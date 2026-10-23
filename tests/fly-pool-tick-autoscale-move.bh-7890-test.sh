#!/bin/bash
# tests/fly-pool-tick-autoscale-move.bh-7890-test.sh — BH-7890 (rest of
# BH-7433): the pool tick wrapper (bin/fly-pool-tick.sh) classifies the
# projects first (ptb_split) and runs the lock guard and the autoscale read
# (bin/pool-cap.sh --autoscale) only for the projects that stay on the hub.
# For fly-placed projects the lane-fleet autoscaler (bin/lane-fleet.sh
# lf_decide, BH-6885) decides how many lane machines run their rows.
#
# The fixture is the one of tests/fly-pool-tick-batch.bh-7432-test.sh: the REAL
# wrapper, the REAL ptb_split and pool-placement libs, the REAL bin/fly-pool.sh
# and the REAL jobs worker on node:sqlite (tests/lib/mc-budget.bh-6887.mjs).
# `fly`, `flyctl` and `gh` are stubs that record into vendor.txt (asserted
# empty: 0 vendor calls). bin/pool-cap.sh, bin/fly-lock-guard.sh,
# bin/fly-pool-rows-parity.sh, bin/pool-budget.sh and bin/fly-onboard.sh are
# stubs that append one line to <hub>/starts.log. A start of the real
# bin/fly-pool.sh is its locks/fly-pool-<p>.lock (BH-7432 rule). A PATH shim
# counts forks. Every case has its own hub root and its own project names.
#
#   A1  13 projects placed fly, no rows, AS=1: 1 batch POST, 0 starts,
#       guard=0, pool-cap=0, no .since stamp, 0 vendor calls
#   A2  the same with POOL_AUTOSCALE=0 (the stub answers 0): 1 batch POST,
#       0 starts, guard=0, pool-cap=0
#   A3  no fly row, 3 projects, AS=1: 3 starts, guard=1, pool-cap=1, stamps
#   A4  no fly row, 3 projects, AS=0: 3 starts in flag-glob order, one at a
#       time, guard=1, pool-cap=1
#   A5  12 placed fly + 1 placed hub, AS=0: 1 batch POST of 12, 1 start
#   A6  all fly, one project lock held: that one goes to the hub, guard=1,
#       the other 12 batch
#   A7  all fly, one onboard attempt due on the hub: the guard runs once,
#       before the onboard launch; pool-cap=0
#   A8  all fly, the onboard project gave up: no launch, guard=0
#   A9  no pool flag at all: guard=0, pool-cap=0, exit 0
#
# BH7890_WRAPPER=<file> installs another wrapper in the scratch root (the red
# run and the "before" numbers use origin/main's: `git show
# origin/main:bin/fly-pool-tick.sh > /tmp/w.sh; BH7890_WRAPPER=/tmp/w.sh ...`).
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-tick-autoscale-move.bh-7890-test.sh
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
         bin/lib/project-lease.sh bin/lib/lane-run-inputs.sh bin/jobs-client.sh bin/lib/hub-load-shed.sh \
         bin/lib/hub-box.sh bin/lib/env-path.sh; do
  [ -e "$DIR/$L" ] || continue
  ( cd "$DIR" && scratch_install_closure "$L" "$TPL" ) >/dev/null 2>&1 || bad "setup: closure of $L failed"
done
if [ -n "${BH7890_WRAPPER:-}" ]; then
  cp "$BH7890_WRAPPER" "$TPL/bin/fly-pool-tick.sh" || { echo "FAIL: cannot install $BH7890_WRAPPER"; exit 1; }
  echo "  info wrapper under test: $BH7890_WRAPPER"
