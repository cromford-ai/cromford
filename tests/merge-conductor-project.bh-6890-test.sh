#!/bin/bash
# tests/merge-conductor-project.bh-6890-test.sh — BH-6890 (BH-6881.6): the
# merge conductor for one whole project on a lane-run machine, under the
# project lease, with the hub fallback row.
#
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/mc-budget.bh-6887.mjs: lane_runs, project_leases and settings
# routes, plus the /__setting and /__lease hooks), through the real
# bin/merge-conductor.sh tick, bin/merge-conductor-project.sh,
# bin/lane-run-worker.sh and bin/project-lane-run.sh. The repo is the K1
# fixture of tests/conductor-machine-lands-nothing.bh-6495-test.sh: one READY
# PR #31 on a Mergify repo. `gh` is a stub; `curl` is a wrapper that answers
# the verdict and lead reads like that fixture and passes every other request
# to the real worker, writing one events line per project-lease call.
#
#   P0  control: placement hub (no project row) — the hub tick works #31 as
#       today (it enqueues it), and no merge-conductor row is enqueued
#   P1  placement fly for mgfy: a hub tick enqueues exactly ONE lane_runs row
#       (lane merge-conductor, project mgfy, args
#       [bin/merge-conductor-project.sh, mgfy]) and does no PR work for mgfy
#       (no PR list read, no enqueue)
#   P2  a second hub tick while that row is live enqueues 0 rows and keeps
#       one owed line
#   P3  fallback off and a stale row: exactly ONE ALERTS line over two ticks,
#       and the hub does no PR work for mgfy. Control: fallback hub and the
#       same stale row run the hub tick (fallback=no-capacity)
#   P4  the machine path: bin/merge-conductor-project.sh mgfy acquires the
#       lease, and #31 reaches the Mergify enqueue only after a renew with
#       the fence it holds; PROF state=QUEUED queued=1; the lease is released
#       after. Control: MC_ON_MACHINE=1 without MC_LEASED_RUN still answers
#       deferred=land and writes nothing
#   P5  a lost fence (another holder takes the lease before the first
#       renew): nothing is written, PROF state=LEASE_LOST, the run ends
#   P6  TERM to bin/lane-run-worker.sh during a project run: the project
#       lease is released, the row returns to queued, the entry logs the stop
#   P7  lane-placement order: the project row wins over the lane row, no
#       project row reads the lane row, a lane-only caller is unchanged
#   P8  lane-alert.sh on a lane-run machine posts its line to
#       /api/alert-lines and writes no local ALERTS.log line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-project.bh-6890-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
[ -f "$DIR/catalog/lanes.json" ] || HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --write >/dev/null \
  || { echo "FAIL: cannot compose catalog/lanes.json"; exit 1; }
SRV="$DIR/tests/lib/mc-budget.bh-6887.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v flock >/dev/null 2>&1 || { echo "SKIP: node, jq, curl or flock missing"; exit 0; }
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
# No lane-run-inputs manifest in this root: lri_fetch and lri_checkpoint have
# nothing to carry, so the worker runs the row (the snapshot is
# tests/lane-run-inputs-mc-manifest.bh-6889-test.sh's subject).
scratch_rm "$KH/catalog/lane-run-inputs.d"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure alert-line; do printf '#!/bin/bash\nexit 0\n' > "$KH/bin/$s.sh"; done
# The hub's lane-alert: one ALERTS.log line per call (the real one is P8's).
mv "$KH/bin/lane-alert.sh" "$KH/bin/lane-alert.real.sh"
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$(date -u +%%FT%%TZ)" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' "$KH" > "$KH/bin/lane-alert.sh"
chmod +x "$KH/bin/"*.sh
# The scripts' #!/bin/bash is bash 3.2 on a Mac; the harness needs bash 4+.
# env bash is the same bash on a Linux box.
for f in "$KH/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done
# The hub's apply and publish of this lane are recorded, not run: this root
# has no merge-conductor manifest (the apply itself is
# tests/lane-run-inputs-rows.bh-6884-test.sh's subject). $KT/apply-fail makes
# the apply fail.
cat >> "$KH/bin/lib/lane-run-inputs.sh" <<EOF
lri_apply_pending() { echo "apply \$2" >> "$KT/events.txt"; [ -e "$KT/apply-fail" ] && { echo "applied=0 conflicts=0 rejected=0 (lock busy)"; return 1; }; echo "applied=1 conflicts=0 rejected=0"; }
lri_publish() { echo "publish \$2" >> "$KT/events.txt"; echo "published 000000000000 1"; }
EOF
cp "$DIR/tests/lib/rest-emit.sh" "$KB/restpr"; chmod +x "$KB/restpr"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
KSLUG=example-org/mgfy-os; KHEAD=$(printf 'a%.0s' {1..40}); KMAIN=$(printf 'd%.0s' {1..40}); KU="https://github.com/$KSLUG/pull"
printf 'mgfy %s - - 2 box-m\n' "$KSLUG" > "$KH/fleet.conf"
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
# The gh stub. A list read of the repo's open PRs blocks while $KT/block exists
# (P6), and is written to $KT/lists.txt. Every Mergify write is an `enqueue`
# event in $KT/events.txt, after the lease events the curl wrapper writes.
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
  *"api -X POST repos/"*"/issues/"*"/comments"*|*"api -X POST repos/"*"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; echo enqueue >> "$KT/events.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$KT/cmds.txt"; echo enqueue >> "$KT/events.txt"; restpr --raw 201 '{"id":1}' ;;
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
  *"api -i -X GET repos/$KSLUG/pulls?state=open"*)
     printf 'list\n' >> "$KT/lists.txt"; echo list >> "$KT/events.txt"
     i=0; while [ -e "$KT/block" ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i+1)); done
     restpr --raw 200 "\$(cat "$KT/rest-list.json")" ;;
  *"api -i -X GET repos/"*"/pulls?state=open"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*|*"api -i -X GET repos/"*"/pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"api repos/$KSLUG -q .id"*) echo 1 ;;
  *"pr list -R $KSLUG --state open"*) printf 'list\n' >> "$KT/lists.txt"; cat "$KT/list.json" ;;
  *"pr list"*) echo '[]' ;;
