#!/bin/bash
# rehearsal-provision.sh — prep a REHEARSAL auditor VM (cloned from
# auditor-gold) for validating a staged orchestrator (two-phase-audit-v3)
# WITHOUT touching the leftclaw marketplace or holding the job wallet.
#
# Host-side usage:
#   ./cont snapshot auditor-gold rehearsal
#   ./cont provision rehearsal ./rehearsal-provision.sh
#   ./cont ssh rehearsal -- 'nohup ~/run-rehearsal.sh >/dev/null 2>&1 & echo started'
#
# What it does, in order:
#   1. kills any claude the gold image auto-launched at boot
#   2. runs the REAL provisionAuditorAgent.sh (FAST) — fresh skills incl.
#      two-phase-audit-v3.md + pashov x-ray tree, fresh claude OAuth
#   3. NEUTERS the VM: removes ~/auditor.prompt.md (the startup wrapper
#      then falls back to a plain shell on any future boot) and removes
#      ~/.env.auditor (no wallet / no leftclaw creds in this VM at all)
#   4. installs ~/rehearsal.prompt.md + ~/run-rehearsal.sh (headless runner)
#
# Idempotent — safe to re-run.

set -euo pipefail

# 1 — stop anything the baked LaunchAgent already fired
pkill -f 'dangerously-skip-permissions' 2>/dev/null || true

# 2 — normal auditor provisioning (skills, prompt, env, OAuth refresh).
#     Sourced so SELF_DIR resolves to /tmp where cont provision staged files.
export CONT_PROVISION_FAST=1
source /tmp/provisionAuditorAgent.sh

# 3 — neuter: no marketplace prompt, no wallet. The claude-startup wrapper
#     provisionAuditorAgent.sh just wrote execs zsh when the prompt file is
#     missing, so future boots come up idle.
pkill -f 'dangerously-skip-permissions' 2>/dev/null || true
rm -f "$HOME/auditor.prompt.md" "$HOME/.env.auditor"
if [[ -f "$HOME/.zprofile" ]]; then
  grep -v '\.env\.auditor' "$HOME/.zprofile" > "$HOME/.zprofile.tmp" || true
  mv "$HOME/.zprofile.tmp" "$HOME/.zprofile"
fi
rm -f /tmp/.env.* 2>/dev/null || true

# 4 — rehearsal prompt + headless runner
if [[ -f /tmp/rehearsal.prompt.md ]]; then
  install -m 644 /tmp/rehearsal.prompt.md "$HOME/rehearsal.prompt.md"
  rm -f /tmp/rehearsal.prompt.md
else
  echo "ERROR: /tmp/rehearsal.prompt.md missing — keep rehearsal.prompt.md next to this script on the host" >&2
  exit 1
fi

cat > "$HOME/run-rehearsal.sh" <<'EOSH'
#!/bin/bash
source "$HOME/.zprofile" 2>/dev/null || true
export PATH="$HOME/.local/bin:$HOME/.foundry/bin:/opt/homebrew/bin:$PATH"
cd "$HOME"
PROMPT="$(cat "$HOME/rehearsal.prompt.md")"
exec "$HOME/.local/bin/claude" --dangerously-skip-permissions -p "$PROMPT" \
  > "$HOME/rehearsal.log" 2>&1
EOSH
chmod 755 "$HOME/run-rehearsal.sh"

# sanity report for the host log
echo "==> rehearsal sanity:"
echo "    python3: $(command -v python3 || echo MISSING)"
echo "    forge:   $(command -v forge || echo MISSING)"
echo "    v3 skill: $(ls -l "$HOME/skills/two-phase-audit-v3.md" 2>/dev/null || echo MISSING)"
echo "    x-ray:    $(ls "$HOME/skills/pashov-skills/x-ray/SKILL.md" 2>/dev/null || echo MISSING)"
echo "    wallet env removed: $(test ! -f "$HOME/.env.auditor" && echo yes || echo NO — STILL PRESENT)"

sync
echo "==> rehearsal layer: done"
