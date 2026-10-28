# shellcheck shell=bash
# bin/jobs-client.d/bh-8731-lifecycle-transition.sh — BH-8731: move one
# ticket's lifecycle phase (bin/lib/jobs/lifecycle.sh lifecycle_transition).
# rc 0 = moved, 9 = refused (409, the body says why), 2 = no such row,
# 1 = transport or not configured, 3 = bad arguments.
#: lifecycle-transition <project> <ticket_key> <to_phase> <actor> <reason> [pr] [question]
jc_verb_lifecycle_transition() {
  # shellcheck source=bin/lib/jobs/lifecycle.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../lib/jobs/lifecycle.sh" || return 1
  local rc
  lifecycle_transition "$@"; rc=$?
  case "$rc" in 0|9) echo ;; esac
  return "$rc"
}
