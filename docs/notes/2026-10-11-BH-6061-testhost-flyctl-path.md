# testhost-tick finds flyctl under cron, and alerts on an unknown streak (BH-6061)

Doc: REMOTE-GATE

## What changed

- New `bin/lib/fly-bin.sh`: `fly_bin` prints the path of flyctl. It looks in
  PATH first (`flyctl`, then `fly`), then `$FLYCTL_INSTALL/bin`,
  `$HOME/.fly/bin` and `/root/.fly/bin`. It returns rc 127 when none exists.
- `bin/testhost-tick.sh` `_th_fly` uses `fly_bin`. Before, it ran
  `command -v flyctl || return 127` BEFORE it put `/root/.fly/bin` on PATH.
  Cron's PATH is `/usr/bin:/bin`, so every Fly call from cron returned 127.
  Every tick read `state=unknown` and logged "nothing to stop" for 13 days
  (`idle=1138100s`). The BH-1597 disk check was dark for the same reason.
- Each unknown state now has a cause (`flyctl not found`, `auth failure: …`,
  `no machine id: …`, `API error: …`, `no State: line`). The first output line
  is cut to 120 characters, with token shapes replaced by `[redacted]`.
- A streak of unknown ticks is counted in
  `state/testhost-tick/unknown-streak` (`<count> <fired> <cause>`). At
  `TESTHOST_UNKNOWN_ALERT_TICKS` (new knob, default 3) one
  `testhost-state-unknown` alert (warn) names the count and the cause. A tick
  that reads a real state resolves it and removes the file.
- New read-only verb `bin/testhost-tick.sh idle [<machine-id>]`. It prints the
  idle seconds (now minus `testhost.last_used`), `0` when the machine says it
  is busy, or `unknown` with rc 2. It writes nothing. `bin/fly-idle-reaper.sh`
  uses it as the testhost idle signal.

## Tests

`tests/testhost-tick-cron-path.bh-6061-test.sh` (T1 is the reproduction: on
the old code `state` printed `unknown` under `env -i PATH=/usr/bin:/bin`).
Four older suites copied the tick into a scratch tree with a hand lib list.
They now use `scratch_install_closure`, so the new lib comes with the script.
