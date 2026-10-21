#!/bin/bash
# tests/merge-conductor-box.bh-7636-test.sh — BH-7636: the merge conductor of
# one project placed on a named box (lane_placement.merge-conductor.<project>
# = box:<name>).
#
# Part A runs the REAL bin/lib/mc/project-placement.sh and
# bin/lib/lane-placement.sh in a scratch HARNESS root. Stubs: setting_get
# (reads $T/settings/<key>), _jobs_req (GET answers $T/rows.json; POST
# .../withdraw records its body and answers the rc in $T/withdraw.rc),
# lp_enqueue (records a line), lri_apply_pending/lri_publish.
# bin/lane-alert.sh appends one line to logs/ALERTS.log.
#
#   B1  mc_proj_newest: the box-silent cases (a claimed row whose lease ran
#       out st s ago or more), and the same rows on a fly placement
#   B4  a queued box row older than st: withdrawn, the hub takes the tick
#   B5  ONE box-down ALERTS line on the first take-back, 0 on 3 more in the
#       same outage, 0 for a project placed hub; a 409 withdraw writes none
#   B6  a claimed row (the box answers) clears the mark; the next outage
#       writes 1 line
#   B7  a claimed row silent for st s or more: withdraw with expired:1
#   B8  undo: the row back to hub -> rc 1, .placed and .box-down removed
#   B9  a box placement writes no BH-7462 no-capacity streak line
#   B10 mc_proj_none_fly: a box: value in the settings cache gates
#
# Part B drives the REAL jobs worker over curl (tests/lib/mc-budget.bh-6887.mjs)
# through the real bin/lib/mc/fly-workers.sh gate, bin/lane-run-worker.sh and
# bin/project-lane-run.sh. bin/merge-conductor-project.sh is a recorder.
#
#   B2  placed box:box-project-6-os-1: 5 hub gate ticks enqueue ONE row and
#       run no hub tick; a Fly worker claims nothing; the box worker runs the
#       row and reports rc 0 as box-project-6-os-1
#   W1  --box with a bad name exits 2 and sends no claim
#   W2  a claim answer with no `box` (a jobs worker from before BH-7636 that
#       ignored the field): the row is released, not run, and the worker exits 1
#   P1  bin/lane-snapshot-publish.sh --lane merge-conductor publishes a
#       project placed box (stubbed jobs client, real lane-placement.sh)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-box.bh-7636-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# Part B starts the real worker (tests/lib/mc-budget.bh-6887.mjs), which imports
# catalog/llm-sites.json: compose it, or a fresh checkout dies in node (BH-6452).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
BOX=box-project-6-os-1; P=project-6-os

# ============================================================================
# Part A
H="$T/h"; D="$H/state/merge-conductor/project-fly"
mkdir -p "$H/bin/lib/mc" "$H/logs" "$T/settings"
for L in bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh bin/lib/lane-placement.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

cat > "$T/stubs.sh" <<EOF
. "$H/bin/lib/lane-placement.sh"
_lp_client() { return 0; }
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
lp_enqueue() { echo "enqueue \$2" >> "$T/enqueues.txt"; return 0; }
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; return 0; }
lri_publish() { echo "published 0 0"; return 0; }
_jobs_req() {
  if [ "\$1" = GET ]; then cat "$T/rows.json"; return 0; fi
  local rc; rc=\$(cat "$T/withdraw.rc" 2>/dev/null || echo 0)
  JOBS_HTTP=200; JOBS_BODY='{}'
  [ "\$rc" = 9 ] && { JOBS_HTTP=409; JOBS_BODY='{"reason":"not_queued"}'; }
  echo "withdraw \$2 \$3" >> "$T/withdraws.txt"
  return "\$rc"
}
EOF

