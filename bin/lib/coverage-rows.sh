#!/bin/bash
# bin/lib/coverage-rows.sh — the plan's `## Requirements coverage` table has at
# least one row per item of the ticket body's `## Scope` list, or the plan gate
# refuses it (prompts/plan-contract.md §4).
# Sourced, never executed: functions only, no output at source time.
#
# WHY. In 14 days the lead review blocked 88 tickets on wrong-data: ticket
# requirements the diff did not deliver, which the in-build review had
# approved. A plan whose coverage table skips a scope item builds a diff that
# skips it too, and nothing compared the table with the ticket.
#
# WHAT IS COUNTED (body only, never comments: a comment author must not be able
# to change a gate).
#   A scope item: a top-level list item (`1.`, `1)`, `-`, `*`, `+`, indent 0-1)
#     under a body heading whose text starts with the word "Scope" (any level,
#     any suffix such as "(files: ...)"), up to the next heading at the same or
#     a higher level. "Out of scope" and "Scoped notes" do not match. Lines in a
#     ``` or ~~~ fence do not count. Sub-bullets do not count.
#   A coverage row: under the plan's first heading that starts "Requirements
#     coverage", up to the next heading at the same or a higher level: a table
#     row that is not a `|---|` separator and not a table header (the row just
#     before a separator), or a top-level list item. Fenced lines do not count.
# The gate counts. Whether each row quotes the ticket and names a file and a
# test is the review's job, not this gate's.
#
# THE FUNCTIONS
#   cr_scope_count <ticket>          the item count; rc 1 and no output: no Scope
#   cr_plan_rows <plan>              the row count; `0` and rc 1: no section
#   cr_conf [project]                sets CR_ENFORCE (0|1) and CR_CONF_WARN
#   cr_plan_check <plan> <ticket>    the plan gate (rc 2 = refuse); no Scope: silent
#   cr_plan_note <ticket>            the planner's sentence, or nothing
#   cr_repair_note <plan-gate-out>   the repair pass's sentence, or nothing
#   cr_why_note <plan-gate-out>      the PLAN_MALFORMED reason clause, or nothing
# A <ticket> file is ticket-meta.json (its .body) or the body text itself.
#
# THE KNOB (catalog/lanes.d/_lib.coverage-rows.json, id coverage-rows), read
# through lib_env_apply, else the env, else CR_DEFAULT_ENFORCE below.

CR_DEFAULT_ENFORCE=1

# _cr_body <ticket> — the body text: `.body` of a JSON object, else the file.
_cr_body() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] && [ -f "$f" ] || return 1
  if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then jq -r '.body // ""' "$f" 2>/dev/null
  else cat "$f"; fi
}

# _cr_count <heading-regex> <mode> — markdown on stdin. Finds the first heading
# whose lowercased text matches the regex, and counts its items up to the next
# heading at the same or a higher level. mode scope: list items only. mode
# rows: table rows (no separator, no header) and list items. Prints the count,
# or nothing when no heading matched.
_cr_count() {
  tr -d '\r' | awk -v re="$1" -v mode="$2" '
    function flush(   i) {
      # A table row is a header when the line after it is a separator.
      for (i = 1; i <= nt; i++) if (!(tsep[i]) && !(i < nt && tsep[i + 1])) n++
      nt = 0
    }
    {
      line = $0
      t = line; sub(/^[ \t]*/, "", t)
      m = substr(t, 1, 3)
      if (m == "```" || m == "~~~") {
        if (fence == "") fence = m; else if (fence == m) fence = ""
        if (open) flush()
        next
      }
      if (fence != "") next
      if (line ~ /^#+[ \t]/) {
        match(line, /^#+/); lvl = RLENGTH
        if (open && lvl <= olvl) { flush(); open = 0; done = 1 }
        if (!open && !done) {
          h = line; sub(/^#+[ \t]*/, "", h); gsub(/[*_`]/, "", h); h = tolower(h)
          if (h ~ re) { open = 1; olvl = lvl; found = 1 }
        }
        next
      }
      if (!open) next
      if (mode == "rows" && line ~ /^[ \t]*\|/) {
        tsep[++nt] = (line ~ /^[ \t]*\|[ \t:|-]+$/)
        next
      }
      if (nt) flush()
      if (line ~ /^[ ]?([0-9]+[.)]|[-*+])[ \t]+/) n++
    }
    END { if (open) flush(); if (found) print n + 0 }'
}

cr_scope_count() {
  local b c
  b=$(_cr_body "${1:-}") || return 1
  c=$(_cr_count '^scope([^a-z]|$)' scope <<<"$b")
  [ -n "$c" ] || return 1
  echo "$c"
}

cr_plan_rows() {
  local c
  [ -r "${1:-}" ] || { echo 0; return 1; }
  c=$(_cr_count '^requirements coverage' rows < "$1")
  [ -n "$c" ] || { echo 0; return 1; }
  echo "$c"
}

# cr_conf [project] — CR_ENFORCE from COVERAGE_ROWS_ENFORCE: lib_env_apply in a
# subshell, then the env, then CR_DEFAULT_ENFORCE. A value that is not on/off
# enforces and sets CR_CONF_WARN.
cr_conf() {
  local p="${1:-${PROJECT:-}}" root e
  root="${HARNESS:-${H:-}}"
  CR_CONF_WARN=""
  e=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply coverage-rows "$p" >/dev/null 2>&1
    printf '%s' "${COVERAGE_ROWS_ENFORCE:-}"
  ) || e=""
  case "$(printf '%s' "${e:-$CR_DEFAULT_ENFORCE}" | tr 'A-Z' 'a-z')" in
    0|off|false|no) CR_ENFORCE=0 ;;
    1|on|true|yes) CR_ENFORCE=1 ;;
    *) CR_ENFORCE=1; CR_CONF_WARN="COVERAGE_ROWS_ENFORCE='$e' is not on/off, so it enforces" ;;
  esac
  return 0
}

