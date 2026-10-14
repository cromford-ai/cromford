#!/bin/bash
# tests/lane-day-cap.bh-1039-test.sh — the other two unpriced hub lanes stop on
# their daily dollar cap, the medic's evidence is capped with a marker, and
# agent-call REFUSES on a cliff instead of descending to a rung that costs 100x
# (BH-1039).
#
# WHY THE REFUSAL IS THE LOAD-BEARING ONE. On 2026-09-20 the alert-triage lane
# ran on `grok/grok-4.6` at $0.20 a session. Its projected context crossed the
# xAI cliff, so BH-656's routing skipped grok — and the ladder below it went on
# to `codex/gpt-6-astra` (81 rows, $392) and then
# `openrouter/anthropic/claude-fable-5.1` (97 rows, $396). Every one of those
# descents is a correct failover by the rules as written: no vendor failed. The
# rule that was missing is that a lane which routed AWAY from its runner on
# PRICE must not then buy the same work at a hundred times the price. It
# refuses, the caller defers, and the work comes back when the lane can afford
# it.
#
# Everything here is DRIVEN: the real bin/alerts-medic.sh, the real
# bin/watchdog-responder.sh and the real bin/agent-call.sh, each with only its
# harness ROOT rewritten and with the things that leave the machine stubbed.
#
# Run from anywhere: tests/lane-day-cap.bh-1039-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 63 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock anchor for the suite; every fixture is derived from it.
NOW=$(date -u +%s)
DAY=$(date -u +%Y-%m-%d)

HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
# Lane name in the PROJECT column, `triage` in the stage column — the shape
# `agent-call.sh triage <lane>` actually writes, and the one that catches a
# reader keyed on the wrong column.
crow() { # crow <ledger> <lane> <cost_usd>
  local r n
  r="${DAY}T04:00:00Z,box,$2,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0,$3,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$1"
}

CAPCONF="$T/lane-caps.conf"
cat > "$CAPCONF" <<'EOF'
lane medic 90 40000
lane responder 150 60000
default 200 20000
EOF

# ============================================================================
# A. alerts-medic
# ============================================================================
echo "--- A. alerts-medic"
HM="$T/hm"
mkdir -p "$HM/bin" "$HM/logs" "$HM/state" "$HM/locks" "$HM/env" "$HM/flags" "$T/stubm" "$T/callsm"
printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$HM/env/global.env"
sed "s|/root/harness|$HM|g" "$DIR/bin/alerts-medic.sh" > "$HM/bin/alerts-medic.sh"
chmod +x "$HM/bin/alerts-medic.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py; do ln -sf "$DIR/bin/$s" "$HM/bin/$s"; done
ln -sfn "$DIR/bin/lib" "$HM/bin/lib"
ln -sf "$DIR/bin/alert-line.sh" "$HM/bin/alert-line.sh"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$HM" || exit 1  # BH-1510.2: lanes read models from model_routes
export FLEET_CONF="$DIR/fleet.conf"
printf '#!/bin/sh\nexit 0\n' > "$HM/bin/alerts-groom.sh"; chmod +x "$HM/bin/alerts-groom.sh"

cat > "$HM/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "medic done" > "$5"
STUB
chmod +x "$HM/bin/agent-call.sh"
# The console API is this lane's queue. Every fetch is counted, because "the
# lane stopped before it spent anything" includes not fetching.
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