esac
exit 0
EOF
chmod +x "$KB/gh"
# The curl wrapper: the fixture's verdict and lead answers, then the real
# worker. A project-lease call writes `lease <op> <fence>` to events.txt; with
# $KT/steal present, the FIRST renew is preceded by another holder taking the
# lease (P5).
cat > "$KB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/lead-protected-paths*) "$KB/lpp-answer" GET "\$URL"; exit 0 ;;
  */api/verdict\?*) if [ -s "$KT/ledger.json" ]; then printf '%s\n200\n' "\$(cat "$KT/ledger.json")"; else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n'; exit 0 ;;
  */api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"lead-fixture-bot"}}\n200\n'; exit 0 ;;
  */api/lane-runs)
    prev=""; for a in "\$@"; do [ "\$prev" = --data-binary ] && printf '%s\n' "\$a" >> "$KT/rows.txt"; prev="\$a"; done ;;
  */api/project-leases/*)
    op="\${URL##*/}"; body=""; prev=""
    for a in "\$@"; do [ "\$prev" = --data-binary ] && body="\$a"; prev="\$a"; done
    if [ "\$op" = renew ] && [ -e "$KT/steal" ]; then
      rm -f "$KT/steal"
      "$REALCURL" -sS -X POST "\${URL%/api/*}/__lease" -d '{"lane":"merge-conductor","project":"mgfy","holder":"other","fence":99,"lease_until":"2099-01-01T00:00:00Z"}' >/dev/null
    fi
    printf 'lease %s %s\n' "\$op" "\$(printf '%s' "\$body" | jq -r '.fence // "-"' 2>/dev/null)" >> "$KT/events.txt" ;;
esac
exec "$REALCURL" "\$@"
EOF
chmod +x "$KB/curl"
# TEST-CHANGE BH-4148 (the fixture's): the lead reads protected paths from
# the jobs route; the fixture repo has no rows.
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$KT/lpp.json" "$KSLUG"
lpp_install "$KB" "$KT/lpp.json" "$KT/lpp-down"
touch "$KH/flags/merge-conductor-actions" "$KH/flags/merge-conductor-merge"

# ---- the worker -------------------------------------------------------------
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
trap 'kill "$SPID" 2>/dev/null; rm -f "$KT/block"' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
W="http://127.0.0.1:$PORT"
setting() { "$REALCURL" -sS -X PUT "$W/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
lease() { "$REALCURL" -sS "$W/__lease?lane=merge-conductor&project=mgfy"; }
mcrows() { "$REALCURL" -sS -H "authorization: Bearer fixture-harness-secret" \
  "$W/api/lane-runs/by-prefix?lane=merge-conductor&project_prefix=mgfy&limit=50" | jq -c '[.rows[] | select(.project == "mgfy")]'; }
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }

ENVS=(PATH="$KB:$PATH" HARNESS="$KH" HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" GH_TOKEN=pat-fixture
  JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0
  MC_REHYDRATE=0 MC_LAND_REBASE=0 PR_SNAPSHOT=0 MC_TICK_SECS=0 FLEET_CONF="$KH/fleet.conf")
