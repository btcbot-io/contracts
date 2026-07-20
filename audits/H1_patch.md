# H1 patch — fix the `minUsdtOut` semantic ambiguity

## Why this matters

In the current `swapAndDistribute`, the argument `minUsdtOut` is used in two incompatible ways:

1. As the floor passed to `PancakeRouter.swapExactTokensForTokens` — meaning *"the swap must return ≥ this much USDT, gross"*.
2. As the user-side floor in `usdtOut < minUsdtOut + totalCommission` — meaning *"the user must receive ≥ this much USDT, net of commission"*.

The spec invariant **I1** says *"userReceived ≥ minUsdtOut"* — that's the user-net interpretation. Under the current code, the trader must therefore pre-compute `minUsdtOut = userMinNet + totalCommission` off-chain. This is an unwritten contract that will be violated one day. The fix is to make the user-net floor the **explicit, named** argument, and have the contract compute the Pancake floor itself.

---

## Change summary

- Rename argument `minUsdtOut` → `minUserReceived` (semantic clarity).
- Move the `totalCommission` summation **before** the swap.
- Compute `pancakeMinOut = minUserReceived + totalCommission` and pass that to Pancake.
- Replace the post-swap check `usdtOut < minUsdtOut + totalCommission` with `usdtOut < pancakeMinOut` (defense-in-depth — Pancake already enforces it).
- Keep the cap check (`totalCommission ≤ usdtOut × MAX_COMMISSION_BPS / 10000`) where it is — it can only be computed after the swap since it depends on `usdtOut`.

---

## Patched function — full replacement

Replace the entire body of `swapAndDistribute` (currently lines 190–281) with the following:

```solidity
/// @notice Execute a SELL with atomic commission fan-out.
/// @dev Sequence:
///   1. Pull BTCB from user via Permit2.
///   2. Sum commission and compute Pancake floor as `minUserReceived + totalCommission`.
///   3. Approve Pancake to spend the pulled BTCB.
///   4. Swap BTCB → USDT with the computed floor, output to this contract.
///   5. Sanity-check commission ≤ MAX_COMMISSION_BPS of usdtOut.
///   6. Defense-in-depth: usdtOut must cover commission + user floor.
///   7. For each tier i: transfer parts[i] to recipients[i], with self-pay
///      short-circuit (recipient == user → accumulate into user remainder)
///      and failover-to-root (transfer reverts or returns-false → send slice to root).
///   8. Transfer remainder to user.
/// @param user The user's wallet address (must match the signer of `permit`).
///             Permit2 will revert signature verification if mismatched — no forging.
/// @param permit Permit2 message authorising the BTCB pull
/// @param signature User's EIP-712 signature over `permit`
/// @param minUserReceived Minimum USDT the user must receive AFTER commission. The
///                        Pancake floor is computed internally as
///                        `minUserReceived + sum(parts)`.
/// @param tierRecipients Array of 6 addresses: tiers 1..5 + root at index 5
/// @param parts Per-tier USDT amounts in token units (sum = total commission)
/// @return userReceived The USDT amount actually sent to the user
function swapAndDistribute(
    address user,
    ISignatureTransfer.PermitTransferFrom calldata permit,
    bytes calldata signature,
    uint256 minUserReceived,
    address[N_TIERS] calldata tierRecipients,
    uint256[N_TIERS] calldata parts
) external onlyTrader whenNotPaused nonReentrant returns (uint256 userReceived) {
    if (user == address(0)) revert ZeroAddress();
    if (permit.permitted.token != BTCB) revert WrongPermitToken();

    // 1. Pull BTCB from user → this contract. Permit2 verifies signature against
    //    `user` as the EIP-712 signer; mismatched user reverts here.
    ISignatureTransfer.SignatureTransferDetails memory td = ISignatureTransfer
        .SignatureTransferDetails({to: address(this), requestedAmount: permit.permitted.amount});
    ISignatureTransfer(PERMIT2).permitTransferFrom(permit, td, user, signature);

    // 2. Sum commission and compute the Pancake floor.
    uint256 totalCommission;
    unchecked {
        // 6 × max(uint256) overflow is impossible with realistic USDT amounts.
        // The post-swap cap check would catch any garbage anyway.
        totalCommission = parts[0] + parts[1] + parts[2] + parts[3] + parts[4] + parts[5];
    }
    // pancakeMinOut: the floor we pass to Pancake. Reverts on overflow under 0.8 checked math.
    uint256 pancakeMinOut = minUserReceived + totalCommission;

    // 3. Approve Pancake for this exact BTCB amount.
    IERC20(BTCB).forceApprove(PANCAKE_ROUTER, permit.permitted.amount);

    // 4. Swap BTCB → USDT to this contract.
    address[] memory path = new address[](2);
    path[0] = BTCB;
    path[1] = USDT;
    uint256[] memory amounts = IPancakeV2Router(PANCAKE_ROUTER).swapExactTokensForTokens(
        permit.permitted.amount,
        pancakeMinOut,
        path,
        address(this),
        block.timestamp
    );
    uint256 usdtOut = amounts[amounts.length - 1];

    // 5. Commission sanity cap (can only check after swap — depends on usdtOut).
    if (totalCommission * BPS_DENOMINATOR > usdtOut * MAX_COMMISSION_BPS) {
        revert CommissionTooHigh();
    }
    // 6. Defense-in-depth. Pancake should have enforced this already.
    if (usdtOut < pancakeMinOut) revert InsufficientOutput();

    // 7. Fan-out
    userReceived = usdtOut;
    for (uint256 i = 0; i < N_TIERS; i++) {
        uint256 part = parts[i];
        if (part == 0) continue;

        uint8 tierLabel = (i == ROOT_TIER_IDX) ? 0 : uint8(i + 1);
        address recipient = tierRecipients[i];

        if (recipient == user) {
            // Self-pay short-circuit: don't make an on-chain transfer to user
            // (we'll send the final remainder to user anyway), just keep the slice.
            emit TierSelfPaySkipped(user, tierLabel, part);
            continue;   // userReceived unchanged
        }
        userReceived -= part;

        // Try the transfer; on failure (revert OR returns-false), failover to root.
        // Low-level call so a malicious/blacklisted token can't grief us with a revert
        // that kills the whole tx. We also guard against unexpected return-data lengths.
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
            // if it does, the whole tx reverts (user keeps BTCB; nothing left on chain).
            IERC20(USDT).safeTransfer(root, part);
            emit TierFailoverToRoot(user, recipient, tierLabel, part);
        }
    }

    // 8. Send remainder to user.
    IERC20(USDT).safeTransfer(user, userReceived);

    emit SwapAndDistribute(user, permit.permitted.amount, usdtOut, totalCommission, userReceived);
}
```

