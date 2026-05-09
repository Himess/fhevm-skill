// templates/vite-frontend/src/main.js
//
// Vanilla-JS confidential-dApp frontend using the foundational SDK
// (@zama-fhe/relayer-sdk/web). NOT React. Drop into any Vite project,
// pair with templates/vite-frontend/vite.config.js and the index.html
// in the parent directory.
//
// Replace CONTRACT_ADDRESS + CONTRACT_ABI with your deployment, swap
// the encrypt-then-call body inside `submit()` for whatever your
// contract method needs (single euint64 input shown).
//
// What this template demonstrates:
//   1. Connect wallet (MetaMask) on Sepolia
//   2. Initialize the relayer-sdk WASM lazily on first action
//      (initSDK() must run before any createInstance() call)
//   3. Encrypt a uint64 input client-side, get handle + inputProof
//   4. Submit on-chain with a typed contract call
//
// For ERC-7984 token UIs (balances, transfers, wraps), prefer the
// react-sdk Token API in templates/react-dashboard-v3.tsx.

import { ethers } from "ethers";
import { createInstance, SepoliaConfig, initSDK } from "@zama-fhe/relayer-sdk/web";

// ─── CONFIG: fill these in ────────────────────────────────────────
const CONTRACT_ADDRESS = "0xYOUR_CONTRACT_ADDRESS"; // ← replace
const CONTRACT_ABI = [
  // Example: a deposit function with one encrypted euint64 input.
  // The wire types are: externalEuint64 → bytes32, bytes inputProof.
  "function deposit(bytes32 encAmount, bytes inputProof)",
];
const SEPOLIA_CHAIN_ID_HEX = "0xaa36a7"; // 11155111

// ─── State ─────────────────────────────────────────────────────────
let provider, signer, contract, fhevm;

const $ = (id) => document.getElementById(id);
function log(msg, kind = "") {
  const ts = new Date().toLocaleTimeString();
  $("log").insertAdjacentHTML(
    "beforeend",
    `<div class="${kind}">${ts}  ${msg}</div>`,
  );
  $("log").scrollTop = $("log").scrollHeight;
}

// ─── Wallet connect ─────────────────────────────────────────────────
$("connect").addEventListener("click", async () => {
  if (!window.ethereum) return log("MetaMask not found", "warn");
  try {
    const eth = window.ethereum;
    const chain = await eth.request({ method: "eth_chainId" });
    if (chain !== SEPOLIA_CHAIN_ID_HEX) {
      log("switching network → Sepolia…");
      await eth.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: SEPOLIA_CHAIN_ID_HEX }],
      });
    }
    provider = new ethers.BrowserProvider(eth);
    signer = await provider.getSigner();
    const addr = await signer.getAddress();
    contract = new ethers.Contract(CONTRACT_ADDRESS, CONTRACT_ABI, signer);
    $("addr").textContent = addr.slice(0, 6) + "…" + addr.slice(-4);
    $("net").textContent = "Sepolia (11155111)";
    $("status").textContent = "— connected";
    $("status").style.color = "#7fbf7f";
    $("connect").textContent = "Connected";
    $("connect").disabled = true;
    $("actions").hidden = false;
    log("wallet connected", "ok");
  } catch (err) {
    log("connect failed: " + (err?.message ?? err), "warn");
  }
});

// ─── Submit encrypted action ────────────────────────────────────────
$("submit").addEventListener("click", async () => {
  const amount = $("amount").value;
  if (!amount || amount <= 0) return log("enter a positive amount", "warn");
  try {
    if (!fhevm) {
      log("initializing relayer SDK (loads WASM, ~3 s)…");
      await initSDK();                  // MUST run before createInstance
      fhevm = await createInstance({
        ...SepoliaConfig,
        network: window.ethereum,
      });
      log("SDK ready", "ok");
    }
    log(`encrypting amount ${amount}…`);
    const enc = await fhevm
      .createEncryptedInput(CONTRACT_ADDRESS, await signer.getAddress())
      .add64(BigInt(amount))
      .encrypt();
    log("ciphertext + proof generated", "ok");

    log("submitting tx…");
    const tx = await contract.deposit(enc.handles[0], enc.inputProof);
    log(`tx ${tx.hash}`);
    const r = await tx.wait();
    log(`mined in block ${r.blockNumber}`, "ok");
  } catch (err) {
    log("submit failed: " + (err?.shortMessage ?? err?.message ?? err), "warn");
    console.error(err);
  }
});

log("ready — click Connect MetaMask to begin");
