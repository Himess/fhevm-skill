# `@zama-fhe/react-sdk` 3.0 — React Hooks Guide

> **Official React bindings for Zama's FHEVM SDK.** Wraps `@zama-fhe/sdk` 3.x
> with `@tanstack/react-query` for cache + invalidation. Use this in any
> Next.js / Vite / CRA app talking to confidential ERC-7984 tokens.

---

## 1. Install

```bash
npm install @zama-fhe/react-sdk @zama-fhe/sdk @tanstack/react-query \
            wagmi viem
```

Dependency layout: `react-sdk` re-exports the core SDK so you usually only
import from `@zama-fhe/react-sdk`. `wagmi` is required only if you use
`WagmiSigner`; with custom signers it's optional.

---

## 2. Provider setup

`ZamaProvider` must be **inside** `WagmiProvider` and `QueryClientProvider`.
That order matters — the signer reads from wagmi, the SDK reads from
react-query.

```tsx
// app/providers.tsx
"use client";

import { WagmiProvider, createConfig, http } from "wagmi";
import { sepolia } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  ZamaProvider,
  RelayerWeb,
  indexedDBStorage,
  SepoliaConfig,
} from "@zama-fhe/react-sdk";
import { WagmiSigner } from "@zama-fhe/react-sdk/wagmi";

const wagmiConfig = createConfig({
  chains: [sepolia],
  transports: { [sepolia.id]: http() },
});

const queryClient = new QueryClient();

const relayer = new RelayerWeb({
  getChainId: async () => sepolia.id,            // MUST return Promise<number>
  transports: {
    [sepolia.id]: {
      relayerUrl: SepoliaConfig.relayerUrl,
      network:    SepoliaConfig.network,
    },
  },
});

// WagmiSigner takes the wagmi Config — it reads the active connector internally.
const signer = new WagmiSigner({ config: wagmiConfig });

export function Providers({ children }: { children: React.ReactNode }) {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <ZamaProvider
          relayer={relayer}
          signer={signer}
          storage={indexedDBStorage}
        >
          {children}
        </ZamaProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
```

In `app/layout.tsx`:

```tsx
import { Providers } from "./providers";
export default function RootLayout({ children }) {
  return <html><body><Providers>{children}</Providers></body></html>;
}
```

---

## 3. Read a confidential balance

```tsx
"use client";
import { useConfidentialBalance } from "@zama-fhe/react-sdk";

export function Balance({ tokenAddress }: { tokenAddress: `0x${string}` }) {
  const { data, isLoading, error } = useConfidentialBalance({ tokenAddress });

  if (isLoading) return <p>Decrypting…</p>;
  if (error)     return <p>Error: {error.message}</p>;
  return <p>Balance: {data?.toString()}</p>;
}
```

The hook handles: ACL grant on first read, KMS keypair generation, EIP-712
signature, IndexedDB caching, and react-query invalidation when a transfer
mutation lands.

---

## 4. Confidential transfer (mutation)

```tsx
"use client";
import { useConfidentialTransfer } from "@zama-fhe/react-sdk";
import { useState } from "react";

export function TransferForm({ tokenAddress }) {
  const { mutateAsync, isPending } = useConfidentialTransfer({ tokenAddress });
  const [to, setTo]         = useState("");
  const [amount, setAmount] = useState("");

  return (
    <form onSubmit={async (e) => {
      e.preventDefault();
      await mutateAsync({ to: to as `0x${string}`, amount: BigInt(amount) });
    }}>
      <input value={to}     onChange={(e) => setTo(e.target.value)}     placeholder="0x…" />
      <input value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="100" />
      <button disabled={isPending}>{isPending ? "Sending…" : "Send"}</button>
    </form>
  );
}
```

`mutateAsync` returns a `TransactionResult` (`{ txHash, receipt }`) — the
receipt is already mined, no `.wait()` needed. On success,
`useConfidentialBalance` for both sender and recipient is invalidated
automatically by the react-query layer.

---

## 5. Hook reference (verified against `@zama-fhe/react-sdk@3.0.0`)

### Queries

| Hook                                       | Returns                       | Notes                                    |
|--------------------------------------------|-------------------------------|------------------------------------------|
| `useZamaSDK()`                             | `ZamaSDK`                     | Escape hatch for advanced flows          |
| `useConfidentialBalance({ tokenAddress })` | `bigint`                      | Auto-decrypts caller's balance           |
| `useConfidentialBalances({ ... })`         | `BatchBalancesResult`         | Batch decrypt multiple owners            |
| `useMetadata(tokenAddress)`                | `{ name, symbol, decimals }`  | ERC-20-style metadata only               |
| `useIsConfidential(tokenAddress)`          | `boolean`                     | ERC-165 `IConfidentialFungibleToken` check|
| `useIsWrapper(tokenAddress)`               | `boolean`                     | ERC-7984 wrapper detection               |
| `useIsAllowed({ contractAddresses })`      | `boolean`                     | Has caller granted ACL for these contracts (`[Address, ...]`) |
| `useTotalSupply(tokenAddress)`             | `bigint \| Handle`            | Encrypted or inferred                    |
| `useUnderlyingAllowance(...)`              | `bigint`                      | ERC-20 allowance toward wrapper          |
| `useUserDecrypt(config)`                   | `DecryptResult`               | **`useQuery` — fires automatically on mount when `config.handles` is set**. NOT a mutation; do NOT call `.mutate(...)`. For imperative one-shot decryption, prefer `useZamaSDK().userDecrypt(handles)` or the higher-level `useConfidentialBalance` / `useDecryptBalanceAs`. Disable auto-fire with `{ enabled: false }` in the second `options` arg. |
| `useDelegationStatus(...)`                 | `DelegationStatusData`        | Check delegated decryption state         |