ago() { date -u -d "@$(( $(date -u +%s) - $1 ))" +%FT%TZ; }
# row <project> <id> <status> [prof_line] [enqueued age-s] [lease_until age-s|-]
row() {
  local lu=null
  [ "${6:--}" != - ] && lu="\"$(ago "$6")\""
  jq -nc --arg p "$1" --argjson id "$2" --arg s "$3" --arg pl "${4:-}" --arg at "$(ago "${5:-700}")" --argjson lu "$lu" \
    '{rows:[{id:$id, project:$p, status:$s, prof_line:$pl, rc:null, enqueued_at:$at, lease_until:$lu}]}' > "$T/rows.json"
}
place() { printf '%s' "$2" > "$T/settings/lane_placement.merge-conductor.$1"; }
# tick <project> — one hub gate decision in its own process. Sets RC.
tick() {
  HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; . \"$T/stubs.sh\"; mc_proj_gate \"$1\" 600; rc=\$?; mc_proj_hub_unmark \"$1\"; exit \$rc" \
    2>>"$T/gate.log"; RC=$?
}
reset() {
  scratch_rm "$D"
  rm -rf "$T/settings" "$T/withdraw.rc" "$T/enqueues.txt" "$T/withdraws.txt"
  mkdir -p "$T/settings"; : > "$H/logs/ALERTS.log"; : > "$T/gate.log"
}
boxlines() { grep -c "mc-project-box-$1" "$H/logs/ALERTS.log"; }
newest() { HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; mc_proj_newest \"\$(cat \"$T/rows.json\")\" $P $(date -u +%s) 600 $1"; }

echo "B1: box-silent classification"
reset
while IFS='|' read -r st enq lu box want; do
  [ -n "$st" ] || continue
  row $P 7 "$st" "" "$enq" "$lu"
  got=$(newest "$box"); got=${got%% *}
  [ "$got" = "$want" ] && ok "B1 $st enqueued ${enq}s ago lease ${lu}s ago box=$box -> $want" \
    || bad "B1 $st enq=$enq lease=$lu box=$box -> '$(newest "$box")' want $want"
done <<'EOF'
queued|100|-|1|live
queued|700|-|1|stale
claimed|700|-120|1|live
claimed|700|300|1|live
claimed|700|600|1|stale
claimed|700|900|1|stale
claimed|700|900|0|live
claimed|700|-|1|live
EOF
row $P 7 claimed "" 700 900
[ "$(newest 1)" = "stale 7 box-silent" ] && ok "B1 detail is box-silent" || bad "B1 detail: $(newest 1)"
row $P 7 died "withdrawn by=hub-x stale-700s" 700
[ "$(newest 1)" = "stale 7 withdrawn" ] && ok "B1 a withdrawn row stays stale withdrawn" || bad "B1 withdrawn: $(newest 1)"

echo "B4: a queued box row older than st is taken back"
reset; place $P "box:$BOX"; row $P 11 queued "" 700; tick $P
[ "$RC" = 1 ] && ok "B4 rc 1: the hub runs the tick" || bad "B4 rc $RC; $(tail -3 "$T/gate.log")"
grep -q '^withdraw /api/lane-runs/11/withdraw ' "$T/withdraws.txt" && ok "B4 row 11 withdrawn" || bad "B4 withdraws: $(cat "$T/withdraws.txt" 2>/dev/null)"
[ "$(jq -r '.expired // "none"' <<<"$(sed -n 's/^withdraw [^ ]* //p' "$T/withdraws.txt")")" = none ] && ok "B4 a queued row is withdrawn without expired" || bad "B4 body: $(cat "$T/withdraws.txt")"
grep -q "project-box($BOX)" "$T/gate.log" && ok "B4 the log names project-box($BOX)" || bad "B4 log: $(cat "$T/gate.log")"

echo "B5: one alert per outage"
[ "$(boxlines $P)" = 1 ] && ok "B5 the first take-back writes 1 line" || bad "B5 lines=$(boxlines $P): $(cat "$H/logs/ALERTS.log")"
grep -q "took the project back to the hub" "$H/logs/ALERTS.log" && grep -q "box $BOX" "$H/logs/ALERTS.log" \
  && ok "B5 the line names the box and the take-back" || bad "B5 text: $(cat "$H/logs/ALERTS.log")"
[ -e "$D/$P.box-down" ] && ok "B5 the box-down mark is written" || bad "B5 no mark"
for id in 12 13 14; do
  rm -f "$D/$P.nocap-at"
  row $P "$id" queued "" 700; tick $P
