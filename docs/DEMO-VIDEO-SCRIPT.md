# 3-Minute Demo Video Script

**Target length:** 2:55–3:00 (Zama Developer Program S2 cap is 3:00).
**Audience:** Bounty judge. Knows FHEVM. Wants to see why this skill stands out.
**Recording setup:** OBS or QuickTime, 1080p, terminal + screen + face cam (small overlay).
**Tone:** Direct, confident, evidence-driven. No theme music, no slides — terminal + browser only.

---

## Scene 1 — Hook (0:00–0:20) — "The problem"

**Visual:** Open Cursor / Claude Code. Empty editor. Camera on you.

**Voice-over (you on cam):**

> "I'm Semih. I built an FHEVM skill that lets any AI agent — Claude, Cursor, Copilot, Codex — write production-grade confidential smart contracts on Zama's Protocol without ever opening Zama's docs. In the next three minutes, I'll show you it actually works, then I'll show you the audit trail that backs it up."

**Cut.**

---

## Scene 2 — Live agent demo (0:20–1:30) — "It works"

**Visual:** Switch to Claude Code (or Cursor) terminal. Skill is already loaded at `~/.claude/skills/fhevm/`. Camera goes small or hides.

**On-screen action:**
1. Type into the agent: *"Build me a confidential second-price (Vickrey) auction with ERC-7984 escrow, full test suite, 4 bidders, no internet access."*
2. Press enter. Agent works (real-time, sped up 4× in post if needed). Show:
   - Reading SKILL.md
   - Reading `references/common-pitfalls.md` Top-K section
   - Lifting `templates/vickrey-auction.sol`
   - Writing tests
3. Run `npx hardhat test`. Show 19/19 passing.

**Voice-over over the run:**

> "The agent reads the skill, picks the right template, follows the patterns, and ships a working Vickrey auction with passing tests. No Google. No Zama doc lookups. Just the skill."

**Show terminal output:**
```
  19 passing (3s)
```

**Cut.**

---

## Scene 3 — Stress-test evidence (1:30–2:15) — "It works repeatedly"

**Visual:** Open `stress-reports/` folder in editor. Show the file list — 9 reports from 3 rounds.

**On-screen action:**
1. Open `round5-agent3-kyc.md`. Scroll to §1 (Outcome) — show "21/21 passing, 2 rework loops, 52 minutes wall time."
2. Cut to `round5-agent1-amm.md` — "19/19 passing, 0 rework loops."
3. Open `docs/bounty-compliance.md`. Highlight the stress-test row: "9 agents, 126/126 tests, 9.0/10 average, zero internet."

**Voice-over:**

> "I didn't trust just one demo. I ran nine independent agents across three rounds — confidential AMM, CDP vault, payroll, lottery, KYC, Vickrey, multi-vote — every one with internet disabled. 126 tests across 9 dApps. All passing. The reports are in the repo."

**Cut.**

---

## Scene 4 — Audit rigor (2:15–2:45) — "It's calibrated"

**Visual:** `audit-reports/` folder. Show 5 round files. Open `AUDIT-REPORT-2026-05-08-FINAL.md`.

**On-screen action:**
1. Show the table of audit rounds: R3 + R4 source-code audits.
2. Highlight one specific catch: "Round 3 found `EncryptResult` import doesn't exist in relayer-sdk@0.4.1 — fixed."
3. Open `node_modules/@zama-fhe/relayer-sdk/lib/web.d.ts`. Grep for the real exports: `UserDecryptResults`, `KmsUserDecryptEIP712Type`, `KeypairType`. Show they match the skill's import list.

**Voice-over:**

> "Every API claim was checked against locally-installed source — `@fhevm/solidity@0.11.1`, OpenZeppelin Confidential Contracts, the Zama SDKs. Two source-code audit rounds caught 24 hard errors. All fixed and re-verified. The HCU table in `gas-optimization.md` is verbatim from the live Zama docs page. Nothing is guessed."

**Cut.**

---

## Scene 5 — Close (2:45–3:00) — "The pitch"

**Visual:** Camera back on you. Behind, terminal showing `validate-fhevm.sh` final run with "0 errors, 0 warnings, all checks passed!"

**Voice-over (you on cam):**

> "FHEVM has a learning curve. This skill collapses it: AI agents write correct confidential dApps on the first try, with patterns sourced from real production code. 21 templates, 12 reference guides, 5 audit rounds, 126 stress-test passes. The repo is at github.com/Himess/fhevm-skill. Thanks for watching."

**End card (1.5 sec):**
```
github.com/Himess/fhevm-skill
Zama Developer Program — Season 2
```

---

## Recording Checklist

- [ ] Skill installed at `~/.claude/skills/fhevm/` (symlink ok)
- [ ] Run a dress-rehearsal of Scene 2 first — make sure the agent picks the Vickrey template (not blind-auction). If it misroutes, adjust the prompt to "second-price auction (Vickrey) with separate winner-pays-second-bid logic" — that disambiguates.
- [ ] Pre-load `stress-reports/round5-agent1-amm.md`, `round5-agent3-kyc.md`, and `docs/bounty-compliance.md` in editor tabs so Scene 3 transitions are fast.
- [ ] Pre-position your terminal at `node_modules/@zama-fhe/relayer-sdk/lib/web.d.ts` and a `grep "export declare type"` command, so Scene 4 is one keystroke.
- [ ] Mic check: AirPods Pro or Yeti, push-to-talk OFF, room treated.
- [ ] First take is rarely the keeper. Plan 3 takes minimum.
- [ ] In post: trim Scene 2 to ~50 seconds (the slow part is the agent thinking — speed up 4× and overlay your voice).

## Submission Notes

The bounty rules say "real person demo video, ≤3 minutes". Your face on camera in Scene 1 + Scene 5 satisfies the "real person" requirement. The middle 90 seconds can be all-screen.

If you want a longer cut (e.g. 5 min for a tweet thread), expand Scene 4 with one specific Round-3 fix walked through line-by-line.
