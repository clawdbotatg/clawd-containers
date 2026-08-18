#!/usr/bin/env bash
# fleet-health.sh — one-shot "is the fleet OK, and is anything eating my
# subscription?" report. Read-only: it starts nothing, stops nothing, and
# never touches a job.
#
# Exit 0 = all clear, 1 = at least one FLAG. Run it any time:
#     ./scripts/fleet-health.sh
#
# Each section prints OK/FLAG plus the number behind the verdict, so a
# glance tells you whether to dig in.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${HARNESS:-$HOME/clawd/clawd-harness}"
STATE="${TMPDIR:-/tmp}/agent-wrangler"
FLAGS=0
ok()   { printf "  \033[32mOK\033[0m   %s\n" "$*"; }
flag() { printf "  \033[31mFLAG\033[0m %s\n" "$*"; FLAGS=$((FLAGS+1)); }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$*"; }

hdr "daemons"
for l in com.clawd.harness com.leftclaw.wrangler com.clawd.fleet-worker; do
  pid=$(launchctl list 2>/dev/null | awk -v L="$l" '$3==L{print $1}')
  [[ -n "$pid" && "$pid" != "-" ]] && ok "$l running (pid $pid)" || flag "$l NOT running"
done

hdr "audit VMs (running = burning tokens)"
running=$(tart list 2>/dev/null | awk '$NF=="running"{print $2}')
if [[ -z "$running" ]]; then ok "no VMs running (fleet idle)"; else
  for vm in $running; do
    cap=14400; [[ "$vm" == auditor* ]] || cap=7200
    if [[ -f "$STATE/$vm.started" ]]; then
      el=$(( $(date +%s) - $(cat "$STATE/$vm.started") ))
      pct=$(( el * 100 / cap ))
      msg="$vm up ${el}s / ${cap}s cap (${pct}%)"
      (( pct > 80 )) && flag "$msg — near cap, a kill here restarts from ZERO" || ok "$msg"
    else ok "$vm running (no start marker)"; fi
  done
fi

hdr "parked / stuck jobs"
if [[ -s "$STATE/cap_strikes.txt" ]]; then
  while read -r jid n; do
    [[ -z "${jid:-}" ]] && continue
    (( n >= 2 )) && flag "job $jid PARKED (${n} strikes) — blocks its agent, escrow locked" \
                 || ok "job $jid has $n strike(s)"
  done < "$STATE/cap_strikes.txt"
else ok "no cap strikes"; fi

hdr "account usage"
probe="$HARNESS/tools/usage_probe.py"
if [[ -r "$probe" ]]; then
  for d in "$HOME"/.clawd-accounts/*/; do
    d="${d%/}"                      # probe rejects a trailing slash
    a=$(basename "$d")
    out=$(python3 "$probe" "$d" 2>&1)
    if grep -qE "no accessToken|no credentials found" <<<"$out"; then
      flag "$a — LOGGED OUT (needs re-sign-in)"; continue; fi
    if grep -q "429" <<<"$out"; then ok "$a — rate-limited, could not read"; continue; fi
    pct() { awk -v pat="$1" '$0 ~ pat {match($0,/[0-9.]+%/);
              if (RSTART) { printf "%d", substr($0,RSTART,RLENGTH-1)+0; exit }}' <<<"$out"; }
    wk=$(pct "7d total"); h5=$(pct "5h session"); fb=$(pct "7d Fable")
    if [[ -z "$wk" ]]; then flag "$a — could not read usage"; continue; fi
    msg="$a — weekly ${wk}%, 5h ${h5:-?}%, fable ${fb:-?}%"
    if   (( wk >= 90 ));        then flag "$msg — weekly nearly gone"
    elif (( ${h5:-0} >= 95 ));  then flag "$msg — 5h window spent"
    elif (( ${fb:-0} >= 100 )); then flag "$msg — no fable, router will skip it"
    else ok "$msg"; fi
  done
else flag "usage probe not found at $probe"; fi

hdr "handoff stampede (the big subscription burner)"
log="$HOME/Library/Logs/clawd-harness.log"
if [[ -r "$log" ]]; then
  # Count only since the CURRENT server started. The log is append-only across
  # restarts, so a whole-file count keeps reporting a stampede that was already
  # fixed — a check that always flags is a check nobody reads.
  L=$(grep -n "tearing down + exiting" "$log" | tail -1 | cut -d: -f1)
  n=$(tail -n +"${L:-1}" "$log" | grep -c "plan drained")
  b=$(tail -n +"${L:-1}" "$log" | grep -c "handoff budget")
  if   (( n > 20 )); then flag "$n handoffs since last restart — each re-ingests a full context"
  elif (( n > 0 ));  then ok "$n handoff(s) since last restart${b:+, $b batched}"
  else ok "no handoffs since last restart"; fi
else ok "no harness log"; fi

hdr "runaway host processes"
n=$(ps aux | awk '$3>90 && /[r]g |[f]ind |[c]laude/ {print}' | wc -l | tr -d ' ')
(( n > 0 )) && { flag "$n process(es) over 90% CPU:"; ps aux | awk '$3>90 && /[r]g |[f]ind |[c]laude/ {printf "         pid=%s cpu=%s%% %s\n",$2,$3,$11}'; } \
            || ok "nothing pegged"

hdr "code freshness"
cd "$HERE" || exit 1
[[ -z "$(git status --porcelain)" ]] && ok "worktree clean (self-update can run)" \
                                     || flag "worktree DIRTY — this box will stop pulling updates"
git fetch -q origin main 2>/dev/null
behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
(( behind > 0 )) && flag "behind origin/main by $behind commit(s)" || ok "up to date with origin/main"

printf "\n"
(( FLAGS == 0 )) && { printf "\033[32mall clear\033[0m\n"; exit 0; }
printf "\033[31m%d flag(s) — see above\033[0m\n" "$FLAGS"; exit 1
