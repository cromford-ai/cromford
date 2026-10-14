#!/bin/bash
# tests/cost-reconcile.bh-1020-test.sh — the blank-cost flood alert, driven
# through bin/cost-reconcile.sh against a stubbed harness-jobs API.
#
# WHY IT EXISTS (BH-1020). The write-time pricer (cost_row_price, shipped in the
# same ticket) only helps a box that has SYNCED it, and it can only price a
# model catalog/model-prices.json actually carries. Both failures look identical
# from the hub: rc=0 rows arriving with an empty cost_usd, quietly, thousands of
# them — 1,987 rows and about $3.5K in the three days the audit measured, with
# nothing anywhere saying so until somebody read a rollup.
#
# So the hourly reconcile run counts them. More than RECONCILE_BLANK_ROWS_MAX
# (default 20) blank rc=0 rows from ONE runner in an hour is one alert, once per
# runner per UTC day. Almost everything below is about NOT alerting: a failed
# call was never billed, a priced row is priced, exactly 20 is not "more than
# 20", and the 24h run must never read a day's total as an hour's flood.
#
# Run from anywhere: tests/cost-reconcile.bh-1020-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/state" "$T/flags" "$T/catalog" "$T/api" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

cp "$DIR/bin/cost-reconcile.sh" "$T/bin/"
cp "$DIR/bin/jobs-client.sh"    "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# scratch-closure-allow: BH-4080 the lane under test runs under env -i or in its own harness root, so HARNESS_DEPLOYMENT_FILE does not reach it and bin/lib/deployment.sh must sit beside its copied libs
cp "$DIR/bin/lib/deployment.sh" "$T/bin/lib/"  # BH-4080: req.sh builds the worker URL from it
chmod +x "$T/bin/cost-reconcile.sh"
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
echo "$2" >> "$ALERT_SINK"
exit 0
EOF
chmod +x "$T/bin/lane-alert.sh"

# ── the stubbed API ─────────────────────────────────────────────────────────
# Same design as tests/cost-reconcile-test.sh: a real filter, not a fixed
# answer, so a pass that forgot its window or its paginator cannot slide past.
# ROWS_404 makes the rows endpoint answer like a ledger miss, which is the one
# state the blank pass must never report as clean.
cat > "$T/fakebin/curl" <<'CURL'
#!/usr/bin/env python3
import json, os, sys, urllib.parse

argv = sys.argv[1:]
url = argv[-1]
method, body = "GET", None
i = 0
while i < len(argv):
    if argv[i] == "-X":
        method = argv[i + 1]; i += 2
    elif argv[i] == "--data-binary":
        body = argv[i + 1]; i += 2
    else:
        i += 1
if body and body.startswith("@"):
    body = open(body[1:]).read()

API = os.environ["API_DIR"]
u = urllib.parse.urlparse(url)
q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}

def load(name, default):
    try:
        return json.load(open(os.path.join(API, name)))
    except Exception:
        return default

def answer(payload, code=200):
    sys.stdout.write(json.dumps(payload) + "\n" + str(code) + "\n")
    raise SystemExit(0)

if os.environ.get("REQ_SINK"):
    with open(os.environ["REQ_SINK"], "a") as fh:
        fh.write("%s %s\n" % (method, u.path))

if u.path == "/api/metrics/reconcile" and method == "POST":
    with open(os.environ["RECONCILE_SINK"], "a") as fh:
        fh.write((body or "") + "\n")
    answer({"accepted": len(json.loads(body or "{}").get("rows", [])), "inserted": 1})

if u.path == "/api/metrics/extra-usage":
    snaps = [s for s in load("meters.json", []) if s.get("box") == q.get("box")]
    snaps.sort(key=lambda s: s["ts"], reverse=True)
    answer({"snapshots": snaps[: int(q.get("limit", 200))]})

