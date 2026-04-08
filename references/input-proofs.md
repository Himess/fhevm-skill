# FHEVM Input Proofs

## What Are Input Proofs?

When a user wants to send an encrypted value to a smart contract, they encrypt the value client-side and generate a **ZK proof** that the ciphertext is well-formed. The contract validates this proof before accepting the encrypted input.

This prevents malicious users from submitting garbage data as "encrypted values."

## Contract-Side: Accepting Encrypted Inputs

### Function Signature Pattern

Use typed `externalEuintXX` parameters paired with a single `bytes calldata inputProof`:

```solidity
import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";

function deposit(
    externalEuint64 encryptedAmount,
    bytes calldata inputProof
) external {
    euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
    // amount is now a validated encrypted handle — safe to use
    balances[msg.sender] = FHE.add(balances[msg.sender], amount);
    FHE.allowThis(balances[msg.sender]);
    FHE.allow(balances[msg.sender], msg.sender);
}
```

### Available External Types

```solidity
externalEbool      → FHE.fromExternal(externalEbool, proof)    returns ebool
externalEuint8     → FHE.fromExternal(externalEuint8, proof)   returns euint8
externalEuint16    → FHE.fromExternal(externalEuint16, proof)  returns euint16
externalEuint32    → FHE.fromExternal(externalEuint32, proof)  returns euint32
externalEuint64    → FHE.fromExternal(externalEuint64, proof)  returns euint64
externalEuint128   → FHE.fromExternal(externalEuint128, proof) returns euint128
externalEaddress   → FHE.fromExternal(externalEaddress, proof) returns eaddress
externalEuint256   → FHE.fromExternal(externalEuint256, proof) returns euint256
```

### Multiple Encrypted Inputs (Single Proof)

Multiple encrypted values can share one proof:

```solidity
function placeBid(
    externalEuint64 encryptedPrice,
    externalEuint32 encryptedQuantity,
    bytes calldata inputProof         // Single proof covers both inputs
) external {
    euint64 price = FHE.fromExternal(encryptedPrice, inputProof);
    euint32 quantity = FHE.fromExternal(encryptedQuantity, inputProof);
    // Both validated from the same proof
}
```

### Accepting Already-Verified Handles

For contract-to-contract calls where the handle is already verified:

```solidity
function processPayment(euint64 amount) external {
    // Verify the caller has ACL permission for this handle
    require(FHE.isSenderAllowed(amount), "Sender not allowed");
    // Proceed — no fromExternal needed
}
```

**When `inputProof` is empty**: `FHE.fromExternal` treats the handle as already verified. This is useful for smart contract accounts (Account Abstraction).

### Who Gets ACL After `FHE.fromExternal()`?

**The contract that calls `FHE.fromExternal()` gains ACL access to the resulting handle.** This is critical for cross-contract design:

```
User calls Escrow.deposit(externalEuint64 enc, bytes proof)
  └─ Escrow calls FHE.fromExternal(enc, proof) → Escrow gets ACL ✅
  └─ Escrow can now use the handle (allowTransient, store, etc.)

User calls Escrow.deposit(euint64 handle)
  └─ Escrow does NOT have ACL for this handle ❌
  └─ FHE.allowTransient will fail — Escrow can't grant what it doesn't have
```

### When to Use `externalEuint64` vs `euint64` as Function Parameters

```
Is the USER calling your contract directly?
  └─ Yes → Use externalEuint64 + bytes proof
       FHE.fromExternal() grants YOUR contract ACL

Is ANOTHER CONTRACT calling yours (cross-contract)?
  └─ Yes → Use euint64 + require(FHE.isSenderAllowed(amount))
       The calling contract must have already granted you access
       via FHE.allowTransient(amount, yourAddress)
```

### Return Value ACL of ERC-7984 Functions

When you call `confidentialTransfer` or `confidentialTransferFrom` on an ERC-7984 token, the returned `euint64` (actual transferred amount) has ACL granted to:
- The `msg.sender` (the contract/user that initiated the call)
- The `to` address (the recipient)
- The token contract itself (for internal bookkeeping)

**Complete cross-contract auction/escrow flow:**
```solidity
function placeBid(externalEuint64 encBid, bytes calldata proof) external {
    euint64 bidAmount = FHE.fromExternal(encBid, proof);     // Auction gets ACL
    FHE.allowTransient(bidAmount, address(paymentToken));     // Token can read handle
    
    // Pull tokens: token checks isOperator(msg.sender=auction) — user must have setOperator first
    euint64 transferred = paymentToken.confidentialTransferFrom(
        msg.sender, address(this), bidAmount
    );
    // `transferred` has ACL for: this contract (msg.sender) + address(this) (to) + token
    
    // Store the bid — transferred handle is already accessible to this contract
    _bids[msg.sender] = transferred;
    FHE.allowThis(_bids[msg.sender]);
    FHE.allow(_bids[msg.sender], msg.sender);
}
```

