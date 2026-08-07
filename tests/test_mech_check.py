#!/usr/bin/env python3
"""Regression suite for the citation resolver in scripts/leftclaw/mech_check.py.

Run: python3 tests/test_mech_check.py   (exit 0 = pass; no network, no clone)

Every case here is a false positive the checker actually produced against a
real audit report before it was fixed. The resolver's whole value is that a
FAIL means something — the moment it starts crying wolf, the reader learns to
ignore it and the tool is worse than nothing. So the negative cases (drift and
fabrication must still be caught) matter exactly as much as the positive ones:
it would be trivial to silence every false positive by making the matcher
permissive enough to accept anything.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "scripts", "leftclaw"))
import mech_check as M  # noqa: E402

SOURCE = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract Sample {
    error ShortTransfer();
    error BadPauseStart();

    uint256 public escrowedFees;
    PauseWindow[] private _pauseWindows;

    function _pauseAt(uint64 startAt) private {
        if (startAt > block.timestamp) {
            revert BadPauseStart();
        }
        uint256 n = _pauseWindows.length;
        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();
        _pauseWindows.push(PauseWindow({start: startAt, end: 0}));
    }

    function settle(uint256 lotId, uint64 end) external {
        if (
            CostBasis.sequencerUpFor(sequencerUptimeFeed) <= SEQ_SETTLE_GRACE
                && block.timestamp < end + SEQ_SETTLE_BACKSTOP
        ) revert SequencerDown();
        lots[lotId].settled = true;
    }
}
"""
FILES = {"src/Sample.sol": SOURCE}
LINES = SOURCE.split("\n")

# Ground truth, 1-indexed, verified by reading SOURCE above.
CLAMP_LINE = LINES.index("        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();") + 1
SETTLE_IF = LINES.index("        if (") + 1


def block(cite, body, lang="solidity", lead=""):
    return f"# R\n{lead}**Files:** `Sample.sol:{cite}`\n\n```{lang}\n{body}\n```\n"


CASES = [
    # (name, markdown, expected outcome)
    ("exact quote",
     block(CLAMP_LINE, "        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();"),
     "resolved"),

    # Reports annotate quoted code with trailing line markers.
    ("annotated with // line N",
     block(CLAMP_LINE, "        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();  // line 16"),
     "resolved"),

    # `n-1` in the report vs `n - 1` in the file is the same code.
    ("operator spacing differs",
     block(CLAMP_LINE, "        if (n>0 && startAt<_pauseWindows[n-1].end) revert BadPauseStart();"),
     "resolved"),

    ("within the ±5 slack",
     block(CLAMP_LINE + 4, "        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();"),
     "resolved"),

    # A flattened multi-line statement must still match its source.
    ("multi-line if flattened into one",
     block(SETTLE_IF,
           "        CostBasis.sequencerUpFor(sequencerUptimeFeed) <= SEQ_SETTLE_GRACE && block.timestamp < end + SEQ_SETTLE_BACKSTOP"),
     "resolved"),

    # Faithful paraphrase: an argument shortened for readability.
    ("identifier abbreviated in the quote",
     block(SETTLE_IF,
           "        CostBasis.sequencerUpFor(feed) <= SEQ_SETTLE_GRACE && block.timestamp < end + SEQ_SETTLE_BACKSTOP"),
     "resolved"),

    # --- these must still be caught; a permissive matcher fails here ---
    ("real drift, cited 40 lines off",
     block(CLAMP_LINE + 40, "        if (n > 0 && startAt < _pauseWindows[n - 1].end) revert BadPauseStart();"),
     "drifted"),

    ("fabricated quote",
     block(CLAMP_LINE, "        uint256 thisLineIsNotInTheFile = 12345;"),
     "missed"),

    # --- these are not citation claims at all and must not be scored ---
    ("remediation diff",
     block(CLAMP_LINE, "+        uint64 lotCreatedAt;\n-        uint64 old;", lang="diff"),
     "none"),

    ("fix block under a **Fix** heading",
     block(CLAMP_LINE, "        uint256 somethingBrandNewEntirely = 1;", lead="**Fix**\n"),
     "none"),

    ("neighbouring citation, not a quote",
     "# R\nSee `Sample.sol:10`, `lib/CostBasis.sol:409` for the call sites.\n",
     "none"),
]


def outcome(md):
    resolved, drifted, missed, _unver = M.resolve_citations(md, FILES)
    if resolved:
        return "resolved"
    if drifted:
        return "drifted"
    if missed:
        return "missed"
    return "none"


def unit_checks():
    """Pin the pieces the end-to-end cases can't distinguish.

    Every CASE above still passes with norm() reverted to collapsing whitespace
    instead of removing it, because the token-overlap fallback rescues the
    respaced quote. That makes the end-to-end suite blind to a real regression,
    so assert the exact matcher and the token matcher separately.
    """
    out = []

    out.append(("norm() removes whitespace, not just collapses",
                M.norm("startAt < _pauseWindows[n - 1].end")
                == M.norm("startAt<_pauseWindows[n-1].end")))

    # Exact matcher alone (no token fallback) must handle operator respacing...
    respaced = ["if (n>0 && startAt<_pauseWindows[n-1].end) revert BadPauseStart();"]
    out.append(("_find_exact matches across operator spacing",
                M._find_exact(LINES, respaced, CLAMP_LINE - 5, CLAMP_LINE + 5) == CLAMP_LINE))

    # ...and a statement flattened from several source lines.
    flat = ["CostBasis.sequencerUpFor(sequencerUptimeFeed) <= SEQ_SETTLE_GRACE "
            "&& block.timestamp < end + SEQ_SETTLE_BACKSTOP"]
    out.append(("_find_exact spans multiple source lines",
                M._find_exact(LINES, flat, SETTLE_IF - 5, SETTLE_IF + 5) is not None))

    # The token fallback must not be a blanket pass: unrelated code in range
    # has to stay unmatched, or drift detection is meaningless.
    out.append(("_token_match rejects unrelated code",
                not M._token_match(LINES, ["uint256 totallyUnrelatedSymbolHere = 9;"],
                                   CLAMP_LINE - 5, CLAMP_LINE + 5)))
    return out


def main():
    failures = 0
    for name, ok in unit_checks():
        failures += not ok
        print(f"  {'ok ' if ok else 'FAIL'} {name}")
    print()
    for name, md, want in CASES:
        got = outcome(md)
        ok = got == want
        failures += not ok
        print(f"  {'ok ' if ok else 'FAIL'} {name:38} want={want:8} got={got}")

    # Inline `File.sol:N`: `code` claims are checked too.
    inline = ("The guard (`Sample.sol:%d`: `if (n > 0 && startAt < "
              "_pauseWindows[n - 1].end) revert BadPauseStart();`) holds." % CLAMP_LINE)
    got = outcome(inline)
    ok = got == "resolved"
    failures += not ok
    print(f"  {'ok ' if ok else 'FAIL'} {'inline citation with quote':38} want=resolved got={got}")

    print(f"\n{'ALL PASS' if not failures else f'{failures} FAILURE(S)'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
