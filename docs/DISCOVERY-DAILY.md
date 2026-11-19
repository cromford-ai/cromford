# Discovery daily (BH-9795)

The `discovery-daily` lane runs once a day per product project on the hub. It
reads the project's discovery sources, drops the items the code already knows,
asks a model narrow questions about each item that is left, and lets a rules
table in code decide what to do. Part 1 has one source: Sentry.

## What the lane does

`bin/discovery-daily.sh <project>` runs these steps (`dd_run` in
`bin/lib/discovery-daily.sh`):

1. It claims the run row `discovery-daily-run/<project>/<date>` in the jobs
   ledger. A `done` row stops the run with one log line. The first run writes
   `discovery-daily-since/<project>`.
2. It lists each source in `DISCOVERY_SOURCES`. A source with no credential or
   no project slug is `not-configured`: one log line, no fetch. A value that
   is not `^[a-z0-9,-]*$` (spaces removed) reads no source. A name with no
   `bin/lib/discovery/<name>.sh` is logged and skipped.
3. It saves each raw answer under `state/discovery-daily/<project>/<date>/` and
   deletes date dirs older than `DISCOVERY_RAW_KEEP_D` days (default 14).
4. It drops an item with no model call when: the item has fewer than
   `DISCOVERY_MIN_EVENTS` events; its ledger row is `ticketed`, `noise` or
   `failed`; or an open issue of the target repo holds the marker
   `<!-- discovery: <source>/<id> -->` (the row is healed to `ticketed`).
5. It counts the call in the day row and writes the attempt BEFORE the call.
   Then it makes ONE no-tools call through `bin/agent-call.sh` with a per-call
   budget (`DISCOVERY_MAX_USD`). Every fetched text is wrapped by `ui_wrap`.
6. The model answers four questions and writes a draft. It gives no verdict.
   `bin/lib/discovery/rules.sh` holds the questions and the decision table.
7. The table files an `ai-build` ticket (plus `hotfix` at or above
   `DISCOVERY_HOTFIX_24H` events in 24 h), comments on one open
   candidate ticket, or marks noise. The body has `## Scope`,
   `## Acceptance tests`, `## Out of scope` and the marker. The source id, the
   link and the event counts come from the fetch, never from the model.
8. It stops at `DISCOVERY_TICKETS_DAY` or `DISCOVERY_MAX_CALLS_DAY`. An
   item that fails `DISCOVERY_MAX_ATTEMPTS` times is `failed` and raises one
   warn alert `discovery-daily-failed`.
9. It marks the run row `done` with the counts and sends one Telegram summary
   through `bin/archie-tg-send.sh` (akey `discovery-daily:<project>:<date>`).

The lane shares the ledger, cap, attempt, filing and comment code of the
sentry-triage lane (`bin/lib/sentry-triage.sh`, BH-5620) through its `ST_*`
parameters. It never reads a ticket it filed as an item: items come only from
the source adapters.

`bin/pipeline-health.sh` runs the missed-run check on the hub
(`bin/lib/discovery-missed.sh`). A project with the lane on and no `done` run
row for yesterday raises ONE alert `discovery-missed:<project>:<date>`. The
check starts the day after the first run.

Off: `flags/lane-off-discovery-daily`, or `bin/harness-ctl.sh off discovery-daily`.

## Switch it on for a project

1. Run the setup command on the hub. It writes the per-project settings rows
   through `bin/harness-ctl.sh set`. A second run with the same input writes
   nothing.

   ```
   bin/discovery-setup.sh --project <project> --sources sentry --sentry-project <slug> [--repo <owner/repo>]
   ```

   With no `--repo`, tickets go to the project's `fleet.conf` repo. `--repo`
   writes `DISCOVERY_TARGET_REPO`; the value must be a repo `fleet.conf` names,
   else the setup refuses it and the lane reads nothing.
2. Add one line for the project to `cron/lanes/782-discovery-daily.cron`, in a
   PR:

   ```
   23 7 * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/discovery-daily.sh <project> >> /root/harness/logs/discovery-daily.log 2>&1
   ```
3. The first run writes the `discovery-daily-since/<project>` row. The
   missed-run check reads the project from the next day.

project-6-os is on (BH-9795): sources `sentry`, tickets in its `fleet.conf` repo `example-org/project-6`.
Its Sentry project slug is not set yet, so its runs log `sentry not-configured`
and make no call until the lead runs step 1 with `--sentry-project`.

## Add a source

1. Write `bin/lib/discovery/<source>.sh` with two functions:
   - `dd_src_<source>_list <raw-dir>`: one JSON line per candidate item on
     stdout, `{source, id, title, url, count, first_seen, last_seen,
     count_24h}`. Write the raw answer to `<raw-dir>/<source>-list.json`.
     Return 3 when the source has no credential or no project id
     (`not-configured`), 1 when the fetch failed (set `DD_SRC_ERR`), else 0.
   - `dd_src_<source>_detail <id> <out>`: the latest detail of one item in
     `<out>`. Return 1 when it is not available.
2. Register its knobs in `catalog/lanes.d/discovery-daily.json` and its names in
   `env-templates/lanes/386-discovery-daily.env.example`.
3. Add test cases to `tests/discovery-daily.bh-9795-test.sh` with a fake of its
   vendor (0 real calls in the PR suite).
4. Switch it on per project with `bin/discovery-setup.sh --sources <csv>`.

## Ledger rows

| Kind | Key | Status and detail |
|---|---|---|
| `discovery-daily` | `<project>/<source>/<id>` | `retry`, `diagnosed`, `ticketed`, `noise`, `failed`; the fetched fields, attempts, answers, the draft, the decision, the action |
| `discovery-daily-day` | `<project>/<date>` | `{filed: [<source>/<id>], calls: n}` |
| `discovery-daily-run` | `<project>/<date>` | `running`, `done`, `failed`; the run counts and `usd` |
| `discovery-daily-since` | `<project>` | `{since: <date of the first run>}` |
