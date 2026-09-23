#!/bin/bash
# Post a message on a leftclaw job (visible to the client).
# Usage: post-message.sh <job_id> <message_text...>
#
# The server's POST /api/job/{id}/messages accepts exactly ONE shape from
# a worker: {type:"escalation", from:"bot", question, details, stage}
# (leftclaw-services, packages/nextjs/app/api/job/[id]/messages/route.ts).
# This script used to send {body: ...} and got a 400 on every call, so
# from ~2026-08 to 2026-09-23 no fleet message reached a client: not the
# "too complex, resubmit smaller" notes, not the delivery-blocked notes
# from job 860. The client UI shows an escalation as a "bot blocked" card
# with `question` as the headline and `details` as the body — so the first
# line of the message becomes the headline. POST_STAGE labels it
# (default "update"). A plain bot note type would need a server change.
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <job_id> <message...>" >&2; exit 2; }
JID="$1"; shift
MSG="$*"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/_auth.sh"

PAYLOAD="$(python3 -c '
import json, sys
msg = sys.argv[1].strip()
head = msg.splitlines()[0][:200] if msg else "(empty)"
print(json.dumps({"type": "escalation", "from": "bot", "question": head,
                  "details": msg, "stage": sys.argv[2]}))
' "$MSG" "${POST_STAGE:-update}")"

curl -fsS -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "https://leftclaw.services/api/job/$JID/messages?address=$LEFTCLAW_ADDR&sig=$LEFTCLAW_SIG"
