#!/bin/bash
# tests/migration-lane-rowcount-proof.bh-9416-test.sh — BH-9416 (rest of
# BH-8914 Acceptance 4): prove, on every run, that case 1 of the BH-8914 suite
# (a 0-row UPDATE with no marker is not merged) is red without the row-count
# judge, and that the lane suite makes 0 calls to a real database.
#
# The fixture is the BH-8704 one (tests/lib/migration-lane.bh-8704.sh), sourced
# and not edited; the apply command is the BH-8914 SQLite fake
# (tests/lib/migration-rowcount-fake-apply.bh-8914.py).
#
#   P1  HEAD lane: the E1 scenario is not merged, 1 `empty:` line, 0 rows
#   P3  pre-fix lane from 9298941c (first parent of the BH-8914 merge): the
#       same scenario merges, no `empty:` line. SKIP on a shallow clone.
#   P2  HEAD lane with the ml_judge_rows call removed (scratch copy): merges.
#       The sed guard asserts the call was there, so a rename fails the case.
#   P5  an apply command that runs psql writes exactly 1 tripwire line
#   P4  (reads the logs of P1-P3) 0 DB-client calls, 0 gh calls, only
#       127.0.0.1 curls, a db.sqlite per case, a `.invalid` DATABASE_URL host
#
# The fixture worker exits after 180 s by design (project-lease.bh-6883.mjs),
# so each case first asserts the worker answers: a dead worker FAILS the case,
# it never reads as "not merged".
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-lane-rowcount-proof.bh-9416-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 0; }
# shellcheck source=tests/lib/migration-lane.bh-8704.sh
. "$(dirname "$0")/lib/migration-lane.bh-8704.sh" || exit 1
FAKE="$DIR/tests/lib/migration-rowcount-fake-apply.bh-8914.py"
PREFIX=9298941c5d848f956662c027e5b16393ef192a69
# scratch-closure-allow: the closure installer follows `.sh` only, so the python judge is copied by hand (as in the BH-8914 suite); the other two copies save the installed lane so P2/P3 can restore it after they mutate it
cp "$DIR/bin/lib/migration-rowcount.py" "$H/bin/lib/" 2>/dev/null || bad "setup: bin/lib/migration-rowcount.py missing"
cp "$H/bin/lib/migration-lane.sh" "$T/lib-lane.head"
cp "$H/bin/migration-lane.sh" "$T/lane.head"
restore_head() { cp "$T/lib-lane.head" "$H/bin/lib/migration-lane.sh"; cp "$T/lane.head" "$H/bin/migration-lane.sh"; }

# DB-client tripwires: $FB is first on PATH (the fixture put it there).
for c in psql pg_dump pg_restore prisma npx mysql; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/db-clients.log"\nexit 1\n' "$c" "$T" > "$FB/$c"
  chmod +x "$FB/$c"
done
: > "$T/db-clients.log"

newr() {
  newp "$1"
  sed -i "s|^MIGRATION_LANE_APPLY_CMD=.*|MIGRATION_LANE_APPLY_CMD=\"python3 $FAKE\"|" "$H/env/$P.env"
  python3 "$FAKE" --seed
}
CASEDIRS=()
alive() { # <case> — rc 0 when the fixture worker still answers
  kill -0 "$SPID" 2>/dev/null && "$REALCURL" -sf "$JOBS_URL/__count?lane=probe&project=probe" >/dev/null 2>&1 \
    || { bad "fixture worker died before $1"; return 1; }
}
F1=prisma/sql/20261104100000_grant.sql
e1() { # <n> — the BH-8914 E1 scenario: a 0-row UPDATE with no marker
  mkpr "$1" "$F1" "UPDATE users SET dashboards='b' WHERE dashboards='zzz';"
  run "$P"
  CASEDIRS+=("$C")
}

# ============================================================================
echo "P1: HEAD lane, 0-row UPDATE, no marker"
if alive P1; then
  newr p1; e1 9401
  [ -z "$(merges)" ] && ok "P1 not merged" || bad "P1 merges: $(merges)"
  grep -qF "#9401 empty: $F1 statement 1 (UPDATE, line 1) changed 0 rows" <<<"$(lg)" \
    && ok "P1 one empty line with changed 0 rows" || bad "P1 no empty line: $(lg | tail -6); run.out: $(tail -5 "$C/run.out")"
fi

# ============================================================================
echo "P3: pre-fix lane ($PREFIX), same scenario"
if ! git -C "$DIR" cat-file -e "$PREFIX:bin/lib/migration-lane.sh" 2>/dev/null; then
  echo "SKIP P3: pre-fix commit 9298941c not in this clone (shallow); P2 proves the same gate"
