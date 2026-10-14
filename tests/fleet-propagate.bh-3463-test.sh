#!/bin/bash
# tests/fleet-propagate.bh-3463-test.sh — BH-3463: bin/fleet-propagate.sh
#   §C   a diff whose fleet paths are all catalog/ rebakes no pool (the runtime
#        reads catalog/ from the spawn tarball, not from the image), and
#        docs/ never reached the fleet at all;
#   §W   a warm build that timed out INSIDE a pushed image is ok, recorded
#        warm=cold, captured to logs/fly-image-build/<pool>-<sha7>.log, and
#        raised as exactly one warn-digest alert naming that file;
#   §W2  an outer bake timeout (rc 124) is a fail with the same capture;
#   §W3  lines that only look like a timeout never count as one;
#   §R   a failed bake is retried on the next tick, capped per pool per UTC day.
#
# Same fixture as tests/fleet-propagate.bh-821-test.sh: git is REAL against a
# scratch origin, everything else (ssh, pgrep, crontab, harness-sync,
# fly-image-build, lane-alert) is a stub through PATH or the scratch HARNESS.
#
# Run from anywhere: tests/fleet-propagate.bh-3463-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 51 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
TODAY=$(date -u +%F)
export HARNESS_LANE=test

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os - - 2 box-alpha 10.0.0.1
EOF
: > "$H/flags/fly-pool-app-alpha-os"

cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/bin/pgrep"
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
printf '#!/bin/bash\necho "synced (stub)"; exit 0\n' > "$H/bin/harness-sync.sh"
# The bake stub: BAKE_OUT is printed as the build's output, BAKE_SLEEP holds it
# past POOL_BAKE_TIMEOUT_S, BAKE_FAIL=<pool> fails that pool with rc 1.
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
[ -n "${BAKE_OUT:-}" ] && cat "$BAKE_OUT"
[ -n "${BAKE_SLEEP:-}" ] && sleep "$BAKE_SLEEP"
[ "$1" = "${BAKE_FAIL:-}" ] && { echo "Error: build failed (stub)"; exit 1; }
exit "${BAKE_RC:-0}"
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTS"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$T/bin"/* "$H/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin" "$T/src/catalog" "$T/src/docs"
echo "echo v1" > "$T/src/bin/run-build.sh"
echo '{}' > "$T/src/catalog/model-prices.json"
echo '{}' > "$T/src/catalog/x.json"
echo "# doc" > "$T/src/docs/x.md"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

FLY="$H/state/fly"
N=0
commit() { # commit <path>... — change each path, one commit, push
  local f; N=$((N+1))
  for f in "$@"; do echo "v$N" > "$T/src/$f"; done
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "c$N" && git -C "$T/src" push -q origin main
}
run() {
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    BAKE_FAIL="${BAKE_FAIL:-}" BAKE_OUT="${BAKE_OUT:-}" BAKE_SLEEP="${BAKE_SLEEP:-}" BAKE_RC="${BAKE_RC:-}" \
    POOL_IMAGE_MIN_AGE_MIN="${KNOB:-}" POOL_BAKE_TIMEOUT_S="${POOL_BAKE_TIMEOUT_S:-}" \
    POOL_BAKE_RETRY_MAX="${RETRY:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
nssh()   { grep -c . "$T/ssh.calls"  2>/dev/null | head -1; }
nbake()  { grep -c . "$T/bake.calls" 2>/dev/null | head -1; }
nalert() { grep -c . "$T/alerts"     2>/dev/null | head -1; }
nlog()   { grep -c . "$H/logs/fleet-propagate.log" 2>/dev/null | head -1; }
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
stamp()  { mkdir -p "$FLY"; echo "$1" > "$FLY/alpha-os.baked-at"; }
marker() { cat "$FLY/alpha-os.image-dirty" 2>/dev/null; }
retries() { cat "$FLY/alpha-os.bake-retries" 2>/dev/null; }
snapshot() { find "$H/state" "$H/logs" -type f -exec md5sum {} \; 2>/dev/null | sort; }
settle() { stamp $((NOW - 3600)); rm -f "$FLY"/*.image-dirty "$FLY"/*.bake-retries; }

# First run records where the fleet is (no state yet => nothing propagates).
run

# ══ §C a catalog-only diff rebakes no pool, and still syncs the boxes ════════
settle
commit catalog/model-prices.json
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§C rc=$RC: $(cat "$T/err")"
[ "$(nbake)" = 0 ] && ok || bad "§C a catalog-only diff must bake no pool (got: $(cat "$T/bake.calls"))"
[ "$(jsonq '.pools')" = '{}' ] && ok || bad "§C .pools must be empty (got $(jq -c .pools "$H/state/fleet-propagate.json"))"
ls "$FLY"/*.image-dirty >/dev/null 2>&1 && bad "§C no pool may be marked dirty: $(ls "$FLY")" || ok
[ "$(nssh)" = 1 ] && ok || bad "§C the boxes must still be synced (got $(nssh))"
[ "$(jq -c '.changed_paths' "$H/state/fleet-propagate.json")" = '["catalog/model-prices.json"]' ] && ok \
  || bad "§C changed_paths must name the catalog file (got $(jq -c '.changed_paths' "$H/state/fleet-propagate.json"))"
[ "$(nalert)" = 1 ] && ok || bad "§C exactly one alert (got $(nalert): $(cat "$T/alerts"))"
grep -q '^--log-only fleet-propagate propagated' "$T/alerts" && ok || bad "§C a clean catalog-only run is --log-only: $(cat "$T/alerts")"
grep -q '0/0 pool images rebaked (no image input changed)' "$T/alerts" && ok || bad "§C the alert must say why 0/0: $(cat "$T/alerts")"
grep -q 'pools: no image input changed (catalog/model-prices.json) — no pool rebaked' "$H/logs/fleet-propagate.log" && ok \
  || bad "§C the log must say no pool was rebaked and why: $(tail -3 "$H/logs/fleet-propagate.log")"
[ "$(jsonq .last_sha)" = "$(git -C "$T/src" rev-parse HEAD)" ] && ok || bad "§C last_sha must advance"

# ══ §C2 catalog plus bin still bakes ═════════════════════════════════════════
settle
commit catalog/x.json bin/run-build.sh
run
[ "$(nbake)" = 1 ] && ok || bad "§C2 a diff that also touches bin/ must bake (got: $(cat "$T/bake.calls"))"
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "§C2 the bake must be ok (got $(jsonq '.pools["alpha-os"].status'))"

# ══ §C3 docs-only is not a fleet path at all ═════════════════════════════════
settle
commit docs/x.md
run
[ "$(nbake)" = 0 ] && ok || bad "§C3 a docs-only diff must bake nothing (got: $(cat "$T/bake.calls"))"
[ "$(jsonq .skipped)" = true ] && ok || bad "§C3 a docs-only diff must be recorded skipped (got $(jsonq .skipped))"

# ══ §C4 --check on a catalog-only diff says so and writes nothing ════════════
settle
commit catalog/model-prices.json
BEFORE_SNAP=$(snapshot)
run --check; RC=$?
[ "$RC" = 0 ] && ok || bad "§C4 rc=$RC"
grep -q 'pools:   none (no image input changed)' "$T/out" && ok || bad "§C4 --check must say no image input changed: $(cat "$T/out")"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "§C4 --check wrote state or logs"
[ "$(nbake)" = 0 ] && [ "$(nssh)" = 0 ] && ok || bad "§C4 --check must not bake or ssh"
run   # settle the catalog commit

# ══ §W a warm build that timed out inside a pushed image ═════════════════════
settle
{ for i in $(seq 1 50); do echo "filler $i"; done
  echo "#14 3.1 warm-build: step build start timeout=600s"
  echo "#14 612.3 warm-build: TIMED OUT after 600s — baking checkout+node_modules only (warm=cold)"
  echo "#14 612.4 warm-build: step build elapsed=600s rc=124"
  echo "#14 DONE 612.9s"
  for i in $(seq 51 300); do echo "filler $i"; done
  echo "image: registry.fly.io/builder-alpha-os:deployment-W"
} > "$T/w.out"
commit bin/run-build.sh
NEW=$(git -C "$T/src" rev-parse HEAD)
CAP="$H/logs/fly-image-build/alpha-os-${NEW:0:7}.log"
BAKE_OUT="$T/w.out" run
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "§W a pushed image is ok even with a cold warm layer (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["alpha-os"].warm')" = cold ] && ok || bad "§W warm must be cold (got $(jsonq '.pools["alpha-os"].warm'))"
[ "$(jsonq '.pools["alpha-os"].capture')" = "$CAP" ] && ok || bad "§W capture must be recorded (got $(jsonq '.pools["alpha-os"].capture'))"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok || bad "§W an ok bake must re-stamp baked-at"
[ -f "$CAP" ] && ok || bad "§W the capture $CAP must exist: $(ls "$H/logs/fly-image-build" 2>&1)"
grep -q 'warm-build: TIMED OUT' "$CAP" && ok || bad "§W the capture must carry the timeout line"
grep -q 'warm-build: step build elapsed=600s' "$CAP" && ok || bad "§W the capture must carry the step elapsed line"
grep -q '^#14 DONE 612.9s' "$CAP" && ok || bad "§W the capture must carry BuildKit step timings"
grep -q '^filler 300$' "$CAP" && ok || bad "§W the capture must carry the tail"
grep -q '^filler 50$' "$CAP" && bad "§W the capture must keep only the last 200 lines" || ok
[ "$(grep -c '^filler' "$CAP")" -le 200 ] && ok || bad "§W at most 200 tail lines (got $(grep -c '^filler' "$CAP"))"
grep -q 'bake elapsed=[0-9]*s' "$CAP" && ok || bad "§W the header must carry the bake's elapsed time"
[ "$(nalert)" = 1 ] && ok || bad "§W exactly one alert (got $(nalert): $(cat "$T/alerts"))"
grep -q '^--severity warn fleet-propagate' "$T/alerts" && ok || bad "§W a warm timeout is a warn-digest line: $(cat "$T/alerts")"
grep -qF "logs/fly-image-build/alpha-os-${NEW:0:7}.log" "$T/alerts" && ok || bad "§W the alert must name the capture: $(cat "$T/alerts")"
grep -q -- '--critical' "$T/alerts" && bad "§W a shipped image is not critical" || ok
grep -q "pool alpha-os: warm build timed out — image shipped cold, see $CAP" "$H/logs/fleet-propagate.log" && ok \
  || bad "§W the run log must name the cold pool: $(tail -3 "$H/logs/fleet-propagate.log")"
[ -z "$(ls "$H"/logs/fly-image-build/*.tmp 2>/dev/null)" ] && ok || bad "§W no .tmp may be left behind"

# ══ §W2 the OUTER timeout: fail, reason timeout, captured, critical ══════════
settle
printf 'step 1\n#9 [warm 4/5] RUN git clone\n' > "$T/w2.out"
commit bin/run-build.sh
NEW=$(git -C "$T/src" rev-parse HEAD)
CAP="$H/logs/fly-image-build/alpha-os-${NEW:0:7}.log"
RETRY=0 BAKE_OUT="$T/w2.out" BAKE_SLEEP=30 POOL_BAKE_TIMEOUT_S=2 run
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok || bad "§W2 status must be fail (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["alpha-os"].reason')" = timeout ] && ok || bad "§W2 reason must be timeout (got $(jsonq '.pools["alpha-os"].reason'))"
[ "$(jsonq '.pools["alpha-os"].warm')" = "" ] && ok || bad "§W2 no warm sentinel => warm stays empty (got $(jsonq '.pools["alpha-os"].warm'))"
[ -f "$CAP" ] && ok || bad "§W2 an outer timeout must write the capture"
grep -q 'rc=124' "$CAP" && ok || bad "§W2 the capture header must carry rc=124"
grep -q '^#9 \[warm 4/5\]' "$CAP" && ok || bad "§W2 the capture must carry the step lines"
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "§W2 must be critical: $(cat "$T/alerts")"
grep -qF "see $CAP" "$T/alerts" && ok || bad "§W2 the critical alert must name the capture: $(cat "$T/alerts")"

# ══ §W3 things that only look like a timeout ═════════════════════════════════
for NEG in 'next build exceeded the configured timeout 60000 ms for a page' \
           'test TIMED OUT upstream' 'Terminated'; do
  settle
  printf '%s\n' "$NEG" > "$T/w3.out"
  commit bin/run-build.sh
  NEW=$(git -C "$T/src" rev-parse HEAD)
  BAKE_OUT="$T/w3.out" run
  [ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "§W3 '$NEG' status (got $(jsonq '.pools["alpha-os"].status'))"
  [ "$(jsonq '.pools["alpha-os"].warm')" != cold ] && ok || bad "§W3 '$NEG' must not mark warm=cold"
  [ ! -f "$H/logs/fly-image-build/alpha-os-${NEW:0:7}.log" ] && ok || bad "§W3 '$NEG' must write no capture"
  grep -q '^--log-only' "$T/alerts" && ok || bad "§W3 '$NEG' must stay --log-only: $(cat "$T/alerts")"
done
# A plain warm FAILED is warm=cold (true) but keeps today's quiet --log-only.
settle
echo "warm build FAILED — baking checkout+node_modules only (rc=1)" > "$T/w3.out"
commit bin/run-build.sh
NEW=$(git -C "$T/src" rev-parse HEAD)
BAKE_OUT="$T/w3.out" run
[ "$(jsonq '.pools["alpha-os"].warm')" = cold ] && ok || bad "§W3 a warm FAILED is warm=cold (got $(jsonq '.pools["alpha-os"].warm'))"
[ ! -f "$H/logs/fly-image-build/alpha-os-${NEW:0:7}.log" ] && ok || bad "§W3 a warm FAILED writes no capture"
grep -q '^--log-only' "$T/alerts" && ok || bad "§W3 a warm FAILED stays --log-only: $(cat "$T/alerts")"
# An ok warm build reads warm.
echo "#14 99.0 warm build OK" > "$T/w3.out"
settle; commit bin/run-build.sh
BAKE_OUT="$T/w3.out" run
[ "$(jsonq '.pools["alpha-os"].warm')" = warm ] && ok || bad "§W3 warm build OK reads warm (got $(jsonq '.pools["alpha-os"].warm'))"

# ══ §R a failed bake is retried on the next tick, capped per day ═════════════
settle
commit bin/run-build.sh
NEW=$(git -C "$T/src" rev-parse HEAD)
BAKE_FAIL=alpha-os run
[ "$(nbake)" = 1 ] && ok || bad "§R merge: one bake (got $(nbake))"
[ "$(marker)" = "$NEW" ] && ok || bad "§R merge: the failed pool must stay dirty for a retry (got '$(marker)')"
[ "$(retries)" = "$TODAY 1" ] && ok || bad "§R merge: retry 1 must be counted (got '$(retries)')"
grep -q 'retry queued (1/2)' "$T/alerts" && ok || bad "§R merge: the alert must say a retry is queued: $(cat "$T/alerts")"
grep -q 'pool alpha-os: retry 1/2 queued for the next tick (bake failed)' "$H/logs/fleet-propagate.log" && ok || bad "§R merge: log line"
BAKE_FAIL=alpha-os run
[ "$(nbake)" = 1 ] && ok || bad "§R tick 2: the retry must bake with nothing new merged (got $(nbake))"
[ "$(jsonq .drain)" = true ] && ok || bad "§R tick 2 must be a drain"
[ "$(retries)" = "$TODAY 2" ] && ok || bad "§R tick 2: retry 2 counted (got '$(retries)')"
[ "$(marker)" = "$NEW" ] && ok || bad "§R tick 2: still dirty (got '$(marker)')"
BAKE_FAIL=alpha-os run
[ "$(nbake)" = 1 ] && ok || bad "§R tick 3: the last retry bakes (got $(nbake))"
[ -z "$(marker)" ] && ok || bad "§R tick 3: the cap must drop the marker (got '$(marker)')"
grep -q 'retry cap reached' "$T/alerts" && ok || bad "§R tick 3: the alert must say the cap is reached: $(cat "$T/alerts")"
grep -q 'pool alpha-os: retry cap 2 reached today (bake failed), next attempt on the next merge or the 05:40Z nightly' "$H/logs/fleet-propagate.log" && ok || bad "§R tick 3: log line"
LOG_BEFORE=$(nlog)
BAKE_FAIL=alpha-os run
[ "$(nbake)" = 0 ] && ok || bad "§R tick 4: capped — no bake (got $(nbake))"
[ "$(nalert)" = 0 ] && ok || bad "§R tick 4: no alert (got $(cat "$T/alerts"))"
[ "$(nlog)" = "$LOG_BEFORE" ] && ok || bad "§R tick 4: no log line"

# A stale day's count reads as zero.
settle
echo "2000-01-01 2" > "$FLY/alpha-os.bake-retries"
commit bin/run-build.sh
BAKE_FAIL=alpha-os run
[ "$(retries)" = "$TODAY 1" ] && ok || bad "§R an old day's count must reset (got '$(retries)')"

# ══ §R2 a retry that succeeds clears the state ═══════════════════════════════
settle
commit bin/run-build.sh
BAKE_FAIL=alpha-os run
[ -n "$(marker)" ] && ok || bad "§R2 fixture: the failure must queue a retry"
run
[ "$(nbake)" = 1 ] && ok || bad "§R2 the retry drain must bake (got $(nbake))"
[ -z "$(retries)" ] && ok || bad "§R2 an ok bake must remove bake-retries (got '$(retries)')"
[ -z "$(marker)" ] && ok || bad "§R2 an ok bake must clear the marker"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok || bad "§R2 an ok bake must stamp baked-at"

# ══ §R3 POOL_BAKE_RETRY_MAX=0 is the old one-attempt behaviour ═══════════════
settle
commit bin/run-build.sh
RETRY=0 BAKE_FAIL=alpha-os run
[ "$(nbake)" = 1 ] && ok || bad "§R3 one bake (got $(nbake))"
[ -z "$(marker)" ] && ok || bad "§R3 knob 0: no retry marker (got '$(marker)')"
RETRY=0 BAKE_FAIL=alpha-os run
[ "$(nbake)" = 0 ] && ok || bad "§R3 knob 0: next tick bakes nothing (got $(nbake))"

# ══ §R4 a bad knob falls back to 2, loudly ═══════════════════════════════════
settle
commit bin/run-build.sh
RETRY=abc BAKE_FAIL=alpha-os run
grep -q 'POOL_BAKE_RETRY_MAX=abc is not a number' "$H/logs/fleet-propagate.log" && ok || bad "§R4 the bad knob must be logged"
[ "$(retries)" = "$TODAY 1" ] && ok || bad "§R4 must behave as 2 (got '$(retries)')"
grep -q 'retry queued (1/2)' "$T/alerts" && ok || bad "§R4 the alert must say 1/2: $(cat "$T/alerts")"

echo "fleet-propagate.bh-3463-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
