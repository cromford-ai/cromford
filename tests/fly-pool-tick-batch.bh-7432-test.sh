#!/bin/bash
# tests/fly-pool-tick-batch.bh-7432-test.sh — BH-7432: the pool tick wrapper
# (bin/fly-pool-tick.sh) enqueues every fly-placed project in ONE batch call
# (ptb_split, bin/lib/pool-tick-batch.sh) and starts bin/fly-pool.sh only for
# the projects that still need a hub tick.
#
# Driven over real curl against the REAL jobs worker on node:sqlite
# (tests/lib/mc-budget.bh-6887.mjs; its request log counts the calls), through
# the REAL bin/fly-pool-tick.sh and the REAL bin/fly-pool.sh on a scratch hub
# root. `fly`, `flyctl` and `gh` are stubs that record every call. A PATH shim
# counts the external starts of one wrapper tick (the
# tests/hub-load-budget.bh-6886-test.sh pattern). A fresh
# state/settings-cache.json carries the placement rows. "Started" means
# locks/fly-pool-<p>.lock exists after the tick: bin/fly-pool.sh opens it first.
# Every case has its own hub root and its own project names.
#
#   B1  13 projects placed fly (one ` FLY `, one by the lane row), no rows:
#       1 batch POST, 0 single POSTs, 13 queued rows with args
#       [bin/fly-pool-project.sh], 0 starts, 0 fly/gh calls, <= 300 forks
#   B2  a second tick with every row queued: 0 batch POSTs, 13 skip lines;
#       one row done rc 0 with a PROF line: that project alone is batched
#   B3  mixed: fly and withdrawn batch; hub, no row, default row only, `flyy`
#       and a rollback mark are started
#   B4  stale, done rc 1, no PROF, deferred, backoff: all started, 0 batch
#       POSTs; the stale row ends withdrawn by pp_gate
#   B5  batch route 404 / 500 / a partial answer: the projects left out are
#       started, pp_gate posts its own rows, no wrapper alert
#   B6  POOL_TICK_BATCH=0: every project started, 0 batch POSTs
#   B7  no fly row in a fresh cache: every project started, no by-prefix read
#   B8  lane_placement.fly-pool.hub_only set: every project started
#   B9  a held project lock: that project is started, the others batch
#   B10 round trip: a batch row is claimed by the real bin/lane-run-worker.sh
#       on a machine root; the entry runs for exactly that project and the
#       stub tick writes the same files as a hub run of the stub
#   B11 hub load over: fly projects still batch
#   B12 box:mk-box: batched, `placed box:mk-box`; claimed and box-silent:
#       started
#   B13 POOL_TICK_MAX_PARALLEL=1: the cap applies to the started projects only
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-tick-batch.bh-7432-test.sh
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
LANE=fly-pool
KT="$T/k"; TPL="$KT/tpl"; FB="$KT/fakebin"; SHIM="$KT/shim"
mkdir -p "$TPL/bin/lib" "$FB" "$SHIM"

# ---- the template hub root ---------------------------------------------------
for L in bin/fly-pool-tick.sh bin/fly-pool.sh bin/lib/pool-tick-batch.sh bin/lib/pool-placement.sh bin/lib/lane-placement.sh \
         bin/lib/project-lease.sh bin/lib/lane-run-inputs.sh bin/jobs-client.sh bin/lib/hub-load-shed.sh; do
  [ -e "$DIR/$L" ] || continue
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
mkdir -p "$TPL/logs" "$TPL/flags" "$TPL/locks" "$TPL/env" "$TPL/state/fly" "$TPL/catalog"
cp -r "$DIR/catalog/lane-run-inputs.d" "$TPL/catalog/"
: > "$TPL/env/global.env"; : > "$TPL/env/fly.env"
# The alert writers record one line per call; the cap answers 1 (autoscale on).
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${HARNESS:?}/logs/ALERTS.log"\nexit 0\n' > "$TPL/bin/lane-alert.sh"
cp "$TPL/bin/lane-alert.sh" "$TPL/bin/alert-line.sh"
printf '#!/bin/bash\necho 1\n' > "$TPL/bin/pool-cap.sh"
for s in beat fly-lock-guard; do printf '#!/bin/bash\nexit 0\n' > "$TPL/bin/$s.sh"; done
rm -f "$TPL/bin/fly-pool-rows-parity.sh" "$TPL/bin/pool-budget.sh" "$TPL/bin/fly-onboard.sh"
chmod +x "$TPL/bin/"*.sh 2>/dev/null
# The scripts' #!/bin/bash is bash 3.2 on a Mac; env bash also makes each script
# start one counted `bash` through the shim.
for f in "$TPL/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done

