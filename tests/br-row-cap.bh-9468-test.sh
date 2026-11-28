#!/bin/bash
# tests/br-row-cap.bh-9468-test.sh — BH-9468 (#9369 fix 4): a row that reaches
# no rung and no state write in BR_ROW_MAX_SECS is stopped, logged as carried,
# and the next row still gets its rung in the same tick. A row past its first
# rung or write is never stopped, and rungs stay serial.
#
# THE BUG (hub, 2026-11-09). One row held a tick for 504 s of reads. The tick's
# wall bound (BR_TICK_MAX_SECS) is asked only BETWEEN rows, so every row behind
# it waited.
#
#   0  CALIBRATION: one uncapped tick of two fast rows takes W s on THIS box.
#      The cap is CAP = W*3/2 + 5 (well above one ordinary row's reads), a
#      slow read sleeps SLOW = BOUND + CAP, and a run that the cap ended must
#      take under BOUND = 2*W + CAP + 15. Nothing is an absolute number of
#      seconds, so a slow runner scales every bound (lead review lr-9505: a
#      2 s cap carried ordinary rows on a 2-CPU box)
#   A  #7's reads sleep SLOW: the run ends under BOUND, logs
#      `row cap: p1/o-p1-7 carried`, #7 has no dispatch line and no EVENT
#   B  same run: #8 is dispatched after #7's carry line; the tick has rungs=1/
#   C  #7 is fast to its dispatch line, then a read sleeps CAP+5 s: not stopped,
#      no `row cap:` line, rungs=2/
#   D  the race, on the fragment alone: the watchdog holds the lock and wrote
#      `capped`; the row's wrapped br_record waits on the lock, then the row
#      ends 143 and the writer body never ran
#   E  tick 1 carries #7 (count 1 in .row-carry-p1.tsv); tick 2 logs `runs
#      uncapped`, #7 is dispatched, and the ledger no longer holds #7
#   F  BR_ROW_MAX_SECS=0, BR_ROW_MAX_SECS=abc and a one-PR run: #7's 4 s read
#      is not stopped; abc says one fallback line
#   G  a read that ignores TERM is KILLed after BR_ROW_KILL_GRACE_SECS (the
#      run ends under BOUND); no process of the row is left
#   H  a ledger entry whose row is not a candidate is gone after the tick
#   I  on the fragment alone: BR_FIX_HERE=1 does not arm; a ledger that
#      cannot be written says one line
#
# WHAT IS DRIVEN. A, B, C, E, F, G and H run the real bin/blocked-resolver.sh
# end to end against a scratch $HARNESS (the rig of
# tests/br-one-pr-lock.bh-9369-test.sh). D sources the fragment in a shell.
# No vendor is called (BH-7563): gh is a local stub, GH_TOKEN is empty.
# BR_ROW_CAP_RIG_DELAY=<secs> makes every stub gh read sleep that long: it
# imitates a slow runner (the lead's 40-54 s fixture tick) on a fast one.
# Run from anywhere: tests/br-row-cap.bh-9468-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -d /proc/self/fd ] || { echo "/proc missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9468-row-cap.sh"
[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9468-row-cap.sh must exist"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# THE SLOW READ. Inside row #7 the row subshell holds fd 9 on the per-key lock
# (locks/blocked-resolver-p1-o-p1-7.lock), and gh inherits it, so the stub
# knows it runs inside that row. $T/slow7 holds the seconds a read of #7 sleeps
# BEFORE the row's dispatch line (the read phase). $T/slowpost7 holds the
# seconds a read sleeps AFTER that line (a rung that runs long). Each is ONE
# slow read: only the first such read of #7 sleeps ($T/slept7 records it).
# $T/stubborn7 makes the sleep ignore TERM (case G).
RIG_DELAY="${BR_ROW_CAP_RIG_DELAY:-}"
case "$RIG_DELAY" in ''|*[!0-9.]*) RIG_DELAY="" ;; esac
[ -n "$RIG_DELAY" ] && printf '%s\n' "$RIG_DELAY" > "$T/rigdelay"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
[ -s "$T/rigdelay" ] && sleep "\$(cat "$T/rigdelay")"
IN7=0
case "\$(readlink /proc/\$\$/fd/9 2>/dev/null)" in *"-o-p1-7.lock") IN7=1 ;; esac
if [ "\$IN7" = 1 ]; then
  if grep -q 'p1/o-p1-7 \[[^]]*\] -> ' "$H/logs/blocked-resolver.log" 2>/dev/null; then
    [ -s "$T/slowpost7" ] && ! grep -q post "$T/slept7" 2>/dev/null \
      && { printf 'post\n' >> "$T/slept7"; sleep "\$(cat "$T/slowpost7")"; }
  elif [ -s "$T/slow7" ] && ! grep -q pre "$T/slept7" 2>/dev/null; then
    printf 'pre\n' >> "$T/slept7"
    if [ -e "$T/stubborn7" ]; then
      trap '' TERM; "$T/fakebin/brrc-g-sleep" "\$(cat "$T/slow7")"
    else
      sleep "\$(cat "$T/slow7")"
    fi
  fi
