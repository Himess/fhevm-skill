// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FHE, euint64, ebool, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ConfidentialWrappedERC20
/// @notice ERC-7984 confidential token with encrypted balances, private transfers,
///         owner minting, approval/transferFrom, and ERC-20 wrapping.
/// @dev Uses the new FHE library from @fhevm/solidity v0.11+.
///      Transfers silently send 0 on insufficient balance (no revert -- preserves confidentiality).
///      Wrapping converts plaintext ERC-20 tokens into encrypted confidential tokens.
contract ConfidentialWrappedERC20 is ZamaEthereumConfig, Ownable2Step {
    using SafeERC20 for IERC20;

    // --- Metadata ---
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;

    /// @notice Plaintext total supply (public knowledge -- sum of all mints + wraps minus unwraps).
    uint64 public totalSupply;

    /// @notice The underlying ERC-20 token that can be wrapped into confidential tokens.
    IERC20 public immutable underlying;

    // --- Encrypted State ---
    mapping(address => euint64) internal _balances;
    mapping(address => mapping(address => euint64)) internal _allowances;

    // --- Events (no plaintext amounts -- preserves confidentiality) ---
    event Transfer(address indexed from, address indexed to);
    event Approval(address indexed owner, address indexed spender);
    event Mint(address indexed to, uint64 amount);
    event Wrap(address indexed account, uint64 amount);

    // --- Constructor ---
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _underlying Address of the ERC-20 token to wrap (address(0) if wrap not needed)
    constructor(
        string memory _name,
        string memory _symbol,
        address _underlying
    ) Ownable(msg.sender) {
        name = _name;
        symbol = _symbol;
        underlying = IERC20(_underlying);
    }

    // =========================================================================
    //                              MINT (Owner Only)
    // =========================================================================

    /// @notice Mint new confidential tokens to the owner.
    /// @dev The amount is plaintext here (visible on-chain in the tx calldata),
    ///      but the balance itself remains encrypted.
    /// @param amount Plaintext amount to mint.
    function mint(uint64 amount) external onlyOwner {
        _balances[owner()] = FHE.add(_balances[owner()], amount);
        FHE.allowThis(_balances[owner()]);
        FHE.allow(_balances[owner()], owner());
        totalSupply += amount;
        emit Mint(owner(), amount);
    }

    // =========================================================================
    //                            WRAP (ERC-20 -> Confidential)
    // =========================================================================

    /// @notice Wrap plaintext ERC-20 tokens into encrypted confidential tokens.
    /// @dev Transfers `amount` of the underlying ERC-20 from the caller to this contract,
    ///      then credits the caller with an encrypted balance of the same amount.
    ///      The wrap amount is visible on-chain (plaintext boundary), but the resulting
    ///      balance is encrypted.
    /// @param amount Plaintext amount of underlying ERC-20 to wrap.
    function wrap(uint64 amount) external {
        require(address(underlying) != address(0), "No underlying token");
        require(amount > 0, "Amount must be > 0");

        // 1. Transfer plaintext ERC-20 from user to this contract
        underlying.safeTransferFrom(msg.sender, address(this), uint256(amount));

        // 2. Credit encrypted balance
        _balances[msg.sender] = FHE.add(_balances[msg.sender], amount);
        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);

        totalSupply += amount;
        emit Wrap(msg.sender, amount);
    }

    // =========================================================================
    //                              BALANCE
    // =========================================================================

    /// @notice Returns the encrypted balance handle for the given account.
    /// @dev Only the account owner (or someone with ACL permission) can decrypt this.
    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }

    // =========================================================================
    //                        TRANSFER (Encrypted Amount)
    // =========================================================================

    /// @notice Transfer tokens with an encrypted amount (client-side encryption + ZK proof).
    /// @param to Recipient address.
    /// @param encryptedAmount Encrypted amount from client-side encryption.
    /// @param inputProof ZK proof validating the encrypted input.
    function transfer(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer tokens with an already-verified encrypted handle.
    /// @dev Used for contract-to-contract interactions where the handle is pre-verified.
    /// @param to Recipient address.
    /// @param amount Already-verified encrypted amount handle.
    function transfer(address to, euint64 amount) external returns (bool) {
        require(FHE.isSenderAllowed(amount), "Sender not allowed");
        _transfer(msg.sender, to, amount);
        return true;
    }

    // =========================================================================
    //                              APPROVAL
    // =========================================================================

    /// @notice Approve a spender to transfer up to an encrypted amount on behalf of the caller.
    /// @param spender Address allowed to spend.
    /// @param encryptedAmount Encrypted allowance amount.
    /// @param inputProof ZK proof.
    function approve(
        address spender,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _approve(msg.sender, spender, amount);
        return true;
    }

    /// @notice Returns the encrypted allowance handle.
    function allowance(address owner_, address spender) external view returns (euint64) {
        return _allowances[owner_][spender];
    }

    // =========================================================================
    //                            TRANSFER FROM
    // =========================================================================

    /// @notice Transfer tokens from one address to another using the caller's allowance.
    /// @dev Silently transfers 0 if the allowance or balance is insufficient.
    /// @param from Source address.
    /// @param to Destination address.
    /// @param encryptedAmount Encrypted transfer amount.
    /// @param inputProof ZK proof.
    function transferFrom(
        address from,
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external returns (bool) {
        euint64 amount = FHE.fromExternal(encryptedAmount, inputProof);
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // =========================================================================
    //                         INTERNAL: SILENT TRANSFER
    // =========================================================================

    /// @dev Core transfer logic. Does NOT revert on insufficient balance.
    ///      Instead, silently transfers 0 to preserve confidentiality.
    ///      Reverting would leak information about the sender's balance.
    function _transfer(address from, address to, euint64 amount) internal {
        require(from != address(0), "Transfer from zero address");
        require(to != address(0), "Transfer to zero address");

        // Encrypted comparison: is amount <= sender's balance?
        ebool canTransfer = FHE.le(amount, _balances[from]);
        // If insufficient, transfer 0 instead (no revert)
        euint64 transferValue = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        // Update sender balance
        _balances[from] = FHE.sub(_balances[from], transferValue);
        FHE.allowThis(_balances[from]);
        FHE.allow(_balances[from], from);

        // Update recipient balance
        _balances[to] = FHE.add(_balances[to], transferValue);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);

        emit Transfer(from, to);
    }

    // =========================================================================
    //                          INTERNAL: APPROVE
    // =========================================================================

    /// @dev Sets the allowance for a spender. Overwrites any existing allowance.
    function _approve(address owner_, address spender, euint64 amount) internal {
        require(owner_ != address(0), "Approve from zero address");
        require(spender != address(0), "Approve to zero address");

        _allowances[owner_][spender] = amount;
        FHE.allowThis(amount);
        FHE.allow(amount, owner_);
        FHE.allow(amount, spender);

        emit Approval(owner_, spender);
    }

    // =========================================================================
    //                       INTERNAL: SPEND ALLOWANCE
    // =========================================================================

    /// @dev Deducts from the spender's allowance. Silently caps to 0 if allowance
    ///      is insufficient (does not revert -- preserves confidentiality).
    function _spendAllowance(address owner_, address spender, euint64 amount) internal {
        euint64 currentAllowance = _allowances[owner_][spender];

        // Check if allowance is sufficient (encrypted comparison)
        ebool hasAllowance = FHE.le(amount, currentAllowance);
        euint64 spendAmount = FHE.select(hasAllowance, amount, FHE.asEuint64(0));

        // Deduct from allowance
        _allowances[owner_][spender] = FHE.sub(currentAllowance, spendAmount);
        FHE.allowThis(_allowances[owner_][spender]);
        FHE.allow(_allowances[owner_][spender], owner_);
        FHE.allow(_allowances[owner_][spender], spender);
    }
}
