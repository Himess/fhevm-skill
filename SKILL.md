---
name: fhevm
description: >-
  Guides the agent to build, test, and deploy confidential smart contracts
  using Zama's fhEVM protocol with Fully Homomorphic Encryption. Triggers when
  the user mentions FHEVM, fhEVM, FHE, encrypted types (euint8, euint64,
  ebool, eaddress), confidential smart contracts, homomorphic encryption,
  Zama protocol, encrypted balances, private transfers, or asks about
  ERC-7984 confidential tokens. Also triggers when importing @fhevm/solidity,
  fhevm-contracts, @zama-fhe/relayer-sdk, or when Solidity files contain
  FHE.add, FHE.select, FHE.allow, FHE.fromExternal, or externalEuint types.
  Covers the full lifecycle: project setup, encrypted types and operations,
  ACL permissions, input proofs, decryption (user/public/delegated),
  testing with Hardhat mock and Sepolia, frontend integration with Relayer SDK,
  ERC-7984 token standard, gas optimization, and security hardening.
  Includes a validation script that catches common FHEVM mistakes before deployment.
license: MIT
version: "1.0.0"
compatibility:
  - claude-code
  - cursor
  - windsurf
  - copilot
  - codex
  - gemini-cli
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
---

# FHEVM Development Skill

> Build confidential smart contracts with Fully Homomorphic Encryption on EVM chains using the Zama Protocol.

## Installation

Copy the `fhevm-skill/` directory to your AI tool's skills folder:
- **Claude Code**: `~/.claude/skills/fhevm/`
- **Cursor**: `.cursor/skills/fhevm/`
- **Windsurf**: `.windsurf/skills/fhevm/`
- **Copilot**: `.github/skills/fhevm/`

## Architecture

FHEVM uses a **coprocessor model** with 4 components:

```
User (browser)                          Coprocessor (FHE engine)
  │ encrypt via Relayer SDK                  │ executes actual FHE math
  ▼                                          ▲
Contract (Host Chain, EVM)  ──handles──►     │
  │ stores handles (bytes32)                 │
  │ symbolic execution only                  │
  ▼                                          │
ACL Contract ◄──── who can read what ──────► │
  │                                          │
  ▼                                          │
Gateway Chain ──── orchestrates ──────► KMS (Key Management Service)
                   decryption            │ threshold decryption
                                         │ multi-party computation
                                         │ no single party has the full key
```

**How it works:**

1. **Host Chain** (Ethereum/Sepolia): Your contracts live here. FHE operations are **symbolic** — when you call `FHE.add(a, b)`, the chain produces a new handle but the real encrypted computation happens asynchronously in the coprocessor.

2. **Coprocessor**: Rust-based engine that executes the actual FHE math offchain. Receives operations from the host chain, processes ciphertexts, returns result handles.

3. **ACL Contract**: On-chain registry tracking who can access each encrypted handle. Every `FHE.allow()`, `FHE.allowThis()`, and `FHE.allowTransient()` writes to this contract.

4. **KMS (Key Management Service)**: Handles decryption via **threshold multi-party computation** — the FHE secret key is split across multiple KMS nodes. No single node can decrypt alone. When `FHE.makePubliclyDecryptable()` is called, the KMS nodes cooperatively produce a decryption proof that can be verified on-chain via `FHE.checkSignatures()`.

5. **Gateway Chain** (chainId 10901 for Sepolia): Orchestrates communication between the host chain and KMS for decryption requests.

6. **Relayer SDK** (`@zama-fhe/relayer-sdk`): Frontend library that handles client-side encryption (ZK proof generation) and coordinates decryption requests with the KMS via the Gateway.

**Key implications:**
- You NEVER see plaintext in contract logic (except at system boundaries like wrap/unwrap)
- All branching on encrypted values uses `FHE.select()`, not `if/else`
- Decryption is **asynchronous** — mark a value as decryptable, then verify the KMS proof separately
- The FHE key is **never held by a single entity** — threshold security via KMS

## Two Library Generations — Use the NEW One

There are two incompatible Solidity libraries. **Always use the NEW system:**

