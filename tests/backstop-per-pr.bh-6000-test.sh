#!/bin/bash
# tests/backstop-per-pr.bh-6000-test.sh — BH-6000 part 2: the */5 backstop
# starts one detached keyed conductor run PER CANDIDATE PR, with no cap and no
# shared window, so no PR waits for lack of time.
#
# THE INCIDENT (2026-10-11, merge-conductor.log on the hub). The backstop
# handed at most 6 keys to ONE keyed run under one worker window
# (MC_WORKERS_DONE_BY). #4546, #5704, #5727, #5990 and #5999 each logged
# "WINDOW_DEFERRED: under 15s of worker time left ... not started" on every
# fire, and the rest of the candidates waited for later fires.
#
# The REAL bin/merge-conductor-backstop.sh is driven against a recorder
# conductor whose per-PR step takes 10 s (the ticket's fixture).
#   P1 30 candidates: every one starts its own run in ONE fire, each run is
#      keyed to exactly one PR, carries WAKE_LAUNCH=1 and no MC_WORKERS_DONE_BY,
#      all 30 start within a few seconds, and the fire itself returns at once
#   P2 nothing in the fire's output says deferred, carried or WINDOW_DEFERRED
#   P3 a second fire while those runs still work starts none of them again:
#      each busy key is left alone with one line
#   P4 once the runs are done, the next fire starts all 30 again (never dropped)
#   P5 MC_BACKSTOP_MAX_KEYS (deprecated) caps nothing, and is named in the log
# Run from anywhere: tests/backstop-per-pr.bh-6000-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v setsid >/dev/null && command -v flock >/dev/null || { echo "FAIL: setsid/flock missing"; exit 1; }

R="$T/r"; mkdir -p "$R/bin/lib" "$R/logs" "$R/locks" "$R/state/merge-conductor" "$R/flags" "$R/env" "$T/rbin" "$T/rec"
( cd "$DIR" && scratch_install_closure bin/merge-conductor-backstop.sh "$R" ) >/dev/null || { echo "FAIL: cannot install the backstop"; exit 1; }
: > "$R/env/global.env"
# The recorder: one file per run, named by its key, holding its start second,
# its env, and (after its 10 s step) "done".
cat > "$R/bin/merge-conductor.sh" <<EOF
#!/bin/bash
f="$T/rec/\$(printf '%s' "\${MC_ONLY_PR:-unset}" | tr '/#' '__').\$\$"
printf 'key=%s start=%s wake=%s done_by=%s\n' "\${MC_ONLY_PR:-unset}" "\$(date +%s)" "\${WAKE_LAUNCH:-}" "\${MC_WORKERS_DONE_BY:-}" > "\$f"
sleep 10   # determinism: ok the per-PR step of the ticket's fixture (10 s of work), not a wait for a condition
echo done >> "\$f"
EOF
chmod +x "$R/bin/merge-conductor.sh"
printf '#!/bin/bash\nexit 1\n' > "$T/rbin/gh"; chmod +x "$T/rbin/gh"
NOW=$(date +%s); H1=$(printf 'a%.0s' $(seq 40))
: > "$R/state/merge-conductor/pr-state.tsv"
for i in $(seq 1 30); do
  repo=example-org/demo-os; [ "$i" -gt 15 ] && repo=example-org/other-os
  st=READY; [ $((i % 2)) = 0 ] && st=WAIT_CI
  printf '%s#%s\t%s\t%s\t%s\t%s\t-\t-\thttps://github.com/%s/pull/%s\n' "$repo" "$i" "$st" "$((NOW - i))" "$H1" "$H1" "$repo" "$i" \
    >> "$R/state/merge-conductor/pr-state.tsv"
