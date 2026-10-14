#!/bin/bash
# tests/unpriced-new-pair.bh-2306-test.sh — a NEW runner/model pair whose rows
# the ledger STORED unpriced pages once, on the day it first shows up.
#
# THE GAP (BH-2306). Over 700 billed rows on 2026-09-18..21 went into D1 with
# cost_usd NULL, and every D1 reader (llm-spend caps, the Costs page) counted
# them as $0. The daily UNPRICED alert never saw them: unpriced_pairs() keeps a
# row only when row_cost() is 0, and row_cost() re-prices a blank cost_usd from
# its tokens whenever the model is in the price table. So a row the ledger
# stored as NULL, for a model the catalog prices, read as priced to the rollup
# and paged nobody.
#
# What this pins:
#   A  ledger_unpriced_pairs() keys on the STORED value: a blank cost_usd with
#      tokens counts, whether or not the catalog could price it; a stored
#      figure, a refused row, a never-billed zero-token failure and a row
#      outside the window do not; runner/model are trimmed before grouping.
#   B  new pairs (ledger rc 2) -> one ALERTS line naming each, the daily flag,
#      and one ledger put per pair — kind unpriced_pair, key runner|model.
#   C  known pairs (rc 0) -> silence, and a mix names only the new one.
#   D  the daily flag already set -> no line, no ledger traffic at all.
#   E  a summary with no fleet_ledger_unpriced_pairs_24h key -> nothing.
#   F  seen-set unreadable (rc 1) -> the line, tagged, and ZERO puts.
#   F2 the ALERTS append fails -> no flag and no put (write, then mark).
#   G  the whole bin/cost-rollup.sh, WINDOWS_ONLY=1, in a scratch tree.
#
# SRC=<path> runs sections A-F against another copy of bin/cost-rollup.sh.
# Run from anywhere: tests/unpriced-new-pair.bh-2306-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC="${SRC:-$DIR/bin/cost-rollup.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
mkdir -p "$T/logs" "$T/flags" "$T/cost"
mkdir -p "$T/bin"; cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$T/bin/"
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
unset HARNESS_SECRET JOBS_URL

KIMI="accounts/fireworks/models/kimi-k2p7-code"
HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"

# ── A. ledger_unpriced_pairs(), extracted from the shipped script ────────────
# The same grab() span the sibling suites use: a function added inside it must
# live on the names that span already has.
python3 - "$SRC" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
def grab(name, upto):
    i = body.index(name)
    return body[i:body.index(upto, i)]
out = ["import csv, json, datetime, sys\n"
       "H = sys.argv[4]\nCD = sys.argv[1]\n"
       "prices = json.load(open(sys.argv[2]))\n"
       "now = datetime.datetime.fromisoformat(sys.argv[3])\n"]
out.append(grab("def row_cost(r):", "# per-build exact attribution"))
out.append(grab("def unpriced_pairs(days=1):", "# Real projects come from fleet.conf"))
out.append("print(json.dumps(ledger_unpriced_pairs(1)))\n")
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
grep -q 'def ledger_unpriced_pairs' "$T/core.py" 2>/dev/null && ok \
  || bad "A0: ledger_unpriced_pairs() is not inside the unpriced_pairs span of cost-rollup.sh"

cat > "$T/prices.json" <<EOF
{"$KIMI": {"prompt": 0.000001, "completion": 0.000004},
 "deepseek/deepseek-v4-flash": {"prompt": 0.0000002, "completion": 0.0000008},
 "claude-opus-5": {"prompt": 0.000005, "completion": 0.000025}}
