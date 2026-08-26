// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotRouterV3} from "../src/BtcbotRouterV3.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @title BtcbotRouterV3 — delta tests for the stranded-settlement fix (DappBay).
/// @notice V3 is byte-identical to V2 except: failed batch settlements are RECORDED as
///         owed (`stranded`), delivered by the permissionless `claimStranded`, and
///         `rescueToken` is barred from the stranded pool. These tests exercise exactly
///         that delta plus smoke tests that the V2 paths still behave.
contract BtcbotRouterV3Test is Test {
    BtcbotRouterV3 router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockV3SwapRouter v3;
    MockAggregatorV3 oracle;
    MockAggregatorV3 usdtOracle;

    event UserSettlementFailed(address indexed user, address indexed token, uint256 amount);
    event StrandedClaimed(address indexed user, address indexed token, uint256 amount, address caller);
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);

    uint256 constant TRADER_PK = 0xA77;
    uint256 constant USER_PK = 0x5151;
    uint256 constant USER2_PK = 0x5252;
    address TRADER;
    address USER;
    address USER2;
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);

    int256 constant BTC_USD = 60000e8; // feed 8-dec
    uint256 constant SELL_RATE = 60000e18; // 1 BTCB -> 60000 USDT
    uint256 constant BUY_RATE = uint256(1e18) / 60000; // 1 USDT -> ~1/60000 BTCB
    uint256 constant DL = type(uint256).max;
    uint64 EXP;

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
        usdtOracle = new MockAggregatorV3(8, int256(1e8));

        router = new BtcbotRouterV3(
            address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER, address(oracle), address(usdtOracle)
        );
        vm.prank(OWNER);
        router.setPaused(false);

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

        _register(_mk(USER, 1_000_000e18, 3000, 200, EXP, 1), USER_PK);
        _register(_mk(USER2, 1_000_000e18, 3000, 200, EXP, 1), USER2_PK);
    }

    // ── helpers ──
    function _mk(address user, uint256 maxNotional, uint16 commBps, uint16 slipBps, uint64 expiry, uint96 nonce)
        internal
        pure
        returns (BtcbotRouterV3.TradeMandate memory m)
    {
        m.user = user;
        m.maxNotionalPerTrade = maxNotional;
        m.maxCumulativeNotional = type(uint256).max;
        m.maxCommissionBps = commBps;
        m.maxSlippageBps = slipBps;
        m.expiry = expiry;
        m.nonce = nonce;
    }

    function _register(BtcbotRouterV3.TradeMandate memory m, uint256 pk) internal {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.mandateDigest(m));
        router.registerMandate(m, abi.encodePacked(r, s, v));
    }

    function _emptyParts() internal pure returns (uint256[6] memory p) {}

    function _sellLeg(address u, uint256 amt) internal pure returns (BtcbotRouterV3.UserLeg memory l) {
        l.user = u;
        l.amountIn = amt;
    }

    function _sellBoth() internal returns (uint256 strandedAmt) {
        // USER can't receive USDT (blacklisted-style: transfer returns false); USER2 is fine.
        usdt.setReturnsFalseTo(USER, true);
        BtcbotRouterV3.UserLeg[] memory legs = new BtcbotRouterV3.UserLeg[](2);
        legs[0] = _sellLeg(USER, 1e18);
        legs[1] = _sellLeg(USER2, 1e18);
        vm.prank(TRADER);
        router.batchSwapAndDistribute(legs, 0, DL);
        strandedAmt = router.stranded(USER, address(usdt));
    }

    // ── stranded recording (SELL: USDT owed) ──
    function test_batchSell_failedSettle_recordsStranded_othersPaid() public {
        uint256 u2Before = usdt.balanceOf(USER2);
        uint256 amt = _sellBoth();
        assertGt(amt, 59_000e18, "USER's ~60000 USDT recorded as owed");
        assertEq(router.strandedTotal(address(usdt)), amt, "per-token total tracks");
        assertGt(usdt.balanceOf(USER2) - u2Before, 59_000e18, "USER2 settled normally");
        assertEq(usdt.balanceOf(address(router)), amt, "owed funds sit in the router");
    }

    // ── claimStranded ──
    function test_claim_paysUser_fromAnyCaller_thenNothingLeft() public {
        uint256 amt = _sellBoth();
        usdt.setReturnsFalseTo(USER, false); // user unblocked
        uint256 before = usdt.balanceOf(USER);
        vm.expectEmit(true, true, false, true, address(router));
        emit StrandedClaimed(USER, address(usdt), amt, address(0xBEEF));
        vm.prank(address(0xBEEF)); // PERMISSIONLESS: a stranger delivers, funds go to USER
        router.claimStranded(address(usdt), USER);
        assertEq(usdt.balanceOf(USER) - before, amt, "user made whole");
        assertEq(router.stranded(USER, address(usdt)), 0, "debt cleared");
        assertEq(router.strandedTotal(address(usdt)), 0, "total cleared");
        vm.expectRevert(BtcbotRouterV3.NothingStranded.selector);
        router.claimStranded(address(usdt), USER);
    }

    function test_claim_whileStillBlocked_revertsAndKeepsDebt() public {
        uint256 amt = _sellBoth();
        vm.expectRevert(); // safeTransfer sees the false return and reverts; state rolls back
        router.claimStranded(address(usdt), USER);
        assertEq(router.stranded(USER, address(usdt)), amt, "debt intact, retry any time");
        assertEq(router.strandedTotal(address(usdt)), amt, "total intact");
    }

    // ── rescueToken carve-out ──
    function test_rescue_cannotTouchStranded_canTakeExcess() public {
        uint256 amt = _sellBoth();
        vm.prank(OWNER);
        vm.expectRevert(BtcbotRouterV3.StrandedProtected.selector);
        router.rescueToken(address(usdt), amt, OWNER); // owed funds are out of reach
        // an accidental direct send on top IS rescuable — but only the excess
        usdt.mint(address(router), 100e18);
        vm.prank(OWNER);
        vm.expectRevert(BtcbotRouterV3.StrandedProtected.selector);
        router.rescueToken(address(usdt), 100e18 + 1, OWNER);
        vm.prank(OWNER);
        router.rescueToken(address(usdt), 100e18, OWNER);
        assertEq(usdt.balanceOf(OWNER), 100e18, "excess rescued");
        assertEq(usdt.balanceOf(address(router)), amt, "owed funds untouched");
    }

    // ── stranded recording (BUY: BTCB owed) ──
    function test_batchBuy_failedSettle_recordsStranded_thenClaim() public {
        btcb.setReturnsFalseTo(USER, true);
        BtcbotRouterV3.BuyLeg[] memory legs = new BtcbotRouterV3.BuyLeg[](1);
        legs[0].user = USER;
        legs[0].amountIn = 60000e18;
        vm.prank(TRADER);
        router.batchSwapUsdtToBtcb(legs, 0, DL);
        uint256 amt = router.stranded(USER, address(btcb));
        assertApproxEqAbs(amt, 1e18, 1e12, "~1 BTCB owed");
        btcb.setReturnsFalseTo(USER, false);
        uint256 before = btcb.balanceOf(USER);
        router.claimStranded(address(btcb), USER);
        assertEq(btcb.balanceOf(USER) - before, amt, "BTCB delivered");
    }

    // ── quota semantics: an EXECUTED leg consumes volume even if settlement failed ──
    // (deliberate: the swap ran within the signed caps and the proceeds are claimable;
    //  refunding would let a blacklisted-recipient loop trade unbounded volume)
    function test_quota_consumedOnFailedSettle() public {
        assertEq(router.mandateVolumeUsed(USER), 0, "fresh budget");
        _sellBoth();
        assertGt(router.mandateVolumeUsed(USER), 59_000e18, "executed volume counted");
    }

    // ── V2 behavior smoke: happy paths unchanged ──
    function test_happyPaths_stillWork() public {
        vm.prank(TRADER);
        uint256 out = router.swapUsdtToBtcb(USER, 60000e18, 0, DL);
        assertApproxEqAbs(out, 1e18, 1e12, "single buy works");
        vm.prank(TRADER);
        uint256 recv = router.swapAndDistribute(USER, 1e18, 0, _emptyParts(), DL);
        assertGt(recv, 59_000e18, "single sell works");
        assertEq(router.strandedTotal(address(usdt)), 0, "no stranding on happy path");
    }
}
