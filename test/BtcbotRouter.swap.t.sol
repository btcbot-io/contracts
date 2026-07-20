// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotRouter} from "../src/BtcbotRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPancakeRouter} from "./mocks/MockPancakeRouter.sol";

/// @title BtcbotRouter — swap & fan-out tests
/// @notice 12 core tests covering happy path, conservation, self-pay short-circuit,
///         failover-to-root, slippage, cap, pause/auth, atomicity, buy path.
///
/// Setup conventions:
///   - 1 BTCB = 100 USDT (clean math; both tokens 18 decimals)
///   - User has 10 BTCB and 1000 USDT pre-funded
///   - User pre-approves THE ROUTER for max on both tokens (direct approve pattern)
///   - 6 tier recipients (T1..T5, ROOT); USER is distinct from all of them by default
contract BtcbotRouterSwapTest is Test {
    BtcbotRouter router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockPancakeRouter pancake;

    address constant TRADER = address(0xA77ade2);
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);
    address constant USER = address(0xC5e72);

    // Tier recipients
    address constant T1 = address(0xC1);
    address constant T2 = address(0xC2);
    address constant T3 = address(0xC3);
    address constant T4 = address(0xC4);
    address constant T5 = address(0xC5);

    address[6] DEFAULT_TIERS = [T1, T2, T3, T4, T5, ROOT];

    // Clean numbers: 1 BTCB → 100 USDT.
    uint256 constant RATE_BTCB_USDT = 100e18;        // 100 USDT per 1 BTCB, both 18 dec
    uint256 constant AMOUNT_IN = 1e18;                // 1 BTCB
    uint256 constant EXPECTED_GROSS = 100e18;         // 100 USDT
    // Commission target 20% on this trade (well under 35% cap):
    //   T1=8, T2=4, T3=2, T4=1, T5=1, ROOT=4 → total 20 USDT
    uint256[6] DEFAULT_PARTS = [
        uint256(8e18),
        uint256(4e18),
        uint256(2e18),
        uint256(1e18),
        uint256(1e18),
        uint256(4e18)
    ];
    uint256 constant DEFAULT_TOTAL_COMMISSION = 20e18;
    uint256 constant DEFAULT_USER_NET = 80e18;        // EXPECTED_GROSS - DEFAULT_TOTAL_COMMISSION

    function setUp() public {
        btcb = new MockERC20("BTCB", "BTCB", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        pancake = new MockPancakeRouter();

        router = new BtcbotRouter(
            address(btcb),
            address(usdt),
            address(pancake),
            TRADER,
            ROOT,
            OWNER
        );

        // Mock pancake rates (both directions)
        pancake.setRate(address(btcb), address(usdt), RATE_BTCB_USDT);
        // 1 USDT = 0.01 BTCB → in 1e18 fixed-point: (1e18 * 1e18) / 100e18 = 1e16
        pancake.setRate(address(usdt), address(btcb), 1e16);

        // Mock pancake also needs liquidity to fulfill swaps
        btcb.mint(address(pancake), 1_000e18);
        usdt.mint(address(pancake), 100_000e18);

        // Fund user
        btcb.mint(USER, 10e18);
        usdt.mint(USER, 1000e18);

        // User pre-approves THE ROUTER directly (direct ERC20 approve pattern).
        // No Permit2 — onboarding flow is: user does these two approvals once, done.
        vm.startPrank(USER);
        btcb.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _defaultParts() internal view returns (uint256[6] memory p) {
        p[0] = DEFAULT_PARTS[0];
        p[1] = DEFAULT_PARTS[1];
        p[2] = DEFAULT_PARTS[2];
        p[3] = DEFAULT_PARTS[3];
        p[4] = DEFAULT_PARTS[4];
        p[5] = DEFAULT_PARTS[5];
    }

    function _defaultTiers() internal view returns (address[6] memory t) {
        t[0] = DEFAULT_TIERS[0];
        t[1] = DEFAULT_TIERS[1];
        t[2] = DEFAULT_TIERS[2];
        t[3] = DEFAULT_TIERS[3];
        t[4] = DEFAULT_TIERS[4];
        t[5] = DEFAULT_TIERS[5];
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 1 — happy path
    // ─────────────────────────────────────────────────────────────────
    function test_swap_happyPath() public {
        uint256 userBtcbBefore = btcb.balanceOf(USER);
        uint256 userUsdtBefore = usdt.balanceOf(USER);

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(
            USER,
            AMOUNT_IN,
            DEFAULT_USER_NET,
            _defaultTiers(),
            _defaultParts()
        );

        assertEq(userReceived, DEFAULT_USER_NET, "userReceived == user net");
        assertEq(btcb.balanceOf(USER), userBtcbBefore - AMOUNT_IN, "user BTCB debited");
        assertEq(usdt.balanceOf(USER), userUsdtBefore + DEFAULT_USER_NET, "user USDT credited net");

        // Each tier received its slice
        assertEq(usdt.balanceOf(T1), DEFAULT_PARTS[0], "T1 paid");
        assertEq(usdt.balanceOf(T2), DEFAULT_PARTS[1], "T2 paid");
        assertEq(usdt.balanceOf(T3), DEFAULT_PARTS[2], "T3 paid");
        assertEq(usdt.balanceOf(T4), DEFAULT_PARTS[3], "T4 paid");
        assertEq(usdt.balanceOf(T5), DEFAULT_PARTS[4], "T5 paid");
        assertEq(usdt.balanceOf(ROOT), DEFAULT_PARTS[5], "ROOT paid");

        // Contract holds nothing after the swap
        assertEq(btcb.balanceOf(address(router)), 0, "no BTCB stuck in router");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck in router");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 2 — conservation across the fan-out
    // ─────────────────────────────────────────────────────────────────
    function test_swap_conservation() public {
        uint256[6] memory parts = _defaultParts();
        address[6] memory tiers = _defaultTiers();

        uint256 routerBalanceBefore = usdt.balanceOf(address(router));

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, tiers, parts
        );

        uint256 totalOut;
        for (uint256 i = 0; i < 6; i++) totalOut += parts[i];
        totalOut += userReceived;

        assertEq(totalOut, EXPECTED_GROSS, "sum(parts) + userReceived == usdtOut");
        assertEq(usdt.balanceOf(address(router)), routerBalanceBefore, "router USDT balance unchanged");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 3 — self-pay on a single tier
    // ─────────────────────────────────────────────────────────────────
    function test_swap_selfPay_singleTier() public {
        // Make USER their own T1 referrer.
        address[6] memory tiers = _defaultTiers();
        tiers[0] = USER;

        uint256 userUsdtBefore = usdt.balanceOf(USER);

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, tiers, _defaultParts()
        );

        // userReceived = baseline 80 + the 8 that would have gone to T1 = 88
        assertEq(userReceived, DEFAULT_USER_NET + DEFAULT_PARTS[0], "self-pay credit");
        assertEq(
            usdt.balanceOf(USER),
            userUsdtBefore + DEFAULT_USER_NET + DEFAULT_PARTS[0],
            "user gets baseline + self-pay slice"
        );
        // Other tiers paid normally.
        assertEq(usdt.balanceOf(T2), DEFAULT_PARTS[1], "T2 still paid");
        assertEq(usdt.balanceOf(ROOT), DEFAULT_PARTS[5], "ROOT still paid");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 4 — self-pay on all tiers (root invitee edge case)
    // ─────────────────────────────────────────────────────────────────
    function test_swap_selfPay_allTiers() public {
        // All 6 tiers point to USER (edge case: USER is at every position).
        address[6] memory tiers;
        for (uint256 i = 0; i < 6; i++) tiers[i] = USER;

        uint256 userUsdtBefore = usdt.balanceOf(USER);

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, tiers, _defaultParts()
        );

        // userReceived = full gross since everything self-pays
        assertEq(userReceived, EXPECTED_GROSS, "all-self-pay returns full gross");
        assertEq(usdt.balanceOf(USER), userUsdtBefore + EXPECTED_GROSS, "user gets everything");

        // No tier recipient was credited (other than USER).
        for (uint256 i = 0; i < 6; i++) {
            if (DEFAULT_TIERS[i] != USER && DEFAULT_TIERS[i] != ROOT) {
                assertEq(usdt.balanceOf(DEFAULT_TIERS[i]), 0, "no separate tier transfer");
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 5 — failover on revert (blacklist)
    // ─────────────────────────────────────────────────────────────────
    function test_swap_failover_onRevert() public {
        // T3 is blacklisted on USDT → any transfer to T3 reverts.
        usdt.setBlacklisted(T3, true);

        uint256 rootUsdtBefore = usdt.balanceOf(ROOT);

        vm.prank(TRADER);
        router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, _defaultTiers(), _defaultParts()
        );

        // T3 received nothing; its slice was routed to ROOT.
        assertEq(usdt.balanceOf(T3), 0, "T3 not paid (blacklisted)");
        // ROOT received its own slice + T3's failover slice
        assertEq(
            usdt.balanceOf(ROOT),
            rootUsdtBefore + DEFAULT_PARTS[5] + DEFAULT_PARTS[2],
            "ROOT received own + T3 failover"
        );
        // Other tiers paid normally
        assertEq(usdt.balanceOf(T1), DEFAULT_PARTS[0], "T1 ok");
        assertEq(usdt.balanceOf(T2), DEFAULT_PARTS[1], "T2 ok");
        assertEq(usdt.balanceOf(T4), DEFAULT_PARTS[3], "T4 ok");
        assertEq(usdt.balanceOf(T5), DEFAULT_PARTS[4], "T5 ok");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 6 — failover on returns-false (silent failure)
    // ─────────────────────────────────────────────────────────────────
    function test_swap_failover_onReturnsFalse() public {
        // Make USDT silently fail when transferring to T5 (returns false, no revert).
        usdt.setReturnsFalseTo(T5, true);

        uint256 rootUsdtBefore = usdt.balanceOf(ROOT);

        vm.prank(TRADER);
        router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, _defaultTiers(), _defaultParts()
        );

        assertEq(usdt.balanceOf(T5), 0, "T5 not paid (silent failure)");
        assertEq(
            usdt.balanceOf(ROOT),
            rootUsdtBefore + DEFAULT_PARTS[5] + DEFAULT_PARTS[4],
            "ROOT received own + T5 failover"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 7 — commission above cap reverts
    // ─────────────────────────────────────────────────────────────────
    function test_swap_revertsOnCommissionAboveCap() public {
        // Sum 40 USDT of commission on a 100 USDT trade = 40% > 35% MAX_COMMISSION_BPS.
        uint256[6] memory parts;
        parts[0] = 10e18;
        parts[1] = 10e18;
        parts[2] = 10e18;
        parts[3] = 5e18;
        parts[4] = 4e18;
        parts[5] = 1e18;   // total 40e18 = 40% — over 35% cap

        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouter.CommissionTooHigh.selector);
        router.swapAndDistribute(
            USER, AMOUNT_IN, 60e18, _defaultTiers(), parts
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 8 — slippage revert
    // ─────────────────────────────────────────────────────────────────
    function test_swap_revertsOnSlippage() public {
        // Ask for 120 USDT net — Pancake will only return 100 gross. With H1 applied,
        // the Pancake floor is `120 + 20 = 140`, which the mock pancake will reject.
        vm.prank(TRADER);
        vm.expectRevert();   // accept either Pancake's revert or InsufficientOutput
        router.swapAndDistribute(
            USER, AMOUNT_IN, 120e18, _defaultTiers(), _defaultParts()
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 9 — only the trader can call
    // ─────────────────────────────────────────────────────────────────
    function test_swap_revertsWhenNotTrader() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(BtcbotRouter.NotTrader.selector);
        router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, _defaultTiers(), _defaultParts()
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 10 — pause halts swaps
    // ─────────────────────────────────────────────────────────────────
    function test_swap_revertsWhenPaused() public {
        vm.prank(OWNER);
        router.setPaused(true);

        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouter.IsPaused.selector);
        router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, _defaultTiers(), _defaultParts()
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 11 — atomicity on swap failure
    // ─────────────────────────────────────────────────────────────────
    function test_swap_atomicityOnSwapFail() public {
        // Pancake reverts mid-swap → user's BTCB unchanged, no commission transfers.
        pancake.setSwapReverts(true);

        uint256 userBtcbBefore = btcb.balanceOf(USER);
        uint256 userUsdtBefore = usdt.balanceOf(USER);

        vm.prank(TRADER);
        vm.expectRevert();
        router.swapAndDistribute(
            USER, AMOUNT_IN, DEFAULT_USER_NET, _defaultTiers(), _defaultParts()
        );

        // Atomic revert: everything as before
        assertEq(btcb.balanceOf(USER), userBtcbBefore, "BTCB unchanged");
        assertEq(usdt.balanceOf(USER), userUsdtBefore, "USDT unchanged");
        assertEq(usdt.balanceOf(T1), 0, "T1 unchanged");
        assertEq(usdt.balanceOf(ROOT), 0, "ROOT unchanged");
        assertEq(btcb.balanceOf(address(router)), 0, "router has no BTCB");
        assertEq(usdt.balanceOf(address(router)), 0, "router has no USDT");
    }

    // ─────────────────────────────────────────────────────────────────
    // Test 12 — BUY (swapUsdtToBtcb) happy path
    // ─────────────────────────────────────────────────────────────────
    function test_buy_happyPath() public {
        // 100 USDT in → 1 BTCB out (rate 1 USDT = 0.01 BTCB)
        uint256 usdtIn = 100e18;
        uint256 expectedBtcbOut = 1e18;

        uint256 userBtcbBefore = btcb.balanceOf(USER);
        uint256 userUsdtBefore = usdt.balanceOf(USER);

        vm.prank(TRADER);
        uint256 btcbOut = router.swapUsdtToBtcb(USER, usdtIn, expectedBtcbOut);

        assertEq(btcbOut, expectedBtcbOut, "btcbOut matches");
        assertEq(usdt.balanceOf(USER), userUsdtBefore - usdtIn, "user USDT debited");
        assertEq(btcb.balanceOf(USER), userBtcbBefore + expectedBtcbOut, "user BTCB credited");
        // No commission on BUYs, router holds nothing
        assertEq(btcb.balanceOf(address(router)), 0, "no BTCB stuck");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
    }
}
