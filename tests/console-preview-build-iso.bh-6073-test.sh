#!/bin/bash
# tests/console-preview-build-iso.bh-6073-test.sh — nothing a console preview
# build starts outlives the build (BH-6073). cpv_run_unpriv
# (bin/lib/console-preview.sh) runs each build command in its own PID
# namespace, refuses to start while a process of the build user is alive, and
# refuses the build output while one is still alive after it.
#
# Drives the REAL hub lane bin/console-preview-deploy.sh (scratch harness,
# scratch_install_closure, a scratch origin with refs/pull/<n>/head, stubs for
# gh, npm, npx, curl, node) and the lib function itself.
#
#   C0 control: the npm stub's build leaves two detached sleeps when it runs
#      bare, and the survivor probe finds both
#   C1 the lane: a build that starts a `setsid` sleep 300 and a double-fork
#      `nohup` sleep 300 deploys, and neither pid is alive after the lane
#   C2 the lib: a build that times out returns 124 fast and leaves no pid alive
#   C3 a live process of the build uid before the build: no npm call, one lane
#      line that names the user, the uid and the pid, one console-preview-box
#      alert, no failed record, no comment
#   C4 a process of the build uid alive AFTER the build: rc 125 from the lib;
#      in the lane no dist copy, no upload, a box alert, no failed record
#   C5 a non-self build user on a box that cannot make a PID namespace: rc 125,
#      the command does not run (root only)
#   C6 six live pids: the line counts 6 and lists the first 5
#   C7 CPV_TEST_UID is read in self mode only: a real build user is checked by
#      its own uid (root only). The build root is under /tmp, because a
#      scratch dir under /root is not reachable by nobody
#   C8 self mode with no PID namespace still runs, and says so on stderr
#   C9 a PR build that exits 125 is the head's fault, not a box fault: rc 1
#      from the lib; in the lane "vite build failed", `failed 1`, no box alert
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/console-preview-build-iso.bh-6073-test.sh
# CPV_PIDNS_REQUIRED=1 makes a host with no PID namespace fail C1 and C2
# instead of skipping them.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
skip() { echo "SKIP: $1"; }
for c in git jq flock pgrep pkill setsid nohup timeout; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
[ -f "$DIR/bin/console-preview-deploy.sh" ] && [ -f "$DIR/bin/lib/console-preview.sh" ] \
  || { echo "FAIL: bin/console-preview-deploy.sh or bin/lib/console-preview.sh does not exist"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset CONSOLE_PREVIEW_DEPLOY CONSOLE_PREVIEW_MAX_PER_RUN CONSOLE_PAGES_URL CONSOLE_PAGES_PROJECT CLOUDFLARE_API_TOKEN \
      CLOUDFLARE_ACCOUNT_ID CONSOLE_PREVIEW_QA_SCREENS CONSOLE_PREVIEW_WRANGLER CONSOLE_PREVIEW_MAX_ATTEMPTS CPV_TEST_UID
SLUG=o/console-fixture
# Every detached sleep this suite starts is named cpv6073-<TOK>-<x>: the token
# is this run's scratch suffix, so the probe and the EXIT kill never match
# another run or the suite's own command line.
TOK=${SCRATCH##*.}
NAME="cpv6073-$TOK"
survivors() { pgrep -f "^$NAME-" | sort -n | tr '\n' ' ' | sed 's/ $//'; }
PLANTS=()
cleanup_procs() {
  pkill -KILL -f "^$NAME-" 2>/dev/null
  local p; for p in "${PLANTS[@]}"; do kill -KILL "$p" 2>/dev/null; done
  return 0
}
C7R=""
# rm_c7r: remove C7's build root. It lives under $T, so scratch_rm owns it.
rm_c7r() { [ -z "$C7R" ] || scratch_rm "$C7R"; C7R=""; }
trap 'cleanup_procs; rm_c7r; __scratch_exit_trap' EXIT

# A uid with no process on this box: the build user of the self-mode cases.
U=""
for u in $(seq 61073 61999); do
  getent passwd "$u" >/dev/null 2>&1 && continue
  [ -z "$(pgrep -u "$u"; pgrep -U "$u")" ] && { U=$u; break; }
done
[ -n "$U" ] || { echo "FAIL: no free uid in 61073..61999"; exit 1; }

# Can this host make a PID namespace (as root, or in a user namespace)?
PIDNS=0
unshare --pid --fork --kill-child --mount-proc -- true >/dev/null 2>&1 && PIDNS=1
[ "$PIDNS" = 1 ] || { unshare --user --map-root-user --pid --fork --kill-child --mount-proc -- true >/dev/null 2>&1 && PIDNS=1; }
pidns_case() { # pidns_case <case> — 0 when the case can run here
  [ "$PIDNS" = 1 ] && return 0
  if [ "${CPV_PIDNS_REQUIRED:-}" = 1 ]; then bad "$1: no PID namespace on $(hostname) and CPV_PIDNS_REQUIRED=1"; else skip "$1: no PID namespace on $(hostname)"; fi
  return 1
}
ROOT=0; [ "$(id -u)" = 0 ] && ROOT=1

# ── fixture: origin with PR refs, a hub checkout, a scratch harness ───────────
O="$T/origin.git"; W="$T/work"; CK="$T/ck"; HB="$T/h"
git init -q --bare -b main "$O"; git init -q -b main "$W"
mkdir -p "$W/console-ui/src" "$W/console-ui/functions/api" "$W/worker/jobs" "$W/catalog"
echo '{"name":"console-ui"}' > "$W/console-ui/package.json"
echo 'export const who = "main";' > "$W/console-ui/functions/api/f.js"
echo 'export const a = 1;' > "$W/console-ui/src/app.js"
echo '{ "account_id": "acct-fixture" }' > "$W/worker/jobs/wrangler.jsonc"
echo '{}' > "$W/catalog/x.json"
git -C "$W" add -A; git -C "$W" commit -qm base; git -C "$W" push -q "$O" main
git -C "$W" checkout -q -B pr11 main
echo "change 11" >> "$W/console-ui/src/app.js"; git -C "$W" commit -qam "pr 11"
git -C "$W" push -q "$O" "HEAD:refs/pull/11/head"; S11=$(git -C "$W" rev-parse HEAD)
git clone -q "$O" "$CK"

mkdir -p "$HB/env" "$HB/logs" "$HB/state" "$HB/locks" "$T/sbin" "$T/pg" "$T/nons" "$T/passns"
scratch_install_closure bin/console-preview-deploy.sh "$HB" >/dev/null || bad "closure of bin/console-preview-deploy.sh"
printf 'CLOUDFLARE_API_TOKEN=%s\n' tok-fixture-6073 > "$HB/env/cloudflare.env"
printf 'HARNESS_SECRET=%s\n' hsec-fixture-6073-not-real > "$HB/env/global.env"
QATOK="1791700000.$(printf 'cd%.0s' $(seq 1 32))"

cat > "$T/sbin/gh" <<EOF
#!/bin/bash
printf 'gh %s\n' "\$*" >> "$T/calls.log"
send() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "\$1" "\$2"; }
case "\$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    all="\$*"; n=\${all#*/issues/}; n=\${n%%/*}
    for a in "\$@"; do case "\$a" in body=@*) cat "\${a#body=@}" > "$T/posted-\$n" ;; esac; done
    send 201 '{"id":1}' ;;
  *"-X GET repos/"*"/issues/"*"/comments"*) send 200 '[]' ;;
  *"-X GET repos/"*"/pulls"*) send 200 "\$(cat "$T/openprs")" ;;
