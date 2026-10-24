#!/bin/bash
# tests/regenerated-schema-conflicts.bh-6000-test.sh — a merge that conflicts
# only in a generated file is regenerated and goes on; it is never parked
# (BH-6000 part 1).
#
# THE INCIDENT (2026-10-11 03:50Z, merge-conductor.log on the hub). Every PR
# that adds a worker/jobs/schema.d/ fragment conflicts on worker/jobs/schema.sql
# as soon as any other schema PR merges. The conductor's conflict resolver had
# no rule for schema.sql (config/regenerated-paths.conf named only
# docs/notes/INDEX.md), so it called the conflict real and parked the PR
# conflict-unresolvable: #5420 and its 3 stacked children, #5892, #5956 and
# #5907, some for 1000+ minutes.
#
# THE FIX is data: config/regenerated-paths.conf (and its compiled twin
# MC_REGENERATED_PATHS_DEFAULT) names the committed generated files with the
# command that renders each one. mc_resolve_conflicts then re-renders such a
# path over the merged tree, after every other path is settled.
#
# Driven through mc_resolve_conflicts, the production entry point (mc_rebase,
# mc_restack and rebase-job.sh all call it), against REAL git merges and the
# real bin/schema-build.sh.
#   T1  the registry: schema.sql, rules/CLAUDE.md and docs/PR-OWNERSHIP.md map
#       to their generators; the conf and the compiled default agree
#   E1  THE TICKET'S CASE: a main merge that conflicts only in schema.sql is
#       regenerated from the merged fragments, staged and committed
#   E2  a merge that conflicts in schema.sql AND a hand-written file still
#       fails (the caller parks it), and the hand-written file is named
#   R1  a stacked child's restack (`rebase --onto`, mc_restack) that stops on
#       schema.sql is regenerated and continues, over two replayed commits
#       (mc_rebase_regen_continue)
#   R2  a rebase that stops on a hand-written file is left stopped (rc 1)
# Run from anywhere: tests/regenerated-schema-conflicts.bh-6000-test.sh
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

# --- T1. the registry ---------------------------------------------------------
for row in "rules/CLAUDE.md|bin/render-rules.sh --write" \
           "docs/PR-OWNERSHIP.md|bin/render-doc-sections.sh --write"; do
  p="${row%%|*}"; want="${row#*|}"
  [ "$(mc_regen_cmd_for_path "$p" 2>/dev/null)" = "$want" ] && ok || bad "T1 $p must map to '$want' (got '$(mc_regen_cmd_for_path "$p" 2>/dev/null)')"
  [ "$(MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path "$p" 2>/dev/null)" = "$want" ] && ok \
    || bad "T1 the compiled default (a pool image with no config/) must map $p too"
done
# Every path the registry names is a committed file in this repo, and its
# generator is in the tree.
while IFS=$'\t' read -r p cmd; do
  git -C "$DIR" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && ok || bad "T1 $p is in the registry but not tracked"
  [ -x "$DIR/${cmd%% *}" ] && ok || bad "T1 $p's generator ${cmd%% *} is not an executable in the tree"
done < <(mc_regen_paths)

# TEST-CHANGE (BH-6005.4): worker/jobs/schema.sql left git, so it left the
# registry: no row in the conf and none in the compiled default.
mc_regen_cmd_for_path worker/jobs/schema.sql >/dev/null 2>&1 && bad "T1 worker/jobs/schema.sql must have no row any more" || ok
MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path worker/jobs/schema.sql >/dev/null 2>&1 \
  && bad "T1 the compiled default must have no worker/jobs/schema.sql row any more" || ok
# TEST-CHANGE (BH-8254): docs/notes/INDEX.md left git the same way, so its
# row left the loop above and its absence is pinned here.
mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 && bad "T1 docs/notes/INDEX.md must have no row any more" || ok
MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 \
  && bad "T1 the compiled default must have no docs/notes/INDEX.md row any more" || ok
# The fixtures below still COMMIT a render (the shape this mechanism exists
# for), so E1-R2 drive the regenerate through a conf that names it.
printf 'worker/jobs/schema.sql\tbin/schema-build.sh --write\n' > "$T/regen.conf"
export MC_REGENERATED_PATHS_CONF="$T/regen.conf"

