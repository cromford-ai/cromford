#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/unreadable.sh — the unblock tick's fold of U12 escalations
# whose GitHub inputs were not read (BH-9446). Sourced by bin/unblock.sh,
# never run; nothing here runs on source.
#
# WHY. When GitHub does not answer, a PR record carries null inputs, no rule
# can match it, and U12 made one card per PR on the first tick (#8908: four
# null inputs, one card). A read failure is not a decision for a person.
#
#   ubu_fold <project> <decisions file>
#     A decision is HELD when decision is escalate, rule_id is U12 or null,
#     its record (.evidence) is not kind queue-unreadable, source-unreadable
#     or inputs-unreadable, and the record has an unread GitHub input:
#       mergeable_state, checks or changes_requested_open present and null;
#       or a PR subject (subject_kind pr, or a subject ending #<n>) whose head
#       is not 40 hex.
#     Held decisions are grouped by repo. Per repo, the counter file
#     $HARNESS/state/unblock-unreadable/<project>-<owner>__<name> holds
#     `<ticks> <since_epoch> <project> <repo>`; ticks = the last value + 1
#     (no file = 0). The counter is written BEFORE the decisions file changes.
#       ticks < UNBLOCK_UNREADABLE_CARD_AFTER_TICKS: the held decisions are
#         removed (no claim, no card) and one line is logged:
#         `wait inputs-unreadable <repo>: <k> PR(s) (<fields>) unread, tick <t> of <N>; no card`
#       ticks >= N: the held decisions are removed and ONE record
#         {family queue, kind inputs-unreadable, subject source:pr-inputs:<repo>,
#          subject_kind lane, source pr-inputs, prs, fields, ticks, since,
#          stall_at, day, unknown [pr-inputs]} goes through ub_rules_eval; its
#         U12 decision is added. The key does not change from tick to tick,
#         so the claim makes one card per source.
#     A repo of this project with a counter file and no held decision this
#     tick: the file is deleted (the "in a row" reset).
#     FAIL TOWARD A CARD: a counter that cannot be written, or no
#     ub_rules_eval, keeps that repo's decisions as they were (one log line).
#     Prints the number of decisions it removed. rc 0 always.
#
# Knob (catalog/lanes.d/unblock.knobs.d/):
#   UNBLOCK_UNREADABLE_CARD_AFTER_TICKS (3, 1..100)
#   UB_NOW  epoch seconds, the clock seam for tests (act.sh's).
#
# NO ROOT DEFAULT (D43): the root is $HARNESS, then $H; with neither the fold
# changes nothing and prints 0.

_ubu_log() {
  printf '%s %s\n' "$(date -u -d "@$2" +%Y-%m-%dT%H:%M:%SZ)" "$3" >> "$1/logs/unblock.log" 2>/dev/null || true
}

