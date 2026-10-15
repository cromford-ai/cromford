#!/bin/bash
# tests/hub-load-budget.bh-6886-test.sh — BH-6886 (BH-6881.8): the hub's cost
# of ONE pl_dispatch tick for a lane placed `fly` does not grow with the fleet.
# pl_dispatch sends one POST /api/lane-runs/batch per 500 projects
# (lp_enqueue_batch, bin/lib/lane-placement.sh) instead of one POST and two jq
# forks per project.
#
# The REAL pl_dispatch (bin/lib/project-lanes.sh) runs against fleets of 10,
# 13, 500 and 1000 projects (tests/fixtures/hub-load/fleet-1000.conf), a stub
# jobs client (shell functions, answering with the route's shape) and a
# counting PATH shim. "Forks" are the external commands the shim sees.
#
#   B1  1000 projects: <= 3 HTTP calls (2 batch POSTs), <= 40 forks, 0 setsid,
#       0 per-row POSTs, `placed: 1000 fly, 0 hub`
#   B2  10 vs 1000: HTTP calls differ by exactly 1, forks by at most 5
#   B3  10 vs 500: HTTP calls differ by 0, forks by at most 5
#   B4  the two payloads: 500 + 500 rows, p0001..p1000 once each, the args
#   B5  forks per tick at 13 projects, per-row path vs batch (reported; the
#       batch must be <= 40 and below the per-row path)
#   L1  2 rows answered already_live -> `2 already live`, 0 hub runs
#   L2  the batch answers 500 -> every project on the hub, ONE alert
#   L3  the batch answers 404 -> the per-row path, as before this ticket
#   L3b 404 on the 2nd batch only -> 500 fly by batch, 500 per-row
#   L4  a 2xx answer that leaves a project out -> that project on the hub
#   L5  the negative list: status queued / error / missing, no id, a project
#       in another case, a project not sent, a body that is not JSON, an empty
#       body -> never fly, each project concerned on the hub
#   R   node tests/lib/lane-runs-batch.bh-6886.mjs (the route contract)
#   E1  the real worker over real curl: 1 batch POST, 20 queued rows, args
#   E2  a second dispatch -> `20 already live`
#   E3  the worker's first batch POST answers 500 -> 20 hub runs, ONE alert
#
# Run from anywhere: tests/hub-load-budget.bh-6886-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
FIX="$REPO/tests/fixtures/hub-load/fleet-1000.conf"
ROUTE="$REPO/worker/jobs/src/routes/lane-runs-batch.js"
DRV="$REPO/tests/lib/lane-runs-batch.bh-6886.mjs"
SRV="$REPO/tests/lib/lane-runs-worker.bh-6124.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }
[ -f "$FIX" ] && [ "$(grep -c . "$FIX")" = 1000 ] || { echo "setup: $FIX is not 1000 lines"; exit 1; }
[ -f "$ROUTE" ] && ok "the batch route module exists" || bad "no $ROUTE"

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/shim"
for L in bin/lib/project-lanes.sh bin/fleet-conf.sh bin/project-lane-run.sh bin/alert-line.sh \
         bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
[ -f "$H/bin/lib/lane-placement.sh" ] && ok "the closure installs bin/lib/lane-placement.sh" || bad "closure lacks lane-placement.sh"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=tok-fixture-default BOX_NAME=fixture-box
export JOBS_BOX=fixture-box JOBS_URL="" HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0

# The fake lane: one line per run (<project> TAB <run id or hub>).
cat > "$H/bin/fake-lane.sh" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\${@: -1}" "\${LANE_RUN_ID:-hub}" >> "$T/runs.tsv"
EOF
chmod +x "$H/bin/fake-lane.sh"

# The counting shim: one line per external start, then the real binary.
JQ=$(command -v jq)
export FORKLOG="$T/forks.log"
for c in jq curl mkdir setsid cksum cat date hostname awk sed grep tr head tail cut sort uniq \
         mktemp rm mv flock sleep env wc bash dirname basename; do
  real=$(command -v "$c") || continue
  printf '#!/bin/bash\nprintf "%%s\\n" %s >> "$FORKLOG"\nexec %s "$@"\n' "$c" "$real" > "$T/shim/$c"
  chmod +x "$T/shim/$c"
done