# The stubs: fly, flyctl and gh record every call.
for c in fly flyctl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.txt"\ncase "$*" in *"machines list"*|*"machine list"*) echo "[]" ;; esac\nexit 0\n' "$c" "$KT" > "$FB/$c"
done
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
chmod +x "$FB/"*
# The counting shim: one line per external start, then the real binary.
export FORKLOG="$KT/forks.log"
for c in jq curl mkdir setsid cksum cat date hostname awk sed grep tr head tail cut sort uniq \
         mktemp rm mv cp flock sleep env wc bash dirname basename find ls stat tar gzip base64 sha256sum xargs nproc pgrep ps touch chmod ln readlink realpath printf seq; do
  real=$(command -v "$c") || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/bash\nprintf "%%s\\n" %s >> "$FORKLOG"\nexec %s "$@"\n' "$c" "$real" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done
# curl also keeps the body of every batch POST, one line in batch-bodies.jsonl.
cat > "$SHIM/curl" <<EOF
#!/bin/bash
printf '%s\n' curl >> "\$FORKLOG"
case "\${!#}" in
  */api/lane-runs/batch) prev=""; for a in "\$@"; do [ "\$prev" = --data-binary ] && printf '%s\n' "\$a" >> "$KT/batch-bodies.jsonl"; prev="\$a"; done ;;
esac
exec "$REALCURL" "\$@"
EOF
chmod +x "$SHIM/curl"

