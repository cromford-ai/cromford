#!/bin/bash
# tests/triage-session-cap-zero.bh-1164-test.sh — a session cap of ZERO must buy
# ZERO sessions, and the daily dollar cap that backstops it must not default to
# $200 on a box that never got the conf (BH-1164).
#
# THE INCIDENT. 2026-09-20 16:10Z-21:20Z on the hub, immediately after BH-1039
# deployed. `TRIAGE_MAX_FAMILIES=0` was the operator's pause — the only stop the
# lane had — and it held from 12:30 to 16:10 ("deferred 488 families — session
# cap (0)", zero cost rows). After 16:10 every */10 tick logged:
#
#   triage pass: 1 of 1037 line(s) across 1 famil(ies) — one session each
#   triage pass: deferred 659 families to next tick — session cap (0)
#   triage session [family ..., 1 line(s), tier=strong]: handled=0 escalated=0 noise=1
#
# — one bought session per tick, ~$2-4 each, 11 rows and $38 in two hours, every
# one of them `noise=1`. The splitter's `cap = max(1, int(capstr))` clamps the
# cap UP to 1, so the first family always crosses. A pause knob that still buys
# a session per tick is not a pause; it is a slower burn that reads as stopped
# in the operator's head and in the lane log's own "session cap (0)" line.
#
# What finally stopped it was `lane_day_cap_tripped alert-triage` at 21:20Z — on
# `LANE_CAPS_DEFAULT_USD=200`, because the hub had the LIBRARY but not
# `catalog/lane-caps.conf`, so the reviewed `lane alert-triage 120` row never
# applied. A built-in fallback that is 3-5x the lane's own observed daily spend
# is a cap in name only.
#
# Four properties, each of which had to be false for that to happen:
#   A  TRIAGE_MAX_FAMILIES=0 buys NO session, consumes nothing, stamps nothing,
#      leaves the spooled work spooled, and says so once per tick without paging;
#   B  the same for the medic's MEDIC_MAX_FAMILIES=0 (identical `max(1, ...)`);
#   C  a box with NO lane-caps.conf falls back to $50/day, not $200, and the
#      shipped conf puts alert-triage at $5; a cap of `0` means OFF (stopped),
#      not "that is not a number, take the default";
#   D  the caps declare themselves — the effective cap, its source, and the
#      machine-readable knob rows the lanes registry (BH-1132) shows an operator.
#
# A and B run the REAL bin/alert-triage.sh and bin/alerts-medic.sh end to end,
# exactly as tests/triage-volume-caps.bh-1039-test.sh and
# tests/lane-day-cap.bh-1039-test.sh do: only the harness ROOT is rewritten, and
# only what would leave this machine or spend money is stubbed. What the
# agent-call stub RECEIVES — or never receives — is the assertion.
#
# Run from anywhere: tests/triage-session-cap-zero.bh-1164-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock anchor for the whole suite; every fixture is derived from it, so
# nothing here depends on the wall clock.
NOW=$(date -u +%s)
DAY=$(date -u +%Y-%m-%d)

HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
# Lane name in the PROJECT column and `triage` in the stage column — the shape
# `agent-call.sh triage <lane>` actually writes on a live hub.
crow() { # crow <ledger> <lane> <cost_usd>
  local r n
  r="${DAY}T04:00:00Z,box,$2,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0,$3,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$1"
}

cat > "$T/prices.json" <<'EOF'
{"per_token": {"claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015,
                                    "cache_read": 3e-7, "cache_write": 0.00000375}}}
EOF

# ============================================================================
# A. bin/alert-triage.sh with TRIAGE_MAX_FAMILIES=0
# ============================================================================
echo "--- A. TRIAGE_MAX_FAMILIES=0 buys nothing and loses nothing"
H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/catalog" \
         "$T/stub" "$T/calls"
: > "$H/env/global.env"
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
chmod +x "$H/bin/alert-triage.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sfn "$DIR/bin/lib" "$H/bin/lib"
ln -sf "$DIR/bin/alert-line.sh" "$H/bin/alert-line.sh"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1
HP="$H/state/alert-triage/cromford"   # BH-5942: the home project's run owns these lines

