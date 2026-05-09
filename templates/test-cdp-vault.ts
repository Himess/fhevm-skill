// Test suite for templates/cdp-vault.sol — collateral-debt position vault.
//
// Run with:
//   npx hardhat test test/test-cdp-vault.ts
//
// Requires `ConfidentialToken` from templates/confidential-erc20.sol to be in
// the same contracts/ directory (used as the cWETH-style collateral token).
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("ConfidentialCDPVault", function () {
  let token: any;
  let vault: any;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let liquidator: HardhatEthersSigner;
  let tokenAddr: string;
  let vaultAddr: string;

  const INITIAL_PRICE = 2n; // 1 cWETH = 2 debt units

  beforeEach(async function () {
    if (!fhevm.isMock) this.skip();

    [owner, alice, bob, liquidator] = await ethers.getSigners();

    const tokenFactory = await ethers.getContractFactory("ConfidentialToken");
    token = await tokenFactory.deploy(
      owner.address,
      "ConfidentialWETH",
      "cWETH",
      "https://example.com/cweth.json",
    );
    await token.waitForDeployment();
    tokenAddr = await token.getAddress();

    const vaultFactory = await ethers.getContractFactory("ConfidentialCDPVault");
    vault = await vaultFactory.deploy(owner.address, tokenAddr, INITIAL_PRICE);
    await vault.waitForDeployment();
    vaultAddr = await vault.getAddress();

    // Mint cWETH to alice & bob
    await token.connect(owner).mint(alice.address, 1000n);
    await token.connect(owner).mint(bob.address, 1000n);
  });

  // ─── Helpers ─────────────────────────────────────────────────────────

  async function setVaultAsOperator(user: HardhatEthersSigner) {
    const maxUint48 = 2n ** 48n - 1n;
    await token.connect(user).setOperator(vaultAddr, maxUint48);
  }

  async function encryptForVault(amount: bigint | number, signer: HardhatEthersSigner) {
    return await fhevm
      .createEncryptedInput(vaultAddr, signer.address)
      .add64(BigInt(amount))
      .encrypt();
  }

  async function decryptCollateral(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await vault.collateralOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, vaultAddr, user);
  }

  async function decryptDebt(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await vault.debtOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, vaultAddr, user);
  }

  async function decryptTokenBalance(
    holder: HardhatEthersSigner,
    decryptor: HardhatEthersSigner,
  ): Promise<bigint> {
    const h = await token.confidentialBalanceOf(holder.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, h, tokenAddr, decryptor);
  }

  async function deposit(user: HardhatEthersSigner, amount: number) {
    await setVaultAsOperator(user);
    const enc = await encryptForVault(amount, user);
    await vault.connect(user).deposit(enc.handles[0], enc.inputProof);
  }

  async function borrow(user: HardhatEthersSigner, amount: number) {
    const enc = await encryptForVault(amount, user);
    await vault.connect(user).borrow(enc.handles[0], enc.inputProof);
  }

  // ─── Tests ───────────────────────────────────────────────────────────

  describe("Deployment", function () {
    it("sets the right owner, oracle, token", async function () {
      expect(await vault.owner()).to.equal(owner.address);
      expect(await vault.oraclePrice()).to.equal(INITIAL_PRICE);
      expect(await vault.collateralToken()).to.equal(tokenAddr);
      expect(await vault.borrowingPaused()).to.equal(false);
    });

    it("rejects zero oracle price in constructor", async function () {
      const factory = await ethers.getContractFactory("ConfidentialCDPVault");
      await expect(factory.deploy(owner.address, tokenAddr, 0)).to.be.reverted;
    });
  });

  describe("Owner controls", function () {
    it("owner can set oracle price", async function () {
      await vault.connect(owner).setOraclePrice(3n);
      expect(await vault.oraclePrice()).to.equal(3n);
    });

    it("non-owner cannot set oracle price", async function () {
      await expect(vault.connect(alice).setOraclePrice(3n)).to.be.reverted;
    });

    it("owner can pause borrowing", async function () {
      await vault.connect(owner).setBorrowingPaused(true);
      expect(await vault.borrowingPaused()).to.equal(true);
    });

    it("paused borrow reverts", async function () {
      await deposit(alice, 500);
      await vault.connect(owner).setBorrowingPaused(true);
      const enc = await encryptForVault(100, alice);
      await expect(
        vault.connect(alice).borrow(enc.handles[0], enc.inputProof),
      ).to.be.reverted;
    });
  });

  describe("Deposit", function () {
    it("user can deposit cWETH and balance updates", async function () {
      await deposit(alice, 500);
      expect(await decryptCollateral(alice)).to.equal(500n);
      expect(await decryptTokenBalance(alice, alice)).to.equal(500n);
    });

    it("two deposits accumulate", async function () {
      await deposit(alice, 300);
      const enc = await encryptForVault(200, alice);
      await vault.connect(alice).deposit(enc.handles[0], enc.inputProof);
      expect(await decryptCollateral(alice)).to.equal(500n);
    });
  });

  describe("Borrow", function () {
    beforeEach(async function () {
      await deposit(alice, 500);
      // collateral 500, oraclePrice 2, LTV 60%
      // maxBorrow = 500 * 0.6 * 2 = 600 debt units
    });

    it("borrow at safe LTV succeeds", async function () {
      await borrow(alice, 300);
      expect(await decryptDebt(alice)).to.equal(300n);
    });

    it("borrow up to exact LTV cap succeeds", async function () {
      await borrow(alice, 600);
      expect(await decryptDebt(alice)).to.equal(600n);
    });

    it("over-LTV borrow silently caps to 0 (debt unchanged)", async function () {
      await borrow(alice, 700); // > 600 max
      expect(await decryptDebt(alice)).to.equal(0n);
    });

    it("partial then over-LTV does not increase debt", async function () {
      await borrow(alice, 300);
      expect(await decryptDebt(alice)).to.equal(300n);
      await borrow(alice, 500);
      expect(await decryptDebt(alice)).to.equal(300n);
    });
  });

  describe("Repay", function () {
    beforeEach(async function () {
      await deposit(alice, 500);
      await borrow(alice, 300);
    });

    it("repay reduces debt", async function () {
      const enc = await encryptForVault(100, alice);
      await vault.connect(alice).repay(enc.handles[0], enc.inputProof);
      expect(await decryptDebt(alice)).to.equal(200n);
    });

    it("repay greater than debt caps to debt", async function () {
      const enc = await encryptForVault(1000, alice);
      await vault.connect(alice).repay(enc.handles[0], enc.inputProof);
      expect(await decryptDebt(alice)).to.equal(0n);
    });
  });

  describe("Liquidation flow", function () {
    beforeEach(async function () {
      await deposit(alice, 500);
      await borrow(alice, 600);
    });

    it("position is NOT liquidatable at original price", async function () {
      // threshold = 500 * 0.8 * 2 = 800; debt 600 < 800 → safe
      await vault.connect(liquidator).requestLiquidationCheck(alice.address);
      const flagHandle = await vault.liquidationFlagOf(alice.address);
      const dec = await fhevm.publicDecrypt([flagHandle]);
      expect(dec.clearValues[flagHandle]).to.equal(0n);
    });

    it("price drop makes position liquidatable", async function () {
      // Drop oracle to 1 → threshold = 500 * 0.8 * 1 = 400; debt 600 > 400 → liquidatable
      await vault.connect(owner).setOraclePrice(1n);

      await vault.connect(liquidator).requestLiquidationCheck(alice.address);
      const flagHandle = await vault.liquidationFlagOf(alice.address);
      const dec = await fhevm.publicDecrypt([flagHandle]);
      expect(dec.clearValues[flagHandle]).to.equal(1n);
    });

    it("liquidator confirms + liquidates, receives collateral", async function () {
      await vault.connect(owner).setOraclePrice(1n);
      await vault.connect(liquidator).requestLiquidationCheck(alice.address);

      const flagHandle = await vault.liquidationFlagOf(alice.address);
      const dec = await fhevm.publicDecrypt([flagHandle]);
      expect(dec.clearValues[flagHandle]).to.equal(1n);

      // Confirm on-chain via checkSignatures
      await vault
        .connect(liquidator)
        .confirmLiquidatable(
          alice.address,
          dec.abiEncodedClearValues,
          dec.decryptionProof,
        );
      expect(await vault.isLiquidatableCached(alice.address)).to.equal(true);

      // Liquidate
      await vault.connect(liquidator).liquidate(alice.address);

      // Alice's positions wiped
      expect(await decryptCollateral(alice)).to.equal(0n);
      expect(await decryptDebt(alice)).to.equal(0n);

      // Liquidator received the collateral
      expect(await decryptTokenBalance(liquidator, liquidator)).to.equal(500n);
    });

    it("cannot liquidate if not flagged", async function () {
      // Original price (2), debt 600, threshold 800 → not liquidatable
      await vault.connect(liquidator).requestLiquidationCheck(alice.address);
      const flagHandle = await vault.liquidationFlagOf(alice.address);
      const dec = await fhevm.publicDecrypt([flagHandle]);

      await vault
        .connect(liquidator)
        .confirmLiquidatable(
          alice.address,
          dec.abiEncodedClearValues,
          dec.decryptionProof,
        );
      expect(await vault.isLiquidatableCached(alice.address)).to.equal(false);

      await expect(vault.connect(liquidator).liquidate(alice.address)).to.be.reverted;
    });
  });

  describe("Withdraw", function () {
    beforeEach(async function () {
      await deposit(alice, 500);
    });

    it("user can withdraw full collateral when no debt", async function () {
      const enc = await encryptForVault(500, alice);
      await vault.connect(alice).withdraw(enc.handles[0], enc.inputProof);
      expect(await decryptCollateral(alice)).to.equal(0n);
      expect(await decryptTokenBalance(alice, alice)).to.equal(1000n);
    });

    it("withdraw silently zeroes when debt > 0", async function () {
      await borrow(alice, 100);
      const enc = await encryptForVault(500, alice);
      await vault.connect(alice).withdraw(enc.handles[0], enc.inputProof);
      // Should NOT have withdrawn anything
      expect(await decryptCollateral(alice)).to.equal(500n);
      expect(await decryptTokenBalance(alice, alice)).to.equal(500n);
    });
  });

  describe("Access Control", function () {
    it("non-owner cannot decrypt another user's collateral", async function () {
      await deposit(alice, 500);
      const handle = await vault.collateralOf(alice.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, handle, vaultAddr, bob),
      ).to.be.rejected;
    });

    it("non-owner cannot decrypt another user's debt", async function () {
      await deposit(alice, 500);
      await borrow(alice, 100);
      const handle = await vault.debtOf(alice.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, handle, vaultAddr, bob),
      ).to.be.rejected;
    });
  });
});
