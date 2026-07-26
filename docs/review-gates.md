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
`pull_request_review`, `pull_request_review_comment` and `issue_comment`. That set is
deliberate: **all four resolve the workflow file from the default branch**, so the gate
applies to stacked PRs whose base branch predates the gate, and to PRs opened before it
existed. Plain `pull_request` would resolve from the head branch and silently not run.

Nothing from the head branch is checked out or executed. The job reads PR metadata via
GraphQL and writes one commit status.

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

## Relaxing the gate

The ruleset has no bypass actors, so the gate binds the repo owner too. That is intentional.
To loosen it:

```bash
gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name=="review-gate") | .id'
gh api -X PUT repos/OWNER/REPO/rulesets/ID -f enforcement=disabled
```

Prefer disabling it explicitly and briefly over adding a permanent bypass — a bypass that
exists is a bypass that gets used.