ubu_fold() {
  local proj="${1:-}" f="${2:-}" h n now dir tmp repo rf prev since ticks k fields rec dec held=0 keep
  local -A seen=()
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -n "$proj" ] && [ -f "$f" ] || { echo 0; return 0; }
  # Fallback 3 = the knob default
  # (catalog/lanes.d/unblock.knobs.d/UNBLOCK_UNREADABLE_CARD_AFTER_TICKS.json).
  n="${UNBLOCK_UNREADABLE_CARD_AFTER_TICKS:-3}"
  if ! [[ $n =~ ^[1-9][0-9]{0,2}$ ]] || [ "$n" -gt 100 ]; then n=3; fi
  now="${UB_NOW:-}"; [[ $now =~ ^[0-9]+$ ]] || now=$(date -u +%s)
  mkdir -p "$h/logs" 2>/dev/null
  dir="$h/state/unblock-unreadable"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/ubu.XXXXXX") || { echo 0; return 0; }
  # One pass: each line is kept as it is ({t: "k"}) or held ({t: "h"}).
  jq -cR '
    def unread: [
      (if has("mergeable_state") and .mergeable_state == null then "mergeable_state" else empty end),
      (if has("checks") and .checks == null then "checks" else empty end),
      (if has("changes_requested_open") and .changes_requested_open == null then "changes_requested_open" else empty end),
      (if (((.subject_kind // "") == "pr") or ((.subject // "") | tostring | test("#[0-9]+$")))
          and (((.head // "") | tostring | test("^[0-9a-f]{40}$")) | not) then "head" else empty end)];
    . as $raw | (fromjson? // null) as $d
    | if ($d | type) == "object" and $d.decision == "escalate" and ($d.rule_id == "U12" or $d.rule_id == null)
         and ($d.evidence | type) == "object"
         and (($d.evidence.kind // "") | IN("queue-unreadable", "source-unreadable", "inputs-unreadable") | not)
         and (($d.evidence | unread) | length) > 0
         and ((($d.repo // $d.evidence.repo // "") | tostring) | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
      then {t: "h", repo: ($d.repo // $d.evidence.repo), subject: ($d.subject // $d.evidence.subject // null),
            pr: ($d.pr // $d.evidence.pr // null), fields: ($d.evidence | unread), l: $raw}
      else {t: "k", l: $raw} end' "$f" > "$tmp/tagged" 2>/dev/null || { rm -rf "$tmp"; echo 0; return 0; }
  jq -r 'select(.t == "k") | .l' "$tmp/tagged" > "$tmp/out" 2>/dev/null || { rm -rf "$tmp"; echo 0; return 0; }
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    seen[$repo]=1
    rf="$dir/$proj-${repo//\//__}"
    prev=0 since=$now
    if [ -f "$rf" ]; then
      read -r prev since _ < "$rf" 2>/dev/null
      [[ $prev =~ ^[0-9]+$ ]] || prev=0
      [[ $since =~ ^[0-9]+$ ]] || since=$now
    fi
    ticks=$((prev + 1))
    jq -c --arg r "$repo" 'select(.t == "h" and .repo == $r)' "$tmp/tagged" 2>/dev/null > "$tmp/held" || true
    k=$(grep -c . "$tmp/held")
    fields=$(jq -sr '[.[].fields[]] | unique | join(",")' "$tmp/held" 2>/dev/null)
    keep=0
    if ! { mkdir -p "$dir" 2>/dev/null && printf '%s %s %s %s\n' "$ticks" "$since" "$proj" "$repo" > "$rf.tmp" 2>/dev/null \
           && mv "$rf.tmp" "$rf" 2>/dev/null; }; then
      rm -f "$rf.tmp" 2>/dev/null
      _ubu_log "$h" "$now" "inputs-unreadable $repo: counter not written ($rf); $k decision(s) kept as cards"
      keep=1
    elif [ "$ticks" -lt "$n" ]; then
      _ubu_log "$h" "$now" "wait inputs-unreadable $repo: $k PR(s) ($fields) unread, tick $ticks of $n; no card"
    elif ! declare -F ub_rules_eval >/dev/null; then
      _ubu_log "$h" "$now" "inputs-unreadable $repo: no ub_rules_eval; $k decision(s) kept as cards"
      keep=1
    else
      rec=$(jq -sc --arg p "$proj" --arg r "$repo" --argjson t "$ticks" --argjson s "$since" --argjson now "$now" '
        ($s | todate) as $si
        | {family: "queue", kind: "inputs-unreadable", project: $p, repo: $r, subject: ("source:pr-inputs:" + $r),
           subject_kind: "lane", source: "pr-inputs", prs: ([.[] | (.pr // .subject)] | unique),
           fields: ([.[].fields[]] | unique), ticks: $t, since: $si, stall_at: $si, day: (($now | todate)[0:10]),
           truncated: false, unknown: ["pr-inputs"]}' "$tmp/held" 2>/dev/null)
      dec=""
      [ -n "$rec" ] && dec=$(ub_rules_eval <<<"$rec" 2>/dev/null)
      if [ -n "$dec" ]; then
        printf '%s\n' "$dec" >> "$tmp/out"
        _ubu_log "$h" "$now" "inputs-unreadable $repo: $k PR(s) ($fields) unread for $ticks ticks; one card for the source"
      else
        _ubu_log "$h" "$now" "inputs-unreadable $repo: the source record made no decision; $k decision(s) kept as cards"
        keep=1
      fi
    fi
    if [ "$keep" = 1 ]; then jq -r '.l' "$tmp/held" >> "$tmp/out"; else held=$((held + k)); fi
  done < <(jq -r 'select(.t == "h") | .repo' "$tmp/tagged" 2>/dev/null | sort -u)
  # The "in a row" reset: a repo of this project with no held decision now.
  for rf in "$dir/$proj-"*; do
    [ -f "$rf" ] || continue
    read -r _ _ k repo < "$rf" 2>/dev/null
    [ "$k" = "$proj" ] && [ -n "$repo" ] || continue
    [ -n "${seen[$repo]+x}" ] || rm -f "$rf"
  done
  [ "${#seen[@]}" -gt 0 ] && mv "$tmp/out" "$f"
  rm -rf "$tmp"
  echo "$held"
  return 0
}
