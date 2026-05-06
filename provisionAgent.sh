#!/bin/bash
# provisionAgent.sh — runs INSIDE a cont VM via `./cont provision <vm> ./provisionAgent.sh`.
#
# Layered model — each script `source`s the layer below so any of them is a
# complete "fresh upstream VM -> ready" recipe:
#
#   provision.sh           clean mac (brew, terminal, browser)
#   provisionAgent.sh      ^ + Claude Code + auth + auto-launch
#   provisionXxxAgent.sh   ^ + your specialization
#
# Idempotent — on a gold-cloned VM the lower layers no-op (~10s) and only
# the new layer does meaningful work.
set -euo pipefail

# Cascade: run the clean-mac layer first. cont provision scps all
# provision*.sh siblings into /tmp alongside this one, so this resolves
# whether we're running from the source dir or from /tmp inside the VM.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SELF_DIR/provision.sh"

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
  python3 - "$ACCOUNT_FILE" "$HOME/.claude.json" "$HOME/.claude/settings.json" "$HOME" <<'PY'
import json, os, sys
src_path, claude_json_path, settings_json_path, home = sys.argv[1:]
patch = json.load(open(src_path))
if os.path.exists(claude_json_path):
    base = json.load(open(claude_json_path))
else:
    base = {}
base.update(patch)
# Pre-trust the user's home directory so claude doesn't prompt with
# "Quick safety check: is this a project you trust?" on first run.
projects = base.setdefault("projects", {})
projects.setdefault(home, {})["hasTrustDialogAccepted"] = True
os.umask(0o077)
with open(claude_json_path, "w") as f:
    json.dump(base, f, indent=2)
os.chmod(claude_json_path, 0o600)
# Pre-accept the --dangerously-skip-permissions warning. The wrapper
# launches claude with that flag (the VM IS the sandbox), and without
# this acknowledgement claude shows a one-time "I accept" gate.
# The flag lives in user settings under skipDangerousModePermissionPrompt;
# setting it on .claude.json gets migrated away by claude on next launch.
os.makedirs(os.path.dirname(settings_json_path), exist_ok=True)
if os.path.exists(settings_json_path):
    settings = json.load(open(settings_json_path))
else:
    settings = {}
settings["skipDangerousModePermissionPrompt"] = True
with open(settings_json_path, "w") as f:
    json.dump(settings, f, indent=2)
os.chmod(settings_json_path, 0o600)
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

# --- Auto-launch on login -----------------------------------------------
# Approach: an iTerm Dynamic Profile whose default command is our wrapper
# script. A LaunchAgent runs `open -a iTerm` at Aqua login, iTerm opens a
# window using the default profile, the profile's command runs
# `claude --chrome "gm"`. Going via Dynamic Profile avoids the macOS
# "OK to run this script?" LaunchServices prompt that fires when iTerm
# opens a `.command` file directly.

echo "==> installing claude-startup wrapper, iTerm dynamic profile, LaunchAgent"

mkdir -p \
  "$HOME/.local/bin" \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Application Support/iTerm2/DynamicProfiles"

# Wrapper. iTerm execs this as the session command, so it must source
# .zprofile to get PATH (iTerm doesn't inherit launchd's env into the
# child process for custom-command profiles).
cat > "$HOME/.local/bin/claude-startup.sh" <<'EOSH'
#!/bin/bash
# This VM is the sandbox — give claude full reign. The flag is documented
# as "Recommended only for sandboxes with no internet access," but a
# throwaway VM has the same blast-radius properties.
source "$HOME/.zprofile" 2>/dev/null || true
exec "$HOME/.local/bin/claude" --dangerously-skip-permissions --chrome "gm"
EOSH
chmod 755 "$HOME/.local/bin/claude-startup.sh"

# Dynamic Profile — fixed Guid so re-provisioning updates rather than
# duplicating. Setting Default Bookmark Guid below makes iTerm use this
# profile for new windows on launch.
PROFILE_GUID="claude-startup-cont-fixed"
cat > "$HOME/Library/Application Support/iTerm2/DynamicProfiles/claude-startup.json" <<EOPROF
{
  "Profiles": [
    {
      "Name": "claude-startup",
      "Guid": "$PROFILE_GUID",
      "Custom Command": "Yes",
      "Command": "$HOME/.local/bin/claude-startup.sh",
      "Custom Directory": "Yes",
      "Working Directory": "$HOME"
    }
  ]
}
EOPROF

# Make claude-startup the default profile for new iTerm windows.
defaults write com.googlecode.iterm2 "Default Bookmark Guid" -string "$PROFILE_GUID"

# LaunchAgent: just open iTerm at login. No script argument => no
# LaunchServices "OK to run this script?" prompt. iTerm opens a window
# with the default profile, which runs claude --chrome "gm".
cat > "$HOME/Library/LaunchAgents/com.cont.claude-startup.plist" <<EOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.cont.claude-startup</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>iTerm</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
</dict>
</plist>
EOPLIST
chmod 644 "$HOME/Library/LaunchAgents/com.cont.claude-startup.plist"

# Clean up the .command file from earlier iterations of this script so
# stale stuff doesn't accumulate.
rm -f "$HOME/.local/bin/claude-startup.command"

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

# Flush all writes to disk. tart stop is not always graceful and can roll
# back recent unsynced writes (we hit this when freshly-written files
# vanished after `cont open` rebooted the VM).
sync

echo "==> agent layer: done"
