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
  - `claude-source` — config dir of the selected Claude login (empty/missing = default
    `~/.claude`); all token reads/refreshes/staging follow it. The agent-wrangler's usage
    gate runs `cont account auto` when the current login's window exhausts, hopping the
    fleet to the login with the most headroom instead of pausing (pause only when no
    login has ≥15% headroom). Never fork a credential store (copy a blob under a second
    keychain service and refresh both) — OAuth refresh rotates the refresh token and the
    stale copy dies. Refresh only via a real `claude -p` ping under that account's
    `CLAUDE_CONFIG_DIR` (`claude_ping_dir`), never a hand-rolled token call.

## Deploy = `git push` (the wrangler pulls itself)

`agent-wrangler.sh` self-updates every 5 minutes (`self_update`, added
2026-08-17): on main + clean worktree + fast-forward only, it pulls, drops
the cached scope verdicts in `~/.cache/leftclaw-complexity/`, and re-execs
itself if `agent-wrangler.sh` changed. Helper scripts (`scripts/**`) are
re-read every tick, so they go live on the pull with no restart.

**So pushing to main IS the deploy** — for all three wrangler boxes
(**clawd-head, clawd-sat, clawd-leftclaw**), not just the one you are
typing on.

Two traps, both silent:

- **A dirty worktree stops updates on that box.** It is skipped on purpose
  (never clobber a live edit), but a stray untracked file left behind means
  that machine quietly runs old code forever. Leave the tree clean.
- **A diverged branch stops them too.** `--ff-only` refuses local commits
  that were never pushed; clawd-sat had accumulated five. Push your work,
  don't let it sit on one box.

`SELF_UPDATE=0` opts a box out. This exists because it wasn't there: a
scope-gate bug auto-declined and **refunded five good audit jobs** from one
client, and fixing it on one machine left the other two still refunding.

**No ssh route to clawd-sat / clawd-leftclaw from clawd-head** (their
`.local` names don't resolve off-LAN). Drive them through the fleet
controller instead: `ssh zkllmapi`, POST `/api/tool` on `127.0.0.1:8799`
with `spawn` (`pid` `"self"` — a stable pid on every harness), then `ask`.

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
