#!/bin/bash
# tests/autohalt-boundary.bh-5526-test.sh — the cost autohalt holds NEW builds
# at the ticket boundary and never stops work already in progress (BH-5526,
# slice C1).
#
# The breaker (bin/pipeline-health.sh `cost budget`, and bin/cost-local-brake.sh
# on the owning box during a worker outage) used to write flags/paused-<p>, the
# human pause. merge-queue, review-prs, rb/pr.sh's tier-1 merge,
# migration-autopilot and run-triage all read that flag, so a trip left tickets
# built but not merged, merged but not migrated, finished but not closed out.
# It now writes its own flag, spend-hold-<p>, and only the build launch gate
# (bin/lib/rb/gates.sh `budget launch gate`) reads it.
#
#   A1  the verbatim cost budget block, project-9 at $154.80/PR against a $20
#       budget: flags/spend-hold-project-9 and its row (reason "(cost
#       autohalt)"), no flags/paused-project-9; the zero-merge breaker the same
#       with "(zero-merge breaker)"
#   A2  on the tree A1 leaves, the real pause checks of merge-queue,
#       migration-autopilot and run-triage do not stand down
#   A3  the costhalt / costzeromerge pages say NEW BUILDS HELD, carry the rate
#       and the lift command, and never say TRIAGE PAUSED
#   A4  the real bin/cost-local-brake.sh in an outage writes spend-hold-<p> and
#       .pending, no paused-<p>; the worker back publishes the spend-hold row; a
#       human pause on the box means no hold
#   A5  the verbatim launch gate block: a held project's fresh build is
#       BUILD_DEFERRED spend-hold with one alert a day and no ADMITTED; an
#       admitted resume, another project's hold, a human pause only, and no hold
#       all pass; a worker outage, or no jobs client at all, answers from the file
#   A6  the breaker writes no hold for a human-paused project, an already-held
#       project, with the kill switch on, or inside the re-arm window
#   A7  pool_lane_failure reads the hold deferral as the lane's condition
#   N   the node suite console-ui/tests/cost-breaker.bh-5526.test.js (the
#       console COST BREAKER card lists hold rows)
#
# Assertions are on artifacts only: flag files, the PUT bodies the worker got,
# page lines, RESULT, pipeline.log and ALERTS.log.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/autohalt-boundary.bh-5526-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq python3 awk flock; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>
FAKE="$T/fakebin"; mkdir -p "$FAKE"

# --- curl: the jobs worker. CURL_MODE: up (an inactive, old row for every flag)
# | down (transport failure). PUT /api/flags answers 200; llm-spend answers $0.
cat > "$FAKE/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; case "$BODY" in @*) BODY=$(cat "${BODY#@}");; esac; shift 2;;
    *) shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$T/req.log"
[ "${CURL_MODE:-up}" = down ] && exit 7
case "$METHOD $URL" in
  # TEST-CHANGE (BH-4153 on BH-5526): the row names the flag asked for, as the
  # real worker does. A ported name (paused-*, automerge-disabled*) is read
  # through _flag_norm, which refuses a row for another name as unreadable.
  "GET "*/api/flags/*) n="${URL##*/}"; n="${n%%\?*}"
                       printf '{"flag":{"name":"%s","active":0,"updated_at":"2020-01-01T00:00:00Z"}}\n200\n' "$n" ;;
  "PUT "*/api/flags)   printf '{"flag":{"updated_at":"2020-01-01T00:00:02Z"}}\n200\n' ;;
  "GET "*/api/metrics/llm-spend\?*) printf '{"usd":0,"calls":0,"refused":0,"settled":0}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
cat > "$FAKE/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.gh"
case "$*" in
  *merged:\>=*T*) echo "{\"total_count\":${GH_M24:-0}}" ;;
  *)              echo "{\"total_count\":${GH_M7:-0}}" ;;
esac
GH
printf '#!/bin/sh\nexit 0\n' > "$FAKE/sleep"
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
unset BOX_NAME CURL_MODE GH_M24 GH_M7 TELEGRAM_BOT_TOKEN COST_AUTOHALT JOBS_URL HARNESS_JOBS_URL LANE_REGISTRY RESUME_BUILD
ENVS=(HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_RETRIES=0)
# put_reason <flag-name> -> the reason of the last PUT of that flag the worker got
put_reason() {
  awk '$1=="PUT" {sub(/^PUT [^ ]+ /, ""); print}' "$T/req.log" 2>/dev/null \
    | jq -r --arg n "$1" 'select(.name == $n and .active == 1) | .reason' 2>/dev/null | tail -1
}

