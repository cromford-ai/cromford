#!/bin/bash
# bin/lib/triage-park.sh — BH-3949 (BH-3943 item 1): park a ticket the
# call-guard keeps refusing. Sourced, never executed. Defines functions only:
# no `set -e`, no `exit`, nothing runs or prints at source time.
#
# WHY. project-4 TK-2117 sat in the TRIAGE-STATE "to the model" list on every tick
# from 2026-10-01: each shard was refused by the call-guard (`repeat`, this
# world already had its paid sessions today), refused shards stamp nothing, so
# the pre-check offered it again next tick. The refusal costs $0, the churn
# does not. After TRIAGE_REFUSED_PARK_AFTER refusals of ONE fingerprint the
# ticket's triage_state row gets a `hold` verdict stamped with its own
# input_hash; bin/triage-state.py decide then answers `skip unchanged:hold`
# until next_recheck_at, and any board change moves input_hash and sends it
# back to the model. Unparking needs no code.
#
#   triage_park_on_refusal <harness> <project> <KEY> <cg_fp> [mark]
#     bin/triage-shard.sh's `call-guard repeat` arm only. The count is the D1
#     call_guard row for "<KEY>:<cg_fp>" (refused_since_reset); the park is ONE
#     triage_state_put. Fail-open: an unreadable list, no row, no triage_state
#     row or no input_hash parks nothing and logs one line. Write-then-tell: the
#     alert-once marker state/triage-park/<p>/<KEY>.<fp> is written only after
#     a 2xx PUT, and lane-alert runs only when the marker was absent.
#   triage_park_tick_line <harness> <project>
#     One `triage-park: N parked (KEYS)` line per tick (N=0: nothing), and the
#     markers of keys no longer parked are pruned — only after a good read.
#   triage_park_note <harness> <project> <KEY> <text>
#     The observe-column write ({last_decision}), verdict untouched. rc only.
#
# KNOBS (catalog/lanes.d/_lib.triage-park.json, through lib_env_apply; the
# numbers below are the documented fallback only):
#   TRIAGE_REFUSED_PARK_AFTER (3, 0 = off)   TRIAGE_PARK_RECHECK_S (604800)
# shellcheck shell=bash
if [ -n "${TRIAGE_PARK_LIB:-}" ]; then return 0 2>/dev/null; fi
TRIAGE_PARK_LIB=1
_TP_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_TP_APPLIED=0

# _tp_knobs <project> — sets _TP_AFTER/_TP_RECHECK in THIS shell; the settings
# contract is applied once per process (split-chain.sh's _sc_knobs idiom).
_tp_knobs() {
  if [ "$_TP_APPLIED" = 0 ]; then
    _TP_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_TP_LIBDIR/lane-gate.sh" ] && . "$_TP_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply triage-park "${1:-}"
  fi
  _TP_AFTER="${TRIAGE_REFUSED_PARK_AFTER:-3}"
  _TP_RECHECK="${TRIAGE_PARK_RECHECK_S:-604800}"
  case "$_TP_AFTER" in ''|*[!0-9]*) _TP_AFTER=3 ;; esac
  case "$_TP_RECHECK" in ''|*[!0-9]*) _TP_RECHECK=604800 ;; esac
  return 0
}

# _tp_jobs <harness> — the jobs-client functions, from this process when the
# caller already sourced them, else from <harness>/bin/jobs-client.sh.
_tp_jobs() {
  command -v triage_state_put >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  [ -n "${1:-}" ] && [ -r "$1/bin/jobs-client.sh" ] && . "$1/bin/jobs-client.sh" 2>/dev/null
  command -v triage_state_put >/dev/null 2>&1
}

