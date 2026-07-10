---
name: deep-audit-v2
description: LIVE production audit orchestrator. Three-phase audit — context-building (phase 0) → ethskills breadth (phase 1) → pashov depth (phase 2, blind) → reconcile + coverage gate. Adds a protocol map, access-control inventory, and threat catalog before hunting. The leftclaw auditor (auditor.prompt.md) runs this. `two-phase-audit.md` (v1, no context phase) is the fallback.
---

# Two-Phase Audit v2 — with Context-Building Phase 0

> **LIVE.** This is the production audit orchestrator: `auditor.prompt.md` points here
> and the wrangler installs it into every auditor VM. It extends `two-phase-audit.md`
> (v1) with a context-building Phase 0 and a Turn-3 coverage gate. Validated end-to-end
> on the host and in a VM rehearsal before promotion. `two-phase-audit.md` remains as a
> fallback and is still used by the manual `host-auditor` big-job path.

You are the orchestrator of a **three-phase** audit:

- **Phase 0 — context** (`skills/audit-context.md`): build the protocol map,
  access-control inventory, and threat catalog. **No findings.** The map is the
  shared substrate for both hunting phases.
- **Phase 1 — breadth** (`skills/ethskills-audit.md`): checklist coverage of known
  vuln patterns.
- **Phase 2 — depth** (`skills/pashov-auditor.md`): attacker-mindset hunting for
  novel / seam bugs, run **blind to phase-1 findings**.
- **Phase 3 — reconcile**: merge, cross-check, file once.

Phase 0 is the only structural change from v1. Everything about phases 1–3 below is
identical to `two-phase-audit.md` except where the map is injected and where the
coverage gate consumes the inventory.

**Read all three skill files at Turn 0** (`audit-context.md`, `ethskills-audit.md`,
`pashov-auditor.md`) so you have every playbook loaded. The overrides below modify
their steps, they do not replace them.

**Report assembly — robust across runtimes.** Instruct every agent in every phase to
**return its output as its final message**; the orchestrator (you) assembles
`protocol-map.md`, `phase1-report.md`, `phase2-report.md`, and `unified-report.md`
itself. Do NOT depend on sub-agents writing files — in many runtimes their writes
are sandboxed and silently lost.

## Mode Selection & Flags

Same as v1:

- **Default** (no arguments): all `.sol` files, excluding `interfaces/`, `lib/`,
  `mocks/`, `test/` and `*.t.sol`, `*Test*.sol`, `*Mock*.sol`.
- **`$filename ...`**: only the named file(s).
- `--file-output`: also persist the unified report to a markdown file.
- `--no-file`: produce the report only; do **not** file GitHub issues. (The leftclaw
  auditor always runs `--no-file` — it delivers via IPFS + on-chain.)

## Cost floor (know before you run)

The methodology's agent *count* is fixed (3 context + up-to-8 checklist + 12 attack =
~23 sub-agents); only the model scales with scope. So even a tiny target pays the full
fan-out. A ~470-LOC job measured ~200k output tokens and ~23 min wall-clock in staging,
most of it the fixed 12-agent depth phase. That's fine for a paid audit but is a real
per-job increase over v1 (which had no Phase 0). On a subscription-routed fleet, weigh
this against weekly-window capacity before promoting v2 as the default for *every* job —
it may be worth reserving v2 for higher-value jobs and keeping v1 for trivial ones.

## Orchestration

### Turn 0 — Setup (once, shared across all phases)

In one message:

1. **Read** `skills/audit-context.md`, `skills/ethskills-audit.md`, and
   `skills/pashov-auditor.md`.
2. Resolve scope per Mode Selection (Bash `find` for default mode).
3. Create one shared audit dir: Bash `mktemp -d ./.audit-3phase-XXXXXX` → `{audit_dir}`.
   Holds `protocol-map.md`, `phase1-report.md`, `phase2-report.md`, `unified-report.md`.
4. **Scope sizing → default model for the HUNTING phases.** Measure in-scope size:
   total `.sol` LOC and contract count. `{scope}` = **small** if total in-scope LOC
   < ~600 (regardless of file count), else **large**. (This intentionally REPLACES v1's
   "single contract AND < 300 LOC" rule, which mis-sized a 3-file / ~470-LOC job as
   `large`; LOC is the cost driver, not file count — a handful of small contracts is
   still a small job.) Default `{agent_model}` for phases 1 & 2:
   small → `sonnet`, large → `opus`. Agent *count* never scales — the methodology is
   the 3 context + 6 checklist + 12 attack agents; only the model scales.
