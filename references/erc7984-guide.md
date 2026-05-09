# ERC-7984: Confidential Token Standard

> **Quick imports** (memorize these — they trip up most newcomers):
> ```solidity
> // Implementation base (your token contract extends this):
> import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
>
> // Interface for cross-contract use (escrow / vault / DEX → token):
> import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
>
> // For wrapping plain ERC-20 → ERC-7984:
> import {ERC7984ERC20Wrapper} from "@openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984ERC20Wrapper.sol";
>
> // Receiver hook (ERC-7984 callback target):
> import {IERC7984Receiver} from "@openzeppelin/confidential-contracts/interfaces/IERC7984Receiver.sol";
>
> // Safe encrypted math:
> import {FHESafeMath} from "@openzeppelin/confidential-contracts/utils/FHESafeMath.sol";
> ```

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

Use the `ERC7984ERC20Wrapper` extension. The wrapper class itself already
provides full implementations of `decimals()`, `supportsInterface()`, and
`_update()`, so a thin subclass that adds NOTHING needs **no overrides**:

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

**Multi-extension override tip:** Only when you stack a *second* extension
(e.g. `ERC7984ERC20Wrapper, ERC7984Votes`) does Solidity require explicit
overrides. The signature in that case lists *both* extensions:

```solidity
function _update(address from, address to, euint64 amount)
    internal override(ERC7984ERC20Wrapper, ERC7984Votes) returns (euint64)
{
    return super._update(from, to, amount);
}
```

> **Verified against `@openzeppelin/confidential-contracts@0.4.0`**:
> `ERC7984ERC20Wrapper.decimals()` is declared `override(IERC7984, ERC7984)`
> (line 138 of `ERC7984ERC20Wrapper.sol`). A subclass that adds no other
> extensions inherits the wrapper's `decimals()` directly — no re-override
> needed.

### ERC7984ERC20Wrapper Function Signatures

```solidity
// Wrap: pulls underlying ERC-20 (rounded down to a multiple of rate()),
//       mints `amount / rate()` confidential tokens to `to`. Returns the
//       encrypted minted amount (transient ACL granted to msg.sender).
function wrap(address to, uint256 amount) public virtual returns (euint64);
// User must first: underlying.approve(wrapperAddress, amount)

// Unwrap (2 overloads) — returns the unwrap request ID (bytes32)
function unwrap(address from, address to, euint64 amount) public virtual returns (bytes32);
function unwrap(address from, address to, externalEuint64 encryptedAmount, bytes calldata inputProof) public virtual returns (bytes32);
// Burns encrypted tokens, calls makePubliclyDecryptable, stores unwrap request

// Finalize: anyone can call after KMS decrypts. Note: requestId is bytes32, NOT uint256.
function finalizeUnwrap(bytes32 unwrapRequestId, uint64 unwrapAmountCleartext, bytes calldata decryptionProof) public virtual;
// Verifies proof via checkSignatures, transfers `unwrapAmountCleartext * rate()` underlying to recipient

// View:
function underlying() external view returns (address);   // The wrapped ERC-20
function rate()       external view returns (uint256);   // Scaling divisor — see below
function decimals()   external view returns (uint8);     // = min(underlyingDecimals, 6)
```

### ⚠ CRITICAL: `wrap`/`unwrap` Use a Decimal-Scaling `rate()`

`ERC7984` uses `euint64` for balances, which caps at `~1.8 × 10¹⁹`. Most ERC-20
tokens have 18 decimals → `1` token = `10¹⁸` raw units, far exceeding euint64
range over realistic supplies. The wrapper handles this by *scaling down*:

```solidity
// Constructor (paraphrased from ERC7984ERC20Wrapper.sol:35-46):
uint8 maxDec = _maxDecimals();              // = 6 by default
uint8 underlyingDec = underlying.decimals();
if (underlyingDec > maxDec) {
    _decimals = maxDec;                     // wrapper exposes 6 decimals
    _rate     = 10**(underlyingDec - maxDec); // e.g. 10**12 for 18-dec USDC
} else {
    _decimals = underlyingDec;              // already small enough
    _rate     = 1;
}
```

Consequences for the `wrap()` caller — first table is the **same `amount`
across different underlyings**, second is the **uint64-overflow boundary**:

