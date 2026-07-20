// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BtcbotRouter} from "../src/BtcbotRouter.sol";

/// @title BtcbotRouter — constructor + admin tests
/// @dev Swap-path tests live in BtcbotRouter.swap.t.sol with mocks.
contract BtcbotRouterTest is Test {
    BtcbotRouter router;

    // Test addresses — deterministic for readable traces
    address constant BTCB = address(0xb7cb);
    address constant USDT = address(0x05d7);
    address constant PANCAKE = address(0xa11ce0);
    address constant TRADER = address(0x77ade2);
    address constant ROOT = address(0xa007);
    address constant OWNER = address(0x0e7e2);

    function setUp() public {
        router = new BtcbotRouter(BTCB, USDT, PANCAKE, TRADER, ROOT, OWNER);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(router.BTCB(), BTCB);
        assertEq(router.USDT(), USDT);
        assertEq(router.PANCAKE_ROUTER(), PANCAKE);
    }

    function test_constructor_setsMutableState() public view {
        assertEq(router.trader(), TRADER);
        assertEq(router.root(), ROOT);
        assertEq(router.owner(), OWNER);
        assertEq(router.pendingOwner(), address(0));
        assertFalse(router.paused());
    }

    function test_constants() public view {
        assertEq(uint256(router.N_TIERS()), 6);
        assertEq(uint256(router.ROOT_TIER_IDX()), 5);
        assertEq(router.MAX_COMMISSION_BPS(), 3500);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(BtcbotRouter.ZeroAddress.selector);
        new BtcbotRouter(address(0), USDT, PANCAKE, TRADER, ROOT, OWNER);
    }

    function test_setTrader_onlyOwner() public {
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouter.NotOwner.selector);
        router.setTrader(address(0x999));
    }

    function test_setTrader_ownerCanUpdate() public {
        vm.prank(OWNER);
        router.setTrader(address(0x999));
        assertEq(router.trader(), address(0x999));
    }

    function test_setPaused_onlyOwner() public {
        vm.prank(TRADER);
        vm.expectRevert(BtcbotRouter.NotOwner.selector);
        router.setPaused(true);
    }

    function test_setPaused_blocksSwaps() public {
        vm.prank(OWNER);
        router.setPaused(true);
        assertTrue(router.paused());
    }

    function test_transferOwnership_twoStep() public {
        address newOwner = address(0xCAFE);

        // Step 1: current owner proposes new owner
        vm.prank(OWNER);
        router.transferOwnership(newOwner);
        assertEq(router.pendingOwner(), newOwner);
        assertEq(router.owner(), OWNER);  // unchanged

        // Step 2: pending owner accepts
        vm.prank(newOwner);
        router.acceptOwnership();
        assertEq(router.owner(), newOwner);
        assertEq(router.pendingOwner(), address(0));
    }

    function test_acceptOwnership_revertsNonPending() public {
        vm.prank(OWNER);
        router.transferOwnership(address(0xCAFE));

        vm.prank(address(0xBAD));
        vm.expectRevert(BtcbotRouter.NotPendingOwner.selector);
        router.acceptOwnership();
    }

    function test_transferOwnership_zeroCancels() public {
        // First propose
        vm.prank(OWNER);
        router.transferOwnership(address(0xCAFE));
        assertEq(router.pendingOwner(), address(0xCAFE));

        // Then cancel by proposing zero
        vm.prank(OWNER);
        router.transferOwnership(address(0));
        assertEq(router.pendingOwner(), address(0));
    }
}