### Batch Encrypted Operations (Multiple Users/Items)

For operations involving multiple encrypted values in a loop (e.g., batch voter registration, batch payroll):

```solidity
// Batch registration with individual encrypted inputs
function registerVoters(
    address[] calldata voters,
    externalEuint64[] calldata encWeights,
    bytes calldata inputProof           // Single proof for ALL inputs
) external onlyOwner {
    require(voters.length == encWeights.length, "Length mismatch");
    require(voters.length <= 10, "Batch too large");  // Bound FHE ops per tx

    for (uint i = 0; i < voters.length; i++) {
        euint64 weight = FHE.fromExternal(encWeights[i], inputProof);
        _weights[voters[i]] = weight;
        FHE.allowThis(_weights[voters[i]]);
        FHE.allow(_weights[voters[i]], voters[i]);
    }
}
```

**Gas limit**: Each FHE operation in a loop costs gas. Rule of thumb: max **10-15 FHE operations per transaction** for euint64. Larger batches should be split across multiple transactions.

## Client-Side: Creating Encrypted Inputs

### Using the Relayer SDK

```typescript
import { createInstance, SepoliaConfig } from '@zama-fhe/relayer-sdk';

const fhevm = await createInstance({
    ...SepoliaConfig,
    network: provider,  // ethers.js provider or window.ethereum
});

// Create encrypted input bound to contract + user
const input = fhevm.createEncryptedInput(contractAddress, userAddress);

// Add values to encrypt
input.addBool(true);              // ebool
input.add8(42);                   // euint8
input.add16(1000);                // euint16
input.add32(Date.now());          // euint32
input.add64(BigInt("1000000"));   // euint64
input.add128(BigInt("999999"));   // euint128
input.addAddress("0x1234...");    // eaddress
input.add256(BigInt("12345"));    // euint256

// Encrypt all values and generate proof
const encrypted = await input.encrypt();

// encrypted.handles[0] — first handle (matches order of add calls)
// encrypted.handles[1] — second handle
// encrypted.inputProof  — single proof for ALL handles
```

### Sending to Contract

```typescript
// Single input
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(BigInt(amount))
    .encrypt();

const tx = await contract.deposit(
    encrypted.handles[0],    // externalEuint64
    encrypted.inputProof     // bytes
);
await tx.wait();
```

### Multiple Inputs

```typescript
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(BigInt(price))
    .add32(quantity)
    .encrypt();

const tx = await contract.placeBid(
    encrypted.handles[0],    // externalEuint64 (price)
    encrypted.handles[1],    // externalEuint32 (quantity)
    encrypted.inputProof     // Single proof for both
);
```

### Encryption with Timeout Protection

```typescript
const input = fhevm.createEncryptedInput(contractAddress, signer.address);
input.add64(BigInt(amount));

let encrypted;
const timeoutId = setTimeout(() => {}, 30000);
try {
    encrypted = await Promise.race([
        input.encrypt(),
        new Promise<never>((_, reject) => {
            setTimeout(() => reject(new Error("FHE encryption timed out")), 30000);
        }),
    ]);
} finally {
    clearTimeout(timeoutId);
}
```

## Critical Rules

### 1. Input proofs are bound to `msg.sender`

The proof verifies that the encrypted input was created by the transaction sender. If you forward an encrypted input to another contract, the proof validation will fail because `msg.sender` changes.

```solidity
// DOES NOT WORK: proof is bound to the original caller, not ContractB
contract ContractA {
    function forward(externalEuint64 enc, bytes calldata proof) external {
        // msg.sender is the user here
        ContractB(target).process(enc, proof);
        // In ContractB.process(), msg.sender is ContractA, not the user
        // → proof validation fails!
    }
}
```

**Solution**: Use a 2-transaction flow:
1. User sends encrypted input directly to the token contract
2. User (or another contract) triggers the business logic separately

### 2. Handle order matches `add` call order

```typescript
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(price)      // → encrypted.handles[0]
    .add32(quantity)   // → encrypted.handles[1]
    .addBool(isActive) // → encrypted.handles[2]
    .encrypt();
```

### 3. One proof per `createEncryptedInput` call

Each `createEncryptedInput` produces one proof. If you need inputs for different contracts, create separate encrypted inputs:

```typescript
// For contract A
const encA = await fhevm
    .createEncryptedInput(contractA, signer.address)
    .add64(amountA)
    .encrypt();

// For contract B (separate proof)
const encB = await fhevm
    .createEncryptedInput(contractB, signer.address)
    .add64(amountB)
    .encrypt();
```

### 4. Encryption is non-deterministic

Encrypting the same plaintext twice produces different ciphertexts. This is correct behavior — deterministic encryption would leak information.

```typescript
const enc1 = await fhevm.createEncryptedInput(addr, user).add64(100n).encrypt();
const enc2 = await fhevm.createEncryptedInput(addr, user).add64(100n).encrypt();
// enc1.handles[0] !== enc2.handles[0]  — EXPECTED
```