# =============================================================================
# The hub: the cost budget block, verbatim
# =============================================================================
HB="$T/hub"
mkdir -p "$HB/flags" "$HB/logs" "$HB/state/cost"
for f in bin/jobs-client.sh bin/alert-line.sh bin/lib/rb/gates.sh; do
  scratch_install_closure "$f" "$HB" >/dev/null || { echo "cannot install the closure of $f"; exit 1; }
done
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$HB/bin/blk.sh"
[ -s "$HB/bin/blk.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"
# The block sources $(dirname "$0")/lib/cost-budget.sh: a $20/PR budget, min 1.
printf 'cost_budget_for() { echo "20 1"; }\ncost_budget_source() { echo fixture; }\n' > "$HB/bin/lib/cost-budget.sh"
cat > "$HB/fleet.conf" <<'CONF'
project-9 Acme/project-9 - - 1 box-s
zm         Acme/zm      - - 2 box-s
CONF
# project-9: $774 delivery spend for 5 merged PRs in 24h = $154.80/PR, 7.7x.
# zm: $700 over 7d with nothing merged — the zero-merge breaker's 7d rule.
cat > "$HB/state/cost/summary.json" <<'JSON'
{ "projects": {
  "project-9": {"delivery_cost_24h": 774, "merged_prs_24h": 5, "cost_7d": 774, "product_7d": 0,
                 "merged_prs_7d": 5, "merged_prs_status": "ok", "stages_24h": {"execute": 600, "review": 174}},
  "zm":         {"delivery_cost_24h": 50, "merged_prs_24h": 0, "cost_7d": 700, "product_7d": 0,
                 "merged_prs_7d": 0, "merged_prs_status": "ok"}
} }
JSON
hub_reset() {
  rm -f "$HB/flags/"* "$HB/pages.txt" "$HB/alerts.txt" "$T/req.log"; : > "$HB/logs/ALERTS.log"
  scratch_rm "$HB/state/costhalt"
}
drive_hub() { # drive_hub [VAR=VAL ...]  -> $HB/pages.txt, $HB/alerts.txt, $T/req.log
  echo 0 > "$HB/state/costbreaker.stamp"
  ( cd "$T" && export "${ENVS[@]}" H="$HB" HARNESS="$HB" NOW="$NOW" FLEET_CONF="$HB/fleet.conf" "$@"
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$H/alerts.txt"; }
             alert_emit() { printf "%s\n" "$*" >> "$H/logs/ALERTS.log"; }
             page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$H/pages.txt"; }
             . "$H/bin/jobs-client.sh" || exit 1
             . "$1"' _ "$HB/bin/blk.sh" ) >"$T/hub.out" 2>&1
}
pline() { grep "^[0-9]*|$1|" "$HB/pages.txt" 2>/dev/null | head -1; }

# A1 ---------------------------------------------------------------------------
hub_reset; drive_hub
[ -e "$HB/flags/spend-hold-project-9" ] && ok \
  || bad "A1 the rate breaker must write flags/spend-hold-project-9 (flags: $(ls "$HB/flags"); $(cat "$T/hub.out"))"
[ ! -e "$HB/flags/paused-project-9" ] && ok \
  || bad "A1 the rate breaker wrote flags/paused-project-9, the human pause every in-flight lane reads"
R=$(put_reason spend-hold-project-9)
case "$R" in *'(cost autohalt)') ok ;; *) bad "A1 the spend-hold-project-9 row must be PUT with a reason ending '(cost autohalt)' (got '$R'; req.log: $(cat "$T/req.log" 2>/dev/null))" ;; esac
grep -q '154.80/PR over 24h' <<<"$R" && ok || bad "A1 the row reason must carry the rate: '$R'"
[ -z "$(put_reason paused-project-9)" ] && ok || bad "A1 a paused-project-9 row was PUT"
[ -s "$HB/state/costhalt/project-9" ] && ok || bad "A1 a landed hold (CB_HALT=done) stamps state/costhalt/project-9"
[ -e "$HB/flags/spend-hold-zm" ] && [ ! -e "$HB/flags/paused-zm" ] && ok \
  || bad "A1 the zero-merge breaker must hold zm, not pause it (flags: $(ls "$HB/flags"))"
