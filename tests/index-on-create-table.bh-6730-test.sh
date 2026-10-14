#!/bin/bash
# tests/index-on-create-table.bh-6730-test.sh — BH-6730, the index iron law as a
# rules-pack component. A diff that adds a table gets a BLOCK naming the law.
#
# WHY. The harness-jobs D1 lesson (#6727): tables of 25k-206k rows read
# 100-160M rows an hour and D1 answered "overloaded" 875 times in 5 hours.
# Every new table ships with the indexes its queries need (rules/CLAUDE.md).
#
# The builtin rp_index_on_create_table (bin/lib/rules-pack-checks.sh) reads the
# `+` lines of `git diff <base>` over *.sql. The lead review runs the rules
# pack first, and a red pack is a BLOCK whose findings are the pack's lines
# with no agent call (bin/lead-review.sh; pinned by
# tests/lead-review-rules-pack.bh-3546-test.sh R4). So the finding line below
# is the BLOCK the lead review posts.
#   X1  a new table with no index: rc 1, one finding with path, line, table and
#       the law; quoted and IF NOT EXISTS forms are findings too
#   X2  a CREATE INDEX ... ON the table, in the same file or another .sql file
#       of the diff: clean; CREATE UNIQUE INDEX IF NOT EXISTS counts too
#   X3  `-- no-index: <table> <reason>`: clean; the marker without a reason, or
#       for another table: still a finding
#   X4  TEMP, TEMPORARY and VIRTUAL tables, a commented CREATE TABLE, and a
#       table only the base has: clean
#   X5  no base, or a base that does not resolve: rc 125
#   X6  the catalog row exists, and the REAL bin/rules-pack.sh is red on a
#       no-index table with the finding line, green when the index is added
# Fixture repos only, fixed commit dates. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/index-on-create-table.bh-6730-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }
command -v rp_index_on_create_table >/dev/null 2>&1 || bad "rp_index_on_create_table is not defined in bin/lib/rules-pack-checks.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
NEW=worker/jobs/schema.d/0100-probe.sql
LAW='iron law, BH-6730: every new table ships with the indexes its queries need'

# fixture <tag> — a repo with one committed fragment holding probe_old. Sets R and BASE.
fixture() {
  R="$T/$1"; scratch_rm "$R"; mkdir -p "$R/worker/jobs/schema.d"
  printf '%s\n' 'CREATE TABLE probe_old (id INTEGER PRIMARY KEY, k TEXT);' \
                'CREATE INDEX probe_old_k ON probe_old (k);' > "$R/worker/jobs/schema.d/0000-base.sql"
  git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
lint() { OUT=$(rp_index_on_create_table "$R" "$BASE" 2>"$T/err"); RC=$?; }
# add <line>... — write the new fragment and stage it (git diff <base> does not see
# an untracked file; in a real PR the change is committed).
add() { printf '%s\n' "$@" > "$R/$NEW"; git -C "$R" add -A; }

# ── X1 a new table with no index ──────────────────────────────────────────────
fixture x1; add 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY, seen_at INTEGER);'
lint
[ "$RC" = 1 ] && ok || bad "X1 rc $RC (want 1): $OUT"
[ "$OUT" = "$NEW:1: index-on-create-table: table probe_t has no CREATE INDEX in this diff ($LAW; a handful-of-rows table carries -- no-index: probe_t <reason>)" ] \
  && ok || bad "X1 finding [$OUT]"
for l in 'CREATE TABLE IF NOT EXISTS probe_t (id INTEGER);' 'create table "probe_t" (id integer);' 'CREATE TABLE main.probe_t (id INTEGER);'; do
  fixture x1b; add "$l"; lint
  [ "$RC" = 1 ] && grep -q 'table probe_t has no CREATE INDEX' <<<"$OUT" && ok || bad "X1 form [$l]: rc $RC [$OUT]"
done
fixture x1c; add 'CREATE TABLE probe_a (id INTEGER);' 'CREATE TABLE probe_b (id INTEGER);' 'CREATE INDEX probe_a_id ON probe_a (id);'
lint
[ "$RC" = 1 ] && [ "$(grep -c . <<<"$OUT")" = 1 ] && grep -q 'table probe_b ' <<<"$OUT" && ok || bad "X1 two tables, one indexed: [$OUT]"

