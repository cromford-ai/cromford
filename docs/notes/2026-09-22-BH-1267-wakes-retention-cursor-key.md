# BH-1267 — wakes retention prune, `idx_wakes_at`, and a lowercased wake-cursor key

Doc: EVENTS

Three follow-ups from the head-bound review of #1104 (BH-1063).

## 1. The wake-cursor mirror never worked on a box with a capital letter in its name

`bin/wake-loop.sh` built its settings key as `wake-cursor.$JOBS_BOX`, and
`_setting_key_ok` (`bin/lib/jobs/settings.sh`) accepts `[a-z0-9_.-]` only — the
same charset `PUT /api/settings` enforces. `_jobs_box_name` preserves case from
`BOX_NAME`, `state/box-name` or `hostname`, so on a box called `TestBox` the key
was refused client-side, with no request, and both call sites swallow that rc
(`|| true` on the mirror write, `|| __wl_seed=""` on the seed read). The mirror
was a silent no-op and the seed never happened, which is exactly the loss
BH-1034.4 added the mirror to stop: a box restored without `state/` asks for the
whole unacked backlog and re-launches every lane in it.

What changed: one `WL_CURSOR_KEY="wake-cursor.$(… | tr 'A-Z' 'a-z')"` computed
once after the jobs-client source and used at both sites. `_jobs_box_name`
already strips to `A-Za-z0-9._-`, so case was the only normalisation left, and it
now happens in one place so write and read cannot disagree.
`tests/wake-cursor-key-lowercase.bh-1267-test.sh` drives the real loop and the
real client on `JOBS_BOX=TestBox` and on `Orgo-Desktop.1`; the existing
lowercase-box suite (`tests/wake-cursor-writethrough.bh-1034-test.sh`) is
unchanged and still green, which is the negative.

## 2. `wakes` grew for ever, and nothing indexed the column the lane reads

Nothing has ever deleted a wake. Rows arrive from every push, PR, check suite
and deploy on every fleet repo, and the daily doorbell lane reads a time window
over all of them.

- `worker/jobs/schema.sql` gains `CREATE INDEX IF NOT EXISTS idx_wakes_at ON
  wakes(at)`, and `wakes` gains a `CREATED_TABLES` entry (BH-658) carrying the
  table and all three indexes. Both are additive and `IF NOT EXISTS`.
  `bin/harness-sync.sh` applies `schema.sql` statement by statement before
  `wrangler deploy` (BH-1000) and is what reaches the live database first; the
  self-create is the belt.
- `POST /api/wakes/prune {days, limit?}` deletes rows whose `at` is older than
  `days`, OLDEST FIRST, at most `limit` (1..5000, default 5000) per call, and
  answers `{deleted, before, days, limit, capped, as_of}`. `days` has no
  default: absent, `0`, negative, fractional, a string or over 3650 is a 400
  that runs no statement. Rows go by age whatever their `acked_at` — the loop's
  guard is its own id watermark, so a 30-day-old row is behind every box's
  cursor, and an unacked one left by a failed ack slice would otherwise be
  immortal.
- `wakes_prune <days>` in `bin/lib/jobs/queue.sh` and the `wakes-prune` verb
  refuse the same values client-side, print TSV `deleted before capped`, and
  answer rc 1 with empty stdout on any failure including a 404 from a worker
  that predates the route. `JOBS_ALERT=0`, like `wakes_summary`.
- `bin/doorbell-coverage-check.sh` calls it once per full run, after the
  registry walk, behind `WAKES_RETENTION_DAYS` (default 30, `0` = off, a
  non-numeric value prunes nothing and logs `retention ignored`). A `--repo` run
  never prunes. A failed prune logs `failed`, never `deleted=0`, and cannot move
  a doorbell verdict, the `checked=…` line or the `--strict` exit code.

**Measured, because the plan guessed the other way:** the summary's
`at >= ?1 GROUP BY repo ORDER BY repo` keeps choosing `idx_wakes_dedupe` with or
without `ANALYZE`, because that index already delivers repo order. Ordering the
prune by `id` was a plain scan too. `ORDER BY at` is what makes `idx_wakes_at` a
covering index search — and age is the ordering retention means anyway, so the
prune orders by `at` and the index earns its write cost there.

## 3. Deploying the worker

No code. `bin/harness-sync.sh` already applies each `worker/*/schema.sql` and
runs `wrangler deploy` on the hub for a changed `worker/` (BH-1000,
`bin/fleet-propagate.sh`). The post-merge probes ride in the PR body as a named
condition; this change claims BUILT, not deployed.

Command/state touched: no new state, no new cron line, no new lock. The prune's
watermark is the data itself (`at < now - days`), recomputed each run. The knob's
settings row is `lane.doorbell-coverage-check.wakes_retention_days`, reached
through the `lane_env_apply` call the lane already makes.
