# FHEVM Testing Guide

## Overview

FHEVM contracts can be tested in two modes:

| Mode | Network | FHE | Speed | Use Case |
|------|---------|-----|-------|----------|
| **Mock** | Local Hardhat (31337) | Simulated | Fast (~seconds) | Development, CI/CD |
| **Real FHE** | Sepolia (11155111) | Actual coprocessor | Slow (~minutes) | Pre-deployment verification |

The `@fhevm/hardhat-plugin` handles both modes transparently.

## Hardhat Configuration

```typescript
// hardhat.config.ts
import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-toolbox";

const config: HardhatUserConfig = {
    solidity: {
        version: "0.8.27",
        settings: {
            optimizer: { enabled: true, runs: 800 },
            evmVersion: "cancun",  // REQUIRED for EIP-1153 transient storage
        },
    },
    networks: {
        hardhat: {
            chainId: 31337,
        },
        sepolia: {
            url: `https://sepolia.infura.io/v3/${INFURA_API_KEY}`,
            accounts: { mnemonic: MNEMONIC },
            chainId: 11155111,
        },
    },
};
```

## Test Structure

```typescript
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";

describe("MyConfidentialContract", function () {
    let contract: MyContract;
    let owner: HardhatEthersSigner;
    let alice: HardhatEthersSigner;
    let contractAddress: string;

    beforeEach(async function () {
        [owner, alice] = await ethers.getSigners();
        const factory = await ethers.getContractFactory("MyContract");
        contract = await factory.deploy();
        await contract.waitForDeployment();
        contractAddress = await contract.getAddress();
    });

    // Tests go here
});
```

## Encrypting Test Inputs

```typescript
// Single value
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(1000)
    .encrypt();

await contract.deposit(encrypted.handles[0], encrypted.inputProof);

// Multiple values
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(BigInt(price))
    .add32(quantity)
    .addBool(true)
    .encrypt();

await contract.placeBid(
    encrypted.handles[0],  // price (euint64)
    encrypted.handles[1],  // quantity (euint32)
    encrypted.handles[2],  // active (ebool)
    encrypted.inputProof,
);
```

## Decrypting Test Results

### User Decryption (Most Common in Tests)

```typescript
// Get the encrypted handle from contract
const encHandle = await contract.getBalance(alice.address);

// Decrypt as different types
const balance = await fhevm.userDecryptEuint(
    FhevmType.euint64,    // Specify the type
    encHandle,
    contractAddress,
    alice,                 // The signer who has ACL permission
);
expect(balance).to.equal(1000n);  // bigint comparison

// Boolean decryption
const flag = await fhevm.userDecryptEbool(encHandle, contractAddress, signer);
expect(flag).to.equal(true);

