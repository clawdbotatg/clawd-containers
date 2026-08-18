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

# macOS ships no `timeout` (it's GNU coreutils). host_oauth_ok and
# agent_alive depend on it; without this shim every `timeout ...` call
# is "command not found" (exit 127), which reads as check-failed and
# pauses the fleet on a phantom dead-OAuth. Python is already a hard
# dependency of this script.
if ! command -v timeout >/dev/null 2>&1; then
  timeout() {
    python3 - "$@" <<'PY'
import subprocess, sys
try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
  }
fi

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
WRANGLER_ARGV=("$@")            # kept for self_update's re-exec
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
TIME_CAP_AUDITOR_SECONDS="${TIME_CAP_AUDITOR_SECONDS:-14400}"  # 4h — 2h parked in-budget scoped jobs (508/509); VM work restarts from zero on every cap kill, so a too-tight cap loops forever

# Stall detection. A VM holding an assigned job used to be left alone for the
# FULL time cap — agent_alive is only consulted on the mine=0 path, so a hung
# or dead agent burned 4h before anything noticed (job 570, 2026-08-05: 4h
# elapsed, zero logWork calls, then a cap strike). On-chain stage notes are the
# progress signal, and they survive a VM wipe.
#
# Two tiers, because the first stage legitimately takes a long time: the agent
# boots, reads its prompt and skills, clones, and runs an entire breadth pass
# before the first logWork lands. Measured on job 570: first stage at 41 min.
# FIRST_STAGE_GRACE must clear that comfortably or we recycle healthy work.
STALL_FIRST_STAGE_SECONDS="${STALL_FIRST_STAGE_SECONDS:-5400}"  # 90 min to post ANY stage
STALL_SECONDS="${STALL_SECONDS:-2700}"                          # 45 min between stages after that
# Bound the recycles so an un-auditable job can't loop; after this many we stop
# intervening and let the existing time-cap / strike / park path take over.
STALL_MAX_RECYCLES="${STALL_MAX_RECYCLES:-2}"

# Per-VM start-time markers. Used to compute elapsed for the cap.
STATE_DIR="${TMPDIR:-/tmp}/agent-wrangler"
mkdir -p "$STATE_DIR"

# Max consecutive start_vm() failures before we back off and stop retrying
# until the VM's queue empties (or it eventually starts).
MAX_START_RETRIES="${MAX_START_RETRIES:-3}"

# How long a start-failure back-off holds before we retry anyway. Transient
# causes (Claude session-limit window, RPC blips) heal on their own, but the
# queue-empties condition can never fire while a job stays assigned to our
# wallet — that deadlock kept the auditor dark for 27h on 2026-07-09/10.
BACKOFF_RESET_SECONDS="${BACKOFF_RESET_SECONDS:-1800}"

# Maximum concurrent tart VMs the host can run. Apple Silicon's
# Virtualization framework documents a cap of 2 for arm64 macOS guests,
# but on some hosts the effective cap is 1 (other virtualization tools
# running, hardware/OS variation). Default to 1 — override with
# MAX_VMS=2 if your host confirms it can run two.
MAX_VMS="${MAX_VMS:-1}"

# Runtime override for MAX_VMS, re-read at every slot check so a human can
# turn parallelism down (or back up) on a live wrangler without a restart —
# a restart kills the running VMs. Write a bare number into the file
# (e.g. `echo 1 > ~/.config/cont/max-vms`); remove it to fall back to the
# MAX_VMS env. Lives in ~/.config/cont so it survives reboots, and is
# per-box on purpose: a push deploys code to every wrangler box, but each
# host's VM budget is its own.
MAX_VMS_FILE="${MAX_VMS_FILE:-$HOME/.config/cont/max-vms}"
effective_max_vms() {
  local v
  v=$(cat "$MAX_VMS_FILE" 2>/dev/null | tr -cd '0-9')
  if [[ -n "$v" ]]; then echo "$v"; else echo "$MAX_VMS"; fi
}

# Per-VM consecutive start_vm() failure counter. Reset on a successful
# start or when the queue becomes empty. Stored as "<vm> <count>" lines
# in a flat file (bash 3.2 on macOS lacks associative arrays).
FAILURES_FILE="$STATE_DIR/failures.txt"

