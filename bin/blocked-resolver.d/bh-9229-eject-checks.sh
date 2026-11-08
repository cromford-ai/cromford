# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9229-eject-checks.sh — BH-9229: a queue-ejected-twice
# park whose ejection cause names failing checks goes to the fix round, and
# the fix round's brief names those checks.
#
# WHY. On 2026-11-08 #9189 was parked queue-ejected-twice after a CHECKS_FAILED
# dequeue. No eject-runs file answered (br_eject_runs), so the ladder took
# `regen`, which merges main and re-runs the PR's own checks. That cannot fix
# a check that fails in the batch build.
#
# WHAT. The conductor writes one eject-cause record line per ejection
# (bin/lib/mc-eject-cause.sh ec_record, $MC_STATE_DIR/eject-cause/<owner_repo>_<num>).
# When the newest line for the row head has cause `checks` and names checks,
# the resolver has the evidence it needs for a fix round. Two call sites in
# bin/blocked-resolver.sh, each `command -v` guarded:
#   br_one        block `ejected twice: fix round first`: brec_checks is an OR
#                 beside br_eject_runs.
#   br_fix_round  block `eject runs brief`: brec_brief adds the check names.
# These functions read one local file and write nothing.
#
# Kill switch: BR_OPT_OFF=bh-9229-eject-checks (the ladder runs as before).

# brec_checks <pr-url> [<head>] — prints the failing checks of the newest
#   eject-cause record line for head (default: the conductor row's head,
#   mc_row_field field 4). rc 0 only when that line's cause is `checks` and its
#   detail is not empty; rc 1 otherwise (no MC_STATE_DIR, bad URL, no record,
#   no line for this head, another cause).
brec_checks() {
  local u="${1:-}" h="${2:-}" slug num f l c d
  case "$u" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  u="${u#https://github.com/}"; slug="${u%/pull/*}"; num="${u##*/}"
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  # The driver does not source the eject-cause lib; load it from this repo.
  if ! command -v _ec_find >/dev/null 2>&1; then
    # shellcheck source=bin/lib/mc-eject-cause.sh
    . "${BASH_SOURCE[0]%/*}/../lib/mc-eject-cause.sh" 2>/dev/null || return 1
  fi
  command -v _ec_find >/dev/null 2>&1 && command -v ec_file >/dev/null 2>&1 || return 1
  if [ -z "$h" ] && command -v mc_row_field >/dev/null 2>&1; then
    h=$(mc_row_field "$slug#$num" 4 2>/dev/null)
  fi
  [ "${#h}" -ge 7 ] || return 1
  f=$(ec_file "$slug" "$num") || return 1
  l=$(_ec_find "$f" "$h"); [ -n "$l" ] || return 1
  IFS=$'\t' read -r _ _ _ c d <<<"$l"
  [ "$c" = checks ] && [ -n "$d" ] || return 1
  printf '%s\n' "$d"
}

# brec_brief <pr-url> [<head>] — the fix-round brief paragraph that names the
#   failing checks, or nothing when brec_checks does not answer.
brec_brief() {
  local names
  names=$(brec_checks "$@") || return 0
  printf '\n\nTHE MERGE QUEUE NAMED THESE FAILING CHECKS ON THIS HEAD: %s. Make them pass against current main.' "$names"
}
