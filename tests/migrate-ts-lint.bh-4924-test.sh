#!/bin/bash
# tests/migrate-ts-lint.bh-4924-test.sh — BH-4924 (BH-4920.1): the appliability
# classifier lints the literal DDL inside a scripts/migrate-*.ts migration.
#   E1-E6   bin/lib/migrate-ts-ddl.sh's mtd_extract, line by line
#   C1-C19  the REAL bin/check-migration-appliable.sh over .ts fixtures
#   P1-P2   the .sql path: byte-identical to the base, .ts allowances stay .ts-only
# Run from anywhere: tests/migrate-ts-lint.bh-4924-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1"; }
command -v perl >/dev/null || { echo "perl missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/migrate-ts-ddl.sh"
CLS="$DIR/bin/check-migration-appliable.sh"
[ -r "$LIB" ] && ok || bad "D41: $LIB is missing"

M="$T/m"; mkdir -p "$M/scripts"
fx() { printf '%s\n' "${@:2}" > "$M/scripts/$1"; }
# ext <file> — mtd_extract's stdout, in a subshell that sources the real lib
ext() { ( . "$LIB" 2>/dev/null || exit 9; mtd_extract "$M/scripts/$1" ); }
# eq <label> <want> <got>
eq() { [ "$2" = "$3" ] && ok || bad "$1"$'\n'"want: $2"$'\n'"got:  $3"; }
# cls <file...> — run the real classifier, sets OUT and RC
cls() { OUT=$("$CLS" p "$M" "${@/#/$M/scripts/}" 2>&1); RC=$?; }

# --- E1: one fixture per call shape ------------------------------------------
fx e1a.ts "await client.execute('CREATE INDEX IF NOT EXISTS i ON t(a)');"
fx e1b.ts 'await client.executeMultiple("ALTER TABLE t ADD COLUMN a TEXT");'
fx e1c.ts 'await prisma.$executeRawUnsafe(`ALTER TABLE t ADD COLUMN b TEXT`);'
fx e1d.ts 'await prisma.$executeRaw`ALTER TABLE t ADD COLUMN c TEXT`;'
fx e1e.ts 'await db.execute(sql`CREATE TABLE IF NOT EXISTS x (id TEXT)`);'
fx e1f.ts 'db.run("ALTER TABLE t ADD COLUMN d INTEGER");'
eq "E1 .execute('…')"        "CREATE INDEX IF NOT EXISTS i ON t(a)"   "$(ext e1a.ts)"
eq "E1 .executeMultiple(\"…\")" "ALTER TABLE t ADD COLUMN a TEXT"      "$(ext e1b.ts)"
eq "E1 \$executeRawUnsafe(\`…\`)" "ALTER TABLE t ADD COLUMN b TEXT"    "$(ext e1c.ts)"
eq "E1 \$executeRaw\`…\`"     "ALTER TABLE t ADD COLUMN c TEXT"        "$(ext e1d.ts)"
eq "E1 sql\`…\`"              "CREATE TABLE IF NOT EXISTS x (id TEXT)" "$(ext e1e.ts)"
eq "E1 db.run(\"…\")"         "ALTER TABLE t ADD COLUMN d INTEGER"     "$(ext e1f.ts)"

# --- E2: comments stripped, a // inside a string survives ----------------------
fx e2.ts \
  '// await client.execute("DROP TABLE x");' \
  '/* await client.execute("DROP TABLE y");' \
  '   still commented */' \
  'console.log("see https://x//y");' \
  'await client.execute("ALTER TABLE t ADD COLUMN e TEXT"); // trailing note'
eq "E2 comments stripped" "ALTER TABLE t ADD COLUMN e TEXT" "$(ext e2.ts)"
fx e2b.ts 'await client.execute("INSERT INTO log (u) SELECT '"'"'https://x//y'"'"' WHERE NOT EXISTS (SELECT 1 FROM log)");'
eq "E2 // inside a SQL literal survives" "INSERT INTO log (u) SELECT 'https://x//y' WHERE NOT EXISTS (SELECT 1 FROM log)" "$(ext e2b.ts)"

# --- E3: executeMultiple with two statements, multi-line -------------------------
fx e3.ts 'await client.executeMultiple(`' \
  '  ALTER TABLE t ADD COLUMN f TEXT;' \
  '  CREATE INDEX IF NOT EXISTS i2 ON t(f);' \
  '`);'
eq "E3 two statements" $'ALTER TABLE t ADD COLUMN f TEXT\nCREATE INDEX IF NOT EXISTS i2 ON t(f)' "$(ext e3.ts)"

# --- E4-E6: COMPUTED -------------------------------------------------------------
fx e4.ts 'await client.execute(`ALTER TABLE ${table} ADD COLUMN x TEXT`);'
eq "E4 interpolation" "COMPUTED template interpolation" "$(ext e4.ts)"
fx e5.ts 'await client.execute("ALTER TABLE " + t + " ADD COLUMN x TEXT");'
eq "E5 concatenation" "COMPUTED string concatenation" "$(ext e5.ts)"
fx e6a.ts 'await client.execute(q);'
eq "E6 identifier arg" "COMPUTED non-literal first argument" "$(ext e6a.ts)"
fx e6b.ts 'await client.execute({ sql: "ALTER TABLE t ADD COLUMN x TEXT", args: [] });'
eq "E6 object arg" "COMPUTED non-literal first argument" "$(ext e6b.ts)"
fx e6c.ts 'import { createClient } from "@libsql/client";' 'console.log("nothing to do");'
eq "E6 no SQL" "COMPUTED no literal SQL found" "$(ext e6c.ts)"
fx e6d.ts 'await prisma.client.deleteMany({});'
case "$(ext e6d.ts)" in *"COMPUTED ORM write deleteMany()"*) ok ;; *) bad "E6 ORM write: $(ext e6d.ts)" ;; esac
( . "$LIB" 2>/dev/null || exit 9; mtd_extract "$M/scripts/nope.ts" >/dev/null 2>&1 ); [ $? = 2 ] && ok || bad "E6 unreadable file is rc 2"