# ---- the stub jobs client (defined before the lib is sourced) --------------
# Placement: lane_placement.demo=fly and no hub_only row, as a fresh box
# settings cache answers. _jobs_req logs `<method> <path>`, keeps the body and
# answers in the route's shape with the REAL jq by absolute path, so the stub's
# own work is not counted. Knobs: STUB_HTTP=404|500 (batch path only; with
# STUB_HTTP_CALL=<n>, only the n-th batch POST), STUB_LIVE="<projects>"
# (already_live), STUB_MUTATE=<jq filter on the answer>, STUB_RAW_SET=1 with
# STUB_RAW=<the 2xx body as is>.
STUB_HTTP=""; STUB_HTTP_CALL=""; STUB_LIVE=""; STUB_MUTATE="."; STUB_RAW=""; STUB_RAW_SET=""; NB=0
setting_get() { case "$1" in lane_placement.demo) printf 'fly'; return 0 ;; *) return 2 ;; esac; }
_setting_key_ok() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" proj
  JOBS_HTTP=""; JOBS_BODY=""
  printf '%s %s\n' "$m" "$p" >> "$T/http.log"
  case "$m $p" in
    "POST /api/lane-runs/batch")
      NB=$((NB + 1))
      printf '%s\n' "$b" >> "$T/bodies.jsonl"
      if [ -n "$STUB_HTTP" ] && { [ -z "$STUB_HTTP_CALL" ] || [ "$STUB_HTTP_CALL" = "$NB" ]; }; then
        JOBS_HTTP="$STUB_HTTP"
        [ "$STUB_HTTP" = 404 ] && return 2
        return 1
      fi
      JOBS_HTTP=200
      if [ -n "$STUB_RAW_SET" ]; then JOBS_BODY="$STUB_RAW"; return 0; fi
      JOBS_BODY=$("$JQ" -c --arg live " $STUB_LIVE " --argjson base "$((NB * 1000))" '
        . as $r
        | [ $r.rows | to_entries[] | .value.project as $pj
            | if ($live | contains(" " + $pj + " "))
              then {project: $pj, status: "already_live"}
              else {project: $pj, status: "enqueued", id: ($base + .key + 1)} end ] as $rows
        | {lane: $r.lane, as_of: "2026-10-15T00:00:00Z",
           enqueued: ([$rows[] | select(.status == "enqueued")] | length),
           already_live: ([$rows[] | select(.status == "already_live")] | length),
           rows: $rows}
        | '"$STUB_MUTATE" <<<"$b")
      return 0 ;;
    "POST /api/lane-runs")
      proj=$("$JQ" -r .project <<<"$b")
      printf '%s\n' "$proj" >> "$T/rowposts.log"
      case " $STUB_LIVE " in *" $proj "*) JOBS_HTTP=409; JOBS_BODY='{"error":"already_live"}'; return 9 ;; esac
      JOBS_HTTP=201; JOBS_BODY='{"id":1}'; return 0 ;;
  esac
  JOBS_HTTP=404; return 2
}

# shellcheck source=bin/lib/project-lanes.sh
. "$H/bin/lib/project-lanes.sh" || { echo "setup: project-lanes.sh did not load"; exit 1; }
command -v lp_enqueue_batch >/dev/null 2>&1 && ok "lp_enqueue_batch is defined" || bad "lp_enqueue_batch is not defined"

# run <n> — one pl_dispatch tick over the first <n> fixture projects, with the
# shim on PATH for the tick only. Sets OUT, DRC, NHTTP, NBATCH, NROW, NFORK.
run() {
  local op="$PATH"
  head -n "$1" "$FIX" > "$H/fleet.conf"
  : > "$T/http.log"; : > "$T/forks.log"; : > "$T/bodies.jsonl"; : > "$T/rowposts.log"; NB=0
  PATH="$T/shim:$op"
  pl_dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b" > "$T/out"; DRC=$?
  PATH="$op"
  OUT=$(< "$T/out")
  NHTTP=$(grep -c . "$T/http.log")
  NBATCH=$(grep -c '^POST /api/lane-runs/batch$' "$T/http.log")
  NROW=$(grep -c '^POST /api/lane-runs$' "$T/http.log")
  NFORK=$(grep -c . "$T/forks.log")
}
stub_reset() { STUB_HTTP=""; STUB_HTTP_CALL=""; STUB_LIVE=""; STUB_MUTATE="."; STUB_RAW=""; STUB_RAW_SET=""; }
wait_runs() { local p; for p in $(jobs -p); do case " ${PIDS[*]:-} " in *" $p "*) ;; *) wait "$p" ;; esac; done; }
hubruns() { awk -F'\t' '$2 == "hub" {print $1}' "$T/runs.tsv" 2>/dev/null | sort | tr '\n' ' '; }
nhub() { awk -F'\t' '$2 == "hub"' "$T/runs.tsv" 2>/dev/null | grep -c .; }
nalerts_lp() { grep -c 'lane-placement' "$H/logs/ALERTS.log" 2>/dev/null; }
CLEAN() { : > "$T/runs.tsv"; : > "$H/logs/ALERTS.log"; }
PIDS=()

