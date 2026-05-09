# FHEVM Gas Optimization Guide

## Key Principle: FHE Gas is Amount-Independent

Unlike regular EVM operations, FHE gas costs are **constant** regardless of the encrypted value. `FHE.add(1, 2)` costs the same as `FHE.add(MAX_UINT64, MAX_UINT64)`. This is by design — variable gas would leak information.

## HCU Concept (Homomorphic Compute Units)

Every FHE operation consumes two budgets simultaneously:

| Budget | Limit | Resets |
|---|---|---|
| **EVM gas** | host chain block limit (~30M on Sepolia) | per block |
| **HCU per transaction** | **20,000,000 HCU** | per tx |
| **HCU sequential depth** | **5,000,000 HCU** along the longest dependency chain | per tx |

If a transaction exceeds *either* the per-tx HCU cap or the depth cap, it
reverts with a coprocessor error — independent of EVM gas. Depth matters
because chained operations like `FHE.add(FHE.add(FHE.add(a, b), c), d)`
accumulate along a single critical path; the same four `add`s done as
`FHE.add(a, b)` and `FHE.add(c, d)` then `FHE.add(of_two, of_two)` halve the
depth.

> Source: docs.zama.org `solidity-guides/v0.11/development-guide/hcu` (latest
> as of fhevm-solidity 0.11.x). Numbers below are quoted verbatim from that
> page; re-verify after every Zama point release.

## FHE Operation Costs — `euint64` (the most-used width)

| Operation | Scalar (encrypted ⊙ plaintext) | Non-scalar (encrypted ⊙ encrypted) |
|---|---:|---:|
| `add` / `sub` | 133,000 | 162,000 |
| `mul` | 365,000 | 596,000 |
| `div` | 715,000 | — (encrypted divisor not supported) |
| `rem` | 1,153,000 | — |
| `and` / `or` / `xor` | 34,000 | 34,000 |
| `not` | — | 63 |
| `shl` / `shr` / `rotl` / `rotr` | 34,000 | ~209,000 |
| `eq` / `ne` | 83,000–84,000 | 118,000–120,000 |
| `gt` / `ge` / `lt` / `le` | 116,000–119,000 | 146,000–152,000 |
| `min` / `max` | ~150,000 | ~218,000 |
| `neg` | — | 131,000 |
| `select` | — | 55,000 |
| `randEuint64` | — | 24,000 |

## FHE Operation Costs — `euint8` (smallest, cheapest)

| Operation | Scalar | Non-scalar |
|---|---:|---:|
| `add` / `sub` | 84,000 | 88,000–91,000 |
| `mul` | 122,000 | 150,000 |
| `div` | 210,000 | — |
| `rem` | 440,000 | — |
| `and` / `or` / `xor` | ~30,000 | ~30,000 |
| `not` | — | 9 |
| `shl` / `shr` / `rotl` / `rotr` | ~32,000 | ~91,000 |
| `eq` / `ne` | 55,000 | 55,000 |
| `gt` / `ge` / `lt` / `le` | 52,000–58,000 | 58,000–63,000 |
| `min` / `max` | 84,000–89,000 | 119,000–121,000 |
| `neg` | — | 79,000 |
| `select` | — | 55,000 |
| `randEuint8` | — | 23,000 |

## Constants and trivial operations

| Operation | HCU |
|---|---:|
| `cast` (euintX → euintY) | 32 |
| `trivialEncrypt` (`FHE.asEuintX(plaintext)`) | 32 |
| `randBounded` | 23,000–30,000 |

## Boolean operations (`ebool`)

| Operation | Scalar | Non-scalar |
|---|---:|---:|
| `and` | 22,000 | 25,000 |
| `or` | 22,000 | 24,000 |
| `xor` | 2,000 | 22,000 |
| `not` | — | 2 |
| `select` | — | 55,000 |
| `randEbool` | — | 19,000 |

## Operation cost — cheap → expensive (for `euint64`)

1. `cast` / `trivialEncrypt` — 32 HCU (effectively free)
2. `not` — 63 HCU
3. `randEuint64` — 24,000 HCU (much cheaper than common belief — `rand` is **not** "very expensive")
4. `and` / `or` / `xor` — 34,000 HCU
5. `select` — 55,000 HCU (constant across widths)
6. `eq` / `ne` — 83,000–120,000 HCU
7. `gt` / `ge` / `lt` / `le` — 116,000–152,000 HCU
8. `add` / `sub` — 133,000–162,000 HCU
9. `min` / `max` — 150,000–219,000 HCU
10. `shl` / `shr` / `rotl` / `rotr` — 34,000 (scalar) / ~209,000 (non-scalar)
11. `mul` — 365,000–596,000 HCU
12. `div` — 715,000 HCU (plaintext divisor only)
13. `rem` — 1,153,000 HCU (plaintext divisor only) — **most expensive**

