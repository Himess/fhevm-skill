# `@zama-fhe/sdk` 3.0 — Integration Guide

> **The new default frontend SDK for FHEVM.** Released April 2026. High-level
> Token API + viem/ethers adapters + IndexedDB key cache. Replaces hand-wired
> `@zama-fhe/relayer-sdk` calls for typical confidential-token apps.
>
> **When to use which SDK:**
> - **`@zama-fhe/sdk` 3.x** — new apps, ERC-7984 confidential tokens, browser/Node.
> - **`@zama-fhe/relayer-sdk` 0.4.x** — Hardhat tests, custom non-token contracts,
>   manual encryption pipelines, or anything requiring direct `RelayerSDKType`.
> - **TFHE / `fhevmjs`** — **deprecated, do not use.** Both are flagged by
>   `scripts/fhevm-lint.js` rule AP-013.

---

## 1. Install

```bash
# Browser / React app
npm install @zama-fhe/sdk viem
# or with ethers
npm install @zama-fhe/sdk ethers

# React hooks
npm install @zama-fhe/react-sdk @tanstack/react-query

# Node.js (server side)
npm install @zama-fhe/sdk
```

The package ships ESM + CJS builds and TypeScript types. Subpaths:

| Subpath                  | Exports                                              |
|--------------------------|------------------------------------------------------|
| `@zama-fhe/sdk`          | `ZamaSDK`, `RelayerWeb`, storage, configs, errors    |
| `@zama-fhe/sdk/viem`     | `ViemSigner`                                         |
| `@zama-fhe/sdk/ethers`   | `EthersSigner`                                       |
| `@zama-fhe/sdk/node`     | `RelayerNode` (server-side relayer)                  |
| `@zama-fhe/sdk/query`    | `@tanstack/react-query` adapter (used by react-sdk)  |
| `@zama-fhe/sdk/cleartext`| Plaintext value helpers (`ClearValueType`)           |

---

## 2. Browser quickstart (viem)

```ts
import { ZamaSDK, RelayerWeb, IndexedDBStorage, SepoliaConfig } from "@zama-fhe/sdk";
import { ViemSigner } from "@zama-fhe/sdk/viem";
import { sepolia } from "viem/chains";
import { createWalletClient, createPublicClient, custom, http } from "viem";

const walletClient = createWalletClient({
  chain: sepolia,
  transport: custom(window.ethereum!),
});
const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(),
});

const signer = new ViemSigner({ walletClient, publicClient });

const sdk = new ZamaSDK({
  relayer: new RelayerWeb({
    getChainId: () => signer.getChainId(),  // returns Promise<number>
    transports: {
      [sepolia.id]: {
        relayerUrl: SepoliaConfig.relayerUrl,
        network:    SepoliaConfig.network,
      },
    },
  }),
  signer,
  storage: new IndexedDBStorage(),
});

// 1. Wrap a public ERC-20 into confidential
const token = sdk.createToken("0xConfidentialErc20Address");
await token.shield(1_000n);

// 2. Read encrypted balance (auto-decrypts for caller)
const balance = await token.balanceOf();
console.log("balance:", balance);

// 3. Confidential transfer
await token.confidentialTransfer("0xRecipient", 500n);
```

**That's the entire flow.** No manual `createEncryptedInput`, no manual ACL,
no manual `requestDecryption`. The Token wrapper does it.

---

## 3. Node.js quickstart (ethers)

```ts
import { ZamaSDK, MainnetConfig } from "@zama-fhe/sdk";
import { RelayerNode } from "@zama-fhe/sdk/node";
import { EthersSigner } from "@zama-fhe/sdk/ethers";
import { JsonRpcProvider, Wallet } from "ethers";

const provider = new JsonRpcProvider(process.env.RPC_URL);
const wallet   = new Wallet(process.env.PRIVATE_KEY!, provider);
const signer   = new EthersSigner({ signer: wallet });

const sdk = new ZamaSDK({
  relayer: new RelayerNode({
    getChainId: () => signer.getChainId(),  // returns Promise<number>
    transports: {
      [MainnetConfig.chainId]: {
        relayerUrl: MainnetConfig.relayerUrl,
        network:    MainnetConfig.network,
      },
    },
  }),
  signer,
  storage: undefined, // in-memory by default on Node
});

const usdc = sdk.createToken("0x...");
const bal  = await usdc.confidentialBalanceOf();   // returns Handle (bytes32)
console.log("encrypted handle:", bal);
```

---

## 4. Network configs (verbatim, verified)

These are **JS objects** exported from `@zama-fhe/sdk`. Do **not** confuse with
the deprecated Solidity `SepoliaConfig` contract from
`@fhevm/solidity/config/ZamaConfig.sol` (which doesn't exist in 0.11.1 —
only `ZamaEthereumConfig` does; see `references/type-system.md`).

### `SepoliaConfig`

