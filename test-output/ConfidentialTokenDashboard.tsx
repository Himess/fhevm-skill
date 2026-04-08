/**
 * ConfidentialTokenDashboard.tsx
 * Complete React component for interacting with a ConfidentialERC20 contract.
 *
 * Features:
 *  - Encrypted balance display with "Decrypt" button (EIP-712 user decryption)
 *  - Confidential transfer form (encrypt amount + send)
 *  - Wrap form (convert plaintext ERC20 -> confidential tokens)
 *  - Full loading / error / success state handling
 *
 * Written using ONLY the knowledge from the FHEVM skill files.
 */

import React, { useState, useEffect, type FormEvent } from "react";
import { BrowserProvider, type Signer } from "ethers";
import { useConfidentialToken } from "./useConfidentialToken";

// ---------------------------------------------------------------------------
// Configuration -- replace with your deployed contract addresses
// ---------------------------------------------------------------------------
const CONFIDENTIAL_TOKEN_ADDRESS = "0x_YOUR_CONFIDENTIAL_ERC20_ADDRESS";
const UNDERLYING_ERC20_ADDRESS = "0x_YOUR_UNDERLYING_ERC20_ADDRESS"; // or null

// ---------------------------------------------------------------------------
// Wallet connection helper (minimal -- replace with wagmi/rainbowkit in prod)
// ---------------------------------------------------------------------------

