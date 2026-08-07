#!/bin/bash
# Layer 1 of REVIEW.md — mechanical checks over completed jobs.
#
# Usage:
#   mech-check.sh <job_id> [job_id...]   # human-readable table
#   mech-check.sh --json <job_id>...     # one JSON object per job
#   mech-check.sh --queue                # every job review-queue.sh offers
#
# Exit 0 when no check FAILs, 1 otherwise — so it can gate a scorecard run.
#
# Reads ALCHEMY_API_KEY (all checks) and, for the escalation check, the
# signing env that _auth.sh needs. Both come from .env.auditor; source it
# yourself or run from a shell that already has it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set — source .env.auditor first}"
command -v cast >/dev/null 2>&1 || { echo "cast (foundry) not on PATH" >&2; exit 2; }

if [[ "${1:-}" == "--queue" ]]; then
  shift
  ids="$("$HERE/review-queue.sh" "$@" | python3 -c 'import sys,json
for line in sys.stdin:
    line = line.strip()
    if line:
        print(json.loads(line)["id"])')"
  [[ -n "$ids" ]] || { echo "review queue is empty"; exit 0; }
  # shellcheck disable=SC2086
  exec python3 "$HERE/mech_check.py" $ids
fi

[[ $# -ge 1 ]] || { echo "usage: $0 <job_id> [job_id...] | --queue" >&2; exit 2; }
exec python3 "$HERE/mech_check.py" "$@"