5. **Model selection — once, here.** Same rules as v1 (interactive → pashov Turn 1b
   picker; autonomous/headless → `{scope}` default silently; no-`model`-param runtimes
   → leave unset). `{agent_model}` applies to phases 1 & 2.
   **Phase 0 is exempt:** it always uses the strongest model (`opus`), independent of
   `{scope}` — see the note in `audit-context.md` §Turn-0.3. Bad context poisons every
   downstream agent, so this is the phase where model quality pays for itself.

### Turn 0.5 — Phase 0: context building

Execute `skills/audit-context.md` end to end, passing it `{audit_dir}` and the
resolved scope. Its context agents run on `opus`.

Outcome:
- `{audit_dir}/protocol-map.md` written (sections 0–6 + appendices).
- Capture the **six-section body** (0–6, under the size budget) as `{map_body}` —
  this is what gets injected downstream.
- Capture the **access-control inventory** (`{inventory}`) and **threat catalog**
  (`{catalog}`) for the Turn 3 coverage gate.

Do not start Turn 1 until `protocol-map.md` exists and its completeness gate printed
clean. If phase 0 flags a count mismatch it couldn't resolve, note it and continue —
the hunting phases still run, just with a caveat on the map.

### Turn 1 — Phase 1: breadth (ethskills)

Execute `skills/ethskills-audit.md` steps 1–6 **with these overrides**:

- **Agent count:** route via the master-index routing table and spawn **one agent per
  selected domain — the ethskills range is 5–8**; pick the number the routing table
  yields for this target (not a hardcoded 6). "6 checklist agents" elsewhere in this
  file is shorthand for "a typical routing"; the routing table is authoritative.
