#!/bin/bash
# tests/triage-noise-budget.bh-1168-test.sh — a lane whose sessions all find
# NOTHING must stop buying them, whatever they cost (BH-1168, #1164 part 3).
#
# THE GAP THIS IS. A session concluding `handled=0 escalated=0 noise=1` costs
# full price and produces nothing. On 2026-09-20 that was 150 of 192 sessions at
# ~$4 each, and on the 16:10-21:20Z tail it was EVERY ONE of the 11 sessions the
# clamped session cap let through. The dollar cap catches that only after the
# day's money is gone; the $5/day row catches it sooner only by being small
# enough to hurt a legitimate day too. The bound missing is on the thing that is
# actually wrong: the lane is finding nothing.
#
# So: a per-lane, per-UTC-day NOISE BUDGET. It counts sessions that concluded
# `handled=0 escalated=0`, a session that handled or escalated anything RESETS
# the count, and at the budget the lane stops buying sessions until 00:00Z —
# before the call, never after — pages once, and drops nothing.
#
# Section L is the library seam (bin/lib/lane-caps.sh). Section A is the REAL
# bin/alert-triage.sh end to end, the same fixture harness
# tests/triage-session-cap-zero.bh-1164-test.sh uses: only the harness ROOT is
# rewritten, and only what would leave this machine or spend money is stubbed.
# What the agent-call stub is asked to do — or never asked — is the assertion.
#
# Run from anywhere: tests/triage-noise-budget.bh-1168-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 77 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# THE BOX'S OWN KNOBS DO NOT GET A VOTE. Every one of these beats the fixture's
# catalog/lane-caps.conf and the lane's own default, and they are set for real
# in env/global.env on the hub — TRIAGE_MAX_FAMILIES=0 is the operator's pause,
# and it made every section-A case read STOPPED when this suite ran ON a box
# rather than in CI. Each case says what it wants by exporting it in its own
# subshell; nothing inherited from the shell that launched the run may decide.
unset TRIAGE_MAX_FAMILIES LANE_USD_CAP_ALERT_TRIAGE \
      LANE_NOISE_CAP_ALERT_TRIAGE LANE_BYTES_CAP_ALERT_TRIAGE

# ONE clock anchor for the whole suite; every fixture and every day key is
# derived from it and passed in as LANE_CAPS_DAY, so nothing here depends on the
# wall clock crossing midnight mid-run.
NOW=$(date -u +%s)
DAY=$(date -u +%Y-%m-%d)
YDAY=$(date -u -d "@$(( NOW - 86400 ))" +%Y-%m-%d)

HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )

cat > "$T/prices.json" <<'EOF'
{"per_token": {"claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015,
                                    "cache_read": 3e-7, "cache_write": 0.00000375}}}
EOF

# ============================================================================
# L. the library: budget resolution, the durable counter, the trip
# ============================================================================
echo "--- L. bin/lib/lane-caps.sh: the noise budget"
HC="$T/hc"; mkdir -p "$HC/bin/lib" "$HC/logs" "$HC/flags" "$HC/state"
cp "$DIR/bin/lib/lane-caps.sh" "$DIR/bin/lib/cost-row.sh" "$HC/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$HC/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
printf '%s\n' "$HDR" > "$HC/logs/cost.csv"
CFILE="$HC/state/lane-noise-alert-triage.count"

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
# The SHIPPED catalog through the real resolution chain (no LANE_CAPS_CONF and
# no $HARNESS conf, so the library's own ../../catalog/lane-caps.conf answers).
HR="$T/hr"; mkdir -p "$HR/logs" "$HR/flags" "$HR/state"
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
lclean() { scratch_rm "$CFILE"; scratch_rm "$CFILE.lock"; scratch_rm "$CFILE.tmp"; rm -f "$HC/flags/"alerted-lane-noise-* \
                "$HC/flags/"lane-caps-* "$HC/logs/lane-caps.log" "$HC/logs/ALERTS.log"; }

# L1. THE NUMBER LIVES IN THE REVIEWED CATALOG, like the dollar cap's.
lclean
V=$(lcrepo -- lane_noise_cap alert-triage)
[ "$V" = 10 ] \
  && ok || bad "L1 the shipped catalog must put alert-triage's noise budget at 10/day (got '$V')"

