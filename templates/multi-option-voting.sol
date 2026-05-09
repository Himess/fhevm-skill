// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint8, euint64, ebool, externalEuint8, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MultiOptionVoting — N-bucket token-weighted DAO vote (3 ≤ N ≤ 5)
/// @notice Each voter encrypts ONE choice id (0..N-1) plus a weight, all in a single proof.
///         The contract pulls `weight` from the voter's confidential governance-token
///         balance and routes it to the matching tally bucket via an `FHE.eq + FHE.select`
///         chain. Each address can vote only once. After the deadline, the N tallies become
///         publicly decryptable; `revealTallies` then verifies the KMS proof and stores
///         plaintext per-bucket totals.
/// @dev Out-of-range choice ids (>= N) silently route the weight to NO bucket — the eq
///      chain matches no entry, so every `FHE.select` keeps the previous tally. This is
///      intentional: rejecting a bad choiceId would leak information about an encrypted
///      input.
contract MultiOptionVoting is ZamaEthereumConfig, Ownable2Step {
    // ─── Types ─────────────────────────────────────────────────────────
    enum VoteState { Active, Ended, Revealed }

    // ─── Config ────────────────────────────────────────────────────────
    IERC7984 public immutable govToken;
    string[] public choices;
    uint256 public immutable endTime;

    // ─── State ─────────────────────────────────────────────────────────
    VoteState public state;
    /// @notice Encrypted per-bucket tallies. `_tallies[i]` accumulates weights of
    ///         voters whose encrypted choice equalled `i`.
    euint64[] private _tallies;
    /// @notice Plaintext tallies populated by `revealTallies`. Same length as `choices`.
    uint64[] public revealedTallies;
    mapping(address => bool) public hasVoted;
    uint256 public voteCount;

    // ─── Events ────────────────────────────────────────────────────────
    event VoteCast(address indexed voter);
    event VoteEnded(bytes32[] tallyHandles);
    event TalliesRevealed(uint64[] tallies);

    // ─── Errors ────────────────────────────────────────────────────────
    error InvalidChoiceCount(uint256 given);
    error VoteNotActive();
    error VoteStillActive();
    error AlreadyVoted();
    error NotRevealed();
    error InvalidProofArity();

    // ─── Constructor ───────────────────────────────────────────────────
    constructor(
        address govToken_,
        string[] memory choices_,
        uint256 durationSeconds
    ) Ownable(msg.sender) {
        uint256 n = choices_.length;
        if (n < 3 || n > 5) revert InvalidChoiceCount(n);

        govToken = IERC7984(govToken_);
        choices = choices_;
        endTime = block.timestamp + durationSeconds;
        state = VoteState.Active;
        revealedTallies = new uint64[](n);

        // Initialize all N tallies as encrypted zero. Each handle gets allowThis +
        // contract self-access; voters don't need ACL on tallies (they decrypt nothing
        // about the running total during voting).
        for (uint256 i = 0; i < n; i++) {
            euint64 zero = FHE.asEuint64(0);
            FHE.allowThis(zero);
            _tallies.push(zero);
        }
    }

    // ─── numChoices view (frontend can't read string[].length via auto-getter) ───
    function numChoices() external view returns (uint256) { return choices.length; }

    // ─── Cast Vote ─────────────────────────────────────────────────────
    /// @notice Cast an encrypted weighted vote. Single proof covers BOTH `encChoiceId`
    ///         and `encWeight`. Caller must have `setOperator(address(this), expiry)`
    ///         on `govToken` first so this contract can pull `weight`.
    /// @param encChoiceId Encrypted euint8 — voter's chosen index in [0, N).
    /// @param encWeight   Encrypted euint64 — number of vote tokens to commit.
    /// @param inputProof  ZK proof bound to msg.sender. SAME proof for both inputs.
    function castVote(
        externalEuint8 encChoiceId,
        externalEuint64 encWeight,
        bytes calldata inputProof
    ) external {
        if (state != VoteState.Active) revert VoteNotActive();
        if (block.timestamp >= endTime) revert VoteNotActive();
        if (hasVoted[msg.sender]) revert AlreadyVoted();
        hasVoted[msg.sender] = true;
        voteCount++;

        // 1. Validate both encrypted inputs against the SAME proof.
        euint8  choiceId = FHE.fromExternal(encChoiceId, inputProof);
        euint64 weight   = FHE.fromExternal(encWeight,   inputProof);

        // 2. Pull `weight` cGOV tokens from the voter into this contract.
        //    Order matters: allowTransient grants the token contract permission
        //    to read `weight` for its internal FHE math.
        FHE.allowTransient(weight, address(govToken));
        // The returned handle is the actual transferred amount (silent 0 on insufficient balance).
        euint64 transferred = govToken.confidentialTransferFrom(
            msg.sender,
            address(this),
            weight
        );

        // 3. Route the transferred weight to the matching tally bucket.
        //    For each i in [0, N): if choiceId == i, add transferred to _tallies[i].
        //    Otherwise add zero (no-op). The eq chain leaks NOTHING — every iteration
        //    runs identically regardless of the encrypted choiceId value.
        euint64 zero = FHE.asEuint64(0);
        FHE.allowThis(zero);
        uint256 n = _tallies.length;
        for (uint256 i = 0; i < n; i++) {
            ebool   matches  = FHE.eq(choiceId, FHE.asEuint8(uint8(i)));
            euint64 delta    = FHE.select(matches, transferred, zero);
            _tallies[i]      = FHE.add(_tallies[i], delta);
            FHE.allowThis(_tallies[i]);
        }

        emit VoteCast(msg.sender);
    }

    // ─── End Vote ──────────────────────────────────────────────────────
    /// @notice Ends voting and marks every tally publicly decryptable.
    function endVote() external {
        if (state != VoteState.Active) revert VoteNotActive();
        if (block.timestamp < endTime) revert VoteStillActive();

        state = VoteState.Ended;
        uint256 n = _tallies.length;
        bytes32[] memory tallyHandles = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            FHE.makePubliclyDecryptable(_tallies[i]);
            tallyHandles[i] = FHE.toBytes32(_tallies[i]);
        }
        emit VoteEnded(tallyHandles);
    }

    // ─── Reveal Tallies ────────────────────────────────────────────────
    /// @notice Anyone calls this with the KMS-signed cleartexts. Stores plaintext per-bucket totals.
    /// @dev Cleartexts are packed back-to-back as N × 32-byte uint256 words.
    ///      We use a fixed-max decode (≤ 5) since N is enforced by the constructor.
    function revealTallies(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        if (state != VoteState.Ended) revert VoteNotActive();
        uint256 n = _tallies.length;
        if (abiEncodedCleartexts.length != n * 32) revert InvalidProofArity();

        // Build handles array in the SAME order as endVote / makePubliclyDecryptable.
        bytes32[] memory handlesList = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            handlesList[i] = FHE.toBytes32(_tallies[i]);
        }
        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // Fixed-max decode: N is bounded to [3, 5]. Decode 5 slots, use first n.
        // Pad the input to 5×32 bytes if needed by the constructor enforcement.
        // Simpler: decode incrementally via calldataload (no length prefix in static tuple).
        for (uint256 i = 0; i < n; i++) {
            uint256 raw;
            assembly {
                let off := add(abiEncodedCleartexts.offset, mul(i, 32))
                raw := calldataload(off)
            }
            revealedTallies[i] = uint64(raw);
        }

        state = VoteState.Revealed;
        emit TalliesRevealed(revealedTallies);
    }

    // ─── Winning Choice ────────────────────────────────────────────────
    /// @notice Returns the index + vote count of the winning choice.
    /// @dev Tie-breaking: returns the LOWEST index that ties for the maximum.
    function winningChoice() external view returns (uint8 idx, uint64 votes) {
        if (state != VoteState.Revealed) revert NotRevealed();
        uint256 n = revealedTallies.length;
        votes = revealedTallies[0];
        idx = 0;
        for (uint256 i = 1; i < n; i++) {
            if (revealedTallies[i] > votes) {
                votes = revealedTallies[i];
                idx = uint8(i);
            }
        }
    }

    // ─── Public handle views (so frontend can call publicDecrypt unambiguously) ──
    function tallyHandle(uint256 i) external view returns (bytes32) {
        return FHE.toBytes32(_tallies[i]);
    }
}
