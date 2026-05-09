# FHEVM Frontend Integration

> **Heads-up — pick the right SDK first.** As of April 2026 there are two
> supported frontend SDKs:
>
> - **`@zama-fhe/sdk@3.x`** (Gen-3, current default) — high-level `Token` API,
>   `useConfidentialBalance` / `useConfidentialTransfer` hooks via
>   `@zama-fhe/react-sdk`. **Use this for new browser/React apps.** See
>   [sdk-v3-guide.md](sdk-v3-guide.md) and [react-sdk-guide.md](react-sdk-guide.md).
> - **`@zama-fhe/relayer-sdk@0.4.x`** (Gen-2) — low-level `createInstance` +
>   `createEncryptedInput` API. **Still required** by `@fhevm/hardhat-plugin@0.4.2`
>   for tests, and useful for custom non-token contracts. **The rest of this
>   document covers Gen-2.**
>
> See `SKILL.md` § "Three SDK Generations" for the full decision matrix.

## SDK Setup

The Relayer SDK (`@zama-fhe/relayer-sdk`) replaces the deprecated `fhevmjs` package.

### Installation

```bash
npm install @zama-fhe/relayer-sdk
```

### Initialization (React/Node.js)

```typescript
// For browser/frontend (React, Next.js, Vite):
import { createInstance, SepoliaConfig, MainnetConfig } from '@zama-fhe/relayer-sdk/web';

// For Node.js (Hardhat scripts, backend):
import { createInstance, SepoliaConfig, MainnetConfig } from '@zama-fhe/relayer-sdk/node';

// NOTE: The root import '@zama-fhe/relayer-sdk' may NOT work in all environments.
// Always use the /web or /node subpath for your target platform.

// The `network` parameter accepts:
// - Browser: window.ethereum (EIP-1193 provider)
// - Node.js: an RPC URL string like "https://ethereum-sepolia-rpc.publicnode.com"
// - Hardhat scripts: use string URL (ethers.provider object does NOT work)

// IMPORTANT (relayer-sdk@0.4.1 — the version paired with @fhevm/hardhat-plugin@0.4.2):
//   encrypted.handles    : Uint8Array[]   ← raw bytes, not hex, not BigInt
//   encrypted.inputProof : Uint8Array     ← raw bytes
// Pass directly to ethers v6 contract calls; for string-keyed lookups (publicDecrypt
// result records) hex-encode first. See § "Handle Types in @zama-fhe/relayer-sdk@0.4.1"
// below for the toHex() helper.

// Sepolia Testnet
const fhevm = await createInstance({
    ...SepoliaConfig,
    network: provider,  // ethers.js provider or window.ethereum
});

// Ethereum Mainnet (requires API key)
const fhevm = await createInstance({
    ...MainnetConfig,
    network: provider,
    auth: { __type: 'ApiKeyHeader', value: ZAMA_API_KEY },
});
```

### Public TypeScript Types (relayer-sdk@0.4.1)

These are the actual named exports in `@zama-fhe/relayer-sdk@0.4.1` (verified
against `node_modules/@zama-fhe/relayer-sdk/lib/web.d.ts`):

```typescript
import type {
    FhevmInstance,                  // interface — return type of createInstance()
    FhevmInstanceConfig,            // config object passed to createInstance()
    RelayerEncryptedInput,          // builder returned by createEncryptedInput()
    HandleContractPair,             // { handle, contractAddress } — userDecrypt input
    UserDecryptResults,             // Record<`0x${string}`, bigint | boolean | `0x${string}`>
    PublicDecryptResults,           // { clearValues, abiEncodedClearValues, decryptionProof }
    KmsUserDecryptEIP712Type,       // typed-data shape from createEIP712()
    KmsUserDecryptEIP712TypesType,  // the inner `types` part (readonly tuple — needs spread for ethers v6)
    KeypairType,                    // generic; instance type is KeypairType<BytesHexNo0x>
    ClearValueType,                 // bigint | boolean | `0x${string}`
} from '@zama-fhe/relayer-sdk/web';
```

**Watch out — common mistakes that don't compile against 0.4.1:**

