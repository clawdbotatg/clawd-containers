#!/bin/bash
# provisionAgent.sh — runs INSIDE a cont VM via `./cont provision <vm> ./provisionAgent.sh`.
#
# Designed to layer on top of a gold image already built from provision.sh:
#   cont up base
#   cont provision base ./provision.sh        # bake browse+terminal setup
#   cont snapshot base gold
#   cont base gold                            # future VMs clone from gold
#   cont up agent
#   cont provision agent ./provisionAgent.sh  # adds only the Claude layer
#
# Idempotent — safe to re-run. Doesn't reinstall Homebrew/Chrome/iTerm; assumes
# the gold image already has them.
set -euo pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"

echo "==> agent layer: $(whoami)@$(hostname) ($(sw_vers -productName) $(sw_vers -productVersion))"

# --- Claude Code ---------------------------------------------------------
if [[ ! -x "$HOME/.local/bin/claude" ]]; then
  echo "==> installing Claude Code ..."
  curl -fsSL https://claude.ai/install.sh | bash
fi

# Ensure ~/.local/bin is on PATH for both login (.zprofile, sourced by
# Terminal.app/iTerm) and interactive (.zshrc) zsh shells. The cirruslabs
# base image ships .zprofile but no .zshrc, so we *append* to the former
# (it already sets up brew + node) and *create* the latter.
RC_FILES=("$HOME/.zprofile" "$HOME/.zshrc")
for rc in "${RC_FILES[@]}"; do
  if ! grep -qs '\.local/bin' "$rc" 2>/dev/null; then
    echo "==> adding ~/.local/bin to PATH in $rc"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
  fi
done
export PATH="$HOME/.local/bin:$PATH"

# --- Claude OAuth credentials (injected by `cont provision` from the host)
# `cont auth` saves two artifacts on the host: the access token (for the
# CLAUDE_CODE_OAUTH_TOKEN env var, useful for non-interactive use) and the
# full macOS keychain JSON blob for the "Claude Code-credentials" entry
# (what the interactive `claude` UI actually reads). `cont provision`
# scps both into /tmp.
#
# We do BOTH:
#   1. Recreate the keychain entry — this is what makes `claude` skip the
#      login picker on first interactive run.
#   2. Export CLAUDE_CODE_OAUTH_TOKEN in ~/.zshrc — fallback for headless
#      `claude -p` invocations and shells that don't unlock the keychain.

# Merge the host-extracted auth-state fields into ~/.claude.json. This is
# the "logged in?" gate Claude Code's interactive UI checks — without
# `oauthAccount` here, the picker shows up even with a valid keychain
# entry. We merge (not overwrite) so any pre-existing local state from
# claude having run once already (e.g. firstStartTime, userID) is kept.
ACCOUNT_FILE="/tmp/cont-claude-account.json"
if [[ -f "$ACCOUNT_FILE" ]]; then
  echo "==> merging claude account state into ~/.claude.json"
  python3 - "$ACCOUNT_FILE" "$HOME/.claude.json" <<'PY'
import json, os, sys
src_path, dst_path = sys.argv[1], sys.argv[2]
patch = json.load(open(src_path))
if os.path.exists(dst_path):
    base = json.load(open(dst_path))
else:
    base = {}
base.update(patch)
os.umask(0o077)
with open(dst_path, "w") as f:
    json.dump(base, f, indent=2)
os.chmod(dst_path, 0o600)
PY
  rm -f "$ACCOUNT_FILE"
fi

CREDS_FILE="/tmp/cont-claude-credentials.json"
if [[ -f "$CREDS_FILE" ]]; then
  CREDS_JSON="$(cat "$CREDS_FILE")"
  echo "==> writing Claude Code keychain entry"
  security unlock-keychain -p "admin" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
  # Delete any prior entry — `-U` updates the password but does NOT replace
  # the ACL or partition list, so a stale ACL from a previous version
  # of this script can keep claude locked out.
  security delete-generic-password \
    -s "Claude Code-credentials" \
    -a "$USER" \
    "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
  # -A  allow any application to access without prompt. This sets the ACL.
  security add-generic-password \
    -A \
    -s "Claude Code-credentials" \
    -a "$USER" \
    -w "$CREDS_JSON" \
    "$HOME/Library/Keychains/login.keychain-db"
  # Apple added a *second* layer of access control on top of ACL: the
  # partition list. Without setting it explicitly, third-party binaries
  # (Claude Code is not Apple-signed) can be silently blocked even when
  # the ACL says -A. A broad partition list is fine in a single-user VM.
  security set-generic-password-partition-list \
    -S "apple-tool:,apple:,teamid:" \
    -k "admin" \
    -s "Claude Code-credentials" \
    -a "$USER" \
    "$HOME/Library/Keychains/login.keychain-db" >/dev/null
  # Verify the entry exists.
  if ! security find-generic-password \
        -s "Claude Code-credentials" \
        -a "$USER" \
        "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
    echo "ERROR: keychain entry 'Claude Code-credentials' not found after write" >&2
    exit 1
  fi
  # Fallback: also drop the JSON at ~/.claude/.credentials.json. Some
  # Claude Code versions read from this file when keychain access fails.
  # Cheap defense in depth.
  mkdir -p "$HOME/.claude"
  printf '%s' "$CREDS_JSON" > "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  rm -f "$CREDS_FILE"
  unset CREDS_JSON
else
  echo "==> no $CREDS_FILE — run 'cont auth' on the host, then re-provision"
fi

TOKEN_FILE="/tmp/cont-claude-token"
if [[ -f "$TOKEN_FILE" ]]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
  if [[ -z "$TOKEN" ]]; then
    echo "ERROR: $TOKEN_FILE is empty — host-side token missing or unreadable" >&2
    exit 1
  fi
  for rc in "${RC_FILES[@]}"; do
    # Replace any prior export line so a rotated token actually takes effect.
    if grep -qs 'CLAUDE_CODE_OAUTH_TOKEN=' "$rc" 2>/dev/null; then
      /usr/bin/sed -i '' '/CLAUDE_CODE_OAUTH_TOKEN=/d' "$rc"
    fi
    echo "==> writing CLAUDE_CODE_OAUTH_TOKEN to $rc"
    printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$TOKEN" >> "$rc"
    # Verify the export actually landed. Same silent-fail guard as above.
    if ! grep -q '^export CLAUDE_CODE_OAUTH_TOKEN=' "$rc"; then
      echo "ERROR: failed to write CLAUDE_CODE_OAUTH_TOKEN export to $rc" >&2
      exit 1
    fi
  done
  rm -f "$TOKEN_FILE"
fi

# --- Final auth sanity check --------------------------------------------
# Single source-of-truth verification: run a tiny non-interactive claude
# call in a fresh login shell. If this 401s, provisioning failed.
echo "==> verifying claude auth (sanity ping)"
if ! out="$(zsh -lc 'claude -p --output-format text "reply with the single word OK"' 2>&1)"; then
  echo "ERROR: claude auth verification failed:" >&2
  echo "$out" >&2
  exit 1
fi
case "$out" in
  *OK*) echo "==> claude auth ok" ;;
  *)    echo "ERROR: unexpected claude reply: $out" >&2; exit 1 ;;
esac

echo "==> agent layer: done"
