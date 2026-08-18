# Subscription drain, 2026-08-17 → 08-18 — what happened, what's fixed, what isn't

Handoff doc. Written 2026-08-18 by the agent that diagnosed it. Read this
before touching account routing, `~/.clawd-accounts/`, or the audit time cap.

**One-line summary:** three subscriptions were spent in a day. The audit VMs
took the blame and were innocent — they were idle. The cost was the harness's
own account router evacuating every session at once, plus an audit depth phase
that fanned out 12 agents simultaneously.

> **Read `CLAUDE.md` → "Subscription burn: throttle the RATE, never the coverage"
> alongside this.** Another agent worked the same incident from the VM side and
> landed that section (`1f05c83`). The two are complementary, not duplicates:
> that one explains the audit fan-out and the custody hop; this one explains the
> harness-side handoff stampede, the account/dir mapping, and the pending
> rename. Where they overlap they agree.

---

## 0. How to check the fleet in one command

```bash
cd ~/clawd/clawd-harness/projects/clawd-containers
./scripts/fleet-health.sh          # exit 0 = clear, 1 = at least one FLAG
```

Read-only: starts nothing, stops nothing, touches no job. Covers daemons, VM
elapsed-vs-cap, parked jobs, per-**subscription** usage, handoff stampedes,
pegged host processes, and whether a dirty worktree is blocking self-update.

---

## 1. The three causes (they are independent — don't conflate them)

### (a) The handoff stampede — FIXED (`clawd-harness` 8784a57)

An account handoff respawns the session with `--resume`, so **each one
re-ingests that session's entire context.** Cheap for one session, a bill for
ten at once.

`_handoff_sweep` in `server.py` moved **every** session on a drained plan in a
single pass. Ten simultaneous context re-ingests landed on the fresh pool,
spent enough of it to drain that pool too, and the next sweep marched everyone
back. The day's log showed the ping-pong plainly:

```
89  sub4 → clawd        67  clawd → sub4
50  ef   → sub4         49  sub4 → sub2
1598 resumes total
```

Only the capability-evacuation path had a batch cap (`SUB_CAP_EVAC_BATCH`). The
drained rescue, the hot evacuation, and the rebalance had **none**.

Fix: `SUB_HANDOFF_BATCH` (default **2**) is ONE budget shared by all four
paths, and drained-plan sessions sort first so a rescue outranks an optional
rebalance. The sweep re-runs every ~15s, so a 10-session evacuation still
finishes inside a minute — it arrives as a queue, not a herd.
`SUB_HANDOFF_BATCH=0` restores the old behaviour.

Test: `python3 test_handoff_batch.py` (in `clawd-harness`). It binds the real
`_handoff_sweep` to a stub and constructs **no** SessionManager — a real one
would `--resume` this machine's live sessions. Same trap `test_fable_gate.py`
documents.

> **Not yet stress-tested.** Zero handoffs occurred in the window after the
> restart because no plan drained. The cap only engages when one does.

### (b) Audit depth-phase fan-out — FIXED by another agent (`07db430`)

Recovered phase timings off the VM before it was wiped (job 672, the run that
succeeded):

| phase | done at | took |
|---|---|---|
| fetch source | 22:52 | 2 min |
| phase 0 map | 23:00 | 8 min |
| phase 1 ethskills | 23:11 | **11 min** |
| phase 2 pashov | 00:36 | **85 min** |
| reconcile | 00:39 | 3 min |

**Phase 2 was 77% of runtime.** Phases 0+1 together were 21 minutes. Cost
tracks the 12-agent pashov fan-out, **not** lines of code — which is why a
1500-line file costs about the same as a 2200-line one.

History worth knowing: a consolidation 12 → 4 agents was tried (`20e67c0`) and
**reverted** (`6f4b56c`) — it cut coverage. The landed fix (`07db430`) keeps all
12 but runs them **3 at a time**. Same tokens, same coverage; the phase just
can't drain a 5h window in one burst. Depth wall-clock roughly triples.

### (c) The audit scope gate was blind — FIXED (`577cccc`)

`scripts/audit/complexity-check.sh` only discovered targets two ways: a `0x`
address, or a `github.com/owner/repo` URL. Clients increasingly ship source as
a bare file:

