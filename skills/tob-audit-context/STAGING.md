# Phase 0 (audit-context) — STAGING, not live

This directory + `../audit-context.md` + `../two-phase-audit-v2.md` add a
**context-building Phase 0** (protocol map, access-control inventory, threat
catalog) in front of the existing two-phase audit. Adapted from Trail of Bits'
`audit-context-building` plugin.

## Status: LIVE (promoted)

The leftclaw auditor now runs `../two-phase-audit-v2.md` via `auditor.prompt.md`, and
`provisionAuditorAgent.sh` installs the Phase-0 files (`audit-context.md`,
`two-phase-audit-v2.md`, and this `tob-audit-context/` tree) into every auditor VM.
The wrangler re-provisions before each job, so the next type-4 job runs v2.

`two-phase-audit.md` (v1) is kept as a fallback and is still used by the manual
`host-auditor` big-job path.

## Files

| File | Role |
|---|---|
| `../audit-context.md` | The Phase 0 skill: 3 context agents → `protocol-map.md`. |
| `../two-phase-audit-v2.md` | Staged orchestrator = v1 + Turn 0.5 + coverage gate + report sections. |
| `SKILL.md`, `resources/`, `function-analyzer.md` | Vendored ToB reference (read-only source material). |
| `README.upstream.md` | ToB's original plugin README, for provenance. |

## Promotion checklist (when the staging run proves it out)

1. Add `audit-context.md`, `two-phase-audit-v2.md`, and the needed
   `tob-audit-context/` files to the install allowlist in
   `provisionAuditorAgent.sh` (the `for s in ...` top-level loop + a `cp -R` for the
   `tob-audit-context` dir).
2. Point `auditor.prompt.md`'s reference-material list + step 4 at
   `two-phase-audit-v2.md` instead of `two-phase-audit.md` (or rename v2 → the live
   name once confident).
3. Re-run `cont provision auditor ./provisionAuditorAgent.sh` (the poller does this
   automatically on the next spin-up).
4. Watch the first live job's `protocol-map.md` + coverage-gate output before trusting
   it unattended.

Until step 1 happens, this is documentation and a staged experiment — nothing more.
