#!/bin/bash
# tests/alerts-groom-paging.bh-9114-test.sh — bin/alerts-groom.sh reads EVERY
# open console row, oldest first, with an id cursor (BH-9114).
#
# The console's GET /api/alerts/open answers the newest 500 rows and ignores
# every paging parameter, so with 861 open rows the groom never looked at the
# oldest 361. The read now pages through D1 (bin/lib/alerts-open-read.sh) and
# keeps the API as the fallback.
#   P1  700 open rows, page 500: 2 D1 queries (cursor 0, then the 500th id),
#       log rows=700 pages=2 complete=1, supersede gets 700 minus the groom's own
#   P1b exactly 500 rows: 2 queries, the second answers 0
#   P2  ALERTS_GROOM_PAGE_SIZE=300: 3 queries
#   P3  no cloudflare.env: source=api why=no-cloudflare-env, one GET
#   P4  HTTP 500 on page 2: source=api, and no D1 row in the set
#   P5  a cursor that did not advance: the api fallback
#   P6  ALERTS_GROOM_MAX_PAGES=1: complete=0 rows=500
#   P7  230 groom resolves: 3 POSTs of at most 100 ids
#   P8  the Cloudflare token is in no argv and in no log
#   P9  EXPLAIN QUERY PLAN of the SQL the lib SENT, on a seeded 60k-row table:
#       the integer primary key, no bare SCAN
# The REAL groom and lib run with curl and gh as PATH stubs: 0 network calls.
# Run from anywhere: tests/alerts-groom-paging.bh-9114-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

