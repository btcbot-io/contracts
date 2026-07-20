// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotRouterDuplex} from "../src/BtcbotRouterDuplex.sol";

/// @title DeployDuplex — deploy BtcbotRouterDuplex (batch-buy + per-swap deadline) to BSC.
/// @notice Successor of BtcbotCommissionRouter (0xB81C0b…). Same constructor + same V3
///         venue (Pancake V3 0.05%); two additions only (batch BUY + deadline). A new
///         address ⇒ a one-time user re-approval. Ships PAUSED.
///
/// ⚠️ POST-SPLIT ROLES (different from the old single-key deploys):
///   - trader = TRADER_WALLET_ADDRESS = the HOT bot wallet 0x093eAa… (signs swaps)
///   - root   = FOUNDER_WALLET = 0x032c18… (commission root + fallback recipient + the
///              F4M1LY 10% single-line recipient). NOT the trader anymore.
///   - owner  = the DEPLOYER at deploy (so the atomic setPaused works), then transferred
///              to the COLD wallet 0x94eDfB… afterwards (2-step, like the other routers).
///
/// GO-LIVE PROCEDURE (operator runs each step; deploy = your key + your gas):
///   0. env: TRADER_WALLET_ADDRESS=0x093eAa…, FOUNDER_WALLET=0x032c18…
///      Deploy with the FOUNDER key (0x032c18) so owner==deployer → atomic pause works.
///   1. forge script DeployDuplex --rpc-url bsc --private-key $DEPLOYER_PRIVATE_KEY \
///        --broadcast --verify          → deploys PAUSED; logs + sanity-checks the args.
///   2. BscScan verify; sanity-check the logged constructor args.
///   3. PRE-WARN Blockaid with the new address (young contract + approve + transferFrom =
///      the drainer heuristic; send the slither report + the dossier BEFORE pushing users).
///   4. transferOwnership(0x94eDfB… COLD) from the founder key, then acceptOwnership from
///      the Ledger (fund the cold wallet with a little BNB first). Owner now COLD.
///   5. Canary: setPaused(false) from the Ledger; point the trader at the new address for
///      yourself + 1 friend only; $5 smoke BUY + a 2-leg batch BUY → verify per-user fills.
///   6. If clean: open re-approval to all (frontend banner), flip the trader for everyone
///      (TRI-router until each user re-approves: legacy 0xb191… + commission 0xB81C… + Duplex).
contract DeployDuplex is Script {
    // BSC mainnet (chainid 56) — MUST match the live routers' immutables.
    address constant BTCB_BSC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    // Pancake V3 SmartRouter02 (same venue as the current 0xB81C0b… router).
    address constant PANCAKE_V3_ROUTER_BSC = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    function run() external returns (BtcbotRouterDuplex router) {
        require(block.chainid == 56, "Deploy: not on BSC mainnet (chainid 56)");

        address trader = vm.envAddress("TRADER_WALLET_ADDRESS");        // hot bot 0x093eAa
        address rootAddr = vm.envAddress("FOUNDER_WALLET");             // founder 0x032c18
        address ownerAddr = vm.envOr("ROUTER_OWNER_ADDRESS", rootAddr); // deployer (then →cold)
        bool deployPaused = vm.envOr("DEPLOY_PAUSED", true);

        require(trader != address(0), "Deploy: TRADER_WALLET_ADDRESS missing");
        require(rootAddr != address(0), "Deploy: FOUNDER_WALLET missing");
        require(ownerAddr != address(0), "Deploy: owner zero");
        // Post-split sanity: the bot (trader) must NOT be the commission root.
        require(trader != rootAddr, "Deploy: trader == root (did you forget the split env?)");

        console.log("==================================================");
        console.log(" Deploying BtcbotRouterDuplex (batch-buy + deadline) to BSC mainnet");
        console.log("==================================================");
        console.log("  chainid     :", block.chainid);
        console.log("  Constructor parameters:");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V3  :", PANCAKE_V3_ROUTER_BSC);
        console.log("    trader (hot):", trader);
        console.log("    root (fndr) :", rootAddr);
        console.log("    owner       :", ownerAddr, "(transfer to COLD 0x94eDfB after deploy)");
        console.log("    deployPaused:", deployPaused);
        console.log("==================================================");

        vm.startBroadcast();
        router = new BtcbotRouterDuplex(
            BTCB_BSC, USDT_BSC, PANCAKE_V3_ROUTER_BSC, trader, rootAddr, ownerAddr
        );
        if (deployPaused) {
            // Ship paused — owner (== deployer here) must setPaused(false) to enable trading.
            router.setPaused(true);
        }
        vm.stopBroadcast();

        // ── Post-deploy sanity (reverts the script if anything is off) ──
        require(router.BTCB() == BTCB_BSC, "sanity: BTCB mismatch");
        require(router.USDT() == USDT_BSC, "sanity: USDT mismatch");
        require(router.swapRouter() == PANCAKE_V3_ROUTER_BSC, "sanity: swapRouter mismatch");
        require(router.trader() == trader, "sanity: trader mismatch");
        require(router.root() == rootAddr, "sanity: root mismatch");
        require(router.owner() == ownerAddr, "sanity: owner mismatch");
        if (deployPaused) {
            require(router.paused(), "sanity: expected paused-on-deploy");
        }

        console.log("");
        console.log(">>> BtcbotRouterDuplex deployed at:", address(router));
        console.log("    paused      :", router.paused());
        console.log("    NEXT: verify -> Blockaid pre-warn -> transferOwnership(COLD) +");
        console.log("          acceptOwnership(Ledger) -> set the Duplex addr in env ->");
        console.log("          users re-approve (USDT + BTCB) -> unpause -> canary -> all.");
    }
}
