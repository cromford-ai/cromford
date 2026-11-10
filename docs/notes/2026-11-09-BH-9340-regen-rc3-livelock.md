# BH-9340: the regenerate rung no longer livelocks on a stable rc 3

Date: 2026-11-09

## What changed

- `mc_rebase` (`bin/lib/mc/rebase.sh`) takes an optional arg 7. When it is
  `distinct`, the BH-8021 Mergify push refusal ("SKIP_PUSH mergify-queue")
  returns rc 9. Without arg 7, the refusal still returns rc 3. Only
  `br_regen_rung` passes `distinct`. The guard still never pushes while Mergify
  holds the PR.
- `br_regen_rung` (`bin/lib/br/ladder.sh`, rung 1b):
  - rc 9: records `regen-noop` on head8 and runs the fix round in the same
    tick, the same as rc 1/2.
  - rc 3: counts per head in `state/blocked-resolver/<project>/<cap-key>.regen-lease`
    (one line `<head40>\t<n>`). Ticks below `BR_REGEN_LEASE_TICKS` retry with
    no rung spent. At the bound, the rung records `regen-noop`, sends one warn
    alert (`br-regen-lease:<project>:<cap-key>:<head8>`) that names the PR, and
    runs the fix round. A new head restarts the count. Every answer except
    rc 3 and rc 7 removes the sidecar.
  - rc 7: unchanged (retry, no rung spent).
- New knob `BR_REGEN_LEASE_TICKS` (default 3, 0 = off),
  `catalog/lanes.d/blocked-resolver.knobs.d/BR_REGEN_LEASE_TICKS.json`.

## Why

The BH-8021 guard returned rc 3 when a Mergify queue check stood on the head.
The rung read rc 3 as a lease race and retried every tick. The refusal is
stable, so the fix round never ran (#9317, #8979, #9221, #9273 on
2026-11-08/09).

## How to check on a box

- `grep 'mc_rebase rc=9 (Mergify queue check' logs/blocked-resolver.log`
- `grep 'on this head)' logs/blocked-resolver.log` (the rc 3 count)
- `grep 'the regenerate rung stops retrying' logs/blocked-resolver.log`
- Suites: `tests/blocked-resolver.bh-9340-test.sh`, `tests/mc-rebase-mq-rc.bh-9340-test.sh`.
