#!/bin/bash
# tests/openrouter-audit.bh-4001-test.sh — BH-4001 (BH-3983.3), the bucketed
# OpenRouter audit: bin/openrouter-audit.sh's per-key, per day x model and
# per-request sections and its four buckets, driven as shipped against a PATH
# curl stub that plays the jobs worker (vendor-spend, cost-rows) and
# OpenRouter's /api/v1/activity, logging every URL it is asked for.
#
#   A1  buckets: other-keys $900, unpriced-rows 2, residual $40; line 1 is the tracer's
#   A2  no management key -> activity skipped, no /api/v1/activity call
#   A3  activity join lists only the one day x model cell the rows miss
#   A4  --export: the request 5% off on tokens is the one unmatched
#   A5  cost-rows 500 (tracer's read, then the audit's own read) -> could not read, rc 1, no table
#   A6  the management key never reaches stdout or stderr
#   A7  an other-class key missing from b is unreadable, in no bucket, never 0;
#       a harness key missing from b is the tracer's unread -> could not read
#   A8  killed-no-row: one rc=143 failovers line in the window + one reaped openrouter dir
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$DIR/bin/openrouter-audit.sh"
SECRET=sk-or-v1-secretfixture

export HARNESS="$T/h"
mkdir -p "$HARNESS/env" "$HARNESS/logs" "$HARNESS/builds" "$T/bin" "$T/fx"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=test-secret-xyz\n' > "$HARNESS/env/global.env"
export JOBS_URL=http://jobs.test HARNESS_SECRET=test-secret-xyz JOBS_RETRIES=0 JOBS_ALERT=0
export ENDPOINT_OPENROUTER=http://or.test CURL_LOG="$T/curl.log"
unset OPENROUTER_RECONCILE_KEYS OPENROUTER_PROVISIONING_KEY OPENROUTER_API_KEY

# jobs.test: vendor-spend (vendor/since filters, newest first, limit <= 1000) and
# cost-rows (since/until inclusive, newest first, limit <= 2000; $T/rows.code is
# its status, $T/rows.okcalls how many calls answer 200 before that status).
# or.test: /api/v1/activity?date=D from fx/activity-D.{code,body}, 401 without
# the fixture management key. `-o <file>` writes the body there and prints only
# the status, like real curl with -w '%{http_code}'.
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
url="" ofile="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile="$2"; shift ;;
    -H) case "$2" in [Aa]uthorization:*) auth="$2" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$CURL_LOG"
exec python3 - "$url" "$STUB_DIR" "$ofile" "$auth" <<'PY'
import json, os, sys, urllib.parse
u = urllib.parse.urlsplit(sys.argv[1]); d, ofile, auth = sys.argv[2:5]
q = dict(urllib.parse.parse_qsl(u.query))
def out(body, code):
    if ofile:
        open(ofile, "w").write(body); sys.stdout.write(str(code))
    else:
        sys.stdout.write(body + "\n" + str(code))
def rd(name, dflt=None):
    p = os.path.join(d, name)
    return open(p).read().strip() if os.path.exists(p) else dflt
if u.netloc == "or.test" and u.path == "/api/v1/activity":
    if auth != "Authorization: Bearer sk-or-v1-secretfixture":
        out('{"error":"unauthorized"}', 401); sys.exit(0)
    out(rd("fx/activity-%s.body" % q.get("date"), '{"data":[]}'), rd("fx/activity-%s.code" % q.get("date"), "200"))
elif u.path == "/api/metrics/vendor-spend":
    rows = json.load(open(os.path.join(d, "vendor.json")))
    rows = [r for r in rows if (not q.get("vendor") or r.get("vendor") == q["vendor"])
            and (not q.get("since") or r["ts"] >= q["since"])]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    out(json.dumps({"vendor_spend": rows[:min(int(q.get("limit", 200)), 1000)]}), 200)
