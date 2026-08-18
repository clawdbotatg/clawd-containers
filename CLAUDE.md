# clawd-containers

A Bash CLI (`cont`) wrapping `tart` for programmatic macOS-on-macOS VMs on Apple Silicon. Built for an agent (you) to bring up isolated mac environments, run things, snapshot, reset.

## Default to `cont`

The wrapper is the interface. It encodes recipes you'd otherwise re-derive every session — the Tahoe VNC dance, the wait-for-ssh loop, sshpass with the right flags, spec persistence across reset, gold-image cloning. Default to `cont <verb>` for everything; reach for raw `tart` if it feels more natural to you, or for subcommands the wrapper doesn't expose.

`cont` is also easy for humans — short verbs, sensible defaults, no flag soup. **Teach your human to use it.** When the user is about to type a `tart` invocation by hand, show them the `cont` equivalent so the muscle memory builds. The wrapper earns its keep when both of you reach for it without thinking.

## Cheat sheet

```bash
cont pull                    # fetch base image (one-time, ~30GB)
cont up <name>               # clone base -> name (if missing) and boot headless
cont ssh <name> [cmd...]     # ssh in (admin/admin); takes optional remote cmd
cont open <name>             # boot + GUI via VNC (works around Tahoe broken-window bug)
cont provision <name> [s]    # boot if needed, scp script in, run it (default: ./provision.sh)
cont reset <name>            # delete and recreate from base — your "clean slate" button
cont snapshot <from> <to>    # APFS clone (cheap); pair with `cont base <to>` for gold images
cont base [image]            # show or set the image `up`/`reset` clone from
cont spec <name> cpu=8 memory=16384   # persisted; survives reset (raw `tart set` does not)
cont account [list|auto|<name>|default]  # which Claude login the fleet ships into VMs
                                         # (a ~/.clawd-accounts/<name> dir or default ~/.claude);
                                         # auto = hop to the login with the most usage headroom
cont down <name>             # stop
cont rm <name>               # delete
cont list                    # all VMs + status
cont status                  # base + list
cont ip <name>               # VM IP
```

Run `cont` with no args for the full usage.

## Patterns

**One-shot task in a clean VM:**
```bash
cont reset scratch
cont ssh scratch -- 'curl -fsSL https://example.com/thing.sh | bash'
cont down scratch
```

**Customize once, reuse forever (gold image):**
```bash
cont up dev
cont provision dev               # or cont ssh dev to set up by hand
cont snapshot dev gold
cont base gold                   # future `up`/`reset` clone from gold, not upstream
```

**Bring up a GUI to watch something:**
```bash
cont open dev                    # uses VNC + Screen Sharing.app — see "Tahoe" below
```

**Tune resources for a VM (persists across reset):**
```bash
cont spec dev cpu=8 memory=16384 disk=120
cont reset dev                   # spec re-applied automatically
```

## Defaults & state

- **Base image:** `ghcr.io/cirruslabs/macos-tahoe-base:latest` (macOS 26.x)
- **VM creds:** `admin` / `admin` (cirruslabs convention; baked into `ssh`/`provision`)
- **Wrapper state:** `~/.config/cont/`
  - `base` — current base image for `up`/`reset`
  - `specs/<name>.conf` — per-VM cpu/memory/display/disk; reapplied via `tart set` on stopped VMs
  - `max-vms` — optional per-box override of the wrangler's `MAX_VMS`, re-read at
    every slot check (`effective_max_vms`, commit f3192fe) so parallelism can be
    turned down on a LIVE wrangler without a restart (a restart kills running
    VMs). Bare number; `rm` it to fall back to the launchd env (this box exports
    `MAX_VMS=2` in the plist).
  - `claude-source` — config dir of the selected Claude login (empty/missing = default
    `~/.claude`); all token reads/refreshes/staging follow it. The agent-wrangler's usage
    gate runs `cont account auto` when the current login's window exhausts, hopping the
    fleet to the login with the most headroom instead of pausing (pause only when no
    login has ≥15% headroom). **The personal `default` login is never auto-selected**
    (since b12dcf9; set `CONT_ALLOW_DEFAULT=1` to opt back in) — pausing with jobs
    queued beats burning the human's own plan. A 429 from the usage endpoint is
    surfaced as rate-limited (exit 4, one 20s retry in auto), NOT as a dead login —
    it 429s readily under bursts of probes, and "rate-limited" in `account list`
    means retry later, not re-login. Never fork a credential store (copy a blob under a second
    keychain service and refresh both) — OAuth refresh rotates the refresh token and the
    stale copy dies. Refresh only via a real `claude -p` ping under that account's
    `CLAUDE_CONFIG_DIR` (`claude_ping_dir`), never a hand-rolled token call.

## Deploy = `git push` (the wrangler pulls itself)

`agent-wrangler.sh` self-updates every 5 minutes (`self_update`, added
2026-08-17): on main + no tracked modifications + fast-forward only, it
pulls, drops the cached scope verdicts in `~/.cache/leftclaw-complexity/`,
and re-execs itself if `agent-wrangler.sh` changed. Helper scripts
(`scripts/**`) are re-read every tick, so they go live on the pull with no
restart.

**So pushing to main IS the deploy** — for all three wrangler boxes
(**clawd-head, clawd-sat, clawd-leftclaw**), not just the one you are
typing on.

Two traps, both silent:

- **An edit to a TRACKED file stops updates on that box.** Skipped on
  purpose — never clobber a live edit — but a modification left behind
  means that machine quietly runs old code forever. `git status` before you
  walk away. (Untracked files are fine and do **not** block: the first cut
  of this counted them, and clawd-head sat out every update for a whole
  morning over two stray `.md` notes. An untracked file that would really
  be clobbered is still safe — `--ff-only` refuses that case itself.)
