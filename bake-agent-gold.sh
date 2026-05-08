#!/usr/bin/env bash
# bake-agent-gold.sh — build a per-agent gold image with the agent's
# toolchain (foundry, gh, yarn, bgipfs CLI, etc.) baked in.
#
# Why: every wrangler boot today runs the FULL provisioner inside a
# generic agent-gold VM, reinstalling foundry / yarn / bgipfs each time.
# A per-agent gold lets the wrangler clone a VM that already has its
# toolchain and just `cont sync` the volatile per-job state (scripts,
# skills, env, prompt, OAuth) — ~10s vs ~30–60s.
#
# Usage:
#   ./bake-agent-gold.sh <agent>
#
# <agent> is one of: auditor, builder, feature, frontendqa, research.
#
# Re-run when the agent's Tier 2 toolchain changes (e.g. a new brew package
# in provisionXxxAgent.sh, a foundry version bump, a new evm-audit-skills
# clone). Tier 3 changes (scripts, skills, prompts, env) do NOT require a
# re-bake — `cont sync` handles those on every boot.
#
# How: spin up a temporary `<agent>-prep` VM, run the FULL provisioner
# (no FAST flag), stop it cleanly, snapshot to `<agent>-gold`, remove the
# prep VM. Idempotent — overwrites the previous gold of the same name.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <agent>" >&2
  echo "  agent: auditor | builder | feature | frontendqa | research" >&2
  exit 2
fi

AGENT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

case "$AGENT" in
  auditor)    PROV="provisionAuditorAgent.sh"    ; ENV_FILE=".env.auditor" ;;
  builder)    PROV="provisionBuilderAgent.sh"    ; ENV_FILE=".env.builder" ;;
  feature)    PROV="provisionFeatureAgent.sh"    ; ENV_FILE=".env.feature" ;;
  frontendqa) PROV="provisionFrontendQAAgent.sh" ; ENV_FILE=".env.frontend-qa" ;;
  research)   PROV="provisionResearchAgent.sh"   ; ENV_FILE=".env.research" ;;
  *)
    echo "unknown agent: $AGENT" >&2
    echo "valid: auditor builder feature frontendqa research" >&2
    exit 2
    ;;
esac

if [ ! -x "./$PROV" ]; then
  echo "FAIL: ./$PROV missing or not executable" >&2
  exit 1
fi
if [ ! -f "./$ENV_FILE" ]; then
  echo "FAIL: ./$ENV_FILE missing" >&2
  echo "  cp ./${ENV_FILE}.example ./${ENV_FILE} && fill in values" >&2
  exit 1
fi

PREP_VM="${AGENT}-prep"
GOLD="${AGENT}-gold"

# If the agent's actual VM is currently running (e.g. wrangler picked
# something up while we're trying to bake), bail rather than racing on
# tart's 2-VM cap. The wrangler will release the slot when its queue
# drains.
if tart list 2>/dev/null | awk -v vm="$AGENT" '$2==vm && $NF=="running"{f=1} END{exit !f}'; then
  echo "FAIL: '${AGENT}' VM is currently running. Stop it first:" >&2
  echo "  ./cont down ${AGENT}" >&2
  echo "  (or wait for the wrangler to stop it when its queue is empty)" >&2
  exit 1
fi

echo "==> baking ${GOLD} via ${PREP_VM}"
echo "==> using ${PROV} with full provisioner (FAST disabled)"
echo

# Fresh prep VM — nuke any prior one and clone from the current cont base
# (likely 'agent-gold': the Tier 1 image with brew + Chrome + iTerm + Claude).
./cont rm "${PREP_VM}" 2>/dev/null || true
./cont up "${PREP_VM}"

# Full provision — Tier 2 + Tier 3 both run.
./cont provision "${PREP_VM}" "./${PROV}"

# Stop cleanly so the snapshot is consistent (avoids the unsynced-write
# rollback we hit early on with tart stop).
./cont down "${PREP_VM}"
sleep 3

# Drop any prior gold of the same name. tart delete refuses if running;
# we've already stopped it above.
tart delete "${GOLD}" >/dev/null 2>&1 || true

# Snapshot prep -> gold (APFS clone, nearly free).
./cont snapshot "${PREP_VM}" "${GOLD}"

# Prep VM no longer needed — gold is the source of truth.
./cont rm "${PREP_VM}" || true

echo
echo "==> done. ${GOLD} is ready."
echo "    The wrangler will clone from it on the next ${AGENT} boot,"
echo "    then 'cont sync' to refresh per-job state. Total boot time"
echo "    should be ~10s vs ~30-60s before."
