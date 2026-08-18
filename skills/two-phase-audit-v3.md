---
name: deep-audit-v3
description: STAGED audit orchestrator (v2 + pashov x-ray as Phase 0a). Four-stage audit — x-ray pre-scan (phase 0a) → context-building (phase 0) → ethskills breadth (phase 1) → pashov depth (phase 2, blind) → reconcile + coverage gate (now with an invariant-verification axis). Promote to LIVE (point auditor.prompt.md here) only after a rehearsal job validates it end-to-end. `two-phase-audit-v2.md` is the current LIVE orchestrator.
---

# Two-Phase Audit v3 — v2 + X-Ray Pre-Scan (Phase 0a)

> **STAGED — not yet the production default.** `auditor.prompt.md` still points at
> `two-phase-audit-v2.md`. This version adds pashov's **x-ray** skill as a Phase 0a
> pre-scan whose grep-verified entry-point classification and synthesized invariant
> catalog sharpen everything downstream. Promote only after a rehearsal job runs
> clean end to end.

You are the orchestrator of a **four-stage** audit:

- **Phase 0a — x-ray pre-scan** (`skills/pashov-skills/x-ray/SKILL.md`): mechanical
  enumeration, grep-verified entry-point classification, invariant synthesis, git
  security analysis. Produces `x-ray/` artifacts. **No findings filed** — its
  On-chain=No invariant rows are *candidates*, consumed later as leads.
- **Phase 0 — context** (`skills/audit-context.md`): protocol map, access-control
  inventory, threat catalog. **No findings.** Cross-checked against Phase 0a.
- **Phase 1 — breadth** (`skills/ethskills-audit.md`): checklist coverage of known
  vuln patterns.
- **Phase 2 — depth** (`skills/pashov-auditor.md`): attacker-mindset hunting, run
  **blind to phase-1 findings**, armed with the x-ray invariant catalog.
- **Phase 3 — reconcile**: merge, cross-check, coverage gate (now three axes:
  entrypoints, threat rows, **invariants**), file once.

Phase 0a and the invariant axis are the only structural changes from v2. Everything
below not marked **NEW in v3** is identical to `two-phase-audit-v2.md`.

**Read all four skill files at Turn 0** (`pashov-skills/x-ray/SKILL.md`,
`audit-context.md`, `ethskills-audit.md`, `pashov-auditor.md`). The overrides below
modify their steps, they do not replace them.

**Report assembly — robust across runtimes.** Instruct every agent in every phase to
**return its output as its final message**; the orchestrator (you) assembles
`protocol-map.md`, `phase1-report.md`, `phase2-report.md`, and `unified-report.md`
itself. Do NOT depend on sub-agents writing files — in many runtimes their writes
are sandboxed and silently lost. (Exception: Phase 0a's scripts and Write steps run
in YOUR context, not a sub-agent's, so its `x-ray/` files are real — verify they
exist before moving on.)

## Mode Selection & Flags

Same as v2:

- **Default** (no arguments): all `.sol` files, excluding `interfaces/`, `lib/`,
  `mocks/`, `test/` and `*.t.sol`, `*Test*.sol`, `*Mock*.sol`.
- **`$filename ...`**: only the named file(s).
- `--file-output`: also persist the unified report to a markdown file.
- `--no-file`: produce the report only; do **not** file GitHub issues. (The leftclaw
  auditor always runs `--no-file` — it delivers via IPFS + on-chain.)

## Cost floor (know before you run)

v2's floor (~23 sub-agents; a ~470-LOC job ≈ 200k output tokens / ~23 min) plus
Phase 0a: local scripts (seconds) + up to 5 `sonnet` fact-extraction sub-agents on
large targets, zero on small ones. Phase 0a is the cheapest phase in the pipeline —
its cost is noise next to the 12-agent depth phase.

## Orchestration

### Turn 0 — Setup (once, shared across all phases)

In one message:

1. **Read** `skills/pashov-skills/x-ray/SKILL.md`, `skills/audit-context.md`,
   `skills/ethskills-audit.md`, and `skills/pashov-auditor.md`.
2. Resolve scope per Mode Selection (Bash `find` for default mode).
3. Create one shared audit dir: Bash `mktemp -d ./.audit-3phase-XXXXXX` → `{audit_dir}`.
   Holds `protocol-map.md`, `phase1-report.md`, `phase2-report.md`, `unified-report.md`.
4. **Scope sizing → default model for the HUNTING phases.** Same rule as v2:
   `{scope}` = **small** if total in-scope `.sol` LOC < ~600 (regardless of file
   count), else **large**. Default `{agent_model}` for phases 1 & 2:
   small → `sonnet`, large → `opus`. Agent *count* never scales.