- **A diverged branch stops them too.** `--ff-only` refuses local commits
  that were never pushed; clawd-sat had accumulated five. Push your work,
  don't let it sit on one box.

`SELF_UPDATE=0` opts a box out. This exists because it wasn't there: a
scope-gate bug auto-declined and **refunded five good audit jobs** from one
client, and fixing it on one machine left the other two still refunding.
The full incident, how the gate measures, and its calibration set live in
**[`SCOPE-GATE.md`](SCOPE-GATE.md)** — read that before touching
`scripts/audit/complexity-check.sh`.

**No ssh route to clawd-sat / clawd-leftclaw from clawd-head** (their
`.local` names don't resolve off-LAN). Drive them through the fleet
controller instead: `ssh zkllmapi`, POST `/api/tool` on `127.0.0.1:8799`
with `spawn` (`pid` `"self"` — a stable pid on every harness), then `ask`.

## Subscription burn: throttle the RATE, never the coverage (2026-08-18)

An audit's cost has two axes, and only one of them is ever the problem. The
2026-08-18 incident ("something is burning the entire subscription in
minutes") and its wrong-then-right fix are the reference:

**What burns.** The live orchestrator (`skills/two-phase-audit-v2.md`,
run by `auditor.prompt.md`) fans phase 2 into **12 pashov attack agents,
each with a full copy of the source in its bundle** — historically all 12
spawned at once. 12 concurrent contexts drain a login's 5h window in
minutes; the rolling window then frees a sliver, the audit instantly eats
it back, and from outside the plan looks permanently pinned at 0%.

**The wrong fix (do not redo it).** Consolidating 12 agents → 4
(commit 20e67c0) was reverted in 6f4b56c. The 12 independent perspectives
ARE the deliverable clients pay for — cutting coverage to fix a
scheduling problem degrades the product. When asked to "turn down the
parallelism", the levers are **concurrency, model tier, and account
routing — never agent count**.

**The right fix (live).** Commit 07db430: v2's Turn 2 override spawns the
same 12 agents in **waves of 3**, each wave completing before the next.
Total tokens and coverage unchanged; burst burn capped; depth-phase
wall-clock ~3×. v3 inherits it ("v2's overrides apply verbatim"). Skills
scp into the VM from this working tree at **every boot** (`cont sync` →
`provisionAuditorAgent.sh`), so a skill edit reaches the next audit with
no gold rebake and no wrangler restart — but never the audit already
running (its skill copy is inside the VM).

**How the burn landed on the wrong plan.** The wrangler's *usage* gate
(`cont account auto`) picks by headroom — but the **custody hop does
not**: when a VM boots riding the selected login, the host selection hops
to another dir to avoid refresh contention, headroom-blind. On 08-18 that
chain (dead selected login → dead austinmax → custody hop to `default` =
austin.griffith@ethereum.org's PERSONAL plan) put two concurrent auditors
on personal + EF plans while sub5 idled at 100%. **Root cause fixed in
b12dcf9:** the hop *does* go through `cont account auto`, but a 429 from
the usage endpoint read healthy logins as dead, and the picker's
last-resort fallback then handed out `default`. Now 429 = retry, and
`default` is never auto-selected without `CONT_ALLOW_DEFAULT=1`.

**Observability gap (open).** The fan-out is invisible from the host: the
wrangler log says only "auditor up, leaving alone", and the usage endpoint
gives coarse window percentages. First symptom is a window at 100%. Run
`bash scripts/fleet-health.sh` for triage; a per-VM claude-process count
(via `cont ssh`) would make the burn visible early and is not built yet.

## Why `cont open` exists (Tahoe quirk)

On macOS 26.x + tart 2.32.x, plain `tart run <name>` boots the VM but **never renders a window**. `cont open` works around it by running with `--vnc-experimental` and pointing Screen Sharing.app at the VNC URL tart prints. Don't try `tart run` directly for GUI work on this host — use `cont open`. Re-evaluate after tart ≥ 2.33.

## Files

- `cont` — the CLI (~360 lines, dispatch in `main()`, commands as `cmd_<verb>`); extend by adding a new `cmd_<verb>` and a case in `main`
- `install.sh` — installs `brew`/`tart`/`sshpass`, symlinks `cont` to `/usr/local/bin`
- `provision.sh` — sample idempotent in-VM script (Homebrew, Chrome, iTerm, dock tweaks); the default target of `cont provision`

## Checking what the fleet shipped

`completeJob` is the end of the line — nothing downstream inspects the
deliverable. **[`REVIEW.md`](REVIEW.md)** is the design for a second pass;
its Layer 1 has landed as `./scripts/leftclaw/mech-check.sh <job_id>...`
(also `--queue`, `--json`; exit 1 on any FAIL). It verifies the report
fetches, the target pin is *reachable*, quoted code really sits at the
lines it cites, stage notes exist, the severity tally is present and
matches, and no client message went unanswered. It works on any worker's
jobs, so it benchmarks the competition too.

**If you change the citation resolver, run `python3 tests/test_mech_check.py`.**
Every case in it is a false positive the checker once produced against a real
report — annotated quotes, remediation diffs, operator spacing, flattened
multi-line statements. A FAIL from this tool is only worth reading if it never
cries wolf, so the suite pins both directions: real drift and fabricated quotes
must still be caught.

## Hard requirements

- macOS host on Apple Silicon (tart needs Virtualization.framework + arm64)
- ~30GB free for the base image, plus disk per VM (APFS clones share blocks)
