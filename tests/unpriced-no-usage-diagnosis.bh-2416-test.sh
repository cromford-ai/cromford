#!/bin/bash
# tests/unpriced-no-usage-diagnosis.bh-2416-test.sh — the NEW UNPRICED PAIR
# alert tells a pair with no usage to fix its usage parse, not to add a price
# row, and only a model the catalog does not have is told to add one.
#
# THE GAP (BH-2416, from the review of BH-2306). A zero-token rc-0 cost row
# (what cost_row_price writes as UNPRICED:no-usage) always prices at $0, so
# ledger_unpriced_pairs() marked its pair priceable:false, and the alert's
# two-way diagnosis said "not in catalog/model-prices.json — add it" even when
# the catalog had the model. The fix for that pair is the runner's usage parse.
#
# What this pins:
#   A  ledger_unpriced_pairs() reports in_catalog (the price-table lookup
#      row_cost uses) and no_usage (calls in the pair with zero tokens).
#   B  a no-usage pair on a catalog model names the runner and its parser path
#      and never says "not in catalog" or "add a price row"; one parser path
#      per runner, and an unmapped runner is named rather than left blank.
#   C  only in_catalog:false says "add a price row"; a catalog model whose row
#      prices tokens at $0 is told to check that row's rates.
#   D  a mixed pair carries both parts; the seen-set put and flag are unchanged.
#   E  the whole bin/cost-rollup.sh, WINDOWS_ONLY=1, in a scratch tree.
#
# SRC=<path> runs sections A-D against another copy of bin/cost-rollup.sh.
# Run from anywhere: tests/unpriced-no-usage-diagnosis.bh-2416-test.sh   (exit 0 = all pass)
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

HDR="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note"

# ── A. ledger_unpriced_pairs(), extracted from the shipped script ────────────
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

cat > "$T/prices.json" <<'EOF'
{"claude-opus-5": {"prompt": 0.000005, "completion": 0.000025},
 "grok-4.7": {"prompt": 0.000003, "completion": 0.000015}}
