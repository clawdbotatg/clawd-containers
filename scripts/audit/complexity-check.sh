#!/usr/bin/env bash
# complexity-check.sh — Solidity-LoC scope gate for Smart Contract Audit
# jobs (Service Type 4).
#
# The failure mode this exists for: a client submits more code than the
# audit pipeline can do well in one pass. That is NOT the same as "many
# contracts" — 10 tiny contracts are fine, one 24KB monolith is not
# (job 326: a single repo at 3,788 LoC time-capped forever; job 443: 10
# contracts, several at the EIP-170 size cap). So the gate measures LINES
# OF SOLIDITY, not target count. And the contract only allows a worker-side
# refund (declineJob → escrow back to client) while the job is still OPEN —
# acceptJob moves the escrow to treasury irreversibly — so oversized jobs
# must be caught and refunded BEFORE anything accepts. The wrangler's
# pre-flight calls this for every open type-4 job and declines-with-refund
# on `too_complex`.
#
# Target discovery (description only — no auth):
#   - addresses after an explicit scope marker ("contracts to audit",
#     "audit scope", …) if present, else all unique addresses
#   - GitHub repo URLs — but ONLY when there are no addresses (when both
#     appear, the repo is almost always just the source of the deployed
#     addresses: counting both double-counts; jobs 422/430), and never
#     when the description says "do not use GitHub" (job 427 ships its
#     source out-of-band and marks the GitHub link as an anti-target)
#
# Per-target LoC:
#   - address, Sourcify-verified → exact LoC of the verified sources
#   - address, unverified → eth_getCode bytecode ÷ BYTES_PER_LOC.
#     Calibrated on the leftclaw contract: 23,139 runtime bytes ↔ 1,268
#     source LoC ≈ 18 bytes/line → we use 20 (slightly lenient).
#     Chain comes from a chainId in the description; if absent (or the
#     address is empty there) common chains are probed: Base, Ethereum,
#     Arbitrum, Optimism, Polygon.
#   - github repo → shallow hooks-off clone; *.sol outside lib/,
#     node_modules/, test(s)/, script(s)/, mock(s)/ and not *.t.sol/*.s.sol
#
# All counted source goes through the same section counter: each file is
# split at top-level contract/library/interface declarations, sections
# whose header comments identify a well-known library (OpenZeppelin,
# forge-std, solady, solmate) are dropped, and sections are deduped by
# content hash across the whole job — so flattened files (job 440: five
# .flat.sol supersets of each other, each embedding OZ) count their real
# unique code, not 8K lines of vendored duplication.
#
# Verdict: total LoC > MAX_AUDIT_SOL_LOC (default 3000) → too_complex.
# Unmeasurable targets count 0 — fail open; a probe failure must never
# refuse a paying client.
#
# Results are cached per (job, description-hash) under
# ~/.cache/leftclaw-complexity/ — the wrangler re-runs this every tick and
# the measurement involves network calls.
#
# Usage:  complexity-check.sh <job_id>   (needs ALCHEMY_API_KEY in env)
# Output (stdout, parseable):
#   VERDICT: ok|too_complex
#   TARGETS: <n>
#   LOC: <total estimated Solidity LoC>
#   REASON: <one line, internal>
#   CLIENT_REASON: <one line, safe to embed in the client-facing message>
# Exit code 0 always — VERDICT is the signal.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <job_id>" >&2
  exit 2
fi

JOB_ID="$1"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LEFTCLAW="$SELF_DIR/../leftclaw"
CACHE_DIR="${LEFTCLAW_COMPLEXITY_CACHE:-$HOME/.cache/leftclaw-complexity}"
mkdir -p "$CACHE_DIR"

JOB_JSON="$("$LEFTCLAW/get-job.sh" "$JOB_ID" 2>/dev/null || true)"

# Transient get-job failure: fail open WITHOUT caching, so the next tick
# re-measures instead of trusting a poisoned verdict.
if [ -z "$JOB_JSON" ]; then
  echo "VERDICT: ok"
  echo "TARGETS: 0"
  echo "LOC: 0"
  echo "REASON: get-job returned nothing — failing open (not cached)"
  echo "CLIENT_REASON: "
  exit 0
fi

