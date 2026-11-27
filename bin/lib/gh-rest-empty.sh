#!/bin/bash
# bin/lib/gh-rest-empty.sh — the empty-budget rule for gh_rest. Sourced by
# bin/lib/gh-rest-ledger.sh, never executed. Function definitions only: no
# `set -e`, no `exit`, no side effect at source time, no `gh` call. Every
# function answers 0 or 1 and never fails a caller.
#
# THE RULE. When the persisted reading of the bucket a GET is about to spend
# (state/gh-rest-ledger/.quota-<bucket>, written by _gh_quota_persist from every
# live answer's X-RateLimit-* headers) says remaining 0 with a reset that is
# still in the future, a TIMED lane sends no GET. GitHub would answer 403 to
# it: the call costs a request and a ledger row and returns nothing. gh_rest
# answers rc 75 with GH_REST_REASON=quota-reserve instead, before the request,
# and this file writes ONE line per lane process and reset window to
# logs/gh-rate.log.
#
# NOT REFUSED: a write (POST, PUT, PATCH, DELETE) or HEAD; a wake-started run
# (WAKE_LAUNCH=1); a shell outside any lane (no LANE_GATE_RUN); an unknown
# reading (no file, a torn file, no reset, a reset that has passed): unknown is
# never zero (the BH-1484 rule).
#
# THE SWITCH. The settings row `lane.<id>.gh_rest_empty_budget_gate` turns the
# rule off for one lane (`0`, `false`, `off` or `no`, any case). The env
# GH_REST_EMPTY_BUDGET_GATE wins over the row for one run. No row = on.

# gh_rest_empty_lane — the lane id of a timed run, or nothing.
gh_rest_empty_lane() {
  [ -n "${LANE_GATE_RUN:-}" ] || return 0
  [ "${WAKE_LAUNCH:-0}" = 1 ] && return 0
  printf '%s' "${LANE_GATE_RUN%%/*}"
  return 0
}

# _gh_empty_off_word <value> — rc 0 when the value turns the rule off.
_gh_empty_off_word() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    0|false|off|no) return 0 ;;
  esac
  return 1
}

# gh_rest_empty_switch <lane> — rc 0 = the rule is on for this lane.
# One jq per process per lane: the answer is memoised in a shell variable.
gh_rest_empty_switch() {
  local lane="${1:-}" f v
  if [ -n "${GH_REST_EMPTY_BUDGET_GATE:-}" ]; then
    _gh_empty_off_word "$GH_REST_EMPTY_BUDGET_GATE" && return 1
    return 0
  fi
  if [ "${_GH_EMPTY_SW_LANE:-}" = "$lane" ] && [ -n "${_GH_EMPTY_SW_VAL:-}" ]; then
    [ "$_GH_EMPTY_SW_VAL" = on ]; return $?
  fi
  v=""
  f="${HARNESS:-${H:-}}"
  if [ -n "$f" ] && [ -r "$f/state/settings-cache.json" ] && command -v jq >/dev/null 2>&1; then
    v=$(jq -r --arg k "lane.$lane.gh_rest_empty_budget_gate" \
      '(if ((.values // {}) | has($k)) then .values[$k] else ((.seeded // {})[$k]) end) | if . == null then empty else tostring end' "$f/state/settings-cache.json" 2>/dev/null) || v=""
  fi
  _GH_EMPTY_SW_LANE=$lane
  # Fallback when the row `lane.<id>.gh_rest_empty_budget_gate` is absent: ON
  # (the ticket: "on by default for all lanes").
  if _gh_empty_off_word "$v"; then _GH_EMPTY_SW_VAL=off; return 1; fi
  _GH_EMPTY_SW_VAL=on
  return 0
}

# _gh_empty_now — the clock, read once per call. GH_REST_EMPTY_NOW (digits) is
# the test clock seam.
_gh_empty_now() {
  case "${GH_REST_EMPTY_NOW:-}" in
    ''|*[!0-9]*) date -u +%s 2>/dev/null ;;
    *) printf '%s' "$GH_REST_EMPTY_NOW" ;;
  esac
}

