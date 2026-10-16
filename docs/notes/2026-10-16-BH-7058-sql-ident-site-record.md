# BH-6523 site record: the 66 marked SQL sites, the 2 real findings, the fractional-limit reads

Doc: none

PR #7048 (BH-6523, merged 2026-10-16 05:15Z as `cfc848205`) did the code work. Its body has no per-site table and no `## Other observations` section. A merged PR body is not edited, so this note is that record (BH-7058).

All line numbers belong to main `2d0db3fc9`. They drift after later merges. To regenerate the site list, run `bin/sql-ident-lint.sh --print`.

## Site table

Scope: every `bin/sql-ident-lint.sh --print` site in the files of #6523's Owns list that have sites, plus `lib/harness-flags.js`. That is 24 files and 66 sites, all `marked`:

- 22 Owns files that #7048 edited (64 sites).
- `lib/harness-flags.js` (4 sites). #7048 edited it under the lib/ rule.
- `routes/suite-results.js` (1 site, `:149`). It is in Owns, but #7048 did not edit it. BH-6525 (`47a6196d`) marked it before #7048 merged.

The 23 files #7048 edited hold 65 sites. The `suite-results.js` row is the 66th.

`source` is the text of the site's `// sql-ident-ok:` marker. `verdict` is `fixed` where #7048 added a `sqlIdent()` check or a clamp that the site depends on. Otherwise it is `safe`: the marker names a source that the caller cannot control.

