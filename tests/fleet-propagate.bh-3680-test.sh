#!/bin/bash
# tests/fleet-propagate.bh-3680-test.sh — BH-3680: bin/fleet-propagate.sh
#   (a)  a failed pool bake whose retry is queued, with everything else ok, is
#        ONE --severity warn digest line, never a --critical page;
#   (a2) a drain whose retry fails again (not yet capped) is still a warn;
#   (b)  a pool at its retry cap pages, and the page names only that pool in
#        failed: and the OLD-harness list (a queued sibling is `retrying:`);
#   (c)  a box failure pages; a queued pool rides along as `retrying:`;
#   (d)  a drain that bakes ok after a retry says `ok on retry n/N`;
#   (e)  a cold-warm pool shipped the new harness: not in the OLD list;
#   (f)  PROPAGATE_PAGE_ON_FIRST_FAIL=1 restores first-fail paging; a bad value
#        logs and uses 0;
#   (g)  retries off, or a hub failure, still page;
#   P1-P5 POOL_BAKE_PUSH_GRACE_S: a bake already pushing gets a margin past
#        POOL_BAKE_TIMEOUT_S, a bake still building does not.
#
# Same fixture as tests/fleet-propagate.bh-3463-test.sh (real git against a
# scratch origin, stubs through PATH and the scratch HARNESS), with two boxes
# and two pools.
#
# Run from anywhere: tests/fleet-propagate.bh-3680-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 65 || exit 1
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
beta     Acme/beta     - - 4 box-beta  10.0.0.2
EOF
: > "$H/flags/fly-pool-app-alpha-os"
: > "$H/flags/fly-pool-app-beta"

cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
IP=""; for A in "$@"; do case "$A" in root@*) IP="${A#root@}" ;; esac; done
if [ -n "${SSH_FAIL_IP:-}" ] && [ "$IP" = "$SSH_FAIL_IP" ]; then echo "0000000"; exit 7; fi
echo "cafe123456789"; exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/bin/pgrep"
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
printf '#!/bin/bash\necho "synced (stub)"; exit 0\n' > "$H/bin/harness-sync.sh"
# The bake stub. BAKE_OUT and BAKE_SLEEP apply to alpha-os only, so beta is a
# plain ok bake unless BAKE_FAIL names it. BAKE_FAIL is a space list of pools
# that fail with rc 1. BAKE_PUSH=<pool> prints the push line fly deploy prints,
# holds for BAKE_SLEEP, then prints the image line and exits 0.
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
if [ "$1" = "${BAKE_PUSH:-}" ]; then
  echo "#33 pushing layer sha256:abc 9.5s done"
  sleep "${BAKE_SLEEP:-0}"
  echo "image: registry.fly.io/builder-$1:deployment-X"
  exit 0
fi
if [ "$1" = alpha-os ]; then
  [ -n "${BAKE_OUT:-}" ] && cat "$BAKE_OUT"
  [ -n "${BAKE_SLEEP:-}" ] && sleep "$BAKE_SLEEP"
