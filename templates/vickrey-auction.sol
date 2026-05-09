// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, eaddress, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

/// @title VickreyAuction Template
/// @notice Sealed-bid second-price auction. Winner pays the SECOND-highest bid.
///         All bids are encrypted; only the clearing price (second-highest) and
///         winner's address are revealed at settlement.
/// @dev Tracks the top-2 bids on every `bid()` call via chained FHE.gt + FHE.select.
///      Bid tokens are pulled into escrow on each bid (full bid amount), and the
///      winner gets a refund of (bid - clearingPrice) at settlement.
contract VickreyAuction is ZamaEthereumConfig {
    enum AuctionState { Bidding, Ended, Revealed, Settled }

    // ─── Immutable role (no Ownable surface — seller is fixed at deploy) ─
    address public immutable seller;
    IERC7984 public immutable bidToken;
    string public item;
    uint256 public immutable endTime;

    AuctionState public state;
    uint256 public bidCount;

    // Top-2 tracking (encrypted)
    euint64 private _highestBid;
    euint64 private _secondBid;        // ← Vickrey clearing price
    eaddress private _highestBidder;

    // Per-bidder state
    mapping(address => euint64) private _bids;
    mapping(address => bool)    public  hasBid;
    mapping(address => bool)    public  hasClaimed;

    // Revealed results (only second-highest + winner address are revealed)
    uint64  public revealedClearingPrice;   // = second-highest bid
    address public revealedWinner;
    bool    public sellerWithdrawn;

    // ─── Errors ─────────────────────────────────────────────────────────
    error NotSeller();
    error WrongState();
    error AuctionExpired();
    error AuctionNotExpired();
    error AlreadyBid();
    error SellerCannotBid();
    error NoBid();
    error AlreadyClaimed();
    error WinnerCannotRefund();
    error ZeroDuration();

    // ─── Events ─────────────────────────────────────────────────────────
    event BidPlaced(address indexed bidder);
    event AuctionEnded(bytes32 secondBidHandle, bytes32 winnerHandle);
    event WinnerRevealed(address indexed winner, uint64 clearingPrice);
    event WinnerSettled(address indexed winner, uint64 refundAmount);
    event SellerPaid(address indexed seller, uint64 amount);
    event LoserRefunded(address indexed bidder);

    // ─── Constructor ────────────────────────────────────────────────────
    constructor(
        address _seller,
        IERC7984 _bidToken,
        string memory _item,
        uint256 _durationSeconds
    ) {
        if (_durationSeconds == 0) revert ZeroDuration();
        seller   = _seller;
        bidToken = _bidToken;
        item     = _item;
        endTime  = block.timestamp + _durationSeconds;
        state    = AuctionState.Bidding;

        _highestBid    = FHE.asEuint64(0);
        _secondBid     = FHE.asEuint64(0);
        _highestBidder = FHE.asEaddress(address(0));
        FHE.allowThis(_highestBid);
        FHE.allowThis(_secondBid);
        FHE.allowThis(_highestBidder);
    }

    // ─── Place Bid ──────────────────────────────────────────────────────
    /// @notice Submit an encrypted bid. The full bid amount is escrowed in this contract.
    /// @dev User must first call `bidToken.setOperator(address(this), expiry)` so this
    ///      contract can pull tokens via `confidentialTransferFrom`.
    function bid(externalEuint64 encryptedBid, bytes calldata inputProof) external {
        if (state != AuctionState.Bidding) revert WrongState();
        if (block.timestamp >= endTime) revert AuctionExpired();
        if (hasBid[msg.sender]) revert AlreadyBid();
        if (msg.sender == seller) revert SellerCannotBid();

        hasBid[msg.sender] = true;
        bidCount++;

        // 1. Validate the encrypted input → contract gets ACL on the handle
        euint64 amount = FHE.fromExternal(encryptedBid, inputProof);

        // 2. Pull bid tokens into escrow (full bid)
        //    Recipe (erc7984-guide.md): allowTransient → confidentialTransferFrom → allowThis
        FHE.allowTransient(amount, address(bidToken));
        euint64 transferred = bidToken.confidentialTransferFrom(msg.sender, address(this), amount);
        FHE.allowThis(transferred);
        FHE.allow(transferred, msg.sender);
        _bids[msg.sender] = transferred;

        // 3. Top-2 update (chained gt+select). Order matters:
        //    when newBid wins first place, the new SECOND becomes the OLD FIRST,
        //    NOT a freshly-compared candidate. See common-pitfalls.md "Top-K".
        ebool isFirst  = FHE.gt(transferred, _highestBid);
        ebool isSecond = FHE.gt(transferred, _secondBid);

        // candidate-for-second when transferred is BETWEEN second and first
        euint64 secondCandidate = FHE.select(isSecond, transferred, _secondBid);
        // if transferred wins first, second = previous-first; otherwise secondCandidate
        _secondBid = FHE.select(isFirst, _highestBid, secondCandidate);
        FHE.allowThis(_secondBid);

        _highestBid = FHE.select(isFirst, transferred, _highestBid);
        FHE.allowThis(_highestBid);

        _highestBidder = FHE.select(
            isFirst,
            FHE.asEaddress(msg.sender),
            _highestBidder
        );
        FHE.allowThis(_highestBidder);

        emit BidPlaced(msg.sender);
    }

    // ─── End Auction ────────────────────────────────────────────────────
    /// @notice Mark the auction ended and request public decryption of the
    ///         CLEARING PRICE (second-highest) and WINNER address only. The
    ///         highest bid itself stays encrypted forever.
    function endAuction() external {
        if (msg.sender != seller) revert NotSeller();
        if (state != AuctionState.Bidding) revert WrongState();
        if (block.timestamp < endTime && bidCount > 0) revert AuctionNotExpired();

        state = AuctionState.Ended;

        // ⚠ Mixed-type 2-handle reveal: (euint64 secondBid, eaddress winner).
        //   Off-chain SDK encodes BOTH cleartexts as uint256 — see revealResults.
        FHE.makePubliclyDecryptable(_secondBid);
        FHE.makePubliclyDecryptable(_highestBidder);

        emit AuctionEnded(FHE.toBytes32(_secondBid), FHE.toBytes32(_highestBidder));
    }

    // ─── Reveal Winner ──────────────────────────────────────────────────
    /// @notice Submit KMS decryption proof to reveal (clearingPrice, winner).
    /// @dev Handles MUST be passed in the same order they were marked publicly
    ///      decryptable in `endAuction`:
    ///        [0] = _secondBid     (uint64  encoded as uint256)
    ///        [1] = _highestBidder (address encoded as uint256 via uint160)
    function revealResults(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        if (state != AuctionState.Ended) revert WrongState();

        bytes32[] memory handlesList = new bytes32[](2);
        handlesList[0] = FHE.toBytes32(_secondBid);
        handlesList[1] = FHE.toBytes32(_highestBidder);

        FHE.checkSignatures(handlesList, abiEncodedCleartexts, decryptionProof);

        // SDK encodes ALL cleartexts as uint256 regardless of source type:
        //   euint64    → uint64(uint256)
        //   eaddress   → address(uint160(uint256))
        (uint256 secondRaw, uint256 winnerRaw) =
            abi.decode(abiEncodedCleartexts, (uint256, uint256));

        revealedClearingPrice = uint64(secondRaw);
        revealedWinner        = address(uint160(winnerRaw));
        state                 = AuctionState.Revealed;

        emit WinnerRevealed(revealedWinner, revealedClearingPrice);
    }

    // ─── Winner Settlement (refund excess) ──────────────────────────────
    /// @notice Winner claims their refund (bid - clearingPrice) and flips the
    ///         auction to Settled so the seller can withdraw the clearing price.
    function winnerSettle() external {
        if (state != AuctionState.Revealed) revert WrongState();
        if (msg.sender != revealedWinner) revert NoBid();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        hasClaimed[msg.sender] = true;
        state = AuctionState.Settled;

        // Winner's escrow = their full bid; refund = bid - clearingPrice.
        //
        // Invariant: `_bids[winner] >= revealedClearingPrice`. The winner is the
        // top bidder (selected via chained FHE.gt in bid()), and clearingPrice =
        // second-highest bid by construction.
        //
        // FHE.sub uses MODULAR arithmetic — if the invariant ever broke (a
        // future regression in the top-2 ranking logic, or a malformed reveal),
        // a naked `FHE.sub` would silently underflow to a near-MAX_UINT64
        // refund and drain the contract.
        //
        // Defense-in-depth: gate the refund behind `bid >= clearingPrice`.
        // Under the invariant this is always true; if it ever fails, the
        // refund collapses to 0 instead of leaking the pool.
        euint64 winnerBid = _bids[msg.sender];
        ebool   ok        = FHE.ge(winnerBid, revealedClearingPrice);
        euint64 refund    = FHE.select(
            ok,
            FHE.sub(winnerBid, revealedClearingPrice),
            FHE.asEuint64(0)
        );
        FHE.allowThis(refund);
        FHE.allowTransient(refund, address(bidToken));
        bidToken.confidentialTransfer(msg.sender, refund);

        emit WinnerSettled(msg.sender, revealedClearingPrice);
    }

    // ─── Seller Withdrawal ──────────────────────────────────────────────
    /// @notice Seller withdraws the clearing price after settlement.
    function sellerWithdraw() external {
        if (msg.sender != seller) revert NotSeller();
        if (state != AuctionState.Settled) revert WrongState();
        if (sellerWithdrawn) revert AlreadyClaimed();

        sellerWithdrawn = true;

        // Pay seller exactly the clearing price (plaintext → encrypt → pay)
        euint64 payment = FHE.asEuint64(revealedClearingPrice);
        FHE.allowThis(payment);
        FHE.allowTransient(payment, address(bidToken));
        bidToken.confidentialTransfer(seller, payment);

        emit SellerPaid(seller, revealedClearingPrice);
    }

    // ─── Loser Refund ───────────────────────────────────────────────────
    /// @notice Non-winning bidders reclaim their full escrow after reveal.
    function loserRefund() external {
        if (state != AuctionState.Revealed && state != AuctionState.Settled) revert WrongState();
        if (!hasBid[msg.sender]) revert NoBid();
        if (msg.sender == revealedWinner) revert WinnerCannotRefund();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        hasClaimed[msg.sender] = true;

        euint64 refund = _bids[msg.sender];
        FHE.allowTransient(refund, address(bidToken));
        bidToken.confidentialTransfer(msg.sender, refund);

        emit LoserRefunded(msg.sender);
    }

    // ─── Public Handle Views (for off-chain publicDecrypt) ─────────────
    function secondBidHandle()      external view returns (bytes32) { return FHE.toBytes32(_secondBid); }
    function highestBidderHandle()  external view returns (bytes32) { return FHE.toBytes32(_highestBidder); }

    // ─── View Own Bid ───────────────────────────────────────────────────
    /// @notice Get your own encrypted bid (only you can decrypt it via Relayer SDK).
    /// @dev `FHE.allow(_, bidder)` was called in `bid()`, so no extra guard
    ///      is required — this function is defense-in-depth for callers that
    ///      lost their ACL through some external interaction.
    function getMyBid() external view returns (euint64) {
        if (!hasBid[msg.sender]) revert NoBid();
        return _bids[msg.sender];
    }
}
