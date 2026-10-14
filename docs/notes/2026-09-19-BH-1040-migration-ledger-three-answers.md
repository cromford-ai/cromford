# 2026-09-19 — BH-1040: the migration ledger answers three ways, and "cannot ask" holds

Doc: DB-COORDINATION-SPEC, ALERT-REMEDIATION

## What was wrong

`bin/migration-autopilot.sh`'s `ledger_has` read `job_ledger_get` like a boolean:

```bash
job_ledger_get migration "$PROJECT $1" >/dev/null && return 0
return 1
```

The client has never been a boolean. `bin/jobs-client.sh` returns **0** with the
row's status, **2** when the worker is reachable and there is no such row, and
**1** when the API is unusable — including the case where `HARNESS_SECRET` is
unset. Its own contract comment says a MERGE/APPLY caller must not read rc 1 as
"not done". `ledger_has` read both non-zero rcs as "absent", so with
`state/migration-autopilot-done.txt` empty and harness-jobs down, a file the
autopilot had already ledgered as `failed-alerted`, `flagged`, `skipped` or
`applied` was carried through the classifier, the deploy gate and the apply POST
as if it had never been seen. A `failed-alerted` file would be re-POSTed and
re-alerted, which is the alert storm the ledger was built to stop; an `applied`
file was held back only by the app's own status ledger, and the harness-side
ledger is not supposed to depend on that.

The rc 0 branch also threw the row away instead of writing it to the file, so a
rebuilt hub re-asked the DB for every file on every tick.

## What changed

**`bin/migration-autopilot.sh`**

