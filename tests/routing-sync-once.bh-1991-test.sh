#!/bin/bash
# tests/routing-sync-once.bh-1991-test.sh — BH-1991, the BH-1627 follow-ups:
#   B1/B1b pr-owner-sweep syncs routing once per process, so its per-PR
#          $(routing_builder) sends no request of its own;
#   B2     fly-pool.sh syncs once, and its second client source keeps the memo;
#   B3     fly-machine-state.sh syncs once before its $(routing_pool_app);
#   B4     bin/routing-flip-preflight.sh writes nothing under $HARNESS, even
#          when the probe fails (the jobs-client log line goes to stderr);
#   B5     knob on, row absent (404, or missing from the list): the files survive.
# Every case drives the REAL scripts against a stubbed curl and counts requests;
# every case has a mutant that must turn it red.
# Run from anywhere: tests/routing-sync-once.bh-1991-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# modules under test, named for bin/test-impact.sh
for f in bin/lib/jobs/routing.sh bin/pr-owner-sweep.sh bin/fly-pool.sh bin/fly-machine-state.sh bin/routing-flip-preflight.sh; do
  bash -n "$DIR/$f" || exit 1
done

H="$T/h"
mkdir -p "$H/logs" "$H/state/fly" "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/env" "$H/fixture" "$T/fakebin" "$T/rows"
cp -R "$DIR/bin" "$H/bin"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
: > "$H/env/fly.env"
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
x       Org/x       https://x.example  /api/board 2 box-x 192.0.2.1
y       Org/y       -                  -          4 box-y 192.0.2.2
EOF

# Fake curl (FIXTURE worker). Rows in $ROWS/<p>.json; knob in $SETTING_JSON.
# CURL_MODE: ok | down | http500 (settings still answer, as in BH-1627's fixture).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/routing_rows)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  http500) printf 'error code: 1101\n500\n'; exit 0 ;;
esac
case "$METHOD $URL" in
  "GET "*/api/routing)
    printf '{"routing":['; first=1
    for f in "$ROWS"/*.json; do [ -f "$f" ] || continue; [ $first = 1 ] || printf ','; first=0; cat "$f"; done
    printf '],"as_of":"2026-09-24T00:00:00Z"}\n200\n' ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*/api/jobs*)  printf '%s\n200\n' "$(cat "$FIXDIR/jobs.json" 2>/dev/null || echo '{"jobs":[]}')" ;;
  "GET "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
for s in ssh rsync scp; do printf '#!/bin/bash\necho "%s $*" >> "$SINK"\ncat >/dev/null\nexit 0\n' "$s" > "$T/fakebin/$s"; done
# fly/flyctl: every argv to the sink; `machine status` answers State: started.
for s in fly flyctl; do
  printf '#!/bin/bash\necho "%s $*" >> "$SINK"\ncase "$*" in *"machine status"*) echo "State: started" ;; *"machines list"*) echo "[]" ;; esac\nexit 0\n' "$s" > "$T/fakebin/$s"