# ---- the worker ----------------------------------------------------------------
: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
HOLDERS=()
trap 'kill "$SPID" 2>/dev/null; for h in "${HOLDERS[@]}"; do kill "$h" 2>/dev/null; done' EXIT
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
W="http://127.0.0.1:$PORT"
AUTH=(-H "authorization: Bearer fixture-harness-secret" -H 'content-type: application/json')
api() { "$REALCURL" -sS "${AUTH[@]}" -X "$1" "$W$2" ${3:+-d "$3"}; }
answer() { "$REALCURL" -sS -X PUT "$W/__answer" -d "$1" >/dev/null; }
setting() { "$REALCURL" -sS -X PUT "$W/__setting" -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" >/dev/null; }
rows() { api GET "/api/lane-runs/by-prefix?lane=$LANE&project_prefix=$1&limit=50" | jq -c --arg p "$1" '[.rows[] | select(.project == $p)]'; }
enq() { api POST /api/lane-runs "$(jq -nc --arg p "$1" '{lane:"fly-pool", project:$p, args:["bin/fly-pool-project.sh",$p]}')" | jq -r '.id'; }
# finish <project> <rc> <prof> — the project's queued row claimed and reported.
finish() {
  local id
  id=$(api POST /api/lane-runs/claim "$(jq -nc --arg p "$1" '{machine:"m-test", lanes:["fly-pool"], only_prefixes:[$p]}')" | jq -r '.id // empty')
  [ -n "$id" ] || { bad "setup: no claim for $1"; return 1; }
  api POST "/api/lane-runs/$id/report" "$(jq -nc --argjson rc "$2" --arg pr "$3" '{machine:"m-test", rc:$rc, prof:$pr}')" >/dev/null
}
withdraw() { api POST "/api/lane-runs/$1/withdraw" '{"by":"fixture","why":"test"}' >/dev/null; }
PROF0='PROF fly-pool-project state=TICKED spawned=0 reaped=0 deferred=- fence=1'

# mkhub <case> <project>... — a fresh hub root for one case: a flag, an app
# record and a fleet line per project. Prints the root.
mkhub() {
  local h="$KT/$1" p; shift
  cp -a "$TPL" "$h"
  : > "$h/fleet.conf"
  for p in "$@"; do
    : > "$h/flags/fly-pool-$p"
    printf '{"app":"pool-%s"}\n' "$p" > "$h/state/fly/$p.json"
    printf '%s example-org/%s - - 1 local local\n' "$p" "$p" >> "$h/fleet.conf"
  done
  printf '%s' "$h"
}
# cache <hub> <values-json> — a fresh box settings cache.
cache() { printf '{"fetched_at":%s,"seeded":{"lane_placement.default":"hub"},"values":%s}\n' "$(date -u +%s)" "$2" > "$1/state/settings-cache.json"; }
# fresh_pub <hub> <project>... — the snapshot publish is inside its window (A2).
fresh_pub() { local h="$1" p; shift; mkdir -p "$h/state/pool-fly"; for p in "$@"; do date -u +%s > "$h/state/pool-fly/$p.published-at"; done; }
ENVS=(HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" GH_TOKEN=pat-fixture JOBS_SETTINGS_CACHE_S=600 JOBS_RETRIES=0
  JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box POOL_TICK_BUDGET_S=20 POOL_TICK_WAIT_S=60 POOL_TICK_MAX_PARALLEL=0)
# tick <hub> [VAR=val...] — one wrapper run, the shim and the stubs on PATH.
# Sets NFORK, NBATCH (batch POSTs), NSINGLE (single POSTs), NPREFIX (by-prefix GETs).
tick() {
  local h="$1" s0; shift
  s0=$(wc -l < "$T/srv.log"); : > "$FORKLOG"
  ( cd "$KT" && env "${ENVS[@]}" HARNESS="$h" FLEET_CONF="$h/fleet.conf" FLY_BIN_DIR="$FB" PATH="$SHIM:$FB:$PATH" "$@" \
      bash "$h/bin/fly-pool-tick.sh" > "$h/tick.out" 2> "$h/tick.err" )
  # The hub ticks the wrapper left running finish on their own: wait for them.
  local i; for i in $(seq 1 300); do pgrep -f "$h/bin/fly-pool.sh" >/dev/null 2>&1 || break; sleep 0.1; done
  NFORK=$(grep -c . "$FORKLOG")
  tail -n +"$((s0 + 1))" "$T/srv.log" > "$h/http.log"
  NBATCH=$(grep -c '^POST /api/lane-runs/batch ' "$h/http.log")
  NSINGLE=$(grep -c '^POST /api/lane-runs ' "$h/http.log")
  NPREFIX=$(grep -c '^GET /api/lane-runs/by-prefix' "$h/http.log")
}
started() { [ -e "$1/locks/fly-pool-$2.lock" ]; }
nstarted() { local h="$1" p n=0; shift; for p in "$@"; do started "$h" "$p" && n=$((n + 1)); done; echo "$n"; }
lines() { grep -c -- "$2" "$1/logs/fly-pool.log" 2>/dev/null || true; }
vendor_n() { grep -c . "$KT/vendor.txt" 2>/dev/null || true; }

# ============================================================================
echo "B10: round trip — the machine claims a batch row and ticks exactly that project"
# First, so the machine's drain finds this one row in the shared queue.
P10=b10-mk; H10=$(mkhub b10 "$P10")
cache "$H10" "{\"lane_placement.fly-pool.$P10\":\"fly\"}"   # the publish is due: the machine fetches it
tick "$H10"
[ "$NBATCH" = 1 ] && [ "$(rows "$P10" | jq -r '.[0].status')" = queued ] || bad "B10 setup: no batch row: batch=$NBATCH $(rows "$P10")"
MAC="$KT/mac"; MFB="$KT/machine-fly"; SRCD="$KT/harness-src"
mkdir -p "$MAC/bin/lib" "$MAC/logs" "$MAC/state" "$MAC/locks" "$MAC/env" "$MAC/catalog" "$MFB" "$SRCD"
for d in bin prompts rules catalog fly; do mkdir -p "$SRCD/$d"; done; : > "$SRCD/fleet.conf"
printf '%s example-org/%s - - 1 local local\n' "$P10" "$P10" > "$MAC/fleet.conf"; : > "$MAC/env/global.env"
cp -r "$DIR/catalog/lane-run-inputs.d" "$MAC/catalog/"
for L in bin/fleet-conf.sh bin/lane-run-worker.sh bin/project-lane-run.sh bin/fly-pool-project.sh bin/lib/pool-placement.sh bin/lib/project-lease.sh \
         bin/lib/lane-run-inputs.sh bin/lane-alert.sh bin/lib/alert-line-remote.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$MAC" ) >/dev/null 2>&1 || bad "B10 setup: closure of $L on the machine failed"
done
for s in beat alert-line; do printf '#!/bin/bash\nexit 0\n' > "$MAC/bin/$s.sh"; done
# The stub tick: it writes what a tick of <project> writes, under $HARNESS.
STUB='#!/bin/bash
H="${HARNESS:?}"; PRJ="${1:?}"
mkdir -p "$H/state/fly-pool/$PRJ" "$H/logs"
printf "{\"project\":\"%s\",\"machine\":\"abcdef01234567\"}\n" "$PRJ" > "$H/state/fly-pool/$PRJ/abcdef01234567.json"
echo "tick $PRJ" >> "$H/ticks.txt"
exit 0'
printf '%s\n' "$STUB" > "$MAC/bin/fly-pool.sh"
printf '#!/bin/bash\necho "fly $*" >> "%s/mac-fly.txt"\nexit 0\n' "$KT" > "$MFB/fly"
chmod +x "$MAC/bin/"*.sh "$MFB/fly"
for f in "$MAC/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done
TV="FLY_API_TOKEN_$(echo "$P10" | tr '[:lower:].-' '[:upper:]__')"
( cd "$KT" && env "${ENVS[@]}" JOBS_SETTINGS_CACHE_S=0 HARNESS="$MAC" FLY_BIN_DIR="$MFB" FLEET_CONF="$MAC/fleet.conf" FLY_MACHINE_ID=m1 \
    "$TV=fixture-fly-token" POOL_HARNESS_SRC="$SRCD" LANE_RUN=1 bash "$MAC/bin/lane-run-worker.sh" --once --machine m1 ) > "$KT/mrun.out" 2> "$KT/mrun.err"
R=$(rows "$P10" | jq -c '.[0]')
[ "$(jq -r .status <<<"$R")" = done ] && [ "$(jq -r .rc <<<"$R")" = 0 ] && ok "B10 the batch row ends done rc 0" || bad "B10 row: $R; $(tail -3 "$MAC/logs/lane-run-worker.log" 2>/dev/null) $(tail -3 "$KT/mrun.err")"
jq -r .prof_line <<<"$R" | grep -q '^PROF fly-pool-project state=TICKED ' && ok "B10 PROF fly-pool-project state=TICKED" || bad "B10 prof: $(jq -r .prof_line <<<"$R")"
[ "$(cat "$MAC/ticks.txt" 2>/dev/null)" = "tick $P10" ] && ok "B10 the entry ran the tick for exactly $P10" || bad "B10 ticks: $(cat "$MAC/ticks.txt" 2>/dev/null)"
HREF="$KT/b10-hubref"; mkdir -p "$HREF"; printf '%s\n' "$STUB" > "$KT/stub.sh"
HARNESS="$HREF" bash "$KT/stub.sh" "$P10"
diff -r "$HREF/state/fly-pool" "$MAC/state/fly-pool" >/dev/null && ok "B10 the machine tick wrote the same files as a hub run of the stub" \
  || bad "B10 files differ: $(diff -r "$HREF/state/fly-pool" "$MAC/state/fly-pool" 2>&1 | head -3)"

# ============================================================================
echo "B1: 13 projects placed fly, no rows — one batch call, no hub start"
B1P=(); for i in $(seq -w 1 13); do B1P+=("b1-p$i"); done
H1=$(mkhub b1 "${B1P[@]}")
V='{"lane_placement.fly-pool":"fly"}'
for p in "${B1P[@]}"; do
  case "$p" in
    b1-p12) V=$(jq -c --arg k "lane_placement.fly-pool.$p" '.[$k] = " FLY \n"' <<<"$V") ;;   # B1b
    b1-p13) ;;                                                                         # B1c: the lane row
    *) V=$(jq -c --arg k "lane_placement.fly-pool.$p" '.[$k] = "fly"' <<<"$V") ;;
  esac
