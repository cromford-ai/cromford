# BH-2650 (BH-2613.2): triage, hotfix, pause and heartbeat libs have no literal root

Doc: LIB-ROOT-RESOLUTION

Part 3 of 5 of #2613. It applies the contract in
`docs/notes/2026-09-26-BH-2613-lib-root-resolution.md` (rules 1-6) to ten libs
and deletes their ten baseline files under `tests/fixtures/root-fallback-baseline/`.
Their 56 sites are now 0. `tests/lib-root-triage.bh-2613-test.sh` pins it.

The root is `${HARNESS:-${H:-}}`. The caller-scoped vars stay where they
were: `JOBS_HARNESS` first in `pause`, `HB_DIR` and `HB_DB_CMD` first in
`heartbeat`, and the positional root first wherever a function takes one. On a
box every entry point sets H or HARNESS before it sources these libs, so the
answers there are unchanged.

## What each lib answers with no root

| Lib | No-root answer |
|---|---|
| `triage-shards-lib` | Every knob gives its env var, then its default (no env file is read). The `triage-shards-off` / `triage-shard-caps-off` switches read as absent. `triage_model` gives the env var, then rc 75 with nothing on stdout ("no route"). The gate-ledger lib is sourced from the sibling copy only. |
| `triage-hotfix-lib` | hotfix-lib, gh-budget and gh-rest are not sourced, so `triage_hot_mark` is a `cat` passthrough. |
| `triage-throttle` | `triage_health_on` gives the env answer (default 1). `triage_health_warn_once` with an empty root stamps no flag and runs no lane-alert.sh. It still writes the raw WARN line to the alerts file it is given, on every call. |
| `triage-gate-ledger` | ledger-twin is sourced from the sibling copy only. The functions already refused an empty root. |
| `hotfix-lib` | Lane on, label `hotfix`, `main_red_label` from the env tiers (default `fix-main-red`). `hotfix_issue_is` loads no gh-rest, so it answers rc 2 (unknown), which is falsy. `hotfix_announce` already refused an empty root. |
| `hotfix-migrate-workflow` | gh-app-auth is not sourced. The body runs on the caller's token. |
| `conf-row` | `conf_rows`, `conf_rows_preload` and `conf_row_refused` return 0 with nothing done. `conf_row` returns 1 with `CONF_ROW_SRC=none`. `conf_row_note_file` returns 0. lane-gate is never loaded. |
| `heartbeat` | `hb_dir`, `hb_file` and the `-db` stamp paths print "". `hb_start`, `hb_tick` and `hb_done` write nothing and return 0. `hb_db_enabled` is dark unless `HB_DB=1`. With `HB_DB=1` and an `HB_DB_CMD`, every beat is sent and no stamp is written, so no beat is rate-limited. |
| `issue-state-lib` | `_issue_switch` gives the env answer (default on), `_issue_env` the default. gh-app-auth is not sourced. The gh calls still go out, on the caller's token. |
| `pause` | No cache path. `pause_active` is rc 1 and `pause_label` prints nothing, which is exactly a root with no `state/pauses.json`. `pause_refresh` still sends the POST expire and the GET. It writes no `logs/pauses.log` line and no cache, and returns 1 (what an unwritable state dir returns). `pause_env_shapes` still reports the env review cap with the default knob and skips the `flags/` checks. |

## Cross-lib calls skipped with no root

These libs still carry their own literal until a sibling or the remainder
converts them, so with no root they are not called or sourced at all. Handing
them an empty HARNESS would reach that literal.

- `lane_switch` (lane-switch, #2649) in triage-shards-lib, triage-throttle and hotfix-lib
- `lane_role_model` (lane-model, #2652) in `triage_model`
- `main_red_label_resolve` (main-red-label, remainder) in `main_red_label`
- gh-rest (remainder) from the root in triage-hotfix-lib and `hotfix_issue_is`
- gh-app-auth (remainder) in `hm_workflow` and at the top of issue-state-lib

## Not changed

- No `bin/*.sh` is touched. Every entry point that sources one of these libs
  sets H or HARNESS before its source line (rule 4).
- No existing suite needed a scratch HARNESS: all of them already set one.
  `tests/lane-switch-readers-triage.bh-2437-test.sh` reverts the
  `triage-shards-off` read with a `sed` for its D1 case, and its pattern now
  also matches the line with the new `[ -n "$h" ] && ` guard in front.
- Some writers in `triage-shards-lib` take a required positional root and do
  not refuse an empty one (for example `triage_shard_fp_put`). They are not
  counted sites and are not changed here. Their callers (`bin/lib/rt/shards.sh`,
  `bin/triage-shard.sh`) pass `$HARNESS`, which run-triage and triage-shard set.
