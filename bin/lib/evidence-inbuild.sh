#!/bin/bash
# bin/lib/evidence-inbuild.sh — an in-build review whose acceptance claims are
# ALL inconclusive does not report APPROVE (BH-9441 scope item 4).
# Sourced, never executed: functions only, no output at source time. Safe
# under `set -uo pipefail`. jq is called with -r and --arg only, and file
# content is never re-parsed as shell: a claim that carries $(…) or a backtick
# stays data.
#
# WHY. The lead review abandoned 36 PRs whose evidence claims were almost all
# inconclusive (29/29, 18/18, 16/16). The in-build review had approved each of
# them at tier 1, and the PR body said `(VERDICT: APPROVE)`. The scorer
# (bin/lib/evidence.sh) wrote the counts, and no step after the lenses read
# them: bin/lib/rb/result.sh only demotes when EVIDENCE_GATE_ENFORCE=1.
#
# THE RULE. "All inconclusive" is: $BUILD/evidence.json is readable, `total`
# is an integer >= 1 and `inconclusive == total` (so 0 confirmed, 0 refuted).
# Then, when review.md ends `VERDICT: APPROVE`, ei_cap appends one marked block
# to review.md:
#   <!-- evidence-inbuild-cap -->
#   - [NOTE] not verified here: claim <n>: <claim> (<scorer's note>)   (one per claim)
#   one sentence: the review reports MERGE-WITH-NOTES, not APPROVE
#   TIER: 2
#   VERDICT: APPROVE
# and sets EI_PR_VERDICT, which bin/lib/rb/pr.sh prints in the PR body in
# place of the word APPROVE.
# The machine verdict line stays APPROVE on purpose. About 15 readers gate on
# that word, and REVIEW LEVELS says a check this box cannot run is a NOTE and
# the verdict does not wait on it. The teeth are the tier: the existing reader
# (`tail -2 review.md | grep -q 'TIER: 1'` in bin/lib/rb/pr.sh) records tier 2,
# so the build never self-merges on zero proven claims.
# Any CONFIRMED or REFUTED claim, total 0, an unreadable file or a review that
# does not end APPROVE: nothing changes.
#
# THE FUNCTIONS
#   ei_conf [project]          sets EI_ENFORCE (0|1) and EI_CONF_WARN
#   ei_state <build>           prints `all-inconclusive <N>`, `proven`, `none` or `unread`; rc 0
#   ei_notes <build>           the NOTE lines, one per claim
#   ei_cap <build> <review.md> applies the rule; prints one status line; rc 0
#
# THE KNOB (catalog/lanes.d/_lib.evidence-inbuild.json, id evidence-inbuild),
# read through lib_env_apply, else the env, else EI_DEFAULT_ENFORCE below.

# Fallback of the knob EVIDENCE_INBUILD_CAP (settings row lib.evidence-inbuild.*).
EI_DEFAULT_ENFORCE=1
EI_MARKER='<!-- evidence-inbuild-cap -->'

# ei_conf [project] — EI_ENFORCE from EVIDENCE_INBUILD_CAP: lib_env_apply in a
# subshell, then the env, then EI_DEFAULT_ENFORCE. A value that is not on/off
# enforces and sets EI_CONF_WARN.
ei_conf() {
  local p="${1:-${PROJECT:-}}" root e
  root="${HARNESS:-${H:-}}"
  EI_CONF_WARN=""
  e=$(
    if ! command -v lib_env_apply >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
      # shellcheck source=/dev/null
      . "$root/bin/lib/lane-gate.sh" >/dev/null 2>&1
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply evidence-inbuild "$p" >/dev/null 2>&1
    printf '%s' "${EVIDENCE_INBUILD_CAP:-}"
  ) || e=""
  case "$(printf '%s' "${e:-$EI_DEFAULT_ENFORCE}" | tr 'A-Z' 'a-z')" in
    0|off|false|no) EI_ENFORCE=0 ;;
    1|on|true|yes) EI_ENFORCE=1 ;;
    *) EI_ENFORCE=1; EI_CONF_WARN="EVIDENCE_INBUILD_CAP='$e' is not on/off, so it enforces" ;;
  esac
  return 0
}

# ei_state <build> — never reads unread evidence as "all inconclusive" or as 0.
ei_state() {
  local f="${1:-}/evidence.json" out
  if [ -z "${1:-}" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then echo unread; return 0; fi
  out=$(jq -r '
    def int: type == "number" and . == floor and . >= 0;
    if type != "object" then "unread"
    elif ((.total | int) and (.confirmed | int) and (.refuted | int) and (.inconclusive | int)) | not then "unread"
    elif .total == 0 then "none"
    elif .inconclusive == .total and .confirmed == 0 and .refuted == 0 then "all-inconclusive \(.total)"
    else "proven" end' "$f" 2>/dev/null) || out=""
  case "$out" in
    none|proven|"all-inconclusive "[0-9]*) printf '%s\n' "$out" ;;
    *) echo unread ;;
  esac
  return 0
}