# htick [VAR=val...] — one hub keyed tick of #31.
htick() { ( cd "$KT" && env "${ENVS[@]}" MC_ONLY_PR="$KSLUG#31" "$@" bash "$KH/bin/merge-conductor.sh" >/dev/null 2>"$KT/tick.err" ); }
# prun — the machine entry, run directly (no LANE_RUN_ID: no write-back).
prun() { ( cd "$KT" && env "${ENVS[@]}" FLY_MACHINE_ID=m1 MC_PROJECT_RENEW_S=60 bash "$KH/bin/merge-conductor-project.sh" mgfy ) > "$KT/prun.out" 2> "$KT/prun.err"; }
kreset() {
  scratch_rm "$KH/state/merge-conductor"
  # A timer `sleep` of an earlier worker can still hold a PR lock's fd; a new
  # lock file is a new lock.
  scratch_rm "$KH/locks"; mkdir -p "$KH/locks"
  mkdir -p "$KH/state/merge-conductor/prequeue"
  printf 'green %s 1 -\n' "$NOW" > "$KH/state/merge-conductor/prequeue/example-org_mgfy-os_31_${KHEAD}_${KMAIN}"
  : > "$KH/logs/merge-conductor.log"; : > "$KT/calls.txt"; : > "$KH/logs/ALERTS.log"
  rm -f "$KT/rows.txt" "$KT/cmds.txt" "$KT/merges.txt" "$KT/closes.txt" "$KT/ledger.json" "$KT/events.txt" "$KT/lists.txt" "$KT/steal" "$KT/block"
}
KLOG="$KH/logs/merge-conductor.log"
klog() { tail -8 "$KLOG" 2>/dev/null; }
nowork() { # nowork <case> — the hub did no PR work for mgfy
  [ ! -s "$KT/lists.txt" ] && ok "$1 no PR list read of mgfy" || bad "$1 the hub read the PR list: $(klog)"
  [ ! -s "$KT/cmds.txt" ] && ok "$1 no enqueue" || bad "$1 writes: $(cat "$KT/cmds.txt")"
}
ALERTN() { grep -c 'mc-project-fly-mgfy' "$KH/logs/ALERTS.log" 2>/dev/null; }

# ============================================================================
echo "P0: control — placement hub: today's hub tick"
kreset
htick
grep -q "$KSLUG#31 enqueued in the mergify merge queue at ${KHEAD:0:8}" "$KLOG" && ok "P0 the hub enqueues #31" \
  || bad "P0 not enqueued: $(klog) $(tail -3 "$KT/tick.err")"
[ "$(mcrows | jq length)" = 0 ] && ok "P0 no merge-conductor row" || bad "P0 rows: $(mcrows)"
! grep -q 'project-fly' "$KLOG" && ok "P0 no project-fly line" || bad "P0 log: $(grep project-fly "$KLOG")"

# ============================================================================
echo "P1: placement fly — one row, no hub PR work"
kreset
setting lane_placement.merge-conductor.mgfy fly
htick
R=$(mcrows)
[ "$(jq length <<<"$R")" = 1 ] && ok "P1 exactly one merge-conductor row" || bad "P1 rows: $R; log: $(klog)"
[ "$(jq -c '.[0] | [.lane, .project, .status]' <<<"$R")" = '["merge-conductor","mgfy","queued"]' ] && ok "P1 lane merge-conductor, project mgfy, queued" || bad "P1 row: $R"
A=$(jq -c 'select(.lane == "merge-conductor") | .args' "$KT/rows.txt" 2>/dev/null | tail -1)
[ "$A" = '["bin/merge-conductor-project.sh","mgfy"]' ] && ok "P1 args name the project entry" || bad "P1 args: $A"
nowork P1
grep -q 'mgfy project-fly: enqueued merge-conductor mgfy' "$KLOG" && ok "P1 one enqueue line" || bad "P1 log: $(klog)"

# ============================================================================
echo "P2: a second wake while the row is live"
: > "$KT/lists.txt"
htick
[ "$(mcrows | jq length)" = 1 ] && ok "P2 still one row (0 enqueued)" || bad "P2 rows: $(mcrows)"
[ "$(grep -c . "$KH/state/merge-conductor/project-fly/mgfy.owed" 2>/dev/null)" = 1 ] && ok "P2 one owed line" \
  || bad "P2 owed: $(cat "$KH/state/merge-conductor/project-fly/mgfy.owed" 2>/dev/null)"
nowork P2

# ============================================================================
echo "P3: fallback off and a stale row"
: > "$KT/lists.txt"; : > "$KH/logs/ALERTS.log"
setting lane_fallback.merge-conductor.mgfy off
htick MC_FLY_QUEUE_STALE_S=0
htick MC_FLY_QUEUE_STALE_S=0
[ "$(ALERTN)" = 1 ] && ok "P3 exactly one ALERTS line over two ticks" || bad "P3 ALERTS: $(cat "$KH/logs/ALERTS.log")"
nowork P3
[ "$(mcrows | jq length)" = 1 ] && ok "P3 no new row" || bad "P3 rows: $(mcrows)"
echo "P3 control: fallback hub runs the stale project on the hub"
setting lane_fallback.merge-conductor.mgfy hub
: > "$KT/lists.txt"
htick MC_FLY_QUEUE_STALE_S=0
grep -q 'mgfy project-fly: fallback=no-capacity' "$KLOG" && ok "P3c fallback=no-capacity logged" || bad "P3c log: $(klog)"
[ -s "$KT/lists.txt" ] && ok "P3c the hub tick read the PR list" || bad "P3c no hub work: $(klog)"
R=$(mcrows | jq -c '.[0]')
[ "$(jq -r .status <<<"$R")" = died ] && [[ "$(jq -r .prof_line <<<"$R")" == "withdrawn by=hub-"* ]] \
  && ok "P3c the stale row is withdrawn (died, withdrawn by=hub-...) before the hub works" || bad "P3c row: $R"
