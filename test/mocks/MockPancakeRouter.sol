// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPancakeV2Router} from "../../src/interfaces/IPancakeV2Router.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockPancakeRouter — minimal IPancakeV2Router for tests
/// @notice Simulates a constant-rate swap: 1 unit of tokenIn → `rate[tokenIn][tokenOut] / 1e18`
///         units of tokenOut. The caller must have approved this router for `amountIn`
///         of tokenIn; the router pulls via transferFrom and then mints tokenOut to `to`
///         (since the mock pool doesn't hold liquidity).
///
/// Knobs:
///   - `setRate(tokenIn, tokenOut, r)`: fix the rate (1e18 = 1.0)
///   - `setSwapReverts(true)`: every call reverts (atomicity tests)
contract MockPancakeRouter is IPancakeV2Router {
    /// @dev rate[A][B] * 1e18 = how many B you get for 1 A (in their respective decimals).
    ///      Tests typically pre-account for decimals when setting the rate.
    mapping(address => mapping(address => uint256)) public rate;

    bool public swapReverts;

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function setSwapReverts(bool v) external {
        swapReverts = v;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        if (swapReverts) revert("MockPancake: swapReverts is on");
        require(deadline >= block.timestamp, "MockPancake: deadline expired");
        require(path.length >= 2, "MockPancake: path too short");

        // Pull tokenIn from caller. Caller must have approved this router for >= amountIn.
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);

        // Compute output linearly. For the tests we only use direct (2-hop) paths.
        uint256 r = rate[path[0]][path[path.length - 1]];
        require(r > 0, "MockPancake: rate not set");
        uint256 amountOut = (amountIn * r) / 1e18;
        require(amountOut >= amountOutMin, "MockPancake: insufficient output");

        // Mint output to `to` (the mock pool doesn't hold liquidity).
        MockERC20(path[path.length - 1]).mint(to, amountOut);

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;
        return amounts;
    }
}
