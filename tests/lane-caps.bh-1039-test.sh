#!/bin/bash
# tests/lane-caps.bh-1039-test.sh — bin/lib/lane-caps.sh: the daily dollar cap,
# the evidence byte cap, and the reader that prices what the vendor did not
# (BH-1039).
#
# WHAT IS AT STAKE. On 2026-09-20 alert-triage spent $793 in 12 hours inside a
# session cap that never moved — the per-session PRICE went up ~100x when the
# grok lane cliff-routed down to Fable-over-OpenRouter. Three properties decide
# whether this library would have stopped that:
#
#   1. the cap is stated in DOLLARS PER DAY, resolved from a file an operator
#      can edit without a deploy, and an env override can raise it for one run;
#   2. a row with tokens and a BLANK cost column is PRICED, not counted as
#      $0.00 — these are the "unpriced lanes" of the ticket title, and a cap
#      that reads blank as free is a cap that never fires on them;
#   3. the trip writes exactly ONE ALERTS line per lane per UTC day, and stays
#      silent under the cap. An alarm that rings 144 times is an alarm nobody
#      reads, and one that rings while the lane is healthy is worse.
#
# Everything is DRIVEN: the library is sourced and its functions called, and the
# pricing assertion is cross-checked against cost_price_tokens so this file can
# never quietly become a second pricing formula.
#
# Run from anywhere: tests/lane-caps.bh-1039-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# THE DAY IS PINNED. Every fixture row below carries this literal date, and the
# library reads it from LANE_CAPS_DAY — so this suite is the same on any wall
# clock, and the "today only" assertion has a real yesterday to exclude.
DAY=2026-09-20
DAYC=20260920
YESTERDAY=2026-09-19

mkdir -p "$T/h/logs" "$T/h/flags" "$T/h/catalog"

HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")

cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015,
                       "cache_read": 3e-7, "cache_write": 0.00000375},
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
               "cache_write": null, "cliff_tokens": 200000}
}}
EOF

# The conf an operator would write. Its whole grammar is exercised: a capped
# lane, a deliberately uncapped one, a default, and a row that cannot bind.
cat > "$T/lane-caps.conf" <<'EOF'
# a comment
lane alert-triage 120 20000
lane medic 90 40000
lane never-stop off 15000
lane broken notanumber 999
default 200 20000
ceiling 4000
EOF

fresh_ledger() { printf '%s\n' "$HDR" > "$T/h/logs/cost.csv"; }
# THE TWO COLUMNS ARE DELIBERATELY DIFFERENT. cost.csv is `...,project,stage,...`
# ($3,$4), and all three lanes call `agent-call.sh triage <lane>` — so the LANE
# name is in the PROJECT column and the stage column reads `triage` for every
# one of them. A fixture that put the lane name in both would pass a reader that
# only looked at $4, which sums $0.00 on a real hub forever. It did, once.
row() { # row <day> <lane> <cost_usd> <model> <in> <out> <cache_read> <cache_write>
  local r n
  r="${1}T04:00:00Z,box,$2,triage,openrouter,$4,0,10,$5,$6,$7,$8,$3,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$T/h/logs/cost.csv"
}

# One subshell per call so the library's load-once cache never leaks a conf or
# an env override into the next assertion.
lc() { # lc <env assignments...> -- <function> <args...>
  local envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  shift
  ( export HARNESS="$T/h" COST="$T/h/logs/cost.csv" LANE_CAPS_DAY="$DAY" \
           MODEL_PRICES="$T/prices.json" "${envs[@]}"
    . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
    . "$DIR/bin/lib/lane-caps.sh" || exit 9
    "$@" )
}