5. **Model selection — once, here.** Same rules as v2 (interactive → pashov Turn 1b
   picker; autonomous/headless → `{scope}` default silently; no-`model`-param runtimes
   → leave unset). **Phase 0 is exempt:** always `opus`. **Phase 0a is exempt the
   other way:** it is mechanical extraction — run it in YOUR context and let its own
   `sonnet` sub-agent rules stand; never upgrade them to opus.

### Turn 0.25 — Phase 0a: x-ray pre-scan (NEW in v3)

Execute `skills/pashov-skills/x-ray/SKILL.md` end to end against the target root,
**with these overrides** (each is load-bearing — do not skip):

- **NO NETWORK (override its Step 1 version check).** Skip the remote `VERSION`
  curl entirely. Same principle as v2's local-checklists rule: no mid-pipeline
  network dependence. The skill treats a failed fetch as skip-silently anyway.
- **NO TARGET CODE EXECUTION (HARD — override its Step 1 coverage run).** Do NOT
  run `forge coverage` / `npx hardhat coverage` — building or testing an untrusted
  target executes the target's own code (ffi, build scripts, test hooks) inside an
  environment that may hold job credentials. Test *existence* already comes from
  `enumerate.sh` file counts. In the report, state:
  `coverage metrics unavailable — target-code execution disabled by audit policy`.
  x-ray's own rules (its "Test existence vs. coverage execution" section) handle
  this cleanly; never let the absence of coverage metrics cascade into "no tests".
- **Local scripts only, fail-soft.** `enumerate.sh`, `analyze_git_security.py`, and
  `generate_svg.py` run from the vendored `skills/pashov-skills/x-ray/scripts/`
  (`$SKILL_DIR` = `skills/pashov-skills/x-ray`). These are OUR reviewed, SHA-pinned
  copies. If `python3` is missing, follow the skill's fallback (bash-only git
  stats; skip the SVG) — never block the audit on a script.
- **No TodoWrite runtime → track inline.** If your runtime lacks TodoWrite, note
  the three x-ray phases inline instead; do not abort over progress bookkeeping.
- Output lands in `x-ray/` at the target root as the skill designs (it is already
  excluded from audit scope). Copy `x-ray/x-ray.md`, `x-ray/entry-points.md`, and
  `x-ray/invariants.md` into `{audit_dir}/` so they survive the skill's cleanup.

Capture for downstream:
- `{xray_entrypoints}` = `entry-points.md` — the **grep-verified** entry-point
  classification (permissionless / role-gated / admin) + flow paths.
- `{xray_invariants}` = `invariants.md` — Enforced Guards (§1) + inferred
  single-contract / cross-contract / economic invariants (§2–4), each marked
  On-chain=Yes/No.
- `{xray_overview}` = `x-ray.md` — overview, threat & trust model, git history.

Do not start Phase 0 until the three files exist. If x-ray fails wholesale
(pathological repo), note it and fall through to plain v2 behavior — Phase 0a is an
enhancer, never a blocker.

### Turn 0.5 — Phase 0: context building

Execute `skills/audit-context.md` end to end, passing it `{audit_dir}` and the
resolved scope. Its context agents run on `opus`. **v3 changes:**

- **Seed the context agents with `{xray_overview}` and `{xray_entrypoints}`** as
  *"mechanical pre-scan output (grep-verified facts, no findings — cross-check your
  inventory against it)"*. Do NOT pass `{xray_invariants}` into Phase 0 — its
  On-chain=No rows read like findings and audit-context is a no-findings phase.
- **Reconciliation rule (NEW):** the access-control inventory must account for every
  entry point in `{xray_entrypoints}`. On a count mismatch, the x-ray list is
  grep-verified — resolve by reading the disputed function, and record the
  resolution in the map's appendix. An entry point in x-ray's list but missing from
  the inventory is a Phase-0 bug; fix it before proceeding.

Outcome (same as v2): `{audit_dir}/protocol-map.md` written; capture `{map_body}`,
`{inventory}`, `{catalog}`. Do not start Turn 1 until the completeness gate prints
clean.

### Turn 1 — Phase 1: breadth (ethskills)

**Identical to v2** — all of v2's overrides apply verbatim (routing-table agent
count 5–8; LOCAL checklists from `skills/evm-audit-skills/`, never the network;
`model={agent_model}`; inject `{map_body}` with v2's no-findings framing; no issue
filing; output → `{audit_dir}/phase1-report.md`).

Phase 1 does **NOT** receive the x-ray artifacts. The checklist agents route by the
map alone — keeping phase 1's coverage independent of x-ray keeps the Turn-3
overlap/coverage statistics honest.

