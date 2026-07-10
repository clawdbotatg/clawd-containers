#!/usr/bin/env bash
# state.sh — per-job progress ledger + resume-line printer.
#
# The whole point of the host auditor is run/stop/run/stop over hours, so
# state is durable and on disk: jobs/<id>/state.json is a small JSON object
# { "job_id", "phase_done": {<phase>: <unix_ts>, …}, "target", "updated" }.
#
# IMPORTANT — state.json is a MEMO, never the source of truth. Idempotency
# lives in the phase functions, which re-check the REAL surface (on-chain
# status, an artifact file, a recorded IPFS URL). We learned this the hard
# way across the fleet: a local "done" flag lies after a crash, a manual
# edit, or a partial run. state.json only speeds up the happy path and
# records timing/telemetry; a phase must still be safe to re-run with its
# ledger entry present.
#
# Sourced by audit.sh. Requires JOB_DIR to be set by the caller.

# Ordered phase list — the state machine. Kept here so audit.sh, the resume
# logic, and the PLAN printer all agree on one ordering.
PHASES=(intake sanitize safety accept audit report publish complete)

_state_file() { echo "$JOB_DIR/state.json"; }

# Print the whole state object (or an empty skeleton if none yet).
state_read() {
  local f; f="$(_state_file)"
  if [[ -s "$f" ]]; then
    cat "$f"
  else
    printf '{"job_id":%s,"phase_done":{},"target":null,"updated":null}\n' "${JOB_ID:-null}"
  fi
}

# state_get <dot.path> — read a value via python (empty string if absent).
state_get() {
  state_read | python3 -c 'import json,sys
d=json.load(sys.stdin)
cur=d
for k in sys.argv[1].split("."):
    if isinstance(cur,dict) and k in cur: cur=cur[k]
    else: cur=None; break
print("" if cur is None else (cur if isinstance(cur,str) else json.dumps(cur)))' "$1"
}

# state_set <dot.path> <raw_json_or_string> — merge one key and persist.
# Values that parse as JSON are stored as JSON; otherwise stored as a string.
state_set() {
  local path="$1" val="$2" f; f="$(_state_file)"
  mkdir -p "$JOB_DIR"
  local now; now="$(date +%s)"
  state_read | JOB_STATE_NOW="$now" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
path=sys.argv[1].split("."); raw=sys.argv[2]
try: val=json.loads(raw)
except Exception: val=raw
cur=d
for k in path[:-1]:
    cur=cur.setdefault(k,{})
cur[path[-1]]=val
d["updated"]=int(os.environ["JOB_STATE_NOW"])
print(json.dumps(d,indent=2))' "$path" "$val" > "$f.tmp" && mv "$f.tmp" "$f"
}

# Mark a phase complete (records the timestamp). Idempotent.
state_mark_done() {
  local phase="$1"
  state_set "phase_done.$phase" "$(date +%s)"
}

# True if a phase has a ledger entry. Callers STILL re-check the real
# surface — this only short-circuits the happy path.
state_is_done() {
  local phase="$1" v
  v="$(state_get "phase_done.$phase")"
  [[ -n "$v" ]]
}

# The first phase not yet marked done (or "" if all done).
state_next_phase() {
  local p
  for p in "${PHASES[@]}"; do
    state_is_done "$p" || { echo "$p"; return; }
  done
  echo ""
}

# Print the exact command to resume from a given phase. Errors that teach
# their own recovery: whenever a phase stops or fails, we echo this so the
# operator never has to reconstruct the invocation.
resume_line() {
  local from="$1"
  echo "  resume:  host-auditor/audit.sh $JOB_ID --go --from $from"
}
