# shellcheck shell=bash
# bin/lib/lane-wake-gate.sh — SOURCED, never executed. No side effect at source
# time. The lane wake gate (BH-9072, BH-9067.0; docs/EVENTS.md): a scheduled
# tick of a lane that has catalog/lane-wakes.d/<lane>.json runs only when a
# ring (a `wakes` row, repo harness/lanes, kind lane, key <lane>:<scope>) or a
# newer webhook row of the registry's kinds for the project's repo was taken.
#
# lane_gate_or_exit (bin/lib/lane-gate.sh) calls lwg_take for a scheduled tick
# (the single-run guard claimed) of a lane with a registry file, before any
# other D1 read. A lane with no registry file pays one stat and nothing else.
#
#   lwg_mode <lane>               prints off | shadow | on. The lane's mode knob
#     is the `mode_knob` of its registry file (pm-groom: MODE_PM_GROOM), else
#     MODE_<LANE, - as _>. First valid answer:
#       1. settings row lib.lane-wake-gate.<mode knob lowercased> (operator row)
#       2. settings row lib.lane-wake-gate.mode_default
#       3. the registry default of the lane's mode knob (pm-groom: shadow)
#       4. the registry default of MODE_DEFAULT (off); off when none answers.
#     A row word other than off/shadow/on (case-sensitive) is ignored and named
#     once per LWG_FAIL_LOG_EVERY_S. The process env is never read for a mode.
#   lwg_take <lane> <scope>       rc 0 = run, rc 3 = skip. Never another rc.
#   lwg_ring <lane> <scope> <dedupe>   rc 0 when the worker answered 200 (it
#     prints inserted=<0|1>); rc 1 otherwise, with a ring-failed line. The
#     dedupe is lowercased (the worker's dedupe charset is lowercase).
#
# Decision of lwg_take (one line per take in logs/lane-wake-gate.log,
# `<iso> lwg <lane> <scope> <verdict>`):
#   mode off                         rc 0, no request, no line
#   a ring was taken                 rc 0, run wake=<first id>
#   no watermark file yet            rc 0, run first (rings only; watermark = pending)
#   watermark pending                rings only; watermark = webhook_max_id (or 0)
#   webhook_max_id > watermark       rc 0, run webhook=<id>; watermark = that id
#   nothing new, shadow              rc 0, would-skip
#   nothing new, on                  rc 3, skip
#   no jq / no client / no repo / no answer / bad answer / bad registry
#                                    rc 0, fail-open (<why>), one line per
#                                    LWG_FAIL_LOG_EVERY_S per (lane, scope), 0 ALERTS
# The watermark (state/lane-wake-gate/<lane>.<scope>.after: one integer, or
# the word pending) moves only after a 200 answer that parsed, through a temp
# file and mv. scope `fleet` sends no repo and no kinds: rings only.
#
# Knobs (catalog/lanes.d/_lib.lane-wake-gate.knobs.d/): MODE_<LANE>,
# MODE_DEFAULT, LWG_TIMEOUT_S, LWG_FAIL_LOG_EVERY_S.

# _lwg_root — the harness root, or rc 1 (D43: never a literal default).
_lwg_root() { _LWG_H="${HARNESS:-${H:-}}"; [ -n "$_LWG_H" ]; }

# _lwg_lib — lane-gate.sh's settings and registry readers, sourced when the
# caller did not (a calendar ringer). rc 1 when they are not there.
_lwg_lib() {
  command -v lane_knob >/dev/null 2>&1 && return 0
  _lwg_root || return 1
  # shellcheck source=lane-gate.sh
  . "$_LWG_H/bin/lib/lane-gate.sh" 2>/dev/null || return 1
  command -v lane_knob >/dev/null 2>&1
}

# _lwg_client — _jobs_req, or rc 1.
_lwg_client() {
  command -v _jobs_req >/dev/null 2>&1 && return 0
  _lwg_root || return 1
  # shellcheck source=../jobs-client.sh
  . "$_LWG_H/bin/jobs-client.sh" >/dev/null 2>&1 || return 1
  command -v _jobs_req >/dev/null 2>&1
}

_lwg_now() { if command -v _lg_now >/dev/null 2>&1; then _lg_now; else date -u '+%s'; fi; }

# _lwg_log <line> — one line in logs/lane-wake-gate.log.
_lwg_log() {
  _lwg_root || return 0
  mkdir -p "$_LWG_H/logs" 2>/dev/null
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$_LWG_H/logs/lane-wake-gate.log" 2>/dev/null
  return 0
}

# _lwg_int <ENV> <fallback> <min> <max> — a whole-number lib knob in bounds,
# else the fallback (the registry default, kept here as the documented code
# fallback: LWG_TIMEOUT_S 5, LWG_FAIL_LOG_EVERY_S 3600).
_lwg_int() {
  local v="" _LG_KIND=libs
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob lane-wake-gate "$1" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  { [ "$v" -ge "$3" ] && [ "$v" -le "$4" ]; } 2>/dev/null || v=$2
  printf '%s' "$v"
}