| Underlying | Underlying decimals | `rate()` | `wrap(user, 10¹⁸)` mint result |
|---|---|---|---|
| 18-dec ERC-20 | 18 | 10¹² | mints `10⁶` confidential units = "1.000000" wrapped |
| 6-dec ERC-20 (real USDC) | 6 | 1 | mints `10¹⁸` raw — **overflows uint64** (max ~1.844 × 10¹⁹, but 10¹⁸ < that, so **OK at 10¹⁸ specifically**; overflows above ~1.844 × 10¹⁹) |
| 4-dec ERC-20 | 4 | 1 | mints `10¹⁸` raw — same as 6-dec (rate=1) |

The actual `SafeCast.toUint64` revert threshold is `amount / rate() ≥ 2⁶⁴ ≈
1.844 × 10¹⁹`. For `rate=1` underlyings (≤6 decimals), the caller must keep
total `amount` below `2⁶⁴` raw units. For `rate=10¹²` underlyings (18-dec),
the caller can pass up to `2⁶⁴ × 10¹² ≈ 1.844 × 10³¹` raw units before the
mint reverts.

The 18-dec case is the most common surprise. Calling `wrap(user, 1_000_000)`
on a wrapper over an 18-decimal token mints **0** confidential tokens
(`1_000_000 / 10¹² = 0`), pulls 0 underlying (`amount - amount % rate() = 0`),
and **leaves the entire 1_000_000 wei in the caller's wallet** (it is never
pulled — `safeTransferFrom(... , 0)` is a no-op). The user sees a successful
tx and zero balance change on both sides — the worst kind of silent failure.
Reading the source once:

```solidity
// ERC7984ERC20Wrapper.sol:82-91 (confirmed)
function wrap(address to, uint256 amount) public virtual override returns (euint64) {
    SafeERC20.safeTransferFrom(IERC20(underlying()), msg.sender, address(this),
                               amount - (amount % rate()));
    euint64 wrappedAmountSent = _mint(to, FHE.asEuint64(SafeCast.toUint64(amount / rate())));
    FHE.allowTransient(wrappedAmountSent, msg.sender);
    return wrappedAmountSent;
}
```

**Frontend rule of thumb:** when prompting the user for an "amount to wrap",
treat the input as confidential-token units (6 decimals by default) and pass
`uiAmount * rate()` to `wrap()`. For 1 wrapped USDC over an 18-dec underlying:

```ts
const rate = await wrapper.rate();          // 10n ** 12n
const wantConfidential = 1_000_000n;        // 1.000000 wrapped (6-dec)
await underlying.approve(wrapperAddress, wantConfidential * rate);   // 10**18 wei
await wrapper.wrap(userAddress, wantConfidential * rate);
```

`finalizeUnwrap` applies the inverse scaling: `unwrapAmountCleartext * rate()`
underlying ERC-20 are sent to the recipient (`ERC7984ERC20Wrapper.sol:132`).

### Wrap: ERC-20 → ERC-7984

```solidity
uint256 rate = wrapper.rate();           // discover scaling first
uint256 wantConfidential = 1_000_000;    // 1.000000 in 6-dec wrapped units
uint256 underlyingAmount = wantConfidential * rate;

// Step 1: User approves wrapper to spend their ERC-20
underlying.approve(wrapperAddress, underlyingAmount);

// Step 2: Wrap — locks ERC-20, mints `wantConfidential` confidential tokens to user
wrapper.wrap(userAddress, underlyingAmount);
```

> **Single-tx alternative (ERC-1363):** if the underlying token implements
> `ERC1363`, calling `underlying.transferAndCall(wrapperAddress, amount, data)`
> hits the wrapper's `onTransferReceived` callback and wraps in one tx — no
> separate `approve` step. The recipient is decoded from `data` (first 20
> bytes), defaulting to the original sender. See
> `ERC7984ERC20Wrapper.sol:54-73`.

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
                                                                  // ↑ no-proof overload
                                                                  //   confidentialTransferFrom(address,address,euint64)
  d) FHE.allowThis(storedAmount)                           // Contract stores handle
  e) FHE.allow(storedAmount, user)                         // User can decrypt