DESC_HASH="$(printf '%s' "$JOB_JSON" | shasum -a 256 | awk '{print substr($1,1,16)}')"
CACHE_FILE="$CACHE_DIR/job-${JOB_ID}-${DESC_HASH}.out"
if [ -s "$CACHE_FILE" ]; then
  cat "$CACHE_FILE"
  exit 0
fi

MAX_AUDIT_SOL_LOC="${MAX_AUDIT_SOL_LOC:-3000}" \
BYTES_PER_LOC="${BYTES_PER_LOC:-20}" \
ALCHEMY_API_KEY="${ALCHEMY_API_KEY:-}" \
python3 - "$JOB_JSON" > "$CACHE_FILE.tmp" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, urllib.request

MAX_LOC   = int(os.environ.get("MAX_AUDIT_SOL_LOC", "3000"))
BYTES_LOC = int(os.environ.get("BYTES_PER_LOC", "20"))
ALCHEMY   = os.environ.get("ALCHEMY_API_KEY", "")

# chainId -> Alchemy subdomain, in probe order (Base first: it's home turf)
CHAINS = [("8453", "base-mainnet"), ("1", "eth-mainnet"),
          ("42161", "arb-mainnet"), ("10", "opt-mainnet"),
          ("137", "polygon-mainnet")]
CHAIN_MAP = dict(CHAINS)

def emit(verdict, targets, loc, reason, client_reason):
    print(f"VERDICT: {verdict}")
    print(f"TARGETS: {targets}")
    print(f"LOC: {loc}")
    print(f"REASON: {reason}")
    print(f"CLIENT_REASON: {client_reason}")
    sys.exit(0)

try:
    job = json.loads(sys.argv[1])
    desc = (job.get("description") or "").strip()
except Exception:
    emit("ok", 0, 0, "could not parse job — failing open", "")
if not desc:
    emit("ok", 0, 0, "empty description — failing open", "")

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
CHAIN_RE = re.compile(r'chain\s*_?id\W{0,4}(\d{1,10})', re.IGNORECASE)
NO_GITHUB_RE = re.compile(r"do\s+not\s+use\s+(?:the\s+)?github", re.IGNORECASE)
# Clients also ship source as a bare file rather than a repo or an address:
# an IPFS CID (job 672) or a raw.githubusercontent.com file URL (jobs 629,
# 647). Neither matches ADDR_RE or REPO_RE, so the gate used to measure
# TARGETS: 0 / LOC: 0 and fail open on every one of them.
CID_RE = re.compile(r"\b(?:Qm[1-9A-HJ-NP-Za-km-z]{44}|ba[a-z2-7]{50,})\b")
# any direct http(s) link to a .sol file; github.com blob/tree links are
# excluded because REPO_RE already claims those (double-count guard)
SRCURL_RE = re.compile(r"https?://[^\s)\]}>\"\']+\.sol\b", re.IGNORECASE)
IPFS_GATEWAYS = (
    "https://gateway.pinata.cloud/ipfs/{cid}",
    "https://{cid}.ipfs.community.bgipfs.com/",
    "https://ipfs.io/ipfs/{cid}",
)
LIB_NAME_RE = re.compile(r"openzeppelin|forge-std|solady|solmate", re.IGNORECASE)
SECTION_RE = re.compile(
    r"^\s*(?:abstract\s+contract|contract|library|interface)\s+[A-Za-z_]",
)

m = SCOPE_RE.search(desc)
scope_text = desc[m.end():] if m else desc
addrs, seen_a = [], set()
for a in ADDR_RE.findall(scope_text):
    if a.lower() not in seen_a:
        seen_a.add(a.lower()); addrs.append(a)

# Words that mark a repo URL as context/anti-target rather than scope
# ("github.com/x/y is private", "do NOT use the legacy repo", "Reject
# github …") — checked in a window around each URL match.
NEGATION_RE = re.compile(r"private|do\s*not|don'?t|reject|ignore|legacy|avoid",
                         re.IGNORECASE)
repos = []
if not addrs and not NO_GITHUB_RE.search(desc):
    seen_r = set()
    for rm in REPO_RE.finditer(desc):
        window = desc[max(0, rm.start() - 120):rm.end() + 120]
        if NEGATION_RE.search(window):
            continue
        r = "https://" + re.sub(r"^(?:https?://)?(?:www\.)?", "", rm.group(0).rstrip("/."))
        if r.lower() not in seen_r:
            seen_r.add(r.lower()); repos.append(r)

