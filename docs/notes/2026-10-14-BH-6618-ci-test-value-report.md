# CI test value report: the tracer CLI (BH-6636, BH-6618.0)

Doc: CI-RUNNERS, FLAKY-TESTS

## What it is

`bin/ci-test-value-report.sh` is an operator CLI. It has no cron line and no
lane. It lists the failed `harness-ci.yml` runs of a window, reads the failed
jobs of each run and their logs, and writes one row per failed unit. In this
slice no rule decides a row, so every row is `unknown U1.undecided`. The
sibling tickets BH-6618.1 to BH-6618.4 add the rules, the model pass, the
extra sources and the richer report.

## How to run it

```bash
bin/ci-test-value-report.sh --days 1 --no-model --out /tmp/ctv
jq '.totals, .coverage' /tmp/ctv/$(date -u +%F)/ci-test-value.json
```

Flags: `--repo owner/name` (default `example-org/cromford`), `--days 1..90`
(default 7, the N UTC days that end today), `--out DIR` (default
`$HARNESS/state/ci-test-value`), `--max-reads N`, `--no-model`, `--dry-run`.
`CTV_EXCERPT_LINES` (default 60) sets the log lines kept per failed unit.

Exit codes:

| rc | Meaning |
|---|---|
| 0 | Complete. Every day listed, every red run read, no stop. |
| 4 | Report written, `coverage.incomplete` is true. `coverage.stop` names `max-reads`, `budget-low` or `list-cap` when one fired. |
| 3 | No day of the window could be listed. No report, no `occurrences.tsv`. |
| 2 | Usage error or bad knob (nothing written), a broken rule registry, or another run holds `<out>/.lock`. |
| 1 | An internal step failed (classify, render). No report. |

`--dry-run` lists the days and prints
`ctv: dry-run days=N runs_listed=X red_runs=Y gh_reads=Z days_unlisted=U`. It
reads no job and no log, and writes no report.

## What it reads

Every GitHub read is `gh_rest GET` with `GH_ETAG=0`, through `ctv_gh_get` in
`bin/lib/ci-test-value.sh`. There are three families:

1. `repos/R/actions/workflows/harness-ci.yml/runs?created=D...`: one
   `per_page=1` read per day for `runs_listed`, then the `status=failure` pages
   (100 per page, 10 pages at most, which is the 1000-run cap of the list API).
2. `repos/R/actions/runs/<id>/attempts/<a>/jobs`: the jobs of the listed
   attempt. A job with conclusion `failure` or `timed_out` is a failed job.
   `cancelled` is not.
3. `repos/R/actions/jobs/<id>/logs`: the log of each failed job.

