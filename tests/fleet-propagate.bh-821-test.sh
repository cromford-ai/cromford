#!/bin/bash
# tests/fleet-propagate.bh-821-test.sh — BH-821: bin/fleet-propagate.sh debounces
# the pool image bake instead of kicking a remote Fly build per pool per merge.
#
# WHAT THIS PINS. Cromford merged 11 PRs in eight minutes on 2026-09-18; at
# that rate the */5 propagate lane would start ten remote builds every tick. So:
#   * a pool whose image was baked less than POOL_IMAGE_MIN_AGE_MIN minutes ago
#     is NOT rebaked — it is recorded `debounced` and marked dirty in state;
#   * a dirty pool is baked by the next tick whose window has expired, even when
#     nothing new merged (a skip must never leave a pool on a stale image);
#   * --force and POOL_IMAGE_MIN_AGE_MIN=0 bake regardless;
#   * a debounced run is NOT --critical, and says images=0/1 (1 debounced);
#   * absent, unparseable and future stamps all bake (absent is not fresh), and
#     a garbage knob logs one line and falls back to the documented 30.
#
# Everything outside the script is stubbed through PATH ($T/bin) and a scratch
# HARNESS ($H/bin): ssh, pgrep, crontab, harness-sync, fly-image-build and
# lane-alert. git is REAL against a scratch origin — the LAST..NEW range
# arithmetic decides which of the two entry paths (merge, drain) a tick takes.
#
# Run from anywhere: tests/fleet-propagate.bh-821-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s) # one wall-clock read; every fixture age is derived from it

# The fixture pushes to a scratch bare repo on main. The act-time guard fences
# pushes to main in the execute lane; a test lane is not guarded.
export HARNESS_LANE=test

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"

# ── the fixture fleet: one box, one pool (a second pool joins for §D2) ───────
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os - - 2 box-alpha 10.0.0.1
EOF
: > "$H/flags/fly-pool-app-alpha-os"

# ── stubs ────────────────────────────────────────────────────────────────────
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SSH_CALLS"
echo "cafe123456789"; exit 0
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-l" ] && { cat "$LIVE_CRON" 2>/dev/null; exit 0; }
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
echo "synced (stub)"; exit 0
EOF
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
[ "$1" = "${BAKE_FAIL:-}" ] && exit 1
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*

# ── a real scratch repo: bare origin + the hub's checkout ────────────────────
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
commit() { # commit <content> — one bin/ change, i.e. a fleet path
  echo "$1" > "$T/src/bin/run-build.sh"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main
}
run() { # run [flags...] — KNOB / BAKE_FAIL come from the caller's environment
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    BAKE_FAIL="${BAKE_FAIL:-}" POOL_IMAGE_MIN_AGE_MIN="${KNOB:-}" \
    POOL_BAKE_RETRY_MAX="${POOL_BAKE_RETRY_MAX:-}" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
nssh()   { grep -c . "$T/ssh.calls"  2>/dev/null | head -1; }
nbake()  { grep -c . "$T/bake.calls" 2>/dev/null | head -1; }
nalert() { grep -c . "$T/alerts"     2>/dev/null | head -1; }
nlog()   { grep -v ' box [^ ]*: ' "$H/logs/fleet-propagate.log" 2>/dev/null | grep -c . | head -1; }  # BH-7189: the per-box lines are not part of this suite's count
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }
stamp()  { mkdir -p "$FLY"; echo "$1" > "$FLY/alpha-os.baked-at"; }   # stamp <epoch-or-text>
marker() { cat "$FLY/alpha-os.image-dirty" 2>/dev/null; }
snapshot() { find "$H/state" "$H/logs" -type f -exec md5sum {} \; 2>/dev/null | sort; }

