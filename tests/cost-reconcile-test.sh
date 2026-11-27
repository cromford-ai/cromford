#!/bin/bash
# tests/cost-reconcile-test.sh — bin/cost-reconcile.sh, driven end to end against
# a stubbed harness-jobs API.
#
# THE GAP THIS CLOSES (2026-09-14, cost fix 4). We have two independent
# measurements of the same money: Anthropic's own extra-usage meter (the
# invoice) and cost_rows (our per-call ledger, which every dashboard, PR cost
# and budget in this harness is built on). Nothing had ever compared them, so
# when the project-6 account ran to $23.8K of a $35K cap the ledger said nothing
# was wrong — a ledger cannot see an invoice, and an invoice cannot see a lane.
#
# The product is one row per (account, window) and ONE alert per day when a
# metered account's two numbers disagree by more than RECONCILE_GAP_PCT. Almost
# everything asserted below is about NOT alerting: an alarm that rings on a
# quiet week is one nobody reads on the week that matters.
#
#   1. metered: meter delta vs summed rows, gap $ and %, alert over the
#      threshold, ONE per account per day (dedupe), none under it
#   2. credits-covered: under the weekly cap the meter reads $0 and is RIGHT to.
#      $0 against $600 of rows is the plan working, not a 100% discrepancy
#   3. no-login / no-meter / meter-reset: three different nothings, each named
#   4. the sum itself: non-Anthropic runners excluded, unlabelled rows reported
#      as unattributed rather than summed, pool jobs counted ONLY for machines
#      that push no rows of their own, pagination walked to the end
#   5. the floors: a tiny meter movement and a too-short meter span do not alert
#   6. the window forms, the DB push, --dry-run, and both kill switches
# Run from anywhere: tests/cost-reconcile-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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
# A real filter, not a fixed answer: the script pages cost_rows backwards with
# since/until/limit and asks for one account's meter at a time, and a stub that
# ignores the query would let a broken paginator or a missing filter pass.
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
        fh.write("%s %s %s\n" % (method, u.path + ("?" + u.query if u.query else ""), body or ""))

if u.path == "/api/metrics/reconcile" and method == "POST":
    with open(os.environ["RECONCILE_SINK"], "a") as fh:
        fh.write((body or "") + "\n")
    answer({"accepted": len(json.loads(body or "{}").get("rows", [])), "inserted": 1})

if u.path == "/api/metrics/extra-usage":
    snaps = [s for s in load("meters.json", []) if s.get("box") == q.get("box")]
    snaps.sort(key=lambda s: s["ts"], reverse=True)
    answer({"snapshots": snaps[: int(q.get("limit", 200))]})

if u.path == "/api/metrics/cost-rows":
    rows = load("cost-rows.json", [])
    for key in ("auth_account", "box"):
        if q.get(key):
            rows = [r for r in rows if (r.get(key) or "") == q[key]]
    if q.get("since"):
        rows = [r for r in rows if r["ts"] >= q["since"]]
    if q.get("until"):
        rows = [r for r in rows if r["ts"] <= q["until"]]
    rows.sort(key=lambda r: r["ts"], reverse=True)
    answer({"cost_rows": rows[: int(q.get("limit", 200))]})

if u.path == "/api/jobs":
    answer({"jobs": load("jobs.json", [])})

answer({"error": "unstubbed route " + u.path}, 404)
CURL
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

# ── fixtures ────────────────────────────────────────────────────────────────
# Timestamps are relative to NOW so the same fixture sits inside a 1h or a 24h
# window without a clock trick.
ago() { python3 -c "
import datetime,sys
print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }
T0=$(ago 600); T1=$(ago 300); T2=$(ago 30)

