// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Minimal PancakeSwap V3 SmartRouter interface
/// @notice We only use `exactInputSingle`. PancakeSwap deployed a SmartRouter (V3
///         SwapRouter02-style, 7-field params — NO deadline in the struct) at
///         0x13f4EA83D0bd40E75C8222255bc855a974568Dd4. This is NOT the OG Uniswap
///         V3 SwapRouter (which had an 8-field struct including deadline).
///         Burned 2026-05-21 morning when the 8-field call reverted with no logic
///         executed (selector mismatch, ~1100 gas).
///         Deadline protection — for users who need it — comes from the outer
///         `multicall(deadline, calls)` wrapper. For our bot-driven swaps (block
///         inclusion ~1-2s on BSC), in-tx deadline doesn't add meaningful safety.
///         https://bscscan.com/address/0x13f4EA83D0bd40E75C8222255bc855a974568Dd4#code
interface IPancakeV3SwapRouter {
    /// @notice Parameters for single-pool exact-input swaps.
    /// @dev    7 fields (no deadline) — SwapRouter02-style.
    ///         `fee` is the pool's fee tier in hundredths of a bip (500 = 0.05%).
    ///         `sqrtPriceLimitX96` = 0 means no price limit (slippage protection
    ///         delegated entirely to `amountOutMinimum`). Per cowork Q4 we always
    ///         pass 0 — avoids Q64.96 fixed-point encoding bugs.
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swap `amountIn` of `tokenIn` for at least `amountOutMinimum` of `tokenOut`
    ///         in a single V3 pool identified by (tokenIn, tokenOut, fee).
    /// @return amountOut The amount of `tokenOut` received.
    /// @dev    Marked `payable` for WBNB-wrap paths; we always call with msg.value == 0.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
