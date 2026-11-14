# shellcheck shell=bash
# bin/jobs-client.d/bh-9697-suite-quarantine-put.sh — BH-9697: quarantine one
# suite that is red on main and not changed by the diff (POST
# /api/suite-quarantine, worker/jobs/src/routes/suite-quarantine.js). A suite
# that already has an active row keeps it. The answer {row, created} is printed.
# rc 0 = written or already active, 1 = empty argument, transport, 400 or not
# configured.
#: suite-quarantine-put <json>
jc_verb_suite_quarantine_put() {
  [ -n "${1:-}" ] || return 1
  local rc=0
  _jobs_req POST /api/suite-quarantine "$1" || rc=$?
  printf '\n'
  return "$rc"
}
