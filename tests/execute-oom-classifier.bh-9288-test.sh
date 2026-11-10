#!/bin/bash
# tests/execute-oom-classifier.bh-9288-test.sh — BH-9288: an out-of-memory
# stop (exit 137) records the processes that were alive, says whether the
# cause was concurrent processes or one large process, and the execute stage
# kills the process groups its session left behind.
#
# THE INCIDENT (project-6-os TK-3659, 2026-11-09). The execute session started
# two vitest suites in the background and then ran the typecheck. The machine
# ran out of memory and the typecheck was killed (exit 137) twice. The stop
# reason said "Raise the row lane.fly-pool.project-6-os.vm_memory_mb", but the
# memory went to the concurrent processes, and the vitest workers lived on.
#
# Driven, not grepped:
#   A  ep_snapshot (the REAL bin/lib/exec-procs.sh) over a fake `ps` listing:
#      header, sort, row cap, the caller's own ancestors left out, scrub.
#   B  ep_oom_cause: the decision table (concurrent / single / no-snapshot /
#      unknown) with its near misses.
#   C  ep_reap on REAL local processes: a tagged stub that starts 3 children
#      (one under setsid) leaves none alive; untagged, other-tag and
#      prefix-tag processes live; --strays keeps postgres and the session's
#      own children.
#   D  the REAL bin/exec-proc-hook.sh with hook payloads: 137 writes the
#      snapshot before it reaps; a timeout reaps a stray vitest; green and
#      non-Bash payloads do nothing; it prints nothing and exits 0.
#   E  the settings merge block of the REAL bin/agent-call.sh keeps every
#      hook entry (edit-feedback, a SessionStart file, the proc hook, the
#      iron-law guard).
#   F  ee_on_empty (the REAL bin/lib/execute-empty.sh) with the TK-3659
#      transcript: the stop reason names the cause from oom-procs.txt.
#   G  knob overrides change the outcome.
#   Z  no network stub was called.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/execute-oom-classifier.bh-9288-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
LIB_EP="$DIR/bin/lib/exec-procs.sh"
LIB_EE="$DIR/bin/lib/execute-empty.sh"
HOOK="$DIR/bin/exec-proc-hook.sh"
FX="$DIR/tests/fixtures/execute-oom.bh-9288"
RUNID="bh9288-exec-oom-$$"

# Network stubs: any call is a vendor call in a PR-path suite (BH-7563 item 6).
mkdir -p "$T/stubbin"
for c in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 7\n' "$c" "$T/net.log" > "$T/stubbin/$c"
  chmod +x "$T/stubbin/$c"
done
export PATH="$T/stubbin:$PATH"

# The scratch hub: the real render and scrub, a fake alert writer. No lane
# registry, so the knobs come from the environment (then the code fallback).
H="$T/h"; mkdir -p "$H/bin/lib" "$H/builds" "$H/logs"
ln -s "$DIR/bin/transcript-render.sh" "$H/bin/transcript-render.sh"
ln -s "$DIR/bin/transcript-scrub.sh" "$H/bin/transcript-scrub.sh"
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
chmod +x "$H/bin/alert-line.sh"
NOREG="$T/no-registry.json"

# Every process this suite starts is killed at the end, whatever happened.
PIDS_FILE="$T/started.pids"; : > "$PIDS_FILE"
cleanup_procs() {
  local p
  while read -r p; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done < "$PIDS_FILE"
  pkill -KILL -f "$RUNID" 2>/dev/null
  return 0
}
# alive <pid> -> rc 0 when the pid runs (a zombie is not alive)
alive() {
  local st
  [ -r "/proc/$1/stat" ] || return 1
  st=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  st=${st##*) }; st=${st%% *}
  [ "$st" != Z ] && [ "$st" != X ]
}
# waitfile <file> <lines> -> wait (max ~5 s) until the file has that many lines
waitfile() {
  local i
  for i in $(seq 50); do
    [ "$(grep -c . "$1" 2>/dev/null)" -ge "$2" ] 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

# epx [VAR=value ...] -- <function> <args...> : the REAL lib in a clean shell.
epx() {
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  env LANE_REGISTRY="$NOREG" HARNESS="$H" ${envs[@]+"${envs[@]}"} \
    bash -c '. "$0" || exit 9; "$@"' "$LIB_EP" "$@"
}
[ -r "$LIB_EP" ] && ok || bad "bin/lib/exec-procs.sh is missing"

# ═════ A: ep_snapshot over a fake ps listing ════════════════════════════════
# The chain 500 (the caller) -> 400 (the claude CLI, node, 400 MB) -> 300 -> 1
# is the caller's own ancestry and stays out of the snapshot.
# The fake token is built at run time so that no token-shaped literal is in
# this file (the share-mirror leakcheck refuses one).
FAKE_TOKEN="ghp""_abcdefghijklmnopqrstuvwxyz0123456789"
cat > "$T/fake-ps.sh" <<SH
#!/bin/bash
cat <<'PS'
    1     0   9000 init            /sbin/init
  300     1   4000 bash            bash run-build.sh
  400   300 409600 node            node /usr/bin/claude -p
  500   400   3000 bash            bash /root/harness/bin/exec-proc-hook.sh
 4101     1 7987200 node           node /repo/node_modules/typescript/bin/tsc --noEmit
 4210     1 1126400 node           node /repo/node_modules/vitest/dist/workers/forks.js --token=$FAKE_TOKEN
 4211     1 921600 node            node /repo/node_modules/vitest/dist/workers/forks.js
 3050     1  61440 postgres        postgres -D /var/lib/postgresql/data
PS
SH
chmod +x "$T/fake-ps.sh"
printf 'MemTotal:       33554432 kB\nMemFree: 1 kB\n' > "$T/meminfo"
SNAP="$T/snap-a.txt"
epx EP_PS_CMD="$T/fake-ps.sh" EP_SELF_PID=500 EE_MEMINFO="$T/meminfo" -- ep_snapshot "$SNAP" "Exit code 137"; RC=$?
[ "$RC" = 0 ] && ok || bad "A1 ep_snapshot rc $RC"
case "$(head -1 "$SNAP" 2>/dev/null)" in
  "# oom-procs v1 at="*" mem_total_kb=33554432 signal=Exit code 137") ok ;;
  *) bad "A1 header: $(head -1 "$SNAP" 2>/dev/null)" ;;