done
[ "$(boxlines $P)" = 1 ] && ok "B5 3 more take-backs in the outage write 0 lines" || bad "B5 lines=$(boxlines $P)"
[ "$(grep -c '^withdraw ' "$T/withdraws.txt")" = 4 ] && ok "B5 each stale row was withdrawn (4)" || bad "B5 withdraws: $(cat "$T/withdraws.txt")"
place other hub; row other 20 queued "" 700; tick other
[ "$RC" = 1 ] && [ "$(boxlines other)" = 0 ] && ok "B5 a project placed hub: today's tick, 0 lines" || bad "B5 hub project rc $RC lines $(boxlines other)"
reset; place $P "box:$BOX"; echo 9 > "$T/withdraw.rc"; row $P 15 queued "" 700; tick $P
[ "$RC" = 0 ] && [ "$(boxlines $P)" = 0 ] && [ ! -e "$D/$P.box-down" ] \
  && ok "B5 a 409 withdraw (the box claimed it): rc 0, no line, no mark" || bad "B5 409: rc $RC lines $(boxlines $P)"

echo "B6: the box answers -> the mark goes; the next outage alerts again"
reset; place $P "box:$BOX"; row $P 30 queued "" 700; tick $P
[ "$(boxlines $P)" = 1 ] || bad "B6 setup lines=$(boxlines $P)"
rm -f "$D/$P.nocap-at"; row $P 31 claimed "" 10 -100; tick $P
[ "$RC" = 0 ] && [ ! -e "$D/$P.box-down" ] && ok "B6 a live claimed row: rc 0, mark removed" || bad "B6 rc $RC mark $(ls "$D")"
row $P 32 queued "" 700; tick $P
[ "$(boxlines $P)" = 2 ] && ok "B6 the next outage writes 1 more line" || bad "B6 lines=$(boxlines $P)"
for k in "done|PROF mc-project state=OK deferred=-" "deferred|PROF mc-project state=DEFERRED deferred=land"; do
  reset; place $P "box:$BOX"; mkdir -p "$D"; echo 1 > "$D/$P.box-down"
  row $P 40 done "${k#*|}" 10; tick $P
  [ ! -e "$D/$P.box-down" ] && ok "B6 a ${k%%|*} row clears the mark" || bad "B6 ${k%%|*}: mark kept"
done
reset; place $P "box:$BOX"; mkdir -p "$D"; echo 1 > "$D/$P.box-down"
row $P 41 died "" 10; tick $P
[ -e "$D/$P.box-down" ] && ok "B6 a died row (no box answer) keeps the mark" || bad "B6 died row removed the mark"

echo "B7: a claimed row silent for st s or more"
reset; place $P "box:$BOX"; row $P 50 claimed "" 900 650; tick $P
[ "$RC" = 1 ] && ok "B7 rc 1: taken back" || bad "B7 rc $RC; $(tail -3 "$T/gate.log")"
[ "$(sed -n 's/^withdraw [^ ]* //p' "$T/withdraws.txt" | jq -r '.expired')" = 1 ] && ok "B7 withdraw body has expired:1" || bad "B7 withdraws: $(cat "$T/withdraws.txt" 2>/dev/null)"
[ "$(boxlines $P)" = 1 ] && ok "B7 1 box-down line" || bad "B7 lines=$(boxlines $P)"
reset; place $P "box:$BOX"; row $P 51 claimed "" 900 500; tick $P
[ "$RC" = 0 ] && [ ! -s "$T/withdraws.txt" ] && ok "B7 near miss: lease out 500 s < 600 s -> live, no withdraw" || bad "B7 near miss rc $RC"
reset; place $P fly; row $P 52 claimed "" 900 900; tick $P
[ "$RC" = 0 ] && [ ! -s "$T/withdraws.txt" ] && ok "B7 the same row on a fly placement: live (no change)" || bad "B7 fly rc $RC"

echo "B8: undo"
reset; place $P "box:$BOX"; row $P 60 queued "" 700; tick $P
[ -e "$D/$P.placed" ] && [ -e "$D/$P.box-down" ] || bad "B8 setup: $(ls "$D")"
place $P hub; tick $P
[ "$RC" = 1 ] && [ ! -e "$D/$P.placed" ] && [ ! -e "$D/$P.box-down" ] && ok "B8 hub row: rc 1, .placed and .box-down removed" || bad "B8 rc $RC $(ls "$D")"

