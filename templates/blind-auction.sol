// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, eaddress, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
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
    /// @notice Encrypted address of the actual highest bidder. Updated atomically
    ///         with `_highestBid` via `FHE.select`. Decryptable only after `endAuction`
    ///         marks it publicly decryptable, so the leader stays hidden during bidding.
    eaddress private _highestBidder;
    /// @notice Plaintext address of the highest bidder, populated by `revealWinner`.
    ///         Until `revealWinner` runs, this stays at `address(0)`.
    address public revealedHighestBidder;
    uint256 public bidCount;

    mapping(address => euint64) private _bids;
    mapping(address => bool) public hasBid;
    mapping(address => bool) public hasClaimed;

    // Revealed result
    uint64 public revealedHighestBid;

    // ─── Events ─────────────────────────────────────────────────────────
    event BidPlaced(address indexed bidder);
    event AuctionEnded(bytes32 highestBidHandle, bytes32 highestBidderHandle);
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

        _highestBidder = FHE.asEaddress(address(0));
        FHE.allowThis(_highestBidder);
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

        // Update highest bid AND highest bidder atomically — both stay encrypted.
        // FHE.select keeps the previous values when isHigher is false, so this
        // is leakage-free: validators cannot tell whether the new bid won.
        _highestBid = FHE.select(isHigher, bidAmount, _highestBid);
        FHE.allowThis(_highestBid);

        _highestBidder = FHE.select(
            isHigher,
            FHE.asEaddress(msg.sender),
            _highestBidder
        );
        FHE.allowThis(_highestBidder);

        emit BidPlaced(msg.sender);
    }

    // ─── End Auction ────────────────────────────────────────────────────
    /// @notice End the auction and request public decryption of the winning bid + bidder.
    /// @dev Both the encrypted amount AND the encrypted bidder address are revealed.
    function endAuction() external onlyOwner {
        require(state == AuctionState.Bidding, "Auction not active");
        require(block.timestamp >= endTime || bidCount == 0, "Auction not expired");

        state = AuctionState.Ended;

        FHE.makePubliclyDecryptable(_highestBid);
        FHE.makePubliclyDecryptable(_highestBidder);

        emit AuctionEnded(FHE.toBytes32(_highestBid), FHE.toBytes32(_highestBidder));
    }

    // ─── Public Handle Views (for off-chain publicDecrypt) ─────────────
    function highestBidHandle() external view returns (bytes32) { return FHE.toBytes32(_highestBid); }
    function highestBidderHandle() external view returns (bytes32) { return FHE.toBytes32(_highestBidder); }

    // ─── Reveal Winner ──────────────────────────────────────────────────
    /// @notice Submit KMS decryption proof to reveal both the winning bid AND the winning bidder.
    /// @dev Handles MUST be in the same order they were marked publicly decryptable in `endAuction`:
    ///      [0] = _highestBid (uint64), [1] = _highestBidder (address packed as uint256).
    function revealWinner(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        require(state == AuctionState.Ended, "Auction not ended");

        bytes32[] memory handlesList = new bytes32[](2);
        handlesList[0] = FHE.toBytes32(_highestBid);
        handlesList[1] = FHE.toBytes32(_highestBidder);

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // SDK encodes ALL cleartexts as uint256, regardless of source type.
        // - euint64 → uint64(uint256)
        // - eaddress → address(uint160(uint256))
        (uint256 winningBidRaw, uint256 winningBidderRaw) =
            abi.decode(abiEncodedCleartexts, (uint256, uint256));

        revealedHighestBid     = uint64(winningBidRaw);
        revealedHighestBidder  = address(uint160(winningBidderRaw));
        state                  = AuctionState.Revealed;

        emit WinnerRevealed(revealedHighestBidder, revealedHighestBid);
    }

    // ─── View Own Bid ───────────────────────────────────────────────────
    /// @notice Get your own encrypted bid (only you can decrypt it).
    function getMyBid() external view returns (euint64) {
        require(hasBid[msg.sender], "No bid placed");
        require(FHE.isAllowed(_bids[msg.sender], msg.sender), "Not authorized");
        return _bids[msg.sender];
    }
}