done
fire() { # fire [VAR=val...] — one backstop fire; its output -> $T/bs.out, seconds -> $T/bs.secs
  local t0 t1; t0=$(date +%s)
  ( cd "$T" && env PATH="$T/rbin:$PATH" HARNESS="$R" "$@" bash "$R/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 )
  t1=$(date +%s); echo $((t1 - t0)) > "$T/bs.secs"
}
starts() { grep -h '^key=' "$T"/rec/* 2>/dev/null | grep -c .; }
wait_starts() { local n=0; while [ "$(starts)" -lt "$1" ] && [ "$n" -lt 40 ]; do sleep 0.25; n=$((n + 1)); done; }
wait_done() { local n=0; while [ "$(grep -l '^done$' "$T"/rec/* 2>/dev/null | grep -c .)" -lt "$1" ] && [ "$n" -lt 80 ]; do sleep 0.25; n=$((n + 1)); done; }

# --- P1/P2. one fire, 30 candidates --------------------------------------------
fire
[ "$(cat "$T/bs.secs")" -le 5 ] && ok || bad "P1 the fire must return at once, not wait for the runs (took $(cat "$T/bs.secs")s)"
wait_starts 30
[ "$(starts)" = 30 ] && ok || bad "P1 all 30 candidates must start their own run in one fire (started: $(starts))"
[ "$(grep -h '^key=' "$T"/rec/* | sed 's/ .*//' | sort -u | grep -c .)" = 30 ] && ok || bad "P1 each run must be keyed to a different PR"
MULTI=$(grep -h '^key=' "$T"/rec/* | grep -v '^key=[^ ,]*#[0-9]* ')
[ -z "$MULTI" ] && ok || bad "P1 a run keyed to more than one PR: $(head -2 <<<"$MULTI")"
[ "$(grep -h '^key=' "$T"/rec/* | grep -c ' wake=1 ')" = 30 ] && ok || bad "P1 every run carries WAKE_LAUNCH=1"
[ "$(grep -h '^key=' "$T"/rec/* | grep -c ' done_by=$')" = 30 ] && ok || bad "P1 no run carries a shared window (MC_WORKERS_DONE_BY)"
S=$(grep -h '^key=' "$T"/rec/* | sed 's/.* start=\([0-9]*\) .*/\1/' | sort -n)
[ $(( $(tail -1 <<<"$S") - $(head -1 <<<"$S") )) -le 5 ] && ok || bad "P1 all 30 must start within the same fire (spread $(( $(tail -1 <<<"$S") - $(head -1 <<<"$S") ))s)"
grep -qiE 'deferred|carry|WINDOW_DEFERRED' "$T/bs.out" && bad "P2 the fire must defer nothing: $(cat "$T/bs.out")" || ok
grep -q '30 candidate(s): 30 detached keyed conductor run(s) started' "$T/bs.out" && ok || bad "P2 the summary line: $(cat "$T/bs.out")"

# --- P3. a second fire while the runs still work -------------------------------
fire
[ "$(starts)" = 30 ] && ok || bad "P3 a busy key must not start a second run (starts now: $(starts))"
[ "$(grep -c 'still holds .* left alone this fire' "$T/bs.out")" = 30 ] && ok || bad "P3 each busy key gets one 'left alone' line: $(grep -c 'left alone' "$T/bs.out")"

# --- P4. after the runs, the next fire starts them all again -------------------
wait_done 30
rm -f "$T"/rec/*
fire
wait_starts 30
[ "$(starts)" = 30 ] && ok || bad "P4 after the runs end every key is offered again, none dropped (started: $(starts))"
wait_done 30; rm -f "$T"/rec/*

# --- P5. the deprecated cap caps nothing ---------------------------------------
fire MC_BACKSTOP_MAX_KEYS=2
wait_starts 30
[ "$(starts)" = 30 ] && ok || bad "P5 MC_BACKSTOP_MAX_KEYS=2 must not cap the fire (started: $(starts))"
grep -q 'MC_BACKSTOP_MAX_KEYS=2 is deprecated and has no effect' "$T/bs.out" && ok || bad "P5 the deprecated knob must be named: $(cat "$T/bs.out")"
wait_done 30

echo "backstop-per-pr.bh-6000: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
