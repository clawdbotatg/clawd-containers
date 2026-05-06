#!/bin/bash
# Read a single job from the leftclaw contract and emit its fields as JSON.
#
# Usage: get-job.sh <job_id>
#
# Strategy: pull raw ABI-encoded return data via `cast call`, then locate
# the description string by hex-decoding all bytes and finding the longest
# run of printable text (the description is human-prose, will dominate).
# Also extract the obvious fields (id, client, serviceTypeId) from known
# positions, plus status as a small uint heuristic.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 <job_id>" >&2; exit 2; }
: "${ALCHEMY_API_KEY:?ALCHEMY_API_KEY not set}"

CONTRACT="0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a"
RPC="https://base-mainnet.g.alchemy.com/v2/$ALCHEMY_API_KEY"

raw="$(cast call "$CONTRACT" "getJob(uint256)" "$1" --rpc-url "$RPC")"

python3 - "$1" "$raw" <<'PY'
import sys, json, re

job_id = int(sys.argv[1])
raw = sys.argv[2]
hx = raw[2:] if raw.startswith("0x") else raw
data = bytes.fromhex(hx)

# 32-byte words (the ABI tuple body starts at byte 32 — first word is the
# outer-tuple offset 0x20).
words = [data[i:i+32] for i in range(0, len(data), 32)]
def w_uint(i): return int.from_bytes(words[i], "big")
def w_addr(i): return "0x" + words[i][-20:].hex()

# Known slots (verified against on-chain data for jobs 88 / 91):
#   word[1] = id
#   word[2] = client
#   word[3] = serviceTypeId
# Beyond that the public docs and deployed ABI disagree, so we use heuristics.
out = {
    "id": w_uint(1) if len(words) > 1 else None,
    "client": w_addr(2) if len(words) > 2 else None,
    "serviceTypeId": w_uint(3) if len(words) > 3 else None,
}

# status: smallest uint8-shaped value (0..3) appearing after the
# serviceTypeId slot but BEFORE any obvious string-offset slot.
status = None
for i in range(4, min(len(words), 24)):
    v = w_uint(i)
    if 0 <= v <= 3:
        status = v
        break
out["status"] = status

# worker: an address slot (last 20 bytes nonzero, first 12 bytes all zero)
# appearing at position > 3. Take the LAST such slot before the dynamic
# data section (heuristic: stop when we hit a value that looks like a string
# offset, > 0x40).
worker = None
for i in range(4, min(len(words), 24)):
    word = words[i]
    if word[:12] == b"\x00" * 12 and word[12:] != b"\x00" * 20:
        v = int.from_bytes(word, "big")
        # Plausible address: not a small uint, not absurdly huge
        if 2**40 <= v < 2**160:
            worker = "0x" + word[-20:].hex()
out["worker"] = worker

# Description: longest printable-text run in the payload, >= 16 chars.
# Decode the full payload as UTF-8 with errors='replace' so multi-byte
# characters (em-dash, smart quotes) stay intact. The regex matches any
# printable Unicode plus newline/tab — printable as Python defines it
# excludes \x00..\x1f except \n\t.
text = data.decode("utf-8", errors="replace")
# Use a finditer + manual scan so we don't depend on overcomplicated regex.
runs = []
buf = []
for ch in text:
    if ch == "\n" or ch == "\t" or (ch >= " " and ch.isprintable()):
        buf.append(ch)
    else:
        if len(buf) >= 16:
            runs.append("".join(buf))
        buf = []
if len(buf) >= 16:
    runs.append("".join(buf))
runs.sort(key=len, reverse=True)

# Filter out runs that are clearly junk (only digits/whitespace, only zero bytes-as-text)
def looks_real(s):
    s = s.strip()
    if len(s) < 16: return False
    # Too many non-letter chars => junk
    letters = sum(1 for c in s if c.isalpha())
    return letters >= 6

runs = [r for r in runs if looks_real(r)]
out["description"] = runs[0] if runs else None
out["_other_strings"] = runs[1:5]  # cap to 4

print(json.dumps(out, indent=2))
PY