# ══ §F a pool with NO bake stamp is baked (absent is not fresh) ══════════════
commit "echo v2"
NEW=$(git -C "$T/src" rev-parse HEAD)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§F a first propagation must exit 0 (rc=$RC)"
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§F a pool with no stamp must be baked (got: $(cat "$T/bake.calls"))"
[ "$(jsonq '.pools["alpha-os"].status')" = ok ] && ok || bad "§F the bake must be recorded ok (got $(jsonq '.pools["alpha-os"].status'))"
[ -f "$FLY/alpha-os.baked-at" ] && [ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok \
  || bad "§F an ok bake must stamp state/fly/alpha-os.baked-at (got $(cat "$FLY/alpha-os.baked-at" 2>/dev/null))"
[ -z "$(marker)" ] && ok || bad "§F a baked pool must carry no dirty marker (got $(marker))"
[ "$(jsonq .drain)" = false ] && ok || bad "§F a merge run must record drain:false (got $(jsonq .drain))"

# ══ §A inside the window: not baked, recorded debounced, marked dirty ════════
stamp $((NOW - 60))
commit "echo v3"
NEW=$(git -C "$T/src" rev-parse HEAD)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§A a debounced run must exit 0 (rc=$RC)"
[ "$(nbake)" = 0 ] && ok || bad "§A a pool inside its window must NOT be baked (got: $(cat "$T/bake.calls"))"
[ "$(jsonq '.pools["alpha-os"].status')" = debounced ] && ok \
  || bad "§A the skip must be recorded debounced, not failed (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(marker)" = "$NEW" ] && ok || bad "§A the pool must be marked dirty at the new sha (got $(marker))"
[ "$(cat "$FLY/alpha-os.baked-at")" = "$((NOW - 60))" ] && ok \
  || bad "§A a debounced tick must not move the bake stamp (got $(cat "$FLY/alpha-os.baked-at"))"
[ "$(nssh)" = 1 ] && ok || bad "§A the box must still be synced on a debounced tick (got $(nssh))"
grep -q 'debounced' "$H/logs/fleet-propagate.log" && ok || bad "§A the debounce must be logged"

# ══ §D the wording: images=0/1 (1 debounced), and NOT critical ══════════════
[ "$(nalert)" = 1 ] && ok || bad "§D a debounced run must still alert exactly once (got $(nalert))"
grep -q -- '--critical' "$T/alerts" && bad "§D a tolerated skip must not be critical: $(cat "$T/alerts")" || ok
grep -q '0/1 pool images rebaked (1 debounced' "$T/alerts" && ok \
  || bad "§D the alert must name the debounce: $(cat "$T/alerts")"
tail -1 "$H/logs/fleet-propagate.log" | grep -q 'images=0/1 (1 debounced)' && ok \
  || bad "§D the log line must qualify 0/1: $(tail -1 "$H/logs/fleet-propagate.log")"

# ══ §B2 inside the window with nothing new: wait, keep the marker, write nothing
BEFORE_SNAP=$(snapshot)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§B2 a tick with nothing due must exit 0 (rc=$RC)"
[ "$(nbake)" = 0 ] && [ "$(nssh)" = 0 ] && ok || bad "§B2 a tick with nothing due must touch no target"
[ "$(nalert)" = 0 ] && ok || bad "§B2 a quiet tick must not alert (got: $(cat "$T/alerts"))"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "§B2 a quiet tick wrote state or logs:
$(diff <(printf '%s\n' "$BEFORE_SNAP") <(snapshot))"
[ "$(marker)" = "$NEW" ] && ok || bad "§B2 the dirty marker must survive until the pool is baked (got $(marker))"

# ══ §B1 the drain: window expired, nothing new merged — bake it anyway ═══════
LAST_SHA=$(jsonq .last_sha)
stamp $((NOW - 3600))
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§B1 a drain run must exit 0 (rc=$RC)"
grep -qx 'alpha-os' "$T/bake.calls" && ok \
  || bad "§B1 a dirty pool must be baked on the next eligible tick (got: $(cat "$T/bake.calls"))"
