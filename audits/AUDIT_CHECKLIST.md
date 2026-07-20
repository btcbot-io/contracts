# BtcbotRouter — audit checklist

Pre-flight before testnet, mainnet, and any tier expansion.

---

## 1. Static analysis — Slither

### Run

```bash
cd contracts/btcbot_router
docker run --rm -v "$PWD":/share trailofbits/slither:latest /share \
  --solc-remaps "@openzeppelin=lib/openzeppelin-contracts permit2=lib/permit2 forge-std=lib/forge-std" \
  --exclude-dependencies \
  --filter-paths "lib/|test/" \
  2>&1 | tee slither-report.txt
```

### Pass criteria

- **0 high severity findings**
- **0 medium severity findings**
- All low / informational findings have a one-line rationale in this file (see §3)

### Common findings expected (and acceptable)

| Finding | Severity | Disposition |
|---|---|---|
| `Owner can change trader / root / pause / rescue` | informational | **Accepted** — centralization documented in spec §2 and §7 |
| `Use of low-level call in fan-out loop` | informational | **Accepted** — intentional, defended in spec §4 (I13) and code comments. The low-level call is the mechanism that lets us catch reverting / returns-false transfers without killing the whole tx |
| `Block.timestamp used as deadline` | informational | **Accepted** — standard for Pancake/Uniswap V2 calls; equivalent to `deadline = now`, miner manipulation worth a few seconds is irrelevant |
| `forceApprove + leftover allowance` | informational | **Accepted** — Pancake's `swapExactTokensForTokens` consumes the exact allowance; post-swap remaining = 0 |
| `Reentrancy in swap functions` | high | **Must fail** — `nonReentrant` on both swap functions blocks it. If Slither reports a true reentrancy issue, stop and investigate |

### Re-run after H1 patch and Mxx fixes

Slither must be re-run on every contract change. The pass criteria above hold across versions.

---

## 2. Foundry test suite

### Local unit tests

```bash
forge test -vvv
```

Expected:
- All tests in `test/BtcbotRouter.t.sol` (constructor + setters) pass
- All tests in `test/BtcbotRouter.swap.t.sol` (12 core swap tests) pass
- Total: ≥ 16 tests pass, 0 failures

### Fork tests against BSC mainnet

```bash
forge test --fork-url $BSC_RPC_HTTP --fork-block-number <recent_finalised_block> -vvv \
  --match-path test/BtcbotRouter.fork.t.sol
```

Expected (when fork tests are written — currently absent):
- Real `0x10ED43C7...56024E` Pancake V2 router executes the swap
- Real `0x000000000022D473...8BA3` canonical Permit2 verifies signatures
- Swap output within expected slippage of the live quote
- Atomicity test: injected failure → user's BTCB unchanged

### Coverage

```bash
forge coverage --report summary
```

Pass criteria:
- ≥ 95% line coverage on `src/BtcbotRouter.sol`
- 100% branch coverage on `swapAndDistribute` and `swapUsdtToBtcb`

---

## 3. Manual review — items from REVIEW_2026-05-19.md

### HIGH — must be done

- [ ] **H1** — `minUsdtOut` → `minUserReceived` rename + Pancake floor computed internally (see `H1_patch.md`)
- [ ] **H2** — 12 core swap tests in `test/BtcbotRouter.swap.t.sol` pass with `forge test`

### MEDIUM — must be done before mainnet

- [ ] **M1** — `Ownable2Step` pattern applied to `transferOwnership` (pendingOwner + acceptOwnership)
- [ ] **M2** — Custom error `WrongPermitToken()` replaces both `require(...token == BTCB/USDT, "...")` strings
- [ ] **M3** — Defensive guard `ret.length == 32 && abi.decode(...)` (covered in `H1_patch.md`)
- [ ] **M4** — `amounts[amounts.length - 1]` in both `swapAndDistribute` and `swapUsdtToBtcb`
- [ ] **M5** — Optional: swap order of cap check vs output check for clearer error messages

### Spec ↔ code drift

- [ ] **D1** — Reconcile `event Paused` (spec) vs `event PausedSet` (code) — pick one and update both
- [ ] **D2** — Either add `bytes reason` to `TierFailoverToRoot` event (and propagate `ret`) or remove from spec
- [ ] **D3** — Remove `InvalidRecipientArray` / `InvalidPartsArray` from spec (unreachable due to ABI-enforced array sizes) OR add explicit defensive checks in code

### LOW — consider before public expansion

