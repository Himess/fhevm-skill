# FHEVM Decryption Guide

## Overview

FHEVM supports three decryption models:

| Model | Who Sees Plaintext | Use Case |
|-------|-------------------|----------|
| **User Decryption** | Only the data owner | Private balances, personal data |
| **Public Decryption** | Everyone | Auction results, vote tallies, unwrap amounts |
| **Delegated Decryption** | A delegate on behalf of owner | Backend services, custodial setups |

> **Forward-looking note (fhevm v0.12, April 2026).** The protocol now supports
> **context-aware decryption** via an `extraData` field bound to each ciphertext
> for replay protection across different consumers. The new
> `@zama-fhe/sdk@3.x` already speaks this protocol. The legacy
> `@zama-fhe/relayer-sdk@0.4.x` shown below works against v0.11 contracts. If
> you upgrade contracts to v0.12, also upgrade to `relayer-sdk@0.5.0-alpha` or
> migrate the frontend to `@zama-fhe/sdk@3.x`. Symptom of mismatch:
> `extraDataMismatch` errors at decrypt time.

## User Decryption (EIP-712 Flow)

The user proves ownership via an EIP-712 signature, and the Relayer/KMS re-encrypts the value with the user's ephemeral public key.

### Full Frontend Flow

```typescript
// IMPORTANT: the package has NO root export. Always import from /web (browser)
// or /node (Node.js / Hardhat scripts). The plain `@zama-fhe/relayer-sdk`
// specifier is not in the package.json `exports` map and will fail to resolve.
import { createInstance, SepoliaConfig } from '@zama-fhe/relayer-sdk/web';
import { ethers } from 'ethers';

// 1. Initialize the SDK
const fhevm = await createInstance({
    ...SepoliaConfig,
    network: provider,           // window.ethereum (browser) or RPC URL string (node)
});

// 2. Get the encrypted handle from the contract
const encryptedBalance = (await contract.balanceOf(userAddress)) as bigint;

// 3. Generate an ephemeral keypair
const keypair = fhevm.generateKeypair();

// 4. Create EIP-712 typed data for signing
const contractAddresses = [contractAddress];
const startTimestamp = Math.floor(Date.now() / 1000);  // NUMBER, not string
const durationDays = 10;  // NUMBER, not string — how long the decryption permission lasts

const eip712 = fhevm.createEIP712(
    keypair.publicKey,
    contractAddresses,
    startTimestamp,
    durationDays,
);

// 5. User signs with their wallet (MetaMask popup)
//    `eip712.types.UserDecryptRequestVerification` is `readonly` in 0.4.1.
//    ethers v6 `signTypedData` wants a mutable `TypedDataField[]` — spread:
const signature = await signer.signTypedData(
    eip712.domain,
    { UserDecryptRequestVerification: [...eip712.types.UserDecryptRequestVerification] },
    eip712.message,
);

// 6. Request decryption through the Relayer
const result = await fhevm.userDecrypt(
    [{ handle: encryptedBalance, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.slice(2),  // strip the leading "0x" before sending to the relayer
    contractAddresses,
    signer.address,
    startTimestamp,
    durationDays,
);

// 7. Read the decrypted value
// `result` (UserDecryptResults) is keyed by `0x${string}`. Convert + cast:
const hexHandle = ethers.toBeHex(encryptedBalance, 32) as `0x${string}`;
const clearBalance = result[hexHandle];  // bigint
console.log("Balance:", clearBalance.toString());
```

### Requirements for User Decryption

1. The user must have ACL permission (`FHE.allow(value, user)` was called in the contract)
2. Total bit length of all handles in one request must not exceed **2048 bits**
3. The EIP-712 signature binds to specific contract addresses and a time window

### Decryption in Tests (Hardhat Mock)

```typescript
import { fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";

// For euint64:
const clearValue = await fhevm.userDecryptEuint(
    FhevmType.euint64,
    encryptedHandle,
    contractAddress,
    signer,
);

// For ebool:
const clearBool = await fhevm.userDecryptEbool(
    encryptedHandle,
    contractAddress,
    signer,
);

// For eaddress:
const clearAddr = await fhevm.userDecryptEaddress(
    encryptedHandle,
    contractAddress,
    signer,
);
```

