// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPancakeV3SwapRouter} from "../../src/interfaces/IPancakeV3SwapRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockV3SwapRouter — minimal IPancakeV3SwapRouter for unit tests
/// @notice Simulates a constant-rate V3 `exactInputSingle`: pulls `amountIn` of tokenIn
///         from the caller (the contract under test must have approved this router) and
///         mints `amountIn * rate / 1e18` of tokenOut to `recipient`.
///
/// Knobs (mirror MockPancakeRouter so the V2 + V3 test suites behave identically):
///   - `setRate(tokenIn, tokenOut, r)`: fix the rate (1e18 = 1.0)
///   - `setSwapReverts(true)`: every call reverts (atomicity tests)
///   - `setFixedOut(n)`: when n>0, return EXACTLY `n` tokenOut regardless of rate/amountIn
///     (forces an indivisible total so the batch pro-rata truncation/dust branch is hit)
contract MockV3SwapRouter is IPancakeV3SwapRouter {
    mapping(address => mapping(address => uint256)) public rate;
    bool public swapReverts;
    uint256 public fixedOut; // 0 = use rate; >0 = return exactly this many tokenOut

    function setRate(address tokenIn, address tokenOut, uint256 r) external {
        rate[tokenIn][tokenOut] = r;
    }

    function setSwapReverts(bool v) external {
        swapReverts = v;
    }

    function setFixedOut(uint256 n) external {
        fixedOut = n;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        if (swapReverts) revert("MockV3: swapReverts is on");

        // Pull tokenIn from caller (must have approved this router for >= amountIn).
        MockERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);

        if (fixedOut > 0) {
            amountOut = fixedOut;
        } else {
            uint256 r = rate[p.tokenIn][p.tokenOut];
            require(r > 0, "MockV3: rate not set");
            amountOut = (p.amountIn * r) / 1e18;
        }
        require(amountOut >= p.amountOutMinimum, "MockV3: insufficient output");

        // Mint output to recipient (the mock pool doesn't hold liquidity).
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}