# ============================================================================
echo "B1: 1000 projects on fly"
CLEAN; stub_reset
run 1000
H1000=$NHTTP; F1000=$NFORK; cp "$T/bodies.jsonl" "$T/b1-bodies.jsonl"
echo "  (1000 projects: $NHTTP HTTP call(s), $NFORK fork(s): $(sort "$T/forks.log" | uniq -c | tr -s ' ' | tr '\n' ',' ))"
[ "$DRC" = 0 ] && ok "B1 pl_dispatch rc 0" || bad "B1 rc=$DRC"
[ "$NHTTP" -le 3 ] && ok "B1 $NHTTP HTTP calls (<= 3)" || bad "B1 $NHTTP HTTP calls"
[ "$NBATCH" = 2 ] && ok "B1 2 batch POSTs" || bad "B1 batch POSTs: $NBATCH"
[ "$NROW" = 0 ] && ok "B1 0 per-row POSTs" || bad "B1 per-row POSTs: $NROW"
[ "$NFORK" -le 40 ] && ok "B1 $NFORK forks (<= 40)" || bad "B1 $NFORK forks"
[ "$(grep -c '^setsid$' "$T/forks.log")" = 0 ] && ok "B1 0 setsid" || bad "B1 setsid: $(grep -c '^setsid$' "$T/forks.log")"
case "$OUT" in *"; placed: 1000 fly, 0 hub (lane_placement.demo=fly)") ok "B1 placed: 1000 fly, 0 hub" ;; *) bad "B1 summary: $OUT" ;; esac
case "$OUT" in "demo dispatch: started 0 project run(s) (period 0s, no cap), 0 held: []"*) ok "B1 the summary prefix is unchanged" ;; *) bad "B1 prefix: $OUT" ;; esac

# ============================================================================
echo "B2/B3: the tick cost does not grow with the fleet"
run 10; H10=$NHTTP; F10=$NFORK
case "$OUT" in *"placed: 10 fly, 0 hub"*) ;; *) bad "B2 10-project summary: $OUT" ;; esac
run 500; H500=$NHTTP; F500=$NFORK
case "$OUT" in *"placed: 500 fly, 0 hub"*) ;; *) bad "B3 500-project summary: $OUT" ;; esac
echo "  (HTTP 10/500/1000: $H10/$H500/$H1000, forks: $F10/$F500/$F1000)"
d=$((F1000 - F10)); [ "$d" -lt 0 ] && d=$((-d))
[ $((H1000 - H10)) = 1 ] && ok "B2 10 vs 1000: HTTP calls differ by 1 (the second 500-row batch)" || bad "B2 HTTP $H10 vs $H1000"
[ "$d" -le 5 ] && ok "B2 10 vs 1000: forks differ by $d (<= 5)" || bad "B2 forks $F10 vs $F1000"
d=$((F500 - F10)); [ "$d" -lt 0 ] && d=$((-d))
[ "$H500" = "$H10" ] && ok "B3 10 vs 500: HTTP calls differ by 0" || bad "B3 HTTP $H10 vs $H500"
[ "$d" -le 5 ] && ok "B3 10 vs 500: forks differ by $d (<= 5)" || bad "B3 forks $F10 vs $F500"

# ============================================================================
echo "B4: the payload chunks"
[ "$(jq -c '.rows | length' "$T/b1-bodies.jsonl" | tr '\n' ' ')" = "500 500 " ] && ok "B4 2 batches of 500 and 500" || bad "B4 sizes: $(jq -c '.rows | length' "$T/b1-bodies.jsonl" | tr '\n' ' ')"
ALL=$(jq -r '.rows[].project' "$T/b1-bodies.jsonl")
[ "$ALL" = "$(awk '{print $1}' "$FIX")" ] && ok "B4 p0001..p1000, once each, in fleet order" || bad "B4 the projects differ from the fixture"
[ "$(jq -c '[.rows[].args] | unique' "$T/b1-bodies.jsonl" | sort -u)" = '[["bin/fake-lane.sh","--x","a b"]]' ] \
  && ok "B4 every row's args are [bin/fake-lane.sh, --x, a b]" || bad "B4 args: $(jq -c '[.rows[].args] | unique' "$T/b1-bodies.jsonl" | sort -u)"
