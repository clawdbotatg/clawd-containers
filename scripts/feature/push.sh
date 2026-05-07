#!/usr/bin/env bash
# push.sh — safe push wrapper for the Feature agent.
#
# This is the SECOND security gate (resolve-target.sh is the first). It
# re-runs the classifier from scratch every time and refuses to push unless
# MODE is `leftclaw` (direct push to clawdbotatg/leftclaw-service-job-<N>)
# or `external` (fork + branch + PR against upstream). MODE=blocked or
# MODE=ambiguous → exit non-zero, no git operations performed.
#
# Both gates run; both must agree. If the classifier got something past on
# the first call (resolve-target.sh emitted MODE=external for some hostile
# input), this gate gives us a second chance to catch it before the push
# actually happens.
#
# Usage:
#   push.sh <job_id> <build_dir> [<commit_message>]
#
# Behavior:
#   leftclaw  → cd <build_dir>; git add/commit/push origin
#               (origin must already be set to clawdbotatg/<repo>)
#   external  → cd <build_dir>; ensure clawdbotatg has a fork; add 'fork'
#               remote; create a feature branch; commit; push to fork;
#               open a PR against upstream's default branch.
#
# Output (stdout, structured key/value lines):
#   MODE: <leftclaw|external>
#   COMMIT: <sha>
#   BRANCH: <branch name>
#   PUSHED_TO: <remote/branch>
#   PR_URL: <url, only for external>     # empty for leftclaw

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <job_id> <build_dir> [<commit_message>]" >&2
  exit 2
fi

JOB_ID="$1"
BUILD_DIR="$(cd "$2" && pwd)"
COMMIT_MSG="${3:-feature: implement leftclaw job #$JOB_ID}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVE="$SELF_DIR/resolve-target.sh"

if [ ! -x "$RESOLVE" ]; then
  echo "FAIL: $RESOLVE missing or not executable" >&2
  exit 1
fi

if [ ! -d "$BUILD_DIR/.git" ]; then
  echo "FAIL: $BUILD_DIR is not a git repo (no .git directory)" >&2
  exit 1
fi

# ---- Re-classify (fresh, every call) ----------------------------------
RESOLVE_OUT="$("$RESOLVE" "$JOB_ID")"
MODE=$(echo "$RESOLVE_OUT" | awk -F': ' '/^MODE:/{print $2}')
REPO_OWNER=$(echo "$RESOLVE_OUT" | awk -F': ' '/^REPO_OWNER:/{print $2}')
REPO_NAME=$(echo "$RESOLVE_OUT" | awk -F': ' '/^REPO_NAME:/{print $2}')
REASON=$(echo "$RESOLVE_OUT" | awk -F': ' '/^REASON:/{$1=""; sub(/^ /,""); print}')

case "$MODE" in
  leftclaw|external)
    : ;;
  blocked)
    echo "REFUSED: MODE=blocked" >&2
    echo "  $REASON" >&2
    exit 3
    ;;
  ambiguous)
    echo "REFUSED: MODE=ambiguous — clarify with the client before pushing" >&2
    echo "  $REASON" >&2
    exit 3
    ;;
  *)
    echo "REFUSED: unrecognized MODE='$MODE'" >&2
    exit 3
    ;;
esac

cd "$BUILD_DIR"

# Set committer identity (every call — config doesn't always persist).
git config user.email "clawd@buidlguidl.com"
git config user.name "clawdbotatg"

# Stage everything that's not gitignored.
git add -A

if git diff --cached --quiet && git diff --quiet; then
  echo "  (no changes to commit)"
fi

# Commit if there's anything new (don't fail if there's nothing).
if ! git diff --cached --quiet; then
  git commit -m "$COMMIT_MSG" >/dev/null
fi

CURRENT_SHA=$(git rev-parse HEAD)
DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "main")

