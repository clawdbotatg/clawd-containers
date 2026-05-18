#!/bin/bash
# provisionFrontendQAAgent.sh — runs INSIDE a cont VM via
#   `./cont provision <vm> ./provisionFrontendQAAgent.sh`.
#
# Layered model (each script source's the layer below):
#   provision.sh                    clean mac
#   provisionAgent.sh               ^ + Claude Code authed + auto-launch on boot
#   provisionFrontendQAAgent.sh     ^ + foundry + scripts/{bgipfs,leftclaw}
#                                     + skills/frontend-qa + QA prompt
#
# Idempotent — safe to re-run.
#
# PHASE 1 (this version): Code-level + visual QA only. Chrome is
# available (claude --chrome) but no MetaMask is installed yet, so
# wallet-connection flow tests are deferred to MANUAL.
#
# PHASE 2 (future): Bake MetaMask into the image, import a test wallet
# from TEST_WALLET_PRIVATE_KEY env var so claude can drive real
# wallet flows.
#
# Prereqs on the host (in this directory):
#   - .env.frontend-qa              (copy from .env.frontend-qa.example)
#   - frontend-qa.prompt.md
#   - scripts/bgipfs/, scripts/leftclaw/
#   - skills/frontend-qa/{qa.md,frontend-playbook.md,frontend-ux.md}

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> frontend-qa layer: $(whoami)@$(hostname)"

# --- foundry (provides `cast`) — Tier 2, baked into frontendqa-gold -----
# QA reports may cite contract addresses + on-chain config.
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

echo "==> installing ~/skills/frontend-qa"
mkdir -p "$HOME/skills"
src="/tmp/skills/frontend-qa"
if [[ -d "$src" ]]; then
  rm -rf "$HOME/skills/frontend-qa"
  cp -R "$src" "$HOME/skills/frontend-qa"
else
  echo "ERROR: $src missing — host-side skills/frontend-qa/ must exist" >&2
  exit 1
fi

# --- .env and prompt ---------------------------------------------------
ENV_SRC="/tmp/.env.frontend-qa"
ENV_DST="$HOME/.env.frontend-qa"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  # Idempotent rewrite: strip any prior .env.frontend-qa line, then re-add
  # with set -a so secrets auto-export to child processes.
  if [[ -f "$HOME/.zprofile" ]]; then
    grep -v '\.env\.frontend-qa' "$HOME/.zprofile" > "$HOME/.zprofile.tmp" || true
    mv "$HOME/.zprofile.tmp" "$HOME/.zprofile"
  fi
  echo '[ -f "$HOME/.env.frontend-qa" ] && { set -a; source "$HOME/.env.frontend-qa"; set +a; }' >> "$HOME/.zprofile"
else
  echo "ERROR: $ENV_SRC missing — drop a .env.frontend-qa next to this script on the host" >&2
  echo "       (copy .env.frontend-qa.example -> .env.frontend-qa and fill in values)" >&2
  exit 1
fi

PROMPT_SRC="/tmp/frontend-qa.prompt.md"
PROMPT_DST="$HOME/frontend-qa.prompt.md"
if [[ -f "$PROMPT_SRC" ]]; then
  echo "==> installing $PROMPT_DST"
  install -m 644 "$PROMPT_SRC" "$PROMPT_DST"
  rm -f "$PROMPT_SRC"
else
  echo "ERROR: $PROMPT_SRC missing" >&2
  exit 1
fi

# --- override the startup wrapper to fire the frontend-qa prompt -------
echo "==> writing frontend-qa startup wrapper"
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true

PROMPT_FILE="$HOME/frontend-qa.prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "claude-startup.sh: missing $PROMPT_FILE — re-run 'cont provision <vm> ./provisionFrontendQAAgent.sh' on the host" >&2
  exec zsh -l
fi
PROMPT="$(cat "$PROMPT_FILE")"

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --chrome "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Flush all writes — tart stop is not always graceful and can roll back
# recent writes when the VM is killed without a clean shutdown.
sync

echo "==> frontend-qa layer: done"
