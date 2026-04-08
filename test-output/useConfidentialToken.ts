/**
 * useConfidentialToken.ts
 * React hook that encapsulates all FHEVM logic for a ConfidentialERC20 token.
 *
 * Capabilities:
 *  - Initialize FHEVM SDK
 *  - Read encrypted balance handle from contract
 *  - Decrypt balance via user decryption (EIP-712 flow)
 *  - Encrypt an amount and execute a confidential transfer
 *  - Wrap plaintext ERC20 into confidential tokens
 *
 * Written using ONLY the knowledge from the FHEVM skill files.
 */

import { useState, useCallback, useRef, useEffect } from "react";
import { ethers, Contract, type Signer, type Provider } from "ethers";
import { initFhevm, getFhevmInstance, resetFhevm, type FhevmInstance } from "./fhevm-init";

// ---------------------------------------------------------------------------
// ABI fragments -- only the functions we actually call
// ---------------------------------------------------------------------------

const CONFIDENTIAL_ERC20_ABI = [
  // Read encrypted balance handle
  "function balanceOf(address account) view returns (uint256)",
  // Transfer with encrypted input + proof
  "function transfer(address to, bytes32 encryptedAmount, bytes inputProof) returns (bool)",
  // Token metadata
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint64)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
];

const WRAPPED_CONFIDENTIAL_ABI = [
  // Wrap plaintext ERC20 into confidential tokens
  "function wrap(uint64 amount) external",
];

// ---------------------------------------------------------------------------
// Hook state
// ---------------------------------------------------------------------------

export interface ConfidentialTokenState {
  /** Whether the SDK is still initializing */
  sdkReady: boolean;
  /** Last error encountered (reset on next action) */
  error: string | null;

  /** Encrypted handle (opaque -- cannot display to user) */
  encryptedBalanceHandle: string | null;
  /** Decrypted plaintext balance (only set after user decrypts) */
  balance: bigint | null;
  /** True while balance decryption is in flight */
  decrypting: boolean;

  /** True while a transfer tx is being prepared / confirmed */
  transferring: boolean;
  /** True while a wrap tx is being prepared / confirmed */
  wrapping: boolean;

  /** Token metadata */
  tokenName: string | null;
  tokenSymbol: string | null;
  tokenDecimals: number;
}

export interface ConfidentialTokenActions {
  /** Fetch the encrypted balance handle from the contract */
  fetchBalance: () => Promise<void>;
  /** Decrypt the balance using the EIP-712 user-decryption flow */
  decryptBalance: () => Promise<void>;
  /** Encrypt `amount` and send a confidential transfer to `recipient` */
  transfer: (recipient: string, amount: bigint) => Promise<void>;
  /** Approve the confidential contract and wrap plaintext ERC20 tokens */
  wrap: (amount: bigint) => Promise<void>;
}

export type UseConfidentialTokenReturn = ConfidentialTokenState & ConfidentialTokenActions;

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------

