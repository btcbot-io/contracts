# BtcbotRouterV2 — external audit scope

**Prepared for**: the external auditor / audit firm.
**Date**: 2026-06-29.
**Contact**: btcbot operator.

---

## 1. What we need audited

A single Solidity contract — **`src/BtcbotRouterV2.sol`** (~720 LoC, Solidity `^0.8.24`) — the
new on-chain swap + commission router for an autonomous, **non-custodial** BTCB/USDT grid
trading bot on **BSC mainnet (chainid 56)**.

This V2 hardens the live predecessor (`BtcbotRouterDuplex`, already deployed) following a
review by **Blockaid** (the security layer behind MetaMask / Rabby / Coinbase Wallet). The
goal of the audit is a clean report enabling a public launch + a Blockaid "Trusted" rating.

| | |
|---|---|
| Repo | `github.com/rushapoil/btcbot` (private — access on request), dir `contracts/btcbot_router/` |
| Commit to audit | **`6376ccc`** (freeze; we will tag `v2-audit-rc1`) |
| Primary file | `src/BtcbotRouterV2.sol` |
| Imports (in scope only as used) | OpenZeppelin `ReentrancyGuard`, `SafeERC20`, `EIP712`, `ECDSA`; `src/interfaces/IPancakeV3SwapRouter.sol` |
| **In scope** | `BtcbotRouterV2.sol` + its direct logic |
| **Out of scope** | OpenZeppelin libs (audited), PancakeSwap V3 router (audited), Chainlink feed, the legacy routers (`BtcbotRouter`/`BtcbotCommissionRouter`/`BtcbotRouterDuplex`), the off-chain bot, the frontend |

## 2. Build / test / static analysis

Foundry project. From `contracts/btcbot_router/`:

```bash
forge build                                   # compiles clean (Solc 0.8.24)
forge test --match-path test/BtcbotRouterV2.t.sol   # 53/53 pass
forge coverage --match-path test/BtcbotRouterV2.t.sol --report summary --ir-minimum
#   → BtcbotRouterV2.sol: >95% lines, ~97% funcs; lower branch coverage is defensive/unreachable (§6)
#   (--ir-minimum works around forge-coverage's stack-too-deep on the batch fns)
slither . --filter-paths 'lib/|test/' --exclude-dependencies
#   → 0 high/medium on V2; findings = accepted classes (see §6 + slither-report)
```

Existing artifacts to read alongside this doc:
- `docs/btcbot_router_spec.md` — original router spec + threat model.
- `docs/btcbot_router_v2_spec.md` — the V2 design rationale (why each change).
- `AUDIT_CHECKLIST.md` — slither dispositions for the predecessor (carried-over findings).

## 3. What the contract does (architecture)

A **trusted relayer** ("trader", a hot key) executes swaps **on behalf of users**, but V2
moves all *trade-term authority* off the relayer and onto **on-chain limits + a user-signed
mandate**. Every swap returns 100% of the output to the **same user** (no third-party
recipient path). Five mechanisms:

1. **Oracle price floor (`_btcUsd` / `_floorUsdtOut` / `_floorBtcbOut`)** — every swap is
   floored by a **Chainlink BTC/USD** reference minus a bounded max-slippage; the contract
   enforces `amountOut >= max(traderMinOut, oracleFloor)`. A compromised relayer cannot drain
   via an adversarial `minOut`. Staleness + round-completeness checked.
2. **EIP-712 session mandate (`registerMandate` / `_checkMandate` / `cancelMandate` /
   `cancelUpToNonce`)** — the user signs ONE mandate bounding `maxNotionalPerTrade` (USD),
   `maxCommissionBps`, `maxSlippageBps`, `expiry`, `nonce`. The relayer can only execute
   within it. Register-once (cheap per-trade checks), revocable on-chain anytime.
3. **On-chain referral tree (`uplines` / `_recipient`)** — sell-commission **recipients are
   derived on-chain** (`uplines[user]` + global `root`), NOT passed by the relayer. Vacant
   uplines roll to root. Commission **amount** is relayer-provided but capped by the user's
   signed rate.
4. **`setSwapRouter` timelock + allowlist** — `scheduleSwapRouter` → 48h → `executeSwapRouter`,
   constrained to a pre-seeded allowlist.
