# FHEVM Type System Reference

## Encrypted Types

All encrypted types are user-defined value types wrapping `bytes32` handles. The actual ciphertext is stored offchain in the coprocessor.

### Available Types

| Solidity Type | External Input Type | Bits | Use Cases |
|---------------|-------------------|------|-----------|
| `ebool` | `externalEbool` | 1 | Flags, conditions, voting choices |
| `euint8` | `externalEuint8` | 8 | Ages, scores, small enums, percentages |
| `euint16` | `externalEuint16` | 16 | Years, item counts, small amounts |
| `euint32` | `externalEuint32` | 32 | Timestamps, medium counts, IDs |
| `euint64` | `externalEuint64` | 64 | Token amounts, balances (MOST COMMON) |
| `euint128` | `externalEuint128` | 128 | Large amounts, high-precision values |
| `eaddress` | `externalEaddress` | 160 | Encrypted Ethereum addresses |
| `euint256` | `externalEuint256` | 256 | Hashes, very large values (LIMITED operations) |

### Import Pattern

```solidity
// Import only what you need
import {FHE, euint64, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";

// For contracts using the Zama config:
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
```

### Type NOT Available (Common Hallucinations)

These types do NOT exist in the current FHE.sol library:
- `ebytes` (no encrypted bytes type)
- `eint8`, `eint16`, etc. (no signed integer types)
- `euint4`, `euint512`, `euint1024`, `euint2048` (exist in enum but NOT exposed in library)

## Operations by Type

### Arithmetic Operations

All arithmetic wraps on overflow (no revert — prevents information leakage).

```solidity
FHE.add(euintX a, euintX b) returns (euintX)    // a + b (encrypted + encrypted)
FHE.add(euintX a, uintX b) returns (euintX)     // a + b (encrypted + plaintext)
FHE.add(uintX a, euintX b) returns (euintX)     // a + b (plaintext + encrypted)
FHE.sub(euintX a, euintX b) returns (euintX)     // a - b (wraps on underflow)
FHE.mul(euintX a, euintX b) returns (euintX)     // a * b (encrypted × encrypted)
FHE.mul(euintX a, uintX b) returns (euintX)      // a * b (encrypted × plaintext scalar)
FHE.mul(uintX a, euintX b) returns (euintX)      // a * b (plaintext scalar × encrypted)
FHE.div(euintX a, uintX b) returns (euintX)      // a / b — PLAINTEXT DIVISOR ONLY
FHE.rem(euintX a, uintX b) returns (euintX)      // a % b — PLAINTEXT DIVISOR ONLY
FHE.neg(euintX a) returns (euintX)                // -a (two's complement)
FHE.min(euintX a, euintX b) returns (euintX)      // encrypted minimum
FHE.max(euintX a, euintX b) returns (euintX)      // encrypted maximum
```

**Supported types for arithmetic**: `euint8`, `euint16`, `euint32`, `euint64`, `euint128`
**NOT supported**: `euint256` (only `neg`), `ebool`, `eaddress`

**Operator overloads** (Solidity operator syntax):
```solidity
euint64 sum = a + b;    // equivalent to FHE.add(a, b)
euint64 diff = a - b;   // equivalent to FHE.sub(a, b)
euint64 prod = a * b;   // equivalent to FHE.mul(a, b)
```

### Comparison Operations (all return `ebool`)

```solidity
FHE.eq(euintX a, euintX b) returns (ebool)   // a == b
FHE.ne(euintX a, euintX b) returns (ebool)   // a != b
FHE.ge(euintX a, euintX b) returns (ebool)   // a >= b
FHE.gt(euintX a, euintX b) returns (ebool)   // a > b
FHE.le(euintX a, euintX b) returns (ebool)   // a <= b
FHE.lt(euintX a, euintX b) returns (ebool)   // a < b
```

**Ordering comparisons** (ge, gt, le, lt): `euint8` through `euint128` only.
**Equality only** (eq, ne): ALL types including `euint256` and `eaddress`.

Comparisons also support scalar overloads:
```solidity
ebool result = FHE.gt(encryptedAge, uint8(18));  // encrypted > plaintext
```

### Bitwise Operations

```solidity
FHE.and(euintX a, euintX b) returns (euintX)   // Also: FHE.and(ebool, ebool)
FHE.or(euintX a, euintX b) returns (euintX)     // Also: FHE.or(ebool, ebool)
FHE.xor(euintX a, euintX b) returns (euintX)    // Also: FHE.xor(ebool, ebool)
FHE.not(euintX a) returns (euintX)               // Also: FHE.not(ebool)
FHE.shl(euintX a, euint8 b) returns (euintX)    // Shift left (amount always euint8/uint8)
FHE.shr(euintX a, euint8 b) returns (euintX)    // Shift right
FHE.rotl(euintX a, euint8 b) returns (euintX)   // Rotate left
FHE.rotr(euintX a, euint8 b) returns (euintX)   // Rotate right
```

**Shift amount is always modulo the bit-width** of the first operand (e.g., shifting euint32 by 33 = shifting by 1).

### Ternary Select (The ONLY Way to Branch on Encrypted Values)

```solidity
FHE.select(ebool control, euintX a, euintX b) returns (euintX)
FHE.select(ebool control, ebool a, ebool b) returns (ebool)
FHE.select(ebool control, eaddress a, eaddress b) returns (eaddress)
```

