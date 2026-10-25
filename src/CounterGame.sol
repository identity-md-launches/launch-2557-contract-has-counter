// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CounterGame
/// @notice A shared counter: each move is 100 points and the caller reaching 1,000 wins.
/// @dev One game per deployment. Anyone may move repeatedly in either direction until a win.
///      There are no administrators, payments, external calls, or reset mechanisms.
contract CounterGame {
    uint256 public constant STEP = 100;
    uint256 public constant TARGET = 1_000;

    /// @notice Shared score, initially zero, always a multiple of STEP between zero and TARGET.
    uint256 public counter;

    /// @notice The caller of the winning increment; zero means nobody has won yet.
    address public winner;

    error CounterAtZero();
    error GameAlreadyWon(address winner);

    event CounterChanged(address indexed player, uint256 previousCounter, uint256 newCounter);
    event WinnerDeclared(address indexed winner);

    modifier whenActive() {
        if (winner != address(0)) revert GameAlreadyWon(winner);
        _;
    }

    /// @notice Add exactly STEP points; the caller wins if the counter reaches TARGET.
    /// @dev Reverts with GameAlreadyWon after the first win. Smart wallets are credited as msg.sender.
    function increment() external whenActive {
        uint256 previous = counter;
        uint256 next = previous + STEP;
        counter = next;
        emit CounterChanged(msg.sender, previous, next);

        if (next == TARGET) {
            winner = msg.sender;
            emit WinnerDeclared(msg.sender);
        }
    }

    /// @notice Subtract exactly STEP points. Any player may decrement, including the last mover.
    /// @dev Reverts with CounterAtZero at zero, or GameAlreadyWon after the first win.
    function decrement() external whenActive {
        uint256 previous = counter;
        if (previous == 0) revert CounterAtZero();

        uint256 next = previous - STEP;
        counter = next;
        emit CounterChanged(msg.sender, previous, next);
    }
}
