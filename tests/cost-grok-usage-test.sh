#!/bin/bash
# tests/cost-grok-usage-test.sh — a grok call must land PRICED, and a call that
# yields no usage at all must page on the FIRST one.
#
# THE FAILURE (BH-406, 2026-09-15). 217 grok/grok-4.6 rows in one 24h window
# shipped with blank input_toks, blank output_toks and blank cost_usd. The
# parser lived inline in bin/agent-call.sh and was path-bound twice over: it
# looked only at $HOME/.grok/sessions/**/updates.jsonl, and it matched a usage
# object only when the dict carried BOTH inputTokens AND costUsdTicks. A moved
# ledger or a subscription-billed session with no metered ticks therefore read
# as "no usage", the row went out blank, and NOTHING on the box said so — the
# hub's hourly rollup was the first and only mention, once a day.
#
# That is the same class as the 2026-08-20 grok incident (~$160/day metered
# while every row showed $0.00) and the codex one after it. The fix is the same
# design bin/codex-usage.sh adopted: recurse for the SHAPE, walk for the FILE,
# never assume a path — plus a call-site alert so the first unpriced call pages.
#
# Everything here is DRIVEN, not grepped: bin/grok-usage.sh runs against
# fixtures, the two new cost-row.sh functions are extracted by their markers and
# executed, and section D runs bin/agent-call.sh itself with a fake grok CLI on
# PATH and reads the cost row back off disk.
#
# Run from anywhere: tests/cost-grok-usage-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$T" testproj
GU="$DIR/bin/grok-usage.sh"
FIX="$DIR/tests/fixtures"
mkdir -p "$T/logs" "$T/flags" "$T/locks" "$T/fakebin" "$T/bin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The price table sections B and D price against. grok-4.6's rates are the ones
# catalog/model-prices.json actually carries today (prompt 2e-6, completion
# 6e-6, cache_read 5e-7, cache_write null) — a null rate is not zero-by-luck,
# it is a rate xAI does not publish, and it must contribute 0 without making the
# whole row unpriced.
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7, "cache_write": null}
}}
EOF

# ── A. bin/grok-usage.sh: the ledger reader ──────────────────────────────────
echo "--- A. bin/grok-usage.sh"
[ -x "$GU" ] || bad "bin/grok-usage.sh is missing or not executable"
ghome() { # ghome <dir-under-T> <fixture> <relative-path-inside-grok-home>
  rm -rf "${T:?}/${1:?}"; mkdir -p "$T/$1/$(dirname "$3")"
  cp "$FIX/$2" "$T/$1/$3"
  echo "$T/$1"
}

# A1. the verified 2026-08-20 shape: nested usage + costUsdTicks.
H1=$(ghome gh1 grok-usage-nested-ticks.jsonl sessions/s1/updates.jsonl)
OUT=$(bash "$GU" 0 "$H1"); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 reader must exit 0 (rc=$RC)"
[ "$OUT" = "402118 11003 128044 2011 0.905636" ] && ok \
  || bad "A1 the verified nested-ticks shape must price: expected '402118 11003 128044 2011 0.905636', got '$OUT'"

# A2. tokens with NO costUsdTicks. This is the row the shipped parser drops on
# the floor: tokens must come back and USD must be EMPTY (not 0 — a zero here
# reads as "this call was free", which is the lie the blank column already told).
H2=$(ghome gh2 grok-usage-no-ticks.jsonl sessions/s2/updates.jsonl)
OUT=$(bash "$GU" 0 "$H2")
[ "$OUT" = "100000 10000 50000 0 " ] && ok \
  || bad "A2 a ticks-less session must still report tokens with an EMPTY usd: got '$OUT'"

# A3. a ledger with no usage anywhere: five empty fields, rc 0, no crash.
H3=$(ghome gh3 grok-usage-none.jsonl sessions/s3/updates.jsonl)
OUT=$(bash "$GU" 0 "$H3"); RC=$?
[ "$RC" = 0 ] && ok || bad "A3 a usage-free ledger must not fail the caller (rc=$RC)"
[ -z "$(tr -d ' ' <<<"$OUT")" ] && ok || bad "A3 a miss must be blank, never a number: got '$OUT'"
# ...and a settings dict carrying maxInputTokens is not a call.
grep -q maxInputTokens "$T/gh3/sessions/s3/updates.jsonl" && ok \
  || bad "A3 fixture lost its maxInputTokens line — the negative it pins is gone"