echo "B9: no no-capacity streak line on a box placement"
reset; place $P "box:$BOX"; echo 1 > "$T/settings/mc_project_fly.nocap_alert_n"
for id in 70 71 72; do rm -f "$D/$P.nocap-at"; row $P "$id" queued "" 700; tick $P; done
grep -q 'no-capacity cycles in a row' "$H/logs/ALERTS.log" && bad "B9 a streak line: $(cat "$H/logs/ALERTS.log")" || ok "B9 0 streak lines"
reset; place $P fly; echo 1 > "$T/settings/mc_project_fly.nocap_alert_n"; row $P 73 queued "" 700; tick $P
grep -q 'no-capacity cycles in a row' "$H/logs/ALERTS.log" && [ "$(boxlines $P)" = 0 ] \
  && ok "B9 control: a fly placement writes the streak line and no box line" || bad "B9 control: $(cat "$H/logs/ALERTS.log")"

echo "B10: mc_proj_none_fly"
nf() {
  mkdir -p "$H/state"
  jq -nc --argjson f "$(date -u +%s)" --arg v "$1" '{fetched_at:$f, values:{"lane_placement.merge-conductor.project-6-os":$v}}' > "$H/state/settings-cache.json"
  HARNESS="$H" bash -c ". \"$H/bin/lib/mc/project-placement.sh\"; mc_proj_none_fly"
}
reset
nf hub; [ "$?" = 0 ] && ok "B10 hub only: skip the gate" || bad "B10 hub: rc 1"
nf " Box:$BOX"; [ "$?" = 1 ] && ok "B10 a box: value: gate" || bad "B10 box: rc 0"

# ============================================================================
echo "P1: the snapshot backstop publishes a project placed box"
PB="$T/p"; mkdir -p "$PB/bin/lib" "$PB/logs" "$T/pset"
cp "$DIR/bin/lane-snapshot-publish.sh" "$PB/bin/"
( cd "$DIR" && scratch_install_closure bin/lib/lane-placement.sh "$PB" ) >/dev/null 2>&1 || bad "setup: closure of lane-placement.sh failed"
cat > "$PB/bin/jobs-client.sh" <<EOF
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/pset/\$1" ] || return 2; cat "$T/pset/\$1"; }
_jobs_req() { return 1; }
EOF
printf 'pl_name_ok() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }\n' > "$PB/bin/lib/project-lanes.sh"
printf 'alr_apply() { echo "alert lines: 0 replayed"; }\n' > "$PB/bin/lib/alert-line-remote.sh"
cat > "$PB/bin/lib/lane-run-inputs.sh" <<EOF
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; }
lri_publish() { echo "publish \$1 \$2" >> "$T/published.txt"; echo "published 000000000000 1"; }
EOF
printf 'box:%s' "$BOX" > "$T/pset/lane_placement.merge-conductor.$P"
printf 'hub' > "$T/pset/lane_placement.merge-conductor.other"
HARNESS="$PB" bash "$PB/bin/lane-snapshot-publish.sh" --lane merge-conductor "$P" other > "$T/pub.out" 2>&1
[ "$(cat "$T/published.txt" 2>/dev/null)" = "publish merge-conductor $P" ] && ok "P1 lri_publish ran once, for $P only" \
  || bad "P1 published: $(cat "$T/published.txt" 2>/dev/null) out: $(cat "$T/pub.out")"
rm -f "$T/published.txt"
HARNESS="$PB" bash "$PB/bin/lane-snapshot-publish.sh" --lane blocked-resolver "$P" > "$T/pub.out" 2>&1
[ ! -e "$T/published.txt" ] && ok "P1 another lane: a box: row of merge-conductor publishes nothing" || bad "P1 blocked-resolver published: $(cat "$T/published.txt")"

