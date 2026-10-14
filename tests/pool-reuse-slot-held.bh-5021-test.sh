#!/bin/bash
# tests/pool-reuse-slot-held.bh-5021-test.sh — a reused pool machine with a held
# build slot is cleaned, or destroyed, before it is handed a new build (BH-5021).
#
# BH-4973, a hotfix, deferred three times on reused machines with
# `BUILD_DEFERRED all 1 slots busy`: something from the previous build still
# held locks/build-slot-1.lock. Pinned here, driven:
#   P1  a stale holder (an orphan that inherited the slot fd) is killed by the
#       REAL bin/pool-slot-clean.sh: `SLOTCLEAN ok cleaned=…`, exit 0
#   P2  the new build then takes the slot: the real `# >>> build slots` block
#       answers GOT=1 and writes no RESULT
#   P3  the holder is logged before it is killed, its secrets redacted
#   P4  a free slot is left alone: `SLOTCLEAN ok clean`, an unrelated lock
#       holder still alive
#   P5  a holder the cleaner may not kill (its own ancestor) -> `SLOTCLEAN held`,
#       exit 1, the ancestor alive
#   P6  the hub's handoff (next_job_or_destroy, lifted verbatim) destroys a
#       machine whose cleaner answers held, and hands the claimed row back
#   P7  ...reuses one whose cleaner killed the holder, and says so
#   P8  ...reuses on an empty answer (an older tarball, the stub suites)
#   P9  ...never reuses a machine whose last RESULT was the dirty-slot deferral;
#       a plain `all 1 slots busy` still reuses
#   P10 the REAL reap (bin/fly-pool.sh): a dirty-slot deferral leaves the
#       ticket's deferral count and spawn cap alone, sets no project hold and
#       destroys the machine; a plain `all 1 slots busy` still counts
# Holders are real processes inside $T, killed and reaped by the EXIT trap.
# Run from anywhere: bash tests/pool-reuse-slot-held.bh-5021-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# A pool build runs this suite with its own HOTFIX=1 / BUILDER_EXEC=1 in the
# environment; every case here sets the ones it means.
unset HOTFIX BUILDER_EXEC
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null 2>&1 || { echo "pool-reuse-slot-held.bh-5021: flock absent — skipping"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "pool-reuse-slot-held.bh-5021: jq absent — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/locks" "$H/logs" "$H/flags" "$T/b"
scratch_install_closure bin/pool-slot-clean.sh "$H" >/dev/null 2>&1 || bad "bin/pool-slot-clean.sh could not be installed into the scratch harness"
CLEAN="$H/bin/pool-slot-clean.sh"
[ -x "$DIR/bin/pool-slot-clean.sh" ] && ok || bad "bin/pool-slot-clean.sh is missing or not executable"
LOCK="$H/locks/build-slot-1.lock"

HOLDERS=()
cleanup_holders() { local p; for p in "${HOLDERS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; }
trap 'cleanup_holders' EXIT
alive() { # alive <pid> -> 0 while the pid runs (a zombie has exited, and its fds are closed)
  [ -r "/proc/$1/stat" ] || return 1
  [ "$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)" != Z ]
}
clean() { OUT=$(POOL_SLOT_CLEAN_GRACE_S=2 "$CLEAN" --harness "$H" 2>"$T/clean.err"); RC=$?; }

# ── P1 a stale holder is killed ───────────────────────────────────────────────
# The subshell takes the slot the way run-build does (fd 8, flock), starts a
# child that inherits fd 8, and exits: only the orphan holds the lock now, the
# BH-4973 shape. Its argv carries a token so P3 can check the redaction.
( exec 8>"$LOCK"; flock 8
  bash -c 'exec -a "sleep 300 FOO_TOKEN=abc" sleep 300' </dev/null >/dev/null 2>&1 &  # determinism: ok a holder process, killed by the cleaner or the EXIT trap
  echo $! > "$T/p1.pid" )
P1=$(cat "$T/p1.pid"); HOLDERS+=("$P1")
flock -n "$LOCK" true && bad "P1 fixture: the orphan does not hold the slot, every assertion below is vacuous" || ok
clean
[ "$RC" = 0 ] && ok || bad "P1: the cleaner must exit 0 after killing the holder (rc=$RC out=$OUT err=$(cat "$T/clean.err"))"
[[ "$OUT" == "SLOTCLEAN ok cleaned="* ]] && ok || bad "P1: expected 'SLOTCLEAN ok cleaned=…', got '$OUT'"
[[ "$OUT" == *"$P1"* ]] && ok || bad "P1: the answer must name the killed pid $P1: '$OUT'"
alive "$P1" && bad "P1: the holder $P1 is still running" || ok

# ── P2 the new build takes the slot ──────────────────────────────────────────
flock -n "$LOCK" true && ok || bad "P2: the slot is still held after the cleaner said ok"
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }
awk '/^# >>> build slots/{f=1;next} /^# <<< build slots/{exit} f' "$RB_ALL" > "$T/slots.sh"
[ -s "$T/slots.sh" ] && ok || bad "P2: could not extract the build-slots gate"
mkdir -p "$H/bin/lib"; scratch_install_closure bin/lib/build-caps.sh "$H" >/dev/null
rm -f "$T/RESULT"
SOUT=$( env HARNESS="$H" BUILD="$T/b" PROJECT=proj KEY=BH-1 BUILD_SLOTS=1 \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; RESULT() { echo "$*" > "'"$T"'/RESULT"; }
           . "$0"; echo "PASSED slot=${GOT:-none}"' "$T/slots.sh" 2>&1 )
[ "$SOUT" = "PASSED slot=1" ] && ok || bad "P2: the new build must take slot 1 (got: $SOUT)"
[ -e "$T/RESULT" ] && bad "P2: the gate wrote a RESULT: $(cat "$T/RESULT")" || ok

# ── P3 logged before the kill, secrets redacted ──────────────────────────────
LOGF="$H/logs/pool-slot-clean.log"
grep -E "holder lock=build-slot-1\.lock pid=$P1 ppid=[0-9]+ age=[0-9]+ cmd=.*sleep[ ]300" "$LOGF" >/dev/null 2>&1 \
  && ok || bad "P3: no holder line for pid $P1 in pool-slot-clean.log: $(cat "$LOGF" 2>/dev/null)"
grep -F 'FOO_TOKEN=<redacted>' "$LOGF" >/dev/null 2>&1 && ok || bad "P3: the token in the holder's argv was not redacted: $(cat "$LOGF" 2>/dev/null)"
grep -F 'FOO_TOKEN=abc' "$LOGF" "$T/clean.err" >/dev/null 2>&1 && bad "P3: the token value reached the log" || ok
grep -E "holder lock=build-slot-1\.lock pid=$P1" "$T/clean.err" >/dev/null 2>&1 && ok || bad "P3: the holder line must go to stderr too"

# ── P4 a free slot is left alone ─────────────────────────────────────────────
( exec 8>"$T/other.lock"; flock 8
  sleep 300 </dev/null >/dev/null 2>&1 &  # determinism: ok an unrelated lock holder the cleaner must not touch
  echo $! > "$T/p4.pid" )
P4=$(cat "$T/p4.pid"); HOLDERS+=("$P4")
clean
[ "$RC" = 0 ] && [ "$OUT" = "SLOTCLEAN ok clean" ] && ok || bad "P4: a free slot must answer 'SLOTCLEAN ok clean' rc 0 (rc=$RC out=$OUT)"
alive "$P4" && ok || bad "P4: the cleaner killed $P4, which holds a different lock"
[ -e "$LOCK" ] && ok || bad "P4: the cleaner deleted the lock file"
kill -9 "$P4" 2>/dev/null

# ── P5 an ancestor holder is reported, never killed ──────────────────────────
# The shell that runs the cleaner holds the slot itself.
kill -9 "$P1" 2>/dev/null  # a fixture reset: P1 left a holder behind if the cleaner failed
OUT=$( exec 8>"$LOCK"; flock -w 5 8 || echo fixture-lock-busy
       POOL_SLOT_CLEAN_GRACE_S=1 "$CLEAN" --harness "$H" 2>/dev/null; echo "rc=$?"; echo "me=$BASHPID"; alive "$BASHPID" && echo still-alive )
grep -q '^SLOTCLEAN held lock=build-slot-1\.lock' <<<"$OUT" && ok || bad "P5: an ancestor holder must answer 'SLOTCLEAN held lock=build-slot-1.lock': $OUT"
grep -qx 'rc=1' <<<"$OUT" && ok || bad "P5: held must exit 1: $OUT"
grep -qx 'still-alive' <<<"$OUT" && ok || bad "P5: the cleaner signalled its own ancestor: $OUT"
flock -n "$LOCK" true && ok || bad "P5: the ancestor's lock outlived the ancestor"

# ── P6-P9 the hub handoff, next_job_or_destroy lifted verbatim ───────────────
NR="$T/nr"; mkdir -p "$NR/q" "$NR/pool" "$NR/bin" "$NR/local"
awk '/^next_job_or_destroy\(\) \{/,/^\}$/' "$DIR/bin/fly-pool.sh" > "$NR/fn.sh"
grep -q 'REUSED=0' "$NR/fn.sh" && ok || bad "could not extract next_job_or_destroy from bin/fly-pool.sh"
printf '#!/bin/bash\nexit 0\n' > "$NR/bin/beat.sh"; chmod +x "$NR/bin/beat.sh"
# handoff <mexec-answer|-> [local RESULT line] -> REUSED, and the call logs in $NR
handoff() {
  local ans="$1" rline="${2:-}"
  rm -f "$NR/q"/*.json "$NR/pool"/*.json "$NR/local/RESULT"; : > "$NR/log"; : > "$NR/calls"
  jq -nc '{key:"BH-20",ticket_id:"20",attempt:0}' > "$NR/q/BH-20.json"
  jq -nc '{machine:"m1",key:"BH-10"}' > "$NR/pool/m1.json"
  [ -n "$rline" ] && printf '%s\nBUILD_DIR: x\n' "$rline" > "$NR/local/RESULT"
  REUSED=$(
    set +u
    HARNESS="$NR"; P=proj; APP=app; FLY=/bin/false; ROWS_ONLY=1
    QDIR="$NR/q"; POOL="$NR/pool"; LOCAL="$NR/local"
    MID=m1; MSTATE=started; KEY=BH-10; MF="$NR/pool/m1.json"; MACCT=max1
    STAMP() { echo now; }; say() { echo "$*" >> "$NR/log"; }
    if [ "$ans" = - ]; then mexec() { return 0; }
    else mexec() { echo "mexec $2" >> "$NR/calls"; case "$2" in *pool-slot-clean*) printf '%s\n' "$MEXEC_ANSWER" ;; esac; return 0; }; fi
    MEXEC_ANSWER="$ans"
    mput() { echo "mput $3" >> "$NR/calls"; return 0; }
    queue_claim() { echo "claim $3" >> "$NR/calls"; return 0; }
    queue_release() { echo "release $2 $3" >> "$NR/calls"; return 0; }
    destroy_machine() { echo "destroy $1" >> "$NR/calls"; return 0; }
    push_preplan() { :; }; push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    . "$NR/fn.sh"
    next_job_or_destroy
    echo "$REUSED"
  )
}
c() { grep -c "$1" "$NR/calls" 2>/dev/null || true; }

handoff "SLOTCLEAN held lock=build-slot-1.lock pids=42"
[ "$REUSED" = 0 ] && ok || bad "P6: a machine whose slot is still held was reused (REUSED=$REUSED)"
[ "$(c '^destroy m1')" = 1 ] && ok || bad "P6: the dirty machine was not destroyed: $(cat "$NR/calls")"
[ "$(c '^release BH-20')" = 1 ] && ok || bad "P6: the claimed row must be handed back exactly once: $(cat "$NR/calls")"
[ "$(c '^mput')" = 0 ] && ok || bad "P6: a job was pushed onto the dirty machine"
[ -f "$NR/q/BH-20.json" ] && ok || bad "P6: the queued job was consumed by a destroyed machine"
grep -q 'build slot still held' "$NR/log" && ok || bad "P6: no say line names the held slot: $(cat "$NR/log")"
grep -q 'pool-slot-clean' "$NR/calls" && ok || bad "P6: the handoff cleanup never ran the cleaner: $(cat "$NR/calls")"

handoff "SLOTCLEAN ok cleaned=1 pids=42"
[ "$REUSED" = 1 ] && ok || bad "P7: a cleaned machine must be reused (REUSED=$REUSED)"
grep -q '^mput /run/harness/job.json.next' "$NR/calls" && ok || bad "P7: the job was not pushed: $(cat "$NR/calls")"
[ "$(c '^destroy')" = 0 ] && ok || bad "P7: a cleaned machine was destroyed"
grep -q 'killed' "$NR/log" && grep -q '42' "$NR/log" && ok || bad "P7: no say line names the cleanup: $(cat "$NR/log")"

handoff "SLOTCLEAN ok clean"
[ "$REUSED" = 1 ] && ok || bad "P7b: a clean machine must be reused (REUSED=$REUSED)"
grep -q 'killed' "$NR/log" && bad "P7b: a clean machine logged a cleanup it never did" || ok

handoff -
[ "$REUSED" = 1 ] && ok || bad "P8: an empty cleanup answer must reuse as before (REUSED=$REUSED)"
handoff "SLOTCLEAN absent"
[ "$REUSED" = 1 ] && ok || bad "P8b: an older machine without the cleaner must reuse as before (REUSED=$REUSED)"

handoff "SLOTCLEAN ok clean" "BUILD_DEFERRED all 1 slots busy — slot held on this machine by 42 after cleanup"
[ "$REUSED" = 0 ] && ok || bad "P9: a machine whose last build deferred on a held slot was reused"
[ "$(c '^destroy m1')" = 1 ] && ok || bad "P9: the dirty machine was not destroyed: $(cat "$NR/calls")"
[ "$(c '^mput')" = 0 ] && ok || bad "P9: a job was pushed onto the dirty machine"
[ "$(c '^claim')" = 0 ] && ok || bad "P9: a row was claimed for a machine that is never reused"
[ -s "$NR/log" ] && ok || bad "P9: the decision was not logged"
handoff "SLOTCLEAN ok clean" "BUILD_DEFERRED all 1 slots busy"
[ "$REUSED" = 1 ] && ok || bad "P9b: the plain box wording must still reuse (REUSED=$REUSED)"

# ── P10 the real reap ────────────────────────────────────────────────────────
. "$(dirname "$0")/lib/pool-reap-fixture.sh" || exit 1
H0="$H"; prf_setup
cp "$DIR/bin/alert-line.sh" "$H/bin/"
HF="$H/state/pool/project-5/_spawn-hold"
kdef() { jq -r --arg k "$1" 'select(.key==$k) | .deferrals' "$H/state/fly-pool/project-5"/*.json "$H/state/build-queue/project-5"/*.json 2>/dev/null | sort -u | tr '\n' ' '; }
DIRTY="BUILD_DEFERRED all 1 slots busy — slot held on this machine by 42 after cleanup"
{
  prf_reset
  write_fly_stub "m-dirty=$DIRTY"
  machine_json m-dirty BH-1016 1
  queue_job BH-1018
  prf_run_pool
  # The requeued job may be spawned this same tick, so its count rides the new
  # machine's json rather than the queue file (the bh-1853 suite's reading).
  [ "$(kdef BH-1016)" = "1 " ] && ok || bad "P10: a dirty-slot deferral must leave the ticket's deferrals at 1, got '$(kdef BH-1016)'"
  grep -qx "$((NOW-60))" "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null \
    && bad "P10: the dirty machine's spawn still counts against the ticket's cap: $(cat "$H/state/pool/project-5/BH-1016.spawns")" || ok
  [ -e "$HF" ] && bad "P10: one dirty machine set a project spawn hold: $(cat "$HF")" || ok
  [ "$(destroyed m-dirty)" -ge 1 ] && ok || bad "P10: the dirty machine was not destroyed"
  [ "$(pushed_job m-dirty)" = 0 ] && ok || bad "P10: a queued job was handed to the dirty machine"
}
{
  prf_reset
  write_fly_stub "m-busy=BUILD_DEFERRED all 1 slots busy"
  machine_json m-busy BH-1016 1
  prf_run_pool
  [ "$(kdef BH-1016)" = "2 " ] && ok || bad "P10b: the plain box wording must still count a deferral (1 -> 2), got '$(kdef BH-1016)'"
  grep -qx "$((NOW-60))" "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null \
    && ok || bad "P10b: a plain deferral's spawn must keep counting against the cap"
}
H="$H0"

echo "pool-reuse-slot-held.bh-5021: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
