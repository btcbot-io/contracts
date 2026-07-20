// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPancakeV3SwapRouter} from "./interfaces/IPancakeV3SwapRouter.sol";

/// @title BtcbotCommissionRouter — atomic swap + commission fan-out router, V3-native
/// @author btcbot operator (peer-reviewed by Claude + cowork + Slither, 2026-05-21)
/// @notice V3 successor of BtcbotRouter (v2). Same atomic 6-tier commission fan-out
///         logic, with three substantive changes:
///
///         1. **Swap routes through PancakeSwap V3** (`exactInputSingle`) on the BTCB/USDT
///            0.05% fee tier — ~100× the effective depth of the small V2 BTCB/USDT direct
///            pool. Slippage on $10k swap drops from ~4% (V2) to <0.1% (V3 0.05%).
///
///         2. **`swapRouter` is MUTABLE via `setSwapRouter` (onlyOwner)** — the lesson
///            from V2 where `PANCAKE_ROUTER` immutable forced a full redeploy + user
///            re-approval to switch DEX. With the setter pattern, switching V3 → V4 → 1inch
///            (or any future DEX) becomes a single onlyOwner tx. The fan-out logic itself
///            (the security-critical part that moves user funds) remains immutable in code,
///            so the contract stays auditable-once. See cowork Q1 review.
///
///         3. **Renamed from "Router" to "CommissionRouter"** — technically more accurate.
///            A "router" in DEX vocabulary computes and executes a swap path. We don't
///            route; we wrap an external router and add atomic commission fan-out — that
///            fan-out is the distinctive function, hence the name.
///
///         See `docs/v3_migration_design.md` for the full design + cowork review notes.
///
/// Onboarding (per user, one-time):
///   1. user calls USDT.approve(BtcbotCommissionRouter, max)  — pays ~$0.05 gas
///   2. user calls BTCB.approve(BtcbotCommissionRouter, max)  — pays ~$0.05 gas
///   3. bot is then free to trade via swapAndDistribute / swapUsdtToBtcb
///
/// Tier index convention in arrays (unchanged from V2):
///   tierRecipients[0..4] / parts[0..4]  → tiers 1..5 (uplines)
///   tierRecipients[5]    / parts[5]     → tier 0     (root / project)
///
/// Centralization caveat for `setSwapRouter`:
///   A compromised owner could redirect swaps to a malicious DEX that keeps the input
///   token without delivering output. Defenses already in the contract still hold:
///   `amountOutMinimum` (passed to V3) reverts if delivered < expected, and the post-swap
///   commission cap (`MAX_COMMISSION_BPS`) catches garbage outputs. But a smart malicious
///   router could in theory exfiltrate via fees/dust — same trust scope as `setTrader` /
///   `setRoot`. Acceptable for V1 friends-only. Hardening for public launch: 48h timelock
///   on `setSwapRouter` — deliberately out-of-scope for V1.
contract BtcbotCommissionRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants & immutable config
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Number of tier slots in the fan-out (5 uplines + 1 root = 6).
    uint8 public constant N_TIERS = 6;

    /// @notice Array index of the root tier (tier 0 in business terms).
    uint8 public constant ROOT_TIER_IDX = 5;

    /// @notice Sanity cap on total commission as basis points of usdtOut.
    ///         Set to 35% (3500 bps) — 5% margin above the 30% commission target locked-in
    ///         2026-05-19. Lowering the rate needs no contract change; only raising the rate
    ///         above 35% would require a redeploy.
    uint256 public constant MAX_COMMISSION_BPS = 3500;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice PancakeSwap V3 BTCB/USDT pool fee tier (500 = 0.05%). This is the deep
    ///         pool — the other tiers (0.01%, 0.25%, 1%) exist but have far less liquidity
    ///         for this pair. Changing fee tier within BTCB/USDT requires redeploy (the
    ///         setter only changes the SwapRouter address, not the pool fee).
    uint24 public constant POOL_FEE = 500;

    /// @notice `sqrtPriceLimitX96 = 0` means "no price limit" at the V3 level. Per cowork
    ///         Q4: `amountOutMinimum` already provides equivalent slippage protection
    ///         without the risk of mis-encoding Q64.96 fixed-point math.
    uint160 private constant SQRT_PRICE_LIMIT = 0;

    /// @notice BSC mainnet BTCB (BSC-pegged BTC).
    address public immutable BTCB;
    /// @notice BSC mainnet USDT (BSC-pegged Tether).
    address public immutable USDT;

    // ─────────────────────────────────────────────────────────────────────
    // Mutable state (owner-controlled)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice The DEX SwapRouter we currently route swaps through. MUTABLE via
    ///         `setSwapRouter` — see cowork Q1 rationale at the contract header.
    address public swapRouter;

    /// @notice Contract administrator. Can update trader, root, swap router, pause, rescue.
    address public owner;

    /// @notice The only address allowed to call swap functions. Typically the trader bot wallet.
    address public trader;

    /// @notice Fallback recipient if a tier USDT.transfer fails (e.g. Tether blacklist).
    ///         Must be an EOA — never a contract that could revert on receive.
    address public root;

    /// @notice Emergency kill switch. When `true`, all swap functions revert.
    bool public paused;

    /// @notice Two-step ownership transfer (OpenZeppelin Ownable2Step pattern).
    address public pendingOwner;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event SwapAndDistribute(
        address indexed user,
        uint256 btcbIn,
        uint256 usdtOut,
        uint256 commissionTotal,
        uint256 userReceived
    );
    event SwapUsdtToBtcb(address indexed user, uint256 usdtIn, uint256 btcbOut);

    /// @notice Emitted for each successful tier transfer.
    /// @param tier Business tier number: 1..5 for uplines, 0 for root.
    event TierPaid(address indexed user, address indexed recipient, uint8 tier, uint256 amount);

    /// @notice Emitted when recipient == user (self-pay short-circuit). No on-chain
    ///         USDT.transfer is performed; the amount accumulates into userReceived.
    event TierSelfPaySkipped(address indexed user, uint8 tier, uint256 amount);

    /// @notice Emitted when a tier USDT.transfer fails and the amount falls back to root.
    event TierFailoverToRoot(
        address indexed user,
        address indexed originalRecipient,
        uint8 tier,
        uint256 amount
    );

    event TraderUpdated(address indexed oldTrader, address indexed newTrader);
    event RootUpdated(address indexed oldRoot, address indexed newRoot);
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event Rescued(address indexed token, uint256 amount, address indexed to);

    /// @notice Summary of a batchSwapAndDistribute call.
    event BatchSwapAndDistribute(uint256 totalBtcbIn, uint256 totalUsdtOut, uint256 nFilled, uint256 nSkipped);
    /// @notice A leg was skipped (not reverted) — reason: 1=zero/invalid, 2=transferFrom failed.
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);
    /// @notice A leg's commission exceeded the cap → skipped (user made whole), batch continued.
    event LegCommissionSkipped(address indexed user, uint256 attemptedCommission, uint256 userGross);

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    error NotOwner();
    error NotTrader();
    error ZeroAddress();
    error CommissionTooHigh();
    error InsufficientOutput();
    error InsufficientBtcbOut();
    error IsPaused();
    error NothingToRescue();
    error NotPendingOwner();
    error EmptyBatch();

    // ─────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier onlyTrader() {
        if (msg.sender != trader) revert NotTrader();
        _;
    }
    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(
        address _btcb,
        address _usdt,
        address _swapRouter,
        address _trader,
        address _root,
        address _owner
    ) {
        if (
            _btcb == address(0) || _usdt == address(0) || _swapRouter == address(0)
                || _trader == address(0) || _root == address(0) || _owner == address(0)
        ) revert ZeroAddress();
        BTCB = _btcb;
        USDT = _usdt;
        swapRouter = _swapRouter;
        trader = _trader;
        root = _root;
        owner = _owner;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Main swap functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Execute a SELL (BTCB → USDT) with atomic commission fan-out.
    /// @dev    User must have called `BTCB.approve(BtcbotCommissionRouter, ≥amountIn)`.
    ///         Sequence:
    ///   1. Pull BTCB from user via ERC20.transferFrom.
    ///   2. Sum commission and compute V3 floor as `minUserReceived + sum(parts)`.
    ///   3. forceApprove the current swapRouter to spend the pulled BTCB.
    ///   4. exactInputSingle (BTCB → USDT) with the computed floor, output to this contract.
    ///   5. Sanity-check commission ≤ MAX_COMMISSION_BPS of usdtOut.
    ///   6. Defense-in-depth: usdtOut must cover commission + user floor.
    ///   7. Fan-out per tier with self-pay short-circuit and failover-to-root.
    ///   8. Transfer remainder to user.
    function swapAndDistribute(
        address user,
        uint256 amountIn,
        uint256 minUserReceived,
        address[N_TIERS] calldata tierRecipients,
        uint256[N_TIERS] calldata parts
    ) external onlyTrader whenNotPaused nonReentrant returns (uint256 userReceived) {
        if (user == address(0)) revert ZeroAddress();

        // 1. Pull BTCB from user → this contract.
        IERC20(BTCB).safeTransferFrom(user, address(this), amountIn);

        // 2. Sum commission and compute V3 minOut.
        uint256 totalCommission;
        unchecked {
            totalCommission = parts[0] + parts[1] + parts[2] + parts[3] + parts[4] + parts[5];
        }
        uint256 swapMinOut = minUserReceived + totalCommission;

        // 3. Approve the V3 SwapRouter to spend the pulled BTCB.
        IERC20(BTCB).forceApprove(swapRouter, amountIn);

        // 4. V3 exactInputSingle BTCB → USDT (SwapRouter02-style, no deadline field).
        IPancakeV3SwapRouter.ExactInputSingleParams memory swapParams = IPancakeV3SwapRouter
            .ExactInputSingleParams({
            tokenIn: BTCB,
            tokenOut: USDT,
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: swapMinOut,
            sqrtPriceLimitX96: SQRT_PRICE_LIMIT
        });
        uint256 usdtOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(swapParams);

        // 5. Commission sanity cap (only checkable post-swap — depends on usdtOut).
        if (totalCommission * BPS_DENOMINATOR > usdtOut * MAX_COMMISSION_BPS) {
            revert CommissionTooHigh();
        }
        // 6. Defense-in-depth. V3 should have enforced this already via amountOutMinimum.
        if (usdtOut < swapMinOut) revert InsufficientOutput();

        // 7. Fan-out (clean self-pay branch — no deduct-then-undeduct).
        userReceived = usdtOut;
        for (uint256 i = 0; i < N_TIERS; i++) {
            uint256 part = parts[i];
            if (part == 0) continue;

            // i ∈ [0, N_TIERS-1=5], so uint8 cast is always safe.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tierLabel = (i == ROOT_TIER_IDX) ? 0 : uint8(i + 1);
            address recipient = tierRecipients[i];

            if (recipient == user) {
                // Self-pay short-circuit: keep `part` in `userReceived` (no deduction).
                emit TierSelfPaySkipped(user, tierLabel, part);
                continue;
            }
            userReceived -= part;

            // Try the transfer; on failure (revert OR returns-false), failover to root.
            (bool success, bytes memory ret) = USDT.call(
                abi.encodeWithSelector(IERC20.transfer.selector, recipient, part)
            );
            bool ok = success && (
                ret.length == 0 ||
                (ret.length == 32 && abi.decode(ret, (bool)))
            );
            if (ok) {
                emit TierPaid(user, recipient, tierLabel, part);
            } else {
                // Failover to root. safeTransfer here because root must never fail —
                // if it does, the whole tx reverts (user keeps BTCB).
                IERC20(USDT).safeTransfer(root, part);
                emit TierFailoverToRoot(user, recipient, tierLabel, part);
            }
        }

        // 8. Send remainder to user.
        IERC20(USDT).safeTransfer(user, userReceived);

        emit SwapAndDistribute(user, amountIn, usdtOut, totalCommission, userReceived);
    }

    /// @notice One user's leg in a batch SELL. Same per-user inputs as
    ///         swapAndDistribute, MINUS the per-user floor — the batch enforces one
    ///         aggregate `minTotalUsdtOut`; all legs fill at the same pro-rata price,
    ///         so each leg's share is ≥ its proportional floor.
    struct UserLeg {
        address user;                     // user's wallet
        uint256 amountIn;                 // BTCB to sell for this user (18-dec)
        address[N_TIERS] tierRecipients;  // 6 upline addrs: tiers 1..5 + root@idx 5
        uint256[N_TIERS] parts;           // 6 commission USDT amounts (pnl × share_pct)
    }

    /// @notice Execute MANY users' SELLs as ONE aggregated V3 swap + per-user commission
    ///         fan-out, in a single tx (the Tier-2 SCALE path). Instead of N serial swaps
    ///         drifting the price over minutes, all legs fill at the SAME price in ONE
    ///         block. Non-custodial: each leg's BTCB is pulled via that user's own approval,
    ///         swapped, and returned to that same user (minus their commission to their own
    ///         upline). See docs/tier2_batched_swap_design.md.
    /// @dev    GUARDRAILS — one bad leg NEVER sinks the batch:
    ///   - per-leg `transferFrom` is FAILURE-ISOLATED (low-level call): a revoked
    ///     approval / off-bot-swapped / empty-balance user is SKIPPED (LegSkipped),
    ///     not reverted. Only successfully-pulled legs join the swap + distribution.
    ///   - ONE V3 `exactInputSingle` of the summed pulled BTCB, floored by `minTotalUsdtOut`.
    ///   - per-leg pro-rata gross = amountIn × totalUsdtOut / totalIn (same price all).
    ///   - per-leg commission cap (≤35% of that leg's gross): an over-cap leg has its
    ///     commission SKIPPED (user made whole) + LegCommissionSkipped — never reverts.
    ///   - per-leg tier fan-out reuses the single-user logic: self-pay short-circuit +
    ///     low-level transfer with failover-to-root (a blacklisted recipient can't grief).
    ///   - reverts ONLY on: not-trader, paused, empty batch, nothing-pulled, or the
    ///     aggregate swap missing `minTotalUsdtOut` (protects everyone at once).
    ///   - solvency: Σ(userReceived + commission) = Σ userGross ≤ totalUsdtOut; the
    ///     truncation dust (≤ a few wei × legs) stays in the contract → rescueToken.
    /// @param legs Per-user legs (the trader chunks the full set by gas; TRADER_BATCH_MAX_LEGS).
    /// @param minTotalUsdtOut Aggregate slippage floor for the single V3 swap.
    /// @return totalUsdtOut USDT received from the aggregate swap.
    /// @return nFilled Number of legs successfully pulled + distributed.
    function batchSwapAndDistribute(UserLeg[] calldata legs, uint256 minTotalUsdtOut)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        returns (uint256 totalUsdtOut, uint256 nFilled)
    {
        uint256 n = legs.length;
        if (n == 0) revert EmptyBatch();

        // ── Pass 1: pull each leg's BTCB, FAILURE-ISOLATED. Track what we got. ──
        uint256 totalIn;
        uint256[] memory pulled = new uint256[](n); // 0 ⇒ leg skipped
        for (uint256 i = 0; i < n; i++) {
            address u = legs[i].user;
            uint256 amt = legs[i].amountIn;
            if (u == address(0) || amt == 0) {
                emit LegSkipped(u, i, 1); // 1 = zero/invalid leg
                continue;
            }
            // Low-level transferFrom so a revoked approval / empty balance can't revert
            // the whole batch (that would block every other user's exit).
            (bool ok, bytes memory ret) = BTCB.call(
                abi.encodeWithSelector(IERC20.transferFrom.selector, u, address(this), amt)
            );
            bool got = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
            if (!got) {
                emit LegSkipped(u, i, 2); // 2 = transferFrom failed (approval/balance)
                continue;
            }
            pulled[i] = amt;
            totalIn += amt;
            nFilled++;
        }
        if (totalIn == 0) revert EmptyBatch(); // every leg skipped

        // ── One aggregated V3 swap (BTCB → USDT), floored. ──
        IERC20(BTCB).forceApprove(swapRouter, totalIn);
        IPancakeV3SwapRouter.ExactInputSingleParams memory swapParams = IPancakeV3SwapRouter
            .ExactInputSingleParams({
            tokenIn: BTCB,
            tokenOut: USDT,
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: totalIn,
            amountOutMinimum: minTotalUsdtOut,
            sqrtPriceLimitX96: SQRT_PRICE_LIMIT
        });
        totalUsdtOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(swapParams);
        if (totalUsdtOut < minTotalUsdtOut) revert InsufficientOutput(); // defense-in-depth

        // ── Pass 2: per-leg pro-rata distribution + commission fan-out. ──
        for (uint256 i = 0; i < n; i++) {
            uint256 amt = pulled[i];
            if (amt == 0) continue; // skipped in pass 1
            address u = legs[i].user;

            // Same price for everyone: this leg's share of the aggregate output.
            uint256 userGross = (amt * totalUsdtOut) / totalIn; // truncates → dust stays

            uint256 totalCommission;
            for (uint256 t = 0; t < N_TIERS; t++) {
                totalCommission += legs[i].parts[t];
            }
            // Per-leg cap: an over-35% leg (trader mis-priced) has its commission
            // SKIPPED so the user is made whole — never revert the whole batch.
            if (totalCommission * BPS_DENOMINATOR > userGross * MAX_COMMISSION_BPS) {
                emit LegCommissionSkipped(u, totalCommission, userGross);
                totalCommission = 0;
            }

            uint256 userReceived = userGross;
            if (totalCommission > 0) {
                for (uint256 t = 0; t < N_TIERS; t++) {
                    uint256 part = legs[i].parts[t];
                    if (part == 0) continue;
                    // t ∈ [0, N_TIERS-1=5], so uint8 cast is always safe.
                    // forge-lint: disable-next-line(unsafe-typecast)
                    uint8 tierLabel = (t == ROOT_TIER_IDX) ? 0 : uint8(t + 1);
                    address recipient = legs[i].tierRecipients[t];
                    if (recipient == u) {
                        emit TierSelfPaySkipped(u, tierLabel, part);
                        continue;
                    }
                    userReceived -= part;
                    (bool s, bytes memory r) = USDT.call(
                        abi.encodeWithSelector(IERC20.transfer.selector, recipient, part)
                    );
                    bool paid = s && (r.length == 0 || (r.length == 32 && abi.decode(r, (bool))));
                    if (paid) {
                        emit TierPaid(u, recipient, tierLabel, part);
                    } else {
                        IERC20(USDT).safeTransfer(root, part);
                        emit TierFailoverToRoot(u, recipient, tierLabel, part);
                    }
                }
            }
            IERC20(USDT).safeTransfer(u, userReceived);
            // Reuse the single-user event so the trader's receipt parser works per leg.
            emit SwapAndDistribute(u, amt, userGross, totalCommission, userReceived);
        }

        emit BatchSwapAndDistribute(totalIn, totalUsdtOut, nFilled, n - nFilled);
    }

    /// @notice Execute a BUY (USDT → BTCB). No commission — BUYs aren't taxable events.
    /// @dev    User must have called `USDT.approve(BtcbotCommissionRouter, ≥amountIn)`.
    function swapUsdtToBtcb(address user, uint256 amountIn, uint256 minBtcbOut)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        returns (uint256 btcbOut)
    {
        if (user == address(0)) revert ZeroAddress();

        IERC20(USDT).safeTransferFrom(user, address(this), amountIn);
        IERC20(USDT).forceApprove(swapRouter, amountIn);

        IPancakeV3SwapRouter.ExactInputSingleParams memory swapParams = IPancakeV3SwapRouter
            .ExactInputSingleParams({
            tokenIn: USDT,
            tokenOut: BTCB,
            fee: POOL_FEE,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: minBtcbOut,
            sqrtPriceLimitX96: SQRT_PRICE_LIMIT
        });
        btcbOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(swapParams);

        if (btcbOut < minBtcbOut) revert InsufficientBtcbOut();

        IERC20(BTCB).safeTransfer(user, btcbOut);
        emit SwapUsdtToBtcb(user, amountIn, btcbOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner admin functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Update the DEX SwapRouter address. Per cowork Q1: this is THE difference
    ///         that justifies the redeploy from V2 — V2 had `PANCAKE_ROUTER immutable`
    ///         which forced this whole sprint. With this setter, switching V3 → V4 → 1inch
    ///         (or any future DEX with the V3-compatible exactInputSingle signature) is a
    ///         single onlyOwner tx. The fan-out logic stays immutable.
    /// @dev    Trust scope: a compromised owner can redirect swaps. Same as setTrader /
    ///         setRoot — acceptable for V1 friends-only. Add a 48h timelock for public.
    function setSwapRouter(address newSwapRouter) external onlyOwner {
        if (newSwapRouter == address(0)) revert ZeroAddress();
        emit SwapRouterUpdated(swapRouter, newSwapRouter);
        swapRouter = newSwapRouter;
    }

    function setTrader(address newTrader) external onlyOwner {
        if (newTrader == address(0)) revert ZeroAddress();
        emit TraderUpdated(trader, newTrader);
        trader = newTrader;
    }

    function setRoot(address newRoot) external onlyOwner {
        if (newRoot == address(0)) revert ZeroAddress();
        emit RootUpdated(root, newRoot);
        root = newRoot;
    }

    /// @notice Step 1 of 2 in ownership transfer. Two-step pattern prevents accidentally
    ///         bricking the contract by sending ownership to a wrong address.
    /// @dev    Passing `address(0)` is INTENTIONAL — it cancels any pending transfer.
    // slither-disable-next-line missing-zero-check
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferStarted(owner, newOwner);
        pendingOwner = newOwner;
    }

    /// @notice Step 2 of 2 in ownership transfer. Caller must be the pending owner.
    function acceptOwnership() external {
        address sender = msg.sender;
        if (sender != pendingOwner) revert NotPendingOwner();
        emit OwnerTransferred(owner, sender);
        owner = sender;
        delete pendingOwner;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Recover tokens stuck in the contract. CEI pattern: emit first, then transfer.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToRescue();
        emit Rescued(token, amount, to);
        IERC20(token).safeTransfer(to, amount);
    }
}
