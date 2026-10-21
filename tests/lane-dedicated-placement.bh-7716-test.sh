#!/bin/bash
# tests/lane-dedicated-placement.bh-7716-test.sh — BH-7716: the placement value
# `fly-dedicated` on the hub (acceptance (a): with
# lane_placement.merge-conductor=fly-dedicated the hub cron does not start the
# lane, and the machine does).
#
# Part A runs the REAL bin/lib/lane-placement.sh in a fresh process per case.
# Only the settings I/O is a stub: setting_get reads $T/settings/<key> (rc 2
# when the file is absent, rc 1 when $T/outage exists). The same table is read
# by worker/jobs/test/lane-dedicated.bh-7716.test.js.
#
#   P1  every row of tests/fixtures/bh-7716/dedicated-placement-cases.tsv
#       through lp_decide: LP_PLACE, LP_BOX and a substring of LP_WHY
#   P1b a settings outage is hub (`settings unreadable`)
#   P1c mc_proj_none_fly: a fly-dedicated value in the settings cache gates
#
# Part B drives the REAL jobs worker (tests/lib/lane-runs-worker.bh-6124.mjs)
# through the real pl_dispatch and the real bin/lane-run-worker.sh.
#
#   P5  lane_placement.blocked-resolver=fly-dedicated: pl_dispatch (the
#       `blocked-resolver --dispatch` runner) enqueues 3 rows and starts 0
#       hub runs; a Fly worker claims none; the dedicated machine loop
#       (--box fly-dedicated --machine mid1-w2) runs all 3; rollback to hub:
#       3 hub runs and 0 rows
#
# Part C drives the REAL bin/merge-conductor.sh hub tick over 2 projects
# (the K1 fixture of tests/merge-conductor-project.bh-6890-test.sh: one READY
# PR #31 on a Mergify repo; `gh` is a stub that records each call).
#
#   P2  lane_placement.merge-conductor=fly-dedicated, a full tick: 2 rows
#       (one per project), 0 PR list reads, 0 Mergify writes, 0 merges, 0
#       local workers, and the log names project-box(fly-dedicated)
#   P3  a keyed tick (MC_ONLY_PR=<slug>#31) returns at the project gate:
#       0 PR list reads, 0 writes
#   P4  rollback: the row set to hub, the same tick works #31 on the hub
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-dedicated-placement.bh-7716-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
CASES="$DIR/tests/fixtures/bh-7716/dedicated-placement-cases.tsv"
[ -r "$CASES" ] || { echo "FAIL: no case table $CASES"; exit 1; }

