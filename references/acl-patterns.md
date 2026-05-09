# FHEVM Access Control (ACL) Patterns

## Overview

Every encrypted value (handle) in FHEVM has an Access Control List (ACL) that determines who can use it. If a contract or user doesn't have ACL permission for a handle, any operation using that handle will fail.

## Core ACL Functions

### `FHE.allow(value, account)` — Persistent Access

Grants **persistent** read access to an account. Stored in the ACL contract's storage. Survives across transactions.

```solidity
FHE.allow(euint64 value, address account) returns (euint64)
```

**When to use**: When the value is stored in state and the account needs to access it in future transactions.

```solidity
balances[user] = FHE.add(balances[user], amount);
FHE.allow(balances[user], user);  // User can decrypt in future tx
```

### `FHE.allowThis(value)` — Contract Self-Access

Shorthand for `FHE.allow(value, address(this))`. Lets the current contract use the handle in future transactions.

```solidity
FHE.allowThis(euint64 value) returns (euint64)
```

**When to use**: ALWAYS after any FHE operation that produces a value stored in contract state.

```solidity
_totalSupply = FHE.add(_totalSupply, mintAmount);
FHE.allowThis(_totalSupply);  // CRITICAL: without this, contract can't use _totalSupply later
```

### `FHE.allowTransient(value, account)` — Same-Transaction Access

Grants **transient** access using EIP-1153 transient storage. Automatically cleared at the end of the transaction. Cheaper gas than `allow`.

```solidity
FHE.allowTransient(euint64 value, address account) returns (euint64)
```

**When to use**: When passing encrypted values to another contract within the same transaction.

```solidity
// Before calling another contract that needs to read this handle:
FHE.allowTransient(encAmount, address(tokenContract));
tokenContract.confidentialTransfer(recipient, encAmount);
```

### `FHE.makePubliclyDecryptable(value)` — Public Decryption

Marks a handle so anyone can request its decryption through the KMS.

```solidity
FHE.makePubliclyDecryptable(euint64 value) returns (euint64)
```

**When to use**: When a value needs to be revealed publicly (e.g., auction result, vote tally, unwrap amount).

```solidity
function revealWinner() external onlyOwner {
    FHE.makePubliclyDecryptable(highestBid);
    emit RevealRequested(FHE.toBytes32(highestBid));
}
```

## ACL Check Functions (View / Pure)

`FHE.sol` exposes a small set of state-mutation-free helpers you can safely call
from `view` (and one `pure`) functions:

```solidity
// Pure — no state read at all (handle equals bytes32(0) check):
FHE.isInitialized(euintX|ebool|eaddress v) returns (bool)

// View — read the on-chain ACL contract:
FHE.isAllowed(euintX|ebool|eaddress value, address account) returns (bool)
FHE.isSenderAllowed(euintX|ebool|eaddress value)            returns (bool)  // checks msg.sender
FHE.isPubliclyDecryptable(euintX|ebool|eaddress value)      returns (bool)
FHE.isAccountDenied(address account)                        returns (bool)
FHE.isUserDecryptable(bytes32 handle, address user, address contractAddress) returns (bool)
FHE.isDelegatedForUserDecryption(...)                       returns (bool)
FHE.getDelegatedUserDecryptionExpirationDate(...)           returns (uint256)
```

These are the **only** state-free helpers in `FHE.sol`. Every other call (add,
sub, mul, select, eq, gt, fromExternal, asEuintX, makePubliclyDecryptable, …)
routes through the coprocessor and counts as state-changing — so you can freely
use the checks above inside `view`/`pure` getters, but you cannot combine them
with arithmetic or `select` and still keep the function `view`.

Use them for access control in getter functions:

```solidity
function getBalance(address user) external view returns (euint64) {
    require(FHE.isAllowed(balances[user], msg.sender), "Not authorized");
    return balances[user];
}
```

> **Important:** `FHE.isAllowed` checks the on-chain ACL set by
> `FHE.allowThis`/`FHE.allow`/`FHE.makePubliclyDecryptable`. It does **not**
> attempt decryption, does **not** call the coprocessor, and does **not**
> mutate state — that's why it can be used in `view` functions. A common
> misconception is that this check "leaks" whether the caller has access; it
> doesn't, because the ACL itself is public information (the same value is
> visible from off-chain via the ACL contract's events). The confidentiality
> guarantee covers the *plaintext value*, not the access list.

