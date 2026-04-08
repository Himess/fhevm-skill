// Test template for standalone confidential contracts (custom FHE pattern).
// For ERC-7984 standard tokens, use confidentialTransfer/confidentialBalanceOf instead.
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
// Replace with your contract's type:
// import type { ConfidentialERC20 } from "../typechain-types";

describe("ConfidentialERC20", function () {
  let contract: any; // Replace 'any' with your contract type
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let contractAddress: string;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const factory = await ethers.getContractFactory("ConfidentialERC20");
    contract = await factory.deploy("TestToken", "TT");
    await contract.waitForDeployment();
    contractAddress = await contract.getAddress();
  });

  // ─── Helper: Encrypt and send ─────────────────────────────────────
  async function encryptAndTransfer(
    signer: HardhatEthersSigner,
    to: string,
    amount: number | bigint,
  ) {
    const encrypted = await fhevm
      .createEncryptedInput(contractAddress, signer.address)
      .add64(BigInt(amount))
      .encrypt();
    return contract
      .connect(signer)
      ["transfer(address,bytes32,bytes)"](to, encrypted.handles[0], encrypted.inputProof);
  }

  // ─── Helper: Decrypt balance ──────────────────────────────────────
  async function decryptBalance(user: HardhatEthersSigner): Promise<bigint> {
    const encHandle = await contract.balanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, encHandle, contractAddress, user);
  }

  // ─── Tests ────────────────────────────────────────────────────────

  describe("Minting", function () {
    it("should mint tokens to owner", async function () {
      await contract.mint(1000);
      const balance = await decryptBalance(owner);
      expect(balance).to.equal(1000n);
    });

    it("should update total supply", async function () {
      await contract.mint(5000);
      expect(await contract.totalSupply()).to.equal(5000n);
    });

    it("should reject non-owner mint", async function () {
      await expect(contract.connect(alice).mint(1000)).to.be.reverted;
    });
  });

  describe("Transfer", function () {
    beforeEach(async function () {
      await contract.mint(1000);
    });

    it("should transfer tokens confidentially", async function () {
      await encryptAndTransfer(owner, alice.address, 300);

      expect(await decryptBalance(owner)).to.equal(700n);
      expect(await decryptBalance(alice)).to.equal(300n);
    });

    it("should silently transfer 0 on insufficient balance", async function () {
      // Try to transfer 2000 with only 1000 balance
      await encryptAndTransfer(owner, alice.address, 2000);

      // No revert! But 0 was transferred.
      expect(await decryptBalance(owner)).to.equal(1000n);
      expect(await decryptBalance(alice)).to.equal(0n);
    });

    it("should handle multiple transfers", async function () {
      await encryptAndTransfer(owner, alice.address, 200);
      await encryptAndTransfer(owner, bob.address, 300);

      expect(await decryptBalance(owner)).to.equal(500n);
      expect(await decryptBalance(alice)).to.equal(200n);
      expect(await decryptBalance(bob)).to.equal(300n);
    });

    it("should allow recipient to transfer received tokens", async function () {
      await encryptAndTransfer(owner, alice.address, 500);
      await encryptAndTransfer(alice, bob.address, 200);

      expect(await decryptBalance(alice)).to.equal(300n);
      expect(await decryptBalance(bob)).to.equal(200n);
    });
  });

  describe("Approval & TransferFrom", function () {
    beforeEach(async function () {
      await contract.mint(1000);
    });

    it("should approve and transferFrom", async function () {
      // Owner approves alice to spend 500
      const approveEnc = await fhevm
        .createEncryptedInput(contractAddress, owner.address)
        .add64(500)
        .encrypt();
      await contract.approve(alice.address, approveEnc.handles[0], approveEnc.inputProof);

      // Alice transfers 300 from owner to bob
      const transferEnc = await fhevm
        .createEncryptedInput(contractAddress, alice.address)
        .add64(300)
        .encrypt();
      await contract
        .connect(alice)
        .transferFrom(owner.address, bob.address, transferEnc.handles[0], transferEnc.inputProof);

      expect(await decryptBalance(owner)).to.equal(700n);
      expect(await decryptBalance(bob)).to.equal(300n);
    });

    it("should silently transfer 0 on insufficient allowance", async function () {
      // Approve only 100
      const approveEnc = await fhevm
        .createEncryptedInput(contractAddress, owner.address)
        .add64(100)
        .encrypt();
      await contract.approve(alice.address, approveEnc.handles[0], approveEnc.inputProof);

      // Try to transfer 500 (exceeds allowance)
      const transferEnc = await fhevm
        .createEncryptedInput(contractAddress, alice.address)
        .add64(500)
        .encrypt();
      await contract
        .connect(alice)
        .transferFrom(owner.address, bob.address, transferEnc.handles[0], transferEnc.inputProof);

      // No revert, 0 transferred
      expect(await decryptBalance(owner)).to.equal(1000n);
      expect(await decryptBalance(bob)).to.equal(0n);
    });
  });

  describe("Access Control", function () {
    it("should only allow balance owner to decrypt", async function () {
      await contract.mint(1000);
      await encryptAndTransfer(owner, alice.address, 500);

      // Alice can decrypt her own balance
      const aliceBal = await decryptBalance(alice);
      expect(aliceBal).to.equal(500n);

      // Bob should NOT be able to decrypt alice's balance
      const aliceHandle = await contract.balanceOf(alice.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, aliceHandle, contractAddress, bob),
      ).to.be.rejected;
    });
  });
});
