// templates/onchain-e2e.ts
//
// Paste-ready Sepolia end-to-end script: deploy → encrypt → submit → KMS
// roundtrip → verify on-chain. Uses the foundational SDK (@zama-fhe/relayer-sdk
// /node), NOT the hardhat-plugin's `fhevm` helper (that one only works inside
// `npx hardhat test`).
//
// Run with:
//   npx hardhat run scripts/onchain-e2e.ts --network sepolia
//   (or `ts-node scripts/onchain-e2e.ts` once SEPOLIA_RPC + DEPLOYER_PRIVATE_KEY
//   are in env — the script bypasses hre.ethers entirely, see WHY-RAW-ETHERS)
//
// What this template demonstrates:
//   1. Deploy a contract with plain ethers (no hardhat-deploy)
//   2. Encrypt an input via the Node SDK (real ZK proof, not mock)
//   3. Submit the tx, wait for receipt, assert status == 1
//   4. Public-decrypt a handle through the live KMS (real 5-10s roundtrip)
//   5. Save tx hashes + Etherscan links to a JSON evidence file
//
// Adapt the contract name, constructor args, and the call/decrypt flow to
// your contract. The harness around it (ephemeral wallets, delta tracking,
// public-decrypt + on-chain checkSignatures) is the canonical pattern.
//
// PRECONDITIONS:
//   - SEPOLIA_RPC + DEPLOYER_PRIVATE_KEY in process.env (or hardhat vars)
//   - Deployer has Sepolia ETH (faucets in SKILL.md § Sepolia Deployment)
//   - @fhevm/hardhat-plugin@0.4.2 + @zama-fhe/relayer-sdk@0.4.1 EXACT installed
//   - Contract artifact has been compiled (`npx hardhat compile` once)
//
// ─── WHY-RAW-ETHERS ─────────────────────────────────────────────────
// On Sepolia, `@fhevm/hardhat-plugin@0.4.2` wraps `hre.ethers` with a
// `FhevmProviderExtender` that throws "The Hardhat Fhevm plugin is not
// initialized." when you call `hre.ethers.getSigners()` from a script that
// runs OUTSIDE the plugin's mock test runner. Localhost/mock-mode works,
// Sepolia does not. Stress-test agents reproduced this in Round 4.
//
// Workaround used here: bypass `hre.ethers` and construct a raw
// `ethers.JsonRpcProvider` + `ethers.Wallet`. We still load the contract
// ABI via `hre.artifacts.readArtifactSync(...)` so you keep the type-safe
// compile pipeline. Inside `npx hardhat test`, prefer the `fhevm` helper.

import { ethers } from "ethers"; // raw ethers, NOT `from "hardhat"`
import hre from "hardhat";
import { writeFileSync, existsSync, mkdirSync } from "fs";
import { join } from "path";

// ─── RAW PROVIDER + SIGNER (avoids FhevmProviderExtender on Sepolia) ──
const SEPOLIA_RPC = process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com";
const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY;
if (!PRIVATE_KEY) throw new Error("DEPLOYER_PRIVATE_KEY not set in env");
const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC);
const deployer = new ethers.Wallet(PRIVATE_KEY, provider);

// Lazy-import the relayer SDK so a script that doesn't need the WASM doesn't
// pay the init cost. Top-level import is fine; this just keeps the helper
// composable.
let _fhevmInstance: any = null;
async function getFhevm() {
  if (_fhevmInstance) return _fhevmInstance;
  const { createInstance, SepoliaConfig } = await import("@zama-fhe/relayer-sdk/node");
  // SepoliaConfig is the canonical addresses + chain IDs; only `network`
  // needs to be supplied (RPC URL string for Node, never a Provider).
  _fhevmInstance = await createInstance({
    ...SepoliaConfig,
    network: "https://ethereum-sepolia-rpc.publicnode.com",
  });
  return _fhevmInstance;
}

function etherscan(hashOrAddr: string, type: "tx" | "address" = "tx") {
  return `https://sepolia.etherscan.io/${type}/${hashOrAddr}`;
}

async function waitForTx(tx: any, label: string) {
  console.log(`  → ${label} tx ${tx.hash}`);
  const r = await tx.wait();
  if (!r || r.status !== 1) {
    throw new Error(`Tx ${label} REVERTED (status=${r?.status}) hash=${tx.hash}`);
  }
  console.log(`    ✓ block ${r.blockNumber}, gas ${r.gasUsed}`);
  return r;
}

function saveResults(name: string, data: any) {
  const dir = join(__dirname, "..", "onchain-results");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  const path = join(dir, `${name}.json`);
  writeFileSync(path, JSON.stringify(data, null, 2));
  console.log(`✓ saved ${path}`);
}