esac
[ "$(sed -n 2p "$SNAP" | cut -f1)" = 4101 ] && ok || bad "A2 the largest process first: $(sed -n 2p "$SNAP")"
[ "$(sed -n 2p "$SNAP" | cut -f2)" = 7987200 ] && ok || bad "A2 rss_kb column: $(sed -n 2p "$SNAP")"
[ "$(sed -n 2p "$SNAP" | cut -f3)" = node ] && ok || bad "A2 comm column: $(sed -n 2p "$SNAP")"
grep -q '/tsc --noEmit' <(sed -n 2p "$SNAP" | cut -f4) && ok || bad "A2 args column: $(sed -n 2p "$SNAP")"
grep -qx -e 400 -e 500 -e 300 <<<"$(cut -f1 "$SNAP")" && bad "A3 the caller's ancestors (claude CLI 400) are in the snapshot" || ok
grep -qF "$FAKE_TOKEN" "$SNAP" && bad "A4 a token in the args was not scrubbed" || ok
grep -q 'REDACTED' "$SNAP" && ok || bad "A4 the scrub left no mark"
[ "$(grep -vc '^#' "$SNAP")" = 4 ] && ok || bad "A5 want 4 rows (tsc, 2 vitest, postgres; init is an ancestor too), got $(grep -vc '^#' "$SNAP")"
SNAP2="$T/snap-a2.txt"
epx EP_PS_CMD="$T/fake-ps.sh" EP_SELF_PID=500 EE_MEMINFO="$T/meminfo" EXEC_OOM_SNAPSHOT_ROWS=2 -- ep_snapshot "$SNAP2" "Exit code 137"
[ "$(grep -vc '^#' "$SNAP2")" = 2 ] && ok || bad "A6 EXEC_OOM_SNAPSHOT_ROWS=2 keeps 2 rows, got $(grep -vc '^#' "$SNAP2")"
SNAP3="$T/snap-a3.txt"
epx EP_PS_CMD="$T/fake-ps.sh" EP_SELF_PID=500 EE_MEMINFO="$T/meminfo" EP_SCRUB="$T/no-such-scrub.sh" -- ep_snapshot "$SNAP3" "Exit code 137"; RC=$?
[ "$RC" = 0 ] && ok || bad "A7 a failed scrub must not fail the caller (rc $RC)"
[ "$(grep -vc '^#' "$SNAP3")" = 0 ] && ok || bad "A7 a failed scrub writes no rows (fail-closed)"
grep -q '^# rows withheld: scrub failed' "$SNAP3" && ok || bad "A7 a failed scrub says so"
[ ! -e "$T/no-dir/x.txt" ] && epx EP_PS_CMD="$T/fake-ps.sh" -- ep_snapshot "$T/no-dir/x.txt" sig; RC=$?
[ "$RC" = 0 ] && ok || bad "A8 an unwritable dest must not fail the caller (rc $RC)"

