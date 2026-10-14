#!/bin/bash
# tests/openrouter-ledger.bh-3998-test.sh — BH-3998 (BH-3983.0), the OpenRouter
# gap tracer: bin/lib/openrouter-ledger.sh's or_ledger_compare and the
# read-only CLI bin/openrouter-audit.sh, driven against a PATH curl stub that
# plays the jobs worker's two routes (vendor-spend and cost-rows).
#
#   L1  account delta, claude rows ignored, blank cost counted as unpriced (CLI line 1;
#       the bucketed audit after it is tests/openrouter-audit.bh-4001-test.sh)
#   L2  keys-csv sums only the named keys; no key name or secret is printed
#   L3  a named key missing from b                    -> unread, rc 1
#   L4  only auth-failed vendor rows                  -> no-meter, vendor_usd empty
#   L5  cost-rows read fails (500)                    -> unread, rc 1, `could not read`
#   L6  cumulative goes down                          -> meter-reset
#   L7  a killed:sig= note                            -> killed_n=1
#   L8  vendor read at the 1000-row cap, all after since -> unread
#   L9  CLI with no flags reads the last 7 days
#   L10 global.env with an unbound reference still loads the keys list
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/openrouter-ledger.sh"
CLI="$DIR/bin/openrouter-audit.sh"
NOW=$(python3 -c 'import time; print(int(time.time()))')

export HARNESS="$T/h"
mkdir -p "$HARNESS/env" "$HARNESS/logs" "$T/bin"
: > "$HARNESS/env/global.env"
export JOBS_URL=http://jobs.test HARNESS_SECRET=test-secret-xyz JOBS_RETRIES=0 JOBS_ALERT=0
unset OPENROUTER_RECONCILE_KEYS

# The worker, for the two routes this lib reads. vendor-spend: vendor/since
# filters, newest first, limit clamped to 1000. cost-rows: since/until
# inclusive, newest first, limit clamped to 2000, status from $T/rows.code.
# Anything else is a 404, the worker's "no such thing".
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
exec python3 - "$url" "$STUB_DIR" <<'PY'
import json, os, sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1]); d = sys.argv[2]
q = dict(urllib.parse.parse_qsl(u.query))
def out(body, code):
    sys.stdout.write(body + "\n" + str(code))
