# Iron-law checks apply their own false-positive lists (BH-9436)

Doc: CHECKS

Three mined checks under `checks/` parked PRs on lines their own WHY.md
already called false positives. On the merge base, the 4 sampled lines
(cromford#9372, project-6#3074, project-4#2205, project-3#649) gave 6
`CHECK-HIT` lines, and `bin/merge-sweep.sh` parked each PR as an iron-law hit.

## What changed

- Each of `client-id-trust`, `sql-command-injection` and `secret-literals`
  reads one list file, `checks/<slug>/exclusions.tsv`. A row has 4 TAB fields:
  `kind action pattern why`. Kinds: `path` (an awk ERE on the file path),
  `tag` (sql only: a template tag that binds its parameters), `rule`
  (secret-literals only: `name-only`). Actions: `note` or `skip`.
- A missing list, or an invalid row, is no exclusion. The check runs in its
  strict form, so a broken install gives more hits, never fewer.
- A check prints `NOTE<TAB>path:line<TAB>reason` for a line a `note` row
  excludes. `bin/checks-run.sh` (diff mode) prints it as
  `CHECK-NOTE <slug> <loc> <reason>` after every `CHECK-HIT`, appends
  ` — <k> note(s): <slug>(xN)` to the summary, and does not count it. rc 0 when
  only notes exist.
- `bin/lib/rb/execute.sh` (the MINED CHECKS block, rc 0 arm) shows up to 20
  `CHECK-NOTE` lines to the reviewer.
- The rows: client-id-trust notes `cron/`, `webhooks/`, test fake or fixture
  paths and `admin/` routes. sql-command-injection skips `.md`, `e2e/` and seed
  helpers, and accepts the `sql`, `Prisma.sql`, `$queryRaw` and `$executeRaw`
  tags with an optional `<...>` generic. secret-literals notes a log line that
  prints a secret NAME and no value.
- The built-in `$queryRaw`/`$executeRaw` exclusion in
  `checks/sql-command-injection/check.sh` now also takes the `<...>` generic.

## What did not change

`bin/merge-sweep.sh`, `mc_iron_law_scan` and `bin/lib/ironlaw-carry.sh` count
only `^CHECK-HIT ` and rc, so a note never parks a PR. Tree mode is unchanged.
`scanner_fp` in `bin/lib/mc/locks.sh` digests `check.sh` but not
`exclusions.tsv`: a list-only edit does not move the scan memo key, and the
memo TTL bounds that stale window.

Pinned by `tests/checks-false-positives.bh-9436-test.sh`.
