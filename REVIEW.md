# REVIEW.md — the second pass over the assembly line

The fleet ships deliverables with nobody looking at them afterward. The
2026-07-10 sweep of jobs 273–372 found the *line* mostly works (97/100
complete) but exposed two blind spots:

1. **Process failures are silent.** Job 326 sat IN_PROGRESS for 2 days
   because the wrangler was disabled in launchd and nothing noticed. The
   stage note said "pass 2 complete" while the VM that held the work was
   already wiped.
2. **Deliverable defects are invisible.** Job 372's audit report is
   well-structured and substantive — but its cited line numbers don't
   resolve against the target repo (quoted code exists at :1679, report
   says :1221–1223) and no commit hash is pinned. No client complained;
   nobody knew.

A second pass exists to catch both kinds. Design principle: **cheap
mechanical checks first, judge-model review second, human taste last** —
each layer only sees what the previous one couldn't decide.

## What a reviewer has to work with (today, no changes)

| Source | What it gives |
|---|---|
| contract (`getJob`, `getJobsByStatus`) | status, worker, stage string, timestamps, payment |
| stage notes (`logWork` history) | claimed progress ("Found N high, M medium…") |
| `GET /api/job/{id}/messages` | escalations, client messages, rollbacks |
| `resultURL` on IPFS | the final deliverable |
| `/tmp/agent-wrangler.log` | boots, recycles, cap strikes, declines per job |

**What is lost:** everything under `~/audits/<job_id>/` in the VM
(phase-1/phase-2 raw outputs, reconciliation notes) and the claude
transcripts — wiped on every recycle. Layer 0 fixes that.

## Layer 0 — harvest (make the line inspectable)

Before `cont down` in the wrangler's `stop_vm`, tar the VM's `~/audits`
and `~/.claude/projects` to `archive/<job_id>/` on the host (best-effort,
`|| true` — a failed harvest must never block a stop). Until this lands,
the review pass can only see the deliverable, not the work.

## Layer 1 — mechanical checks (scriptable, no model) — **landed**

`./scripts/leftclaw/mech-check.sh <job_id>...` (also `--queue`, `--json`).
Exit 1 if any check FAILs, so it can gate a scorecard run. Works on any
worker's jobs, so it also benchmarks the competition.

- `resultURL` fetches, non-trivial size, parses as markdown.
- Report pins a commit hash (audits of repos) or contract address+chain
  (on-chain targets) — **and the pin is reachable**. Job 565 pinned
  `96b2c2a4…`, which the remote answers with `upload-pack: not our ref`:
  the audited tree cannot be recovered by anyone, including us.
- **Line-reference resolution**: extract `file.sol:N` citations + quoted
  snippets, clone the target at the pinned commit, verify each snippet
  appears within ±5 lines of the cited location. Score = % resolved.
  (This is the check job 372 fails today.)
- Finding counts claimed in the last stage note match the report's own
  `**Severity counts:**` line — and that line exists at all, since the
  published-page renderer reads it to build the severity strip.
- Every escalation in the message thread got a response before complete.

The rule that shapes the whole design: **never score a report against a tree
it did not read.** When the pin is unreachable, or a commit is pinned with no
repo named, the check still runs but caps at WARN and labels the number "not
attributable" — the pin problem is recorded against `pin`, where it belongs.

Source resolution: repos are cloned at the pin; on-chain targets try Sourcify,
then Etherscan multichain V2. Sourcify does not mirror most Base Sepolia
contracts even when BaseScan has them verified, so Etherscan carries that case.
No key is required — it defaults to scaffold-eth-2's shared public key, the
same pattern SE-2 uses in `hardhat.config.ts`. Set `ETHERSCAN_API_KEY` for
sustained use.

Baseline over our own completed jobs, 2026-08-06:

| Job | Verdict | Notable |
|---|---|---|
| 565 | FAIL | pinned commit not in the remote; no severity-counts line (predates the prompt fix) |
| 568 | WARN | commit pin unresolvable (no repo named); citations 13/16 vs deployed source |
| 570 | WARN | 3/3 citations resolve; last note claimed 2 Critical, report tallies 0 |
| 573 | WARN | 4/4 citations resolve; commit pin unresolvable |

**Every FAIL this tool reported on its first pass at a report was its own bug.**
Five distinct false-positive classes, each caught only by checking a flagged
citation against the actual source before believing it:

| Symptom | Cause |
|---|---|
| "quoted code not found" everywhere | reports annotate quotes with `// line 183` |
| ditto, on remediation blocks | ```diff fixes quote code that deliberately doesn't exist yet |
| ditto, on adjacent citations | a neighbouring `path.sol:N` read as the first one's quoted code |
| `n-1` vs `n - 1` | whitespace collapsed to single spaces instead of removed |
| multi-line `if (...)` | matcher compared single source lines only |

The lesson generalises past this tool: **a checker that reports a defect it
cannot substantiate is worse than no checker**, because it teaches the reader
to ignore it. Verify a sample of every new check's hits by hand before trusting
the aggregate.

## Layer 2 — judge review (model, rubric-driven)

A host-side `claude -p` run (read-only — no VM, no keys beyond fetch)
grades what mechanics can't:

- **Severity calibration**: does each High walk a concrete exploit path,
  per the prompt's own verification standard? Downgrades hedged Highs.
- **Fabrication smell**: agent/phase origin tags consistent; findings
  that quote code the target doesn't contain; confident claims about
  unverifiable behavior (e.g. out-of-scope hook internals).
- **Scope match**: report covers what the job description asked
  ("Focus on: reentrancy, first-depositor inflation…" → did it?).
- **Padding ratio**: informational items that restate compiler warnings
  or repeat each other.

Output: `review/<job_id>.md` scorecard + one row appended to
`review/SCORECARD.md` (job, type, wall-time, recycles, mech-score,
judge-score, top defect). LeftClaw already has a Judge/Oracle service
type (8) — once the rubric is stable this layer can be dogfooded as
type-8 jobs the fleet runs on its own output.

## Layer 3 — the improvement loop (human)

Weekly: read the scorecard deltas, pick the top recurring defect, fix it
at the *source* — prompt, skill file, or wrangler — not in the review
layer. Each fix should name the jobs that motivated it (the way the
wrangler's own commit history does: "job 344 hit this").

First three candidates, from the pilot:

1. ~~Reports don't pin commits / line refs drift~~ — fixed in
   `auditor.prompt.md` the same day this doc landed (verification
   standard now requires a pinned commit + resolvable citations).
2. Wrangler death is silent — a heartbeat (`notify` if no tick logged
   for >10 min, or a `launchctl print` check from the auth-refresh
   daemon) would have caught the 2-day outage in minutes.
3. Harvest (Layer 0) — without it, "how did it do" reviews can only
   grade the final artifact, never the reasoning that produced it.

## Running the queue

```bash
./scripts/leftclaw/review-queue.sh          # completed jobs since watermark, JSON lines
./scripts/leftclaw/review-queue.sh 340      # …since an explicit job id
./scripts/leftclaw/review-queue.sh --mark 372   # advance the watermark
```

Each line is `{id, serviceTypeId, resultURL, description}` — enough for
a human to spot-check one, or for a judge agent to work the whole batch.