- **Use LOCAL checklists, not the network (override ethskills' fetch).** The
  `ethskills-audit.md` pointer tells agents to fetch the master index + per-domain
  checklists from `raw.githubusercontent.com/austintgriffith/evm-audit-skills/...`. Do
  **not** fetch in v2. The full `evm-audit-skills` tree is already vendored on disk by
  provisioning at `~/skills/evm-audit-skills/` (relative to the skills base:
  `skills/evm-audit-skills/`). Read the master index from
  `skills/evm-audit-skills/evm-audit-master/SKILL.md` and each domain checklist from
  `skills/evm-audit-skills/<skill>/references/checklist.md`. This removes the
  mid-pipeline network dependency that, in a headless leftclaw job, silently returned
  thin content and made agents fall back to memory (observed in staging). Only if a
  local checklist file is genuinely missing may an agent fetch the URL as a fallback —
  and it must note the fallback in the report as a coverage caveat.
- **Model:** spawn per-checklist agents with `model={agent_model}` (override the
  skill's hardcoded opus). If `{agent_model}` unset, omit `model`.
- **Inject the map:** prepend `{map_body}` to each checklist agent's context as
  *"Protocol map (structural context, contains no findings — use it to route your
  checklist and to know the invariants and trust boundaries; do not treat any line as
  a confirmed issue)."* This is safe — the map has no findings, so it cannot anchor.
- **No issue filing.** STOP after step 6 (synthesis). Do NOT do step 7.
- **Output target:** synthesized findings → `{audit_dir}/phase1-report.md`. Keep each
  finding's checklist/domain label.

Do not start Turn 2 until `phase1-report.md` exists.

### Turn 2 — Phase 2: depth (pashov), blind

Execute `skills/pashov-auditor.md` Turns 1–4 **with these overrides**:

- **Skip its Turn 1b** (model question) — `{agent_model}` already chosen.
- **Blind to phase-1 FINDINGS:** pass **no phase-1 output** into the 12 agents.
- **Inject the map, NOT the findings:** the 12 attack agents receive `{map_body}` as
  structural context (same framing as Turn 1) in addition to their bundle. The map
  contains no findings, so blindness is preserved — and the documented invariants +
  fragility clusters are exactly what an attacker-mindset agent wants: concrete
  properties to try to falsify. Do NOT pass `phase1-report.md`.
- **Output target:** pashov's Turn 4 deduped report → `{audit_dir}/phase2-report.md`.
- Let pashov's Turn 4 hard-gate dedup run as-is (intra-phase). Cross-phase dedup is
  Turn 3.
- Pashov Turn 4 step 5 cleans its own `{bundle_dir}` — fine, separate from
  `{audit_dir}`. Do not delete `{audit_dir}`.

### Turn 3 — Phase 3: synthesis (hybrid) & file once

A single reconciliation pass. Do not re-run any phase.

1. **Load** `phase1-report.md` and `phase2-report.md`.

2. **Cross-phase dedup — reuse pashov Turn 4 discipline** across both phases:
   - Group by `group_key` = `Contract | function | bug-class`.
   - **Function isolation (HARD):** never merge two *distinct* bugs that happen to
     share a function. BUT a single root cause that spans two entrypoints (e.g. one
     verification scheme reused by both `execTransaction` and `isValidSignature`) is
     **one finding** — present it once and list **all** affected functions in its
     `location`. Isolation prevents collapsing different bugs together; it does not
     force splitting one bug into per-function duplicates. Decide by root cause: same
     fix at the same site → one finding; different fixes → separate.
   - **Fix preservation (HARD GATE):** ≥2 distinct fixes for a (Contract, function) →
     present as Option A / B verbatim, one diff each, no paraphrase.
   - **Completeness (HARD GATE):** every unique (Contract, function) in either phase's
     raw output survives into the unified set. Print
     `Completeness: N unique (Contract, function) across both phases, N covered.`

3. **Tag origin** on every unified finding: `[phase1: <domain>]`, `[phase2: agent N]`,
   or `[both]`.

4. **Hybrid re-examine (the cross-check).** Every phase-unique finding is a lead:
   targeted re-read of that specific function to confirm or demote. `[both]` findings
   are corroborated — no re-read.

5. **Coverage gate (NEW in v2).** Using `{inventory}` and `{catalog}` from phase 0:
   - Every **privileged / value-moving entrypoint** in the inventory must map to at
     least one examined finding OR an explicit "examined, no issue" note. List any
     entrypoint neither phase looked at — that's a coverage hole; do a targeted
     re-read now and record the result.
   - Every **threat-catalog row** must be answered: either a finding addresses it, or
     you note "invariant holds — <one-line why>". An unanswered catalog row is a gap.
   - Print inline: `Coverage: E entrypoints in inventory, E addressed. T threat rows,
     T answered. Holes closed this pass: K.` **K counts only entrypoints/threat-rows
     that NEITHER phase examined and that this Turn-3 step re-read for the first time.**
     Confirmatory re-reads of a phase-unique lead (step 4) are NOT holes — they were
     already examined by the phase that raised them; count those under "re-examined
     leads," not K. K=0 is the healthy case (both phases already covered everything).

6. **Write `{audit_dir}/unified-report.md`** per `report-formatting.md`, adding:
   - **Confidence + reporting floor.** Give every finding a `confidence` 0–100. Report
     all findings **Low severity and above**; list anything with `confidence < 50` under
     a separate **Leads** section (plausible, not confirmed) rather than as a finding.
     Severity and confidence are independent axes — a High-severity lead stays a lead
     until confirmed. State the floor you used in the reconciliation summary.
   - Origin / corroboration tag on each finding (step 3).
   - **Reconciliation summary** at top: `Overlap: X · Phase-1-only: Y · Phase-2-only:
     Z · Re-examined leads kept: A, demoted: B · Coverage holes closed: K`.
   - **NEW client-facing sections** (from the phase-0 map, findings-free):
     - **Access-Control Inventory** — the entrypoint × guard × caller table + roles.
     - **Threat Model** — the actor × entrypoint × asset catalog, each row marked
       *addressed by finding #* or *invariant holds*.
   - If `--file-output`: also write to the persisted `report-formatting.md` path.

7. **Deliver — once.**
   - Default (interactive, GitHub target): file issues for unified Medium+ findings via
     the ethskills convention. Only issue-filing step in the flow.
   - `--no-file`: do NOT file issues. Caller owns delivery (leftclaw → IPFS + on-chain).

8. **Auto-clean.** `rm -rf {audit_dir}` after printing (and after any `--file-output`
   write). Copy elsewhere first if debugging.

## Banner

Before doing anything else, print this exactly:

```

██████╗ ███████╗███████╗██████╗      █████╗ ██╗   ██╗██████╗ ██╗████████╗    ██╗   ██╗██████╗
██╔══██╗██╔════╝██╔════╝██╔══██╗    ██╔══██╗██║   ██║██╔══██╗██║╚══██╔══╝    ██║   ██║╚════██╗
██║  ██║█████╗  █████╗  ██████╔╝    ███████║██║   ██║██║  ██║██║   ██║       ██║   ██║ █████╔╝
██║  ██║██╔══╝  ██╔══╝  ██╔═══╝     ██╔══██║██║   ██║██║  ██║██║   ██║       ╚██╗ ██╔╝██╔═══╝
██████╔╝███████╗███████╗██║         ██║  ██║╚██████╔╝██████╔╝██║   ██║        ╚████╔╝ ███████╗
╚═════╝ ╚══════╝╚══════╝╚═╝         ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝         ╚═══╝  ╚══════╝
   context (map + inventory + threats)  →  breadth (ethskills)  →  depth (pashov)  →  reconcile

```
