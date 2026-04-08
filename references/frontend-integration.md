# FHEVM Frontend Integration

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

// IMPORTANT: Handle types differ between /web and /node:
// - /web: encrypted.handles[0] is a hex string ("0x...")
// - /node: encrypted.handles[0] may be a BigInt
// Always convert: String(encrypted.handles[0]) or `0x${encrypted.handles[0].toString(16)}`

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
<script src="https://cdn.zama.org/relayer-sdk-js/<version>/relayer-sdk-js.umd.cjs"></script>
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

```typescript
// For a ConfidentialERC20 with these Solidity functions:
//   function transfer(address to, externalEuint64 amount, bytes calldata proof)
//   function balanceOf(address) view returns (euint64)
//   function approve(address spender, externalEuint64 amount, bytes calldata proof)

const ABI = [
    "function transfer(address to, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function balanceOf(address account) view returns (uint256)",
    "function approve(address spender, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function transferFrom(address from, address to, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
    "function mint(uint64 amount)",
    "function totalSupply() view returns (uint64)",
    "function allowance(address owner, address spender) view returns (uint256)",
];

const contract = new ethers.Contract(contractAddress, ABI, signer);
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
const startTimestamp = Math.floor(Date.now() / 1000).toString();
const durationDays = '10';

const eip712 = fhevm.createEIP712(
    keypair.publicKey,
    contractAddresses,
    startTimestamp,
    durationDays,
);

// User signs (triggers MetaMask popup)
const signature = await signer.signTypedData(
    eip712.domain,
    { UserDecryptRequestVerification: eip712.types.UserDecryptRequestVerification },
    eip712.message,
);

// Decrypt
const result = await fhevm.userDecrypt(
    [{ handle: encryptedHandle, contractAddress }],
    keypair.privateKey,
    keypair.publicKey,
    signature.replace('0x', ''),
    contractAddresses,
    signer.address,
    startTimestamp,
    durationDays,
);

const clearValue = result[encryptedHandle]; // bigint
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
const yesCount = result.clearValues[yesHandle.toString()];
const noCount = result.clearValues[noHandle.toString()];

// Submit proof to contract for on-chain verification:
await contract.revealResults(result.abiEncodedClearValues, result.decryptionProof);
```

**Important**: `publicDecrypt` only works for handles that have been marked as `makePubliclyDecryptable` on-chain. If the handle hasn't been marked, the KMS will reject the request.

**Hardhat tests vs Browser**: In Hardhat tests, use `fhevm.publicDecrypt(handles)` from the test runner. In browser, use the Relayer SDK's `fhevm.publicDecrypt(handles)` as shown above. The API is similar but the import source differs (`hardhat` vs `@zama-fhe/relayer-sdk/web`).

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
            const startTimestamp = Math.floor(Date.now() / 1000).toString();
            const eip712 = fhevm.createEIP712(
                keypair.publicKey,
                [contractAddress],
                startTimestamp,
                '10',
            );
            const signature = await signer.signTypedData(
                eip712.domain,
                { UserDecryptRequestVerification: eip712.types.UserDecryptRequestVerification },
                eip712.message,
            );

            // Decrypt
            const result = await fhevm.userDecrypt(
                [{ handle: encHandle, contractAddress }],
                keypair.privateKey,
                keypair.publicKey,
                signature.replace('0x', ''),
                [contractAddress],
                await signer.getAddress(),
                startTimestamp,
                '10',
            );

            setBalance(result[encHandle]);
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

## Bundler WASM Configuration

The Relayer SDK uses WASM internally. Some bundlers need configuration:

### Vite (vite.config.ts)
```typescript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
    plugins: [react()],
    optimizeDeps: {
        exclude: ["@zama-fhe/relayer-sdk"], // Don't pre-bundle WASM modules
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
module.exports = {
    webpack: (config) => {
        config.experiments = { ...config.experiments, asyncWebAssembly: true };
        return config;
    },
};
```

If you see `WebAssembly.instantiate` errors, ensure your bundler supports WASM and the SDK is not being pre-bundled/optimized.

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

## Sepolia Contract Addresses

```
ACL:            0xf0Ffdc93b7E186bC2f8CB3dAA75D86d1930A433D
Coprocessor:    0x92C920834Ec8941d2C77D188936E1f7A6f49c127
KMSVerifier:    0xbE0E383937d564D7FF0BC3b46c51f0bF8d5C311A
InputVerifier:  0xBBC1fFCdc7C316aAAd72E807D9b0272BE8F84DA0
```