// Address decryption
const addr = await fhevm.userDecryptEaddress(encHandle, contractAddress, signer);
expect(addr).to.equal("0x1234...");
```

### FhevmType Values

```typescript
FhevmType.euint8
FhevmType.euint16
FhevmType.euint32
FhevmType.euint64
FhevmType.euint128
FhevmType.euint256
```

## Common Test Patterns

### Pattern 1: Test Encrypted Transfer

```typescript
it("should transfer tokens confidentially", async function () {
    // Mint 1000 tokens to owner
    await contract.mint(1000);

    // Transfer 300 to alice
    const encrypted = await fhevm
        .createEncryptedInput(contractAddress, owner.address)
        .add64(300)
        .encrypt();
    await contract.transfer(alice.address, encrypted.handles[0], encrypted.inputProof);

    // Verify owner balance
    const ownerBalance = await contract.balanceOf(owner.address);
    const clearOwner = await fhevm.userDecryptEuint(
        FhevmType.euint64, ownerBalance, contractAddress, owner,
    );
    expect(clearOwner).to.equal(700n);

    // Verify alice balance
    const aliceBalance = await contract.balanceOf(alice.address);
    const clearAlice = await fhevm.userDecryptEuint(
        FhevmType.euint64, aliceBalance, contractAddress, alice,
    );
    expect(clearAlice).to.equal(300n);
});
```

### Pattern 2: Test Silent Failure (Insufficient Balance)

```typescript
it("should silently transfer 0 on insufficient balance", async function () {
    await contract.mint(100);  // Only 100 tokens

    // Try to transfer 200 (more than balance)
    const encrypted = await fhevm
        .createEncryptedInput(contractAddress, owner.address)
        .add64(200)
        .encrypt();

    // Does NOT revert!
    await contract.transfer(alice.address, encrypted.handles[0], encrypted.inputProof);

    // Owner balance unchanged (still 100)
    const ownerBal = await contract.balanceOf(owner.address);
    const clearOwner = await fhevm.userDecryptEuint(
        FhevmType.euint64, ownerBal, contractAddress, owner,
    );
    expect(clearOwner).to.equal(100n);

    // Alice received 0
    const aliceBal = await contract.balanceOf(alice.address);
    const clearAlice = await fhevm.userDecryptEuint(
        FhevmType.euint64, aliceBal, contractAddress, alice,
    );
    expect(clearAlice).to.equal(0n);
});
```

### Pattern 3: Test Access Control

```typescript
it("should prevent unauthorized decryption", async function () {
    await contract.connect(alice).deposit(/* encrypted input */);

    // Owner should NOT be able to decrypt alice's balance
    const aliceBal = await contract.balanceOf(alice.address);

    // This should fail because owner doesn't have ACL permission
    await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, aliceBal, contractAddress, owner)
    ).to.be.rejected;
});
```

### Pattern 4: Test Encrypted Comparison

```typescript
it("should correctly compare encrypted values", async function () {
    const enc1 = await fhevm.createEncryptedInput(contractAddress, owner.address)
        .add64(100).encrypt();
    const enc2 = await fhevm.createEncryptedInput(contractAddress, owner.address)
        .add64(200).encrypt();

    await contract.compare(enc1.handles[0], enc2.handles[0], enc1.inputProof);

    const result = await contract.getResult();  // Returns ebool handle
    const isGreater = await fhevm.userDecryptEbool(result, contractAddress, owner);
    expect(isGreater).to.equal(false);  // 100 > 200 = false
});
```

### Pattern 5: Test with Multiple Signers

```typescript
it("should handle multi-party interactions", async function () {
    // Alice deposits
    const aliceEnc = await fhevm
        .createEncryptedInput(contractAddress, alice.address)
        .add64(500).encrypt();
    await contract.connect(alice).deposit(aliceEnc.handles[0], aliceEnc.inputProof);

    // Bob deposits
    const bobEnc = await fhevm
        .createEncryptedInput(contractAddress, bob.address)
        .add64(300).encrypt();
    await contract.connect(bob).deposit(bobEnc.handles[0], bobEnc.inputProof);

    // Each can only decrypt their own
    const aliceBal = await contract.balanceOf(alice.address);
    const clearAlice = await fhevm.userDecryptEuint(
        FhevmType.euint64, aliceBal, contractAddress, alice,
    );
    expect(clearAlice).to.equal(500n);
});
```

### Pattern 6: Conditional Skip for Mock/Real FHE

```typescript
describe("Mock-only tests", function () {
    beforeEach(async function () {
        if (!fhevm.isMock) this.skip();
    });
    // Fast tests for local development
});

describe("Sepolia-only tests", function () {
    beforeEach(async function () {
        if (fhevm.isMock) this.skip();
    });
    // Real FHE tests on Sepolia
});
```

### Pattern 7: Test Public Decryption Flow (checkSignatures)

Use `fhevm.publicDecrypt(handles)` to get the cleartext values AND the KMS proof, then pass both to your contract's reveal function:

```typescript
it("should reveal results via public decryption", async function () {
    // Setup: voting contract where votes are encrypted
    await contract.endVoting();  // Calls FHE.makePubliclyDecryptable internally

    // Get the encrypted handles
    const yesHandle = await contract.getYesVotesHandle();
    const noHandle = await contract.getNoVotesHandle();

    // Use publicDecrypt to get cleartexts + KMS proof (works in both mock and real FHE)
    const handles = [yesHandle, noHandle];
    const decrypted = await fhevm.publicDecrypt(handles);
    // decrypted.clearValues[handle] → bigint
    // decrypted.abiEncodedClearValues → bytes (for on-chain checkSignatures)
    // decrypted.decryptionProof → bytes (KMS signatures)

    // Pass both to the contract's reveal function
    await contract.revealResults(
        decrypted.abiEncodedClearValues,
        decrypted.decryptionProof,
    );

    // Verify the revealed values
    const clearYes = decrypted.clearValues[yesHandle];
    expect(await contract.revealedYes()).to.equal(clearYes);
});
```

**Important**: The SDK encodes all cleartext values as `uint256` in `abiEncodedClearValues`, regardless of the original encrypted type. In your Solidity callback, decode with `uint256` and cast down:

```solidity
function revealResults(bytes calldata abiEncodedCleartexts, bytes calldata proof) external {
    bytes32[] memory handlesList = new bytes32[](2);
    handlesList[0] = FHE.toBytes32(yesVotes);
    handlesList[1] = FHE.toBytes32(noVotes);
    FHE.checkSignatures(handlesList, abiEncodedCleartexts, proof);

    // SDK encodes as uint256, so decode as uint256 and cast
    (uint256 yesRaw, uint256 noRaw) = abi.decode(abiEncodedCleartexts, (uint256, uint256));
    revealedYes = uint64(yesRaw);
    revealedNo = uint64(noRaw);
}
```

**`fhevm.publicDecrypt()` return type:**
```typescript
const result = await fhevm.publicDecrypt(handles);
// result is an object with:
result.clearValues        // Record<string, bigint> — handle → decrypted value
result.abiEncodedClearValues  // string (bytes) — ABI-encoded for checkSignatures
result.decryptionProof    // string (bytes) — KMS signatures for checkSignatures

