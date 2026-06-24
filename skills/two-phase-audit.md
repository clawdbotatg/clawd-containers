---
name: deep-audit
description: Maximum-coverage two-phase smart contract security audit. Trigger on "deep audit", "two-phase audit", "full security audit", "thorough audit". Runs the ethskills checklist-breadth pass, then the pashov attacker-depth pass blind, then reconciles both into one unified report and files issues once. Supersedes the single-phase `audit` and `solidity-auditor` skills when the runner wants the deepest possible coverage.
---

# Two-Phase Smart Contract Security Audit

You are the orchestrator of a two-phase audit. Phase 1 is **breadth** (checklist
coverage of known vuln patterns); phase 2 is **depth** (attacker-mindset hunting
for novel / seam bugs). Phase 2 runs **blind** to phase 1 to avoid anchoring; a
final synthesis reconciles both and **files issues once**.

The two phases are the existing skills in this repo — you drive them, you do not
re-derive them:

- **Phase 1** — `skills/ethskills-audit.md` (the `audit` skill). Checklist-driven
  breadth: master index → route 5–8 domain checklists → one agent per checklist →
  synthesize.
- **Phase 2** — `skills/pashov-auditor.md` (the `solidity-auditor` skill).
  Attacker-mindset depth: 12 parallel background agents (9 specialty + 3
  gap-hunter) → hard-gate dedup.

**Read both skill files at Turn 0** so you have their exact steps in front of you;
the overrides below modify those steps, they do not replace them.

**Report assembly — robust across runtimes.** Instruct every phase-1 and phase-2
agent to **return its findings as its final message**, and have the orchestrator
assemble `phase1-report.md` / `phase2-report.md` itself from those returned
messages. Do NOT depend on sub-agents writing report files: in many runtimes
sub-agents are sandboxed and file writes are blocked or land in an unreadable
working dir. The orchestrator (you) writes all three report files. (Lesson from
real runs: sub-agent file writes were silently blocked; the run only succeeded
because findings came back in the agents' final messages.)

## Mode Selection & Flags

Same as the sub-skills:

- **Default** (no arguments): all `.sol` files, excluding `interfaces/`, `lib/`,
  `mocks/`, `test/` and files matching `*.t.sol`, `*Test*.sol`, `*Mock*.sol`.
- **`$filename ...`**: only the named file(s).
- `--file-output`: also persist the final unified report to a markdown file (path
  per `report-formatting.md`). Off by default.
- `--no-file`: produce the report only; do **not** file GitHub issues. (Default is
  to file issues once, Medium+, at the end.)

## Orchestration

### Turn 0 — Setup (once, shared across both phases)

In one message:

1. **Read** `skills/ethskills-audit.md` and `skills/pashov-auditor.md` so you have
   both phase playbooks loaded.
2. Resolve scope per Mode Selection (Bash `find` for default mode).
3. Create one shared audit dir: Bash `mktemp -d ./.audit-2phase-XXXXXX` → store as
   `{audit_dir}`. It will hold `phase1-report.md`, `phase2-report.md`,
   `unified-report.md`.
4. **Scope sizing → default model.** Measure in-scope size: total `.sol` LOC and
   contract count. Set `{scope}` = **small** if a single contract AND < ~300 in-scope
   LOC, else **large**. Default `{agent_model}`: small → `sonnet`, large → `opus`.
   Agent *count* never scales with size — the 6 checklist + 12 attack agents are the
   methodology; independent perspectives are the point. Only the **model** scales.
   (Lesson from real runs: on a tiny contract a dozen attack agents converge on the
   same 1–2 leads — that redundancy is expected and the Turn 3 dedup collapses it;
   do not treat N identical leads as N signals, and do not cut agents to save cost —
   drop to `sonnet` instead.)

5. **Model selection — once, here, not per phase.**
   - **Interactive Claude Code** (both `AskUserQuestion` and the `Agent` tool's
     `model` parameter exist, and a human is driving): run the pashov **Turn 1b**
     picker — `AskUserQuestion` with the three opus/sonnet/haiku preview boxes,
     pre-selecting the `{scope}` default as `(Recommended)`. Store the answer as
     `{agent_model}`; if no answer, use the `{scope}` default.
   - **Autonomous / headless** (no human to answer — e.g. the leftclaw auditor, cron,
     a CI job): do **NOT** emit an interactive question. Use the `{scope}` default
     for `{agent_model}` and proceed silently.
   - **Runtimes without a `model` parameter** (Codex, Gemini, Cursor native, …):
     SKIP model selection, leave `{agent_model}` unset (omit `model` on Agent calls).

   `{agent_model}` is applied to **both** phases' agents.

### Turn 1 — Phase 1: breadth (ethskills)

Execute `skills/ethskills-audit.md` steps 1–6 **with these overrides**:

- **Model:** spawn the per-checklist agents with `model={agent_model}` (the
  ethskills skill hardcodes opus — override it). If `{agent_model}` is unset, omit
  `model` (runtime default).
- **No issue filing.** STOP after step 6 (synthesis). Do **NOT** perform step 7
  (file GitHub issues) — issues are filed once in Turn 3.
- **Output target:** write the synthesized findings to
  `{audit_dir}/phase1-report.md`. Keep each finding's checklist/domain label so it
  can be tagged in synthesis.

Do not start Turn 2 until phase 1 has produced `phase1-report.md`.

### Turn 2 — Phase 2: depth (pashov), blind

Execute `skills/pashov-auditor.md` Turns 1–4 **with these overrides**:

- **Skip its Turn 1b** (model question) — `{agent_model}` is already chosen. If set,
  pass `model={agent_model}` on every Agent call; if unset, omit `model`.
- **Blind:** pass **no phase-1 context** into the 12 agents. They read only their
  bundle, exactly as the skill specifies. Do not mention phase-1 findings to them.
- **Output target:** run as if `--file-output`, writing pashov's Turn 4 deduped
  report to `{audit_dir}/phase2-report.md` (instead of, or in addition to, the
  default path).
- Let pashov's Turn 4 hard-gate dedup (function isolation, fix preservation,
  completeness) run as-is — that is the **intra-phase** dedup. Cross-phase dedup
  happens in Turn 3.
