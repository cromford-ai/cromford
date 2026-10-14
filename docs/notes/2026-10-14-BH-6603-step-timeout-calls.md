# A step-timeout kill reports the call trace (BH-6603)

Doc: MERGE-CONDUCTOR

## The gap

BH-6462 gave each bounded conductor worker a call trace, `<mark>.calls`. A
`WORKER_DEADLINE` kill reports it. A `STEP_TIMEOUT` kill (BH-6351) did not.
`mc_fanin_outcome` in `bin/lib/fanin.sh` read the summary into `calls` and
removed the file before it chose the arm, so the step-timeout arm had the
value and dropped it.

## What changed

The step-timeout arm of `mc_fanin_outcome` now reports `calls`, the same as
the deadline arm:

- The `STEP_TIMEOUT` log line and its lane alert end with
  ` | calls: <call_trace_summary>`. Example:
  `<key> STEP_TIMEOUT step=dep-gate after 2s on 81000000 (step timeout 2s, worker deadline 30s): worker stopped; row left READY, the next tick works it again | calls: dep-gate gh=1/1.5s; slowest: gh GET repos/o/r/pulls/9 1.5s (dep-gate)`
- The `conductor-step-timeout` Sentry extra has the key `calls` with the same
  summary. The title, the fingerprint and the tags do not change.
- The value is `none` when the worker traced no call or left no file.

The outcome word (`killed:step-timeout`), the dedupe key
(`steptimeout <key> <head> <step>`) and the file removal do not change.
`mc_worker_bounded` already keeps `<mark>.calls` when a kill wrote the mark.

## Check on the box

```bash
grep STEP_TIMEOUT /root/harness/logs/merge-conductor.log | grep -o '| calls: .*' | tail -3
```

The next step-timeout kill after the deploy shows the segment.

## Tests

`tests/mc-step-timeout-calls.bh-6603-test.sh` drives the real
`mc_worker_bounded` step watchdog and `mc_fanin_outcome`. The
`tests/mc-step-timeout.bh-6351-test.sh` T1 end anchor now allows the segment.