// Access individual values:
const value = result.clearValues[handleAsHexString]; // bigint
```

**Do NOT pass empty proof `"0x"`** — the KMSVerifier rejects empty proofs even in mock mode. Always use the proof from `fhevm.publicDecrypt()`.

### Testing finalizeUnwrap (Async 2-Step Unwrap)

```typescript
it("should unwrap and finalize", async function () {
    // Step 1: Request unwrap (burns encrypted tokens, requests decryption)
    const unwrapEnc = await fhevm.createEncryptedInput(tokenAddress, owner.address).add64(500).encrypt();
    const unwrapTx = await token.connect(owner)["unwrap(address,address,bytes32,bytes)"](
        owner.address, owner.address, unwrapEnc.handles[0], unwrapEnc.inputProof,
    );
    const receipt = await unwrapTx.wait();
    // Extract requestId from UnwrapRequested event
    const requestId = receipt.logs[...]; // Parse event for requestId

    // Step 2: In mock mode, get cleartext + proof via publicDecrypt
    // NOTE: The unwrap internally calls makePubliclyDecryptable on the burn handle
    // You need the burn handle from the event, then:
    // const decrypted = await fhevm.publicDecrypt([burnHandle]);
    // await token.finalizeUnwrap(requestId, decrypted.abiEncodedClearValues, decrypted.decryptionProof);

    // In practice, finalizeUnwrap testing in mock mode is complex because
    // the burn handle is internal to the wrapper. A simpler approach:
    // test wrap + encrypted transfer + balance verification instead.
});
```

### Mock Mode: Timestamp Behavior

In mock mode, `block.timestamp` may drift from `Date.now() / 1000` by several seconds. If you get timestamp collisions (two blocks with same timestamp), add to hardhat config:

```typescript
// hardhat.config.ts — under networks.hardhat:
hardhat: {
    allowBlocksWithSameTimestamp: true,  // Prevents timestamp collision errors
    chainId: 31337,
},
```

For time-dependent contracts (vesting, auctions, timelocks), use generous tolerances in assertions:

```typescript
// FRAGILE: exact timestamp match
expect(vestedAmount).to.equal(expectedAmount);

// ROBUST: allow ±5% tolerance for time-based calculations
const tolerance = expectedAmount * 5n / 100n;
expect(vestedAmount).to.be.closeTo(expectedAmount, tolerance);

// Or use Hardhat time manipulation for deterministic tests:
await ethers.provider.send("evm_increaseTime", [86400]); // +1 day
await ethers.provider.send("evm_mine", []);
```

### Testing Time-Based Contracts (Voting, Vesting, Auction)

Use Hardhat's time manipulation for deterministic time-based tests:

```typescript
// Advance time by 1 day
await ethers.provider.send("evm_increaseTime", [86400]);
await ethers.provider.send("evm_mine", []);

// Set to specific timestamp
await ethers.provider.send("evm_setNextBlockTimestamp", [futureTimestamp]);
await ethers.provider.send("evm_mine", []);

// Get current block timestamp
const block = await ethers.provider.getBlock("latest");
const now = block!.timestamp;
```

**Pattern for voting/auction with start/end times:**
```typescript
it("should reject vote after deadline", async function () {
    // Fast-forward past the voting deadline
    await ethers.provider.send("evm_increaseTime", [3601]); // 1 hour + 1 second
    await ethers.provider.send("evm_mine", []);

    // Vote should now fail
    let reverted = false;
    try { await vote(alice, true); } catch { reverted = true; }
    expect(reverted).to.be.true;
});
```

### Mock Mode: Random Number Behavior

In mock mode, `FHE.randEuint64()` and other random functions produce **deterministic pseudo-random values** based on an internal counter — NOT cryptographically random. This means:

- Same test run = same random values (reproducible)
- Random values are small integers in mock mode (not full uint64 range)
- Tests should NOT assert specific random values — instead test the logic around them
- On Sepolia/mainnet, random values come from the actual FHE coprocessor and are truly unpredictable

```typescript
// WRONG: asserting specific random value (fragile, mock-specific)
expect(ticketNumber).to.equal(42n);

