#!/bin/bash
# Log work progress on a leftclaw job (visible to the client).
#
# Usage: log-work.sh <job_id> <stage> <note>
#   stage: short label, e.g. "audit-pass-1", "review", "fix-applied"
#   note:  free-form summary, e.g. "Found 2 high, 4 medium, 7 low"
#
# Reads PRIVATE_KEY and ALCHEMY_API_KEY from env.
set -euo pipefail
[[ $# -ge 3 ]] || { echo "usage: $0 <job_id> <stage> <note>" >&2; exit 2; }
: "${PRIVATE_KEY:?PRIVATE_KEY not set — check ~/.env.auditor}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set — check ~/.env.auditor}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

cast send "$CONTRACT" "logWork(uint256,string,string)" "$1" "$3" "$2" \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tx:", d.get("transactionHash")); print("status:", d.get("status"))'
