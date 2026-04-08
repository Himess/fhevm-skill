#!/bin/bash
# FHEVM Contract Validator
# Checks Solidity contracts for common FHEVM mistakes before deployment.
# Usage: ./validate-fhevm.sh [directory]
#
# Exit codes:
#   0 - All checks passed
#   1 - Warnings found (review recommended)
#   2 - Errors found (must fix before deployment)

set -euo pipefail

DIR="${1:-.}"
ERRORS=0
WARNINGS=0
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "=== FHEVM Contract Validator ==="
echo "Scanning: $DIR"
echo ""

# Find all Solidity files
SOLFILES=$(find "$DIR" -name "*.sol" -not -path "*/node_modules/*" -not -path "*/lib/*" -not -path "*/artifacts/*" -not -path "*/cache/*" 2>/dev/null || true)

if [ -z "$SOLFILES" ]; then
    echo "No Solidity files found in $DIR"
    exit 0
fi

FILE_COUNT=$(echo "$SOLFILES" | wc -l | tr -d ' ')
echo "Found $FILE_COUNT Solidity files"
echo ""

# ─── Check 1: Deprecated TFHE library usage ──────────────────────────
echo "--- Check 1: Deprecated TFHE library ---"
TFHE_FILES=$(grep -rl 'import.*"fhevm/lib/TFHE.sol"' $SOLFILES 2>/dev/null || true)
if [ -n "$TFHE_FILES" ]; then
    echo -e "${YELLOW}WARNING: Files using deprecated TFHE library (use @fhevm/solidity/lib/FHE.sol instead):${NC}"
    echo "$TFHE_FILES" | while read -r f; do echo "  - $f"; done
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${GREEN}PASS: No deprecated TFHE imports found${NC}"
fi
echo ""

