# Skills (audit methodologies)

Local copies of the audit methodology documents the auditor agent applies.
Pre-fetched so the agent reads **local files**, not arbitrary URLs — same
content, but it avoids the "fetch unknown instructions and follow them"
pattern that triggers prompt-injection refusals.

| File | Source URL | What it covers |
|---|---|---|
| `ethskills-audit.md` | <https://ethskills.com/audit/SKILL.md> | EVM audit pipeline (19 domains, parallel sub-agents, 500+ checklist items) |
| `pashov-auditor.md` | <https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md> | Pashov's 4-turn solidity audit methodology (8 specialized agents, dedup + gate eval) |

`provisionAuditorAgent.sh` installs these into `~/skills/` inside the VM.
Refresh by re-running:

```bash
curl -fsSL https://ethskills.com/audit/SKILL.md -o skills/ethskills-audit.md
curl -fsSL https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md -o skills/pashov-auditor.md
```
