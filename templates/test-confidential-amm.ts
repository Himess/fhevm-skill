// Test suite for templates/confidential-amm.sol — single-pair constant-product
// AMM for ERC-7984 tokens.
//
// Run with:
//   npx hardhat test test/test-confidential-amm.ts
//
// Requires `ConfidentialToken` from templates/confidential-erc20.sol to be in
// the same contracts/ directory (used as both TokenA and TokenB).
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

// Helper: encrypt one or many uint64 inputs against a contract+sender pair.
async function encrypt64s(
  contractAddr: string,
  signer: HardhatEthersSigner,
  values: bigint[],
): Promise<{ handles: string[]; inputProof: string }> {
  let builder = fhevm.createEncryptedInput(contractAddr, signer.address);
  for (const v of values) {
    builder = builder.add64(v);
  }
  const enc = await builder.encrypt();
  return { handles: enc.handles.map((h: any) => h as string), inputProof: enc.inputProof as string };
}

const MAX_UINT48 = 2n ** 48n - 1n;

describe("ConfidentialAMM", function () {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let tokenA: any;
  let tokenB: any;
  let amm: any;
  let tokenAAddr: string;
  let tokenBAddr: string;
  let ammAddr: string;

  beforeEach(async function () {
    if (!fhevm.isMock) this.skip();
    [owner, alice, bob] = await ethers.getSigners();

    const TokenFactory = await ethers.getContractFactory("ConfidentialToken");
    tokenA = await TokenFactory.deploy(
      owner.address,
      "TokenA",
      "TKA",
      "https://example.com/a.json",
    );
    await tokenA.waitForDeployment();
    tokenAAddr = await tokenA.getAddress();

    tokenB = await TokenFactory.deploy(
      owner.address,
      "TokenB",
      "TKB",
      "https://example.com/b.json",
    );
    await tokenB.waitForDeployment();
    tokenBAddr = await tokenB.getAddress();

    const AMMFactory = await ethers.getContractFactory("ConfidentialAMM");
    amm = await AMMFactory.deploy(tokenAAddr, tokenBAddr, owner.address);
    await amm.waitForDeployment();
    ammAddr = await amm.getAddress();

    // Mint each user 1_000_000 of both tokens (plenty for test math).
    for (const u of [owner, alice, bob]) {
      await tokenA.mint(u.address, 1_000_000n);
      await tokenB.mint(u.address, 1_000_000n);
    }

    // Each user authorises AMM as operator on both tokens.
    for (const u of [owner, alice, bob]) {
      await tokenA.connect(u).setOperator(ammAddr, MAX_UINT48);
      await tokenB.connect(u).setOperator(ammAddr, MAX_UINT48);
    }
  });

  async function decryptBalance(token: any, user: HardhatEthersSigner): Promise<bigint> {
    const handle = await token.confidentialBalanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, await token.getAddress(), user);
  }

  async function decryptShares(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await amm.lpSharesOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, ammAddr, user);
  }

  async function decryptReserveOwner(): Promise<{ a: bigint; b: bigint }> {
    const [hA, hB] = await amm.getReserves();
    const a = await fhevm.userDecryptEuint(FhevmType.euint64, hA, ammAddr, owner);
    const b = await fhevm.userDecryptEuint(FhevmType.euint64, hB, ammAddr, owner);
    return { a, b };
  }

  // ──────────────────────────────────────────────────────────────────
  describe("Initialization", function () {
    it("constructor sets immutable token pair + owner", async function () {
      expect(await amm.tokenA()).to.equal(tokenAAddr);
      expect(await amm.tokenB()).to.equal(tokenBAddr);
      expect(await amm.owner()).to.equal(owner.address);
      expect(await amm.totalLPShares()).to.equal(0n);
    });

    it("initialize seeds reserves and mints LP shares to owner", async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, owner, [10_000n, 40_000n]);
      await amm.initialize(handles[0], handles[1], 1000n, inputProof);

      expect(await amm.totalLPShares()).to.equal(1000n);

      const shares = await decryptShares(owner);
      expect(shares).to.equal(1000n);

      const r = await decryptReserveOwner();
      expect(r.a).to.equal(10_000n);
      expect(r.b).to.equal(40_000n);
    });

    it("non-owner cannot initialize", async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [1n, 1n]);
      await expect(
        amm.connect(alice).initialize(handles[0], handles[1], 100n, inputProof),
      ).to.be.reverted;
    });

    it("cannot initialize twice", async function () {
      const { handles: h1, inputProof: p1 } = await encrypt64s(ammAddr, owner, [10n, 10n]);
      await amm.initialize(h1[0], h1[1], 100n, p1);
      const { handles: h2, inputProof: p2 } = await encrypt64s(ammAddr, owner, [1n, 1n]);
      await expect(amm.initialize(h2[0], h2[1], 100n, p2)).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────
  describe("Liquidity provision", function () {
    beforeEach(async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, owner, [10_000n, 40_000n]);
      await amm.initialize(handles[0], handles[1], 1000n, inputProof);
    });

    it("alice can add liquidity at the right ratio", async function () {
      // Add 5_000 A and 20_000 B → mint 500 shares (50% of pool).
      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [5_000n, 20_000n]);
      await amm.connect(alice).addLiquidity(handles[0], handles[1], 500n, inputProof);

      expect(await amm.totalLPShares()).to.equal(1500n);
      expect(await decryptShares(alice)).to.equal(500n);

      const r = await decryptReserveOwner();
      expect(r.a).to.equal(15_000n);
      expect(r.b).to.equal(60_000n);
    });

    it("alice can remove half her liquidity and get pro-rata back", async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [5_000n, 20_000n]);
      await amm.connect(alice).addLiquidity(handles[0], handles[1], 500n, inputProof);

      const aBefore = await decryptBalance(tokenA, alice);
      const bBefore = await decryptBalance(tokenB, alice);

      // Burn 250 shares (1/6 of total pool of 1500). Should withdraw ~2500A + ~10000B.
      await amm.connect(alice).removeLiquidity(250n);

      expect(await amm.totalLPShares()).to.equal(1250n);
      expect(await decryptShares(alice)).to.equal(250n);

      const aAfter = await decryptBalance(tokenA, alice);
      const bAfter = await decryptBalance(tokenB, alice);
      expect(aAfter - aBefore).to.equal(2500n);
      expect(bAfter - bBefore).to.equal(10_000n);
    });

    it("removeLiquidity with sharesToBurn > totalLPShares reverts", async function () {
      await expect(amm.connect(owner).removeLiquidity(99_999n)).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────
  describe("Swaps", function () {
    beforeEach(async function () {
      // 100_000 / 100_000 pool — 1:1 nominal, large enough for fee math.
      const { handles, inputProof } = await encrypt64s(ammAddr, owner, [100_000n, 100_000n]);
      await amm.initialize(handles[0], handles[1], 10_000n, inputProof);
    });

    it("A→B swap with correct expected amount transfers tokens", async function () {
      const amountIn = 1_000n;
      const amountInAfterFee = (amountIn * 997n) / 1000n; // 997
      const expectedOut =
        (100_000n * amountInAfterFee) / (100_000n + amountInAfterFee);

      const aBefore = await decryptBalance(tokenA, alice);
      const bBefore = await decryptBalance(tokenB, alice);

      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [amountIn, expectedOut]);
      await amm.connect(alice).swap(handles[0], handles[1], true, inputProof);

      const aAfter = await decryptBalance(tokenA, alice);
      const bAfter = await decryptBalance(tokenB, alice);

      expect(aBefore - aAfter).to.equal(amountIn);
      expect(bAfter - bBefore).to.equal(expectedOut);
    });

    it("A→B swap with too-large expected amount silently refunds", async function () {
      const amountIn = 1_000n;
      const inflated = 5_000n; // way above what the invariant allows

      const aBefore = await decryptBalance(tokenA, alice);
      const bBefore = await decryptBalance(tokenB, alice);

      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [amountIn, inflated]);
      await amm.connect(alice).swap(handles[0], handles[1], true, inputProof);

      const aAfter = await decryptBalance(tokenA, alice);
      const bAfter = await decryptBalance(tokenB, alice);
      // Cheating swap returns the trader's full input as a refund and gives
      // them 0 of the output token.
      expect(aBefore - aAfter).to.equal(0n);
      expect(bAfter - bBefore).to.equal(0n);
    });

    it("swap accumulates fee in the input token", async function () {
      const amountIn = 1_000n;
      const amountInAfterFee = (amountIn * 997n) / 1000n;
      const out = (100_000n * amountInAfterFee) / (100_000n + amountInAfterFee);

      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [amountIn, out]);
      await amm.connect(alice).swap(handles[0], handles[1], true, inputProof);

      const [feeA] = await amm.getFees();
      const decFeeA = await fhevm.userDecryptEuint(FhevmType.euint64, feeA, ammAddr, owner);
      expect(decFeeA).to.equal(amountIn - amountInAfterFee); // 3
    });

    it("B→A swap works symmetrically", async function () {
      const amountIn = 2_000n;
      const amountInAfterFee = (amountIn * 997n) / 1000n; // 1994
      const out = (100_000n * amountInAfterFee) / (100_000n + amountInAfterFee);

      const aBefore = await decryptBalance(tokenA, alice);

      const { handles, inputProof } = await encrypt64s(ammAddr, alice, [amountIn, out]);
      await amm.connect(alice).swap(handles[0], handles[1], false, inputProof);

      const aAfter = await decryptBalance(tokenA, alice);
      expect(aAfter - aBefore).to.equal(out);
    });
  });

  // ──────────────────────────────────────────────────────────────────
  describe("Fee withdrawal", function () {
    beforeEach(async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, owner, [100_000n, 100_000n]);
      await amm.initialize(handles[0], handles[1], 10_000n, inputProof);

      // Run one swap to accumulate fees.
      const amountIn = 1_000n;
      const amountInAfterFee = (amountIn * 997n) / 1000n;
      const out = (100_000n * amountInAfterFee) / (100_000n + amountInAfterFee);
      const { handles: h, inputProof: p } = await encrypt64s(ammAddr, alice, [amountIn, out]);
      await amm.connect(alice).swap(h[0], h[1], true, p);
    });

    it("owner can withdraw accumulated fees", async function () {
      const ownerABefore = await decryptBalance(tokenA, owner);
      await amm.connect(owner).withdrawFees(owner.address);
      const ownerAAfter = await decryptBalance(tokenA, owner);
      expect(ownerAAfter - ownerABefore).to.equal(3n);
    });

    it("non-owner cannot withdraw fees", async function () {
      await expect(amm.connect(alice).withdrawFees(alice.address)).to.be.reverted;
    });
  });

  // ──────────────────────────────────────────────────────────────────
  describe("Reserve disclosure (TVL UX)", function () {
    beforeEach(async function () {
      const { handles, inputProof } = await encrypt64s(ammAddr, owner, [50n, 200n]);
      await amm.initialize(handles[0], handles[1], 100n, inputProof);
    });

    it("non-LP cannot decrypt reserves before reveal", async function () {
      const [hA] = await amm.getReserves();
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, hA, ammAddr, alice),
      ).to.be.rejected;
    });

    it("after revealReserves anyone can publicly decrypt", async function () {
      await amm.connect(owner).revealReserves();
      const [hA, hB] = await amm.getReserves();
      const a = await fhevm.publicDecryptEuint(FhevmType.euint64, hA);
      const b = await fhevm.publicDecryptEuint(FhevmType.euint64, hB);
      expect(a).to.equal(50n);
      expect(b).to.equal(200n);
    });

    it("allowReservesTo grants ACL to a specific user", async function () {
      await amm.connect(owner).allowReservesTo(alice.address);
      const [hA] = await amm.getReserves();
      const a = await fhevm.userDecryptEuint(FhevmType.euint64, hA, ammAddr, alice);
      expect(a).to.equal(50n);
    });
  });
});