> **`isInitialized` pure-vs-view nuance:** `FHE.isInitialized(handle)` is
> declared `pure` because it only inspects the handle's *value* (`handle ==
> bytes32(0)`) — it never reads contract storage or the ACL. But the storage
> read that *produced* that handle still happens in the calling function. So:
> ```solidity
> // ❌ Won't work as you'd expect — `pure` cannot read storage
> function check(address u) external pure returns (bool) {
>     return FHE.isInitialized(_balances[u]); // compile error: pure can't access state
> }
>
> // ✓ Correct — `view` reads the storage slot, then passes the loaded handle
> //   into the pure check
> function check(address u) external view returns (bool) {
>     return FHE.isInitialized(_balances[u]);
> }
> ```
> Rule of thumb: getters that consult `isInitialized` on a stored mapping/state
> handle must be `view`, not `pure`.

## Lazy-Init Mapping Handles (First-Touch Pattern)

A user-keyed mapping defaults to the zero handle — `bytes32(0)`. You **cannot**
`FHE.add(uninitialized, x)` without first checking, because the zero handle has
no ACL and no encrypted value behind it. The canonical accumulator idiom:

> **"Check after deref" is the correct order, not a bug.** Reading an
> uninitialized mapping slot returns the zero handle, which is a valid input
> to `FHE.isInitialized()` (the function returns `false` for it). Loading the
> slot first, then branching on `isInitialized`, is the canonical pattern —
> not a defensive workaround. Some readers expect "check before deref" by
> analogy with null-pointer guards in other languages; that's not how euint
> handles work.

```solidity
mapping(address => euint64) private _balances;

function deposit(externalEuint64 enc, bytes calldata proof) external {
    euint64 amount = FHE.fromExternal(enc, proof);

    // Branch on the HANDLE (plaintext-level branching is fine — it's not
    // branching on encrypted data). `isInitialized` is pure, so this is free.
    euint64 prev = _balances[msg.sender];
    euint64 next = FHE.isInitialized(prev)
        ? FHE.add(prev, amount)     // accumulator path
        : amount;                   // first-touch — store the increment directly

    _balances[msg.sender] = next;
    FHE.allowThis(next);
    FHE.allow(next, msg.sender);
}
```

This is the single most common mapping-side accumulator pattern in any
ledger-shaped contract (vault, AMM, payroll, treasury). Use it any time a
`mapping(address => euintX)` slot may be touched for the first time.

Alternative if you want `isInitialized` semantics without the branch (slightly
more gas): seed every account on first interaction via a dedicated
`_initialize(address)` helper that sets `_balances[user] = FHE.asEuint64(0)`
plus the ACL triple. Pick whichever fits the protocol's UX better.

## Publicly-Readable, ACL-Gated Pattern (Hidden TVL / Reveal-on-Demand)

Sometimes you want a handle to be **publicly readable** (any caller can fetch
the `bytes32` handle from a getter) but **decryption-gated** (only specific
users can ask the relayer to decrypt it). Examples: AMM TVL that the protocol
hides until a periodic reveal; auction reserves visible to the auctioneer but
hidden from bidders.

The pattern composes three primitives:

```solidity
// State (encrypted)
euint64 private _reserveA;

// 1. Anyone can read the HANDLE — no ACL needed for raw storage reads
function reserveAHandle() external view returns (bytes32) {
    return FHE.toBytes32(_reserveA);
}

// 2. Owner-gated: extend decrypt rights to a specific user
function allowReserveTo(address user) external onlyOwner {
    FHE.allow(_reserveA, user);   // persistent — survives across tx boundaries
}

// 3. Owner-gated: open the gates fully
function revealReserves() external onlyOwner {
    FHE.makePubliclyDecryptable(_reserveA);
    // From here, anyone can `relayer.publicDecrypt([reserveAHandle()])`
}
```

UX consequence: a frontend that calls `relayer.userDecrypt(...)` on a handle
the caller hasn't been granted ACL for **gets a relayer rejection**, not a
contract revert. Display this as "Hidden until reveal" rather than as an
error state.

## The Mandatory ACL Pattern

**The skill describes three different ACL flows. Each is correct for its scenario; the orderings differ on purpose.** Pick by the question "where will this handle be consumed next?":

| Scenario | Where | Ordering |
|---|---|---|
| **Self-storage** (handle stays in *this* contract) | this section | op → `allowThis(new)` → `allow(new, user)` |
| **Cross-contract pull/push** (handle is consumed by another contract in the same tx) | [Cross-Contract ACL Pattern](#cross-contract-acl-pattern) below + [erc7984-guide.md § Cross-Contract](erc7984-guide.md) | `allowTransient(arg, target)` → call → `allowThis(returned)` → `allow(returned, user)` |
| **Public reveal** (handle is going to KMS for `publicDecrypt`) | [decryption-guide.md § Public Decryption](decryption-guide.md) | `makePubliclyDecryptable(handle)` — no `allow` needed |

The three flows can chain inside a single function (e.g. an escrow that pulls in via cross-contract, stores via self-storage, and later reveals publicly).

### Self-storage flow

**Every time you create or modify an encrypted value that will be stored in this contract:**

```solidity
// Step 1: Perform the FHE operation
balances[user] = FHE.add(balances[user], amount);