| | OLD (deprecated) | NEW (use this) |
|---|---|---|
| **Package** | `fhevm` v0.5-0.6 | `@fhevm/solidity` v0.11+ |
| **Library** | `TFHE` | `FHE` |
| **Import** | `import "fhevm/lib/TFHE.sol"` | `import {FHE, euint64} from "@fhevm/solidity/lib/FHE.sol"` |
| **Input type** | `einput` | `externalEuint64` (typed per width) |
| **Input parse** | `TFHE.asEuint64(einput, proof)` | `FHE.fromExternal(externalEuint64, proof)` |
| **Config** | `SepoliaZamaFHEVMConfig` | `ZamaEthereumConfig` |
| **Decryption** | `Gateway.requestDecryption()` | `FHE.makePubliclyDecryptable()` + `FHE.checkSignatures()` |
| **Frontend SDK** | `fhevmjs` | `@zama-fhe/relayer-sdk` |

> **Warning**: `fhevm-contracts` was **archived in 2025** and used the OLD `TFHE` library. It has been replaced by `@openzeppelin/confidential-contracts` which uses the new `FHE` library. Use the new package for all development.

### Self-Correction Table

If you just generated code containing any of these, STOP and fix:

| If you wrote... | You meant... |
|---|---|
| `TFHE.asEuint64(input, proof)` | `FHE.fromExternal(externalEuint64, proof)` |
| `einput` parameter type | `externalEuint64` (or typed variant) |
| `Gateway.requestDecryption()` | `FHE.makePubliclyDecryptable()` + `checkSignatures` |
| `import "fhevm/lib/TFHE.sol"` | `import {FHE} from "@fhevm/solidity/lib/FHE.sol"` |
| `SepoliaZamaFHEVMConfig` | `ZamaEthereumConfig` |
| `fhevmjs` package | `@zama-fhe/relayer-sdk` |
| `FHE.decrypt(value)` in Solidity | No in-contract decrypt. Use Relayer SDK off-chain |
| `ebytes64` or `eint8` | These types don't exist. Use `euint64` or `ebool` |
| `FHE.div(a, encryptedB)` | Divisor must be plaintext: `FHE.div(a, uint64(b))` |
| `FHE.safeAdd()` / `safeSub()` | Don't exist. All arithmetic wraps silently |
| `npm install hardhat` (gets v3) | Use `npm install hardhat@^2.22.0` — FHEVM plugin requires Hardhat 2 |
| `npm install hardhat-deploy` (gets v2) | Use `hardhat-deploy@^0.11.45` — v2 is incompatible with Hardhat 2 |
| `npm install @nomicfoundation/hardhat-ethers` (gets v4) | Use `@nomicfoundation/hardhat-ethers@^3.1.3` — v4 requires Hardhat 3 |
| `abi.decode(cleartexts, (uint64))` | SDK encodes as `uint256`: use `abi.decode(cleartexts, (uint256))` then cast |
| `FHE.randEuint64(100)` | upperBound must be power of 2: `FHE.randEuint64(128)` then `FHE.rem(r, 100)` |

## Agent Workflow

**CRITICAL REMINDERS (read before writing ANY code):**
- ERC-7984 tokens use `confidentialTransfer`/`confidentialBalanceOf` — NOT `transfer`/`balanceOf`
- Use Hardhat 2 (`^2.28.4`) — NOT Hardhat 3
- Call `FHE.allowThis()` + `FHE.allow()` after EVERY FHE operation that stores a value
- Functions receiving encrypted handles from other contracts need `FHE.isSenderAllowed()` check
- Encrypted operations NEVER revert — they silently return 0

**When a user asks to create a new FHEVM project:**

1. **Scaffold**: Clone `fhevm-hardhat-template` or create Hardhat project with FHEVM deps
2. **Configure**: Set `evmVersion: "cancun"` in hardhat.config.ts (use templates/hardhat.config.ts)
3. **Write contract**: Use templates/ as starting points. Always use the NEW FHE library
4. **Apply ACL pattern**: After every FHE operation that stores a value: `allowThis` + `allow`
5. **Write tests**: Use templates/test-template.ts as boilerplate. Test silent failures
6. **Validate**: Run `scripts/validate-fhevm.sh` against the contracts directory
7. **Deploy**: `npx hardhat deploy --network sepolia` then verify

