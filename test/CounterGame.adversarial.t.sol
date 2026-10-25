// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CounterGame} from "src/CounterGame.sol";

/// @dev Each external call executes one wallet transaction, including its rollback or caught failures.
contract CounterBatchWallet {
    error WalletAborted();

    function execute(CounterGame game, bool[] calldata moves, bool tolerateFailures)
        external
        returns (bool[] memory successes, bytes[] memory results)
    {
        successes = new bool[](moves.length);
        results = new bytes[](moves.length);
        for (uint256 i; i < moves.length; ++i) {
            (bool success, bytes memory result) =
                address(game).call(moves[i] ? abi.encodeCall(game.increment, ()) : abi.encodeCall(game.decrement, ()));
            if (!success && !tolerateFailures) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
            successes[i] = success;
            results[i] = result;
        }
    }

    function moveThenAbort(CounterGame game, bool goesUp) external {
        if (goesUp) game.increment();
        else game.decrement();
        revert WalletAborted();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract CounterGameAdversarialTest is Test {
    CounterGame internal game;
    CounterBatchWallet internal wallet;
    address internal alice;
    address internal bob;

    function setUp() public {
        game = new CounterGame();
        wallet = new CounterBatchWallet();
        alice = makeAddr("adversarial alice");
        bob = makeAddr("adversarial bob");
    }

    function testFuzz_UpThenDownRoundTripsPreserveActiveScore(uint8 rawStart, uint8 rawCycles) public {
        uint256 start = bound(uint256(rawStart), 0, 8);
        uint256 cycles = bound(uint256(rawCycles), 1, 32);
        _advance(start);
        _roundTrips(cycles, false);
        assertEq(game.counter(), start * 100);
    }

    function testFuzz_DownThenUpRoundTripsPreserveActiveScore(uint8 rawStart, uint8 rawCycles) public {
        uint256 start = bound(uint256(rawStart), 1, 9);
        uint256 cycles = bound(uint256(rawCycles), 1, 32);
        _advance(start);
        _roundTrips(cycles, true);
        assertEq(game.counter(), start * 100);
    }

    function test_RepeatedRoundTripsAtZeroAndNineHundredDoNotAccumulateWins() public {
        // More than ten successful increments must not win when other moves cancel them out.
        _roundTrips(32, false);
        assertEq(game.counter(), 0);
        _advance(9);
        _roundTrips(32, true);
        assertEq(game.counter(), 900);

        vm.prank(bob);
        game.increment();
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
    }

    function testFuzz_BatchOfExactlyRemainingIncrementsWins(uint8 rawStart) public {
        uint256 start = bound(uint256(rawStart), 0, 9);
        _advance(start);
        bool[] memory moves = _repeatedMoves(10 - start, true);

        vm.prank(bob, bob);
        (bool[] memory successes, bytes[] memory results) = wallet.execute(game, moves, false);
        assertEq(successes.length, moves.length);
        assertEq(results.length, moves.length);
        for (uint256 i; i < moves.length; ++i) {
            assertTrue(successes[i]);
            assertEq(results[i].length, 0);
        }
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), address(wallet), "wallet, not transaction origin, made the winning call");
    }

    function testFuzz_OverlongIncrementBatchRestoresEarlierTransactions(uint8 rawStart) public {
        uint256 start = bound(uint256(rawStart), 1, 9);
        _advance(start);
        bool[] memory moves = _repeatedMoves(11 - start, true);

        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, address(wallet)));
        wallet.execute(game, moves, false);
        assertEq(game.counter(), start * 100, "failed batch erased or added to an earlier transaction");
        assertEq(game.winner(), address(0), "reverted winner survived the batch");

        _advance(10 - start);
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), alice);
    }

    function testFuzz_OverlongDecrementBatchRestoresEarlierTransactions(uint8 rawStart) public {
        uint256 start = bound(uint256(rawStart), 1, 9);
        _advance(start);
        bool[] memory moves = _repeatedMoves(start + 1, false);

        vm.expectRevert(CounterGame.CounterAtZero.selector);
        wallet.execute(game, moves, false);
        assertEq(game.counter(), start * 100, "partial decrements survived a reverted batch");
        assertEq(game.winner(), address(0));

        vm.prank(bob);
        game.decrement();
        assertEq(game.counter(), (start - 1) * 100, "game did not recover after the failed batch");
    }

    function test_WinningIncrementFollowedByDecrementRollsBackTogether() public {
        _advance(9);
        bool[] memory moves = new bool[](2);
        moves[0] = true;
        moves[1] = false;

        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, address(wallet)));
        wallet.execute(game, moves, false);
        assertEq(game.counter(), 900);
        assertEq(game.winner(), address(0));

        vm.prank(bob);
        game.increment();
        assertEq(game.winner(), bob, "rolled-back winning transaction kept priority");
        assertEq(game.counter(), 1_000);
    }

    function test_CaughtZeroFailureAllowsLaterMovesInSameTransaction() public {
        bool[] memory moves = new bool[](4);
        moves[0] = false;
        moves[1] = true;
        moves[2] = false;
        moves[3] = true;

        vm.recordLogs();
        (bool[] memory successes, bytes[] memory results) = wallet.execute(game, moves, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(successes[0]);
        assertEq(results[0], abi.encodeWithSelector(CounterGame.CounterAtZero.selector));
        for (uint256 i = 1; i < moves.length; ++i) {
            assertTrue(successes[i], "caught underflow blocked a later valid move");
            assertEq(results[i].length, 0);
        }
        assertEq(game.counter(), 100);
        assertEq(game.winner(), address(0));
        assertEq(logs.length, 3, "only successful moves may emit events");
        _assertChangeEvent(logs[0], 0, 100);
        _assertChangeEvent(logs[1], 100, 0);
        _assertChangeEvent(logs[2], 0, 100);
    }

    function test_CaughtPostWinFailuresKeepTheCommittedWin() public {
        _advance(9);
        bool[] memory moves = new bool[](4);
        moves[0] = true;
        moves[1] = false;
        moves[2] = true;
        moves[3] = false;

        vm.recordLogs();
        vm.prank(bob, bob);
        (bool[] memory successes, bytes[] memory results) = wallet.execute(game, moves, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(successes[0]);
        assertEq(results[0].length, 0);
        for (uint256 i = 1; i < moves.length; ++i) {
            assertFalse(successes[i], "finished game accepted another move in the same transaction");
            assertEq(results[i], abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, address(wallet)));
        }
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), address(wallet));
        assertEq(logs.length, 2, "winner must be declared only once");
        _assertChangeEvent(logs[0], 900, 1_000);
        assertEq(logs[1].emitter, address(game));
        assertEq(logs[1].topics.length, 2);
        assertEq(logs[1].topics[0], keccak256("WinnerDeclared(address)"));
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(address(wallet)))));
        assertEq(logs[1].data.length, 0);
    }

    function test_OuterWalletRevertUndoesTheWinningMove() public {
        _advance(9);
        vm.expectRevert(CounterBatchWallet.WalletAborted.selector);
        wallet.moveThenAbort(game, true);
        assertEq(game.counter(), 900);
        assertEq(game.winner(), address(0));

        vm.prank(bob);
        game.increment();
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
    }

    function test_OuterWalletRevertUndoesADecrementToZero() public {
        _advance(1);
        vm.expectRevert(CounterBatchWallet.WalletAborted.selector);
        wallet.moveThenAbort(game, false);
        assertEq(game.counter(), 100);
        assertEq(game.winner(), address(0));

        vm.prank(bob);
        game.decrement();
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
    }

    function test_OneWeiCannotBuyAWinningMove() public {
        _assertPaidWinningMoveIsRejected(1 wei);
    }

    function testFuzz_PaidWinningMoveCanBeRetriedWithoutValue(uint96 rawValue) public {
        _assertPaidWinningMoveIsRejected(bound(uint256(rawValue), 1, type(uint96).max));
    }

    function _assertPaidWinningMoveIsRejected(uint256 value) internal {
        _advance(9);
        vm.deal(bob, value);
        vm.recordLogs();
        vm.prank(bob);
        (bool success, bytes memory result) = address(game).call{value: value}(abi.encodeCall(game.increment, ()));
        assertFalse(success);
        assertEq(result.length, 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(bob.balance, value);
        assertEq(address(game).balance, 0);
        assertEq(game.counter(), 900);
        assertEq(game.winner(), address(0));

        vm.prank(bob);
        game.increment();
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
    }

    function _roundTrips(uint256 cycles, bool downFirst) internal {
        uint256 initialScore = game.counter();
        for (uint256 i; i < cycles; ++i) {
            vm.prank(alice);
            if (downFirst) game.decrement();
            else game.increment();
            assertEq(game.winner(), address(0), "round-trip first leg declared an early winner");
            vm.prank(bob);
            if (downFirst) game.increment();
            else game.decrement();
            assertEq(game.counter(), initialScore, "opposite moves did not cancel");
            assertEq(game.winner(), address(0), "cancelled moves accumulated a win");
        }
    }

    function _advance(uint256 moves) internal {
        vm.startPrank(alice);
        for (uint256 i; i < moves; ++i) {
            game.increment();
        }
        vm.stopPrank();
    }

    function _repeatedMoves(uint256 count, bool goesUp) internal pure returns (bool[] memory moves) {
        moves = new bool[](count);
        for (uint256 i; i < count; ++i) {
            moves[i] = goesUp;
        }
    }

    function _assertChangeEvent(Vm.Log memory entry, uint256 beforeScore, uint256 afterScore) internal view {
        assertEq(entry.emitter, address(game));
        assertEq(entry.topics.length, 2);
        assertEq(entry.topics[0], keccak256("CounterChanged(address,uint256,uint256)"));
        assertEq(entry.topics[1], bytes32(uint256(uint160(address(wallet)))));
        assertEq(entry.data, abi.encode(beforeScore, afterScore));
    }
}