# L2. a `noise default` row answers for a lane with no row of its own.
cat > "$T/def.conf" <<'EOF'
lane alert-triage 5 20000
noise default 7
default 50 20000
EOF
V=$(lcbare "LANE_CAPS_CONF=$T/def.conf" -- lane_noise_cap alert-triage)
[ "$V" = 7 ] && ok || bad "L2 a 'noise default' row must answer for an unlisted lane (got '$V')"

# L3. NO CONF ANYWHERE — the box whose fleet-sync has not landed the catalog,
# which is the 2026-09-20 hub itself. The built-in binds AND says so.
lclean
V=$(lcbare -- lane_noise_cap alert-triage)
[ "$V" = 10 ] \
  && ok || bad "L3 a box with no conf must fall back to the built-in 10/day (got '$V')"
grep -q 'built-in default' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "L3b a lane running on the built-in noise budget must SAY so: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
grep -q '10' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "L3c ...and name the number that is binding: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
lcbare -- lane_noise_cap alert-triage >/dev/null
[ "$(grep -c 'built-in default' "$HC/logs/lane-caps.log")" = 1 ] \
  && ok || bad "L3d ...once a day, not once a tick (got $(grep -c 'built-in default' "$HC/logs/lane-caps.log"))"

# L4. the env override beats the conf row, for one run.
cat > "$T/ten.conf" <<'EOF'
lane alert-triage 5 20000
noise alert-triage 10
default 50 20000
EOF
V=$(lcbare "LANE_CAPS_CONF=$T/ten.conf" LANE_NOISE_CAP_ALERT_TRIAGE=3 -- lane_noise_cap alert-triage)
[ "$V" = 3 ] && ok || bad "L4 the env override must beat the conf row (got '$V')"

# L5. ZERO IS A VALUE. `=0` is "buy nothing on this lane today" and must trip on
# an EMPTY counter, the same reading the dollar cap gives it.
lclean
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=0 -- lane_noise_cap_tripped alert-triage \
  && ok || bad "L5 a noise budget of 0 must trip on an empty counter — zero noise allowed is zero"

# L6. `off` is its OPPOSITE, and a typo is neither.
lclean
printf '%s\t%s\n' "$DAY" 50 > "$CFILE"
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=off -- lane_noise_cap_tripped alert-triage \
  && bad "L6 'off' must never trip, even at 50 noise sessions" || ok
V=$(lcbare "LANE_CAPS_CONF=$T/ten.conf" LANE_NOISE_CAP_ALERT_TRIAGE=1.5 -- lane_noise_cap alert-triage)
[ "$V" = 10 ] \
  && ok || bad "L6b a non-integer override must be IGNORED, not obeyed and not read as 0 (got '$V')"
grep -q 'LANE_NOISE_CAP_ALERT_TRIAGE=1.5' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "L6c ...and the refused value must be NAMED: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
V=$(lcbare "LANE_CAPS_CONF=$T/ten.conf" LANE_NOISE_CAP_ALERT_TRIAGE=abc -- lane_noise_cap alert-triage)
[ "$V" = 10 ] && ok || bad "L6d a garbage override must leave the configured row standing (got '$V')"
cat > "$T/banana.conf" <<'EOF'
lane alert-triage 5 20000
noise alert-triage banana
default 50 20000
EOF
V=$(lcbare "LANE_CAPS_CONF=$T/banana.conf" -- lane_caps_legacy_rows)
case "$V" in *noise:alert-triage*) ok ;;
  *) bad "L6e a refused noise row must be NAMED by lane_caps_legacy_rows (got '$V')" ;; esac

# L7. THE DURABLE COUNTER. Three noise-only verdicts, three bumps, one file.
lclean
lcbare -- lane_noise_record alert-triage 0 0
lcbare -- lane_noise_record alert-triage 0 0
lcbare -- lane_noise_record alert-triage 0 0
V=$(lcbare -- lane_noise_count alert-triage)
[ "$V" = 3 ] && ok || bad "L7 three noise-only sessions must read 3 (got '$V')"
[ "$(cat "$CFILE")" = "$(printf '%s\t3' "$DAY")" ] \
  && ok || bad "L7b the counter file must be '<day><TAB><n>' (got '$(cat "$CFILE")')"

