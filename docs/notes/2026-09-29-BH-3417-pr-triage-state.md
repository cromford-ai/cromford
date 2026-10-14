# TRIAGE-STATE for PRs: the contract and the inert seams (BH-3417 slice 1)

Doc: TRIAGE-STATE

BH-3418, part 1 of 3 of #3417. The ticket pre-check (`bin/lib/triage-state.sh`)
keeps unchanged tickets away from the model. The `board prs:` lines still go to
the model on every tick they show up in. This slice adds the seams the PR
pre-check is built on. It is wired end to end and does nothing yet:
`ts_pr_precheck` is a stub, so no `pr-*` key is ever dropped and a tick runs
exactly as it did before.

## The mode knob

`PR_STATE_MODE`: `off | shadow | enforce`, default `shadow`, read by
`ts_pr_mode <project>` in `bin/lib/triage-state-pr.sh`. Registered in
`catalog/lanes.d/_lib.triage-state.json` and settable. Rows, first hit wins:

- `lib.triage-state.<project>.pr_state_mode`
- `lib.triage-state.pr_state_mode`

then the env, then `shadow`. Any other value reads as `shadow`. The kill switch
`triage-state-off` (`switch.triage-state-off`, else `flags/triage-state-off`)
answers `off` before any settings read; `catalog/switches.d/triage-state-off.json`
now lists `bin/lib/triage-state-pr.sh` as a reader.

## The four variables

`ts_pr_precheck <project>` sets these, and `ts_tick` reads them:

| Variable | Meaning | Stub value |
|---|---|---|
| `TS_PR_MODE` | `off`, `shadow` or `enforce` (`ts_pr_mode`) | the mode, `off` with no root or no project |
| `TS_PR_READY` | `1` when every open PR was decided | `0` |
| `TS_PR_SKIPSET` | space-padded `pr-*` keys the shard loop may drop, `" pr-12 pr-40 "` | `" "` |
| `TS_PR_DRAFTS` | draft PRs, one per line | empty |

`ts_tick` calls `ts_pr_precheck` right after `ts_precheck` and before the
ticket early return. It sets `TS_PR_ENFORCING=1` only when `TS_PR_MODE=enforce`,
`TS_PR_READY=1` and `_ts_enforce_reason` accepts `GATE_REASON` (the same seven
reasons the ticket path enforces on: board-changed, event-wake, daily-sweep,
queue-pending, results-sweep, remote-results-pending, split-ready). When
`ts_pr_precheck` is not defined (no root, or a box mid-sync without the new
file), the defaults `off / 0 / " " / ""` stand.

`ts_unit_skip <units> <key>` decides a `pr-*` key by the PR state alone: rc 0
only when `TS_PR_ENFORCING=1` and the key is in `TS_PR_SKIPSET`. A ticket key
never reads `TS_PR_*`, and a `pr-*` key never reads the ticket set.

The `^board prs:` condition that keeps a tick with PR lines from ending at $0
is unchanged.

## `_ts_prs_json`

`_ts_prs_json <project> <dir>` is the open-PR read that used to sit inside
`_ts_owned`, moved as is: one `gh_rest_pr_list <slug> open "" 100` per tick
into `<dir>/prs.json`, or the marker `unreadable` when the read fails or there
is no slug. `_ts_owned` calls it and still answers `owned:pr-unreadable` on the
marker. `ts_precheck` removes `prs.json` at the top of every tick, so the next
tick reads again.

## `pr-decisions.tsv`

`state/triage-state/<p>/pr-decisions.tsv` is per-tick scratch, removed at the
top of every `ts_precheck` beside `decisions.tsv`. Nothing writes it in this
slice. Its columns match `decisions.tsv`:

`key  label  decision  reason  hash  seed  in-scope  base`

with `label` = `key` (`pr-N`), `in-scope` = `1` and `base` = `-`.

## `bin/triage-state-pr.py`

CLI stubs, all rc 1 (read as "unhashable" / "not a draft"):

- `pr-hash --thread F --pr F --reviews F --lead F`
- `pr-draft --title T --head-ref R`
- `mergify_state(comments)` returns `None`

Nothing calls them yet.

## Tests

`tests/triage-state-pr-contract.bh-3418-test.sh`.
