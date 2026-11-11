#!/bin/bash
# bin/lib/fresh-main-guards.sh — before the push, run every guard suite that
# changed on main after the build's base commit, on this branch merged with
# main (BH-9471, slice C1 of #9414; #9285 Fix 3). Sourced, never executed.
#
# WHY. project-6 PR #3608 was built on a base from before TK-3485 added a
# clock-relative guard to main. The build's verify never ran that guard; CI ran
# it on the merge with main and went red. Here the pre-PR gate fetches main and
# runs each guard main added or changed since the fork, on the same merge CI
# tests, so a red guard costs a fix turn, not a CI round.
#
# CONTRACT
#   fmg_run <wt> <base> <out>
#     Prints one word and returns its rc:
#       clean          rc 0  no guard changed on main, or each changed guard green
#       red            rc 1  at least one changed guard red
#       could-not-run  rc 2  bad base name, no budget left, fetch failed, no
#                            merge-base, guard list unreadable or over its cap,
#                            merge conflict, no temp worktree, or a guard run
#                            that could not run (locale, Postgres, runner,
#                            timeout). It returns on the first such guard.
#       skipped        rc 3  <wt>/bin/test-impact-gate.sh is executable: its
#                            --fresh-main run (BH-6459) already covers this
#       off            rc 4  knob FRESH_MAIN_GUARDS is 0; nothing fetched
#     Steps: fetch origin's <base> (an `origin/` prefix is stripped; the name
#     must match ^[A-Za-z0-9._/-]{1,200}$ and not start with `-`) into the
#     private ref refs/harness/fmg/<pid>; list the guards main declares at that
#     ref (vg_list, bin/lib/verify-guards.sh); keep those in
#     `git diff --name-only $(git merge-base HEAD <ref>) <ref>`; build the tree
#     of `git merge-tree --write-tree HEAD <ref>` in a temp worktree; run each
#     kept guard there with vr_run_files (bin/lib/verify-run.sh), the budget
#     left, and VR_DEPS_FROM=<wt>.
#     Writes <out>/fmg.txt (reason lines, `state=<word>` last),
#     <out>/findings.txt (one `FRESH-MAIN-GUARD <file>: <first FAIL or Error
#     line, 200 chars>` per red guard) and <out>/run.log (the guard output).
#     Every return deletes the private ref and removes the temp worktree.
#   Budget: FMG_BUDGET_S (seconds, set by the caller) capped by cl_budget
#     (CI_LOCAL_BUDGET_S, bin/lib/ci-local-verify.sh) when that lib is loaded.
#     Neither: could-not-run. 0 or less: could-not-run, never clean.
#
# Knob: FRESH_MAIN_GUARDS (catalog/lanes.d/_lib.fresh-main-guards.json, row
# lib.fresh-main-guards[.<project>].fresh_main_guards). The default lives only
# in that fragment.

_FMG_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/verify-guards.sh
command -v vg_list >/dev/null 2>&1 || { [ -r "$_FMG_LIB/verify-guards.sh" ] && . "$_FMG_LIB/verify-guards.sh"; }
# shellcheck source=bin/lib/verify-run.sh
command -v vr_run_files >/dev/null 2>&1 || { [ -r "$_FMG_LIB/verify-run.sh" ] && . "$_FMG_LIB/verify-run.sh"; }

# _fmg_default <ENV> — the fragment default, for a caller with no registry.
_fmg_default() {
  local f root="${HARNESS:-${H:-}}"
  for f in ${root:+"$root/catalog/lanes.d/_lib.fresh-main-guards.json"} "$_FMG_LIB/../../catalog/lanes.d/_lib.fresh-main-guards.json"; do
    [ -r "$f" ] || continue
    jq -r --arg e "$1" '[.libs[]?.knobs[]? | select(.env == $e) | .default][0] // empty | tostring' "$f" 2>/dev/null
    return 0
  done
}

# _fmg_knob <ENV> — lane_knob in libs scope (with $PROJECT), else the harness
# lane-gate.sh in a subshell, else the env, else the fragment default.
_fmg_knob() {
  local _LG_KIND=libs v="" root="${HARNESS:-${H:-}}" lg
  if command -v lane_knob >/dev/null 2>&1; then
    v=$(lane_knob fresh-main-guards "$1" "${PROJECT:-}" 2>/dev/null)
  else
    for lg in ${root:+"$root/bin/lib/lane-gate.sh"} "$_FMG_LIB/lane-gate.sh"; do
      [ -r "$lg" ] || continue
      v=$( . "$lg" 2>/dev/null && _LG_KIND=libs lane_knob fresh-main-guards "$1" "${PROJECT:-}" 2>/dev/null )
      break
    done
  fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v=$(_fmg_default "$1")
  printf '%s' "$v"
}