// Step 2: Allow the contract itself (for future transactions)
FHE.allowThis(balances[user]);

// Step 3: Allow the relevant user(s)
FHE.allow(balances[user], user);
```

**Forgetting Step 2 is the #1 FHEVM bug.** The contract creates a new handle but loses access to it. (For a cross-contract input or a publicly-decryptable output, see the table above for the right ordering.)

## Cross-Contract ACL Pattern

When Contract A needs to pass an encrypted value to Contract B within a single transaction:

```solidity
contract Escrow {
    IERC7984 public token;

    function deposit(euint64 amount) external {
        // 1. Verify caller has access to the handle
        require(FHE.isSenderAllowed(amount), "Not allowed");

        // 2. Grant transient access to the token contract (same tx only)
        FHE.allowTransient(amount, address(token));

        // 3. Execute the cross-contract call
        euint64 transferred = token.confidentialTransferFrom(
            msg.sender, address(this), amount
        );

        // 4. Grant persistent access to this contract (for future use)
        FHE.allow(transferred, address(this));
        FHE.allowThis(transferred);

        // 5. Store the handle
        deposits[msg.sender] = transferred;
    }
}
```

**Key insight**: Use `allowTransient` for Step 2 (cheaper, same-tx only) and `allow`/`allowThis` for Step 4 (persistent, needed later).

### How `allowTransient` and `isSenderAllowed` Work Together

This is a common source of confusion in cross-contract calls. Here's the exact flow:

```
DEX contract has handle `amount` (from FHE.fromExternal or storage with allowThis)
  │
  ├─ DEX already has ACL access to `amount` (it created or stored it)
  │
  ├─ DEX calls: FHE.allowTransient(amount, address(token))
  │   └─ This grants the TOKEN CONTRACT access to the handle
  │      (so the token can do FHE operations like sub/add on it)
  │
  └─ DEX calls: token.transferFrom(user, dex, amount)
      └─ Inside the token: msg.sender = DEX
         └─ token checks: FHE.isSenderAllowed(amount)
            └─ This checks if the DEX has access → YES (DEX created/stored the handle)
         └─ token does: FHE.sub(balances[from], amount)
            └─ Token needs access to `amount` to do FHE math → YES (allowTransient granted it)
```

**Summary**: `isSenderAllowed` checks if the CALLER (DEX) has access — it does because it created the handle. `allowTransient` grants the TARGET CONTRACT (token) access so it can perform FHE operations on the handle. Both are needed for different reasons.

### Contract Pays User Pattern (from contract's own balance)

When a contract holds encrypted tokens and needs to pay a user (e.g., payroll, auction refund, lending withdrawal):

```solidity
contract Payroll {
    IConfidentialERC20 public token;
    mapping(address => euint64) public salaries;

    function payEmployee(address employee) external onlyOwner {
        euint64 salary = salaries[employee];

        // 1. Grant the token contract transient access to the salary handle
        //    (so it can do FHE math inside its _transfer function)
        FHE.allowTransient(salary, address(token));

        // 2. Call transfer — sends FROM this contract's token balance TO employee
        //    msg.sender = this contract (which holds the tokens)
        token.transfer(employee, salary);
    }
}
```

**This is different from the escrow deposit pattern** where the user approves first. Here the contract already holds the tokens and pays out directly. The key is that `FHE.allowTransient(salary, address(token))` gives the token contract access to the salary handle for the FHE operations inside `_transfer`.

### Cross-Contract Encrypted Balance Reading (DAO/Governance Pattern)

When a contract (e.g., DAO) needs to read a user's encrypted token balance as vote weight:

**Problem**: `token.confidentialBalanceOf(user)` returns a handle, but the DAO contract has NO ACL access to that handle — only the user and the token contract do.

**Solutions**:

```solidity
// Option A: User submits their balance as an encrypted input (simplest)
// User reads their own balance off-chain, then submits it to the DAO
function vote(uint256 proposalId, externalEbool encVote, externalEuint64 encWeight, bytes calldata proof) external {
    ebool voteChoice = FHE.fromExternal(encVote, proof);
    euint64 weight = FHE.fromExternal(encWeight, proof);
    // DAO now has ACL on weight (fromExternal grants it)
    // Downside: user could lie about their weight
}

