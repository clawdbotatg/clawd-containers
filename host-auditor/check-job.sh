#!/usr/bin/env bash
# check-job.sh — INDEPENDENT read-only verifier. Shares no code path with the
# writers in lib/phases.sh: it re-derives every surface from scratch (its own
# on-chain read, its own citation resolver, its own IPFS fetch) so it can catch
# a silent failure the writer's own success path would miss. This is the
# "never let the writer grade its own homework" rule — a writer that printed
# "completed: true" has been wrong before.
#
#   host-auditor/check-job.sh <job_id>
#
# Prints one line per surface (✅ / ❌) and exits nonzero if any is missing.
set -uo pipefail
export PATH="$HOME/.foundry/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
JOB_ID="${1:-}"; [[ "$JOB_ID" =~ ^[0-9]+$ ]] || { echo "usage: check-job.sh <job_id>"; exit 2; }
JOB_DIR="$HERE/jobs/$JOB_ID"
CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"

# Independent env load + RPC (does NOT reuse phases.sh helpers).
set -a; source "$REPO_ROOT/.env.auditor" 2>/dev/null; set +a
RPC="https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY:-}"
fail=0
ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*"; fail=1; }

# 1. On-chain status (independent decode).
raw=$(cast call "$CONTRACT" "getJob(uint256)" "$JOB_ID" --rpc-url "$RPC" 2>/dev/null)
st=$(printf '%s' "$raw" | python3 -c 'import sys
try: print(int.from_bytes(bytes.fromhex(sys.stdin.read().strip()[2:])[7*32:8*32],"big"))
except Exception: print("")' 2>/dev/null)
resurl=$(printf '%s' "$raw" | python3 -c 'import re,sys
# The resultURL is ABI-encoded bytes in the return blob — decode hex to
# text before searching, or the literal "https://" never appears.
raw=sys.stdin.read().strip()
try: txt=bytes.fromhex(raw[2:]).decode("latin-1")
except Exception: txt=raw
m=re.search(r"https://[ -~]*?ipfs[ -~]*?/",txt)
print(m.group(0) if m else "")' 2>/dev/null)
case "$st" in
  2) ok "on-chain: COMPLETE" ;;
  1) bad "on-chain: still IN_PROGRESS (not completed)" ;;
  0) bad "on-chain: OPEN (not accepted)" ;;
  3) bad "on-chain: CANCELLED" ;;
  *) bad "on-chain: status unreadable" ;;
esac

# 2. Safety verdict = go.
if [[ -s "$JOB_DIR/safety/verdict.json" ]] && \
   python3 -c 'import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get("decision")=="go" else 1)' "$JOB_DIR/safety/verdict.json" 2>/dev/null; then
  ok "safety: verdict=go"
else bad "safety: verdict missing or not go"; fi

# 3. Final report exists + pins a commit.
final="$JOB_DIR/report/final-report.md"
if [[ -s "$final" ]] && grep -qE 'commit `[0-9a-f]{7,}`' "$final"; then
  ok "report: present + commit pinned"
else bad "report: missing or no pinned commit"; fi

# 4. Citations resolve (independent resolver over the clone).
if [[ -s "$final" && -d "$JOB_DIR/repo" ]]; then
  read -r pct okc tot < <(python3 - "$final" "$JOB_DIR/repo" <<'PY'
import re,sys,os
txt=open(sys.argv[1]).read(); repo=sys.argv[2]
def lines(p):
    try: return sum(1 for _ in open(p))
    except Exception: return 0
sols=[]
for root,_,files in os.walk(repo):
    if re.search(r'/(node_modules|lib|out|\.git|mocks?|test|interfaces?)(/|$)',root): continue
    for f in files:
        if f.endswith('.sol'): sols.append(os.path.join(root,f))
cites=[]
for f,n in re.findall(r'([A-Za-z0-9_/.-]+\.sol):(\d+)',txt):
    base=os.path.basename(f)
    hit=next((p for p in sols if os.path.basename(p)==base),None)
    if hit: cites.append((hit,int(n)))
# bare "line N" is only unambiguous for a single-file target (see phases.sh)
if len(sols)==1:
    for n in re.findall(r'\blines?\s+(\d+)',txt): cites.append((sols[0],int(n)))
if not cites: print("100 0 0"); raise SystemExit
ok=sum(1 for p,n in cites if 1<=n<=lines(p))
print(f"{int(100*ok/len(cites))} {ok} {len(cites)}")
PY
)
  if (( pct >= 80 )); then ok "citations: $okc/$tot resolve ($pct%)"
  else bad "citations: only $okc/$tot resolve ($pct% < 80%)"; fi
else bad "citations: no report or clone to check against"; fi

# 5. IPFS deliverable reachable + non-trivial.
if [[ -n "$resurl" ]]; then
  sz=$(curl -fsS -m 20 "$resurl" 2>/dev/null | wc -c | tr -d ' ')
  if [[ "${sz:-0}" -gt 800 ]]; then ok "IPFS: reachable ($sz bytes) $resurl"
  else bad "IPFS: unreachable or trivial ($resurl)"; fi
else bad "IPFS: no resultURL on-chain"; fi

echo
[[ "$fail" == "0" ]] && echo "ALL SURFACES ✅ job $JOB_ID verified" || echo "SOME SURFACES ❌ job $JOB_ID incomplete"
exit "$fail"
