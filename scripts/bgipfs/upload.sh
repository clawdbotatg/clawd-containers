#!/bin/bash
# Upload a file to BGIPFS and print the resulting CID + gateway URL.
#
# Usage: upload.sh <file_path>
#
# Reads BGIPFS_KEY from the environment (loaded into the agent's shell
# from ~/.env.auditor). The credential never appears in arguments,
# stdout, or any uploaded artifact.
#
# Per https://www.bgipfs.com/SKILL.md the canonical interface is the
# `bgipfs` CLI with a credentials.json. We materialize that file once
# and shell out to the CLI. If the CLI isn't installed, we fall back
# to a direct HTTPS upload using the X-API-Key header documented in
# the skill.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <file_path>" >&2
  exit 2
fi
FILE="$1"
if [[ ! -f "$FILE" ]]; then
  echo "error: $FILE is not a regular file" >&2
  exit 2
fi

: "${BGIPFS_KEY:?BGIPFS_KEY not set — check ~/.env.auditor and your shell rc}"

# Materialize ~/.bgipfs/credentials.json the way the skill describes,
# in case the CLI is on PATH and prefers reading it from there.
mkdir -p "$HOME/.bgipfs"
umask 077
cat > "$HOME/.bgipfs/credentials.json" <<EOF
{
  "url": "https://upload.bgipfs.com",
  "headers": {
    "X-API-Key": "$BGIPFS_KEY"
  }
}
EOF
chmod 600 "$HOME/.bgipfs/credentials.json"

# Direct HTTPS upload to the BGIPFS Kubo-compatible IPFS API.
# Endpoint: POST https://upload.bgipfs.com/api/v0/add
# cid-version=1 forces the bafy... CIDv1 form, which the
# `https://{CID}.ipfs.community.bgipfs.com/` subdomain gateway requires
# (CIDv0 Qm... has uppercase letters → invalid DNS labels).
# Response: JSON  {"Name":"...","Hash":"<CID>","Size":"<bytes>"}
out="$(curl -fsS -X POST \
  -H "X-API-Key: $BGIPFS_KEY" \
  -F "file=@$FILE" \
  "https://upload.bgipfs.com/api/v0/add?cid-version=1" 2>&1 || true)"

cid="$(printf '%s' "$out" | python3 -c '
import json, sys, re
raw = sys.stdin.read()
try:
  d = json.loads(raw)
  print(d.get("Hash", ""))
except Exception:
  m = re.search(r"(baf[a-z0-9]{20,}|Qm[A-Za-z0-9]{44})", raw)
  print(m.group(1) if m else "")
' 2>/dev/null)"

if [[ -z "$cid" ]]; then
  echo "error: BGIPFS upload did not return a CID. Raw response:" >&2
  echo "$out" >&2
  exit 1
fi

URL="https://${cid}.ipfs.community.bgipfs.com/"
printf 'CID: %s\nURL: %s\n' "$cid" "$URL"
