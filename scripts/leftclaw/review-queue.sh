#!/bin/bash
# List COMPLETED jobs newer than a watermark, one JSON object per line —
# the intake for the second-pass review layer (see REVIEW.md).
#
# Usage:
#   review-queue.sh              # jobs newer than the stored watermark
#   review-queue.sh <from_id>    # jobs with id > <from_id> (watermark untouched)
#   review-queue.sh --mark <id>  # record <id> as reviewed; print nothing
#
# Output: {"id": …, "serviceTypeId": …, "resultURL": …, "description": …}
# resultURL is best-effort (extracted from the getJob payload's strings);
# null when the completion didn't include one.
set -euo pipefail
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
HERE="$(cd "$(dirname "$0")" && pwd)"
WATERMARK_FILE="${REVIEW_WATERMARK_FILE:-$HOME/.config/leftclaw-review/watermark}"

if [[ "${1:-}" == "--mark" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 --mark <job_id>" >&2; exit 2; }
  mkdir -p "$(dirname "$WATERMARK_FILE")"
  echo "$2" > "$WATERMARK_FILE"
  exit 0
fi

from="${1:-}"
if [[ -z "$from" ]]; then
  from="$(cat "$WATERMARK_FILE" 2>/dev/null || echo 0)"
fi

# All COMPLETE job ids, filtered to > from. Same bracketed-list parsing
# as list-jobs.sh.
ids="$(cast call "$CONTRACT" 'getJobsByStatus(uint8)(uint256[])' 2 --rpc-url "$RPC" 2>/dev/null \
      | tr -d '[]' | tr ',' '\n' | awk '{$1=$1};1' | grep -E '^[0-9]+$' \
      | awk -v min="$from" '$1 > min' || true)"

for jid in $ids; do
  json="$("$HERE/get-job.sh" "$jid" 2>/dev/null || true)"
  [[ -n "$json" ]] || continue
  printf '%s' "$json" | python3 -c '
import json, re, sys
d = json.load(sys.stdin)
strings = [d.get("description") or ""] + (d.get("_other_strings") or [])
url = None
for s in strings:
    m = re.search(r"https://\S+ipfs\S+", s)
    if m:
        url = m.group(0).rstrip(").,")
        break
print(json.dumps({
    "id": d.get("id"),
    "serviceTypeId": d.get("serviceTypeId"),
    "resultURL": url,
    "description": (d.get("description") or "")[:200],
}))'
done
