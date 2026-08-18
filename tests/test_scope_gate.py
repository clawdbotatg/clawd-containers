#!/usr/bin/env python3
"""Regression suite for the Solidity scope gate, scripts/audit/complexity-check.sh.

Run: python3 tests/test_scope_gate.py    (exit 0 = pass; NO network, NO clone)

Why this exists
---------------
The gate decides whether to `declineJob`, which REFUNDS a paying client, and it
does that unattended in about 30 seconds. On 2026-08-17 it counted a single
linked 87-line contract as its entire 55-file repo (11,028 LoC), blew the 3,000
budget, and refunded five jobs from one client — 633, 634, 635, 641, 643. See
SCOPE-GATE.md.

Nothing caught that. The only check was running the gate against ~22 live job
ids, which needs the internet, an Alchemy key, and other people's GitHub repos
to still exist — and those rot: two of those jobs already report different
numbers than when first measured, and one repo has been deleted. This suite is
the part that does not rot.

It exercises the REAL code, not a copy: the embedded Python program is extracted
out of the shell script and run as-is. Fixtures are tiny on purpose so the
expected line counts can be checked by hand.

Both directions matter. It is trivial to stop over-counting by dropping every
section that looks like a library — and that would silently let a genuinely
oversized job through, which is the failure that locks escrow forever. So the
"must still be counted" cases are as load-bearing as the "must be dropped" ones.
"""

import http.server
import json
import os
import re
import subprocess
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
GATE = os.path.join(ROOT, "scripts", "audit", "complexity-check.sh")
FIXTURES = os.path.join(HERE, "fixtures", "scope_gate")

# The gate is a shell wrapper around one embedded Python program. We pull that
# program out and run it directly, so these tests cover the shipped code with no
# duplication and no changes to it.
BEGIN = 'python3 - "$JOB_JSON"'
END = "\nPY\n"
# Discovery (which targets did it find?) happens before any fetching. Slicing
# there lets us assert on target discovery with zero network.
SLICE_MARKER = "# ── section-aware LoC counter"

FAILED = []


def check(name, got, want):
    if got == want:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}\n         got:  {got!r}\n         want: {want!r}")
        FAILED.append(name)


def embedded_python():
    src = open(GATE).read()
    i = src.index(BEGIN)
    i = src.index("\n", src.index("<<'PY'", i)) + 1
    j = src.index(END, i)
    return src[i:j]


def discovery_source():
    """The part of the program that finds targets, up to the LoC counter."""
    src = embedded_python()
    if SLICE_MARKER not in src:
        raise SystemExit(
            f"test_scope_gate.py: marker {SLICE_MARKER!r} is gone from "
            f"{GATE}.\nTarget discovery moved. Update SLICE_MARKER — do not "
            f"delete these tests."
        )
    return src[: src.index(SLICE_MARKER)]


def discover(desc):
    """Run the real discovery code against a description; return what it found."""
    ns = {"__name__": "__gate__"}
    argv = sys.argv
    sys.argv = ["gate", json.dumps({"description": desc})]
    try:
        exec(compile(discovery_source(), "<gate-discovery>", "exec"), ns)
    finally:
        sys.argv = argv
    return {
        "addrs": ns.get("addrs", []),
        "repos": ns.get("repos", []),
        "blob_urls": ns.get("blob_urls", []),
        "direct_urls": ns.get("direct_urls", []),
        "direct_cids": ns.get("direct_cids", []),
    }


def run_gate(desc, max_loc=3000):
    """Run the whole real program. Returns (verdict, targets, loc)."""
    env = dict(
        os.environ,
        MAX_AUDIT_SOL_LOC=str(max_loc),
        BYTES_PER_LOC="20",
        ALCHEMY_API_KEY="",       # no address probing: fixtures carry no addresses
    )
    out = subprocess.run(
        [sys.executable, "-c", embedded_python(), json.dumps({"description": desc})],
        capture_output=True, text=True, env=env, timeout=120,
    ).stdout
    got = dict(re.findall(r"^(VERDICT|TARGETS|LOC): (.*)$", out, re.M))
    return got.get("VERDICT"), int(got.get("TARGETS", -1)), int(got.get("LOC", -1))


class Server(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=FIXTURES, **kw)

    def log_message(self, *a):
        pass


def serve():
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Server)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}"


# ── 1. target discovery — the bug that cost five refunds ────────────────────
BLOB = ("https://github.com/Deepyield-labs/deepyield-vault-audit/blob/"
        "bb9ffbf822c58f3b74d96351c9b1f4541be4e3bd/audit2/batches/"
        "01-capital-and-redemptions/flat/FixedFeeSink.audit2.flat.sol")