# ═════ B: ep_oom_cause, the decision table ══════════════════════════════════
# mk <file> <mem_kb> [pid rss_kb comm args]... (one row per 4 arguments)
mk() {
  local f="$1" m="$2"; shift 2
  printf '# oom-procs v1 at=1793750000 mem_total_kb=%s signal=Exit code 137\n' "$m" > "$f"
  while [ "$#" -ge 4 ]; do printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$f"; shift 4; done
}
cause() { epx PROJECT=project-6-os -- ep_oom_cause "$@" | cut -f1; }
sentence() { epx PROJECT=project-6-os -- ep_oom_cause "$@" | cut -f2-; }
G32=33554432; G16=16777216; FLOOR=204800  # 32 GB, 16 GB, 200 MB in kB
[ "$(cause "$FX/mk3659-procs.txt" 32768)" = concurrent ] && ok || bad "B1 TK-3659 (3 heavy, none dominant) -> concurrent, got $(cause "$FX/mk3659-procs.txt" 32768)"
S=$(sentence "$FX/mk3659-procs.txt" 32768)
grep -q '3 heavy' <<<"$S" && grep -q 'tsc' <<<"$S" && grep -q 'vitest' <<<"$S" && ok || bad "B1 sentence names 3 heavy, tsc, vitest: $S"
grep -q 'one heavy check at a time' <<<"$S" && ok || bad "B1 sentence says one heavy check at a time: $S"
mk "$T/b2" $G32 1 $FLOOR node "node vitest" 2 $FLOOR node "node vitest"
[ "$(cause "$T/b2" 32768)" = concurrent ] && ok || bad "B2 2 heavy at exactly the RSS floor -> concurrent, got $(cause "$T/b2" 32768)"
mk "$T/b3" $G32 1 1048576 node "node tsc" 2 $((FLOOR-1)) node "node vitest" 3 $((FLOOR-1)) node "node vitest" 4 $((FLOOR-1)) node "node vitest" 5 $((FLOOR-1)) node "node vitest"
[ "$(cause "$T/b3" 32768)" != concurrent ] && ok || bad "B3 1 heavy + 4 under the floor is not concurrent"
mk "$T/b4" $G32 1 9000000 java "java -jar x.jar" 2 9000000 python3 "python3 x.py"
[ "$(cause "$T/b4" 32768)" != concurrent ] && ok || bad "B4 2 large non-node processes are not heavy test processes"
[ "$(cause "$FX/single-90pct-procs.txt" 16384)" = single ] && ok || bad "B5 one process at 90% -> single, got $(cause "$FX/single-90pct-procs.txt" 16384)"
S=$(sentence "$FX/single-90pct-procs.txt" 16384)
grep -q 'Raise the row lane.fly-pool.project-6-os.vm_memory_mb' <<<"$S" && ok || bad "B5 single says raise the row: $S"
mk "$T/b6" $G16 1 $((G16/2)) node "node tsc"
[ "$(cause "$T/b6" 16384)" = single ] && ok || bad "B6 exactly 50% -> single, got $(cause "$T/b6" 16384)"
mk "$T/b7" $G16 1 $((G16*49/100)) node "node tsc" 2 307200 node "node vitest"
[ "$(cause "$T/b7" 16384)" = concurrent ] && ok || bad "B7 49% with 2 heavy -> concurrent, got $(cause "$T/b7" 16384)"
mk "$T/b8" $G16 1 $((G16/10)) bash "bash x"
[ "$(cause "$T/b8" 16384)" = single ] && ok || bad "B8 survivors total 10% -> single (the killed command used most), got $(cause "$T/b8" 16384)"
[ "$(cause "$T/missing.txt" 16384)" = no-snapshot ] && ok || bad "B9 missing file -> no-snapshot"
: > "$T/b9e"; [ "$(cause "$T/b9e" 16384)" = no-snapshot ] && ok || bad "B9 empty file -> no-snapshot"
mk "$T/b9h" $G16; echo '# rows withheld: scrub failed' >> "$T/b9h"
[ "$(cause "$T/b9h" 16384)" = no-snapshot ] && ok || bad "B9 header only -> no-snapshot"
printf 'garbage\nmore garbage here\n1 2 3\n' > "$T/b9g"
[ "$(cause "$T/b9g" 16384)" = no-snapshot ] && ok || bad "B9 garbage -> no-snapshot, got $(cause "$T/b9g" 16384)"
S=$(sentence "$T/missing.txt" 16384)
grep -q 'Cause unknown, no snapshot' <<<"$S" && ok || bad "B9 no-snapshot sentence: $S"
mk "$T/b10" $G16 1 $((G16*30/100)) node "node tsc" 2 $((G16*30/100)) java "java -jar x"
[ "$(cause "$T/b10" 16384)" = unknown ] && ok || bad "B10 1 heavy at 30%, survivors 60% -> unknown, got $(cause "$T/b10" 16384)"
mk "$T/b11" 0 1 1000 bash "bash x"
[ "$(cause "$T/b11" unknown)" = unknown ] && ok || bad "B11 memory unknown -> unknown, never single by inference, got $(cause "$T/b11" unknown)"
mk "$T/b12" 0 1 $FLOOR node "node vitest" 2 $FLOOR node "node tsc"
[ "$(cause "$T/b12" unknown)" = concurrent ] && ok || bad "B12 memory unknown with 2 heavy -> concurrent, got $(cause "$T/b12" unknown)"
mk "$T/b13" 0 1 $((G16*9/10)) node "node tsc"
[ "$(cause "$T/b13" 16384)" = single ] && ok || bad "B13 header memory 0: the argument memory decides, got $(cause "$T/b13" 16384)"

# ═════ C: ep_reap on real processes ═════════════════════════════════════════
TAG="$RUNID-c"
# stub_session <tag> <pidfile>: a tagged bash backgrounds a command that starts
# 3 children, one of them under setsid. Every child pid goes to <pidfile>.
# The setsid child double-forks a grandchild: re-parented, so not a descendant
# of any target, it dies only if its whole process GROUP is signalled.
stub_session() {
  env HARNESS_EXEC_TAG="$1" RUNID="$RUNID" PF="$2" bash -c '
    ( sleep 300 & echo $! >> "$PF"
      setsid bash -c "echo \$\$ >> \"$PF\"; (sleep 300 & echo \$! >> \"$PF\"); exec sleep 300" &
      sleep 300 & echo $! >> "$PF"
      wait ) &
    wait' &
  echo $! >> "$PIDS_FILE"
}
stub_session "$TAG" "$T/c.pids"
waitfile "$T/c.pids" 4 && ok || bad "C0 the stub did not start 3 children (and the setsid one's own child)"
cat "$T/c.pids" >> "$PIDS_FILE"
env HARNESS_EXEC_TAG="$TAG" bash -c 'sleep 300 & echo $! > "$0"; wait' "$T/c-parent.pid" &
echo $! >> "$PIDS_FILE"
sleep 300 & UNTAGGED=$!; echo $UNTAGGED >> "$PIDS_FILE"
env HARNESS_EXEC_TAG="$RUNID-other" sleep 300 & OTHER=$!; echo $OTHER >> "$PIDS_FILE"
env HARNESS_EXEC_TAG="${TAG}x" sleep 300 & PREFIX=$!; echo $PREFIX >> "$PIDS_FILE"
waitfile "$T/c-parent.pid" 1
sleep 0.3
for p in $(cat "$T/c.pids"); do alive "$p" && ok || bad "C0 child $p is not running before the reap"; done
ERR=$(epx EXEC_PROC_REAP_GRACE_S=2 -- ep_reap "$TAG" 2>&1 >/dev/null); RC=$?
[ "$RC" = 0 ] && ok || bad "C1 ep_reap rc $RC"
for p in $(cat "$T/c.pids") $(cat "$T/c-parent.pid"); do
  alive "$p" && bad "C1 tagged child $p is still alive after ep_reap" || ok