fi
mkdir -p "$TPL/logs" "$TPL/flags" "$TPL/locks" "$TPL/env" "$TPL/state/fly" "$TPL/catalog"
cp -r "$DIR/catalog/lane-run-inputs.d" "$TPL/catalog/"
: > "$TPL/env/global.env"; : > "$TPL/env/fly.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "${HARNESS:?}/logs/ALERTS.log"\nexit 0\n' > "$TPL/bin/lane-alert.sh"
cp "$TPL/bin/lane-alert.sh" "$TPL/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$TPL/bin/beat.sh"
# The counted children: one line each in <hub>/starts.log. The cap answers
# STUB_AS (default 1, autoscale on).
printf '#!/bin/bash\necho "pool-cap $*" >> "${HARNESS:?}/starts.log"\necho "${STUB_AS:-1}"\n' > "$TPL/bin/pool-cap.sh"
printf '#!/bin/bash\necho guard >> "${HARNESS:?}/starts.log"\nexit 0\n' > "$TPL/bin/fly-lock-guard.sh"
printf '#!/bin/bash\necho parity >> "${HARNESS:?}/starts.log"\nexit 0\n' > "$TPL/bin/fly-pool-rows-parity.sh"
printf '#!/bin/bash\necho budget >> "${HARNESS:?}/starts.log"\nexit 0\n' > "$TPL/bin/pool-budget.sh"
printf '#!/bin/bash\necho "onboard $1" >> "${HARNESS:?}/starts.log"\nexit 0\n' > "$TPL/bin/fly-onboard.sh"
rm -f "$TPL/bin/box-name.sh"
chmod +x "$TPL/bin/"*.sh 2>/dev/null
for f in "$TPL/bin/"*.sh; do sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"; done