- job 672 → an **IPFS CID**
- jobs 629, 647, 616 → **raw.githubusercontent.com** file URLs

Neither matched, so the gate measured `TARGETS: 0 / LOC: 0` ("nothing
measurable") and **failed open to `ok` on every one**. Added `CID_RE` (CIDv0 +
CIDv1) and `SRCURL_RE` (any http `.sol`, minus github.com blob links which
`REPO_RE` already owns), fetched through three IPFS gateways, run through the
same section-aware `count_sol`.

Measured after (all were 0): `672 → 1505` · `629 → 2194` · `647 → 2260` ·
`616 → 111`. No regression: `443` still `too_complex` at 10 targets / 6820 LoC;
`422`, `374`, `440` byte-identical.

> **This closes the blind spot but would not have stopped any of them.** All
> four pass the 3000-LoC budget. LoC is the wrong axis — see (b). If you want a
> gate that predicts cost, gate on **projected agent-invocations**, not lines.

---

## 2. The four subscriptions, and why the folder names lie

**Austin has 4 subscriptions.** `~/.clawd-accounts/` had 7 directories. The
**organizationUuid** in each dir's `.claude.json` (`oauthAccount`) is the real
usage pool — the directory name is arbitrary, whatever it was called at
sign-in.

Verified by matching the harness's own subscriptions tab (which labels by org,
and aggregates across machines) against a per-dir usage probe. All four lined
up exactly.

| plan, as the harness UI names it | tier | email | folder holding it |
|---|---|---|---|
| Ethereum Foundation | max 5x | austin.griffith@ethereum.org | `ef` ✅ |
| **austingriffith** | max 20x | austin.griffith@ethereum.org | **`clawd`** ← misnamed |
| **clawd** | max 5x | clawd@buidlguidl.com | **`sub4`** ← misnamed |
| slop | max 5x | slop@buidlguidl.com | `slop` ✅ |

Plus one dead duplicate: **`austinmax`** is signed into *Ethereum Foundation* —
the same org as `ef` — and holds no usable token.

### Two wrong beliefs this corrected (don't re-derive them)

1. **"Three subscriptions are logged out, re-sign them in."** Wrong. `sub2`,
   `sub3`, `austinmax` were duplicate dirs for pools that `ef` and `clawd`
   already held working logins for. **No subscription was ever lost.**
2. **"`sub4` is a plan Austin didn't name."** Wrong. He calls it `clawd`. The
   dir named `clawd` holds the *austingriffith* plan.

### Why duplicates go dead

A duplicate dir on the same org is a **forked credential store**, which this
repo's own rule forbids: OAuth refresh **rotates** the refresh token, so
whichever dir refreshes last kills its siblings. That is why `austinmax` and
`sub3` read `no accessToken`.

**The fix for a duplicate is deletion, never re-sign-in** — re-signing in
re-forks the store and restarts the same clock. Same failure family as the
wrangler's `custody hop unavailable — shared custody, refresh contention
possible` warning when two VMs ride one login.

Done: `sub2` and `sub3` moved to `~/.clawd-accounts-removed-2026-08-18/`
(recoverable, not shredded). Nothing was bound to them.

---

## 3. ⚠️ THE PENDING RENAME — read the trap before you `mv` anything

**Not done.** Austin approved it; it was never executed.

Goal: folder names should match the plan names, leaving exactly four.

```
delete  austinmax   (dead duplicate of ef)
rename  clawd  -> austinmax     (the max 20x austingriffith plan)
rename  sub4   -> clawd         (the clawd@buidlguidl.com plan)
```

### The trap: the login is NOT in the folder

It is in the **macOS keychain**, under a service name derived from the folder's
**full path**:

```python
# tools/usage_probe.py :: keychain_service()
"Claude Code-credentials-" + sha256(NFC(config_dir)).hexdigest()[:8]
```

Verified against every account on clawd-head. The actual service names are
deliberately **not** written down here — this repo is public, and a list of
"here are the keychain items holding live OAuth tokens" is a gift to anyone who
gets local access. Compute them when you need them:

```bash
python3 - <<'EOF'
import hashlib, unicodedata, glob, os
for d in sorted(glob.glob(os.path.expanduser("~/.clawd-accounts/*"))):
    h = hashlib.sha256(unicodedata.normalize("NFC", d).encode()).hexdigest()[:8]
    print(f"{os.path.basename(d):<12} Claude Code-credentials-{h}")