# Direct source: raw .sol URLs and IPFS CIDs. Same gating as repos — only
# when no addresses were found (an address plus its source would double
# count) — and the same negation-window check.
direct_urls, direct_cids = [], []
if not addrs:
    seen_d = set()
    for sm in SRCURL_RE.finditer(desc):
        u = sm.group(0).rstrip(".,;)")
        if re.match(r"https?://(?:www\.)?github\.com/", u, re.IGNORECASE):
            continue                      # REPO_RE owns these
        window = desc[max(0, sm.start() - 120):sm.end() + 120]
        if NEGATION_RE.search(window):
            continue
        if u.lower() not in seen_d:
            seen_d.add(u.lower()); direct_urls.append(u)
    seen_c = set()
    for cm2 in CID_RE.finditer(desc):
        c = cm2.group(0)
        window = desc[max(0, cm2.start() - 120):cm2.end() + 120]
        if NEGATION_RE.search(window):
            continue
        if c not in seen_c:
            seen_c.add(c); direct_cids.append(c)

# Specific .sol files named in the description narrow a repo's scope to
# just those files ("audit X.sol and Y.sol in github.com/o/r") — the rest
# of the repo is context, not scope.
named_sols = {f.lower() for f in re.findall(r"([A-Za-z0-9_.-]+\.sol)\b", desc)
              if not f.endswith((".t.sol", ".s.sol"))}

cm = CHAIN_RE.search(desc)
stated_chain = cm.group(1) if cm else None
chain_order = [c for c in CHAINS if not stated_chain or c[0] == stated_chain]
if stated_chain and not chain_order:
    chain_order = []          # stated but unsupported chain → unmeasurable

# ── section-aware LoC counter, shared by every source of code ───────────
seen_sections = set()

def count_sol(text):
    """Non-blank LoC of text, minus well-known library sections, minus
    sections already counted elsewhere in this job (flattened dupes)."""
    lines = text.splitlines()
    # section start indices (preamble before the first decl is its own chunk)
    starts = [i for i, l in enumerate(lines) if SECTION_RE.match(l)]
    bounds = [0] + starts + [len(lines)]
    total = 0
    for i in range(len(bounds) - 1):
        chunk = lines[bounds[i]:bounds[i + 1]]
        if not chunk:
            continue
        body = "\n".join(chunk)
        # header comments live at the TAIL of the previous chunk (right
        # above the decl); check the last few lines of the preceding chunk
        # plus the decl line itself for a library attribution
        prev_tail = "\n".join(lines[max(0, bounds[i] - 8):bounds[i]])
        header_zone = prev_tail + "\n" + chunk[0]
        if i > 0 and LIB_NAME_RE.search(header_zone):
            continue
        key = hashlib.sha256(body.strip().encode()).hexdigest()
        if key in seen_sections:
            continue
        seen_sections.add(key)
        total += sum(1 for l in chunk if l.strip())
    return total

