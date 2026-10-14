#!/bin/bash
# tests/wake-claims-client.bh-2635-test.sh — BH-2635 (BH-2525.0): the contract
# slice of #2525. Loads the REAL bin/jobs-client.sh (which loads
# bin/lib/jobs/queue.sh through JC_MODULES) and drives wakes_claim,
# wake_cursor_get, wake_cursor_put and wake_cooldown_take against a stub curl
# that records each request and answers a canned body + HTTP code. Then loads
# the BH-2525 block of worker/jobs/schema.sql into an in-memory sqlite.
#
#   C1  wakes_claim: TSV row + `#top N`; POST /api/wakes/claim, repos lowercased
#       with empties dropped, kinds_all_repos as given, limit a number
#   C2  empty wakes prints only `#top N`; null event/at print `-`
#   C3  500, non-JSON, and a 200 without scanned_top: rc 2, empty stdout
#   C4  wake_cursor_get: integer printed; GET /api/wakes/cursor?box=hub
#   C5  cursor null prints nothing (never 0); cursor 0 prints 0
#   C6  500, missing cursor key, 404: rc 2, empty stdout
#   C7  wake_cursor_put 2xx rc 0; PUT body {box, cursor:<number>}
#   C8  500 rc 2; a non-numeric cursor is rc 2 with no request
#   C9  wake_cooldown_take taken:true rc 0; POST /api/wakes/cooldown/take body
#   C10 taken:false rc 1
#   C11 500, non-JSON, taken:"yes", 409: rc 2 (a failed request is never taken)
#   C12 JOBS_URL empty: every helper rc 2 and no curl call
#   S1  table keys: wake_claims per (wake, box), cursors per box, cooldowns
#       per (kind, project) with an INTEGER last_at
#   S2  the seed copies digit-only wake-cursor.<box> settings, never overwrites
#   S3  the BH-2525 block carries no DROP / ALTER
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/wake-claims-client.bh-2635-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- stub curl ---------------------------------------------------------
mkdir -p "$T/bin" "$T/logs"
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
m=GET d="" u=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) d="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H) shift 2 ;;
    -*) shift ;;
    *) u="$1"; shift ;;
  esac
done
printf '%s\t%s\t%s\n' "$m" "$u" "$d" >> "$STUB_DIR/req.log"
printf '%s\n%s' "$(cat "$STUB_DIR/body")" "$(cat "$STUB_DIR/code")"
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" STUB_DIR="$T"
export HARNESS="$T" HARNESS_SECRET=test JOBS_URL=http://stub JOBS_RETRIES=0
# shellcheck source=/dev/null
. "$DIR/bin/jobs-client.sh" || { echo "FAIL: cannot source bin/jobs-client.sh"; exit 1; }

# stub <code> <body>: the next request's answer; clears the request log.
stub() { printf '%s' "$1" > "$T/code"; printf '%s' "$2" > "$T/body"; : > "$T/req.log"; }
# run <cmd...>: sets OUT and RC.
run() { OUT=$("$@"); RC=$?; }
req_n()      { wc -l < "$T/req.log" | tr -d ' '; }
req_field()  { sed -n 1p "$T/req.log" | cut -f"$1"; }
body_q()     { req_field 3 | jq -c "$1" 2>/dev/null; }
want() { # want <label> <got> <expected>
  if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }

# ---------- C1 ---------------------------------------------------------------
stub 200 '{"wakes":[{"id":7,"repo":"example-org/cromford","kind":"pr","key":"12","event":"closed","at":"t"}],"cursor":7,"scanned_top":9}'
run wakes_claim hub 50 "example-org/Cromford,,Acme/X" "deploy,push"
want "C1 rc" "$RC" 0
want "C1 stdout" "$OUT" "$(printf '7\texample-org/cromford\tpr\t12\tclosed\tt\n#top 9')"
want "C1 method" "$(req_field 1)" POST
want "C1 url" "$(req_field 2)" "http://stub/api/wakes/claim"
want "C1 repos" "$(body_q .repos)" '["example-org/cromford","acme/x"]'
want "C1 kinds" "$(body_q .kinds_all_repos)" '["deploy","push"]'
want "C1 limit" "$(body_q .limit)" 50
want "C1 box" "$(body_q .box)" '"hub"'

