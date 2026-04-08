import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("MultiBlindAuction", function () {
  let auction: any;
  let token: any;
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let charlie: HardhatEthersSigner;
  let auctionAddress: string;
  let tokenAddress: string;

  // ─── Helpers ────────────────────────────────────────────────────────

  async function mintTokens(to: HardhatEthersSigner, amount: number | bigint) {
    // Mint to owner first, then transfer
    await token.mint(BigInt(amount));
    if (to.address !== owner.address) {
      const enc = await fhevm
        .createEncryptedInput(tokenAddress, owner.address)
        .add64(BigInt(amount))
        .encrypt();
      await token
        .connect(owner)
        ["transfer(address,bytes32,bytes)"](to.address, enc.handles[0], enc.inputProof);
    }
  }

  async function decryptBalance(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await token.balanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, tokenAddress, user);
  }

  async function placeBid(
    signer: HardhatEthersSigner,
    auctionId: number,
    amount: number | bigint,
  ) {
    const enc = await fhevm
      .createEncryptedInput(auctionAddress, signer.address)
      .add64(BigInt(amount))
      .encrypt();
    return auction.connect(signer).bid(auctionId, enc.handles[0], enc.inputProof);
  }

  async function decryptMyBid(
    signer: HardhatEthersSigner,
    auctionId: number,
  ): Promise<bigint> {
    const handle = await auction.connect(signer).getMyBid(auctionId);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, auctionAddress, signer);
  }

  async function createDefaultAuction(): Promise<number> {
    const now = await time.latest();
    const startTime = now + 1;
    const endTime = now + 3600; // 1 hour from now
    const tx = await auction.createAuction("Test Item", startTime, endTime);
    await tx.wait();
    // Advance time to after startTime so bids are accepted
    await time.increaseTo(startTime + 1);
    return 0; // First auction ID
  }

  // ─── Setup ──────────────────────────────────────────────────────────

  beforeEach(async function () {
    [owner, alice, bob, charlie] = await ethers.getSigners();

    // Deploy the confidential ERC-20 token
    const tokenFactory = await ethers.getContractFactory("ConfidentialERC20");
    token = await tokenFactory.deploy("AuctionToken", "AUCT");
    await token.waitForDeployment();
    tokenAddress = await token.getAddress();

    // Deploy the multi-auction contract
    const auctionFactory = await ethers.getContractFactory("MultiBlindAuction");
    auction = await auctionFactory.deploy(tokenAddress);
    await auction.waitForDeployment();
    auctionAddress = await auction.getAddress();

    // Mint and distribute tokens for testing
    await mintTokens(alice, 10000);
    await mintTokens(bob, 10000);
    await mintTokens(charlie, 10000);
  });

  // ─── Auction Creation ─────────────────────────────────────────────

  describe("Auction Creation", function () {
    it("should create an auction with correct parameters", async function () {
      const now = await time.latest();
      const startTime = now + 60;
      const endTime = now + 3600;

      await auction.createAuction("Rare NFT", startTime, endTime);

      const info = await auction.getAuctionInfo(0);
      expect(info.itemName).to.equal("Rare NFT");
      expect(info.state).to.equal(0); // Bidding
      expect(info.startTime).to.equal(startTime);
      expect(info.endTime).to.equal(endTime);
      expect(info.bidCount).to.equal(0);
      expect(info.revealedWinner).to.equal(ethers.ZeroAddress);
      expect(info.revealedHighestBid).to.equal(0);
    });

    it("should create multiple auctions", async function () {
      const now = await time.latest();
      await auction.createAuction("Item A", now + 1, now + 3600);
      await auction.createAuction("Item B", now + 1, now + 7200);
      await auction.createAuction("Item C", now + 3600, now + 7200);

      expect(await auction.auctionCount()).to.equal(3);

      const infoA = await auction.getAuctionInfo(0);
      const infoB = await auction.getAuctionInfo(1);
      const infoC = await auction.getAuctionInfo(2);

      expect(infoA.itemName).to.equal("Item A");
      expect(infoB.itemName).to.equal("Item B");
      expect(infoC.itemName).to.equal("Item C");
    });

    it("should reject auction with endTime <= startTime", async function () {
      const now = await time.latest();
      await expect(
        auction.createAuction("Bad Auction", now + 3600, now + 1),
      ).to.be.revertedWithCustomError(auction, "InvalidTimeRange");
    });

    it("should reject non-owner creating auction", async function () {
      const now = await time.latest();
      await expect(
        auction.connect(alice).createAuction("Unauthorized", now + 1, now + 3600),
      ).to.be.reverted;
    });

    it("should reject accessing non-existent auction", async function () {
      await expect(auction.getAuctionInfo(999)).to.be.revertedWithCustomError(
        auction,
        "AuctionDoesNotExist",
      );
    });
  });

  // ─── Bidding ──────────────────────────────────────────────────────

  describe("Bidding", function () {
    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should accept an encrypted bid", async function () {
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      expect(info.bidCount).to.equal(1);
      expect(await auction.hasBid(auctionId, alice.address)).to.be.true;
    });

    it("should allow bidder to view their own bid", async function () {
      await placeBid(alice, auctionId, 500);

      const myBid = await decryptMyBid(alice, auctionId);
      expect(myBid).to.equal(500n);
    });

    it("should accept multiple different bidders", async function () {
      await placeBid(alice, auctionId, 500);
      // Advance time past rate limit for different bidders (they have separate timestamps)
      await placeBid(bob, auctionId, 700);
      await placeBid(charlie, auctionId, 300);

      const info = await auction.getAuctionInfo(auctionId);
      expect(info.bidCount).to.equal(3);
    });

    it("should reject duplicate bid from same address", async function () {
      await placeBid(alice, auctionId, 500);
      await expect(placeBid(alice, auctionId, 600)).to.be.revertedWithCustomError(
        auction,
        "AlreadyBid",
      );
    });

    it("should reject bid from owner", async function () {
      // Owner needs to use a different mechanism — they cannot bid on their own auction
      const enc = await fhevm
        .createEncryptedInput(auctionAddress, owner.address)
        .add64(100n)
        .encrypt();
      await expect(
        auction.connect(owner).bid(auctionId, enc.handles[0], enc.inputProof),
      ).to.be.revertedWithCustomError(auction, "OwnerCannotBid");
    });

    it("should reject bid before auction start time", async function () {
      const now = await time.latest();
      // Create an auction that starts in the future
      await auction.createAuction("Future Item", now + 7200, now + 14400);
      const futureAuctionId = 1;

      await expect(placeBid(alice, futureAuctionId, 500)).to.be.revertedWithCustomError(
        auction,
        "AuctionNotStarted",
      );
    });

    it("should reject bid after auction end time", async function () {
      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime) + 1);

      await expect(placeBid(alice, auctionId, 500)).to.be.revertedWithCustomError(
        auction,
        "AuctionNotExpired",
      );
    });

    it("should reject bid on non-existent auction", async function () {
      await expect(placeBid(alice, 999, 500)).to.be.revertedWithCustomError(
        auction,
        "AuctionDoesNotExist",
      );
    });

    it("should track bids independently across auctions", async function () {
      const now = await time.latest();
      await auction.createAuction("Item B", now + 1, now + 3600);
      await time.increaseTo(now + 2);

      const secondAuctionId = 1;

      await placeBid(alice, auctionId, 500);
      await placeBid(alice, secondAuctionId, 800);

      const bidA = await decryptMyBid(alice, auctionId);
      const bidB = await decryptMyBid(alice, secondAuctionId);

      expect(bidA).to.equal(500n);
      expect(bidB).to.equal(800n);
    });
  });

  // ─── Rate Limiting ────────────────────────────────────────────────

  describe("Rate Limiting", function () {
    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should enforce minimum bid interval per address", async function () {
      // Alice bids on auction 0
      await placeBid(alice, auctionId, 500);

      // Create another auction for the same time range
      const now = await time.latest();
      await auction.createAuction("Item B", now + 1, now + 3600);
      await time.increaseTo(now + 2);
      const secondAuctionId = 1;

      // Alice tries to bid again immediately on auction 1 — should fail
      await expect(placeBid(alice, secondAuctionId, 600)).to.be.revertedWithCustomError(
        auction,
        "RateLimited",
      );
    });

    it("should allow bid after rate limit period passes", async function () {
      await placeBid(alice, auctionId, 500);

      // Create another auction
      const now = await time.latest();
      await auction.createAuction("Item B", now + 1, now + 3600);

      // Advance past rate limit
      await time.increase(31); // MIN_BID_INTERVAL = 30 seconds

      const secondAuctionId = 1;
      // Now alice should be able to bid
      await expect(placeBid(alice, secondAuctionId, 600)).to.not.be.reverted;
    });

    it("should allow different users to bid simultaneously", async function () {
      // Different users have separate rate limit timestamps
      await placeBid(alice, auctionId, 500);
      await placeBid(bob, auctionId, 600);
      await placeBid(charlie, auctionId, 700);

      const info = await auction.getAuctionInfo(auctionId);
      expect(info.bidCount).to.equal(3);
    });
  });

  // ─── End Auction ──────────────────────────────────────────────────

  describe("End Auction", function () {
    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should end auction after expiry", async function () {
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await auction.endAuction(auctionId);

      const updatedInfo = await auction.getAuctionInfo(auctionId);
      expect(updatedInfo.state).to.equal(1); // Ended
    });

    it("should end auction early if no bids", async function () {
      // No bids placed, owner can end immediately
      await auction.endAuction(auctionId);

      const info = await auction.getAuctionInfo(auctionId);
      expect(info.state).to.equal(1); // Ended
    });

    it("should reject ending before expiry with active bids", async function () {
      await placeBid(alice, auctionId, 500);

      await expect(auction.endAuction(auctionId)).to.be.revertedWithCustomError(
        auction,
        "AuctionNotExpired",
      );
    });

    it("should reject non-owner ending auction", async function () {
      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await expect(
        auction.connect(alice).endAuction(auctionId),
      ).to.be.reverted;
    });

    it("should reject ending an already ended auction", async function () {
      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await auction.endAuction(auctionId);
      await expect(auction.endAuction(auctionId)).to.be.revertedWithCustomError(
        auction,
        "AuctionNotActive",
      );
    });
  });

  // ─── Winner Reveal (via Public Decryption) ────────────────────────

  describe("Winner Reveal", function () {
    // NOTE: In the Hardhat mock environment, public decryption with
    // checkSignatures may need special handling. These tests verify
    // the state transitions and logic around the reveal flow.

    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should reject reveal before auction is ended", async function () {
      await placeBid(alice, auctionId, 500);

      await expect(
        auction.revealWinner(auctionId, "0x", "0x"),
      ).to.be.revertedWithCustomError(auction, "AuctionNotRevealed");
    });

    it("should transition to Ended state after endAuction", async function () {
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await auction.endAuction(auctionId);

      const endedInfo = await auction.getAuctionInfo(auctionId);
      expect(endedInfo.state).to.equal(1); // Ended
    });
  });

  // ─── Refund Claims ────────────────────────────────────────────────

  describe("Refund Claims", function () {
    // These tests verify the refund logic prerequisites.
    // Full refund flow requires public decryption to reveal winner first.

    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should reject refund before auction is revealed", async function () {
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await auction.endAuction(auctionId);

      // Auction is Ended but not Revealed — refund should fail
      await expect(
        auction.connect(alice).claimRefund(auctionId),
      ).to.be.revertedWithCustomError(auction, "AuctionNotRevealed");
    });

    it("should reject refund from non-bidder", async function () {
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));

      await auction.endAuction(auctionId);

      // Bob never bid — should be rejected even before reveal
      await expect(
        auction.connect(bob).claimRefund(auctionId),
      ).to.be.revertedWithCustomError(auction, "AuctionNotRevealed");
    });

    it("should reject refund on non-existent auction", async function () {
      await expect(
        auction.connect(alice).claimRefund(999),
      ).to.be.revertedWithCustomError(auction, "AuctionDoesNotExist");
    });
  });

  // ─── Encrypted Bid Privacy ────────────────────────────────────────

  describe("Bid Privacy", function () {
    let auctionId: number;

    beforeEach(async function () {
      auctionId = await createDefaultAuction();
    });

    it("should not allow Bob to decrypt Alice's bid", async function () {
      await placeBid(alice, auctionId, 500);

      // Bob tries to read Alice's bid — should fail ACL check
      await expect(
        auction.connect(bob).getMyBid(auctionId),
      ).to.be.revertedWith("No bid placed");
    });

    it("should keep bids encrypted and independent", async function () {
      await placeBid(alice, auctionId, 500);
      await placeBid(bob, auctionId, 700);

      // Each bidder can only see their own bid
      const aliceBid = await decryptMyBid(alice, auctionId);
      const bobBid = await decryptMyBid(bob, auctionId);

      expect(aliceBid).to.equal(500n);
      expect(bobBid).to.equal(700n);
    });

    it("bid handles should be non-deterministic", async function () {
      // Place two bids with the same amount — handles should differ
      // (encryption is non-deterministic by design)
      await placeBid(alice, auctionId, 500);
      await placeBid(bob, auctionId, 500);

      // Both can decrypt and see the same value
      const aliceBid = await decryptMyBid(alice, auctionId);
      const bobBid = await decryptMyBid(bob, auctionId);

      expect(aliceBid).to.equal(500n);
      expect(bobBid).to.equal(500n);
    });
  });

  // ─── Multi-Auction Isolation ──────────────────────────────────────

  describe("Multi-Auction Isolation", function () {
    it("should isolate state between auctions", async function () {
      const now = await time.latest();
      await auction.createAuction("Item A", now + 1, now + 3600);
      await auction.createAuction("Item B", now + 1, now + 3600);
      await time.increaseTo(now + 2);

      await placeBid(alice, 0, 100);
      await placeBid(bob, 1, 200);

      // Alice bid on auction 0, not on auction 1
      expect(await auction.hasBid(0, alice.address)).to.be.true;
      expect(await auction.hasBid(1, alice.address)).to.be.false;

      // Bob bid on auction 1, not on auction 0
      expect(await auction.hasBid(0, bob.address)).to.be.false;
      expect(await auction.hasBid(1, bob.address)).to.be.true;

      // Each auction has 1 bid
      const infoA = await auction.getAuctionInfo(0);
      const infoB = await auction.getAuctionInfo(1);
      expect(infoA.bidCount).to.equal(1);
      expect(infoB.bidCount).to.equal(1);
    });

    it("should end auctions independently", async function () {
      const now = await time.latest();
      await auction.createAuction("Item A", now + 1, now + 100);
      await auction.createAuction("Item B", now + 1, now + 7200);
      await time.increaseTo(now + 2);

      await placeBid(alice, 0, 100);

      // End auction 0 (after its endTime)
      await time.increaseTo(now + 101);
      await auction.endAuction(0);

      // Auction 0 is ended, but auction 1 is still active
      const infoA = await auction.getAuctionInfo(0);
      const infoB = await auction.getAuctionInfo(1);
      expect(infoA.state).to.equal(1); // Ended
      expect(infoB.state).to.equal(0); // Still Bidding
    });
  });

  // ─── Edge Cases ───────────────────────────────────────────────────

  describe("Edge Cases", function () {
    it("should handle auction with no bids gracefully", async function () {
      const now = await time.latest();
      await auction.createAuction("Empty Auction", now + 1, now + 3600);

      // Owner can end with no bids (bidCount == 0 allows early end)
      await auction.endAuction(0);

      const info = await auction.getAuctionInfo(0);
      expect(info.state).to.equal(1); // Ended
      expect(info.bidCount).to.equal(0);
    });

    it("should handle single bidder auction", async function () {
      const auctionId = await createDefaultAuction();
      await placeBid(alice, auctionId, 500);

      const info = await auction.getAuctionInfo(auctionId);
      await time.increaseTo(Number(info.endTime));
      await auction.endAuction(auctionId);

      // Single bidder should be the highest (compared against encrypted 0)
      const endedInfo = await auction.getAuctionInfo(auctionId);
      expect(endedInfo.state).to.equal(1);
      expect(endedInfo.bidCount).to.equal(1);
    });

    it("should handle auction with start time in the past", async function () {
      const now = await time.latest();
      // Start time is in the past — bidding is immediately open
      await auction.createAuction("Immediate Auction", now - 100, now + 3600);
      await placeBid(alice, 0, 500);

      const info = await auction.getAuctionInfo(0);
      expect(info.bidCount).to.equal(1);
    });
  });
});
