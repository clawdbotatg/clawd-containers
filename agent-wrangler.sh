#!/bin/bash
# agent-wrangler.sh — single host-side daemon. Watches leftclaw for any
# supported job type and spins up the matching worker VM on demand.
# Stops VMs when idle so nothing runs unless there's actual work.
#
# Replaces the per-agent pollers (auditor-poll.sh, research-poll.sh).
#
# Add a new agent type by adding one line to AGENTS below — the rest is
# generic.
#
# Usage:
#   ./agent-wrangler.sh                 # default 60s, foreground
#   ./agent-wrangler.sh 30              # 30s interval
#   nohup ./agent-wrangler.sh 60 >>/tmp/agent-wrangler.out 2>&1 &
#
# Stop with `pkill -f agent-wrangler.sh`. The trap closes cleanly.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# ── Agent registry ──────────────────────────────────────────────────────
# Format: "service_type_id:vm_name:provisioner_script:env_file"
# - service_type_id matches leftclaw's Job.serviceTypeId
# - vm_name is the tart VM the agent runs in (one VM per agent type)
# - provisioner_script: provision*.sh that installs the agent layer
# - env_file: the host-side env file with PRIVATE_KEY/BGIPFS_KEY/etc
#
# Tart caps at 2 mac VMs running concurrently — keep AGENTS at ≤2 unless
# you add coordination logic below.
AGENTS=(
  "4:auditor:provisionAuditorAgent.sh:.env.auditor"
  "5:frontendqa:provisionFrontendQAAgent.sh:.env.frontend-qa"
  "7:research:provisionResearchAgent.sh:.env.research"
)

INTERVAL="${1:-60}"
LOG="${LOG:-/tmp/agent-wrangler.log}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

# Count the JSON array length emitted by list-jobs.sh / my-jobs.sh.
count_jobs() {
  # $1 = script ("list-jobs.sh" | "my-jobs.sh")
  # $2 = service type
  # $3 = env file (sources env in subshell so each agent's keys stay scoped)
  local script="$1" svc="$2" env="$3"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/"$script" "$svc" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(len(d) if isinstance(d, list) else 0)
except Exception:
  pass' 2>/dev/null
}

# Count jobs in MY queue: assigned-to-me but not yet accepted (status=0
# with worker=me) OR in-progress (status=1). leftclaw's flow is:
# client picks a worker -> status stays 0 with worker set -> worker
# calls acceptJob -> status moves to 1. my-jobs.sh already filters to
# {0, 1} for our wallet, so we just count its array length.
count_my_queue() {
  local svc="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/my-jobs.sh "$svc" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(len(d) if isinstance(d, list) else 0)
except Exception:
  pass' 2>/dev/null
}

vm_running() {
  local vm="$1"
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$vm" \
    && tart list 2>/dev/null \
       | awk -v vm="$vm" '$2==vm && $NF=="running"{f=1} END{exit !f}'
}

start_vm() {
  local vm="$1" prov="$2"
  log "  re-provisioning $vm with ./$prov"
  if ! ./cont provision "$vm" "./$prov" >>"$LOG" 2>&1; then
    log "  cont provision failed — see $LOG"
    return 1
  fi
  log "  bouncing $vm so fresh Aqua login fires the LaunchAgent"
  ./cont down "$vm" >>"$LOG" 2>&1 || true
  sleep 3
  if ! ./cont up "$vm" >>"$LOG" 2>&1; then
    log "  cont up failed (tart 2-VM cap?) — see $LOG"
    return 1
  fi
  # Settle time so claude has Aqua + LaunchAgent + iTerm + scripts up
  # before the next loop iteration sees the queue change.
  sleep 30
}

stop_vm() {
  local vm="$1"
  log "stopping $vm (idle — no in-progress, no open)"
  ./cont down "$vm" >>"$LOG" 2>&1 || true
}

trap 'log "wrangler exiting"; exit 0' INT TERM

log "agent-wrangler starting — interval=${INTERVAL}s, log=$LOG"
for entry in "${AGENTS[@]}"; do
  IFS=":" read -r svc vm prov env <<<"$entry"
  log "  registered: type=$svc vm=$vm prov=$prov env=$env"
done

while :; do
  for entry in "${AGENTS[@]}"; do
    IFS=":" read -r svc vm prov env <<<"$entry"

    if [[ ! -f "$env" ]]; then
      log "$vm: missing $env on host — skipping (create it to enable)"
      continue
    fi
    if [[ ! -x "$prov" ]]; then
      log "$vm: provisioner $prov not found or not executable — skipping"
      continue
    fi

    open=$(count_jobs list-jobs.sh "$svc" "$env")
    mine=$(count_my_queue "$svc" "$env")
    open=${open:-?}
    mine=${mine:-?}

    if vm_running "$vm"; then
      if [[ "$mine" == "0" && "$open" == "0" ]]; then
        stop_vm "$vm"
      else
        log "$vm up, mine=$mine open=$open — leaving alone"
      fi
    else
      if [[ "$mine" =~ ^[1-9] ]]; then
        log "$vm: wallet has $mine assigned/in-progress type-$svc job(s) — booting"
        start_vm "$vm" "$prov" || log "$vm: start failed; will retry next tick"
      elif [[ "$open" =~ ^[1-9] ]]; then
        log "$vm: $open open type-$svc job(s) — booting"
        start_vm "$vm" "$prov" || log "$vm: start failed; will retry next tick"
      else
        log "$vm: idle (type-$svc mine=$mine open=$open)"
      fi
    fi
  done
  sleep "$INTERVAL"
done