FIRST=$(grep -m1 -nE '^(apply mgfy|list)$' "$KT/events.txt" | cut -d: -f2)
[ "$FIRST" = "apply mgfy" ] && ok "P3c the machine's write-backs are applied before the hub's first PR read" \
  || bad "P3c order: $(tr '\n' '|' < "$KT/events.txt")"
[ ! -e "$KH/state/merge-conductor/project-fly/mgfy.hubtick" ] && ok "P3c the hub mark is gone once the take-back tick ends" || bad "P3c mark left: $(cat "$KH/state/merge-conductor/project-fly/mgfy.hubtick")"
echo "P3 apply-fail: the hub does no PR work when the write-backs are not applied"
"$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
  -d '{"lane":"merge-conductor","project":"mgfy","args":["bin/merge-conductor-project.sh","mgfy"]}' "$W/api/lane-runs" >/dev/null
: > "$KT/lists.txt"; : > "$KT/apply-fail"
htick MC_FLY_QUEUE_STALE_S=0
rm -f "$KT/apply-fail"
grep -q 'mgfy project-fly: fallback=no-capacity .* held — the machine.s write-backs were not applied' "$KLOG" && ok "P3f the fallback is held, with one line" || bad "P3f log: $(klog)"
[ ! -s "$KT/lists.txt" ] && ok "P3f no hub PR work" || bad "P3f hub work: $(klog)"
echo "P3 withdrawn: the hub takes a withdrawn row back once, then enqueues a new row after the backoff"
setting mc_project_fly.nocap_backoff_s 600
N0=$(mcrows | jq length)
: > "$KT/lists.txt"
htick
grep -q 'mgfy project-fly: fallback=no-capacity (row [0-9]* withdrawn, backoff [0-9]*s left)' "$KLOG" && ok "P3w inside the backoff the hub keeps the project" || bad "P3w log: $(klog)"
[ -s "$KT/lists.txt" ] && ok "P3w and does its PR work" || bad "P3w no hub work"
[ "$(mcrows | jq length)" = "$N0" ] && ok "P3w no row inside the backoff" || bad "P3w rows: $(mcrows)"
setting mc_project_fly.nocap_backoff_s 1   # the backoff ends: the row is the knob, read live
sleep 1.2
: > "$KT/lists.txt"
htick
[ "$(mcrows | jq length)" = $((N0 + 1)) ] && [ "$(mcrows | jq -r '.[0].status')" = queued ] && ok "P3w after the backoff the next tick enqueues a new row" \
  || bad "P3w rows: $(mcrows); $(klog)"
[ ! -s "$KT/lists.txt" ] && ok "P3w and does no hub PR work" || bad "P3w hub work: $(klog)"

# ============================================================================
echo "P4: the machine path lands #31 after a renew with its fence"
kreset
prun; rc=$?
[ "$rc" = 0 ] && ok "P4 the entry exits 0" || bad "P4 rc=$rc $(tail -3 "$KT/prun.err")"
F=$(awk '$1 == "lease" && $2 == "acquire" {print; exit}' "$KT/events.txt")
AF=$(grep -o 'fence=[0-9]*' "$KT/prun.out" | head -1 | cut -d= -f2)
[ -n "$AF" ] && [ "$AF" != - ] && ok "P4 the entry held fence $AF" || bad "P4 no fence: $(cat "$KT/prun.out")"
[ -n "$F" ] && ok "P4 the lease was acquired" || bad "P4 events: $(cat "$KT/events.txt" 2>/dev/null)"
grep -qx enqueue "$KT/events.txt" && ok "P4 #31 reached the Mergify enqueue on the machine" \
  || bad "P4 no enqueue: $(klog) $(tail -3 "$KT/prun.err")"
BEFORE=$(awk '$0 == "enqueue" {print prev; exit} {prev = $0}' "$KT/events.txt")
[ "$BEFORE" = "lease renew $AF" ] && ok "P4 the event before the enqueue is a renew with fence $AF" \
  || bad "P4 before the enqueue: '$BEFORE'; events: $(tr '\n' '|' < "$KT/events.txt")"
grep -q "^PROF mc-project state=QUEUED landed=0 queued=1 deferred=" "$KT/prun.out" && ok "P4 PROF state=QUEUED queued=1" \
  || bad "P4 prof: $(cat "$KT/prun.out")"
L=$(lease)
[ "$(jq -r .holder <<<"$L")" = m1 ] && [ "$(jq -r .fence <<<"$L")" = "$AF" ] && ok "P4 the lease row is m1's fence" || bad "P4 lease: $L"
[ "$(awk '$1 == "lease"' "$KT/events.txt" | tail -1)" = "lease release $AF" ] && ok "P4 the last lease call is the release" \
  || bad "P4 lease events: $(grep lease "$KT/events.txt" | tr '\n' '|')"