# --- the fixture: a repo with the real schema builder ------------------------
frag() { # frag <repo> <name> <table>
  printf 'CREATE TABLE IF NOT EXISTS %s (\n  id TEXT PRIMARY KEY\n);\n' "$3" > "$1/worker/jobs/schema.d/$2"
}
build() { ( cd "$1" && bin/schema-build.sh --write >/dev/null 2>&1 ); }
# mkrepo <dir> <branch> [handfile] — main and <branch> each add a fragment and
# re-render schema.sql. With [handfile], both also change the same line of
# worker/jobs/src/<handfile>, a hand-written file. <branch> is checked out.
mkrepo() {
  local R="$1" br="$2" hand="${3:-}"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin/lib" "$R/worker/jobs/schema.d" "$R/worker/jobs/src"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@fixture.test; git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  ( cd "$DIR" && scratch_install_closure bin/schema-build.sh "$R" ) >/dev/null || { bad "cannot install the closure of bin/schema-build.sh"; return 1; }
  frag "$R" 0000-base.sql base_t
  printf 'export const v = 0;\n' > "$R/worker/jobs/src/${hand:-app.js}"
  build "$R"
  git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" checkout -q -b "$br"
  frag "$R" 0016-branch.sql branch_t; build "$R"
  [ -n "$hand" ] && printf 'export const v = 1;\n' > "$R/worker/jobs/src/$hand"
  git -C "$R" add -A; git -C "$R" commit -qm branch
  git -C "$R" checkout -q main
  frag "$R" 0017-main.sql main_t; build "$R"
  [ -n "$hand" ] && printf 'export const v = 2;\n' > "$R/worker/jobs/src/$hand"
  git -C "$R" add -A; git -C "$R" commit -qm main
  git -C "$R" checkout -q "$br"
}
fresh() { cat "$1"/worker/jobs/schema.d/*.sql; }

# --- E1. THE TICKET'S CASE: conflicts only in schema.sql ----------------------
R="$T/e1"; BR=ticket/bh-9001
mkrepo "$R" "$BR"
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "E1 the fixture should conflict"
CONF=$(git -C "$R" diff --name-only --diff-filter=U | tr '\n' ' ')
[ "$CONF" = "worker/jobs/schema.sql " ] && ok || bad "E1 expected a conflict on schema.sql alone, got: $CONF"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 0 ] && ok || bad "E1 a schema.sql-only conflict must be regenerated, not parked (rc=$RC, left: $OUT) $(cat "$MCLOG")"
[ -z "$OUT" ] && ok || bad "E1 a resolved conflict prints nothing on stdout: $OUT"
[ -z "$(git -C "$R" ls-files -u)" ] && ok || bad "E1 paths left unmerged: $(git -C "$R" ls-files -u)"
[ "$(cat "$R/worker/jobs/schema.sql")" = "$(fresh "$R")" ] && ok || bad "E1 schema.sql is not the render of the merged fragments"
[ "$(git -C "$R" show :worker/jobs/schema.sql)" = "$(fresh "$R")" ] && ok || bad "E1 the STAGED schema.sql is not the render"
for t in base_t branch_t main_t; do
  [ "$(grep -c "CREATE TABLE IF NOT EXISTS $t " "$R/worker/jobs/schema.sql")" = 1 ] && ok || bad "E1 $t must be in schema.sql exactly once"
done
grep -Eq '^(<<<<<<<|=======|>>>>>>>)' "$R/worker/jobs/schema.sql" && bad "E1 conflict markers in schema.sql" || ok
grep -q 'regenerated path worker/jobs/schema.sql resolved by re-running bin/schema-build.sh --write' "$MCLOG" && ok \
  || bad "E1 no conductor log line for the regenerate: $(cat "$MCLOG")"
git -C "$R" commit -q --no-edit >/dev/null 2>&1 && ok || bad "E1 the resolved merge must commit"
[ -z "$(git -C "$R" status --porcelain)" ] && ok || bad "E1 the regenerate left the tree dirty: $(git -C "$R" status --porcelain)"
( cd "$R" && bin/schema-build.sh --check >/dev/null 2>&1 ) && ok || bad "E1 the merged tree must pass schema-build --check"

# --- E2. schema.sql AND a hand-written file: still parked ---------------------
R="$T/e2"; BR=ticket/bh-9002
mkrepo "$R" "$BR" handwritten.js
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "E2 the fixture should conflict"
CONF=$(git -C "$R" diff --name-only --diff-filter=U | sort | tr '\n' ' ')
[ "$CONF" = "worker/jobs/schema.sql worker/jobs/src/handwritten.js " ] && ok || bad "E2 expected conflicts on schema.sql and handwritten.js, got: $CONF"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "E2 a hand-written conflict must still fail the rung (rc=$RC)"
grep -qx 'worker/jobs/src/handwritten.js' <<<"$OUT" && ok || bad "E2 the hand-written file must be in the conflict list handed on: $OUT"

# --- R. a rebase (mc_restack's `rebase --onto`) ------------------------------
# rbrepo <dir> [handfile] — the branch carries TWO commits, each adding a
# fragment and re-rendering; main adds one. With [handfile] both change it.
rbrepo() {
  local R="$1" hand="${2:-}"
  mkrepo "$R" ticket/bh-9003 "$hand"
  frag "$R" 0018-branch2.sql branch2_t; build "$R"
  git -C "$R" add -A; git -C "$R" commit -qm branch2
}
R="$T/r1"; rbrepo "$R"
git -C "$R" -c commit.gpgsign=false rebase -q main >/dev/null 2>&1 && bad "R1 the fixture rebase should stop on a conflict"
[ "$(git -C "$R" diff --name-only --diff-filter=U)" = worker/jobs/schema.sql ] && ok || bad "R1 the rebase should stop on schema.sql alone"
: > "$MCLOG"
( MC_GIT_NAME=t MC_GIT_EMAIL=t@fixture.test mc_rebase_regen_continue "$R" "r1 restack" ); RC=$?
[ "$RC" = 0 ] && ok || bad "R1 the rebase must finish after the regenerate (rc=$RC): $(cat "$MCLOG")"
[ ! -d "$R/.git/rebase-merge" ] && [ ! -d "$R/.git/rebase-apply" ] && ok || bad "R1 the rebase is still in progress"
for t in base_t branch_t branch2_t main_t; do
  [ "$(grep -c "CREATE TABLE IF NOT EXISTS $t " "$R/worker/jobs/schema.sql")" = 1 ] && ok || bad "R1 $t must be in schema.sql exactly once"
done
( cd "$R" && bin/schema-build.sh --check >/dev/null 2>&1 ) && ok || bad "R1 the rebased tree must pass schema-build --check"
[ "$(git -C "$R" rev-list --count main..HEAD)" = 2 ] && ok || bad "R1 both branch commits must be replayed onto main"
git -C "$R" merge-base --is-ancestor main HEAD && ok || bad "R1 the result must sit on main"
grep -q 'r1 restack: regenerated worker/jobs/schema.sql on a replayed commit' "$MCLOG" && ok || bad "R1 no log line for the regenerate: $(cat "$MCLOG")"

R="$T/r2"; rbrepo "$R" handwritten.js
git -C "$R" -c commit.gpgsign=false rebase -q main >/dev/null 2>&1 && bad "R2 the fixture rebase should stop on a conflict"
( MC_GIT_NAME=t MC_GIT_EMAIL=t@fixture.test mc_rebase_regen_continue "$R" "r2 restack" ); RC=$?
[ "$RC" = 1 ] && ok || bad "R2 a hand-written conflict must leave the rebase stopped (rc=$RC)"
grep -qx 'worker/jobs/src/handwritten.js' <<<"$(git -C "$R" diff --name-only --diff-filter=U)" && ok || bad "R2 the hand-written conflict must still be in the index for the caller"
git -C "$R" rebase --abort >/dev/null 2>&1

echo "regenerated-schema-conflicts.bh-6000: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
