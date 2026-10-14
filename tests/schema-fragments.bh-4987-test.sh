#!/bin/bash
# tests/schema-fragments.bh-4987-test.sh — worker/jobs/schema.sql is a RENDER of
# worker/jobs/schema.d/NNNN-<name>.sql, composed by bin/schema-build.sh.
#
# WHAT THIS PINS (BH-4987). docs/CONFLICT_HOTSPOTS.md (BH-4986) ranked
# worker/jobs/schema.sql the top conflict hotspot in the repo: every new table
# was appended at its EOF, so any two builds that each added one collided on
# the same hunk. A new table is now a NEW file under schema.d/, and schema.sql
# stays committed, byte for byte what its ~220 readers already read.
#
#   S1 the composition at the split commit is the old file, byte for byte, and
#      `--check` is green on the repo as it is
#   S2 two fixture branches each adding a fragment: no fragment ever conflicts,
#      the real conductor functions (mc_resolve_conflicts + mc_regen_generated,
#      fed by the real Generated files row) settle schema.sql with nobody
#      resolving anything, and the result is the canonical sorted composition
#   S3 editing schema.sql by hand, or adding a fragment without --write, is red,
#      and --write refuses to delete a statement that is in no fragment
#   S4 a stray file, a fragment with no final newline, an empty fragment are red
#      and --write leaves schema.sql untouched
#   S5 a fragment that ends mid-statement is red
#   S6 a worker with no schema.d/ is skipped, never touched
#   S7 two fragments sharing a number, and `;` inside a comment or a string,
#      are fine
#   S9 a branch cut before the split keeps its tables through the conductor's
#      regenerate, a conflict union and a batch train's --theirs; a fragment
#      edit and a statement the branch removed itself are never refused
#   S10 the edit loop (a fragment edited twice before a commit, --write after
#      each) is never refused, and a hand edit after a --write still is
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SB="$DIR/bin/schema-build.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"; mkdir -p "$HOME"

# run <root> <args...> — the script installed under <root>, stdout/stderr/rc kept.
run() {
  local root="$1"; shift
  ( cd "$root" && bin/schema-build.sh "$@" ) >"$T/out" 2>"$T/err"; RC=$?
}
# fresh <tag> — a scratch tree with the script's closure and one base fragment,
# composed the way production composes it (a fragment plus --write).
fresh() {
  W="$T/$1"; mkdir -p "$W/worker/jobs/schema.d"
  scratch_install_closure bin/schema-build.sh "$W" >/dev/null || { echo "closure install failed"; exit 1; }
  printf '%s\n' 'CREATE TABLE a (id INTEGER PRIMARY KEY, name TEXT);' \
                '-- b holds the second thing' \
                'CREATE TABLE b (id INTEGER PRIMARY KEY);' > "$W/worker/jobs/schema.d/0000-base.sql"
  run "$W" --write
  [ "$RC" = 0 ] || { echo "fixture --write failed rc=$RC: $(cat "$T/err")"; exit 1; }
}
sum() { sha256sum "$1" | cut -d' ' -f1; }
mt()  { stat -c %Y "$1"; }

# =============================================================================
# S1 byte-exact at the split commit, and --check green on the repo as it is.
# =============================================================================
"$SB" --worker jobs >"$T/s1.compose" 2>"$T/s1.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 composing the repo's jobs schema must exit 0, got $RC: $(cat "$T/s1.err")"
[ -s "$T/s1.compose" ] && ok || bad "S1 the composition must not be empty"
cmp -s "$T/s1.compose" "$DIR/worker/jobs/schema.sql" && ok \
  || bad "S1 the composition must equal the committed worker/jobs/schema.sql byte for byte"
# The old file: main's schema.sql while main has no schema.d/ yet (this PR is
# the split), and the split commit's parent once it has landed.
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1 \
   && ! git -C "$DIR" cat-file -e origin/main:worker/jobs/schema.d/0000-base.sql 2>/dev/null; then
  git -C "$DIR" show origin/main:worker/jobs/schema.sql >"$T/s1.old" 2>/dev/null
  cmp -s "$T/s1.compose" "$T/s1.old" && ok \
    || bad "S1 the composition must equal origin/main's worker/jobs/schema.sql byte for byte (the old file)"