def test_discovery():
    print("target discovery")

    # THE regression. A blob URL names ONE FILE at ONE REF. Counting its repo
    # instead is what produced 11,028 LoC for an 87-line contract.
    d = discover(f"External link:\n  {BLOB}\n\nAudit only the linked file.")
    check("blob URL is one file", len(d["blob_urls"]), 1)
    check("blob URL is NOT a repo target", d["repos"], [])
    check("blob resolves to raw.githubusercontent.com",
          d["blob_urls"][0],
          "https://raw.githubusercontent.com/Deepyield-labs/deepyield-vault-audit/"
          "bb9ffbf822c58f3b74d96351c9b1f4541be4e3bd/audit2/batches/"
          "01-capital-and-redemptions/flat/FixedFeeSink.audit2.flat.sol")

    # A bare repo link still means the whole repo — do not over-correct.
    d = discover("Audit the contracts in https://github.com/acme/vault")
    check("bare repo URL is still a repo", len(d["repos"]), 1)
    check("bare repo URL is not a blob", d["blob_urls"], [])

    # An address plus its source repo would double count (jobs 422/430).
    d = discover("Audit 0x1111111111111111111111111111111111111111 — "
                 "source at https://github.com/acme/vault")
    check("address wins over its repo (addrs)", len(d["addrs"]), 1)
    check("address wins over its repo (repos)", d["repos"], [])

    # Job 427 ships source out of band and marks GitHub as an anti-target.
    d = discover("Do not use the GitHub repo https://github.com/acme/vault")
    check("'do not use github' drops the repo", d["repos"], [])

    # A negation window around a blob link makes it context, not scope.
    d = discover(f"Ignore the legacy file {BLOB} — it is superseded.")
    check("negated blob URL is not a target", d["blob_urls"], [])

    # Direct source forms (jobs 629/647/616 and 672).
    d = discover("Source: https://example.com/src/Vault.sol")
    check("raw .sol URL is a direct target", len(d["direct_urls"]), 1)
    d = discover("Source pinned at QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG")
    check("IPFS CID is a direct target", len(d["direct_cids"]), 1)


# ── 2. line counting — what the budget is actually spent on ─────────────────
# Fixtures are tiny so these numbers are hand-checkable. See
# tests/fixtures/scope_gate/. Each number is "non-blank lines of the sections
# that are really the client's code".
EXPECT_FLAT = 11          # preamble 2 + IFeeSink 3 + FixedFeeSink 6; OZ dropped
EXPECT_NAMED_LIKE_LIB = 8  # preamble 2 + contract Math 6; OZ SafeCast dropped
EXPECT_DEDUPED = 10        # IShared 3 counted ONCE + Alpha 3 + Beta 3 + preamble 1
EXPECT_HEADER = 6          # preamble 2 + RealTarget 4; header-attributed dropped


def test_counting():
    print("line counting")
    httpd, base = serve()
    try:
        # Vendored OpenZeppelin must not be billed to the client's budget.
        v, t, loc = run_gate(f"Audit only {base}/flat_with_oz.sol")
        check("flat file: verdict", v, "ok")
        check("flat file: one target", t, 1)
        check("flat file: OZ dropped, project counted", loc, EXPECT_FLAT)

        # The dangerous half of that rule: a PROJECT contract named like a
        # library, sitting last (where a flattener puts the target), must be
        # counted. Dropping it would under-count real scope.
        v, t, loc = run_gate(f"Audit only {base}/project_named_like_lib.sol")
        check("project contract named 'Math' is still counted",
              loc, EXPECT_NAMED_LIKE_LIB)

        # Flattened files that embed the same section (job 440 shipped five).
        v, t, loc = run_gate(
            f"Audit {base}/dupe_one.sol and {base}/dupe_two.sol")
        check("two files, shared section counted once (targets)", t, 2)
        check("two files, shared section counted once (loc)",
              loc, EXPECT_DEDUPED)

        # Attribution by header comment, for a name no list will ever contain.
        v, t, loc = run_gate(f"Audit only {base}/header_attributed.sol")
        check("header-comment attribution drops the library", loc, EXPECT_HEADER)

        # The verdict boundary itself: same file, budget below its size.
        v, t, loc = run_gate(f"Audit only {base}/flat_with_oz.sol",
                             max_loc=EXPECT_FLAT - 1)
        check("over budget -> too_complex", v, "too_complex")
        v, t, loc = run_gate(f"Audit only {base}/flat_with_oz.sol",
                             max_loc=EXPECT_FLAT)
        check("exactly at budget -> ok", v, "ok")

        # Fail open: an unreachable target must never refuse a paying client.
        v, t, loc = run_gate("Audit only http://127.0.0.1:1/nope.sol")
        check("unreachable target fails open (verdict)", v, "ok")
        check("unreachable target counts zero", loc, 0)
    finally:
        httpd.shutdown()


if __name__ == "__main__":
    test_discovery()
    test_counting()
    if FAILED:
        print(f"\n{len(FAILED)} FAILED: {', '.join(FAILED)}")
        sys.exit(1)
    print("\nall scope-gate tests passed")
