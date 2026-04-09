// Example React dashboard for interacting with an ERC-7984 confidential token.
// Uses @zama-fhe/relayer-sdk/web for encryption/decryption.
// Requires: "use client" directive for Next.js compatibility.
"use client";

import { useState, useEffect, useCallback } from "react";
import { ethers } from "ethers";

// ERC-7984 ABI (externalEuint64 = bytes32 in ABI, euint64 return = uint256)
const TOKEN_ABI = [
  // ERC-7984 standard
  "function confidentialTransfer(address to, bytes32 encAmount, bytes proof) returns (uint256)",
  "function confidentialTransferFrom(address from, address to, bytes32 encAmount, bytes proof) returns (uint256)",
  "function confidentialBalanceOf(address account) view returns (uint256)",
  "function setOperator(address operator, uint48 until)",
  "function isOperator(address holder, address spender) view returns (bool)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  // Owner functions
  "function mint(address to, uint64 amount)",
  "function owner() view returns (address)",
  // Wrap/Unwrap (if ERC7984ERC20Wrapper)
  "function wrap(address to, uint256 amount)",
  "function unwrap(address from, address to, uint64 amount)",
  "function underlying() view returns (address)",
];

// For window.ethereum TypeScript support, add to your project's global.d.ts:
// declare global { interface Window { ethereum?: import("ethers").Eip1193Provider; } }

const TOKEN_ADDRESS = "0x..."; // Your deployed token address