| Wrong (often seen in old guides) | Correct (0.4.1) |
|---|---|
| `EncryptResult` | does **not** exist — the encrypt() return is anonymous: `Promise<{ handles: Uint8Array[]; inputProof: Uint8Array }>`. If you need a name, define `type EncryptResult = Awaited<ReturnType<RelayerEncryptedInput['encrypt']>>;` locally. |
| `DecryptedResults` | `UserDecryptResults` |
| `EIP712` | `KmsUserDecryptEIP712Type` |
| `Keypair` | `KeypairType<BytesHexNo0x>` (generic over the byte-encoding type — typically `BytesHexNo0x`) |

### Manual Configuration

```typescript
const fhevm = await createInstance({
    aclContractAddress: '0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D',
    kmsContractAddress: '0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A',
    inputVerifierContractAddress: '0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0',
    verifyingContractAddressDecryption: '0x5D8BD78e2ea6bbE41f26dFe9fdaEAa349e077478',
    verifyingContractAddressInputVerification: '0x483b9dE06E4E4C7D35CCf5837A1668487406D955',
    chainId: 11155111,
    gatewayChainId: 10901,
    network: provider,
    relayerUrl: 'https://relayer.testnet.zama.org',
});
```

### CDN / Vanilla JS (Browser)

```html
<!-- The canonical CDN host is `cdn.zama.org` and `@zama-fhe/sdk@3.0.0`
     hardcodes 0.4.2 inside its worker (verified at
     `node_modules/@zama-fhe/sdk/dist/esm/index.js:514`). For consistency
     with the SDK's own SRI integrity hash, use 0.4.2 here too unless you
     have a specific reason to bump. Verify newer versions at
     https://www.npmjs.com/package/@zama-fhe/relayer-sdk and re-check the
     SDK's hardcoded URL after every Zama point release. -->
<script src="https://cdn.zama.org/relayer-sdk-js/0.4.2/relayer-sdk-js.umd.cjs"></script>
<script>
  async function init() {
    const { initSDK, createInstance, SepoliaConfig } = window.relayerSdk;
    await initSDK();  // Load WASM module
    const fhevm = await createInstance({
        ...SepoliaConfig,
        network: window.ethereum,
    });
  }
</script>
```

## CRITICAL: Handle Types in `@zama-fhe/relayer-sdk@0.4.1`

In the **pinned 0.4.1** version that `@fhevm/hardhat-plugin@0.4.2` requires, the
return shape is the same on both `/web` and `/node` — and it is **NOT** a hex
string:

```ts
const encrypted = await input.encrypt();
// encrypted.handles      : Uint8Array[]   ← raw bytes, NOT hex strings, NOT BigInt
// encrypted.inputProof   : Uint8Array     ← raw bytes
```

ethers v6 contract calls accept `BytesLike` (which includes `Uint8Array`), so
passing `encrypted.handles[0]` and `encrypted.inputProof` directly to a
contract write usually works. But for any string-keyed lookup (e.g.
`publicDecrypt` result records, logging, comparison) you need to hex-encode:

```typescript
// Normalize to 0x-prefixed bytes32 hex (32 bytes = 64 chars)
function toHex(buf: Uint8Array): `0x${string}` {
    return ("0x" + Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("")) as `0x${string}`;
}

// Common shape — directly pass Uint8Array to ethers v6:
await contract.deposit(encrypted.handles[0], encrypted.inputProof);

// When you need a string key (e.g. result.clearValues lookup):
const handleHex = toHex(encrypted.handles[0]);
const value = result.clearValues[handleHex];   // bigint
```

