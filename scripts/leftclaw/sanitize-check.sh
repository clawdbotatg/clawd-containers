#!/bin/bash
# Check whether a job has passed sanitization — required before accepting.
#
# Usage: sanitize-check.sh <job_id>
#
# Returns 0 only when safe=true. Prints the JSON response.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
RESP="$(curl -fsS "https://leftclaw.services/api/job/sanitize?jobId=$1")"
echo "$RESP"
echo "$RESP" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("safe") is True else 1)
'