echo "P4 control: MC_ON_MACHINE=1 without MC_LEASED_RUN defers the landing"
kreset
: > "$KT/def.txt"
htick MC_FANIN_SOLO_RUN=1 MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$KT/def.txt"
grep -qx land "$KT/def.txt" && ok "P4c deferred=land" || bad "P4c words: '$(tr '\n' ' ' < "$KT/def.txt")' $(klog)"
[ ! -s "$KT/cmds.txt" ] && ok "P4c no enqueue" || bad "P4c writes: $(cat "$KT/cmds.txt")"
echo "P4 control: a lease fence alone (no MC_LEASED_RUN) still defers"
kreset
: > "$KT/def.txt"
htick MC_FANIN_SOLO_RUN=1 MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$KT/def.txt" MC_LEASE_FENCE=7 MC_LEASE_PROJECT=mgfy
grep -qx land "$KT/def.txt" && [ ! -s "$KT/cmds.txt" ] && ok "P4d deferred=land, no enqueue" || bad "P4d words: '$(tr '\n' ' ' < "$KT/def.txt")'"

# ============================================================================
echo "P5: a lost fence writes nothing"
kreset
: > "$KT/steal"
prun; rc=$?
[ ! -s "$KT/cmds.txt" ] && ok "P5 no enqueue" || bad "P5 writes: $(cat "$KT/cmds.txt")"
grep -q "^PROF mc-project state=LEASE_LOST " "$KT/prun.out" && ok "P5 PROF state=LEASE_LOST" || bad "P5 prof: $(cat "$KT/prun.out") rc=$rc"
grep -q "mgfy project lease lost" "$KLOG" && ok "P5 'project lease lost' is logged" || bad "P5 log: $(klog)"
[ "$(lease | jq -r .holder)" = other ] && ok "P5 the other holder keeps the lease" || bad "P5 lease: $(lease)"
"$REALCURL" -sS -X POST "$W/__lease" -d '{"lane":"merge-conductor","project":"mgfy","holder":"other","fence":99,"lease_until":"2000-01-01T00:00:00Z"}' >/dev/null

# ============================================================================
echo "P6: TERM during a project run releases the lease and the row"
kreset
setting lane_run.term_grace_s 20
ID=$("$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
  -d '{"lane":"merge-conductor","project":"mgfy","args":["bin/merge-conductor-project.sh","mgfy"]}' "$W/api/lane-runs" | jq -r '.id // empty')
[ -n "$ID" ] || ID=$(mcrows | jq -r '[.[] | select(.status == "queued")][0].id // empty')
[ -n "$ID" ] || bad "P6 setup: no queued row: $(mcrows)"
: > "$KT/block"
( cd "$KT" && exec env "${ENVS[@]}" FLY_MACHINE_ID=m6 MC_PROJECT_TERM_WAIT_S=1 "$KH/bin/lane-run-worker.sh" --once --machine m6 ) > "$KT/w6.out" 2>&1 & WP=$!
WAITFOR '[ -s "$KT/lists.txt" ]' 200 || bad "P6 setup: the run never read the PR list: $(cat "$KT/w6.out") $(tail -5 "$KH/logs/lane-run-worker.log" 2>/dev/null)"
[ "$(lease | jq -r .holder)" = m6 ] && ok "P6 the run holds the lease (m6)" || bad "P6 lease: $(lease)"
kill -TERM "$WP"; wait "$WP"; wrc=$?
WAITFOR '! pgrep -f "$KH/bin/merge-conductor.sh" >/dev/null && ! pgrep -f "$KB/gh" >/dev/null' 50 \
  && ok "P6 no conductor process and no gh call outlive the run (the tree is reaped)" \
  || bad "P6 survivors: $(pgrep -fl "$KH/bin/merge-conductor.sh|$KB/gh" | head -5)"
rm -f "$KT/block"
[ "$wrc" = 0 ] && ok "P6 the worker exits 0" || bad "P6 worker rc=$wrc $(cat "$KT/w6.out")"
L=$(lease); NOWISO=$(date -u +%FT%TZ)
[ "$(jq -r .holder <<<"$L")" = m6 ] && [[ "$(jq -r .lease_until <<<"$L")" < "$NOWISO" || "$(jq -r .lease_until <<<"$L")" == "$NOWISO" ]] \
  && ok "P6 the lease is released (lease_until <= now)" || bad "P6 lease: $L (now $NOWISO)"
R=$(mcrows | jq -c --argjson id "$ID" '.[] | select(.id == $id)')
[ "$(jq -r .status <<<"$R")" = queued ] && [ "$(jq -r .claimed_by <<<"$R")" = null ] && ok "P6 the row is queued again" || bad "P6 row: $R"
grep -q 'merge-conductor-project.*TERM — stop at the next PR boundary' "$KLOG" && ok "P6 the entry logged the stop" || bad "P6 log: $(klog)"
grep -q "run $ID merge-conductor/mgfy: TERM — released to the queue" "$KH/logs/lane-run-worker.log" && ok "P6 the worker released the row" \
  || bad "P6 worker log: $(tail -3 "$KH/logs/lane-run-worker.log")"

