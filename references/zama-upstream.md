# Upstream Sources & Attribution

> **TL;DR** — every contract pattern, SDK call, and ACL recipe in this skill is derivative work on top of Zama's open-source FHEVM stack. This file documents what we pin to, where to look upstream when you need to go deeper, and how to upgrade if Zama ships a breaking version.

---

## Pinned versions (what this skill is tested against)

| Package | Pinned version | Verified by |
|---|---|---|
| `@fhevm/solidity` | **0.11.1** EXACT | 39 mock-mode tests + 9/9 Sepolia E2E (`docs/onchain-evidence.md`) |
| `@fhevm/hardhat-plugin` | **0.4.2** EXACT | mock test runner |
| `@openzeppelin/confidential-contracts` | **0.4.0** EXACT | ERC-7984 wrapper, voting, freezable, restricted extensions |
| `@openzeppelin/contracts` | **^5.x** | Ownable2Step, ReentrancyGuard |
| `@zama-fhe/relayer-sdk` | **0.4.1** EXACT (pinned by `@fhevm/hardhat-plugin@0.4.2`) | Node + browser input proofs, public-decrypt, user-decrypt |
| `@zama-fhe/sdk` | **3.0.0** | browser Token API (Gen-3) |
| `@zama-fhe/react-sdk` | **3.0.0** | React hooks layer (Gen-3) |

> **Why exact pins?** FHEVM is a fast-moving target. The handle ABI, ACL contract address, and KMS proof format have all shipped breaking changes between minor versions. Anything not pinned will eventually break the templates' on-chain behavior. `npm install --save-exact <pkg>@<version>` is the recipe — never `^` or `~` for these packages.

---

## Upstream repositories

| Component | Repo | What it is |
|---|---|---|
| `FHE.sol` library | [zama-ai/fhevm-solidity](https://github.com/zama-ai/fhevm-solidity) | The Solidity bindings. `FHE.add`, `FHE.allowThis`, `FHE.fromExternal`, etc. all live here. |
| Hardhat plugin | [zama-ai/fhevm-hardhat-plugin](https://github.com/zama-ai/fhevm-hardhat-plugin) | Mock-mode coprocessor + `fhevm.userDecrypt` / `awaitDecryptionOracle` hardhat helpers used by every template's tests. |
| Relayer SDK | [zama-ai/relayer-sdk](https://github.com/zama-ai/relayer-sdk) | Off-chain input-proof generation, public-decrypt, user-decrypt EIP-712 flow. Both Node and browser entry points. |
| Confidential Contracts | [OpenZeppelin/openzeppelin-confidential-contracts](https://github.com/OpenZeppelin/openzeppelin-confidential-contracts) | ERC-7984 base + 7 extensions (Votes, Freezable, Restricted, ObserverAccess, Omnibus, Rwa, ERC20Wrapper). |
| Browser SDK (Gen-3) | [zama-ai/sdk](https://github.com/zama-ai/sdk) | Token API — different from relayer-sdk; targets dApp frontends. |
| React hooks (Gen-3) | [zama-ai/react-sdk](https://github.com/zama-ai/react-sdk) | `useFhevm`, `usePublicDecrypt`, `useUserDecrypt` query hooks. |
| Official examples | [zama-ai/fhevm-hardhat-template](https://github.com/zama-ai/fhevm-hardhat-template) | Zama's starter — useful for sanity-checking config drift. |
| Protocol docs | [docs.zama.ai/protocol](https://docs.zama.ai/protocol) | Architecture, KMS, gateway, ACL deep-dives. |

---

## Where this skill differs from upstream

The templates in `templates/` are NOT verbatim copies of Zama or OpenZeppelin examples. Each one has been hardened with:

- **Mock-mode tests** (39 across the template set; many upstream examples have none)
- **On-chain Sepolia E2E proof** (9/9 verified end-to-end with real KMS — see `docs/onchain-evidence.md`)
- **NatSpec cross-references** to specific pitfalls in `references/common-pitfalls.md`
- **ACL invariants documented inline** (which party can decrypt what, and why)
- **Battle-scar comments** (e.g. constructor-init handle pattern, modular FHE.sub underflow note, top-K rebalancing note)
- **Pinned-version compatibility** — `@fhevm/solidity@0.11.1` and `@openzeppelin/confidential-contracts@0.4.0` (upstream main branch may use newer APIs)
- **Self-Correction Table integration** (`SKILL.md`) — the table catches AI hallucinations against the pinned API surface

> If you spot drift between this skill and an upstream pattern, file an issue. We pin deliberately; we don't auto-track upstream HEAD.

### Import path pin (verified at v0.4.0)

The `@openzeppelin/confidential-contracts@0.4.0` import paths used in this skill's templates:

```solidity
import {ERC7984}  from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
```

OpenZeppelin sometimes restructures package layouts at major version bumps. If `@openzeppelin/confidential-contracts >= 0.5` reorganises (e.g. flattens or re-namespaces these paths), update every template's import statement and rerun the mock + Sepolia test suites before publishing the skill update. Treat such a bump the same way as a Solidity-side breaking change in the upgrade procedure above.

---

## When to consult upstream directly (and when not to)

**Consult this skill first** for:
- Anything in `templates/*.sol` — they're tested
- Common DeFi primitives (token, voting, auction, escrow, swap, AMM, vault)
- Mock-mode testing recipes
- Frontend integration (Gen-2 vs Gen-3 decision tree is in `references/sdk-v3-guide.md`)
- Pitfalls + lint rules

**Consult upstream directly** when:
- You need an extension this skill doesn't template (e.g. `ERC7984Omnibus`, `ERC7984Rwa`, custom `FHESafeMath` callers)
- You're integrating a brand-new SDK feature released after the pinned version
- You're debugging a KMS / gateway issue at the protocol layer
- You want to verify a memory layout or ABI claim against the source

**Never paste upstream `main` branch code into this skill's template structure without re-pinning.** Version drift between `@fhevm/solidity` minors has historically broken handle ABI compatibility.

---

## Upgrade procedure (if Zama ships a breaking version)

1. Check the relayer-sdk and `@fhevm/solidity` changelogs for ABI / handle / ACL contract changes
2. Update the pinned versions in `package.json` examples throughout the skill (search: `0.11.1`, `0.4.2`, `0.4.0`, `0.4.1`, `3.0.0`)
3. Re-run `validate-fhevm.sh` against `templates/`
4. Re-run mock-mode test suite
5. Re-run the Sepolia E2E from `docs/onchain-evidence.md` recipe
6. Update `references/decryption-guide.md` if the abi-encoded cleartext format changed
7. Update Self-Correction Table in `SKILL.md` if any API was renamed/removed

This skill is opinionated about pinning. The trade-off: occasional manual upgrade work in exchange for templates that are guaranteed to work as documented.
