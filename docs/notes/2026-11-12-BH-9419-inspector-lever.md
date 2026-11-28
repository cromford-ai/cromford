# The inspector owns hours behind main, and files fix-main-red as its lever (BH-9419)

Doc: STAFF, OPERATING

Slice C1 of #9187. The staff contract (C0, BH-9187) says each staff agent owns
ONE metric and is judged by whether that metric moved. This slice gives the
inspector its metric, `hours_behind_main`, and its one lever: file a
fix-main-red issue with the failing build step quoted, dry run first.

The lane is `bin/staff/inspector-lever.sh`. It runs on the hub, hourly at :23
(`cron/lanes/781-staff-inspector-lever.cron`, lane `staff-inspector-lever`).
It makes no model call.

## The metric

`hours_behind_main` is ONE number: the larger of two parts, in hours with two
decimals. The sample detail carries each part.

- Vercel part. The lane reads what `bin/served-sha-watch.sh` already wrote. It
  makes no Vercel call for this part. The newest
  `checked=N ... unreadable=N` line of `logs/served-sha-watch.log` must be at
  most `staff.inspector.fresh_min` minutes old (seed 20). For each
  `vercel.conf` project: no `state/served-sha-watch/<p>.json` file is 0 h. A
  file with `last_verdict` `wait` or `alert` is `(now - since) / 3600`, where
  `since` is `.prodbehind.since`, else `.first_seen`. A file whose
  `checked_at` is older than the window still counts with its clock and is
  tagged `stale`.
- Console part. The Cloudflare Pages production deployment of
  `mission-control` against main's last first-parent console-ui commit in
  `HARNESS_CHECKOUT` (the rule of `bin/pipeline-health.sh` block 8c). Behind is
  the age of the oldest console-ui commit not deployed. A commit the checkout
  does not know uses the age of main's console-ui commit. The token is
  `CLOUDFLARE_API_TOKEN` from `env/cloudflare.env`. It goes to curl on stdin.

A part that cannot be read is never 0: the run writes no sample and takes no
action, and the log line names the part (`vercel part unreadable (...)` or
`console part unreadable (...)`).

The sample goes to `POST /api/staff/levers/metric`. That call also settles the
inspector's lever actions that are 24 h old (C0).

## The lever

At `staff.inspector.level` `file` or `act` (seed `observe`), a Vercel project
at or over `staff.inspector.target` hours (seed 2) is a candidate, oldest
first. The console part has no lever. A candidate gets an action only when:

1. Its newest production deployment is `ERROR`. A `READY`, `BUILDING` or
   `CANCELED` deploy, or a list the lane cannot read, gets no action: there is
   no failing step to quote.
2. The non-dry actions of the last day (scorecard `days=1`) are under
   `staff.inspector.file_max_day` (seed 3). Dry actions do not count. A
   scorecard the lane cannot read means no action.
3. The build log (`/v3/deployments/<uid>/events`) has error lines. The step is
   the last `command` event. The quote is the last
   `staff.inspector.quote_lines` (seed 30) lines that are stderr or say
   `error`, `failed` or `ERR!`. Each line is redacted first (token shapes,
   `Bearer <credential>`, and the value after any name that holds `key`,
   `token`, `secret` or `password` in any case, such as `apiKey=` or
   `password=`), then cut to `staff.inspector.quote_line_chars` (seed 300)
   characters. A secret that crosses the cut leaves no fragment.

At most `staff.inspector.lever_max_run` (seed 1) actions run per run. Only a
new record (or a failed one) uses a slot. An episode recorded earlier does not,
so one project that stays behind cannot block the next project.

The action row is written BEFORE GitHub is called, with the key
`fix-main-red:<project>@<since>` (`:dry` added in dry mode). The episode is the
`prodbehind.since` clock, so one behind episode is one row. A row recorded
earlier (200 `existing`, or 409 `key_mismatch` when the hours changed) retries
the delivery.

