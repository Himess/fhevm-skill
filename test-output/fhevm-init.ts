/**
 * fhevm-init.ts
 * Utility file for FHEVM SDK initialization.
 *
 * Handles creating and caching the Relayer SDK instance so it is only
 * initialized once per session. Exposes the singleton via `getFhevmInstance()`.
 *
 * Written using ONLY the knowledge from the FHEVM skill files.
 */

import {
  createInstance,
  SepoliaConfig,
  MainnetConfig,
} from "@zama-fhe/relayer-sdk";
import type { ethers } from "ethers";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** The object returned by `createInstance`. The SDK docs don't export an
 *  explicit interface name, so we infer it from usage.  */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type FhevmInstance = any;

export interface FhevmInitOptions {
  /** "sepolia" (default) or "mainnet" */
  network?: "sepolia" | "mainnet";
  /** Required for mainnet -- the Zama API key.
   *  WARNING: On mainnet this must come through a backend proxy,
   *  never expose it in client-side code. */
  apiKey?: string;
  /** ethers.js provider or `window.ethereum` */
  provider: ethers.Provider | typeof window.ethereum;
}

// ---------------------------------------------------------------------------
// Singleton cache
// ---------------------------------------------------------------------------

let _instance: FhevmInstance | null = null;
let _initPromise: Promise<FhevmInstance> | null = null;

/**
 * Initialize the FHEVM Relayer SDK.
 *
 * Calling this multiple times is safe -- it returns the cached instance.
 * If initialization is already in flight it waits on the same promise.
 */
export async function initFhevm(opts: FhevmInitOptions): Promise<FhevmInstance> {
  if (_instance) return _instance;
  if (_initPromise) return _initPromise;

  _initPromise = _createInstance(opts);

  try {
    _instance = await _initPromise;
    return _instance;
  } catch (err) {
    // Allow retry on failure
    _initPromise = null;
    throw err;
  }
}

/**
 * Return the already-initialized FHEVM instance.
 * Throws if `initFhevm` has not been called yet.
 */
export function getFhevmInstance(): FhevmInstance {
  if (!_instance) {
    throw new Error(
      "FHEVM not initialized. Call initFhevm() first."
    );
  }
  return _instance;
}

/**
 * Tear down the cached instance (useful in tests or on wallet disconnect).
 */
export function resetFhevm(): void {
  _instance = null;
  _initPromise = null;
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

async function _createInstance(opts: FhevmInitOptions): Promise<FhevmInstance> {
  const { network = "sepolia", apiKey, provider } = opts;

  if (network === "mainnet") {
    if (!apiKey) {
      throw new Error(
        "Mainnet requires a Zama API key. Pass it via a backend proxy -- " +
        "never expose it in frontend code."
      );
    }
    return createInstance({
      ...MainnetConfig,
      network: provider,
      auth: { __type: "ApiKeyHeader", value: apiKey },
    });
  }

  // Sepolia (default)
  return createInstance({
    ...SepoliaConfig,
    network: provider,
  });
}