# Per-JOB time-cap strike counter ("<job_id> <count>" lines). Every cap
# hit while a job is assigned counts a strike; a job gets one free
# resume, and at MAX_CAP_STRIKES the wrangler stops rebooting for it.
# We'd prefer to decline the job back to the pool, but the contract's
# declineJob requires status OPEN (reverts "!open" once accepted) — an
# accepted job only leaves IN_PROGRESS via completeJob (worker) or
# cancelJob (client/owner). So: try decline (works iff never accepted),
# else park the job and alert a human. Clear a park manually with
#   sed -i '' '/^<job_id> /d' "$CAP_STRIKES_FILE"
MAX_CAP_STRIKES="${MAX_CAP_STRIKES:-2}"
CAP_STRIKES_FILE="$STATE_DIR/cap_strikes.txt"

# Telegram dedup buffer: hash -> last-sent-timestamp. Prevents duplicate
# notifications when multiple wranglers run or retries happen rapidly.
# Stored as "<hash> <timestamp>" lines in a flat file.
NOTIFY_DEDUP_FILE="$STATE_DIR/notify_dedup.txt"
STALL_RECYCLES_FILE="$STATE_DIR/stall_recycles.txt"

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

# Signature of a job's on-chain progress (its logWork stage notes). Changes
# whenever the agent records a new stage; empty when none posted yet. Reads the
# chain rather than ssh-ing the guest: it survives a recycle, needs no network
# path into the VM, and is the same evidence a human would check.
get_job_progress_sig() {
  local jid="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/get-job.sh "$jid" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.loads(sys.stdin.read(), strict=False)
  print("|".join(d.get("_other_strings") or []))
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

# The Claude login the fleet ships is selected via `cont account` — every
# host-side health/usage check below must follow the same selection, or the
# gates watch one account while the VMs burn another.
fleet_claude_dir() { ./cont account dir 2>/dev/null || true; }
fleet_claude_blob() { ./cont account blob 2>/dev/null || true; }

# Seconds until the selected account's Claude token expires. Prints an
# integer (may be negative if expired); nothing if missing/unreadable.
host_oauth_seconds_left() {
  fleet_claude_blob | python3 -c '
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
  local out="" attempt cdir
  cdir="$(fleet_claude_dir)"
  for attempt in 1 2 3; do
    # Set/unset INSIDE the login shell: .zprofile exports CLAUDE_CONFIG_DIR
    # (harness account), which would override anything we export out here —
    # pinging the wrong account gives a false "ok" while the fleet's actual
    # token is dead (2026-07-09, 28h outage). The ping must run under the
    # SELECTED account's config dir (unset = default ~/.claude).
    if [[ -n "$cdir" ]]; then
      out=$(timeout 25 zsh -lc "export CLAUDE_CONFIG_DIR=$(printf '%q' "$cdir"); claude -p --output-format text 'reply with the single word OK'" 2>&1 || true)
    else
      out=$(timeout 25 zsh -lc 'unset CLAUDE_CONFIG_DIR; claude -p --output-format text "reply with the single word OK"' 2>&1 || true)
    fi
    case "$out" in
      *OK*) date +%s > "$stamp"; echo "ok" > "$cache"; return 0 ;;
    esac
    (( attempt < 3 )) && sleep 5
  done
  date +%s > "$stamp"; echo "fail" > "$cache"
  log "STUCK: host claude OAuth genuinely dead — keychain token expired (${left:-no-token}s) AND 3 live pings failed. last: ${out:0:160}"
  return 1
}

# ── OBS gate ────────────────────────────────────────────────────────────
# Recording/streaming happens from this host, and a VM boot mid-recording
# steals enough CPU to drop frames. Hold the fleet while OBS has an ACTIVE
# OUTPUT — a write-handle on a media file (recording) or an established
# RTMP session (streaming). OBS merely being OPEN does not pause the fleet:
# the 2026-07-08 process-exists gate (a live edit, never committed) left
# the fleet dark for 2 days because OBS never quits on this machine.
#
# NOTE: awk consumes full lsof output (not grep -q) — under pipefail a
# grep -q early exit SIGPIPEs lsof and a true match reads as false, same
# bug as the tart list checks (d4d2baf).
obs_active_output() {
  local pid
  pid=$(pgrep -x OBS 2>/dev/null | head -1)
  [[ -n "$pid" ]] || return 1
  # Recording: write-mode ('w' or 'u') handle on a media container.
  if lsof -p "$pid" 2>/dev/null \
       | awk '$4 ~ /[0-9][wu]/ && $NF ~ /\.(mkv|mp4|mov|flv|ts)$/ {f=1} END{exit !f}'; then
    return 0
  fi
  # Streaming: established RTMP(S) connection.
  if lsof -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null \
       | awk 'tolower($0) ~ /rtmp|:1935/ {f=1} END{exit !f}'; then
    return 0
  fi
  return 1
}