# A4. THE PATH IS NOT THE CONTRACT. Neither the directory depth nor the
# filename may matter: "the JSON path moved once already" is the ticket's own
# words, and the shipped parser hardcoded both.
H4=$(ghome gh4 grok-usage-nested-ticks.jsonl chats/2026/09/15/xyz-9f2.jsonl)
OUT=$(bash "$GU" 0 "$H4")
[ "${OUT%% *}" = "402118" ] && ok \
  || bad "A4 a ledger under a different dir and filename must still be found: got '$OUT'"

# A5. an OLDER ledger belongs to a different call. Borrowing its tokens would
# INVENT spend, which is worse than a blank row.
H5=$(ghome gh5 grok-usage-nested-ticks.jsonl sessions/s5/updates.jsonl)
touch -t 202001010000 "$T/gh5/sessions/s5/updates.jsonl"
OUT=$(bash "$GU" "$(date +%s)" "$H5")
[ -z "$(tr -d ' ' <<<"$OUT")" ] && ok \
  || bad "A5 a ledger older than the call must be ignored, not attributed: got '$OUT'"

# A6. NEWEST WINS. Two ledgers both carrying usage: the stale one must not be
# the one billed. Without the mtime sort whichever file os.walk reaches first
# wins outright, and files at the root are walked before subdirectories.
H6=$(ghome gh6 grok-usage-nested-ticks.jsonl sessions/2026/09/15/current.jsonl)
for i in 1 2 3; do
  printf '%s\n' '{"params":{"update":{"usage":{"inputTokens":111,"outputTokens":9,"costUsdTicks":10000}}}}' \
    > "$T/gh6/stale-$i.jsonl"
  touch -t 202001010100 "$T/gh6/stale-$i.jsonl"
done
OUT=$(bash "$GU" 0 "$H6")
[ "${OUT%% *}" = "402118" ] && ok || bad "A6 the NEWEST ledger must be the one read: got '$OUT'"
[ "${OUT%% *}" != "111" ]   && ok || bad "A6 a stale session's tokens were billed to this call: got '$OUT'"

# A7. CREDENTIALS ARE NEVER READ. ~/.grok/auth.json sits in the same tree. It is
# skipped BY NAME, not by permissions — this suite runs as root on the fleet
# boxes, where mode 000 is not a barrier at all. The file is planted with a
# usage-shaped dict so that a reader which opened it would visibly win the
# "newest file" race and print its numbers.
H7=$(ghome gh7 grok-usage-nested-ticks.jsonl sessions/s7/updates.jsonl)
printf '%s\n' '{"inputTokens":66666666,"outputTokens":66666666,"apiKey":"SECRET-MARKER-406"}' > "$T/gh7/auth.json"
printf '%s\n' '{"inputTokens":66666666,"outputTokens":66666666,"refresh":"SECRET-MARKER-406"}' > "$T/gh7/credentials.json"
OUT=$(bash "$GU" 0 "$H7"); RC=$?
[ "$RC" = 0 ] && ok || bad "A7 a credentials file in the tree must not fail the reader (rc=$RC)"
grep -q 'SECRET-MARKER-406' <<<"$OUT" && bad "A7 credential content reached stdout: '$OUT'" || ok
grep -q '66666666' <<<"$OUT" && bad "A7 auth.json/credentials.json were PARSED for usage: '$OUT'" || ok
[ "${OUT%% *}" = "402118" ] && ok || bad "A7 the real ledger must still be read: got '$OUT'"

# A8. the naming families. The next drift is a rename, not a move.
mkdir -p "$T/gh8"
printf '%s\n' '{"usage":{"input_tokens":700,"output_tokens":80}}' > "$T/gh8/a.jsonl"
[ "$(bash "$GU" 0 "$T/gh8")" = "700 80   " ] && ok \
  || bad "A8 input_tokens/output_tokens must match: got '$(bash "$GU" 0 "$T/gh8")'"
