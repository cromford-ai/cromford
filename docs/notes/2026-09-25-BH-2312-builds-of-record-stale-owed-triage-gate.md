# BH-2350 (BH-2312.3): the orphan scan and the triage gate read the builds-of-record ledger

Doc: DB-COORDINATION-SPEC

## What changed

**`bin/stale-owed-tickets.sh`, section 4.** The `find` over `builds/*/RESULT` is
unchanged, byte for byte. After it, a ledger pass reads `bor_union <project>` for
every board project and alerts on a REVIEW_BLOCKED build that has no dir on this
box and whose job has no `verdict` artifact (`job_verdict_state <job_id>` rc 2).
Such a build used to be invisible: the find only sees local dirs.

- A row is skipped when it has a local dir (bare, `pool-`, `fly-`), when its job
  is already staged here as a `-remote<ts>` copy (a `JOB_ID: <job>` line in a
  local RESULT), when `updated_at` does not parse, when it is under 90 minutes
  old, or when it is older than `STALE_ORPHAN_LOOKBACK_H` hours (default 168,
  read through the lane's settings rows and registered as a knob in
  `catalog/lanes.d/stale-owed-tickets.json`).
- One ALERTS line per `<project>:<build_dir>`, ever, deduped in the box-local
  `state/stale-owed-orphans.json` (key -> first-flagged epoch). The line is
  written first, then the key is stamped: a crash or an unwritable store
  re-alerts, it never goes silent. Keys older than the lookback plus a day are
  pruned.
- An outage alerts nothing and stamps nothing. `bor_union` rc 1 logs
  `ledger read failed — local find only` to `logs/stale-owed.log`, and a
  `job_verdict_state` rc 1 skips the row. A capped read (`BOR_TRUNCATED=1`)
  logs `ledger read capped at <n> rows — older records not scanned`.

**`bin/triage-gate.sh`, section 3b** (after the section 3 local sweep, so it also
runs when the sweep brake held). With `bor_list` loaded and `JOBS_BOX` set, it
reads `bor_list <project> <.since> 50`, the window staging reads. A row counts
when its box is not `JOBS_BOX`, it has no local dir and there is no
`state/remote-results/<project>/.handled/<job>.job`. Any such row prints
`RUN remote-results-pending`, so the tick's staging (`bin/lib/rt/staging.sh`)
pulls it. The gate stages nothing itself. The set (`key<TAB>result_line`,
sorted) is fingerprinted into `state/<project>.remotefp` (fp, epoch), and the
same set within 45 minutes falls through to sections 4-6. `bor_list` rc 1 or 2
changes nothing.

## Why 3b reads staging's accounting

Staging names its copies `<project>-<KEY>-remote<ts>`, never the ledger
`build_dir`, so `bor_local_dir` never finds a staged remote build. A 3b that
asked only "no local dir" would wake a paid tick every 45 minutes for every
remote row ever recorded. Staging's `.since` watermark and `.handled` markers
are what "already pulled" means on this box, so 3b reads both and writes
neither.

## Assumptions (declared in the plan)

- The wake reason is the existing `remote-results-pending`, not a new
  `results-pending-remote`. Four consumers route on the exact name
  (`bin/lib/rt/scope.sh`, `bin/lib/triage-shards-lib.sh`, `bin/run-triage.sh`,
  `bin/pipeline-health.sh`); a new name would buy a full-context tick for a
  results sweep.
- The find always runs. The ledger pass only adds builds with no local dir, so
  projects with no board stay covered and a local dir is never alerted twice.
- The dedupe key is `<project>:<build_dir>`, not the ticket key: a ticket can
  have several builds.
- `job_verdict_state` takes a job id, so the row's job id is passed.

## Tests

- `tests/stale-owed-db-first.bh-2312-test.sh` — the real lane over the real
  client and lib, a stub `curl` worker.
- `tests/triage-gate-db-first.bh-2312-test.sh` — the real gate and lib, a stub
  client feed and a fake gh board.
