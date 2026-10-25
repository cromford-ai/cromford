# `bin/lib/br/opt/` — the optional modules of `bin/blocked-resolver.sh`

This directory is the seam. `bin/blocked-resolver.sh` sources every file named
here — and only these — immediately after its REQUIRED `bin/lib/br/` loop, then
calls the hooks below at fixed places in the tick. With no module present the
lane does exactly what it did before the seam existed, every counter the seam
adds reads 0, and nothing here can change a decision.

Shipped by BH-1468. The modules themselves are:

| file | ships with | what it does |
|---|---|---|
| `mechanical.sh` | #1470 | carry an unchanged verdict onto a moved head; rebase a derived-only conflict |
| `family.sh` | #1471 | carry one iron-law ruling across a family of PRs that share a cause |
| `cirepair.sh` | Lane D | cap CI repair rounds per PR head lineage (`BR_CI_REPAIR_ROUNDS`, default 2), then park with a decision request |
| `stale.sh` | #3935 | re-plan a PR the age ladder parked `stale-replan` (no head or verdict change for `pr_stale.replan_days`) on the CI park's path and shared `BR_CI_REPLAN_MAX`, then close it as superseded once the re-plan's PR exists |
| `external.sh` | BH-4664.0 | the external-PR candidate source and its shared gates (knob, push right, author quiet); pushes nothing |
| `extfix.sh` | BH-4664 (sibling, not yet shipped) | defines `br_xpr_fix` |
| `extpark.sh` | BH-4669 (BH-4664.2) | defines `br_xpr_nopush` and `br_xpr_terminal`: tells the author once per head (`pr_attempts` row first), never closes |
| `extrebase.sh` | BH-4664 (sibling, not yet shipped) | defines `br_xpr_rebase` |
| `parentprio.sh` | BH-5741 | ranks a BLOCKed parent PR with approved stacked children above ordinary rows (below main-red), and writes ONE ALERTS line when no fix round starts for it in `BR_PARENT_WAIT_ALERT_MIN` (default 120) |
| `profile.sh` | BH-5946 | one `prof:` line after the `tick:` line (stage seconds, GitHub calls by endpoint shape, D1 and model calls, memo hits, unchanged skips, the 5 slowest rows) and a per-row TSV in `state/blocked-resolver/profile/` |
| `readmemo.sh` | BH-5946 | a per-run memo of `gh_rest` GETs of a PR, an issue, its comment pages and the merged-PR search; a rung reads live |
| `unchanged.sh` | BH-5946 | skips a row that ended on a quiet exit while its local fingerprint is unchanged, for up to `BR_UNCHANGED_RECHECK_S` (default 1800) |
| `untouched.sh` | BH-5913 | writes ONE ALERTS line per project when its oldest untouched park passes `BR_UNTOUCHED_ALERT_MIN` (default 120) |

`BR_OPT_MODULES` in the lane is the whole list. Adding a name there is the only
way a file in this directory is ever sourced; a file nobody named is ignored.

## The hooks

Every hook is OPTIONAL. Each call site is `command -v <hook>` guarded, so an
undefined hook is not an error and not a log line — it is the lane's own path.

| hook | argv | called | rc 0 means | rc 0 costs |
|---|---|---|---|---|
| `br_opt_carry_rung` | `<p> <rkey> <reason> <url> <rec> <tkey>` | in `br_one`, after the already-merged guard, before the ladder resolves a rung | this module HANDLED the row | `br_one` returns 0: the row spends its `PER_TICK` slot and its project's share, dispatches nothing, and is not an llm rung |
| `br_opt_conflict_rung` | `<p> <rkey> <reason> <url> <rec> <tkey>` | immediately after `br_opt_carry_rung` DECLINED | same | same |
| `br_opt_family_pre` | `<p> <rkey> <reason> <rec> <url>` | at the top of `br_adjudicate`, after the adjudicated-once guard and BEFORE the observe check | a stored ruling was carried onto this PR | `br_adjudicate` returns 0 and makes NO model call, posts no ruling, spends no adjudication counter |
| `br_opt_family_record` | `<p> <rkey> <reason> <rec> <url> <verdict>` | at the END of the `ACCEPT` and `REJECT` arms, after the lane acted on the ruling | nothing — best effort, rc ignored | nothing |
| `br_opt_ci_cap_rung` | `<p> <rkey> <reason> <url> <rec> <tkey>` | immediately after `br_opt_conflict_rung` DECLINED | the CI-red park was PARKED this tick (comment + CI_PARKED outcome) | same as the carry hook. **rc 3** is its own answer: already parked, a terminal — `br_one` returns 3, no rung, no `PER_TICK` slot |
| `br_opt_stale_rung` | `<p> <rkey> <reason> <url> <rec> <tkey>` | immediately after `br_opt_ci_cap_rung` DECLINED; rc 1 for anything but a `stale-replan` park | the stale park was re-planned (note + one enqueue), or superseded by the re-plan's PR, this tick | same as the carry hook. **rc 3**: waiting for the re-plan's PR, nothing to re-plan (cap spent, no key), or a close to retry — no rung, no slot. **A stale park never reaches the ladder**: when this hook is not loaded (`BR_OPT_OFF=stale`, a module that failed to source) `br_one` logs `left where it is` and returns 3, because the ladder's fix round is a model call |