done
cache "$H1" "$V"; fresh_pub "$H1" "${B1P[@]}"
: > "$KT/vendor.txt"
tick "$H1"
B1_FORK=$NFORK; B1_HTTP=$(grep -c . "$H1/http.log")
[ "$NBATCH" = 1 ] && ok "B1 exactly 1 POST /api/lane-runs/batch" || bad "B1 batch POSTs: $NBATCH"
[ "$NSINGLE" = 0 ] && ok "B1 0 single POST /api/lane-runs" || bad "B1 single POSTs: $NSINGLE"
NQ=0
for p in "${B1P[@]}"; do
  [ "$(rows "$p" | jq -c '[.[] | select(.status == "queued")] | length')" = 1 ] && NQ=$((NQ + 1))
done
NA=$(jq -c '.rows[] | select(.args == ["bin/fly-pool-project.sh"]) | .project' "$KT/batch-bodies.jsonl" 2>/dev/null | grep -c '"b1-p')
[ "$NQ" = 13 ] && ok "B1 one queued fly-pool row per project (13)" || bad "B1 queued rows: $NQ of 13; log: $(tail -3 "$H1/logs/fly-pool.log")"
[ "$NA" = 13 ] && ok "B1 every batch row has args [bin/fly-pool-project.sh]" || bad "B1 args right on $NA of 13: $(tail -c 300 "$KT/batch-bodies.jsonl" 2>/dev/null)"
[ "$(nstarted "$H1" "${B1P[@]}")" = 0 ] && ok "B1 0 bin/fly-pool.sh starts for the 13 fly projects" || bad "B1 started: $(nstarted "$H1" "${B1P[@]}") ($(ls "$H1/locks"))"
[ "$(vendor_n)" = 0 ] && ok "B1 0 fly/flyctl/gh calls" || bad "B1 vendor calls: $(head -3 "$KT/vendor.txt")"
[ "$B1_FORK" -le 300 ] && ok "B1 $B1_FORK forks for 13 projects (<= 300)" || bad "B1 forks: $B1_FORK > 300 ($(sort "$FORKLOG" | uniq -c | sort -rn | head -5 | tr '\n' ' '))"
[ "$(lines "$H1" '(batch) — no hub pool work')" = 13 ] && ok "B1 13 enqueued (batch) lines" || bad "B1 lines: $(tail -3 "$H1/logs/fly-pool.log")"
grep -q '\[pool\] batch: 13 enqueued, 0 live, 0 skipped live, 0 to hub (1 batch call(s))' "$H1/logs/fly-pool.log" \
  && ok "B1 one summary line" || bad "B1 summary: $(grep 'batch:' "$H1/logs/fly-pool.log")"