# ─── Check 2: Missing FHE.allowThis() after FHE operations ──────────
echo "--- Check 2: Missing FHE.allowThis() ---"
for file in $SOLFILES; do
    # Count FHE state-changing operations (add, sub, mul, select, fromExternal)
    OPS=$(grep -c 'FHE\.\(add\|sub\|mul\|div\|rem\|select\|fromExternal\|min\|max\|and\|or\|xor\|not\|neg\|asEuint\|asEbool\|asEaddress\|randE\)' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    ALLOWS=$(grep -c 'FHE\.allowThis' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Skip contracts extending ERC7984 (ACL handled by base class)
    EXTENDS_ERC7984=$(grep -c 'ERC7984' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")

    if [ "$OPS" -gt 0 ] && [ "$ALLOWS" -eq 0 ] && [ "$EXTENDS_ERC7984" -eq 0 ]; then
        echo -e "${RED}ERROR: $file has $OPS FHE operations but NO FHE.allowThis() calls${NC}"
        ERRORS=$((ERRORS + 1))
    elif [ "$OPS" -gt 0 ] && [ "$ALLOWS" -eq 0 ] && [ "$EXTENDS_ERC7984" -gt 0 ]; then
        echo -e "${GREEN}OK: $file extends ERC7984 (ACL handled by base class)${NC}"
    elif [ "$OPS" -gt 0 ] && [ "$ALLOWS" -lt "$OPS" ]; then
        # Not all operations need allowThis (e.g., temporary values), so just warn
        echo -e "${YELLOW}WARNING: $file has $OPS FHE operations but only $ALLOWS FHE.allowThis() calls${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# ─── Check 3: Division by encrypted value ────────────────────────────
echo "--- Check 3: Division by encrypted value ---"
for file in $SOLFILES; do
    # Look for FHE.div with encrypted second argument (euintXX variable)
    BAD_DIV=$(grep -n 'FHE\.div(.*,\s*\(e\|_e\)' "$file" 2>/dev/null || true)
    if [ -n "$BAD_DIV" ]; then
        echo -e "${RED}ERROR: $file may divide by encrypted value (FHE.div requires plaintext divisor):${NC}"
        echo "$BAD_DIV" | while read -r line; do echo "  $line"; done
        ERRORS=$((ERRORS + 1))
    fi
done
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}PASS: No encrypted divisors found${NC}"
fi
echo ""

# ─── Check 4: if/require with encrypted booleans ─────────────────────
echo "--- Check 4: Branching on encrypted values ---"
for file in $SOLFILES; do
    # Check for if(FHE. or require(FHE. patterns
    BAD_BRANCH=$(grep -n '\(if\|require\|assert\)\s*(.*FHE\.\(eq\|ne\|gt\|ge\|lt\|le\|select\)' "$file" 2>/dev/null || true)
    if [ -n "$BAD_BRANCH" ]; then
        echo -e "${RED}ERROR: $file may branch on encrypted values (use FHE.select instead):${NC}"
        echo "$BAD_BRANCH" | while read -r line; do echo "  $line"; done
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# ─── Check 5: Missing ZamaEthereumConfig ─────────────────────────────
echo "--- Check 5: FHE Configuration ---"
for file in $SOLFILES; do
    USES_FHE=$(grep -c 'FHE\.' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    HAS_CONFIG=$(grep -c '\(ZamaEthereumConfig\|FHE\.setCoprocessor\|SepoliaZamaFHEVMConfig\)' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    IS_INTERFACE=$(grep -c '^\s*\(interface\|library\|abstract\)' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")

    if [ "$USES_FHE" -gt 0 ] && [ "$HAS_CONFIG" -eq 0 ] && [ "$IS_INTERFACE" -eq 0 ]; then
        echo -e "${YELLOW}WARNING: $file uses FHE but doesn't inherit ZamaEthereumConfig or call FHE.setCoprocessor()${NC}"
        WARNINGS=$((WARNINGS + 1))
    fi
done
echo ""

# ─── Check 6: evmVersion in hardhat config ───────────────────────────
echo "--- Check 6: Hardhat evmVersion ---"
HARDHAT_CONFIG=$(find "$DIR" -name "hardhat.config.*" -not -path "*/node_modules/*" 2>/dev/null | head -1)
if [ -n "$HARDHAT_CONFIG" ]; then
    HAS_CANCUN=$(grep -c 'cancun' "$HARDHAT_CONFIG" 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$HAS_CANCUN" -eq 0 ]; then
        echo -e "${RED}ERROR: $HARDHAT_CONFIG does not set evmVersion to 'cancun' (required for FHE.allowTransient)${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}PASS: evmVersion is set to cancun${NC}"
    fi
else
    echo -e "${YELLOW}WARNING: No hardhat.config found${NC}"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ─── Check 7: Random in view functions ───────────────────────────────
echo "--- Check 7: Random in view functions ---"
for file in $SOLFILES; do
    # Simplified check: look for randE in view/pure functions
    BAD_RAND=$(grep -B5 'FHE\.rand' "$file" 2>/dev/null | grep -l '\(view\|pure\)' 2>/dev/null || true)
    if [ -n "$BAD_RAND" ]; then
        echo -e "${RED}ERROR: $file may use FHE.rand* in a view/pure function (requires state mutation)${NC}"
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# ─── Check 8: Deprecated Gateway usage ───────────────────────────────
echo "--- Check 8: Deprecated Gateway pattern ---"
GATEWAY_FILES=$(grep -rl 'Gateway\.\(requestDecryption\|loadRequestedHandles\)\|GatewayCaller' $SOLFILES 2>/dev/null || true)
if [ -n "$GATEWAY_FILES" ]; then
    echo -e "${YELLOW}WARNING: Files using deprecated Gateway pattern (use FHE.makePubliclyDecryptable + checkSignatures):${NC}"
    echo "$GATEWAY_FILES" | while read -r f; do echo "  - $f"; done
    WARNINGS=$((WARNINGS + 1))
else
    echo -e "${GREEN}PASS: No deprecated Gateway usage found${NC}"
fi
echo ""

# ─── Check 9: Events emitting potential plaintext ─────────────────────
echo "--- Check 9: Event data leakage ---"
for file in $SOLFILES; do
    # Look for events with uint parameters in files that also use FHE
    USES_FHE=$(grep -c 'FHE\.' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$USES_FHE" -gt 0 ]; then
        EMIT_UINT=$(grep -n 'emit.*uint' "$file" 2>/dev/null || true)
        if [ -n "$EMIT_UINT" ]; then
            echo -e "${YELLOW}INFO: $file emits events with uint — verify no encrypted values are leaked:${NC}"
            echo "$EMIT_UINT" | head -3 | while read -r line; do echo "  $line"; done
        fi
    fi
done
echo ""

# ─── Check 10: euint256 with ordering comparisons ────────────────────
echo "--- Check 10: euint256 ordering comparisons ---"
for file in $SOLFILES; do
    HAS_256=$(grep -c 'euint256' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$HAS_256" -gt 0 ]; then
        BAD_CMP=$(grep -n 'FHE\.\(gt\|lt\|ge\|le\).*256' "$file" 2>/dev/null || true)
        if [ -n "$BAD_CMP" ]; then
            echo -e "${RED}ERROR: $file uses ordering comparison on euint256 (only eq/ne supported):${NC}"
            echo "$BAD_CMP" | while read -r line; do echo "  $line"; done
            ERRORS=$((ERRORS + 1))
        fi
    fi
done
echo ""

# ─── Check 11: Hallucinated functions ────────────────────────────────
echo "--- Check 11: Non-existent FHE functions ---"
for file in $SOLFILES; do
    BAD_FN=$(grep -n 'FHE\.\(decrypt\|safeAdd\|safeSub\|safeMul\|allowForDecryption\|sealoutput\|isIn\)' "$file" 2>/dev/null || true)
    if [ -n "$BAD_FN" ]; then
        echo -e "${RED}ERROR: $file uses non-existent FHE functions:${NC}"
        echo "$BAD_FN" | while read -r line; do echo "  $line"; done
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# ─── Check 12: Non-existent types ────────────────────────────────────
echo "--- Check 12: Non-existent encrypted types ---"
for file in $SOLFILES; do
    BAD_TYPE=$(grep -n '\(ebytes\|eint8\|eint16\|eint32\|eint64\|eint128\)[^a-zA-Z0-9]' "$file" 2>/dev/null || true)
    if [ -n "$BAD_TYPE" ]; then
        echo -e "${RED}ERROR: $file uses non-existent encrypted types (ebytes/eint do not exist):${NC}"
        echo "$BAD_TYPE" | while read -r line; do echo "  $line"; done
        ERRORS=$((ERRORS + 1))
    fi
done
echo ""

# ─── Summary ─────────────────────────────────────────────────────────
echo "=== SUMMARY ==="
echo -e "Errors:   ${RED}$ERRORS${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}Fix errors before deploying!${NC}"
    exit 2
elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "${YELLOW}Review warnings before deploying.${NC}"
    exit 1
else
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
fi