medic_seed3() { # medic_seed3 <line-text> — three alerts, ONE family
  printf '{"alerts":[{"id":"alert-OLD1","createdAt":"2026-08-25T00:00:00Z","line":"%s"},{"id":"alert-OLD2","createdAt":"2026-08-25T00:00:01Z","line":"%s"},{"id":"alert-NEW3","createdAt":"2026-08-25T00:00:02Z","line":"%s"}]}\n' \
    "$1" "$1" "$1" > "$T/alerts.json"
}
medic_seed() { # medic_seed <line-text>
  printf '{"alerts":[{"id":"alert-aa","createdAt":"2026-08-25T00:00:00Z","line":"%s"}]}\n' "$1" > "$T/alerts.json"
}
# BH-5942: the medic runs per project; these rows carry no project, so they are
# the cromford run's, with its state in state/alerts-medic/cromford/.
MS="$HM/state/alerts-medic/cromford"
medic_reset() {
  : > "$HM/logs/medic.log"; : > "$HM/logs/ALERTS.log"; : > "$T/curl.log"
  scratch_rm "$MS"; mkdir -p "$MS"
  : > "$MS/medic-seen.txt"
  echo '{}' > "$MS/medic-families.json"; echo '{}' > "$MS/medic-parked.json"
  rm -f "$HM/flags/"alerted-lane-usd-*
  printf '%s\n' "$HDR" > "$HM/logs/cost.csv"
  rm -rf "${T:?}/callsm"; mkdir -p "$T/callsm"
}
medic_run() {
  ( export CALLDIR="$T/callsm" PATH="$T/stubm:$PATH" LANE_CAPS_CONF="$CAPCONF"
    [ "$#" -gt 0 ] && export "$@"
    bash "$HM/bin/alerts-medic.sh" cromford >/dev/null 2>&1 )
}
mcalls() { ls "$T/callsm"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }

medic_reset; medic_seed "the widget subsystem is unhappy"
medic_run
[ "$(mcalls)" = 1 ] && ok || bad "A1 under the cap the medic must run normally (got $(mcalls))"

medic_reset; medic_seed "the widget subsystem is unhappy"; crow "$HM/logs/cost.csv" medic 100.00
medic_run
[ "$(mcalls)" = 0 ] && ok || bad "A2 the medic over its day cap must buy no session (got $(mcalls))"
[ ! -s "$T/curl.log" ] && ok || bad "A3 a stopped lane must not even fetch its queue"
[ ! -s "$MS/medic-seen.txt" ] \
  && ok || bad "A4 a stopped medic must consume nothing — the console has to re-offer"
grep -q 'DAILY SPEND CAP' "$HM/logs/ALERTS.log" \
  && ok || bad "A5 the stop must page once: $(cat "$HM/logs/ALERTS.log")"
grep -q 'daily spend cap' "$HM/logs/medic.log" \
  && ok || bad "A6 the lane log must say why this pass did nothing: $(cat "$HM/logs/medic.log")"

# The medic's evidence has never had a cap at all: it hands the whole family's
# alert text to the model. One 1.1M-input-token session is what that buys.
medic_reset
PAD=$(awk 'BEGIN{for(i=1;i<=400;i++) printf "xpad%04d", i}')
medic_seed3 "the widget subsystem is unhappy $PAD"
medic_run LANE_BYTES_CAP_MEDIC=4000
[ "$(mcalls)" = 1 ] && ok || bad "A7 the oversized family must still be investigated (got $(mcalls))"
grep -q '\[capped:' "$T/callsm/prompt-0.txt" 2>/dev/null \
  && ok || bad "A8 over-cap medic evidence must carry the truncation MARKER"
[ "$(grep -c 'the widget subsystem is unhappy' "$T/callsm/prompt-0.txt")" -lt 3 ] \
  && ok || bad "A8b the cap must actually drop evidence, or the marker means nothing"
medic_reset; medic_seed "the widget subsystem is unhappy"
medic_run LANE_BYTES_CAP_MEDIC=40000
! grep -q '\[capped:' "$T/callsm/prompt-0.txt" 2>/dev/null \
  && ok || bad "A9 medic evidence under the cap must not claim it was capped"

# A10-A13. WHAT THE CAP DROPS MUST NOT BE MARKED SEEN (round 1, I2). The medic's
# SEEN list is a one-way door: an id in it is filtered out of every later pass
# for as long as it sits in the 500-line window (bin/alerts-medic.sh:78/81). The
# first draft derived that list from the RAW rows, so ids the cap had dropped —
# which the model never read — were retired without anyone looking at them. The
# file's own doctrine three lines above the loop says the opposite: "not
# consuming an alert is how it comes back".
medic_reset
PAD3=$(awk 'BEGIN{for(i=1;i<=300;i++) printf "xpad%04d", i}')
medic_seed3 "the widget subsystem is unhappy $PAD3"
medic_run LANE_BYTES_CAP_MEDIC=3000
[ "$(mcalls)" = 1 ] && ok || bad "A10 the capped family must still be investigated (got $(mcalls))"
grep -q 'alert-NEW3' "$T/callsm/prompt-0.txt" 2>/dev/null \
  && ok || bad "A10b the newest alert must survive the cut"
