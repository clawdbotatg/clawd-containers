#!/usr/bin/env python3
"""pipeline_gate.py <job_id> [--count]

Did THIS VM's audit session really run the multi-agent pipeline?

Called by complete.sh inside an auditor VM, right before `completeJob`.
  exit 0  deliver (stdout says why)
  exit 3  REFUSE  (stderr tells the auditor what is missing)

Why this exists (2026-11-10): the only thing that made the auditor run the
3 context + 5-8 checklist + 12 attack agents was a sentence in its prompt.
On "small" jobs it decided not to — about 46 Solidity audits between jobs
975 and 1206 shipped as one manual pass, and ~15 more ran 1-6 agents. Every
one said so in its report; nothing stopped delivery. An instruction that
failed that often is not a control. This is: the evidence is Claude Code's
own session log, which the auditor does not write.

What counts: sub-agent spawns since this VM booted — `Agent`/`Task` tool
calls in the session transcripts under ~/.claude/projects, and the
per-agent transcript files next to them. The larger of the two, so a tool
rename in a CLI update cannot zero the count. A fresh VM is cloned per job,
so "since boot" is "for this job"; sessions baked into the gold image are
older than boot and ignored.

Deliberately NOT here: an override the auditor can pass. Small scope, a
fix-review round, a tight clock — none of them is a reason. The two real
exceptions are handled without asking the auditor to judge itself:
  * nothing Solidity under ~/audits/<job>/ (no source, bytecode only, a
    pure JS/Python target)  -> not this pipeline's job, passes;
  * a Solidity repo whose SCOPE is not Solidity -> complete.sh
    `--not-solidity "<scope>"`, which is written on-chain and shows up in
    the operator's completion alert.
An operator (not the auditor) can force one delivery from the host:
  cont ssh auditor -- 'echo "<why>" > ~/.pipeline-override'

Fails OPEN: if the evidence cannot be read at all (no transcripts, a moved
log dir) it prints a WARNING and lets delivery through — a paid, finished
job stuck forever is worse, and the host's completion alert (minutes +
notes, scripts/leftclaw/delivery_summary.py) still catches a fast one.

Tests: python3 tests/test_pipeline_gate.py
"""
import glob
import json
import os
import re
import subprocess
import sys

MIN_AGENTS = int(os.environ.get("PIPELINE_MIN_AGENTS", "20"))
HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
SPAWN_TOOLS = {"Agent", "Task"}


def boot_time():
    """Epoch seconds this machine booted (override for tests)."""
    env = os.environ.get("PIPELINE_GATE_SINCE")
    if env:
        return float(env)
    try:
        out = subprocess.run(["sysctl", "-n", "kern.boottime"],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r"sec\s*=\s*(\d+)", out)
        if m:
            return float(m.group(1))
    except Exception:
        pass
    return None


def spawn_ids(path):
    """tool_use ids of every sub-agent spawn in one session transcript."""
    ids = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"tool_use"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if d.get("type") != "assistant" or d.get("isSidechain"):
                    continue
                content = (d.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for b in content:
                    if (isinstance(b, dict) and b.get("type") == "tool_use"
                            and b.get("name") in SPAWN_TOOLS):
                        ids.add(b.get("id") or f"{path}:{len(ids)}")
    except OSError:
        pass
    return ids


def count_agents():
    """(spawns, sessions_seen). spawns = max(tool calls, per-agent logs)."""
    since = boot_time()
    sessions = [p for p in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl"))
                if since is None or os.path.getmtime(p) >= since]
    calls = set()
    for p in sessions:
        calls |= spawn_ids(p)
    agent_logs = [p for p in glob.glob(os.path.join(PROJECTS, "*", "*", "subagents", "*.jsonl"))
                  if since is None or os.path.getmtime(p) >= since]
    return max(len(calls), len(agent_logs)), len(sessions)


def has_solidity(job_id):
    root = os.path.join(HOME, "audits", str(job_id))
    for _dir, _sub, files in os.walk(root):
        if any(f.endswith(".sol") for f in files):
            return True
    return False


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("usage: pipeline_gate.py <job_id> [--count]", file=sys.stderr)
        return 2
    job = args[0]
    n, sessions = count_agents()
    if "--count" in sys.argv:
        print(n)
        return 0

    override = os.path.join(HOME, ".pipeline-override")
    if os.path.isfile(override) and os.path.getsize(override) > 0:
        why = open(override, errors="replace").read().strip()[:200]
        print(f"pipeline gate: OPERATOR OVERRIDE ({why}) — {n} sub-agents ran")
        return 0
    if not has_solidity(job):
        print(f"pipeline gate: no Solidity under ~/audits/{job}/ — not checked ({n} sub-agents ran)")
        return 0
    if sessions == 0:
        print("pipeline gate: WARNING — no session log found since boot under "
              "~/.claude/projects; cannot verify the pipeline ran. Letting delivery through.")
        return 0
    if n >= MIN_AGENTS:
        print(f"pipeline gate: ok — {n} sub-agents ran (need {MIN_AGENTS})")
        return 0

    print(f"""
REFUSED — job {job} is not delivered. The full audit pipeline has not run.

This session's log shows {n} sub-agent(s) started. A full audit starts at
least {MIN_AGENTS}: 3 context agents (phase 0), 5-8 checklist agents (phase 1) and
the 12 attack agents (phase 2, in waves of 3).

Nothing you reviewed by hand counts toward this, and none of these is a
reason to skip it: a small or single-file scope, a fix-review round, a
target you have audited before, the time already spent. Clients pay for the
independent agents; a one-reviewer pass is a different product.

Do this now:
  1. Open ~/skills/two-phase-audit-v3.md and run every phase you have not
     run, spawning the agents for real, in waves of 3 (model "fable" for
     phases 0 and 1, "opus" for the 12 attack agents).
  2. Rebuild ~/audits/{job}/final-report.md from their output, re-upload it,
     log the stage notes.
  3. Call complete.sh again with the new URL.

Only if the job's SCOPE contains no Solidity at all (e.g. a JS/Python diff
in a repo that also holds contracts), deliver with:
  ~/scripts/leftclaw/complete.sh {job} "<url>" --not-solidity "<what the scope is>"
That statement is written on-chain and sent to the operator.
""", file=sys.stderr)
    return 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as e:  # never strand a paid job on a bug in the checker
        print(f"pipeline gate: WARNING — checker error ({e!r}); letting delivery through.")
        sys.exit(0)
