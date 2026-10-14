# BH-2247: a zombie pid is a dead run to the fan-in check

Doc: MERGE-CONDUCTOR

## The race

`tests/fanin.bh-186-test.sh` C3 kills a conductor tick inside #13's worker,
then runs the next tick straight away. It expects that tick's `fanin_begin` to
find the dead run's ledger (`state/fanin/merge-conductor/example-org_demo-os.<pid>`)
and alert `(run died before fan-in)`.

`fanin_begin` decided a ledger's run was alive with `kill -0 <pid>`, and
`kill -0` succeeds on a zombie. The ledger pid is the `tick_project` subshell.
When the group is SIGKILLed that subshell becomes an orphan, and only PID 1 can
reap it. On the pool boxes PID 1 is `/fly/init`, which reaps in batches. During
planning the pid was still `Z` when `setsid -w` returned in 200 of 200 trials,
and it stayed that way for about 0.35-0.7 s. C3 went green only when the next
tick's startup outlasted that reap. When it didn't, the dead ledger was skipped
as a live parallel run, and C3 failed with "the next tick alerts the dead
tick's missing PRs (got: none)". There was no `sleep` in C3. What was missing
was a sync on "the killed run is dead", and the product check got that
condition wrong for zombies.

## The fix

- `bin/lib/fanin.sh`: new `_fanin_pid_live <pid>`. It returns dead when
  `kill -0` fails, when `/proc/<pid>/stat` shows state `Z` or `X`, or when the
  stat read fails because the pid vanished between the two checks. With no
  `/proc` it keeps the `kill -0` answer (`FANIN_PROC` is the test seam for the
  root). `fanin_begin` uses it in place of the bare `kill -0`. A running or
  stopped (`T`) pid is still a live run, so a parallel run's ledger is never
  touched.
- `tests/fanin.bh-186-test.sh` C3: after the killing tick, it reads the ledger
  pid and polls at most 100 x 0.1 s until that pid is dead or a zombie. It
  uses the same definition as the lib. If the bound expires, or no ledger was
  left, it fails as a named setup error instead of passing by luck.
- `tests/fanin-zombie.bh-2247-test.sh` pins the rule against a real zombie:
  it alerts and deletes (Z1), deletes a fully accounted zombie silently (Z2),
  leaves live (Z3) and stopped (Z4) pids alone, and falls back when there is no
  `/proc` (Z5).

## Proof

- Before the fix, Z1 and Z2 fail on the unmodified lib: `FAIL: Z1: a zombie
  (<pid>) ledger is a dead run and alerts once (alerts: )`.
- Reverting the lib line to `kill -0` or dropping the `Z|X` case turns Z1 and
  Z2 red. Hardcoding `/proc` turns Z5 red. Counting `S` or `T` as dead turns
  Z3 or Z4 red.
- On the build box, C3's wait found the ledger pid in state `Z` on every
  instrumented run. That is the window the fix closes.
- The end-to-end C3 flake itself did not reproduce on the build box: the
  unmodified test passed 8 of 8 runs in parallel. The 20-run proof below
  therefore shows C3 is green with the fix. It does not show it was red before.
- 20 consecutive `tests/fanin.bh-186-test.sh` runs on the build box, all green.
