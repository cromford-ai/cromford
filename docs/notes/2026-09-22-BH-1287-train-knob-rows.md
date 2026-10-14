# BH-1287: the fix shipped in #1297; this note is about the two knobs it left unpinned

**What #1287 reported.** `bin/lib/mc/train.sh` fixes `MC_TRAIN_CI_REQUIRED`,
`MC_TRAIN_CI_WORKFLOW` and `MC_TRAIN_CI_IGNORE` at SOURCE time from
`${BATCH_CI_RUN_REQUIRED:-1}` / `${BATCH_CI_WORKFLOW:-Harness CI}` /
`${BATCH_CI_IGNORE:-^(Mergify|Publish share mirror)}`. The module used to be
sourced ABOVE `lane_env_apply batch-resolve "$PROJECT"` in
`bin/batch-resolve.sh`, so those three assignments ran before the lane's
settings rows were exported — and a `lane.batch-resolve.batch_ci_*` row reached
the environment one line too late to be read. The registry called all three
settable, the console wrote the row, `bin/harness-ctl.sh show` printed the new
value, and the lane went on logging the default back at the operator who had
just changed it. Nothing errored, because the `env/global.env` path worked
throughout. That is why it went unnoticed.

**There is no product bug left to fix.** The one-line fix the ticket asked for
("source `bin/lib/mc/train.sh` after `lane_env_apply`") landed on main in
#1297 (BH-1270, commit 0f0dc75, merged 2026-09-22 06:34Z). That PR's body says
"Closes #1270" and mentions #1287 only in passing, which is why this issue
stayed open with `ai-build` on it. On HEAD the source sits at
`bin/batch-resolve.sh:132` with `lane_env_apply` at `:115`, and
`tests/batch-resolve-trains.bh-1270-test.sh` T9 pins it: on a temp copy of the
tree with the source line moved back above `lane_env_apply`, T9 fails with the
ticket's verbatim symptom — `STANDS — the fix PR #200 merged but no Harness CI
run for … (BATCH_CI_RUN_REQUIRED=1 …)` while the row says 0.

**What was missing.** T9 drives ONE of the three knobs. Nothing drove a
`batch_ci_workflow` or a `batch_ci_ignore` ROW end to end, so a future
re-ordering that happened to keep `BATCH_CI_RUN_REQUIRED` working — reading
that one knob at call time and leaving the other two at source time, which is
the ticket's "option A" done halfway — would have passed CI with two of the
three knobs silently dead again.

**What this PR adds.** `tests/batch-resolve-trains.bh-1287-test.sh`, two cases
against the SHIPPED `bin/batch-resolve.sh` through its main-red freeze-lift
branch (`bin/batch-resolve.sh:253-302`, which runs before any candidate work,
so no PRs are built and no train is formed). Both arms of each case are read
from outside the module — the flag file the lane removes and the line it writes
to `logs/batch-resolve.log`:

- **W** — a fix head carrying a concluded `Harness CI` success lifts the freeze
  with no row. A `lane.batch-resolve.batch_ci_workflow=Fleet CI` row makes the
  same head un-green, and the refusal names `Fleet CI` — the row's own value
  coming back out of `MRT_GREEN_WHY` is what distinguishes "the module saw the
  row" from "it refused for some other reason".
- **I** — a `Leak Guard` check run still `in_progress` holds the freeze at the
  default ignore ERE. A `lane.batch-resolve.batch_ci_ignore` row that widens the
  ERE to cover it lifts the freeze. String rows are not clamped or rewritten by
  `lane_knob` (`bin/lib/lane-gate.sh` only bounds numeric values), so the ERE
  reaches `MC_TRAIN_CI_IGNORE` as the operator wrote it.

Under the same source-order mutation, W-2 and I-2 both go red and the two
control arms stay green — the mutation breaks only the settings-ROW path, which
is the shape a real pin has.

**One map cell was wrong.** `docs/verification-map/entries/BH-1270.md`'s last
row records the #1287 behaviour but pointed its test column at
`tests/lanes-registry-test.sh` section 16, which checks that `lane_env_apply`
sits below the env-file load in every lane — a different ordering, and not the
thing that pins this. It now names `tests/batch-resolve-trains.bh-1270-test.sh`
T9, which is the real pin. `docs/verification-map/entries/BH-1287.md` carries
the two new rows.

**Not done, on purpose.** `BATCH_MODULE_DIRS` → `MC_TRAIN_MODULE_DIRS` has the
same source-time shape and is fixed by the same #1297 ordering, but the ticket
names three knobs and a case for it needs the BH-1270 candidate fixture. It is
unpinned. So is the project-scoped key spelling
(`lane.batch-resolve.<project>.batch_ci_*`) — `lane_env_apply` resolves it, and
nothing drives it.

Doc: MERGE-TRAINS
