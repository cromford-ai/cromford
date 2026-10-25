#!/bin/bash
# tests/harness-ci-merge.bh-7452-test.sh — two sibling PRs that each add a CI
# step merge with no human step, and a hand append to the CI workflow is
# refused (BH-7452 slice BH-7537).
#
# WHY. .github/workflows/harness-ci.yml is the committed render of the
# fragments in config/harness-ci/ (bin/render-ci-workflow.sh). Two PRs that each
# add a step at the same place in one job add two different fragment files, so
# the fragments never conflict, but both re-render the workflow and conflict on
# it. The merge conductor settles such a path by re-running its renderer over
# the merged tree, when config/regenerated-paths.conf (and its compiled twin
# MC_REGENERATED_PATHS_DEFAULT) names it. catalog/list-files.tsv names it as a
# `rendered config/harness-ci/` list file, so bin/list-file-lint.sh refuses a PR
# that grows the workflow without touching a fragment.
#
# Driven through the production entry points (mc_regen_cmd_for_path,
# mc_resolve_by_regen, mc_resolve_conflicts, bin/list-file-lint.sh) against REAL
# git merges and the real bin/render-ci-workflow.sh over the real fragments.
#   M1  the conf and the compiled default map the render to its renderer; 7
#       near misses map to nothing under both
#   M2  a fragment that itself conflicts: the renderer exits 3, the render is
#       left a REAL conflict with its markers
#   M3  siblings in two jobs: the merge ends with no human step, --check rc 0
#   M4  siblings at the end of one job: the conflict is on the render alone,
#       the regen settles it, a before b, nothing unmerged
#   L1  a hand append to the render with no fragment: list-file-lint rc 1
#   L2  the same append plus a new fragment: rc 0
# Run from anywhere: tests/harness-ci-merge.bh-7452-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The library is sourced against a SCRATCH harness, never /root/harness.
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
cp "$DIR/config/generated-paths.conf" "$DIR/config/regenerated-paths.conf" "$T/h/config/"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
WF=.github/workflows/harness-ci.yml
WANT="bin/render-ci-workflow.sh --write"

# --- M1. the registry ---------------------------------------------------------
[ "$(mc_regen_cmd_for_path "$WF" 2>/dev/null)" = "$WANT" ] && ok \
  || bad "M1 the conf must map $WF to '$WANT' (got '$(mc_regen_cmd_for_path "$WF" 2>/dev/null)')"
[ "$(MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path "$WF" 2>/dev/null)" = "$WANT" ] && ok \
  || bad "M1 the compiled default (a pool image with no config/) must map $WF too"
for p in .github/workflows/harness-nightly.yml .github/workflows/prequeue-gate.yml \
         config/harness-ci/120-lint/010-x.yml harness-ci.yml \
         .github/workflows/harness-ci.yml.orig x/.github/workflows/harness-ci.yml ""; do
  mc_regen_cmd_for_path "$p" >/dev/null 2>&1 && bad "M1 the conf must not map '$p'" || ok
  MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path "$p" >/dev/null 2>&1 \
    && bad "M1 the compiled default must not map '$p'" || ok
done

# --- the fixture: a repo with the real renderer and the real fragments --------
# mkrepo <dir> — base commit on main, render in step with its fragments.
mkrepo() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/.github/workflows" "$R/config"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@fixture.test; git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  ( cd "$DIR" && scratch_install_closure bin/render-ci-workflow.sh "$R" ) >/dev/null \
    || { bad "cannot install the closure of bin/render-ci-workflow.sh"; return 1; }
  cp -R "$DIR/config/harness-ci" "$R/config/"
  cp "$DIR/$WF" "$R/$WF"
  ( cd "$R" && bin/render-ci-workflow.sh --check ) >/dev/null 2>&1 \
    || { bad "the fixture's render is not in step with its fragments"; return 1; }
}
# step <repo> <frag> <name> — one step fragment, the steps indentation of a job.
step() { printf '      - name: %s\n        run: echo %s\n' "$3" "$3" > "$1/config/harness-ci/$2"; }
render() { ( cd "$1" && bin/render-ci-workflow.sh --write ) >/dev/null 2>&1; }
commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }
markers() { grep -Eq '^(<<<<<<<|=======|>>>>>>>)( |$)' "$1"; }
unmerged() { git -C "$1" diff --name-only --diff-filter=U | tr '\n' ' '; }

# --- M2. a fragment that itself conflicts -------------------------------------
R="$T/m2"
if mkrepo "$R"; then
  step "$R" 120-lint/995-shared.yml shared-base; render "$R"; commit "$R" base
  git -C "$R" checkout -q -b a
  step "$R" 120-lint/995-shared.yml shared-a; render "$R"; commit "$R" a
  git -C "$R" checkout -q main; git -C "$R" checkout -q -b b
  step "$R" 120-lint/995-shared.yml shared-b; render "$R"; commit "$R" b
  git -C "$R" merge -q --no-edit a >/dev/null 2>&1 && bad "M2 the fixture should conflict"
  : > "$MCLOG"
  mc_resolve_by_regen "$R" "$WF" "$(mc_regen_cmd_for_path "$WF")"; rc=$?
  [ "$rc" = 1 ] && ok || bad "M2 a marker fragment must leave a real conflict (rc 1), got rc $rc"
  case " $(unmerged "$R")" in *" $WF "*) ok ;; *) bad "M2 the render must stay unmerged, got: $(unmerged "$R")" ;; esac
  grep -q '^<<<<<<< ' "$R/$WF" && ok || bad "M2 the render must keep its conflict markers"
  grep -q "regenerated path $WF left as a REAL conflict" "$MCLOG" && ok || bad "M2 the log must name a REAL conflict: $(cat "$MCLOG")"
  grep -q 'exited 3' "$MCLOG" && ok || bad "M2 the log must name the renderer's rc 3: $(cat "$MCLOG")"
  grep -q "regenerated path $WF resolved by re-running" "$MCLOG" && bad "M2 the log must not claim the render was resolved" || ok
