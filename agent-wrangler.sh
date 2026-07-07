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
  "4:auditor2:provisionAuditorAgent.sh:.env.auditor2"
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
TIME_CAP_AUDITOR_SECONDS="${TIME_CAP_AUDITOR_SECONDS:-7200}"   # 2h — real audits were hitting the 1h cap

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
  # >&2: several helpers (job_advanceable via count_advanceable_open) run
  # inside $(...) command substitutions — log lines on stdout would be
  # captured into the caller's variable instead of reaching the console.
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2
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

# ── Host-side OAuth health gate ─────────────────────────────────────────
# Job 188's failure mode: the host's claude OAuth token was stale, every
# VM got a dead token, every boot stalled at the no-accept grace cliff.
# We verify the host's auth works BEFORE booting any VM. If it doesn't,
# we don't boot — we wait and alert. Cached for 5 min to keep the cost down.
#
# IMPORTANT — what counts as "dead": the deterministic source of truth is the
# macOS keychain token's own `expiresAt`, which Claude Code refreshes in the
# background. A future expiresAt means auth is genuinely fine. We do NOT gate
# on a live `claude -p` ping in the healthy path: that ping is flaky (API
# latency spikes), and treating a slow ping as "OAuth is dead" was firing
# false Telegram alarms + pausing the fleet while the token was perfectly
# valid. The live ping is now only a fallback when the token is actually
# at/past expiry (where a refresh may have just rotated it).
HOST_OAUTH_CACHE_SECONDS="${HOST_OAUTH_CACHE_SECONDS:-300}"

# Seconds until the keychain Claude token expires. Prints an integer (may be
# negative if expired); prints nothing if the entry is missing/unreadable.
host_oauth_seconds_left() {
  security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null | python3 -c '
import json,sys,time
try:
    o=json.load(sys.stdin)["claudeAiOauth"]
    if not o.get("accessToken"): sys.exit(0)
    print(int(o.get("expiresAt",0)/1000 - time.time()))
except Exception:
    pass
' 2>/dev/null
}

host_oauth_ok() {
  local cache="$STATE_DIR/host_oauth.status"
  local stamp="$STATE_DIR/host_oauth.checked-at"
  local now
  now=$(date +%s)
  if [[ -f "$stamp" && -f "$cache" ]]; then
    local checked
    checked=$(cat "$stamp" 2>/dev/null || echo 0)
    if (( now - checked < HOST_OAUTH_CACHE_SECONDS )); then
      [[ "$(cat "$cache" 2>/dev/null)" == "ok" ]]
      return $?
    fi
  fi

  # Healthy path: keychain token still valid (>2 min headroom). Deterministic,
  # no network call, no false alarms. This is the normal state.
  local left
  left=$(host_oauth_seconds_left)
  if [[ -n "$left" ]] && (( left > 120 )); then
    date +%s > "$stamp"; echo "ok" > "$cache"; return 0
  fi

  # Token missing / expired / near-expiry. The background refresh may have
  # just rotated it, so confirm with a live ping (which itself triggers a
  # refresh if needed). Retry to absorb transient slowness — only a genuine,
  # repeated failure here means auth is actually dead and worth alerting on.
  local out="" attempt
  for attempt in 1 2 3; do
    out=$(timeout 25 zsh -lc 'claude -p --output-format text "reply with the single word OK"' 2>&1 || true)
    case "$out" in
      *OK*) date +%s > "$stamp"; echo "ok" > "$cache"; return 0 ;;
    esac
    (( attempt < 3 )) && sleep 5
  done
  date +%s > "$stamp"; echo "fail" > "$cache"
  log "STUCK: host claude OAuth genuinely dead — keychain token expired (${left:-no-token}s) AND 3 live pings failed. last: ${out:0:160}"
  return 1
}

# ── Per-job pre-flight ──────────────────────────────────────────────────
# Architectural fix: refuse to boot a VM for a job that nothing in our
# system can advance. The wrangler is the brain; the VM is the body.
#
# Failure modes this catches (each one would otherwise loop indefinitely):
#   - leftclaw sanitize stuck at pending      → defer, retry later
#   - sanitize hard-fail (safe=false)         → decline from host
#   - feature classifier returns blocked      → decline from host
#   - feature classifier returns ambiguous    → post one chat msg, defer
#
# State lives in $STATE_DIR/job.<id>.* — survives wrangler restarts.