if u.path == "/api/metrics/vendor-spend":
    rows = json.load(open(os.path.join(d, "vendor.json")))
    rows = [r for r in rows if (not q.get("vendor") or r.get("vendor") == q["vendor"])
            and (not q.get("since") or r["ts"] >= q["since"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    out(json.dumps({"vendor_spend": rows[:min(int(q.get("limit", 200)), 1000)]}), 200)
elif u.path == "/api/metrics/cost-rows":
    code = open(os.path.join(d, "rows.code")).read().strip() if os.path.exists(os.path.join(d, "rows.code")) else "200"
    if code != "200":
        out('{"error":"boom"}', code); sys.exit(0)
    rows = json.load(open(os.path.join(d, "rows.json")))
    rows = [r for r in rows if (not q.get("since") or r["ts"] >= q["since"])
            and (not q.get("until") or r["ts"] <= q["until"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    out(json.dumps({"cost_rows": rows[:min(int(q.get("limit", 200)), 2000)]}), 200)
else:
    out("", 404)
PY
STUB
chmod +x "$T/bin/curl"
export STUB_DIR="$T" PATH="$T/bin:$PATH"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] in [$2]" ;; *) ok "$1" ;; esac; }

# vendor rows: vrow <ts> <status> <cum|-> [raw-json]
vendor() { python3 - "$@" > "$T/vendor.json" <<'PY'
import json, sys
a = sys.argv[1:]; rows = []
while a:
    ts, st, cum, raw = a[0], a[1], a[2], a[3]; a = a[4:]
    rows.append({"vendor": "openrouter", "ts": ts, "status": st, "usd": None, "kind": "metered",
                 "balance_usd": None, "cumulative_usd": None if cum == "-" else float(cum),
                 "note": "", "raw": None if raw == "-" else raw})
rows.append({"vendor": "xai", "ts": "2026-09-25T00:00:00Z", "status": "ok", "cumulative_usd": 1.0, "raw": None})
json.dump(rows, sys.stdout)
PY
}
# cost rows: crow <ts> <runner> <cost|""> <note>
rows() { python3 - "$@" > "$T/rows.json" <<'PY'
import json, sys
a = sys.argv[1:]; rows = []; n = 0
while a:
    ts, runner, cost, note = a[:4]; a = a[4:]; n += 1
    rows.append({"box": "hub", "row_hash": "h%d" % n, "ts": ts, "host": "h", "project": "p", "stage": "prd",
                 "runner": runner, "model": "m", "rc": 0, "cost_usd": None if cost == "" else float(cost),
                 "note": note})
json.dump(rows, sys.stdout)
PY
}
lib() { ( . "$LIB" && or_ledger_compare "$@" ); }

S=2026-09-21T00:00:00Z; U=2026-10-03T23:59:59Z
L1_ROWS=(2026-09-25T00:00:00Z openrouter 100.00 ""
         2026-09-26T00:00:00Z claude 500.00 ""
         2026-09-27T00:00:00Z openrouter "" ""
         2026-09-28T00:00:00Z openrouter "" ""
         2026-10-03T23:30:00Z openrouter 999.00 "")   # after b.ts: outside the vendor span

# ── L1 ──
vendor 2026-09-20T23:00:00Z ok 1000.00 - 2026-10-03T23:00:00Z ok 1200.00 - 2026-10-02T00:00:00Z error - -
rows "${L1_ROWS[@]}"
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "L1 CLI line 1" "$(head -1 <<<"$out")" "openrouter scope=account state=ok vendor_usd=200.00 rows_usd=100.00 rows_n=3 unpriced_n=2 killed_n=0 span=2026-09-20T23:00:00Z..2026-10-03T23:00:00Z"
check "L1 CLI rc 0" "$rc" 0
out=$(lib "$S" "$U"); rc=$?
check "L1 lib prints exactly one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
check "L1 lib rc 0" "$rc" 0
has "L1 lib line" "$out" "scope=account state=ok vendor_usd=200.00"

# ── L2 ──
RA='{"credits":{},"keys":[{"name":"harness-a","usage":50},{"name":"project-4-app","usage":0}],"keys_total":2}'
RB='{"credits":{},"keys":[{"name":"project-4-app","usage":900},{"name":"harness-a","usage":150}],"keys_total":2}'
vendor 2026-09-20T23:00:00Z ok 1000.00 "$RA" 2026-10-03T23:00:00Z ok 1900.00 "$RB"
out=$(OPENROUTER_RECONCILE_KEYS=harness-a "$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
has "L2 harness-keys sum" "$out" "openrouter scope=harness-keys state=ok vendor_usd=100.00 "
check "L2 rc 0" "$rc" 0
# Since BH-4001 the lines after line 1 name keys (the per-key table); the
# tracer's own line and stderr still name none.
all="$(head -1 <<<"$out") $(cat "$T/err")"
hasnt "L2 no harness-a printed" "$all" harness-a
hasnt "L2 no project-4-app printed" "$all" project-4-app
hasnt "L2 no secret printed" "$out $(cat "$T/err")" test-secret-xyz

# ── L3 ──
RB3='{"keys":[{"name":"project-4-app","usage":900}]}'
vendor 2026-09-20T23:00:00Z ok 1000.00 "$RA" 2026-10-03T23:00:00Z ok 1900.00 "$RB3"
out=$(lib "$S" "$U" harness-a); rc=$?
has "L3 missing key is unread" "$out" "state=unread vendor_usd= "
check "L3 rc 1" "$rc" 1
out=$(OPENROUTER_RECONCILE_KEYS=harness-a "$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "L3 CLI rc 1" "$rc" 1

# ── L4 ──
vendor 2026-09-20T23:00:00Z auth-failed - - 2026-10-03T23:00:00Z auth-failed - -
out=$(lib "$S" "$U"); rc=$?
has "L4 no-meter, empty vendor_usd" "$out" "state=no-meter vendor_usd= "
check "L4 rc 0" "$rc" 0
vendor 2026-10-03T23:00:00Z ok 1200.00 -
out=$(lib "$S" "$U"); rc=$?
has "L4 a single ok row is no-meter" "$out" "state=no-meter vendor_usd= "
vendor 2026-09-20T22:00:00Z ok 1000.00 - 2026-09-20T23:00:00Z ok 1200.00 -
out=$(lib "$S" "$U"); rc=$?
check "L4 no ok row inside the window is no-meter" "$out" "scope=account state=no-meter vendor_usd= rows_usd= rows_n= unpriced_n= killed_n= span="

# ── L5 ──
vendor 2026-09-20T23:00:00Z ok 1000.00 - 2026-10-03T23:00:00Z ok 1200.00 -
rows "${L1_ROWS[@]}"
echo 500 > "$T/rows.code"
out=$(lib "$S" "$U"); rc=$?
has "L5 failed rows read is unread" "$out" "state=unread"
has "L5 rows_usd empty, not zero" "$out" " rows_usd= rows_n= unpriced_n= killed_n= "
check "L5 lib rc 1" "$rc" 1
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "L5 CLI rc 1" "$rc" 1
has "L5 CLI says could not read" "$(cat "$T/err")" "could not read"
hasnt "L5 no rows_usd=0" "$out" "rows_usd=0"
rm -f "$T/rows.code"

# ── L6 ──
vendor 2026-09-20T23:00:00Z ok 1200.00 - 2026-10-03T23:00:00Z ok 1100.00 -
out=$(lib "$S" "$U"); rc=$?
has "L6 meter-reset" "$out" "state=meter-reset vendor_usd= rows_usd=100.00"
check "L6 rc 0" "$rc" 0

# ── L7 ──
vendor 2026-09-20T23:00:00Z ok 1000.00 - 2026-10-03T23:00:00Z ok 1200.00 -
rows 2026-09-25T00:00:00Z openrouter 3.00 "killed:sig=TERM after 600s" 2026-09-26T00:00:00Z openrouter 1.00 ""
out=$(lib "$S" "$U")
has "L7 killed note counted" "$out" "rows_usd=4.00 rows_n=2 unpriced_n=0 killed_n=1 "

# ── L8 ──
python3 - > "$T/vendor.json" <<'PY'
import json
rows = [{"vendor": "openrouter", "ts": "2026-09-22T%02d:%02d:%02dZ" % ((i + 1) // 3600, (i + 1) // 60 % 60, (i + 1) % 60),
         "status": "ok", "cumulative_usd": 1000.0 + i, "raw": None} for i in range(1000)]
# the real `a`: inside the 6h lookback, so the worker holds it, but behind the cap
rows.append({"vendor": "openrouter", "ts": "2026-09-21T20:00:00Z", "status": "ok", "cumulative_usd": 900.0, "raw": None})
json.dump(rows, open("/dev/stdout", "w"))
PY
out=$(lib 2026-09-22T00:00:00Z 2026-09-22T23:59:59Z); rc=$?
has "L8 capped vendor read is unread" "$out" "state=unread vendor_usd= "
check "L8 rc 1" "$rc" 1

# ── L9 ──
iso() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }
A9=$(iso $((NOW - 7*86400 + 3600))); B9=$(iso $((NOW - 3600))); WK=$(iso $((NOW - 7*86400 - 120)))
vendor "$A9" ok 10.00 - "$B9" ok 12.50 -
rows "$(iso $((NOW - 86400)))" openrouter 2.00 ""
out=$("$CLI" 2>"$T/err"); rc=$?
check "L9 no-flag CLI rc 0" "$rc" 0
check "L9 no-flag CLI reads the last 7 days" "$(head -1 <<<"$out")" "openrouter scope=account state=ok vendor_usd=2.50 rows_usd=2.00 rows_n=1 unpriced_n=0 killed_n=0 span=$A9..$B9"
[[ "$A9" > "$WK" ]] && ok "L9 span starts inside the last 7 days" || bad "L9 span start" "$A9 vs $WK"

# ── L10 ──
vendor 2026-09-20T23:00:00Z ok 1000.00 "$RA" 2026-10-03T23:00:00Z ok 1900.00 "$RB"
rows "${L1_ROWS[@]}"
printf 'X=$UNBOUND_THING\nOPENROUTER_RECONCILE_KEYS=harness-a\n' > "$HARNESS/env/global.env"
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "L10 rc 0 with an unbound reference in global.env" "$rc" 0
has "L10 keys from global.env" "$out" "scope=harness-keys state=ok vendor_usd=100.00"
: > "$HARNESS/env/global.env"

# ── usage ──
"$CLI" --bogus >/dev/null 2>&1; rc=$?
check "unknown flag exits 2" "$rc" 2

echo "openrouter-ledger: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