[ "$(jq -r '"\(.lane) \(.box)"' "$T/b1-bodies.jsonl" | sort -u)" = "demo fixture-box" ] && ok "B4 lane demo, box fixture-box" || bad "B4 lane/box: $(jq -c '{lane,box}' "$T/b1-bodies.jsonl")"

# ============================================================================
echo "B5: forks per tick at 13 projects"
STUB_HTTP=404; run 13; X=$NFORK; XR=$NROW; XO=$OUT; stub_reset
run 13; Y=$NFORK
echo "  forks per tick, 13 projects: per-row $X, batch $Y"
[ "$XR" = 13 ] && case "$XO" in *"placed: 13 fly, 0 hub"*) true ;; *) false ;; esac && ok "B5 the 404 run took the per-row path (13 POSTs, 13 fly)" || bad "B5 per-row run: $XR posts, $XO"
[ "$Y" -le 40 ] && ok "B5 batch forks $Y <= 40" || bad "B5 batch forks $Y"
[ "$Y" -lt "$X" ] && ok "B5 batch forks $Y < per-row forks $X" || bad "B5 batch $Y not below per-row $X"

# ============================================================================
echo "L1: rows answered already_live"
CLEAN; stub_reset; STUB_LIVE="p0003 p0700"
run 1000; wait_runs
case "$OUT" in *"; placed: 998 fly, 0 hub (lane_placement.demo=fly), 2 already live") ok "L1 998 fly, 2 already live" ;; *) bad "L1 summary: $OUT" ;; esac
[ "$(nhub)" = 0 ] && ok "L1 0 hub runs" || bad "L1 hub runs: $(hubruns)"
[ "$(nalerts_lp)" = 0 ] && ok "L1 0 alerts" || bad "L1 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "L2: the batch answers 500"
CLEAN; stub_reset; STUB_HTTP=500
run 20; wait_runs
case "$OUT" in *"; placed: 0 fly, 20 hub (lane_placement.demo=fly), 20 enqueue failed -> hub") ok "L2 0 fly, 20 hub, 20 failed" ;; *) bad "L2 summary: $OUT" ;; esac
case "$OUT" in "demo dispatch: started 20 project run(s)"*"[p0001@0s p0002@0s"*) ok "L2 the hub runs are named in the line" ;; *) bad "L2 line: $OUT" ;; esac
[ "$(nhub)" = 20 ] && ok "L2 20 hub runs" || bad "L2 hub runs: $(nhub)"
[ "$NROW" = 0 ] && ok "L2 no per-row retry after a 500" || bad "L2 per-row posts: $NROW"
[ "$(nalerts_lp)" = 1 ] && grep 'lane-placement' "$H/logs/ALERTS.log" | grep -q 'demo: 20 of 20 fly enqueue(s) failed' \
  && ok "L2 ONE lane-placement alert naming demo and the count" || bad "L2 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "L3: the worker has no batch route (404)"
CLEAN; stub_reset; STUB_HTTP=404
run 20; wait_runs
case "$OUT" in *"; placed: 20 fly, 0 hub (lane_placement.demo=fly)") ok "L3 20 fly through the per-row path" ;; *) bad "L3 summary: $OUT" ;; esac
[ "$NBATCH" = 1 ] && [ "$NROW" = 20 ] && ok "L3 1 batch POST, then 20 per-row POSTs" || bad "L3 batch=$NBATCH row=$NROW"
[ "$(nhub)" = 0 ] && [ "$(nalerts_lp)" = 0 ] && ok "L3 0 hub runs, 0 alerts" || bad "L3 hub=$(nhub) alerts=$(nalerts_lp)"
CLEAN; stub_reset; STUB_HTTP=404; STUB_LIVE="p0004"
run 20; wait_runs
case "$OUT" in *"; placed: 19 fly, 0 hub (lane_placement.demo=fly), 1 already live") ok "L3 the per-row 409 still counts already live" ;; *) bad "L3 live: $OUT" ;; esac

