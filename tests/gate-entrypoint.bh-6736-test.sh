#!/bin/bash
# tests/gate-entrypoint.bh-6736-test.sh — BH-6736: bin/gate.sh, the one Mac
# gate entrypoint. Remote (bin/remote-gate.sh) by default; --local runs the
# tree's bin/run-tests-in-docker.sh under a GATE_LOCAL_SLOTS slot lock.
#
# Every case drives the real "$DIR/bin/gate.sh". The remote gate, the local
# runner and (in T4e) test-impact are stubs in $T/stub, through the seams
# REMOTE_GATE_BIN, GATE_LOCAL_BIN and GATE_IMPACT_BIN. T4 runs the real
# bin/test-impact.sh against a fixture git repo.
#
#   T1  default path: remote stub gets "<dir> <suites>", its rc comes back
#   T2  remote rc 125: exit 125, the reason passes through, --local is printed
#   T3  --local, flock arm: 3 gates, 2 slots, one waits, never 3 at once
#   T3m the same on the mkdir arm, and no slot dir is left behind
#   T4  --impacted: the merge-base diff picks tests/x-test.sh, not y
#   T4e --impacted with no suite list is 125; outside git it is 2
#   T5  the GATE_LOCAL_SLOTS knob is in the composed registry and env example
#   T6  skills/harness/SKILL.md names bin/gate.sh and no inline docker run
#   T7  usage errors are 2 and run nothing; GATE_LOCAL_SLOTS range 1..6
#   T8  mkdir arm: a dead holder's slot is reclaimed, a live one's is not
#   T9  bash -n, and no bash-4-only syntax (a Mac runs /bin/bash 3.2)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/gate-entrypoint.bh-6736-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
GATE="$DIR/bin/gate.sh"
# gate <args…>: the real bin/gate.sh, bounded at 20 s where `timeout` exists, so
# a gate that waits forever on a slot is a red case (rc 124), not a hung suite.
gate() {
  if command -v timeout > /dev/null 2>&1; then timeout 20 "$GATE" "$@"; else "$GATE" "$@"; fi
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

mkdir -p "$T/h" "$T/tmp" "$T/stub" "$T/repo/tests" "$T/run" "$T/out"
export HARNESS="$T/h" TMPDIR="$T/tmp"

# The remote stub writes its argv, one line, to $T/out/remote.argv and exits
# $STUB_RC; with STUB_RC=125 it prints a reason first, as remote-gate does.
cat > "$T/stub/remote" <<'EOF'
#!/bin/bash
echo "$*" > "$STUB_OUT/remote.argv"
[ "${STUB_RC:-0}" = 125 ] && echo "remote-gate: no route to Fly (stub)" >&2
exit "${STUB_RC:-0}"
EOF
# The local stub appends a line per call. With STUB_HOLD=1 it marks itself
# running in $T/run, records how many were running when it started, and holds
# its slot until $T/out/release exists (bounded at 10 s).
cat > "$T/stub/local" <<'EOF'
#!/bin/bash
echo "$PWD $*" >> "$STUB_OUT/local.calls"
if [ "${STUB_HOLD:-0}" = 1 ]; then
  : > "$STUB_RUN/$$.pid"
  ls "$STUB_RUN" | wc -l | tr -d ' ' >> "$STUB_OUT/conc"
  i=0
  while [ ! -f "$STUB_OUT/release" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  rm -f "$STUB_RUN/$$.pid"
fi
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/stub/impact-empty"
chmod +x "$T/stub/"*
export STUB_OUT="$T/out" STUB_RUN="$T/run"
export REMOTE_GATE_BIN="$T/stub/remote" GATE_LOCAL_BIN="$T/stub/local"
export GATE_POLL_S=0.1

reset_out() { rm -rf "$T/out" "$T/run" "$T/slots"; mkdir -p "$T/out" "$T/run"; }
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
export GATE_SLOT_DIR="$T/slots"

echo "T1 default path is the remote gate"
reset_out
STUB_RC=3 gate "$T/repo" tests/a-test.sh > "$T/out/o" 2> "$T/out/e"; rc=$?
[ "$rc" = 3 ] && ok "T1 rc of the remote gate comes back (3)" || bad "T1 rc $rc, want 3"
[ "$(cat "$T/out/remote.argv" 2>/dev/null)" = "$T/repo tests/a-test.sh" ] \
  && ok "T1 remote argv is '<dir> <suite>'" || bad "T1 remote argv '$(cat "$T/out/remote.argv" 2>/dev/null)'"
[ "$(lines "$T/out/local.calls")" = 0 ] && ok "T1 local runner not called" || bad "T1 local runner called"
reset_out
STUB_RC=0 gate "$T/repo" -- echo hi > /dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/out/remote.argv" 2>/dev/null)" = "$T/repo -- echo hi" ] \
  && ok "T1 '-- <command>' passes through to the remote gate" || bad "T1 command mode rc $rc argv '$(cat "$T/out/remote.argv" 2>/dev/null)'"

echo "T2 remote rc 125 is never a pass and never a silent local run"
reset_out
STUB_RC=125 gate "$T/repo" tests/a-test.sh > "$T/out/o" 2> "$T/out/e"; rc=$?
[ "$rc" = 125 ] && ok "T2 exit 125" || bad "T2 rc $rc, want 125"
e=$(cat "$T/out/e")
case "$e" in *"no route to Fly (stub)"*) ok "T2 remote reason passes through" ;; *) bad "T2 reason missing: $e" ;; esac
case "$e" in *"bin/gate.sh --local "*"tests/a-test.sh"*) ok "T2 prints the --local command" ;; *) bad "T2 no --local command: $e" ;; esac
case "$e" in *"Nothing passed"*) ok "T2 says nothing passed" ;; *) bad "T2 no 'Nothing passed': $e" ;; esac
[ "$(lines "$T/out/local.calls")" = 0 ] && ok "T2 no fallback to local" || bad "T2 local runner called"