Do not start Turn 2 until `phase1-report.md` exists.

### Turn 2 — Phase 2: depth (pashov), blind

**v2's overrides apply verbatim** (skip its Turn 1b; staggered spawn in waves of 3
— all 12 agents, never all at once; blind to phase-1 findings;
inject `{map_body}`; output → `{audit_dir}/phase2-report.md`), plus:

- **Inject `{xray_invariants}` into the 12 attack agents (NEW in v3)**, framed as:
  *"Invariant catalog from a mechanical pre-scan. These are CANDIDATES, not
  findings: each inferred row cites a derivation — try to falsify it. On-chain=No
  rows are properties the code does not fully enforce — verify whether the gap is
  reachable and exploitable before treating it as a bug. Enforced Guards (§1) are
  per-call preconditions for reference only."*
  This preserves blindness (the catalog derives from code structure, not from
  phase-1 output) and hands attack agents exactly what they want: concrete
  properties to break.

### Turn 3 — Phase 3: synthesis (hybrid) & file once

v2's steps 1–4 (load, cross-phase dedup with function-isolation + fix-preservation
+ completeness hard gates, origin tagging, hybrid re-examine) apply **verbatim**.

5. **Coverage gate — now three axes (v3 extends v2's two):**
   - **Entrypoints** (v2): every privileged / value-moving entrypoint in
     `{inventory}` maps to a finding or an "examined, no issue" note. The inventory
     was already reconciled against `{xray_entrypoints}` in Phase 0, so this axis
     now inherits grep-verified completeness.
   - **Threat rows** (v2): every `{catalog}` row answered — finding or
     "invariant holds — <one-line why>".
   - **Invariants (NEW):** every *inferred* row in `{xray_invariants}` (I-N / X-N /
     E-N — not the §1 guards) must be answered: **holds** (one-line why), **violated
     → finding #**, or **could not verify** (explicitly listed). Every **On-chain=No**
     row that no phase examined gets a targeted re-read now — those rows are the
     pre-scan's highest-signal leads and leaving one unanswered is a coverage hole.
   - Print inline: `Coverage: E entrypoints, E addressed. T threat rows, T answered.
     V inferred invariants, V answered. Holes closed this pass: K.` K counts
     entrypoints/threat-rows/invariant-rows that NEITHER phase examined and this
     step re-read for the first time (confirmatory re-reads of step-4 leads don't
     count). K=0 is the healthy case.

6. **Write `{audit_dir}/unified-report.md`** per v2's step 6 (confidence + reporting
   floor, origin tags, reconciliation summary, Access-Control Inventory and Threat
   Model sections), with the reconciliation summary extended to
   `… · Coverage holes closed: K · Invariants: V answered (H hold, B violated,
   U unverified)` and **one NEW client-facing section**:
   - **Invariant Verification** — the inferred-invariant table from
     `{xray_invariants}`, one row each: ID · property · On-chain Yes/No ·
     verdict (*holds* / *violated → finding #* / *could not verify*). This is the
     section clients quote — a fuzz phase (planned fizz integration) will later
     turn these same rows into executable properties.

7. **Deliver — once.** Same as v2 (default: file unified Medium+ issues;
   `--no-file`: caller owns delivery).

8. **Auto-clean.** `rm -rf {audit_dir}` after printing (and after any
   `--file-output` write). The `x-ray/` dir at target root was already consumed —
   remove it too. Copy elsewhere first if debugging.

## Banner

Before doing anything else, print this exactly:

```

██████╗ ███████╗███████╗██████╗      █████╗ ██╗   ██╗██████╗ ██╗████████╗    ██╗   ██╗██████╗
██╔══██╗██╔════╝██╔════╝██╔══██╗    ██╔══██╗██║   ██║██╔══██╗██║╚══██╔══╝    ██║   ██║╚════██╗
██║  ██║█████╗  █████╗  ██████╔╝    ███████║██║   ██║██║  ██║██║   ██║       ██║   ██║ █████╔╝
██║  ██║██╔══╝  ██╔══╝  ██╔═══╝     ██╔══██║██║   ██║██║  ██║██║   ██║       ╚██╗ ██╔╝╚═══██╔╝
██████╔╝███████╗███████╗██║         ██║  ██║╚██████╔╝██████╔╝██║   ██║        ╚████╔╝ ██████╔╝
╚═════╝ ╚══════╝╚══════╝╚═╝         ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝         ╚═══╝  ╚═════╝
  x-ray pre-scan  →  context (map + inventory + threats)  →  breadth  →  depth  →  reconcile

```
