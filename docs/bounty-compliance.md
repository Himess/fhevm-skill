# Bounty Compliance Map — Zama Developer Program S2, Bounty Track

> One-page judge's guide. Every requirement from the bounty page, mapped to the
> exact file and line number that satisfies it, plus the independent evidence
> that proves it works.

**Submission:** `github.com/Himess/fhevm-skill`
**Deadline:** May 10, 2026, 23:59 AOE
**Skill version:** 1.1.0

---

## TL;DR — Summary of Evidence

| Claim | Number | Where to verify |
|---|---|---|
| Solidity templates that compile cleanly | **10** (incl. dependencies → 32 contracts compiled with AMM + Vault) | `templates/*.sol` |
| Mock-mode runtime tests passing (skill internal) | **77 / 77** | Reproducible: see "Reproducibility" below |
| Independent stress-test agents that built dApps from skill alone | **9** (3 Round 1 + 3 Round 2 + 3 Round 5) | `stress-reports/{agent,round2-agent,round5-agent}[1-3]-*.md` |
| Tests those agents generated, all passing | **126 / 126** (24 R1 + 40 R2 + 62 R5) | Same |
| Average skill score across three stress-test rounds (no internet, no Zama doc lookups) | **9.0 / 10** R1, **9.0 / 10** R2, **9.0 / 10** R5 (peak per round 9.5) | Same |
| Reference guides | **12** | `references/*.md` |
| Templates (Solidity + TS + frontend) | **21** (incl. AMM, CDP vault and their test suites) | `templates/` |
| Self-Correction table entries (catch AI hallucinations) | **22** | `SKILL.md:149–172` |
| Lint rules in `validate-fhevm.sh` | **12** | `scripts/validate-fhevm.sh` |
| Documented anti-patterns | **18** (incl. Top-K ranking pattern; #17 inverted to flag operator-overload misuse) | `references/common-pitfalls.md` |
| Audit + stress rounds completed | **5** (R1 stress, R2 stress, R3 source-audit, R4 source-audit, R5 stress with R3-4 regression check) | `audit-reports/` + `stress-reports/` |
| Battle scars (real production lessons) | **5 in SKILL, 7 in common-pitfalls** | `SKILL.md:605–615` + `references/common-pitfalls.md` § Battle Scars |

---

## Required Topics (12 / 12)

### 1. Overview of FHEVM architecture and how FHE works on-chain

- **`SKILL.md:53–87`** — Architecture diagram + 4-component breakdown (Host Chain / Coprocessor / ACL Contract / KMS / Gateway)
- **`SKILL.md:88–93`** — Key implications (no plaintext in contract logic, async decryption, threshold-secret keys)

### 2. Setting up the development environment using the Hardhat template

- **`SKILL.md:201–243`** — § Quick Start: clone-or-scratch, exact dep matrix with version pins, smoke-test, ERC-7984 operator setup
- **`templates/hardhat.config.ts`** — Production-ready config: Hardhat 2 + cancun + viaIR, with `hardhat-deploy` import deliberately commented out (broken on ethers 6 — see Self-Correction Table)

### 3. Encrypted types (`euint8`, `euint16`, `euint32`, `euint64`, `ebool`, `eaddress`)

- **`references/type-system.md:3–35`** — All 8 types (incl. `euint128`, `euint256`) with bit widths and use cases
- **`references/type-system.md:158–199`** — Storing in mappings / state / structs, initialization checks
- Verified line-by-line vs `@fhevm/solidity@0.11.1::lib/FHE.sol` source

### 4. FHE operations (arithmetic, comparison, conditional logic)

- **`references/type-system.md:37–115`** — Arithmetic (add/sub/mul/div/rem/neg/min/max), comparison (eq/ne/gt/lt/ge/le → `ebool`), bitwise (and/or/xor/not/shl/shr/rotl/rotr), ternary `FHE.select`
- **`SKILL.md:418–426` Pattern 3** — Conditional logic with `select`, never `if`
- Tests: `confidential-swap.sol` exercises mul/div/sub/select; `multi-option-voting.sol` exercises eq+select chain across N buckets

### 5. Access control (`FHE.allow`, `FHE.allowTransient`)

- **`references/acl-patterns.md:7–88`** — `allow` (persistent), `allowThis` (self-access), `allowTransient` (same-tx via EIP-1153), `makePubliclyDecryptable`, `isAllowed` / `isSenderAllowed` checks
- **`references/acl-patterns.md:106–214`** — Cross-contract ACL pattern, contract-pays-user pattern, DAO/Governance balance reading
- **`SKILL.md:389–397` Pattern 1** — The ACL Triple (mandatory ACL grant after every stored FHE result)
- **`SKILL.md:448–465` Pattern 5** — Cross-contract 5-step ACL choreography
- All 3 stress-test agents called this their #1 savior win

### 6. Input proofs — what they are, why they're needed, how to use them

- **`references/input-proofs.md:1–10`** — What (ZK proof of well-formed ciphertext), why (prevents garbage encrypted inputs)
- **`references/input-proofs.md:11–98`** — Contract-side: `externalEuintXX` parameter + `FHE.fromExternal()`, multi-input single-proof, ACL on `fromExternal` results, when to use `externalEuintXX` vs `euintXX`
- **`references/input-proofs.md:151–298`** — Client-side: `createEncryptedInput().add8/64/...().encrypt()`, handle ordering, msg.sender binding, non-determinism
- Tested in `templates/multi-option-voting.sol::castVote` (single proof for both `encChoiceId` and `encWeight`)

### 7. User decryption (EIP-712 signing flow)

- **`references/decryption-guide.md:22–117`** — Full flow: `generateKeypair` → `createEIP712` → `signTypedData` → `userDecrypt`. Plus Hardhat-mock helpers (`fhevm.userDecryptEuint/Ebool/Eaddress`).

### 8. Public decryption patterns

- **`references/decryption-guide.md:118–262`** — 3-step on-chain reveal: `makePubliclyDecryptable` → off-chain `publicDecrypt` → on-chain `checkSignatures` + `abi.decode`
- **`references/decryption-guide.md:179–245`** — Single-handle variant + dynamic-N decode (Option A: fixed-max, Option B: calldataload loop)
- **`SKILL.md` Pattern 7 / `references/testing-guide.md` Pattern 7** — Test pattern with `fhevm.publicDecrypt` return-shape ⚠
- E2E tested: `EncryptedVoting` (yes=3, no=1) and `BlindAuction` (winner+amount) via real KMS proof

### 9. Frontend integration (formerly `fhevmjs` — now `@zama-fhe/relayer-sdk` / `@zama-fhe/sdk`)

- **`SKILL.md:94–123`** — § "Three SDK Generations" decision matrix (`fhevmjs` Gen-1 deprecated → `@zama-fhe/relayer-sdk` Gen-2 → `@zama-fhe/sdk` Gen-3)
- **`SKILL.md:124–143`** — § "Migrating from `fhevmjs`" 6-row API mapping table + 6-step migration checklist
- **`references/frontend-integration.md`** — Gen-2 deep dive: 720+ lines covering init, ABI encoding, encryption, EIP-712 user decryption, public decryption, React patterns, Next.js/Vite WASM config, contract addresses for Sepolia/Mainnet
- **`references/sdk-v3-guide.md`** — Gen-3 `ZamaSDK` / `Token` / `RelayerWeb` (current default since April 2026)
- **`references/react-sdk-guide.md`** — Gen-3 `ZamaProvider` + hooks (`useConfidentialBalance`, `useConfidentialTransfer`, `useShield`, `useUnshield`)
- All TypeScript examples type-check against the actually installed `@zama-fhe/relayer-sdk@0.4.1` and `@zama-fhe/sdk@3.0.0`

### 10. Testing FHEVM contracts

- **`references/testing-guide.md`** — 700+ lines: mock mode, Sepolia, decrypt helpers, 7 test patterns including `publicDecrypt + checkSignatures` E2E and constructor-revert assertions
- **`templates/test-template.ts`** — ERC-7984 boilerplate matched to `templates/confidential-erc20.sol`
- **`templates/test-erc7984-template.ts`** — Generic ERC-7984 fixture-pattern boilerplate
- **`templates/test-multi-option-voting.ts`** — Full E2E: multi-input proof, dynamic-N publicDecrypt, winningChoice tie-break, out-of-range silent fall-through

### 11. Common anti-patterns and mistakes

Bounty calls out specifically:

| Anti-pattern from bounty | Where covered |
|---|---|
| **View functions with encrypted values** | `references/common-pitfalls.md` Pitfall 5f — explains why ALL `FHE.*` ops are state-changing, and lists the **8** state-free helpers: `isInitialized` (pure) plus `isAllowed`, `isSenderAllowed`, `isPubliclyDecryptable`, `isAccountDenied`, `isUserDecryptable`, `isDelegatedForUserDecryption`, `getDelegatedUserDecryptionExpirationDate` (view) |
| **Missing `FHE.allowThis`** | `references/common-pitfalls.md:5–21` Pitfall 1 (Critical) + `SKILL.md:496–509` Critical Anti-Pattern #2 + `scripts/validate-fhevm.sh` Check 2 |

Plus the wider catalog:

- **`references/common-pitfalls.md`** — 17 ranked pitfalls (Critical → Medium) with detection heuristics
- **`SKILL.md:145–199`** — Self-Correction Table (22 rows) for AI hallucination prevention
- **`SKILL.md:559–571`** — "Do NOT Generate" table (catches `FHE.decrypt`, `FHE.safeAdd`, `FHE.allowForDecryption`, `FHE.sealoutput`, `ebytes64`, `eint8`, etc.)
- **`scripts/validate-fhevm.sh`** — 12 lint rules; runs against any `contracts/` dir

### 12. OpenZeppelin Confidential Contracts and ERC-7984

Bounty specifically calls out:

| Bounty sub-topic | Where covered |
|---|---|
| **Confidential token standard (ERC-7984)** | `references/erc7984-guide.md:1–148` — IERC7984 interface, all 6 transfer overloads, deployment recipe, revert vs silent-0 behavior table |
| **Encrypted balances** | `references/erc7984-guide.md:50–89` — `confidentialBalanceOf`, ACL-gated reads |
| **Private transfers** | `references/erc7984-guide.md:50–89` — `confidentialTransfer`, `confidentialTransferFrom`, `confidentialTransferAndCall` (each with 2 overloads) |
| **Wrapping between ERC-7984 and ERC-20** | `references/erc7984-guide.md:220–292` — `ERC7984ERC20Wrapper`: full `wrap` / `unwrap` / `finalizeUnwrap` recipe, 2-step async unwrap with KMS proof |
| **Operator model** | `references/erc7984-guide.md:151–168` — Time-based `setOperator`, NOT amount-based approve |
| **All extensions** | `references/erc7984-guide.md:332–400` — `ERC7984Votes`, `ERC7984Freezable`, `ERC7984Restricted`, `ERC7984ObserverAccess`, `ERC7984Omnibus`, `ERC7984Rwa` |
| **FHESafeMath utility** | `references/erc7984-guide.md:413–426` — `tryAdd`, `trySub`, `tryIncrease`, `tryDecrease` |

Verified vs `@openzeppelin/confidential-contracts@0.4.0` source (all 7 extensions exist in `node_modules/@openzeppelin/confidential-contracts/token/ERC7984/extensions/`).

---

## Submission Requirements

| Required | Status |
|---|---|
| One or more SKILL.md files | ✅ `SKILL.md` (640+ lines) |
| Frontmatter following AI-skill conventions | ✅ `name`, `description`, `license`, `version`, `compatibility` (claude-code, cursor, windsurf, copilot, codex, gemini-cli), `allowed-tools` |
| Supporting resource files / examples / templates | ✅ 12 reference docs (`references/*.md`) + 14 templates (`templates/*.sol`, `*.ts`, `*.tsx`) + 1 lint script (`scripts/validate-fhevm.sh`) |
| Demonstration video (≤3 min, real person) | Recorded separately — not in this repo |

---

## Judging Criteria — Evidence Index

### Accuracy

- **`references/*.md` correctness:** Every Solidity API call referenced in our docs is verified against the actual `@fhevm/solidity@0.11.1::lib/FHE.sol` source. Every Sepolia/Mainnet contract address is verified verbatim against `@zama-fhe/relayer-sdk@0.4.1::lib/internal.js`'s `SepoliaConfigBase` / `MainnetConfigBase`.
- **`SKILL.md` Self-Correction Table:** 22 rows covering known AI hallucinations (`Gateway.requestDecryption`, `FHE.decrypt`, `FHE.allowForDecryption`, `FHE.sealoutput`, `ebytes64`, `eint8`, `randEuint8Bounded(n)`, etc.).
- **Test evidence:** 19 / 19 mock-mode tests passing (see "Reproducibility" below).
- **Onchain evidence:** all 9 deployable templates exercised end-to-end on **live Sepolia FHEVM** with real KMS roundtrips (`docs/onchain-evidence.md`). Per-template tx hashes, addresses, Etherscan links, and KMS latencies in `docs/onchain-results/eN-*.json`. This is the strongest accuracy signal available: the recipes work against the actual relayer + ACL contract + KMS, not just compile-clean.

### Completeness — full lifecycle in one skill

| Stage | Where |
|---|---|
| Contracts | `templates/*.sol` (7 contracts) + `references/{type-system,acl-patterns,input-proofs,erc7984-guide}.md` |
| Testing | `references/testing-guide.md` + `templates/test-*.ts` |
| Deployment | `SKILL.md` § Sepolia Deployment + `templates/deploy-template.ts` + `templates/hardhat.config.ts` |
| Frontend | `references/{frontend-integration,sdk-v3-guide,react-sdk-guide}.md` + `templates/react-dashboard{,-v3}.tsx` |

### Agent effectiveness — independent stress test

3 fresh agents were given 3 distinct dApp specifications and **only the contents of this repo** as context. **No internet access. No Zama doc lookups.** All 3 succeeded:

| Agent | Task (distinct from any template) | Tests | Score |
|---|---|---|---|
| 1 | Confidential Tip Jar (encrypted donate + reveal + withdraw) | 6 / 6 | 9 / 10 |
| 2 | Pay-bound Sealed-Bid Auction (real ERC-7984 deposit + refunds + winner withdraw) | 8 / 8 | 9 / 10 |
| 3 | Multi-Option Token-Weighted DAO Vote (3-5 choices, FHE.eq+select chain) | 10 / 10 | 9 / 10 |
| **Total** | | **24 / 24** | **avg 9.0 / 10** |

Each agent reported the skill's "savior wins" — the same 5 win across all 3 reports:
1. ACL Triple / 5-step cross-contract pattern
2. Self-Correction Table `abi.decode(uint256)` cast-down
3. Pattern 7 `publicDecrypt + checkSignatures` recipe
4. Constructor-init handle warning (mock-mode `KMSInvalidSigner` trap)
5. Three SDK Generations decision matrix

### Code quality

- All 10 Solidity templates compile under Hardhat 2 + `evmVersion: cancun` + `viaIR: true` — `32 Solidity files compiled, 0 errors` (10 templates + dependencies).
- `validate-fhevm.sh` reports **0 errors, 0 warnings** on `templates/` after the Round-5 Check 2 + Check 11 fixes.
- Internal compile-test runs **77/77** mock-mode tests passing (39 baseline + 16 AMM + 22 CDP vault).
- 39 / 39 mock-mode runtime tests pass (incl. 2 E2E `publicDecrypt + checkSignatures` reveals + 20-test Vickrey suite covering top-2 ranking, refunds, settlement).
- **9 / 9 deployable templates pass live Sepolia E2E** ([`docs/onchain-evidence.md`](onchain-evidence.md)). Real input proofs, real ACL contract, real KMS, real public + user decryption roundtrips (3.4 – 8.5 s).
- All TypeScript templates type-check (`tsc --noEmit`) against the actually installed SDK packages.
- `scripts/validate-fhevm.sh` reports **0 errors** on `templates/`.

### Structure

```
fhevm-skill/
├── SKILL.md                       # 640+ lines — entry point, decision trees, patterns, self-correction
├── README.md                      # 180+ lines — bounty compliance map, quick install
├── LICENSE                        # MIT
├── .gitignore
├── docs/
│   └── bounty-compliance.md       # ← you are here
├── references/                    # 12 deep-dive guides
│   ├── type-system.md
│   ├── acl-patterns.md
│   ├── input-proofs.md
│   ├── decryption-guide.md
│   ├── testing-guide.md
│   ├── frontend-integration.md    # Gen-2 (relayer-sdk)
│   ├── sdk-v3-guide.md            # Gen-3 (sdk@3.x)
│   ├── react-sdk-guide.md         # Gen-3 (react-sdk@3.x)
│   ├── erc7984-guide.md
│   ├── common-pitfalls.md
│   ├── gas-optimization.md
│   └── security-checklist.md
├── templates/                       # 17 paste-ready files
│   ├── confidential-erc20.sol
│   ├── encrypted-voting.sol
│   ├── multi-option-voting.sol       # ★ added after Round 1 stress test
│   ├── blind-auction.sol             # ★ updated: encrypted leader via eaddress
│   ├── vickrey-auction.sol           # ★ added after Round 2 stress test
│   ├── confidential-escrow.sol
│   ├── confidential-swap.sol
│   ├── mock-erc20.sol
│   ├── hardhat.config.ts
│   ├── deploy-template.ts
│   ├── test-template.ts
│   ├── test-erc7984-template.ts
│   ├── test-multi-option-voting.ts   # ★ added after Round 1 stress test
│   ├── test-vickrey-auction.ts       # ★ added after Round 2 stress test
│   ├── react-dashboard.tsx           # Gen-2 dashboard
│   ├── react-dashboard-v3.tsx        # Gen-3 dashboard
│   └── .gitignore                    # ★ added after Round 2 stress test
└── scripts/
    └── validate-fhevm.sh           # 12-rule FHEVM linter
```

### Error prevention

| Layer | Mechanism |
|---|---|
| Naming-time | `SKILL.md` Self-Correction Table catches AI from typing `Gateway.requestDecryption`, `FHE.decrypt`, `ebytes64`, `eint8`, `randEuint8Bounded`, `import "fhevm/lib/TFHE.sol"`, etc. |
| Compile-time | `templates/hardhat.config.ts` enforces `evmVersion: cancun` + `viaIR: true`; `scripts/validate-fhevm.sh` runs 12 lint rules before deploy |
| Test-time | `references/testing-guide.md` Pattern 7 ⚠ note prevents the `result[handle]` vs `result.clearValues[handle]` mistake (cost agent 3 a debug cycle until it was added) |
| Deploy-time | `SKILL.md` § Quick Start lists 5 critical version pins (`@zama-fhe/relayer-sdk@0.4.1` exact, no caret; `@typechain/ethers-v6` paired with `@typechain/hardhat`; `hardhat-deploy` deliberately omitted) |
| Production | `references/security-checklist.md` 7-section pre-deploy checklist (ACL, info-leak, input handling, arithmetic, transfer, decryption, configuration, cross-contract, protocol-level, frontend) |

---

## Reproducibility

Anyone (including a judge) can verify the test claims locally:

```bash
# 1. Set up a fresh Hardhat 2 project
mkdir test-skill && cd test-skill
npm init -y
npm install --save-dev --legacy-peer-deps \
  hardhat@2.28.4 \
  @fhevm/solidity@0.11.1 @fhevm/hardhat-plugin@0.4.2 @fhevm/mock-utils@0.4.2 \
  @zama-fhe/relayer-sdk@0.4.1 \
  @nomicfoundation/hardhat-ethers@3.1.3 @nomicfoundation/hardhat-chai-matchers@2.1.2 \
  @typechain/hardhat @typechain/ethers-v6@0.5.1 \
  ethers@6.16.0 chai@4.5.0 ts-node@10.9.2 typescript@5.9.3 \
  @types/node@20.16.10 @types/mocha@10.0.10 @types/chai@4.3.20 \
  @openzeppelin/contracts@5.6.1 @openzeppelin/confidential-contracts@0.4.0

# 2. Drop in the templates
mkdir contracts test
cp /path/to/fhevm-skill/templates/*.sol contracts/

# 3. Use the minimal hardhat.config.ts (the shipped templates/hardhat.config.ts
#    works too once you `npm install @nomicfoundation/hardhat-verify`):
cat > hardhat.config.ts <<'EOF'
import { HardhatUserConfig } from "hardhat/config";
import "@fhevm/hardhat-plugin";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.27",
    settings: { optimizer: { enabled: true, runs: 800 }, viaIR: true, evmVersion: "cancun" },
  },
  networks: { hardhat: { chainId: 31337, allowBlocksWithSameTimestamp: true } },
};
export default config;
EOF

# 4. Compile + test
npx hardhat compile          # 32 contracts, 0 errors
npx hardhat test             # 77 / 77 passing
```

---

## License

MIT. See `LICENSE`.
