// Test suite for templates/vickrey-auction.sol — sealed-bid second-price auction.
// Uses @openzeppelin/confidential-contracts as the bid token (ERC-7984 minted to bidders).
//
// To run:
//   npx hardhat test test/test-vickrey-auction.ts
//
// You'll also need a small ERC-7984 token contract (BidToken) — either reuse
// templates/confidential-erc20.sol or write a minimal mintable token. The test
// below assumes a `BidToken` contract with `(address owner)` constructor and
// `mint(address, uint64)` that the deployer can call freely.

import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

const ONE_DAY = 24 * 60 * 60;
const INITIAL_MINT = 10_000n;

type Signers = {
  deployer: HardhatEthersSigner;
  seller: HardhatEthersSigner;
  alice: HardhatEthersSigner;
  bob: HardhatEthersSigner;
  carol: HardhatEthersSigner;
  dave: HardhatEthersSigner;
};

async function deployFixture() {
  const [deployer, seller, alice, bob, carol, dave] = await ethers.getSigners();

  // 1. Deploy bid token (ERC-7984). Replace constructor signature if yours differs.
  const tokenFactory = await ethers.getContractFactory("BidToken");
  const token = await tokenFactory.deploy(deployer.address);
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();

  // 2. Deploy Vickrey auction
  const auctionFactory = await ethers.getContractFactory("VickreyAuction");
  const auction = await auctionFactory.deploy(
    seller.address,
    tokenAddress,
    "Pixelated Hat #1",
    ONE_DAY,
  );
  await auction.waitForDeployment();
  const auctionAddress = await auction.getAddress();

  // 3. Fund bidders. mint(addr, uint64) — token-specific signature.
  for (const bidder of [alice, bob, carol, dave]) {
    const tx = await (token as any)
      .connect(deployer)
      .mint(bidder.address, INITIAL_MINT);
    await tx.wait();
  }

  // 4. Each bidder authorizes the auction as operator on the bid token.
  //    Use the chain's current block.timestamp — system time can drift away
  //    from on-chain time after several `evm_increaseTime` calls in a suite.
  const latestBlock = await ethers.provider.getBlock("latest");
  const expiry = (latestBlock!.timestamp) + 7 * ONE_DAY;
  for (const bidder of [alice, bob, carol, dave]) {
    const tx = await (token as any)
      .connect(bidder)
      .setOperator(auctionAddress, expiry);
    await tx.wait();
  }

  return { token, tokenAddress, auction, auctionAddress };
}

