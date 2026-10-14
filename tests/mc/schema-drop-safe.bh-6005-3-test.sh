#!/bin/bash
# tests/mc/schema-drop-safe.bh-6005-3-test.sh — the merge-conductor never takes
# a base-side deletion of a git-ignored worker/<w>/schema.sql when the branch's
# copy holds a statement that no fragment of the merged tree holds.
#
# WHAT THIS PINS (BH-6005.3). mc_resolve_deleted_ignored (BH-1175) takes the
# deletion of any ignored path with no look at its content. Once the untrack
# child makes worker/jobs/schema.sql ignored, a branch that appended a CREATE
# TABLE to schema.sql only (cut before the BH-4987 split) would lose that table
# in the merge, with no conflict and no log line. mc_schema_drop_safe refuses
# that deletion: the path stays a REAL conflict and one log line names the
# statement.
#
# WHY REAL GIT AND THE REAL BUILDER. Every case builds a real repo, renders
# schema.sql with the real bin/schema-build.sh --write (the format production
# writes), merges main INTO the ticket branch with HEAD on the branch (stage
# 2 = branch, stage 3 = main) as mc_rebase does, and drives the production
# entry point mc_resolve_conflicts.
# Run from anywhere: tests/mc/schema-drop-safe.bh-6005-3-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# A fixed clock: no fixture reads the wall clock.
export GIT_AUTHOR_DATE="@1790000000 +0000" GIT_COMMITTER_DATE="@1790000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

# The library runs against a SCRATCH harness, never /root/harness.
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/flags" "$T/h/builds" "$T/h/config"
unset MC_UNION_FILES
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init

BR=ticket/bh-9001
SCHEMA=worker/jobs/schema.sql
FRAGS=worker/jobs/schema.d

# --- fixture helpers ----------------------------------------------------------
# mkrepo <tag>: a repo at $T/<tag> on main with the real builder and one
# rendered fragment committed, and the branch forked from it. W is the worktree.
mkrepo() {
  W="$T/$1"
  git init -q -b main "$W"
  git -C "$W" config user.email t@t
  git -C "$W" config user.name t
  git -C "$W" config commit.gpgsign false
  scratch_install_closure bin/schema-build.sh "$W" >/dev/null \
    || { echo "FAIL: cannot install bin/schema-build.sh into $1"; exit 1; }
  chmod 755 "$W/bin/schema-build.sh"
  put "$FRAGS/0100-base_fixture.sql" 'CREATE TABLE IF NOT EXISTS base_fixture (id INTEGER PRIMARY KEY);
'
  render
  commit base
  git -C "$W" branch -q "$BR"
}
put()    { mkdir -p "$(dirname "$W/$1")"; printf '%s' "$2" > "$W/$1"; }
commit() { git -C "$W" add -A; git -C "$W" commit -qm "$1"; }
render() { "$W/bin/schema-build.sh" --root "$W" --worker jobs --write 2>/dev/null \
             || { echo "FAIL: schema-build.sh --write refused in $W"; exit 1; }; }
# untrack <path>: main's side of the untrack child — the path leaves git and
# goes into .gitignore.
untrack() { git -C "$W" rm -q -- "$1"; printf '%s\n' "$1" >> "$W/.gitignore"; }
on_branch()  { git -C "$W" checkout -q "$BR"; }
merge_main() { git -C "$W" merge -q --no-edit main >/dev/null 2>&1; }
unmerged()   { [ -n "$(git -C "$W" ls-files -u -- "$1")" ]; }
in_index()   { [ -n "$(git -C "$W" ls-files -s -- "$1")" ]; }
resolve()    { : > "$MC_LOG"; OUT=$(mc_resolve_conflicts "$W" "$BR"); RC=$?; }
logn()       { grep -c -- "$1" "$MC_LOG"; }

