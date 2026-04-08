# FHEVM Decryption Guide

## Overview

FHEVM supports three decryption models:

| Model | Who Sees Plaintext | Use Case |
|-------|-------------------|----------|
| **User Decryption** | Only the data owner | Private balances, personal data |
| **Public Decryption** | Everyone | Auction results, vote tallies, unwrap amounts |
| **Delegated Decryption** | A delegate on behalf of owner | Backend services, custodial setups |

## User Decryption (EIP-712 Flow)

The user proves ownership via an EIP-712 signature, and the Relayer/KMS re-encrypts the value with the user's ephemeral public key.

### Full Frontend Flow

```typescript
import { createInstance, SepoliaConfig } from '@zama-fhe/relayer-sdk';

// 1. Initialize the SDK
const fhevm = await createInstance({
    ...SepoliaConfig,
    network: provider,
});

// 2. Get the encrypted handle from the contract
const encryptedBalance = await contract.balanceOf(userAddress);

// 3. Generate an ephemeral keypair
const keypair = fhevm.generateKeypair();

// 4. Create EIP-712 typed data for signing
const contractAddresses = [contractAddress];
const startTimestamp = Math.floor(Date.now() / 1000).toString();
const durationDays = '10';  // How long the decryption permission lasts

const eip712 = fhevm.createEIP712(
    keypair.publicKey,
    contractAddresses,
    startTimestamp,
    durationDays,
);

// 5. User signs with their wallet (MetaMask popup)
const signature = await signer.signTypedData(
    eip712.domain,
    { UserDecryptRequestVerification: eip712.types.UserDecryptRequestVerification },
    eip712.message,
);

// 6. Request decryption through the Relayer
const result = await fhevm.userDecrypt(
    [{ handle: encryptedBalance, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.replace('0x', ''),
    contractAddresses,
    signer.address,
    startTimestamp,
    durationDays,
);

// 7. Read the decrypted value
const clearBalance = result[encryptedBalance];  // bigint
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

For backend services or custodial setups where a different address decrypts on behalf of the data owner.

### On-Chain: Owner Delegates Permission

```solidity
// The data owner delegates decryption rights to a backend address
FHE.delegateUserDecryption(
    backendAddress,      // delegate
    contractAddress,     // which contract's data
    expirationTimestamp  // when delegation expires (Unix timestamp)
);
```

### Off-Chain: Delegate Requests Decryption

```typescript
// Delegate creates EIP-712 for delegated decryption
const eip712 = fhevm.createDelegatedUserDecryptEIP712(
    keypair.publicKey,
    contractAddresses,
    startTimestamp,
    durationDays,
);

// Delegate signs
const signature = await delegateSigner.signTypedData(
    eip712.domain,
    { DelegatedUserDecryptRequestVerification: eip712.types.DelegatedUserDecryptRequestVerification },
    eip712.message,
);

// Request delegated decryption
const result = await fhevm.delegatedUserDecrypt(
    [{ handle: encryptedHandle, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.replace('0x', ''),
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
mapping(euint64 => address) private _unwrapRecipients;

function _unwrap(address from, address to, euint64 amount) internal {
    // 1. Burn the confidential tokens
    euint64 burntAmount = _burn(from, amount);

    // 2. Request public decryption of the burnt amount
    FHE.makePubliclyDecryptable(burntAmount);

    // 3. Store who should receive the unwrapped tokens
    _unwrapRecipients[burntAmount] = to;
    emit UnwrapRequested(to, burntAmount);
}

function finalizeUnwrap(
    euint64 burntAmount,
    uint64 clearAmount,
    bytes calldata decryptionProof
) external {
    address to = _unwrapRecipients[burntAmount];
    require(to != address(0), "No pending unwrap");
    delete _unwrapRecipients[burntAmount];

    // Verify the decryption proof
    bytes32[] memory handles = new bytes32[](1);
    handles[0] = FHE.toBytes32(burntAmount);
    FHE.checkSignatures(handles, abi.encode(clearAmount), decryptionProof);

    // Transfer the plaintext amount
    IERC20(underlying).safeTransfer(to, uint256(clearAmount));
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
