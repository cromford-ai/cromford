#!/bin/bash
# tests/routing-sweep-readers.bh-1027-test.sh — BH-1372 (BH-1027.3): the sweep,
# planner and propagate readers consult the BH-1369 routing contract when the
# client is loaded and fall back to the bare flags/ files when it is not.
# Driven through the REAL scripts (fleet-propagate --check, fleet-status-push,
# fleet-fly-block, health-uncommented) against a stubbed curl; the point
# readers' helpers are extracted from the real files and evaluated with the
# real client sourced.
# Run from anywhere: tests/routing-sweep-readers.bh-1027-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v git >/dev/null || { echo "jq/git missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/logs" "$H/state" "$H/bin/lib/jobs" "$H/bin/remediations" "$H/env" "$H/flags" "$H/builds" "$T/fakebin" "$T/rows"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-propagate.sh" \
   "$DIR/bin/fleet-status-push.sh" "$DIR/bin/fleet-fly-block.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
cp "$DIR/bin/remediations/health-uncommented.sh" "$H/bin/remediations/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/watchdog-url.sh" "$H/bin/lib/"
[ -f "$DIR/bin/alert_family.py" ] && cp "$DIR/bin/alert_family.py" "$H/bin/"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/queued-fly-relayed.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin"/*.sh "$H/bin/remediations"/*.sh
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
x       Org/x       https://x.example  /api/board 2 box-x 10.0.0.1
project-3    Org/project-3    -                  -          4 box-project-3-1 10.0.0.2
project-3 Org/project-3 -                  -          4 box-project-3-1 10.0.0.2
EOF

cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; METHOD=GET; ALL="$*"
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2;; *) shift;; esac; done
case "$ALL" in *harness-watchdog*) cat > "$PUSH_OUT"; exit 0 ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s\n' "$METHOD" "$URL" >> "$REQ_SINK"
case "$METHOD $URL" in
  "GET "*/api/settings/*)
    if [ -s "${SETTING_JSON:-/nonexistent}" ]; then cat "$SETTING_JSON"; printf '\n200\n'
    else printf '{"error":"not found"}\n404\n'; fi; exit 0 ;;
esac
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$METHOD $URL" in
  "GET "*/api/routing)
    printf '{"routing":['; first=1
    for f in "$ROWS"/*.json; do [ -f "$f" ] || continue; [ $first = 1 ] || printf ','; first=0; cat "$f"; done
    printf ']}\n200\n' ;;
  "GET "*/api/routing/*)
    p="${URL##*/api/routing/}"
    if [ -f "$ROWS/$p.json" ]; then printf '{"routing":%s}\n200\n' "$(cat "$ROWS/$p.json")"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
