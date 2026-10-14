# Cost/billing and mission-control knobs now come from the registry

Doc: OPERATOR-SETUP

## What changed

BH-1939 is part 3 of 5 of BH-1511's split. Sixteen `${VAR:-literal}` defaults
in four files are gone. Each knob is registered `required: true` with today's
literal as its `default`, in a NEW per-lib file (`_lib.json` is untouched):

| Lib id | Registry file | Knobs | Settings key |
|---|---|---|---|
| `gh-budget` | `catalog/lanes.d/_lib.gh-budget.json` | GH_BUDGET_TTL_S (60), GH_BUDGET_DB_TIMEOUT_S (4) | `lib.gh-budget.<env lowercased>` |
| `transcript-cost` | `catalog/lanes.d/_lib.transcript-cost.json` | COST_TRANSCRIPT_SCAN_MAX (400), COST_CACHE_TTL (auto) | `lib.transcript-cost.<env lowercased>` |
| `main-red-gate` | `catalog/lanes.d/_lib.main-red-gate.json` | MC_MAIN_RED_TEST_PATHS (`tests/* worker/*/test/*`) | `lib.main-red-gate.mc_main_red_test_paths` |
| `mc-queue` | `catalog/lanes.d/_lib.mc-queue.json` | MC_QUEUE_TTL (300), MC_MERGE_SETTLE (5), MC_ENQUEUE_SETTLE (2), MC_MERGIFY_SETTLE (15), MC_MERGIFY_WAIT_S (90); settable:false: MC_EJECT_REBASE (1), MC_MERGIFY_STUCK_SECS (300), MC_MERGIFY_REFRESH_WINDOW_SECS (3600), MC_MERGIFY_STUCK_ALERT_SECS (600), BATCH_TRAIN_MIN (1) | `lib.mc-queue.<env lowercased>` |

The value resolves row > cached row > env > registry default > fail closed,
through the existing `lib_env_apply`. `bin/lib/lane-gate.sh` is not edited.

## The five settable:false knobs

These five names already had a settings key on a lane, so a lib key would be a
second key for the same knob. The lib entry supplies the default only, and
operators keep setting the lane key:

- MC_EJECT_REBASE, MC_MERGIFY_STUCK_SECS, MC_MERGIFY_REFRESH_WINDOW_SECS,
  MC_MERGIFY_STUCK_ALERT_SECS: `lane.merge-conductor.<env lowercased>`.
  `bin/merge-conductor.sh` runs `lane_env_apply merge-conductor` before it
  sources the lib, so the row is already env, and `lib_env_apply` keeps a
  non-empty env.
- BATCH_TRAIN_MIN: `lane.batch-resolve.batch_train_min`, which
  `mc_batch_should_spawn` still reads through `lane_knob` first.

A `lib.<id>.*` row for any of the five is ignored (`lib_env_apply` does not
read rows for a settable:false knob).

MC_MAIN_RED_LABEL is not converted here. Main already made it one knob
(BH-1770): the lib row `lib.main-red-label.mc_main_red_label`, resolved by
`bin/lib/main-red-label.sh`, which `main-red-gate.sh` calls before this slice's
subshell. A second registration under `main-red-gate` would split it again.

## How each file resolves (and why in a subshell)

Each of the four files runs one block at the point where it used to assign
its default. The block calls `lib_env_apply <id>` inside `$( … )` and copies
back every knob that resolved:

- The subshell means `lane-gate.sh` never replaces a function the caller already
  defined, such as a suite's `lane_knob` stub. It also means the fail-closed
  `exit 75` never stops one of the 14+17 lanes that source these libs.
- When `$HARNESS` has no readable registry and `LANE_REGISTRY` is unset, the
  block reads the registry of the checkout the lib lives in. Fixture suites run
  with a scratch `HARNESS` and no `catalog/`. In production `$HARNESS` is that
  same checkout.
- A resolved `0` is assigned, and an empty answer leaves the variable alone.

## When nothing resolves

A required knob with no row, no env and no default gets one ALERTS line per
lib per day (`_lg_alert_once`), and the caller keeps running. Every read then
takes the branch that does less:

- gh-budget trusts no cache and turns off the shared row.
- main-red-gate exempts nothing: an empty path list matches no file, and an
  empty label matches no PR.
- mc-queue caches nothing, sleeps not at all, and makes one Mergify witness pass.
- transcript-cost falls to its python reader's own handling, which is unchanged.

## Left in place

- **GH_BUDGET_DB.** The ticket calls it a path (BOX_LAYOUT) and says to leave it,
  so it stays `${GH_BUDGET_DB:-1}`. The ticket's reason is wrong: the code reads
  it as a 0/1 switch for the shared budget row, not as a path. Registering it
  (int 0..1, zero_means "off", default 1) is a later slice's call.
- **GH_BUDGET_MIN_REMAINING.** It has no literal read. It already resolves
  through the `gh_budget_min_remaining` setting, then env, then 800.
- **MC_DV_INLINE** (`bin/deploy-request.sh`). It's a per-call flag that
  `bin/lib/mc/rebase.sh` sets for one invocation. A row outranks env, so a row
  would flip it for every caller. `deploy-request.sh` is unchanged.
- **MC_MERGIFY_LABEL, MC_MERGIFY_REQUEUE_CMD.** Both are contracts with Mergify
  (`.mergify.yml`), not knobs.
- The existing number validators (`queue.sh`'s `min=1` floor, the BH-1887
  fallbacks in `mc_mergify_stuck_pass`, transcript-cost's python `or 400` /
  `or "auto"`). They handle a garbage value, not the missing default.

"Does less" here means it changes nothing and merges nothing it wouldn't
otherwise have. It does not mean fewer API calls. With no TTL, the gh-budget
refresh and the merge-queue provider probe ask GitHub on every call. That only
happens when no registry can be read at all.

## Suites that copy these libs

Many suites copy a lib into a scratch tree that has no `lane-gate.sh` and no
registry. There the knobs now resolve to nothing, where they used to fall back
to the file's literal. Six suites depended on that literal. Each one now exports
the registry default it relies on, next to the values it already pinned:

- `tests/gh-budget-shared-test.sh`: GH_BUDGET_DB_TIMEOUT_S=4
- `tests/main-red-gate.bh-987-test.sh`, `tests/main-red-box-freeze.bh-945-test.sh`,
  `tests/main-red-pair-suspected.bh-1451-test.sh`: MC_MAIN_RED_LABEL,
  MC_MAIN_RED_TEST_PATHS
- `tests/mc/queue-test.sh`: those two, plus MC_QUEUE_TTL=300
- `tests/conductor-limited-read.bh-784-test.sh`: MC_QUEUE_TTL=300

No assertion changed. Copying `lane-gate.sh` into those trees instead would also
arm the lane gate and the settings fetch in every script under test there.

Pinned by `tests/config-slice-cost-mc.bh-1939-test.sh`.
