import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("ConfidentialWrappedERC20", function () {
  let token: any;
  let mockERC20: any;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let tokenAddress: string;
  let mockERC20Address: string;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    // Deploy a mock ERC-20 as the underlying token for wrapping
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    mockERC20 = await MockERC20Factory.deploy("Mock USDC", "MUSDC", 6);
    await mockERC20.waitForDeployment();
    mockERC20Address = await mockERC20.getAddress();

    // Deploy the confidential wrapped token
    const TokenFactory = await ethers.getContractFactory("ConfidentialWrappedERC20");
    token = await TokenFactory.deploy("Confidential USDC", "cUSDC", mockERC20Address);
    await token.waitForDeployment();
    tokenAddress = await token.getAddress();
  });

  // --- Helpers ---

  async function encryptAmount(
    signer: HardhatEthersSigner,
    amount: number | bigint,
  ) {
    return fhevm
      .createEncryptedInput(tokenAddress, signer.address)
      .add64(BigInt(amount))
      .encrypt();
  }

  async function encryptAndTransfer(
    signer: HardhatEthersSigner,
    to: string,
    amount: number | bigint,
  ) {
    const encrypted = await encryptAmount(signer, amount);
    return token
      .connect(signer)
      ["transfer(address,bytes32,bytes)"](to, encrypted.handles[0], encrypted.inputProof);
  }

  async function decryptBalance(user: HardhatEthersSigner): Promise<bigint> {
    const encHandle = await token.balanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, encHandle, tokenAddress, user);
  }

  // =========================================================================
  //                              MINTING TESTS
  // =========================================================================

  describe("Minting", function () {
    it("should mint tokens to the owner", async function () {
      await token.mint(1000);
      const balance = await decryptBalance(owner);
      expect(balance).to.equal(1000n);
    });

    it("should update total supply after minting", async function () {
      await token.mint(5000);
      expect(await token.totalSupply()).to.equal(5000n);
    });

    it("should accumulate across multiple mints", async function () {
      await token.mint(1000);
      await token.mint(2000);
      const balance = await decryptBalance(owner);
      expect(balance).to.equal(3000n);
      expect(await token.totalSupply()).to.equal(3000n);
    });

    it("should reject minting from non-owner", async function () {
      await expect(token.connect(alice).mint(1000)).to.be.reverted;
    });

    it("should mint zero without error", async function () {
      await token.mint(0);
      expect(await token.totalSupply()).to.equal(0n);
    });
  });

  // =========================================================================
  //                             TRANSFER TESTS
  // =========================================================================

  describe("Transfer", function () {
    beforeEach(async function () {
      await token.mint(10000);
    });

    it("should transfer tokens confidentially", async function () {
      await encryptAndTransfer(owner, alice.address, 3000);

      expect(await decryptBalance(owner)).to.equal(7000n);
      expect(await decryptBalance(alice)).to.equal(3000n);
    });

    it("should silently transfer 0 on insufficient balance", async function () {
      // Owner has 10000, tries to send 20000
      await encryptAndTransfer(owner, alice.address, 20000);

      // No revert -- 0 was transferred (silent failure by design)
      expect(await decryptBalance(owner)).to.equal(10000n);
      expect(await decryptBalance(alice)).to.equal(0n);
    });

    it("should handle transfer of exact balance", async function () {
      await encryptAndTransfer(owner, alice.address, 10000);

      expect(await decryptBalance(owner)).to.equal(0n);
      expect(await decryptBalance(alice)).to.equal(10000n);
    });

    it("should handle multiple sequential transfers", async function () {
      await encryptAndTransfer(owner, alice.address, 2000);
      await encryptAndTransfer(owner, bob.address, 3000);

      expect(await decryptBalance(owner)).to.equal(5000n);
      expect(await decryptBalance(alice)).to.equal(2000n);
      expect(await decryptBalance(bob)).to.equal(3000n);
    });

    it("should allow recipient to forward received tokens", async function () {
      await encryptAndTransfer(owner, alice.address, 5000);
      await encryptAndTransfer(alice, bob.address, 2000);

      expect(await decryptBalance(alice)).to.equal(3000n);
      expect(await decryptBalance(bob)).to.equal(2000n);
    });

    it("should revert on transfer to zero address", async function () {
      const encrypted = await encryptAmount(owner, 100);
      await expect(
        token["transfer(address,bytes32,bytes)"](
          ethers.ZeroAddress,
          encrypted.handles[0],
          encrypted.inputProof,
        ),
      ).to.be.revertedWith("Transfer to zero address");
    });
  });

  // =========================================================================
  //                      APPROVAL & TRANSFER-FROM TESTS
  // =========================================================================

  describe("Approval & TransferFrom", function () {
    beforeEach(async function () {
      await token.mint(10000);
    });

    it("should approve and transferFrom", async function () {
      // Owner approves alice to spend 5000
      const approveEnc = await encryptAmount(owner, 5000);
      await token.approve(alice.address, approveEnc.handles[0], approveEnc.inputProof);

      // Alice transfers 3000 from owner to bob
      const transferEnc = await fhevm
        .createEncryptedInput(tokenAddress, alice.address)
        .add64(3000n)
        .encrypt();
      await token
        .connect(alice)
        .transferFrom(
          owner.address,
          bob.address,
          transferEnc.handles[0],
          transferEnc.inputProof,
        );

      expect(await decryptBalance(owner)).to.equal(7000n);
      expect(await decryptBalance(bob)).to.equal(3000n);
    });

    it("should silently transfer 0 on insufficient allowance", async function () {
      // Approve only 100
      const approveEnc = await encryptAmount(owner, 100);
      await token.approve(alice.address, approveEnc.handles[0], approveEnc.inputProof);

      // Alice tries to transfer 500 (exceeds allowance)
      const transferEnc = await fhevm
        .createEncryptedInput(tokenAddress, alice.address)
        .add64(500n)
        .encrypt();
      await token
        .connect(alice)
        .transferFrom(
          owner.address,
          bob.address,
          transferEnc.handles[0],
          transferEnc.inputProof,
        );

      // No revert, but 0 was transferred
      expect(await decryptBalance(owner)).to.equal(10000n);
      expect(await decryptBalance(bob)).to.equal(0n);
    });

    it("should reduce allowance after transferFrom", async function () {
      // Approve 5000
      const approveEnc = await encryptAmount(owner, 5000);
      await token.approve(alice.address, approveEnc.handles[0], approveEnc.inputProof);

      // Transfer 2000
      const transferEnc = await fhevm
        .createEncryptedInput(tokenAddress, alice.address)
        .add64(2000n)
        .encrypt();
      await token
        .connect(alice)
        .transferFrom(
          owner.address,
          bob.address,
          transferEnc.handles[0],
          transferEnc.inputProof,
        );

      // Try to transfer another 4000 (only 3000 allowance left)
      const transferEnc2 = await fhevm
        .createEncryptedInput(tokenAddress, alice.address)
        .add64(4000n)
        .encrypt();
      await token
        .connect(alice)
        .transferFrom(
          owner.address,
          bob.address,
          transferEnc2.handles[0],
          transferEnc2.inputProof,
        );

      // Second transfer should silently fail (4000 > 3000 remaining allowance)
      expect(await decryptBalance(owner)).to.equal(8000n); // Only first 2000 deducted
      expect(await decryptBalance(bob)).to.equal(2000n);
    });

    it("should allow overwriting approval", async function () {
      // First approve 5000
      const approveEnc1 = await encryptAmount(owner, 5000);
      await token.approve(alice.address, approveEnc1.handles[0], approveEnc1.inputProof);

      // Overwrite with 200
      const approveEnc2 = await encryptAmount(owner, 200);
      await token.approve(alice.address, approveEnc2.handles[0], approveEnc2.inputProof);

      // Alice tries to transfer 300 (exceeds new 200 allowance)
      const transferEnc = await fhevm
        .createEncryptedInput(tokenAddress, alice.address)
        .add64(300n)
        .encrypt();
      await token
        .connect(alice)
        .transferFrom(
          owner.address,
          bob.address,
          transferEnc.handles[0],
          transferEnc.inputProof,
        );

      // 0 transferred (300 > 200 allowance)
      expect(await decryptBalance(owner)).to.equal(10000n);
      expect(await decryptBalance(bob)).to.equal(0n);
    });
  });

  // =========================================================================
  //                              WRAP TESTS
  // =========================================================================

  describe("Wrap", function () {
    beforeEach(async function () {
      // Mint underlying ERC-20 to alice
      await mockERC20.mint(alice.address, 100000);
      // Alice approves the confidential token to spend her ERC-20
      await mockERC20.connect(alice).approve(tokenAddress, 100000);
    });

    it("should wrap ERC-20 tokens into confidential tokens", async function () {
      await token.connect(alice).wrap(5000);

      expect(await decryptBalance(alice)).to.equal(5000n);
      expect(await token.totalSupply()).to.equal(5000n);

      // Underlying ERC-20 balance should decrease
      expect(await mockERC20.balanceOf(alice.address)).to.equal(95000n);
      // Contract should hold the underlying tokens
      expect(await mockERC20.balanceOf(tokenAddress)).to.equal(5000n);
    });

    it("should accumulate across multiple wraps", async function () {
      await token.connect(alice).wrap(2000);
      await token.connect(alice).wrap(3000);

      expect(await decryptBalance(alice)).to.equal(5000n);
      expect(await token.totalSupply()).to.equal(5000n);
    });

    it("should reject wrap of zero amount", async function () {
      await expect(token.connect(alice).wrap(0)).to.be.revertedWith("Amount must be > 0");
    });

    it("should revert if user has insufficient ERC-20 balance", async function () {
      // Bob has no underlying tokens
      await expect(token.connect(bob).wrap(1000)).to.be.reverted;
    });

    it("should allow wrapped tokens to be transferred", async function () {
      await token.connect(alice).wrap(5000);
      await encryptAndTransfer(alice, bob.address, 2000);

      expect(await decryptBalance(alice)).to.equal(3000n);
      expect(await decryptBalance(bob)).to.equal(2000n);
    });

    it("should coexist with minted tokens", async function () {
      // Owner mints 1000
      await token.mint(1000);
      // Alice wraps 5000
      await token.connect(alice).wrap(5000);

      expect(await decryptBalance(owner)).to.equal(1000n);
      expect(await decryptBalance(alice)).to.equal(5000n);
      expect(await token.totalSupply()).to.equal(6000n);
    });
  });

  // =========================================================================
  //                        ACCESS CONTROL TESTS
  // =========================================================================

  describe("Access Control", function () {
    it("should only allow balance owner to decrypt their balance", async function () {
      await token.mint(1000);
      await encryptAndTransfer(owner, alice.address, 500);

      // Alice can decrypt her own balance
      const aliceBal = await decryptBalance(alice);
      expect(aliceBal).to.equal(500n);

      // Bob should NOT be able to decrypt alice's balance
      const aliceHandle = await token.balanceOf(alice.address);
      await expect(
        fhevm.userDecryptEuint(FhevmType.euint64, aliceHandle, tokenAddress, bob),
      ).to.be.rejected;
    });

    it("should prevent non-owner from minting", async function () {
      await expect(token.connect(alice).mint(1000)).to.be.reverted;
      await expect(token.connect(bob).mint(1000)).to.be.reverted;
    });
  });

  // =========================================================================
  //                          EDGE CASE TESTS
  // =========================================================================

  describe("Edge Cases", function () {
    it("should handle transfer to self", async function () {
      await token.mint(5000);
      await encryptAndTransfer(owner, owner.address, 2000);

      // Balance should remain 5000 (sent 2000 to self = net zero)
      expect(await decryptBalance(owner)).to.equal(5000n);
    });

    it("should handle zero-amount transfer", async function () {
      await token.mint(1000);
      await encryptAndTransfer(owner, alice.address, 0);

      expect(await decryptBalance(owner)).to.equal(1000n);
      expect(await decryptBalance(alice)).to.equal(0n);
    });

    it("should handle transfer from account with no balance", async function () {
      // Alice has never received tokens -- has no initialized balance
      // This should not revert, just silently transfer 0
      await encryptAndTransfer(alice, bob.address, 100);

      expect(await decryptBalance(alice)).to.equal(0n);
      expect(await decryptBalance(bob)).to.equal(0n);
    });
  });

  // =========================================================================
  //                           METADATA TESTS
  // =========================================================================

  describe("Metadata", function () {
    it("should return correct name and symbol", async function () {
      expect(await token.name()).to.equal("Confidential USDC");
      expect(await token.symbol()).to.equal("cUSDC");
    });

    it("should return correct decimals", async function () {
      expect(await token.decimals()).to.equal(6);
    });

    it("should return correct underlying token address", async function () {
      expect(await token.underlying()).to.equal(mockERC20Address);
    });
  });
});