[ -s "$H1/state/pool-fly/b1-p01.placed" ] && ok "B1 the placed mark is written" || bad "B1 no placed mark"
echo "  info B1 forks by command: $(sort "$FORKLOG" | uniq -c | sort -rn | awk '{printf "%s=%s ", $2, $1}')"
echo "  info B1 counts (13 fly projects, publish throttled): forks=$B1_FORK http=$B1_HTTP batch=$NBATCH single=$NSINGLE by-prefix=$NPREFIX"
# The publish-due tick, for the note (A2): printed, not asserted.
B1D=(); for i in $(seq -w 1 13); do B1D+=("b1d-p$i"); done
H1D=$(mkhub b1d "${B1D[@]}"); cache "$H1D" '{"lane_placement.fly-pool":"fly"}'
tick "$H1D"
echo "  info B1 counts (13 fly projects, every publish due): forks=$NFORK http=$(grep -c . "$H1D/http.log") batch=$NBATCH single=$NSINGLE"

# ============================================================================
echo "B2: a second tick while every row is live; then one row done"
: > "$KT/vendor.txt"; : > "$H1/logs/fly-pool.log"
tick "$H1"
[ "$NBATCH" = 0 ] && ok "B2 0 batch POSTs while every row is queued" || bad "B2 batch POSTs: $NBATCH"
[ "$NSINGLE" = 0 ] && ok "B2 0 single POSTs" || bad "B2 single POSTs: $NSINGLE"
[ "$(lines "$H1" 'is queued — no hub pool work this tick (batch)')" = 13 ] && ok "B2 13 skip lines" || bad "B2 skip lines: $(tail -3 "$H1/logs/fly-pool.log")"
[ "$(nstarted "$H1" "${B1P[@]}")" = 0 ] && ok "B2 0 starts" || bad "B2 started: $(ls "$H1/locks")"
[ "$NFORK" -le 300 ] && ok "B2 $NFORK forks (<= 300)" || bad "B2 forks: $NFORK"
[ "$(vendor_n)" = 0 ] && ok "B2 0 fly/flyctl/gh calls" || bad "B2 vendor calls: $(head -3 "$KT/vendor.txt")"
finish b1-p05 0 "$PROF0"
: > "$H1/logs/fly-pool.log"
tick "$H1"
[ "$NBATCH" = 1 ] && grep -q '\[pool/b1-p05\] placed fly: enqueued fly-pool b1-p05 (batch)' "$H1/logs/fly-pool.log" \
  && [ "$(lines "$H1" 'enqueued fly-pool')" = 1 ] && ok "B2 the done project alone is in the next batch" || bad "B2 after done: batch=$NBATCH $(grep -v 'is queued' "$H1/logs/fly-pool.log")"
[ "$(rows b1-p05 | jq '[.[] | select(.status == "queued")] | length')" = 1 ] && ok "B2 b1-p05 has a new queued row" || bad "B2 rows: $(rows b1-p05)"
# A claimed row is live too: skipped, and the line names it claimed.
api POST /api/lane-runs/claim '{"machine":"m-test","lanes":["fly-pool"],"only_prefixes":["b1-p07"]}' >/dev/null
: > "$H1/logs/fly-pool.log"
tick "$H1"
grep -q '\[pool/b1-p07\] placed fly: row [0-9]* is claimed — no hub pool work this tick (batch)' "$H1/logs/fly-pool.log" && ! started "$H1" b1-p07 && [ "$NBATCH" = 0 ] \
  && ok "B2 a claimed row is skipped as live" || bad "B2 claimed: batch=$NBATCH $(grep b1-p07 "$H1/logs/fly-pool.log")"

# ============================================================================
echo "B3: mixed placements — only the fly steady states batch"
B3P=(b3-fly b3-hub b3-none b3-def b3-bad b3-rb b3-wd)
H3=$(mkhub b3 "${B3P[@]}")
cache "$H3" '{"lane_placement.default":"fly","lane_placement.fly-pool.b3-fly":"fly","lane_placement.fly-pool.b3-hub":"hub","lane_placement.fly-pool.b3-bad":"flyy","lane_placement.fly-pool.b3-rb":"hub","lane_placement.fly-pool.b3-wd":"fly"}'
mkdir -p "$H3/state/pool-fly"; echo fly > "$H3/state/pool-fly/b3-rb.placed"
withdraw "$(enq b3-wd)"
fresh_pub "$H3" "${B3P[@]}"
tick "$H3"
[ "$NBATCH" = 1 ] && ok "B3 one batch POST" || bad "B3 batch POSTs: $NBATCH"
for p in b3-fly b3-wd; do
  ! started "$H3" "$p" && [ "$(rows "$p" | jq '[.[] | select(.status == "queued")] | length')" = 1 ] \
    && ok "B3 $p batched (a queued row, no start)" || bad "B3 $p: started=$(started "$H3" "$p" && echo y) rows=$(rows "$p")"
