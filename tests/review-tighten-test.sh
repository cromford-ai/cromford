#!/bin/bash
# tests/review-tighten-test.sh — the outcome steering rule, driven for real.
#
# THE PROPERTIES UNDER TEST, in the order they matter:
#
#  1. IT ONLY EVER TIGHTENS. There is no input to bin/review-tighten.sh that
#     makes it merge something, widen a budget, or grant autonomy. A detector
#     that could loosen a gate on its own arithmetic is a second, unreviewed
#     merge path, and this suite asserts the absence with a recording `gh` stub
#     that must never be touched.
#  2. IT NEVER ACTS BLIND. No merge ledger means no denominator, which means no
#     measurement — and specifically it must not CLEAR a flag it cannot justify
#     clearing. Missing evidence is not good news.
#  3. THE STARVATION GUARD HOLDS. One revert out of one merge is a 100% rate and
#     means nothing. Without min_merges the first bad outcome on a quiet repo
#     parks its whole backlog.
#  4. THE THRESHOLDS ARE THE DATABASE'S. A row in review_gate_thresholds
#     overrides the code fallback, per field, and the fallback is only reached
#     when the table has nothing to say.
#  5. HYSTERESIS. Tighten and clear are two different numbers, so a repo does
#     not flap in and out of the park as one revert ages out of the window.
#  6. THE FLAG ACTUALLY STOPS A MERGE. bin/merge-sweep.sh must SKIP a flagged
#     repo's PR without ledgering it (a ledger row would mark it handled
#     forever) and without asking gh to merge anything — and must still merge
#     the identical PR when the flag is absent, or this test proves nothing.
#
# Driven, not grepped: it runs the REAL scripts against a stubbed curl and reads
# back the request bodies and the flag files. A grep would pass on a version
# that computes the rate and forgets to write the flag.
# Run from anywhere: tests/review-tighten-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/bin" "$T/env" "$T/locks" "$T/fakebin" "$T/resp" "$T/builds"
cp "$DIR/bin/jobs-client.sh"    "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/review-tighten.sh" "$T/bin/review-tighten.sh"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
cp "$DIR/bin/merge-sweep.sh"    "$T/bin/merge-sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
echo "HARNESS_SECRET=test-secret" > "$T/env/global.env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Stub curl: answers per route from files under resp/, records every request so
# bodies can be read back, and can be told the worker is down. No network.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in down) exit 7 ;; esac
case "$METHOD $URL" in
  "GET "*"/api/ledger"*)                 cat "$RESP/ledger.json"; echo; echo 200 ;;
  "GET "*"/api/metrics/outcomes"*)       cat "$RESP/outcomes.json"; echo; echo 200 ;;
  "GET "*"/api/review-gate"*)            cat "$RESP/gate.json"; echo; echo 200 ;;
  "PUT "*"/api/review-gate"*)            echo '{"gate":{}}'; echo 200 ;;
  "GET "*"/api/flags/"*)                 echo '{}'; echo 404 ;;
  "PUT "*"/api/flags"*)                  echo '{"flag":{"updated_at":"2026-08-29T00:00:00Z"}}'; echo 200 ;;
  *)                                     echo '{}'; echo 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# A `gh` that records any invocation at all. Nothing in this lane may reach it.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_SINK:-/dev/null}"
exit 1
EOF
chmod +x "$T/fakebin/gh"

D_AGO() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }
PR() { printf 'https://github.com/%s/pull/%s' "$1" "$2"; }

