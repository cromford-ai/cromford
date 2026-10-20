#!/bin/bash
# bin/lib/suite-reach-gate.sh — the execute stage's suite-reach gate. Sourced,
# never executed. Functions only. Root is ${HARNESS:-${H:-}}, no default.
#
# suite_reach_block <where>
#   Runs the build worktree's own bin/suite-reach-check.sh (cwd) against
#   ${SCOPE_BASE:-$BASE}, with the fly-pool knobs SUITE_REACH_CAP,
#   SUITE_REACH_BUDGET_S and SUITE_REACH_SUITE_TIMEOUT_S. Writes
#   $BUILD/suite-reach.txt (the check's output), $BUILD/suite-reach.md (its
#   table), one `SUITE_REACH rc=…` line to $BUILD/pipeline.log, and a paragraph
#   to GATES_NOTE.
#     rc 0                            clean: NOTE / TRANSIENT / NOT RUN lines to GATES_NOTE
#     rc 1 + `SUITE_REACH_VERDICT: red` + a `RED:` line
#                                     SUITE_REACH_BLOCK=0: warn only, GATES_NOTE
#                                     else: alert, escalate_block, RESULT
#                                     "REVIEW_BLOCKED suite-reach: …", exit 6
#     anything else                   could not run: GATES_NOTE (+ one ALERTS
#                                     line for rc 1 with no verdict); never blocks
#   A worktree with no executable bin/suite-reach-check.sh is skipped (rc 0).
#   The caller provides STAMP, RESULT, escalate_block, PROJECT, KEY, BUILD and
#   ALERTS, as bin/lib/rb/execute.sh does.

# _sr_knob <ENV> <default> — `lane_knob fly-pool <ENV> "$PROJECT"` when it is a
# whole number, else <default>. Resolved in a subshell so lane-gate.sh's
# globals never land in the driver.
_sr_knob() {
  local root="${HARNESS:-${H:-}}" v=""
  if [ -n "$root" ] && [ -r "$root/bin/lib/lane-gate.sh" ]; then
    v=$( . "$root/bin/lib/lane-gate.sh" 2>/dev/null && lane_knob fly-pool "$1" "${PROJECT:-}" 2>/dev/null )
  fi
  case "$v" in ''|*[!0-9]*) v=$2 ;; esac
  printf '%s' "$v"
}

_sr_log() { echo "$(STAMP) [${PROJECT:-}/${KEY:-}] $1" >> "$BUILD/pipeline.log"; }

suite_reach_block() {
  local where="${1:-execute}" root="${HARNESS:-${H:-}}" blk cap bud sto out rc t0 verdict n_red first sname scase
  if [ ! -x bin/suite-reach-check.sh ]; then
    _sr_log "suite-reach: skipped (repo carries no bin/suite-reach-check.sh)"
    return 0
  fi
  blk=$(_sr_knob SUITE_REACH_BLOCK 1)
  cap=$(_sr_knob SUITE_REACH_CAP 60)
  bud=$(_sr_knob SUITE_REACH_BUDGET_S 600)
  sto=$(_sr_knob SUITE_REACH_SUITE_TIMEOUT_S 300)
  out="$BUILD/suite-reach.txt"
  command -v STAGE_START >/dev/null 2>&1 && t0=$(STAGE_START)
  # A started suite can run three times (head, base, head again).
  timeout "$((bud + 3 * sto + 120))" bin/suite-reach-check.sh --tree . --base "${SCOPE_BASE:-${BASE:-}}" \
    --cap "$cap" --budget "$bud" --suite-timeout "$sto" --table "$BUILD/suite-reach.md" > "$out" 2>&1
  rc=$?
  [ -n "${t0:-}" ] && command -v STAGE_END >/dev/null 2>&1 && STAGE_END gates.suite-reach "$t0"
  verdict=$(sed -n 's/^SUITE_REACH_VERDICT: \([a-z]*\).*/\1/p' "$out" | tail -1)
  n_red=$(grep -c '^RED: ' "$out")
  _sr_log "SUITE_REACH rc=$rc verdict=${verdict:-none} red=$n_red note=$(grep -c '^\[NOTE\] ' "$out") transient=$(grep -c '^TRANSIENT: ' "$out") notrun=$(grep -c '^NOT RUN: ' "$out")"

  if [ "$rc" = 0 ] && [ -n "$verdict" ]; then
    GATES_NOTE="${GATES_NOTE:-}"$'\n'"SUITE-REACH GATE: clean — every suite that names a changed file and ran is green on this head, or was red on the merge base too. Table: $BUILD/suite-reach.md"
    if grep -qE '^(\[NOTE\] |TRANSIENT: |NOT RUN: )' "$out"; then
      GATES_NOTE="$GATES_NOTE"$'\n'"$(grep -E '^(\[NOTE\] |TRANSIENT: |NOT RUN: )' "$out")"
    fi
    return 0
  fi
  if [ "$rc" = 1 ] && [ "$verdict" = red ] && [ "$n_red" -gt 0 ]; then
    first=$(grep -m1 '^RED: ' "$out")
    sname=$(sed -n 's/^RED: \([^ ]*\) .*/\1/p' <<< "$first")
    scase=$(sed -n 's/.* case: //p' <<< "$first")
    if [ "$blk" = 0 ]; then
      GATES_NOTE="${GATES_NOTE:-}"$'\n'"SUITE-REACH GATE: green→red (warn-only, SUITE_REACH_BLOCK=0) — $n_red suite(s) pass on the merge base and fail on this head. Each is a [BLOCK weakened-test] candidate: fix the code, or amend the suite with a TEST-CHANGE: line. Table: $BUILD/suite-reach.md"$'\n'"$(grep '^RED: ' "$out")"
      return 0
    fi
    [ -n "$root" ] && [ -x "$root/bin/alert-line.sh" ] && "$root/bin/alert-line.sh" --project "${PROJECT:-}" \
      "[${PROJECT:-}/${KEY:-}] BLOCKED: $n_red suite(s) green on the merge base and red on this head (suite-reach) ($where)"
    command -v escalate_block >/dev/null 2>&1 \
      && escalate_block "suite-reach" "$n_red suite(s) passed on the merge base and fail on this head: $first"
    RESULT "REVIEW_BLOCKED suite-reach: $n_red suite(s) green on base, red on head: $sname ($scase); see $BUILD/suite-reach.txt"
    exit 6
  fi
  if [ "$rc" = 1 ]; then
    echo "$(STAMP) [${PROJECT:-}/${KEY:-}] suite-reach check exited 1 without a red verdict (crash?) — NOT blocking" >> "${ALERTS:-/dev/null}"
  fi
  GATES_NOTE="${GATES_NOTE:-}"$'\n'"SUITE-REACH GATE: could not run (rc=$rc) — not a pass. Suites that name the changed files were not compared head vs base on this build:"$'\n'"$(tail -5 "$out")"
  return 0
}
