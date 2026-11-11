#!/bin/bash
# tests/alerts-supersede-digest.bh-9114-test.sh — bin/alerts-supersede.py closes
# warn-digest rows and posts its resolves in chunks (BH-9114).
#
# A warn digest (bin/alert-digest.sh --warn-batch) beats one console row with
# akey warnbatch:<box>:<ts>:<pid>. The single warns it batches are rows of their
# own, so every warn was counted twice, for 48h (about 157 open rows on
# 2026-11-05). The groom's supersede pass is the backstop that closes them.
#   G1 warnbatch:* rows are resolved with reason "digest"
#   G2 near misses (another prefix, case, an empty akey with the digest TEXT)
#      are not resolved by the digest rule
#   G3 250 resolvable rows go out as 3 POSTs of at most 100 ids
#   G4 --dry posts nothing
#   G5 the other resolves keep today's body {"ids":[...]} (no reason key)
#   G6 ALERTS_OPEN_FILE is the open set when it is set (no GET)
# The REAL script talks to a local fake console (python http.server on
# 127.0.0.1, port 0): no network beyond loopback, no vendor.
# Run from anywhere: tests/alerts-supersede-digest.bh-9114-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

mkdir -p "$T/srv" "$T/h/state"
# The fake console: GET /api/alerts/open serves open.json and logs the GET;
# POST /api/alerts/resolve appends its body to posts.jsonl.
cat > "$T/srv/fake.py" <<'PY'
import http.server, json, os, sys
root = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, body):
        b = body.encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        with open(os.path.join(root, "gets.txt"), "a") as f: f.write(self.path + "\n")
        self._send(open(os.path.join(root, "open.json")).read())
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n).decode()
        with open(os.path.join(root, "posts.jsonl"), "a") as f: f.write(body + "\n")
        self._send(json.dumps({"resolved": len(json.loads(body).get("ids", []))}))
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(os.path.join(root, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY
( trap - EXIT; exec python3 -I "$T/srv/fake.py" "$T/srv" ) & SRV=$!
__sd_exit() { local rc=$?
              [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
              kill "$SRV" 2>/dev/null; scratch_cleanup; exit "$rc"; }
trap __sd_exit EXIT
i=0; while [ ! -s "$T/srv/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$T/srv/port" ] || { echo "FAIL: the fake console did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$T/srv/port")"

# One fixed timestamp an hour old: well inside the 72h TTL, so only the rule under test closes a row.
TS=$(python3 -I -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')
DLINE='Alerts (warn) on hub, last batch: 2 condition(s), 3 event(s). None of these page on their own; this is the batched cadence.'
row() { jq -nc --argjson i "$1" --arg k "$2" --arg l "$3" --arg t "$TS" '{id:$i,akey:$k,project:"fleet",line:$l,createdAt:$t}'; }
openset() { jq -sc '{alerts:.}' > "$T/srv/open.json"; cp "$T/srv/open.json" "$T/h/open.json"; }
run() { : > "$T/srv/posts.jsonl"; : > "$T/srv/gets.txt"
  CONSOLE_URL="$URL" HARNESS_SECRET=fixture-secret HARNESS="$T/h" "$@" > "$T/out.txt" 2>&1; }
reason_ids() { jq -r --arg r "$1" 'select((.reason // "") == $r) | .ids[] | tostring' "$T/srv/posts.jsonl" 2>/dev/null | sort -n | tr '\n' ' '; }

# ── G1 + G2 ─────────────────────────────────────────────────────────────────
{
  row 1 "warnbatch:hub:20261105120000:4021" "$DLINE"
  row 2 "warnbatch:unknown-box:20261105120000:9" "$DLINE"
  row 3 "warnbatch:orgo-3:20261104000000:1" "$DLINE"
  row 4 "alert:warnbatch-x" "a real alert about warnbatch-x"
  row 5 "orclane:warnbatch:hub:1" "an orchestrator lane line"
  row 6 "warnbatchx:hub:1" "a different key family"
  row 7 "WARNBATCH:hub:1" "upper case is a different key"
  row 8 "triage:warnbatch:1" "a triage escalation"
  row 9 "" "$DLINE"
} | openset
run env ALERTS_OPEN_FILE="$T/h/open.json" python3 "$DIR/bin/alerts-supersede.py"
[ "$(reason_ids digest)" = "1 2 3 " ] && ok \
  || bad "G1/G2 exactly the three warnbatch: rows must be resolved with reason digest, got '$(reason_ids digest)': $(cat "$T/srv/posts.jsonl") :: $(cat "$T/out.txt")"
grep -qx 'digest resolve=3' "$T/out.txt" && grep -q '^open=9 resolve=3 remaining=6$' "$T/out.txt" && ok \
  || bad "G1 the summary lines must count the digest resolves: $(cat "$T/out.txt")"
# G6: the file is the open set, so no GET reached the console
[ ! -s "$T/srv/gets.txt" ] && ok || bad "G6 with ALERTS_OPEN_FILE set, supersede must not GET /open: $(cat "$T/srv/gets.txt")"

# ── G3 250 digest rows: chunks of at most 100 ───────────────────────────────
for n in $(seq 1001 1250); do row "$n" "warnbatch:hub:20261105120000:$n" "$DLINE"; done | openset
run env ALERTS_OPEN_FILE="$T/h/open.json" python3 "$DIR/bin/alerts-supersede.py"
SIZES=$(jq -c '.ids | length' "$T/srv/posts.jsonl" 2>/dev/null | tr '\n' ' ')
TOTAL=$(jq -r '.ids[]' "$T/srv/posts.jsonl" 2>/dev/null | sort -u | grep -c .)
[ "$SIZES" = "100 100 50 " ] && [ "$TOTAL" = 250 ] && ok \
  || bad "G3 250 ids must go out as 3 POSTs of at most 100 (sizes '$SIZES', distinct $TOTAL): $(cat "$T/out.txt")"
# and the chunk is a knob
run env ALERTS_OPEN_FILE="$T/h/open.json" ALERTS_GROOM_RESOLVE_CHUNK=60 python3 "$DIR/bin/alerts-supersede.py"
[ "$(grep -c . "$T/srv/posts.jsonl")" = 5 ] && ok || bad "G3 ALERTS_GROOM_RESOLVE_CHUNK=60 must give 5 POSTs: $(jq -c '.ids|length' "$T/srv/posts.jsonl" | tr '\n' ' ')"
run env ALERTS_OPEN_FILE="$T/h/open.json" ALERTS_GROOM_RESOLVE_CHUNK=500 python3 "$DIR/bin/alerts-supersede.py"
[ "$(grep -c . "$T/srv/posts.jsonl")" = 3 ] && grep -q 'ALERTS_GROOM_RESOLVE_CHUNK=500' "$T/out.txt" && ok \
  || bad "G3 a chunk over 100 must mean 100, said once: $(cat "$T/out.txt")"

# ── G4 --dry posts nothing ──────────────────────────────────────────────────
run env ALERTS_OPEN_FILE="$T/h/open.json" python3 "$DIR/bin/alerts-supersede.py" --dry
[ ! -s "$T/srv/posts.jsonl" ] && grep -qx 'digest resolve=250' "$T/out.txt" && ok \
  || bad "G4 --dry must post nothing and still count: $(cat "$T/srv/posts.jsonl") :: $(cat "$T/out.txt")"

# ── G5 the other reasons keep today's body ──────────────────────────────────
{
  row 21 "warnbatch:hub:20261105120000:21" "$DLINE"
  row 22 "alert:x22" "2026-11-05 10:00:00Z [lane] job finished rc=0, see logs/x.log"
} | openset
run env ALERTS_OPEN_FILE="$T/h/open.json" python3 "$DIR/bin/alerts-supersede.py"
[ "$(reason_ids digest)" = "21 " ] \
  && [ "$(jq -c 'select(has("reason")|not)' "$T/srv/posts.jsonl")" = '{"ids":["22"]}' ] && ok \
  || bad "G5 a non-digest resolve keeps the body {\"ids\":[...]} with no reason: $(cat "$T/srv/posts.jsonl")"

# ── G6 unset: today's GET is the open set ───────────────────────────────────
run python3 "$DIR/bin/alerts-supersede.py"
[ "$(grep -c '/api/alerts/open' "$T/srv/gets.txt")" = 1 ] && [ "$(reason_ids digest)" = "21 " ] && ok \
  || bad "G6 with no ALERTS_OPEN_FILE, supersede reads GET /open as before: $(cat "$T/srv/gets.txt") :: $(cat "$T/out.txt")"

echo "alerts-supersede-digest.bh-9114: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
