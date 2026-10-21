#!/bin/bash
# tests/lane-run-entrypoint-workers.bh-7716-test.sh — BH-7716 T3: the REAL
# fly/lane-run-entrypoint.sh with LANE_RUN_WORKERS=N starts N worker loops
# `--machine <FLY_MACHINE_ID>-w<i>`, forwards TERM and INT to each, restarts
# a loop that exits non-zero (at most 10 restarts an hour), and with N unset
# keeps today's single exec.
#
# The scratch tree's bin/lane-run-worker.sh is a stub: it logs `start <pid>
# <argv>`, logs `term <pid> <argv>` and exits 0 on TERM, and exits 1 at once
# when $T/fail-<id> exists (<id> = the w<i> suffix) or 0 when $T/zero-<id>
# exists. Required env (HARNESS_SECRET, JOBS_URL, FLY_MACHINE_ID) are dummies.
#
#   E1  N=3: 3 loops, ids mid-w1..mid-w3, no --box; TERM to the entrypoint
#       reaches all 3, it exits 0, no loop is left
#   E2  N unset: one exec, argv `--machine mid`, the entrypoint pid is the
#       worker pid; N=1, N=abc, N=17 and N=08 do the same
#   E3  LANE_RUN_BOX=fly-dedicated: --box fly-dedicated on every loop and on
#       the single exec
#   E4  a loop that always exits 1: restarted 10 times, then the other loops
#       get TERM and the entrypoint exits 1
#   E5  a loop that exits 0 is not restarted; INT to the entrypoint reaches
#       the loops as TERM (a background job of a script starts with INT
#       ignored, and the worker treats TERM and INT the same)
#   E6  LANE_RUN_RESTART_SLEEP_S is honoured only with HARNESS_TEST_SANDBOX=1:
#       without it the restart waits 5 s, and a TERM in that wait exits 0
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lane-run-entrypoint-workers.bh-7716-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v timeout >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || { echo "SKIP: timeout or python3 missing"; exit 0; }

