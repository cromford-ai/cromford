#!/bin/bash
# tests/schema-fragment-lint.bh-5788-test.sh — a new table goes in a NEW
# worker/<w>/schema.d/ fragment, never in one that already exists (BH-5788 A).
#
# The builtin rp_schema_fragment (bin/lib/rules-pack-checks.sh) diffs the
# working tree against a base and reports each added CREATE [TEMP|TEMPORARY|
# VIRTUAL] TABLE line in a schema.d/*.sql file that exists at the base.
#   A1  CREATE TABLE added to an existing fragment: one finding, path and line;
#       lower case, TEMP, VIRTUAL and IF NOT EXISTS forms are findings too
#   A2  the same line in a NEW fragment (NNNN or stamp-key name): clean
#   A3  a `-- CREATE TABLE` comment: clean
#   A4  CREATE INDEX, INSERT OR IGNORE, ALTER TABLE, CREATE TABLEX, a removed
#       CREATE TABLE line: clean
#   A5  a worker with no schema.d/ (worker/other/schema.sql): not scanned
#   A6  the catalog row exists, and the real bin/rules-pack.sh runs it: green on
#       a clean diff, red with the finding on the A1 diff
#   A7  no base, or a base that does not resolve: rc 125 (could not run)
# Fixture repos only, fixed commit dates. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-fragment-lint.bh-5788-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }
command -v rp_schema_fragment >/dev/null 2>&1 || bad "rp_schema_fragment is not defined in bin/lib/rules-pack-checks.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
FRAG=worker/jobs/schema.d/0000-base.sql
MSG='schema-fragment: a new table goes in a new schema.d fragment'

# fixture <tag> — a repo with one committed fragment and a worker without
# schema.d/. Sets R (the tree) and BASE (its base commit).
fixture() {
  R="$T/$1"; scratch_rm "$R"; mkdir -p "$R/worker/jobs/schema.d" "$R/worker/other"
  printf '%s\n' 'CREATE TABLE probe_a (id INTEGER PRIMARY KEY);' \
                'CREATE TABLE probe_b (id INTEGER PRIMARY KEY);' > "$R/$FRAG"
  printf '%s\n' 'CREATE TABLE probe_cloud (id INTEGER);' > "$R/worker/other/schema.sql"
  git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
# lint — rp_schema_fragment on the fixture; sets RC and OUT.
lint() { OUT=$(rp_schema_fragment "$R" "$BASE" 2>"$T/err"); RC=$?; }

# ── A1 a CREATE TABLE added to an existing fragment ───────────────────────────
fixture a1
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY);' >> "$R/$FRAG"
lint
[ "$RC" = 1 ] && ok || bad "A1 rc $RC (want 1): $OUT $(cat "$T/err")"
[ "$OUT" = "$FRAG:3: $MSG" ] && ok || bad "A1 finding [$OUT] (want [$FRAG:3: $MSG])"
for l in '  create temp table probe_tt (id INTEGER);' \
         'CREATE VIRTUAL TABLE probe_v USING fts5(x);' \
         'CREATE TABLE IF NOT EXISTS probe_i (id INTEGER);' \
         'CREATE TEMPORARY TABLE probe_tmp (id INTEGER);'; do
  fixture a1x
  printf '%s\n' "$l" >> "$R/$FRAG"
  lint
  [ "$RC" = 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" = 1 ] && [ "$OUT" = "$FRAG:3: $MSG" ] && ok \
    || bad "A1 [$l] rc $RC out [$OUT] (want one finding at line 3)"
done
# The line number is the NEW side's line, not the count of added lines.
fixture a1m
{ printf '%s\n' '-- header'; cat "$R/$FRAG"; printf '%s\n' '' 'CREATE TABLE probe_m (id INTEGER);'; } > "$T/m.sql"
cat "$T/m.sql" > "$R/$FRAG"
lint
[ "$RC" = 1 ] && [ "$OUT" = "$FRAG:5: $MSG" ] && ok || bad "A1 line number after an earlier hunk: [$OUT] (want line 5)"

# A removed `-- comment` reads `--- comment` in the diff; it is not a file header.
fixture a1c
printf '%s\n' '-- probe note' >> "$R/$FRAG"; git -C "$R" commit -qam note; BASE=$(git -C "$R" rev-parse HEAD)
sed -i 's/^-- probe note$/-- probe note, edited/' "$R/$FRAG"
printf '%s\n' 'CREATE TABLE probe_c (id INTEGER);' >> "$R/$FRAG"
lint
[ "$RC" = 1 ] && [ "$OUT" = "$FRAG:4: $MSG" ] && ok || bad "A1 after a removed comment line: rc $RC [$OUT] (want line 4)"

# ── A2 the same line in a NEW fragment ────────────────────────────────────────
fixture a2
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY);' > "$R/worker/jobs/schema.d/0001-probe.sql"
git -C "$R" add -A
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A2 a new fragment must be clean, rc $RC out [$OUT]"
fixture a2s
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY);' > "$R/worker/jobs/schema.d/202610140000-bh-1-t.sql"
git -C "$R" add -A
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A2 a new stamp-key fragment must be clean, rc $RC out [$OUT]"
# Untracked (not yet added) is the same answer: the file is not at the base.
fixture a2u
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY);' > "$R/worker/jobs/schema.d/0001-probe.sql"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A2 an untracked new fragment must be clean, rc $RC out [$OUT]"

