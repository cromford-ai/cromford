#!/bin/bash
# tests/alert-line-wave-lib.bh-2314-test.sh — the library alert writers go
# through bin/alert-line.sh (BH-2365, wave 3 of BH-2314).
#
# THE POINT. bin/lib/lane-caps.sh and bin/lib/gh-repo-token.sh used to
# `echo … >> ALERTS.log`, which reaches the alerts table only when
# poll-commands.sh's re-beat tails the file a minute later. Now they call
# bin/alert-line.sh, which beats {kind:"alert"} at emit time, marks the line
# sent, and still appends the SAME text to ALERTS.log.
#
# Every case drives the real library function (the production entry the lanes
# call) with the real bin/alert-line.sh; only beat.sh is a stub that records
# its payload. The assertion is on the exact text after the stamp, the beat
# payload's .line, and the marker the helper writes.
#
#   W1  lane_day_cap_tripped over its cap -> DAILY SPEND CAP line + alert beat
#   W2  lane_noise_cap_tripped over budget -> NOISE BUDGET line + alert beat
#   W3  gh_repo_invisible_alert -> INVISIBLE line + alert beat + fleet_alert beat
#   W4  the REPO copy of lane-caps sourced with HARNESS=<tree with no
#       bin/alert-line.sh> still lands the line, through the lib's own path
#   W5  under the cap: nothing; a second trip the same day: nothing more
#   W6  bin/stale-owed-tickets.sh (the script, run) on a REVIEW_BLOCKED build
#       dir with no VERDICT -> ORPHANED BUILD line + alert beat
#
# Run from anywhere: tests/alert-line-wave-lib.bh-2314-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset LANE_USD_CAP_WAVE_LANE LANE_NOISE_CAP_WAVE_LANE

DAY=$(date -u +%Y-%m-%d)
STAMP_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z '
HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")

# The scratch harness: the real helper and libs, a recording beat.sh.
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/state" "$H/env"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
cp "$DIR/bin/lib/lane-caps.sh" "$DIR/bin/lib/conf-row.sh" "$DIR/bin/lib/cost-row.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$H/bin/lib/"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"

cat > "$T/caps.conf" <<'EOF'
lane wave-lane 5 20000
noise wave-lane 3
default 50 20000
EOF
cat > "$T/prices.json" <<'EOF'
{"per_token": {"claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015,
                                    "cache_read": 3e-7, "cache_write": 0.00000375}}}
EOF