if u.path == "/api/metrics/cost-rows":
    if os.environ.get("ROWS_404"):
        answer({"error": "no such ledger"}, 404)
    rows = load("cost-rows.json", [])
    for key in ("auth_account", "box"):
        if q.get(key):
            rows = [r for r in rows if (r.get(key) or "") == q[key]]
    lo, hi = q.get("since"), q.get("until")
    if lo:
        rows = [r for r in rows if r["ts"] >= lo]
    if hi:
        rows = [r for r in rows if r["ts"] <= hi]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    answer({"cost_rows": rows[: int(q.get("limit", 200))]})

if u.path == "/api/jobs":
    answer({"jobs": load("jobs.json", [])})

answer({"error": "unstubbed route " + u.path}, 404)
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ── fixtures ────────────────────────────────────────────────────────────────
# Timestamps are relative to NOW so one fixture sits inside a 1h window and a
# 24h one without a clock trick.
ago() { python3 -c "
import datetime,sys
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
M50=$(ago 50); M30=$(ago 30); M5=$(ago 5)

setfix() { printf '%s' "$2" | jq -s '.' > "$T/api/$1"; }
meters() { setfix meters.json "$1"; }
rows()   { setfix cost-rows.json "$1"; }
jobs()   { setfix jobs.json "$1"; }
jobs ""

snap() { # snap <box> <ts> <weekly_pct> <used_usd>
  jq -nc --arg b "$1" --arg t "$2" --argjson w "$3" --argjson u "$4" \
    '{box:$b,ts:$t,weekly_pct:$w,extra_used_usd:$u,extra_limit_usd:35000,status:"ok"}'
}
# The account loop's own rows, so R9 can prove the new pass did not break it.
crow() { # crow <ts> <box> <runner> <auth_account> <usd> <hash>
  jq -nc --arg t "$1" --arg b "$2" --arg r "$3" --arg a "$4" --argjson u "$5" --arg h "$6" \
    '{ts:$t,box:$b,runner:$r,auth_account:$a,cost_usd:$u,rc:0,model:"claude-opus-5",row_hash:$h}'
}
# n rows from one runner, with whatever rc and cost_usd the case is about.
flood() { # flood <n> <runner> <model> <rc> <cost_usd-or-empty> <hash-prefix>
  python3 - "$@" "$M30" <<'PY'
import json, sys
n, runner, model, rc, usd, pfx, ts = sys.argv[1:8]
for i in range(int(n)):
    print(json.dumps({"ts": ts, "box": "pool-1", "runner": runner, "model": model,
                      "rc": int(rc), "cost_usd": (None if usd == "" else float(usd)),
                      "auth_account": "", "row_hash": "%s%d" % (pfx, i)}))
PY
}

cat > "$T/catalog/cost-accounts.json" <<'EOF'
{
  "anthropic_runners": ["claude"],
  "box_aliases": {"box-hub": "hub"},
  "accounts": {
    "acct": {
      "login": {"box": "hub", "config_dir": "/dev/null"},
      "auth_accounts": ["claude:operator@example.com"],
      "boxes": {"cost_rows": ["hub"], "jobs": ["box-hub"]}
    }
  }
}
EOF

run() { # run <args...> — one reconcile in the sandbox
  : > "$T/reqs"; : > "$T/alerts"; : > "$T/pushed"; : > "$T/logs/cost-reconcile.log"
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" API_DIR="$T/api" REQ_SINK="$T/reqs" \
    ALERT_SINK="$T/alerts" RECONCILE_SINK="$T/pushed" ${RUN_ENV:-} \
    bash "$T/bin/cost-reconcile.sh" "$@" >"$T/out" 2>"$T/err"
}
log()       { cat "$T/logs/cost-reconcile.log"; }
# The account-gap alert (the script's original product) shares the sink, and
# some cases below deliberately break the row fetch — which moves that gap. So
# every assertion here is about the BLANK COST line specifically, never about
# the sink being empty.
blanks()    { grep -c 'BLANK COST' "$T/alerts" 2>/dev/null || true; }
fresh_day() { rm -f "$T/flags"/alerted-cost-blank-* "$T/flags"/alerted-cost-reconcile-* 2>/dev/null; : ; }

# The account half of every fixture below: a metered account with priced claude
# rows. It is here so the blank flood never sits alone in the table — the pass
# must pick its rows out of a ledger that also carries healthy ones.
BASE_ROWS="$(printf '%s\n%s\n' \
  "$(crow "$M30" hub claude 'claude:operator@example.com' 40 c1)" \
  "$(crow "$M30" hub claude 'claude:operator@example.com' 10 c2)")"
meters "$(printf '%s\n%s\n' "$(snap acct "$M50" 100 1000)" "$(snap acct "$M5" 100 1050)")"

# ===========================================================================
# R1. THE FINDING: 21 blank openrouter rows in the hour
# ===========================================================================
rows "$(printf '%s\n%s\n%s\n' "$BASE_ROWS" \
  "$(flood 21 openrouter anthropic/claude-fable-5.1 0 "" or)" \
  "$(flood 5 fireworks accounts/fireworks/models/kimi-k2p7-code 0 "" fw)")"
fresh_day; run --window 1h
grep -q 'BLANK COST \[openrouter\]' "$T/alerts" \
  && ok || bad "R1 21 blank openrouter rows in an hour raised no alert: $(cat "$T/alerts")"
grep -q 'blank=21' "$T/alerts" && ok || bad "R1 the alert does not name the count: $(cat "$T/alerts")"
grep -q 'anthropic/claude-fable-5.1' "$T/alerts" \
  && ok || bad "R1 the alert does not name the model in the flood: $(cat "$T/alerts")"
grep -q 'cost_row_price' "$T/alerts" \
  && ok || bad "R1 the alert does not say what to check: $(cat "$T/alerts")"
grep -q 'BLANK COST \[fireworks\]' "$T/alerts" \
  && bad "R1 5 blank fireworks rows are under the threshold and must not alert: $(cat "$T/alerts")" || ok
log | grep -q 'blank-cost 1h runner=openrouter blank=21 alerted=1' \
  && ok || bad "R1 the log line must record the count and that it alerted: $(log)"
log | grep -q 'blank-cost 1h runner=fireworks blank=5 alerted=0' \
  && ok || bad "R1 a runner under the threshold is still counted in the log: $(log)"
ls "$T/flags/" | grep -q "^alerted-cost-blank-openrouter-$(date -u +%Y%m%d)$" \
  && ok || bad "R1 the daily flag must be alerted-cost-blank-<runner>-<date> (have: $(ls "$T/flags/"))"

# R6. ...once. The hourly cadence would otherwise raise 24 identical lines.
run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R6 the blank-cost alert re-fired the same day: $(cat "$T/alerts")"
log | grep -q 'blank-cost 1h runner=openrouter blank=21 alerted=0' \
  && ok || bad "R6 the deduped run must still COUNT and log: $(log)"

# ===========================================================================
# R2. exactly 20 is not "more than 20"
# ===========================================================================
rows "$(printf '%s\n%s\n' "$BASE_ROWS" "$(flood 20 openrouter anthropic/claude-fable-5.1 0 "" or)")"
fresh_day; run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R2 exactly 20 blank rows alerted — the threshold is strictly greater: $(cat "$T/alerts")"
log | grep -q 'blank-cost 1h runner=openrouter blank=20 alerted=0' \
  && ok || bad "R2 20 rows must still be counted and logged: $(log)"

# ===========================================================================
# R3. NEGATIVE: a FAILED call was never billed
# ===========================================================================
rows "$(printf '%s\n%s\n' "$BASE_ROWS" "$(flood 21 openrouter anthropic/claude-fable-5.1 1 "" or)")"
fresh_day; run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R3 21 FAILED calls paged as unpriced spend: $(cat "$T/alerts")"
log | grep -q 'blank-cost 1h clean' \
  && ok || bad "R3 a window whose only blanks are failures is clean: $(log)"

# ===========================================================================
# R4. NEGATIVE: a priced row is priced
# ===========================================================================
rows "$(printf '%s\n%s\n' "$BASE_ROWS" "$(flood 21 openrouter anthropic/claude-fable-5.1 0 0.01 or)")"
fresh_day; run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R4 21 PRICED rows alerted as blank: $(cat "$T/alerts")"
log | grep -q 'blank-cost 1h clean' || bad "R4 a fully priced hour must log clean: $(log)"
log | grep -q 'blank-cost 1h clean' && ok

# ===========================================================================
# R5. the 24h run never reads a day's total as an hour's flood
# ===========================================================================
rows "$(printf '%s\n%s\n' "$BASE_ROWS" "$(flood 21 openrouter anthropic/claude-fable-5.1 0 "" or)")"
fresh_day; run --window 24h
[ "$(blanks)" = 0 ] && ok || bad "R5 the 24h run raised the hourly flood alert: $(cat "$T/alerts")"
grep -q 'blank-cost' <<<"$(log)" \
  && bad "R5 the 24h run must not even log a blank-cost line: $(log)" || ok
# ...and the same fixture on the hourly run still fires, so R5 is about the
# window and not about a fixture that stopped working.
fresh_day; run --window 1h
grep -q 'BLANK COST \[openrouter\]' "$T/alerts" \
  && ok || bad "R5 control: the same rows must still alert on the 1h window"

# ===========================================================================
# R7. the threshold is a knob, and 0 turns the pass off
# ===========================================================================
rows "$(printf '%s\n%s\n%s\n' "$BASE_ROWS" \
  "$(flood 21 openrouter anthropic/claude-fable-5.1 0 "" or)" \
  "$(flood 5 fireworks accounts/fireworks/models/kimi-k2p7-code 0 "" fw)")"
fresh_day; RUN_ENV="RECONCILE_BLANK_ROWS_MAX=0" run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R7 RECONCILE_BLANK_ROWS_MAX=0 still alerted: $(cat "$T/alerts")"
grep -q 'blank-cost' <<<"$(log)" && bad "R7 the disabled pass must run nothing at all: $(log)" || ok
fresh_day; RUN_ENV="RECONCILE_BLANK_ROWS_MAX=100" run --window 1h
[ "$(blanks)" = 0 ] && ok || bad "R7 a raised threshold still alerted at 21 rows: $(cat "$T/alerts")"
fresh_day; RUN_ENV="RECONCILE_BLANK_ROWS_MAX=5" run --window 1h
grep -q 'BLANK COST \[fireworks\]' "$T/alerts" \
  && bad "R7 a lowered threshold is still strictly greater — 5 of 5 must not page: $(cat "$T/alerts")" || ok
grep -q 'BLANK COST \[openrouter\]' "$T/alerts" \
  && ok || bad "R7 a lowered threshold did not lower the threshold: $(cat "$T/alerts")"

# ===========================================================================
# R8. A FETCH THAT FAILED IS NOT A CLEAN HOUR
# ===========================================================================
fresh_day; RUN_ENV="ROWS_404=1" run --window 1h
log | grep -q 'blank-cost 1h unread' \
  && ok || bad "R8 an unreadable ledger must log unread: $(log)"
grep -q 'blank-cost 1h clean' <<<"$(log)" \
  && bad "R8 an unreadable ledger claimed the hour was clean: $(log)" || ok
[ "$(blanks)" = 0 ] && ok || bad "R8 an unreadable ledger raised a blank-cost alert: $(cat "$T/alerts")"

# ===========================================================================
# R9. the account loop in front of it still works
# ===========================================================================
rows "$(printf '%s\n%s\n' "$BASE_ROWS" "$(flood 21 openrouter anthropic/claude-fable-5.1 0 "" or)")"
fresh_day; run --window 1h
ROW=$(jq -sc '.[0].rows[0] // {}' "$T/pushed" 2>/dev/null)
[ "$(printf '%s' "$ROW" | jq -r '.state')" = metered ] \
  && ok || bad "R9 the blank pass broke the account reconciliation: $ROW"
[ "$(printf '%s' "$ROW" | jq -r '.rows_usd | .+0 | tostring')" = 50 ] \
  && ok || bad "R9 the account sum moved — blank openrouter rows must not enter it: $ROW"
log | grep -q 'cost-reconcile \[acct\] 1h state=metered' \
  && ok || bad "R9 the per-account log line is gone: $(log)"

echo "cost-reconcile.bh-1020-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
