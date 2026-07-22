#!/bin/bash
# refresh-skills.sh — pull the latest skill content from upstream into ./skills/
# so the auditor agent reads local files instead of fetching URLs at runtime.
#
# Re-run this any time you want the agent to pick up new upstream skill
# changes. After running, push to the VM with:
#   ./cont provision auditor ./provisionAuditorAgent.sh
# (no full rebuild needed — just re-scp's skills/ and reinstalls)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/skills"

# --- ethskills (full evm-audit-skills repo: master + 19 sub-skill domains)
if [[ -d evm-audit-skills/.git ]]; then
  echo "==> updating skills/evm-audit-skills"
  git -C evm-audit-skills fetch --depth=1 origin main
  git -C evm-audit-skills reset --hard origin/main
else
  echo "==> cloning skills/evm-audit-skills"
  rm -rf evm-audit-skills
  git clone --depth=1 https://github.com/austintgriffith/evm-audit-skills.git evm-audit-skills
fi

# --- pashov skills (sparse-checkout, PINNED to a reviewed SHA)
# solidity-auditor is wired into the pipeline; x-ray is Phase 0a in
# two-phase-audit-v3.md (its scripts EXECUTE in the audit environment); fizz is
# vendored for the planned fuzz phase. Because we now run pashov-authored
# code, refreshes are pinned: bump PASHOV_SHA only after reading the upstream
# diff (git -C pashov-skills log -p <old>..<new> -- solidity-auditor x-ray fizz).
# c577eb7 reviewed 2026-07-15: no network calls, subprocess use is git-only.
PASHOV_SHA=c577eb7799c349de0acb187ba00ca98e14e436fd
PASHOV_SKILLS=(solidity-auditor x-ray fizz)
if [[ ! -d pashov-skills/.git ]]; then
  echo "==> cloning skills/pashov-skills (sparse: ${PASHOV_SKILLS[*]})"
  rm -rf pashov-skills
  git clone --filter=blob:none --sparse https://github.com/pashov/skills.git pashov-skills
fi
echo "==> pinning skills/pashov-skills to reviewed SHA ${PASHOV_SHA:0:7} (sparse: ${PASHOV_SKILLS[*]})"
git -C pashov-skills fetch --depth=1 origin "$PASHOV_SHA"
git -C pashov-skills reset --hard "$PASHOV_SHA"
git -C pashov-skills sparse-checkout set "${PASHOV_SKILLS[@]}"

# --- top-level pointers (the original SKILL.md files we keep for context)
# ethskills.com is our own content (austintgriffith/evm-audit-skills) — kept
# live; the pashov pointer is pinned to the same reviewed SHA as the clone.
echo "==> refreshing top-level SKILL.md pointers"
curl -fsSL https://ethskills.com/audit/SKILL.md -o ethskills-audit.md
curl -fsSL "https://raw.githubusercontent.com/pashov/skills/$PASHOV_SHA/solidity-auditor/SKILL.md" -o pashov-auditor.md

echo
echo "==> done. Tree:"
find . -maxdepth 2 -type d | sort | sed 's|^\./|  |'
