# scripts

Deterministic helpers the agent calls to perform credentialed or
on-chain actions. The agent invokes the scripts as plain CLIs; the
scripts read secrets from the env (loaded from `~/.env.auditor`) and
handle authentication internally.

## Why

Smart-contract audit agents need to: read jobs, sign on-chain
transactions, upload reports to IPFS, etc. Letting the agent build and
sign these transactions itself — and read API keys with `printenv` —
matches the prompt-injection / credential-exfiltration patterns Claude
Code refuses (correctly). Wrapping the credentialed actions in scripts
and exposing only a clean CLI to the agent removes the blast radius
without removing the autonomy.

## Layout

```
scripts/
├── bgipfs/
│   ├── README.md
│   └── upload.sh
└── leftclaw/
    ├── README.md
    ├── accept.sh
    ├── complete.sh
    ├── decline.sh
    ├── get-job.sh
    ├── list-jobs.sh
    ├── log-work.sh
    └── sanitize-check.sh
```

## Per-agent selection

Each `provisionXxxAgent.sh` decides which script families to install
into the VM. The auditor installs `bgipfs/` and `leftclaw/`; a future
QA agent might install `leftclaw/` only.

`cont provision` scps the entire `scripts/` directory into `/tmp/scripts/`
and `skills/` into `/tmp/skills/`. The provision script copies just the
families it needs from `/tmp/scripts/<family>/` to `~/scripts/<family>/`.

## Adding a new script family

1. Create `scripts/<family>/` with one or more executable `.sh` files.
2. Add a `scripts/<family>/README.md` explaining each script's args and
   any env vars it expects.
3. In your `provisionXxxAgent.sh`, copy `/tmp/scripts/<family>/` to
   `~/scripts/<family>/` and `chmod +x` the files.
4. Reference the scripts in the agent prompt by their installed path.
