#!/bin/bash
# provisionAuditorAgent.sh — runs INSIDE a cont VM via
#   `./cont provision <vm> ./provisionAuditorAgent.sh`.
#
# Layered model (each script source's the layer below):
#   provision.sh                clean mac
#   provisionAgent.sh           ^ + Claude Code authed + auto-launch on boot
#   provisionAuditorAgent.sh    ^ + foundry + scripts/{bgipfs,leftclaw}
#                                 + skills/{ethskills,pashov} + auditor prompt
#
# Idempotent — safe to re-run.
#
# Prereqs on the host (in this directory):
#   - .env.auditor              (copy from .env.auditor.example, fill in)
#   - auditor.prompt.md         (the prompt — edit to change agent behavior)
#   - scripts/bgipfs/           (deterministic credentialed helpers)
#   - scripts/leftclaw/         (deterministic credentialed helpers)
#   - skills/two-phase-audit.md (the orchestrator the auditor runs)
#   - skills/ethskills-audit.md (phase-1 methodology, pre-fetched)
#   - skills/pashov-auditor.md  (phase-2 methodology, pre-fetched)

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> auditor layer: $(whoami)@$(hostname)"

# --- Claude Code floor — every boot, FAST or not ---------------------------
# The auditor runs `--model claude-fable-5-2` and spawns `model: fable`
# agents. A CLI older than CLAUDE_MIN_VERSION rejects that id and maps
# `fable` to the old Fable 5 (tested on gold's 2.1.202, 2026-11-09), and a
# fresh clone only starts its background auto-update AFTER the auditor has
# launched. So a gold baked before the floor gets the pinned CLI here.
CLAUDE_MIN_VERSION="2.1.321"
_cv="$("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')"
if [[ "$(printf '%s\n%s\n' "$CLAUDE_MIN_VERSION" "${_cv:-0}" | sort -V | head -1)" != "$CLAUDE_MIN_VERSION" ]]; then
  echo "==> claude ${_cv:-missing} < $CLAUDE_MIN_VERSION — installing $CLAUDE_MIN_VERSION"
  "$HOME/.local/bin/claude" install "$CLAUDE_MIN_VERSION" >/dev/null 2>&1 \
    || curl -fsSL https://claude.ai/install.sh | bash -s "$CLAUDE_MIN_VERSION"
  echo "==> claude now $("$HOME/.local/bin/claude" --version 2>/dev/null)"
fi

# --- foundry (provides `cast`) — Tier 2, baked into auditor-gold --------
# leftclaw scripts use `cast` for on-chain reads (getJob) and writes
# (acceptJob, completeJob). Install via the official one-liner if missing.
if [[ "${CONT_PROVISION_FAST:-}" != "1" ]] && ! command -v cast >/dev/null 2>&1; then
  echo "==> installing foundry (cast/forge/anvil)"
  curl -fsSL https://foundry.paradigm.xyz | bash
  # foundryup is installed at ~/.foundry/bin/foundryup; run it to fetch the toolchain.
  "$HOME/.foundry/bin/foundryup"
  # Make sure ~/.foundry/bin is on PATH for future shells.
  for rc in "${RC_FILES[@]}"; do
    if ! grep -qs '\.foundry/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$rc"
    fi
  done
  export PATH="$HOME/.foundry/bin:$PATH"
fi

# --- install scripts and skills ----------------------------------------
# cont provision scps the host-side `scripts/` and `skills/` dirs into
# /tmp on the VM. We selectively copy the families this agent needs.

