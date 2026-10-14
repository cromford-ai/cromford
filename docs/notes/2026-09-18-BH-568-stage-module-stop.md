# The stage-module presence check stops like F1

Doc: RUN-BUILD-GRAPH

The stage-module presence check stops the same way, and for the same reason. The
pipeline sources its stage modules from `bin/lib/rb/` a few lines below the
resume guard; if one of the seven is not readable on this box, the run writes one
ALERTS line naming the module and the host, and exits 2. There is no job row to
close and nothing to release, because the check sits ahead of every lock, claim
and worktree — nothing has been claimed yet. A missing module means the box's
`bin/` arrived in two pieces, and a half-synced pipeline must not build: it would
run some stages from the new tree and some from the old one, and the build that
came out would be nobody's code. One line to ALERTS and stop is the honest
answer, and the next sync makes the condition go away on its own. On a FRESH run
that stop writes no RESULT, exactly like F1. On a RESUMED one it writes
`BUILD_DEFERRED` first: the dir already exists, `bin/resume-dead-builds.sh`
re-enters any dir it finds with no RESULT in it, and a resume that exits silently
would be re-entered until the attempt cap killed it. `BUILD_DEFERRED` from a
resume is weather to the resumer (`bin/resume-dead-builds.sh`: a deferred verdict
on a dir with resume attempts on it clears the RESULT and refunds the attempt),
so a sync that is merely late costs the ticket nothing. The never-refunded
resume-total counter still backstops it: a box that stays half-synced converges
to `BUILD_DEAD` rather than relaunching forever.

**For a future suite author.** A suite that reads `bin/run-build.sh` as text
sources `tests/lib/rb-all.sh` and reads `$RB_ALL` (the flatten that puts every
stage-module body back at its call site) instead of the driver path;
`tests/rb-modules-source-test.sh` fails CI on any other reader.
`tests/queue-producers-test.sh` is the one exception, because it EXECUTES the
driver rather than reading it.