done
for p in b3-hub b3-none b3-def b3-bad b3-rb; do
  started "$H3" "$p" && ok "B3 $p started as today" || bad "B3 $p not started: $(grep "$p" "$H3/logs/fly-pool.log" | tail -2)"
done
[ "$(rows b3-def | jq length)" = 0 ] && ok "B3 the default row places no pool (no row for b3-def)" || bad "B3 b3-def rows: $(rows b3-def)"

# ============================================================================
echo "B4: rows that need a decision go to the hub, and pp_gate decides them"
B4P=(b4-stale b4-fail b4-nop b4-def b4-back)
H4=$(mkhub b4 "${B4P[@]}")
V='{}'; for p in "${B4P[@]}"; do V=$(jq -c --arg k "lane_placement.fly-pool.$p" '.[$k] = "fly"' <<<"$V"); done
cache "$H4" "$V"
SID=$(enq b4-stale)
enq b4-fail >/dev/null; finish b4-fail 1 "$PROF0"
enq b4-nop >/dev/null; finish b4-nop 0 "no prof here"
enq b4-def >/dev/null; finish b4-def 0 'PROF fly-pool-project state=DEFERRED spawned=0 reaped=0 deferred=fly-binary fence=1'
mkdir -p "$H4/state/pool-fly"; date -u +%s > "$H4/state/pool-fly/b4-back.takeback-at"
fresh_pub "$H4" "${B4P[@]}"
tick "$H4" POOL_FLY_QUEUE_STALE_S=0
[ "$NBATCH" = 0 ] && ok "B4 0 batch POSTs" || bad "B4 batch POSTs: $NBATCH ($(grep 'batch' "$H4/logs/fly-pool.log"))"
[ "$(nstarted "$H4" "${B4P[@]}")" = 5 ] && ok "B4 all 5 started" || bad "B4 started: $(ls "$H4/locks")"
[ "$(rows b4-stale | jq -r --argjson id "$SID" '.[] | select(.id == $id) | .status')" = died ] \
  && ok "B4 the stale row ends withdrawn by pp_gate (the hub's own take-back)" || bad "B4 stale row: $(rows b4-stale)"
grep -q '\[pool/b4-back\] placed fly: backoff' "$H4/logs/fly-pool.log" && ok "B4 pp_gate ran the backoff for b4-back" || bad "B4 backoff: $(grep b4-back "$H4/logs/fly-pool.log")"

# ============================================================================
echo "B5: the batch call fails — the projects left out go to pp_gate"
b5() { # b5 <tag> <answer-json|-> — 3 fly projects b5<tag>-a..c
  local t="$1" h p
  B5P=("b5$t-a" "b5$t-b" "b5$t-c")
  h=$(mkhub "b5$t" "${B5P[@]}")
  V='{}'; for p in "${B5P[@]}"; do V=$(jq -c --arg k "lane_placement.fly-pool.$p" '.[$k] = "fly"' <<<"$V"); done
  cache "$h" "$V"; fresh_pub "$h" "${B5P[@]}"
  [ "$2" = - ] || answer "$2"
  tick "$h"
  answer '{}'
  H5="$h"
}
b5 404 '{"path_prefix":"/api/lane-runs/batch","status":404,"body":"{}"}'
[ "$NBATCH" = 1 ] && [ "$(nstarted "$H5" "${B5P[@]}")" = 3 ] && ok "B5 404: every fly project started" || bad "B5 404: batch=$NBATCH started=$(ls "$H5/locks")"
[ "$NSINGLE" = 3 ] && ok "B5 404: pp_gate posts one POST /api/lane-runs each (3)" || bad "B5 404 single POSTs: $NSINGLE"
[ ! -s "$H5/logs/ALERTS.log" ] && ok "B5 404: no wrapper alert" || bad "B5 404 alerts: $(cat "$H5/logs/ALERTS.log")"
b5 500 '{"path_prefix":"/api/lane-runs/batch","status":500,"body":"{}"}'
[ "$(nstarted "$H5" "${B5P[@]}")" = 3 ] && ok "B5 500: every fly project started" || bad "B5 500: started=$(ls "$H5/locks")"
[ "$(lines "$H5" 'enqueued fly-pool .* (batch)')" = 0 ] && ok "B5 500: no (batch) enqueued line" || bad "B5 500 lines: $(grep batch "$H5/logs/fly-pool.log")"
PART='{"path_prefix":"/api/lane-runs/batch","status":200,"body":"{\"lane\":\"fly-pool\",\"rows\":[{\"project\":\"b5part-a\",\"status\":\"enqueued\",\"id\":9001},{\"project\":\"b5part-b\",\"status\":\"already_live\"}]}"}'
b5 part "$PART"
! started "$H5" b5part-a && ! started "$H5" b5part-b && started "$H5" b5part-c \
  && ok "B5 partial: the project left out (c) is started, a and b are not" || bad "B5 partial: started=$(ls "$H5/locks")"
