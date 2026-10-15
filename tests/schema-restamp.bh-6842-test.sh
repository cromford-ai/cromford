#!/bin/bash
# tests/schema-restamp.bh-6842-test.sh — BH-6842: bin/lib/schema-restamp.sh
# renames a PR's stale stamp-form schema fragments to a later minute, and proves
# a restamp-only commit.
#
#   S1  main's newest is 202610150259, the PR adds 202610142106: renamed to the
#       clock minute (09:00), and the REAL rp_schema_fragment_name is then green
#   S2  the PR stamp equals main's newest minute: still stale, renamed
#   S3  two PR fragments: consecutive new minutes, the old order kept; a clock
#       earlier than main's newest starts at newest + 1 minute
#   S4  a suite and a doc that name the old basename name the new one, no other
#       byte changes; a fragment that names it in a SQL comment is not touched
#   S5  the SQL blob of every renamed fragment is the same before and after
#   S6  a fresh stamp, an NNNN fragment, no stamp at main: an empty plan; two
#       PR fragments with one suffix that would swap names: rc 2
#   R1  the sr_apply commit, renames only: sr_commit_only rc 0, restamp_same
#   R2  renames plus reference rewrites: restamp_same
#   R3  the restamp, then a clean main merge: restamp_same
#   R4  the restamp commit also edits one other line: refused
#   R5  a fragment byte changes in the rename: refused
#   R6  a rename out of schema.d, and a suffix change: refused
#   R7  a mode change: refused
#   R8  a new fragment in the same commit, and a hand-resolved merge after the
#       restamp: refused
#   T1  sr_stamp_order_line / sr_stamp_split on the rules pack's own lines
#   M1  mutation: the stale compare made strict (<) leaves S2 un-renamed
# Real git; no network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-restamp.bh-6842-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/schema-restamp.sh"
[ -f "$LIB" ] || { echo "FAIL: bin/lib/schema-restamp.sh does not exist"; exit 1; }
# shellcheck source=bin/lib/schema-restamp.sh
. "$LIB" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }
# shellcheck source=bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
NOW0900=$(date -u -d '2026-10-15 09:00' +%s)
NOW0100=$(date -u -d '2026-10-15 01:00' +%s)
SD=worker/jobs/schema.d
R="$T/repo"

g() { git -C "$R" "$@"; }
commit() { g add -A; g commit -qm "$1"; }
# seed <pr-fragment...> — main: 0000-base + 202610140000-bh-0-z at the fork,
#   then 202610150259-bh-1-a after it. Branch pr (checked out at the end) adds
#   each named fragment, a suite and a doc that name the first one.
seed() {
  scratch_rm "$R" 2>/dev/null
  mkdir -p "$R/$SD" "$R/tests" "$R/docs"; g init -q -b main
  printf 'CREATE TABLE base (id INTEGER);\n' > "$R/$SD/0000-base.sql"
  printf 'CREATE TABLE z (id INTEGER);\n' > "$R/$SD/202610140000-bh-0-z.sql"
  commit base
  g checkout -qb pr
  local f
  for f in "$@"; do printf -- '-- %s\nCREATE TABLE t_%s (id INTEGER);\n' "$f" "${#f}" > "$R/$SD/$f"; done
  printf '#!/bin/bash\n# reads %s\ncat worker/jobs/schema.d/%s\n' "$1" "$1" > "$R/tests/x.bh-2-test.sh"
  printf '# note\n\nThe fragment `%s` makes the table.\n' "$1" > "$R/docs/n.md"
  commit pr
  g checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$R/$SD/202610150259-bh-1-a.sql"
  commit main-a
  g checkout -q pr
}
plan() { SR_NOW_EPOCH="$1" sr_plan "$R" main HEAD; }
apply() { SR_NOW_EPOCH="$1" sr_apply "$R" main; }

