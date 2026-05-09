# Foundry vs Hardhat — Why This Skill Targets Hardhat

> **TL;DR**: Zama maintains both contract toolchains as first-class options. This skill targets **Hardhat** because the official `@fhevm/hardhat-plugin` is the most mature FHEVM testing stack and is what the bounty's "Hardhat template" topic is built on. Foundry is a valid second path; this file documents the trade-off so you can pick consciously.

---

## The two official toolchains (verified May 2026)

| Path | Repo | Last push | Stars | Status |
|---|---|---|---|---|
| **Hardhat** | [`zama-ai/fhevm-hardhat-template`](https://github.com/zama-ai/fhevm-hardhat-template) | 2026-05-04 | 133 ⭐ | Active, NOT archived |
| **Hardhat plugin** | [`zama-ai/fhevm-hardhat-plugin`](https://github.com/zama-ai/fhevm-hardhat-plugin) | 2026-03-25 | 16 ⭐ | Active, NOT archived |
| **Foundry** | [`zama-ai/forge-fhevm`](https://github.com/zama-ai/forge-fhevm) | 2026-04-28 | 4 ⭐ | Active, very early |
| **React frontend template** | [`zama-ai/fhevm-react-template`](https://github.com/zama-ai/fhevm-react-template) | 2026-05-07 | 157 ⭐ | Foundry-based |

The React template adopted Foundry for its frontend-dApp flow. The standalone Hardhat template stayed on Hardhat and is still actively maintained — neither is being deprecated.

## Why this skill picks Hardhat

| Reason | What you get |
|---|---|
| **Mock-mode coprocessor** | `@fhevm/hardhat-plugin@0.4.2` ships an in-process FHE mock that lets every test run in milliseconds against a fresh chain. forge-fhevm has helpers for cleartext testing but the deepest mock infrastructure is in the Hardhat plugin. |
| **`fhevm.userDecryptEuint` / `awaitDecryptionOracle`** | Hardhat tests can decrypt encrypted handles directly inside Mocha; Foundry needs an off-chain script. |
| **Maturity gap** | Hardhat plugin: 16 ⭐, 14 months of releases. forge-fhevm: 4 ⭐, < 6 months old. We pin to what's been battle-tested. |
| **Bounty rubric alignment** | The Zama Developer Program S2 bounty topic list explicitly includes *"Setting up the development environment using **the Hardhat template**"*. Foundry isn't in the rubric. |
| **Plugin pin-chain reality** | `@fhevm/hardhat-plugin@0.4.2` pins `@zama-fhe/relayer-sdk@0.4.1` exactly. That's the SDK every test in this skill uses, including the on-chain Sepolia E2E proof in `docs/onchain-evidence.md`. |

## When Foundry is the right call

You should reach for Foundry over Hardhat when:

1. **You're cloning the official React frontend template** — `zama-ai/fhevm-react-template` is Foundry-based, and aligning with it (over re-doing the contract layer in Hardhat) is sensible.
2. **You want Solidity-native unit tests** — `forge test`'s `vm.startPrank`, fuzzing, and invariants are nicer than Mocha for some flows.
3. **You're in a Foundry-native shop** — re-tooling to Hardhat just for FHEVM is a friction tax.

Even then, you can mix: write Foundry contract tests + use Hardhat-driven mock decryption helpers for the encryption flows the plugin handles best.

## Direct equivalents (cheat-sheet for Foundry users)

If you're translating this skill's patterns into a Foundry project, these are the rough equivalents:

| Hardhat (this skill) | Foundry (forge-fhevm) |
|---|---|
| `@fhevm/hardhat-plugin@0.4.2` | `forge-fhevm` (Solidity helpers + cleartext host) |
| `import { fhevm } from "hardhat"` | `import "forge-fhevm/FHE.sol"` (test-only helpers) |
| `await fhevm.createEncryptedInput(...).add64(n).encrypt()` | `bytes32 handle = vm.encryptU64(n)` (cleartext mode) |
| `await fhevm.userDecryptEuint(FhevmType.euint64, handle, addr, signer)` | `uint64 v = vm.decryptU64(handle, signer)` (cleartext mode) |
| `npx hardhat test` | `forge test` |
| `templates/hardhat.config.ts` | `foundry.toml` (set `evm_version = "cancun"` + IR via `via_ir = true`) |
| `templates/deploy-template.ts` | `script/Deploy.s.sol` + `forge script` |

The on-chain Solidity API (`FHE.add`, `FHE.allowThis`, `FHE.fromExternal`, `ZamaEthereumConfig`) is **identical** — your contracts drop in unchanged.

## Two open questions if you pick Foundry

1. **Real KMS roundtrips on Sepolia** — Forge scripts can deploy to Sepolia and call contracts, but encrypting client-side requires the Node SDK (`@zama-fhe/relayer-sdk/node`), which works fine but bypasses forge-fhevm. The pattern from `templates/onchain-e2e.ts` (this skill) ports verbatim — just call it from `forge script` or via `cast` instead of `npx hardhat run`.

2. **Mock-mode parity** — forge-fhevm's cleartext mode is for fast unit tests, but it doesn't simulate the gateway, KMS proof verification, or HCU limits. The Hardhat plugin simulates more of these. If you need that level of fidelity, run a Hardhat test suite alongside your Foundry one.

## Bottom line

This skill is opinionated about Hardhat for the same reason it's opinionated about exact-pinning `@zama-fhe/relayer-sdk@0.4.1`: there's a single correct answer for the bounty rubric and the most-used FHEVM-dev path, and we pick it. If your project is Foundry-native, lift the Solidity templates (they're framework-agnostic) and the patterns from `references/`, then translate the test scaffold using the cheat-sheet above.

We will revisit this position if Zama archives `fhevm-hardhat-template` or makes `@fhevm/hardhat-plugin` Foundry-incompatible. As of May 2026 neither has happened.