echo "--- A. the conf grammar"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_cap_usd alert-triage)
[ "$V" = 120 ] && ok || bad "A1 a lane row must set the lane's daily dollar cap (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_cap_bytes medic)
[ "$V" = 40000 ] && ok || bad "A2 a lane row must set the lane's evidence byte cap (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_cap_usd responder)
[ "$V" = 200 ] && ok || bad "A3 an unlisted lane takes the default, never 'unbounded' (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_cap_usd never-stop)
[ "$V" = off ] && ok || bad "A4 'off' is a VALUE a lane can carry — deliberately uncapped (got '$V')"
# The refusal, and it must be NAMED: a row that binds nothing is the threshold
# nobody can see, which is the whole failure the conf file exists to end.
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_caps_legacy_rows)
case "$V" in *lane:broken*) ok ;; *) bad "A5 a lane row with a non-numeric cap must be named as refused (got '$V')" ;; esac
case "$V" in *ceiling*) ok ;; *) bad "A5b an unknown keyword must be named as refused (got '$V')" ;; esac
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_cap_usd broken)
[ "$V" = 200 ] && ok || bad "A6 a refused row must fall to the default, not to a half-parsed value (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_caps_source)
[ "$V" = "$T/lane-caps.conf" ] && ok || bad "A7 the source file must be nameable (got '$V')"
# No conf anywhere but the repo's own: the committed catalog answers, and the
# three lanes of this ticket are all in it.
V=$(lc -- lane_cap_usd alert-triage)
[ -n "$V" ] && [ "$V" != off ] && ok || bad "A8 catalog/lane-caps.conf must cap alert-triage (got '$V')"
V=$(lc -- lane_caps_legacy_rows)
[ -z "${V//[[:space:]]/}" ] && ok || bad "A8b the committed catalog must have no refused rows (got '$V')"

echo "--- B. the env override"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_USD_CAP_ALERT_TRIAGE=5 -- lane_cap_usd alert-triage)
[ "$V" = 5 ] && ok || bad "B1 LANE_USD_CAP_<LANE> must beat the conf (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_USD_CAP_ALERT_TRIAGE=off -- lane_cap_usd alert-triage)
[ "$V" = off ] && ok || bad "B2 the operator's one-run release valve must be 'off' (got '$V')"
# The negative direction, and it is the one that matters: a typo must not remove
# a bound. Garbage falls back to the configured cap rather than to uncapped.
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_USD_CAP_ALERT_TRIAGE=oops -- lane_cap_usd alert-triage)
[ "$V" = 120 ] && ok || bad "B3 an unparseable env override must NOT read as uncapped (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=77 -- lane_cap_bytes alert-triage)
[ "$V" = 77 ] && ok || bad "B4 LANE_BYTES_CAP_<LANE> must beat the conf (got '$V')"

echo "--- C. the evidence cap and its marker"
SHORT="one line of evidence"
V=$(printf '%s' "$SHORT" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_evidence_cap alert-triage)
[ "$V" = "$SHORT" ] && ok || bad "C1 evidence under the cap must pass through byte for byte (got '$V')"
BIG=$(awk 'BEGIN{for(i=1;i<=400;i++) printf "line %04d of evidence padding\n", i}')
BIGN=$(printf '%s' "$BIG" | wc -c | tr -d ' ')
V=$(printf '%s' "$BIG" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=500 -- lane_evidence_cap alert-triage)
VN=$(printf '%s' "$V" | wc -c | tr -d ' ')
[ "$BIGN" -gt 500 ] && ok || bad "C2 the fixture must actually exceed the cap (it is ${BIGN}B)"
# The cap binds the EVIDENCE; the marker is allowed to be the one thing above
# it, because a prompt that silently ends mid-sentence is the failure here.
[ "$VN" -le $(( 500 + 300 )) ] && ok || bad "C3 capped evidence must come back at about the cap (got ${VN}B for a 500B cap)"
case "$V" in *"[capped:"*) ok ;; *) bad "C4 a truncation must carry a MARKER, never be silent: $(head -c 120 <<<"$V")" ;; esac
case "$V" in *"$(printf '%s' "$BIG" | tail -1)"*) ok ;; *) bad "C5 the NEWEST evidence must survive the cut (oldest-first drop)" ;; esac
case "$V" in *"line 0001 of evidence"*) bad "C6 the oldest line must be the one dropped" ;; *) ok ;; esac

