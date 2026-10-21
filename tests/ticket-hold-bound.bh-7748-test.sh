#!/bin/bash
# tests/ticket-hold-bound.bh-7748-test.sh — BH-7748: the merge conductor's
# ticket-hold step is bounded, and a kill in it names the call in flight.
#
# Sentry CROMFORD-HARNESS-N: a worker was killed at its 600 s deadline in step
# ticket-hold, and the event named the step but no call. to_lane_hold
# (bin/lib/ticket-ownership.sh) ran to_merge_hold's five network reads with no
# bound and no call file.
#
#   H1  a hung PR-thread read ends at MC_TICKET_HOLD_TIMEOUT_S: rc 0 (held), one
#       TICKET_HOLD_TIMEOUT line with call, PR key, took and rc=124; no alert
#   H2  a fast clear answer is rc 1; a fast held answer keeps its own why
#   H3  knob unset, 0 or not a number: no bound, the slow read completes
#   H4  no stub process is left after a timeout
#   H5  to__hold_bound_s over every row of the decision table
#   H6  a check that answers clear AFTER the bound fired is still held
#   H7  two real bounded workers: one hangs, the other still reaches `done`
#   H8  a `sleep` that returns at once (a stub on PATH) does not end the bound
#   C1  to__call writes the 5-field BH-7029 call line
#   C2  a hung token mint names `auth`; a hung ticket read names `ticket-thread`
#   C3  the conductor's call file after the answer: clear empty, held hold-note
#   D1  a real deadline kill in ticket-hold: the Sentry tags carry call and PR
#   D2  the WORKER_DEADLINE line carries ` | call: ticket-hold/pr-thread (`
#   D3  a deadline kill with no call: no call tag, no call segment, same title
#   K1  lane_env_apply merge-conductor gives MC_TICKET_HOLD_TIMEOUT_S=90
#
# Every network read is a stub function: 0 vendor calls. A hang is a stub
# `sleep 30.7748N` (N per case), so H4 can look for its own leftovers.
#
# Run from anywhere: tests/ticket-hold-bound.bh-7748-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }

TOL="$REPO/bin/lib/ticket-ownership.sh"
FANIN="$REPO/bin/lib/fanin.sh"
HEAD=6a7867e3ff00000000000000000000000000beef

# The stubs every case starts from: every read answers clear, fast.
STUBS='
gh_auth_for() { :; }
hold_check_thread() { printf "clear\tno hold on the PR\n"; return 0; }
hold_check() { printf "clear\tno hold on the ticket\n"; }
hold_is_pause() { case "$1" in pause*) return 0 ;; esac; return 1; }
hold_is_abandon() { return 1; }
gh_rest() { printf "%s" "{\"user\":{\"login\":\"dev-fixture\"},\"body\":\"Closes #5\",\"head\":{\"ref\":\"ticket/x\"}}"; }
setting_get() { printf "lead-fixture\n"; }
_mc_fanin_alert() { echo alert >> "$c/alerts"; }
sentry_report() { echo sentry >> "$c/alerts"; }
'

# mk_h <dir> — a scratch harness whose fleet-conf says the project's tickets
# are GitHub issues (board_prefix -), so to_merge_hold reads the ticket too.
mk_h() {
  mkdir -p "$1/h/bin" "$1/h/logs"
  printf '%s\n' '#!/bin/bash' 'case "$2" in board_prefix) echo - ;; repo) echo o/issues ;; esac' > "$1/h/bin/fleet-conf.sh"
  chmod +x "$1/h/bin/fleet-conf.sh"
  : > "$1/log"; : > "$1/alerts"
}

# hold_case <name> <num> <stub overrides> [env...] — one to_lane_hold call in a
# fresh shell with only ticket-ownership.sh loaded. Leaves rc, took (seconds),
# log (mc_log lines), alerts and out in $T/<name>.
hold_case() {
  local c="$T/$1" num="$2" setup="$3" t0; shift 3
  mk_h "$c"
  t0=$SECONDS
  env "$@" HARNESS="$c/h" bash -c '
    c=$1; . "$2" || exit 1
    mc_log() { printf "%s\n" "$*" >> "$c/log"; }
    eval "$3"; eval "$4"
    to_lane_hold P o/r "$5"; echo "$?" > "$c/rc"
  ' _ "$c" "$TOL" "$STUBS" "$setup" "$num" > "$c/out" 2>&1
  echo $((SECONDS - t0)) > "$c/took"
}
rc()   { cat "$T/$1/rc" 2>/dev/null; }
took() { cat "$T/$1/took" 2>/dev/null; }