rm -f "$T/gh8"/*.jsonl
printf '%s\n' '{"usage":{"prompt_tokens":60,"completion_tokens":5}}' > "$T/gh8/b.jsonl"
[ "$(bash "$GU" 0 "$T/gh8")" = "60 5   " ] && ok \
  || bad "A8 prompt_tokens/completion_tokens must match: got '$(bash "$GU" 0 "$T/gh8")'"
rm -f "$T/gh8"/*.jsonl
# a direct dollar figure, for a CLI that reports money without ticks
printf '%s\n' '{"usage":{"inputTokens":10,"outputTokens":2,"costUsd":0.25}}' > "$T/gh8/c.jsonl"
[ "$(bash "$GU" 0 "$T/gh8")" = "10 2   0.250000" ] && ok \
  || bad "A8 a direct costUsd must be read as dollars: got '$(bash "$GU" 0 "$T/gh8")'"
rm -f "$T/gh8"/*.jsonl
# ...and a whole-document JSON file, not only JSONL
printf '%s\n' '{"session":{"usage":{"inputTokens":33,"outputTokens":4}}}' > "$T/gh8/d.json"
[ "$(bash "$GU" 0 "$T/gh8")" = "33 4   " ] && ok \
  || bad "A8 a .json document must parse too: got '$(bash "$GU" 0 "$T/gh8")'"

# A9. junk must be blank, never a number, never a crash.
rm -rf "${T:?}/gh9"; mkdir -p "$T/gh9"
for B in '{"no":"usage"}' 'not json at all' '' '{"usage":{"inputTokens":"abc","outputTokens":null}}' '{"settings":{"maxInputTokens":900,"maxOutputTokens":9}}'; do
  printf '%s\n' "$B" > "$T/gh9/x.jsonl"
  OUT=$(bash "$GU" 0 "$T/gh9"); RC=$?
  [ "$RC" = 0 ] || bad "A9 must never fail the caller (rc=$RC on: $B)"
  [ -z "$(tr -d ' ' <<<"$OUT")" ] || bad "A9 a miss must be blank (got '$OUT' on: $B)"
done
ok
# a grok home that does not exist at all
OUT=$(bash "$GU" 0 "$T/no-such-home"); RC=$?
[ "$RC" = 0 ] && [ -z "$(tr -d ' ' <<<"$OUT")" ] && ok \
  || bad "A9 a missing grok home must be blank and rc 0 (rc=$RC, out='$OUT')"

# A10. the output is consumable the way agent-call.sh consumes it: five fields,
# blanks preserved, via the '|' substitution (a space-split slides the columns
# and drops the dollars out of the USD field).
IFS='|' read -r I O CRD CWR U <<<"$(bash "$GU" 0 "$H2" | tr ' ' '|')"
[ "$I" = 100000 ] && [ "$O" = 10000 ] && [ "$CRD" = 50000 ] && [ "$CWR" = 0 ] && [ -z "$U" ] && ok \
  || bad "A10 five fields must survive the '|' split (got '$I' '$O' '$CRD' '$CWR' '$U')"

# ── B. cost_price_tokens ─────────────────────────────────────────────────────
echo "--- B. cost_price_tokens"
awk '/^# >>> cost_price_tokens/{f=1;next} /^# <<< cost_price_tokens/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/bin/price.sh"
[ -s "$T/bin/price.sh" ] && grep -q 'cost_price_tokens()' "$T/bin/price.sh" && ok \
  || bad "B could not extract cost_price_tokens from bin/lib/cost-row.sh — markers missing?"
price() { ( MODEL_PRICES="$T/prices.json"; . "$T/bin/price.sh"; cost_price_tokens "$@" ); }

# The formula is cost-rollup.sh's row_cost(), to the digit: a row the call site
# priced and a row the rollup prices must never disagree.
#   100000*2e-6 + 10000*6e-6 + 50000*5e-7 + 1000*null(=0) = 0.285
[ "$(price grok-4.6 100000 10000 50000 1000)" = "0.285000" ] && ok \
  || bad "B the table price must match row_cost() to the digit: got '$(price grok-4.6 100000 10000 50000 1000)'"
[ "$(price grok-4.6 100000 10000 50000 0)" = "0.285000" ] && ok \
  || bad "B a null cache_write rate must contribute 0, not void the row: got '$(price grok-4.6 100000 10000 50000 0)'"
# ABSENT IS NOT ZERO, in both directions.
[ -z "$(price no-such-model 1000 100 0 0)" ] && ok \
  || bad "B a model the table does not know must price EMPTY, never 0: got '$(price no-such-model 1000 100 0 0)'"
[ -z "$(price grok-4.6 '' '' '' '')" ] && ok \
  || bad "B no counts at all must price EMPTY: got '$(price grok-4.6 '' '' '' '')'"
[ -z "$(price '' 10 10 0 0)" ] && ok || bad "B an empty model must price EMPTY"
# ...but a partial count set is still a price (cache columns are often absent).
[ "$(price grok-4.6 100000 10000 '' '')" = "0.260000" ] && ok \
  || bad "B absent cache counts must price as 0 tokens of cache: got '$(price grok-4.6 100000 10000 '' '')'"
# a table that is not there at all
[ -z "$( ( MODEL_PRICES="$T/nope.json"; . "$T/bin/price.sh"; cost_price_tokens grok-4.6 1000 100 0 0 ) )" ] && ok \
  || bad "B an unreadable price table must price EMPTY (the rollup prices it later), never 0"

# ── C. cost_parity_alert ─────────────────────────────────────────────────────
echo "--- C. cost_parity_alert"
awk '/^# >>> cost_parity_alert/{f=1;next} /^# <<< cost_parity_alert/{exit} f' \
  "$DIR/bin/lib/cost-row.sh" > "$T/bin/parity.sh"
[ -s "$T/bin/parity.sh" ] && grep -q 'cost_parity_alert()' "$T/bin/parity.sh" && ok \
  || bad "C could not extract cost_parity_alert from bin/lib/cost-row.sh — markers missing?"
AL="$T/logs/ALERTS.log"
pfire() { ( HARNESS="$T"; . "$T/bin/parity.sh"; cost_parity_alert "$@" ); }
pcount() { grep -c '\[cost-parity\] UNPRICED' "$AL" 2>/dev/null || true; }
reset_alerts() { : > "$AL"; rm -f "$T/flags/"alerted-cost-parity-*; }

# C1. the case the ticket is about: the call SUCCEEDED and reported nothing.
reset_alerts
pfire grok grok-4.6 triage 0 "" ""; RC=$?
[ "$RC" = 0 ] && ok || bad "C1 writing the alert must return 0 so the caller can tell (rc=$RC)"
[ "$(pcount)" = 1 ] && ok || bad "C1 an rc=0 call with no usage must page exactly once: $(pcount) line(s)"
L=$(grep '\[cost-parity\]' "$AL" | tail -1)
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+Z \[cost-parity\] UNPRICED grok grok-4.6 triage priced=0 rc=0' <<<"$L" && ok \
  || bad "C1 the line must name runner, model, stage and priced=0 after a UTC stamp (got: '$L')"
grep -q 'docs/COST.md#cost-capture-parity' <<<"$L" && ok \
  || bad "C1 the line must point at the family note (got: '$L')"
ls "$T/flags/" | grep -q "^alerted-cost-parity-grok-grok-4.6-triage-$(date -u +%Y%m%d)$" && ok \
  || bad "C1 the daily flag must be named alerted-cost-parity-<runner>-<model>-<stage>-<date> (have: $(ls "$T/flags/"))"

# C2. deduped per runner/model/stage/day — 217 lines in a day is how an alert
# stops being read.
pfire grok grok-4.6 triage 0 "" ""; RC=$?
[ "$RC" != 0 ] && ok || bad "C2 a deduped call must return nonzero so the caller knows it did not write"
[ "$(pcount)" = 1 ] && ok || bad "C2 the alert re-fired within the day: $(pcount) lines"
# ...but a DIFFERENT stage is a different fault and still pages.
pfire grok grok-4.6 plan 0 "" ""
[ "$(pcount)" = 2 ] && ok || bad "C2 a different stage must page separately: $(pcount) lines"
# ...and a model string with a slash must not become a path.
pfire grok x-ai/grok-4.6 triage 0 "" ""
ls "$T/flags/" | grep -q "^alerted-cost-parity-grok-x-ai_grok-4.6-triage-" && ok \
  || bad "C2 a model with a / must be sanitized into the flag name (have: $(ls "$T/flags/"))"

# C3. THE NEGATIVES. A failed call was never billed, and paging on it would
# bury the real one.
reset_alerts
pfire grok grok-4.6 triage 1 "" ""
[ "$(pcount)" = 0 ] && ok || bad "C3 a FAILED call must never page as unpriced spend: $(pcount) line(s)"
pfire grok grok-4.6 triage 137 "" ""
[ "$(pcount)" = 0 ] && ok || bad "C3 a killed call (rc=137) must never page: $(pcount) line(s)"
pfire grok grok-4.6 triage 0 5 ""
[ "$(pcount)" = 0 ] && ok || bad "C3 a call that reported input tokens is not unpriced: $(pcount) line(s)"
pfire grok grok-4.6 triage 0 "" 7
[ "$(pcount)" = 0 ] && ok || bad "C3 a call that reported output tokens is not unpriced: $(pcount) line(s)"
pfire grok grok-4.6 triage 0 100 10
[ "$(pcount)" = 0 ] && ok || bad "C3 a fully priced call must be silent: $(pcount) line(s)"
# C4. it is not grok-only: the ticket says "a runner call".
reset_alerts
pfire claude claude-opus-5 execute 0 "" ""
[ "$(pcount)" = 1 ] && ok || bad "C4 any runner returning success with no usage must page: $(pcount) line(s)"
grep -q 'UNPRICED claude claude-opus-5 execute' "$AL" && ok || bad "C4 the line must name the runner that missed"

# ── D. the production entry point: bin/agent-call.sh ─────────────────────────
echo "--- D. bin/agent-call.sh (driven)"
# A pure-seam green here would prove nothing: the bug shipped INSIDE the grok
# branch of agent-call.sh, and every $0.00 row came out of this script.
mkdir -p "$T/.grok/bin"
cat > "$T/.grok/bin/grok" <<'EOF'
#!/bin/bash
# fake grok CLI: writes the ledger the test asked for, then answers like the CLI.
if [ -n "${GROK_FIXTURE:-}" ]; then
  mkdir -p "$HOME/.grok/sessions/s-run"
  cp "$GROK_FIXTURE" "$HOME/.grok/sessions/s-run/updates.jsonl"
fi
echo "DECISION: BH-406 :: skip :: fake"
exit "${GROK_EXIT:-0}"
EOF
chmod +x "$T/.grok/bin/grok"
printf '#!/bin/bash\necho subscription\n' > "$T/fakebin/billing-mode.sh"; chmod +x "$T/fakebin/billing-mode.sh"
# GNU timeout is not on every dev box, and agent-call.sh wraps every runner in
# it. Same shim the sibling suite uses: strip --kill-after and the duration.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
chmod +x "$T/fakebin/timeout"

drive() { # drive <fixture-or-empty> <grok-exit> ; echoes agent-call's rc
  rm -rf "${T:?}/.grok/sessions"
  # THE SURVIVAL LADDER MUST NOT ENGAGE. Case D5 makes the fake grok FAIL, and
  # on a real fleet box the openrouter and fireworks keys are in the ambient
  # env with a real codex CLI on PATH — so an unfenced run of this test spends
  # actual money on two vendors and then reports rc=0 because the survival lane
  # succeeded. Dropping the keys is what makes runner_ready() refuse those
  # lanes; the configured fallback is pinned to grok so the claude lane cannot
  # answer either.
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY
    export HOME="$T" HARNESS="$T" PATH="$T/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" \
           CONTEXT_BUDGETS="$DIR/catalog/context-budgets.json" \
           GROK_FIXTURE="$1" GROK_EXIT="$2" \
           RUNNER_TRIAGE=grok RUNNER_TRIAGE_FALLBACK=grok
    bash "$DIR/bin/agent-call.sh" triage testproj grok-4.6 60 "$T/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}
col() { tail -1 "$T/logs/cost.csv" | awk -F, -v c="$1" '{print $c}'; }

rm -f "$T/logs/cost.csv"; reset_alerts
# D1. the verified shape, end to end: tokens AND the vendor's own dollars.
RC=$(drive "$FIX/grok-usage-nested-ticks.jsonl" 0)
[ "$RC" = 0 ] && ok || bad "D1 the driven call failed (rc=$RC)"
[ -s "$T/logs/cost.csv" ] && ok || bad "D1 no cost row was written at all"
[ "$(col 5)" = grok ] && ok || bad "D1 the row must be a grok row (got '$(col 5)')"
[ "$(col 9)" = 402118 ] && ok  || bad "D1 input_toks (col 9) must be the ledger's: got '$(col 9)'"
[ "$(col 10)" = 11003 ] && ok  || bad "D1 output_toks (col 10): got '$(col 10)'"
[ "$(col 11)" = 128044 ] && ok || bad "D1 cache_read (col 11): got '$(col 11)'"
[ "$(col 12)" = 2011 ] && ok   || bad "D1 cache_write (col 12): got '$(col 12)'"
# TEST-CHANGE: BH-3984 reverses the precedence: cost_usd is the table's price of
# the row's tokens (402118*2e-6 + 11003*6e-6 + 128044*5e-7 + 2011*null), and the
# vendor's ticks move to result_usd only (asserted below, unchanged).
[ "$(col 13)" = 0.934276 ] && ok || bad "D1 cost_usd (col 13) must be cost_price_tokens over the row's tokens, not the vendor's ticks: got '$(col 13)'"
[ "$(col 18)" = ledger ] && ok || bad "D1 row_source (col 18) must say the numbers came from the ledger: got '$(col 18)'"
[ "$(col 19)" = 0.905636 ] && ok || bad "D1 result_usd (col 19) must keep the vendor's own reading: got '$(col 19)'"
[ "$(pcount)" = 0 ] && ok || bad "D1 a priced call must not page: $(pcount) line(s)"

# D2. THE ROW THE SHIPPED PARSER DROPPED: tokens, no costUsdTicks. It must land
# priced from catalog/model-prices.json, and result_usd must stay empty because
# the vendor never said a dollar figure.
RC=$(drive "$FIX/grok-usage-no-ticks.jsonl" 0)
[ "$(col 9)" = 100000 ] && ok || bad "D2 a ticks-less session must still report tokens: got '$(col 9)'"
[ "$(col 13)" = 0.285000 ] && ok || bad "D2 cost_usd must be priced from the table: got '$(col 13)'"
[ "$(col 18)" = ledger ] && ok || bad "D2 row_source must be ledger: got '$(col 18)'"
[ -z "$(col 19)" ] && ok || bad "D2 result_usd must stay EMPTY when the vendor reported no dollars: got '$(col 19)'"
[ "$(pcount)" = 0 ] && ok || bad "D2 a priced call must not page: $(pcount) line(s)"

# D3. success, and NO usage anywhere. The row still lands (rc, duration, who
# paid are real), blank and honest — and the box pages on this FIRST one.
RC=$(drive "" 0)
[ "$RC" = 0 ] && ok || bad "D3 the driven call failed (rc=$RC)"
[ "$(col 5)" = grok ] && [ "$(col 7)" = 0 ] && ok || bad "D3 the row must still land: '$(tail -1 "$T/logs/cost.csv")'"
[ -z "$(col 9)" ] && ok  || bad "D3 input_toks must be EMPTY, not 0: got '$(col 9)'"
[ -z "$(col 13)" ] && ok || bad "D3 cost_usd must be EMPTY, not 0: got '$(col 13)'"
[ "$(col 18)" = none ] && ok || bad "D3 row_source must be none when nothing was read: got '$(col 18)'"
[ "$(pcount)" = 1 ] && ok || bad "D3 the FIRST unpriced call must page: $(pcount) line(s) in ALERTS.log"
grep -q '\[cost-parity\] UNPRICED grok grok-4.6 triage' "$AL" && ok \
  || bad "D3 the alert must name runner/model/stage: $(grep cost-parity "$AL" | tail -1)"

# D4. ...once. Two more identical calls must not add a line.
drive "" 0 >/dev/null; drive "" 0 >/dev/null
[ "$(pcount)" = 1 ] && ok || bad "D4 the call-site alert re-fired within the day: $(pcount) lines"

# D5. a FAILED grok call is not unpriced spend — nothing was billed.
reset_alerts
RC=$(drive "" 1)
[ "$RC" != 0 ] && ok || bad "D5 a failing runner must not report success (rc=$RC)"
[ "$(col 7)" != 0 ] && ok || bad "D5 the row must carry the real rc: got '$(col 7)'"
[ "$(pcount)" = 0 ] && ok || bad "D5 a failed call must never page as unpriced: $(pcount) line(s)"

# D6. HARNESS stays overridable — every assertion above depends on it, and a
# regression to a hardcoded absolute would silently point this suite at the hub.
grep -q 'HARNESS="${HARNESS:-/root/harness}"' "$DIR/bin/agent-call.sh" && ok \
  || bad "D6 agent-call.sh's HARNESS is no longer overridable — this suite would write to the real hub paths"

echo "cost-grok-usage-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
