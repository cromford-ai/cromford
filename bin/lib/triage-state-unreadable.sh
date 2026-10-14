#!/bin/bash
# bin/lib/triage-state-unreadable.sh — the rows-unreadable hook of the
# TRIAGE-STATE tick (BH-3921, body BH-3925). Sourced by bin/lib/triage-state.sh
# next to the lib; defines functions only, nothing runs on source.
# Doc: docs/triage-state/rows-unreadable.md.
#
# ts_rows_unreadable_tick — ts_tick calls it once per tick, right before the
# `TS_READY != 1` early return, and never on a `forced` / `forced-env` tick.
# `ts_rows_unreadable_tick && return 0` is the call: rc 0 means it handled the
# tick, rc 1 means it did nothing and the tick goes on as before.
#
# Under enforce, a tick whose triage_state rows could not be read (TS_ROWS_OK=0,
# set by ts_precheck) used to send every open ticket to the model: a full-board
# paid session bought exactly when we know the least. Now:
#   rows readable           remove state/triage-state/<p>/rows-unreadable.streak, rc 1
#   not enforce             rc 1 (shadow's line still says every ticket goes to the model)
#   no decisions.tsv        rc 1: the pre-check never got as far as the rows read
#                           (no board fingerprint, no jq/python3, a failed decision
#                           pass), so TS_ROWS_OK=0 is only its default
#   reason not an enforce   rc 1 (gate-error, anything unknown). no-gate-state and
#   one                     gate-fetch-failed ARE acted on here, though
#                           _ts_enforce_reason leaves them observe-only
#   work in scope           a queue line, a queue dir, a finished build, a
#                           remote-results-pending tick, or an UNBLOCKED /
#                           STACKABLE / `board prs:` scope line: the session runs
#                           RESTRICTED to that work (TS_ENFORCING=1, TS_SKIPSET =
#                           every decisions.tsv key with no work and no UNBLOCKED /
#                           STACKABLE line, one directive on
#                           PROMPT_TEXT), rc 0. The streak is left alone.
#   no work                 the tick EXITS, logged `rc=skip`, no model call, the
#                           streak bumped. rt_gate_consume is never called, so the
#                           pending gate survives and the next tick re-offers it.
# At TRIAGE_STATE_UNREADABLE_ALERT_AFTER skips in a row, ONE alert
# (bin/lane-alert.sh --id triage-rows-unreadable:<p>, else bin/alert-line.sh);
# the streak is stamped `alerted` only after a send returned 0.
#
# The streak file: line 1 the count, optional line 2 `alerted`, written through
# a temp file and mv -f. An unparseable count reads as 0, not alerted.
ts_rows_unreadable_tick() {
  local h p d sf n after msg rel alerted=""
  h=$(_ts_h); p="${PROJECT:-}"
  [ -n "$h" ] && [ -n "$p" ] || return 1
  d=$(_ts_dir "$p"); sf="$d/rows-unreadable.streak"
  if [ "${TS_ROWS_OK:-0}" = 1 ]; then rm -f "$sf" 2>/dev/null; return 1; fi
  [ "${TS_MODE:-off}" = enforce ] || return 1
  [ -e "$d/decisions.tsv" ] || return 1
  case "${GATE_REASON:-}" in no-gate-state|gate-fetch-failed) ;; *) _ts_enforce_reason || return 1 ;; esac
  if [ -n "${QLINES:-}${QDIRS:-}${RDIRS:-}" ] || [ "${GATE_REASON:-}" = remote-results-pending ] \
     || grep -qE 'UNBLOCKED|STACKABLE|^board prs:' <<<"$(printf '%s\n%s\n' "${TICK_SCOPE:-}" "${BOARD_SEC:-}")"; then
    TS_ENFORCING=1
    # A key an UNBLOCKED / STACKABLE line releases is launch work too, though
    # column 9 counts only queue lines and finished builds: keep it out of the skip set.
    rel=" $(_ts_unr_released_keys "$h" | tr '\n' ' ') "
    TS_SKIPSET=" $(awk -F'\t' -v rel="$rel" '$9!="1" && !index(rel, " " $1 " ") && !index(rel, " " $2 " ") {printf "%s ", $1}' "$d/decisions.tsv" 2>/dev/null)"
    ts_waste_account restricted
    _ts_log "triage-state enforce: rows unreadable — session restricted to the queue and finished-build work in scope [gate=${GATE_REASON:-?}$(ts_waste_bracket)]"
    PROMPT_TEXT="${PROMPT_TEXT:-}

