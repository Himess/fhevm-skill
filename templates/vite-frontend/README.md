# Vite Vanilla-JS Frontend Template

Lowest-friction frontend for confidential dApps on FHEVM. No React, no Next.js — just Vite + ethers + the foundational `@zama-fhe/relayer-sdk/web`.

## When to use this template vs `react-dashboard-v3.tsx`

| You want | Use |
|---|---|
| ERC-7984 token UI (balances, transfers, wraps) | `templates/react-dashboard-v3.tsx` (high-level Token API) |
| Custom non-token contract UI (voting, auction, AMM, vault) | This template |
| Hackathon-tier rapid prototype | This template |
| Understand the raw encryption flow before adopting hooks | This template |

## Quick start

```bash
cp -r templates/vite-frontend my-app
cd my-app
npm install
# Replace CONTRACT_ADDRESS + CONTRACT_ABI in src/main.js
npm run dev   # http://localhost:5173
```

## What's wired

- **Wallet connect** — MetaMask, auto-switches to Sepolia (chainId 11155111)
- **Lazy SDK init** — `initSDK()` is called on first action, not on page load (avoids WASM blocking the wallet UX)
- **Encrypted input flow** — `createEncryptedInput → add64 → encrypt → contract.method(handle, inputProof)`
- **Plain log feed** — every step printed with timestamp; mismatched calls visible at a glance

## Critical Vite config

`vite.config.js` excludes `@zama-fhe/relayer-sdk` from `optimizeDeps`. Without this, Vite's dependency pre-bundler strips the WASM init path and the SDK fails at runtime.

If your browser raises `SharedArrayBuffer is not defined`, uncomment the COOP/COEP headers in `vite.config.js`. (Most modern wallets work without them.)

## Browser-only gotcha — `Buffer` does not exist

The Node-side `templates/onchain-e2e.ts` uses

```ts
const handle = "0x" + Buffer.from(enc.handles[0]).toString("hex");
```

to hex-encode a `Uint8Array` handle. **Don't copy this verbatim into the browser bundle** — Vite does NOT polyfill Node's `Buffer` global, and the line silently breaks at runtime (`ReferenceError: Buffer is not defined`). Use ethers v6 instead:

```ts
const handle = ethers.hexlify(enc.handles[0]);   // works in browser AND Node
```

The same applies anywhere a Node example reaches for `Buffer.from(uint8).toString("hex")` / `Buffer.from(hex, "hex")`. In the browser, `ethers.hexlify` and `ethers.getBytes` cover both directions.

> The simple `add64 → encrypt → contract.method(handles[0], inputProof)` path in `src/main.js` happens to work without hex-encoding because ethers v6 accepts `BytesLike` directly. You only hit the gotcha when you start logging handles, comparing them as strings, or using them as `mapping(bytes32 => …)` keys — which is most real frontends.

## Stack

- `@zama-fhe/relayer-sdk@0.4.1` (EXACT pin — see `references/zama-upstream.md`)
- `ethers@^6.16`
- `vite@^5`
