# Onchain Evidence — Sepolia FHEVM E2E

**Network:** Ethereum Sepolia (chainId 11155111) — Zama FHEVM Testnet
**Wallet:** `0xF505e2E71df58D7244189072008f25f6b6aaE5ae`
**SDK:** `@zama-fhe/relayer-sdk@0.4.1` (Node entry point) — real KMS, real input proofs, real ACL
**Date:** 2026-05-09

All 9 deployable templates were exercised end-to-end on live Sepolia — encrypt off-chain → submit input proof on-chain → execute FHE math → KMS roundtrip → public-decrypt or user-decrypt → verify result. Per-test JSON evidence sits in [`onchain-results/`](onchain-results/).

| # | Template | Contract | Status | Key tx | Etherscan |
|---|---|---|---|---|---|
| E1 | `vickrey-auction.sol` | VickreyAuction | PASS | revealResults `0x2d7b2910…` | [auction](https://sepolia.etherscan.io/address/0xEbcF2F2d60dde17854379F8f96e8C7fCE85820a4) |
| E2 | `confidential-amm.sol` | ConfidentialAMM | PASS | swap A→B `0xbe9b518f…` | [amm](https://sepolia.etherscan.io/address/0x500559A789B5CFe7478533DB021F41832Ed2a016) |
| E3 | `cdp-vault.sol` | ConfidentialCDPVault | PASS | confirmLiquidatable `0x4c74c1eb…` | [vault](https://sepolia.etherscan.io/address/0x5De5a1a9F2179EAF174f373825ca8d8E41b3E098) |
| E4 | `confidential-escrow.sol` | ConfidentialEscrow | PASS | release `0x7ebab6ac…` | [escrow](https://sepolia.etherscan.io/address/0x494fa276C041f88a1b62723dE9bCD00e3C6E0614) |
| E5 | `confidential-swap.sol` | ConfidentialSwap | PASS | swapAtoB `0x0c5c515c…` | [swap](https://sepolia.etherscan.io/address/0x888b3C5C0A75908a0699Ff354d503CC26E6928B5) |
| E6 | `blind-auction.sol` | BlindAuction | PASS | revealWinner `0x23e0a061…` | [blind-auction](https://sepolia.etherscan.io/address/0x1945153F4481285048dE81b7b4056920d24f1141) |
| E7 | `multi-option-voting.sol` | MultiOptionVoting | PASS | revealTallies `0xd8fce98a…` | [voting](https://sepolia.etherscan.io/address/0x686a2360FD1Ff1C7a8a758b3e960837Be5637461) |
| E8 | `encrypted-voting.sol` | EncryptedVoting | PASS | revealResults `0x927ac7ef…` | [voting](https://sepolia.etherscan.io/address/0x1719d9097aAbB9E37465Df93856565238360dC78) |
| E9 | `confidential-erc20.sol` | ConfidentialToken (ERC-7984) | PASS | transfer `0xed227342…` | [token](https://sepolia.etherscan.io/address/0xCf4C0B8000d3855FAE8ACcA2E0724575A3941C39) |

> The 10th template, `react-dashboard-v3.tsx`, is a frontend (browser SDK Token API integration) and is not deployable on-chain. It is exercised at SDK level by `templates/test-template.ts`.

---

## What was actually proved

For each template, the test exercised the **full lifecycle the dApp would use in production**, not just deploy-and-call:

### E1 — VickreyAuction (sealed-bid second-price)

- 2 ephemeral bidders funded from deployer; bidder1 bid encrypted 700, bidder2 bid encrypted 500
- Top-2 tracking via chained `FHE.gt` + `FHE.select` (no leakage about who's leading)
- After expiry: `endAuction` marks `_secondBid` + `_highestBidder` publicly decryptable
- KMS public-decrypt returns `(500, bidder1)` → `revealResults` verifies proof on-chain
- **Verified second-price clearing**: winner = bidder1, clearing price = bidder2's 500

### E2 — ConfidentialAMM (constant-product, encrypted reserves)

- Pool initialized at 1000 A / 2000 B / 1000 LP shares (plaintext supply)
- Off-chain trader computed `expectedOut = 180` for `amountIn = 100` (Uniswap-V2 fee math: 99·2000/(1000+99) = 180)
- On-chain `swap` validated the constant-product invariant in the encrypted domain via `FHE.ge(newK, oldK)` — passed
- Reserves stayed encrypted throughout; only the LP-share count is plaintext

### E3 — ConfidentialCDPVault (encrypted collateral + debt)

- Deposited 100 cWETH collateral, borrowed 50 (within 60% LTV cap of 60)
- **User-decrypt of `debtOf(user)` returned exactly 50** — proves debt is encrypted on-chain but borrower can decrypt their own
- `requestLiquidationCheck` published `_liqFlag[user]` publicly decryptable
- `publicDecrypt` returned 0 (healthy); `confirmLiquidatable` cached `false` on-chain
- Validates the canonical "publicly-readable, ACL-gated" pattern

### E4 — ConfidentialEscrow (ERC-7984 buyer/seller/arbiter)

- Buyer minted 1000, called `setOperator(escrow, +1d)`, then `createEscrow(amount=250)`
- `confidentialTransferFrom` pulled 250 into escrow with single proof
- **User-decrypt of `confidentialBalanceOf(buyer)` returned 750** after the escrow pull — proves OZ ERC7984 grants ACL on the new from-balance to the original `from` (not just to `msg.sender`), per `ERC7984.sol::_update` line 288. Critical for any escrow / vault / AMM that pulls via transferFrom — the original holder retains decryption rights on their post-transfer balance.
- `release(escrowId)` flipped state Active(0) → Released(1)
- Verified the operator-model 3-step recipe: setOperator → encrypted-input call → state transition

### E5 — ConfidentialSwap (fixed-rate two-token swap)

- Two tokens deployed; rate 2:1, fee 1% (feeDivisor=100)
- Owner added 500 B liquidity, then `swapAtoB(100)` ran with full fee accounting
- Encrypted reserves + encrypted fee accumulators all updated in one tx
- Validates constructor-init handles + lazy-init liquidity reserves

### E6 — BlindAuction (sealed-bid first-price)

- Ephemeral bidder placed encrypted bid 7777 (only bidder; deployer is owner, owner cannot bid)
- After 30s: `endAuction` published `_highestBid` and `_highestBidder` (eaddress!) publicly decryptable
- KMS-decoded `(7777, bidder.address)` correctly — eaddress decoded as `address(uint160(uint256))`
- **Validates the mixed-type 2-handle reveal pattern** (euint64 + eaddress in one proof)

### E7 — MultiOptionVoting (3-bucket DAO vote, token-weighted)

- gov token minted 100 cGOV to deployer
- `castVote(choice=B, weight=100)` — TWO encrypted inputs (`euint8 choiceId`, `euint64 weight`) sharing ONE input proof
- `confidentialTransferFrom` pulled 100 cGOV; eq-chain routed weight to bucket B
- `endVote` → `publicDecrypt([t0, t1, t2])` → `[0, 100, 0]` ✓
- `revealTallies` stored plaintext tallies; on-chain `state` transitioned to Revealed
- **Validates multi-input single-proof + N-bucket FHE.eq+FHE.select routing**

### E8 — EncryptedVoting (binary yes/no, token-weighted)

- 1 yes vote cast as `addBool(true)` + single proof
- `endVoting` published yes + no tallies as publicly decryptable
- KMS roundtrip 8.4s, returned `(yes=1, no=0)`
- `revealResults` verified KMS proof on-chain via `FHE.checkSignatures`
- Validates the **public decryption + on-chain proof verification** end-to-end

### E9 — ConfidentialToken (ERC-7984)

- Deployed via OZ ERC7984 base. Minted 1000, encrypted-transferred 100 to a random recipient
- **User-decrypt of `confidentialBalanceOf(deployer)` returned 1000 → 900 after transfer**
- `setOperator(recipient, +1d)` works → `isOperator` returns true
- KMS roundtrip ~6s for user-decrypt (EIP-712 + relayer)
- Validates the canonical ERC-7984 mint/transfer/balance/operator flow

---

## Real KMS roundtrips measured

| Operation | Time |
|---|---|
| publicDecrypt 1 handle (E3 liq flag) | 3.4s |
| publicDecrypt 2 handles (E1, E6) | ~8s |
| publicDecrypt 3 handles (E7 tallies) | 8.5s |
| publicDecrypt 2 handles (E8 voting) | 8.4s |
| userDecrypt 1 handle (E9 balance) | 5–6s |
| userDecrypt 1 handle (E3 debt) | 5.0s |

These are **real network latencies against `relayer.testnet.zama.org/v2/*`** — not simulated, not mocked.

---

## Reproducing locally

The test harness lives outside this repo (it's bigger than a skill should ship) but the recipe is portable:

```bash
mkdir onchain-test && cd $_
npm init -y
npm i hardhat @nomicfoundation/hardhat-toolbox @fhevm/solidity@0.11.1 \
  @openzeppelin/confidential-contracts@0.4.0 @zama-fhe/relayer-sdk@0.4.1 --save-exact
# Copy templates/*.sol into ./contracts/, write a hardhat.config.ts pointing at
# Sepolia + DEPLOYER_PRIVATE_KEY, then write per-template e2e scripts that:
#   1. deploy → 2. encrypt input via createEncryptedInput → 3. send tx
#   4. for revealable contracts: queryFilter → publicDecrypt → on-chain checkSignatures
npx hardhat run scripts/eN-...ts --network sepolia
```

Each `onchain-results/eN-*.json` file contains every tx hash for independent verification on Etherscan.

---

## What this evidence does NOT cover

- **Mainnet Ethereum** — Zama FHEVM is currently testnet-only (Sepolia). When mainnet launches, the same code paths apply.
- **Gas-optimization stress** — reported gas (e.g. AMM swap @ 1.5M, AMM init @ 1.1M, MultiOptionVoting @ 870k) reflects "normal" tx size, not a contention or worst-case fuzz harness.
- **Adversarial inputs against KMS** — the proof verification is what `FHE.checkSignatures` does; we use it as a black box. Audit of the KMS itself is Zama's domain.
- **HCU envelope** — every tx fit inside the per-tx 20M / sequential-depth 5M HCU budget in practice. Templates that grow per-iteration (e.g. MultiOptionVoting's eq-chain) document the bound.

The skill's recipes are now demonstrably correct against the live FHEVM stack — not just typecheck-clean and unit-tested.