# ============================================================================
echo "P7: lane-placement order"
lp() { ( env "${ENVS[@]}" bash -c '. "$HARNESS/bin/lib/lane-placement.sh"; lp_decide "$1" "$2"; printf "%s|%s" "$LP_PLACE" "$LP_WHY"' _ "$@" ); }
setting lane_placement.lanex hub
setting lane_placement.lanex.pa fly
[ "$(lp lanex pa)" = "fly|lane_placement.lanex.pa=fly" ] && ok "P7 the project row wins" || bad "P7 pa: $(lp lanex pa)"
[[ "$(lp lanex pb)" == hub\|lane_placement.lanex=* ]] && ok "P7 no project row reads the lane row" || bad "P7 pb: $(lp lanex pb)"
[[ "$(lp lanex)" == hub\|lane_placement.lanex=* ]] && ok "P7 a lane-only caller is unchanged" || bad "P7 lane: $(lp lanex)"
setting lane_placement.lanex fly
setting lane_placement.lanex.pc hub
[[ "$(lp lanex pc)" == hub\|lane_placement.lanex.pc=* ]] && ok "P7 a project row can keep one project on the hub" || bad "P7 pc: $(lp lanex pc)"

# ============================================================================
echo "P8: lane-alert.sh on a lane-run machine posts to the jobs API"
: > "$KH/logs/ALERTS.log"
( env "${ENVS[@]}" LANE_RUN_ID=77 PL_LANE=merge-conductor PL_PROJECT=mgfy bash "$KH/bin/lane-alert.real.sh" --severity warn --id p8-test merge-conductor "p8 line" ) >/dev/null 2>&1
grep -q 'POST /api/alert-lines 20[01]' "$T/srv.log" && ok "P8 one POST /api/alert-lines" || bad "P8 server log: $(grep alert-lines "$T/srv.log")"
! grep -q 'p8 line' "$KH/logs/ALERTS.log" && ok "P8 no local ALERTS.log line" || bad "P8 local: $(cat "$KH/logs/ALERTS.log")"

# ============================================================================
WAITFOR '! pgrep -f "$KH/bin/merge-conductor" >/dev/null' 100 || bad "P9 setup: a conductor process is still running: $(pgrep -fl "$KH/bin/merge-conductor")"
echo "P9: a finished row that left work to the hub, then a failed row"
# finish <rc> <prof> — claim the queued row as m9 and report it.
finish_row() {
  local id
  id=$("$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
    -d '{"machine":"m9"}' "$W/api/lane-runs/claim" | jq -r '.id // empty')
  [ -n "$id" ] || { bad "P9 setup: nothing to claim: $(mcrows)"; return 1; }
  "$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
    -d "$(jq -nc --argjson rc "$1" --arg p "$2" '{machine:"m9", rc:$rc, prof:$p}')" "$W/api/lane-runs/$id/report" >/dev/null
  printf '%s' "$id"
}
kreset
setting lane_fallback.merge-conductor.mgfy hub
N0=$(mcrows | jq length)
htick   # the row P6 released is still queued: owed, no new row
ID=$(finish_row 0 "PROF mc-project state=QUEUED landed=0 queued=1 deferred=settle fence=3")
htick
grep -q "mgfy project-fly: fallback=machine-deferred (row $ID: settle)" "$KLOG" && ok "P9 fallback=machine-deferred names the row and the word" || bad "P9 log: $(klog)"
grep -q "TICK mgfy: the hub takes the machine's work back — one full tick of mgfy (keyed tick)" "$KLOG" && ok "P9 the keyed tick starts one full tick of the project" || bad "P9 takeback: $(klog)"
[ -s "$KT/lists.txt" ] && ok "P9 the hub did the project's work" || bad "P9 no hub work"
[ "$(mcrows | jq length)" = "$N0" ] && ok "P9 no row enqueued on the take-back tick" || bad "P9 rows: $(mcrows)"
: > "$KT/lists.txt"
htick
[ "$(mcrows | jq length)" = $((N0 + 1)) ] && ok "P9 the next tick enqueues a new row (the row was taken once)" || bad "P9 rows: $(mcrows); $(klog)"
[ ! -s "$KT/lists.txt" ] && ok "P9 and does no hub PR work" || bad "P9 hub work: $(klog)"
ID=$(finish_row 1 "PROF lane-run rc=1 reason=exit-nonzero err=x")
: > "$KT/lists.txt"
htick
grep -q "mgfy project-fly: fallback=machine-failed (row $ID: rc=1)" "$KLOG" && ok "P9 a failed row is fallback=machine-failed" || bad "P9 failed: $(klog)"
[ -s "$KT/lists.txt" ] && ok "P9 and the hub runs the project" || bad "P9 no hub work after a failed row"

echo "P9 lock: a keyed take-back while a full tick of mgfy holds the full-tick lock"
# Drain every queued row (P6's released row included) as clean done rows.
for _ in 1 2 3 4 5; do
  c=$("$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
    -d '{"machine":"m9"}' "$W/api/lane-runs/claim" | jq -r '.id // empty')
  [ -n "$c" ] || break
  "$REALCURL" -sS -X POST -H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json' \
    -d '{"machine":"m9","rc":0,"prof":"PROF mc-project state=TICKED landed=0 queued=0 deferred=- fence=1"}' "$W/api/lane-runs/$c/report" >/dev/null
