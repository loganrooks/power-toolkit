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

if [[ -n "$EXISTING_SHA" ]]; then
  REMOTE_B64=$(gh api "repos/$TARGET/contents/$REMOTE_PATH?ref=$DEFAULT_BRANCH" --jq .content | tr -d '\n')
  if [[ "$REMOTE_B64" == "$LOCAL_B64" ]]; then
    echo "    workflow: already current"
  else
    gh api -X PUT "repos/$TARGET/contents/$REMOTE_PATH" \
      -f message='ci: update review-gate workflow' \
      -f content="$LOCAL_B64" -f sha="$EXISTING_SHA" -f branch="$DEFAULT_BRANCH" >/dev/null
    echo "    workflow: updated"
  fi
else
  gh api -X PUT "repos/$TARGET/contents/$REMOTE_PATH" \
    -f message='ci: add review-gate workflow' \
    -f content="$LOCAL_B64" -f branch="$DEFAULT_BRANCH" >/dev/null
  echo "    workflow: created"
fi

# ---- 2. the ruleset ----------------------------------------------------------------------
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
