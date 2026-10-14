#!/bin/bash
# shellcheck shell=bash
# bin/lib/dequeue-watch/classify.sh — BH-3728 (BH-3719.2): a failed merge-queue
# batch log into a class, a rule id, a hint and the fix-round brief the
# dequeue-watch lane (BH-3719) hands blocked-resolver as record_in.dequeue.brief.
# Sourced, never run.
#
# PURE, like attribute.sh beside it: no network, no clock, no jobs calls, and the
# only root it reads is ${HARNESS:-${H:-}} for the rules pack, refusing when that
# is empty (D43). The class names are the ones bin/lib/jobs/dequeue-watch.sh fixes.
#
#   dqw_parse_log <log-file>
#       A `--log-failed` log (`<job>\t<step>\t<ISO time> <text>`). Suite blocks
#       open at `--- tests/<x>.sh rc=<n>` (bin/test-trace-safety.sh --gate) and
#       run to the next `--- `; only rc 1-9 is live. Prints `suite<TAB>line` per
#       FAIL line of a live block (a live block with none prints one
#       `suite<TAB>(no FAIL line)` row), secrets masked, each line cut to 300,
#       at most DEQUEUE_WATCH_FAIL_LINES (40) rows, then `-<TAB>(truncated)` when
#       rows were dropped. rc 1 with nothing printed when no block is live.
#   dqw_rule_id <suite> [rules-pack.tsv]
#       The rules-pack id whose kind=suite row runs <suite>. rc 1 when none.
#   dqw_classify key=value...
#       main_red, mergeable, stale, checks, rerun_green, attribution, parsed
#       (the dqw_parse_log output file), rules. Prints `class<TAB>how<TAB>rule_id`,
#       first match wins. A missing key is its fail-safe value, and attribution
#       `unknown` never reads as bystander.
#   dqw_hint <class> <rule_id>
#       One line for a class a fix round answers; rc 1 for the rest.
#   dqw_brief <class> <rule_id> <suite> <parsed-file> <run_url>
#       The fix round's brief. It never carries a 40-hex sha: the fix-round
#       preflight reads "of <sha>" as the head findings were written against
#       (frp_findings_head) and would route the round to a re-review.

[ -n "${_DQW_CLASSIFY_SH:-}" ] && return 0
_DQW_CLASSIFY_SH=1

dqw_parse_log() {
  local f="${1:-}" cap="${DEQUEUE_WATCH_FAIL_LINES:-40}" rows n
  case "$cap" in ''|0|*[!0-9]*) cap=40 ;; esac
  [ -r "$f" ] || return 1
  rows=$(awk '
    { sub(/^[^\t]*\t[^\t]*\t/, "")
      sub(/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9:.]+Z ?/, "")
      gsub(/\t/, " ") }
    /^--- / {
      if (live && !hit) print suite "\t(no FAIL line)"
      live = 0; hit = 0
      if ($2 ~ /^tests\/[^ ]+\.sh$/ && $3 ~ /^rc=[1-9]$/) { live = 1; suite = $2 }
      next }
    live && index($0, "FAIL") { hit = 1; print suite "\t" $0 }
    END { if (live && !hit) print suite "\t(no FAIL line)" }' "$f" \
    | sed -E 's/(^|[^A-Za-z0-9_])(gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]{16,}/\1\2[masked]/g' \
    | awk -F'\t' '{ print $1 "\t" substr($2, 1, 300) }')
  # ^ the mask is bin/needs-human-hold.sh's, verbatim: a token starts a word and
  #   runs at least 16 characters.
  [ -n "$rows" ] || return 1
  n=$(printf '%s\n' "$rows" | wc -l)
  head -n "$cap" <<<"$rows"
  [ "$n" -gt "$cap" ] && printf -- '-\t(truncated)\n'
  return 0
}

