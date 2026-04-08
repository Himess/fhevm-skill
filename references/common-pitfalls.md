# FHEVM Common Pitfalls & Battle Scars

## Critical Pitfalls (Will Break Your Contract)

### 1. Missing `FHE.allowThis()` After Operations

**Severity**: Critical — contract permanently loses access to encrypted data

```solidity
// BROKEN: contract can't access newBalance in future transactions
balances[user] = FHE.add(balances[user], amount);

// FIXED:
balances[user] = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]);       // ← ALWAYS do this
FHE.allow(balances[user], user);     // ← And grant user access
```

**Why**: Every FHE operation creates a NEW handle with NO permissions. ACL permissions from the old handle do NOT carry over. Without `allowThis`, the contract's own storage variable becomes inaccessible.

**How to detect**: Any FHE operation whose result is stored to state MUST be followed by `allowThis` + `allow`.

### 2. Using `if/require/assert` with Encrypted Values

**Severity**: Critical — leaks confidential information

```solidity
// BROKEN: reveals whether user has enough balance
require(balance >= amount, "Insufficient balance");

// FIXED: use select pattern (always executes both paths)
ebool sufficient = FHE.ge(balance, amount);
euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));
```

**Why**: `if` statements create different execution paths. Validators observe which path was taken, leaking the encrypted boolean value. All control flow based on encrypted data must use `FHE.select()`.

### 3. Division/Remainder by Encrypted Value

**Severity**: Critical — compilation error or runtime failure

```solidity
// BROKEN: FHE.div(encrypted, encrypted) does not exist
euint64 share = FHE.div(total, encryptedCount);

// FIXED: divisor must be plaintext
euint64 share = FHE.div(total, uint64(participantCount));
```

**Why**: Encrypted division is not supported by the underlying FHE scheme. Only `FHE.div(euintX, uintX)` with a plaintext right-hand operand is available.

### 4. Using Deprecated TFHE Library for New Contracts

**Severity**: Critical — API mismatch, wrong addresses

```solidity
// BROKEN: old API
import "fhevm/lib/TFHE.sol";
TFHE.asEuint64(encryptedInput, inputProof);
Gateway.requestDecryption(...);

// FIXED: new API
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
FHE.fromExternal(encryptedInput, inputProof);
FHE.makePubliclyDecryptable(value);  // + checkSignatures for verification
```

**When to use TFHE**: ONLY when extending `fhevm-contracts` (which still uses the old library). For all new standalone contracts, use `FHE` from `@fhevm/solidity`.

### 5. Missing `evmVersion: "cancun"` in Hardhat Config

**Severity**: Critical — `allowTransient` will fail silently

```typescript
// BROKEN: default EVM version doesn't support EIP-1153
solidity: { version: "0.8.27" }

// FIXED: must specify cancun
solidity: {
    version: "0.8.27",
    settings: { evmVersion: "cancun" }
}
```

**Why**: `FHE.allowTransient()` uses EIP-1153 transient storage, which requires the Cancun hardfork EVM version.

### 5b. Installing Hardhat 3 Instead of Hardhat 2

**Severity**: Critical — FHEVM plugin will not work

```bash
# BROKEN: installs Hardhat 3 (latest), which is incompatible with @fhevm/hardhat-plugin
npm install hardhat

# CORRECT: install Hardhat 2
npm install hardhat@^2.22.0
```

**Why**: `@fhevm/hardhat-plugin@0.4.2` has a peer dependency on `hardhat@^2.0.0`. Hardhat 3 has a completely different plugin API, test runner, and configuration system. Symptoms: "Cannot determine a test runner", "invalid: ^2.0.0 from @fhevm/hardhat-plugin". **Always clone `fhevm-hardhat-template`** to avoid this issue, or pin `hardhat@^2.22.0` when setting up from scratch.

### 5c. Missing `viaIR: true` for Complex FHE Contracts

**Severity**: Critical — "Stack too deep" compilation error

```typescript
// BROKEN: complex FHE contracts hit stack-too-deep without viaIR
solidity: {
    version: "0.8.27",
    settings: { evmVersion: "cancun", optimizer: { enabled: true, runs: 800 } }
}

// FIXED: enable viaIR for contracts with many FHE operations
solidity: {
    version: "0.8.27",
    settings: {
        evmVersion: "cancun",
        viaIR: true,  // Required for complex FHE contracts
        optimizer: { enabled: true, runs: 800 }
    }
}
```