[ -z "$(marker)" ] && ok || bad "§B1 a completed bake must clear the dirty marker (got $(marker))"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok \
  || bad "§B1 the drain bake must re-stamp (got $(cat "$FLY/alpha-os.baked-at"))"
[ "$(jsonq .last_sha)" = "$LAST_SHA" ] && ok || bad "§B1 a drain must not move last_sha"
[ "$(nssh)" = 0 ] && ok || bad "§B1 a drain must not re-ssh the boxes: $(cat "$T/ssh.calls")"
[ "$(jsonq .drain)" = true ] && ok || bad "§B1 a drain run must record drain:true (got $(jsonq .drain))"
[ "$(nalert)" = 1 ] && ok || bad "§B1 a drain must alert exactly once (got $(nalert))"
grep -q -- '--critical' "$T/alerts" && bad "§B1 a drain that worked is not critical: $(cat "$T/alerts")" || ok
grep -q 'drained' "$T/alerts" && ok || bad "§B1 the drain alert must say so: $(cat "$T/alerts")"
grep -q '^--log-only fleet-propagate drained' "$T/alerts" && ok || bad "§B1 BH-2337: a drain that worked is --log-only: $(cat "$T/alerts")"

# ══ §B3 a merge once the window has expired: baked through the merge path ════
stamp $((NOW - 3600))
echo "deadbee" > "$FLY/alpha-os.image-dirty"
commit "echo v4"
run
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§B3 a merge past the window must bake (got: $(cat "$T/bake.calls"))"
[ "$(nssh)" = 1 ] && ok || bad "§B3 a merge must still sync the boxes (got $(nssh))"
[ -z "$(marker)" ] && ok || bad "§B3 the merge bake must clear the dirty marker (got $(marker))"
[ "$(jsonq .drain)" = false ] && ok || bad "§B3 a merge run must record drain:false"

# ══ §C --force bakes inside the window and marks nothing dirty ══════════════
stamp $((NOW - 60))
run --force
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§C --force must bake regardless of age (got: $(cat "$T/bake.calls"))"
[ -z "$(marker)" ] && ok || bad "§C --force must not mark a pool dirty (got $(marker))"
[ "$(cat "$FLY/alpha-os.baked-at")" -ge "$NOW" ] && ok || bad "§C --force must re-stamp"

# ══ §E POOL_IMAGE_MIN_AGE_MIN=0 keeps the per-merge behaviour ═══════════════
stamp $((NOW - 60))
commit "echo v5"
KNOB=0 run
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§E knob 0 must bake every merge (got: $(cat "$T/bake.calls"))"

# ══ §G unusable stamps and an unusable knob ═════════════════════════════════
stamp "garbage"
commit "echo v6"
run
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§G an unparseable stamp must bake (got: $(cat "$T/bake.calls"))"
stamp $((NOW + 99999))
commit "echo v7"
run
grep -qx 'alpha-os' "$T/bake.calls" && ok || bad "§G a future stamp must bake, not suppress forever (got: $(cat "$T/bake.calls"))"
stamp $((NOW - 60))
commit "echo v8"
LOG_BEFORE=$(nlog)
KNOB=abc run
grep -q 'POOL_IMAGE_MIN_AGE_MIN=abc' "$H/logs/fleet-propagate.log" && ok \
  || bad "§G a garbage knob must be named in the log, never silent"
[ "$(nbake)" = 0 ] && ok || bad "§G a garbage knob must fall back to the 30m default, not to per-merge"
[ "$(grep -c 'POOL_IMAGE_MIN_AGE_MIN=abc' "$H/logs/fleet-propagate.log")" = 1 ] && ok \
  || bad "§G the bad knob must be named ONCE, not on repeat"
[ "$(( $(nlog) - LOG_BEFORE ))" = 3 ] && ok \
  || bad "§G the bad-knob run must log the warning, the debounce and its summary (got $(( $(nlog) - LOG_BEFORE )) lines)"

