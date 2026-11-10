#!/bin/bash
# tests/migration-lane-rowcount.bh-8914-test.sh — BH-8914: in the hub migration
# lane (bin/migration-lane.sh + bin/lib/migration-lane.sh), a data statement
# that changes 0 rows is `empty`, not `ok`, and its PR does not merge.
#
# The fixture (scratch harness, jobs worker, seams, newp/mkpr/run) is the
# BH-8704 one, tests/lib/migration-lane.bh-8704.sh, sourced and not edited. The
# apply command is tests/lib/migration-rowcount-fake-apply.bh-8914.py on a
# SQLite file in the case dir: 0 real database calls.
#
#   E1  UPDATE that matches 0 rows, no marker -> not merged, 1 log line with
#       file + statement + "0 rows", ledger empty <head>, 1 PR comment, batch
#       failed; the next tick skips it, 0 more comments, 0 more batches
#   E2  the same UPDATE marked `-- may-be-empty: idempotent backfill` -> merged
#   E2b an UPDATE that changes 1 row -> merged, no empty line
#   E3  one empty and one ok member in a batch -> the ok one merges, 1 critical
#   E4  an apply CLI with no report line -> merged as before, 1 log line
#   E6  CREATE + ALTER + INSERT ... VALUES ON CONFLICT DO NOTHING (0 rows) -> merged
#   E7  a report that does not match the file (unaligned) -> not merged, no comment,
#       ledger held <head>; the next tick (its CLI skips the applied file, as the
#       real CLIs do) skips the PR and still does not merge it (lr-9192)
#   E5  0 gh calls and only 127.0.0.1 curls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-lane-rowcount.bh-8914-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }
# shellcheck source=tests/lib/migration-lane.bh-8704.sh
. "$(dirname "$0")/lib/migration-lane.bh-8704.sh" || exit 1
FAKE="$DIR/tests/lib/migration-rowcount-fake-apply.bh-8914.py"
# scratch_install_closure follows `.sh` source lines only, so it never finds
# the python judge that bin/lib/migration-lane.sh runs; this suite adds it.
cp "$DIR/bin/lib/migration-rowcount.py" "$H/bin/lib/" 2>/dev/null || bad "setup: bin/lib/migration-rowcount.py missing"

# newr <name> — newp, with the fake apply CLI and a seeded SQLite database.
newr() {
  newp "$1"
  sed -i "s|^MIGRATION_LANE_APPLY_CMD=.*|MIGRATION_LANE_APPLY_CMD=\"python3 $FAKE\"|" "$H/env/$P.env"
  python3 "$FAKE" --seed
}
cmt() { grep -c "^comment $1 " "$C/calls"; }
dashboards() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select dashboards from users where id=?", ("hayley",)).fetchone()[0])' "$C/db.sqlite"; }

# ============================================================================
echo "E1: an UPDATE that matches 0 rows, no marker"
newr e1
F1=prisma/sql/20261104100000_grant.sql
mkpr 811 "$F1" "UPDATE users SET dashboards='b' WHERE dashboards='zzz';"
run "$P"
[ -z "$(merges)" ] && ok "E1 not merged" || bad "E1 merges: $(merges)"
grep -qF "#811 empty: $F1 statement 1 (UPDATE, line 1) changed 0 rows" <<<"$(lg)" \
  && ok "E1 one line names the file, the statement and 0 rows" || bad "E1 no empty line: $(lg | tail -6)"
