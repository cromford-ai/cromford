# Who spends the GitHub REST budget (BH-6974, wave 1 of 3 of #6545)

Doc: DORA, gh-quota

## What changed

- `bin/gh-budget-report.sh` is new. It prints REST calls per lane per hour,
  per repo, the top 10 (lane, endpoint class) pairs and calls per merged PR.
  It writes `state/gh-budget/<date>.json` (`<date>-<window>.json` when the
  window is not `24h`). It makes no GitHub API call.
- `GET /api/metrics/gh-ledger` takes an optional `group` parameter:
  `lane-hour`, `lane-class` or `repo`. A grouped answer counts REST rows only
  and adds `group` and `totals` (`rest_calls`, `rest_counted`,
  `graphql_calls`, `graphql_counted`). The totals are a second read with no row
  cap, so a `truncated` answer still has exact totals. With no `group`, the
  answer does not change. Any other `group` value is a 400.
- `bin/dora-digest.sh` runs the report once (knob `DORA_GH_BUDGET`, default 1)
  and passes its own merge count with `--merged`. The digest JSON gets a
  `gh_budget` key, and the text gets one `github REST:` line with the top 5
  pollers and the calls per merged PR.

## What the report reads (the ticket named two other sources)

1. The ticket named a `gh_budget` table. That table holds one rate-limit
   snapshot per token and has no lane. The per-call numbers are in `gh_ledger`
   (BH-1574), which every box pushes every 10 minutes.
2. The ticket named `logs/gh-rest.log`. That file does not exist. The per-call
   file of a box is `state/gh-rest-ledger/<hour>.tsv`. The report reads it when
   the worker does not answer, or answers with no `group` echo (a worker
   deployed before this change), and its first line says so. `--local` reads
   it and skips the worker.

## Definitions

- Endpoint class: the ledger's `path_class` (ids folded to `N`, shas to `SHA`).
- REST: `resource` is not `graphql` and `path_class` (leading `/` removed) is
  not `graphql`.
- Ranking: `counted` (what GitHub charged), then `calls`, then the name.
- Repo: `<owner>/<repo>` from a class that starts `repos/` or `/repos/`.
  Everything else is `(no repo)`. A repo name with digits shows folded
  (`Org/appN`), because the writer folds digits before a row is stored.
- Calls per merged PR: `--merged <n>`, else `GET /api/metrics/dora?days=<D>`
  `totals.merged` (fleet mode only), else `n/a (merge count absent)`.
  `merged = 0` is `n/a (no merges in window)`.
- A lane with no row in the window is absent, never `0`.

## JSON format

`state/gh-budget/<date>.json`: `generated_at`, `window {arg, hours,
since_hour}`, `source` (`fleet` | `local`), `source_note`, `state_file`,
`truncated {lane_hour, lane_class, repo}`, `totals`, `merged {count, source,
days}`, `per_merged_pr {calls, counted}`, `per_merged_pr_why`, `top [{lane,
path_class, calls, counted}]` (10), `repos [{repo, calls, counted}]`,
`lane_hour [{hour, lane, calls, counted}]`, `notes []`. Wave 3 of #6545 reads
`top`.

## Knobs

- `DORA_GH_BUDGET` (env, row `conf.dora-digest.dora_gh_budget`,
  `flags/dora-digest.conf`): `1` runs the report in the digest. Default 1.
- `GH_BUDGET_KEEP_DAYS` (env, then row `conf.gh-budget-report.keep_days`):
  days of `state/gh-budget/` files to keep. Default 90. A value that is not a
  positive integer uses 90 and writes one `logs/gh-budget-report.log` line.
  Each run that deletes a file writes one `swept <n> file(s)` line.

No new env var is required in any environment.

## Open items

- `bin/dora-digest.sh` has no cron line in `cron/`. Its header says 07:00Z on
  the hub. Until a cron line exists, the `github REST:` line appears only when
  an operator runs the digest.
- A folded repo name (`Org/appN`) could use the `project` column to show the
  real slug.