EOF
{ echo "$HDR"
  # counted: blank stored cost, tokens, priceable
  echo "2026-09-25T11:00:00Z,box1,alpha,execute,fireworks,$KIMI,0,60,2000,500,0,0,,metered,,,,,,,,,,"
  # counted: failed AFTER consuming tokens; padded runner and model group with the row above (D17)
  echo "2026-09-25T11:01:00Z,box1,alpha,execute, fireworks , $KIMI ,1,60,100,0,0,0,,metered,,,,,,,,,,"
  # counted: blank stored cost, tokens, the catalog cannot price it
  echo "2026-09-25T11:02:00Z,box1,beta,plan,openrouter,acme/unknown-9,0,60,300,30,0,0,,metered,,,,,,,,,,"
  # NOT counted: a stored dollar figure
  echo "2026-09-25T11:03:00Z,box1,beta,plan,openrouter,deepseek/deepseek-v4-flash,0,60,300,30,0,0,0.5,metered,,,,,,,,,,"
  # NOT counted: a stored zero is a stored value, not a D1 NULL
  echo "2026-09-25T11:04:00Z,box1,beta,plan,claude,claude-opus-5,0,60,300,30,0,0,0,subscription,,,,,,,,,,"
  # NOT counted: refused (BH-1141)
  echo "2026-09-25T11:05:00Z,box1,beta,plan,openrouter,deepseek/deepseek-v4-flash,0,60,300,30,0,0,,metered,,,,refused,,,,,,"
  # NOT counted: a failed call that consumed nothing was never billed (rc 1, 124, 127)
  echo "2026-09-25T11:06:00Z,box1,beta,plan,grok,grok-4.7,1,60,0,0,0,0,,metered,,,,,,,,,,"
  echo "2026-09-25T11:07:00Z,box1,beta,plan,openrouter,deepseek/deepseek-v4-flash,124,60,0,0,0,0,,metered,,,,,,,,,,"
  echo "2026-09-25T11:08:00Z,box1,beta,plan,claude,claude-opus-5,127,60,,,,,,subscription,,,,,,,,,,"
  # NOT counted: outside the 24h window
  echo "2026-09-23T11:00:00Z,box1,beta,plan,openrouter,deepseek/deepseek-v4-flash,0,60,300,30,0,0,,metered,,,,,,,,,,"
} > "$T/cost/fleet-cost.csv"
J=$(python3 "$T/core.py" "$T/cost" "$T/prices.json" 2026-09-25T12:00:00 "$T"); RC=$?
[ "$RC" = 0 ] && ok || bad "A1: ledger_unpriced_pairs() raised (rc=$RC)"
WANT=$(jq -nc --arg k "$KIMI" '[
  {runner:"fireworks",model:$k,calls:2,tokens:2600,priceable:true,in_catalog:true,no_usage:0},
  {runner:"openrouter",model:"acme/unknown-9",calls:1,tokens:330,priceable:false,in_catalog:false,no_usage:0}]')
GOT=$(jq -c '.' <<<"$J" 2>/dev/null)
[ "$GOT" = "$WANT" ] && ok || bad "A2: exact pair list mismatch
  want: $WANT
  got:  $GOT"

# ── B-F. the alert block, extracted and fired ────────────────────────────────
awk '/^# >>> new unpriced pair alert/{f=1;next} /^# <<< new unpriced pair alert/{exit} f' "$SRC" > "$T/newalert.sh"
[ -s "$T/newalert.sh" ] && ok || bad "B0: could not extract the new unpriced pair alert block — markers missing?"

# fire <summary-json> [ledger rc for unknown keys] — ledger stubs record every
# call; keys listed in $T/known answer rc 0.
fire() {
  printf '%s' "$1" > "$T/cost/summary.json"
  : > "$T/gets"; : > "$T/puts"
  LEDGER_RC="${2:-2}" T="$T" H="$T" CD="$T/cost" bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    job_ledger_get() { printf "%s\t%s\n" "$1" "$2" >> "$T/gets"
      grep -qxF -- "$2" "$T/known" 2>/dev/null && { printf alerted; return 0; }
      return "$LEDGER_RC"; }
    job_ledger_put() { printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" >> "$T/puts"; return 0; }
    . "$0"' "$T/newalert.sh"
}
reset() { rm -rf "$T/logs/ALERTS.log" "$T/flags/"* "$T/known"; }
TWO=$(jq -nc --arg k "$KIMI" '{fleet_ledger_unpriced_pairs_24h:[
  {runner:"fireworks",model:$k,calls:2,tokens:2600,priceable:true},
  {runner:"openrouter",model:"acme/unknown-9",calls:1,tokens:330,priceable:false}]}')