# ── S1 ──
seed 202610142106-bh-2-b.sql
out=$(plan "$NOW0900"); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$SD/202610142106-bh-2-b.sql	$SD/202610150900-bh-2-b.sql" ] && ok || bad "S1 plan rc=$rc out='$out'"
rp_schema_fragment_name "$R" main >/dev/null; [ $? = 1 ] && ok || bad "S1 setup: the rules pack must be red on the stale stamp before the restamp"
OLDHEAD=$(g rev-parse HEAD)
new=$(apply "$NOW0900"); rc=$?
[ "$rc" = 0 ] && [ "$new" = "$(g rev-parse HEAD)" ] && [ "$new" != "$OLDHEAD" ] && ok || bad "S1 apply rc=$rc new='$new'"
[ -f "$R/$SD/202610150900-bh-2-b.sql" ] && [ ! -e "$R/$SD/202610142106-bh-2-b.sql" ] && ok || bad "S1 the fragment was not renamed: $(ls "$R/$SD")"
rpo=$(rp_schema_fragment_name "$R" main); rprc=$?
[ "$rprc" = 0 ] && ok || bad "S1 the real rp_schema_fragment_name must be green after the restamp (rc $rprc): $rpo"
[ "$(g log -1 --format=%s)" = 'restamp schema fragments (no SQL change)' ] && ok || bad "S1 subject: $(g log -1 --format=%s)"
g log -1 --format=%b | grep -qxF "Restamped: 202610142106-bh-2-b.sql -> 202610150900-bh-2-b.sql" && ok || bad "S1 body: $(g log -1 --format=%b)"
[ "$(g rev-list --count "$OLDHEAD..HEAD")" = 1 ] && ok || bad "S1 want exactly one new commit"
# S5 on S1's commit: the SQL bytes are the blob of the old name
[ "$(g rev-parse "HEAD~1:$SD/202610142106-bh-2-b.sql")" = "$(g rev-parse "HEAD:$SD/202610150900-bh-2-b.sql")" ] \
  && ok || bad "S5 the fragment's blob changed in the restamp"
# S4 on S1's commit: the suite and the doc name the new basename, nothing else moved
for f in tests/x.bh-2-test.sh docs/n.md; do
  want=$(g show "HEAD~1:$f" | sed 's/202610142106-bh-2-b\.sql/202610150900-bh-2-b.sql/g')
  [ "$(g show "HEAD:$f")" = "$want" ] && ok || bad "S4 $f: want the old text with only the basename replaced, got: $(g show "HEAD:$f")"
done
g grep -q -F 202610142106-bh-2-b.sql HEAD -- tests docs && bad "S4 a reference to the old basename is left outside schema.d" || ok
# R1/R2: the real writer's commit is restamp-only, and restamp_same carries it
sr_commit_only "$R" HEAD && ok || bad "R2 sr_commit_only must accept the sr_apply commit (renames + references)"
how=$(restamp_same "$R" main "$OLDHEAD" HEAD); rc=$?
[ "$rc" = 0 ] && [ "$how" = restamp ] && ok || bad "R2 restamp_same rc=$rc how='$how'"
# S6 (idempotent): the restamped head plans nothing
out=$(plan "$NOW0900"); [ $? = 0 ] && [ -z "$out" ] && ok || bad "S6 a restamped head must plan nothing: '$out'"
# R3: the restamp, then a clean main merge
g merge -q --no-edit main >/dev/null 2>&1
how=$(restamp_same "$R" main "$OLDHEAD" HEAD); rc=$?
[ "$rc" = 0 ] && [ "$how" = restamp ] && ok || bad "R3 restamp + clean main merge: rc=$rc how='$how'"
# R8b: a hand-resolved (evil) merge after the restamp
g reset -q --hard HEAD~1
g merge -q --no-commit main >/dev/null 2>&1; echo 'smuggled' >> "$R/docs/n.md"; g add -A; g commit -qm 'merge main' >/dev/null
restamp_same "$R" main "$OLDHEAD" HEAD >/dev/null && bad "R8 a merge with a hand edit after the restamp must refuse" || ok

# ── S2: equal minute is stale ──
seed 202610150259-bh-2-b.sql
out=$(plan "$NOW0900")
[ "$out" = "$SD/202610150259-bh-2-b.sql	$SD/202610150900-bh-2-b.sql" ] && ok || bad "S2 the equal-minute fragment must be renamed: '$out'"

# ── S3: two fragments keep their order; an early clock starts at newest + 1 ──
seed 202610142106-bh-2-b.sql 202610142107-bh-2-c.sql
out=$(plan "$NOW0900")
want="$SD/202610142106-bh-2-b.sql	$SD/202610150900-bh-2-b.sql
$SD/202610142107-bh-2-c.sql	$SD/202610150901-bh-2-c.sql"
[ "$out" = "$want" ] && ok || bad "S3 two fragments: '$out'"
out=$(plan "$NOW0100")
want="$SD/202610142106-bh-2-b.sql	$SD/202610150300-bh-2-b.sql
$SD/202610142107-bh-2-c.sql	$SD/202610150301-bh-2-c.sql"
[ "$out" = "$want" ] && ok || bad "S3 an early clock must start at main's newest + 1 minute: '$out'"
# one stale and one fresh: both move, in order
seed 202610142106-bh-2-b.sql 202610151000-bh-2-c.sql
out=$(plan "$NOW0900")
want="$SD/202610142106-bh-2-b.sql	$SD/202610150900-bh-2-b.sql
$SD/202610151000-bh-2-c.sql	$SD/202610150901-bh-2-c.sql"
[ "$out" = "$want" ] && ok || bad "S3 one stale + one fresh: both renamed in order: '$out'"