Step 4: Contract pays out later (e.g., batch payroll, scheduled withdrawal):
  a) FHE.allowTransient(salary, address(token))            // Token can read handle
  b) token.confidentialTransfer(employee, salary)           // Send from contract balance
                                                            // ↑ no-proof overload
                                                            //   confidentialTransfer(address,euint64)
```

**Key**: Step 1 (setOperator) must happen in a separate transaction BEFORE Step 2. The operator model is time-based — no amount cap.

**Use the no-proof overloads inside the contract.** The 2-arg
`confidentialTransfer(address,euint64)` and 3-arg
`confidentialTransferFrom(address,address,euint64)` overloads take an existing
`euint64` handle — no re-encryption, no `bytes proof` argument. Reaching for
`externalEuint64` + `proof` from inside a contract is a sign you're doing it
wrong: a contract cannot produce a fresh user-bound proof. Encrypted inputs
(and their proofs) only originate from the user's wallet via the Relayer SDK.

### Foot-gun: Plaintext-Priced Pulls (Auctions, Order Books)

When the contract holds the **price as plaintext** (e.g., a fixed reserve
price, an auction settled at a publicly-revealed clearing price) but pulls the
**token amount as an `euint64` handle**, the bridge between the two is
`FHE.asEuint64(plaintextPrice)` followed by `allowTransient`:

```solidity
// Settlement: winner pays plaintext clearing price, contract pulls ERC-7984
function settle(address winner, uint64 clearingPrice) external onlyOwner {
    // ❌ WRONG: passing the plaintext directly to confidentialTransferFrom does not
    //          compile — the no-proof overload's third arg is euint64, not uint64.
    // token.confidentialTransferFrom(winner, address(this), clearingPrice);

    // ❌ WRONG: encrypting in storage without allowTransient — token can't read it.
    // euint64 enc = FHE.asEuint64(clearingPrice);
    // token.confidentialTransferFrom(winner, address(this), enc);   // silent 0 transfer

    // ✓ CORRECT
    euint64 enc = FHE.asEuint64(clearingPrice);
    FHE.allowThis(enc);                            // contract keeps ACL
    FHE.allowTransient(enc, address(token));       // token reads it for this tx
    euint64 paid = token.confidentialTransferFrom(winner, address(this), enc);
    FHE.allowThis(paid);
}
```

The same trap appears in any pattern where a known-plaintext amount drives an
encrypted-token pull: bond redemptions, fixed-fee payouts, slashing penalties.
The contract owner has the price in clear, but the token only speaks `euint64`.

**Rule of thumb:** if you have a `uint64` and need to call ERC-7984, the
sequence is always `FHE.asEuint64` → `FHE.allowThis` → `FHE.allowTransient(_, token)`
→ overload-without-proof.

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

### Other @openzeppelin/confidential-contracts Modules

Beyond ERC-7984 extensions, the package includes:

```solidity
// Finance
import {VestingWalletConfidential} from "@openzeppelin/confidential-contracts/finance/VestingWalletConfidential.sol";
import {VestingWalletCliffConfidential} from "@openzeppelin/confidential-contracts/finance/VestingWalletCliffConfidential.sol";
import {VestingWalletConfidentialFactory} from "@openzeppelin/confidential-contracts/finance/VestingWalletConfidentialFactory.sol";
import {BatcherConfidential} from "@openzeppelin/confidential-contracts/finance/BatcherConfidential.sol";

// Governance base (used by ERC7984Votes)
import {VotesConfidential} from "@openzeppelin/confidential-contracts/governance/utils/VotesConfidential.sol";

// Utilities
import {HandleAccessManager} from "@openzeppelin/confidential-contracts/utils/HandleAccessManager.sol";
import {CheckpointsConfidential} from "@openzeppelin/confidential-contracts/utils/structs/CheckpointsConfidential.sol";
import {ERC7984Utils} from "@openzeppelin/confidential-contracts/token/ERC7984/utils/ERC7984Utils.sol";
```

**VestingWalletConfidential**: Drop-in confidential vesting wallet with encrypted amounts. No need to write custom vesting logic.

**HandleAccessManager**: Helper for managing ACL permissions across multiple contracts.

**BatcherConfidential**: Batch multiple confidential operations into one transaction.

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
    // - getPastVotes(address account, uint256 timepoint) — historical snapshots (ERC-6372 clock)
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
