#!/bin/bash
# shellcheck shell=bash
# bin/lib/mc/parks-delta.sh — BH-9075 (BH-9067.3): the merge conductor's
# PARKS DELTA. A project with no changed parks row and no pr/checks wake since
# its last full walk skips the per-PR walk of that tick. Not a `# module:`
# file: an optional lib, sourced by bin/merge-conductor.d/bh-9075-parks.sh
# (which also sources bin/lib/parks-write.sh). No side effect at source time.
# docs/MERGE-CONDUCTOR.md section 11, docs/events-bh-9067/3-parks.md.
#
#   mc_parks_delta_skip <project>   rc 0 = skip the walk, rc 1 = walk.
#     Called in tick_project after the cadence hold and before pause_active,
#     use_token and every GitHub read. The checks, in order; the first that
#     answers "walk" wins:
#       1. MC_PARKS_DELTA_MODE is off (the default)            walk, no request
#       2. a keyed tick (MC_ONLY_KEYS)                         walk
#       3. no walk stamp, or it is MC_PARKS_DELTA_MAX_SKIP_S old walk (bounded skip)
#       4. a pre-queue verdict file of the repo newer than the stamp   walk
#       5. GET /api/parks/changed since stamp - MC_PARKS_DELTA_LAG_S has a row,
#          or the read failed                                  walk (fail-open)
#       6. POST /api/lane-wakes/take (lane mc-parks-delta, kinds pr, checks):
#          no watermark yet, webhook_max_id above it, or a failure    walk
#       7. nothing changed: mode on  -> `TICK <p> held: ... (decision=parks-quiet)`, rc 0
#                           mode shadow -> `... would skip (decision=parks-quiet-shadow)`, rc 1
#     The two reads are sequential on purpose: the wake read is skipped when
#     the parks read already says walk. No metrics line on a skip (the
#     cadence hold's rule: tick-<p>.json.started_at must not move).
#     The PREQUEUE D1 read is owed (#9061 holds none); check 4 is the local guard.
#   mc_parks_tick_end <project> <slug> [t0]   rc 0 always. pw_conductor_sync, and
#     on a full tick the walk stamp = the tick's T0.
#
# State (cache, catalog/state-paths.d/9075-parks.json):
#   state/merge-conductor/parks-delta/<p>.walk  epoch of the last full walk
#   state/merge-conductor/parks-delta/<p>.wake  the webhook id watermark
# Knobs (catalog/lanes.d/merge-conductor.knobs.d/): MC_PARKS_DELTA_MODE (off),
# MC_PARKS_DELTA_MAX_SKIP_S (1800), MC_PARKS_DELTA_LAG_S (120).

_mpd_dir() { printf '%s/parks-delta' "${MC_STATE_DIR:-${HARNESS:-${H:-}}/state/merge-conductor}"; }
_mpd_h() { printf '%s' "${MC_H:-${HARNESS:-${H:-}}}"; }
_mpd_log() { if command -v mc_log >/dev/null 2>&1; then mc_log "$*"; fi; return 0; }

# _mpd_int <ENV> <fallback> <min> <max> — the lane knob (lane_env_apply exports it), else the fallback.
_mpd_int() {
  local v="${!1:-}"
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  { [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } 2>/dev/null || v=$2
  printf '%s' "$v"
}

# _mpd_write <file> <value> — tmp + mv.
_mpd_write() { mkdir -p "${1%/*}" 2>/dev/null; printf '%s\n' "$2" > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null; }

mc_parks_delta_skip() {
  local p="${1:-}" mode d walk now maxs lag repo f out wmf wm="" body wmax iso
  mode=${MC_PARKS_DELTA_MODE:-off}           # lane.merge-conductor.mc_parks_delta_mode; code fallback off
  case "$mode" in shadow|on) ;; *) return 1 ;; esac
  [ -n "${MC_ONLY_KEYS:-}" ] && return 1
  [ -n "$p" ] || return 1
  d=$(_mpd_dir); now=$(date -u +%s)
  walk=$(tr -dc '0-9' 2>/dev/null < "$d/$p.walk")
  [ -n "$walk" ] || return 1
  maxs=$(_mpd_int MC_PARKS_DELTA_MAX_SKIP_S 1800 60 86400)   # lane.merge-conductor.mc_parks_delta_max_skip_s
  [ $((now - walk)) -lt "$maxs" ] && [ $((now - walk)) -ge 0 ] || return 1
  repo=$("$(_mpd_h)/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || repo=""
  case "$repo" in */*) ;; *) return 1 ;; esac
  for f in "${MC_STATE_DIR:-/nonexistent}/prequeue/${repo//\//_}_"*; do
    [ -e "$f" ] && [ "$f" -nt "$d/$p.walk" ] && return 1
  done
  if ! command -v parks_changed >/dev/null 2>&1; then
    # shellcheck source=../jobs/parks.sh
    . "$(_mpd_h)/bin/lib/jobs/parks.sh" 2>/dev/null || return 1
  fi
  lag=$(_mpd_int MC_PARKS_DELTA_LAG_S 120 0 3600)            # lane.merge-conductor.mc_parks_delta_lag_s
  out=$(parks_changed "$p" "$(( walk > lag ? walk - lag : 0 ))" 1 0) || return 1
  grep -q '^row	' <<<"$out" && return 1
  # The wake read. Its watermark moves only after a parsed 200.
  command -v jq >/dev/null 2>&1 || return 1
  wmf="$d/$p.wake"
  [ -f "$wmf" ] && wm=$(tr -dc '0-9' 2>/dev/null < "$wmf")
  body=$(jq -nc --arg s "$p" --arg r "$repo" --argjson a "${wm:-0}" \
    '{lane:"mc-parks-delta", scope:$s, kinds:["pr","checks"], repo:$r, after_id:$a}') || return 1
  _pk_req POST /api/lane-wakes/take "$body" || return 1
  wmax=$(jq -er 'if (.taken | type) == "array" and (.webhook_max_id == null or (.webhook_max_id | type) == "number")
                 then (.webhook_max_id // "-" | tostring) else error("bad") end' <<<"$_PK_OUT" 2>/dev/null) || return 1
  if [ -z "$wm" ]; then _mpd_write "$wmf" "${wmax/#-/0}"; return 1; fi
  if [ "$wmax" != - ] && [ "$wmax" -gt "$wm" ] 2>/dev/null; then _mpd_write "$wmf" "$wmax"; return 1; fi
  iso=$(date -u -d "@$walk" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$walk")
  if [ "$mode" = on ]; then
    _mpd_log "TICK $p held: no parks change and no pr/checks wake since $iso — the per-PR walk is skipped this tick (decision=parks-quiet)"
    return 0
  fi
  _mpd_log "TICK $p would skip: no parks change and no pr/checks wake since $iso — shadow, the walk runs (decision=parks-quiet-shadow)"
  return 1
}

mc_parks_tick_end() {
  local p="${1:-}" slug="${2:-}" t0="${3:-}"
  [ -n "$p" ] || return 0
  command -v pw_conductor_sync >/dev/null 2>&1 && pw_conductor_sync "$p" "$slug"
  case "$t0" in ''|*[!0-9]*) t0=$(date -u +%s) ;; esac
  [ -n "${MC_ONLY_KEYS:-}" ] || _mpd_write "$(_mpd_dir)/$p.walk" "$t0"
  return 0
}
