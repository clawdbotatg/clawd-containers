# HACK-REGISTRY-PLAN.md — mining real exploits to sharpen the auditor

**Status:** planned, not started. This doc is the spec — an agent with no prior
context should be able to execute any of the three workstreams below from it alone.

## The opportunity in one line

[`sanbir/evm-hack-registry`](https://github.com/sanbir/evm-hack-registry) is a
**labeled, machine-greppable corpus of ~845 real EVM exploits (2017→2026)** whose
vulnerability taxonomy lines up almost 1:1 with how our audit skills are already
organized. We can turn that corpus into **few-shot exemplars + a recall benchmark**
for our pipeline — *without* adding per-audit runtime — because the expensive part
(distillation) is precomputed offline and the audit just reads richer reference
files it was already reading.

## What the registry actually is

Not just PoCs — a structured dataset. Each exploit lives in `YYYY-MM-Name_exp/` with:

| Artifact | What it is |
|---|---|
| `sources/` | the **real victim contract source**, pulled from Etherscan (flattened, per-contract) |
| `test/…_exp.sol`, `anvil_state.json` | runnable offline Foundry PoC + committed block state (no RPC needed) |
| `output.txt` | full `-vvvvv` reference trace |
| `<Name>_exp.md` | **AI write-up: root cause + step-by-step attack flow + $loss + a vuln-class tag line** |

The tag line is the key. It sits directly under each write-up's title:

> **Vulnerability classes:** vuln/oracle/price-manipulation · vuln/logic/liquidation-logic

Tags use the [AuditVault](https://github.com/AuditWare/AuditVault) taxonomy. ~820
write-ups are tagged; ~1,851 tag instances across ~70 distinct `vuln/` slugs. Pull
every hack of a class with one grep:

```bash
grep -rl "vuln/oracle/price-manipulation" --include='*_exp.md' .
```

**Real-world class frequency (from the registry README)** — this doubles as a prior
on what actually causes losses, i.e. where to spend audit effort:

| Category | Tag count | Top slugs |
|---|---:|---|
| `vuln/logic/*` (business logic) | 538 | state-update (94), incorrect-state-transition (87), missing-check (71), order-of-operations (71), reward-calc (63) |
| `vuln/access-control/*` | 425 | missing-auth (254), missing-modifier (45), broken-logic (30) |
| `vuln/oracle/*` | 327 | price-manipulation (176), spot-price (113), stale-price (14) |
| `vuln/defi/*` | 166 | slippage (120), sandwich (20), fee-manipulation (16) |
| `vuln/arithmetic/*` | 112 | rounding (35), precision-loss (32), overflow (18), decimal-mismatch (17) |
| `vuln/dependency/*` | 90 | unsafe-external-call (74), unchecked-return (12) |
| `vuln/governance/*` | 65 | flash-loan-attack (57) |
| `vuln/reentrancy/*` | 63 | single-function (33), cross-function (13), cross-contract (11), read-only (6) |
| `vuln/auth/*`, `bridge/*`, `input-validation/*`, `dos/*`, `data/*` | ~65 combined | signature-validation, bridge message-spoofing/replay, etc. |

## Taxonomy mapping (registry → our checklists)

Our breadth phase runs ~20 category checklists in `skills/evm-audit-skills/`. The
mapping is nearly 1:1 — this table is the join key for workstream #1:

| Our checklist dir | Registry `vuln/` slugs to mine |
|---|---|
| `evm-audit-oracles` | `vuln/oracle/*` |
| `evm-audit-access-control` | `vuln/access-control/*` |
| `evm-audit-reentrancy`* | `vuln/reentrancy/*` |
| `evm-audit-precision-math` | `vuln/arithmetic/*` |
| `evm-audit-governance` | `vuln/governance/*` |
| `evm-audit-bridges` | `vuln/bridge/*` |
| `evm-audit-flashloans` | `vuln/governance/flash-loan-attack`, `vuln/defi/flash-loan-attack` |
| `evm-audit-defi-amm` | `vuln/defi/slippage`, `vuln/defi/sandwich-attack`, `vuln/defi/fee-manipulation`, `vuln/defi/price-manipulation` |
| `evm-audit-defi-lending` | `vuln/logic/liquidation-logic`, `vuln/oracle/*` (lending oracle abuse) |
| `evm-audit-signatures` | `vuln/auth/*` (signature-validation/replay/malleability) |
| `evm-audit-proxies` | `vuln/access-control/uninitialized-proxy`, `proxy-storage-collision`, `vuln/dependency/upgradeable-contract` |
| `evm-audit-erc20/721/4626/4337` | token-specific slugs by inspection |
| `evm-audit-dos` | `vuln/dos/*` |
| `evm-audit-general` | `vuln/logic/*` (business-logic — under-served by mechanism checklists; see note) |

\* If we don't have a standalone reentrancy checklist, `vuln/reentrancy/*` cases
fold into `evm-audit-general`. Verify dir names against
`ls skills/evm-audit-skills/` before running — they drift.

> **Note — the `vuln/logic/*` gap.** It's the single biggest category (538 tags) and
> maps least cleanly onto our mechanism-oriented checklists. Business-logic bugs are
> exactly what generic checklists miss and what the depth phase is for. Mining these
> into `evm-audit-general` (and as depth-phase leads, workstream #3) is high-value.

---

## Workstream #1 — enrich breadth checklists with real-world exemplars

**Do this first. Highest ROI, zero added per-audit runtime.** Few-shot exemplars
beat abstract checklist rules; because the output is baked into the skills'
reference files, each audit just reads a richer file it already reads.

**A one-time (then occasionally-refreshed) offline distiller** that, per category:

1. Clone the registry to scratch (see "Getting the corpus" below).
2. For each checklist category, grep the mapped `vuln/` slugs → list of `*_exp.md`.
3. Feed the matched write-ups to a distiller model. Output a
   `references/real-world-cases.md` per category with **5–8 canonical cases**, each:
   - one-line **what broke** + the vuln-class slug,
   - the **concrete code/attack pattern** (not the abstract rule),
   - **$loss + year + a link** back to the registry entry,
   - the **audit check that would have caught it** (the actionable part).
4. Write it into `skills/evm-audit-skills/<category>/references/real-world-cases.md`
   and add a `## Reference Files` pointer in that category's `SKILL.md`.

Pick cases for **diversity of mechanism**, not just the biggest hacks — 8 different
ways price-manipulation manifests beats the 8 largest price-manip losses.

**Acceptance:** every category with ≥5 registry matches has a `real-world-cases.md`;
Phase-1 agents cite a case in at least one finding on a target that has that class.
No change to audit wall-clock (verify against the v3 cost floor).

## Workstream #2 — recall benchmark (`bench_hack_recall.py`, cadence-run)

**The measurable "does this make audits better" signal.** The registry is a labeled
test set. Run periodically (like `bench_naming.py`), NOT per-audit.

1. Sample ~50 entries spanning all classes (stratified by category so rare classes
   are represented).
2. For each: feed the **victim `sources/`** through our audit pipeline as if it were
   a fresh target. **Feed source to the static pipeline only — never run the PoC or
   `anvil_state.json`** (see constraints; no-target-code-execution is a hard rule).
3. Score: did we report a finding whose class matches the entry's ground-truth tag?
   → per-class **recall** + a confusion view of what we systematically miss.
4. Emit a ranked "classes we miss most" list → that's the backlog for workstream #1
   refreshes and checklist strengthening.

**Caveats to encode in the harness:** victim source is sometimes partial (proxy impls
behind custom dispatchers live at a separate address — see the Euler write-up), so a
miss may be a source-completeness artifact, not a real recall gap. Flag entries whose
root-cause contract isn't in `sources/` and exclude them from the denominator.
Running the full pipeline over 50 targets is a big-job batch — route it through
`host-auditor` or a VM, not an interactive session.

**Acceptance:** `python3 bench_hack_recall.py` prints per-class recall + a
"most-missed classes" table; results checked into a dated file the way naming-bench
results are. Cadence: quarterly, or after any material checklist change.

## Workstream #3 — protocol-archetype lead injection (optional, small runtime)

Light RAG over the corpus, keyed by protocol archetype. **Adds minor runtime** —
only pursue after #1/#2 prove out.

During an audit, after x-ray/Phase-0 classifies the protocol type (lending / AMM /
bridge / staking / vault), grep the registry for that archetype's historical hacks
and inject the compact write-ups into the **Phase-2 depth agents** as leads: *"here
are the N ways protocols like this have actually been drained."* Preserves phase-2
blindness (leads derive from external history, not phase-1 output). Natural fit with
the v3 **invariant axis** and the planned **fizz** fuzz phase — these PoCs are
executable invariant-violations, so the same write-ups seed "invariant that was
broken" per class.

---

## Getting the corpus (offline, not vendored)

**Do NOT vendor the registry into this repo.** It's ~32k files with large
`anvil_state.json` snapshots (many GB). We mine it externally and commit only the
**distilled** `real-world-cases.md` outputs. For the distiller/bench, a shallow clone
into scratch is enough — and we only need the write-ups + sources, not the state:

```bash
# shallow clone into scratch (write-ups + sources; skip running anything)
git clone --depth 1 https://github.com/sanbir/evm-hack-registry <scratch>/evm-hack-registry
# all write-ups:      find <scratch>/evm-hack-registry -name '*_exp.md'
# a class's hacks:    grep -rl "vuln/oracle/price-manipulation" --include='*_exp.md' <scratch>/evm-hack-registry
```

For workstream #2, the victim source per entry is `<entry>/sources/**`.

## Hard constraints (do not violate)

- **No target-code execution.** Same rule as `two-phase-audit-v3.md`: never
  `forge build`/`test`/`coverage` the registry PoCs or load `anvil_state.json` in a
  credentialed environment — that runs untrusted code. Workstream #2 feeds *source
  text* to the static pipeline only.
- **Don't vendor the corpus.** Commit distilled references only. Refresh distillation
  on a cadence (fold into `refresh-skills.sh` if it becomes routine).
- **Licensing.** The registry is an educational-use derivative of
  [DeFiHackLabs](https://github.com/SunWeb3Sec/DeFiHackLabs); tags use the AuditVault
  taxonomy. Defensive distillation of patterns is in scope; credit both in any
  committed reference files.
- **Verify names before running.** Both taxonomies drift — re-check
  `ls skills/evm-audit-skills/` and the registry's current class table before a run.

## Suggested order

1. **#1** — offline distiller → `real-world-cases.md` per category. Ship incrementally
   (start with the highest-frequency categories: logic, access-control, oracle).
2. **#2** — `bench_hack_recall.py` to get a baseline recall number; use its
   most-missed list to prioritize the remaining #1 categories.
3. **#3** — archetype lead injection into the depth phase, once #1/#2 show value.