elif u.path == "/api/metrics/cost-rows":
    code = rd("rows.code", "200")
    okc = rd("rows.okcalls")
    if okc is not None:
        n = int(rd("rows.calls", "0")) + 1
        open(os.path.join(d, "rows.calls"), "w").write(str(n))
        if n <= int(okc):
            code = "200"
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
jqv() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$2" 2>&1; }

# vendor <ts> <cum> <raw-json|-> ...
vendor() { python3 - "$@" > "$T/vendor.json" <<'PY'
import json, sys
a = sys.argv[1:]; rows = []
while a:
    ts, cum, raw = a[:3]; a = a[3:]
    rows.append({"vendor": "openrouter", "ts": ts, "status": "ok", "usd": None, "kind": "metered",
                 "cumulative_usd": float(cum), "note": "", "raw": None if raw == "-" else raw})
json.dump(rows, sys.stdout)
PY
}
# rows <ts> <runner> <model> <input_toks> <cost|""> <note> ...
rows() { python3 - "$@" > "$T/rows.json" <<'PY'
import json, sys
a = sys.argv[1:]; rows = []; n = 0
while a:
    ts, runner, model, toks, cost, note = a[:6]; a = a[6:]; n += 1
    rows.append({"box": "hub", "row_hash": "h%d" % n, "ts": ts, "host": "hub", "project": "cromford",
                 "stage": "build", "runner": runner, "model": model, "rc": 0, "input_toks": int(toks),
                 "cost_usd": None if cost == "" else float(cost), "note": note})
json.dump(rows, sys.stdout)
PY
}
activity() { # activity <date> <model> <usd> ...
  local d="$1"; shift
  python3 - "$d" "$@" > "$T/fx/activity-$d.body" <<'PY'
import json, sys
d, a = sys.argv[1], sys.argv[2:]; data = []
while a:
    m, u = a[:2]; a = a[2:]
    data.append({"date": d, "model": m, "model_permaslug": m, "endpoint_id": "e", "provider_name": "p",
                 "usage": float(u), "byok_usage_inference": 0, "requests": 1,
                 "prompt_tokens": 1, "completion_tokens": 1, "reasoning_tokens": 0})
json.dump({"data": data}, sys.stdout)
PY
}

S=2026-10-01T00:00:00Z; U=2026-10-02T23:59:59Z
RA='{"credits":{},"keys":[{"name":"harness-a","usage":50,"limit":null},{"name":"project-4-app","usage":0}],"keys_total":2}'
RB='{"credits":{},"keys":[{"name":"project-4-app","usage":900},{"name":"harness-a","usage":150}],"keys_total":2}'
vendor 2026-09-30T23:00:00Z 1000 "$RA" 2026-10-02T23:00:00Z 2000 "$RB"
# $60 priced over three day x model cells, two unpriced, one claude row ignored
rows 2026-10-01T10:00:00Z openrouter openrouter/OpenAI/gpt-x 1000 25.00 "" \
     2026-10-01T11:00:00Z openrouter anthropic/claude-y 2000 10.00 "" \
     2026-10-02T10:00:00Z openrouter openai/gpt-x 1000 25.00 "" \
     2026-10-02T12:00:00Z openrouter x-ai/grok-z 500 "" "" \
     2026-10-02T13:00:00Z openrouter x-ai/grok-z 500 "" "" \
     2026-10-02T14:00:00Z claude claude-opus 9000 500.00 ""
activity 2026-10-01 openai/gpt-x 25 anthropic/claude-y 10
activity 2026-10-02 openai/gpt-x 25 anthropic/claude-y 7

