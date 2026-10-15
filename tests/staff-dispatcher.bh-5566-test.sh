#!/bin/bash
# tests/staff-dispatcher.bh-5566-test.sh — BH-5566 (BH-5556.9): the Dispatcher
# collector, bin/staff/dispatcher-collect.sh, its declarations
# (catalog/staff-feeds.d/) and its lanes.
#
#   D1   Otter shape (a feed 1396 h stale, window 24 h) -> one dead-feed line,
#        1396 h in the title, no hour count in the item, no page
#   D2   the production entry point: bin/staff.sh tick dispatcher twice at
#        augmentation with the real collector -> one claim, one model call,
#        one issue on tick 1; nothing new on tick 2; no page on either; with
#        the collector gone, nothing is claimed
#   D3   a healthy feed -> no line, no page, rc 0
#   D4   a verified deploy 7 h ago, window 6 h, newest output before it -> one
#        post-deploy-output line and one critical page, marker written
#   D5   the same run again -> the same line, no second page
#   D6   knobs: defaults, DSP_PAGE_SEVERITY off/warn/bogus, a settings row,
#        DSP_DEPLOY_LOOKBACK_H, DSP_DEPLOY_ROWS
#   D7   the decision-rule edges, table-driven
#   D8   unreadable probes, an unreadable ledger, no declarations, malformed
#        declarations, an unwritable marker dir, old markers
#   D9   every lane the seed gives dispatcher has a lane registry file
#   D10  the composed schema gives dispatcher exactly the 11 health lanes
#   D11  every committed catalog/staff-feeds.d/*.json validates and its probe
#        path is a GET in worker/jobs/test/route-table.d/
#   D12  the collector names no model string and makes no gh call
#   D13  the reads this lane adds use an index on a seeded database (BH-6730):
#        the deploy ledger list (GET /api/ledger?kind=deploy, ORDER BY
#        updated_at DESC, key DESC) uses idx_ledgers_kind_updated with no temp
#        sort, and the two staff_lanes reads use its primary key
#
# MUTATIONS (D1), each tried by hand once against the collector: `>` to `>=`
# in dead-feed -> D7 red; read an unreadable probe as never -> D8 red; put the
# hour count in the item -> D2 red; skip the marker -> D5 red; count a failed
# deploy -> D7 red.
#
# Probes and the deploy ledger are served by a DSP_FIXTURE _jobs_req stub; a
# ledger row carries `detail` as the JSON text D1 stores
# (bin/deploy-train.sh deploy_record).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-dispatcher.bh-5566-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-dispatcher: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

COL_REL=bin/staff/dispatcher-collect.sh
COL_SRC="$DIR/bin/staff/dispatcher-collect.sh"
LIBF="$DIR/catalog/lanes.d/_lib.staff-dispatcher.json"
[ -r "$COL_SRC" ] || bad "missing $COL_SRC"
[ -r "$LIBF" ] || bad "missing $LIBF"

# 2026-10-14T12:00:00Z, pinned (D60).
NOW=1791979200
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
HR=3600

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H" "$FXT" "$T/fakebin"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$H" >/dev/null || bad "scratch_install_closure $COL_REL failed"
fi
COL="$H/$COL_REL"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/pages.log"\nexit 0\n' "$FXT" > "$T/lane-alert.stub"
chmod +x "$T/lane-alert.stub"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done

