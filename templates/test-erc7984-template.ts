// Test template for ERC-7984 confidential tokens using @openzeppelin/confidential-contracts.
// Uses confidentialTransfer/confidentialBalanceOf (NOT transfer/balanceOf).
// Uses operator model (setOperator) instead of approve/allowance.
import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";
// Replace with your contract's typechain types:
// import type { MyToken, MyToken__factory } from "../types";

type Signers = {
  deployer: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
};

async function deployFixture() {
  // Replace "MyToken" with your contract name
  const factory = await ethers.getContractFactory("MyToken");
  const contract = await factory.deploy(
    /* owner */ (await ethers.getSigners())[0].address,
    /* name */ "MyToken",
    /* symbol */ "MTK",
    /* contractURI */ "https://example.com/token.json",
  );
  await contract.waitForDeployment();
  const contractAddress = await contract.getAddress();
  return { contract, contractAddress };
}

describe("ERC-7984 Token", function () {
  let contract: any; // Replace with your typechain type
  let contractAddress: string;
  let signers: Signers;

  before(async function () {
    const s = await ethers.getSigners();
    signers = { deployer: s[0], alice: s[1], bob: s[2] };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) {
      this.skip();
    }
    ({ contract, contractAddress } = await deployFixture());
  });

  // ─── Helper: Encrypt and transfer ─────────────────────────────────
  async function encryptAndTransfer(
    signer: HardhatEthersSigner,
    to: string,
    amount: number | bigint,
  ) {
    const encrypted = await fhevm
      .createEncryptedInput(contractAddress, signer.address)
      .add64(BigInt(amount))
      .encrypt();
    // ERC-7984 uses confidentialTransfer (NOT transfer)
    const tx = await contract
      .connect(signer)
      ["confidentialTransfer(address,bytes32,bytes)"](to, encrypted.handles[0], encrypted.inputProof);
    await tx.wait();
  }

  // ─── Helper: Decrypt balance ──────────────────────────────────────
  async function decryptBalance(user: HardhatEthersSigner): Promise<bigint> {
    // ERC-7984 uses confidentialBalanceOf (NOT balanceOf)
    const encHandle = await contract.connect(user).confidentialBalanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, encHandle, contractAddress, user);
  }

  // ─── Tests ────────────────────────────────────────────────────────

  describe("Metadata", function () {
    it("should have correct name, symbol, decimals", async function () {
      expect(await contract.name()).to.equal("MyToken");
      expect(await contract.symbol()).to.equal("MTK");
      expect(await contract.decimals()).to.equal(6n); // ERC-7984 default
    });
  });

  describe("Minting", function () {
    it("should mint tokens", async function () {
      await contract.mint(signers.deployer.address, 1000);
      const balance = await decryptBalance(signers.deployer);
      expect(balance).to.equal(1000n);
    });

    it("should reject non-owner mint", async function () {
      await expect(
        contract.connect(signers.alice).mint(signers.alice.address, 1000),
      ).to.be.reverted;
    });
  });

  describe("Confidential Transfer", function () {
    beforeEach(async function () {
      await contract.mint(signers.deployer.address, 1000);
    });

    it("should transfer confidentially", async function () {
      await encryptAndTransfer(signers.deployer, signers.alice.address, 300);
      expect(await decryptBalance(signers.deployer)).to.equal(700n);
      expect(await decryptBalance(signers.alice)).to.equal(300n);
    });

    it("should silently transfer 0 on insufficient balance", async function () {
      await encryptAndTransfer(signers.deployer, signers.alice.address, 2000);
      expect(await decryptBalance(signers.deployer)).to.equal(1000n);
      expect(await decryptBalance(signers.alice)).to.equal(0n);
    });
  });

  describe("Operator Model", function () {
    beforeEach(async function () {
      await contract.mint(signers.deployer.address, 1000);
    });

    it("should allow operator to transferFrom", async function () {
      // Set alice as operator (max uint48 = far future expiry)
      const maxUint48 = 2n ** 48n - 1n;
      await contract.setOperator(signers.alice.address, maxUint48);
      expect(await contract.isOperator(signers.deployer.address, signers.alice.address)).to.be.true;

      // Alice transfers from deployer to bob
      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(400)
        .encrypt();
      await contract
        .connect(signers.alice)
        ["confidentialTransferFrom(address,address,bytes32,bytes)"](
          signers.deployer.address,
          signers.bob.address,
          encrypted.handles[0],
          encrypted.inputProof,
        );

      expect(await decryptBalance(signers.deployer)).to.equal(600n);
      expect(await decryptBalance(signers.bob)).to.equal(400n);
    });

    it("should reject non-operator transferFrom", async function () {
      const encrypted = await fhevm
        .createEncryptedInput(contractAddress, signers.alice.address)
        .add64(100)
        .encrypt();
      await expect(
        contract
          .connect(signers.alice)
          ["confidentialTransferFrom(address,address,bytes32,bytes)"](
            signers.deployer.address,
            signers.bob.address,
            encrypted.handles[0],
            encrypted.inputProof,
          ),
      ).to.be.reverted;
    });

    it("should revoke operator by setting expiry to 0", async function () {
      const maxUint48 = 2n ** 48n - 1n;
      await contract.setOperator(signers.alice.address, maxUint48);
      expect(await contract.isOperator(signers.deployer.address, signers.alice.address)).to.be.true;

      await contract.setOperator(signers.alice.address, 0);
      expect(await contract.isOperator(signers.deployer.address, signers.alice.address)).to.be.false;
    });
  });
});