# three_gates <label>: start 3 --local gates at once on 2 slots and check them.
three_gates() {
  local label=$1 i n waited max pids=""
  for i in 1 2 3; do
    STUB_HOLD=1 GATE_LOCAL_SLOTS=2 gate --local "$T/repo" tests/a-test.sh \
      > "$T/out/o$i" 2> "$T/out/e$i" &
    pids="$pids $!"
  done
  # Wait (max 10 s) until two runners hold a slot and one gate says it waits.
  # The runners hold until $T/out/release, so the third cannot start before.
  for i in $(seq 1 100); do
    n=$(ls "$T/run" | wc -l | tr -d ' ')
    waited=$(cat "$T/out/e1" "$T/out/e2" "$T/out/e3" 2>/dev/null | grep -c 'waiting for one to free')
    [ "$n" -ge 2 ] && [ "$waited" -ge 1 ] && break
    sleep 0.1
  done
  n=$(ls "$T/run" | wc -l | tr -d ' ')
  [ "$n" = 2 ] && [ "$waited" = 1 ] && ok "$label 2 runners hold a slot, the third waits" \
    || bad "$label $n runners running, $waited waiting, want 2 and 1"
  : > "$T/out/release"
  local allok=1
  for i in $pids; do wait "$i" || allok=0; done
  [ "$allok" = 1 ] && ok "$label all 3 gates exit 0" || bad "$label a gate exited non-zero"
  [ "$(lines "$T/out/local.calls")" = 3 ] && ok "$label the third ran after a slot freed" || bad "$label $(lines "$T/out/local.calls") runs, want 3"
  max=$(sort -n "$T/out/conc" 2>/dev/null | tail -n 1)
  [ "${max:-0}" -le 2 ] && ok "$label never more than 2 at once (max $max)" || bad "$label $max ran at once"
  waited=$(cat "$T/out/e1" "$T/out/e2" "$T/out/e3" | grep -c 'waiting for one to free')
  [ "$waited" = 1 ] && ok "$label one waiting line in total" || bad "$label $waited waiting lines, want 1"
  n=$(cat "$T/out/e1" "$T/out/e2" "$T/out/e3" | grep -c '^gate: local slot [12] of 2$')
  [ "$n" = 3 ] && ok "$label each gate names its slot" || bad "$label $n slot lines, want 3"
  [ "$(cut -d' ' -f1 "$T/out/local.calls" | sort -u)" = "$T/repo" ] \
    && ok "$label the runner runs in <dir>" || bad "$label runner cwd: $(cut -d' ' -f1 "$T/out/local.calls" | sort -u)"
}