# The stub: $FXT/p/<path with / ? = & as _> is the answer body; a .fail file
# next to it makes that path fail. The deploy ledger is $FXT/ledger.json.
cat > "$T/dspfx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  local k
  case "$1 $2" in
    "GET /api/ledger?kind=deploy&"*)
      [ -f "$FXT/ledger.fail" ] && return 1
      cat "$FXT/ledger.json" 2>/dev/null || echo '{"ledgers":[]}'; return 0 ;;
    "GET /api/"*)
      k=$(printf '%s' "$2" | tr '/?=&' '____')
      [ -f "$FXT/p/$k.fail" ] && return 1
      [ -f "$FXT/p/$k" ] || return 2
      cat "$FXT/p/$k"; return 0 ;;
  esac
  return 1
}
SH
DECL="$H/catalog/staff-feeds.d"
pkey() { printf '%s' "$1" | tr '/?=&' '____'; }
# feed <id> <max_age_h> [path] [at]
feed() {
  mkdir -p "$DECL"
  jq -n --arg id "$1" --argjson w "$2" --arg p "${3:-/api/fx/$1?limit=1}" --arg at "${4:-.rows[0].ts}" \
    '{id: $id, kind: "feed", lane: $id, max_age_h: $w, probe: {path: $p, at: $at}, note: "fixture"}' > "$DECL/$1.json"
}
# output <id> <project> <window_h> [path] [at]
output() {
  mkdir -p "$DECL"
  jq -n --arg id "$1" --arg pr "$2" --argjson w "$3" --arg p "${4:-/api/fx/$1?limit=1}" --arg at "${5:-.rows[0].ts}" \
    '{id: $id, kind: "output", project: $pr, window_h: $w, probe: {path: $p, at: $at}, note: "fixture"}' > "$DECL/$1.json"
}
# answer <id> <json value for ts>: the body of /api/fx/<id>?limit=1
answer() { mkdir -p "$FXT/p"; printf '{"rows":[{"ts":%s}]}\n' "$2" > "$FXT/p/$(pkey "/api/fx/$1?limit=1")"; }
answer_at() { answer "$1" "\"$(iso "$2")\""; }
probe_fail() { mkdir -p "$FXT/p"; touch "$FXT/p/$(pkey "/api/fx/$1?limit=1").fail"; }
# deploy <project> <status> <epoch> [verified_at|departure|created]: one ledger row
deploy() {
  local at; at=$(iso "$3")
  jq -c --arg p "$1" --arg s "$2" --arg at "$at" --arg how "${4:-verified_at}" '
    .ledgers += [{kind: "deploy", key: ("fx/" + $p + "@" + ($at | gsub("[^0-9]"; ""))), status: $s,
      detail: ({project: $p, sha: "fixture-sha"}
        + (if $how == "verified_at" then {verified_at: $at, departure: "2000-01-01T00:00:00Z"}
           elif $how == "departure" then {departure: $at} else {} end) | tojson),
      created_at: (if $how == "created" then $at else "2000-01-01T00:00:00Z" end),
      updated_at: $at}]' "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/catalog" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT/p" "$H/bin"
  echo '{"ledgers":[]}' > "$FXT/ledger.json"
  : > "$FXT/req.log"; : > "$FXT/pages.log"
  cp "$T/lane-alert.stub" "$H/bin/lane-alert.sh"
}
# dsp [VAR=value ...] — run the collector as shipped, sandboxed. Out: $T/out, RC.
dsp() {
  env HARNESS="$H" FXT="$FXT" DSP_FIXTURE="$T/dspfx.sh" HARNESS_TEST_SANDBOX=1 \
    DSP_NOW="$NOW" LANE_GATE_DISABLE=1 JOBS_URL= CONSOLE_URL= PATH="$T/fakebin:$PATH" "$@" \
    bash "$COL" > "$T/out" 2> "$T/err"
  RC=$?
}
pages() { lines "$FXT/pages.log"; }
ledger_reads() { grep -c '^GET /api/ledger' "$FXT/req.log"; }
shape() {
  jq -e '.item and .title and .source.kind == "staff-feed" and .source.url == "/staff/dispatcher"
         and (.source.labels | type == "array") and .observedAt == "2026-10-14T12:00:00Z"' "$1" >/dev/null 2>&1
}

# ═════ D1: Otter -> one dead-feed finding ════════════════════════════════════
reset; feed otter-transcripts 24; answer_at otter-transcripts $((NOW - 1396 * HR - 120)); dsp
eq "D1 rc" "$RC" 0
eq "D1 lines" "$(lines "$T/out")" 1
eq "D1 class" "$(jq -r .class "$T/out" 2>/dev/null)" dead-feed
L1=$(iso $((NOW - 1396 * HR - 120)))
eq "D1 item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"dead-feed\",\"feed\":\"otter-transcripts\",\"last_success\":\"$L1\"}"
case "$(jq -r .title "$T/out" 2>/dev/null)" in
  "Dead feed: otter-transcripts last succeeded 1396 h ago ($L1); its window is 24 h") ok ;;
  *) bad "D1 title: $(jq -r .title "$T/out" 2>/dev/null)" ;;
esac
shape "$T/out" && ok || bad "D1 line shape: $(cat "$T/out")"
eq "D1 pages" "$(pages)" 0
eq "D1 ledger reads (no output declared)" "$(ledger_reads)" 0

# ═════ D3: a healthy feed -> nothing ═════════════════════════════════════════
reset; feed cost-fx 2; answer_at cost-fx $((NOW - 600)); dsp
eq "D3 rc" "$RC" 0
eq "D3 lines" "$(lines "$T/out")" 0
eq "D3 pages" "$(pages)" 0

# ═════ D4: deploy then no output -> one finding, one page ════════════════════
DEP=$((NOW - 7 * HR))
reset; output o1 p1 6; deploy p1 verified "$DEP"; answer_at o1 $((DEP - HR)); dsp
eq "D4 rc" "$RC" 0
eq "D4 lines" "$(lines "$T/out")" 1
eq "D4 class" "$(jq -r .class "$T/out" 2>/dev/null)" post-deploy-output
eq "D4 item" "$(jq -c .item "$T/out" 2>/dev/null)" "{\"check\":\"post-deploy-output\",\"output\":\"o1\",\"deployed_at\":\"$(iso "$DEP")\"}"
T4="No output after deploy: o1 (p1) made no output in the 6 h since the $(iso "$DEP") deploy"
eq "D4 title" "$(jq -r .title "$T/out" 2>/dev/null)" "$T4"
shape "$T/out" && ok || bad "D4 line shape: $(cat "$T/out")"
eq "D4 pages" "$(pages)" 1
eq "D4 page argv" "$(cat "$FXT/pages.log")" "--id staff-dispatcher-postdeploy-o1-$DEP --severity critical staff $T4"
[ -f "$H/state/staff/dispatcher/paged/o1.$DEP" ] && ok || bad "D4: no marker o1.$DEP: $(ls -R "$H/state" 2>&1)"
eq "D4 ledger reads" "$(ledger_reads)" 1
grep -q '^GET /api/ledger?kind=deploy&limit=500$' "$FXT/req.log" && ok || bad "D4 ledger request: $(cat "$FXT/req.log")"
grep -q "paged o1" "$H/logs/staff.log" 2>/dev/null && ok || bad "D4: no paged log line"