**When a user asks to add FHE to an existing contract:**

1. Add `@fhevm/solidity` dependency
2. Inherit `ZamaEthereumConfig`
3. Replace plaintext state variables with encrypted types (`uint256 balance` → `euint64 balance`)
4. Replace `if/require` conditions with `FHE.select` patterns
5. Add ACL calls after every state mutation
6. Run `scripts/validate-fhevm.sh`

## Quick Start

### 1. Project Setup

```bash
git clone https://github.com/zama-ai/fhevm-hardhat-template.git my-fhevm-project
cd my-fhevm-project && npm install
# Template does NOT include OpenZeppelin. Install for Ownable2Step, ReentrancyGuard, etc.:
npm install @openzeppelin/contracts@^5.6.1
# For ERC-7984 tokens, also install:
npm install @openzeppelin/confidential-contracts@^0.4.0
```

Key deps: `@fhevm/solidity` ^0.11.1, `@fhevm/hardhat-plugin` ^0.4.2, `@zama-fhe/relayer-sdk` ^0.4.1.

**CRITICAL**: Use **Hardhat 2** (^2.22.0), NOT Hardhat 3. The `@fhevm/hardhat-plugin` is incompatible with Hardhat 3. If setting up from scratch instead of cloning the template:

```bash
npm install --save-dev hardhat@^2.28.4 @fhevm/solidity@^0.11.1 @fhevm/hardhat-plugin@^0.4.2 @fhevm/mock-utils@^0.4.2 @zama-fhe/relayer-sdk@^0.4.1 encrypted-types@^0.0.4 @nomicfoundation/hardhat-chai-matchers@^2.1.0 @nomicfoundation/hardhat-ethers @nomicfoundation/hardhat-verify @typechain/hardhat hardhat-deploy@^0.11.45 ethers @openzeppelin/contracts@^5.6.1 @openzeppelin/confidential-contracts@^0.4.0
```

> **These are the exact same versions Zama uses in fhevm-hardhat-template.** Use `hardhat@^2.28.4` (Hardhat 2, NOT 3). The `@fhevm/hardhat-plugin` is incompatible with Hardhat 3.

Config must set `evmVersion: "cancun"` and `viaIR: true` (avoids stack-too-deep in complex FHE contracts).

### Sepolia Deployment

For deploying to Sepolia testnet, you need:

**RPC URLs** (no API key needed for public RPCs):
```
https://ethereum-sepolia-rpc.publicnode.com
https://rpc.ankr.com/eth_sepolia
https://sepolia.infura.io/v3/YOUR_KEY  (if you have Infura)
```

**Sepolia ETH faucets:**
- https://www.alchemy.com/faucets/ethereum-sepolia
- https://cloud.google.com/application/web3/faucet/ethereum/sepolia
- https://faucets.chain.link/sepolia

### 2. Minimal Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";

contract ConfidentialCounter is ZamaEthereumConfig {
    euint64 private _count;

    function add(externalEuint64 encryptedValue, bytes calldata inputProof) external {
        euint64 value = FHE.fromExternal(encryptedValue, inputProof);
        _count = FHE.add(_count, value);
        FHE.allowThis(_count);
        FHE.allow(_count, msg.sender);
    }

    function getCount() external view returns (euint64) {
        return _count;
    }
}
```

### 3. Test It

```typescript
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";

it("increments encrypted counter", async function () {
    const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signer.address)
        .add64(42)
        .encrypt();
    await contract.add(encrypted.handles[0], encrypted.inputProof);

    const handle = await contract.getCount();
    const clear = await fhevm.userDecryptEuint(FhevmType.euint64, handle, contractAddress, signer);
    expect(clear).to.equal(42n);
});
```

## Decision Trees

### "Which encrypted type should I use?"

```
Is the value a boolean (true/false)?
  └─ Yes → ebool
  └─ No → Is it an Ethereum address?
       └─ Yes → eaddress
       └─ No → What's the value range?
            └─ 0-255 → euint8  (ages, scores, small enums)
            └─ 0-65535 → euint16  (years, small counts)
            └─ 0-4B → euint32  (timestamps, medium counts)
            └─ 0-18.4×10¹⁸ → euint64  (token amounts, balances — MOST COMMON)
            └─ Larger → euint128 or euint256
                 ⚠️ euint256: only eq/ne comparisons, no ordering (gt/lt/ge/le)
