#!/usr/bin/env bash
# audit.sh — host-native, resumable, gated auditor orchestrator.
#
#   host-auditor/audit.sh <job_id>                 # PLAN (no side effects)
#   host-auditor/audit.sh <job_id> --go            # run all phases to completion
#   host-auditor/audit.sh <job_id> --go --from audit   # resume from a phase
#   host-auditor/audit.sh <job_id> --go --only safety  # run one phase
#   host-auditor/audit.sh <job_id> --go --no-complete  # stop before on-chain complete
#
# Runs raw on the host — NO container, NO time cap. Every artifact lives under
# host-auditor/jobs/<job_id>/ so a run can stop and resume. Safety pre-flight
# gates everything: nothing untrusted is executed, and even a prompt-injected
# audit agent cannot read the host's secrets (sandbox-exec, see lib/sandbox.sh).
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
LC="$REPO_ROOT/scripts/leftclaw"
BG="$REPO_ROOT/scripts/bgipfs"
SKILLS="$REPO_ROOT/skills"

JOB_ID="${1:-}"; shift || true
[[ "$JOB_ID" =~ ^[0-9]+$ ]] || { echo "usage: audit.sh <job_id> [--go] [--from <phase>] [--only <phase>] [--no-complete]"; exit 2; }

GO=0; FROM=""; ONLY=""; NO_COMPLETE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --go) GO=1 ;;
    --from) FROM="$2"; shift ;;
    --only) ONLY="$2"; shift ;;
    --no-complete) NO_COMPLETE=1 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac; shift
done

JOB_DIR="$HERE/jobs/$JOB_ID"; mkdir -p "$JOB_DIR"
export JOB_ID JOB_DIR HERE REPO_ROOT LC BG SKILLS GO

# shellcheck source=lib/state.sh
source "$HERE/lib/state.sh"
source "$HERE/lib/sandbox.sh"
source "$HERE/lib/safety.sh"
source "$HERE/lib/phases.sh"

RUN_LOG="$JOB_DIR/run.log"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG"; }

[[ "$GO" == "1" ]] || log "=== PLAN for job $JOB_ID (no side effects; add --go to execute) ==="
[[ "$GO" == "1" ]] && log "=== RUN job $JOB_ID (host-native, no time cap) ==="

# Which phases to run this invocation.
declare -a RUN=()
if [[ -n "$ONLY" ]]; then RUN=("$ONLY")
else
  start_at="${FROM:-}"
  seen=0
  for p in "${PHASES[@]}"; do
    [[ -z "$start_at" ]] && seen=1
    [[ "$p" == "$start_at" ]] && seen=1
    (( seen )) && RUN+=("$p")
  done
fi

for phase in "${RUN[@]}"; do
  [[ "$phase" == "complete" && "$NO_COMPLETE" == "1" ]] && { log "skip complete (--no-complete)"; break; }
  log "── phase: $phase"
  "phase_$phase"; rc=$?
  case $rc in
    0) : ;;                              # done (or skipped as already-done)
    2) : ;;                              # PLAN dry-run: printed intent, no side effect
    3) log "phase $phase PARKED (waiting on an external condition — safe to retry later)"
       resume_line "$phase" | tee -a "$RUN_LOG"; exit 3 ;;
    *) log "phase $phase FAILED (rc=$rc)"
       resume_line "$phase" | tee -a "$RUN_LOG"; exit 1 ;;
  esac
done

if [[ "$GO" == "1" ]]; then
  nxt="$(state_next_phase)"
  if [[ -z "$nxt" ]]; then log "✅ all phases complete for job $JOB_ID"
  else log "stopped with next phase = $nxt"; resume_line "$nxt" | tee -a "$RUN_LOG"; fi
else
  log "PLAN complete. Re-run with --go to execute."
fi