fi
for F in ${BAKE_FAIL:-}; do [ "$1" = "$F" ] && { echo "Error: build failed (stub)"; exit 1; }; done
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$ALERTS"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$T/bin"/* "$H/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

FLY="$H/state/fly"
N=0
commit() { # commit — change bin/run-build.sh, one commit, push
  N=$((N+1))
  echo "v$N" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "c$N" && git -C "$T/src" push -q origin main
}
run() {
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    SSH_FAIL_IP="${SSH_FAIL_IP:-}" \
    BAKE_FAIL="${BAKE_FAIL:-}" BAKE_OUT="${BAKE_OUT:-}" BAKE_SLEEP="${BAKE_SLEEP:-}" BAKE_PUSH="${BAKE_PUSH:-}" \
    POOL_IMAGE_MIN_AGE_MIN="" POOL_BAKE_TIMEOUT_S="${POOL_BAKE_TIMEOUT_S:-}" \
    POOL_BAKE_RETRY_MAX="${RETRY:-}" \
    PROPAGATE_PAGE_ON_FIRST_FAIL="${PAGE:-}" POOL_BAKE_PUSH_GRACE_S="${GRACE:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
nalert() { grep -c . "$T/alerts" 2>/dev/null | head -1; }
nlog()   { grep -c . "$H/logs/fleet-propagate.log" 2>/dev/null | head -1; }
newlog() { tail -n +"$(( $1 + 1 ))" "$H/logs/fleet-propagate.log"; }  # newlog <lines-before>
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
retries() { cat "$FLY/alpha-os.bake-retries" 2>/dev/null; }
marker()  { cat "$FLY/alpha-os.image-dirty" 2>/dev/null; }
# The `failed:` segment of the pool part, and the OLD-harness list, of the alert.
pool_failed() { sed -n 's/.*pool images rebaked[^,]*, failed:\([^,]*\),.*/\1/p' "$T/alerts"; }
old_list()    { sed -n 's/.*Still running the OLD harness:\([^.]*\)\..*/\1/p' "$T/alerts"; }
settle() {
  mkdir -p "$FLY"
  echo $((NOW - 3600)) > "$FLY/alpha-os.baked-at"; echo $((NOW - 3600)) > "$FLY/beta.baked-at"
  rm -f "$FLY"/*.image-dirty "$FLY"/*.bake-retries
}
sha7() { git -C "$T/src" rev-parse HEAD | cut -c1-7; }

# First run records where the fleet is (no state yet => nothing propagates).
run

# ══ (a) retry queued, everything else ok → one warn, no page ═════════════════
settle; commit
BAKE_FAIL=alpha-os run
[ "$(nalert)" = 1 ] && ok || bad "(a) exactly one alert (got $(nalert): $(cat "$T/alerts"))"
grep -q '^--severity warn fleet-propagate' "$T/alerts" && ok || bad "(a) a queued retry is a warn: $(cat "$T/alerts")"
grep -q -- '--critical' "$T/alerts" && bad "(a) a queued retry must not page: $(cat "$T/alerts")" || ok
grep -qF 'retrying: alpha-os(build)' "$T/alerts" && ok || bad "(a) the pool must be listed retrying: $(cat "$T/alerts")"
grep -qF 'retry queued (1/2)' "$T/alerts" && ok || bad "(a) the retry must be named: $(cat "$T/alerts")"
grep -q 'FAILED in part' "$T/alerts" && bad "(a) the warn must not carry the page's prefix: $(cat "$T/alerts")" || ok
grep -q 'OLD harness' "$T/alerts" && bad "(a) the warn names no OLD harness: $(cat "$T/alerts")" || ok
[ "$(retries)" = "$TODAY 1" ] && ok || bad "(a) retry 1 counted (got '$(retries)')"
[ -n "$(marker)" ] && ok || bad "(a) the dirty marker stays for the retry"
grep -q 'failed=alpha-os(build)' "$H/logs/fleet-propagate.log" && ok || bad "(a) the summary line still lists the failed pool"

# ══ (a2) the drain retry fails again, not capped → still warn ════════════════
BAKE_FAIL=alpha-os run
[ "$(jsonq .drain)" = true ] && ok || bad "(a2) must be a drain"
[ "$(nalert)" = 1 ] && ok || bad "(a2) exactly one alert (got $(nalert))"
grep -q '^--severity warn fleet-propagate' "$T/alerts" && ok || bad "(a2) a queued retry on a drain is a warn: $(cat "$T/alerts")"
grep -q 'drained' "$T/alerts" && ok || bad "(a2) the drain warn says drained: $(cat "$T/alerts")"
grep -qF 'retry queued (2/2)' "$T/alerts" && ok || bad "(a2) retry 2/2 named: $(cat "$T/alerts")"
# The third failure spends the cap and pages.
BAKE_FAIL=alpha-os run
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(a2) the tick that hits the cap pages: $(cat "$T/alerts")"
grep -qF 'retry cap reached' "$T/alerts" && ok || bad "(a2) cap named: $(cat "$T/alerts")"

# ══ (b) cap reached → critical naming only that pool ═════════════════════════
settle
echo "$TODAY 2" > "$FLY/alpha-os.bake-retries"
commit
BAKE_FAIL="alpha-os beta" run
S7=$(sha7)
[ "$(nalert)" = 1 ] && ok || bad "(b) exactly one alert (got $(nalert))"
grep -q "^--critical fleet-propagate propagating $S7 to the fleet FAILED in part" "$T/alerts" && ok \
  || bad "(b) critical with the alert-verify prefix: $(cat "$T/alerts")"
PF=$(pool_failed)
case "$PF" in *alpha-os*) ok ;; *) bad "(b) failed: must name alpha-os (got '$PF')" ;; esac
case "$PF" in *beta*) bad "(b) failed: must not name the retrying beta (got '$PF')" ;; *) ok ;; esac
OL=$(old_list)
case "$OL" in *alpha-os*) ok ;; *) bad "(b) OLD list must name alpha-os (got '$OL'): $(cat "$T/alerts")" ;; esac
case "$OL" in *beta*) bad "(b) OLD list must not name beta (got '$OL')" ;; *) ok ;; esac
grep -qF 'retrying: beta(build)' "$T/alerts" && ok || bad "(b) beta is retrying: $(cat "$T/alerts")"
grep -qF 'retry cap reached' "$T/alerts" && ok || bad "(b) the cap is named: $(cat "$T/alerts")"

# ══ (c) box failure plus a queued retry → critical, pool listed as retrying ══
settle; commit
SSH_FAIL_IP=10.0.0.2 BAKE_FAIL=alpha-os run
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(c) a box failure pages: $(cat "$T/alerts")"
grep -qF '1/2 boxes synced' "$T/alerts" && ok || bad "(c) 1/2 boxes: $(cat "$T/alerts")"
grep -qF 'retrying: alpha-os(build)' "$T/alerts" && ok || bad "(c) the pool is retrying: $(cat "$T/alerts")"
OL=$(old_list)
case "$OL" in *box-beta*) ok ;; *) bad "(c) OLD list must name the failed box (got '$OL')" ;; esac
case "$OL" in *alpha-os*) bad "(c) OLD list must not name the retrying pool (got '$OL')" ;; *) ok ;; esac

# ══ (d) drain success after a retry → "ok on retry" ══════════════════════════
settle; commit
BAKE_FAIL=alpha-os run
L0=$(nlog)
run
[ "$(jsonq .drain)" = true ] && ok || bad "(d) the second tick must be a drain"
newlog "$L0" | grep -q 'pool alpha-os: ok on retry 1/2' && ok || bad "(d) log must say ok on retry 1/2: $(newlog "$L0")"
grep -q '^--log-only fleet-propagate drained' "$T/alerts" && ok || bad "(d) a clean drain stays --log-only: $(cat "$T/alerts")"
grep -qF 'alpha-os ok on retry 1/2' "$T/alerts" && ok || bad "(d) the alert must carry ok on retry: $(cat "$T/alerts")"
[ -z "$(retries)" ] && ok || bad "(d) bake-retries removed (got '$(retries)')"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok || bad "(d) baked-at stamped"
# Negatives: a plain ok bake, and a retries file from another day, say nothing.
settle; commit
L0=$(nlog); run
case "$(newlog "$L0")" in *'ok on retry'*) bad "(d) a clean bake must not claim a retry" ;; *) ok ;; esac
grep -q 'ok on retry' "$T/alerts" && bad "(d) a clean bake alert must not claim a retry" || ok
settle; echo "2000-01-01 1" > "$FLY/alpha-os.bake-retries"; commit
L0=$(nlog); run
case "$(newlog "$L0")" in *'ok on retry'*) bad "(d) an old day's retry count must not be claimed" ;; *) ok ;; esac

# ══ (e) a cold-warm pool is not in the OLD list ══════════════════════════════
settle
{ echo "#14 3.1 warm-build: step build start timeout=600s"
  echo "#14 612.3 warm-build: TIMED OUT after 600s — baking checkout+node_modules only (warm=cold)"
  echo "image: registry.fly.io/builder-alpha-os:deployment-W"
} > "$T/w.out"
commit
SSH_FAIL_IP=10.0.0.2 BAKE_OUT="$T/w.out" run
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "(e) fixture: the pool is ok"
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(e) the box failure pages: $(cat "$T/alerts")"
OL=$(old_list)
case "$OL" in *alpha-os*) bad "(e) a cold-warm pool shipped the new harness, not OLD (got '$OL')" ;; *) ok ;; esac
grep -qF 'shipped the new harness, warm layer cold (warm build timed out): alpha-os' "$T/alerts" && ok \
  || bad "(e) the cold clause is its own: $(cat "$T/alerts")"

# ══ (f) knob=1 restores first-fail paging ════════════════════════════════════
settle; commit
PAGE=1 BAKE_FAIL=alpha-os run
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(f) PAGE=1 pages on first fail: $(cat "$T/alerts")"
grep -qF 'failed: alpha-os(build)' "$T/alerts" && ok || bad "(f) failed: names the pool: $(cat "$T/alerts")"
grep -qF 'retry queued (1/2)' "$T/alerts" && ok || bad "(f) the retry is still queued: $(cat "$T/alerts")"
grep -q 'retrying:' "$T/alerts" && bad "(f) no retrying: segment when paging first-fail" || ok

# ══ (f2) a bad knob logs and uses 0 ══════════════════════════════════════════
settle; commit
PAGE=yes BAKE_FAIL=alpha-os run
grep -qF 'PROPAGATE_PAGE_ON_FIRST_FAIL=yes is not 0 or 1 — using 0' "$H/logs/fleet-propagate.log" && ok || bad "(f2) the bad knob is logged"
grep -q '^--severity warn fleet-propagate' "$T/alerts" && ok || bad "(f2) a bad knob behaves as 0 (warn): $(cat "$T/alerts")"

# ══ (g) retries off still pages ══════════════════════════════════════════════
settle; commit
RETRY=0 BAKE_FAIL=alpha-os run
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(g) RETRY=0 pages: $(cat "$T/alerts")"
grep -qF 'no retry (POOL_BAKE_RETRY_MAX=0)' "$T/alerts" && ok || bad "(g) no retry named: $(cat "$T/alerts")"

# ══ P1 push grace lets a finishing bake land ═════════════════════════════════
settle; commit
S7=$(sha7)
L0=$(nlog)
BAKE_PUSH=alpha-os BAKE_SLEEP=3 POOL_BAKE_TIMEOUT_S=1 GRACE=10 run
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "P1 status ok (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok || bad "P1 baked-at stamped"
newlog "$L0" | grep -q 'pool alpha-os: bake ran [0-9]*s, past the 1s build limit, finished in its push grace' && ok \
  || bad "P1 log must say finished in its push grace: $(newlog "$L0")"
[ ! -f "$H/logs/fly-image-build/alpha-os-$S7.log" ] && ok || bad "P1 no capture for an ok bake"
grep -q '^--log-only' "$T/alerts" && ok || bad "P1 --log-only: $(cat "$T/alerts")"

# ══ P2 a build-phase bake is still killed at the build limit ═════════════════
settle; commit
S7=$(sha7)
printf 'step 1\n#9 [warm 4/5] RUN git clone\n' > "$T/p2.out"
L0=$(nlog)
T_START=$SECONDS
RETRY=0 BAKE_OUT="$T/p2.out" BAKE_SLEEP=30 POOL_BAKE_TIMEOUT_S=1 GRACE=60 run
T_EL=$((SECONDS - T_START))
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok || bad "P2 status fail (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["alpha-os"].reason')" = timeout ] && ok || bad "P2 reason timeout (got $(jsonq '.pools["alpha-os"].reason'))"
newlog "$L0" | grep -q 'pool alpha-os: outer timeout hit in the build phase (1s build limit, +60s push grace)' && ok \
  || bad "P2 log names the build phase: $(newlog "$L0")"
grep -q 'phase=build' "$H/logs/fly-image-build/alpha-os-$S7.log" 2>/dev/null && ok || bad "P2 capture header phase=build"
[ "$T_EL" -lt 15 ] && ok || bad "P2 a building bake must die at the build limit, not the grace (took ${T_EL}s)"

# ══ P3 push hangs past the grace ═════════════════════════════════════════════
settle; commit
S7=$(sha7)
L0=$(nlog)
BAKE_PUSH=alpha-os BAKE_SLEEP=30 POOL_BAKE_TIMEOUT_S=1 GRACE=2 run
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok || bad "P3 status fail (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["alpha-os"].reason')" = timeout ] && ok || bad "P3 reason timeout (got $(jsonq '.pools["alpha-os"].reason'))"
newlog "$L0" | grep -q 'outer timeout hit in the push phase' && ok || bad "P3 log names the push phase: $(newlog "$L0")"
grep -q 'phase=push' "$H/logs/fly-image-build/alpha-os-$S7.log" 2>/dev/null && ok || bad "P3 capture header phase=push"
[ "$(retries)" = "$TODAY 1" ] && ok || bad "P3 a retry is queued (got '$(retries)')"
grep -q '^--severity warn fleet-propagate' "$T/alerts" && ok || bad "P3 a queued retry is a warn: $(cat "$T/alerts")"

# ══ P4 grace 0 is the old single timeout ═════════════════════════════════════
settle; commit
BAKE_PUSH=alpha-os BAKE_SLEEP=5 POOL_BAKE_TIMEOUT_S=1 GRACE=0 run
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok || bad "P4 grace 0: a push past the limit fails (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["alpha-os"].reason')" = timeout ] && ok || bad "P4 reason timeout (got $(jsonq '.pools["alpha-os"].reason'))"

# ══ P5 a bad grace knob logs and uses 300 ════════════════════════════════════
settle; commit
GRACE=abc run
grep -qF 'POOL_BAKE_PUSH_GRACE_S=abc is not a number of seconds — using 300' "$H/logs/fleet-propagate.log" && ok \
  || bad "P5 the bad grace knob is logged"

# ══ (g2) a hub failure with a queued pool pages (LAST: it leaves the checkout
#    diverged, exactly as tests/fleet-propagate.bh-1128-test.sh does) ═════════
settle; commit
echo local > "$T/checkout/local.txt"
git -C "$T/checkout" add -A && git -C "$T/checkout" commit -qm local
BAKE_FAIL=alpha-os run
[ "$(jsonq .hub)" = fail ] && ok || bad "(g2) fixture: hub must be fail (got $(jsonq .hub))"
grep -q '^--critical fleet-propagate' "$T/alerts" && ok || bad "(g2) a hub failure pages: $(cat "$T/alerts")"
case "$(old_list)" in *hub*) ok ;; *) bad "(g2) OLD list names the hub (got '$(old_list)')" ;; esac

echo "fleet-propagate.bh-3680-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