```

### "How should I handle decryption?"

```
Who needs to see the plaintext?
  └─ Only the data owner (private) → User Decryption (EIP-712 flow)
       See: references/decryption-guide.md#user-decryption
  └─ Everyone / contract logic needs it → Public Decryption
       See: references/decryption-guide.md#public-decryption
  └─ A backend service on behalf of user → Delegated Decryption
       See: references/decryption-guide.md#delegated-decryption
```

### "Which ACL function do I need?"

```
When is the encrypted value needed?
  └─ In a FUTURE transaction (stored in state) → FHE.allow(value, account)
       Also call: FHE.allowThis(value) so the contract can access it later
  └─ Only within THIS transaction (cross-contract call) → FHE.allowTransient(value, account)
       Cheaper gas (EIP-1153 transient storage), cleared after tx
  └─ Anyone should be able to decrypt it → FHE.makePubliclyDecryptable(value)
```

### "Which library/import should I use?"

```
Using @openzeppelin/confidential-contracts (ERC-7984)? → FHE + ZamaEthereumConfig + ERC7984 base
Writing a standalone contract from scratch? → FHE + ZamaEthereumConfig
```

### "Cross-contract encrypted value?"

```
Same transaction? → FHE.allowTransient(value, target) before the call
Future transaction? → FHE.allow(value, target)
Forwarding user's input proof? → STOP: proofs bound to msg.sender. Use 2-tx flow.
```

### "My FHEVM code doesn't work — what's wrong?"

```
Is it a compilation error?
  └─ "type not found" → Check imports: use @fhevm/solidity/lib/FHE.sol
  └─ "div/rem type mismatch" → Divisor must be plaintext: FHE.div(enc, uint64)
  └─ "gt/lt not found for euint256" → euint256 only supports eq/ne
  └─ "cannot be declared as view" → FHE ops modify state. Remove view/pure modifier
  └─ "Cannot determine a test runner" → You have Hardhat 3 — downgrade to Hardhat 2
  └─ "invalid: ^2.0.0 from @fhevm/hardhat-plugin" → Same: npm install hardhat@^2.22.0
Is it a runtime revert?
  └─ "Sender not allowed" → Missing FHE.allowTransient() before cross-contract call
  └─ Reverts on FHE.rand → Random must be in non-view function
  └─ "evmVersion" errors → Set evmVersion: "cancun" in hardhat.config
Is it a silent failure (no revert, but wrong result)?
  └─ Transfer sends 0 → Insufficient balance (by design). Check with handle comparison
  └─ Contract can't read its own data → Missing FHE.allowThis() after operation
  └─ Decryption returns nothing → Missing FHE.allow(value, user)
```

## Core Patterns

### Pattern 1: The ACL Triple (MANDATORY after every FHE operation that produces a stored value)

```solidity
balances[user] = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]);    // Contract can use it in future tx
FHE.allow(balances[user], user);  // User can decrypt their own balance
```

Forgetting `allowThis` is the #1 FHEVM bug — the contract creates a new handle but loses access to it because each FHE operation produces a NEW handle with NO inherited permissions.

### Pattern 2: Silent Transfer (no-revert on insufficient balance)

```solidity
function _transfer(address from, address to, euint64 amount) internal {
    ebool canTransfer = FHE.le(amount, balances[from]);
    euint64 transferValue = FHE.select(canTransfer, amount, FHE.asEuint64(0));

    balances[from] = FHE.sub(balances[from], transferValue);
    FHE.allowThis(balances[from]);
    FHE.allow(balances[from], from);

    balances[to] = FHE.add(balances[to], transferValue);
    FHE.allowThis(balances[to]);
    FHE.allow(balances[to], to);
}
```

FHE transfers NEVER revert on insufficient balance — reverting would leak balance information. They silently transfer 0. This is by design, not a bug.

### Pattern 3: Encrypted Conditional Logic (use `select`, never `if`)

```solidity
// WRONG — leaks which branch was taken
if (FHE.decrypt(condition)) { x = a; } else { x = b; }

