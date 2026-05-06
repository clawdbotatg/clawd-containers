#!/bin/bash
# _auth.sh — leftclaw API signature-auth helper.
#
# Usage: source ~/scripts/leftclaw/_auth.sh
#        # then $LEFTCLAW_ADDR and $LEFTCLAW_SIG are set
#
# Per https://leftclaw.services/admin/skill/api the API uses signature-
# gated auth: ?address=<wallet>&sig=<signature> on each request, where
# <signature> is `personal_sign` of the literal string
# "LeftClaw Services Auth". The signature has no nonce and is reusable,
# so we sign once per VM and cache it under ~/.cache/leftclaw-auth.
#
# This file is *sourced*, not exec'd, so the caller's shell gets the
# exported vars. Don't `set -e` here.

: "${PRIVATE_KEY:?PRIVATE_KEY not set — check ~/.env.auditor}"

LEFTCLAW_AUTH_CACHE="$HOME/.cache/leftclaw-auth"

if [[ -r "$LEFTCLAW_AUTH_CACHE" ]]; then
  # shellcheck disable=SC1090
  source "$LEFTCLAW_AUTH_CACHE"
fi

if [[ -z "${LEFTCLAW_ADDR:-}" || -z "${LEFTCLAW_SIG:-}" ]]; then
  if ! command -v cast >/dev/null 2>&1; then
    echo "_auth.sh: foundry's cast not on PATH — re-provision the VM" >&2
    return 1 2>/dev/null || exit 1
  fi
  LEFTCLAW_ADDR="$(cast wallet address "$PRIVATE_KEY")"
  LEFTCLAW_SIG="$(cast wallet sign --private-key "$PRIVATE_KEY" 'LeftClaw Services Auth')"
  mkdir -p "$(dirname "$LEFTCLAW_AUTH_CACHE")"
  ( umask 077; cat > "$LEFTCLAW_AUTH_CACHE" <<EOF
LEFTCLAW_ADDR=$LEFTCLAW_ADDR
LEFTCLAW_SIG=$LEFTCLAW_SIG
EOF
  )
  chmod 600 "$LEFTCLAW_AUTH_CACHE"
fi

export LEFTCLAW_ADDR LEFTCLAW_SIG