# Defer further attempts on this job for N seconds. Idempotent — overwrites.
defer_job() {
  local jid="$1" seconds="$2"
  local until=$(( $(date +%s) + seconds ))
  echo "$until" > "$STATE_DIR/job.$jid.defer-until"
}
# True when a defer window is still in the future.
job_is_deferred() {
  local jid="$1"
  local f="$STATE_DIR/job.$jid.defer-until"
  [[ -f "$f" ]] || return 1
  local until
  until=$(cat "$f" 2>/dev/null || echo 0)
  (( $(date +%s) < until ))
}
# Remember we already asked the client to clarify ambiguous targets so
# we don't spam-post on every tick.
mark_clarification_posted() { touch "$STATE_DIR/job.$1.clarif-sent"; }
clarification_already_posted() { [[ -f "$STATE_DIR/job.$1.clarif-sent" ]]; }

# List open job IDs (status=0) for a service type, one per line.
list_open_job_ids() {
  local svc="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/list-jobs.sh "$svc" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  if isinstance(d, list):
    for j in d:
      jid = j.get("id")
      if jid is not None:
        print(jid)
except Exception:
  pass' 2>/dev/null
}

# Decline a job on-chain from the host (no VM boot).
host_decline() {
  local jid="$1" env="$2" reason="${3:-pre-flight refused}"
  log "  job $jid: host-declining ($reason)"
  if ! ( set -a; source "$env" 2>/dev/null; set +a
         ./scripts/leftclaw/decline.sh "$jid" >>"$LOG" 2>&1 ); then
    log "  job $jid: host-decline FAILED — will retry next tick"
    return 1
  fi
  notify "🔻 declined job ${jid}: ${reason}"
}

# Post a chat message on a job from host. Returns curl's exit code.
host_post_message() {
  local jid="$1" env="$2" msg="$3"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/post-message.sh "$jid" "$msg" >>"$LOG" 2>&1 )
}

# Pre-flight a single open job. Side effects: may decline, post message,
# set defer. Returns 0 if a fresh agent could advance this job now.
job_advanceable() {
  local jid="$1" svc="$2" env="$3"

  job_is_deferred "$jid" && return 1

  # Sanitize gate (server-side leftclaw check; pending means not yet processed).
  local resp safe pending
  resp=$( ( set -a; source "$env" 2>/dev/null; set +a
           ./scripts/leftclaw/sanitize-check.sh "$jid" 2>/dev/null
         ) || true )
  safe=$(   printf '%s' "$resp" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("safe"))
except: print("")' 2>/dev/null)
  pending=$(printf '%s' "$resp" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("pending"))
except: print("")' 2>/dev/null)

  if [[ "$safe" == "True" ]]; then
    : # passed; fall through to classifier (if applicable)
  elif [[ "$pending" == "True" ]]; then
    log "  job $jid: sanitize still pending — deferring 5min (no boot)"
    defer_job "$jid" 300
    return 1
  else
    if host_decline "$jid" "$env" "sanitize refused"; then
      defer_job "$jid" 86400
    fi
    return 1
  fi

  # Feature-only: classifier gate.
  if [[ "$svc" == "10" ]]; then
    local target_out mode reason
    target_out=$(./scripts/feature/resolve-target.sh "$jid" 2>/dev/null || true)
    mode=$(printf '%s\n' "$target_out" | awk '/^MODE: /{print $2; exit}')
    case "$mode" in
      leftclaw|external)
        : # advanceable
        ;;
      blocked)
        reason=$(printf '%s\n' "$target_out" | sed -n 's/^REASON: //p' | head -1)
        if host_decline "$jid" "$env" "blocked: ${reason:-classifier blocked}"; then
          defer_job "$jid" 86400
        fi
        return 1
        ;;
      ambiguous)
        if clarification_already_posted "$jid"; then
          log "  job $jid: still ambiguous after our earlier message — deferring 1h"
          defer_job "$jid" 3600
        else
          if host_post_message "$jid" "$env" \
               "Hello — to proceed with this Feature job, please share the GitHub URL of the repo to modify (e.g. https://github.com/owner/repo), or reference a prior leftclaw job by ID (e.g. 'job #99'). We'll pick it back up automatically once you reply."; then
            mark_clarification_posted "$jid"
            notify "❓ asked job ${jid} client for repo URL (ambiguous)"
            defer_job "$jid" 1800
          else
            log "  job $jid: post-message FAILED — deferring 10min to retry"
            defer_job "$jid" 600
          fi
        fi
        return 1
        ;;
      *)
        log "  job $jid: unknown classifier MODE='${mode}' — deferring 5min"
        defer_job "$jid" 300
        return 1
        ;;
    esac
  fi

  return 0
}

