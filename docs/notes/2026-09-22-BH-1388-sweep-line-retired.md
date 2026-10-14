# The hub's merge-sweep cron line is retired, and two readers stop depending on files only one box has

Doc: MERGE-CONDUCTOR

The hub ran two mergers. `bin/merge-conductor.sh` has been merging live since
2026-09-12, when the operator armed `merge-conductor-merge` fleet-wide, and
`bin/merge-sweep.sh` kept running beside it at `6,16,26,36,46,56 * * * *`.
BH-1388 (BH-1025.3) deletes the sweep's LANE — `cron/lanes/400-merge-sweep.cron`
and `catalog/lanes.d/merge-sweep.json` — so the conductor is the hub's only
merger. The script stays, and so do its suites: `bin/batch-resolve.sh` and an
operator still run it by hand. The box-side `tier2-merge-sweep` lane was a
different lane, which BH-1366 retired on main separately; this change does not
touch it.

## The Phase C probe (the BH-1000 rule), re-run before the PR

This PR does not GATE a lane, it REMOVES one, so the probe is the mirror image
of the rule's usual shape: the thing that has to already answer in production is
the lane that survives. Run from this build's box at 2026-09-22 13:16Z through
`bin/jobs-client.sh`:

```
--- probe re-run at 2026-09-22 13:53:10Z from pool-cromford-d8d0ed6a5210e8 (Fly pool box) ---
GET /api/flags/merge-conductor-merge  rc=0  {"name":"merge-conductor-merge","active":1,"actor":"operator-mac-session","reason":"the operator 2026-09-12: arm the merge conductor fleet-wide (merge-lane plan, project-5 pilot)","updated_at":"2026-09-12T21:44:40Z"}
GET /api/flags/conductor-owns-merges  rc=2
GET /api/flags/pr-state-rows          rc=2
GET /api/ledger?kind=merge&limit=500   rc=0  rows=500  merged in last 24h by detail:
    (no detail)	123
    merge-conductor	40
GET /api/ledger?kind=pr_merged&limit=500 rc=0  rows=4  in last 24h=0
```

Two things that reading does NOT say, stated plainly:

- **`conductor-owns-merges` could not be verified.** It has no DB row — it is a
  hub-local `touch`, and this build runs on a Fly pool machine
  (`bin/lib/hub-box.sh` keeps builds off the hub), so `rc=2` here means "invisible
  from here", not "off". It gates the BOX-side mergers (`bin/merge-queue.sh`,
  `bin/tier2-merge-sweep.sh`, `bin/review-prs.sh`, `run-build`'s tier-1 step),
  none of which this change touches, so its state does not change whether the
  HUB sweep line is redundant with the conductor.
