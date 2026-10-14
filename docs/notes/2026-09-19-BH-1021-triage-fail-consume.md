# A triage session that fails every time is consumed after three attempts, not bought forever

Doc: EVENTS

The gate is edge-triggered: it answers "did the board move since the last
CONSUMED tick", and only an rc=0 session consumed. So a lane whose triage
session died on every attempt left `state/<project>.gate.pending` in place, the
next tick diffed the same board against the same old `gate.json`, answered
`RUN board-changed` again, and paid for the identical failing session ten
minutes later. On project-5 on 2026-09-17 that shape billed **1,168 rc≠0 triage
rows in one day on one fingerprint** — the runaway-spend audit's fix 7 of 8.

## What changed

`bin/lib/rt/launch.sh` had one arm:

```
if [ "$RC" -eq 0 ]; then rt_gate_consume; fi
```

It now has two. Success additionally drops the failure counter; failure calls
the new `rt_gate_fail_consume` in `bin/lib/rt/gate.sh`, which:

1. reads the cap from `TRIAGE_FAIL_CONSUME_AFTER` (default 3; `0` disables and
   restores exactly the old behaviour; blank or non-numeric reads as 3, never as
   "no cap" — an unreadable knob must not be the thing that keeps paying);
2. keys the count on the 16-char sha256 of `state/<project>.gate.pending` —
   the same identity `bin/triage-gate.sh` compares — or on `none` for a tick
   whose gate reason wrote no pending file (`daily-sweep`, `forced`,
   `no-gate-state`), which loops on the same shape because an unstamped
   full-sweep clock re-answers `RUN daily-sweep` every tick;
3. below the cap writes `state/<project>.gate.fail` (two lines: sha, count) and
   one `NOT consumed, failed attempt n/cap` line into `logs/<project>.log`;
4. at the cap calls the SAME `rt_gate_consume` the success path calls, drops the
   counter, logs the consume, and alerts once through `bin/lane-alert.sh --id
   triage-fail-consume:<project> --severity warn`.

The next tick's gate then reads `gate.json == live fingerprint`, answers
`SKIP no-change`, and spends nothing.

## Rules and state this touches

- **State:** `state/<project>.gate.fail`, one file per project, written only by
  the single-session path under the per-project tick flock, removed on any
  consume. Garbage reads as count 0.
- **Ordering:** consume → drop counter → log → alert. A failed alert leaves the
  consume plus one raw `logs/ALERTS.log` line, so a consume is never silent; the
  record is written after the mv, so a record without a consume is impossible.
- **Failure is not success (D9):** the log line and the alert carry the real
  `rc`; only the absorb is borrowed from the success path.
- **Not a lost ticket:** what the consumed fingerprint carried is re-offered as
  soon as the board changes again, or on the daily sweep (`FULL_SWEEP_SECS`).
  That is stated in the alert text too.
- **Untouched:** `bin/lib/rt/shards.sh` (consumes at dispatch, re-arms per key,
  exits before `rt_launch`), `bin/triage-gate.sh`, every queue/sweep brake.

## Where it is pinned

`tests/triage-fail-consume.bh-1021-test.sh` drives the real `bin/run-triage.sh`
in a scratch harness whose agent stub exits with a fixture-supplied code: three
failures consume and alert once, the fourth tick makes no agent call, rc=0 still
consumes, a success clears the counter, a changed fingerprint restarts it,
`TRIAGE_FAIL_CONSUME_AFTER=0` never consumes, and an unrunnable `lane-alert.sh`
still leaves the consume. Map entry: `docs/verification-map/triage-fail-consume.md`.