# ── A1 ──
export OPENROUTER_RECONCILE_KEYS=harness-a
js=$("$CLI" --since "$S" --until "$U" --json 2>"$T/err"); rc=$?
check "A1 --json rc 0" "$rc" 0
bk() { jqv "$js" "[b for b in d['buckets'] if b['name']=='$1'][0]['$2']"; }
check "A1 other-keys usd 900" "$(bk other-keys usd)" 900.0
check "A1 other-keys count 1" "$(bk other-keys count)" 1
check "A1 other-keys names project-4-app" "$(jqv "$js" "[a['key'] for b in d['buckets'] if b['name']=='other-keys' for a in b['attribution']]")" "['project-4-app']"
check "A1 unpriced-rows count 2" "$(bk unpriced-rows count)" 2
check "A1 unpriced-rows usd null" "$(bk unpriced-rows usd)" None
check "A1 unpriced attribution" "$(jqv "$js" "[(a['runner'],a['stage'],a['box'],a['project'],a['count']) for b in d['buckets'] if b['name']=='unpriced-rows' for a in b['attribution']]")" "[('openrouter', 'build', 'hub', 'cromford', 2)]"
check "A1 residual usd 40" "$(bk residual usd)" 40.0
check "A1 json line is the tracer's" "$(jqv "$js" "d['line'][:42]")" "openrouter scope=harness-keys state=ok ven"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "A1 markdown rc 0" "$rc" 0
has "A1 line 1 is the tracer's" "$(head -1 <<<"$md")" "openrouter scope=harness-keys state=ok vendor_usd=100.00 rows_usd=60.00 "
has "A1 bucket table header" "$md" "| bucket | count | usd | attribution |"
has "A1 other-keys row" "$md" "| other-keys | 1 | 900.00 |"
has "A1 residual row" "$md" "| residual | 1 | 40.00 |"
has "A1 per-key harness row" "$md" "| harness-a | harness | 50.00 | 150.00 | 100.00 |"

# ── A2 ──
: > "$CURL_LOG"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err")
has "A2 activity skipped without a key" "$md" "activity: skipped (no management key on this box)"
check "A2 no activity call" "$(grep -c '/api/v1/activity' "$CURL_LOG")" 0

# ── A3 / A6 ──
printf 'OPENROUTER_PROVISIONING_KEY=%s\n' "$SECRET" >> "$HARNESS/env/global.env"
: > "$CURL_LOG"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err3"); rc=$?
check "A3 rc 0" "$rc" 0
check "A3 one activity call per day" "$(grep -c '/api/v1/activity?date=' "$CURL_LOG")" 2
has "A3 activity read" "$md" "activity: ok"
um=$(printf '%s\n' "$md" | grep '^| unmatched |' || true)
check "A3 exactly one unmatched cell" "$(printf '%s\n' "$um" | grep -c 'unmatched')" 1
has "A3 the unmatched cell" "$um" "| unmatched | 2026-10-02 | anthropic/claude-y | 7.00 | 0.00 | 7.00 |"
js=$("$CLI" --since "$S" --until "$U" --json 2>>"$T/err3")
check "A3 json unmatched cells" "$(jqv "$js" "[(r['day'],r['model'],r['vendor_usd']) for r in d['activity']['rows'] if r['unmatched']]")" "[('2026-10-02', 'anthropic/claude-y', 7.0)]"
check "A3 normalized join matched day1 gpt-x" "$(jqv "$js" "[r['rows_usd'] for r in d['activity']['rows'] if r['day']=='2026-10-01' and r['model']=='openai/gpt-x']")" "[25.0]"
hasnt "A6 no key in markdown/json/stderr" "$md $js $(cat "$T/err3")" "$SECRET"
hasnt "A6 no key fragment" "$md $js $(cat "$T/err3")" "secretfixture"
echo 403 > "$T/fx/activity-2026-10-02.code"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err3"); rc=$?
has "A3 a refused activity read is named" "$md" "activity: could not read (HTTP 403)"
check "A3 a refused activity read keeps rc 0" "$rc" 0
hasnt "A6 no key on the refused path" "$md $(cat "$T/err3")" "secretfixture"
rm -f "$T/fx/activity-2026-10-02.code"
echo '{"rows":[]}' > "$T/fx/activity-2026-10-02.body"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err3")
has "A3 an unknown activity shape is unparseable" "$md" "activity: unparseable"
activity 2026-10-02 openai/gpt-x 25 anthropic/claude-y 7