# taken <case> <path>: rc 0, stdout empty, the path gone from index and worktree.
taken() {
  [ "$RC" = 0 ] && ok || bad "$1: rc $RC, want 0 (out: $OUT)"
  [ -z "$OUT" ] && ok || bad "$1: stdout not empty: $OUT"
  [ -z "$(git -C "$W" ls-files -u)" ] && ok || bad "$1: unmerged paths left: $(git -C "$W" ls-files -u)"
  in_index "$2" && bad "$1: $2 still in the index" || ok
  [ -e "$W/$2" ] && bad "$1: $2 still in the worktree" || ok
}
# refused <case> <path>: rc 1, stdout lists the path, the path unmerged and kept.
refused() {
  [ "$RC" = 1 ] && ok || bad "$1: rc $RC, want 1"
  grep -qx -- "$2" <<<"$OUT" && ok || bad "$1: stdout does not list $2: $OUT"
  unmerged "$2" && ok || bad "$1: $2 is not unmerged"
  [ -f "$W/$2" ] && ok || bad "$1: $2 is gone from the worktree"
}

# --- X1: both sides added a fragment, the branch re-rendered -> deletion taken.
mkrepo x1
put "$FRAGS/0200-main_fixture.sql" 'CREATE TABLE IF NOT EXISTS main_fixture (id INTEGER PRIMARY KEY);
'
untrack "$SCHEMA"; commit main-untrack
on_branch
put "$FRAGS/0201-branch_fixture.sql" 'CREATE TABLE IF NOT EXISTS branch_fixture (id INTEGER PRIMARY KEY);
'
render; commit branch-frag
merge_main
unmerged "$SCHEMA" && ok || bad "X1: fixture: $SCHEMA is not a conflict"
resolve
taken X1 "$SCHEMA"
[ "$(logn BH-6005)" = 0 ] && ok || bad "X1: a BH-6005 line was logged: $(cat "$MC_LOG")"
[ "$(logn BH-1175)" = 1 ] && ok || bad "X1: no BH-1175 line: $(cat "$MC_LOG")"

# --- X2: the branch edited the CREATE in a fragment and re-rendered -> taken.
mkrepo x2
untrack "$SCHEMA"; commit main-untrack
on_branch
put "$FRAGS/0100-base_fixture.sql" 'CREATE TABLE IF NOT EXISTS base_fixture (id INTEGER PRIMARY KEY, note TEXT);
'
render; commit branch-edit
merge_main
unmerged "$SCHEMA" && ok || bad "X2: fixture: $SCHEMA is not a conflict"
resolve
taken X2 "$SCHEMA"
[ "$(logn BH-6005)" = 0 ] && ok || bad "X2: a BH-6005 line was logged: $(cat "$MC_LOG")"

# --- X3: the branch appended a statement to schema.sql only -> REAL conflict.
mkrepo x3
untrack "$SCHEMA"; commit main-untrack
on_branch
printf 'CREATE TABLE IF NOT EXISTS prebranch_fixture (id INTEGER PRIMARY KEY);\n' >> "$W/$SCHEMA"
commit branch-schema-only
merge_main
unmerged "$SCHEMA" && ok || bad "X3: fixture: $SCHEMA is not a conflict"
resolve
refused X3 "$SCHEMA"
grep -qs 'prebranch_fixture' "$W/$SCHEMA" && ok || bad "X3: the worktree file lost prebranch_fixture"
[ "$(grep -- BH-6005 "$MC_LOG" | grep -- prebranch_fixture | grep -c -- '1 statement(s)')" = 1 ] \
  && ok || bad "X3: no BH-6005 line naming 1 statement prebranch_fixture: $(cat "$MC_LOG")"
[ "$(logn BH-1175)" = 0 ] && ok || bad "X3: the deletion was logged as taken: $(cat "$MC_LOG")"

# --- X4: the BH-1175 shape on a non-schema path -> taken, no BH-6005 line.
mkrepo x4
put notes/gen_fixture.md 'generated v1
'
commit gen-add
git -C "$W" branch -q -f "$BR"
untrack notes/gen_fixture.md; commit main-untrack
on_branch
put notes/gen_fixture.md 'generated v2
'
commit branch-edit
merge_main
unmerged notes/gen_fixture.md && ok || bad "X4: fixture: notes/gen_fixture.md is not a conflict"
resolve
taken X4 notes/gen_fixture.md
[ "$(logn BH-1175)" = 1 ] && ok || bad "X4: no BH-1175 line: $(cat "$MC_LOG")"
[ "$(logn BH-6005)" = 0 ] && ok || bad "X4: a BH-6005 line was logged: $(cat "$MC_LOG")"