// CORRECT: assert the value is in valid range
expect(ticketNumber).to.be.lessThan(1000n); // If bounded to [0,1000)
expect(ticketNumber).to.be.greaterThanOrEqual(0n);
```

### Mock Mode Edge Case: Constructor-Initialized Handles

Handles created in the constructor via `FHE.asEuint64(0)` (trivial encryption with no FHE operation) may fail `publicDecrypt` in mock mode with `KMSInvalidSigner`. This happens because the mock KMS only tracks handles that have gone through at least one FHE operation.

```solidity
// In constructor:
_yesVotes = FHE.asEuint64(0);  // This handle may fail publicDecrypt in mock

// Fix Option A (RECOMMENDED): Guard reveal with a minimum activity check
function endVoting() external onlyOwner {
    require(voteCount > 0, "No votes cast");  // Prevents empty-state publicDecrypt
    FHE.makePubliclyDecryptable(_yesVotes);
}

// Fix Option B: Initialize with a dummy FHE operation
// NOTE: Even FHE.add(asEuint64(0), asEuint64(0)) may still fail in some mock edge cases.
// Option A is more reliable.
_yesVotes = FHE.add(FHE.asEuint64(0), FHE.asEuint64(0));
FHE.allowThis(_yesVotes);
```

## Testing Reverts in FHEVM

**Important**: FHEVM contracts use custom errors (not `require("message")`). Use the correct assertion:

```typescript
// For custom errors (recommended in FHEVM):
// contract: error ERC7984UnauthorizedSpender(address holder, address spender);
await expect(tx).to.be.revertedWithCustomError(contract, "ERC7984UnauthorizedSpender");

// For require() string messages (legacy):
await expect(tx).to.be.revertedWith("Not authorized");

// When you don't care about the specific error (simplest, always works):
await expect(tx).to.be.reverted;
```

**FHEVM-specific revert behavior**: Remember that encrypted operations do NOT revert on failure — they silently return 0 (e.g., transfer with insufficient balance). Only **plaintext checks** (`require`, `if/revert`, custom errors on non-encrypted conditions) produce reverts. Never expect a revert from an encrypted balance check.

```typescript
// WRONG expectation: encrypted insufficient balance does NOT revert
await expect(confidentialTransfer(alice, 999999)).to.be.reverted; // FAILS — no revert!

// CORRECT: the transfer "succeeds" but sends 0
await confidentialTransfer(alice, 999999); // No revert
expect(await decryptBalance(sender)).to.equal(originalBalance); // Balance unchanged
```

### HardhatFhevmError: `expect().to.be.reverted` Not Catching Plugin Errors

In FHEVM mock mode, some operations throw `HardhatFhevmError` (a plugin-level error) instead of an on-chain revert. Chai's `.to.be.reverted` only catches on-chain reverts, so these errors slip through.

**Symptoms**: Test fails with `HardhatFhevmError` even though you expected a revert.

**Fix**: Use try-catch for operations that may throw plugin-level errors:

```typescript
// BROKEN: Chai's .to.be.reverted doesn't catch HardhatFhevmError
await expect(
    contract.connect(unauthorized).someFunction(encInput, proof)
).to.be.reverted;  // HardhatFhevmError not caught!

// FIXED: Use try-catch pattern
let reverted = false;
try {
    await contract.connect(unauthorized).someFunction(encInput, proof);
} catch {
    reverted = true;
}
expect(reverted).to.be.true;
```

**When does this happen?** Typically when:
- The `@fhevm/hardhat-plugin` validates encrypted inputs before sending the transaction
- ACL checks fail at the plugin level (not on-chain)
- Input proof validation fails in mock mode
- `ERC7984ZeroBalance` — trying to transfer from an uninitialized balance (also thrown at plugin level)

**When is `.to.be.reverted` fine?** For purely on-chain reverts that don't involve encrypted inputs:
```typescript
// These work normally with .to.be.reverted:
await expect(contract.connect(alice).mint(1000)).to.be.reverted; // onlyOwner
await expect(contract.connect(alice).endVoting()).to.be.reverted; // plaintext require
```

### fhevm Plugin Scope: Tests Only

The `fhevm` object (from `import { fhevm } from "hardhat"`) is **only available inside the Mocha test runner** (i.e., files run via `npx hardhat test`). It is NOT available in scripts run via `npx hardhat run`:

```typescript
// ✅ WORKS — test file (npx hardhat test)
import { fhevm } from "hardhat";
it("test", async () => { await fhevm.createEncryptedInput(...); });

