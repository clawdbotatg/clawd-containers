# The audit scope gate — how it works, how it broke, how to test it

Handoff doc. Written 2026-08-17/18 after the gate auto-declined and
**refunded five good jobs from one client**. Read this before touching
`scripts/audit/complexity-check.sh` or `self_update` in `agent-wrangler.sh`.

---

## 1. What the gate is and why it must exist

`scripts/audit/complexity-check.sh <job_id>` estimates how much Solidity a
Smart Contract Audit job (service type 4) really contains, and votes
`ok` or `too_complex`. The wrangler pre-flights **every open type-4 job**
with it and, on `too_complex`, messages the client and calls
`declineJob` — which refunds them.

It exists because of one asymmetry in the contract
(`0xb2fb486a9569ad2c97d9c73936b46ef7fdaa413a` on Base, chain 8453):

> `declineJob` (selector `0xe0d1efc8`) only works while the job is **OPEN**.
> `acceptJob` moves escrow to treasury **irreversibly**, and there is no path
> out of IN_PROGRESS except the assigned worker's `completeJob`.

So an oversized job must be caught *before* anything accepts it. A job we
accept and cannot finish locks its escrow forever. That pressure is why the
gate runs early, fast, and unattended — and why a false `too_complex` is
expensive: it hands a paying client their money back in about 30 seconds.

**The budget measures LINES, not targets.** Ten small contracts are fine;
one 24KB monolith is not (job 326 time-capped forever at 3,788 LoC; job 443
was 10 contracts, several at the EIP-170 cap). `MAX_AUDIT_SOL_LOC` defaults
to 3000.

**It fails open on purpose.** An unmeasurable target counts 0. A probe
failure must never refuse a paying client. Keep that property.

---

## 2. How it measures

**Target discovery (description text only, no auth):**

| form | handling |
|---|---|
| `0x…` addresses | after an explicit scope marker if present, else all unique ones |
| GitHub repo URL | only when there are **no** addresses (both = the repo is just the source of the deployed address; jobs 422/430), and never when the text says "do not use GitHub" (job 427) |
| GitHub **blob** URL | **one file at one ref** — resolved to `raw.githubusercontent.com` and counted alone. Not its repo. |
| raw `.sol` URL | fetched directly (jobs 629, 647, 616) |
| IPFS CID | fetched through three gateways (job 672) |

A `NEGATION_RE` window (±120 chars) around each URL drops anti-targets
("do not use", "legacy", "private").

**Per-target LoC:** Sourcify verified sources when available; else
`eth_getCode` bytes ÷ `BYTES_PER_LOC` (20, calibrated on the leftclaw
contract: 23,139 runtime bytes ↔ 1,268 source LoC ≈ 18/line); else a
shallow repo clone.

**The section counter (`count_sol`) is the important part.** Every source
is split at top-level `contract`/`library`/`interface` declarations, and a
section is dropped when:

1. its header comment names a known library (`openzeppelin|forge-std|solady|solmate`), **or**
2. its **declared name** is a known dependency primitive (`KNOWN_LIB_DECLS` + any `IERC\d+`), **or**
3. its content hash was already counted elsewhere in this job (flattened dupes — job 440 shipped five `.flat.sol` supersets of each other).

Rule 2 is one-directional (it can only lower the count) and **never drops
the last section in a file**, because a flattener emits the audit target
last — so a project contract that happens to be named `Math` is safe.

**Results are cached** per (job, description-hash) in
`~/.cache/leftclaw-complexity/`. The wrangler re-runs the gate every tick,
and measurement costs network calls.

> ⚠️ **A cached verdict outlives the code that produced it.** After any
> change to the gate you must `rm -f ~/.cache/leftclaw-complexity/*.out`,
> or a stale `too_complex` keeps refunding jobs the new gate accepts.
> `self_update` now does this automatically on every pull.

---

## 3. The 2026-08-17 incident