FLAG="$T/flags/alerted-unpriced-new-$(date -u +%Y%m%d)"

# B. both new
reset; fire "$TWO" 2
L=$(cat "$T/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -c 'NEW UNPRICED PAIR' <<<"$L")" = 1 ] && ok || bad "B1: exactly one NEW UNPRICED PAIR line (got: '$L')"
grep -qF "fireworks/$KIMI (2 call(s), 2600 tokens, catalog prices it" <<<"$L" && grep -qF 'not pricing at the call site' <<<"$L" \
  && ok || bad "B2: the priceable pair must say the call site is not pricing it (got: '$L')"
grep -qF 'openrouter/acme/unknown-9 (1 call(s), 330 tokens, not in catalog/model-prices.json — add a price row' <<<"$L" \
  && ok || bad "B3: the unpriceable pair must say to add a price row to the catalog (got: '$L')"
grep -qF 'llm-spend caps and the Costs page read them as $0' <<<"$L" && ok || bad "B4: the line must say what it costs (got: '$L')"
grep -q 'seen-set unreadable' <<<"$L" && bad "B5: a readable seen-set must not be tagged unreadable" || ok
[ -f "$FLAG" ] && ok || bad "B6: the daily flag must be set after the line"
WANTP=$(printf 'unpriced_pair\tfireworks|%s\nunpriced_pair\topenrouter|acme/unknown-9\n' "$KIMI")
[ "$(cut -f1,2 "$T/puts")" = "$WANTP" ] && ok || bad "B7: one put per new pair, kind unpriced_pair, key runner|model (got: $(cat "$T/puts"))"
grep -qP '\talerted\tfirst_alerted=TS calls=2 tokens=2600$' "$T/puts" && ok \
  || bad "B8: the put carries status alerted and the first-alert detail (got: $(cat "$T/puts"))"

# C. all known -> silence; a mix -> only the new pair
reset; printf 'fireworks|%s\nopenrouter|acme/unknown-9\n' "$KIMI" > "$T/known"; fire "$TWO" 2
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -f "$FLAG" ] && [ ! -s "$T/puts" ] && ok \
  || bad "C1: known pairs must not page, flag or put (log: $(cat "$T/logs/ALERTS.log" 2>/dev/null); puts: $(cat "$T/puts"))"
reset; printf 'fireworks|%s\n' "$KIMI" > "$T/known"; fire "$TWO" 2
L=$(cat "$T/logs/ALERTS.log" 2>/dev/null)
grep -qF 'openrouter/acme/unknown-9' <<<"$L" && ! grep -qF "$KIMI" <<<"$L" && ok \
  || bad "C2: a mix must name only the new pair (got: '$L')"
[ "$(cut -f2 "$T/puts")" = "openrouter|acme/unknown-9" ] && ok || bad "C3: only the new pair is marked (got: $(cat "$T/puts"))"

# D. the flag is already set (a new pair arrived after today's line): no line, no ledger traffic
reset; touch "$FLAG"; fire "$TWO" 2
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/puts" ] && [ ! -s "$T/gets" ] && ok \
  || bad "D1: once today's line is out, nothing more pages or is marked (log: $(cat "$T/logs/ALERTS.log" 2>/dev/null); puts: $(cat "$T/puts"))"

# E. absent is not empty: a summary from the previous version does nothing
reset; fire '{"fleet_unpriced_pairs_24h":[]}' 2
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -s "$T/gets" ] && [ ! -f "$FLAG" ] && ok \
  || bad "E1: a summary without the key must not page or read the ledger"
reset; fire '{"fleet_ledger_unpriced_pairs_24h":[]}' 2
[ ! -s "$T/logs/ALERTS.log" ] && [ ! -f "$FLAG" ] && ok || bad "E2: an empty list must not page"