| `br_opt_external_candidates` | none | last, inside `br_candidates` | nothing — it prints `xreviews` rows (reason `external-changes-requested` or `external-dirty`, ticket key `-`) | nothing |
| `br_opt_external_rung` | `<p> <rkey> <reason> <url> <rec> <tkey>` | in `br_one` for every `external-*` row, after the fix-round in-flight gate; the ladder never sees the row | the hook's own rc | **rc 3** on a gate refusal or when no hook is installed: no rung, no `PER_TICK` slot |
| `br_xpr_fix` / `br_xpr_rebase` | the same six | by `br_opt_external_rung` after its gates passed, with `BR_XPR_HEAD BR_XPR_REF BR_XPR_SLUG BR_XPR_NUM BR_XPR_AUTHOR BR_XPR_ROUNDS` exported | the sibling's | the sibling's |
| `br_xpr_nopush` | `<p> <url>` | by the gate when the head repo gives no push right | nothing — rc ignored; the gate returns 3 | nothing |
| `br_opt_parent_children` | `<p> <rkey> <reason> <url> <tkey>` | in `br_rank_rows`, for each plain (rank 4) row, with stdin closed | nothing — it prints `<n>\t<#a #b …>`; `n > 0` ranks the row 3 and logs one `PRIORITY parent` line. It appends the parent to `$BR_PARENT_TICK` | nothing |
| `br_opt_parent_wait` | `<tick-file>` | once per tick, after the dispatch loop and the STARVED walk, not observe-gated | nothing — it keeps `$ST/.parent-wait.tsv` and sends `lane-alert.sh --id parent-blocked-children-<p>-<ck>` | nothing |
| `br_opt_unchanged_skip` | `<p> <rkey> <reason> <url> <rec> <tkey> <src>` | at the top of `br_one`, before the repo token and every read | the row is unchanged since a quiet look younger than `BR_UNCHANGED_RECHECK_S` | `br_one` returns 3: no rung, no `PER_TICK` slot, no GitHub, D1 or model call. Counts `unchanged` |
| `br_opt_unchanged_mark` | `<class>` + `BR_ROW` (`<p> <rkey> <reason> <url> <rec> <tkey> <src> <ck>`) | by the lane's `br_quiet <class>`, right before a quiet `return 3` (`held`, `escalated`, `stalled`, `job-abandoned`, `hv-stands`, `rung-hold`, `needs-human`, `ci-parked`) | nothing — rc ignored; it writes `$ST/<p>/.looks/<rkey>` | one local fingerprint (no call) |
| `br_opt_unchanged_forget` / `br_opt_readmemo_drop` | `<p> <rkey>` / `<url>` | in `br_one` at the dispatch line (the drop also in `br_close_pr` after a close); `BR_READMEMO_LIVE=0` is set there too | nothing — rc ignored | nothing |
| `br_opt_readmemo_pr_ref` | `<slug> <num>` | first, inside `br_pr_ref` | `<head sha> <head ref>` from the memo or one REST read | on any other rc `br_pr_ref` runs its raw two-try read, as before |
| `br_opt_prof_stage` / `br_opt_prof_row_begin` / `br_opt_prof_row_end` / `br_opt_prof_tick_end` | `<discovery\|prepass\|order\|loop>` / none / `<p> <rkey> <src> <reason> <rc>` / none | in the lane's shell: at each stage start, around each row's subshell, right after the `tick:` line | nothing — rc ignored | one TSV line per row, one `prof:` line per run |
| `br_untouched_note` | `<p> <epoch>` | by `br_note_untouched`, for every row the tick did not dispatch (held rows pass `-`) | nothing — rc ignored | nothing |
| `br_untouched_alert` | `<now-epoch>` | once per tick, after the dispatch loop, not observe-gated | nothing — it keeps `$ST/.untouched-<p>` and sends `lane-alert.sh --id br-untouched-<p>` | nothing |
| `br_xpr_terminal` | the terminal's own args | in place of `br_fix_terminal`, `br_abandon` or `br_rebuild_fresh` when `br_is_external` is true | the terminal's rc, except that `br_abandon` answers 3 for a hook's 0 (its callers read 0 as "closed and ABANDONED recorded") | without it the terminal logs `external PR — never closed or rebuilt; left for the author`, sets `BR_XPR_PARKED` and returns 3: `br_one` answers 3, no rung, no `PER_TICK` slot. `extpark.sh`'s hook answers rc 0 below the review fix cap (the PR "waits for the next head"), and at the cap it parks (`BR_XPR_PARKED`, rc 3) |

Any rc but 0 from the first three is today's path, byte for byte. A run that
produced NO verdict (a dead session) reaches neither arm, so
`br_opt_family_record` is not called and nothing is stored — absent is not a
ruling.

