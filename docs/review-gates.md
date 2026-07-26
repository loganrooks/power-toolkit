# Review gates

Every PR targeting the default branch is gated on three obligations toward each reviewer
thread — bot or human. Resolution alone is not enough: a thread can be resolved without anyone
reading it, and that is precisely the failure this exists to prevent.

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

## Scope: default-branch PRs only, and why

**Measured on this repo, 2026-07-26:** `pull_request_review` and `pull_request_review_comment`
fire **only when a pull request's base branch is the repository's default branch.**

- PR #2 (base `feat/mem-watchdog-m0-observe`) — a Codex review and two human replies produced
  **no workflow run at all**.
- PR #1 (base `main`) — the identical event types fired immediately.

Isolated by changing only the base branch; same repo, same workflow, same event types.
Reproduce with `gh run list --workflow=review-gate.yml` after commenting on each.

So a stacked PR's status **cannot be kept current**, and the ruleset therefore protects the
default branch and nothing else. A required check that cannot be refreshed is a check that
silently passes — strictly worse than no check, because it looks like coverage.

Stacked PRs still get a status here, marked `ADVISORY` in its description and step summary.
They become gate-bound the moment they are retargeted at the default branch, which is when the
gate can be honest about them. `edited` is in the `pull_request_target` activity types
precisely because that is the event a retarget fires; without it, a PR would carry its last
advisory verdict — quite possibly a stale green from before any review — into a branch where
the ruleset now enforces it.

### What was tried instead, and why it was removed

An earlier version covered stacked PRs with a `*/10` cron sweeping every open PR. Four review
rounds found races, rate-limit ceilings and coverage holes in it — several of them introduced
by the fix for the previous round's. It was deleted rather than patched a fifth time.

Recorded because the failure is instructive, not to be re-litigated: the sweep was fighting the
platform constraint above rather than accepting it, and cost scaled with *total* open PRs while
the requirement scaled with *stacked* PRs.

## The invariant: every quiet failure is a fail-open

A required status that is not freshly written **keeps its previous value**, and that value is
`success` in every case that matters — a PR is green at open time, before any reviewer has
commented. So every way this workflow can fail quietly makes the PR mergeable with unanswered
findings.

Review of this file found **eight independent instances of that one shape**, which is why the
rule is written down rather than left implicit:

| Instance | Why it went green | Status |
|---|---|---|
| Status publish failure ignored | evaluation "succeeded", stale status retained | fixed |
| PR listing unpaginated | PRs 101+ never evaluated; the count guard could not miss what it never listed | removed with the sweep |
| Commit-status quota | 1000/SHA/context; a `*/10` sweep burned 144/day and exhausted it in <7 days, after which a green SHA could **never** be turned red | dedupe kept, sweep removed |
| GraphQL 100-item window | threads past the window unseen | guarded |
| Sweep/event race | an older sweep snapshot could overwrite a newer `failure` with `success` | removed with the sweep |
| Sweep API budget | 6 sweeps/hr × N PRs against 1000 REST req/hr/repo | removed with the sweep |
| Retarget transition | a stacked PR retargeted at the default branch kept its advisory verdict | fixed via `edited` |
| Skipped-PR cap | over-budget PRs got no fresh status at all | removed with the sweep |

**The rule for anyone editing this workflow:** any condition that prevents establishing *or*
publishing a verdict must reach the **status**, not merely the log. Write `failure` when a SHA
is known, and only then exit non-zero.

> **Loud is not the same as closed.** An earlier version of this file claimed a non-zero exit
> discharged the obligation. It does not: the ruleset gates on the `review-gate` commit status,
> not on the workflow job, so a red run informs the operator while the PR stays green and
> mergeable. Several fixes written under that assumption were weaker than they claimed.

`publish()` skips writing when the current status already carries the same state. That dedupe
is a correctness requirement, not an optimisation — it is what keeps the per-SHA quota from
being spent on repeats.

**Residual, not closed:** if an event-triggered run fails outright, or the statuses API is
unavailable, a green SHA cannot be turned red. The run fails visibly and the next review event
retries, so exposure is bounded — but it is real and is not engineered away.

## Applying these gates to another repo

```bash
.github/scripts/bootstrap-review-gates.sh owner/other-repo
CHECKS='build,test' .github/scripts/bootstrap-review-gates.sh owner/other-repo   # different CI jobs
```

There is deliberately **no knob to protect a stacked PR's base** — see the scope section above.

`_`-prefixed keys in the ruleset JSON are documentation and are stripped before submission; the
API rejects any unrecognised parameter with a 422.

Idempotent: re-running updates the workflow and ruleset in place.

**Upgrading a repo that already has the gate takes two runs.** The ruleset makes the default
branch require a PR with no bypass actors, so the script's own direct commit is rejected — the
upgrade path is blocked by exactly the thing it installed. It falls back to a branch plus a PR,
then **stops without touching the ruleset**: requiring the `review-gate` check while the
workflow sits in an unmerged PR would block every pull request on a check that can never
report, the fail-closed mirror of the bug above. Merge the PR it opens, re-run, and the ruleset
step completes.

The fallback branch is named `review-gate-bootstrap-<default-branch-sha>`. Keying it to the
tip makes it unique per upgrade and therefore always ours — a fixed name has to be force-reset
when it survives a squash-merge, and on a repo we do not own, guessing wrong about whose branch
it is destroys someone's commits.

**The script cannot install the reviewer bots.** Codex and CodeRabbit are GitHub Apps
configured from their own dashboards, and neither exposes an installation API. So "initialize
review gating on this repo" remains a two-step operation — one scripted, one manual — which is
the standing argument for GitHub shipping this as a repo-creation template rather than
something each project reassembles by hand.

## Which branches the ruleset targets

`conditions.ref_name.include` is `~DEFAULT_BRANCH` and nothing else. Two independent reasons,
either sufficient:

1. These rules gate **pushes** to any matching ref, so an intuitive-looking
   `refs/heads/feat/**` makes every feature branch reject your own commits:

   ```
   remote: error: GH013: Repository rule violations found for refs/heads/feat/my-branch
   remote: - Changes must be made through a pull request.
   ```

   That glob was in the first version and produced exactly that on the first push. GitHub
   rulesets cannot say *"gate this ref when it is a PR base, but allow pushes when it is a PR
   head."*

2. Even naming a single stacked base explicitly is wrong, because its status cannot be kept
   fresh (scope section above). It would be a required check that silently passes.

## Relaxing the gate

The ruleset has no bypass actors, so the gate binds the repo owner too. That is intentional.
To loosen it:

```bash
gh api repos/OWNER/REPO/rulesets --jq '.[] | select(.name=="review-gate") | .id'
gh api -X PUT repos/OWNER/REPO/rulesets/ID -f enforcement=disabled
```

Prefer disabling it explicitly and briefly over adding a permanent bypass — a bypass that
exists is a bypass that gets used.