# ═════ D5: the same run again -> same line, no second page ═══════════════════
cp "$T/out" "$T/out.d4"
dsp
eq "D5 rc" "$RC" 0
cmp -s "$T/out" "$T/out.d4" && ok || bad "D5: the second run printed a different line"
eq "D5 pages" "$(pages)" 1
# A newer deploy is a new item, a new marker and one new page.
DEP2=$((NOW - 6 * HR - 60)); deploy p1 verified "$DEP2"; dsp
eq "D5 new deploy item" "$(jq -r .item.deployed_at "$T/out" 2>/dev/null)" "$(iso "$DEP2")"
eq "D5 new deploy pages" "$(pages)" 2
# The deploy is in the alert id. The same id, inside ALERT_AUTO_CLOSE_S, is
# a suppress in bin/lib/alert-state.sh, so the second page would never go.
eq "D5 new deploy alert id" "$(sed -n 2p "$FXT/pages.log" | cut -d' ' -f2)" "staff-dispatcher-postdeploy-o1-$DEP2"
[ "$(sed -n 1p "$FXT/pages.log" | cut -d' ' -f2)" != "$(sed -n 2p "$FXT/pages.log" | cut -d' ' -f2)" ] && ok \
  || bad "D5: two deploys paged with one alert id: $(cat "$FXT/pages.log")"
[ -f "$H/state/staff/dispatcher/paged/o1.$DEP2" ] && ok || bad "D5: no marker for the new deploy"

# ═════ D6: knobs ═════════════════════════════════════════════════════════════
d4() { reset; output o1 p1 6; deploy p1 verified "$DEP"; answer_at o1 $((DEP - HR)); }
d4; dsp DSP_PAGE_SEVERITY=off
eq "D6 off lines" "$(lines "$T/out")" 1
eq "D6 off pages" "$(pages)" 0
[ -e "$H/state/staff/dispatcher/paged/o1.$DEP" ] && bad "D6: off wrote a marker" || ok
d4; dsp DSP_PAGE_SEVERITY=warn
grep -q -- '--severity warn staff' "$FXT/pages.log" && ok || bad "D6 warn: $(cat "$FXT/pages.log")"
d4; dsp DSP_PAGE_SEVERITY=bogus
grep -q -- '--severity critical staff' "$FXT/pages.log" && ok || bad "D6 bogus page: $(cat "$FXT/pages.log")"
grep -q 'agent=dispatcher warn: DSP_PAGE_SEVERITY=bogus' "$H/logs/staff.log" 2>/dev/null \
  && ok || bad "D6: no warn line for bogus: $(cat "$H/logs/staff.log" 2>/dev/null)"
d4; dsp DSP_DEPLOY_LOOKBACK_H=6
eq "D6 lookback 6 hides the 7 h deploy" "$(lines "$T/out")" 0
d4; dsp DSP_DEPLOY_LOOKBACK_H=0
eq "D6 lookback 0 (out of range) uses 72" "$(lines "$T/out")" 1
grep -q 'warn: DSP_DEPLOY_LOOKBACK_H=0 is outside' "$H/logs/staff.log" 2>/dev/null && ok || bad "D6: no lookback warn"
d4; dsp DSP_DEPLOY_ROWS=7
grep -q '^GET /api/ledger?kind=deploy&limit=7$' "$FXT/req.log" && ok || bad "D6 rows=7: $(cat "$FXT/req.log")"
d4; dsp DSP_DEPLOY_ROWS=5000
grep -q '^GET /api/ledger?kind=deploy&limit=500$' "$FXT/req.log" && ok || bad "D6 rows=5000 -> default"
# The default lookback is 72 h.
reset; output o1 p1 6; deploy p1 verified $((NOW - 71 * HR)); answer o1 null; dsp
eq "D6 default lookback sees 71 h" "$(lines "$T/out")" 1
reset; output o1 p1 6; deploy p1 verified $((NOW - 73 * HR)); answer o1 null; dsp
eq "D6 default lookback drops 73 h" "$(lines "$T/out")" 0
# The settings row, through lib_env_apply and the real registry.
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --to "$REG" >/dev/null 2>&1 || bad "D6: cannot render the lane registry"
jq -e '.libs[] | select(.id == "staff-dispatcher")' "$REG" >/dev/null 2>&1 \
  && ok || bad "D6: catalog/lanes.json has no lib staff-dispatcher"
d4; mkdir -p "$H/state"
printf '{"fetched_at":%s,"values":{"lib.staff-dispatcher.dsp_page_severity":"off"},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
dsp LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW"
eq "D6 settings row severity=off lines" "$(lines "$T/out")" 1
eq "D6 settings row severity=off pages" "$(pages)" 0
d4; mkdir -p "$H/state"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
dsp LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW"
eq "D6 no settings row pages" "$(pages)" 1