# --- fixtures ----------------------------------------------------------------
# o/hot   10 merges, 3 of them reverted or reopened  -> 30%
# o/calm  10 merges, none                            -> 0%
# o/quiet  2 merges, both reverted                   -> 100%, but under min_merges
# o/mid   10 merges, 15% (between clear and tighten) -> hold whatever it is
write_ledger() {
  {
    printf '{"ledgers":['
    local first=1 repo n
    for repo in o/hot o/calm o/mid; do
      for n in $(seq 1 10); do
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"key":"%s","status":"merged","job_id":"build-%s-%s","updated_at":"%s"}' \
          "$(PR "$repo" "$n")" "${repo#*/}" "$n" "$(D_AGO 3)"
      done
    done
    for n in 1 2; do
      printf ',{"key":"%s","status":"merged","job_id":"build-quiet-%s","updated_at":"%s"}' \
        "$(PR o/quiet "$n")" "$n" "$(D_AGO 3)"
    done
    # Rows that must NOT reach the denominator: parked (never landed) and a
    # merge outside the window.
    printf ',{"key":"%s","status":"parked","job_id":"j","updated_at":"%s"}' "$(PR o/calm 77)" "$(D_AGO 1)"
    printf ',{"key":"%s","status":"merged","job_id":"j","updated_at":"%s"}' "$(PR o/calm 88)" "$(D_AGO 90)"
    printf ']}'
  } > "$T/resp/ledger.json"
}
write_outcomes() { # write_outcomes <hot-bad-count>
  local hot="${1:-3}" n first=1
  {
    printf '{"outcomes":['
    for n in $(seq 1 "$hot"); do
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"repo":"o/hot","pr":"%s","outcome":"reverted","day":"%s"}' "$(PR o/hot "$n")" "$(D_AGO 2 | cut -c1-10)"
    done
    # The same PR twice: one merge that did not hold, never two.
    [ "$hot" -ge 1 ] && printf ',{"repo":"o/hot","pr":"%s","outcome":"reopened","day":"%s"}' "$(PR o/hot 1)" "$(D_AGO 2 | cut -c1-10)"
    # main-red is REPORTED and never in the rate.
    printf ',{"repo":"o/calm","pr":"%s","outcome":"merged_then_red","day":"%s"}' "$(PR o/calm 1)" "$(D_AGO 2 | cut -c1-10)"
    printf ',{"repo":"o/quiet","pr":"%s","outcome":"reverted","day":"%s"}' "$(PR o/quiet 1)" "$(D_AGO 2 | cut -c1-10)"
    printf ',{"repo":"o/quiet","pr":"%s","outcome":"reverted","day":"%s"}' "$(PR o/quiet 2)" "$(D_AGO 2 | cut -c1-10)"
    printf ',{"repo":"o/mid","pr":"%s","outcome":"reverted","day":"%s"}' "$(PR o/mid 1)" "$(D_AGO 2 | cut -c1-10)"
    printf ',{"repo":"o/mid","pr":"%s","outcome":"reopened","day":"%s"}' "$(PR o/mid 2)" "$(D_AGO 2 | cut -c1-10)"
    printf ']}'
  } > "$T/resp/outcomes.json"
}
write_gate() { printf '{"gates":[],"thresholds":%s}' "${1:-[]}" > "$T/resp/gate.json"; }

