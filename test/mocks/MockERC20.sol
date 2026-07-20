// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockERC20 — a controllable ERC20 for testing
/// @notice Implements the IERC20 surface plus per-address "misbehavior" knobs that let
///         tests exercise the router's failover paths:
///
///           - `setBlacklisted(addr, true)` — any transfer to/from `addr` reverts with
///             "MockERC20: blacklisted". Models real-world USDT-style blacklisting.
///           - `setReturnsFalseTo(addr, true)` — any transfer with `to == addr` returns
///             `false` without reverting. Models non-standard ERC20 behavior where the
///             token deliberately fails-silently.
///
/// These are scoped per-recipient so a single MockERC20 instance can model "one tier
/// is blacklisted, another returns false, the rest behave normally" within a single test.
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    // ── per-recipient misbehavior knobs ──────────────────────────────────
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public returnsFalseTo;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    // ── knob setters ─────────────────────────────────────────────────────
    function setBlacklisted(address who, bool v) external {
        blacklisted[who] = v;
    }

    function setReturnsFalseTo(address who, bool v) external {
        returnsFalseTo[who] = v;
    }

    // ── minting / burning helpers (test-only) ────────────────────────────
    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ── IERC20 surface ───────────────────────────────────────────────────
    function transfer(address to, uint256 amount) external override returns (bool) {
        if (blacklisted[msg.sender] || blacklisted[to]) {
            revert("MockERC20: blacklisted");
        }
        if (returnsFalseTo[to]) return false;
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (blacklisted[from] || blacklisted[to]) {
            revert("MockERC20: blacklisted");
        }
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        if (returnsFalseTo[to]) return false;
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockERC20: insufficient balance");
        unchecked {
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