done
alive "$UNTAGGED" && ok || bad "C2 an untagged sleep was killed"
alive "$OTHER" && ok || bad "C2 another build's tag was killed"
alive "$PREFIX" && ok || bad "C2 a tag prefix match (${TAG}x) was killed"
case "$ERR" in *"reaped "*" group(s), "*" process(es)"*) ok ;; *) bad "C3 the stderr line: $ERR" ;; esac
N=$(sed -nE 's/.*group\(s\), ([0-9]+) process\(es\).*/\1/p' <<<"$ERR")
[ "${N:-0}" -ge 4 ] && ok || bad "C3 the count names at least the 4 tagged sleeps: $ERR"
ERR=$(epx -- ep_reap "" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C4 an empty tag is a no-op with rc 0 (rc $RC)"
alive "$UNTAGGED" && ok || bad "C4 an empty tag killed an untagged process"

# --strays <claude-pid>: only orphaned test runners. The fake claude is a
# tagged bash with a vitest-named child of its own.
TAG2="$RUNID-s"
env HARNESS_EXEC_TAG="$TAG2" bash -c '(exec -a vitest sleep 301) & echo $! > "$0"; echo $$ > "$1"; wait' "$T/s-own.pid" "$T/s-claude.pid" &
echo $! >> "$PIDS_FILE"
env HARNESS_EXEC_TAG="$TAG2" bash -c '( (exec -a vitest sleep 302) & echo $! > "$0" )' "$T/s-stray.pid"
env HARNESS_EXEC_TAG="$TAG2" bash -c '( (exec -a postgres sleep 303) & echo $! > "$0" )' "$T/s-pg.pid"
waitfile "$T/s-own.pid" 1; waitfile "$T/s-claude.pid" 1; waitfile "$T/s-stray.pid" 1; waitfile "$T/s-pg.pid" 1
cat "$T/s-own.pid" "$T/s-stray.pid" "$T/s-pg.pid" >> "$PIDS_FILE"
sleep 0.3
alive "$(cat "$T/s-stray.pid")" && ok || bad "C5 the stray vitest is not running before the reap"
epx EXEC_PROC_REAP_GRACE_S=2 -- ep_reap "$TAG2" --strays "$(cat "$T/s-claude.pid")" 2>/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "C5 ep_reap --strays rc $RC"
alive "$(cat "$T/s-stray.pid")" && bad "C5 the orphaned vitest is still alive after --strays" || ok
alive "$(cat "$T/s-pg.pid")" && ok || bad "C6 --strays killed a tagged postgres orphan"
alive "$(cat "$T/s-own.pid")" && ok || bad "C6 --strays killed a child of the claude pid"
alive "$(cat "$T/s-claude.pid")" && ok || bad "C6 --strays killed the claude pid"
epx EXEC_PROC_REAP_GRACE_S=2 -- ep_reap "$TAG2" 2>/dev/null
for f in s-own s-pg s-claude; do alive "$(cat "$T/$f.pid")" && bad "C7 stage-end reap left $f alive" || ok; done

# ═════ D: the hook ══════════════════════════════════════════════════════════
[ -x "$HOOK" ] && ok || bad "D0 bin/exec-proc-hook.sh is missing or not executable"
# A fake ps that records whether the stray vitest was still alive when the
# snapshot ran: the snapshot must come BEFORE any reap.
cat > "$T/fake-ps-d.sh" <<'SH'
#!/bin/bash
p=$(cat "$STRAY_PIDFILE" 2>/dev/null)
st=""; [ -n "$p" ] && st=$(cat "/proc/$p/stat" 2>/dev/null) && st=${st##*) } && st=${st%% *}
case "$st" in ''|Z|X) echo dead > "$SNAP_SEEN" ;; *) echo alive > "$SNAP_SEEN" ;; esac
printf ' 4101 1 7987200 node node /repo/node_modules/typescript/bin/tsc --noEmit\n 4210 1 1126400 node node /repo/node_modules/vitest/dist/workers/forks.js\n 4211 1 921600 node node /repo/node_modules/vitest/dist/workers/forks.js\n'
SH
chmod +x "$T/fake-ps-d.sh"
# run_hook <payload> <tag> <procdir>: the hook under a tagged fake claude.
run_hook() {
  env HARNESS_EXEC_TAG="$2" EXEC_PROC_DIR="$3" LANE_REGISTRY="$NOREG" HARNESS="$H" EXEC_PROC_REAP_GRACE_S=2 \
      EP_PS_CMD="$T/fake-ps-d.sh" STRAY_PIDFILE="$T/d-stray.pid" SNAP_SEEN="$T/d-seen" EE_MEMINFO="$T/meminfo" \
    bash -c '"$0" < "$1" > "$2" 2>&1; echo $? > "$3"' "$HOOK" "$1" "$T/d-out" "$T/d-rc"
}
d_stray() { rm -f "$T/d-stray.pid"
  env HARNESS_EXEC_TAG="$1" bash -c '( (exec -a vitest sleep 304) & echo $! > "$0" )' "$T/d-stray.pid"
  waitfile "$T/d-stray.pid" 1; cat "$T/d-stray.pid" >> "$PIDS_FILE"; sleep 0.2; }
