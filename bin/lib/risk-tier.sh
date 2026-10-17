#!/bin/bash
# bin/lib/risk-tier.sh — BH-5022 (BH-4973.1): a rule-based risk tier for ONE PR
# head. Sourced (by bin/lead-review-enqueue.sh), never executed. Pure rules: it
# never calls a model, and it reads nothing from GitHub itself. The caller hands
# it the head's compare answer (GET compare/<base>...<head>, which carries
# files[] with status, additions and deletions).
#
# THE RULES, in order (the first that answers wins):
#   0. 300 or more compare files (GitHub's cap)           -> high, "diff too large to read whole"
#   1. any filename OR previous_filename matching a high, a sensitive or a lead
#      protected glob (la_globs: the repo's lead_protected_paths rows plus the
#      seed floor, catalog/lead-protected-paths.seed.tsv globs that have no row
#      yet, BH-4148; ALWAYS high, no risk_tier row can remove them)  -> high
#   2. every path is a low path, and changed lines (additions + deletions) are
#      under the low limit                                 -> low
#      every path is a low path, but the low limit or over  -> medium
#      Wave 1 (the operator, 10-07) low is exactly: docs/, console-ui/src/screens/,
#      console-ui/src/ui/ (the ceiling RT_LOW_CEILING), and NEW test files: an
#      ADDED tests/<name>-test.sh, tests/mc/<name>-test.sh or
#      console-ui/tests/<name>.test.js (RT_LOW_NEW_TESTS, one directory level,
#      so nothing under tests/lib/ or any other helper or fixture directory).
#      A low path must also match a risk_tier.low_globs glob: a low_globs row
#      can narrow low, never widen it. Both sets are constants, not rows. No
#      bin/, worker/, catalog/, cron/, checks/, guardrails/, .github/, fly/,
#      config/ or prompts/ path is ever low, and neither is any edit to an
#      EXISTING test file: modified (even purely additive, since an added
#      `exit 0` is additive), deleted or renamed, it goes to the lead. So every
#      edit to an existing test, and every test helper or fixture, gets a lead
#      review. The low limit is risk_tier.low_lines, capped at RT_LOW_LINES_MAX
#      (300). An all-low-paths diff is never made high by its size.
#   2b. RULES TEXT: every path, each rename's previous_filename included, is
#      rules/CLAUDE.md or rules/topics/<name>.md (one directory level, rt_rules_shape),
#      rules/CLAUDE.md is one of them, the caller proved the render on the head
#      (RT_RULES_RENDER starts `ok`, bin/lib/rules-render-head.sh), changed
#      lines are under risk_tier.rules_low_lines (fallback 80, capped at
#      RT_LOW_LINES_MAX, 0 = the lane is off), and rules/topics/01-iron-
#      guardrails.md has 0 deletions and is not removed or renamed away
#                                                          -> low, `rules-text: ...`
#      A rules diff that fails any of these names why (never with the
#      `rules-text:` prefix) and goes on to rules 3 and 4. rt_rules_low is the
#      one test for "a rules-text low". rules/settings.json is a lead protected
#      path (rule 1), and rules/RTK.md is no rules text, so neither is ever low.
#   2c. EVIDENCE (BH-6968), only while risk_tier.low_score_max > 0 (0, the
#      fallback, = the lane is off): a diff no rule above made low, with no
#      edit to an existing test, helper or fixture, no rules-text shape (2b owns
#      those), and changed lines under the low limit, is low when ALL of these
#      hold. rt_evidence_load reads them; rule 1 already sent every protected
#      path to high, so this is never a way around the protected globs:
#        RT_EVIDENCE_SCORE     the queue-risk score (bin/lib/queue-risk.sh,
#                              qr_score) is under risk_tier.low_score_max
#        RT_EVIDENCE_SUITES    the builder gate ran at least
#                              risk_tier.low_min_suites suites green on THIS head
#                              (the PR body's builder-gate marker)
#        RT_EVIDENCE_PREQUEUE  `green`: the prequeue-verdict status is success
#                              and says `green on main ...`
#                                                          -> low, `evidence: ...`
#      A miss adds `no evidence low: <the first input that failed>` to the
#      reasons and goes on to rules 3 and 4. No RT_EVIDENCE_* set (a caller that
#      never loaded them) is never an evidence low.
#   3. changed lines > high_lines, or files > high_files    -> high
#   4. otherwise                                             -> medium
# UNREADABLE IS NEVER LOW. A rules row the worker could not answer (rc 1), or a
# protected-path list that could not be read, caps the answer at medium, with
# the reason saying which.
#
# THE RULES ARE SETTINGS ROWS (bin/jobs-client.sh setting-set <key> <value>);
# the constants below are only the fallback for a key with no row (rc 2):
#   risk_tier.high_globs       RT_HIGH_GLOBS_DEFAULT
#   risk_tier.sensitive_globs  RT_SENSITIVE_GLOBS_DEFAULT (auth, secrets, env, billing, cost caps)
#   risk_tier.low_globs        RT_LOW_GLOBS_DEFAULT (only narrows the wave-1 low set)
#   risk_tier.high_lines 600, risk_tier.high_files 25, risk_tier.low_lines 300,
#   risk_tier.rules_low_lines 80,
#   risk_tier.low_score_max 0 (rule 2c off), risk_tier.low_min_suites 12
# Globs are space-separated and match like _la_match: `**` reads as `*`, and a
# bash `*` already crosses `/`. The worker signs every risk_tier.* write; the
# signature records who wrote a row, it does not gate the write, which is why
# the low ceiling is a constant here and not a row.
#
# rt_mode <owner/repo>
#   prints `<off|shadow|enforce>\t<why>`. Wave 1 honours the mode rows for
#   example-org/cromford only (RT_MODE_REPOS, a constant): any other repo is
#   off, whatever its rows say, until a later wave adds a gate for it. The row
#   risk_tier.mode.<owner>.<name> wins over the global risk_tier.mode; neither
#   row = off. An unreadable row
#   or a value that is not off|shadow|enforce (trimmed, lowercased) is off for
#   this tick, and <why> says so (empty otherwise). Always rc 0.
# rt_rules_load
#   fills RT_HIGH_GLOBS RT_SENSITIVE_GLOBS RT_LOW_GLOBS RT_HIGH_LINES
#   RT_HIGH_FILES RT_LOW_LINES RT_RULES_LOW_LINES RT_LOW_SCORE_MAX
#   RT_LOW_MIN_SUITES (read only while RT_LOW_SCORE_MAX > 0), and
#   RT_RULES_UNREADABLE=1 when any read failed
#   (that key keeps its fallback), RT_RULES_SIG (a checksum of the rules as
#   loaded: a cached tier is only reused under the same one; the two rule 2c
#   rows are in it only while the lane is on, so a lane that stays off keeps
#   every cached tier) and RT_RULES_LOADED=1. rt_classify calls it unless the caller already did (the
#   lane loads once per repo per tick).
# rt_inbuild_grace
#   BH-5023: prints the seconds the hub enqueue holds a medium head under
#   enforce for the in-build lead-grade review (bin/inbuild-lead-review.sh)
#   before it requests a lead review itself: the risk_tier.inbuild_grace_s row,
#   else RT_INBUILD_GRACE_S_DEFAULT. A row that cannot be read or is not an
#   integer prints the fallback. Not in rt_rules_load or RT_RULES_SIG: the grace
#   never reclassifies a head. Always rc 0.
# rt_rules_shape <compare-json-file>
#   rc 0 when every filename and previous_filename is rules text (rule 2b) and
#   rules/CLAUDE.md is one of them; rc 1 otherwise, and on an unreadable files[].
#   The caller runs the head render check only when this answers rc 0.
# rt_rules_low <tier> <reasons>
#   rc 0 when the tier is low or withheld and the reasons start `rules-text:`.
# rt_evidence_load <owner/repo> <n> <head> <compare-json-file> <pr-json-file>
#   Rule 2c's inputs, in this order, stopping at the first that fails (its
#   reason in RT_EVIDENCE_WHY, the later inputs left empty):
#     1. the PR body (.body of <pr-json-file>, no network) carries exactly one
#        distinct `<!-- builder-gate: head=<sha> green=<n> -->` marker
#        (bin/evidence-summary.sh) and its head is <head>: RT_EVIDENCE_SUITES=<n>
#     2. one gh_rest GET repos/<slug>/commits/<head>/status: the
#        prequeue-verdict entry is `success` with a description that starts
#        `green on main ` (bin/lib/mc-prequeue.d/status.sh). `gate off`,
#        `no-selection`, `could-not-run`, `no red pre-queue verdict` and the
#        other success answers ran no green suites: RT_EVIDENCE_PREQUEUE=green
#     3. qr_score over the compare's file names, lines and file count, in a
#        subshell whose mc_attempt_count reads pr_attempt_count (the conductor's
#        pr_attempts rows). An outage there, a queue_risk row that could not be
#        read, or no score: unreadable. Else RT_EVIDENCE_SCORE=<score>
#   The queue_risk rows are read once per rt_rules_load. Always rc 0.
# rt_low_rule <tier> <reasons>
#   prints which rule made a head low, for risk.tsv column 8: `evidence` (low
#   or withheld, reasons start `evidence:`), `path` (any other low or withheld,
#   a rules-text low included), else `-`.
# rt_classify <compare-json-file> <owner/repo>
#   Reads RT_RULES_RENDER (rule 2b; unset = not proved, never low) and
#   RT_EVIDENCE_* (rule 2c; unset = no evidence, never an evidence low).
#   rc 0, prints `<low|medium|high>\t<reasons>\t<lines>\t<files>`.
#   rc 2, prints nothing: the compare carries no readable files[] (the caller
#   classifies nothing and falls through to today's path).
# Needs jq. Bash 4 (the hub only). awk here is POSIX (mawk on boxes).