esac
exit 0
EOF
# detach.sh: what a hostile vite.config.js does. A setsid sleep 300 and a
# double-fork nohup sleep 300, both named $NAME-<x>, then $T/started.
cat > "$T/detach.sh" <<EOF
#!/bin/bash
setsid bash -c 'exec -a $NAME-a sleep 300' </dev/null >/dev/null 2>&1 &
( nohup bash -c 'exec -a $NAME-b sleep 300' </dev/null >/dev/null 2>&1 & )
touch "$T/started"
EOF
# npm run build: detach, write dist, then (when $T/hold) wait for $T/go so the
# suite can read the host pids of the detached sleeps while the build is alive.
# $T/arm-post makes the build leave the post-check's pgrep stub armed (C4).
# $T/exit125 makes the build exit 125, as a hostile package.json can (C9).
cat > "$T/sbin/npm" <<EOF
#!/bin/bash
printf 'npm %s\n' "\$*" >> "$T/calls.log"
case "\$1" in
  ci) exit 0 ;;
  run) [ "\$2" = build ] || exit 1
       [ -f "$T/exit125" ] && exit 125
       bash "$T/detach.sh"
       [ -f "$T/arm-post" ] && touch "$T/pg.after"
       mkdir -p dist; echo '<html>' > dist/index.html
       if [ -f "$T/hold" ]; then for _ in \$(seq 1 200); do [ -f "$T/go" ] && break; sleep 0.1; done; fi
       exit 0 ;;
