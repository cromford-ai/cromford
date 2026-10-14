#!/bin/bash
# tests/triage-volume-caps.bh-1039-test.sh — bin/alert-triage.sh must stop
# paying for work it can settle deterministically, must stop entirely when the
# day's dollars are gone, and must never descend to a 100x rung on a cliff
# refusal (BH-1039).
#
# THE INCIDENT. 2026-09-20, 00:00-12:20Z: 208 rows, $793, against a $39-$61/day
# baseline. 150 of the 192 sessions concluded `handled=0 escalated=0 noise=1` —
# roughly $4 each to classify a stale heartbeat as noise — while every tick
# logged `deferred 485 families to next tick`. The session cap held the whole
# time; what moved was the PRICE, because the configured grok runner hit its
# context cliff and the ladder fell through to codex and then Fable over
# OpenRouter.
#
# Four properties, each of which had to be false for that to happen:
#   A  a family that is deterministically settleable is settled with NO model
#      call, and the settlement is LOGGED with its proof;
#   B  the evidence a session is handed is capped WITH A MARKER (today the lane
#      cuts at 20000 bytes and says nothing, so a session on a third of the
#      evidence reads exactly like one on all of it);
#   C  a lane at its daily dollar cap buys no session at all, consumes nothing,
#      and pages once;
#   D  a cliff refusal DEFERS the family instead of buying it on a costlier
#      lane — and the deferral is bounded, so a permanently-cliffed family is
#      escalated rather than spun forever.
#
# This runs the REAL bin/alert-triage.sh end to end, exactly as
# tests/triage-split-test.sh does: only the harness ROOT is rewritten, and only
# the things that would leave this machine or spend money are stubbed. What the
# stub RECEIVES is the assertion.
#
# Run from anywhere: tests/triage-volume-caps.bh-1039-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 132 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock anchor for the whole suite: the fixtures are built relative to it,
# so nothing here depends on the wall clock.
NOW=$(date -u +%s)
DAY=$(date -u +%Y-%m-%d)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/catalog" "$T/stub" "$T/calls"
: > "$H/env/global.env"

sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
chmod +x "$H/bin/alert-triage.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py alert-line.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
ln -sfn "$DIR/bin/lib" "$H/bin/lib"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1  # BH-1510.2: lanes read models from model_routes
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1
# BH-5942: project-1 and fleet are not fleet.conf projects, so every line here
# belongs to the home project's run; its spool and brake files live under HP.
HP="$H/state/alert-triage/cromford"

cat > "$H/catalog/lane-caps.conf" <<'EOF'
lane alert-triage 120 20000
default 200 20000
EOF

cat > "$T/prices.json" <<'EOF'
{"per_token": {"claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015,
                                    "cache_read": 3e-7, "cache_write": 0.00000375}}}
EOF

# --- stubs -------------------------------------------------------------------
# The agent-call stub records what it was handed and answers however the current
# case needs (AGENT_STUB_RC / AGENT_STUB_CLIFF).
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
# WHICH RUNG CALLED. The floor retry is only a real exit path if it actually
# runs on the floor lane, so the stub records the runner it was handed.
printf '%s' "${RUNNER_TRIAGE:-strong}" > "$CALLDIR/runner-$N.txt"
CLIFF=0
case "${AGENT_STUB_CLIFF:-0}" in
  1) CLIFF=1 ;;
  # `strong`: the cliff is the STRONG tier's, which is the real shape — the
  # floor lane runs an open model with no cliff at this size.
  strong) [ "${RUNNER_TRIAGE:-}" = fireworks ] || CLIFF=1 ;;
esac
if [ "$CLIFF" = 1 ]; then
  printf 'AGENT_CALL_CLIFF_ROUTED grok projected 1408081 > cliff 200000\n' > "$5"
  exit 79
fi
echo "handled=1 escalated=0 noise=0" > "$5"
exit "${AGENT_STUB_RC:-0}"
STUB
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$T/stub/timeout"; chmod +x "$T/stub/timeout"