echo "--- D. lane_day_usd: today only, and blank rows are PRICED"
fresh_ledger
row "$DAY" alert-triage 3.00 claude-fable-5.1 1000 100 0 0
row "$DAY" alert-triage 4.00 claude-fable-5.1 1000 100 0 0
row "$YESTERDAY" alert-triage 500.00 claude-fable-5.1 1000 100 0 0
row "$DAY" medic 1.00 claude-fable-5.1 1000 100 0 0
V=$(lc -- lane_day_usd alert-triage)
[ "$V" = 7.00 ] && ok || bad "D1 the day total must be this lane, this UTC day (got '$V', expected 7.00)"
V=$(lc -- lane_day_usd medic)
[ "$V" = 1.00 ] && ok || bad "D2 another lane's rows must not count (got '$V')"
V=$(lc -- lane_day_usd responder)
[ "$V" = 0.00 ] && ok || bad "D3 a lane with no rows spends nothing (got '$V')"
# The column the lane name actually lives in. All four rows above carry the same
# stage (`triage`) and differ only in the project column, so a reader that keyed
# on the stage would answer 8.00 for alert-triage here and 0.00 on a real hub.
V=$(lc -- lane_day_usd triage)
[ "$V" = 8.00 ] && ok || bad "D3b the shared stage must answer for every lane under it (got '$V')"

# THE UNPRICED ROW. Tokens, empty cost column — exactly what a runner whose
# usage capture missed writes, and what makes these three lanes "unpriced".
fresh_ledger
row "$DAY" alert-triage "" claude-fable-5.1 1000000 20000 0 0
EXPECT=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
          MODEL_PRICES="$T/prices.json" cost_price_tokens claude-fable-5.1 1000000 20000 0 0 )
EXPECT2=$(awk -v v="$EXPECT" 'BEGIN{printf "%.2f", v + 0}')
V=$(lc -- lane_day_usd alert-triage)
[ "$V" = "$EXPECT2" ] && ok \
  || bad "D4 a row with tokens and a BLANK cost must be priced from the tokens (got '$V', cost_price_tokens says '$EXPECT2')"
awk -v v="$EXPECT2" 'BEGIN{exit !(v+0 > 0)}' && ok || bad "D4b the pricing fixture must produce real dollars, or D4 proves nothing"
# ...and the cliff is honoured, because the price comes from the one formula
# that knows about it rather than from a second one written here.
fresh_ledger
row "$DAY" alert-triage "" grok-4.6 400000 1000 0 0
V=$(lc -- lane_day_usd alert-triage)
E=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
     MODEL_PRICES="$T/prices.json" cost_price_tokens grok-4.6 400000 1000 0 0 )
E2=$(awk -v v="$E" 'BEGIN{printf "%.2f", v + 0}')
[ "$V" = "$E2" ] && ok || bad "D5 a blank grok row past the cliff must price the same as cost_price_tokens (got '$V' vs '$E2')"

# FAIL OPEN, AND SAY SO. No ledger at all is $0.00 and a lane that keeps
# running — never a lane stopped because a file was missing.
rm -f "$T/h/logs/cost.csv" "$T/h/flags/"lane-caps-degraded-alert-triage-*
V=$(lc -- lane_day_usd alert-triage)
[ "$V" = 0.00 ] && ok || bad "D6 an unreadable ledger must fail OPEN at \$0.00 (got '$V')"
grep -q 'no cost ledger' "$T/h/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "D6b a fail-open degrade must write a line, or it reads like a real zero"

echo "--- E. the trip, and its single alert"
rm -f "$T/h/flags/"alerted-lane-usd-* "$T/h/logs/ALERTS.log"
fresh_ledger
row "$DAY" alert-triage 5.00 claude-fable-5.1 1000 100 0 0
lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_cap_tripped alert-triage \
  && bad "E1 \$5 against a \$120 cap must NOT trip" || ok