[ "$(grep -cF '#811 empty:' <<<"$(lg)")" = 1 ] && ok "E1 exactly one empty line" || bad "E1 empty lines: $(grep -cF '#811 empty:' <<<"$(lg)")"
grep -qF '#811 applied' <<<"$(lg)" && ok "E1 the file is logged applied (production holds it)" || bad "E1 no applied line"
[ "$(ledger_get migration-lane "pr $P#811" | cut -d' ' -f1-2)" = "empty $HEAD_811" ] && ok "E1 ledger row empty <head>" || bad "E1 row: $(ledger_get migration-lane "pr $P#811")"
[ "$(cmt 811)" = 1 ] && ok "E1 one comment on the PR" || bad "E1 comments on #811: $(cmt 811)"
C1L=$(grep "^comment 811 " "$C/calls")
grep -qF "20261104100000_grant.sql" <<<"$C1L" && grep -qF "statement 1" <<<"$C1L" && grep -qF "0 rows" <<<"$C1L" \
  && ok "E1 the comment names the file, the statement and 0 rows" || bad "E1 comment: $C1L"
grep -qF 'may-be-empty' "$C/comments" && ok "E1 the comment names the marker" || bad "E1 comment has no marker syntax"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = failed ] && ok "E1 batch = failed" || bad "E1 batch: $(ledger_get migration-lane "batch $P")"
[ "$(grep -c '^alert critical' "$C/calls")" = 1 ] && ok "E1 one critical alert" || bad "E1 alerts: $(cat "$C/alerts")"
grep -qF 'changed 0 rows' "$C/alerts" && ok "E1 the alert says a data statement changed 0 rows" || bad "E1 alert text: $(cat "$C/alerts")"
[ "$(dashboards)" = a ] && ok "E1 the fake database row is unchanged" || bad "E1 dashboards $(dashboards)"
PRC=$(calls pr_create)
run "$P"
grep -qF '#811 skipped: a data statement changed 0 rows' <<<"$(lg)" && ok "E1 the next tick skips the PR" || bad "E1 no skip line: $(lg | tail -4)"
[ "$(cmt 811)" = 1 ] && ok "E1 the next tick adds no comment" || bad "E1 comments now $(cmt 811)"
[ "$(calls pr_create)" = "$PRC" ] && ok "E1 the next tick makes no batch" || bad "E1 pr_create $(calls pr_create) (was $PRC)"
[ -z "$(merges)" ] && ok "E1 still not merged" || bad "E1 merged on tick 2: $(merges)"

# ============================================================================
echo "E2: the same UPDATE with a may-be-empty marker"
newr e2
mkpr 821 prisma/sql/20261104100000_grant.sql "-- may-be-empty: idempotent backfill
UPDATE users SET dashboards='b' WHERE dashboards='zzz';"
run "$P"
[ "$(merges)" = 821 ] && ok "E2 merged" || bad "E2 merges: $(merges); $(lg | tail -4)"
grep -qF '#821 may-be-empty: prisma/sql/20261104100000_grant.sql statement 1 (idempotent backfill)' <<<"$(lg)" \
  && ok "E2 the marker reason is logged" || bad "E2 no marker line: $(lg | tail -4)"
grep -qF '#821 empty' <<<"$(lg)" && bad "E2 an empty line" || ok "E2 no empty line"

echo "E2b: an UPDATE that changes 1 row"
newr e2b
mkpr 822 prisma/sql/20261104100000_grant.sql "UPDATE users SET dashboards='b' WHERE id='hayley';"
run "$P"
[ "$(merges)" = 822 ] && ok "E2b merged" || bad "E2b merges: $(merges); $(lg | tail -4)"
grep -qE '#822 (empty|may-be-empty|not merged)' <<<"$(lg)" && bad "E2b an empty/marker line: $(lg | tail -4)" || ok "E2b no empty line"
[ "$(dashboards)" = b ] && ok "E2b the fake database row changed" || bad "E2b dashboards $(dashboards)"
[ "$(ledger_get migration-lane "batch $P" | cut -d' ' -f1)" = "done" ] && ok "E2b batch = done" || bad "E2b batch"

# ============================================================================
echo "E3: one empty and one ok member in one batch"
newr e3
mkpr 831 prisma/sql/20261104100000_a.sql "UPDATE users SET dashboards='c' WHERE id='hayley';"
mkpr 832 prisma/sql/20261104100100_b.sql "DELETE FROM users WHERE id='nobody';"
run "$P"
[ "$(merges)" = 831 ] && ok "E3 the ok member merges, the empty one does not" || bad "E3 merges: $(merges)"
grep -qF '#832 empty: prisma/sql/20261104100100_b.sql statement 1 (DELETE, line 1) changed 0 rows' <<<"$(lg)" \
  && ok "E3 the DELETE is named" || bad "E3 no DELETE line: $(lg | tail -6)"
[ "$(grep -c '^alert critical' "$C/calls")" = 1 ] && ok "E3 one critical alert" || bad "E3 alerts: $(cat "$C/alerts")"
[ "$(cmt 831)" = 1 ] && [ "$(cmt 832)" = 1 ] && ok "E3 one comment each (merged / empty)" || bad "E3 comments 831=$(cmt 831) 832=$(cmt 832)"
grep "^comment 832 " "$C/calls" | grep -qF '0 rows' && ok "E3 #832's comment says 0 rows" || bad "E3 #832 comment: $(grep '^comment 832' "$C/calls")"

