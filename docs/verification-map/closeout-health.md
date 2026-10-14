# Build-record close-out health

**What it is:** the two checks that notice a finished build whose board close-out
never happened — `bin/pipeline-health.sh` check 4 ("N build result(s) >1h with no
board close-out") and the EMPTY-URL half of check 5. Both subtract records that
are already over (PR merged, PR closed unmerged, `SUPERSEDED` marker) or aged out
past `CLOSEOUT_AGE_OUT_H` (default 168h), and page once per project rather than
once per record. `bin/sweep-stale-builds.sh` annotates its survivors with the
same verdict through the same function.

**How an operator reaches it:** `cron/hub.cron` runs `bin/pipeline-health.sh
--dispatch` every 10 minutes on the hub (BH-5941). The dispatch starts one
`bin/pipeline-health.sh --project <p>` per project, and checks 4 and 5 run in
those project runs. `bin/pipeline-health.sh --project <p>` runs one project's
checks by hand; with no argument every section runs in one process.
`bin/sweep-stale-builds.sh` runs daily. Output lands
in `logs/ALERTS.log`, `logs/pipeline-health.log` and
`logs/sweep-stale-builds.log`. Mission Control's pipeline pane reads the middle
one through `bin/fetch-log.sh which=pipeline`.

**How to drive it:**

| what | how |
|---|---|
| the two checks, extracted verbatim | `bash tests/pipeline-health-closeout-ageout-test.sh` |
| the skip set: an aged-out dir is not read again (BH-5941) | `HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-closeout-skip.bh-5941-test.sh` |
| the dispatch, the per-project runs and their locks (BH-5941) | `HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-dispatch.bh-5941-test.sh` |
| the age-out writer's dedupe, on a file past the pipe buffer | `HARNESS_TEST_SANDBOX=1 bash tests/closeout-record-aged-dedupe.bh-1044-test.sh` |
| the neighbouring blocks in the same file | `bash tests/pipeline-health-detectors-test.sh`, `-flake-rate-test.sh`, `-permared-test.sh` |
| the whole health script, end to end | run it with `HARNESS=<scratch tree>` and a stubbed `PATH` (see the PR body's reproduction) |
| the sweep lane | `bash tests/sweep-stale-builds-test.sh` |
| the remediation handler that reads the alert key | `bash tests/remediation-hook-test.sh` |

**Files it owns on a live box:**

- `state/pipeline-health/<p>/closeout-aged.tsv` — the skip set (BH-5941). One
  line per dir already aged out: dir, RESULT mtime, kind (`aged` or
  `emptyurl`). Checks 4 and 5 count such a dir and do not read it again while
  its RESULT mtime is unchanged and still past the ceiling. A gone or rewritten
  dir is pruned. Losing the file costs one tick of re-reads.
- `locks/pipeline-health-<p>.lock` — one project run at a time (BH-5941).

- `state/closeout-aged-out.tsv` — the audit trail. One row per aged-out build
  dir: `project`, `build dir`, `RESULT` first line, reason. ONE row: since
  BH-1044 `closeout_record_aged` answers "already recorded?" with a single awk
  process instead of `cut -f2 | grep -qxF`, which died of SIGPIPE under this
  script's `set -o pipefail` whenever the match sat outside the last 64 KB — the
  dedupe then reported "not found" and appended the row again, every 10 minutes,
  which is how the hub's copy reached 45 MB. Pinned by
  `tests/closeout-record-aged-dedupe.bh-1044-test.sh`.
  `bin/disk-clean.sh` (daily, 04:47Z) bounds the file from the other side: a row
  whose build dir carries a launch stamp older than `CLOSEOUT_TSV_KEEP_DAYS`
  (default 30) **and whose build dir no longer exists** moves to
  `state/archive/closeout-aged-out.<YYYYMMDD>.tsv`, under this same lock. A row
  with no parseable stamp is kept, and so is a row whose dir is still on the box
  — the checks above would re-record that dir on the next tick, so archiving it
  would only move the growth. See
  [disk-clean-hygiene.md](disk-clean-hygiene.md).
- `state/health-alerted.json` / `state/health-active.txt` — the TTL dedupe map
  and the retraction set, shared with every other check in the file.
- `locks/closeout-aged-out.lock` — held for the milliseconds of one append,
  never across a network call.

**Knobs:** `CLOSEOUT_AGE_OUT_H` in `env/global.env` (hub only, default 168,
non-numeric falls back to 168). See `env-templates/global.env.example`.

**What must never regress:** an outage or a missing ledger row is NOT terminal.
Both checks keep paging when they cannot tell — a check that goes quiet on a
blink of the coordination DB hides the wedge it exists to find.