R=$(put_reason spend-hold-zm)
case "$R" in *'(zero-merge breaker)') ok ;; *) bad "A1 the spend-hold-zm reason must end '(zero-merge breaker)' (got '$R')" ;; esac

# A2 — the in-flight lanes, against the tree A1 left -------------------------
# merge-queue: its `pause guards` block, verbatim.
awk '/^# >>> pause guards/{f=1} f{print} /^# <<< pause guards/{exit}' "$DIR/bin/merge-queue.sh" > "$T/mq-guard.sh"
grep -q 'paused-\$PROJECT' "$T/mq-guard.sh" && ok || bad "A2 could not extract merge-queue's pause guards"
# migration-autopilot: its pause line, verbatim.
grep -F '[ -f "$HARNESS/flags/paused-$PROJECT" ] && exit 0' "$DIR/bin/migration-autopilot.sh" > "$T/ma-guard.sh"
[ -s "$T/ma-guard.sh" ] && ok || bad "A2 could not find migration-autopilot's pause line"
# run-triage: its pause check (bin/run-triage.sh), verbatim to the closing fi.
awk 'index($0, "flag_active \"paused-$PROJECT\"") {f=1} f{print} f&&/^fi$/{exit}' "$DIR/bin/run-triage.sh" > "$T/rt-guard.sh"
grep -q 'paused-\$PROJECT' "$T/rt-guard.sh" && ok || bad "A2 could not extract run-triage's pause check"
for g in mq ma rt; do
  : > "$T/lane.log"
  ( export "${ENVS[@]}" HARNESS="$HB" PROJECT=project-9 LOG="$T/lane.log" STAMP=now
    bash -c 'STAMP() { echo now; }; LANE_TICK() { :; }
             . "$HARNESS/bin/jobs-client.sh"; . "$1"; echo RAN_ON' _ "$T/$g-guard.sh" ) > "$T/lane.out" 2>&1
  grep -q RAN_ON "$T/lane.out" && ! grep -qi 'stood down\|skipping' "$T/lane.log" && ok \
    || bad "A2 $g must not stand down under the cost autohalt ($(cat "$T/lane.out" "$T/lane.log"))"
done

# A3 — the pages -------------------------------------------------------------
L=$(pline "costhalt:project-9")
grep -q '\$154.80/PR' <<<"$L" && grep -q 'NEW BUILDS HELD' <<<"$L" \
  && grep -q 'flag_set spend-hold-project-9 off' <<<"$L" && ! grep -q 'TRIAGE PAUSED' <<<"$L" && ok \
  || bad "A3 the costhalt page must carry the rate, NEW BUILDS HELD and the lift command, not TRIAGE PAUSED: $L"
grep -q 'Merges, reviews, migration applies and builds already running continue' <<<"$L" && ok \
  || bad "A3 the costhalt page must say in-flight work continues: $L"
[ "$(grep -c '|costhalt:project-9|' "$HB/pages.txt")" = 1 ] && ok || bad "A3 exactly one costhalt page"
L=$(pline "costzeromerge:zm")
grep -q 'NEW BUILDS HELD' <<<"$L" && grep -q 'flag_set spend-hold-zm off' <<<"$L" && ! grep -q 'TRIAGE PAUSED' <<<"$L" && ok \
  || bad "A3 the zero-merge page must say NEW BUILDS HELD with the lift command: $L"

# A6 — what the breaker must NOT hold ----------------------------------------
hub_reset; echo "operator: holding for a migration" > "$HB/flags/paused-project-9"; drive_hub
[ ! -e "$HB/flags/spend-hold-project-9" ] && [ -z "$(pline costhalt:project-9)" ] \
  && [ ! -e "$HB/state/costhalt/project-9" ] \
  && [ "$(cat "$HB/flags/paused-project-9")" = "operator: holding for a migration" ] && ok \
  || bad "A6 a human-paused project gets no hold, no page, no stamp, and its pause is untouched ($(ls "$HB/flags"); $(pline costhalt:project-9))"
hub_reset; echo "earlier hold" > "$HB/flags/spend-hold-project-9"; echo "earlier hold" > "$HB/flags/spend-hold-zm"; drive_hub
[ -z "$(put_reason spend-hold-project-9)" ] && [ -z "$(pline costhalt:project-9)" ] \
  && [ -z "$(pline costzeromerge:zm)" ] && [ "$(cat "$HB/flags/spend-hold-project-9")" = "earlier hold" ] && ok \
  || bad "A6 an already-held project gets no second hold and no page ($(cat "$HB/pages.txt" 2>/dev/null))"
hub_reset; touch "$HB/flags/cost-autohalt-off"; drive_hub
[ ! -e "$HB/flags/spend-hold-project-9" ] && [ -z "$(pline costhalt:project-9)" ] && ok \
  || bad "A6 the kill switch flags/cost-autohalt-off must stop the hold"
grep -q '|costrate:project-9|' "$HB/alerts.txt" 2>/dev/null && ok || bad "A6 the kill switch must not silence the rate alert"
hub_reset; mkdir -p "$HB/state/costhalt"; echo $(( NOW - 3600 )) > "$HB/state/costhalt/project-9"; drive_hub
[ ! -e "$HB/flags/spend-hold-project-9" ] && ok || bad "A6 inside the re-arm window the breaker must not hold again"

# =============================================================================
# A4 — the owning box during a worker outage: the real bin/cost-local-brake.sh
# =============================================================================
C="$T/box"
mkdir -p "$C/flags" "$C/logs" "$C/state" "$C/env"
for f in bin/cost-local-brake.sh bin/jobs-client.sh bin/fleet-conf.sh bin/box-for.sh bin/box-name.sh \
         bin/lib/hub-box.sh bin/lib/page-critical.sh bin/lib/lane-gate.sh bin/lib/lane-switch.sh bin/lib/deployment.sh; do
  scratch_install_closure "$f" "$C" >/dev/null || { echo "cannot install the closure of $f"; exit 1; }
done
printf 'cost_budget_for() { echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$C/bin/lib/cost-budget.sh"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\n' > "$C/env/global.env"
printf 'x Acme/x - - 1 box-x\n' > "$C/fleet.conf"
echo box-x > "$C/state/box-name"
HDR='ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id'
box_reset() {
  rm -f "$C/flags/"* "$T/req.log" "$T/calls.gh"; : > "$C/logs/ALERTS.log"; scratch_rm "$C/state/cost-local-brake"
  echo "$HDR" > "$C/logs/cost.csv"
  # $300 delivery spend in 24h for 1 merged PR against $10/PR: a rate trip.
  printf '%s,box-x,x,execute,claude,claude-opus-5-5,0,300,10,2000,0,0,300.00,metered,,,,,300.00,X-1,,,,,\n' "$(iso 3600)" >> "$C/logs/cost.csv"
}
run_brake() { ( cd "$T" && env -u NOW HARNESS="$C" "$C/bin/cost-local-brake.sh" ) >"$T/brake.out" 2>&1; }

box_reset; CURL_MODE=down GH_M24=1 GH_M7=1 run_brake
[ -e "$C/flags/spend-hold-x" ] && [ ! -e "$C/flags/paused-x" ] && ok \
  || bad "A4 the box-local brake must hold x, not pause it (flags: $(ls "$C/flags"); $(cat "$T/brake.out"))"
PEND=$(cat "$C/state/cost-local-brake/x.pending" 2>/dev/null)
case "$PEND" in *'(cost autohalt)') ok ;; *) bad "A4 .pending must hold the reason ending '(cost autohalt)' (got '$PEND')" ;; esac
grep -q '"name":"spend-hold-x","active":1' "$T/req.log" 2>/dev/null && ok \
  || bad "A4 the hold must be attempted as the spend-hold-x row ($(cat "$T/req.log" 2>/dev/null))"