This replaces all `if/else/require/assert` logic for encrypted conditions:
```solidity
// Instead of: if (balance >= amount) { transfer amount } else { transfer 0 }
euint64 actual = FHE.select(FHE.ge(balance, amount), amount, FHE.asEuint64(0));
```

## Type Casting

### Plaintext to Encrypted (Trivial Encryption)

```solidity
FHE.asEbool(bool value) returns (ebool)
FHE.asEuint8(uint8 value) returns (euint8)
FHE.asEuint16(uint16 value) returns (euint16)
FHE.asEuint32(uint32 value) returns (euint32)
FHE.asEuint64(uint64 value) returns (euint64)
FHE.asEuint128(uint128 value) returns (euint128)
FHE.asEuint256(uint256 value) returns (euint256)
FHE.asEaddress(address value) returns (eaddress)
```

**Warning**: Trivially encrypted values are NOT truly confidential — validators can see the plaintext in the transaction calldata. Use only for contract-side constants and comparisons.

### Between Encrypted Types (Upcasting / Downcasting)

```solidity
// Upcast (safe — no data loss)
FHE.asEuint64(euint8 value) returns (euint64)
FHE.asEuint128(euint32 value) returns (euint128)

// Downcast (may truncate — use with care)
FHE.asEuint8(euint64 value) returns (euint8)
FHE.asEuint32(euint128 value) returns (euint32)

// Bool conversions
FHE.asEuint8(ebool b) returns (euint8)    // true → 1, false → 0
FHE.asEbool(euint8 value) returns (ebool)  // nonzero → true, zero → false
```

### Cross-Type Operations (Automatic Upcasting)

When performing operations between different encrypted widths, the smaller type is automatically upcast:

```solidity
euint64 result = FHE.add(euint8_val, euint64_val);  // euint8 upcast to euint64
euint128 result = FHE.mul(euint32_val, euint128_val); // euint32 upcast to euint128
```

## Storing Encrypted Types

Encrypted types can be stored in **mappings**, **state variables**, and **structs**:

```solidity
// All of these work:
euint64 private _totalSupply;                          // State variable
mapping(address => euint64) private _balances;          // Mapping
mapping(address => mapping(address => euint64)) private _allowances;  // Nested mapping

struct Position {
    euint64 collateral;   // ✅ Works in structs
    euint64 debt;         // ✅ euint64 is a bytes32 handle under the hood
    uint256 lastUpdate;   // Plaintext fields can coexist
}
mapping(address => Position) private _positions;
```

**Note**: Encrypted types in struct fields cannot be returned through interfaces (not ABI-safe). Use separate getter functions instead.

## Initialization Check

```solidity
FHE.isInitialized(euint64 v) returns (bool)  // true if handle != bytes32(0)
```

Use this to check if a storage variable has been assigned:

```solidity
if (!FHE.isInitialized(balances[user])) {
    balances[user] = FHE.asEuint64(0);
    FHE.allowThis(balances[user]);
    FHE.allow(balances[user], user);
}
```

**Behavior of uninitialized encrypted values**:
- Uninitialized `euint64` storage = `bytes32(0)` (zero handle)
- `FHE.isInitialized(zeroHandle)` returns `false`
- `FHE.add(zeroHandle, amount)` works in mock mode (treats zero handle as encrypted 0)
- `FHE.isAllowed(zeroHandle, account)` returns `false` (no ACL on zero handle)
- **Best practice**: Always initialize encrypted storage before first use, or check `isInitialized` first

## Handle Conversion

`FHE.toBytes32()` works on ALL encrypted types — it unwraps the handle to raw `bytes32`:

```solidity
FHE.toBytes32(ebool value) returns (bytes32)
FHE.toBytes32(euint8 value) returns (bytes32)
FHE.toBytes32(euint16 value) returns (bytes32)
FHE.toBytes32(euint32 value) returns (bytes32)
FHE.toBytes32(euint64 value) returns (bytes32)
FHE.toBytes32(euint128 value) returns (bytes32)
FHE.toBytes32(euint256 value) returns (bytes32)
FHE.toBytes32(eaddress value) returns (bytes32)
```

Used for building handles arrays for `checkSignatures`:
```solidity
bytes32[] memory handles = new bytes32[](2);
handles[0] = FHE.toBytes32(myEncryptedAmount);    // euint64
handles[1] = FHE.toBytes32(myEncryptedAddress);   // eaddress — also works!
```

## Random Number Generation

```solidity
FHE.randEbool() returns (ebool)
FHE.randEuint8() returns (euint8)
FHE.randEuint8(uint8 upperBound) returns (euint8)     // [0, upperBound)
FHE.randEuint16() returns (euint16)
FHE.randEuint16(uint16 upperBound) returns (euint16)
FHE.randEuint32() returns (euint32)
FHE.randEuint32(uint32 upperBound) returns (euint32)
FHE.randEuint64() returns (euint64)
FHE.randEuint64(uint64 upperBound) returns (euint64)
FHE.randEuint128() returns (euint128)
FHE.randEuint128(uint128 upperBound) returns (euint128)
FHE.randEuint256() returns (euint256)
FHE.randEuint256(uint256 upperBound) returns (euint256)
```

**Critical rules:**
1. `upperBound` MUST be a power of 2 (2, 4, 8, 16, 32, 64, 128, 256...)
2. Random generation MUST happen in a transaction (not view/pure) — it mutates on-chain PRNG state
3. Always call `FHE.allowThis()` and `FHE.allow()` on the result