fi

# --- M3. siblings in two jobs -------------------------------------------------
R="$T/m3"
if mkrepo "$R"; then
  commit "$R" base
  git -C "$R" checkout -q -b a
  step "$R" 120-lint/995-sibling-a.yml sibling-a; render "$R"; commit "$R" a
  git -C "$R" checkout -q main; git -C "$R" checkout -q -b b
  step "$R" 160-tests-shard/995-sibling-b.yml sibling-b; render "$R"; commit "$R" b
  if ! git -C "$R" merge -q --no-edit a >/dev/null 2>&1; then
    # Git stopped: every unmerged path must be the render, and the conductor
    # settles it.
    [ "$(unmerged "$R")" = "$WF " ] && ok || bad "M3 the only conflict must be the render, got: $(unmerged "$R")"
    out=$(mc_resolve_conflicts "$R" b); rc=$?
    [ "$rc" = 0 ] && ok || bad "M3 mc_resolve_conflicts must settle the render, rc $rc: $(cat "$MCLOG")"
    [ -z "$out" ] && ok || bad "M3 mc_resolve_conflicts must name no real conflict, got: $out"
    git -C "$R" commit -q --no-edit >/dev/null 2>&1 && ok || bad "M3 the merge must commit"
  fi
  ( cd "$R" && bin/render-ci-workflow.sh --check ) >/dev/null 2>&1 && ok || bad "M3 the merged render must pass --check"
  grep -q 'name: sibling-a' "$R/$WF" && grep -q 'name: sibling-b' "$R/$WF" && ok || bad "M3 both steps must be in the render"
  markers "$R/$WF" && bad "M3 the render must hold no conflict marker" || ok
fi

# --- M4. siblings at the end of one job ---------------------------------------
R="$T/m4"
if mkrepo "$R"; then
  commit "$R" base
  git -C "$R" checkout -q -b a
  step "$R" 120-lint/995-sibling-a.yml sibling-a; render "$R"; commit "$R" a
  git -C "$R" checkout -q main; git -C "$R" checkout -q -b b
  step "$R" 120-lint/996-sibling-b.yml sibling-b; render "$R"; commit "$R" b
  git -C "$R" merge -q --no-edit a >/dev/null 2>&1 && bad "M4 the fixture should conflict"
  [ "$(unmerged "$R")" = "$WF " ] && ok || bad "M4 the conflict must be on the render alone, got: $(unmerged "$R")"
  : > "$MCLOG"
  mc_resolve_by_regen "$R" "$WF" "$(mc_regen_cmd_for_path "$WF")"; rc=$?
  [ "$rc" = 0 ] && ok || bad "M4 the regen must settle the render (rc 0), got rc $rc: $(cat "$MCLOG")"
  markers "$R/$WF" && bad "M4 the render must hold no conflict marker" || ok
  ( cd "$R" && bin/render-ci-workflow.sh --check ) >/dev/null 2>&1 && ok || bad "M4 the merged render must pass --check"
  la=$(grep -n 'name: sibling-a' "$R/$WF" | cut -d: -f1); lb=$(grep -n 'name: sibling-b' "$R/$WF" | cut -d: -f1)
  [ -n "$la" ] && [ -n "$lb" ] && [ "$la" -lt "$lb" ] && ok || bad "M4 both steps must be in the render, a before b (a=$la b=$lb)"
  [ -z "$(unmerged "$R")" ] && ok || bad "M4 nothing must stay unmerged, got: $(unmerged "$R")"
  grep -q "regenerated path $WF resolved by re-running $WANT" "$MCLOG" && ok || bad "M4 the log must name the regen: $(cat "$MCLOG")"
fi

# --- L1/L2. the list-file lint ------------------------------------------------
# lrepo <dir> — the fixture plus the lint and this tree's catalog, committed.
lrepo() {
  local R="$1"
  mkrepo "$R" || return 1
  ( cd "$DIR" && scratch_install_closure bin/list-file-lint.sh "$R" ) >/dev/null \
    || { bad "cannot install the closure of bin/list-file-lint.sh"; return 1; }
  mkdir -p "$R/catalog"; cp "$DIR/catalog/list-files.tsv" "$R/catalog/"
  commit "$R" base
}
R="$T/l1"
if lrepo "$R"; then
  B=$(git -C "$R" rev-parse HEAD)
  echo '# hand edit' >> "$R/$WF"; commit "$R" hand
  out=$( cd "$R" && bin/list-file-lint.sh --base "$B" --catalog catalog/list-files.tsv 2>&1 ); rc=$?
  [ "$rc" = 1 ] && ok || bad "L1 a hand append to the render must be refused (rc 1), got rc $rc: $out"
  case "$out" in *config/harness-ci/*) ok ;; *) bad "L1 the refusal must name config/harness-ci/: $out" ;; esac
fi
R="$T/l2"
if lrepo "$R"; then
  B=$(git -C "$R" rev-parse HEAD)
  echo '# hand edit' >> "$R/$WF"; step "$R" 120-lint/995-l2.yml l2; commit "$R" frag
  out=$( cd "$R" && bin/list-file-lint.sh --base "$B" --catalog catalog/list-files.tsv 2>&1 ); rc=$?
  [ "$rc" = 0 ] && ok || bad "L2 an append with a new fragment must pass (rc 0), got rc $rc: $out"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