**Headroom math:** with euint64 `add` at 162,000 HCU and a 20,000,000 HCU
per-tx cap, you have room for **~123 chained encrypted adds** in a single
transaction (or ~33 `mul`s, or ~17 `rem`s) before hitting the cap. Sequential
depth (5M) caps the *longest dependency chain* at ~30 chained adds; widen the
chain (parallelize independent ops) to reclaim depth.

**Key takeaways:**
- `rem` and `div` dominate cost — avoid encrypted modular arithmetic in hot paths.
- `select` is a flat 55,000 HCU regardless of type width — cheap to use.
- `rand` is **cheap** (~23k–24k HCU); the cost is dwarfed by any subsequent op.
- `xor` on `ebool` (2,000 HCU) is the cheapest non-trivial primitive in the system.
- Scalar variants are 5–30 % cheaper than non-scalar — prefer plaintext literals where possible.

## Optimization Strategies

### 1. Use the Smallest Type That Fits

Gas increases with encrypted type bit-width. Choose wisely:

| Use Case | Recommended Type | Avoid |
|----------|-----------------|-------|
| Boolean flags | `ebool` | `euint8` |
| Age, score, percentage | `euint8` | `euint64` |
| Year, small count | `euint16` | `euint64` |
| Timestamp, ID | `euint32` | `euint64` |
| Token amount, balance | `euint64` | `euint128` |
| Large precision | `euint128` | `euint256` |
| Hash, huge value | `euint256` | — (limited ops) |

```solidity
// WASTEFUL: euint64 for a vote (0 or 1)
euint64 vote = FHE.asEuint64(1);

// OPTIMIZED: ebool is much cheaper
ebool vote = FHE.asEbool(true);
```

### 2. Use Plaintext Operands When Possible

Operations with one plaintext operand (scalar) are cheaper than two encrypted operands:

```solidity
// MORE EXPENSIVE: both operands encrypted
euint64 fee = FHE.div(amount, FHE.asEuint64(100));  // Also: doesn't compile!

// CHEAPER: plaintext second operand
euint64 fee = FHE.div(amount, uint64(100));

// CHEAPER:
euint64 incremented = FHE.add(counter, uint64(1));
// vs MORE EXPENSIVE:
euint64 incremented = FHE.add(counter, FHE.asEuint64(1));
```

### 3. Use `FHE.allowTransient()` for Same-Transaction Access

`allowTransient` uses EIP-1153 transient storage (no SSTORE) — significantly cheaper than persistent `allow`:

```solidity
// EXPENSIVE: persistent storage write
FHE.allow(tempValue, address(otherContract));

// CHEAPER: transient storage, cleared after tx
FHE.allowTransient(tempValue, address(otherContract));
```

**Rule**: If the value is only needed within the current transaction (cross-contract calls), always use `allowTransient`.

### 4. Cache Encrypted Constants

```solidity
// WASTEFUL: creates new encrypted zero on each call
function transfer(address to, euint64 amount) external {
    euint64 transferValue = FHE.select(canTransfer, amount, FHE.asEuint64(0));
    // FHE.asEuint64(0) encrypts a new zero every time
}

// OPTIMIZED: store and reuse
euint64 private ENCRYPTED_ZERO;

constructor() {
    ENCRYPTED_ZERO = FHE.asEuint64(0);
    FHE.allowThis(ENCRYPTED_ZERO);
}

function transfer(address to, euint64 amount) external {
    euint64 transferValue = FHE.select(canTransfer, amount, ENCRYPTED_ZERO);
}
```

### 5. Use `FHE.min`/`FHE.max` Instead of Select Chains

```solidity
// VERBOSE + MORE GAS: comparison + select
ebool isSmaller = FHE.lt(a, b);
euint64 smaller = FHE.select(isSmaller, a, b);

// OPTIMIZED: single operation
euint64 smaller = FHE.min(a, b);
euint64 larger = FHE.max(a, b);
```

### 6. Batch Operations in Single Transactions

