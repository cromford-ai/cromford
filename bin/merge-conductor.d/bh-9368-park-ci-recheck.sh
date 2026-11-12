# shellcheck shell=bash
# bin/merge-conductor.d/bh-9368-park-ci-recheck.sh - A PARK WHOSE CI IS GREEN
# AGAIN IS RELEASED (BH-9368, comment 6754703346). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block).
#
# Incident (project-6 #3700, #3728): a RED_TWICE row stayed parked after its
# CI went green. The tick read its CI word from the read memo (15 min, and kept
# for as long as nothing on the row changes), and the BH-8012 net reads one
# check-runs page of 100, which a project-6 head overflows. So nothing read the
# green, and bin/blocked-resolver.sh spent its ladder on a green head.
#
# mc_park_ci_recheck — pr_worker calls it right before mc_handoff_sticky, with
# pr_worker's KEY, HEAD, SLUG, PROVIDER and URL in scope. It acts only when the
# stored row is on this HEAD and is RED_TWICE, WAIT_MIGRATION, or BLOCKED_HUMAN
# with a `red-twice*` reason. Then, at most once per MC_STICKY_CI_RECHECK_SECS
# per (PR, head), it reads the head's CI fresh (mc_ci_state, never the memo),
# and on red or pending asks mcr_ci_override. Green on either:
#   - mc_handoff_release <key> ci-green-recheck (the handoff-rel record),
#   - one `parkcigreen <key> <head>` attempts line, which changes read_memo_fp,
#     so this tick's ci-read reads fresh by construction,
#   - one PARK_RELEASED_CI_GREEN log line.
# The row then classifies on the normal path in this same tick. rc 0 = released.
#
# The throttle: $MC_STATE_DIR/park-ci-recheck/<handoff-id>.<head12>, the epoch
# of the last read, written BEFORE the read. Retention: files older than 7 days
# are pruned on each write (one file per parked head; its value is one window).
# Knob: MC_STICKY_CI_RECHECK_SECS (catalog/lanes.d/merge-conductor.knobs.d/
# MC_STICKY_CI_RECHECK_SECS.json; fallback 600, 0 = off).

mc_park_ci_recheck() {
  local secs row st why rhead d f now at t word green=""
  secs="${MC_STICKY_CI_RECHECK_SECS:-600}"
  case "$secs" in ''|*[!0-9]*) secs=600 ;; esac
  [ "$secs" -gt 0 ] || return 1
  [ -n "${KEY:-}" ] && [ -n "${HEAD:-}" ] && [ -n "${SLUG:-}" ] && [ -n "${MC_STATE_DIR:-}" ] || return 1
  command -v mc_row_get >/dev/null 2>&1 && command -v mc_ci_state >/dev/null 2>&1 || return 1
  row=$(mc_row_get "$KEY"); [ -n "$row" ] || return 1
  st=$(cut -f2 <<<"$row"); rhead=$(cut -f4 <<<"$row"); why=$(cut -f7 <<<"$row")
  [ "$rhead" = "$HEAD" ] || return 1
  case "$st" in
    RED_TWICE|WAIT_MIGRATION) ;;
    BLOCKED_HUMAN) case "$why" in red-twice*) ;; *) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  d="$MC_STATE_DIR/park-ci-recheck"
  mkdir -p "$d" 2>/dev/null || return 1
  f="$d/$(mc_handoff_id "$KEY").${HEAD:0:12}"
  now=$(mc_now)
  at=$(head -n 1 "$f" 2>/dev/null)
  case "$at" in
    ''|*[!0-9]*) ;;
    *) if [ "$((now - at))" -ge 0 ] && [ "$((now - at))" -lt "$secs" ]; then return 1; fi ;;
  esac
  # The mark before the read: a read that fails or hangs is not retried until
  # the window ends.
  printf '%s\n' "$now" > "$f" 2>/dev/null
  find "$d" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null
  # A plain command into a file, never $( ), so mc_ci_state's globals stay here.
  t=$(mktemp "${TMPDIR:-/tmp}/mc-pcr.XXXXXX") || return 1
  mc_ci_state "$SLUG" "$HEAD" > "$t" 2>/dev/null || true
  word=$(head -n 1 "$t" 2>/dev/null); rm -f "$t"
  case "$word" in
    green) green="ci green on a fresh read" ;;
    red|pending)
      if command -v mcr_ci_override >/dev/null 2>&1 && mcr_ci_override "$SLUG" "$HEAD" "$word" "${PROVIDER:-}" >/dev/null; then
        green="${MCR_WHY:-every required check green}"
      fi ;;
  esac
  [ -n "$green" ] || return 1
  command -v mc_handoff_release >/dev/null 2>&1 && mc_handoff_release "$KEY" ci-green-recheck
  mc_attempt_put "parkcigreen $KEY $HEAD"
  mc_log "$KEY PARK_RELEASED_CI_GREEN on ${HEAD:0:8}: $green — the $st park is released and the row classifies on the normal path this tick; no resolver rung: ${URL:-}"
  return 0
}
