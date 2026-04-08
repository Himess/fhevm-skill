# FHEVM Security Checklist

## Pre-Deployment Audit Checklist

### ACL Management

- [ ] Every FHE operation that stores a result has `FHE.allowThis(result)` immediately after
- [ ] Every stored encrypted value grants `FHE.allow(value, relevantUser)` to the appropriate users
- [ ] Cross-contract calls use `FHE.allowTransient()` before the external call
- [ ] View functions that return encrypted handles check `FHE.isAllowed()` before returning
- [ ] No encrypted handle is stored without both `allowThis` and `allow` being called
- [ ] Delegation permissions have appropriate expiration dates

### Information Leakage Prevention

- [ ] No `if`/`else`/`require`/`assert` statements use encrypted boolean values
- [ ] All conditional logic on encrypted values uses `FHE.select()`
- [ ] Events do NOT emit plaintext values derived from encrypted computation
- [ ] Function return values do not leak encrypted state (e.g., returning different values based on encrypted conditions)
- [ ] Error messages do not reveal information about encrypted values
- [ ] Gas consumption is constant regardless of encrypted values (no early returns based on encrypted conditions)
- [ ] Revert/no-revert behavior does not depend on encrypted values

### Input Handling

- [ ] All external encrypted inputs use `FHE.fromExternal(externalEuintXX, inputProof)` for validation
- [ ] Functions accepting already-verified handles check `FHE.isSenderAllowed(handle)`
- [ ] Input proofs are not forwarded across contract boundaries (msg.sender binding)
- [ ] Multiple encrypted inputs from a single user share one proof (gas optimization)

### Arithmetic Safety

- [ ] All division/remainder uses plaintext right-hand operand (`FHE.div(enc, uint64)`)
- [ ] Overflow behavior is handled — either acceptable (wrapping) or detected with `FHE.lt(FHE.add(a,b), a)`
- [ ] Underflow in subtraction handled via select pattern: `FHE.select(FHE.ge(a, b), FHE.sub(a, b), ZERO)`
- [ ] No assumption that FHE operations revert on overflow/underflow (they wrap silently)
- [ ] Bounded random uses power-of-2 upper bounds

### Transfer Safety

- [ ] Transfer functions use the silent failure pattern (select with zero, not revert)
- [ ] Allowance spending uses the same silent failure pattern
- [ ] No assumption that failed transfers revert — they silently transfer 0
- [ ] Both sender and recipient balances are updated with `allowThis` + `allow` after transfer

### Decryption Safety

- [ ] `FHE.makePubliclyDecryptable()` is only called on values that SHOULD be public
- [ ] `FHE.checkSignatures()` is used to verify KMS proofs before acting on decrypted values
- [ ] Decryption results are stored/processed atomically (no partial updates)
- [ ] Unwrap/reveal operations delete pending state after completion (prevent replay)
- [ ] Total bits in a single decryption request ≤ 2048

### State Management

- [ ] `FHE.isInitialized()` checks before operating on potentially uninitialized encrypted storage
- [ ] State transitions for encrypted values are atomic (no partial updates across multiple storage slots)
- [ ] Encrypted values in mappings are properly initialized before first use

### Configuration

- [ ] Contract inherits `ZamaEthereumConfig` (or calls `FHE.setCoprocessor()` in constructor)
- [ ] Hardhat config has `evmVersion: "cancun"` (required for transient storage)
- [ ] Solidity version is `^0.8.24` or higher

### Protocol-Level Security

- [ ] `Ownable2Step` used instead of `Ownable` (prevents accidental ownership transfer)
- [ ] `ReentrancyGuard` on all state-changing functions that interact with FHE
- [ ] `Pausable` for emergency stop capability
- [ ] Rate limiting on FHE-heavy functions (prevent gas griefing / DoS)
- [ ] Batch sizes bounded with explicit `MAX_BATCH_SIZE`
- [ ] Hooks/callbacks are gas-capped: `try hook.call{gas: 100_000}() {} catch {}`
- [ ] No self-dealing prevention bypasses (e.g., user can't be both buyer and seller)
- [ ] Timelock on admin functions for governance safety

### Frontend Security

- [ ] Mainnet API keys are NOT exposed in frontend code (use backend proxy)
- [ ] Encryption timeouts are implemented (30-60 second race)
- [ ] EIP-712 signatures have appropriate time windows (not indefinite)
- [ ] Decrypted values are not stored in localStorage or other persistent client storage

## Common Attack Vectors

### 1. Gas-Based Side Channel

**Attack**: Observe gas consumption to infer encrypted values.

**Mitigation**: FHE operations are constant-gas by design. Ensure your contract logic doesn't create variable gas paths based on encrypted conditions (no early returns, no variable-length loops driven by encrypted values).

### 2. Timing-Based Side Channel

**Attack**: Measure transaction execution time to infer encrypted values.

**Mitigation**: The coprocessor model means computation happens offchain asynchronously. On-chain execution time is handle manipulation only (constant time).

### 3. Revert-Based Oracle

**Attack**: Use `require(encryptedCondition)` to extract one bit per transaction.

**Mitigation**: Never revert based on encrypted values. Always use `FHE.select()`. Verify no code path reverts conditionally on encrypted data.

### 4. Event-Based Leakage

**Attack**: Read plaintext amounts from event logs.

**Mitigation**: Never emit decrypted values in events. Emit only addresses, timestamps, and encrypted handles.

### 5. Balance Change Detection

**Attack**: Compare encrypted balance handles before/after to detect if a transfer succeeded.

**Mitigation**: This is partially mitigable — handles always change after any FHE operation. However, if a transfer of 0 is forced (silent failure), the sender's handle MAY not change. Consider always touching the sender's balance (even for 0 transfers) to ensure the handle changes.

### 6. Front-Running Encrypted Transactions

**Attack**: While the encrypted amount is unknown, transaction metadata (sender, recipient, function selector) is public. Attackers can front-run based on who is transacting.

**Mitigation**: Use commit-reveal schemes for sensitive operations. Consider private mempools or encrypted transaction relayers for additional protection.

### 7. ACL Permission Escalation

**Attack**: Gaining unauthorized access to encrypted handles.

**Mitigation**: Always verify `FHE.isAllowed()` or `FHE.isSenderAllowed()` before returning or processing handles. Never grant broader permissions than necessary.

## Post-Deployment Monitoring

- Monitor for unusual patterns in encrypted handle creation (high-frequency operations may indicate DoS)
- Track ACL permission grants — unexpected `allow` calls may indicate privilege escalation
- Monitor `makePubliclyDecryptable` events — unexpected public decryption may indicate compromise
- Track gas consumption patterns for FHE operations
- Monitor unwrap/reveal operations for replay attempts