# ═════ D7: the decision-rule edges, table-driven ═════════════════════════════
# feed rows: name | max_age_h | probe value (JSON) | want lines
while IFS='|' read -r name w v want; do
  [ -n "$name" ] || continue
  reset; feed f1 "$w"; answer f1 "$v"; dsp
  eq "D7 feed $name rc" "$RC" 0
  eq "D7 feed $name lines" "$(lines "$T/out")" "$want"
  eq "D7 feed $name pages" "$(pages)" 0
done <<EOF
otter 1396 h, window 24|24|"$(iso $((NOW - 1396 * HR)))"|1
2 h + 1 s, window 2|2|"$(iso $((NOW - 2 * HR - 1)))"|1
exactly 2 h, window 2|2|"$(iso $((NOW - 2 * HR)))"|0
10 min, window 2|2|"$(iso $((NOW - 600)))"|0
future|2|"$(iso $((NOW + 3 * HR)))"|0
null|2|null|1
empty string|2|""|1
epoch s stale|2|$((NOW - 3 * HR))|1
epoch s fresh|2|$((NOW - 60))|0
epoch ms stale|2|$(( (NOW - 3 * HR) * 1000 + 250 ))|1
epoch ms fresh|2|$(( (NOW - 60) * 1000 ))|0
space and fractions stale|2|"$(date -u -d "@$((NOW - 5 * HR))" '+%Y-%m-%d %H:%M:%S').123"|1
space and fractions fresh|2|"$(date -u -d "@$((NOW - 60))" '+%Y-%m-%d %H:%M:%S').123456"|0
EOF
reset; feed f1 2; answer f1 null; dsp
eq "D7 null item" "$(jq -c .item "$T/out" 2>/dev/null)" '{"check":"dead-feed","feed":"f1","last_success":"never"}'
eq "D7 null title" "$(jq -r .title "$T/out" 2>/dev/null)" "Dead feed: f1 has no success on record; its window is 2 h"
reset; feed f1 2; answer f1 $(( (NOW - 3 * HR) * 1000 + 250 )); dsp
eq "D7 ms item" "$(jq -r .item.last_success "$T/out" 2>/dev/null)" "$(iso $((NOW - 3 * HR)))"
case "$(jq -r .title "$T/out" 2>/dev/null)" in *"last succeeded 3 h ago"*) ok ;; *) bad "D7 ms hours: $(cat "$T/out")" ;; esac
reset; feed f1 2; answer f1 "\"$(date -u -d "@$((NOW - 5 * HR))" '+%Y-%m-%d %H:%M:%S').123\""; dsp
eq "D7 space item" "$(jq -r .item.last_success "$T/out" 2>/dev/null)" "$(iso $((NOW - 5 * HR)))"