elif alive P3; then
  git -C "$DIR" show "$PREFIX:bin/lib/migration-lane.sh" > "$H/bin/lib/migration-lane.sh"
  git -C "$DIR" show "$PREFIX:bin/migration-lane.sh" > "$H/bin/migration-lane.sh"
  if grep -q 'ml_judge_rows' "$H/bin/lib/migration-lane.sh"; then
    bad "P3 the pre-fix lane already has ml_judge_rows: wrong sha"
  else
    newr p3; e1 9403
    [ "$(merges)" = 9403 ] && ok "P3 the pre-fix lane merges the 0-row PR (case 1 is red on main)" \
      || bad "P3 merges: '$(merges)'; log: $(lg | tail -4); run.out: $(tail -5 "$C/run.out")"
    grep -qF '#9403 empty:' <<<"$(lg)" && bad "P3 an empty line on the pre-fix lane" || ok "P3 no empty line"
  fi
  restore_head
fi

# ============================================================================
echo "P2: HEAD lane with the ml_judge_rows call removed"
if alive P2; then
  L="$H/bin/lib/migration-lane.sh"
  CALL='for p in $f; do ml_judge_rows "$n" "$p" "$apply/$p" "$out" || held=1; done'
  if [ "$(grep -cF "$CALL" "$L")" = 1 ]; then
    ok "P2 the judge call is in the lane before the mutation"
    grep -vF "$CALL" "$T/lib-lane.head" > "$L"
    if grep -qF 'ml_judge_rows "$n"' "$L"; then
      bad "P2 the mutation did not remove the call"
    else
      ok "P2 the judge call is gone after the mutation"
      newr p2; e1 9402
      [ "$(merges)" = 9402 ] && ok "P2 without the judge the 0-row PR merges" \
        || bad "P2 merges: '$(merges)'; log: $(lg | tail -4); run.out: $(tail -5 "$C/run.out")"
    fi
  else
    bad "P2 the judge call is not in bin/lib/migration-lane.sh (renamed?): $(grep -c 'ml_judge_rows' "$L") ml_judge_rows lines"
  fi
  restore_head
fi

# ============================================================================
echo "P4: 0 calls to a real database"
[ ! -s "$T/db-clients.log" ] && ok "P4 0 DB-client calls" || bad "P4 DB-client calls: $(head -3 "$T/db-clients.log")"
[ "${#CASEDIRS[@]}" -ge 2 ] && ok "P4 ${#CASEDIRS[@]} cases ran" || bad "P4 only ${#CASEDIRS[@]} cases ran"
for d in "${CASEDIRS[@]}"; do
  [ -s "$d/db.sqlite" ] && ok "P4 ${d##*/} used the SQLite fake" || bad "P4 ${d##*/} has no db.sqlite"
done
[ ! -s "$T/gh.log" ] && ok "P4 0 gh calls" || bad "P4 gh calls: $(head -3 "$T/gh.log")"
[ -s "$T/curl-hosts.log" ] && ok "P4 the curl log is written" || bad "P4 the curl log is empty"
OFFBOX=$(grep -vE '^https?://127\.0\.0\.1:' "$T/curl-hosts.log")
[ -z "$OFFBOX" ] && ok "P4 every curl went to 127.0.0.1" || bad "P4 a curl left 127.0.0.1: $(head -3 <<<"$OFFBOX")"
DBHOST=$(sed -n 's|^MIGRATION_LANE_DATABASE_URL=[a-z]*://[^@]*@\([^/]*\)/.*|\1|p' "$H/env/$P.env")
[[ "$DBHOST" == *.invalid ]] && ok "P4 the DATABASE_URL host $DBHOST never resolves" || bad "P4 DATABASE_URL host '$DBHOST'"

# ============================================================================
echo "P5: the tripwire records a DB-client call"
if alive P5; then
  newr p5
  sed -i "s|^MIGRATION_LANE_APPLY_CMD=.*|MIGRATION_LANE_APPLY_CMD=\"psql -c 'select 1'\"|" "$H/env/$P.env"
  mkpr 9404 "$F1" "UPDATE users SET dashboards='b' WHERE id='hayley';"
  run "$P"
  [ "$(grep -c '^psql ' "$T/db-clients.log")" = 1 ] && ok "P5 exactly 1 psql line in the tripwire log" \
    || bad "P5 tripwire log: '$(cat "$T/db-clients.log")'; run.out: $(tail -5 "$C/run.out")"
  [ -z "$(merges)" ] && ok "P5 the failed apply does not merge" || bad "P5 merges: $(merges)"
fi

echo "migration-lane-rowcount-proof.bh-9416: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
