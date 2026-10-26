#!/bin/bash
# tests/lib/tracker-contract-c12.bh-7920.sh — contract case C12 (BH-7920):
# tracker_list --state / --label / --since and the three row keys every
# adapter now prints (updatedAt, state, commentCount). Adapter-agnostic, like
# tests/lib/tracker-contract.sh; tests/tracker-list-filters.bh-7920-test.sh
# runs it once per adapter.
#
#   tracker_contract_c12 <adapter>
#
# The suite provides tc12_setup_<adapter with - as _>, which loads the adapter
# and its context, seeds the stub with five rows that the stub serves WHATEVER
# the request asks for (so the contract's own check is what is under test),
# and sets:
#   C12_OPEN      open, label ai-build, updated after C12_SINCE
#   C12_CLOSED    closed, label ai-build, updated after C12_SINCE
#   C12_OTHER     open, another label only, updated after C12_SINCE
#   C12_OLD       open, label ai-build, updated before C12_SINCE
#   C12_NODATE    open, label ai-build, no updated time at all
#   C12_SINCE     a UTC ISO time (YYYY-MM-DDTHH:MM:SSZ)
#   C12_OPEN_UPDATED  the updatedAt C12_OPEN must print (UTC, no fraction)
#   C12_OPEN_COMMENTS the commentCount C12_OPEN must print
#   C12_DROP_SINCE    optional: more ids --since must drop
# and these stub hooks:
#   c12_reqs      how many tracker requests the stub has received so far
#   c12_writes    the writes the stub received, one per line
# Counts go into TC_PASS / TC_FAIL (shared with tests/lib/tracker-contract.sh).

TC_PASS=${TC_PASS:-0}; TC_FAIL=${TC_FAIL:-0}
_c12_ok()  { TC_PASS=$((TC_PASS+1)); }
_c12_bad() { TC_FAIL=$((TC_FAIL+1)); echo "FAIL [${C12_A:-?}] C12$1"; }
_c12_ids() { jq -c '[.[].id] | sort' 2>/dev/null; }
_c12_has() { jq -e --arg i "$1" 'any(.[]; .id == $i)' >/dev/null 2>&1; }

