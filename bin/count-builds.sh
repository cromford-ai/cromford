#!/bin/bash
# Count REAL running build pipelines for a project (arg 1) or all projects.
#
# Exists because `pgrep -fc "run-build.sh"` self-matches any agent session whose
# prompt text quotes the script path (claude/codex argv contains the prompt),
# which reported phantom builds and starved every slot (project-3, 2026-07-26).
# Anchoring to the interpreter+script prefix matches only actual processes:
#   /bin/bash /root/harness/bin/run-build.sh <project> <ticket> <key>
# An agent's cmdline starts with the runner binary, a poller's with "/bin/bash -c",
# so neither can match the anchor.
#
# BUILDS, NOT PROCESSES (2026-09-11, project-5). This counted `pgrep -fc`, i.e.
# matching PROCESSES, and run-build.sh forks a subshell that keeps the same
# argv — so one running build has always shown up as TWO. A box with
# flags/build-slots=2 read "2/2" with a single TK-267 build and refused to
# launch TK-268/269/270; it was unblocked by hand with build-slots=10, which is
# the same lie pointing the other way. The unit of work is the argv tuple
# `<project> <ticket> <key>`, so that tuple is what gets counted, once, however
# many processes the pipeline happens to have forked.
#
# `ps` rather than `pgrep` because the identity is in the ARGUMENTS, not in the
# match — and because a process table can then be replayed from a fixture, which
# is how tests/free-slots-test.sh drives both the counting and the anchor.
# EXCLUDE (arg 2, optional): a ticket key left out of the count. The WIP gate
# in bin/lib/rb/gates.sh runs INSIDE run-build.sh, so without it the asking
# build counted itself and flags/wip-limit-<p> = 1 deferred every non-hotfix
# local build (project-6-desktop, 2026-10-27 to 2026-11-06).
P="${1:-}"; X="${2:-}"
ps -ww -eo args= 2>/dev/null | awk -v want="$P" -v skip="$X" '
  # THE ANCHOR, unchanged in substance: argv[0] is a bash, argv[1] is the script
  # itself. An agent quoting the path carries its runner at argv[0]; a poller
  # carries "-c" at argv[1]. Neither can reach the body. The harness root is not
  # pinned — a pipeline is a pipeline wherever the tree lives — but the path
  # must END at bin/run-build.sh, so a .bak or a lookalike does not count.
  $1 ~ /(^|\/)bash$/ && $2 ~ /(^|\/)bin\/run-build\.sh$/ {
    if (want != "" && $3 != want) next
    if (skip != "" && $5 == skip) next
    id = $3 SUBSEP $4 SUBSEP $5
    if (!(id in seen)) { seen[id] = 1; n++ }
  }
  END { print n+0 }
'
