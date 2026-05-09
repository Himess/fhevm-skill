// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, ebool, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ConfidentialCDPVault — encrypted collateral / debt position protocol.
/// @notice Demonstrates the canonical confidential-DeFi pattern: encrypted
///         collateral, encrypted debt, plaintext oracle, silently-capped
///         over-LTV borrows, and a publicly-decryptable liquidation-flag for
///         UI rendering. Ships with the simplifications recommended by
///         common-pitfalls.md §11 (Pitfall #11) — fractions like 60/100 and
///         80/100 are reduced to 3/5 and 4/5 BEFORE multiplying, to keep
///         FHE.mul intermediates inside the euint64 range.
///
///         Lifecycle:
///           1. User: `collateralToken.setOperator(vault, until)` (separate tx).
///           2. User: `deposit(encAmount, proof)` — pulls ERC-7984 collateral
///              into the vault and increments encrypted `_collateral[user]`.
///           3. User: `borrow(encAmount, proof)` — draws encrypted debt up to
///              60% LTV. Over-LTV requests are silently capped to 0 — never
///              revert (revert would leak the threshold).
///           4. Liquidation discovery: anyone calls `requestLiquidationCheck(user)`
///              which writes the publicly-decryptable `_liqFlag[user]` (0 or 1).
///              Off-chain Relayer SDK `publicDecrypt` reads it; UI displays
///              "healthy" vs "liquidatable".
///           5. Liquidator runs `confirmLiquidatable(user, cleartexts, proof)`
///              to verify the KMS proof on-chain (caches the bool), then
///              `liquidate(user)` seizes collateral and zeroes the debt.
///
///         Constants (uint64 to interop with FHE.div / FHE.mul plaintext args):
///           - LTV_PCT  = 60  (max 60% loan-to-value at borrow time)
///           - LIQ_PCT  = 80  (above 80% LTV → liquidatable)
///         The plaintext oracle price is stored as `oraclePrice`
///         (cWETH-units per debt-unit; scale by usage).
contract ConfidentialCDPVault is ZamaEthereumConfig, Ownable2Step {
    // ─── Constants ────────────────────────────────────────────────────
    uint64 public constant LTV_PCT  = 60; // max LTV at borrow
    uint64 public constant LIQ_PCT  = 80; // liquidation threshold
    uint64 public constant PCT_BASE = 100;

    // ─── State ────────────────────────────────────────────────────────
    IERC7984 public immutable collateralToken;

    /// @notice Plaintext oracle price: how many debt units 1 cWETH unit is worth.
    uint64 public oraclePrice;

    bool public borrowingPaused;

    /// @notice Encrypted user state.
    mapping(address user => euint64) private _collateral;
    mapping(address user => euint64) private _debt;

    /// @notice Public-decryptable liquidation flag (1 if liquidatable, 0 otherwise).
    ///         Refreshed by `requestLiquidationCheck(user)`.
    mapping(address user => euint64) private _liqFlag;

    /// @notice After `confirmLiquidatable` validates the KMS proof, the bool is
    ///         cached so `liquidate(user)` can be called without re-running the
    ///         proof flow within ~256 blocks.
    mapping(address user => bool)   public isLiquidatableCached;
    mapping(address user => uint64) public liqCacheBlock;

    // ─── Events ───────────────────────────────────────────────────────
    event CollateralDeposited(address indexed user);
    event Borrowed(address indexed user);
    event Repaid(address indexed user);
    event Withdrawn(address indexed user);
    event Liquidated(address indexed user, address indexed liquidator);
    event OraclePriceSet(uint64 newPrice);
    event BorrowingPausedSet(bool paused);
    event LiquidationCheckRequested(address indexed user, bytes32 flagHandle);
    event LiquidationConfirmed(address indexed user, bool isLiquidatable);

    // ─── Errors ───────────────────────────────────────────────────────
    error BorrowingPaused();
    error InvalidPrice();
    error NotLiquidatable();
    error StaleLiqCheck();

    constructor(address owner_, IERC7984 collateral_, uint64 initialOraclePrice)
        Ownable(owner_)
    {
        require(initialOraclePrice > 0, "price=0");
        collateralToken = collateral_;
        oraclePrice = initialOraclePrice;
    }

    // ─── Owner controls ───────────────────────────────────────────────

    function setOraclePrice(uint64 newPrice) external onlyOwner {
        if (newPrice == 0) revert InvalidPrice();
        oraclePrice = newPrice;
        emit OraclePriceSet(newPrice);
    }

    function setBorrowingPaused(bool paused_) external onlyOwner {
        borrowingPaused = paused_;
        emit BorrowingPausedSet(paused_);
    }

    // ─── Deposit collateral (ERC-7984 pull) ───────────────────────────

    /// @notice User must first call `collateralToken.setOperator(vault, until)`.
    function deposit(externalEuint64 encAmount, bytes calldata inputProof) external {
        // Validate input → vault gets ACL on the handle.
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // Grant token contract transient access so it can read the handle.
        FHE.allowTransient(amount, address(collateralToken));

        // Pull tokens (no-proof overload — returns the actual transferred amount).
        euint64 transferred = collateralToken.confidentialTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Lazy-init mapping pattern (acl-patterns.md).
        euint64 oldCollat = _collateral[msg.sender];
        euint64 newCollat = FHE.isInitialized(oldCollat)
            ? FHE.add(oldCollat, transferred)
            : transferred;

        _collateral[msg.sender] = newCollat;
        FHE.allowThis(newCollat);
        FHE.allow(newCollat, msg.sender);

        emit CollateralDeposited(msg.sender);
    }

    // ─── Borrow (encrypted credit line) ───────────────────────────────

    /// @notice Borrow an encrypted amount. Silently capped to 0 on over-LTV.
    function borrow(externalEuint64 encAmount, bytes calldata inputProof) external {
        if (borrowingPaused) revert BorrowingPaused();

        euint64 requested = FHE.fromExternal(encAmount, inputProof);

        // maxBorrow = collateral * (LTV_PCT / PCT_BASE) * oraclePrice
        // Pitfall #11 mitigation: simplify 60/100 → 3/5 BEFORE multiplying
        // by oraclePrice, so FHE.mul intermediate stays small.
        euint64 collat = _collateral[msg.sender];
        euint64 collatScaled = FHE.isInitialized(collat)
            ? FHE.div(FHE.mul(collat, uint64(3)), uint64(5))
            : FHE.asEuint64(0);
        euint64 maxBorrowDebt = FHE.mul(collatScaled, oraclePrice);
        FHE.allowThis(maxBorrowDebt);

        // Existing debt
        euint64 currentDebt = _debt[msg.sender];
        if (!FHE.isInitialized(currentDebt)) {
            currentDebt = FHE.asEuint64(0);
            FHE.allowThis(currentDebt);
        }

        // Hypothetical new debt
        euint64 hypNewDebt = FHE.add(currentDebt, requested);
        FHE.allowThis(hypNewDebt);

        // If hypNewDebt <= maxBorrowDebt: take requested. Else: 0 (silent cap).
        ebool ok = FHE.le(hypNewDebt, maxBorrowDebt);
        euint64 actualBorrow = FHE.select(ok, requested, FHE.asEuint64(0));
        FHE.allowThis(actualBorrow);

        euint64 newDebt = FHE.add(currentDebt, actualBorrow);
        _debt[msg.sender] = newDebt;
        FHE.allowThis(newDebt);
        FHE.allow(newDebt, msg.sender);

        // Invalidate stale liq cache.
        delete isLiquidatableCached[msg.sender];

        emit Borrowed(msg.sender);
    }

    // ─── Repay (reduces debt) ─────────────────────────────────────────

    /// @notice Burns part of the user's encrypted debt. (Token-side burn omitted
    ///         for template clarity; in production, also pull/burn the borrow
    ///         token. This template focuses on the encrypted bookkeeping.)
    function repay(externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        euint64 currentDebt = _debt[msg.sender];
        if (!FHE.isInitialized(currentDebt)) {
            return;
        }

        // Cap to currentDebt — silent cap if user tries to over-repay.
        ebool ok = FHE.le(amount, currentDebt);
        euint64 actualRepay = FHE.select(ok, amount, currentDebt);
        FHE.allowThis(actualRepay);

        euint64 newDebt = FHE.sub(currentDebt, actualRepay);
        _debt[msg.sender] = newDebt;
        FHE.allowThis(newDebt);
        FHE.allow(newDebt, msg.sender);

        delete isLiquidatableCached[msg.sender];

        emit Repaid(msg.sender);
    }

    // ─── Withdraw (only if no debt) ───────────────────────────────────

    /// @notice Withdraws encrypted collateral. Silent cap if user has any debt.
    ///         For partial-withdraw under debt, generalise the gate to:
    ///         `actualWithdraw = min(requested, collateral - debt * PCT_BASE / (LIQ_PCT * oraclePrice))`.
    function withdraw(externalEuint64 encAmount, bytes calldata inputProof) external {
        euint64 requested = FHE.fromExternal(encAmount, inputProof);

        euint64 collat = _collateral[msg.sender];
        if (!FHE.isInitialized(collat)) return;

        euint64 currentDebt = _debt[msg.sender];
        ebool noDebt = FHE.isInitialized(currentDebt)
            ? FHE.eq(currentDebt, FHE.asEuint64(0))
            : FHE.asEbool(true);

        // Cap requested to collateral
        ebool fits = FHE.le(requested, collat);
        euint64 cappedToCollat = FHE.select(fits, requested, collat);

        // Zero out if there is debt
        euint64 actualWithdraw = FHE.select(noDebt, cappedToCollat, FHE.asEuint64(0));
        FHE.allowThis(actualWithdraw);

        // Reduce collateral
        euint64 newCollat = FHE.sub(collat, actualWithdraw);
        _collateral[msg.sender] = newCollat;
        FHE.allowThis(newCollat);
        FHE.allow(newCollat, msg.sender);

        // Push tokens back via ERC-7984 transfer.
        FHE.allowTransient(actualWithdraw, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, actualWithdraw);

        emit Withdrawn(msg.sender);
    }

    // ─── Liquidation flow ─────────────────────────────────────────────

    /// @notice Recompute `_liqFlag[user]` and mark it publicly decryptable.
    ///         Off-chain UI: `relayer.publicDecrypt([flagHandle])` → render bool.
    ///         On-chain: liquidator submits proof via `confirmLiquidatable`.
    function requestLiquidationCheck(address user) external returns (bytes32 flagHandle) {
        euint64 collat = _collateral[user];
        euint64 debt   = _debt[user];

        if (!FHE.isInitialized(debt)) {
            // No debt → never liquidatable. Publish a 0 flag.
            euint64 zero = FHE.asEuint64(0);
            FHE.allowThis(zero);
            FHE.makePubliclyDecryptable(zero);
            _liqFlag[user] = zero;
            flagHandle = FHE.toBytes32(zero);
            emit LiquidationCheckRequested(user, flagHandle);
            return flagHandle;
        }

        // threshold = collateral * (LIQ_PCT / PCT_BASE) * oraclePrice
        // Simplify 80/100 → 4/5 to keep mul intermediate small.
        euint64 collatScaled = FHE.isInitialized(collat)
            ? FHE.div(FHE.mul(collat, uint64(4)), uint64(5))
            : FHE.asEuint64(0);
        euint64 maxDebt = FHE.mul(collatScaled, oraclePrice);
        FHE.allowThis(maxDebt);

        // isLiquidatable = debt > maxDebt
        ebool isLiq = FHE.gt(debt, maxDebt);
        // Encode as euint64 (1 or 0) so we can use the standard publicDecrypt
        // → uint256 → cast path (decryption-guide.md).
        euint64 flag = FHE.select(isLiq, FHE.asEuint64(1), FHE.asEuint64(0));
        FHE.allowThis(flag);
        FHE.makePubliclyDecryptable(flag);

        _liqFlag[user] = flag;
        flagHandle = FHE.toBytes32(flag);
        emit LiquidationCheckRequested(user, flagHandle);
    }

    /// @notice Verify the KMS proof for the liquidation flag and cache the bool.
    /// @dev    Anyone can call. `abiEncodedCleartexts` is `abi.encode(uint256)`.
    function confirmLiquidatable(
        address user,
        bytes calldata abiEncodedCleartexts,
        bytes calldata decryptionProof
    ) external returns (bool isLiq) {
        euint64 flag = _liqFlag[user];
        require(FHE.isInitialized(flag), "no flag");

        bytes32[] memory handles = new bytes32[](1);
        handles[0] = FHE.toBytes32(flag);
        FHE.checkSignatures(handles, abiEncodedCleartexts, decryptionProof);

        // SDK encodes everything as uint256 — see decryption-guide.md.
        uint256 raw = abi.decode(abiEncodedCleartexts, (uint256));
        isLiq = (raw == 1);

        isLiquidatableCached[user] = isLiq;
        liqCacheBlock[user] = uint64(block.number);
        emit LiquidationConfirmed(user, isLiq);
    }

    /// @notice Liquidator wipes the user's debt and seizes the user's collateral.
    ///         Caller must have run `requestLiquidationCheck` →
    ///         `confirmLiquidatable` within the last 256 blocks.
    function liquidate(address user) external {
        if (!isLiquidatableCached[user]) revert NotLiquidatable();
        if (block.number > liqCacheBlock[user] + 256) revert StaleLiqCheck();

        euint64 collat = _collateral[user];
        require(FHE.isInitialized(collat), "no collat");

        // Zero the user's positions.
        euint64 zero = FHE.asEuint64(0);
        FHE.allowThis(zero);

        _collateral[user] = zero;
        FHE.allow(zero, user);

        _debt[user] = zero;

        // Send seized collateral to liquidator.
        FHE.allowTransient(collat, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, collat);

        delete isLiquidatableCached[user];
        delete liqCacheBlock[user];
        emit Liquidated(user, msg.sender);
    }

    // ─── Read functions (return handles) ──────────────────────────────

    function collateralOf(address user) external view returns (euint64) {
        return _collateral[user];
    }

    function debtOf(address user) external view returns (euint64) {
        return _debt[user];
    }

    function liquidationFlagOf(address user) external view returns (euint64) {
        return _liqFlag[user];
    }
}