# Each fixture writer takes newline-delimited JSON objects (what the `jq -nc`
# builders below print) and stores the JSON ARRAY the stub serves. An empty
# argument is an empty table, which is a fixture in its own right.
setfix() { printf '%s' "$2" | jq -s '.' > "$T/api/$1"; }
meters() { setfix meters.json "$1"; }
rows()   { setfix cost-rows.json "$1"; }
jobs()   { setfix jobs.json "$1"; }
meters ""; rows ""; jobs ""

snap() { # snap <box> <ts> <weekly_pct> <used_usd> [status]
  jq -nc --arg b "$1" --arg t "$2" --argjson w "$3" --arg u "$4" --arg s "${5:-ok}" \
    '{box:$b,ts:$t,weekly_pct:$w,extra_used_usd:(if $u=="" then null else ($u|tonumber) end),
      extra_limit_usd:35000,status:$s}'
}
crow() { # crow <ts> <box> <runner> <auth_account> <usd> <hash>
  jq -nc --arg t "$1" --arg b "$2" --arg r "$3" --arg a "$4" --argjson u "$5" --arg h "$6" \
    '{ts:$t,box:$b,runner:$r,auth_account:$a,cost_usd:$u,row_hash:$h}'
}
job() { # job <box> <created> <updated> <spent>
  jq -nc --arg b "$1" --arg c "$2" --arg u "$3" --argjson s "$4" \
    '{box:$b,created_at:$c,updated_at:$u,spent_usd:$s}'
}

cat > "$T/catalog/cost-accounts.json" <<'EOF'
{
  "anthropic_runners": ["claude"],
  "box_aliases": {"box-hub": "hub", "box-project-3-2": "project-3"},
  "accounts": {
    "acct": {
      "login": {"box": "hub", "config_dir": "/dev/null"},
      "auth_accounts": ["claude:operator@second.example"],
      "boxes": {"cost_rows": ["hub"], "jobs": ["box-hub", "pool-*"]}
    }
  }
}
EOF

run() { # run <args...> — one reconcile in the sandbox
  : > "$T/reqs"; : > "$T/alerts"; : > "$T/pushed"
  env -i PATH="$PATH" HOME="$T" HARNESS="$T" API_DIR="$T/api" REQ_SINK="$T/reqs" \
    ALERT_SINK="$T/alerts" RECONCILE_SINK="$T/pushed" ${RUN_ENV:-} \
    bash "$T/bin/cost-reconcile.sh" "$@" >"$T/out" 2>"$T/err"
}
row_json() { jq -sc '.[0].rows[0] // {}' "$T/pushed" 2>/dev/null; }
# jq 1.7 prints a number back exactly as it arrived (40.0 stays "40.0"), so
# every numeric read goes through +0 to get one canonical form to compare with.
field() { row_json | jq -r --arg k "$1" '(.[$k] // "null") | if type=="number" then (.+0|tostring) else tostring end'; }
fresh_day() { rm -f "$T/flags"/alerted-cost-reconcile-* 2>/dev/null; : ; }

# ===========================================================================
# 1. METERED: the comparison, the alert, and the dedupe
# ===========================================================================
# The meter moved $100; our rows account for $40. That is the finding the whole
# job exists for: $60 of spend ran through something that writes no cost row.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1100)")"
rows "$(printf '%s\n%s\n' \
  "$(crow "$T1" hub claude 'claude:operator@second.example' 30 h1)" \
  "$(crow "$T1" hub claude 'claude:operator@second.example' 10 h2)")"
jobs ""
fresh_day; run --window 24h
[ "$(field state)" = metered ] && ok || bad "a past-the-credits account did not reconcile as metered: $(row_json)"
[ "$(field meter_delta_usd)" = 100 ] && ok || bad "meter delta wrong: $(row_json)"
[ "$(field rows_usd)" = 40 ] && ok || bad "rows sum wrong: $(row_json)"
[ "$(field gap_usd)" = 60 ] && [ "$(field gap_pct)" = 60 ] && ok || bad "gap wrong: $(row_json)"
grep -q 'COST RECONCILE \[acct\]' "$T/alerts" \
  && ok || bad "a 60% gap on a metered account raised no alert: $(cat "$T/alerts")"