echo "L3b: 404 on the second batch only"
CLEAN; stub_reset; STUB_HTTP=404; STUB_HTTP_CALL=2
run 1000; wait_runs
case "$OUT" in *"; placed: 1000 fly, 0 hub (lane_placement.demo=fly)") ok "L3b 1000 fly" ;; *) bad "L3b summary: $OUT" ;; esac
[ "$NBATCH" = 2 ] && [ "$NROW" = 500 ] && ok "L3b 2 batch POSTs, 500 per-row POSTs" || bad "L3b batch=$NBATCH row=$NROW"
[ "$(< "$T/rowposts.log")" = "$(awk 'NR > 500 {print $1}' "$FIX")" ] && ok "L3b the per-row posts are p0501..p1000" || bad "L3b per-row: $(head -2 "$T/rowposts.log")"
[ "$(nhub)" = 0 ] && ok "L3b 0 hub runs" || bad "L3b hub runs: $(nhub)"

# ============================================================================
echo "L4: a 2xx answer that leaves a project out"
CLEAN; stub_reset; STUB_MUTATE='.rows |= map(select(.project != "p0002"))'
run 20; wait_runs
case "$OUT" in *"; placed: 19 fly, 1 hub (lane_placement.demo=fly), 1 enqueue failed -> hub") ok "L4 19 fly, p0002 on the hub, counted failed" ;; *) bad "L4 summary: $OUT" ;; esac
[ "$(hubruns)" = "p0002 " ] && ok "L4 the hub ran p0002 only" || bad "L4 hub runs: $(hubruns)"
[ "$(nalerts_lp)" = 1 ] && ok "L4 ONE alert" || bad "L4 alerts: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "L5: the negative list is never fly"
CLEAN; stub_reset
STUB_MUTATE='.rows |= map(
    if .project == "p0001" then .status = "queued"
    elif .project == "p0002" then .status = "error"
    elif .project == "p0003" then del(.status)
    elif .project == "p0004" then .project = "P0004"
    elif .project == "p0005" then del(.id)
    else . end)
  | .rows += [{project: "zzz9", status: "enqueued", id: 99999}, {project: "p0006", status: "already_live"}]'
run 20; wait_runs
case "$OUT" in *"; placed: 15 fly, 5 hub (lane_placement.demo=fly), 5 enqueue failed -> hub") ok "L5 15 fly, 5 hub: queued/error/no status/P0004/no id are not fly, zzz9 is not counted" ;; *) bad "L5 summary: $OUT" ;; esac
[ "$(hubruns)" = "p0001 p0002 p0003 p0004 p0005 " ] && ok "L5 the hub ran p0001..p0005" || bad "L5 hub runs: $(hubruns)"
for raw in 'not json' ''; do
  CLEAN; stub_reset; STUB_RAW_SET=1; STUB_RAW="$raw"
  run 3; wait_runs
  case "$OUT" in *"; placed: 0 fly, 3 hub (lane_placement.demo=fly), 3 enqueue failed -> hub") ok "L5 2xx body '$raw': 0 fly, 3 hub" ;; *) bad "L5 body '$raw': $OUT" ;; esac
  [ "$(nhub)" = 3 ] && ok "L5 2xx body '$raw': 3 hub runs" || bad "L5 body '$raw' hub runs: $(nhub)"
done

# ============================================================================
echo "R: the route contract (node $DRV)"
NODE_OK=1; command -v node >/dev/null 2>&1 || NODE_OK=0
if [ "$NODE_OK" = 1 ]; then
  "$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || bad "R cannot compose catalog/llm-sites.json"
  if [ ! -f "$REPO/catalog/lanes.json" ]; then
    HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null 2>&1 \
      || bad "R could not generate catalog/lanes.json the worker imports"
  fi
  node "$DRV" > "$T/r.out" 2>"$T/r.err"; rrc=$?
  sed 's/^/  | /' "$T/r.out"
  case "$rrc" in
    0) ok "R the route driver passed" ;;
    3) echo "  SKIP R: node:sqlite unavailable in this runtime" ;;
    *) bad "R the route driver rc=$rrc: $(head -5 "$T/r.err")" ;;
  esac
else
  echo "  SKIP R and E: node missing"
fi

