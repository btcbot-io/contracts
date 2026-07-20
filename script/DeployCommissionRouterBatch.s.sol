// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotCommissionRouter} from "../src/BtcbotCommissionRouter.sol";

/// @title DeployCommissionRouterBatch — redeploy BtcbotCommissionRouter WITH the new
///        Tier-2 `batchSwapAndDistribute` function, to BSC mainnet (chainid 56).
/// @notice Same contract + same constructor as the live router (0xb19125…) — only a new
///         function was added, which requires a fresh deployment (and a one-time user
///         re-approval of the new address). Identical V3 swap venue (Pancake V3 0.05%),
///         identical security + commission model.
///
///         GO-LIVE PROCEDURE (operator runs each step; deploy = your key + your gas):
///           1. forge script DeployCommissionRouterBatch --rpc-url bsc \
///                --private-key $DEPLOYER_PRIVATE_KEY --broadcast --verify
///              → deploys PAUSED (this script calls setPaused(true) atomically).
///           2. Verify on BscScan; sanity-check the constructor args (logged below).
///           3. Submit the new address to Blockaid for re-clearing (C2).
///           4. Point a CANARY: setPaused(false), set the trader to use the new address
///              for yourself + 1 friend only, do a $5 smoke SELL + a batch of 2 → verify
///              events + per-user fills on-chain.
///           5. If clean: open re-approval to all users (frontend banner), flip the
///              trader to the new address for everyone (dual-router until each re-approves).
///
/// @dev    setPaused(true) requires the broadcaster (deploy key) == owner. In the V1
///         single-key model owner defaults to TRADER_WALLET_ADDRESS, so deploy with that
///         same key. If you deploy with a separate key, set ROUTER_OWNER_ADDRESS to the
///         deployer (or remove the setPaused line and pause manually afterwards).
contract DeployCommissionRouterBatch is Script {
    // BSC mainnet (chainid 56) — MUST match the live router's immutables.
    address constant BTCB_BSC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    // Pancake V3 SmartRouter02 (same as the live 0xb19125… router).
    address constant PANCAKE_V3_ROUTER_BSC = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    function run() external returns (BtcbotCommissionRouter router) {
        require(block.chainid == 56, "Deploy: not on BSC mainnet (chainid 56)");

        address trader = vm.envAddress("TRADER_WALLET_ADDRESS");
        address rootAddr = vm.envOr("ROUTER_ROOT_ADDRESS", trader);
        address ownerAddr = vm.envOr("ROUTER_OWNER_ADDRESS", trader);
        bool deployPaused = vm.envOr("DEPLOY_PAUSED", true);

        require(trader != address(0), "Deploy: TRADER_WALLET_ADDRESS env missing");
        require(rootAddr != address(0), "Deploy: root address zero");
        require(ownerAddr != address(0), "Deploy: owner address zero");

        console.log("==================================================");
        console.log(" Deploying BtcbotCommissionRouter + BATCH (V3) to BSC mainnet");
        console.log("==================================================");
        console.log("  chainid     :", block.chainid);
        console.log("  block       :", block.number);
        console.log("  Constructor parameters:");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V3  :", PANCAKE_V3_ROUTER_BSC);
        console.log("    trader      :", trader);
        console.log("    root        :", rootAddr);
        console.log("    owner       :", ownerAddr);
        console.log("    deployPaused:", deployPaused);
        console.log("==================================================");

        vm.startBroadcast();
        router = new BtcbotCommissionRouter(
            BTCB_BSC, USDT_BSC, PANCAKE_V3_ROUTER_BSC, trader, rootAddr, ownerAddr
        );
        if (deployPaused) {
            // Go-live gate: ship paused; owner must setPaused(false) to enable trading.
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
        console.log(">>> BtcbotCommissionRouter (with batch) deployed at:", address(router));
        console.log("    paused      :", router.paused());
        console.log("    NEXT: BscScan verify -> Blockaid re-clear -> set BTCBOT_ROUTER_ADDRESS");
        console.log("          -> users re-approve (BTCB + USDT) -> unpause -> canary -> on");
    }
}
