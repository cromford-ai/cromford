# The rebuild rung never closes a CI-parked PR whose current head is green

Doc: ALERT-REMEDIATION

## What was wrong

On 2026-09-23 the blocked-resolver's rebuild rung closed project-5 #3172 and
#3175 at 11:32Z and 11:33Z as "Superseded by a fresh build". Both were green on
`Build + Unit tests` at their current head. `br_supersede_guard` in
`bin/blocked-resolver.sh` (BH-1642) checks the head, the park, the settle
window, the verdicts and the hold before it lets the rung close an open PR. It
never read CI on the head it was about to throw away, so a red count from
earlier code was enough to discard a green PR.

## What changed

`br_supersede_guard` has one more decline, `green-at-head`. It is checked
straight after the current head is read, before `head-moved`:

- It applies only to the CI reasons: `red-ci-twice`, `red-twice` and
  `queue-ejected-twice`, the `ci-red` class of `br_ladder_class`.
- It reads `mc_ci_state` (`bin/lib/mc/classify.sh`) on the current head. That
  is the conductor's own read: the latest run of each workflow, with cancelled,
  skipped, timed-out and neutral runs ignored.
- On `green` the resolver logs one line starting `SKIP green-at-head`. It closes
  nothing, enqueues nothing and spends no counter, and it releases the
  conductor's park so the PR goes back to the queue.
- It covers both closes behind the guard: the supersede and the ABANDONED close
  at the rebuild cap.

## Fail-open on an unreadable CI read

Only an affirmative `green` declines. `red`, `pending`, `none` and `unavailable`
fall through to the BH-1642 guards unchanged, so a PR that is red on its current
head is still superseded exactly as before. Failing closed would stall every
ci-red park on any `actions/runs` blip, and the ticket defines the rule by
positive evidence of a green head.

## Red is counted per head, never across heads

The conductor's half of the same ticket is in
`docs/notes/2026-09-23-BH-1671-red-counted-per-head.md` (`Doc: MERGE-CONDUCTOR`).
`mc_classify` no longer parks `red-ci-twice`, which counted reds across heads,
so the only CI-red park a head can reach is `red-twice` on that same head.
`red-ci-twice` stays in the ci-red class for rows parked before this shipped.

Pinned by `tests/blocked-resolver-green-at-head.bh-1671-test.sh`.