done
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/tailscale"
chmod +x "$T/fakebin"/*

knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null> <halted>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":%s,"updated_at":"2026-09-24T00:00:00Z"}' "$1" "$2" "$app" "$4" > "$T/rows/$1.json"
}
reset() { rm -f "$H"/flags/* "$T"/rows/* "$T/req.log" "$T/sink"; : > "$T/req.log"; : > "$T/sink"; return 0; }
count() { grep -cE "^GET https://jobs.invalid$1\$" "$T/req.log" 2>/dev/null || true; }
lists() { count /api/routing; }
perproj() { count "/api/routing/$1"; }
knobreads() { count /api/settings/routing_rows; }
snap() { ( cd "$1" && find . -type f -printf '%p %s %T@\n' | sort ); }
envrun() {
  env PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
    JOBS_BOX=hub JOBS_RETRIES=0 SETTING_JSON="$T/setting.json" ROWS="$T/rows" REQ_SINK="$T/req.log" \
    SINK="$T/sink" FIXDIR="$H/fixture" CURL_MODE="${CURL_MODE:-ok}" FLEET_CONF="$H/fleet.conf" \
    HARNESS_TEST_SANDBOX=1 FLY_BIN_DIR="$T/fakebin" POOL_SPAWN=0 "$@"
}
POS=$(grep -m1 '^pos_pool_routed() {' "$DIR/bin/pr-owner-sweep.sh")
[ -n "$POS" ] || bad "pos_pool_routed missing from bin/pr-owner-sweep.sh"
point() { # point <expr...> with the client loaded, the real pos_pool_routed defined
  envrun bash -c "H='$H'; . '$H/bin/jobs-client.sh'; $POS; $*" 2>/dev/null
}
# mutate <file> <sed-expr> — put a mutant of a real script at the same path in $H.
mutate() { sed -e "$2" "$DIR/$1" > "$H/$1"; }
restore() { cp "$DIR/$1" "$H/$1"; }

# --- B1. the extracted reader after one top-level sync ---------------------------
reset; knob on; row x pool harness-pool-x 0
point 'routing_sync_all; for i in 1 2 3; do r=$(pos_pool_routed x && echo pool); [ "$r" = pool ] || exit 9; done'; RC=$?
[ "$RC" = 0 ] && ok || bad "B1: pos_pool_routed x must answer pool after the sync (rc=$RC)"
[ "$(lists)" = 1 ] && [ "$(perproj x)" = 0 ] && ok || bad "B1: sync + 3 subshell reads must send 1 list GET, 0 per-project (lists=$(lists) x=$(perproj x))"
reset; knob on; row x pool harness-pool-x 0
point 'for i in 1 2 3; do r=$(pos_pool_routed x && echo pool); done'
[ "$(( $(lists) + $(perproj x) ))" -gt 1 ] && ok || bad "B1 mutant: without the sync each subshell read must send its own request (lists=$(lists) x=$(perproj x))"

# --- B1b. the real bin/pr-owner-sweep.sh, three hand-backs in one run ------------
NOWISO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
D=86400
cp "$DIR/bin/pr-owner-sweep.sh" "$T/pos.orig"
printf '#!/bin/bash\necho box-x\n' > "$H/bin/box-for.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/beat.sh" "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "api rate_limit") n=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$n" "$n"; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*) cat "$FIXDIR/open.json" ;;
  *"pr list"*"--state merged"*) echo '[]' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$T/fakebin/gh"
{
  printf '['
  for n in 1 2 3; do
    [ "$n" = 1 ] || printf ','
    printf '{"number":%s,"title":"XT-%s: orphan","headRefName":"ticket/xt-%s","author":{"login":"operator"},"labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"%s","createdAt":"%s","url":"https://github.com/Org/x/pull/%s","isDraft":false}' \
      "$n" "$n" "$n" "$(NOWISO $((30*D)))" "$(NOWISO $((40*D)))" "$n"
  done
  printf ']\n'
} > "$H/fixture/open.json"
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
touch "$H/state/merge-conductor/pr-state.tsv"; export BOX_NAME=box-hub HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box, and only when it exists
sweep() { scratch_rm "$H/state/pr-owners"; scratch_rm "$H/logs/pr-owner-sweep.log"; envrun GH_TOKEN=t GH_BUDGET_TTL_S=0 PR_OWNER_DRY_RUN=1 bash "$H/bin/pr-owner-sweep.sh" --repo Org/x >/dev/null 2>&1; }
reset; knob on; row x local null 0
sweep
# BH-2317 (#2395) moved the hand-back's stamp clear to a DB row, so the dry-run
# line reads 'clear row blocked <project> <ticket>' instead of 'ssh root@<ip> rm'.
HB=$(grep -c 'DRY-RUN would: clear row blocked x XT-' "$H/logs/pr-owner-sweep.log" 2>/dev/null || true)
[ "$HB" = 3 ] && ok || bad "B1b: the fixture must reach three hand-backs (saw $HB): $(cat "$H/logs/pr-owner-sweep.log" 2>/dev/null)"
[ "$(lists)" = 1 ] && [ "$(perproj x)" = 0 ] && ok || bad "B1b: pr-owner-sweep must send exactly 1 GET /api/routing and 0 per-project (lists=$(lists) x=$(perproj x))"
[ "$(knobreads)" = 1 ] && ok || bad "B1b: the knob is read once per process (saw $(knobreads))"
mutate bin/pr-owner-sweep.sh '/^command -v routing_sync_all/d'
reset; knob on; row x local null 0; sweep
[ "$(( $(lists) + $(perproj x) ))" -gt 1 ] && ok || bad "B1b mutant: no top-level sync must cost >1 routing request (lists=$(lists) x=$(perproj x))"
restore bin/pr-owner-sweep.sh

# --- B2. the real bin/fly-pool.sh -------------------------------------------------
PP=tproj
mkdir -p "$H/state/fly-pool/$PP" "$H/state/build-queue/$PP"
printf '{"app":"builder-%s"}\n' "$PP" > "$H/state/fly/$PP.json"
# One queued job and a halted row, so the tick reaches its routing_halted gate
# (:2926, the parent-shell reader) and stops there without spawning.
pool_files() { : > "$H/flags/builder-fly-$PP"; printf '1\n' > "$H/flags/fly-pool-$PP"; echo "harness-pool-$PP" > "$H/flags/fly-pool-app-$PP"; : > "$H/flags/pool-halt-$PP"
  printf '{"key":"TP-1","ticket_id":"1"}\n' > "$H/state/build-queue/$PP/TP-1.json"; }
pool() { envrun POOL_SPAWN=1 FLY_API_TOKEN_TPROJ=tok bash "$H/bin/fly-pool.sh" "$PP" >/dev/null 2>&1; }
reset; knob on; row "$PP" pool "harness-pool-$PP" 1; pool_files; pool
[ "$(knobreads)" = 1 ] && [ "$(lists)" = 1 ] && [ "$(perproj $PP)" = 0 ] && ok \
  || bad "B2: fly-pool.sh must send 1 knob GET, 1 list GET, 0 per-project (knob=$(knobreads) lists=$(lists) $PP=$(perproj $PP)): $(grep -E 'routing' "$T/req.log" | tr '\n' ';')"
grep -q "spawns halted for $PP" "$H/logs/fly-pool.log" && ok || bad "B2: the tick must reach the halted gate: $(tail -3 "$H/logs/fly-pool.log")"
! grep -q 'machine run' "$T/sink" && ok || bad "B2: a halted pool must spawn nothing: $(cat "$T/sink")"
mutate bin/fly-pool.sh '/^command -v routing_sync_all/d'
reset; knob on; row "$PP" pool "harness-pool-$PP" 1; pool_files; pool
[ "$(perproj $PP)" -gt 0 ] && ok || bad "B2 mutant (no sync): the subshell reader must send its own request (lists=$(lists) $PP=$(perproj $PP))"
mutate bin/fly-pool.sh 's|^command -v _jobs_req >/dev/null 2>&1 [|][|] { \(.*\); }$|\1|'
cmp -s "$DIR/bin/fly-pool.sh" "$H/bin/fly-pool.sh" && bad "B2 mutant (unguarded re-source) did not change the script"
reset; knob on; row "$PP" pool "harness-pool-$PP" 1; pool_files; pool
[ "$(knobreads)" -gt 1 ] && ok || bad "B2 mutant (unguarded re-source): the reset memo must cost a second knob GET (knob=$(knobreads))"
restore bin/fly-pool.sh

# --- B3. the real bin/fly-machine-state.sh ---------------------------------------
mstate() { envrun bash "$H/bin/fly-machine-state.sh" x m1 2>/dev/null; }
reset; knob on; row x pool harness-pool-x 0
OUT=$(mstate); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = started ] && ok || bad "B3: fly-machine-state x m1 must print started (rc=$RC out=$OUT)"
grep -q -- '-a harness-pool-x' "$T/sink" && ok || bad "B3: flyctl must be asked about harness-pool-x: $(cat "$T/sink")"
[ "$(lists)" = 1 ] && [ "$(perproj x)" = 0 ] && ok || bad "B3: 1 list GET, 0 per-project (lists=$(lists) x=$(perproj x))"
mutate bin/fly-machine-state.sh '/^command -v routing_sync_all/d'
reset; knob on; row x pool harness-pool-x 0; mstate >/dev/null
[ "$(perproj x)" = 1 ] && [ "$(lists)" = 0 ] && ok || bad "B3 mutant (no sync): the reader must fall back to its per-project GET (lists=$(lists) x=$(perproj x))"
restore bin/fly-machine-state.sh

# --- B4. the preflight writes nothing under $HARNESS -----------------------------
PF="$H/bin/routing-flip-preflight.sh"
for m in down http500; do
  reset; knob off; rm -f "$H/logs/jobs-client.log"; BEFORE=$(snap "$H")
  OUT=$(CURL_MODE=$m envrun bash "$PF" 2>"$T/pf.err"); RC=$?
  [ "$BEFORE" = "$(snap "$H")" ] && ok || bad "B4 $m: \$HARNESS must be byte-identical: $(diff <(printf '%s\n' "$BEFORE") <(snap "$H") | head -5)"
  [ ! -e "$H/logs/jobs-client.log" ] && ok || bad "B4 $m: logs/jobs-client.log must not be created: $(cat "$H/logs/jobs-client.log")"
  [ "$RC" = 1 ] && grep -q '^\[FAIL\] 4 .*http=' <<<"$OUT" && ok || bad "B4 $m: rc 1 and the [FAIL] 4 http= line (rc=$RC): $OUT"
  grep -q 'jobs-client:' "$T/pf.err" && ok || bad "B4 $m: the jobs-client diagnostic must reach stderr: $(cat "$T/pf.err")"
done
sed '/^_jobs_log() { printf .routing-flip-preflight: jobs-client:/d' "$DIR/bin/routing-flip-preflight.sh" > "$T/pf-mutant.sh"
reset; knob off; rm -f "$H/logs/jobs-client.log"
CURL_MODE=down envrun bash "$T/pf-mutant.sh" >/dev/null 2>&1
[ -e "$H/logs/jobs-client.log" ] && ok || bad "B4 mutant (no override): the stock _jobs_log must create logs/jobs-client.log"
rm -f "$H/logs/jobs-client.log"

# --- B5. knob on, row absent: the files survive a sync ---------------------------
yfiles() { : > "$H/flags/builder-fly-y"; : > "$H/flags/fly-pool-y"; echo harness-pool-y > "$H/flags/fly-pool-app-y"; : > "$H/flags/pool-halt-y"; }
b5a() { point 'routing_sync y; echo "rc=$?"; routing_builder y'; }
reset; knob on; yfiles; BEFORE=$(snap "$H/flags")
OUT=$(b5a | tr '\n' ' ')
[ "$OUT" = "rc=2 pool " ] && ok || bad "B5a: 404 must return rc 2 and routing_builder must answer pool (got '$OUT')"
[ "$BEFORE" = "$(snap "$H/flags")" ] && ok || bad "B5a: a 404 must leave flags/ byte-identical"
[ "$(perproj y)" = 1 ] && ok || bad "B5a: the 404 is asked once (saw $(perproj y))"
reset; knob on; yfiles; row x pool harness-pool-x 0; BEFORE=$(snap "$H/flags" | grep -- '-y ')
OUT=$(point 'routing_sync_all; routing_pool_app y')
[ "$OUT" = harness-pool-y ] && ok || bad "B5b: routing_pool_app y must answer from the file (got '$OUT')"
[ "$BEFORE" = "$(snap "$H/flags" | grep -- '-y ')" ] && ok || bad "B5b: a sync_all that does not list y must leave every y file byte-identical"
[ -f "$H/flags/builder-fly-x" ] && ok || bad "B5b: the listed x row must still be applied"
mutate bin/lib/jobs/routing.sh '/^_routing_sync_one() {/,/^}/ s|^  \[ "\$rc" -eq 0 \] [|][|] return "\$rc"$|  [ "$rc" -eq 2 ] \&\& { _routing_apply "$p" local "" 0; return 0; }; [ "$rc" -eq 0 ] \|\| return "$rc"|'
cmp -s "$DIR/bin/lib/jobs/routing.sh" "$H/bin/lib/jobs/routing.sh" && bad "B5 mutant did not change routing.sh"
reset; knob on; yfiles; BEFORE=$(snap "$H/flags")
OUT=$(b5a | tr '\n' ' ')
{ [ "$OUT" = "rc=2 pool " ] && [ "$BEFORE" = "$(snap "$H/flags")" ]; } && bad "B5 mutant (404 applied as local) must fail B5a (got '$OUT')" || ok
restore bin/lib/jobs/routing.sh

echo "routing-sync-once.bh-1991: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