# L8. A USEFUL SESSION RESETS IT. A lane that starts finding real problems again
# must not still be stopped on this morning's noise.
lcbare -- lane_noise_record alert-triage 2 0
V=$(lcbare -- lane_noise_count alert-triage)
[ "$V" = 0 ] && ok || bad "L8 handled>0 must reset the count to 0 (got '$V')"
lcbare -- lane_noise_record alert-triage 0 0
lcbare -- lane_noise_record alert-triage 0 0
lcbare -- lane_noise_record alert-triage 0 1
V=$(lcbare -- lane_noise_count alert-triage)
[ "$V" = 0 ] && ok || bad "L8b escalated>0 must reset it too (got '$V')"

# L9. YESTERDAY IS NOT TODAY. A counter stamped with another day reads 0 and is
# overwritten by the next write — one file per lane, nothing to prune.
lclean
printf '%s\t%s\n' "$YDAY" 40 > "$CFILE"
V=$(lcbare -- lane_noise_count alert-triage)
[ "$V" = 0 ] && ok || bad "L9 a counter from another UTC day must read 0 (got '$V')"
lcbare -- lane_noise_record alert-triage 0 0
[ "$(cat "$CFILE")" = "$(printf '%s\t1' "$DAY")" ] \
  && ok || bad "L9b ...and the next bump must start today at 1 (got '$(cat "$CFILE")')"

# L10. THE TRIP PAGES ONCE PER LANE PER UTC DAY, like DAILY SPEND CAP: the lane
# is about to stop on every tick until midnight and 144 identical pages is how a
# real one gets missed.
lclean
printf '%s\t%s\n' "$DAY" 3 > "$CFILE"
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=3 -- lane_noise_cap_tripped alert-triage \
  && ok || bad "L10 count 3 against a budget of 3 must trip"