# ══ §H a FAILED bake stamps nothing and clears nothing ══════════════════════
rm -f "$FLY/alpha-os.image-dirty"
stamp $((NOW - 3600))
STAMP_BEFORE=$(cat "$FLY/alpha-os.baked-at")
commit "echo v9"
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
PROPAGATE_PAGE_ON_FIRST_FAIL=1 BAKE_FAIL=alpha-os run
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok \
  || bad "§H a failed bake must be recorded fail (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(cat "$FLY/alpha-os.baked-at")" = "$STAMP_BEFORE" ] && ok \
  || bad "§H a failed bake must not be stamped as fresh (got $(cat "$FLY/alpha-os.baked-at"))"
grep -q -- '--critical' "$T/alerts" && ok || bad "§H a failed bake must stay critical: $(cat "$T/alerts")"

# ══ §H2 a failed DRAIN bake is one attempt, not a retry every five minutes ══
# Without this the marker and the stale stamp both survive the failure, so the
# next */5 tick drains the same pool again — a permanently broken pool would
# cost 288 remote build attempts a day, which is the spend this ticket exists to
# stop. BH-3463 made a failed bake retry, capped per pool per UTC day
# (POOL_BAKE_RETRY_MAX, pinned in tests/fleet-propagate.bh-3463-test.sh §R);
# this section now pins the knob's OFF setting, 0, which is exactly the old
# one-attempt behaviour.
stamp $((NOW - 3600))
STAMP_BEFORE=$(cat "$FLY/alpha-os.baked-at")
echo "deadbee" > "$FLY/alpha-os.image-dirty"
POOL_BAKE_RETRY_MAX=0 BAKE_FAIL=alpha-os run
[ "$(nbake)" = 1 ] && ok || bad "§H2 the drain must attempt the dirty pool once (got: $(cat "$T/bake.calls"))"
[ "$(jsonq .drain)" = true ] && ok || bad "§H2 that attempt must run on the drain path (got $(jsonq .drain))"
[ "$(jsonq '.pools["alpha-os"].status')" = fail ] && ok \
  || bad "§H2 a failed drain bake must be recorded fail (got $(jsonq '.pools["alpha-os"].status'))"
grep -q -- '--critical' "$T/alerts" && ok || bad "§H2 a failed drain bake must be critical: $(cat "$T/alerts")"
[ "$(cat "$FLY/alpha-os.baked-at")" = "$STAMP_BEFORE" ] && ok \
  || bad "§H2 a failed bake must not be stamped as fresh (got $(cat "$FLY/alpha-os.baked-at"))"
[ -z "$(marker)" ] && ok \
  || bad "§H2 the attempt must clear the dirty marker, ok or fail (got $(marker))"
LOG_BEFORE=$(nlog)
POOL_BAKE_RETRY_MAX=0 BAKE_FAIL=alpha-os run
[ "$(nbake)" = 0 ] && ok || bad "§H2 the next tick must NOT drain the same pool again (got: $(cat "$T/bake.calls"))"
[ "$(nalert)" = 0 ] && ok || bad "§H2 the next tick must be quiet, not alert again (got: $(cat "$T/alerts"))"
[ "$(nlog)" = "$LOG_BEFORE" ] && ok || bad "§H2 the next tick must write no log line"

# ══ §D2 one debounced and one failed: critical names only the failure ═══════
: > "$H/flags/fly-pool-app-beta"
stamp $((NOW - 60))
rm -f "$FLY/beta.baked-at"
commit "echo v10"
# BH-3680: first-fail paging pinned; the default (warn while a retry is queued) is tests/fleet-propagate.bh-3680-test.sh
PROPAGATE_PAGE_ON_FIRST_FAIL=1 BAKE_FAIL=beta run
grep -q -- '--critical' "$T/alerts" && ok || bad "§D2 a failed pool must still be critical: $(cat "$T/alerts")"
[ "$(jsonq '.pools["alpha-os"].status')" = debounced ] && ok \
  || bad "§D2 the fresh pool must read debounced (got $(jsonq '.pools["alpha-os"].status'))"
