#!/bin/bash
# tests/fleet-propagate.bh-7189-test.sh — bin/fleet-propagate.sh: a merge to main
# reaches every box without waiting for the hub's own sync, and the log names
# each box with its before->after sha.
#
# WHY (BH-7189, 2026-10-16). Boxes stayed on an old head for up to 17 minutes
# after a merge. The push path was fine (boxes=9/9 on every merge tick). The
# delay was the order: the box fan-out started only AFTER the hub's
# harness-sync, which now ends at its 300 s timeout on every tick. Boxes pull
# from origin and do not need the hub, so the fan-out starts before the hub sync
# and the tick waits for both. The log had one summary line and no per-box line,
# so a box left behind was visible only as a count.
#   C1  the first box ssh starts before the hub's harness-sync ends
#   C2  the tick still waits for the boxes (the record holds all boxes)
#   C3  one log line per box: name, before->after sha, rc
#   C4  a failed box and a box with no address are NAMED in the log
#   C5  a box that answers rc 0 on a sha that is not the new head is marked behind
#
# Run from anywhere: tests/fleet-propagate.bh-7189-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "fleet-propagate.bh-7189-test: SKIPPED - jq missing"; exit 0; }

H="$T/harness"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$T/bin"
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
scratch_install_closure bin/lib/fleet-paths.sh "$H" >/dev/null || exit 1
echo hub > "$H/state/box-id"
cat > "$H/fleet.conf" <<'EOF'
alpha-os Acme/alpha-os https://alpha.example /api/board 2 box-alpha 192.0.2.1
beta     Acme/beta     -                     -          4 box-beta  192.0.2.2
gamma    Acme/gamma    -                     -          6 box-gone
EOF
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$H/bin/"

# ssh stub: stamp the call time, answer "before" then "after" like the real box.
cat > "$T/bin/ssh" <<'EOF'
#!/bin/bash
IP=""; for A in "$@"; do case "$A" in root@*) IP="${A#root@}" ;; esac; done
date +%s.%N >> "$SSH_TIMES"
if [ "$IP" = "${SSH_FAIL_IP:-}" ]; then echo "before=1111111"; echo "1111111"; exit 7; fi
if [ "$IP" = "${SSH_STALE_IP:-}" ]; then echo "before=1111111"; git -C "$ORIGIN" rev-parse HEAD~1; exit 0; fi
echo "before=1111111"; git -C "$ORIGIN" rev-parse HEAD; exit 0
EOF
cat > "$T/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$T/bin/crontab" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$H/bin/harness-sync.sh" <<'EOF'
#!/bin/bash
sleep "${HUB_SLEEP:-3}"; date +%s.%N > "$HUB_DONE"; exit 0
EOF
cat > "$H/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$H/bin/lane-alert.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTS"; exit 0
EOF
chmod +x "$T/bin"/* "$H/bin"/*

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"; echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
commit() { echo "$2" > "$T/src/$1"; git -C "$T/src" add -A && git -C "$T/src" commit -qm "$1" && git -C "$T/src" push -q origin main; }
run() {
  : > "$T/ssh.times"; : > "$T/alerts"; rm -f "$T/hub.done"
  ( HARNESS="$H" HARNESS_CHECKOUT="$T/checkout" POOL_IMAGE_MIN_AGE_MIN=0 \
    FLEET_PROPAGATE_PATH="$T/bin:/usr/bin:/bin:/usr/local/bin" \
    SSH_TIMES="$T/ssh.times" HUB_DONE="$T/hub.done" ALERTS="$T/alerts" ORIGIN="$T/origin" \
    SSH_FAIL_IP="${SSH_FAIL_IP:-}" SSH_STALE_IP="${SSH_STALE_IP:-}" \
    bash "$H/bin/fleet-propagate.sh" ) > "$T/out" 2>"$T/err"
}
LOG="$H/logs/fleet-propagate.log"

commit bin/run-build.sh "echo v2"; NEW=$(git -C "$T/src" rev-parse HEAD)
run
FIRST=$(sort -n "$T/ssh.times" | head -1)
DONE=$(cat "$T/hub.done" 2>/dev/null)
# C1
if [ -n "$FIRST" ] && [ -n "$DONE" ] && awk -v a="$FIRST" -v b="$DONE" 'BEGIN{exit !(a<b)}'; then ok
else bad "C1: the first box ssh ($FIRST) must start before the hub sync ends ($DONE)"; fi
# C2
[ "$(jq -r '.boxes|keys|length' "$H/state/fleet-propagate.json" 2>/dev/null)" = 3 ] && ok \
  || bad "C2: the record must hold all 3 boxes: $(jq -c .boxes "$H/state/fleet-propagate.json" 2>/dev/null)"
# C3
grep -q "box box-alpha: 1111111->${NEW:0:7} rc=0" "$LOG" && ok \
  || bad "C3: alpha needs a per-box line 1111111->${NEW:0:7} rc=0: $(grep ' box ' "$LOG")"
grep -q "box box-beta: 1111111->${NEW:0:7} rc=0" "$LOG" && ok || bad "C3: beta needs a per-box line"
# C4
grep -q "box box-gone: .*no-address" "$LOG" && ok || bad "C4: the box with no address must be named: $(grep ' box ' "$LOG")"
commit bin/run-build.sh "echo v3"; NEW=$(git -C "$T/src" rev-parse HEAD)
SSH_FAIL_IP=192.0.2.2 run
grep -q "box box-beta: .*rc=7" "$LOG" && ok || bad "C4: a failed box must be named with its rc: $(grep ' box ' "$LOG")"
# C5
commit bin/run-build.sh "echo v4"; NEW=$(git -C "$T/src" rev-parse HEAD)
SSH_STALE_IP=192.0.2.1 run
OLD=$(git -C "$T/src" rev-parse HEAD~1)
grep -q "box box-alpha: 1111111->${OLD:0:7} rc=0 behind" "$LOG" && ok \
  || bad "C5: rc 0 on an old head must be marked behind: $(grep ' box ' "$LOG" | tail -3)"

echo "fleet-propagate.bh-7189-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
