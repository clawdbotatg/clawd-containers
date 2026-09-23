#!/bin/bash
# Check whether a job has passed sanitization — required before accepting.
#
# Usage: sanitize-check.sh <job_id>
#
# Returns 0 only when safe=true. Prints exactly one JSON response.
#
# GET only reads the KV cache. The server runs the actual check when a job
# is posted through the website, or when someone opens its job page — a job
# posted straight to the contract never gets checked and sits at
# `pending` forever (jobs 917/918, 2026-09-23: deferred every 5 min for
# a whole morning). The POST endpoint accepts a bare {jobId}, resolves the
# description from chain, runs the check, caches and returns the verdict —
# so on `pending` we trigger it ourselves and use that answer. If the
# trigger fails (400/500/timeout) we fall back to the GET's pending
# response, so the caller keeps deferring instead of guessing.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
BASE="${LEFTCLAW_API:-https://leftclaw.services}"

is_pending() {
  printf '%s' "$1" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if d.get("pending") is True and d.get("safe") is None else 1)
' 2>/dev/null
}

RESP="$(curl -fsS "$BASE/api/job/sanitize?jobId=$1")"

if is_pending "$RESP"; then
  echo "sanitize: job $1 pending — triggering the check" >&2
  TRIG="$(curl -sS --max-time 90 -X POST "$BASE/api/job/sanitize" \
            -H 'Content-Type: application/json' \
            -d "{\"jobId\":\"$1\"}" 2>/dev/null || true)"
  # Only a verdict (safe true/false from valid JSON) replaces the GET.
  if printf '%s' "$TRIG" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d.get("safe"), bool) else 1)
' 2>/dev/null; then
    RESP="$TRIG"
  else
    echo "sanitize: trigger for job $1 returned no verdict — still pending" >&2
  fi
fi

echo "$RESP"
echo "$RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("safe") is True else 1)
'
