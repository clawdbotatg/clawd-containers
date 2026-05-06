#!/bin/bash
# List all OPEN jobs of a given service type, by enumerating the contract's
# getOpenJobs() view (returns uint256[] of currently-OPEN job IDs).
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

# `cast call ... 'getOpenJobs()(uint256[])'` returns a bracketed list,
# e.g.  [1, 2, 3, 92, 93]
#
# The contract has dead "ghost" IDs in its getOpenJobs() output that
# revert with "!job" when getJob() is called. As of May 2026 they're
# IDs 1..34 — querying them on every poll wastes ~14s of RPC time.
# Filter to IDs >= MIN_LIVE_ID. Bump if leftclaw cleans up the ghosts.
MIN_LIVE_ID="${MIN_LIVE_ID:-80}"
ids="$(cast call "$CONTRACT" 'getOpenJobs()(uint256[])' --rpc-url "$RPC" 2>/dev/null \
      | tr -d '[]' | tr ',' '\n' | awk '{$1=$1};1' | grep -E '^[0-9]+$' \
      | awk -v min="$MIN_LIVE_ID" '$1 >= min' || true)"

declare -a out=()
for jid in $ids; do
  [[ -n "$jid" ]] || continue
  json="$("$HERE/get-job.sh" "$jid" 2>/dev/null || true)"
  [[ -n "$json" ]] || continue
  match="$(printf '%s' "$json" | python3 -c "
import json, sys
try:
  d = json.load(sys.stdin)
except Exception:
  sys.exit(0)
if d.get('serviceTypeId') == $SVC and d.get('status') == 0:
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