- `ledger_has` returns three answers: **0** present (file hit, or a DB hit which
  is back-filled into the file the way `merge-sweep.sh`'s `sweep_seen` does),
  **1** absent (file miss and the worker answered "no row", or no worker is
  configured on this box), **2** unknown (a worker IS configured and the read
  failed). The back-filled line is `<project> <file> <status>` with a non-empty
  status, so the function's own leading `grep "^$PROJECT $1 "` finds it next tick.
- `HOLD <file> <pr#> <merge-commit>` — the run stops. One `LOGLINE`, one alert
  through `bin/lane-alert.sh --id migration-autopilot-hold:<project>`, and
  `exit 0`. Nothing is ledgered, nothing is posted, no job row is opened. The
  next cron tick re-asks.
- **The alert's severity is proportional to what the hold actually stopped.**
  `critical` when prod is already serving the merge commit — the file really was
  about to be applied. `warn` when it is not: the deploy gate is a local
  `git merge-base` that needs no external ledger, so it would have held that file
  this tick regardless, and paging critical for it is a page for nothing. The
  hold itself still fires in both cases; only the channel changes.
- **`--id` is only honoured while the alert state machine is on**, so both lanes
  ask `alert_dedupes_by_id` first. `bin/lane-alert.sh:72-77` falls to a legacy
  path when `bin/lib/alert-state.sh` is missing, when `flags/alert-state-off`
  exists, or when `ALERT_STATE_ENABLED=0` — and that path ignores `--id` entirely
  and beats `orclane:<lane>:$(date -u +%Y%m%d%H%M)`, a fresh akey every tick.
  Passing `--id` into it would turn "one alert per condition" into a page every
  tick per project (12/hour across the three) for as long as the worker is down,
  which is the pb67 storm again. So the fallback below covers THREE cases, not
  one: no `lane-alert.sh`, state machine off, `ALERT_STATE_ENABLED=0`.
- fallback shape: the `FAIL` shape — a direct `ALERTS.log` line plus a `beat.sh`
  `fleet_alert` whose `akey` IS the condition id, which `beat.sh`'s own hook
  dedupes. That is why it is safe to route around `lane-alert.sh`.
- `ledger_db_reachable` calls `lane-alert.sh --resolve` on that same id once per
  run, on the first answer that actually came back from the worker (rc 0 or rc 2).
  `--resolve` on a closed or unknown id is silent by the script's own contract.
- The loop at the top of the per-file body is now
  `ledger_has "$FN"; case $? in 0) continue ;; 2) HOLD "$FN" "$NUM" "$MC" ;; esac`.
- `HARNESS` and `RDIR` are overridable (`${HARNESS:-/root/harness}`,
  `${MIGRATION_AUTOPILOT_REPO_DIR:-/root/repos/$PROJECT}`). Both defaults are the
  old literals, so every box runs unchanged; without them the fixture suite
  cannot drive the real script and would have had to test extracted functions.
- The header's `ledger` rail (was lines 24-26, now 24-30) says the new truth.

**`bin/check-migration-prs.sh`**

- Sources `bin/jobs-client.sh` when it is present, and dedupes on
  `ledgers(kind=migration)` instead of `state/migration-prs-alerted.txt`.
- **The silence is visible.** On the first unknown of a run, `mig_unknown_alert`
  raises one `lane-alert.sh --id migration-prs-ledger-unknown --severity warn`
  (same `alert_dedupes_by_id` routing and same fallback). Without it the lane
  went dark during exactly the outage it guards: the per-PR skip writes only to
  `logs/migrations.log`, which nothing tails — this lane deliberately moved off
  `ALERTS.log` in 2026-08 — so a merged migration-SQL PR needing a human was
  announced nowhere for the whole outage, and the autopilot's HOLD does not cover
  the gap (it fires only for harness-authored files inside the 48h window that the
  file ledger does not already hold). The condition closes at the end of a run
  that got a real answer and hit no unknown. ONE alert per run, not per PR: the
  two markers are `mktemp` files (removed on exit), because the per-PR loop is the
  right-hand side of a pipe and so a subshell — a shell variable would reset at
  every one of the four repos.
- `mig_seen` has the same three answers. On unknown the PR is skipped for this
  tick with one `migrations.log` line and no page — per PR, not an exit, because
  the loop spans four repos and a per-project auth swap.
- `mig_autopilot_applied_all` suppresses the human ping when EVERY file on the PR
  has an autopilot row whose status starts `applied`. Narrow on purpose:
  `flagged`, `failed-alerted`, `skipped` and `legacy-file` all still page.
- `mig_record` writes the DB row; it writes the legacy file only when no worker
  is configured. The `alerted` row is written AFTER `beat.sh` returns, so a run
  killed mid-send cannot leave "alerted" behind for a page that never went out.
- The beat payload, its akey (`migration:<owner/repo>#<n>`), its message text and
  the `MIGRATION_TOKEN` handling are untouched.

## Keys, and why there are two shapes

`kind=migration` holds both lanes' rows. The autopilot's key is
`<project> <file>`; this lane's key is `<owner/repo>#<n>`, which has been its
dedupe subject since 2026-07-24. Sharing the kind is the point — it is how an
autopilot apply now suppresses the human ping. Keeping the shapes distinct is
what stops the two lanes from overwriting each other's meaning: per-file
`human-alerted` rows under the autopilot's key would have made `ledger_has` see
them as present and never auto-apply those files.

## The one-release legacy read

`state/migration-prs-alerted.txt` is still created and still READ, but only on a
**real miss** (rc 2), never on an outage. A key found there is back-filled into
the DB as status `legacy-file`. Without that, the first tick after this ships
would re-page the last 15 merged migration PRs in each of four repos. It is never
written while a worker is configured. Drop the read in a later release.

## What a box without a worker does

Nothing changes. "Unknown" requires a worker to be CONFIGURED — `jobs-client.sh`
sourced AND `HARNESS_SECRET` non-empty. Without both, `job_ledger_get` returns rc
1 on every call, and reading that as unknown would make every such box HOLD and
page forever. `tests/remediator-agent-test.sh` runs `check-migration-prs.sh` in
exactly that shape and is unchanged.

## Tests

`tests/migration-ledger-three-answers-test.sh` (new, 69 assertions). Both scripts
run as scripts, not sourced for their functions. The `jobs-client.sh` stub's
answers come from `$T/ledger-mode`; `gh` and `curl` are fixtures. Cases 1-3 are
the autopilot's three answers (hold / back-fill / apply once, then file-first on
the second run) plus 1b, the same hold on a box without `bin/lane-alert.sh`, 1c
the same hold with the alert state machine OFF (no `--id` call, one deduped beat)
and 1d the hold's severity while prod is not yet serving the merge; 4-10 are the
PR lane's (outage — including its own blind alert at 4/4b and the resolve at 4c —
present, applied-per-autopilot and its flagged negative, absent, no-worker,
legacy back-fill, app-ledger), and 11 is a tripwire proving the live
`/root/harness` state files did not move.

Nine mutations were checked to go red before this shipped: reverting the loop to
`ledger_has "$FN" && continue`; `ledger_has` rc `*) return 1`; dropping the
back-fill; `mig_seen` rc `*) return 1`; `mig_autopilot_applied_all` accepting any
status; `mig_record` always writing the file; dropping the legacy back-fill; dropping
the `lane-alert.sh`-absent fallback in `HOLD`; the app-ledger branch writing the
legacy file again.

Round 2 (the review of `694b70e3`) added four more, each red on that head before
the fix: `HOLD` calling `lane-alert.sh` with the state machine off; `HOLD`
hard-coding `--severity critical`; the PR lane's unknown branch with no alert at
all; the PR lane raising that alert once per PR instead of once per run.

## Line references that moved

`docs/BOARD-API-CONTRACT.md:575` cites `bin/migration-autopilot.sh:131-140` (the
`FAIL` helper) and `:587` cites `:215-219` (the verify-through-the-status-ledger
block). After this change `FAIL` is at **167-175** and the verify block at
**291-295**. The contract doc is not edited — this note carries the correction,
which is the rule (D37).
