#!/bin/bash
# Accept a leftclaw job on-chain (one tx).
#
# Usage: accept.sh <job_id>
#
# Reads PRIVATE_KEY and ALCHEMY_API_KEY from env. The key is passed to
# `cast send` via --private-key — it never appears in args or stdout.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
: "${PRIVATE_KEY:?PRIVATE_KEY not set — check ~/.env.auditor}"
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set — check ~/.env.auditor}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

cast send "$CONTRACT" "acceptJob(uint256)" "$1" \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tx:", d.get("transactionHash")); print("status:", d.get("status"))'