// ❌ DOES NOT WORK — script file (npx hardhat run scripts/foo.ts)
import { fhevm } from "hardhat";  // fhevm is undefined!
```

For Sepolia on-chain verification scripts, use plain ethers.js transactions without fhevm helpers. You can still deploy and call contracts, but encryption/decryption must use the Relayer SDK directly (`@zama-fhe/relayer-sdk/node`) instead of the Hardhat plugin's `fhevm` wrapper.

```typescript
// scripts/onchain-verify.ts — runs via "npx hardhat run scripts/onchain-verify.ts --network sepolia"
import { ethers } from "hardhat";
// For encryption in scripts, use Relayer SDK directly (NOT fhevm from hardhat):
import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/node";

async function main() {
    const [deployer] = await ethers.getSigners();
    const contract = await ethers.getContractAt("MyContract", "0xDeployedAddress");

    // Plain transactions work fine:
    await contract.mint(deployer.address, 1000);

    // For encryption, init Relayer SDK with RPC URL string (not ethers provider):
    const fhevm = await createInstance({
        ...SepoliaConfig,
        network: "https://ethereum-sepolia-rpc.publicnode.com",
    });
    const encrypted = await fhevm
        .createEncryptedInput("0xContractAddress", deployer.address)
        .add64(500n)
        .encrypt();
    // ... use encrypted.handles[0] and encrypted.inputProof
}
main().catch(console.error);
```

## Running Tests

```bash
# Local mock mode (fast)
npx hardhat test

# On Sepolia (real FHE, slow)
npx hardhat test --network sepolia

# Specific test file
npx hardhat test test/MyContract.test.ts

# With gas reporting
REPORT_GAS=true npx hardhat test
```

## Deployment

```typescript
// deploy/001_deploy_my_contract.ts
import { DeployFunction } from "hardhat-deploy/types";

const func: DeployFunction = async function ({ deployments, getNamedAccounts }) {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("MyContract", {
        from: deployer,
        args: [],
        log: true,
    });
};

export default func;
func.tags = ["MyContract"];
```

```bash
# Deploy to Sepolia
npx hardhat deploy --network sepolia

# Verify on Etherscan (simple, no constructor args)
npx hardhat verify --network sepolia DEPLOYED_ADDRESS

# Verify with constructor args — create args.js first:
npx hardhat verify --network sepolia DEPLOYED_ADDRESS --constructor-args args.js
```

Example `args.js` for an ERC-7984 token (4 constructor args):
```javascript
// args.js
module.exports = [
    "0xF505e2E71df58D7244189072008f25f6b6aaE5ae", // owner address
    "ConfidentialUSDC",                              // name
    "cUSDC",                                         // symbol
    "https://example.com/token.json"                 // contractURI
];
```

```bash
npx hardhat verify --network sepolia 0xYourDeployedAddress --constructor-args args.js
```

## Common Testing Mistakes

### 1. Forgetting to await encrypted input creation

```typescript
// WRONG: encrypt() is async
const encrypted = fhevm.createEncryptedInput(addr, signer.address).add64(100).encrypt();
// encrypted is a Promise, not the actual result!

// CORRECT
const encrypted = await fhevm.createEncryptedInput(addr, signer.address).add64(100).encrypt();
```

### 2. Using wrong FhevmType for decryption

```typescript
// WRONG: contract stores euint64 but decrypting as euint32
const clear = await fhevm.userDecryptEuint(FhevmType.euint32, handle, addr, signer);

// CORRECT: match the type
const clear = await fhevm.userDecryptEuint(FhevmType.euint64, handle, addr, signer);
```

### 3. Decrypting with wrong signer

```typescript
// WRONG: alice deposited but trying to decrypt with bob
const clear = await fhevm.userDecryptEuint(FhevmType.euint64, aliceBalance, addr, bob);
// Fails: bob doesn't have ACL permission

// CORRECT: use the account that has ACL permission
const clear = await fhevm.userDecryptEuint(FhevmType.euint64, aliceBalance, addr, alice);
```

### 4. Not checking for handle equality (zero handle = uninitialized)

```typescript
// Check if a balance has been initialized
const handle = await contract.balanceOf(user.address);
// handle === 0n means the balance was never set
```
