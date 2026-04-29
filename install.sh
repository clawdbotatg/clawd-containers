#!/usr/bin/env bash
# install — set up tart + sshpass and put `contain` on PATH.
# Usage: ./install.sh
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: macOS only" >&2; exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Apple Silicon required (tart uses Virtualization.framework)" >&2; exit 1
fi

if ! command -v brew >/dev/null; then
  echo "==> installing Homebrew ..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! command -v tart >/dev/null; then
  echo "==> installing tart ..."
  brew install cirruslabs/cli/tart
fi

if ! command -v sshpass >/dev/null; then
  echo "==> installing sshpass ..."
  brew install esolitos/ipa/sshpass
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
chmod +x "$SCRIPT_DIR/contain"

TARGET="/usr/local/bin/contain"
if [[ "$(readlink "$TARGET" 2>/dev/null || true)" != "$SCRIPT_DIR/contain" ]]; then
  echo "==> symlinking contain -> $TARGET (sudo) ..."
  sudo mkdir -p /usr/local/bin
  sudo ln -sf "$SCRIPT_DIR/contain" "$TARGET"
fi

echo
echo "done. next steps:"
echo "  contain pull          # fetch base image (~30GB, one-time)"
echo "  contain up dev        # boot a VM"
echo "  contain open dev      # VNC into it"
