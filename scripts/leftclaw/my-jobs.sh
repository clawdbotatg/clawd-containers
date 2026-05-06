#!/bin/bash
# List jobs assigned to MY wallet that aren't yet complete.
# Use this BEFORE list-jobs.sh — finish in-progress work before accepting new.
#
# Usage: my-jobs.sh [service_type_id]   (defaults: any service type)
#
# Output: JSON array. Filters: worker == my address AND status in {0, 1}.
# Uses getOpenJobs() (status 0) ∪ getJobsByStatus(1) (IN_PROGRESS) as the
# candidate set, then filters by worker.
set -euo pipefail
: "${PRIVATE_KEY:?PRIVATE_KEY not set}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="${1:-}"

ME="$(cast wallet address "$PRIVATE_KEY")"
ME_LOWER="$(printf '%s' "$ME" | tr '[:upper:]' '[:lower:]')"

# OPEN ∪ IN_PROGRESS as candidates.
open_ids="$(cast call "$CONTRACT" 'getOpenJobs()(uint256[])' --rpc-url "$RPC" 2>/dev/null \
            | tr -d '[]' | tr ',' '\n' | awk '{$1=$1};1' | grep -E '^[0-9]+$' || true)"
inprog_ids="$(cast call "$CONTRACT" 'getJobsByStatus(uint8)(uint256[])' 1 --rpc-url "$RPC" 2>/dev/null \
            | tr -d '[]' | tr ',' '\n' | awk '{$1=$1};1' | grep -E '^[0-9]+$' || true)"
ids="$(printf '%s\n%s\n' "$open_ids" "$inprog_ids" | sort -un)"

declare -a out=()
for jid in $ids; do
  [[ -n "$jid" ]] || continue
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
" 2>/dev/null || true)"
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
