// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotRouterDuplex} from "../src/BtcbotRouterDuplex.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";

/// @title BtcbotRouterDuplex — batchSwapUsdtToBtcb (batch BUY) tests
/// @notice The BUY mirror of the batch-SELL suite. NO commission (buys aren't
///         taxable): verifies per-user pro-rata BTCB, failure-isolation (one bad
///         leg never sinks the batch), the aggregate slippage floor, dust
///         accounting, the per-swap `deadline` guard, and the revert paths.
///
/// Setup: 1 BTCB = 100 USDT (clean math; both 18 decimals). Users A/B/C funded
/// with USDT, pre-approve THE ROUTER for max. USER_D approves but holds 0 USDT.
contract BtcbotRouterDuplexBatchBuyTest is Test {
    BtcbotRouterDuplex router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockV3SwapRouter v3;

    // Re-declared events (Foundry needs them in scope for vm.expectEmit).
    event BatchSwapUsdtToBtcb(uint256 totalUsdtIn, uint256 totalBtcbOut, uint256 nFilled, uint256 nSkipped);
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);
    event SwapUsdtToBtcb(address indexed user, uint256 usdtIn, uint256 btcbOut);

    address constant TRADER = address(0xA77ade2);
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);
    address constant USER_A = address(0xA1);
    address constant USER_B = address(0xB1);
    address constant USER_C = address(0xC1);
    address constant USER_D = address(0xD1); // approves but has ZERO USDT

    uint256 constant RATE_USDT_BTCB = 1e16;  // 0.01 BTCB per USDT → 100 USDT = 1 BTCB
    uint256 constant DL = type(uint256).max; // far-future deadline (always valid)

    function setUp() public {
        vm.warp(1000); // so `block.timestamp - 1` is a safe past deadline
        btcb = new MockERC20("BTCB", "BTCB", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        v3 = new MockV3SwapRouter();

        router = new BtcbotRouterDuplex(
            address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER
        );

        v3.setRate(address(usdt), address(btcb), RATE_USDT_BTCB);

        usdt.mint(USER_A, 500e18);
        usdt.mint(USER_B, 500e18);
        usdt.mint(USER_C, 500e18);

        vm.prank(USER_A);
        usdt.approve(address(router), type(uint256).max);
        vm.prank(USER_B);
        usdt.approve(address(router), type(uint256).max);
        vm.prank(USER_C);
        usdt.approve(address(router), type(uint256).max);
        vm.prank(USER_D);
        usdt.approve(address(router), type(uint256).max);
    }

    function _leg(address u, uint256 amtIn) internal pure returns (BtcbotRouterDuplex.BuyLeg memory leg) {
        leg.user = u;
        leg.amountIn = amtIn;
    }

    // A:100, B:200, C:300 USDT → 600 USDT in → 6 BTCB out (pro-rata 1/2/3).
    function _threeLegs() internal pure returns (BtcbotRouterDuplex.BuyLeg[] memory legs) {
        legs = new BtcbotRouterDuplex.BuyLeg[](3);
        legs[0] = _leg(USER_A, 100e18);
        legs[1] = _leg(USER_B, 200e18);
        legs[2] = _leg(USER_C, 300e18);
    }

    // 1 — happy multi-leg
    function test_buy_happyMultiLeg() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();

        vm.expectEmit(false, false, false, true, address(router));
        emit BatchSwapUsdtToBtcb(600e18, 6e18, 3, 0);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 6e18, DL);

        assertEq(totalOut, 6e18, "totalBtcbOut");
        assertEq(nFilled, 3, "nFilled");
        assertEq(btcb.balanceOf(USER_A), 1e18, "A btcb");
        assertEq(btcb.balanceOf(USER_B), 2e18, "B btcb");
        assertEq(btcb.balanceOf(USER_C), 3e18, "C btcb");
        assertEq(usdt.balanceOf(USER_A), 400e18, "A spent 100 USDT");
        assertEq(usdt.balanceOf(USER_C), 200e18, "C spent 300 USDT");
        assertEq(btcb.balanceOf(address(router)), 0, "no BTCB stuck");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
    }

    // 2 — single leg
    function test_buy_singleLeg() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = new BtcbotRouterDuplex.BuyLeg[](1);
        legs[0] = _leg(USER_A, 100e18);
        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 1e18, DL);
        assertEq(totalOut, 1e18, "totalOut");
        assertEq(nFilled, 1, "nFilled");
        assertEq(btcb.balanceOf(USER_A), 1e18, "A btcb");
    }

    // 3 — skipped leg: revoked approval
    function test_buy_skipped_noApproval() public {
        vm.prank(USER_B);
        usdt.approve(address(router), 0);

        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_B, 1, 2);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 4e18, DL);

        assertEq(totalOut, 4e18, "A+C only (400 USDT -> 4 BTCB)");
        assertEq(nFilled, 2, "nFilled excludes B");
        assertEq(btcb.balanceOf(USER_B), 0, "B no btcb");
        assertEq(usdt.balanceOf(USER_B), 500e18, "B USDT intact");
        assertEq(btcb.balanceOf(USER_A), 1e18, "A btcb");
        assertEq(btcb.balanceOf(USER_C), 3e18, "C btcb");
        assertEq(btcb.balanceOf(address(router)), 0, "no BTCB stuck");
    }

    // 4 — skipped leg: approved but zero balance
    function test_buy_skipped_zeroBalance() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = new BtcbotRouterDuplex.BuyLeg[](3);
        legs[0] = _leg(USER_A, 100e18);
        legs[1] = _leg(USER_D, 200e18); // approved, holds 0 USDT
        legs[2] = _leg(USER_C, 300e18);

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_D, 1, 2);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 4e18, DL);
        assertEq(nFilled, 2, "nFilled");
        assertEq(btcb.balanceOf(USER_D), 0, "D got nothing");
        assertEq(totalOut, 4e18, "A + C only");
    }

    // 5 — skipped leg: zero amountIn
    function test_buy_skipped_zeroAmount() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = new BtcbotRouterDuplex.BuyLeg[](3);
        legs[0] = _leg(USER_A, 100e18);
        legs[1] = _leg(USER_B, 0);
        legs[2] = _leg(USER_C, 300e18);

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_B, 1, 1);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 4e18, DL);
        assertEq(nFilled, 2, "nFilled");
        assertEq(btcb.balanceOf(USER_B), 0, "B no btcb");
        assertEq(usdt.balanceOf(USER_B), 500e18, "B USDT intact");
    }

    // 6 — dust (indivisible total → truncation retained by the contract)
    function test_buy_dust() public {
        v3.setFixedOut(6e18 + 1);
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        (uint256 totalOut,) = router.batchSwapUsdtToBtcb(legs, 6e18, DL);
        assertEq(totalOut, 6e18 + 1, "totalOut = fixedOut");
        // pro-rata floors: 1e18 / 2e18 / 3e18 = 6e18 distributed, 1 wei dust.
        assertEq(btcb.balanceOf(USER_A), 1e18, "A");
        assertEq(btcb.balanceOf(USER_B), 2e18, "B");
        assertEq(btcb.balanceOf(USER_C), 3e18, "C");
        assertEq(btcb.balanceOf(address(router)), 1, "1 wei dust retained");
    }

    // 7 — conservation
    function test_buy_conservation() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        (uint256 totalOut,) = router.batchSwapUsdtToBtcb(legs, 6e18, DL);
        uint256 dist = btcb.balanceOf(USER_A) + btcb.balanceOf(USER_B) + btcb.balanceOf(USER_C);
        assertEq(dist + btcb.balanceOf(address(router)), totalOut, "conservation");
        assertEq(totalOut, 6e18, "totalOut");
    }

    // 8 — empty batch reverts
    function test_buy_emptyBatch_reverts() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = new BtcbotRouterDuplex.BuyLeg[](0);
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterDuplex.EmptyBatch.selector);
        router.batchSwapUsdtToBtcb(legs, 0, DL);
    }

    // 9 — all skipped → EmptyBatch (atomic, nothing pulled)
    function test_buy_allSkipped_reverts() public {
        vm.prank(USER_A);
        usdt.approve(address(router), 0);
        vm.prank(USER_B);
        usdt.approve(address(router), 0);

        BtcbotRouterDuplex.BuyLeg[] memory legs = new BtcbotRouterDuplex.BuyLeg[](2);
        legs[0] = _leg(USER_A, 100e18);
        legs[1] = _leg(USER_B, 200e18);

        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterDuplex.EmptyBatch.selector);
        router.batchSwapUsdtToBtcb(legs, 1, DL);
        assertEq(usdt.balanceOf(USER_A), 500e18, "A intact");
        assertEq(usdt.balanceOf(USER_B), 500e18, "B intact");
    }

    // 10 — only trader
    function test_buy_revertsWhenNotTrader() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(address(0xBAD));
        vm.expectRevert(BtcbotRouterDuplex.NotTrader.selector);
        router.batchSwapUsdtToBtcb(legs, 6e18, DL);
    }

    // 11 — paused
    function test_buy_revertsWhenPaused() public {
        vm.prank(OWNER);
        router.setPaused(true);
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterDuplex.IsPaused.selector);
        router.batchSwapUsdtToBtcb(legs, 6e18, DL);
    }

    // 12 — aggregate slippage → atomic revert (out 6 < floor 7)
    function test_buy_aggregateSlippage_atomicRevert() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        vm.expectRevert(); // mock V3 reverts: out 6e18 < minOut 7e18
        router.batchSwapUsdtToBtcb(legs, 7e18, DL);
        assertEq(usdt.balanceOf(USER_A), 500e18, "A USDT intact (rolled back)");
        assertEq(btcb.balanceOf(USER_A), 0, "A no btcb");
        assertEq(usdt.balanceOf(address(router)), 0, "router no USDT");
    }

    // 13 — expired deadline → Expired (modifier runs before any pull)
    function test_buy_expiredDeadline_reverts() public {
        BtcbotRouterDuplex.BuyLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterDuplex.Expired.selector);
        router.batchSwapUsdtToBtcb(legs, 6e18, block.timestamp - 1);
        assertEq(usdt.balanceOf(USER_A), 500e18, "A intact (nothing pulled)");
        assertEq(btcb.balanceOf(USER_A), 0, "A no btcb");
    }
}