**Why**: FHE operations produce many intermediate variables (handles). Complex contracts with multiple FHE operations in one function exceed Solidity's default stack limit. `viaIR: true` uses the IR-based code generator which handles deep stacks. The MARC Protocol uses this in production.

### 5d. NatDoc `@` Symbol in Solidity Comments

**Severity**: High — compilation fails

```solidity
// BROKEN: Solidity parser interprets @fhevm as a NatDoc tag
/// @dev Uses the new FHE library from @fhevm/solidity v0.11+.
//  → DocstringParsingError: Documentation tag @fhevm/solidity not valid

// FIXED: Avoid @ in NatDoc comments, or escape it
/// @dev Uses the new FHE library (fhevm/solidity v0.11+).
```

**Why**: Solidity's NatDoc parser treats any `@word` in `///` comments as a documentation tag. Package names like `@fhevm/solidity` or `@openzeppelin/contracts` trigger parsing errors.

### 5e. Missing `@fhevm/mock-utils` Dependency

**Severity**: High — tests won't run in mock mode

```bash
# The hardhat plugin needs mock-utils as a separate dependency
npm install --save-dev @fhevm/mock-utils@^0.4.2
```

The `@fhevm/hardhat-plugin` requires `@fhevm/mock-utils` for local testing but doesn't always install it automatically. If you see errors about missing mock utilities, install it explicitly.

### 5f. FHE Operations Cannot Be Used in view/pure Functions

**Severity**: High — compilation error

```solidity
// BROKEN: FHE operations modify coprocessor state — cannot be view/pure
function getVestedAmount(address user) public view returns (euint64) {
    return FHE.mul(vestingAmount, uint64(elapsed));  // Compiler error!
}

// FIXED: Remove view modifier — FHE ops are state-changing
function getVestedAmount(address user) public returns (euint64) {
    euint64 result = FHE.mul(vestingAmount, uint64(elapsed));
    FHE.allowThis(result);
    FHE.allow(result, user);
    return result;
}
```

**Why**: ALL FHE operations (`add`, `sub`, `mul`, `div`, `select`, `eq`, `gt`, `min`, `max`, `rand`, etc.) produce new handles by sending computation requests to the coprocessor. This counts as state modification. Only `FHE.isInitialized()`, `FHE.isAllowed()`, `FHE.isSenderAllowed()`, and `FHE.isPubliclyDecryptable()` are true view functions.

## High-Impact Pitfalls (Subtle Bugs)

### 6. Silent Transfer Failures

**Severity**: High — appears to work but transfers 0

FHE transfers NEVER revert on insufficient balance. They silently transfer 0 to preserve confidentiality.

```solidity
// This "works" even with zero balance — it just transfers 0
function transfer(address to, euint64 amount) external {
    // No revert! The select pattern handles it internally:
    ebool ok = FHE.le(amount, balances[msg.sender]);
    euint64 actual = FHE.select(ok, amount, FHE.asEuint64(0));
}
```

**Detection heuristic** (off-chain):
```typescript
// Compare sender's balance handle before and after
const handleBefore = await token.balanceOf(sender);
await token.transfer(recipient, encAmount, proof);
const handleAfter = await token.balanceOf(sender);
// If handleBefore === handleAfter, the transfer likely failed (0 transferred)
```

### 7. Input Proofs Bound to msg.sender

**Severity**: High — cross-contract encrypted inputs fail

```solidity
// BROKEN: forwarding encrypted input to another contract
contract Router {
    function routePayment(externalEuint64 enc, bytes calldata proof) external {
        // msg.sender changes from user → Router
        token.deposit(enc, proof);  // ← Proof validation fails!
    }
}
```

**Fix**: Use a 2-transaction flow:
1. User sends encrypted input directly to the target contract
2. Router triggers business logic in a separate call

### 8. Ordering Comparisons on euint256

**Severity**: High — compilation error

```solidity
// BROKEN: euint256 only supports eq/ne
ebool bigger = FHE.gt(euint256_a, euint256_b);  // Does not exist!

// FIXED: use euint128 or smaller for ordering
// Or use eq/ne only for euint256
ebool equal = FHE.eq(euint256_a, euint256_b);  // OK
```

### 9. Random in View Functions

**Severity**: High — transaction reverts

```solidity
// BROKEN: view functions can't mutate state
function getRandom() external view returns (euint8) {
    return FHE.randEuint8();  // Reverts! PRNG needs state mutation
}

// FIXED: must be a state-changing function
function generateRandom() external returns (euint8) {
    euint8 rand = FHE.randEuint8();
    FHE.allowThis(rand);
    return rand;
}
```

