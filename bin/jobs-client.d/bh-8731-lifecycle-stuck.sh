# shellcheck shell=bash
# bin/jobs-client.d/bh-8731-lifecycle-stuck.sh — BH-8731: the tickets past
# their lifecycle.stuck.<phase>_min threshold (bin/lib/jobs/lifecycle.sh
# lifecycle_stuck). rc as lifecycle-transition.
#: lifecycle-stuck [project]
jc_verb_lifecycle_stuck() {
  # shellcheck source=bin/lib/jobs/lifecycle.sh
  . "$(dirname "${BASH_SOURCE[0]}")/../lib/jobs/lifecycle.sh" || return 1
  local rc
  lifecycle_stuck "$@"; rc=$?
  case "$rc" in 0|9) echo ;; esac
  return "$rc"
}