fi
SPLIT=$(git -C "$DIR" log --diff-filter=A --format=%H -1 -- worker/jobs/schema.d/0000-base.sql 2>/dev/null)
if [ -n "$SPLIT" ] && git -C "$DIR" cat-file -e "$SPLIT^:worker/jobs/schema.sql" 2>/dev/null; then
  S1W="$T/s1split"; mkdir -p "$S1W/worker/jobs"
  scratch_install_closure bin/schema-build.sh "$S1W" >/dev/null || { echo "closure install failed"; exit 1; }
  git -C "$DIR" archive "$SPLIT" worker/jobs/schema.d | tar -x -C "$S1W"
  ( cd "$S1W" && bin/schema-build.sh --worker jobs ) >"$T/s1.split" 2>/dev/null
  git -C "$DIR" show "$SPLIT^:worker/jobs/schema.sql" >"$T/s1.parent"
  cmp -s "$T/s1.split" "$T/s1.parent" && ok \
    || bad "S1 at the split commit ${SPLIT:0:12} the fragments must compose to its parent's schema.sql byte for byte"
fi
"$SB" --check >"$T/s1.out" 2>"$T/s1.err"; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 --check must exit 0 on the repo as it is, got $RC: $(cat "$T/s1.err")"

# =============================================================================
# S2 two fixture branches each add a fragment; the conductor settles schema.sql.
# =============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/locks" "$T/h/flags" "$T/h/builds" "$T/h/config"
unset MC_UNION_FILES
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh" || { echo "cannot source merge-conductor-lib.sh"; exit 1; }
mc_init
: > "$MC_LOG"

# The Generated files row, read from the REAL table: deleting it there is what
# this case must notice.
ROW=$(grep -F '| `worker/jobs/schema.sql` |' "$DIR/docs/verification-map/index/tail.md")
[ -n "$ROW" ] && ok || bad "S2 docs/verification-map/index/tail.md must declare worker/jobs/schema.sql in its Generated files table"

# s2_case <tag> <main's fragment> <branch's fragment> — main and branch A/B fork
# from one base; A (main's side) lands first, then B merges main.
s2_case() {
  local tag="$1" fa="$2" fb="$3"
  fresh "$tag"
  mkdir -p "$W/docs/verification-map/index"
  printf '%s\n' '# tail' '' '## Generated files' '' \
    '| path | regenerate with | committed |' '| --- | --- | --- |' "$ROW" \
    > "$W/docs/verification-map/index/tail.md"
  git init -q -b main "$W"
  git -C "$W" config user.email t@t; git -C "$W" config user.name t; git -C "$W" config commit.gpgsign false
  git -C "$W" add -A; git -C "$W" commit -qm base
  git -C "$W" branch -q a; git -C "$W" branch -q "$BR"
  git -C "$W" checkout -q a
  printf 'CREATE TABLE %s (id INTEGER PRIMARY KEY);\n' "${fa#*-}" > "$W/worker/jobs/schema.d/$fa.sql"
  run "$W" --write; git -C "$W" add -A; git -C "$W" commit -qm "add $fa"
  git -C "$W" checkout -q "$BR"
  printf 'CREATE TABLE %s (id INTEGER PRIMARY KEY);\n' "${fb#*-}" > "$W/worker/jobs/schema.d/$fb.sql"
  run "$W" --write; git -C "$W" add -A; git -C "$W" commit -qm "add $fb"
  git -C "$W" checkout -q main
  git -C "$W" merge -q --no-edit a >/dev/null 2>&1 || bad "S2[$tag] merging branch A into main must be clean"
  git -C "$W" checkout -q "$BR"
  git -C "$W" merge -q --no-edit main >/dev/null 2>&1
  CONF=$(git -C "$W" diff --name-only --diff-filter=U)
  # Both renders appended at the same EOF, so git DOES conflict on the render —
  # and on nothing else. That conflict is what the conductor has to settle.
  [ "$CONF" = worker/jobs/schema.sql ] && ok || bad "S2[$tag] the only conflicted path must be worker/jobs/schema.sql, got: ${CONF:-none}"
  grep -q 'schema\.d/' <<<"$CONF" && bad "S2[$tag] no schema.d/ fragment may conflict: $CONF" || ok
  OUT=$(mc_resolve_conflicts "$W" "$BR"); RC=$?
  [ "$RC" = 0 ] && ok || bad "S2[$tag] mc_resolve_conflicts must settle it (rc 0), got $RC: $OUT; $(tail -3 "$MC_LOG")"
  git -C "$W" commit -q --no-edit >/dev/null 2>&1 || bad "S2[$tag] the resolved merge must commit"
  BEFORE=$(git -C "$W" rev-parse HEAD)
  mc_regen_generated "$W" main "s2 $tag"
  AFTER=$(git -C "$W" rev-parse HEAD)
  [ -z "$(git -C "$W" status --porcelain)" ] && ok || bad "S2[$tag] the tree must be clean after the regenerate: $(git -C "$W" status --porcelain)"
  run "$W" --check
  [ "$RC" = 0 ] && ok || bad "S2[$tag] --check must be green on the merged tree, got $RC: $(cat "$T/err")"
  grep -q "CREATE TABLE ${fa#*-} " "$W/worker/jobs/schema.sql" && grep -q "CREATE TABLE ${fb#*-} " "$W/worker/jobs/schema.sql" \
    && ok || bad "S2[$tag] both tables must be in schema.sql: $(cat "$W/worker/jobs/schema.sql")"
}
BR=ticket/bh-9001

