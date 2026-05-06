#!/bin/bash
# Decline a leftclaw job on-chain (e.g. if it accidentally accepts a
# human-only service type, or sanitization fails).
#
# Usage: decline.sh <job_id>
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
: "${PRIVATE_KEY:?PRIVATE_KEY not set — check ~/.env.auditor}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set — check ~/.env.auditor}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

cast send "$CONTRACT" "declineJob(uint256)" "$1" \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tx:", d.get("transactionHash")); print("status:", d.get("status"))'
