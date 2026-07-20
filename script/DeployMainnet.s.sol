// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BtcbotRouter} from "../src/BtcbotRouter.sol";

/// @title DeployMainnet — deploys BtcbotRouter to BSC mainnet (chainid 56)
/// @notice Direct ERC20.approve flow (no Permit2). User approves the deployed
///         router address for BTCB + USDT during onboarding.
contract DeployMainnet is Script {
    // BSC mainnet (chainid 56)
    address constant BTCB_BSC              = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant USDT_BSC              = 0x55d398326f99059fF775485246999027B3197955;
    address constant PANCAKE_V2_ROUTER_BSC = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function run() external returns (BtcbotRouter router) {
        require(block.chainid == 56, "DeployMainnet: not on BSC mainnet (chainid 56)");

        address trader = vm.envAddress("TRADER_WALLET_ADDRESS");
        // root and owner default to trader if not overridden — V1 single-key model.
        address rootAddr = vm.envOr("ROUTER_ROOT_ADDRESS", trader);
        address ownerAddr = vm.envOr("ROUTER_OWNER_ADDRESS", trader);

        require(trader != address(0),   "DeployMainnet: TRADER_WALLET_ADDRESS env missing");
        require(rootAddr != address(0), "DeployMainnet: root address zero");
        require(ownerAddr != address(0),"DeployMainnet: owner address zero");

        console.log("==============================================");
        console.log(" Deploying BtcbotRouter v2 (no Permit2) to BSC mainnet");
        console.log("==============================================");
        console.log("  chainid     :", block.chainid);
        console.log("  block       :", block.number);
        console.log("");
        console.log("  Constructor parameters:");
        console.log("    BTCB        :", BTCB_BSC);
        console.log("    USDT        :", USDT_BSC);
        console.log("    Pancake V2  :", PANCAKE_V2_ROUTER_BSC);
        console.log("    trader      :", trader);
        console.log("    root        :", rootAddr);
        console.log("    owner       :", ownerAddr);
        console.log("==============================================");

        vm.startBroadcast();
        router = new BtcbotRouter(
            BTCB_BSC,
            USDT_BSC,
            PANCAKE_V2_ROUTER_BSC,
            trader,
            rootAddr,
            ownerAddr
        );
        vm.stopBroadcast();

        console.log("");
        console.log(">>> BtcbotRouter deployed at:", address(router));
    }
}