# The second line is the merge, deploy, propagate and guard machinery. No bin/
# path is low in wave 1 anyway; these stay high so they also go to the lead first.
RT_HIGH_GLOBS_DEFAULT='worker/jobs/schema.sql worker/*/schema.d/* *migrations/* bin/lib/jobs/* bin/merge-* bin/lead-* bin/lib/verdicts.sh bin/lib/risk-tier.sh .mergify.yml .github/*
 bin/run-build.sh bin/harness-sync.sh bin/fleet-propagate.sh bin/update-runners.sh bin/blocked-resolver.sh bin/iron-law-guard.sh bin/poll-commands.sh bin/review-prs.sh bin/agent-call.sh bin/watchdog-responder.sh bin/alert-triage.sh'
RT_SENSITIVE_GLOBS_DEFAULT='bin/*secret* bin/*auth* bin/*env* bin/*billing* bin/*cost-cap* worker/*secret* worker/*auth* worker/*billing* worker/*cost-cap*'
RT_LOW_GLOBS_DEFAULT='docs/* console-ui/src/screens/* console-ui/src/ui/* tests/* console-ui/tests/*'
# BH-5022 wave 1 (the operator, 10-07): the most low can ever be. Not settings rows.
# RT_LOW_NEW_TESTS counts only for an ADDED file directly in its directory.
RT_LOW_CEILING='docs/* console-ui/src/screens/* console-ui/src/ui/*'
RT_LOW_NEW_TESTS='tests/*-test.sh tests/mc/*-test.sh console-ui/tests/*.test.js'
# The repos whose risk_tier.mode rows wave 1 honours (owner/name, lowercase).
RT_MODE_REPOS='example-org/cromford'
RT_LOW_LINES_MAX=300
RT_HIGH_LINES_DEFAULT=600
RT_HIGH_FILES_DEFAULT=25
RT_LOW_LINES_DEFAULT=300
RT_RULES_LOW_LINES_DEFAULT=80
RT_RULES_GUARDRAILS=rules/topics/01-iron-guardrails.md
RT_INBUILD_GRACE_S_DEFAULT=3600
RT_LOW_SCORE_MAX_DEFAULT=0
RT_LOW_MIN_SUITES_DEFAULT=12
RT_PQ_CONTEXT=prequeue-verdict

