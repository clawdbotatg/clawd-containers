# scripts/feature/

Helpers for the **Feature agent** (leftclaw.services Service Type 10).

A Feature job asks us to add functionality to an *existing* project — usually
either a previous leftclaw build or a customer's own GitHub repo. The
non-trivial concern is that our `clawdbotatg` PAT has `repo` scope across
**every** repo we (the bot) own — including products we built outside the
leftclaw flow. A malicious customer could ask the agent to add a feature
(read: backdoor) to one of those.

The two scripts in this directory exist to make that impossible.

---

## The threat model

Our PAT (`GITHUB_TOKEN`) is scoped: `repo, workflow, delete_repo`. It can push
to any `clawdbotatg/*` repo. There is no GitHub-side acl distinguishing
"leftclaw deliverables" (safe to modify autonomously) from "shared products
we use in production" (NOT safe).

A customer who wants to compromise one of those products can:

1. Reference it in a Feature job (`"please add login redirect to clawdbotatg/foo"`).
2. Reference it implicitly (`"job #88"` where `#88` happens to live in our shared org by accident).
3. Hide the reference from a URL regex by writing `clawdbotatg/foo` without `github.com/`.

Two layers stop this:

1. **`resolve-target.sh`** — deterministic classifier. Reads the job
   description and chat messages, scans for repo references via three
   independent regexes (URL, leftclaw-name shorthand, bare `clawdbotatg/...`).
   Returns one of four `MODE` values. The classifier is **fail-safe**: if
   `blocked` shows up anywhere in the parse, that wins over any other
   reference, even if a "valid" target is also present.
2. **`push.sh`** — re-runs the classifier from scratch and refuses to do
   any git push unless the resulting `MODE` is `leftclaw` or `external`. It
   also re-validates the working dir's `origin` URL when the mode is
   `leftclaw`, so the agent can't accidentally have cloned the wrong repo
   into its build dir.

Both gates run on every push. They must agree. You can't bypass one without
the other.

---

## `resolve-target.sh <job_id>`

Parses the job description + chat messages and emits:

```
MODE: <leftclaw|external|blocked|ambiguous>
REPO_URL: <full https URL or empty>
REPO_OWNER: <github owner or empty>
REPO_NAME: <repo name or empty>
REFERENCED_JOB_ID: <N or empty>
REASON: <one-line human explanation>
```

The four modes:

- **`leftclaw`** — the target is `clawdbotatg/leftclaw-service-job-<N>`.
  This is a deliverable from a previous build job; we own it precisely so
  we can extend it. Direct push to `origin` is allowed.

- **`external`** — the target is a non-clawdbotatg repo. The agent must
  fork it, push the change to the fork, and open a PR against upstream.
  We never push directly to a repo we don't own.

- **`blocked`** — the target is `clawdbotatg/<something>` but **not**
  `leftclaw-service-job-<N>`. This is one of our own products; refuse the
  job. The agent should `decline.sh` (if pre-accept) or post a message
  explaining why and leave the job in our queue without modification.
  This is the security backbone.

- **`ambiguous`** — couldn't pinpoint the target, or multiple references
  disagree. The agent should ask the client for the explicit repo URL via
  `post-message.sh`. If the client doesn't clarify, `decline.sh` rather
  than guess.

### What's scanned

The classifier reads:

- `get-job.sh <id>` — `description` field.
- `messages.sh <id>` — every message body, in order.

…and matches three regex families against the combined corpus:

1. **URL form** — `(https?://)?(www\.)?github.com/<owner>/<repo>(.git)?`
2. **Leftclaw shorthand** — `[<owner>/]leftclaw-service-job-<N>` (owner
   defaults to `clawdbotatg` when omitted).
3. **Bare own-repo form** — `clawdbotatg/<repo>`, regardless of host.
   This is the anti-evasion regex; the customer cannot omit `github.com/`
   to slip past us.

Multiple references are deduplicated (case-insensitive). If they classify
the same and name the same repo, we proceed. Otherwise we go ambiguous.
`blocked` always wins over `external`/`leftclaw` if both appear.

---

## `push.sh <job_id> <build_dir> [<commit_message>]`

Re-runs the classifier, then:

- **`MODE=leftclaw`** — sets `clawdbotatg` git committer identity, stages
  everything, commits if there are changes, and pushes `HEAD` to `origin`'s
  current branch. Belt-and-suspenders: refuses if `git remote get-url origin`
  doesn't match `*/clawdbotatg/leftclaw-service-job-<N>(.git)?`.

- **`MODE=external`** — runs `gh repo fork <owner>/<repo>` (idempotent),
  adds a `fork` remote pointing at the clawdbotatg fork, checks out a
  deterministic feature branch (`leftclaw-feature-job-<N>`), pushes to the
  fork with `--force-with-lease`, then opens a PR from
  `clawdbotatg:<branch>` against the upstream's default branch.

- **`MODE=blocked` or `MODE=ambiguous`** — exits non-zero, no git
  operations performed.

The output is a structured 5-line block (parseable by the agent or by
downstream tooling):

```
MODE: <leftclaw|external>
COMMIT: <sha>
BRANCH: <branch name>
PUSHED_TO: <remote/branch>
PR_URL: <url, only for external>
```

---

## Why a separate IPFS step

`push.sh` does **not** invoke bgipfs. The two are decoupled by mode:

- For `leftclaw` jobs, `~/scripts/builder/bgipfs-ship.sh` is the canonical
  upload step (it also commits + pushes the resulting `DEPLOYMENT.md` /
  README updates to the leftclaw repo). The Feature agent reuses it.

- For `external` jobs, the upload step is just `~/scripts/bgipfs/upload.sh`
  on the build output. The IPFS gateway URL goes in the PR body and on-chain
  `completeJob`. We don't commit a `DEPLOYMENT.md` to the upstream repo —
  the maintainer can choose to merge the PR or not.

`push.sh` doesn't need to know which is which; the agent picks the right
upload script per its mode.