[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "E1b a healthy lane must page nothing: $(cat "$T/h/logs/ALERTS.log")"
row "$DAY" alert-triage 200.00 claude-fable-5.1 1000 100 0 0
lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_cap_tripped alert-triage \
  && ok || bad "E2 \$205 against a \$120 cap must trip"
[ "$(grep -c 'DAILY SPEND CAP' "$T/h/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "E3 the trip must page exactly once: $(cat "$T/h/logs/ALERTS.log")"
grep -q '205.00' "$T/h/logs/ALERTS.log" && ok || bad "E3b the page must carry the real spend"
grep -q 'LANE_USD_CAP_ALERT_TRIAGE' "$T/h/logs/ALERTS.log" \
  && ok || bad "E3c the page must name the knob that releases it"
# The second tick of the same day trips again (the lane stays stopped) and does
# NOT page again.
lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_cap_tripped alert-triage \
  && ok || bad "E4 the lane must stay stopped for the rest of the day"
[ "$(grep -c 'DAILY SPEND CAP' "$T/h/logs/ALERTS.log")" = 1 ] \
  && ok || bad "E4b 144 ticks must not mean 144 pages: $(grep -c 'DAILY SPEND CAP' "$T/h/logs/ALERTS.log")"
# `off` means the lane is never stopped, however much it spent.
lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_USD_CAP_ALERT_TRIAGE=off -- lane_day_cap_tripped alert-triage \
  && bad "E5 an 'off' cap must never trip" || ok

echo "--- F. what the cut leaves behind, and what the grammar refuses (round 1)"
# F1. NO HEADLESS FRAGMENT. `tail -c` cuts at a byte, so the first surviving
# line used to be a record with its head chopped off — in alerts-medic.sh an
# `id<TAB>line` whose id is gone. Every line the model is handed must be whole.
REC=$(awk 'BEGIN{for(i=1;i<=40;i++) printf "alert-%04d\tthe widget subsystem is unhappy, padding padding padding\n", i}')
V=$(printf '%s' "$REC" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=400 -- lane_evidence_cap alert-triage)
FIRST=$(printf '%s\n' "$V" | sed -n '2p')
case "$FIRST" in
  alert-*) ok ;;
  *) bad "F1 the first line after the marker must be a WHOLE record, not a fragment (got '$FIRST')" ;;
esac
# ...and every surviving line, not just the first.
BADLINES=$(printf '%s\n' "$V" | sed '1d' | grep -cv $'^alert-[0-9]\{4\}\t')
[ "${BADLINES:-1}" = 0 ] && ok || bad "F1b $BADLINES surviving line(s) are not whole records"
# F2. The marker must still be there, and must count the bytes it ACTUALLY
# dropped (head-line included), or the declaration is a second lie.
case "$V" in *"[capped:"*) ok ;; *) bad "F2 the whole-line cut must still declare itself" ;; esac
RECN=$(printf '%s' "$REC" | wc -c | tr -d ' ')
KEPTN=$(printf '%s\n' "$V" | sed '1d' | wc -c | tr -d ' ')
DROPN=$(printf '%s\n' "$V" | sed -n '1p' | sed -n 's/.*dropped \([0-9]*\) of.*/\1/p')
[ -n "$DROPN" ] && [ "$(( DROPN + KEPTN ))" -ge "$(( RECN - 1 ))" ] && [ "$(( DROPN + KEPTN ))" -le "$(( RECN + 1 ))" ] \
  && ok || bad "F2b dropped($DROPN) + kept($KEPTN) must account for the whole ${RECN}B input"
# F3. A cap too small for ONE record keeps nothing and says so — half a record
# is worse evidence than a declared absence.
V=$(printf '%s' "$REC" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=10 -- lane_evidence_cap alert-triage)
F3RC=$?
[ "$(printf '%s\n' "$V" | wc -l | tr -d ' ')" = 1 ] \
  && ok || bad "F3 a cap under one record must emit the marker alone (got: $V)"