5. **Atomic commission fan-out** (carried over, re-audit) — per-tier transfer with self-pay
   short-circuit + failover-to-root (low-level call so one blacklisted recipient can't grief),
   `deadline` on every swap, `ReentrancyGuard`, pause, `rescueToken`, Ownable2Step. Plus
   **batch** BUY/SELL: one aggregated V3 swap + per-leg pro-rata, with per-leg failure
   isolation (a bad mandate / revoked approval / empty balance is skipped, never reverts the
   batch).

## 4. Trust model

- **owner** (COLD / Ledger, `0x94eDfB…`) — can `setTrader`, `setRoot`, `setUplines`,
  `setMaxSlippageBps` (hard-capped ≤ 5% in code), `setMaxOracleAge`, `allowRouter`,
  schedule/execute the timelocked router swap, pause, `rescueToken`, transfer ownership
  (2-step). Centralized but cold-stored; this is the documented trust anchor.
- **trader** (HOT bot, `0x093eAa…`) — the only caller of swap functions; bounded by the
  oracle floor + each user's signed mandate. Holds no custody; cannot withdraw user funds.
- **root** (founder, `0x032c18…`) — commission root + fallback recipient.
- Users keep custody; they approve the router (or Permit2 — planned) + sign a mandate, and
  can revoke either anytime.

## 5. Deployment parameters (BSC mainnet)

Constructor `(BTCB, USDT, swapRouter, trader, root, owner, btcUsdFeed, usdtUsdFeed)`:

| Param | Address | Note |
|---|---|---|
| BTCB | `0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c` | unchanged from Duplex |
| USDT (BSC, 18-dec) | `0x55d398326f99059fF775485246999027B3197955` | unchanged |
| swapRouter | `0x13f4EA83D0bd40E75C8222255bc855a974568Dd4` | Pancake V3 SmartRouter02 |
| trader (hot) | `0x093eAa…` | bot |
| root (founder) | `0x032c18…` | commission root |
| owner | deployer → `0x94eDfB…` (cold) | transferred post-deploy (2-step) |
| **btcUsdFeed** | `0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf` | **Chainlink BTC/USD on BSC. Verify: canonical feed, 8 decimals, heartbeat vs `maxOracleAge` (default 1h, owner-settable, hard-capped ≤2h).** |
| **usdtUsdFeed** | `0xB97Ad0E74fa7d920791E90258A6E2085088b4320` | **Chainlink USDT/USD on BSC — depeg-aware floor (audit L-03). Constructor asserts it shares `decimals()` with btcUsdFeed (both 8). Verify: canonical feed, 8 decimals.** |

Ships **paused**; owner transferred to cold; deploy script `script/DeployV2.s.sol` (pending —
mirrors `DeployDuplex.s.sol` + the two feed args). USDT on BSC is **18 decimals** (not 6).

## 6. Known design decisions / accepted risks (please confirm or challenge)

- **Centralization** (owner can rotate trader/root/uplines, pause, rescue) — accepted for a
  small operator-run product; owner is a cold Ledger; `setSwapRouter` is timelocked.
- **Commission cap is on PROCEEDS, not the rate.** `MAX_COMMISSION_BPS = 3000` (30%, lowered
  audit M-03) of `usdtOut`; the real commission is `30% × gain`, and `gain ≤ proceeds`, so the
  cap can never bind in normal operation (it's a sanity backstop). The rate lives off-chain. The
  cap now binds on the commission PAID to third parties (`_paidCommission`, excludes self-pay).
- **Relayer still provides commission `parts` (amounts).** Recipients are on-chain (can't be
  redirected); totals are capped by the user-signed rate. We did NOT put full on-chain
  cost-basis accounting on-chain (it would change the per-position commission math). Is the
  "recipients on-chain + signed cap" sufficient for your sign-off, or do you want more?
- **Batch slippage = the STRICTEST filled leg.** The aggregate swap is floored at
  `min(ownerMaxSlippageBps, every filled leg's signed maxSlippageBps)` (audit M-02) — never
  looser than any participating user agreed to. (Owner cap ≤5% throughout.)
- **`arbitrary-send-erc20` (slither)** on `transferFrom(user,…)` — `user` is arbitrary by
  design (relayer passes the executed user), gated by `onlyTrader` + the user's own approval +
  now the mandate. Same pattern as the Uniswap router. Accepted in the predecessor audit.
- **Low coverage on branches (53%)** is defensive/unreachable paths (post-swap
  `InsufficientOutput` guards the V3 already enforces; low-level-call decode short-circuits).
  Line coverage is 96%. Flag any branch you consider materially untested.

## 7. Areas we most want scrutinized

1. **EIP-712 mandate**: signature recovery + the domain (replay across chains/contracts?),
   nonce + `cancelUpToNonce` watermark logic, the "anyone may submit a signed mandate" pattern.
2. **Oracle math + decimals**: `_btcbToUsd`, `_floorUsdtOut`, `_floorBtcbOut` (BTCB 18 / USDT
   18 / feed 8); rounding direction; staleness + `answeredInRound < roundId`; USDT≈USD risk.
3. **Commission**: the proceeds-based cap, recipients-from-tree, self-pay + failover-to-root.
4. **Batch**: failure isolation (one bad leg never sinks the batch), pro-rata + dust
   conservation, the aggregate oracle floor.
5. **Reentrancy / fund safety**: `nonReentrant`, CEI, the low-level-call fan-out.
6. **Timelock + allowlist** on `setSwapRouter`.

## 8. Engagement notes

Scale: ~720 LoC, mid complexity, single contract, ~$12k of user funds today (public launch
ahead). We will freeze the commit (`v2-audit-rc1` tag) before kickoff and apply fixes on a
branch for your re-review. Happy to walk through the design on a call.