done
htick   # the newest row is done: one new row
ID=$(finish_row 0 "PROF mc-project state=TICKED landed=0 queued=0 deferred=rebase fence=4")
LK="$KH/locks/merge-conductor-mgfy-fulltick.lock"
( exec 5>"$LK"; flock 5; sleep 8 ) & LP=$!
sleep 0.5
: > "$KT/lists.txt"
htick
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
grep -q "TICK mgfy: a full tick of mgfy already runs — the take-back waits for the next tick" "$KLOG" && ok "P9l the take-back does not run beside a full tick" || bad "P9l log: $(klog)"
[ ! -s "$KT/lists.txt" ] && ok "P9l no hub PR work" || bad "P9l hub work"
[ ! -e "$KH/state/merge-conductor/project-fly/mgfy.taken" ] && ok "P9l the row stays to be taken back" || bad "P9l taken: $(cat "$KH/state/merge-conductor/project-fly/mgfy.taken")"
htick   # takes the P9l row back now that the lock is free
echo "P9 streak: machine-failed rows in a row raise one ALERTS line"
: > "$KH/logs/ALERTS.log"; rm -f "$KH/state/merge-conductor/project-fly/mgfy.alert-at" "$KH/state/merge-conductor/project-fly/mgfy.failed-n"
setting mc_project_fly.failed_alert_n 2
for i in 1 2 3; do
  htick >/dev/null   # enqueues a new row after the take-back
  finish_row 1 "PROF lane-run rc=1 reason=exit-nonzero err=x" >/dev/null
  htick              # takes it back (machine-failed)
done
[ "$(ALERTN)" = 1 ] && grep -q 'machine runs in a row failed' "$KH/logs/ALERTS.log" && ok "P9s one ALERTS line for the streak (held for the hour)" \
  || bad "P9s ALERTS: $(cat "$KH/logs/ALERTS.log"); log: $(klog)"

# ============================================================================
echo "P10: the gate when the placement cannot be read, and with no fly row at all"
gate() { ( env "${ENVS[@]}" "$@" bash -c '. "$HARNESS/bin/lib/mc/fly-workers.sh"; mc_fly_project_gate mgfy; echo "rc=$?"' 2>/dev/null | tail -1 ); }
: > "$KH/state/merge-conductor/project-fly/mgfy.placed"
[ "$(gate JOBS_URL=http://127.0.0.1:9)" = rc=0 ] && ok "P10 unreadable + last placed fly: no hub work (rc 0)" || bad "P10 placed: $(gate JOBS_URL=http://127.0.0.1:9)"
rm -f "$KH/state/merge-conductor/project-fly/mgfy.placed"
[ "$(gate JOBS_URL=http://127.0.0.1:9)" = rc=1 ] && ok "P10 unreadable, never fly, no live row: today's hub tick (rc 1)" || bad "P10 never: $(gate JOBS_URL=http://127.0.0.1:9)"
nf() { ( env "${ENVS[@]}" JOBS_SETTINGS_CACHE_S=60 bash -c '. "$HARNESS/bin/lib/mc/fly-workers.sh"; mc_fly_project_none; echo "rc=$?"' 2>/dev/null | tail -1 ); }
printf '{"fetched_at":%s,"values":{"lane_placement.merge-conductor.mgfy":"hub","lane_placement.default":"hub"}}\n' "$(date -u +%s)" > "$KH/state/settings-cache.json"
[ "$(nf)" = rc=0 ] && ok "P10 a fresh cache with no fly row: the hub skips the gate" || bad "P10 none: $(nf)"
printf '{"fetched_at":%s,"values":{"lane_placement.merge-conductor.mgfy":" FLY "}}\n' "$(date -u +%s)" > "$KH/state/settings-cache.json"
[ "$(nf)" = rc=1 ] && ok "P10 a fly row in the cache: gate" || bad "P10 fly: $(nf)"
printf '{"fetched_at":%s,"values":{}}\n' "$(( $(date -u +%s) - 3600 ))" > "$KH/state/settings-cache.json"
[ "$(nf)" = rc=1 ] && ok "P10 a stale cache: gate" || bad "P10 stale: $(nf)"
printf '{"fetched_at":%s,"values":{}}\n' "$(date -u +%s)" > "$KH/state/settings-cache.json"
: > "$KH/state/merge-conductor/project-fly/mgfy.placed"
[ "$(nf)" = rc=1 ] && ok "P10 a .placed mark: gate" || bad "P10 mark: $(nf)"
rm -f "$KH/state/settings-cache.json" "$KH/state/merge-conductor/project-fly/mgfy.placed"

