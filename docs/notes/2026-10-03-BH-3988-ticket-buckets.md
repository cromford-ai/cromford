# utilization: ticket buckets and the real verdict (BH-4009, slice 2 of BH-3988)

Doc: VERIFICATION-MAP

## What changed

The hourly utilization snapshot now counts each project's tickets, and the
verdict is no longer always `unknown`.

- **New section `bin/lib/utilization/section-tickets.sh`.** The collector
  (`bin/utilization-push.sh`, unchanged) sources it with every other
  `section-*.sh`. It prints `tickets:{ready, blocked, held, parked,
  held_complete}`, and `basis.<bucket>:"unmeasured"` for each null bucket.
- **GitHub-Issues projects** (fleet.conf board prefix `-`). The section reads
  the open `ai-build` issues and the open PRs, up to 3 pages of 100 each.
  - `blocked`: a body line that starts with `Blocked-by` (after list or quote
    marks) names a bare `#N` that is open. An `#N` outside the list costs one
    issue-state read. Only `closed` clears it; a 404, an unreadable answer or
    an exhausted read budget counts as blocked.
  - candidates: not blocked, no open PR whose head branch carries
    `<letters>-N`, and no running build of N.
  - `held`: candidates whose thread `hold_classify` reads as held. `ready`:
    the rest of the candidates.
  - `parked`: always null.
- **In-app projects.** One board list and one ticket list through the
  project's API, with the token from `bin/internal-token-for.sh`.
  - open: the status is not done, closed, cancelled, canceled, archived,
    rejected, shipped or review.
  - `blocked`: `blocked:true`. `parked`: `waitingOn` client, or a
    `triageVerdict` other than ready or empty.
  - `held`: null, because the list carries no comments.
  - `ready`: the open tickets left, minus any with an open PR or a running
    build on their key.
- **Verdict precedence in `util_verdict`.** First match wins:
  1. unknown (an input unmeasured)
  2. paused (a `stops_builds` pause, or cap 0)
  3. saturated
  4. busy
  5. blocked
  6. starved

  The why strings are in the header of `bin/lib/utilization.sh`.

## Why null and never 0

The went-quiet alert will read `starved`. A rate-limited or failed read that
came back as 0 would page "nothing to build" exactly when GitHub stopped
answering. So every failed read is null:
- the issue list makes all three GitHub buckets null.
- the PR list, or a running-jobs read at its 500 cap, makes `ready` null.
- an unreadable hold thread makes `held` and `ready` null.
- the board read makes all of the in-app buckets null.

A null `ready` is verdict rule 1, `unknown`.

## Read budget

`UTIL_HOLD_READS_MAX` (default 30) is the knob. It is the settings row
`lib.utilization-tickets[.<project>].util_hold_reads_max`, registered in
`catalog/lanes.d/_lib.utilization-tickets.json`. It caps the issue-state
reads and the hold-thread reads together, per project per run. Candidates
past the cap count as ready, and `held_complete` is false. A bound can only
push the verdict toward busy or saturated, never starved. Every GitHub call
is a `gh_rest` GET with `GH_REST_OPTIONAL=1`, so it yields under the quota
reserve.

## Decisions a reviewer should know

- **Reads only.** Holds are classified with `hold_classify` over a `gh_rest`
  comment read, not `hold_check`. `hold_check` calls `hold_ambiguous_note`,
  which can alert and post a ticket comment. An observability lane must not
  write.
- **Open PRs.** Any open PR whose head carries the key counts, whoever opened
  it.
- **Exclusive buckets.** Holds are read only for tickets that are not blocked
  and not claimed. On a board, a ticket that is blocked is not also parked.
- **Running builds.** The jobs read is `kind=build&limit=500`, the same read
  section-builds makes.
