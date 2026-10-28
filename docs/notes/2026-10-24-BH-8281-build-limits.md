# Build sessions run with CARGO_BUILD_JOBS capped and a lower CPU priority (BH-8281)

Doc: OPERATING, FLY-POOL

## What changed

On 2026-10-24 box-project-6-os-1 (10.0.0.14) reached load 92. From 11:20Z
to 18:14Z the hub could not ssh to it. The project-6-os pool logged
`env bundle FAILED … ssh env extract from 10.0.0.14 failed (ssh rc 255)` on
every tick, and no project-6 build started for 7 hours. The box had just taken
the project-6-desktop cargo build.

- `bin/lib/build-limits.sh` (`bl_apply <harness> <project>`) exports
  `CARGO_BUILD_JOBS` and renices the calling shell. Children inherit both.
  - `CARGO_BUILD_JOBS` comes from knob `BUILD_CARGO_JOBS` (default 0 = half
    the cores, at least 1). A `CARGO_BUILD_JOBS` that is already set wins.
  - The niceness comes from knob `BUILD_NICE` (default 10, 0 = off). The lib
    only lowers priority. It never raises it.
  - One stderr line says what it applied, read back after the renice:
    `build-limits: <project> CARGO_BUILD_JOBS=<n> nice=<n>`.
- `bin/run-build.sh` calls it right after the env load, so a project env
  file can set `CARGO_BUILD_JOBS` itself.
- `bin/fix-round-claim.sh` runs each fix round in a subshell that calls it, so
  the claim runner keeps its own priority. The line goes to
  `logs/fix-round-claim.log`.
- The `ptn_note` alert (`bin/lib/pool-tailnet.sh`) now says
  `tailnet unreachable or box overloaded` and tells the operator to check the
  load (`uptime`, `ps`) after tailscaled. The trigger is 3 failures inside
  `POOL_TAILNET_WINDOW_S`, one line per episode.
- Fix round 1 (lead review of 042b0fa4d): the window default is now 1800 s,
  not 900 s. The pool tick runs every 10 min
  (`cron/lanes/240-fly-pool-tick.cron`). With one queued row, 3 failed ticks
  land at 0, 600 and 1200 s, and a 900 s window held only 2 of them, so the
  "3 ticks in a row" alert never fired. The fly-pool knob row, the
  box-ssh-probe row and both script fallbacks change together (the probe row
  says to keep them the same). A settings row already set on the hub
  overrides the new default; check `lane.fly-pool.pool_tailnet_window_s`.

## Knobs

Both are lib knobs in `catalog/lanes.d/_lib.build-limits.json`. To set one
project tighter, put a row:

    PUT /api/settings lib.build-limits.project-6-desktop.build_cargo_jobs = 2

## Not done here

- No cgroup memory cap (`systemd-run -p MemoryMax=`). Fewer rustc jobs is what
  lowers peak memory.
- No move of project-6-desktop to another box or to a Fly builder. Those are
  `bin/registry.sh` and routing rows, an operator decision.
