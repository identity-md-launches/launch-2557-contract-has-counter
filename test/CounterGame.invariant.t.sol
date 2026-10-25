// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CounterGame} from "../src/CounterGame.sol";

/// @dev Tracks an independent model and checks failures as well as successful state transitions.
contract CounterGameHandler is Test {
    CounterGame public immutable game;
    address[3] internal actors;
    uint256 public modelSteps;
    address public modelWinner;
    uint256 public successfulIncrements;
    uint256 public successfulDecrements;
    uint256 public winnerAnnouncements;
    uint256 public forcedBalance;

    constructor(CounterGame game_, address[3] memory actors_) {
        game = game_;
        actors = actors_;
    }

    function increment(uint256 actorSeed) external {
        _move(true, actors[actorSeed % actors.length]);
    }

    function decrement(uint256 actorSeed) external {
        _move(false, actors[actorSeed % actors.length]);
    }

    /// @dev Keep exploring active scores through cancelling moves, without resetting the game.
    function roundTrip(uint256 actorSeed, bool downFirst) external {
        address first = actors[actorSeed % actors.length];
        address second = actors[(actorSeed % actors.length + 1) % actors.length];
        uint256 stepsBefore = modelSteps;
        address winnerBefore = modelWinner;

        // At the boundaries only one ordering can complete a round trip without winning/reverting.
        if (modelSteps == 0) downFirst = false;
        if (modelSteps == 9) downFirst = true;
        _move(!downFirst, first);
        _move(downFirst, second);

        assertEq(game.counter(), stepsBefore * 100, "round trip changed the score");
        assertEq(game.winner(), winnerBefore, "round trip changed the winner");
    }

    /// @dev Exercise nonpayable moves and the absent receive/fallback at arbitrary game states.
    function sendValue(uint256 actorSeed, uint96 rawValue, uint8 operation) external {
        address actor = actors[actorSeed % actors.length];
        uint256 value = bound(uint256(rawValue), 1, type(uint96).max);
        bytes memory data;
        if (operation % 4 == 0) data = abi.encodeCall(game.increment, ());
        else if (operation % 4 == 1) data = abi.encodeCall(game.decrement, ());
        else if (operation % 4 == 2) data = "";
        else data = abi.encodeWithSignature("reset()");

        vm.deal(actor, value);
        vm.recordLogs();
        vm.prank(actor);
        (bool success, bytes memory result) = address(game).call{value: value}(data);
        assertFalse(success, "game accepted an ETH transfer");
        assertEq(result.length, 0, "unexpected nonpayable/fallback revert data");
        assertEq(vm.getRecordedLogs().length, 0, "rejected transfer emitted an event");
        assertEq(actor.balance, value, "rejected transfer charged the caller");
        assertEq(game.counter(), modelSteps * 100, "rejected transfer changed score");
        assertEq(game.winner(), modelWinner, "rejected transfer changed winner");
    }

    /// @dev The game has no deposit facility. Model unsolicited ETH separately from accepted calls.
    function forceNativeBalance(uint96 amount) external {
        forcedBalance += uint256(amount);
        vm.deal(address(game), address(game).balance + uint256(amount));
    }

    function _move(bool goesUp, address actor) internal {
        uint256 previousScore = modelSteps * 100;
        bool shouldRevert = modelWinner != address(0) || (!goesUp && modelSteps == 0);
        bytes memory expectedError;
        if (modelWinner != address(0)) {
            expectedError = abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, modelWinner);
        } else if (!goesUp && modelSteps == 0) {
            expectedError = abi.encodeWithSelector(CounterGame.CounterAtZero.selector);
        }

        vm.recordLogs();
        vm.prank(actor);
        (bool success, bytes memory result) =
            address(game).call(goesUp ? abi.encodeCall(game.increment, ()) : abi.encodeCall(game.decrement, ()));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(success, !shouldRevert, "move acceptance differs from the model");

        if (shouldRevert) {
            assertEq(result, expectedError, "wrong failure reason");
            assertEq(logs.length, 0, "failed move emitted an event");
        } else if (goesUp) {
            ++successfulIncrements;
            ++modelSteps;
            if (modelSteps == 10) modelWinner = actor;
        } else {
            ++successfulDecrements;
            --modelSteps;
        }

        assertEq(game.counter(), modelSteps * 100, "counter diverged from model");
        assertEq(game.winner(), modelWinner, "winner diverged from model");
        if (success) {
            assertEq(result.length, 0, "move unexpectedly returned data");
            _checkMoveEvents(logs, actor, previousScore);
        }
    }

    function _checkMoveEvents(Vm.Log[] memory logs, address actor, uint256 previousScore) internal {
        assertEq(logs.length, modelWinner == address(0) ? 1 : 2, "wrong number of move events");
        assertEq(logs[0].emitter, address(game));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("CounterChanged(address,uint256,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(actor))));
        assertEq(logs[0].data, abi.encode(previousScore, modelSteps * 100));

        if (logs.length == 2) {
            ++winnerAnnouncements;
            assertEq(logs[1].emitter, address(game));
            assertEq(logs[1].topics.length, 2);
            assertEq(logs[1].topics[0], keccak256("WinnerDeclared(address)"));
            assertEq(logs[1].topics[1], bytes32(uint256(uint160(modelWinner))));
            assertEq(logs[1].data.length, 0);
        }
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract CounterGameInvariantTest is Test {
    CounterGame internal game;
    CounterGameHandler internal handler;

    function setUp() public {
        game = new CounterGame();
        address[3] memory actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        handler = new CounterGameHandler(game, actors);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = CounterGameHandler.increment.selector;
        selectors[1] = CounterGameHandler.decrement.selector;
        selectors[2] = CounterGameHandler.roundTrip.selector;
        selectors[3] = CounterGameHandler.sendValue.selector;
        selectors[4] = CounterGameHandler.forceNativeBalance.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_CounterIsBoundedAndInStepsOf100() public view {
        assertLe(game.counter(), 1_000);
        assertEq(game.counter() % 100, 0);
    }

    function invariant_WinnerExistsExactlyWhenTargetIsReached() public view {
        assertEq(game.winner() != address(0), game.counter() == 1_000);
    }

    function invariant_EveryAcceptedMoveIsAccountedFor() public view {
        assertGe(handler.successfulIncrements(), handler.successfulDecrements());
        assertEq(game.counter(), (handler.successfulIncrements() - handler.successfulDecrements()) * 100);
    }

    function invariant_CounterAndPermanentWinnerMatchModel() public view {
        assertEq(game.counter(), handler.modelSteps() * 100);
        assertEq(game.winner(), handler.modelWinner());
    }

    function invariant_WinnerIsAnnouncedExactlyOnce() public view {
        assertEq(handler.winnerAnnouncements(), game.winner() == address(0) ? 0 : 1);
    }

    function invariant_OnlyForcedNativeValueRemainsInTheGame() public view {
        assertEq(address(game).balance, handler.forcedBalance());
    }

    /// @dev Every random prefix must still admit a win, and every finished game must stay finished.
    function afterInvariant() public {
        uint256 steps = handler.modelSteps();
        for (uint256 i = steps; i < 10; ++i) {
            handler.increment(i);
        }
        address finalWinner = game.winner();
        assertTrue(finalWinner != address(0), "active game could not finish");
        for (uint256 i; i < 3; ++i) {
            handler.increment(i);
            handler.decrement(i);
        }
        assertEq(game.counter(), 1_000);
        assertEq(game.winner(), finalWinner);
        invariant_CounterAndPermanentWinnerMatchModel();
        invariant_EveryAcceptedMoveIsAccountedFor();
        invariant_WinnerIsAnnouncedExactlyOnce();
        invariant_OnlyForcedNativeValueRemainsInTheGame();
    }

    /// @dev Deterministically exercises every handler entry point and both terminal failures.
    function test_HandlerReachesBothBoundariesWithAnUnsolicitedBalance() public {
        handler.forceNativeBalance(1 wei);
        handler.decrement(0);
        handler.roundTrip(type(uint256).max, false);
        for (uint256 i; i < 9; ++i) {
            handler.increment(i);
        }
        handler.roundTrip(type(uint256).max, true);
        assertEq(game.counter(), 900);
        assertEq(handler.successfulIncrements(), 11);
        assertEq(handler.successfulDecrements(), 2);

        for (uint8 operation; operation < 4; ++operation) {
            handler.sendValue(type(uint256).max, 1, operation);
            handler.sendValue(1, type(uint96).max, operation);
        }
        afterInvariant();
        handler.roundTrip(0, false);
        handler.forceNativeBalance(type(uint96).max);
        invariant_CounterAndPermanentWinnerMatchModel();
        invariant_OnlyForcedNativeValueRemainsInTheGame();
    }
}
