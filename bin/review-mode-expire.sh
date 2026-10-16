#!/bin/bash
# bin/review-mode-expire.sh — the review dial's clock (BH-7123 wave B). Hub
# lane, every 15 minutes behind the hub lease (cron/lanes/472-review-mode-expire.cron).
#
# Every tick reads the settings snapshot once (GET /api/settings) and, for every
# review.mode_until[.<project>] row whose time is in the past:
#   * mode row not `levels` -> write review.mode[.<project>]=levels, clear the
#     until row (`never`), one log line, ONE operator line
#     "review.mode[.<p>] expired: <old> -> levels";
#   * mode row already levels (or absent) -> clear the stale until row only.
# A row that reads `never`, `-` or empty has no expiry. A value that is not an
# ISO-8601 UTC time is logged and skipped (never flips a mode on junk).
# Idempotent: once a row is cleared nothing matches it again. FAIL-OPEN TO NO
# CHANGE: an unreadable settings read, a missing jobs client or a failed write
# changes nothing and leaves one log line; the next tick retries.
#   --dry-run              log what would flip, write nothing
#   REVIEW_MODE_EXPIRE_NOW epoch seconds standing in for the clock (tests)
# Off: flags/lane-off-review-mode-expire or bin/harness-ctl.sh off review-mode-expire.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
set -a; . "$HENV/global.env" 2>/dev/null; set +a

. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit review-mode-expire
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    review-mode-expire

LOG="$H/logs/review-mode-expire.log"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$LOG"; }
DRY=0
case "${1:-}" in --dry-run) DRY=1 ;; '') ;; *) echo "usage: bin/review-mode-expire.sh [--dry-run]" >&2; exit 2 ;; esac

[ -r "$H/bin/jobs-client.sh" ] || { log "bin/jobs-client.sh missing; nothing changed"; exit 0; }
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || { log "bin/jobs-client.sh did not load; nothing changed"; exit 0; }
command -v _jobs_req >/dev/null 2>&1 && command -v setting_set >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { log "no jobs client or no jq; nothing changed"; exit 0; }
if command -v flock >/dev/null 2>&1; then
  exec 9>"$H/locks/review-mode-expire.lock"; flock -n 9 || exit 0
fi

# The clock; REVIEW_MODE_EXPIRE_NOW (epoch seconds) stands in for it only under
# HARNESS_TEST_SANDBOX=1 (a test seam, registered settable=false).
NOW=""
[ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && NOW="${REVIEW_MODE_EXPIRE_NOW:-}"
case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
epoch_of() { # epoch_of <iso-utc> — GNU date, then BSD date; rc 1 when it is not one
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null  # determinism: ok the regex on the line above rejects an empty or non-ISO value before date sees it
}

RESP=$(_jobs_req GET /api/settings) || { log "settings unreadable (http ${JOBS_HTTP:-none}); nothing changed"; exit 0; }
jq -e '(.settings | type) == "array"' <<<"$RESP" >/dev/null 2>&1 || { log "settings answer unparseable; nothing changed"; exit 0; }
CHECKED=0; FLIPPED=0; CLEARED=0
while IFS=$'\t' read -r UK V; do
  [ -n "$UK" ] || continue
  CHECKED=$((CHECKED+1))
  case "$V" in ''|never|-) continue ;; esac
  E=$(epoch_of "$V") || { log "$UK reads '$V', not an ISO-8601 UTC time; skipped"; continue; }
  [ "$E" -le "$NOW" ] || continue
  SFX="${UK#review.mode_until}"            # "" for the fleet row, ".<project>" otherwise
  MK="review.mode$SFX"; P="${SFX#.}"
  M=$(jq -r --arg k "$MK" '.settings[] | select(.key == $k) | .value' <<<"$RESP" | head -1 | tr -d '[:space:]')
  if [ -n "$M" ] && [ "$M" != levels ]; then
    if [ "$DRY" = 1 ]; then log "DRY would flip $MK: $M -> levels (until $V passed)"; continue; fi
    setting_set "$MK" levels "BH-7123 review-mode-expire: $M expired at $V" \
      || { log "could not write $MK=levels (http ${JOBS_HTTP:-none}); next tick retries"; continue; }
    setting_set "$UK" never "BH-7123 review-mode-expire: cleared after $M expired at $V" \
      || log "could not clear $UK (http ${JOBS_HTTP:-none}); the mode is levels, the next tick re-clears"
    FLIPPED=$((FLIPPED+1))
    log "$MK expired: $M -> levels (until $V)"
    [ -x "$H/bin/alert-line.sh" ] && HARNESS="$H" "$H/bin/alert-line.sh" --severity info --id "review-mode-expire${SFX:-.fleet}" ${P:+--project "$P"} \
      "[review-mode] $MK expired: $M -> levels (was due $V). Set it again with bin/review-mode.sh ${P:-fleet} $M --for <Nh> if the sprint is still on." >/dev/null 2>&1 || true
  else
    if [ "$DRY" = 1 ]; then log "DRY would clear $UK ($V passed; mode ${M:-unset})"; continue; fi
    setting_set "$UK" never "BH-7123 review-mode-expire: stale until cleared (mode ${M:-unset})" \
      || { log "could not clear $UK (http ${JOBS_HTTP:-none}); next tick retries"; continue; }
    CLEARED=$((CLEARED+1))
    log "$UK cleared ($V passed; mode ${M:-unset} needs no flip)"
  fi
done < <(jq -r '.settings[] | select(.key | test("^review\\.mode_until(\\.[a-z0-9_-]+)?$")) | [.key, (.value // "")] | @tsv' <<<"$RESP")
log "tick: $CHECKED until row(s) checked, $FLIPPED flipped to levels, $CLEARED cleared$([ "$DRY" = 1 ] && echo ' (dry run)')"
exit 0