if [ "$MODE" = "leftclaw" ]; then
  # Direct push to origin (which is clawdbotatg/leftclaw-service-job-<N>).
  # Sanity-check origin URL: the fail-safe is the resolve gate, but a
  # belt+suspenders check here catches the scenario where the agent
  # accidentally cloned the wrong repo into <build_dir>.
  ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
  if ! echo "$ORIGIN_URL" | grep -qE '[/:]clawdbotatg/leftclaw-service-job-[0-9]+(\.git)?$'; then
    echo "FAIL: origin '$ORIGIN_URL' is not a clawdbotatg/leftclaw-service-job-* repo" >&2
    echo "  MODE=leftclaw requires the working dir's origin to point at the leftclaw repo" >&2
    exit 4
  fi
  git push origin "HEAD:$DEFAULT_BRANCH" >/dev/null 2>&1 || git push -u origin "$DEFAULT_BRANCH" >/dev/null
  echo
  echo "MODE: leftclaw"
  echo "COMMIT: $CURRENT_SHA"
  echo "BRANCH: $DEFAULT_BRANCH"
  echo "PUSHED_TO: origin/$DEFAULT_BRANCH"
  echo "PR_URL:"
  exit 0
fi

# ----- MODE=external: fork+PR flow -------------------------------------
if [ -z "$REPO_OWNER" ] || [ -z "$REPO_NAME" ]; then
  echo "FAIL: MODE=external but REPO_OWNER/REPO_NAME not resolved" >&2
  exit 4
fi
UPSTREAM="$REPO_OWNER/$REPO_NAME"

# Make sure clawdbotatg has a fork. `gh repo fork` is idempotent: if a fork
# already exists, it just prints the existing URL. We pass --clone=false
# because we already have a clone — we only need a remote pointing at the fork.
echo "=== Ensuring fork at clawdbotatg/$REPO_NAME ==="
gh repo fork "$UPSTREAM" --clone=false --remote=false >/dev/null 2>&1 || true

# Add or update the 'fork' remote.
FORK_URL="https://github.com/clawdbotatg/$REPO_NAME.git"
if git remote get-url fork >/dev/null 2>&1; then
  git remote set-url fork "$FORK_URL"
else
  git remote add fork "$FORK_URL"
fi

# Use a deterministic branch name keyed on the leftclaw job id so the PR is
# traceable and re-runs are idempotent (push -f to the same branch on retry).
FEATURE_BRANCH="leftclaw-feature-job-$JOB_ID"

# If we're not already on it, create or check out the branch from current HEAD.
if ! git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1; then
  git checkout -b "$FEATURE_BRANCH" >/dev/null 2>&1
elif [ "$(git symbolic-ref --short HEAD)" != "$FEATURE_BRANCH" ]; then
  git checkout "$FEATURE_BRANCH" >/dev/null 2>&1
  git merge --ff-only HEAD@{1} >/dev/null 2>&1 || true
fi

git push fork "$FEATURE_BRANCH" --force-with-lease >/dev/null

# Detect upstream's default branch (we can't assume "main").
UPSTREAM_DEFAULT=$(gh repo view "$UPSTREAM" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)

# Open the PR (or update an existing one — gh prints the existing URL if a
# PR already exists from this branch).
PR_BODY=$(cat <<EOF
This PR was generated by the leftclaw.services Feature agent in response
to job #${JOB_ID} on the leftclaw marketplace.

**Job:** https://leftclaw.services/jobs/${JOB_ID}

The agent identified this repo (\`${UPSTREAM}\`) as the target from the
job description and/or chat. Because we (clawdbotatg) do not own the
upstream, the change is being submitted as a PR from a fork rather than
pushed directly.

If something looks wrong, comment on this PR or post a message on the
leftclaw job — the agent reads both.
EOF
)

set +e
PR_OUT=$(gh pr create \
  --repo "$UPSTREAM" \
  --base "$UPSTREAM_DEFAULT" \
  --head "clawdbotatg:$FEATURE_BRANCH" \
  --title "feat: leftclaw job #${JOB_ID} — ${REPO_NAME}" \
  --body "$PR_BODY" 2>&1)
PR_RC=$?
set -e

if [ "$PR_RC" -ne 0 ]; then
  # If a PR already exists for this branch, fetch its URL.
  EXISTING=$(gh pr list --repo "$UPSTREAM" --head "clawdbotatg:$FEATURE_BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)
  if [ -n "$EXISTING" ]; then
    PR_URL="$EXISTING"
  else
    echo "FAIL: gh pr create failed:" >&2
    echo "$PR_OUT" >&2
    exit 5
  fi
else
  PR_URL=$(echo "$PR_OUT" | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | head -1)
fi

echo
echo "MODE: external"
echo "COMMIT: $CURRENT_SHA"
echo "BRANCH: $FEATURE_BRANCH"
echo "PUSHED_TO: fork/$FEATURE_BRANCH"
echo "PR_URL: $PR_URL"