# ============================================================================
echo "P11: the Mergify queue post renews the fence first"
ae() { ( env "${ENVS[@]}" FENCE_RC="$1" bash -c '
  . "$HARNESS/bin/lib/autoenqueue.sh" 2>/dev/null
  gh_repo_use_pat() { return 0; }; _ae_record() { return 0; }; _ae_fails() { echo 0; }; _ae_alert() { :; }
  _ae_log() { printf "%s
" "$*" >> "'"$KT"'/ae.log"; }
  gh_rest() { printf "POST
" >> "'"$KT"'/ae.posts"; GH_REST_STATUS=500; return 1; }
  mc_lease_fence_ok() { return "$FENCE_RC"; }
  AE_RECOVER=0 AE_SLUG=example-org/mgfy-os AE_NUM=31 AE_URL=u AE_HEAD=h AE_KEY=k AE_JOB=- AE_MAX_FAILS=3 AE_STATUS=none
  _ae_send; echo "rc=$?"' | tail -1 ); }
rm -f "$KT/ae.posts" "$KT/ae.log"
[ "$(ae 99)" = rc=1 ] && [ ! -e "$KT/ae.posts" ] && grep -q 'the project lease was lost' "$KT/ae.log" \
  && ok "P11 a lost fence: no @mergifyio queue post" || bad "P11 lost: posts=$(cat "$KT/ae.posts" 2>/dev/null) log=$(cat "$KT/ae.log" 2>/dev/null)"
ae 0 >/dev/null
[ -s "$KT/ae.posts" ] && ok "P11 control: a held fence posts" || bad "P11 control: no post; $(cat "$KT/ae.log" 2>/dev/null)"

# ============================================================================
echo "P12: attempts appends (mc_attempt_put) wait for attempts.txt.lock; the @rows ERE takes the repo's lines"
A="$KH/state/merge-conductor/attempts.txt"; mkdir -p "$(dirname "$A")"; : > "$A"
( exec 9>>"$A.lock"; flock 9; sleep 2 ) & LP=$!
sleep 0.3
T0=$(date +%s%N)
( env "${ENVS[@]}" bash -c '. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_attempt_put "red example-org/mgfy-os#31 abc"' )
T1=$(date +%s%N); wait "$LP"
[ $(( (T1 - T0) / 1000000 )) -ge 1200 ] && grep -qx 'red example-org/mgfy-os#31 abc' "$A" && ok "P12 the append waited for the lock, then wrote" \
  || bad "P12 took $(( (T1 - T0) / 1000000 )) ms; file: $(cat "$A")"
ERE=$(sed -n 's/^@rows state\/merge-conductor\/attempts\.txt //p' "$DIR/catalog/lane-run-inputs.d/merge-conductor.rw" | sed "s|\$slug|$KSLUG|")
printf '%s\n' "red $KSLUG#31 abc" "identityalert $KSLUG word 20261019" "citimeout $KSLUG 123 20261019" \
  "red $KSLUG-console#3 x" "identityalert ${KSLUG}x w d" "red Other/repo#1 y" > "$T/att.txt"
[ "$(grep -ciE -- "$ERE" "$T/att.txt")" = 3 ] && ok "P12 the ERE takes the PR, identityalert and citimeout lines of the repo only" \
  || bad "P12 ERE '$ERE' took: $(grep -iE -- "$ERE" "$T/att.txt" | tr '\n' '|')"

# ============================================================================
echo "P13: the hub mark counts only for the same process (pid + start stamp) and while young"
busy() { ( env "${ENVS[@]}" bash -c '. "$HARNESS/bin/lib/mc/project-placement.sh"; _mc_proj_hub_busy mgfy >/dev/null; echo "rc=$?"' 2>/dev/null | tail -1 ); }
stamp() { ( env "${ENVS[@]}" bash -c '. "$HARNESS/bin/lib/mc/project-placement.sh"; _mc_proj_pid_start "$1"' _ "$1" ); }
sleep 30 & SP=$!
MK="$KH/state/merge-conductor/project-fly/mgfy.hubtick"; NOWS=$(date -u +%s)
printf '%s %s %s\n' "$SP" "$(stamp "$SP")" "$NOWS" > "$MK"
[ "$(busy)" = rc=0 ] && ok "P13 the live tick with its own start stamp is busy" || bad "P13 live: $(busy) ($(cat "$MK"))"
printf '%s %s %s\n' "$SP" "other-start" "$NOWS" > "$MK"
[ "$(busy)" = rc=1 ] && ok "P13 a live pid with another start stamp (a reused pid) is not busy" || bad "P13 reused: $(busy)"
printf '%s %s %s\n' "$SP" "$(stamp "$SP")" "$((NOWS - 7200))" > "$MK"
[ "$(busy)" = rc=1 ] && ok "P13 a mark past mc_project_fly.hubtick_max_s is not busy" || bad "P13 old: $(busy)"
printf '%s\n' "$SP" > "$MK"
[ "$(busy)" = rc=1 ] && ok "P13 an old pid-only mark is not busy" || bad "P13 pid-only: $(busy)"
kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
( env "${ENVS[@]}" bash -c '. "$HARNESS/bin/lib/mc/project-placement.sh"; mc_proj_hub_mark mgfy; mc_proj_hub_unmark mgfy' )
[ ! -e "$MK" ] && ok "P13 the mark is removed when its tick ends" || bad "P13 unmark: $(cat "$MK")"

echo "merge-conductor-project.bh-6890: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