**Job 643** was a 100-line contract (`FixedFeeSink`, lines 3664–3763 of a
flattened file), shipped as a GitHub blob URL pinned to commit
`bb9ffbf8`. We declined it **36 seconds after it was posted** — 18 blocks,
creation `50040368` → decline `50040386`, tx
`0xe6c3a90d…1734404` from our own wallet `0xd98728b9…`.

**The mechanism, in order:**

1. `REPO_RE` matched the `github.com/owner/repo` prefix **inside the blob
   URL**, so the gate treated one file as a whole-repo target.
2. It shallow-cloned the **default branch**. The pinned commit is not the
   tip, and the `audit2/` tree does not exist there.
3. The "narrow to named `.sol` files" step therefore matched nothing —
   and **silently fell back to "the whole repo is the scope."**
4. 55 `.sol` files → 11,028 LoC vs a 3,000 budget → `too_complex` →
   `declineJob` → refund.

Real scope: **87 non-blank lines.**

Step 3 is the actual villain. A narrowing step whose failure mode is
"measure something 100× bigger instead" will eventually fire.

**Blast radius — the same 11,028 killed five jobs:**

| job | old | new | note |
|---|---|---|---|
| 633 | too_complex 11028 | **ok 1074** | wrongly refunded |
| 634 | too_complex 11028 | **ok 132** | wrongly refunded |
| 635 | too_complex 11028 | **ok 2548** | wrongly refunded |
| 641 | too_complex 11028 | **ok 13** | wrongly refunded |
| 643 | too_complex 11028 | **ok 132** | wrongly refunded |
| 586 | too_complex 11028 | too_complex 6163 | correct — whole repo |
| 621 | too_complex 11028 | too_complex 3609 | correct — 3-file batch |

**The part that should sting:** the client kept re-posting in ever smaller,
better-scoped chunks — 586 (repo) → 621 (3-file batch) → 633/635 (single
files) → 641/643 (single contract, explicit line range). That is *exactly*
what our decline message asks them to do. We refunded every attempt with
the same fabricated number.

**All five declines were ours.** Two of the declining wallets were logged in
memory as "rival snipers"; they are our own boxes. Before calling any taker
a competitor, check the wallet against §6.

---

## 4. What was fixed

| commit | change |
|---|---|
| `a6f0f84` | `BLOB_RE` — a blob URL is one file at one ref, resolved to raw and counted alone; its `owner/repo` prefix no longer registers as a repo target. Plus `KNOWN_LIB_DECLS` name-based dependency dropping. Plus pinned-ref checkout so named-file narrowing measures the package the client actually pinned. |
| `6ebec01` | Gate's own git calls can never block on a credential dialog. |
| `eca84b9` | `self_update` in the wrangler — push to main deploys fleet-wide. |
| `66b97d7` | CLAUDE.md deploy section. |
| *(this one)* | `self_update` ignores **untracked** files; only tracked modifications count as "live editing". |

On the pinned-ref work: a branch name can contain slashes (job 621's ref is
`audit2/round9-batched-20260814`) and nothing in the URL says where the ref
ends and the path begins, so the first few path prefixes are offered as
candidates — bounded at 4 tries, 45s each, and any failure just leaves the
default branch.

---

## 5. How to test it — the calibration set

**Run the whole set once, at the end.** Do not re-run it after each
increment; it is network-bound and one bad repo used to hang for minutes.

Patch the gate in a `git worktree` (see §7), then diff the two copies
job-for-job. Give each side its **own** cache dir or you are comparing a
cached verdict against itself.