fi
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
ln -s "$(command -v sleep)" "$T/fakebin/brrc-g-sleep"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
LOGF="$H/logs/blocked-resolver.log"
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
ROWADD() { printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/p1/pull/%s\n' \
             "$1" "$((NOW - 600))" "$CONFLICT" "$1" >> "$ROWS"; }
RUNRC=0
RUN() { RUNRC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
          BR_SSH="$T/fakebin/br-ssh" BR_PER_TICK=10 BR_PER_TICK_P1=10 \
          BR_ROW_MAX_SECS="$CAP" BR_ROW_KILL_GRACE_SECS=1 env "$@" \
          bash "$H/bin/blocked-resolver.sh" ${RUNARGS[@]+"${RUNARGS[@]}"} >>"$T/run.log" 2>&1 ) || RUNRC=$?; }
RUNARGS=(p1)
LOG() { cat "$LOGF" 2>/dev/null; }
DISPATCHED() { grep -qE "p1/o-p1-$1 \\[[^]]*\\] -> " "$LOGF"; }
# HOLD <lock name> — a background sleep owns the flock until UNHOLD.
HOLDER=""
HOLD() { ( exec 9>"$H/locks/$1"; flock -n 9 || exit 1; exec sleep 300 ) & HOLDER=$!
         local i; for i in $(seq 1 50); do
           ( exec 8<"$H/locks/$1"; flock -n 8 ) 2>/dev/null || return 0; sleep 0.1; done
         echo "setup: the holder did not take $1"; exit 1; }
UNHOLD() { [ -n "$HOLDER" ] && { kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; }; HOLDER=""; }
trap 'UNHOLD' EXIT
CLEAN() { UNHOLD
          scratch_rm "$ST" 2>/dev/null; mkdir -p "$ST"
          scratch_rm "$H/locks" 2>/dev/null; mkdir -p "$H/locks"
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          rm -f "$T/slow7" "$T/slowpost7" "$T/stubborn7" "$T/slept7"; : > "$T/run.log"
          : > "$T/alerts.txt"; : > "$LOGF"; : > "$ROWS"; RUNARGS=(p1); }

LEDGER="$ST/.row-carry-p1.tsv"
# AT <pattern> — the first log line number that matches, or 0.
AT() { local n; n=$(grep -nE "$1" "$LOGF" 2>/dev/null | head -1 | cut -d: -f1); printf '%s' "${n:-0}"; }
TICKLINE() { grep 'tick: candidates=' "$LOGF" | tail -1; }

# ============================================================================
# 0. CALIBRATION. One uncapped tick of the two fast rows. Every time bound of
#    this file is a multiple of its wall time W, never an absolute number.
# ============================================================================
CAP=0
CLEAN
ROWADD 7; ROWADD 8
S0=$SECONDS; RUN BR_ROW_MAX_SECS=0; S1=$SECONDS
W=$((S1 - S0)); [ "$W" -ge 1 ] || W=1
CAP=$((W * 3 / 2 + 5)); BOUND=$((2 * W + CAP + 15)); SLOW=$((BOUND + CAP))
echo "br-row-cap.bh-9468: calibration W=${W}s CAP=${CAP}s BOUND=${BOUND}s SLOW=${SLOW}s"
DISPATCHED 7 && DISPATCHED 8 && ok || bad "0: the uncapped calibration tick dispatches #7 and #8 (the rig is wrong; $(TICKLINE))"