grep -q '60.0%' "$T/alerts" && ok || bad "the alert does not name the gap: $(cat "$T/alerts")"
[ "$(field alerted)" = 1 ] && ok || bad "the row does not record that it alerted: $(row_json)"
grep -q 'cost-reconcile \[acct\] 24h state=metered' "$T/logs/cost-reconcile.log" \
  && ok || bad "no log line for the run: $(cat "$T/logs/cost-reconcile.log")"

# ONE ALERT PER ACCOUNT PER DAY. The hourly cadence would otherwise raise 24
# identical lines about one unchanged fact.
run --window 24h
[ ! -s "$T/alerts" ] && ok || bad "the gap alert re-fired the same day: $(cat "$T/alerts")"
[ -s "$T/pushed" ] && ok || bad "a deduped alert also suppressed the DB row — the measurement must still be recorded"
[ "$(field alerted)" = 0 ] && ok || bad "the deduped row claims it alerted: $(row_json)"

# Under the threshold: same shape, no alert.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1045)")"
fresh_day; run --window 24h
[ "$(field state)" = metered ] && [ "$(field gap_pct)" = 11.1 ] \
  && ok || bad "expected an 11.1% gap: $(row_json)"
grep -q 'COST RECONCILE' "$T/alerts" && ok || bad "an 11.1% gap did not clear the 10% threshold"
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1042)")"
fresh_day; run --window 24h
[ ! -s "$T/alerts" ] && ok || bad "a 4.8% gap alerted: $(cat "$T/alerts")"
# ...and the threshold is a knob, not a constant.
RUN_ENV="RECONCILE_GAP_PCT=1" run --window 24h
grep -q 'COST RECONCILE' "$T/alerts" \
  && ok || bad "RECONCILE_GAP_PCT did not lower the threshold"

# ===========================================================================
# 2. CREDITS-COVERED: a $0 meter against $600 of rows is the plan working
# ===========================================================================
# This is the COMMON case and the one that would destroy the alert's
# credibility: before an account is past its weekly credits the dollar meter
# does not move at all, so a naive comparison reports a 100% gap every quiet
# week until nobody reads the alert any more.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 71 0)" "$(snap acct "$T2" 88 0)")"
rows "$(crow "$T1" hub claude 'claude:operator@second.example' 600 h9)"
fresh_day; run --window 24h
[ "$(field state)" = credits-covered ] && ok || bad "an account inside its weekly credits was not reported as credits-covered: $(row_json)"
[ "$(field gap_pct)" = null ] && ok || bad "a credits-covered account was given a dollar gap: $(row_json)"
[ ! -s "$T/alerts" ] && ok || bad "a credits-covered account alerted: $(cat "$T/alerts")"
# The spend is still REPORTED — it is the comparison that is impossible, not
# the measurement.
[ "$(field rows_usd)" = 600 ] && ok || bad "credits-covered dropped the rows it did have: $(row_json)"
field note | grep -qi 'credits' && ok || bad "the row does not say WHY no comparison was made: $(row_json)"

# ===========================================================================
# 3. THE THREE NOTHINGS, EACH NAMED
# ===========================================================================
# no-login: the account holds no credential that can read its meter (a 1-year
# setup-token answers 429 forever). Different from a dead poller, and only one
# of the two is fixed by provisioning a login.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 0 '' no-login)" "$(snap acct "$T2" 0 '' no-login)")"
fresh_day; run --window 24h
[ "$(field state)" = no-login ] && ok || bad "an account with no readable login was not reported as no-login: $(row_json)"
[ ! -s "$T/alerts" ] && ok || bad "no-login alerted — there is nothing to compare, so there is nothing to alert about"

# no-meter: nobody polled at all in this window.
meters ""
fresh_day; run --window 24h
[ "$(field state)" = no-meter ] && ok || bad "an empty meter window was not reported as no-meter: $(row_json)"