E="$T/e"; mkdir -p "$E/bin/lib" "$E/env" "$T/home"
( cd "$REPO" && scratch_install_closure fly/lane-run-entrypoint.sh "$E" ) >/dev/null 2>&1 || bad "setup: closure"
cat > "$E/bin/lane-run-worker.sh" <<EOF
#!/bin/bash
id=""; a=("\$@"); for ((k = 0; k < \${#a[@]}; k++)); do [ "\${a[k]}" = --machine ] && id="\${a[k+1]##*-}"; done
echo "start \$\$ \$*" >> "$T/ew.log"
trap 'echo "term \$\$ \$*" >> "$T/ew.log"; exit 0' TERM
trap 'echo "int \$\$ \$*" >> "$T/ew.log"; exit 0' INT
[ -e "$T/fail-\$id" ] && exit 1
[ -e "$T/zero-\$id" ] && exit 0
i=0; while [ "\$i" -lt 600 ]; do sleep 0.1; i=\$((i+1)); done
exit 0
EOF
chmod +x "$E/bin/lane-run-worker.sh"
WAITFOR() { local i; for i in $(seq 1 "${2:-100}"); do eval "$1" && return 0; sleep 0.1; done; return 1; }
# A background job of this suite starts with INT ignored, and bash cannot trap
# a signal ignored at entry. Fly starts the entrypoint with INT at its default,
# so the launcher puts INT back to the default before it runs bash.
UNIGNORE='import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])'
# ep [VAR=value...] — the entrypoint in the background, a clean env. EP = its pid.
ep() {
  : > "$T/ew.log"
  env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-hs JOBS_URL=http://192.0.2.1 \
    FLY_MACHINE_ID=mid "$@" timeout -s KILL 120 python3 -c "$UNIGNORE" bash "$E/fly/lane-run-entrypoint.sh" > "$T/ep.out" 2>&1 &
  EP=$!
}
# ep_exec — the entrypoint must replace its process: no timeout wrapper here,
# so $! is the bash that runs the entrypoint.
ep_exec() {
  : > "$T/ew.log"
  env -i PATH="$PATH" HOME="$T/home" HARNESS="$E" ETC_HARNESS_ENV="$T/no-etc" HARNESS_SECRET=fixture-hs JOBS_URL=http://192.0.2.1 \
    FLY_MACHINE_ID=mid "$@" bash "$E/fly/lane-run-entrypoint.sh" > "$T/ep.out" 2>&1 &
  EP=$!
}
starts() { grep -c '^start ' "$T/ew.log"; }
alive() { local p n=0; for p in $(sed -n 's/^start \([0-9]*\) .*/\1/p' "$T/ew.log"); do kill -0 "$p" 2>/dev/null && n=$((n+1)); done; echo "$n"; }
# the entrypoint runs under timeout (pid EP); signal the bash below it.
epsh() { pgrep -P "$EP" -f lane-run-entrypoint.sh | head -1; }

# ============================================================================
echo "E1: N=3 starts 3 loops; TERM reaches all 3"
ep LANE_RUN_WORKERS=3
WAITFOR '[ "$(starts)" = 3 ]' || bad "E1 setup: $(starts) starts: $(cat "$T/ew.log" "$T/ep.out")"
for i in 1 2 3; do
  grep -qE "^start [0-9]+ --machine mid-w$i\$" "$T/ew.log" && ok "E1 loop w$i: --machine mid-w$i" || bad "E1 w$i: $(cat "$T/ew.log")"
done
[ "$(sed -n 's/^start \([0-9]*\) .*/\1/p' "$T/ew.log" | sort -u | wc -l)" = 3 ] && ok "E1 3 distinct pids" || bad "E1 pids: $(cat "$T/ew.log")"
S=$(epsh); kill -TERM "$S"; wait "$EP"; rc=$?
[ "$rc" = 0 ] && ok "E1 the entrypoint exits 0 after TERM" || bad "E1 rc=$rc $(cat "$T/ep.out")"
[ "$(grep -c '^term ' "$T/ew.log")" = 3 ] && ok "E1 TERM reached all 3 loops" || bad "E1 log: $(cat "$T/ew.log")"
[ "$(alive)" = 0 ] && ok "E1 no loop is left" || bad "E1 $(alive) loops alive"

# ============================================================================
echo "E2: N unset, 1 or invalid: today's single exec"
for n in unset 1 abc 17 08 0; do
  if [ "$n" = unset ]; then ep_exec; else ep_exec LANE_RUN_WORKERS="$n"; fi
  WAITFOR '[ "$(starts)" -ge 1 ]' || bad "E2 N=$n: no start: $(cat "$T/ep.out")"
  sleep 0.3
  L=$(head -1 "$T/ew.log")
  [ "$(starts)" = 1 ] && [ "$L" = "start $EP --machine mid" ] && ok "E2 N=$n: one exec, the entrypoint pid, argv --machine mid" \
    || bad "E2 N=$n: '$L' (entrypoint pid $EP) $(starts) starts"
  kill -TERM "$EP"; wait "$EP"
done

# ============================================================================
echo "E3: LANE_RUN_BOX passes --box"
ep LANE_RUN_WORKERS=2 LANE_RUN_BOX=fly-dedicated
WAITFOR '[ "$(starts)" = 2 ]' || bad "E3 setup: $(cat "$T/ew.log")"
[ "$(grep -cE '^start [0-9]+ --machine mid-w[12] --box fly-dedicated$' "$T/ew.log")" = 2 ] && ok "E3 both loops get --box fly-dedicated" \
  || bad "E3 log: $(cat "$T/ew.log")"
kill -TERM "$(epsh)"; wait "$EP"
ep_exec LANE_RUN_BOX=fly-dedicated
WAITFOR '[ "$(starts)" -ge 1 ]' || bad "E3 exec: no start"
[ "$(head -1 "$T/ew.log")" = "start $EP --machine mid --box fly-dedicated" ] && ok "E3 the single exec gets --box too" \
  || bad "E3 exec: $(head -1 "$T/ew.log") (pid $EP)"
kill -TERM "$EP"; wait "$EP"

# ============================================================================
echo "E4: the restart cap"
: > "$T/fail-w1"
ep LANE_RUN_WORKERS=3 HARNESS_TEST_SANDBOX=1 LANE_RUN_RESTART_SLEEP_S=0
wait "$EP"; rc=$?
[ "$rc" = 1 ] && ok "E4 the entrypoint exits 1" || bad "E4 rc=$rc $(cat "$T/ep.out")"
[ "$(grep -cE '^start [0-9]+ --machine mid-w1$' "$T/ew.log")" = 11 ] && ok "E4 w1 started 1 + 10 restarts = 11 times" \
  || bad "E4 w1 starts: $(grep -c 'mid-w1' "$T/ew.log")"
[ "$(grep -cE '^start [0-9]+ --machine mid-w[23]$' "$T/ew.log")" = 2 ] && ok "E4 w2 and w3 started once each" || bad "E4 log: $(cat "$T/ew.log")"
[ "$(grep -cE '^term [0-9]+ --machine mid-w[23]$' "$T/ew.log")" = 2 ] && ok "E4 w2 and w3 got TERM" || bad "E4 terms: $(grep term "$T/ew.log")"
grep -q 'restart' "$T/ep.out" && ok "E4 stderr names the restart cap" || bad "E4 out: $(cat "$T/ep.out")"
[ "$(alive)" = 0 ] && ok "E4 no loop is left" || bad "E4 $(alive) alive"
rm -f "$T/fail-w1"

# ============================================================================
echo "E5: a loop that exits 0 is not restarted; INT is forwarded"
: > "$T/zero-w2"
ep LANE_RUN_WORKERS=2 HARNESS_TEST_SANDBOX=1 LANE_RUN_RESTART_SLEEP_S=0
WAITFOR '[ "$(starts)" = 2 ]' || bad "E5 setup: $(cat "$T/ew.log")"
sleep 1
[ "$(grep -c 'mid-w2' "$T/ew.log")" = 1 ] && ok "E5 w2 exited 0 and was not restarted" || bad "E5 log: $(cat "$T/ew.log")"
kill -INT "$(epsh)"; wait "$EP"; rc=$?
[ "$rc" = 0 ] && grep -qE '^term [0-9]+ --machine mid-w1$' "$T/ew.log" && ok "E5 INT reached w1 as TERM, exit 0" || bad "E5 rc $rc: $(cat "$T/ew.log")"
rm -f "$T/zero-w2"

# ============================================================================
echo "E6: the restart sleep seam needs HARNESS_TEST_SANDBOX=1"
: > "$T/fail-w1"
ep LANE_RUN_WORKERS=2 LANE_RUN_RESTART_SLEEP_S=0
WAITFOR '[ "$(starts)" = 2 ]' || bad "E6 setup: $(cat "$T/ew.log")"
WAITFOR 'grep -q "loop w1 exited [0-9]*; restart 1 of 10 this hour in 5s" "$T/ep.out"' \
  && ok "E6 the restart wait is 5 s (the seam is off)" || bad "E6 ep.out: $(cat "$T/ep.out")"
[ "$(grep -c 'mid-w1' "$T/ew.log")" = 1 ] && ok "E6 w1 is not restarted in the 5 s wait" || bad "E6 log: $(cat "$T/ew.log")"
kill -TERM "$(epsh)"; wait "$EP"; rc=$?
[ "$rc" = 0 ] && grep -qE '^term [0-9]+ --machine mid-w2$' "$T/ew.log" && ok "E6 TERM in the restart wait: w2 got TERM, exit 0" || bad "E6 rc $rc: $(cat "$T/ew.log")"
[ "$(grep -c 'mid-w1' "$T/ew.log")" = 1 ] && ok "E6 w1 was not restarted after TERM" || bad "E6 log: $(cat "$T/ew.log")"
rm -f "$T/fail-w1"

echo
echo "lane-run-entrypoint-workers.bh-7716: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
