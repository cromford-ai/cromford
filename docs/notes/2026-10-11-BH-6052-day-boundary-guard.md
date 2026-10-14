# Suites that read a UTC day stamp wait out 00:00Z (BH-6052)

Doc: TEST-DETERMINISM

## What happened

The #6049 audit found 63 `tests/*.sh` files with a `date -u` day stamp (`%Y%m%d`, `%F`,
`%Y-%m-%d`). The code under test reads the day, and the suite reads it again to build the value it
expects. A run that crosses 00:00Z between the two reads compares two different days and is red on a
correct build.

## What changed

1. **`tests/lib/day-boundary.sh`** defines `clear_boundary <period_s> <margin_s>`. If the next
   multiple of `period_s` on the epoch clock is `margin_s` seconds away or less, it sleeps until 1 s
   past it and writes `clear_boundary: waiting <n>s for the <period_s>s boundary` to stderr.
   Otherwise it returns at once. Bad arguments return 2. If a `clear_boundary` is already defined
   (#6049's `tests/lib/wait-for.sh`), the file defines nothing.
2. **61 suites call it** right after their `scratch.sh` source, as 3 added lines:
   ```
   # TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
   . "$(dirname "$0")/lib/day-boundary.sh" || exit 1
   clear_boundary 86400 <margin> || exit 1
   ```
   The margin is `max(30, ceil(2 × wall time) + 5)` seconds, from a run on the build box. No
   assertion changed.
3. **`tests/lib/at-utc-midnight.sh <suite> [lead_s]`** runs a suite with a `date` shim on PATH. The
   shim clock starts `lead_s` (default 10) seconds before the next 00:00Z.
4. **`tests/day-boundary-guard.bh-6052-test.sh` section C** fails on any `tests/*.sh` day-stamp read
   that has no guard before it and is not in its 2-row benign table. A new suite that reads a day
   stamp adds the 3 lines above.

## What usually lies

- The shim moves only the `date` command, and only a plain read of now. A relative
  `date -d '5 days ago'`, a file mtime, and a clock read in python or node see the real clock. A suite
  whose code compares `date +%s` with a file mtime fails under the shim with or without the guard
  (`tests/cost-grok-usage-test.sh` is one). That is a limit of the shim, not a straddle.
- The wait happens only in the `margin` seconds before 00:00Z, and only once per suite run.
