// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, externalEuint64, ebool} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {IERC7984} from "@openzeppelin/confidential-contracts/interfaces/IERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ConfidentialAMM — single-pair constant-product AMM for ERC-7984 tokens.
/// @notice Reserves are encrypted (TVL hidden by default; toggle via revealReserves).
///         Total LP supply is plaintext (per common-pitfalls.md §11b: "keep LP
///         shares or divisors as plaintext" — encrypted-by-encrypted division
///         is unsupported by the FHE library).
///
///         Per-user LP balances are encrypted. Fees (0.3%) are accumulated as
///         encrypted handles withdrawable by the owner. Swap math follows
///         Uniswap-V2 style:
///
///             amountInWithFee = amountIn * 997
///             amountOut       = (reserveOut * amountInWithFee)
///                             / (reserveIn * 1000 + amountInWithFee)
///
///         Because the FHE library has no encrypted-by-encrypted division, the
///         **caller** computes `expectedAmountOut` off-chain (after they user-decrypt the
///         reserve handles via `allowReservesTo` / `revealReserves`) and passes
///         the encrypted expectation in. The contract validates the constant-
///         product invariant entirely in the encrypted domain via `FHE.select`:
///
///             ok = (reserveIn + amountInAfterFee) * (reserveOut - expectedAmountOut)
///                  >= reserveIn * reserveOut
///
///         If `ok` is false, the swap silently outputs 0 and refunds the full
///         `amountIn` — preserving the no-revert-on-confidential-failure
///         guarantee (see SKILL.md Battle Scar #1 + Pattern 2).
///
///         Use this template as a starting point for any custom-pair confidential
///         AMM. For volume DEX deployments, lift to `euint128` reserves to widen
///         the multiplicative-invariant overflow envelope.
contract ConfidentialAMM is ZamaEthereumConfig, Ownable2Step {
    // ─── Immutable token pair ─────────────────────────────────────────
    IERC7984 public immutable tokenA;
    IERC7984 public immutable tokenB;

    // ─── Encrypted reserves (TVL hidden, ACL grants on-demand) ───────
    euint64 internal _reserveA;
    euint64 internal _reserveB;

    // ─── LP accounting ───────────────────────────────────────────────
    /// @notice Total LP supply — PLAINTEXT, per skill guidance (encrypted/
    ///         encrypted division is impossible). Exposes how many LP "tickets"
    ///         exist, NOT the underlying token amounts.
    uint64 public totalLPShares;
    /// @notice Per-LP balance of shares, encrypted.
    mapping(address => euint64) internal _lpShares;

    // ─── Fees (encrypted, owner-withdrawable) ────────────────────────
    euint64 internal _feeA;
    euint64 internal _feeB;

    // ─── Constants ───────────────────────────────────────────────────
    /// @notice 0.3% swap fee. Numerator/denominator pair to avoid an
    ///         encrypted divisor (skill self-correction table).
    uint64 public constant FEE_NUM = 997;
    uint64 public constant FEE_DEN = 1000;

    // ─── Events ──────────────────────────────────────────────────────
    event LiquidityAdded(address indexed provider, uint64 sharesMinted);
    event LiquidityRemoved(address indexed provider, uint64 sharesBurned);
    event Swapped(address indexed trader, bool indexed aToB);
    event FeesWithdrawn(address indexed token, address indexed to);

    // ─── Errors ──────────────────────────────────────────────────────
    error ZeroAddress();
    error ZeroShares();
    error PoolNotInitialized();
    error PoolAlreadyInitialized();

    constructor(address tokenA_, address tokenB_, address owner_)
        Ownable(owner_)
    {
        if (tokenA_ == address(0) || tokenB_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        tokenA = IERC7984(tokenA_);
        tokenB = IERC7984(tokenB_);

        // Constructor-init handles to the zero ciphertext so subsequent FHE.add
        // calls have a valid handle to read from. See testing-guide.md
        // "Constructor-Initialized Handles".
        _reserveA = FHE.asEuint64(0);
        _reserveB = FHE.asEuint64(0);
        _feeA = FHE.asEuint64(0);
        _feeB = FHE.asEuint64(0);

        // Persist contract ACL — required after every state-storing FHE op
        // (SKILL.md Pattern 1 "ACL Triple").
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allowThis(_feeA);
        FHE.allowThis(_feeB);
    }

    // ─── Views ───────────────────────────────────────────────────────
    function getReserves() external view returns (euint64, euint64) {
        return (_reserveA, _reserveB);
    }

    function lpSharesOf(address provider) external view returns (euint64) {
        return _lpShares[provider];
    }

    function getFees() external view returns (euint64, euint64) {
        return (_feeA, _feeB);
    }

    // ─── Init: first-add (owner) ─────────────────────────────────────
    /// @notice Seed the pool with initial encrypted reserves and bootstrap
    ///         `initialShares` LP tokens to the caller. Sets the initial price.
    /// @dev    User must `setOperator(amm, expiry)` on BOTH tokens beforehand.
    function initialize(
        externalEuint64 encAmountA,
        externalEuint64 encAmountB,
        uint64 initialShares,
        bytes calldata inputProof
    ) external onlyOwner {
        if (totalLPShares != 0) revert PoolAlreadyInitialized();
        if (initialShares == 0) revert ZeroShares();

        euint64 amountA = FHE.fromExternal(encAmountA, inputProof);
        euint64 amountB = FHE.fromExternal(encAmountB, inputProof);

        _pullA(msg.sender, amountA);
        _pullB(msg.sender, amountB);

        _reserveA = FHE.add(_reserveA, amountA);
        _reserveB = FHE.add(_reserveB, amountB);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        // Owner can decrypt reserves so they can compute fair swap quotes.
        FHE.allow(_reserveA, owner());
        FHE.allow(_reserveB, owner());

        totalLPShares = initialShares;
        euint64 minted = FHE.asEuint64(initialShares);
        _lpShares[msg.sender] = minted;
        FHE.allowThis(_lpShares[msg.sender]);
        FHE.allow(_lpShares[msg.sender], msg.sender);

        emit LiquidityAdded(msg.sender, initialShares);
    }

    // ─── Add liquidity (post-init) ───────────────────────────────────
    /// @notice Add liquidity at the current pool ratio. The caller computes
    ///         `sharesToMint` off-chain from the (publicly-decryptable, ACL-gated)
    ///         reserves: `sharesToMint = totalLPShares * amountA / reserveA`.
    function addLiquidity(
        externalEuint64 encAmountA,
        externalEuint64 encAmountB,
        uint64 sharesToMint,
        bytes calldata inputProof
    ) external {
        if (totalLPShares == 0) revert PoolNotInitialized();
        if (sharesToMint == 0) revert ZeroShares();

        euint64 amountA = FHE.fromExternal(encAmountA, inputProof);
        euint64 amountB = FHE.fromExternal(encAmountB, inputProof);

        _pullA(msg.sender, amountA);
        _pullB(msg.sender, amountB);

        _reserveA = FHE.add(_reserveA, amountA);
        _reserveB = FHE.add(_reserveB, amountB);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allow(_reserveA, owner());
        FHE.allow(_reserveB, owner());

        totalLPShares += sharesToMint;
        // Lazy-init mapping pattern (acl-patterns.md "Lazy-Init Mapping Handles")
        euint64 prev = _lpShares[msg.sender];
        if (!FHE.isInitialized(prev)) {
            prev = FHE.asEuint64(0);
        }
        euint64 newShares = FHE.add(prev, FHE.asEuint64(sharesToMint));
        _lpShares[msg.sender] = newShares;
        FHE.allowThis(newShares);
        FHE.allow(newShares, msg.sender);

        emit LiquidityAdded(msg.sender, sharesToMint);
    }

    // ─── Remove liquidity ────────────────────────────────────────────
    /// @notice Burn `sharesToBurn` (plaintext) and withdraw a pro-rata share
    ///         of the encrypted reserves.
    function removeLiquidity(uint64 sharesToBurn) external {
        if (sharesToBurn == 0) revert ZeroShares();
        if (totalLPShares == 0) revert PoolNotInitialized();
        require(sharesToBurn <= totalLPShares, "shares > total");

        // Encrypted balance check: did the user have at least that many shares?
        euint64 encBurn = FHE.asEuint64(sharesToBurn);
        euint64 currentShares = _lpShares[msg.sender];
        require(FHE.isInitialized(currentShares), "no shares");
        ebool sufficient = FHE.le(encBurn, currentShares);
        // Silent-truncate pattern (SKILL.md Pattern 2). If user lied, they get 0.
        euint64 actualBurn = FHE.select(sufficient, encBurn, FHE.asEuint64(0));

        // Pro-rata payout. reserveX * sharesToBurn / totalLPShares.
        // Both sharesToBurn and totalLPShares are plaintext — `FHE.mul(enc,uintX)`
        // and `FHE.div(enc,uintX)` are the supported overloads.
        euint64 outA = FHE.div(FHE.mul(_reserveA, sharesToBurn), totalLPShares);
        euint64 outB = FHE.div(FHE.mul(_reserveB, sharesToBurn), totalLPShares);

        // If the user lied about their share count, they should still get 0.
        outA = FHE.select(sufficient, outA, FHE.asEuint64(0));
        outB = FHE.select(sufficient, outB, FHE.asEuint64(0));

        _reserveA = FHE.sub(_reserveA, outA);
        _reserveB = FHE.sub(_reserveB, outB);
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allow(_reserveA, owner());
        FHE.allow(_reserveB, owner());

        // Burn the encrypted shares.
        euint64 newShares = FHE.sub(currentShares, actualBurn);
        _lpShares[msg.sender] = newShares;
        FHE.allowThis(newShares);
        FHE.allow(newShares, msg.sender);

        // Plaintext supply drops; lying users self-rug their token output.
        totalLPShares -= sharesToBurn;

        _pushA(msg.sender, outA);
        _pushB(msg.sender, outB);

        emit LiquidityRemoved(msg.sender, sharesToBurn);
    }

    // ─── Swap A → B (or B → A) ───────────────────────────────────────
    /// @param encAmountIn        Encrypted token-in amount.
    /// @param expectedAmountOut  Caller's pre-computed amountOut. Must satisfy
    ///                           the constant-product invariant after fee, or
    ///                           the swap silently returns 0 and refunds.
    /// @param inputProof         Single proof for both encrypted handles.
    function swap(
        externalEuint64 encAmountIn,
        externalEuint64 expectedAmountOut,
        bool isAtoB,
        bytes calldata inputProof
    ) external {
        euint64 amountIn = FHE.fromExternal(encAmountIn, inputProof);
        euint64 amountOut = FHE.fromExternal(expectedAmountOut, inputProof);

        // Apply 0.3% fee. amountInAfterFee = amountIn * FEE_NUM / FEE_DEN.
        euint64 amountInAfterFee = FHE.div(FHE.mul(amountIn, FEE_NUM), FEE_DEN);
        euint64 fee = FHE.sub(amountIn, amountInAfterFee);

        // Pull amountIn (full, including fee) from the trader.
        if (isAtoB) {
            _pullA(msg.sender, amountIn);
        } else {
            _pullB(msg.sender, amountIn);
        }

        // Constant-product invariant check in encrypted domain:
        //   (reserveIn + amountInAfterFee) * (reserveOut - amountOut)
        //   >= reserveIn * reserveOut
        euint64 reserveIn = isAtoB ? _reserveA : _reserveB;
        euint64 reserveOut = isAtoB ? _reserveB : _reserveA;

        euint64 newReserveIn = FHE.add(reserveIn, amountInAfterFee);
        euint64 newReserveOut = FHE.sub(reserveOut, amountOut);

        // ⚠ common-pitfalls.md §11b: mul(enc,enc) overflows above ~sqrt(euint64-max)
        // ≈ 4.3 × 10⁹. For production volume DEXes, lift this template to
        // `euint128` reserves and a euint128 `newK`/`oldK`.
        euint64 newK = FHE.mul(newReserveIn, newReserveOut);
        euint64 oldK = FHE.mul(reserveIn, reserveOut);
        ebool ok = FHE.ge(newK, oldK);

        // Gate the trade: if invariant fails (caller cheated on amountOut),
        // both legs become 0. Refund full amountIn so the trader is whole.
        // The fee is also gated to 0 — caller burned gas only.
        euint64 gatedOut = FHE.select(ok, amountOut, FHE.asEuint64(0));
        euint64 gatedInAfterFee = FHE.select(ok, amountInAfterFee, FHE.asEuint64(0));
        euint64 gatedFee = FHE.select(ok, fee, FHE.asEuint64(0));
        euint64 refund = FHE.select(ok, FHE.asEuint64(0), amountIn);

        // Update reserves
        if (isAtoB) {
            _reserveA = FHE.add(_reserveA, gatedInAfterFee);
            _reserveB = FHE.sub(_reserveB, gatedOut);
            _feeA = FHE.add(_feeA, gatedFee);
            FHE.allowThis(_feeA);
            FHE.allow(_feeA, owner());
            _pushB(msg.sender, gatedOut);
            _pushA(msg.sender, refund);
        } else {
            _reserveB = FHE.add(_reserveB, gatedInAfterFee);
            _reserveA = FHE.sub(_reserveA, gatedOut);
            _feeB = FHE.add(_feeB, gatedFee);
            FHE.allowThis(_feeB);
            FHE.allow(_feeB, owner());
            _pushA(msg.sender, gatedOut);
            _pushB(msg.sender, refund);
        }
        FHE.allowThis(_reserveA);
        FHE.allowThis(_reserveB);
        FHE.allow(_reserveA, owner());
        FHE.allow(_reserveB, owner());

        emit Swapped(msg.sender, isAtoB);
    }

    // ─── Owner: withdraw fees ────────────────────────────────────────
    function withdrawFees(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _pushA(to, _feeA);
        _pushB(to, _feeB);
        _feeA = FHE.asEuint64(0);
        _feeB = FHE.asEuint64(0);
        FHE.allowThis(_feeA);
        FHE.allowThis(_feeB);
        emit FeesWithdrawn(address(tokenA), to);
        emit FeesWithdrawn(address(tokenB), to);
    }

    // ─── Owner: hand out ACL grants on reserves (TVL UX) ─────────────
    /// @notice Make reserve handles publicly decryptable so the frontend can
    ///         fetch TVL once owner explicitly opts in. By default reserves
    ///         stay owner-only. See acl-patterns.md "Publicly-Readable,
    ///         ACL-Gated Pattern".
    function revealReserves() external onlyOwner {
        FHE.makePubliclyDecryptable(_reserveA);
        FHE.makePubliclyDecryptable(_reserveB);
    }

    /// @notice Grant a specific user (e.g. an LP who needs fair-ratio adds)
    ///         persistent decryption rights on the reserves.
    function allowReservesTo(address user) external onlyOwner {
        FHE.allow(_reserveA, user);
        FHE.allow(_reserveB, user);
    }

    // ─── Internal: token pull/push helpers ───────────────────────────
    function _pullA(address from, euint64 amount) internal {
        FHE.allowTransient(amount, address(tokenA));
        tokenA.confidentialTransferFrom(from, address(this), amount);
    }

    function _pullB(address from, euint64 amount) internal {
        FHE.allowTransient(amount, address(tokenB));
        tokenB.confidentialTransferFrom(from, address(this), amount);
    }

    function _pushA(address to, euint64 amount) internal {
        FHE.allowTransient(amount, address(tokenA));
        tokenA.confidentialTransfer(to, amount);
    }

    function _pushB(address to, euint64 amount) internal {
        FHE.allowTransient(amount, address(tokenB));
        tokenB.confidentialTransfer(to, amount);
    }
}
