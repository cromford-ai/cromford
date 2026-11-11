# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9369-one-pr-lock.sh — BH-9369 fix 6: the sweep
# leaves a PR alone while a one-PR run holds it.
#
# WHY. A BR_ONLY_PR run (the conductor's mc_eject_fix_now, BH-6000) took the
# project lock and exited while the project's sweep ran, which can be an hour.
# It now takes locks/blocked-resolver-<project>-pr-<n>.lock (the driver's lock
# block, which runs before this file is sourced), so it runs beside the sweep.
# A BR_ONLY_PR that is not <owner>/<repo>#<n>, or one with no project, exits 2
# there: before, it matched 0 rows in silence. The sweep skips a held PR's rows
# (bop_sweep_skip) while the one-PR run scans; the per-key lock is what keeps
# two runs off one rung once the one-PR run's fix round has begun.
#
# Call site, one line in the driver's rung loop, after the DONE_KEYS dedupe.
# BR_OPT_OFF=bh-9369-one-pr-lock does not source this file: the sweep then
# dispatches every row, and the per-key lock stays the hard guard.

# bop_pr_held <project> <url> — rc 0 and $_BOP_N (the PR number) when <url> is
#   a PR url and locks/blocked-resolver-<project>-pr-<n>.lock is held now. The
#   probe opens the lock on its own fd in a subshell and releases it at once.
#   An absent lock file is not created; a free one (a finished run) is not held.
bop_pr_held() {
  local p="${1:-}" url="${2:-}" f
  _BOP_N=""
  [ -n "$p" ] && [ "$p" != "-" ] || return 1
  [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)$ ]] || return 1
  f="$H/locks/blocked-resolver-$p-pr-${BASH_REMATCH[1]}.lock"
  [ -e "$f" ] || return 1
  ( exec 7<"$f" && flock -n 7 ) 2>/dev/null && return 1
  _BOP_N="${BASH_REMATCH[1]}"
  return 0
}

# bop_sweep_skip — the rung loop's one call, per row of a sweep (never in a
#   one-PR run). rc 0 when this row's PR is held by a one-PR run: the line
#   `skip: one-PR run holds <n>` is said, the hand-off claim is acked
#   lock-held, and the loop goes on to the next row. It reads the loop's row
#   (P RKEY URL TKEY) and BHW_ON as the driver's globals.
bop_sweep_skip() {
  bop_pr_held "${P:-}" "${URL:-}" || return 1
  say "$P/$RKEY: skip: one-PR run holds $_BOP_N"
  [ "${BHW_ON:-0}" = 1 ] && bhw_ack "$P" "${TKEY:--}" "${URL:--}" lock-held
  return 0
}