[ -r "$DIR/bin/lib/alerts-open-read.sh" ] || { echo "FAIL: bin/lib/alerts-open-read.sh is missing"; exit 1; }
TOK=tok-fixture-TK-9114
mkdir -p "$T/env" "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/stub" "$T/bin/lib" "$T/fx"
export HARNESS="$T" PATH="$T/stub:$PATH" FLEET_CONF="$T/fleet.conf"
cat > "$FLEET_CONF" <<'CONF'
project-4    example-org/project-4    - - 8 box-project-4-1 192.0.2.2
CONF
ln -sf "$DIR/bin/fleet-conf.sh" "$T/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fleet-projects-or-alert.sh"
printf '#!/bin/bash\necho ""\n' > "$T/bin/project-of.sh"
printf '#!/bin/bash\necho local\n' > "$T/bin/box-for.sh"
# supersede is a recorder: what it receives is the groom's hand-off, not its rules.
cat > "$T/bin/alerts-supersede.py" <<PY
import os, shutil
f = os.environ.get("ALERTS_OPEN_FILE")
if f: shutil.copy(f, "$T/supersede-saw.json")
PY
chmod +x "$T/bin/fleet-projects-or-alert.sh" "$T/bin/project-of.sh" "$T/bin/box-for.sh"
# Every mq-conflict row names one of five project-4 PRs, all MERGED: rule 1 settles it.
printf '#!/bin/bash\necho MERGED\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
# curl: the D1 query endpoint pages fx/d1.json by (id > cursor ORDER BY id LIMIT n);
# the console answers /open from fx/api.json and records /resolve bodies.
cat > "$T/stub/curl.py" <<'PY'
import json, os, sys
T = os.environ["STUB_T"]
args = sys.argv[1:]
with open(os.path.join(T, "argv.log"), "a") as f: f.write(" ".join(args) + "\n")
url = next((a for a in args if a.startswith("http")), "")
def opt(name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None
out, wfmt = opt("-o"), opt("-w")
def emit(body, code=200):
    if out:
        open(out, "w").write(body)
    else:
        sys.stdout.write(body)
    if wfmt: sys.stdout.write(str(code))
if "/d1/database/" in url:
    sys.stdin.read()  # the bearer header arrives on stdin (-H @-), never in argv
    data = opt("--data-binary") or ""
    q = json.load(open(data[1:])) if data.startswith("@") else json.loads(data)
    with open(os.path.join(T, "d1q.jsonl"), "a") as f: f.write(json.dumps(q) + "\n")
    n = sum(1 for _ in open(os.path.join(T, "d1q.jsonl")))
    if os.environ.get("D1_FAIL_PAGE") == str(n): emit('{"success":false}', 500); sys.exit(0)
    rows = sorted(json.load(open(os.path.join(T, "fx", "d1.json"))), key=lambda r: r["id"])
    cur, lim = int(q["params"][0]), int(q["params"][1])
    if os.environ.get("D1_STUCK") == "1": cur = 0
    page = [r for r in rows if r["id"] > cur][:lim]
    emit(json.dumps({"success": True, "result": [{"success": True, "results": page}]}))
elif url.endswith("/api/alerts/open"):
    with open(os.path.join(T, "gets.txt"), "a") as f: f.write(url + "\n")
    emit(open(os.path.join(T, "fx", "api.json")).read())
elif url.endswith("/api/alerts/resolve"):
    with open(os.path.join(T, "posts.jsonl"), "a") as f: f.write(opt("-d") + "\n")
    emit('{"resolved":1}')
else:
    emit("{}")
PY
printf '#!/bin/bash\nSTUB_T="%s" exec python3 -I "%s/stub/curl.py" "$@"\n' "$T" "$T" > "$T/stub/curl"
chmod +x "$T/stub/curl"

# fx_d1 <n> <mq> — n open rows (ids 1000, 1003, ...: gaps on purpose), the first mq of them settle.
fx_d1() { python3 -I - "$1" "$2" > "$T/fx/d1.json" <<'PY'
import json, sys
n, mq = int(sys.argv[1]), int(sys.argv[2])
rows = []
for k in range(n):
    i = 1000 + 3 * k
    if k < mq:
        rows.append({"id": i, "akey": "mq-conflict:project-4:%d" % (100 + k % 5), "project": "project-4",
                     "line": "Merge queue: semantic conflict with main, needs a hand", "ts": "2026-11-05T10:00:00.000Z"})
    else:
        rows.append({"id": i, "akey": "alert:note-%d" % k, "project": "fleet",
                     "line": "routine note %d" % k, "ts": "2026-11-05T10:00:00.000Z"})
print(json.dumps(rows))
PY
}
# The API's own answer: 500 rows with ids no D1 fixture uses (900000+).
python3 -I -c 'import json;print(json.dumps({"alerts":[{"id":900000+k,"akey":"alert:api-%d"%k,"project":"fleet","line":"api row %d"%k,"createdAt":"2026-11-05T10:00:00.000Z"} for k in range(500)]}))' > "$T/fx/api.json"

GENV="CONSOLE_URL=https://console.invalid
HARNESS_SECRET=fixture-secret
CLOUDFLARE_ACCOUNT_ID=acct-fixture"
printf '%s\n' "$GENV" > "$T/env/global.env"
cfenv_on()  { printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOK" > "$T/env/cloudflare.env"; }
cfenv_off() { rm -f "$T/env/cloudflare.env"; }
groom() {
  rm -f "$T/d1q.jsonl" "$T/gets.txt" "$T/posts.jsonl" "$T/supersede-saw.json" "$T/locks/"*
  : > "$T/logs/alerts-groom.log"
  ( for kv in "$@"; do export "${kv?}"; done
    bash "$DIR/bin/alerts-groom.sh" ) >/dev/null 2>&1
}
readline() { grep 'open read:' "$T/logs/alerts-groom.log" | tail -1; }
q_count() { local n; n=$(grep -c . "$T/d1q.jsonl" 2>/dev/null); printf '%s' "${n:-0}"; }
cursors() { jq -r '.params[0]' "$T/d1q.jsonl" 2>/dev/null | tr '\n' ' '; }
saw_n() { jq '.alerts | length' "$T/supersede-saw.json" 2>/dev/null; }

# ── P1 + P7 + P8 ────────────────────────────────────────────────────────────
cfenv_on; fx_d1 700 230
groom
ID500=$(jq '.[499].id' "$T/fx/d1.json")
[ "$(q_count)" = 2 ] && [ "$(cursors)" = "0 $ID500 " ] && ok \
  || bad "P1 700 rows at page 500 must be 2 D1 queries with cursors 0 and $ID500, got $(q_count) '$(cursors)'"
grep -q 'open read: source=d1 rows=700 pages=2 complete=1$' "$T/logs/alerts-groom.log" && ok \
  || bad "P1 the log must say source=d1 rows=700 pages=2 complete=1: $(cat "$T/logs/alerts-groom.log")"
[ ! -s "$T/gets.txt" ] && ok || bad "P1 a complete D1 read must not also GET /open: $(cat "$T/gets.txt")"
POSTED=$(jq -r '.ids[] | tostring' "$T/posts.jsonl" 2>/dev/null | sort -u)
[ "$(grep -c . <<<"$POSTED")" = 230 ] && ok || bad "P1 the groom must resolve all 230 settled rows, got $(grep -c . <<<"$POSTED")"
SAWIDS=$(jq -r '.alerts[].id | tostring' "$T/supersede-saw.json" 2>/dev/null | sort -u)
[ "$(saw_n)" = 470 ] && [ -z "$(comm -12 <(printf '%s\n' "$POSTED") <(printf '%s\n' "$SAWIDS"))" ] \
  && [ "$(jq -r '.alerts[-1].id' "$T/supersede-saw.json")" = "$(jq '.[699].id' "$T/fx/d1.json")" ] \
  && [ "$(jq -r '.alerts[0].createdAt' "$T/supersede-saw.json")" = "2026-11-05T10:00:00.000Z" ] && ok \
  || bad "P1 supersede must get the 700 rows minus the groom's 230 (with createdAt), got $(saw_n)"
SIZES=$(jq -c '.ids | length' "$T/posts.jsonl" 2>/dev/null | tr '\n' ' ')
[ "$SIZES" = "100 100 30 " ] && ok || bad "P7 230 resolves must go out as 100 100 30, got '$SIZES'"
grep -qF "$TOK" "$T/argv.log" && bad "P8 the Cloudflare token reached a curl argv" || ok
grep -qF "$TOK" "$T/logs/alerts-groom.log" && bad "P8 the Cloudflare token reached alerts-groom.log" || ok
[ -s "$T/argv.log" ] && grep -q 'd1/database' "$T/argv.log" && ok || bad "P8 fixture: the D1 calls were not recorded"
cp "$T/d1q.jsonl" "$T/sent-sql.jsonl"
# a resolve chunk knob is read
groom ALERTS_GROOM_RESOLVE_CHUNK=50
[ "$(jq -c '.ids | length' "$T/posts.jsonl" 2>/dev/null | tr '\n' ' ')" = "50 50 50 50 30 " ] && ok \
  || bad "P7 ALERTS_GROOM_RESOLVE_CHUNK=50 must give 50 50 50 50 30: $(jq -c '.ids|length' "$T/posts.jsonl" | tr '\n' ' ')"

# ── P1b exactly one full page ───────────────────────────────────────────────
fx_d1 500 0
groom
[ "$(q_count)" = 2 ] && grep -q 'open read: source=d1 rows=500 pages=2 complete=1$' "$T/logs/alerts-groom.log" && ok \
  || bad "P1b exactly 500 rows must read a second, empty page: $(q_count) :: $(readline)"

# ── P2 the page size is a knob ──────────────────────────────────────────────
fx_d1 700 0
groom ALERTS_GROOM_PAGE_SIZE=300
[ "$(q_count)" = 3 ] && [ "$(jq -r '.params[1]' "$T/d1q.jsonl" | sort -u)" = 300 ] \
  && grep -q 'rows=700 pages=3 complete=1$' "$T/logs/alerts-groom.log" && ok \
  || bad "P2 page 300 must be 3 queries of LIMIT 300: $(q_count) :: $(readline)"
groom ALERTS_GROOM_PAGE_SIZE=abc
[ "$(q_count)" = 2 ] && grep -q 'ALERTS_GROOM_PAGE_SIZE=abc' "$T/logs/alerts-groom.log" && ok \
  || bad "P2 an invalid page size means 500, with a log line: $(q_count) :: $(cat "$T/logs/alerts-groom.log")"

# ── P3 no cloudflare.env: today's single GET ────────────────────────────────
cfenv_off
groom
grep -q 'open read: source=api rows=500 pages=0 complete=0 why=no-cloudflare-env$' "$T/logs/alerts-groom.log" \
  && [ "$(grep -c . "$T/gets.txt")" = 1 ] && [ "$(q_count)" = 0 ] && [ "$(saw_n)" = 500 ] && ok \
  || bad "P3 no cloudflare.env must fall back to one GET: $(readline) :: gets $(cat "$T/gets.txt" 2>/dev/null)"

# ── P4 a failed page: the whole D1 read is dropped ──────────────────────────
cfenv_on; fx_d1 700 0
groom D1_FAIL_PAGE=2
MIN=$(jq '[.alerts[].id] | min' "$T/supersede-saw.json" 2>/dev/null)
readline | grep -q 'source=api .*why=d1-http-500' && [ "${MIN:-0}" -ge 900000 ] && [ "$(saw_n)" = 500 ] && ok \
  || bad "P4 HTTP 500 on page 2 must give the api set and no D1 row: $(readline) :: min id $MIN"

# ── P5 a cursor that did not advance ────────────────────────────────────────
groom D1_STUCK=1
readline | grep -q 'source=api .*why=d1-cursor-stuck' && [ "$(grep -c . "$T/gets.txt")" = 1 ] && ok \
  || bad "P5 a cursor that does not advance must fall back to the api: $(readline)"

# ── P6 the page cap ─────────────────────────────────────────────────────────
groom ALERTS_GROOM_MAX_PAGES=1
grep -q 'open read: source=d1 rows=500 pages=1 complete=0' "$T/logs/alerts-groom.log" && [ "$(q_count)" = 1 ] \
  && [ "$(saw_n)" = 500 ] && ok \
  || bad "P6 MAX_PAGES=1 must stop at 500 rows with complete=0: $(readline)"

# ── P9 the SQL the lib sent uses the primary key ────────────────────────────
PLAN=$(python3 -I - "$T/sent-sql.jsonl" <<'PY'
import json, sqlite3, sys
q = json.loads(open(sys.argv[1]).readline())
db = sqlite3.connect(":memory:")
# The console's alerts shape (console-ui/functions/api/cockpit reads these columns).
db.execute("CREATE TABLE alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, akey TEXT, ts TEXT, project TEXT, line TEXT, resolved INTEGER NOT NULL DEFAULT 0)")
db.executemany("INSERT INTO alerts (akey, ts, project, line, resolved) VALUES (?,?,?,?,?)",
               [("k%d" % i, "2026-11-05T10:00:00Z", "fleet", "line %d" % i, 0 if i % 67 == 0 else 1) for i in range(60000)])
print(" | ".join(r[-1] for r in db.execute("EXPLAIN QUERY PLAN " + q["sql"], q["params"])))
PY
)
grep -q 'USING INTEGER PRIMARY KEY' <<<"$PLAN" && ! grep -qE 'SCAN alerts($| \|)' <<<"$PLAN" && ok \
  || bad "P9 the page query must use the integer primary key, not a bare scan: $PLAN"

echo "alerts-groom-paging.bh-9114: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