**Available FhevmType values**: `euint8`, `euint16`, `euint32`, `euint64`, `euint128`, `euint256`

## Public Decryption

When a value needs to be revealed publicly (e.g., auction winner, vote tally), use the 3-step public decryption flow.

### Step 1: Mark as Publicly Decryptable (In Contract)

```solidity
function revealResult() external onlyOwner {
    require(votingEnded, "Voting still active");
    FHE.makePubliclyDecryptable(yesVotes);
    FHE.makePubliclyDecryptable(noVotes);
    emit DecryptionRequested(
        FHE.toBytes32(yesVotes),
        FHE.toBytes32(noVotes)
    );
}
```

### Step 2: Request Decryption Off-Chain (Frontend/Backend)

```typescript
const handles = [
    FHE.toBytes32(yesVotesHandle),
    FHE.toBytes32(noVotesHandle),
];

const result = await fhevm.publicDecrypt(handles);
// result.clearValues[handle] → decrypted value
// result.abiEncodedClearValues → for on-chain verification
// result.decryptionProof → KMS signatures
```

### Step 3: Verify On-Chain (Callback)

```solidity
function fulfillDecryption(
    bytes calldata abiEncodedCleartexts,
    bytes calldata decryptionProof
) external {
    // Build the handles array (must match the order used in publicDecrypt)
    bytes32[] memory handlesList = new bytes32[](2);
    handlesList[0] = FHE.toBytes32(yesVotes);
    handlesList[1] = FHE.toBytes32(noVotes);

    // Verify the KMS proof — reverts if invalid
    FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

    // SDK encodes ALL values as uint256 — decode and cast down
    (uint256 yesRaw, uint256 noRaw) = abi.decode(
        abiEncodedCleartexts,
        (uint256, uint256)
    );
    uint64 yesCount = uint64(yesRaw);
    uint64 noCount = uint64(noRaw);

    // Use the decrypted values
    winner = yesCount > noCount ? "Yes" : "No";
    emit ResultRevealed(yesCount, noCount);
}
```

### Single-Handle Variant (one value to reveal)

For contracts that publish a single encrypted total (tip jar, lottery winner, treasury balance):

```solidity
function revealTotal(
    bytes calldata abiEncodedCleartexts,
    bytes calldata decryptionProof
) external {
    bytes32[] memory handlesList = new bytes32[](1);
    handlesList[0] = FHE.toBytes32(_encryptedTotal);

    FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

    // Single value: still decode as uint256, then cast to your width.
    uint256 raw = abi.decode(abiEncodedCleartexts, (uint256));
    revealedTotal = uint64(raw);
}
```

For an `eaddress` reveal: `address(uint160(uint256RawValue))`.

### Decoding N Cleartexts When N Is Dynamic

`abi.decode` requires a static tuple. For multi-option voting / multi-bucket
accumulators where N is set at construction time (e.g. 3..5 choices), use one of
two patterns:

**Option A — Fixed maximum, ignore extras (simplest):**

```solidity
// Constructor enforces N <= 5:
constructor(string[] memory choices) { require(choices.length <= 5, "max 5"); ... }

// Decode as if always 5; trust checkSignatures already validated arity.
(uint256 v0, uint256 v1, uint256 v2, uint256 v3, uint256 v4) =
    abi.decode(abiEncodedCleartexts, (uint256, uint256, uint256, uint256, uint256));
uint256[5] memory raws = [v0, v1, v2, v3, v4];
for (uint256 i = 0; i < numChoices; i++) {
    revealedTallies[i] = uint64(raws[i]);
}
```

**Option B — Calldata loop (truly dynamic):**

