# The selection gate opens the PR when it cannot attribute a red (BH-9061, slice C0)

Doc: REMOTE-GATE

## What happened

On 2026-11-04 the pre-PR selection gate (`bin/lib/selection-gate.sh`,
BH-8062) ended 27 of 38 cromford builds `GATE_RED`. In 25 of them
gate.txt said `baseline: could-not-run: timeout`, and in 2 more
`baseline: could-not-run: runner-rc-125: …`. The base run (BH-8901) never ran,
so the gate never checked whether the red suites were red on main too. Each of
those builds was thrown away.

Two causes:

1. `sg_block` read `rc` and `red` only. It never read `baseline:`.
2. `bin/selection-gate.sh` gave the main run the whole `--timeout`. The base
   run then got its own `SELECTION_GATE_BASELINE_TIMEOUT_S` on top of that,
   past the wall the caller gave.

## What changed

- **Unattributed red.** When the gate run is red (`rc: 1`, a red list) and
  `baseline:` starts with `could-not-run`, `sg_block` returns 0 and the PR
  opens. It:
  - appends `unattributed: <comma list>` to `$BUILD/gate.txt` (`rc:` and `red:`
    keep the true run result; `$BUILD/selection-gate/gate.txt` is not changed);
  - logs one line, `SELECTION-GATE unattributed=<n> red=[<list>] baseline=<why>: …`;
  - writes one ALERTS line per box per UTC day,
    `SELECTION GATE COULD NOT ATTRIBUTE <n> red suite(s) on <host>: …`, under
    the day marker `state/selection-gate/cnr-unattributed-<yyyymmdd>`
    (`SELECTION_GATE_CNR_ALERT`, pruned with the `cnr-*` markers);
  - sets the PR-body marker to `rc=could-not-run`, and on the next line one
    sentence that names each suite and says `unattributed`.
  It writes no RESULT and posts no board notice. The merge queue is the gate of
  record. Any other `baseline:` value (`ran …`, `skipped: head-is-base`, no
  line) keeps the old `GATE_RED`, rc 6.
- **The base run gets its time.** With `SELECTION_GATE_BASELINE_RUN=1`, the main
  run's bound is `SELECTION_GATE_TIMEOUT_S - SELECTION_GATE_BASELINE_TIMEOUT_S -
  SELECTION_GATE_BASELINE_RESERVE_PAD_S`, never under
  `SELECTION_GATE_MAIN_TIMEOUT_MIN_S` and never over `--timeout`. With the prod
  rows (2400, 900, 60) the main run gets 1440 s. The step-4 timeout verdict uses
  the same bound.
- **Two new fly-pool knobs:** `SELECTION_GATE_BASELINE_RESERVE_PAD_S` (default
  60) and `SELECTION_GATE_MAIN_TIMEOUT_MIN_S` (default 300).
- **One host note:** `catalog/selection-gate-host-notes.d/bh-9061.tsv` notes
  `tests/ci-durations-db.bh-5653-test.sh` as `shallow-context` when its only
  failure line is `no seed in git history (0 rows)`. The fixture is the real
  output of that suite in a shallow checkout.

Test: `tests/selection-gate-unattributed.bh-9061-test.sh`.

## Left on #9061

- The hourly hub lane that primes `state/selection-gate/baseline`.
- The context-kill host-note rows (each needs a matching hub run.txt line).
- The daily unattributed count on the dash and in the fly-pool tick summary.
- The 24 h re-measure after the deploy.