```bash
cd ~/clawd/clawd-harness/projects/clawd-containers
set -a; source .env.auditor; set +a          # needs ALCHEMY_API_KEY
OLD=/tmp/cc-old; NEW=/tmp/cc-new; rm -rf $OLD $NEW
PATCHED=/path/to/worktree/scripts/audit/complexity-check.sh

for j in 586 600 617 621 633 634 635 639 641 643 658 668 \
         443 422 374 440 672 629 647 616 427 430; do
  o=$(LEFTCLAW_COMPLEXITY_CACHE=$OLD ./scripts/audit/complexity-check.sh $j \
        2>/dev/null | sed -n '1p;3p' | tr '\n' ' ')
  n=$(LEFTCLAW_COMPLEXITY_CACHE=$NEW "$PATCHED" $j \
        2>/dev/null | sed -n '1p;3p' | tr '\n' ' ')
  if [ "$o" = "$n" ]; then printf '%-5s SAME     %s\n' "$j" "$n"
  else printf '%-5s CHANGED\n  old: %s\n  new: %s\n' "$j" "$o" "$n"; fi
done
```

**Expected verdicts after the fix** (LoC may drift as clients edit repos;
the *verdicts* are the contract):

```
ok:           422 374 440 672 629 647 616 427 430 600 617 639 658 668
              633 634 635 641 643
too_complex:  443 586 621
```

Three of these are load-bearing and must never flip:

- **443** — 10 targets / 6820 LoC. The oversize guard. If this goes `ok`,
  the name-based dropping in §2 rule 2 has become too aggressive.
- **586 / 621** — a whole repo and a 3-file batch. Genuinely too big. If
  these go `ok`, the blob/narrowing logic is now under-counting real scope.

`440` clones a private-or-deleted repo; it must return in ~1s, not 120s. If
it hangs, the no-prompt git flags in §7 regressed.

---

## 6. Fleet topology — three boxes, and two of them have no ssh

The wrangler runs on **clawd-head, clawd-sat, clawd-leftclaw**. Those are
the only machines with `clawd-containers` on disk (clawd-gut, clawd-heart
and clawd-antenna were checked and do not have it).

| wallet | box | file |
|---|---|---|
| `0xEE8f4Bf7…377c` | clawd-head | `.env.auditor` (+ builder/research/feature/frontend-qa) |
| `0xDB5465EA…0f6C` | clawd-head | `.env.auditor2` |
| `0xB2109c9C…21AD` | clawd-leftclaw | `.env.auditor` (+ the others) |
| `0x8F5d03C5…5359` | clawd-leftclaw | `.env.auditor2` |
| `0xd98728b9…636a` | clawd-sat | `.env.auditor` (inferred: it declined 586/600/633/641/643/658 and sat is the third box) |
| `0x024771c8…6be4` | **unknown** | possibly a genuine third party |

**`clawd-sat` and `clawd-leftclaw` have no ssh route from clawd-head** —
their `.local` mDNS names do not resolve off-LAN. Drive them through the
fleet controller instead:

```bash
# 1. who is online, and which boxes have the repo
ssh zkllmapi 'curl -s http://127.0.0.1:8799/api/world' | python3 -c "import sys,json
d=json.load(sys.stdin)
for m in d['machines']:
    ep=m.get('empty_projects',[])+[p['name'] for p in m.get('projects',[])]
    print(m['id'], m.get('connected'), 'clawd-containers' in ep)"

# 2. spawn a session.  pid 'self' is a STABLE pid on every harness — use it.
ssh zkllmapi "curl -s -X POST http://127.0.0.1:8799/api/tool \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"spawn\",\"args\":{\"machine\":\"clawd-sat\",\"pid\":\"self\",\"confirm\":true}}'"

# 3. drive it (write the JSON to a file and --data-binary it; quoting is brutal)
#    {"name":"ask","args":{"machine":"…","cid":"…","text":"…","confirm":true}}

# 4. read what it did — NOT the digest, see §7
ssh zkllmapi "curl -s -X POST http://127.0.0.1:8799/api/tool \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"transcript_tail\",\"args\":{\"machine\":\"clawd-sat\",\"cid\":\"…\",\"n\":6}}'"
```

