# The backup-freshness "flake" was a 35-minute window after midnight UTC

Doc: backup-freshness

## Why

`tests/backup-freshness-test.sh` F13 ("a row with no collection time must
produce no record") failed two merge trains on 2026-09-21/22 and passed
everywhere else, so the drain treated it as flaky and re-ran it. It was not
flaky. Both failing runs were inside the first 35 minutes after 00:00Z (record
ts `20260921T235843Z` = NOW 00:03:43Z, `20260922T001956Z` = NOW 00:24:56Z);
main's green runs were 23:47Z and 00:44Z, both outside it.

GNU `date -u -d "" +%s` prints **today's 00:00:00** and exits 0. The writer,
`bin/backup-records-sync.sh`, parsed the collection time with exactly that call
and then checked the answer was numeric — which it always was. So a row with no
collection time was not refused, it was DATED at midnight, and for
`BF_RECORD_FRESH_MIN` (35) minutes after 00:00Z that fabricated date sat inside
the collection window and the row was written. Every other minute of the day the
stale branch caught the same row and F13 passed. The comment two lines above the
bug already said the right thing — "Dropped, not defaulted" — the code just
never did it.

Two consequences worth naming. An undatable record is one that can never age
out, which is the frozen-record failure the whole lane is built to avoid. And a
test that is red for 35 minutes a day is treated as noise, which is how a real
regression in this file would have been missed.

In production the worker stamps `backup_reported_at` server-side
(`worker/jobs/src/routes/boxes.js`) and `bin/lib/jobs/boxes.sh` emits it
verbatim, so no live record was written from an empty value; the defect was
confined to what the suite could reach. It is still a correctness fix in the
writer, not a test fix.

## What changed

**`bin/backup-records-sync.sh`** — a positional shape gate runs BEFORE `date`:

```sh
case "${REPORTED:-}" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;;
  *) SKIPPED=$((SKIPPED+1)); continue ;;
esac
```

The order is the fix. Checking after the parse cannot work, because the parse is
what invents the value. The gate also drops a blank field and every relative
word `date` would otherwise guess at (`now`, `today`, `yesterday`) — an
empty-string-only check would have passed the first case and still written the
second. A row it refuses is counted in `skipped`, never silently dropped. No
other line in the file changes, and `bin/lib/backup-freshness.sh` is untouched:
the reader was always right.

**`tests/backup-freshness.bh-1308-test.sh`** (new) pins the window with the
clock HELD (`BACKUP_SYNC_NOW` = today's midnight + an offset), so the cases are
deterministic at any wall-clock time instead of reachable for 35 minutes a day:
empty collection time at 00:10Z and at 00:40Z, a blank one at 00:10Z, and the
control that proves the gate did not simply blind the lane — a row dated 00:08Z
still lands, with three fields and its report's mtime. Every case runs the real
`bin/backup-records-sync.sh`; `BH1308_SYNC_OVERRIDE` points the suite at another
copy of the writer, which is how the red-before-green run was done against
`main:bin/backup-records-sync.sh`.

## The Broken pipe on line 269 was separate, and is fixed too

The same failing runs carried `bin/lib/backup-freshness.sh: line 269: printf:
write error: Broken pipe`. That line is `bf_rows`' own printf, and the reader
that closed under it was the suite's `rowfor` helper, which piped `bf_rows` into
`awk '...{print;exit}'` — the selector exits on the first match while the writer
is still printing later boxes. It changed no assertion (and the two production
callers, `bin/fleet-status-push.sh` and `bin/pipeline-health.sh`, capture with
`$( )` and never close early), but it is noise on a suite already being read as
flaky. `rowfor` now drains `bf_rows` into a variable and selects from the
variable.

**Why it looked intermittent, and how the new suite makes it deterministic.**
Whether an early-exit reader closes the pipe in time is a property of the awk on
the box: gawk (the CI runner) processes records as they arrive and exits on the
first match; mawk (Debian's `/usr/bin/awk`, this fleet) reads a whole block
first and usually outlives the writer, so the error never appears. The new
suite's R6 runs the whole of `tests/backup-freshness-test.sh` with SIGPIPE
ignored and `awk` shimmed to `mawk -Winteractive` — mawk with line-buffered
reads, same semantics — and demands zero `Broken pipe` lines. With the shim the
old `rowfor` reproduces the exact line from the failing trains, and reverting
`rowfor` turns R6 red; without it the case is green on mawk either way.

## Not done here

The ticket's second half (a per-suite trace-safety budget that scales with
runner load) shipped separately in PR #1314, merged 2026-09-22 04:49Z:
`TRACE_SAFETY_TEST_TIMEOUT` 120→300 s, shard job cap 25→35 min.

The ticket also says the drain treats `tests/backup-freshness-test.sh` as
known-flaky. There is no artifact that names it: `docs/FLAKY-TESTS.md` describes
a flake signal derived from run history per head sha, not a checked-in list of
suite names, and nothing under `bin/` or `.github/` names this suite as an
exception. The re-run is `bin/blocked-resolver.sh`'s generic
`rerun-failed-jobs` (line 3075), which is not suite-specific. Nothing to remove
— what made this read as a flake is fixed at the source instead.

The other unvalidated `date -u -d "$VAR"` call sites in `bin/`
(`alert-digest.sh`, `alert-triage.sh`, `fly-pool.sh`, `pipeline-health.sh`,
`fleet-status-push.sh`, `postmerge-qa.sh`) are out of scope: none of them gates
a write, and each guards its own emptiness or falls back to a distinct value.
They are worth a sweep of their own if anyone wants one.