case "$V" in *"not one COMPLETE line fits"*) ok ;; *) bad "F3b and it must say that is what happened (got '$V')" ;; esac
# F3c. AND THE RC SAYS SO (round 2, I4). The marker alone is a declared absence
# of evidence, and a caller that buys a paid session on it is buying nothing —
# alert-triage did, on the strong tier, and stamped the family into its 6h brake
# on the way. The rc is what lets both callers decline.
[ "$F3RC" = 2 ] \
  && ok || bad "F3c marker-only evidence must come back rc 2, not rc 0 (got $F3RC)"
V=$(printf '%s' "$REC" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=400 -- lane_evidence_cap alert-triage)
[ "$?" = 0 ] && ok || bad "F3d a cut that keeps whole records is still rc 0"

# F4. THE BYTE COLUMN IS AN INTEGER. `1.5` used to be accepted, and then
# `tail -c 1.5` plus `$(( n - 1.5 ))` emptied the evidence with two bash errors
# while the paid session still went out.
cat > "$T/decimal.conf" <<'EOF'
lane medic 90 1.5
default 200 20000
EOF
V=$(lc "LANE_CAPS_CONF=$T/decimal.conf" -- lane_cap_bytes medic)
[ "$V" = 20000 ] && ok || bad "F4 a decimal byte cap must not bind — the default stands (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/decimal.conf" -- lane_caps_legacy_rows)
case "$V" in *medic*) ok ;; *) bad "F4b a refused byte column must be NAMED, not silently dropped (got '$V')" ;; esac
V=$(lc "LANE_CAPS_CONF=$T/decimal.conf" -- lane_cap_usd medic)
[ "$V" = 90 ] && ok || bad "F4c the dollar column of that row is fine and must still bind (got '$V')"
# The env override of the same shape is ignored too, and the evidence survives.
V=$(printf '%s' "$REC" | lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=1.5 -- lane_evidence_cap alert-triage 2>/dev/null)
[ -n "$V" ] && ok || bad "F4d a decimal env byte cap must not empty the evidence"
case "$V" in *"alert-0040"*) ok ;; *) bad "F4e the evidence must come back intact under the configured cap" ;; esac
# Dollars stay decimal — 90.50 is a legitimate cap and must not be refused.
cat > "$T/cents.conf" <<'EOF'
lane medic 90.50 40000
EOF
V=$(lc "LANE_CAPS_CONF=$T/cents.conf" -- lane_cap_usd medic)
[ "$V" = 90.50 ] && ok || bad "F4f a decimal DOLLAR cap must still bind (got '$V')"

# F5. THE LEDGER READ IS BOUNDED. cost.csv is append-only for the life of the
# box and three lanes ask this on every tick; an unbounded double scan is a cost
# the cap itself starts paying.
fresh_ledger
I=0; while [ "$I" -lt 30 ]; do row "$DAY" alert-triage 1.00 claude-fable-5.1 1000 100 0 0; I=$((I+1)); done
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_usd alert-triage)
[ "$V" = 30.00 ] && ok || bad "F5 the unbounded-window total must be \$30.00 (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_CAPS_SCAN=5 -- lane_day_usd alert-triage)
[ "$V" = 5.00 ] && ok || bad "F5b LANE_CAPS_SCAN must bound the rows read (got '$V' for a 5-row window)"

