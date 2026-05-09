// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
// Use the official IERC7984 interface from OpenZeppelin
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
// NOTE: IERC7984 provides confidentialTransfer, confidentialTransferFrom, setOperator, etc.

/// @title ConfidentialEscrow — FHE-encrypted escrow for ERC-7984 tokens
/// @notice Supports deposit, release, refund, and arbiter-based dispute resolution.
///         All amounts are encrypted — only involved parties can see escrow amounts.
///         Uses the ERC-7984 operator model (setOperator) for token permissions.
/// @dev The escrow holds tokens in its own ERC-7984 balance. Each escrow deal is tracked
///      via an incrementing ID. The arbiter is set per-deal at creation time.
contract ConfidentialEscrow is ZamaEthereumConfig {
    // ─── Types ─────────────────────────────────────────────────────────
    enum EscrowState {
        Active,
        Released,
        Refunded
    }

    struct Escrow {
        address buyer;
        address seller;
        address arbiter;
        euint64 amount; // encrypted escrow amount
        EscrowState state;
    }

    // ─── State ─────────────────────────────────────────────────────────
    IERC7984 public immutable token;
    uint256 public nextEscrowId;
    mapping(uint256 => Escrow) private escrows;

    // ─── Events ────────────────────────────────────────────────────────
    event EscrowCreated(uint256 indexed escrowId, address indexed buyer, address indexed seller, address arbiter);
    event EscrowReleased(uint256 indexed escrowId);
    event EscrowRefunded(uint256 indexed escrowId);
    event EscrowDisputed(uint256 indexed escrowId, address indexed decidedBy, address indexed recipient);

    // ─── Errors ────────────────────────────────────────────────────────
    error EscrowNotActive(uint256 escrowId);
    error NotBuyer(uint256 escrowId);
    error NotArbiter(uint256 escrowId);
    error InvalidAddress();

    // ─── Constructor ───────────────────────────────────────────────────
    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) revert InvalidAddress();
        token = IERC7984(tokenAddress);
    }

    // ─── Modifiers ─────────────────────────────────────────────────────
    modifier onlyActive(uint256 escrowId) {
        if (escrows[escrowId].state != EscrowState.Active) {
            revert EscrowNotActive(escrowId);
        }
        _;
    }

    modifier onlyBuyer(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].buyer) {
            revert NotBuyer(escrowId);
        }
        _;
    }

    modifier onlyArbiter(uint256 escrowId) {
        if (msg.sender != escrows[escrowId].arbiter) {
            revert NotArbiter(escrowId);
        }
        _;
    }

    // ─── Create Escrow (Buyer deposits) ────────────────────────────────
    /// @notice Buyer creates an escrow by depositing encrypted tokens for a seller.
    ///         Before calling, the buyer must: token.setOperator(escrowAddress, expiry)
    /// @param seller The seller who will receive tokens upon release
    /// @param arbiter A third party who can resolve disputes
    /// @param encAmount The encrypted token amount (external input from buyer)
    /// @param inputProof The ZK proof for the encrypted input
    /// @return escrowId The ID of the newly created escrow
    function createEscrow(
        address seller,
        address arbiter,
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external returns (uint256 escrowId) {
        if (seller == address(0) || arbiter == address(0)) revert InvalidAddress();

        // Validate the encrypted input — this gives the escrow contract ACL access
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        escrowId = nextEscrowId++;

        // ORDERING IS LOAD-BEARING: allowTransient MUST come BEFORE the call.
        //   - allowTransient grants the token contract permission to read this handle.
        //   - That permission is used inside the token's FHE math (sub from buyer, add to escrow).
        //   - Calling allowTransient AFTER confidentialTransferFrom would be too late —
        //     the token would have already failed with "Sender not allowed" inside _update.
        FHE.allowTransient(amount, address(token));

        // Transfer tokens from buyer to this escrow contract.
        // PRECONDITION: buyer must have called token.setOperator(address(this), expiry)
        //               in a separate transaction BEFORE calling createEscrow.
        euint64 transferred = token.confidentialTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Store the escrow with the actual transferred amount
        // (may be 0 if buyer had insufficient balance — silent failure by design)
        escrows[escrowId].buyer = msg.sender;
        escrows[escrowId].seller = seller;
        escrows[escrowId].arbiter = arbiter;
        escrows[escrowId].amount = transferred;
        escrows[escrowId].state = EscrowState.Active;

        // ACL: contract can access this amount in future transactions
        FHE.allowThis(transferred);
        // ACL: buyer can decrypt their own escrow amount any time
        FHE.allow(transferred, msg.sender);
        // NOTE: seller and arbiter intentionally do NOT receive ACL here.
        //       The seller learns the amount only on `release` (when funds
        //       transfer to them and the token contract grants them ACL on
        //       their balance). Pre-disclosure to the seller would violate
        //       the escrow's privacy contract — a buyer could learn that the
        //       seller has visibility into the escrow before any release
        //       decision, which is a leakage channel.

        emit EscrowCreated(escrowId, msg.sender, seller, arbiter);
    }

    // ─── Release (Buyer releases funds to seller) ──────────────────────
    /// @notice Buyer releases the escrowed tokens to the seller.
    function release(uint256 escrowId) external onlyActive(escrowId) onlyBuyer(escrowId) {
        _sendToRecipient(escrowId, escrows[escrowId].seller);
        escrows[escrowId].state = EscrowState.Released;
        emit EscrowReleased(escrowId);
    }

    // ─── Refund (Buyer requests refund) ────────────────────────────────
    /// @notice Buyer requests a refund, getting the escrowed tokens back.
    function refund(uint256 escrowId) external onlyActive(escrowId) onlyBuyer(escrowId) {
        _sendToRecipient(escrowId, escrows[escrowId].buyer);
        escrows[escrowId].state = EscrowState.Refunded;
        emit EscrowRefunded(escrowId);
    }

    // ─── Dispute Resolution (Arbiter decides) ──────────────────────────
    /// @notice Arbiter resolves a dispute by sending funds to either buyer or seller.
    /// @param escrowId The escrow to resolve
    /// @param sendToSeller If true, sends to seller. If false, sends to buyer.
    function resolveDispute(
        uint256 escrowId,
        bool sendToSeller
    ) external onlyActive(escrowId) onlyArbiter(escrowId) {
        address recipient = sendToSeller
            ? escrows[escrowId].seller
            : escrows[escrowId].buyer;

        _sendToRecipient(escrowId, recipient);

        // Set state based on who received funds
        escrows[escrowId].state = sendToSeller
            ? EscrowState.Released
            : EscrowState.Refunded;

        emit EscrowDisputed(escrowId, msg.sender, recipient);
    }

    // ─── View Functions ────────────────────────────────────────────────
    /// @notice Returns the encrypted amount handle for an escrow.
    /// @dev    The handle is publicly readable, but only parties whose address
    ///         was granted ACL via `FHE.allow` can decrypt it via the Relayer
    ///         SDK. Currently the buyer (granted at `createEscrow`) and any
    ///         recipient of `_sendToRecipient` (post-release / post-resolve,
    ///         granted indirectly through the token's per-balance ACL) have
    ///         decryption rights on their respective views.
    function getEscrowAmount(uint256 escrowId) external view returns (euint64) {
        return escrows[escrowId].amount;
    }

    /// @notice Returns the current state of an escrow.
    function getEscrowState(uint256 escrowId) external view returns (EscrowState) {
        return escrows[escrowId].state;
    }

    /// @notice Returns the buyer, seller, and arbiter of an escrow.
    function getEscrowParties(uint256 escrowId)
        external
        view
        returns (address buyer, address seller, address arbiter)
    {
        Escrow storage e = escrows[escrowId];
        return (e.buyer, e.seller, e.arbiter);
    }

    // ─── Internal ──────────────────────────────────────────────────────
    /// @dev Transfers the escrowed amount from this contract to the recipient
    ///      using confidentialTransfer (contract sends from its own balance).
    function _sendToRecipient(uint256 escrowId, address recipient) internal {
        euint64 amount = escrows[escrowId].amount;

        // Grant the token contract transient access to the amount handle
        // so it can perform FHE math inside its _transfer
        FHE.allowTransient(amount, address(token));

        // Transfer from escrow contract's balance to the recipient
        token.confidentialTransfer(recipient, amount);
    }
}
