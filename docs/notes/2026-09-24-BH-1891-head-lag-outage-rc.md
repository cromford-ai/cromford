# A jobs-worker outage no longer reads as "never kicked" in the head-lag check

Doc: MERGE-CONDUCTOR

## What changed

`mc_attempt_rows` (bin/lib/mc/locks.sh) now has its own return code for an outage:

| rc | meaning |
|---|---|
| 0 | rows, written to the out-file |
| 2 | a measured none |
| 1 | rows not in use: `flags/pr-state-rows` is down, or the kind, key or out-file is unusable |
| 3 | the jobs worker could not answer. That covers a failed or unparseable GET on this call, a tick already latched down (`<tick>.pr-rows-down`), and a process that already tripped (`_PR_ROWS_DOWN=1`). The out-file is left empty. |

`head_lag_rows_read` passes rc 3 through unchanged. When `head_lag_check` gets rc 3
for a tip its state file does not hold, it writes no head-lag file and no `seen`
row, and it makes no kick decision that tick. It logs
`<pr> head-lag record for <tip8> not read: pr-state-rows unreachable — …` and
asks again on the next tick. rc 1 and rc 2 still take the fresh-clock path, so
the flag-down behaviour from BH-1529 is unchanged.

## Why

This came out of the #1889 review (BH-1564). `mc_attempt_rows` used to return rc 1
both when the flag was down and when the worker was unreachable. Say the worker
was down on the one tick that found the state file gone after a real kick. That
tick started a fresh clock in the file. Later ticks trusted the file and never
re-read the rows, so once `MC_HEAD_LAG_MINS` passed, the PR got a second
close/reopen. When the ledger can't be read, the tick now does nothing instead of
treating it as "not spent".

## Trade-off

During a long outage, a lagging PR with no state file gets no clock and no kick
until the worker answers. That delays the kick, but it can never double it.

Pinned by `tests/mc-head-lag-rows.bh-1564-test.sh` sections G and J.