TAGD="$RUNID-d"; PD="$T/procdir"; mkdir -p "$PD"
d_stray "$TAGD"; rm -f "$T/d-seen"
run_hook "$FX/hook-137.json" "$TAGD" "$PD"
[ "$(cat "$T/d-rc")" = 0 ] && ok || bad "D1 hook rc $(cat "$T/d-rc")"
[ ! -s "$T/d-out" ] && ok || bad "D1 the hook printed text: $(head -c 200 "$T/d-out")"
[ -s "$PD/oom-procs.txt" ] && ok || bad "D1 hook-137 wrote no oom-procs.txt"
grep -q 'signal=Exit code 137' "$PD/oom-procs.txt" 2>/dev/null && ok || bad "D1 header names the signal: $(head -1 "$PD/oom-procs.txt" 2>/dev/null)"
[ "$(cat "$T/d-seen" 2>/dev/null)" = alive ] && ok || bad "D2 the snapshot ran after the reap (seen: $(cat "$T/d-seen" 2>/dev/null))"
alive "$(cat "$T/d-stray.pid")" && bad "D2 an OOM did not reap the stray vitest" || ok
[ "$(epx -- ep_oom_cause "$PD/oom-procs.txt" 32768 | cut -f1)" = concurrent ] && ok || bad "D3 round trip: the hook's snapshot classifies as concurrent"

rm -f "$PD/oom-procs.txt"; d_stray "$TAGD"
run_hook "$FX/hook-timeout.json" "$TAGD" "$PD"
[ "$(cat "$T/d-rc")" = 0 ] && ok || bad "D4 hook rc $(cat "$T/d-rc")"
[ ! -e "$PD/oom-procs.txt" ] && ok || bad "D4 a timeout is not an OOM: no snapshot"
alive "$(cat "$T/d-stray.pid")" && bad "D4 a timed-out call did not reap the stray vitest" || ok
jq '.error = null | .tool_response = {stdout:"", stderr:"", interrupted:true}' "$FX/hook-timeout.json" > "$T/hook-int.json"
d_stray "$TAGD"; run_hook "$T/hook-int.json" "$TAGD" "$PD"
alive "$(cat "$T/d-stray.pid")" && bad "D4 an interrupted call did not reap the stray vitest" || ok

d_stray "$TAGD"
run_hook "$FX/hook-green.json" "$TAGD" "$PD"
[ "$(cat "$T/d-rc")" = 0 ] && ok || bad "D5 hook rc $(cat "$T/d-rc")"
[ ! -e "$PD/oom-procs.txt" ] && ok || bad "D5 a green payload wrote a snapshot"
alive "$(cat "$T/d-stray.pid")" && ok || bad "D5 a green payload reaped a process"
jq '.error = "Exit code 1370"' "$FX/hook-137.json" > "$T/hook-1370.json"
run_hook "$T/hook-1370.json" "$TAGD" "$PD"
[ ! -e "$PD/oom-procs.txt" ] && ok || bad "D6 'Exit code 1370' is not an OOM"
jq '.tool_name = "Read"' "$FX/hook-137.json" > "$T/hook-read.json"
run_hook "$T/hook-read.json" "$TAGD" "$PD"
[ ! -e "$PD/oom-procs.txt" ] && ok || bad "D6 a Read payload wrote a snapshot"
jq '.error = null | .tool_response = {stdout:"grep found: heap out of memory", stderr:""} | .tool_input.command = "grep -rn heap logs/"' "$FX/hook-137.json" > "$T/hook-v8.json"
run_hook "$T/hook-v8.json" "$TAGD" "$PD"
[ -s "$PD/oom-procs.txt" ] && ok || bad "D7 'heap out of memory' in the response is an OOM signature"
rm -f "$PD/oom-procs.txt"; d_stray "$TAGD"
run_hook "$FX/hook-137.json" "" "$PD"
[ ! -e "$PD/oom-procs.txt" ] && ok || bad "D8 no HARNESS_EXEC_TAG: the hook does nothing"
alive "$(cat "$T/d-stray.pid")" && ok || bad "D8 no tag: the hook reaped a process"
printf 'not json' > "$T/hook-bad.json"; run_hook "$T/hook-bad.json" "$TAGD" "$PD"
[ "$(cat "$T/d-rc")" = 0 ] && [ ! -s "$T/d-out" ] && ok || bad "D9 bad JSON: rc 0 and no output"

