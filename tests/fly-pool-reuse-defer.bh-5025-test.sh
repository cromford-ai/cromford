#!/bin/bash
# tests/fly-pool-reuse-defer.bh-5025-test.sh — BH-5047 (BH-5025.2): a dead
# GitHub token is not the ticket's fault, and a hotfix that deferred on a REUSED
# machine gets a fresh one next time.
#
#   T1  ta_gh_trigger: a 401 on the events read -> rc 2, PROJECT_2_NOTE "token-401 events page 1 …"
#   T2  a 403 rate limit keeps today's "events page 1 rc=75 rate-limit" (no token-401)
#   T3  a full tick: a token-401 deferral is requeued with deferrals unchanged,
#       logs TOKEN-401, destroys the machine instead of reusing it, sets no
#       project hold, keeps its .spawns line and writes one ALERTS line
#   T3b an ordinary deferral after earlier token-401 deferrals is not charged for them
#   T4  the next machine in the same tick (an ordinary deferral) still advances
#       deferrals and IS reused — TOKFAIL does not leak
#   T5  a hotfix deferring on a reused machine is requeued with fresh_spawn:true
#       (queue file + QROW meta); the next reaped machine leaves it for a fresh spawn
#   T6  POOL_HOTFIX_FRESH_AFTER_DEFER=0: no marker, and a fresh_spawn hotfix IS reused
#   T7  no marker for a hotfix on a fresh machine, nor for a non-hotfix on a reused one
#   T8  queue_row_job_file carries fresh_spawn from row meta to the job json
#
# The full-tick harness is tests/fly-pool-refused-not-counted.bh-1279-test.sh's.
# Every age derives from one NOW.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

# ── T1/T2: ta_gh_trigger through the real gh-rest.sh, a stubbed gh ─────────
mkdir -p "$T/ghbin"
ta_run() { # ta_run <status line> [body] -> sets TRC, TNOTE; leaves $T/ta-out*
  printf '%s\r\nContent-Type: application/json\r\n\r\n%s\n' "$1" "${2:-'{"message":"Bad credentials"}'}" > "$T/gh-answer"
  printf '#!/bin/bash\ncat "%s"\n' "$T/gh-answer" > "$T/ghbin/gh"
  chmod +x "$T/ghbin/gh"
  local f
  for f in "$T"/ta-out*; do [ -e "$f" ] && scratch_rm "$f"; done
  # shellcheck disable=SC1090,SC1091
  eval "$( PATH="$T/ghbin:$PATH" GH_ETAG=0 bash -c '
    . "$1/bin/lib/gh-rest.sh" || exit 9
    . "$1/bin/lib/trigger-actor.sh" || exit 9
    rc=0; ta_gh_trigger example-org/tproj 77 "$2" || rc=$?
    printf "TRC=%q; TNOTE=%q\n" "$rc" "${PROJECT_2_NOTE:-}"' _ "$DIR" "$T/ta-out" )"
}
left_over() { ls "$T"/ta-out.page "$T"/ta-out.page.reason "$T"/ta-out.page.status "$T"/ta-out.hits 2>/dev/null | tr '\n' ' '; }

TRC=""; TNOTE=""
ta_run 'HTTP/1.1 401 Unauthorized'
[ "$TRC" = 2 ] && ok || bad "T1: a 401 must stay rc 2 (fail closed), got rc=$TRC"
case "$TNOTE" in "token-401 events page 1"*) ok ;; *) bad "T1: PROJECT_2_NOTE must start 'token-401 events page 1', got '$TNOTE'" ;; esac
[ -z "$(left_over)" ] && ok || bad "T1: page files left behind: $(left_over)"

ta_run 'HTTP/1.1 403 Forbidden' '{"message":"API rate limit exceeded for installation"}'
[ "$TRC" = 2 ] && ok || bad "T2: a 403 must be rc 2, got rc=$TRC"
case "$TNOTE" in *token-401*) bad "T2: a 403 rate limit must never read as token-401: '$TNOTE'" ;; *) ok ;; esac
[ "$TNOTE" = "events page 1 rc=75 rate-limit" ] && ok || bad "T2: a 403 keeps today's text, got '$TNOTE'"
[ -z "$(left_over)" ] && ok || bad "T2: page files left behind: $(left_over)"

