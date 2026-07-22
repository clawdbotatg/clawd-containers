#!/usr/bin/env bash
# sandbox.sh — macOS sandbox-exec jails for the untrusted-facing phases.
#
# Threat model (v1, read-only mode — we NEVER execute the target's own
# build/tests, so untrusted CODE never runs). The residual risks are:
#   1. A git clone that tries to run repo hooks → we clone hooks-off, and
#      the clone runs write-confined so a rogue hook (if one slipped) can't
#      scribble outside the job dir.
#   2. Prompt injection: the target's README/comments carry instructions
#      aimed at OUR audit agent, trying to make claude read a key and
#      exfiltrate it. The defense that actually holds regardless of what
#      the agent "decides" to do: the kernel denies the agent read access
#      to the secret files. If it can't READ the secret, it can't send it,
#      network-open or not.
#
# Empirically verified before shipping: `claude -p` runs fine under the
# net profile (it still reaches the Anthropic API and its own config), and
# `cat ~/clawd/clawd-md/.env.clawd` returns EPERM under both profiles.
#
# Two profiles, one shared base:
#   offline — deny network; for pure static recon (grep/find over the clone).
#   net     — network on; for `git clone` and the claude judge/audit calls.
#
# Both: (allow default) minus (a) reads of the secret set, (b) writes
# outside the job dir + tmp. `(allow default)` (not deny-default) is
# deliberate — wrapping a large binary like claude/node under deny-default
# is a losing game of whack-a-mole; the security property we need is the
# read-deny of secrets, which last-match-wins gives us cleanly.

HOME_DIR="${HOME:-/Users/austingriffith}"

# The secret set — everything a hijacked agent must never read. The crown
# jewel is clawd-md/.env.clawd (6 wallets + private keys + seed phrases,
# and currently world-readable — see host-auditor/CLAUDE.md). Add to this
# list, never trim it.
_secret_deny_rules() {
  cat <<RULES
(deny file-read* (subpath "$HOME_DIR/clawd/clawd-md"))
(deny file-read* (regex #"/clawd-containers/\.env"))
(deny file-read* (subpath "$HOME_DIR/.ssh"))
(deny file-read* (subpath "$HOME_DIR/.aws"))
(deny file-read* (subpath "$HOME_DIR/.foundry/keystores"))
(deny file-read* (subpath "$HOME_DIR/.config/gh"))
RULES
}

# Emit a profile to stdout. $1 = job dir (abs). $2 = "offline" | "net".
sandbox_profile() {
  local job_dir="$1" mode="${2:-net}"
  echo '(version 1)'
  echo '(allow default)'
  [[ "$mode" == "offline" ]] && echo '(deny network*)'
  _secret_deny_rules
  # Write-confinement: deny all writes, then re-allow the job workspace and
  # scratch. Reads stay broad (claude/git need system + config reads); only
  # the secret set above is carved out of reads.
  echo '(deny file-write*)'
  echo "(allow file-write* (subpath \"$job_dir\"))"
  echo '(allow file-write* (subpath "/private/tmp"))'
  echo '(allow file-write* (subpath "/private/var/folders"))'
  echo '(allow file-write* (subpath "/tmp"))'
  echo '(allow file-write* (subpath "/dev"))'
  # claude/node keep state + caches under HOME; allow those specific dirs
  # (they are NOT in the secret set) so the agent can run and authenticate.
  echo "(allow file-write* (subpath \"$HOME_DIR/.claude\"))"
  # When the invoker runs under a harness account, claude's state lives in
  # $CLAUDE_CONFIG_DIR instead of ~/.claude; without this the jailed agent's
  # Bash tool dies on mkdir session-env (EPERM) and the agent flies blind
  # (job 374 phase2 guessed the wrong job dir because of it).
  [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && echo "(allow file-write* (subpath \"$CLAUDE_CONFIG_DIR\"))"
  echo "(allow file-write* (subpath \"$HOME_DIR/.cache\"))"
  echo "(allow file-write* (subpath \"$HOME_DIR/.config/claude\"))"
  echo "(allow file-write* (subpath \"$HOME_DIR/Library/Caches\"))"
}

# run_jailed <job_dir> <offline|net> -- cmd args...
# Writes the profile to the job's sandbox dir (auditable after the fact),
# then execs the command under it.
run_jailed() {
  local job_dir="$1" mode="$2"; shift 2
  [[ "$1" == "--" ]] && shift
  mkdir -p "$job_dir/.sandbox"
  local prof="$job_dir/.sandbox/$mode.sb"
  sandbox_profile "$job_dir" "$mode" > "$prof"
  sandbox-exec -f "$prof" "$@"
}