# ---- H1 a hung PR-thread read ends at the bound, held --------------------------
hold_case h1 71 'hold_check_thread() { sleep 30.77481; }' MC_TICKET_HOLD_TIMEOUT_S=2   # determinism: ok the stub IS the hung read the bound cuts
[ "$(rc h1)" = 0 ] && ok "H1 rc 0 (held)" || bad "H1 rc: $(rc h1) $(cat "$T/h1/out")"
[ "$(took h1)" -le 7 ] && ok "H1 ended in $(took h1)s (<= 7)" || bad "H1 took $(took h1)s"
grep -Eq '^o/r#71 TICKET_HOLD_TIMEOUT call=ticket-hold/pr-thread took=[2-6]s timeout=2s rc=124: ' "$T/h1/log" \
  && ok "H1 TICKET_HOLD_TIMEOUT line names call, PR, took, rc" || bad "H1 log: $(cat "$T/h1/log")"
[ "$(grep -c TICKET_HOLD_TIMEOUT "$T/h1/log")" = 1 ] && ok "H1 one timeout line" || bad "H1 timeout lines: $(cat "$T/h1/log")"
grep -q '^o/r#71 MERGE_HELD: the hold check timed out (call pr-thread)' "$T/h1/log" \
  && ok "H1 MERGE_HELD names the call" || bad "H1 MERGE_HELD: $(cat "$T/h1/log")"
[ ! -s "$T/h1/alerts" ] && ok "H1 no alert, no Sentry event" || bad "H1 alerts: $(cat "$T/h1/alerts")"

# ---- H4 nothing of the hung stub is left -------------------------------------
left=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -f '30[.]77481' >/dev/null 2>&1 || { left=0; break; }
  sleep 0.5   # determinism: ok a bounded poll for the condition, not a race
done
[ "$left" = 0 ] && ok "H4 no stub sleep left after the timeout" || bad "H4 left: $(pgrep -af '30[.]77481')"

# ---- H2 fast answers keep today's result -------------------------------------
hold_case h2a 72 ':' MC_TICKET_HOLD_TIMEOUT_S=5
[ "$(rc h2a)" = 1 ] && ok "H2 fast clear: rc 1" || bad "H2 clear rc: $(rc h2a) $(cat "$T/h2a/out" "$T/h2a/log")"
! grep -q TICKET_HOLD_TIMEOUT "$T/h2a/log" && ok "H2 clear: no timeout line" || bad "H2 clear log: $(cat "$T/h2a/log")"
hold_case h2b 73 'hold_check() { printf "pause\tHOLD by fixture-user\n"; }' MC_TICKET_HOLD_TIMEOUT_S=5
[ "$(rc h2b)" = 0 ] && ok "H2 fast held: rc 0" || bad "H2 held rc: $(rc h2b) $(cat "$T/h2b/out")"
grep -q '^o/r#73 MERGE_HELD: ticket #5 is held (HOLD by fixture-user)' "$T/h2b/log" \
  && ok "H2 held: the original why" || bad "H2 held log: $(cat "$T/h2b/log")"

# ---- H3 no bound: a slow read completes ---------------------------------------
for v in unset 0 abc; do
  if [ "$v" = unset ]; then
    hold_case "h3$v" 74 'hold_check_thread() { sleep 3; printf "clear\tslow\n"; return 0; }' MC_WORKER_DEADLINE_AT=   # determinism: ok a slow read that must NOT be cut
  else
    hold_case "h3$v" 74 'hold_check_thread() { sleep 3; printf "clear\tslow\n"; return 0; }' MC_TICKET_HOLD_TIMEOUT_S="$v"   # determinism: ok a slow read that must NOT be cut
  fi
  [ "$(rc "h3$v")" = 1 ] && ok "H3 knob $v: the slow clear answer stands (rc 1)" || bad "H3 knob $v rc: $(rc "h3$v") $(cat "$T/h3$v/log")"
  ! grep -q TICKET_HOLD_TIMEOUT "$T/h3$v/log" && ok "H3 knob $v: no timeout line" || bad "H3 knob $v log: $(cat "$T/h3$v/log")"
done

