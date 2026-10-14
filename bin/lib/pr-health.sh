#!/bin/bash
# bin/lib/pr-health.sh — BH-3932 (BH-3929.0): the shared helpers the PR-owner
# hooks (bin/lib/pr-owner/*.sh) and the conductor's CI-block step read. Sourced,
# never executed. It writes no file and reads no clock: its only reads are D1
# (settings, verdicts) through the jobs client the caller already loaded, and
# its only "log" is stderr, which the caller sends where it wants
# (bin/pr-owner-sweep.sh: 2>>logs/pr-owner-sweep.log).
#
#   ph_knob <dotted-key> <ENV> <default>        one non-negative integer
#   ph_ci_only_body <text>                       is every BLOCK a CI-did-not-run?
#   ph_review_covered <slug> <num> <sha> [word]  is this head already reviewed?
#
# Rules: docs/PR-OWNERSHIP.md.

# ph_knob <dotted-key> <ENV> <default> — prints one non-negative integer, rc 0.
#   The D1 settings row wins (setting_get rc 0 with a number), then ${!ENV} when
#   it is a number, then <default>. 0 is a number, so it binds (zero-means-off).
#   A non-number, in the row or the env, is ignored and named on stderr.
#   PH_KNOB_SRC is row | env | default, or outage when the settings read failed
#   (rc 1) or there is no setting_get at all — then env/default still decide.
#   PH_KNOB_SRC is set in the shell that runs ph_knob; inside $(...) it is lost.
ph_knob() {
  local key="${1:-}" envn="${2:-}" dflt="${3:-}" v="" rc ev=""
  PH_KNOB_SRC=""
  if command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get "$key" 2>/dev/null); rc=$?
    case "$rc" in
      0) if [[ "$v" =~ ^[0-9]+$ ]]; then PH_KNOB_SRC=row; printf '%s\n' "$v"; return 0; fi
         echo "pr-health: knob $key=$v is not a number — ignored" >&2 ;;
      2) ;;
      *) PH_KNOB_SRC=outage
         echo "pr-health: knob $key: settings unreadable (rc $rc) — using ${envn:-env}/default" >&2 ;;
    esac
  else
    PH_KNOB_SRC=outage
    echo "pr-health: knob $key: no settings client loaded — using ${envn:-env}/default" >&2
  fi
  [[ "$envn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && ev="${!envn:-}"
  if [ -n "$ev" ]; then
    if [[ "$ev" =~ ^[0-9]+$ ]]; then
      PH_KNOB_SRC="${PH_KNOB_SRC:-env}"; printf '%s\n' "$ev"; return 0
    fi
    echo "pr-health: knob $key: env $envn=$ev is not a number — ignored" >&2
  fi
  PH_KNOB_SRC="${PH_KNOB_SRC:-default}"
  printf '%s\n' "$dflt"
}

# ph_ci_only_body <text> — rc 0 only when EVERY BLOCK finding in a review body
#   says CI did not run, and nothing else. It gates a BLOCK clear (#3934), so a
#   wrong rc 0 is a merge over a real finding; every doubt is rc 1.
#   A finding passes when it matches all three, case-insensitive:
#     vocab     the ticket's CI-did-not-run phrases
#     CI-named  it says ci, workflow or github actions (a "cron job skipped its
#               lock check" is vocab and is not CI)
#     code-free no path:line and no dir/file.ext token (a finding that names
#               code is about the code)
#   With `- [BLOCK]` lines, every one must pass, each on its own. With none,
#   the paragraph from the one line carrying the word BLOCK to the next blank
#   line must pass, and it must be one finding: no list item inside it.
#   Fail closed on any BLOCK this does not check (BH-3932 review): rc 1 when a
#   line other than the checked ones carries `[BLOCK]` (numbered, bold) or the
#   word BLOCK (prose), or when two lines carry it with no `- [BLOCK]` lines.
#   A bare `VERDICT: BLOCK` line is the verdict, not a finding, and is skipped.
#   Empty text, or no BLOCK at all: rc 1.
#   Known gap: "- [BLOCK] CI passed, but the migration did not run on prod"
#   is CI-named and matches the vocabulary, so it answers rc 0. #3934 adds the
#   finer rule before any BLOCK clear reads this answer.
_PH_CI_VOCAB="\\b(ci|check|workflow|job)\\b.*\\b(did not run|didn't run|not run|was skipped|skipped|was cancell?ed|cancell?ed|never ran|no run)\\b|\\bno (ci|check) run\\b"
_PH_CI_NAMED='\b(ci|workflows?|github actions)\b'
_PH_CODE_REF='[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+|[A-Za-z0-9_-]+/[A-Za-z0-9_./-]+\.[a-z]{1,4}\b'
_ph_ci_finding() { # _ph_ci_finding <one finding>
  grep -Eiq -- "$_PH_CI_VOCAB" <<<"$1" || return 1
  grep -Eiq -- "$_PH_CI_NAMED" <<<"$1" || return 1
  ! grep -Eq -- "$_PH_CODE_REF" <<<"$1"
}
ph_ci_only_body() {
  local text="${1:-}" lines line marks nmarks start para
  [ -n "$text" ] || return 1
  lines=$(printf '%s\n' "$text" | grep -Ei '^[[:space:]]*[-*][[:space:]]*\[BLOCK\]')
  # Every line carrying a BLOCK marker in any form, numbered, the verdict skipped.
  marks=$(printf '%s\n' "$text" | awk '
    { u = toupper($0) }
    u ~ /^[[:space:]*_#>]*VERDICT[[:space:]*_]*:?[[:space:]*_]*BLOCK[[:space:]*_.]*$/ { next }
    u ~ /\[BLOCK\]/ || $0 ~ /(^|[^A-Za-z])BLOCK([^A-Za-z]|$)/ { print NR }')
  nmarks=$(printf '%s' "$marks" | grep -c .)
  if [ -n "$lines" ]; then
    # A BLOCK on any line that is not a `- [BLOCK]` line is a finding unchecked.
    [ "$nmarks" = "$(printf '%s\n' "$lines" | grep -c .)" ] || return 1
    while IFS= read -r line; do
      _ph_ci_finding "$line" || return 1
    done <<<"$lines"
    return 0
  fi
  [ "$nmarks" = 1 ] || return 1
  start=$marks
  # `[BLOCK]` outside a `- [BLOCK]` bullet (numbered, bold) is a list shape this
  # does not parse; a list item inside the paragraph is a second finding.
  printf '%s\n' "$text" | sed -n "${start}p" | grep -qi '\[BLOCK\]' && return 1
  para=$(printf '%s\n' "$text" | awk -v s="$start" '
    NR < s { next }
    /^[[:space:]]*$/ { exit }
    NR > s && /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ { bad = 1; exit }
    { printf "%s ", $0 }
    END { if (bad) exit 1 }') || return 1
  [ -n "$para" ] || return 1
  _ph_ci_finding "$para"
}

# ph_review_covered <owner/repo> <num> <sha> [<word>] — is a settled review
#   already bound to exactly this head? A thin wrapper over the two readers that
#   exist; #3930 owns review dedupe, this only answers the question.
#     rc 0  job_verdict_covers (any source; <word> when given) or vd_standing
#           has a row on this head (whose verdict is <word>, when given)
#     rc 2  a real no from both
#     rc 1  either read was an outage, or a reader is not loaded
ph_review_covered() {
  local slug="${1:-}" num="${2:-}" sha="${3:-}" word="${4:-}" outage=0 rc line
  [ -n "$slug" ] && [ -n "$num" ] && [ -n "$sha" ] || return 1
  if command -v job_verdict_covers >/dev/null 2>&1; then
    job_verdict_covers "https://github.com/$slug/pull/$num" "$sha" "" "$word"; rc=$?
    [ "$rc" = 0 ] && return 0
    [ "$rc" = 2 ] || outage=1
  else
    outage=1
  fi
  # vd_standing lives next to this file; load it when the caller has not.
  if ! command -v vd_standing >/dev/null 2>&1 && [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ]; then
    # shellcheck source=bin/lib/verdicts.sh
    . "${BASH_SOURCE[0]%/*}/verdicts.sh"
  fi
  if command -v vd_standing >/dev/null 2>&1; then
    line=$(vd_standing "$slug" "$num" "$sha" 2>/dev/null); rc=$?
    case "$rc" in
      0) if [ -z "$word" ] || [ "${line%%$'\t'*}" = "$word" ]; then return 0; fi ;;
      1) ;;
      *) outage=1 ;;
    esac
  else
    outage=1
  fi
  [ "$outage" = 1 ] && return 1
  return 2
}