# ── A4 ──
cat > "$T/fx/export.csv" <<'CSV'
generation_id,created_at,model,tokens_prompt,tokens_completion,cost
g1,2026-10-01 10:01:00.123,openai/gpt-x,1010,10,25.00
g2,2026-10-01 11:00:30.000,anthropic/claude-y,1990,10,10.00
g3,2026-10-02 10:00:30.000,openai/gpt-x,1050,10,25.00
CSV
js=$("$CLI" --since "$S" --until "$U" --json --export "$T/fx/export.csv" 2>"$T/err"); rc=$?
check "A4 rc 0" "$rc" 0
check "A4 one unmatched request" "$(jqv "$js" "len(d['requests']['unmatched'])")" 1
check "A4 the unmatched request" "$(jqv "$js" "[(r['ts'],r['model'],r['usd']) for r in d['requests']['unmatched']]")" "[('2026-10-02T10:00:30Z', 'openai/gpt-x', 25.0)]"
check "A4 matched 2" "$(jqv "$js" "d['requests']['matched_n']")" 2
md=$("$CLI" --since "$S" --until "$U" --export "$T/fx/export.csv" 2>"$T/err")
has "A4 section header" "$md" "per-request match from the dashboard export; OpenRouter has no API that lists requests"
check "A4 markdown lists exactly one request" "$(printf '%s\n' "$md" | grep -c '^| request |')" 1
has "A4 markdown request row" "$md" "| request | 2026-10-02T10:00:30Z | openai/gpt-x | 25.00 |"
printf 'created_at,model,cost\n2026-10-01 10:00:00,openai/gpt-x,1\n' > "$T/fx/bad.csv"
md=$("$CLI" --since "$S" --until "$U" --export "$T/fx/bad.csv" 2>"$T/err")
has "A4 export without a token column is unparseable" "$md" "requests: unparseable (no input tokens column)"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err")
has "A4 no export: requests section did not run" "$md" "requests: not run (no --export csv)"

# ── A5 ──
echo 500 > "$T/rows.code"
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "A5 rc 1" "$rc" 1
has "A5 could not read" "$out" "could not read"
hasnt "A5 no table" "$out" "|"
hasnt "A5 no buckets" "$out" "buckets"
echo 1 > "$T/rows.okcalls"; rm -f "$T/rows.calls"   # the tracer reads fine, the audit's own read fails
out=$("$CLI" --since "$S" --until "$U" --json 2>"$T/err"); rc=$?
check "A5 audit's own read fails: rc 1" "$rc" 1
check "A5 audit's own read fails: only the could-not-read line" "$out" "could not read: cost_rows"
rm -f "$T/rows.code" "$T/rows.okcalls" "$T/rows.calls"

# ── A7 ──
RA7='{"keys":[{"name":"harness-a","usage":50},{"name":"harness-b","usage":10},{"name":"project-4-app","usage":0}]}'
RB7='{"keys":[{"name":"harness-b","usage":30},{"name":"project-4-app","usage":900}]}'
vendor 2026-09-30T23:00:00Z 1000 "$RA7" 2026-10-02T23:00:00Z 2000 "$RB7"
export OPENROUTER_RECONCILE_KEYS=harness-b
js=$("$CLI" --since "$S" --until "$U" --json 2>"$T/err"); rc=$?
check "A7 rc 0" "$rc" 0
check "A7 harness-a unreadable, no delta" "$(jqv "$js" "[(k['class'],k['delta']) for k in d['keys'] if k['name']=='harness-a']")" "[('unreadable', None)]"
check "A7 other-keys is project-4-app only" "$(bk other-keys usd)" 900.0
hasnt "A7 harness-a in no bucket" "$(jqv "$js" "d['buckets']")" harness-a
check "A7 residual from harness-b only" "$(bk residual usd)" -40.0
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err")
ha=$(printf '%s\n' "$md" | grep 'harness-a')
has "A7 per-key row says unreadable" "$ha" "| harness-a | unreadable | 50.00 |  |  |"
hasnt "A7 no zero delta shown for harness-a" "$ha" "| 0.00 |"
has "A7 table counts unreadable keys" "$md" "keys unreadable (in one snapshot only): 1"
export OPENROUTER_RECONCILE_KEYS=harness-a
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "A7 a missing harness key is the tracer's unread: rc 1" "$rc" 1
has "A7 a missing harness key: could not read" "$out" "could not read"
vendor 2026-09-30T23:00:00Z 1000 "$RA" 2026-10-02T23:00:00Z 2000 "$RB"