export default function ConfidentialTokenDashboard() {
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  const [address, setAddress] = useState("");
  const [fhevm, setFhevm] = useState<any>(null);
  const [balance, setBalance] = useState<string>("●●●●●●");
  const [status, setStatus] = useState("Not connected");

  // ─── Connect Wallet ───────────────────────────────────────────
  const connect = useCallback(async () => {
    if (!window.ethereum) return setStatus("No wallet found");
    const provider = new ethers.BrowserProvider(window.ethereum);
    const s = await provider.getSigner();
    setSigner(s);
    setAddress(await s.getAddress());

    // Dynamic import — SSR safe
    const { createInstance, SepoliaConfig } = await import("@zama-fhe/relayer-sdk/web");
    const instance = await createInstance({ ...SepoliaConfig, network: window.ethereum });
    setFhevm(instance);
    setStatus("Connected");
  }, []);

  // ─── Decrypt Balance ──────────────────────────────────────────
  const decryptBalance = useCallback(async () => {
    if (!signer || !fhevm) return;
    setStatus("Decrypting...");
    try {
      const contract = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, signer);
      const encHandle = await contract.confidentialBalanceOf(address);

      // EIP-712 user decryption flow
      const keypair = fhevm.generateKeypair();
      const startTimestamp = Math.floor(Date.now() / 1000);
      const eip712 = fhevm.createEIP712(
        keypair.publicKey,
        [TOKEN_ADDRESS],
        startTimestamp,
        10,
      );
      const signature = await signer.signTypedData(
        eip712.domain,
        { UserDecryptRequestVerification: eip712.types.UserDecryptRequestVerification },
        eip712.message,
      );
      const result = await fhevm.userDecrypt(
        [{ handle: encHandle, contractAddress: TOKEN_ADDRESS }],
        keypair.privateKey,
        keypair.publicKey,
        (signature as string).replace("0x", ""),
        [TOKEN_ADDRESS],
        address,
        startTimestamp,
        10,
      );
      // encHandle from contract is a bigint — convert to 32-byte hex for lookup
      const hexHandle = ethers.toBeHex(encHandle, 32);
      setBalance(result[hexHandle]?.toString() ?? "0");
      setStatus("Decrypted");
    } catch (err: any) {
      setStatus(`Decrypt failed: ${err.message}`);
    }
  }, [signer, fhevm, address]);

  // ─── Transfer ─────────────────────────────────────────────────
  const [transferTo, setTransferTo] = useState("");
  const [transferAmount, setTransferAmount] = useState("");

  const transfer = useCallback(async () => {
    if (!signer || !fhevm) return;
    setStatus("Encrypting...");
    try {
      const contract = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, signer);
      const encrypted = await fhevm
        .createEncryptedInput(TOKEN_ADDRESS, address)
        .add64(BigInt(transferAmount))
        .encrypt();

      setStatus("Sending transaction...");
      const tx = await contract["confidentialTransfer(address,bytes32,bytes)"](
        transferTo,
        encrypted.handles[0],
        encrypted.inputProof,
      );
      await tx.wait();
      setStatus("Transfer complete!");
      setBalance("●●●●●●"); // Reset — needs re-decrypt
    } catch (err: any) {
      setStatus(`Transfer failed: ${err.message}`);
    }
  }, [signer, fhevm, address, transferTo, transferAmount]);

  // ─── Admin: Mint (owner only) ──────────────────────────────────
  const [mintTo, setMintTo] = useState("");
  const [mintAmount, setMintAmount] = useState("");
  const [isOwner, setIsOwner] = useState(false);

  useEffect(() => {
    if (!signer || !address) return;
    const contract = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, signer);
    contract.owner().then((o: string) => setIsOwner(o.toLowerCase() === address.toLowerCase())).catch(() => {});
  }, [signer, address]);

  const mint = useCallback(async () => {
    if (!signer) return;
    setStatus("Minting...");
    try {
      const contract = new ethers.Contract(TOKEN_ADDRESS, TOKEN_ABI, signer);
      const tx = await contract.mint(mintTo || address, BigInt(mintAmount));
      await tx.wait();
      setStatus("Minted!");
    } catch (err: any) {
      setStatus(`Mint failed: ${err.message}`);
    }
  }, [signer, address, mintTo, mintAmount]);

  // ─── Render ───────────────────────────────────────────────────
  return (
    <div style={{ maxWidth: 480, margin: "auto", padding: 24, fontFamily: "monospace" }}>
      <h2>Confidential Token Dashboard</h2>

      {!signer ? (
        <button onClick={connect}>Connect Wallet</button>
      ) : (
        <>
          <p>Address: {address.slice(0, 6)}...{address.slice(-4)}</p>
          <p>Status: {status}</p>

          {/* Balance */}
          <div style={{ margin: "16px 0", padding: 12, border: "1px solid #333" }}>
            <p>Balance: {balance}</p>
            <button onClick={decryptBalance}>Decrypt Balance</button>
          </div>

          {/* Admin: Mint (only visible to owner) */}
          {isOwner && (
            <div style={{ margin: "16px 0", padding: 12, border: "1px solid #090" }}>
              <h3>Admin: Mint</h3>
              <input
                placeholder="Recipient (or leave empty for self)"
                value={mintTo}
                onChange={(e) => setMintTo(e.target.value)}
                style={{ width: "100%", marginBottom: 8 }}
              />
              <input
                type="number"
                placeholder="Amount"
                value={mintAmount}
                onChange={(e) => setMintAmount(e.target.value)}
                style={{ width: "100%", marginBottom: 8 }}
              />
              <button onClick={mint}>Mint Tokens</button>
            </div>
          )}

          {/* Transfer */}
          <div style={{ margin: "16px 0", padding: 12, border: "1px solid #333" }}>
            <h3>Transfer</h3>
            <input
              placeholder="Recipient address"
              value={transferTo}
              onChange={(e) => setTransferTo(e.target.value)}
              style={{ width: "100%", marginBottom: 8 }}
            />
            <input
              type="number"
              placeholder="Amount"
              value={transferAmount}
              onChange={(e) => setTransferAmount(e.target.value)}
              style={{ width: "100%", marginBottom: 8 }}
            />
            <button onClick={transfer}>Send Encrypted Transfer</button>
          </div>
        </>
      )}
    </div>
  );
}
