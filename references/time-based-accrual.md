# Time-Based Encrypted Accrual (Interest, Rewards, Vesting)

> **TL;DR** — `FHE.div` on `euint64` is integer division. Naive accrual math (`principal * ratePerSecond * elapsed / SECONDS_PER_YEAR`) truncates **every intermediate step** and routinely loses 30–40% of the result on realistic inputs. Pre-multiply the running totals by an `ACCRUAL_SCALE` constant (1000 is the sweet spot), defer the divide-out until the user-facing readout, and you keep ~3 decimals of precision through the encrypted hot path.

This pattern is needed by lending protocols, staking pools, vesting schedules, streaming payments — anything that converts elapsed time into an accrued encrypted amount.

---

## The footgun (what naive code does)

```solidity
// principal: 1000e6 (1000 USDC, 6 decimals, encrypted as euint64)
// ratePerSecond: ~1585 (≈ 5% APR scaled to 1e9, fits in euint64)
// elapsed: 86_400 (one day in seconds)
// SECONDS_PER_YEAR: 31_536_000

euint64 numerator = FHE.mul(principal, FHE.mul(ratePerSecond, elapsed));
// numerator = 1000e6 * 1585 * 86_400 = 1.37e17  → fine, euint64 holds 1.84e19

euint64 interest = FHE.div(numerator, SECONDS_PER_YEAR);
// interest ≈ 4.34e9  → "looks right"

// BUT — repeat 365 times for a year of daily compounding:
//   each step: FHE.div(small_value, SECONDS_PER_YEAR)
//   each step truncates the trailing digits
//   over 365 steps, ~37% of the principal accrual is lost to truncation
```

The killer is **per-step truncation in a loop**. Single-shot accrual at year-end is fine; per-block, per-day, or per-action accrual hemorrhages precision. The lending-pool stress-test agent (Round 4) measured 37% loss against the off-chain reference for a 1-year, daily-stepped pool.

Why it's worse in FHE than in plaintext:
- **No fixed-point types**: there is no `ufixed`, `eFixed64x18`, or analogue. `euint64` only.
- **Cannot probe values**: you cannot `assert(intermediate > 0)` mid-computation; you only see truncation at decrypt time.
- **`FHE.div` cost is high (~~80k+ HCU)**: you can't add a "remainder check" branch cheaply.

---

## The fix: pre-multiply by `ACCRUAL_SCALE`

Carry an internal scaled representation of the accumulator. Only divide back to user units at the boundary where a human reads the number.

```solidity
uint64 constant ACCRUAL_SCALE = 1000;            // 3 extra decimals of headroom
uint64 constant SECONDS_PER_YEAR = 31_536_000;

// Storage: scaled accumulator, not user-facing units
euint64 internal _scaledIndex;                   // grows by rate * elapsed each accrue()

function accrue() internal {
    uint64 elapsed = uint64(block.timestamp - _lastAccrueAt);
    if (elapsed == 0) return;

    // Add `ratePerSecond * elapsed * ACCRUAL_SCALE` to the index.
    // No division here — divisions are deferred until readout.
    euint64 delta = FHE.mul(_ratePerSecond, elapsed * ACCRUAL_SCALE);
    _scaledIndex = FHE.add(_scaledIndex, delta);
    FHE.allowThis(_scaledIndex);

    _lastAccrueAt = uint64(block.timestamp);
}

// User-facing readout: divide ONCE, at the boundary
function balanceOf(address user) external view returns (euint64) {
    // userPrincipal stored encrypted; index applied at readout
    euint64 grossScaled = FHE.mul(_userPrincipal[user], _scaledIndex);
    // Divide back: ACCRUAL_SCALE * SECONDS_PER_YEAR collapses to a single constant
    return FHE.div(grossScaled, ACCRUAL_SCALE * SECONDS_PER_YEAR);
}
```

The guarantee: every increment to `_scaledIndex` retains its full precision; only the final readout truncates, and that's a single, bounded loss.

### Why `ACCRUAL_SCALE = 1000`, not 1e6 or 1e18?

Because `euint64` tops out at `1.84e19`. The product `principal * scaledIndex` must fit:

| principal cap | rate (APR) | duration | scaled product order | safe scale |
|---|---|---|---|---|
| 1e9 (1B USDC, 6 dec) | 100% | 10 years | ~3e18 | **`ACCRUAL_SCALE = 1000`** ✓ |
| 1e9 | 100% | 10 years | ~3e21 | ACCRUAL_SCALE = 1e6 ✗ overflow |
| 1e6 (1M USDC) | 20% | 1 year | ~6e15 | 1e6 fits but no margin |