EOF
```

Confirm one exists:
`security find-generic-password -s "Claude Code-credentials-<hash>" -w`

**A plain `mv` silently destroys the login.** New path → new hash → Claude Code
looks for a keychain entry that does not exist.

**And there is a collision.** The hash depends only on the path string, so
`.../clawd` maps to the same slot no matter which plan lives there. Renaming
`sub4` → `clawd` therefore needs the slot the austingriffith plan currently
occupies. **Order is not optional** — free the slot before you claim it.

### Safe procedure

1. **Stop harness + wrangler** — nothing may refresh a token mid-move.
   `launchctl` bootout is the silent killer per the ops runbook; prefer
   `touch $STATE_DIR/paused.<vm>` for the wrangler and a clean harness stop.
   Compute the five slot names with the snippet above and keep them to hand —
   below, `slot(x)` means the service name for `~/.clawd-accounts/x`.
2. Delete the dead `austinmax` dir **and** `slot(austinmax)` — that slot is the
   destination in step 3, so it must be empty first.
3. austingriffith: copy blob `slot(clawd)` → `slot(austinmax)`,
   `mv clawd austinmax`, **verify with `usage_probe.py`**, only then delete the
   old `slot(clawd)`. This frees `slot(clawd)` for step 4.
4. clawd: copy blob `slot(sub4)` → `slot(clawd)`, `mv sub4 clawd`, **verify**,
   only then delete the old `slot(sub4)`.
5. Update references: `.clawd-harness.sessions.json` (sessions record
   `account` + `config_dir` for `--resume`), the harness accounts registry, and
   `~/.config/cont/claude-source`.
6. Restart; confirm all four read usage and the emails match the UI table above.

**Invariant that keeps this safe:** never two live copies of one credential at
once (that is what kills tokens), and delete the old slot only after the new one
verifies. Nothing running during the move means nothing can refresh.

**Good window:** when all live sessions sit on `ef` and nothing is bound to
`clawd`/`sub4`. Check with the session registry before starting.

---

## 4. The stuck-job situation (separate, cheaper problem)

Four jobs were held IN_PROGRESS across the fleet. Ground truth is on-chain
(`getJobsByStatus(1)` on `0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a`, Base) —
this works even when a box is unreachable by ssh.

- **629** — ours, locked **3 days**, parked at 2 cap strikes. Not burning, but
  escrow frozen and it blocked `auditor` from booting for anything (~320
  "not booting" log lines in one day).
- **656** — another box, accepted 10:43, **zero work logs in 8h40m**.
- **671** — another box, silent since 15:07. The client gave up and reposted it
  as **677**, which a *third* box accepted — so two of our own boxes audited the
  same `StakePool.sol`.
- **677** — progressing normally.

**A parked job is a double cost:** it blocks its agent AND locks client escrow.
The contract has **no path out of IN_PROGRESS except the assigned worker's
`completeJob`** — `cancelJob`, `adminCancelJob`, and `declineJob` all revert
`!open`. So an abandoned accepted job is permanent; the only remedy is the
client reposting.

### The auditors are all one team

`0xd98728b9…` and `0x8f5d03c5…` are **our own fleet wallets on other machines**,
not competitors. An older memory note logged them as "rival snipers" — that note
has been corrected. Reading them as rivals makes a job burst look like "we won
2 of 7" when the fleet won **all 7** — which is the actual explanation for
burning three subscriptions, and it is invisible if you mislabel them.

Only `0xb2109c9c…` and `0x024771c8…` remain unconfirmed as third parties.
**Check any taker against every box's `.env.auditor*` before calling it a rival.**

---

## 5. Time cap: the multiplier nobody costed

`TIME_CAP_AUDITOR_SECONDS` is **14400** (4h), `MAX_CAP_STRIKES` is **2**.

A cap kill **wipes the VM, so the retry redoes every phase from zero.** One bad
job can therefore eat 8h of Opus and deliver nothing. Job 672's run #1 hit 240
min and was killed; run #2 finished in 110 min. You paid for both.

Austin's stated position: *he would rather a job take 6 hours than time out and
restart* — the gate at the front should decide what to admit, and admitted work
should be allowed to finish. **Open question he raised and nobody has answered:
does anything actually spin forever without the cap?** Worth determining before
raising or removing it. If nothing does, the cap is pure downside.

If the cap stays, checkpointing phases across a kill would make a retry resume
instead of restart — that is the change that makes strike 2 not cost double.

---

## 6. Reaching the other machines

Fleet machines seen on the relay over 3 days (`ssh zkllmapi`,
`journalctl -u clawd-fleet-relay | grep -oE 'clawd-[a-z]+'`): **clawd-head**
(this box, 235 hits), **clawd-leftclaw** (116), **clawd-heart** (4).

> **Naming discrepancy — unresolved.** `CLAUDE.md` names the three wrangler
> boxes clawd-head / **clawd-sat** / clawd-leftclaw. `clawd-sat` never appears
> in the relay journal and `clawd-heart` is not in CLAUDE.md. One of them was
> probably renamed. Confirm before you rely on either name.

**Account dirs are per-machine.** `~/.clawd-accounts/` on this box holds
`austinmax, clawd, ef, slop, sub4`. Other boxes have different sets (the other
agent's writeup references a `sub5` that does not exist here). Never assume a
dir name means the same plan on another machine — check the org.

**There is no ssh route to leftclaw/heart from head** — their `.local` names
don't resolve off-LAN, and `buck`/`officebox` in `~/.ssh/config` time out.
Options: drive them through the fleet controller (`ssh zkllmapi`, POST
`/api/tool` on `127.0.0.1:8799`, `spawn` with `pid` `"self"`, then `ask`), or use
on-chain job state as ground truth for what a box is doing.

`clawd-leftclaw` was flapping offline/online every ~8–25 min in the relay log.
**Unexplained — worth a look.** It may be a crash-loop.

---

## 7. Still open

- [ ] **The rename** (§3) — approved, not done. Read the keychain trap first.
- [ ] `austinmax` folder is a dead duplicate; delete it as part of the rename.
- [ ] **Stampede cap is untested under a real drain** — watch for
      `[accounts] handoff budget:` in the harness log the next time a plan walls.
- [ ] Weekly windows: `clawd`/`austingriffith` and `clawd@buidlguidl` were both
      at 98%. `ef` is the healthy pool (resets Aug 25).
- [ ] **The custody hop is headroom-blind — likely the remaining root bug.**
      The wrangler's *usage* gate (`cont account auto`) picks by headroom, but
      the custody hop that fires when a VM boots riding the selected login does
      **not**. On 08-18 that chain (dead selected login → dead `austinmax` →
      hop to `default`) put two concurrent auditors on the personal + EF plans
      while a healthy pool idled. Credit: the other agent's CLAUDE.md writeup;
      I did not find this one. Fix the hop to consult headroom.
- [ ] **VM credential contention**: both auditor VMs booted with
      `WARNING: cont stage failed — guest may ride stale creds` and
      `custody hop unavailable — shared custody, refresh contention possible`.
      Same family as §2, and the trigger for the headroom-blind hop above.
- [ ] `clawd-leftclaw` relay flapping (§6).
- [ ] Job 629 escrow is frozen forever unless the client cancels.

## 8. Traps that cost time this round

- **A dirty worktree silently stops a box self-updating.** A stale untracked
  file (`tools/escprobe.mjs`, 2 months old) was doing this. Leave trees clean.
- **`clawd-containers` is a nested repo with its own remote**
  (`clawdbotatg/clawd-containers`). Never point it at clawd-harness.
- **A concurrent agent works in these repos.** Both pushes here needed a rebase
  mid-session. Fetch before you assume HEAD.
- **A health check that always flags is a check nobody reads.** The first cut of
  `fleet-health.sh` counted handoffs across the whole append-only log, so it
  reported the stampede forever after the fix. It now counts since the current
  server start.
- **Per-dir account reporting invents capacity.** Always group by org.