// CORRECT — preserves confidentiality
euint64 result = FHE.select(condition, a, b);
```

### Pattern 4: Input Validation

```solidity
// Single encrypted input:
function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
    euint64 amount = FHE.fromExternal(encAmount, inputProof);
}

// Multiple encrypted inputs share ONE proof:
function swap(externalEuint64 encIn, externalEuint64 encOut, bytes calldata inputProof) external {
    euint64 amountIn = FHE.fromExternal(encIn, inputProof);   // Same proof
    euint64 amountOut = FHE.fromExternal(encOut, inputProof); // Same proof
}

// For already-verified handles (e.g., from another contract):
function processHandle(euint64 amount) external {
    require(FHE.isSenderAllowed(amount), "Sender not allowed");
}
```

### Pattern 5: Cross-Contract FHE (the 5-step pattern)

```solidity
// 1. Encrypt amount
euint64 encAmount = FHE.asEuint64(amount);
// 2. Grant transient access to the receiving contract
FHE.allowTransient(encAmount, address(token));
// 3. Call the other contract
euint64 transferred = token.confidentialTransferFrom(msg.sender, address(this), encAmount);
// 4. Grant persistent access to THIS contract for future use
FHE.allowThis(transferred);  // equivalent to FHE.allow(transferred, address(this))
// 5. Store the handle
escrow.budget = transferred;
```

Step 2 uses `allowTransient` (cheaper, same-tx only). Step 4 uses `allow` (persistent, needed for future transactions).

For collecting ERC-7984 token payments (lottery, escrow, payroll), see the step-by-step recipe in **[references/erc7984-guide.md](references/erc7984-guide.md)#recipe-fund-a-contract**.

### Pattern 6: ERC-7984 Confidential Token (Zama's core standard)

ERC-7984 is the FHE equivalent of ERC-20. Use `@openzeppelin/confidential-contracts`:

```bash
npm install @openzeppelin/confidential-contracts@^0.4.0 @fhevm/solidity@^0.11.1 @openzeppelin/contracts@^5.6.1
```

Key differences from ERC-20:
- **Function names**: `confidentialTransfer`, `confidentialBalanceOf`, `confidentialTotalSupply` (NOT `transfer`/`balanceOf`)
- **Operator model**: `setOperator(address, uint48 until)` — time-based, NOT amount-based approval
- **Transfers return `euint64`** (actual transferred amount), NOT `bool`
- **Silently sends 0** on insufficient balance (no revert)
- **Default decimals: 6** (not 18)
- **Events**: `ConfidentialTransfer(from, to, encAmount)` with encrypted handle

```solidity
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";

