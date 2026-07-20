# BtcbotRouterV2 — fixes applied after the audit review

Contract is at the latest commit (see git log); **53/53 tests pass** + **BSC-fork test 4/4 green**
on live infra, `forge build` clean, slither **0 high/medium on V2** (residual findings are
accepted FPs, see below). Re-submit this doc + the updated `BtcbotRouterV2.sol` + `BtcbotRouterV2.t.sol`.

## Round 5 — external ChatGPT + Gemini audits (current build)

Both auditors independently found **no High, no Medium fund-drain** and judged the contract
deploy-ready after minor batch-isolation hardening (Gemini flagged the H-02 fix as "highly
resilient"). Three items implemented:

| Finding | Severity | Status | What changed |
|---|---|---|---|
| Final user transfer can revert the whole batch (Gemini M-1 = ChatGPT L-02) | Medium | ✅ **Fixed** | Batch settlement uses `_settle()` — a low-level `transfer` that, on failure (e.g. a USDT-blacklisted recipient), keeps the funds in the router for `rescueToken` and emits `UserSettlementFailed` instead of reverting. One bad recipient can no longer DoS a whole batch. Single swaps keep the reverting `safeTransfer` (a lone user's own tx reverting is harmless). Test: `test_batch_finalTransferFails_isolatesUser`. |
| `amt * px` notional overflow reverts the batch (ChatGPT L-01) | Low | ✅ **Fixed** | Guard `amt > type(uint256).max / px` → skip the leg (reason 1); cumulative-session check rewritten overflow-safe (`notional > maxCum \|\| mandateVolumeUsed[u] > maxCum - notional`). Tests: `test_batch_{sell,buy}_absurdAmount_skipsLegNotReverts`. |
| `maxNotionalPerTrade` bypass via intra-batch chunking (Gemini M-2) | Medium | ✅ **Fixed** | Per-user volume is tracked WITHIN the batch and capped at the signed `maxNotionalPerTrade` (skip reason 5). A compromised relayer can't chunk one user across many legs past their per-trade cap. (⚠ executor: set `maxNotionalPerTrade` ≥ a user's expected per-batch volume; legit small multi-rung batches are unaffected.) Test: `test_batch_chunking_perTradeCapWithinBatch`. |

No action (auditor-classified): oracle floor rounds down ≤1 wei (acknowledged, standard for minOut); `_fanOut` underflow-immunity (Gemini Info-4: positive finding); `SwapAndDistribute.commissionTotal` is the attempted/capped commission — indexers should also read `TierPaid`/`TierFailoverToRoot`/`TierRefundedToUser`/`TierSelfPaySkipped`/`UserSettlementFailed`.

## Round 4 — external LLM (ChatGPT) re-review

ChatGPT re-reviewed the H-02 build and **confirmed H-02 fixed + all prior fixes hold**
(H-01 / M-01 / M-02, oracle/depeg, BUY notional). Verdict: OK for testnet/fork; OK for mainnet
after the standard checklist (forge test/coverage, slither, BSC-fork test, low-value smoke test).
Four Low/hardening items, all now implemented:

| Finding | Severity | Status | What changed |
|---|---|---|---|
| **L-01** no on-chain batch-size bound | Low | ✅ **Fixed** | `MAX_BATCH_LEGS = 50`; both batch fns revert `BatchTooLarge` above it. Larger fleets are chunked by the relayer. |
| **L-02** `FEED_DECIMALS` only checked for equality | Low | ✅ **Fixed** | Constructor also rejects `dec == 0 || dec > 18` (a feed with absurd-but-matching decimals). |
| **L-03** no explicit zero-amount guard on single swaps | Low | ✅ **Fixed** | `swapAndDistribute` / `swapUsdtToBtcb` revert `ZeroAmount` on `amountIn == 0` (the batch already skips zero legs). |
| **L-04** absurd trader `parts` could revert a batch (checked overflow in `_paidCommission`) | Low | ✅ **Fixed** | `_paidCommission` now SATURATES to `type(uint256).max` instead of reverting; the cap rejects it (single reverts via the cap, batch skips the leg). The "bad leg never reverts the batch" promise now holds for malformed params too. Test: `test_batch_absurdParts_skipsLegNotReverts`. |

(Note: this ChatGPT pass reviewed the H-02 build, so it predates — and did not see — the round-3
M-1/L-2 fixes below; it also did not independently flag M-1, which the round-3 agent caught.)

## Round 3 — independent multi-agent re-review

Three independent reviewers (fresh context; fund-safety / math-decimals / mandate-batch lenses).
Two returned fully clean — no exploitable drain, no cap bypass; the math reviewer fuzzed the batch
cap 200k iterations and confirmed it equals capping `userGross·commBps` with divergence < 1 wei in
the safe direction. The third surfaced one Medium + one Low, both now fixed:

| Finding | Severity | Status | What changed |
|---|---|---|---|
| **M-1** cumulative anti-churn cap silently reset by re-registration | Medium | ✅ **Fixed** | `registerMandate` resets `mandateVolumeUsed` ONLY when no prior mandate is still active (prior expired, or none). Re-registering over a LIVE mandate carries the spent volume forward, so a compromised relayer holding a newer user-signed mandate can't zero the meter early to churn another full `maxCumulativeNotional`. Natural expiry / explicit `cancelMandate` still reset. Tests: `test_cumulativeCap_notResetByEarlyReRegister`, `test_cumulativeCap_resetAfterExpiry`. |
| **L-2** `_fanOut` root-failover used a reverting `safeTransfer` | Low | ✅ **Fixed** | Failover-to-root now uses the same hookless-safe low-level call; if root ALSO can't receive, the part is refunded to the user. `_fanOut` can no longer revert on a pathological/blacklisted recipient → one un-routable commission can't sink a whole batch. New event `TierRefundedToUser`. Test: `test_fanOut_doubleFailure_refundsUser`. |
| **Docs** | Info | ✅ **Fixed** | `AUDIT_SCOPE_V2.md`: 8-arg constructor (+ `usdtUsdFeed`), `MAX_COMMISSION_BPS` 3500→3000, batch slippage = strictest filled leg, test count 45/45. |

Informational (no code change): `cancelUpToNonce` is exclusive (now in NatSpec); a filled leg whose
notional rounds to 0 doesn't advance the meter (dust-level, not a drain); `setUplines` (owner) can
redirect commission but never exceeds the signed cap or touches principal.

## Round 2 — second re-review

| Finding | Severity | Status | What changed |
|---|---|---|---|
| **H-02** commission-cap bypass: `unchecked` sum overflow + self-pay short-circuit | High | ✅ **Fixed** | The cap now binds on `_paidCommission()` — commission ACTUALLY paid to third parties, EXCLUDING self-pay tiers (recipient == user). Sum is **checked** (no `unchecked`); a `> usdtOut` (single) / `> userGross` (batch) guard also blocks the cap-multiplication overflow. A giant self-pay part is now a no-op for the cap, so it can't wrap the sum and smuggle an oversized real upline payout. Tests: `test_singleSell_commissionCapOverflowWithSelfPay_reverts`, `test_batch_commissionCapOverflowWithSelfPay_skipped`. |
| **Remark 1** `cancelUpToNonce` exclusive vs its name | Info | ✅ **Doc** | NatSpec clarified: `n` is the new minimum-valid nonce (mandates with `nonce < n` invalidated); to revoke nonce `k`, pass `k + 1`. |
| **Remark 2** BUY notional counted in nominal USDT | Low | ✅ **Fixed** | `swapUsdtToBtcb` + `batchSwapUsdtToBtcb` convert `amountIn` to USD via the USDT/USD feed for the per-trade + cumulative caps — depeg-aware, consistent with SELL. Test: `test_buy_notionalIsDepegAware`. |
| **slither** divide-before-multiply (oracle floor + batch cap) | Medium | ✅ **Fixed** | `_floorUsdtOut`/`_floorBtcbOut` reordered to multiply-before-divide (single division); the batch over-cap check cross-multiplied by `totalIn` so the divided `userGross` is never multiplied. **V2 now has 0 divide-before-multiply** (the 2 remaining are in the out-of-scope legacy routers). |

**On the `setUplines` self-upline guard you suggested:** NOT added — self-pay is a *supported* scenario here (the founder trades as `root`; a user can be their own tier-1 via root-spillover — see `test_sell_selfPay`). `_paidCommission` makes self-pay safe without forbidding it, which is strictly more robust than a config guard. The H-02 regression test therefore uses a real self-pay tier (`up[0] = user`).

## Round 1 — first re-review

| Finding | Severity | Status | What changed |
|---|---|---|---|
| **H-01** trader can churn unlimited (no cumulative cap) | High | ✅ **Fixed** | Mandate now carries `maxCumulativeNotional`; `mandateVolumeUsed[user]` counter, consumed on every swap (single + per batch leg), **reset to 0 on each `registerMandate`**. Over-budget → `ExceedsSessionLimit` (single) / `LegSkipped reason 4` (batch). |
| **M-01** old mandate replayable (rollback) | Med/High | ✅ **Fixed** | `registerMandate` now requires **strictly increasing** nonce (`m.nonce > current.nonce`), rejects already-expired mandates, and reserves `nonce == type(uint96).max`. |
| **M-02** batch ignores signed `maxSlippageBps` | Med | ✅ **Fixed** | The aggregate swap is floored at the **strictest** filled leg's signed slippage (`batchSlip = min(owner, each leg)`), never looser than any user agreed. |
| **M-03** commission cap on gross proceeds | Med | ✅ **Fixed** | Hard cap lowered **35% → 30%** (`MAX_COMMISSION_BPS = 3000`). Per-user signed `maxCommissionBps` remains the effective cap (FE defaults 30% / 10% OG). |
| **M-04** router allowlist not pre-seeded-only | Med/Low | ⚖️ **Accepted + documented** | The **48h `setSwapRouter` timelock** is the binding control (a compromised owner is visible for 48h → users revoke). Timelocking allowlist adds / `setTrader` would cripple emergency key rotation. Owner is a cold Ledger. |
| **L-01** not shipped paused | Low | ✅ **Fixed** | Constructor sets `paused = true`. |
| **L-02** oracle hardening | Low | ✅ **Fixed** | `_readFeed` rejects `updatedAt == 0`, `startedAt == 0`, future-dated `updatedAt`, `answeredInRound < roundId`; `setMaxOracleAge` bounded to `MAX_ORACLE_AGE_CAP = 2h` and non-zero. |
| **L-03** USDT≈USD depeg | Low/Med | ✅ **Fixed** | Added a 2nd Chainlink feed **USDT/USD**; floors now use the ratio (`SELL = BTC_USD / USDT_USD`, `BUY = USDT_USD / BTC_USD`). Both feeds must share decimals (asserted in the constructor). |
| **L-04** `cancelMandate` nonce-max wrap | Low | ✅ **Fixed** | `registerMandate` reserves `nonce == type(uint96).max`, so a stored nonce is always `< max` → `cancelMandate`'s `nonce + 1` can't wrap. |

## Slither — one residual, accepted

`reentrancy-no-eth` on `batchSwapAndDistribute` / `batchSwapUsdtToBtcb`: `mandateVolumeUsed[u] +=`
is written after the `transferFrom` low-level call. **Accepted false-positive**:
- Both batch functions are `nonReentrant` (re-entry reverts).
- BTCB + USDT are **fixed, immutable, hookless BEP20s** — `transferFrom` invokes no callback, so
  re-entry is impossible.
- `registerMandate` (the cross-function path slither names) is **also `nonReentrant`** now.

No other high/medium on V2 — `divide-before-multiply` was eliminated in round 2 (the 2 remaining
instances are in the out-of-scope legacy routers). (`arbitrary-send-erc20` on the `user` param is
accepted — `onlyTrader` + the user's own approval + the signed mandate; identical to the Uniswap
router pattern.)

## Suggested re-review prompt
> Here is BtcbotRouterV2.sol after fixing your previous findings (see AUDIT_FIXES_V2.md).
> Verify each fix is correct and complete (especially H-01 cumulative accounting incl. the
> reset-on-register and the batch per-leg consume; M-01 nonce monotonicity; M-02 strict batch
> slippage; L-03 dual-feed floor decimals). Confirm no new issues were introduced. Be
> adversarial. The reentrancy-no-eth on the batch is a documented false-positive (nonReentrant
> + hookless tokens) — challenge it only if you can show a concrete exploit.
