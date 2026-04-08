# ERC-7984: Confidential Token Standard

## Overview

ERC-7984 is **Zama's official standard** for confidential fungible tokens on FHEVM. It is the FHE equivalent of ERC-20 — every confidential token on FHEVM should implement this standard.

### What Makes ERC-7984 Different from ERC-20

| Feature | ERC-20 | ERC-7984 |
|---------|--------|----------|
| **Balances** | Public `uint256` | Encrypted `euint64` — nobody sees balances |
| **Transfer function** | `transfer(to, amount)` | `confidentialTransfer(to, encAmount, proof)` |
| **Transfer return** | `bool` | `euint64` (the actual transferred amount) |
| **Insufficient balance** | Reverts with error | **Silently transfers 0** (revert would leak info) |
| **Approval model** | `approve(spender, amount)` — amount-based | `setOperator(operator, until)` — **time-based** |
| **Events** | `Transfer(from, to, amount)` — plaintext | `ConfidentialTransfer(from, to, encAmount)` — encrypted handle |
| **View functions** | Anyone reads balances | ACL-gated via `FHE.isAllowed` |
| **Total supply** | `totalSupply()` public | `confidentialTotalSupply()` — encrypted |
| **Decimals** | Typically 18 | **Default 6** (euint64 max = ~18.4×10¹⁸) |
| **Callback** | None standard | `confidentialTransferAndCall` + `IERC7984Receiver` |

## OpenZeppelin Confidential Contracts (Recommended)

The official implementation is `@openzeppelin/confidential-contracts`. This **replaces** the archived `fhevm-contracts` package.

```bash
npm install @openzeppelin/confidential-contracts @fhevm/solidity @openzeppelin/contracts
```

> **Warning**: The old `fhevm-contracts` package was **archived in June 2025** and uses the deprecated `TFHE` library. For all new development, use `@openzeppelin/confidential-contracts` which uses the new `FHE` library.

## IERC7984 Interface

```solidity
import {euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";

interface IERC7984 {
    // ─── Events ─────────────────────────────────────────────────
    event OperatorSet(address indexed holder, address indexed operator, uint48 until);
    event ConfidentialTransfer(address indexed from, address indexed to, euint64 indexed amount);
    event AmountDisclosed(euint64 indexed encryptedAmount, uint64 amount);

    // ─── View Functions ─────────────────────────────────────────
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);           // Default: 6
    function contractURI() external view returns (string memory);
    function confidentialTotalSupply() external view returns (euint64);
    function confidentialBalanceOf(address account) external view returns (euint64);
    function isOperator(address holder, address spender) external view returns (bool);

    // ─── Operator (replaces ERC-20 approve/allowance) ───────────
    function setOperator(address operator, uint48 until) external;

    // ─── Transfer (2 overloads) ─────────────────────────────────
    function confidentialTransfer(address to, externalEuint64 encAmount, bytes calldata proof) external returns (euint64);
    function confidentialTransfer(address to, euint64 amount) external returns (euint64);

    // ─── TransferFrom (2 overloads) ─────────────────────────────
    function confidentialTransferFrom(address from, address to, externalEuint64 encAmount, bytes calldata proof) external returns (euint64);
    function confidentialTransferFrom(address from, address to, euint64 amount) external returns (euint64);

    // ─── TransferAndCall (2 overloads) ──────────────────────────
    function confidentialTransferAndCall(address to, externalEuint64 encAmount, bytes calldata proof, bytes calldata data) external returns (euint64);
    function confidentialTransferAndCall(address to, euint64 amount, bytes calldata data) external returns (euint64);

    // ─── TransferFromAndCall (2 overloads) ──────────────────────
    function confidentialTransferFromAndCall(address from, address to, externalEuint64 encAmount, bytes calldata proof, bytes calldata data) external returns (euint64);
    function confidentialTransferFromAndCall(address from, address to, euint64 amount, bytes calldata data) external returns (euint64);
}
```