# ---------- C2 ---------------------------------------------------------------
stub 200 '{"wakes":[],"scanned_top":3}'
run wakes_claim hub 10 "" ""
want "C2 empty rc" "$RC" 0
want "C2 empty stdout" "$OUT" "#top 3"
want "C2 empty repos" "$(body_q .repos)" '[]'
stub 200 '{"wakes":[{"id":8,"repo":"a/b","kind":"push","key":"main","event":null}],"scanned_top":8}'
run wakes_claim hub 10 "a/b" ""
want "C2 null event/at" "$OUT" "$(printf '8\ta/b\tpush\tmain\t-\t-\n#top 8')"

# ---------- C3 ---------------------------------------------------------------
for c in '500|{"error":"x"}' '200|not json' '200|{"wakes":[]}' '200|{"wakes":[{"id":1,"repo":"a/b","kind":"k","key":"1"}]}' '200|{"wakes":{},"scanned_top":1}'; do
  stub "${c%%|*}" "${c#*|}"
  run wakes_claim hub 10 "a/b" ""
  want "C3 [$c] rc" "$RC" 2
  want "C3 [$c] stdout" "$OUT" ""
done
stub 200 '{"wakes":[],"scanned_top":1}'
run wakes_claim "" 10 "a/b" ""
want "C3 empty box rc" "$RC" 2
run wakes_claim hub ten "a/b" ""
want "C3 non-numeric limit rc" "$RC" 2
want "C3 bad args sent nothing" "$(req_n)" 0

# ---------- C4 ---------------------------------------------------------------
stub 200 '{"box":"hub","cursor":42}'
run wake_cursor_get hub
want "C4 rc" "$RC" 0
want "C4 stdout" "$OUT" 42
want "C4 method" "$(req_field 1)" GET
want "C4 url" "$(req_field 2)" "http://stub/api/wakes/cursor?box=hub"

# ---------- C5 ---------------------------------------------------------------
stub 200 '{"box":"hub","cursor":null}'
run wake_cursor_get hub
want "C5 null rc" "$RC" 0
want "C5 null stdout" "$OUT" ""
stub 200 '{"box":"hub","cursor":0}'
run wake_cursor_get hub
want "C5 zero stdout" "$OUT" 0

# ---------- C6 ---------------------------------------------------------------
for c in '500|{"error":"x"}' '200|{"box":"hub"}' '404|' '200|not json' '200|{"cursor":"12"}' '200|{"cursor":-1}' '200|{"cursor":1.5}'; do
  stub "${c%%|*}" "${c#*|}"
  run wake_cursor_get hub
  want "C6 [$c] rc" "$RC" 2
  want "C6 [$c] stdout" "$OUT" ""
done
run wake_cursor_get ""
want "C6 empty box rc" "$RC" 2

# ---------- C7 ---------------------------------------------------------------
for code in 200 204; do
  stub "$code" '{"ok":true}'
  run wake_cursor_put hub 42
  want "C7 $code rc" "$RC" 0
  want "C7 $code stdout" "$OUT" ""
done
want "C7 method" "$(req_field 1)" PUT
want "C7 url" "$(req_field 2)" "http://stub/api/wakes/cursor"
want "C7 body" "$(body_q '{box,cursor}')" '{"box":"hub","cursor":42}'

# ---------- C8 ---------------------------------------------------------------
stub 500 '{"error":"x"}'
run wake_cursor_put hub 42
want "C8 500 rc" "$RC" 2
stub 200 '{"ok":true}'
run wake_cursor_put hub abc
want "C8 abc rc" "$RC" 2
run wake_cursor_put "" 5
want "C8 empty box rc" "$RC" 2
want "C8 bad args sent nothing" "$(req_n)" 0

# ---------- C9 ---------------------------------------------------------------
stub 200 '{"taken":true}'
run wake_cooldown_take review cromford 600 hub
want "C9 rc" "$RC" 0
want "C9 stdout" "$OUT" ""
want "C9 method" "$(req_field 1)" POST
want "C9 url" "$(req_field 2)" "http://stub/api/wakes/cooldown/take"
want "C9 body" "$(body_q '{kind,project,window_s,box}')" '{"kind":"review","project":"cromford","window_s":600,"box":"hub"}'

# ---------- C10 --------------------------------------------------------------
stub 200 '{"taken":false}'
run wake_cooldown_take review cromford 600 hub
want "C10 rc" "$RC" 1