# F. the seen-set is unreadable: page, tagged, flag set, NEVER marked
reset; fire "$TWO" 1
L=$(cat "$T/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -o 'seen-set unreadable' <<<"$L" | wc -l)" = 2 ] && ok || bad "F1: each unverified pair must be tagged (got: '$L')"
[ -f "$FLAG" ] && ok || bad "F2: the daily flag is set for an unverified line too"
[ ! -s "$T/puts" ] && ok || bad "F3: an unverified pair must never be marked seen (puts: $(cat "$T/puts"))"

# F2. the append fails: nothing is marked, so tomorrow pages again
reset; mkdir -p "$T/logs/ALERTS.log"; fire "$TWO" 2 2>/dev/null
[ ! -f "$FLAG" ] && [ ! -s "$T/puts" ] && ok || bad "F4: a failed ALERTS append must leave no flag and no put (puts: $(cat "$T/puts"))"
rm -rf "$T/logs/ALERTS.log"

# ── G. the production entry point: the whole rollup, windows-only ────────────
# A copy of the script in a scratch HARNESS, so $(dirname "$0")/lib resolves to
# nothing but the cost_rows reader copied beside it (an empty table), an empty fleet.conf (no
# gh), no watchdog secret (no push). The only row is one billed call for a pair
# the ledger stub has never seen.
G="$T/g"; mkdir -p "$G/bin" "$G/logs" "$G/flags" "$G/state/cost"
cp "$SRC" "$G/bin/cost-rollup.sh"; chmod +x "$G/bin/cost-rollup.sh"
# The rollup reads the fleet from cost_rows and, since BH-2527, stops (ALERT,
# nothing rewritten) when it cannot. The table answers EMPTY here, so the
# hub's own logs/cost.csv below is the whole fleet, as this case intends.
mkdir -p "$G/bin/lib"; cp "$DIR/bin/lib/cost-rows-read.sh" "$G/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$G/bin/"
: > "$G/fleet.conf"
jq '{per_token: .}' "$T/prices.json" > "$G/state/model-prices.json"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{ echo "$HDR"
  echo "$NOW,hub,alpha,execute,fireworks,$KIMI,0,60,2000,500,0,0,,metered,,,,,,,,,,"
} > "$G/logs/cost.csv"
cat > "$G/bin/jobs-client.sh" <<'SH'
_jobs_req() { case "$2" in /api/metrics/cost-rows*) echo '{"cost_rows":[]}' ;; *) return 1 ;; esac; }
job_ledger_get() { printf '%s\t%s\n' "$1" "$2" >> "$HARNESS/gets"; return 2; }
job_ledger_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HARNESS/puts"; return 0; }
SH
( export HARNESS="$G" WINDOWS_ONLY=1 COST_ROLLUP_TIMEBOXED=1
  bash "$G/bin/cost-rollup.sh" >"$T/g.out" 2>"$T/g.err" ); GRC=$?
[ "$GRC" = 0 ] && ok || bad "G1: the rollup must exit 0 (rc=$GRC): $(tail -5 "$T/g.err")"
GP=$(jq -c '.fleet_ledger_unpriced_pairs_24h' "$G/state/cost/summary.json" 2>/dev/null)
WANTG=$(jq -nc --arg k "$KIMI" '[{runner:"fireworks",model:$k,calls:1,tokens:2500,priceable:true,in_catalog:true,no_usage:0}]')
[ "$GP" = "$WANTG" ] && ok || bad "G2: summary.json must carry the stored-unpriced pair (got: $GP)"
[ "$(grep -c 'NEW UNPRICED PAIR' "$G/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "G3: one NEW UNPRICED PAIR line from the whole run (ALERTS: $(cat "$G/logs/ALERTS.log" 2>/dev/null))"
# Only the unpriced_pair puts: since BH-4158 the same run also writes the
# cost-rollup/last-success row through this stub.
[ "$(awk -F'\t' '$1 == "unpriced_pair" { print $2 }' "$G/puts" 2>/dev/null)" = "fireworks|$KIMI" ] && ok || bad "G4: the run marks the pair seen (puts: $(cat "$G/puts" 2>/dev/null))"

echo "unpriced-new-pair: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
