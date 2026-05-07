#!/usr/bin/env bash
# leftclaw-se2-prep.sh — apply the canonical LeftClaw set of SE2 fixes to a fresh scaffold.
#
# Usage:  scripts/leftclaw-se2-prep.sh <build-dir> [<project-title>]
#
# <build-dir>     project root, e.g. /…/builds/leftclaw-service-job-99
# <project-title> short name used in the page title template
#                 (e.g. "CLAWD DCA"). Defaults to the build dir basename.
#
# This script is idempotent — safe to re-run. It applies the fixed/known-good
# state for every patch it knows about. Patches that can't be applied
# automatically are logged as WARNINGS (not failures), so the agent knows
# what manual work remains.
#
# What it does:
#   ✓ Delete app/blockexplorer/ and app/debug/ (both crash static export)
#   ✓ Drop polyfill-localstorage.cjs into packages/nextjs/
#   ✓ Drop useWriteAndOpen hook into packages/nextjs/hooks/scaffold-eth/
#   ✓ Replace ScaffoldEthAppWithProviders.tsx with mount-gated version
#   ✓ Replace next.config.ts (static export config baked in)
#   ✓ Replace getMetadata.ts (no localhost fallback, project title substituted)
#   ✓ Patch globals.css → --radius-field: 0.5rem in both theme blocks
#   ✓ Patch scaffold.config.ts → pollingInterval: 3000
#   ✓ Patch package.json build script → NODE_OPTIONS polyfill
#   ✓ Best-effort patch of contract.ts → getParsedErrorWithAllAbis walks merged
#   ✓ Add common gitignore entries
#
# What it does NOT do (still up to the agent):
#   • Header.tsx — project-specific nav and branding
#   • Footer.tsx — project-specific copy and links
#   • app/layout.tsx — title, description, fonts, metadata
#   • app/page.tsx — the actual app
#   • README.md — project description
#   • Favicon and OG image — project assets
#   • externalContracts.ts — project-specific tokens
#   • scaffold.config.ts targetNetworks — usually [chains.base] but verify
#   • appName in wagmiConnectors.tsx — project name
#   • Phantom wallet add to wagmiConnectors — fragile regex, easier by hand
#   • bare http() removal in wagmiConfig.tsx — fragile regex, easier by hand

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <build-dir> [<project-title>]" >&2
  exit 2
fi

BUILD_DIR="$(cd "$1" && pwd)"
PROJECT_TITLE="${2:-$(basename "$BUILD_DIR")}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates/se2-leftclaw"
NEXTJS_DIR="$BUILD_DIR/packages/nextjs"

if [ ! -d "$NEXTJS_DIR" ]; then
  echo "FAIL: $NEXTJS_DIR not found — is this a SE2 scaffold?" >&2
  exit 1
fi

WARNINGS=()
APPLIED=()

note_applied() { APPLIED+=("$1"); echo "  ✓ $1"; }
note_warn()    { WARNINGS+=("$1"); echo "  ⚠ $1"; }

echo "=== leftclaw-se2-prep — $BUILD_DIR ==="
echo "    project title: $PROJECT_TITLE"
echo ""

# ─── 1. Delete crashing routes ──────────────────────────────────────────────
echo "[1/9] Removing routes that crash static export"
for route in blockexplorer debug; do
  if [ -d "$NEXTJS_DIR/app/$route" ]; then
    rm -rf "$NEXTJS_DIR/app/$route"
    note_applied "removed app/$route/"
  fi
done

# ─── 2. Drop the polyfill ───────────────────────────────────────────────────
echo "[2/9] Installing polyfill-localstorage.cjs"
cp "$TEMPLATE_DIR/polyfill-localstorage.cjs" "$NEXTJS_DIR/polyfill-localstorage.cjs"
note_applied "packages/nextjs/polyfill-localstorage.cjs"

# ─── 3. Drop the useWriteAndOpen hook ───────────────────────────────────────
echo "[3/9] Installing useWriteAndOpen mobile-deep-link hook"
mkdir -p "$NEXTJS_DIR/hooks/scaffold-eth"
cp "$TEMPLATE_DIR/hooks/useWriteAndOpen.ts" "$NEXTJS_DIR/hooks/scaffold-eth/useWriteAndOpen.ts"
note_applied "hooks/scaffold-eth/useWriteAndOpen.ts"

# Add to barrel if it exists.
INDEX="$NEXTJS_DIR/hooks/scaffold-eth/index.ts"
if [ -f "$INDEX" ] && ! grep -q "useWriteAndOpen" "$INDEX"; then
  echo "export * from \"./useWriteAndOpen\";" >>"$INDEX"
  note_applied "exported useWriteAndOpen from hooks/scaffold-eth/index.ts"
fi

# ─── 4. Replace ScaffoldEthAppWithProviders ─────────────────────────────────
echo "[4/9] Installing mount-gated ScaffoldEthAppWithProviders"
cp "$TEMPLATE_DIR/components/ScaffoldEthAppWithProviders.tsx" "$NEXTJS_DIR/components/ScaffoldEthAppWithProviders.tsx"
note_applied "components/ScaffoldEthAppWithProviders.tsx (mount-gated for SSR)"

# ─── 5. Replace next.config.ts ──────────────────────────────────────────────
echo "[5/9] Installing static-export next.config.ts"
cp "$TEMPLATE_DIR/next.config.ts" "$NEXTJS_DIR/next.config.ts"
note_applied "next.config.ts (output: export, trailingSlash, unoptimized images)"

# ─── 6. Replace getMetadata.ts (with title substitution) ────────────────────
echo "[6/9] Installing localhost-free getMetadata.ts"
sed "s|__TITLE_TEMPLATE__|$PROJECT_TITLE|" "$TEMPLATE_DIR/utils/getMetadata.ts" \
  >"$NEXTJS_DIR/utils/scaffold-eth/getMetadata.ts"
