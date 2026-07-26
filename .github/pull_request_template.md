## Summary

What changed, and why.

## Verification

State what you actually ran, not what you intend to run. Claims without a reproduction
command are `Unchecked` — label them that way rather than asserting them.

- [ ] `zsh -n` clean (the `zsh-syntax` check covers this)
- [ ] Behaviour exercised on a real machine — command:
- [ ] Evidence recorded in `goal/EVIDENCE_LEDGER.md` (private package), entry id(s):

## Kill-safety (GOAL_CONTRACT §4)

Required for any change touching `config.sh` protect lists, `libexec/*-watchdog.sh`, or a
signalling path. Delete this section if it genuinely does not apply.

- [ ] No process on `PROTECT_SYSTEM` / `PROTECT_SESSION` can be signalled in any mode
- [ ] Verified in **real** `aggressive` mode via `var/mode` — not by assigning `PT_MODE`
      in-process, which `config.sh` silently overrides by re-reading the mode file
- [ ] Observe-before-kill preserved (§5): no new termination path ships un-staged

## Reviewer obligations

The `review-gate` status check enforces these; it is not a formality you can tick past.
Every thread from a reviewer — bot or human — needs all three:

- [ ] **Replied to**, with a ` ```review-verdict ` block (see `docs/review-gates.md`)
- [ ] **Reacted to** on the reviewer's originating comment
- [ ] **Resolved**

Rejecting a finding is a perfectly good outcome. Silently resolving one is not.
