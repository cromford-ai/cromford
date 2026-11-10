#!/bin/bash
# tests/migration-rowcount.bh-8914-test.sh — BH-8914: the row-count judge
# bin/lib/migration-rowcount.py, alone (no lane, no worker).
#
#   C1-C18  the splitter and the data classifier (UPDATE, DELETE, INSERT ...
#           SELECT, WITH ... UPDATE/DELETE/INSERT are data; near misses are not)
#   M1-M11  the `-- may-be-empty: <reason>` marker and its near misses
#   R1-R12  the report reader (`migration-rows: <file> <k> <COMMAND> <n|->`)
#           and the verdicts ok|marked|empty|unaligned|unreported, with the rc
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-rowcount.bh-8914-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PY="$DIR/bin/lib/migration-rowcount.py"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# cls <id> <sql> — the classifier's verdict per statement: "<k>:<verb|->" joined by spaces.
cls() { printf '%s' "$2" > "$T/$1.sql"; python3 -I "$PY" classify "$T/$1.sql" 2>&1 | awk -F'\t' '{printf "%s%s:%s", (NR>1?" ":""), $1, $3}'; }
# want <id> <sql> <expected>
want() {
  local got first="${2%%$'\n'*}"; got=$(cls "$1" "$2")
  [ "$got" = "$3" ] && ok "$1 ${first:0:50} -> $3" || bad "$1 want '$3' got '$got'"
}

echo "C: the classifier"
want C1  "UPDATE \"User\" SET x=1 WHERE id='h';" "1:UPDATE"
want C2  "update t set a=1;" "1:UPDATE"
want C3  $'-- note\nDELETE FROM t WHERE a=1;' "1:DELETE"
want C4  "INSERT INTO t (a) SELECT a FROM u;" "1:INSERT"
want C5  "INSERT INTO t SELECT * FROM u WHERE false;" "1:INSERT"
want C6  "WITH s AS (SELECT 1) UPDATE t SET a=1;" "1:UPDATE"
want C7  "INSERT INTO t (a) VALUES (1);" "1:-"
want C8  "INSERT INTO t (a) VALUES ((SELECT 1));" "1:-"
want C9  "INSERT INTO t VALUES (1) ON CONFLICT DO NOTHING;" "1:-"
want C10 "CREATE TABLE t (a int REFERENCES u ON UPDATE CASCADE);" "1:-"
want C11 "CREATE TRIGGER tr BEFORE UPDATE ON t FOR EACH ROW EXECUTE FUNCTION f();" "1:-"
want C12 "GRANT UPDATE ON t TO r;" "1:-"
want C13 "ALTER TABLE t ADD COLUMN a int;" "1:-"
want C14 "DROP INDEX IF EXISTS i;" "1:-"
want C15 'DO $$ BEGIN UPDATE t SET a=1; END $$;' "1:-"
want C16 'CREATE FUNCTION f() RETURNS void AS $fn$ DELETE FROM t; UPDATE t SET a=2; $fn$ LANGUAGE sql;' "1:-"
want C17 "SELECT 'UPDATE t; DELETE FROM u';" "1:-"
want C18 "WITH s AS (SELECT 1) SELECT * FROM s;" "1:-"
want C19 "-- UPDATE t SET a=1" ""
want C20 $'CREATE TABLE a (id int);\n/* DELETE FROM a; */\nUPDATE a SET id=2 WHERE id=1;\nSELECT "x;y" FROM a;\nDELETE FROM a WHERE id = E\'it\\\'s;\';' "1:- 2:UPDATE 3:- 4:DELETE"
want C21 $'INSERT INTO t (a) VALUES (\'a\'\';UPDATE\');\r\nUPDATE t SET a=1' "1:- 2:UPDATE"
# The line of each statement's first keyword (after its leading comments).
printf '%s' $'CREATE TABLE a (id int);\n\n-- lead\n-- lead 2\nUPDATE a\n  SET id = 2;' > "$T/line.sql"
L=$(python3 -I "$PY" classify "$T/line.sql" | awk -F'\t' '$1==2{print $2}')
[ "$L" = 5 ] && ok "C22 statement 2 starts on line 5" || bad "C22 line: '$L'"

echo "M: the marker"
# jm <id> <sql> — the judge's verdict and reason for statement 1 (count 0 reported).
jm() {
  printf '%s' "$2" > "$T/$1.sql"
  printf 'migration-rows: %s.sql 1 UPDATE 0\nmigration-rows: %s.sql 2 UPDATE 0\n' "$1" "$1" > "$T/$1.out"
  python3 -I "$PY" judge "$T/$1.sql" "$1.sql" "$T/$1.out" 2>&1 | awk -F'\t' -v k="${3:-1}" '$2==k{print $1 "|" $6}'
}
wantm() {
  local got; got=$(jm "$1" "$2" "${4:-1}")
  [ "$got" = "$3" ] && ok "$1 -> $3" || bad "$1 want '$3' got '$got'"
}
wantm M1  $'-- may-be-empty: idempotent backfill\nUPDATE t SET a=1;' "marked|idempotent backfill"
wantm M2  $'UPDATE t SET a=1; -- may-be-empty: idempotent backfill' "marked|idempotent backfill"
wantm M3  $'UPDATE t\n  -- may-be-empty: grant already given\n  SET a=1;' "marked|grant already given"
wantm M4  $'-- MAY-BE-EMPTY: reason\nUPDATE t SET a=1;' "marked|reason"
wantm M5  $'-- may-be-empty:\nUPDATE t SET a=1;' "empty|-"
wantm M6  $'-- may be empty: x\nUPDATE t SET a=1;' "empty|-"
wantm M7  $'-- maybe-empty: x\nUPDATE t SET a=1;' "empty|-"
wantm M8  $'/* may-be-empty: x */\nUPDATE t SET a=1;' "empty|-"
wantm M9  $'UPDATE t SET a=\'-- may-be-empty: x\';' "empty|-"
wantm M10 $'-- may-be-empty: first only\nUPDATE t SET a=1;\nUPDATE t SET a=2;' "empty|-" 2
wantm M11 $'UPDATE t SET a=1; -- may-be-empty: first only\nUPDATE t SET a=2;' "empty|-" 2
wantm M12 $'UPDATE t SET a=1; -- may-be-empty: first only\nUPDATE t SET a=2;' "marked|first only" 1