echo "T3 --local, flock arm"
if command -v flock > /dev/null 2>&1; then
  reset_out
  GATE_LOCK_MODE=auto three_gates T3
else
  echo "  SKIP T3: no flock on this machine (T3m covers the mkdir arm)"
fi

echo "T3m --local, mkdir arm"
reset_out
GATE_LOCK_MODE=mkdir three_gates T3m
left=$(find "$T/slots" -name '*.d' 2>/dev/null | wc -l | tr -d ' ')
[ "$left" = 0 ] && ok "T3m no slot dir is left after exit" || bad "T3m $left slot dirs left"

echo "T4 --impacted runs the suites the merge-base diff reaches"
F="$T/fix"
mkdir -p "$F/bin" "$F/tests"
echo 'echo x' > "$F/bin/x.sh"; echo 'echo y' > "$F/bin/y.sh"
printf '#!/bin/bash\nbash "$(dirname "$0")/../bin/x.sh"\n' > "$F/tests/x-test.sh"
printf '#!/bin/bash\nbash "$(dirname "$0")/../bin/y.sh"\n' > "$F/tests/y-test.sh"
g() { git -C "$F" -c user.email=fixture@example.com -c user.name=fixture "$@"; }
g init -q && g add -A && g commit -qm one && g update-ref refs/remotes/origin/main HEAD
echo 'echo x2' > "$F/bin/x.sh"; g commit -qam two
reset_out
STUB_RC=0 gate --impacted "$F" > "$T/out/o" 2> "$T/out/e"; rc=$?
[ "$rc" = 0 ] && ok "T4 rc 0" || bad "T4 rc $rc: $(cat "$T/out/e")"
[ "$(cat "$T/out/remote.argv" 2>/dev/null)" = "$F tests/x-test.sh" ] \
  && ok "T4 remote gets exactly tests/x-test.sh" || bad "T4 remote argv '$(cat "$T/out/remote.argv" 2>/dev/null)'"
# An untracked file counts as changed: the remote gate uploads it.
printf '#!/bin/bash\nbash "$(dirname "$0")/../bin/y.sh"\n' > "$F/tests/z-test.sh"
reset_out
STUB_RC=0 gate --impacted "$F" > "$T/out/o" 2> "$T/out/e"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$T/out/remote.argv" 2>/dev/null)" = "$F tests/x-test.sh tests/z-test.sh" ] \
  && ok "T4 an untracked suite is in the list" || bad "T4 untracked: rc $rc argv '$(cat "$T/out/remote.argv" 2>/dev/null)'"
rm -f "$F/tests/z-test.sh"
reset_out
STUB_RC=125 gate --impacted "$F" > "$T/out/o" 2> "$T/out/e"; rc=$?
case "$(cat "$T/out/e")" in *"bin/gate.sh --local $F tests/x-test.sh"*) ok "T4 rc 125 prints the computed --local command" ;;
  *) bad "T4 125 command line: $(cat "$T/out/e")" ;; esac

echo "T4e --impacted refusals"
reset_out
GATE_IMPACT_BIN="$T/stub/impact-empty" gate --impacted "$F" > "$T/out/o" 2> "$T/out/e"; rc=$?
[ "$rc" = 125 ] && ok "T4e no suite list is 125" || bad "T4e empty list rc $rc, want 125"
[ ! -f "$T/out/remote.argv" ] && ok "T4e remote gate not called" || bad "T4e remote gate called"
reset_out
mkdir -p "$T/nogit"
gate --impacted "$T/nogit" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "T4e not a git tree is 2" || bad "T4e not-git rc $rc, want 2"
gate --impacted --base no-such-ref "$F" > /dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "T4e no merge-base is 2" || bad "T4e no merge-base rc $rc, want 2"
[ ! -f "$T/out/remote.argv" ] && ok "T4e refusals run nothing" || bad "T4e a refusal ran the remote gate"

