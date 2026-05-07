#!/bin/bash
# provisionBuilderAgent.sh — runs INSIDE a cont VM via
#   `./cont provision <vm> ./provisionBuilderAgent.sh`.
#
# Layered model:
#   provision.sh                clean mac
#   provisionAgent.sh           ^ + Claude Code + auto-launch on boot
#   provisionBuilderAgent.sh    ^ + foundry + gh + yarn (corepack)
#                                 + scripts/{bgipfs,leftclaw}
#                                 + skills/builder + builder prompt
#
# Idempotent — safe to re-run.
#
# Prereqs on the host (in this directory):
#   - .env.builder              (PRIVATE_KEY, BGIPFS_KEY, ALCHEMY_API_KEY,
#                                GITHUB_TOKEN, GITHUB_USER)
#   - builder.prompt.md
#   - scripts/bgipfs/, scripts/leftclaw/
#   - skills/builder/{COMPREHENSIVEPLAYBOOK,DAPP_BUILD_PLAYBOOK,
#                     START_HERE_FIRST,orchestration,ship,
#                     ethskills-master,scaffold-eth-2-AGENTS}.md

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> builder layer: $(whoami)@$(hostname)"

# --- foundry (provides cast/forge/anvil) -------------------------------
if ! command -v cast >/dev/null 2>&1; then
  echo "==> installing foundry"
  curl -fsSL https://foundry.paradigm.xyz | bash
  "$HOME/.foundry/bin/foundryup"
  for rc in "${RC_FILES[@]}"; do
    if ! grep -qs '\.foundry/bin' "$rc" 2>/dev/null; then
      echo 'export PATH="$HOME/.foundry/bin:$PATH"' >> "$rc"
    fi
  done
  export PATH="$HOME/.foundry/bin:$PATH"
fi

# --- gh CLI ------------------------------------------------------------
# The builder pushes generated code to GitHub and files audit issues.
if ! command -v gh >/dev/null 2>&1; then
  echo "==> installing gh"
  /opt/homebrew/bin/brew install gh
fi

# --- yarn via corepack -------------------------------------------------
# Scaffold-ETH 2 expects yarn berry. corepack ships with node@24, just
# needs to be activated.
if ! command -v yarn >/dev/null 2>&1; then
  echo "==> activating yarn via corepack"
  /opt/homebrew/opt/node@24/bin/corepack enable yarn
fi

# --- bgipfs CLI (used by the builder's ship script) --------------------
# scripts/builder/bgipfs-ship.sh shells out to `npx bgipfs upload …`.
# Install once globally so npx finds it without a per-job network round-trip.
if ! command -v bgipfs >/dev/null 2>&1; then
  echo "==> installing bgipfs CLI globally"
  /opt/homebrew/opt/node@24/bin/npm install -g bgipfs >/dev/null 2>&1 || \
    echo "  WARN: bgipfs install failed; ship script will fall back to npx on first use"
fi

# --- install scripts ---------------------------------------------------
echo "==> installing ~/scripts/{bgipfs,leftclaw,builder}"
mkdir -p "$HOME/scripts"
for fam in bgipfs leftclaw builder; do
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

# --- install skills/builder --------------------------------------------
echo "==> installing ~/skills/builder"
mkdir -p "$HOME/skills"
src="/tmp/skills/builder"
if [[ -d "$src" ]]; then
  rm -rf "$HOME/skills/builder"
  cp -R "$src" "$HOME/skills/builder"
else
  echo "ERROR: $src missing — host-side skills/builder/ must exist" >&2
  exit 1
fi

# --- .env.builder + prompt ---------------------------------------------
ENV_SRC="/tmp/.env.builder"
ENV_DST="$HOME/.env.builder"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  if ! grep -qs '\.env\.builder' "$HOME/.zprofile" 2>/dev/null; then
    echo '[ -f "$HOME/.env.builder" ] && source "$HOME/.env.builder"' >> "$HOME/.zprofile"
  fi
else
  echo "ERROR: $ENV_SRC missing — drop a .env.builder next to this script on the host" >&2
  echo "       (copy .env.builder.example -> .env.builder and fill in values)" >&2
  exit 1
fi

PROMPT_SRC="/tmp/builder.prompt.md"
PROMPT_DST="$HOME/builder.prompt.md"
if [[ -f "$PROMPT_SRC" ]]; then
  echo "==> installing $PROMPT_DST"
  install -m 644 "$PROMPT_SRC" "$PROMPT_DST"
  rm -f "$PROMPT_SRC"
else
  echo "ERROR: $PROMPT_SRC missing" >&2
  exit 1
fi

# --- gh auth bootstrap (idempotent) ------------------------------------
# Source the env so GITHUB_TOKEN is available for `gh auth login`.
# shellcheck disable=SC1091
source "$HOME/.env.builder"
if [[ -z "${GITHUB_TOKEN:-}" || "$GITHUB_TOKEN" == "ghp_REPLACE_ME" ]]; then
  echo "ERROR: GITHUB_TOKEN not set or still placeholder in .env.builder" >&2
  exit 1
fi
# Configure gh and git for the bot identity. `gh auth login --with-token`
# stashes the token in the system keychain so subsequent gh calls don't
# need the env var. Re-running is fine (overwrites cleanly).
echo "==> authenticating gh as ${GITHUB_USER:-clawdbotatg}"
echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com
gh auth setup-git --hostname github.com >/dev/null 2>&1 || true
git config --global user.name "${GITHUB_USER:-clawdbotatg}"
git config --global user.email "clawd@buidlguidl.com"
gh_who="$(gh api user --jq .login 2>/dev/null || echo unknown)"
echo "  active gh account: $gh_who"
if [[ "$gh_who" != "${GITHUB_USER:-clawdbotatg}" ]]; then
  echo "ERROR: gh auth resolved to '$gh_who', expected '${GITHUB_USER:-clawdbotatg}'" >&2
  exit 1
fi

# --- builds workspace -------------------------------------------------
mkdir -p "$HOME/builds"

# --- override the startup wrapper to fire the builder prompt -----------
echo "==> writing builder startup wrapper"
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true

PROMPT_FILE="$HOME/builder.prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "claude-startup.sh: missing $PROMPT_FILE" >&2
  exec zsh -l
fi
PROMPT="$(cat "$PROMPT_FILE")"

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --chrome "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Flush all writes — tart stop is not always graceful and can roll back
# recent writes when the VM is killed without a clean shutdown.
sync

echo "==> builder layer: done"