dqw_rule_id() {
  local suite="${1:-}" pack="${2:-}" root="${HARNESS:-${H:-}}" id
  if [ -z "$pack" ]; then
    [ -n "$root" ] || return 1
    pack="$root/catalog/rules-pack.tsv"
  fi
  [ -n "$suite" ] && [ -r "$pack" ] || return 1
  id=$(awk -F'\t' -v s="$suite" '!/^#/ && $3 == "suite" && $4 == s { print $1; exit }' "$pack")
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# _dqw_suites <parsed-file> — the parsed rows' suites, in order, `-` rows left out.
_dqw_suites() {
  [ -r "${1:-}" ] || return 0
  awk -F'\t' '$1 != "-" && $1 != "" { print $1 }' "$1"
}

dqw_classify() {
  local kv main_red=0 mergeable=- stale=0 checks=- rerun_green=0 attribution=unknown parsed="" rules="" re first rid
  for kv in "$@"; do
    case "$kv" in
      main_red=*) main_red="${kv#*=}" ;;       mergeable=*) mergeable="${kv#*=}" ;;
      stale=*) stale="${kv#*=}" ;;             checks=*) checks="${kv#*=}" ;;
      rerun_green=*) rerun_green="${kv#*=}" ;; attribution=*) attribution="${kv#*=}" ;;
      parsed=*) parsed="${kv#*=}" ;;           rules=*) rules="${kv#*=}" ;;
    esac
  done
  re="${DQW_SCANNER_RE:-gitleaks|leakcheck|generic-api-key|share-publish-clean}"
  first=$(_dqw_suites "$parsed" | head -1)
  [ "$main_red" = 1 ] && { printf 'main-red\tmain-red\t-\n'; return 0; }
  [ "$mergeable" = dirty ] && { printf 'textual-conflict\tmergeable\t-\n'; return 0; }
  { [ "$stale" = 1 ] || [ "$checks" = lead-verdict ]; } && { printf 'stale-status\tstale\t-\n'; return 0; }
  [ "$rerun_green" = 1 ] && { printf 'flake\trerun\t-\n'; return 0; }
  [ "$attribution" = bystander ] && { printf 'bystander\tattribution\t-\n'; return 0; }
  [ -n "$first" ] && awk -F'\t' '$1 != "-"' "$parsed" | grep -qE "$re" && { printf 'scanner-fp\tregex\t-\n'; return 0; } # DQW_RULE_SCANNER
  [ -n "$first" ] && rid=$(dqw_rule_id "$first" "$rules") && { printf 'rule-break\trule\t%s\n' "$rid"; return 0; }
  [ -n "$first" ] && { printf 'semantic-test\tsuite\t-\n'; return 0; }
  printf 'unclassified\tnone\t-\n'
}

dqw_hint() {
  case "${1:-}" in
    scanner-fp)       echo "Reword the flagged identifier or placeholder so the scanner no longer matches. Never add an allowlist entry." ;;
    rule-break)       echo "This breaks the rules-pack rule ${2:--}. Fix the flagged lines on this branch. Do not change the rule or its suite." ;;
    semantic-test)    echo "A test went red on this change. Fix the code. If a test really is wrong, change it and say why on a TEST-CHANGE: line; the lead reviews it." ;;
    textual-conflict) echo "This branch no longer merges with main. Merge origin/main in and keep both sides' intent." ;;
    unclassified)     echo "Read the FAIL lines below and fix the cause on this branch." ;;
    *) return 1 ;;
  esac
}

dqw_brief() {
  local class="${1:-}" rid="${2:-}" suite="${3:-}" parsed="${4:-}" url="${5:-}" hint hdr="FAIL lines:"
  hint=$(dqw_hint "$class" "$rid") || hint=-
  [ -r "$parsed" ] && grep -qxF -- $'-\t(truncated)' "$parsed" && hdr="FAIL lines (truncated):"
  {
    echo "## Mergify dequeued this PR (dequeue-watch, BH-3719)"
    echo "Class: ${class:--}"
    echo "Rule: ${rid:--}"
    echo "Failing suite: ${suite:--}"
    echo "Batch run: ${url:--}"
    echo "Hint: $hint"
    echo "$hdr"
    [ -r "$parsed" ] && awk -F'\t' '$1 != "-" { print "- " $2 }' "$parsed"
  } | sed -E 's/([0-9a-f]{12})[0-9a-f]{28,}/\1/g'
}
