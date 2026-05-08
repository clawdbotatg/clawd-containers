#!/bin/bash
# provisionResearchAgent.sh — runs INSIDE a cont VM via
#   `./cont provision <vm> ./provisionResearchAgent.sh`.
#
# Layered model (each script source's the layer below):
#   provision.sh                 clean mac
#   provisionAgent.sh            ^ + Claude Code authed + auto-launch on boot
#   provisionResearchAgent.sh    ^ + foundry + scripts/{bgipfs,leftclaw}
#                                  + skills/research + research prompt
#
# Idempotent — safe to re-run.
#
# Prereqs on the host (in this directory):
#   - .env.research              (copy from .env.research.example)
#   - research.prompt.md         (the prompt — edit to change agent behavior)
#   - scripts/bgipfs/            (deterministic credentialed helpers)
#   - scripts/leftclaw/          (deterministic credentialed helpers)
#   - skills/research/SKILL.md   (research methodology)

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> research layer: $(whoami)@$(hostname)"

# --- foundry (provides `cast`) — Tier 2, baked into research-gold -------
# Research jobs often cite on-chain data; cast is how we read it.
if [[ "${CONT_PROVISION_FAST:-}" != "1" ]] && ! command -v cast >/dev/null 2>&1; then
  echo "==> installing foundry (cast/forge/anvil)"
  curl -fsSL https://foundry.paradigm.xyz | bash
  "$HOME/.foundry/bin/foundryup"
  for rc in "${RC_FILES[@]}"; do
    if ! grep -qs '\.foundry/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$rc"
    fi
  done
  export PATH="$HOME/.foundry/bin:$PATH"
fi

# --- install scripts and skills ----------------------------------------
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

echo "==> installing ~/skills/research"
mkdir -p "$HOME/skills"
src="/tmp/skills/research"
if [[ -d "$src" ]]; then
  rm -rf "$HOME/skills/research"
  cp -R "$src" "$HOME/skills/research"
else
  echo "ERROR: $src missing — host-side skills/research/ must exist" >&2
  exit 1
fi

# --- .env.research and prompt file -------------------------------------
ENV_SRC="/tmp/.env.research"
ENV_DST="$HOME/.env.research"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  if ! grep -qs '\.env\.research' "$HOME/.zprofile" 2>/dev/null; then
    echo '[ -f "$HOME/.env.research" ] && source "$HOME/.env.research"' >> "$HOME/.zprofile"
  fi
else
  echo "ERROR: $ENV_SRC missing — drop a .env.research next to this script on the host" >&2
  echo "       (copy .env.research.example -> .env.research and fill in values)" >&2
  exit 1
fi

PROMPT_SRC="/tmp/research.prompt.md"
PROMPT_DST="$HOME/research.prompt.md"
if [[ -f "$PROMPT_SRC" ]]; then
  echo "==> installing $PROMPT_DST"
  install -m 644 "$PROMPT_SRC" "$PROMPT_DST"
  rm -f "$PROMPT_SRC"
else
  echo "ERROR: $PROMPT_SRC missing" >&2
  exit 1
fi

# --- override the startup wrapper to fire the research prompt ----------
echo "==> writing research startup wrapper"
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true

PROMPT_FILE="$HOME/research.prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "claude-startup.sh: missing $PROMPT_FILE — re-run 'cont provision <vm> ./provisionResearchAgent.sh' on the host" >&2
  exec zsh -l
fi
PROMPT="$(cat "$PROMPT_FILE")"

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --chrome "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Flush all writes — tart stop is not always graceful and can roll back
# recent writes when the VM is killed without a clean shutdown.
sync

echo "==> research layer: done"
