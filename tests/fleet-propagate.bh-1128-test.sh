#!/bin/bash
# tests/fleet-propagate.bh-1128-test.sh — when the hub's ff-only pull fails, the
# tick says WHICH branch, HOW far apart, and WHAT git said.
#
# WHAT THIS PINS (BH-1128, item 2). bin/fleet-propagate.sh:415-421 enriches a
# failed `git pull --ff-only` with the checkout's branch, its ahead/behind
# counts and git's first error line, into `hub_reason`, the log line and the one
# --critical alert. It was probed by hand when BH-1099 shipped and never pinned,
# so the next edit to that block could flatten it back to "pull failed" with
# every suite green — and the operator reading `hub=fail` would be back to
# guessing why the fleet did not move.
#
# The hub failure here is real, not stubbed: the checkout is on main, clean, and
# carries a local commit the origin does not have, so the 2b preflight passes
# and the ff-only pull aborts exactly as it does on a diverged hub.
#
# Run from anywhere: tests/fleet-propagate.bh-1128-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null \
  || { echo "jq/git missing — skipping"; exit 0; }

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1   # BH-5247: FLEET_PATHS, or the run fails closed
echo hub > "$H/state/box-id"

cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 10.0.0.1
beta     Acme/beta     -                     -          4 box-beta  10.0.0.2
EOF
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"
: > "$H/flags/fly-pool-app-alpha-os"

# ── stubs: everything outside the script under test ─────────────────────────
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
if [ "${1:-}" = "-l" ]; then cat "$LIVE_CRON" 2>/dev/null; exit 0; fi
cp "$1" "$INSTALLED_CRON"; exit 0
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
echo "synced (stub)"; exit 0
EOF
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$BAKE_CALLS"
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"
exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*

# ── a real scratch repo: bare origin, a source clone, the hub's checkout ────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin" "$T/src/docs" "$T/src/cron"
echo "echo v1" > "$T/src/bin/run-build.sh"
echo "readme" > "$T/src/docs/README.md"
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/src/cron/hub.cron"
cat > "$T/src/bin/render-crontab.sh" <<'EOF'
#!/bin/bash
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n*/5 * * * * /root/harness/bin/fleet-propagate.sh\n'
EOF
chmod +x "$T/src/bin/render-crontab.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
git -C "$T/checkout" config user.email t@x; git -C "$T/checkout" config user.name t
printf '2,12 * * * * /root/harness/bin/run-triage.sh alpha-os\n' > "$T/livecron"

commit() { # commit <path> <content>
  mkdir -p "$(dirname "$T/src/$1")"; echo "$2" > "$T/src/$1"
  git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main
}
run() { # run [flags...]
  : > "$T/ssh.calls"; : > "$T/bake.calls"; : > "$T/alerts"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_CALLS="$T/ssh.calls" BAKE_CALLS="$T/bake.calls" ALERTS="$T/alerts" \
    LIVE_CRON="$T/livecron" INSTALLED_CRON="$T/installed.cron" \
    bash "$H/bin/fleet-propagate.sh" "$@" ) > "$T/out" 2>"$T/err"
}
nalert() { grep -c . "$T/alerts" 2>/dev/null | head -1; }
jsonq()  { jq -r "$1" "$H/state/fleet-propagate.json" 2>/dev/null; }

# ── 0. one clean tick, which leaves the hub checkout at origin/main ─────────
# (a tick with nothing new exits before it writes anything, so the fixture needs
# a real fleet-path commit to record a last_sha)
commit bin/run-build.sh "echo v2"
run
[ "$(jsonq .hub)" = ok ] && ok || bad "0: the first tick must record hub=ok (got: $(jsonq .hub); $(cat "$T/err"))"

# ── the failure: a fleet-path commit to propagate, and a hub checkout that is
#    on main, clean, and one commit ahead of origin ───────────────────────────
commit bin/run-build.sh "echo pull-fail"
echo local > "$T/checkout/local.txt"
git -C "$T/checkout" add -A
git -C "$T/checkout" commit -qm local
LOCAL_SHA=$(git -C "$T/checkout" rev-parse HEAD)

run
RC=$?
[ "$RC" = 0 ] && ok || bad "rc: a hub failure must not make the lane exit non-zero (rc=$RC): $(cat "$T/err")"
[ "$(jsonq .hub)" = fail ] && ok || bad "hub must be fail (got: $(jsonq .hub))"

REASON=$(jsonq .hub_reason)
grep -Eq '^checkout on main, ahead 1 / behind 1: .+' <<<"$REASON" \
  && ok || bad "hub_reason must name the branch and the ahead/behind counts (got: $REASON)"
grep -q 'fast-forward' <<<"$REASON" \
  && ok || bad "hub_reason must carry git's own first error line (got: $REASON)"

grep -q 'hub: git pull --ff-only FAILED (checkout on main, ahead 1 / behind 1: ' "$H/logs/fleet-propagate.log" \
  && ok || bad "the log line must carry the same enrichment: $(grep 'ff-only' "$H/logs/fleet-propagate.log")"

[ "$(nalert)" = 1 ] && ok || bad "a failing tick must raise exactly one alert (got: $(cat "$T/alerts"))"
grep -q -- '--critical' "$T/alerts" && ok || bad "the hub-failure alert must be --critical: $(cat "$T/alerts")"
grep -q 'hub=fail (checkout on main, ahead 1 / behind 1:' "$T/alerts" \
  && ok || bad "the alert text must name the branch and counts: $(cat "$T/alerts")"

# The lane never resets a hub checkout: the operator's local commit is still
# HEAD after the failed tick.
[ "$(git -C "$T/checkout" rev-parse HEAD)" = "$LOCAL_SHA" ] \
  && ok || bad "the hub checkout must be left exactly as it was"

echo "fleet-propagate.bh-1128-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