run_detector() {
  rm -f "$T/req.log" "$T/gh.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
           REQ_SINK="$T/req.log" GH_SINK="$T/gh.log" RESP="$T/resp" BOX_NAME=hub ${EXTRA_ENV:-}
    bash "$T/bin/review-tighten.sh" >/dev/null 2>&1 )
}
flag_of() { printf '%s/flags/review-tighten-%s' "$T" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')"; }
gate_put_for() { grep -F "\"repo\":\"$1\"" "$T/req.log" 2>/dev/null | grep -F '/api/review-gate ' | tail -1; }
reset_state() { rm -f "$T"/flags/review-tighten-* "$T"/logs/ALERTS.log 2>/dev/null; }

write_ledger; write_outcomes 3; write_gate

# --- 1. the fallback thresholds fire, and only where they should -------------
reset_state
run_detector

[ -f "$(flag_of o/hot)" ] && ok || bad "o/hot at 30% did not park under the 20% fallback threshold"
[ -f "$(flag_of o/calm)" ] && bad "o/calm at 0% was parked" || ok
# 100% over two merges is the shape that would park a whole quiet repo on one
# bad day. min_merges is the only thing standing between it and starvation.
[ -f "$(flag_of o/quiet)" ] && bad "o/quiet parked on a 2-merge sample (min_merges did not hold)" || ok
# 2 of 10 = 20%... which IS the tighten threshold. o/mid is the boundary case:
# >= is the documented comparison, so it parks.
[ -f "$(flag_of o/mid)" ] && ok || bad "o/mid at exactly the threshold did not park (>= is the documented comparison)"

# --- 2. the numbers it recorded ---------------------------------------------
HOT=$(gate_put_for o/hot)
grep -q '"merges":"10"' <<<"$HOT" && ok || bad "o/hot denominator was not 10: $HOT"
# Four findings on three PRs (#1 is both reverted and reopened) is THREE merges
# that did not hold. Counting rows would report 4/10 and, on a smaller repo,
# a rate above 100%.
grep -q '"bad":"3"' <<<"$HOT" && ok || bad "o/hot numerator counted finding rows, not distinct PRs: $HOT"
grep -q '"rate":"0.3000"' <<<"$HOT" && ok || bad "o/hot rate was not 0.30: $HOT"
grep -q '"decision":"tighten"' <<<"$HOT" && ok || bad "o/hot decision was not tighten: $HOT"
CALM=$(gate_put_for o/calm)
grep -q '"merges":"10"' <<<"$CALM" && ok || bad "a parked row or an out-of-window merge reached o/calm's denominator: $CALM"
grep -q '"bad":"0"' <<<"$CALM" && ok || bad "main-red leaked into the revert/reopen numerator: $CALM"
QUIET=$(gate_put_for o/quiet)
grep -q '"decision":"insufficient"' <<<"$QUIET" && ok || bad "o/quiet was not recorded as insufficient evidence: $QUIET"
# A measurement is written for EVERY repo, including the ones that changed
# nothing — otherwise nobody can tell "measured and fine" from "never measured".
grep -q '"repo":"o/calm"' "$T/req.log" && ok || bad "no review_gate row was written for a healthy repo"

# --- 3. one ALERTS line per transition, naming the escape hatch --------------
N=$(grep -c 'review-tighten. o/hot TIGHTENED' "$T/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] && ok || bad "expected exactly one ALERTS line for o/hot, got $N"
grep -q 'review-tighten-set o/hot off' "$T/logs/ALERTS.log" && ok \
  || bad "the ALERTS line does not tell the operator how to release the gate by hand"
grep -q 'PARK instead of auto-merging' "$T/logs/ALERTS.log" && ok \
  || bad "the ALERTS line does not say what actually changed"

# A SECOND run at the same rate must not re-alert: the flag is already set and
# the state has not transitioned. A lane that pages daily gets skimmed.
: > "$T/logs/ALERTS.log"
run_detector
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "a re-run at an unchanged rate wrote another alert: $(cat "$T/logs/ALERTS.log")"
[ -f "$(flag_of o/hot)" ] && ok || bad "the second run released a flag it should have held"

# --- 4. the clear side, at the boundary --------------------------------------
# o/hot drops to one bad PR in ten. (#1 carries both a revert and a reopen, so
# it is still ONE merge that did not hold.)
write_outcomes 1
: > "$T/logs/ALERTS.log"
run_detector
HOT=$(gate_put_for o/hot)
grep -q '"rate":"0.1000"' <<<"$HOT" && ok || bad "expected a 10% rate after the drop: $HOT"
# 10% is exactly the clear threshold and <= is the documented comparison, so
# this one DOES clear — and says so once.
[ -f "$(flag_of o/hot)" ] && bad "o/hot did not release at exactly the clear threshold" || ok
grep -q 'o/hot RELEASED' "$T/logs/ALERTS.log" && ok || bad "the release was not announced"

# --- 4b. hysteresis: between the two thresholds, HOLD whatever you were ------
# The band exists so a gate does not flap as one revert ages out of the window.
# The SAME 10% rate must leave a parked repo parked and an unparked repo free —
# which is only possible if the decision reads the current state rather than
# recomputing a single threshold.
reset_state
write_gate '[{"scope":"*","window_days":14,"min_merges":5,"tighten_rate":0.30,"clear_rate":0.05}]'
touch "$(flag_of o/hot)"          # already parked from an earlier, worse week
: > "$T/logs/ALERTS.log"
run_detector
grep -q '"decision":"hold"' <<<"$(gate_put_for o/hot)" && ok || bad "a 10% rate between 5% and 30% was not recorded as a hold"
[ -f "$(flag_of o/hot)" ] && ok || bad "the hold band RELEASED a parked repo — the gate will flap"
[ -f "$(flag_of o/mid)" ] && bad "the hold band PARKED a repo that was not parked" || ok
[ ! -s "$T/logs/ALERTS.log" ] && ok || bad "a hold announced itself as a transition"

# --- 5. thresholds come from the DATABASE, not the constants ----------------
reset_state
write_outcomes 3
write_gate '[{"scope":"*","window_days":14,"min_merges":5,"tighten_rate":0.9,"clear_rate":0.8}]'
run_detector
[ -f "$(flag_of o/hot)" ] && bad "a 30% rate parked against a DB threshold of 90% — the code fallback won" || ok
grep -q '"threshold_scope":"\*"' "$T/req.log" && ok || bad "the run did not record which threshold row it used"

# A repo-scoped row outranks the fleet default for that repo alone.
write_gate '[{"scope":"*","window_days":14,"min_merges":5,"tighten_rate":0.9,"clear_rate":0.8},{"scope":"o/hot","window_days":14,"min_merges":5,"tighten_rate":0.25,"clear_rate":0.1}]'
run_detector
[ -f "$(flag_of o/hot)" ] && ok || bad "the repo-scoped threshold row did not override the fleet default"
[ -f "$(flag_of o/mid)" ] && bad "o/mid parked against the 90% fleet threshold" || ok

# --- 6. it never acts blind --------------------------------------------------
# The flag is set (from the run above). With the worker down there is no merge
# ledger, so there is no denominator — and a flag must NEVER be cleared on
# missing evidence. Absence of data is not good news.
: > "$T/logs/ALERTS.log"
EXTRA_ENV="CURL_MODE=down" run_detector
[ -f "$(flag_of o/hot)" ] && ok || bad "a worker outage CLEARED a review-tighten flag"
# jobs-client writes its own once-a-day "harness-jobs unreachable" line and
# that is correct. What must NOT appear is a gate transition: an outage may
# never announce a park or a release, because it measured neither.
grep -q '\[review-tighten\]' "$T/logs/ALERTS.log" \
  && bad "an outage announced a gate transition" || ok
grep -q 'nothing measured' "$T/logs/review-tighten.log" && ok || bad "the outage was not recorded in the run log"

# --- 7. the CSV fallback measures when the ledger read comes back empty ------
reset_state
write_gate '[]'
printf '{"outcomes":[]}' > "$T/resp/outcomes.json"
{
  echo "date,repo,pr,outcome,evidence"
  echo "$(D_AGO 2 | cut -c1-10),o/hot,$(PR o/hot 1),reverted,\"reverted by abc, see #1\""
  echo "$(D_AGO 2 | cut -c1-10),o/hot,$(PR o/hot 2),reverted,e"
  echo "$(D_AGO 2 | cut -c1-10),o/hot,$(PR o/hot 3),reopened,e"
} > "$T/logs/outcome-metrics.csv"
run_detector
[ -f "$(flag_of o/hot)" ] && ok || bad "the logs/outcome-metrics.csv fallback did not produce a measurement"
grep -q 'outcomes_source=csv' "$T/logs/review-tighten.log" && ok || bad "the run did not say which outcome source it used"
rm -f "$T/logs/outcome-metrics.csv"

# --- 8. it never merges, never loosens --------------------------------------
[ ! -s "$T/gh.log" ] && ok || bad "the detector invoked gh: $(cat "$T/gh.log")"
grep -qE '"tightened":"1"' "$T/req.log" && ok || bad "no tighten was ever recorded across the suite"
# The ONLY writes this lane makes are the gate row and the flag. Nothing may
# touch the merge ledger, the jobs table or a pause flag other than its own.
BADW=$(grep -E '^(PUT|POST) ' "$T/req.log" | grep -vE '/api/review-gate|/api/flags' || true)
[ -z "$BADW" ] && ok || bad "the detector wrote somewhere it has no business writing: $BADW"
FLAGW=$(grep -E '^PUT .*/api/flags' "$T/req.log" | grep -v 'review-tighten-' || true)
[ -z "$FLAGW" ] && ok || bad "the detector set a flag that is not its own: $FLAGW"

# --- 8b. the flag namespace cannot swallow the lane's own kill switch --------
# A bare name sanitises to review-tighten-disabled, which IS the kill switch: a
# caller that passed something other than an owner/name slug would silently turn
# the whole detector off for the fleet. Required to have a slash, so it cannot.
NAME=$( . "$T/bin/jobs-client.sh" >/dev/null 2>&1; review_tighten_flag_name "o/hot" )
[ "$NAME" = "review-tighten-o-hot" ] && ok || bad "flag name for o/hot was '$NAME'"
( . "$T/bin/jobs-client.sh" >/dev/null 2>&1; review_tighten_flag_name "disabled" ) >/dev/null 2>&1 \
  && bad "a slugless repo name produced a flag name — it would collide with the kill switch" || ok

# --- 9. the flag actually stops a merge --------------------------------------
# The whole point. A flag nothing reads is a log line with extra steps.
mkdir -p "$T/builds/pool-hot-os-K-1"
echo "PR_CREATED $(PR o/hot 401)" > "$T/builds/pool-hot-os-K-1/RESULT"
echo "VERDICT: APPROVE"           > "$T/builds/pool-hot-os-K-1/review.md"
sweep() {
  rm -f "$T/gh.log" "$T/logs/merge-sweep.log"
  : > "$T/state/merge-sweep-done.txt"
  # CURL_MODE=down on purpose: the flag must hold through a worker outage,
  # which is exactly when a file-backed flag has to be the one that answers.
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" JOBS_URL=https://jobs.invalid \
           CURL_MODE=down GH_SINK="$T/gh.log" RESP="$T/resp" BOX_NAME=hub
    bash "$T/bin/merge-sweep.sh" >/dev/null 2>&1 )
}

# TEST-CHANGE BH-4153: automerge-disabled* are harness_flags rows read DB-first now,
# and with CURL_MODE=down and no cache they are UNKNOWN, which a stop switch reads
# as ON, so the sweep would stand down before it ever reached the review gate.
# Seed the last-good "off" a box holds from before the outage (edge 1: the cache
# answers), so the fleet kill switch is known off and the tighten flag is the
# only thing that can hold this PR.
mkdir -p "$T/state/flags-cache/fleet"
printf '{"on":false,"value":null,"set_at":null,"cleared_at":null,"src":"db","stamp":%s}\n' \
  "$(date -u +%s)" > "$T/state/flags-cache/fleet/automerge-disabled"
touch "$(flag_of o/hot)"
sweep
[ ! -s "$T/gh.log" ] && ok || bad "merge-sweep asked gh about a PR on a PARKED repo: $(cat "$T/gh.log")"
grep -q 'review gate is TIGHTENED' "$T/logs/merge-sweep.log" && ok || bad "the sweep did not say why it held the PR"
# SKIPPED, never ledgered: a ledger row would mark this PR handled forever and
# it would never land once the gate clears.
grep -q "$(PR o/hot 401)" "$T/state/merge-sweep-done.txt" \
  && bad "the sweep ledgered a parked PR — it can never be swept again" || ok

# The positive control. Without this the test above passes on a sweep that was
# broken for some entirely different reason.
rm -f "$(flag_of o/hot)"
sweep
[ -s "$T/gh.log" ] && ok || bad "with no flag the sweep still did nothing — the park assertion above proves nothing"

# --- 10. a `reworked` row (BH-3956) is not a bad outcome ---------------------
# The same three PRs, now carrying only the decomposition metric. Rework is not
# a revert or a reopen, so it must never park a repo's merges. Same CSV
# fallback setup as section 7, which proves that path DOES tighten on reverts.
reset_state
write_gate '[]'
printf '{"outcomes":[]}' > "$T/resp/outcomes.json"
{
  echo "date,repo,pr,outcome,evidence,repairs"
  for n in 1 2 3; do
    echo "$(D_AGO 2 | cut -c1-10),o/hot,$(PR o/hot "$n"),reworked,\"reworked by $(PR o/hot 9), 3d later\",-"
  done
} > "$T/logs/outcome-metrics.csv"
run_detector
[ -f "$(flag_of o/hot)" ] && bad "reworked rows were counted as bad outcomes and tightened o/hot" || ok
tail -1 "$T/logs/review-tighten.log" | grep -q 'outcomes_source=csv' && ok \
  || bad "section 10 never read the CSV, so its no-tighten proves nothing: $(tail -1 "$T/logs/review-tighten.log")"
rm -f "$T/logs/outcome-metrics.csv"

echo "review-tighten: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