# _lwg_throttled <stamp> <line> — the line once per LWG_FAIL_LOG_EVERY_S.
_lwg_throttled() {
  local d f now last every
  _lwg_root || return 0
  d="$_LWG_H/state/lane-wake-gate"; f="$d/.$1"
  now=$(_lwg_now); every=$(_lwg_int LWG_FAIL_LOG_EVERY_S 3600 60 86400)
  last=$(tr -dc '0-9' < "$f" 2>/dev/null)
  if [ -n "$last" ] && [ -n "$now" ] && [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt "$every" ]; then
    return 0
  fi
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$now" > "$f" 2>/dev/null
  _lwg_log "$2"
}

# _lwg_mode_set <lane> — LWG_MODE = the mode (no subshell, so the settings
# memo of lane-gate.sh is kept for the rest of the tick).
_lwg_mode_set() {
  local lane="$1" u env key v reg _LG_KIND=libs
  LWG_MODE=off
  _lwg_lib || return 0
  # The lane's mode knob is named in its own registry file (`mode_knob`), so
  # a new gated lane adds that file and one knob file and edits nothing shared,
  # and the knob's read_in is that file. With no name there, it is
  # MODE_<LANE, - as _>.
  env=""
  if _lwg_root && command -v jq >/dev/null 2>&1; then
    env=$(jq -r '.mode_knob // empty' "$_LWG_H/catalog/lane-wakes.d/$lane.json" 2>/dev/null)
  fi
  case "$env" in MODE_?*) case "$env" in *[!A-Z0-9_]*) env="" ;; esac ;; *) env="" ;; esac
  if [ -z "$env" ]; then u=${lane//-/_}; env="MODE_$(printf '%s' "$u" | tr '[:lower:]' '[:upper:]')"; fi
  _lg_settings_refresh
  for key in "lib.lane-wake-gate.$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')" "lib.lane-wake-gate.mode_default"; do
    _lg_setting_lookup_set "$key" || continue
    v=$_LG_SVAL
    case "$v" in
      off|shadow|on) LWG_MODE=$v; return 0 ;;
      *) _lwg_throttled "mode-$key" "lwg $lane - bad-mode $key=$v ignored (want off, shadow or on)" ;;
    esac
  done
  _lg_registry >/dev/null; reg=$_LG_REG_OUT
  [ -r "$reg" ] || return 0
  for key in "$env" MODE_DEFAULT; do
    _lg_knob_meta_set "$reg" lane-wake-gate "$key" default
    case "$_LG_META" in off|shadow|on) LWG_MODE=$_LG_META; return 0 ;; esac
  done
  return 0
}
lwg_mode() { _lwg_mode_set "${1:-}"; printf '%s\n' "$LWG_MODE"; }

# _lwg_fail <lane> <scope> <why> — the fail-open answer: rc 0, one throttled line.
_lwg_fail() {
  _lwg_throttled "fail-$1.$2" "lwg $1 $2 fail-open ($3)"
  return 0
}

