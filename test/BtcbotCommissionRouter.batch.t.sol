// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotCommissionRouter} from "../src/BtcbotCommissionRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";

/// @title BtcbotCommissionRouter — batchSwapAndDistribute (Tier 2 cross-user batch) tests
/// @notice Verifies every guardrail of the V3 batch SELL path on the LIVE contract base:
///         one bad leg never sinks the batch, per-leg pro-rata + commission, self-pay /
///         failover-to-root, per-leg cap = SKIP-not-revert, dust accounting, and the revert
///         paths (empty / all-skipped / not-trader / paused / aggregate slippage atomicity).
///
/// Setup conventions:
///   - 1 BTCB = 100 USDT (clean math; both tokens 18 decimals)
///   - Three users A/B/C funded with BTCB, pre-approve THE ROUTER for max
///   - Each user has DISTINCT tiers 1..5 + the SHARED global ROOT, so per-leg routing
///     is provable (each user's commission must reach that user's own upline)
contract BtcbotCommissionRouterBatchTest is Test {
    BtcbotCommissionRouter router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockV3SwapRouter v3;

    // Re-declared events (Foundry needs them in scope for vm.expectEmit).
    event BatchSwapAndDistribute(uint256 totalBtcbIn, uint256 totalUsdtOut, uint256 nFilled, uint256 nSkipped);
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);
    event LegCommissionSkipped(address indexed user, uint256 attemptedCommission, uint256 userGross);
    event TierSelfPaySkipped(address indexed user, uint8 tier, uint256 amount);
    event TierFailoverToRoot(address indexed user, address indexed originalRecipient, uint8 tier, uint256 amount);

    address constant TRADER = address(0xA77ade2);
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);

    address constant USER_A = address(0xA1);
    address constant USER_B = address(0xB1);
    address constant USER_C = address(0xC1);
    address constant USER_D = address(0xD1); // approves but has ZERO BTCB

    address constant AT1 = address(0xA101);
    address constant AT2 = address(0xA102);
    address constant AT3 = address(0xA103);
    address constant AT4 = address(0xA104);
    address constant AT5 = address(0xA105);
    address constant BT1 = address(0xB101);
    address constant BT2 = address(0xB102);
    address constant BT3 = address(0xB103);
    address constant BT4 = address(0xB104);
    address constant BT5 = address(0xB105);
    address constant CT1 = address(0xC101);
    address constant CT2 = address(0xC102);
    address constant CT3 = address(0xC103);
    address constant CT4 = address(0xC104);
    address constant CT5 = address(0xC105);

    uint256 constant RATE_BTCB_USDT = 100e18; // 100 USDT per 1 BTCB

    function setUp() public {
        btcb = new MockERC20("BTCB", "BTCB", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        v3 = new MockV3SwapRouter();

        router = new BtcbotCommissionRouter(
            address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER
        );

        v3.setRate(address(btcb), address(usdt), RATE_BTCB_USDT);
        // V3 mock mints output; no liquidity needed, but mirror realism.
        usdt.mint(address(v3), 100_000e18);

        btcb.mint(USER_A, 5e18);
        btcb.mint(USER_B, 5e18);
        btcb.mint(USER_C, 5e18);

        vm.prank(USER_A);
        btcb.approve(address(router), type(uint256).max);
        vm.prank(USER_B);
        btcb.approve(address(router), type(uint256).max);
        vm.prank(USER_C);
        btcb.approve(address(router), type(uint256).max);
        vm.prank(USER_D);
        btcb.approve(address(router), type(uint256).max);
    }

    // ── Leg builders ──────────────────────────────────────────────────

    function _leg(address u, uint256 amtIn, address[6] memory tiers, uint256[6] memory parts)
        internal
        pure
        returns (BtcbotCommissionRouter.UserLeg memory leg)
    {
        leg.user = u;
        leg.amountIn = amtIn;
        leg.tierRecipients = tiers;
        leg.parts = parts;
    }

    function _legA() internal pure returns (BtcbotCommissionRouter.UserLeg memory) {
        return _leg(USER_A, 1e18, [AT1, AT2, AT3, AT4, AT5, ROOT], [uint256(8e18), 4e18, 2e18, 1e18, 1e18, 4e18]);
    }

    function _legB() internal pure returns (BtcbotCommissionRouter.UserLeg memory) {
        return _leg(USER_B, 2e18, [BT1, BT2, BT3, BT4, BT5, ROOT], [uint256(16e18), 8e18, 4e18, 2e18, 2e18, 8e18]);
    }

    function _legC() internal pure returns (BtcbotCommissionRouter.UserLeg memory) {
        return _leg(USER_C, 3e18, [CT1, CT2, CT3, CT4, CT5, ROOT], [uint256(24e18), 12e18, 6e18, 3e18, 3e18, 12e18]);
    }

    function _threeLegs() internal pure returns (BtcbotCommissionRouter.UserLeg[] memory legs) {
        legs = new BtcbotCommissionRouter.UserLeg[](3);
        legs[0] = _legA();
        legs[1] = _legB();
        legs[2] = _legC();
    }

    // 1 — happy multi-leg
    function test_batch_happyMultiLeg() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();

        vm.expectEmit(false, false, false, true, address(router));
        emit BatchSwapAndDistribute(6e18, 600e18, 3, 0);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 600e18);

        assertEq(totalOut, 600e18, "totalUsdtOut");
        assertEq(nFilled, 3, "nFilled");

        assertEq(usdt.balanceOf(USER_A), 80e18, "A net");
        assertEq(usdt.balanceOf(USER_B), 160e18, "B net");
        assertEq(usdt.balanceOf(USER_C), 240e18, "C net");

        assertEq(btcb.balanceOf(USER_A), 4e18, "A btcb");
        assertEq(btcb.balanceOf(USER_B), 3e18, "B btcb");
        assertEq(btcb.balanceOf(USER_C), 2e18, "C btcb");

        assertEq(usdt.balanceOf(AT1), 8e18, "A T1");
        assertEq(usdt.balanceOf(AT2), 4e18, "A T2");
        assertEq(usdt.balanceOf(BT1), 16e18, "B T1");
        assertEq(usdt.balanceOf(CT1), 24e18, "C T1");
        assertEq(usdt.balanceOf(ROOT), 24e18, "ROOT aggregate");

        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
        assertEq(btcb.balanceOf(address(router)), 0, "no BTCB stuck");
    }

    // 2 — single-leg batch
    function test_batch_singleLeg() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](1);
        legs[0] = _legA();

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 100e18);

        assertEq(totalOut, 100e18, "totalOut");
        assertEq(nFilled, 1, "nFilled");
        assertEq(usdt.balanceOf(USER_A), 80e18, "A net");
        assertEq(usdt.balanceOf(AT1), 8e18, "A T1");
        assertEq(usdt.balanceOf(ROOT), 4e18, "ROOT");
    }

    // 3 — skipped leg: revoked approval
    function test_batch_skippedLeg_noApproval() public {
        vm.prank(USER_B);
        btcb.approve(address(router), 0);

        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_B, 1, 2);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 400e18);

        assertEq(totalOut, 400e18, "totalOut excludes B");
        assertEq(nFilled, 2, "nFilled excludes B");

        assertEq(btcb.balanceOf(USER_B), 5e18, "B BTCB intact");
        assertEq(usdt.balanceOf(USER_B), 0, "B no USDT");
        assertEq(usdt.balanceOf(BT1), 0, "B T1 unpaid");

        assertEq(usdt.balanceOf(USER_A), 80e18, "A net");
        assertEq(usdt.balanceOf(USER_C), 240e18, "C net");
        assertEq(usdt.balanceOf(ROOT), 16e18, "ROOT excludes B");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
    }

    // 4 — skipped leg: approved but zero balance
    function test_batch_skippedLeg_zeroBalance() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](3);
        legs[0] = _legA();
        legs[1] = _leg(USER_D, 2e18, [BT1, BT2, BT3, BT4, BT5, ROOT], [uint256(16e18), 8e18, 4e18, 2e18, 2e18, 8e18]);
        legs[2] = _legC();

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_D, 1, 2);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 400e18);

        assertEq(totalOut, 400e18, "totalOut excludes D");
        assertEq(nFilled, 2, "nFilled");
        assertEq(usdt.balanceOf(USER_D), 0, "D got nothing");
        assertEq(usdt.balanceOf(USER_A), 80e18, "A net");
        assertEq(usdt.balanceOf(USER_C), 240e18, "C net");
    }

    // 5 — skipped leg: zero amountIn
    function test_batch_skippedLeg_zeroAmount() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](3);
        legs[0] = _legA();
        legs[1] = _leg(USER_B, 0, [BT1, BT2, BT3, BT4, BT5, ROOT], [uint256(0), 0, 0, 0, 0, 0]);
        legs[2] = _legC();

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER_B, 1, 1);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 400e18);

        assertEq(totalOut, 400e18, "A + C only");
        assertEq(nFilled, 2, "nFilled");
        assertEq(btcb.balanceOf(USER_B), 5e18, "B BTCB intact");
        assertEq(usdt.balanceOf(USER_B), 0, "B no USDT");
    }

    // 6 — self-pay
    function test_batch_selfPay() public {
        BtcbotCommissionRouter.UserLeg memory la = _legA();
        la.tierRecipients[0] = USER_A;

        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](1);
        legs[0] = la;

        vm.expectEmit(true, false, false, true, address(router));
        emit TierSelfPaySkipped(USER_A, 1, 8e18);

        vm.prank(TRADER);
        router.batchSwapAndDistribute(legs, 100e18);

        assertEq(usdt.balanceOf(USER_A), 88e18, "A net + self-pay");
        assertEq(usdt.balanceOf(AT1), 0, "original T1 unpaid (was self)");
        assertEq(usdt.balanceOf(ROOT), 4e18, "ROOT still paid");
    }

    // 7 — failover-to-root
    function test_batch_failoverToRoot() public {
        usdt.setBlacklisted(BT3, true);

        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();

        vm.expectEmit(true, true, false, true, address(router));
        emit TierFailoverToRoot(USER_B, BT3, 3, 4e18);

        vm.prank(TRADER);
        router.batchSwapAndDistribute(legs, 600e18);

        assertEq(usdt.balanceOf(BT3), 0, "B T3 unpaid (blacklisted)");
        assertEq(usdt.balanceOf(ROOT), 28e18, "ROOT own + B T3 failover");
        assertEq(usdt.balanceOf(BT1), 16e18, "B T1 ok");
        assertEq(usdt.balanceOf(USER_B), 160e18, "B net unchanged");
    }

    // 8 — per-leg cap: SKIP-not-revert
    function test_batch_perLegCapSkipped() public {
        BtcbotCommissionRouter.UserLeg memory lb = _legB();
        lb.parts = [uint256(20e18), 20e18, 20e18, 10e18, 5e18, 5e18]; // 80 on 200 gross = 40% > 35%

        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](3);
        legs[0] = _legA();
        legs[1] = lb;
        legs[2] = _legC();

        vm.expectEmit(true, false, false, true, address(router));
        emit LegCommissionSkipped(USER_B, 80e18, 200e18);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 600e18);

        assertEq(nFilled, 3, "B still filled (only its commission skipped)");
        assertEq(usdt.balanceOf(USER_B), 200e18, "B full gross");
        assertEq(usdt.balanceOf(BT1), 0, "B T1 unpaid (commission skipped)");
        assertEq(usdt.balanceOf(USER_A), 80e18, "A net");
        assertEq(usdt.balanceOf(USER_C), 240e18, "C net");
        assertEq(usdt.balanceOf(ROOT), 16e18, "ROOT excludes B");
        assertEq(totalOut, 600e18, "totalOut");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
    }

    // 9 — dust
    function test_batch_dust() public {
        v3.setFixedOut(100e18 + 1);

        uint256[6] memory noComm = [uint256(0), 0, 0, 0, 0, 0];
        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](3);
        legs[0] = _leg(USER_A, 1e18, [AT1, AT2, AT3, AT4, AT5, ROOT], noComm);
        legs[1] = _leg(USER_B, 1e18, [BT1, BT2, BT3, BT4, BT5, ROOT], noComm);
        legs[2] = _leg(USER_C, 1e18, [CT1, CT2, CT3, CT4, CT5, ROOT], noComm);

        vm.prank(TRADER);
        (uint256 totalOut,) = router.batchSwapAndDistribute(legs, 100e18);

        assertEq(totalOut, 100e18 + 1, "totalOut = fixedOut");
        uint256 each = 33333333333333333333;
        assertEq(usdt.balanceOf(USER_A), each, "A pro-rata");
        assertEq(usdt.balanceOf(USER_B), each, "B pro-rata");
        assertEq(usdt.balanceOf(USER_C), each, "C pro-rata");
        assertEq(usdt.balanceOf(address(router)), 2, "2 wei dust retained");
        assertEq(each * 3 + 2, totalOut, "conservation incl. dust");
    }

    // 10 — conservation
    function test_batch_conservation() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();

        vm.prank(TRADER);
        (uint256 totalOut,) = router.batchSwapAndDistribute(legs, 600e18);

        uint256 distributed = usdt.balanceOf(USER_A) + usdt.balanceOf(USER_B) + usdt.balanceOf(USER_C)
            + usdt.balanceOf(AT1) + usdt.balanceOf(AT2) + usdt.balanceOf(AT3) + usdt.balanceOf(AT4)
            + usdt.balanceOf(AT5) + usdt.balanceOf(BT1) + usdt.balanceOf(BT2) + usdt.balanceOf(BT3)
            + usdt.balanceOf(BT4) + usdt.balanceOf(BT5) + usdt.balanceOf(CT1) + usdt.balanceOf(CT2)
            + usdt.balanceOf(CT3) + usdt.balanceOf(CT4) + usdt.balanceOf(CT5) + usdt.balanceOf(ROOT);

        assertEq(distributed + usdt.balanceOf(address(router)), totalOut, "conservation");
        assertEq(totalOut, 600e18, "totalOut");
    }

    // 11 — empty batch reverts
    function test_batch_emptyBatch_reverts() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](0);
        vm.prank(TRADER);
        vm.expectRevert(BtcbotCommissionRouter.EmptyBatch.selector);
        router.batchSwapAndDistribute(legs, 0);
    }

    // 12 — all skipped → EmptyBatch (atomic)
    function test_batch_allSkipped_reverts() public {
        vm.prank(USER_A);
        btcb.approve(address(router), 0);
        vm.prank(USER_B);
        btcb.approve(address(router), 0);

        BtcbotCommissionRouter.UserLeg[] memory legs = new BtcbotCommissionRouter.UserLeg[](2);
        legs[0] = _legA();
        legs[1] = _legB();

        vm.prank(TRADER);
        vm.expectRevert(BtcbotCommissionRouter.EmptyBatch.selector);
        router.batchSwapAndDistribute(legs, 1);

        assertEq(btcb.balanceOf(USER_A), 5e18, "A intact");
        assertEq(btcb.balanceOf(USER_B), 5e18, "B intact");
    }

    // 13 — only trader
    function test_batch_revertsWhenNotTrader() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();
        vm.prank(address(0xBAD));
        vm.expectRevert(BtcbotCommissionRouter.NotTrader.selector);
        router.batchSwapAndDistribute(legs, 600e18);
    }

    // 14 — pause
    function test_batch_revertsWhenPaused() public {
        vm.prank(OWNER);
        router.setPaused(true);

        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotCommissionRouter.IsPaused.selector);
        router.batchSwapAndDistribute(legs, 600e18);
    }

    // 15 — aggregate slippage → atomic revert
    function test_batch_aggregateSlippage_atomicRevert() public {
        BtcbotCommissionRouter.UserLeg[] memory legs = _threeLegs();

        vm.prank(TRADER);
        vm.expectRevert(); // mock V3 reverts: out 600 < floor 700
        router.batchSwapAndDistribute(legs, 700e18);

        assertEq(btcb.balanceOf(USER_A), 5e18, "A intact");
        assertEq(btcb.balanceOf(USER_B), 5e18, "B intact");
        assertEq(btcb.balanceOf(USER_C), 5e18, "C intact");
        assertEq(usdt.balanceOf(USER_A), 0, "A no USDT");
        assertEq(usdt.balanceOf(ROOT), 0, "ROOT no USDT");
        assertEq(btcb.balanceOf(address(router)), 0, "router no BTCB");
    }
}
