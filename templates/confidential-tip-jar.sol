// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// templates/confidential-tip-jar.sol
//
// Confidential tip jar / donation pool — an aggregate-with-private-contributors
// pattern that's distinct from escrow (single-deal) and crowdfunding
// (goal-conditional). Use this shape for: tip jars, fundraisers, GoFundMe-style
// pools, public-treasury inflows, anywhere fans send encrypted contributions
// to one beneficiary and only the running total — never the individual amounts —
// is later revealed.
//
// Patterns demonstrated:
//   - ERC-7984 cross-contract pull (`confidentialTransferFrom` with the silent-zero
//     return-value bound — see `templates/confidential-swap.sol` battle scar)
//   - Per-contributor ACL split: tipper sees their own running contribution,
//     creator sees the jar balance, total stays private until the creator opts in
//   - Snapshot-then-reveal of the lifetime total (Pattern 7 in SKILL.md):
//     `requestRevealTotal` snapshots `_totalTips` into `_pendingRevealHandle`
//     so a concurrent `tip()` during the KMS roundtrip doesn't break
//     `checkSignatures` in `finalizeRevealTotal`.
//   - `KMSInvalidSigner` defense: the constructor-init zero handle of `_totalTips`
//     would fail `publicDecrypt` until at least one FHE op has produced it —
//     guarded by `if (tipCount == 0) revert NoTipsYet();`.
//
// PRECONDITION for `tip()`: each tipper must have called
//   `token.setOperator(address(jar), expiry)` on the ERC-7984 token in a prior
//   tx so this contract can pull funds via `confidentialTransferFrom`. The
//   operator approval is plaintext (the operator relationship itself isn't
//   private) — this is a *role* check, not an encrypted-value check, so it's
//   fine to revert (see SKILL.md Anti-Pattern #4 clarifier).

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";

