// ────────────────────────────────────────────────────────────────────────────────
// Gen-3 React dashboard — uses @zama-fhe/react-sdk hooks (current default, Apr 2026).
// Choose this for NEW apps with ERC-7984 confidential tokens — you get
// useConfidentialBalance / useConfidentialTransfer / useShield / useUnshield
// + automatic IndexedDB key cache + react-query invalidation.
//
// For low-level control or non-ERC-7984 contracts, see:
//   → templates/react-dashboard.tsx  (Gen-2: @zama-fhe/relayer-sdk/web, manual flow)
// ────────────────────────────────────────────────────────────────────────────────
//
// templates/react-dashboard-v3.tsx
// Gen-3 React dashboard for ERC-7984 confidential tokens.
//
// Uses @zama-fhe/sdk@3.x + @zama-fhe/react-sdk@3.x.
//
// Setup:
//   npm install @zama-fhe/sdk @zama-fhe/react-sdk @tanstack/react-query \
//               wagmi viem
//
// ⚠ STORAGE BACKEND NOTE:
//   `IndexedDBStorage` reads `globalThis.indexedDB` at instantiation. In SSR /
//   Node / unit-test contexts (no `window`), use `MemoryStorage` instead:
//     import { MemoryStorage } from "@zama-fhe/sdk";  // for tests / Node scripts
//   The Node quickstart in `references/sdk-v3-guide.md` § 3 uses `storage:
//   undefined` to opt into the in-memory default.
//
// Required providers (in app/layout.tsx for Next.js, or main.tsx for Vite):
//
//   <WagmiProvider config={wagmiConfig}>
//     <QueryClientProvider client={queryClient}>
//       <ZamaProvider relayer={relayer} signer={signer} storage={indexedDBStorage}>
//         {children}
//       </ZamaProvider>
//     </QueryClientProvider>
//   </WagmiProvider>
//
// See app/providers.tsx at the bottom of this file for a copy-paste example.

"use client";

import { useState } from "react";
import { useAccount, useConnect, useDisconnect } from "wagmi";
import {
  useConfidentialBalance,
  useConfidentialTransfer,
  useShield,
  useUnshield,
  useMetadata,
  useIsWrapper,
} from "@zama-fhe/react-sdk";

// Fill in your deployed token address before running. Left as `undefined` so
// the dashboard short-circuits with a clear "configure first" message instead
// of silently calling hooks with a garbage placeholder string.
const TOKEN_ADDRESS: `0x${string}` | undefined = undefined;
// Example (uncomment + fill in after deploy):
// const TOKEN_ADDRESS: `0x${string}` | undefined = "0xYourConfidentialTokenAddress";

// Required for shield/unshield (ERC-7984 wrapper). For a non-wrapper token,
// leave this as `undefined` (the `ShieldUnshield` panel below short-circuits
// when the address is falsy). For a wrapper, replace the placeholder with
// the deployed wrapper address — but DO NOT leave a placeholder string in
// production: any truthy value bypasses the short-circuit and the hooks
// receive garbage. Either set a real address or `undefined`.
const WRAPPER_ADDRESS: `0x${string}` | undefined = undefined;
// Example (uncomment + fill in):
// const WRAPPER_ADDRESS: `0x${string}` | undefined = "0xYourWrapperContractAddress";

// ─── Top-level Dashboard ──────────────────────────────────────────────────────

export default function Dashboard() {
  const { address, isConnected } = useAccount();

  if (!TOKEN_ADDRESS) {
    return (
      <div style={{ padding: 24 }}>
        <h2>Configure first</h2>
        <p>Set <code>TOKEN_ADDRESS</code> at the top of <code>react-dashboard-v3.tsx</code> to your deployed ERC-7984 token, then reload.</p>
      </div>
    );
  }

  if (!isConnected) return <ConnectWallet />;

  return (
    <div className="space-y-6 p-6">
      <Header address={address!} />
      <TokenSummary />
      <Balance />
      <TransferForm />
      <ShieldUnshield />
    </div>
  );
}

// ─── Connect / Disconnect ─────────────────────────────────────────────────────

function ConnectWallet() {
  const { connect, connectors } = useConnect();
  return (
    <button onClick={() => connect({ connector: connectors[0] })}>
      Connect Wallet
    </button>
  );
}

function Header({ address }: { address: `0x${string}` }) {
  const { disconnect } = useDisconnect();
  return (
    <div className="flex justify-between">
      <span className="font-mono">{address.slice(0, 6)}…{address.slice(-4)}</span>
      <button onClick={() => disconnect()}>Disconnect</button>
    </div>
  );
}

// ─── Token Info ───────────────────────────────────────────────────────────────

function TokenSummary() {
  const { data: meta, isLoading: metaLoading } = useMetadata(TOKEN_ADDRESS);
  const { data: isWrapper }                    = useIsWrapper(TOKEN_ADDRESS);

  if (metaLoading) return <p>Loading token info…</p>;
  if (!meta)       return null;
  return (
    <div className="rounded border p-4">
      <h2>{meta.name} ({meta.symbol})</h2>
      <p>Decimals: {meta.decimals}</p>
      <p>Wrapper: {isWrapper ? "Yes" : "No"}</p>
    </div>
  );
}