| file:line | interpolated | source | verdict |
|---|---|---|---|
| worker/jobs/src/lib/core.js:703 | `sql` | scopePeers returns literal SQL text; the scope values are ? binds | safe |
| worker/jobs/src/lib/core.js:952 | `table`, `columns.join(",")`, `placeholders` | table and columns passed sqlIdent above; placeholders are ?N text | fixed |
| worker/jobs/src/lib/core.js:980 | `table`, `where.join(" AND ")`, `lim + 1` | table passed sqlIdent; where is two literals; lim is a clamped number | fixed |
| worker/jobs/src/lib/core.js:1156 | `table` | table passed sqlIdent at the top of ensureColumns | fixed |
| worker/jobs/src/lib/core.js:1162 | `table`, `sqlIdent(col)`, `type` | table and col pass sqlIdent; type is a literal type phrase from ADDED_COLUMNS | fixed |
| worker/jobs/src/lib/daily-digest/state-sections.js:107 | `col`, `where` | col passes sqlIdent; where is a literal predicate from the three calls below | safe |
| worker/jobs/src/lib/daily-digest/state-sections.js:128 | `PR_STATE_NO_GATE` | PR_STATE_NO_GATE is a module constant subquery | safe |
| worker/jobs/src/lib/daily-digest/state-sections.js:150 | `PR_STATE_NO_GATE` | PR_STATE_NO_GATE is a module constant subquery | safe |
| worker/jobs/src/lib/harness-flags.js:128 | `portedSql("name")`, `limit + 1` | portedSql builds literal text from the PORTED_ALTS code list; limit is a code constant from each caller | safe |
| worker/jobs/src/lib/harness-flags.js:135 | `portedSql("p.name")`, `limit + 1` | portedSql builds literal text from the PORTED_ALTS code list; limit is a code constant from each caller | safe |
| worker/jobs/src/lib/harness-flags.js:161 | `marks(ported, 1)` | marks() is ?N placeholder text | safe |
| worker/jobs/src/lib/harness-flags.js:175 | `marks(names, 1)`, `twin` | marks() is ?N placeholder text; twin is a literal clause with marks() | safe |
| worker/jobs/src/lib/lane-dedup.js:92 | `window` | window is a literal predicate | safe |
| worker/jobs/src/lib/lane-dedup.js:104 | `window`, `FP_CAP + 1` | window is a literal predicate; FP_CAP is a code constant | safe |
| worker/jobs/src/lib/merge-queue-intake-medians.js:25 | `MEDIAN_WINDOW_DEFAULT` | MEDIAN_WINDOW_DEFAULT is a code constant | safe |
| worker/jobs/src/lib/merge-queue-intake-stages.js:72 | `ph` | ph is ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-intake-stages.js:84 | `ph`, `CANDIDATES` | ph is ?N placeholder text; CANDIDATES is a code constant | safe |
| worker/jobs/src/lib/merge-queue-intake.js:115 | `ph` | ph is ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-live-progress.js:25 | `ph`, `drafts.length + 2` | ph and the LIMIT are ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-live-progress.js:30 | `ph` | ph is ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-live-stages.js:31 | `ph` | ph is ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-live-stages.js:41 | `ph`, `fph`, `drafts.length + FAILED_CONCLUSIONS.length + 1` | ph, fph and the LIMIT are ?N placeholder text | safe |
| worker/jobs/src/lib/merge-queue-live-stages.js:71 | `where`, `binds.length` | where holds literal predicates with ?N binds; the LIMIT is ?N text | safe |
| worker/jobs/src/lib/pr-gate.js:38 | `cols.join(", ")`, `` cols.map((_, i) => `?${i + 1}`).join(",") `` | cols are literals plus names from the GATE_FIELDS constant; values are ?N text | safe |
| worker/jobs/src/lib/pr-gate.js:55 | `[...GATE_FIELDS, "url"].map(latest).join(", ")` | latest() reads names from the GATE_FIELDS constant | safe |
| worker/jobs/src/routes/alert-actions.js:50 | `AUDIT_COLS` | AUDIT_COLS is a module constant | safe |
| worker/jobs/src/routes/alert-actions.js:77 | `AUDIT_COLS`, `n + 1`, `n + 2`, `n + 3`, `n + 4`, `afterSql`, `n + 5`, `n + 6`, `cas` | AUDIT_COLS is a constant; cas and afterSql are literals from the pair() calls below | safe |
| worker/jobs/src/routes/alert-actions.js:83 | `set`, `cas` | set and cas are literals from the pair() calls below | safe |
| worker/jobs/src/routes/alert-family-scripts.js:78 | `COLS` | COLS is a module constant | safe |
| worker/jobs/src/routes/alert-family-scripts.js:92 | `COLS` | COLS is a module constant | safe |
| worker/jobs/src/routes/alert-family-scripts.js:99 | `COLS` | COLS is a module constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:175 | `table`, `f.where`, `order`, `f.binds.length + 1` | table and order are literals from the two listRows calls; f.where joins literal filter names with ?N binds | safe |
| worker/jobs/src/routes/dequeue-watch.js:216 | `EVENT_WHERE` | EVENT_WHERE is a module constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:252 | `set`, `fields.length + 5`, `EVENT_WHERE` | set takes names from the EVENT_STATE constant with ?N binds; EVENT_WHERE is a constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:256 | `EVENT_WHERE` | EVENT_WHERE is a module constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:286 | `ACTION_WHERE` | ACTION_WHERE is a module constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:311 | `set`, `fields.length + 5`, `ACTION_WHERE` | set takes names from the ACTION_SET constant with ?N binds; ACTION_WHERE is a constant | safe |
| worker/jobs/src/routes/dequeue-watch.js:315 | `ACTION_WHERE` | ACTION_WHERE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:87 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:108 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:114 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:133 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:158 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:166 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:183 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:188 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/hub-probe.js:204 | `TABLE` | TABLE is a module constant | safe |
| worker/jobs/src/routes/job-detail.js:119 | `JOBS_SELECT` | JOBS_SELECT is a constant from lib/core.js | safe |
| worker/jobs/src/routes/job-detail.js:148 | `TRANSCRIPT_INDEX_COLS` | TRANSCRIPT_INDEX_COLS is a constant from lib/core.js | safe |
| worker/jobs/src/routes/jobs.js:293 | `sets.join(", ")`, `binds.length` | sets are literal col=? strings from the set() calls in this handler | safe |
| worker/jobs/src/routes/lead-reviews.js:94 | `JOBS_SELECT` | JOBS_SELECT is a constant from lib/core.js | safe |
| worker/jobs/src/routes/ledger.js:62 | `where.join(" AND ")`, `lim` | where holds literal predicates with ?N binds; lim is a clamped integer | fixed |
| worker/jobs/src/routes/ledger.js:128 | `notTerminal` | notTerminal is a literal with ?N placeholder text from term; every value is a ?N bind | safe |
| worker/jobs/src/routes/participants.js:151 | `set`, `from` | stamp and from are literals from the three decision() calls at the end of this file | safe |
| worker/jobs/src/routes/participants.js:259 | `DETAIL_MAX + 1` | DETAIL_MAX is a code constant | safe |
| worker/jobs/src/routes/phases.js:180 | `sets.join(", ")`, `binds.length` | sets are literal col=? strings from the set() calls in this handler | safe |
| worker/jobs/src/routes/pool-state.js:36 | `sql`, `limit + 1` | sql is a literal from each bounded() call; limit is a LIMITS constant | safe |
| worker/jobs/src/routes/pool-state.js:147 | `tail` | tail is one of two literal ON CONFLICT clauses | safe |
| worker/jobs/src/routes/pool-state.js:218 | `tail` | tail is one of two literal ON CONFLICT clauses | safe |
| worker/jobs/src/routes/pr-state.js:190 | `where.join(" AND ")`, `binds.length` | where holds literal predicates with ?N binds; the LIMIT is ?N text | safe |
| worker/jobs/src/routes/pr-state.js:224 | `where.join(" AND ")`, `binds.length` | where holds literal predicates with ?N binds; the LIMIT is ?N text | safe |
| worker/jobs/src/routes/pr-state.js:323 | `clause` | clause holds literal predicates with ?N binds | safe |
| worker/jobs/src/routes/pr-state.js:326 | `clause` | clause holds literal predicates with ?N binds | safe |
| worker/jobs/src/routes/suite-results.js:149 | `PRUNE_CAP` | PRUNE_CAP is a module number const | safe |
| worker/jobs/src/routes/triage-state.js:77 | `cols.join(", ")`, `` cols.map((_, i) => `?${i + 4}`).join(", ") `` | cols are keys of the FIELDS constant; values are ?N text | safe |
| worker/jobs/src/routes/triage-state.js:115 | `where`, `limit + 1` | where is one of two literals; limit passes a digits regex and a range check | safe |