# ── Usage-limit gate ────────────────────────────────────────────────────
# host_oauth_ok proves the token is VALID; it says nothing about whether
# the subscription window has headroom. With an exhausted 5h/7d window the
# token still passes, every VM we boot stalls at "usage limit reached",
# hits the no-accept grace, and recycles — a clone/bounce churn loop for
# hours. This gate asks Claude's OAuth usage endpoint (undocumented —
# degrade to "ok" on any error, never pause the fleet on a probe failure)
# and pauses all boots until the window resets. Jobs stay queued on-chain;
# nothing is declined or struck while paused.
HOST_USAGE_CACHE_SECONDS="${HOST_USAGE_CACHE_SECONDS:-300}"

# Prints "ok" or "exhausted <resets_at>". Cached HOST_USAGE_CACHE_SECONDS.
host_usage_state() {
  local cache="$STATE_DIR/host_usage.state" stamp="$STATE_DIR/host_usage.checked-at"
  local now checked
  now=$(date +%s)
  if [[ -f "$stamp" && -f "$cache" ]]; then
    checked=$(cat "$stamp" 2>/dev/null || echo 0)
    if (( now - checked < HOST_USAGE_CACHE_SECONDS )); then
      cat "$cache"; return 0
    fi
  fi
  local out
  out=$(fleet_claude_blob | python3 -c '
import json, sys, urllib.request
try:
    tok = json.load(sys.stdin)["claudeAiOauth"]["accessToken"]
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": "Bearer " + tok,
                 "anthropic-beta": "oauth-2025-04-20",
                 "Content-Type": "application/json"})
    u = json.load(urllib.request.urlopen(req, timeout=10))
    exhausted = []
    for k in ("five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"):
        w = u.get(k)
        if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)) \
           and w["utilization"] >= 100:
            exhausted.append(w.get("resets_at") or "")
    if exhausted:
        resets = sorted(x for x in exhausted if x)
        print(("exhausted " + resets[0]) if resets else "exhausted")
    else:
        print("ok")
except Exception:
    print("ok")
' 2>/dev/null) || true
  [[ -z "$out" ]] && out="ok"
  date +%s > "$stamp"
  printf '%s\n' "$out" > "$cache"
  printf '%s\n' "$out"
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

# ── Problem-job strikes ─────────────────────────────────────────────────
# "If a job causes problems, decline it and move on." A job that keeps
# burning boot cycles (VM boots, agent never accepts) accumulates
# strikes; at MAX_JOB_STRIKES it is declined from the host and
# deferred 24h so the rest of the queue gets worked. Strikes are only
# awarded while inference is healthy — the OAuth and usage gates run
# before any strike logic, so an exhausted subscription can never get
# good jobs declined.
STRIKES_FILE="$STATE_DIR/job-strikes.txt"
MAX_JOB_STRIKES="${MAX_JOB_STRIKES:-3}"