- **The sweep still wrote most of the merged rows.** 123 rows with no detail
  (`sweep_record`, `bin/merge-sweep.sh`) against 40 with `detail=merge-conductor`
  (`mc_settle_merged`, `bin/lib/mc/settle.sh`) in the last 24 hours. After this
  lands the conductor takes all of it, and the first 24 hours are the real Phase C
  exit test. Rollback restores the two deleted files from the MAIN THAT THIS
  MERGED INTO (the merge commit's first parent), not from this branch's old
  copy: `git checkout <merge-sha>^1 -- cron/lanes/400-merge-sweep.cron
  catalog/lanes.d/merge-sweep.json`, then commit and PR. That copy of the
  registry entry carries BH-1575's required `SWEEP_PRS_FRESH_S` knob, which an
  older copy lacks. The next `bin/fleet-propagate.sh` tick (≤5 min,
  `bin/update-runners.sh` at 05:17Z as the backstop) puts the line back. The
  `lane-off-merge-sweep` flag row is left in place: a flag with no lane harms
  nothing, and a rollback re-reads it.
- **Do not land #1389 (conductor `*/5` → `*/30`) in the same window.** With the
  sweep gone the conductor is the only merger; slowing it before #1387's keyed
  ticks are live would cut hub merge throughput twice in one step.

`pr-state-rows` reads `rc=2` as it should: BH-1385's rows ship DARK, and
everything this change adds to `bin/blocked-resolver.sh` is behind that flag.

## What changed

**`bin/pipeline-health.sh`, the `# >>> sweep should have landed` block.** It
asked `state/merge-sweep-done.txt` and nothing else. That file is written by the
sweep, so from the moment the lane goes it stops growing and every PR the
conductor lands would look un-handled — an APPROVE'd, OPEN, CLEAN PR that
"the merge sweep has not landed", every ten minutes, for every merge. The block
now also asks `merge_ledger_has` (kinds `merge` OR `pr_merged`), which is what
the conductor writes:

- rc 0 — ledgered merged: handled, skip, and the record's terminal marker
  (`$D/pr-terminal`, `merged <epoch> <url>`, the format `bin/lib/pr-terminal.sh`
  writes) is persisted, so the next tick answers from the record and spends
  neither a ledger GET nor a PR read on it;
- rc 2 — a real miss, and `bin/reconcile-prs.sh`'s `closed` row IS one: today's
  classification, which pages;
- rc 1 — an outage: also today's classification. Never "merged" on a blink (D9).

The order is: the sweep-done file, then the record's terminal marker (BH-1585,
#1614), then the ledger, then the live REST read (`prt_read`). The two free
answers are asked first, which is the one place this build departs from the
ticket's own ordering. The decision is identical in every rc case, and the block
loops over every `builds/*` directory with a `PR_CREATED` RESULT on every tick:
ledger-first would spend hundreds of worker GETs per tick on PRs a file already
answers (D21). A `type merge_ledger_has` guard keeps a box with no jobs client
on exactly today's path.

What the ledger read buys is cost, not correctness: the block only pages on
OPEN + CLEAN, so a conductor-merged PR never paged; its live read said MERGED.
After BH-1585 the terminal marker already made that read a one-off. The ledger
answer now writes the same marker, so a conductor-merged PR costs one ledger GET
once instead of one PR read once.

**`bin/blocked-resolver.sh`, three new reads, all behind `pr_rows_on`.**

- `br_handoff_rows` beside `br_handoff_lines`, and read FIRST by
  `br_from_conductor`. The log grep runs only when the rows answered rc 1 (flag
  off, or an outage); rc 2 — the rows answered and hold nothing — does not fall
  back, because a real empty answer is an answer. It emits FIVE columns, not the
  log's three: the recovery loop's head guard reads `mc_handoff_file` and the
  pr-state.tsv row, and a rebuilt hub has neither, so a three-column source could
  never emit at all. The head and the park's `since` ride as columns 4 and 5 and
  are used only when the file and the row have none. Each of its two reads is
  one page of 1000 rows, and a page that comes back FULL is rc 1, not an
  answer: a PR whose latest state sits on an unread page would otherwise read
  as "no longer parked" and silence the log too. The log answers until the
  reader pages.
- `br_record` gained two optional trailing arguments (`pr-url`, `head`) and, when
  the bump is `rebuilds|fixrounds|adjudications`, writes a `pr_attempts` row
  AFTER the file — `mc_attempt_put`'s ordering, so "a row with no file line"
  cannot happen and "a file line with no row" heals on the next bump. The rc is
  ignored. The url is an argument because the record has never carried one.
- `br_rows_count` / `br_cap_rows` at the four cap reads (`br_rebuild_fresh`,
  `br_rebuild_retry`, `br_fix_round`, `br_adjudicate`). The cap is
  **max(file, rows)**, not rows-only-when-the-file-is-absent: "absent" is knowable
  only inside `br_load`, and `br_hold_gate` runs before every cap read and can
  `br_record` a `held` attempt, which CREATES the file with zero counters — so an
  absent-only rule would find a file and let a wiped hub evade the cap, which is
  the one outcome this ticket forbids. Rows ≤ file whenever the file is genuine,
  so the max equals the file everywhere the file is authoritative. An outage
  prints nothing and can never raise or lower a cap (D11). The rows are keyed
  per PR, so "the cap survives a wiped hub" holds for the PR being rebuilt, not
  across a rebuild chain: a rebuild opens a new PR whose rows start at 0. That
  follows from the ticket's design (rows per `(repo, number, kind, sha)`).
- `br_record`'s dark copy in `bin/lib/br/record.sh` (BH-1176) is kept
  byte-identical to the inline one, as `tests/br-split-layout-test.sh` requires.

`br_from_conductor`'s `$MC_ROWS` file source above the recovery loop is
unchanged.

**Hand runs of `bin/merge-sweep.sh`.** An operator, or
`bin/remediator-settings.json`, can still run the script; it still calls
`lane_env_apply merge-sweep`. With the registry entry gone the `SWEEP_*` knobs
fall back to the script's own defaults, and `SWEEP_PRS_FRESH_S` (BH-1575)
becomes off. That is safe: the sweep makes more live reads, and never a wrong
merge.

## What was NOT delivered, on purpose

The ticket asks whether `br_from_builds` can be dropped once the rows are read.
**It cannot, and it is not.** `br_from_builds` is the only source for parks that
never had a PR — `PLAN_MALFORMED`, `BUILD_DEAD`, `PR_CREATE_FAILED`,
`REVIEW_BLOCKED` — and `pr_state` has no row for a PR that was never opened.
Dropping it would make every one of those records invisible to the lane that
exists to find them.

## The flag is off, so nothing here runs yet

`pr-state-rows` has no row and no file. With it down, `br_handoff_rows` answers
rc 1 and the log grep runs, `br_record` writes only the file, and `br_rows_count`
prints nothing — byte-identical decisions to yesterday, pinned by the flag-off
twin of every case in
`tests/blocked-resolver-sources.bh-1388-test.sh`. The pipeline-health ledger read
is deliberately NOT behind that flag: it reads the `merge`/`pr_merged` ledger
routes, which are live today and which `bin/outcome-metrics.sh` already reads
ungated.

## Where the evidence is

`tests/merge-sweep-line-retired.bh-1388-test.sh` (the render, and the detector
block driven against the real `bin/jobs-client.sh`),
`tests/blocked-resolver-sources.bh-1388-test.sh` (the whole lane, end to end,
against a curl shim that records every request),
`tests/hub-cron-gated-test.sh` (the sweep is no longer in its `GATED` list),
and `docs/verification-map/merge-sweep-line-retired.md` for how to read it live.
