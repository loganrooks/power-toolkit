# Review gates

Every PR in this repo is gated on three obligations toward each reviewer thread — bot or
human. Resolution alone is not enough: a thread can be resolved without anyone reading it,
and that is precisely the failure this exists to prevent.

| Obligation | Enforced by | Why it is not the other one's job |
|---|---|---|
| **Resolved** | repo ruleset `review-gate`, `required_review_thread_resolution` | Native GitHub; no code needed |
| **Replied to** | `review-gate` commit status (`.github/workflows/review-gate.yml`) | GitHub has no native concept of "was answered" |
| **Reacted to** | same | The reaction is the cheap acknowledgement that a human eye landed on it |

A **rejection is a perfectly good disposition.** The gate never asks you to agree with a
reviewer — only to say, on the record, what you decided and why.

## The verdict block

Every reply on a review thread opens with a fenced block whose info-string is
`review-verdict`:

````markdown
```review-verdict
verdict: ACCEPTED_MODIFIED
commit: 9202291
finding_category: kill-safety
reviewer: chatgpt-codex-connector
notes: Observation correct; fixed at the source instead — KILL_ALLOWLIST and MEM_PROTECT
  now derive from one canonical pair, so the two lists cannot drift apart again.
```

The canonical lists live at `config.sh` under "kill-safety (GOAL_CONTRACT §4)".
````

Vocabulary: `ACCEPTED`, `ACCEPTED_MODIFIED`, `DEFERRED`, `REJECTED_FALSE_POSITIVE`,
`REJECTED_BAD_FIT`, `REJECTED_REGRESSION`, `OBSOLETE`, `DUPLICATE`. `ACCEPTED`,
`ACCEPTED_MODIFIED` and `OBSOLETE` require a `commit:`; the rest require `notes:`.

The block is a fence rather than an HTML comment so that a human reading the thread later
sees the same audit trail the parser does.

## What runs, and when

`.github/workflows/review-gate.yml` triggers on `pull_request_target`,
`pull_request_review`, `pull_request_review_comment`, `issue_comment`, a `schedule`, and
`workflow_dispatch`. All of them resolve the workflow file from the default branch, so the
gate applies to PRs whose base branch predates it. Plain `pull_request` would resolve from
the head branch and silently not run.

Nothing from the head branch is checked out or executed. The job reads PR metadata via
GraphQL and writes one commit status.

### Why the schedule is load-bearing

**Measured on this repo, 2026-07-26:** `pull_request_review` and `pull_request_review_comment`
fire **only when the pull request's base branch is the repository's default branch.**

- PR #2 (base `feat/mem-watchdog-m0-observe`) — a Codex review and two human replies produced
  **no workflow run at all**.
- PR #1 (base `main`) — the identical event types fired immediately.

Isolated by changing only the base branch; same repo, same workflow, same event types.
Reproduce with `gh run list --workflow=review-gate.yml` after commenting on each.

The consequence is the dangerous one. A stacked PR gets a `success` status at open time —
vacuously, since no reviewer has commented yet — and without a re-evaluation it keeps that
status forever. A stale-green **required** check means the PR is mergeable with unanswered
findings: the gate fails **open**, the one direction a gate must never fail. The `*/10` cron
bounds that staleness at ten minutes.

`pull_request_target` still fires on push for stacked PRs, so pushing a fix re-evaluates
immediately; the cron covers the case where a review lands and nothing is pushed after it.

**Caveat:** GitHub disables scheduled workflows after 60 days without repository activity. If
that happens, stacked PRs stop being re-evaluated and hold their last verdict.

The workflow job exits 0 even when obligations are unmet — the verdict lives in the
`review-gate` **commit status**, which is what the ruleset requires. One red thing, not two.
Read the run's step summary for the itemised list of what is outstanding.

**Known limit:** the GraphQL query takes the first 100 threads / reviews / comments. If a PR
exceeds that, the gate *fails* rather than passing on partial data. An unseen thread must
never read as a satisfied one.

## Applying these gates to another repo

```bash
.github/scripts/bootstrap-review-gates.sh owner/other-repo
CHECKS='build,test' .github/scripts/bootstrap-review-gates.sh owner/other-repo   # different CI jobs
```

Idempotent: re-running updates the workflow and ruleset in place.

**The script cannot install the reviewer bots.** Codex and CodeRabbit are GitHub Apps
configured from their own dashboards, and neither exposes an installation API. So
"initialize review gating on this repo" remains a two-step operation — one scripted, one
manual — which is the standing argument for GitHub shipping this as a repo-creation
template rather than something each project reassembles by hand.

## Which branches the ruleset targets — merge targets only

`conditions.ref_name.include` lists branches you merge **into**, never a glob over branches
you work **on**. A ruleset's `pull_request` and `required_status_checks` rules gate *pushes*
to any matching ref, so an intuitive-looking `refs/heads/feat/**` makes every feature branch
reject your own commits:

```
remote: error: GH013: Repository rule violations found for refs/heads/feat/my-branch
remote: - Changes must be made through a pull request.
remote: - 2 of 2 required status checks are expected.
```

That glob was in the first version of this ruleset and produced exactly that on the first
push. GitHub rulesets have no way to say *"gate this ref when it is a PR base, but allow
pushes when it is a PR head"* — so while a stacked PR is open, its base branch must be listed
explicitly, and removed once the stack lands.

The cost of not listing it: the base branch of a stacked PR is unprotected, so `review-gate`
still runs and is visible on the PR but does not block its merge. The gate only becomes
blocking when the PR is retargeted at the default branch.

## Relaxing the gate

The ruleset has no bypass actors, so the gate binds the repo owner too. That is intentional.
To loosen it:

```bash
gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name=="review-gate") | .id'
gh api -X PUT repos/OWNER/REPO/rulesets/ID -f enforcement=disabled
```

Prefer disabling it explicitly and briefly over adding a permanent bypass — a bypass that
exists is a bypass that gets used.