`fixed` rows:

- `core.js:952` (appendLines): `sqlIdent(table)` and `columns.forEach((c) => sqlIdent(c))` now run before the first prepare.
- `core.js:980` (listLines): `sqlIdent(table)` now runs first. Its `lim` still lets a fraction through. See Other observations.
- `core.js:1156`, `core.js:1162` (ensureColumns): `sqlIdent(table)` now runs before the cache and the PRAGMA. `sqlIdent(col)` runs before each ALTER.
- `ledger.js:62`: `lim` is now an integer in [1, 1000].

`jobs.js` has no row for its limit. The `LIMIT ${limit}` text is built into a `const sql` and then sent through `prepare(sql)`. The lint does not count a `prepare(<variable>)` site, and the NEGATIVE rule of #6523 keeps it so.

## Real findings

#7048 found two real defects. No site was RISK.

1. `GET /api/jobs?limit=-1` built `LIMIT -1`, which is no limit in SQLite/D1. `limit=-Infinity` built `LIMIT -Infinity`, which is a 500. Fix: `routes/jobs.js:30` clamps to an integer in [1, 500], default 100.
2. `GET /api/ledger?kind=k&limit=-1` read every row of the kind. Fix: `routes/ledger.js:42` clamps the list path to an integer in [1, 1000], default 200. The BH-6863 `key=` archive path did not change.

