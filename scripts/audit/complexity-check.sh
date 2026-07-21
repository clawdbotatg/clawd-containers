#!/usr/bin/env bash
# complexity-check.sh — deterministic scope gate for Smart Contract Audit
# jobs (Service Type 4).
#
# The failure mode this exists for: a client submits a WHOLE PROTOCOL as one
# job (job 443: 10 contracts on Base). The audit pipeline does its best work
# on 1–2 contracts per job; a 10-contract job burns boot after boot, hits
# time caps, and never ships a report worth its escrow. Worse, the contract
# only allows a worker-side refund (declineJob → escrow back to client)
# while the job is still OPEN — the moment acceptJob runs, the escrow moves
# to treasury and the job can only end via completeJob or an owner
# adminResetJob. So an oversized job must be caught and refunded BEFORE
# anything accepts it. The wrangler's pre-flight calls this script for every
# open type-4 job and declines-with-refund on `too_complex`.
#
# How targets are counted (description only — no auth needed, no LLM,
# no clone; this runs on every wrangler tick):
#
#   1. If the description has an explicit audit-scope marker ("contracts to
#      audit", "audit the following contracts", "audit scope", …), count the
#      unique 0x… addresses AFTER the marker. High confidence — that list is
#      the scope. Threshold: MAX_AUDIT_TARGETS (default 2).
#   2. No marker: count unique 0x… addresses in the whole description. This
#      region also holds context addresses (deployer, USDC, fee recipient),
#      so be lenient — only flag when the count exceeds
#      MAX_AUDIT_ADDRS_NOSCOPE (default 5). A one-contract job that mentions
#      a few infra addresses must NOT get refused.
#   3. GitHub repo URLs count as one target each (a repo job's real size is
#      judged later, at intake/clone time — not here).
#
# Fail-open: any error (get-job unreachable, unparseable JSON) → VERDICT: ok.
# A probe failure must never refuse a paying client.
#
# Usage:  complexity-check.sh <job_id>       (needs ALCHEMY_API_KEY in env)
# Output (stdout, parseable):
#   VERDICT: ok|too_complex
#   TARGETS: <n>
#   REASON: <one line>
# Exit code 0 always — VERDICT is the signal.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <job_id>" >&2
  exit 2
fi

JOB_ID="$1"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LEFTCLAW="$SELF_DIR/../leftclaw"

JOB_JSON="$("$LEFTCLAW/get-job.sh" "$JOB_ID" 2>/dev/null || true)"

MAX_AUDIT_TARGETS="${MAX_AUDIT_TARGETS:-2}" \
MAX_AUDIT_ADDRS_NOSCOPE="${MAX_AUDIT_ADDRS_NOSCOPE:-5}" \
python3 - "$JOB_JSON" <<'PY'
import json, os, re, sys

MAX_TARGETS = int(os.environ.get("MAX_AUDIT_TARGETS", "2"))
MAX_NOSCOPE = int(os.environ.get("MAX_AUDIT_ADDRS_NOSCOPE", "5"))

def emit(verdict, targets, reason):
    print(f"VERDICT: {verdict}")
    print(f"TARGETS: {targets}")
    print(f"REASON: {reason}")
    sys.exit(0)

try:
    job = json.loads(sys.argv[1])
    desc = (job.get("description") or "").strip()
except Exception:
    emit("ok", 0, "could not read job — failing open")

if not desc:
    emit("ok", 0, "empty description — failing open")

ADDR_RE = re.compile(r"0x[a-fA-F0-9]{40}\b")
REPO_RE = re.compile(
    r"(?:https?://)?(?:www\.)?github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+",
    re.IGNORECASE,
)
SCOPE_RE = re.compile(
    r"contracts?\s+(?:to\s+(?:be\s+)?audit|for\s+audit|in\s+scope)"
    r"|audit\s+(?:the\s+following|these)\s+contracts?"
    r"|audit\s+scope",
    re.IGNORECASE,
)

def uniq_addrs(text):
    return {a.lower() for a in ADDR_RE.findall(text)}

repos = {r.lower().rstrip("/.") for r in REPO_RE.findall(desc)}

m = SCOPE_RE.search(desc)
if m:
    scoped = uniq_addrs(desc[m.end():])
    n = len(scoped) + len(repos)
    if n > MAX_TARGETS:
        emit("too_complex", n,
             f"explicit audit scope lists {n} targets (max {MAX_TARGETS} per job)")
    emit("ok", max(n, 1), f"explicit audit scope lists {n} target(s)")

n_addrs = len(uniq_addrs(desc))
n = n_addrs + len(repos)
if n_addrs > MAX_NOSCOPE:
    emit("too_complex", n_addrs,
         f"{n_addrs} distinct contract addresses with no explicit scope "
         f"(lenient max {MAX_NOSCOPE}) — looks like a whole protocol")
emit("ok", max(n, 1), f"{n_addrs} address(es), {len(repos)} repo(s) — within scope")
PY
