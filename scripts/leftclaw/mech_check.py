#!/usr/bin/env python3
"""Layer 1 of REVIEW.md — mechanical checks over a completed leftclaw job.

No model, no judgment: every check here is something a script can decide.
Anything requiring taste belongs in Layer 2.

Driven by mech-check.sh, which supplies ALCHEMY_API_KEY. See that script for
the CLI. The checks, in order:

  result-fetch  resultURL resolves, is non-trivial, and parses as markdown
  pin           report pins a commit hash (repos) or address+chain (on-chain)
  citations     every `File.sol:N` citation's quoted code actually lives there
  stages        logWork stage notes exist for the service type's phases
  escalations   no client message went unanswered before completion

`citations` is the one that matters most: it is the check job 372 fails, and
line drift is invisible to clients right up until they try to read the code.
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

CONTRACT = "0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"

# topic0s, recovered by decoding the contract's log stream (no public ABI).
EV_POSTED = "0xfedb08719ec013458bbe9c86e0b87a10413be78ff76c974a0dac8cce68e73e8a"
EV_ACCEPTED = "0x4426e4a90a9570c8f678a263b11785eaaade8b79d76d18c43d4d8e00062e4f83"
EV_WORK = "0xc181770b18c66c81dce39e4f7d4100884b62c26403dddf12b19b1de85cdc3ac4"
EV_COMPLETED = "0x884d377a76a733295a9fde0f6f3729db2762d3ed11c468fa3904b134ab552dda"

CACHE = os.path.expanduser("~/.cache/leftclaw-mech")

# Etherscan's multichain V2 endpoint covers the testnets Sourcify doesn't
# mirror. Rather than make a key mandatory, borrow scaffold-eth-2's pattern:
# ship its shared public key as the default and let ETHERSCAN_API_KEY override.
# It is published in scaffold-eth-2's hardhat.config.ts for exactly this use
# and is rate-limited — fine for reviewing a handful of jobs, set your own for
# anything sustained.
SHARED_ETHERSCAN_KEY = "DNXJA8RX2Q3VZ4URQIWP7Z68CJXQZSC6AW"

# How far a quoted snippet may sit from its cited line before we call it drift.
# Reports legitimately cite the head of a function and quote a few lines into
# it, so this is deliberately loose; it still catches the hundreds-of-lines
# drift that motivated the check.
SLACK = 5

PASS, WARN, FAIL, SKIP = "PASS", "WARN", "FAIL", "SKIP"


class Check:
    def __init__(self, name, status, summary, detail=None):
        self.name, self.status, self.summary = name, status, summary
        self.detail = detail or []
        self.flags = {}

    def as_dict(self):
        return {
            "check": self.name,
            "status": self.status,
            "summary": self.summary,
            "detail": self.detail,
        }


# ── chain ────────────────────────────────────────────────────────────────


def rpc_url():
    key = os.environ.get("ALCHEMY_API_KEY")
    if not key:
        sys.exit("ALCHEMY_API_KEY not set")
    return f"https://base-mainnet.g.alchemy.com/v2/{key}"


def job_logs(job_id):
    """Every event for one job, oldest first."""
    flt = {
        "address": CONTRACT,
        "fromBlock": "0x0",
        "toBlock": "latest",
        "topics": [None, "0x%064x" % int(job_id)],
    }
    out = subprocess.run(
        ["cast", "rpc", "eth_getLogs", json.dumps(flt), "--rpc-url", rpc_url()],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"eth_getLogs failed: {out.stderr.strip()[:200]}")
    logs = json.loads(out.stdout)
    return sorted(logs, key=lambda l: (int(l["blockNumber"], 16), int(l.get("logIndex", "0x0"), 16)))


def decode_strings(data_hex):
    """Pull every ABI-encoded dynamic string out of an event's data blob.

    The contract's ABI isn't published, so rather than hardcode each event's
    shape we walk the head words looking for values that behave like offsets
    into a well-formed (length, bytes) tail. Order follows the head, which is
    parameter order.
    """
    b = bytes.fromhex(data_hex[2:] if data_hex.startswith("0x") else data_hex)
    out, seen = [], set()
    nwords = len(b) // 32
    # Event data is encoded from byte 0; a `getJob` return is a tuple whose
    # inner offsets are relative to the tuple body (byte 32). Try both bases
    # rather than requiring the caller to know which shape it holds.
    for base in (0, 32):
        for i in range(nwords):
            off = base + int.from_bytes(b[i * 32:(i + 1) * 32], "big")
            if off % 32 or not (32 <= off < len(b)) or off + 32 > len(b):
                continue
            n = int.from_bytes(b[off:off + 32], "big")
            if n == 0 or off + 32 + n > len(b):
                continue
            try:
                s = b[off + 32:off + 32 + n].decode("utf-8")
            except UnicodeDecodeError:
                continue
            if s.strip() and (off, n) not in seen:
                seen.add((off, n))
                out.append(s)
    return out


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers={"User-Agent": "leftclaw-mech-check"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


# ── checks ───────────────────────────────────────────────────────────────


def check_result(logs):
    """resultURL present, fetches, non-trivial, reads as markdown."""
    urls = []
    for lg in logs:
        if lg["topics"][0] == EV_COMPLETED:
            urls += [s for s in decode_strings(lg["data"]) if s.startswith("http")]
    if not urls:
        return Check("result-fetch", FAIL, "no resultURL in any JobCompleted event"), None
    url = urls[-1]
    try:
        raw = fetch(url)
    except (urllib.error.URLError, OSError) as e:
        return Check("result-fetch", FAIL, f"resultURL did not fetch: {e}", [url]), None
    try:
        md = raw.decode("utf-8")
    except UnicodeDecodeError:
        return Check("result-fetch", FAIL, "resultURL is not UTF-8 text", [url]), None

    lines = md.count("\n") + 1
    if len(raw) < 2048:
        return Check("result-fetch", FAIL, f"report is only {len(raw)} bytes", [url]), md
    if not re.search(r"^#{1,3}\s+\S", md, re.M):
        return Check("result-fetch", FAIL, "no markdown headings in report", [url]), md
    return Check("result-fetch", PASS, f"{len(raw)} bytes, {lines} lines, markdown", [url]), md


def find_pin(md, description):
    """Return (kind, value, chain) for the audit target this report pins."""
    m = re.search(r"\b(?:commit|rev|pinned at|@)\D{0,12}\b([0-9a-f]{40})\b", md, re.I)
    if not m:
        m = re.search(r"\b([0-9a-f]{40})\b", md)
    if m:
        return "commit", m.group(1), None

    m = re.search(r"\b(?:commit|rev)\D{0,12}\b([0-9a-f]{7,12})\b", md, re.I)
    if m:
        return "commit", m.group(1), None

    addr = re.search(r"\b(0x[0-9a-fA-F]{40})\b", md)
    if addr:
        chain = None
        cm = re.search(r"\b(8453|84532|1|11155111|10|42161|137)\b", md)
        if re.search(r"base\s+sepolia", md, re.I):
            chain = 84532
        elif re.search(r"\bbase\b", md, re.I):
            chain = 8453
        elif cm:
            chain = int(cm.group(1))
        return "address", addr.group(1), chain
    return None, None, None


def check_pin(md, description):
    kind, value, chain = find_pin(md, description)
    if not kind:
        return Check("pin", FAIL, "report pins neither a commit hash nor a contract address"), (None, None, None)
    if kind == "commit":
        return Check("pin", PASS, f"commit {value[:12]}"), (kind, value, chain)
    where = f"chain {chain}" if chain else "chain not stated"
    status = PASS if chain else WARN
    return Check("pin", status, f"contract {value} · {where}"), (kind, value, chain)


EXPLORER_CHAINS = [
    (r"sepolia\.basescan\.org", 84532),
    (r"basescan\.org", 8453),
    (r"sepolia\.etherscan\.io", 11155111),
    (r"etherscan\.io", 1),
    (r"arbiscan\.io", 42161),
    (r"optimistic\.etherscan\.io", 10),
    (r"polygonscan\.com", 137),
]


def onchain_target(description, md):
    """(addresses, chain) for a job whose target is deployed contract(s).

    Two shapes occur in real briefs: a direct explorer link, and — job 568 —
    a *template* link (`sepolia.basescan.org/address/<addr>#code`) with the
    real addresses in a table below it. The second defeats URL matching, so
    fall back to taking the chain from the domain and every address from the
    text. A brief naming several contracts wants all of them checked, not the
    first one.
    """
    for text in (description, md):
        if not text:
            continue
        for pat, chain in EXPLORER_CHAINS:
            if not re.search(pat, text):
                continue
            linked = re.findall(pat + r"/address/(0x[0-9a-fA-F]{40})", text)
            if linked:
                return list(dict.fromkeys(linked)), chain
            loose = re.findall(r"\b(0x[0-9a-fA-F]{40})\b", text)
            if loose:
                return list(dict.fromkeys(loose))[:6], chain
    return [], None


def repo_url_from(text):
    m = re.search(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", text or "")
    if not m:
        return None
    return re.sub(r"(\.git)?/?$", "", m.group(0).rstrip(").,"))


def ensure_repo(url, commit):
    """Clone (blobless, cached) and check out the pin.

    Returns (path, actual_ref, pinned_ok). A pin the remote won't serve is not
    fatal — we fall back to the default branch so the citation check still
    runs — but the caller must surface it, because an unfetchable pin means
    nobody can reproduce the audit against the code that was actually read.
    """
    os.makedirs(CACHE, exist_ok=True)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", url.split("github.com/")[1])
    path = os.path.join(CACHE, slug)
    if not os.path.isdir(os.path.join(path, ".git")):
        r = subprocess.run(
            ["git", "clone", "--quiet", "--filter=blob:none", url + ".git", path],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            raise RuntimeError(f"clone failed: {r.stderr.strip()[:160]}")

    def head():
        return subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

    if commit:
        subprocess.run(["git", "-C", path, "fetch", "--quiet", "origin", commit],
                       capture_output=True, text=True)
        co = subprocess.run(["git", "-C", path, "checkout", "--quiet", "--detach", commit],
                            capture_output=True, text=True)
        if co.returncode == 0:
            return path, commit, True
        # Pin unreachable (force-push, fork, or a hash that never existed).
        subprocess.run(["git", "-C", path, "checkout", "--quiet", "-"],
                       capture_output=True, text=True)
        return path, head(), False
    return path, head(), True


def sourcify_sources(chain, addr):
    """Verified sources for an on-chain target, as {relpath: text}. {} if none.

    Sourcify API v1 is in a scheduled brownout through 2027-01, so this speaks
    v2 only. Falls back to Etherscan's multichain V2 endpoint when the caller
    has ETHERSCAN_API_KEY set (we normally don't — keyless is the default).
    """
    if not chain:
        return {}
    try:
        raw = fetch(f"https://sourcify.dev/server/v2/contract/{chain}/{addr}"
                    f"?fields=sources", timeout=45)
        payload = json.loads(raw)
        src = payload.get("sources") or {}
        out = {p: v.get("content", "") for p, v in src.items()
               if p.endswith(".sol") and isinstance(v, dict)}
        if out:
            return out
    except (urllib.error.URLError, OSError, json.JSONDecodeError, AttributeError):
        pass

    key = os.environ.get("ETHERSCAN_API_KEY") or SHARED_ETHERSCAN_KEY
    try:
        raw = fetch(f"https://api.etherscan.io/v2/api?chainid={chain}&module=contract"
                    f"&action=getsourcecode&address={addr}&apikey={key}", timeout=45)
        res = json.loads(raw).get("result") or []
    except (urllib.error.URLError, OSError, json.JSONDecodeError):
        return {}
    out = {}
    for entry in res:
        blob = entry.get("SourceCode") or ""
        name = entry.get("ContractName") or "Contract"
        if blob.startswith("{"):
            try:
                inner = json.loads(blob[1:-1] if blob.startswith("{{") else blob)
                for p, v in (inner.get("sources") or inner).items():
                    if p.endswith(".sol"):
                        out[p] = v.get("content", "") if isinstance(v, dict) else str(v)
            except json.JSONDecodeError:
                pass
        elif blob:
            out[f"{name}.sol"] = blob
    return out


CITE_RE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_./-]*\.sol)\s*:\s*(\d+)(?:\s*[-–—]\s*(\d+))?")


def norm(s):
    """Whitespace-free form for comparing a quote against source.

    Collapsing runs to single spaces is not enough: reports routinely quote
    `_pauseWindows[n-1].end` where the file reads `_pauseWindows[n - 1].end`.
    That is the same line of code, and spacing around operators must not
    decide whether a citation resolves.
    """
    return re.sub(r"\s+", "", s)


FIX_CONTEXT = re.compile(r"\*\*(?:Fix|Recommendation|Mitigation|Patch)\b|^#{2,5}\s*(?:Fix|Recommend)",
                         re.I | re.M)


def is_proposed_fix(lang, body, ctx):
    """A remediation diff is not a claim about what the source says.

    Reports end findings with a ```diff showing the patch they recommend. Its
    `+` lines are code that deliberately does not exist yet, and the block is
    often about a different file than the finding's own citation. Checking
    either against the target manufactures 'quoted code not found in file' —
    an accusation of fabrication aimed at a correct report.
    """
    if lang.strip().lower() == "diff":
        return True
    if any(l.startswith("+") for l in body) and any(l.startswith("-") for l in body):
        return True
    return bool(FIX_CONTEXT.search("\n".join(ctx.split("\n")[-3:])))


def code_blocks(md):
    """Fenced blocks as (body_lines, context), excluding remediation diffs."""
    lines = md.split("\n")
    blocks, i = [], 0
    while i < len(lines):
        stripped = lines[i].lstrip()
        if stripped.startswith("```"):
            lang = stripped[3:]
            start = i
            i += 1
            body = []
            while i < len(lines) and not lines[i].lstrip().startswith("```"):
                body.append(lines[i])
                i += 1
            ctx = "\n".join(lines[max(0, start - 6):start])
            if not is_proposed_fix(lang, body, ctx):
                blocks.append((body, ctx))
        i += 1
    return blocks


def candidate_lines(body):
    """Substantive source lines from a quoted block — no comments, no diff noise."""
    out = []
    for ln in body:
        s = ln.rstrip()
        if s[:1] in ("+", "-") and not s.lstrip("+-").lstrip().startswith(("+", "-")):
            s = s[1:]
        t = s.strip()
        if not t or t.startswith(("//", "*", "/*", "#")):
            continue
        # Reports annotate quoted code with trailing `// line 183` markers.
        # Left in, the snippet is strictly longer than the real source line and
        # never matches — a false "not found" against perfectly good code.
        t = re.sub(r"\s*//.*$", "", t).strip()
        if len(re.sub(r"\s", "", t)) < 12:
            continue
        out.append(t)          # raw; callers norm() or tokenize as needed
    return out


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
WINDOW = 5          # source lines a single quoted statement may span
TOKEN_MATCH = 0.8   # identifier overlap that counts as the same code


def _find_exact(flines, cands, lo, hi):
    """First line in [lo,hi] where a quote appears, allowing it to span lines.

    Reports flatten multi-line statements — a four-line `if (...)` becomes one
    quoted line — so compare against joined windows, not just single lines.
    """
    lo, hi = max(1, lo), min(len(flines), hi)
    normed = [norm(c) for c in cands]
    for i in range(lo - 1, hi):
        for span in range(1, WINDOW + 1):
            blob = norm("".join(flines[i:i + span]))
            if not blob:
                continue
            for c in normed:
                if c and c in blob:
                    return i + 1
    return None


def _token_match(flines, cands, lo, hi):
    """Same code, lightly reworded.

    Job 570 quotes `CostBasis.sequencerUpFor(feed) <= SEQ_SETTLE_GRACE …` where
    the source names the argument `sequencerUptimeFeed`. The citation is right
    and the substance is right; only an identifier was shortened for reading.
    Demanding a byte-exact quote there would call good work fabricated.
    """
    lo, hi = max(1, lo), min(len(flines), hi)
    ftoks = set(IDENT.findall(" ".join(flines[lo - 1:hi])))
    if not ftoks:
        return False
    for c in cands:
        ctoks = set(IDENT.findall(c))
        if ctoks and len(ctoks & ftoks) / len(ctoks) >= TOKEN_MATCH:
            return True
    return False


# `GoodBidAuction.sol:1665`: `if (bidder == lot.leader) revert AlreadyLeader();`
# — the citation and its evidence in one breath, which is how the strongest
# findings actually read. Verified exactly like a fenced block.
INLINE_RE = re.compile(
    r"`([A-Za-z0-9_][A-Za-z0-9_./-]*\.sol)\s*:\s*(\d+)(?:\s*[-–—]\s*(\d+))?`"
    r"[^`\n]{0,24}`([^`\n]{16,})`")


CODE_SIGNAL = re.compile(r"[;{}()=<>]|\b(?:function|revert|require|return|if|mapping|uint\d*|address|bool)\b")


def looks_like_code(s):
    """Guard against the neighbouring-citation trap.

    Findings often list locations back to back —
    `GoodBidAuction.sol:312`, `lib/CostBasis.sol:409` — and a naive
    citation-then-backticks match reads the second *path* as the first one's
    quoted code, then reports it missing from the source. Require something
    that actually looks like Solidity, and never accept a bare file:line.
    """
    t = s.strip()
    if CITE_RE.fullmatch(t) or re.fullmatch(r"[A-Za-z0-9_./-]+\.sol(:\d+(-\d+)?)?", t):
        return False
    return bool(CODE_SIGNAL.search(t))


def inline_claims(md):
    out = []
    for fname, start, end, code in INLINE_RE.findall(md):
        if not looks_like_code(code):
            continue
        cands = candidate_lines([code])
        if cands:
            out.append(((fname, start, end), cands))
    return out


def resolve_citations(md, files):
    """Check each quoted block against the real source at its cited location.

    files maps a repo-relative path to its text. A citation resolves when one
    of the block's substantive lines appears within SLACK lines of the cite.
    Finding it elsewhere in the same file is drift — the defect this exists to
    catch. Not finding it at all is a miss.
    """
    by_base = {}
    for path, text in files.items():
        by_base.setdefault(os.path.basename(path), []).append((path, text.split("\n")))

    claims = []
    for body, ctx in code_blocks(md):
        head = "\n".join(body[:2])
        cites = CITE_RE.findall(ctx) or CITE_RE.findall(head)
        if cites:
            claims.append((cites[0], candidate_lines(body)))
    claims += inline_claims(md)

    resolved, drifted, missed, unverifiable = 0, [], [], 0
    for cite, cands in claims:
        if not cands:
            unverifiable += 1
            continue

        fname, start_s, end_s = cite
        start = int(start_s)
        end = int(end_s) if end_s else start
        targets = by_base.get(os.path.basename(fname))
        if not targets:
            missed.append(f"{fname}:{start} — file not in target source")
            continue

        best_hit = None
        found_anywhere = []
        for path, flines in targets:
            hit = _find_exact(flines, cands, start - SLACK, end + SLACK)
            if hit is None and _token_match(flines, cands, start - SLACK, end + SLACK):
                hit = start
            if hit:
                best_hit = hit
                break
            elsewhere = _find_exact(flines, cands, 1, len(flines))
            if elsewhere:
                found_anywhere.append(elsewhere)

        if best_hit:
            resolved += 1
        elif found_anywhere:
            near = min(found_anywhere, key=lambda x: abs(x - start))
            drifted.append(f"{fname}:{start} — quoted code is at :{near} ({near - start:+d})")
        else:
            missed.append(f"{fname}:{start} — quoted code not found in file")

    return resolved, drifted, missed, unverifiable


def check_citations(md, description, pin):
    kind, value, chain = pin
    files = {}
    note = ""
    warn_prefix = []
    repo = repo_url_from(description) or repo_url_from(md)
    addrs = []
    basis_mismatch = False
    pin_unreachable = False
    if not repo:
        # A commit hash with no repo to resolve it against is dead weight; if
        # the job names on-chain targets, check those instead. But a report
        # that pinned a *commit* was read against a source tree we then have
        # no way to obtain — deployed source may be a different revision, so
        # anything that fails to match is not attributable to the report.
        addrs, ch = onchain_target(description, md)
        if addrs:
            basis_mismatch = kind == "commit"
            kind, value, chain = "address", addrs[0], ch
        elif kind == "address":
            addrs = [value]

    try:
        if repo:
            want = value if kind == "commit" else None
            path, actual, pinned_ok = ensure_repo(repo, want)
            for root, _dirs, names in os.walk(path):
                if ".git" in root:
                    continue
                for n in names:
                    if n.endswith(".sol"):
                        fp = os.path.join(root, n)
                        try:
                            files[os.path.relpath(fp, path)] = open(fp, encoding="utf-8", errors="replace").read()
                        except OSError:
                            pass
            note = repo.split("github.com/")[1] + f"@{actual[:12]}"
            pin_unreachable = not pinned_ok
            if not pinned_ok:
                warn_prefix.append(
                    f"pinned commit {value[:12]} is not in the remote — "
                    f"checked against HEAD {actual[:12]} instead; the audited tree "
                    f"is not reproducible")
        elif kind == "address":
            for a in (addrs or [value]):
                files.update(sourcify_sources(chain, a))
            got = len(addrs or [value])
            note = f"verified-source {chain}/{(addrs or [value])[0][:10]}…"
            if got > 1:
                note += f" (+{got - 1} more)"
            if basis_mismatch:
                warn_prefix.append(
                    "report pins a commit but names no repo — checked against "
                    "the deployed contract's verified source, which may be a "
                    "different revision; misses are not attributable")
    except RuntimeError as e:
        return Check("citations", SKIP, f"source unavailable: {e}")

    if not files:
        why = ("target contract has no verified source on Sourcify or Etherscan"
               ) if kind == "address" else \
              "no target source available to check against"
        return Check("citations", SKIP, why)

    resolved, drifted, missed, unverifiable = resolve_citations(md, files)
    total = resolved + len(drifted) + len(missed)
    if total == 0:
        return Check("citations", SKIP, f"no file:line citations with quoted code ({note})")

    pct = 100 * resolved / total
    detail = warn_prefix + drifted[:8] + missed[:8]
    if unverifiable:
        detail.append(f"({unverifiable} quoted blocks had no citation-bearing context)")
    summary = f"{resolved}/{total} resolved ({pct:.0f}%) · {len(drifted)} drifted, {len(missed)} missing · {note}"
    status = PASS if pct >= 95 else (WARN if pct >= 80 else FAIL)
    if warn_prefix:
        # Measured against the wrong tree: the repo moved on and the audited
        # commit is gone, so drift here says nothing about the report's
        # accuracy. Never let that read as a deliverable defect — the real
        # problem is the unreproducible pin, which `pin` reports.
        status = min(status, WARN, key=lambda s: [PASS, WARN, FAIL].index(s))
        summary += " — not the audited tree; result not attributable"
    chk = Check("citations", status, summary, detail)
    chk.flags["pin_unreachable"] = pin_unreachable
    chk.flags["basis_mismatch"] = basis_mismatch
    return chk


SEV_WORDS = {
    "crit": "Critical", "critical": "Critical",
    "high": "High",
    "med": "Medium", "medium": "Medium",
    "low": "Low",
    "info": "Info", "informational": "Info",
}
SEV_PAIR = re.compile(
    r"(\d+)\s*(critical|crit|high|medium|med|low|informational|info)\b", re.I)


def severity_counts(text):
    """`2 Crit, 6 High, 8 Med` → {Critical: 2, High: 6, Medium: 8}."""
    out = {}
    for n, word in SEV_PAIR.findall(text or ""):
        key = SEV_WORDS[word.lower()]
        out[key] = out.get(key, 0) + int(n)
    return out


def report_tally(md):
    """The report's own `**Severity counts:**` line — the renderer reads this too."""
    m = re.search(
        r"\*\*Severity (?:counts|tally)\b:?\*\*:?\s*([^\n]+)"
        r"|\*\*Severity (?:counts|tally)\b:?\s*([^*\n]+)\*\*", md, re.I)
    if not m:
        return {}
    return severity_counts(m.group(1) or m.group(2) or "")


def work_notes(logs):
    """Progress notes, oldest first. WorkLogged emits the note only — the stage
    label lives in the job struct and only its latest value survives, so
    cadence and content are all the chain can tell us."""
    out = []
    for lg in logs:
        if lg["topics"][0] != EV_WORK:
            continue
        ss = decode_strings(lg["data"])
        if ss:
            out.append(ss[0])
    return out


def check_stages(notes, service_type, last_stage):
    tail = f" · last stage: {last_stage}" if last_stage else ""
    if not notes:
        return Check("stages", FAIL, "no logWork notes — the client saw zero progress")
    if service_type == 4 and len(notes) < 2:
        return Check("stages", WARN,
                     f"only 1 progress note; the audit prompt logs one per phase{tail}", notes)
    return Check("stages", PASS, f"{len(notes)} progress notes{tail}", notes)


def check_count_match(notes, md):
    """The last stage note claims finding counts; the report tallies them.

    A mismatch is usually legitimate — reconciliation downgrades findings after
    the phase-2 note goes out — but it is also exactly how a report that
    silently lost findings would look, so it is worth a human glance.
    """
    tally = report_tally(md)
    if not tally:
        return Check("count-match", FAIL,
                     "report has no '**Severity counts:**' line — its severity strip will render blank")
    claimed = {}
    for n in reversed(notes):
        c = severity_counts(n)
        if c:
            claimed = c
            break
    shown = " · ".join(f"{v} {k}" for k, v in tally.items())
    if not claimed:
        return Check("count-match", PASS, f"report tallies {shown}; no counts claimed in notes")

    diffs = [f"{k}: note said {claimed.get(k, 0)}, report says {tally.get(k, 0)}"
             for k in set(claimed) | set(tally) if claimed.get(k, 0) != tally.get(k, 0)]
    if diffs:
        return Check("count-match", WARN,
                     f"last note's counts differ from the report tally ({shown})", diffs)
    return Check("count-match", PASS, f"note and report agree: {shown}")


def check_escalations(job_id):
    """Any client message must have a worker reply before the job completes."""
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run([os.path.join(here, "messages.sh"), str(job_id)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return Check("escalations", SKIP, "messages endpoint unavailable (needs signed auth)")
    try:
        msgs = json.loads(r.stdout).get("messages", [])
    except json.JSONDecodeError:
        return Check("escalations", SKIP, "messages endpoint returned non-JSON")
    if not msgs:
        return Check("escalations", PASS, "no client messages")

    worker_addr = (os.environ.get("LEFTCLAW_ADDR") or "").lower()
    unanswered = []
    for i, m in enumerate(msgs):
        sender = (m.get("sender") or m.get("from") or "").lower()
        if worker_addr and sender == worker_addr:
            continue
        if not any((later.get("sender") or later.get("from") or "").lower() == worker_addr
                   for later in msgs[i + 1:]):
            unanswered.append((m.get("content") or m.get("text") or "")[:90])
    if unanswered:
        return Check("escalations", FAIL,
                     f"{len(unanswered)} client message(s) never answered", unanswered)
    return Check("escalations", PASS, f"{len(msgs)} message(s), all answered")


# ── driver ───────────────────────────────────────────────────────────────


def run_job(job_id):
    logs = job_logs(job_id)
    if not logs:
        return {"id": job_id, "error": "no on-chain events for this job"}

    service_type = None
    description = ""
    for lg in logs:
        if lg["topics"][0] == EV_POSTED:
            b = bytes.fromhex(lg["data"][2:])
            if len(b) >= 32:
                service_type = int.from_bytes(b[:32], "big")
    worker = None
    for lg in logs:
        if lg["topics"][0] in (EV_ACCEPTED, EV_COMPLETED) and len(lg["topics"]) > 2:
            worker = "0x" + lg["topics"][2][-40:]

    # get-job.sh picks the description by "longest printable run", which
    # truncates and reorders. Decode the raw tuple instead so URLs buried in a
    # long brief still surface.
    last_stage = None
    gj = subprocess.run(
        ["cast", "call", CONTRACT, "getJob(uint256)", str(job_id), "--rpc-url", rpc_url()],
        capture_output=True, text=True)
    if gj.returncode == 0 and gj.stdout.strip():
        strings = decode_strings(gj.stdout.strip())
        description = "\n".join(strings)
        # Trailing short string is the most recent logWork stage label.
        for s in reversed(strings):
            if len(s) < 64 and not s.startswith("http"):
                last_stage = s
                break

    notes = work_notes(logs)
    checks = []
    c_result, md = check_result(logs)
    checks.append(c_result)
    if md:
        c_pin, pin = check_pin(md, description)
        c_cite = check_citations(md, description, pin)
        if c_cite.flags.get("pin_unreachable"):
            # The pin parsed fine but the remote no longer serves it, so the
            # audited tree can't be recovered. That is a pin defect, not a
            # citation defect — record it where a reader will act on it.
            c_pin = Check("pin", FAIL,
                          f"{c_pin.summary} — not reachable in the remote; "
                          f"the audited tree cannot be reproduced")
        elif c_cite.flags.get("basis_mismatch"):
            # A commit with no repo named anywhere resolves to nothing; the
            # target was on-chain. Weaker than a broken pin, but it still
            # leaves the reader unable to fetch what was audited.
            c_pin = Check("pin", WARN,
                          f"{c_pin.summary} — but the report names no repo, so "
                          f"the commit cannot be resolved; target was on-chain")
        checks.append(c_pin)
        checks.append(c_cite)
    checks.append(check_stages(notes, service_type, last_stage))
    if md:
        checks.append(check_count_match(notes, md))
    checks.append(check_escalations(job_id))

    return {
        "id": job_id,
        "serviceType": service_type,
        "worker": worker,
        "checks": [c.as_dict() for c in checks],
        "fails": sum(1 for c in checks if c.status == FAIL),
        "warns": sum(1 for c in checks if c.status == WARN),
    }


COLOR = {PASS: "\033[32m", WARN: "\033[33m", FAIL: "\033[31m", SKIP: "\033[90m"}


def render(rep, tty):
    def paint(s):
        return f"{COLOR[s]}{s:4}\033[0m" if tty else f"{s:4}"

    if rep.get("error"):
        print(f"job {rep['id']}: {rep['error']}")
        return
    w = rep.get("worker") or "?"
    print(f"\njob {rep['id']} · type {rep.get('serviceType')} · worker {w[:12]}…")
    for c in rep["checks"]:
        print(f"  [{paint(c['status'])}] {c['check']:<14} {c['summary']}")
        for d in c["detail"][:8]:
            print(f"                        · {d}")
    verdict = "CLEAN" if rep["fails"] == 0 and rep["warns"] == 0 else (
        "WARN" if rep["fails"] == 0 else "FAIL")
    print(f"  → {verdict} ({rep['fails']} fail, {rep['warns']} warn)")


def main():
    args = [a for a in sys.argv[1:]]
    as_json = "--json" in args
    args = [a for a in args if not a.startswith("--")]
    if not args:
        sys.exit("usage: mech_check.py <job_id> [job_id...] [--json]")

    reports, worst = [], 0
    for jid in args:
        try:
            rep = run_job(int(jid))
        except (RuntimeError, ValueError) as e:
            rep = {"id": jid, "error": str(e)}
        reports.append(rep)
        if rep.get("error") or rep.get("fails"):
            worst = 1
        if not as_json:
            render(rep, sys.stdout.isatty())

    if as_json:
        for r in reports:
            print(json.dumps(r))
    sys.exit(worst)


if __name__ == "__main__":
    main()
