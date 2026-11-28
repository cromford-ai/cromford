# shellcheck shell=bash
# bin/lib/cnr-retry.sh — SOURCED, never executed. The retry seam of the
# could-not-read contract (BH-9594). # owner: BH-9555.3 (BH-10453)
#
# cnr_retry <budget_s> <cmd...>
#   Runs <cmd...> in the CURRENT shell, never in a `$( )` or a pipe, so the
#   GH_REST_STATUS / GH_REST_REASON a bin/lib/gh-rest.sh helper sets stay
#   readable by the caller after the call. Returns the LAST attempt's rc
#   verbatim. A caller's redirect (`cnr_retry "" gh_rest_issue_list ... > f`)
#   covers every attempt.
#
#   It runs the command again only when the attempt failed AND
#   cnr_classify_status (bin/lib/could-not-read.sh) calls its GH_REST_STATUS /
#   GH_REST_REASON `could-not-read` (401, 403, 429, 5xx, 000, rate-limit). A
#   decision (200, 404, 422, an empty status) is returned at once. The local
#   refusals of bin/lib/gh-rest.sh (quota-reserve, bad-args, cache-miss) are
#   not a fault of the box and are never retried.
#
#   Backoff 2, 4, 8 s, and a step is taken only while elapsed + step fits the
#   budget. elapsed is the larger of the wall time and the seconds slept.
#   <budget_s>: a whole number, else (empty or not a number) the knob
#   CNR_RETRY_BUDGET_S. The knob: the env value, else the row
#   lib.could-not-read.cnr_retry_budget_s through lib_env_apply (resolved once
#   a shell, in a subshell, and only on the first could-not-read), else 20.
#   Clamped to 0..120. 0 = one read, as before BH-9555.3.
#
#   Kill row: CNR_ENFORCE=0 (lib.could-not-read.cnr_enforce) = one read.
#
# _cnr_sleep <s> is the test seam around sleep.
# cnr_enforce_resolve [project] prints CNR_ENFORCE (0 or 1) and sets it in the
#   caller's shell when it was unset: the env value, else the row through
#   lib_env_apply in a subshell (the bin/orphan-reconcile.sh shape, so a
#   fail-closed exit there never stops the caller), else 1.

_CNR_RETRY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
if ! command -v cnr_classify_status >/dev/null 2>&1 && [ -r "$_CNR_RETRY_LIB_DIR/could-not-read.sh" ]; then
  # shellcheck source=bin/lib/could-not-read.sh
  . "$_CNR_RETRY_LIB_DIR/could-not-read.sh"
fi

_cnr_sleep() { sleep "${1:-0}"; }

# _cnr_lane_gate — the lane-gate.sh of this harness: $HARNESS, else $H, else
# the lib's own tree.
_cnr_lane_gate() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || r=$(cd "$_CNR_RETRY_LIB_DIR/../.." 2>/dev/null && pwd)
  printf '%s/bin/lib/lane-gate.sh' "$r"
}

cnr_enforce_resolve() {
  local v
  if [ -z "${CNR_ENFORCE:-}" ]; then
    v=$(
      exec 3>&1
      trap 'printf "%s" "${CNR_ENFORCE:-}" >&3' EXIT
      command -v lib_env_apply >/dev/null 2>&1 || . "$(_cnr_lane_gate)" >/dev/null 2>&1 || exit 0
      lib_env_apply could-not-read "${1:-${PROJECT:-}}" >/dev/null 2>&1)
    case "$v" in 0|1) ;; *) v=1 ;; esac
    CNR_ENFORCE="$v"
  fi
  printf '%s\n' "$CNR_ENFORCE"
}

# _cnr_budget <arg> — sets _CNR_BUDGET to the budget in whole seconds, 0..120.
# Current shell, so the once-a-shell knob read is cached.
_cnr_budget() {
  local b="${1:-}"
  case "$b" in ''|*[!0-9]*) b="${CNR_RETRY_BUDGET_S:-}" ;; esac
  case "$b" in
    '')
      if [ -z "${_CNR_RETRY_BUDGET_RESOLVED:-}" ]; then
        _CNR_RETRY_BUDGET_RESOLVED=$(
          exec 3>&1
          trap 'printf "%s" "${CNR_RETRY_BUDGET_S:-}" >&3' EXIT
          command -v lib_env_apply >/dev/null 2>&1 || . "$(_cnr_lane_gate)" >/dev/null 2>&1 || exit 0
          lib_env_apply could-not-read "${PROJECT:-}" >/dev/null 2>&1)
        # Code fallback 20 = the seeded row lib.could-not-read.cnr_retry_budget_s
        # (catalog/lanes.d/_lib.could-not-read.knobs.d/CNR_RETRY_BUDGET_S.json).
        case "$_CNR_RETRY_BUDGET_RESOLVED" in ''|*[!0-9]*) _CNR_RETRY_BUDGET_RESOLVED=20 ;; esac
      fi
      b="$_CNR_RETRY_BUDGET_RESOLVED" ;;
    *[!0-9]*) b=20 ;;
  esac
  b=$((10#$b))
  [ "$b" -gt 120 ] && b=120
  _CNR_BUDGET="$b"
}

cnr_retry() {
  local _cnr_arg="${1:-}" _cnr_rc _cnr_b="" _cnr_t0=$SECONDS _cnr_slept=0 _cnr_el _cnr_step _cnr_steps="2 4 8"
  shift
  while :; do
    _cnr_rc=0
    "$@" || _cnr_rc=$?
    [ "$_cnr_rc" = 0 ] && return 0
    command -v cnr_classify_status >/dev/null 2>&1 || return "$_cnr_rc"
    case "${GH_REST_REASON:-}" in quota-reserve|bad-args|cache-miss) return "$_cnr_rc" ;; esac
    [ "$(cnr_classify_status "${GH_REST_STATUS:-}" "${GH_REST_REASON:-}")" = could-not-read ] || return "$_cnr_rc"
    cnr_enforce_resolve >/dev/null
    [ "$CNR_ENFORCE" = 0 ] && return "$_cnr_rc"
    [ -n "$_cnr_b" ] || { _cnr_budget "$_cnr_arg"; _cnr_b="$_CNR_BUDGET"; }
    [ -n "$_cnr_steps" ] || return "$_cnr_rc"
    _cnr_step="${_cnr_steps%% *}"
    case "$_cnr_steps" in *" "*) _cnr_steps="${_cnr_steps#* }" ;; *) _cnr_steps="" ;; esac
    _cnr_el=$((SECONDS - _cnr_t0)); [ "$_cnr_slept" -gt "$_cnr_el" ] && _cnr_el=$_cnr_slept
    [ $((_cnr_el + _cnr_step)) -gt "$_cnr_b" ] && return "$_cnr_rc"
    _cnr_sleep "$_cnr_step"
    _cnr_slept=$((_cnr_slept + _cnr_step))
  done
}
