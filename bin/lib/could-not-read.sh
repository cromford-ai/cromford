# shellcheck shell=bash
# bin/lib/could-not-read.sh — SOURCED, never executed. Defines functions only;
# nothing runs on source. BH-9594 (the BH-9555 contract, order 1 of 2).
#
# A FAILED READ IS NOT A FACT. A lane that reads GitHub and gets a 401, a 403,
# a 429, a 5xx or no answer at all did not learn that the board is empty, the
# PR is closed or the ticket needs nothing. It learned nothing. Before this lib
# the harness logged such a read and alerted, but it recorded nothing against
# the box, so no lane could tell a dead credential from a quiet board.
#
#   cnr_classify_status <http-status> <reason>
#       prints `could-not-read` or `decision`. could-not-read: status 401, 403,
#       429, 500, 502, 503, 504 or 000 (no status line: network, timeout, or a local
#       refusal), or reason rate-limit / auth-skipped with any status. decision:
#       200, 304, 404 (absent IS a fact, bin/orphan-reconcile.sh), 422 and every
#       other status, an empty one included. The reasons are the GH_REST_REASON
#       words of bin/lib/gh-rest.sh.
#   cnr_classify_text <skip-reason>
#       prints `could-not-read` or `decision` for a free-text reason. It matches
#       whole phrases, never a bare number: a status number must follow gh /
#       github / api / http within 20 characters with no `#` between, and must
#       not be followed by ` day`, ` days` or ` hour`. Plus `rate limit
#       exceeded`, `secondary rate limit`, `bad credentials` and `timed out
#       (reading|waiting for) [the] board|github|gh`. `waiting on PR #401`,
#       `asked 403 days ago`, `blocked by #500` and an empty reason are decision.
#   cnr_record <box> <project> <cred_class> <status|ok> [reason]
#       POSTs {box, project, cred_class, status, reason} to the jobs worker
#       route /api/box-read-failures (worker/jobs/src/routes/box-read-failures.js).
#       A failure status adds a box_read_failures row and +1 to
#       box_cred_health.consecutive; `ok` sets consecutive to 0. ALWAYS rc 0: a
#       failed POST prints one line and the caller goes on (fail toward retry,
#       the next run reads again). It prints at most one line, for the caller's
#       log:
#         cnr: recorded <cred_class> <status> for <box> (consecutive=N)
#         cnr: box_read_failures row not written (rc N)
#         cnr: <reason> is not a credential failure, not recorded
#         cnr: refused <field> '<value>', not recorded
#       Nothing at all when CNR_ENFORCE is 0 (the kill row
#       lib.could-not-read.cnr_enforce, catalog/lanes.d/_lib.could-not-read.json).
#       cred_class is one of gh-app gh-pat board-api jobs. box and project match
#       ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$: no dot, so a host address is never
#       stored. Reasons quota-reserve, bad-args and cache-miss are local
#       refusals of bin/lib/gh-rest.sh, not a fault of the box: not recorded.
#   cnr_box
#       prints this box's registry name: $BOX_NAME, else bin/box-name.sh.
#
# Doc: docs/GH-REST.md §17, docs/STATE-STORES.md (box_read_failures).

cnr_classify_status() {
  case "${2:-}" in rate-limit|auth-skipped) echo could-not-read; return 0 ;; esac
  case "${1:-}" in
    401|403|429|500|502|503|504|000) echo could-not-read ;;
    *) echo decision ;;
  esac
  return 0
}

cnr_classify_text() {
  local t pre num post
  t=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$t" in
    *"rate limit exceeded"*|*"secondary rate limit"*|*"bad credentials"*) echo could-not-read; return 0 ;;
  esac
  if [[ "$t" =~ timed\ out\ (reading|waiting\ for)\ (the\ )?(board|github|gh) ]]; then
    echo could-not-read; return 0
  fi
  if [[ "$t" =~ (^|[^a-z])(gh|github|api|http)([^#]{0,20})(401|403|429|5[0-9][0-9])([^0-9].*)?$ ]]; then
    pre="${BASH_REMATCH[3]}" num="${BASH_REMATCH[4]}" post="${BASH_REMATCH[5]}"
    # The number is whole: no digit right before it (1401 is not 401).
    case "$pre" in *[0-9]) num="" ;; esac
    case "$post" in " day"*|" hour"*) num="" ;; esac
    [ -n "$num" ] && { echo could-not-read; return 0; }
  fi
  echo decision
  return 0
}

# _cnr_root — the harness root: $HARNESS, else $H, else two levels above this
# file (no literal root fallback, BH-2613).
_cnr_root() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || h=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)
  printf '%s' "$h"
}

cnr_box() {
  if [ -n "${BOX_NAME:-}" ]; then printf '%s\n' "$BOX_NAME"; return 0; fi
  "$(_cnr_root)/bin/box-name.sh" 2>/dev/null || true
}

cnr_record() {
  local box="${1:-}" project="${2:-}" cred="${3:-}" st="${4:-}" reason="${5:-}" body out rc n
  [ "${CNR_ENFORCE:-1}" = 0 ] && return 0
  local name_re='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
  [[ "$box" =~ $name_re ]] || { echo "cnr: refused box '$box', not recorded"; return 0; }
  [[ "$project" =~ $name_re ]] || { echo "cnr: refused project '$project', not recorded"; return 0; }
  case "$cred" in gh-app|gh-pat|board-api|jobs) ;; *) echo "cnr: refused cred_class '$cred', not recorded"; return 0 ;; esac
  [[ "$st" =~ ^(ok|[0-9]{3})$ ]] || { echo "cnr: refused status '$st', not recorded"; return 0; }
  case "$reason" in
    quota-reserve|bad-args|cache-miss) echo "cnr: $reason is not a credential failure, not recorded"; return 0 ;;
  esac
  if ! command -v _jobs_req >/dev/null 2>&1; then
    # shellcheck source=bin/jobs-client.sh
    . "$(_cnr_root)/bin/jobs-client.sh" 2>/dev/null || true
  fi
  command -v _jobs_req >/dev/null 2>&1 || { echo "cnr: box_read_failures row not written (rc 127)"; return 0; }
  body=$(jq -nc --arg b "$box" --arg p "$project" --arg c "$cred" --arg s "$st" --arg r "${reason:0:200}" \
    '{box: $b, project: $p, cred_class: $c, status: $s, reason: $r}' 2>/dev/null) \
    || { echo "cnr: box_read_failures row not written (rc 127)"; return 0; }
  rc=0
  out=$(_jobs_req POST /api/box-read-failures "$body" 2>/dev/null) || rc=$?
  if [ "$rc" != 0 ]; then echo "cnr: box_read_failures row not written (rc $rc)"; return 0; fi
  n=$(jq -r 'if (.consecutive | type) == "number" then .consecutive else empty end' <<<"$out" 2>/dev/null)
  if [ -z "$n" ]; then echo "cnr: box_read_failures row not written (rc 0, no consecutive in the answer)"; return 0; fi
  echo "cnr: recorded $cred $st for $box (consecutive=$n)"
  return 0
}