```ts
{
  chainId: 11155111,
  gatewayChainId: 10901,
  relayerUrl: "https://relayer.testnet.zama.org/v2",
  network:    "https://ethereum-sepolia-rpc.publicnode.com",
  aclContractAddress:                      "0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D",
  kmsContractAddress:                      "0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A",
  inputVerifierContractAddress:            "0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0",
  verifyingContractAddressDecryption:      "0x5D8BD78e2ea6bbE41f26dFe9fdaEAa349e077478",
  verifyingContractAddressInputVerification:"0x483b9dE06E4E4C7D35CCf5837A1668487406D955",
  registryAddress:                         "0x2f0750Bbb0A246059d80e94c454586a7F27a128e",
}
```

### `MainnetConfig`

Same shape, points at Ethereum mainnet + production Zama gateway. Import and
use; do **not** hard-code addresses — they change per release.

### `HardhatConfig`

For local hardhat-network mock chain (chainId 31337). Used internally by
`@fhevm/hardhat-plugin`.

---

## 5. `ZamaSDK` class — public API

Verified against the actual installed `@zama-fhe/sdk@3.0.0` distribution
(`dist/esm/activity-*.d.ts` lines 22284–22445):

```ts
class ZamaSDK {
  constructor(config: ZamaSDKConfig);

  // Readonly accessors
  readonly relayer:              RelayerSDK;
  readonly signer:               GenericSigner;
  readonly storage:              GenericStorage;
  readonly sessionStorage:       GenericStorage;
  readonly credentials:          CredentialsManager;
  readonly delegatedCredentials: DelegatedCredentialsManager;
  readonly cache:                DecryptCache;        // persistent decrypted-value cache
  readonly registry:             WrappersRegistry;    // auto-configured per chain

  // Factories
  createReadonlyToken(address: Address): ReadonlyToken;
  createToken(address: Address, wrapper?: Address): Token;
  createWrappersRegistry(
    registryAddresses?: Record<number, Address>
  ): WrappersRegistry;

  // Direct ACL / decrypt (when not going through Token)
  allow(contractAddresses: Address[]): Promise<void>;
  userDecrypt(handles: DecryptHandle[]): Promise<Record<Handle, ClearValueType>>;
  publicDecrypt(handles: Handle[]): Promise<PublicDecryptResult>;

  // Lifecycle
  revokeSession():     Promise<void>;   // wipe session signature for current signer
  dispose():           void;            // unsubscribe signer events; keep relayer
  terminate():         void;            // tear everything down
  [Symbol.dispose]():  void;            // TC39 explicit resource management
}
```

`PublicDecryptResult` is **NOT** an array — it's a record keyed by handle:

```ts
type PublicDecryptResult = {
  clearValues:           Readonly<Record<Handle, ClearValueType>>;  // object, not array
  decryptionProof:       Hex;
  abiEncodedClearValues: Hex;
};
```

So you read it via `result.clearValues[handle]`, *not* `result.clearValues[i]`.
`Handle` is `0x${string}` (bytes32 ciphertext handle from on-chain).
`ClearValueType` is `bigint | boolean | Address`.

The TC39 `using` syntax lets you scope an SDK instance to a block:

```ts
{
  using sdk = new ZamaSDK({ relayer, signer, storage });
  // ... do work ...
}  // sdk.terminate() runs here automatically
```

---

## 6. `Token` class — full API

`Token extends ReadonlyToken`. The `ReadonlyToken` half is read-only and
needs no signer; `Token` adds writes and needs a signer.

```ts
class ReadonlyToken {
  // Identity
  isConfidential(): Promise<boolean>;       // ERC-165 `IConfidentialFungibleToken`
  isWrapper():      Promise<boolean>;       // ERC-7984 wrapper detection
  name():           Promise<string>;
  symbol():         Promise<string>;
  decimals():       Promise<number>;

  // Balance reads
  balanceOf(owner?: Address):              Promise<bigint>;        // auto-decrypts
  confidentialBalanceOf(owner?: Address):  Promise<Handle>;        // raw bytes32

  // ACL
  allow():     Promise<void>;
  isAllowed(): Promise<boolean>;
  revoke(...contractAddresses: Address[]): Promise<void>;
}

class Token extends ReadonlyToken {
  // Transfers
  confidentialTransfer(
    to: Address,
    amount: bigint,
    options?: TransferOptions
  ): Promise<TransactionResult>;

  confidentialTransferFrom(
    from: Address,
    to:   Address,
    amount: bigint,
    callbacks?: TransferFromCallbacks
  ): Promise<TransactionResult>;

  // Operator approvals (ERC-7984 timed approvals)
  approve(spender: Address, until?: number): Promise<TransactionResult>;

  // Wrapper flows (ERC-20 ↔ ERC-7984)
  shield(amount: bigint, options?: ShieldOptions): Promise<TransactionResult>;
  unshield(amount: bigint, options?: UnshieldOptions): Promise<TransactionResult>;
  unshieldAll(callbacks?: UnshieldCallbacks): Promise<TransactionResult>;

  // Lower-level wrap primitives
  unwrap(amount: bigint):       Promise<TransactionResult>;
  unwrapAll():                  Promise<TransactionResult>;
  finalizeUnwrap(burnAmountHandle: Handle): Promise<TransactionResult>;
}
```