# ---------- C11 --------------------------------------------------------------
for c in '500|{"taken":true}' '200|not json' '200|{"taken":"yes"}' '409|{"taken":true}' '404|' '200|{}'; do
  stub "${c%%|*}" "${c#*|}"
  run wake_cooldown_take review cromford 600 hub
  want "C11 [$c] rc" "$RC" 2
done
stub 200 '{"taken":true}'
run wake_cooldown_take review cromford soon hub
want "C11 non-numeric window rc" "$RC" 2
run wake_cooldown_take review "" 600 hub
want "C11 empty project rc" "$RC" 2
want "C11 bad args sent nothing" "$(req_n)" 0

# ---------- C12 --------------------------------------------------------------
stub 200 '{"wakes":[],"scanned_top":1,"cursor":1,"taken":true}'
( JOBS_URL=""
  rc=0; wakes_claim hub 10 a/b "" >/dev/null || rc=$?; echo "claim=$rc"
  rc=0; wake_cursor_get hub >/dev/null || rc=$?; echo "get=$rc"
  rc=0; wake_cursor_put hub 1 || rc=$?; echo "put=$rc"
  rc=0; wake_cooldown_take k p 60 hub || rc=$?; echo "take=$rc" ) > "$T/c12.out"
want "C12 rcs" "$(tr '\n' ' ' < "$T/c12.out")" "claim=2 get=2 put=2 take=2 "
want "C12 no curl call" "$(req_n)" 0

# ---------- S1-S3 schema -----------------------------------------------------
SCHEMA="$DIR/worker/jobs/schema.sql"
BLOCK="$T/bh2525.sql"
awk '/^-- ── /{on = /BH-2525: wake claims/} on' "$SCHEMA" > "$BLOCK"
[ -s "$BLOCK" ] && ok || bad "S no BH-2525 block in schema.sql"
if command -v python3 >/dev/null && python3 -c 'import sqlite3' 2>/dev/null; then
  out=$(python3 - "$BLOCK" <<'EOF' 2>&1
import sqlite3, sys
block = open(sys.argv[1]).read()
db = sqlite3.connect(":memory:")
db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT NOT NULL)")
for k, v in (("wake-cursor.hub", "120"), ("wake-cursor.small", "abc"), ("other.key", "5")):
    db.execute("INSERT INTO settings VALUES (?, ?, NULL, NULL, 'now')", (k, v))
db.executescript(block)
def q(sql, *a): return db.execute(sql, a).fetchall()
def dup(sql, *a):
    try: db.execute(sql, a); return "inserted"
    except sqlite3.IntegrityError: return "conflict"
print("seed", q("SELECT box, cursor FROM wake_cursors ORDER BY box"))
db.execute("UPDATE wake_cursors SET cursor = 200 WHERE box = 'hub'")
db.executescript(block)
print("reseed", q("SELECT box, cursor FROM wake_cursors ORDER BY box"))
db.execute("INSERT INTO wake_claims VALUES (1, 'hub', 't')")
print("claim other box", dup("INSERT INTO wake_claims VALUES (1, 'small', 't')"))
print("claim same pair", dup("INSERT INTO wake_claims VALUES (1, 'hub', 't')"))
print("cursor same box", dup("INSERT INTO wake_cursors VALUES ('hub', 5, 't')"))
db.execute("INSERT INTO wake_cooldowns VALUES ('review', 'p', 1700000000, 'hub')")
print("cooldown other project", dup("INSERT INTO wake_cooldowns VALUES ('review', 'q', 1, 'hub')"))
print("cooldown same key", dup("INSERT INTO wake_cooldowns VALUES ('review', 'p', 2, 'small')"))
print("last_at", q("SELECT typeof(last_at) FROM wake_cooldowns WHERE project = 'p'"))
print("index", q("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'wake_claims' AND sql IS NOT NULL"))
EOF
  )
  want "S1/S2 sqlite" "$out" "$(cat <<'EOF'
seed [('hub', 120)]
reseed [('hub', 200)]
claim other box inserted
claim same pair conflict
cursor same box conflict
cooldown other project inserted
cooldown same key conflict
last_at [('integer',)]
index [('idx_wake_claims_box_wake',)]
EOF
)"
else
  echo "SKIP: S1/S2 need python3 with sqlite3"
fi
[ "$(grep -ciE '\b(DROP|ALTER)\b' "$BLOCK")" = 0 ] && ok || bad "S3 BH-2525 block carries DROP/ALTER"

echo "wake-claims-client.bh-2635: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
