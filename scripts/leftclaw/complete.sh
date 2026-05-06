#!/bin/bash
# Complete a leftclaw job on-chain by attaching the result URL.
#
# Usage: complete.sh <job_id> <result_url>
#   result_url MUST be a full gateway URL, not a bare CID. Example:
#     https://bafy.../audit-report.md
#
# Reads PRIVATE_KEY and ALCHEMY_API_KEY from env.
set -euo pipefail
[[ $# -ge 2 ]] || { echo "usage: $0 <job_id> <result_url>" >&2; exit 2; }
: "${PRIVATE_KEY:?PRIVATE_KEY not set — check ~/.env.auditor}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set — check ~/.env.auditor}"

# Sanity-check URL shape per leftclaw contract docs.
case "$2" in
  https://*) ;;
  *) echo "error: result_url must start with https:// (full URL, not CID)" >&2; exit 2 ;;
esac

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

cast send "$CONTRACT" "completeJob(uint256,string)" "$1" "$2" \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tx:", d.get("transactionHash")); print("status:", d.get("status"))'