```solidity
// Cleartexts are packed back-to-back, 32 bytes each, no length prefix.
// Read the first numChoices words.
require(abiEncodedCleartexts.length == numChoices * 32, "arity mismatch");
for (uint256 i = 0; i < numChoices; i++) {
    uint256 raw;
    assembly {
        // calldatacopy from abiEncodedCleartexts.offset + i*32
        // Position: abiEncodedCleartexts is bytes calldata, raw bytes start
        // immediately after its length-prefixed header in calldata.
        let off := add(abiEncodedCleartexts.offset, mul(i, 32))
        raw := calldataload(off)
    }
    revealedTallies[i] = uint64(raw);
}
```

Option A is recommended for contracts with a small fixed-max N — it's safer and
type-checked. Option B is only worth it if your N is large or fully unbounded.

### Verification Functions

```solidity
// Reverts if proof is invalid. Emits PublicDecryptionVerified event.
FHE.checkSignatures(
    bytes32[] memory handlesList,
    bytes memory abiEncodedCleartexts,
    bytes memory decryptionProof
)

// View variant — returns bool, does NOT emit events.
// Use checkSignatures when possible (emits events for better tracking).
FHE.isPublicDecryptionResultValid(
    bytes32[] memory handlesList,
    bytes memory abiEncodedCleartexts,
    bytes memory decryptionProof
) returns (bool)
```

## Delegated Decryption

For backend services or custodial setups where a different address decrypts on
behalf of the data owner.

### Three Distinct Flows — Pick One Before You Start Coding

The skill (and the FHEVM docs in general) sometimes blur three patterns under
one heading. They are NOT interchangeable. Read this disambiguation first:

| Flow | Who is the delegator? | On-chain `FHE.delegateUserDecryption` call needed? | Where the EIP-712 is signed |
|---|---|---|---|
| **(1) Off-chain only (EOA)** | An EOA (the data owner) | **No** — relayer accepts the EIP-712 alone | EOA-side, in the user's wallet |
| **(2) On-chain smart-contract custody** | A custodial contract that holds rights to data living on a *different* contract | **Yes** — the custodian contract calls `FHE.delegateUserDecryption(delegate, dataContract, exp)` | Optional EIP-712 from the delegate; on-chain delegation alone may suffice depending on relayer policy |
| **(3) Hybrid** | Both an on-chain delegation *and* an off-chain EIP-712 — used when the protocol wants on-chain attestation + KMS authentication | **Yes** | Yes |

**Most user-flows are (1).** A user lets a backend decrypt their own data — the
EIP-712 the user signs is enough; the relayer enforces the delegation by
checking the signature. **No on-chain call is required.**

### ⚠ Critical constraint for flow (2)

`FHE.delegateUserDecryption` reverts with `SenderCannotBeContractAddress()` if
called with `contractAddress == address(this)` of the calling contract. **A
contract cannot delegate decryption of its OWN handles via the on-chain
function.** This applies even when the contract's caller is the EOA owner of
the data — the ACL check looks at `msg.sender == contractAddress`, not at the
EOA.

Two valid resolutions:

1. **Use flow (1) instead** — let the EOA sign the EIP-712 directly via
   `createDelegatedUserDecryptEIP712`, send it to the relayer, no on-chain
   call needed. This is what 90% of "delegate my balance to a backend"
   use cases actually want.
2. **Route flow (2) through a separate helper contract** — deploy a
   `DelegationHelper` whose `address(this)` differs from the contract that
   holds the data. The helper calls `FHE.delegateUserDecryption(delegate,
   dataContract, exp)` with `dataContract != address(this)`, which is allowed.
   This is only useful when the data-holding contract has no EOA owner (e.g.
   protocol-owned funds).

### On-Chain: Custody Contract Delegates (Flow 2 only)

```solidity
// Inside a DEDICATED helper contract (not the data-holding contract):
function delegateForCustomer(
    address delegate,
    address dataContract,   // ← MUST be a different contract from this one
    uint256 expirationTs
) external onlyOwner {
    FHE.delegateUserDecryption(delegate, dataContract, expirationTs);
}
```

### Off-Chain: Delegate Requests Decryption

