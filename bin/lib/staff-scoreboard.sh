#!/bin/bash
# bin/lib/staff-scoreboard.sh — BH-9422 (C4 of BH-9187): the staff lever
# scoreboard for the weekly overlook report (bin/archie-overlook.sh) and
# Archie's turn briefing (bin/orchestrate.sh compose_v2_prompt). Sourced, never
# executed. It reads GET /api/staff/levers/scoreboard (worker/jobs/src/routes/
# staff-scoreboard.js): every staff agent's scorecard, Archie excluded, over
# the window of the settings row staff.scorecard_days (7). It writes nothing.
#
# staff_scoreboard_get <out-file>
#   One _jobs_req GET. rc 0 and a body whose .agents is an array: the body goes
#   to <out-file>, rc 0. Else rc 1 and ONE reason word on stdout: http=<code>
#   or curl_rc=<n> (jobs-client's status), rc=<n> when the client gave no
#   status, no-jobs-client when _jobs_req is not loaded, bad-body.
# staff_scoreboard_line <file> <agent>
#   One line, for example:
#     hours_behind_main now 3 (7d ago 41), target 2, level observe; actions 2, moved 1 of 2 settled, precision 50%
#   A null sample is `no sample` (never 0), a null target `target n/a`, a null
#   metric `no metric row`, a null precision `precision n/a` (never 0%).
#   Numbers keep at most 2 decimals. An agent not in the file is
#   `not on the scoreboard`. precision is LEVER precision: moved / settled lever
#   actions, not the issue-verdict precision of the report's agent line.
# archie_staff_metrics_timeout_s
#   KNOB: ARCHIE_STAFF_METRICS_TIMEOUT_S (default 5; registry
#   catalog/lanes.d/archie.knobs.d/ARCHIE_STAFF_METRICS_TIMEOUT_S.json,
#   settings row lane.archie.archie_staff_metrics_timeout_s). The env, else
#   lane_knob archie when lane-gate.sh is loaded, else 5. Not digits or outside
#   1..30 is 5.
# archie_staff_metrics_block
#   The `=== STAFF METRICS (lever scorecards, <days>d window) ===` section and
#   one `- <agent>: <line>` per agent. One request, JOBS_TIMEOUT = the knob, no
#   retry, so a down worker adds at most that many seconds to a turn. A failed
#   read prints `UNREADABLE staff scoreboard (<reason>)`. Always rc 0.
#   SANDBOX: under HARNESS_TEST_SANDBOX=1 it makes no request unless
#   ARCHIE_STAFF_METRICS_SANDBOX=1, and prints the header and
#   `(not read: test sandbox)` (BH-7563: a test does not call the worker).
#
# Root: ${HARNESS:-${H:-}} (only to source bin/jobs-client.sh when _jobs_req is
# absent). Test: tests/staff-scoreboard.bh-9422-test.sh.
# Note: docs/notes/2026-11-11-BH-9422-staff-report-screens.md.

staff_scoreboard_get() {
  local out="$1" sf body rc reason
  command -v _jobs_req >/dev/null 2>&1 || { echo no-jobs-client; return 1; }
  sf=$(mktemp "${TMPDIR:-/tmp}/staff-scoreboard.XXXXXX") || { echo mktemp; return 1; }
  body=$(JOBS_STATUS_FILE="$sf" _jobs_req GET /api/staff/levers/scoreboard); rc=$?
  reason=$(head -1 "$sf" 2>/dev/null); rm -f "$sf"
  if [ "$rc" -ne 0 ]; then
    [ -n "$reason" ] && [ "$reason" != "http=200" ] || reason="rc=$rc"
    echo "$reason"; return 1
  fi
  jq -e '.agents | type == "array"' >/dev/null 2>&1 <<<"$body" || { echo bad-body; return 1; }
  printf '%s\n' "$body" > "$out" || { echo write; return 1; }
}

staff_scoreboard_line() {
  jq -r --arg a "$2" '
    def num: (. * 100 | round) / 100 | tostring;
    def smp: if . == null or .value == null then "no sample" else .value | num end;
    (.days // 7) as $d
    | ([.agents[]? | select(.agent == $a)] | first) as $e
    | if $e == null then "not on the scoreboard"
      else
        (if $e.metric == null then "no metric row"
         else "\($e.metric) now \($e.metric_now | smp) (\($e.days // $d)d ago \($e.metric_then | smp))" end)
        + ", target " + (if $e.target == null then "n/a" else ($e.target | num) end)
        + ", level " + ($e.level // "observe")
        + "; actions \($e.actions // 0), moved \($e.moved // 0) of \($e.settled // 0) settled, precision "
        + (if $e.precision == null then "n/a" else "\($e.precision * 100 | round)%" end)
      end' "$1" 2>/dev/null || echo "not on the scoreboard"
}

archie_staff_metrics_timeout_s() {
  # Fallback 5 = the registry default of ARCHIE_STAFF_METRICS_TIMEOUT_S
  # (catalog/lanes.d/archie.knobs.d/, row lane.archie.archie_staff_metrics_timeout_s).
  local s="${ARCHIE_STAFF_METRICS_TIMEOUT_S:-}"
  if [ -z "$s" ] && command -v lane_knob >/dev/null 2>&1; then
    s=$(lane_knob archie ARCHIE_STAFF_METRICS_TIMEOUT_S 2>/dev/null)
  fi
  if ! [[ ${s:-} =~ ^[0-9]{1,3}$ ]] || [ "$((10#$s))" -lt 1 ] || [ "$((10#$s))" -gt 30 ]; then s=5; fi
  printf '%s\n' "$((10#$s))"
}

archie_staff_metrics_block() {
  local h="${HARNESS:-${H:-}}" to f reason days a
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ "${ARCHIE_STAFF_METRICS_SANDBOX:-}" != 1 ]; then
    printf '=== STAFF METRICS (lever scorecards) ===\n(not read: test sandbox)\n'
    return 0
  fi
  to=$(archie_staff_metrics_timeout_s)
  f=$(mktemp "${TMPDIR:-/tmp}/staff-metrics.XXXXXX") || {
    printf '=== STAFF METRICS (lever scorecards) ===\nUNREADABLE staff scoreboard (mktemp)\n'; return 0; }
  # The request runs in a subshell: a jobs-client sourced here and the
  # per-request JOBS_* values never reach the caller's shell.
  reason=$(
    if ! command -v _jobs_req >/dev/null 2>&1 && [ -n "$h" ] && [ -r "$h/bin/jobs-client.sh" ]; then
      # shellcheck source=bin/jobs-client.sh
      . "$h/bin/jobs-client.sh" >/dev/null 2>&1
    fi
    JOBS_TIMEOUT="$to" JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 staff_scoreboard_get "$f"
  ) || {
    printf '=== STAFF METRICS (lever scorecards) ===\nUNREADABLE staff scoreboard (%s)\n' "${reason:-unknown}"
    rm -f "$f"; return 0
  }
  days=$(jq -r '.days // 7' "$f" 2>/dev/null)
  printf '=== STAFF METRICS (lever scorecards, %sd window) ===\n' "${days:-7}"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    printf -- '- %s: %s\n' "$a" "$(staff_scoreboard_line "$f" "$a")"
  done < <(jq -r '.agents[]?.agent // empty' "$f" 2>/dev/null)
  rm -f "$f"
  return 0
}