// ─── E2E: adapt the body to your contract ───────────────────────────
async function main() {
  console.log("=== Onchain E2E on Sepolia ===");
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await provider.getBalance(deployer.address)),
    "ETH",
  );

  // 1. DEPLOY ────────────────────────────────────────────────────────
  // Replace "MyContract" + constructor args with your deployment.
  // Artifact is read from the hardhat compile output; the deploy itself
  // uses raw ethers so we never touch the FhevmProviderExtender.
  console.log("\n[1] Deploy MyContract");
  const artifact = hre.artifacts.readArtifactSync("MyContract");
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, deployer);
  const contract = await factory.deploy(/* constructor args */);
  await contract.waitForDeployment();
  const addr = await contract.getAddress();
  const deployTxHash = contract.deploymentTransaction()?.hash;
  console.log("  ✓ deployed at:", addr);
  console.log("    " + etherscan(addr, "address"));

  // 2. ENCRYPT INPUT ─────────────────────────────────────────────────
  console.log("\n[2] Encrypt input via real Sepolia relayer");
  const fhevm = await getFhevm();
  const buf = fhevm.createEncryptedInput(addr, deployer.address);
  buf.add64(42n); // adapt: addBool / add8 / add16 / add32 / addAddress
  const enc = await buf.encrypt();
  // Node SDK returns Uint8Array handles. Hex-encode for logging / contract calls
  // that expect bytes32 strings (ethers v6 accepts BytesLike, so Uint8Array
  // also works directly).
  const handle = "0x" + Buffer.from(enc.handles[0]).toString("hex");
  const inputProof = "0x" + Buffer.from(enc.inputProof).toString("hex");
  console.log(`    handle: ${handle.slice(0, 18)}...`);

  // 3. SUBMIT TX ─────────────────────────────────────────────────────
  console.log("\n[3] Submit on-chain");
  const tx = await contract.myMethod(handle, inputProof); // ← your method
  const receipt = await waitForTx(tx, "myMethod");

  // 4. PUBLIC DECRYPT (KMS roundtrip) ────────────────────────────────
  // Skip this section if your contract doesn't use FHE.makePubliclyDecryptable.
  // For user-decrypt instead, see the userDecrypt block at the bottom.
  console.log("\n[4] Public-decrypt result handle (real KMS — 5-10s)");
  const t0 = Date.now();
  // Wait briefly so the KMS has registered the makePubliclyDecryptable.
  await new Promise((r) => setTimeout(r, 5000));
  // If the contract emits a handle in an event:
  const filter = contract.filters.SomeEvent?.();
  let resultHandle: string | undefined;
  if (filter) {
    const events = await contract.queryFilter(filter, receipt.blockNumber, receipt.blockNumber);
    if (events.length > 0) resultHandle = (events[0].args as any).resultHandle as string;
  }
  if (!resultHandle) {
    // Fallback: contract exposes a view returning the bytes32 handle
    resultHandle = await (contract as any).resultHandle();
  }
  console.log(`    handle: ${resultHandle.slice(0, 18)}...`);

  const decrypted = await fhevm.publicDecrypt([resultHandle]);
  console.log(`  ✓ KMS roundtrip ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  console.log(`    cleartext: ${decrypted.clearValues[resultHandle]}`);

  // Submit the KMS proof on-chain via FHE.checkSignatures()
  // (your contract needs a function that calls FHE.checkSignatures internally).
  console.log("\n[5] Submit KMS proof on-chain via revealResult");
  const revealTx = await (contract as any).revealResult(
    decrypted.abiEncodedClearValues,
    decrypted.decryptionProof,
  );
  await waitForTx(revealTx, "revealResult");

  // ─── (alternative) USER DECRYPT path ────────────────────────────
  // Uncomment to user-decrypt a handle the contract has FHE.allow'd to
  // your address. EIP-712 signature flow. Note `deployer` here is the
  // raw `ethers.Wallet` from the top of the file — `signTypedData` works
  // identically.
  /*
  console.log("\n[alt] User-decrypt own state (real KMS)");
  const stateHandle = await (contract as any).getMyState();
  const handleHex = ethers.toBeHex(stateHandle, 32);
  const keypair = fhevm.generateKeypair();
  const startTs = Math.floor(Date.now() / 1000);
  const days = 1;
  const eip712 = fhevm.createEIP712(keypair.publicKey, [addr], startTs, days);
  const sig = await deployer.signTypedData(
    eip712.domain,
    { UserDecryptRequestVerification: [...eip712.types.UserDecryptRequestVerification] },
    eip712.message,
  );
  const result = await fhevm.userDecrypt(
    [{ handle: handleHex, contractAddress: addr }],
    keypair.privateKey,
    keypair.publicKey,
    sig.slice(2),
    [addr],
    deployer.address,
    startTs,
    days,
  );
  console.log(`  ✓ cleartext: ${result[handleHex]}`);
  */

  // 6. SAVE EVIDENCE ──────────────────────────────────────────────────
  saveResults("my-contract-e2e", {
    contract: "MyContract",
    address: addr,
    deployTx: deployTxHash,
    submitTx: tx.hash,
    revealTx: revealTx.hash,
    handle,
    resultHandle,
    cleartext: decrypted.clearValues[resultHandle].toString(),
    timestamp: new Date().toISOString(),
    etherscan: {
      contract: etherscan(addr, "address"),
      deploy: etherscan(deployTxHash!),
      submit: etherscan(tx.hash),
      reveal: etherscan(revealTx.hash),
    },
    status: "PASS",
  });

  console.log("\n=== E2E PASS ===");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