note_applied "utils/scaffold-eth/getMetadata.ts (titleTemplate=\"%s | $PROJECT_TITLE\")"

# ─── 7. Patch globals.css for --radius-field ────────────────────────────────
echo "[7/9] Patching --radius-field in globals.css"
GLOBALS="$NEXTJS_DIR/styles/globals.css"
if [ -f "$GLOBALS" ]; then
  if grep -q "9999rem" "$GLOBALS"; then
    perl -i -pe 's/--radius-field:\s*9999rem/--radius-field: 0.5rem/g' "$GLOBALS"
    note_applied "--radius-field: 0.5rem in globals.css"
  else
    note_applied "globals.css already has non-pill --radius-field (no change)"
  fi
else
  note_warn "globals.css not found at $GLOBALS"
fi

# ─── 8. Patch scaffold.config.ts pollingInterval ────────────────────────────
echo "[8/9] Patching pollingInterval in scaffold.config.ts"
SCAFFOLD_CONFIG="$NEXTJS_DIR/scaffold.config.ts"
if [ -f "$SCAFFOLD_CONFIG" ]; then
  if grep -q "pollingInterval: 30000" "$SCAFFOLD_CONFIG"; then
    perl -i -pe 's/pollingInterval:\s*30000/pollingInterval: 3000/g' "$SCAFFOLD_CONFIG"
    note_applied "pollingInterval: 3000 in scaffold.config.ts"
  else
    note_applied "scaffold.config.ts already has non-default pollingInterval (no change)"
  fi
else
  note_warn "scaffold.config.ts not found at $SCAFFOLD_CONFIG"
fi

# ─── 9. Patch package.json build script for the polyfill ────────────────────
echo "[9/9] Patching nextjs package.json build script for polyfill"
PKG_JSON="$NEXTJS_DIR/package.json"
if [ -f "$PKG_JSON" ]; then
  if ! grep -q "polyfill-localstorage.cjs" "$PKG_JSON"; then
    # Find the build script and prepend the NODE_OPTIONS. Keep it minimal:
    # just match `"build": "next build"` and replace with the polyfilled form.
    perl -i -pe 's|"build":\s*"next build"|"build": "NODE_OPTIONS=\\"--require ./polyfill-localstorage.cjs\\" next build"|g' "$PKG_JSON"
    if grep -q "polyfill-localstorage.cjs" "$PKG_JSON"; then
      note_applied "package.json build script wrapped with NODE_OPTIONS polyfill"
    else
      note_warn "could not auto-patch package.json build script — wrap manually with NODE_OPTIONS=\"--require ./polyfill-localstorage.cjs\""
    fi
  else
    note_applied "package.json build script already references the polyfill"
  fi
fi

# ─── Best-effort: patch contract.ts getParsedErrorWithAllAbis ───────────────
echo ""
echo "[bonus] Best-effort patch of getParsedErrorWithAllAbis"
CONTRACT_TS="$NEXTJS_DIR/utils/scaffold-eth/contract.ts"
if [ -f "$CONTRACT_TS" ]; then
  # Two patterns to spot the buggy version (which only walks deployedContractsData).
  if grep -q "getParsedErrorWithAllAbis" "$CONTRACT_TS" \
    && grep -q "deployedContractsData as Record" "$CONTRACT_TS"; then
    perl -i -pe 's|deployedContractsData as Record<number, Record<string, any>>|contractsData as Record<number, Record<string, any>>|g' "$CONTRACT_TS"
    if grep -q "contractsData as Record<number" "$CONTRACT_TS"; then
      note_applied "getParsedErrorWithAllAbis now walks merged contractsData (was deployedContractsData)"
    else
      note_warn "contract.ts patch attempted but post-condition not met — verify manually"
    fi
  elif grep -q "contractsData as Record<number" "$CONTRACT_TS"; then
    note_applied "contract.ts already patched (contractsData merge)"
  else
    note_warn "contract.ts shape unrecognized — patch getParsedErrorWithAllAbis by hand if external contract errors don't decode"
  fi
fi

# ─── gitignore additions ────────────────────────────────────────────────────
echo ""
echo "[bonus] gitignore"
GI="$BUILD_DIR/.gitignore"
if [ -f "$GI" ]; then
  for line in ".env" ".env.local" "ipfs-upload.config.json" "packages/nextjs/out" "packages/nextjs/.next"; do
    if ! grep -qxF "$line" "$GI"; then
      echo "$line" >>"$GI"
      note_applied "added '$line' to .gitignore"
    fi
  done
fi

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary ==="
echo "Applied: ${#APPLIED[@]} fix(es)"
echo "Warnings: ${#WARNINGS[@]}"

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo ""
  echo "Manual review needed:"
  for w in "${WARNINGS[@]}"; do
    echo "  ⚠ $w"
  done
fi

echo ""
echo "Still up to the agent (project-specific):"
echo "  • Header.tsx — project nav and branding"
echo "  • Footer.tsx — project copy and links"
echo "  • app/layout.tsx — title, description, fonts"
echo "  • app/page.tsx + sub-routes — the actual app"
echo "  • README.md — project description"
echo "  • Favicon (public/favicon.svg) and OG image (public/og.png)"
echo "  • externalContracts.ts — tokens with full OZ v5 ABIs incl. custom errors"
echo "  • scaffold.config.ts targetNetworks (verify [chains.base])"
echo "  • appName in wagmiConnectors.tsx — project name (was \"scaffold-eth-2\")"
echo "  • Phantom wallet add to wagmiConnectors.tsx connectors array"
echo "  • Remove bare http() fallback transports from wagmiConfig.tsx"
