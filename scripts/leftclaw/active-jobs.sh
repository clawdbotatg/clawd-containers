#!/bin/bash
# Every OPEN or IN_PROGRESS job on the contract, for the WHOLE fleet — not
# just this box's wallets (that's my-jobs.sh). This is what the job-count
# screens show. Run it first when someone asks "why does it say a job is open".
#
# Usage: active-jobs.sh [--json]
#
# One line per job: id, status, service type, age, stage, worker, and which
# fleet box holds that wallet (fleet-wallets.txt), or "not ours".
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${ALCHEMY_API_KEY:-}" ]]; then
  ALCHEMY_API_KEY="$(grep -h '^ALCHEMY_API_KEY=' "$HERE/../../.env.auditor" 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d "\"' ")"
fi
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"
MIN_LIVE_ID="${MIN_LIVE_ID:-80}"   # 1..34 are dead ghost IDs (see list-jobs.sh)
JOB_T='(uint256,address,uint256,uint256,uint256,string,uint8,uint256,uint256,uint256,string,address,bool,uint8,uint256,string)'

ids() {
  cast call "$CONTRACT" 'getJobsByStatus(uint8)(uint256[])' "$1" --rpc-url "$RPC" \
    | tr -d '[]' | tr ',' '\n' | awk -v min="$MIN_LIVE_ID" '{$1=$1} $1 ~ /^[0-9]+$/ && $1 >= min'
}

rows=""
for st in 0 1; do
  for jid in $(ids "$st"); do
    raw="$(cast call "$CONTRACT" 'getJob(uint256)' "$jid" --rpc-url "$RPC")"
    rows+="$(cast abi-decode --json "f()($JOB_T)" "$raw" | tr -d '\n')"$'\n'
  done
done

ROWS="$rows" python3 - "$HERE/fleet-wallets.txt" "${1:-}" <<'PY'
import json, os, sys, time
wallets = {}
for line in open(sys.argv[1]):
    p = line.split()
    if p and not p[0].startswith("#"):
        wallets[p[0].lower()] = f"{p[1]} ({p[2]})"
status = {0: "OPEN", 1: "IN_PROGRESS"}
out = []
for line in os.environ["ROWS"].splitlines():
    if not line.strip():
        continue
    j = json.loads(line)[0]
    jid, client, svc, desc, st, created, started, worker, stage = (
        int(j[0]), j[1], int(j[2]), j[5], int(j[6]), int(j[7]), int(j[8]), j[11], j[15])
    since = started or created
    w = worker.lower()
    owner = "-" if int(w, 16) == 0 else wallets.get(w, "not ours")
    out.append({"id": jid, "status": status.get(st, st), "serviceTypeId": svc,
                "ageHours": round((time.time() - since) / 3600, 1), "stage": stage,
                "worker": worker, "box": owner, "client": client,
                "description": " ".join(desc.split())[:120]})
if sys.argv[2] == "--json":
    print(json.dumps(out, indent=1))
elif not out:
    print("no open or in-progress jobs (ghost IDs below %s ignored)" % "80")
else:
    for r in out:
        print(f"#{r['id']}  {r['status']}  svc={r['serviceTypeId']}  {r['ageHours']}h  "
              f"stage={r['stage'] or '-'}  box={r['box']}")
        print(f"     {r['description']}")
PY