Proof: `worker/jobs/test/limit-clamp.bh-6514.test.js` K1 (`/api/jobs?limit=-1` with 3 jobs returns 1) and K3 (`/api/ledger?kind=k&limit=-1` returns 1) run `worker.fetch` over node:sqlite. `worker/jobs/test/sql-ident-core.bh-6514.test.js` J3-J5 prove the ensureColumns, appendLines and listLines refusals. All of them fail on `0128edc4` (before #7048).

## Other observations

The 25 reads below clamp a query value with `Math.min(Math.max(...))` and no `Math.floor` or `Math.trunc`. Source: `git grep -n "Math.min(Math.max(Number\|Math.min(Math.max(1, Number" -- worker/jobs/src | grep -v floor | grep -v trunc` on `2d0db3fc9`. So `?limit=2.7` gives `2.7`, not `2`.

A local probe (node:sqlite, this build) shows `LIMIT 2.7` fails with `datatype mismatch`. It fails in the SQL text and also as a `?1` bind. D1 was not tested. The probable effect is a 500 on a fractional `limit`, not a wider read. This is not #6523's class (identifiers in SQL text). It is a follow-up. If triage wants the fix, it files ONE grouped ticket for all of these reads (BH-6902), not one per file.

Value in the SQL text (`LIMIT ${...}`), 17 reads:

- `worker/jobs/src/lib/core.js:976` (listLines, `LIMIT ${lim + 1}` at :980)
- `worker/jobs/src/routes/artifacts.js:44`
- `worker/jobs/src/routes/cli-versions.js:79`
- `worker/jobs/src/routes/closeout-aged.js:55`
- `worker/jobs/src/routes/cost.js:156` (`days` used as the LIMIT)
- `worker/jobs/src/routes/cost.js:220`
- `worker/jobs/src/routes/cost.js:276`
- `worker/jobs/src/routes/cost.js:472`
- `worker/jobs/src/routes/flakes.js:61`
- `worker/jobs/src/routes/merge-queue.js:86`
- `worker/jobs/src/routes/merge-trains.js:97`
- `worker/jobs/src/routes/outcomes.js:52`
- `worker/jobs/src/routes/queue.js:198`
- `worker/jobs/src/routes/queue.js:487`
- `worker/jobs/src/routes/usage.js:61`
- `worker/jobs/src/routes/usage.js:141`
- `worker/jobs/src/routes/wakes.js:298`

Value bound as `?N` or used only in JS, 7 reads:

- `worker/jobs/src/lib/config-changes.js:79` (bound `n + 1`, then `slice(0, n)`)
- `worker/jobs/src/routes/burn.js:24` (`days` sets a `since` date)
- `worker/jobs/src/routes/cost-caps.js:80` (bound `limit + 1`)
- `worker/jobs/src/routes/cost.js:310` (passed to `computeAnchored` as `limit`)
- `worker/jobs/src/routes/dora.js:51` (`days` sets a `since` date)
- `worker/jobs/src/routes/model-routes.js:624` (bound `limit + 1`)
- `worker/jobs/src/routes/routing.js:28` (bound `limit + 1`)

Not a defect, 1 read:

- `worker/jobs/src/routes/suite-reuse-saved.js:55`: `daysParam` refuses a value that fails `/^-?\d{1,6}$/` first, so a fraction never reaches the clamp.

## Not edited

- `routes/cost-breakdown.js`: 0 sites since `536babf1e` (BH-6779 made its SQL literal-only). #7048 deleted only its stale baseline fragment.
- `routes/suite-results.js`: #7048 did not edit it. Its 1 site (`:149`, `PRUNE_CAP`) has a marker from BH-6525 (`47a6196d`). The #6523 plan and the #7048 commit say "0 sites". That is wrong. The file had 0 UNMARKED sites when #6523 was planned.
- `lib/harness-flags.js` is in no child's Owns. #7048 took it under the "every file under worker/jobs/src/lib/" rule, as comment 6200549226 on #6523 asked, and its PR body says so.
