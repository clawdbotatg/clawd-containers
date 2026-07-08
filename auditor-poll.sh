#!/bin/bash
# auditor-poll.sh — host-side poller. No AI, no claude calls. Plain bash.
#
# Loop, every $INTERVAL seconds:
#   - list OPEN Service Type 4 jobs on leftclaw, and count how many are
#     *sanitize-safe* (the agent will only ever accept safe jobs — an
#     all-`pending` queue is not work we can do).
#   - count OUR wallet's in-progress jobs.
#   - decide:
#       VM stopped + (in-progress work OR a safe open job)  -> boot it
#       VM running + nothing acceptable (mine=0, safe=0)    -> stop it
#       VM running + safe work but claude idle for too long -> bounce it
#     The in-VM LaunchAgent fires claude with the auditor prompt on boot;
#     claude accepts a job, audits, publishes, completes, exits.
#
# Why "safe" and not raw open count: jobs sit in sanitize `pending` for a
# while, and the agent correctly declines them. Counting raw open jobs
# pinned the VM up doing nothing. We count only what's actually takeable.
#
# Stall guard: if the VM is up with mine=0 but there ARE safe jobs, claude
# should be accepting one. If that persists past $STALL_LIMIT polls, claude
# has wedged / hit a usage limit / gone idle mid-queue — re-provision and
# bounce to get a fresh claude. Reset the counter the moment it makes progress.
#
# Usage:
#   ./auditor-poll.sh                # default 60s interval, foreground
#   ./auditor-poll.sh 30             # 30s interval
#   ./auditor-daemon.sh install      # run it under launchd (survives reboot)
#
# Reads ./.env.auditor for ALCHEMY_API_KEY (the leftclaw scripts need it).
# PRIVATE_KEY/BGIPFS_KEY only matter inside the VM — the poller never signs.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

VM="auditor"
INTERVAL="${1:-60}"
LOG="${LOG:-/tmp/auditor-poll.log}"
# How many consecutive "VM up, safe work waiting, but mine=0" polls before we
# decide claude is wedged and bounce the VM. At 60s that's ~5 minutes grace.
STALL_LIMIT="${STALL_LIMIT:-5}"

if [[ ! -f .env.auditor ]]; then
  echo "auditor-poll: missing $HERE/.env.auditor" >&2
  exit 2
fi
if [[ ! -x ./scripts/leftclaw/list-jobs.sh ]]; then
  echo "auditor-poll: scripts/leftclaw/list-jobs.sh not found or not executable" >&2
  exit 2
fi

# Pull keys into our env so the leftclaw scripts see ALCHEMY_API_KEY.
set -a; source ./.env.auditor; set +a

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

count_my_inprogress() {
  ./scripts/leftclaw/my-jobs.sh 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  print(sum(1 for j in d if j.get("status") == 1))
except Exception:
  print(0)' 2>/dev/null
}

open_and_safe() {
  # Prints "<total_open> <safe_count>". A job is "safe" iff sanitize-check
  # exits 0 (safe=true). On any RPC/parse failure we degrade to "0 0" and
  # simply retry next poll — never a false-positive that boots the VM for
  # nothing.
  local json ids total=0 safe=0 id
  json="$(./scripts/leftclaw/list-jobs.sh 4 2>/dev/null || echo '[]')"
  ids="$(printf '%s' "$json" | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  for j in d: print(j["id"])
except Exception:
  pass' 2>/dev/null || true)"
  for id in $ids; do
    [[ -n "$id" ]] || continue
    total=$((total + 1))
    if ./scripts/leftclaw/sanitize-check.sh "$id" >/dev/null 2>&1; then
      safe=$((safe + 1))
    fi
  done
  printf '%s %s\n' "$total" "$safe"
}

vm_running() {
  # tart list output:  Source Name Disk Size Accessed State
  # awk only (no grep -q): grep's early exit + pipefail = SIGPIPE false negatives.
  tart list 2>/dev/null \
    | awk -v vm="$VM" '$1=="local" && $2==vm && $NF=="running"{f=1} END{exit !f}'
}

start_vm() {
  # Re-provision before each spin-up so the VM always has the latest
  # scripts/skills/prompt, then down+up to force a fresh Aqua login so the
  # in-VM LaunchAgent fires a NEW claude (not the previous boot's process).
  log "re-provisioning $VM (ensuring fresh scripts + fresh claude)"
  if ! ./cont provision "$VM" ./provisionAuditorAgent.sh >>"$LOG" 2>&1; then
    log "  cont provision failed — see $LOG"
    return 1
  fi
  log "  bouncing $VM so a fresh Aqua login fires the LaunchAgent"
  ./cont down "$VM" >>"$LOG" 2>&1 || true
  sleep 3
  if ! ./cont up "$VM" >>"$LOG" 2>&1; then
    log "  cont up failed — see $LOG"
    return 1
  fi
  # Let Aqua + LaunchAgent + iTerm + claude settle before the next poll so
  # we don't immediately re-eval and stop a just-started VM.
  sleep 30
}

stop_vm() {
  log "stopping $VM (${1:-idle})"
  ./cont down "$VM" >>"$LOG" 2>&1 || true
}

trap 'log "poll loop exiting"; exit 0' INT TERM

log "auditor poller starting — interval=${INTERVAL}s, stall_limit=${STALL_LIMIT}, log=$LOG"
log "  VM=$VM, contract=0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a (Base)"

stall=0
while :; do
  read -r open safe <<<"$(open_and_safe)"
  open=${open:-0}; safe=${safe:-0}
  mine=$(count_my_inprogress); mine=${mine:-0}

  if vm_running; then
    if [[ "$mine" == "0" && "$safe" == "0" ]]; then
      stall=0
      stop_vm "no in-progress, open=$open but 0 sanitize-safe"
    elif [[ "$mine" == "0" && "$safe" != "0" ]]; then
      # Safe work exists but claude hasn't taken it. Give it a grace window;
      # if it never accepts, it's wedged/usage-limited — bounce for a fresh one.
      stall=$((stall + 1))
      if (( stall >= STALL_LIMIT )); then
        log "STALL: $VM up ${stall} polls, safe=$safe waiting but mine=0 — claude idle/wedged, bouncing"
        if start_vm; then stall=0; fi
      else
        log "auditor up, mine=0 safe=$safe (open=$open) — awaiting accept (stall ${stall}/${STALL_LIMIT})"
      fi
    else
      stall=0
      log "auditor up, mine=$mine safe=$safe (open=$open) — working"
    fi
  else
    stall=0
    if [[ "$mine" =~ ^[1-9] ]]; then
      log "wallet has $mine in-progress audit(s) — booting to resume"
      start_vm
    elif [[ "$safe" =~ ^[1-9] ]]; then
      log "found $safe sanitize-safe audit job(s) (open=$open) — booting"
      start_vm
    else
      log "idle (mine=$mine open=$open safe=$safe)"
    fi
  fi

  sleep "$INTERVAL"
done
