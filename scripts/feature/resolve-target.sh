#!/usr/bin/env bash
# resolve-target.sh — deterministic target-repo classifier for the Feature agent.
#
# A Feature job (Service Type 10) asks us to add functionality to an existing
# project. The customer might reference:
#
#   1. A previous leftclaw build  → "job #99" or `leftclaw-service-job-99`
#   2. An external repo they own  → `github.com/their-org/their-repo`
#   3. A repo we (clawdbotatg) own → DANGER: could be a product we built
#      outside of leftclaw, where our PAT has push rights. A malicious client
#      could ask us to add a backdoor to one of our own products.
#
# This script is the gatekeeper. It scans the job description + chat messages
# (and, optionally, recursively, the description of a referenced leftclaw job)
# and returns a MODE telling the agent what's allowed:
#
#   leftclaw   — clawdbotatg/leftclaw-service-job-<N>; direct push allowed
#   external   — non-clawdbotatg repo; agent must fork+PR
#   blocked    — clawdbotatg/<not-a-leftclaw-service-job>; REFUSE the job
#   ambiguous  — couldn't pinpoint a repo, or got conflicting signals;
#                DECLINE or ask the client for clarification before doing work
#
# The push wrapper (push.sh) re-runs this and refuses to push unless MODE is
# `leftclaw` or `external`. Two layers, same rule.
#
# Usage:
#   resolve-target.sh <job_id>
#
# Output (stdout, structured key/value lines, parseable):
#   MODE: <leftclaw|external|blocked|ambiguous>
#   REPO_URL: <url or empty>
#   REPO_OWNER: <owner or empty>
#   REPO_NAME: <name or empty>
#   REFERENCED_JOB_ID: <N or empty>      # e.g. when the description says "job #99"
#   REASON: <one-line human explanation>
#
# Exit code 0 always (the MODE is the signal). The wrapper interprets MODE.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <job_id>" >&2
  exit 2
fi

JOB_ID="$1"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LEFTCLAW="$SELF_DIR/../leftclaw"

if [ ! -x "$LEFTCLAW/get-job.sh" ]; then
  echo "ERROR: $LEFTCLAW/get-job.sh not found or not executable" >&2
  exit 2
fi

# Pull the job + messages. Both feed the corpus we scan for repo refs.
JOB_JSON="$("$LEFTCLAW/get-job.sh" "$JOB_ID" 2>/dev/null || true)"
MSGS_JSON="$("$LEFTCLAW/messages.sh" "$JOB_ID" 2>/dev/null || echo "[]")"

# Hand off to Python — regex + JSON, much more readable than bash.
python3 - "$JOB_ID" "$JOB_JSON" "$MSGS_JSON" <<'PY'
import json, re, sys

job_id = sys.argv[1]
try:
    job = json.loads(sys.argv[2])
except Exception:
    job = {}
try:
    msgs = json.loads(sys.argv[3])
    if not isinstance(msgs, list):
        msgs = []
except Exception:
    msgs = []

# Build the corpus we scan: job description + every message body.
parts = []
desc = (job.get("description") or "").strip()
if desc:
    parts.append(desc)
for m in msgs:
    if isinstance(m, dict):
        body = m.get("content") or m.get("body") or m.get("message") or ""
        if isinstance(body, str) and body.strip():
            parts.append(body.strip())
corpus = "\n".join(parts)

# --- Repo extraction ---------------------------------------------------
# 1) Full GitHub URLs: github.com/<owner>/<repo>
#    Tolerate trailing .git, /tree/branch, /blob/path, /pull/N, /issues/N, etc.
URL_RE = re.compile(
    r"(?<![A-Za-z0-9._-])"
    r"(?:https?://)?(?:www\.)?github\.com/"
    r"([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?)/"   # owner
    r"([A-Za-z0-9._-]{1,100}?)"                            # repo
    r"(?:\.git)?(?=$|[/?#\s)\]\,\.;!])",
    re.IGNORECASE,
)

# 2) "leftclaw-service-job-<N>" (or with leading owner) — even without URL.
LSJ_RE = re.compile(
    r"(?<![A-Za-z0-9._-])"
    r"(?:([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?)/)?"  # optional owner
    r"leftclaw-service-job-(\d+)\b",
    re.IGNORECASE,
)

# 3) Standalone "job #N" / "job N" / "service job N" — references another
#    leftclaw job whose description we'll recurse into below.
JOBREF_RE = re.compile(
    r"(?<![A-Za-z0-9])"
    r"(?:service\s+job|leftclaw\s+job|job)\s*#?\s*(\d+)\b",
    re.IGNORECASE,
)

