#!/usr/bin/env bash
# leftclaw-bgipfs-ship.sh — upload a built static export to BGIPFS, verify, commit.
#
# Usage:  scripts/leftclaw-bgipfs-ship.sh <build-dir> [<jobId>]
#
# <build-dir> is the project root (e.g. /…/builds/leftclaw-service-job-99).
# <jobId> is optional and used only for the commit message.
#
# Steps:
#   1. Verify packages/nextjs/out/ exists and is non-empty (else: instruct to yarn build)
#   2. Source BGIPFS_TOKEN from servicer .env
#   3. Init bgipfs config with BOTH --apiKey AND --nodeUrl (silent-localhost
#      footgun is the only reason this script exists)
#   4. Verify ipfs-upload.config.json doesn't point at localhost
#   5. Upload, capture CID
#   6. curl HTTP 200 on the gateway URL
#   7. Write/update DEPLOYMENT.md + README.md "Live URL" section
#   8. Commit + push to clawdbotatg
#
# Returns the structured 4-line block:
#   LIVE_URL: …
#   CID: …
#   HTTP_STATUS: 200
#   COMMIT: …

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 <build-dir> [<jobId>]" >&2
  exit 2
fi

BUILD_DIR="$(cd "$1" && pwd)"
JOB_ID="${2:-}"
OUT_DIR="$BUILD_DIR/packages/nextjs/out"

if [ ! -d "$OUT_DIR" ] || [ -z "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
  echo "FAIL: $OUT_DIR is missing or empty. Run 'yarn build' from $BUILD_DIR first." >&2
  exit 1
fi

# Token: prefer BGIPFS_TOKEN (the name ethereum-servicer + bgipfs CLI use).
# Fall back to BGIPFS_KEY (the name our existing scripts use). Both should
# already be in the shell env via ~/.zprofile sourcing ~/.env.builder.
TOKEN="${BGIPFS_TOKEN:-${BGIPFS_KEY:-}}"
if [ -z "$TOKEN" ]; then
  echo "FAIL: neither BGIPFS_TOKEN nor BGIPFS_KEY set in env. Source ~/.env.builder." >&2
  exit 1
fi
export BGIPFS_TOKEN="$TOKEN"

cd "$BUILD_DIR"

# Ensure ipfs-upload.config.json is gitignored before init writes it.
if [ -f .gitignore ] && ! grep -q "^ipfs-upload.config.json$" .gitignore; then
  echo "ipfs-upload.config.json" >>.gitignore
fi

# Step 3: init config — both flags mandatory (the entire reason for this script).
echo "=== Initializing bgipfs config ==="
npx --no-install bgipfs upload config init --apiKey "$BGIPFS_TOKEN" --nodeUrl https://upload.bgipfs.com >/dev/null

# Step 4: assert the config didn't silently default to localhost.
if [ -f ipfs-upload.config.json ] && grep -q "localhost" ipfs-upload.config.json; then
  echo "FAIL: ipfs-upload.config.json points at localhost — re-run with explicit --nodeUrl" >&2
  rm -f ipfs-upload.config.json
  exit 1
fi

# Step 5: upload and capture CID. bgipfs prints the CID in stdout; we grep for
# the 'bafy…' v1 CID pattern (length ~59 chars).
echo "=== Uploading packages/nextjs/out/ ==="
UPLOAD_OUTPUT="$(npx --no-install bgipfs upload packages/nextjs/out 2>&1)"
echo "$UPLOAD_OUTPUT"
CID=$(echo "$UPLOAD_OUTPUT" | grep -Eo 'bafy[a-z0-9]{50,}' | head -1)

if [ -z "$CID" ]; then
  echo "FAIL: could not parse CID from bgipfs output" >&2
  exit 1
fi

LIVE_URL="https://${CID}.ipfs.community.bgipfs.com/"

# Step 6: HTTP 200 verification. Retry once after 30s for slow propagation.
echo "=== Verifying live URL ==="
for attempt in 1 2; do
  STATUS=$(curl -sLo /dev/null --max-time 15 -w "%{http_code}" "$LIVE_URL" 2>/dev/null || echo "000")
  if [ "$STATUS" = "200" ]; then break; fi
  if [ "$attempt" = "1" ]; then
    echo "  HTTP $STATUS on first attempt — waiting 30s for propagation"
    sleep 30
  fi
done

if [ "$STATUS" != "200" ]; then
  echo "FAIL: live URL returned HTTP $STATUS after retry" >&2
  echo "  URL: $LIVE_URL" >&2
  exit 1
fi

# Step 7: write DEPLOYMENT.md.
DEPLOY_DATE=$(date -u +%Y-%m-%d)
cat >DEPLOYMENT.md <<EOF
# Deployment

**Live URL:** $LIVE_URL
**CID:** $CID
**Deployed:** $DEPLOY_DATE

Static export uploaded to BGIPFS. The CID is content-addressed: every byte of
\`packages/nextjs/out/\` is included. To redeploy, rebuild and re-upload — a
new CID will be issued for any change.
EOF

# Update README.md "Live URL" line if present, else prepend a fenced section.
if [ -f README.md ]; then
  if grep -q "Live URL" README.md; then
    # Replace the line containing "Live URL" with the new one.
    perl -i -pe 's|^.*Live URL.*$|**Live URL:** '"$LIVE_URL"'|m' README.md
  else
    # Prepend after the first H1 line.
    perl -i -pe '
      if (!$done && /^# /) { $done = 1; $_ .= "\n**Live URL:** '"$LIVE_URL"'\n"; }
    ' README.md
  fi
fi

# Step 8: commit + push as clawdbotatg.
COMMIT_MSG="deploy: ship to BGIPFS — ${CID:0:12}…"
if [ -n "$JOB_ID" ]; then
  COMMIT_MSG="deploy: ship job #$JOB_ID to BGIPFS — ${CID:0:12}…"
fi

git add -A
if git diff --cached --quiet; then
  echo "  (no uncommitted changes — DEPLOYMENT.md and README.md were already up to date)"
  COMMIT_SHA=$(git rev-parse HEAD)
else
  git config user.email "clawd@buidlguidl.com"
  git config user.name "clawdbotatg"
  git commit -m "$COMMIT_MSG" >/dev/null
  git push >/dev/null 2>&1 || git push -u origin main >/dev/null 2>&1
  COMMIT_SHA=$(git rev-parse HEAD)
fi

# Final structured output — what the orchestrator parses.
echo ""
echo "LIVE_URL: $LIVE_URL"
echo "CID: $CID"
echo "HTTP_STATUS: 200"
echo "COMMIT: $COMMIT_SHA"
