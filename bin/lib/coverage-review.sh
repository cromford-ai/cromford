#!/bin/bash
# bin/lib/coverage-review.sh — the in-build general review runs the lead-review
# checklist (prompts/lead-review-checklist.md) and answers the plan's
# `## Requirements coverage` table row by row. A row the diff does not deliver
# turns an APPROVE in review.md into a BLOCK, so the fix round runs inside the
# build, where a fix pass is cheap.
# Sourced, never executed: functions only, no output at source time.
#
# WHY. In 14 days the lead review blocked 88 tickets on wrong-data: ticket
# requirements the diff did not deliver, which the in-build review had
# approved. The checklist reached only the lead lanes, after the PR existed.
#
# THE ROWS are the rows bin/lib/coverage-rows.sh counts for the plan gate
# (cr_plan_row_list), numbered R1..Rn in plan order. One definition of a row.
#
# THE ROW LINE the reviewer writes, one per plan row, at the start of a line,
# outside any code fence or quote, above its TIER and VERDICT lines:
#   COVERAGE-ROW: R<n> | <requirement> | <status> | <evidence> [| <class>]
# status: delivered (evidence = file:line), missing, contradicts, or elsewhere
# (evidence = the ticket or slice that delivers it). There is no partial: a row
# delivered in part is split, and the undelivered part is missing. class:
# wrong-data (the default) or core-flow-broken.
#
# THE FUNCTIONS
#   cv_conf [project]                  the knobs (CV_* variables)
#   cv_review_note <plan> <names>      the reviewer's brief; nothing: no rows
#   cv_rereview_note <plan>            "re-emit the rows for this head"
#   cv_judge <review> <plan>           the rule over the latest pass
#   cv_enforce <review> <plan>         APPROVE -> BLOCK on an undelivered row
# <names> is the output of `git diff --name-only <base>...HEAD`.
#
# THE KNOBS (catalog/lanes.d/_lib.coverage-review.json, id coverage-review),
# read through lib_env_apply, else the env, else the CV_DEFAULT_* values below.

CV_DEFAULT_ENFORCE=1
CV_DEFAULT_ROWS_MAX=40
CV_DEFAULT_CHECKLIST_MAX_BYTES=16000

_cv_lib_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd); }
declare -F cr_plan_row_list >/dev/null 2>&1 || . "$(_cv_lib_dir)/coverage-rows.sh" 2>/dev/null

# The row format, ONE definition: the note shows it and cv_judge parses it.
CV_ROW_FORMAT='COVERAGE-ROW: R<n> | <requirement> | <delivered|missing|contradicts|elsewhere> | <file:line, or the ticket or slice for elsewhere> [| wrong-data|core-flow-broken]'
CV_ROW_EXAMPLE='COVERAGE-ROW: R1 | the rows screen lists the rows | delivered | src/app/rows/page.tsx:12'

# _cv_int <var> <value> <default> <min> <max> — a whole number in range, else the
# default with a warning in CV_CONF_WARN (never clamped).
_cv_int() {
  local v="${2:-}"
  case "$v" in
    ''|*[!0-9]*)
      [ -n "$v" ] && CV_CONF_WARN="${CV_CONF_WARN:+$CV_CONF_WARN; }$1='$v' is not a whole number"
      printf -v "$1" '%s' "$3" ;;
    *) if [ "$((10#$v))" -lt "$4" ] || [ "$((10#$v))" -gt "$5" ]; then
         CV_CONF_WARN="${CV_CONF_WARN:+$CV_CONF_WARN; }$1='$v' is outside $4-$5"; printf -v "$1" '%s' "$3"
       else printf -v "$1" '%s' "$((10#$v))"; fi ;;
  esac
}