grep 'costlocalhalt:x' "$C/logs/ALERTS.log" 2>/dev/null | grep -q 'NEW BUILDS HELD' && ok \
  || bad "A4 the costlocalhalt page must say NEW BUILDS HELD ($(cat "$C/logs/ALERTS.log"))"
grep -q 'TRIAGE PAUSED' <<<"$(grep 'costlocalhalt:x' "$C/logs/ALERTS.log" 2>/dev/null)" \
  && bad "A4 the costlocalhalt page still says TRIAGE PAUSED" || ok
# the worker answers again: the hold is published as the spend-hold-x row
rm -f "$T/req.log"; CURL_MODE=up run_brake
[ "$(put_reason spend-hold-x)" = "$PEND" ] && [ ! -e "$C/state/cost-local-brake/x.pending" ] && [ -e "$C/flags/spend-hold-x" ] && ok \
  || bad "A4 recovery must PUT spend-hold-x with the pending reason and drop .pending ($(cat "$T/req.log" 2>/dev/null))"
[ -z "$(put_reason paused-x)" ] && ok || bad "A4 recovery PUT a paused-x row"
# a human pause on the box: the brake leaves the project alone
box_reset; echo "operator" > "$C/flags/paused-x"; CURL_MODE=down GH_M24=1 GH_M7=1 run_brake
[ ! -e "$C/flags/spend-hold-x" ] && [ "$(cat "$C/flags/paused-x")" = operator ] && ok \
  || bad "A4 a human-paused project gets no hold (flags: $(ls "$C/flags"))"