// ─── Balance (auto-decrypts) ──────────────────────────────────────────────────

function Balance() {
  const { data, isLoading, error, refetch } =
    useConfidentialBalance({ tokenAddress: TOKEN_ADDRESS });

  return (
    <div className="rounded border p-4">
      <h3>Encrypted Balance</h3>
      {isLoading && <p>Decrypting…</p>}
      {error && <p className="text-red-600">Error: {error.message}</p>}
      {data !== undefined && (
        <p className="text-2xl font-bold">{data.toString()}</p>
      )}
      <button onClick={() => refetch()}>Refresh</button>
    </div>
  );
}

// ─── Confidential Transfer ────────────────────────────────────────────────────

function TransferForm() {
  const { mutateAsync, isPending, error } =
    useConfidentialTransfer({ tokenAddress: TOKEN_ADDRESS });
  const [to, setTo]         = useState("");
  const [amount, setAmount] = useState("");

  return (
    <form
      className="space-y-2 rounded border p-4"
      onSubmit={async (e) => {
        e.preventDefault();
        // mutateAsync resolves with { txHash, receipt } once mined — no .wait() needed.
        await mutateAsync({
          to: to as `0x${string}`,
          amount: BigInt(amount),
        });
        setTo("");
        setAmount("");
      }}
    >
      <h3>Transfer</h3>
      <input
        value={to}
        onChange={(e) => setTo(e.target.value)}
        placeholder="0xRecipient"
      />
      <input
        type="number"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        placeholder="Amount"
      />
      <button type="submit" disabled={isPending}>
        {isPending ? "Sending…" : "Transfer"}
      </button>
      {error && <p className="text-red-600">Error: {error.message}</p>}
    </form>
  );
}

// ─── Shield / Unshield (only for ERC-7984 wrappers) ───────────────────────────

function ShieldUnshield() {
  const { data: isWrapper } = useIsWrapper(TOKEN_ADDRESS);
  const { mutateAsync: shield,   isPending: isShielding   } = useShield({
    tokenAddress: TOKEN_ADDRESS,
    wrapperAddress: WRAPPER_ADDRESS,
  });
  const { mutateAsync: unshield, isPending: isUnshielding } = useUnshield({
    tokenAddress: TOKEN_ADDRESS,
    wrapperAddress: WRAPPER_ADDRESS,
  });
  const [amount, setAmount] = useState("");

  if (!isWrapper || !WRAPPER_ADDRESS) return null;

  return (
    <div className="rounded border p-4 space-y-2">
      <h3>Shield / Unshield</h3>
      <input
        type="number"
        value={amount}
        onChange={(e) => setAmount(e.target.value)}
        placeholder="Amount"
      />
      <div className="flex gap-2">
        <button
          disabled={isShielding}
          onClick={async () => {
            await shield({ amount: BigInt(amount) });
            setAmount("");
          }}
        >
          {isShielding ? "Shielding…" : "Shield (ERC-20 → 7984)"}
        </button>
        <button
          disabled={isUnshielding}
          onClick={async () => {
            await unshield({ amount: BigInt(amount) });
            setAmount("");
          }}
        >
          {isUnshielding ? "Unshielding…" : "Unshield (7984 → ERC-20)"}
        </button>
      </div>
    </div>
  );
}

// ─── app/providers.tsx (paste into your Next.js / Vite root) ──────────────────
//
// "use client";
//
// import { WagmiProvider, createConfig, http } from "wagmi";
// import { sepolia } from "wagmi/chains";
// import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
// import {
//   ZamaProvider,
//   RelayerWeb,
//   indexedDBStorage,
//   SepoliaConfig,
// } from "@zama-fhe/react-sdk";
// import { WagmiSigner } from "@zama-fhe/react-sdk/wagmi";
//
// const wagmiConfig = createConfig({
//   chains: [sepolia],
//   transports: { [sepolia.id]: http() },
// });
// const queryClient = new QueryClient();
//
// const relayer = new RelayerWeb({
//   getChainId: async () => sepolia.id,  // Must return Promise<number>
//   transports: {
//     [sepolia.id]: {
//       relayerUrl: SepoliaConfig.relayerUrl,
//       network:    SepoliaConfig.network,
//     },
//   },
// });
// const signer = new WagmiSigner({ config: wagmiConfig });
//
// export function Providers({ children }: { children: React.ReactNode }) {
//   return (
//     <WagmiProvider config={wagmiConfig}>
//       <QueryClientProvider client={queryClient}>
//         <ZamaProvider relayer={relayer} signer={signer} storage={indexedDBStorage}>
//           {children}
//         </ZamaProvider>
//       </QueryClientProvider>
//     </WagmiProvider>
//   );
// }
