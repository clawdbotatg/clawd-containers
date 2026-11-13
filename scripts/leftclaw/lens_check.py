#!/usr/bin/env python3
"""lens_check.py — how many of the 12 phase-2 attack agents RETURNED work?

  "12/12"                                                  all lenses delivered
  "9/12 — missing: 2 access-control, 8 asymmetry, 9 boundary"
  "0/12 — no attack-agent log found"

Called by complete.sh in an auditor VM after pipeline_gate.py passes. When the
answer is short of 12 it is written on-chain as a "delivery-check" note, and
the host's completion alert (delivery_summary.py) turns that into a ⚠️ on
Telegram. It never blocks delivery: a lens can be lost for reasons outside the
VM's control, and a paid job stuck forever is worse than a flagged one.

Why this exists (2026-11-13): pipeline_gate.py counts agents STARTED. From job
994 on, attack agents were being stopped by the API safeguard mid-run — jobs
shipped with 5 to 11 of 12 lenses (1222: 5), the auditor said so in its stage
note, and nothing read the note. The cause found that day is fixed
(provisionAuditorAgent.sh strips pashov's print-your-reasoning rule), but this
checks the RESULT, so the next cause shows up on the first job, not the 30th.

How a lens is identified: every attack agent reads its own bundle,
`agent-N-bundle.md` (pashov V4 builds exactly 12). The agent's own transcript
shows which N it opened; its description text is free-form and not trusted.
A lens counts as returned when any agent for that N (first run or respawn)
ended normally with real text — not an API error, not a "stopped by a safety
classifier" note, not empty.

Prints one line, exits 0 always. Tests: python3 tests/test_pipeline_gate.py
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

LENSES = {1: "math-precision", 2: "access-control", 3: "economic-security",
          4: "execution-trace", 5: "invariant", 6: "periphery",
          7: "first-principles", 8: "asymmetry", 9: "boundary",
          10: "numerical-gap", 11: "trust-gap", 12: "flow-gap"}
BUNDLE_RE = re.compile(r"agent-(\d{1,2})-bundle\.md")
STOPPED_RE = re.compile(r"API Error|safeguards? flagged|safety classifier|"
                        r"stopped by (?:a|the) (?:model )?safeguard", re.IGNORECASE)
MIN_CHARS = 200


def read_agent(path):
    """(lens number or None, returned?) for one sub-agent transcript."""
    lens = None
    prompt_lens = None
    final_text, final_stop = "", None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message") if isinstance(d.get("message"), dict) else {}
                content = msg.get("content")
                if d.get("type") == "user" and prompt_lens is None:
                    m = BUNDLE_RE.search(content if isinstance(content, str) else json.dumps(content))
                    prompt_lens = int(m.group(1)) if m else 0
                if d.get("type") != "assistant" or not isinstance(content, list):
                    continue
                text = ""
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use" and lens is None:
                        m = BUNDLE_RE.search(json.dumps(b.get("input")))
                        if m:
                            lens = int(m.group(1))
                    elif b.get("type") == "text":
                        text += b.get("text", "")
                if text:
                    final_text = text
                final_stop = msg.get("stop_reason") or final_stop
    except OSError:
        return None, False
    lens = lens or prompt_lens or None
    if lens not in LENSES:
        return None, False
    ok = (final_stop == "end_turn" and len(final_text) >= MIN_CHARS
          and not STOPPED_RE.search(final_text[:600]))
    return lens, ok


def check():
    import pipeline_gate as pg
    since = pg.boot_time()
    logs = [p for p in glob.glob(os.path.join(pg.PROJECTS, "*", "*", "subagents", "*.jsonl"))
            if since is None or os.path.getmtime(p) >= since]
    seen, returned = set(), set()
    for p in logs:
        lens, ok = read_agent(p)
        if lens is None:
            continue
        seen.add(lens)
        if ok:
            returned.add(lens)
    if not seen:
        return "0/12 — no attack-agent log found"
    missing = [f"{n} {LENSES[n]}" for n in sorted(LENSES) if n not in returned]
    if not missing:
        return "12/12"
    return f"{len(returned)}/12 — missing: {', '.join(missing)}"


if __name__ == "__main__":
    try:
        print(check())
    except Exception as e:      # never get in the way of a delivery
        print(f"?/12 — lens check error ({e!r})")
    sys.exit(0)