# ============================================================================
# A + B. THE BUG. #7's read phase sleeps SLOW. The cap stops it at CAP, says
#    so, and #8 still gets its rung in the same tick.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
printf '%s\n' "$SLOW" > "$T/slow7"
S0=$SECONDS; RUN; S1=$SECONDS
[ "$((S1 - S0))" -lt "$BOUND" ] && ok || bad "A: THE BUG: the run waited on #7's slow read ($((S1 - S0)) s; the cap is $CAP s, the bound $BOUND s)"
grep -q 'row cap: p1/o-p1-7 carried' "$LOGF" && ok \
  || bad "A: THE BUG: no 'row cap: p1/o-p1-7 carried' line (log: $(LOG | grep -E 'o-p1-7|row cap' | head -4))"
grep -q 'pre' "$T/slept7" 2>/dev/null && ok || bad "A: the stub's slow read of #7 ran (the rig is wrong)"
DISPATCHED 7 && bad "A: #7 must take no rung this tick" || ok
grep -q 'EVENT .*p1-TK-7' "$LOGF" && bad "A: #7 wrote no event ($(grep 'EVENT .*p1-TK-7' "$LOGF" | head -2))" || ok
CL=$(AT 'row cap: p1/o-p1-7 carried'); D8=$(AT 'p1/o-p1-8 \[[^]]*\] -> ')
[ "$CL" -gt 0 ] && [ "$D8" -gt "$CL" ] && ok \
  || bad "B: #8 is dispatched after #7's carry line (carry at $CL, #8 at $D8)"
TICKLINE | grep -qE ' rungs=1/' && ok || bad "B: the tick counts #8's rung only ($(TICKLINE))"
grep -qP '^p1\to-p1-7\t1$' "$LEDGER" 2>/dev/null && ok || bad "A: the carry ledger holds p1/o-p1-7 count 1 ($(cat "$LEDGER" 2>/dev/null))"
pgrep -f "$T/fakebin" >/dev/null 2>&1 && bad "A: a process of the stopped row is left ($(pgrep -af "$T/fakebin" | head -2))" || ok

# ============================================================================
# C. A row past its dispatch line (br_cron_unlock, the first rung) runs CAP+5
#    s and is NOT stopped.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
printf '%s\n' "$((CAP + 5))" > "$T/slowpost7"
RUN
grep -q 'post' "$T/slept7" 2>/dev/null && ok || bad "C: the stub's slow post-dispatch read of #7 ran (the rig is wrong)"
grep -q 'row cap:' "$LOGF" && bad "C: a committed row must not be stopped ($(grep 'row cap:' "$LOGF"))" || ok
grep -q 'EVENT resolver_setup_blocked p1/p1-TK-7' "$LOGF" && ok \
  || bad "C: #7's rung ran to its end (log: $(LOG | grep 'p1-TK-7\|o-p1-7' | tail -3))"
TICKLINE | grep -qE ' rungs=2/' && ok || bad "C: both rows took their rung ($(TICKLINE))"
[ -s "$LEDGER" ] && bad "C: nothing is carried ($(cat "$LEDGER"))" || ok

# ============================================================================
# D. THE RACE, on the fragment alone. The watchdog holds $BRRC_DIR/lock and has
#    written `capped`. The row's first wrapped writer waits on the lock, then
#    finds `capped`: the writer body never runs and the row ends 143.
# ============================================================================
(
  say() { printf '%s\n' "$*" >> "$T/d-say.txt"; }
  br_record() { printf 'wrote\n' >> "$T/d-record.txt"; }
  # shellcheck source=bin/blocked-resolver.d/bh-9468-row-cap.sh
  . "$FRAG" || exit 9
  _brrc_wrap
  BRRC_DIR="$T/d-dir"; mkdir -p "$BRRC_DIR"
  ( exec 7>"$BRRC_DIR/lock"; flock -x 7; : > "$T/d-held"; sleep 1; printf '2\n' > "$BRRC_DIR/capped" ) &
  HP=$!
  for _ in $(seq 1 50); do [ -e "$T/d-held" ] && break; sleep 0.1; done
  ( brrc_row_pid; br_record x; printf 'after\n' >> "$T/d-record.txt" ); RC=$?
  wait "$HP"
  printf '%s\n' "$RC" > "$T/d-rc"
) 2>>"$T/d-err.txt"
[ "$(cat "$T/d-rc" 2>/dev/null)" = 143 ] && ok || bad "D: the row ends 143 when the cap won the lock (rc $(cat "$T/d-rc" 2>/dev/null); $(head -2 "$T/d-err.txt"))"
[ -s "$T/d-record.txt" ] && bad "D: the writer body must not run after the cap ($(cat "$T/d-record.txt"))" || ok
# The other order: the row commits first, so the watchdog leaves it alone.
(
  say() { :; }
  br_record() { printf 'wrote\n' >> "$T/d2-record.txt"; }
  . "$FRAG" || exit 9
  _brrc_wrap
  BRRC_DIR="$T/d2-dir"; mkdir -p "$BRRC_DIR"
  ( brrc_row_pid; br_record x ); printf '%s\n' "$?" > "$T/d2-rc"
  [ -e "$BRRC_DIR/committed" ] && printf 'committed\n' >> "$T/d2-rc"
) 2>/dev/null
[ "$(tr '\n' ' ' < "$T/d2-rc" 2>/dev/null)" = "0 committed " ] && ok \
  || bad "D: a row that writes first commits and runs its writer ($(tr '\n' ' ' < "$T/d2-rc" 2>/dev/null), $(cat "$T/d2-record.txt" 2>/dev/null))"