# --- X5: as X1, but the merged tree has no bin/schema-build.sh -> REAL conflict.
mkrepo x5
put "$FRAGS/0200-main_fixture.sql" 'CREATE TABLE IF NOT EXISTS main_fixture (id INTEGER PRIMARY KEY);
'
untrack "$SCHEMA"; git -C "$W" rm -q -- bin/schema-build.sh; commit main-untrack
on_branch
put "$FRAGS/0201-branch_fixture.sql" 'CREATE TABLE IF NOT EXISTS branch_fixture (id INTEGER PRIMARY KEY);
'
render; commit branch-frag
merge_main
unmerged "$SCHEMA" && ok || bad "X5: fixture: $SCHEMA is not a conflict"
resolve
refused X5 "$SCHEMA"
[ "$(grep -- BH-6005 "$MC_LOG" | grep -c -- 'no bin/schema-build.sh')" = 1 ] \
  && ok || bad "X5: no 'no bin/schema-build.sh' line: $(cat "$MC_LOG")"

# --- X6: a worker with no schema.d/ -> no opinion, the deletion is taken.
mkrepo x6
put worker/cloud_fixture/schema.sql 'CREATE TABLE IF NOT EXISTS cloud_fixture (id INTEGER PRIMARY KEY);
'
commit cloud-add
git -C "$W" branch -q -f "$BR"
untrack worker/cloud_fixture/schema.sql; commit main-untrack
on_branch
printf 'CREATE TABLE IF NOT EXISTS cloud_more_fixture (id INTEGER PRIMARY KEY);\n' >> "$W/worker/cloud_fixture/schema.sql"
commit branch-edit
merge_main
unmerged worker/cloud_fixture/schema.sql && ok || bad "X6: fixture: cloud schema.sql is not a conflict"
resolve
taken X6 worker/cloud_fixture/schema.sql
[ "$(logn BH-6005)" = 0 ] && ok || bad "X6: a BH-6005 line was logged: $(cat "$MC_LOG")"

# --- X7: as X1, but main adds a stray file the builder refuses -> REAL conflict.
mkrepo x7
put "$FRAGS/0200-main_fixture.sql" 'CREATE TABLE IF NOT EXISTS main_fixture (id INTEGER PRIMARY KEY);
'
put "$FRAGS/README_fixture.txt" 'not a fragment
'
untrack "$SCHEMA"; commit main-untrack
on_branch
put "$FRAGS/0201-branch_fixture.sql" 'CREATE TABLE IF NOT EXISTS branch_fixture (id INTEGER PRIMARY KEY);
'
render; commit branch-frag
merge_main
unmerged "$SCHEMA" && ok || bad "X7: fixture: $SCHEMA is not a conflict"
resolve
refused X7 "$SCHEMA"
[ "$(grep -- BH-6005 "$MC_LOG" | grep -c -- 'could not be composed')" = 1 ] \
  && ok || bad "X7: no 'could not be composed' line: $(cat "$MC_LOG")"

# --- X8: main dropped a fragment the base had; the branch's copy still holds
# that base statement. It is not the branch's statement to lose -> taken.
mkrepo x8
put "$FRAGS/0200-main_fixture.sql" 'CREATE TABLE IF NOT EXISTS main_fixture (id INTEGER PRIMARY KEY);
'
git -C "$W" rm -q -- "$FRAGS/0100-base_fixture.sql"
untrack "$SCHEMA"; commit main-untrack
on_branch
put "$FRAGS/0201-branch_fixture.sql" 'CREATE TABLE IF NOT EXISTS branch_fixture (id INTEGER PRIMARY KEY);
'
render; commit branch-frag
merge_main
unmerged "$SCHEMA" && ok || bad "X8: fixture: $SCHEMA is not a conflict"
resolve
taken X8 "$SCHEMA"
[ "$(logn BH-6005)" = 0 ] && ok || bad "X8: a BH-6005 line was logged: $(cat "$MC_LOG")"

echo "schema-drop-safe.bh-6005-3: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
