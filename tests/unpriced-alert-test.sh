#!/bin/bash
# tests/unpriced-alert-test.sh — an unpriced call must page someone.
#
# THE FAILURE (2026-09-10). summary.json has carried unpriced_calls_24h since
# the cash split shipped, and twenty unpriced calls sat on the dashboard for a
# week without a single alert. An unpriced row is NOT a missing row: the call
# went out, the vendor billed for it, and the ledger stores $0.00 — so a lane
# running entirely on a model the price table does not know reads as free. That
# is the shape of the grok incident (~$460 in two days, blank cost column, the
# xAI invoice as the only symptom) and of the whole metered-API class: the guard
# exists, looks right in review, and never fires.
#
# Both halves are driven, not grepped. The aggregation runs against a FIXTURE
# CSV using the script's own row_cost(), and the shell alert is extracted from
# the script and run against a fixture summary.json in a fixture harness tree.
#
# Run from anywhere: tests/unpriced-alert-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="$DIR/bin/cost-rollup.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/logs" "$T/flags" "$T/cost"
mkdir -p "$T/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"

# ── A. the aggregation, using the shipped row_cost() ─────────────────────────
python3 - "$SRC" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
def grab(name, upto):
    i = body.index(name)
    return body[i:body.index(upto, i)]
out = ["import csv, json, datetime, sys\n"
       "H = '/none'\nCD = sys.argv[1]\n"
       "prices = json.load(open(sys.argv[2]))\n"
       "now = datetime.datetime.fromisoformat(sys.argv[3])\n"]
out.append(grab("def row_cost(r):", "# per-build exact attribution"))
out.append(grab("def unpriced_pairs(days=1):", "# Real projects come from fleet.conf"))
out.append("print(json.dumps(unpriced_pairs(1)))\n")
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && grep -q 'def unpriced_pairs' "$T/core.py" && ok \
  || bad "could not extract row_cost/unpriced_pairs from cost-rollup.sh — markers moved?"

cat > "$T/prices.json" <<'EOF'
{"claude-opus-5": {"prompt": 0.000015, "completion": 0.000075},
 "grok-4.6": {"prompt": 0, "completion": 0}}
EOF
# ts values straddle the 24h cut at 2026-09-10T12:00:00.
cat > "$T/cost/fleet-cost.csv" <<'EOF'
ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode
2026-09-10T11:00:00Z,box1,alpha-os,execute,claude,claude-opus-5,0,60,1000,500,0,0,0.05,subscription
2026-09-10T11:05:00Z,box1,alpha-os,review,fireworks,kimi-k3,0,60,900,100,0,0,,metered
2026-09-10T11:06:00Z,box1,beta-os,review,fireworks,kimi-k3,0,60,100,0,0,0,0,metered
2026-09-10T11:07:00Z,box1,beta-os,triage,grok,grok-4.6,0,60,0,0,0,0,,metered
2026-09-10T11:08:00Z,box1,beta-os,triage,grok,grok-4.6,0,60,0,0,0,0,,metered
2026-09-10T11:09:00Z,box1,beta-os,plan,codex,gpt-6,0,60,50,50,0,0,,subscription
2026-09-09T09:00:00Z,box1,beta-os,plan,fireworks,kimi-k3,0,60,999,999,0,0,,metered
2026-09-10T11:10:00Z,box1,beta-os,execute,claude,claude-opus-5,1,3,0,0,0,0,,subscription
2026-09-10T11:11:00Z,box1,beta-os,execute,claude,claude-opus-5,124,3,0,0,0,0,,subscription
2026-09-10T11:12:00Z,box1,beta-os,execute,anthropic,claude-sonnet-9,1,30,4000,120,0,0,,metered
EOF
J=$(python3 "$T/core.py" "$T/cost" "$T/prices.json" 2026-09-10T12:00:00)
pair() { jq -r --arg r "$1" --arg m "$2" '[.[]|select(.runner==$r and .model==$m)][0] | '"$3" <<<"$J"; }

# A priced row is not unpriced, whatever its billing mode.
[ "$(jq -r '[.[]|select(.model=="claude-opus-5")]|length' <<<"$J")" = 0 ] && ok \
  || bad "a row with a real cost_usd must not be reported as unpriced"
# The two shapes, kept apart.
[ "$(pair fireworks kimi-k3 .calls)" = 2 ] && ok \
  || bad "both in-window kimi-k3 rows must aggregate (got $(pair fireworks kimi-k3 .calls))"
[ "$(pair fireworks kimi-k3 .tokens)" = 1100 ] && ok \
  || bad "tokens must sum across input/output/cache (got $(pair fireworks kimi-k3 .tokens))"
[ "$(pair fireworks kimi-k3 .in_price_table)" = false ] && ok \
  || bad "kimi-k3 is absent from the price table and must say so"
