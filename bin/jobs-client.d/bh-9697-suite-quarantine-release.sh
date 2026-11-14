# shellcheck shell=bash
# bin/jobs-client.d/bh-9697-suite-quarantine-release.sh — BH-9697: release
# the active row after a green nightly on a newer
# main sha (POST /api/suite-quarantine/release). The answer {released: 0|1}
# is printed.
# Route: worker/jobs/src/routes/suite-quarantine.js.
# rc 0 = answered, 1 = empty argument, transport, 400 or not configured.
#: suite-quarantine-release <json>
jc_verb_suite_quarantine_release() {
  [ -n "${1:-}" ] || return 1
  local rc=0
  _jobs_req POST /api/suite-quarantine/release "$1" || rc=$?
  printf '\n'
  return "$rc"
}