# --- C1: the TK-32 shape ---------------------------------------------------------
fx migrate-client-redtail-status.ts \
  'import { createClient } from "@libsql/client";' \
  'const client = createClient({ url: process.env.TURSO_DATABASE_URL!, authToken: process.env.TURSO_AUTH_TOKEN });' \
  'async function main() {' \
  '  const info = await client.execute('"'"'PRAGMA table_info("Client")'"'"');' \
  '  const cols = info.rows.map((r) => String(r.name));' \
  '  if (!cols.includes("redtailStatus")) {' \
  '    await client.execute('"'"'ALTER TABLE "Client" ADD COLUMN "redtailStatus" TEXT'"'"');' \
  '  }' \
  '  if (!cols.includes("redtailSyncedAt")) {' \
  '    await client.execute('"'"'ALTER TABLE "Client" ADD COLUMN "redtailSyncedAt" DATETIME'"'"');' \
  '  }' \
  '  await client.execute('"'"'CREATE INDEX IF NOT EXISTS "Client_redtailStatus_idx" ON "Client"("redtailStatus")'"'"');' \
  '  console.log("done");' \
  '}' \
  'main().catch((e) => { console.error(e); process.exit(1); });'
cls migrate-client-redtail-status.ts
[ "$RC" = 0 ] && ok || bad "C1 TK-32 shape exits 0 (rc $RC): $OUT"
n=$(grep -cE ': allowed: (ALTER TABLE "Client" ADD COLUMN "redtail(Status|SyncedAt)"|CREATE INDEX IF NOT EXISTS "Client_redtailStatus_idx")' <<< "$OUT")
[ "$n" = 3 ] && ok || bad "C1 three DDL statements printed as allowed (got $n): $OUT"
grep -q ': allowed: PRAGMA table_info("Client")' <<< "$OUT" && ok || bad "C1 PRAGMA table_info allowed: $OUT"
grep -q FLAGGED <<< "$OUT" && bad "C1 nothing FLAGGED: $OUT" || ok

