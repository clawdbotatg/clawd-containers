#!/bin/bash
# provisionFeatureAgent.sh — runs INSIDE a cont VM via
#   `./cont provision <vm> ./provisionFeatureAgent.sh`.
#
# Layered model:
#   provision.sh                clean mac
#   provisionAgent.sh           ^ + Claude Code + auto-launch on boot
#   provisionFeatureAgent.sh    ^ + foundry + gh + yarn (corepack)
#                                 + scripts/{bgipfs,leftclaw,builder,feature}
#                                 + skills/{builder,feature}
#                                 + feature prompt
#
# The feature agent extends existing leftclaw builds AND files PRs against
# external repos. It needs the same toolchain as the builder (foundry, gh,
# yarn) plus the builder skills (when extending an SE2 dApp it walks the
# same playbooks) plus the feature-specific skill + scripts.
#
# Idempotent — safe to re-run.
#
# Prereqs on the host (in this directory):
#   - .env.feature              (PRIVATE_KEY, BGIPFS_KEY, ALCHEMY_API_KEY,
#                                GITHUB_TOKEN, GITHUB_USER)
#   - feature.prompt.md
#   - scripts/{bgipfs,leftclaw,builder,feature}/
#   - skills/{builder,feature}/

set -euo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SELF_DIR/provisionAgent.sh"

echo "==> feature layer: $(whoami)@$(hostname)"

# --- Tier 2 toolchain (skip in FAST mode — baked into feature-gold) ----
if [[ "${CONT_PROVISION_FAST:-}" != "1" ]]; then
  # foundry (provides cast/forge/anvil)
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

  # gh CLI
  if ! command -v gh >/dev/null 2>&1; then
    echo "==> installing gh"
    /opt/homebrew/bin/brew install gh
  fi

  # yarn via corepack
  if ! command -v yarn >/dev/null 2>&1; then
    echo "==> activating yarn via corepack"
    /opt/homebrew/opt/node@24/bin/corepack enable yarn
  fi

  # bgipfs CLI globally
  if ! command -v bgipfs >/dev/null 2>&1; then
    echo "==> installing bgipfs CLI globally"
    /opt/homebrew/opt/node@24/bin/npm install -g bgipfs >/dev/null 2>&1 || \
      echo "  WARN: bgipfs install failed; ship script will fall back to npx on first use"
  fi
fi

# --- install scripts ---------------------------------------------------
echo "==> installing ~/scripts/{bgipfs,leftclaw,builder,feature}"
mkdir -p "$HOME/scripts"
for fam in bgipfs leftclaw builder feature; do
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

# --- install skills/{builder,feature} ----------------------------------
echo "==> installing ~/skills/{builder,feature}"
mkdir -p "$HOME/skills"
for fam in builder feature; do
  src="/tmp/skills/$fam"
  if [[ -d "$src" ]]; then
    rm -rf "$HOME/skills/$fam"
    cp -R "$src" "$HOME/skills/$fam"
  else
    echo "ERROR: $src missing — host-side skills/$fam/ must exist" >&2
    exit 1
  fi
done

# --- .env.feature + prompt ---------------------------------------------
ENV_SRC="/tmp/.env.feature"
ENV_DST="$HOME/.env.feature"
if [[ -f "$ENV_SRC" ]]; then
  echo "==> installing $ENV_DST (mode 600)"
  install -m 600 "$ENV_SRC" "$ENV_DST"
  rm -f "$ENV_SRC"
  # Idempotent rewrite: strip any prior .env.feature line, then re-add
  # with set -a so secrets auto-export to child processes.
  if [[ -f "$HOME/.zprofile" ]]; then
    grep -v '\.env\.feature' "$HOME/.zprofile" > "$HOME/.zprofile.tmp" || true
    mv "$HOME/.zprofile.tmp" "$HOME/.zprofile"
  fi
  echo '[ -f "$HOME/.env.feature" ] && { set -a; source "$HOME/.env.feature"; set +a; }' >> "$HOME/.zprofile"
else
  echo "ERROR: $ENV_SRC missing — drop a .env.feature next to this script on the host" >&2
  echo "       (copy .env.feature.example -> .env.feature and fill in values)" >&2
  exit 1
fi

PROMPT_SRC="/tmp/feature.prompt.md"
PROMPT_DST="$HOME/feature.prompt.md"
if [[ -f "$PROMPT_SRC" ]]; then
  echo "==> installing $PROMPT_DST"
  install -m 644 "$PROMPT_SRC" "$PROMPT_DST"
  rm -f "$PROMPT_SRC"
else
  echo "ERROR: $PROMPT_SRC missing" >&2
  exit 1
fi

# --- gh auth bootstrap (idempotent) ------------------------------------
# shellcheck disable=SC1091
source "$HOME/.env.feature"
if [[ -z "${GITHUB_TOKEN:-}" || "$GITHUB_TOKEN" == "ghp_REPLACE_ME" ]]; then
  echo "ERROR: GITHUB_TOKEN not set or still placeholder in .env.feature" >&2
  exit 1
fi
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

# --- builds workspace --------------------------------------------------
mkdir -p "$HOME/builds"

# --- override the startup wrapper to fire the feature prompt -----------
echo "==> writing feature startup wrapper"
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true

PROMPT_FILE="$HOME/feature.prompt.md"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "claude-startup.sh: missing $PROMPT_FILE" >&2
  exec zsh -l
fi
PROMPT="$(cat "$PROMPT_FILE")"

exec "$HOME/.local/bin/claude" --dangerously-skip-permissions "$PROMPT"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

sync

echo "==> feature layer: done"
