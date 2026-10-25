# BH-8270: pr-owner-sweep reads the fleet's PR record before GitHub

Doc: PR-OWNERSHIP, DB-COORDINATION-SPEC

## What changed

`bin/pr-owner-sweep.sh` now asks the fleet's own PR record (`pr_records`, BH-8067)
first for the GitHub reads the record can answer. The new lib is
`bin/lib/pr-owner/prr.sh`. It uses the read rule and the helpers of
`bin/lib/pr-record.sh`, but it never calls GitHub itself: on a miss the lane runs its
own old read, so a miss gives exactly the old behavior.

| Read | Old | Now |
|---|---|---|
| enroll (`po_enroll`) | `GET pulls/N` | record `state head_sha draft mergeable_state`. An open row with a null `mergeable_state` is a miss, never `clean`. A fallback read is written back to the record (source `github`), except in a dry run. |
| stale rebase rung | `GET pulls/N` for `head.ref` | record `head_ref`. |
| open and merged lists | two `gh pr list` reads per repo per tick | reused from `state/pr-owner-sweep/<owner>_<repo>/` while no `pr` wake rang for the repo and the copy is no older than the knob (the BH-8271 mechanism). |

## The miss line

Each fallback read logs one line through the lane's `say` into `logs/pr-owner-sweep.log`:

```
<UTC> PRR_MISS <owner/repo>#<n|list> why=<no-row|stale|no-field|unreadable>[ field=<f>]
```

Count them: `grep -c ' PRR_MISS ' logs/pr-owner-sweep.log`.

## The knob

`PR_RECORD_MAX_AGE_S` (default 900, `catalog/lanes.d/_lib.pr-record.json`). No second
knob was added. Set it to 0 to turn the record reads and the list reuse off.
`WAKE_BACKSTOP=0` turns the list reuse off only.

## Reads left on GitHub, and why

- The enroll CI read (`mc_ci_state`, `actions/runs`): the record keeps one `checks`
  entry per workflow name on any sha, and a missed webhook leaves none. Using it could
  turn a WAIT_CI into a READY.
- The stale close rung's label guard and the commit-gone `updated_at` read: the first
  guards a PR close, and the record has no `updated_at`.
- `commits/SHA`, comment and review bodies, `compare`, the ticket issue and the
  shipped-file checks: the record does not store them.
