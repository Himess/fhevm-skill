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

## Pre-deployed Sepolia confidential tokens (use these for testing)

Zama ships a registry of canonical confidential ERC-7984 wrappers on Sepolia. **Use these instead of deploying your own MockUSDC** when you want a realistic integration test — they're recognised by the explorer, the wrappers registry, and any third-party tooling that integrates with the Zama ecosystem. Source: [docs.zama.org/protocol/protocol-apps/addresses/testnet/sepolia](https://docs.zama.org/protocol/protocol-apps/addresses/testnet/sepolia).

| Token | Symbol | Sepolia address | Underlying decimals |
|---|---|---|---|
| Confidential USDC | `cUSDCMock` | `0x7c5BF43B851c1dff1a4feE8dB225b87f2C223639` | 6 |
| Confidential USDT | `cUSDTMock` | `0x4E7B06D78965594eB5EF5414c357ca21E1554491` | 6 |
| Confidential WETH | `cWETHMock` | `0x46208622DA27d91db4f0393733C8BA082ed83158` | 18 |
| Confidential BRON | `cBRONMock` | `0xaa5612FA27c927a0c7961f5AEFEE5ba3A0F9C891` | 18 |
| Confidential ZAMA | `cZAMAMock` | `0xf2D628d2598aF4eAF94CB76a437Ff86CA78FfbFB` | 18 |
| Confidential tGBP | `ctGBPMock` | `0xfCE5c7069c5525eF6c8C2b2E35A745bA20a2F7CC` | 6 |
| Confidential XAUt | `cXAUtMock` | `0xe4FcF848739845BC81Dee1d5352cf3844F0a60C7` | 6 |
| Wrappers Registry | — | `0x2f0750Bbb0A246059d80e94c454586a7F27a128e` | — |

> **Why use these instead of `templates/mock-erc20.sol` + your own wrapper?**
> - Already deployed — no extra tx, no extra deploy fee
> - Match the wrap-rate logic the official wrapper enforces (`_rate = 10**(underlyingDec - 6)`); see `references/erc7984-guide.md` for the rate-scaling pitfall
> - Recognised by `docs.zama.org`, etherscan integrations, and the Wrappers Registry — easier for anyone reviewing your dApp on-chain
>
> **Use `templates/mock-erc20.sol` only when:** you need a custom decimal layout, you're testing a wrap/unwrap edge case the official mocks don't expose (e.g. underlying decimals < 6), or you're running locally on Hardhat / forge-fhevm where these addresses don't exist.

### Funding a test wallet with cUSDC / cWETH (the cTokens are NOT directly mintable)

> **Caveat surfaced by stress-test agent (Round 4):** the wrappers above are `Ownable`. `cUSDCMock.mint(yourAddress, ...)` reverts with `OwnableUnauthorizedAccount` because only the Zama deployer holds the owner role. The path that actually works is the standard wrap flow:

```solidity
// 1. Read the underlying ERC-20 the wrapper points at
IERC20 underlying = IERC20(IERC7984Wrapper(cUSDCMock).underlying());

// 2. Mint underlying mock tokens (these are open mocks; permissionless mint)
underlying.mint(myAddress, 1_000_000e6); // 1M USDC, 6 decimals

// 3. Approve the wrapper to pull
underlying.approve(cUSDCMock, type(uint256).max);

// 4. Wrap → confidential balance lands on `cUSDCMock`
IERC7984Wrapper(cUSDCMock).wrap(myAddress, 1_000_000e6);
```

Underlying mock addresses (open `mint()`) come from the Zama wrappers registry at `0x2f0750Bbb0A246059d80e94c454586a7F27a128e`; query `wrapperOf(underlying)` or `underlyingOf(wrapper)` to bridge between the two. From a test script:

```ts
// Node SDK / ethers v6
const wrapper = new ethers.Contract(cUSDCMock, ["function underlying() view returns (address)"], wallet);
const underlyingAddr = await wrapper.underlying();
const underlying = new ethers.Contract(underlyingAddr, ["function mint(address,uint256)", "function approve(address,uint256)"], wallet);
await (await underlying.mint(wallet.address, 1_000_000_000_000n)).wait(); // 1M @ 6 dec
await (await underlying.approve(cUSDCMock, ethers.MaxUint256)).wait();
const w = new ethers.Contract(cUSDCMock, ["function wrap(address,uint256)"], wallet);
await (await w.wrap(wallet.address, 1_000_000_000_000n)).wait();
```

After `wrap()` the cToken balance is encrypted; user-decrypt or `confidentialBalanceOf` (with ACL) to read it.

## Upgrade procedure (if Zama ships a breaking version)

1. Check the relayer-sdk and `@fhevm/solidity` changelogs for ABI / handle / ACL contract changes
2. Update the pinned versions in `package.json` examples throughout the skill (search: `0.11.1`, `0.4.2`, `0.4.0`, `0.4.1`, `3.0.0`)
3. Re-run `validate-fhevm.sh` against `templates/`
4. Re-run mock-mode test suite
5. Re-run the Sepolia E2E from `docs/onchain-evidence.md` recipe
6. Update `references/decryption-guide.md` if the abi-encoded cleartext format changed
7. Update Self-Correction Table in `SKILL.md` if any API was renamed/removed

This skill is opinionated about pinning. The trade-off: occasional manual upgrade work in exchange for templates that are guaranteed to work as documented.
