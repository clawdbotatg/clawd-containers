#!/bin/bash
# Complete a leftclaw job on-chain by attaching the result URL.
#
# Usage: complete.sh <job_id> <result_url> [--not-solidity "<what the scope is>"]
#   result_url MUST be a full gateway URL, not a bare CID. Example:
#     https://bafy.../audit-report.md
#
# Reads PRIVATE_KEY and ALCHEMY_API_KEY from env.
#
# In an AUDITOR VM (marker: ~/auditor.prompt.md) delivery is gated on
# pipeline_gate.py: a Solidity audit whose session log does not show the
# multi-agent pipeline ran is REFUSED (exit 3) — see that file for why.
# Every other caller (builder/research/feature VMs, host-auditor on the
# host) has no marker and is not gated.
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

# ── pipeline gate (auditor VMs only) ────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$HOME/auditor.prompt.md" && -f "$HERE/pipeline_gate.py" && "${PIPELINE_GATE:-1}" != "0" ]]; then
  PY="$(command -v python3 || true)"; [[ -n "$PY" ]] || PY=/usr/bin/python3
  if [[ "${3:-}" == "--not-solidity" ]]; then
    WHY="${4:-}"
    if (( ${#WHY} < 12 )); then
      echo "error: --not-solidity needs a real description of the scope (what language, which files)" >&2
      exit 2
    fi
    N="$("$PY" "$HERE/pipeline_gate.py" "$1" --count 2>/dev/null || echo '?')"
    # On-chain, so the operator's completion alert and mech-check both see it.
    "$HERE/log-work.sh" "$1" "delivery-check" \
      "Scope is not Solidity (${WHY:0:240}). The Solidity agent pipeline does not apply; ${N} sub-agent(s) ran." \
      >/dev/null 2>&1 || echo "warning: could not log the delivery-check note" >&2
    echo "pipeline gate: delivered as NOT SOLIDITY — $WHY"
  elif [[ -x "$PY" ]]; then
    "$PY" "$HERE/pipeline_gate.py" "$1" || exit 3
  else
    echo "pipeline gate: WARNING — no python3; cannot verify the pipeline ran" >&2
  fi
fi

cast send "$CONTRACT" "completeJob(uint256,string)" "$1" "$2" \
  --rpc-url "$RPC" \
  --private-key "$PRIVATE_KEY" \
  --json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("tx:", d.get("transactionHash")); print("status:", d.get("status"))'