# Count how many open jobs of this type a fresh agent could actually
# advance. Side effects identical to job_advanceable.
count_advanceable_open() {
  local svc="$1" env="$2"
  local n=0 jid
  while IFS= read -r jid; do
    [[ -z "$jid" ]] && continue
    if job_advanceable "$jid" "$svc" "$env"; then
      n=$(( n + 1 ))
    fi
  done < <(list_open_job_ids "$svc" "$env")
  echo "$n"
}

# Cap for a given VM name — special-cased for builder, default otherwise.
cap_for() {
  case "$1" in
    builder) echo "$TIME_CAP_BUILDER_SECONDS" ;;
    feature) echo "$TIME_CAP_FEATURE_SECONDS" ;;
    auditor) echo "$TIME_CAP_AUDITOR_SECONDS" ;;
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

# NOTE: these must consume tart's FULL output (awk, not grep -q). Under
# `set -o pipefail`, grep -q's early exit SIGPIPEs tart and the pipeline
# goes false even on a match — measured ~73% false-negative rate, which
# made the wrangler believe running VMs were stopped.
vm_running() {
  local vm="$1"
  tart list 2>/dev/null \
    | awk -v vm="$vm" '$1=="local" && $2==vm && $NF=="running"{f=1} END{exit !f}'
}

# Does a per-agent gold image exist? Fast path uses it.
gold_exists() {
  tart list --quiet --source local 2>/dev/null \
    | awk -v n="$1" '$0==n{f=1} END{exit !f}'
}

# Does a VM exist (any state)?
vm_exists() {
  tart list --quiet --source local 2>/dev/null | grep -Fxq "$1"
}

# Is claude actually running inside the VM? Used to detect the
# "VM up but agent process exited" case — happens when the agent
# follows the ambiguous-target → post-clarification → exit pattern
# in feature.prompt.md, expecting the wrangler to cycle the VM as
# its "next polling cycle." Without this check, the dead-agent VM
# holds the slot indefinitely, blocking other agents.
# 8s timeout so a hung ssh can't block the poll loop.
agent_alive() {
  local vm="$1"
  timeout 8 ./cont ssh "$vm" 'pgrep -f "[c]laude" >/dev/null 2>&1' 2>/dev/null
}

