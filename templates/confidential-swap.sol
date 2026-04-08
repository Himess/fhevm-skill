// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ConfidentialSwap - Fixed-rate confidential token swap
/// @notice Swap between two ERC-7984 tokens at a fixed rate with encrypted amounts.
///         Rate: 1 TokenA = (rateNumerator / rateDenominator) TokenB.
///         Fee: inputAmount / feeDivisor (e.g., feeDivisor=100 means 1% fee).
///         All swap amounts are encrypted. Fee is collected in the input token.
contract ConfidentialSwap is ZamaEthereumConfig, Ownable2Step {
    // ─── State ────────────────────────────────────────────────────────
    IERC7984 public immutable tokenA;
    IERC7984 public immutable tokenB;

    /// @notice Rate: 1 TokenA = rateNumerator/rateDenominator TokenB
    uint64 public rateNumerator;
    uint64 public rateDenominator;

    /// @notice Fee = amount / feeDivisor (e.g., 100 = 1%, 200 = 0.5%)
    uint64 public feeDivisor;

    /// @notice Accumulated encrypted fees (tracked per token)
    euint64 public collectedFeesA;
    euint64 public collectedFeesB;

    bool public paused;

    // ─── Events ───────────────────────────────────────────────────────
    event SwapExecuted(address indexed user, bool indexed aToB);
    event RateUpdated(uint64 numerator, uint64 denominator);
    event FeeUpdated(uint64 feeDivisor);
    event Paused(bool paused);
    event FeesWithdrawn(address indexed token, address indexed to);

    // ─── Errors ───────────────────────────────────────────────────────
    error SwapPaused();
    error InvalidRate();
    error InvalidFee();
    error ZeroAddress();

    // ─── Constructor ──────────────────────────────────────────────────
    /// @param tokenA_ Address of ERC-7984 Token A
    /// @param tokenB_ Address of ERC-7984 Token B
    /// @param rateNum Initial rate numerator (e.g., 2)
    /// @param rateDen Initial rate denominator (e.g., 1)
    /// @param feeDivisor_ Fee divisor (e.g., 100 for 1% fee, 0 for no fee)
    constructor(
        address tokenA_,
        address tokenB_,
        uint64 rateNum,
        uint64 rateDen,
        uint64 feeDivisor_
    ) Ownable(msg.sender) {
        if (tokenA_ == address(0) || tokenB_ == address(0)) revert ZeroAddress();
        if (rateNum == 0 || rateDen == 0) revert InvalidRate();

        tokenA = IERC7984(tokenA_);
        tokenB = IERC7984(tokenB_);
        rateNumerator = rateNum;
        rateDenominator = rateDen;
        feeDivisor = feeDivisor_;

        // Initialize fee accumulators with encrypted zero
        collectedFeesA = FHE.asEuint64(0);
        FHE.allowThis(collectedFeesA);

        collectedFeesB = FHE.asEuint64(0);
        FHE.allowThis(collectedFeesB);
    }

    // ─── Modifiers ────────────────────────────────────────────────────
    modifier whenNotPaused() {
        if (paused) revert SwapPaused();
        _;
    }

    // ─── Swap A -> B ──────────────────────────────────────────────────
    /// @notice Swap TokenA for TokenB at the fixed rate.
    ///         User must first call tokenA.setOperator(swapAddress, expiry).
    /// @param encAmountA Encrypted amount of TokenA to swap
    /// @param inputProof ZK proof for the encrypted input
    function swapAtoB(
        externalEuint64 encAmountA,
        bytes calldata inputProof
    ) external whenNotPaused {
        euint64 amountA = FHE.fromExternal(encAmountA, inputProof);

        // Calculate fee and net amount
        euint64 fee;
        euint64 netAmount;
        if (feeDivisor > 0) {
            fee = FHE.div(amountA, uint64(feeDivisor));
            netAmount = FHE.sub(amountA, fee);
        } else {
            fee = FHE.asEuint64(0);
            netAmount = amountA;
        }

        // Calculate output: netAmount * rateNumerator / rateDenominator
        euint64 amountB;
        if (rateNumerator != rateDenominator) {
            amountB = FHE.div(
                FHE.mul(netAmount, uint64(rateNumerator)),
                uint64(rateDenominator)
            );
        } else {
            amountB = netAmount;
        }

        // Pull TokenA from user to this contract
        FHE.allowTransient(amountA, address(tokenA));
        tokenA.confidentialTransferFrom(msg.sender, address(this), amountA);

        // Send TokenB from this contract to user
        FHE.allowTransient(amountB, address(tokenB));
        tokenB.confidentialTransfer(msg.sender, amountB);

        // Accumulate fees
        if (feeDivisor > 0) {
            collectedFeesA = FHE.add(collectedFeesA, fee);
            FHE.allowThis(collectedFeesA);
            FHE.allow(collectedFeesA, owner());
        }

        emit SwapExecuted(msg.sender, true);
    }

    // ─── Swap B -> A ──────────────────────────────────────────────────
    /// @notice Swap TokenB for TokenA at the fixed rate (inverse).
    ///         User must first call tokenB.setOperator(swapAddress, expiry).
    /// @param encAmountB Encrypted amount of TokenB to swap
    /// @param inputProof ZK proof for the encrypted input
    function swapBtoA(
        externalEuint64 encAmountB,
        bytes calldata inputProof
    ) external whenNotPaused {
        euint64 amountB = FHE.fromExternal(encAmountB, inputProof);

        // Calculate fee and net amount
        euint64 fee;
        euint64 netAmount;
        if (feeDivisor > 0) {
            fee = FHE.div(amountB, uint64(feeDivisor));
            netAmount = FHE.sub(amountB, fee);
        } else {
            fee = FHE.asEuint64(0);
            netAmount = amountB;
        }

        // Calculate output: netAmount * rateDenominator / rateNumerator (inverse)
        euint64 amountA;
        if (rateNumerator != rateDenominator) {
            amountA = FHE.div(
                FHE.mul(netAmount, uint64(rateDenominator)),
                uint64(rateNumerator)
            );
        } else {
            amountA = netAmount;
        }

        // Pull TokenB from user to this contract
        FHE.allowTransient(amountB, address(tokenB));
        tokenB.confidentialTransferFrom(msg.sender, address(this), amountB);

        // Send TokenA from this contract to user
        FHE.allowTransient(amountA, address(tokenA));
        tokenA.confidentialTransfer(msg.sender, amountA);

        // Accumulate fees
        if (feeDivisor > 0) {
            collectedFeesB = FHE.add(collectedFeesB, fee);
            FHE.allowThis(collectedFeesB);
            FHE.allow(collectedFeesB, owner());
        }

        emit SwapExecuted(msg.sender, false);
    }

    // ─── Admin: Add Liquidity ─────────────────────────────────────────
    /// @notice Owner deposits TokenA reserves. Must setOperator first.
    function addLiquidityA(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        FHE.allowTransient(amount, address(tokenA));
        tokenA.confidentialTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Owner deposits TokenB reserves. Must setOperator first.
    function addLiquidityB(
        externalEuint64 encAmount,
        bytes calldata inputProof
    ) external onlyOwner {
        euint64 amount = FHE.fromExternal(encAmount, inputProof);
        FHE.allowTransient(amount, address(tokenB));
        tokenB.confidentialTransferFrom(msg.sender, address(this), amount);
    }

    // ─── Admin: Withdraw Fees ─────────────────────────────────────────
    /// @notice Owner withdraws accumulated TokenA fees.
    function withdrawFeesA(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        FHE.allowTransient(collectedFeesA, address(tokenA));
        tokenA.confidentialTransfer(to, collectedFeesA);

        // Reset fee counter
        collectedFeesA = FHE.asEuint64(0);
        FHE.allowThis(collectedFeesA);

        emit FeesWithdrawn(address(tokenA), to);
    }

    /// @notice Owner withdraws accumulated TokenB fees.
    function withdrawFeesB(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        FHE.allowTransient(collectedFeesB, address(tokenB));
        tokenB.confidentialTransfer(to, collectedFeesB);

        // Reset fee counter
        collectedFeesB = FHE.asEuint64(0);
        FHE.allowThis(collectedFeesB);

        emit FeesWithdrawn(address(tokenB), to);
    }

    // ─── Admin: Rate & Fee Management ─────────────────────────────────
    function setRate(uint64 numerator, uint64 denominator) external onlyOwner {
        if (numerator == 0 || denominator == 0) revert InvalidRate();
        rateNumerator = numerator;
        rateDenominator = denominator;
        emit RateUpdated(numerator, denominator);
    }

    function setFeeDivisor(uint64 newFeeDivisor) external onlyOwner {
        feeDivisor = newFeeDivisor;
        emit FeeUpdated(newFeeDivisor);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }
}
