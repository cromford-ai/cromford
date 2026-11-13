#!/bin/bash
# bin/lib/fixround-repro.sh — a ci-red fix round reproduces the failing CI
# test on the box before it spends an agent call or pushes (BH-9285 Fix 4,
# BH-9472). Sourced, never executed. Functions only.
#
# WHY. A fix round on a red CI head used to push the agent's guess with no
# local proof: the round's verify ran the repo's whole unit suite on the box
# locale, which was green on the box while the one CI test stayed red. The
# next CI run was red again and the ladder spent its next rung on the same
# guess.
#
# CONTRACT
#   frr_on                 rc 0 when the gate is on. Knob FIXROUND_REPRO_GATE
#                          (row lib.fixround-repro[.<project>].fixround_repro_gate);
#                          anything but 0 or 1 reads the registry default.
#   frr_failing_tests <slug> <sha> <tree>
#                          The failing test files of the CI of <sha>, one per
#                          line, sorted, unique. rc:
#                            0  every failed job named at least one test file
#                               that is a regular file in <tree>
#                            2  the CI, a job list or a job log could not be read
#                            3  not gated: CI is not red, or a failed run or
#                               job names no test file (typecheck, lint, build,
#                               a check that is not an Actions job). ONE such
#                               job makes the whole set rc 3, so a test that is
#                               green here never hides a red in another job.
#                          Call it in this shell (stdout to a file):
#                          FRR_CI_URLS is the JSON array of the failed runs' urls.
#   frr_reproduce <tree> <out> <file>...
#                          Runs the files once (bin/lib/verify-run.sh
#                          vr_run_files: CI locale, throwaway Postgres, budget).
#                            reproduced      rc 1  red here, as in CI
#                            not-reproduced  rc 0  green here
#                            could-not-run   rc 2  never either of the above
#   frr_confirm <tree> <out> <file>...
#                          The same run after the agent:
#                            passes rc 0 | still-red rc 1 | could-not-run rc 2
#   FRR_WHY holds the reason after a could-not-run (VR_WHY of the run). Call
#   both in this shell (`w=$(frr_reproduce ...)` loses FRR_WHY).
#   The budget is cl_budget (CI_LOCAL_BUDGET_S, bin/lib/ci-local-verify.sh),
#   lowered by CL_BUDGET_CAP when the caller sets it.
#
# FAILING TEST LINES READ FROM A JOB LOG (timestamp and colour stripped):
#   vitest   " FAIL  tests/a.test.ts > suite > case"  (also "|project| tests/...")
#   jest     "FAIL tests/a.test.js"  (an optional "(5.1 s)" after it)
#   harness  "--- tests/a-test.sh rc=1 12s"  (bin/test-trace-safety.sh, rc != 0)
#   A path must be relative, without "..", not start with "-", and be a regular
#   file (not a symlink) in <tree>. Anything else is not a test name.
#
# Knobs: FIXROUND_REPRO_GATE, FIXROUND_REPRO_LOG_MAX_KB
# (catalog/lanes.d/_lib.fixround-repro.json).

_FRR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _frr_l in gh-ci-read.sh fixround-preflight.sh ci-local-verify.sh ci-env.sh verify-run.sh; do
  case "$_frr_l" in
    gh-ci-read.sh)         command -v gh_ci_api >/dev/null 2>&1 && continue ;;
    fixround-preflight.sh) command -v frp_ci >/dev/null 2>&1 && continue ;;
    ci-local-verify.sh)    command -v cl_budget >/dev/null 2>&1 && continue ;;
    ci-env.sh)             command -v ce_resolve >/dev/null 2>&1 && continue ;;
    verify-run.sh)         command -v vr_run_files >/dev/null 2>&1 && continue ;;
  esac
  # shellcheck source=/dev/null
  [ -r "$_FRR_LIB/$_frr_l" ] && . "$_FRR_LIB/$_frr_l"
done
unset _frr_l

# _frr_default <ENV> — the knob's default from this lib's registry fragment,
# under the harness root first and beside this lib second.
_frr_default() {
  local f root="${HARNESS:-${H:-}}" v=""
  for f in ${root:+"$root/catalog/lanes.d/_lib.fixround-repro.json"} \
           "$_FRR_LIB/../../catalog/lanes.d/_lib.fixround-repro.json"; do
    [ -r "$f" ] || continue
    v=$(jq -r --arg e "$1" '.libs[]? | select(.id == "fixround-repro") | .knobs[]?
               | select(.env == $e) | .default // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && break
  done
  printf '%s' "$v"
}

# _frr_knob <ENV> — lane_knob in libs scope (with $PROJECT) when the caller
# has it, else the harness root's lane-gate.sh in a subshell, else the env.
_frr_knob() {
  local _LG_KIND=libs v="" root="${HARNESS:-${H:-}}" lg
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob fixround-repro "$1" "${PROJECT:-}" 2>/dev/null)
  else
    for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$_FRR_LIB/lane-gate.sh"; do
      [ -r "$lg" ] || continue
      v=$( . "$lg" 2>/dev/null && _LG_KIND=libs lane_knob fixround-repro "$1" "${PROJECT:-}" 2>/dev/null )
      break
    done
  fi
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "$v"
}

