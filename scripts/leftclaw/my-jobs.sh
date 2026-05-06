#!/bin/bash
# List jobs assigned to MY wallet that aren't yet complete.
# Use this BEFORE list-jobs.sh — finish in-progress work before accepting new.
#
# Usage: my-jobs.sh [service_type_id]   (defaults: any service type)
#
# Output: JSON array. Filters: worker == my address AND status in {0, 1}.
set -euo pipefail
: "${PRIVATE_KEY:?PRIVATE_KEY not set}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="${1:-}"

ME="$(cast wallet address "$PRIVATE_KEY")"
ME_LOWER="$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')"

# Same job-discovery scan as list-jobs.sh — events over the last 100k blocks.
BLOCK="$(cast block-number --rpc-url "$RPC")"
FROM=$(( BLOCK - 100000 ))
JOB_CREATED_TOPIC="0x4426e4a90a9570c8f678a263b11785eaaade8b79d76d18c43d4d8e00062e4f83"

ids="$(cast logs --address "$CONTRACT" --from-block "$FROM" \
        "$JOB_CREATED_TOPIC" --rpc-url "$RPC" 2>/dev/null \
      | grep -A1 -F "$JOB_CREATED_TOPIC" \
      | grep -oE '0x0+[0-9a-f]+' \
      | sed 's/0x0*//' | sort -u)"

declare -a out=()
for hex_id in $ids; do
  [[ -n "$hex_id" ]] || continue
  jid=$((16#$hex_id))
  json="$("$HERE/get-job.sh" "$jid" 2>/dev/null || true)"
  [[ -n "$json" ]] || continue
  match="$(printf '%s' "$json" | ME_LOWER="$ME_LOWER" SVC="$SVC" python3 -c "
import json, os, sys
try:
  d = json.loads(sys.stdin.read())
except Exception:
  sys.exit(0)
me = os.environ.get('ME_LOWER','')
svc = os.environ.get('SVC','')
worker = (d.get('worker') or '').lower()
if worker != me: sys.exit(0)
if d.get('status') not in (0, 1): sys.exit(0)
if svc and str(d.get('serviceTypeId')) != svc: sys.exit(0)
print(json.dumps(d))
")"
  [[ -n "$match" ]] && out+=("$match")
done

printf '['
if (( ${#out[@]} > 0 )); then
  first=1
  for j in "${out[@]}"; do
    if (( first )); then first=0; else printf ','; fi
    printf '%s' "$j"
  done
fi
printf ']\n'