cr_plan_check() {
  local plan="${1:-}" tk="${2:-}" items rows has=1 pfx
  if [ -z "$tk" ] || ! _cr_body "$tk" >/dev/null; then echo "PLAN_COVERAGE: unread"; return 0; fi
  items=$(cr_scope_count "$tk") || items=0
  # No Scope list: no line at all, so the gate output of every ticket without
  # one stays byte-identical (tests/plan-spec-trace.bh-6485-test.sh G7).
  [ "${items:-0}" = 0 ] && return 0
  rows=$(cr_plan_rows "$plan") || has=0
  if [ "$rows" -ge "$items" ]; then
    echo "PLAN_COVERAGE: ok ($rows row(s) for $items scope item(s))"; return 0
  fi
  cr_conf
  pfx="  UNTRACED: coverage — "
  [ "$CR_ENFORCE" = 0 ] && pfx="  NOTE: coverage (COVERAGE_ROWS_ENFORCE=0) — "
  if [ "$has" = 1 ]; then
    echo "${pfx}'## Requirements coverage' has $rows row(s), the ticket's Scope has $items item(s)"
  else
    echo "${pfx}no '## Requirements coverage' section, the ticket's Scope has $items item(s)"
  fi
  if [ "$CR_ENFORCE" = 0 ]; then echo "PLAN_COVERAGE: short (not enforced, COVERAGE_ROWS_ENFORCE=0)"; return 0; fi
  echo "PLAN_COVERAGE: short"
  return 2
}

cr_plan_note() {
  local n
  n=$(cr_scope_count "${1:-}" 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  printf ' REQUIREMENTS COVERAGE (BH-9441, prompts/plan-contract.md §4): the ticket'"'"'s Scope has %s item(s). '"'"'## Requirements coverage'"'"' needs at least %s rows, one per ticket noun, field and number, each quoting the ticket'"'"'s words and naming the file and the test that deliver it; bin/plan-gate.sh refuses a plan with fewer.' "$n" "$n"
}

cr_repair_note() {
  local g="${1:-}" l
  [ -r "$g" ] || return 0
  grep -q '^PLAN_COVERAGE: short$' "$g" 2>/dev/null || return 0
  l=$(sed -n 's/^  UNTRACED: coverage — //p' "$g" | head -1)
  printf ' REQUIREMENTS COVERAGE: the coverage table is short (%s). Add rows to '"'"'## Requirements coverage'"'"' until there is at least one row per Scope item of the ticket: each row quotes the ticket'"'"'s words and names the file and the test that deliver it; an item this plan does not deliver gets a row naming who does.' "$l"
}

cr_why_note() {
  local g="${1:-}" l r n
  [ -r "$g" ] || return 0
  grep -q '^PLAN_COVERAGE: short$' "$g" 2>/dev/null || return 0
  l=$(sed -n 's/^  UNTRACED: coverage — //p' "$g" | head -1)
  n=$(sed -n "s/.*the ticket's Scope has \([0-9]*\) item(s)\$/\1/p" <<<"$l")
  case "$l" in
    "no '## Requirements coverage'"*) r="no section" ;;
    *) r="$(sed -n 's/.* has \([0-9]*\) row(s),.*/\1/p' <<<"$l") row(s)" ;;
  esac
  printf 'the coverage table is still short (%s for %s scope item(s))' "$r" "${n:-?}"
}