# ---- H5 the bound's decision table ---------------------------------------------
NOW=1760000000
bound() {
  env -u MC_TICKET_HOLD_TIMEOUT_S -u MC_WORKER_DEADLINE_AT "$@" TO_HOLD_NOW=$NOW bash -c '
    . "$1" || exit 1; b=$(to__hold_bound_s); echo "$?:$b"' _ "$TOL" 2>&1
}
while IFS='|' read -r knob at want; do
  args=()
  [ "$knob" = - ] || args+=("MC_TICKET_HOLD_TIMEOUT_S=$knob")
  case "$at" in -) ;; soon) args+=("MC_WORKER_DEADLINE_AT=soon") ;; *) args+=("MC_WORKER_DEADLINE_AT=$((NOW + at))") ;; esac
  got=$(bound "${args[@]}")
  [ "$got" = "$want" ] && ok "H5 knob '$knob' deadline '$at' -> $want" || bad "H5 knob '$knob' deadline '$at': want $want, got $got"
done <<'EOF'
-|-|0:0
0|600|0:0
abc|-|0:0
-5|-|0:0
 90|-|0:0
1e3|-|0:0
090|-|0:90
90|-|0:90
90|600|0:90
90|45|0:30
90|16|0:1
90|15|1:
90|soon|0:90
EOF
hold_case h5x 75 'hold_check_thread() { echo called > "$c/called"; return 0; }' MC_TICKET_HOLD_TIMEOUT_S=90 MC_WORKER_DEADLINE_AT=1
[ "$(rc h5x)" = 0 ] && ok "H5 no time left: held" || bad "H5 no time left rc: $(rc h5x)"
[ ! -e "$T/h5x/called" ] && ok "H5 no time left: no read started" || bad "H5 no time left: a read ran"
grep -q '^o/r#75 MERGE_HELD: no worker time left for the hold check' "$T/h5x/log" \
  && ok "H5 no time left: MERGE_HELD says why" || bad "H5 log: $(cat "$T/h5x/log")"

# ---- H6 a clear answer after the bound fired is still held -------------------
# TERM is ignored in the caller, so the check is not stopped by the TERM and
# answers clear after the bound: the timeout marker must win.
hold_case h6 76 'trap "" TERM; hold_check_thread() { sleep 2.5; printf "clear\tlate\n"; return 0; }' MC_TICKET_HOLD_TIMEOUT_S=1   # determinism: ok the late answer IS the race under test
[ "$(rc h6)" = 0 ] && ok "H6 a late clear answer is held (rc 0)" || bad "H6 rc: $(rc h6) $(cat "$T/h6/log")"
grep -Eq '^o/r#76 TICKET_HOLD_TIMEOUT call=ticket-hold/[a-z-]+ took=[0-9]+s timeout=1s rc=124' "$T/h6/log" && ok "H6 the timeout line" || bad "H6 log: $(cat "$T/h6/log")"

# ---- H8 the bound does not trust `sleep` ------------------------------------------
# tests/ticket-ownership.bh-1526-test.sh puts an `exit 0` sleep on PATH; a
# watchdog that slept with it held every PR at 0 s.
mkdir -p "$T/fakebin"; printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"
hold_case h8 70 'hold_check_thread() { read -rt 1 <> <(:); printf "clear\tno hold\n"; return 0; }' MC_TICKET_HOLD_TIMEOUT_S=5 PATH="$T/fakebin:$PATH"
[ "$(rc h8)" = 1 ] && ok "H8 a fake sleep: the 1 s clear answer stands (rc 1)" || bad "H8 rc: $(rc h8) $(cat "$T/h8/log")"
! grep -q TICKET_HOLD_TIMEOUT "$T/h8/log" && ok "H8 no timeout line" || bad "H8 log: $(cat "$T/h8/log")"

# ---- C1 the call line ----------------------------------------------------------------
c="$T/c1"; mkdir -p "$c"
TO_CALL_FILE="$c/call" bash -c '. "$1" || exit 1; to__call pr-read' _ "$TOL"
ct=""; cp=""; cw=""; cpid=""; ccs=""
IFS=$'\t' read -r ct cp cw cpid ccs < "$c/call" 2>/dev/null
[ "$(awk -F'\t' '{ print NF }' "$c/call")" = 5 ] && ok "C1 five tab fields" || bad "C1 fields: $(cat -A "$c/call")"
[[ "$ct" =~ ^[0-9]+$ ]] && [ "$cp" = ticket-hold/pr-read ] && [ "$cw" = r ] && [[ "$cpid" =~ ^[0-9]+$ ]] && [[ "$ccs" =~ ^[0-9]+$ ]] \
  && ok "C1 epoch, path, r, pid, centiseconds" || bad "C1 line: $(cat "$c/call")"
