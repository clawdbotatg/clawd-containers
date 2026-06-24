# Skills (audit methodologies)

Local copies of the audit methodology documents the auditor agent applies.
Pre-fetched so the agent reads **local files**, not arbitrary URLs — same
content, but it avoids the "fetch unknown instructions and follow them"
pattern that triggers prompt-injection refusals.

| File | Source URL | What it covers |
|---|---|---|
| `two-phase-audit.md` | (local — this repo) | **Orchestrator the auditor agent runs.** Drives ethskills breadth → pashov depth (blind) → hybrid reconciliation into one unified report. |
| `ethskills-audit.md` | <https://ethskills.com/audit/SKILL.md> | Phase 1: EVM audit pipeline (19 domains, parallel sub-agents, 500+ checklist items) |
| `pashov-auditor.md` | <https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md> | Phase 2: Pashov's solidity audit methodology (12 specialized attack agents — 9 specialty + 3 gap-hunter — dedup + gate eval) |

`provisionAuditorAgent.sh` installs these into `~/skills/` inside the VM
(`two-phase-audit.md` is local to this repo — not refreshed from upstream).
Refresh by re-running:

```bash
curl -fsSL https://ethskills.com/audit/SKILL.md -o skills/ethskills-audit.md
curl -fsSL https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md -o skills/pashov-auditor.md
```
