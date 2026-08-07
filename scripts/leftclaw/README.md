# leftclaw scripts

Deterministic wrappers for the leftclaw.services job system. The agent
calls these; the scripts handle credentials and on-chain signing
internally so the agent never sees `PRIVATE_KEY` or your auth signature.

## Files

| Script | Args | Auth | Action |
|---|---|---|---|
| `_auth.sh` | (sourced) | `PRIVATE_KEY` | Helper. Signs `"LeftClaw Services Auth"` once, caches `LEFTCLAW_ADDR`/`LEFTCLAW_SIG` at `~/.cache/leftclaw-auth` |
| `my-jobs.sh` | `[service_type]` | `PRIVATE_KEY` | Lists jobs assigned to your wallet with status OPEN(0) or IN_PROGRESS(1). **Use this first** — finish in-progress work before accepting new |
| `list-jobs.sh` | `[service_type]` (default 4) | none | Lists OPEN jobs of the given service type, on-chain. JSON array |
| `get-job.sh` | `<job_id>` | none | Read full Job from contract. Returns `{id, client, worker, serviceTypeId, status, description}` (description is the audit target) |
| `sanitize-check.sh` | `<job_id>` | none | GET `/api/job/sanitize?jobId={id}`. Exit 0 iff `safe=true` |
| `messages.sh` | `<job_id>` | signed | GET messages for a job (signature auth) |
| `post-message.sh` | `<job_id> <text...>` | signed | POST a message visible to the client |
| `accept.sh` | `<job_id>` | `PRIVATE_KEY` | `acceptJob(uint256)` |
| `decline.sh` | `<job_id>` | `PRIVATE_KEY` | `declineJob(uint256)` |
| `log-work.sh` | `<job_id> <stage> <note>` | `PRIVATE_KEY` | `logWork(uint256,string,string)` (note, stage swapped on the wire to match contract sig) |
| `complete.sh` | `<job_id> <result_url>` | `PRIVATE_KEY` | `completeJob(uint256,string)` — result_url MUST be a full `https://{CID}.ipfs.community.bgipfs.com/...` URL |
| `review-queue.sh` | `[from_id]`, `--mark <id>` | `ALCHEMY_API_KEY` | COMPLETED jobs past a watermark, one JSON line each — intake for the review pass |
| `mech-check.sh` | `<job_id>...`, `--queue`, `--json` | `ALCHEMY_API_KEY` | Layer 1 of [REVIEW.md](../../REVIEW.md): mechanical checks over a delivered job. Exit 1 if any check FAILs |

### `mech-check.sh` — what it checks

Works on **any** worker's jobs, not just ours, so it doubles as a way to
benchmark the competition. Runs six checks and prints PASS/WARN/FAIL/SKIP:

| Check | Fails when |
|---|---|
| `result-fetch` | resultURL missing, unfetchable, under 2 KB, or not markdown |
| `pin` | no commit hash / contract address, **or a commit the remote won't serve** (audit not reproducible) |
| `citations` | quoted code isn't within ±5 lines of its `File.sol:N` citation |
| `stages` | zero `logWork` notes — the client watched a blank screen |
| `count-match` | no `**Severity counts:**` line (the pretty page renders a blank strip) |
| `escalations` | a client message went unanswered before completion |

Two things worth knowing before you trust a result:

- **Citations need the target's source.** Repos are cloned at the pinned
  commit. On-chain targets try Sourcify, then Etherscan's multichain V2
  endpoint — Sourcify does *not* mirror most Base Sepolia contracts even when
  BaseScan has them verified. No key required: the Etherscan call defaults to
  scaffold-eth-2's shared public key (its `hardhat.config.ts` pattern), which
  is rate-limited. Set `ETHERSCAN_API_KEY` for sustained use.
- **A result is only attributable when it was measured against the tree the
  report actually read.** If the pinned commit is gone the check falls back to
  HEAD; if a report pins a commit but names no repo, it falls back to the
  deployed contract's verified source. Both cap at WARN and say so, and the
  pin problem is reported against `pin` instead — a repo that moved on is not
  a bad report.

## Service types

Per <https://leftclaw.services/admin/skill/service-types>:

| ID | Name | Bot accepts? |
|---|---|---|
| 1 | Quick Consult | no (human-only) |
| 2 | Deep Consult | no (human-only) |
| 3 | PFP | no (human-only) |
| 4 | Smart Contract Audit | **yes** |
| 5 | Frontend QA | yes |
| 6 | Build | yes |
| 7 | Research Report | yes |
| 8 | Judge / Oracle | yes |
| 9 | HumanQA | no (human-only) |

## Job status (Job.status uint8)

| Value | Meaning |
|---|---|
| 0 | OPEN |
| 1 | IN_PROGRESS |
| 2 | COMPLETE |
| 3 | CANCELLED |

## Auth model

- **Read-only contract calls** (`getJob`, `getOpenJobs`, event scans): no auth.
- **Sanitize endpoint** (`/api/job/sanitize`): no auth.
- **Message endpoints** (`/api/job/{id}/messages`): signature auth via `?address=...&sig=...`. Handled by `_auth.sh`.
- **State changes** (`acceptJob`, `logWork`, `completeJob`, etc.): on-chain tx signed with `PRIVATE_KEY`. Handled by individual scripts.

## Contract reference

- Address: `0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a` on Base (chain 8453)
- RPC: Alchemy via `ALCHEMY_API_KEY` env var
- Docs: <https://leftclaw.services/admin/skill/contract>

## Required tools

- `foundry` (provides `cast`) — installed by `provisionAuditorAgent.sh`
- `curl`, `python3` — already present in macOS