bash -c '. "$1" || exit 1; to__call pr-read' _ "$TOL" && ok "C1 no TO_CALL_FILE: a no-op, rc 0" || bad "C1 no-op rc"

# ---- C2 the other calls are named ---------------------------------------------
hold_case c2a 77 'gh_auth_for() { sleep 30.77482; }' MC_TICKET_HOLD_TIMEOUT_S=1   # determinism: ok the stub IS the hung token mint
grep -q '^o/r#77 TICKET_HOLD_TIMEOUT call=ticket-hold/auth ' "$T/c2a/log" && ok "C2 hung mint: call auth" || bad "C2 auth log: $(cat "$T/c2a/log")"
hold_case c2b 78 'hold_check() { sleep 30.77483; }' MC_TICKET_HOLD_TIMEOUT_S=1   # determinism: ok the stub IS the hung ticket read
grep -q '^o/r#78 TICKET_HOLD_TIMEOUT call=ticket-hold/ticket-thread ' "$T/c2b/log" && ok "C2 hung ticket read: call ticket-thread" || bad "C2 ticket log: $(cat "$T/c2b/log")"
hold_case c2c 79 'gh_rest() { sleep 30.77484; }' MC_TICKET_HOLD_TIMEOUT_S=1   # determinism: ok the stub IS the hung PR read
grep -q '^o/r#79 TICKET_HOLD_TIMEOUT call=ticket-hold/pr-read ' "$T/c2c/log" && ok "C2 hung PR read: call pr-read" || bad "C2 pr-read log: $(cat "$T/c2c/log")"

# ---- C3 the conductor's call file after the answer -------------------------------
for k in clear:ticket-hold:empty held:ticket-hold:hold-note held:enqueue:empty; do
  IFS=: read -r ans step want <<<"$k"
  setup=':'; [ "$ans" = held ] && setup='hold_check() { printf "pause\tHOLD by fixture-user\n"; }'
  n="c3$ans$step"; mkdir -p "$T/$n"; printf 'stale\tprequeue/x\tr\t1\t1\n' > "$T/$n/mcall"
  hold_case "$n" 80 "$setup; MC_CALL_FILE=\$c/mcall; MC_STEP_NAME=$step" MC_TICKET_HOLD_TIMEOUT_S=5
  got=$(cut -f2 "$T/$n/mcall" 2>/dev/null); [ -n "$got" ] || got=empty
  [ "$got" = "$want" ] || { [ "$want" = hold-note ] && [ "$got" = ticket-hold/hold-note ]; } \
    && ok "C3 $ans in step $step: call file $want" || bad "C3 $ans in step $step: want $want, got '$got'"
done

# ---- the real bounded worker: fanin.sh + ticket-ownership.sh ---------------------
# run_worker <name> <num> <stub overrides> [env...] — one mc_worker_bounded +
# mc_fanin_outcome per row, the rows run in parallel. pr_worker is the
# conductor's ticket-hold step: mc_step ticket-hold; to_lane_hold; mc_step done.
run_worker() {
  local c="$T/$1" nums="$2" setup="$3"; shift 3
  mk_h "$c"; mkdir -p "$c/state"; : > "$c/ev"; : > "$c/attempts"
  env "$@" HARNESS="$c/h" bash -c '
    c=$1; . "$2" || exit 1; . "$3" || exit 1
    SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1 MC_LOG="$c/lanelog" MC_FANIN_T0=0
    : > "$MC_LOG"
    eval "$4"; eval "$5"
    mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9._-]/_}"; }
    mc_log() { printf "%s\n" "$*" >> "$c/log"; }
    mc_attempt_has() { grep -qxF "$1" "$c/attempts"; }
    mc_attempt_put() { printf "%s\n" "$1" >> "$c/attempts"; }
    mc_row_field() { echo QUEUED; }
    sentry_report() {
      jq -nc --arg level "$1" --arg reason "$3" --arg message "$4" \
        --argjson extra "${5:-null}" --argjson tags "${6:-null}" \
        "{level:\$level,reason:\$reason,message:\$message,extra:\$extra,tags:\$tags}" >> "$c/ev"
    }
    pr_worker() {
      local n="${1%%[[:space:]]*}"
      mc_step ticket-hold
      to_lane_hold P o/r "$n"; echo "$?" > "$c/rc-$n"
      mc_step done; echo done > "$c/done-$n"
    }
    for n in $6; do
      ( row=$(printf "%s\turl\t%s\tbr\tfalse\tCLEAN\t-" "$n" "$7")
        t0=$SECONDS
        mc_worker_bounded "$row"; mc_fanin_outcome $? "$row" > "$c/word-$n"
        echo $((SECONDS - t0)) > "$c/took-$n" ) &
    done
    wait
    ls "$c/state/worker-deadline" 2>/dev/null > "$c/left"
  ' _ "$c" "$FANIN" "$TOL" "$STUBS" "$setup" "$nums" "$HEAD" > "$c/out" 2>&1
}
ev() { jq -rc "$2" "$T/$1/ev" 2>/dev/null | head -1; }