Delivery, live mode only: one list of the `staff:inspector` issues in all
states per run on the filing repo (`STAFF_FILE_REPO`, else `HARNESS_REPO`).

- An issue in any state with `<!-- inspector-fmr:<p>@<since> -->` is
  `filed=already`. A closed ticket for the same episode is never filed again.
- An open issue with `<!-- inspector-fmr-project:<p> -->` is
  `filed=open-reused`: one open ticket per project.
- Else the lane POSTs the issue, title
  `fix-main-red: <p> prod <served8> behind main <head8> for <h>h`, label
  `staff:inspector`. The label is not `fix-main-red`, because that label lets a
  PR merge through a main-red freeze.
- A list the lane cannot read, or a POST that does not answer 201, files
  nothing. The row stays, and the next run retries the delivery.
- The list reads at most `staff.inspector.issue_list_max` (seed 1000) issues.
  The value cannot go above 1000, the stop of `bin/lib/gh-rest-list.sh` (10
  pages). A list that reaches the cap can be cut short, so it is
  `filed=list-unreadable`, and the lever files nothing (it never files on a
  list it could not read to the end, because that can file a duplicate).
  The label `staff:inspector` holds closed issues too, and `bin/staff.sh`
  files under it. When it reaches the cap, every live run logs
  `issue list unreadable` and files nothing. The fix is to take the label off
  old closed issues, or to lower the row only after you check that old
  episodes cannot come back.

## Dry to live

The defaults sample the metric and file nothing. To move on:

1. Set `staff.inspector.level` to `file`. The lever now records dry actions
   (`dry_run=1`) and writes one `dry fix-main-red: ...` line per action. It
   makes no GitHub call.
2. Read the dry lines in `logs/staff-inspector-lever.log`. If the titles and
   the steps are right, set `staff.inspector.lever_dry_run` to `0`.
3. Only exactly `0` files. A missing or non-numeric value is dry.

Off: `bin/harness-ctl.sh off staff-inspector-lever`, or a staff kill flag
(`staff-off-all`, `staff-kill-all`, `staff-off-inspector`,
`staff-kill-inspector`), or `STAFF_ENABLED=0`.

## The log

One summary line per run in `logs/staff-inspector-lever.log`:

```
<ts> level=<L> hours=<M|unreadable> target=<T> vercel=<h> console=<h> sample=<ok|failed|none> action=<none|recorded|recorded-earlier|failed|log-unreadable|day-cap|scorecard-unreadable> dry=<0|1|-> project=<p|-> filed=<-|dry|new <url>|already|open-reused|list-unreadable|failed>
```

## Knobs

Settings rows, seeded by `worker/jobs/schema.d/202611121831-bh-9419-inspector-lever.sql`
(the C0 seed has `level`, `metric`, `target` and `file_max_day`):

| Row | Seed | Code fallback |
|---|---|---|
| `staff.inspector.lever_dry_run` | 1 | 1 (dry) |
| `staff.inspector.quote_lines` | 30 | 30 |
| `staff.inspector.fresh_min` | 20 | 20 |
| `staff.inspector.lever_max_run` | 1 | 1 |
| `staff.inspector.issue_list_max` | 1000 | 1000 (at most 1000) |
| `staff.inspector.quote_line_chars` | 300 | 300 |

The Vercel and Cloudflare reads use `SERVED_SHA_HTTP_TIMEOUT` through
`ssw_vapi`. The test seams `INSPECTOR_NOW` and `INSPECTOR_CF_BASE` work only
with `HARNESS_TEST_SANDBOX=1`.

## Tests

`tests/staff-inspector-lever.bh-9419-test.sh` drives the lane against the REAL
jobs worker and fake Vercel and Cloudflare APIs in
`tests/lib/inspector-world.bh-9419.mjs`, with a `gh` stub on PATH. No call
leaves the box.