[ "$(pair grok grok-4.6 .calls)" = 2 ] && ok || bad "the two grok rows must aggregate"
[ "$(pair grok grok-4.6 .tokens)" = 0 ] && ok \
  || bad "a runner reporting no tokens must show 0, not be dropped"
# A model that IS in the table but priced to zero still costs money off-ledger —
# it must not be silently absolved just because a price row exists.
[ "$(pair grok grok-4.6 .in_price_table)" = true ] && ok \
  || bad "grok-4.6 has a price-table entry and must be reported as such"
# The window is real: yesterday's row must not inflate today's alert.
[ "$(pair fireworks kimi-k3 .calls)" != 3 ] && ok || bad "an out-of-window row leaked into the 24h count"
# Ordering is by call count, so the worst offender is first in the alert line.
[ "$(jq -r '.[0].calls' <<<"$J")" = 2 ] && ok || bad "pairs must be ordered by call count"

# --- A FAILED CALL WAS NEVER BILLED -----------------------------------------
# Every attempt appends a row, so a 429, a timeout or a failover writes rc!=0
# with no tokens and no cost. Those rows are unpriced because nothing happened,
# not because the ledger cannot price them — counting them fires this alert on
# a bad afternoon at the vendor and sends someone to model-prices.json to add a
# row for a model that is already there. The distinguishing fact is tokens: a
# call that consumed none never reached the meter.
[ "$(jq -r '[.[]|select(.runner=="claude" and .model=="claude-opus-5")]|length' <<<"$J")" = 0 ] && ok \
  || bad "a zero-token rc!=0 row was never billed and must not be reported as unpriced"
# …but a call that FAILED AFTER consuming tokens was billed for those tokens
# and still needs pricing. rc is not the test on its own.
[ "$(pair anthropic claude-sonnet-9 .calls)" = 1 ] && ok \
  || bad "a failure that consumed tokens was billed and must still flag (got $(pair anthropic claude-sonnet-9 .calls))"
[ "$(pair anthropic claude-sonnet-9 .tokens)" = 4120 ] && ok \
  || bad "the billed tokens of a failed call must still be counted"

# --- A DEAD PRICE TABLE IS ITS OWN ALERT ------------------------------------
# row_cost() falls back to the price table, which is loaded from a hardcoded
# path inside a bare except. If that path is ever wrong, prices={} and EVERY
# row in the fleet reads as unpriced — the alert would name the entire fleet
# and point at a file that is fine. The count must say the table failed instead.
echo '{}' > "$T/empty-prices.json"
JZ=$(python3 "$T/core.py" "$T/cost" "$T/empty-prices.json" 2026-09-10T12:00:00)
pairz() { jq -r --arg r "$1" --arg m "$2" '[.[]|select(.runner==$r and .model==$m)][0] | '"$3" <<<"$JZ"; }
# grok-4.6 IS in the real table and says so. With the table gone it says the
# opposite — so every "no price-table entry" verdict in the fleet flips at once,
# and the alert would name models whose price rows are perfectly fine.
[ "$(pair grok grok-4.6 .in_price_table)" = true ] \
  && [ "$(pairz grok grok-4.6 .in_price_table)" = false ] && ok \
  || bad "an empty price table must visibly flip in_price_table — that is the state the alert has to recognise"

# ── B. the ALERTS line, extracted and run ────────────────────────────────────
awk '/^# >>> unpriced call alert/{f=1;next} /^# <<< unpriced call alert/{exit} f' "$SRC" > "$T/alert.sh"
[ -s "$T/alert.sh" ] && ok || bad "could not extract the unpriced alert block — markers missing?"

fire() { # fire <summary-json>  -> writes ALERTS.log in the fixture tree
  printf '%s' "$1" > "$T/cost/summary.json"
  H="$T" CD="$T/cost" bash -c 'STAMP(){ echo TS; }; . "$0"' "$T/alert.sh"
}
SUM='{"fleet_unpriced_calls_24h":20,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"fireworks","model":"kimi-k3","calls":12,"tokens":1100,"in_price_table":false},
  {"runner":"grok","model":"grok-4.6","calls":5,"tokens":0,"in_price_table":true},
  {"runner":"openrouter","model":"deepseek","calls":3,"tokens":900,"in_price_table":true}]}'

fire "$SUM"
L=$(grep 'cost-rollup' "$T/logs/ALERTS.log" 2>/dev/null | tail -1)
grep -q '20 call(s) in the last 24h are UNPRICED' <<<"$L" && ok \
  || bad "the alert must lead with the fleet-wide count (got: '$L')"
grep -q 'fireworks/kimi-k3 (12 call(s), 1100 tokens)' <<<"$L" && ok \
  || bad "a pair with tokens and no price entry must be NAMED with its counts (got: '$L')"