esac
exit 1
EOF
cat > "$T/sbin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/calls.log"
echo "✨ Deployment complete! Take a peek over at https://x.example.invalid"
exit 0
EOF
cat > "$T/sbin/curl" <<STUB
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/calls.log"
case "\$*" in
  *"/pages/projects/"*) echo '{"success":true,"result":{"deployment_configs":{"preview":{"env_vars":{}}}}}' ;;
  *"/api/qa/session"*) printf '{"ok":true,"token":"%s","expires_at":1791700000}\n' "$QATOK" ;;
  *) exit 7 ;;
esac
STUB
cat > "$T/sbin/node" <<STUB
#!/bin/bash
printf 'SCREEN / 1440 ok\nSCREEN / 390 ok\nQA COVERAGE: screens=2 flows=0 shots=2\nQA: PASS\n'; exit 0
STUB
# pgrep stub (only on PATH in C3 non-root, C4, C6): for -u/-U $U it answers
# the pids in $T/pg.pids, or 4243 once $T/pg.after exists; anything else goes
# to the real pgrep.
REALPG=$(command -v pgrep)
cat > "$T/pg/pgrep" <<EOF
#!/bin/bash
if [ "\$#" = 2 ] && { [ "\$1" = -u ] || [ "\$1" = -U ]; } && [ "\$2" = "$U" ]; then
  if [ -f "$T/pg.after" ]; then echo 4243; exit 0; fi
  [ -s "$T/pg.pids" ] && { cat "$T/pg.pids"; exit 0; }
  exit 1
fi
exec "$REALPG" "\$@"
EOF
# unshare that always fails (a box with no PID namespace), and one that runs
# its command with no namespace at all (C7 isolates the uid check).
printf '#!/bin/bash\necho "unshare: unshare failed: Operation not permitted" >&2\nexit 1\n' > "$T/nons/unshare"
cat > "$T/passns/unshare" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift; exec "$@"
EOF
printf '#!/bin/bash\nprintf "alert %%s\\n" "$*" >> "%s/calls.log"\n' "$T" > "$HB/bin/lane-alert.sh"
chmod +x "$T/sbin/"* "$T/pg/pgrep" "$T/nons/unshare" "$T/passns/unshare" "$HB/bin/lane-alert.sh"
jq -nc --arg s "$S11" --arg r "$SLUG" '[{number:11, head:{ref:"ticket/bh-11", sha:$s, repo:{full_name:$r}}, base:{ref:"main"}}]' > "$T/openprs"