# la_globs lives in the lead-authority lib; without it rule 1's catalog half is unreadable.
# shellcheck source=bin/lib/lead-authority.sh
command -v la_globs >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-authority.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-authority.sh"; }

# _rt_match <path> <glob> — the _la_match semantics, kept here so a lane
# without the lead-authority lib still matches the same way.
_rt_match() {
  local p="$1" g="$2"
  g="${g//\*\*/*}"
  # shellcheck disable=SC2053
  [[ $p == $g ]]
}

# _rt_any <path> <globs, space-separated> — rc 0 when one matches.
_rt_any() {
  local p="$1" g gs=()
  # read -a, never an unquoted expansion: `docs/*` would glob against the cwd.
  read -r -a gs <<<"$(printf '%s' "$2" | tr '\n\t' '  ')"
  for g in "${gs[@]}"; do
    _rt_match "$p" "$g" && return 0
  done
  return 1
}

# _rt_new_test <path> — rc 0 when the path has a RT_LOW_NEW_TESTS shape with
# no further directory: tests/x-test.sh yes, tests/lib/x-test.sh no.
_rt_new_test() {
  local p="$1" g gs=()
  read -r -a gs <<<"$RT_LOW_NEW_TESTS"
  for g in "${gs[@]}"; do
    _rt_match "$p" "$g" || continue
    [[ "${p#"${g%/*}"/}" == */* ]] || return 0
  done
  return 1
}

# _rt_setting <key> <fallback> <int|globs> — the row's value, or the fallback
# on rc 2. rc 1 (an outage, or a value that is not what the key holds) prints
# the fallback and sets RT_RULES_UNREADABLE=1.
_rt_setting() {
  local v rc=0
  if ! command -v setting_get >/dev/null 2>&1; then RT_RULES_UNREADABLE=1; printf '%s' "$2"; return 0; fi
  v=$(setting_get "$1") || rc=$?
  case "$rc" in
    0) ;;
    2) printf '%s' "$2"; return 0 ;;
    *) RT_RULES_UNREADABLE=1; printf '%s' "$2"; return 0 ;;
  esac
  v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [ "$3" = int ]; then
    case "$v" in ''|*[!0-9]*) RT_RULES_UNREADABLE=1; printf '%s' "$2"; return 0 ;; esac
  fi
  printf '%s' "$v"
}