# Outside an armed row the wrapper is a no-op.
(
  br_record() { printf 'wrote\n' >> "$T/d3-record.txt"; }
  . "$FRAG" || exit 9
  _brrc_wrap; unset BRRC_DIR; br_record x
) 2>/dev/null
[ "$(cat "$T/d3-record.txt" 2>/dev/null)" = wrote ] && ok || bad "D: an unarmed br_record runs as before"

# ============================================================================
# E. No starvation. Tick 1 carries #7. Tick 2 runs it uncapped: its CAP+5 s
#    read is not stopped, it gets its rung, and the ledger drops it.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
printf '%s\n' "$SLOW" > "$T/slow7"
RUN
grep -qP '^p1\to-p1-7\t1$' "$LEDGER" 2>/dev/null && ok || bad "E: tick 1 carries #7 with count 1 ($(cat "$LEDGER" 2>/dev/null))"
: > "$LOGF"; rm -f "$T/slept7"
printf '%s\n' "$((CAP + 5))" > "$T/slow7"
RUN
grep -q 'row cap: p1/o-p1-7 runs uncapped this tick' "$LOGF" && ok \
  || bad "E: tick 2 says #7 runs uncapped (log: $(LOG | grep -E 'row cap|o-p1-7' | head -3))"
grep -q 'pre' "$T/slept7" 2>/dev/null && ok || bad "E: the CAP+5 s read ran in tick 2 (the rig is wrong)"
DISPATCHED 7 && ok || bad "E: #7 gets its rung in tick 2 (log: $(LOG | grep -E 'o-p1-7' | head -3))"
grep -q 'row cap: p1/o-p1-7 carried' "$LOGF" && bad "E: #7 is not carried twice" || ok
grep -q 'o-p1-7' "$LEDGER" 2>/dev/null && bad "E: the ledger drops #7 once it ran ($(cat "$LEDGER"))" || ok

# ============================================================================
# F. The cap off (0), a bad value (abc = the 120 s default) and a one-PR run:
#    #7's 4 s read is never stopped.
# ============================================================================
for V in 0 abc; do
  CLEAN
  ROWADD 7; ROWADD 8
  printf '4\n' > "$T/slow7"
  RUN BR_ROW_MAX_SECS="$V"
  grep -q 'pre' "$T/slept7" 2>/dev/null && ok || bad "F($V): the 4 s read ran (the rig is wrong)"
  grep -q 'row cap: .*carried' "$LOGF" && bad "F($V): no row is stopped ($(grep 'row cap:' "$LOGF"))" || ok
  DISPATCHED 7 && ok || bad "F($V): #7 is dispatched (log: $(LOG | grep -E 'o-p1-7' | head -3))"
  [ -e "$LEDGER" ] && [ -s "$LEDGER" ] && bad "F($V): nothing is carried ($(cat "$LEDGER"))" || ok