SEENIDS=$(sort "$MS/medic-seen.txt" | tr '\n' ',')
[ "$SEENIDS" = "alert-NEW3," ] \
  && ok || bad "A11 only ids the model actually READ may be marked seen (got '$SEENIDS')"
# ...and the id the model read must be a WHOLE record, not a headless fragment:
# the medic's rows are id<TAB>line, and a cut through one hands the model a body
# with no id on it.
grep -q '^alert-NEW3	' "$T/callsm/prompt-0.txt" \
  && ok || bad "A12 the surviving row must still carry its id and tab"
! grep -qE '^(xpad|[0-9]{4}xpad)' "$T/callsm/prompt-0.txt" \
  && ok || bad "A12b no headless fragment may reach the prompt"
# The dropped ones come back on the next pass, as a smaller family. (The
# family brake is cleared the way a later tick would clear it — what is under
# test here is the SEEN filter, not the 6h TTL.)
echo '{}' > "$MS/medic-families.json"
medic_run LANE_BYTES_CAP_MEDIC=3000
grep -q 'alert-OLD2' "$T/callsm/prompt-1.txt" 2>/dev/null \
  && ok || bad "A13 a dropped alert must be re-offered on the next pass"

# A14. MARKER-ONLY EVIDENCE BUYS NOTHING (round 2, I4). A cap under ONE whole
# `id<TAB>line` record keeps no record at all, so the prompt would be the
# truncation marker and nothing else. In this lane that is worse than a wasted
# session: nothing would be marked SEEN either, so the same family is re-offered
# by the console and re-paid for on every pass, forever.
medic_reset
medic_seed3 "the widget subsystem is unhappy $PAD3"
medic_run LANE_BYTES_CAP_MEDIC=200
[ "$(mcalls)" = 0 ] \
  && ok || bad "A14 a family whose evidence does not fit at all must buy NO session (got $(mcalls))"
[ ! -s "$MS/medic-seen.txt" ] \
  && ok || bad "A14b ...and nothing may be marked seen: $(cat "$MS/medic-seen.txt")"
grep -q 'NO SESSION' "$HM/logs/medic.log" \
  && ok || bad "A14c the skip must be declared with the cap that caused it: $(cat "$HM/logs/medic.log")"
# ...and because the console re-offers it forever, the stop is a PAGE, once a
# day. A skip that repeats until a human raises the cap and says nothing is the
# same dead-feed shape as a session that reads nothing.
grep -q 'EVIDENCE CAP TOO SMALL' "$HM/logs/ALERTS.log" \
  && ok || bad "A14d a permanent skip must page once a day: $(cat "$HM/logs/ALERTS.log")"
medic_run LANE_BYTES_CAP_MEDIC=200
[ "$(grep -c 'EVIDENCE CAP TOO SMALL' "$HM/logs/ALERTS.log")" = 1 ] \
  && ok || bad "A14e ...once, not once per pass: $(grep -c 'EVIDENCE CAP TOO SMALL' "$HM/logs/ALERTS.log")"

# ============================================================================
# B. watchdog-responder
# ============================================================================
echo "--- B. watchdog-responder"
HR="$T/hr"
mkdir -p "$HR/bin/lib" "$HR/logs" "$HR/locks" "$HR/env" "$HR/flags" "$HR/state/responder" "$T/callsr"
model_routes_fixture "$HR" || exit 1
: > "$HR/env/global.env"
sed "s|/root/harness|$HR|g" "$DIR/bin/watchdog-responder.sh" > "$HR/bin/watchdog-responder.sh"
chmod +x "$HR/bin/watchdog-responder.sh"
for s in fleet-conf.sh internal-token-for.sh board-fetch.sh box-for.sh; do
  [ -e "$DIR/bin/$s" ] && ln -sf "$DIR/bin/$s" "$HR/bin/$s"