# ═════ E: the settings merge of bin/agent-call.sh ═══════════════════════════
awk 'index($0,"# >>> exec proc hook")>0{f=1;next} index($0,"# <<< exec proc hook")>0{f=0} f' "$DIR/bin/agent-call.sh" > "$T/eph.sh"
awk 'index($0,"# >>> settings merge")>0{f=1;next} index($0,"# <<< settings merge")>0{f=0} f' "$DIR/bin/agent-call.sh" > "$T/merge.sh"
[ -s "$T/eph.sh" ] && ok || bad "E0 no '# >>> exec proc hook' block in bin/agent-call.sh"
[ -s "$T/merge.sh" ] && ok || bad "E0 no '# >>> settings merge' block in bin/agent-call.sh"
EH="$T/eh"; mkdir -p "$EH/bin" "$EH/state"
ln -s "$HOOK" "$EH/bin/exec-proc-hook.sh"
printf '{"hooks":{"SessionStart":[{"matcher":"compact","hooks":[{"type":"command","command":"/x/cr.sh"}]}]}}\n' > "$T/cr.json"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/x/iron-law-guard.sh","timeout":30}]}]},"permissions":{"deny":["x"]}}\n' > "$T/guard.json"
E_OUT=$(
  HARNESS="$EH" STAGE=execute PROJECT=p EXEC_PROC_TAG="$RUNID-e" LANE_REGISTRY="$NOREG" ALERTS="$T/e-alerts.log"
  STAMP() { echo t; }
  # shellcheck disable=SC2034
  _sets=("$DIR/bin/edit-feedback-settings.json" "$T/cr.json"); _settings=""; SP_ENV=(); _eph=""; _ephto=""
  # shellcheck disable=SC1090
  . "$T/eph.sh"
  _sets+=("$T/guard.json")
  # shellcheck disable=SC1090
  . "$T/merge.sh"
  printf '%s\n%s\n' "$_settings" "${SP_ENV[*]}"
)
E_SET=$(sed -n 1p <<<"$E_OUT"); E_ENV=$(sed -n 2p <<<"$E_OUT")
[ "$E_ENV" = "HARNESS_EXEC_TAG=$RUNID-e" ] && ok || bad "E1 SP_ENV carries the tag: $E_ENV"
[ -s "$E_SET" ] && ok || bad "E2 no merged settings file: $E_SET"
[ "$(jq '.hooks.PostToolUse | length' "$E_SET" 2>/dev/null)" = 2 ] && ok || bad "E2 want 2 PostToolUse entries (edit-feedback + proc hook): $(jq -c '.hooks.PostToolUse' "$E_SET" 2>/dev/null)"
jq -e '.hooks.PostToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' "$E_SET" >/dev/null 2>&1 && ok || bad "E2 the edit-feedback entry was dropped"
jq -e --arg c "$EH/bin/exec-proc-hook.sh" '.hooks.PostToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c)' "$E_SET" >/dev/null 2>&1 && ok || bad "E2 the proc-hook PostToolUse entry is missing"
jq -e --arg c "$EH/bin/exec-proc-hook.sh" '.hooks.PostToolUseFailure[] | select(.matcher == "Bash") | .hooks[] | select(.command == $c)' "$E_SET" >/dev/null 2>&1 && ok || bad "E2 the proc-hook PostToolUseFailure entry is missing"
jq -e '.hooks.PreToolUse[] | .hooks[] | select(.command == "/x/iron-law-guard.sh")' "$E_SET" >/dev/null 2>&1 && ok || bad "E3 the iron-law guard PreToolUse entry was dropped"
jq -e '.hooks.SessionStart[0].matcher == "compact"' "$E_SET" >/dev/null 2>&1 && ok || bad "E3 the SessionStart entry was dropped"
jq -e '.permissions.deny == ["x"]' "$E_SET" >/dev/null 2>&1 && ok || bad "E3 a non-hook key was dropped"
# Not execute, or no tag: no proc hook and no tag in the env.
E_OUT=$(
  HARNESS="$EH" STAGE=review PROJECT=p EXEC_PROC_TAG="$RUNID-e" LANE_REGISTRY="$NOREG"
  _sets=(); SP_ENV=(); _eph=""; _ephto=""
  # shellcheck disable=SC1090
  . "$T/eph.sh"
  printf '%s|%s\n' "${#_sets[@]}" "${SP_ENV[*]}"
)
[ "$E_OUT" = "0|" ] && ok || bad "E4 stage review: no proc hook ($E_OUT)"
E_OUT=$(
  HARNESS="$EH" STAGE=execute PROJECT=p EXEC_PROC_TAG="" LANE_REGISTRY="$NOREG"
  _sets=(); SP_ENV=(); _eph=""; _ephto=""
  # shellcheck disable=SC1090
  . "$T/eph.sh"
  printf '%s|%s\n' "${#_sets[@]}" "${SP_ENV[*]}"
)
[ "$E_OUT" = "0|" ] && ok || bad "E4 no tag: no proc hook ($E_OUT)"

# ═════ F: ee_on_empty with the TK-3659 transcript ═══════════════════════════
# f_build <name> [snapshot] -> a build dir with the TK-3659 stage output
f_build() {
  local b="$T/bd-$1"
  mkdir -p "$b"; cp "$FX/mk3659-transcript.md" "$b/execute-run.txt"
  [ -n "${2:-}" ] && cp "$2" "$b/oom-procs.txt"
  printf '%s' "$b"
}
ONEMPTY() {
  local b="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    export HARNESS="$H" CLAUDE_PROJECTS_DIR="$T/projects" HOME="$T/home" ALERTLOG="$T/alert.log" \
      PROJECT=project-6-os KEY=TK-3659 LANE_REGISTRY="$NOREG"
    # shellcheck disable=SC1090
    . "$LIB_EE" || exit 9
    ee_on_empty "$b" ) >/dev/null 2>&1
}
sr() { head -1 "$1/stop-reason.txt" 2>/dev/null; }
alerts() { local c; c=$(grep -c . "$T/alert.log" 2>/dev/null); echo "${c:-0}"; }
rm -f "$T/alert.log"
F1=$(f_build 1 "$FX/mk3659-procs.txt"); ONEMPTY "$F1" VM_MEMORY_MB=32768
case "$(sr "$F1")" in "EXECUTE_OOM: NODE_OPTIONS=--max-old-space-size=8192 npm run typecheck"*) ok ;; *) bad "F1 stop-reason.txt start: $(sr "$F1")" ;; esac
grep -q 'concurrent processes' "$F1/stop-reason.txt" 2>/dev/null && ok || bad "F1 want 'concurrent processes': $(sr "$F1")"
grep -q 'Raise the row' "$F1/stop-reason.txt" 2>/dev/null && bad "F1 a concurrent stop must not say 'Raise the row': $(sr "$F1")" || ok
grep -q '32768 MB' "$F1/stop-reason.txt" 2>/dev/null && ok || bad "F1 the stop reason still names the machine memory: $(sr "$F1")"
[ "$(alerts)" = 1 ] && ok || bad "F1 want one alert line, got $(alerts)"
grep -q 'concurrent processes' "$T/alert.log" 2>/dev/null && ok || bad "F1 the alert names the cause: $(head -1 "$T/alert.log" 2>/dev/null)"
grep -q 'Raise the row' "$T/alert.log" 2>/dev/null && bad "F1 the concurrent alert says 'Raise the row'" || ok
grep -q -- '--id execute-oom:project-6-os:TK-3659' "$T/alert.log" 2>/dev/null && ok || bad "F1 the alert id is unchanged"
ONEMPTY "$F1" VM_MEMORY_MB=32768
[ "$(alerts)" = 1 ] && ok || bad "F1 a second ee_on_empty on the same dir adds no alert (got $(alerts))"

