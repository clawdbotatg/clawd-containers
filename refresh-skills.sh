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

# --- pashov solidity-auditor (sparse-checkout — repo has many skills, we want one)
if [[ -d pashov-skills/.git ]]; then
  echo "==> updating skills/pashov-skills (sparse: solidity-auditor)"
  git -C pashov-skills fetch --depth=1 origin main
  git -C pashov-skills reset --hard origin/main
else
  echo "==> cloning skills/pashov-skills (sparse: solidity-auditor)"
  rm -rf pashov-skills
  git clone --depth=1 --filter=blob:none --sparse https://github.com/pashov/skills.git pashov-skills
  git -C pashov-skills sparse-checkout set solidity-auditor
fi

# --- top-level pointers (the original SKILL.md files we keep for context)
echo "==> refreshing top-level SKILL.md pointers"
curl -fsSL https://ethskills.com/audit/SKILL.md -o ethskills-audit.md
curl -fsSL https://raw.githubusercontent.com/pashov/skills/main/solidity-auditor/SKILL.md -o pashov-auditor.md

echo
echo "==> done. Tree:"
find . -maxdepth 2 -type d | sort | sed 's|^\./|  |'
