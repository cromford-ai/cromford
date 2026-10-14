# In-app text dependencies: the contract slice (BH-3962, part 0 of BH-3946)

Doc: TRIAGE-STATE

## What changed

This lands the lib skeleton and the three hook points for BH-3946, with no
behaviour. Every work function is a stub, so every gate answer, tick reason and
scope line is what it was before.

- `bin/lib/inapp-deps.sh` is new. It defines `inapp_deps_on`,
  `inapp_deps_state_dir`, `inapp_deps_ready_file` and the private
  `_inapp_deps_knobs`, then sources its two part files.
- `bin/lib/inapp-deps/core.sh` holds stubs: `inapp_deps_lines` prints `NONE`,
  `inapp_deps_eval` prints `VERDICT<TAB>NONE<TAB><TAB><TAB>`,
  `inapp_deps_buildable` prints nothing.
- `bin/lib/inapp-deps/release.sh` holds stubs: `inapp_deps_gate` and
  `inapp_deps_take_lines` print nothing, `inapp_deps_hold_check` prints `clear`.

## The hooks

1. `bin/triage-gate.sh --buildable[-strict]`: when the board served no
   `blocked` boolean on an in-app project, the raw ticket goes to
   `inapp_deps_buildable` through a temp file. A non-empty first line is the
   answer.
2. `bin/triage-gate.sh` step 1e, after 1d: a stale
   `state/inapp-deps-ready-<p>` (older than `INAPP_DEPS_REMIND_S`) is deleted
   unread, then `inapp_deps_gate` printing anything answers
   `RUN inapp-deps-ready`.
3. `bin/lib/rt/scope.sh` `inapp_released_lines` appends
   `inapp_deps_take_lines` output after the gate-release lines.

Each hook checks the function is defined and the switch is not held, so a box
without the lib, or with the switch on, is today exactly.

## The new tick reason

`inapp-deps-ready` joins `split-ready` and `gate-reoffer` in both of
`bin/lib/rt/scope.sh`'s `GATE_REASON` cases (scoped tick, live fingerprint
refreshed with `--pending` first) and in `_ts_enforce_reason`
(`bin/lib/triage-state.sh`). The sibling slices fill only the two part files.

## Switch and knobs

- Kill switch `inapp-deps-off` (`catalog/switches.d/inapp-deps-off.json`):
  settings row `switch.inapp-deps-off[.<box>]`, else `flags/inapp-deps-off`.
- Knobs in `catalog/lanes.d/_lib.inapp-deps.json`: `INAPP_DEPS_REMIND_S`
  (fallback 21600) and `INAPP_DEPS_MAX_LOOKUPS` (fallback 10).

Pinned by `tests/inapp-deps-contract.bh-3962-test.sh`.
