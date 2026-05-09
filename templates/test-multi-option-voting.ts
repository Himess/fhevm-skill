// Test template for templates/multi-option-voting.sol
// Demonstrates: multi-input single-proof encryption, FHE.eq+select bucket router,
// dynamic-N publicDecrypt + checkSignatures, winningChoice tie-break.
//
// Pairs with an ERC-7984 governance token "GovToken" (mint with owner-only `mint(to, uint64)`).
// See templates/confidential-erc20.sol for the token shape.

import { ethers, fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";
import { expect } from "chai";
import type { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers";

describe("MultiOptionVoting", function () {
  let owner: HardhatEthersSigner;
  let alice: HardhatEthersSigner;
  let bob: HardhatEthersSigner;
  let carol: HardhatEthersSigner;
  let dave: HardhatEthersSigner;

  let token: any;        // GovToken (ERC-7984)
  let tokenAddr: string;
  let vote: any;         // MultiOptionVoting
  let voteAddr: string;

  const CHOICES = ["Option-A", "Option-B", "Option-C"];
  const DURATION = 3600;
  const FAR_FUTURE = 2n ** 47n;

  beforeEach(async function () {
    if (!fhevm.isMock) this.skip();
    [owner, alice, bob, carol, dave] = await ethers.getSigners();

    // Deploy ERC-7984 governance token (replace "GovToken" with your token contract name)
    const TokF = await ethers.getContractFactory("GovToken");
    token = await TokF.deploy(owner.address, "GovToken", "GOV", "https://x.io/g.json");
    await token.waitForDeployment();
    tokenAddr = await token.getAddress();

    // Deploy MultiOptionVoting (3 choices, 1-hour duration)
    const VoteF = await ethers.getContractFactory("MultiOptionVoting");
    vote = await VoteF.deploy(tokenAddr, CHOICES, DURATION);
    await vote.waitForDeployment();
    voteAddr = await vote.getAddress();

    // Fund voters with cGOV
    for (const v of [alice, bob, carol, dave]) {
      await token.mint(v.address, 10000n);
      await token.connect(v).setOperator(voteAddr, FAR_FUTURE);
    }
  });

  // Helper: encrypt (choiceId, weight) under a single proof and submit.
  async function castVote(
    voter: HardhatEthersSigner,
    choiceId: number,
    weight: bigint,
  ) {
    const enc = await fhevm
      .createEncryptedInput(voteAddr, voter.address)
      .add8(choiceId)
      .add64(weight)
      .encrypt();
    await vote.connect(voter).castVote(
      enc.handles[0],   // externalEuint8 choiceId
      enc.handles[1],   // externalEuint64 weight
      enc.inputProof,   // SAME proof for both
    );
  }

  describe("Constructor", function () {
    it("rejects fewer than 3 choices", async function () {
      const F = await ethers.getContractFactory("MultiOptionVoting");
      await expect(F.deploy(tokenAddr, ["solo"], DURATION))
        .to.be.revertedWithCustomError(F, "InvalidChoiceCount");
    });

    it("rejects more than 5 choices", async function () {
      const F = await ethers.getContractFactory("MultiOptionVoting");
      await expect(F.deploy(tokenAddr, ["a", "b", "c", "d", "e", "f"], DURATION))
        .to.be.revertedWithCustomError(F, "InvalidChoiceCount");
    });

    it("accepts exactly 5 choices", async function () {
      const F = await ethers.getContractFactory("MultiOptionVoting");
      const v = await F.deploy(tokenAddr, ["a", "b", "c", "d", "e"], DURATION);
      await v.waitForDeployment();
      expect(await v.numChoices()).to.equal(5n);
    });
  });

  describe("Voting + Tally Decryption", function () {
    it("aggregates weighted votes from 4 voters across 3 choices", async function () {
      // Expected per-bucket sums:  A=300, B=900, C=400
      await castVote(alice, 0, 100n);
      await castVote(bob,   1, 500n);
      await castVote(carol, 2, 400n);
      await castVote(dave,  1, 400n);

      // Advance past deadline + endVote
      await ethers.provider.send("evm_increaseTime", [DURATION + 1]);
      await ethers.provider.send("evm_mine", []);
      const endTx = await vote.endVote();
      const endRcpt = await endTx.wait();
      const ev = endRcpt.logs.find(
        (l: any) => l.fragment && l.fragment.name === "VoteEnded",
      );
      const tallyHandles: string[] = ev.args.tallyHandles;
      expect(tallyHandles.length).to.equal(3);

      // Off-chain publicDecrypt to get cleartexts + KMS proof
      const decrypted = await fhevm.publicDecrypt(tallyHandles);
      // ✅ Use .clearValues — NOT decrypted[handle]
      expect(decrypted.clearValues[tallyHandles[0]]).to.equal(100n);
      expect(decrypted.clearValues[tallyHandles[1]]).to.equal(900n);
      expect(decrypted.clearValues[tallyHandles[2]]).to.equal(400n);

      // Submit to contract
      await vote.revealTallies(
        decrypted.abiEncodedClearValues,
        decrypted.decryptionProof,
      );
      expect(await vote.revealedTallies(0)).to.equal(100n);
      expect(await vote.revealedTallies(1)).to.equal(900n);
      expect(await vote.revealedTallies(2)).to.equal(400n);

      // winningChoice: bucket 1 (Option-B) wins with 900
      const [idx, votes] = await vote.winningChoice();
      expect(idx).to.equal(1n);
      expect(votes).to.equal(900n);
    });

    it("reverts when same address votes twice", async function () {
      await castVote(alice, 0, 100n);
      await expect(castVote(alice, 1, 50n)).to.be.revertedWithCustomError(vote, "AlreadyVoted");
    });

    it("reverts when voting after endVote", async function () {
      await castVote(alice, 0, 100n);
      await ethers.provider.send("evm_increaseTime", [DURATION + 1]);
      await ethers.provider.send("evm_mine", []);
      await vote.endVote();
      await expect(castVote(bob, 1, 100n)).to.be.revertedWithCustomError(vote, "VoteNotActive");
    });

    it("out-of-range choice id silently routes weight nowhere", async function () {
      // Alice picks bucket 7 (invalid for N=3) with weight 999.
      // Eq chain matches NO bucket → all tallies get +0.
      await castVote(alice, 7, 999n);
      // Bob casts a legitimate vote so we can verify the only effect comes from bob.
      await castVote(bob, 1, 50n);

      await ethers.provider.send("evm_increaseTime", [DURATION + 1]);
      await ethers.provider.send("evm_mine", []);
      await vote.endVote();
      const handles = [
        await vote.tallyHandle(0),
        await vote.tallyHandle(1),
        await vote.tallyHandle(2),
      ];
      const decrypted = await fhevm.publicDecrypt(handles);
      expect(decrypted.clearValues[handles[0]]).to.equal(0n);
      expect(decrypted.clearValues[handles[1]]).to.equal(50n); // only bob's
      expect(decrypted.clearValues[handles[2]]).to.equal(0n);
    });

    it("a bucket that received zero votes reveals as 0", async function () {
      await castVote(alice, 0, 100n);
      // No votes for buckets 1 or 2.
      await ethers.provider.send("evm_increaseTime", [DURATION + 1]);
      await ethers.provider.send("evm_mine", []);
      await vote.endVote();
      const h2 = await vote.tallyHandle(2);
      const decrypted = await fhevm.publicDecrypt([h2]);
      expect(decrypted.clearValues[h2]).to.equal(0n);
    });
  });
});