function useWallet() {
  const [signer, setSigner] = useState<Signer | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [connecting, setConnecting] = useState(false);

  async function connect() {
    setConnecting(true);
    try {
      if (!window.ethereum) throw new Error("No wallet detected");
      const provider = new BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
      const s = await provider.getSigner();
      setSigner(s);
      setAddress(await s.getAddress());
    } catch (err) {
      console.error("Wallet connect failed:", err);
    } finally {
      setConnecting(false);
    }
  }

  function disconnect() {
    setSigner(null);
    setAddress(null);
  }

  return { signer, address, connecting, connect, disconnect };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

function formatBalance(value: bigint, decimals: number): string {
  const divisor = 10n ** BigInt(decimals);
  const whole = value / divisor;
  const frac = value % divisor;
  const fracStr = frac.toString().padStart(decimals, "0").replace(/0+$/, "");
  return fracStr ? `${whole}.${fracStr}` : whole.toString();
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function ErrorBanner({ message, onDismiss }: { message: string; onDismiss: () => void }) {
  return (
    <div style={styles.errorBanner}>
      <span>{message}</span>
      <button onClick={onDismiss} style={styles.dismissBtn}>x</button>
    </div>
  );
}

function BalanceSection({
  encryptedBalanceHandle,
  balance,
  decrypting,
  tokenSymbol,
  tokenDecimals,
  sdkReady,
  onFetch,
  onDecrypt,
}: {
  encryptedBalanceHandle: string | null;
  balance: bigint | null;
  decrypting: boolean;
  tokenSymbol: string | null;
  tokenDecimals: number;
  sdkReady: boolean;
  onFetch: () => void;
  onDecrypt: () => void;
}) {
  // UX states from the skill file:
  //  - Not connected            -> handled by parent
  //  - Connected, not decrypted -> show masked balance
  //  - Decrypting               -> spinner
  //  - Decrypted                -> show plaintext
  const sym = tokenSymbol ?? "TOKENS";

  return (
    <div style={styles.section}>
      <h2>Balance</h2>

      {encryptedBalanceHandle === null ? (
        <div>
          <p style={styles.muted}>Balance not loaded yet.</p>
          <button onClick={onFetch} style={styles.btn}>
            Load Balance
          </button>
        </div>
      ) : balance !== null ? (
        // Decrypted state
        <div>
          <p style={styles.balanceText}>
            {formatBalance(balance, tokenDecimals)} {sym}
          </p>
          <button onClick={onDecrypt} disabled={decrypting || !sdkReady} style={styles.btnSecondary}>
            Refresh
          </button>
        </div>
      ) : (
        // Encrypted handle loaded but not decrypted
        <div>
          <p style={styles.balanceEncrypted}>
            {"●●●●●●"} {sym} <span style={styles.muted}>(encrypted)</span>
          </p>
          <button
            onClick={onDecrypt}
            disabled={decrypting || !sdkReady}
            style={styles.btn}
          >
            {decrypting
              ? "Decrypting... (sign the message in your wallet)"
              : "Decrypt Balance"}
          </button>
          {!sdkReady && (
            <p style={styles.muted}>Initializing encryption SDK...</p>
          )}
        </div>
      )}
    </div>
  );
}

function TransferForm({
  transferring,
  sdkReady,
  onTransfer,
}: {
  transferring: boolean;
  sdkReady: boolean;
  onTransfer: (recipient: string, amount: bigint) => Promise<void>;
}) {
  const [recipient, setRecipient] = useState("");
  const [amount, setAmount] = useState("");
  const [success, setSuccess] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSuccess(false);

    // The skill file notes: let users confirm the plaintext amount BEFORE
    // encryption. We show the amount they entered in the form, then encrypt it.
    const amountBigInt = BigInt(amount);
    await onTransfer(recipient, amountBigInt);
    setSuccess(true);
    setRecipient("");
    setAmount("");
  }

  return (
    <div style={styles.section}>
      <h2>Confidential Transfer</h2>
      <p style={styles.muted}>
        The amount will be encrypted before sending. The transaction will NOT
        revert on insufficient balance -- it will silently transfer 0 (this
        preserves confidentiality).
      </p>
      <form onSubmit={handleSubmit}>
        <div style={styles.formGroup}>
          <label>Recipient Address</label>
          <input
            type="text"
            placeholder="0x..."
            value={recipient}
            onChange={(e) => setRecipient(e.target.value)}
            required
            style={styles.input}
          />
        </div>
        <div style={styles.formGroup}>
          <label>Amount (plaintext -- will be encrypted)</label>
          <input
            type="number"
            placeholder="1000000"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            min="1"
            required
            style={styles.input}
          />
        </div>
        <button
          type="submit"
          disabled={transferring || !sdkReady || !recipient || !amount}
          style={styles.btn}
        >
          {transferring ? "Encrypting & Sending..." : "Send Encrypted Transfer"}
        </button>
      </form>
      {success && <p style={styles.success}>Transfer submitted. Balance will update.</p>}
    </div>
  );
}

function WrapForm({
  wrapping,
  onWrap,
}: {
  wrapping: boolean;
  onWrap: (amount: bigint) => Promise<void>;
}) {
  const [amount, setAmount] = useState("");
  const [success, setSuccess] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setSuccess(false);
    await onWrap(BigInt(amount));
    setSuccess(true);
    setAmount("");
  }

  return (
    <div style={styles.section}>
      <h2>Wrap ERC-20 to Confidential</h2>
      <p style={styles.muted}>
        Converts plaintext ERC-20 tokens into confidential (encrypted) tokens.
        This will first approve the confidential contract, then call wrap().
        The plaintext amount is visible in the wrap transaction, but once
        wrapped, your balance is fully encrypted.
      </p>
      <form onSubmit={handleSubmit}>
        <div style={styles.formGroup}>
          <label>Amount to Wrap (plaintext)</label>
          <input
            type="number"
            placeholder="1000000"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            min="1"
            required
            style={styles.input}
          />
        </div>
        <button
          type="submit"
          disabled={wrapping || !amount}
          style={styles.btn}
        >
          {wrapping ? "Approving & Wrapping..." : "Wrap Tokens"}
        </button>
      </form>
      {success && <p style={styles.success}>Wrap complete. Your encrypted balance has been updated.</p>}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------

export default function ConfidentialTokenDashboard() {
  const wallet = useWallet();

  const token = useConfidentialToken(
    CONFIDENTIAL_TOKEN_ADDRESS,
    UNDERLYING_ERC20_ADDRESS,
    wallet.signer,
  );

  // Auto-fetch balance once SDK is ready
  useEffect(() => {
    if (token.sdkReady && wallet.signer) {
      token.fetchBalance();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token.sdkReady, wallet.signer]);

  // -- Not connected -------------------------------------------------------
  if (!wallet.signer) {
    return (
      <div style={styles.container}>
        <h1>Confidential Token Dashboard</h1>
        <p style={styles.muted}>Connect your wallet to view your encrypted balance.</p>
        <button onClick={wallet.connect} disabled={wallet.connecting} style={styles.btn}>
          {wallet.connecting ? "Connecting..." : "Connect Wallet"}
        </button>
      </div>
    );
  }

  // -- Connected -----------------------------------------------------------
  return (
    <div style={styles.container}>
      <header style={styles.header}>
        <h1>
          {token.tokenName ?? "Confidential Token"}{" "}
          {token.tokenSymbol ? `(${token.tokenSymbol})` : ""}
        </h1>
        <div>
          <span style={styles.address}>{wallet.address}</span>
          <button onClick={wallet.disconnect} style={styles.btnSecondary}>
            Disconnect
          </button>
        </div>
      </header>

      {/* Error banner */}
      {token.error && (
        <ErrorBanner
          message={token.error}
          onDismiss={() => {
            /* The hook clears error on next action, but we can hide it manually */
          }}
        />
      )}

      {/* SDK loading indicator */}
      {!token.sdkReady && (
        <p style={styles.muted}>Initializing FHEVM SDK (loading WASM)...</p>
      )}

      {/* Balance */}
      <BalanceSection
        encryptedBalanceHandle={token.encryptedBalanceHandle}
        balance={token.balance}
        decrypting={token.decrypting}
        tokenSymbol={token.tokenSymbol}
        tokenDecimals={token.tokenDecimals}
        sdkReady={token.sdkReady}
        onFetch={token.fetchBalance}
        onDecrypt={token.decryptBalance}
      />

      {/* Transfer */}
      <TransferForm
        transferring={token.transferring}
        sdkReady={token.sdkReady}
        onTransfer={token.transfer}
      />

      {/* Wrap */}
      {UNDERLYING_ERC20_ADDRESS && (
        <WrapForm wrapping={token.wrapping} onWrap={token.wrap} />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Inline styles (replace with your CSS framework in production)
// ---------------------------------------------------------------------------

const styles: Record<string, React.CSSProperties> = {
  container: {
    maxWidth: 640,
    margin: "40px auto",
    fontFamily: "system-ui, sans-serif",
    padding: "0 16px",
  },
  header: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
    marginBottom: 24,
    flexWrap: "wrap",
    gap: 8,
  },
  section: {
    border: "1px solid #e2e2e2",
    borderRadius: 8,
    padding: 20,
    marginBottom: 20,
  },
  btn: {
    padding: "10px 20px",
    borderRadius: 6,
    border: "none",
    backgroundColor: "#6366f1",
    color: "white",
    cursor: "pointer",
    fontSize: 14,
    fontWeight: 600,
  },
  btnSecondary: {
    padding: "8px 16px",
    borderRadius: 6,
    border: "1px solid #e2e2e2",
    backgroundColor: "transparent",
    cursor: "pointer",
    fontSize: 13,
    marginLeft: 8,
  },
  muted: { color: "#888", fontSize: 13, marginTop: 4 },
  balanceText: { fontSize: 28, fontWeight: 700, margin: "8px 0" },
  balanceEncrypted: { fontSize: 22, fontWeight: 600, margin: "8px 0" },
  formGroup: { marginBottom: 12 },
  input: {
    display: "block",
    width: "100%",
    padding: "8px 12px",
    borderRadius: 6,
    border: "1px solid #ccc",
    marginTop: 4,
    fontSize: 14,
    boxSizing: "border-box",
  },
  errorBanner: {
    backgroundColor: "#fee2e2",
    border: "1px solid #ef4444",
    color: "#991b1b",
    padding: "10px 16px",
    borderRadius: 6,
    marginBottom: 16,
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
  },
  dismissBtn: {
    background: "none",
    border: "none",
    cursor: "pointer",
    fontSize: 16,
    color: "#991b1b",
  },
  success: { color: "#16a34a", marginTop: 8, fontSize: 13 },
  address: { fontSize: 13, color: "#555", fontFamily: "monospace" },
};