crow() { # crow <lane> <cost_usd>
  local r n
  r="${DAY}T04:00:00Z,box,$1,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0,$2,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r")
  while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$H/logs/cost.csv"
}
reset() {
  : > "$H/logs/ALERTS.log"; : > "$T/beats.txt"
  scratch_rm "$H/state/alert-line-sent"
  rm -f "$H"/flags/alerted-* "$H/state/lane-noise-wave-lane.count"
  printf '%s\n' "$HDR" > "$H/logs/cost.csv"
}
lc() { # lc <function> <args...> — the scratch lane-caps, sourced fresh
  ( export HARNESS="$H" COST="$H/logs/cost.csv" LANE_CAPS_CONF="$T/caps.conf" \
           MODEL_PRICES="$T/prices.json" LANE_CAPS_DAY="$DAY"
    . "$H/bin/lib/cost-row.sh" >/dev/null 2>&1
    . "${LCLIB:-$H/bin/lib/lane-caps.sh}" || exit 9
    "$@" )
}
alines() { grep -c . "$H/logs/ALERTS.log" 2>/dev/null; true; }
nbeats() { grep -c . "$T/beats.txt" 2>/dev/null; true; }
# check_line <case> <expected text after the stamp> — the three asserts every
# converted site owes: exact ALERTS line, one kind:"alert" beat carrying that
# same line, and the helper's sent marker for it.
check_line() {
  local c="$1" want="$2" line sha n
  [ "$(alines)" = 1 ] || { bad "$c: expected exactly one ALERTS line, got $(alines): $(cat "$H/logs/ALERTS.log")"; return; }
  line=$(head -1 "$H/logs/ALERTS.log")
  grep -qE "$STAMP_RE" <<<"$line" && ok || bad "$c: ALERTS line has no '%F %TZ' stamp: $line"
  [ "${line#* * }" = "$want" ] && ok || bad "$c: text after the stamp changed:
  want: $want
  got:  ${line#* * }"
  n=$(jq -c --arg l "$line" 'select(.kind=="alert" and .line==$l)' "$T/beats.txt" 2>/dev/null | grep -c .)
  [ "$n" = 1 ] && ok || bad "$c: expected one kind:\"alert\" beat whose .line is the ALERTS line, got $n: $(cat "$T/beats.txt")"
  sha=$(printf %s "$line" | sha1sum | cut -c1-40)
  [ -f "$H/state/alert-line-sent/$sha" ] && ok || bad "$c: no state/alert-line-sent marker for the line"
}

# W1. the daily dollar cap
echo "--- W1 lane_day_cap_tripped"
reset; crow wave-lane 7.50
lc lane_day_cap_tripped wave-lane && ok || bad "W1: \$7.50 against a \$5/day cap must trip"
check_line W1 "[wave-lane] DAILY SPEND CAP: \$7.50 spent today against a \$5/day cap — this lane is STOPPED until 00:00Z and is buying no sessions. Nothing is dropped: its work stays queued. Raise or clear the cap in $T/caps.conf (lane wave-lane), or for one run LANE_USD_CAP_WAVE_LANE=off."
ls "$H"/flags/alerted-lane-usd-wave-lane-* >/dev/null 2>&1 && ok || bad "W1: the day flag must still be touched after the line"

# W5. a second trip the same day adds nothing; under the cap is silent
echo "--- W5 negatives"
lc lane_day_cap_tripped wave-lane && ok || bad "W5: the lane is still over its cap"
[ "$(alines)" = 1 ] && [ "$(nbeats)" = 1 ] && ok || bad "W5: a second trip with the flag present must add nothing (lines $(alines), beats $(nbeats))"
reset; crow wave-lane 1.00
lc lane_day_cap_tripped wave-lane && bad "W5: \$1.00 against \$5 must not trip" || ok
[ "$(alines)" = 0 ] && [ "$(nbeats)" = 0 ] && ok || bad "W5: under the cap there must be no line and no beat (lines $(alines), beats $(nbeats))"

# W2. the noise budget
echo "--- W2 lane_noise_cap_tripped"
reset; printf '%s\t%s\n' "$DAY" 4 > "$H/state/lane-noise-wave-lane.count"
lc lane_noise_cap_tripped wave-lane && ok || bad "W2: 4 noise sessions against a budget of 3 must trip"
check_line W2 "[wave-lane] NOISE BUDGET: 4 session(s) today concluded handled=0 escalated=0 against a budget of 3/day — this lane is STOPPED until 00:00Z and is buying no sessions. Nothing is dropped: its work stays queued. A session that handles or escalates something resets the count. Raise or clear the budget in $T/caps.conf (noise wave-lane), or for one run LANE_NOISE_CAP_WAVE_LANE=off."
reset; printf '%s\t%s\n' "$DAY" 1 > "$H/state/lane-noise-wave-lane.count"
lc lane_noise_cap_tripped wave-lane && bad "W2: 1 against 3 must not trip" || ok
[ "$(alines)" = 0 ] && [ "$(nbeats)" = 0 ] && ok || bad "W2: under budget must be silent (lines $(alines), beats $(nbeats))"

# W3. gh_repo_invisible_alert keeps its fleet_alert beat and gains the alert one
echo "--- W3 gh_repo_invisible_alert"
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
reset
( export PATH="$T/fakebin:$PATH" HARNESS="$H"; unset GH_TOKEN
  . "$H/bin/lib/gh-repo-token.sh"; gh_repo_invisible_alert merge-sweep o/blind "3 approved PRs skipped" )
check_line W3 "[merge-sweep] repo o/blind is INVISIBLE to the default gh token (no admin token on this box (env/github-admin.env absent)) — 3 approved PRs skipped. This is the 2026-09-12 project-5 shape: an empty PR list that nobody logged. Tried: tried the App installation token: not armed on this box; the default PAT: blind; the admin PAT: absent on this box (env/github-admin.env)."
n=$(jq -c 'select(.kind=="fleet_alert" and .akey=="repoinvisible:merge-sweep:o/blind")' "$T/beats.txt" 2>/dev/null | grep -c .)
[ "$n" = 1 ] && ok || bad "W3: the existing fleet_alert beat must still fire once, got $n: $(cat "$T/beats.txt")"

# W4. the REPO lib with HARNESS on a tree that has no bin/alert-line.sh
echo "--- W4 the library's own helper path"
H2="$T/h2"; mkdir -p "$H2/bin" "$H2/logs" "$H2/flags" "$H2/state"
printf '%s\n' "$HDR" > "$H2/logs/cost.csv"
( export HARNESS="$H2" COST="$H2/logs/cost.csv" LANE_CAPS_CONF="$T/caps.conf" \
         MODEL_PRICES="$T/prices.json" LANE_CAPS_DAY="$DAY"
  r="${DAY}T04:00:00Z,box,wave-lane,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0,9.00,api,fp,acct,sess,transcript,,,,,"
  n=$(awk -F, '{print NF}' <<<"$r"); while [ "$n" -lt "$NCOL" ]; do r="$r,"; n=$((n+1)); done
  printf '%s\n' "$r" >> "$H2/logs/cost.csv"
  . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1
  . "$DIR/bin/lib/lane-caps.sh" || exit 9
  lane_day_cap_tripped wave-lane ) && ok || bad "W4: the repo lib must trip over the cap"
[ -x "$H2/bin/alert-line.sh" ] && bad "W4: fixture error, H2 must not carry the helper" || ok
grep -qE "${STAMP_RE}\[wave-lane\] DAILY SPEND CAP: \\\$9.00 spent today" "$H2/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "W4: the line must land in \$HARNESS/logs/ALERTS.log via the library's own helper path: $(cat "$H2/logs/ALERTS.log" 2>&1)"
ls "$H2"/flags/alerted-lane-usd-wave-lane-* >/dev/null 2>&1 && ok || bad "W4: the day flag must be touched"
[ -e "$DIR/logs/ALERTS.log" ] && grep -q 'wave-lane' "$DIR/logs/ALERTS.log" && bad "W4: the helper wrote into the checkout, not \$HARNESS" || ok

# W6. a plain script: bin/stale-owed-tickets.sh's orphaned-build scan, run whole
echo "--- W6 stale-owed-tickets.sh ORPHANED BUILD"
reset
cp "$DIR/bin/stale-owed-tickets.sh" "$H/bin/"
# The real verdict reader with the registry's window, so a scratch tree with no
# catalog does not add its own "unresolvable" line to ALERTS.log.
vpf_install "$H" || bad "W6: tests/lib/verdict-fixture.sh could not install the verdict reader"
# Sections 1-3 see one project with no token and skip it; only section 4 runs.
printf '#!/bin/sh\necho p\n' > "$H/bin/fleet-projects-or-alert.sh"
printf '#!/bin/sh\necho -\n' > "$H/bin/fleet-conf.sh"
printf '#!/bin/sh\nexit 1\n' > "$H/bin/internal-token-for.sh"
printf '#!/bin/sh\necho local\n' > "$H/bin/box-for.sh"
chmod +x "$H/bin/"*.sh
BD="$H/builds/p-P-1-202609010000"; mkdir -p "$BD"
echo "REVIEW_BLOCKED" > "$BD/RESULT"; echo "no verdict here" > "$BD/review.md"
touch -d '3 hours ago' "$BD/RESULT"
HARNESS="$H" bash "$H/bin/stale-owed-tickets.sh" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "W6: stale-owed-tickets.sh exited $rc"
check_line W6 "[stale-sweep] ORPHANED BUILD: p-P-1-202609010000 — RESULT=REVIEW_BLOCKED but review.md has no VERDICT (review died mid-run). Hub: re-run the review stage or close it out; nothing else will."
[ -f "$BD/.stale-flagged" ] && ok || bad "W6: the build dir must still be stamped .stale-flagged after the line"

echo "alert-line-wave-lib: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
