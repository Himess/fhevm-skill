// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {FHE, euint64, externalEuint64} from "@fhevm/solidity/lib/FHE.sol";
import {ZamaEthereumConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ERC7984} from "@openzeppelin/confidential-contracts/token/ERC7984/ERC7984.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ConfidentialToken — ERC-7984 Token Template
/// @notice Extends OpenZeppelin ERC7984 base contract with owner-controlled minting.
/// ERC-7984 uses confidentialTransfer/confidentialBalanceOf (NOT ERC-20 names).
/// Operator model (setOperator + time-based expiry) replaces ERC-20 approval/allowance.
/// Transfers silently send 0 on insufficient balance (no revert — preserves privacy).
/// Default decimals: 6 (euint64 max = ~18.4e18, sufficient for 6-decimal tokens).
/// Setup: npm install openzeppelin/confidential-contracts fhevm/solidity openzeppelin/contracts
contract ConfidentialToken is ZamaEthereumConfig, ERC7984, Ownable2Step {
    constructor(
        address owner_,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
    ) ERC7984(name_, symbol_, contractURI_) Ownable(owner_) {}

    // ─── Mint (plaintext amount → encrypted internally) ───────────────
    function mint(address to, uint64 amount) external onlyOwner {
        _mint(to, FHE.asEuint64(amount));
    }

    // ─── Mint with encrypted amount ───────────────────────────────────
    function confidentialMint(
        address to,
        externalEuint64 encryptedAmount,
        bytes calldata inputProof
    ) external onlyOwner returns (euint64 transferred) {
        return _mint(to, FHE.fromExternal(encryptedAmount, inputProof));
    }

    // ─── Burn ─────────────────────────────────────────────────────────
    function burn(address from, uint64 amount) external onlyOwner {
        _burn(from, FHE.asEuint64(amount));
    }
}

// ─── Usage Notes ────────────────────────────────────────────────────
//
// ERC-7984 functions inherited from ERC7984 base:
//   confidentialTransfer(address to, externalEuint64 amount, bytes proof) → euint64
//   confidentialTransfer(address to, euint64 amount) → euint64
//   confidentialTransferFrom(address from, address to, externalEuint64 amount, bytes proof) → euint64
//   confidentialTransferFrom(address from, address to, euint64 amount) → euint64
//   confidentialTransferAndCall(address to, euint64 amount, bytes data) → euint64
//   confidentialBalanceOf(address account) → euint64
//   confidentialTotalSupply() → euint64
//   setOperator(address operator, uint48 until)  — time-based, NOT amount-based
//   isOperator(address holder, address spender) → bool
//   name(), symbol(), decimals() (default 6), contractURI()
//
// Events:
//   ConfidentialTransfer(address indexed from, address indexed to, euint64 indexed amount)
//   OperatorSet(address indexed holder, address indexed operator, uint48 until)
//   AmountDisclosed(euint64 indexed encryptedAmount, uint64 amount)
//
// Key differences from ERC-20:
//   - NO approve/allowance — uses operator model (setOperator with expiry timestamp)
//   - Transfers return euint64 (the actual transferred amount), NOT bool
//   - Silent failure: insufficient balance → transfers 0 (no revert)
//   - Balances are euint64 (encrypted), view functions return handles
//   - Default decimals = 6 (not 18)
