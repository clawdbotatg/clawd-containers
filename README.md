# clawd-containers

Two things in one repo:

1. **`cont`** — a Bash CLI wrapping [tart](https://tart.run/) for programmatic
   macOS-on-macOS VMs on Apple Silicon. Boot, snapshot, reset, GUI in, ssh in.
2. **An agent fleet** — five autonomous Claude Code workers, each running in
   its own tart VM, that pick up jobs from
   [leftclaw.services](https://leftclaw.services), do them, and complete
   them on chain. A single host-side daemon (`agent-wrangler.sh`) boots and
   stops the VMs on demand so nothing burns CPU when the queues are empty.

```
host (your Mac mini)
├── agent-wrangler.sh          # polls leftclaw every 60s
├── cont                       # CLI wrapping tart
└── tart VMs (one per agent type)
    ├── auditor      Service Type 4 — Contract Audit
    ├── frontendqa   Service Type 5 — Frontend QA
    ├── builder      Service Type 6 — Build
    ├── research     Service Type 7 — Research Report
    └── feature      Service Type 10 — Feature
```

Tart caps at 2 mac VMs running concurrently; AGENTS may exceed 2 because
boots are opportunistic and idle VMs shut down each tick.

---

## Bootstrap on a fresh Mac mini

The path from a wiped Apple Silicon Mac to a running fleet:

```fish
git clone https://github.com/clawdbotatg/clawd-containers ~/clawd/clawd-containers
cd ~/clawd/clawd-containers

./install.sh                  # brew + tart + sshpass + cont symlink
curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup    # cast — used by the wrangler's leftclaw scripts
claude                        # one-time interactive login (writes OAuth to keychain)

./refresh-skills.sh           # clones skills/evm-audit-skills + skills/pashov-skills (gitignored — not in this repo)

scp old-mac:~/clawd/clawd-containers/.env.* .    # bring the five secrets files
chmod 600 .env.*

cont pull                     # ~30GB, one-time — the macOS-Tahoe base image

nohup ./agent-wrangler.sh 60 >>/tmp/agent-wrangler.out 2>&1 &
disown
```

That's it. The wrangler creates per-agent VMs on demand the first time a
matching job appears (first boot per agent type runs the full provision,
~3–5 min; subsequent boots are seconds).

### What you actually need

- **macOS on Apple Silicon** (tart needs Virtualization.framework + arm64).
- **~30 GB free** for the base image, plus ~5–10 GB per VM (APFS clones share
  blocks).
- **Homebrew, tart, sshpass, foundry** (`install.sh` covers the first three;
  foundry is currently a manual step). The official installer is the most
  reliable: `curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup`.
  `brew install foundry` exists in some homebrew taps but the package name
  has churned across versions — if your shell can't find `cast` after a
  brew install, fall back to the curl one.
- **Claude Code logged in on the host.** `cont provision` reads your OAuth
  token from the keychain and injects it into the VM during provisioning.
  Without it, the agent VMs won't launch Claude.
- **Five `.env.*` files** (gitignored, mode 600):
  - `.env.auditor` — `PRIVATE_KEY`, `BGIPFS_KEY`, `ALCHEMY_API_KEY`
  - `.env.frontend-qa` — same three
  - `.env.research` — same three
  - `.env.builder` — adds `GITHUB_TOKEN`, `GITHUB_USER` (for repo creation + push)
  - `.env.feature` — same as builder

  Each `.env.*.example` file in this repo documents the keys with comments.

- **External skill repos cloned into `skills/`.** The auditor agent reads
  from `skills/evm-audit-skills/` and `skills/pashov-skills/` — both are
  separate upstream repos, gitignored here, populated by
  `./refresh-skills.sh`. Run that script once on every fresh clone, and
  re-run any time you want to pick up upstream skill changes. **The
  auditor VM will fail to provision without it.**

### Moving credentials to the new machine

Two distinct piles, handled differently:

**Pile 1 — the `.env.*` files (high-stakes).** Real Base mainnet
`PRIVATE_KEY`, GitHub PAT, BGIPFS key, Alchemy key. `scp` over ssh, mode 600,
never paste them anywhere unencrypted.

```fish
scp -p .env.* new-mac:~/clawd/clawd-containers/
ssh new-mac 'chmod 600 ~/clawd/clawd-containers/.env.*'
```

**Pile 2 — Claude Code OAuth (rotatable).** `cont` keeps three files in
`~/.config/cont/`:

- `claude-token` — the access token
- `claude-credentials.json` — full keychain blob with the long-lived refresh token
- `claude-account.json` — the `oauthAccount` slice from `~/.claude.json`
  (Claude Code's UI "are you logged in?" gate)

Three ways to populate them on the remote:

**A — recommended for a machine you'll keep using.** ssh in with a TTY and
run the interactive setup once. Future provisions just work.

```fish
ssh -t new-mac
# on the remote:
cd ~/clawd/clawd-containers
claude setup-token             # device flow — visit the printed URL on your laptop
cont claude setup              # populates ~/.config/cont/{claude-token,*.json}
```

**B — headless / no-tty.** Copy the three files from your local box. The
refresh token in `claude-credentials.json` is long-lived; the VM's Claude
will rotate access tokens on its own.

```fish
ssh new-mac 'mkdir -p ~/.config/cont && chmod 700 ~/.config/cont'
scp -p ~/.config/cont/{claude-token,claude-credentials.json,claude-account.json} new-mac:~/.config/cont/
ssh new-mac 'chmod 600 ~/.config/cont/claude-*'
```

**One-shot remote bootstrap** (paste-and-run from your laptop). Assumes
ssh keys to the new host and the `clawdbotatg/clawd-containers` repo
being publicly cloneable (it is). If either isn't true, run the
individual steps from the bootstrap section instead.

```fish
scp -p .env.* ~/.config/cont/claude-* new-mac:/tmp/
ssh -t new-mac '
  git clone https://github.com/clawdbotatg/clawd-containers ~/clawd/clawd-containers &&
  cd ~/clawd/clawd-containers &&
  ./install.sh &&
  curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup &&
  ./refresh-skills.sh &&
  mkdir -p ~/.config/cont && mv /tmp/claude-* ~/.config/cont/ && chmod 600 ~/.config/cont/claude-* &&
  mv /tmp/.env.* . && chmod 600 .env.* &&
  cont pull &&
  nohup ./agent-wrangler.sh 60 >>/tmp/agent-wrangler.out 2>&1 & disown
'
```

About 90 seconds of human time, then `cont pull` runs unattended (~30 min
for the 30 GB base image). After that the wrangler is autonomous.

---

## `cont` — VM CLI

`cont` is the interface; reach for raw `tart` only when the wrapper doesn't
expose what you need. Cheat sheet:

```bash
cont pull                    # fetch base image (one-time)
cont up <name>               # clone base -> name (if missing) and boot headless
cont ssh <name> [cmd...]     # ssh in (admin/admin); takes optional remote cmd
cont open <name>             # boot + GUI via VNC (Tahoe workaround, see below)
cont provision <name> [s]    # boot if needed, scp script in, run it
cont reset <name>            # delete and recreate from base — clean slate
cont snapshot <from> <to>    # APFS clone (cheap); pair with `cont base <to>`
cont base [image]            # show or set the image `up`/`reset` clone from
cont spec <name> cpu=8 memory=16384   # persisted; survives reset
cont down <name>             # stop
cont rm <name>               # delete
cont list                    # all VMs + status
cont status                  # base + list
cont ip <name>               # VM IP
```

Run `cont` with no args for full usage.

### Defaults and state

- Base image: `ghcr.io/cirruslabs/macos-tahoe-base:latest` (macOS 26.x).
- VM creds: `admin` / `admin` (cirruslabs convention).
- Wrapper state: `~/.config/cont/`
  - `base` — current base image for `up` / `reset`
  - `specs/<name>.conf` — per-VM cpu/memory/disk; reapplied via `tart set`
    on stopped VMs.

### Why `cont open` exists

On macOS 26.x + tart 2.32.x, `tart run <name>` boots the VM but **never
renders a window**. `cont open` works around it via `--vnc-experimental` +
Screen Sharing.app. Use `cont open` (not raw `tart run`) for GUI work on
Tahoe; revisit after tart ≥ 2.33.

---

## The agent fleet

### Architecture

The pattern across all five agents:

1. **Cascading provision scripts** — each agent layer sources the layer
   below it, so a clean macOS image becomes a fully-prepared agent VM in
   one `cont provision` call:

   ```
   provision.sh                  → clean mac (Homebrew, Chrome, iTerm)
   provisionAgent.sh             → ^ + Claude Code authed + auto-launch on Aqua login
   provisionXxxAgent.sh          → ^ + agent-specific tooling + scripts/skills/prompt
   ```

2. **Deterministic credentialed-action scripts** under `scripts/<family>/`.
   The agent never sees raw private keys or PATs — it calls `~/scripts/leftclaw/accept.sh <id>`
   and the wrapper signs the tx. Same pattern for IPFS uploads, GitHub
   forking, etc. Reduces the credential blast radius if a prompt is
   compromised.

3. **Pre-fetched skills** in `skills/<family>/SKILL.md`. The agent's
   prompt mandates reading these before any work — the playbooks are the
   source of truth, not the model's training data.

4. **One prompt file per agent type** at `<agent>.prompt.md` in the repo
   root. Copied into the VM as `~/<agent>.prompt.md` and fed to Claude
   Code via the startup wrapper. Edit a prompt, re-provision, done.

### Per-agent gold images (fast boot)

By default the wrangler clones each VM from the generic `agent-gold`
image (clean mac + Homebrew + Chrome + iTerm + Claude Code) and runs
the FULL provisioner on top — reinstalling foundry / yarn / bgipfs /
gh / etc. every boot. That's ~30–60s of wasted work per VM start.

The fix is per-agent gold images. Each contains the agent's full Tier 1
+ Tier 2 toolchain. The wrangler clones from there and only `cont sync`'s
the volatile Tier 3 state (scripts, skills, env, prompt, OAuth) on each
boot — ~10s instead of ~60s.

**Bake one per agent (one-time, redo when toolchain changes):**

```fish
./bake-agent-gold.sh auditor
./bake-agent-gold.sh builder
./bake-agent-gold.sh feature
./bake-agent-gold.sh frontendqa
./bake-agent-gold.sh research
```

The wrangler picks them up automatically — `start_vm` checks for
`<agent>-gold` and falls back to the full provision path if missing.
So you can roll out per-agent golds incrementally; nothing breaks
during the transition.

Re-bake when:
- The agent's `provisionXxxAgent.sh` adds a new install step.
- A baked-in package needs a version bump.
- The brew package list in `provision.sh` changes.

Tier 3 changes (script edits, skill updates, prompt tweaks, env rotation)
do NOT need a re-bake — `cont sync` handles those on every boot.

### `agent-wrangler.sh`

A single host-side daemon. Watches leftclaw for any registered service
type and spins up the matching VM on demand. Stops VMs when their queue
is empty. Stops VMs that hit a per-type time cap (backstop for runaway
sessions).

```bash
nohup ./agent-wrangler.sh 60 >>/tmp/agent-wrangler.out 2>&1 &     # default
./agent-wrangler.sh 30                                            # 30s polls
pkill -f agent-wrangler.sh                                        # stop
tail -f /tmp/agent-wrangler.log                                   # observe
```

Time caps (env-overridable):
- builder, feature → 2h
- auditor, frontendqa, research → 1h

### Adding a new agent type

The wrangler is registry-driven; adding an agent is one line plus the
matching files:

1. New files in this repo:
   - `provisionXxxAgent.sh` — sources `provisionAgent.sh`, installs the
     specific toolchain, scripts, skills.
   - `xxx.prompt.md` — the agent's operating manual.
   - `.env.xxx.example` + `.env.xxx` (the real one is gitignored).
   - `scripts/xxx/` — credentialed-action wrappers if needed.
   - `skills/xxx/SKILL.md` — methodology.

2. One line in `agent-wrangler.sh`:
   ```bash
   AGENTS=(
     ...
     "<service_type_id>:<vm_name>:<provisioner>:<env_file>"
   )
   ```

The `cont provision` command auto-ships everything in the repo's
`scripts/`, `skills/`, every `provision*.sh`, every `.env*` (skipping
`.example`), and every `*.prompt.md` to `/tmp` inside the VM. Your
provisioner picks what to install where.

### Service-type coverage

| # | Name | Price | Agent | Status |
|---|------|------:|-------|--------|
| 1 | Quick Consultation | $0.40 | — | open |
| 2 | Deep Consultation | $0.60 | — | open |
| 3 | PFP Generator | $0.01 | — | open (image-gen — out of current scope) |
| 4 | Contract Audit | $4.00 | `auditor` | ✅ |
| 5 | Frontend QA Audit | $1.00 | `frontendqa` | ✅ |
| 6 | Build | $20.00 | `builder` | ✅ |
| 7 | Research Report | $2.00 | `research` | ✅ |
| 8 | Judge / Oracle | $100.00 | — | open (high-stakes; design TBD) |
| 9 | HumanQA | $200.00 | — | open (likely human-in-the-loop) |
| 10 | Feature | $5.00 | `feature` | ✅ |

---

## Files of interest

- `cont` — the VM CLI (~360 lines, dispatch in `main()`, commands as
  `cmd_<verb>`). Extend by adding a new `cmd_<verb>` and a case in `main`.
- `install.sh` — host bootstrap (Homebrew, tart, sshpass, `cont` symlink).
- `provision.sh` — base provisioner (clean mac → ready-to-use mac).
- `provisionAgent.sh` — Claude Code layer (auth + auto-launch on Aqua login).
- `provision<Xxx>Agent.sh` — per-agent layer.
- `agent-wrangler.sh` — host-side daemon.
- `scripts/leftclaw/` — credentialed wrappers for the leftclaw on-chain API
  (`accept.sh`, `complete.sh`, `get-job.sh`, `list-jobs.sh`, `messages.sh`,
  `my-jobs.sh`, `post-message.sh`, `decline.sh`, `log-work.sh`,
  `sanitize-check.sh`).
- `scripts/bgipfs/` — IPFS upload wrappers.
- `scripts/builder/` — SE2 prep + BGIPFS-ship for the builder agent.
- `scripts/feature/` — target-resolver + safe-push wrappers for the
  feature agent's two-gate security model.
- `skills/<agent>/SKILL.md` — per-agent methodology.

## Hard requirements

- macOS host on Apple Silicon (tart needs Virtualization.framework + arm64).
- ~30 GB free for the base image, plus disk per VM.
