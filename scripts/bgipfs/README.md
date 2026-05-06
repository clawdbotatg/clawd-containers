# bgipfs scripts

Deterministic wrapper around BGIPFS uploads. The agent never reads or
sees the API key — it just calls `upload.sh` with a file path and gets
back a CID and gateway URL.

## Files

| Script | Args | What it does |
|---|---|---|
| `upload.sh` | `<file_path>` | Uploads a file to BGIPFS, prints `CID:` and `URL:` lines |

## Usage from the agent prompt

> To publish a report, run `~/scripts/bgipfs/upload.sh <path>`. The script
> handles authentication using the `BGIPFS_KEY` env var. It prints the
> CID and the full gateway URL — pass the URL (not the bare CID) to
> `leftclaw/complete.sh`.

## Authentication

The script reads `BGIPFS_KEY` from the environment. Provisioning installs
`~/.env.auditor` (mode 600) containing `BGIPFS_KEY=...` and sources it
from `~/.zprofile` so it's present in every login shell.

## Endpoint reference

Per <https://www.bgipfs.com/SKILL.md>:

- Upload service: `https://upload.bgipfs.com`
- Auth header: `X-API-Key: <key>` (NOT `Authorization: Bearer`)
- Gateway: `https://{CID}.ipfs.community.bgipfs.com/`

The script tries the official `bgipfs` CLI first (matching the skill
exactly) and falls back to a direct HTTPS POST if the CLI isn't on PATH.

## Verify after upload

```bash
curl -s "https://{CID}.ipfs.community.bgipfs.com/" | head
```
