#!/usr/bin/env python3
"""delivery_summary.py <job_id> — one line for the wrangler's completion alert.

  "97 min, 4 notes"                              a normal audit
  "FAST 6 min, 1 note — too fast for a full audit"
  "FAST 9 min, 2 notes — not Solidity: browser JS diff, web/*.js only"
  "FAST 97 min, 5 notes — attack lenses 9/12 — missing: 2 access-control, …"

Host-side and independent of the VM: it reads only the chain (accept ->
complete time from block TIMESTAMPS, the progress notes). So it still
speaks when the in-VM gate (pipeline_gate.py) was skipped, overridden, or
bypassed. For months the only signal that an audit had been cut to one
manual pass was a mech-check WARN nobody was paged on; this puts it in the
Telegram line the operator already reads for every job.

Never multiply block counts by a block time: Base moved from 2 s to ~0.2 s
blocks around 2026-11 and a "x2s" estimate was 10x wrong.

Prints nothing and exits 0 on any error — the wrangler falls back to its
plain "completed" message.
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FAST_MINUTES = float(os.environ.get("DELIVERY_FAST_MINUTES", "20"))


def block_ts(mc, number):
    req = urllib.request.Request(
        mc.rpc_url(),
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber",
                         "params": [hex(number), False]}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": "leftclaw-wrangler"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return int(json.load(r)["result"]["timestamp"], 16)


def summarize(mc, logs, ts):
    """Pure: (logs, block->timestamp fn) -> summary line or ''."""
    acc = [int(l["blockNumber"], 16) for l in logs if l["topics"][0] == mc.EV_ACCEPTED]
    comp = [int(l["blockNumber"], 16) for l in logs if l["topics"][0] == mc.EV_COMPLETED]
    if not acc or not comp:
        return ""
    minutes = (ts(comp[-1]) - ts(acc[-1])) / 60.0
    notes = []
    for l in logs:
        if l["topics"][0] == mc.EV_WORK:
            notes.extend(mc.decode_strings(l.get("data", "0x")))
    n_ev = sum(1 for l in logs if l["topics"][0] == mc.EV_WORK)
    base = f"{minutes:.0f} min, {n_ev} note{'' if n_ev == 1 else 's'}"
    not_sol = next((s for s in notes if s.startswith("Scope is not Solidity")), "")
    if not_sol:
        why = not_sol[len("Scope is not Solidity"):].strip(" (").split(")")[0][:120]
        return f"FAST {base} — not Solidity: {why}" if minutes < FAST_MINUTES else f"{base}, not Solidity: {why}"
    if minutes < FAST_MINUTES:
        return f"FAST {base} — too fast for a full audit"
    # complete.sh writes this note only when fewer than 12 attack agents
    # returned work (lens_check.py). "FAST" is the wrangler's ⚠️ prefix; the
    # line reads "… completed job N in 97 min, 4 notes — attack lenses 9/12 …".
    short = [s for s in notes if s.startswith("Attack lenses returned:")]
    if short:
        return f"FAST {base} — attack lenses {short[-1][len('Attack lenses returned:'):].strip()[:200]}"
    return base


def main():
    import mech_check as mc
    job = int(sys.argv[1])
    cache = {}

    def ts(n):
        if n not in cache:
            cache[n] = block_ts(mc, n)
        return cache[n]

    line = summarize(mc, mc.job_logs(job), ts)
    if line:
        print(line)


if __name__ == "__main__":
    try:
        main()
    except BaseException:      # incl. mech_check's sys.exit on a missing key
        pass
    sys.exit(0)