def http_json(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": "leftclaw-scope-gate"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def get_code_bytes(addr, subdomain):
    req = urllib.request.Request(
        f"https://{subdomain}.g.alchemy.com/v2/{ALCHEMY}",
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode",
                         "params": [addr, "latest"]}).encode(),
        headers={"Content-Type": "application/json"})
    code = json.load(urllib.request.urlopen(req, timeout=15)).get("result") or "0x"
    return max(0, (len(code) - 2) // 2)

LIB_PATH_RE = re.compile(r"openzeppelin|node_modules|forge-std|/solady/|/solmate/",
                         re.IGNORECASE)
verified_loc = est_loc = repo_loc = 0
n_verified = n_estimated = unmeasured = 0

for a in addrs:
    counted = False
    for chain_id, subdomain in chain_order:
        # exact first: Sourcify verified sources on this chain
        try:
            d = http_json(f"https://sourcify.dev/server/v2/contract/{chain_id}/{a}?fields=sources")
            srcs = d.get("sources") or {}
            if srcs:
                for path, s in srcs.items():
                    if LIB_PATH_RE.search(path):
                        continue
                    verified_loc += count_sol(s.get("content") or "")
                n_verified += 1
                counted = True
                break
        except Exception:
            pass
        # estimate: runtime bytecode on this chain
        if ALCHEMY:
            try:
                nbytes = get_code_bytes(a, subdomain)
                if nbytes > 0:
                    est_loc += nbytes // BYTES_LOC
                    n_estimated += 1
                    counted = True
                    break
            except Exception:
                pass
    else:
        # no chain had code for it: an EOA (deployer/fee recipient mentioned
        # in the description) — not an audit target, ignore silently
        if chain_order:
            counted = True
    if not counted:
        unmeasured += 1

for r in repos:
    tmp = tempfile.mkdtemp(prefix="scope-gate-")
    try:
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
        subprocess.run(
            ["git", "-c", "core.hooksPath=/dev/null", "clone", "--depth", "1",
             "--no-tags", "--single-branch", r, tmp],
            capture_output=True, timeout=120, env=env, check=True)
        SKIP_DIRS = {"lib", "node_modules", ".git", "test", "tests",
                     "script", "scripts", "mock", "mocks", "dependencies"}
        candidates = []
        for root, dirs, files in os.walk(tmp):
            dirs[:] = [d for d in dirs if d.lower() not in SKIP_DIRS]
            for f in files:
                if not f.endswith(".sol") or f.endswith((".t.sol", ".s.sol")):
                    continue
                candidates.append(os.path.join(root, f))
        # Narrow to the named files when the description names some and
        # they exist in this clone; otherwise the whole repo is the scope.
        if named_sols:
            matched = [p for p in candidates
                       if os.path.basename(p).lower() in named_sols]
            if matched:
                candidates = matched
        for p in candidates:
            try:
                with open(p, errors="replace") as fh:
                    repo_loc += count_sol(fh.read())
            except Exception:
                pass
    except Exception:
        unmeasured += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

# ── direct source files (raw URLs + IPFS CIDs) ─────────────────────────
direct_loc = 0
n_direct = 0

def fetch_text(url, timeout=30, cap=8_000_000):
    req = urllib.request.Request(url, headers={"User-Agent": "leftclaw-scope-gate"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(cap).decode("utf-8", errors="replace")

def looks_solidity(t):
    return bool(re.search(r"pragma\s+solidity|^\s*(?:abstract\s+contract|contract|library|interface)\s+[A-Za-z_]",
                          t, re.MULTILINE))

for u in direct_urls:
    try:
        t = fetch_text(u)
        if looks_solidity(t):
            direct_loc += count_sol(t); n_direct += 1
        else:
            unmeasured += 1
    except Exception:
        unmeasured += 1

for c in direct_cids:
    got = False
    for g in IPFS_GATEWAYS:
        try:
            t = fetch_text(g.format(cid=c))
        except Exception:
            continue
        if looks_solidity(t):
            direct_loc += count_sol(t); n_direct += 1; got = True
        break                              # gateway answered; don't re-fetch
    if not got:
        unmeasured += 1

total = verified_loc + est_loc + repo_loc + direct_loc
targets = len(addrs) + len(repos) + len(direct_urls) + len(direct_cids)
detail = []
if verified_loc: detail.append(f"{verified_loc} verified-source LoC ({n_verified} contracts)")
if est_loc:      detail.append(f"~{est_loc} LoC est. from bytecode ({n_estimated} contracts)")
if repo_loc:     detail.append(f"{repo_loc} repo LoC ({len(repos)} repos)")
if direct_loc:   detail.append(f"{direct_loc} direct-source LoC ({n_direct} files)")
if unmeasured:   detail.append(f"{unmeasured} target(s) unmeasurable, counted as 0")
detail = "; ".join(detail) or "nothing measurable"

if total > MAX_LOC:
    emit("too_complex", targets, total,
         f"~{total} LoC of Solidity > budget {MAX_LOC} ({detail})",
         f"roughly {total:,} lines of Solidity across {targets} target(s), "
         f"vs our per-job audit budget of about {MAX_LOC:,} lines")
emit("ok", targets, total, f"~{total} LoC within budget {MAX_LOC} ({detail})", "")
PY
mv "$CACHE_FILE.tmp" "$CACHE_FILE"
cat "$CACHE_FILE"
