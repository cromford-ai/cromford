#!/bin/bash
# bin/lib/perf-plan-rule.sh — a perf/cost ticket's plan states a target metric
# and an outcome replay (prompts/plan-contract.md §16). Sourced, never executed.
# Which tickets are perf is the contract bin/lib/perf-ticket.sh (pt_classify,
# pt_parse_target) and its catalog; this file only uses it. No contract lib on
# the box: this file defines nothing, so there is no rule and no check.
#
# pt_replay_n
#   How many recent real inputs the outcome replay covers: the knob
#   OUTCOME_REPLAY_N (lib_env_apply perf-ticket, then env), else 50. A value
#   that is not an integer in 5..500 is 50 plus one stderr line. Always rc 0.
# pt_plan_rule <ticket-file> <title> <labels-csv>
#   The plan-prompt paragraph when pt_classify says perf, else nothing. rc 0.
# pt_build_perf <build-dir>
#   Reads <build-dir>/ticket-meta.json once and sets PT_TITLE, PT_LABELS,
#   PT_BODY (ticket-body.md, else a pt-ticket-body.md written from the meta),
#   PT_EVIDENCE (pt_classify's own line) and PLAN_GATE_PERF (1 = perf, else 0).
# pt_plan_check <plan.md>
#   Active when PLAN_GATE_PERF=1 or the plan has a `Target metric` heading
#   (outside fences). Then the plan needs a `Target metric: <id> from <n> to
#   <n>` line with from != to, and ONE `## Acceptance tests` item that names
#   the outcome replay, the top miss reasons and a hit rate (fenced lines do
#   not count). Prints one `  UNTRACED: outcome replay — <gap>` line per gap,
#   then `PLAN_OUTCOME_REPLAY: ok | missing | n/a`. rc 2 on missing, else 0.
# pt_repair_note <gate-out>
#   The repair-pass sentence when a bin/plan-gate.sh output has outcome-replay
#   gaps, else nothing.
# shellcheck shell=bash

[ -n "${_PPR_LIB_LOADED:-}" ] && return 0
_PPR_LIB_LOADED=1
_PPR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
command -v pt_classify >/dev/null 2>&1 || . "$_PPR_DIR/perf-ticket.sh" 2>/dev/null || return 0
command -v pt_classify >/dev/null 2>&1 || return 0

pt_replay_n() {
  local v="" lib="$_PPR_DIR"
  if [ -n "${HARNESS:-${H:-}}" ]; then
    v=$(
      command -v lib_env_apply >/dev/null 2>&1 || . "$lib/lane-gate.sh" >/dev/null 2>&1
      lib_env_apply perf-ticket >/dev/null 2>&1
      printf '%s' "${OUTCOME_REPLAY_N:-}"
    ) 2>/dev/null
  else
    v=${OUTCOME_REPLAY_N:-}
  fi
  [ -n "$v" ] || { echo 50; return 0; }
  if [[ ! "$v" =~ ^[0-9]+$ ]] || [ "${#v}" -gt 9 ] || [ "$((10#$v))" -lt 5 ] || [ "$((10#$v))" -gt 500 ]; then
    echo "perf-plan-rule: OUTCOME_REPLAY_N='$v' is not an integer in 5..500, using 50" >&2
    echo 50; return 0
  fi
  echo "$((10#$v))"
}

