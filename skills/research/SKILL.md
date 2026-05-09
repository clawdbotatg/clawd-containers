---
name: research-report
description: Research methodology for leftclaw.services Service Type 7 jobs. Produce a structured, source-cited report on a crypto/Ethereum/protocol topic given a description, optional context, and (often) a set of starting URLs.
---

# Research Report — Methodology

You are producing a deep-dive research report. The deliverable is a single
markdown document, structured as below, with every non-trivial claim
cited inline. Default depth: 1500–4000 words depending on topic
breadth. Don't pad — fewer words with sharper analysis beats length.

## Inputs (from job description + messages)

- **Topic** — the subject of the report (always present; ≥10 chars)
- **Context** — optional client guidance about scope, audience, what
  they already know
- **Starting URLs** — sometimes embedded in the description or
  provided via a job message; read them first as primary sources

## Pre-research checklist

1. Re-read the description and any messages. Extract:
   - The exact question/decision the client is trying to answer (if
     any). If implicit, write it out for yourself.
   - Hard constraints (chain, protocol family, time window, etc).
   - Provided starting URLs.
2. Plan: list 5–10 specific questions the report must answer to be
   useful. Don't skip this — it disciplines the research.
3. Decide which primary-source categories you need: protocol docs,
   contract code, governance forums, on-chain data, academic papers,
   incident postmortems, audit reports, etc.

## Research workflow

- **Start with provided URLs.** Read them in full. They are the
  highest-priority primary sources.
- **Triangulate.** For any non-trivial claim, find at least one
  independent source. Single-source assertions are flagged as such.
- **Use on-chain data when relevant.** `cast call`, `cast logs`, and
  the leftclaw RPC (Base + Alchemy) are available. For TVL, holder
  counts, governance votes, etc., quote the on-chain value with the
  block number you read it at.
- **Use `WebFetch` and `WebSearch`** for browsing — the Chrome
  integration is intentionally disabled in research VMs (it routes
  account-scoped and can hijack the operator's host Chrome). For
  dashboards and forums that require JS rendering, fall back to a
  static archive (web.archive.org) or note the limitation in Risks
  and Caveats.
- **Distinguish primary vs secondary.** A protocol's docs/whitepaper +
  its deployed contract are primary. A blog post or thread describing
  them is secondary. Prefer primary; cite secondary only when primary
  isn't accessible.
- **Distrust press-release framing.** Quotes from project teams and
  marketing copy are claims, not evidence. Treat them as such.

## Report structure (REQUIRED)

```markdown
# Research Report — <Topic>

**Job ID:** <N>
**Date:** YYYY-MM-DD
**Researcher:** clawd auto-research-agent
**Block height of on-chain reads:** <if applicable>

## Executive Summary

3–6 sentences. The reader who only reads this paragraph should leave
with the answer to the client's question. State the question, give the
answer, and name the 2–3 most consequential findings.

## Question Being Answered

Restate the client's question in your own words. If multiple
interpretations are possible, say which one this report addresses
and why.

## Key Findings

3–7 bullet points. Each one a single declarative sentence with at
least one inline citation. Order by importance, not order discovered.

- Finding A. [^1]
- Finding B. [^2]
- ...

## Background

Just enough context for a reader unfamiliar with the topic. Skip if
the audience is implied to be expert (per Context).

## Detailed Analysis

The substantive body. Use H3 sections for each major sub-question. In
each section: state the sub-question, present evidence, draw a
conclusion. Cite as you go. Use tables for comparative data and
on-chain figures.

## Risks and Caveats

What this report does NOT cover, what could change the conclusions,
what's based on a single source or unverified claim. Be candid.

## Recommendations / Decision Implications

Only if the client's question implies a decision. Frame as
conditional: "If A then X; if B then Y."

## Sources

Numbered footnote references in the order cited. Each entry:

[^1]: Title. Author/Org. URL. Accessed YYYY-MM-DD. Type: primary/secondary.

## Appendix

Optional. On-chain queries with block numbers, raw tables, anything
the analysis references but doesn't need to live in the body.
```

## Citation rules

- Every numeric claim, every protocol design assertion, every
  competitive comparison: cited.
- Use markdown footnote syntax `[^1]` … `[^1]:` so the report renders
  cleanly on GitHub or any markdown viewer.
- For on-chain values: include contract address, function name, and
  block number in the citation.
- Do NOT cite the leftclaw skill files or this SKILL.md.

## Verification standard

- Before claiming a contract has property X, read the contract.
- Before claiming TVL is $N, read it from the protocol's frontend AND
  cross-check against an on-chain read or DefiLlama.
- Before claiming a governance proposal passed/failed, read the vote
  record on-chain (Snapshot off-chain, Compound/Tally on-chain).

## Output

Save to `~/research/<job_id>/report.md`. The file you upload to BGIPFS
must be that exact file — don't rewrite at upload time.

## What this skill is NOT

- Not a tutorial or guide. The reader is competent; explain what they
  need to act, not the basics.
- Not a press release for the protocol being researched. Be neutral.
- Not exhaustive. 1500–4000 words means choosing what matters.
