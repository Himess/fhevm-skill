# FHEVM Gas Optimization Guide

## Key Principle: FHE Gas is Amount-Independent

Unlike regular EVM operations, FHE gas costs are **constant** regardless of the encrypted value. `FHE.add(1, 2)` costs the same as `FHE.add(MAX_UINT64, MAX_UINT64)`. This is by design — variable gas would leak information.

## FHE Operation Costs (HCU — Homomorphic Computation Units)

Each FHE operation consumes gas on the host chain AND computation on the coprocessor. Costs scale with type width:

| Operation | euint8 | euint16 | euint32 | euint64 | euint128 | euint256 |
|-----------|--------|---------|---------|---------|----------|----------|
| `add/sub` | Low | Low | Low | Medium | High | N/A |
| `mul` | Medium | Medium | High | High | Very High | N/A |
| `div/rem` | High | High | High | Very High | Very High | N/A |
| `eq/ne` | Low | Low | Low | Low | Medium | Medium |
| `gt/lt/ge/le` | Low | Low | Medium | Medium | High | N/A |
| `select` | Medium | Medium | Medium | Medium | High | High |
| `min/max` | Medium | Medium | Medium | Medium | High | N/A |
| `and/or/xor/not` | Low | Low | Low | Low | Low | Low |
| `shl/shr` | Low | Low | Medium | Medium | Medium | Medium |
| `rand` | High | High | High | Very High | Very High | Very High |

**Key takeaway**: `rand` and `div` are the most expensive. `add`/`sub` and bitwise are cheapest. Always use the smallest type that fits your data.

**Batch evaluation tip**: If a function does many FHE operations, consider splitting across multiple transactions to avoid gas limits. Rule of thumb: max ~10-15 FHE operations per transaction for euint64.

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

## Gas Cost Relative Comparison

Operations from cheapest to most expensive (approximate):

1. `FHE.isInitialized()` — pure function, no gas
2. `FHE.asEuintX(plaintext)` — trivial encryption
3. `FHE.not()`, `FHE.neg()` — unary operations
4. `FHE.and()`, `FHE.or()`, `FHE.xor()` — bitwise
5. `FHE.add()`, `FHE.sub()` — arithmetic (scalar operand cheaper)
6. `FHE.eq()`, `FHE.ne()` — equality comparison
7. `FHE.mul()` — multiplication
8. `FHE.ge()`, `FHE.gt()`, `FHE.le()`, `FHE.lt()` — ordering comparison
9. `FHE.min()`, `FHE.max()` — combined comparison + select
10. `FHE.select()` — ternary
11. `FHE.div()`, `FHE.rem()` — division (most expensive arithmetic)
12. `FHE.shl()`, `FHE.shr()` — shifts
13. `FHE.randEuintX()` — random generation (most expensive overall)

**All costs increase with type bit-width**: euint8 operations are cheaper than euint64, which are cheaper than euint128.