# ── A8 ──
cat > "$HARNESS/logs/failovers.log" <<'LOG'
2026-10-01 12:00:00Z [proj] build openrouter: m failed rc=143 — killed
2026-10-01 12:30:00Z [proj] build openrouter: m failed rc=1 — 403 nope
2026-09-01 12:00:00Z [proj] build openrouter: m failed rc=137 — old
LOG
mkdir -p "$HARNESS/builds/x" "$HARNESS/builds/y"
echo "ABANDONED_TIMEOUT stuck 3h" > "$HARNESS/builds/x/RESULT"; touch -d 2026-10-01T12:00:00Z "$HARNESS/builds/x/REAPED"
echo openrouter > "$HARNESS/builds/x/a.runner"
echo "ABANDONED_TIMEOUT stuck" > "$HARNESS/builds/y/RESULT"; touch -d 2026-10-01T12:00:00Z "$HARNESS/builds/y/REAPED"
echo claude > "$HARNESS/builds/y/a.runner"
js=$("$CLI" --since "$S" --until "$U" --json 2>"$T/err")
check "A8 killed-no-row count 2" "$(bk killed-no-row count)" 2
check "A8 killed-no-row usd null" "$(bk killed-no-row usd)" None
check "A8 attribution" "$(jqv "$js" "sorted((a['project'],a['stage'],a['count']) for b in d['buckets'] if b['name']=='killed-no-row' for a in b['attribution'])")" "[('proj', 'build', 1), ('x', '', 1)]"
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err")
has "A8 notes the tracer's kill-note count" "$md" "rows_with_kill_note=0"

# ── the markdown attribution cell names the top 5 groups, --json all of them ──
python3 - "$T/rows.json" <<'PY2'
import json, sys
rows = json.load(open(sys.argv[1]))
for i in range(7):
    rows.append(dict(rows[0], row_hash="u%d" % i, host="pool-m%d" % i, cost_usd=None, ts="2026-10-02T15:00:%02dZ" % i))
json.dump(rows, open(sys.argv[1], "w"))
PY2
md=$("$CLI" --since "$S" --until "$U" 2>"$T/err")
has "md attribution capped at 5 groups" "$(printf '%s\n' "$md" | grep '^| unpriced-rows |')" "+3 more groups (--json lists them)"
js=$("$CLI" --since "$S" --until "$U" --json 2>"$T/err")
check "json attribution has every group" "$(jqv "$js" "len([b for b in d['buckets'] if b['name']=='unpriced-rows'][0]['attribution'])")" 8

# ── usage / a non-ok tracer state ──
"$CLI" --export >/dev/null 2>&1; rc=$?
check "--export with no file exits 2" "$rc" 2
vendor 2026-10-02T23:00:00Z 2000 -
out=$("$CLI" --since "$S" --until "$U" 2>"$T/err"); rc=$?
check "no-meter: rc 0" "$rc" 0
has "no-meter: buckets not computed" "$out" "buckets: not computed (state=no-meter)"

echo "openrouter-audit: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