echo "T5 the GATE_LOCAL_SLOTS knob"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --check > "$T/out/lb" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "T5 lanes-build --check green" || bad "T5 lanes-build --check rc $rc: $(tail -n 3 "$T/out/lb")"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/out/reg.json" 2>/dev/null
k=$(jq -c '.libs[]|select(.id=="gate")|[.file,(.knobs[]|select(.env=="GATE_LOCAL_SLOTS")|.default,.min,.max,.settable)]' "$T/out/reg.json" 2>/dev/null)
[ "$k" = '["bin/gate.sh",2,1,6,false]' ] && ok "T5 lib gate: bin/gate.sh, GATE_LOCAL_SLOTS 2 in 1..6, not settable" || bad "T5 registry row: '$k'"
"$DIR/bin/render-env-example.sh" --root "$DIR" > "$T/out/env" 2>/dev/null
n=$(grep -c '^#GATE_LOCAL_SLOTS=2$' "$T/out/env")
[ "$n" = 1 ] && ok "T5 env example names #GATE_LOCAL_SLOTS=2" || bad "T5 env example has $n GATE_LOCAL_SLOTS lines"

echo "T6 the skill points at bin/gate.sh"
S="$DIR/skills/harness/SKILL.md"
# The image name comes from the runner, so this suite does not hardcode it
# (tests/docker-image-ratchet-test.sh). An empty name would make T6 vacuous.
IMG=$(sed -n 's/^IMAGE="${IMAGE:-\([^:"]*\):.*/\1/p' "$DIR/bin/run-tests-in-docker.sh" | head -n 1)
[ -n "$IMG" ] && ok "T6 image name read from bin/run-tests-in-docker.sh" || bad "T6 could not read the image name from bin/run-tests-in-docker.sh"
n=$(grep -c "docker run.*${IMG:-UNSET-IMAGE-NAME}" "$S")
[ "$n" = 0 ] && ok "T6 no inline docker run of the test image" || bad "T6 $n inline docker run lines"
n=$(grep -c '^## Run the gate from the Mac' "$S")
[ "$n" = 1 ] && ok "T6 heading present" || bad "T6 heading count $n"
n=$(grep -c 'bin/gate.sh' "$S")
[ "$n" -ge 1 ] && ok "T6 names bin/gate.sh" || bad "T6 bin/gate.sh not named"

echo "T7 usage errors are 2 and run nothing"
reset_out
expect2() { # <label> <args…>
  local label=$1; shift
  gate "$@" > /dev/null 2> "$T/out/e"; local rc=$?
  [ "$rc" = 2 ] && ok "T7 $label is 2" || bad "T7 $label rc $rc, want 2"
}
expect2 "unknown flag" --frobnicate "$T/repo" tests/a-test.sh
expect2 "missing dir" "$T/no-such-dir" tests/a-test.sh
expect2 "no dir at all"
expect2 "--impacted with suites" --impacted "$F" tests/x-test.sh
expect2 "--impacted with --" --impacted "$F" -- echo hi
expect2 "--local with --" --local "$T/repo" -- echo hi
expect2 "--base with no value" --base
expect2 "--base without --impacted" --base origin/main "$T/repo" tests/a-test.sh
for v in 0 7 x 1x; do GATE_LOCAL_SLOTS=$v expect2 "GATE_LOCAL_SLOTS=$v" --local "$T/repo" tests/a-test.sh; done
case "$(cat "$T/out/e")" in *"GATE_LOCAL_SLOTS wants a whole number 1..6, got '1x'"*) ok "T7 the refusal names the value" ;; *) bad "T7 refusal text: $(cat "$T/out/e")" ;; esac
mkdir -p "$T/repo-nobin"
[ ! -f "$T/out/remote.argv" ] && [ "$(lines "$T/out/local.calls")" = 0 ] && ok "T7 nothing ran" || bad "T7 a refused run called a runner"
GATE_LOCAL_BIN= GATE_LOCAL_SLOTS=2 gate --local "$T/repo-nobin" tests/a-test.sh > /dev/null 2> "$T/out/e"; rc=$?
[ "$rc" = 2 ] && ok "T7 default runner missing in <dir> is 2" || bad "T7 default runner missing rc $rc"
for v in 1 6; do
  reset_out
  GATE_LOCAL_SLOTS=$v gate --local "$T/repo" tests/a-test.sh > /dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ "$(lines "$T/out/local.calls")" = 1 ] && ok "T7 GATE_LOCAL_SLOTS=$v runs" || bad "T7 GATE_LOCAL_SLOTS=$v rc $rc"