# ── X2 an index in the diff ───────────────────────────────────────────────────
fixture x2; add 'CREATE TABLE probe_t (id INTEGER, seen_at INTEGER);' 'CREATE INDEX IF NOT EXISTS probe_t_seen ON probe_t (seen_at);'
lint; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "X2 same file: rc $RC [$OUT]"
fixture x2b; add 'CREATE TABLE probe_t (id INTEGER, k TEXT);'
printf '%s\n' 'CREATE UNIQUE INDEX IF NOT EXISTS probe_t_k ON "probe_t" (k);' > "$R/worker/jobs/schema.d/0101-probe-idx.sql"
git -C "$R" add -A
lint; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "X2 another file, unique, quoted: rc $RC [$OUT]"

# ── X3 the no-index marker ────────────────────────────────────────────────────
fixture x3; add '-- no-index: probe_t three rows, one per lane class, read whole' 'CREATE TABLE probe_t (id INTEGER);'
lint; [ "$RC" = 0 ] && ok || bad "X3 marker with reason: rc $RC [$OUT]"
fixture x3b; add '-- no-index: probe_t' 'CREATE TABLE probe_t (id INTEGER);'
lint; [ "$RC" = 1 ] && ok || bad "X3 marker with no reason must not clear it: rc $RC"
fixture x3c; add '-- no-index: probe_other small' 'CREATE TABLE probe_t (id INTEGER);'
lint; [ "$RC" = 1 ] && ok || bad "X3 a marker for another table must not clear it: rc $RC"

# ── X4 not a new table ────────────────────────────────────────────────────────
for l in 'CREATE TEMP TABLE probe_t (id INTEGER);' 'CREATE TEMPORARY TABLE probe_t (id INTEGER);' \
         'CREATE VIRTUAL TABLE probe_t USING fts5(x);' '-- CREATE TABLE probe_t (id INTEGER);' \
         'ALTER TABLE probe_old ADD COLUMN v TEXT;'; do
  fixture x4; add "$l"; lint
  [ "$RC" = 0 ] && ok || bad "X4 [$l]: rc $RC [$OUT]"
done

# ── X5 could not run ──────────────────────────────────────────────────────────
fixture x5
rp_index_on_create_table "$R" "" >/dev/null 2>&1; [ "$?" = 125 ] && ok || bad "X5 no base must be rc 125"
rp_index_on_create_table "$R" deadbeefdeadbeef >/dev/null 2>&1; [ "$?" = 125 ] && ok || bad "X5 a bad base must be rc 125"

# ── X6 the catalog row and the real pack ──────────────────────────────────────
N=$(grep -c $'^index-on-create-table\tdelta\tbuiltin\trp_index_on_create_table\t' "$DIR/catalog/rules-pack.tsv")
[ "$N" = 1 ] && ok || bad "X6 catalog/rules-pack.tsv must carry one index-on-create-table delta builtin row (got $N)"
mkdir -p "$T/nolg"
pack() { env HARNESS="$T/nolg" bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$BASE" --runner local \
    --out "$T/$1" --only index-on-create-table >"$T/pack.out" 2>"$T/pack.err"; RC=$?; }
fixture x6r; add 'CREATE TABLE probe_t (id INTEGER, seen_at INTEGER);'
git -C "$R" add -A; git -C "$R" commit -qm red
pack o6r
[ "$RC" = 1 ] && grep -qF "index-on-create-table: $NEW:1: index-on-create-table: table probe_t has no CREATE INDEX" "$T/pack.out" \
  && grep -qF "$LAW" "$T/pack.out" && ok || bad "X6 red: pack rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"
fixture x6g; add 'CREATE TABLE probe_t (id INTEGER, seen_at INTEGER);' 'CREATE INDEX probe_t_seen ON probe_t (seen_at);'
git -C "$R" add -A; git -C "$R" commit -qm green
pack o6g
[ "$RC" = 0 ] && [ ! -s "$T/pack.out" ] && ok || bad "X6 green: pack rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"

echo "index-on-create-table.bh-6730: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