grep -q '\[pool/b5part-a\] placed fly: enqueued fly-pool b5part-a (batch)' "$H5/logs/fly-pool.log" \
  && grep -q '\[pool/b5part-b\] placed fly: a row of b5part-b is already live (batch)' "$H5/logs/fly-pool.log" \
  && ok "B5 partial: a has its enqueued line, b its already-live line" || bad "B5 partial lines: $(grep batch "$H5/logs/fly-pool.log")"
[ "$(lines "$H5" 'enqueued fly-pool b5part-c (batch)')" = 0 ] && ok "B5 partial: no enqueued line for the left-out c" || bad "B5 partial: c logged enqueued"
grep -q '\[pool\] batch: 1 enqueued, 1 live, 0 skipped live, 1 to hub' "$H5/logs/fly-pool.log" && ok "B5 partial: the summary counts the answer" || bad "B5 summary: $(grep 'batch:' "$H5/logs/fly-pool.log")"
[ ! -s "$H5/logs/ALERTS.log" ] && ok "B5 partial: no wrapper alert" || bad "B5 alerts: $(cat "$H5/logs/ALERTS.log")"

# ============================================================================
echo "B6: POOL_TICK_BATCH=0 — today's starts"
B6P=(b6-a b6-b b6-c); H6=$(mkhub b6 "${B6P[@]}")
cache "$H6" '{"lane_placement.fly-pool.b6-a":"fly","lane_placement.fly-pool.b6-b":"fly","lane_placement.fly-pool.b6-c":"fly"}'
tick "$H6" POOL_TICK_BATCH=0
[ "$(nstarted "$H6" "${B6P[@]}")" = 3 ] && ok "B6 every project started" || bad "B6 started: $(ls "$H6/locks")"
[ "$NBATCH" = 0 ] && ok "B6 0 batch POSTs" || bad "B6 batch POSTs: $NBATCH"
[ "$(lines "$H6" '(batch)')" = 0 ] && ok "B6 no (batch) line" || bad "B6 lines: $(grep batch "$H6/logs/fly-pool.log")"

# ============================================================================
echo "B7: no fly row in a fresh cache — no call, every project started"
B7P=(b7-a b7-b); H7=$(mkhub b7 "${B7P[@]}")
cache "$H7" '{"lane_placement.fly-pool.b7-a":"hub"}'
tick "$H7"
[ "$(nstarted "$H7" "${B7P[@]}")" = 2 ] && ok "B7 every project started" || bad "B7 started: $(ls "$H7/locks")"
[ "$NPREFIX" = 0 ] && [ "$NBATCH" = 0 ] && ok "B7 0 by-prefix reads, 0 batch POSTs" || bad "B7 by-prefix=$NPREFIX batch=$NBATCH"
[ "$(lines "$H7" '\[pool\] batch:')" = 0 ] && ok "B7 no summary line" || bad "B7 summary written"
H7W=$(mkhub b7w); cache "$H7W" '{}'; tick "$H7W"
echo "  info the wrapper with no project at all: forks=$NFORK (its own fixed cost)"

# ============================================================================
echo "B8: hub_only set — every project started"
B8P=(b8-a b8-b); H8=$(mkhub b8 "${B8P[@]}")
cache "$H8" '{"lane_placement.fly-pool.hub_only":"maintenance","lane_placement.fly-pool.b8-a":"fly","lane_placement.fly-pool.b8-b":"fly"}'
tick "$H8"
[ "$(nstarted "$H8" "${B8P[@]}")" = 2 ] && ok "B8 every project started" || bad "B8 started: $(ls "$H8/locks")"
[ "$NBATCH" = 0 ] && ok "B8 0 batch POSTs" || bad "B8 batch POSTs: $NBATCH"

# ============================================================================
echo "B9: a held project lock — that project is started (its lock turns it away), the others batch"
B9P=(b9-held b9-a b9-b); H9=$(mkhub b9 "${B9P[@]}")
cache "$H9" '{"lane_placement.fly-pool":"fly"}'; fresh_pub "$H9" "${B9P[@]}"
( exec 9>"$H9/locks/fly-pool-b9-held.lock"; flock 9; sleep 60 ) & HOLDERS+=("$!")
for _ in $(seq 1 50); do ( exec 9>>"$H9/locks/fly-pool-b9-held.lock"; flock -n 9 ) 2>/dev/null || break; sleep 0.1; done
tick "$H9"
grep -q '\[pool/b9-held\] already running' "$H9/logs/fly-pool.log" && ok "B9 the held project was started and its lock turned it away" || bad "B9 held: $(grep b9-held "$H9/logs/fly-pool.log")"
[ "$(rows b9-held | jq length)" = 0 ] && ok "B9 the held project is not batched" || bad "B9 held rows: $(rows b9-held)"
! started "$H9" b9-a && ! started "$H9" b9-b && [ "$NBATCH" = 1 ] && ok "B9 the others batch (1 POST, no start)" || bad "B9 others: batch=$NBATCH locks=$(ls "$H9/locks")"
kill "${HOLDERS[@]}" 2>/dev/null