tracker_contract_c12() {
  local C12_A="$1" out rc n0 i
  "tc12_setup_${C12_A//-/_}" || { _c12_bad " setup failed"; return 1; }

  # (a) the three new keys, with their types, on every row
  out=$(tracker_list --state all); rc=$?
  [ "$rc" = 0 ] && _c12_ok || _c12_bad "(a) --state all rc=$rc"
  printf '%s' "$out" | jq -e 'type == "array" and length >= 5 and all(.[];
      has("updatedAt") and has("state") and has("commentCount")
      and (.updatedAt == null or (.updatedAt | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")))
      and (.state == "open" or .state == "closed")
      and (.commentCount == null or (.commentCount | type == "number" and . >= 0 and . == floor)))' >/dev/null 2>&1 \
    && _c12_ok || _c12_bad "(a) every row carries updatedAt (UTC ISO or null), state (open|closed), commentCount (int or null): $out"
  [ "$(printf '%s' "$out" | jq -c --arg i "$C12_OPEN" '[.[] | select(.id == $i) | .updatedAt, .state, .commentCount]')" \
      = "$(jq -nc --arg u "$C12_OPEN_UPDATED" --argjson c "$C12_OPEN_COMMENTS" '[$u, "open", $c]')" ] \
    && _c12_ok || _c12_bad "(a) $C12_OPEN must print [$C12_OPEN_UPDATED, open, $C12_OPEN_COMMENTS]: $(printf '%s' "$out" | jq -c --arg i "$C12_OPEN" '.[] | select(.id == $i)')"
  [ "$(printf '%s' "$out" | jq -r --arg i "$C12_CLOSED" '.[] | select(.id == $i) | .state')" = closed ] \
    && _c12_ok || _c12_bad "(a) $C12_CLOSED must be state closed: $out"
  [ "$(printf '%s' "$out" | jq -r --arg i "$C12_NODATE" '.[] | select(.id == $i) | .updatedAt')" = null ] \
    && _c12_ok || _c12_bad "(a) $C12_NODATE has no updated time and must print updatedAt null: $out"

  # (b) --state open drops the closed row
  out=$(tracker_list --state open); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | _c12_has "$C12_OPEN" && ! printf '%s' "$out" | _c12_has "$C12_CLOSED" \
    && _c12_ok || _c12_bad "(b) --state open must keep $C12_OPEN and drop $C12_CLOSED (rc=$rc): $(printf '%s' "$out" | _c12_ids)"

  # (c) --label keeps only that label, compared case-insensitively
  out=$(tracker_list --label ai-build); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | _c12_has "$C12_OPEN" && ! printf '%s' "$out" | _c12_has "$C12_OTHER" \
    && _c12_ok || _c12_bad "(c) --label ai-build must drop $C12_OTHER (rc=$rc): $(printf '%s' "$out" | _c12_ids)"
  out=$(tracker_list --label AI-Build); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | _c12_has "$C12_OPEN" && ! printf '%s' "$out" | _c12_has "$C12_OTHER" \
    && _c12_ok || _c12_bad "(c) --label AI-Build must match ai-build case-insensitively (rc=$rc): $(printf '%s' "$out" | _c12_ids)"

  # (d) --since drops the old row and keeps the row we cannot date
  out=$(tracker_list --since "$C12_SINCE"); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | _c12_has "$C12_OPEN" && printf '%s' "$out" | _c12_has "$C12_NODATE" \
    && ! printf '%s' "$out" | _c12_has "$C12_OLD" \
    && _c12_ok || _c12_bad "(d) --since $C12_SINCE must keep $C12_OPEN and $C12_NODATE and drop $C12_OLD (rc=$rc): $(printf '%s' "$out" | _c12_ids)"
  for i in ${C12_DROP_SINCE:-}; do
    printf '%s' "$out" | _c12_has "$i" && _c12_bad "(d) --since $C12_SINCE must drop $i: $(printf '%s' "$out" | _c12_ids)" || _c12_ok
  done

  # (e) --state all keeps the closed row; the three flags combine
  out=$(tracker_list --state all --label ai-build); rc=$?
  [ "$rc" = 0 ] && printf '%s' "$out" | _c12_has "$C12_CLOSED" && ! printf '%s' "$out" | _c12_has "$C12_OTHER" \
    && _c12_ok || _c12_bad "(e) --state all --label ai-build must keep $C12_CLOSED (rc=$rc): $(printf '%s' "$out" | _c12_ids)"
  out=$(tracker_list --state open --label ai-build --since "$C12_SINCE"); rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | _c12_ids)" = "$(jq -nc --arg a "$C12_OPEN" --arg b "$C12_NODATE" '[$a, $b] | sort')" ] \
    && _c12_ok || _c12_bad "(e) all three flags must leave exactly $C12_OPEN and $C12_NODATE (rc=$rc): $(printf '%s' "$out" | _c12_ids)"

  # (f) refusals: rc 1, nothing printed, nothing sent
  n0=$(c12_reqs)
  _c12_refuse() {
    local o r
    o=$(tracker_list "$@" 2>/dev/null); r=$?
    [ "$r" = 1 ] && [ -z "$o" ] && _c12_ok || _c12_bad "(f) tracker_list $* must be rc 1 with nothing printed (rc=$r out=$o)"
  }
  _c12_refuse --state bogus
  _c12_refuse --state closed
  _c12_refuse --state
  _c12_refuse --since 2026-10-21
  _c12_refuse --since 2026-10-21T00:00:00+03:00
  _c12_refuse --label ""
  _c12_refuse --label 'ai"build'
  _c12_refuse --frob
  _c12_refuse open
  [ "$(c12_reqs)" = "$n0" ] && _c12_ok || _c12_bad "(f) a refused flag sent $(( $(c12_reqs) - n0 )) request(s)"
  out=$(tracker_list --since 2026-10-21 2>&1 >/dev/null)
  [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && _c12_ok || _c12_bad "(f) a refusal prints exactly one stderr line: [$out]"

  # (g) a list makes no write
  [ "$(c12_writes | grep -c .)" = 0 ] && _c12_ok || _c12_bad "(g) a list wrote: $(c12_writes)"
  return 0
}