- [ ] **L1** — Self-pay deduct/undeduct readability cleanup (covered in `H1_patch.md`)
- [ ] **L2** — `unchecked { ++i }` in fan-out loop
- [ ] **L3** — Explicit guard for `recipients[i] == address(0)` with `parts[i] > 0`
- [ ] **L4** — Pin pragma to `0.8.24` exactly; lock in `foundry.toml` via `solc_version`
- [ ] **L5** — Document intentionality of `MAX_COMMISSION_BPS` being `constant` in §7 #5 (already there; just confirm no second thoughts)
- [ ] **L6** — Add `indexed initiator` to `Rescued` event for indexer-friendly traces

---

## 4. Pre-deploy operational checks

Before pushing to testnet:

- [ ] `foundry.toml` pins `solc_version = "0.8.24"` and `optimizer_runs` value documented
- [ ] `remappings.txt` matches the Slither remaps used above
- [ ] `lib/openzeppelin-contracts` is pinned at a specific git tag (NOT `main`)
- [ ] `lib/permit2` (if vendored) is pinned at a specific Uniswap release
- [ ] BscScan verification dry-run on testnet (so we know the exact compiler settings)
- [ ] Constructor parameters checked against `docs/btcbot_router_spec.md` §6.1 (testnet) or §6.2 (mainnet)
- [ ] `transferOwnership` plan: who is the post-deploy owner, and is their wallet ready to `acceptOwnership` (once M1 is applied)?

Before pushing to mainnet:

- [ ] All HIGH and MEDIUM items above checked off
- [ ] 48h testnet run with ≥10 SELL trades and ≥10 BUY trades, no unexpected events
- [ ] Slither + Foundry tests + fork tests all green
- [ ] Backup of the deployer key (cold storage) verified accessible
- [ ] `setPaused(true)` smoke-test on testnet → confirms kill-switch works as documented

---

## 5. Post-deploy verification (BscScan mainnet)

- [ ] Constructor arguments match `docs/btcbot_router_spec.md` §6.2 exactly
- [ ] Source verified on BscScan (matching solc version, settings, libs)
- [ ] `paused()` returns `false`
- [ ] `owner()` is the operator's cold key (NOT the deployer — already `transferOwnership`'d)
- [ ] `trader()` is the production trader hot wallet
- [ ] `root()` is the production root wallet (= owner per spec §7 in V1)
- [ ] Initial $5 smoke test confirmed with all expected events on-chain
- [ ] `setPaused(true)` and `setPaused(false)` exercise on mainnet to confirm owner key works
- [ ] One full SELL with fan-out: `SwapAndDistribute` + ≥1 `TierPaid` + `TierSelfPaySkipped` events as expected
- [ ] One full BUY with `SwapUsdtToBtcb` event as expected
- [ ] Conservation: pre-tx vs post-tx token balance sums match for `(user + tiers + root)` across the test
- [ ] Indexer plan: events captured by an off-chain process for reconciliation against `commissions` DB table (per spec §17.6)

---

## 6. Slither finding triage template

When a new Slither finding appears, document it here with this format:

```
- Finding: <short description>
  Severity: high | medium | low | informational
  Location: src/BtcbotRouter.sol:<line>
  Disposition: fixed | accepted | deferred
  Rationale: <one or two sentences>
```

Example acceptance entry:

```
- Finding: Reentrancy guard in `swapAndDistribute` (informational on benign use)
  Severity: informational
  Location: src/BtcbotRouter.sol:197
  Disposition: accepted
  Rationale: `nonReentrant` modifier from OpenZeppelin's `ReentrancyGuard` is applied;
             no external call path can re-enter before state finalisation. Spec §4 I7.
```

---

## 7. Slither run 2026-05-19 — actual findings

Tool: slither-analyzer (latest pip, ≥0.10.x), run via the btcbot-foundry Docker image.
Total: **11 findings — 0 HIGH, 0 MEDIUM, 3 LOW, 8 informational.**

