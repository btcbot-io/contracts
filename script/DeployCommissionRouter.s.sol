// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotCommissionRouter} from "../src/BtcbotCommissionRouter.sol";

/// @title DeployCommissionRouter — deploys BtcbotCommissionRouter (V3-native) to
///                                 BSC mainnet (chainid 56).
/// @notice Successor of BtcbotRouter (V2). Same single-key owner/trader/root model.
///         User must call USDT.approve + BTCB.approve on the deployed router
///         address before the trader can swap on their behalf.
contract DeployCommissionRouter is Script {
    // BSC mainnet (chainid 56)
    address constant BTCB_BSC = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    // Pancake V3 SmartRouter02 (NOT the OG V3 SwapRouter — see IPancakeV3SwapRouter.sol).
    address constant PANCAKE_V3_ROUTER_BSC = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;

    function run() external returns (BtcbotCommissionRouter router) {
        require(block.chainid == 56, "Deploy: not on BSC mainnet (chainid 56)");

        address trader = vm.envAddress("TRADER_WALLET_ADDRESS");
        // root + owner default to trader if not overridden — V1 single-key model.
        address rootAddr  = vm.envOr("ROUTER_ROOT_ADDRESS",  trader);
        address ownerAddr = vm.envOr("ROUTER_OWNER_ADDRESS", trader);

        require(trader    != address(0), "Deploy: TRADER_WALLET_ADDRESS env missing");
        require(rootAddr  != address(0), "Deploy: root address zero");
        require(ownerAddr != address(0), "Deploy: owner address zero");

        console.log("==============================================");
        console.log(" Deploying BtcbotCommissionRouter (V3) to BSC mainnet");
        console.log("==============================================");
        console.log("  chainid     :", block.chainid);
        console.log("  block       :", block.number);
        console.log("");
        console.log("  Constructor parameters:");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V3  :", PANCAKE_V3_ROUTER_BSC);
        console.log("    trader      :", trader);
        console.log("    root        :", rootAddr);
        console.log("    owner       :", ownerAddr);
        console.log("==============================================");

        vm.startBroadcast();
        router = new BtcbotCommissionRouter(
            BTCB_BSC,
            USDT_BSC,
            PANCAKE_V3_ROUTER_BSC,
            trader,
            rootAddr,
            ownerAddr
        );
        vm.stopBroadcast();

        console.log("");
        console.log(">>> BtcbotCommissionRouter deployed at:", address(router));
    }
}