## Deploying an ERC-7984 Token

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MyToken is ZamaEthereumConfig, ERC7984, Ownable2Step {
    constructor(address owner_, uint64 initialSupply)
        ERC7984("MyToken", "MTK", "https://example.com/token.json")
        Ownable(owner_)
    {
        _mint(owner_, FHE.asEuint64(initialSupply));
    }

    function mint(address to, uint64 amount) external onlyOwner {
        _mint(to, FHE.asEuint64(amount));
    }

    function confidentialMint(
        address to, externalEuint64 encAmount, bytes calldata proof
    ) external onlyOwner returns (euint64) {
        return _mint(to, FHE.fromExternal(encAmount, proof));
    }

    function burn(address from, uint64 amount) external onlyOwner {
        _burn(from, FHE.asEuint64(amount));
    }
}
```

**Key points:**
- `ERC7984` is abstract — you must create a concrete contract
- Constructor requires 3 args: `name`, `symbol`, `contractURI`
- `_mint` and `_burn` are internal — expose them as needed
- ACL is handled automatically by the base `_update` function
- Default `decimals()` returns **6**

**ERC7984ZeroBalance revert**: Unlike custom implementations where transfers always silently send 0, the OpenZeppelin ERC7984 base **reverts with `ERC7984ZeroBalance`** when a sender has NEVER received any tokens (uninitialized balance = zero handle). Silent 0 transfer only applies to initialized balances with insufficient funds. This means:

```solidity
// User has received tokens before but balance < amount → silent 0 transfer (no revert)
// User has NEVER received any tokens (zero handle) → reverts with ERC7984ZeroBalance
```

## When Does ERC-7984 Revert vs Silent 0?

| Scenario | Behavior |
|----------|----------|
| Transfer with insufficient balance (initialized) | **Silent 0 transfer** — no revert |
| Transfer from uninitialized sender (never received tokens) | **Reverts** with `ERC7984ZeroBalance` |
| TransferFrom without operator permission | **Reverts** with `ERC7984UnauthorizedSpender` |
| Transfer to `address(0)` | **Reverts** with `ERC7984InvalidReceiver` |
| Transfer from `address(0)` | **Reverts** with `ERC7984InvalidSender` |
| Using encrypted handle without ACL | **Reverts** with `ERC7984UnauthorizedUseOfEncryptedAmount` |

## Operator Model (NOT Approve/Allowance)

ERC-7984 uses **time-based operators** instead of ERC-20's amount-based approval:

```solidity
// Grant operator permission until a specific timestamp
token.setOperator(spenderAddress, uint48(block.timestamp + 1 days));

// Check if someone is an operator
bool canSpend = token.isOperator(holderAddress, spenderAddress);

// Revoke by setting expiry to 0
token.setOperator(spenderAddress, 0);
```

**Key difference from ERC-20**: Operators can move ANY amount while approved. There is no amount cap. The permission expires at the `until` timestamp.

**Self-operator**: `isOperator(holder, holder)` always returns `true` (you are your own operator).

## Cross-Contract Interaction

When your contract needs to interact with an ERC-7984 token:

```solidity
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

contract Vault {
    IERC7984 public token;

    // User must first: token.setOperator(vaultAddress, expiry)
    function deposit(euint64 amount) external {
        require(FHE.isSenderAllowed(amount), "Not allowed");
        FHE.allowTransient(amount, address(token));
        token.confidentialTransferFrom(msg.sender, address(this), amount);
    }

    // Vault pays user from its own balance
    function withdraw(euint64 amount) external {
        FHE.allowTransient(amount, address(token));
        token.confidentialTransfer(msg.sender, amount);
    }
}
```

**Important**: The user must call `token.setOperator(vaultAddress, expiry)` before depositing, because ERC-7984 uses operator model (not approve).

## ERC-7984 Receiver (Transfer-and-Call)

Contracts receiving tokens via `confidentialTransferAndCall`:

```solidity
import {IERC7984Receiver} from "@openzeppelin/confidential-contracts/interfaces/IERC7984Receiver.sol";
import {ebool, euint64} from "@fhevm/solidity/lib/FHE.sol";