### Mutations

| Hook                                            | Variables                                   |
|-------------------------------------------------|---------------------------------------------|
| `useConfidentialTransfer({ tokenAddress })`     | `{ to, amount }` (`ConfidentialTransferParams`) |
| `useConfidentialTransferFrom({ tokenAddress })` | `{ from, to, amount }`                       |
| `useConfidentialApprove({ tokenAddress })`      | `{ spender, until? }` (operator model)       |
| `useShield({ tokenAddress, wrapperAddress })`   | `{ amount, approvalStrategy?, to? }`         |
| `useUnshield({ tokenAddress, wrapperAddress })` | `{ amount }`                                 |
| `useUnshieldAll({ tokenAddress, wrapperAddress })`| `void \| { ... }`                          |
| `useUnwrap({ tokenAddress })`                   | `{ amount }`                                 |
| `useFinalizeUnwrap({ tokenAddress })`           | `{ burnAmountHandle }`                       |
| `usePublicDecrypt()`                            | `Handle[]`                                   |
| `useEncrypt()`                                  | `EncryptParams` (low-level)                  |
| `useAllow()`                                    | `Address[]`                                  |
| `useRevoke()`                                   | `Address[]`                                  |

> All hooks accept a second `options` argument forwarded to `@tanstack/react-query`:
> `enabled`, `staleTime`, `refetchOnWindowFocus`, `select`, `placeholderData` for queries;
> `onSuccess`, `onError`, `onMutate`, `retry` for mutations.

### Suspense variants

`useMetadataSuspense`, `useIsWrapperSuspense`, `useIsConfidentialSuspense`,
`useTotalSupplySuspense`, `useUnderlyingAllowanceSuspense`,
`useConfidentialIsApprovedSuspense`, `useWrapperDiscoverySuspense` — all
require a parent `<Suspense fallback>` boundary.

### Optimistic updates

`useConfidentialTransfer` and `useShield` accept `optimistic: true` in their
config. The cached confidential balance is adjusted in-flight and rolled back
if the tx reverts. Useful for snappy UIs but skip for actions you must show
as confirmed.

---

## 6. Custom signer (without wagmi)

If you don't want wagmi, you can pass any signer that implements the
`Signer` interface from `@zama-fhe/sdk`:

```ts
import type { Signer } from "@zama-fhe/sdk";

class MyCustomSigner implements Signer {
  async getAddress(): Promise<`0x${string}`> { /* ... */ }
  async getChainId(): Promise<number> { /* ... */ }
  async signTypedData(typedData): Promise<`0x${string}`> { /* ... */ }
  async sendTransaction(tx): Promise<{ hash, wait }> { /* ... */ }
}
```

Pass it to `<ZamaProvider signer={new MyCustomSigner()}>`.

`ViemSigner` and `EthersSigner` are the two ready-made implementations;
`WagmiSigner` adapts both.

---

## 7. SSR / Next.js notes

- `ZamaProvider` and all hooks are **client-only**. Mark wrapper with
  `"use client"` (as in §2). Do **not** call hooks in server components.
- `IndexedDBStorage` reads from `window.indexedDB`. On SSR it falls back
  silently to `MemoryStorage` for the first render, then upgrades on hydrate.
- For static export (`output: "export"`), the SDK works — just keep all
  decrypt-triggering UI behind a user click, not in `useEffect` at mount,
  to avoid prerender warnings.

---

## 8. Testing components

Use a `MemoryStorage` and a mocked relayer:

```tsx
import { ZamaProvider, MemoryStorage } from "@zama-fhe/react-sdk";
import { mockRelayer } from "./test-utils";

render(
  <QueryClientProvider client={new QueryClient()}>
    <ZamaProvider
      relayer={mockRelayer}
      signer={mockSigner}
      storage={new MemoryStorage()}
    >
      <Balance tokenAddress="0x..." />
    </ZamaProvider>
  </QueryClientProvider>
);
```

`@fhevm/mock-utils` (used by Hardhat tests) is **not** for React tests — it
patches the in-process EVM. For React, mock at the relayer level.

---

## 9. Common pitfalls

| Symptom                                    | Cause                                                     |
|--------------------------------------------|-----------------------------------------------------------|
| `useConfidentialBalance` returns `undefined` forever | Provider order wrong — `ZamaProvider` outside `QueryClientProvider` |
| EIP-712 popup on every page load           | `storage={new MemoryStorage()}` instead of `indexedDBStorage` |
| `AclDeniedError` on first read             | First call is a one-shot bootstrap; show a "Connect to token" UI |
| Balance stale after transfer               | You mutated through raw `useZamaSDK()` — use the hook mutation so cache invalidates |
| Hook fails on Sepolia after wallet switch  | `getChainId` in `RelayerWeb` config returned a stale value — make it a function |

---

## See also

- `references/sdk-v3-guide.md` — core SDK API (`ZamaSDK`, `Token`, etc.)
- `references/frontend-integration.md` — legacy `relayer-sdk` patterns
- `templates/react-dashboard.tsx` — full working dashboard example