start_vm() {
  local vm="$1" prov="$2" svc="${3:-?}" env="${4:-}" mine="${5:-0}"
  local jid="" meta=""
  if [[ -n "$env" && -f "$env" ]]; then
    # When re-booting for an already-assigned/in-progress job (mine > 0),
    # the assigned job is what the agent will actually work — name that,
    # not the first OPEN job (which made every reboot notify "job 300"
    # while the VM was really re-working the assigned job).
    if [[ "$mine" =~ ^[1-9] ]]; then
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
    # Fresh boot toward the open queue: don't name a specific job — the
    # agent picks its own on accept, and naming one here reads as "job N
    # started" even when nothing was accepted (looked like duplicate
    # starts to the client watching a job).
    desc="(open type-${svc} queue)"
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
      if ! AGENT_ENV_FILE="$env" ./cont provision "$vm" "./$prov" >>"$LOG" 2>&1; then
        log "  cont provision failed — cleaning up zombie VM"
        ./cont down "$vm" >>"$LOG" 2>&1 || true
        ./cont rm "$vm"   >>"$LOG" 2>&1 || true
        notify "🔴 ${vm} failed to start ${desc}"
        return 1
      fi
    elif ! AGENT_ENV_FILE="$env" ./cont sync "$vm" "./$prov" >>"$LOG" 2>&1; then
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
    if ! AGENT_ENV_FILE="$env" ./cont provision "$vm" "./$prov" >>"$LOG" 2>&1; then
      log "  cont provision failed — cleaning up zombie VM"
      ./cont down "$vm" >>"$LOG" 2>&1 || true
      ./cont rm "$vm"   >>"$LOG" 2>&1 || true
      notify "🔴 ${vm} failed to start ${desc}"
      return 1
    fi
  fi

  log "  bouncing $vm so fresh Aqua login fires the LaunchAgent"
  # Graceful in-guest halt BEFORE tart stop: a hard stop can roll back the
  # freshly-synced Tier-3 writes (env/scripts/prompt), reverting the VM to
  # the gold image's baked state — it then runs as whatever identity/agent
  # was baked at gold-bake time (2026-07-07: VMs silently became the old
  # May bot and worked jobs as the stale baked wallet).
  local _vm_ip
  _vm_ip=$(./cont ip "$vm" 2>/dev/null || true)
  if [[ -n "$_vm_ip" ]]; then
    sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=8 "admin@${_vm_ip}" \
      'sync; sync; echo admin | sudo -S shutdown -h now' >/dev/null 2>&1 || true
    sleep 10
  fi
  ./cont down "$vm" >>"$LOG" 2>&1 || true
  sleep 3
  if ! ./cont up "$vm" >>"$LOG" 2>&1; then
    log "  cont up failed (tart 2-VM cap?) — see $LOG"
    notify "🔴 ${vm} failed to start ${desc}"
    return 1
  fi
  # Post-bounce verification (auditor instances): the provisioned agent env
  # must have survived the bounce. If it rolled back, this VM is running the
  # gold image's baked identity, not the agent we provisioned — recycle loudly.
  if [[ "$vm" == auditor* ]]; then
    local _verify_ip _tries _envstate=""
    for _tries in 1 2 3 4 5 6; do
      sleep 15
      _verify_ip=$(./cont ip "$vm" 2>/dev/null || true)
      [[ -z "$_verify_ip" ]] && continue
      _envstate=$(sshpass -p admin ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
        "admin@${_verify_ip}" 'test -s ~/.env.auditor && echo PRESENT || echo MISSING' 2>/dev/null || true)
      [[ -n "$_envstate" ]] && break
    done
    if [[ "$_envstate" == "MISSING" ]]; then
      log "  WARNING: $vm rolled back in bounce — agent env missing; recycling"
      notify "🔴 ${vm} rolled back during bounce (env missing) — recycling"
      ./cont down "$vm" >>"$LOG" 2>&1 || true
      return 1
    elif [[ "$_envstate" == "PRESENT" ]]; then
      log "  post-bounce verify: agent env present in $vm"
    else
      log "  post-bounce verify: $vm unreachable over ssh — proceeding, watch for ghost agent"
    fi
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
  # Only notify on red for actual errors, not normal idle stops
  case "$reason" in
    *EXCEEDED* | *fail* | *FAIL* | *error* | *ERROR*)
      notify "🔴 ${vm} stopped — ${reason}" ;;
  esac
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

  # Health gate: if the host can't authenticate to Anthropic, no VM we
  # boot can either. Skip the whole tick rather than waste boots.
  if ! host_oauth_ok; then
    log "STUCK: host claude OAuth is dead — fleet paused this tick. Fix with 'claude /login' on the host."
    notify "🔴 host claude OAuth is dead — fleet paused; run 'claude /login' on host"
    sleep "$INTERVAL"
    continue
  fi

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
    # Manual pause: `touch $STATE_DIR/paused.<vm>` to take an agent
    # out of rotation without restarting the wrangler.
    if [[ -f "$STATE_DIR/paused.$vm" ]]; then
      log "$vm: paused (rm $STATE_DIR/paused.$vm to resume)"
      continue
    fi

    # `open` reflects host-side pre-flight: only jobs a fresh agent could
    # actually advance (sanitize=safe, classifier passes for feature). Jobs
    # that fail pre-flight are declined / asked-about / deferred from the
    # host instead of spinning up a VM that would loop on them.
    open=$(count_advanceable_open "$svc" "$env")
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
      elif [[ "$mine" == "0" && "$open" =~ ^[1-9] ]]; then
        # Open work exists but the agent hasn't accepted. Three cases:
        #  (a) fresh boot, agent is still reading prompt/scripts — fine
        #  (b) agent process exited (e.g. ambiguous-target escalation
        #      pattern in feature.prompt.md) — VM holds slot for nothing
        #  (c) claude is alive but idle (posted a message, now waiting
        #      on client; or hung) — VM also holds slot for nothing
        # Tolerate the boot window (NO_ACCEPT_GRACE_SECONDS, default
        # 5 min). After that, recycle the VM regardless of whether
        # claude is running — a clean restart re-pulls the job and
        # either accepts or declines per the agent's own protocol.
        : "${NO_ACCEPT_GRACE_SECONDS:=300}"
        if (( elapsed < NO_ACCEPT_GRACE_SECONDS )) && agent_alive "$vm"; then
          log "$vm up, mine=0 open=$open — agent alive, leaving alone (elapsed ${elapsed}s/${cap}s)"
        elif (( elapsed < NO_ACCEPT_GRACE_SECONDS )); then
          log "$vm up, mine=0 open=$open — claude process gone in boot window, recycling"
          stop_vm "$vm" "agent exited during boot (no claude process; open=$open)"
        else
          log "$vm up, mine=0 open=$open — no accept after ${elapsed}s (grace ${NO_ACCEPT_GRACE_SECONDS}s), recycling"
          stop_vm "$vm" "stuck — no job accept within grace window (open=$open, elapsed=${elapsed}s)"
        fi
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
