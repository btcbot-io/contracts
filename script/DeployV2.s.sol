// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotRouterV2} from "../src/BtcbotRouterV2.sol";

/// @title DeployV2 — deploy BtcbotRouterV2 (oracle floor + EIP-712 session mandate + on-chain
///        commission tree + 48h setSwapRouter timelock) to BSC mainnet.
/// @notice Successor of BtcbotRouterDuplex (0x581bfa…). The public-launch router.
///         Constructor now takes **8 args** (two Chainlink feeds added). The contract
///         ships PAUSED from its own constructor (no setPaused needed at deploy). A new address
///         ⇒ a one-time user re-approval AND a one-time mandate signature (the 4th migration).
///
/// ⚠️ ROLES (post key-split, same as Duplex):
///   - trader = TRADER_WALLET_ADDRESS = HOT bot 0x093eAa… (only swap caller; no custody)
///   - root   = FOUNDER_WALLET = 0x032c18… (commission root + fan-out fallback recipient)
///   - owner  = DEPLOYER at deploy, then transferred to the COLD Ledger 0x94eDfB… (2-step)
///
/// GO-LIVE PROCEDURE (operator runs each step; deploy = your key + your gas):
///   0. env: TRADER_WALLET_ADDRESS=0x093eAa…, FOUNDER_WALLET=0x032c18…
///      Deploy with a key whose address you'll set as owner (then transfer to cold).
///   1. forge script DeployV2 --rpc-url bsc --private-key $DEPLOYER_PRIVATE_KEY \
///        --broadcast --verify        → deploys PAUSED; logs + sanity-checks all 8 args + feeds.
///   2. BscScan verify; sanity-check the logged constructor args + the two Chainlink feeds.
///   3. Share the Slither report and the AUDIT_FIXES_V2 changelog with security reviewers.
///   4. transferOwnership(0x94eDfB COLD) from the deployer key, then acceptOwnership from the
///      Ledger (fund the cold wallet with a little BNB first). Owner now COLD.
///   5. setUplines(user, [t1..t5]) for each user from the Ledger — mirror the off-chain
///      `referrals` table (recipients are now ON-CHAIN, not relayer-passed). Vacant => root.
///   6. Users: re-approve (bounded ERC20 approval) + sign + register an EIP-712 mandate (FE).
///   7. Canary: setPaused(false) from the Ledger; point the trader at the new address for
///      yourself + 1 friend; low-value smoke SELL/BUY + a 2-leg batch → verify per-user fills
///      + conservation (the fork test already proved this against live infra).
///   8. If clean: open to all (FE banner), flip the trader's MIGRATION_TARGET_ROUTER to V2.
contract DeployV2 is Script {
    // BSC mainnet (chainid 56) — MUST match the live routers' immutables.
    address constant BTCB_BSC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    // Pancake V3 SmartRouter02 (same venue as Duplex — the deep 0.05% BTCB/USDT pool).
    address constant PANCAKE_V3_ROUTER_BSC = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    // Chainlink feeds on BNB Chain (both 8-dec; constructor asserts equal decimals + range).
    // Verified live 2026-06-29: BTC/USD ~2min heartbeat, USDT/USD ~15min — both << maxOracleAge(1h).
    address constant BTC_USD_FEED_BSC = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address constant USDT_USD_FEED_BSC = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;

    function run() external returns (BtcbotRouterV2 router) {
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
        console.log(" Deploying BtcbotRouterV2 (oracle floor + mandate + tree) to BSC mainnet");
        console.log("==================================================");
        console.log("  chainid     :", block.chainid);
        console.log("  Constructor parameters (8):");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V3  :", PANCAKE_V3_ROUTER_BSC);
        console.log("    trader (hot):", trader);
        console.log("    root (fndr) :", rootAddr);
        console.log("    owner       :", ownerAddr, "(transfer to COLD 0x94eDfB after deploy)");
        console.log("    BTC/USD feed:", BTC_USD_FEED_BSC);
        console.log("    USDT/USD fd :", USDT_USD_FEED_BSC);
        console.log("==================================================");

        vm.startBroadcast();
        router = new BtcbotRouterV2(
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
        console.log(">>> BtcbotRouterV2 deployed at:", address(router));
        console.log("    paused      :", router.paused());
        console.log("    NEXT: BscScan verify -> security review ->");
        console.log("          transferOwnership(COLD) + acceptOwnership(Ledger) ->");
        console.log("          setUplines(user,[t1..t5]) per user (mirror referrals table) ->");
        console.log("          users re-approve + sign a mandate -> unpause -> canary -> all.");
    }
}