**`br_opt_family_pre` is asked before the observe check on purpose.** A module
that would carry a ruling logs `WOULD carry family` and writes no marker when
`$OBSERVE` is 1; the site is pure dispatch and does not read `$OBSERVE` itself.
Returning on observe first would hide every carry from the module and make
observe mode a worse predictor of a real tick than no observe mode at all.

**ACCEPT ordering.** The per-PR `ironlaw-head-accept` row (or, when the jobs DB
did not take it, the record's `.ila_pending`) is written FIRST, by the lane's
own `ACCEPT` arm; the family row is second. So `br_opt_family_record` may key
its store on an ACCEPT that is already recorded — `br_opt_family_pre` may not,
because on the PR it is carrying a ruling ONTO there is no ACCEPT row yet. That
is what the module is there to write.

## Counting

**A bare `BR_N_X=$((BR_N_X + 1))` inside a hook is lost.** Every row is
dispatched inside a subshell (the per-key `flock`), so an assignment at the site
that did the work dies with that subshell and the tick line reads 0 for ever.

Call `br_count <token>` instead. It appends one line to this tick's scratch
ledger, which the tick line reads at the end:

| token | tick-line field | written by |
|---|---|---|
| `carried` | `carried=` | `mechanical.sh` when it carried a verdict |
| `mechanical` | `mechanical=` | `mechanical.sh` when it resolved a conflict |
| `family` | `families=` | `family.sh` when it carried a stored ruling |
| `llm` | `llm_rungs=` | the LANE, at each of its three model calls |
| `gh <METHOD> <shape>`, `gh RAW <shape>`, `d1 <segment>`, `memo-hit`, `unchanged` | the `prof:` line only | `profile.sh`, `readmemo.sh`, `unchanged.sh` |

Count at the site that did the thing, and count on REACHING the spend rather
than on liking the answer — an adjudication that came back empty was billed
exactly like one that ruled.

## The rules a module must keep

- **Define functions, do NOTHING on source.** The file is sourced once per tick,
  before any candidate has been read, on every tick of every hub. A source-time
  REST read, clock read or state write is a cost the lane cannot see and cannot
  bound.
- **Fail open.** The loader skips a file that does not parse (`bash -n`) and
  logs one line; it logs one line when a source returns non-zero and carries on.
  Neither writes to `logs/ALERTS.log` and neither fails the tick — unlike the
  REQUIRED loop, which pages and exits 1, because a half-synced CLASSIFIER would
  drain parks wrongly while a missing optional module simply does nothing. Note
  that bash keeps the functions a failed source had already defined, so a module
  must not rely on a non-zero source to disable itself.
- **Own your own timeouts.** A hook runs in the lane's tick, inside
  `BR_TICK_MAX_SECS`, which can only stop the tick BETWEEN rows. A hook that
  blocks blocks the whole tick.
- **Own your own conductor transition and hand-off.** A hook that answers rc 0
  returns from `br_one` before `TICK_DONE` is stamped, before the rebuild-cap
  gate and before `mc_handoff_release`, so nothing downstream will tidy up after
  it.
- **The lane-wide scan lock is still held.** The hook sites in `br_one` run
  before `br_cron_unlock`. That function is idempotent (`flock -u` then
  `exec 8>&-`), so a module about to do long git work may call it itself first
  and the lane's own later call is a no-op.
- **Observe mode is yours.** Read `$OBSERVE` in the module and log `WOULD …`.

## Knobs

- `BR_OPT_OFF` — comma list, no spaces, of module names this lane will not
  source (`mechanical`, `family`, `cirepair`, `external`, `extfix`, `extpark`,
  `extrebase`, `parentprio`, `profile`, `readmemo`, `unchanged`). One kill switch for every optional rung;
  nobody adds a per-behaviour flag. Empty is every module that exists. A name
  nothing ships is ignored silently.
- `BR_FAMILY_TTL_SECS` — how long a stored family ruling may be carried to
  another PR of the same family. `0` = never expires. Resolved by the LANE (a
  typo falls back to 0 once, there) and read by `family.sh` out of the
  environment it is sourced into.

Both are declared in `catalog/lanes.d/blocked-resolver.json`, so the console can
explain them. The BH-5946 modules read `BR_PROFILE`, `BR_PROFILE_KEEP`,
`BR_READMEMO`, `BR_READMEMO_MAX_AGE_S`, `BR_UNCHANGED_RECHECK_S` and
`BR_UNCHANGED_CLASSES` from the `lib.br-repeat-cuts.*` settings rows
(`catalog/lanes.d/_lib.br-repeat-cuts.json`), through `lib_env_apply` when
they are sourced.

## Getting a module onto a box

Nothing to do. `bin/harness-sync.sh` rsyncs `bin/` recursively, so a file
committed here reaches every box on the next sync, and `bin/blocked-resolver.sh`
picks it up on the next tick.

## Tests

`tests/blocked-resolver-opt-hooks.bh-1468-test.sh` drives the real lane against
a scratch `$HARNESS` with a canary module at each hook.
