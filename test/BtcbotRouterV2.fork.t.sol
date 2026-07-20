// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BtcbotRouterV2} from "../src/BtcbotRouterV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAgg {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @title BtcbotRouterV2 — BSC-mainnet FORK test
/// @notice Exercises the contract against the REAL BTCB/USDT tokens, the real PancakeSwap V3
///         SmartRouter, and the real Chainlink BTC/USD + USDT/USD feeds. Proves the oracle floor,
///         the EIP-712 mandate (signed with the fork's chainid=56), and a real single + batch
///         SELL/BUY all execute and conserve balances against live liquidity.
///
///   Run: forge test --match-path test/BtcbotRouterV2.fork.t.sol \
///        --fork-url https://bsc-dataseed.binance.org -vv
contract BtcbotRouterV2ForkTest is Test {
    // ── real BSC mainnet addresses ──
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4; // Pancake V3 SmartRouter
    address constant BTC_USD = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address constant USDT_USD = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    uint256 constant USER_PK = 0xF00D;
    uint256 constant USER2_PK = 0xBEEF;
    address USER;
    address USER2;
    address constant TRADER = address(0x7AAD);
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7E2);

    BtcbotRouterV2 router;
    uint64 EXP;

    function setUp() public {
        USER = vm.addr(USER_PK);
        USER2 = vm.addr(USER2_PK);
        EXP = uint64(block.timestamp + 90 days);

        router = new BtcbotRouterV2(BTCB, USDT, SMART_ROUTER, TRADER, ROOT, OWNER, BTC_USD, USDT_USD);
        vm.prank(OWNER);
        router.setPaused(false);

        // fund both users with real tokens (forge writes the balance slots)
        deal(BTCB, USER, 1e17); // 0.1 BTCB
        deal(USDT, USER, 20_000e18);
        deal(BTCB, USER2, 1e17);
        deal(USDT, USER2, 20_000e18);

        _approveAndRegister(USER, USER_PK);
        _approveAndRegister(USER2, USER2_PK);
    }

    function _approveAndRegister(address u, uint256 pk) internal {
        vm.startPrank(u);
        IERC20(BTCB).approve(address(router), type(uint256).max);
        IERC20(USDT).approve(address(router), type(uint256).max);
        vm.stopPrank();
        BtcbotRouterV2.TradeMandate memory m;
        m.user = u;
        m.maxNotionalPerTrade = 1_000_000e18;
        m.maxCumulativeNotional = type(uint256).max;
        m.maxCommissionBps = 3000;
        m.maxSlippageBps = 300; // capped to ownerMaxSlippageBps (200) at swap time anyway
        m.expiry = EXP;
        m.nonce = 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, router.mandateDigest(m));
        router.registerMandate(m, abi.encodePacked(r, s, v));
    }

    // ── feed freshness (verifies maxOracleAge is not too tight for the live heartbeats) ──
    function test_fork_feedFreshness() public view {
        (, int256 btcP,, uint256 btcUpd,) = IAgg(BTC_USD).latestRoundData();
        (, int256 usdtP,, uint256 usdtUpd,) = IAgg(USDT_USD).latestRoundData();
        console2.log("block.timestamp     ", block.timestamp);
        console2.log("BTC/USD  price(8dp) ", uint256(btcP));
        console2.log("BTC/USD  age (s)    ", block.timestamp - btcUpd);
        console2.log("USDT/USD price(8dp) ", uint256(usdtP));
        console2.log("USDT/USD age (s)    ", block.timestamp - usdtUpd);
        assertLt(block.timestamp - btcUpd, router.maxOracleAge(), "BTC/USD older than maxOracleAge");
        assertLt(block.timestamp - usdtUpd, router.maxOracleAge(), "USDT/USD older than maxOracleAge");
    }

    // ── real SELL through the live pool, floored by the live oracle ──
    function test_fork_sell() public {
        uint256 amtIn = 1e16; // 0.01 BTCB
        uint256 userUsdtBefore = IERC20(USDT).balanceOf(USER);
        uint256[6] memory parts; // no commission

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(USER, amtIn, 0, parts, block.timestamp + 300);

        console2.log("SELL 0.01 BTCB -> USDT received:", userReceived);
        assertGt(userReceived, 0, "no USDT out");
        assertEq(IERC20(USDT).balanceOf(USER) - userUsdtBefore, userReceived, "user credited exactly");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "no USDT stuck in router");
        assertEq(IERC20(BTCB).balanceOf(address(router)), 0, "no BTCB stuck in router");
    }

    // ── real BUY through the live pool ──
    function test_fork_buy() public {
        uint256 amtIn = 600e18; // 600 USDT
        uint256 userBtcbBefore = IERC20(BTCB).balanceOf(USER);

        vm.prank(TRADER);
        uint256 btcbOut = router.swapUsdtToBtcb(USER, amtIn, 0, block.timestamp + 300);

        console2.log("BUY 600 USDT -> BTCB received:", btcbOut);
        assertGt(btcbOut, 0, "no BTCB out");
        assertEq(IERC20(BTCB).balanceOf(USER) - userBtcbBefore, btcbOut, "user credited exactly");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "no USDT stuck");
        assertEq(IERC20(BTCB).balanceOf(address(router)), 0, "no BTCB stuck");
    }

    // ── real BATCH SELL: 2 users, one aggregated swap, per-user settlement ──
    function test_fork_batchSell() public {
        BtcbotRouterV2.UserLeg[] memory legs = new BtcbotRouterV2.UserLeg[](2);
        legs[0].user = USER;
        legs[0].amountIn = 5e15; // 0.005 BTCB
        legs[1].user = USER2;
        legs[1].amountIn = 5e15;

        uint256 u1Before = IERC20(USDT).balanceOf(USER);
        uint256 u2Before = IERC20(USDT).balanceOf(USER2);

        vm.prank(TRADER);
        (uint256 totalOut, uint256 nFilled) = router.batchSwapAndDistribute(legs, 0, block.timestamp + 300);

        console2.log("BATCH SELL total USDT:", totalOut, "filled:", nFilled);
        assertEq(nFilled, 2, "both legs filled");
        assertGt(IERC20(USDT).balanceOf(USER) - u1Before, 0, "USER got USDT");
        assertGt(IERC20(USDT).balanceOf(USER2) - u2Before, 0, "USER2 got USDT");
        // only pro-rata dust may remain
        assertLt(IERC20(USDT).balanceOf(address(router)), 1e6, "only dust USDT left");
        assertEq(IERC20(BTCB).balanceOf(address(router)), 0, "no BTCB stuck");
    }

    // ── real SELL with on-chain commission fan-out (#6: recipients from setUplines, not relayer) ──
    function test_fork_sell_commission() public {
        address up1 = address(0x11110001);
        // mirrors what _v2_setuplines emits for a referred user: tier1 = real referrer, 2-5 = root
        address[5] memory up = [up1, ROOT, ROOT, ROOT, ROOT];
        vm.prank(OWNER);
        router.setUplines(USER, up);

        uint256[6] memory parts; // ~$8 commission on ~$600 proceeds (~1.3% << 30% cap)
        parts[0] = 5e18; // tier1 -> up1
        parts[5] = 3e18; // root  -> ROOT
        uint256 up1Before = IERC20(USDT).balanceOf(up1);
        uint256 rootBefore = IERC20(USDT).balanceOf(ROOT);
        uint256 userBefore = IERC20(USDT).balanceOf(USER);

        vm.prank(TRADER);
        uint256 userReceived = router.swapAndDistribute(USER, 1e16, 0, parts, block.timestamp + 300);

        console2.log("SELL+commission userReceived:", userReceived);
        assertEq(IERC20(USDT).balanceOf(up1) - up1Before, 5e18, "tier1 commission -> up1 (on-chain recipient)");
        assertEq(IERC20(USDT).balanceOf(ROOT) - rootBefore, 3e18, "root commission -> ROOT");
        assertEq(IERC20(USDT).balanceOf(USER) - userBefore, userReceived, "user net credited");
        assertEq(IERC20(USDT).balanceOf(address(router)), 0, "no USDT stuck (full distribution)");
        assertEq(IERC20(BTCB).balanceOf(address(router)), 0, "no BTCB stuck");
    }
}