```typescript
// Delegate creates EIP-712 for delegated decryption
// NOTE: delegatorAddress is the 3rd parameter (the original data owner)
const eip712 = fhevm.createDelegatedUserDecryptEIP712(
    keypair.publicKey,
    contractAddresses,
    delegatorAddress,      // The original data owner whose data is being decrypted
    startTimestamp,
    durationDays,
);

// Delegate signs
//   Spread the readonly tuple — same fix as user-decrypt above.
const signature = await delegateSigner.signTypedData(
    eip712.domain,
    { DelegatedUserDecryptRequestVerification: [...eip712.types.DelegatedUserDecryptRequestVerification] },
    eip712.message,
);

// Request delegated decryption
const result = await fhevm.delegatedUserDecrypt(
    [{ handle: encryptedHandle, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.slice(2),  // strip the leading "0x" before sending to the relayer
    contractAddresses,
    delegatorAddress,    // The original data owner
    delegateSigner.address,
    startTimestamp,
    durationDays,
);
```

## Async Unwrap Pattern (ERC-7984 → ERC-20)

A common pattern for converting confidential tokens back to standard tokens:

### Contract Side

```solidity
// Map request ID (bytes32) to recipient — NOT euint64 as key (user-defined types can't be mapping keys)
mapping(bytes32 requestId => address recipient) private _unwrapRecipients;
mapping(bytes32 requestId => euint64 burntHandle) private _unwrapHandles;

function _unwrap(address from, address to, euint64 amount) internal returns (bytes32 requestId) {
    // 1. Burn the confidential tokens
    euint64 burntAmount = _burn(from, amount);

    // 2. Request public decryption of the burnt amount
    FHE.makePubliclyDecryptable(burntAmount);

    // 3. Generate a request ID and store recipient + handle
    requestId = keccak256(abi.encode(from, to, FHE.toBytes32(burntAmount), block.number));
    _unwrapRecipients[requestId] = to;
    _unwrapHandles[requestId] = burntAmount;
    emit UnwrapRequested(requestId, to, FHE.toBytes32(burntAmount));
}

function finalizeUnwrap(
    bytes32 unwrapRequestId,
    uint64 unwrapAmountCleartext,
    bytes calldata decryptionProof
) external {
    address to = _unwrapRecipients[unwrapRequestId];
    require(to != address(0), "No pending unwrap");
    euint64 burntAmount = _unwrapHandles[unwrapRequestId];
    delete _unwrapRecipients[unwrapRequestId];
    delete _unwrapHandles[unwrapRequestId];

    // Verify the decryption proof
    bytes32[] memory handles = new bytes32[](1);
    handles[0] = FHE.toBytes32(burntAmount);
    FHE.checkSignatures(handles, abi.encode(unwrapAmountCleartext), decryptionProof);

    // Transfer the plaintext amount
    IERC20(underlying).safeTransfer(to, uint256(unwrapAmountCleartext));
}
```

## Decryption Limits

- **2048-bit limit**: A single decryption request cannot exceed 2048 bits total across all handles.
  - Max 32 × euint64 handles per request
  - Max 16 × euint128 handles per request
  - Max 256 × euint8 handles per request
  - Mix and match as long as total ≤ 2048 bits

## Common Decryption Mistakes

### 1. Forgetting `FHE.allow` before user decryption

```solidity
// WRONG: user can't decrypt
balances[user] = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]);
// Missing: FHE.allow(balances[user], user);
```

### 2. Using the old Gateway pattern

```solidity
// WRONG: deprecated in v0.9+
Gateway.requestDecryption(cts, this.callback.selector, 0, block.timestamp + 100, false);

// CORRECT: self-relaying pattern
FHE.makePubliclyDecryptable(value);
// Then off-chain: publicDecrypt → checkSignatures
```

### 3. Not emitting handles for off-chain tracking

```solidity
// BETTER: emit handles so frontend knows what to decrypt
function revealResult() external {
    FHE.makePubliclyDecryptable(result);
    emit DecryptionRequested(FHE.toBytes32(result));  // Frontend listens for this
}
```