# meter-reset: the meter fell inside the window, so last-minus-first is not a
# delta — it is a negative number that would read as a huge negative gap.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 900)" "$(snap acct "$T2" 100 12)")"
fresh_day; run --window 24h
[ "$(field state)" = meter-reset ] && ok || bad "a meter that zeroed mid-window was not reported as meter-reset: $(row_json)"
[ ! -s "$T/alerts" ] && ok || bad "a meter reset alerted as a gap: $(cat "$T/alerts")"

# ===========================================================================
# 4. THE SUM ITSELF
# ===========================================================================
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1100)")"
# grok on the same box is a DIFFERENT vendor's bill, and on the real hub 287 of
# its rows carry no account label at all. Summing them against a Claude meter
# invents a gap out of a vendor this meter never measured.
rows "$(printf '%s\n%s\n%s\n' \
  "$(crow "$T1" hub claude 'claude:operator@second.example' 40 h1)" \
  "$(crow "$T1" hub grok  unknown 500 h2)" \
  "$(crow "$T1" hub claude unknown 25 h3)")"
fresh_day; run --window 24h
[ "$(field rows_usd)" = 40 ] && ok || bad "a non-Anthropic runner was summed against the Claude meter: $(row_json)"
# An unlabelled ANTHROPIC row is real spend on this account's box that we cannot
# attribute. Counted nowhere, reported here, never silently folded in — and the
# unlabelled grok row beside it is not Anthropic spend at all.
[ "$(field unattributed_usd)" = 25 ] && ok || bad "the unattributed figure is not Anthropic-only: $(row_json)"
[ "$(field gap_usd)" = 60 ] && ok || bad "unattributed spend leaked into the gap: $(row_json)"

# Pool jobs: counted only for a machine that pushes no cost rows. box-hub
# IS the hub, under the name the jobs table uses, and the hub pushes rows — so
# its job total is the same dollars seen twice.
jobs "$(printf '%s\n%s\n' \
  "$(job box-hub "$T1" "$T1" 99)" \
  "$(job pool-project-5-abc "$T1" "$T1" 15)")"
fresh_day; run --window 24h
[ "$(field jobs_usd)" = 15 ] && ok || bad "the double-count guard did not translate box-hub into hub: $(row_json)"
[ "$(field jobs_count)" = 1 ] && ok || bad "wrong job count: $(row_json)"
[ "$(field gap_usd)" = 45 ] && ok || bad "pool spend was not credited against the meter: $(row_json)"
jobs ""

# Pagination: the read side answers newest-first with a hard limit, so a window
# wider than one page is walked backwards. 25 rows at a page size of 10.
BIG=$(python3 - "$T1" <<'PY'
import datetime, json, sys
t = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
for i in range(25):
    ts = (t + datetime.timedelta(seconds=i)).strftime("%Y-%m-%dT%H:%M:%SZ")
    print(json.dumps({"ts": ts, "box": "hub", "runner": "claude",
                      "auth_account": "claude:operator@second.example", "cost_usd": 4,
                      "row_hash": "p%d" % i}))
PY
)
rows "$BIG"
fresh_day; RUN_ENV="RECONCILE_PAGE_LIMIT=10" run --window 24h
[ "$(field rows_count)" = 25 ] && [ "$(field rows_usd)" = 100 ] \
  && ok || bad "the paginator stopped early: $(row_json)"
[ "$(grep -c 'metrics/cost-rows' "$T/reqs")" -ge 3 ] \
  && ok || bad "a 25-row window at 10 rows a page did not take at least 3 requests"
# ...and no row is counted twice across the inclusive page boundary.
[ "$(field gap_usd)" = 0 ] && ok || bad "a paged row was double counted: $(row_json)"

