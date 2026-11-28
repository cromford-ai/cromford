# shellcheck shell=bash
# bin/lib/cnr-retry.sh — SOURCED, never executed. The retry seam of the
# could-not-read contract (BH-9594). # owner: BH-9555.3
#
# cnr_retry <budget_s> <cmd...>
#   Runs <cmd...> in the CURRENT shell, never in a `$( )` or a pipe, so the
#   GH_REST_STATUS / GH_REST_REASON a bin/lib/gh-rest.sh helper sets stay
#   readable by the caller after the call. Returns the command's rc verbatim.
#   A caller's redirect (`cnr_retry "" gh_rest_issue_list ... > f`) covers
#   every attempt. An empty <budget_s> means "the lib's own knob"
#   (CNR_RETRY_BUDGET_S, owned by BH-9555.3).
#
# THIS IS THE PLACEHOLDER: it runs the command once and ignores the budget, so
# every caller behaves as before. BH-9555.3 replaces the body with the
# backoff (retry only when cnr_classify_status says could-not-read) and edits
# no caller.
cnr_retry() {
  shift
  "$@"
}