lwg_take() {
  local lane="${1:-}" scope="${2:-}" reg kinds repo="" wmf wm="" after=0 send body out rc
  local tmp first wmax verdict newwm=""
  case "$lane" in ''|*[!a-z0-9-]*) return 0 ;; esac
  case "$scope" in ''|.*|*[!a-z0-9._-]*) return 0 ;; esac
  _lwg_mode_set "$lane"
  [ "$LWG_MODE" = off ] && return 0
  _lwg_root || return 0
  command -v jq >/dev/null 2>&1 || { _lwg_fail "$lane" "$scope" no-jq; return 0; }
  reg="$_LWG_H/catalog/lane-wakes.d/$lane.json"
  kinds=$(jq -ce --arg l "$lane" 'select(.lane == $l and (.kinds | type) == "array" and (.kinds | length) <= 8
      and all(.kinds[]; type == "string" and test("^[a-z_]{1,32}$"))) | .kinds' "$reg" 2>/dev/null) \
    || { _lwg_fail "$lane" "$scope" bad-registry; return 0; }
  _lwg_client || { _lwg_fail "$lane" "$scope" no-client; return 0; }
  wmf="$_LWG_H/state/lane-wake-gate/$lane.$scope.after"
  if [ "$scope" = fleet ]; then
    kinds='[]'
  else
    repo=$("$_LWG_H/bin/fleet-conf.sh" "$scope" repo 2>/dev/null) || repo=""
    [ -n "$repo" ] || { _lwg_fail "$lane" "$scope" no-repo; return 0; }
  fi
  [ -f "$wmf" ] && wm=$(tr -dc 'a-z0-9' < "$wmf" 2>/dev/null)
  case "$wm" in
    pending) after=0 ;;
    ''|*[!0-9]*) wm=""; kinds='[]' ;;   # no watermark: rings only (a first tick never reads history)
    *) after=$wm ;;
  esac
  [ "$kinds" = '[]' ] && repo=""
  body=$(jq -nc --arg l "$lane" --arg s "$scope" --argjson k "$kinds" --arg r "$repo" --argjson a "$after" \
    '{lane:$l, scope:$s, kinds:$k} + (if ($k | length) > 0 then {repo:$r, after_id:$a} else {} end)') \
    || { _lwg_fail "$lane" "$scope" bad-registry; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/lwg.XXXXXX" 2>/dev/null) || { _lwg_fail "$lane" "$scope" no-client; return 0; }
  # JOBS_RETRIES=0 is a correctness constant, not a knob: a retry after a lost
  # answer would read the first try's ack as "nothing taken" and skip a rung
  # lane. A lost answer fails open instead, so the lane runs.
  rc=0
  JOBS_TIMEOUT=$(_lwg_int LWG_TIMEOUT_S 5 1 30) JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 \
    _jobs_req POST /api/lane-wakes/take "$body" > "$tmp" 2>/dev/null || rc=$?
  out=$(cat "$tmp" 2>/dev/null); rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    if [ -z "${JOBS_HTTP:-}" ]; then _lwg_fail "$lane" "$scope" no-answer; else _lwg_fail "$lane" "$scope" bad-answer; fi
    return 0
  fi
  send=$(jq -r '
      if (.taken | type) == "array" and all(.taken[]; type == "number")
         and (.webhook_max_id == null or (.webhook_max_id | type) == "number")
      then "\(.taken[0] // "-") \(.webhook_max_id // "-")" else empty end' <<<"$out" 2>/dev/null)
  [ -n "$send" ] || { _lwg_fail "$lane" "$scope" bad-answer; return 0; }
  read -r first wmax <<<"$send"
  if [ -z "$wm" ]; then
    newwm=pending
  elif [ "$wm" = pending ]; then
    newwm=${wmax/#-/0}
  elif [ "$wmax" != - ] && [ "$wmax" -gt "$wm" ] 2>/dev/null; then
    newwm=$wmax
  fi
  if [ -n "$newwm" ]; then
    mkdir -p "${wmf%/*}" 2>/dev/null
    printf '%s\n' "$newwm" > "$wmf.tmp.$$" 2>/dev/null && mv -f "$wmf.tmp.$$" "$wmf" 2>/dev/null
  fi
  if [ "$first" != - ]; then verdict="run wake=$first"
  elif [ -z "$wm" ]; then verdict="run first"
  elif [ "$wm" != pending ] && [ -n "$newwm" ]; then verdict="run webhook=$newwm"
  elif [ "$LWG_MODE" = on ]; then verdict=skip
  else verdict=would-skip
  fi
  _lwg_log "lwg $lane $scope $verdict"
  [ "$verdict" = skip ] && return 3
  return 0
}

lwg_ring() {
  local lane="${1:-}" scope="${2:-}" dedupe body out rc=0 tmp
  dedupe=$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')
  command -v jq >/dev/null 2>&1 || { _lwg_log "lwg $lane $scope ring-failed (no-jq)"; return 1; }
  _lwg_lib >/dev/null 2>&1 || :
  _lwg_client || { _lwg_log "lwg $lane $scope ring-failed (no-client)"; return 1; }
  body=$(jq -nc --arg l "$lane" --arg s "$scope" --arg d "$dedupe" '{lane:$l, scope:$s, dedupe:$d}')
  tmp=$(mktemp "${TMPDIR:-/tmp}/lwg.XXXXXX" 2>/dev/null) || { _lwg_log "lwg $lane $scope ring-failed (mktemp)"; return 1; }
  JOBS_TIMEOUT=$(_lwg_int LWG_TIMEOUT_S 5 1 30) JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 \
    _jobs_req POST /api/lane-wakes/ring "$body" > "$tmp" 2>/dev/null || rc=$?
  out=$(cat "$tmp" 2>/dev/null); rm -f "$tmp"
  if [ "$rc" -ne 0 ] || [ "${JOBS_HTTP:-}" != 200 ]; then
    _lwg_log "lwg $lane $scope ring-failed (${JOBS_HTTP:+http=}${JOBS_HTTP:-no-answer})"; return 1
  fi
  out=$(jq -er '.inserted | select(. == 0 or . == 1)' <<<"$out" 2>/dev/null) \
    || { _lwg_log "lwg $lane $scope ring-failed (bad-answer)"; return 1; }
  printf 'inserted=%s\n' "$out"
  return 0
}