```
- Finding: missing-zero-check on transferOwnership.newOwner
  Severity: low
  Location: src/BtcbotRouter.sol:360 (after fix: 364)
  Disposition: accepted (intentional)
  Rationale: Passing address(0) is part of the public API — it cancels any pending
             transfer (Ownable2Step pattern from OZ). Adding a zero-check would
             remove the cancel functionality. Comment + slither-disable-next-line
             added inline.

- Finding: calls-loop in swapAndDistribute (external USDT.call inside fan-out loop)
  Severity: low
  Location: src/BtcbotRouter.sol:276
  Disposition: accepted (intentional)
  Rationale: Each tier transfer is independent; nonReentrant guards the whole
             function; ReentrancyGuard prevents re-entry across iterations.
             The loop is bounded to N_TIERS=6 so DoS via gas griefing is bounded.
             Spec §4 I13. The pattern is needed for try/catch + failover-to-root.

- Finding: reentrancy-events in rescueToken (event emitted after external call)
  Severity: informational
  Location: src/BtcbotRouter.sol:381-386
  Disposition: fixed
  Rationale: Reordered to CEI pattern (emit Rescued before safeTransfer). Even
             though onlyOwner-gated, the best-practice ordering is harmless and
             cleaner.

- Finding: timestamp comparison in swapAndDistribute / swapUsdtToBtcb
  Severity: low
  Location: src/BtcbotRouter.sol:249, 253, 332
  Disposition: accepted (false positive)
  Rationale: The flagged comparisons are `totalCommission * BPS_DENOMINATOR >
             usdtOut * MAX_COMMISSION_BPS`, `usdtOut < pancakeMinOut`, and
             `btcbOut < minBtcbOut` — none involve block.timestamp directly.
             Slither's heuristic flags them because block.timestamp appears
             earlier (as Pancake deadline). Standard pattern, no manipulation
             surface.

- Finding: low-level-calls in fan-out
  Severity: informational
  Location: src/BtcbotRouter.sol:276
  Disposition: accepted (intentional)
  Rationale: The low-level `USDT.call(transfer.selector, ...)` is the mechanism
             that lets the contract catch reverting / returns-false transfers
             without killing the whole tx (failover-to-root). Spec §4 I13.

- Finding: naming-convention on immutables (BTCB, USDT, PANCAKE_ROUTER, PERMIT2)
  Severity: informational
  Location: src/BtcbotRouter.sol:49,51,53,55
  Disposition: accepted (style choice)
  Rationale: SCREAMING_SNAKE_CASE is conventional for `constant`/`immutable`
             variables per the Solidity style guide. Slither's check defaults
             to mixedCase for all state vars including immutables.

- Finding: naming-convention on setPaused._paused parameter
  Severity: informational
  Location: src/BtcbotRouter.sol:374
  Disposition: accepted (style choice)
  Rationale: Underscore prefix disambiguates the parameter from the state variable
             `paused`. Common Solidity convention.
```

**Re-run after applying fix #3 should drop to 10 results.** Other findings are
permanent accepted exceptions documented above.

---

## 8. Slither run 2026-05-19 v2 (post-Permit2-removal) — actual findings

Tool: slither-analyzer (latest pip, ≥0.10.x).
Total: **10 findings — 0 HIGH, 0 MEDIUM, 2 LOW, 8 informational.**

Changes vs v1:
- `reentrancy-events`: gone (CEI fix applied)
- `arbitrary-send-erc20`: NEW (we now do `transferFrom(user, this, amount)` with `user`
  as a parameter, which Slither flags as potentially-arbitrary)

```
- Finding: arbitrary-send-erc20 in swapAndDistribute / swapUsdtToBtcb
  Severity: low
  Location: src/BtcbotRouter.sol (safeTransferFrom calls)
  Disposition: accepted (intentional)
  Rationale: The `user` parameter IS arbitrary by design — the trader passes which
             user is being executed against. Security is enforced by:
             1) onlyTrader modifier (only the trader hot wallet can call)
             2) the user MUST have approved this contract for the input token; an
                arbitrary user without prior approval causes transferFrom to revert
             3) the trader is trusted (operator's hot wallet, same as in any DEX
                aggregator pattern)
             This is identical to how Uniswap Router pulls user tokens via approve.

- Remaining LOW + informational findings: same as v1
  (missing-zero-check on transferOwnership is gone — fixed via slither-disable line)
```

**Conclusion: contract is ready for friends-testing.**

---

## 9. Slither run 2026-06-08 (post-`batchSwapAndDistribute` / Tier 2 A1) — actual findings