rm -f "$T/alert.log"
F2=$(f_build 2 "$FX/single-90pct-procs.txt"); ONEMPTY "$F2" VM_MEMORY_MB=16384
grep -q 'Raise the row lane.fly-pool.project-6-os.vm_memory_mb' "$F2/stop-reason.txt" 2>/dev/null && ok || bad "F2 one process at 90% says raise the row: $(sr "$F2")"
grep -q 'one process used most of the memory' "$F2/stop-reason.txt" 2>/dev/null && ok || bad "F2 names the single cause: $(sr "$F2")"
grep -q 'lane.fly-pool.project-6-os.vm_memory_mb' "$T/alert.log" 2>/dev/null && ok || bad "F2 the alert names the row"

F4=$(f_build 4); ONEMPTY "$F4" VM_MEMORY_MB=16384
grep -q 'Cause unknown, no snapshot' "$F4/stop-reason.txt" 2>/dev/null && ok || bad "F4 no oom-procs.txt -> 'Cause unknown, no snapshot': $(sr "$F4")"
case "$(sr "$F4")" in "EXECUTE_OOM: "*) ok ;; *) bad "F4 still EXECUTE_OOM: $(sr "$F4")" ;; esac

# Round trip: ep_snapshot writes it, ee_on_empty reads it.
F5=$(f_build 5)
epx EP_PS_CMD="$T/fake-ps.sh" EP_SELF_PID=500 EE_MEMINFO="$T/meminfo" -- ep_snapshot "$F5/oom-procs.txt" "Exit code 137"
ONEMPTY "$F5" VM_MEMORY_MB=32768
grep -q 'concurrent processes' "$F5/stop-reason.txt" 2>/dev/null && ok || bad "F5 round trip ep_snapshot -> ee_on_empty: $(sr "$F5")"

# ═════ G: knobs ═════════════════════════════════════════════════════════════
[ "$(epx EXEC_OOM_SINGLE_PCT=95 -- ep_oom_cause "$FX/single-90pct-procs.txt" 16384 | cut -f1)" = unknown ] \
  && ok || bad "G1 EXEC_OOM_SINGLE_PCT=95 turns the 90% fixture into unknown"
[ "$(epx EXEC_OOM_HEAVY_RSS_MB=2000 -- ep_oom_cause "$FX/mk3659-procs.txt" 32768 | cut -f1)" != concurrent ] \
  && ok || bad "G2 EXEC_OOM_HEAVY_RSS_MB=2000 leaves only 1 heavy: not concurrent"
TAGG="$RUNID-g"
env HARNESS_EXEC_TAG="$TAGG" sleep 300 & GP=$!; echo $GP >> "$PIDS_FILE"
sleep 0.2
ERR=$(epx EXEC_PROC_REAP=0 -- ep_reap "$TAGG" 2>&1)
alive "$GP" && ok || bad "G3 EXEC_PROC_REAP=0 reaped a process"
case "$ERR" in *"reaped 0 group(s), 0 process(es)"*) ok ;; *) bad "G3 EXEC_PROC_REAP=0 count line: $ERR" ;; esac
epx EXEC_PROC_REAP_GRACE_S=1 -- ep_reap "$TAGG" 2>/dev/null
alive "$GP" && bad "G4 the default reaps the tagged sleep" || ok
[ "$(epx -- ep_oom_cause "$FX/single-90pct-procs.txt" 16384 | cut -f1)" = single ] && ok || bad "G5 with no knob set, 90% is single"
[ -s "$DIR/catalog/lanes.d/_lib.exec-procs.json" ] && ok || bad "G6 catalog/lanes.d/_lib.exec-procs.json is missing"
for k in EXEC_PROC_REAP EXEC_PROC_REAP_GRACE_S EXEC_OOM_HEAVY_RSS_MB EXEC_OOM_SINGLE_PCT EXEC_OOM_SNAPSHOT_ROWS; do
  jq -e --arg k "$k" '.libs[] | select(.id == "exec-procs") | .knobs[] | select(.env == $k)' "$DIR/catalog/lanes.d/_lib.exec-procs.json" >/dev/null 2>&1 \
    && ok || bad "G6 knob $k is not registered"
done