# ── S4b: a SQL comment in another fragment keeps the old name (bytes unchanged) ──
seed 202610142106-bh-2-b.sql 202610142107-bh-2-c.sql
printf -- '-- after 202610142106-bh-2-b.sql\nCREATE TABLE c (id INTEGER);\n' > "$R/$SD/202610142107-bh-2-c.sql"; commit c-names-b
CB=$(g rev-parse "HEAD:$SD/202610142107-bh-2-c.sql")
apply "$NOW0900" >/dev/null
[ "$(g rev-parse "HEAD:$SD/202610150901-bh-2-c.sql")" = "$CB" ] && ok || bad "S4b a fragment's bytes changed in the reference rewrite"
for f in 202610142106-bh-2-b.sql 202610142107-bh-2-c.sql; do
  n="${f/202610142106/202610150900}"; n="${n/202610142107/202610150901}"
  [ "$(g rev-parse "HEAD~1:$SD/$f")" = "$(g rev-parse "HEAD:$SD/$n")" ] && ok || bad "S5 the blob of $f changed"
done

# ── S6: nothing to do, and the collision ──
seed 202610151000-bh-2-b.sql
out=$(plan "$NOW0900"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "S6 a fresh stamp: rc=$rc '$out'"
apply "$NOW0900" >/dev/null; [ $? = 1 ] && ok || bad "S6 sr_apply on a fresh head must be rc 1 (nothing to do)"
seed 0099-bh-2-b.sql
out=$(plan "$NOW0900"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "S6 an NNNN fragment is never renamed: rc=$rc '$out'"
scratch_rm "$R"; mkdir -p "$R/$SD"; g init -q -b main
printf 'x\n' > "$R/$SD/0000-base.sql"; commit base; g checkout -qb pr
printf 'y\n' > "$R/$SD/202601010000-bh-2-b.sql"; commit pr
out=$(plan "$NOW0900"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "S6 no stamp fragment at main: rc=$rc '$out'"
seed 202610142106-bh-2-b.sql 202610150900-bh-2-b.sql
out=$(plan "$NOW0900" 2>"$T/err"); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && [ -s "$T/err" ] && ok || bad "S6 a new name equal to another old name must be rc 2 with one stderr line: rc=$rc out='$out'"
before=$(g rev-parse HEAD)
apply "$NOW0900" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ "$(g rev-parse HEAD)" = "$before" ] && ok || bad "S6 sr_apply on a collision must be rc 2 with no commit (rc $rc)"

# ── R matrix: hand-made commits on a stale head ──
# rename <old> <new> — git mv inside schema.d, no commit
rn() { g mv "$SD/$1" "$2"; }
base_r() { seed 202610142106-bh-2-b.sql; RA=$(g rev-parse HEAD); }
cm() { g commit -qm "$1"; }

# R1: renames only (no reference rewrite)
base_r; rn 202610142106-bh-2-b.sql "$SD/202610150900-bh-2-b.sql"; cm r1
sr_commit_only "$R" HEAD && ok || bad "R1 a pure rename must be restamp-only"
[ "$(restamp_same "$R" main "$RA" HEAD)" = restamp ] && ok || bad "R1 restamp_same on a pure rename"
# R4: the restamp commit also edits one other line
base_r; apply "$NOW0900" >/dev/null; echo 'echo extra' >> "$R/tests/x.bh-2-test.sh"; g add -A; g commit -q --amend --no-edit
sr_commit_only "$R" HEAD && bad "R4 a restamp that also edits a line must refuse" || ok
restamp_same "$R" main "$RA" HEAD >/dev/null && bad "R4 restamp_same must refuse" || ok
# R4b: a restamp commit then a separate code commit
base_r; apply "$NOW0900" >/dev/null; echo 'echo extra' >> "$R/tests/x.bh-2-test.sh"; g add -A; cm code
restamp_same "$R" main "$RA" HEAD >/dev/null && bad "R4b a code commit after the restamp must refuse" || ok
# R5: a fragment byte changes in the rename
base_r; rn 202610142106-bh-2-b.sql "$SD/202610150900-bh-2-b.sql"; echo '-- one byte more' >> "$R/$SD/202610150900-bh-2-b.sql"; g add -A; cm r5
sr_commit_only "$R" HEAD && bad "R5 a fragment content change must refuse" || ok
# R6: a rename out of schema.d, and a suffix change
base_r; g mv "$SD/202610142106-bh-2-b.sql" "worker/jobs/202610150900-bh-2-b.sql"; cm r6a
sr_commit_only "$R" HEAD && bad "R6 a rename out of schema.d must refuse" || ok
base_r; rn 202610142106-bh-2-b.sql "$SD/202610150900-bh-2-z.sql"; cm r6b
sr_commit_only "$R" HEAD && bad "R6 a suffix change must refuse" || ok
# R7: a mode change in the rename
base_r; rn 202610142106-bh-2-b.sql "$SD/202610150900-bh-2-b.sql"; chmod +x "$R/$SD/202610150900-bh-2-b.sql"; g add -A; cm r7
sr_commit_only "$R" HEAD && bad "R7 a mode change must refuse" || ok
# R8: a new fragment added in the same commit
base_r; rn 202610142106-bh-2-b.sql "$SD/202610150900-bh-2-b.sql"; printf 'CREATE TABLE q (id INTEGER);\n' > "$R/$SD/202610150901-bh-2-q.sql"; g add -A; cm r8
sr_commit_only "$R" HEAD && bad "R8 a new fragment in the restamp commit must refuse" || ok
# a merge commit is never restamp-only, and no commit at all is not a restamp
sr_commit_only "$R" "$(g rev-parse HEAD)~99" 2>/dev/null && bad "R an unreadable commit must refuse" || ok
restamp_same "$R" main "$RA" "$RA" >/dev/null && bad "R identical heads are not a restamp" || ok

# ── T1: the rules pack's own lines ──
seed 202610142106-bh-2-b.sql
STAMP=$(rp_schema_fragment_name "$R" main | sed 's/^/schema-fragment-name: /')
sr_stamp_order_line "$STAMP" && ok || bad "T1 the rules pack's stamp-order line must match: $STAMP"
seed 0000-bh-2-b.sql
TAKEN=$(rp_schema_fragment_name "$R" main | sed 's/^/schema-fragment-name: /')
sr_stamp_order_line "$TAKEN" && bad "T1 the NNNN-taken line must not match: $TAKEN" || ok
seed 1-bh-2-b.sql
MAL=$(rp_schema_fragment_name "$R" main | sed 's/^/schema-fragment-name: /')
sr_stamp_order_line "$MAL" && bad "T1 the malformed-name line must not match: $MAL" || ok
[ -n "$STAMP" ] && [ -n "$TAKEN" ] && [ -n "$MAL" ] && ok || bad "T1 setup: the real rules pack printed no line"
printf '%s\n' "$STAMP" "$TAKEN" '' "index-on-create-table: worker/jobs/schema.d/x.sql: no index" > "$T/in"
sr_stamp_split "$T/in" "$T/real" "$T/note"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/note")" = "$STAMP" ] && [ "$(cat "$T/real")" = "$TAKEN
index-on-create-table: worker/jobs/schema.d/x.sql: no index" ] && ok || bad "T1 split rc=$rc note='$(cat "$T/note")' real='$(cat "$T/real")'"

# ── M1: mutation — a strict compare leaves the equal-minute fragment alone ──
sed 's/\[\[ "\${s:0:12}" > "\$top" \]\] || stale=1/[[ "${s:0:12}" < "$top" ]] \&\& stale=1/' "$LIB" > "$T/mut.sh"
if cmp -s "$T/mut.sh" "$LIB"; then
  bad "M1 the mutation anchor (the stale compare in sr_plan) is missing"
else
  seed 202610150259-bh-2-b.sql
  out=$(bash -c '. "$1"; SR_NOW_EPOCH="$2" sr_plan "$3" main HEAD' _ "$T/mut.sh" "$NOW0900" "$R")
  [ -z "$out" ] && ok || bad "M1 the strict compare must leave S2 un-renamed (S2 would go red), got '$out'"
fi

echo "schema-restamp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