# --- C2-C12: flag / pass per statement --------------------------------------------
# want <label> <rc> <needle> <statement>
WN=0
want() {
  WN=$((WN+1)); local f="c-want-$WN.ts"
  printf 'await client.execute(%s);\n' "$4" > "$M/scripts/$f"
  cls "$f"
  [ "$RC" = "$2" ] && ok || bad "$1 rc $RC, want $2: $OUT"
  [ -z "$3" ] || { grep -qF -- "$3" <<< "$OUT" && ok || bad "$1 output lacks '$3': $OUT"; }
}
want C2  1 "FLAGGED (data rewrite"          "'UPDATE \"Client\" SET x=1'"
want C3  1 "FLAGGED (ALTER TABLE action"    "'ALTER TABLE \"Client\" DROP COLUMN x'"
want C4  1 "FLAGGED (ALTER TABLE action"    "'ALTER TABLE \"Client\" RENAME TO c2'"
want C4b 1 "FLAGGED (ALTER TABLE action"    "'ALTER TABLE \"Client\" RENAME COLUMN a TO b'"
want C5  1 "FLAGGED (computed SQL — never auto-applied): template interpolation" '`ALTER TABLE ${table} ADD COLUMN x TEXT`'
want C6  1 "FLAGGED (computed SQL — never auto-applied): string concatenation"   '"ALTER TABLE " + t + " ADD COLUMN x TEXT"'
want C6b 1 "computed SQL"                   "q"
want C6c 1 "computed SQL"                   '{ sql: "ALTER TABLE t ADD COLUMN x TEXT" }'
want C7  1 "FLAGGED"                        "'INSERT INTO t (id, a) VALUES (1, 2) ON CONFLICT(id) DO UPDATE SET a = 2'"
want C8  1 "not idempotent"                 "'INSERT INTO t VALUES (1)'"
want C9  1 "FLAGGED (destructive statement" "'DELETE FROM t'"
want C10 0 "allowed: INSERT"                "'INSERT INTO t (id) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM t WHERE id = 1)'"
want C11 0 "allowed: INSERT"                "'INSERT INTO t (id) VALUES (1) ON CONFLICT DO NOTHING'"
want C11b 0 "allowed: INSERT"               "'INSERT INTO t (id) VALUES (1) ON CONFLICT (id) DO NOTHING'"
want C12 0 "allowed: INSERT OR IGNORE"      "'INSERT OR IGNORE INTO t (id) VALUES (1)'"
want C12b 1 "FLAGGED"                       "'INSERT OR REPLACE INTO t (id) VALUES (1)'"
want C12c 1 "FLAGGED"                       "'PRAGMA writable_schema = 1'"
want C12d 1 "FLAGGED"                       "'PRAGMA foreign_keys = OFF'"

# C9a: the DELETE only in comments, a safe ALTER live
fx c9a.ts '// await client.execute("DELETE FROM t");' '/* await client.execute("DELETE FROM t"); */' \
  'await client.execute("ALTER TABLE t ADD COLUMN g TEXT");'