rt_rules_load() {
  RT_RULES_UNREADABLE=""
  # Each read in THIS shell (not a substitution of the whole load), so the flag survives.
  local f; f=$(mktemp "${TMPDIR:-/tmp}/risk-tier.XXXXXX") || { RT_RULES_UNREADABLE=1; f=/dev/null; }
  _rt_setting risk_tier.high_globs "$RT_HIGH_GLOBS_DEFAULT" globs > "$f"; RT_HIGH_GLOBS=$(cat "$f")
  _rt_setting risk_tier.sensitive_globs "$RT_SENSITIVE_GLOBS_DEFAULT" globs > "$f"; RT_SENSITIVE_GLOBS=$(cat "$f")
  _rt_setting risk_tier.low_globs "$RT_LOW_GLOBS_DEFAULT" globs > "$f"; RT_LOW_GLOBS=$(cat "$f")
  _rt_setting risk_tier.high_lines "$RT_HIGH_LINES_DEFAULT" int > "$f"; RT_HIGH_LINES=$(cat "$f")
  _rt_setting risk_tier.high_files "$RT_HIGH_FILES_DEFAULT" int > "$f"; RT_HIGH_FILES=$(cat "$f")
  _rt_setting risk_tier.low_lines "$RT_LOW_LINES_DEFAULT" int > "$f"; RT_LOW_LINES=$(cat "$f")
  _rt_setting risk_tier.rules_low_lines "$RT_RULES_LOW_LINES_DEFAULT" int > "$f"; RT_RULES_LOW_LINES=$(cat "$f")
  _rt_setting risk_tier.low_score_max "$RT_LOW_SCORE_MAX_DEFAULT" int > "$f"; RT_LOW_SCORE_MAX=$((10#$(cat "$f")))
  RT_LOW_MIN_SUITES="$RT_LOW_MIN_SUITES_DEFAULT"
  if [ "$RT_LOW_SCORE_MAX" -gt 0 ]; then
    _rt_setting risk_tier.low_min_suites "$RT_LOW_MIN_SUITES_DEFAULT" int > "$f"; RT_LOW_MIN_SUITES=$((10#$(cat "$f")))
  fi
  [ "$f" = /dev/null ] || rm -f "$f"
  # The queue_risk rows rule 2c scores with are read again after a rules load.
  _RT_QR_LOADED=""
  if [ "$RT_LOW_SCORE_MAX" -gt 0 ]; then
    RT_RULES_SIG=$(printf '%s\n' "$RT_HIGH_GLOBS" "$RT_SENSITIVE_GLOBS" "$RT_LOW_GLOBS" "$RT_HIGH_LINES" "$RT_HIGH_FILES" "$RT_LOW_LINES" "$RT_RULES_LOW_LINES" "${RT_RULES_UNREADABLE:-}" "evidence $RT_LOW_SCORE_MAX $RT_LOW_MIN_SUITES" | cksum | cut -d' ' -f1)
  else
    RT_RULES_SIG=$(printf '%s\n' "$RT_HIGH_GLOBS" "$RT_SENSITIVE_GLOBS" "$RT_LOW_GLOBS" "$RT_HIGH_LINES" "$RT_HIGH_FILES" "$RT_LOW_LINES" "$RT_RULES_LOW_LINES" "${RT_RULES_UNREADABLE:-}" | cksum | cut -d' ' -f1)
  fi
  RT_RULES_LOADED=1
  return 0
}

rt_inbuild_grace() {
  # local: a failed read must not mark the classification rules unreadable.
  local RT_RULES_UNREADABLE=""
  _rt_setting risk_tier.inbuild_grace_s "$RT_INBUILD_GRACE_S_DEFAULT" int
}

rt_mode() {
  local slug="${1:-}" k v rc=0 src
  if ! command -v setting_get >/dev/null 2>&1; then printf 'off\tno settings reader\n'; return 0; fi
  [[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { printf 'off\trepo %s is not owner/name\n' "$slug"; return 0; }
  _rt_any "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" "$RT_MODE_REPOS" \
    || { printf 'off\twave 1 honours risk_tier.mode only for %s; %s stays off\n' "$RT_MODE_REPOS" "$slug"; return 0; }
  k="risk_tier.mode.$(printf '%s' "$slug" | tr 'A-Z/' 'a-z.')"
  src="$k"
  if [ "${#k}" -le 64 ]; then v=$(setting_get "$k") || rc=$?; else rc=2; fi
  if [ "$rc" = 2 ]; then
    rc=0; src=risk_tier.mode; v=$(setting_get risk_tier.mode) || rc=$?
    [ "$rc" = 2 ] && { printf 'off\t\n'; return 0; }
  fi
  [ "$rc" = 0 ] || { printf 'off\tthe %s row could not be read; off this tick\n' "$src"; return 0; }
  v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
  case "$v" in
    off|shadow|enforce) printf '%s\t\n' "$v" ;;
    *) printf "off\\t%s reads '%s', not off|shadow|enforce; off this tick\\n" "$src" "$(printf '%s' "$v" | tr -d '\t\n' | head -c 40)" ;;
  esac
  return 0
}

# _rt_hits <paths-file> <globs> — prints `touches <p1>, <p2>, <p3>[, +N more]`
# for the paths matching any glob; prints nothing when none do.
_rt_hits() {
  local p hit="" n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _rt_any "$p" "$2" || continue
    n=$((n + 1))
    [ "$n" -le 3 ] && hit="${hit:+$hit, }$p"
  done < "$1"
  [ "$n" -gt 0 ] || return 0
  [ "$n" -gt 3 ] && hit="$hit, +$((n - 3)) more"
  printf 'touches %s' "$hit"
}

rt_rules_shape() {
  local p render=0 n=0
  # A name with a control character is never rules text (it could split a line).
  jq -e '(.files | type) == "array" and all(.files[]; [.filename, (.previous_filename // empty)]
    | all(type == "string" and (test("[[:cntrl:]]") | not)))' "$1" >/dev/null 2>&1 || return 1
  while IFS= read -r p; do
    n=$((n + 1))
    case "$p" in
      rules/CLAUDE.md) render=1 ;;
      rules/topics/*.md) [[ "${p#rules/topics/}" == */* ]] && return 1 ;;
      *) return 1 ;;
    esac
  done < <(jq -r '.files[] | .filename, (.previous_filename // empty)' "$1" 2>/dev/null)
  [ "$n" -gt 0 ] && [ "$render" = 1 ]
}