echo "==> installing ~/scripts/{bgipfs,leftclaw}"
mkdir -p "$HOME/scripts"
for fam in bgipfs leftclaw; do
  src="/tmp/scripts/$fam"
  if [[ -d "$src" ]]; then
    rm -rf "$HOME/scripts/$fam"
    cp -R "$src" "$HOME/scripts/$fam"
    chmod +x "$HOME/scripts/$fam"/*.sh 2>/dev/null || true
  else
    echo "ERROR: $src missing — host-side scripts/$fam/ must exist" >&2
    exit 1
  fi
done

echo "==> installing ~/skills/ (full trees)"
mkdir -p "$HOME/skills"
# Top-level pointer files. two-phase-audit-v2.md is the LIVE orchestrator
# (adds a context-building Phase 0 in front of breadth+depth); two-phase-audit.md
# (v1) is kept as the fallback/reference and is still used by host-auditor.
for s in two-phase-audit-v3.md two-phase-audit-v2.md two-phase-audit.md audit-context.md ethskills-audit.md pashov-auditor.md pashov-auditor-v4.md README.md; do
  src="/tmp/skills/$s"
  if [[ -f "$src" ]]; then
    install -m 644 "$src" "$HOME/skills/$s"
  fi
done
# Full repos: evm-audit-skills (19 sub-skills), pashov-skills/solidity-auditor,
# and tob-audit-context (the Phase-0 function-analyzer + reference resources).
for d in evm-audit-skills pashov-skills tob-audit-context; do
  src="/tmp/skills/$d"
  if [[ -d "$src" ]]; then
    rm -rf "$HOME/skills/$d"
    cp -R "$src" "$HOME/skills/$d"
  else
    echo "ERROR: $src missing — host-side skills/$d/ must exist (run ./refresh-skills.sh)" >&2
    exit 1
  fi
done
# pashov solidity-auditor V4 tree — LIVE phase 2 since 2026-09-23. Required:
# the wrangler's needs_skills_refresh pulls it the moment a box lacks it.
if [[ -d /tmp/skills/pashov-skills-v4 ]]; then
  rm -rf "$HOME/skills/pashov-skills-v4"
  cp -R /tmp/skills/pashov-skills-v4 "$HOME/skills/pashov-skills-v4"
else
  echo "ERROR: /tmp/skills/pashov-skills-v4 missing — host-side skills/pashov-skills-v4/ must exist (run ./refresh-skills.sh)" >&2
  exit 1
fi

# Delete pashov's "Mental tool protocol" from the attack agents' rules file.
# That section orders every agent to PRINT its reasoning as [Feynman: …] /
# [Socratic: …] / [Inversion: …] markers. The API's safeguard reads that as
# reasoning extraction and stops the agent: jobs 994–1223 lost 1 to 12 of the
# 12 attack agents, and two re-runs of job 1222 lost 9 of 18 and 8 of 17
# spawns. With the section gone the third re-run got 12 of 12, zero stops
# (2026-11-13). A prompt line saying "ignore it" did NOT work — the text has
# to be out of the bundle. The pashov trees are gitignored per-box clones, so
# this runs here, at every boot, and survives a skills refresh. The SOP still
# teaches the three tools; only the print-it-out order is removed.
python3 - <<'PYEOF' || echo "WARNING: could not strip the marker protocol from shared-rules.md" >&2
import glob, os
for p in glob.glob(os.path.expanduser("~/skills/pashov-skills*/solidity-auditor/references/hacking-agents/shared-rules.md")):
    s = open(p).read()
    a, b = s.find("## Mental tool protocol"), s.find("## Cross-contract patterns")
    if a < 0:
        print("marker protocol: not present in", p); continue
    if b < a:
        print("WARNING: marker protocol found but its end was not, left as is:", p); continue
    s = s[:a] + s[b:]
    s = s.replace(", AND mandatory mental tool protocol)", ")")
    i = s.find("**The protocol below applies continuously")
    if i >= 0:
        j = s.find("\n\n", i)
        s = s[:i] + s[j + 2:] if j > 0 else s
    open(p, "w").write(s)
    print("marker protocol: removed from", p)
PYEOF

# --- .env.auditor and prompt file --------------------------------------
# AGENT_ENV_FILE lets one provisioner serve multiple auditor instances
# (auditor2 was silently getting auditor1's wallet before this, so its
# agent saw auditor1's in-progress job as "mine" and never accepted work).
ENV_SRC="/tmp/${AGENT_ENV_FILE:-.env.auditor}"
ENV_DST="$HOME/.env.auditor"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  # Idempotent rewrite: strip any prior .env.auditor line, then re-add
  # with set -a so secrets auto-export to child processes.
  if [[ -f "$HOME/.zprofile" ]]; then
    grep -v '\.env\.auditor' "$HOME/.zprofile" > "$HOME/.zprofile.tmp" || true
    mv "$HOME/.zprofile.tmp" "$HOME/.zprofile"
  fi
  echo '[ -f "$HOME/.env.auditor" ] && { set -a; source "$HOME/.env.auditor"; set +a; }' >> "$HOME/.zprofile"
else
  echo "ERROR: $ENV_SRC missing — drop a .env.auditor next to this script on the host" >&2
  echo "       (copy .env.auditor.example -> .env.auditor and fill in values)" >&2
  exit 1
fi

PROMPT_SRC="/tmp/auditor.prompt.md"
PROMPT_DST="$HOME/auditor.prompt.md"
if [[ -f "$PROMPT_SRC" ]]; then
  echo "==> installing $PROMPT_DST"
  install -m 644 "$PROMPT_SRC" "$PROMPT_DST"
  rm -f "$PROMPT_SRC"
else
  echo "ERROR: $PROMPT_SRC missing" >&2
  exit 1
fi

# --- override the startup wrapper to fire the auditor prompt -----------
echo "==> writing auditor startup wrapper"
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true

PROMPT_FILE="$HOME/auditor.prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "claude-startup.sh: missing $PROMPT_FILE — re-run 'cont provision <vm> ./provisionAuditorAgent.sh' on the host" >&2
  exec zsh -l
fi
PROMPT="$(cat "$PROMPT_FILE")"

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --model claude-fable-5-2 "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Flush all writes — tart stop is not always graceful and can roll back
# recent writes when the VM is killed without a clean shutdown.
sync

echo "==> auditor layer: done"