contract MyToken is ZamaEthereumConfig, ERC7984, Ownable2Step {
    constructor() ERC7984("MyToken", "MTK", "https://example.com/token.json") Ownable(msg.sender) {}
    function mint(address to, uint64 amount) external onlyOwner { _mint(to, FHE.asEuint64(amount)); }
}
```

> **Warning**: The old `fhevm-contracts` package was **archived in June 2025**. Use `@openzeppelin/confidential-contracts` for all new development.

See **[references/erc7984-guide.md](references/erc7984-guide.md)** for complete interface, operator model, wrap/unwrap, extensions, and cross-contract patterns.

## Critical Anti-Patterns

### 1. Branching on encrypted values [CRITICAL — leaks confidential data]

```solidity
// WRONG: if (FHE.decrypt(isEligible)) { grant(); }
// CORRECT:
euint64 reward = FHE.select(isEligible, fullReward, FHE.asEuint64(0));
```

`if/require/assert` with encrypted booleans reveals the value to validators by observing which branch executes.

### 2. Forgetting `FHE.allowThis()` [CRITICAL — contract loses access to its data]

```solidity
// WRONG: balances[user] = FHE.add(balances[user], amount);
// CORRECT:
balances[user] = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]);
FHE.allow(balances[user], user);
```

### 3. Dividing by encrypted value [CRITICAL — does not compile]

```solidity
// WRONG: FHE.div(amount, encDivisor);
// CORRECT:
euint64 result = FHE.div(amount, uint64(100));  // Plaintext divisor only
```

### 4. Using `require()` for balance checks [CRITICAL — leaks balance info]

```solidity
// WRONG: require(balance >= amount, "Insufficient");
// CORRECT:
ebool sufficient = FHE.ge(balance, amount);
euint64 actual = FHE.select(sufficient, amount, FHE.asEuint64(0));
```

### 5. Random in view functions [HIGH — runtime revert]

Random generation mutates on-chain PRNG state. Must be a state-changing function.

### 6. Bounded random with non-power-of-2 [HIGH — undefined behavior]

`FHE.randEuint8(6)` is wrong. Use `FHE.randEuint8(8)` (power of 2), then `FHE.rem(result, uint8(6))`.

### 7. Deprecated TFHE library for new contracts [HIGH — wrong API]

Use `FHE` from `@fhevm/solidity/lib/FHE.sol`, not `TFHE` from `fhevm/lib/TFHE.sol`.

### 8. Unprotected view function returning encrypted handles [MEDIUM]

Always check `FHE.isAllowed(value, msg.sender)` before returning encrypted handles.

### 9. Ordering comparisons on euint256 [HIGH — does not compile]

`euint256` only supports `eq`/`ne`. Use `euint128` or smaller for `gt`/`lt`/`ge`/`le`.

### 10. Exceeding 2048-bit decryption limit [MEDIUM]

Max per request: 32 × euint64, or 16 × euint128, or 256 × euint8. Total ≤ 2048 bits.

## Do NOT Generate These (Common AI Hallucinations)

| Hallucinated | Reality |
|---|---|
| `FHE.decrypt()` in Solidity | Decryption is off-chain only via Relayer SDK |
| `Gateway.requestDecryption()` | Removed in v0.9+. Use self-relaying pattern |
| `ebytes64`, `eint8` (signed types) | These types do not exist in FHE.sol |
| `FHE.safeAdd()` / `safeSub()` / `safeMul()` | No `FHE.safe*`. Use `FHESafeMath.tryAdd/trySub` from `@openzeppelin/confidential-contracts` |
| `TFHE.*` for new contracts | Use `FHE.*` from `@fhevm/solidity` |
| `FHE.div(encrypted, encrypted)` | Divisor must be plaintext |
| `FHE.sealoutput()` | Does not exist in v0.11 |
| `FHE.allowForDecryption()` | Correct name: `FHE.makePubliclyDecryptable()` |
| `randEuint8Bounded(n)` | Correct: `FHE.randEuint8(uint8 upperBound)` |

## Battle Scars (Real-World Lessons)

1. **"Why did 0 tokens arrive?"**: We deployed a confidential ERC-20 and tested a transfer of 1000 tokens from an account with 500. No revert, no error, transaction succeeded. The recipient got 0. We spent hours debugging before realizing: FHE transfers NEVER revert on insufficient balance. The `select` pattern quietly chose 0. **Detection trick**: compare the sender's balance handle before and after — if unchanged, the transfer silently failed.

2. **"Why does the proof fail cross-contract?"**: Our vault contract received an encrypted input from a user and forwarded it to a token contract via `confidentialTransferFrom`. Proof validation failed every time. Root cause: input proofs are bound to `msg.sender`. When the vault forwarded the call, `msg.sender` changed from user to vault. **Fix**: 2-transaction flow — user sends to token directly, then vault triggers logic separately.

3. **"Why can't the contract read its own storage?"**: Contract stored an encrypted treasury balance. First transaction worked. Second transaction reverted with "not allowed." Root cause: `FHE.add()` creates a NEW handle — the old handle's ACL doesn't carry over. We were missing `FHE.allowThis()` after the operation. **Rule**: every FHE operation + state store = must call `allowThis`.

4. **"Gas doesn't change with amount?"**: We benchmarked `FHE.add(1, 2)` vs `FHE.add(MAX_UINT64, MAX_UINT64)` — identical gas. This is intentional: variable gas would leak information about encrypted values. Don't try to optimize around amount-based gas.

5. **"Same amount, different ciphertext?"**: Frontend test encrypted 100 twice and compared handles — they differed. This is correct: encryption is non-deterministic by design. Deterministic encryption would leak information through ciphertext equality comparison.

## Supported Types & Operations Quick Reference

| Type | Bits | Arithmetic | Comparison | Bitwise | Random |
|------|------|-----------|------------|---------|--------|
| `ebool` | 1 | - | eq, ne | and, or, xor, not | randEbool |
| `euint8` | 8 | add, sub, mul, div*, rem*, neg, min, max | all | all + shifts | randEuint8 |
| `euint16` | 16 | same | all | all + shifts | randEuint16 |
| `euint32` | 32 | same | all | all + shifts | randEuint32 |
| `euint64` | 64 | same | all | all + shifts | randEuint64 |
| `euint128` | 128 | same | all | all + shifts | randEuint128 |
| `euint256` | 256 | neg only | eq, ne only | all + shifts | randEuint256 |
| `eaddress` | 160 | - | eq, ne | - | - |

*`div` and `rem`: plaintext right-hand operand ONLY. Shift amounts are always `euint8`/`uint8`.

## Reference Files

For detailed guides, read the corresponding reference file:

- **[Type System](references/type-system.md)** — Complete type details, casting, cross-type operations, operator overloads
- **[ACL Patterns](references/acl-patterns.md)** — allow, allowThis, allowTransient, makePubliclyDecryptable, delegation
- **[Input Proofs](references/input-proofs.md)** — Client-side encryption, contract-side validation, multi-input proofs
- **[Decryption Guide](references/decryption-guide.md)** — User decryption (EIP-712), public decryption, checkSignatures, delegated
- **[Testing Guide](references/testing-guide.md)** — Mock mode, Sepolia testing, decrypt helpers, test patterns
- **[Frontend Integration](references/frontend-integration.md)** — Relayer SDK setup, encryption, decryption, React patterns
- **[ERC-7984 Guide](references/erc7984-guide.md)** — Confidential tokens, wrap/unwrap, ConfidentialERC20, OpenZeppelin contracts
- **[Common Pitfalls](references/common-pitfalls.md)** — Extended anti-patterns with explanations and battle scars
- **[Gas Optimization](references/gas-optimization.md)** — FHE-specific gas patterns, type sizing, batching strategies
- **[Security Checklist](references/security-checklist.md)** — Production security audit checklist for FHEVM contracts

## Templates

- **[templates/confidential-erc20.sol](templates/confidential-erc20.sol)** — ERC-7984 confidential token with encrypted balances
- **[templates/encrypted-voting.sol](templates/encrypted-voting.sol)** — Confidential voting with encrypted tallies
- **[templates/blind-auction.sol](templates/blind-auction.sol)** — Sealed-bid auction with encrypted bids
- **[templates/hardhat.config.ts](templates/hardhat.config.ts)** — Production-ready Hardhat configuration
- **[templates/test-template.ts](templates/test-template.ts)** — Test boilerplate for custom FHE contracts
- **[templates/test-erc7984-template.ts](templates/test-erc7984-template.ts)** — Test boilerplate for ERC-7984 tokens (operator model)
- **[templates/confidential-escrow.sol](templates/confidential-escrow.sol)** — Escrow with encrypted deposits, release, refund, arbiter dispute
- **[templates/confidential-swap.sol](templates/confidential-swap.sol)** — Token swap with encrypted amounts and fee collection
- **[templates/react-dashboard.tsx](templates/react-dashboard.tsx)** — Complete React component: connect, decrypt balance, encrypted transfer
- **[templates/deploy-template.ts](templates/deploy-template.ts)** — Hardhat-deploy script template
- **[templates/mock-erc20.sol](templates/mock-erc20.sol)** — Mock ERC-20 for testing wrap/unwrap flows

## Validation

Run `scripts/validate-fhevm.sh` against your contracts to catch common FHEVM mistakes before deployment:

```bash
chmod +x scripts/validate-fhevm.sh
./scripts/validate-fhevm.sh ./contracts
```

Checks: missing `allowThis`, deprecated TFHE usage, encrypted divisors, branching on encrypted values, missing `cancun` evmVersion, deprecated Gateway pattern, euint256 ordering comparisons, and more.