strike_job() {
  local jid="$1" env="$2" weight="$3" why="$4"
  [[ -n "$jid" ]] || return 0
  local n
  n=$(( $(kv_get "j$jid" "$STRIKES_FILE") + weight ))
  kv_set "j$jid" "$n" "$STRIKES_FILE"
  log "  job $jid: strike ${n}/${MAX_JOB_STRIKES} — $why"
  (( n >= MAX_JOB_STRIKES )) || return 0
  if host_decline "$jid" "$env" "problem job (${why}; ${n} strikes) — moving on"; then
    defer_job "$jid" 86400
    kv_set "j$jid" 0 "$STRIKES_FILE"
  else
    # decline.sh can fail — e.g. the tx reverts on an already-accepted
    # job. Flag for a human and leave the count one below the threshold
    # so the next strike retries the decline instead of hammering the
    # chain every tick.
    notify "⚠️ job ${jid} keeps failing (${why}) but decline didn't land — may need manual attention"
    kv_set "j$jid" $(( MAX_JOB_STRIKES - 1 )) "$STRIKES_FILE"
  fi
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

  # Audit-only: scope gate, measured in Solidity LoC (not contract count —
  # 10 tiny contracts are fine, one 24KB monolith is not). A whole-protocol
  # submission (job 443: 10 contracts, ~6.8K LoC) can never finish well in
  # one pass — and the contract only refunds via worker declineJob while
  # the job is still OPEN (acceptJob moves the escrow to treasury
  # irreversibly). So catch it here, before anything boots or accepts:
  # tell the client how to resubmit, then decline — the decline itself
  # returns their escrow. Fail-open: an empty/errored verdict never
  # blocks a job.
  if [[ "$svc" == "4" ]]; then
    local cx verdict ireason creason
    cx=$( ( set -a; source "$env" 2>/dev/null; set +a
            ./scripts/audit/complexity-check.sh "$jid" 2>/dev/null
          ) || true )
    verdict=$(printf '%s\n' "$cx" | awk '/^VERDICT: /{print $2; exit}')
    ireason=$(printf '%s\n' "$cx" | sed -n 's/^REASON: //p' | head -1)
    creason=$(printf '%s\n' "$cx" | sed -n 's/^CLIENT_REASON: //p' | head -1)
    if [[ "$verdict" == "too_complex" ]]; then
      log "  job $jid: too complex (${ireason:-over LoC budget}) — refunding via decline"
      # Message first, decline second: after the decline lands the client
      # has their refund and this explains what happened + what to do.
      host_post_message "$jid" "$env" \
        "Thanks for the submission — but this job's scope is bigger than our audit pipeline handles well in one pass: ${creason:-it exceeds our per-job code budget}. We're declining it, which automatically refunds your escrow. Please resubmit in smaller chunks that fit the budget — usually one or two contracts per job (splitting a protocol by module works great: e.g. the vault/escrow contracts first, then the registries). Smaller scopes get much deeper reports, and each job completes instead of stalling. We'll pick the new jobs up automatically." || true
      if host_decline "$jid" "$env" "too complex: ${ireason:-over LoC budget} — refunded; asked client to resubmit in smaller chunks"; then
        defer_job "$jid" 86400
      else
        # decline can fail transiently (RPC) or because someone accepted
        # in the race window. Short defer, then re-evaluate.
        defer_job "$jid" 3600
      fi
      return 1
    fi
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
    auditor*) echo "$TIME_CAP_AUDITOR_SECONDS" ;;
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

# First job assigned to this wallet (OPEN/IN_PROGRESS), or empty.
get_assigned_job_id() {
  local svc="$1" env="$2"
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
}

# Comma-separated list of all OPEN job ids for a service type, or empty.
get_open_job_ids() {
  local svc="$1" env="$2"
  ( set -a; source "$env" 2>/dev/null; set +a
    ./scripts/leftclaw/list-jobs.sh "$svc" 2>/dev/null
  ) | python3 -c 'import json,sys
try:
  d = json.load(sys.stdin)
  if isinstance(d, list) and d:
    print(", ".join(str(j.get("id")) for j in d if j.get("id") is not None))
except Exception:
  pass' 2>/dev/null
}

