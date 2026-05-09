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
# Only flag if a file uses state-mutating FHE ops AND has zero allowThis at all.
# (The previous heuristic counted *every* FHE.* call vs allowThis count, which
# false-positives on every non-trivial contract because plenty of FHE ops produce
# locals that don't need allowThis. We've kept the heuristic simple: a contract
# that uses any add/sub/mul/div/select/fromExternal but never calls allowThis is
# almost certainly broken.)
echo "--- Check 2: Missing FHE.allowThis() ---"
for file in $SOLFILES; do
    # State-mutating ops only — these are the ones that produce a handle the
    # contract is likely to store. Comparison/cast helpers are excluded.
    OPS=$(grep -cE 'FHE\.(add|sub|mul|div|rem|select|fromExternal)\(' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")
    ALLOWS=$(grep -cE 'FHE\.allowThis\(' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")

    # Skip contracts extending ERC7984 (ACL handled by base class _update).
    EXTENDS_ERC7984=$(grep -c 'ERC7984' "$file" 2>/dev/null | tr -d '[:space:]' || echo "0")

    if [ "$OPS" -gt 0 ] && [ "$ALLOWS" -eq 0 ] && [ "$EXTENDS_ERC7984" -eq 0 ]; then
        echo -e "${RED}ERROR: $file has $OPS state-mutating FHE operations but NO FHE.allowThis() calls${NC}"
        ERRORS=$((ERRORS + 1))
    elif [ "$OPS" -gt 0 ] && [ "$ALLOWS" -eq 0 ] && [ "$EXTENDS_ERC7984" -gt 0 ]; then
        echo -e "${GREEN}OK: $file extends ERC7984 (ACL handled by base class)${NC}"
    fi
    # No "OPS > ALLOWS" warning — that heuristic produced too many false positives.
    # Real correctness requires checking that EACH stored handle has its own
    # allowThis, which needs an AST walk. Let solc + tests catch the rest.
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
# Look in $DIR first; if not found, walk up to the parent (a common invocation
# is `bash skill/scripts/validate-fhevm.sh ./contracts` from the project root,
# which would otherwise miss `./hardhat.config.ts` sitting at the project root).
HARDHAT_CONFIG=$(find "$DIR" -maxdepth 3 -name "hardhat.config.*" -not -path "*/node_modules/*" 2>/dev/null | head -1)
if [ -z "$HARDHAT_CONFIG" ]; then
    PARENT_DIR="$(dirname "$DIR")"
    HARDHAT_CONFIG=$(find "$PARENT_DIR" -maxdepth 2 -name "hardhat.config.*" -not -path "*/node_modules/*" 2>/dev/null | head -1)
fi
if [ -n "$HARDHAT_CONFIG" ]; then
    HAS_CANCUN=$(grep -c 'cancun' "$HARDHAT_CONFIG" 2>/dev/null | tr -d '[:space:]' || echo "0")
    if [ "$HAS_CANCUN" -eq 0 ]; then
        echo -e "${RED}ERROR: $HARDHAT_CONFIG does not set evmVersion to 'cancun' (required for FHE.allowTransient)${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}PASS: evmVersion is set to cancun${NC}"
    fi
else
    echo -e "${YELLOW}WARNING: No hardhat.config found in $DIR or its parent${NC}"
    WARNINGS=$((WARNINGS + 1))
fi
echo ""

# ─── Check 7: Random in view functions ───────────────────────────────
echo "--- Check 7: Random in view functions ---"
# Use awk to walk each file. Track the most recent function declaration
# (its modifier list); if the body contains FHE.rand* before the next
# function header, flag it. This catches `function foo(...) external view ...`
# blocks that subsequently call FHE.randEuintN().
for file in $SOLFILES; do
    BAD_RAND_LINES=$(awk '
        /^[[:space:]]*function[[:space:]]/ {
            current_fn = $0
            in_fn = 1
            next
        }
        in_fn && /FHE\.rand[A-Za-z]+\s*\(/ {
            if (current_fn ~ /\b(view|pure)\b/) {
                print FILENAME ":" NR ": " $0
                bad++
            }
        }
        END { exit (bad ? 0 : 1) }
    ' "$file" 2>/dev/null || true)
    if [ -n "$BAD_RAND_LINES" ]; then
        echo -e "${RED}ERROR: $file uses FHE.rand* in a view/pure function (requires state mutation):${NC}"
        echo "$BAD_RAND_LINES" | sed 's/^/  /'
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
    # Anchor each pattern with `(` so prefix matches don't fire — `isIn` would
    # otherwise hit `isInitialized` (a real, documented helper). Same trick
    # avoids `decrypt` matching `decryption` in identifier names.
    BAD_FN=$(grep -nE 'FHE\.(decrypt|safeAdd|safeSub|safeMul|allowForDecryption|sealoutput|isIn)\(' "$file" 2>/dev/null || true)
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

# ─── Check 13: confidentialTransferFrom return value discarded ───────
# The biggest footgun in confidential-DEX patterns: if the caller is underfunded,
# ERC-7984 silently transfers 0 (per Battle Scar #1 in SKILL.md). Code that
# computes the output leg from the *requested* amount instead of the *actual
# transferred* amount is drainable. Detect by flagging:
#   <token>.confidentialTransferFrom(...);     // line by itself, return discarded
# vs the safe form:
#   euint64 actual = <token>.confidentialTransferFrom(...);
echo "--- Check 13: Discarded confidentialTransferFrom return ---"
for file in $SOLFILES; do
    # Match a line that starts (after whitespace) with a token call to
    # confidentialTransferFrom and is NOT preceded on the same line by an
    # assignment (`=`) or a return-style binding. Multi-line calls handled
    # by checking the closing paren/semicolon line in the same loop.
    BAD_DROP=$(grep -nE '^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\.confidentialTransferFrom\(' "$file" 2>/dev/null \
        | grep -vE '=' \
        | grep -vE 'return ' \
        || true)
    if [ -n "$BAD_DROP" ]; then
        echo -e "${RED}ERROR: $file calls confidentialTransferFrom but discards the return value:${NC}"
        echo "$BAD_DROP" | while read -r line; do echo "  $line"; done
        echo -e "  ${YELLOW}HINT:${NC} bind the result and use it for downstream math:"
        echo "    euint64 actual = token.confidentialTransferFrom(...);"
        echo "    FHE.allowThis(actual);"
        echo "    // ... derive output / fee / state from \`actual\`, NOT the request."
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
