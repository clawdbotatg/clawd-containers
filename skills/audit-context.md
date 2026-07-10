---
name: audit-context
description: Phase 0 of an audit — pure context building. Produces a protocol map, an access-control inventory, and a threat catalog BEFORE any vulnerability hunting. Trigger on "audit context", "protocol map", "threat model", "access control inventory", or as Turn 0.5 of the two-phase audit. Finds no bugs, rates no severities — it builds the map the hunters use.
---

# Audit Context Building (Phase 0)

You are the orchestrator of the **context-building** phase that runs before
vulnerability hunting. Your output is one artifact — `protocol-map.md` — holding
three things:

1. **Access-control inventory** — every entrypoint, its guard, and who can reach it.
2. **Protocol map** — modules, actors, storage read/write map, end-to-end workflows,
   documented invariants.
3. **Threat catalog** — actors × entrypoints × assets, plus fragility clusters that
   tell the later hunting phases where to dig.

Adapted from Trail of Bits' `audit-context-building` skill (vendored under
`skills/tob-audit-context/` — read `SKILL.md` there for the micro-analysis
discipline, `function-analyzer.md` for the per-function agent prompt).

## The one hard rule

**This phase finds no vulnerabilities.** No findings, no fixes, no PoCs, no
severities. If you catch yourself writing "vulnerability", "exploit", or
"reentrancy bug", stop and reframe as a neutral structural observation:
*"`withdraw()` makes an external call at L88 before zeroing `balances` at L91"* is
context. *"`withdraw()` is reentrant"* is a finding — not yours to make here.

Why this matters mechanically: `protocol-map.md` is fed to the phase-2 attack
agents, which must stay **blind to findings** to avoid anchoring. A map that
contains conclusions breaks that blindness. A map that contains only structure,
invariants, and assumptions *sharpens* their hunt — it hands them the exact
statements they should try to falsify.

## Rationalizations (do not skip)

| Rationalization | Why it's wrong | Required action |
|---|---|---|
| "I get the gist" | Gist-level misses edge cases | Read the function |
| "This function is simple" | Simple functions compose into complex bugs | Document its invariants anyway |
| "I'll remember this invariant" | You won't. Context degrades. | Write it down |
| "External call is probably fine" | External = adversarial until proven otherwise | Jump into the code, or model as hostile |
| "I can skip this helper" | Helpers carry assumptions that propagate | Trace the call chain |
| "This is taking too long" | Rushed context = hallucinated findings later | Slow is fast |

## Scope-scaled depth (the cost control)

ToB's skill demands full micro-analysis — 3+ invariants, 5+ assumptions,
line-by-line First Principles / 5 Whys — for **every non-trivial function**. On a
20-contract scope that's ruinous. So we **tier** it:

- **Tier A — full micro-analysis.** Every function that (a) is `external`/`public`
  and state-changing, AND (b) is privileged, moves value, or writes storage another
  entrypoint reads. Plus anything in a fragility cluster. Use the
  `function-analyzer` agent prompt from `skills/tob-audit-context/function-analyzer.md`
  verbatim, honoring its quality thresholds. (Note: that file's internal `{baseDir}/…`
  reference paths point at Trail of Bits' original `audit-context-building/resources/`
  layout — in this repo those resources live under `skills/tob-audit-context/resources/`.
  Read them there; the prompt body is what matters, not its doc links.)
- **Tier B — structural pass.** Everything else in scope: purpose, guard, inputs'
  trust levels, state writes, external calls. One paragraph, no 5 Whys.
- **Tier C — noted only.** Pure getters, `view`/`pure` with no external calls.
  One line in the inventory, no prose.

State the tiering explicitly in the map so a reader knows what got deep attention.

## Orchestration

### Turn 0 — Setup

1. Resolve scope the same way `two-phase-audit.md` does: all `.sol` files excluding
   `interfaces/`, `lib/`, `mocks/`, `test/`, `*.t.sol`, `*Test*.sol`, `*Mock*.sol` —
   unless the caller named specific files.
2. Receive `{audit_dir}` from the caller (the two-phase orchestrator creates it). If
   running standalone, `mktemp -d ./.audit-context-XXXXXX`.
3. **Model.** Context quality determines everything downstream — a wrong invariant
   poisons 18 hunting agents. Run the context agents on the **strongest available
   model** regardless of scope size (currently `opus`). This is the one phase that
   does not scale its model down for small targets. In runtimes with no `model`
   parameter, omit it.
4. Bash `find`/`grep` a cheap skeleton first — contract names, function signatures,
   modifiers, storage declarations — so the agents start from a real inventory rather
   than discovering files one at a time.

### Turn 1 — Three context agents, in parallel

Spawn all three in one message. Each **returns its section as its final message** —
do not rely on sub-agents writing files (they're often sandboxed; writes vanish
silently). You, the orchestrator, assemble `protocol-map.md`.

