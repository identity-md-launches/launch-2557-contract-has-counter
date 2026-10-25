// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CounterGame} from "../src/CounterGame.sol";

/// @dev Models a smart wallet or a batching caller, not a production dependency.
contract CounterPlayer {
    function increment(CounterGame game, uint256 times) external {
        for (uint256 i; i < times; ++i) {
            game.increment();
        }
    }
}

/// @dev An empty-chain factory rehearsal with no privileged deployment address.
contract CounterGameFactory {
    function deploy(bytes32 salt) external returns (CounterGame) {
        return new CounterGame{salt: salt}();
    }
}

contract CounterGameTest is Test {
    CounterGame internal game;
    address internal alice;
    address internal bob;
    address internal carol;

    event CounterChanged(address indexed player, uint256 previousCounter, uint256 newCounter);
    event WinnerDeclared(address indexed winner);

    function setUp() public {
        game = new CounterGame();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
    }

    function test_InitialStateAndRules() public view {
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
        assertEq(game.STEP(), 100);
        assertEq(game.TARGET(), 1_000);
    }

    function test_IncrementAddsExactly100AndSharesTheCounter() public {
        vm.prank(alice);
        game.increment();
        assertEq(game.counter(), 100);

        vm.prank(bob);
        game.increment();
        assertEq(game.counter(), 200);
        assertEq(game.winner(), address(0));
    }

    function test_AnotherWalletCanLowerTheCounterBy100() public {
        _incrementAs(alice, 3);
        vm.prank(bob);
        game.decrement();
        assertEq(game.counter(), 200);
        assertEq(game.winner(), address(0));
    }

    function test_SameWalletMayMoveRepeatedlyInEitherDirection() public {
        _incrementAs(alice, 2);
        vm.startPrank(alice);
        game.decrement();
        game.decrement();
        game.increment();
        vm.stopPrank();
        assertEq(game.counter(), 100);
        assertEq(game.winner(), address(0));
    }

    function test_DecrementAtInitialZeroRevertsWithoutEventsOrStateChanges() public {
        vm.recordLogs();
        vm.expectRevert(CounterGame.CounterAtZero.selector);
        vm.prank(bob);
        game.decrement();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
    }

    function test_ReturnToZeroRejectsFurtherDecrementAndAllowsRecovery() public {
        _incrementAs(alice, 1);
        vm.prank(bob);
        game.decrement();
        assertEq(game.counter(), 0);

        vm.expectRevert(CounterGame.CounterAtZero.selector);
        vm.prank(carol);
        game.decrement();

        _incrementAs(carol, 1);
        assertEq(game.counter(), 100);
        assertEq(game.winner(), address(0));
    }

    function test_IncrementEmitsActorAndOldAndNewCounters() public {
        vm.expectEmit(true, false, false, true, address(game));
        emit CounterChanged(alice, 0, 100);
        vm.prank(alice);
        game.increment();
    }

    function test_DecrementEmitsActorAndOldAndNewCounters() public {
        _incrementAs(alice, 2);
        vm.expectEmit(true, false, false, true, address(game));
        emit CounterChanged(bob, 200, 100);
        vm.prank(bob);
        game.decrement();
    }

    function test_WinningMoveCreditsTheLastWalletAndEmitsExactlyTwoEvents() public {
        _incrementAs(alice, 9);
        assertEq(game.counter(), 900);
        assertEq(game.winner(), address(0));

        vm.recordLogs();
        vm.prank(bob);
        game.increment();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
        assertEq(logs.length, 2);
        assertEq(logs[0].emitter, address(game));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("CounterChanged(address,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(bob))));
        assertEq(logs[0].data, abi.encode(uint256(900), uint256(1_000)));
        assertEq(logs[1].emitter, address(game));
        assertEq(logs[1].topics.length, 2);
        assertEq(logs[1].topics[0], keccak256("WinnerDeclared(address)"));
        assertEq(logs[1].topics[1], bytes32(uint256(uint160(bob))));
        assertEq(logs[1].data.length, 0);
    }

    function test_DecrementNearTargetDelaysWinning() public {
        _incrementAs(alice, 9);
        vm.prank(bob);
        game.decrement();
        assertEq(game.counter(), 800);

        _incrementAs(carol, 1);
        assertEq(game.counter(), 900);
        assertEq(game.winner(), address(0));

        _incrementAs(bob, 1);
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
    }

    function test_WinnerAndOtherPlayersCannotChangeAFinishedGame() public {
        _incrementAs(alice, 10);
        address[3] memory players = [alice, bob, carol];
        vm.recordLogs();
        for (uint256 i; i < players.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, alice));
            vm.prank(players[i]);
            game.increment();

            vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, alice));
            vm.prank(players[i]);
            game.decrement();
        }
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), alice);
    }

    function test_FirstExecutedWinningMoveBeatsCompetingMove() public {
        _incrementAs(alice, 9);
        _incrementAs(bob, 1);

        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, bob));
        vm.prank(carol);
        game.increment();
        assertEq(game.winner(), bob);
        assertEq(game.counter(), 1_000);
    }

    function test_SmartWalletIsTheWinnerAndCanBatchMoves() public {
        CounterPlayer player = new CounterPlayer();
        vm.prank(alice, alice);
        player.increment(game, 10);
        assertEq(game.winner(), address(player));
        assertEq(game.counter(), 1_000);
    }

    function test_OverlongAtomicBatchRevertsTheEntireGameProgress() public {
        CounterPlayer player = new CounterPlayer();
        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, address(player)));
        player.increment(game, 11);
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
    }

    function test_NativeValueOnMovesIsRejectedWithoutChangingState() public {
        _incrementAs(alice, 1);
        vm.deal(bob, 2 ether);
        vm.prank(bob);
        (bool incremented,) = address(game).call{value: 1 ether}(abi.encodeCall(game.increment, ()));
        assertFalse(incremented);

        vm.prank(bob);
        (bool decremented,) = address(game).call{value: 1 ether}(abi.encodeCall(game.decrement, ()));
        assertFalse(decremented);
        assertEq(address(game).balance, 0);
        assertEq(bob.balance, 2 ether);
        assertEq(game.counter(), 100);
        assertEq(game.winner(), address(0));
    }

    function test_PlainNativeTransferAndUnknownSelectorAreRejected() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool paid,) = address(game).call{value: 1 ether}("");
        assertFalse(paid);
        (bool unknown,) = address(game).call(abi.encodeWithSignature("reset()"));
        assertFalse(unknown);
        assertEq(address(game).balance, 0);
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
    }

    function test_UnsolicitedBalanceCannotAffectScoringOrWinning() public {
        // Model an unsolicited balance without adding a SELFDESTRUCT helper to the repository.
        vm.deal(address(game), 5 ether);
        assertEq(game.counter(), 0);
        assertEq(game.winner(), address(0));
        _incrementAs(bob, 10);
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), bob);
        assertEq(address(game).balance, 5 ether);
    }

    function test_FactoryDeploymentNeedsNoArgumentsAndGamesAreIndependent() public {
        CounterGameFactory factory = new CounterGameFactory();
        CounterGame first = factory.deploy(keccak256("first game"));
        CounterGame second = factory.deploy(keccak256("second game"));
        assertGt(address(first).code.length, 0);
        assertLe(address(first).code.length, 24_576);
        assertEq(first.counter(), 0);
        assertEq(first.winner(), address(0));

        vm.startPrank(alice);
        for (uint256 i; i < 10; ++i) {
            first.increment();
        }
        vm.stopPrank();
        assertEq(first.winner(), alice);
        assertEq(second.counter(), 0);
        assertEq(second.winner(), address(0));
        vm.prank(bob);
        second.increment();
        assertEq(second.counter(), 100);
    }

    function testFuzz_AllReachableActiveScoresCanBeLowered(uint8 rawSteps, address player) public {
        vm.assume(player != address(0));
        uint256 steps = bound(uint256(rawSteps), 1, 9);
        _incrementAs(alice, steps);
        vm.prank(player);
        game.decrement();
        assertEq(game.counter(), (steps - 1) * 100);
        assertEq(game.winner(), address(0));
    }

    function testFuzz_AnyCallerCanWinAndCannotBeReplaced(address winningPlayer, address latePlayer) public {
        vm.assume(winningPlayer != address(0) && latePlayer != address(0));
        _incrementAs(alice, 9);
        _incrementAs(winningPlayer, 1);
        assertEq(game.winner(), winningPlayer);
        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, winningPlayer));
        vm.prank(latePlayer);
        game.increment();
        vm.expectRevert(abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, winningPlayer));
        vm.prank(latePlayer);
        game.decrement();
        assertEq(game.winner(), winningPlayer);
        assertEq(game.counter(), 1_000);
    }

    /// @dev Reference model uses steps (0..10), independently of the contract's point arithmetic.
    function testFuzz_MixedMovesMatchReferenceModel(bytes memory moves) public {
        uint256 steps;
        address modelWinner;
        uint256 length = moves.length > 128 ? 128 : moves.length;
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < length; ++i) {
            uint8 move = uint8(moves[i]);
            address player = players[(move >> 1) % players.length];
            bool goesUp = (move & 1) == 1;
            bool shouldRevert = modelWinner != address(0) || (!goesUp && steps == 0);
            bytes memory expectedError;
            if (modelWinner != address(0)) {
                expectedError = abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, modelWinner);
            } else if (!goesUp && steps == 0) {
                expectedError = abi.encodeWithSelector(CounterGame.CounterAtZero.selector);
            }

            vm.prank(player);
            (bool success, bytes memory result) =
                address(game).call(goesUp ? abi.encodeCall(game.increment, ()) : abi.encodeCall(game.decrement, ()));
            assertEq(success, !shouldRevert);
            if (shouldRevert) {
                assertEq(result, expectedError);
            } else if (goesUp) {
                ++steps;
                if (steps == 10) modelWinner = player;
            } else {
                --steps;
            }

            assertEq(game.counter(), steps * 100);
            assertEq(game.winner(), modelWinner);
            assertLe(game.counter(), 1_000);
            assertEq(game.counter() % 100, 0);
        }
    }

    function _incrementAs(address player, uint256 times) internal {
        vm.startPrank(player);
        for (uint256 i; i < times; ++i) {
            game.increment();
        }
        vm.stopPrank();
    }
}
