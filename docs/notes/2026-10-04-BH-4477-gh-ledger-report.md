# BH-4477: `bin/gh-ledger-report.sh`, the caller × endpoint view of the GitHub REST ledger

Doc: GH-REST

**What changed.** A new read-only report over this box's
`state/gh-rest-ledger/<YYYY-MM-DDTHH>.tsv` files, the ones
`bin/lib/gh-rest-ledger.sh` `gh_ledger_append` writes:

```
bin/gh-ledger-report.sh [--last <N>h|<N>m] [--top <N>] [--dir <path>]
```

- `--last` is the window ending now (default `1h`). `--top` is the number of
  ranked rows (default 10, `0` = all). `--dir` defaults to
  `$HARNESS/state/gh-rest-ledger`.
- It groups rows by caller (column 2) and endpoint shape (method plus path
  class, columns 4 and 5), and prints `CALLS`, `COUNTED` and `UNCOUNTED` per
  group. It sorts by calls, then caller, then endpoint, so two runs over the
  same files print the same bytes.
- `TOTAL` sums every row in the window, including rows past `--top`, and
  `per_hour` is calls scaled to an hour.
- Ids collapse to `N` and 40-hex shas to `SHA`. The writer already does this.
  The report does it again so an old or hand-made row still groups correctly.
- `CALLS` counts HTTP requests. The writer ledgers one row per request, so each
  page of a `--paginate` read is already its own call. `UNCOUNTED` is the 304s
  answered from the ETag cache plus the 000s that never reached GitHub.
- Rows with fewer than 7 columns are torn appends and are skipped. An hour file
  the 48h sweep removed is just absent, and the header says how many hour files
  were read.
- A malformed `--last` or `--top`, an unknown argument, or a missing or
  unreadable ledger directory exits 2. A missing directory never prints a zero
  total. An empty window prints `no ledger rows in window` and exits 0.
- It reads files only, makes no API call and writes nothing.
  `GH_LEDGER_REPORT_NOW` (an epoch) pins the clock for tests.

**Why.** the operator's 2026-10-04 diagnosis of the hub's GitHub volume (9,361 requests
in the 19Z hour, from `state/gh-rest-ledger/2026-10-04T19.tsv`) was done by
hand. `bin/gh-quota-report.sh` shows caller and path class as two separate
blocks and only reads whole hour files. #4477 asks for a before/after reading
from this script in every slice's PR body.

**Scope note.** This is the report only. The plan also had a shared open-PR
snapshot helper with per-lane watermarks. the operator's 20:58Z comment on #4477
replaced that design with an event-fed `gh_objects` mirror, so the helper was
not shipped.

**Suite.** `tests/gh-ledger-report.bh-4477-test.sh`.
