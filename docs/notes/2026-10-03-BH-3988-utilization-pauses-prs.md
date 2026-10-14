# utilization: pauses and PR-queue sections (BH-4010, slice 3 of BH-3988)

Doc: VERIFICATION-MAP

## What changed

The hourly utilization snapshot (`bin/utilization-push.sh`, BH-4008) now
carries two more sections. Both are new files in `bin/lib/utilization/`, which
the collector already sources, so the collector itself is unchanged. Neither
section writes anything: every request is a GET.

### `pauses` (`section-pauses.sh`)

`payload.pauses` is a list of `{kind, name, since, stops_builds}`:

| kind | from | name | since | stops_builds |
|---|---|---|---|---|
| flag | `flags/paused-<p>` | file name | file mtime | true |
| flag | `flags/all-off` | file name | file mtime | true |
| flag | `flags/automerge-disabled` | file name | file mtime | false |
| pause | `GET /api/pauses?active=1`, scope `fleet` or `<p>` | `<scope>/<what>` | `created_at` | true for builds and triage, false for reviews and merges |
| hold | `GET /api/conductor/held?limit=500`, repo = `fleet-conf.sh <p> repo` | `<repo>#<number> <kind>` | `first_held_at` | false |

`basis.pauses` is `"unmeasured"` when the pauses read fails, has no `pauses`
array or says `truncated:true`, or when the held read fails or comes back
truncated (fewer rows than `n_total`). The flag entries are still listed in
that case, so a worker outage never hides a flag pause. A project with no repo
in fleet.conf has no holds to match and that alone does not make it
unmeasured.

### `prs` (`section-prs.sh`)

`payload.prs` is `{review, ci, merge_queue}`:

- `merge_queue`: the number of `status=queued` rows from
  `GET /api/merge-queue?project=<p>&status=queued&limit=500`. Null when the
  read fails, the body has no array, or it comes back with exactly 500 rows (a
  capped list is not a count).
- `review` and `ci`: the project's PRs in the `pr_state` view, read through
  `pr_state_page` 1000 rows at a time and walked with `before=<min id>` for up
  to 5 pages, bucketed by state:

  | bucket | states (`UTIL_PR_REVIEW_STATES` / `UTIL_PR_CI_STATES`) |
  |---|---|
  | review | WAIT_REVIEW, HEAD_MOVED, NEEDS_HUMAN_VERDICT |
  | ci | WAIT_CI, RED_TWICE |

  Every other conductor state counts toward neither. Both are null, never 0,
  when the `pr-state-rows` flag is off (`pr_rows_on`), the project has no
  repo, the first page answers 404 or fails, a later page fails, or the walk is
  still on a full page after 5 pages. A 404 after a full page is the end of
  the rows. The first-page 404 is null on purpose: the route answers 404 both
  for "no rows for this repo" and for a worker without the route.

  The view keeps MERGED and CLOSED PRs forever, so a repo with more than 5000
  `pr_state` rows (cromford is one) comes out null and unmeasured on
  every run. That is the walk bound doing its job, not an outage.

  Both sections feed worker bodies to jq on stdin, never as an argv string: a
  production-width 1000-row page is about 390 KB, and Linux caps a single
  argument at 128 KiB.

`basis.prs` is `"unmeasured"` whenever any of the three is null.

The bucket table, the 500 cap, the 1000-row page and the 5-page bound are code
constants: they mirror the conductor's state vocabulary and the routes' own
limits, not business inputs.

## Check it

```bash
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/utilization" \
  | jq -c '.rows[] | {project, pauses: .payload.pauses, prs: .payload.prs, basis: .payload.basis}'
```

After the first `:07` hub tick following the deploy, every row has a `pauses`
list, a `prs` object and `basis.pauses` / `basis.prs`.

Tests: `tests/utilization-pauses-prs.bh-4010-test.sh`.