Each transaction has FHE overhead. Batch multiple operations to amortize:

```solidity
// EXPENSIVE: 3 separate transactions
await contract.deposit(enc1, proof1);
await contract.approve(spender, enc2, proof2);
await contract.transfer(to, enc3, proof3);

// CHEAPER: one transaction with batch function
function depositAndTransfer(
    externalEuint64 depositAmount,
    address to,
    externalEuint64 transferAmount,
    bytes calldata inputProof
) external {
    euint64 dep = FHE.fromExternal(depositAmount, inputProof);
    euint64 xfer = FHE.fromExternal(transferAmount, inputProof);
    // Both operations in one tx
}
```

### 7. Avoid Unnecessary Type Conversions

```solidity
// WASTEFUL: convert to euint64 and back
euint8 small = FHE.asEuint8(42);
euint64 big = FHE.asEuint64(small);   // upcast
euint8 back = FHE.asEuint8(big);       // downcast — wastes gas

// BETTER: stay in the original type
euint8 small = FHE.asEuint8(42);
// Use euint8 operations directly
```

### 8. Lazy Evaluation for Expensive Computations

```solidity
// EXPENSIVE: compute everything on write
function deposit(euint64 amount) external {
    balances[msg.sender] = FHE.add(balances[msg.sender], amount);
    totalDeposits = FHE.add(totalDeposits, amount);
    averageDeposit = FHE.div(totalDeposits, uint64(depositCount));
    // ^ Unnecessary if averageDeposit is rarely read
}

// CHEAPER: compute on demand
function deposit(euint64 amount) external {
    balances[msg.sender] = FHE.add(balances[msg.sender], amount);
    FHE.allowThis(balances[msg.sender]);
    FHE.allow(balances[msg.sender], msg.sender);
    depositCount++;
    // Don't compute average until someone asks for it
}
```

### 9. Bound Batch Sizes to Prevent Gas Griefing

```solidity
uint256 public constant MAX_BATCH_SIZE = 10;

function batchTransfer(
    address[] calldata recipients,
    euint64[] calldata amounts
) external {
    require(recipients.length <= MAX_BATCH_SIZE, "Batch too large");
    require(recipients.length == amounts.length, "Length mismatch");

    for (uint i = 0; i < recipients.length; i++) {
        _transfer(msg.sender, recipients[i], amounts[i]);
    }
}
```

### 10. Fees at Plaintext Boundaries

Charge fees at wrap/unwrap (where amounts are already plaintext), not on encrypted transfers:

```solidity
// EXPENSIVE: fee on every encrypted transfer
function _transfer(address from, address to, euint64 amount) internal {
    euint64 fee = FHE.div(amount, uint64(100));  // FHE operation every transfer
    euint64 net = FHE.sub(amount, fee);
}

// CHEAPER: fee only on wrap/unwrap
function wrap(uint64 amount) external {
    uint64 fee = amount / 100;                    // Plaintext math, cheap
    uint64 netAmount = amount - fee;
    _mint(msg.sender, netAmount);                 // Only net amount enters FHE domain
}
```

### 11. Encrypted Fee Collection Pattern

When collecting fees on encrypted operations (swap, transfer, etc.):

```solidity
// Fee as percentage with plaintext divisor:
euint64 fee = FHE.div(FHE.mul(amount, uint64(3)), uint64(1000));  // 0.3% fee
euint64 netAmount = FHE.sub(amount, fee);

// Accumulate fees (encrypted running total):
_accumulatedFees = FHE.add(_accumulatedFees, fee);
FHE.allowThis(_accumulatedFees);
FHE.allow(_accumulatedFees, owner());

// Owner withdraws fees later:
function withdrawFees() external onlyOwner {
    FHE.allowTransient(_accumulatedFees, address(token));
    token.confidentialTransfer(owner(), _accumulatedFees);
    _accumulatedFees = FHE.asEuint64(0);
    FHE.allowThis(_accumulatedFees);
}
```

**Tip**: For high-volume contracts, accumulate fees encrypted and withdraw periodically. This avoids per-transaction fee transfers (expensive). If you need the fee amount in plaintext (for accounting), use `makePubliclyDecryptable` on `_accumulatedFees` before withdrawal.

**All costs increase with type bit-width**: euint8 operations are cheaper than euint64, which are cheaper than euint128. The numeric tables above are the source of truth — the qualitative ordering on this page is a quick-reference summary only.