# output rows: name | deploys (project:status:age_s[:how] ...) | output probe (JSON, or "D-<s>"/"D+<s>" around the newest deploy) | want lines
while IFS='|' read -r name deps v want; do
  [ -n "$name" ] || continue
  reset; output o1 p1 6
  newest=""
  for d in $deps; do
    IFS=: read -r dp ds da dh <<<"$d"
    deploy "$dp" "$ds" $((NOW - da)) "${dh:-verified_at}"
    [ "$dp" = p1 ] && [ "$ds" = verified ] && { [ -z "$newest" ] || [ $((NOW - da)) -gt "$newest" ]; } && newest=$((NOW - da))
  done
  case "$v" in
    D-*) answer_at o1 $(( ${newest:-$NOW} - ${v#D-} )) ;;
    D+*) answer_at o1 $(( ${newest:-$NOW} + ${v#D+} )) ;;
    *) answer o1 "$v" ;;
  esac
  dsp
  eq "D7 output $name rc" "$RC" 0
  eq "D7 output $name lines" "$(lines "$T/out")" "$want"
  eq "D7 output $name pages" "$(pages)" "$want"
done <<EOF
7 h, window 6, output D-1h|p1:verified:$((7 * HR))|D-3600|1
exactly 6 h, output null|p1:verified:$((6 * HR))|null|1
5 h 59 m, output null|p1:verified:$((6 * HR - 60))|null|0
output at the deploy second|p1:verified:$((7 * HR))|D+0|0
output 10 min after|p1:verified:$((7 * HR))|D+600|0
only a failed deploy|p1:failed:$((7 * HR))|null|0
older than the lookback|p1:verified:$((73 * HR))|null|0
another project only|p2:verified:$((7 * HR))|null|0
lane rc 0 but no output since|p1:verified:$((7 * HR))|D-60|1
newest of two deploys|p1:verified:$((30 * HR)) p1:verified:$((7 * HR))|D-60|1
departure when no verified_at|p1:verified:$((7 * HR)):departure|D-60|1
created_at when no detail time|p1:verified:$((7 * HR)):created|D-60|1
EOF
# The newest deploy is the one judged; a failed newer one is not a deploy.
reset; output o1 p1 6; deploy p1 verified $((NOW - 30 * HR)); deploy p1 verified $((NOW - 7 * HR))
deploy p1 failed $((NOW - 6 * HR - 1)); answer_at o1 $((NOW - 20 * HR)); dsp
eq "D7 newest verified deploy" "$(jq -r .item.deployed_at "$T/out" 2>/dev/null)" "$(iso $((NOW - 7 * HR)))"
# The check reads the OUTPUT and the ledger and nothing else: no lane rc.
eq "D7 reads only probe and ledger" "$(grep -vc -e '^GET /api/fx/o1?limit=1$' -e '^GET /api/ledger?kind=deploy&limit=500$' "$FXT/req.log")" 0

# ═════ D8: unreadable, absent, malformed ═════════════════════════════════════
reset; feed fa 2; feed fb 2; probe_fail fa; probe_fail fb; dsp
eq "D8 all fail rc" "$RC" 1
eq "D8 all fail stdout" "$(lines "$T/out")" 0
eq "D8 all fail pages" "$(pages)" 0
reset; feed fa 2; feed fb 2; probe_fail fa; answer fb null; dsp
eq "D8 one fails rc" "$RC" 0
eq "D8 one fails lines" "$(lines "$T/out")" 1
eq "D8 one fails line is fb" "$(jq -r .item.feed "$T/out" 2>/dev/null)" fb
eq "D8 one unreadable log line" "$(grep -c 'dispatcher: probe fa unreadable' "$H/logs/staff.log" 2>/dev/null)" 1
# A non-time answer is unreadable, never "never succeeded" (absent != zero).
for v in '"hello"' '"2026-13-45T00:00:00Z"' '{"a":1}' '"-5"' 'true'; do
  reset; feed fa 2; answer fa "$v"; dsp
  eq "D8 answer $v rc" "$RC" 1
  eq "D8 answer $v lines" "$(lines "$T/out")" 0
done
# A probe whose `at` answers more than one value is unreadable.
reset; feed fa 2 /api/fx/fa?limit=1 '.rows[], .rows[]'; answer_at fa $((NOW - 9 * HR)); dsp
eq "D8 two values rc" "$RC" 1
# A route with no such path (rc 2) is unreadable too.
reset; feed fa 2; dsp
eq "D8 absent path rc" "$RC" 1
# The ledger unreadable with an output declared: rc 1, no page, even with a dead feed.
reset; output o1 p1 6; feed fa 2; answer fa null; deploy p1 verified "$DEP"; answer_at o1 $((DEP - HR)); touch "$FXT/ledger.fail"; dsp
eq "D8 ledger fail rc" "$RC" 1
eq "D8 ledger fail stdout" "$(lines "$T/out")" 0
eq "D8 ledger fail pages" "$(pages)" 0
# A ledger answer that is not a ledger list is unreadable.
reset; output o1 p1 6; answer_at o1 "$DEP"; echo '{"error":"x"}' > "$FXT/ledger.json"; dsp
eq "D8 ledger not a list rc" "$RC" 1
# No declarations: rc 0, nothing, no read at all.
reset; dsp
eq "D8 none rc" "$RC" 0
eq "D8 none lines" "$(lines "$T/out")" 0
eq "D8 none reads" "$(lines "$FXT/req.log")" 0
# Malformed declarations: each one skipped with one log line; a good one still runs.
reset; feed good 2; answer good null
printf '{not json' > "$DECL/badjson.json"
jq -n '{id: "other-name", kind: "feed", max_age_h: 2, probe: {path: "/api/x", at: ".a"}}' > "$DECL/misnamed.json"
jq -n '{id: "Bad_Id", kind: "feed", max_age_h: 2, probe: {path: "/api/x", at: ".a"}}' > "$DECL/Bad_Id.json"
jq -n '{id: "badkind", kind: "thing", max_age_h: 2, probe: {path: "/api/x", at: ".a"}}' > "$DECL/badkind.json"
jq -n '{id: "badwin", kind: "feed", max_age_h: 0, probe: {path: "/api/x", at: ".a"}}' > "$DECL/badwin.json"
jq -n '{id: "badwin2", kind: "feed", max_age_h: "2", probe: {path: "/api/x", at: ".a"}}' > "$DECL/badwin2.json"
jq -n '{id: "badpath", kind: "feed", max_age_h: 2, probe: {path: "https://example.com/api/x", at: ".a"}}' > "$DECL/badpath.json"
jq -n '{id: "dotdot", kind: "feed", max_age_h: 2, probe: {path: "/api/../x", at: ".a"}}' > "$DECL/dotdot.json"
jq -n '{id: "space", kind: "feed", max_age_h: 2, probe: {path: "/api/x y", at: ".a"}}' > "$DECL/space.json"
jq -n '{id: "badjq", kind: "feed", max_age_h: 2, probe: {path: "/api/x", at: ".a | ]"}}' > "$DECL/badjq.json"
jq -n '{id: "badproj", kind: "output", project: "Bad Proj", window_h: 2, probe: {path: "/api/x", at: ".a"}}' > "$DECL/badproj.json"
jq -n '{id: "outwin", kind: "output", project: "p1", max_age_h: 2, probe: {path: "/api/x", at: ".a"}}' > "$DECL/outwin.json"
dsp
eq "D8 malformed rc" "$RC" 0
eq "D8 malformed lines" "$(lines "$T/out")" 1
eq "D8 malformed good line" "$(jq -r .item.feed "$T/out" 2>/dev/null)" good
eq "D8 malformed log lines" "$(grep -c 'dispatcher: declaration .* invalid' "$H/logs/staff.log" 2>/dev/null)" 12
eq "D8 malformed: only the good probe read" "$(cat "$FXT/req.log")" "GET /api/fx/good?limit=1"
# The marker dir cannot be made: the page still goes, one warn line.
reset; output o1 p1 6; deploy p1 verified "$DEP"; answer_at o1 $((DEP - HR))
mkdir -p "$H/state/staff/dispatcher"; : > "$H/state/staff/dispatcher/paged"; dsp
eq "D8 no marker dir rc" "$RC" 0
eq "D8 no marker dir pages" "$(pages)" 1
grep -q 'agent=dispatcher warn: cannot write the page marker' "$H/logs/staff.log" 2>/dev/null && ok || bad "D8: no marker warn"
# Markers older than DSP_DEPLOY_LOOKBACK_H are deleted; a recent one stays.
reset; mkdir -p "$H/state/staff/dispatcher/paged"
: > "$H/state/staff/dispatcher/paged/old.1"; touch -d '2000-01-01T00:00:00Z' "$H/state/staff/dispatcher/paged/old.1"
: > "$H/state/staff/dispatcher/paged/new.1"
dsp
[ -e "$H/state/staff/dispatcher/paged/old.1" ] && bad "D8: a marker past the lookback stayed" || ok
[ -e "$H/state/staff/dispatcher/paged/new.1" ] && ok || bad "D8: a recent marker was deleted"
# The prune follows the lookback knob: 2 h old, lookback 1 h -> deleted; 30 min old -> stays.
reset; mkdir -p "$H/state/staff/dispatcher/paged"
: > "$H/state/staff/dispatcher/paged/old.2"; touch -d '2 hours ago' "$H/state/staff/dispatcher/paged/old.2"
: > "$H/state/staff/dispatcher/paged/new.2"; touch -d '30 minutes ago' "$H/state/staff/dispatcher/paged/new.2"
dsp DSP_DEPLOY_LOOKBACK_H=1
[ -e "$H/state/staff/dispatcher/paged/old.2" ] && bad "D8: a marker past a 1 h lookback stayed" || ok
[ -e "$H/state/staff/dispatcher/paged/new.2" ] && ok || bad "D8: a marker inside a 1 h lookback was deleted"

# ═════ D2: the production entry point ════════════════════════════════════════
S="$T/s"
mkdir -p "$S/prompts/staff" "$S/catalog/prompts" "$S/catalog/staff-feeds.d"
scratch_install_closure bin/staff.sh "$S" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
scratch_install_closure bin/jobs-client.sh "$S" >/dev/null || bad "D2 closure of bin/jobs-client.sh failed"
if [ -r "$COL_SRC" ]; then
  scratch_install_closure "$COL_REL" "$S" >/dev/null || bad "D2 closure of the collector failed"
fi
cp "$DIR/bin/staff-core.mjs" "$S/bin/"
cp -r "$DIR/agent-core" "$S/agent-core"
cp "$DIR/prompts/staff/dispatcher-soul.md" "$S/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$S/catalog/prompts/"
cat > "$S/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${STAFF_AGENT:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit 0
SH
cp "$T/lane-alert.stub" "$S/bin/lane-alert.sh"
chmod +x "$S/bin/agent-call.sh" "$S/bin/lane-alert.sh"
jq -n '{id: "otter-transcripts", kind: "feed", lane: "otter-transcripts", max_age_h: 24,
  probe: {path: "/api/fx/otter-transcripts?limit=1", at: ".rows[0].ts"}, note: "fixture"}' \
  > "$S/catalog/staff-feeds.d/otter-transcripts.json"
# The claim stub keys on the item, as the route does: a fingerprint it has
# seen answers 409 already_claimed (the finding is filed by then).
cat > "$T/stafffx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/staff-req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name=dispatcher")
      printf '{"agent":{"name":"dispatcher","autonomy":"augmentation","cap":"augmentation","status":"active","soul":"prompts/staff/dispatcher-soul.md"}}'
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/staff-req.log"
  local fp
  case "$2" in
    /api/staff/findings/claim)
      fp=$(jq -cS .item "$3" | sha256sum | cut -c1-64)
      if grep -qx "$fp" "$FXT/claimed" 2>/dev/null; then
        printf '{"claimed":false,"error":"already_claimed","fingerprint":"%s","finding":{"agent":"dispatcher","status":"filed"}}' "$fp"
        return 9
      fi
      printf '%s\n' "$fp" >> "$FXT/claimed"
      printf '{"claimed":true,"fingerprint":"%s","finding":{"agent":"dispatcher","status":"claimed"}}' "$fp"; return 0 ;;
    /api/staff/findings/record) printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  printf 'gh_rest %s %s\n' "$1" "$2" >> "$FXT/gh.log"
  [ "${3:-}" = --input ] && cp "$4" "$FXT/gh-payload.json"
  GH_REST_STATUS=201
  printf '{"number":7,"html_url":"https://github.com/example/fixture/issues/7"}\n'
  return 0
}
gh_rest_issue_list() { printf 'LIST %s\n' "$*" >> "$FXT/gh.log"; GH_REST_STATUS=200; echo '[]'; return 0; }
lane_role_model() { printf 'stub-model\n'; }
SH
d2() { # d2 <now> — one tick, the shipped entry point
  : > "$FXT/staff-req.log"; : > "$FXT/ac.log"; : > "$FXT/gh.log"; : > "$FXT/req.log"; : > "$FXT/pages.log"
  env HARNESS="$S" FXT="$FXT" STAFF_FIXTURE="$T/stafffx.sh" DSP_FIXTURE="$T/dspfx.sh" \
    HARNESS_TEST_SANDBOX=1 DSP_NOW="$1" LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= CONSOLE_URL= \
    PATH="$T/fakebin:$PATH" bash "$S/bin/staff.sh" tick dispatcher > "$T/d2.out" 2>&1
  RC=$?
}
reset; scratch_rm "$S/state" || exit 1; scratch_rm "$S/logs" || exit 1; rm -f "$FXT/claimed"
answer_at otter-transcripts $((NOW - 1396 * HR))
d2 "$NOW"
eq "D2 tick1 rc" "$RC" 0
eq "D2 tick1 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 1
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '1396 h ago' && ok || bad "D2: the claim title lacks 1396 h: $(cat "$FXT/staff-req.log")"
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '"agent":"dispatcher"' && ok || bad "D2: the claim is not dispatcher's"
eq "D2 tick1 agent-calls" "$(lines "$FXT/ac.log")" 1
eq "D2 tick1 agent-call" "$(cat "$FXT/ac.log" 2>/dev/null)" "staff-tick|dispatcher"
eq "D2 tick1 issue creates" "$(grep -c '^gh_rest POST repos/.*/issues$' "$FXT/gh.log")" 1
eq "D2 tick1 labels" "$(jq -c .labels "$FXT/gh-payload.json" 2>/dev/null)" '["staff:dispatcher"]'
eq "D2 tick1 pages" "$(pages)" 0
grep -q 'collected=1 new=1 .* model_calls=1 .*filed=1' "$S/logs/staff.log" 2>/dev/null \
  && ok || bad "D2 tick1 summary: $(cat "$S/logs/staff.log" 2>/dev/null)"
