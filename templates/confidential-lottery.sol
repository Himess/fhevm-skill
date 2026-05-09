// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// templates/confidential-lottery.sol
//
// Confidential lottery / commit-reveal raffle — encrypted ticket counts per
// player, a publicly-decryptable winner-flag for proof, single payout to the
// winner. Distinct from auctions (highest bid wins) and crowdfunding (any
// pledge counts toward a goal): the lottery shape is "many players each take
// a private slice of an integer range; one slot is randomly chosen; only that
// slot's owner can prove it and claim".
//
// Patterns demonstrated:
//   - Encrypted ticket-range allocation: each buy claims `[start, start + count)`,
//     with `start = pre-buy total` and `count` capped at `maxTickets - sold`
//     (silent cap to avoid leaking the requested count via revert)
//   - Per-player winner proof: `(start <= winIdx) && (winIdx < start + count)`
//     packed into a `euint64` flag (1 = winner, 0 = not), made publicly
//     decryptable by the player so the on-chain `claim` can verify the KMS
//     signature without needing the operator to take a custodial reveal step
//   - Multi-round state machine: Idle → Open → Closed → Revealed → Claimed
//     guarded by typed `error` reverts (plaintext role / lifecycle checks,
//     not encrypted-value checks — see SKILL.md Anti-Pattern #4)
//   - ERC-7984 cross-contract pull (`confidentialTransferFrom`) with the
//     silent-zero return-value bound, plus partial-pay handling: if the
//     player's balance is short, the transfer silently sends 0 and we set
//     `finalCount = 0` via `FHE.eq(transferred, cost)`.
//
// PRECONDITION for `buyTickets()`: each player must call
//   `token.setOperator(address(lottery), expiry)` on the ERC-7984 token in a
//   prior tx so this contract can pull the ticket cost.

