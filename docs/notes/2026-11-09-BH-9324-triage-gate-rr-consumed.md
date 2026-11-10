# BH-9324: the triage gate reads the rr-consumed row before it buys a run

Doc: TRIAGE-STATE, STATE-STORES

## Problem

`bin/triage-gate.sh` answered `RUN remote-results-pending` when any `*.json`
was in `state/remote-results/<p>/`. Staging runs before the gate on every tick
and moves every json it reads. So a json at gate time is often a hub re-send
(pool relay retry, custody sweep) of a json this box already consumed. The
gate bought a paid triage run for it, and the next staging pass consumed it as
`duplicate`.

## Change

- `bin/lib/triage-gate-relay.sh` (new): `tgr_relay_run <project> <dir>` asks
  `rrr_consumed` (`bin/lib/rr-relay.sh`) for each json. It returns 1 (no run
  reason) only when every json has an rr-consumed row with status `staged` or
  `duplicate`, the set staging uses. Any other answer is the old RUN: no row,
  an outage, no client, `empty`, `badjson`, `parked`, a row with no status,
  more jsons than the cap, the knob at 0, no lib.
- `bin/triage-gate.sh`: the json check keeps its glob and its mode set. It
  sets `RR_JSON_PENDING=1`, and the decision runs after the libs are sourced.
- Knob `TRIAGE_GATE_RR_ROWS_MAX` on the run-triage lane (default 20, 0 = off).
  One rr-consumed GET per json, at most the cap; more jsons than the cap run
  as before with no read.

A row read only removes a false RUN. The gate never stages, moves or deletes a
file, and the files stay the input.

## Not in this change

Item 2 of BH-9324 (retire the cursor and relay file writers) is not built.
The rows merged in #9194 on 2026-11-09, and they are lossy copies of the files
(a long `.result` is cut). The files stay the outage cache.

Tests: `tests/triage-gate-relay.bh-9324-test.sh`.
