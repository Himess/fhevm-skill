# scripts/validate-fhevm.ps1
#
# PowerShell port of validate-fhevm.sh. Runs the same 13 lint checks against
# every .sol file under the target directory. For Windows users without Git
# Bash / WSL -- the bash script is still authoritative; this is a 1:1 port.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/validate-fhevm.ps1 [<dir>]
#
# Exit codes match the bash script:
#   0 = all checks passed
#   1 = warnings found (review recommended)
#   2 = errors found (must fix before deploy)
#
# NOTE: this file is intentionally pure-ASCII so Windows PowerShell 5.1 can
# parse it under any system code page. Do not introduce em-dashes / box-drawing
# characters / smart quotes -- replace them with ASCII equivalents.

param(
    [string]$Dir = "."
)

$ErrorActionPreference = "Stop"
$Errors = 0
$Warnings = 0

function Write-Pass($msg)    { Write-Host "PASS: $msg" -ForegroundColor Green }
function Write-Fail($msg)    { Write-Host "ERROR: $msg" -ForegroundColor Red; $script:Errors++ }
function Write-Warn($msg)    { Write-Host "WARNING: $msg" -ForegroundColor Yellow; $script:Warnings++ }
function Write-InfoLine($msg){ Write-Host "INFO: $msg" -ForegroundColor Yellow }
function Write-Section($n,$t){ Write-Host ""; Write-Host "--- Check ${n}: $t ---" -ForegroundColor Cyan }

Write-Host "=== FHEVM Contract Validator (PowerShell) ===" -ForegroundColor Cyan
Write-Host "Scanning: $Dir"

# Collect Solidity files (skip node_modules / artifacts / cache / lib)
$SolFiles = Get-ChildItem -Path $Dir -Recurse -Filter "*.sol" -ErrorAction SilentlyContinue |
    Where-Object {
        $p = $_.FullName -replace '\\','/'
        ($p -notmatch '/node_modules/') -and
        ($p -notmatch '/artifacts/')   -and
        ($p -notmatch '/cache/')       -and
        ($p -notmatch '/lib/')
    }

if (-not $SolFiles) {
    Write-Host "No Solidity files found in $Dir"
    exit 0
}
Write-Host "Found $($SolFiles.Count) Solidity files"

# --- Check 1: Deprecated TFHE library ----------------------------------
Write-Section 1 "Deprecated TFHE library"
$tfhe = $SolFiles | Where-Object { Select-String -Path $_.FullName -Pattern 'import.*"fhevm/lib/TFHE\.sol"' -Quiet }
if ($tfhe) {
    Write-Warn "Files using deprecated TFHE library (use @fhevm/solidity/lib/FHE.sol):"
    $tfhe | ForEach-Object { Write-Host "  - $($_.FullName)" }
} else {
    Write-Pass "No deprecated TFHE imports found"
}

# --- Check 2: Missing FHE.allowThis() ----------------------------------
Write-Section 2 "Missing FHE.allowThis()"
foreach ($f in $SolFiles) {
    $content = Get-Content $f.FullName -Raw
    $ops      = ([regex]::Matches($content, 'FHE\.(add|sub|mul|div|rem|select|fromExternal)\(')).Count
    $allows   = ([regex]::Matches($content, 'FHE\.allowThis\(')).Count
    $erc7984  = ([regex]::Matches($content, 'ERC7984')).Count
    if ($ops -gt 0 -and $allows -eq 0 -and $erc7984 -eq 0) {
        Write-Fail "$($f.Name) has $ops state-mutating FHE operations but NO FHE.allowThis() calls"
    } elseif ($ops -gt 0 -and $allows -eq 0 -and $erc7984 -gt 0) {
        Write-Pass "$($f.Name) extends ERC7984 (ACL handled by base class)"
    }
}