# 4) Anti-evasion: bare "clawdbotatg/<repo>" — no github.com prefix. A
#    malicious client could try to slip a sensitive repo past the URL regex
#    by omitting the host. Catch any clawdbotatg/<repo> form and let the
#    classifier handle it (will resolve to leftclaw or blocked).
OWN_RE = re.compile(
    r"(?<![A-Za-z0-9._-])"
    r"clawdbotatg/([A-Za-z0-9._-]{1,100})"
    r"(?=$|[/?#\s)\]\,\.;!])",
    re.IGNORECASE,
)

repos = []  # list of (owner, name, source_tag)

for m in URL_RE.finditer(corpus):
    owner, name = m.group(1), m.group(2)
    # Strip a trailing dot/comma the regex didn't catch.
    name = name.rstrip(".,")
    repos.append((owner, name, "url"))

for m in LSJ_RE.finditer(corpus):
    owner, n = m.group(1), m.group(2)
    repos.append((owner or "clawdbotatg", f"leftclaw-service-job-{n}", "lsj-name"))

for m in OWN_RE.finditer(corpus):
    name = m.group(1).rstrip(".,")
    if name.endswith(".git"):
        name = name[:-4]
    if name:
        repos.append(("clawdbotatg", name, "own-bare"))

# Dedupe preserving order, case-insensitive.
seen = set()
unique = []
for o, n, src in repos:
    key = (o.lower(), n.lower())
    if key in seen:
        continue
    seen.add(key)
    unique.append((o, n, src))

referenced_job_id = ""
jobref_matches = JOBREF_RE.findall(corpus)
# Only treat a "job #N" reference as authoritative when no explicit repo URL
# was found — otherwise we'd duplicate. The agent can still chase it.
if jobref_matches and not unique:
    # Take the first numeric match that isn't the current job.
    for n in jobref_matches:
        if n != str(job_id):
            referenced_job_id = n
            unique.append(("clawdbotatg", f"leftclaw-service-job-{n}", "jobref"))
            break
elif jobref_matches:
    for n in jobref_matches:
        if n != str(job_id):
            referenced_job_id = n
            break

# --- Classification ---------------------------------------------------
def classify(owner, name):
    """Return (mode, reason) for a single repo reference."""
    o = owner.lower()
    n = name.lower()
    if o == "clawdbotatg":
        if re.fullmatch(r"leftclaw-service-job-\d+", n):
            return "leftclaw", "clawdbotatg-owned leftclaw service job — direct push allowed"
        return "blocked", (
            f"clawdbotatg/{name} is owned by us but is NOT a leftclaw-service-job repo. "
            "Refusing to modify our own product. If this is a real Feature job for an "
            "existing leftclaw build, the customer should reference it as "
            "leftclaw-service-job-<N> or by job number."
        )
    return "external", f"{owner}/{name} is external; must fork and open a PR"

mode = "ambiguous"
repo_url = ""
repo_owner = ""
repo_name = ""
reason = ""

if not unique:
    reason = (
        "No GitHub repo and no leftclaw job reference found in description or "
        "messages. Ask the client for the target repo URL or the prior job ID."
    )
elif len(unique) == 1:
    owner, name, _ = unique[0]
    mode, reason = classify(owner, name)
    repo_owner, repo_name = owner, name
    repo_url = f"https://github.com/{owner}/{name}"
else:
    # Multiple references. If they all classify the same AND name the same
    # repo, that's fine. If they disagree, ambiguous.
    classified = [(o, n, classify(o, n)[0]) for o, n, _ in unique]
    modes = {c[2] for c in classified}
    # Special case: if one is "blocked" we surface that — fail-safe wins.
    if "blocked" in modes:
        for o, n, c in classified:
            if c == "blocked":
                mode, reason = classify(o, n)
                repo_owner, repo_name = o, n
                repo_url = f"https://github.com/{o}/{n}"
                break
    elif len(modes) == 1 and len({(o.lower(), n.lower()) for o, n, _ in classified}) == 1:
        owner, name, _ = unique[0]
        mode, reason = classify(owner, name)
        repo_owner, repo_name = owner, name
        repo_url = f"https://github.com/{owner}/{name}"
    else:
        mode = "ambiguous"
        names = ", ".join(f"{o}/{n}" for o, n, _ in unique)
        reason = (
            f"Multiple distinct repo references found ({names}); cannot pick "
            "deterministically. Ask the client which one to modify."
        )

print(f"MODE: {mode}")
print(f"REPO_URL: {repo_url}")
print(f"REPO_OWNER: {repo_owner}")
print(f"REPO_NAME: {repo_name}")
print(f"REFERENCED_JOB_ID: {referenced_job_id}")
print(f"REASON: {reason}")
PY
