// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockAggregatorV3 — minimal Chainlink AggregatorV3 for unit tests.
/// @notice Configurable price + updatedAt so tests can exercise the oracle floor (#7)
///         and the staleness guard. `decimals()` matches the BSC BTC/USD feed (8).
contract MockAggregatorV3 {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    /// @notice Set the price and refresh updatedAt to now.
    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    /// @notice Force a specific updatedAt (to test the staleness revert).
    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 ans, uint256 startedAt, uint256 upd, uint80 answeredInRound)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