export function useConfidentialToken(
  /** Address of the ConfidentialERC20 contract */
  contractAddress: string,
  /** Address of the underlying ERC20 (for wrap). Pass null if wrap is not needed. */
  underlyingErc20Address: string | null,
  /** ethers.js Signer (connected wallet) */
  signer: Signer | null,
): UseConfidentialTokenReturn {
  // -- state ---------------------------------------------------------------
  const [sdkReady, setSdkReady] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [encryptedBalanceHandle, setEncryptedBalanceHandle] = useState<string | null>(null);
  const [balance, setBalance] = useState<bigint | null>(null);
  const [decrypting, setDecrypting] = useState(false);

  const [transferring, setTransferring] = useState(false);
  const [wrapping, setWrapping] = useState(false);

  const [tokenName, setTokenName] = useState<string | null>(null);
  const [tokenSymbol, setTokenSymbol] = useState<string | null>(null);
  const [tokenDecimals, setTokenDecimals] = useState<number>(6);

  // Ref so callbacks always have latest signer without stale closures
  const signerRef = useRef(signer);
  signerRef.current = signer;

  // -- SDK init ------------------------------------------------------------
  useEffect(() => {
    let cancelled = false;

    async function init() {
      if (!signer) return;
      try {
        const provider = signer.provider;
        if (!provider) throw new Error("Signer has no provider");
        await initFhevm({ network: "sepolia", provider });
        if (!cancelled) setSdkReady(true);
      } catch (err: unknown) {
        if (!cancelled) setError(`SDK init failed: ${(err as Error).message}`);
      }
    }

    init();
    return () => { cancelled = true; };
  }, [signer]);

  // -- Load token metadata -------------------------------------------------
  useEffect(() => {
    let cancelled = false;

    async function loadMeta() {
      if (!signer) return;
      try {
        const contract = new Contract(contractAddress, CONFIDENTIAL_ERC20_ABI, signer);
        const [name, symbol, decimals] = await Promise.all([
          contract.name(),
          contract.symbol(),
          contract.decimals(),
        ]);
        if (!cancelled) {
          setTokenName(name);
          setTokenSymbol(symbol);
          setTokenDecimals(Number(decimals));
        }
      } catch {
        // non-critical -- metadata may not be available
      }
    }

    loadMeta();
    return () => { cancelled = true; };
  }, [contractAddress, signer]);

  // -- fetchBalance --------------------------------------------------------
  const fetchBalance = useCallback(async () => {
    setError(null);
    const s = signerRef.current;
    if (!s) { setError("Wallet not connected"); return; }

    try {
      const contract = new Contract(contractAddress, CONFIDENTIAL_ERC20_ABI, s);
      const userAddress = await s.getAddress();
      const handle = await contract.balanceOf(userAddress);
      setEncryptedBalanceHandle(handle.toString());
    } catch (err: unknown) {
      setError(`Failed to fetch balance: ${(err as Error).message}`);
    }
  }, [contractAddress]);

  // -- decryptBalance ------------------------------------------------------
  const decryptBalance = useCallback(async () => {
    setError(null);
    setDecrypting(true);
    const s = signerRef.current;

    try {
      if (!s) throw new Error("Wallet not connected");
      if (!sdkReady) throw new Error("FHEVM SDK not ready");

      const fhevm: FhevmInstance = getFhevmInstance();
      const contract = new Contract(contractAddress, CONFIDENTIAL_ERC20_ABI, s);
      const userAddress = await s.getAddress();

      // 1. Get encrypted handle from contract
      const encHandle = await contract.balanceOf(userAddress);

      // 2. Generate ephemeral keypair
      const keypair = fhevm.generateKeypair();

      // 3. Create EIP-712 typed data for the user to sign
      const contractAddresses = [contractAddress];
      const startTimestamp = Math.floor(Date.now() / 1000).toString();
      const durationDays = "10";

      const eip712 = fhevm.createEIP712(
        keypair.publicKey,
        contractAddresses,
        startTimestamp,
        durationDays,
      );

      // 4. User signs with their wallet (MetaMask popup)
      const signature = await s.signTypedData(
        eip712.domain,
        { UserDecryptRequestVerification: eip712.types.UserDecryptRequestVerification },
        eip712.message,
      );

      // 5. Request decryption through the Relayer
      const result = await fhevm.userDecrypt(
        [{ handle: encHandle, contractAddress }],
        keypair.privateKey,
        keypair.publicKey,
        signature.replace("0x", ""),
        contractAddresses,
        userAddress,
        startTimestamp,
        durationDays,
      );

      // 6. Read the decrypted value
      const clearBalance = result[encHandle] as bigint;
      setBalance(clearBalance);
      setEncryptedBalanceHandle(encHandle.toString());
    } catch (err: unknown) {
      setError(`Decryption failed: ${(err as Error).message}`);
    } finally {
      setDecrypting(false);
    }
  }, [contractAddress, sdkReady]);

  // -- transfer ------------------------------------------------------------
  const transfer = useCallback(async (recipient: string, amount: bigint) => {
    setError(null);
    setTransferring(true);
    const s = signerRef.current;

    try {
      if (!s) throw new Error("Wallet not connected");
      if (!sdkReady) throw new Error("FHEVM SDK not ready");
      if (!ethers.isAddress(recipient)) throw new Error("Invalid recipient address");
      if (amount <= 0n) throw new Error("Amount must be positive");

      const fhevm: FhevmInstance = getFhevmInstance();
      const userAddress = await s.getAddress();

      // 1. Encrypt the amount and generate a ZK proof
      //    The encrypted input is bound to this specific contract + user.
      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, userAddress)
        .add64(amount)
        .encrypt();

      // 2. Call contract.transfer(to, encryptedHandle, inputProof)
      const contract = new Contract(contractAddress, CONFIDENTIAL_ERC20_ABI, s);
      const tx = await contract.transfer(
        recipient,
        encrypted.handles[0],
        encrypted.inputProof,
      );
      await tx.wait();

      // 3. Refresh balance handle (the old handle is invalidated after transfer
      //    because FHE operations produce NEW handles)
      await fetchBalance();
      // Clear cached decrypted balance since the handle changed
      setBalance(null);
    } catch (err: unknown) {
      setError(`Transfer failed: ${(err as Error).message}`);
    } finally {
      setTransferring(false);
    }
  }, [contractAddress, sdkReady, fetchBalance]);

  // -- wrap ----------------------------------------------------------------
  const wrap = useCallback(async (amount: bigint) => {
    setError(null);
    setWrapping(true);
    const s = signerRef.current;

    try {
      if (!s) throw new Error("Wallet not connected");
      if (!underlyingErc20Address) throw new Error("No underlying ERC20 configured");
      if (amount <= 0n) throw new Error("Amount must be positive");

      // Wrap is a plaintext operation:
      //  1. Approve the confidential contract to pull the ERC20 tokens
      //  2. Call wrap(uint64 amount) -- the contract transfers plaintext tokens
      //     from the user and mints encrypted tokens internally

      const erc20 = new Contract(underlyingErc20Address, ERC20_ABI, s);
      const confidential = new Contract(
        contractAddress,
        [...CONFIDENTIAL_ERC20_ABI, ...WRAPPED_CONFIDENTIAL_ABI],
        s,
      );

      // Step 1: Approve (check existing allowance first to avoid unnecessary tx)
      const userAddress = await s.getAddress();
      const currentAllowance: bigint = await erc20.allowance(userAddress, contractAddress);
      if (currentAllowance < amount) {
        const approveTx = await erc20.approve(contractAddress, amount);
        await approveTx.wait();
      }

      // Step 2: Wrap -- plaintext uint64 amount goes in, encrypted balance comes out
      const wrapTx = await confidential.wrap(amount);
      await wrapTx.wait();

      // Refresh balance
      await fetchBalance();
      setBalance(null); // clear cached decryption since handle changed
    } catch (err: unknown) {
      setError(`Wrap failed: ${(err as Error).message}`);
    } finally {
      setWrapping(false);
    }
  }, [contractAddress, underlyingErc20Address, fetchBalance]);

  // -- return --------------------------------------------------------------
  return {
    sdkReady,
    error,
    encryptedBalanceHandle,
    balance,
    decrypting,
    transferring,
    wrapping,
    tokenName,
    tokenSymbol,
    tokenDecimals,
    fetchBalance,
    decryptBalance,
    transfer,
    wrap,
  };
}