echo "R: the report reader and the verdicts"
# jr <id> <sql> <report> — prints "<rc>|<verdict lines, ';'-joined, fields 1-4 by ','>".
jr() {
  printf '%s' "$2" > "$T/$1.sql"; printf '%s' "$3" > "$T/$1.out"
  local o rc=0
  o=$(python3 -I "$PY" judge "$T/$1.sql" "$1.sql" "$T/$1.out" 2>/dev/null) || rc=$?
  printf '%s|%s' "$rc" "$(awk -F'\t' 'NF{printf "%s%s,%s,%s,%s", (c++?";":""), $1, $2, $3, $4}' <<<"$o")"
}
wantr() {
  local got; got=$(jr "$1" "$2" "$3")
  [ "$got" = "$4" ] && ok "$1 -> $4" || bad "$1 want '$4' got '$got'"
}
U='UPDATE t SET a=1 WHERE b=2;'
wantr R1  "$U" $'R1.sql ok\n' "3|unreported,-,-,-"
wantr R2  "$U" $'migration-rows: R2.sql 1 UPDATE 1\nR2.sql ok\n' "0|ok,1,UPDATE,1"
wantr R3  "$U" $'migration-rows: R3.sql 1 UPDATE 14\n' "0|ok,1,UPDATE,14"
wantr R4  "$U" $'migration-rows: R4.sql 1 UPDATE 0\n' "1|empty,1,UPDATE,0"
wantr R5  "$U" $'migration-rows: R5.sql 1 DELETE 3\n' "1|unaligned,1,UPDATE,3"
wantr R6  "$U" $'migration-rows: R6.sql 1 UPDATE -\n' "1|unaligned,1,UPDATE,-"
wantr R7  $'CREATE TABLE x (a int);\nUPDATE t SET a=1;' $'migration-rows: R7.sql 1 CREATE -\n' "1|unaligned,2,UPDATE,-"
wantr R8  "$U" $'migration-rows: aR8.sql 1 UPDATE 0\nmigration-rows: R8.sql.bak 1 UPDATE 0\n' "3|unreported,-,-,-"
wantr R9  "$U" $'error: x migration-rows: R9.sql 1 UPDATE 0\nmigration-rows: R9.sql 1 UPDATE 2\n' "0|ok,1,UPDATE,2"
wantr R10 "$U" $'migration-rows: R10.sql 1 UPDATE 0\r\nmigration-rows: R10.sql 1 UPDATE 5\r\n' "0|ok,1,UPDATE,5"
wantr R11 "$U" $'migration-rows: R11.sql 1 UPDATE 1\nmigration-rows: R11.sql 2 UPDATE 1\n' "1|ok,1,UPDATE,1;unaligned,2,-,-"
wantr R12 'CREATE TABLE x (a int); ALTER TABLE x ADD COLUMN b int; INSERT INTO x VALUES (1) ON CONFLICT DO NOTHING;' \
  $'migration-rows: R12.sql 1 CREATE -\nmigration-rows: R12.sql 2 ALTER -\nmigration-rows: R12.sql 3 INSERT 0\n' "0|"
wantr R13 $'-- may-be-empty: idempotent\nDELETE FROM t WHERE a=1;\nUPDATE t SET a=1;' \
  $'migration-rows: R13.sql 1 DELETE 0\nmigration-rows: R13.sql 2 UPDATE 0\n' "1|marked,1,DELETE,0;empty,2,UPDATE,0"
wantr R14 "WITH s AS (SELECT 1) UPDATE t SET a=1;" $'migration-rows: R14.sql 1 UPDATE 0\n' "1|empty,1,UPDATE,0"
# A missing SQL file is a crash, never ok or unreported.
rc=0; python3 -I "$PY" judge "$T/nope.sql" nope.sql "$T/R2.out" >/dev/null 2>&1 || rc=$?
case "$rc" in 0|1|3) bad "R15 a missing SQL file gave rc $rc" ;; *) ok "R15 a missing SQL file: rc $rc" ;; esac
# The output holds no SQL text and no apply-output text.
printf '%s' "UPDATE t SET secretcol='fixture-sqltext' WHERE a=1;" > "$T/R16.sql"
printf 'migration-rows: R16.sql 1 UPDATE 0\nfixture-applytext\n' > "$T/R16.out"
O=$(python3 -I "$PY" judge "$T/R16.sql" R16.sql "$T/R16.out" 2>&1)
grep -qE 'fixture-sqltext|fixture-applytext|secretcol' <<<"$O" && bad "R16 the output echoes input text: $O" || ok "R16 no SQL or apply text in the output"

echo "migration-rowcount.bh-8914: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
