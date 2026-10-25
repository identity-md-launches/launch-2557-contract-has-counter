// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CounterGame} from "../src/CounterGame.sol";

/// @dev Tracks an independent model and checks failures as well as successful state transitions.
contract CounterGameHandler is Test {
    CounterGame public immutable game;
    address[3] internal actors;
    uint256 public modelSteps;
    address public modelWinner;
    uint256 public successfulIncrements;
    uint256 public successfulDecrements;

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

    function _move(bool goesUp, address actor) internal {
        bool shouldRevert = modelWinner != address(0) || (!goesUp && modelSteps == 0);
        bytes memory expectedError;
        if (modelWinner != address(0)) {
            expectedError = abi.encodeWithSelector(CounterGame.GameAlreadyWon.selector, modelWinner);
        } else if (!goesUp && modelSteps == 0) {
            expectedError = abi.encodeWithSelector(CounterGame.CounterAtZero.selector);
        }

        vm.prank(actor);
        (bool success, bytes memory result) =
            address(game).call(goesUp ? abi.encodeCall(game.increment, ()) : abi.encodeCall(game.decrement, ()));
        assertEq(success, !shouldRevert, "move acceptance differs from the model");

        if (shouldRevert) {
            assertEq(result, expectedError, "wrong failure reason");
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
    }
}

contract CounterGameInvariantTest is Test {
    CounterGame internal game;
    CounterGameHandler internal handler;

    function setUp() public {
        game = new CounterGame();
        address[3] memory actors = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol")];
        handler = new CounterGameHandler(game, actors);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = CounterGameHandler.increment.selector;
        selectors[1] = CounterGameHandler.decrement.selector;
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
}