**Agent 1 — access-control inventory.**
> For every `external`/`public` function in scope, produce one row:
> `Contract.function | guard (modifier / msg.sender check / none) | who can call | state written | moves value?`
> Then a **roles section**: every role, owner, admin, or privileged address —
> how it is granted, revoked, renounced, or transferred; which functions it unlocks;
> whether transfer is one-step or two-step. Then an **unguarded list**: every
> state-changing entrypoint reachable by an arbitrary caller.
> Cite line numbers for every guard. Do not judge whether a guard is correct —
> record what it is.

**Agent 2 — protocol mapper.**
> Map modules and their relationships. Identify actors (user, owner, keeper, oracle,
> liquidator, other contracts). Build the **storage read/write map**: for each state
> variable, which functions read it, which write it. Reconstruct **end-to-end
> workflows** (deposit, withdraw, borrow, liquidate, upgrade, lifecycle) and how state
> transforms across each step. Document **invariants** — properties that must hold
> across the whole system — and **assumptions**, especially those spanning steps.
> Apply Tier A micro-analysis (via `function-analyzer`) to privileged and
> value-moving functions; Tier B to the rest. Cite line numbers. Where behavior is
> unclear, write "Unclear; need to inspect X" — never guess.

**Agent 3 — external-surface & dependency mapper.**
> Enumerate every call that leaves the in-scope code: external contracts, tokens,
> oracles, callbacks, delegatecalls, low-level calls. For each: what is sent
> (payload/value/gas), what is assumed about the target, and — treating the target
> as a **black box** — what happens on revert, on a hostile return value, on an
> unexpected state change, on reentry. Also note upgradeability (proxies, admin
> slots), initialization paths, and any assumption about token behavior
> (fee-on-transfer, rebasing, missing return values, non-standard decimals).
> Record the surface; do not rate it.

### Turn 2 — Threat catalog synthesis

Once all three return, synthesize (no new source reading unless a contradiction
forces it — say so if it does):

1. **Threat catalog.** Cross actors × entrypoints × assets. One row per plausible
   adversarial relationship:
   `actor | what they can reach | what they could gain | which invariant must hold to prevent it`
   This names **invariants to falsify**, not bugs found. An `[unguarded]` entrypoint
   with a value-moving effect is a row; whether it's exploitable is phase 1/2's call.

2. **Fragility clusters.** Rank the functions/flows worth the deepest hunting:
   - many documented assumptions
   - high branching / multi-step dependencies
   - coupled state writes across modules
   - external-call seams (especially state-write-after-call orderings)
   - arithmetic with rounding, scaling, or unit conversion
   Give each cluster a one-line reason. This is the hunting map.

3. **Open questions.** Every "Unclear; need to inspect X" that survived. These are
   handed to the hunting phases as explicit leads.

### Turn 3 — Assemble and budget

Write `{audit_dir}/protocol-map.md`:

```
# Protocol Map — <target>
## 0. Summary            (≤ 200 words: what the protocol does, actors, core invariant)
## 1. Access-Control Inventory   (table + roles + unguarded list)
## 2. Protocol Map       (modules, storage r/w map, workflows, invariants)
## 3. External Surface   (calls out, assumptions, upgradeability)
## 4. Threat Catalog     (actor × entrypoint × asset table)
## 5. Fragility Clusters (ranked, with reasons)
## 6. Open Questions
## Appendix A — Tier A micro-analyses (full per-function depth)
## Appendix B — Tiering ledger (which functions got A / B / C, and why)
```

**Hard size budget.** Sections 0–6 must fit in **~4,000 words / ~6k tokens**. They
are what gets injected into all 18 downstream hunting agents' context; bloat there
is paid 18 times over and crowds out the source itself. Appendix A is **not**
injected wholesale — it stays on disk, and hunting agents are told they may read it
for a specific function. If sections 0–6 exceed budget, compress prose (tables over
paragraphs), never drop a row from the inventory or catalog.

**Completeness gate.** Before finishing, verify and print inline:
- `Entrypoints: N external/public state-changing in source, N in inventory.`
- Every privileged function appears in both the inventory and ≥1 threat-catalog row.
- Every documented invariant names the function(s) that maintain it.
- No section contains a severity, a fix, or the word "vulnerability".

If a count mismatches, fix the map before returning — a map that silently omits an
entrypoint is worse than no map, because downstream agents trust it.

## Handoff

Return to the caller: the path to `protocol-map.md`, the six-section body (for
injection), and the fragility-cluster list. The caller injects sections 0–6 into
both hunting phases' agent bundles and uses the inventory + catalog for its
coverage gate.

## Standalone use

Invoked directly (not from `two-phase-audit-v2.md`), just run Turns 0–3 and print
the map. Nothing else — no hunting, no issues filed.
