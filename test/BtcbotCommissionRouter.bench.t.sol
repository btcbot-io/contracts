// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotCommissionRouter} from "../src/BtcbotCommissionRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockV3SwapRouter} from "./mocks/MockV3SwapRouter.sol";

/// @title batchSwapAndDistribute — gas profile (B2, sets TRADER_BATCH_MAX_LEGS)
/// @notice WORST-CASE legs: all 6 tiers funded with distinct non-self recipients + a
///         20% commission (under the 35% cap) → every leg fires 6 tier transfers + 1
///         user transfer + events. Bounds the max legs per tx on the LIVE V3 contract.
///         Run: forge test --match-path test/BtcbotCommissionRouter.bench.t.sol -vv
contract BtcbotCommissionRouterBenchTest is Test {
    BtcbotCommissionRouter router;
    MockERC20 btcb;
    MockERC20 usdt;
    MockV3SwapRouter v3;

    address constant TRADER = address(0xA77ade2);
    address constant ROOT = address(0xA0007);
    address constant OWNER = address(0x0E7e2);

    uint256 constant POOL = 100;
    uint256 constant AMT = 1e18;

    function setUp() public {
        btcb = new MockERC20("BTCB", "BTCB", 18);
        usdt = new MockERC20("USDT", "USDT", 18);
        v3 = new MockV3SwapRouter();
        router = new BtcbotCommissionRouter(address(btcb), address(usdt), address(v3), TRADER, ROOT, OWNER);
        v3.setRate(address(btcb), address(usdt), 100e18);
        usdt.mint(address(v3), 100_000_000e18);
        for (uint256 i = 0; i < POOL; i++) {
            address u = _user(i);
            btcb.mint(u, AMT);
            vm.prank(u);
            btcb.approve(address(router), type(uint256).max);
        }
    }

    function _user(uint256 i) internal pure returns (address) {
        // test-only deterministic address generator; cast is safe (tiny literals).
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(0x1000 + i));
    }

    function _buildLegs(uint256 n) internal pure returns (BtcbotCommissionRouter.UserLeg[] memory legs) {
        legs = new BtcbotCommissionRouter.UserLeg[](n);
        for (uint256 i = 0; i < n; i++) {
            BtcbotCommissionRouter.UserLeg memory leg;
            leg.user = _user(i);
            leg.amountIn = AMT;
            address[6] memory t;
            uint256[6] memory p;
            for (uint256 k = 0; k < 6; k++) {
                // forge-lint: disable-next-line(unsafe-typecast)
                t[k] = address(uint160(0x100000 + i * 6 + k));
            }
            p[0] = 8e18;
            p[1] = 4e18;
            p[2] = 2e18;
            p[3] = 1e18;
            p[4] = 1e18;
            p[5] = 4e18;
            leg.tierRecipients = t;
            leg.parts = p;
            legs[i] = leg;
        }
    }

    function _run(uint256 n) internal {
        BtcbotCommissionRouter.UserLeg[] memory legs = _buildLegs(n);
        uint256 minOut = n * 100e18;
        vm.prank(TRADER);
        uint256 g0 = gasleft();
        router.batchSwapAndDistribute(legs, minOut);
        uint256 used = g0 - gasleft();
        emit log_named_uint(string(abi.encodePacked("legs=", vm.toString(n), " total_gas")), used);
        emit log_named_uint("  per_leg_gas", used / n);
    }

    function test_gas_001() public {
        _run(1);
    }

    function test_gas_010() public {
        _run(10);
    }

    function test_gas_025() public {
        _run(25);
    }

    function test_gas_050() public {
        _run(50);
    }

    function test_gas_075() public {
        _run(75);
    }

    function test_gas_100() public {
        _run(100);
    }
}