import {FHE, ebool, euint32, euint64, externalEuint32} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title Confidential Lottery
/// @notice Operator opens rounds with a public ticket price, max tickets, and
///         deadline. Players buy encrypted ticket counts; the running pot
///         and per-player counts stay confidential during the round. After
///         the deadline the pot is publicly decryptable; the operator picks
///         a winning ticket index. The winner proves ownership via a publicly
///         decryptable comparison handle and claims the entire pot.
contract ConfidentialLottery is ZamaEthereumConfig, Ownable2Step {
    enum State { Idle, Open, Closed, Revealed, Claimed }

    IERC7984 public immutable token;

    struct RoundInfo {
        uint64  ticketPrice;   // public — ticket cost in token base units
        uint32  maxTickets;    // public — hard cap on tickets sold this round
        uint64  deadline;      // public — UNIX seconds; no buys at or after this
        State   state;
        uint32  winningIdx;    // set by `revealWinningIndex`
        address winner;        // set by `claim`
    }

    /// @notice Round IDs start at 1 and increment per `openRound`. 0 = no round yet.
    uint32 public currentRoundId;
    mapping(uint32 => RoundInfo) public roundInfo;

    /// @notice Encrypted per-round running totals. ACL: contract only until
    ///         `closeRound` flips them publicly decryptable.
    mapping(uint32 => euint32) private _totalTickets;
    mapping(uint32 => euint64) private _pot;

    /// @notice Encrypted per-(round, player) ticket assignment. `start` is the
    ///         pre-buy `_totalTickets`, `count` is the actual number of tickets
    ///         the player received (silently capped, possibly 0 on partial pay).
    ///         ACL: contract + the player themselves.
    mapping(uint32 => mapping(address => euint32)) private _ticketStart;
    mapping(uint32 => mapping(address => euint32)) private _ticketCount;
    mapping(uint32 => mapping(address => bool))    public  hasBought;

    /// @notice Encrypted per-(round, player) winner flag (1 if the player owns
    ///         the winning index, else 0). Made publicly decryptable by
    ///         `requestClaim`. Verified on-chain by `claim` via
    ///         `FHE.checkSignatures` against the snapshotted handle.
    mapping(uint32 => mapping(address => euint64)) private _winFlag;

    event RoundOpened(uint32 indexed roundId, uint64 ticketPrice, uint32 maxTickets, uint64 deadline);
    event TicketsBought(uint32 indexed roundId, address indexed player);
    event RoundClosed(uint32 indexed roundId, bytes32 potHandle, bytes32 totalTicketsHandle);
    event WinnerRevealed(uint32 indexed roundId, uint32 winningIdx);
    event ClaimRequested(uint32 indexed roundId, address indexed player, bytes32 flagHandle);
    event Claimed(uint32 indexed roundId, address indexed winner);

    error NotOpen();
    error NotClosed();
    error NotRevealed();
    error AlreadyBought();
    error NeverBought();
    error DeadlineNotReached();
    error DeadlineReached();
    error BadParams();
    error WinnerProofFailed();
    error PreviousRoundNotFinished();

    constructor(address operator_, IERC7984 token_) Ownable(operator_) {
        require(address(token_) != address(0), "token=0");
        token = token_;
    }

    // ─── Operator: open a round ────────────────────────────────────────
    function openRound(uint64 ticketPrice_, uint32 maxTickets_, uint64 duration) external onlyOwner {
        if (ticketPrice_ == 0 || maxTickets_ == 0 || duration == 0) revert BadParams();
        if (currentRoundId != 0) {
            State s = roundInfo[currentRoundId].state;
            if (s != State.Claimed && s != State.Revealed) revert PreviousRoundNotFinished();
        }

        uint32 newId = currentRoundId + 1;
        currentRoundId = newId;
        uint64 deadline_ = uint64(block.timestamp) + duration;

        roundInfo[newId] = RoundInfo({
            ticketPrice: ticketPrice_,
            maxTickets:  maxTickets_,
            deadline:    deadline_,
            state:       State.Open,
            winningIdx:  0,
            winner:      address(0)
        });

        // Initialise encrypted aggregates so the first FHE.add has a valid LHS.
        euint32 zero32 = FHE.asEuint32(0);
        FHE.allowThis(zero32);
        _totalTickets[newId] = zero32;

        euint64 zero64 = FHE.asEuint64(0);
        FHE.allowThis(zero64);
        _pot[newId] = zero64;

        emit RoundOpened(newId, ticketPrice_, maxTickets_, deadline_);
    }

    // ─── Player: buy an encrypted ticket count ─────────────────────────
    /// @notice One buy per address per round. Caller MUST have set this
    ///         contract as operator on the payment token before calling.
    function buyTickets(externalEuint32 encCount, bytes calldata inputProof) external {
        uint32 r = currentRoundId;
        RoundInfo storage info = roundInfo[r];
        if (info.state != State.Open) revert NotOpen();
        if (block.timestamp >= info.deadline) revert DeadlineReached();
        if (hasBought[r][msg.sender]) revert AlreadyBought();
        hasBought[r][msg.sender] = true;

        // 1. Validate input — contract gets ACL on the handle.
        euint32 count = FHE.fromExternal(encCount, inputProof);

        // 2. Cap to remaining tickets (silent — never reverts; revert would
        //    leak the encrypted requested count).
        euint32 remaining = FHE.sub(FHE.asEuint32(info.maxTickets), _totalTickets[r]);
        FHE.allowThis(remaining);
        ebool fits = FHE.le(count, remaining);
        euint32 capped = FHE.select(fits, count, remaining);
        FHE.allowThis(capped);

        // 3. cost = capped * ticketPrice (encrypted × plaintext scalar — fine).
        euint64 cost = FHE.mul(FHE.asEuint64(capped), uint64(info.ticketPrice));
        FHE.allowThis(cost);

        // 4. Pull payment via ERC-7984. Token contract needs transient ACL on
        //    `cost` to do its internal balance/transfer math.
        FHE.allowTransient(cost, address(token));
        euint64 transferred = token.confidentialTransferFrom(msg.sender, address(this), cost);
        FHE.allowThis(transferred);

        // 5. Detect partial pay (insufficient balance → silent 0). Final count
        //    is `capped` if paid in full, else 0. This is the canonical
        //    "bind the return value, never compute downstream from the input"
        //    pattern — see SKILL.md Anti-Pattern about ERC-7984 silent transfers.
        ebool fullyPaid = FHE.eq(transferred, cost);
        euint32 finalCount = FHE.select(fullyPaid, capped, FHE.asEuint32(0));
        FHE.allowThis(finalCount);
        FHE.allow(finalCount, msg.sender);

        // 6. Assign ticket range [start, start + finalCount). Player keeps ACL
        //    on both halves so they can decrypt their own range later.
        euint32 start = _totalTickets[r];
        FHE.allowThis(start);
        FHE.allow(start, msg.sender);
        _ticketStart[r][msg.sender] = start;
        _ticketCount[r][msg.sender] = finalCount;

        // 7. Update encrypted aggregates.
        _totalTickets[r] = FHE.add(_totalTickets[r], finalCount);
        FHE.allowThis(_totalTickets[r]);

        _pot[r] = FHE.add(_pot[r], transferred);
        FHE.allowThis(_pot[r]);

        emit TicketsBought(r, msg.sender);
    }

    // ─── Anyone: close the round once the deadline has passed ──────────
    /// @notice Marks the encrypted pot + total-tickets publicly decryptable.
    function closeRound() external {
        uint32 r = currentRoundId;
        RoundInfo storage info = roundInfo[r];
        if (info.state != State.Open) revert NotOpen();
        if (block.timestamp < info.deadline) revert DeadlineNotReached();

        info.state = State.Closed;
        FHE.makePubliclyDecryptable(_pot[r]);
        FHE.makePubliclyDecryptable(_totalTickets[r]);
        emit RoundClosed(r, FHE.toBytes32(_pot[r]), FHE.toBytes32(_totalTickets[r]));
    }

    // ─── Operator: pick the winning ticket index ───────────────────────
    /// @dev Operator should sample `winningIdx ∈ [0, decrypted_total_tickets)`
    ///      off-chain (after `closeRound` makes the total publicly decryptable)
    ///      using a verifiable randomness source — VRF, BLOCKHASH, etc. The
    ///      template stays oracle-agnostic: the operator submits a plaintext index.
    function revealWinningIndex(uint32 winningIdx_) external onlyOwner {
        uint32 r = currentRoundId;
        RoundInfo storage info = roundInfo[r];
        if (info.state != State.Closed) revert NotClosed();
        if (winningIdx_ >= info.maxTickets) revert BadParams();
        info.winningIdx = winningIdx_;
        info.state = State.Revealed;
        emit WinnerRevealed(r, winningIdx_);
    }

    // ─── Player: ask the contract to mark winner-flag publicly decryptable ─
    /// @notice Computes `(start <= winIdx) && (winIdx < start + count)` for
    ///         the caller and marks the resulting flag publicly decryptable.
    ///         Encoded as `euint64` (1 = winner, 0 = not) so the canonical
    ///         publicDecrypt → uint256 path applies.
    function requestClaim() external returns (bytes32 flagHandle) {
        uint32 r = currentRoundId;
        RoundInfo storage info = roundInfo[r];
        if (info.state != State.Revealed) revert NotRevealed();
        if (!hasBought[r][msg.sender]) revert NeverBought();

        euint32 start = _ticketStart[r][msg.sender];
        euint32 count = _ticketCount[r][msg.sender];
        euint32 winIdxEnc = FHE.asEuint32(info.winningIdx);

        // (start <= winIdx) AND (winIdx < start + count)
        ebool ge = FHE.le(start, winIdxEnc);
        euint32 endIdx = FHE.add(start, count);
        FHE.allowThis(endIdx);
        ebool lt = FHE.lt(winIdxEnc, endIdx);
        ebool isWinner = FHE.and(ge, lt);

        // Encode as euint64 for the canonical decode-as-uint256 path.
        euint64 flag = FHE.select(isWinner, FHE.asEuint64(1), FHE.asEuint64(0));
        FHE.allowThis(flag);
        FHE.makePubliclyDecryptable(flag);
        _winFlag[r][msg.sender] = flag;

        flagHandle = FHE.toBytes32(flag);
        emit ClaimRequested(r, msg.sender, flagHandle);
    }

    // ─── Winner: submit KMS proof + claim entire pot ───────────────────
    function claim(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        uint32 r = currentRoundId;
        RoundInfo storage info = roundInfo[r];
        if (info.state != State.Revealed) revert NotRevealed();

        euint64 flag = _winFlag[r][msg.sender];
        require(FHE.isInitialized(flag), "no claim request");

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(flag);
        FHE.checkSignatures(handles, abiEncodedCleartexts, decryptionProof);

        // SDK encodes every cleartext as `uint256` regardless of source type
        // (see references/decryption-guide.md: `abiEncodedClearValues` in JS
        // vs `abiEncodedCleartexts` in Solidity — same bytes, different name).
        uint256 raw = abi.decode(abiEncodedCleartexts, (uint256));
        if (raw != 1) revert WinnerProofFailed();

        info.winner = msg.sender;
        info.state = State.Claimed;

        // Transfer the entire encrypted pot to the winner. The pot stays
        // encrypted in the token; only the on-chain *total* (already publicly
        // decrypted in `closeRound`) is known to outside observers.
        euint64 pot = _pot[r];
        FHE.allowTransient(pot, address(token));
        token.confidentialTransfer(msg.sender, pot);

        emit Claimed(r, msg.sender);
    }

    // ─── Read-only handle accessors (for off-chain decrypt) ────────────
    function potHandle(uint32 r) external view returns (bytes32) {
        return FHE.toBytes32(_pot[r]);
    }

    function totalTicketsHandle(uint32 r) external view returns (bytes32) {
        return FHE.toBytes32(_totalTickets[r]);
    }

    function ticketCountHandle(uint32 r, address player) external view returns (bytes32) {
        return FHE.toBytes32(_ticketCount[r][player]);
    }

    function ticketStartHandle(uint32 r, address player) external view returns (bytes32) {
        return FHE.toBytes32(_ticketStart[r][player]);
    }

    function winFlagHandle(uint32 r, address player) external view returns (bytes32) {
        return FHE.toBytes32(_winFlag[r][player]);
    }
}
