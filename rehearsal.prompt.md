You are running a REHEARSAL audit to validate a staged orchestrator version (`two-phase-audit-v3.md`) before it is promoted to production. This is NOT a marketplace job:

- Do NOT use `~/scripts/leftclaw/` or `~/scripts/bgipfs/` for anything.
- No on-chain actions, no publishing, no messaging. Everything stays on local disk in this VM.
- Work autonomously start to finish; never ask for confirmation.

## The job

Target: https://github.com/austintgriffith/liquidity-vesting

1. `git clone https://github.com/austintgriffith/liquidity-vesting ~/audits/rehearsal/repo` and audit the `*.sol` files there. Pin the commit hash (`git rev-parse HEAD`) in the report header.

2. Read `~/skills/two-phase-audit-v3.md` and follow it end to end for this target, **with `--no-file`** (no GitHub issues — the report is the deliverable). At the model-selection step do NOT ask a question — take the scope-scaled default (phase 0 always opus; hunting phases sonnet for small scope, opus for larger/multi-contract scope). Write all outputs under `~/audits/rehearsal/` and land the unified report at `~/audits/rehearsal/final-report.md`.

3. Verification standard (same as production): walk every exploit path step by step before rating a finding Critical or High — if you cannot construct a concrete exploit, downgrade. Quote the relevant source lines in each finding, and before finalizing verify every `file:line` citation resolves (`sed -n '<N>p' <file>` must show the quoted code).

## Rehearsal telemetry (the point of this run)

When the audit is complete, write `~/audits/rehearsal/rehearsal-notes.md` covering:

- Did **Phase 0a (x-ray)** run end to end? Which of its scripts executed cleanly vs failed (and the fallback taken)? Was `python3` available in this VM? Confirm the no-network and no-target-code-execution overrides were honored (you never ran `forge build`/`forge coverage`/tests on the target).
- Did the x-ray entry-point list and the Phase 0 access-control inventory reconcile cleanly, or were there mismatches (list them)?
- The final coverage-gate line (entrypoints / threat rows / invariants answered) and the invariant verdict counts (hold / violated / unverified).
- Anything in `two-phase-audit-v3.md` that was ambiguous, contradictory, or broken while you followed it — quote the offending instruction. This feedback gates promotion, so be blunt.

End your run by printing a one-paragraph summary: finding counts by severity, whether Phase 0a added value over what Phase 0 alone would have produced, and PASS/FAIL: would you promote v3 based on this run?
