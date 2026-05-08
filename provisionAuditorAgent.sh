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
#   - skills/ethskills-audit.md (audit methodology, pre-fetched)
#   - skills/pashov-auditor.md  (audit methodology, pre-fetched)

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> auditor layer: $(whoami)@$(hostname)"

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
# Top-level pointer files.
for s in ethskills-audit.md pashov-auditor.md README.md; do
  src="/tmp/skills/$s"
  if [[ -f "$src" ]]; then
    install -m 644 "$src" "$HOME/skills/$s"
  fi
done
# Full repos: evm-audit-skills (19 sub-skills) and pashov-skills/solidity-auditor.
for d in evm-audit-skills pashov-skills; do
  src="/tmp/skills/$d"
  if [[ -d "$src" ]]; then
    rm -rf "$HOME/skills/$d"
    cp -R "$src" "$HOME/skills/$d"
  else
    echo "ERROR: $src missing — host-side skills/$d/ must exist (run ./refresh-skills.sh)" >&2
    exit 1
  fi
done

# --- .env.auditor and prompt file --------------------------------------
ENV_SRC="/tmp/.env.auditor"
ENV_DST="$HOME/.env.auditor"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  if ! grep -qs '\.env\.auditor' "$HOME/.zprofile" 2>/dev/null; then
    echo '[ -f "$HOME/.env.auditor" ] && source "$HOME/.env.auditor"' >> "$HOME/.zprofile"
  fi
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

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --chrome "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Flush all writes — tart stop is not always graceful and can roll back
# recent writes when the VM is killed without a clean shutdown.
sync

echo "==> auditor layer: done"