# ei_notes <build> — every byte is assembled inside jq. Claim and note are cut
# to 160 chars, control characters become spaces.
ei_notes() {
  local f="${1:-}/evidence.json"
  [ -r "$f" ] || return 0
  jq -r '
    def clean: tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode | .[0:160];
    .claims[]? |
    "- [NOTE] not verified here: claim \(.n // "?" | clean): \(.claim // "" | clean) (\(
      (.note // "" | clean) as $r | if ($r | test("^\\s*$")) then "no reason recorded by the scorer" else $r end))"' \
    "$f" 2>/dev/null
  return 0
}

_ei_say() { EI_STATUS="EVIDENCE INBUILD CAP: $1"; printf '%s\n' "$EI_STATUS"; }

# ei_cap <build> <review.md> — sets EI_PR_VERDICT when the cap applies (or was
# already applied), and EI_STATUS, the one status line for pipeline.log, which
# it also prints. Call it in the current shell (not in $(...)) to keep both
# variables. rc 0 always.
ei_cap() {
  local b="${1:-}" rv="${2:-}" st n root tmp notes
  unset EI_PR_VERDICT; EI_STATUS=""
  [ -n "${EI_ENFORCE:-}" ] || ei_conf
  st=$(ei_state "$b")
  case "$st" in
    "all-inconclusive "*) n=${st#all-inconclusive } ;;
    *) _ei_say "not applied ($st)"; return 0 ;;
  esac
  if ! command -v verdict_is >/dev/null 2>&1; then
    root="${HARNESS:-${H:-}}"
    # shellcheck source=/dev/null
    [ -n "$root" ] && [ -r "$root/bin/lib/verdict-parse.sh" ] && . "$root/bin/lib/verdict-parse.sh" >/dev/null 2>&1
  fi
  command -v verdict_is >/dev/null 2>&1 || { _ei_say "could not run (no verdict reader)"; return 0; }
  # A window nobody resolved makes every verdict read unknown; name that cause
  # instead of reporting it as a review that does not end APPROVE.
  if command -v verdict_window >/dev/null 2>&1 && ! verdict_window >/dev/null 2>&1; then
    _ei_say "could not run (verdict unknown: VERDICT_WINDOW_LINES unresolved)"; return 0
  fi
  if [ -z "$rv" ] || [ ! -f "$rv" ] || ! verdict_is APPROVE -L "$rv" 2>/dev/null; then
    _ei_say "not applied (review does not end APPROVE)"; return 0
  fi
  if [ "${EI_ENFORCE:-1}" = 0 ]; then
    _ei_say "not enforced (0 of $n claims proven; EVIDENCE_INBUILD_CAP=0, log only)"; return 0
  fi
  if grep -qxF "$EI_MARKER" "$rv" 2>/dev/null; then
    EI_PR_VERDICT="MERGE-WITH-NOTES, 0 of $n acceptance claims proven"
    _ei_say "applied earlier (0 of $n claims proven) — tier 2, MERGE-WITH-NOTES"; return 0
  fi
  notes=$(ei_notes "$b")
  tmp=$(mktemp "$(dirname "$rv")/.review.md.ei.XXXXXX" 2>/dev/null) || {
    _ei_say "could not run (review dir not writable)"; return 0; }
  if { cat "$rv"
       printf '\n%s\n' "$EI_MARKER"
       printf '## Evidence cap (in-build)\n\n'
       printf 'All %s acceptance claims are INCONCLUSIVE: the build proved none of them.\n' "$n"
       [ -z "$notes" ] || printf '%s\n' "$notes"
       printf '\nThe in-build review reports MERGE-WITH-NOTES, not APPROVE. The build is recorded tier 2.\n\n'
       printf 'TIER: 2\nVERDICT: APPROVE\n'
     } > "$tmp" 2>/dev/null && mv -f "$tmp" "$rv" 2>/dev/null; then
    EI_PR_VERDICT="MERGE-WITH-NOTES, 0 of $n acceptance claims proven"
    _ei_say "applied (0 of $n claims proven) — tier 2, MERGE-WITH-NOTES"
  else
    rm -f "$tmp" 2>/dev/null
    _ei_say "could not run (review.md not writable)"
  fi
  return 0
}