reset() {
  cleanup_procs
  rm -f "$T"/posted-* "$T/started" "$T/hold" "$T/go" "$T/arm-post" "$T/exit125" "$T/pg.after" "$T/pg.pids"
  scratch_rm "$HB/state/console-preview-deploy"; : > "$T/calls.log"
}
# lane [extra PATH dir]: one lane tick in self mode, build uid $U.
lane() {
  ( cd "$T" && env -u CLOUDFLARE_API_TOKEN HARNESS="$HB" HARNESS_CHECKOUT="$CK" HARNESS_ENV_DIR="$HB/env" \
      HARNESS_REPO="$SLUG" PATH="${1:+$1:}$T/sbin:$PATH" LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T" \
      HARNESS_TEST_SANDBOX=1 CONSOLE_PREVIEW_BUILD_USER=self CPV_TEST_UID="$U" CONSOLE_PREVIEW_BUILD_TMP="$T" \
      CONSOLE_PREVIEW_DEPLOY=1 CONSOLE_PAGES_URL=https://pages-fixture.example.invalid \
      bash "$HB/bin/console-preview-deploy.sh" ) > "$T/out" 2>&1
}
rec()     { cat "$HB/state/console-preview-deploy/$1" 2>/dev/null; }
uploads() { grep -c "^npx .*pages deploy .*--commit-hash $S11 " "$T/calls.log"; }
alerts()  { grep -c '^alert .*--id console-preview-box ' "$T/calls.log"; }
# lib <out> <extra PATH dir> <timeout> <cmd...>: cpv_run_unpriv in its own
# build root $LB (default $T/lb; a fresh tree each call), env as given by the
# caller. C7 sets LB under its own root, $T/c7r.
lib() {
  local out="$1" xp="$2" LB="${LB:-$T/lb}"; shift 2
  scratch_rm "$LB" || return 9
  mkdir -p "$LB/w"
  ( HARNESS="$HB"; PATH="${xp:+$xp:}$PATH"; . "$HB/bin/lib/console-preview.sh" || exit 9
    cpv_run_unpriv "$LB" "$LB/w" "$@" ) > "$out" 2>&1
}
# wait_started: wait (max 20 s) for the stub build to report its detach.
wait_started() { local i; for i in $(seq 1 200); do [ -f "$T/started" ] && return 0; sleep 0.1; done; return 1; }

# ── C0: control — the probe sees a detached survivor ─────────────────────────
reset; mkdir -p "$T/c0"
( cd "$T/c0" && "$T/sbin/npm" run build ) >/dev/null 2>&1
sleep 0.3
n0=$(survivors | wc -w)
[ "$n0" = 2 ] && ok || bad "C0 the bare stub build must leave 2 detached sleeps for the probe to see: '$(survivors)'"
cleanup_procs

# ── C1: the lane's build step leaves no detached process alive ───────────────
if pidns_case C1; then
  reset; touch "$T/hold"
  lane & LP=$!
  wait_started || bad "C1 the stub build never started: $(cat "$T/out")"
  sleep 0.3
  PIDS1=$(survivors)
  touch "$T/go"; wait "$LP"; RC=$?
  [ "$RC" = 0 ] && ok || bad "C1 lane rc=$RC $(cat "$T/out")"
  [ "$(echo "$PIDS1" | wc -w)" = 2 ] && ok || bad "C1 the build must start 2 detached sleeps while it runs: '$PIDS1'"
  [ "$(uploads)" = 1 ] && ok || bad "C1 one pages deploy: $(uploads) $(cat "$T/out")"
  alive=""; for p in $PIDS1; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
  [ -z "$alive" ] && ok || bad "C1 detached build processes outlived the lane's build step: pid$alive"
  [ -z "$(survivors)" ] && ok || bad "C1 no $NAME- process may be alive after the lane: '$(survivors)'"
fi

# ── C2: a build that times out leaves nothing alive ──────────────────────────
if pidns_case C2; then
  reset
  SECONDS=0
  ( CONSOLE_PREVIEW_BUILD_USER=self HARNESS_TEST_SANDBOX=1 CPV_TEST_UID="$U" lib "$T/c2.out" "" 2 bash -c "bash '$T/detach.sh'; sleep 60" ) & LP=$!
  wait_started || bad "C2 the build never started"
  sleep 0.3
  PIDS2=$(survivors)
  wait "$LP"; RC=$?; took=$SECONDS
  [ "$RC" = 124 ] && ok || bad "C2 a build over its timeout returns 124: rc=$RC $(cat "$T/c2.out")"
  [ "$took" -lt 20 ] && ok || bad "C2 the timeout must end the build fast: ${took}s"
  [ "$(echo "$PIDS2" | wc -w)" = 2 ] && ok || bad "C2 the build must start 2 detached sleeps: '$PIDS2'"
  alive=""; for p in $PIDS2; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
  [ -z "$alive" ] && ok || bad "C2 a timed-out build left pid$alive alive"
  [ -z "$(pgrep -u "$U"; pgrep -U "$U")" ] && ok || bad "C2 the build uid $U has a live process"
fi

# ── C3: a live build-user process before the build: nothing builds ───────────
reset
if [ "$ROOT" = 1 ]; then
  setpriv --reuid="$U" --regid="$U" --clear-groups bash -c "exec -a $NAME-p sleep 300" </dev/null >/dev/null 2>&1 &
  PLANT=$!; disown "$PLANT"; PLANTS+=("$PLANT"); XP=""
  for _ in $(seq 1 50); do [ -n "$(pgrep -u "$U")" ] && break; sleep 0.1; done
else
  PLANT=4242; echo 4242 > "$T/pg.pids"; XP="$T/pg"
fi
lane "$XP"; RC=$?
[ "$(grep -c '^npm ' "$T/calls.log")" = 0 ] && ok || bad "C3 nothing may build while uid $U has a live process: $(grep '^npm ' "$T/calls.log" | tr '\n' ';')"
nl=$(grep -c "build not isolated: cpv_run_unpriv: build user 'self' (uid $U) has 1 live process(es) (pid $PLANT)" "$T/out")
[ "$nl" = 1 ] && ok || bad "C3 one lane line names the user, uid $U and pid $PLANT: $nl lines; $(cat "$T/out")"
[ "$(alerts)" = 1 ] && ok || bad "C3 one console-preview-box alert: $(alerts)"
[ -z "$(rec "$S11")" ] && ok || bad "C3 a box condition charges no head: '$(rec "$S11")'"
[ ! -e "$T/posted-11" ] && ok || bad "C3 no comment: $(cat "$T/posted-11")"
[ "$RC" = 0 ] && ok || bad "C3 lane rc=$RC"
cleanup_procs; PLANTS=()

# ── C4: a build-user process alive after the build: the output is not used ───
reset
( CONSOLE_PREVIEW_BUILD_USER=self HARNESS_TEST_SANDBOX=1 CPV_TEST_UID="$U" lib "$T/c4.out" "$T/pg" 10 bash -c "touch '$T/pg.after'" ); RC=$?
[ "$RC" = 125 ] && ok || bad "C4 lib: a live build-uid process after the run is rc 125: rc=$RC $(cat "$T/c4.out")"
grep -q "build user 'self' (uid $U) still has 1 process(es) after the build (pid 4243)" "$T/c4.out" 2>/dev/null && ok \
  || bad "C4 lib: the reason names the leftover pid: $(cat "$T/c4.out")"
reset; touch "$T/arm-post"
lane "$T/pg"
[ "$(grep -c '^npm run build' "$T/calls.log")" = 1 ] && ok || bad "C4 lane: the build ran once: $(grep '^npm' "$T/calls.log" | tr '\n' ';')"
[ "$(uploads)" = 0 ] && ok || bad "C4 lane: no pages deploy of a build the user may still write: $(uploads)"
grep -q 'cpv_copy_dist' "$T/out" && bad "C4 lane: dist was copied: $(grep cpv_copy_dist "$T/out")" || ok
grep -q "build not isolated: cpv_run_unpriv: build user 'self' (uid $U) still has 1 process(es) after the build" "$T/out" && ok \
  || bad "C4 lane: the box line for the build step: $(cat "$T/out")"
[ "$(alerts)" = 1 ] && ok || bad "C4 lane: one console-preview-box alert: $(alerts)"
[ -z "$(rec "$S11")" ] && ok || bad "C4 lane: no failed record for the head: '$(rec "$S11")'"
grep -q 'vite build failed' "$T/out" && bad "C4 lane: a box fault is not a vite build failure: $(grep 'vite build failed' "$T/out")" || ok

# ── C5: a real build user and no PID namespace: nothing runs ─────────────────
reset
if [ "$ROOT" = 1 ]; then
  ( unset HARNESS_TEST_SANDBOX; CONSOLE_PREVIEW_BUILD_USER=nobody lib "$T/c5.out" "$T/nons" 10 touch ran ); RC=$?
  [ "$RC" = 125 ] && ok || bad "C5 no PID namespace for a real build user is rc 125: rc=$RC $(cat "$T/c5.out")"
  grep -q 'cannot start a PID namespace' "$T/c5.out" && ok || bad "C5 the reason: $(cat "$T/c5.out")"
  [ ! -e "$T/lb/w/ran" ] && ok || bad "C5 the command ran without isolation"
else
  skip "C5: needs root (a real build user)"
fi

# ── C6: six live pids — the count is 6, the list is the first 5 ──────────────
reset; printf '%s\n' 4301 4302 4303 4304 4305 4306 > "$T/pg.pids"
( CONSOLE_PREVIEW_BUILD_USER=self HARNESS_TEST_SANDBOX=1 CPV_TEST_UID="$U" lib "$T/c6.out" "$T/pg" 10 touch ran ); RC=$?
[ "$RC" = 125 ] && ok || bad "C6 rc=$RC $(cat "$T/c6.out")"
grep -qF "has 6 live process(es) (pid 4301 4302 4303 4304 4305)" "$T/c6.out" && ok || bad "C6 count 6, first 5 pids: $(cat "$T/c6.out")"
grep -q 4306 "$T/c6.out" && bad "C6 the 6th pid is not listed: $(cat "$T/c6.out")" || ok
[ ! -e "$T/lb/w/ran" ] && ok || bad "C6 the command ran"

# ── C7: CPV_TEST_UID does not move a real build user's check ─────────────────
reset
NB=$(id -u nobody 2>/dev/null)
if [ "$ROOT" != 1 ] || [ -z "$NB" ]; then
  skip "C7: needs root and a nobody user"
elif [ -n "$(pgrep -u "$NB"; pgrep -U "$NB")" ]; then
  skip "C7: nobody (uid $NB) already has live processes on $(hostname)"
elif ! { C7R="$T/c7r" && mkdir -p "$C7R" && chmod 755 "$C7R"; }; then
  bad "C7: mkdir $T/c7r failed on $(hostname)"; rm_c7r
elif ! setpriv --reuid="$NB" --regid="$(id -g nobody)" --clear-groups test -x "$C7R"; then
  skip "C7: nobody (uid $NB) cannot traverse $C7R on $(hostname)"; rm_c7r
else
  setpriv --reuid="$U" --regid="$U" --clear-groups bash -c "exec -a $NAME-q sleep 300" </dev/null >/dev/null 2>&1 &
  PLANTS+=("$!"); disown "$!"
  for _ in $(seq 1 50); do [ -n "$(pgrep -u "$U")" ] && break; sleep 0.1; done
  ( unset HARNESS_TEST_SANDBOX; CONSOLE_PREVIEW_BUILD_USER=nobody CPV_TEST_UID="$U" LB="$C7R/lb" lib "$T/c7.out" "$T/passns" 10 touch ran ); RC=$?
  [ "$RC" = 0 ] && [ -e "$C7R/lb/w/ran" ] && ok || bad "C7 a busy CPV_TEST_UID must not refuse a nobody build: rc=$RC $(cat "$T/c7.out")"
  setpriv --reuid="$NB" --regid="$(id -g nobody)" --clear-groups bash -c "exec -a $NAME-r sleep 300" </dev/null >/dev/null 2>&1 &
  PLANTS+=("$!"); disown "$!"
  for _ in $(seq 1 50); do [ -n "$(pgrep -u "$NB")" ] && break; sleep 0.1; done
  ( unset HARNESS_TEST_SANDBOX; CONSOLE_PREVIEW_BUILD_USER=nobody CPV_TEST_UID="$U" LB="$C7R/lb" lib "$T/c7.out" "$T/passns" 10 touch ran ); RC=$?
  [ "$RC" = 125 ] && grep -q "build user 'nobody' (uid $NB) has 1 live process" "$T/c7.out" && ok \
    || bad "C7 the nobody build is checked by uid $NB: rc=$RC $(cat "$T/c7.out")"
  cleanup_procs; PLANTS=(); rm_c7r
fi

# ── C8: self mode with no PID namespace runs and says so ─────────────────────
reset
( CONSOLE_PREVIEW_BUILD_USER=self HARNESS_TEST_SANDBOX=1 lib "$T/c8.out" "$T/nons" 10 touch ran ); RC=$?
[ "$RC" = 0 ] && [ -e "$T/lb/w/ran" ] && ok || bad "C8 self mode with no namespace still runs: rc=$RC $(cat "$T/c8.out")"
grep -q 'self mode without a PID namespace (test sandbox)' "$T/c8.out" && ok || bad "C8 stderr names the fallback: $(cat "$T/c8.out")"

# ── C9: a build that exits 125 is charged to the head ───────────────────────
reset
( CONSOLE_PREVIEW_BUILD_USER=self HARNESS_TEST_SANDBOX=1 CPV_TEST_UID="$U" lib "$T/c9.out" "" 10 bash -c 'exit 125' ); RC=$?
[ "$RC" = 1 ] && ok || bad "C9 lib: a command rc 125 is returned as 1, not as the box-fault 125: rc=$RC $(cat "$T/c9.out")"
reset; touch "$T/exit125"
lane; RC=$?
[ "$(grep -c '^npm run build' "$T/calls.log")" = 1 ] && ok || bad "C9 lane: the build ran once: $(grep '^npm' "$T/calls.log" | tr '\n' ';')"
grep -q '#11 vite build failed' "$T/out" && ok || bad "C9 lane: a build rc 125 is a vite build failure: $(cat "$T/out")"
grep -q 'build not isolated' "$T/out" && bad "C9 lane: a head rc 125 is not a box line: $(grep 'build not isolated' "$T/out")" || ok
[ "$(alerts)" = 0 ] && ok || bad "C9 lane: no console-preview-box alert for the head's own rc: $(alerts)"
[ "$(rec "$S11")" = "failed 1" ] && ok || bad "C9 lane: the head is charged: '$(rec "$S11")'"
[ "$(uploads)" = 0 ] && ok || bad "C9 lane: no pages deploy: $(uploads)"
[ "$RC" = 0 ] && ok || bad "C9 lane rc=$RC"

echo "console-preview-build-iso.bh-6073: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