# Detect and announce job completions. Remembers the job a VM was working
# ($STATE_DIR/<vm>.current-job); when that job leaves the wallet queue,
# checks its on-chain status and notifies on COMPLETED(2).
track_job_completion() {
  local vm="$1" svc="$2" env="$3" mine="$4"
  local f="$STATE_DIR/$vm.current-job"
  local prev="" cur=""
  [[ -f "$f" ]] && prev=$(cat "$f" 2>/dev/null)
  if [[ "$mine" =~ ^[1-9] ]]; then
    cur=$(get_assigned_job_id "$svc" "$env")
  fi
  if [[ -n "$prev" && "$prev" != "$cur" ]]; then
    local st
    st=$( ( set -a; source "$env" 2>/dev/null; set +a
            ./scripts/leftclaw/get-job.sh "$prev" 2>/dev/null
          ) | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("status",""))
except Exception: pass' 2>/dev/null )
    if [[ "$st" == "2" ]]; then
      log "$vm: job $prev completed"
      notify "✅ ${vm} completed job ${prev}"
    fi
  fi
  if [[ -n "$cur" ]]; then echo "$cur" > "$f"; else rm -f "$f"; fi
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
      jid=$(get_assigned_job_id "$svc" "$env")
    fi
    [[ -n "$jid" ]] && meta=$(get_job_meta "$jid" "$env" || true)
  fi
  local desc
  if [[ -n "$jid" && -n "$meta" ]]; then
    desc="resuming assigned job ${jid}: ${meta}"
  else
    # Fresh boot toward the open queue: list the open job ids rather than
    # claiming a specific one — the agent picks its own on accept, and
    # naming one here reads as "job N started" even when nothing was
    # accepted (looked like duplicate starts to the client watching a job).
    local open_ids
    open_ids=$( [[ -n "$env" && -f "$env" ]] && get_open_job_ids "$svc" "$env" || true )
    if [[ -n "$open_ids" ]]; then
      desc="for open type-${svc} jobs: ${open_ids}"
    else
      desc="(open type-${svc} queue)"
    fi
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
  # Re-stage the CURRENT login into the bounced guest + record custody
  # (2026-08-07): `cont up` boots whatever login the last provision left
  # on the disk — stale tokens the guest replays (doomed refresh, wiped
  # blob, unauthenticated job) — and without a custody record every
  # host-side refresher contends for whatever login it does hold.
  if ./cont stage "$vm" >>"$LOG" 2>&1; then
    log "  staged current login into $vm (custody recorded)"
  else
    log "  WARNING: cont stage failed for $vm — guest may ride stale creds"
  fi
  mark_started "$vm"
  # Custody hop: $vm now rides the selected login and will rotate its
  # refresh token in-guest on any job that outlives the ~1h access token.
  # Move the host's selection to a different login so no host-side
  # refresh contends with the in-guest copy (cont account auto skips
  # in-custody logins; cont down harvests the rotated blob back). If no
  # other login has headroom the selection stays shared — logged, and
  # the harvest still recovers the likely rotation.
  local _hop
  if _hop=$(./cont account auto 2>>"$LOG") && [[ -n "$_hop" ]]; then
    log "  custody hop: fleet account -> '$_hop' ($vm keeps the previous login)"
    rm -f "$STATE_DIR/host_oauth.status" "$STATE_DIR/host_oauth.checked-at" \
          "$STATE_DIR/host_usage.state" "$STATE_DIR/host_usage.checked-at"
  else
    log "  custody hop unavailable — selection stays on the login inside $vm (shared custody, refresh contention possible)"
  fi
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

# ── Self-update ─────────────────────────────────────────────────────────
# This repo had NO auto-pull, unlike clawd-harness. So a fix landed on the
# box it was written on and every other box kept running the old code for
# as long as nobody remembered to ssh in. That is not hypothetical: a
# scope-gate bug counted a single linked .sol file as its entire repo and
# auto-declined + REFUNDED five good audit jobs from one client (633, 634,
# 635, 641, 643). Fixing it on one machine left two others still refunding,
# and one of those had no working ssh route at all.
#
# Same guards the harness uses (docs/fleet/DEPLOY.md): on main, clean
# worktree, fast-forward only. A dirty tree means someone is live-editing —
# skip it, never clobber. A diverged branch (local commits never pushed —
# clawd-sat had five) fails the ff-only pull and is left alone for a human.
SELF_UPDATE="${SELF_UPDATE:-1}"
SELF_UPDATE_EVERY="${SELF_UPDATE_EVERY:-300}"

self_update() {
  [[ "$SELF_UPDATE" == "1" ]] || return 0
  local stamp="$STATE_DIR/self-update.at" now last
  now=$(date +%s); last=$(cat "$stamp" 2>/dev/null || echo 0)
  (( now - last < SELF_UPDATE_EVERY )) && return 0
  echo "$now" > "$stamp"

  local branch; branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || return 0
  if [[ "$branch" != "main" ]]; then
    log "self-update: on '$branch', not main — skipping"; return 0
  fi
  # TRACKED changes only. Untracked files are normal debris on these boxes —
  # agents leave plan/scratch .md files lying around — and counting them as
  # "someone is live-editing" wedges the box permanently: clawd-head sat out
  # every update for a whole morning over two stray notes, which is the exact
  # silent-staleness this function exists to prevent. An untracked file that
  # would genuinely be clobbered is still safe, because `pull --ff-only`
  # refuses that case itself ("untracked working tree files would be
  # overwritten") and changes nothing — we just log it and try again next tick.
  if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    log "self-update: tracked files modified — skipping (someone is live-editing)"; return 0
  fi

  local before after
  before="$(git rev-parse HEAD 2>/dev/null)" || return 0
  # Never let git block on a credential dialog on an unattended box.
  if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo \
       git -c credential.helper='!gh auth git-credential' \
           pull --ff-only -q origin main >>"$LOG" 2>&1; then
    log "self-update: ff-only pull failed (diverged or offline) — staying on ${before:0:8}"
    return 0
  fi
  after="$(git rev-parse HEAD 2>/dev/null)"
  [[ "$before" == "$after" ]] && return 0

  log "self-update: ${before:0:8} -> ${after:0:8} ($(git log --oneline -1 | cut -c1-70))"
  notify "⬆️ wrangler self-updated: $(git log --oneline -1 | cut -c1-60)"
  # Cached scope verdicts were produced by the OLD gate — drop them, or a
  # stale too_complex keeps refunding jobs the new gate would accept.
  rm -f "$HOME/.cache/leftclaw-complexity"/*.out 2>/dev/null || true
  # Helper scripts are re-read every tick, so they are already live. This
  # file is not — re-exec so the new loop takes over. Running VMs are
  # separate tart processes and survive; all state lives in $STATE_DIR.
  if ! git diff --quiet "$before" "$after" -- agent-wrangler.sh; then
    log "self-update: agent-wrangler.sh itself changed — re-exec"
    # bash 3.2 (what launchd's bare PATH finds at /bin/bash) treats an
    # empty array expansion as an unbound variable under `set -u`, so a
    # wrangler started with no args would die here instead of re-exec'ing.
    exec "$0" ${WRANGLER_ARGV[@]+"${WRANGLER_ARGV[@]}"}
  fi
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
  self_update
  refresh_skills

  # Health gate: if the host can't authenticate to Anthropic, no VM we
  # boot can either. But "the host" means the SELECTED login — its refresh
  # token dying (revoked, rotated elsewhere) says nothing about the other
  # roster logins, so FIRST hop to one with headroom (`cont account auto`
  # skips any login whose credential can't produce a live token), exactly
  # like the usage gate below. Only when every login is dead do we pause.
  # (2026-08-04: fleet sat STUCK on one dead login for hours while five
  # healthy logins idled at 54-100% headroom.)
  if ! host_oauth_ok; then
    if hopped=$(./cont account auto 2>>"$LOG") && [[ -n "$hopped" ]]; then
      rm -f "$STATE_DIR/host_oauth.status" "$STATE_DIR/host_oauth.checked-at" \
            "$STATE_DIR/host_usage.state" "$STATE_DIR/host_usage.checked-at"
      log "host claude OAuth dead on selected login — auto-hopped fleet account to '$hopped'"
      notify "🔄 Claude login dead — fleet hopped to account '$hopped'; jobs continue"
    fi
    if ! host_oauth_ok; then
      log "STUCK: host claude OAuth is dead on every roster login — fleet paused this tick. Fix with 'claude /login' on the host."
      notify "🔴 host claude OAuth dead (no roster login usable) — fleet paused; run 'claude /login' on host"
      sleep "$INTERVAL"
      continue
    fi
  fi

  # OBS gate: no boots or stops while a recording/stream is live. Jobs
  # stay queued and the fleet resumes automatically when the output ends.
  if obs_active_output; then
    log "OBS is actively recording/streaming — fleet paused this tick (jobs stay queued)"
    sleep "$INTERVAL"
    continue
  fi

  # Usage gate: valid token but exhausted window → every boot would stall
  # at the no-accept cliff. FIRST try hopping to another host login with
  # headroom (`cont account auto` — new boots ship the new credential;
  # running VMs finish on the old one). Only if no login has headroom do
  # we wait it out; notify only on state transitions.
  usage=$(host_usage_state)
  if [[ "$usage" == exhausted* ]]; then
    if hopped=$(./cont account auto 2>>"$LOG") && [[ -n "$hopped" ]]; then
      log "usage window exhausted — auto-hopped fleet account to '$hopped'"
      notify "🔄 Claude usage limit hit — fleet hopped to account '$hopped'; jobs continue"
      rm -f "$STATE_DIR/host_usage.state" "$STATE_DIR/host_usage.checked-at" \
            "$STATE_DIR/host_oauth.status" "$STATE_DIR/host_oauth.checked-at"
      usage=$(host_usage_state)
    fi
  fi
  prev_usage=$(cat "$STATE_DIR/usage.last-state" 2>/dev/null || echo "ok")
  printf '%s\n' "$usage" > "$STATE_DIR/usage.last-state"
  if [[ "$usage" == exhausted* ]]; then
    resets="${usage#exhausted}"; resets="${resets# }"
    log "PAUSED: Claude usage window exhausted${resets:+ (resets $resets)} — waiting for reset; jobs stay queued"
    if [[ "$prev_usage" != exhausted* ]]; then
      notify "⏳ Claude usage limit hit — fleet paused${resets:+ until $resets}; jobs stay queued and resume automatically"
    fi
    sleep "$INTERVAL"
    continue
  elif [[ "$prev_usage" == exhausted* ]]; then
    log "usage window reset — fleet resuming"
    notify "▶️ Claude usage window reset — fleet resuming"
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

    track_job_completion "$vm" "$svc" "$env" "$mine"

    if vm_running "$vm"; then
      # If the wrangler restarted while a VM was already running, the
      # marker won't exist — assume "now" so we don't immediately
      # time-cap a fresh runtime.
      [[ -f "$STATE_DIR/$vm.started" ]] || mark_started "$vm"
      # Periodic custody harvest (no-op without a custody record): the
      # guest rotates its login's refresh token whenever the ~1h access
      # token expires mid-job, and auditor VMs self-halt at end of job —
      # so a stop-time harvest alone can miss the rotation and strand the
      # lineage tip on the VM disk (what killed ef and sub2, 2026-08-06).
      # Grabbing every tick keeps the host copy current no matter how the
      # VM later dies.
      ./cont harvest "$vm" >>"$LOG" 2>&1 || true
      cap=$(cap_for "$vm")
      elapsed=$(elapsed_seconds "$vm")
      if (( elapsed > cap )); then
        # Strike the assigned job (if any) before recycling. On the
        # MAX_CAP_STRIKES'th strike, try to give the job back: decline
        # works iff it was never accepted; an accepted job can't be
        # declined ("!open"), so tell the client and park it — the boot
        # gate below then refuses to reboot for it.
        jid=$(get_assigned_job_id "$svc" "$env")
        if [[ -n "$jid" ]]; then
          strikes=$(( $(kv_get "$jid" "$CAP_STRIKES_FILE") + 1 ))
          kv_set "$jid" "$strikes" "$CAP_STRIKES_FILE"
          log "  job $jid: time-cap strike ${strikes}/${MAX_CAP_STRIKES}"
          if (( strikes >= MAX_CAP_STRIKES )); then
            if host_decline "$jid" "$env" "exceeded ${cap}s time cap ${strikes}x"; then
              kv_set "$jid" 0 "$CAP_STRIKES_FILE"
            else
              host_post_message "$jid" "$env" "Worker note: this job has twice exceeded the worker's ${cap}s compute budget without completing, and an accepted job cannot be declined on-chain. Please cancel the job to release it back to the pool, or expect it to remain stalled." || true
              notify "⛔ job ${jid} (${vm}) hit the ${cap}s time cap ${strikes}x — PARKED. Can't decline an accepted job; ask the client to cancel, or raise the cap and clear job ${jid} from ${CAP_STRIKES_FILE}."
            fi
          fi
        fi
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
          # The head-of-queue job is what the agent chewed on and failed to
          # accept — strike it so a poisoned job gets declined after
          # MAX_JOB_STRIKES cycles instead of blocking the queue forever.
          strike_job "$(get_first_job_id "$svc" "$env")" "$env" 1 "boot cycle on $vm ended with no accept"
          stop_vm "$vm" "stuck — no job accept within grace window (open=$open, elapsed=${elapsed}s)"
        fi
      else
        # Holding an assigned job: watch on-chain stage progress so a hung or
        # dead agent is recycled in minutes rather than burning the whole cap.
        # Before the first stage the budget is STALL_FIRST_STAGE_SECONDS (the
        # breadth pass is genuinely slow); after it, STALL_SECONDS per stage.
        jid=$(get_assigned_job_id "$svc" "$env")
        stalled=0
        if [[ -n "$jid" ]]; then
          sig=$(get_job_progress_sig "$jid" "$env")
          sigf="$STATE_DIR/$vm.progress-sig"
          stampf="$STATE_DIR/$vm.progress-at"
          prev=$(cat "$sigf" 2>/dev/null || echo "__unset__")
          if [[ "$sig" != "$prev" ]]; then
            printf '%s' "$sig" > "$sigf"; date +%s > "$stampf"
          else
            budget="$STALL_SECONDS"
            [[ -z "$sig" ]] && budget="$STALL_FIRST_STAGE_SECONDS"
            since=$(cat "$stampf" 2>/dev/null || echo 0)
            (( since == 0 )) && { date +%s > "$stampf"; since=$(date +%s); }
            quiet=$(( $(date +%s) - since ))
            if (( quiet > budget )); then
              recycles=$(kv_get "$jid" "$STALL_RECYCLES_FILE")
              if (( recycles < STALL_MAX_RECYCLES )); then
                kv_set "$jid" $(( recycles + 1 )) "$STALL_RECYCLES_FILE"
                rm -f "$sigf" "$stampf"
                stalled=1
                log "  job $jid: no stage progress for ${quiet}s (budget ${budget}s) — stall recycle $(( recycles + 1 ))/${STALL_MAX_RECYCLES}"
                notify "⚠️ job ${jid} (${vm}) stalled ${quiet}s with no on-chain progress — recycling ($(( recycles + 1 ))/${STALL_MAX_RECYCLES})"
                stop_vm "$vm" "STALLED — no stage note for ${quiet}s while holding job ${jid}"
              else
                log "  job $jid: stalled again at STALL_MAX_RECYCLES — deferring to the time cap"
              fi
            fi
          fi
        fi
        (( stalled )) || log "$vm up, mine=$mine open=$open — leaving alone (elapsed ${elapsed}s/${cap}s)"
      fi
    else
      if [[ "$mine" =~ ^[1-9] || "$open" =~ ^[1-9] ]]; then
        # Parked-job gate: a job at MAX_CAP_STRIKES blocks this agent
        # entirely — booting even for OTHER open jobs is pointless,
        # because the in-VM protocol is "finish IN_PROGRESS first", so
        # any boot resumes the parked job and burns another full cap.
        # Unblocks when the client cancels (job leaves my-jobs) or the
        # job's line is removed from CAP_STRIKES_FILE.
        if [[ "$mine" =~ ^[1-9] ]]; then
          jid=$(get_assigned_job_id "$svc" "$env")
          if [[ -n "$jid" ]] && (( $(kv_get "$jid" "$CAP_STRIKES_FILE") >= MAX_CAP_STRIKES )); then
            log "$vm: assigned job $jid is PARKED (${MAX_CAP_STRIKES} time-cap strikes) — not booting; client cancel or clear it from $CAP_STRIKES_FILE"
            continue
          fi
        fi
        fails=$(kv_get "$vm" "$FAILURES_FILE")
        if (( fails >= MAX_START_RETRIES )); then
          last_fail=$(kv_get "$vm.lastfail" "$FAILURES_FILE")
          if (( $(date +%s) - last_fail >= BACKOFF_RESET_SECONDS )); then
            log "$vm: back-off expired (${BACKOFF_RESET_SECONDS}s since last start failure) — retrying"
            kv_set "$vm" 0 "$FAILURES_FILE"
            fails=0
          fi
        fi
        if (( fails >= MAX_START_RETRIES )); then
          log "$vm: backing off — ${fails} consecutive start failures (retry in ≤${BACKOFF_RESET_SECONDS}s, or when queue empties)"
        else
          # Check VM slot availability BEFORE attempting to boot.
          # Skip the boot when the cap is hit instead of consuming a retry.
          _cap=$(effective_max_vms)
          _running=$(tart list 2>/dev/null | awk '/running/{n++} END{print n+0}')
          if (( _running >= _cap )); then
            log "$vm: no VM slot available (${_running}/${_cap} running) — skipping this tick"
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
            kv_set "$vm.lastfail" "$(date +%s)" "$FAILURES_FILE"
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
