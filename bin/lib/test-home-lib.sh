#!/bin/bash
# bin/lib/test-home-lib.sh — the fleet's ONE definition of "test path",
# "PER-TICKET test path", the `REROUTE tests:` record format and the two
# sentences (planner rule, executor note) that carry the rule to a model (#580).
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source time.
#
# WHY ONE FILE. Test files are the largest merge-conflict surface in the fleet
# (20 of 24 unresolvable conductor cases), every one a sibling APPENDING cases to
# a shared tests/<tier>/<area>.test.ts. The fix is "a ticket adds its OWN test
# file, named for the ticket"; this is the shared spelling of it, so the planner,
# the pre-plan list rewrite and the executor prompt cannot drift apart.
# Wired into bin/overlap-guard.sh (the launch-time reroute) and bin/fly-pool.sh
# (push_reroute, the relay to a pool machine) by BH-584; the executor half
# (th_exec_note, th_plan_rule) is still #580's other children.
#
#   th_record_path <harness> <project> <KEY>   the record: state/preplan-files/<project>-<KEY>
#   th_relay_path <project> <KEY>              its flat copy on a pool machine
#   th_enabled <harness>                       kill switch: TEST_REROUTE=0 / switch.test-reroute-off row, else flags/test-reroute-off

th_is_test_path() { # th_is_test_path <p> — SAME arms as bin/test-tamper-scan.sh:is_test_path
  case "${1:-}" in
    */test/*|*/tests/*|*/__tests__/*|*/spec/*|test/*|tests/*|spec/*) return 0 ;;
    *.test.*|*.spec.*|*_test.go|*_test.py|test_*.py|*Test.java|*Tests.cs) return 0 ;;
    *test*.sh) return 0 ;;
    *) return 1 ;;
  esac
}
_th_key() { printf '%s' "${1:-}" | tr 'A-Z' 'a-z'; }
th_is_per_ticket() { # th_is_per_ticket <p> — basename carries a ticket key segment
  local b="${1:-}"; b="${b##*/}"
  [[ "$b" =~ \.[a-z]+-[0-9]+(\.|-test\.sh$) ]]
}
th_is_own() { # th_is_own <p> <KEY>
  local b="${1:-}" k; b="${b##*/}"; k=$(_th_key "${2:-}")
  [ -n "$k" ] || return 1
  case "$b" in *".$k."*|*".$k-test.sh") return 0 ;; *) return 1 ;; esac
}
th_per_ticket_path() { # th_per_ticket_path <p> <KEY> — prints the per-ticket path
  local p="${1:-}" k b d; k=$(_th_key "${2:-}")
  [ -n "$p" ] && [ -n "$k" ] || return 1
  th_is_own "$p" "$k" && { printf '%s\n' "$p"; return 0; }
  case "$p" in */*) d="${p%/*}/" ;; *) d="" ;; esac
  b="${p##*/}"
  case "$b" in
    *.test.*)  printf '%s%s.%s.test.%s\n' "$d" "${b%%.test.*}" "$k" "${b##*.test.}" ;;
    *.spec.*)  printf '%s%s.%s.spec.%s\n' "$d" "${b%%.spec.*}" "$k" "${b##*.spec.}" ;;
    *-test.sh) printf '%s%s.%s-test.sh\n' "$d" "${b%-test.sh}" "$k" ;;
    *.*)       printf '%s%s.%s.%s\n' "$d" "${b%.*}" "$k" "${b##*.}" ;;
    *)         printf '%s%s.%s\n' "$d" "$b" "$k" ;;
  esac
}
th_record_path() { printf '%s/state/preplan-files/%s-%s\n' "${1:-}" "${2:-}" "${3:-}"; }
th_relay_path()  { printf '%s/test-reroute-%s-%s\n' "${TEST_REROUTE_RELAY_DIR:-/run/harness}" "${1:-}" "${2:-}"; }
th_enabled() { # th_enabled <harness> — default ON; rc 1 is "do not reroute"
  [ "${TEST_REROUTE:-1}" = 0 ] && return 1
  command -v lane_switch >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
  HARNESS="${1:-}" lane_switch test-reroute-off file && return 1
  return 0
}
th_record_add() { # th_record_add <record> <shared> <target> — rc 1 means "not rerouted"
  local r="${1:-}" s="${2:-}" t="${3:-}" line
  [ -n "$r" ] && [ -n "$s" ] && [ -n "$t" ] || return 1
  line="REROUTE tests: $s -> $t"
  mkdir -p "$(dirname "$r")" 2>/dev/null || return 1
  grep -qxF "$line" "$r" 2>/dev/null && return 0
  { printf '%s\n' "$line" >> "$r"; } 2>/dev/null || return 1   # the redirect's own failure IS the rc 1
}
# The record format is parsed HERE and nowhere else, so its two consumers cannot
# read it differently. Prints `shared<TAB>target`; a missing, empty or
# header-only record prints nothing and is not an error.
_th_pairs() { [ -s "${1:-}" ] || return 0
  awk 'sub(/^REROUTE tests: /,""){i=index($0," -> "); if(i>1) printf "%s\t%s\n", substr($0,1,i-1), substr($0,i+4)}' "$1" 2>/dev/null
  return 0
}
th_apply() { # th_apply <record> <list> — swap each shared path for its target, whole line only
  local r="${1:-}" l="${2:-}" pairs s t
  [ -s "$r" ] && [ -f "$l" ] || return 0
  pairs=$(_th_pairs "$r")   # read every pair BEFORE the rewrite: record and list may be one file
  [ -n "$pairs" ] || return 0
  while IFS=$'\t' read -r s t; do
    [ -n "$s" ] && [ -n "$t" ] || continue
    grep -qxF "$t" "$l" && continue
    grep -qxF "$s" "$l" || continue
    awk -v s="$s" -v t="$t" '{print ($0==s ? t : $0)}' "$l" > "$l.th-tmp" 2>/dev/null && mv "$l.th-tmp" "$l" 2>/dev/null
  done <<< "$pairs"
  return 0
}
th_exec_note() { # th_exec_note <record> — one sentence per pair, each ending in a space
  local s t
  _th_pairs "${1:-}" | while IFS=$'\t' read -r s t; do
    printf "Write this ticket's new test cases to \`%s\`, NOT to \`%s\`: a sibling build already holds that file and the harness rerouted it. Do not create or append to \`%s\`. " "$t" "$s" "$s"
  done
}
th_plan_rule() { # th_plan_rule <KEY> — the planner sentence, key lower-cased in the examples
  local k; k=$(_th_key "${1:-}")
  printf "TEST FILES ARE PER-TICKET: new test cases go in a NEW file named for this ticket (\`tests/<tier>/<area>.%s.test.ts\`, shell suites \`tests/<area>.%s-test.sh\`), never appended to an existing shared test file, unless this ticket's scope is to CHANGE an existing test's behaviour (a bug reproduction next to the case it fixes, a spec change to an existing case). List the per-ticket file in the plan's files-to-touch. Each test asserts the fields this ticket owns, never the whole payload; a whole-output pin belongs only in a contract test (\`*.contract.test.*\` or a \`# contract-test\` header). TESTS THAT MUST CHANGE: an existing test of ANOTHER ticket (a name like \`tests/<area>.<other-key>-test.sh\`) changes only when it pins a premise this ticket changes. List each such test under '## Tests that must change', one line each as '- \`<path>\`: <the premise this ticket changes>', and name it in files-to-touch too; write 'None' when there is none. The PR body copies these lines as TEST-CHANGE: lines, and the pre-review self-check refuses an edit to another ticket's test without one. " "$k" "$k"
}
th_fragment_rule() { # th_fragment_rule <KEY> <repo-dir> — the shared-list sentence, only for a repo with worker/*/schema.d/
  local k d
  for d in "${2:-.}"/worker/*/schema.d; do
    [ -d "$d" ] || continue
    k=$(_th_key "${1:-}")
    # The schema name allows no dot, so a child key bh-5235.2 is bh-5235-2 there.
    printf "SHARED LISTS ARE FRAGMENTS: a new table is a new \`worker/<w>/schema.d/<yyyymmddhhmm>-%s-<name>.sql\` (the UTC minute you create it, then this ticket's key; never a picked NNNN number) plus \`bin/schema-build.sh --write\`; a new jobs-worker route family is \`worker/jobs/src/routes/<family>.js\` plus \`worker/jobs/test/route-table.d/%s-<family>.txt\`, never an \`index.js\` edit or a picked number. Never append to a shared list. " "${k//./-}" "$k"
    return 0
  done
  return 0
}