# ---- H7 one PR hangs, the other still completes ----------------------------------
H7STUB='hold_check_thread() { if [ "$2" = 81 ]; then sleep 30.77485; fi; printf "clear\tno hold\n"; return 0; }'   # determinism: ok PR 81's stub IS the hung read
run_worker h7 "81 82" "$H7STUB" MC_WORKER_DEADLINE_S=30 MC_TICKET_HOLD_TIMEOUT_S=2 MC_STEP_TIMEOUT_S=0
[ -e "$T/h7/done-82" ] && ok "H7 PR 82 reached step done" || bad "H7 PR 82: $(cat "$T/h7/out" "$T/h7/log")"
[ "$(cat "$T/h7/rc-82" 2>/dev/null)" = 1 ] && ok "H7 PR 82 clear (rc 1)" || bad "H7 PR 82 rc: $(cat "$T/h7/rc-82" 2>/dev/null)"
[ "$(cat "$T/h7/rc-81" 2>/dev/null)" = 0 ] && ok "H7 PR 81 held (rc 0)" || bad "H7 PR 81 rc: $(cat "$T/h7/rc-81" 2>/dev/null)"
[ "$(cat "$T/h7/took-81" 2>/dev/null)" -le 10 ] && ok "H7 PR 81 ended in $(cat "$T/h7/took-81")s (<= 10)" || bad "H7 PR 81 took $(cat "$T/h7/took-81" 2>/dev/null)s"
[ ! -s "$T/h7/left" ] && ok "H7 no deadline mark" || bad "H7 marks: $(cat "$T/h7/left")"
grep -qx 'killed:deadline' "$T/h7/word-81" "$T/h7/word-82" && bad "H7 a worker was killed at its deadline" || ok "H7 neither outcome is killed:deadline"
[ ! -s "$T/h7/ev" ] && ok "H7 no Sentry event" || bad "H7 events: $(cat "$T/h7/ev")"
grep -q '^o/r#81 TICKET_HOLD_TIMEOUT call=ticket-hold/pr-thread ' "$T/h7/log" && ok "H7 PR 81 timeout line" || bad "H7 log: $(cat "$T/h7/log")"

# ---- D1/D2 a deadline kill in ticket-hold names the call -------------------------
D1STUB='hold_check_thread() { sleep 30.77486; }'   # determinism: ok the stub IS the stall the deadline kills
run_worker d1 61 "$D1STUB" MC_WORKER_DEADLINE_S=2 MC_STEP_TIMEOUT_S=0 MC_WORKER_DEADLINE_CAP_S=
[ "$(cat "$T/d1/word-61")" = killed:deadline ] && ok "D1 outcome killed:deadline" || bad "D1 outcome: $(cat "$T/d1/word-61" "$T/d1/out")"
[ "$(jq -s length "$T/d1/ev")" = 1 ] && ok "D1 one event" || bad "D1 events: $(cat "$T/d1/ev")"
[ "$(ev d1 .tags.call)" = ticket-hold/pr-thread ] && ok "D1 tag call" || bad "D1 tags: $(ev d1 .tags)"
[ "$(ev d1 .tags.pr)" = 61 ] && [ "$(ev d1 .tags.worker_key)" = "o/r#61" ] && [ "$(ev d1 .tags.step)" = ticket-hold ] \
  && ok "D1 tags pr, worker_key, step" || bad "D1 tags: $(ev d1 .tags)"
[ "$(ev d1 .extra.call)" = ticket-hold/pr-thread ] && [[ "$(ev d1 .extra.call_s)" =~ ^[0-9]+$ ]] \
  && ok "D1 extra call and numeric call_s" || bad "D1 extra: $(ev d1 .extra)"