# ============================================================================
echo "E4: an apply CLI that prints no report line"
newp e4
mkpr 841 prisma/sql/20261104100000_grant.sql "UPDATE users SET dashboards='b' WHERE dashboards='zzz';"
run "$P"
[ "$(merges)" = 841 ] && ok "E4 merged as before" || bad "E4 merges: $(merges)"
grep -qF '#841 prisma/sql/20261104100000_grant.sql: the apply output has no migration-rows lines; row counts not checked' <<<"$(lg)" \
  && ok "E4 one row-counts-not-checked line" || bad "E4 no unreported line: $(lg | tail -4)"

# ============================================================================
echo "E6: schema statements and INSERT ... VALUES are not counted"
newr e6
mkpr 861 prisma/sql/20261104100000_schema.sql "CREATE TABLE e6 (a int PRIMARY KEY);
ALTER TABLE e6 ADD COLUMN b int;
INSERT INTO users (id, dashboards) VALUES ('hayley', 'x') ON CONFLICT DO NOTHING;"
run "$P"
[ "$(merges)" = 861 ] && ok "E6 merged" || bad "E6 merges: $(merges); $(lg | tail -4)"
grep -qE '#861 (empty|not merged)' <<<"$(lg)" && bad "E6 judged a schema statement: $(lg | tail -4)" || ok "E6 no empty line"
grep -qF 'migration-rows: 20261104100000_schema.sql 3 INSERT 0' "$H/state/migration-lane/$P/apply.out" \
  && ok "E6 the fake reported the 0-row INSERT" || bad "E6 apply.out: $(cat "$H/state/migration-lane/$P/apply.out")"

# ============================================================================
echo "E7: a report that does not match the file"
newr e7
cat > "$C/badapply.sh" <<'EOS'
#!/bin/bash
st="$ML_FX/status.json"
for f in prisma/sql/2026*.sql; do
  b=${f##*/}
  # The real CLIs skip a file the ledger already holds, and report nothing.
  jq -e --arg b "$b" 'any(.applied[]?; .filename == $b)' "$st" >/dev/null 2>&1 && continue
  echo "migration-rows: $b 1 DELETE 4"
  jq --arg b "$b" --arg s "$(sha256sum "$f" | cut -d" " -f1)" '.applied += [{filename:$b, checksum:$s}]' "$st" > "$st.t" && mv "$st.t" "$st"
done
EOS
sed -i "s|^MIGRATION_LANE_APPLY_CMD=.*|MIGRATION_LANE_APPLY_CMD=\"bash $C/badapply.sh\"|" "$H/env/$P.env"
mkpr 871 prisma/sql/20261104100000_grant.sql "UPDATE users SET dashboards='b' WHERE id='hayley';"
run "$P"
[ -z "$(merges)" ] && ok "E7 not merged" || bad "E7 merges: $(merges)"
grep -qF '#871 not merged: prisma/sql/20261104100000_grant.sql row report does not match its statements' <<<"$(lg)" \
  && ok "E7 the unaligned line" || bad "E7 no unaligned line: $(lg | tail -4)"
[ "$(cmt 871)" = 0 ] && ok "E7 no PR comment" || bad "E7 comments $(cmt 871)"
[ "$(ledger_get migration-lane "pr $P#871" | cut -d' ' -f1-2)" = "held $HEAD_871" ] && ok "E7 ledger row held <head>" \
  || bad "E7 row: $(ledger_get migration-lane "pr $P#871")"
PRC=$(calls pr_create)
run "$P"
grep -qF '#871 skipped: row counts could not be checked' <<<"$(lg)" && ok "E7 the next tick skips the PR" || bad "E7 no skip line: $(lg | tail -4)"
[ -z "$(merges)" ] && ok "E7 still not merged on tick 2" || bad "E7 merged on tick 2: $(merges); $(lg | tail -4)"
[ "$(calls pr_create)" = "$PRC" ] && ok "E7 the next tick makes no batch" || bad "E7 pr_create $(calls pr_create) (was $PRC)"

# ============================================================================
echo "E5: no vendor call"
[ ! -s "$T/gh.log" ] && ok "E5 0 gh calls" || bad "E5 gh calls: $(head -3 "$T/gh.log")"
OFFBOX=$(grep -vE '^https?://127\.0\.0\.1:' "$T/curl-hosts.log")
[ -n "$OFFBOX" ] && bad "E5 a curl left 127.0.0.1: $(head -3 <<<"$OFFBOX")" || ok "E5 every curl went to 127.0.0.1"

echo "migration-lane-rowcount.bh-8914: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