`TransactionResult` is `{ txHash: Hex; receipt: TransactionReceipt }`. The
receipt is already mined when the promise resolves — there is no `.wait()`
method to call.

---

## 7. `RelayerWeb` / `RelayerNode`

Thin transport over the Zama relayer HTTP API. Pass per-chain config:

```ts
new RelayerWeb({
  // Must return Promise<number>. Read on every operation so a single SDK
  // instance can follow a wallet that switches networks.
  getChainId: () => signer.getChainId(),  // signer.getChainId() returns Promise<number>
  transports: {
    11155111: { relayerUrl, network },
    1:        { relayerUrl, network }, // mainnet
  },
});
```

If you don't have a signer handy and want a fixed chain:

```ts
new RelayerWeb({
  getChainId: async () => 11155111,  // explicit Promise
  transports: { ... },
});
```

Don't memoize the result — the SDK calls this lazily before each operation
and re-initializes the worker if the value changes.

---

## 8. Storage backends

Cached values: KMS-issued user signature (so each session doesn't re-sign on
every decrypt), wrapper address discovery, and recent decrypt cache.

| Storage class            | Where it lives        | When to use            |
|--------------------------|-----------------------|------------------------|
| `IndexedDBStorage`       | Browser IndexedDB     | Default for browser    |
| `ChromeSessionStorage`   | Extension session API | MV3 extensions         |
| `MemoryStorage`          | In-memory only        | Tests, ephemeral apps  |
| (Node default)           | In-memory             | Server-side            |

```ts
import { IndexedDBStorage, MemoryStorage } from "@zama-fhe/sdk";

new ZamaSDK({ /* ... */, storage: new IndexedDBStorage() });
```

---

## 9. Direct user-decrypt (without Token)

When you have a custom contract that exposes encrypted handles directly:

```ts
const handle = await contract.read.encryptedScore([userAddress]);

// Tell the SDK we'll be decrypting handles owned by this contract
await sdk.allow([contract.address]);

const result = await sdk.userDecrypt([{ handle, contractAddress: contract.address }]);
console.log(result[handle]); // bigint | boolean | Address
```

For globally-public values (e.g. winner reveal), use `publicDecrypt`. The
contract must have called `FHE.makePubliclyDecryptable(handle)` on-chain
first — see `references/decryption-guide.md` §3.

---

## 10. Migration map: `relayer-sdk` 0.4.x → `sdk` 3.x

| 0.4.x (relayer-sdk)                              | 3.x (sdk)                                        |
|--------------------------------------------------|--------------------------------------------------|
| `createInstance(SepoliaConfig)`                  | `new ZamaSDK({ relayer, signer, storage })`      |
| `instance.createEncryptedInput(addr, user)`      | hidden inside `Token.shield()` / `confidentialTransfer()` |
| `input.add64(n); await input.encrypt()`          | hidden inside `Token` methods                    |
| `instance.userDecrypt(handles, ...)`             | `sdk.userDecrypt(handles)` or `Token.balanceOf()`|
| `instance.publicDecrypt(handles)`                | `sdk.publicDecrypt(handles)`                     |
| `instance.generateKeypair()` + EIP-712 sign loop | handled internally, cached in storage            |
| Manual ACL on every read                         | `Token.allow()` once per (token, user) pair      |

If you're writing a Hardhat test, **stay on `relayer-sdk` 0.4.x** — it's what
`@fhevm/hardhat-plugin@0.4.2` integrates with via `fhevm.userDecryptEuint(...)`.

---

## 11. Errors

All SDK errors extend `ZamaError`. Catchable subclasses:

```ts
import {
  ZamaError,
  EncryptionFailedError,
  DecryptionFailedError,
  RelayerError,
  AclDeniedError,
  UnsupportedChainError,
} from "@zama-fhe/sdk";

try {
  await token.confidentialTransfer(to, amount);
} catch (e) {
  if (e instanceof AclDeniedError)        { /* user hasn't called token.allow() */ }
  else if (e instanceof RelayerError)     { /* relayer down or rate-limited */ }
  else if (e instanceof EncryptionFailedError) { /* input rejected */ }
  else throw e;
}
```

---

## 12. Forward note — fhevm v0.12 / relayer-sdk 0.5.0-alpha

April 2026 v0.12 introduces **context-aware decryption** with an `extraData`
field bound to each ciphertext (for replay protection across different
contracts). The new SDK 3.x already speaks this protocol; the legacy
`relayer-sdk` requires `0.5.0-alpha` to participate. If you see
`extraDataMismatch` errors after upgrading the FHEVM version, upgrade the
relayer-sdk in lockstep — see `references/decryption-guide.md` §6.

---

## See also

- `references/react-sdk-guide.md` — `@zama-fhe/react-sdk` hooks + `ZamaProvider`
- `references/frontend-integration.md` — legacy relayer-sdk patterns
- `references/decryption-guide.md` — async decryption + callback patterns
- `references/erc7984-guide.md` — Token contract side (Solidity)
