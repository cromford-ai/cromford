# Hotspot split tickets (BH-6739, BH-6543.2)

Doc: OPERATING, CONFLICT_HOTSPOTS

## The gap

`bin/conflict-hotspots.sh` measures which files collide most, and
`bin/conflict-hotspots-fleet.sh` stores the rows for display. No code compared
a row with a threshold or filed a ticket. A file with 14 replayed conflicts in
30 days got no split ticket.

## What changed

- New hub lane `bin/hotspot-split-ticket.sh`, weekly, Monday 04:53Z
  (`cron/lanes/732-hotspot-split-ticket.cron`, registry
  `catalog/lanes.d/hotspot-split-ticket.json`, no knobs). It runs for this
  deployment's repo (`HARNESS_REPO`).
- Its input is `GET /api/conflict-hotspots?project=<repo>&limit=10`: the
  stored output of `bin/conflict-hotspots.sh --ref origin/main --top 10`. The
  box that owns the checkout measures it weekly (`bin/conflict-hotspots-fleet.sh`,
  Sunday 03:23Z) and PUTs the rows. The hub runs no git scan. `fleet.conf` puts
  cromford on `box-small`, not on the hub.
- The run stops when the stored run is absent (`never-measured`), names
  another repo (`repo-mismatch`), or its `last_ok_at` is older than the
  settings row `hotspots.split_max_age_days` (seeded 14; no row = 14; a value
  outside 1..365 stops the run with `max-age`) (`stale`).
- A row is a candidate when its conflicts are at least the settings row
  `hotspots.split_threshold` (seeded 10; no row = 10; a value outside
  1..10000 stops the run).
- A candidate is skipped when its path matches a glob in the hub's
  `catalog/list-files.tsv` (`listed`, the `bin/list-file-lint.sh` match), when
  it has a `hotspot_tickets` row (`recorded`), when one contents read on main
  (`GET repos/<slug>/contents/<path>?ref=main`) answers 404 (`gone`: it already
  left git), or when an open
  issue carries its marker `<!-- harness-hotspot-split: <path> -->` (`reused`:
  the row is written with that issue number).
- Else the lane files ONE `ai-build` issue `Split <path>: <k> conflicts in
  <days> days` with the body from `prompts/hotspot-split-ticket.md`, then
  writes the row through `PUT /api/hotspot-tickets`.
- New D1 table `hotspot_tickets (repo, path, issue, filed_at, actor)`, primary
  key `(repo, path)`. The PUT is insert-once: a replay answers 200, a
  different issue for the same path answers 409 with the stored row.

## Retention

Rule `hotspot_tickets.age` in `worker/jobs/src/routes/retention.js`, run by
the hourly `bin/d1-retention.sh` (dry run first: `retention.dry_run`; one
`retention_runs` row per rule per run). The window is the settings row
`retention.hotspot_tickets.days` (seeded 365; 0 = off). A row is the "filed
once" memory; after the window it is deleted and a path that is still hot may
file a new split ticket. The GitHub issue keeps the history. The index
`idx_hotspot_tickets_filed (filed_at)` serves the rule's read. Growth is at
most 10 rows a week.

## Failure

- STOP (nothing filed, `stopped=<why>` on the summary line, one warn alert
  `hotspot-split-ticket`): `threshold`, `threshold-unreadable`, `max-age`,
  `measure-unreadable`, `never-measured`, `repo-mismatch`, `stale`,
  `bad-output`, `list-catalog`, `rows-unreadable`,
  `rows-truncated`, `issue-search` (the list failed or hit its 1000 cap),
  `template`.
- A contents read that fails with anything but 404 counts `failed=`; that
  path is not filed this run and the warn alert names it.
- A failed create writes no row; the next run tries again. A failed row write
  leaves the issue open; the next run finds its marker and writes the row with
  no second issue. Both count `failed=` and send the warn alert with the paths.
- The one window for a second issue: the row write fails AND someone closes
  the issue before the next run.

## Operate

- Off: `bin/harness-ctl.sh off hotspot-split-ticket`
  (`flags/lane-off-hotspot-split-ticket`).
- Dry run: `bin/hotspot-split-ticket.sh --dry-run` logs `would: file …` and
  writes nothing.
- Read: `tail -n 5 /root/harness/logs/hotspot-split-ticket.log`. One summary
  line a run: `hotspot-split-ticket repo= ref= threshold= rows= over= listed=
  gone= recorded= filed= reused= written= failed= dry_run=[ stopped=]`.
