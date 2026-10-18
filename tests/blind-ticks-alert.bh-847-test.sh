#!/bin/bash
# tests/blind-ticks-alert.bh-847-test.sh — N consecutive blind PR lists raise ONE line.
#
# THE SILENCE THIS KILLS (BH-847). A visible repo whose list keeps failing wrote
# one "transient?" line per tick into the lane's own log and nothing else, so a
# lane that was blind for ten hours looked exactly like a lane that hiccuped
# once. The rule: a per-(lane, repo) consecutive-blind counter under $H/state/,
# ONE ALERTS.log line plus one beat at N (default 3, settings row then
# BLIND_TICKS_ALERT then 3), silence after that, and one "recovered" line when a
# list finally succeeds.
#
# THE TWO BRANCHES THAT ALREADY PAGE DO NOT COUNT (review finding 3 on PR #867).
# An invisible repo and an exhausted API bucket each write their own single,
# specific line; counting those ticks too paged a second time for the same cause,
# in vaguer words. Case 9 is that negative. And a NEW streak drops the dedupe
# flag (review finding 2), or a lane with no reset call of its own pages once per
# (lane, repo) for the life of the box — case 10.
# Run from anywhere: tests/blind-ticks-alert.bh-847-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/state" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole suite: every stale-counter fixture is derived from
# it, so the suite cannot pick its own red hour.
NOW=$(date -u +%s); OLD=$((NOW - 10800))

cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
# gh_repo_invisible_alert keeps its day flag through bin/lib/flags.sh (BH-7252):
# install that lib and the jobs client it loads.
( cd "$DIR" && scratch_install_closure bin/lib/flags.sh "$T" && scratch_install_closure bin/jobs-client.sh "$T" ) >/dev/null \
  || bad "setup: could not install bin/lib/flags.sh + bin/jobs-client.sh"
# This scratch has no worker: JOBS_ALERT=0 keeps the client's own "harness-jobs
# unreachable" line out of the ALERTS.log this suite counts.
export JOBS_ALERT=0
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"