# already held on the box: no second trip, no second page
box_reset; echo "earlier" > "$C/flags/spend-hold-x"; CURL_MODE=down GH_M24=1 GH_M7=1 run_brake
[ "$(cat "$C/flags/spend-hold-x")" = earlier ] && ! grep -q costlocalhalt "$C/logs/ALERTS.log" && ok \
  || bad "A4 an already-held project is not tripped again ($(cat "$C/logs/ALERTS.log"))"

# =============================================================================
# A5 — the ticket boundary: the budget launch gate block, verbatim
# =============================================================================
awk '/^# >>> budget launch gate/{f=1} f{print} /^# <<< budget launch gate/{f=0}' "$DIR/bin/lib/rb/gates.sh" > "$T/launch.sh"
[ -s "$T/launch.sh" ] && ok || bad "A5 no '# >>> budget launch gate' block"
mkdir -p "$HB/state"
jq -nc --argjson fa "$NOW" '{fetched_at:$fa,values:{},seeded:{}}' > "$HB/state/settings-cache.json"
echo '{"version":1,"lanes":[]}' > "$T/lanes.json"
# launch <build-subdir> <project> [VAR=VAL ...] -> rc
launch() {
  local b="$T/s5/$1" p="$2"; shift 2
  mkdir -p "$b"
  ( export "${ENVS[@]}" HARNESS="$HB" HOME="$T" BUILD="$b" LANE_REGISTRY="$T/lanes.json" PROJECT="$p" \
           RB_GATES_D="$DIR/bin/lib/rb/gates.d" "$@"
    bash -c '
      set -uo pipefail
      KEY=K-5
      STAMP() { date -u +%FT%TZ; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      [ -n "${NO_CLIENT:-}" ] || . "$HARNESS/bin/jobs-client.sh"
      . "$1"
      echo REACHED > "$BUILD/reached"' _ "$T/launch.sh" >"$b/out" 2>&1 )
  echo $?
}
nalerts() { grep -c 'spend-hold' "$HB/logs/ALERTS.log" 2>/dev/null; }
hub_reset; rm -rf "$T/s5"
echo '$154.80/PR over 24h (cost autohalt)' > "$HB/flags/spend-hold-testproj"
R=$(launch a testproj)
[ "$R" = 3 ] && ok || bad "A5 a fresh build of a held project: rc=$R, want 3 ($(cat "$T/s5/a/out"))"
grep -q '^BUILD_DEFERRED spend-hold testproj ' "$T/s5/a/RESULT" 2>/dev/null && ok \
  || bad "A5 RESULT must start 'BUILD_DEFERRED spend-hold testproj': $(cat "$T/s5/a/RESULT" 2>/dev/null)"
grep -q 'flag_set spend-hold-testproj off' "$T/s5/a/RESULT" 2>/dev/null && ok || bad "A5 RESULT must name the lift command"
[ ! -e "$T/s5/a/ADMITTED" ] && [ ! -e "$T/s5/a/reached" ] && ok || bad "A5 a refused launch must write no ADMITTED and go no further"
grep -q 'BUILD_DEFERRED spend-hold testproj' "$T/s5/a/pipeline.log" 2>/dev/null && ok || bad "A5 no pipeline.log line"
[ "$(nalerts)" = 1 ] && grep -q '154.80/PR over 24h (cost autohalt)' "$HB/logs/ALERTS.log" && ok \
  || bad "A5 want one ALERTS line naming the spend that tripped the hold: $(cat "$HB/logs/ALERTS.log")"
R=$(launch b testproj)
[ "$R" = 3 ] && [ "$(nalerts)" = 1 ] && ok || bad "A5 a second refusal the same day: rc=$R, alerts=$(nalerts), want 3 and 1"
# The hold file written by touch carries no reason: the alert says "cost autohalt".
: > "$HB/flags/spend-hold-testproj"
R=$(launch b2 testproj)
[ "$R" = 3 ] && ok || bad "A5 an empty hold file still holds: rc=$R"
echo '$154.80/PR over 24h (cost autohalt)' > "$HB/flags/spend-hold-testproj"
# A ticket already admitted is in progress: a hold set after it started never stops it.
mkdir -p "$T/s5/c"; echo "2026-10-08T00:00:00Z K-5" > "$T/s5/c/ADMITTED"
R=$(launch c testproj RESUME_BUILD="$T/s5/c")
[ "$R" = 0 ] && [ -e "$T/s5/c/reached" ] && ok || bad "A5 a resume of an admitted dir under a hold: rc=$R ($(cat "$T/s5/c/out"))"
# A worker outage answers from the file: still refused.
R=$(launch d testproj CURL_MODE=down)
[ "$R" = 3 ] && [ ! -e "$T/s5/d/ADMITTED" ] && ok || bad "A5 the file holds through a worker outage: rc=$R"
# No jobs client loaded at all (flag_active absent): the file alone holds.
R=$(launch d2 testproj NO_CLIENT=1)
[ "$R" = 3 ] && grep -q '^BUILD_DEFERRED spend-hold testproj ' "$T/s5/d2/RESULT" 2>/dev/null && ok \
  || bad "A5 with no jobs client the file must still hold: rc=$R ($(cat "$T/s5/d2/out"))"
# Another project's hold does not refuse this one.
R=$(launch e project-2)
[ "$R" = 0 ] && grep -q ' K-5$' "$T/s5/e/ADMITTED" 2>/dev/null && ok \
  || bad "A5 spend-hold-testproj must not refuse project-2: rc=$R ($(cat "$T/s5/e/out"))"
# spend-hold-all is not a project name; the gate reads only spend-hold-$PROJECT.
rm -f "$HB/flags/spend-hold-testproj"; : > "$HB/flags/spend-hold-all"
R=$(launch f testproj)
[ "$R" = 0 ] && [ -e "$T/s5/f/ADMITTED" ] && ok || bad "A5 spend-hold-all must not refuse testproj: rc=$R"
# A human pause only: the gate does not read it (triage stops upstream).
rm -f "$HB/flags/"*; : > "$HB/flags/paused-testproj"
R=$(launch g testproj)
[ "$R" = 0 ] && [ -e "$T/s5/g/ADMITTED" ] && ok || bad "A5 paused-testproj alone is not a spend hold: rc=$R"
# No hold: admitted.
rm -f "$HB/flags/"*
R=$(launch h testproj)
[ "$R" = 0 ] && grep -q ' K-5$' "$T/s5/h/ADMITTED" 2>/dev/null && ok || bad "A5 no hold must write ADMITTED: rc=$R ($(cat "$T/s5/h/out"))"

# =============================================================================
# A7 — the pool does not charge a hold to the ticket
# =============================================================================
awk '/^pool_lane_failure\(\)/{f=1} f{print} f&&/^}/{exit}' "$DIR/bin/fly-pool.sh" > "$T/plf.sh"
[ -s "$T/plf.sh" ] && ok || bad "A7 could not extract pool_lane_failure"
plf() { bash -c '. "$1"; pool_lane_failure "$2"; echo $?' _ "$T/plf.sh" "$1"; }
HOLD_RESULT=$(cat "$T/s5/a/RESULT" 2>/dev/null)
[ "$(plf "$HOLD_RESULT")" = 0 ] && ok || bad "A7 the launch gate's hold deferral must read as the lane's condition: '$HOLD_RESULT'"
[ "$(plf "BUILD_DEFERRED push of ticket/x rejected")" = 1 ] && ok || bad "A7 a ticket's own deferral must still count"

# =============================================================================
# N — the console card (the pure lib needs no console-ui dependencies)
# =============================================================================
LIB="$DIR/console-ui/src/lib/cost-breaker.js"
[ -f "$LIB" ] && ok || bad "missing $LIB"
if command -v node >/dev/null 2>&1; then
  if NOUT=$(cd "$DIR/console-ui" && node --test tests/cost-breaker.bh-5526.test.js 2>&1); then ok
  else bad "console-ui/tests/cost-breaker.bh-5526.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -20
  fi
else
  echo "autohalt-boundary: node suite SKIPPED — node is not installed on this box"
fi

echo "autohalt-boundary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