[ "$(jsonq '.pools["beta"].status')" = fail ] && ok || bad "§D2 the failed pool must read fail (got $(jsonq '.pools["beta"].status'))"
FAILED_LIST=$(sed -n 's/.*failed:\([^,]*\).*/\1/p' "$T/alerts" | tail -1)
grep -q 'beta' <<<"$FAILED_LIST" && ok || bad "§D2 the alert must name the failed pool (got '$FAILED_LIST')"
grep -q 'alpha-os' <<<"$FAILED_LIST" && bad "§D2 a debounced pool must never be listed as failed (got '$FAILED_LIST')" || ok
grep -q '0/2 pool images rebaked (1 debounced' "$T/alerts" && ok \
  || bad "§D2 the counts must stay honest: $(cat "$T/alerts")"
rm -f "$H/flags/fly-pool-app-beta" "$FLY/beta.baked-at" "$FLY/beta.image-dirty"

# ══ §I --check reads the same state, prints the decision, writes nothing ════
rm -f "$FLY/alpha-os.image-dirty"
stamp $((NOW - 60))
commit "echo v11"
BEFORE_SNAP=$(snapshot)
run --check; RC=$?
[ "$RC" = 0 ] && ok || bad "§I --check must exit 0 (rc=$RC)"
grep -q 'debounced' "$T/out" && ok || bad "§I --check must show the debounce decision: $(cat "$T/out")"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "§I --check wrote to \$H/state or \$H/logs:
$(diff <(printf '%s\n' "$BEFORE_SNAP") <(snapshot))"
[ -z "$(marker)" ] && ok || bad "§I --check must not mark a pool dirty (got $(marker))"
[ "$(nbake)" = 0 ] && [ "$(nssh)" = 0 ] && ok || bad "§I --check must not bake or ssh"

# ══ §J a dirty marker for a project that no longer has a pool ═══════════════
KNOB=0 run                      # settle the pending commit, clear every marker
rm -f "$FLY/alpha-os.image-dirty"
echo "deadbee" > "$FLY/gamma.image-dirty"
LOG_BEFORE=$(nlog)
run; RC=$?
[ "$RC" = 0 ] && ok || bad "§J a stale marker must not error (rc=$RC)"
[ ! -f "$FLY/gamma.image-dirty" ] && ok || bad "§J a marker for a project with no pool flag must be removed"
[ "$(nbake)" = 0 ] && ok || bad "§J a stale marker must bake nothing (got: $(cat "$T/bake.calls"))"
[ "$(nalert)" = 0 ] && ok || bad "§J a stale marker must not alert (got: $(cat "$T/alerts"))"
[ "$(nlog)" = "$LOG_BEFORE" ] && ok || bad "§J a stale marker must not write a log line"

# ══ §I2 --check in drain mode names the pools it would drain, and writes nothing
stamp $((NOW - 3600))
echo "deadbee" > "$FLY/alpha-os.image-dirty"
BEFORE_SNAP=$(snapshot)
run --check; RC=$?
[ "$RC" = 0 ] && ok || bad "§I2 --check in drain mode must exit 0 (rc=$RC)"
grep -q 'drain' "$T/out" && grep -q 'alpha-os' "$T/out" && ok \
  || bad "§I2 --check must name the pools it would drain: $(cat "$T/out")"
[ "$(snapshot)" = "$BEFORE_SNAP" ] && ok || bad "§I2 --check in drain mode wrote state or logs:
$(diff <(printf '%s\n' "$BEFORE_SNAP") <(snapshot))"
[ "$(marker)" = "deadbee" ] && ok || bad "§I2 --check must leave the dirty marker alone (got $(marker))"
[ "$(nbake)" = 0 ] && [ "$(nssh)" = 0 ] && ok || bad "§I2 --check must not bake or ssh"

echo "fleet-propagate.bh-821-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