# ============================================================================
echo "B11: hub load over — fly projects still batch"
B11P=(b11-a b11-b); H11=$(mkhub b11 "${B11P[@]}")
cache "$H11" '{"lane_placement.fly-pool":"fly"}'; fresh_pub "$H11" "${B11P[@]}"
mkdir -p "$H11/state/hub-load"
printf 'v=1\tat=%s\trunnable=90\tp90=90\tmax=8\tstate=over\tmax_age_s=1800\tshed=1\n' "$(date -u +%s)" > "$H11/state/hub-load/verdict"
tick "$H11"
[ "$NBATCH" = 1 ] && [ "$(nstarted "$H11" "${B11P[@]}")" = 0 ] && ok "B11 1 batch POST, 0 starts under load shed" || bad "B11 batch=$NBATCH locks=$(ls "$H11/locks"); $(tail -2 "$H11/logs/fly-pool.log")"

# ============================================================================
echo "B12: box placement — batched with its tag; box-silent goes to the hub"
H12=$(mkhub b12 b12-box); cache "$H12" '{"lane_placement.fly-pool.b12-box":"box:mk-box"}'; fresh_pub "$H12" b12-box
tick "$H12"
[ "$NBATCH" = 1 ] && ! started "$H12" b12-box && ok "B12 box:mk-box batched, not started" || bad "B12 batch=$NBATCH locks=$(ls "$H12/locks")"
grep -q '\[pool/b12-box\] placed box:mk-box: enqueued fly-pool b12-box (batch)' "$H12/logs/fly-pool.log" && ok "B12 the line says placed box:mk-box" || bad "B12 line: $(grep b12 "$H12/logs/fly-pool.log")"
[ "$(cat "$H12/state/pool-fly/b12-box.placed")" = box:mk-box ] && ok "B12 the placed mark says box:mk-box" || bad "B12 mark: $(cat "$H12/state/pool-fly/b12-box.placed")"
H12S=$(mkhub b12s b12-silent); cache "$H12S" '{"lane_placement.fly-pool.b12-silent":"box:mk-box"}'
answer '{"path_prefix":"/api/lane-runs/by-prefix","status":200,"body":"{\"rows\":[{\"id\":77001,\"lane\":\"fly-pool\",\"project\":\"b12-silent\",\"status\":\"claimed\",\"lease_until\":\"2000-01-01T00:00:00Z\"}]}"}'
tick "$H12S"
answer '{}'
started "$H12S" b12-silent && [ "$NBATCH" = 0 ] && ok "B12 a claimed row past its lease (box-silent) is started, not batched" || bad "B12 silent: batch=$NBATCH locks=$(ls "$H12S/locks")"
grep -q '\[pool/b12-silent\] placed box:mk-box: fallback=no-capacity (row 77001: box-silent)' "$H12S/logs/fly-pool.log" \
  && ok "B12 pp_gate ran the box-silent take-back" || bad "B12 silent log: $(grep b12-silent "$H12S/logs/fly-pool.log")"

# ============================================================================
echo "B13: POOL_TICK_MAX_PARALLEL=1 — the cap counts the started projects only"
B13P=(b13-f1 b13-f2 b13-f3 b13-h1 b13-h2); H13=$(mkhub b13 "${B13P[@]}")
cache "$H13" '{"lane_placement.fly-pool.b13-f1":"fly","lane_placement.fly-pool.b13-f2":"fly","lane_placement.fly-pool.b13-f3":"fly"}'
fresh_pub "$H13" "${B13P[@]}"
tick "$H13" POOL_TICK_MAX_PARALLEL=1
[ "$NBATCH" = 1 ] && [ "$(nstarted "$H13" b13-f1 b13-f2 b13-f3)" = 0 ] && ok "B13 3 fly projects batched" || bad "B13 batch=$NBATCH locks=$(ls "$H13/locks")"
[ "$(nstarted "$H13" b13-h1 b13-h2)" = 1 ] && ok "B13 1 hub project started" || bad "B13 hub started: $(ls "$H13/locks")"
[ "$(lines "$H13" 'max-ticks: 1 of 1 running')" = 1 ] && ok "B13 1 max-ticks line for the other hub project" || bad "B13 max-ticks: $(grep max-ticks "$H13/logs/fly-pool.log")"

echo "fly-pool-tick-batch.bh-7432: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