# cv_conf [project] — sets CV_ENFORCE (0|1), CV_ROWS_MAX, CV_CHECKLIST_MAX and
# CV_CONF_WARN. The knob rows come through lib_env_apply in a subshell, so a
# registry that fails closed cannot end the caller; then the env; then the
# CV_DEFAULT_* values. A bad ENFORCE value enforces.
cv_conf() {
  local p="${1:-${PROJECT:-}}" root out e r c
  root="${HARNESS:-${H:-}}"
  CV_CONF_WARN=""
  out=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply coverage-review "$p" >/dev/null 2>&1
    printf '%s\037%s\037%s\n' "${COVERAGE_REVIEW_ENFORCE:-}" "${COVERAGE_REVIEW_ROWS_MAX:-}" "${COVERAGE_REVIEW_CHECKLIST_MAX_BYTES:-}"
  ) || out=""
  IFS=$'\037' read -r e r c <<<"$out"
  case "$(printf '%s' "${e:-$CV_DEFAULT_ENFORCE}" | tr 'A-Z' 'a-z')" in
    0|off|false|no) CV_ENFORCE=0 ;;
    1|on|true|yes) CV_ENFORCE=1 ;;
    *) CV_ENFORCE=1; CV_CONF_WARN="COVERAGE_REVIEW_ENFORCE='$e' is not on/off, so it enforces" ;;
  esac
  _cv_int CV_ROWS_MAX "${r:-}" "$CV_DEFAULT_ROWS_MAX" 1 200
  _cv_int CV_CHECKLIST_MAX "${c:-}" "$CV_DEFAULT_CHECKLIST_MAX_BYTES" 0 65536
  return 0
}

# _cv_log <line> — one pipeline.log line when the caller has a build dir.
_cv_log() {
  [ -n "${BUILD:-}" ] && [ -d "$BUILD" ] || return 0
  printf '%s [%s/%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PROJECT:-?}" "${KEY:-?}" "$1" >> "$BUILD/pipeline.log" 2>/dev/null
  return 0
}

# _cv_checklist — the version line and the numbered items of the lead-review
# checklist (from the first `1. ` line up to `## Changes`), or one CHECKLIST:
# line that names the file when it is unreadable or over CV_CHECKLIST_MAX.
_cv_checklist() {
  local root f v items n
  root="${HARNESS:-${H:-}}"
  f="${root:+$root/}prompts/lead-review-checklist.md"
  if [ -z "$root" ] || [ ! -r "$f" ]; then printf 'CHECKLIST: could not read %s\n' "$f"; return 0; fi
  v=$(grep -m1 '^Checklist-Version:' "$f")
  items=$(awk '/^## Changes/{exit} /^1\. /{f=1} f' "$f")
  n=$(printf '%s\n' "$items" | wc -c | tr -d ' ')
  if [ -z "$items" ] || [ "$CV_CHECKLIST_MAX" = 0 ] || [ "$n" -gt "$CV_CHECKLIST_MAX" ]; then
    printf '%s\nCHECKLIST: read %s yourself (its items are not inlined: %s bytes, cap COVERAGE_REVIEW_CHECKLIST_MAX_BYTES=%s)\n' "${v:-Checklist-Version: ?}" "$f" "$n" "$CV_CHECKLIST_MAX"
    return 0
  fi
  printf '%s\n%s\n' "${v:-Checklist-Version: ?}" "$items"
}