# ===========================================================================
# 5. THE FLOORS: a percentage of a small number is noise
# ===========================================================================
# $0.40 of meter against $0.35 of rows is a 12% gap and means nothing.
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1000.40)")"
rows "$(crow "$T1" hub claude 'claude:operator@second.example' 0.35 h1)"
fresh_day; run --window 24h
[ "$(field state)" = metered ] && ok || bad "the small-money case must still be measured: $(row_json)"
[ ! -s "$T/alerts" ] && ok || bad "a \$0.40 meter movement alerted: $(cat "$T/alerts")"

# A window the meter only saw three minutes of is measuring clock skew, not
# money: rows land every 10 minutes and the meter samples every 15.
S1=$(ago 4); S2=$(ago 1)
meters "$(printf '%s\n%s\n' "$(snap acct "$S1" 100 1000)" "$(snap acct "$S2" 100 1100)")"
rows "$(crow "$S1" hub claude 'claude:operator@second.example' 10 h1)"
fresh_day; run --window 1h
[ ! -s "$T/alerts" ] && ok || bad "a 3-minute meter span alerted on a 90% gap: $(cat "$T/alerts")"
field span_start | grep -q "$S1" && ok || bad "the row does not carry the span the comparison used: $(row_json)"

# ===========================================================================
# 6. WINDOWS, THE PUSH, --dry-run AND THE KILL SWITCHES
# ===========================================================================
meters "$(printf '%s\n%s\n' "$(snap acct "$T0" 100 1000)" "$(snap acct "$T2" 100 1100)")"
rows "$(crow "$T1" hub claude 'claude:operator@second.example' 100 h1)"
fresh_day; run --window 1h
[ "$(field window_key)" = 1h ] && ok || bad "--window 1h did not key the row as 1h: $(row_json)"
run --window day 2026-09-01
[ "$(field window_key)" = "day:2026-09-01" ] && ok || bad "--window day YYYY-MM-DD did not key the row: $(row_json)"
[ "$(field window_start)" = "2026-09-01T00:00:00Z" ] && ok || bad "a named day did not bound the window: $(row_json)"
run --window nonsense
[ "$?" != 0 ] && ok || bad "an unknown window was accepted"

# ONE request for the whole run, carrying every account's row.
run --window 24h
[ "$(grep -c 'POST /api/metrics/reconcile' "$T/reqs")" = 1 ] \
  && ok || bad "expected exactly one reconcile push per run: $(grep -c 'POST /api/metrics/reconcile' "$T/reqs")"
row_json | jq -e 'has("account") and has("window_key") and has("state") and has("created_at")==false' >/dev/null \
  && ok || bad "the pushed row is missing a key the worker requires: $(row_json)"

# --dry-run measures and logs but writes nothing to the DB.
: > "$T/logs/cost-reconcile.log"
run --window 24h --dry-run
[ ! -s "$T/pushed" ] && ok || bad "--dry-run pushed to the DB"
[ -s "$T/logs/cost-reconcile.log" ] && ok || bad "--dry-run also skipped the log line"

# The log line survives a worker outage — the file is the copy that remains.
: > "$T/logs/cost-reconcile.log"
mv "$T/fakebin/curl" "$T/fakebin/curl.off"
printf '#!/bin/bash\nexit 7\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
run --window 24h
[ "$?" = 0 ] && ok || bad "a dead worker made the reconciler exit nonzero into cron"
mv -f "$T/fakebin/curl.off" "$T/fakebin/curl"

# Kill switches.
RUN_ENV="RECONCILE=0" run --window 24h
[ ! -s "$T/pushed" ] && ok || bad "RECONCILE=0 still ran"
touch "$T/flags/cost-reconcile-off"
run --window 24h
[ ! -s "$T/pushed" ] && ok || bad "flags/cost-reconcile-off still ran"
rm -f "$T/flags/cost-reconcile-off"

# --account narrows the run to one account, for a by-hand check of one meter.
run --window 24h --account nosuchaccount
[ ! -s "$T/pushed" ] && ok || bad "--account did not filter the account list"

echo "cost-reconcile-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
