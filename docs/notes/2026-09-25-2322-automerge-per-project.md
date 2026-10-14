# The Project page's auto-merge toggle turns off one board, not the fleet

Doc: MERGE-CONDUCTOR

## What changed

#2322. The console's Project page shows AUTOMERGE as a per-project toggle and
sends `automerge_off` / `automerge_on` with `commands.project` set to that
board. The dashboard KILL button and chat `/kill` send the same types with the
project `all`. `bin/poll-commands.sh` ignored the project and wrote the
fleet-wide `automerge-disabled` for both, so one board's toggle stopped
auto-merge everywhere, and the flags beat then reported `automerge=false` for
every board.

The handler now follows the command's project:

| project | flag written | meaning |
|---|---|---|
| `all`, empty or `null` | `automerge-disabled` | the fleet kill switch, unchanged |
| a fleet.conf project `<p>` | `automerge-disabled-<p>` | auto-merge off for that board only |
| anything else | nothing | `refused: unknown project` (terminal) |
| fleet.conf could not be read | nothing | `auto-merge not changed: …; retry` (retryable, never `refused:`, per BH-2009) |

Turning a board back ON never clears the fleet switch. If the fleet switch is
still on, the ack says so.

The flags beat reconciles `automerge-disabled-<p>` for every registry project
and reports `automerge=false` for a board when either the fleet switch or its
own flag is on.

## Who reads `automerge-disabled-<p>`

Every lane that merges, or enqueues a merge, for one project at a time now reads
the project flag next to the fleet one, through `flag_active` when the jobs
client is loaded and the file otherwise:

| lane | effect of the project flag |
|---|---|
| `bin/review-prs.sh` (`hold_automerge_disabled`) | the APPROVE is left unmerged, silently, the same as the fleet switch |
| `bin/lib/rb/pr.sh` (build tier-1 gate) | demoted to tier 2 with a pipeline.log line |
| `bin/merge-queue.sh` | stands down for that project: `flags/automerge-disabled-<p> is on` |
| `bin/lander.sh` | exits 1 before anything is written |
| `bin/lib/tier2-autoenqueue.sh` | a `WOULD` line naming the flag, nothing enqueued |
| `bin/batch-resolve.sh` | does nothing for that project |
| the merge sweep | per PR, before the merges-pause guard: skipped, retryable, nothing recorded |
| `bin/merge-conductor.sh` | `MERGES=0` inside that project's `tick_project` subshell, like a project merges pause. The fleet switch still owns `KILL` |

The fleet switch alone still stops the lanes that do not merge: the rebase
trains, blocked-resolver's observe mode and the conductor's provenance
auto-resolve. A board with auto-merge off keeps its branches rebased, so its
PRs are ready to land when the toggle comes back on.

Tests: `tests/automerge-scope.bh-2322-test.sh`.