### 10. Bounded Random with Non-Power-of-2

**Severity**: High — unexpected behavior or revert

```solidity
// BROKEN: 6 is not a power of 2
euint8 dice = FHE.randEuint8(6);

// FIXED: use next power of 2, then modulo
euint8 rand = FHE.randEuint8(8);  // [0, 8)
euint8 dice = FHE.rem(rand, uint8(6));  // [0, 6)
```

### 11. FHE.mul Overflow with Large Multipliers (DeFi-Critical)

**Severity**: High — silent incorrect results in DeFi

```solidity
// RISKY: debt * 100 overflows if debt > MAX_UINT64 / 100 (~1.84 * 10^17)
// With 18-decimal tokens, this overflows at just ~0.184 tokens!
euint64 scaled = FHE.mul(debt, uint64(100));

// SAFE: simplify the fraction BEFORE multiplying
// Instead of: debt * 100 / 50, compute: debt * 2
euint64 required = FHE.mul(debt, uint64(2));

// Instead of: collateral * 50 / 100, compute: collateral / 2
euint64 maxBorrow = FHE.div(collateral, uint64(2));

// Instead of: amount * 110 / 100, compute: amount + amount / 10
euint64 bonus = FHE.div(amount, uint64(10));
euint64 withBonus = FHE.add(amount, bonus);
```

**Why**: FHE arithmetic wraps silently on overflow (no revert). With 18-decimal ERC-20 tokens, even small amounts can overflow when multiplied by constants like 100 or 110. Always simplify fractions first.

### 11b. FHE.mul(encrypted, encrypted) Overflow in DeFi Invariants

**Severity**: High — breaks AMM/DEX constant product checks

```solidity
// RISKY: reserveA * reserveB overflows euint64 when reserves are large
// euint64 max = ~18.4 × 10^18. Two reserves of 10^9 tokens (6 decimals = 10^15 raw)
// → product = 10^30, far exceeding euint64 max
euint64 k = FHE.mul(reserveA, reserveB);  // Silent overflow!

// SAFER APPROACH: validate invariant with comparison, not product
// Instead of checking: newReserveA * newReserveB >= oldK
// Check: newReserveA * newReserveB >= reserveA * reserveB
// But BOTH sides overflow equally, so this still doesn't work!

// RECOMMENDED: user submits expected amountOut, contract validates with
// multiplication-only invariant:
// (reserveA + amountIn) * (reserveB - amountOut) >= reserveA * reserveB
// This STILL has overflow risk. For production DEX, use euint128 for intermediates
// or restructure to avoid products of two large encrypted values.
```

**Design constraint**: `FHE.div(encrypted, encrypted)` does not exist. This means proportional computations like `reserve * shares / totalShares` are impossible when all three values are encrypted. Common workaround: keep LP shares or divisors as plaintext.

### 12. Allowance Bypass in transferFrom

**Severity**: High — spender can exceed allowance

```solidity
// BROKEN: _spendAllowance caps internally but transferFrom uses original amount
function transferFrom(...) {
    euint64 amount = FHE.fromExternal(enc, proof);
    _spendAllowance(from, spender, amount);  // Caps to 0 if over-allowance
    _transfer(from, to, amount);              // But uses ORIGINAL amount!
}

// FIXED: _spendAllowance MUST return the capped amount
function transferFrom(...) {
    euint64 amount = FHE.fromExternal(enc, proof);
    euint64 cappedAmount = _spendAllowance(from, spender, amount);
    _transfer(from, to, cappedAmount);  // Use the CAPPED amount
}
```

**Why**: `_spendAllowance` silently sets spend to 0 if allowance is insufficient. But if the uncapped amount is passed to `_transfer`, the balance check in `_transfer` may succeed independently, allowing transfers exceeding the approved allowance.

## Medium-Impact Pitfalls (Performance & Design)

### 11. Using `FHE.allow()` When `FHE.allowTransient()` Suffices

```solidity
// WASTEFUL: persistent storage write for single-tx use
FHE.allow(tempValue, address(otherContract));
otherContract.process(tempValue);

// BETTER: transient storage, ~20% cheaper gas
FHE.allowTransient(tempValue, address(otherContract));
otherContract.process(tempValue);
```

### 12. Using Larger Types Than Necessary

```solidity
// WASTEFUL: euint256 for a boolean flag
euint256 isActive = FHE.asEuint256(1);

// BETTER: use the smallest type that fits
ebool isActive = FHE.asEbool(true);
```

