#!/bin/bash
# bin/lib/ci-local-verify.sh — BH-6897. The one seam through which the build's
# pre-PR gate (bin/lib/prepr-gate.sh), bin/blocked-resolver.sh fix rounds and
# bin/lead-review.sh run bin/ci-local.sh. Sourced, never executed.
#
# WHY. On 2026-10-15 four of about fifteen approved PRs went red on a CI lint
# step after approval (#6858 state-paths guard, #6862 fixture-hygiene, #6867
# race-sigpipe-echo, a shellcheck/render red). The build ran the rules pack and
# a few fast lints, never the CI lint job itself. bin/ci-local.sh runs that
# job's steps from the workflow file, so the three lanes see what CI sees.
#
# CONTRACT
#   cl_on                 rc 0 when CI_LOCAL_GATE resolves to 1, rc 1 when 0.
#                         lane_knob (libs scope), then the env, then this lib's
#                         registry fragment default; anything not 0/1 is the
#                         fragment default. No literal here.
#   cl_budget             CI_LOCAL_BUDGET_S, resolved the same way; a value
#                         outside 60..3600 is the fragment default.
#   cl_run <bin> <tree> <base> <out> [args...]
#                         Runs `<bin> --tree <tree> --base <base> --out <out>
#                         --budget <cl_budget> [args...]` under a timeout of the
#                         budget plus 120 s, stdout to <out>.stdout, stderr to
#                         <out>.stderr. CL_BUDGET_CAP (seconds), when set and
#                         lower, replaces the budget. Prints one word:
#                           clean          rc 0  bin rc 0
#                           red            rc 1  bin rc 1 and a non-empty
#                                                <out>/findings.txt
#                           could-not-run  rc 2  any other rc (2, 124, ...), or
#                                                rc 1 with no finding
#                           skipped        rc 3  <bin> is not executable (every
#                                                product repo)
#                           off            rc 4  cl_on says 0
#   cl_findings <out>     <out>/findings.txt, at most 40 lines.
#   cl_verify_lines <wt> <base> <out>
#                         The fix-round verify block: `== ci-local ==`, the
#                         findings when red, then `CI_LOCAL_EXIT: 1` (red),
#                         `CI_LOCAL_EXIT: 0` (clean) or `CI_LOCAL_EXIT: <word>`.
#                         Runs <wt>/bin/ci-local.sh, the PR's own copy, with
#                         the rules pack (a fix round runs no other pack).
#
# Knobs: CI_LOCAL_GATE, CI_LOCAL_BUDGET_S (catalog/lanes.d/_lib.ci-local.json).

_CL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _cl_default <ENV> — the knob's default from this lib's registry fragment,
# under the harness root first and beside this lib second.
_cl_default() {
  local f root="${HARNESS:-${H:-}}" v=""
  for f in ${root:+"$root/catalog/lanes.d/_lib.ci-local.json"} \
           "$_CL_LIB/../../catalog/lanes.d/_lib.ci-local.json"; do
    [ -r "$f" ] || continue
    v=$(jq -r --arg e "$1" '.libs[]? | select(.id == "ci-local") | .knobs[]?
               | select(.env == $e) | .default // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && break
  done
  printf '%s' "$v"
}

# _cl_knob <ENV> — lane_knob in libs scope when the caller has it, else the
# harness root's lane-gate.sh in a subshell (the build driver does not keep
# lane_knob in its own shell), else the env. Empty when nothing answers.
_cl_knob() {
  local _LG_KIND=libs v="" root="${HARNESS:-${H:-}}" lg
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob ci-local "$1" 2>/dev/null)
  else
    for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$_CL_LIB/lane-gate.sh"; do
      [ -r "$lg" ] || continue
      v=$( . "$lg" 2>/dev/null && lane_knob ci-local "$1" 2>/dev/null )
      break
    done
  fi
  [ -n "$v" ] || v="${!1:-}"
  printf '%s' "$v"
}

cl_on() {
  local v
  v=$(_cl_knob CI_LOCAL_GATE)
  case "$v" in 0|1) ;; *) v=$(_cl_default CI_LOCAL_GATE) ;; esac
  # An unreadable fragment leaves the gate on: a run that cannot happen is
  # could-not-run, which never refuses anything.
  [ "$v" != 0 ]
}

cl_budget() {
  local v
  v=$(_cl_knob CI_LOCAL_BUDGET_S)
  case "$v" in ''|*[!0-9]*) v="" ;; *) { [ "$v" -lt 60 ] || [ "$v" -gt 3600 ]; } && v="" ;; esac
  [ -n "$v" ] || v=$(_cl_default CI_LOCAL_BUDGET_S)
  printf '%s' "$v"
}

cl_run() {
  local bin="${1:-}" tree="${2:-}" base="${3:-}" out="${4:-}" budget rc
  shift 4 2>/dev/null || { echo could-not-run; return 2; }
  # An off or skipped run clears <out> too: a resolver's next brief reads
  # <out>/findings.txt, and a stale one from an earlier round must not reach it.
  if ! cl_on; then rm -rf -- "${out:?}"; echo off; return 4; fi
  if [ ! -x "$bin" ]; then rm -rf -- "${out:?}"; echo skipped; return 3; fi
  budget=$(cl_budget)
  case "$budget" in ''|*[!0-9]*) echo could-not-run; return 2 ;; esac
  # A caller with its own deadline (the lead review) lowers the budget.
  case "${CL_BUDGET_CAP:-}" in ''|*[!0-9]*) ;; *) [ "$CL_BUDGET_CAP" -lt "$budget" ] && budget="$CL_BUDGET_CAP" ;; esac
  rm -rf -- "${out:?}"; mkdir -p "$out" 2>/dev/null || { echo could-not-run; return 2; }
  timeout $((budget + 120)) "$bin" --tree "$tree" --base "$base" --out "$out" --budget "$budget" "$@" \
    > "$out.stdout" 2> "$out.stderr"; rc=$?
  if [ "$rc" = 0 ]; then echo clean; return 0; fi
  if [ "$rc" = 1 ] && [ -s "$out/findings.txt" ]; then echo red; return 1; fi
  echo could-not-run; return 2
}

cl_findings() {
  head -40 "${1:-}/findings.txt" 2>/dev/null
}

cl_verify_lines() {
  local wt="${1:-}" base="${2:-}" out="${3:-}" w
  echo "== ci-local =="
  w=$(cl_run "$wt/bin/ci-local.sh" "$wt" "$base" "$out")
  case "$w" in
    red)   cl_findings "$out"; echo "CI_LOCAL_EXIT: 1" ;;
    clean) echo "CI_LOCAL_EXIT: 0" ;;
    could-not-run) tail -n 3 "$out.stdout" 2>/dev/null; echo "CI_LOCAL_EXIT: could-not-run" ;;
    *)     echo "CI_LOCAL_EXIT: ${w:-could-not-run}" ;;
  esac
}
