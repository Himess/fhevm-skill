# FHEVM Skill for AI Coding Agents

Production-ready Agent Skills bundle for building, testing, and deploying confidential smart contracts on the Zama Protocol — with offline-capable AI agents (Claude Code, Cursor, Windsurf, Copilot, Codex, Gemini CLI).

Drop the directory into your tool's skill folder, then prompt _"write me a confidential AMM with ERC-7984 wrapping"_ and get correct, working code without internet lookups.

---

## Quick Start

```bash
git clone https://github.com/Himess/fhevm-skill.git
```

Then place the directory wherever your AI tool loads skills from:

| Tool | Path |
|------|------|
| Claude Code | `~/.claude/skills/fhevm/` |
| Cursor | `.cursor/skills/fhevm/` |
| Windsurf | `.windsurf/skills/fhevm/` |
| Copilot | `.github/skills/fhevm/` |
| Codex / Gemini-CLI | drop into the tool's context-loading folder |

The agent will read [`SKILL.md`](SKILL.md) first; that file routes to whichever reference + template it needs for your prompt.

---

## What's Inside

```
fhevm-skill/
├── SKILL.md           ← agent entry point: architecture, decision trees, patterns
├── references/        ← 13 deep-dive guides (types, ACL, decryption, ERC-7984, …)
├── templates/         ← paste-ready files (10 contracts + 6 tests + 2 React frontends + Vite frontend + on-chain E2E + deploy + config)
├── scripts/           ← validate-fhevm.sh — 13-rule lint
├── stress-reports/    ← 9 independent agent stress-test runs (evidence)
└── docs/              ← bounty-compliance + on-chain Sepolia evidence
```

### Templates

Ten production-ready Solidity contracts plus matching tests + two React dashboards:

| Template | Pattern crystallised |
|---|---|
| `confidential-erc20.sol` | ERC-7984 token (OpenZeppelin base) |
| `encrypted-voting.sol` | Confidential yes/no voting + public reveal |
| `multi-option-voting.sol` | N-bucket token-weighted DAO vote (FHE.eq + select chain) |
| `blind-auction.sol` | Sealed-bid auction with **encrypted leader address** (eaddress) |
| `vickrey-auction.sol` | Sealed-bid second-price (top-2 ranking, ERC-7984 escrow, 4-state lifecycle) |
| `confidential-amm.sol` | Single-pair constant-product AMM (encrypted reserves, plaintext LP supply, multiplicative-invariant gate) |
| `cdp-vault.sol` | Encrypted collateral / debt with public-decryptable liquidation flag |
| `confidential-escrow.sol` | Buyer / seller / arbiter escrow |
| `confidential-swap.sol` | Atomic fixed-rate swap |
| `mock-erc20.sol` | Plain ERC-20 for wrap/unwrap testing |
| `react-dashboard.tsx` | React frontend on the foundational SDK (custom contracts, fine-grained control) |
| `react-dashboard-v3.tsx` | React frontend on the high-level Token API (ERC-7984 token UIs) |
| `vite-frontend/` | Vanilla-JS Vite frontend (no React) — fastest path for hackathon-tier prototypes |
| `onchain-e2e.ts` | Paste-ready Sepolia end-to-end script (deploy + encrypt + KMS roundtrip + evidence JSON) |
| `deploy-template.ts` | Plain-ethers deploy script (no hardhat-deploy) |

### Reference guides

`type-system.md` · `acl-patterns.md` · `input-proofs.md` · `decryption-guide.md` · `erc7984-guide.md` · `testing-guide.md` · `frontend-integration.md` · `sdk-v3-guide.md` · `react-sdk-guide.md` · `common-pitfalls.md` · `gas-optimization.md` · `security-checklist.md` · `zama-upstream.md` · `foundry-vs-hardhat.md`

---

## Verification & Evidence

This skill ships with three independent forms of proof.

### On-chain proof — 9/9 templates work on live Sepolia

Every deployable template was exercised end-to-end against the live FHEVM stack: real input proofs, real ACL contract, real KMS roundtrips (3.4 – 8.5 s measured per public-decrypt). Per-template tx hashes, contract addresses, and Etherscan links live in [`docs/onchain-evidence.md`](docs/onchain-evidence.md) and [`docs/onchain-results/eN-*.json`](docs/onchain-results/).

### Agent stress tests — 9 fresh agents, 0 internet, 126/126 generated tests passing

Nine agents across three rounds were given a dApp spec and **only this skill** as context (internet disabled). Each built a distinct application:

| Round | dApp | Generated tests | Self-rated score |
|---|---|---|---|
| R1 | Tip Jar / Pay-Auction / Multi-Vote | 6 + 8 + 10 | 9.0 / 9.0 / 9.0 |
| R2 | Lottery / Payroll / Vickrey | 12 + 17 + 11 | 9.0 / 8.5 / 9.5 |
| R5 | AMM / CDP Vault / KYC + Delegated Decryption | 19 + 22 + 21 | 9.5 / 9.0 / 8.5 |

Total: **126 / 126** tests passing across nine agents, average self-rated quality **9.0 / 10**. Full reports: [`stress-reports/`](stress-reports/).

### Skill-internal validation

- Mock-mode tests exercise every template through `@fhevm/hardhat-plugin@0.4.2` (mock coprocessor + real input-proof flow).
- `scripts/validate-fhevm.sh` lints every contract for the twelve most common FHEVM mistakes — reports zero errors against the shipped templates.
- Every Solidity API claim in references is verified against the locally-installed `@fhevm/solidity@0.11.1`, `@openzeppelin/confidential-contracts@0.4.0`, and `@zama-fhe/relayer-sdk@0.4.1` source.

---

## Bounty Submission Map

For the Zama Developer Program S2 (Skills Track), every rubric criterion is mapped to the file that satisfies it in [`docs/bounty-compliance.md`](docs/bounty-compliance.md). One-line summary:

| Criterion | Where |
|---|---|
| Accuracy | Source-verified API claims · 9/9 Sepolia E2E proof · 22-row Self-Correction Table |
| Completeness | Contracts + Testing + Deployment + Frontend (foundational + Token-API layers) |
| Agent effectiveness | 9 fresh agents · 9 distinct dApps · 126/126 tests · 9.0 / 10 average |
| Code quality | All templates compile, lint clean, run on Sepolia |
| Structure | `SKILL.md` (entry) → `references/` → `templates/` → `scripts/` |
| Error prevention | Self-Correction Table · 17 documented pitfalls · 12-rule lint · battle scars |

---

## Tech Stack

- `@fhevm/solidity` ^0.11.1, `@fhevm/hardhat-plugin` ^0.4.2, `@fhevm/mock-utils` ^0.4.2
- `@openzeppelin/confidential-contracts` ^0.4.0, `@openzeppelin/contracts` ^5.6.1
- `@zama-fhe/relayer-sdk` **EXACT 0.4.1** (foundational SDK; pinned by hardhat-plugin)
- `@zama-fhe/sdk` ^3.0.0, `@zama-fhe/react-sdk` ^3.0.0 (high-level Token API for token UIs)
- Hardhat **2** (`^2.28.4`) — _not_ Hardhat 3
- Solidity ^0.8.27 · `evmVersion: "cancun"` · `viaIR: true`

Pinning rationale and upgrade procedure for breaking Zama versions: [`references/zama-upstream.md`](references/zama-upstream.md).

---

## License

MIT