# --- fixtures ----------------------------------------------------------------
# beat.sh's own line shape: epoch<TAB>beat-json. AGE is seconds before NOW.
q() { # q <file> <age-secs> <project> <akey> <line>
  printf '%s\t{"kind":"fleet_alert","project":"%s","akey":"%s","line":"%s"}\n' \
    "$(( NOW - $2 ))" "$3" "$4" "$5" >> "$1"
}

# A RETRACTION beat: `resolved:true` is what bin/lane-alert.sh:107 and
# bin/pipeline-health.sh:749/820/1008 put on one, and what bin/beat.sh:227
# already reads to keep the remediator off it.
qr() { # qr <file> <age-secs> <project> <akey> <line>
  printf '%s\t{"kind":"fleet_alert","project":"%s","akey":"%s","resolved":true,"line":"%s"}\n' \
    "$(( NOW - $2 ))" "$3" "$4" "$5" >> "$1"
}

HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
fresh_ledger() { printf '%s\n' "$HDR" > "$H/logs/cost.csv"; }
# The lane name goes in the PROJECT column and the stage reads `triage`, which
# is exactly how bin/alert-triage.sh calls agent-call.sh. A fixture that put the
# lane in both columns would pass a reader that only looked at the stage — and
# that reader sums $0.00 on a real hub, forever.
crow() { # crow <cost_usd>
  local r n
  r="${DAY}T04:00:00Z,box,alert-triage,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0,$1,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$H/logs/cost.csv"
}