rt_rules_low() {
  case "${1:-}" in low|withheld) ;; *) return 1 ;; esac
  case "${2:-}" in rules-text:*) return 0 ;; esac
  return 1
}

# _rt_rules_lane <compare-json-file> <lines> — rule 2b once rt_rules_shape said
# rules text: prints `low` when every condition holds, else the reason it fails.
_rt_rules_lane() {
  local cmp="$1" lines="$2" max="${RT_RULES_LOW_LINES:-$RT_RULES_LOW_LINES_DEFAULT}"
  [ "$max" -gt "$RT_LOW_LINES_MAX" ] && max="$RT_LOW_LINES_MAX"
  case "${RT_RULES_RENDER:-}" in
    ok|ok$'\t'*) ;;
    "") printf 'rules text, but no render check on the head'; return 0 ;;
    *) printf 'rules text, but render check %s' "$(printf '%s' "$RT_RULES_RENDER" | tr '\t\n' ': ' | head -c 200)"; return 0 ;;
  esac
  if [ "$max" -le 0 ]; then printf 'rules text, but the rules-text lane is off (risk_tier.rules_low_lines 0)'; return 0; fi
  if [ "$lines" -ge "$max" ]; then printf 'rules text, %s lines, over rules limit %s' "$lines" "$max"; return 0; fi
  # Absent is not zero: the guardrails file needs a numeric 0 deletions.
  if jq -e --arg g "$RT_RULES_GUARDRAILS" 'any(.files[];
      (.filename == $g and ((.deletions | type) != "number" or .deletions > 0 or .status == "removed"))
      or ((.previous_filename // "") == $g and .filename != $g))' "$cmp" >/dev/null 2>&1; then
    printf 'rules text, but deletes lines from %s' "$RT_RULES_GUARDRAILS"; return 0
  fi
  printf 'low'
}

rt_low_rule() {
  case "${1:-}" in low|withheld) ;; *) printf -- '-'; return 0 ;; esac
  case "${2:-}" in evidence:*) printf evidence ;; *) printf path ;; esac
}

