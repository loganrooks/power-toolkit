#!/usr/bin/env bash
# Apply this repo's review gates to ANY repo, idempotently.
#
#   .github/scripts/bootstrap-review-gates.sh                    # this repo
#   .github/scripts/bootstrap-review-gates.sh owner/other-repo   # somewhere else
#   CHECKS='build,test' .github/scripts/bootstrap-review-gates.sh owner/other-repo
#
# Installs, in the target repo:
#   1. .github/workflows/review-gate.yml  — reply+react enforcement, pushed to the DEFAULT
#      branch (comment-triggered workflows resolve from there and nowhere else)
#   2. a branch ruleset named `review-gate` requiring thread resolution + status checks
#
# It does NOT install the reviewer bots themselves — Codex and CodeRabbit are GitHub Apps
# installed from their own dashboards, and there is no API to do it for you. That gap is
# the whole reason this script exists rather than a checkbox.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
RULESET="$HERE/.github/rulesets/review-gate.json"
WORKFLOW="$HERE/.github/workflows/review-gate.yml"

[[ -f "$RULESET" ]]  || { echo "missing $RULESET"  >&2; exit 1; }
[[ -f "$WORKFLOW" ]] || { echo "missing $WORKFLOW" >&2; exit 1; }

echo "==> target: $TARGET"
DEFAULT_BRANCH=$(gh api "repos/$TARGET" --jq .default_branch)
echo "    default branch: $DEFAULT_BRANCH"

# ---- 1. the workflow, committed to the default branch ------------------------------------
REMOTE_PATH=.github/workflows/review-gate.yml
EXISTING_SHA=$(gh api "repos/$TARGET/contents/$REMOTE_PATH?ref=$DEFAULT_BRANCH" --jq .sha 2>/dev/null || true)
LOCAL_B64=$(base64 < "$WORKFLOW" | tr -d '\n')

REMOTE_B64=""
[[ -n "$EXISTING_SHA" ]] && \
  REMOTE_B64=$(gh api "repos/$TARGET/contents/$REMOTE_PATH?ref=$DEFAULT_BRANCH" --jq .content | tr -d '\n')

# The ruleset this script installs makes the default branch require a pull request with no
# bypass actors — so on any repo that ALREADY has the gate, a direct Contents-API commit is
# rejected and the "idempotent upgrade" cannot deliver a fix to precisely the installations
# running the old, broken gate. Try direct; fall back to a branch and a PR.
# (Codex round 1 on PR #3.)
put_file() {                       # $1 = branch, $2 = commit message
  local args=(-X PUT "repos/$TARGET/contents/$REMOTE_PATH"
              -f "message=$2" -f "content=$LOCAL_B64" -f "branch=$1")
  [[ -n "$EXISTING_SHA" ]] && args+=(-f "sha=$EXISTING_SHA")
  gh api "${args[@]}" >/dev/null 2>&1
}

if [[ -n "$EXISTING_SHA" ]]; then MSG='ci: update review-gate workflow'
else                              MSG='ci: add review-gate workflow'; fi

if [[ -n "$EXISTING_SHA" && "$REMOTE_B64" == "$LOCAL_B64" ]]; then
  echo "    workflow: already current"
elif put_file "$DEFAULT_BRANCH" "$MSG"; then
  echo "    workflow: written to $DEFAULT_BRANCH"
else
  BR=chore/review-gate-bootstrap
  HEAD_SHA=$(gh api "repos/$TARGET/git/ref/heads/$DEFAULT_BRANCH" --jq .object.sha)
  gh api -X POST "repos/$TARGET/git/refs" -f "ref=refs/heads/$BR" -f "sha=$HEAD_SHA" >/dev/null 2>&1 || true
  EXISTING_SHA=$(gh api "repos/$TARGET/contents/$REMOTE_PATH?ref=$BR" --jq .sha 2>/dev/null || true)
  put_file "$BR" "$MSG" || { echo "    workflow: FAILED on both $DEFAULT_BRANCH and $BR" >&2; exit 1; }
  PR_URL=$(gh pr create --repo "$TARGET" --base "$DEFAULT_BRANCH" --head "$BR" --title "$MSG" \
             --body 'Automated `review-gate` bootstrap. The default branch is protected by the gate ruleset, so this could not be committed directly.' 2>/dev/null \
           || gh pr list --repo "$TARGET" --head "$BR" --state open --json url --jq '.[0].url')
  WORKFLOW_PENDING=1
  echo "    workflow: $DEFAULT_BRANCH is protected -> opened $PR_URL"
fi

# ---- 2. the ruleset ----------------------------------------------------------------------
# Applying a ruleset that REQUIRES the `review-gate` check while the workflow is still sitting
# in an unmerged PR would block every pull request on a check that can never report — the
# fail-CLOSED mirror of the fail-open this whole workflow is about. Refuse, and say what to do.
if [[ -n "${WORKFLOW_PENDING:-}" ]]; then
  echo "==> ruleset NOT applied: the workflow is still in an unmerged PR."
  echo '    Requiring the review-gate check now would block every PR on a check that cannot run.'
  echo "    Merge $PR_URL, then re-run this script to apply the ruleset."
  exit 0
fi

# CHECKS lets a repo with different CI job names reuse this without editing the JSON.
PAYLOAD=$(cat "$RULESET")
if [[ -n "${CHECKS:-}" ]]; then
  PAYLOAD=$(CHECKS="$CHECKS" python3 -c '
import json, os, sys
p = json.load(sys.stdin)
want = [c.strip() for c in os.environ["CHECKS"].split(",") if c.strip()]
if "review-gate" not in want:
    want.append("review-gate")
for rule in p["rules"]:
    if rule["type"] == "required_status_checks":
        rule["parameters"]["required_status_checks"] = [{"context": c} for c in want]
json.dump(p, sys.stdout)
' <<<"$PAYLOAD")
fi

EXISTING_ID=$(gh api "repos/$TARGET/rulesets" --jq '.[] | select(.name=="review-gate") | .id' 2>/dev/null || true)
if [[ -n "$EXISTING_ID" ]]; then
  gh api -X PUT "repos/$TARGET/rulesets/$EXISTING_ID" --input - <<<"$PAYLOAD" >/dev/null
  echo "    ruleset: updated (id $EXISTING_ID)"
else
  NEW_ID=$(gh api -X POST "repos/$TARGET/rulesets" --input - <<<"$PAYLOAD" --jq .id)
  echo "    ruleset: created (id $NEW_ID)"
fi

echo "==> done. Remaining MANUAL step (no API exists for it):"
echo "    install the reviewer apps on $TARGET —"
echo "      Codex:       https://chatgpt.com/codex/settings/code-review"
echo "      CodeRabbit:  https://app.coderabbit.ai"
