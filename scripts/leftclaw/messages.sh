#!/bin/bash
# Read all messages on a leftclaw job.
# Usage: messages.sh <job_id>
# Output: JSON array of messages.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_auth.sh"

curl -fsS "https://leftclaw.services/api/job/$1/messages?address=$LEFTCLAW_ADDR&sig=$LEFTCLAW_SIG"