# --- Check 3: Division by encrypted value ------------------------------
Write-Section 3 "Division by encrypted value"
$any3 = $false
foreach ($f in $SolFiles) {
    $bad = Select-String -Path $f.FullName -Pattern 'FHE\.div\(.*,\s*(e|_e)' -AllMatches
    if ($bad) {
        Write-Fail "$($f.Name) may divide by encrypted value (FHE.div requires plaintext divisor):"
        $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
        $any3 = $true
    }
}
if (-not $any3) { Write-Pass "No encrypted divisors found" }

# --- Check 4: Branching on encrypted values ----------------------------
Write-Section 4 "Branching on encrypted values"
foreach ($f in $SolFiles) {
    $bad = Select-String -Path $f.FullName -Pattern '(if|require|assert)\s*\(.*FHE\.(eq|ne|gt|ge|lt|le|select)' -AllMatches
    if ($bad) {
        Write-Fail "$($f.Name) may branch on encrypted values (use FHE.select instead):"
        $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
    }
}

# --- Check 5: Missing ZamaEthereumConfig -------------------------------
Write-Section 5 "FHE Configuration"
foreach ($f in $SolFiles) {
    $content = Get-Content $f.FullName -Raw
    $usesFhe   = ([regex]::Matches($content, 'FHE\.')).Count
    $hasConfig = ([regex]::Matches($content, '(ZamaEthereumConfig|FHE\.setCoprocessor|SepoliaZamaFHEVMConfig)')).Count
    $isAbstract = ([regex]::Matches($content, '(?m)^\s*(interface|library|abstract)')).Count
    if ($usesFhe -gt 0 -and $hasConfig -eq 0 -and $isAbstract -eq 0) {
        Write-Warn "$($f.Name) uses FHE but doesn't inherit ZamaEthereumConfig or call FHE.setCoprocessor()"
    }
}

# --- Check 6: Hardhat evmVersion ---------------------------------------
Write-Section 6 "Hardhat evmVersion"
$cfg = Get-ChildItem -Path $Dir -Recurse -Depth 3 -Filter "hardhat.config.*" -ErrorAction SilentlyContinue |
    Where-Object { ($_.FullName -replace '\\','/') -notmatch '/node_modules/' } |
    Select-Object -First 1
if (-not $cfg) {
    $parent = Split-Path -Parent (Resolve-Path $Dir)
    if ($parent) {
        $cfg = Get-ChildItem -Path $parent -Recurse -Depth 2 -Filter "hardhat.config.*" -ErrorAction SilentlyContinue |
            Where-Object { ($_.FullName -replace '\\','/') -notmatch '/node_modules/' } |
            Select-Object -First 1
    }
}
if ($cfg) {
    $hasCancun = (Select-String -Path $cfg.FullName -Pattern 'cancun' -Quiet)
    if (-not $hasCancun) {
        Write-Fail "$($cfg.Name) does not set evmVersion to 'cancun' (required for FHE.allowTransient)"
    } else {
        Write-Pass "evmVersion is set to cancun"
    }
} else {
    Write-Warn "No hardhat.config found in $Dir or its parent"
}

# --- Check 7: Random in view functions ---------------------------------
Write-Section 7 "Random in view functions"
foreach ($f in $SolFiles) {
    $lines = Get-Content $f.FullName
    $currentFn = ""
    $inFn = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match '^\s*function\s') { $currentFn = $ln; $inFn = $true; continue }
        if ($inFn -and $ln -match 'FHE\.rand[A-Za-z]+\s*\(' -and $currentFn -match '\b(view|pure)\b') {
            Write-Fail "$($f.Name):$($i+1) uses FHE.rand* in a view/pure function"
            Write-Host "  $ln"
        }
    }
}