Gas increases with type width. Use `euint8` for small values, `euint64` for amounts.

### 13. Re-encrypting Constants in Loops

```solidity
// WASTEFUL: creates a new encrypted zero each iteration
for (uint i = 0; i < recipients.length; i++) {
    balances[recipients[i]] = FHE.select(condition, amount, FHE.asEuint64(0));
}

// BETTER: cache the encrypted constant
euint64 zero = FHE.asEuint64(0);
FHE.allowThis(zero);
for (uint i = 0; i < recipients.length; i++) {
    balances[recipients[i]] = FHE.select(condition, amount, zero);
}
```

### 14. Emitting Plaintext in Events

```solidity
// WRONG: defeats the purpose of encryption
emit Transfer(from, to, plaintextAmount);

// CORRECT: emit only non-sensitive data
emit Transfer(from, to);
// or emit the handle for off-chain reference
emit Transfer(from, to, FHE.toBytes32(encAmount));
```

### 15. Not Using Operator Overloads for Readability

```solidity
// VERBOSE:
euint64 result = FHE.add(FHE.mul(price, quantity), fee);

// CLEANER: operator overloads available for +, -, *
euint64 result = price * quantity + fee;
```

## Battle Scars (Real Production Lessons)

### Scar 1: "Gas is the same regardless of amount"

FHE gas costs are **constant** — encrypting `1` costs the same as encrypting `MAX_UINT64`. This is intentional: variable gas would leak information about the encrypted value. Don't try to optimize around amount-based gas costs.

### Scar 2: "The same plaintext encrypts differently each time"

Encrypting `100` twice produces two different ciphertexts. This confused our frontend tests until we realized: encryption is non-deterministic by design. Comparing ciphertexts (handles) tells you nothing about the underlying values.

### Scar 3: "allowThis is needed even for contract-owned data"

We had a contract that stored its own encrypted treasury balance. It worked once but failed on the second transaction. The first `FHE.add` created a handle the contract could use (it was the first operation). The second `FHE.add` created a NEW handle that the contract didn't have permission for. `FHE.allowThis()` after EVERY operation fixed it.

### Scar 4: "Cross-contract FHE requires careful ACL choreography"

A vault contract called a token's `transferFrom` but forgot `FHE.allowTransient()` before the call. The token contract couldn't read the encrypted amount handle, and the transfer silently moved 0 tokens. The 5-step pattern (encrypt → allowTransient → call → allow → store) must be followed exactly.

### Scar 5: "The 2048-bit decryption limit is per-request, not per-block"

We tried to decrypt 100 euint64 balances at once (6400 bits) and it failed. Batch your decryption requests: max 32 euint64 handles per request.

### Scar 6: "Fee calculations must use plaintext divisors"

We wanted to calculate a 1% fee: `FHE.div(amount, FHE.asEuint64(100))`. This doesn't compile because `FHE.div` requires a plaintext divisor. The fix: `FHE.div(amount, uint64(100))`.

### Scar 7: "Overflow wraps silently — use it as a feature"

`FHE.add(FHE.asEuint8(200), FHE.asEuint8(100))` wraps to 44 (300 mod 256). There is no revert, no error. Use `FHE.min`/`FHE.max` or explicit overflow checks with `FHE.lt(FHE.add(a, b), a)` to detect overflow.

## Functions That DO NOT Exist (Common Hallucinations)

AI models sometimes generate these — they are NOT real:

| Hallucinated Function | Reality |
|----------------------|---------|
| `FHE.allowForDecryption()` | Use `FHE.makePubliclyDecryptable()` |
| `FHE.safeAdd()` / `FHE.safeSub()` / `FHE.safeMul()` | Don't exist. All arithmetic wraps. |
| `FHE.decrypt()` (in contract) | Decryption is async via Relayer SDK off-chain |
| `FHE.isIn()` | Does not exist |
| `FHE.sealoutput()` | Does not exist in v0.11 |
| `Gateway.requestDecryption()` | Removed in v0.9+. Use self-relaying pattern. |
| `TFHE.asEuint64(einput, proof)` | Old API. New: `FHE.fromExternal(externalEuint64, proof)` |
| `ebytes64` / `ebytesXXX` | Encrypted bytes types do not exist |
| `eint8` / `eint64` (signed) | Signed encrypted integers do not exist |
| `randEuint8Bounded(n)` | Correct name: `FHE.randEuint8(uint8 upperBound)` |
