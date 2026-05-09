// vite.config.js — confidential dApp frontend (no React).
//
// CRITICAL: `@zama-fhe/relayer-sdk/web` ships a WASM blob for FHE
// keygen + input-proof construction. Vite's default dependency
// pre-bundler tries to optimize the import, which strips the WASM
// init path and breaks at runtime with `WebAssembly.compile()` errors.
//
// Excluding the package from `optimizeDeps` keeps the WASM-loading
// import graph intact. This is THE one Vite-specific config you
// need — every other concern (HMR, TS, etc.) works out of the box.
import { defineConfig } from "vite";

export default defineConfig({
  optimizeDeps: {
    exclude: ["@zama-fhe/relayer-sdk"],
  },
  server: {
    port: 5173,
    // Some browsers require COOP/COEP headers for SharedArrayBuffer
    // (used by the relayer-sdk WASM threadpool). If you see
    // `SharedArrayBuffer is not defined` errors, uncomment:
    // headers: {
    //   "Cross-Origin-Opener-Policy":   "same-origin",
    //   "Cross-Origin-Embedder-Policy": "require-corp",
    // },
  },
});