# ============================================================================
# Part A
cat > "$T/stubs.sh" <<EOF
_lp_client() { return 0; }
_jobs_req() { echo "_jobs_req \$*" >> "$T/jobs-calls.txt"; return 1; }
_setting_key_ok() { case "\${1:-}" in ''|*[!a-z0-9_.-]*) return 1 ;; esac; [ "\${#1}" -le 64 ]; }
setting_get() { [ -e "$T/outage" ] && return 1; [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
EOF
decide() {
  bash -c '. "$1/bin/lib/lane-placement.sh" || exit 9; . "$2" || exit 9
    LP_BOX=stale-from-before
    lp_decide "$3" "$4"; printf "%s|%s|%s" "$LP_PLACE" "${LP_BOX:-}" "$LP_WHY"' _ "$DIR" "$T/stubs.sh" "$1" "$2"
}

echo "P1: every row of the case table"
n=0
while IFS=$'\t' read -r lane proj rows lanes place box why; do
  case "$lane" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  scratch_rm "$T/settings"; mkdir -p "$T/settings"
  IFS=$'\001' read -r -a kvs <<<"${rows//;;/$'\001'}"
  for kv in "${kvs[@]}"; do printf '%b' "${kv#*=}" > "$T/settings/${kv%%=*}"; done
  case "$lanes" in -) ;; '~') : > "$T/settings/lane_dedicated.lanes" ;; *) printf '%s' "$lanes" > "$T/settings/lane_dedicated.lanes" ;; esac
  [ "$proj" = - ] && proj=""
  [ "$box" = - ] && box=""
  got=$(decide "$lane" "$proj")
  gp=${got%%|*}; rest=${got#*|}; gb=${rest%%|*}; gw=${rest#*|}
  label="row $n: $rows lanes=$lanes (lane $lane, project ${proj:-none})"
  if [ "$gp" = "$place" ] && [ "$gb" = "$box" ] && [[ "$gw" == *"$why"* ]]; then
    ok "$label -> $place${box:+ $box}"
  else
    bad "$label -> got place=$gp box=$gb why=$gw; want place=$place box=$box why~$why"
  fi
done < "$CASES"
[ "$n" -ge 20 ] && ok "P1 read $n rows" || bad "P1 read only $n rows"
[ ! -s "$T/jobs-calls.txt" ] && ok "P1 no jobs request" || bad "P1 jobs calls: $(cat "$T/jobs-calls.txt")"

echo "P1b: a settings outage"
scratch_rm "$T/settings"; mkdir -p "$T/settings"
printf 'fly-dedicated' > "$T/settings/lane_placement.merge-conductor"
touch "$T/outage"
got=$(decide merge-conductor project-5)
rm -f "$T/outage"
[ "${got%%|*}" = hub ] && [[ "$got" == *"settings unreadable"* ]] && ok "P1b outage -> hub, settings unreadable" || bad "P1b got $got"
# The allow-list read alone fails: hub, never the box.
cat > "$T/stubs2.sh" <<EOF
. "$T/stubs.sh"
setting_get() { [ "\$1" = lane_dedicated.lanes ] && return 1; [ -e "$T/settings/\$1" ] || return 2; cat "$T/settings/\$1"; }
EOF
got=$(bash -c '. "$1/bin/lib/lane-placement.sh"; . "$2"; lp_decide merge-conductor project-5; printf "%s|%s|%s" "$LP_PLACE" "${LP_BOX:-}" "$LP_WHY"' _ "$DIR" "$T/stubs2.sh")
[ "${got%%|*}" = hub ] && [[ "$got" == *"settings unreadable"* ]] && ok "P1b allow-list outage -> hub" || bad "P1b allow-list outage got $got"

echo "P1c: mc_proj_none_fly"
NH="$T/nf"; mkdir -p "$NH/bin/lib/mc" "$NH/state"
( cd "$DIR" && scratch_install_closure bin/lib/mc/project-placement.sh "$NH" ) >/dev/null 2>&1 || bad "setup: closure of project-placement.sh failed"
nf() {
  jq -nc --argjson f "$(date -u +%s)" --arg k "$1" --arg v "$2" '{fetched_at:$f, values:{($k):$v}}' > "$NH/state/settings-cache.json"
  HARNESS="$NH" bash -c ". \"$NH/bin/lib/mc/project-placement.sh\"; mc_proj_none_fly"
}
nf lane_placement.merge-conductor hub; [ "$?" = 0 ] && ok "P1c hub only: the tick skips the gate" || bad "P1c hub: rc 1"
nf lane_placement.merge-conductor " Fly-Dedicated "; [ "$?" = 1 ] && ok "P1c a fly-dedicated lane row: gate" || bad "P1c fly-dedicated lane row: rc 0"
nf lane_placement.merge-conductor.project-5 fly-dedicated; [ "$?" = 1 ] && ok "P1c a fly-dedicated project row: gate" || bad "P1c project row: rc 0"

# ============================================================================
# Part B
echo "Part B: pl_dispatch and the dedicated machine loop"
command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || { echo "SKIP part B and C: node or curl missing"; echo "lane-dedicated-placement.bh-7716: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
BH="$T/b"
mkdir -p "$BH/bin" "$BH/logs" "$BH/locks" "$BH/state" "$BH/env" "$BH/flags"
for L in bin/project-lane-run.sh bin/lib/project-lanes.sh bin/lane-run-worker.sh bin/fleet-conf.sh \
         bin/jobs-client.sh bin/alert-line.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$BH" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
for i in 1 2 3; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$i" "$i" "$i" "$i"; done > "$BH/fleet.conf"
cat > "$BH/bin/fake-br.sh" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\${@: -1}" "\${LANE_RUN_ID:-hub}" >> "$T/br-runs.tsv"
echo "PROF fake-br ok"
EOF
chmod +x "$BH/bin/"*.sh 2>/dev/null
SPIDS=()
trap 'for p in "${SPIDS[@]}"; do kill "$p" 2>/dev/null; done' EXIT
: > "$T/w1.log"; : > "$T/w1.port"
node "$DIR/tests/lib/lane-runs-worker.bh-6124.mjs" "$T/w1.log" > "$T/w1.port" 2> "$T/w1.err" &
SPIDS+=("$!")
for _ in $(seq 1 200); do [ -s "$T/w1.port" ] && break; kill -0 "${SPIDS[0]}" 2>/dev/null || break; sleep 0.05; done
BPORT=$(head -1 "$T/w1.port")
if [ -z "$BPORT" ]; then
  wait "${SPIDS[0]}"; [ "$?" = 3 ] && { echo "SKIP part B and C: node:sqlite unavailable"; echo "lane-dedicated-placement.bh-7716: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; exit; }
  echo "setup: worker did not start: $(cat "$T/w1.err")"; exit 1
fi
BW="http://127.0.0.1:$BPORT"
BENV=(HARNESS="$BH" FLEET_CONF="$BH/fleet.conf" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$BW" GH_TOKEN=tok-fixture
  JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-hub)
bset() { curl -sS -X PUT "$BW/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
brows() { curl -sS "$BW/__lane_runs" | jq -c '[.rows[] | select(.lane == "blocked-resolver")]'; }
nhub() { awk -F'\t' '$2 == "hub"' "$T/br-runs.tsv" 2>/dev/null | grep -c .; }
WAITFOR() { local i; for i in $(seq 1 "${2:-300}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
bdispatch() {
  env "${BENV[@]}" bash -c 'H="$1"; . "$1/bin/lib/project-lanes.sh" || exit 9; pl_dispatch blocked-resolver 0 "$1/bin/fake-br.sh"; wait' _ "$BH" > "$T/dispatch.out" 2>&1
}

echo "P5: blocked-resolver placed fly-dedicated"
: > "$T/br-runs.tsv"
bset lane_placement.blocked-resolver fly-dedicated
bdispatch
grep -q "placed: 3 fly, 0 hub (lane_placement.blocked-resolver=fly-dedicated)" "$T/dispatch.out" \
  && ok "P5 pl_dispatch enqueues 3 rows for the box" || bad "P5 dispatch: $(cat "$T/dispatch.out")"
[ "$(nhub)" = 0 ] && ok "P5 0 hub runs" || bad "P5 hub runs: $(nhub)"
[ "$(brows | jq '[.[] | select(.status == "queued")] | length')" = 3 ] && ok "P5 3 queued rows" || bad "P5 rows: $(brows)"
env "${BENV[@]}" timeout 20 "$BH/bin/lane-run-worker.sh" --once --machine m1 > "$T/fly.out" 2>&1; frc=$?
[ "$frc" = 0 ] && [ "$(brows | jq '[.[] | select(.status == "queued")] | length')" = 3 ] \
  && ok "P5 a Fly worker of the default fleet claims none of them" || bad "P5 fly worker rc $frc rows $(brows) $(cat "$T/fly.out")"
env "${BENV[@]}" timeout 30 "$BH/bin/lane-run-worker.sh" --once --box fly-dedicated --machine mid1-w2 > "$T/box.out" 2>&1; drc=$?
R=$(brows)
[ "$drc" = 0 ] && [ "$(jq '[.[] | select(.status == "done" and .claimed_by == "mid1-w2" and .rc == 0)] | length' <<<"$R")" = 3 ] \
  && ok "P5 the dedicated machine loop mid1-w2 runs all 3 rows, rc 0" || bad "P5 box worker rc $drc rows $R $(cat "$T/box.out") $(tail -5 "$BH/logs/lane-run-worker.log" 2>/dev/null)"
[ "$(awk -F'\t' '$2 != "hub"' "$T/br-runs.tsv" | grep -c .)" = 3 ] && ok "P5 the 3 runs carry LANE_RUN_ID" || bad "P5 runs: $(cat "$T/br-runs.tsv")"
echo "P5: rollback to hub"
: > "$T/br-runs.tsv"; N0=$(brows | jq length)
bset lane_placement.blocked-resolver hub
bdispatch
WAITFOR '[ "$(nhub)" -ge 3 ]' && ok "P5 rollback: 3 hub runs" || bad "P5 rollback hub runs $(nhub): $(cat "$T/dispatch.out")"
[ "$(brows | jq length)" = "$N0" ] && ok "P5 rollback: 0 new rows" || bad "P5 rollback rows: $(brows)"

# ============================================================================
# Part C
echo "Part C: the real merge-conductor hub tick"
REALCURL=$(command -v curl)
NOW=$(date +%s)
KT="$T/k"; KH="$KT/h"; KB="$KT/fakebin"
mkdir -p "$KH/bin/lib/mc" "$KH/logs" "$KH/state" "$KH/flags" "$KH/locks" "$KH/builds" "$KH/env" "$KH/tmp" "$KB"
for L in bin/merge-conductor.sh bin/merge-conductor-project.sh bin/lane-run-worker.sh bin/project-lane-run.sh \
         bin/jobs-client.sh bin/lib/project-lease.sh bin/lib/lane-placement.sh bin/lib/mc/project-placement.sh \
         bin/lib/mc/fly-workers.sh bin/lane-alert.sh bin/lib/alert-line-remote.sh bin/lib/lane-run-inputs.sh \
         bin/lib/autoenqueue.sh bin/lib/merge-conductor-lib.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$KH" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
cp "$DIR/bin/fleet-conf.sh" "$KH/bin/fleet-conf.sh"
mkdir -p "$KH/catalog"; cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$KH/catalog/"
scratch_rm "$KH/catalog/lane-run-inputs.d"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure alert-line; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$(date -u +%%FT%%TZ)" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$KH" > "$KH/bin/lane-alert.sh"
chmod +x "$KH/bin/"*.sh
for f in "$KH/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done
cat >> "$KH/bin/lib/lane-run-inputs.sh" <<EOF
lri_apply_pending() { echo "applied=0 conflicts=0 rejected=0"; }
lri_publish() { echo "published 000000000000 1"; }
EOF
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
{ printf 'mgfy %s - - 2 box-m\n' "$KSLUG"; printf 'quiet example-org/quiet-os - - 2 box-q\n'; } > "$KH/fleet.conf"
: > "$KH/env/global.env"
REC="$KH/builds/pool-mgfy-MG-31-202610110001"; mkdir -p "$REC"
echo "PR_CREATED $KU/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$KHEAD" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cat > "$KT/list.json" <<J
[{"number":31,"url":"$KU/31","headRefOid":"$KHEAD","headRefName":"ticket/mg-31","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
jq -nc --arg r "$KSLUG" --arg h "$KHEAD" '[{number:31, html_url:("https://github.com/"+$r+"/pull/31"), title:"t", draft:false, state:"open",
  updated_at:"2026-10-11T00:00:00Z", created_at:"2026-10-10T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
  head:{sha:$h, ref:"ticket/mg-31", repo:{full_name:$r}}, base:{ref:"main", repo:{full_name:$r}}}]' > "$KT/rest-list.json"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# The gh stub: every call is a line in calls.txt, every PR list read a line in
# lists.txt, every Mergify write a line in cmds.txt, every merge one in merges.txt.
cat > "$KB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$KT/calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo fixture-token ;;
  *"api -i -X GET repos/$KSLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$KSLUG/commits/main"*|*"api -i -X GET repos/$KSLUG/git/ref/heads/main"*) restpr --raw 200 '{"sha":"$KMAIN","object":{"sha":"$KMAIN"}}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":2,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-11T10:00:00Z"},{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":"In merge queue"},"app":{"slug":"mergify"}}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*) restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$KT/merges.txt"; exit 1 ;;
  *"issue close"*|*"-X PATCH repos/"*"/issues/"*) printf '%s\n' "\$*" >> "$KT/closes.txt" ;;
  *"api -i -X GET repos/$KSLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*|*"api --paginate repos/"*"/reviews"*) echo '[]' ;;
  *"api repos/"*"/comments --paginate"*) : ;;
  *"api repos/$KSLUG/issues/31"*) printf '{"number":31,"state":"open","labels":[],"body":""}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$KSLUG/pulls/31"*) restpr OPEN "$KHEAD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*) printf 'list mgfy\n' >> "$KT/lists.txt"; restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) printf 'list other\n' >> "$KT/lists.txt"; restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) printf 'list mgfy\n' >> "$KT/lists.txt"; cat "$KT/list.json" ;;
  *"pr list"*) printf 'list other\n' >> "$KT/lists.txt"; echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdict\?*) printf '{"error":"not found"}\n404\n'; exit 0 ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n'; exit 0 ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n'; exit 0 ;;