done
NB=$(grep -c "row cap: BR_ROW_MAX_SECS='abc' is not a non-negative integer — the cap is 120 s" "$LOGF")
[ "$NB" = 1 ] && ok || bad "F(abc): exactly one fallback line ($NB; $(grep 'row cap' "$LOGF" | head -3))"
CLEAN
ROWADD 7; ROWADD 8
printf '4\n' > "$T/slow7"
RUN BR_ONLY_PR='o/p1#7'
grep -q 'row cap: .*carried' "$LOGF" && bad "F(one-PR): a one-PR run is not capped ($(grep 'row cap:' "$LOGF"))" || ok
DISPATCHED 7 && ok || bad "F(one-PR): #7 is dispatched (log: $(LOG | grep -E 'o-p1-7' | head -3))"
[ -e "$LEDGER" ] && bad "F(one-PR): a one-PR run writes no ledger" || ok

# ============================================================================
# G. A read that ignores TERM is KILLed after BR_ROW_KILL_GRACE_SECS=1.
# ============================================================================
CLEAN
ROWADD 7; ROWADD 8
printf '%s\n' "$SLOW" > "$T/slow7"; : > "$T/stubborn7"
S0=$SECONDS; RUN; S1=$SECONDS
[ "$((S1 - S0))" -lt "$BOUND" ] && ok || bad "G: the run did not wait on the stubborn read ($((S1 - S0)) s, the bound $BOUND s)"
grep -q 'row cap: p1/o-p1-7 carried' "$LOGF" && ok || bad "G: #7 is carried (log: $(LOG | grep -E 'o-p1-7|row cap' | head -3))"
DISPATCHED 8 && ok || bad "G: #8 is dispatched (log: $(LOG | grep 'o-p1-8 ' | head -2))"
pgrep -f "$T/fakebin/brrc-g-sleep" >/dev/null 2>&1 \
  && { bad "G: the stubborn read is left alive ($(pgrep -af "$T/fakebin/brrc-g-sleep" | head -1))"; pkill -9 -f "$T/fakebin/brrc-g-sleep"; } || ok

# ============================================================================
# H. Retention: a ledger entry whose row is not a candidate drops out; an
#    entry for a row this tick ran to its end drops out too.
# ============================================================================
CLEAN
ROWADD 8
printf 'p1\to-p1-99\t1\np1\to-p1-8\t1\n' > "$LEDGER"
RUN
DISPATCHED 8 && ok || bad "H: #8 is dispatched"
grep -q 'o-p1-99' "$LEDGER" 2>/dev/null && bad "H: the entry for a row that is not a candidate is gone ($(cat "$LEDGER"))" || ok
grep -q 'o-p1-8' "$LEDGER" 2>/dev/null && bad "H: the entry for #8, which ran, is gone ($(cat "$LEDGER"))" || ok

# ============================================================================
# I. On the fragment alone. A hopped rung (BR_FIX_HERE=1) is not armed. A
#    ledger that cannot be written says one line and the tick goes on.
# ============================================================================
(
  say() { printf '%s\n' "$*" >> "$T/i-say.txt"; }
  . "$FRAG" || exit 9
  ST="$T/i-st"; ONLY=p1; mkdir -p "$ST"
  BR_FIX_HERE=1 BR_ROW_MAX_SECS=2 brrc_row_begin p1 o-p1-7
  printf 'dir=%s wpid=%s\n' "${BRRC_DIR:-}" "${BRRC_WPID:-}" > "$T/i-armed.txt"
  BRRC_CARRY[p1$'\t'o-p1-7]=1
  CANDS=("conductor"$'\t'"p1"$'\t'"o-p1-7")
  BRRC_FILE="$T/i-no-such-dir/x.tsv"
  brrc_tick_end; printf '%s\n' "$?" > "$T/i-rc.txt"
) 2>/dev/null
[ "$(cat "$T/i-armed.txt" 2>/dev/null)" = "dir= wpid=" ] && ok || bad "I: BR_FIX_HERE=1 arms no watchdog ($(cat "$T/i-armed.txt" 2>/dev/null))"
[ "$(cat "$T/i-rc.txt" 2>/dev/null)" = 0 ] && ok || bad "I: a failed ledger write returns 0 (rc $(cat "$T/i-rc.txt" 2>/dev/null))"
NI=$(grep -c 'row cap: the carry ledger could not be written' "$T/i-say.txt" 2>/dev/null)
[ "$NI" = 1 ] && ok || bad "I: a failed ledger write says one line ($NI; $(cat "$T/i-say.txt" 2>/dev/null))"

echo "br-row-cap.bh-9468: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