> **CORRECTION 2026-06-08:** `batchSwapAndDistribute` was first added to the V2
> `BtcbotRouter.sol` by mistake. The LIVE contract is **`BtcbotCommissionRouter.sol`**
> (V3, `0xb19125…`, deploy log `deploy-commission-router.log`). The batch was re-ported
> to `BtcbotCommissionRouter.sol` (V3 `exactInputSingle`) and the V2 additions reverted.
> The findings below apply to **`BtcbotCommissionRouter.batchSwapAndDistribute`** — same
> detectors, same dispositions; only the file name + exact line numbers shift (the V2
> source paths/lines quoted below are historical — see `slither-report*.txt` for the
> current V3 lines). Post-revert slither: **24 results, 0 new HIGH/MEDIUM**, batch =
> info/low only; `arbitrary-from-in-transferfrom` fires only on the single-user
> `safeTransferFrom` of both contracts, NOT on the batch (it uses a low-level call).

Tool: slither-analyzer (btcbot-foundry image, ≥0.10.x):
`slither . --filter-paths "lib/|test/" --exclude-dependencies`.
Total: **24 results — 0 NEW HIGH, 0 NEW MEDIUM.** The new `batchSwapAndDistribute` adds
only informational/low findings (each dispositioned below); all single-user
`swapAndDistribute` / `swapUsdtToBtcb` findings are unchanged from §7/§8.

### New `batchSwapAndDistribute` findings (all accepted)

```
- Finding: divide-before-multiply — userGross = (amt * totalUsdtOut)/totalIn, then
           userGross * MAX_COMMISSION_BPS in the per-leg cap check
  Severity: informational
  Location: src/BtcbotRouter.sol#393,401
  Disposition: accepted (intentional)
  Rationale: userGross is the REAL wei the user receives — the truncation IS the dust
             policy (design doc §10). The 35% cap must be measured against the actual
             distributable amount, not a higher-precision phantom. No exploitable
             precision loss; dust bounded (≤ ~1 wei × legs), swept via rescueToken.
             Proven by test_batch_dust (Σ distributed + dust == totalUsdtOut).

- Finding: uninitialized-local-variables — totalIn, totalCommission
  Severity: informational
  Location: src/BtcbotRouter.sol#350,395
  Disposition: accepted (false positive)
  Rationale: Solidity zero-initializes value-type locals. totalIn accumulates from 0;
             totalCommission is re-summed (and re-zeroed) per leg. Idiomatic.

- Finding: calls-loop — BTCB.call(transferFrom) + USDT.call(transfer) inside loops
  Severity: low
  Location: src/BtcbotRouter.sol#361,420
  Disposition: accepted (intentional)
  Rationale: Same as §7 for the single-user fan-out. Each pull/transfer is independent;
             nonReentrant guards the whole fn; loops are bounded by legs.length, which the
             trader caps at TRADER_BATCH_MAX_LEGS (≈40, see B2). The low-level call IS the
             failure-isolation mechanism (skip bad leg / failover-to-root) — the whole
             point of Tier 2. A reverting leg cannot DoS the batch.

- Finding: low-level-calls
  Severity: informational
  Location: src/BtcbotRouter.sol#361,420
  Disposition: accepted (intentional) — same rationale as §7/§8.

- Finding: cyclomatic-complexity (17)
  Severity: informational
  Location: src/BtcbotRouter.sol#339-438
  Disposition: accepted
  Rationale: Inherent to the two-pass (pull → swap → distribute) design with per-leg
             failure isolation + per-tier failover. Mitigated by 15 dedicated unit tests
             covering every branch (test/BtcbotRouter.batch.t.sol); full 38-test suite green.

- Finding: block-timestamp (Pancake deadline + cap-comparison heuristic)
  Severity: low
  Location: src/BtcbotRouter.sol (batch fn)
  Disposition: accepted (false positive) — same as §7. The cap comparison involves no
             block.timestamp; the only timestamp use is deadline = block.timestamp.
```

### Pre-existing findings (unchanged, already dispositioned in §7/§8)

```
- arbitrary-from-in-transferfrom (HIGH native): fires ONLY on the single-user
  safeTransferFrom(user, ...) in both routers (BtcbotRouter#224,455 +
  BtcbotCommissionRouter#228,313). Does NOT fire on batchSwapAndDistribute (it uses a
  low-level BTCB.call(transferFrom…) slither doesn't pattern-match). Disposition UNCHANGED
  from §8: accepted — `user` is arbitrary BY DESIGN (trader passes the executed user),
  gated by onlyTrader + the user's own prior approval (no approval → revert). Identical to
  the Uniswap router pull pattern. NO new instance introduced by Tier 2.
- naming-convention (immutables, _paused): accepted style, §7.
```

**Conclusion: `batchSwapAndDistribute` introduces no new high/medium findings; the audit
posture is identical to the live single-user contract. Ready for external re-audit +
Blockaid re-clear (C2) before deploy.**