**Common errors caught by this:**
- `encrypted.handles[0].substring()` → `TypeError: handles[0].substring is not a function` (it's a `Uint8Array`, not a string).
- `result.clearValues[encrypted.handles[0]]` → `undefined` (object keys are strings; passing a `Uint8Array` stringifies to "0,1,2,...").
- `BigInt(encrypted.handles[0])` → `TypeError`. Pass through `toHex()` first, then `BigInt(toHex(...))` if you need a numeric form.

> **Older skill versions documented this as "hex on /web, BigInt on /node".** That
> applied to a pre-0.4.1 line and is no longer accurate against the version
> `@fhevm/hardhat-plugin@0.4.2` pins to. If you upgrade past `0.4.1`, re-verify
> the shape against `node_modules/@zama-fhe/relayer-sdk/web.d.ts`.

## ABI Encoding of Encrypted Types

When calling FHEVM contracts from JavaScript/TypeScript, encrypted types map to these ABI types:

| Solidity Type | ABI Type | ethers.js Type | Notes |
|---------------|----------|----------------|-------|
| `externalEuint8` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEuint16` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEuint32` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEuint64` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEuint128` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEuint256` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEbool` | `bytes32` | `BytesLike` | Encrypted input handle |
| `externalEaddress` | `bytes32` | `BytesLike` | Encrypted input handle |
| `euint64` (return) | `uint256` | `bigint` | Handle stored on-chain |
| `ebool` (return) | `uint256` | `bigint` | Handle stored on-chain |
| `eaddress` (return) | `uint256` | `bigint` | Handle stored on-chain |
| `bytes calldata inputProof` | `bytes` | `BytesLike` | ZK proof |

### ABI Fragment Example

> **For new code, use the ERC-7984 ABI fragment in the next section.** The block below is the **legacy `ConfidentialERC20`** shape (deprecated `fhevm-contracts` package, archived in 2025) and is kept only so you can recognise / migrate older codebases. The function names and return types are different from ERC-7984.

```typescript
// LEGACY ConfidentialERC20 (deprecated — for migration reference only):
//   function transfer(address to, externalEuint64 amount, bytes calldata proof)
//   function balanceOf(address) view returns (euint64)
//   function approve(address spender, externalEuint64 amount, bytes calldata proof)

const LEGACY_ABI = [
    "function transfer(address to, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function transferFrom(address from, address to, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function mint(uint64 amount)",
    "function totalSupply() view returns (uint64)",
    "function allowance(address owner, address spender) view returns (uint256)",
];
// ⚠ Returns `bool` here is wrong for ERC-7984 — the new standard returns
// `uint256` (the post-transfer encrypted handle). Don't paste this fragment
// into new ERC-7984 code.

const contract = new ethers.Contract(contractAddress, LEGACY_ABI, signer);
```

### ERC-7984 ABI Fragment (with Ownable2Step)

```typescript
// For an ERC-7984 token extending ERC7984 + Ownable2Step:
const ERC7984_ABI = [
    // ERC-7984 standard
    "function confidentialTransfer(address to, bytes32 encAmount, bytes proof) returns (uint256)",
    "function confidentialTransfer(address to, uint256 amount) returns (uint256)",
    "function confidentialTransferFrom(address from, address to, bytes32 encAmount, bytes proof) returns (uint256)",
    "function confidentialTransferFrom(address from, address to, uint256 amount) returns (uint256)",
    "function confidentialBalanceOf(address account) view returns (uint256)",
    "function confidentialTotalSupply() view returns (uint256)",
    "function setOperator(address operator, uint48 until)",
    "function isOperator(address holder, address spender) view returns (bool)",
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function contractURI() view returns (string)",
    // Owner functions (if added)
    "function mint(address to, uint64 amount)",
    "function owner() view returns (address)",
];
```

### All ERC-7984 Overloaded Function Selectors

```typescript
// confidentialTransfer — 2 overloads:
contract["confidentialTransfer(address,bytes32,bytes)"](to, handle, proof);  // encrypted input
contract["confidentialTransfer(address,uint256)"](to, existingHandle);       // handle-based

// confidentialTransferFrom — 2 overloads:
contract["confidentialTransferFrom(address,address,bytes32,bytes)"](from, to, handle, proof);
contract["confidentialTransferFrom(address,address,uint256)"](from, to, existingHandle);

// confidentialTransferAndCall — 2 overloads:
contract["confidentialTransferAndCall(address,bytes32,bytes,bytes)"](to, handle, proof, data);
contract["confidentialTransferAndCall(address,uint256,bytes)"](to, existingHandle, data);

// confidentialTransferFromAndCall — 2 overloads:
contract["confidentialTransferFromAndCall(address,address,bytes32,bytes,bytes)"](from, to, handle, proof, data);
contract["confidentialTransferFromAndCall(address,address,uint256,bytes)"](from, to, existingHandle, data);
```

### Solidity Auto-Getter Gotcha: Public Arrays

A `string[] public choices` Solidity field auto-generates `choices(uint256 i)`,
**not** `choices.length`. Calling `await contract.choices.length` from
JavaScript fails. Always expose a separate `numChoices()` (or similar) view:

```solidity
string[] public choices;
function numChoices() external view returns (uint256) { return choices.length; }
```

```typescript
// Frontend:
const n = await contract.numChoices();
const labels: string[] = [];
for (let i = 0; i < Number(n); i++) labels.push(await contract.choices(i));
```

Same gotcha applies to dynamic mappings — auto-getters never expose `.length` or iteration.

### Solidity Struct Getters: Tuple Return Order

When a Solidity `public mapping` returns a struct, ethers.js returns a tuple in **field declaration order**:

```solidity
struct Auction {
    address creator;     // index 0
    string item;         // index 1
    uint256 endTime;     // index 2
    uint8 state;         // index 3
    // euint64 fields are NOT returned (not ABI-safe)
}
```

```typescript
const data = await contract.auctions(auctionId);
const creator = data[0];  // or data.creator
const item = data[1];     // or data.item
const endTime = data[2];  // or data.endTime
const state = data[3];    // or data.state
// NOTE: encrypted fields (euint64) are excluded from auto-generated getters
// Use separate view functions for encrypted data
```

### Calling Overloaded Functions

When a contract has both `transfer(address, externalEuint64, bytes)` and `transfer(address, euint64)`, use bracket notation in ethers.js:

```typescript
// Encrypted input version:
await contract["transfer(address,bytes32,bytes)"](to, encrypted.handles[0], encrypted.inputProof);

// Handle version (from another contract):
await contract["transfer(address,uint256)"](to, existingHandle);
```

## Core Operations

### 1. Encrypt Values

```typescript
// Create encrypted input bound to a specific contract and user
const input = fhevm.createEncryptedInput(contractAddress, userAddress);

// Add values (order matters — maps to handles[0], handles[1], etc.)
input.addBool(true);               // → externalEbool
input.add8(42);                    // → externalEuint8
input.add16(1000);                 // → externalEuint16
input.add32(Date.now());           // → externalEuint32
input.add64(BigInt("1000000"));    // → externalEuint64
input.add128(BigInt("999999"));    // → externalEuint128
input.addAddress("0xAbCd...");     // → externalEaddress
input.add256(BigInt("12345"));     // → externalEuint256

// Encrypt (async — involves WASM computation)
const encrypted = await input.encrypt();

// Result
encrypted.handles[0]    // First handle (bytes)
encrypted.handles[1]    // Second handle
encrypted.inputProof    // Single proof for all handles
```

### 2. Send Encrypted Transaction

```typescript
const encrypted = await fhevm
    .createEncryptedInput(contractAddress, signer.address)
    .add64(BigInt(amount))
    .encrypt();

const tx = await contract.transfer(
    recipientAddress,
    encrypted.handles[0],
    encrypted.inputProof,
);
await tx.wait();
```

### 3. User Decryption (Private)

```typescript
// Generate ephemeral keypair
const keypair = fhevm.generateKeypair();

// Create EIP-712 signature request
const contractAddresses = [contractAddress];
const startTimestamp = Math.floor(Date.now() / 1000);  // NUMBER, not string
const durationDays = 10;  // NUMBER, not string

const eip712 = fhevm.createEIP712(
    keypair.publicKey,
    contractAddresses,
    startTimestamp,
    durationDays,
);

// User signs (triggers MetaMask popup)
//
// ⚠ Strict TypeScript: `eip712.types.UserDecryptRequestVerification` is a
// `readonly TypedDataField[]`, but ethers v6 `signTypedData` expects a
// mutable `Record<string, TypedDataField[]>`. Spread to copy:
const signature = await signer.signTypedData(
    eip712.domain,
    { UserDecryptRequestVerification: [...eip712.types.UserDecryptRequestVerification] },
    eip712.message,
);

// Decrypt
const result = await fhevm.userDecrypt(
    [{ handle: encryptedHandle, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.slice(2),  // strip the leading "0x" before sending to the relayer
    contractAddresses,
    signer.address,
    startTimestamp,
    durationDays,
);

// `result` is keyed by `0x${string}`. If `encryptedHandle` is a plain string
// or bigint, normalize + cast (see "Strict TypeScript: handle-key cast" above):
const handleHex = (typeof encryptedHandle === "bigint"
    ? ethers.toBeHex(encryptedHandle, 32)
    : encryptedHandle) as `0x${string}`;
const clearValue = result[handleHex]; // bigint
```

### 4. Public Decryption (Browser SDK)

For values marked as `makePubliclyDecryptable` on-chain, request decryption from the browser:

```typescript
import { createInstance, SepoliaConfig } from '@zama-fhe/relayer-sdk/web';

const fhevm = await createInstance({ ...SepoliaConfig, network: window.ethereum });

// Get handles from the contract (these are uint256 values)
const yesHandle = await contract.getYesVotesHandle();
const noHandle = await contract.getNoVotesHandle();

// Request public decryption from KMS
const handles = [yesHandle, noHandle];
const result = await fhevm.publicDecrypt(handles);

// Result structure:
result.clearValues              // Record<string, bigint> — handle → decrypted value
result.abiEncodedClearValues    // bytes string — pass to contract's checkSignatures
result.decryptionProof          // bytes string — KMS proof

// Access individual decrypted values:
// `result.clearValues` is typed `Record<`0x${string}`, bigint | boolean | string>`,
// so a plain `.toString()` key fails strict TypeScript with
// "Element implicitly has an 'any' type because expression of type 'string'
//  can't be used to index type". Cast to the template-literal type:
const yesCount = result.clearValues[ethers.toBeHex(yesHandle, 32) as `0x${string}`];
const noCount  = result.clearValues[ethers.toBeHex(noHandle,  32) as `0x${string}`];

// Submit proof to contract for on-chain verification:
await contract.revealResults(result.abiEncodedClearValues, result.decryptionProof);
```

**Important**: `publicDecrypt` only works for handles that have been marked as `makePubliclyDecryptable` on-chain. If the handle hasn't been marked, the KMS will reject the request.

**Strict TypeScript: handle-key cast**

`clearValues` (and the `userDecrypt` result) is keyed by `` `0x${string}` `` — a
template-literal type. Plain `string`, `bigint.toString()`, or even
`encrypted.handles[0]` (a `Uint8Array`) will not type-check under strict mode.
Always normalize to a 32-byte hex string and cast:

```ts
import { ethers } from "ethers";

// From an on-chain handle (uint256 → bigint in ethers v6):
const handle = (await contract.getYesVotesHandle()) as bigint;
const key = ethers.toBeHex(handle, 32) as `0x${string}`;
const yes = result.clearValues[key];   // ✓ typed bigint

// From an encryption result (Uint8Array → hex):
const inputKey = toHex(encrypted.handles[0]);  // already `0x${string}`
const v = result.clearValues[inputKey];        // ✓
```

### publicDecrypt: Hardhat Test vs Browser SDK

| Context | Import | Usage |
|---------|--------|-------|
| Hardhat test | `import { fhevm } from "hardhat"` | `await fhevm.publicDecrypt(handles)` |
| Browser (React) | `import { createInstance } from "@zama-fhe/relayer-sdk/web"` | `await fhevm.publicDecrypt(handles)` |
| Node.js script | `import { createInstance } from "@zama-fhe/relayer-sdk/node"` | `await fhevm.publicDecrypt(handles)` |

The API is identical — `publicDecrypt(handles)` returns `{ clearValues, abiEncodedClearValues, decryptionProof }` in all contexts. Only the import source differs. In Hardhat tests, `fhevm` is auto-injected by the plugin. In browser/Node.js, you must create an instance first via `createInstance()`.

## React Integration Pattern

### Custom Hook: useConfidentialBalance

```typescript
import { useState, useCallback } from 'react';
import { createInstance, SepoliaConfig } from '@zama-fhe/relayer-sdk/web';

function useConfidentialBalance(contractAddress: string) {
    const [balance, setBalance] = useState<bigint | null>(null);
    const [loading, setLoading] = useState(false);

    const decrypt = useCallback(async (signer: ethers.Signer) => {
        setLoading(true);
        try {
            const fhevm = await createInstance({
                ...SepoliaConfig,
                network: signer.provider,
            });

            // Get encrypted handle
            const contract = new ethers.Contract(contractAddress, abi, signer);
            const encHandle = await contract.balanceOf(await signer.getAddress());

            // Generate keypair and sign
            const keypair = fhevm.generateKeypair();
            const startTimestamp = Math.floor(Date.now() / 1000);
            const eip712 = fhevm.createEIP712(
                keypair.publicKey,
                [contractAddress],
                startTimestamp,
                10,                  // durationDays — number, not string
            );
            const signature = await signer.signTypedData(
                eip712.domain,
                // Spread the readonly type tuple into a mutable copy for ethers v6
                { UserDecryptRequestVerification: [...eip712.types.UserDecryptRequestVerification] },
                eip712.message,
            );

            // Decrypt
            const result = await fhevm.userDecrypt(
                [{ handle: encHandle, contractAddress }],
                keypair.privateKey,
                keypair.publicKey,
                signature.slice(2),  // strip the leading "0x" before sending to the relayer
                [contractAddress],
                await signer.getAddress(),
                startTimestamp,
                10,
            );

            // encHandle is a bigint — convert to 32-byte hex and cast to `0x${string}` for lookup
            const hexHandle = ethers.toBeHex(encHandle, 32) as `0x${string}`;
            setBalance(result[hexHandle]);
        } finally {
            setLoading(false);
        }
    }, [contractAddress]);

    return { balance, loading, decrypt };
}
```

### Encryption with Progress & Timeout

```typescript
const encrypted = await fhevm.createEncryptedInput(contractAddress, userAddress)
    .add64(BigInt(amount))
    .encrypt({
        timeout: 60000,  // 60 second timeout
        onProgress: (args) => {
            console.log(`${args.type}: ${args.elapsedMs}ms`);
            // Update UI loading state
        },
    });
```

## UX Considerations

### Encrypted State Display

Users cannot see encrypted values directly. Design your UI with these states:

| State | Display |
|-------|---------|
| Not connected | "Connect wallet to view" |
| Connected, not decrypted | "Balance: ●●●●●● (Click to reveal)" |
| Decrypting (EIP-712 sign) | "Sign message to decrypt..." |
| Decrypting (KMS request) | "Decrypting..." with spinner |
| Decrypted | "Balance: 1,000.00 USDC" |
| Error | "Decryption failed. Try again." |

### Transaction Confirmation

For encrypted transfers, the UI cannot show the amount in the confirmation dialog (it's encrypted). Consider:
- Let users confirm the plaintext amount BEFORE encryption
- Show: "Sending [amount you entered] tokens to [address]"
- After encryption: "Confirming encrypted transfer..."

### Mainnet API Key Protection

For mainnet, the Zama API key must NOT be exposed in frontend code:

```typescript
// Backend proxy pattern
// Frontend → Your Backend → Zama Relayer
const fhevm = await createInstance({
    ...MainnetConfig,
    network: provider,
    auth: { __type: 'ApiKeyHeader', value: API_KEY },  // Use backend proxy!
});
```

## Next.js / SSR Compatibility

The Relayer SDK uses WASM which only works in the browser. For Next.js:

```typescript
// components/FhevmProvider.tsx — MUST be a client component
"use client";

import { createInstance, SepoliaConfig } from "@zama-fhe/relayer-sdk/web";
import { useState, useEffect, createContext, useContext } from "react";

const FhevmContext = createContext<any>(null);

export function FhevmProvider({ children }: { children: React.ReactNode }) {
    const [fhevm, setFhevm] = useState<any>(null);

    useEffect(() => {
        // Only initialize in browser (not during SSR)
        createInstance({ ...SepoliaConfig, network: window.ethereum })
            .then(setFhevm)
            .catch(console.error);
    }, []);

    return <FhevmContext.Provider value={fhevm}>{children}</FhevmContext.Provider>;
}

export const useFhevm = () => useContext(FhevmContext);
```

**Key rules for Next.js:**
- All FHEVM components must have `"use client"` directive
- Never import `@zama-fhe/relayer-sdk` in server components
- Use `dynamic(() => import("./MyFhevmComponent"), { ssr: false })` for pages that use FHEVM
- Check `typeof window !== "undefined"` before accessing `window.ethereum`

### Dynamic Import with Graceful Fallback

For SSR-safe FHEVM loading with error handling:

```typescript
"use client";
import { useState, useEffect } from "react";

function useFhevm() {
    const [fhevm, setFhevm] = useState<any>(null);
    const [error, setError] = useState<string | null>(null);
    const [loading, setLoading] = useState(true);

    useEffect(() => {
        if (typeof window === "undefined") return;

        // Dynamic import — only loads in browser, never during SSR
        import("@zama-fhe/relayer-sdk/web")
            .then(async ({ createInstance, SepoliaConfig }) => {
                const instance = await createInstance({
                    ...SepoliaConfig,
                    network: window.ethereum,
                });
                setFhevm(instance);
            })
            .catch((err) => setError(`FHEVM init failed: ${err.message}`))
            .finally(() => setLoading(false));
    }, []);

    return { fhevm, error, loading };
}
```

This pattern gracefully handles: SSR (skips), missing wallet (error state), WASM load failure (error state).

## Error Handling Patterns

```typescript
// Encryption errors
try {
    const encrypted = await fhevm.createEncryptedInput(addr, user).add64(amount).encrypt();
} catch (err: any) {
    if (err.message?.includes("timeout")) {
        // WASM encryption took too long — retry or show "Try again"
    } else if (err.message?.includes("user rejected")) {
        // User cancelled in wallet — no action needed
    } else {
        // SDK/network error — show generic error
    }
}

// Decryption errors
try {
    const result = await fhevm.userDecrypt([...], ...);
} catch (err: any) {
    if (err.message?.includes("rejected")) {
        // User rejected EIP-712 signature in wallet
    } else if (err.message?.includes("KMS") || err.message?.includes("relayer")) {
        // KMS/relayer unavailable — try again later
    } else if (err.message?.includes("not allowed")) {
        // Handle doesn't have ACL for this user — check FHE.allow was called
    } else {
        // Unknown error
    }
}

// Transaction errors (confidentialTransfer, etc.)
try {
    const tx = await contract["confidentialTransfer(address,bytes32,bytes)"](to, handle, proof);
    await tx.wait();
} catch (err: any) {
    if (err.code === "ACTION_REJECTED") {
        // User rejected in wallet
    } else if (err.message?.includes("insufficient funds")) {
        // Not enough ETH for gas
    } else {
        // Contract revert or network error
    }
}
```

## TypeScript: window.ethereum Declaration

For TypeScript strict mode, declare `window.ethereum` globally:

```typescript
// src/global.d.ts (or any .d.ts file in your project)
import { Eip1193Provider } from "ethers";

declare global {
    interface Window {
        ethereum?: Eip1193Provider;
    }
}
```

Without this, `window.ethereum` will show a TypeScript error in strict mode.

## Bundler WASM Configuration

The Relayer SDK uses WASM internally. Some bundlers need configuration:

### Vite (vite.config.ts)
```typescript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
    plugins: [react()],
    optimizeDeps: {
        exclude: ["@zama-fhe/relayer-sdk/web"], // Don't pre-bundle WASM modules
    },
    build: {
        target: "esnext", // Required for top-level await used by WASM
    },
    // If you still get WASM errors, also try:
    // server: { fs: { allow: [".."] } },
});
```

### Webpack (next.config.js for Next.js)
```javascript
/** @type {import('next').NextConfig} */
const nextConfig = {
    webpack: (config, { isServer }) => {
        // Enable WASM support
        config.experiments = { ...config.experiments, asyncWebAssembly: true };
        // Prevent WASM from being bundled on server side
        if (isServer) {
            config.externals = [...(config.externals || []), "@zama-fhe/relayer-sdk"];
        }
        return config;
    },
    // Suppress hydration warnings from WASM-dependent components
    reactStrictMode: true,
};
module.exports = nextConfig;
```

**Also in Next.js**: Any component using `@zama-fhe/relayer-sdk/web` must be dynamically imported:
```typescript
// pages/index.tsx or app/page.tsx
import dynamic from "next/dynamic";
const FhevmDashboard = dynamic(() => import("../components/Dashboard"), { ssr: false });
export default function Home() { return <FhevmDashboard />; }
```

If you see `WebAssembly.instantiate` errors, ensure your bundler supports WASM and the SDK is not being pre-bundled/optimized.

### Multi-Threaded WASM (5–10× faster encryption)

The Relayer SDK's WASM module can run on multiple threads via `SharedArrayBuffer`,
which speeds up encryption substantially (~5–10× on a 4-core laptop). This is
gated behind a browser security feature: `SharedArrayBuffer` is **only available
in cross-origin-isolated contexts**, which require both of these response headers
on every page that loads the SDK:

```
Cross-Origin-Opener-Policy:   same-origin
Cross-Origin-Embedder-Policy: require-corp
```

#### Next.js (`next.config.js`)

```js
const nextConfig = {
    async headers() {
        return [{
            source: "/(.*)",
            headers: [
                { key: "Cross-Origin-Opener-Policy",   value: "same-origin" },
                { key: "Cross-Origin-Embedder-Policy", value: "require-corp" },
            ],
        }];
    },
};
```

#### Vite (`vite.config.ts`)

```ts
server: {
    headers: {
        "Cross-Origin-Opener-Policy":   "same-origin",
        "Cross-Origin-Embedder-Policy": "require-corp",
    },
},
preview: {
    headers: { /* same as above */ },
},
```

**Symptom of missing headers**: encryption is single-threaded and slow, and the
SDK logs `threads option requires SharedArrayBuffer (COOP/COEP headers).
Falling back to single-threaded.` (verified inside `@zama-fhe/sdk@3.0.0`'s
`RelayerWeb` worker).

**Caveat**: COEP `require-corp` blocks any third-party `<img>`, `<script>`,
`<iframe>`, etc., that doesn't return a `Cross-Origin-Resource-Policy:
cross-origin` header. If your app embeds external content (analytics, fonts,
images from CDNs), either route them through your origin or set the resource
policy on those endpoints. Vercel-hosted `cdn.zama.org` already returns the
correct CORP header for the SDK's WASM bundle.

## Wallet Chain Switching (Sepolia)

When connecting to FHEVM on Sepolia, ensure the user's wallet is on the correct chain:

```typescript
async function ensureSepoliaNetwork(provider: any) {
    const chainId = await provider.request({ method: "eth_chainId" });
    if (chainId !== "0xaa36a7") { // 11155111 in hex
        try {
            await provider.request({
                method: "wallet_switchEthereumChain",
                params: [{ chainId: "0xaa36a7" }],
            });
        } catch (err: any) {
            // Chain not added — add it
            if (err.code === 4902) {
                await provider.request({
                    method: "wallet_addEthereumChain",
                    params: [{
                        chainId: "0xaa36a7",
                        chainName: "Sepolia",
                        rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"],
                        nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
                        blockExplorerUrls: ["https://sepolia.etherscan.io"],
                    }],
                });
            }
        }
    }
}

// Call before FHEVM initialization:
await ensureSepoliaNetwork(window.ethereum);
const fhevm = await createInstance({ ...SepoliaConfig, network: window.ethereum });
```

## Contract Addresses

### Sepolia Testnet (chainId 11155111, gatewayChainId 10901)
```
ACL:            0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D
Coprocessor:    0x92C920834Ec8941d2C77D188936E1f7A6f49c127
KMSVerifier:    0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A
InputVerifier:  0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0
relayerUrl:     https://relayer.testnet.zama.org
```

### Ethereum Mainnet (chainId 1, gatewayChainId 261131)
```
ACL:            0xcA2E8f1F656CD25C01F05d0b243Ab1ecd4a8ffb6
KMSVerifier:    0x77627828a55156b04Ac0DC0eb30467f1a552BB03
InputVerifier:  0xCe0FC2e05CFff1B719EFF7169f7D80Af770c8EA2
relayerUrl:     https://relayer.mainnet.zama.org
```

Use `MainnetConfig` from the Relayer SDK for mainnet — addresses are hardcoded in the SDK.