# _rt_score_shim <flag-file> — defines mc_attempt_count over pr_attempt_count
# (the same pr_attempts rows the conductor reads). For the subshell qr_score
# runs in only: an outage, or no pr_attempt_count at all, touches <flag-file>.
_rt_score_shim() {
  _RT_SHIM_FLAG="$1"
  mc_attempt_count() {
    local key="${2:-}" n rc=0
    command -v pr_attempt_count >/dev/null 2>&1 || { : > "$_RT_SHIM_FLAG"; echo 0; return 0; }
    n=$(pr_attempt_count "${key%#*}" "${key##*#}" "${1:-}" 2>/dev/null) || rc=$?
    case "$rc" in 0|2) ;; *) : > "$_RT_SHIM_FLAG"; n=0 ;; esac
    echo "${n:-0}"
  }
}

rt_evidence_load() {
  local slug="${1:-}" n="${2:-}" head cmp="${4:-}" prf="${5:-}" m k st sf files lines nf flag out sc reasons
  RT_EVIDENCE_SCORE=""; RT_EVIDENCE_SUITES=""; RT_EVIDENCE_PREQUEUE=""; RT_EVIDENCE_WHY=""
  head=$(printf '%s' "${3:-}" | tr '[:upper:]' '[:lower:]')
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || { RT_EVIDENCE_WHY="head '${head:0:40}' is not a sha"; return 0; }
  # 1. The builder gate's count, bound to this head.
  m=$(jq -r '.body // "" | strings' "$prf" 2>/dev/null \
    | grep -oE '<!-- builder-gate: head=[0-9A-Fa-f]{40} green=[0-9]+ -->' | tr '[:upper:]' '[:lower:]' | sort -u)
  k=$(printf '%s' "$m" | grep -c .)
  if [ "$k" -gt 1 ]; then RT_EVIDENCE_WHY="$k different builder-gate markers in the PR body"; return 0; fi
  if [ "$k" != 1 ] || [ "$(printf '%s' "$m" | sed -E 's/.*head=([0-9a-f]{40}).*/\1/')" != "$head" ]; then
    RT_EVIDENCE_WHY="no builder-gate marker for this head"; return 0
  fi
  RT_EVIDENCE_SUITES=$((10#$(printf '%s' "$m" | sed -E 's/.*green=([0-9]+).*/\1/')))
  # 2. The prequeue-verdict status on this head.
  if ! command -v gh_rest >/dev/null 2>&1; then RT_EVIDENCE_WHY="prequeue-verdict not green (no GitHub reader)"; return 0; fi
  # A plain call into a file, never inside $( ): GH_REST_STATUS lives in this shell.
  sf=$(mktemp "${TMPDIR:-/tmp}/risk-tier.XXXXXX") || { RT_EVIDENCE_WHY="prequeue-verdict not green (mktemp)"; return 0; }
  GH_REST_STATUS=""
  if ! gh_rest GET "repos/$slug/commits/$head/status" > "$sf" 2>/dev/null; then
    rm -f "$sf"; RT_EVIDENCE_WHY="prequeue-verdict not green (status unreadable, HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  st=$(jq -r --arg c "$RT_PQ_CONTEXT" '[.statuses[]? | select(.context == $c)] | first // empty
    | if .state == "success" and ((.description // "") | startswith("green on main ")) then "green" else "\(.state)" end' \
    "$sf" 2>/dev/null)
  rm -f "$sf"
  if [ "$st" != green ]; then RT_EVIDENCE_WHY="prequeue-verdict not green (${st:-absent})"; return 0; fi
  RT_EVIDENCE_PREQUEUE=green
  # 3. The queue-risk score, the conductor's attempt history included.
  # shellcheck source=bin/lib/queue-risk.sh
  command -v qr_score >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/queue-risk.sh" ] && . "${BASH_SOURCE[0]%/*}/queue-risk.sh"; }
  if ! command -v qr_score >/dev/null 2>&1; then RT_EVIDENCE_WHY="queue-risk score unreadable (no bin/lib/queue-risk.sh)"; return 0; fi
  [ "${_RT_QR_LOADED:-}" = 1 ] || { qr_rules_load; _RT_QR_LOADED=1; }
  files=$(mktemp "${TMPDIR:-/tmp}/risk-tier.XXXXXX") || { RT_EVIDENCE_WHY="queue-risk score unreadable (mktemp)"; return 0; }
  flag="$files.down"
  jq -r '.files[] | .filename, (.previous_filename // empty)' "$cmp" 2>/dev/null | awk 'NF && !seen[$0]++' > "$files"
  lines=$(jq '[.files[] | ((.additions // 0) + (.deletions // 0))] | add // 0' "$cmp" 2>/dev/null)
  nf=$(jq '.files | length' "$cmp" 2>/dev/null)
  # The rows were read above, once: the subshell does not read them again.
  out=$(_rt_score_shim "$flag"; qr_rules_load() { :; }; qr_score "$files" "$lines" "$nf" "$slug" "$n")
  IFS=$'\t' read -r sc _ _ reasons <<<"$out"
  if [ -e "$flag" ]; then RT_EVIDENCE_WHY="queue-risk score unreadable (attempt history unreadable)"
  else
    case ",$reasons," in
      *,rows-unreadable,*|*,files-unavailable,*|*,history-unread,*) RT_EVIDENCE_WHY="queue-risk score unreadable ($reasons)" ;;
      *) case "$sc" in ''|*[!0-9]*) RT_EVIDENCE_WHY="queue-risk score unreadable (score '${sc:0:20}')" ;; *) RT_EVIDENCE_SCORE="$sc" ;; esac ;;
    esac
  fi
  rm -f "$files" "$flag"
  return 0
}

# _rt_evidence_lane <lines> — rule 2c: prints `evidence: ...` when every input
# holds, else `no evidence low: <the first that does not>`.
_rt_evidence_lane() {
  local lines="$1" s="${RT_EVIDENCE_SCORE:-}" k="${RT_EVIDENCE_SUITES:-}" max="$RT_LOW_SCORE_MAX" min="${RT_LOW_MIN_SUITES:-$RT_LOW_MIN_SUITES_DEFAULT}"
  if [ -n "${RT_EVIDENCE_WHY:-}" ]; then printf 'no evidence low: %s' "$RT_EVIDENCE_WHY"; return 0; fi
  if [ -z "$s$k${RT_EVIDENCE_PREQUEUE:-}" ]; then printf 'no evidence low: no evidence read for this head'; return 0; fi
  case "$k" in ''|*[!0-9]*) printf 'no evidence low: no builder-gate count for this head'; return 0 ;; esac
  if [ "$k" -lt "$min" ]; then printf 'no evidence low: %s suites green on head, under %s' "$k" "$min"; return 0; fi
  if [ "${RT_EVIDENCE_PREQUEUE:-}" != green ]; then printf 'no evidence low: prequeue-verdict not green'; return 0; fi
  case "$s" in ''|*[!0-9]*) printf 'no evidence low: queue-risk score unreadable'; return 0 ;; esac
  if [ "$s" -ge "$max" ]; then printf 'no evidence low: queue-risk score %s, not under %s' "$s" "$max"; return 0; fi
  printf 'evidence: score %s under %s, %s suites green on head, prequeue-verdict green, %s lines' "$s" "$max" "$k" "$lines"
}

rt_classify() {
  local cmp="$1" slug="$2" nfiles lines paths names la la_ok=1 hits p add notlow="" nnot=0 nweak=0 weak="" tier reasons lowmax
  jq -e '(.files | type) == "array"' "$cmp" >/dev/null 2>&1 || return 2
  nfiles=$(jq '.files | length' "$cmp") || return 2
  lines=$(jq '[.files[] | ((.additions // 0) + (.deletions // 0))] | add // 0' "$cmp") || return 2
  [ "${RT_RULES_LOADED:-}" = 1 ] || rt_rules_load
  if [ "$nfiles" -ge 300 ]; then
    printf 'high\tdiff too large to read whole (%s files)\t%s\t%s\n' "$nfiles" "$lines" "$nfiles"; return 0
  fi
  # <path>\t<1 when the file is new (status added)>. A rename's old name is a
  # deleted path, so never new.
  paths=$(mktemp "${TMPDIR:-/tmp}/risk-tier.XXXXXX") || return 2
  jq -r '.files[] | (if .status == "added" then "1" else "0" end) as $a
    | "\(.filename)\t\($a)", (.previous_filename // empty | "\(.)\t0")' "$cmp" | awk -F'\t' 'NF && !seen[$1]++' > "$paths"
  # Rule 1. The lead's protected globs are always in: unreadable caps at medium.
  la=""
  if command -v la_globs >/dev/null 2>&1; then la=$(la_globs "$slug" 2>/dev/null) || la_ok=0; else la_ok=0; fi
  names="$paths.names"; cut -f1 "$paths" > "$names"
  hits=$(_rt_hits "$names" "$RT_HIGH_GLOBS $RT_SENSITIVE_GLOBS $(printf '%s' "$la" | tr '\n' ' ')"); rm -f "$names"
  if [ -n "$hits" ]; then
    rm -f "$paths"; printf 'high\t%s\t%s\t%s\n' "$hits" "$lines" "$nfiles"; return 0
  fi
  # Rule 2. A low path is in the row's low globs AND either the ceiling or a
  # new test file. Any other test path (an existing test, a helper, a fixture)
  # is named as such.
  while IFS=$'\t' read -r p add; do
    [ -n "$p" ] || continue
    if _rt_any "$p" "$RT_LOW_GLOBS"; then
      _rt_any "$p" "$RT_LOW_CEILING" && continue
      [ "$add" = 1 ] && _rt_new_test "$p" && continue
    fi
    case "$p" in tests/*|console-ui/tests/*) nweak=$((nweak + 1)); weak="$p" ;; esac
    nnot=$((nnot + 1)); notlow="$p"
  done < "$paths"
  rm -f "$paths"
  lowmax="$RT_LOW_LINES"; [ "$lowmax" -gt "$RT_LOW_LINES_MAX" ] && lowmax="$RT_LOW_LINES_MAX"
  tier=""; reasons=""
  if [ "$nfiles" -eq 0 ]; then
    tier=medium; reasons="empty diff"
  elif [ "$nnot" -eq 0 ]; then
    if [ "$lines" -lt "$lowmax" ]; then tier=low; reasons="docs, screens or new tests only, $lines lines"
    else tier=medium; reasons="$lines lines, over low limit $lowmax"; fi
  elif [ "$nweak" -gt 0 ]; then
    reasons="$weak is an existing test file, a test helper or a fixture"
  elif rt_rules_shape "$cmp"; then
    # Rule 2b.
    reasons=$(_rt_rules_lane "$cmp" "$lines")
    [ "$reasons" = low ] && { tier=low; reasons="rules-text: $lines lines, render check passed"; }
  elif [ "${RT_LOW_SCORE_MAX:-0}" -gt 0 ] && [ "$lines" -lt "$lowmax" ]; then
    # Rule 2c.
    reasons=$(_rt_evidence_lane "$lines")
    case "$reasons" in
      evidence:*) tier=low ;;
      *) reasons="$nnot path(s) outside the low globs, e.g. $notlow; $reasons" ;;
    esac
  fi
  # Rules 3 and 4.
  if [ -z "$tier" ]; then
    if [ "$lines" -gt "$RT_HIGH_LINES" ]; then tier=high; reasons="${reasons:+$reasons; }$lines lines, over $RT_HIGH_LINES"
    elif [ "$nfiles" -gt "$RT_HIGH_FILES" ]; then tier=high; reasons="${reasons:+$reasons; }$nfiles files, over $RT_HIGH_FILES"
    else tier=medium; reasons="${reasons:-$nnot path(s) outside the low globs, e.g. $notlow}"; fi
  fi
  # Unreadable is never low.
  if [ "$tier" = low ]; then
    if [ -n "${RT_RULES_UNREADABLE:-}" ]; then tier=medium; reasons="rules unreadable; $reasons"
    elif [ "$la_ok" != 1 ]; then tier=medium; reasons="protected paths unreadable; $reasons"; fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$tier" "$(printf '%s' "$reasons" | tr '\t\n' '  ' | head -c 1000)" "$lines" "$nfiles"
}