contract PaymentProcessor is IERC7984Receiver {
    function onConfidentialTransferReceived(
        address operator,
        address from,
        euint64 amount,      // Transient ACL — only valid in this tx
        bytes calldata data
    ) external returns (ebool) {
        // Process payment...
        return FHE.asEbool(true);  // Accept the transfer
    }
}
```

If the callback returns `false` (encrypted), the token contract attempts to refund the transfer.

## Wrap/Unwrap (ERC-20 ↔ ERC-7984)

Use `ERC7984ERC20Wrapper` extension:

```solidity
import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";

contract WrappedToken is ZamaEthereumConfig, ERC7984ERC20Wrapper, Ownable2Step {
    constructor(IERC20 underlying_, address owner_)
        ERC7984("Wrapped USDC", "wUSDC", "https://example.com/wrapped.json")
        ERC7984ERC20Wrapper(underlying_)
        Ownable(owner_)
    {}
}
```

### ERC7984ERC20Wrapper Function Signatures

```solidity
// Wrap: locks ERC-20, mints encrypted ERC-7984 tokens
function wrap(address to, uint256 amount) external;
// User must first: underlying.approve(wrapperAddress, amount)

// Unwrap (3 overloads):
function unwrap(address from, address to, uint64 amount) external;
function unwrap(address from, address to, externalEuint64 encAmount, bytes calldata proof) external;
function unwrap(address from, address to, euint64 amount) external;
// Burns encrypted tokens, calls makePubliclyDecryptable, stores unwrap request

// Finalize: anyone can call after KMS decrypts
function finalizeUnwrap(uint256 requestId, uint64 cleartextAmount, bytes calldata decryptionProof) external;
// Verifies proof via checkSignatures, transfers plaintext ERC-20 to recipient

// View:
function underlying() external view returns (address);  // The wrapped ERC-20
```

### Wrap: ERC-20 → ERC-7984

```solidity
// Step 1: User approves wrapper to spend their ERC-20
underlying.approve(wrapperAddress, amount);

// Step 2: Wrap — locks ERC-20, mints encrypted tokens to user
wrapper.wrap(userAddress, amount);
```

### Unwrap: ERC-7984 → ERC-20 (Async 2-Step)

```solidity
// Step 1: User requests unwrap (burns encrypted, requests decryption)
wrapper.unwrap(msg.sender, recipientAddress, amount);
// Emits event with requestId — frontend listens for this

// Step 2: Finalize after KMS decrypts (permissionless — anyone can call)
wrapper.finalizeUnwrap(requestId, cleartextAmount, decryptionProof);
// Verifies proof via checkSignatures, transfers plaintext ERC-20
```

## Recipe: Fund a Contract with ERC-7984 Tokens (Payroll/Escrow Pattern)

Step-by-step flow for a user funding a contract (e.g., payroll, escrow, vault):

```
Step 1: User sets the contract as operator on the token
  → token.setOperator(contractAddress, expiryTimestamp)

Step 2: User calls the contract's funding function with encrypted amount
  → contract.fund(externalEuint64 encAmount, bytes proof)

Step 3: Inside the contract:
  a) euint64 amount = FHE.fromExternal(encAmount, proof)  // Contract gets ACL
  b) FHE.allowTransient(amount, address(token))            // Token can read handle
  c) token.confidentialTransferFrom(user, address(this), amount)  // Pull tokens
  d) FHE.allowThis(storedAmount)                           // Contract stores handle
  e) FHE.allow(storedAmount, user)                         // User can decrypt

Step 4: Contract pays out later (e.g., batch payroll):
  a) FHE.allowTransient(salary, address(token))            // Token can read handle
  b) token.confidentialTransfer(employee, salary)           // Send from contract balance