_tp_log() { # _tp_log <harness> <project> <text>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  mkdir -p "$1/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$2] $3" >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

# _tp_put <harness> <json> — one triage_state_put of <json>; its rc.
_tp_put() {
  local f rc
  f=$(mktemp "${TMPDIR:-/tmp}/triage-park.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$2" > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  rc=0; triage_state_put "$f" >/dev/null 2>&1 </dev/null || rc=$?
  rm -f "$f"
  return "$rc"
}

triage_park_on_refusal() {
  local h="${1:-}" p="${2:-}" k="${3:-}" fp="${4:-}" mark="${5:-}" cg row r paid max ih now body mk
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 0
  case "$k$fp" in *[!A-Za-z0-9._-]*) return 0 ;; esac
  _tp_knobs "$p"
  [ "$_TP_AFTER" -gt 0 ] && [ -n "$fp" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  _tp_jobs "$h" && command -v call_guard_list >/dev/null 2>&1 && command -v triage_state_get >/dev/null 2>&1 \
    || { _tp_log "$h" "$p" "triage-park: $k not parked: no jobs client"; return 0; }
  cg=$(call_guard_list "$p" triage-shard 24 2>/dev/null </dev/null) \
    || { _tp_log "$h" "$p" "triage-park: $k not parked: call-guard list unreadable"; return 0; }
  printf '%s' "$cg" | jq -e '.rows | type == "array"' >/dev/null 2>&1 \
    || { _tp_log "$h" "$p" "triage-park: $k not parked: call-guard list unreadable"; return 0; }
  r=$(printf '%s' "$cg" | jq -r --arg fp "$k:$fp" \
    '[.rows[] | select(.fp == $fp)][0] | if . == null then "" else (.refused_since_reset // "" | tostring) end' 2>/dev/null)
  [ -n "$r" ] || { _tp_log "$h" "$p" "triage-park: $k not parked: no call-guard row for $k:$fp"; return 0; }
  case "$r" in *[!0-9]*) _tp_log "$h" "$p" "triage-park: $k not parked: unreadable refusal count '$r'"; return 0 ;; esac
  [ "$r" -ge "$_TP_AFTER" ] || return 0
  row=$(triage_state_get "$p" "$k" 2>/dev/null </dev/null) \
    || { _tp_log "$h" "$p" "triage-park: $k not parked: no triage_state row"; return 0; }
  ih=$(printf '%s' "$row" | jq -r '.input_hash // "" | tostring' 2>/dev/null)
  [ -n "$ih" ] || { _tp_log "$h" "$p" "triage-park: $k not parked: its triage_state row has no input_hash"; return 0; }
  # paid=<n>/<max> from agent-call's own refusal mark; the row's paid if absent.
  paid=$(printf '%s' "$mark" | sed -nE 's#.* paid=([0-9]+)/([0-9]+).*#\1#p')
  max=$(printf '%s' "$mark" | sed -nE 's#.* paid=([0-9]+)/([0-9]+).*#\2#p')
  [ -n "$paid" ] || paid=$(printf '%s' "$cg" | jq -r --arg fp "$k:$fp" '[.rows[] | select(.fp == $fp)][0].paid // "?" | tostring' 2>/dev/null)
  mk="$h/state/triage-park/$p/$k.$fp"
  # Already parked on this hash: no second PUT, so a refusal every tick does
  # not keep pushing the recheck clock forward.
  if ! printf '%s' "$row" | jq -e --arg ih "$ih" \
       '.verdict == "hold" and ((.reason // "") | startswith("call-guard-exhausted")) and .verdict_hash == $ih' >/dev/null 2>&1; then
    now=$(date +%s)
    body=$(jq -nc --arg p "$p" --arg k "$k" --arg ih "$ih" --argjson now "$now" --argjson re "$_TP_RECHECK" \
      --arg why "call-guard-exhausted: paid ${paid:-?}/${max:-?}, refused $r, last repeat" \
      '{project:$p, ticket_key:$k, verdict:"hold", waiting_on:"team", verdict_hash:$ih,
        triaged_at:($now|todate), next_recheck_at:(($now + $re)|todate), reason:$why}' 2>/dev/null) || return 0
    _tp_put "$h" "$body" || { _tp_log "$h" "$p" "triage-park: $k not parked: triage_state PUT failed (retried on the next refusal)"; return 0; }
  fi
  [ -e "$mk" ] && return 0
  mkdir -p "${mk%/*}" 2>/dev/null && : > "$mk" 2>/dev/null || return 0
  _tp_log "$h" "$p" "triage-park: $k parked (refused $r)"
  [ -x "$h/bin/lane-alert.sh" ] && "$h/bin/lane-alert.sh" --severity warn --id "triage-park-$p-$k" triage-park \
    "[triage-park] $p $k parked: call-guard refused $r times on an unchanged board (paid ${paid:-?}/${max:-?}, last outcome repeat). Unparks when the ticket changes." \
    >/dev/null 2>&1 </dev/null
  return 0
}

triage_park_tick_line() {
  local h="${1:-}" p="${2:-}" rows keys n m b
  [ -n "$h" ] && [ -n "$p" ] || return 0
  _tp_knobs "$p"
  [ "$_TP_AFTER" -gt 0 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  _tp_jobs "$h" && command -v triage_state_list >/dev/null 2>&1 || return 0
  rows=$(triage_state_list "$p" 2>/dev/null </dev/null) || return 0
  keys=$(printf '%s' "$rows" | jq -r 'if type == "array" then .[] else error("not a list") end | select(type == "object")
      | select(.verdict == "hold" and ((.reason // "") | startswith("call-guard-exhausted"))
               and .input_hash != null and .input_hash == .verdict_hash) | .ticket_key' 2>/dev/null) || return 0
  n=$(printf '%s' "$keys" | grep -c .)
  [ "$n" -gt 0 ] && _tp_log "$h" "$p" "triage-park: $n parked ($(printf '%s' "$keys" | tr '\n' ' ' | sed 's/ $//'))"
  for m in "$h/state/triage-park/$p/"*; do
    [ -f "$m" ] || continue
    b=${m##*/}
    grep -qxF -- "${b%.*}" <<<"$keys" || rm -f "$m"
  done
  return 0
}

triage_park_note() {
  local h="${1:-}" p="${2:-}" k="${3:-}" text="${4:-}" body
  [ -n "$p" ] && [ -n "$k" ] && [ -n "$text" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  _tp_jobs "$h" || return 1
  body=$(jq -nc --arg p "$p" --arg k "$k" --arg t "$text" '{project:$p, ticket_key:$k, last_decision:$t}' 2>/dev/null) || return 1
  _tp_put "$h" "$body"
}
