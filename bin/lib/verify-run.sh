#!/bin/bash
# bin/lib/verify-run.sh — run named test files once, the way CI would run them
# (BH-9471, slice C1 of #9414). Sourced, never executed. Functions only.
#
# WHY. The pre-push verify ran only the files the build's own diff selected.
# project-6 PR #3608 never ran the guard TK-3485 added to main after the build
# started, and CI went red on it. bin/lib/fresh-main-guards.sh runs those guards
# through this one runner, so each run has CI's locale, the project's
# throwaway Postgres when its knob is on, and a time budget.
#
# CONTRACT
#   vr_run_files <dir> <out> <budget_s> <file>...
#       Runs the files once in <dir>. All output is appended to <out> (a file).
#       Prints one word and returns its rc:
#         green          rc 0  the run exited 0 inside the budget
#         red            rc 1  the run exited non-zero (not 124..127)
#         could-not-run  rc 2  no file, a bad file or budget, no runner, the
#                              CI locale not installed, Postgres down, no
#                              node_modules, a timeout (past the budget is
#                              never green), or an exit of 124..127
#       VR_WHY holds the reason for could-not-run (empty otherwise). It is set
#       in the caller's shell: call it as `vr_run_files ... >/dev/null; rc=$?`
#       to read VR_WHY; a `$( )` call keeps the word and loses VR_WHY.
#   The runner, in this order:
#     1. <dir>/package.json declares "test:unit"  npm run test:unit -- <file>...
#     2. it declares "test"                       npm run test -- <file>...
#     3. every file ends in .sh                   bash <file>, one at a time
#     else could-not-run.
#   VR_DEPS_FROM=<checkout>: for an npm run, when <dir> has no node_modules,
#     link <checkout>/node_modules into <dir> for the run and remove the link
#     (only the link) after it. No node_modules anywhere is could-not-run.
#   CI locale: ce_suite_record (bin/lib/ci-env.sh) when that lib is loaded or
#     beside this one; rc 2 is could-not-run. No ci-env lib: the run uses the
#     process locale, as HARNESS_SUITE_RUN does.
#   Postgres: pgt_enabled (bin/lib/pg-test.sh) starts a throwaway cluster for
#     the run and stops it after. A start that fails is could-not-run.
#
# Every file goes to the runner as one argv item. No eval, no `bash -c`.

_VR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _vr_safe <path> — rc 0 for a repo-relative path that is safe as one argv item.
_vr_safe() {
  local p="${1:-}"
  case "$p" in ''|-*|/*|*$'\r'*|*$'\n'*) return 1 ;; esac
  case "/$p/" in */../*) return 1 ;; esac
  return 0
}

# _vr_cnr <why> — could-not-run with a reason.
_vr_cnr() { VR_WHY="$1"; echo could-not-run; return 2; }

vr_run_files() {
  local dir="${1:-}" out="${2:-}" budget="${3:-}" f script="" allsh=1 rc link="" pgline
  local envs=()
  VR_WHY=""
  shift 3 2>/dev/null || { _vr_cnr "usage: vr_run_files <dir> <out> <budget_s> <file>..."; return 2; }
  [ -n "$out" ] || { _vr_cnr "no output file"; return 2; }
  [ -d "$dir" ] || { _vr_cnr "no directory $dir"; return 2; }
  [[ "$budget" =~ ^[0-9]{1,6}$ ]] && [ "$budget" -gt 0 ] || { _vr_cnr "bad budget '$budget'"; return 2; }
  [ $# -gt 0 ] || { _vr_cnr "no file to run"; return 2; }
  for f in "$@"; do
    _vr_safe "$f" || { _vr_cnr "unsafe file name"; return 2; }
    [ -f "$dir/$f" ] || { _vr_cnr "no file $f"; return 2; }
    case "$f" in *.sh) ;; *) allsh=0 ;; esac
  done
  if grep -q '"test:unit"' "$dir/package.json" 2>/dev/null; then script=test:unit
  elif grep -q '"test"' "$dir/package.json" 2>/dev/null; then script=test
  elif [ "$allsh" = 0 ]; then _vr_cnr "no runner (no test or test:unit script, and not every file is .sh)"; return 2
  fi
  # CI LOCALE (BH-9285): the same record HARNESS_SUITE_RUN writes.
  command -v ce_suite_record >/dev/null 2>&1 || { [ -r "$_VR_LIB/ci-env.sh" ] && . "$_VR_LIB/ci-env.sh"; }
  if command -v ce_suite_record >/dev/null 2>&1; then
    if ! ce_suite_record "$dir" "$out"; then
      _vr_cnr "$(grep '^HARNESS_LOCALE: ' "$out" 2>/dev/null | tail -1)"; return 2
    fi
    envs=("${CE_ENV[@]}")
  fi
  if [ -n "$script" ] && [ ! -e "$dir/node_modules" ]; then
    if [ -n "${VR_DEPS_FROM:-}" ] && [ -d "$VR_DEPS_FROM/node_modules" ]; then
      ln -s "$(cd "$VR_DEPS_FROM/node_modules" && pwd)" "$dir/node_modules" 2>/dev/null \
        || { _vr_cnr "could not link node_modules"; return 2; }
      link="$dir/node_modules"
    else
      _vr_cnr "no node_modules in $dir${VR_DEPS_FROM:+ or $VR_DEPS_FROM}"; return 2
    fi
  fi
  command -v pgt_enabled >/dev/null 2>&1 || { [ -r "$_VR_LIB/pg-test.sh" ] && . "$_VR_LIB/pg-test.sh"; }
  (
    cd "$dir" || exit 125
    run=()
    [ "${#envs[@]}" -gt 0 ] && run=(env "${envs[@]}")
    pg=0
    if command -v pgt_enabled >/dev/null 2>&1 && pgt_enabled; then
      pgt_start "$out" || exit 126
      pg=1
      pgt_setup "$out"
      pgt_env && run=("${PGT_ENV[@]}")
    fi
    if [ -n "$script" ]; then
      ${run[@]+"${run[@]}"} timeout "$budget" npm run "$script" -- "$@"; r=$?
    else
      r=0; t0=$SECONDS
      for f in "$@"; do
        rem=$(( budget - (SECONDS - t0) ))
        [ "$rem" -gt 0 ] || { r=124; break; }
        ${run[@]+"${run[@]}"} timeout "$rem" bash "$f"; x=$?
        case "$x" in 0) ;; 12[4-7]) r=$x; break ;; *) [ "$r" = 0 ] && r=$x ;; esac
      done
    fi
    [ "$pg" = 1 ] && pgt_stop "$out"
    exit "$r"
  ) >> "$out" 2>&1
  rc=$?
  [ -n "$link" ] && [ -L "$link" ] && rm -f -- "$link"
  case "$rc" in
    0) echo green; return 0 ;;
    124) _vr_cnr "timed out past the ${budget}s budget"; return 2 ;;
    126)
      pgline=$(grep '^HARNESS_PG: could-not-start' "$out" 2>/dev/null | tail -1)
      _vr_cnr "${pgline:-exit 126 (could not execute)}"; return 2 ;;
    125|127) _vr_cnr "exit $rc (the runner could not start)"; return 2 ;;
    *) echo red; return 1 ;;
  esac
}
