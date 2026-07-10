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

## Layer 1 — mechanical checks (scriptable, no model)

Run per completed job, exit codes feed the scorecard:

- `resultURL` fetches, non-trivial size, parses as markdown.
- Report pins a commit hash (audits of repos) or contract address+chain
  (on-chain targets).
- **Line-reference resolution**: extract `file.sol:N` citations + quoted
  snippets, clone the target at the pinned commit, verify each snippet
  appears within ±5 lines of the cited location. Score = % resolved.
  (This is the check job 372 fails today.)
- Stage notes present for every stage the service type defines; finding
  counts in stage notes match the report's summary table.
- Every escalation in the message thread got a response before complete.

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