# gh shim: o/blind is visible to no token (so the invisible branch runs), every
# other repo is visible, and the API budget has room unless RATE_LIMIT=exhausted
# — the three branches of gh_repo_list_failed are selected by fixture, not by a
# second shim written mid-suite.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
RESET=1757725102
case "$*" in
  "api repos/o/blind -q .id") exit 1 ;;
  api\ repos/*) exit 0 ;;
  "api rate_limit")
    rem=4996; used=4
    [ "${RATE_LIMIT:-full}" = exhausted ] && { rem=0; used=5000; }
    jq -nc --argjson r "$RESET" --argjson rem "$rem" --argjson used "$used" '{resources:{
      core:{limit:5000, remaining:$rem, reset:$r, used:$used},
      graphql:{limit:5000, remaining:4999, reset:$r, used:1},
      search:{limit:30, remaining:30, reset:$r, used:0},
      code_scanning_upload:{limit:1000, remaining:1000, reset:$r, used:0}}}' ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/fakebin/gh"

drive() { # drive <snippet>; the lib is sourced fresh with HARNESS=$T
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" BEAT_SINK="$T/beats.txt" T="$T"; unset GH_TOKEN
    # shellcheck source=/dev/null
    . "${LIB:-$T/bin/lib/gh-repo-token.sh}"; eval "$1" )
}
wipe() {
  : > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
  rm -rf "$T/state/blind-list"
  rm -f "$T"/flags/alerted-blindlist-* "$T"/flags/alerted-repo-invisible-* "$T"/flags/alerted-gh-ratelimit-*
  rm -f "$T"/logs/merge-conductor.log "$T"/logs/pipeline-health.log
}
alerts() { grep -c . "$T/logs/ALERTS.log" 2>/dev/null; true; }
# TEST-CHANGE: BH-2365 — the ALERTS line now also beats kind:"alert" through bin/alert-line.sh,
# so beats() counts the fleet_alert this suite pins and abeats() the alert-line one.
beats() { grep -c '"kind":"fleet_alert"' "$T/beats.txt" 2>/dev/null; true; }
abeats() { grep -c '"kind":"alert"' "$T/beats.txt" 2>/dev/null; true; }
fail3() { drive 'for i in 1 2 3; do gh_repo_list_failed merge-conductor o/r "tick $i skipped"; done'; }

# 1. the counter file exists after the FIRST blind tick, and the first tick
#    still writes the existing transient line and nothing louder.
wipe
drive 'gh_repo_list_failed merge-conductor o/r "tick 1 skipped"'
[ -s "$T/state/blind-list/merge-conductor-o_r" ] && ok || bad "1: no counter file under state/blind-list: $(ls "$T/state/blind-list" 2>&1)"
[ "$(alerts)" = 0 ] && ok || bad "1: one blind tick must not page: $(cat "$T/logs/ALERTS.log")"
[ "$(grep -c "gh pr list failed for o/r (repo is visible; transient?)" "$T/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "1: the existing transient line must still be written: $(cat "$T/logs/merge-conductor.log" 2>&1)"

# 2. at N=3 exactly ONE ALERTS line and ONE beat, naming how long and what it blocks.
wipe; fail3
[ "$(alerts)" = 1 ] && ok || bad "2: expected exactly one ALERTS line at 3 ticks, got $(alerts): $(cat "$T/logs/ALERTS.log")"
grep -qE "\[merge-conductor\] merge-conductor has been blind on o/r for 3 consecutive ticks since [0-9]{2}:[0-9]{2}Z" "$T/logs/ALERTS.log" \
  && ok || bad "2: alert wording/since: $(cat "$T/logs/ALERTS.log")"
grep -q "no PR on o/r can be enqueued" "$T/logs/ALERTS.log" && ok || bad "2: the alert must say what it blocks: $(cat "$T/logs/ALERTS.log")"
grep -q "tick 3 skipped" "$T/logs/ALERTS.log" && ok || bad "2: the alert must carry the last skip: $(cat "$T/logs/ALERTS.log")"
[ "$(beats)" = 1 ] && ok || bad "2: expected one beat, got $(beats)"
[ "$(abeats)" = 1 ] && ok || bad "2: expected one kind:\"alert\" beat, got $(abeats)"  # TEST-CHANGE: BH-2365
grep -q '"akey":"blindlist:merge-conductor:o/r"' "$T/beats.txt" && grep -q '"kind":"fleet_alert"' "$T/beats.txt" \
  && ok || bad "2: beat akey/kind: $(cat "$T/beats.txt")"
[ -f "$T/flags/alerted-blindlist-merge-conductor-o_r" ] && ok || bad "2: dedupe flag missing"
grep -rqE 'admintok' "$T/logs/ALERTS.log" "$T/beats.txt" && bad "2: a token VALUE leaked into the alert" || ok

# 3. further blind ticks stay quiet.
drive 'gh_repo_list_failed merge-conductor o/r "tick 4 skipped"'
[ "$(alerts)" = 1 ] && ok || bad "3: the 4th blind tick added an ALERTS line: $(cat "$T/logs/ALERTS.log")"
[ "$(beats)" = 1 ] && ok || bad "3: the 4th blind tick added a beat: $(cat "$T/beats.txt")"
[ "$(abeats)" = 1 ] && ok || bad "3: expected one kind:\"alert\" beat, got $(abeats)"  # TEST-CHANGE: BH-2365

# 4. the first successful list writes ONE recovered line and clears flag+counter;
#    a second success is silent.
drive 'gh_repo_list_ok merge-conductor o/r'
[ "$(grep -c "list recovered for o/r after 4 blind ticks" "$T/logs/merge-conductor.log")" = 1 ] \
  && ok || bad "4: recovered line: $(cat "$T/logs/merge-conductor.log")"
[ ! -f "$T/state/blind-list/merge-conductor-o_r" ] && ok || bad "4: counter file survived recovery"
[ ! -f "$T/flags/alerted-blindlist-merge-conductor-o_r" ] && ok || bad "4: dedupe flag survived recovery"
BEFORE=$(wc -l < "$T/logs/merge-conductor.log")
drive 'gh_repo_list_ok merge-conductor o/r'
[ "$(wc -l < "$T/logs/merge-conductor.log")" = "$BEFORE" ] && ok || bad "4: a second gh_repo_list_ok wrote a line"
# ...and after recovery the lane can page again (the flag is not per-day).
wipe; fail3
[ "$(alerts)" = 1 ] && ok || bad "4: a lane that recovered and went blind again must page again"

# 5. BLIND_TICKS_ALERT moves the threshold; a junk value falls back to 3 and says so.
wipe
drive 'BLIND_TICKS_ALERT=2 gh_repo_list_failed merge-conductor o/r "a"; BLIND_TICKS_ALERT=2 gh_repo_list_failed merge-conductor o/r "b"'
[ "$(alerts)" = 1 ] && ok || bad "5: BLIND_TICKS_ALERT=2 should page on the 2nd tick: $(cat "$T/logs/ALERTS.log")"
grep -q "for 2 consecutive ticks" "$T/logs/ALERTS.log" && ok || bad "5: alert should name N=2: $(cat "$T/logs/ALERTS.log")"
wipe
drive 'for i in 1 2; do BLIND_TICKS_ALERT=abc gh_repo_list_failed merge-conductor o/r "x"; done'
[ "$(alerts)" = 0 ] && ok || bad "5: a junk threshold must not page at 2: $(cat "$T/logs/ALERTS.log")"
grep -q "BLIND_TICKS_ALERT='abc' is not a tick count — using 3" "$T/logs/merge-conductor.log" \
  && ok || bad "5: a junk threshold must be logged, not silently clamped: $(cat "$T/logs/merge-conductor.log")"
drive 'BLIND_TICKS_ALERT=abc gh_repo_list_failed merge-conductor o/r "x"'
[ "$(alerts)" = 1 ] && ok || bad "5: junk threshold should still page at the default 3: $(cat "$T/logs/ALERTS.log")"

# 6. two repos on one lane, and two lanes on one repo, count separately.
wipe
drive 'gh_repo_list_failed merge-conductor o/a "x"; gh_repo_list_failed merge-conductor o/a "x"; gh_repo_list_failed merge-conductor o/b "x"'
[ "$(alerts)" = 0 ] && ok || bad "6: 2+1 across two repos must not page: $(cat "$T/logs/ALERTS.log")"
drive 'gh_repo_list_failed pipeline-health o/a "x"; gh_repo_list_failed pipeline-health o/a "x"'
[ "$(alerts)" = 0 ] && ok || bad "6: a second lane must have its own counter: $(cat "$T/logs/ALERTS.log")"
drive 'gh_repo_list_failed merge-conductor o/a "x"'
[ "$(alerts)" = 1 ] && ok || bad "6: the third tick on o/a should page: $(cat "$T/logs/ALERTS.log")"
grep -q "blind on o/a" "$T/logs/ALERTS.log" && ok || bad "6: the alert should name o/a: $(cat "$T/logs/ALERTS.log")"

# 7. "consecutive" has a window: a failure long after the last one restarts at 1.
wipe
mkdir -p "$T/state/blind-list"
printf '2 %s %s\n' "$OLD" "$OLD" > "$T/state/blind-list/merge-conductor-o_r"
drive 'gh_repo_list_failed merge-conductor o/r "x"'
[ "$(alerts)" = 0 ] && ok || bad "7: a stale counter must not page on the next failure: $(cat "$T/logs/ALERTS.log")"
[ "$(awk '{print $1}' "$T/state/blind-list/merge-conductor-o_r")" = 1 ] && ok || bad "7: the counter should restart at 1, got $(cat "$T/state/blind-list/merge-conductor-o_r")"

# 8. a corrupt counter file is rewritten, never read as a number.
wipe
mkdir -p "$T/state/blind-list"; printf 'garbage\n' > "$T/state/blind-list/merge-conductor-o_r"
drive 'gh_repo_list_failed merge-conductor o/r "x"'
[ "$(awk '{print $1}' "$T/state/blind-list/merge-conductor-o_r")" = 1 ] && ok || bad "8: corrupt counter should reset to 1, got $(cat "$T/state/blind-list/merge-conductor-o_r")"
[ "$(alerts)" = 0 ] && ok || bad "8: a corrupt counter must not page"

# 9. review finding 3: the branches that already page keep their ONE page and
#    never touch the counter. Two pages for one cause is the opposite of the aim,
#    and "rate-limited or unreachable" is vaguer than the line already written.
wipe
drive 'for i in 1 2 3; do gh_repo_list_failed merge-conductor o/blind "3 approved PRs skipped"; done'
[ "$(alerts)" = 1 ] && ok || bad "9: an invisible repo must page exactly once, got $(alerts): $(cat "$T/logs/ALERTS.log")"
grep -q "repo o/blind is INVISIBLE to the default gh token" "$T/logs/ALERTS.log" && ok || bad "9: invisible wording changed: $(cat "$T/logs/ALERTS.log")"
[ ! -e "$T/state/blind-list/merge-conductor-o_blind" ] && ok || bad "9: an invisible-repo tick must not create a counter: $(ls "$T/state/blind-list" 2>&1)"
wipe
drive 'for i in 1 2 3; do RATE_LIMIT=exhausted gh_repo_list_failed merge-conductor o/r "tick $i skipped"; done'
[ "$(alerts)" = 1 ] && ok || bad "9: an exhausted bucket must page exactly once, got $(alerts): $(cat "$T/logs/ALERTS.log")"
grep -q "GitHub API rate-limited" "$T/logs/ALERTS.log" && ok || bad "9: exhausted wording changed: $(cat "$T/logs/ALERTS.log")"
[ ! -e "$T/state/blind-list/merge-conductor-o_r" ] && ok || bad "9: an exhausted tick must not create a counter: $(ls "$T/state/blind-list" 2>&1)"
! grep -q "transient?" "$T/logs/merge-conductor.log" 2>/dev/null && ok || bad "9: exhausted must not write the transient line: $(cat "$T/logs/merge-conductor.log")"

# 10. review finding 2: a NEW streak drops the dedupe flag. pipeline-health,
#     pr-owner-sweep and jobs-watchdog never call gh_repo_list_ok, so a flag that
#     outlives its counter would make every later outage on that (lane, repo)
#     silent for the life of the box.
wipe
mkdir -p "$T/state/blind-list"
printf '2 %s %s\n' "$OLD" "$OLD" > "$T/state/blind-list/pipeline-health-o_r"
touch "$T/flags/alerted-blindlist-pipeline-health-o_r"
drive 'for i in 1 2 3; do gh_repo_list_failed pipeline-health o/r "tick $i skipped"; done'
[ "$(alerts)" = 1 ] && ok || bad "10: a stale counter + stale flag must page again, got $(alerts): $(cat "$T/logs/ALERTS.log")"
[ "$(beats)" = 1 ] && ok || bad "10: expected one beat on the new streak, got $(beats): $(cat "$T/beats.txt")"
grep -q "pipeline-health has been blind on o/r for 3 consecutive ticks" "$T/logs/ALERTS.log" \
  && ok || bad "10: the new page should count from 1: $(cat "$T/logs/ALERTS.log")"

# 11. the threshold is DB-driven: a settings row beats the env fallback, which
#     beats the code constant (the repo's gh_budget_min_remaining shape).
wipe
drive 'setting_get() { [ "$1" = blind_ticks_alert ] && echo 2; }
  export BLIND_TICKS_ALERT=5
  gh_repo_list_failed merge-conductor o/r "a"; gh_repo_list_failed merge-conductor o/r "b"'
[ "$(alerts)" = 1 ] && ok || bad "11: a settings row of 2 should page on the 2nd tick with BLIND_TICKS_ALERT=5: $(cat "$T/logs/ALERTS.log")"
grep -q "for 2 consecutive ticks" "$T/logs/ALERTS.log" && ok || bad "11: the DB rung should win over the env rung: $(cat "$T/logs/ALERTS.log")"
wipe
drive 'setting_get() { [ "$1" = blind_ticks_alert ] && echo nope; }
  gh_repo_list_failed merge-conductor o/r "a"'
grep -q "unusable setting blind_ticks_alert='nope' — falling back" "$T/logs/merge-conductor.log" \
  && ok || bad "11: an unusable settings value must say so: $(cat "$T/logs/merge-conductor.log")"

# 12. the conductor closes the streak after a successful list. This assertion
#     pins SOURCE, so it pins the ABSENT case too (D3): the same guard, run
#     against a copy with the call deleted, must answer 0 — otherwise a grep that
#     always matches would "prove" a call that was never wired.
mc_hits() { sed -n '/INQ_IN_LIST" = 0 \]/,/read into an array FIRST/p' "$1" | grep -c 'gh_repo_list_ok merge-conductor "\$SLUG"'; }
[ "$(mc_hits "$DIR/bin/merge-conductor.sh")" = 1 ] \
  && ok || bad "12: the conductor's open-list block must reset the streak exactly once, got $(mc_hits "$DIR/bin/merge-conductor.sh")"
sed '/gh_repo_list_ok merge-conductor/d' "$DIR/bin/merge-conductor.sh" > "$T/mc-mutated.sh"
[ "$(mc_hits "$T/mc-mutated.sh")" = 0 ] \
  && ok || bad "12: the guard does not fail when the call is absent — it proves nothing"

# mutation — remove the counter write and three blind ticks page nothing.
cp "$DIR/bin/lib/gh-repo-token.sh" "$T/gh-repo-token-mutated.sh"
sed -i '/BLIND-COUNTER-WRITE/d' "$T/gh-repo-token-mutated.sh"
wipe
LIB="$T/gh-repo-token-mutated.sh" drive 'for i in 1 2 3; do gh_repo_list_failed merge-conductor o/r "x"; done' >/dev/null 2>&1
[ "$(alerts)" = 0 ] && ok || bad "mutation: the counter write is not load-bearing (still paged): $(cat "$T/logs/ALERTS.log")"

echo "blind-ticks-alert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
