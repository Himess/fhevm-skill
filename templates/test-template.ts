// Test template for ERC-7984 confidential tokens (OpenZeppelin @openzeppelin/confidential-contracts).
// Matches the contract shipped in templates/confidential-erc20.sol (which inherits ERC7984).
//
// ERC-7984 uses:
//   - confidentialTransfer / confidentialTransferFrom (NOT transfer / transferFrom)
//   - confidentialBalanceOf  (NOT balanceOf)
//   - setOperator(address, uint48 until)  (NOT approve(address, amount))
//
// For a NON-ERC-7984 custom FHE token (e.g., one you wrote with ERC-20-style names), see
// the alternative test patterns inside this skill's references/testing-guide.md.

import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
// Replace with your contract's typechain types after `npx hardhat compile`:
// import type { ConfidentialToken } from "../typechain-types";

describe("ConfidentialToken (ERC-7984)", function () {
  let contract: any; // Replace 'any' with your typechain type
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let contractAddress: string;

  beforeEach(async function () {
    if (!fhevm.isMock) this.skip();
    [owner, alice, bob] = await ethers.getSigners();

    const factory = await ethers.getContractFactory("ConfidentialToken");
    // ERC7984 constructor: (owner_, name_, symbol_, contractURI_)
    contract = await factory.deploy(
      owner.address,
      "TestToken",
      "TT",
      "https://example.com/token.json",
    );
    await contract.waitForDeployment();
    contractAddress = await contract.getAddress();
  });

  // ─── Helpers ─────────────────────────────────────────────────────────

  /// Encrypts amount and calls confidentialTransfer (encrypted-input overload).
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
      ["confidentialTransfer(address,bytes32,bytes)"](
        to,
        encrypted.handles[0],
        encrypted.inputProof,
      );
  }

  /// Decrypts a user's confidential balance (only the user's own balance).
  async function decryptBalance(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await contract.confidentialBalanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, contractAddress, user);
  }

  // ─── Tests ───────────────────────────────────────────────────────────

  describe("Metadata", function () {
    it("has correct name, symbol, decimals", async function () {
      expect(await contract.name()).to.equal("TestToken");
      expect(await contract.symbol()).to.equal("TT");
      // ERC-7984 default is 6 decimals (NOT 18)
      expect(await contract.decimals()).to.equal(6n);
    });
  });

  describe("Minting", function () {
    it("mints to owner", async function () {
      await contract.mint(owner.address, 1000n);
      expect(await decryptBalance(owner)).to.equal(1000n);
    });

    it("mints to a different address", async function () {
      await contract.mint(alice.address, 500n);
      expect(await decryptBalance(alice)).to.equal(500n);
    });

    it("rejects non-owner mint", async function () {
      await expect(contract.connect(alice).mint(alice.address, 1000n)).to.be.reverted;
    });
  });

  describe("Confidential Transfer", function () {
    beforeEach(async function () {
      await contract.mint(owner.address, 1000n);
    });

    it("transfers tokens confidentially", async function () {
      await encryptAndTransfer(owner, alice.address, 300);
      expect(await decryptBalance(owner)).to.equal(700n);
      expect(await decryptBalance(alice)).to.equal(300n);
    });

    it("silently transfers 0 on insufficient balance", async function () {
      // Try to transfer 2000 with only 1000 balance — no revert, transfers 0.
      await encryptAndTransfer(owner, alice.address, 2000);
      expect(await decryptBalance(owner)).to.equal(1000n);
      expect(await decryptBalance(alice)).to.equal(0n);
    });

    it("handles multiple transfers in sequence", async function () {
      await encryptAndTransfer(owner, alice.address, 200);
      await encryptAndTransfer(owner, bob.address, 300);
      expect(await decryptBalance(owner)).to.equal(500n);
      expect(await decryptBalance(alice)).to.equal(200n);
      expect(await decryptBalance(bob)).to.equal(300n);
    });

    it("recipient can re-transfer received tokens", async function () {
      await encryptAndTransfer(owner, alice.address, 500);
      await encryptAndTransfer(alice, bob.address, 200);
      expect(await decryptBalance(alice)).to.equal(300n);
      expect(await decryptBalance(bob)).to.equal(200n);
    });
  });

  describe("Operator Model (replaces ERC-20 approve/allowance)", function () {
    beforeEach(async function () {
      await contract.mint(owner.address, 1000n);
    });

    it("operator can call confidentialTransferFrom", async function () {
      // Owner authorizes Alice as an operator until far-future timestamp.
      const maxUint48 = 2n ** 48n - 1n;
      await contract.setOperator(alice.address, maxUint48);
      expect(await contract.isOperator(owner.address, alice.address)).to.be.true;

      // Alice (operator) transfers from owner → bob with an encrypted amount.
      const enc = await fhevm
        .createEncryptedInput(contractAddress, alice.address)
        .add64(400n)
        .encrypt();
      await contract
        .connect(alice)
        ["confidentialTransferFrom(address,address,bytes32,bytes)"](
          owner.address,
          bob.address,
          enc.handles[0],
          enc.inputProof,
        );

      expect(await decryptBalance(owner)).to.equal(600n);
      expect(await decryptBalance(bob)).to.equal(400n);
    });

    it("non-operator cannot call confidentialTransferFrom", async function () {
      const enc = await fhevm
        .createEncryptedInput(contractAddress, alice.address)
        .add64(100n)
        .encrypt();
      await expect(
        contract
          .connect(alice)
          ["confidentialTransferFrom(address,address,bytes32,bytes)"](
            owner.address,
            bob.address,
            enc.handles[0],
            enc.inputProof,
          ),
      ).to.be.reverted;
    });

    it("setOperator(addr, 0) revokes operator status", async function () {
      const maxUint48 = 2n ** 48n - 1n;
      await contract.setOperator(alice.address, maxUint48);
      expect(await contract.isOperator(owner.address, alice.address)).to.be.true;

      await contract.setOperator(alice.address, 0);
      expect(await contract.isOperator(owner.address, alice.address)).to.be.false;
    });
  });

  describe("Access Control", function () {
    it("only the balance owner can decrypt their own balance", async function () {
      await contract.mint(owner.address, 1000n);
      await encryptAndTransfer(owner, alice.address, 500);

      // Alice can decrypt her own balance.
      expect(await decryptBalance(alice)).to.equal(500n);

      // Bob CANNOT decrypt Alice's balance — no FHE.allow(...) was granted to him.
      const aliceHandle = await contract.confidentialBalanceOf(alice.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, aliceHandle, contractAddress, bob),
      ).to.be.rejected;
    });
  });
});