```

**Key**: Step 1 (setOperator) must happen in a separate transaction BEFORE Step 2. The operator model is time-based — no amount cap.

## Amount Disclosure

ERC-7984 includes a disclosure mechanism for revealing encrypted amounts:

```solidity
// Step 1: Request disclosure (marks handle as publicly decryptable)
token.requestDiscloseEncryptedAmount(encryptedAmount);
// Emits: AmountDiscloseRequested(encryptedAmount, msg.sender)

// Step 2: Fulfill with KMS proof
token.discloseEncryptedAmount(encryptedAmount, cleartextAmount, decryptionProof);
// Emits: AmountDisclosed(encryptedAmount, cleartextAmount)
```

## Available Extensions

| Extension | Import | Description |
|-----------|--------|-------------|
| `ERC7984ERC20Wrapper` | `.../extensions/ERC7984ERC20Wrapper.sol` | Wrap ERC-20 ↔ ERC-7984 |
| `ERC7984Votes` | `.../extensions/ERC7984Votes.sol` | Confidential vote delegation |
| `ERC7984Freezable` | `.../extensions/ERC7984Freezable.sol` | Per-account frozen balances |
| `ERC7984Restricted` | `.../extensions/ERC7984Restricted.sol` | Blocklist/allowlist restrictions |
| `ERC7984ObserverAccess` | `.../extensions/ERC7984ObserverAccess.sol` | Permanent ACL observer |
| `ERC7984Omnibus` | `.../extensions/ERC7984Omnibus.sol` | Sub-accounts with encrypted addresses |
| `ERC7984Rwa` | `.../extensions/ERC7984Rwa.sol` | Full RWA compliance |

All extensions are at: `@openzeppelin/confidential-contracts/token/ERC7984/extensions/`

### ERC7984Votes — Governance Token Extension

For DAO/governance use cases, extend `ERC7984Votes` to enable encrypted vote delegation:

```solidity
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {ERC7984Votes} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984Votes.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract GovernanceToken is ZamaEthereumConfig, ERC7984, ERC7984Votes, Ownable2Step {
    constructor(address owner_)
        ERC7984("GovToken", "GOV", "https://example.com/gov.json")
        Ownable(owner_)
    {}

    function mint(address to, uint64 amount) external onlyOwner {
        _mint(to, FHE.asEuint64(amount));
    }

    // ERC7984Votes provides:
    // - delegate(address delegatee) — delegate votes
    // - getVotes(address account) — encrypted vote weight
    // - getPastVotes(address account, uint256 blockNumber) — historical snapshots
}
```

This is the **recommended approach** for governance tokens. The DAO contract reads vote weight via `token.getVotes(voter)` instead of trying to read `confidentialBalanceOf` (which has ACL restrictions).

## Events for Confidential Tokens

```solidity
// ERC-7984 standard events:
event ConfidentialTransfer(address indexed from, address indexed to, euint64 indexed amount);
event OperatorSet(address indexed holder, address indexed operator, uint48 until);
event AmountDisclosed(euint64 indexed encryptedAmount, uint64 amount);

// NOT like ERC-20:
// event Transfer(address from, address to, uint256 amount);  // WRONG for ERC-7984
```

## FHESafeMath Utility

OpenZeppelin provides safe encrypted math:

```solidity
import {FHESafeMath} from "@openzeppelin/confidential-contracts/utils/FHESafeMath.sol";

// Returns (success, result) — success is ebool (encrypted)
(ebool ok, euint64 sum) = FHESafeMath.tryAdd(a, b);
(ebool ok, euint64 diff) = FHESafeMath.trySub(a, b);
(ebool ok, euint64 increased) = FHESafeMath.tryIncrease(oldValue, delta);
(ebool ok, euint64 decreased) = FHESafeMath.tryDecrease(oldValue, delta);
```

The base `ERC7984._update()` uses `tryDecrease`/`tryIncrease` internally for safe transfers.
