# utilization: the hourly snapshot tracer (BH-4008, slice 1 of BH-3988)

Doc: VERIFICATION-MAP

## What changed

The fleet now writes down, every hour, how much of its build capacity each
project is using. This is the thinnest end-to-end path. Its BH-3988 siblings
add the tickets, pauses and PRs sections, the history read, the full verdict,
the went-quiet alert and the console screen.

- **Table.** `utilization_snapshots (project, hour, verdict, payload, box,
  as_of)`, primary key `(project, hour)`, index on `hour`. It ships in
  `worker/jobs/schema.sql`, which `bin/harness-sync.sh` applies before
  `wrangler deploy`. CREATE only.
- **Routes.** `PUT /api/utilization` validates, upserts on `(project, hour)`
  and prunes that project's rows older than `retention_days` (default 35,
  clamped to 7..90) in the same batch. `GET /api/utilization` answers the
  newest row per project. Both sit behind the bearer, and an unapplied table
  answers 503 `utilization_snapshots schema not applied`.
- **Client.** `utilization_put` and `utilization_rows` in
  `bin/lib/jobs/utilization.sh` (the `utilization` jobs-client module). A 404
  from a worker that does not have the route yet is rc 1 for both verbs. It is
  never "written" and never "no rows".
- **Collector.** `bin/utilization-push.sh`, hub only, at `:07` every hour
  (`cron/lanes/724-utilization-push.cron`, behind `hub-lease.sh check`). For
  each fleet.conf project it runs every `util_section_*` in
  `bin/lib/utilization/section-*.sh`, merges them, asks `util_verdict`
  (`bin/lib/utilization.sh`), and PUTs one row for the hour the run started.
  Today there is one section, `builds` (`running`, `pool_cap`, `free_slots`),
  and the verdict is always `unknown`. A reading that failed is `null` and
  `basis.<section>:"unmeasured"`, never 0.
- **Log.** One line per run in `logs/utilization-push.log`:
  `projects=N written=N failed=N deferred=N`, plus `put failed project=<p>`
  for each failed PUT. The lane exits 0 whatever the PUTs answered.

## Switch and knobs

- Off: `bin/harness-ctl.sh off utilization-push`
  (`flags/lane-off-utilization-push`), the `utilization-push-off` switch, or
  `UTIL_PUSH_ENABLED=0`.
- `UTIL_RETENTION_DAYS` (default 35, 7..90): days of rows kept per project.
- Both are settings rows on the `utilization-push` lane
  (`catalog/lanes.d/utilization-push.json`), read through `lane_env_apply`.
  The code literals are the fallbacks.

## Check it

```bash
curl -s -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/utilization" | jq '.rows | length'
tail -1 /root/harness/logs/utilization-push.log
```

After the first `:07` hub tick following the deploy, the first number equals
`bin/fleet-conf.sh --projects | wc -l` and the log line shows `failed=0`.