EOF
# Rows in the exact shape cost_row_price writes for a call that returned no
# usage: rc 0, blank token columns, blank cost_usd, note UNPRICED:no-usage (D4).
{ echo "$HDR"
  echo "2026-09-25T11:00:00Z,box1,alpha,execute,claude,claude-opus-5,0,60,,,,,,subscription,,,,,,,,,,UNPRICED:no-usage"
  echo "2026-09-25T11:01:00Z,box1,beta,plan,openrouter,acme/unknown-9,0,60,,,,,,metered,,,,,,,,,,UNPRICED:no-usage"
  # a tokened blank-cost row for a catalog model
  echo "2026-09-25T11:02:00Z,box1,beta,plan,grok,grok-4.7,0,60,300,30,0,0,,metered,,,,,,,,,,"
} > "$T/cost/fleet-cost.csv"
J=$(python3 "$T/core.py" "$T/cost" "$T/prices.json" 2026-09-25T12:00:00 "$T" 2>"$T/a.err"); RC=$?
[ "$RC" = 0 ] && ok || bad "A0: ledger_unpriced_pairs() raised (rc=$RC): $(tail -2 "$T/a.err")"
pair() { jq -c --arg r "$1" --arg m "$2" '.[]? | select(.runner==$r and .model==$m)
  | {calls, tokens, priceable, in_catalog, no_usage}' <<<"$J" 2>/dev/null; }
[ "$(pair claude claude-opus-5)" = '{"calls":1,"tokens":0,"priceable":false,"in_catalog":true,"no_usage":1}' ] && ok \
  || bad "A1: a no-usage row on a catalog model must report in_catalog:true, no_usage:1 (got: $(pair claude claude-opus-5))"
[ "$(pair openrouter acme/unknown-9)" = '{"calls":1,"tokens":0,"priceable":false,"in_catalog":false,"no_usage":1}' ] && ok \
  || bad "A2: a no-usage row on an unknown model must report in_catalog:false, no_usage:1 (got: $(pair openrouter acme/unknown-9))"
[ "$(pair grok grok-4.7)" = '{"calls":1,"tokens":330,"priceable":true,"in_catalog":true,"no_usage":0}' ] && ok \
  || bad "A3: a tokened row on a catalog model must report no_usage:0, priceable:true (got: $(pair grok grok-4.7))"

# ── B-D. the alert block, extracted and fired ────────────────────────────────
awk '/^# >>> new unpriced pair alert/{f=1;next} /^# <<< new unpriced pair alert/{exit} f' "$SRC" > "$T/newalert.sh"
[ -s "$T/newalert.sh" ] && ok || bad "B0: could not extract the new unpriced pair alert block — markers missing?"

# fire <pair-json> — one pair, new to the seen-set (ledger rc 2); prints the line.
fire() {
  rm -rf "$T/logs/ALERTS.log" "$T/flags/"*
  jq -nc --argjson p "$1" '{fleet_ledger_unpriced_pairs_24h:[$p]}' > "$T/cost/summary.json"
  : > "$T/puts"
  T="$T" H="$T" CD="$T/cost" bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    job_ledger_get() { return 2; }
    job_ledger_put() { printf "%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" >> "$T/puts"; return 0; }
    . "$0"' "$T/newalert.sh"
  cat "$T/logs/ALERTS.log" 2>/dev/null
}

# B. no usage, catalog model
L=$(fire '{"runner":"grok","model":"grok-4.7","calls":3,"tokens":0,"priceable":false,"in_catalog":true,"no_usage":3}')
grep -qF 'grok/grok-4.7 (3 call(s), 0 tokens, 3 call(s) reported no usage' <<<"$L" && ok \
  || bad "B1: a no-usage pair must say its calls reported no usage (got: '$L')"
grep -qF 'not in catalog' <<<"$L" || grep -qF 'add a price row' <<<"$L" || grep -qF 'add it' <<<"$L" \
  && bad "B1b: a catalog model with no usage must never be told to add a price row (got: '$L')" || ok
grep -qF 'runner grok returned no token counts' <<<"$L" && ok || bad "B2: the line must name the runner (got: '$L')"
parser_case() { # parser_case <runner> <expected substring>
  local l; l=$(fire "{\"runner\":\"$1\",\"model\":\"m-$1\",\"calls\":1,\"tokens\":0,\"priceable\":false,\"in_catalog\":true,\"no_usage\":1}")
  grep -qF "fix its usage parse: $2" <<<"$l" && ok || bad "B3[$1]: parser path must be '$2' (got: '$l')"
}
parser_case grok       'bin/grok-usage.sh'
parser_case codex      'bin/codex-usage.sh'
parser_case openrouter 'bin/codex-usage.sh'
parser_case fireworks  'bin/codex-usage.sh'
parser_case claude     'bin/agent-call.sh run_attempt claude branch'
L=$(fire '{"runner":"newthing","model":"x","calls":1,"tokens":0,"priceable":false,"in_catalog":true,"no_usage":1}')
grep -qF 'no usage parser mapped for runner newthing' <<<"$L" && ok \
  || bad "B3[newthing]: an unmapped runner must be named, not left blank (got: '$L')"

# C. only a model the catalog lacks is told to add a price row
L=$(fire '{"runner":"openrouter","model":"acme/unknown-9","calls":1,"tokens":330,"priceable":false,"in_catalog":false,"no_usage":0}')
grep -qF 'not in catalog/model-prices.json — add a price row' <<<"$L" && ok \
  || bad "C1: a model not in the catalog must be told to add a price row (got: '$L')"
grep -qF 'reported no usage' <<<"$L" && bad "C1b: a tokened pair must not say no usage (got: '$L')" || ok
L=$(fire '{"runner":"openrouter","model":"acme/free-1","calls":1,"tokens":330,"priceable":false,"in_catalog":true,"no_usage":0}')
grep -qF "check that row's rates" <<<"$L" && ok || bad "C2: a catalog model pricing tokens at \$0 must be told to check its rates (got: '$L')"
grep -qF 'add a price row' <<<"$L" && bad "C2b: a catalog model must never be told to add a price row (got: '$L')" || ok
L=$(fire '{"runner":"openrouter","model":"acme/unknown-9","calls":2,"tokens":0,"priceable":false,"in_catalog":false,"no_usage":2}')
grep -qF '2 call(s) reported no usage' <<<"$L" && grep -qF 'add a price row' <<<"$L" && ok \
  || bad "C3: no usage on an unknown model must carry both diagnoses (got: '$L')"

# D. mixed pair; seen-set and flag unchanged
L=$(fire '{"runner":"claude","model":"claude-opus-5","calls":3,"tokens":900,"priceable":true,"in_catalog":true,"no_usage":1}')
grep -qF '1 call(s) reported no usage' <<<"$L" && grep -qF 'catalog prices it' <<<"$L" && ok \
  || bad "D1: a mixed pair must carry the no-usage part and the call-site part (got: '$L')"
grep -qF 'add a price row' <<<"$L" && bad "D1b: a mixed catalog pair must not be told to add a price row (got: '$L')" || ok
[ "$(grep -c 'NEW UNPRICED PAIR' <<<"$L")" = 1 ] && [ -f "$T/flags/alerted-unpriced-new-$(date -u +%Y%m%d)" ] \
  && [ "$(cut -f1,2,3 "$T/puts")" = "$(printf 'unpriced_pair\tclaude|claude-opus-5\talerted')" ] && ok \
  || bad "D2: one line, the daily flag, and one put keyed runner|model (puts: $(cat "$T/puts"))"

# ── E. the production entry point: the whole rollup, windows-only ────────────
# Same scratch shape as tests/unpriced-new-pair.bh-2306-test.sh section G; the
# only row is one call that returned no usage, for a model the catalog prices.
G="$T/g"; mkdir -p "$G/bin" "$G/logs" "$G/flags" "$G/state/cost"
cp "$DIR/bin/cost-rollup.sh" "$G/bin/cost-rollup.sh"; chmod +x "$G/bin/cost-rollup.sh"
# The rollup reads the fleet from cost_rows and, since BH-2527, stops (ALERT,
# nothing rewritten) when it cannot. The table answers EMPTY here, so the
# hub's own logs/cost.csv below is the whole fleet, as this case intends.
mkdir -p "$G/bin/lib"; cp "$DIR/bin/lib/cost-rows-read.sh" "$G/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$G/bin/"
: > "$G/fleet.conf"
jq '{per_token: .}' "$T/prices.json" > "$G/state/model-prices.json"
NOW=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
{ echo "$HDR"
  echo "$NOW,hub,alpha,execute,grok,grok-4.7,0,60,,,,,,metered,,,,,,,,,,UNPRICED:no-usage"
} > "$G/logs/cost.csv"
cat > "$G/bin/jobs-client.sh" <<'SH'
_jobs_req() { case "$2" in /api/metrics/cost-rows*) echo '{"cost_rows":[]}' ;; *) return 1 ;; esac; }
job_ledger_get() { return 2; }
job_ledger_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HARNESS/puts"; return 0; }
SH
( export HARNESS="$G" WINDOWS_ONLY=1 COST_ROLLUP_TIMEBOXED=1
  bash "$G/bin/cost-rollup.sh" >"$T/g.out" 2>"$T/g.err" ); GRC=$?
[ "$GRC" = 0 ] && ok || bad "E0: the rollup must exit 0 (rc=$GRC): $(tail -5 "$T/g.err")"
L=$(grep 'NEW UNPRICED PAIR' "$G/logs/ALERTS.log" 2>/dev/null)
grep -qF 'grok/grok-4.7 (1 call(s), 0 tokens, 1 call(s) reported no usage — runner grok returned no token counts; fix its usage parse: bin/grok-usage.sh' <<<"$L" \
  && ! grep -qF 'add a price row' <<<"$L" && ! grep -qF 'not in catalog' <<<"$L" && ok \
  || bad "E1: the whole run must name the runner and parser path, and not ask for a price row (ALERTS: $(cat "$G/logs/ALERTS.log" 2>/dev/null))"

echo "unpriced-no-usage-diagnosis: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