Why `pid: "self"`: the world API omits pids for projects with no sessions,
so a quiet box exposes **no pid you could spawn into**. The harness always
injects itself as the pinned project `self`, so that one always works.

**Restarting a wrangler** (only needed to bootstrap a change to
`agent-wrangler.sh` itself on a box still running the pre-`self_update`
copy):

```bash
launchctl kickstart -k gui/$(id -u)/com.leftclaw.wrangler
```

Use `kickstart -k` only. Never `bootout` / `disable` / `unload` — a
disabled job stays dead silently and that box stops taking jobs entirely.

---

## 7. Traps, all of them found the hard way

**Deploy is `git push`, and two things silently block it.** Every box runs
`self_update` (5 min: on main + no tracked modifications + `--ff-only`).

- A **tracked** modification means someone is live-editing → skipped on
  purpose. Fine, but don't leave one behind.
- **Untracked files used to block it too, and that was wrong.** clawd-head
  sat out every update for a whole morning over two stray `.md` notes an
  agent left in the tree. Now only tracked changes count; an untracked file
  that would genuinely be clobbered is still safe because `pull --ff-only`
  refuses that case itself and changes nothing.
- A **diverged branch** blocks it and should. clawd-sat had accumulated
  **five unpushed commits** of real work. `--ff-only` refuses to guess; a
  human (or a driven session) must rebase and push. Don't let work sit on
  one box.

**macOS pops a GUI login dialog even with `GIT_TERMINAL_PROMPT=0`.** The
osxkeychain credential helper is a separate path. A private-or-deleted
client repo blocked the gate ~2 minutes per run, on an unattended box,
invisibly. Every git call the fleet makes now carries:

```bash
GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/echo git -c credential.helper= …
```

and for pushes/pulls that need real auth, `-c credential.helper='!gh auth git-credential'`.

**bash 3.2 + `set -u` makes an empty array expansion fatal.** launchd's bare
PATH finds `/bin/bash` (3.2 on macOS), where `"${ARR[@]}"` on an empty array
raises *unbound variable*. Use `${ARR[@]+"${ARR[@]}"}`. Test scripts under
**both** `/bin/bash` and `/opt/homebrew/bin/bash` — this repo's shebang is
`#!/usr/bin/env bash`, so which one runs depends on the invoking PATH.

**Session digests in the fleet world API lag.** A box that has already
finished can still read `working :: <stale summary>`. Judge by
`transcript_tail`, never by the digest. `transcript_tail` itself truncates
long replies — ask for the specific line you need rather than the essay.

**A freshly spawned session drops the first message** if it arrives before
the TUI is up. If `transcript_tail` comes back with `events: []`,
`peek_screen` will show an empty prompt — just re-send.

**This repo is nested with its own remote** (`clawdbotatg/clawd-containers`,
not clawd-harness) and a concurrent agent may be using the working tree.
Stage changes in a `git worktree` under the scratchpad, never assume the
shared tree is on your branch, and never run `git checkout` in it to test
something.

---

## 8. What is still open

- **`0x024771c8…6be4` is unidentified.** It declined job 621. Either a
  fourth box nobody has mapped, or a genuine competitor.
- **No client was ever told.** Five refunds went out with a message saying
  "too complex, please resubmit smaller" that was factually wrong. Nothing
  has been sent to correct it. The jobs are closed, so there is no thread to
  post into — it would need a new channel.
- **The gate has no unit tests.** Its only regression suite is the live job
  set in §5, which depends on client repos staying reachable. Jobs 586/621
  already return different LoC than when first measured. A fixture-based
  test (checked-in `.sol` samples → expected counts) would not rot.
- **`count_sol` under-counts flattened OZ** when the flattener strips
  attribution headers *and* the contract is not in `KNOWN_LIB_DECLS`. The
  name list is maintenance debt; treat a surprising `too_complex` on a
  single flat file as a missing name first.
