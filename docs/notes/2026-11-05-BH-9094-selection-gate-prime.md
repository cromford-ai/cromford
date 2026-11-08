# The selection gate's base-run cache is primed every hour (BH-9094, slice C0)

Doc: REMOTE-GATE

## What happened

On 2026-11-04, 25 of 38 cromford `GATE_RED`s had
`baseline: could-not-run: timeout`. The base run of `bin/selection-gate.sh`
(step 6, BH-8901) caches a clean answer per (base sha, suite) in
`state/selection-gate/baseline/`. But that cache is local to the machine, and
every cromford gate runs on a fresh pool machine. Nothing else wrote the
cache, so every base run was a cold run of every red suite under the 900 s
bound.

## What changed

1. `bin/selection-gate-prime.sh` is a new hub lane (`cron/lanes/779-selection-gate-prime.cron`,
   `7 * * * *`, behind `hub-lease.sh check`). Each run:
   - fetches origin main in `/root/repos/cromford` and takes its sha;
   - deletes `baseline/<sha>` dirs older than `SELECTION_GATE_PRIME_KEEP_DAYS`;
   - stops when `baseline/<sha>/.primed` exists (`already primed`), after it
     recomposes prime.tsv;
   - counts the suites in the `red:` and `baseline-red:` fields of the
     cromford `gate.txt` records (`builds/pool-cromford-*`,
     `builds/cromford-*`) of the last `SELECTION_GATE_PRIME_WINDOW_DAYS`
     days, once per record. `noted:` is not counted. A suite with no file in
     the main tree is dropped. It keeps the first `SELECTION_GATE_PRIME_SUITES`
     by count, then by name;
   - runs the ones with no cached answer once, with `bin/remote-gate.sh` on a
     detached worktree of the sha, at `REMOTE_GATE_P=SELECTION_GATE_PRIME_P`,
     under `SELECTION_GATE_PRIME_TIMEOUT_S`;
   - classifies each suite with `bin/selection-gate.sh --classify`, the gate's
     own `bl_class`, and writes red or green to `baseline/<sha>/<suite, / as _>`;
   - writes `baseline/<sha>/.primed`: line 1 `primed <utc> suites=<n> red=<r>
     green=<g> unknown=<u>`, then one `<suite> TAB <red|green>` line per write;
   - composes `state/selection-gate/prime.tsv`: `<sha> TAB <suite> TAB
     <red|green>` for the newest `SELECTION_GATE_PRIME_RELAY_SHAS` primed shas.
     It is replaced only when its bytes change.
   A run that could not run (the timeout, rc over 123, a `RUNNER-FAILURE`
   line) caches nothing, writes no `.primed` and leaves prime.tsv as it was.
   It is one log line, not an alert: a cold cache is the behaviour from before
   this change. The next hour tries again.
2. `bin/lib/sg-prime-relay.sh` `sg_prime_relay <mid>` runs in the live-machine
   refresh block of `bin/fly-pool.sh`. For the harness's own pool only
   (`POOL_SLUG` equals `HARNESS_REPO`), it puts prime.tsv to
   `/data/harness/state/selection-gate/prime.tsv` when its mtime moved. The
   sidecar `$POOL/.<mid>.sgprimemt` is written after a good put only, and goes
   with the machine file.
3. `baseline_pass` in `bin/selection-gate.sh` reads prime.tsv once. A row is a
   hit only when column 1 is the merge base (all 40 hex) and column 3 is
   exactly `red` or `green`. The per-file cache wins when both have a value.
   `(<c> cached)` in `baseline:` counts both kinds of hit.
4. `bin/selection-gate.sh --classify <run file> <suite>` prints red, green or
   unknown. `bl_class` moved above the argument parse for it; its body did not
   change.

## Knobs

Lane `selection-gate-prime` (`catalog/lanes.d/selection-gate-prime.json`):
`SELECTION_GATE_PRIME_SUITES` 20, `_WINDOW_DAYS` 7, `_TIMEOUT_S` 900, `_P` 4,
`_KEEP_DAYS` 2, `_RELAY_SHAS` 3, `_FETCH_TIMEOUT_S` 60. A value out of range is
one ALERTS line and no prime. Off: `flags/lane-off-selection-gate-prime`.

## Not in this slice

- Fix 3 of #9094 (context-kill family rows): it needs a hub run.txt line for
  each row.
- Fix 4 of #9094 (the daily count on the dash and in the fly-pool tick summary).
- Acceptance 5 of #9094 (24 h `GATE_RED` counts with a base could-not-run under
  10%): a measurement on the hub after the deploy.

Suite: `tests/selection-gate-prime.bh-9094-test.sh`.