esac
exec "$REALCURL" "\$@"
EOF
chmod +x "$KB/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"

SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPIDS+=("$!")
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "${SPIDS[1]}" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
[ -n "$PORT" ] || { echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1; }
W="http://127.0.0.1:$PORT"
setting() { "$REALCURL" -sS -X PUT "$W/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
mcrows() { "$REALCURL" -sS -H "authorization: Bearer fixture-harness-secret" \
  "$W/api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=$1&limit=50" | jq -c --arg p "$1" '[.rows[] | select(.project == $p)]'; }
ENVS=(PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" GH_TOKEN=pat-fixture
  JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0
  MC_REHYDRATE=0 MC_LAND_REBASE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf")
htick() { ( cd "$KT" && env "${ENVS[@]}" "$@" bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  scratch_rm "$KH/locks"; mkdir -p "$KH/locks"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KH/logs/merge-conductor.log"; : > "$KT/calls.txt"; : > "$KH/logs/ALERTS.log"
  rm -f "$KT/cmds.txt" "$KT/merges.txt" "$KT/closes.txt" "$KT/lists.txt"
}
KLOG="$KH/logs/merge-conductor.log"
klog() { tail -8 "$KLOG" 2>/dev/null; }
nowork() {
  [ ! -s "$KT/lists.txt" ] && ok "$1 0 PR list reads" || bad "$1 PR list reads: $(cat "$KT/lists.txt"); log: $(klog)"
  [ ! -s "$KT/cmds.txt" ] && ok "$1 0 Mergify writes" || bad "$1 writes: $(cat "$KT/cmds.txt")"
  [ ! -s "$KT/merges.txt" ] && ok "$1 0 merges" || bad "$1 merges: $(cat "$KT/merges.txt")"
  ! grep -qE 'worker (start|spawn)|mc_worker_bounded' "$KLOG" && ok "$1 0 local PR workers" || bad "$1 workers: $(grep -E 'worker' "$KLOG" | head -3)"
}

echo "P2: lane_placement.merge-conductor=fly-dedicated, a full hub tick"
kreset
setting lane_placement.merge-conductor fly-dedicated
htick
for p in mgfy quiet; do
  R=$(mcrows "$p")
  [ "$(jq -c '[.[] | [.lane, .project, .status]]' <<<"$R")" = "[[\"merge-conductor\",\"$p\",\"queued\"]]" ] \
    && ok "P2 one queued merge-conductor row for $p" || bad "P2 rows of $p: $R; log: $(klog) $(tail -3 "$KT/tick.err")"
  grep -q "$p project-box(fly-dedicated): enqueued merge-conductor $p" "$KLOG" && ok "P2 the log names project-box(fly-dedicated) for $p" \
    || bad "P2 log for $p: $(klog)"
done
nowork P2

echo "P3: a keyed tick returns at the project gate"
: > "$KT/lists.txt"; : > "$KT/calls.txt"
htick MC_ONLY_PR="$KSLUG#31"
nowork P3
[ "$(mcrows mgfy | jq length)" = 1 ] && ok "P3 still one row for mgfy (the live row is owed)" || bad "P3 rows: $(mcrows mgfy)"

echo "P4: rollback — the row set to hub"
kreset
setting lane_placement.merge-conductor hub
htick MC_ONLY_PR="$KSLUG#31"
grep -q "$KSLUG#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok "P4 the hub works #31 again" \
  || bad "P4 not enqueued: $(klog) $(tail -3 "$KT/tick.err")"
[ -s "$KT/lists.txt" ] && ok "P4 the hub reads the PR list again" || bad "P4 no list read"

echo
echo "lane-dedicated-placement.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
