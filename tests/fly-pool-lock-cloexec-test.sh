#!/bin/bash
# tests/fly-pool-lock-cloexec-test.sh — flyctl must not inherit the pool flock.
#
# WHAT WENT WRONG. bash `exec 8>lock; flock -n 8` leaves fd 8 inheritable.
# flyctl's agent took that fd, held fly-pool-<project>.lock after the tick
# exited, and the next tick `flock -n 8 || exit 0` skipped. project-4 TK-1566/1571/
# 1576/1584 sat ~50m with no machine (2026-09-11). Killing the agent freed
# the lock; the next spawn leaked it again.
#
# THE PROPERTY. Every flyctl child of a holding tick must NOT see the lock
# fd. Driven, not grepped: the fly stub records whether fd 8 still points at
# the pool lock. A wrap that never runs, or a new `"$FLY"` call that bypasses
# it, fails this.
# Run from anywhere: tests/fly-pool-lock-cloexec-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/logs" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/state/fly" "$T/h/state/fly-pool/project-5" "$T/h/state/build-queue/project-5" \
         "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/fleet.conf" "$T/h/fleet.conf"
printf 'HARNESS_SECRET=test-secret\n' > "$T/h/env/global.env"
: > "$T/h/env/fly.env"
printf '3\n' > "$T/h/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$T/h/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$T/h/state/fly/project-5.json"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"

# flyctl stub: the assertion. If fd 8 still points at the pool lock, the
# wrap did not drop it and a spawned agent would pin the next tick.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
LOCK_HIT=0
if [ -e /proc/self/fd/8 ]; then
  t=$(readlink /proc/self/fd/8 2>/dev/null || true)
  case "$t" in *fly-pool*) LOCK_HIT=1 ;; esac
fi
if [ "$LOCK_HIT" = 1 ]; then
  printf 'LEAK fd8=%s cmd=%s\n' "$t" "$*" >> "$FD_SINK"
else
  printf 'OK cmd=%s\n' "$*" >> "$FD_SINK"
fi
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *) : ;;
esac
exit 0
STUB

cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
printf '{"ok":true}\n200\n'
STUB
chmod +x "$T/h/bin/beat.sh" "$T/h/bin/result-prefix-ok.sh" "$T/fakebin"/*

jq -nc '{machine:"m1",key:"TK-268",ticket_id:"268",attempt:0,deferrals:0}' \
  > "$T/h/state/fly-pool/project-5/m1.json"
: > "$T/fd.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
         FLEET_CONF="$T/h/fleet.conf" FD_SINK="$T/fd.txt" \
         FLY_API_TOKEN_PROJECT_5=tok TMPDIR="$T" \
         FLY_BIN_DIR="$T/fakebin"
  bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )

[ -s "$T/fd.txt" ] && ok || bad "flyctl was never invoked (cannot prove the wrap): $(ls -la "$T/fd.txt" 2>/dev/null)"
if grep -q '^LEAK' "$T/fd.txt"; then
  bad "flyctl inherited the pool lock fd: $(grep '^LEAK' "$T/fd.txt" | head -3)"
else
  ok
fi
grep -q '^OK ' "$T/fd.txt" && ok || bad "no clean flyctl invocation recorded: $(cat "$T/fd.txt")"

# The wrap must exist at the lock site — a future `"$FLY"` call is covered
# only because FLY itself is the wrapper. If that assignment disappears,
# the driven check above may still pass on a path that never starts an
# agent, and the leak returns.
grep -q 'fly-noleak' "$DIR/bin/fly-pool.sh" && ok || bad "fly-pool.sh lost the flyctl no-leak wrap"
grep -q '8>&-' "$DIR/bin/fly-pool.sh" && ok || bad "fly-pool.sh no longer drops fd 8 on the flyctl exec"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
