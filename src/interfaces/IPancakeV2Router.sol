// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Minimal PancakeSwap V2 router interface
/// @notice We only use swapExactTokensForTokens. Full ABI lives at
///         https://bscscan.com/address/0x10ED43C718714eb63d5aA57B78B54704E256024E#code
interface IPancakeV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}
