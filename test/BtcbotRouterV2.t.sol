// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotRouterV2} from "../src/BtcbotRouterV2.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @title BtcbotRouterV2 — core tests for the Blockaid-hardening logic.
/// @notice Exercises the NEW gates: EIP-712 session mandate (register / expiry / cancel /
///         USD-notional per-trade cap), the Chainlink oracle floor (#7) + staleness, the
///         on-chain referral-tree fan-out (#6), the per-leg batch mandate gate, and the
///         48h setSwapRouter timelock (#5). Setup: BTC = $60,000; both tokens 18-dec.
contract BtcbotRouterV2Test is Test {
    BtcbotRouterV2 router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockV3SwapRouter v3;
    MockAggregatorV3 oracle;
    MockAggregatorV3 usdtOracle;

    event MandateRegistered(address indexed user, uint96 nonce, uint64 expiry);
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);

    uint256 constant TRADER_PK = 0xA77;
    uint256 constant USER_PK = 0x5151;
    uint256 constant USER2_PK = 0x5252;
    address TRADER;
    address USER;
    address USER2;
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);
    address constant UP1 = address(0x1101);
    address constant UP2 = address(0x1102);

    int256 constant BTC_USD = 60000e8; // feed 8-dec
    uint256 constant SELL_RATE = 60000e18; // 1 BTCB -> 60000 USDT
    uint256 constant BUY_RATE = uint256(1e18) / 60000; // 1 USDT -> ~1/60000 BTCB
    uint256 constant DL = type(uint256).max;
    uint64 EXP; // mandate expiry

    function setUp() public {
        vm.warp(1_000_000);
        TRADER = vm.addr(TRADER_PK);
        USER = vm.addr(USER_PK);
        USER2 = vm.addr(USER2_PK);
        EXP = uint64(block.timestamp + 90 days);

        btcb = new MockERC20("BTCB", "BTCB", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        v3 = new MockV3SwapRouter();
        oracle = new MockAggregatorV3(8, BTC_USD);
        usdtOracle = new MockAggregatorV3(8, int256(1e8)); // USDT = $1.00

        router = new BtcbotRouterV2(
            address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER, address(oracle), address(usdtOracle)
        );
        vm.prank(OWNER);
        router.setPaused(false); // contract ships paused (audit L-01)

        v3.setRate(address(btcb), address(usdt), SELL_RATE);
        v3.setRate(address(usdt), address(btcb), BUY_RATE);

        usdt.mint(USER, 2_000_000e18);
        btcb.mint(USER, 100e18);
        usdt.mint(USER2, 2_000_000e18);
        btcb.mint(USER2, 100e18);

        vm.startPrank(USER);
        usdt.approve(address(router), type(uint256).max);
        btcb.approve(address(router), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(USER2);
        usdt.approve(address(router), type(uint256).max);
        btcb.approve(address(router), type(uint256).max);
        vm.stopPrank();

        // tree: USER tier1=UP1, tier2=UP2
        address[5] memory up;
        up[0] = UP1;
        up[1] = UP2;
        vm.prank(OWNER);
        router.setUplines(USER, up);

        _register(_mk(USER, 1_000_000e18, 3000, 200, EXP, 1)); // default generous mandate
    }

    // ── helpers ──
    function _mk(address user, uint256 maxNotional, uint16 commBps, uint16 slipBps, uint64 expiry, uint96 nonce)
        internal
        pure
        returns (BtcbotRouterV2.TradeMandate memory m)
    {
        m.user = user;
        m.maxNotionalPerTrade = maxNotional;
        m.maxCumulativeNotional = type(uint256).max; // no cumulative limit unless a test overrides
        m.maxCommissionBps = commBps;
        m.maxSlippageBps = slipBps;
        m.expiry = expiry;
        m.nonce = nonce;
    }

    function _sign(BtcbotRouterV2.TradeMandate memory m, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.mandateDigest(m));
        return abi.encodePacked(r, s, v);
    }

    function _register(BtcbotRouterV2.TradeMandate memory m) internal {
        router.registerMandate(m, _sign(m, m.user == USER2 ? USER2_PK : USER_PK));
    }

    function _emptyParts() internal pure returns (uint256[6] memory p) {}

    // ── mandate registration ──
    function test_register_storesAndEmits() public {
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 500e18, 3000, 100, EXP, 2);
        vm.expectEmit(true, false, false, true, address(router));
        emit MandateRegistered(USER, 2, EXP);
        _register(m);
        (address u, uint256 mn,,,,,) = router.mandates(USER);
        assertEq(u, USER, "stored user");
        assertEq(mn, 500e18, "stored notional cap");
    }

    function test_register_badSig_reverts() public {
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 500e18, 3000, 100, EXP, 3);
        bytes memory badSig = _sign(m, TRADER_PK); // wrong signer; compute (incl. digest view call) FIRST
        vm.expectRevert(BtcbotRouterV2.BadSignature.selector);
        router.registerMandate(m, badSig);
    }

    // ── single buy / sell happy paths ──
    function test_buy_happy() public {
        vm.prank(TRADER);
        uint256 out = router.swapUsdtToBtcb(USER, 60000e18, 0, DL);
        assertApproxEqAbs(out, 1e18, 1e12, "~1 BTCB out");
        assertEq(btcb.balanceOf(USER), 100e18 + out, "user credited BTCB");
    }

    function test_sell_happy_treeFanOut() public {
        uint256[6] memory parts = _emptyParts();
        parts[0] = 100e18; // tier1 -> UP1
        parts[1] = 50e18; // tier2 -> UP2
        parts[5] = 200e18; // root -> ROOT
        vm.prank(TRADER);
        uint256 userRecv = router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(usdt.balanceOf(UP1), 100e18, "UP1 tier1");
        assertEq(usdt.balanceOf(UP2), 50e18, "UP2 tier2");
        assertEq(usdt.balanceOf(ROOT), 200e18, "ROOT");
        assertEq(userRecv, 60000e18 - 350e18, "user remainder");
        assertEq(usdt.balanceOf(USER), 2_000_000e18 + userRecv, "user credited");
        assertEq(usdt.balanceOf(address(router)), 0, "no USDT stuck");
    }

    // ── oracle floor (#7) ──
    function test_sell_oracleFloor_reverts() public {
        v3.setFixedOut(50000e18); // below floor 60000*0.98 = 58800
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(); // MockV3 reverts: out < amountOutMinimum (the oracle floor)
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_oracleStale_reverts() public {
        oracle.setUpdatedAt(block.timestamp - 2 hours); // > maxOracleAge (1h)
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.OracleStale.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    // ── mandate gates ──
    function test_noMandate_reverts() public {
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.NoMandate.selector);
        router.swapAndDistribute(USER2, 1e18, 0, parts, DL); // USER2 has no mandate
    }

    function test_expiredMandate_reverts() public {
        vm.warp(uint256(EXP) + 1);
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.MandateExpired.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_exceedsNotional_reverts() public {
        _register(_mk(USER, 1000e18, 3000, 200, EXP, 2)); // cap $1000
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ExceedsPerTrade.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 1 BTCB = $60k > $1k cap
    }

    function test_cancelMandate_blocksSwap() public {
        vm.prank(USER);
        router.cancelMandate();
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.NoMandate.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_commissionCap_reverts() public {
        _register(_mk(USER, 1_000_000e18, 100, 200, EXP, 2)); // commission cap 1% of proceeds
        uint256[6] memory parts = _emptyParts();
        parts[5] = 1000e18; // 1000 / 60000 = 1.67% > 1%
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.CommissionTooHigh.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_onlyTrader_reverts() public {
        uint256[6] memory parts = _emptyParts();
        vm.prank(address(0xBAD));
        vm.expectRevert(BtcbotRouterV2.NotTrader.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    // ── batch: per-leg mandate gate ──
    function test_batch_sell_skipsLegWithoutMandate() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER; // has mandate
        legs[0].amountIn = 1e18;
        legs[1].user = USER2; // NO mandate
        legs[1].amountIn = 1e18;

        vm.expectEmit(true, false, false, true, address(router));
        emit LegSkipped(USER2, 1, 3); // reason 3 = no valid mandate

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "only USER filled");
        assertEq(totalOut, 60000e18, "1 BTCB aggregate");
        assertEq(btcb.balanceOf(USER2), 100e18, "USER2 BTCB intact");
    }

    // ── #5 setSwapRouter timelock ──
    function test_setSwapRouter_timelock() public {
        address newR = address(new MockV3SwapRouter());
        vm.startPrank(OWNER);
        router.allowRouter(newR, true);
        router.scheduleSwapRouter(newR);
        vm.expectRevert(BtcbotRouterV2.TimelockPending.selector);
        router.executeSwapRouter(); // too early
        vm.warp(block.timestamp + 48 hours);
        router.executeSwapRouter();
        vm.stopPrank();
        assertEq(router.swapRouter(), newR, "router switched after 48h");
    }

    function test_setSwapRouter_notAllowed_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(BtcbotRouterV2.RouterNotAllowed.selector);
        router.scheduleSwapRouter(address(0xDEAD));
    }

    // ── fan-out branches: failover-to-root / self-pay / vacant upline ──
    function test_sell_failoverToRoot() public {
        usdt.setBlacklisted(UP1, true); // UP1 can't receive -> failover to root
        uint256[6] memory parts = _emptyParts();
        parts[0] = 100e18; // tier1 -> UP1 (blacklisted) -> root
        parts[5] = 200e18; // root
        vm.prank(TRADER);
        uint256 userRecv = router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(usdt.balanceOf(UP1), 0, "UP1 got nothing");
        assertEq(usdt.balanceOf(ROOT), 300e18, "root got UP1's slice + its own");
        assertEq(userRecv, 60000e18 - 300e18, "both parts deducted");
    }

    function test_sell_selfPay() public {
        address[5] memory up;
        up[0] = USER; // user is their own tier-1 (root-spillover style)
        vm.prank(OWNER);
        router.setUplines(USER, up);
        uint256[6] memory parts = _emptyParts();
        parts[0] = 100e18; // tier1 -> USER => self-pay, kept (not deducted)
        vm.prank(TRADER);
        uint256 userRecv = router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(userRecv, 60000e18, "self-pay slice kept");
    }

    function test_vacantUpline_rollsToRoot() public {
        uint256[6] memory parts = _emptyParts();
        parts[2] = 100e18; // tier3 upline vacant (default uplines [UP1,UP2,0,0,0]) -> root
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(usdt.balanceOf(ROOT), 100e18, "vacant tier rolled to root");
    }

    // ── batch ──
    function test_batch_sell_commission() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](1);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[0].parts[0] = 100e18; // tier1 -> UP1
        legs[0].parts[5] = 200e18; // root
        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "filled");
        assertEq(totalOut, 60000e18, "aggregate");
        assertEq(usdt.balanceOf(UP1), 100e18, "UP1 tier1 (batch)");
        assertEq(usdt.balanceOf(ROOT), 200e18, "ROOT (batch)");
    }

    function test_batch_buy_happyAndSkip() public {
        BtcbotRouterV2.BuyLeg[] memory legs = new BtcbotRouterV2.BuyLeg[](2);
        legs[0].user = USER; // mandate OK
        legs[0].amountIn = 60000e18;
        legs[1].user = USER2; // NO mandate -> skip
        legs[1].amountIn = 60000e18;
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 0, DL);
        assertEq(nFilled, 1, "only USER filled");
        assertGt(btcb.balanceOf(USER), 100e18, "USER got BTCB");
        assertEq(btcb.balanceOf(USER2), 100e18, "USER2 unchanged");
    }

    function test_buy_oracleFloor_reverts() public {
        v3.setFixedOut(0.5e18); // below buy floor (~0.98 BTCB for 60000 USDT)
        vm.prank(TRADER);
        vm.expectRevert();
        router.swapUsdtToBtcb(USER, 60000e18, 0, DL);
    }

    // ── pause / slippage cap / mandate nonce edges ──
    function test_paused_reverts() public {
        vm.prank(OWNER);
        router.setPaused(true);
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.IsPaused.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_setMaxSlippage_overCap_reverts() public {
        vm.prank(OWNER);
        vm.expectRevert(BtcbotRouterV2.SlippageTooHigh.selector);
        router.setMaxSlippageBps(600); // > 500 cap
    }

    function test_mandateSlippage_overCap_reverts() public {
        _register(_mk(USER, 1_000_000e18, 3000, 600, EXP, 2)); // slip 600 > cap (checked at swap)
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.SlippageTooHigh.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_cancelUpToNonce_blocksSwap() public {
        vm.prank(USER);
        router.cancelUpToNonce(10); // default mandate nonce=1 < 10
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.NoMandate.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_staleNonce_register_reverts() public {
        vm.prank(USER);
        router.cancelMandate(); // minNonce -> 2
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 500e18, 3000, 200, EXP, 1); // nonce 1 < 2
        bytes memory sig = _sign(m, USER_PK);
        vm.expectRevert(BtcbotRouterV2.StaleNonce.selector);
        router.registerMandate(m, sig);
    }

    // ── admin setters / rescue / ownership ──
    function test_setTrader_setRoot() public {
        vm.startPrank(OWNER);
        router.setTrader(address(0x7777));
        router.setRoot(address(0x8888));
        vm.stopPrank();
        assertEq(router.trader(), address(0x7777), "trader set");
        assertEq(router.root(), address(0x8888), "root set");
    }

    function test_rescueToken() public {
        usdt.mint(address(router), 500e18);
        vm.prank(OWNER);
        router.rescueToken(address(usdt), 500e18, OWNER);
        assertEq(usdt.balanceOf(OWNER), 500e18, "owner rescued stuck USDT");
    }

    function test_ownership_2step() public {
        address newOwner = address(0xBEEF);
        vm.prank(OWNER);
        router.transferOwnership(newOwner);
        assertEq(router.owner(), OWNER, "unchanged until accept");
        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner, "changed after accept");
    }

    // ── failure-mode branches (coverage) ──
    function test_sell_failover_returnsFalse() public {
        usdt.setReturnsFalseTo(UP1, true); // transfer returns false (no revert) -> failover to root
        uint256[6] memory parts = _emptyParts();
        parts[0] = 100e18;
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(usdt.balanceOf(UP1), 0, "UP1 nothing");
        assertEq(usdt.balanceOf(ROOT), 100e18, "failover to root (returns-false branch)");
    }

    function test_oracleBad_reverts() public {
        oracle.setAnswer(0); // ans <= 0
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.OracleBad.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_batch_sell_skipZeroAmount() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 0; // reason 1 = zero/invalid
        legs[1].user = USER;
        legs[1].amountIn = 1e18;
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "zero-amount leg skipped");
    }

    function test_batch_sell_skipRevokedApproval() public {
        _register(_mk(USER2, 1_000_000e18, 3000, 200, EXP, 1)); // USER2 mandate OK...
        vm.prank(USER2);
        btcb.approve(address(router), 0); // ...but BTCB approval revoked -> reason 2
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[1].user = USER2;
        legs[1].amountIn = 1e18;
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "revoked-approval leg skipped (reason 2)");
    }

    function test_batch_allSkipped_reverts() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](1);
        legs[0].user = USER2; // no mandate -> skipped -> totalIn 0
        legs[0].amountIn = 1e18;
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.EmptyBatch.selector);
        router.batchSwapAndDistribute(legs, 0, DL);
    }

    function test_batch_overCapCommission_userMadeWhole() public {
        _register(_mk(USER, 1_000_000e18, 100, 200, EXP, 2)); // commission cap 1%
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](1);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[0].parts[5] = 1000e18; // 1.67% > 1% cap -> commission skipped, user made whole
        vm.prank(TRADER);
        router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(usdt.balanceOf(USER), 2_000_000e18 + 60000e18, "user made whole");
        assertEq(usdt.balanceOf(ROOT), 0, "no commission paid (over-cap)");
    }

    // ── audit fixes: cumulative cap (H-01), replay (M-01), batch slippage (M-02), depeg (L-03) ──
    function test_cumulativeCap_reverts() public {
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 1_000_000e18, 3000, 200, EXP, 2);
        m.maxCumulativeNotional = 80000e18; // ~1.3 trades of 1 BTC ($60k each)
        _register(m);
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 1st: 60k used, OK
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ExceedsSessionLimit.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 2nd: 120k > 80k cap
    }

    function test_replayOldMandate_reverts() public {
        // setUp registered nonce=1; register a newer restrictive nonce=2
        _register(_mk(USER, 1000e18, 3000, 200, EXP, 2));
        // replaying the OLD (more permissive) nonce=1 must be rejected (no rollback)
        BtcbotRouterV2.TradeMandate memory m1 = _mk(USER, 1_000_000e18, 3000, 200, EXP, 1);
        bytes memory sig1 = _sign(m1, USER_PK);
        vm.expectRevert(BtcbotRouterV2.StaleNonce.selector);
        router.registerMandate(m1, sig1);
    }

    function test_batch_respectsStrictestSlippage() public {
        _register(_mk(USER, 1_000_000e18, 3000, 50, EXP, 2)); // USER signs a tight 0.5%
        _register(_mk(USER2, 1_000_000e18, 3000, 200, EXP, 1)); // USER2 the default 2%
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[1].user = USER2;
        legs[1].amountIn = 1e18;
        // aggregate fair = 120000e18. floor@0.5% = 119400e18; @2% = 117600e18.
        v3.setFixedOut(118000e18); // within 2% but below USER's 0.5% -> must revert
        vm.prank(TRADER);
        vm.expectRevert(); // MockV3: out < amountOutMinimum (the strict 0.5% floor)
        router.batchSwapAndDistribute(legs, 0, DL);
    }

    function test_depeg_raisesFloor() public {
        usdtOracle.setAnswer(9e7); // USDT depegs to $0.90
        v3.setFixedOut(60000e18); // the non-depeg fair — now below the depeg-adjusted floor
        uint256[6] memory parts = _emptyParts();
        // floor = 1 BTC * (60000 / 0.90) * 0.98 = ~65333e18 > 60000e18 returned
        vm.prank(TRADER);
        vm.expectRevert();
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    // ── re-review fix: H-02 commission-cap bypass via unchecked overflow + self-pay ──
    function test_singleSell_commissionCapOverflowWithSelfPay_reverts() public {
        address[5] memory up;
        up[0] = USER; // self-pay tier (supported: root-spillover style)
        up[1] = UP2;
        vm.prank(OWNER);
        router.setUplines(USER, up);

        uint256[6] memory parts;
        parts[0] = type(uint256).max - 42_000e18; // self-pay -> skipped in _fanOut; old code wrapped the sum
        parts[1] = 60_000e18; // real, to UP2 — 100% of proceeds, far above the 30% cap

        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.CommissionTooHigh.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL);
    }

    function test_batch_commissionCapOverflowWithSelfPay_skipped() public {
        address[5] memory up;
        up[0] = USER; // self-pay
        up[1] = UP2;
        vm.prank(OWNER);
        router.setUplines(USER, up);

        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](1);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[0].parts[0] = type(uint256).max - 42_000e18; // self-pay
        legs[0].parts[1] = 60_000e18; // real, to UP2 — over cap

        vm.prank(TRADER);
        router.batchSwapAndDistribute(legs, 0, DL);
        // over-cap leg -> commission skipped (no overflow), user made whole, UP2 gets nothing
        assertEq(usdt.balanceOf(UP2), 0, "no oversized commission paid (batch self-pay)");
        assertEq(usdt.balanceOf(USER), 2_000_000e18 + 60000e18, "user made whole");
    }

    // ── re-review remark: BUY cumulative/per-trade notional is depeg-aware (USDT/USD) ──
    function test_buy_notionalIsDepegAware() public {
        usdtOracle.setAnswer(105e6); // USDT = $1.05
        _register(_mk(USER, 60_000e18, 3000, 200, EXP, 2)); // per-trade cap $60k (USD)
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ExceedsPerTrade.selector);
        router.swapUsdtToBtcb(USER, 59_000e18, 0, DL); // 59k USDT x $1.05 = $61.95k > $60k cap
    }

    // ── round-3 fix: M-1 cumulative cap not resettable by an EARLY re-registration ──
    function test_cumulativeCap_notResetByEarlyReRegister() public {
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 1_000_000e18, 3000, 200, EXP, 2);
        m.maxCumulativeNotional = 80000e18;
        _register(m);
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 60k used
        // trader submits a newer user-signed mandate EARLY (prior not expired) -> must NOT reset
        BtcbotRouterV2.TradeMandate memory m2 = _mk(USER, 1_000_000e18, 3000, 200, EXP, 3);
        m2.maxCumulativeNotional = 80000e18;
        _register(m2);
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ExceedsSessionLimit.selector);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 120k > 80k -> still reverts (no windfall)
    }

    function test_cumulativeCap_resetAfterExpiry() public {
        BtcbotRouterV2.TradeMandate memory m = _mk(USER, 1_000_000e18, 3000, 200, EXP, 2);
        m.maxCumulativeNotional = 80000e18;
        _register(m);
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 60k used
        // prior mandate expires; user signs a fresh one (new quarter) -> budget resets to 0
        vm.warp(uint256(EXP) + 1);
        oracle.setUpdatedAt(block.timestamp); // refresh oracles past the 90-day warp
        usdtOracle.setUpdatedAt(block.timestamp);
        uint64 newExp = uint64(block.timestamp + 90 days);
        BtcbotRouterV2.TradeMandate memory m2 = _mk(USER, 1_000_000e18, 3000, 200, newExp, 3);
        m2.maxCumulativeNotional = 80000e18;
        _register(m2);
        vm.prank(TRADER);
        router.swapAndDistribute(USER, 1e18, 0, parts, DL); // 60k on a fresh budget -> OK
    }

    // ── round-3 fix: L-2 _fanOut never reverts settlement (recipient -> root -> refund user) ──
    function test_fanOut_doubleFailure_refundsUser() public {
        usdt.setBlacklisted(UP1, true);
        usdt.setBlacklisted(ROOT, true); // both the upline AND root can't receive
        uint256[6] memory parts = _emptyParts();
        parts[0] = 100e18; // tier1 -> UP1 (blacklisted) -> root (blacklisted) -> refund user
        vm.prank(TRADER);
        uint256 userRecv = router.swapAndDistribute(USER, 1e18, 0, parts, DL);
        assertEq(userRecv, 60000e18, "double-failure refunds the user, no revert");
        assertEq(usdt.balanceOf(UP1), 0, "UP1 nothing");
        assertEq(usdt.balanceOf(ROOT), 0, "ROOT nothing");
    }

    // ── round-4 hardening (ChatGPT L-01..L-04) ──
    function test_batch_tooLarge_reverts() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](51); // > MAX_BATCH_LEGS (50)
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.BatchTooLarge.selector);
        router.batchSwapAndDistribute(legs, 0, DL);
    }

    function test_constructor_badFeedDecimals_reverts() public {
        MockAggregatorV3 bad = new MockAggregatorV3(0, BTC_USD); // 0 decimals -> out of [1,18]
        vm.expectRevert(BtcbotRouterV2.FeedDecimalsMismatch.selector);
        new BtcbotRouterV2(address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER, address(bad), address(bad));
    }

    function test_singleSwap_zeroAmount_reverts() public {
        uint256[6] memory parts = _emptyParts();
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ZeroAmount.selector);
        router.swapAndDistribute(USER, 0, 0, parts, DL);
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouterV2.ZeroAmount.selector);
        router.swapUsdtToBtcb(USER, 0, 0, DL);
    }

    function test_batch_absurdParts_skipsLegNotReverts() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[0].parts[4] = type(uint256).max; // non-self (vacant -> root)
        legs[0].parts[5] = type(uint256).max; // non-self (root) -> _paidCommission must SATURATE
        legs[1].user = USER;
        legs[1].amountIn = 1e18; // clean leg
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 2, "both legs pulled; batch did not revert on absurd parts");
        assertEq(usdt.balanceOf(ROOT), 0, "absurd-parts leg's commission skipped (over-cap), not paid");
    }

    // ── round-5 (external audits): batch isolation + per-trade chunking ──
    function test_batch_sell_absurdAmount_skipsLegNotReverts() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = type(uint256).max; // notional mul would overflow -> skip, not revert (L-01)
        legs[1].user = USER;
        legs[1].amountIn = 1e18;
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "absurd-amount leg skipped (overflow guard); batch did not revert");
    }

    function test_batch_buy_absurdAmount_skipsLegNotReverts() public {
        BtcbotRouterV2.BuyLeg[] memory legs = new BtcbotRouterV2.BuyLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = type(uint256).max;
        legs[1].user = USER;
        legs[1].amountIn = 60000e18;
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapUsdtToBtcb(legs, 0, DL);
        assertEq(nFilled, 1, "absurd buy leg skipped; batch did not revert");
    }

    function test_batch_chunking_perTradeCapWithinBatch() public {
        _register(_mk(USER, 80000e18, 3000, 200, EXP, 2)); // per-trade cap $80k
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 1e18; // ~$60k notional, OK
        legs[1].user = USER;
        legs[1].amountIn = 1e18; // cumulative ~$120k > $80k per-trade cap -> skip (reason 5, audit M-2)
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 1, "chunked 2nd leg skipped: per-trade cap enforced cumulatively in-batch");
    }

    function test_batch_finalTransferFails_isolatesUser() public {
        _register(_mk(USER2, 1_000_000e18, 3000, 200, EXP, 1));
        usdt.setBlacklisted(USER, true); // USER can't RECEIVE the USDT sell output (not BTCB)
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 1e18;
        legs[1].user = USER2;
        legs[1].amountIn = 1e18;
        uint256 u2Before = usdt.balanceOf(USER2);
        vm.prank(TRADER);
        (, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, DL);
        assertEq(nFilled, 2, "both legs pulled (USER not blacklisted on BTCB)");
        assertGt(usdt.balanceOf(USER2) - u2Before, 0, "USER2 still settled despite USER's failure");
        assertGt(usdt.balanceOf(address(router)), 0, "USER's un-sendable share held for rescueToken");
    }
}
