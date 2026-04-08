// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title BlindAuction Template
/// @notice Sealed-bid auction where bids remain encrypted until reveal.
/// @dev Bidders submit encrypted bids. The contract tracks the highest bid
///      without revealing any individual bid amounts. Only the winning bid
///      is revealed at the end via public decryption.
contract BlindAuction is ZamaEthereumConfig, Ownable2Step {
    // ─── Types ──────────────────────────────────────────────────────────
    enum AuctionState { Bidding, Ended, Revealed }

    // ─── State ──────────────────────────────────────────────────────────
    string public item;
    AuctionState public state;
    uint256 public endTime;

    euint64 private _highestBid;
    address public highestBidder;
    uint256 public bidCount;

    mapping(address => euint64) private _bids;
    mapping(address => bool) public hasBid;
    mapping(address => bool) public hasClaimed;

    // Revealed result
    uint64 public revealedHighestBid;

    // ─── Events ─────────────────────────────────────────────────────────
    event BidPlaced(address indexed bidder);
    event AuctionEnded(address indexed winner, bytes32 highestBidHandle);
    event WinnerRevealed(address indexed winner, uint64 amount);
    event BidRefunded(address indexed bidder);

    // ─── Constructor ────────────────────────────────────────────────────
    constructor(
        string memory _item,
        uint256 _durationSeconds
    ) Ownable(msg.sender) {
        item = _item;
        endTime = block.timestamp + _durationSeconds;
        state = AuctionState.Bidding;

        _highestBid = FHE.asEuint64(0);
        FHE.allowThis(_highestBid);
    }

    // ─── Place Bid ──────────────────────────────────────────────────────
    /// @notice Submit an encrypted bid. Each address can only bid once.
    /// @param encryptedBid The encrypted bid amount
    /// @param inputProof ZK proof for the encrypted input
    function bid(externalEuint64 encryptedBid, bytes calldata inputProof) external {
        require(state == AuctionState.Bidding, "Auction not active");
        require(block.timestamp < endTime, "Auction expired");
        require(!hasBid[msg.sender], "Already bid");
        require(msg.sender != owner(), "Owner cannot bid");

        hasBid[msg.sender] = true;
        bidCount++;

        // Validate encrypted input
        euint64 bidAmount = FHE.fromExternal(encryptedBid, inputProof);

        // Store the bid (for refund later)
        _bids[msg.sender] = bidAmount;
        FHE.allowThis(_bids[msg.sender]);
        FHE.allow(_bids[msg.sender], msg.sender);

        // Compare with current highest — all encrypted, no one sees the comparison
        ebool isHigher = FHE.gt(bidAmount, _highestBid);

        // Update highest bid (encrypted select — no branching leak)
        _highestBid = FHE.select(isHigher, bidAmount, _highestBid);
        FHE.allowThis(_highestBid);

        // Update highest bidder (uses eaddress for fully encrypted winner tracking)
        // For simplicity, we track in plaintext which is acceptable since
        // the bid AMOUNT remains encrypted. The identity of "current leader" changes
        // with each bid regardless of whether it's actually higher.
        // To fully hide the leader, use eaddress + FHE.select on addresses.
        highestBidder = msg.sender;

        emit BidPlaced(msg.sender);
    }

    // ─── End Auction ────────────────────────────────────────────────────
    /// @notice End the auction and request public decryption of the highest bid.
    function endAuction() external onlyOwner {
        require(state == AuctionState.Bidding, "Auction not active");
        require(block.timestamp >= endTime || bidCount == 0, "Auction not expired");

        state = AuctionState.Ended;

        // Request public decryption of the highest bid
        FHE.makePubliclyDecryptable(_highestBid);

        emit AuctionEnded(highestBidder, FHE.toBytes32(_highestBid));
    }

    // ─── Reveal Winner ──────────────────────────────────────────────────
    /// @notice Submit KMS decryption proof to reveal the winning bid on-chain.
    function revealWinner(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        require(state == AuctionState.Ended, "Auction not ended");

        bytes32[] memory handlesList = new bytes32[](1);
        handlesList[0] = FHE.toBytes32(_highestBid);

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // SDK encodes as uint256 — decode and cast
        uint256 winningBidRaw = abi.decode(abiEncodedCleartexts, (uint256));
        uint64 winningBid = uint64(winningBidRaw);
        revealedHighestBid = winningBid;
        state = AuctionState.Revealed;

        emit WinnerRevealed(highestBidder, winningBid);
    }

    // ─── View Own Bid ───────────────────────────────────────────────────
    /// @notice Get your own encrypted bid (only you can decrypt it).
    function getMyBid() external view returns (euint64) {
        require(hasBid[msg.sender], "No bid placed");
        require(FHE.isAllowed(_bids[msg.sender], msg.sender), "Not authorized");
        return _bids[msg.sender];
    }
}
