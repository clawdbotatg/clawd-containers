#!/usr/bin/env python3
"""client_watch.py <seen_file>   (messages.sh JSON on stdin)

Prints one line per CLIENT message not seen before, and remembers its id.
The wrangler turns each line into a Telegram alert, so a client asking
"when does my job get picked up?" reaches a human — the job chat is
otherwise answered only by the site's AI (job 1247, 2026-11-18).

Only `client_message` from the client counts: escalation responses and AI
replies are machine traffic. Messages older than MAX_AGE_H are marked seen
silently, so a first run on an old job does not replay its history.
Bad input prints nothing and exits 0 — this must never break a wrangler tick.
"""
import json
import os
import sys
import time

MAX_AGE_H = float(os.environ.get("CLIENT_WATCH_MAX_AGE_H", "12"))
MAX_LEN = 300


def main():
    seen_file = sys.argv[1]
    try:
        d = json.loads(sys.stdin.read(), strict=False)
    except Exception:
        return
    msgs = d.get("messages") if isinstance(d, dict) else d
    if not isinstance(msgs, list):
        return
    try:
        seen = set(open(seen_file).read().split())
    except OSError:
        seen = set()
    now, new = time.time(), []
    for m in msgs:
        if not isinstance(m, dict):
            continue
        if m.get("type") != "client_message" or m.get("from") != "client":
            continue
        mid = str(m.get("id") or "")
        if not mid or mid in seen:
            continue
        new.append(mid)
        ts = m.get("timestamp") or 0
        if ts and now - ts / 1000 > MAX_AGE_H * 3600:
            continue
        text = " ".join(str(m.get("content") or "").split())
        if len(text) > MAX_LEN:
            text = text[:MAX_LEN] + "…"
        if text:
            print(text)
    if new:
        try:
            with open(seen_file, "a") as fh:
                fh.write("".join(i + "\n" for i in new))
        except OSError:
            pass


if __name__ == "__main__":
    main()
