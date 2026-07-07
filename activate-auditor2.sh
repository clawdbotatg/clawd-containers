#!/bin/bash
# activate-auditor2.sh — one-shot: safely restart the wrangler to load the
# auditor2 registration, then unpause both auditor slots.
#
# Run ONLY when no audit is mid-flight (job completed / VM idle): a wrangler
# restart kills tart VMs in its launchd process group, which is what caused
# the 2026-07-07 duplicate-tart thrash (restart mid-bounce orphaned a
# hypervisor process and every later boot stacked a second one).
set -euo pipefail

STATE_DIR="$(getconf DARWIN_USER_TEMP_DIR)agent-wrangler"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> stopping auditor VM gracefully (avoids orphaned tart on restart)"
"$HERE/cont" down auditor 2>/dev/null || true
sleep 2
if pgrep -f "libexec/tart.app.*ru[n] --no-graphics auditor" >/dev/null; then
  echo "ERROR: a tart process for auditor is still alive — not restarting. Investigate first." >&2
  exit 1
fi

echo "==> restarting wrangler (loads auditor2 + notification-label fix)"
launchctl kickstart -k gui/501/com.leftclaw.wrangler
sleep 3
launchctl list | grep com.leftclaw.wrangler

echo "==> unpausing auditor and auditor2"
rm -f "$STATE_DIR/paused.auditor" "$STATE_DIR/paused.auditor2"

echo "==> done — tail /tmp/agent-wrangler.out to watch both slots boot"
