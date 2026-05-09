#!/usr/bin/env bash
# Ensure foundry tools (cast) are available — the wrangler runs inside tmux
# which may not inherit the user's PATH.
export PATH="$HOME/.foundry/bin:$PATH"

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
# Tart caps at 2 mac VMs running concurrently. AGENTS may exceed 2 — boots
# happen opportunistically (each tick tries to start any agent whose queue
# has work; tart rejects beyond the cap and we retry next tick). Idle VMs
# are stopped on each tick so the cap is freed up as queues drain.
AGENTS=(
  "4:auditor:provisionAuditorAgent.sh:.env.auditor"
  "5:frontendqa:provisionFrontendQAAgent.sh:.env.frontend-qa"
  "6:builder:provisionBuilderAgent.sh:.env.builder"
  "7:research:provisionResearchAgent.sh:.env.research"
  "10:feature:provisionFeatureAgent.sh:.env.feature"
)

INTERVAL="${1:-60}"
LOG="${LOG:-/tmp/agent-wrangler.log}"

# Soft time cap per VM. If a VM has been running longer than this, the
# wrangler stops it on the next tick — even if its queue still has work.
# Backstop for runaway/stuck claude sessions; tunable per agent type by
# editing TIME_CAP_<UPPER_VM_NAME>_SECONDS below.
#
# Defaults: 2h for builder + feature (1.5h playbook budget + 30 min slack),
# 1h for the others (audit/qa/research are quicker).
TIME_CAP_DEFAULT_SECONDS="${TIME_CAP_DEFAULT_SECONDS:-3600}"   # 1h
TIME_CAP_BUILDER_SECONDS="${TIME_CAP_BUILDER_SECONDS:-7200}"   # 2h
TIME_CAP_FEATURE_SECONDS="${TIME_CAP_FEATURE_SECONDS:-7200}"   # 2h

# Per-VM start-time markers. Used to compute elapsed for the cap.
STATE_DIR="${TMPDIR:-/tmp}/agent-wrangler"
mkdir -p "$STATE_DIR"

# Max consecutive start_vm() failures before we back off and stop retrying
# until the VM's queue empties (or it eventually starts).
MAX_START_RETRIES="${MAX_START_RETRIES:-3}"

# Maximum concurrent tart VMs the host can run. Apple Silicon's
# Virtualization framework documents a cap of 2 for arm64 macOS guests,
# but on some hosts the effective cap is 1 (other virtualization tools
# running, hardware/OS variation). Default to 1 — override with
# MAX_VMS=2 if your host confirms it can run two.
MAX_VMS="${MAX_VMS:-1}"

# Per-VM consecutive start_vm() failure counter. Reset on a successful
# start or when the queue becomes empty. Stored as "<vm> <count>" lines
# in a flat file (bash 3.2 on macOS lacks associative arrays).
FAILURES_FILE="$STATE_DIR/failures.txt"

# Telegram dedup buffer: hash -> last-sent-timestamp. Prevents duplicate
# notifications when multiple wranglers run or retries happen rapidly.
# Stored as "<hash> <timestamp>" lines in a flat file.
NOTIFY_DEDUP_FILE="$STATE_DIR/notify_dedup.txt"

# Read a numeric value keyed by $1 from flat file $2. Echoes 0 if missing.
kv_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || { echo 0; return; }
  local val
  val=$(grep "^${key} " "$file" 2>/dev/null | tail -1 | awk '{print $2}')
  echo "${val:-0}"
}

# Set value $2 for key $1 in flat file $3 (replacing any prior entry).
kv_set() {
  local key="$1" val="$2" file="$3"
  touch "$file"
  local tmp="$file.tmp"
  grep -v "^${key} " "$file" > "$tmp" 2>/dev/null || true
  echo "${key} ${val}" >> "$tmp"
  mv "$tmp" "$file"
}

# Wipe the failures file so every VM starts the next tick at 0. Called
# whenever a slot frees up (any stop_vm) — without this, a VM that hit
# MAX_START_RETRIES while another VM was hogging a slot would stay
# backed-off forever, since the back-off only clears when its own queue
# empties. Resetting on slot turnover gives all agents a fair retry.
reset_all_failures() {
  : > "$FAILURES_FILE"
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
}

# ── Telegram notifications ──────────────────────────────────────────────
# Optional. Reads creds from .env.notify (gitignored via .env.* glob).
# Silent no-op when creds are missing or curl fails — a dropped message
# must never break the wrangler loop.
[[ -f .env.notify ]] && source .env.notify || true

notify() {
  local msg="$1"
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0

  # Deduplicate: skip if this exact message was sent in the last 2 minutes.
  # Prevents runaway loops when multiple wranglers or rapid retries fire.
  local hash now last
  hash=$(printf '%s' "$msg" | shasum -a 256 | awk '{print $1}')
  now=$(date +%s)
  last=$(kv_get "$hash" "$NOTIFY_DEDUP_FILE")
  if (( now - last < 120 )); then
    return 0
  fi
  kv_set "$hash" "$now" "$NOTIFY_DEDUP_FILE"

  curl -fsS -m 5 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${msg}" \
    >/dev/null 2>&1 || true
}

