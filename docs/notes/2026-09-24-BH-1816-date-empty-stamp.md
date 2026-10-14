# date-empty-stamp is an error, and only a real test on the variable guards it

Doc: TEST-DETERMINISM

## What changed (BH-1901, the last slice of BH-1816)

- **`rule date-empty-stamp` is `error`** in `catalog/determinism-lint.conf`. It
  was `warn` while sibling slices (#1897-#1900) guarded or waived the bin/ sites.
  An unguarded `date -d "$VAR"` in a `bin/**.sh` script now fails
  `bin/test-determinism-lint.sh`, so it fails the CI lint step and the pre-PR
  gate.
- **Guard detection is tighter** in `bin/test-determinism-lint.sh`. Before this, any
  `-n`/`-z` followed by the variable counted, so `head -n "$x"`, `grep -n "$x"`,
  `[ ! -n "$x" ]` and `[ -z "$x" ] && e=$(date -d "$x" ...)` all silenced the rule.
- The `warn_show` comment in the conf sits on `opt warn_show` again. It had ended
  up above `date_guard_lookback`.

## The rule and why

GNU `date -u -d ""` exits 0 and prints today's 00:00:00Z. So
`e=$(date -u -d "$x" +%s) || e=0` never takes the fallback when `$x` is empty. The
lane goes on with a real-looking epoch nobody wrote (#1815). The rule matches a
`date` whose `-d` argument is a bare `"$VAR"` or `"${VAR:-...}"`, and judges every
such `date` on the line on its own.

## Scope

`bin/**.sh` only (`scope date-empty-stamp` in the conf), and test files are
skipped even there. A suite plants empty or odd stamps on purpose. A lane stamps
from whatever it read, which is where the empty value comes from.

## `date_guard_lookback`

`opt date_guard_lookback 6`: the guard may sit on the call line or on any of the 6
non-comment lines above it. A guard further up does not count.

## What counts as a guard (after BH-1901)

A test on the same variable, on a non-comment line in that window:

- `[ -n "$VAR" ]`, `[[ -n $VAR ]]`, `test -n "$VAR"`. The `-n` must come right
  after `[`, `[[` or `test`.
- `[ -z "$VAR" ]` (or `[[`, `test`) only when the same line then leaves the date
  call behind: `[ -z "$VAR" ] || ...`, or `&&` / `; then` straight into `return`,
  `exit`, `continue` or `break`.

No longer a guard: `head -n "$VAR"`, `grep -n "$VAR"`, `[ ! -n "$VAR" ]`,
`[ -z "$VAR" ] && e=$(date -d "$VAR" ...)`, and `if [ -z "$VAR" ]; then` with
the date call inside the branch.

Known limits, left to the waiver and to review:

- `if [ -z "$VAR" ]; then` with `return 1` on the NEXT line now reports. Write it
  on one line (`[ -z "$VAR" ] && return 1`) or waive it. No bin/ site had this
  shape at build time.
- `[ -z "$VAR" ] || [ ... ] && date ...` is accepted because `||` follows. The
  lint is a heuristic.
- A `-n` test inside a quoted string still counts, as it did before.

## Waiver

On the call line: `# determinism: ok date-empty-stamp <why the value is never
empty here>`. A waiver without a reason is itself a `waiver-no-reason` finding.

## Audit table

The parent plan (`builds/cromford-BH-1816-202609241155/plan.md`) is not on
the box that built this slice, so this table was rebuilt from the tree at the
build's merge base, 11b8d1e2, by grepping bin/ for the rule's regex and reading
the guard window of each hit. 40 call sites: 34 guarded, 6 waived.
`bin/lib/jobs/flags.sh` and `bin/account-pick.sh` are the two the parent named.

| Site | Status | Guard or waiver reason |
|---|---|---|
| `bin/account-pick.sh:230` | guarded | `[ -n "${1:-}" ] \|\| { printf '0\n'; return 0; }` (line 229) |
| `bin/agent-call.sh:2907` | guarded | `[ -n "$when" ] \|\| return 0` (line 2906) |
| `bin/alert-digest.sh:104` | guarded | `[ -n "$FS_ISO" ] &&` on the same line |
| `bin/alert-triage.sh:209` | guarded | `[ -n "$RFS" ] &&` on the same line |
| `bin/backup-records-sync.sh:164` | waived | the case above skips any REPORTED that does not start with YYYY-MM-DD |
| `bin/batch-resolve.sh:1603` | guarded | `if [ -n "$exp" ] &&` on the same line |
| `bin/blocked-resolver.sh:1855` | waived | the `''\|-)` arm above handles empty |
| `bin/blocked-resolver.sh:2347` | guarded | `[ -n "$at" ] \|\| continue` (line 2346) |
| `bin/blocked-resolver.sh:2399` | guarded | `if [ -n "$qat" ] &&` on the same line |
| `bin/blocked-resolver.sh:2628` | guarded | `[ -n "${upd:-}" ] \|\| continue` (line 2627) |
| `bin/blocked-resolver.sh:3805` | guarded | `[ -n "$at" ] \|\| continue` (line 3804) |
| `bin/board-invariants.sh:32` | guarded | `[ -n "${1:-}" ] &&` on the same line |
| `bin/clock-sync.sh:99` | guarded | `[ -n "$hdr" ] \|\| return 1` (line 98) |
| `bin/concurrency-ceiling-watch.sh:83` | guarded | `[ -n "${1:-}" ] \|\| return 1;` on the same line |
| `bin/extra-usage-track.sh:472` | guarded | `if [ -n "$LASTTS" ]; then` (line 467) |
| `bin/fleet-status-push.sh:129` | guarded | `if [ -n "$QOLD" ]; then` (line 128) |
| `bin/fleet-status-push.sh:461` | guarded | `if [ -n "$HUB_LEASE_UPDATED" ]; then` (line 460) |
| `bin/fly-pool.sh:866` | guarded | `if [ -n "$rearm_ts" ] && [ -n "$created" ]; then` (line 865) |
| `bin/fly-pool.sh:867` | guarded | same test as 866 (line 865) |
| `bin/fly-pool.sh:1428` | guarded | `[ -n "$expat" ] \|\| return 0` (line 1427) |
| `bin/fly-pool.sh:1435` | guarded | `if [ -n "$rotat" ]; then` (line 1434) |
| `bin/fly-pool.sh:1445` | guarded | `[ -n "$newexp" ] &&` on the same line |
| `bin/fly-pool.sh:1462` | waived | only reached when nexp>exp, which needs a non-empty newexp |
| `bin/fly-pool.sh:2785` | guarded | `if [ -n "$SUP" ]; then` (line 2784) |
| `bin/gh-token.sh:301` | guarded | `[ -n "$exp" ] \|\| return 1` (line 300) |
| `bin/lib/backup-freshness.sh:170` | waived | the case above only ever puts one of two non-empty shapes in iso |
| `bin/lib/gh-quota.sh:132` | guarded | `[ -n "$iso" ] &&` on the same line |
| `bin/lib/jobs/flags.sh:42` | waived | the case above admits only YYYY-MM-DDTHH:MM:SSZ |
| `bin/lib/lane-down.sh:25` | guarded | `[ -z "$oldest" ] \|\|` on the same line |
| `bin/lib/mc/classify.sh:361` | guarded | `[ -n "${upd:-}" ] &&` on the same line |
| `bin/lib/mc/settle.sh:45` | guarded | `[ -n "$at" ] && ... \|\| return 0` (line 40) |
| `bin/main-red-pr-pair.sh:306` | guarded | `[ -n "$updated" ] \|\| return 1` (line 305) |
| `bin/metrics-collect.sh:53` | guarded | `if [ -n "$START" ] && [ -n "$END" ]; then` (line 52), both vars |
| `bin/pipeline-health.sh:186` | guarded | `[ -n "$NEWEST_REF" ] &&` on the same line |
| `bin/pipeline-health.sh:482` | guarded | `[ -n "$NEWEST" ] &&` on the same line |
| `bin/postmerge-qa.sh:271` | guarded | `[ -n "${MERGED_AT:-}" ] &&` on the same line |
| `bin/quota-poll.sh:153` | guarded | `[ -n "$p" ] \|\| { echo 999999999; return 0; }` (line 152) |
| `bin/quota-status.sh:208` | guarded | `if [ -n "$polled" ]; then` (line 207) |
| `bin/remote-gate.sh:166` | guarded | `[ -n "${1:-}" ] \|\| return 1` (line 165) |
| `bin/vendor-spend-pull.sh:511` | waived | window_start_for always prints first_ts, $NOW or a non-empty prev/floor_ts |

## The parent plan's assumptions, carried forward

- The rule lives in the determinism lint (`bin/test-determinism-lint.sh` plus
  `catalog/determinism-lint.conf`), not in a new lint.
- Composite arguments are out of scope: `date -d "$at UTC"`,
  `date -d "$(...)"` and similar are not matched, because the rule regex only
  matches a bare `"$VAR"` or `"${VAR:-...}"`.

## Tests

`tests/test-determinism-lint.bh-1901-test.sh` pins the error severity, the real
repo at 0 findings, and each guard shape above that no longer counts.
`tests/test-determinism-lint.bh-1897-test.sh` F1 and R1 now expect error.