# ============================================================================
# E: the real jobs client and the real worker. The stubs go away, so
# _lp_client sources $H/bin/jobs-client.sh on the next call.
if [ "$NODE_OK" = 1 ]; then
  unset -f setting_get _setting_key_ok _jobs_req
  srv() {
    local n="$1"; shift
    : > "$T/$n.log"; : > "$T/$n.port"
    env "$@" node "$SRV" "$T/$n.log" > "$T/$n.port" 2> "$T/$n.err" &
    local pid=$!; PIDS+=("$pid")
    for _ in $(seq 1 200); do [ -s "$T/$n.port" ] && break; kill -0 "$pid" 2>/dev/null || break; sleep 0.05; done
    PORT=$(head -1 "$T/$n.port")
    if [ -z "$PORT" ]; then wait "$pid"; return $?; fi
  }
  stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
  trap 'stop_all; __scratch_exit_trap' EXIT
  setting() { curl -sS -X PUT "$JOBS_URL/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
  rows() { curl -sS "$JOBS_URL/__lane_runs"; }
  dispatch() { pl_dispatch "$@" > "$T/dispatch.out"; DRC=$?; OUT=$(< "$T/dispatch.out"); }

  srv e1; src=$?
  if [ "$src" = 3 ]; then
    echo "  SKIP E: node:sqlite unavailable in this runtime"
  elif [ -z "${PORT:-}" ]; then
    bad "E setup: the worker did not start: $(cat "$T/e1.err")"
  else
    export JOBS_URL="http://127.0.0.1:$PORT"
    echo "E1: 20 projects on fly through the real worker"
    CLEAN; head -n 20 "$FIX" > "$H/fleet.conf"; setting lane_placement.demo fly
    dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b"
    case "$OUT" in *"; placed: 20 fly, 0 hub (lane_placement.demo=fly)") ok "E1 placed: 20 fly" ;; *) bad "E1 summary: $OUT" ;; esac
    [ "$(grep -c '^POST /api/lane-runs/batch 200$' "$T/e1.log")" = 1 ] && ok "E1 1 POST /api/lane-runs/batch 200" || bad "E1 log: $(grep POST "$T/e1.log")"
    [ "$(grep -c '^POST /api/lane-runs [0-9]' "$T/e1.log")" = 0 ] && ok "E1 0 per-row POSTs" || bad "E1 per-row posts"
    R=$(rows)
    [ "$(jq '[.rows[] | select(.status == "queued" and .lane == "demo")] | length' <<<"$R")" = 20 ] && ok "E1 20 queued rows" || bad "E1 rows: $R"
    [ "$(jq -c '[.rows[].args] | unique' <<<"$R")" = '[["bin/fake-lane.sh","--x","a b"]]' ] && ok "E1 args stored byte for byte" || bad "E1 args: $(jq -c '[.rows[].args] | unique' <<<"$R")"
    [ "$(jq -r '[.rows[].project] | join(" ")' <<<"$R")" = "$(awk '{print $1}' "$H/fleet.conf" | tr '\n' ' ' | sed 's/ $//')" ] && ok "E1 ids ascend in fleet order" || bad "E1 order: $(jq -c '[.rows[].project]' <<<"$R")"
    [ "$(jq -r '[.rows[].enqueued_by] | unique | join(",")' <<<"$R")" = fixture-box ] && ok "E1 enqueued_by is the box" || bad "E1 box: $(jq -c '[.rows[].enqueued_by] | unique' <<<"$R")"

    echo "E2: a second dispatch while the rows are live"
    dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b"; wait_runs
    case "$OUT" in *"; placed: 0 fly, 0 hub (lane_placement.demo=fly), 20 already live") ok "E2 20 already live" ;; *) bad "E2 summary: $OUT" ;; esac
    [ "$(nhub)" = 0 ] && ok "E2 0 hub runs" || bad "E2 hub runs: $(nhub)"

    echo "E3: the worker's batch POST answers 500"
    srv e3 FAIL_BATCH_N=1 || true
    export JOBS_URL="http://127.0.0.1:$PORT"
    setting lane_placement.demo fly
    CLEAN; dispatch demo 0 "$H/bin/fake-lane.sh" --x "a b"; wait_runs
    case "$OUT" in *"; placed: 0 fly, 20 hub (lane_placement.demo=fly), 20 enqueue failed -> hub") ok "E3 20 hub, 20 failed" ;; *) bad "E3 summary: $OUT" ;; esac
    [ "$(nhub)" = 20 ] && ok "E3 20 hub runs" || bad "E3 hub runs: $(nhub)"
    [ "$(grep -c '^POST /api/lane-runs/batch 500$' "$T/e3.log")" = 1 ] && ok "E3 the one batch POST answered 500" || bad "E3 log: $(grep POST "$T/e3.log")"
    [ "$(jq '.rows | length' <<<"$(rows)")" = 0 ] && ok "E3 0 rows written" || bad "E3 rows"
    [ "$(nalerts_lp)" = 1 ] && ok "E3 ONE lane-placement alert" || bad "E3 alerts: $(cat "$H/logs/ALERTS.log")"
  fi
fi

echo "hub-load-budget: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