# Tick 2, an hour later: the title says 1397 h; the item, so the claim, is the same.
d2 $((NOW + HR))
eq "D2 tick2 rc" "$RC" 0
eq "D2 tick2 claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 1
grep 'findings/claim' "$FXT/staff-req.log" | grep -q '1397 h ago' && ok || bad "D2 tick2: the title did not move"
eq "D2 tick2 agent-calls" "$(lines "$FXT/ac.log")" 0
eq "D2 tick2 issue creates" "$(grep -c '^gh_rest POST' "$FXT/gh.log")" 0
eq "D2 tick2 pages" "$(pages)" 0
eq "D2 ALERTS lines" "$(lines "$S/logs/ALERTS.log")" 0
# With the collector gone, the tick claims nothing (D2 rule).
rm -f "$S/$COL_REL"; rm -f "$FXT/claimed"; d2 "$NOW"
eq "D2 no collector rc" "$RC" 0
eq "D2 no collector claims" "$(grep -c 'findings/claim' "$FXT/staff-req.log")" 0
eq "D2 no collector agent-calls" "$(lines "$FXT/ac.log")" 0

# ═════ D9/D10: the lane seed ═════════════════════════════════════════════════
LANES11="fleet-slo healthcheck heartbeat-reaper hub-probe jobs-watchdog lane-run-wait-alert pipeline-health served-sha-watch watchdog-ping watchdog-poll watchdog-responder"
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-5566-dispatcher-lanes.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && ok || bad "D9: no worker/jobs/schema.d/*-bh-5566-*.sql fragment"
SEEDED=$( [ -n "$SEED" ] && sed -n "s/^[[:space:]]*('dispatcher','\([a-z0-9-]*\)',.*/\1/p" "$SEED" | LC_ALL=C sort | paste -sd' ')
eq "D9 seeded lanes" "$SEEDED" "$LANES11"
for L in $SEEDED; do
  [ -r "$DIR/catalog/lanes.d/$L.json" ] && ok || bad "D9: seeded lane $L has no catalog/lanes.d/$L.json"
