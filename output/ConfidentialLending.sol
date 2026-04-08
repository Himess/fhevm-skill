// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title IConfidentialERC20
/// @notice Minimal interface for a ConfidentialERC20 token used as collateral or borrow asset.
interface IConfidentialERC20 {
    function confidentialTransferFrom(
        address from,
        address to,
        euint64 amount
    ) external returns (euint64);

    function confidentialTransfer(address to, euint64 amount) external returns (euint64);

    function balanceOf(address account) external view returns (euint64);
}

/// @title ConfidentialLending
/// @notice A confidential lending protocol where all positions (collateral, debt, balances) are
///         encrypted using Zama's FHEVM. Nobody can see any user's position on-chain.
///
/// @dev Architecture:
///   - Users deposit an encrypted amount of collateral (a ConfidentialERC20 token).
///   - Users borrow against their collateral at a 50% LTV ratio.
///   - Interest accrues using a simplified plaintext annual rate, applied per-block.
///   - Liquidation is checked via encrypted comparison: if debt > collateral * LTV, the
///     position can be liquidated. Liquidation itself uses the silent-failure pattern
///     so that the outcome (whether a position was actually underwater) is never revealed.
///   - Repayment allows users to reduce their encrypted debt.
///
///   Key FHEVM patterns applied:
///     - ACL triple (allowThis + allow) after every FHE state mutation
///     - Silent failure via FHE.select (no reverts on encrypted conditions)
///     - Plaintext divisors only for FHE.div
///     - Cached encrypted constants (ENCRYPTED_ZERO)
///     - Smallest viable type (euint64 for amounts, ebool for flags)
///     - allowTransient for cross-contract calls within same tx
///     - ReentrancyGuard, Ownable2Step, Pausable per security checklist
///     - FHE.isInitialized checks before first use of storage slots
///     - No if/require on encrypted values (select only)
///     - Events emit no plaintext amounts
contract ConfidentialLending is ZamaEthereumConfig, Ownable2Step, ReentrancyGuard, Pausable {
    // ─── Constants ──────────────────────────────────────────────────────

    /// @notice Loan-to-value ratio numerator (50%). Denominator is 100.
    uint64 public constant LTV_NUMERATOR = 50;
    uint64 public constant LTV_DENOMINATOR = 100;

    /// @notice Simplified annual interest rate numerator (5%). Denominator is 100.
    /// Applied per accrual call as: debt += debt * INTEREST_RATE / INTEREST_DENOMINATOR
    uint64 public constant INTEREST_RATE = 5;
    uint64 public constant INTEREST_DENOMINATOR = 100;

    /// @notice Liquidation bonus numerator (10%). Liquidator gets collateral * (100 + BONUS) / 100.
    uint64 public constant LIQUIDATION_BONUS_NUMERATOR = 110;
    uint64 public constant LIQUIDATION_BONUS_DENOMINATOR = 100;

    /// @notice Maximum number of users that can be accrued in a single batch call.
    uint256 public constant MAX_BATCH_SIZE = 10;

    // ─── Tokens ─────────────────────────────────────────────────────────

    /// @notice The ConfidentialERC20 used as collateral.
    IConfidentialERC20 public immutable collateralToken;

    /// @notice The ConfidentialERC20 used as the borrow asset.
    IConfidentialERC20 public immutable borrowToken;

    // ─── Encrypted State ────────────────────────────────────────────────

    /// @notice Encrypted collateral deposits per user.
    mapping(address => euint64) private _collateral;

    /// @notice Encrypted debt per user.
    mapping(address => euint64) private _debt;

    /// @notice Encrypted total collateral held by the protocol.
    euint64 private _totalCollateral;

    /// @notice Encrypted total debt outstanding.
    euint64 private _totalDebt;

    // ─── Cached Encrypted Constants (Gas Optimization #4) ───────────────

    /// @notice Pre-encrypted zero to avoid re-encryption in hot paths.
    euint64 private ENCRYPTED_ZERO;

    // ─── Plaintext State ────────────────────────────────────────────────

    /// @notice Tracks which users have active positions (for iteration / batch accrual).
    address[] public borrowers;
    mapping(address => bool) public isBorrower;

    /// @notice Last block at which interest was accrued for a given user.
    mapping(address => uint256) public lastAccrualBlock;

    // ─── Events (no plaintext amounts — security checklist) ─────────────

    event CollateralDeposited(address indexed user);
    event CollateralWithdrawn(address indexed user);
    event BorrowExecuted(address indexed user);
    event RepaymentMade(address indexed user);
    event InterestAccrued(address indexed user, uint256 blocks);
    event LiquidationAttempted(address indexed liquidator, address indexed user);
    event ProtocolPaused();
    event ProtocolUnpaused();

    // ─── Constructor ────────────────────────────────────────────────────

    constructor(
        address _collateralToken,
        address _borrowToken
    ) Ownable(msg.sender) {
        require(_collateralToken != address(0), "Invalid collateral token");
        require(_borrowToken != address(0), "Invalid borrow token");

        collateralToken = IConfidentialERC20(_collateralToken);
        borrowToken = IConfidentialERC20(_borrowToken);

        // Cache encrypted zero (Gas Optimization #4)
        ENCRYPTED_ZERO = FHE.asEuint64(0);
        FHE.allowThis(ENCRYPTED_ZERO);

        // Initialize totals
        _totalCollateral = FHE.asEuint64(0);
        FHE.allowThis(_totalCollateral);

        _totalDebt = FHE.asEuint64(0);
        FHE.allowThis(_totalDebt);
    }

    // ─── Modifiers ──────────────────────────────────────────────────────

    /// @notice Ensures the user's encrypted storage is initialized before first use.
    modifier ensureInitialized(address user) {
        if (!FHE.isInitialized(_collateral[user])) {
            _collateral[user] = FHE.asEuint64(0);
            FHE.allowThis(_collateral[user]);
            FHE.allow(_collateral[user], user);
        }
        if (!FHE.isInitialized(_debt[user])) {
            _debt[user] = FHE.asEuint64(0);
            FHE.allowThis(_debt[user]);
            FHE.allow(_debt[user], user);
        }
        _;
    }

    // ═════════════════════════════════════════════════════════════════════
    //                          DEPOSIT COLLATERAL
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Deposit encrypted collateral into the lending protocol.
    /// @param encAmount The encrypted collateral amount.
    /// @param inputProof ZK proof for the encrypted input.
    function depositCollateral(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant whenNotPaused ensureInitialized(msg.sender) {
        // Validate encrypted input (Input Validation pattern)
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // Cross-contract FHE: grant transient access to collateral token (Gas Optimization #3)
        FHE.allowTransient(amount, address(collateralToken));

        // Transfer collateral from user to this contract
        // The token's transferFrom uses the silent-failure pattern internally
        euint64 transferred = collateralToken.confidentialTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        // Grant persistent access to this contract for the returned handle
        FHE.allowThis(transferred);

        // Update user collateral: collateral[user] += transferred
        _collateral[msg.sender] = FHE.add(_collateral[msg.sender], transferred);
        FHE.allowThis(_collateral[msg.sender]);
        FHE.allow(_collateral[msg.sender], msg.sender);

        // Update total collateral
        _totalCollateral = FHE.add(_totalCollateral, transferred);
        FHE.allowThis(_totalCollateral);

        emit CollateralDeposited(msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════
    //                          WITHDRAW COLLATERAL
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Withdraw collateral, but only the excess above what's needed for the loan.
    ///         Uses the silent-failure pattern: if the user tries to withdraw more than
    ///         the free collateral, 0 is withdrawn (no revert, preserves confidentiality).
    /// @param encAmount The encrypted withdrawal amount.
    /// @param inputProof ZK proof for the encrypted input.
    function withdrawCollateral(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant whenNotPaused ensureInitialized(msg.sender) {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // Calculate required collateral: debt * LTV_DENOMINATOR / LTV_NUMERATOR
        // Required = debt * 100 / 50 = debt * 2
        // This is the minimum collateral needed to back the debt at 50% LTV.
        // Using plaintext divisor (FHE.div rule).
        euint64 requiredCollateral = FHE.div(
            FHE.mul(_debt[msg.sender], uint64(LTV_DENOMINATOR)),
            LTV_NUMERATOR
        );

        // Free collateral = max(0, collateral - required)
        // Use select to handle underflow silently
        ebool hasExcess = FHE.ge(_collateral[msg.sender], requiredCollateral);
        euint64 excessCollateral = FHE.select(
            hasExcess,
            FHE.sub(_collateral[msg.sender], requiredCollateral),
            ENCRYPTED_ZERO
        );

        // Actual withdrawal = min(requested, available excess)
        euint64 actualWithdraw = FHE.min(amount, excessCollateral);

        // Update user collateral
        _collateral[msg.sender] = FHE.sub(_collateral[msg.sender], actualWithdraw);
        FHE.allowThis(_collateral[msg.sender]);
        FHE.allow(_collateral[msg.sender], msg.sender);

        // Update total collateral
        _totalCollateral = FHE.sub(_totalCollateral, actualWithdraw);
        FHE.allowThis(_totalCollateral);

        // Transfer collateral back to user
        FHE.allowTransient(actualWithdraw, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, actualWithdraw);

        emit CollateralWithdrawn(msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════
    //                              BORROW
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Borrow against deposited collateral at 50% LTV.
    ///         Silent failure: if the user tries to borrow more than allowed, 0 is borrowed.
    /// @param encAmount The encrypted borrow amount.
    /// @param inputProof ZK proof for the encrypted input.
    function borrow(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant whenNotPaused ensureInitialized(msg.sender) {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // Max borrow = collateral * LTV_NUMERATOR / LTV_DENOMINATOR
        // = collateral * 50 / 100
        // Using plaintext divisor
        euint64 maxBorrow = FHE.div(
            FHE.mul(_collateral[msg.sender], uint64(LTV_NUMERATOR)),
            LTV_DENOMINATOR
        );

        // Available borrow = maxBorrow - currentDebt (if positive, else 0)
        ebool hasCapacity = FHE.ge(maxBorrow, _debt[msg.sender]);
        euint64 availableBorrow = FHE.select(
            hasCapacity,
            FHE.sub(maxBorrow, _debt[msg.sender]),
            ENCRYPTED_ZERO
        );

        // Actual borrow = min(requested, available)
        // Use FHE.min instead of comparison + select (Gas Optimization #5)
        euint64 actualBorrow = FHE.min(amount, availableBorrow);

        // Update user debt
        _debt[msg.sender] = FHE.add(_debt[msg.sender], actualBorrow);
        FHE.allowThis(_debt[msg.sender]);
        FHE.allow(_debt[msg.sender], msg.sender);

        // Update total debt
        _totalDebt = FHE.add(_totalDebt, actualBorrow);
        FHE.allowThis(_totalDebt);

        // Track borrower for batch accrual
        if (!isBorrower[msg.sender]) {
            isBorrower[msg.sender] = true;
            borrowers.push(msg.sender);
            lastAccrualBlock[msg.sender] = block.number;
        }

        // Transfer borrow tokens to user
        FHE.allowTransient(actualBorrow, address(borrowToken));
        borrowToken.confidentialTransfer(msg.sender, actualBorrow);

        emit BorrowExecuted(msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════
    //                             REPAY
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Repay some or all of the user's debt.
    ///         If repayment exceeds debt, only the debt amount is taken (silent cap).
    /// @param encAmount The encrypted repayment amount.
    /// @param inputProof ZK proof for the encrypted input.
    function repay(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external nonReentrant whenNotPaused ensureInitialized(msg.sender) {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);

        // Cap repayment at current debt (don't overpay)
        // Use FHE.min (Gas Optimization #5)
        euint64 actualRepay = FHE.min(amount, _debt[msg.sender]);

        // Transfer borrow tokens from user to this contract
        FHE.allowTransient(actualRepay, address(borrowToken));
        euint64 received = borrowToken.confidentialTransferFrom(
            msg.sender,
            address(this),
            actualRepay
        );
        FHE.allowThis(received);

        // Update user debt
        _debt[msg.sender] = FHE.sub(_debt[msg.sender], received);
        FHE.allowThis(_debt[msg.sender]);
        FHE.allow(_debt[msg.sender], msg.sender);

        // Update total debt
        _totalDebt = FHE.sub(_totalDebt, received);
        FHE.allowThis(_totalDebt);

        emit RepaymentMade(msg.sender);
    }

    // ═════════════════════════════════════════════════════════════════════
    //                       INTEREST ACCRUAL
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Accrue interest for a single user. Interest = debt * INTEREST_RATE / 100
    ///         per accrual period. Simplified: applies the rate once per call regardless
    ///         of how many blocks have passed (a production system would compound).
    /// @dev Uses plaintext rate with encrypted debt. The number of elapsed blocks is
    ///      plaintext (acceptable — it reveals timing, not amounts).
    function accrueInterest(address user) public whenNotPaused ensureInitialized(user) {
        uint256 blocksElapsed = block.number - lastAccrualBlock[user];
        if (blocksElapsed == 0) return;

        lastAccrualBlock[user] = block.number;

        // interest = debt * INTEREST_RATE / INTEREST_DENOMINATOR
        // Simplified: flat rate per accrual call (not compounding per block).
        // Both multiplier and divisor are plaintext (Gas Optimization #2).
        euint64 interest = FHE.div(
            FHE.mul(_debt[user], uint64(INTEREST_RATE)),
            INTEREST_DENOMINATOR
        );

        // Update user debt: debt += interest
        _debt[user] = FHE.add(_debt[user], interest);
        FHE.allowThis(_debt[user]);
        FHE.allow(_debt[user], user);

        // Update total debt
        _totalDebt = FHE.add(_totalDebt, interest);
        FHE.allowThis(_totalDebt);

        emit InterestAccrued(user, blocksElapsed);
    }

    /// @notice Batch accrue interest for multiple users (Gas Optimization #6 & #9).
    /// @param users Array of user addresses (bounded to MAX_BATCH_SIZE).
    function batchAccrueInterest(address[] calldata users) external whenNotPaused {
        require(users.length <= MAX_BATCH_SIZE, "Batch too large");
        for (uint256 i = 0; i < users.length; i++) {
            accrueInterest(users[i]);
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //                          LIQUIDATION
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Attempt to liquidate an undercollateralized position.
    ///         Uses encrypted comparison: if debt > collateral * LTV / 100, the position
    ///         is liquidatable. The liquidator repays the debt and receives the collateral
    ///         plus a bonus.
    ///
    ///         CRITICAL: This uses the silent-failure pattern. If the position is actually
    ///         healthy, 0 is transferred in both directions. Nobody learns whether the
    ///         liquidation actually occurred (preserves confidentiality of the position).
    ///
    /// @param user The user whose position to attempt to liquidate.
    /// @param encRepayAmount The encrypted amount the liquidator is willing to repay.
    /// @param inputProof ZK proof for the encrypted input.
    function liquidate(
        address user,
        externalEuint64 encRepayAmount,
        bytes calldata inputProof
    ) external nonReentrant whenNotPaused ensureInitialized(user) ensureInitialized(msg.sender) {
        require(msg.sender != user, "Cannot self-liquidate");

        // Accrue interest first so debt is up to date
        accrueInterest(user);

        euint64 repayAmount = FHE.fromExternal(encRepayAmount, inputProof);

        // Check if position is liquidatable:
        // Position is underwater when: debt > collateral * LTV_NUMERATOR / LTV_DENOMINATOR
        // Rearranged to avoid encrypted division: debt * LTV_DENOMINATOR > collateral * LTV_NUMERATOR
        euint64 debtScaled = FHE.mul(_debt[user], uint64(LTV_DENOMINATOR));
        euint64 collateralScaled = FHE.mul(_collateral[user], uint64(LTV_NUMERATOR));
        ebool isUnderwater = FHE.gt(debtScaled, collateralScaled);

        // If not underwater, zero out the repay amount (silent failure)
        euint64 effectiveRepay = FHE.select(isUnderwater, repayAmount, ENCRYPTED_ZERO);

        // Cap repayment to actual debt
        effectiveRepay = FHE.min(effectiveRepay, _debt[user]);

        // Calculate collateral to seize: repayAmount * LIQUIDATION_BONUS_NUMERATOR / LIQUIDATION_BONUS_DENOMINATOR
        // = repayAmount * 110 / 100 (10% bonus)
        // Using plaintext divisor
        euint64 collateralToSeize = FHE.div(
            FHE.mul(effectiveRepay, uint64(LIQUIDATION_BONUS_NUMERATOR)),
            LIQUIDATION_BONUS_DENOMINATOR
        );

        // Cap collateral seizure to available collateral
        collateralToSeize = FHE.min(collateralToSeize, _collateral[user]);

        // ─── Execute liquidation (all silent — no revert if position is healthy) ───

        // 1. Liquidator sends borrow tokens to cover the debt
        FHE.allowTransient(effectiveRepay, address(borrowToken));
        euint64 receivedRepay = borrowToken.confidentialTransferFrom(
            msg.sender,
            address(this),
            effectiveRepay
        );
        FHE.allowThis(receivedRepay);

        // 2. Reduce user's debt by the repaid amount
        _debt[user] = FHE.sub(_debt[user], receivedRepay);
        FHE.allowThis(_debt[user]);
        FHE.allow(_debt[user], user);

        // 3. Reduce user's collateral by the seized amount
        _collateral[user] = FHE.sub(_collateral[user], collateralToSeize);
        FHE.allowThis(_collateral[user]);
        FHE.allow(_collateral[user], user);

        // 4. Transfer seized collateral to liquidator
        FHE.allowTransient(collateralToSeize, address(collateralToken));
        collateralToken.confidentialTransfer(msg.sender, collateralToSeize);

        // 5. Update totals
        _totalDebt = FHE.sub(_totalDebt, receivedRepay);
        FHE.allowThis(_totalDebt);

        _totalCollateral = FHE.sub(_totalCollateral, collateralToSeize);
        FHE.allowThis(_totalCollateral);

        emit LiquidationAttempted(msg.sender, user);
    }

    // ═════════════════════════════════════════════════════════════════════
    //                         VIEW FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Get a user's encrypted collateral balance. Only the user can decrypt it.
    /// @dev Checks ACL before returning (Security Checklist: unprotected view functions).
    function getCollateral(address user) external view returns (euint64) {
        require(FHE.isAllowed(_collateral[user], msg.sender), "Not authorized");
        return _collateral[user];
    }

    /// @notice Get a user's encrypted debt. Only the user can decrypt it.
    function getDebt(address user) external view returns (euint64) {
        require(FHE.isAllowed(_debt[user], msg.sender), "Not authorized");
        return _debt[user];
    }

    /// @notice Get the protocol's total encrypted collateral. Only owner can view.
    function getTotalCollateral() external view returns (euint64) {
        require(FHE.isAllowed(_totalCollateral, msg.sender), "Not authorized");
        return _totalCollateral;
    }

    /// @notice Get the protocol's total encrypted debt. Only owner can view.
    function getTotalDebt() external view returns (euint64) {
        require(FHE.isAllowed(_totalDebt, msg.sender), "Not authorized");
        return _totalDebt;
    }

    /// @notice Get the number of tracked borrowers.
    function getBorrowerCount() external view returns (uint256) {
        return borrowers.length;
    }

    // ═════════════════════════════════════════════════════════════════════
    //                        ADMIN FUNCTIONS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Pause the protocol in case of emergency.
    function pause() external onlyOwner {
        _pause();
        emit ProtocolPaused();
    }

    /// @notice Unpause the protocol.
    function unpause() external onlyOwner {
        _unpause();
        emit ProtocolUnpaused();
    }
}
