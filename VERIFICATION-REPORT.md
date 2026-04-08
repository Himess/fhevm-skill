# FHEVM SKILL.md Verification Report

## Overview

4 independent auditor agents verified the code produced by the test agents. Each auditor read the skill files first (as ground truth), then scrutinized every line of the generated code.

---

## Audit Results Summary

| Agent Output | Critical | High | Medium | Low | Verdict |
|-------------|----------|------|--------|-----|---------|
| ConfidentialERC20 | 0 | 1 | 3 | 5 | Good — 1 bug inherited from OUR template |
| Blind Auction | **1** | 1 | 3 | 4 | Escrow mechanism broken |
| Frontend React | 0 | 1 | 5 | 5 | Structurally sound, operational issues |
| Confidential Lending | 0 | 1 | 6 | 4 | Strong — overflow risk in DeFi math |

---

## CRITICAL Findings

### 1. OUR TEMPLATE HAS A BUG: `_spendAllowance` bypass in ConfidentialERC20
**Source**: `templates/confidential-erc20.sol`
**Found by**: ERC20 Auditor

In `transferFrom`, `_spendAllowance` caps the spend amount to 0 if allowance is insufficient, but the ORIGINAL uncapped `amount` is still passed to `_transfer`. Since `_transfer` independently checks against balance, **a spender can transfer more than their allowance** if the sender has sufficient balance.

**Attack**: Owner has 10000 tokens, approves Alice for 100. Alice calls `transferFrom(owner, bob, 500)`:
- `_spendAllowance`: 500 > 100 → spendAmount = 0, allowance unchanged
- `_transfer`: 500 ≤ 10000 → transfers 500 tokens

**THIS IS A BUG IN OUR SKILL TEMPLATE.** Must fix immediately.

### 2. Auction token escrow sends to self instead of pulling from bidder
**Source**: Generated `MultiBlindAuction.sol`
**Found by**: Auction Auditor

`paymentToken.transfer(address(this), bidAmount)` transfers tokens FROM the auction contract TO itself — not from the bidder. The entire escrow/refund mechanism is non-functional.

**Root cause**: The skill doesn't have a clear "pull tokens from user" pattern for encrypted tokens. The cross-contract section shows pushing tokens, not pulling. We added the escrow pattern in the fix round but the test agent ran before the fix.

---

## HIGH Findings

### 3. euint64 overflow in DeFi multiplications (Lending)
`FHE.mul(debt, uint64(100))` overflows if debt > MAX_UINT64/100 (~184 tokens with 18 decimals). Realistic in DeFi.

**Skill gap**: No guidance on overflow risk with `FHE.mul`. Should recommend simplified math: `debt * 2` instead of `debt * 100 / 50`.

### 4. Missing ReentrancyGuard on Auction
Contract makes external calls to token but doesn't inherit ReentrancyGuard.

### 5. Handle type mismatch in frontend decryption lookup
`balanceOf` returns `bigint` (uint256 ABI), but SDK's `userDecrypt` result may key by hex string. `result[encHandle]` where encHandle is bigint could return undefined.

---

## What the Skill Guided CORRECTLY (All 4 Agents)

| Pattern | ERC20 | Auction | Frontend | Lending |
|---------|-------|---------|----------|---------|
| `FHE.allowThis` after state storage | ✅ | ✅ | N/A | ✅ |
| `FHE.allow` for users | ✅ | ✅ | N/A | ✅* |
| No `if/require` on encrypted values | ✅ | ✅ | N/A | ✅ |
| `FHE.select` for conditional logic | ✅ | ✅ | N/A | ✅ |
| Plaintext-only divisors | ✅ | ✅ | N/A | ✅ |
| `FHE.fromExternal` (not deprecated TFHE) | ✅ | ✅ | N/A | ✅ |
| `ZamaEthereumConfig` (not old config) | ✅ | ✅ | N/A | ✅ |
| Correct import paths | ✅ | ✅ | ✅ | ✅ |
| Silent transfer pattern | ✅ | ✅ | N/A | ✅ |
| SDK encryption flow | N/A | N/A | ✅ | N/A |
| EIP-712 decryption flow | N/A | N/A | ✅ | N/A |
| `eaddress` with FHE.select | N/A | ✅ | N/A | N/A |
| Cached ENCRYPTED_ZERO | N/A | N/A | N/A | ✅ |
| FHE.min/max optimization | N/A | N/A | N/A | ✅ |

*Lending missed `FHE.allow` for owner on `_totalCollateral`/`_totalDebt`

**Conclusion**: The anti-pattern prevention system works. Zero agents used deprecated APIs, branched on encrypted values, or divided by encrypted values.

---

## Skill Issues That MUST Be Fixed

### FIX 1: Template `_spendAllowance` Bug [CRITICAL]
**File**: `templates/confidential-erc20.sol`

`_spendAllowance` must return the capped amount, and `transferFrom` must use it:

```solidity
function transferFrom(...) {
    euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
    euint64 cappedAmount = _spendAllowance(from, msg.sender, amount);
    _transfer(from, to, cappedAmount);  // Use capped amount, not original
}

function _spendAllowance(...) internal returns (euint64) {
    // ... cap logic ...
    return spendAmount;  // Return the capped amount
}
```

### FIX 2: Add FHE.mul overflow warning [HIGH]
**File**: `references/common-pitfalls.md` and `references/gas-optimization.md`

Add pitfall: "Simplify FHE math to avoid overflow":
```
// RISKY: debt * 100 overflows if debt > MAX_UINT64/100
FHE.div(FHE.mul(debt, uint64(100)), uint64(50))

// SAFE: simplify the fraction first
FHE.mul(debt, uint64(2))  // 100/50 = 2
```

### FIX 3: Strengthen token escrow guidance [MEDIUM]
**Already partially fixed** in `references/erc7984-guide.md` (we added `IConfidentialERC20` + escrow pattern in the fix round). But the pattern needs to be more prominently referenced from SKILL.md.

---

## Skill Issues That Are Nice-to-Fix

| Issue | Where | Effort |
|-------|-------|--------|
| Add `FHE.isAllowed` check to template `balanceOf`/`allowance` | templates/confidential-erc20.sol | 5 min |
| Warn about `accrueInterest` being public + griefing | references/security-checklist.md | 5 min |
| Note that `makePubliclyDecryptable` works on all types | references/decryption-guide.md | 2 min |
| Clarify handle return type for frontend (bigint vs hex) | references/frontend-integration.md | 5 min |

---

## Overall Skill Quality Assessment

### Before fixes: 7.6/10 (from test agents)
### After first fix round: ~8.5/10 (estimated)
### After this verification round fixes: ~9.0/10 (estimated)

The skill produces **correct FHEVM patterns** in all cases. The failures are:
1. One bug in our own template (allowance bypass) — fixable
2. Missing DeFi-specific guidance (overflow, escrow) — fixable
3. Frontend operational details (handle types) — partially fixed

**No agent produced deprecated API code, branched on encrypted values, or forgot allowThis.** The anti-pattern prevention system is working excellently.
