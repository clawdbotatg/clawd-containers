#!/bin/bash
# research-poll.sh — host-side poller for Service Type 7 (Research Report).
# Mirror of auditor-poll.sh, watching a separate `research` VM.
#
# Loop:
#   - every $INTERVAL seconds, check leftclaw for open Service Type 7 jobs
#     and check whether OUR wallet has any in-progress jobs.
#   - if work to do AND research VM is stopped, re-provision it (so it
#     has the latest scripts/skills/prompt) and bounce it so the in-VM
#     LaunchAgent fires claude with the research prompt.
#   - if running but no work, stop it — frees the tart 2-VM cap.
#
# Usage:
#   ./research-poll.sh           # default 60s, foreground
#   ./research-poll.sh 30        # 30s interval
#   nohup ./research-poll.sh 60 >>/tmp/research-poll.out 2>&1 &
#
# Reads ~/clawd/clawd-containers/.env.research for ALCHEMY_API_KEY.
# PRIVATE_KEY/BGIPFS_KEY only matter inside the VM.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

VM="research"
SERVICE_TYPE="7"
INTERVAL="${1:-60}"
LOG="${LOG:-/tmp/research-poll.log}"

if [[ ! -f .env.research ]]; then
  echo "research-poll: missing $HERE/.env.research" >&2
  exit 2
fi
if [[ ! -x ./scripts/leftclaw/list-jobs.sh ]]; then
  echo "research-poll: scripts/leftclaw/list-jobs.sh not found or not executable" >&2
  exit 2
fi

set -a; source ./.env.research; set +a

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

count_open() {
  ./scripts/leftclaw/list-jobs.sh "$SERVICE_TYPE" 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(len(d) if isinstance(d, list) else 0)
except Exception:
  pass' 2>/dev/null
}

count_my_inprogress() {
  ./scripts/leftclaw/my-jobs.sh "$SERVICE_TYPE" 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(sum(1 for j in d if j.get("status") == 1))
except Exception:
  pass' 2>/dev/null
}

vm_running() {
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$VM" \
    && tart list 2>/dev/null \
       | awk -v vm="$VM" '$2==vm && $NF=="running"{f=1} END{exit !f}'
}

start_vm() {
  log "re-provisioning $VM (work waiting; ensuring fresh scripts)"
  if ! ./cont provision "$VM" ./provisionResearchAgent.sh >>"$LOG" 2>&1; then
    log "  cont provision failed — see $LOG"
    return 1
  fi
  log "  bouncing $VM so fresh Aqua login fires the LaunchAgent"
  ./cont down "$VM" >>"$LOG" 2>&1 || true
  sleep 3
  if ! ./cont up "$VM" >>"$LOG" 2>&1; then
    log "  cont up failed — see $LOG"
    return 1
  fi
  sleep 30
}

stop_vm() {
  log "stopping $VM (idle — no in-progress, no open)"
  ./cont down "$VM" >>"$LOG" 2>&1 || true
}

trap 'log "poll loop exiting"; exit 0' INT TERM

log "research poller starting — interval=${INTERVAL}s, log=$LOG"
log "  VM=$VM, service_type=$SERVICE_TYPE, contract=0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a (Base)"

while :; do
  open=$(count_open)
  mine=$(count_my_inprogress)
  open=${open:-?}
  mine=${mine:-?}

  if vm_running; then
    if [[ "$mine" == "0" && "$open" == "0" ]]; then
      stop_vm
    else
      log "$VM up, mine=$mine open=$open — leaving alone"
    fi
  else
    if [[ "$mine" =~ ^[1-9] ]]; then
      log "wallet has $mine in-progress research job(s) — booting to resume"
      start_vm
    elif [[ "$open" =~ ^[1-9] ]]; then
      log "found $open open research job(s) — booting"
      start_vm
    else
      log "idle (mine=$mine open=$open)"
    fi
  fi

  sleep "$INTERVAL"
done