[ "$(grep -c 'NOISE BUDGET' "$HC/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L10b ...and page exactly once: $(cat "$HC/logs/ALERTS.log" 2>/dev/null)"
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=3 -- lane_noise_cap_tripped alert-triage \
  && ok || bad "L10c a second check must still trip"
[ "$(grep -c 'NOISE BUDGET' "$HC/logs/ALERTS.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L10d ...and must NOT page again (got $(grep -c 'NOISE BUDGET' "$HC/logs/ALERTS.log"))"
ls "$HC/flags/"alerted-lane-noise-alert-triage-* >/dev/null 2>&1 \
  && ok || bad "L10e the page must leave its once-a-day flag"

# L11. ...and it does not trip UNDER the budget.
lclean
printf '%s\t%s\n' "$DAY" 2 > "$CFILE"
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=3 -- lane_noise_cap_tripped alert-triage \
  && bad "L11 count 2 against a budget of 3 must NOT trip" || ok
[ ! -s "$HC/logs/ALERTS.log" ] \
  && ok || bad "L11b ...and must not page: $(cat "$HC/logs/ALERTS.log" 2>/dev/null)"

# L12. FAIL OPEN, AND SAY SO. A bound that turns the de-noising layer off
# because it could not read a file would look identical to one that correctly
# stopped it — and it would fire in exactly the situation the layer is needed.
lclean
mkdir -p "$CFILE"
lcbare -- lane_noise_count alert-triage >/dev/null 2>&1
[ "$?" = 2 ] && ok || bad "L12 an unreadable counter must answer rc 2, never a number"
lcbare LANE_NOISE_CAP_ALERT_TRIAGE=1 -- lane_noise_cap_tripped alert-triage \
  && bad "L12b an unreadable counter must FAIL OPEN — the lane runs" || ok
grep -q 'fails OPEN' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "L12c ...and the degrade must be declared: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
lcbare -- lane_noise_record alert-triage 0 0
[ "$?" = 0 ] && ok || bad "L12d a bump against an unwritable counter must not crash the caller"
grep -q 'could not write the noise counter' "$HC/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "L12e ...and the failed write must be declared: $(cat "$HC/logs/lane-caps.log" 2>/dev/null)"
scratch_rm "$CFILE"

# L13. THE KNOB ROW. A bound that is not in the lanes registry is a knob only
# the source code knows about, and the row comes from the library that owns the
# number so a settings page can never show a second, stale copy of it.
K=$(lcrepo -- lane_caps_knobs alert-triage)
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_NOISE_CAP_ALERT_TRIAGE")] | length == 1' >/dev/null 2>&1 \
  && ok || bad "L13 the noise budget must be exactly one knob row (got '$(head -c 200 <<<"$K")')"
printf '%s' "$K" | jq -e '[.[] | select(.env == "LANE_NOISE_CAP_ALERT_TRIAGE")][0]
                          | .zero_means == "off" and .type == "int" and .default == 10' >/dev/null 2>&1 \
  && ok || bad "L13b ...declaring int, zero_means off, and the budget actually binding (10)"
printf '%s' "$K" | jq -e 'all(.[]; has("env") and has("type") and has("default")
                                  and has("min") and has("max") and has("unit")
                                  and has("zero_means") and has("note"))' >/dev/null 2>&1 \
  && ok || bad "L13c every knob row must still carry the registry's full shape"

# ============================================================================
# A. the REAL bin/alert-triage.sh
# ============================================================================
echo "--- A. bin/alert-triage.sh under a noise budget"
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
# BH-5942: project-1 is not a fleet.conf project, so every line here belongs to
# the home project's run; its spool and brake files live under HP.
HP="$H/state/alert-triage/cromford"

# A generous, explicitly-configured DOLLAR cap, so nothing in section A can be
# explained by the spend cap: the only bound under test is the noise budget.
cat > "$H/catalog/lane-caps.conf" <<'EOF'
lane alert-triage 999 20000
default 999 20000
EOF

# The stub records every call and answers with whatever verdict this tick asked
# for — the session's last line is what the lane reads.
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
cat "$VERDICT" > "$5"
exit 0
STUB
chmod +x "$H/bin/agent-call.sh"
cat > "$T/stub/ssh" <<STUB
#!/bin/sh
echo ssh >> "$T/ssh.log"
exit 0
STUB
chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

NCFILE="$H/state/lane-noise-alert-triage.count"
verdict() { printf '%s\n' "$1" > "$T/verdict.txt"; }
q() { # q <akey> <line>
  printf '%s\t{"kind":"fleet_alert","project":"project-1","akey":"%s","line":"%s"}\n' \
    "$(( NOW - 60 ))" "$1" "$2" >> "$H/state/alert-quarantine.jsonl"
}
run() { # run [env assignments...]
  rm -rf "${T:?}/calls"; mkdir -p "$T/calls"
  : > "$T/ssh.log"
  ( export CALLDIR="$T/calls" PATH="$T/stub:$PATH" MODEL_PRICES="$T/prices.json" \
           LANE_CAPS_CONF="$H/catalog/lane-caps.conf" LANE_CAPS_DAY="$DAY" \
           VERDICT="$T/verdict.txt"
    [ "$#" -gt 0 ] && export "$@"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
}
ncalls()   { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
famcount() { [ -e "$HP/alert-families.json" ] || { echo 0; return; }; python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HP/alert-families.json"; }
ncount()   { if [ -f "$NCFILE" ]; then cut -f2 "$NCFILE" | tr -d '[:space:]'; else printf none; fi; }
reset_state() {
  triage_tick_reset "$H"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"; : > "$H/logs/lane-caps.log"
  : > "$T/ssh.log"
  echo '{}' > "$H/state/alert-families.json"
  : > "$H/state/alert-triage-deferred.tsv"
  : > "$H/state/alert-quarantine.jsonl"
  scratch_rm "$NCFILE"; scratch_rm "$NCFILE.lock"; scratch_rm "$NCFILE.tmp"
  rm -f "$H/flags/"alerted-lane-usd-* "$H/flags/"alerted-triage-* \
        "$H/flags/"alerted-lane-noise-* "$H/flags/"lane-caps-*
  printf '%s\n' "$HDR" > "$H/logs/cost.csv"
}
BUDGET3=LANE_NOISE_CAP_ALERT_TRIAGE=3

# A1. UNDER THE BUDGET THE LANE RUNS. Two noise-only sessions against a budget
# of 3 change nothing about the next tick.
reset_state
verdict "handled=0 escalated=0 noise=1"
q noise-1 "the widget subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 1 ] && ok || bad "A1 tick 1 must buy its session (got $(ncalls))"
[ "$(ncount)" = 1 ] && ok || bad "A1b ...and record one noise-only session (got $(ncount))"
q noise-2 "the gasket subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 1 ] && ok || bad "A1c a lane under its budget must keep buying (got $(ncalls))"
[ "$(ncount)" = 2 ] && ok || bad "A1d ...and the count must move with it (got $(ncount))"
[ ! -s "$H/logs/ALERTS.log" ] \
  && ok || bad "A1e nothing under the budget may page: $(cat "$H/logs/ALERTS.log")"

# A2. THE BUDGET'TH SESSION STOPS THE NEXT TICK — before the call, and before
# any collection: nothing bought, no box reached, no family stamped, the alert
# still exactly where it was, and ONE page.
q noise-3 "the flange subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 1 ] && ok || bad "A2 the budget'th session is still bought (got $(ncalls))"
[ "$(ncount)" = 3 ] && ok || bad "A2b ...and reaches the budget (got $(ncount))"
FAMS=$(famcount)
q noise-4 "the sprocket subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 0 ] \
  && ok || bad "A2c the tick after the budget must buy NOTHING (got $(ncalls))"
[ ! -s "$T/ssh.log" ] \
  && ok || bad "A2d ...and must reach no box: $(wc -l < "$T/ssh.log") fetch(es)"
[ "$(famcount)" = "$FAMS" ] \
  && ok || bad "A2e ...and stamp no family into the 6h brake ($FAMS -> $(famcount))"
grep -q 'the sprocket subsystem is unhappy' "$H/state/alert-quarantine.jsonl" \
  && ok || bad "A2f ...and consume nothing: the alert must still be quarantined"
[ "$(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A2g the stop must page exactly once: $(cat "$H/logs/ALERTS.log")"
[ "$(grep -c . "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A2h ...and page nothing else: $(cat "$H/logs/ALERTS.log")"
grep -q 'LANE_NOISE_CAP_ALERT_TRIAGE' "$H/logs/alert-triage.log" \
  && ok || bad "A2i the lane log must name the knob that stopped it: $(tail -2 "$H/logs/alert-triage.log")"

# A3. A SECOND STOPPED TICK DOES NOT PAGE AGAIN.
run "$BUDGET3"
[ "$(ncalls)" = 0 ] && ok || bad "A3 a second stopped tick must still buy nothing (got $(ncalls))"
[ "$(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A3b ...and must not page again (got $(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log"))"

# A4. A USEFUL SESSION RE-ARMS THE LANE. Not just "the counter reads 0" — the
# lane must go on to buy a full budget's worth of sessions afterwards, which is
# the only thing that proves the reset is real.
reset_state
verdict "handled=0 escalated=0 noise=1"
q reset-1 "the widget subsystem is unhappy"; run "$BUDGET3"
q reset-2 "the gasket subsystem is unhappy"; run "$BUDGET3"
[ "$(ncount)" = 2 ] && ok || bad "A4 two noise ticks must leave the count at 2 (got $(ncount))"
verdict "handled=1 escalated=0 noise=0"
q reset-3 "the flange subsystem is unhappy"; run "$BUDGET3"
[ "$(ncalls)" = 1 ] && ok || bad "A4b a session that handles something is still bought (got $(ncalls))"
[ "$(ncount)" = 0 ] && ok || bad "A4c ...and resets the count (got $(ncount))"
verdict "handled=0 escalated=0 noise=1"
q reset-4 "the sprocket subsystem is unhappy"; run "$BUDGET3"
q reset-5 "the bezel subsystem is unhappy";    run "$BUDGET3"
q reset-6 "the grommet subsystem is unhappy";  run "$BUDGET3"
[ "$(ncount)" = 3 ] \
  && ok || bad "A4d the re-armed lane must buy a full budget again (count $(ncount))"
q reset-7 "the trunnion subsystem is unhappy"; run "$BUDGET3"
[ "$(ncalls)" = 0 ] \
  && ok || bad "A4e ...and stop at the budget it re-armed to (got $(ncalls))"

# A5. `=0` IS OFF, `off` IS UNBOUNDED, through the real lane.
reset_state
q zero-1 "the widget subsystem is unhappy"
run LANE_NOISE_CAP_ALERT_TRIAGE=0
[ "$(ncalls)" = 0 ] \
  && ok || bad "A5 a noise budget of 0 must buy nothing on a fresh counter (got $(ncalls))"
[ "$(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A5b ...and page once: $(cat "$H/logs/ALERTS.log")"
reset_state
printf '%s\t%s\n' "$DAY" 50 > "$NCFILE"
q off-1 "the widget subsystem is unhappy"
run LANE_NOISE_CAP_ALERT_TRIAGE=off
[ "$(ncalls)" = 1 ] \
  && ok || bad "A5c 'off' must run the lane at 50 noise sessions (got $(ncalls))"
[ ! -s "$H/logs/ALERTS.log" ] \
  && ok || bad "A5d ...and an uncapped lane must never page: $(cat "$H/logs/ALERTS.log")"

# A6. THE TICK THAT CROSSES THE BUDGET STOPS INSIDE ITSELF. Four families under
# a session cap of 4 and a budget of 2: the budget is checked BEFORE each call,
# so exactly two sessions are bought and the other two families are re-spooled
# at their pre-tick stamp — deferred, never dropped.
reset_state
verdict "handled=0 escalated=0 noise=1"
q mid-1 "the widget subsystem is unhappy"
q mid-2 "the gasket subsystem is unhappy"
q mid-3 "the flange subsystem is unhappy"
q mid-4 "the sprocket subsystem is unhappy"
run LANE_NOISE_CAP_ALERT_TRIAGE=2 TRIAGE_MAX_FAMILIES=4
[ "$(ncalls)" = 2 ] \
  && ok || bad "A6 the crossing tick must buy exactly the budget (got $(ncalls))"
[ "$(grep -c . "$HP/deferred.tsv")" = 2 ] \
  && ok || bad "A6b ...and re-spool the rest (got $(grep -c . "$HP/deferred.tsv") line(s))"
[ "$(famcount)" = 2 ] \
  && ok || bad "A6c ...stamping only the families it actually looked at (got $(famcount))"
[ "$(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A6d ...and paging once: $(cat "$H/logs/ALERTS.log")"
run LANE_NOISE_CAP_ALERT_TRIAGE=2 TRIAGE_MAX_FAMILIES=4
[ "$(ncalls)" = 0 ] && ok || bad "A6e the next tick must buy nothing (got $(ncalls))"
[ "$(grep -c . "$HP/deferred.tsv")" = 2 ] \
  && ok || bad "A6f ...and the spooled work must still be spooled, exactly once"
[ "$(grep -c 'NOISE BUDGET' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A6g ...and add no second page"

# A7. A SESSION WITH NO VERDICT IS NOT A VERDICT. A failed or truncated session
# neither bumps nor resets: a broken runner must not stop the lane, and it must
# not clear a real count either.
reset_state
verdict "triage done"
q noverdict-1 "the widget subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 1 ] && ok || bad "A7 a session with no summary line is still bought (got $(ncalls))"
case "$(ncount)" in none|0) ok ;; *) bad "A7b ...and must not be counted as noise (got $(ncount))" ;; esac
verdict "handled=0 escalated=0 noise=1"
q noverdict-2 "the gasket subsystem is unhappy"; run "$BUDGET3"
q noverdict-3 "the flange subsystem is unhappy"; run "$BUDGET3"
[ "$(ncount)" = 2 ] && ok || bad "A7c two real noise verdicts must read 2 (got $(ncount))"
verdict "triage done"
q noverdict-4 "the sprocket subsystem is unhappy"; run "$BUDGET3"
[ "$(ncount)" = 2 ] \
  && ok || bad "A7d ...and a verdictless session must not clear them (got $(ncount))"
verdict "handled=0 escalated=2 noise=0"
q noverdict-5 "the bezel subsystem is unhappy"; run "$BUDGET3"
[ "$(ncount)" = 0 ] \
  && ok || bad "A7e an escalating session resets, through the real lane (got $(ncount))"

# A8. AN UNREADABLE COUNTER FAILS OPEN, LOUDLY. The lane runs, and the degrade
# is declared where the caps library declares every other one.
reset_state
mkdir -p "$NCFILE"
verdict "handled=0 escalated=0 noise=1"
q failopen-1 "the widget subsystem is unhappy"
run "$BUDGET3"
[ "$(ncalls)" = 1 ] \
  && ok || bad "A8 an unreadable counter must never stop the lane (got $(ncalls))"
grep -q 'fails OPEN' "$H/logs/lane-caps.log" 2>/dev/null \
  && ok || bad "A8b ...and must say so in logs/lane-caps.log: $(cat "$H/logs/lane-caps.log" 2>/dev/null)"
[ ! -s "$H/logs/ALERTS.log" ] \
  && ok || bad "A8c ...and a fail-open is not a stop, so it does not page: $(cat "$H/logs/ALERTS.log")"
scratch_rm "$NCFILE"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
