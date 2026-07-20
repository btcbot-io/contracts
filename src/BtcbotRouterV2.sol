// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IPancakeV3SwapRouter} from "./interfaces/IPancakeV3SwapRouter.sol";

/// @notice Minimal Chainlink AggregatorV3 read interface (BSC BTC/USD + USDT/USD feeds).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title BtcbotRouterV2 — Blockaid-"trusted" hardening of BtcbotRouterDuplex
/// @author btcbot operator (spec: docs/btcbot_router_v2_spec.md; audit fixes 2026-06-29)
/// @notice V2 moves trade-term authority OFF the trader and onto on-chain + user-signed
///         limits, while keeping the trader's timing/sizing autonomy (essential for an
///         autonomous grid bot). Post-audit hardening (H-01/M-01/M-02/L-01..L-04):
///
///   #7 ORACLE FLOOR — every swap is floored by Chainlink BTC/USD ÷ USDT/USD minus a bounded
///      max-slippage; the contract enforces `amountOut >= max(traderMinOut, oracleFloor)`.
///      Using BOTH feeds makes the floor robust to a USDT depeg. Primary anti-drain control.
///
///   #1/#2 SESSION MANDATE — the user signs ONE EIP-712 mandate bounding maxNotionalPerTrade,
///      **maxCumulativeNotional** (total volume over the mandate's life — caps a compromised
///      relayer's churn), maxCommissionBps, maxSlippageBps, expiry, nonce. Register-once,
///      revocable on-chain (`cancelMandate` / `cancelUpToNonce`). Nonces are strictly
///      increasing — an older signed mandate can NOT be replayed to roll back a newer one.
///
///   #6 ON-CHAIN COMMISSION RECIPIENTS — sell-commission recipients are derived from an
///      on-chain referral tree (`uplines[user]` + global `root`), NOT passed by the trader.
///      Totals capped by the user-signed `maxCommissionBps`. Vacant uplines roll to root.
///
///   #5 setSwapRouter TIMELOCK — schedule -> 48h -> execute, constrained to an allowlist.
///   #4 DEADLINE — every swap fn takes `deadline`.
///
/// Non-custodial + benign: each swap returns 100% of the output to the SAME user; the relayer
/// (trader hot key) holds no custody. Ships PAUSED. Key split: owner=cold, trader=hot, root.
contract BtcbotRouterV2 is ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────
    // Constants & immutable config
    // ─────────────────────────────────────────────────────────────────────

    uint8 public constant N_TIERS = 6;
    uint8 public constant ROOT_TIER_IDX = 5;

    /// @notice SANITY cap on total commission as bps of usdtOut (GROSS proceeds) — a backstop,
    ///         NOT the rate. The rate (30%) is on the GAIN, and gain <= proceeds, so a correct
    ///         commission is only a few % of proceeds and this never binds normally. Lowered to
    ///         30% for public launch (audit M-03) — caps a compromised relayer's worst-case
    ///         over-declared commission. The per-user signed `maxCommissionBps` may be lower
    ///         (e.g. 1000 = 10% OG cohort) but never above this.
    uint256 public constant MAX_COMMISSION_BPS = 3000;
    uint256 private constant BPS_DENOMINATOR = 10000;

    uint24 public constant POOL_FEE = 500;
    uint160 private constant SQRT_PRICE_LIMIT = 0;

    /// @notice Absolute ceiling on the owner-set slippage tolerance — even a compromised owner
    ///         cannot widen the oracle band into a drain. 500 bps = 5%.
    uint16 public constant MAX_SLIPPAGE_BPS_CAP = 500;

    /// @notice Upper bound on `maxOracleAge` (audit L-02) — owner can't disable staleness.
    uint256 public constant MAX_ORACLE_AGE_CAP = 2 hours;

    /// @notice Max legs per batch (audit L-01) — operational guard-rail against a bot bug / an
    ///         un-gas-able tx. Larger fleets are processed as multiple batches (the relayer chunks).
    uint256 public constant MAX_BATCH_LEGS = 50;

    /// @notice setSwapRouter timelock delay (Blockaid #5).
    uint256 public constant SWAP_ROUTER_TIMELOCK = 48 hours;

    address public immutable BTCB;
    address public immutable USDT;

    /// @notice Chainlink feeds on BSC. Both MUST share the same decimals (asserted in the
    ///         constructor) so the floor ratio math is decimal-clean. Immutable: changing an
    ///         oracle = redeploy (auditable-once).
    address public immutable BTC_USD_FEED;
    address public immutable USDT_USD_FEED;
    uint8 private immutable FEED_DECIMALS;

    // ─────────────────────────────────────────────────────────────────────
    // Mutable state
    // ─────────────────────────────────────────────────────────────────────

    address public swapRouter;
    address public owner;
    address public trader;
    address public root;
    bool public paused;
    address public pendingOwner;

    /// @notice Max staleness for an oracle answer; older => revert. Bounded by MAX_ORACLE_AGE_CAP.
    uint256 public maxOracleAge = 1 hours;

    /// @notice Owner-set slippage tolerance vs the oracle, bps. Bounded by MAX_SLIPPAGE_BPS_CAP.
    ///         Effective per-swap slippage = min(this, mandate.maxSlippageBps).
    uint16 public ownerMaxSlippageBps = 200; // 2%

    // ── #1/#2 mandates ──
    struct TradeMandate {
        address user;
        uint256 maxNotionalPerTrade; // USD-notional cap per swap (18-dec) — both directions
        uint256 maxCumulativeNotional; // USD-notional cap over the WHOLE mandate (audit H-01)
        uint16 maxCommissionBps; // user-signed commission cap (<= MAX_COMMISSION_BPS)
        uint16 maxSlippageBps; // user's execution-quality floor vs oracle
        uint64 expiry; // mandate validity (unix s)
        uint96 nonce; // strictly increasing; for cancellation / re-issue
    }

    bytes32 private constant MANDATE_TYPEHASH = keccak256(
        "TradeMandate(address user,uint256 maxNotionalPerTrade,uint256 maxCumulativeNotional,uint16 maxCommissionBps,uint16 maxSlippageBps,uint64 expiry,uint96 nonce)"
    );

    mapping(address => TradeMandate) public mandates;
    /// @notice Lowest still-valid nonce per user. cancelUpToNonce bumps it to invalidate.
    mapping(address => uint96) public minNonce;
    /// @notice Cumulative USD notional consumed under the user's CURRENT mandate (audit H-01).
    ///         Reset to 0 each time a new mandate is registered.
    mapping(address => uint256) public mandateVolumeUsed;

    // ── #6 on-chain referral tree ──
    /// @notice user => [tier1..tier5] upline recipients. Set by owner from the off-chain
    ///         `referrals` table. address(0) in any slot rolls that slice up to `root`.
    mapping(address => address[5]) public uplines;

    // ── #5 setSwapRouter timelock ──
    mapping(address => bool) public allowedRouter;
    address public pendingSwapRouter;
    uint256 public swapRouterEta;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    event SwapAndDistribute(
        address indexed user, uint256 btcbIn, uint256 usdtOut, uint256 commissionTotal, uint256 userReceived
    );
    event SwapUsdtToBtcb(address indexed user, uint256 usdtIn, uint256 btcbOut);
    event TierPaid(address indexed user, address indexed recipient, uint8 tier, uint256 amount);
    event TierSelfPaySkipped(address indexed user, uint8 tier, uint256 amount);
    event TierFailoverToRoot(address indexed user, address indexed originalRecipient, uint8 tier, uint256 amount);
    event TierRefundedToUser(address indexed user, address indexed originalRecipient, uint8 tier, uint256 amount);

    event MandateRegistered(address indexed user, uint96 nonce, uint64 expiry);
    event MandateCancelled(address indexed user, uint96 newMinNonce);
    event UplinesSet(address indexed user);

    event TraderUpdated(address indexed oldTrader, address indexed newTrader);
    event RootUpdated(address indexed oldRoot, address indexed newRoot);
    event MaxSlippageUpdated(uint16 oldBps, uint16 newBps);
    event MaxOracleAgeUpdated(uint256 oldAge, uint256 newAge);
    event RouterAllowed(address indexed router, bool allowed);
    event SwapRouterChangeScheduled(address indexed router, uint256 executeAfter);
    event SwapRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
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
    error Expired();
    error BadSignature();
    error StaleNonce();
    error NoMandate();
    error MandateExpired();
    error ExceedsPerTrade();
    error ExceedsSessionLimit();
    error SlippageTooHigh();
    error OracleStale();
    error OracleBad();
    error FeedDecimalsMismatch();
    error RouterNotAllowed();
    error TimelockPending();
    error EmptyBatch();
    error BatchTooLarge();
    error ZeroAmount();

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
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Constructor — ships PAUSED (audit L-01)
    // ─────────────────────────────────────────────────────────────────────

    constructor(
        address _btcb,
        address _usdt,
        address _swapRouter,
        address _trader,
        address _root,
        address _owner,
        address _btcUsdFeed,
        address _usdtUsdFeed
    ) EIP712("BtcbotRouterV2", "1") {
        if (
            _btcb == address(0) || _usdt == address(0) || _swapRouter == address(0) || _trader == address(0)
                || _root == address(0) || _owner == address(0) || _btcUsdFeed == address(0) || _usdtUsdFeed == address(0)
        ) revert ZeroAddress();
        BTCB = _btcb;
        USDT = _usdt;
        swapRouter = _swapRouter;
        trader = _trader;
        root = _root;
        owner = _owner;
        BTC_USD_FEED = _btcUsdFeed;
        USDT_USD_FEED = _usdtUsdFeed;
        uint8 dec = IAggregatorV3(_btcUsdFeed).decimals();
        // both feeds must share decimals (clean ratio math) AND be in a sane range (audit L-02)
        if (dec == 0 || dec > 18 || IAggregatorV3(_usdtUsdFeed).decimals() != dec) revert FeedDecimalsMismatch();
        FEED_DECIMALS = dec;
        allowedRouter[_swapRouter] = true; // seed the allowlist with the launch router
        paused = true; // ship paused; owner unpauses after verification
    }

    // ─────────────────────────────────────────────────────────────────────
    // #7 Oracle price floor (BTC/USD ÷ USDT/USD — depeg-robust)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Read a Chainlink feed, reverting on a stale/invalid/incomplete answer.
    function _readFeed(address feed) internal view returns (uint256 px) {
        (uint80 roundId, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            IAggregatorV3(feed).latestRoundData();
        if (ans <= 0) revert OracleBad();
        if (updatedAt == 0 || startedAt == 0) revert OracleBad(); // incomplete round (audit L-02)
        if (updatedAt > block.timestamp) revert OracleBad(); // future-dated (audit L-02)
        if (answeredInRound < roundId) revert OracleStale(); // answer carried from a stale round
        if (block.timestamp - updatedAt > maxOracleAge) revert OracleStale();
        // `ans > 0` checked above, so the int256 -> uint256 cast cannot underflow.
        // forge-lint: disable-next-line(unsafe-typecast)
        px = uint256(ans);
    }

    function _btcUsd() internal view returns (uint256) {
        return _readFeed(BTC_USD_FEED);
    }

    function _usdtUsd() internal view returns (uint256) {
        return _readFeed(USDT_USD_FEED);
    }

    /// @notice Oracle-fair minimum USDT out for selling `btcbIn` BTCB, minus `slipBps`.
    ///         fair = btcbIn × (BTC/USD) ÷ (USDT/USD). Both feeds share decimals, so they
    ///         cancel; BTCB + USDT are both 18-dec on BSC → result is 18-dec USDT.
    function _floorUsdtOut(uint256 btcbIn, uint16 slipBps) internal view returns (uint256) {
        // multiply-before-divide (single division) — avoids precision loss on the floor
        return (btcbIn * _btcUsd() * (BPS_DENOMINATOR - slipBps)) / (_usdtUsd() * BPS_DENOMINATOR);
    }

    /// @notice Oracle-fair minimum BTCB out for spending `usdtIn` USDT, minus `slipBps`.
    function _floorBtcbOut(uint256 usdtIn, uint16 slipBps) internal view returns (uint256) {
        return (usdtIn * _usdtUsd() * (BPS_DENOMINATOR - slipBps)) / (_btcUsd() * BPS_DENOMINATOR);
    }

    /// @notice Effective slippage = min(owner cap, user-signed cap).
    function _effSlippage(uint16 mandateBps) internal view returns (uint16) {
        return mandateBps < ownerMaxSlippageBps ? mandateBps : ownerMaxSlippageBps;
    }

    /// @notice USD notional (18-dec) of `btcbIn`, via the BTC/USD oracle — for the caps.
    function _btcbToUsd(uint256 btcbIn) internal view returns (uint256) {
        return (btcbIn * _btcUsd()) / (10 ** FEED_DECIMALS);
    }

    // ─────────────────────────────────────────────────────────────────────
    // #1/#2 Session mandate
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Register a user-signed trade mandate. Anyone may submit (the signature is the
    ///         authorization). Nonces are STRICTLY INCREASING — a newer mandate can never be
    ///         rolled back by replaying an older signature (audit M-01).
    function registerMandate(TradeMandate calldata m, bytes calldata sig) external nonReentrant {
        if (m.user == address(0)) revert ZeroAddress();
        if (m.expiry <= block.timestamp) revert MandateExpired(); // reject already-expired (M-01)
        if (m.nonce == type(uint96).max) revert StaleNonce(); // reserve max (L-04: cancel wrap)
        if (m.nonce < minNonce[m.user]) revert StaleNonce();
        TradeMandate storage current = mandates[m.user];
        if (current.user == m.user && m.nonce <= current.nonce) revert StaleNonce(); // no rollback (M-01)
        // Only grant a FRESH cumulative budget when no prior mandate is still active (audit M-1):
        // carrying the spent volume forward across an EARLY re-registration stops a compromised
        // relayer from zeroing the anti-churn meter by submitting a newer (user-signed) mandate
        // before the current one expires. A natural expiry, or an explicit cancelMandate (which
        // deletes the mandate), re-enables the reset.
        bool priorActive = current.user == m.user && current.expiry >= block.timestamp;
        address signer = ECDSA.recover(_mandateDigest(m), sig);
        if (signer != m.user) revert BadSignature();
        mandates[m.user] = m;
        if (!priorActive) mandateVolumeUsed[m.user] = 0; // fresh session budget (H-01)
        emit MandateRegistered(m.user, m.nonce, m.expiry);
    }

    /// @notice The EIP-712 digest a user signs to authorize a mandate (FE + tests).
    function mandateDigest(TradeMandate calldata m) external view returns (bytes32) {
        return _mandateDigest(m);
    }

    function _mandateDigest(TradeMandate calldata m) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MANDATE_TYPEHASH,
                    m.user,
                    m.maxNotionalPerTrade,
                    m.maxCumulativeNotional,
                    m.maxCommissionBps,
                    m.maxSlippageBps,
                    m.expiry,
                    m.nonce
                )
            )
        );
    }

    /// @notice Revoke the caller's mandate immediately (and bump the nonce watermark). Safe
    ///         from overflow: registerMandate reserves nonce == type(uint96).max, so the
    ///         stored nonce is always < max here.
    function cancelMandate() external {
        uint96 next = mandates[msg.sender].nonce + 1;
        if (next > minNonce[msg.sender]) minNonce[msg.sender] = next;
        delete mandates[msg.sender];
        emit MandateCancelled(msg.sender, minNonce[msg.sender]);
    }

    /// @notice Raise the caller's minimum-valid nonce to `n`, invalidating every mandate with
    ///         nonce < `n` (EXCLUSIVE of `n`). To revoke a specific nonce `k`, pass `k + 1`.
    function cancelUpToNonce(uint96 n) external {
        if (n > minNonce[msg.sender]) minNonce[msg.sender] = n;
        if (mandates[msg.sender].nonce < n) delete mandates[msg.sender];
        emit MandateCancelled(msg.sender, minNonce[msg.sender]);
    }

    /// @notice Validate the user's live mandate; returns the caps to apply. Reverting variant
    ///         for single swaps.
    function _checkMandate(address user)
        internal
        view
        returns (uint16 slipBps, uint16 commBps, uint256 maxNotional, uint256 maxCumulative)
    {
        TradeMandate storage m = mandates[user];
        if (m.user != user) revert NoMandate();
        if (m.nonce < minNonce[user]) revert NoMandate();
        if (m.expiry < block.timestamp) revert MandateExpired();
        if (m.maxSlippageBps > MAX_SLIPPAGE_BPS_CAP) revert SlippageTooHigh();
        slipBps = _effSlippage(m.maxSlippageBps);
        // MAX_COMMISSION_BPS = 3000 fits uint16; the cast is safe.
        // forge-lint: disable-next-line(unsafe-typecast)
        commBps = m.maxCommissionBps > MAX_COMMISSION_BPS ? uint16(MAX_COMMISSION_BPS) : m.maxCommissionBps;
        maxNotional = m.maxNotionalPerTrade;
        maxCumulative = m.maxCumulativeNotional;
    }

    /// @notice Account `notional` against the user's cumulative session budget (audit H-01).
    function _consume(address user, uint256 notional, uint256 maxCumulative) internal {
        uint256 used = mandateVolumeUsed[user] + notional;
        if (used > maxCumulative) revert ExceedsSessionLimit();
        mandateVolumeUsed[user] = used;
    }

    // ─────────────────────────────────────────────────────────────────────
    // #6 On-chain referral tree
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Set a user's 5 upline recipients (tiers 1..5). address(0) slots roll to root.
    ///         Owner-only (cold key); mirrors the off-chain `referrals` table.
    function setUplines(address user, address[5] calldata up) external onlyOwner {
        if (user == address(0)) revert ZeroAddress();
        uplines[user] = up;
        emit UplinesSet(user);
    }

    /// @notice Resolve the recipient for tier index `i` (0..4 = tiers 1..5, 5 = root).
    ///         Vacant uplines roll up to root.
    function _recipient(address user, uint256 i) internal view returns (address) {
        if (i == ROOT_TIER_IDX) return root;
        address up = uplines[user][i];
        return up == address(0) ? root : up;
    }

    // ─────────────────────────────────────────────────────────────────────
    // Main swap functions
    // ─────────────────────────────────────────────────────────────────────

    /// @notice SELL (BTCB -> USDT) with atomic commission fan-out. Recipients from the on-chain
    ///         tree; floor = max(traderMinOut, oracleFloor); commission capped by the mandate;
    ///         per-trade + cumulative notional enforced. Output (minus commission) -> `user`.
    function swapAndDistribute(
        address user,
        uint256 amountIn,
        uint256 traderMinOut,
        uint256[N_TIERS] calldata parts,
        uint256 deadline
    ) external onlyTrader whenNotPaused nonReentrant checkDeadline(deadline) returns (uint256 userReceived) {
        if (user == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        (uint16 slipBps, uint16 commBps, uint256 maxNotional, uint256 maxCumulative) = _checkMandate(user);
        uint256 notional = _btcbToUsd(amountIn);
        if (notional > maxNotional) revert ExceedsPerTrade();
        _consume(user, notional, maxCumulative);

        IERC20(BTCB).safeTransferFrom(user, address(this), amountIn);

        uint256 floor = _floorUsdtOut(amountIn, slipBps);
        uint256 swapMinOut = traderMinOut > floor ? traderMinOut : floor;

        IERC20(BTCB).forceApprove(swapRouter, amountIn);
        uint256 usdtOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: BTCB,
                tokenOut: USDT,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: swapMinOut,
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT
            })
        );
        if (usdtOut < swapMinOut) revert InsufficientOutput();

        // Cap the commission ACTUALLY paid to third parties. Self-pay parts (recipient == user —
        // a self-upline or the founder trading as root) are returned to the user by _fanOut, so
        // they are excluded: counting them would let a giant self-pay part overflow the raw sum
        // past the cap and then pay an oversized real part to an upline (audit H-02). Checked
        // arithmetic + the `> usdtOut` guard also stop the cap multiplication from overflowing.
        uint256 totalCommission = _paidCommission(user, parts);
        if (totalCommission > usdtOut) revert CommissionTooHigh();
        if (totalCommission * BPS_DENOMINATOR > usdtOut * commBps) revert CommissionTooHigh();

        userReceived = _fanOut(user, usdtOut, parts);
        IERC20(USDT).safeTransfer(user, userReceived);
        emit SwapAndDistribute(user, amountIn, usdtOut, totalCommission, userReceived);
    }

    /// @notice Shared fan-out: pay each non-zero tier to its TREE recipient (self-pay
    ///         short-circuit + failover-to-root). Returns the user's remainder.
    function _fanOut(address user, uint256 usdtOut, uint256[N_TIERS] calldata parts)
        internal
        returns (uint256 userReceived)
    {
        userReceived = usdtOut;
        for (uint256 i = 0; i < N_TIERS; i++) {
            uint256 part = parts[i];
            if (part == 0) continue;
            // i in [0, N_TIERS-1=5] => i+1 <= 6, fits uint8.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 tierLabel = (i == ROOT_TIER_IDX) ? 0 : uint8(i + 1);
            address recipient = _recipient(user, i);

            if (recipient == user) {
                emit TierSelfPaySkipped(user, tierLabel, part);
                continue;
            }
            userReceived -= part;
            (bool ok, bytes memory ret) =
                USDT.call(abi.encodeWithSelector(IERC20.transfer.selector, recipient, part));
            if (ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))))) {
                emit TierPaid(user, recipient, tierLabel, part);
            } else {
                // recipient can't receive → fail over to root via the SAME hookless-safe low-level
                // call (never a reverting safeTransfer), so one pathological/blacklisted recipient
                // can't revert a whole batch's settlement (audit L-2). If root ALSO can't receive,
                // refund the user — the un-collectible commission is simply not charged.
                (bool rok, bytes memory rret) =
                    USDT.call(abi.encodeWithSelector(IERC20.transfer.selector, root, part));
                if (rok && (rret.length == 0 || (rret.length == 32 && abi.decode(rret, (bool))))) {
                    emit TierFailoverToRoot(user, recipient, tierLabel, part);
                } else {
                    userReceived += part; // double-failure: return the part to the user
                    emit TierRefundedToUser(user, recipient, tierLabel, part);
                }
            }
        }
    }

    /// @notice Sum of commission parts ACTUALLY paid to a third party — EXCLUDING self-pay tiers
    ///         (recipient resolves to the user: a self-upline or the root/founder trading). The
    ///         cap binds on this, not the raw `parts` sum (audit H-02): a self-pay part is a no-op
    ///         in `_fanOut`, so counting it would let a huge self-pay part overflow the raw sum
    ///         past the cap and then pay a real oversized upline part, and would also wrongly
    ///         reject the founder's legit 0-commission trade. Checked: a huge non-self part reverts.
    function _paidCommission(address user, uint256[N_TIERS] calldata parts) internal view returns (uint256 paid) {
        for (uint256 i = 0; i < N_TIERS; i++) {
            if (_recipient(user, i) == user) continue; // self-pay → returned to user, not a commission
            uint256 p = parts[i];
            // saturate (don't revert) on an absurd trader-supplied part, so one malformed leg can't
            // revert a whole batch (audit L-04); the caller's `> usdtOut`/`> userGross` cap then
            // rejects the saturated total. Legit parts (≪ proceeds) never hit this.
            if (p > type(uint256).max - paid) return type(uint256).max;
            paid += p;
        }
    }

    /// @notice BUY (USDT -> BTCB). No commission. Floor = max(traderMinOut, oracleFloor).
    function swapUsdtToBtcb(address user, uint256 amountIn, uint256 traderMinOut, uint256 deadline)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 btcbOut)
    {
        if (user == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        (uint16 slipBps,, uint256 maxNotional, uint256 maxCumulative) = _checkMandate(user);
        uint256 notional = (amountIn * _usdtUsd()) / (10 ** FEED_DECIMALS); // USD, depeg-aware
        if (notional > maxNotional) revert ExceedsPerTrade();
        _consume(user, notional, maxCumulative);

        IERC20(USDT).safeTransferFrom(user, address(this), amountIn);

        uint256 floor = _floorBtcbOut(amountIn, slipBps);
        uint256 swapMinOut = traderMinOut > floor ? traderMinOut : floor;

        IERC20(USDT).forceApprove(swapRouter, amountIn);
        btcbOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: USDT,
                tokenOut: BTCB,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: swapMinOut,
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT
            })
        );
        if (btcbOut < swapMinOut) revert InsufficientBtcbOut();

        IERC20(BTCB).safeTransfer(user, btcbOut);
        emit SwapUsdtToBtcb(user, amountIn, btcbOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Batch swaps (Tier-2 scale path) — ONE aggregated V3 swap, per-leg mandate + tree gates
    // ─────────────────────────────────────────────────────────────────────

    event BatchSwapAndDistribute(uint256 totalBtcbIn, uint256 totalUsdtOut, uint256 nFilled, uint256 nSkipped);
    event BatchSwapUsdtToBtcb(uint256 totalUsdtIn, uint256 totalBtcbOut, uint256 nFilled, uint256 nSkipped);
    /// @notice A leg was skipped (not reverted). reason: 1=zero/invalid/notional-overflow,
    ///         2=transferFrom failed, 3=no valid mandate (missing/expired/cancelled/over
    ///         per-trade/slippage>cap), 4=over the cumulative session limit (audit H-01),
    ///         5=over the per-trade cap cumulatively within this batch (audit M-2).
    event LegSkipped(address indexed user, uint256 legIndex, uint8 reason);
    /// @notice A leg's commission exceeded its cap → skipped (user made whole), batch continued.
    event LegCommissionSkipped(address indexed user, uint256 attemptedCommission, uint256 userGross);
    /// @notice The final settlement transfer to a user failed (e.g. a token-blacklisted recipient).
    ///         Funds stay in the router for `rescueToken`; the batch does NOT revert (isolation).
    event UserSettlementFailed(address indexed user, address indexed token, uint256 amount);

    /// @notice One user's leg in a batch SELL. Recipients come from the on-chain tree, so the
    ///         leg carries only the commission AMOUNTS (parts), never recipient addresses.
    struct UserLeg {
        address user;
        uint256 amountIn; // BTCB to sell (18-dec)
        uint256[N_TIERS] parts; // commission USDT amounts; recipients = uplines[user] + root
    }

    /// @notice One user's leg in a batch BUY. No commission on buys.
    struct BuyLeg {
        address user;
        uint256 amountIn; // USDT to spend (18-dec)
    }

    /// @notice Non-reverting mandate check for batch legs (a bad leg is SKIPPED, not reverted).
    ///         Returns the per-leg commission cap, the effective slippage (for the batch min),
    ///         and the cumulative cap. `notional` is this leg's USD notional.
    function _mandateOk(address user, uint256 notional)
        internal
        view
        returns (bool ok, uint16 commBps, uint16 effSlip, uint256 maxCumulative, uint256 maxNotional)
    {
        TradeMandate storage m = mandates[user];
        if (m.user != user) return (false, 0, 0, 0, 0);
        if (m.nonce < minNonce[user]) return (false, 0, 0, 0, 0);
        if (m.expiry < block.timestamp) return (false, 0, 0, 0, 0);
        if (m.maxSlippageBps > MAX_SLIPPAGE_BPS_CAP) return (false, 0, 0, 0, 0);
        if (notional > m.maxNotionalPerTrade) return (false, 0, 0, 0, 0);
        // forge-lint: disable-next-line(unsafe-typecast)
        commBps = m.maxCommissionBps > MAX_COMMISSION_BPS ? uint16(MAX_COMMISSION_BPS) : m.maxCommissionBps;
        effSlip = _effSlippage(m.maxSlippageBps);
        maxCumulative = m.maxCumulativeNotional;
        maxNotional = m.maxNotionalPerTrade;
        ok = true;
    }

    /// @notice Final batch settlement transfer that NEVER reverts the batch: if the user can't
    ///         receive (e.g. a token-blacklisted recipient), the funds stay in the router for
    ///         `rescueToken` and a UserSettlementFailed event fires (audit Gemini M-1 / ChatGPT
    ///         L-02 — preserves the "one bad leg never reverts the batch" invariant). Single
    ///         swaps keep the reverting safeTransfer (a lone user's own tx reverting is harmless).
    function _settle(address token, address user, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, user, amount));
        if (!(ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool)))))) {
            emit UserSettlementFailed(user, token, amount);
        }
    }

    /// @notice MANY users' SELLs as ONE aggregated V3 swap + per-user fan-out, single tx.
    ///         Per-leg failure isolation (bad mandate / over-cumulative / revoked approval /
    ///         empty balance = LegSkipped, never reverts the batch). The aggregate is floored
    ///         at the STRICTEST filled leg's signed slippage (audit M-02) — never looser than
    ///         any user agreed to. Recipients from the tree; per-leg commission capped.
    function batchSwapAndDistribute(UserLeg[] calldata legs, uint256 minTotalUsdtOut, uint256 deadline)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 totalUsdtOut, uint256 nFilled)
    {
        uint256 n = legs.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH_LEGS) revert BatchTooLarge();
        uint256 px = _btcUsd(); // read the oracle ONCE for the whole batch, not per leg
        uint16 batchSlip = ownerMaxSlippageBps;

        uint256 totalIn;
        uint256 denom = 10 ** FEED_DECIMALS;
        uint256[] memory pulled = new uint256[](n); // 0 ⇒ leg skipped
        uint16[] memory legCommBps = new uint16[](n);
        address[] memory bUser = new address[](n); // per-user in-batch volume tracker (audit M-2)
        uint256[] memory bVol = new uint256[](n);
        uint256 bCount;
        for (uint256 i = 0; i < n; i++) {
            address u = legs[i].user;
            uint256 amt = legs[i].amountIn;
            if (u == address(0) || amt == 0 || amt > type(uint256).max / px) {
                emit LegSkipped(u, i, 1); // zero/invalid or notional would overflow (audit L-01)
                continue;
            }
            uint256 notional = (amt * px) / denom;
            (bool okM, uint16 cBps, uint16 effSlip, uint256 maxCum, uint256 maxNotional) = _mandateOk(u, notional);
            if (!okM) {
                emit LegSkipped(u, i, 3);
                continue;
            }
            // per-user cumulative volume WITHIN this batch must stay <= the signed per-trade cap
            // (audit M-2: a compromised relayer can't chunk one user past maxNotionalPerTrade)
            uint256 k = bCount;
            for (uint256 j = 0; j < bCount; j++) {
                if (bUser[j] == u) {
                    k = j;
                    break;
                }
            }
            if (k == bCount) {
                bUser[bCount] = u;
                bCount++;
            }
            if (bVol[k] + notional > maxNotional) {
                emit LegSkipped(u, i, 5); // over per-trade cap (cumulative within batch)
                continue;
            }
            // cumulative SESSION cap — overflow-safe (audit L-01)
            if (notional > maxCum || mandateVolumeUsed[u] > maxCum - notional) {
                emit LegSkipped(u, i, 4);
                continue;
            }
            (bool ok, bytes memory ret) =
                BTCB.call(abi.encodeWithSelector(IERC20.transferFrom.selector, u, address(this), amt));
            bool got = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
            if (!got) {
                emit LegSkipped(u, i, 2);
                continue;
            }
            pulled[i] = amt;
            legCommBps[i] = cBps;
            bVol[k] += notional;
            mandateVolumeUsed[u] += notional;
            if (effSlip < batchSlip) batchSlip = effSlip;
            totalIn += amt;
            nFilled++;
        }
        if (totalIn == 0) revert EmptyBatch();

        uint256 floor = _floorUsdtOut(totalIn, batchSlip);
        uint256 swapMin = minTotalUsdtOut > floor ? minTotalUsdtOut : floor;
        IERC20(BTCB).forceApprove(swapRouter, totalIn);
        totalUsdtOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: BTCB,
                tokenOut: USDT,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: totalIn,
                amountOutMinimum: swapMin,
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT
            })
        );
        if (totalUsdtOut < swapMin) revert InsufficientOutput();

        for (uint256 i = 0; i < n; i++) {
            uint256 amt = pulled[i];
            if (amt == 0) continue;
            address u = legs[i].user;
            uint256 userGross = (amt * totalUsdtOut) / totalIn; // same price for all; dust stays

            uint256 totalCommission = _paidCommission(u, legs[i].parts); // excludes self-pay (H-02)
            // Cap on userGross, but cross-multiplied by totalIn so we never multiply the divided
            // userGross (exact + silences slither divide-before-multiply). Overflow-safe: even at
            // BTCB-total-supply scale the products stay far below 2**256.
            bool overCap = totalCommission > userGross
                || totalCommission * BPS_DENOMINATOR * totalIn > amt * totalUsdtOut * legCommBps[i];
            uint256 userReceived;
            if (totalCommission == 0 || overCap) {
                if (overCap) emit LegCommissionSkipped(u, totalCommission, userGross);
                userReceived = userGross;
                totalCommission = 0;
            } else {
                userReceived = _fanOut(u, userGross, legs[i].parts);
            }
            _settle(USDT, u, userReceived); // fail-safe: never reverts the batch (audit M-1/L-02)
            emit SwapAndDistribute(u, amt, userGross, totalCommission, userReceived);
        }
        emit BatchSwapAndDistribute(totalIn, totalUsdtOut, nFilled, n - nFilled);
    }

    /// @notice MANY users' BUYs as ONE aggregated V3 swap, single tx. NO commission.
    ///         Same per-leg mandate + cumulative + failure isolation; aggregate floored at the
    ///         strictest filled leg's signed slippage.
    function batchSwapUsdtToBtcb(BuyLeg[] calldata legs, uint256 minTotalBtcbOut, uint256 deadline)
        external
        onlyTrader
        whenNotPaused
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 totalBtcbOut, uint256 nFilled)
    {
        uint256 n = legs.length;
        if (n == 0) revert EmptyBatch();
        if (n > MAX_BATCH_LEGS) revert BatchTooLarge();
        uint16 batchSlip = ownerMaxSlippageBps;
        uint256 pxUsdt = _usdtUsd(); // read the USDT/USD oracle ONCE for the whole batch

        uint256 totalIn;
        uint256 denom = 10 ** FEED_DECIMALS;
        uint256[] memory pulled = new uint256[](n);
        address[] memory bUser = new address[](n); // per-user in-batch volume tracker (audit M-2)
        uint256[] memory bVol = new uint256[](n);
        uint256 bCount;
        for (uint256 i = 0; i < n; i++) {
            address u = legs[i].user;
            uint256 amt = legs[i].amountIn; // USDT to spend
            if (u == address(0) || amt == 0 || amt > type(uint256).max / pxUsdt) {
                emit LegSkipped(u, i, 1); // zero/invalid or notional would overflow (audit L-01)
                continue;
            }
            uint256 notional = (amt * pxUsdt) / denom; // USD, depeg-aware
            (bool okM,, uint16 effSlip, uint256 maxCum, uint256 maxNotional) = _mandateOk(u, notional);
            if (!okM) {
                emit LegSkipped(u, i, 3);
                continue;
            }
            // per-user cumulative volume WITHIN this batch must stay <= the signed per-trade cap (M-2)
            uint256 k = bCount;
            for (uint256 j = 0; j < bCount; j++) {
                if (bUser[j] == u) {
                    k = j;
                    break;
                }
            }
            if (k == bCount) {
                bUser[bCount] = u;
                bCount++;
            }
            if (bVol[k] + notional > maxNotional) {
                emit LegSkipped(u, i, 5); // over per-trade cap (cumulative within batch)
                continue;
            }
            // cumulative SESSION cap — overflow-safe (audit L-01)
            if (notional > maxCum || mandateVolumeUsed[u] > maxCum - notional) {
                emit LegSkipped(u, i, 4);
                continue;
            }
            (bool ok, bytes memory ret) =
                USDT.call(abi.encodeWithSelector(IERC20.transferFrom.selector, u, address(this), amt));
            bool got = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
            if (!got) {
                emit LegSkipped(u, i, 2);
                continue;
            }
            pulled[i] = amt;
            bVol[k] += notional;
            mandateVolumeUsed[u] += notional;
            if (effSlip < batchSlip) batchSlip = effSlip;
            totalIn += amt;
            nFilled++;
        }
        if (totalIn == 0) revert EmptyBatch();

        uint256 floor = _floorBtcbOut(totalIn, batchSlip);
        uint256 swapMin = minTotalBtcbOut > floor ? minTotalBtcbOut : floor;
        IERC20(USDT).forceApprove(swapRouter, totalIn);
        totalBtcbOut = IPancakeV3SwapRouter(swapRouter).exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: USDT,
                tokenOut: BTCB,
                fee: POOL_FEE,
                recipient: address(this),
                amountIn: totalIn,
                amountOutMinimum: swapMin,
                sqrtPriceLimitX96: SQRT_PRICE_LIMIT
            })
        );
        if (totalBtcbOut < swapMin) revert InsufficientBtcbOut();

        for (uint256 i = 0; i < n; i++) {
            uint256 amt = pulled[i];
            if (amt == 0) continue;
            address u = legs[i].user;
            uint256 userBtcb = (amt * totalBtcbOut) / totalIn; // same price for all; dust stays
            _settle(BTCB, u, userBtcb); // fail-safe: never reverts the batch (audit M-1/L-02)
            emit SwapUsdtToBtcb(u, amt, userBtcb);
        }
        emit BatchSwapUsdtToBtcb(totalIn, totalBtcbOut, nFilled, n - nFilled);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Owner admin
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

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS_CAP) revert SlippageTooHigh();
        emit MaxSlippageUpdated(ownerMaxSlippageBps, bps);
        ownerMaxSlippageBps = bps;
    }

    /// @notice Bounded so the owner can't disable the staleness guard (audit L-02).
    function setMaxOracleAge(uint256 age) external onlyOwner {
        if (age == 0 || age > MAX_ORACLE_AGE_CAP) revert OracleBad();
        emit MaxOracleAgeUpdated(maxOracleAge, age);
        maxOracleAge = age;
    }

    // ── #5 setSwapRouter timelock + allowlist ──

    function allowRouter(address r, bool ok) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        allowedRouter[r] = ok;
        emit RouterAllowed(r, ok);
    }

    function scheduleSwapRouter(address newSwapRouter) external onlyOwner {
        if (!allowedRouter[newSwapRouter]) revert RouterNotAllowed();
        pendingSwapRouter = newSwapRouter;
        swapRouterEta = block.timestamp + SWAP_ROUTER_TIMELOCK;
        emit SwapRouterChangeScheduled(newSwapRouter, swapRouterEta);
    }

    function executeSwapRouter() external onlyOwner {
        address next = pendingSwapRouter;
        if (next == address(0) || block.timestamp < swapRouterEta) revert TimelockPending();
        if (!allowedRouter[next]) revert RouterNotAllowed();
        emit SwapRouterUpdated(swapRouter, next);
        swapRouter = next;
        pendingSwapRouter = address(0);
        swapRouterEta = 0;
    }

    // ── Ownership (Ownable2Step) + pause + rescue ──

    // slither-disable-next-line missing-zero-check
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferStarted(owner, newOwner);
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnerTransferred(owner, msg.sender);
        owner = msg.sender;
        delete pendingOwner;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToRescue();
        emit Rescued(token, amount, to);
        IERC20(token).safeTransfer(to, amount);
    }
}
