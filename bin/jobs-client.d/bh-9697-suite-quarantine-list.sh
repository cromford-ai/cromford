# shellcheck shell=bash
# bin/jobs-client.d/bh-9697-suite-quarantine-list.sh — BH-9697: the active
# quarantine rows of one repo (GET /api/suite-quarantine?status=active,
# worker/jobs/src/routes/suite-quarantine.js). Prints one line per row:
#   suite<TAB>repair_issue or -<TAB>main_sha_red<TAB>created_at
# An empty list prints nothing and is rc 0. rc 1 = empty argument, any request
# failure, a body that is not JSON with a .rows array, or a list the worker
# cut at suite_quarantine.list_max (.truncated true; then nothing prints).
#: suite-quarantine-list <repo>
jc_verb_suite_quarantine_list() {
  [ -n "${1:-}" ] || return 1
  local enc body out
  enc=$(jq -rn --arg r "$1" '$r|@uri') || return 1
  body=$(_jobs_req GET "/api/suite-quarantine?repo=${enc}&status=active") || return 1
  out=$(printf '%s' "$body" | jq -r '
    if (type == "object") and ((.rows | type) == "array") and (.truncated != true) then
      .rows[] | [.suite, (if .repair_issue == null then "-" else (.repair_issue | tostring) end), .main_sha_red, .created_at] | @tsv
    else error("no rows array, or truncated") end' 2>/dev/null) || return 1
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}