# First open job ID for a service type, or empty string if none / on error.
# Sources the agent's env file in a subshell so ALCHEMY_API_KEY is scoped.
get_first_job_id() {
  local svc="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/list-jobs.sh "$svc" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  if isinstance(d, list) and d:
    jid = d[0].get("id")
    if jid is not None:
      print(jid)
except Exception:
  pass' 2>/dev/null
}

# One-line "<description-snippet> (<price>)" summary for a job.
# Price segment is omitted if get-job.sh does not emit one.
get_job_meta() {
  local jid="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/get-job.sh "$jid" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  desc = (d.get("description") or "").strip().replace("\n", " ").replace("\r", " ")
  if len(desc) > 60:
    desc = desc[:57].rstrip() + "..."
  price = d.get("price")
  if price in (None, ""):
    print(desc)
  else:
    print(f"{desc} ({price})")
except Exception:
  pass' 2>/dev/null
}

# Cap for a given VM name — special-cased for builder, default otherwise.
cap_for() {
  case "$1" in
    builder) echo "$TIME_CAP_BUILDER_SECONDS" ;;
    feature) echo "$TIME_CAP_FEATURE_SECONDS" ;;
    *)       echo "$TIME_CAP_DEFAULT_SECONDS" ;;
  esac
}

mark_started() {
  date +%s > "$STATE_DIR/$1.started"
}
clear_started() {
  rm -f "$STATE_DIR/$1.started"
}
elapsed_seconds() {
  local f="$STATE_DIR/$1.started"
  [[ -f "$f" ]] || { echo 0; return; }
  echo $(( $(date +%s) - $(cat "$f") ))
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

# Does a per-agent gold image exist? Fast path uses it.
gold_exists() {
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$1"
}

# Does a VM exist (any state)?
vm_exists() {
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$1"
}

start_vm() {
  local vm="$1" prov="$2" svc="${3:-?}" env="${4:-}" mine="${5:-0}"
  local jid="" meta=""
  if [[ -n "$env" && -f "$env" ]]; then
    jid=$(get_first_job_id "$svc" "$env" || true)
    # list-jobs.sh only returns OPEN jobs. If we're re-booting for an
    # already-assigned/in-progress job (mine > 0), fall back to my-jobs.sh
    # so the notification names the actual job instead of "type-N".
    if [[ -z "$jid" && "$mine" =~ ^[1-9] ]]; then
      jid=$(
        ( set -a; source "$env" 2>/dev/null; set +a
          ./scripts/leftclaw/my-jobs.sh "$svc" 2>/dev/null
        ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  if isinstance(d, list) and d:
    jid = d[0].get("id")
    if jid is not None:
      print(jid)
except Exception:
  pass' 2>/dev/null
      )
    fi
    [[ -n "$jid" ]] && meta=$(get_job_meta "$jid" "$env" || true)
  fi
  local desc
  if [[ -n "$jid" && -n "$meta" ]]; then
    desc="job ${jid}: ${meta}"
  else
    desc="(type-${svc})"
  fi
  local gold="${vm}-gold"

  if gold_exists "$gold"; then
    # Fast path: clone per-agent gold (Tier 1+2 baked) and sync Tier 3.
    log "  fast path: cloning ${gold} -> ${vm} + sync"
    if vm_exists "$vm"; then
      ./cont rm "$vm" >>"$LOG" 2>&1 || true
    fi
    if ! tart clone "$gold" "$vm" >>"$LOG" 2>&1; then
      log "  tart clone $gold failed — falling back to full provision"
      if ! ./cont provision "$vm" "./$prov" >>"$LOG" 2>&1; then
        log "  cont provision failed — cleaning up zombie VM"
        ./cont down "$vm" >>"$LOG" 2>&1 || true
        ./cont rm "$vm"   >>"$LOG" 2>&1 || true
        notify "🔴 ${vm} failed to start ${desc}"
        return 1
      fi
    elif ! ./cont sync "$vm" "./$prov" >>"$LOG" 2>&1; then
      log "  cont sync failed — cleaning up zombie VM"
      ./cont down "$vm" >>"$LOG" 2>&1 || true
      ./cont rm "$vm"   >>"$LOG" 2>&1 || true
      notify "🔴 ${vm} failed to start ${desc}"
      return 1
    fi
  else
    # Slow path: no per-agent gold yet. Run the full provisioner.
    # Run ./bake-agent-gold.sh $vm to build one and speed up future boots.
    log "  no ${gold} — full provision (run ./bake-agent-gold.sh $vm to enable fast path)"
    if ! ./cont provision "$vm" "./$prov" >>"$LOG" 2>&1; then
      log "  cont provision failed — cleaning up zombie VM"
      ./cont down "$vm" >>"$LOG" 2>&1 || true
      ./cont rm "$vm"   >>"$LOG" 2>&1 || true
      notify "🔴 ${vm} failed to start ${desc}"
      return 1
    fi
  fi

  log "  bouncing $vm so fresh Aqua login fires the LaunchAgent"
  ./cont down "$vm" >>"$LOG" 2>&1 || true
  sleep 3
  if ! ./cont up "$vm" >>"$LOG" 2>&1; then
    log "  cont up failed (tart 2-VM cap?) — see $LOG"
    notify "🔴 ${vm} failed to start ${desc}"
    return 1
  fi
  mark_started "$vm"
  notify "🟢 ${vm} starting ${desc}"
  # Settle time so claude has Aqua + LaunchAgent + iTerm + scripts up
  # before the next loop iteration sees the queue change.
  sleep 30
}

stop_vm() {
  local vm="$1" reason="${2:-idle — no in-progress, no open}"
  log "stopping $vm ($reason)"
  notify "🔴 ${vm} stopped — ${reason}"
  ./cont down "$vm" >>"$LOG" 2>&1 || true
  clear_started "$vm"
  reset_all_failures
  log "  reset all failure counters — slot freed, backed-off agents get a fresh shot"
}

# ── Skills refresh ─────────────────────────────────────────────────────
# Run ./refresh-skills.sh if skills/ is missing or older than 24h.
# This is a no-op most of the time; the first clone may take ~30s.
SKILLS_MAX_AGE_HOURS="${SKILLS_MAX_AGE_HOURS:-24}"

needs_skills_refresh() {
  # Core skill tree that several agents depend on
  local marker="skills/evm-audit-skills/.git"
  [[ -e "$marker" ]] || return 0
  local age_hours
  age_hours=$(( ($(date +%s) - $(stat -f %m "$marker" 2>/dev/null || echo 0)) / 3600 ))
  (( age_hours >= SKILLS_MAX_AGE_HOURS )) && return 0
  return 1
}

refresh_skills() {
  if needs_skills_refresh; then
    log "skills stale or missing — running ./refresh-skills.sh (this may take ~30s)"
    if ./refresh-skills.sh >>"$LOG" 2>&1; then
      log "skills refreshed ok"
    else
      log "skills refresh FAILED — agents that depend on skills/ may fail provisioning"
    fi
  fi
}

trap 'log "wrangler exiting"; exit 0' INT TERM

log "agent-wrangler starting — interval=${INTERVAL}s, log=$LOG"
for entry in "${AGENTS[@]}"; do
  IFS=":" read -r svc vm prov env <<<"$entry"
  log "  registered: type=$svc vm=$vm prov=$prov env=$env"
done

while :; do
  refresh_skills

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
      # If the wrangler restarted while a VM was already running, the
      # marker won't exist — assume "now" so we don't immediately
      # time-cap a fresh runtime.
      [[ -f "$STATE_DIR/$vm.started" ]] || mark_started "$vm"
      cap=$(cap_for "$vm")
      elapsed=$(elapsed_seconds "$vm")
      if (( elapsed > cap )); then
        stop_vm "$vm" "TIME CAP EXCEEDED (${elapsed}s > ${cap}s) — runaway/stuck session, force-stopping"
      elif [[ "$mine" == "0" && "$open" == "0" ]]; then
        stop_vm "$vm"
      else
        log "$vm up, mine=$mine open=$open — leaving alone (elapsed ${elapsed}s/${cap}s)"
      fi
    else
      if [[ "$mine" =~ ^[1-9] || "$open" =~ ^[1-9] ]]; then
        fails=$(kv_get "$vm" "$FAILURES_FILE")
        if (( fails >= MAX_START_RETRIES )); then
          log "$vm: backing off — ${fails} consecutive start failures (will retry when queue empties)"
        else
          # Check VM slot availability BEFORE attempting to boot.
          # Skip the boot when MAX_VMS is hit instead of consuming a retry.
          _running=$(tart list 2>/dev/null | awk '/running/{n++} END{print n+0}')
          if (( _running >= MAX_VMS )); then
            log "$vm: no VM slot available (${_running}/${MAX_VMS} running) — skipping this tick"
            continue
          fi
          if [[ "$mine" =~ ^[1-9] ]]; then
            log "$vm: wallet has $mine assigned/in-progress type-$svc job(s) — booting"
          else
            log "$vm: $open open type-$svc job(s) — booting"
          fi
          if start_vm "$vm" "$prov" "$svc" "$env" "$mine"; then
            kv_set "$vm" 0 "$FAILURES_FILE"
          else
            new_fails=$(( fails + 1 ))
            kv_set "$vm" "$new_fails" "$FAILURES_FILE"
            log "$vm: start failed (${new_fails}/${MAX_START_RETRIES}); will retry next tick"
            if (( new_fails >= MAX_START_RETRIES )); then
              log "WARNING: $vm hit ${MAX_START_RETRIES} consecutive start failures — backing off until queue empties"
              notify "🔴 ${vm} failed to start ${MAX_START_RETRIES} times in a row — backing off until queue empties"
            fi
          fi
        fi
      else
        log "$vm: idle (type-$svc mine=$mine open=$open)"
        kv_set "$vm" 0 "$FAILURES_FILE"
      fi
    fi
  done
  sleep "$INTERVAL"
done
