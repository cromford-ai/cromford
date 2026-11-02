# Stage-module seam (the driver sources `bin/lib/rb/`)

**What it is:** `bin/run-build.sh` is being split into stage modules under
`bin/lib/rb/` (BH-478). This part is the seam only: the driver names the seven
modules on one literal line, sources them in that order, and refuses to build on
a box where one of them is missing. Nothing calls into a module yet, so a build
runs the same pipeline it ran before plus seven no-op sources.

**How a user reaches it:** there is no screen and no cron line of its own. The
block runs at the top of every build, right after the RESULT ratchet — look for
`# >>> stage modules` in `bin/run-build.sh`. Every caller of the driver reaches
it: the triage tick (`bin/run-triage.sh`), the resumer
(`bin/resume-dead-builds.sh`), and the Fly pool runner (`fly/builder-runner.sh`).

**Key routes/screens:**
- `bin/run-build.sh`, the `# >>> stage modules` … `# <<< stage modules` block —
  the loop itself
- `bin/lib/rb/{gates,plan,execute,spec,review,pr,result}.sh` — the seven modules
  (header comments today; the bodies land in the later parts of BH-478)
- `tests/lib/rb-all.sh` — sourced by the suites that READ the driver; flattens
  module bodies back into their call sites so the text they read is the pipeline
  in its original order at every state of the split

**Selectors:** none (no UI). The block is addressed by its markers:
`awk '/^# >>> stage modules/{f=1;next} /^# <<< stage modules/{exit} f' bin/run-build.sh`.

**Preconditions / seed needs:** a `$HARNESS` tree with `bin/lib/rb/*.sh` in it.
`bin/harness-sync.sh` (rsync of `bin/`) and `bin/fly-sync-harness.sh` (tar of
`bin/`) carry the directory with no change, and `bin/` is a fleet path, so
`bin/fleet-propagate.sh` lands it on every box within five minutes of a merge.
That five-minute window is exactly the condition this check exists to cover.

**Verify it works:** `HARNESS_TEST_SANDBOX=1 bash tests/rb-modules-source-test.sh`
lifts the block out of the real driver and executes it against a scratch harness.
Whole tree: rc 0, no output, no ALERTS line, no RESULT. One module removed: rc 2
and exactly one ALERTS line naming the module and the host. The same miss with
`RESUME_BUILD` set also writes `BUILD_DEFERRED …` to `$BUILD/RESULT`, because
`bin/resume-dead-builds.sh` re-enters any dir it finds with no RESULT in it.

A suite that reads `bin/run-build.sh` as text sources `tests/lib/rb-all.sh` and
reads `$RB_ALL` instead of the driver path; `tests/rb-modules-source-test.sh`
fails CI on any other reader (`tests/queue-producers-test.sh` is the one
exception — it executes the driver rather than reading it).

On a live box the only visible artifact is that line:
`grep 'stage module' /root/harness/logs/ALERTS.log`. An empty result is the
normal state — it means no build has met a half-synced `bin/`.

**Gate fragments (`bin/lib/rb/gates.d/`, BH-8930):** a gate of `gates.sh` can
live in its own file, `bin/lib/rb/gates.d/<slug>.sh`, holding one verbatim marked
block. Its call site is one column-0 line `. "$RB_GATES_D/<slug>.sh"` in place of
the block. `rb_gates_d_check`, the first statement of `rb_gate_prelude`, reads
the call sites off `gates.sh` and defers the build (`BUILD_DEFERRED gates.d/<slug>.sh
missing on <host>`, rc 3, one critical lane-alert `rb-gates-d-missing-<host>`)
when a named fragment is missing. `tests/lib/rb-all.sh` expands each call line
back into its block. Moved so far: `hotfix detect` and `disk gate`. Verify:
`HARNESS_TEST_SANDBOX=1 bash tests/rb-gates-fragments.bh-8930-test.sh`.

**Manual-only / not automatable:** the real half-synced box. Nothing here may
interrupt a live `bin/harness-sync.sh` mid-flight to produce one, so the
condition is only ever driven in the scratch tree above.
