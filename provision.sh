#!/bin/bash
# provision.sh — runs INSIDE a cont VM via `./cont provision <vm>`.
# Idempotent — safe to re-run. Edit to taste; this matches a customized
# "browse + terminal" setup.
set -euo pipefail

echo "==> provisioning $(whoami)@$(hostname) ($(sw_vers -productName) $(sw_vers -productVersion))"

# --- Homebrew (preinstalled on cirruslabs *-base, fallback to install) ---
if [[ ! -x /opt/homebrew/bin/brew ]]; then
  echo "==> installing Homebrew ..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# --- CLI tools -----------------------------------------------------------
echo "==> brew install: htop"
brew install htop

# --- GUI apps ------------------------------------------------------------
echo "==> brew install --cask: google-chrome, iterm2"
brew install --cask google-chrome iterm2

# --- iTerm2 dark theme ---------------------------------------------------
# TabStyleWithAutomaticOption: 1 = Dark
echo "==> iTerm2: dark theme"
defaults write com.googlecode.iterm2 TabStyleWithAutomaticOption -int 1

# --- Dock: trim to just the essentials -----------------------------------
echo "==> Dock: trim to Safari/Chrome/iTerm/System Settings"
dock_add() {
  local app="$1"
  local url="file://${app// /%20}/"
  defaults write com.apple.dock persistent-apps -array-add \
    "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$url</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
}
defaults write com.apple.dock persistent-apps -array
dock_add /Applications/Safari.app
dock_add "/Applications/Google Chrome.app"
dock_add /Applications/iTerm.app
dock_add "/System/Applications/System Settings.app"
killall Dock 2>/dev/null || true

# --- hide desktop widgets ------------------------------------------------
echo "==> hide desktop widgets"
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
killall WindowManager 2>/dev/null || true

echo "==> done"