`1000` is the largest power of ten that keeps the standard DeFi parameter ranges (≤ 1B principal, ≤ 100% APR, ≤ 10 years) safely inside `euint64`. Three decimals is enough to drop the truncation loss from ~37% to <0.05% in the lending-pool tests.

Bigger principals or longer time horizons → drop the scale. Smaller scopes (vesting over months, micro-payments) → you can push to 10_000.

---

## Compounding vs simple-interest variants

The `_scaledIndex` pattern above is **simple interest**, the cheapest variant. For compound interest the index is multiplicative (`index *= (1 + rate*elapsed)`), which requires a `1 + x` expression that doesn't blow up over time:

```solidity
// Compound, scaled. (1 + rate*elapsed/YEAR) ≈ 1 + (rate*elapsed/YEAR)  for small steps.
// Carry SCALED form: scaledRateIncrement = rate * elapsed * ACCRUAL_SCALE / YEAR
// new_index = old_index * (ACCRUAL_SCALE + scaledRateIncrement) / ACCRUAL_SCALE
euint64 scaledIncrement = FHE.div(
    FHE.mul(_ratePerSecond, elapsed * ACCRUAL_SCALE),
    SECONDS_PER_YEAR
);
euint64 multiplier = FHE.add(FHE.asEuint64(ACCRUAL_SCALE), scaledIncrement);
_index = FHE.div(FHE.mul(_index, multiplier), ACCRUAL_SCALE);
FHE.allowThis(_index);
```

Compound costs ~2× the HCU of simple-interest because of the per-accrue multiplication. For most lending / staking flows, simple interest is fine — match Compound v2's `borrowIndex` pattern, not v3's RAY-precision compounding.

### Avoid: per-user accrual

```solidity
// ANTI-PATTERN — accrue interest per user on every action
function deposit(address user, ...) external {
    _userBalance[user] = FHE.add(
        _userBalance[user],
        FHE.div(FHE.mul(_userBalance[user], elapsedSinceUserAction[user]), ...)
    );
}
```

Per-user `FHE.mul + FHE.div` on every interaction blows the HCU budget on busy contracts. Use a global scaled index + `lastIndexAt[user]` snapshot, identical to ERC-20-staking's `rewardPerTokenStored` pattern.

---

## What about `FHESafeMath`?

`@openzeppelin/confidential-contracts` ships `FHESafeMath` for over/underflow-aware addition and subtraction (returns `(success, value)` tuples in the encrypted domain). It does **not** provide scaled-arithmetic helpers — those are still your responsibility. Use it for the principal / debt mutations and pair it with this scaling pattern for the index.

---

## Self-test recipe (caught the 37% bug)

```ts
// Off-chain reference: what cleartext math says the accrual should be
const expectedInterest = (principal * rateApr * days) / 365n;

// On-chain: deposit, advance time, withdraw, decrypt
await pool.deposit(encrypted(principal), proof);
await network.provider.send("evm_increaseTime", [days * 86400]);
await network.provider.send("evm_mine");
const handle = await pool.balanceOf(user);
const cleartext = await fhevm.userDecryptEuint(FhevmType.euint64, handle, pool.address, user);

// Assert: scaled-index implementation should be within 0.5%
expect(Number(cleartext - principal)).to.be.closeTo(
    Number(expectedInterest),
    Number(expectedInterest) * 0.005,    // 0.5% tolerance
);
```

The naive `FHE.div`-per-step implementation will fail this test by ~37% on a 365-day window. The scaled-index implementation passes within 0.05%.

This test belongs in every interest-bearing FHEVM contract's mock-mode suite. If you're building anything time-accrued, add it before you ship.

---

## Cross-references

- `references/type-system.md` — `euint64` range and why scaling beyond 1000 risks overflow
- `references/gas-optimization.md` — `FHE.div` cost (one of the most expensive ops) and why deferring it matters
- `references/common-pitfalls.md` — `FHE.div` truncation rules (relevant to but distinct from accrual)
- `references/security-checklist.md` — accrual-driven invariants to assert before deployment

> **Battle scar (Round 4 stress test):** the lending-pool agent shipped the naive variant first, hit the 37% truncation, and only then derived the scaled-index pattern from first principles. That investigation cost ~30 minutes of the agent's 47-minute run. This file exists so the next agent skips that cost entirely.
