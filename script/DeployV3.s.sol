// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotRouterV3} from "../src/BtcbotRouterV3.sol";

/// @title DeployV3: deploys BtcbotRouterV3 (oracle floor, EIP-712 session mandate, on-chain
///        commission tree, 48h swap-router timelock) to BSC mainnet.
/// @notice Successor of BtcbotRouterV2 (0xaCa5F1…). V3 delta: a failed batch settlement is recorded
///         as owed to the user and anyone can deliver it (`claimStranded`); `rescueToken` cannot touch
///         those amounts. Constructor takes 8 args; the contract ships PAUSED from its constructor.
///         Live deployment: 0x600D173c359DB44aFef10b38cA2D7Cad0A320b28 (2026-08-26).
///
/// Roles:
///   - trader = TRADER_WALLET_ADDRESS: the hot bot key, only caller of the swap functions, no custody.
///   - root   = FOUNDER_WALLET: commission root and fan-out fallback recipient.
///   - owner  = ROUTER_OWNER_ADDRESS, set in the constructor. For the live deployment this was the
///              cold hardware wallet 0x94eDfB…, so there was never a hot-key ownership window.
///
/// Usage:
///   forge script script/DeployV3.s.sol --rpc-url bsc --broadcast --verify
///   The script logs the 8 constructor args and reverts if a post-deploy sanity check fails.
///   Then, from the owner: setUplines per user (referral recipients are on-chain), unpause after
///   a low-value canary. Users re-approve the new address (bounded ERC20 approval) and sign a
///   mandate in the dashboard.
contract DeployV3 is Script {
    // BSC mainnet (chainid 56) — MUST match the live routers' immutables.
    address constant BTCB_BSC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    // Pancake V3 SmartRouter02 (same venue as Duplex — the deep 0.05% BTCB/USDT pool).
    address constant PANCAKE_V3_ROUTER_BSC = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    // Chainlink feeds on BNB Chain (both 8-dec; constructor asserts equal decimals + range).
    // Verified live 2026-06-29: BTC/USD ~2min heartbeat, USDT/USD ~15min — both << maxOracleAge(1h).
    address constant BTC_USD_FEED_BSC = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address constant USDT_USD_FEED_BSC = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    function run() external returns (BtcbotRouterV3 router) {
        require(block.chainid == 56, "Deploy: not on BSC mainnet (chainid 56)");

        address trader = vm.envAddress("TRADER_WALLET_ADDRESS"); // hot bot 0x093eAa
        address rootAddr = vm.envAddress("FOUNDER_WALLET"); // founder 0x032c18
        address ownerAddr = vm.envOr("ROUTER_OWNER_ADDRESS", rootAddr); // deployer (then →cold)

        require(trader != address(0), "Deploy: TRADER_WALLET_ADDRESS missing");
        require(rootAddr != address(0), "Deploy: FOUNDER_WALLET missing");
        require(ownerAddr != address(0), "Deploy: owner zero");
        // Post-split sanity: the bot (trader) must NOT be the commission root.
        require(trader != rootAddr, "Deploy: trader == root (did you forget the split env?)");

        console.log("==================================================");
        console.log(" Deploying BtcbotRouterV3 (oracle floor + mandate + tree) to BSC mainnet");
        console.log("==================================================");
        console.log("  chainid     :", block.chainid);
        console.log("  Constructor parameters (8):");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V3  :", PANCAKE_V3_ROUTER_BSC);
        console.log("    trader (hot):", trader);
        console.log("    root (fndr) :", rootAddr);
        console.log("    owner       :", ownerAddr, "(set at construction)");
        console.log("    BTC/USD feed:", BTC_USD_FEED_BSC);
        console.log("    USDT/USD fd :", USDT_USD_FEED_BSC);
        console.log("==================================================");

        vm.startBroadcast();
        router = new BtcbotRouterV3(
            BTCB_BSC, USDT_BSC, PANCAKE_V3_ROUTER_BSC, trader, rootAddr, ownerAddr, BTC_USD_FEED_BSC, USDT_USD_FEED_BSC
        );
        // NB: the constructor already ships PAUSED — no setPaused call needed here.
        vm.stopBroadcast();

        // ── Post-deploy sanity (reverts the script if anything is off) ──
        require(router.BTCB() == BTCB_BSC, "sanity: BTCB mismatch");
        require(router.USDT() == USDT_BSC, "sanity: USDT mismatch");
        require(router.swapRouter() == PANCAKE_V3_ROUTER_BSC, "sanity: swapRouter mismatch");
        require(router.trader() == trader, "sanity: trader mismatch");
        require(router.root() == rootAddr, "sanity: root mismatch");
        require(router.owner() == ownerAddr, "sanity: owner mismatch");
        require(router.BTC_USD_FEED() == BTC_USD_FEED_BSC, "sanity: BTC/USD feed mismatch");
        require(router.USDT_USD_FEED() == USDT_USD_FEED_BSC, "sanity: USDT/USD feed mismatch");
        require(router.paused(), "sanity: expected paused-on-deploy (constructor)");
        require(router.allowedRouter(PANCAKE_V3_ROUTER_BSC), "sanity: swapRouter not allowlisted");

        console.log("");
        console.log(">>> BtcbotRouterV3 deployed at:", address(router));
        console.log("    paused      :", router.paused());
        console.log("    NEXT: BscScan verify -> setUplines per user (owner) ->");
        console.log("          canary + unpause (owner) -> users re-approve + sign a mandate.");
    }
}