grep -q 'model-prices.json' <<<"$L" && ok || bad "the alert must say where the fix goes"
grep -q 'No tokens reported: grok/grok-4.6 (5 call(s))' <<<"$L" && ok \
  || bad "a runner reporting no tokens is a different fix and must be listed separately (got: '$L')"
grep -q 'Priced model, still \$0: openrouter/deepseek' <<<"$L" && ok \
  || bad "a priced model that still costs \$0 points at the usage parser (got: '$L')"
# BH-406: the breakdown says WHAT is unpriced; the family note says where the
# class is written down and that the call sites page on the first one now. A
# rollup line arriving with no [cost-parity] line behind it means that box never
# got the guard, and the reader has to be told that to know it.
grep -q 'cost-capture-parity' <<<"$L" && ok \
  || bad "the alert must link the cost-capture-parity family note (got: '$L')"

# The headline counts what the pairs actually account for. A day whose only
# unpriced rows were never-billed failures must not alert at all, and a day with
# both must not present the failures as spend.
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":9,"prices_loaded":40,"fleet_unpriced_pairs_24h":[]}'
[ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "a count made entirely of never-billed failures must not alert: $(cat "$T/logs/ALERTS.log")"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":25,"prices_loaded":40,"fleet_unpriced_pairs_24h":[
  {"runner":"fireworks","model":"kimi-k3","calls":5,"tokens":900,"in_price_table":false}]}'
L2=$(tail -1 "$T/logs/ALERTS.log")
grep -q '5 call(s) in the last 24h are UNPRICED' <<<"$L2" && ok \
  || bad "the headline must count the billed rows, not the raw dashboard number (got: '$L2')"
grep -q '20 further zero-token failure' <<<"$L2" && ok \
  || bad "the excluded never-billed failures must be named, not silently dropped (got: '$L2')"

# A dead price table gets its own line and does NOT name runners: the fix is the
# table, and listing every model in the fleet would send people to the wrong file.
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":900,"prices_loaded":0,"fleet_unpriced_pairs_24h":[
  {"runner":"claude","model":"claude-opus-5","calls":900,"tokens":9000,"in_price_table":false}]}'
L3=$(tail -1 "$T/logs/ALERTS.log")
grep -q 'price table' <<<"$L3" && ok || bad "an empty price table must alert about the TABLE (got: '$L3')"
grep -q 'claude-opus-5' <<<"$L3" && bad "with no price table the alert must not blame individual models" || ok
# It must still be one line a day, like the rest.
B3=$(wc -l < "$T/logs/ALERTS.log")
fire '{"fleet_unpriced_calls_24h":900,"prices_loaded":0,"fleet_unpriced_pairs_24h":[]}'
[ "$(wc -l < "$T/logs/ALERTS.log")" = "$B3" ] && ok || bad "the price-table alert re-fired within the day"

# Deduped per day: the windows refresh hourly, and an alert repeated every hour
# is an alert nobody reads.
BEFORE=$(wc -l < "$T/logs/ALERTS.log")
fire "$SUM"; fire "$SUM"
[ "$(wc -l < "$T/logs/ALERTS.log")" = "$BEFORE" ] && ok \
  || bad "the alert re-fired within the same day — flags/alerted-unpriced-<date> is not holding"
ls "$T/flags/" | grep -q "^alerted-unpriced-$(date -u +%Y%m%d)$" && ok \
  || bad "the daily flag must be named alerted-unpriced-<date> like the other daily alerts"

# Zero unpriced calls is the quiet case, and must stay quiet.
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":0,"prices_loaded":40,"fleet_unpriced_pairs_24h":[]}'
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "zero unpriced calls must not alert: $(cat "$T/logs/ALERTS.log")"

# A count with no pairs still alerts. Losing the number because the breakdown is
# missing would restore exactly the silence this change is about.
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":7}'
grep -q '7 call(s) in the last 24h are UNPRICED' "$T/logs/ALERTS.log" && ok \
  || bad "a count with no pairs breakdown must still alert"

# A junk/absent count must not crash the script under `set -u`.
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{"fleet_unpriced_calls_24h":"lots"}' && ok || bad "a junk count must not fail the rollup"
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "a junk count must not invent an alert"
rm -f "$T/logs/ALERTS.log" "$T/flags/"*
fire '{}' && ok || bad "a summary with no unpriced fields must not fail the rollup"

# ── C. the field the alert reads is actually produced ────────────────────────
grep -q 'summary\["fleet_unpriced_calls_24h"\]' "$SRC" && ok \
  || bad "cost-rollup.sh never writes fleet_unpriced_calls_24h — the alert can never fire"
grep -q 'summary\["fleet_unpriced_pairs_24h"\] = unpriced_pairs(1)' "$SRC" && ok \
  || bad "cost-rollup.sh never writes fleet_unpriced_pairs_24h"

echo "unpriced-alert-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
