// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPancakeV2Router} from "./interfaces/IPancakeV2Router.sol";

/// @title BtcbotRouter — atomic swap + commission fan-out router for btcbot on BSC
/// @author btcbot operator (peer-reviewed by Claude + Slither, 2026-05-19)
/// @notice See `docs/btcbot_router_spec.md` for full design rationale, threat model,
///         and invariants. This contract is intentionally minimal: it pulls the input
///         token from the user via standard ERC20 `transferFrom` (user must have
///         pre-approved this contract), swaps via PancakeSwap V2, then atomically
///         distributes the commission to 6 tier recipients before sending the user
///         their remainder. All in one transaction — no escrow, no async settlement.
///
/// Onboarding (per user, one-time):
///   1. user calls USDT.approve(BtcbotRouter, max)  — pays ~$0.05 gas
///   2. user calls BTCB.approve(BtcbotRouter, max)  — pays ~$0.05 gas
///   3. user is now ready; bot freely trades via swapAndDistribute / swapUsdtToBtcb
///
/// Why direct approve (not Permit2) — decision 2026-05-19:
///   - Permit2 SignatureTransfer requires a per-trade signed message off-chain, which
///     doesn't fit a bot trading on schedule while the user is offline.
///   - Permit2 AllowanceTransfer adds a layer of indirection with no concrete benefit
///     for a friends-only V1 with a single consumer contract.
///   - Direct ERC20 approve is the time-tested pattern from Uniswap V2 / Pancake V2.
///
/// Tier index convention in arrays:
///   tierRecipients[0..4] / parts[0..4]  → tiers 1..5 (uplines)
///   tierRecipients[5]    / parts[5]     → tier 0     (root / project)
///
/// Trader sets `parts[]` off-chain based on the user's pre-materialised referrals
/// chain and the per-trade PnL. The contract sanity-checks `sum(parts) ≤ usdtOut ×
/// MAX_COMMISSION_BPS` to bound trader-side bugs.
contract BtcbotRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants & immutable config
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Number of tier slots in the fan-out (5 uplines + 1 root = 6).
    uint8 public constant N_TIERS = 6;

    /// @notice Array index of the root tier (tier 0 in business terms).
    uint8 public constant ROOT_TIER_IDX = 5;

    /// @notice Sanity cap on total commission as basis points of usdtOut.
    ///         Set to 35% (3500 bps) — 5% margin above the 30% commission target
    ///         locked-in 2026-05-19. Allows the operator to lower the rate at will
    ///         (no contract change needed); only an UPWARD rate change beyond 35%
    ///         would require a redeploy.
    uint256 public constant MAX_COMMISSION_BPS = 3500;

    /// @notice Basis points denominator (10000 = 100%).
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice BSC mainnet BTCB (BSC-pegged BTC).
    address public immutable BTCB;
    /// @notice BSC mainnet USDT (BSC-pegged Tether).
    address public immutable USDT;
    /// @notice PancakeSwap V2 router (BSC mainnet 0x10ED43C7…56024E).
    address public immutable PANCAKE_ROUTER;

    // ─────────────────────────────────────────────────────────────────────
    // Mutable state (owner-controlled)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Contract administrator. Can update trader, root, pause, and rescue.
    address public owner;

    /// @notice The only address allowed to call swap functions. Typically the
    ///         btcbot trader bot's hot wallet.
    address public trader;

    /// @notice Fallback recipient if a tier USDT.transfer fails (e.g. Tether blacklist).
    ///         Must be an EOA controlled by the operator — never a contract that could
    ///         revert on receive. Usually the project owner's main wallet.
    address public root;

    /// @notice Emergency kill switch. When `true`, all swap functions revert.
    bool public paused;

    /// @notice Two-step ownership transfer. `transferOwnership` only proposes a new
    ///         owner; the new owner must `acceptOwnership` to take over.
    ///         Prevents accidentally bricking the contract by sending ownership to a
    ///         wrong address. Pattern modeled on OpenZeppelin Ownable2Step.
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
    /// @notice Emitted when `transferOwnership` proposes a new owner (step 1 of 2).
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    /// @notice Emitted when `acceptOwnership` completes the transfer (step 2 of 2).
    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event PausedSet(bool paused);
    event Rescued(address indexed token, uint256 amount, address indexed to);

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
        address _pancakeRouter,
        address _trader,
        address _root,
        address _owner
    ) {
        if (
            _btcb == address(0) || _usdt == address(0) || _pancakeRouter == address(0)
                || _trader == address(0) || _root == address(0) || _owner == address(0)
        ) revert ZeroAddress();
        BTCB = _btcb;
        USDT = _usdt;
        PANCAKE_ROUTER = _pancakeRouter;
        trader = _trader;
        root = _root;
        owner = _owner;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Main swap functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Execute a SELL (BTCB → USDT) with atomic commission fan-out.
    /// @dev    User must have called `BTCB.approve(BtcbotRouter, ≥amountIn)` beforehand.
    ///         Sequence:
    ///   1. Pull BTCB from user via ERC20.transferFrom.
    ///   2. Sum commission and compute Pancake floor as `minUserReceived + sum(parts)`.
    ///   3. Approve Pancake to spend the pulled BTCB.
    ///   4. Swap BTCB → USDT with the computed floor, output to this contract.
    ///   5. Sanity-check commission ≤ MAX_COMMISSION_BPS of usdtOut.
    ///   6. Defense-in-depth: usdtOut must cover commission + user floor.
    ///   7. Fan-out per tier with self-pay short-circuit and failover-to-root.
    ///   8. Transfer remainder to user.
    /// @param user The user's wallet address. Trader is trusted to supply the right one.
    /// @param amountIn BTCB amount to sell (in token units, 18 decimals).
    /// @param minUserReceived Minimum USDT the user must receive AFTER commission.
    /// @param tierRecipients Array of 6 addresses: tiers 1..5 + root at index 5.
    /// @param parts Per-tier USDT amounts (sum = total commission).
    /// @return userReceived The USDT amount actually sent to the user.
    function swapAndDistribute(
        address user,
        uint256 amountIn,
        uint256 minUserReceived,
        address[N_TIERS] calldata tierRecipients,
        uint256[N_TIERS] calldata parts
    ) external onlyTrader whenNotPaused nonReentrant returns (uint256 userReceived) {
        if (user == address(0)) revert ZeroAddress();

        // 1. Pull BTCB from user → this contract (user must have pre-approved).
        IERC20(BTCB).safeTransferFrom(user, address(this), amountIn);

        // 2. Sum commission and compute the Pancake floor.
        uint256 totalCommission;
        unchecked {
            // 6 parts × max(uint256) overflow is impossible with realistic USDT amounts.
            // The post-swap cap check would catch any garbage anyway.
            totalCommission = parts[0] + parts[1] + parts[2] + parts[3] + parts[4] + parts[5];
        }
        // pancakeMinOut = user-net floor + total commission. Reverts on overflow (checked math).
        uint256 pancakeMinOut = minUserReceived + totalCommission;

        // 3. Approve Pancake for this exact BTCB amount.
        IERC20(BTCB).forceApprove(PANCAKE_ROUTER, amountIn);

        // 4. Swap BTCB → USDT to this contract.
        address[] memory path = new address[](2);
        path[0] = BTCB;
        path[1] = USDT;
        uint256[] memory amounts = IPancakeV2Router(PANCAKE_ROUTER).swapExactTokensForTokens(
            amountIn,
            pancakeMinOut,
            path,
            address(this),
            block.timestamp
        );
        // Use amounts[length-1] for multi-hop safety.
        uint256 usdtOut = amounts[amounts.length - 1];

        // 5. Commission sanity cap (only checkable post-swap — depends on usdtOut).
        if (totalCommission * BPS_DENOMINATOR > usdtOut * MAX_COMMISSION_BPS) {
            revert CommissionTooHigh();
        }
        // 6. Defense-in-depth. Pancake should have enforced this already.
        if (usdtOut < pancakeMinOut) revert InsufficientOutput();

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
            // Low-level call so a malicious/blacklisted token can't grief us with a revert.
            // Guard against unexpected return-data lengths before decoding.
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
                // Failover: route to root. safeTransfer here because root must never fail —
                // if it does, the whole tx reverts (user keeps BTCB).
                IERC20(USDT).safeTransfer(root, part);
                emit TierFailoverToRoot(user, recipient, tierLabel, part);
            }
        }

        // 8. Send remainder to user.
        IERC20(USDT).safeTransfer(user, userReceived);

        emit SwapAndDistribute(user, amountIn, usdtOut, totalCommission, userReceived);
    }

    /// @notice Execute a BUY (USDT → BTCB). No commission — BUYs aren't taxable events.
    /// @dev    User must have called `USDT.approve(BtcbotRouter, ≥amountIn)` beforehand.
    /// @param user The user's wallet address.
    /// @param amountIn USDT amount to spend.
    /// @param minBtcbOut Minimum BTCB output (slippage protection).
    /// @return btcbOut The BTCB amount actually sent to the user.
    function swapUsdtToBtcb(address user, uint256 amountIn, uint256 minBtcbOut)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        returns (uint256 btcbOut)
    {
        if (user == address(0)) revert ZeroAddress();

        IERC20(USDT).safeTransferFrom(user, address(this), amountIn);
        IERC20(USDT).forceApprove(PANCAKE_ROUTER, amountIn);

        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = BTCB;
        uint256[] memory amounts = IPancakeV2Router(PANCAKE_ROUTER).swapExactTokensForTokens(
            amountIn,
            minBtcbOut,
            path,
            address(this),
            block.timestamp
        );
        // amounts[length-1] for multi-hop safety.
        btcbOut = amounts[amounts.length - 1];
        if (btcbOut < minBtcbOut) revert InsufficientBtcbOut();

        IERC20(BTCB).safeTransfer(user, btcbOut);
        emit SwapUsdtToBtcb(user, amountIn, btcbOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner admin functions
    // ─────────────────────────────────────────────────────────────────────

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

    /// @notice Step 1 of 2 in ownership transfer. Sets the pending owner without
    ///         changing the current owner. The pending owner must call
    ///         `acceptOwnership` to complete the transfer.
    /// @dev    Passing `address(0)` is INTENTIONAL — it cancels any pending
    ///         transfer. The two-step pattern ensures a wrong address never
    ///         takes ownership (acceptOwnership would never be called).
    // slither-disable-next-line missing-zero-check
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferStarted(owner, newOwner);
        pendingOwner = newOwner;
    }

    /// @notice Step 2 of 2 in ownership transfer. Caller must be the `pendingOwner`.
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

    /// @notice Recover tokens stuck in the contract (e.g. someone sent directly).
    ///         CEI pattern: emit event first, then external call. Defensive even
    ///         though onlyOwner-gated.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToRescue();
        emit Rescued(token, amount, to);
        IERC20(token).safeTransfer(to, amount);
    }
}