---

## Other code edits required by this patch

### Add a new custom error (in the `Errors` section)

```solidity
error WrongPermitToken();
```

Use it also in `swapUsdtToBtcb` (replace the `require(permit.permitted.token == USDT, "...")` with `if (permit.permitted.token != USDT) revert WrongPermitToken();`).

### Apply `amounts[length - 1]` in `swapUsdtToBtcb` too (M4)

```solidity
// before
btcbOut = amounts[1];
// after
btcbOut = amounts[amounts.length - 1];
```

---

## Caller-side impact (off-chain)

The trader Python code that calls `swapAndDistribute` must update its argument computation:

**Before:**
```python
min_usdt_out = expected_gross_usdt * (1 - slippage_tolerance)
router.swapAndDistribute(
    user, permit, sig,
    min_usdt_out,      # ambiguous: gross floor?
    recipients, parts
)
```

**After:**
```python
expected_gross_usdt = oracle_price_usdt(amount_btcb_in)
total_commission = sum(parts)
# minUserReceived is the user's NET floor — what they must end up with.
min_user_received = (expected_gross_usdt - total_commission) * (1 - slippage_tolerance)
router.swapAndDistribute(
    user, permit, sig,
    min_user_received,    # explicit: user-net floor
    recipients, parts
)
```

Document this in the trader code with a comment pointing to `H1_patch.md`.

---

## Test coverage that proves the fix

In `test/BtcbotRouter.swap.t.sol`:

- `test_swap_revertsOnSlippage` — sets a `minUserReceived` higher than what the Pancake mock will return; expects `InsufficientOutput` (or Pancake's `Mock: insufficient output` revert).
- `test_swap_happyPath` — verifies `userReceived` from the function return matches `minUserReceived` floor and equals `usdtOut - totalCommission`.
- `test_swap_conservation` — verifies `userReceived + sum(transfers from contract to non-user) == usdtOut` regardless of parts distribution.
