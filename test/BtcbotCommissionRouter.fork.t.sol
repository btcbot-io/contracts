// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BtcbotCommissionRouter} from "../src/BtcbotCommissionRouter.sol";

/// @title Mainnet-fork integration test for BtcbotCommissionRouter
/// @notice Tests against the REAL Pancake V3 SwapRouter + REAL BTCB/USDT pool on a
///         BSC mainnet fork. Run with:
///           forge test --match-contract BtcbotCommissionRouterForkTest --fork-url $BSC_RPC_HTTP
///         Skipped by default — only fires when BSC_RPC_HTTP is set + the matcher is used.
contract BtcbotCommissionRouterForkTest is Test {
    // BSC mainnet canonical addresses
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant V3_SWAP_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    BtcbotCommissionRouter router;

    address user    = makeAddr("user");
    address trader  = makeAddr("trader");
    address ownerW  = makeAddr("owner");
    address root    = makeAddr("root");
    address upline1 = makeAddr("upline1");

    function setUp() public {
        // Deploy the contract pointing at the real V3 SwapRouter.
        router = new BtcbotCommissionRouter(BTCB, USDT, V3_SWAP_ROUTER, trader, root, ownerW);

        // Give the user $50 USDT and approve the router for both tokens.
        deal(USDT, user, 50 ether);
        vm.startPrank(user);
        IERC20(USDT).approve(address(router), type(uint256).max);
        IERC20(BTCB).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice BUY $10 USDT → BTCB via the real V3 0.05% pool. User should
    ///         receive ~ $10 / $77k ≈ 0.00013 BTCB.
    function testForkBuyV3() public {
        uint256 usdtIn = 10 ether;
        uint256 btcbBefore = IERC20(BTCB).balanceOf(user);

        vm.prank(trader);
        uint256 btcbOut = router.swapUsdtToBtcb(user, usdtIn, 1);  // minOut=1, no slippage check

        uint256 btcbAfter = IERC20(BTCB).balanceOf(user);
        assertEq(btcbAfter - btcbBefore, btcbOut, "user balance mismatch vs returned amount");
        assertGt(btcbOut, 1e14, "expected at least 0.0001 BTCB for $10 swap");
        assertLt(btcbOut, 2e14, "expected less than 0.0002 BTCB for $10 swap (sanity)");

        console.log("BUY result: %s wei BTCB for 10 USDT", btcbOut);
    }

    /// @notice SELL 0.0001 BTCB → USDT with a 6-tier commission fan-out.
    ///         Tests the full atomic distribution: user got their share, upline got their cut,
    ///         no leftover token stuck in the contract.
    function testForkSellV3WithFanout() public {
        // Give the user 0.0001 BTCB (~$7.7 at current spot).
        deal(BTCB, user, 1e14);

        address[6] memory tierRecipients;
        uint256[6] memory parts;
        tierRecipients[0] = upline1;    // tier 1 = direct upline
        tierRecipients[5] = root;       // tier 0 / root

        // Per-trade commission: $1.50 to upline1, $0.50 to root (~28% of expected $7 USDT).
        parts[0] = 15 * 1e17;           // 1.5 USDT
        parts[5] = 5 * 1e17;            // 0.5 USDT

        uint256 upline1Before = IERC20(USDT).balanceOf(upline1);
        uint256 rootBefore    = IERC20(USDT).balanceOf(root);
        uint256 userBefore    = IERC20(USDT).balanceOf(user);

        vm.prank(trader);
        uint256 userReceived = router.swapAndDistribute(
            user,
            1e14,                       // 0.0001 BTCB
            1,                          // minUserReceived=1 (no slippage check)
            tierRecipients,
            parts
        );

        // Verify tier transfers happened.
        assertEq(
            IERC20(USDT).balanceOf(upline1) - upline1Before, parts[0],
            "upline1 didn't receive its cut"
        );
        assertEq(
            IERC20(USDT).balanceOf(root) - rootBefore, parts[5],
            "root didn't receive its cut"
        );
        // Verify user got the remainder.
        assertEq(
            IERC20(USDT).balanceOf(user) - userBefore, userReceived,
            "user balance mismatch vs return value"
        );
        // No USDT left in the contract.
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "USDT stuck in router");
        // No BTCB left either.
        assertEq(IERC20(BTCB).balanceOf(address(router)), 0, "BTCB stuck in router");

        console.log("SELL result: user got %s USDT", userReceived);
        console.log("  upline1 got %s, root got %s", parts[0], parts[5]);
    }

    /// @notice The new mutable swap router setter — set + read back + emit event.
    function testSetSwapRouter() public {
        address newRouter = makeAddr("v4_router");

        vm.expectEmit(true, true, false, false);
        emit BtcbotCommissionRouter.SwapRouterUpdated(V3_SWAP_ROUTER, newRouter);

        vm.prank(ownerW);
        router.setSwapRouter(newRouter);

        assertEq(router.swapRouter(), newRouter, "swapRouter not updated");
    }

    /// @notice setSwapRouter is onlyOwner — non-owner reverts.
    function testSetSwapRouter_OnlyOwner() public {
        vm.expectRevert(BtcbotCommissionRouter.NotOwner.selector);
        vm.prank(trader);  // trader is not owner
        router.setSwapRouter(makeAddr("attacker_router"));
    }

    /// @notice setSwapRouter rejects zero address.
    function testSetSwapRouter_ZeroReverts() public {
        vm.expectRevert(BtcbotCommissionRouter.ZeroAddress.selector);
        vm.prank(ownerW);
        router.setSwapRouter(address(0));
    }
}