done
# The FIRST thing the responder does after its knobs is read the stale-owed
# snapshot into its project's state dir. That is the probe the cap has to beat:
# a lane that reads, then decides it is out of money, has already done the work
# that leads to a session. BH-5942: a project run (`watchdog-responder.sh p`)
# no longer refreshes the fleet-wide snapshot, so the probe is the copy it
# writes, state/watchdog-responder/p/stale-owed.json.
( cd "$DIR" && scratch_install_closure bin/lib/llm-lane-project.sh "$HR" ) >/dev/null || exit 1
mkdir -p "$HR/state"; echo '{"p":{"tickets":[]}}' > "$HR/state/stale-owed.json"
RPROBE="$HR/state/watchdog-responder/p/stale-owed.json"
for l in gh-budget.sh gh-app-auth.sh lane-caps.sh cost-row.sh env-path.sh lane-switch.sh lane-gate.sh; do
  [ -e "$DIR/bin/lib/$l" ] && ln -sf "$DIR/bin/lib/$l" "$HR/bin/lib/$l"
done
ln -sf "$DIR/bin/alert-line.sh" "$HR/bin/alert-line.sh"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
cat > "$HR/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "responder done" > "$5"
STUB
chmod +x "$HR/bin/agent-call.sh"
printf '%s\n' "$HDR" > "$HR/logs/cost.csv"
crow "$HR/logs/cost.csv" responder 200.00
rm -rf "${T:?}/callsr"; mkdir -p "$T/callsr"; rm -f "$RPROBE"
( export CALLDIR="$T/callsr" LANE_CAPS_CONF="$CAPCONF" HARNESS="$HR"
  bash "$HR/bin/watchdog-responder.sh" p >/dev/null 2>&1 )
[ "$(ls "$T/callsr"/prompt-* 2>/dev/null | wc -l | tr -d ' ')" = 0 ] \
  && ok || bad "B1 the responder over its day cap must buy no session"
[ ! -e "$RPROBE" ] \
  && ok || bad "B1b a stopped responder must stop BEFORE its stale-owed probe, not after"
grep -q 'DAILY SPEND CAP' "$HR/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "B2 the responder stop must page once: $(cat "$HR/logs/ALERTS.log" 2>/dev/null)"
grep -q 'daily spend cap' "$HR/logs/responder.log" 2>/dev/null \
  && ok || bad "B3 the responder log must say why this tick did nothing: $(cat "$HR/logs/responder.log" 2>/dev/null)"
# Under the cap the gate says nothing at all — an unconditional stop line would
# be the same lane stopped with the reason wrong.
printf '%s\n' "$HDR" > "$HR/logs/cost.csv"
: > "$HR/logs/responder.log"; : > "$HR/logs/ALERTS.log"; rm -f "$RPROBE"
rm -f "$HR/flags/"alerted-lane-usd-*
( export CALLDIR="$T/callsr" LANE_CAPS_CONF="$CAPCONF" HARNESS="$HR"
  bash "$HR/bin/watchdog-responder.sh" p >/dev/null 2>&1 )
! grep -q 'daily spend cap' "$HR/logs/responder.log" 2>/dev/null \
  && ok || bad "B4 under the cap the responder must not claim it was stopped"
[ -s "$RPROBE" ] \
  && ok || bad "B4b under the cap the responder must get past the gate and probe"
# The responder's existing byte cap keeps working, and its default now comes
# from the same conf the other two lanes read.
grep -q 'lane_cap_bytes' "$DIR/bin/watchdog-responder.sh" \
  && ok || bad "B5 RESPONDER_EVIDENCE_CAP_BYTES must default through lane_cap_bytes"

# ============================================================================
# C. agent-call: a cliff refusal does not descend
# ============================================================================
echo "--- C. bin/agent-call.sh cliff refusal"
HA="$T/ha"
mkdir -p "$HA/bin" "$HA/fakebin" "$HA/logs" "$HA/flags" "$HA/locks" "$HA/state"
# BH-1510.1: agent-call reads its ladders from model_routes; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$HA" testproj otherproj pinproj
cat > "$T/prices.json" <<'EOF'
{"per_token": {
  "grok-4.6": {"prompt": 0.000002, "completion": 0.000006, "cache_read": 5e-7,
               "cache_write": null, "cliff_tokens": 200000},
  "claude-opus-5": {"prompt": 0.000015, "completion": 0.000075,
                    "cache_read": 0.0000015, "cache_write": 0.00001875},
  "cheap-floor-1": {"prompt": 0.0000001, "completion": 0.0000003,
                    "cache_read": 0.00000005, "cache_write": 0}
}}
EOF
cat > "$HA/fakebin/grok" <<'EOF'
#!/bin/bash
echo grok >> "$ORDER_SINK"
echo "grok answered"
EOF
cat > "$HA/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
printf '{"result":"claude answered","session_id":"s-fake"}\n'
EOF
cat > "$HA/fakebin/codex" <<'EOF'
#!/bin/bash
p=codex
for a in "$@"; do case "$a" in *openrouter*) p=openrouter ;; *fireworks*) p=fireworks ;; esac; done
echo "$p" >> "$ORDER_SINK"
echo "$p answered"
EOF
cat > "$HA/fakebin/timeout" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--kill-after" ] && shift 2
case "${1:-}" in --kill-after=*) shift ;; esac
shift
exec "$@"
EOF
printf '#!/bin/bash\necho subscription\n' > "$HA/bin/billing-mode.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$BEAT_SINK"\n' > "$HA/bin/beat.sh"
printf '#!/bin/bash\necho "test rules"\n' > "$HA/bin/sync-agent-rules.sh"
chmod +x "$HA/fakebin/"* "$HA/bin/"*