# _gh_empty_reading — rc 0 when the bucket THIS shell's token spends from reads
# exactly 0 remaining with a reset in the future. Sets _GH_EMPTY_BUCKET and
# _GH_EMPTY_RESET. No jq: one `read` of a one-line file.
_gh_empty_reading() {
  local f rem lim rst now
  _GH_EMPTY_BUCKET=; _GH_EMPTY_RESET=
  command -v gh_quota_bucket >/dev/null 2>&1 && command -v _gh_led_dir >/dev/null 2>&1 || return 1
  _GH_EMPTY_BUCKET=$(GH_REST_QUOTA_RESOURCE='' gh_quota_bucket)
  [ -n "$_GH_EMPTY_BUCKET" ] || return 1
  f="$(_gh_led_dir)/.quota-$_GH_EMPTY_BUCKET"
  [ -r "$f" ] || return 1
  read -r rem lim rst _ < "$f" 2>/dev/null || return 1
  [ "${rem:-}" = 0 ] || return 1
  # The search API (limit 30 a minute) and code search (10) answer with their own
  # X-RateLimit-* headers, and _gh_quota_persist files them under the same bucket
  # as core. Only a reading with a core-sized limit can empty the core budget;
  # a small or unreadable limit is not core: unknown, so the GET is sent.
  case "${lim:-}" in ""|*[!0-9]*) return 1 ;; esac
  [ "$lim" -gt 100 ] || return 1
  case "${rst:-}" in ''|*[!0-9]*) return 1 ;; esac
  now=$(_gh_empty_now)
  case "${now:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rst" -gt "$now" ] || return 1
  _GH_EMPTY_RESET=$rst
  return 0
}

# gh_rest_budget_empty [path] — rc 0 when the next GET from this shell would be
# refused: a timed lane, the switch on, and the bucket reading empty. With a
# path and no token in scope, the token is picked the way _gh_quota_gate picks
# it, so the answer is about the bucket the call would spend. A lane calls this
# before an item to stop its tick at the first refusal.
gh_rest_budget_empty() {
  local lane _gre_tok GH_TOKEN="${GH_TOKEN:-}"
  lane=$(gh_rest_empty_lane)
  [ -n "$lane" ] || return 1
  gh_rest_empty_switch "$lane" || return 1
  if [ -n "${1:-}" ] && command -v gh_default_token_for_path >/dev/null 2>&1 \
     && _gre_tok=$(gh_default_token_for_path "$1"); then
    GH_TOKEN="$_gre_tok"
  fi
  _gh_empty_reading
}

# _gh_empty_gate <method> — called by _gh_quota_gate_decide after the gate has
# put this call's token in scope. rc 1 = refuse (and say so once), rc 0 = go on.
_gh_empty_gate() {
  local lane
  [ "${1:-}" = GET ] || return 0
  lane=$(gh_rest_empty_lane)
  [ -n "$lane" ] || return 0
  gh_rest_empty_switch "$lane" || return 0
  _gh_empty_reading || return 0
  _gh_empty_said "$lane" "$_GH_EMPTY_BUCKET" "$_GH_EMPTY_RESET"
  return 1
}

# _gh_empty_said <lane> <bucket> <reset> — ONE log line per lane, process and
# reset window. The marker `.empty-said.<lane>.<pid>` holds the reset it was
# said for, so the `$( )` subshells of one tick share it. On a new marker,
# markers older than GH_LEDGER_TTL_H hours (the ledger's retention knob,
# fallback 48, floor 1) are removed.
_gh_empty_said() {
  local lane="${1:-}" bucket="${2:-}" rst="${3:-}" dir mk old="" tmp iso ttl_h f now
  command -v _gh_led_dir >/dev/null 2>&1 || return 0
  dir=$(_gh_led_dir)
  mk="$dir/.empty-said.$(printf '%s' "$lane" | tr -c 'A-Za-z0-9_.-' '_').$$"
  [ -r "$mk" ] && read -r old _ < "$mk" 2>/dev/null
  [ "${old:-}" = "$rst" ] && return 0
  mkdir -p "$dir" "$(_gh_led_home)/logs" 2>/dev/null || return 0
  tmp="$mk.${BASHPID:-$$}.tmp"
  printf '%s\n' "$rst" > "$tmp" 2>/dev/null && mv -f "$tmp" "$mk" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  iso=$(date -u -d "@$rst" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$rst" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$rst")
  printf '%s [gh-empty-budget] lane=%s bucket=%s core remaining 0 until %s: GET refused before the request (no ledger row), pid %s\n' \
    "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$lane" "$bucket" "$iso" "$$" >> "$(_gh_led_home)/logs/gh-rate.log" 2>/dev/null
  ttl_h="${GH_LEDGER_TTL_H:-48}"
  case "$ttl_h" in ''|*[!0-9]*) ttl_h=48 ;; esac
  [ "$ttl_h" -ge 1 ] || ttl_h=1
  now=$(_gh_empty_now)
  case "${now:-}" in ''|*[!0-9]*) return 0 ;; esac
  for f in "$dir"/.empty-said.*; do
    [ -f "$f" ] && [ "$f" != "$mk" ] || continue
    command -v _gh_led_mtime >/dev/null 2>&1 || break
    [ "$(_gh_led_mtime "$f")" -lt $((now - ttl_h * 3600)) ] && rm -f "$f" 2>/dev/null
  done
  return 0
}
