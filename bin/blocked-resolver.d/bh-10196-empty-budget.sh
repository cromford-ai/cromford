# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10196-empty-budget.sh — BH-10196: an empty GitHub
# bucket stops the tick before its first read, or at the row after the rung
# that drained it.
#
# WHY. When the reading of the bucket this run spends from says remaining 0
# until a reset still ahead, every GET of the tick would be refused
# (bin/lib/gh-rest-empty.sh). A tick that acted on refused reads would stamp
# visits, acks and carries for rows it never saw.
#
# WHAT. The driver calls these, one line each:
#   brge_tick_stop
#       before discovery. rc 0 (and one `say` line) when the bucket of the
#       run's repo (ONLY set) or the default bucket reads empty. A --fix-here
#       round and the dispatcher are not ticks: rc 1 for them.
#   brge_row_empty <pr-url>
#       at the top of each candidate row. rc 0 when the bucket of the row's
#       repo reads empty: the driver ends the tick with reason gh-budget-empty,
#       and the rows after it are left as they are, like rows past a budget break.
# Both are rc 1 when gh_rest_budget_empty is not loaded (fail-open).
# Tests: tests/blocked-resolver-empty-budget.bh-10196-test.sh.

brge_tick_stop() {
  [ "${BR_FIX_HERE:-0}" != 1 ] && [ "${BR_DISPATCH:-0}" != 1 ] || return 1
  command -v gh_rest_budget_empty >/dev/null 2>&1 || return 1
  local path=""
  if [ -n "${ONLY:-}" ]; then
    path=$("$H/bin/fleet-conf.sh" "$ONLY" repo 2>/dev/null) || path=""
    case "$path" in */*) path="repos/$path" ;; *) path="" ;; esac
  fi
  gh_rest_budget_empty "$path" || return 1
  say "GitHub core budget empty — tick stopped before discovery; no park read, rung or hand-off claim"
  return 0
}

brge_row_empty() {
  command -v gh_rest_budget_empty >/dev/null 2>&1 || return 1
  local url="${1:--}" path=""
  case "$url" in https://github.com/*/*/pull/*) path="${url#https://github.com/}"; path="repos/${path%%/pull/*}" ;; esac
  gh_rest_budget_empty "$path"
}