cls c9a.ts
[ "$RC" = 0 ] && ok || bad "C9a commented-out DELETE does not count (rc $RC): $OUT"
# ORM write and a file with no SQL both flag
fx c-orm.ts 'await prisma.client.deleteMany({});' 'await client.execute("CREATE INDEX IF NOT EXISTS i ON t(a)");'
cls c-orm.ts
[ "$RC" = 1 ] && grep -q 'computed SQL — never auto-applied): ORM write deleteMany()' <<< "$OUT" && ok || bad "C ORM write flags (rc $RC): $OUT"
fx c-none.ts 'console.log("hi");'
cls c-none.ts
[ "$RC" = 1 ] && grep -q 'no literal SQL found' <<< "$OUT" && ok || bad "C no-SQL .ts flags (rc $RC): $OUT"
# --- C16-C18: write sinks outside the first call list (review F1) ---------------
# Each file pairs a safe ALTER with one write through another sink; the write
# must FLAG, so a recognised call elsewhere in the file can never hide it.
SAFE='await client.execute("ALTER TABLE t ADD COLUMN a TEXT");'
# sink <label> <needle> <second line>
sink() {
  local f="c-sink-$1.ts"; fx "$f" "$SAFE" "$3"
  cls "$f"
  [ "$RC" = 1 ] && grep -qF -- "$2" <<< "$OUT" && ok || bad "$1 flags (rc $RC): $OUT"
}
sink C16a 'FLAGGED (destructive statement — never auto-merged): DELETE FROM t' 'await prisma.$queryRawUnsafe("DELETE FROM t");'
sink C16b 'FLAGGED (destructive statement — never auto-merged): DELETE FROM t' 'await prisma.$queryRaw`DELETE FROM t`;'
sink C16c 'FLAGGED (destructive statement — never auto-merged): DELETE FROM t' 'await prisma.$queryRaw("DELETE FROM t");'
sink C16d 'computed SQL — never auto-applied): non-literal first argument' 'await client.migrate(["DROP TABLE t"]);'
# backstop: a write literal no recognised call consumed
sink C17a 'computed SQL — never auto-applied): SQL literal outside a recognised call site' "const q = 'DELETE FROM t'; await run(q);"
sink C17b 'computed SQL — never auto-applied): SQL literal outside a recognised call site' 'await client.execute("ALTER TABLE t ADD COLUMN b TEXT", [await helper("DROP TABLE t")]);'
sink C17c 'computed SQL — never auto-applied): SQL literal outside a recognised call site' 'await prisma.$unknownSink(`UPDATE "Client" SET a = 1`);'
# a log line that merely mentions a verb is not SQL
fx c17d.ts "$SAFE" 'console.log("Updated the table, created the index, deleted nothing");'
cls c17d.ts
[ "$RC" = 0 ] && ok || bad "C17d a prose log line does not flag (rc $RC): $OUT"
# C18: a quote inside a regex literal does not desync the comment strip
fx c18.ts 'const re = /"/;' "$SAFE" 'const u = "/*";' 'await client.execute("DELETE FROM t");' 'const v = "*/";'
cls c18.ts
[ "$RC" = 1 ] && grep -qF 'FLAGGED (destructive statement — never auto-merged): DELETE FROM t' <<< "$OUT" && ok || bad "C18 regex quote cannot swallow a live DELETE (rc $RC): $OUT"
fx c18b.ts "const re = /[\"']+/g, d = a / b;" "$SAFE"
cls c18b.ts
[ "$RC" = 0 ] && ok || bad "C18b a regex literal and a division still lint clean (rc $RC): $OUT"
# C19: PRAGMA table_info with a single-quoted table (review F2)
fx c19.ts "await client.execute(\"PRAGMA table_info('Client')\");" "$SAFE"
cls c19.ts
[ "$RC" = 0 ] && grep -qF ": allowed: PRAGMA table_info('Client')" <<< "$OUT" && ok || bad "C19 single-quoted PRAGMA table_info allowed (rc $RC): $OUT"
want C19b 1 "FLAGGED"                       "\"PRAGMA table_info('Client') ; PRAGMA foreign_keys = OFF\""
want C19c 1 "FLAGGED"                       "\"PRAGMA table_info('Client\\\")\""
# unreadable .ts
OUT=$("$CLS" p "$M" scripts/migrate-gone.ts 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q 'migrate-gone.ts: FLAGGED (file unreadable)' <<< "$OUT" && ok || bad "C unreadable .ts flags (rc $RC): $OUT"
# mixed list, argument order
printf 'ALTER TABLE t ADD COLUMN h TEXT;\n' > "$M/scripts/ok.sql"
fx c2-upd.ts "await client.execute('UPDATE t SET a = 1');"
cls ok.sql c2-upd.ts
[ "$RC" = 1 ] && grep -q 'c2-upd.ts: FLAGGED (data rewrite' <<< "$OUT" && ok || bad "C mixed .sql+.ts list flags the .ts (rc $RC): $OUT"

# --- C13: default-list mode picks up an added scripts/migrate-*.ts ----------------
G() { git -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
R="$T/repo"; G init -q -b main "$R" && echo base > "$R/README" && G -C "$R" add -A && G -C "$R" commit -qm base
G -C "$R" checkout -qb pr; mkdir -p "$R/scripts"
printf 'await client.execute("UPDATE t SET a = 1");\n' > "$R/scripts/migrate-x.ts"
G -C "$R" add -A && G -C "$R" commit -qm "add ts migration"
OUT=$("$CLS" p "$R" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q '^scripts/migrate-x.ts: FLAGGED (data rewrite' <<< "$OUT" && ok || bad "C13 default list lints the added .ts (rc $RC): $OUT"

# --- C14: the data lane's call shape, closure-installed ---------------------------
H="$T/h"
scratch_install_closure bin/check-migration-appliable.sh "$H" > "$T/closure.txt" || bad "C14 closure install"
grep -qx 'bin/lib/migrate-ts-ddl.sh' "$T/closure.txt" && ok || bad "C14 the closure carries bin/lib/migrate-ts-ddl.sh: $(tr '\n' ' ' < "$T/closure.txt")"
TMP="$T/dl"; mkdir -p "$TMP/m/scripts"
cp "$M/scripts/migrate-client-redtail-status.ts" "$TMP/m/scripts/migrate-x.ts"
"$H/bin/check-migration-appliable.sh" p "$TMP/m" "$TMP/m/scripts/migrate-x.ts" > "$TMP/classify" 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C14 data-lane call shape passes the TK-32 .ts (rc $RC): $(cat "$TMP/classify")"
cp "$M/scripts/e4.ts" "$TMP/m/scripts/migrate-x.ts"
"$H/bin/check-migration-appliable.sh" p "$TMP/m" "$TMP/m/scripts/migrate-x.ts" > "$TMP/classify" 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "C14 data-lane call shape flags an interpolated .ts (rc $RC): $(cat "$TMP/classify")"

# --- C15: classifier copied alone (no lib beside it) ------------------------------
L="$T/lone"; mkdir -p "$L/bin"; cp "$CLS" "$L/bin/"
OUT=$("$L/bin/check-migration-appliable.sh" p "$M" "$M/scripts/migrate-client-redtail-status.ts" 2>&1); RC=$?
[ "$RC" = 1 ] && grep -q 'ts extractor unavailable' <<< "$OUT" && ok || bad "C15 .ts without the lib flags (rc $RC): $OUT"
OUT=$("$L/bin/check-migration-appliable.sh" p "$M" "$M/scripts/ok.sql" 2>&1); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "C15 .sql without the lib still lints (rc $RC): $OUT"

# --- P1: .sql byte parity with the base classifier --------------------------------
S="$T/sql"; mkdir -p "$S"
printf 'ALTER TABLE "C" ADD COLUMN "a" TEXT;\nCREATE INDEX i ON "C"("a");\n' > "$S/1-add.sql"
printf 'DO $$ BEGIN IF NOT EXISTS (SELECT 1) THEN ALTER TABLE x ADD COLUMN y TEXT; END IF; END $$;\n' > "$S/2-do.sql"
printf -- '-- drop it\nDROP TABLE "Old";\n' > "$S/3-drop.sql"
printf 'GRANT SELECT ON t TO anon;\nGRANT SELECT ON t TO svc;\n' > "$S/4-grant.sql"
printf 'ALTER TABLE t ALTER COLUMN s TYPE TEXT USING s::text;\nALTER TABLE t ALTER COLUMN s DROP NOT NULL;\nALTER TYPE e ADD VALUE '"'"'x'"'"';\n' > "$S/5-alter.sql"
printf 'INSERT INTO t (id) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM t);\nPRAGMA table_info(t);\nUPDATE t SET a = 1;\n' > "$S/6-misc.sql"
BASEREF=""
for r in main origin/main; do
  git -C "$DIR" rev-parse -q --verify "$r^{commit}" >/dev/null 2>&1 && { BASEREF="$r"; break; }
done
if [ -n "$BASEREF" ]; then
  B="$T/base"; mkdir -p "$B/bin"
  git -C "$DIR" show "$BASEREF:bin/check-migration-appliable.sh" > "$B/bin/check-migration-appliable.sh" && chmod +x "$B/bin/check-migration-appliable.sh"
  # BH-9929 adds one `<file>: contract-change: ...` hint line after a FLAGGED
  # non-additive statement (no FLAGGED word, same rc). Until the base
  # classifier carries that hint, the hint lines are compared on their own
  # (below) and left out of the byte comparison. Once the base has the hint,
  # the comparison is full bytes again.
  BASE_HINT=0; grep -q 'cc_hint' "$B/bin/check-migration-appliable.sh" && BASE_HINT=1
  for f in "$S"/*.sql ALL; do
    if [ "$f" = ALL ]; then set -- "$S"/*.sql; else set -- "$f"; fi
    WANT=$("$B/bin/check-migration-appliable.sh" p "$S" "$@" 2>&1); WRC=$?
    GOT=$("$CLS" p "$S" "$@" 2>&1); GRC=$?
    if [ "$BASE_HINT" = 0 ]; then GOT=$(grep -v '^[^:]*: contract-change: ' <<<"$GOT"); fi
    [ "$WANT" = "$GOT" ] && [ "$WRC" = "$GRC" ] && ok || bad "P1 .sql parity for ${f##*/} (base rc $WRC, now rc $GRC)"$'\n'"base: $WANT"$'\n'"now:  $GOT"
  done
  # The hint lines themselves: one after the DROP TABLE, none for the others.
  H=$("$CLS" p "$S" "$S"/*.sql 2>&1 | grep ': contract-change: ')
  [ "$(grep -c . <<<"$H")" = 1 ] && grep -q '3-drop.sql: contract-change: this is a non-additive change (drop-table)' <<<"$H" \
    && grep -qF '"Contract-change: yes"' <<<"$H" && ok || bad "P1 the contract-change hint: one line, for 3-drop.sql only: $H"
else
  skip "P1: no main/origin/main in this checkout to read the base classifier from"
fi

# --- P2: the .ts-only allowances stay .ts-only ------------------------------------
printf 'INSERT INTO t (id) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM t);\nPRAGMA table_info(t);\n' > "$S/p2.sql"
OUT=$("$CLS" p "$S" "$S/p2.sql" 2>&1); RC=$?
[ "$RC" = 1 ] && [ "$(grep -c FLAGGED <<< "$OUT")" = 2 ] && ! grep -q allowed <<< "$OUT" && ok || bad "P2 .sql INSERT/PRAGMA still flag, no allowed lines (rc $RC): $OUT"

echo "migrate-ts-lint.bh-4924-test: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