for c in fly flyctl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.txt"\ncase "$*" in *"machines list"*|*"machine list"*) echo "[]" ;; esac\nexit 0\n' "$c" "$KT" > "$FB/$c"
done
printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
chmod +x "$FB/"*
export FORKLOG="$KT/forks.log"
for c in jq curl mkdir setsid cksum cat date hostname awk sed grep tr head tail cut sort uniq \
         mktemp rm mv cp flock sleep env wc bash dirname basename find ls stat tar gzip base64 sha256sum xargs nproc pgrep ps touch chmod ln readlink realpath printf seq; do
  real=$(command -v "$c") || continue
  case "$real" in /*) ;; *) continue ;; esac
  printf '#!/bin/bash\nprintf "%%s\\n" %s >> "$FORKLOG"\nexec %s "$@"\n' "$c" "$real" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done

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
rows() { api GET "/api/lane-runs/by-prefix?lane=$LANE&project_prefix=$1&limit=50" | jq -c --arg p "$1" '[.rows[] | select(.project == $p)]'; }

# mkhub <case> <project>... — a fresh hub root: a flag, an app record and a
# fleet line per project. Prints the root.
mkhub() {
  local h="$KT/$1" p; shift
  cp -a "$TPL" "$h"
  : > "$h/fleet.conf"; : > "$h/starts.log"
  for p in "$@"; do
    : > "$h/flags/fly-pool-$p"
    printf '{"app":"pool-%s"}\n' "$p" > "$h/state/fly/$p.json"
    printf '%s example-org/%s - - 1 local local\n' "$p" "$p" >> "$h/fleet.conf"
  done
  printf '%s' "$h"
}
cache() { printf '{"fetched_at":%s,"seeded":{"lane_placement.default":"hub"},"values":%s}\n' "$(date -u +%s)" "$2" > "$1/state/settings-cache.json"; }
fresh_pub() { local h="$1" p; shift; mkdir -p "$h/state/pool-fly"; for p in "$@"; do date -u +%s > "$h/state/pool-fly/$p.published-at"; done; }
allfly() { local v='{"lane_placement.fly-pool":"fly"}' p; for p in "$@"; do v=$(jq -c --arg k "lane_placement.fly-pool.$p" '.[$k] = "fly"' <<<"$v"); done; printf '%s' "$v"; }
ENVS=(HARNESS_SECRET=fixture-harness-secret JOBS_URL="$W" GH_TOKEN=pat-fixture JOBS_SETTINGS_CACHE_S=600 JOBS_RETRIES=0
  JOBS_OVERLOAD_RETRIES=0 BOX_NAME=fixture-box HUB_BOX_NAME=other-hub POOL_TICK_BUDGET_S=20 POOL_TICK_WAIT_S=60 POOL_TICK_MAX_PARALLEL=0)
# tick <hub> [VAR=val...] — one wrapper run. Sets RC, NFORK, NBATCH, and the
# child counts NGUARD, NCAP, NPAR, NBUD from <hub>/starts.log.
tick() {
  local h="$1" s0; shift
  s0=$(wc -l < "$T/srv.log"); : > "$FORKLOG"; : > "$h/starts.log"
  ( cd "$KT" && env "${ENVS[@]}" HARNESS="$h" FLEET_CONF="$h/fleet.conf" FLY_BIN_DIR="$FB" PATH="$SHIM:$FB:$PATH" "$@" \
      bash "$h/bin/fly-pool-tick.sh" > "$h/tick.out" 2> "$h/tick.err" )
  RC=$?
  local i; for i in $(seq 1 300); do pgrep -f "$h/bin/fly-pool.sh" >/dev/null 2>&1 || break; sleep 0.1; done
  NFORK=$(grep -c . "$FORKLOG")
  tail -n +"$((s0 + 1))" "$T/srv.log" > "$h/http.log"
  NBATCH=$(grep -c '^POST /api/lane-runs/batch ' "$h/http.log")
  NGUARD=$(grep -cx guard "$h/starts.log"); NCAP=$(grep -cx 'pool-cap --autoscale' "$h/starts.log")
  NPAR=$(grep -cx parity "$h/starts.log"); NBUD=$(grep -cx budget "$h/starts.log")
}
started() { [ -e "$1/locks/fly-pool-$2.lock" ]; }
nstarted() { local h="$1" p n=0; shift; for p in "$@"; do started "$h" "$p" && n=$((n + 1)); done; echo "$n"; }
vendor_n() { grep -c . "$KT/vendor.txt" 2>/dev/null || true; }
nstamps() { local h="$1" p n=0; shift; for p in "$@"; do [ -s "$h/state/fly-pool-tick/$p.since" ] && n=$((n + 1)); done; echo "$n"; }
countline() { echo "bh7890: AS=$1 projects=$2 fly-pool=$3 guard=$NGUARD pool-cap=$NCAP parity=$NPAR budget=$NBUD forks=$NFORK"; }

# ============================================================================
for MODE in 1 0; do
  C=$([ "$MODE" = 1 ] && echo A1 || echo A2)
  echo "$C: 13 projects placed fly, no rows, autoscale=$MODE — no hub decision"
  PS=(); for i in $(seq -w 1 13); do PS+=("${C,,}-p$i"); done
  H=$(mkhub "${C,,}" "${PS[@]}"); cache "$H" "$(allfly "${PS[@]}")"; fresh_pub "$H" "${PS[@]}"
  : > "$KT/vendor.txt"
  tick "$H" STUB_AS="$MODE" POOL_AUTOSCALE="$MODE"
  N=$(nstarted "$H" "${PS[@]}")
  countline "$MODE" 13 "$N"
  [ "$NBATCH" = 1 ] && ok "$C 1 batch POST" || bad "$C batch POSTs: $NBATCH"
  [ "$N" = 0 ] && ok "$C 0 bin/fly-pool.sh starts" || bad "$C started: $N ($(ls "$H/locks" | tr '\n' ' '))"
  [ "$NGUARD" = 0 ] && ok "$C guard=0" || bad "$C guard=$NGUARD"
  [ "$NCAP" = 0 ] && ok "$C pool-cap=0 (no --autoscale read)" || bad "$C pool-cap=$NCAP"
  [ "$(nstamps "$H" "${PS[@]}")" = 0 ] && ok "$C no state/fly-pool-tick/<p>.since" || bad "$C stamps: $(nstamps "$H" "${PS[@]}")"
  [ "$(vendor_n)" = 0 ] && ok "$C 0 fly/flyctl/gh calls" || bad "$C vendor calls: $(head -3 "$KT/vendor.txt")"
  [ "$RC" = 0 ] && ok "$C exit 0" || bad "$C rc=$RC"
done

# ============================================================================
echo "A3: no fly row, 3 projects, autoscale on — the hub decision as today"
PS=(a3-a a3-b a3-c); H=$(mkhub a3 "${PS[@]}"); cache "$H" '{}'
tick "$H"
[ "$(nstarted "$H" "${PS[@]}")" = 3 ] && ok "A3 3 starts" || bad "A3 started: $(ls "$H/locks" | tr '\n' ' ')"
[ "$NGUARD" = 1 ] && [ "$NCAP" = 1 ] && ok "A3 guard=1 pool-cap=1" || bad "A3 guard=$NGUARD pool-cap=$NCAP"
[ "$(nstamps "$H" "${PS[@]}")" = 3 ] && ok "A3 3 .since stamps" || bad "A3 stamps: $(nstamps "$H" "${PS[@]}")"
[ "$NBATCH" = 0 ] && ok "A3 0 batch POSTs" || bad "A3 batch POSTs: $NBATCH"

# ============================================================================
echo "A4: no fly row, 3 projects, POOL_AUTOSCALE=0 — the sequential sweep"
PS=(a4-a a4-b a4-c); H=$(mkhub a4 "${PS[@]}"); cache "$H" '{}'
# A recording fly-pool.sh: a start line, a short run, an end line.
printf '#!/usr/bin/env bash\necho "start $1" >> "${HARNESS:?}/starts.log"\nsleep 0.3\necho "end $1" >> "${HARNESS:?}/starts.log"\n' > "$H/bin/fly-pool.sh"
tick "$H" STUB_AS=0
SEQ=$(grep -E '^(start|end) ' "$H/starts.log" | tr '\n' ' ')
[ "$SEQ" = "start a4-a end a4-a start a4-b end a4-b start a4-c end a4-c " ] && ok "A4 3 starts in flag-glob order, one at a time" || bad "A4 order: $SEQ"
[ "$NGUARD" = 1 ] && [ "$NCAP" = 1 ] && ok "A4 guard=1 pool-cap=1" || bad "A4 guard=$NGUARD pool-cap=$NCAP"
G=$(grep -nx guard "$H/starts.log" | cut -d: -f1); S=$(grep -n '^start ' "$H/starts.log" | head -1 | cut -d: -f1)
[ -n "$G" ] && [ -n "$S" ] && [ "$G" -lt "$S" ] && ok "A4 the guard runs before the first start" || bad "A4 guard line $G, first start $S"

# ============================================================================
echo "A5: 12 placed fly + 1 placed hub, POOL_AUTOSCALE=0"
PS=(); for i in $(seq -w 1 12); do PS+=("a5-f$i"); done
H=$(mkhub a5 "${PS[@]}" a5-hub)
cache "$H" "$(allfly "${PS[@]}" | jq -c '.["lane_placement.fly-pool.a5-hub"] = "hub"')"; fresh_pub "$H" "${PS[@]}" a5-hub
tick "$H" STUB_AS=0
[ "$NBATCH" = 1 ] && ok "A5 1 batch POST" || bad "A5 batch POSTs: $NBATCH"
NQ=0; for p in "${PS[@]}"; do [ "$(rows "$p" | jq '[.[] | select(.status == "queued")] | length')" = 1 ] && NQ=$((NQ + 1)); done
[ "$NQ" = 12 ] && ok "A5 12 queued rows (batched)" || bad "A5 queued rows: $NQ"
[ "$(nstarted "$H" "${PS[@]}")" = 0 ] && started "$H" a5-hub && ok "A5 1 start, the hub project" || bad "A5 starts: $(ls "$H/locks" | tr '\n' ' ')"
[ "$NGUARD" = 1 ] && [ "$NCAP" = 1 ] && ok "A5 guard=1 pool-cap=1" || bad "A5 guard=$NGUARD pool-cap=$NCAP"

# ============================================================================
echo "A6: all fly, one project lock held — that project goes to the hub"
PS=(a6-held); for i in $(seq -w 1 12); do PS+=("a6-p$i"); done
H=$(mkhub a6 "${PS[@]}"); cache "$H" "$(allfly "${PS[@]}")"; fresh_pub "$H" "${PS[@]}"
( exec 9>"$H/locks/fly-pool-a6-held.lock"; flock 9; sleep 60 ) & HOLDERS+=("$!")
for _ in $(seq 1 50); do ( exec 9>>"$H/locks/fly-pool-a6-held.lock"; flock -n 9 ) 2>/dev/null || break; sleep 0.1; done
tick "$H"
grep -q '\[pool/a6-held\] already running' "$H/logs/fly-pool.log" && ok "A6 the held project got a hub start" || bad "A6 held: $(grep a6-held "$H/logs/fly-pool.log")"
[ "$(rows a6-held | jq length)" = 0 ] && ok "A6 the held project is not batched" || bad "A6 held rows: $(rows a6-held)"
[ "$NGUARD" = 1 ] && ok "A6 guard=1" || bad "A6 guard=$NGUARD"
[ "$NBATCH" = 1 ] && [ "$(nstarted "$H" "${PS[@]:1}")" = 0 ] && ok "A6 the other 12 batch" || bad "A6 batch=$NBATCH locks=$(ls "$H/locks" | tr '\n' ' ')"
kill "${HOLDERS[@]}" 2>/dev/null

# ============================================================================
# onboard <case> — 3 fly projects plus one queued onboard project on the hub.
onboard() {
  PS=("$1-a" "$1-b" "$1-c"); OB="$1-new"
  H=$(mkhub "$1" "${PS[@]}"); cache "$H" "$(allfly "${PS[@]}")"; fresh_pub "$H" "${PS[@]}"
  mkdir -p "$H/fly"; printf '# queue\n%s\n' "$OB" > "$H/fly/onboard-queue.conf"
}
wait_onboard() { local i; for i in $(seq 1 50); do grep -q '^onboard ' "$1/starts.log" && return 0; sleep 0.1; done; return 1; }
echo "A7: all fly, one onboard attempt due on the hub — the drain guards its launch"
onboard a7
tick "$H" HUB_BOX_NAME=fixture-box
wait_onboard "$H"
[ "$(grep -cx "onboard $OB" "$H/starts.log")" = 1 ] && ok "A7 fly-onboard.sh launched once" || bad "A7 starts.log: $(tr '\n' ' ' < "$H/starts.log")"
[ "$(cat "$H/state/fly-onboard/$OB.attempts" 2>/dev/null)" = 1 ] && ok "A7 attempts file = 1" || bad "A7 attempts: $(cat "$H/state/fly-onboard/$OB.attempts" 2>/dev/null)"
[ "$NGUARD" = 1 ] && [ "$NCAP" = 0 ] && ok "A7 guard=1 pool-cap=0" || bad "A7 guard=$NGUARD pool-cap=$NCAP"
G=$(grep -nx guard "$H/starts.log" | cut -d: -f1); S=$(grep -n '^onboard ' "$H/starts.log" | cut -d: -f1)
[ -n "$G" ] && [ -n "$S" ] && [ "$G" -lt "$S" ] && ok "A7 the guard line is before the onboard launch" || bad "A7 guard line $G, onboard line $S"
[ "$(nstarted "$H" "${PS[@]}")" = 0 ] && [ "$NBATCH" = 1 ] && ok "A7 the fly projects batch, 0 starts" || bad "A7 batch=$NBATCH locks=$(ls "$H/locks" | tr '\n' ' ')"

echo "A8: all fly, the onboard project gave up — no launch, no guard"
onboard a8
: > "$H/flags/alerted-fly-onboard-gaveup-$OB"
tick "$H" HUB_BOX_NAME=fixture-box
sleep 0.5
[ "$(grep -c '^onboard ' "$H/starts.log")" = 0 ] && ok "A8 no onboard launch" || bad "A8 starts.log: $(tr '\n' ' ' < "$H/starts.log")"
[ "$NGUARD" = 0 ] && [ "$NCAP" = 0 ] && ok "A8 guard=0 pool-cap=0" || bad "A8 guard=$NGUARD pool-cap=$NCAP"
# A8b: a not-hub box never drains, so it never guards for the drain.
onboard a8b
tick "$H"
sleep 0.5
[ "$(grep -c '^onboard ' "$H/starts.log")" = 0 ] && [ "$NGUARD" = 0 ] && ok "A8 a not-hub box: no launch, guard=0" || bad "A8b guard=$NGUARD $(tr '\n' ' ' < "$H/starts.log")"

# ============================================================================
echo "A9: no pool flag at all"
H=$(mkhub a9); cache "$H" '{}'
tick "$H"
[ "$NGUARD" = 0 ] && [ "$NCAP" = 0 ] && ok "A9 guard=0 pool-cap=0" || bad "A9 guard=$NGUARD pool-cap=$NCAP"
[ "$RC" = 0 ] && ok "A9 exit 0" || bad "A9 rc=$RC"

echo "fly-pool-tick-autoscale-move.bh-7890: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
