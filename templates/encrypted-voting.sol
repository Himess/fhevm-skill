// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, externalEbool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title EncryptedVoting Template
/// @notice Confidential voting contract where votes remain encrypted until reveal.
/// @dev Voters submit encrypted boolean votes (yes/no). Tallies are encrypted.
///      Only the owner can end voting and trigger result reveal via public decryption.
contract EncryptedVoting is ZamaEthereumConfig, Ownable2Step {
    // ─── Types ──────────────────────────────────────────────────────────
    enum VotingState { Active, Ended, Revealed }

    // ─── State ──────────────────────────────────────────────────────────
    string public proposal;
    VotingState public state;
    uint256 public voteCount;

    euint64 private _yesVotes;
    euint64 private _noVotes;

    mapping(address => bool) public hasVoted;

    // Revealed results (populated after reveal)
    uint64 public revealedYes;
    uint64 public revealedNo;

    // ─── Events ─────────────────────────────────────────────────────────
    event VoteCast(address indexed voter);
    event VotingEnded(bytes32 yesHandle, bytes32 noHandle);
    event ResultRevealed(uint64 yes, uint64 no);

    // ─── Constructor ────────────────────────────────────────────────────
    constructor(string memory _proposal) Ownable(msg.sender) {
        proposal = _proposal;
        state = VotingState.Active;

        // Initialize encrypted tallies
        _yesVotes = FHE.asEuint64(0);
        FHE.allowThis(_yesVotes);

        _noVotes = FHE.asEuint64(0);
        FHE.allowThis(_noVotes);
    }

    // ─── Vote ───────────────────────────────────────────────────────────
    /// @notice Cast an encrypted vote. true = yes, false = no.
    /// @param encryptedVote The encrypted boolean vote
    /// @param inputProof ZK proof for the encrypted input
    function vote(externalEbool encryptedVote, bytes calldata inputProof) external {
        require(state == VotingState.Active, "Voting not active");
        require(!hasVoted[msg.sender], "Already voted");

        hasVoted[msg.sender] = true;
        voteCount++;

        // Validate and convert the encrypted input
        ebool voteChoice = FHE.fromExternal(encryptedVote, inputProof);

        // Convert bool to uint64: true → 1, false → 0
        euint64 voteAsYes = FHE.select(voteChoice, FHE.asEuint64(1), FHE.asEuint64(0));
        euint64 voteAsNo = FHE.select(voteChoice, FHE.asEuint64(0), FHE.asEuint64(1));

        // Tally (encrypted addition — nobody sees individual votes)
        _yesVotes = FHE.add(_yesVotes, voteAsYes);
        FHE.allowThis(_yesVotes);

        _noVotes = FHE.add(_noVotes, voteAsNo);
        FHE.allowThis(_noVotes);

        emit VoteCast(msg.sender);
    }

    // ─── End Voting ─────────────────────────────────────────────────────
    /// @notice End voting and request public decryption of results.
    function endVoting() external onlyOwner {
        require(state == VotingState.Active, "Voting not active");
        state = VotingState.Ended;

        // Mark tallies for public decryption
        FHE.makePubliclyDecryptable(_yesVotes);
        FHE.makePubliclyDecryptable(_noVotes);

        emit VotingEnded(
            FHE.toBytes32(_yesVotes),
            FHE.toBytes32(_noVotes)
        );
    }

    // ─── Reveal Results ─────────────────────────────────────────────────
    /// @notice Submit KMS decryption proof to reveal results on-chain.
    /// @param abiEncodedCleartexts ABI-encoded (uint64 yes, uint64 no)
    /// @param decryptionProof KMS signature proof
    function revealResults(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        require(state == VotingState.Ended, "Voting not ended");

        // Build handles array (must match order of makePubliclyDecryptable calls)
        bytes32[] memory handlesList = new bytes32[](2);
        handlesList[0] = FHE.toBytes32(_yesVotes);
        handlesList[1] = FHE.toBytes32(_noVotes);

        // Verify KMS proof — reverts if invalid
        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // SDK encodes all values as uint256 — decode and cast down
        (uint256 yesRaw, uint256 noRaw) = abi.decode(abiEncodedCleartexts, (uint256, uint256));
        revealedYes = uint64(yesRaw);
        revealedNo = uint64(noRaw);
        state = VotingState.Revealed;

        emit ResultRevealed(revealedYes, revealedNo);
    }

    // ─── View ───────────────────────────────────────────────────────────
    /// @notice Get the encrypted vote tallies (only accessible by owner).
    function getTallies() external view returns (euint64 yes, euint64 no) {
        require(FHE.isAllowed(_yesVotes, msg.sender), "Not authorized");
        return (_yesVotes, _noVotes);
    }
}