# ═════ W: rb/execute.sh wiring, on the BH-9123 relaunch shape ═══════════════
# The REAL text of bin/lib/rb/execute.sh from the tag export to the end of the
# relaunch loop, run with stub CC / CKPT / ecb_* / ep_reap. CC logs whether a
# snapshot existed when the call started, then leaves one behind (the hook).
RBX="$DIR/bin/lib/rb/execute.sh"
# W0: EX_RC=$? stays the first line of the execute result block (BH-9123).
[ "$(awk 'index($0,"# >>> execute result")==1{getline; print; exit}' "$RBX" | cut -d' ' -f1)" = 'EX_RC=$?' ] \
  && ok || bad "W0 EX_RC=\$? is no longer the first line of the execute result block"
[ "$(grep -c 'ep_reap "\${EXEC_PROC_TAG:-}"' "$RBX")" = 2 ] && ok || bad "W0 want the guarded ep_reap after both CKPT_STOPs that follow a CC execute"
awk '/^export EXEC_PROC_TAG=/{f=1} /^# A CALL-GUARD REFUSAL IS NOT AN EMPTY SESSION/{exit} f' "$RBX" > "$T/rbx.sh"
[ -s "$T/rbx.sh" ] && bash -n "$T/rbx.sh" 2>/dev/null && ok || bad "W0 could not lift the execute block out of bin/lib/rb/execute.sh"
WRUN() { # WRUN <rc list for the CC calls> <reap rc> -> prints the call log and the end state
  local wb="$T/w-$1-$2"; scratch_rm "$wb"; mkdir -p "$wb"; : > "$wb/oom-procs.txt"   # a stale snapshot
  ( set -uo pipefail
    BUILD="$wb"; KEY=TK-3659; PROJECT=project-6-os; BRANCH=b; BASE=main; HARNESS="$T/nohub"
    EXECUTE_MODEL=m; WRCS=($1); WN=0; WLOG="$wb/log"
    STAMP() { echo t; }; RESULT() { echo "RESULT $*" >> "$WLOG"; }; BB() { :; }
    CKPT_START() { echo CKPT_START >> "$WLOG"; }; CKPT_STOP() { echo CKPT_STOP >> "$WLOG"; }
    sp_render() { printf -v "$2" '%s' prompt; }
    CC() { local s=nosnap; [ -e "$BUILD/oom-procs.txt" ] && s=snap
      echo "CC $s tag=${EXEC_PROC_TAG:-}" >> "$WLOG"; : > "$BUILD/oom-procs.txt"
      local r=${WRCS[$WN]:-0}; WN=$((WN+1)); return "$r"; }
    ep_reap() { echo "REAP $1" >> "$WLOG"; return "$WREAPRC"; }
    ecb_write() { return 0; }; ecb_checkpoint_text() { echo ck; }; ecb_record() { :; }
    ecb_render_resume() { printf -v "$1" '%s' resume; }; ecb_resume_sid() { echo ""; }
    WREAPRC=$2
    # shellcheck disable=SC1090
    . "$T/rbx.sh"
    echo "END EX_RC=$EX_RC EX_CALLS=$EX_CALLS tag=${EXEC_PROC_TAG-unset}" >> "$WLOG" ) >/dev/null 2>&1
  cat "$wb/log" 2>/dev/null
}
# One call, rc 0: snapshot cleared before it, reap after its CKPT_STOP.
W1=$(WRUN "0" 0)
[ "$(grep -c '^CC ' <<<"$W1")" = 1 ] && ok || bad "W1 want one execute call: $W1"
grep -q '^CC nosnap tag=TK-3659-[0-9]*-[0-9]*$' <<<"$W1" && ok || bad "W1 the stale snapshot must be gone and the tag set at the call: $W1"
[ "$(grep -A1 '^CKPT_STOP$' <<<"$W1" | sed -n 2p)" = "REAP $(sed -n 's/^CC nosnap tag=//p' <<<"$W1")" ] \
  && ok || bad "W1 the reap of the build tag must follow the CKPT_STOP: $W1"
grep -q '^END EX_RC=0 EX_CALLS=1 tag=unset$' <<<"$W1" && ok || bad "W1 end state (EX_RC 0, tag unset): $W1"
# A relaunch (rc 124, then 0): each call starts with no snapshot, each is reaped, one tag.
W2=$(WRUN "124 0" 0)
[ "$(grep -c '^CC nosnap ' <<<"$W2")" = 2 ] && ok || bad "W2 each relaunch call must start with no snapshot: $W2"
[ "$(grep -c '^REAP ' <<<"$W2")" = 2 ] && ok || bad "W2 want a reap after each execute call: $W2"
[ "$(grep '^REAP \|^CC ' <<<"$W2" | sed 's/^CC nosnap tag=//; s/^REAP //' | sort -u | wc -l)" = 1 ] \
  && ok || bad "W2 one tag per build across the relaunch: $W2"
[ "$(grep -v '^RESULT' <<<"$W2" | tr '\n' ' ' | sed 's/tag=[^ ]*//g; s/REAP [^ ]*/REAP/g')" = "CC nosnap  CKPT_STOP REAP CKPT_START CC nosnap  CKPT_STOP REAP END EX_RC=0 EX_CALLS=2  " ] \
  && ok || bad "W2 order: $(tr '\n' '|' <<<"$W2")"
# A reap that fails changes nothing: EX_RC stays the rc of the call.
W3=$(WRUN "1" 1)
grep -q '^END EX_RC=1 EX_CALLS=1 ' <<<"$W3" && ok || bad "W3 a failed reap must not change EX_RC (want 1): $W3"
W4=$(WRUN "124 1" 1)
grep -q '^END EX_RC=1 EX_CALLS=2 ' <<<"$W4" && ok || bad "W4 a failed reap must not change the relaunch EX_RC (want 1): $W4"

# ═════ Z: no network ════════════════════════════════════════════════════════
[ ! -s "$T/net.log" ] && ok || bad "Z a network stub was called: $(head -3 "$T/net.log")"

cleanup_procs
echo "execute-oom-classifier.bh-9288: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