# ── A3 a comment ──────────────────────────────────────────────────────────────
fixture a3
printf '%s\n' '-- CREATE TABLE probe_t (id INTEGER);' >> "$R/$FRAG"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A3 a -- comment must be clean, rc $RC out [$OUT]"

# ── A4 statements that are not a new table ────────────────────────────────────
fixture a4
printf '%s\n' 'CREATE INDEX probe_ix ON probe_a(id);' \
              "INSERT OR IGNORE INTO probe_a (id) VALUES (1);" \
              'ALTER TABLE probe_a ADD COLUMN note TEXT;' \
              'CREATE TABLEX probe_x;' \
              "INSERT INTO probe_a (note) VALUES ('CREATE TABLE in a string');" >> "$R/$FRAG"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A4 index/insert/alter/TABLEX must be clean, rc $RC out [$OUT]"
fixture a4d
sed -i '/probe_b/d' "$R/$FRAG"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A4 a removed CREATE TABLE line must be clean, rc $RC out [$OUT]"

# ── A5 a worker with no schema.d/ ─────────────────────────────────────────────
fixture a5
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER);' >> "$R/worker/other/schema.sql"
lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "A5 worker/other/schema.sql is not scanned, rc $RC out [$OUT]"

# ── A7 no base, or a base that does not resolve: could not run ───────────────
OUT=$(rp_schema_fragment "$R" "" 2>/dev/null); RC=$?
[ "$RC" = 125 ] && ok || bad "A7 no base must be rc 125, got $RC"
OUT=$(rp_schema_fragment "$R" 0000000000000000000000000000000000000001 2>/dev/null); RC=$?
[ "$RC" = 125 ] && [ -z "$OUT" ] && ok || bad "A7 an unresolvable base must be rc 125, got $RC [$OUT]"

# ── A6 the catalog row, and the real pack ─────────────────────────────────────
N=$(grep -c $'^schema-fragment\tdelta\tbuiltin\trp_schema_fragment\t' "$DIR/catalog/rules-pack.tsv")
[ "$N" = 1 ] && ok || bad "A6 catalog/rules-pack.tsv must carry one schema-fragment delta builtin row (got $N)"
pack() { # pack <outdir> — the real pack, local runner, this component only
  env HARNESS="$T/nolg" bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$BASE" --runner local \
    --out "$T/$1" --only schema-fragment >"$T/pack.out" 2>"$T/pack.err"; RC=$?
}
mkdir -p "$T/nolg"
fixture a6c
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER);' > "$R/worker/jobs/schema.d/0001-probe.sql"
git -C "$R" add -A; git -C "$R" commit -qm clean
pack o6c
[ "$RC" = 0 ] && [ ! -s "$T/pack.out" ] && ok || bad "A6 clean diff: pack rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"
fixture a6r
printf '%s\n' 'CREATE TABLE probe_t (id INTEGER PRIMARY KEY);' >> "$R/$FRAG"
git -C "$R" commit -qam red
pack o6r
[ "$RC" = 1 ] && ok || bad "A6 the A1 diff: pack rc $RC (want 1), err [$(tail -3 "$T/pack.err")]"
[ "$(cat "$T/pack.out")" = "schema-fragment: $FRAG:3: $MSG" ] && ok \
  || bad "A6 pack stdout [$(cat "$T/pack.out")] (want [schema-fragment: $FRAG:3: $MSG])"

echo "schema-fragment-lint.bh-5788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
