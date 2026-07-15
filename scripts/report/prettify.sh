#!/bin/bash
# prettify.sh — render a completed leftclaw audit job's IPFS report as a
# pretty HTML page for hosting at https://leftclaw.services/result/<id>.html
#
# Usage:
#   prettify.sh <job_id> [result_url] [-o <out.html>]
#
# If result_url is omitted it is read from the job on-chain (needs
# ALCHEMY_API_KEY, loaded from .env.auditor if not already set).
# Default output: scripts/report/out/<job_id>.html
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

JOB_ID="${1:-}"; [[ "$JOB_ID" =~ ^[0-9]+$ ]] || { echo "usage: prettify.sh <job_id> [result_url] [-o out.html]" >&2; exit 2; }
shift

RESULT_URL=""
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    https://*) RESULT_URL="$1"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$OUT" ]] || OUT="$HERE/out/$JOB_ID.html"
mkdir -p "$(dirname "$OUT")"

# ---- resolve result URL on-chain if not supplied (same independent decode
# as host-auditor/check-job.sh: the URL is ABI-encoded bytes in the blob) ----
if [[ -z "$RESULT_URL" ]]; then
  if [[ -z "${ALCHEMY_API_KEY:-}" ]]; then
    set -a; source "$REPO_ROOT/.env.auditor" 2>/dev/null || true; set +a
  fi
  : "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set (and no result_url given)}"
  CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
  RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
  raw=$(cast call "$CONTRACT" "getJob(uint256)" "$JOB_ID" --rpc-url "$RPC")
  RESULT_URL=$(printf '%s' "$raw" | python3 -c 'import re,sys
raw=sys.stdin.read().strip()
try: txt=bytes.fromhex(raw[2:]).decode("latin-1")
except Exception: txt=raw
m=re.search(r"https://[ -~]*?ipfs[ -~]*?/",txt)
print(m.group(0) if m else "")')
  [[ -n "$RESULT_URL" ]] || { echo "error: job $JOB_ID has no resultURL on-chain (not completed?)" >&2; exit 1; }
fi

# ---- fetch the markdown ----
TMP_MD="$(mktemp -t leftclaw-report-XXXXXX).md"
trap 'rm -f "$TMP_MD"' EXIT
curl -fsSL -m 60 "$RESULT_URL" -o "$TMP_MD"
[[ -s "$TMP_MD" ]] || { echo "error: empty report fetched from $RESULT_URL" >&2; exit 1; }
# Cheap shape check: a markdown report should start with a heading, not HTML/JSON.
head -c1 "$TMP_MD" | grep -q '#' || echo "warn: report does not start with '#' — rendering anyway" >&2

# ---- render ----
node "$HERE/render.mjs" --job "$JOB_ID" --md "$TMP_MD" --ipfs "$RESULT_URL" -o "$OUT"
