# shellcheck shell=bash
# bin/merge-conductor.d/bh-8327-prequeue-group.sh - ONE PREQUEUE GATE RUN PER
# MAIN SHA FOR A GROUP OF READY HEADS (BH-8327). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block).
#
# mc_pq_group_tick_end <slug> — tick_project calls it once per project, after
# the PR workers and fanin_end. The READY heads that joined a group in those
# workers get ONE prequeue-group-gate.yml run per (repo, main) through
# pq_group_flush (bin/lib/mc-prequeue.d/group.sh, sourced by
# bin/lib/mc-prequeue.sh). No open group: no call. No lib: no-op.
mc_pq_group_tick_end() {
  declare -F pq_group_flush >/dev/null 2>&1 || return 0
  pq_group_flush "$1"
  return 0
}
