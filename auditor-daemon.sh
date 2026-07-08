#!/usr/bin/env bash
# Run auditor-poll.sh as a launchd LaunchAgent so the leftclaw auditor runs
# itself: survives closing the terminal / logout / reboot, and restarts if it
# dies (KeepAlive). RunAtLoad starts it at login.
#
#   ./auditor-daemon.sh install [INTERVAL]   # default INTERVAL = 60s
#   ./auditor-daemon.sh uninstall
#   ./auditor-daemon.sh restart
#   ./auditor-daemon.sh status
#   ./auditor-daemon.sh logs
#
# The poller drives tart VMs (needs the GUI session for VNC/Aqua login), so
# this MUST be a LaunchAgent (gui/$UID), not a system LaunchDaemon.
set -euo pipefail

LABEL="com.clawd.auditor"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/clawd-auditor.log"
BASH_BIN="$(command -v bash)"
INTERVAL="${2:-60}"
DOMAIN="gui/$(id -u)"

cmd="${1:-}"
case "$cmd" in
  install)
    # A hand-started (nohup) poller would fight this one over the VM. Kill any.
    pkill -f "auditor-poll.sh" 2>/dev/null || true
    sleep 1
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BASH_BIN</string>
    <string>$HERE/auditor-poll.sh</string>
    <string>$INTERVAL</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
    echo "installed + loaded. interval=${INTERVAL}s  log=$LOG"
    echo "  poll log also tees to /tmp/auditor-poll.log"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled."
    ;;
  restart)
    launchctl kickstart -k "$DOMAIN/$LABEL"
    echo "restarted."
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state =|pid =" || echo "not loaded"
    ;;
  logs)
    tail -f "$LOG"
    ;;
  *)
    echo "usage: $0 {install [INTERVAL]|uninstall|restart|status|logs}"; exit 1 ;;
esac