frr_on() {
  local v
  v=$(_frr_knob FIXROUND_REPRO_GATE)
  case "$v" in 0|1) ;; *) v=$(_frr_default FIXROUND_REPRO_GATE) ;; esac
  # An unreadable registry leaves the gate on: a run that cannot happen is
  # could-not-run, and could-not-run keeps today's round.
  [ "$v" != 0 ]
}

# _frr_log_max_kb — FIXROUND_REPRO_LOG_MAX_KB, 1..65536, else the registry
# default, else 2048 (the documented last fallback of the row
# lib.fixround-repro.fixround_repro_log_max_kb).
_frr_log_max_kb() {
  local v
  v=$(_frr_knob FIXROUND_REPRO_LOG_MAX_KB)
  case "$v" in ''|*[!0-9]*) v="" ;; *) { [ "$v" -lt 1 ] || [ "$v" -gt 65536 ]; } && v="" ;; esac
  [ -n "$v" ] || v=$(_frr_default FIXROUND_REPRO_LOG_MAX_KB)
  case "$v" in ''|*[!0-9]*) v=2048 ;; esac
  printf '%s' "$v"
}

# frr_verify_tail_bytes — FIXROUND_REPRO_VERIFY_TAIL_BYTES, 1..1048576, else
# the registry default, else 4000 (the documented last fallback of the row
# lib.fixround-repro.fixround_repro_verify_tail_bytes).
frr_verify_tail_bytes() {
  local v
  v=$(_frr_knob FIXROUND_REPRO_VERIFY_TAIL_BYTES)
  case "$v" in ''|*[!0-9]*) v="" ;; *) { [ "$v" -lt 1 ] || [ "$v" -gt 1048576 ]; } && v="" ;; esac
  [ -n "$v" ] || v=$(_frr_default FIXROUND_REPRO_VERIFY_TAIL_BYTES)
  case "$v" in ''|*[!0-9]*) v=4000 ;; esac
  printf '%s' "$v"
}