# ── the full-tick harness ──────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/res"
printf 'FLY_API_TOKEN_PROJECT_5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/lib/hold.sh "$H" >/dev/null || { echo "closure install failed for bin/lib/hold.sh"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/logs/ALERTS.log"\nexit 0\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# The queue-row recorders QROW calls (sourced, never executed: not +x).
cat > "$H/bin/jobs-client.sh" <<'JC'
queue_done() { printf 'done\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$HARNESS/qrow.log"; return 0; }
queue_put()  { printf 'put\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" >> "$HARNESS/qrow.log"; return 0; }
JC
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# gh: the hold check's comment read answers an empty list, an issue read says
# open, the repo is visible, no PR is open, every other REST read is a 404 (the bh-1279 suite's stub, trimmed).
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'
fi
exit 0
GH
chmod +x "$H/bin/beat.sh" "$H/bin/alert-line.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

# Fly stub: per-machine RESULT from $T/res/<machine>, every call logged.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
M=""; prev=""
for a in "\$@"; do [ "\$prev" = --machine ] && M="\$a"; prev="\$a"; done
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "\$M" ] && [ -f "$T/res/\$M" ] && cat "$T/res/\$M" ;;
  *"ssh console"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"

QD="$H/state/build-queue/project-5"; MD="$H/state/fly-pool/project-5"; PD="$H/state/pool/project-5"
run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$H/qrow.log"; : > "$T/fly-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_BIN_DIR="$T/fakebin" POOL_SPAWN=0 "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$MD"/.[!.]* "$PD"/* "$H/builds"/* "$T/res"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
machine() { # machine <mid> <key> <ticket> <deferrals> <hotfix> <reused_from|-> <result>
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" --argjson d "$4" --arg hf "$5" --arg rf "$6" \
    --arg ts "$(date -u -d "@$((NOW-600))" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo 2026-10-07T03:00:00Z)" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:$d,deaths:0,spawned_at:$ts}
     + (if $hf == "true" then {hotfix:true} else {} end)
     + (if $rf == "-" then {} else {reused_from:$rf} end)' > "$MD/$1.json"
  printf '%s\n' "$7" > "$T/res/$1"
}
queued() { # queued <key> <ticket> [hotfix] [fresh_spawn]
  jq -nc --arg k "$1" --arg t "$2" --arg hf "${3:-false}" --arg fs "${4:-false}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-07 02:00:00Z"}
     + (if $hf == "true" then {hotfix:true} else {} end)
     + (if $fs == "true" then {fresh_spawn:true} else {} end)' > "$QD/$1.json"
  touch -d "@$((NOW-3600))" "$QD/$1.json" 2>/dev/null || true
}
qf() { jq -r "$2" "$QD/$1.json" 2>/dev/null; }
# The production shape: gates.sh:653 wrapping ta_gate's PROJECT_2_LINE (trigger-actor.sh:310).
TOK401="BUILD_DEFERRED trigger-actor unverifiable (events read: token-401 events page 1 (GitHub answered 401: this machine's token is dead, not the ticket)) — the next tick re-offers BH-5101"
LOG="$H/logs/fly-pool.log"

# ── T3: a token-401 deferral ────────────────────────────────────────────────
reset_state
SCT=$((NOW-600))
echo "$SCT" > "$PD/BH-5101.spawns"
machine m1 BH-5101 5101 1 false - "$TOK401"
jq --arg s "$SCT" '. + {spawn_cap_ts:$s}' "$MD/m1.json" > "$MD/m1.tmp" && mv "$MD/m1.tmp" "$MD/m1.json"
# An earlier token-401 deferral of the same key must not raise the DSEEN floor.
mkdir -p "$H/builds/pool-project-5-BH-5101-202001010000" "$H/builds/pool-project-5-BH-5101-202001010100"
printf '%s\n' "$TOK401" > "$H/builds/pool-project-5-BH-5101-202001010000/RESULT"
printf '%s\n' "$TOK401" > "$H/builds/pool-project-5-BH-5101-202001010100/RESULT"
queued BH-5102 5102
run_pool
[ "$(qf BH-5101 .deferrals)" = 1 ] && ok || bad "T3: deferrals must stay 1 on a token-401, queue file: $(cat "$QD/BH-5101.json" 2>/dev/null)"
grep -q 'TOKEN-401 BH-5101' "$LOG" && ok || bad "T3: fly-pool.log must log 'TOKEN-401 BH-5101': $(cat "$LOG")"
grep -q 'machine destroy m1' "$T/fly-calls" && ok || bad "T3: m1 must be destroyed: $(cat "$T/fly-calls")"
grep -q 'reused m1' "$LOG" && bad "T3: m1 must not be reused: $(grep reused "$LOG")" || ok
[ -f "$QD/BH-5102.json" ] && ok || bad "T3: BH-5102 must still be queued (not handed to m1)"
[ -e "$PD/_spawn-hold" ] && bad "T3: a token-401 must set no project hold: $(cat "$PD/_spawn-hold")" || ok
grep -qx "$SCT" "$PD/BH-5101.spawns" 2>/dev/null && ok || bad "T3: m1's spawn must stay on the .spawns ledger: $(cat "$PD/BH-5101.spawns" 2>/dev/null)"
[ "$(grep -c 'm1' "$H/logs/ALERTS.log")" = 1 ] && grep -q "token answered 401" "$H/logs/ALERTS.log" && ok \
  || bad "T3: exactly one ALERTS line naming m1's 401: $(cat "$H/logs/ALERTS.log")"
grep -q $'^put\tproject-5\tBH-5101\t5101\tfly\t1\t' "$H/qrow.log" && grep 'BH-5101' "$H/qrow.log" | grep '^put' | grep -q '"deferrals":1' && ok \
  || bad "T3: the row is requeued with deferrals:1 in its meta: $(cat "$H/qrow.log")"
grep -q 'parked\|deferred [0-9]* times' "$LOG" && bad "T3: a token-401 must never park: $(cat "$LOG")" || ok

# ── T3b: the DSEEN floor skips earlier token-401 dirs ──────────────────────
# An ordinary deferral after two token-401 ones: 1 -> 2, not 3.
reset_state
machine m1 BH-5101 5101 1 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5101"
mkdir -p "$H/builds/pool-project-5-BH-5101-202001010000" "$H/builds/pool-project-5-BH-5101-202001010100"
printf '%s\n' "$TOK401" > "$H/builds/pool-project-5-BH-5101-202001010000/RESULT"
printf '%s\n' "$TOK401" > "$H/builds/pool-project-5-BH-5101-202001010100/RESULT"
run_pool
[ "$(qf BH-5101 .deferrals)" = 2 ] && ok || bad "T3b: earlier token-401 dirs must not raise the floor: $(cat "$QD/BH-5101.json" 2>/dev/null)"

# ── T4: the next machine's ordinary deferral — no leak ─────────────────────
reset_state
machine m1 BH-5101 5101 1 false - "$TOK401"
machine m2 BH-5103 5103 1 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5103"
queued BH-5102 5102
run_pool
[ "$(qf BH-5103 .deferrals)" = 2 ] && ok || bad "T4: an ordinary deferral still advances to 2: $(cat "$QD/BH-5103.json" 2>/dev/null)"
grep -q 'reused m2 for BH-5102' "$LOG" && ok || bad "T4: m2 must be reused for BH-5102: $(cat "$LOG")"
grep -q 'machine destroy m2' "$T/fly-calls" && bad "T4: m2 must not be destroyed (TOKFAIL leaked)" || ok
grep -q 'machine destroy m1' "$T/fly-calls" && ok || bad "T4: m1 is still destroyed"
grep -q 'TOKEN-401 BH-5103' "$LOG" && bad "T4: a slots-busy deferral is not a token-401" || ok

# ── T5: hotfix on a reused machine -> fresh_spawn, then left for a fresh spawn
reset_state
machine m1 BH-5104 5104 0 true BH-1 "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5104"
machine m2 BH-5105 5105 0 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5105"
run_pool
[ "$(qf BH-5104 .fresh_spawn)" = true ] && [ "$(qf BH-5104 .hotfix)" = true ] && ok \
  || bad "T5: the queue file must carry hotfix+fresh_spawn: $(cat "$QD/BH-5104.json" 2>/dev/null)"
grep 'BH-5104' "$H/qrow.log" | grep '^put' | grep -q '"fresh_spawn":true' && ok \
  || bad "T5: the QROW requeue meta must carry fresh_spawn:true: $(cat "$H/qrow.log")"
grep -q 'BH-5104: hotfix deferred on a reused machine last time — left for a fresh spawn' "$LOG" && ok \
  || bad "T5: m2 must log 'left for a fresh spawn': $(cat "$LOG")"
grep -q 'reused m2' "$LOG" && bad "T5: m2 must not take the fresh_spawn hotfix: $(grep reused "$LOG")" || ok
grep -q 'machine destroy m2' "$T/fly-calls" && ok || bad "T5: m2 is destroyed when the hotfix was its only job"
[ -f "$QD/BH-5104.json" ] && ok || bad "T5: the hotfix stays queued for the next spawn"
# ...and a hand-made fresh_spawn hotfix is skipped the same way.
reset_state
machine m2 BH-5105 5105 0 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5105"
queued BH-5106 5106 true true
run_pool
grep -q 'BH-5106: hotfix deferred on a reused machine last time — left for a fresh spawn' "$LOG" && ok \
  || bad "T5b: a fresh_spawn hotfix queue file must be left for a fresh spawn: $(cat "$LOG")"
grep -q 'reused m2' "$LOG" && bad "T5b: m2 must not take it" || ok

# ── T6: the knob off ────────────────────────────────────────────────────────
reset_state
machine m1 BH-5104 5104 0 true BH-1 "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5104"
machine m2 BH-5105 5105 0 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5105"
run_pool POOL_HOTFIX_FRESH_AFTER_DEFER=0
grep -q 'BH-5104' "$H/qrow.log" && ! grep -q fresh_spawn <<<"$(grep 'BH-5104' "$H/qrow.log")" && ok \
  || bad "T6: knob 0 -> no marker in the QROW meta: $(cat "$H/qrow.log")"
grep -q 'reused m2 for BH-5104' "$LOG" && ok || bad "T6: knob 0 -> m2 takes the hotfix: $(cat "$LOG")"
reset_state
machine m2 BH-5105 5105 0 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5105"
queued BH-5106 5106 true true
run_pool POOL_HOTFIX_FRESH_AFTER_DEFER=0
grep -q 'reused m2 for BH-5106' "$LOG" && ok || bad "T6b: knob 0 -> a fresh_spawn hotfix IS reused: $(cat "$LOG")"
grep -q 'left for a fresh spawn' "$LOG" && bad "T6b: knob 0 -> nothing is left for a fresh spawn" || ok

# ── T7: no marker without both a hotfix and a reused machine ──────────────
reset_state
machine m1 BH-5107 5107 0 true - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5107"
machine m3 BH-5108 5108 0 false BH-2 "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5108"
run_pool
# Read from the QROW meta: m3 is reaped second and may take BH-5107's file.
putmeta() { awk -F'\t' -v k="$1" '$1=="put" && $3==k {print $7}' "$H/qrow.log" | tail -1; }
[ "$(putmeta BH-5107 | jq -r '.hotfix')" = true ] && [ "$(putmeta BH-5107 | jq -r 'has("fresh_spawn")')" = false ] && ok \
  || bad "T7: a hotfix on a FRESH machine gets no marker: $(putmeta BH-5107)"
[ -n "$(putmeta BH-5108)" ] && [ "$(putmeta BH-5108 | jq -r 'has("fresh_spawn")')" = false ] && ok \
  || bad "T7: a non-hotfix on a REUSED machine gets no marker: $(putmeta BH-5108)"
grep -q 'fresh_spawn' "$H/qrow.log" && bad "T7: no fresh_spawn in any QROW meta: $(cat "$H/qrow.log")" || ok
# A non-hotfix row carrying a stray fresh_spawn is ignored by the skip.
reset_state
machine m2 BH-5105 5105 0 false - "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5105"
queued BH-5109 5109 false true
run_pool
grep -q 'reused m2 for BH-5109' "$LOG" && ok || bad "T7: a non-hotfix fresh_spawn row is still reused: $(cat "$LOG")"

# ── T8: queue_row_job_file carries fresh_spawn ─────────────────────────────
OUT8=$( HARNESS="$H" bash -c '
  . "$1/bin/lib/queue-row-job.sh" || exit 9
  queue_row_job_file project-5 "$2/a.json" BH-5110 5110 1 "{\"hotfix\":true,\"fresh_spawn\":true}" || exit 8
  queue_row_job_file project-5 "$2/b.json" BH-5111 5111 1 "{\"hotfix\":true}" || exit 7
  jq -c . "$2/a.json" "$2/b.json"' _ "$DIR" "$T" ); RC8=$?
[ "$RC8" = 0 ] && ok || bad "T8: queue_row_job_file failed rc=$RC8"
[ "$(jq -r '.fresh_spawn // "absent"' "$T/a.json" 2>/dev/null)" = true ] && [ "$(jq -r .hotfix "$T/a.json" 2>/dev/null)" = true ] && ok \
  || bad "T8: meta fresh_spawn:true must reach the job json: $OUT8"
[ "$(jq -r 'has("fresh_spawn")' "$T/b.json" 2>/dev/null)" = false ] && ok \
  || bad "T8: no fresh_spawn in meta -> no key in the job json: $OUT8"

echo "fly-pool-reuse-defer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
