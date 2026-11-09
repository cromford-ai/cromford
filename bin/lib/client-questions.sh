#!/bin/bash
# shellcheck shell=bash
# bin/lib/client-questions.sh — the client-questions block a planner writes in
# plan.md when it stops on a question: check it, and render each question in
# the four-part form a client can answer with one word. Sourced, never run;
# defines functions only.
#
# The format. The FIRST fenced block in plan.md whose opener line is exactly
# ```client-questions holds a JSON array, one object per question:
#   [{"question": "...", "recommended": "...", "reasons": ["..."], "default": "..."}]
# The keys are exact and lowercase. Every field must be a non-blank string, and
# `reasons` an array with at least one non-blank string. The "1 to 3 reasons"
# is prompt guidance (prompts/TEMPLATE.md), not a code cap.
#
#   cq_block <plan.md>    prints the block body
#                         rc 0 found, rc 3 no block or no file, rc 5 no closing fence
#   cq_check <plan.md>    rc 0 valid, rc 3 no block, rc 5 refused (the first
#                         reason on stderr). The body goes through
#                         bin/transcript-scrub.sh first; no scrubber or a
#                         failed scrub is rc 5 (fail closed).
#   cq_render <plan.md>   cq_check, then per question, a blank line between:
#                           **<i>. <question>**
#                           Recommended: <recommended>
#                           Why: <the reasons, on one line>
#                           If we do not hear from you<, default | default as written>
#                         rc as cq_check; nothing on stdout on a refusal.
#
# Callers: bin/lib/plan-blocked.sh pb_notice (the builder's PLAN_BLOCKED
# comment) and bin/client-questions.sh (the CLI the board sweeps run).

cq_block() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] || return 3
  awk '
    st == 0 && /^```client-questions[[:space:]]*$/ { st = 1; next }
    st == 1 && /^```[[:space:]]*$/ { st = 2; exit }
    st == 1 { L[++n] = $0 }
    END {
      if (st == 0) exit 3
      if (st == 1) exit 5
      for (i = 1; i <= n; i++) print L[i]
    }' "$f"
}

# The first reason a block is refused, or nothing. Input: the slurped body (-s).
_CQ_CHECK_JQ='
  def blank: (type != "string") or (gsub("\\s"; "") == "");
  if length != 1 then "the client-questions block is not valid JSON"
  else .[0]
  | if type != "array" then "the client-questions block is not a JSON array"
    elif length == 0 then "the client-questions block has no questions"
    else (first(to_entries[] | (.key + 1) as $n | .value as $q
           | if ($q | type) != "object" then "question \($n) is not an object"
             elif ($q.question | blank) then "question \($n) has no question text"
             elif ($q.recommended | blank) then "question \($n) has no recommended answer"
             elif (($q.reasons | type) != "array") or ([$q.reasons[] | select(blank | not)] | length) == 0
               then "question \($n) has no reason"
             elif ($q.default | blank) then "question \($n) has no default for no reply"
             else empty end) // "")
    end
  end'

# cq_check sets _CQ_SRC (the scrubbed body) in the caller's scope for cq_render.
cq_check() {
  local f="${1:-}" root="${HARNESS:-${H:-}}" body rc why
  body=$(cq_block "$f"); rc=$?
  [ "$rc" = 3 ] && return 3
  [ "$rc" = 0 ] || { echo "the client-questions block has no closing fence" >&2; return 5; }
  [ -n "$root" ] && [ -x "$root/bin/transcript-scrub.sh" ] || { echo "no scrubber" >&2; return 5; }
  _CQ_SRC=$(printf '%s\n' "$body" | "$root/bin/transcript-scrub.sh" 2>/dev/null) || { echo "no scrubber" >&2; return 5; }
  command -v jq >/dev/null 2>&1 || { echo "jq is missing" >&2; return 5; }
  why=$(printf '%s\n' "$_CQ_SRC" | jq -rs "$_CQ_CHECK_JQ" 2>/dev/null) || why="the client-questions block is not valid JSON"
  [ -z "$why" ] || { printf '%s\n' "$why" >&2; return 5; }
  return 0
}

cq_render() {
  local _CQ_SRC="" rc
  cq_check "${1:-}"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  printf '%s\n' "$_CQ_SRC" | jq -r '
    def one: tostring | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    def nodefault:
      if test("^if we do not hear from you"; "i") then .
      elif (.[1:2] | test("^[a-z]$")) then "If we do not hear from you, " + (.[0:1] | ascii_downcase) + .[1:]
      else "If we do not hear from you, " + . end;
    to_entries | map(.key as $k | .value
      | "**\($k + 1). \(.question | one)**\n"
        + "Recommended: \(.recommended | one)\n"
        + "Why: \([.reasons[] | select(type == "string") | one | select(. != "")] | join(" "))\n"
        + (.default | one | nodefault))
    | join("\n\n")'
}
