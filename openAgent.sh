#!/bin/bash
# openAgent.sh — end-to-end one-shot.
#
# First run: pulls latest macOS, bakes a gold image from provision.sh, ensures
# a valid Claude OAuth token, spins up an "openclaw" agent VM with the Claude
# layer, and opens VNC into it.
#
# Subsequent runs: every step is cached — gold image, agent VM, and token are
# reused. The script just boots openclaw and opens VNC.
#
# Run from this directory: ./openAgent.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONT="$HERE/cont"
UPSTREAM="ghcr.io/cirruslabs/macos-tahoe-base:latest"
GOLD="agent-gold"
AGENT="claude"
BUILDER="agent-base-build"

vm_exists() { tart list --quiet --source local 2>/dev/null | grep -Fxq "$1"; }

# 1. Bake the gold image once (fresh upstream macOS + provision.sh layer).
if ! vm_exists "$GOLD"; then
  echo "==> first run: pulling latest macOS and baking gold image (one-time, ~10 min)"
  "$CONT" pull "$UPSTREAM"
  "$CONT" base "$UPSTREAM"
  if vm_exists "$BUILDER"; then
    echo "==> cleaning up leftover $BUILDER from a previous failed run"
    "$CONT" rm "$BUILDER"
  fi
  "$CONT" provision "$BUILDER" "$HERE/provision.sh"
  "$CONT" snapshot "$BUILDER" "$GOLD"
  "$CONT" rm "$BUILDER"
else
  echo "==> gold image $GOLD already baked"
fi

# Make sure subsequent `cont up` clones come from gold, not upstream.
"$CONT" base "$GOLD" >/dev/null

# 2. Ensure Claude OAuth token. No-op if already valid; otherwise launches
#    `claude setup-token` on the host so you can click through the browser flow.
"$CONT" auth

# 3. Build the agent VM once (clones from gold, adds Claude layer).
if ! vm_exists "$AGENT"; then
  echo "==> creating agent VM '$AGENT' from $GOLD"
  "$CONT" provision "$AGENT" "$HERE/provisionAgent.sh"
else
  echo "==> agent VM '$AGENT' already provisioned"
fi

# 4. Boot if needed and open VNC.
"$CONT" open "$AGENT"