# --- Check 8: Deprecated Gateway pattern -------------------------------
Write-Section 8 "Deprecated Gateway pattern"
$gw = $SolFiles | Where-Object { Select-String -Path $_.FullName -Pattern 'Gateway\.(requestDecryption|loadRequestedHandles)|GatewayCaller' -Quiet }
if ($gw) {
    Write-Warn "Files using deprecated Gateway pattern (use FHE.makePubliclyDecryptable + checkSignatures):"
    $gw | ForEach-Object { Write-Host "  - $($_.FullName)" }
} else {
    Write-Pass "No deprecated Gateway usage found"
}

# --- Check 9: Event data leakage ---------------------------------------
Write-Section 9 "Event data leakage"
foreach ($f in $SolFiles) {
    $content = Get-Content $f.FullName -Raw
    if (([regex]::Matches($content, 'FHE\.')).Count -gt 0) {
        $emit = Select-String -Path $f.FullName -Pattern 'emit.*uint' -AllMatches
        if ($emit) {
            Write-InfoLine "$($f.Name) emits events with uint -- verify no encrypted values are leaked:"
            $emit | Select-Object -First 3 | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
        }
    }
}

# --- Check 10: euint256 ordering comparisons ---------------------------
Write-Section 10 "euint256 ordering comparisons"
foreach ($f in $SolFiles) {
    $content = Get-Content $f.FullName -Raw
    if (([regex]::Matches($content, 'euint256')).Count -gt 0) {
        $bad = Select-String -Path $f.FullName -Pattern 'FHE\.(gt|lt|ge|le).*256' -AllMatches
        if ($bad) {
            Write-Fail "$($f.Name) uses ordering comparison on euint256 (only eq/ne supported):"
            $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
        }
    }
}

# --- Check 11: Hallucinated functions ----------------------------------
Write-Section 11 "Non-existent FHE functions"
foreach ($f in $SolFiles) {
    $bad = Select-String -Path $f.FullName -Pattern 'FHE\.(decrypt|safeAdd|safeSub|safeMul|allowForDecryption|sealoutput|isIn)\(' -AllMatches
    if ($bad) {
        Write-Fail "$($f.Name) uses non-existent FHE functions:"
        $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
    }
}

# --- Check 12: Non-existent types --------------------------------------
Write-Section 12 "Non-existent encrypted types"
foreach ($f in $SolFiles) {
    $bad = Select-String -Path $f.FullName -Pattern '(ebytes|eint8|eint16|eint32|eint64|eint128)[^a-zA-Z0-9]' -AllMatches
    if ($bad) {
        Write-Fail "$($f.Name) uses non-existent encrypted types (ebytes/eint do not exist):"
        $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
    }
}

# --- Check 13: Discarded confidentialTransferFrom return ---------------
Write-Section 13 "Discarded confidentialTransferFrom return"
foreach ($f in $SolFiles) {
    $candidates = Select-String -Path $f.FullName -Pattern '^\s+[A-Za-z_][A-Za-z0-9_]*\.confidentialTransferFrom\(' -AllMatches
    $bad = $candidates | Where-Object { $_.Line -notmatch '=' -and $_.Line -notmatch 'return ' }
    if ($bad) {
        Write-Fail "$($f.Name) calls confidentialTransferFrom but discards the return value:"
        $bad | ForEach-Object { Write-Host "  $($_.LineNumber): $($_.Line)" }
        Write-Host "  HINT: bind the result and use it for downstream math:" -ForegroundColor Yellow
        Write-Host '    euint64 actual = token.confidentialTransferFrom(...);'
        Write-Host '    FHE.allowThis(actual);'
        Write-Host '    // ... derive output / fee / state from actual, NOT the request.'
    }
}

# --- Summary -----------------------------------------------------------
Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Errors:   $Errors" -ForegroundColor Red
Write-Host "Warnings: $Warnings" -ForegroundColor Yellow

if ($Errors -gt 0) {
    Write-Host "Fix errors before deploying!" -ForegroundColor Red
    exit 2
} elseif ($Warnings -gt 0) {
    Write-Host "Review warnings before deploying." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "All checks passed!" -ForegroundColor Green
    exit 0
}