# _fmg_on — rc 1 only when FRESH_MAIN_GUARDS resolves to 0. Anything else is on:
# every failure is could-not-run, which refuses nothing.
_fmg_on() { [ "$(_fmg_knob FRESH_MAIN_GUARDS)" != 0 ]; }

# _fmg_budget — the seconds this run may use: FMG_BUDGET_S, capped by
# cl_budget. Empty when neither answers with a whole number.
_fmg_budget() {
  local v="${FMG_BUDGET_S:-}" cap=""
  [[ "$v" =~ ^-?[0-9]{1,9}$ ]] || v=""
  command -v cl_budget >/dev/null 2>&1 && cap=$(cl_budget)
  [[ "$cap" =~ ^[0-9]{1,9}$ ]] || cap=""
  [ -z "$v" ] && v="$cap"
  [ -n "$cap" ] && [ -n "$v" ] && [ "$v" -gt "$cap" ] && v="$cap"
  printf '%s' "$v"
}

# _fmg_why <out> <line> — one reason line in fmg.txt.
_fmg_why() { printf '%s\n' "$2" >> "$1/fmg.txt"; }

# _fmg_body <wt> <base> <out> — the run. Sets _FMG_REF and _FMG_TMP for the
# cleanup in fmg_run, and _FMG_WORD. rc as fmg_run.
_fmg_body() {
  local wt="$1" base="$2" out="$3" b budget t0 rem mb changed guards err g list=() n0 vrc line red=0 tree commit
  local -A onmain=()
  if ! _fmg_on; then _FMG_WORD=off; _fmg_why "$out" "off: FRESH_MAIN_GUARDS=0"; return 4; fi
  if [ -x "$wt/bin/test-impact-gate.sh" ]; then
    _FMG_WORD=skipped; _fmg_why "$out" "skipped: the repo ships bin/test-impact-gate.sh (its --fresh-main run covers this)"; return 3
  fi
  _FMG_WORD=could-not-run
  command -v vg_list >/dev/null 2>&1 && command -v vr_run_files >/dev/null 2>&1 \
    || { _fmg_why "$out" "could-not-run: verify-guards.sh or verify-run.sh is not loaded"; return 2; }
  b="${base#origin/}"
  if ! [[ "$b" =~ ^[A-Za-z0-9._/-]{1,200}$ ]] || [ "${b#-}" != "$b" ]; then
    _fmg_why "$out" "could-not-run: bad base name"; return 2
  fi
  budget=$(_fmg_budget)
  [ -n "$budget" ] || { _fmg_why "$out" "could-not-run: no budget (FMG_BUDGET_S and cl_budget are unset)"; return 2; }
  [ "$budget" -gt 0 ] || { _fmg_why "$out" "could-not-run: budget spent (${budget}s left)"; return 2; }
  t0=$SECONDS
  _FMG_REF="refs/harness/fmg/${BASHPID:-$$}"
  if ! timeout "$budget" git -C "$wt" fetch -q --no-tags --no-write-fetch-head origin "+refs/heads/$b:$_FMG_REF" >> "$out/run.log" 2>&1; then
    _fmg_why "$out" "could-not-run: fetch of origin/$b failed"; return 2
  fi
  mb=$(git -C "$wt" merge-base HEAD "$_FMG_REF" 2>/dev/null) || { _fmg_why "$out" "could-not-run: no merge-base with origin/$b"; return 2; }
  changed=$(git -C "$wt" diff --name-only "$mb" "$_FMG_REF" 2>/dev/null) || { _fmg_why "$out" "could-not-run: no diff ${mb:0:12}..origin/$b"; return 2; }
  err=$(mktemp) || { _fmg_why "$out" "could-not-run: no temp file"; return 2; }
  guards=$(vg_list "$wt" "$_FMG_REF" 2> "$err"); vrc=$?
  if [ "$vrc" != 0 ]; then
    _fmg_why "$out" "could-not-run: guard list at origin/$b: $(head -1 "$err") (rc $vrc)"; rm -f "$err"; return 2
  fi
  rm -f "$err"
  while IFS= read -r g; do [ -n "$g" ] && onmain["$g"]=1; done <<< "$changed"
  while IFS= read -r g; do
    [ -n "$g" ] && [ -n "${onmain[$g]:-}" ] && list+=("$g")
  done <<< "$guards"
  if [ "${#list[@]}" = 0 ]; then
    _fmg_why "$out" "0 changed on main (base ${mb:0:12}, origin/$b $(git -C "$wt" rev-parse --short=12 "$_FMG_REF"))"
    _FMG_WORD=clean; return 0
  fi
  _fmg_why "$out" "${#list[@]} changed on main (base ${mb:0:12}): ${list[*]}"
  tree=$(git -C "$wt" merge-tree --write-tree HEAD "$_FMG_REF" 2>/dev/null); vrc=$?
  if [ "$vrc" = 1 ]; then _fmg_why "$out" "could-not-run: merge conflict with origin/$b"; return 2; fi
  tree=$(head -1 <<< "$tree")
  [ "$vrc" = 0 ] && [ -n "$tree" ] || { _fmg_why "$out" "could-not-run: git merge-tree failed (rc $vrc)"; return 2; }
  commit=$(git -C "$wt" -c user.name=harness -c user.email=harness@localhost \
             commit-tree "$tree" -p HEAD -p "$_FMG_REF" -m "fresh-main guards (BH-9471)" 2>/dev/null) \
    || { _fmg_why "$out" "could-not-run: git commit-tree failed"; return 2; }
  _FMG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fmg.XXXXXX") || { _fmg_why "$out" "could-not-run: no temp dir"; return 2; }
  git -C "$wt" worktree add -q --detach "$_FMG_TMP/wt" "$commit" >> "$out/run.log" 2>&1 \
    || { _fmg_why "$out" "could-not-run: git worktree add failed"; return 2; }
  for g in "${list[@]}"; do
    rem=$(( budget - (SECONDS - t0) ))
    [ "$rem" -gt 0 ] || { _fmg_why "$out" "could-not-run: budget spent before $g"; return 2; }
    printf '== fresh-main guard %s ==\n' "$g" >> "$out/run.log"
    n0=$(wc -l < "$out/run.log")
    VR_DEPS_FROM="$wt" vr_run_files "$_FMG_TMP/wt" "$out/run.log" "$rem" "$g" > /dev/null; vrc=$?
    case "$vrc" in
      0) _fmg_why "$out" "guard $g: green" ;;
      1) _fmg_why "$out" "guard $g: red"; red=1
         line=$(tail -n +"$((n0 + 1))" "$out/run.log" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' \
                  | grep -m1 -E '(FAIL|Error)' | sed 's/^[[:space:]]*//' | cut -c1-200)
         printf 'FRESH-MAIN-GUARD %s: %s\n' "$g" "${line:-exited non-zero (see fmg/run.log)}" >> "$out/findings.txt" ;;
      *) _fmg_why "$out" "could-not-run: guard $g: ${VR_WHY:-no reason}"; return 2 ;;
    esac
  done
  if [ "$red" = 1 ]; then _FMG_WORD=red; return 1; fi
  _FMG_WORD=clean; return 0
}

fmg_run() {
  local wt="${1:-}" base="${2:-}" out="${3:-}" rc
  _FMG_REF=""; _FMG_TMP=""; _FMG_WORD=could-not-run
  if [ -z "$out" ] || ! mkdir -p "$out" 2>/dev/null; then echo could-not-run; return 2; fi
  : > "$out/fmg.txt"; : > "$out/findings.txt"; : > "$out/run.log"
  if [ -z "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    _fmg_why "$out" "could-not-run: $wt is not a git checkout"; rc=2
  else
    _fmg_body "$wt" "$base" "$out"; rc=$?
  fi
  if [ -n "$_FMG_TMP" ]; then
    [ -d "$_FMG_TMP/wt" ] && git -C "$wt" worktree remove --force "$_FMG_TMP/wt" >/dev/null 2>&1
    case "$_FMG_TMP" in */fmg.??????) rm -rf -- "$_FMG_TMP" ;; esac
    git -C "$wt" worktree prune >/dev/null 2>&1
  fi
  [ -n "$_FMG_REF" ] && git -C "$wt" update-ref -d "$_FMG_REF" >/dev/null 2>&1
  echo "state=$_FMG_WORD" >> "$out/fmg.txt"
  echo "$_FMG_WORD"
  return "$rc"
}