cv_review_note() {
  local plan="${1:-}" names="${2:-}" rows i=0 row toks t hit
  rows=$(cr_plan_row_list "$plan" 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  cv_conf
  printf 'Run the lead-review checklist below on this diff, item by item. The lead review runs it again after the PR opens; a finding it would block on is cheaper to fix here. An item whose input section this build does not have (## Ticket thread, ## Rules pack, ## Conflict hotspots, ## Interface callers, ## Main E2E) is judged from the diff, plan.md and $BUILD/ticket-meta.json, or is n/a.\n'
  _cv_checklist
  printf 'THE COVERAGE ROWS. plan.md'"'"'s ## Requirements coverage table has the rows R1..Rn below. For EVERY row write one line at the start of a line, outside any code fence or quote, above your TIER and VERDICT lines:\n%s\nExample: %s\nA delivered row names the file:line that delivers it on this head. An elsewhere row names the ticket or slice that delivers it. A row delivered only in part is split into two lines: the delivered part, and the undelivered part as missing. A missing or contradicts row is [BLOCK wrong-data], or [BLOCK core-flow-broken] when you write that class in the fifth column. The harness reads these lines mechanically after your verdict, so a row with no line is a BLOCK even when your verdict says APPROVE.\n' "$CV_ROW_FORMAT" "$CV_ROW_EXAMPLE"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    i=$((i + 1))
    if [ "$i" -gt "$CV_ROWS_MAX" ]; then continue; fi
    printf 'R%s: %s\n' "$i" "$row"
    toks=$(grep -oE '`[^`]+`' <<<"$row" | tr -d '`' | grep -E '/|\.[A-Za-z0-9]+$' | grep -v '[[:space:]]')
    [ -n "$toks" ] || continue
    hit=0
    while IFS= read -r t; do
      [ -n "$names" ] && [ -r "$names" ] && grep -qxF -- "$t" "$names" && { hit=1; break; }
    done <<<"$toks"
    [ "$hit" = 1 ] || printf 'NOT IN DIFF: R%s names %s; the diff does not change them\n' "$i" "$(paste -sd' ' - <<<"$toks")"
  done <<<"$rows"
  [ "$i" -gt "$CV_ROWS_MAX" ] && printf 'NOT JUDGED: R%s..R%s (over COVERAGE_REVIEW_ROWS_MAX=%s)\n' "$((CV_ROWS_MAX + 1))" "$i" "$CV_ROWS_MAX"
  return 0
}

cv_rereview_note() {
  local n
  n=$(cr_plan_row_list "${1:-}" 2>/dev/null | grep -c .)
  [ "${n:-0}" -gt 0 ] 2>/dev/null || return 0
  printf ' COVERAGE REVIEW: plan.md has %s coverage row(s), R1..R%s. Re-emit the WHOLE COVERAGE-ROW block for the CURRENT head, one line per row, in the form %s, above the TIER line. Rows from an earlier pass are not read, so a row with no line in this pass is a BLOCK.' "$n" "$n" "$CV_ROW_FORMAT"
}

# cv_judge <review> <plan> — the rule over the LATEST pass: `SKIP` (no verdict
# line), `OK`, or one `BLOCK<TAB><class><TAB>R<n> <requirement>: <why>` line per
# reason. The latest pass is the lines between the previous verdict line and the
# last one, fenced lines skipped. A last verdict that the spec trace restated
# (`SPEC-TRACE-GATE: ok (...)` just before it) judges the pass before it.
cv_judge() {
  local rf="${1:-}" plan="${2:-}" rows
  [ -r "$rf" ] && [ -f "$rf" ] || return 1
  rows=$(cr_plan_row_list "$plan" 2>/dev/null) || return 1
  cv_conf
  CV_ROWS="$rows" awk -v max="$CV_ROWS_MAX" '
    function trim(s) { gsub(/^[ \t`*]+|[ \t`*.]+$/, "", s); return s }
    function verdict(l) {
      return l ~ /^[ \t]*(#+[ \t]*)?(\*\*|__)?VERDICT(\*\*|__)?:?(\*\*|__)?[ \t]*(\*\*|__|`)?(APPROVE|BLOCK)([^A-Za-z0-9_-]|$)/
    }
    function add(cls, k, why) { out[++no] = "BLOCK\t" cls "\tR" k " " substr(R[k], 1, 80) ": " why }
    BEGIN { nr = split(ENVIRON["CV_ROWS"], R, "\n"); while (nr > 0 && R[nr] == "") nr--; if (nr > max) nr = max }
    { raw[NR] = $0 }
    END {
      fence = 0; nv = 0
      for (i = 1; i <= NR; i++) {
        l = raw[i]
        if (l ~ /^[ \t]*(```|~~~)/) { fence = !fence; infence[i] = 1; continue }
        infence[i] = fence
        if (!fence && verdict(l)) V[++nv] = i
      }
      if (nv == 0) { print "SKIP"; exit }
      last = V[nv]; prev = (nv > 1) ? V[nv - 1] : 0
      if (nv > 1) {
        for (i = last - 1; i > prev && raw[i] ~ /^[ \t]*$/; i--) ;
        if (i > prev && raw[i] ~ /^SPEC-TRACE-GATE: ok \(cut-exempt=[0-9]+\)$/) {
          for (j = i - 1; j > prev && raw[j] ~ /^[ \t]*$/; j--) ;
          if (j == prev) { last = prev; prev = (nv > 2) ? V[nv - 2] : 0 }
        }
      }
      for (i = prev + 1; i < last; i++) {
        if (infence[i]) continue
        l = raw[i]
        if (l !~ /^[ \t]*([-*][ \t]+)?COVERAGE-ROW:/) continue
        sub(/^[ \t]*([-*][ \t]+)?COVERAGE-ROW:[ \t]*/, "", l)
        n = split(l, f, "|")
        if (n < 3) continue
        key = tolower(trim(f[1]))
        if (key !~ /^r[0-9]+$/) continue
        k = substr(key, 2) + 0
        if (k < 1 || k > nr) continue
        st = tolower(trim(f[3])); ev = (n >= 4) ? trim(f[4]) : ""
        cls = (n >= 5) ? tolower(trim(f[5])) : ""
        if (cls != "core-flow-broken") cls = "wrong-data"
        seen[k]++
        if (st == "delivered") { if (ev == "" || ev == "-") add(cls, k, "delivered with no file:line") }
        else if (st == "elsewhere") { if (ev == "" || ev == "-") add(cls, k, "elsewhere names no ticket or slice") }
        else if (st == "missing" || st == "contradicts") add(cls, k, st)
        else add(cls, k, "status \"" st "\" is not delivered|missing|contradicts|elsewhere")
      }
      for (k = 1; k <= nr; k++) if (!seen[k]) add("wrong-data", k, "not traced")
      if (no == 0) { print "OK"; exit }
      for (i = 1; i <= no; i++) print out[i]
    }' "$rf"
}

cv_enforce() {
  local rf="${1:-}" plan="${2:-}" res reasons cls why lines=""
  [ -r "$rf" ] && [ -f "$rf" ] || return 0
  [ -n "$(cr_plan_row_list "$plan" 2>/dev/null)" ] || return 0
  declare -F verdict_parse >/dev/null 2>&1 || . "$(_cv_lib_dir)/verdict-parse.sh" 2>/dev/null || return 0
  [ "$(verdict_parse -L "$rf" 2>/dev/null)" = APPROVE ] || return 0
  cv_conf
  [ -n "$CV_CONF_WARN" ] && _cv_log "COVERAGE-GATE: knob warning: $CV_CONF_WARN"
  res=$(cv_judge "$rf" "$plan") || return 0
  case "$res" in BLOCK*) ;; *) return 0 ;; esac
  reasons=""
  while IFS=$'\t' read -r _ cls why; do
    lines="$lines- [BLOCK $cls] COVERAGE-GATE: $why"$'\n'
    reasons="${reasons:+$reasons; }$why"
  done <<<"$res"
  if [ "$CV_ENFORCE" = 0 ]; then
    _cv_log "COVERAGE-GATE: would BLOCK — $reasons; COVERAGE_REVIEW_ENFORCE=0, the verdict stands"
    return 0
  fi
  printf '\n%sVERDICT: BLOCK\n' "$lines" >> "$rf"
  _cv_log "COVERAGE-GATE: BLOCK — $reasons"
  return 0
}
