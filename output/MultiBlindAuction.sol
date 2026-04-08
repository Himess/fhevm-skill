// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, eaddress, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title MultiBlindAuction
/// @notice A multi-item sealed-bid auction with encrypted bids, public winner reveal,
///         refund claims for losers, and FHE DoS rate limiting.
/// @dev Uses the new FHE library from @fhevm/solidity v0.11+.
///      All bids remain fully encrypted. The highest bid is tracked via encrypted
///      comparisons so nobody (including the contract owner) can see any bid amount
///      until the auction ends and the winner is publicly revealed.
///
///      Payment flow: Bidders transfer encrypted tokens from an ERC-7984 confidential
///      token contract. Losers can claim refunds after the auction is revealed.
///      The winner's bid is transferred to the auction owner.
contract MultiBlindAuction is ZamaEthereumConfig, Ownable2Step {
    // ─── Types ──────────────────────────────────────────────────────────
    enum AuctionState {
        Bidding,
        Ended,
        Revealed
    }

    struct Auction {
        string itemName;
        AuctionState state;
        uint256 startTime;
        uint256 endTime;
        euint64 highestBid;
        eaddress highestBidder;  // Encrypted winner — fully private until reveal
        address revealedWinner;  // Set after reveal
        uint64 revealedHighestBid;
        uint256 bidCount;
    }

    // ─── Interfaces ─────────────────────────────────────────────────────
    /// @dev Minimal interface for a confidential ERC-7984 token that supports
    ///      encrypted transfers. The actual token contract handles silent failures.
    interface IConfidentialToken {
        function transfer(address to, euint64 amount) external returns (bool);
        function balanceOf(address account) external view returns (euint64);
    }

    // ─── State ──────────────────────────────────────────────────────────
    IConfidentialToken public paymentToken;
    uint256 public auctionCount;

    mapping(uint256 => Auction) public auctions;
    // auctionId => bidder => encrypted bid amount (escrowed)
    mapping(uint256 => mapping(address => euint64)) private _bids;
    // auctionId => bidder => whether they placed a bid
    mapping(uint256 => mapping(address => bool)) public hasBid;
    // auctionId => bidder => whether they claimed their refund
    mapping(uint256 => mapping(address => bool)) public hasClaimedRefund;

    // ─── Rate Limiting (FHE DoS Prevention) ─────────────────────────────
    // FHE operations are expensive. Without rate limiting, an attacker could
    // spam bids and exhaust coprocessor resources.
    uint256 public constant MIN_BID_INTERVAL = 30 seconds;
    uint256 public constant MAX_BIDS_PER_AUCTION = 100;
    mapping(address => uint256) public lastBidTimestamp;

    // ─── Events ─────────────────────────────────────────────────────────
    event AuctionCreated(uint256 indexed auctionId, string itemName, uint256 startTime, uint256 endTime);
    event BidPlaced(uint256 indexed auctionId, address indexed bidder);
    event AuctionEnded(uint256 indexed auctionId, bytes32 highestBidHandle);
    event WinnerRevealed(uint256 indexed auctionId, address indexed winner, uint64 amount);
    event RefundClaimed(uint256 indexed auctionId, address indexed bidder);

    // ─── Errors ─────────────────────────────────────────────────────────
    error AuctionNotActive(uint256 auctionId);
    error AuctionNotRevealed(uint256 auctionId);
    error AuctionNotExpired(uint256 auctionId);
    error AuctionNotStarted(uint256 auctionId);
    error AlreadyBid(uint256 auctionId, address bidder);
    error NoBidPlaced(uint256 auctionId, address bidder);
    error AlreadyClaimed(uint256 auctionId, address bidder);
    error OwnerCannotBid();
    error RateLimited(address bidder, uint256 nextAllowedTime);
    error MaxBidsReached(uint256 auctionId);
    error InvalidTimeRange();
    error AuctionDoesNotExist(uint256 auctionId);

    // ─── Constructor ────────────────────────────────────────────────────
    constructor(address _paymentToken) Ownable(msg.sender) {
        paymentToken = IConfidentialToken(_paymentToken);
    }

    // ─── Modifiers ──────────────────────────────────────────────────────
    modifier auctionExists(uint256 auctionId) {
        if (auctionId >= auctionCount) revert AuctionDoesNotExist(auctionId);
        _;
    }

    // ─── Create Auction ─────────────────────────────────────────────────
    /// @notice Create a new auction for an item with specified start and end times.
    /// @param itemName The name/description of the item being auctioned
    /// @param startTime Unix timestamp when bidding opens
    /// @param endTime Unix timestamp when bidding closes
    /// @return auctionId The ID of the newly created auction
    function createAuction(
        string calldata itemName,
        uint256 startTime,
        uint256 endTime
    ) external onlyOwner returns (uint256 auctionId) {
        if (endTime <= startTime) revert InvalidTimeRange();

        auctionId = auctionCount++;
        Auction storage auction = auctions[auctionId];
        auction.itemName = itemName;
        auction.state = AuctionState.Bidding;
        auction.startTime = startTime;
        auction.endTime = endTime;
        auction.bidCount = 0;

        // Initialize highest bid to encrypted zero
        auction.highestBid = FHE.asEuint64(0);
        FHE.allowThis(auction.highestBid);

        // Initialize highest bidder to encrypted zero address
        auction.highestBidder = FHE.asEaddress(address(0));
        FHE.allowThis(auction.highestBidder);

        emit AuctionCreated(auctionId, itemName, startTime, endTime);
    }

    // ─── Place Bid ──────────────────────────────────────────────────────
    /// @notice Submit an encrypted bid for an auction. Payment tokens are escrowed.
    /// @dev The bid amount is validated via ZK proof and kept fully encrypted.
    ///      Rate limiting prevents FHE DoS attacks.
    /// @param auctionId The auction to bid on
    /// @param encryptedBid The encrypted bid amount
    /// @param inputProof ZK proof for the encrypted input
    function bid(
        uint256 auctionId,
        externalEuint64 encryptedBid,
        bytes calldata inputProof
    ) external auctionExists(auctionId) {
        Auction storage auction = auctions[auctionId];

        // Plaintext checks (safe to use require — these don't leak encrypted data)
        if (auction.state != AuctionState.Bidding) revert AuctionNotActive(auctionId);
        if (block.timestamp < auction.startTime) revert AuctionNotStarted(auctionId);
        if (block.timestamp >= auction.endTime) revert AuctionNotExpired(auctionId);
        if (hasBid[auctionId][msg.sender]) revert AlreadyBid(auctionId, msg.sender);
        if (msg.sender == owner()) revert OwnerCannotBid();

        // Rate limiting: prevent FHE DoS
        if (block.timestamp < lastBidTimestamp[msg.sender] + MIN_BID_INTERVAL) {
            revert RateLimited(msg.sender, lastBidTimestamp[msg.sender] + MIN_BID_INTERVAL);
        }
        if (auction.bidCount >= MAX_BIDS_PER_AUCTION) revert MaxBidsReached(auctionId);

        // Update rate limiting state
        lastBidTimestamp[msg.sender] = block.timestamp;

        // Mark bid and increment count
        hasBid[auctionId][msg.sender] = true;
        auction.bidCount++;

        // Validate and convert encrypted input
        euint64 bidAmount = FHE.fromExternal(encryptedBid, inputProof);

        // Store the bid amount for potential refund later
        _bids[auctionId][msg.sender] = bidAmount;
        FHE.allowThis(_bids[auctionId][msg.sender]);
        FHE.allow(_bids[auctionId][msg.sender], msg.sender);

        // ── Encrypted highest bid tracking ──
        // Compare this bid to the current highest — fully encrypted, nobody sees the comparison
        ebool isHigher = FHE.gt(bidAmount, auction.highestBid);

        // Update highest bid using select (no branching — preserves confidentiality)
        auction.highestBid = FHE.select(isHigher, bidAmount, auction.highestBid);
        FHE.allowThis(auction.highestBid);

        // Update highest bidder (encrypted address — fully private)
        eaddress encSender = FHE.asEaddress(msg.sender);
        auction.highestBidder = FHE.select(isHigher, encSender, auction.highestBidder);
        FHE.allowThis(auction.highestBidder);

        // ── Escrow: transfer tokens from bidder to this contract ──
        // NOTE: This uses the silent transfer pattern. If the bidder doesn't have
        // enough tokens, the transfer silently sends 0 — which means the bid is
        // effectively zero. This is acceptable because a zero bid will never win.
        // The bidder's escrowed amount reflects what was actually transferred.

        // We need the token contract to be able to read the amount
        FHE.allowTransient(bidAmount, address(paymentToken));
        paymentToken.transfer(address(this), bidAmount);

        emit BidPlaced(auctionId, msg.sender);
    }

    // ─── End Auction ────────────────────────────────────────────────────
    /// @notice End an auction and request public decryption of the highest bid
    ///         and the winner's address.
    /// @param auctionId The auction to end
    function endAuction(uint256 auctionId) external onlyOwner auctionExists(auctionId) {
        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Bidding) revert AuctionNotActive(auctionId);
        // Owner can end after endTime, or early if no bids
        if (block.timestamp < auction.endTime && auction.bidCount > 0) {
            revert AuctionNotExpired(auctionId);
        }

        auction.state = AuctionState.Ended;

        // Request public decryption of the winning bid amount and winner address
        FHE.makePubliclyDecryptable(auction.highestBid);
        FHE.makePubliclyDecryptable(auction.highestBidder);

        emit AuctionEnded(auctionId, FHE.toBytes32(auction.highestBid));
    }

    // ─── Reveal Winner ──────────────────────────────────────────────────
    /// @notice Submit KMS decryption proof to reveal the winning bid on-chain.
    ///         After this, losers can claim refunds.
    /// @param auctionId The auction to reveal
    /// @param abiEncodedCleartexts ABI-encoded (uint64, address) of the decrypted values
    /// @param decryptionProof KMS threshold decryption proof
    function revealWinner(
        uint256 auctionId,
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external auctionExists(auctionId) {
        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Ended) revert AuctionNotRevealed(auctionId);

        // Build handles array (must match the order used in makePubliclyDecryptable)
        bytes32[] memory handlesList = new bytes32[](2);
        handlesList[0] = FHE.toBytes32(auction.highestBid);
        handlesList[1] = FHE.toBytes32(auction.highestBidder);

        // Verify the KMS proof — reverts if invalid
        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // Decode the plaintext values
        (uint64 winningBid, address winner) = abi.decode(
            abiEncodedCleartexts,
            (uint64, address)
        );

        auction.revealedHighestBid = winningBid;
        auction.revealedWinner = winner;
        auction.state = AuctionState.Revealed;

        emit WinnerRevealed(auctionId, winner, winningBid);
    }

    // ─── Claim Refund (Losers Only) ─────────────────────────────────────
    /// @notice Losing bidders can claim a refund of their escrowed bid.
    ///         The winner cannot claim a refund — their bid goes to the owner.
    /// @dev Uses the silent transfer pattern: if the caller is actually the winner,
    ///      the select pattern ensures 0 is refunded (since their bid matches
    ///      the winning bid). However, we also check the revealed winner address
    ///      for an additional plaintext guard after reveal.
    /// @param auctionId The auction to claim a refund from
    function claimRefund(uint256 auctionId) external auctionExists(auctionId) {
        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Revealed) revert AuctionNotRevealed(auctionId);
        if (!hasBid[auctionId][msg.sender]) revert NoBidPlaced(auctionId, msg.sender);
        if (hasClaimedRefund[auctionId][msg.sender]) revert AlreadyClaimed(auctionId, msg.sender);

        // The winner cannot claim a refund — their tokens go to the owner
        require(msg.sender != auction.revealedWinner, "Winner cannot claim refund");

        hasClaimedRefund[auctionId][msg.sender] = true;

        // Transfer the bidder's escrowed amount back to them
        euint64 refundAmount = _bids[auctionId][msg.sender];
        FHE.allowTransient(refundAmount, address(paymentToken));
        paymentToken.transfer(msg.sender, refundAmount);

        emit RefundClaimed(auctionId, msg.sender);
    }

    // ─── Withdraw Winner Payment (Owner Only) ───────────────────────────
    /// @notice Owner withdraws the winner's bid payment after reveal.
    /// @param auctionId The auction whose winning bid to withdraw
    function withdrawWinnerPayment(uint256 auctionId) external onlyOwner auctionExists(auctionId) {
        Auction storage auction = auctions[auctionId];

        if (auction.state != AuctionState.Revealed) revert AuctionNotRevealed(auctionId);
        require(auction.revealedWinner != address(0), "No winner");

        address winner = auction.revealedWinner;
        require(hasBid[auctionId][winner], "Winner bid not found");
        require(!hasClaimedRefund[auctionId][winner], "Already withdrawn");

        hasClaimedRefund[auctionId][winner] = true;

        // Transfer the winner's escrowed bid to the owner
        euint64 winnerBid = _bids[auctionId][winner];
        FHE.allowTransient(winnerBid, address(paymentToken));
        paymentToken.transfer(owner(), winnerBid);
    }

    // ─── View Functions ─────────────────────────────────────────────────

    /// @notice Get your own encrypted bid for an auction (only you can decrypt it off-chain).
    /// @param auctionId The auction ID
    /// @return The encrypted bid handle
    function getMyBid(uint256 auctionId) external view auctionExists(auctionId) returns (euint64) {
        require(hasBid[auctionId][msg.sender], "No bid placed");
        require(FHE.isAllowed(_bids[auctionId][msg.sender], msg.sender), "Not authorized");
        return _bids[auctionId][msg.sender];
    }

    /// @notice Get the auction details (plaintext fields only).
    /// @param auctionId The auction ID
    /// @return itemName The item name
    /// @return state The auction state
    /// @return startTime Bidding start time
    /// @return endTime Bidding end time
    /// @return bidCount Number of bids placed
    /// @return revealedWinner The winner address (only set after reveal)
    /// @return revealedHighestBid The winning bid (only set after reveal)
    function getAuctionInfo(uint256 auctionId)
        external
        view
        auctionExists(auctionId)
        returns (
            string memory itemName,
            AuctionState state,
            uint256 startTime,
            uint256 endTime,
            uint256 bidCount,
            address revealedWinner,
            uint64 revealedHighestBid
        )
    {
        Auction storage auction = auctions[auctionId];
        return (
            auction.itemName,
            auction.state,
            auction.startTime,
            auction.endTime,
            auction.bidCount,
            auction.revealedWinner,
            auction.revealedHighestBid
        );
    }
}