echo "--- G. what the conf, the log and the window declare (round 2)"
# G1. INLINE COMMENTS ARE COMMENTS (round 2, N1). `read -r kw a b c` put
# `40000 # why` in the byte column, so a row an operator can read in the file
# bound no byte cap at all and was reported as a REFUSED row instead.
cat > "$T/inline.conf" <<'EOF'
lane medic 90 40000 # the medic reads whole console alerts
lane alert-triage 120 20000   # keep the triage prompt small
default 200 20000
EOF
V=$(lc "LANE_CAPS_CONF=$T/inline.conf" -- lane_cap_bytes medic)
[ "$V" = 40000 ] && ok || bad "G1 an inline comment must not eat the byte column (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/inline.conf" -- lane_cap_usd medic)
[ "$V" = 90 ] && ok || bad "G1b ...and the dollar column still binds (got '$V')"
V=$(lc "LANE_CAPS_CONF=$T/inline.conf" -- lane_caps_legacy_rows)
[ -z "${V//[[:space:]]/}" ] && ok || bad "G1c a commented row must not be reported as refused (got '$V')"
# A row that is ALL comment still binds nothing, as before.
cat > "$T/allcomment.conf" <<'EOF'
# lane medic 90 40000
default 200 20000
EOF
V=$(lc "LANE_CAPS_CONF=$T/allcomment.conf" -- lane_cap_bytes medic)
[ "$V" = 20000 ] && ok || bad "G1d a fully commented-out row must bind nothing (got '$V')"

# G2. A SECOND, DIFFERENT DEGRADE MUST STILL BE SAID (round 2, N3). One flag per
# lane per day meant the first degrade of the day silenced every later one —
# including a different fault on the same lane, which is the one a reader needs.
rm -f "$T/h/flags/"lane-caps-degraded-alert-triage-* "$T/h/logs/lane-caps.log"
lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_BYTES_CAP_ALERT_TRIAGE=1.5 -- lane_cap_bytes alert-triage >/dev/null
rm -f "$T/h/logs/cost.csv"
lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_usd alert-triage >/dev/null
grep -q 'is not a whole number of bytes' "$T/h/logs/lane-caps.log" \
  && ok || bad "G2 the first degrade must be logged: $(cat "$T/h/logs/lane-caps.log" 2>/dev/null)"
grep -q 'no cost ledger' "$T/h/logs/lane-caps.log" \
  && ok || bad "G2b a LATER, DIFFERENT degrade on the same lane must not be swallowed: $(cat "$T/h/logs/lane-caps.log" 2>/dev/null)"
# ...and the SAME message still says itself once a day.
lc "LANE_CAPS_CONF=$T/lane-caps.conf" -- lane_day_usd alert-triage >/dev/null
[ "$(grep -c 'no cost ledger' "$T/h/logs/lane-caps.log")" = 1 ] \
  && ok || bad "G2c the same degrade must still be deduped per lane per day"

# G3. THE BOUNDED WINDOW DECLARES ITSELF (round 2, N2). LANE_CAPS_SCAN is a
# guess about one UTC day of one lane; when the window's OLDEST row is already
# dated today the total can read LOW, and a cap that reads low in silence is a
# cap that does not fire.
rm -f "$T/h/flags/"lane-caps-degraded-alert-triage-* "$T/h/logs/lane-caps.log"
fresh_ledger
I=0; while [ "$I" -lt 30 ]; do row "$DAY" alert-triage 1.00 claude-fable-5.1 1000 100 0 0; I=$((I+1)); done
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_CAPS_SCAN=5 -- lane_day_usd alert-triage)
[ "$V" = 5.00 ] && ok || bad "G3-setup a 5-row window must total \$5.00 (got '$V')"
grep -q 'LANE_CAPS_SCAN' "$T/h/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "G3 a window that may not reach the day's first row must SAY the total can read low"
# The honest negative: a window that reaches back past today says nothing.
rm -f "$T/h/flags/"lane-caps-degraded-alert-triage-* "$T/h/logs/lane-caps.log"
fresh_ledger
row "$YESTERDAY" alert-triage 1.00 claude-fable-5.1 1000 100 0 0
row "$DAY" alert-triage 2.00 claude-fable-5.1 1000 100 0 0
V=$(lc "LANE_CAPS_CONF=$T/lane-caps.conf" LANE_CAPS_SCAN=2 -- lane_day_usd alert-triage)
[ "$V" = 2.00 ] && ok || bad "G3b-setup the window must still total today only (got '$V')"
! grep -q 'LANE_CAPS_SCAN' "$T/h/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "G3b a window that DOES reach yesterday must not cry shortfall: $(cat "$T/h/logs/lane-caps.log" 2>/dev/null)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