[ "$(ev d1 .message)" = "WORKER_DEADLINE: worker killed after 2s on 6a7867e3 in step ticket-hold" ] \
  && ok "D1 title unchanged" || bad "D1 title: $(ev d1 .message)"
grep -Eq '^o/r#61 WORKER_DEADLINE: .*\| step: ticket-hold \([0-9]+s\) .*\| call: ticket-hold/pr-thread \([0-9]+s\) \| calls: ' "$T/d1/log" \
  && ok "D2 the line carries the call before calls" || bad "D2 log: $(cat "$T/d1/log")"

# ---- D3 a deadline kill with no call in flight -------------------------------------
c="$T/d3"; mk_h "$c"; mkdir -p "$c/state"; : > "$c/ev"; : > "$c/attempts"
HARNESS="$c/h" MC_WORKER_DEADLINE_S=1 MC_WORKER_DEADLINE_CAP_S= bash -c '
  c=$1; . "$2" || exit 1
  SLUG=o/r MC_STATE_DIR="$c/state" MC_TICK_ID=t1 MC_LOG="$c/lanelog" MC_FANIN_T0=0; : > "$MC_LOG"
  mc_handoff_id() { printf "%s" "${1//[^A-Za-z0-9._-]/_}"; }
  mc_log() { printf "%s\n" "$*" >> "$c/log"; }; _mc_fanin_alert() { :; }
  mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_row_field() { echo QUEUED; }
  sentry_report() { jq -nc --arg message "$4" --argjson extra "${5:-null}" --argjson tags "${6:-null}" "{message:\$message,extra:\$extra,tags:\$tags}" >> "$c/ev"; }
  pr_worker() { mc_step review; sleep 5; }   # determinism: ok the stub worker IS the stall the deadline kills
  row=$(printf "63\turl\t%s\tbr\tfalse\tCLEAN\t-" "$3")
  mc_worker_bounded "$row"; mc_fanin_outcome $? "$row" > "$c/word"' _ "$c" "$FANIN" "$HEAD" > "$c/out" 2>&1
[ "$(ev d3 '.tags | has("call")')" = false ] && ok "D3 no call tag" || bad "D3 tags: $(ev d3 .tags)"
[ "$(ev d3 .extra.call)" = none ] && ok "D3 extra call none" || bad "D3 extra: $(ev d3 .extra)"
grep -q 'WORKER_DEADLINE' "$c/log" && ! grep -q '| call:' "$c/log" && ok "D3 no call segment" || bad "D3 log: $(cat "$c/log")"
[ "$(ev d3 .message)" = "WORKER_DEADLINE: worker killed after 1s on 6a7867e3 in step review" ] && ok "D3 title unchanged" || bad "D3 title: $(ev d3 .message)"

# ---- K1 the conductor gets the registry default -------------------------------------
c="$T/k1"; mkdir -p "$c/h/logs" "$c/h/state" "$c/h/flags"
if "$REPO/bin/lanes-build.sh" --to "$c/reg.json" >/dev/null 2>"$c/err"; then
  jq -e '[.lanes[] | select(.id == "merge-conductor") | .knobs[] | select(.env == "MC_TICKET_HOLD_TIMEOUT_S")]
         | length == 1 and .[0].default == 90 and .[0].read_in == "bin/lib/ticket-ownership.sh"' "$c/reg.json" >/dev/null \
    && ok "K1 registered on merge-conductor, default 90" || bad "K1 registry: $(jq -c '[.lanes[] | select(.id == "merge-conductor") | .knobs[] | select(.env == "MC_TICKET_HOLD_TIMEOUT_S")]' "$c/reg.json")"
  got=$(env -u MC_TICKET_HOLD_TIMEOUT_S HARNESS="$c/h" LANE_REGISTRY="$c/reg.json" LANE_GATE_CACHE_S=0 bash -c '
    . "$1" || exit 1; lane_env_apply merge-conductor >/dev/null 2>&1; printf "%s" "${MC_TICKET_HOLD_TIMEOUT_S:-unset}"' _ "$REPO/bin/lib/lane-gate.sh" 2>"$c/err2")
  [ "$got" = 90 ] && ok "K1 lane_env_apply merge-conductor with no row: 90" || bad "K1 lane_env_apply gave '$got' $(cat "$c/err2")"
else
  bad "K1 lanes-build: $(cat "$c/err")"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