- Pashov Turn 4 step 5 auto-cleans **its own** bundle dir (`{bundle_dir}`); that is
  fine and separate from `{audit_dir}`. Do not delete `{audit_dir}` here.

### Turn 3 — Phase 3: synthesis (hybrid) & file once

A single reconciliation pass. Do not re-run either phase.

1. **Load** `{audit_dir}/phase1-report.md` and `{audit_dir}/phase2-report.md`.

2. **Cross-phase dedup — reuse the pashov Turn 4 discipline** applied across both
   phases' findings:
   - Group by `group_key` = `Contract | function | bug-class`.
   - **Function isolation (HARD):** never merge across different `function:` fields.
   - **Fix preservation (HARD GATE):** if a merged (Contract, function) has ≥2
     distinct fixes (different ADD-lines / check direction / checked param),
     present them as **Option A / B …** verbatim, one diff block each — no paraphrase.
   - **Completeness (HARD GATE):** every unique (Contract, function) present in
     either phase's raw output MUST survive into the unified set. Print inline
     before the report: `Completeness: N unique (Contract, function) across both
     phases, N covered in unified.`

3. **Tag origin** on every unified finding:
   - `[phase1: <checklist/domain>]` — only the breadth pass found it.
   - `[phase2: agent N]` — only the depth pass found it.
   - `[both]` — both phases found it (corroborated).

4. **Hybrid re-examine (the cross-check).**
   - Every `[phase1: …]`-only or `[phase2: agent N]`-only finding is a **lead**:
     do a **targeted re-read of that specific function** (Read/Grep the contract)
     to confirm or demote. One pass per phase-unique finding — confirm → keep at
     stated severity; refute in source → demote to a noted lead or drop with reason.
   - `[both]` findings are **corroborated** — boost confidence; no re-read needed.
   - This is the only place source is re-read in Turn 3. Do not re-verify
     corroborated findings.

5. **Write `{audit_dir}/unified-report.md`** per `report-formatting.md`, adding:
   - An **origin / corroboration** column or tag on each finding (from step 3).
   - A short **reconciliation summary** at the top: `Overlap: X findings in both
     phases · Phase-1-only: Y · Phase-2-only: Z · Re-examined leads kept: A,
     demoted: B`.
   - If `--file-output`: also write the unified report to the persisted path from
     `report-formatting.md`.

6. **Deliver — once.** The primary deliverable is always `unified-report.md`.
   - Default (interactive, GitHub repo target): file issues for the unified Medium+
     findings using the ethskills issue-filing convention (from the evm-audit-skills
     master index / `report-formatting.md`). This is the only issue-filing step in
     the flow.
   - `--no-file`: do NOT file issues. The caller owns delivery — e.g. the leftclaw
     auditor publishes `unified-report.md` to IPFS and completes the job on-chain.
     Run `--no-file` whenever an external workflow handles report delivery.

7. **Auto-clean.** `rm -rf {audit_dir}` after printing (and after any `--file-output`
   write to a persisted path). For debugging, copy it elsewhere first.

## Banner

Before doing anything else, print this exactly:

```

██████╗ ███████╗███████╗██████╗      █████╗ ██╗   ██╗██████╗ ██╗████████╗
██╔══██╗██╔════╝██╔════╝██╔══██╗    ██╔══██╗██║   ██║██╔══██╗██║╚══██╔══╝
██║  ██║█████╗  █████╗  ██████╔╝    ███████║██║   ██║██║  ██║██║   ██║
██║  ██║██╔══╝  ██╔══╝  ██╔═══╝     ██╔══██║██║   ██║██║  ██║██║   ██║
██████╔╝███████╗███████╗██║         ██║  ██║╚██████╔╝██████╔╝██║   ██║
╚═════╝ ╚══════╝╚══════╝╚═╝         ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝
        breadth (ethskills)  →  depth (pashov)  →  reconcile

```