# ============================================================================
# Part B
echo "Part B: the real jobs worker"
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "SKIP part B: node or curl missing"; echo "merge-conductor-box.bh-7636: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
KH="$T/k"
mkdir -p "$KH/bin/lib/mc" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/env"
for L in bin/lane-run-worker.sh bin/project-lane-run.sh bin/jobs-client.sh bin/lib/lane-placement.sh \
         bin/lib/mc/project-placement.sh bin/lib/mc/fly-workers.sh bin/lib/lane-run-inputs.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$KH" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
scratch_rm "$KH/catalog/lane-run-inputs.d"
: > "$KH/env/global.env"
printf '%s example-org/project-6 - - 1 %s\n' "$P" "$BOX" > "$KH/fleet.conf"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$KH" > "$KH/bin/lane-alert.sh"
# The recorder: the box run of the project entry.
cat > "$KH/bin/merge-conductor-project.sh" <<EOF
#!/usr/bin/env bash
echo "machine \$* run=\${LANE_RUN_ID:-}" >> "$T/recorder.txt"
echo "PROF mc-project state=OK landed=0 queued=0 deferred=- fence=1"
EOF
chmod +x "$KH/bin/"*.sh
for f in "$KH/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done
cat >> "$KH/bin/lib/lane-run-inputs.sh" <<EOF
lri_apply_pending() { echo "apply \$2" >> "$T/events.txt"; echo "applied=0 conflicts=0 rejected=0"; }
lri_publish() { echo "publish \$2" >> "$T/events.txt"; echo "published 000000000000 1"; }
EOF

SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
trap 'kill "$SPID" 2>/dev/null' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP part B: node:sqlite unavailable"; echo "merge-conductor-box.bh-7636: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
W="http://127.0.0.1:$PORT"
setting() { curl -sS -X PUT "$W/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
mcrows() { curl -sS -H "authorization: Bearer fixture-harness-secret" \
  "$W/api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=$P&limit=50" | jq -c --arg p "$P" '[.rows[] | select(.project == $p)]'; }
ENVS=(HARNESS="$KH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0
  JOBS_OVERLOAD_RETRIES=0 BOX_NAME=hub-fixture FLEET_CONF="$KH/fleet.conf")
gate() {
  env "${ENVS[@]}" bash -c ". \"$KH/bin/jobs-client.sh\"; . \"$KH/bin/lib/mc/fly-workers.sh\"; mc_fly_project_gate $P" 2>>"$T/kgate.log"
}

echo "B2: placed on the box, the hub enqueues and the box runs"
setting "lane_placement.merge-conductor.$P" "box:$BOX"
hub_ticks=0
for _ in 1 2 3 4 5; do gate || hub_ticks=$((hub_ticks + 1)); done
[ "$hub_ticks" = 0 ] && ok "B2 5 gate ticks: 0 hub ticks (rc 0 each)" || bad "B2 $hub_ticks gate ticks answered a hub tick: $(tail -5 "$T/kgate.log")"
R=$(mcrows)
[ "$(jq length <<<"$R")" = 1 ] && [ "$(jq -r '.[0].status' <<<"$R")" = queued ] && ok "B2 exactly one queued row" || bad "B2 rows: $R"
grep -q "$P project-box($BOX): enqueued merge-conductor $P" "$T/kgate.log" && ok "B2 the gate logs project-box($BOX): enqueued" \
  || bad "B2 gate log: $(cat "$T/kgate.log")"
[ "$(head -1 "$T/events.txt" 2>/dev/null)" = "apply $P" ] && grep -q "^publish $P" "$T/events.txt" \
  && ok "B2 the hub applied and published before the enqueue" || bad "B2 events: $(cat "$T/events.txt" 2>/dev/null)"
env "${ENVS[@]}" "$KH/bin/lane-run-worker.sh" --once --machine m1 > "$T/fly.out" 2>&1; frc=$?
[ "$frc" = 0 ] && [ "$(jq -r '.[0].status' <<<"$(mcrows)")" = queued ] && [ ! -e "$T/recorder.txt" ] \
  && ok "B2 a Fly worker claims nothing (rc 0, row queued)" || bad "B2 fly worker rc $frc rows $(mcrows) $(cat "$T/fly.out")"
env "${ENVS[@]}" "$KH/bin/lane-run-worker.sh" --once --box "$BOX" > "$T/box.out" 2>&1; brc=$?
R=$(mcrows)
[ "$brc" = 0 ] && ok "B2 the box worker exits 0" || bad "B2 box worker rc $brc: $(cat "$T/box.out")"
# project-lane-run.sh appends the project to the args, so the entry sees it twice.
grep -q "^machine $P $P run=$(jq -r '.[0].id' <<<"$R")$" "$T/recorder.txt" 2>/dev/null && ok "B2 the box ran bin/merge-conductor-project.sh $P for the row" \
  || bad "B2 recorder: $(cat "$T/recorder.txt" 2>/dev/null); log: $(tail -5 "$KH/logs/lane-run-worker.log" 2>/dev/null)"
[ "$(jq -r '.[0].status' <<<"$R")" = done ] && [ "$(jq -r '.[0].claimed_by' <<<"$R")" = "$BOX" ] && [ "$(jq -r '.[0].rc' <<<"$R")" = 0 ] \
  && ok "B2 the row is done, rc 0, claimed_by $BOX" || bad "B2 row: $R"
grep -q "$BOX: run $(jq -r '.[0].id' <<<"$R") merge-conductor/$P rc 0: reported" "$KH/logs/lane-run-worker.log" \
  && ok "B2 the box's log line names the run" || bad "B2 worker log: $(cat "$KH/logs/lane-run-worker.log")"
gate; grc=$?
[ "$grc" = 0 ] && [ "$(jq length <<<"$(mcrows)")" = 2 ] && ok "B2 after a done row the next tick enqueues the next row" || bad "B2 next tick rc $grc rows $(mcrows)"

echo "B8b: undo on the real worker"
setting "lane_placement.merge-conductor.$P" hub
env "${ENVS[@]}" "$KH/bin/lane-run-worker.sh" --once --box "$BOX" > "$T/box2.out" 2>&1
[ "$(jq -r '.[0].status' <<<"$(mcrows)")" = queued ] && ok "B8b after undo the box claims nothing" || bad "B8b rows $(mcrows)"

echo "W1: --box with a bad name"
n0=$(grep -c 'lane-runs/claim' "$T/srv.log")
env "${ENVS[@]}" "$KH/bin/lane-run-worker.sh" --once --box 'Bad/Name' > "$T/w1.out" 2>&1; wrc=$?
[ "$wrc" = 2 ] && [ "$(grep -c 'lane-runs/claim' "$T/srv.log")" = "$n0" ] && ok "W1 exit 2, no claim sent" || bad "W1 rc $wrc: $(cat "$T/w1.out")"

echo "W2: a claim answer that does not name the box"
curl -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
  -d '{"machine":"m-old"}' "$W/api/lane-runs/claim" > "$T/w2-claim.json"
WID=$(jq -r '.id // empty' "$T/w2-claim.json")
jq -c '{path_prefix:"/api/lane-runs/claim", status:200, body:(. | del(.box) | tojson)}' "$T/w2-claim.json" > "$T/w2-answer.json"
curl -sS -X PUT "$W/__answer" -d @"$T/w2-answer.json" >/dev/null
rm -f "$T/recorder.txt"
env "${ENVS[@]}" "$KH/bin/lane-run-worker.sh" --once --box "$BOX" > "$T/w2.out" 2>&1; wrc=$?
curl -sS -X PUT "$W/__answer" -d '{}' >/dev/null
[ -n "$WID" ] && [ "$wrc" = 1 ] && [ ! -e "$T/recorder.txt" ] && ok "W2 exit 1, the row is not run" || bad "W2 id '$WID' rc $wrc recorder $(cat "$T/recorder.txt" 2>/dev/null): $(cat "$T/w2.out")"
grep -q "POST /api/lane-runs/$WID/release" "$T/srv.log" && grep -q "row $WID not run" "$KH/logs/lane-run-worker.log" \
  && ok "W2 the worker posts the release and logs it" || bad "W2 srv: $(tail -3 "$T/srv.log") log: $(tail -2 "$KH/logs/lane-run-worker.log")"

echo
echo "merge-conductor-box.bh-7636: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