# _frr_parse <tree> — job log on stdin, the test files it names on stdout.
_frr_parse() {
  local tree="${1:-}" f
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //' \
  | sed -nE \
      -e 's/^[[:space:]]*FAIL[[:space:]]+(\|[^|]+\|[[:space:]]+)?([^[:space:]]+)[[:space:]]+>.*$/\2/p' \
      -e 's/^[[:space:]]*FAIL[[:space:]]+([^[:space:]]+)([[:space:]]+\([0-9.]+ m?s\))?[[:space:]]*$/\1/p' \
      -e 's/^--- ([^[:space:]]+\.sh) rc=0*[1-9][0-9]*( .*)?$/\1/p' \
  | while IFS= read -r f; do
      f="${f#./}"
      case "$f" in ''|-*|/*|*$'\r'*) continue ;; esac
      case "/$f/" in */../*) continue ;; esac
      [ -f "$tree/$f" ] && [ ! -L "$tree/$f" ] || continue
      printf '%s\n' "$f"
    done
}

# _frr_jobs_of_run <slug> <run-id> — the failed job ids of one workflow run.
# rc 2 when a page will not read.
_frr_jobs_of_run() {
  local slug="$1" rid="$2" page=1 resp total seen=0 n
  while :; do
    resp=$(GH_CI_READ_WHAT=actions/jobs gh_ci_api "$slug" \
           "repos/$slug/actions/runs/$rid/jobs?filter=latest&per_page=100&page=$page") || return 2
    jq -e '.jobs | type == "array"' >/dev/null 2>&1 <<<"$resp" || return 2
    jq -r '.jobs[] | select(.conclusion == "failure" or .conclusion == "timed_out") | .id' <<<"$resp" 2>/dev/null
    n=$(jq -r '.jobs | length' <<<"$resp" 2>/dev/null)
    total=$(jq -r '.total_count // 0' <<<"$resp" 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    seen=$((seen + n))
    [ "$n" -gt 0 ] && [ "$seen" -lt "$total" ] || break
    page=$((page + 1))
  done
  return 0
}

frr_failing_tests() {
  local slug="${1:-}" sha="${2:-}" tree="${3:-}" ci state url jid rid kb log names
  local jobs=() files=""
  [ -n "$slug" ] && [ -n "$sha" ] && [ -d "$tree" ] || return 2
  command -v frp_ci >/dev/null 2>&1 && command -v gh_ci_api >/dev/null 2>&1 || return 2
  FRR_CI_URLS='[]'
  ci=$(frp_ci "$slug" "$sha")
  state=$(jq -r '.state // "unreadable"' <<<"$ci" 2>/dev/null)
  FRR_CI_URLS=$(jq -c '[.runs[]? | select(.status == "completed"
                  and (.conclusion | IN("failure","timed_out","action_required","startup_failure"))) | .url // ""]' <<<"$ci" 2>/dev/null) \
    || FRR_CI_URLS='[]'

  case "$state" in
    red) ;;
    unreadable|'') return 2 ;;
    *) return 3 ;;
  esac
  while IFS= read -r url; do
    case "$url" in
      https://github.com/"$slug"/actions/runs/*/job/*)
        jid=${url##*/job/}; jid=${jid%%[!0-9]*}
        [ -n "$jid" ] || return 3
        jobs+=("$jid") ;;
      https://github.com/"$slug"/actions/runs/*)
        rid=${url##*/actions/runs/}; rid=${rid%%[!0-9]*}
        [ -n "$rid" ] || return 3
        local got
        got=$(_frr_jobs_of_run "$slug" "$rid") || return 2
        # A failed run with no failed job read is a red this gate cannot name.
        [ -n "$got" ] || return 3
        mapfile -t -O "${#jobs[@]}" jobs <<<"$got" ;;
      *) return 3 ;;
    esac
  done < <(jq -r '.runs[]? | select(.status == "completed"
                   and (.conclusion | IN("failure","timed_out","action_required","startup_failure")))
                 | .url // ""' <<<"$ci" 2>/dev/null)
  [ "${#jobs[@]}" -gt 0 ] || return 3
  kb=$(_frr_log_max_kb)
  while IFS= read -r jid; do
    [ -n "$jid" ] || continue
    log=$(GH_CI_READ_WHAT=actions/job-log gh_ci_api "$slug" "repos/$slug/actions/jobs/$jid/logs" --allow-escape-sequences) || return 2
    names=$(tail -c "$((kb * 1024))" <<<"$log" | _frr_parse "$tree")
    [ -n "$names" ] || return 3
    files="$files$names"$'\n'
  done < <(printf '%s\n' "${jobs[@]}" | LC_ALL=C sort -u)
  printf '%s' "$files" | sed '/^$/d' | LC_ALL=C sort -u
  return 0
}

# _frr_run <tree> <out> <file>... — vr_run_files in this shell (so VR_WHY
# survives) with the round's budget. Sets FRR_W to green|red|could-not-run and
# FRR_WHY to the could-not-run reason. Prints nothing.
_frr_run() {
  local tree="$1" out="$2" budget=""
  shift 2
  FRR_W=could-not-run; FRR_WHY=""
  command -v vr_run_files >/dev/null 2>&1 || { FRR_WHY="bin/lib/verify-run.sh not on this box"; return 2; }
  command -v cl_budget >/dev/null 2>&1 && budget=$(cl_budget)
  case "$budget" in ''|*[!0-9]*) FRR_WHY="no CI_LOCAL_BUDGET_S budget"; return 2 ;; esac
  case "${CL_BUDGET_CAP:-}" in ''|*[!0-9]*) ;; *) [ "$CL_BUDGET_CAP" -lt "$budget" ] && budget="$CL_BUDGET_CAP" ;; esac
  vr_run_files "$tree" "$out" "$budget" "$@" >/dev/null 2>&1
  case "$?" in
    0) FRR_W=green ;;
    1) FRR_W=red ;;
    *) FRR_WHY="${VR_WHY:-the runner gave no reason}" ;;
  esac
  return 0
}

frr_reproduce() {
  local tree="${1:-}" out="${2:-}"
  shift 2 2>/dev/null || { FRR_WHY="usage: frr_reproduce <tree> <out> <file>..."; echo could-not-run; return 2; }
  _frr_run "$tree" "$out" "$@"
  case "$FRR_W" in
    red)   echo reproduced; return 1 ;;
    green) echo not-reproduced; return 0 ;;
  esac
  echo could-not-run; return 2
}

frr_confirm() {
  local tree="${1:-}" out="${2:-}"
  shift 2 2>/dev/null || { FRR_WHY="usage: frr_confirm <tree> <out> <file>..."; echo could-not-run; return 2; }
  _frr_run "$tree" "$out" "$@"
  case "$FRR_W" in
    green) echo passes; return 0 ;;
    red)   echo still-red; return 1 ;;
  esac
  echo could-not-run; return 2
}
