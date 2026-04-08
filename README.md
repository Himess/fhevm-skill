# FHEVM Skill for AI Coding Agents

Production-ready skill files that enable AI coding agents to build, test, and deploy confidential smart contracts using the Zama Protocol.

Drop these files into Claude Code, Cursor, Windsurf, or any AI coding tool — then prompt "Write me a confidential voting contract using FHEVM" and get correct, working code.

## Results

Tested with **19 different dApps** built from scratch by AI agents using only these skill files:

| Metric | Result |
|--------|--------|
| Total tests generated | **738** |
| Tests passing | **738 (100%)** |
| Different dApps built | 19 (voting, auction, escrow, payroll, DEX, lottery, DAO, vesting, wrap/unwrap) |
| Sepolia deployments | 10+ verified on-chain |
| Agent self-sufficiency | **8.9/10** average |
| Internet searches needed | **Zero** |
| Average skill rating | **9/10** |

## Quick Start

### Claude Code
```bash
cp -r fhevm-skill/ ~/.claude/skills/fhevm/
```

### Cursor
```bash
cp -r fhevm-skill/ .cursor/skills/fhevm/
```

### Windsurf / Copilot
```bash
cp -r fhevm-skill/ .windsurf/skills/fhevm/
# or: .github/skills/fhevm/
```

Then prompt your AI agent:
> "Write me a confidential voting contract using FHEVM"

## What's Included

### Core Skill (1 file)
| File | Lines | Description |
|------|-------|-------------|
| `SKILL.md` | 567 | Main skill — architecture, decision trees, core patterns, anti-patterns, self-correction table |

### Reference Guides (10 files)
| File | Lines | Description |
|------|-------|-------------|
| `references/type-system.md` | 244 | All encrypted types, operations, casting rules |
| `references/acl-patterns.md` | 337 | allow, allowThis, allowTransient, delegation, cross-contract ACL |
| `references/input-proofs.md` | 295 | Client-side encryption, contract-side validation, multi-input |
| `references/decryption-guide.md` | 312 | User (EIP-712), public, delegated decryption |
| `references/erc7984-guide.md` | 369 | ERC-7984 standard, operator model, wrap/unwrap, extensions |
| `references/testing-guide.md` | 641 | Mock mode, Sepolia, decrypt helpers, publicDecrypt, edge cases |
| `references/frontend-integration.md` | 647 | Relayer SDK, ABI encoding, React patterns, Next.js/Vite WASM |
| `references/common-pitfalls.md` | 438 | 15+ pitfalls with severity, code examples, battle scars |
| `references/gas-optimization.md` | 254 | HCU costs, type sizing, fee collection, batch strategies |
| `references/security-checklist.md` | 134 | Pre-deployment audit checklist, attack vectors |

### Templates (10 files)
| File | Description |
|------|-------------|
| `templates/confidential-erc20.sol` | ERC-7984 token (OpenZeppelin base) |
| `templates/encrypted-voting.sol` | Confidential voting with public reveal |
| `templates/blind-auction.sol` | Sealed-bid auction |
| `templates/confidential-escrow.sol` | Escrow with arbiter dispute |
| `templates/confidential-swap.sol` | Token swap with encrypted fees |
| `templates/hardhat.config.ts` | Production config (Hardhat 2, cancun, viaIR) |
| `templates/test-template.ts` | Test boilerplate for custom contracts |
| `templates/test-erc7984-template.ts` | Test boilerplate for ERC-7984 tokens |
| `templates/deploy-template.ts` | Hardhat-deploy script |
| `templates/react-dashboard.tsx` | React frontend (connect, encrypt, decrypt, transfer) |
| `templates/mock-erc20.sol` | Mock ERC-20 for wrap/unwrap testing |

### Validation (1 file)
| File | Description |
|------|-------------|
| `scripts/validate-fhevm.sh` | Catches 12 common FHEVM mistakes before deployment |

## Key Features

### Error Prevention (unique to this skill)

**Self-Correction Table** — Catches AI hallucinations before they happen:

| If the agent writes... | It should be... |
|---|---|
| `TFHE.asEuint64(input, proof)` | `FHE.fromExternal(externalEuint64, proof)` |
| `Gateway.requestDecryption()` | `FHE.makePubliclyDecryptable()` + `checkSignatures` |
| `FHE.decrypt(value)` in Solidity | Decryption is off-chain only |
| `npm install hardhat` (gets v3) | `npm install hardhat@^2.28.4` — FHEVM requires Hardhat 2 |

**"Do NOT Generate" Table** — Prevents non-existent APIs:

`FHE.safeAdd()`, `ebytes64`, `eint8`, `FHE.sealoutput()` — none of these exist.

**Battle Scars** — Real-world failure stories from production FHEVM development.

### Decision Trees

6 decision trees for instant routing:
- Which encrypted type? (ebool → euint256)
- How to decrypt? (user / public / delegated)
- Which ACL function? (allow / allowTransient / makePubliclyDecryptable)
- Which library? (FHE for new, TFHE only for legacy fhevm-contracts)
- Cross-contract interaction? (allowTransient vs allow vs 2-tx flow)
- Troubleshooting? (compilation errors, runtime reverts, silent failures)

### Full Lifecycle Coverage

Contracts → Testing → Deployment → Frontend — all from one skill:

1. **Contracts**: Encrypted types, FHE operations, ACL, input proofs, ERC-7984
2. **Testing**: Mock mode, Sepolia, publicDecrypt, HardhatFhevmError handling
3. **Deployment**: Hardhat-deploy, Sepolia config, Etherscan verification
4. **Frontend**: Relayer SDK, encryption, EIP-712 decryption, React hooks, Next.js/Vite WASM

## Validation Results

Every topic from the bounty requirements tested and verified:

| Bounty Topic | Covered | Verified With |
|---|---|---|
| FHEVM architecture | SKILL.md | All 19 agents understood correctly |
| Dev environment (Hardhat) | SKILL.md + template | 19/19 correct setup |
| Encrypted types | type-system.md | Used across all dApps |
| FHE operations | type-system.md | add, sub, mul, div, select, rand, eq, gt, min, max |
| Access control | acl-patterns.md | 19/19 correct ACL triple |
| Input proofs | input-proofs.md | fromExternal in all contracts |
| User decryption (EIP-712) | decryption-guide.md | 8+ frontends |
| Public decryption | decryption-guide.md | Voting, lottery, auction reveals |
| Frontend (Relayer SDK) | frontend-integration.md | 8+ React apps |
| Testing | testing-guide.md | 738 tests, 100% pass |
| Anti-patterns | common-pitfalls.md | 0 deprecated API usage |
| ERC-7984 + OpenZeppelin | erc7984-guide.md | ERC7984, ERC7984ERC20Wrapper |

## Compatibility

Works with:
- Claude Code
- Cursor
- Windsurf
- GitHub Copilot
- Codex
- Gemini CLI
- Any tool supporting the Agent Skills standard

## Technical Details

- **FHEVM version**: `@fhevm/solidity` ^0.11.1
- **OpenZeppelin**: `@openzeppelin/confidential-contracts` ^0.4.0
- **Hardhat**: ^2.28.4 (Hardhat 2, NOT 3)
- **Relayer SDK**: `@zama-fhe/relayer-sdk` ^0.4.1
- **ERC-7984**: Real standard with `confidentialTransfer`, `setOperator`, `confidentialBalanceOf`
- **Solidity**: ^0.8.27, `evmVersion: "cancun"`, `viaIR: true`

## License

MIT