// Option B: Use ERC7984Votes extension (recommended for governance)
// @openzeppelin/confidential-contracts/token/ERC7984/extensions/ERC7984Votes.sol
// Provides encrypted vote delegation with getVotes() that respects ACL
// See erc7984-guide.md for details

// Option C: Token grants DAO access via operator + snapshot
// User sets DAO as operator, DAO reads balance via token's internal function
// Requires custom token extension with a "grantBalanceAccess" function
```

**Recommendation**: Use `ERC7984Votes` extension for governance. It handles encrypted vote weight delegation natively.

## User Decryption Delegation

For account abstraction or backend services that need to decrypt on behalf of a user.

**Delegation constraints (FHE.sol v0.11.1)**: All `delegateUserDecryption*` functions have these requirements:
- `expirationDate` must be at least **1 hour in the future** (`expirationDate >= block.timestamp + 1 hours`)
- Cannot delegate OR revoke more than once per block for the same `(delegator, delegate, contractAddress)` tuple
- `contractAddress` cannot equal `address(this)` (the delegator)
- `delegate` cannot equal `address(this)` (the delegator)
- `delegate` cannot equal `contractAddress`
- The delegator is `address(this)` — the **contract** calling delegateUserDecryption, not a user directly

### On-Chain Setup (called by the contract holding the encrypted data)

```solidity
// Grant a delegate permission to decrypt, with expiration
FHE.delegateUserDecryption(
    address delegate,
    address contractAddress,
    uint64 expirationDate        // Unix timestamp
);

// Without expiration
FHE.delegateUserDecryptionWithoutExpiration(
    address delegate,
    address contractAddress
);

// Batch delegation for multiple contracts
FHE.delegateUserDecryptions(
    address delegate,
    address[] memory contractAddresses,
    uint64 expirationDate
);

// Revoke delegation
FHE.revokeUserDecryptionDelegation(address delegate, address contractAddress);
FHE.revokeUserDecryptionDelegations(address delegate, address[] memory contractAddresses);
```

### Check Delegation Status

```solidity
// Check if a handle is user-decryptable
FHE.isUserDecryptable(bytes32 handle, address user, address contractAddress) returns (bool)

// Check if delegation exists
FHE.isDelegatedForUserDecryption(
    address delegator,
    address delegate,
    address contractAddress,
    bytes32 handle
) returns (bool)

// Get delegation expiration
FHE.getDelegatedUserDecryptionExpirationDate(
    address delegator,
    address delegate,
    address contractAddress
) returns (uint64)
```

## Deny List

```solidity
FHE.isAccountDenied(address account) returns (bool)
```

Check if an account is on the global deny list before processing FHE operations.

## Transient Storage Cleanup

```solidity
FHE.cleanTransientStorage()
```

Manually clears all transient ACL entries. Useful for Account Abstraction bundled UserOperations where multiple operations share a transaction context.

## Common ACL Mistakes

### Mistake 1: Forgetting allowThis

```solidity
// WRONG
balances[user] = FHE.add(balances[user], amount);
// Contract loses access to balances[user] in next tx!

// CORRECT
balances[user] = FHE.add(balances[user], amount);
FHE.allowThis(balances[user]);
FHE.allow(balances[user], user);
```

### Mistake 2: Using allow when allowTransient suffices

```solidity
// WASTEFUL: persistent storage write for single-tx use
FHE.allow(tempValue, address(otherContract));
otherContract.process(tempValue);

// BETTER: transient storage, cheaper gas
FHE.allowTransient(tempValue, address(otherContract));
otherContract.process(tempValue);
```

### Mistake 3: Not allowing the recipient in transfers

```solidity
// WRONG: recipient can't decrypt their new balance
balances[to] = FHE.add(balances[to], amount);
FHE.allowThis(balances[to]);
// Missing: FHE.allow(balances[to], to);

// CORRECT
balances[to] = FHE.add(balances[to], amount);
FHE.allowThis(balances[to]);
FHE.allow(balances[to], to);
```

### Mistake 4: Assuming ACL carries over after FHE operations

```solidity
// Each FHE operation produces a NEW handle with NO permissions
euint64 oldBalance = balances[user];  // Has ACL for user and contract
euint64 newBalance = FHE.add(oldBalance, amount);  // NEW handle, NO ACL
// Must re-grant permissions:
FHE.allowThis(newBalance);
FHE.allow(newBalance, user);
balances[user] = newBalance;
```
