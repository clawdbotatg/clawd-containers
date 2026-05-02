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

## Why `cont open` exists (Tahoe quirk)

On macOS 26.x + tart 2.32.x, plain `tart run <name>` boots the VM but **never renders a window**. `cont open` works around it by running with `--vnc-experimental` and pointing Screen Sharing.app at the VNC URL tart prints. Don't try `tart run` directly for GUI work on this host — use `cont open`. Re-evaluate after tart ≥ 2.33.

## Files

- `cont` — the CLI (~360 lines, dispatch in `main()`, commands as `cmd_<verb>`); extend by adding a new `cmd_<verb>` and a case in `main`
- `install.sh` — installs `brew`/`tart`/`sshpass`, symlinks `cont` to `/usr/local/bin`
- `provision.sh` — sample idempotent in-VM script (Homebrew, Chrome, iTerm, dock tweaks); the default target of `cont provision`

## Hard requirements

- macOS host on Apple Silicon (tart needs Virtualization.framework + arm64)
- ~30GB free for the base image, plus disk per VM (APFS clones share blocks)