A job log holds ANSI colour codes. A `gh` that has `--allow-escape-sequences`
prints the headers only for such a body and exits 1 unless the flag is
passed. `gh_rest` then sees a 200 with an empty body and answers 75, so every
log is unread. The probe below found this on a live log. A `gh` without the
flag (the hub's gh 2.45) rejects it as `unknown flag` (rc 1) and prints an
ESC body raw. So `ctv_gh_get` passes the flag only on a log read, and only
when `gh api --help` lists it (probed once per run). The listing and jobs
reads never carry it. Every log is stored with its escape sequences removed,
so both kinds of `gh` give the same rows. The suite's gh shim refuses an ESC
body without the flag, as a newer `gh` does, and `SHIM_OLD_GH=1` acts as the
older `gh` (AT-GH).

### PROBE (2026-10-14, on the build box, read-only)

```
$ gh api 'repos/example-org/cromford/actions/workflows/harness-ci.yml/runs?per_page=1&created=2026-10-13' --jq .total_count
345
$ GH_ETAG=0 gh_rest GET repos/example-org/cromford/actions/jobs/115601085651/logs   # job "Tests, traced (shard 5/8)"
rc=75 status=200, 0 bytes
$ gh api -i -X GET repos/example-org/cromford/actions/jobs/115601085651/logs
rc=1: the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway
$ GH_ETAG=0 gh_rest GET repos/example-org/cromford/actions/jobs/115601085651/logs --allow-escape-sequences
rc=0 status=200, 284023 bytes, 206 '--- tests/' lines, 138 lines with an ESC byte
```

The real shard line is `2026-10-14T00:18:54.6820832Z --- tests/<suite>.sh rc=1 1s`,
the same form as the fixtures. So the log read stays on `gh_rest`, with no raw
`gh` call and no raw-by-design marker.

`gh_budget_low` (`bin/lib/gh-budget.sh`) reads `rate_limit` before each job or
log read. The settings reads of the libraries it sources are GETs to the jobs
worker.

## The read-only promise

The run writes no label, no comment and no worker row. Outside `--out` it
writes only the telemetry of the libraries it uses: the `gh_rest` quota ledger
(`state/gh-rest-ledger/`), the gh-budget cache and logs (`state/gh-budget/`,
`logs/ci-test-value.log`, `logs/gh-budget.log`) and the lane-gate knob markers
(`state/lane-gate/`, `logs/lane-gate.log`).

`bin/lib/gh-budget.sh` sources `bin/jobs-client.sh` by itself, and after a
fresh `rate_limit` read it publishes the reading to the jobs worker. The CLI
exports `GH_BUDGET_DB=0`, so that write does not occur.

AT-4 of `tests/ci-test-value.bh-6618-test.sh` proves this. It runs the whole
CLI against fixtures with a `gh` shim and a `curl` shim that refuse every
non-GET. It snapshots every file under a fresh `$HARNESS` and the checkout
before and after the run. Every changed path must be under `--out` or on the
named allowlist.

## The read budget

- `CTV_GH_MAX_READS` (default 3000) or `--max-reads N`. At the cap the run
  stops reading, and `coverage.stop` is `max-reads`.
- `gh_budget_low ci-test-value`, checked before each job or log read (not
  before the listing). rc 0 (low) stops the run with `coverage.stop`
  `budget-low`. rc 2 (unknown) proceeds.
- An rc 75 (or 44) read is unread. The run it belongs to counts in
  `coverage.unread` and keeps none of its rows. It is never cached.

## The read cache

`<out>/cache/` holds only data that cannot change: the listing of a closed
UTC day (`list/<D>-all.json`, `list/<D>-fail-p<P>.json`), the jobs of a
completed run (`run/<id>-a<a>-jobs.json`) and the log of a completed job
(`log/<job id>.txt`). A day is closed `CTV_DAY_CLOSE_MARGIN_S` seconds after
it ends (default 21600, 6 h), not at midnight: a run created at 23:50Z can
fail at 00:15Z, and a failure listing read at 00:05Z does not hold it yet. An
open day's listing is never cached (test AT-5d). A cache hit costs no
read. Writes use a temp file and `mv`. The log excerpt of each unit is
`cache/excerpt/<job id>-<n>.txt`.

## Outputs

- `<out>/occurrences.tsv`: one `#` header line, then one row per failed unit,
  columns `run_id attempt job_id day event is_batch head_sha unit rc secs class
  rule run_url job_url why`, tab-separated, `LC_ALL=C` sorted on run_id,
  attempt, job_id, unit.
- `<out>/coverage.json`: the counts the driver hands to the renderer.
- `<out>/<today>/ci-test-value.json`: `window`, `repo`, `generated_at`,
  `coverage{runs_listed, red_runs, red_runs_read, unread, gh_reads, incomplete,
  days_unlisted, stop}`, `totals{occurrences, by_class}`, `rules{}`.

A unit is one of these:

- A harness suite: the anchored line `--- tests/<x>.sh rc=N Ns` (also
  `tests/mc/`) that `bin/test-trace-safety.sh --gate` prints. An indented copy
  of that line is not a unit.
- A vitest or jest `FAIL <token>` line, only for a test-file token
  (`.test.`, `.spec.`, `__tests__/`).
- The `location:` line of a failed `node --test` test (worker-jobs,
  console-ui), once per file.

A failed job whose log names no failed unit gives one `job:<job name>` row
with rc `-`.

## The rule registry

`bin/lib/ci-test-value/rules.d/NN-<slug>.sh` holds one file per rule group.
`ctv_rules_load` sources the files once, in `LC_ALL=C` order, so the number
fixes the order. Each file defines `ctv_rule_<slug>` (a dash in the slug
becomes an underscore). A rule reads the `CTV_*` row variables. To decide the
row, it prints `class<TAB>rule<TAB>why` and returns 0. The first rc 0 wins. A
line that is not in that form gives `unknown U2.rule-error <slug>`. If no rule
decides, the row is `unknown U1.undecided`.

The six files in this slice are placeholders that return 1: `10-infra.sh`,
`20-flake.sh` and `50-main-flake.sh` (BH-6618.1), `30-order.sh`,
`40-followup.sh` and `60-batch-fix.sh` (BH-6618.2). The seams
`ctv_model_pass` (`bin/lib/ci-test-value/model.sh`, BH-6618.3) and
`ctv_fetch_sources` (`bin/lib/ci-test-value/sources.sh`, BH-6618.4) are no-ops
that return 0.
