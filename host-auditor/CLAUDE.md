# host-auditor — runbook

A **host-native, resumable** smart-contract auditor for leftclaw. It does the
same two-phase audit the container auditor does, but runs **raw on this Mac** —
no VM, no time cap — so it can chew on a job for 5 hours and be stopped and
resumed without losing work. Every job's research lives in `jobs/<job_id>/`.

It exists because the container is both the time boundary and the safety
boundary, and both are wrong for big jobs: job 326 (`fwa-relaunch`, 3,788 LoC)
kept time-capping and recycling under the VM's 2h cap and never finished. This
auditor removes the cap — and replaces the VM's isolation with a **safety
pre-flight + a sandbox jail**, because running untrusted repos on the bare host
is otherwise how you leak keys.

## When the user says "host-audit job N" (or a big audit is stuck)

```bash
cd ~/clawd/clawd-harness/projects/clawd-containers

host-auditor/audit.sh N                 # 1. PLAN — prints the phases, no side effects
host-auditor/audit.sh N --go            # 2. RUN — all phases to on-chain completion
host-auditor/check-job.sh N             # 3. VERIFY — independent, every surface ✅
```

It stops and resumes on its own. If a run is interrupted (or parks), it prints
the exact resume line, e.g. `host-auditor/audit.sh N --go --from audit`.
Re-running is always safe — every phase re-checks the real surface first.

Useful variants:
- `--from <phase>` resume from a phase · `--only <phase>` run just one
- `--no-complete` do everything except the on-chain `completeJob` (report-only)
- Phases: `intake sanitize safety accept audit report publish complete`
- Per-job artifacts: `jobs/N/{job.json, safety/verdict.json, repo/, audit/*-report.md, report/final-report.md, state.json, run.log}`

## Hard rules (each earned the hard way — do not "optimize" them away)

1. **The audit phase runs jailed and keyless. Never source `.env.auditor` into
   it.** The clone + all `claude` reasoning run under `sandbox-exec`
   (`lib/sandbox.sh`) with the wallet secrets **kernel-denied** and no wallet var
   in scope. *Why:* `~/clawd/clawd-md/.env.clawd` is world-readable (6 wallets +
   private keys + seed phrases). A prompt-injected audit agent that could read it
   could drain everything. The jail means even a fully hijacked agent physically
   cannot read the secret to send it. The invariant: **untrusted-code context and
   key-holding context never overlap.**

2. **Never run the target's own build/tests.** No `forge build`, `forge test`,
   `npm install`, `make`, or executing anything the repo ships. This is a
   *static* audit. *Why:* that's the whole reason it's safe to run on the bare
   host — untrusted code never executes, so the attack surface is just "clone +
   read files." The clone is hooks-off (`core.hooksPath=/dev/null`) so not even a
   git hook fires.

3. **Safety NO-GO parks the job; it never auto-declines and never auto-runs.**
   A no-go writes `safety/verdict.json` with evidence and alerts Telegram. A human
   looks. *Why:* the collectors are dumb greps that can't tell an exploit-in-a-
   comment from an audit note; the judge adjudicates, but a machine should not
   silently decline a paying client or silently run something that smells wrong.

4. **`complete` is gated on safety=go AND ≥80% of citations resolving.** *Why:*
   job 372 shipped a good report whose `File.sol:N` citations pointed at the wrong
   lines (sub-agents number chunked views) — it reads as fabrication. The report
   phase re-resolves each `File.sol:N` reference at the pinned commit, then
   rejects any report whose resolution rate is under 80%. Correct the line
   numbers rather than relaxing that bar.

5. **`env -i` breaks claude's login — use the `KEYLESS` strip instead.** Stripping
   the whole environment made claude report "Not logged in" and mis-fire a safety
   NO-GO on a clean repo. `KEYLESS=(env -u PRIVATE_KEY -u BGIPFS_KEY)` removes the
   write-capable secrets while keeping the `USER`/keychain context claude needs.

6. **`check-job.sh` shares no code with the writers — keep it that way.** It
   re-derives every surface independently (its own on-chain read, its own citation
   resolver, its own IPFS fetch). *Why:* a writer's "completed: true" has been
   wrong before across this fleet; only an independent check catches a silent
   failure.

## Relationship to the fleet

Coexists with the container auditor (`agent-wrangler.sh`), which keeps routine
type-4 jobs. This host auditor is invoked **by hand** for big/complex jobs. It
shares the same worker wallet and the same reusable pieces — `../scripts/leftclaw`,
`../scripts/bgipfs`, `../skills` (the live v1 two-phase methodology, not the
staged v2). Wrangler auto-delegation of big jobs is a future step, deliberately
gated behind a human until this is proven.

## Not yet built (v1 scope)

- Dynamic PoC execution of the target under sandbox (v1 is static-only).
- Address-target audits (fetch verified source instead of a git clone) — the
  scaffolding is there (`phase_safety` branches on target kind) but the audit
  phase currently requires a cloned repo.
- **Separate hardening item surfaced by this work:** `chmod 600
  ~/clawd/clawd-md/.env.clawd` — it's currently world-readable.