# A generous, explicitly-configured dollar cap, so NOTHING in section A can be
# explained by the day cap: the only thing under test here is the session cap.
cat > "$H/catalog/lane-caps.conf" <<'EOF'
lane alert-triage 999 20000
default 999 20000
EOF

# The agent-call stub records every call. A call at all is the failure.
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=0 escalated=0 noise=1" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"
# Every box SSH is counted: "the lane bought nothing" includes not reaching out
# to eight boxes every ten minutes to collect work it will not look at.
cat > "$T/stub/ssh" <<STUB
#!/bin/sh
echo ssh >> "$T/ssh.log"
exit 0
STUB
chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

q() { # q <file> <age-secs> <project> <akey> <line>
  printf '%s\t{"kind":"fleet_alert","project":"%s","akey":"%s","line":"%s"}\n' \
    "$(( NOW - $2 ))" "$3" "$4" "$5" >> "$1"
}
run() { # run [env assignments...]
  rm -rf "${T:?}/calls"; mkdir -p "$T/calls"
  ( export CALLDIR="$T/calls" PATH="$T/stub:$PATH" MODEL_PRICES="$T/prices.json" \
           LANE_CAPS_CONF="$H/catalog/lane-caps.conf"
    [ "$#" -gt 0 ] && export "$@"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
}
ncalls()   { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
famcount() { [ -e "$HP/alert-families.json" ] || { echo 0; return; }; python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HP/alert-families.json"; }
reset_state() {
  triage_tick_reset "$H"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"; : > "$T/ssh.log"
  echo '{}' > "$H/state/alert-families.json"
  : > "$H/state/alert-triage-deferred.tsv"
  : > "$H/state/alert-quarantine.jsonl"
  rm -f "$H/flags/"alerted-lane-usd-* "$H/flags/"alerted-triage-*
  printf '%s\n' "$HDR" > "$H/logs/cost.csv"
}

# A1-A6. THE RED CASE, exactly as the hub ran it: the cap is 0 and ONE brand-new
# family is waiting. A brand-new family is the one the 6h brake cannot stop, so
# this is the shape that crossed 144 times a day.
reset_state
q "$H/state/alert-quarantine.jsonl" 60 project-1 "widget-1" "the widget subsystem is unhappy"
run TRIAGE_MAX_FAMILIES=0
[ "$(ncalls)" = 0 ] \
  && ok || bad "A1 TRIAGE_MAX_FAMILIES=0 must buy NO session (got $(ncalls))"
[ "$(famcount)" = 0 ] \
  && ok || bad "A2 a family nobody looked at must not be stamped into the 6h brake (stamped $(famcount))"
[ -s "$H/state/alert-quarantine.jsonl" ] || [ -s "$H/state/alert-triage-deferred.tsv" ] \
  && ok || bad "A3 the work must still be there — quarantined or spooled, never consumed and dropped"
grep -q 'the widget subsystem is unhappy' \
     "$H/state/alert-quarantine.jsonl" "$H/state/alert-triage-deferred.tsv" \
  && ok || bad "A4 the alert's own line must survive the stopped tick"
grep -qi 'TRIAGE_MAX_FAMILIES' "$H/logs/alert-triage.log" \
  && ok || bad "A5 the stop must name the knob that caused it: $(cat "$H/logs/alert-triage.log")"
[ ! -s "$H/logs/ALERTS.log" ] \
  && ok || bad "A6 a DELIBERATE operator pause must not page 144 times a day: $(cat "$H/logs/ALERTS.log")"

# A7. NOT EVEN ONE COST ROW'S WORTH OF WORK. The lane must reach zero boxes: a
# stopped lane that still SSHes eight boxes every ten minutes to drain their
# quarantines into a spool it will not read is doing work for nothing, and it
# moves the alerts off the boxes whose own dead-man (alert-flush.sh, 45 min) is
# what escalates them while triage is off.
[ ! -s "$T/ssh.log" ] \
  && ok || bad "A7 a stopped lane must not collect: $(wc -l < "$T/ssh.log") box fetch(es)"

# A8-A9. THE SPOOLED BACKLOG STAYS SPOOLED. This is how the hub was actually
# configured: 659 families already parked on state/alert-triage-deferred.tsv
# from the ticks before the pause. Those lines must neither be triaged nor
# churned back and forth through the drain.
reset_state
printf 'hub\t%s\t{"kind":"fleet_alert","project":"project-1","akey":"spooled-1","line":"the gasket subsystem is unhappy"}\n' \
  "$(( NOW - 600 ))" > "$H/state/alert-triage-deferred.tsv"
run TRIAGE_MAX_FAMILIES=0
[ "$(ncalls)" = 0 ] \
  && ok || bad "A8 a spooled family must not be triaged under a zero cap (got $(ncalls))"
[ "$(grep -c 'the gasket subsystem is unhappy' "$H/state/alert-triage-deferred.tsv")" = 1 ] \
  && ok || bad "A9 the spooled line must still be spooled exactly once (got $(grep -c 'gasket' "$H/state/alert-triage-deferred.tsv"))"
# ...and a second tick changes nothing: no session, no duplicate, no growth.
run TRIAGE_MAX_FAMILIES=0
[ "$(ncalls)" = 0 ] \
  && ok || bad "A9b a second stopped tick must still buy nothing (got $(ncalls))"
[ "$(grep -c 'the gasket subsystem is unhappy' "$H/state/alert-triage-deferred.tsv")" = 1 ] \
  && ok || bad "A9c ...and must not duplicate the spooled line (got $(grep -c 'gasket' "$H/state/alert-triage-deferred.tsv"))"

# A10. THE KNOB STILL WORKS THE OTHER WAY. A guard that is off by one would turn
# the lane off at its DEFAULT setting, which is the same outage wearing the
# opposite sign — so 1 buys exactly one session and the unset default buys one
# for the single family present.
reset_state
q "$H/state/alert-quarantine.jsonl" 60 project-1 "widget-2" "the widget subsystem is unhappy"
run TRIAGE_MAX_FAMILIES=1
[ "$(ncalls)" = 1 ] && ok || bad "A10 a cap of 1 must still buy one session (got $(ncalls))"
reset_state
q "$H/state/alert-quarantine.jsonl" 60 project-1 "widget-3" "the flange subsystem is unhappy"
run
[ "$(ncalls)" = 1 ] && ok || bad "A10b the unset default must still buy a session (got $(ncalls))"

# A11. A NEGATIVE CAP IS OFF, NOT ONE. `max(1, int(capstr))` read -1 as 1 too.
reset_state
q "$H/state/alert-quarantine.jsonl" 60 project-1 "widget-4" "the widget subsystem is unhappy"
run TRIAGE_MAX_FAMILIES=-1
[ "$(ncalls)" = 0 ] && ok || bad "A11 a negative cap must be OFF, never clamped up to 1 (got $(ncalls))"

# A12. A TYPO IS NOT A PAUSE, AND IT IS NOT A CRASH EITHER. `off` is not a
# number here — and until now it was not ignored, it was handed to the
# splitter's `int(capstr)`, which raised, so every tick re-spooled the whole
# batch and nothing was ever triaged. The lane must keep running on its default
# and NAME the value it refused: a silent stop and a silent burn are the same
# bug wearing opposite signs.
reset_state
q "$H/state/alert-quarantine.jsonl" 60 project-1 "widget-5" "the widget subsystem is unhappy"
run TRIAGE_MAX_FAMILIES=off
[ "$(ncalls)" = 1 ] \
  && ok || bad "A12 an unparseable cap must not read as OFF — the lane keeps running (got $(ncalls))"
grep -qi 'is not a whole number' "$H/logs/alert-triage.log" \
  && ok || bad "A12b ...and the refused value must be named: $(cat "$H/logs/alert-triage.log")"

# ============================================================================
# B. bin/alerts-medic.sh with MEDIC_MAX_FAMILIES=0
# ============================================================================
echo "--- B. MEDIC_MAX_FAMILIES=0 buys nothing (the same max(1, ...) clamp)"
HM="$T/hm"
mkdir -p "$HM/bin" "$HM/logs" "$HM/state" "$HM/locks" "$HM/env" "$HM/flags" \
         "$HM/catalog" "$T/stubm" "$T/callsm"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$HM/env/global.env"
sed "s|/root/harness|$HM|g" "$DIR/bin/alerts-medic.sh" > "$HM/bin/alerts-medic.sh"
chmod +x "$HM/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$HM/bin/$s"; done
ln -sfn "$DIR/bin/lib" "$HM/bin/lib"
ln -sf "$DIR/bin/alert-line.sh" "$HM/bin/alert-line.sh"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
model_routes_fixture "$HM" || exit 1
printf '#!/bin/sh\nexit 0\n' > "$HM/bin/alerts-groom.sh"; chmod +x "$HM/bin/alerts-groom.sh"
cat > "$HM/catalog/lane-caps.conf" <<'EOF'
lane medic 999 40000
default 999 20000
EOF
cat > "$HM/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "medic done" > "$5"
STUB
chmod +x "$HM/bin/agent-call.sh"
cat > "$T/stubm/curl" <<STUB
#!/bin/sh
echo fetch >> "$T/curl.log"
cat "$T/alerts.json"
STUB
chmod +x "$T/stubm/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/stubm/flock"; chmod +x "$T/stubm/flock"
cat > "$T/stubm/date" <<'STUB'
#!/bin/sh
if [ "$1" = "-u" ] && [ "$2" = "-d" ]; then shift 3; exec /bin/date -u "$@"; fi
exec /bin/date "$@"
STUB
chmod +x "$T/stubm/date"
printf '{"alerts":[{"id":"alert-aa","createdAt":"2026-08-25T00:00:00Z","line":"the widget subsystem is unhappy"}]}\n' \
  > "$T/alerts.json"
# BH-5942: the medic runs per project; a row with no project is the cromford run's.
MS="$HM/state/alerts-medic/cromford"
medic_reset() {
  : > "$HM/logs/medic.log"; : > "$HM/logs/ALERTS.log"; : > "$T/curl.log"
  scratch_rm "$MS"
  : > "$HM/state/medic-seen.txt"
  echo '{}' > "$HM/state/medic-families.json"; echo '{}' > "$HM/state/medic-parked.json"
  rm -f "$HM/flags/"alerted-lane-usd-*
  printf '%s\n' "$HDR" > "$HM/logs/cost.csv"
  rm -rf "${T:?}/callsm"; mkdir -p "$T/callsm"
}
medic_run() {
  ( export CALLDIR="$T/callsm" PATH="$T/stubm:$PATH" LANE_CAPS_CONF="$HM/catalog/lane-caps.conf" \
           MODEL_PRICES="$T/prices.json"
    [ "$#" -gt 0 ] && export "$@"
    bash "$HM/bin/alerts-medic.sh" cromford >/dev/null 2>&1 )
}
mcalls() { ls "$T/callsm"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }

medic_reset
medic_run
[ "$(mcalls)" = 1 ] && ok || bad "B1 the medic must run normally at its default cap (got $(mcalls))"

medic_reset
medic_run MEDIC_MAX_FAMILIES=0
[ "$(mcalls)" = 0 ] && ok || bad "B2 MEDIC_MAX_FAMILIES=0 must buy NO session (got $(mcalls))"
[ ! -s "$HM/state/medic-seen.txt" ] && [ ! -s "$MS/medic-seen.txt" ] \
  && ok || bad "B3 a stopped medic must consume nothing — the console has to re-offer it"
[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HM/state/medic-families.json")" = 0 ] \
  && { [ ! -e "$MS/medic-families.json" ] || [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$MS/medic-families.json")" = 0 ]; } \
  && ok || bad "B4 a stopped medic must stamp no family into its own 6h brake"
grep -qi 'MEDIC_MAX_FAMILIES' "$HM/logs/medic.log" \
  && ok || bad "B5 the stop must name the knob: $(cat "$HM/logs/medic.log")"
[ ! -s "$HM/logs/ALERTS.log" ] \
  && ok || bad "B6 a deliberate pause must not page: $(cat "$HM/logs/ALERTS.log")"
[ ! -s "$T/curl.log" ] \
  && ok || bad "B7 a stopped lane must not even fetch its queue"

medic_reset
medic_run MEDIC_MAX_FAMILIES=-2
[ "$(mcalls)" = 0 ] && ok || bad "B8 a negative medic cap must be OFF too (got $(mcalls))"
medic_reset
medic_run MEDIC_MAX_FAMILIES=off
[ "$(mcalls)" = 1 ] \
  && ok || bad "B9 an unparseable medic cap must not stop the lane (got $(mcalls))"
grep -qi 'is not a whole number' "$HM/logs/medic.log" \
  && ok || bad "B9b ...and must be named: $(cat "$HM/logs/medic.log")"

# ============================================================================
# C. the daily dollar cap is not $200-by-accident
# ============================================================================
echo "--- C. the lane-caps defaults"
# A harness tree with the LIBRARY and NO conf anywhere — the hub's actual state
# on 2026-09-20, and the one where the built-in constants are what bind.
HC="$T/hc"; mkdir -p "$HC/bin/lib" "$HC/logs" "$HC/flags"
cp "$DIR/bin/lib/lane-caps.sh" "$DIR/bin/lib/cost-row.sh" "$HC/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$HC/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
printf '%s\n' "$HDR" > "$HC/logs/cost.csv"
lcbare() { # lcbare <env assignments...> -- <function> <args...>
  local envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  shift
  ( export HARNESS="$HC" COST="$HC/logs/cost.csv" LANE_CAPS_DAY="$DAY" \
           MODEL_PRICES="$T/prices.json" "${envs[@]}"
    . "$HC/bin/lib/cost-row.sh" >/dev/null 2>&1
    . "$HC/bin/lib/lane-caps.sh" || exit 9
    "$@" )
}
V=$(lcbare -- lane_caps_source)
[ "$V" = "built-in defaults" ] \
  && ok || bad "C0 the fixture must reach the BUILT-IN defaults, no conf (got '$V')"
V=$(lcbare -- lane_cap_usd alert-triage)
[ "$V" = 50 ] \
  && ok || bad "C1 a box with no conf must fall back to \$50/day, not \$200 (got '$V')"
V=$(lcbare -- lane_cap_usd some-lane-nobody-listed)
[ "$V" = 50 ] \
  && ok || bad "C1b every unlisted lane takes the same \$50 default (got '$V')"

# The SHIPPED conf, through the real resolution chain (no LANE_CAPS_CONF, no
# $HARNESS conf — so the library's own `../../catalog/lane-caps.conf` answers).
HR="$T/hr"; mkdir -p "$HR/logs" "$HR/flags"
printf '%s\n' "$HDR" > "$HR/logs/cost.csv"
lcrepo() { # lcrepo <env assignments...> -- <function> <args...>
  local envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  shift
  ( export HARNESS="$HR" COST="$HR/logs/cost.csv" LANE_CAPS_DAY="$DAY" \
           MODEL_PRICES="$T/prices.json" "${envs[@]}"
    . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
    . "$DIR/bin/lib/lane-caps.sh" || exit 9
    "$@" )
}
V=$(lcrepo -- lane_cap_usd alert-triage)
[ "$V" = 5 ] \
  && ok || bad "C2 the shipped conf must put alert-triage at \$5/day (got '$V')"
V=$(lcrepo -- lane_cap_usd some-lane-nobody-listed)
[ "$V" = 50 ] \
  && ok || bad "C2b ...and its default row at \$50/day (got '$V')"

# C3. ZERO IS A VALUE, NOT A TYPO. `_lc_num` demanded a POSITIVE number, so
# `LANE_USD_CAP_ALERT_TRIAGE=0` — the most obvious way an operator writes "spend
# nothing on this lane today" — fell straight through to the default and the
# lane kept buying. Zero means OFF, the same reading BH-1132's registry gives
# every other knob (`zero_means: "off"`).
V=$(lcbare LANE_USD_CAP_ALERT_TRIAGE=0 -- lane_cap_usd alert-triage)
[ "$V" = 0 ] \
  && ok || bad "C3 a dollar cap of 0 must bind as 0, never fall back to the default (got '$V')"
lcbare LANE_USD_CAP_ALERT_TRIAGE=0 -- lane_day_cap_tripped alert-triage \
  && ok || bad "C3b a cap of 0 must trip on an EMPTY ledger — zero spend allowed is zero"
grep -q 'DAILY SPEND CAP' "$HC/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "C3c ...and the stop still pages once: $(cat "$HC/logs/ALERTS.log" 2>/dev/null)"
# A conf row may say it too.
cat > "$T/zero.conf" <<'EOF'
lane alert-triage 0 20000
default 50 20000
EOF
V=$(lcbare "LANE_CAPS_CONF=$T/zero.conf" -- lane_cap_usd alert-triage)
[ "$V" = 0 ] && ok || bad "C3d a conf row of 0 must bind as 0 (got '$V')"
# ...and `off` still means UNCAPPED, the opposite of 0. Two values, two meanings,
# neither of them "the default".
V=$(lcbare LANE_USD_CAP_ALERT_TRIAGE=off -- lane_cap_usd alert-triage)
[ "$V" = off ] && ok || bad "C3e 'off' must still mean deliberately uncapped (got '$V')"
lcbare LANE_USD_CAP_ALERT_TRIAGE=off -- lane_day_cap_tripped alert-triage \
  && bad "C3f an uncapped lane must never trip" || ok
# A real cap still fires on real spend, and still does not fire under it.
crow "$HC/logs/cost.csv" alert-triage 60.00
lcbare -- lane_day_cap_tripped alert-triage \
  && ok || bad "C4 \$60 against the \$50 built-in default must trip"
printf '%s\n' "$HDR" > "$HC/logs/cost.csv"
crow "$HC/logs/cost.csv" alert-triage 10.00
rm -f "$HC/flags/"alerted-lane-usd-*
lcbare -- lane_day_cap_tripped alert-triage \
  && bad "C4b \$10 against a \$50 cap must NOT trip" || ok

# ============================================================================
# D. the cap declares itself
# ============================================================================
echo "--- D. nothing about the cap is silent"
# D1. WHAT IS ACTUALLY BINDING, AND FROM WHERE. The $200 default was not wrong
# because 200 is a bad number — it was wrong because no line anywhere said the
# reviewed $120 row was not in force on that box. One line per lane per UTC day,
# in the lane's own log, naming the cap and the file that answered.
rm -f "$HC/flags/"lane-caps-* "$HC/logs/lane-caps.log"
lcbare -- lane_cap_usd alert-triage >/dev/null
grep -q 'built-in defaults' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "D1 a lane running on the built-in fallback must SAY so: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
grep -q '50' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "D1b ...and name the number that is binding: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
lcbare -- lane_cap_usd alert-triage >/dev/null
[ "$(grep -c 'built-in defaults' "$HC/logs/lane-caps.log")" = 1 ] \
  && ok || bad "D1c ...once a day, not once a tick (got $(grep -c 'built-in defaults' "$HC/logs/lane-caps.log"))"
# A lane reading a real conf file is NOT a degrade and must not write that line.
rm -f "$HC/flags/"lane-caps-* "$HC/logs/lane-caps.log"
lcbare "LANE_CAPS_CONF=$T/zero.conf" -- lane_cap_usd alert-triage >/dev/null
! grep -q 'built-in defaults' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "D1d a configured lane must not claim it is on the fallback"

# D2. THE KNOB ROWS. BH-1132 shows an operator every lane's knobs with their
# bounds and what 0 means; a spend cap that is not in that list is a knob only
# the source code knows about. The rows come from the library that owns them, so
# the registry can never carry a second, stale copy of the numbers.
K=$(lcbare -- lane_caps_knobs alert-triage)
printf '%s' "$K" | jq -e 'type == "array" and length >= 2' >/dev/null 2>&1 \
  && ok || bad "D2 lane_caps_knobs must emit a JSON array of knobs (got '$(head -c 200 <<<"$K")')"
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_USD_CAP_ALERT_TRIAGE")] | length == 1' >/dev/null 2>&1 \
  && ok || bad "D2b the lane's dollar cap must be one of them"
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_USD_CAP_ALERT_TRIAGE")][0].zero_means == "off"' >/dev/null 2>&1 \
  && ok || bad "D2c ...and must declare that 0 means off"
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_USD_CAP_ALERT_TRIAGE")][0].default == 50' >/dev/null 2>&1 \
  && ok || bad "D2d ...and carry the default that is actually binding, not a literal"
printf '%s' "$K" | jq -e 'all(.[]; has("env") and has("type") and has("default")
                                  and has("min") and has("max") and has("unit")
                                  and has("zero_means") and has("note"))' >/dev/null 2>&1 \
  && ok || bad "D2e every knob row must carry the registry's full shape"
K=$(lcrepo -- lane_caps_knobs alert-triage)
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_USD_CAP_ALERT_TRIAGE")][0].default == 5' >/dev/null 2>&1 \
  && ok || bad "D2f the default shown must be THIS lane's resolved cap (\$5 from the shipped conf)"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