describe("VickreyAuction", function () {
  let token: any;
  let tokenAddress: string;
  let auction: any;
  let auctionAddress: string;
  let signers: Signers;

  before(async function () {
    const s = await ethers.getSigners();
    signers = {
      deployer: s[0],
      seller: s[1],
      alice: s[2],
      bob: s[3],
      carol: s[4],
      dave: s[5],
    };
  });

  beforeEach(async function () {
    if (!fhevm.isMock) this.skip();
    ({ token, tokenAddress, auction, auctionAddress } = await deployFixture());
  });

  // ─── Helpers ──────────────────────────────────────────────────────
  async function placeBid(bidder: HardhatEthersSigner, amount: number) {
    const encrypted = await fhevm
      .createEncryptedInput(auctionAddress, bidder.address)
      .add64(BigInt(amount))
      .encrypt();
    const tx = await auction
      .connect(bidder)
      .bid(encrypted.handles[0], encrypted.inputProof);
    await tx.wait();
  }

  async function decryptTokenBalance(user: HardhatEthersSigner): Promise<bigint> {
    const handle = await token.connect(user).confidentialBalanceOf(user.address);
    return fhevm.userDecryptEuint(FhevmType.euint64, handle, tokenAddress, user);
  }

  async function fastForwardPastEnd() {
    await ethers.provider.send("evm_increaseTime", [ONE_DAY + 1]);
    await ethers.provider.send("evm_mine", []);
  }

  async function endAndReveal() {
    await auction.connect(signers.seller).endAuction();
    const secondHandle = await auction.secondBidHandle();
    const winnerHandle = await auction.highestBidderHandle();
    const decrypted = await fhevm.publicDecrypt([secondHandle, winnerHandle]);
    await auction
      .connect(signers.deployer)
      .revealResults(decrypted.abiEncodedClearValues, decrypted.decryptionProof);
  }

  // ─── Construction ─────────────────────────────────────────────────
  it("rejects zero duration", async () => {
    const factory = await ethers.getContractFactory("VickreyAuction");
    await expect(
      factory.deploy(signers.seller.address, tokenAddress, "X", 0),
    ).to.be.revertedWithCustomError(factory, "ZeroDuration");
  });

  it("starts in Bidding state", async () => {
    expect(await auction.state()).to.equal(0); // Bidding
    expect(await auction.bidCount()).to.equal(0);
    expect(await auction.seller()).to.equal(signers.seller.address);
  });

  // ─── Bidding ──────────────────────────────────────────────────────
  it("accepts a bid and pulls tokens into escrow", async () => {
    await placeBid(signers.alice, 200);
    expect(await auction.bidCount()).to.equal(1);
    expect(await auction.hasBid(signers.alice.address)).to.equal(true);
    expect(await decryptTokenBalance(signers.alice)).to.equal(INITIAL_MINT - 200n);
  });

  it("rejects double-bid from the same bidder", async () => {
    await placeBid(signers.alice, 200);
    const enc2 = await fhevm
      .createEncryptedInput(auctionAddress, signers.alice.address)
      .add64(300n)
      .encrypt();
    await expect(
      auction.connect(signers.alice).bid(enc2.handles[0], enc2.inputProof),
    ).to.be.reverted;
  });

  it("rejects bids from the seller", async () => {
    // Seller has no tokens minted; even if they did, contract should revert
    const enc = await fhevm
      .createEncryptedInput(auctionAddress, signers.seller.address)
      .add64(100n)
      .encrypt();
    await expect(
      auction.connect(signers.seller).bid(enc.handles[0], enc.inputProof),
    ).to.be.reverted;
  });

  it("rejects bids after auction expires", async () => {
    await fastForwardPastEnd();
    const enc = await fhevm
      .createEncryptedInput(auctionAddress, signers.alice.address)
      .add64(100n)
      .encrypt();
    await expect(
      auction.connect(signers.alice).bid(enc.handles[0], enc.inputProof),
    ).to.be.reverted;
  });

  // ─── Top-2 tracking (the Vickrey heart) ───────────────────────────
  it("tracks the second-highest bid correctly across 4 bidders", async () => {
    // Bid order: 200, 500, 350, 100 → highest=500 (bob), second=350 (carol)
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 500);
    await placeBid(signers.carol, 350);
    await placeBid(signers.dave, 100);

    await fastForwardPastEnd();
    await endAndReveal();

    expect(await auction.revealedClearingPrice()).to.equal(350);
    expect(await auction.revealedWinner()).to.equal(signers.bob.address);
  });

  it("handles a single bidder (clearing price = 0)", async () => {
    await placeBid(signers.alice, 200);
    await fastForwardPastEnd();
    await endAndReveal();

    expect(await auction.revealedClearingPrice()).to.equal(0);
    expect(await auction.revealedWinner()).to.equal(signers.alice.address);
  });

  it("keeps the highest bid value confidential — only second-highest is revealed", async () => {
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 999);
    await placeBid(signers.carol, 500);
    await fastForwardPastEnd();
    await endAndReveal();

    // Clearing price (revealed) is 500; highest (999) stays encrypted.
    expect(await auction.revealedClearingPrice()).to.equal(500);
  });

  // ─── End / Reveal ─────────────────────────────────────────────────
  it("only seller can end the auction", async () => {
    await placeBid(signers.alice, 100);
    await fastForwardPastEnd();
    await expect(auction.connect(signers.alice).endAuction()).to.be.reverted;
  });

  it("cannot end before deadline if at least one bid was placed", async () => {
    await placeBid(signers.alice, 100);
    await expect(auction.connect(signers.seller).endAuction()).to.be.reverted;
  });

  it("can end early with zero bids", async () => {
    await auction.connect(signers.seller).endAuction();
    expect(await auction.state()).to.equal(1); // Ended
  });

  it("cannot reveal twice", async () => {
    await placeBid(signers.alice, 100);
    await placeBid(signers.bob, 200);
    await fastForwardPastEnd();
    await endAndReveal();
    await expect(
      auction.connect(signers.deployer).revealResults("0x", "0x"),
    ).to.be.reverted;
  });

  // ─── Settlement ───────────────────────────────────────────────────
  it("winner pays clearing price (Vickrey rule), refunds the rest", async () => {
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 500); // winner
    await placeBid(signers.carol, 350); // sets clearing price
    await placeBid(signers.dave, 100);

    await fastForwardPastEnd();
    await endAndReveal();

    expect(await decryptTokenBalance(signers.bob)).to.equal(INITIAL_MINT - 500n); // pre-refund
    await auction.connect(signers.bob).winnerSettle();
    // Bob escrowed 500, owes 350, refund = 150 → balance = 10000 - 350
    expect(await decryptTokenBalance(signers.bob)).to.equal(INITIAL_MINT - 350n);
    expect(await auction.state()).to.equal(3); // Settled
  });

  it("seller withdraws exactly the clearing price", async () => {
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 500);
    await placeBid(signers.carol, 350);

    await fastForwardPastEnd();
    await endAndReveal();
    await auction.connect(signers.bob).winnerSettle();
    await auction.connect(signers.seller).sellerWithdraw();

    expect(await decryptTokenBalance(signers.seller)).to.equal(350n);
    expect(await auction.sellerWithdrawn()).to.equal(true);
  });

  it("losers refund their full escrow", async () => {
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 500); // winner
    await placeBid(signers.carol, 350);
    await placeBid(signers.dave, 100);

    await fastForwardPastEnd();
    await endAndReveal();

    await auction.connect(signers.alice).loserRefund();
    await auction.connect(signers.carol).loserRefund();
    await auction.connect(signers.dave).loserRefund();

    expect(await decryptTokenBalance(signers.alice)).to.equal(INITIAL_MINT);
    expect(await decryptTokenBalance(signers.carol)).to.equal(INITIAL_MINT);
    expect(await decryptTokenBalance(signers.dave)).to.equal(INITIAL_MINT);
  });

  it("winner cannot also call loserRefund", async () => {
    await placeBid(signers.alice, 200);
    await placeBid(signers.bob, 500);
    await fastForwardPastEnd();
    await endAndReveal();

    await expect(auction.connect(signers.bob).loserRefund()).to.be.reverted;
  });

  it("non-bidders cannot refund", async () => {
    await placeBid(signers.alice, 100);
    await placeBid(signers.bob, 200);
    await fastForwardPastEnd();
    await endAndReveal();

    // signers.dave never bid
    await expect(auction.connect(signers.dave).loserRefund()).to.be.reverted;
  });

  it("sellerWithdraw is gated on Settled state", async () => {
    await placeBid(signers.alice, 100);
    await placeBid(signers.bob, 200);
    await fastForwardPastEnd();
    await endAndReveal();

    // No winnerSettle yet → state == Revealed, not Settled
    await expect(auction.connect(signers.seller).sellerWithdraw()).to.be.reverted;
  });

  it("sellerWithdraw cannot be called twice", async () => {
    await placeBid(signers.alice, 100);
    await placeBid(signers.bob, 200);
    await fastForwardPastEnd();
    await endAndReveal();
    await auction.connect(signers.bob).winnerSettle();
    await auction.connect(signers.seller).sellerWithdraw();

    await expect(auction.connect(signers.seller).sellerWithdraw()).to.be.reverted;
  });
});
