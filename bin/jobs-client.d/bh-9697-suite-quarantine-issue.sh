# shellcheck shell=bash
# bin/jobs-client.d/bh-9697-suite-quarantine-issue.sh — BH-9697: set the
# repair ticket number once on the active row
# (POST /api/suite-quarantine/issue). The answer {updated: 0|1} is printed.
# Route: worker/jobs/src/routes/suite-quarantine.js.
# rc 0 = answered, 1 = empty argument, transport, 400 or not configured.
#: suite-quarantine-issue <json>
jc_verb_suite_quarantine_issue() {
  [ -n "${1:-}" ] || return 1
  local rc=0
  _jobs_req POST /api/suite-quarantine/issue "$1" || rc=$?
  printf '\n'
  return "$rc"
}