cat > "$T/cb-refuse.json" <<'EOF'
{"lanes": [
  {"lane":"refuse-fixture","stage":"eval","project":"testproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,
   "cliff_route":true,"cliff_refuse":true},
  {"lane":"route-only","stage":"eval","project":"otherproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true},
  {"lane":"pin-route","stage":"eval","project":"pinproj","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_route":true},
  {"lane":"pin-refuse","stage":"eval","project":"pinproj","runner":"claude","job":"fixture",
   "target_tokens":60000,"ceiling_tokens":200000,"cliff_refuse":true}
]}
EOF
printf '%s\n' "$HDR" > "$HA/logs/cost.csv"
seed_ctx() { # seed_ctx <project> — 10 rows whose context sits past the cliff
  local i=0 r n
  while [ "$i" -lt 10 ]; do
    r="2026-09-18T00:00:00Z,box,$1,eval,claude,claude-opus-5,0,10,676000,100,0,0,0.10,subscription,fp,acct,sess,transcript,,,,,"
    n=$(awk -F, '{print NF}' <<<"$r"); while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
    printf '%s\n' "$r" >> "$HA/logs/cost.csv"; i=$((i+1))
  done
}
seed_ctx testproj
seed_ctx otherproj
seed_ctx pinproj

drive_model() { # drive_model <project> <model> [env...] ; echoes rc
  : > "$T/order"; : > "$T/beats"; : > "$HA/logs/failovers.log"; : > "$HA/logs/ALERTS.log"
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY
    local pj="$1" md="$2"; shift 2
    export HOME="$HA" HARNESS="$HA" PATH="$HA/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$T/cb-refuse.json" \
           ORDER_SINK="$T/order" BEAT_SINK="$T/beats" LADDER_BACKOFF_SECS=0 \
           RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=claude "$@"
    bash "$DIR/bin/agent-call.sh" eval "$pj" "$md" 60 "$HA/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

drive() { # drive <project> [env...] ; echoes rc
  : > "$T/order"; : > "$T/beats"; : > "$HA/logs/failovers.log"; : > "$HA/logs/ALERTS.log"
  ( unset OPENROUTER_API_KEY FIREWORKS_API_KEY XAI_API_KEY GROK_CODE_XAI_API_KEY \
          OPENAI_API_KEY CODEX_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY
    local pj="$1"; shift
    export HOME="$HA" HARNESS="$HA" PATH="$HA/fakebin:$PATH" \
           MODEL_PRICES="$T/prices.json" CONTEXT_BUDGETS="$T/cb-refuse.json" \
           ORDER_SINK="$T/order" BEAT_SINK="$T/beats" LADDER_BACKOFF_SECS=0 \
           RUNNER_EVAL=grok RUNNER_EVAL_FALLBACK=claude "$@"
    bash "$DIR/bin/agent-call.sh" eval "$pj" claude-opus-5 60 "$HA/out.txt" "hello" \
      >/dev/null 2>&1 )
  echo $?
}

# C1. The lane that declares cliff_refuse: grok is skipped on price, and NOTHING
# below it is bought. rc 79, no runner called at all.
RC=$(drive testproj)
[ "$RC" = 79 ] && ok || bad "C1 a refusing lane must exit with the refusal code 79 (got $RC)"
[ ! -s "$T/order" ] && ok || bad "C1b no runner may be called at all, got: $(paste -sd, "$T/order")"
grep -q 'CLIFF REFUSE' "$HA/logs/failovers.log" \
  && ok || bad "C1c the refusal must be declared: $(cat "$HA/logs/failovers.log")"
[ ! -s "$T/beats" ] && ok || bad "C1d a routine refusal is not a page: $(cat "$T/beats")"

# C2. The control, and it is the one that proves C1 is about the new key and
# not about a broken fixture: the SAME cliff, the same ladder, a lane that does
# NOT declare cliff_refuse still descends exactly as it does today.
RC=$(drive otherproj)
[ "$RC" = 0 ] && ok || bad "C2 a lane without cliff_refuse must still descend and succeed (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C2b the control must descend to the configured fallback, got: $(paste -sd, "$T/order")"

# C3. The kill switch. An operator who wants the old behaviour back has one.
RC=$(drive testproj LADDER_CLIFF_REFUSE=0)
[ "$RC" = 0 ] && ok || bad "C3 LADDER_CLIFF_REFUSE=0 must restore the descent (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C3b with refusal off the ladder must descend, got: $(paste -sd, "$T/order")"
RC=$(drive otherproj LADDER_CLIFF_REFUSE=1)
[ "$RC" = 79 ] && ok || bad "C4 LADDER_CLIFF_REFUSE=1 must force the refusal on any lane (got $RC)"

# C6. THE REFUSAL IS A PRICE COMPARISON, NOT A REFLEX (round 1, B3). A flat
# refusal has no exit: a refused call writes no cost row, and the projection it
# refused on is the median of the last ten rc-0 rows, so the number can never
# move. When the rung below is genuinely CHEAPER at this size the ladder
# descends exactly as BH-656 intended — and that descent writes the row that
# lets the projection fall again.
RC=$(drive_model testproj cheap-floor-1)
[ "$RC" = 0 ] \
  && ok || bad "C6 a rung below that is CHEAPER than a doubled grok must be taken (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C6b ...on the configured fallback, got: $(paste -sd, "$T/order")"
grep -q 'CLIFF REFUSE NOT TAKEN' "$HA/logs/failovers.log" \
  && ok || bad "C6c and the decision must be declared: $(cat "$HA/logs/failovers.log")"
# The dear rung still refuses, and the line says WHY.
RC=$(drive testproj)
grep -q 'prices ABOVE a doubled' "$HA/logs/failovers.log" \
  && ok || bad "C6d the refusal line must name the comparison it made: $(cat "$HA/logs/failovers.log")"
# C7. An UNPRICEABLE rung refuses. This is the one reader in the wave that does
# not fail open: descending on a rung nobody can price is exactly the $793
# shape, and nothing is lost by refusing — the caller re-spools the unit.
RC=$(drive_model testproj model-with-no-price-row)
[ "$RC" = 79 ] && ok || bad "C7 an unpriceable rung below must refuse, not descend (got $RC)"
[ ! -s "$T/order" ] && ok || bad "C7b ...and buy nothing: $(paste -sd, "$T/order")"

# C8. THE RUNNER TERM (round 1, N3). cliff_refuse is read with the same
# selector as cliff_route, runner included — so a row pinned to one executor
# cannot switch refusal on for a different one. pinproj routes on its project
# row and its cliff_refuse row is pinned to `claude`, which is NOT the runner
# being skipped, so this lane descends.
RC=$(drive pinproj)
[ "$RC" = 0 ] \
  && ok || bad "C8 a cliff_refuse row pinned to another runner must not apply (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C8b ...the lane descends as its own rows say, got: $(paste -sd, "$T/order")"

# C9-C11. THE GATE MUST PRICE THE MODEL THE RUNG BELOW ACTUALLY RUNS (round 2,
# I2). `run_attempt` remaps per runner — codex runs ${CODEX_MODEL:-gpt-6-astra},
# fireworks runs $FIREWORKS_MODEL, openrouter runs the anthropic/ slug — and only
# a `claude` rung runs the stage's argv $MODEL. The gate priced $MODEL, so with a
# claude fallback (C1-C8 above) it happened to be right and with every other one
# it was wrong in BOTH directions.
#
# C9. The dangerous direction: a CHEAP argv model, a DEAR rung below. The gate
# said "no dearer than a doubled grok" about a model nobody was about to run,
# and approved the descent — the 2026-09-20 shape exactly (codex/gpt-6-astra).
RC=$(drive_model testproj cheap-floor-1 RUNNER_EVAL_FALLBACK=codex \
       CODEX_MODEL=claude-opus-5 CODEX_API_KEY=x)
[ "$RC" = 79 ] \
  && ok || bad "C9 a codex rung running a DEAR model must be refused however cheap the argv model is (got $RC)"
[ ! -s "$T/order" ] && ok || bad "C9b ...and nothing may be called: $(paste -sd, "$T/order")"
grep -q 'claude-opus-5' "$HA/logs/failovers.log" \
  && ok || bad "C9c the refusal must name the model it actually priced: $(cat "$HA/logs/failovers.log")"

# C10. The other direction, and it is the exit path: a DEAR argv model whose
# rung below runs a CHEAP one. The old gate refused a rung that costs cents.
RC=$(drive_model testproj claude-opus-5 RUNNER_EVAL_FALLBACK=codex \
       CODEX_MODEL=cheap-floor-1 CODEX_API_KEY=x)
[ "$RC" = 0 ] \
  && ok || bad "C10 a rung below running a CHEAP model must be taken, whatever the argv model costs (got $RC)"
[ "$(paste -sd, "$T/order")" = "codex" ] \
  && ok || bad "C10b ...on that rung, got: $(paste -sd, "$T/order")"
grep -q 'CLIFF REFUSE NOT TAKEN' "$HA/logs/failovers.log" \
  && ok || bad "C10c and the decision must be declared: $(cat "$HA/logs/failovers.log")"

# C11. A TIER-2 GROK CLIFF IS THE SAME DECISION (round 2, I3). The refusal
# covered only the PRIMARY's cliff, so a lane whose primary FAILS and whose
# tier-2 grok then cliff-routes walked on to the fallback and OpenRouter with
# cliff_refuse on — the same ladder, one rung later. The primary here is claude
# and its fakebin exits nonzero, so tier-2 grok is the rung that cliffs.
cat > "$HA/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
exit 3
EOF
chmod +x "$HA/fakebin/claude"
RC=$(drive_model testproj claude-opus-5 RUNNER_EVAL=claude RUNNER_EVAL_FALLBACK=codex \
       CODEX_MODEL=claude-opus-5 CODEX_API_KEY=x)
[ "$RC" = 79 ] \
  && ok || bad "C11 a tier-2 grok cliff must refuse the dear rung below it too (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude" ] \
  && ok || bad "C11b nothing past the failed primary may be called, got: $(paste -sd, "$T/order")"
grep -q 'CLIFF REFUSE (tier-2)' "$HA/logs/failovers.log" \
  && ok || bad "C11c the tier-2 refusal must be declared as such: $(cat "$HA/logs/failovers.log")"
# ...and the control: when the rung below tier-2 is CHEAP, the ladder still
# descends, so this gate is a price comparison and not a second reflex.
RC=$(drive_model testproj claude-opus-5 RUNNER_EVAL=claude RUNNER_EVAL_FALLBACK=codex \
       CODEX_MODEL=cheap-floor-1 CODEX_API_KEY=x)
[ "$RC" = 0 ] \
  && ok || bad "C11d a cheap rung below a tier-2 cliff must still be taken (got $RC)"
[ "$(paste -sd, "$T/order")" = "claude,codex" ] \
  && ok || bad "C11e ...and it is the rung that runs, got: $(paste -sd, "$T/order")"
# Restore the healthy primary for anything after this.
cat > "$HA/fakebin/claude" <<'EOF'
#!/bin/bash
echo claude >> "$ORDER_SINK"
printf '{"result":"claude answered","session_id":"s-fake"}\n'
EOF
chmod +x "$HA/fakebin/claude"

# C5. The manifest says which lane refuses, so changing it is config, not code.
jq -e '[.lanes[] | select(.lane == "alert-triage") | .cliff_refuse] | any' \
  "$DIR/catalog/context-budgets.json" >/dev/null \
  && ok || bad "C5 the alert-triage lane must declare cliff_refuse in catalog/context-budgets.json"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
