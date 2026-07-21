#!/bin/bash
# Watchdog for com.leftclaw.wrangler — revives it if anything disables or
# unloads it.
#
# Why this exists: between 2026-07-08 and 2026-07-20 the wrangler was
# launchctl-disabled four times, costing days of fleet downtime each time.
# Root cause: a pre-show ("go live") checklist agent on this machine treated
# a running wrangler as a NO-GO and ran `launchctl disable` before every
# stream, while fleet-side sessions kept re-enabling it — two agent lineages
# fighting. Policy is now reconciled (the wrangler's own OBS gate pauses job
# work while OBS is actively recording/streaming, so the service can stay
# loaded during shows), but this watchdog guards against any regression:
# stale memory in another agent, a new automation, or a bad hand-edit.
#
# Runs from launchd (com.leftclaw.wrangler-watchdog) every 5 minutes.
# Every revival is logged with a timestamp — so if the disabler ever comes
# back, the log pins the disable to a 5-minute window for forensics.
set -u

LABEL="com.leftclaw.wrangler"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"
LOG="${WATCHDOG_LOG:-/tmp/wrangler-watchdog.log}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }

[ -f "$PLIST" ] || { echo "[$(ts)] plist missing at $PLIST — nothing to do" >>"$LOG"; exit 0; }

disabled=false
launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -q "\"$LABEL\" => disabled" && disabled=true

loaded=true
launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || loaded=false

if ! $disabled && $loaded; then
  exit 0  # healthy — stay silent
fi

if $disabled; then
  echo "[$(ts)] WRANGLER DISABLED (someone ran launchctl disable/bootout --disable in the last ~5min) — re-enabling" >>"$LOG"
  launchctl enable "$DOMAIN/$LABEL" >>"$LOG" 2>&1
fi

if ! $loaded || $disabled; then
  echo "[$(ts)] bootstrapping $LABEL" >>"$LOG"
  # bootstrap fails with EEXIST if already loaded; that's fine.
  launchctl bootstrap "$DOMAIN" "$PLIST" >>"$LOG" 2>&1 || true
fi

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "[$(ts)] revived OK" >>"$LOG"
else
  echo "[$(ts)] REVIVAL FAILED — manual: launchctl enable $DOMAIN/$LABEL && launchctl bootstrap $DOMAIN $PLIST" >>"$LOG"
fi
