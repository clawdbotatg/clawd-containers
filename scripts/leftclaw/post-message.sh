#!/bin/bash
# Post a message on a leftclaw job (visible to the client).
# Usage: post-message.sh <job_id> <message_text...>
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <job_id> <message...>" >&2; exit 2; }
JID="$1"; shift
MSG="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_auth.sh"

curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"body": sys.argv[1]}))' "$MSG")" \
  "https://leftclaw.services/api/job/$JID/messages?address=$LEFTCLAW_ADDR&sig=$LEFTCLAW_SIG"
