# Security review history

These documents were written while each router generation was built. They are kept as they were written, so they describe the state of the code at their date, not today's. This page says what each one covers.

**What kind of review.** Internal reviews and several rounds of AI-assisted security review (the reviewers are named in the documents: Claude, ChatGPT, Gemini), plus Slither static analysis. No third-party audit firm was hired: the main README explains this choice. `AUDIT_SCOPE_V2.md` was written as a scope for an external review of V2; the reviews that followed are the AI-assisted rounds recorded in `AUDIT_FIXES_V2.md`.

## Documents

| File | Covers | Date | What it is |
|---|---|---|---|
| `REVIEW_2026-05-19.md` | `BtcbotRouter`, first design (Permit2, PancakeSwap V2) | 2026-05-19 | Design and security review, AI-assisted |
| `H1_patch.md` | Same contract | 2026-05-19 | The fix for finding H1 of that review |
| `AUDIT_CHECKLIST.md` | `BtcbotRouter`, then `BtcbotCommissionRouter` | May to June 2026 | Pre-deploy checklist and Slither dispositions |
| `AUDIT_SCOPE_V2.md` | `BtcbotRouterV2` | 2026-06-29 | Review scope: architecture, trust model, accepted risks |
| `AUDIT_FIXES_V2.md` | `BtcbotRouterV2` | June 2026 | Five review rounds, every finding and its fix |
| `slither-report.txt`, `slither-report-v2.txt`, `slither-report-post-fix.txt` | `BtcbotRouter` | 2026-05-19 | Slither output, before and after fixes |
| `slither-report-v3-20260611.txt` | `BtcbotCommissionRouter` (batch, `0xB81C…`) | 2026-06-11 | Slither output. "v3" here means the PancakeSwap V3 generation, not `BtcbotRouterV3` |
| `slither-report-duplex-20260625.txt` | `BtcbotRouterDuplex` and earlier routers | 2026-06-25 | Slither output |
| `slither-report-routerv3-20261004.txt` | All routers in `src/`, including `BtcbotRouterV3` | 2026-10-04 | Slither 0.11.6 output |

## Reading the older documents

- **`AUDIT_CHECKLIST.md`, section 3**: the unchecked boxes are the to-do list as written on 2026-05-19. The HIGH and MEDIUM items were applied in `src/BtcbotRouter.sol` before mainnet (H1 `minUserReceived`, H2 swap tests, M1 two-step ownership, M3 return-data guard, M4 last-hop output). M2 became moot when Permit2 was removed; M5 was optional.
- **Roadmap in `REVIEW_2026-05-19.md`**: it planned an external audit and a multisig owner before growth. We chose instead the approach described in the main README. The owner of the current routers (V2 and V3) is a single hardware wallet.
- **Slither "0 high / 0 medium"** in the older documents means no finding left open after triage, not an empty raw report.

## Slither on BtcbotRouterV3 (2026-10-04)

Raw count for `src/BtcbotRouterV3.sol`: 2 High, 7 Medium, 14 Low, 12 Informational. None is open:

| Detector | Impact | Count | Disposition |
|---|---|---|---|
| `arbitrary-send-erc20` | High | 2 | By design. The router pulls from the user named by the trader key, which only works with that user's own approval and signed mandate, inside the oracle floor. Same pattern as the Uniswap router. |
| `reentrancy-no-eth` | Medium | 3 | False positive. Batch functions are `nonReentrant`, and BTCB and USDT are fixed, hookless tokens: a transfer cannot call back. |
| `uninitialized-local` | Medium | 4 | False positive. Solidity zero-initializes local counters (`totalIn`, `bCount`); starting from zero is intended. |
| `calls-loop`, `reentrancy-benign`, `timestamp` | Low | 14 | Intended: transfers inside loops bounded by the batch size, per-leg failure isolation, timestamps used for deadlines, mandate expiry and the timelock. |
| `low-level-calls`, `cyclomatic-complexity`, `naming-convention` | Informational | 12 | Intended: low-level calls isolate a failing transfer; style. |

The same classes appear for `BtcbotRouterV2`, with the same dispositions (`AUDIT_FIXES_V2.md`).