TRIAGE STATE UNREADABLE: do NOT re-triage any ticket this tick; work only the queue lines, finished-build close-outs, UNBLOCKED/STACKABLE launches and PR lines in scope."
    return 0
  fi
  n=$(_ts_unr_streak_count "$sf")
  [ "$n" -gt 0 ] && _ts_unr_streak_alerted "$sf" && alerted=1
  n=$((n+1))
  _ts_unr_streak_write "$sf" "$n" "$alerted"
  after=$(ts_unreadable_alert_after)
  if [ "$n" -ge "$after" ] && [ -z "$alerted" ]; then
    msg="$p: triage skipped $n ticks in a row: the triage_state rows could not be read (worker unreachable or a bad answer). No model call was made. Check: bin/jobs-client.sh reachability from this box, logs/$p.log."
    _ts_unr_alert "$h" "$p" "$msg" && _ts_unr_streak_write "$sf" "$n" alerted
  fi
  if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
    [ -n "${JOB_BEAT:-}" ] && command -v job_beat_stop >/dev/null 2>&1 && job_beat_stop "$JOB_BEAT"
    job_update "$JOB_ID" stage=done status=done "meta=triage-state: rows unreadable" >/dev/null 2>&1
  fi
  command -v LANE_TICK >/dev/null 2>&1 && LANE_TICK skip
  ts_waste_account unreadable
  _ts_log "rc=skip :: triage-state: rows unreadable — tick skipped, no model call (streak $n) [gate=${GATE_REASON:-?}$(ts_waste_bracket)]"
  exit 0
}

# _ts_unr_released_keys <harness> — the keys this tick's UNBLOCKED / STACKABLE
# scope lines release, one per line, through bin/lib/revdep-lib.sh's revdep_keys.
_ts_unr_released_keys() {
  # shellcheck source=bin/lib/revdep-lib.sh
  command -v revdep_keys >/dev/null 2>&1 || { [ -r "$1/bin/lib/revdep-lib.sh" ] && . "$1/bin/lib/revdep-lib.sh" 2>/dev/null; }
  command -v revdep_keys >/dev/null 2>&1 || return 0
  printf '%s\n%s\n' "${TICK_SCOPE:-}" "${BOARD_SEC:-}" | sed 's/^\[HOTFIX\] //' | revdep_keys
}
# _ts_unr_streak_count <file> — line 1 as a base-10 count, 0 when absent or unparseable.
_ts_unr_streak_count() {
  local n
  n=$(sed -n 1p "$1" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$((10#$n))" ;; esac
}
# _ts_unr_streak_alerted <file> — rc 0 when line 2 is `alerted`.
_ts_unr_streak_alerted() { [ "$(sed -n 2p "$1" 2>/dev/null)" = alerted ]; }
# _ts_unr_streak_write <file> <count> [alerted] — atomic: a temp file, then mv -f.
_ts_unr_streak_write() {
  local t="$1.$$.t"
  mkdir -p "$(dirname "$1")" 2>/dev/null
  { printf '%s\n' "$2"; if [ -n "${3:-}" ]; then printf 'alerted\n'; fi; } > "$t" 2>/dev/null && mv -f "$t" "$1" 2>/dev/null
}
# _ts_unr_alert <harness> <project> <text> — rc 0 when a send returned 0:
# bin/lane-alert.sh (deduped by --id), else bin/alert-line.sh. Never a raw
# ALERTS.log append (the BH-2314 alert-writers ratchet).
_ts_unr_alert() {
  [ -x "$1/bin/lane-alert.sh" ] && "$1/bin/lane-alert.sh" --id "triage-rows-unreadable:$2" --severity warn triage "$3" >/dev/null 2>&1 && return 0
  [ -x "$1/bin/alert-line.sh" ] || return 1
  ALERT_LINE_STAMP="${STAMP:-}" "$1/bin/alert-line.sh" --severity warn --project "$2" "$3" >/dev/null 2>&1
}

# ts_unreadable_alert_after — TRIAGE_STATE_UNREADABLE_ALERT_AFTER (settings row
# lib.triage-state[.<project>].triage_state_unreadable_alert_after), default 3,
# floored at 1. The streak of skipped rows-unreadable ticks before one alert;
# ts_precheck's _ts_knobs has applied the rows by the time the hook reads it.
ts_unreadable_alert_after() { _ts_int "${TRIAGE_STATE_UNREADABLE_ALERT_AFTER:-3}" 3 1; }