/// @title Confidential Tip Jar
/// @notice Single-creator jar that accepts confidential ERC-7984 tips. Each
///         tip stays private; only the tipper can decrypt their own running
///         contribution; the creator can decrypt the live jar balance; the
///         lifetime total is private until the creator opts in to a public
///         reveal via the snapshot-then-reveal pattern.
contract ConfidentialTipJar is ZamaEthereumConfig {
    // ─── Immutable wiring ──────────────────────────────────────────────
    IERC7984 public immutable token;
    address public immutable creator;

    // ─── Encrypted accounting ──────────────────────────────────────────
    /// Lifetime cumulative tips received. Never decreases on withdraw —
    /// withdrawing pulls from `_jarBalance`, not from this aggregate.
    /// ACL: contract only (revealed via the snapshot pattern below).
    euint64 private _totalTips;
    /// Live encrypted balance held by the jar. Resets to encrypted zero on
    /// `withdraw()`. ACL: contract + creator.
    euint64 private _jarBalance;
    /// Per-tipper running contribution. ACL: contract + the tipper themselves.
    /// Other parties (including the creator) cannot user-decrypt.
    mapping(address => euint64) private _contributions;
    /// Plaintext flag — has this address ever tipped?
    mapping(address => bool) public hasTipped;
    /// Plaintext counter — number of tip transactions processed.
    uint64 public tipCount;
    /// Plaintext list of unique tippers so the frontend can iterate.
    address[] private _tippers;

    // ─── Snapshot-then-reveal state ────────────────────────────────────
    /// Snapshotted handle of `_totalTips` at the moment the creator
    /// requested the reveal. Required so a concurrent `tip()` during the
    /// KMS roundtrip doesn't break `checkSignatures` in `finalizeRevealTotal`.
    bytes32 private _pendingRevealHandle;
    /// The most recently revealed cumulative total (plaintext, public).
    uint64 public revealedTotal;
    /// `block.timestamp` at which `revealedTotal` was last updated.
    uint64 public revealedAt;

    // ─── Events ────────────────────────────────────────────────────────
    event Tipped(address indexed tipper, uint64 indexed tipIndex);
    event Withdrawn(address indexed to);
    event RevealRequested(bytes32 totalHandle);
    event TotalRevealed(uint64 total, uint64 revealedAt);

    // ─── Errors ────────────────────────────────────────────────────────
    error NotCreator();
    error InvalidAddress();
    error NoRevealPending();
    error NoTipsYet();

    constructor(address tokenAddress, address creator_) {
        if (tokenAddress == address(0) || creator_ == address(0)) revert InvalidAddress();
        token = IERC7984(tokenAddress);
        creator = creator_;

        // Initialise encrypted state at zero so the first FHE.add has a valid
        // LHS. ACL granted to the contract for follow-up ops.
        _totalTips = FHE.asEuint64(0);
        FHE.allowThis(_totalTips);
        _jarBalance = FHE.asEuint64(0);
        FHE.allowThis(_jarBalance);
    }

    modifier onlyCreator() {
        // Plaintext role check — the creator address is public, not encrypted,
        // so reverting here does NOT leak any confidential state. Contrast
        // with comparing two encrypted balances, which would leak (see
        // SKILL.md Anti-Pattern #4).
        if (msg.sender != creator) revert NotCreator();
        _;
    }

    // ─── Tip ───────────────────────────────────────────────────────────
    /// @notice Send an encrypted tip into the jar.
    /// @dev    Requires `token.setOperator(address(this), expiry)` from msg.sender.
    function tip(externalEuint64 encAmount, bytes calldata inputProof) external {
        // 1. Validate the encrypted input — binds the proof to msg.sender.
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // 2. Grant the token contract transient access so it can run FHE math
        //    on this handle inside its `_update`.
        FHE.allowTransient(amount, address(token));

        // 3. Pull tokens. May silently transfer 0 if the tipper has insufficient
        //    balance. `transferred` reflects what actually moved — bind it; do
        //    NOT compute downstream state from `amount` (drain bug).
        euint64 transferred = token.confidentialTransferFrom(msg.sender, address(this), amount);

        // 4. Update the running aggregates.
        _totalTips = FHE.add(_totalTips, transferred);
        FHE.allowThis(_totalTips);

        _jarBalance = FHE.add(_jarBalance, transferred);
        FHE.allowThis(_jarBalance);
        FHE.allow(_jarBalance, creator); // creator can decrypt the live jar balance

        // 5. Per-tipper running contribution.
        euint64 prior = _contributions[msg.sender];
        if (!hasTipped[msg.sender]) {
            // First tip from this address — start from explicit zero so ACL
            // is unambiguous (uninitialised handles work as LHS but make ACL
            // intent harder to read).
            prior = FHE.asEuint64(0);
            hasTipped[msg.sender] = true;
            _tippers.push(msg.sender);
        }
        euint64 newContribution = FHE.add(prior, transferred);
        _contributions[msg.sender] = newContribution;
        FHE.allowThis(newContribution);
        FHE.allow(newContribution, msg.sender); // tipper can user-decrypt their own

        emit Tipped(msg.sender, tipCount);
        unchecked { tipCount++; }
    }

    // ─── Withdraw ──────────────────────────────────────────────────────
    /// @notice Creator pulls the jar's full confidential balance into their
    ///         own balance via `confidentialTransfer`. `_jarBalance` resets
    ///         to encrypted zero. `_totalTips` is intentionally NOT decreased
    ///         — it is the lifetime cumulative aggregate, not the live balance.
    function withdraw() external onlyCreator {
        euint64 amount = _jarBalance;
        FHE.allowTransient(amount, address(token));
        token.confidentialTransfer(creator, amount);

        _jarBalance = FHE.asEuint64(0);
        FHE.allowThis(_jarBalance);
        FHE.allow(_jarBalance, creator);

        emit Withdrawn(creator);
    }

    // ─── Public-decrypt reveal of cumulative total ─────────────────────
    /// @notice Step 1 of the snapshot-then-reveal pattern: mark `_totalTips`
    ///         as publicly decryptable and snapshot its current handle so the
    ///         on-chain verifier in step 2 validates against the same handle
    ///         the KMS signed (even if a `tip()` lands during the roundtrip).
    /// @dev    See SKILL.md Pattern 7 (Snapshot-Then-Reveal).
    function requestRevealTotal() external onlyCreator {
        // KMS hardening: handles produced only by `FHE.asEuint64(0)` (the
        // constructor init) cannot be public-decrypted — they fail with
        // `KMSInvalidSigner`. Requiring at least one tip guarantees
        // `_totalTips` was produced by an `FHE.add` that the KMS witnessed.
        if (tipCount == 0) revert NoTipsYet();

        FHE.makePubliclyDecryptable(_totalTips);
        bytes32 h = FHE.toBytes32(_totalTips);
        _pendingRevealHandle = h;
        emit RevealRequested(h);
    }

    /// @notice Step 2 of the snapshot-then-reveal pattern: anyone (typically
    ///         the frontend) submits the KMS-signed cleartext + proof. The
    ///         contract verifies via `FHE.checkSignatures` on the SNAPSHOTTED
    ///         handle (not the live `_totalTips`, which may have moved on).
    function finalizeRevealTotal(
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external {
        bytes32 snap = _pendingRevealHandle;
        if (snap == bytes32(0)) revert NoRevealPending();

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = snap;
        FHE.checkSignatures(handles, abiEncodedCleartexts, decryptionProof);

        // SDK encodes every cleartext as `uint256` regardless of source type;
        // cast down to the contract's storage type. See decryption-guide.md
        // (`abiEncodedClearValues` SDK field vs `abiEncodedCleartexts`
        // on-chain param naming).
        uint256 raw = abi.decode(abiEncodedCleartexts, (uint256));
        revealedTotal = uint64(raw);
        revealedAt = uint64(block.timestamp);
        _pendingRevealHandle = bytes32(0); // clear so a stale finalize can't re-fire

        emit TotalRevealed(revealedTotal, revealedAt);
    }

    // ─── View helpers ──────────────────────────────────────────────────
    /// @notice Encrypted total handle. Decryptable only via the public-reveal
    ///         flow above (or off-chain by anyone once `requestRevealTotal`
    ///         has been called).
    function totalTipsHandle() external view returns (euint64) {
        return _totalTips;
    }

    /// @notice Encrypted jar balance handle. Decryptable by the creator
    ///         (granted in `tip` and `withdraw`).
    function jarBalanceHandle() external view returns (euint64) {
        return _jarBalance;
    }

    /// @notice Encrypted handle for caller's own running contribution.
    ///         The caller (and only the caller) can user-decrypt it.
    function myContributionHandle() external view returns (euint64) {
        return _contributions[msg.sender];
    }

    /// @notice Address-keyed lookup of a tipper's contribution handle. The
    ///         handle is public on-chain but only the tipper has the ACL grant
    ///         required to decrypt it via the relayer.
    function contributionHandleOf(address tipper) external view returns (euint64) {
        return _contributions[tipper];
    }

    function pendingRevealHandle() external view returns (bytes32) {
        return _pendingRevealHandle;
    }

    function tippersCount() external view returns (uint256) {
        return _tippers.length;
    }

    function tipperAt(uint256 i) external view returns (address) {
        return _tippers[i];
    }
}