done
if [ -n "$SEED" ] && grep -qiE '^[[:space:]]*(drop|alter|delete|update|create)[[:space:]]' "$SEED"; then
  bad "D9: the seed fragment holds DDL or a destructive statement"
else ok; fi
if node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/schema-build.sh" --root "$DIR" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
    || bad "D10: bin/schema-build.sh --to failed"
  GOT=$(node --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(":memory:");
    db.exec(require("node:fs").readFileSync(process.argv[1], "utf8"));
    db.exec(require("node:fs").readFileSync(process.argv[2], "utf8"));
    const r = db.prepare("SELECT lane FROM staff_lanes WHERE agent = ? ORDER BY lane").all("dispatcher");
    console.log(r.map((x) => x.lane).join(" "));
  ' "$T/schema.sql" "${SEED:-/dev/null}" 2>&1)
  eq "D10 dispatcher lanes after the seed applies twice" "$GOT" "$LANES11"
else
  echo "D10 skipped: node:sqlite is not available in this node"
fi

# ═════ D11: the committed declarations ═══════════════════════════════════════
N=0
reset; mkdir -p "$DECL"
for f in "$DIR"/catalog/staff-feeds.d/*.json; do
  [ -e "$f" ] || continue
  N=$((N+1)); cp "$f" "$DECL/"
  id=$(basename "$f" .json)
  p=$(jq -r .probe.path "$f" 2>/dev/null)
  mkdir -p "$FXT/p"; printf '{}\n' > "$FXT/p/$(pkey "$p")"
  grep -qxF "GET ${p%%\?*}" <(cat "$DIR"/worker/jobs/test/route-table.d/*.txt) \
    && ok || bad "D11: $id probe ${p%%\?*} is not a GET in worker/jobs/test/route-table.d"
done
[ "$N" -ge 2 ] && ok || bad "D11: want at least 2 committed declarations, got $N"
dsp
eq "D11 invalid declarations" "$(cat "$H/logs/staff.log" 2>/dev/null | grep -c 'invalid')" 0
eq "D11 probes read" "$(grep -c '^GET /api/' "$FXT/req.log")" "$N"
eq "D11 ledger reads (no output seeded)" "$(ledger_reads)" 0
eq "D11 rc (each probe answers null: never)" "$RC" 0
eq "D11 lines" "$(lines "$T/out")" "$N"

# ═════ D12: no model string, no gh ═══════════════════════════════════════════
if [ -r "$COL_SRC" ]; then
  eq "D12 claude- strings" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -c 'claude-')" 0
  eq "D12 gh calls" "$(grep -v '^[[:space:]]*#' "$COL_SRC" | grep -cE '(^|[^a-z_])gh( |_rest)')" 0
  [ -x "$COL_SRC" ] && ok || bad "D12: the collector is not executable (staff.sh runs it only when -x)"
else
  bad "D12: no collector to scan"
fi

[ -e "$T/net.log" ] && bad "a stub let a real curl/gh run: $(cat "$T/net.log")" || ok

# ═════ D13: the reads use an index (BH-6730) ═════════════════════════════════
if node -e 'require("node:sqlite")' >/dev/null 2>&1 && [ -s "$T/schema.sql" ]; then
  PLAN=$(node --no-warnings -e '
    const { DatabaseSync } = require("node:sqlite");
    const db = new DatabaseSync(":memory:");
    db.exec(require("node:fs").readFileSync(process.argv[1], "utf8"));
    // 20000 ledger rows over 5 kinds, as on the hub: deploy is one of them.
    const ins = db.prepare("INSERT INTO ledgers (kind, key, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?)");
    const kinds = ["merge", "migration", "pr_state", "deploy", "issue_state"];
    for (let i = 0; i < 20000; i++) {
      const t = new Date(Date.UTC(2026, 8, 1) + i * 60000).toISOString().replace(/\.\d+Z$/, "Z");
      ins.run(kinds[i % 5], "k" + i, "verified", t, t);
    }
    db.exec("ANALYZE");
    const plan = (sql) => db.prepare("EXPLAIN QUERY PLAN " + sql).all().map((r) => r.detail).join(" | ");
    console.log("LEDGER " + plan("SELECT * FROM ledgers WHERE kind = ?1 ORDER BY updated_at DESC, key DESC LIMIT 50"));
    console.log("LANES1 " + plan("SELECT lane FROM staff_lanes WHERE agent = ?1 ORDER BY lane"));
    console.log("LANES2 " + plan("SELECT agent, lane FROM staff_lanes ORDER BY agent, lane"));
  ' "$T/schema.sql" 2>&1)
  L=$(sed -n 's/^LEDGER //p' <<<"$PLAN")
  grep -q 'idx_ledgers_kind_updated' <<<"$L" && ! grep -q 'TEMP B-TREE' <<<"$L" \
    && ok || bad "D13 the deploy ledger list must use idx_ledgers_kind_updated with no temp sort: $L"
  grep -q 'sqlite_autoindex_staff_lanes' <<<"$(sed -n 's/^LANES1 //p' <<<"$PLAN")" && ok \
    || bad "D13 staff_lanes WHERE agent=? must use its primary key: $(sed -n 's/^LANES1 //p' <<<"$PLAN")"
  ! grep -q 'TEMP B-TREE' <<<"$(sed -n 's/^LANES2 //p' <<<"$PLAN")" && ok \
    || bad "D13 the full staff_lanes read must be ordered by its key: $(sed -n 's/^LANES2 //p' <<<"$PLAN")"
else
  echo "D13 skipped: node:sqlite or the composed schema is not available"
fi

echo "staff-dispatcher.bh-5566: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
