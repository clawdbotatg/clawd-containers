#!/bin/bash
# List open jobs of a given service type — read on-chain (no auth needed).
# Falls back to scanning recent JobCreated events if the contract method
# isn't available.
#
# Usage: list-jobs.sh [service_type_id]   (defaults to 4 = audit)
#
# Output: JSON array of {id, client, serviceTypeId, status, description}.
set -euo pipefail
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

SVC="${1:-4}"
CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Strategy: scan the last ~50k blocks for JobCreated events to gather
# candidate IDs (this is what claude reverse-engineered last run, so we
# know it works). Then for each candidate, use ./get-job.sh to decode
# and filter. Robust to docs being out of date about contract method names.

BLOCK="$(cast block-number --rpc-url "$RPC")"
FROM=$(( BLOCK - 100000 ))
JOB_CREATED_TOPIC="0x4426e4a90a9570c8f678a263b11785eaaade8b79d76d18c43d4d8e00062e4f83"

# `cast logs` returns YAML-ish blocks. We want topic[1] of each event,
# which encodes the jobId.
ids="$(cast logs --address "$CONTRACT" --from-block "$FROM" \
        "$JOB_CREATED_TOPIC" --rpc-url "$RPC" 2>/dev/null \
      | awk '/^[[:space:]]*0x4426e4a90a9570c8f678a263b11785eaaade8b79d76d18c43d4d8e00062e4f83$/{getline; print $1}' \
      | sed 's/0x0*//' | sort -u)"

# If awk path didn't work (formatting changed), fall back to grep approach.
if [[ -z "$ids" ]]; then
  ids="$(cast logs --address "$CONTRACT" --from-block "$FROM" \
          "$JOB_CREATED_TOPIC" --rpc-url "$RPC" 2>/dev/null \
        | grep -A1 -F "$JOB_CREATED_TOPIC" \
        | grep -oE '0x0+[0-9a-f]+' \
        | sed 's/0x0*//' | sort -u)"
fi

# For each candidate, decode and filter.
declare -a out=()
for hex_id in $ids; do
  [[ -n "$hex_id" ]] || continue
  jid=$((16#$hex_id))
  json="$("$HERE/get-job.sh" "$jid" 2>/dev/null || true)"
  [[ -n "$json" ]] || continue
  match="$(printf '%s' "$json" | python3 -c "
import json, sys
try:
  d = json.loads(sys.stdin.read())
except Exception:
  sys.exit(0)
if d.get('serviceTypeId') == $SVC and d.get('status') == 0:
  print(json.dumps(d))
")"
  [[ -n "$match" ]] && out+=("$match")
done

# Emit JSON array (handle empty array safely under set -u)
printf '['
if (( ${#out[@]} > 0 )); then
  first=1
  for j in "${out[@]}"; do
    if (( first )); then first=0; else printf ','; fi
    printf '%s' "$j"
  done
fi
printf ']\n'