run() { # run [env assignments...]
  rm -rf "${T:?}/calls"; mkdir -p "$T/calls"
  ( export CALLDIR="$T/calls" PATH="$T/stub:$PATH" MODEL_PRICES="$T/prices.json" \
           LANE_CAPS_CONF="$H/catalog/lane-caps.conf"
    [ "$#" -gt 0 ] && export "$@"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
}
ncalls() { ls "$T/calls"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
reset_state() {
  triage_tick_reset "$H"
  : > "$H/logs/alert-triage.log"; : > "$H/logs/ALERTS.log"
  echo '{}' > "$H/state/alert-families.json"
  : > "$H/state/alert-triage-deferred.tsv"
  rm -f "$H/state/alert-triage-cliff.json" "$H/flags/"alerted-lane-usd-* \
        "$H/flags/"alerted-triage-cliff-* "$H/state/alert-triage-cliff-parked.tsv"
  fresh_ledger
}
famcount() { [ -e "$HP/alert-families.json" ] || { echo 0; return; }; python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HP/alert-families.json"; }

echo "--- A. deterministic settlement: only what THIS BATCH supersedes"
# BOTH RULES ARE POSITIVE (round 1, B2). The first draft settled anything older
# than a TTL whose TEXT matched `stale|heartbeat|...`, on the premise that such
# a class "re-beats while it holds". bin/fleet-heartbeat.sh:78 emits `hb-stale`
# ONCE behind state/stale-$h; merge-queue's `mq-stale` is a one-shot;
# pipeline-health's `stalepr` re-raises at 21600s against a 3600s TTL. So the
# premise was false for the very emitters the pattern matched, and a watcher
# that died at 02:00 would have been logged NOISE-STALE and never restarted.
reset_state
: > "$H/state/alert-quarantine.jsonl"
# The same condition beaten twice: the older beat is superseded BY A LINE IN
# THIS BATCH, which is a fact about the batch and not a guess about the emitter.
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "hb-stale:box-4" "box box-4 heartbeat is STALE — no beat for 40 minutes"
q "$H/state/alert-quarantine.jsonl"   60 project-1 "hb-stale:box-4" "box box-4 heartbeat is STALE — no beat for 40 minutes"
run
[ "$(ncalls)" = 1 ] && ok || bad "A1 the family must still buy exactly one session (got $(ncalls))"
grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A1b the superseded beat must be settled and logged: $(cat "$H/logs/alert-triage.log")"
grep -q 'superseded:' "$H/logs/alert-triage.log" \
  && ok || bad "A1c the settlement must name WHICH rule settled it"
grep -q 'no model call' "$H/logs/alert-triage.log" \
  && ok || bad "A1d the settlement line must say it cost nothing"
grep -q 'heartbeat is STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A1e the settlement line must carry the alert it settled, as its proof"
# ONE of the two lines reached the prompt — the newest. Nothing in this batch
# supersedes it, so nothing may settle it.
[ "$(grep -c 'heartbeat is STALE' "$T/calls/prompt-0.txt")" = 1 ] \
  && ok || bad "A1f the NEWEST beat of an akey must always survive to the session"

# THE REGRESSION THIS RULE EXISTS FOR. A still-held condition, old, ALONE in the
# batch: nothing supersedes it, so it must buy its session. Settling this one is
# how a dead watcher goes unrestarted at $0.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "hb-stale:box-4" "box box-4 heartbeat is STALE — no beat for 40 minutes"
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A2 a still-held hb-stale with no newer beat must be INVESTIGATED, not settled on age (got $(ncalls))"
! grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A2b fleet-heartbeat emits hb-stale ONCE — age says nothing about whether it still holds: $(cat "$H/logs/alert-triage.log")"
# Same for the other two one-shot emitters the old free-text pattern swallowed.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 30000 project-1 "health:stalepr:project-1" "PR #1149 has been open and stale for 8h"
q "$H/state/alert-quarantine.jsonl" 30000 project-1 "mq-stale:project-1:123" "merge queue entry 123 is stale and needs a rebase"
run
[ "$(ncalls)" = 2 ] \
  && ok || bad "A3 stalepr (re-raises at 21600s) and mq-stale (one-shot) must both be investigated (got $(ncalls))"
! grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A3b neither may be settled on age: $(cat "$H/logs/alert-triage.log")"
# ...and the akey is what is matched, never the payload. A line whose TEXT says
# "stale" is not thereby a self-re-raising class.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "pay-1" "Mercury payout 403: the token is stale"
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A4 the word 'stale' in a payload must not settle anything (got $(ncalls))"

# AGE SETTLES ONLY WHAT AN OPERATOR OPTED IN, BY AKEY PREFIX, having verified
# that emitter re-raises faster than the TTL.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "health:sweepstall:project-1" "pipeline-health sweepstall on project-1"
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "hb-stale:box-9" "box box-9 heartbeat is STALE"
run TRIAGE_STALE_AKEYS=health:sweepstall:
[ "$(ncalls)" = 1 ] \
  && ok || bad "A5 only the opted-in akey may settle on age (got $(ncalls))"
grep -q 'stale-akey' "$H/logs/alert-triage.log" \
  && ok || bad "A5b the opt-in settlement must name its rule: $(cat "$H/logs/alert-triage.log")"
grep -q 'box-9' "$T/calls/prompt-0.txt" 2>/dev/null \
  && ok || bad "A5c the NOT-opted-in family must be the one that bought the session"
# Empty by default: without the opt-in neither settles.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 7200 project-1 "health:sweepstall:project-1" "pipeline-health sweepstall on project-1"
run
[ "$(ncalls)" = 1 ] && ok || bad "A5d the opt-in list must be EMPTY by default (got $(ncalls))"

# A FRESH beat is never settled either way.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 beat-2 "box box-4 heartbeat is STALE — no beat for 40 minutes"
run
[ "$(ncalls)" = 1 ] && ok || bad "A6 a FRESH stale-beat alert must still be investigated (got $(ncalls))"
! grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A6b a fresh alert must not be settled: $(cat "$H/logs/alert-triage.log")"

# A family whose own newest line says the condition RESOLVED is settled whatever
# its AGE — this rule is not the supersession one wearing a different hat. The
# flapping sweepstall pair (#735, #1073) put 12 RESOLVED lines each into one
# night's backlog, minutes old and each one a full session.
#
# The two lines below are two FAMILIES, not one, because the family key is a
# normalisation of the line and "RESOLVED" is part of the line. That is the
# correct boundary and it is what makes the rule safe: settling the resolved
# family says nothing about the condition that is still firing beside it.
#
# THE FIXTURE IS THE EMITTER'S OWN SHAPE (round 2, B1). This case used to put
# the bare word RESOLVED at the END of a line, which passed only because the
# rule was "the text contains RESOLVED anywhere" — the rule that settled live
# SLO breaches at $0 (A10 below). bin/pipeline-health.sh:1007 writes
# `[pipeline-health] RESOLVED <key> — condition no longer holds`, and that is
# what a retraction with no structured field actually looks like.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 sweep-1 "pipeline-health sweepstall on project-1"
q "$H/state/alert-quarantine.jsonl" 60 project-1 sweep-1 "[pipeline-health] RESOLVED health:sweepstall:project-1 — condition no longer holds"
run
[ "$(ncalls)" = 1 ] && ok || bad "A7 a fresh RESOLVED line needs no session; the firing one still does (got $(ncalls))"
! grep -q 'RESOLVED' "$T/calls/prompt-0.txt" 2>/dev/null \
  && ok || bad "A7b the session that ran must be the FIRING family, not the resolved one"
grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A7c the resolved family must be settled and logged: $(cat "$H/logs/alert-triage.log")"
grep -q 'resolved:' "$H/logs/alert-triage.log" \
  && ok || bad "A7d the settlement must name WHICH rule settled it"
[ ! -s "$H/state/alert-quarantine.jsonl" ] \
  && ok || bad "A8 the quarantine must still be consumed for a settled family"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "A8b a settled family is finished, not spooled: $(cat "$HP/deferred.tsv")"

# A9. THE STRUCTURED FIELD IS THE RULE (round 2, B1). Every retraction emitter
# in this repo sets `resolved:true` on the beat; that field, not the prose, is
# what says "this is a retraction". A retraction whose text says nothing of the
# sort must still settle.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q  "$H/state/alert-quarantine.jsonl" 60 project-1 sweep-2 "pipeline-health sweepstall on project-1"
qr "$H/state/alert-quarantine.jsonl" 60 project-1 "health:sweepstall:project-1" "the sweep has caught up on project-1"
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A9 a beat marked resolved:true must settle; the firing one still buys its session (got $(ncalls))"
grep -q 'resolved:' "$H/logs/alert-triage.log" \
  && ok || bad "A9b the structured retraction must be settled by the resolved rule: $(cat "$H/logs/alert-triage.log")"
! grep -q 'the sweep has caught up' "$T/calls/prompt-0.txt" 2>/dev/null \
  && ok || bad "A9c the retraction must not be what bought the session"
# ...and alertstate:"resolve" alone (lane-alert writes both; a future emitter
# may write only this one).
reset_state
: > "$H/state/alert-quarantine.jsonl"
printf '%s\t{"kind":"fleet_alert","project":"fleet","akey":"orclane:x","alertstate":"resolve","line":"the queue drained"}\n' \
  "$(( NOW - 60 ))" >> "$H/state/alert-quarantine.jsonl"
run
[ "$(ncalls)" = 0 ] && ok || bad "A9d alertstate=resolve must settle too (got $(ncalls))"

# A10. THE REGRESSION THIS RULE EXISTS FOR (round 2, B1). A LIVE, FIRING alert
# whose own text happens to contain the word RESOLVED must buy its session. The
# text-anywhere rule settled these at $0 and logged "condition cleared" — a
# false verdict on a live alert, which is worse than the session it saved.
# bin/fleet-slo.sh:271 ends EVERY SLO BREACH with this sentence.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 fleet "slo:p95-scan" "SLO BREACH [slo-p95-20260920] p95_scan = 900 (threshold 600, window 60m): 12 of 40 scans over. Thresholds live in flags/slo.conf; this incident will not re-fire while it is open, and clears itself with a RESOLVED line."
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A10 a live fleet-slo.sh:271 BREACH must buy its session (got $(ncalls))"
! grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A10b ...and must not be logged as a cleared condition: $(cat "$H/logs/alert-triage.log")"
grep -q 'SLO BREACH' "$T/calls/prompt-0.txt" 2>/dev/null \
  && ok || bad "A10c the breach itself must be the evidence the session got"
# bin/blocked-resolver.sh:2444 — the second emitter, and it says `resolved`
# lower case in the middle of a sentence.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 "br-setup-blocked" "no repo/branch could be resolved for https://github.com/example-org/project-1/pull/41 even after re-reading it under its own token"
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A10d a blocked-resolver park alert must buy its session (got $(ncalls))"
! grep -q 'NOISE-STALE' "$H/logs/alert-triage.log" \
  && ok || bad "A10e ...and must not be settled: $(cat "$H/logs/alert-triage.log")"
# ...and the other phrases the first pattern carried, mid-sentence in a FIRING
# line: a partial recovery that still needs a human is not a retraction.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 "wedge-1" "the queue has recovered but the worker is still wedged and needs a human"
run
[ "$(ncalls)" = 1 ] \
  && ok || bad "A10f 'has recovered' inside a firing line must not settle it (got $(ncalls))"

echo "--- B. the evidence cap carries a marker"
reset_state
: > "$H/state/alert-quarantine.jsonl"
PAD=$(awk 'BEGIN{for(i=1;i<=300;i++) printf "xpad%04d", i}')
I=0
while [ "$I" -lt 12 ]; do
  q "$H/state/alert-quarantine.jsonl" 60 project-1 big-1 "the widget subsystem is unhappy $PAD"
  I=$((I+1))
done
run LANE_BYTES_CAP_ALERT_TRIAGE=4000
[ "$(ncalls)" = 1 ] && ok || bad "B1 the oversized family must still be investigated (got $(ncalls))"
PB=$(wc -c < "$T/calls/prompt-0.txt" | tr -d ' ')
grep -q '\[capped:' "$T/calls/prompt-0.txt" \
  && ok || bad "B2 an over-cap prompt must carry the truncation MARKER (prompt is ${PB}B)"
EV=$(grep -c 'the widget subsystem is unhappy' "$T/calls/prompt-0.txt")
[ "$EV" -lt 12 ] && ok || bad "B3 the cap must actually drop evidence (all $EV lines survived a 4000B cap)"
# ...and under the cap nothing is marked, or the marker means nothing.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 small-1 "the widget subsystem is unhappy"
run LANE_BYTES_CAP_ALERT_TRIAGE=20000
! grep -q '\[capped:' "$T/calls/prompt-0.txt" \
  && ok || bad "B4 a prompt under the cap must not claim it was capped"

# B5. MARKER-ONLY EVIDENCE BUYS NOTHING (round 2, I4). One line longer than the
# whole cap: the whole-line cut keeps nothing, so the prompt would carry the
# truncation marker and not a single alert — a strong-tier session on zero
# evidence, with the family then stamped into the 6h brake by nobody having
# read it.
reset_state
: > "$H/state/alert-quarantine.jsonl"
HUGE=$(awk 'BEGIN{for(i=1;i<=2500;i++) printf "xpad%04d", i}')
q "$H/state/alert-quarantine.jsonl" 60 project-1 huge-1 "the widget subsystem is unhappy $HUGE"
run LANE_BYTES_CAP_ALERT_TRIAGE=20000
[ "$(ncalls)" = 0 ] \
  && ok || bad "B5 a family whose evidence does not fit at all must buy NO session (got $(ncalls))"
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "B6 ...and its lines must be re-spooled, not dropped"
grep -q 'the widget subsystem is unhappy' "$HP/deferred.tsv" \
  && ok || bad "B6b the spooled lines must be that family's own"
[ "$(famcount)" = 0 ] \
  && ok || bad "B7 a family nobody read must not be stamped into the 6h brake (stamped $(famcount))"
grep -q 'NO SESSION' "$H/logs/alert-triage.log" \
  && ok || bad "B8 the skip must be declared with the cap that caused it: $(cat "$H/logs/alert-triage.log")"
# ...and because the family is re-spooled forever, the stop is a PAGE, once a
# day: a queue that never drains and says nothing is the dead-feed shape.
grep -q 'EVIDENCE CAP TOO SMALL' "$H/logs/ALERTS.log" \
  && ok || bad "B8b a permanent skip must page once a day: $(cat "$H/logs/ALERTS.log")"
run LANE_BYTES_CAP_ALERT_TRIAGE=20000
[ "$(grep -c 'EVIDENCE CAP TOO SMALL' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "B8c ...once, not once per tick: $(grep -c 'EVIDENCE CAP TOO SMALL' "$H/logs/ALERTS.log")"

echo "--- C. the daily dollar cap stops the lane and consumes nothing"
reset_state
crow 200.00
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 capped-1 "the widget subsystem is unhappy"
run
[ "$(ncalls)" = 0 ] && ok || bad "C1 a lane over its day cap must buy NO session (got $(ncalls))"
[ -s "$H/state/alert-quarantine.jsonl" ] \
  && ok || bad "C2 a stopped lane must not consume the quarantine — the work has to come back"
[ "$(famcount)" = 0 ] && ok || bad "C3 a stopped lane must stamp nothing (stamped $(famcount))"
grep -q 'DAILY SPEND CAP' "$H/logs/ALERTS.log" \
  && ok || bad "C4 the stop must page once: $(cat "$H/logs/ALERTS.log")"
grep -q 'daily spend cap' "$H/logs/alert-triage.log" \
  && ok || bad "C5 the lane log must say why this tick did nothing: $(cat "$H/logs/alert-triage.log")"
# Under the cap the lane runs exactly as before.
reset_state
crow 5.00
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 under-1 "the widget subsystem is unhappy"
run
[ "$(ncalls)" = 1 ] && ok || bad "C6 under the cap the lane must run normally (got $(ncalls))"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "C6b a healthy lane must page nothing: $(cat "$H/logs/ALERTS.log")"

echo "--- D. a cliff refusal retries on the floor, then defers; it never buys a costlier rung"
# THE FLOOR RETRY IS THE EXIT PATH (round 1, B3). A refusal writes no cost row,
# and agent-call's projection is the median of this lane's last ten rc-0 rows —
# so a refusing lane can never move the number that made it refuse. Every
# refused family returns strong-tier next tick, is refused again, and is dropped
# on the third. The floor lane has no cliff at this size and costs cents: ONE
# retry there both triages the family and writes the row that lets the
# projection fall.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 cliff-0 "the gasket subsystem is unhappy"
run AGENT_STUB_CLIFF=strong
[ "$(ncalls)" = 2 ] \
  && ok || bad "D0 a strong-tier cliff must be retried ONCE on the floor (got $(ncalls) call(s))"
[ "$(cat "$T/calls/runner-1.txt" 2>/dev/null)" = fireworks ] \
  && ok || bad "D0b the retry must run on the floor lane (got '$(cat "$T/calls/runner-1.txt" 2>/dev/null)')"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "D0c a family the floor retry triaged is DONE, not spooled: $(cat "$HP/deferred.tsv")"
[ "$(famcount)" = 1 ] \
  && ok || bad "D0d ...and it stays stamped, because it did get a session (stamped $(famcount))"
grep -q 'retrying ONCE on the housekeeping floor' "$H/logs/alert-triage.log" \
  && ok || bad "D0e the retry must be declared: $(cat "$H/logs/alert-triage.log")"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "D0f a retry that worked is not a page: $(cat "$H/logs/ALERTS.log")"
# TRIAGE_CLIFF_FLOOR_RETRY=0 turns it off and the old deferral stands.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 cliff-0b "the gasket subsystem is unhappy"
run AGENT_STUB_CLIFF=strong TRIAGE_CLIFF_FLOOR_RETRY=0
[ "$(ncalls)" = 1 ] && ok || bad "D0g the retry must be switchable off (got $(ncalls))"
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "D0h with the retry off the family is spooled as before"

# When EVERY rung refuses, nothing is bought and the family comes back.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 cliff-1 "the widget subsystem is unhappy"
run AGENT_STUB_CLIFF=1
[ "$(ncalls)" = 2 ] && ok || bad "D1 the lane attempts the strong tier and the floor, and no more (got $(ncalls))"
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "D2 a cliff-refused family must be SPOOLED, not dropped"
grep -q 'the widget subsystem is unhappy' "$HP/deferred.tsv" \
  && ok || bad "D2b the spooled lines must be the refused family's own"
[ "$(famcount)" = 0 ] \
  && ok || bad "D3 a refused family the lane had never seen must be UN-stamped (stamped $(famcount))"
grep -qi 'cliff' "$H/logs/alert-triage.log" \
  && ok || bad "D4 the refusal must be declared in the lane log: $(cat "$H/logs/alert-triage.log")"
[ ! -s "$H/logs/ALERTS.log" ] \
  && ok || bad "D5 one routine refusal is not a page: $(cat "$H/logs/ALERTS.log")"

# A FAMILY THIS LANE HAS SEEN GOES BACK TO ITS OLD STAMP, not to "never seen"
# (round 1, N2). Popping the key makes a repeat look brand new, which buys it
# the strong tier on the next tick — the expensive half of the decision that
# just refused.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 stamp-1 "the bearing subsystem is unhappy"
run
[ "$(famcount)" = 1 ] && ok || bad "N2-setup the first (successful) pass must stamp the family"
python3 - "$HP/alert-families.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
json.dump({k: v - 25200 for k, v in d.items()}, open(p, "w"))
PY
BEFORE=$(cat "$HP/alert-families.json")
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 stamp-1 "the bearing subsystem is unhappy"
run AGENT_STUB_CLIFF=1
[ "$(famcount)" = 1 ] \
  && ok || bad "N2 a refused family the lane HAD seen must keep an entry, not be popped (stamped $(famcount))"
[ "$(cat "$HP/alert-families.json")" = "$BEFORE" ] \
  && ok || bad "N2b ...and the entry must be its PRE-TICK stamp: $(cat "$HP/alert-families.json") vs $BEFORE"

# BOUNDED. A family that cliffs every tick would otherwise defer forever at $0
# and never be looked at — a silent loss wearing a working cap's clothes.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 cliff-2 "the sprocket subsystem is unhappy"
N=0
while [ "$N" -lt 4 ]; do run AGENT_STUB_CLIFF=1; N=$((N+1)); done
grep -q 'CLIFF REFUSALS' "$H/logs/ALERTS.log" \
  && ok || bad "D6 a family refused past the attempt cap must be escalated once: $(cat "$H/logs/ALERTS.log")"
[ "$(grep -c 'CLIFF REFUSALS' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "D6b the escalation must fire once, not once per tick"
[ ! -s "$HP/deferred.tsv" ] \
  && ok || bad "D7 past the attempt cap the family stops being re-spooled: $(cat "$HP/deferred.tsv")"
# PARKED, NOT DROPPED (round 1, I1). The first draft deleted the lines and then
# paged "$FCOUNT alert line(s) are waiting on it" — they were waiting nowhere.
[ -s "$H/state/alert-triage-cliff-parked.tsv" ] \
  && ok || bad "D7b the lines must be PARKED where an operator can re-queue them"
grep -q 'the sprocket subsystem is unhappy' "$H/state/alert-triage-cliff-parked.tsv" \
  && ok || bad "D7c the parked lines must be the refused family's own"
grep -q 'alert-triage-cliff-parked.tsv' "$H/logs/ALERTS.log" \
  && ok || bad "D7d the page must say WHERE they are: $(cat "$H/logs/ALERTS.log")"
grep -q 'cat .* >> ' "$H/logs/ALERTS.log" \
  && ok || bad "D7e ...and how to put them back"

# ONE PAGE PER LANE PER DAY, not per family (round 1, B3). The condition is a
# routing fact that is identical for every family on the lane, and the
# 2026-09-20 backlog was 485 families.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 many-1 "the alpha subsystem is unhappy"
q "$H/state/alert-quarantine.jsonl" 60 project-1 many-2 "the beta subsystem is unhappy"
N=0
while [ "$N" -lt 4 ]; do run AGENT_STUB_CLIFF=1; N=$((N+1)); done
[ "$(grep -c 'CLIFF REFUSALS' "$H/logs/ALERTS.log")" = 1 ] \
  && ok || bad "D7f two refused families must still page ONCE: $(grep -c 'CLIFF REFUSALS' "$H/logs/ALERTS.log")"
[ "$(grep -c . "$H/state/alert-triage-cliff-parked.tsv")" = 2 ] \
  && ok || bad "D7g ...and BOTH families' lines must be parked"

# A SUCCESSFUL session clears the refusal counter — a lane that cliffed twice
# last week must not be one refusal from escalation today.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 cliff-3 "the flange subsystem is unhappy"
run AGENT_STUB_CLIFF=1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sum(d.values())==1 else 1)' \
  "$HP/alert-triage-cliff.json" \
  && ok || bad "D8 the refusal must be counted: $(cat "$HP/alert-triage-cliff.json" 2>/dev/null)"
echo '{}' > "$HP/alert-families.json"
run
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sum(d.values())==0 else 1)' \
  "$HP/alert-triage-cliff.json" \
  && ok || bad "D9 a session that succeeds must clear the family's refusal count: $(cat "$HP/alert-triage-cliff.json" 2>/dev/null)"

echo "--- E. the splitter may never lose a tick (round 2, I1)"
# THE SHAPE. The collector DRAINS every box's quarantine and the deferral spool
# into $WORK before the splitter runs, so anything that kills the splitter
# leaves $FILTERED and $DEFERRED empty over an already-consumed batch — and the
# lane then logs "all N line(s) are repeats of families triaged <6h ago" and
# exits 0. A total loss of the batch behind a false, reassuring line.

# E1. An operator's bad regex is the way this build adds to trigger it.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 e-1 "the widget subsystem is unhappy"
q "$H/state/alert-quarantine.jsonl" 60 project-1 e-2 "the gasket subsystem is unhappy"
run TRIAGE_RESOLVED_PATTERNS='('
[ "$(ncalls)" = 2 ] \
  && ok || bad "E1 an unparseable TRIAGE_RESOLVED_PATTERNS must cost the KNOB, not the tick (got $(ncalls) session(s))"
grep -q 'TRIAGE_RESOLVED_PATTERNS' "$H/logs/alert-triage.log" \
  && ok || bad "E1b the ignored knob must be named in the lane log: $(cat "$H/logs/alert-triage.log")"
! grep -q 'are repeats of families triaged' "$H/logs/alert-triage.log" \
  && ok || bad "E1c the lane must never claim 'repeats' for lines it never looked at"

# E2. And the general case: a splitter that dies for ANY reason re-spools.
# An unparseable alert-families.json is the cheapest real trigger — json.load
# raises before a single line is grouped.
reset_state
: > "$H/state/alert-quarantine.jsonl"
q "$H/state/alert-quarantine.jsonl" 60 project-1 e-3 "the flange subsystem is unhappy"
echo 'not json at all' > "$H/state/alert-families.json"
run
[ "$(ncalls)" = 0 ] && ok || bad "E2 a dead splitter must buy nothing (got $(ncalls))"
[ -s "$HP/deferred.tsv" ] \
  && ok || bad "E2b the drained batch must be RE-SPOOLED, not swallowed"
grep -q 'the flange subsystem is unhappy' "$HP/deferred.tsv" \
  && ok || bad "E2c the spooled lines must be the batch's own"
grep -q 'RE-SPOOLED' "$H/logs/alert-triage.log" \
  && ok || bad "E2d the loss-avoidance must be declared: $(cat "$H/logs/alert-triage.log")"
! grep -q 'are repeats of families triaged' "$H/logs/alert-triage.log" \
  && ok || bad "E2e ...and the false 'repeats' line must be gone: $(cat "$H/logs/alert-triage.log")"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