done
gate --help > "$T/out/help" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(grep -c 'bin/gate.sh' "$T/out/help")" -ge 1 ] && ok "T7 --help is 0 and prints usage" || bad "T7 --help rc $rc"

echo "T8 mkdir arm: a dead holder is reclaimed, a live one is not"
reset_out
mkdir -p "$T/slots/1.d" "$T/slots/2.d"
( exit 0 ) & dead=$!; wait "$dead"
echo "$dead" > "$T/slots/1.d/pid"
echo "$$" > "$T/slots/2.d/pid"
GATE_LOCK_MODE=mkdir GATE_LOCAL_SLOTS=2 gate --local "$T/repo" tests/a-test.sh > /dev/null 2> "$T/out/e"; rc=$?
[ "$rc" = 0 ] && ok "T8 rc 0" || bad "T8 rc $rc: $(cat "$T/out/e")"
n=$(grep -c '^gate: local slot 1 of 2$' "$T/out/e")
[ "$n" = 1 ] && ok "T8 took the dead holder's slot 1" || bad "T8 slot line: $(cat "$T/out/e")"
[ ! -e "$T/slots/1.d" ] && ok "T8 slot 1 freed on exit" || bad "T8 slot 1 still there"
[ "$(cat "$T/slots/2.d/pid" 2>/dev/null)" = "$$" ] && ok "T8 the live holder's slot 2 is untouched" || bad "T8 slot 2 changed"
n=$(find "$T/slots" -name '*.stale.*' | wc -l | tr -d ' ')
[ "$n" = 0 ] && ok "T8 no stale leftovers" || bad "T8 $n stale dirs left"
# A dir with no pid file is a holder between mkdir and its pid write: held.
reset_out
mkdir -p "$T/slots/1.d"
GATE_LOCK_MODE=mkdir GATE_LOCAL_SLOTS=1 gate --local "$T/repo" tests/a-test.sh > /dev/null 2> "$T/out/e" &
p=$!
for i in $(seq 1 50); do
  [ "$(grep -c 'waiting for one to free' "$T/out/e")" -ge 1 ] && break
  sleep 0.1
done
n=$(grep -c 'waiting for one to free' "$T/out/e")
[ "$n" = 1 ] && [ "$(lines "$T/out/local.calls")" = 0 ] && ok "T8 a fresh dir with no pid is held" || bad "T8 pidless dir: waited=$n calls=$(lines "$T/out/local.calls")"
rm -rf "$T/slots/1.d"
wait "$p"; rc=$?
[ "$rc" = 0 ] && [ "$(lines "$T/out/local.calls")" = 1 ] && ok "T8 the waiter runs once the slot frees" || bad "T8 waiter rc $rc"

echo "T9 bash 3.2 safe"
bash -n "$GATE" 2> "$T/out/e" && ok "T9 bash -n" || bad "T9 bash -n: $(cat "$T/out/e")"
n=$(grep -v '^[[:space:]]*#' "$GATE" 2>/dev/null | grep -cE 'mapfile|readarray|declare -A|\{[a-z_]+\}[<>]|\$\{[a-zA-Z_]+(,,|\^\^)')
[ -f "$GATE" ] && [ "$n" = 0 ] && ok "T9 no bash-4-only syntax" || bad "T9 $n bash-4 lines (or no bin/gate.sh)"

echo
echo "gate-entrypoint: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
