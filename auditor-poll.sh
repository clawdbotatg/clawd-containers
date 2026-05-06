#!/bin/bash
# auditor-poll.sh — host-side poller. No AI, no claude calls. Plain bash.
#
# Loop:
#   - every $INTERVAL seconds, check leftclaw for open Service Type 4 jobs
#     and check whether OUR wallet has any in-progress jobs.
#   - if we have work to do AND the auditor VM is stopped, boot it. The
#     in-VM LaunchAgent fires claude with the auditor prompt; claude
#     accepts the job, audits, publishes, completes, exits.
#   - if the auditor is running but has nothing to do (no in-progress,
#     no open), stop it — frees the tart 2-VM cap for other agents.
#
# Usage:
#   ./auditor-poll.sh                # default 60s interval, foreground
#   ./auditor-poll.sh 30             # 30s interval
#   nohup ./auditor-poll.sh &        # background, log to nohup.out
#
# Reads ~/clawd/clawd-containers/.env.auditor for ALCHEMY_API_KEY (the
# leftclaw scripts need it). PRIVATE_KEY/BGIPFS_KEY only matter inside
# the VM — the poller never signs anything.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

VM="auditor"
INTERVAL="${1:-60}"
LOG="${LOG:-/tmp/auditor-poll.log}"

if [[ ! -f .env.auditor ]]; then
  echo "auditor-poll: missing $HERE/.env.auditor" >&2
  exit 2
fi
if [[ ! -x ./scripts/leftclaw/list-jobs.sh ]]; then
  echo "auditor-poll: scripts/leftclaw/list-jobs.sh not found or not executable" >&2
  exit 2
fi

# Pull keys into our env so list-jobs.sh and my-jobs.sh see ALCHEMY_API_KEY.
set -a; source ./.env.auditor; set +a

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

count_jobs() {
  # Args: <script-name> [arg]. Returns number of items in the JSON array,
  # or empty string on error.
  local script="$1"; shift || true
  ./scripts/leftclaw/"$script" "$@" 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(len(d) if isinstance(d, list) else 0)
except Exception:
  pass' 2>/dev/null
}

count_my_inprogress() {
  ./scripts/leftclaw/my-jobs.sh 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(sum(1 for j in d if j.get("status") == 1))
except Exception:
  pass' 2>/dev/null
}

vm_running() {
  # tart list output:  Source Name Disk Size Accessed State
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$VM" \
    && tart list 2>/dev/null \
       | awk -v vm="$VM" '$2==vm && $NF=="running"{f=1} END{exit !f}'
}

start_vm() {
  log "starting $VM (work waiting)"
  if ! ./cont up "$VM" >>"$LOG" 2>&1; then
    log "  cont up failed — see $LOG"
    return 1
  fi
  # Give Aqua + LaunchAgent + iTerm + claude time to settle before the
  # next poll, so we don't immediately re-eval and stop a just-started VM.
  sleep 30
}

stop_vm() {
  log "stopping $VM (idle — no in-progress, no open)"
  ./cont down "$VM" >>"$LOG" 2>&1 || true
}

trap 'log "poll loop exiting"; exit 0' INT TERM

log "auditor poller starting — interval=${INTERVAL}s, log=$LOG"
log "  VM=$VM, contract=0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a (Base)"

while :; do
  open=$(count_jobs list-jobs.sh 4)
  mine=$(count_my_inprogress)
  open=${open:-?}
  mine=${mine:-?}

  if vm_running; then
    if [[ "$mine" == "0" && "$open" == "0" ]]; then
      stop_vm
    else
      log "auditor up, mine=$mine open=$open — leaving alone"
    fi
  else
    if [[ "$mine" =~ ^[1-9] ]]; then
      log "wallet has $mine in-progress audit(s) — booting to resume"
      start_vm
    elif [[ "$open" =~ ^[1-9] ]]; then
      log "found $open open audit job(s) — booting"
      start_vm
    else
      log "idle (mine=$mine open=$open)"
    fi
  fi

  sleep "$INTERVAL"
done