# S2a the plan's shape: alpha lands on main, beta on the branch; sorted order
# and the union's main-first order agree.
s2_case s2a 0001-alpha 0001-beta
A=$(grep -n 'CREATE TABLE alpha ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
B=$(grep -n 'CREATE TABLE beta ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
[ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ] && ok || bad "S2a alpha must come before beta (alpha at ${A:-?}, beta at ${B:-?})"

# S2b main's fragment sorts AFTER the branch's: the union puts main's block
# first, so only the regenerate from the declared row can make it canonical.
s2_case s2b 0002-zeta 0001-beta
B=$(grep -n 'CREATE TABLE beta ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
Z=$(grep -n 'CREATE TABLE zeta ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
[ -n "$B" ] && [ -n "$Z" ] && [ "$B" -lt "$Z" ] && ok || bad "S2b beta (0001) must come before zeta (0002) after the regenerate (beta at ${B:-?}, zeta at ${Z:-?})"
# TEST-CHANGE (BH-6000): the conflict on schema.sql is now settled by
# re-rendering it over the merged tree (config/regenerated-paths.conf), so the
# merge commit itself already holds the canonical render and the later
# mc_regen_generated has nothing left to commit (HEAD may stay). The property
# this case is about is unchanged and asserted on the committed bytes: HEAD's
# schema.sql is the render of the merged fragments.
[ "$(git -C "$W" show HEAD:worker/jobs/schema.sql)" = "$(cat "$W"/worker/jobs/schema.d/*.sql)" ] \
  && ok || bad "S2b HEAD must carry the canonical render of the merged fragments (HEAD ${BEFORE:0:8} -> ${AFTER:0:8})"

# =============================================================================
# S3 a direct edit is red; a fragment without --write is red; --write fixes it.
# =============================================================================
fresh s3
printf 'CREATE TABLE sneaky (id INTEGER);\n' >> "$W/worker/jobs/schema.sql"
run "$W" --check
[ "$RC" = 1 ] && ok || bad "S3 --check must exit 1 after a hand edit of schema.sql, got $RC"
grep -q 'schema\.d/' "$T/err" && grep -q -- '--write' "$T/err" && ok \
  || bad "S3 the failure must point at schema.d/ and --write: $(cat "$T/err")"
grep -q 'do not edit schema.sql directly' "$T/err" && ok || bad "S3 the failure must say not to edit schema.sql: $(cat "$T/err")"
grep -q 'CREATE TABLE sneaky' "$T/err" && ok || bad "S3 --check must name the statement that is in no fragment: $(cat "$T/err")"
# BH-4987 review: this case used to assert that --write DROPS the hand-added
# table. That is the data loss the lead review found: a branch cut before the
# split loses its tables on the first rebase. --write now refuses, names the
# statement and leaves schema.sql as it was.
S3SUM=$(sum "$W/worker/jobs/schema.sql")
run "$W" --write
[ "$RC" = 1 ] && ok || bad "S3 --write must refuse (rc 1) a schema.sql holding a statement that is in no fragment, got $RC"
[ "$(sum "$W/worker/jobs/schema.sql")" = "$S3SUM" ] && ok || bad "S3 a refused --write must leave schema.sql untouched"
grep -q sneaky "$W/worker/jobs/schema.sql" && ok || bad "S3 --write must never drop a table that is in no fragment"
grep -q 'CREATE TABLE sneaky' "$T/err" && grep -qF 'schema.d/NNNN-<name>.sql' "$T/err" && ok \
  || bad "S3 the refusal must name the statement and say to move it into schema.d/NNNN-<name>.sql: $(cat "$T/err")"
# The fix the message asks for: the statement moves into a fragment.
printf 'CREATE TABLE sneaky (id INTEGER);\n' > "$W/worker/jobs/schema.d/0000-sneaky.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S3 --write must exit 0 once the statement is in a fragment, got $RC: $(cat "$T/err")"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S3 --check must be green once the statement is in a fragment, got $RC: $(cat "$T/err")"
grep -q sneaky "$W/worker/jobs/schema.sql" && ok || bad "S3 the moved table must still be in schema.sql"
printf 'CREATE TABLE late (id INTEGER);\n' > "$W/worker/jobs/schema.d/0001-late.sql"
run "$W" --check
[ "$RC" = 1 ] && ok || bad "S3 a new fragment without --write must make --check exit 1, got $RC"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S3 --write must exit 0, got $RC: $(cat "$T/err")"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S3 after --write --check must exit 0, got $RC: $(cat "$T/err")"
tail -n 1 "$W/worker/jobs/schema.sql" | grep -q 'CREATE TABLE late ' && ok || bad "S3 the new fragment's table must be the last line"

# =============================================================================
# S4 malformed fragments are red, and --write never rewrites schema.sql then.
# =============================================================================
fresh s4
SCH="$W/worker/jobs/schema.sql"
touch -d '2001-01-01 00:00:00' "$SCH"
S0=$(sum "$SCH"); M0=$(mt "$SCH")
s4_red() {
  local what="$1" path="$2"
  run "$W" --check
  [ "$RC" = 1 ] && ok || bad "S4 $what: --check must exit 1, got $RC"
  grep -qF "$path" "$T/err" && ok || bad "S4 $what: the failure must name $path: $(cat "$T/err")"
  run "$W" --write
  [ "$RC" = 1 ] && ok || bad "S4 $what: --write must exit 1, got $RC"
  [ "$(sum "$SCH")" = "$S0" ] && [ "$(mt "$SCH")" = "$M0" ] && ok || bad "S4 $what: --write must leave schema.sql untouched"
}
printf 'stray\n' > "$W/worker/jobs/schema.d/foo.txt"
s4_red 'stray foo.txt' 'schema.d/foo.txt'; rm -f "$W/worker/jobs/schema.d/foo.txt"
printf 'CREATE TABLE x (id INTEGER);' > "$W/worker/jobs/schema.d/0002-x.sql"
s4_red 'no final newline' 'schema.d/0002-x.sql'; rm -f "$W/worker/jobs/schema.d/0002-x.sql"
: > "$W/worker/jobs/schema.d/0003-e.sql"
s4_red 'empty fragment' 'schema.d/0003-e.sql'; rm -f "$W/worker/jobs/schema.d/0003-e.sql"
mkdir "$W/worker/jobs/schema.d/0004-dir.sql"
s4_red 'subdirectory' 'schema.d/0004-dir.sql'; rmdir "$W/worker/jobs/schema.d/0004-dir.sql"
printf 'CREATE TABLE y (id INTEGER);\n' > "$W/worker/jobs/schema.d/0005-Upper.sql"
s4_red 'bad name' 'schema.d/0005-Upper.sql'; rm -f "$W/worker/jobs/schema.d/0005-Upper.sql"
mv "$W/worker/jobs/schema.d/0000-base.sql" "$T/s4.base"
s4_red 'no fragment at all' 'schema.d'; mv "$T/s4.base" "$W/worker/jobs/schema.d/0000-base.sql"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S4 the tree restored must be green again, got $RC: $(cat "$T/err")"

# =============================================================================
# S5 a statement split across two fragments is red.
# =============================================================================
fresh s5
printf 'CREATE TABLE t (a TEXT\n' > "$W/worker/jobs/schema.d/0001-open.sql"
printf ');\n' > "$W/worker/jobs/schema.d/0002-close.sql"
S0=$(sum "$W/worker/jobs/schema.sql")
run "$W" --write
[ "$RC" = 1 ] && ok || bad "S5 --write must exit 1 on a statement split across fragments, got $RC"
[ "$(sum "$W/worker/jobs/schema.sql")" = "$S0" ] && ok || bad "S5 --write must leave schema.sql untouched"
run "$W" --check
[ "$RC" = 1 ] && ok || bad "S5 --check must exit 1, got $RC"
grep -q 'whole statements' "$T/err" && ok || bad "S5 the failure must say fragments hold whole statements: $(cat "$T/err")"

# =============================================================================
# S6 a worker with no schema.d/ is skipped, never touched.
# =============================================================================
fresh s6
mkdir -p "$W/worker/plain"
printf 'CREATE TABLE c (id INTEGER);\n-- hand kept\n' > "$W/worker/plain/schema.sql"
C0=$(sum "$W/worker/plain/schema.sql")
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S6 --check must exit 0 with a worker that has no schema.d/, got $RC: $(cat "$T/err")"
grep -q 'worker/plain' "$T/err" && ok || bad "S6 the skip must be said on stderr: $(cat "$T/err")"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S6 --write must exit 0, got $RC"
[ "$(sum "$W/worker/plain/schema.sql")" = "$C0" ] && ok || bad "S6 --write must not touch worker/plain/schema.sql"
run "$W" --worker plain --check
[ "$RC" = 0 ] && ok || bad "S6 --worker plain --check must exit 0 (skipped), got $RC"
run "$W" --worker nope --check
[ "$RC" = 2 ] && ok || bad "S6 --worker naming no worker must exit 2, got $RC"

# =============================================================================
# S7 adversarial negatives: a shared number, `;` in a comment and in a string.
# =============================================================================
fresh s7
printf 'CREATE TABLE sa (id INTEGER);\n' > "$W/worker/jobs/schema.d/0001-a.sql"
printf '%s\n' '-- ids are ;-joined; see below' \
              "INSERT INTO sa (id) SELECT 1 WHERE 'x;y' <> '';" > "$W/worker/jobs/schema.d/0001-b.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S7 --write must exit 0, got $RC: $(cat "$T/err")"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S7 --check must exit 0, got $RC: $(cat "$T/err")"
A=$(grep -n 'CREATE TABLE sa ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
B=$(grep -n 'INSERT INTO sa ' "$W/worker/jobs/schema.sql" | cut -d: -f1)
[ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ] && ok || bad "S7 0001-a must come before 0001-b"
cat "$W/worker/jobs/schema.d/0000-base.sql" "$W/worker/jobs/schema.d/0001-a.sql" "$W/worker/jobs/schema.d/0001-b.sql" > "$T/s7.want"
cmp -s "$T/s7.want" "$W/worker/jobs/schema.sql" && ok || bad "S7 schema.sql must be the plain concatenation of the fragments in name order"

# =============================================================================
# S8 the documented surface: --help, the print mode, --to, a bad argument.
# =============================================================================
run "$W" --help
[ "$RC" = 0 ] && grep -q 'schema.d/' "$T/out" && ok || bad "S8 --help must exit 0 and describe schema.d/, got $RC"
run "$W"
[ "$RC" = 0 ] && cmp -s "$T/out" "$W/worker/jobs/schema.sql" && ok || bad "S8 no mode must print the composition, got $RC"
run "$W" --to "$T/s8.to"
[ "$RC" = 0 ] && cmp -s "$T/s8.to" "$W/worker/jobs/schema.sql" && ok || bad "S8 --to must write the composition there, got $RC"
run "$W" --bogus
[ "$RC" = 2 ] && ok || bad "S8 an unknown argument must exit 2, got $RC"

# =============================================================================
# S9 a branch cut BEFORE the split keeps its tables (BH-4987 lead review).
# =============================================================================
# The branch appended a CREATE TABLE straight to schema.sql while main had no
# schema.d/. Main then split. Every regenerate path must keep that table or
# fail loudly; none may write schema.sql from main's fragments alone.
# s9_fixture <tag> — W: base (schema.sql only, no schema.d/), branch $BR adds
# `prebranch` to schema.sql, main splits and declares the Generated files row.
# origin/main points at main, as it does in a conductor worktree.
s9_fixture() {
  fresh "$1"
  mkdir -p "$W/docs/verification-map/index"
  git init -q -b main "$W"
  git -C "$W" config user.email t@t; git -C "$W" config user.name t; git -C "$W" config commit.gpgsign false
  git -C "$W" add -A -- bin worker/jobs/schema.sql; git -C "$W" commit -qm "base, before the split"
  git -C "$W" checkout -q -b "$BR"
  printf 'CREATE TABLE prebranch (id INTEGER PRIMARY KEY);\n' >> "$W/worker/jobs/schema.sql"
  git -C "$W" commit -qam "branch appends prebranch to schema.sql"
  git -C "$W" checkout -q main
  printf '%s\n' '# tail' '' '## Generated files' '' \
    '| path | regenerate with | committed |' '| --- | --- | --- |' "$ROW" \
    > "$W/docs/verification-map/index/tail.md"
  git -C "$W" add -A; git -C "$W" commit -qm "split: schema.d/ plus the Generated files row"
}
s9_kept() { grep -q 'CREATE TABLE prebranch ' "$W/worker/jobs/schema.sql"; }

# S9a the merge is clean; mc_regen_generated must not delete prebranch.
s9_fixture s9a
git -C "$W" update-ref refs/remotes/origin/main main
git -C "$W" checkout -q "$BR"
git -C "$W" merge -q --no-edit origin/main >/dev/null 2>&1 || bad "S9a merging main into the pre-split branch must be clean"
: > "$MC_LOG"
mc_regen_generated "$W" origin/main "s9a"
s9_kept && ok || bad "S9a mc_regen_generated must keep the branch's table in schema.sql: $(tail -3 "$W/worker/jobs/schema.sql")"
grep -q 'regenerate FAILED' "$MC_LOG" && grep -q prebranch "$MC_LOG" && ok \
  || bad "S9a the refused regenerate must be logged and name the statement: $(cat "$MC_LOG")"
run "$W" --check
[ "$RC" = 1 ] && grep -q 'CREATE TABLE prebranch' "$T/err" && ok \
  || bad "S9a --check must stay red and name prebranch, got $RC: $(cat "$T/err")"

# S9b main also gained a fragment, so schema.sql conflicts; the conductor's
# union keeps both blocks and the regenerate must still keep prebranch.
s9_fixture s9b
printf 'CREATE TABLE mainside (id INTEGER PRIMARY KEY);\n' > "$W/worker/jobs/schema.d/0001-mainside.sql"
run "$W" --write; git -C "$W" add -A; git -C "$W" commit -qm "main adds mainside"
git -C "$W" update-ref refs/remotes/origin/main main
git -C "$W" checkout -q "$BR"
git -C "$W" merge -q --no-edit origin/main >/dev/null 2>&1
if [ -n "$(git -C "$W" diff --name-only --diff-filter=U)" ]; then
  mc_resolve_conflicts "$W" "$BR" >/dev/null && git -C "$W" commit -q --no-edit >/dev/null 2>&1
fi
mc_regen_generated "$W" origin/main "s9b"
s9_kept && ok || bad "S9b after the conflict and the regenerate, prebranch must still be in schema.sql: $(cat "$W/worker/jobs/schema.sql")"

# S9c the batch-train shape: the union takes the INCOMING schema.sql on a
# conflict, so the working file already lost prebranch before --write runs.
# --write must find it in the branch's history and refuse.
s9_fixture s9c
git -C "$W" update-ref refs/remotes/origin/main main
git -C "$W" checkout -q -b post-split main
printf 'CREATE TABLE incoming (id INTEGER PRIMARY KEY);\n' > "$W/worker/jobs/schema.d/0001-incoming.sql"
run "$W" --write; git -C "$W" add -A; git -C "$W" commit -qm "post-split branch adds incoming"
git -C "$W" checkout -q -b union main
git -C "$W" merge -q --no-edit "$BR" >/dev/null 2>&1 || bad "S9c merging the pre-split branch into the union must be clean"
git -C "$W" merge -q --no-edit post-split >/dev/null 2>&1
git -C "$W" checkout --theirs -- worker/jobs/schema.sql && git -C "$W" add worker/jobs/schema.sql \
  && git -C "$W" commit -q --no-edit >/dev/null 2>&1 || bad "S9c the --theirs resolution must commit"
s9_kept && bad "S9c fixture: --theirs must have dropped prebranch from the working file" || ok
S9SUM=$(sum "$W/worker/jobs/schema.sql")
run "$W" --write
[ "$RC" = 1 ] && ok || bad "S9c --write must refuse when a branch commit added a statement no fragment holds, got $RC"
grep -q 'CREATE TABLE prebranch' "$T/err" && ok || bad "S9c the refusal must name prebranch: $(cat "$T/err")"
[ "$(sum "$W/worker/jobs/schema.sql")" = "$S9SUM" ] && ok || bad "S9c a refused --write must leave schema.sql untouched"

# S9d no false refusal: on a post-split branch, editing a committed fragment
# and re-rendering is the normal workflow, and so is a branch that deleted its
# own hand-added statement in a later commit.
s9_fixture s9d
git -C "$W" update-ref refs/remotes/origin/main main
sed -i 's/CREATE TABLE b (id INTEGER PRIMARY KEY);/CREATE TABLE b (id INTEGER PRIMARY KEY, note TEXT);/' "$W/worker/jobs/schema.d/0000-base.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S9d editing a committed fragment then --write must exit 0, got $RC: $(cat "$T/err")"
grep -q 'note TEXT' "$W/worker/jobs/schema.sql" && ok || bad "S9d the edited statement must be rendered"
git -C "$W" checkout -q -- .
git -C "$W" checkout -q "$BR"
sed -i '/CREATE TABLE prebranch /d' "$W/worker/jobs/schema.sql"
git -C "$W" commit -qam "branch drops its own table again"
git -C "$W" merge -q --no-edit origin/main >/dev/null 2>&1 || bad "S9d merging main must be clean"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S9d a statement the branch itself removed must not block --write, got $RC: $(cat "$T/err")"

# =============================================================================
# S10 the edit loop is not a lost statement (BH-4987 lead review r3).
# =============================================================================
fresh s10
git -C "$W" init -q && git -C "$W" add -A && git -C "$W" -c user.email=fixture@example.invalid -c user.name=fixture commit -qm base
SCH="$W/worker/jobs/schema.sql"
printf 'CREATE TABLE n (id INTEGER);\n' > "$W/worker/jobs/schema.d/0001-n.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S10 --write of a new uncommitted fragment must exit 0, got $RC: $(cat "$T/err")"
printf 'CREATE TABLE n (id INTEGER, note TEXT);\n' > "$W/worker/jobs/schema.d/0001-n.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S10 editing that fragment again and --write must exit 0 (the old text is our own render), got $RC: $(cat "$T/err")"
[ "$(grep -c 'CREATE TABLE n ' "$SCH")" = 1 ] && grep -q 'note TEXT' "$SCH" && ok \
  || bad "S10 schema.sql must hold exactly one CREATE TABLE n, the edited one: $(grep 'TABLE n ' "$SCH")"
# A committed base fragment edited twice before a commit.
sed -i 's/CREATE TABLE b (id INTEGER PRIMARY KEY);/CREATE TABLE b (id INTEGER PRIMARY KEY, x TEXT);/' "$W/worker/jobs/schema.d/0000-base.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S10 first edit of a committed fragment must exit 0, got $RC: $(cat "$T/err")"
sed -i 's/x TEXT);/x TEXT, y TEXT);/' "$W/worker/jobs/schema.d/0000-base.sql"
run "$W" --write
[ "$RC" = 0 ] && ok || bad "S10 second edit of a committed fragment must exit 0, got $RC: $(cat "$T/err")"
grep -q 'x TEXT, y TEXT' "$SCH" && ok || bad "S10 the second edit must be rendered"
run "$W" --check
[ "$RC" = 0 ] && ok || bad "S10 --check must be green after the edit loop, got $RC: $(cat "$T/err")"
# The guard still holds: a hand edit after a --write is refused.
printf 'CREATE TABLE sneaky2 (id INTEGER);\n' >> "$SCH"
S10SUM=$(sum "$SCH")
run "$W" --write
[ "$RC" = 1 ] && ok || bad "S10 a hand edit after a --write must still be refused, got $RC"
[ "$(sum "$SCH")" = "$S10SUM" ] && ok || bad "S10 a refused --write must leave schema.sql untouched"
grep -q 'CREATE TABLE sneaky2' "$T/err" && grep -q 'edit that fragment' "$T/err" && ok \
  || bad "S10 the refusal must name the statement and say to edit the fragment that holds an older text: $(cat "$T/err")"

echo "schema-fragments.bh-4987: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
