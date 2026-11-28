# BH-10211 C0: the shadow-read counter and the READY check

Slice C0 of BH-10211. It adds the evidence a person reads before moving a
lane's `lane.<id>.gh_source` row from `shadow` to `record`. It changes no
`gh_source` row.

## The counter

`prr_read` (bin/lib/prr-shadow.sh) in step `shadow` now calls
`prr_count_add` (bin/lib/prr-count.sh) once per read. The counter is a
box-local file per lane per UTC day:

    <root>/logs/prr-count/<lane>/<YYYY-MM-DD>.tsv

Rows are `<key>\t<count>`:

| key | meaning |
| --- | --- |
| first | epoch of the first counted read that day |
| last | epoch of the newest counted read |
| agree | the record and GitHub norms were equal (no log line), or a BH-10213 `hit-rc:<n>` answer equal to the GitHub rc |
| mismatch | they differed, or a `hit-rc:<n>` was not the GitHub rc (the PRR_SHADOW line in logs/prr-shadow.log) |
| miss | the record missed (the PRR_MISS fallback=none line) |
| miss.<word> | the same, per miss word (`field:run_id`, `none`, `stale` ...); a word outside `[a-z0-9_:.-]` or over 40 chars is `miss.other` |
| skip | no compare: the GitHub read failed, or a norm output was empty |

The `off` and `record` steps count nothing. The counter never changes the rc,
the out file or the log lines of `prr_read`. A lock timeout
(`PRR_COUNT_LOCK_S`, default 2 s) writes nothing and the lane goes on.

Why `logs/` and not `state/`: the counter is a tally of reads, the same kind
of evidence as `logs/prr-shadow.log`. It is box-local. A shadow read on a
lane-run machine counts on that machine, and the count is not carried to the
hub. That undercounts `agree` and can only make READY later, never earlier.
Under `state/` the counter broke two read-only contracts (the r1 and r2
builds): `tests/lane-run-inputs-mc-manifest.bh-6889-test.sh` T1b (a
merge-conductor run may write only its `.rw` paths or machine-local dirs) and
`tests/main-red-pr-pair.bh-9890-test.sh` A10 (`--explain` leaves `state/`
unchanged). Both suites treat `logs/` as machine-local.

Retention: when `prr_count_add` creates a new day file, it deletes that lane's
day files older than `PRR_COUNT_KEEP_DAYS` (default 14) days.

## The READY rule

`bin/prr-shadow-ready.sh <lane>` reads every kept day file of the lane.

- hours = floor((now - the oldest `first`) / 3600)
- agreed = the sum of `agree`
- mismatch = the larger of the sum of `mismatch` and the count of
  `PRR_SHADOW lane=<lane> ` lines in logs/prr-shadow.log at or after the
  oldest `first`

READY needs hours >= `PRR_READY_HOURS` (48), agreed >= `PRR_READY_MIN_AGREED`
(100), mismatch = 0 and a readable counter. `miss` and `skip` do not block.
No counter is NOT READY `why=no-counter`, rc 2. A malformed file is NOT READY
`why=unreadable`, rc 2. The knobs are rows `lib.prr-count.<lower env>`
(catalog/lanes.d/_lib.prr-count.json).

The window is every kept day (up to 14 days), not only the last 48 hours. A
mismatch stays visible until its day file is pruned.

## Operator steps

These replace the grep counts in 2026-11-25-BH-9938-partial-read-lanes.md.

1. On the hub, run `bin/prr-shadow-ready.sh --all`. It prints one line per
   `catalog/lanes.d/*.knobs.d/GH_SOURCE.json` file (12 lanes at this build). Add `--md` for a
   Markdown table.
2. If a lane prints `NOT READY why=no-counter`, wait: the counter starts at
   the first shadow read after this change deploys.
3. If a lane prints READY, the owner sets the row
   `lane.<id>.gh_source=record`. The script never writes a row.
4. To see why a lane misses, read the `miss.<word>` rows of its day files.

## Remaining slices of BH-10211

The merge close-out files these as child issues.

- C1: the dequeue-watch gather step and the `PRR_MISS field:run_id` /
  `PRR_MISS none` cause (read the `miss.<word>` rows of this counter first).
- C2: break-it shadow results and a daily count by kind in the digest source.
- C3: stopped lanes (Archie, post-merge QA), a required stop reason, and the
  harness-ctl list that must not read a stop file from a box outside the fleet.
- C4: Mac human verdicts with no human token, after C2.
