# Skills (audit methodologies)

Local copies of the audit methodology documents the auditor agent applies.
Pre-fetched so the agent reads **local files**, not arbitrary URLs — same
content, but it avoids the "fetch unknown instructions and follow them"
pattern that triggers prompt-injection refusals.

| File | Source URL | What it covers |
|---|---|---|
| `two-phase-audit-v2.md` | (local — this repo) | **LIVE orchestrator the auditor agent runs.** Phase 0 context (protocol map + access-control inventory + threat catalog) → ethskills breadth → pashov depth (blind) → reconcile + coverage gate. |
| `two-phase-audit-v3.md` | (local — this repo) | **STAGED** (promote after a rehearsal job): v2 + x-ray as Phase 0a — grep-verified entry points cross-check the Phase-0 inventory, the invariant catalog arms the phase-2 attack agents, and the coverage gate gains an invariant axis. Hard override: never runs `forge coverage` on the target (target-code execution is banned in credentialed environments). |
| `two-phase-audit.md` | (local — this repo) | v1 fallback (no Phase 0); still used by the manual host-auditor big-job path. |
| `audit-context.md` | (local — this repo, adapted from ToB) | Phase 0: context building. Uses the vendored `tob-audit-context/` tree for the function-analyzer discipline. |
| `ethskills-audit.md` | <https://ethskills.com/audit/SKILL.md> | Phase 1: EVM audit pipeline (19 domains, parallel sub-agents, 500+ checklist items) |
| `pashov-auditor.md` | <https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md> | Phase 2: Pashov's solidity audit methodology (12 specialized attack agents — 9 specialty + 3 gap-hunter — dedup + gate eval) |
| `pashov-skills/x-ray/` | <https://github.com/pashov/skills> (sparse clone, **SHA-pinned**) | **Wired as Phase 0a in `two-phase-audit-v3.md`** (staged). Pre-audit scan: entry-point classification (grep-verified), invariant synthesis (`invariants.md`), git security analysis, threat profiling. Its scripts execute locally, so refreshes are pinned to a reviewed SHA in `refresh-skills.sh`. |
| `pashov-skills/fizz/` | <https://github.com/pashov/skills> (sparse clone, **SHA-pinned**) | **Vendored, not yet wired.** Generates + runs an Echidna/Medusa stateful fuzz suite. Dynamic (forge build + fuzzers) — VM-path only, never the host-auditor; needs medusa/echidna added to VM provisioning **and a keyless VM** (fuzzing builds untrusted target code). |

`provisionAuditorAgent.sh` installs these into `~/skills/` inside the VM
(the `two-phase-audit*.md` orchestrators and `audit-context.md` are local to
this repo — not refreshed from upstream).

Refresh everything upstream-sourced (evm-audit-skills clone, pashov-skills
sparse clone incl. x-ray + fizz, top-level SKILL.md pointers) with:

```bash
./refresh-skills.sh
```

## Planned: mining real exploits to sharpen the auditor

[`../HACK-REGISTRY-PLAN.md`](../HACK-REGISTRY-PLAN.md) is the spec for turning
[`sanbir/evm-hack-registry`](https://github.com/sanbir/evm-hack-registry) (~845
labeled real EVM exploits, taxonomy ~1:1 with our `evm-audit-skills/` categories)
into **few-shot exemplars per checklist + a recall benchmark** — without adding
per-audit runtime (distillation is precomputed offline). Not started; execute from
that doc.