CURL
for s in ssh rsync gh; do printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/%s.log"\nexit 0\n' "$T" "$s" > "$T/fakebin/$s"; done
chmod +x "$T/fakebin"/*

knob() { printf '{"key":"routing_rows","setting":{"key":"routing_rows","value":"%s"}}' "$1" > "$T/setting.json"; }
row() { # row <project> <builder> <pool_app|null> <halted>
  local app='null'; [ "$3" = null ] || app="\"$3\""
  printf '{"project":"%s","builder":"%s","pool_app":%s,"halted":%s}' "$1" "$2" "$app" "$4" > "$T/rows/$1.json"
}
reset() { rm -f "$H"/flags/* "$T"/rows/* "$T/req.log" "$T/ssh.log" "$T/rsync.log"
  local d; for d in "$H/builds"/*; do [ -e "$d" ] && scratch_rm "$d"; done; return 0; }
# WATCHDOG_URL: no default host since BH-3322; the fake curl captures on *harness-watchdog*.
export ENVS="HARNESS=$H JOBS_URL=https://jobs.invalid WATCHDOG_URL=https://harness-watchdog.invalid HARNESS_SECRET=test-secret SETTING_JSON=$T/setting.json ROWS=$T/rows REQ_SINK=$T/req.log PUSH_OUT=$T/push.json FLEET_CONF=$H/fleet.conf"
envrun() { env $ENVS CURL_MODE="${CURL_MODE:-ok}" PATH="$T/fakebin:$PATH" "$@"; }

# A scratch origin with one fleet-path commit beyond the checkout, so --check
# reaches the pools listing.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
# A plain (non-bare) origin: the checkout clones it, then one more fleet-path
# commit lands on origin so --check reaches the pools listing.
git init -q -b main "$T/origin" 2>/dev/null || { git init -q "$T/origin"; git -C "$T/origin" checkout -q -b main; }
mkdir -p "$T/origin/bin"; echo v1 > "$T/origin/bin/run-build.sh"
git -C "$T/origin" add -A && git -C "$T/origin" commit -qm init
git clone -q "$T/origin" "$T/checkout"
echo v2 > "$T/origin/bin/run-build.sh"; git -C "$T/origin" commit -qam v2

propagate() { # propagate [script] -> stdout of --check
  envrun HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/fakebin:/usr/bin:/bin:/usr/local/bin" bash "${1:-$H/bin/fleet-propagate.sh}" --check 2>/dev/null
}
pools_of() { sed -n '/^  pools:/,/^  crontab:/p' | grep -o '^    [A-Za-z0-9_-]*:' | tr -d ' :' | sort | tr '\n' ' '; }
status() { rm -f "$T/push.json"; envrun bash "$H/bin/fleet-status-push.sh" >/dev/null 2>"$T/status.err"; cat "$T/push.json" 2>/dev/null; }
flyblock() { envrun bash "$H/bin/fleet-fly-block.sh" 2>/dev/null; }
health() { envrun bash "$H/bin/remediations/health-uncommented.sh" "uncommented:hub:x" 2>>"$T/health.err"; }
# Point readers: the helper as it stands in the real file, with the client sourced.
extract() { grep -m1 "^$2() {" "$DIR/$1"; }
BRP=$(extract bin/blocked-resolver.sh br_pool_routed); POS=$(extract bin/pr-owner-sweep.sh pos_pool_routed)
[ -n "$BRP" ] && [ -n "$POS" ] || bad "br_pool_routed / pos_pool_routed missing from the real scripts"
point() { # point <expr...> with the client loaded (unless NOCLIENT=1)
  local src='. "$H/bin/jobs-client.sh"'; [ "${NOCLIENT:-0}" = 1 ] && src=':'
  envrun H="$H" MC_H="$H" bash -c "$src; $BRP; $POS; mc_log(){ :; }; . '$DIR/bin/lib/preplan-lib.sh' >/dev/null 2>&1; . <(sed -n '/^mc_pool_rebase_enabled() {/,/^}/p' '$DIR/bin/lib/mc/rebase.sh'); $*" 2>/dev/null
}
dead_build() { # dead_build <project>
  mkdir -p "$H/builds/$1-K-1"; printf 'BUILD_REFUSED\n' > "$H/builds/$1-K-1/RESULT"
  touch -d "@$((NOW-7200))" "$H/builds/$1-K-1/RESULT"
}

# --- 1. production entry: a row alone routes x as a pool -----------------------
reset; knob on; row x pool harness-pool-x 0
OUT=$(propagate)
[ "$(printf '%s\n' "$OUT" | pools_of)" = "x " ] && ok || bad "1: propagate --check must list pool x from the row alone (got: $(printf '%s\n' "$OUT" | pools_of) / $OUT)"
rm -f "$H"/flags/*
point 'br_pool_routed x' && ok || bad "1: br_pool_routed x from the row"
rm -f "$H"/flags/*
point 'pos_pool_routed x' && ok || bad "1: pos_pool_routed x from the row"
rm -f "$H"/flags/*
point 'REBASE_ON_POOL=1 mc_pool_rebase_enabled x' && ok || bad "1: mc_pool_rebase_enabled from the row"
rm -f "$H"/flags/*
GATE=$(grep -m1 'routing_builder "$PROJECT"' "$DIR/bin/lib/rb/gates.sh" | sed 's/; then$//; s/^if //')
[ -n "$GATE" ] && point "unset BUILDER_EXEC; PROJECT=x; HARNESS=\"\$H\"; $GATE" && ok || bad "1: rb/gates enqueue gate from the row (gate: $GATE)"

# --- 2. row flip lands in status/fly/health with no rsync or ssh ---------------
reset; knob on; row x pool harness-pool-x 1; dead_build x
S=$(status)
[ "$(jq -r '.projects.x.pool' <<<"$S" 2>/dev/null)" = true ] && ok || bad "2: status .projects.x.pool must be true (got: $(jq -c '.projects.x' <<<"$S" 2>/dev/null))"
rm -f "$H"/flags/*
[ "$(flyblock | jq -r '.x.pool_app')" = harness-pool-x ] && ok || bad "2: fly-block pool_app from the row"
rm -f "$H"/flags/*
HV=$(health 1); grep -q 'BUILD_REFUSED(halted)' <<<"$HV" && ok || bad "2/7: health-uncommented must see a halted row: $HV"
[ ! -s "$T/rsync.log" ] && [ ! -s "$T/ssh.log" ] && ok || bad "2: no rsync/ssh may carry the flip"

# --- 3/4. dark default and no client: file answers, byte-identical, zero routing GETs
dark_run() {
  reset; knob off; row x pool harness-pool-x 1
  : > "$H/flags/builder-fly-x"; : > "$H/flags/fly-pool-x"; echo pool-file-x > "$H/flags/fly-pool-app-x"; : > "$H/flags/pool-halt-x"
  : > "$H/flags/builder-fly-project-3"; dead_build x
  { propagate | pools_of; echo
    status | jq -c '[.projects.x.pool, .projects.project-3.pool, .projects["project-3"].pool]'
    flyblock | jq -c 'map_values(.pool_app)'
    health 1
    for e in 'br_pool_routed x' 'br_pool_routed project-3' 'pos_pool_routed x' \
             'REBASE_ON_POOL=1 mc_pool_rebase_enabled x' 'REBASE_ON_POOL=1 mc_pool_rebase_enabled project-3'; do
      point "$e"; echo "$e=$?"; done
    ( cd "$H/flags" && ls ); } > "$1"
}
dark_run "$T/dark.txt"
grep -q '/api/routing' "$T/req.log" 2>/dev/null && bad "3: knob off must send no /api/routing request: $(cat "$T/req.log")" || ok
grep -q 'x ' "$T/dark.txt" && grep -q '\[true,false,false\]' "$T/dark.txt" && grep -q '"x":"pool-file-x"' "$T/dark.txt" \
  && grep -q 'BUILD_REFUSED(halted)' "$T/dark.txt" && grep -q 'br_pool_routed x=0' "$T/dark.txt" \
  && grep -q 'br_pool_routed project-3=1' "$T/dark.txt" \
  && ok || bad "3: dark answers must come from the files: $(cat "$T/dark.txt")"
mv "$H/bin/jobs-client.sh" "$T/jc.sh"; mv "$H/bin/lib/jobs" "$T/jobs-mods"
NOCLIENT=1 dark_run "$T/noclient.txt"
mv "$T/jc.sh" "$H/bin/jobs-client.sh"; mv "$T/jobs-mods" "$H/bin/lib/jobs"
cmp -s "$T/dark.txt" "$T/noclient.txt" && ok || bad "4: no-client output must equal dark output: $(diff "$T/dark.txt" "$T/noclient.txt")"

# --- 5. outage with the knob on: files answer, nothing re-routed --------------
reset; knob on; row x pool harness-pool-x 0
OUT=$(CURL_MODE=down propagate)
[ -z "$(printf '%s\n' "$OUT" | pools_of)" ] && ok || bad "5: outage must list no pool (got: $OUT)"
[ "$(CURL_MODE=down status | jq -r '.projects.x.pool')" = false ] && ok || bad "5: outage status pool must be false"
CURL_MODE=down point 'br_pool_routed x' && bad "5: outage must not pool-route x" || ok
[ -z "$(ls "$H/flags" | grep -E '^(builder-fly|fly-pool|pool-halt)')" ] && ok || bad "5: outage wrote routing files: $(ls "$H/flags")"

# --- 6. prefix: an project-3 row never routes project-3 ------------------------------
reset; knob on; row project-3 pool harness-pool-project-3 0
point 'br_pool_routed project-3' && bad "6: project-3 must not be pool" || ok
[ "$(flyblock | jq -r '."project-3".pool_app')" = "" ] && ok || bad "6: project-3 pool_app must be empty"
[ ! -e "$H/flags/fly-pool-app-project-3" ] && ok || bad "6: flags/fly-pool-app-project-3 must not exist"

# --- 7. pool-halt: row and file give the same terminal verdict ----------------
reset; knob on; row x fly1 null 1; dead_build x; A=$(health 1)
reset; knob off; : > "$H/flags/pool-halt-x"; dead_build x; B=$(health 1)
[ "$A" = "$B" ] && grep -q 'BUILD_REFUSED(halted)' <<<"$A" && ok || bad "7: halted row vs file differ: [$A] vs [$B]"

# --- 8. mutation: propagate without its routing_sync_all misses the row pool --
reset; knob on; row x pool harness-pool-x 0
sed '/routing_sync_all/d' "$H/bin/fleet-propagate.sh" > "$H/bin/mut-propagate.sh"
grep -q routing_sync_all "$H/bin/fleet-propagate.sh" || bad "8: the real propagate has no routing_sync_all"
[ -z "$(propagate "$H/bin/mut-propagate.sh" | pools_of)" ] && ok || bad "8: the mutant must NOT see pool x (the sync is what finds it)"
rm -f "$H/bin/mut-propagate.sh"

echo "routing-sweep-readers: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