pt_plan_rule() {
  local out ev
  out=$(pt_classify "${1:-}" "${2:-}" "${3:-}" 2>/dev/null) || return 0
  ev=${out#perf }
  printf "PERF/COST TICKET (prompts/plan-contract.md §16; classifier said %s): this plan MUST (1) carry a '## Target metric' section with the line 'Target metric: <metric-id> from <current number> to <target number> [<unit>]' (id lower-case a-z0-9-, from and to different numbers); (2) carry an '## Acceptance tests' item for an outcome replay over the last %s real inputs that reports the metric and the top miss reasons; (3) in that same item, name a hit rate for every fallback or escalation path the change adds or keeps; (4) say that the PR body reports the result in the '## Outcome replay' section, which starts with the same 'Target metric:' line and a 'measured: <number>' line. bin/plan-gate.sh refuses a perf plan without (1) to (3). " \
    "$ev" "$(pt_replay_n)"
}

pt_build_perf() {
  local b="${1:-}" meta
  meta="$b/ticket-meta.json"
  PT_TITLE=""; PT_LABELS=""; PT_EVIDENCE=""; PLAN_GATE_PERF=0; PT_BODY="$b/ticket-body.md"
  if [ -s "$meta" ]; then
    PT_TITLE=$(jq -r '.title // ""' "$meta" 2>/dev/null)
    PT_LABELS=$(jq -r '[.labels[]?.name] | join(",")' "$meta" 2>/dev/null)
    if [ ! -s "$PT_BODY" ]; then
      PT_BODY="$b/pt-ticket-body.md"
      jq -r '.body // ""' "$meta" > "$PT_BODY" 2>/dev/null
    fi
  fi
  PT_EVIDENCE=$(pt_classify "$PT_BODY" "$PT_TITLE" "$PT_LABELS" 2>/dev/null) && PLAN_GATE_PERF=1
  [ "$PLAN_GATE_PERF" = 1 ] || PT_EVIDENCE=""
  return 0
}

pt_repair_note() {
  grep -q '^  UNTRACED: outcome replay — ' "${1:-/dev/null}" 2>/dev/null || return 0
  printf " This is a perf/cost plan (prompts/plan-contract.md §16): add a '## Target metric' section with 'Target metric: <id> from <n> to <n>' (from and to differ), and one '## Acceptance tests' item that names the outcome replay, the top miss reasons and a hit rate for each fallback or escalation path."
}

pt_plan_check() {
  local plan="${1:-}" active=0 tgt id from to bad=0
  [ -r "$plan" ] || { echo "PLAN_OUTCOME_REPLAY: n/a"; return 0; }
  [ "${PLAN_GATE_PERF:-0}" = 1 ] && active=1
  if [ "$active" = 0 ] && awk '
      /^[ \t]*(```|~~~)/ { f = 1 - f; next }
      !f && tolower($0) ~ /^#+[ \t]+target metric/ { found = 1; exit }
      END { exit !found }' "$plan"; then
    active=1
  fi
  [ "$active" = 1 ] || { echo "PLAN_OUTCOME_REPLAY: n/a"; return 0; }
  if tgt=$(pt_parse_target "$plan"); then
    read -r id from to <<<"$tgt"
    if awk -v a="$from" -v b="$to" 'BEGIN { exit !(a + 0 == b + 0) }'; then
      echo "  UNTRACED: outcome replay — Target metric $id from $from to $to has no direction (from equals to)"; bad=1
    fi
  else
    echo "  UNTRACED: outcome replay — no 'Target metric: <id> from <n> to <n>' line"; bad=1
  fi
  # The acceptance items: a list line at indent 0-3 opens one; its continuation
  # and nested lines belong to it until the next such line or any heading.
  awk '
    function flush() {
      if (cur == "") return
      t = tolower(cur); cur = ""
      if (t !~ /outcome[ -]replay/) return
      nr++; s = 1 + (t ~ /top miss/) + (t ~ /hit rate/)
      if (s > best) { best = s; bm = (t ~ /top miss/); bh = (t ~ /hit rate/) }
    }
    {
      line = $0
      if (line ~ /^[ \t]*(```|~~~)/) { f = 1 - f; next }
      if (f) next
      if (line ~ /^#+[ \t]/) {
        match(line, /^#+/); lvl = RLENGTH
        h = tolower(line); sub(/^#+[ \t]*/, "", h); gsub(/\*/, "", h)
        if (inat && lvl <= atlvl) { flush(); inat = 0 }
        if (!inat && h ~ /^acceptance tests/) { inat = 1; atlvl = lvl; next }
        if (inat) flush()
        next
      }
      if (!inat) next
      if (line ~ /^(   |  | )?([-*+]|[0-9]+[.)])[ \t]+/) { flush(); cur = line; next }
      if (cur != "") cur = cur " " line
    }
    END {
      flush()
      if (!nr) { print "  UNTRACED: outcome replay — no \047## Acceptance tests\047 item names an outcome replay"; exit 2 }
      if (best == 3) exit 0
      if (!bm) print "  UNTRACED: outcome replay — the outcome-replay acceptance item does not name the top miss reasons"
      if (!bh) print "  UNTRACED: outcome replay — the outcome-replay acceptance item does not name a hit rate"
      exit 2
    }' "$plan" || bad=1
  if [ "$bad" = 1 ]; then echo "PLAN_OUTCOME_REPLAY: missing"; return 2; fi
  echo "PLAN_OUTCOME_REPLAY: ok"
}
