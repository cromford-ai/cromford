#!/bin/bash
# tests/pool-actor-gate.bh-6957-test.sh — the pool asks the trigger-actor gate
# BEFORE it spends a machine (BH-6957). A key whose newest `ai-build` label is
# from an actor the gate ignores gets no machine: its queue row is closed
# `failed` with SKIP_ACTOR in the reason, once.
#
#   P1  ta_gate rc 1: 0 `spawned` lines, no machine json, no .spawns entry, the
#       queue file is gone, one `queue_done … failed` whose reason carries
#       SKIP_ACTOR, one SKIP_ACTOR line in fly-pool.log and in <p>.log, no
#       ALERTS line, and ta_gate's scratch build dir is removed
#   P2  a second tick: still one failed call, 0 spawns, no second gate read
#   P3  ta_gate rc 0 (a human RETRY re-armed it): one `spawned` line
#   P4  the reuse handoff: a reaped machine does not take an rc-1 key (row
#       failed SKIP_ACTOR), and still takes an rc-0 key
#   P5  ta_gate rc 2 (unverifiable): spawns, one `actor check unverifiable` line
#   P6  the SKIP_ACTOR reason matches none of bin/blocked-resolver.sh's
#       requeue reasons (`died N times`, `deferred N times`, ABANDONED)
#   P7  the REAL bin/lib/trigger-actor.sh against a stub gh: a key labelled by
#       github-actions[bot] spawns nothing and its row closes SKIP_ACTOR; the
#       same key with a newer human RETRY comment spawns
#   P8  RB-* rebase rows never reach the gate
#
# HOW IT DRIVES: the real bin/fly-pool.sh, one tick per run, against a scratch
# harness (the full-tick harness of tests/fly-pool-reuse-defer.bh-5025-test.sh)
# with a jobs-client stub that records QROW calls. P1-P6 and P8 put a stub
# bin/lib/trigger-actor.sh in the harness whose ta_gate answers per key from a
# fixture file; P7 installs the real one.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1792000000   # 2026-10-15, pinned

H="$T/h"
QD="$H/state/build-queue/project-5"; MD="$H/state/fly-pool/project-5"; PD="$H/state/pool/project-5"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/project-5" "$PD" \
         "$H/builds" "$T/fakebin" "$T/res"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

# The stub gate, written BEFORE the closure install so the install keeps it.
# $HARNESS/ta-fixture: `<KEY> <rc>`; a key not listed answers rc 0.
cat > "$H/bin/lib/trigger-actor.sh" <<'TA'
ta_gate() {
  local want
  printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$HARNESS/ta-calls"
  [ -d "$4" ] || { PROJECT_2_LINE="no build dir"; return 2; }
  want=$(awk -v k="$2" '$1 == k { print $2 }' "$HARNESS/ta-fixture" 2>/dev/null)
  case "$want" in
    1) PROJECT_2_LINE="ignored bot actor=github-actions[bot] event=9001 — commented once, recorded in ledger trigger-actor \"$1 $2\""; return 1 ;;
    2) PROJECT_2_LINE="events read: events page 1 rc=75 rate-limit"; return 2 ;;
    *) PROJECT_2_LINE="allow rearm actor=operator event=comment-501"; return 0 ;;
  esac
}
TA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/logs/ALERTS.log"\nexit 0\n' > "$H/bin/alert-line.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
# The queue-row recorders QROW calls, and the settings/ledger reads the real
# trigger-actor lib makes in P7 (sourced, never executed: not +x).
cat > "$H/bin/jobs-client.sh" <<'JC'
queue_done() { printf 'done\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$HARNESS/qrow.log"; return 0; }
queue_put()  { printf 'put\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" >> "$HARNESS/qrow.log"; return 0; }
setting_get() { return 2; }
job_ledger_row() { [ -s "$HARNESS/ledger.json" ] || return 2; cat "$HARNESS/ledger.json"; }
job_ledger_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HARNESS/ledger-puts"; jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s, detail:$d}' > "$HARNESS/ledger.json"; return 0; }
JC
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# gh: the repo is visible, no PR is open, the hold check's reads are clean.
# The trigger events and comments of issue 6853 come from $T/gh-events.json
# and $T/gh-comments.json (P7); a comment POST is recorded.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5/issues/6853/events"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/gh-events.json" 2>/dev/null || echo '[]'; exit 0
  fi
  if [[ "\$*" == *"POST"*"repos/example-org/project-5/issues/6853/comments"* ]]; then
    echo "\$*" >> "$T/gh-posts"; printf 'HTTP/1.1 201 Created\\n\\n{"id":1}\\n'; exit 0
  fi
  if [[ "\$*" == *"repos/example-org/project-5/issues/6853/comments"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/gh-comments.json" 2>/dev/null || echo '[]'; exit 0
  fi
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
if [[ "\$*" == *"issues/"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
exit 0
GH
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
chmod +x "$H/bin/beat.sh" "$H/bin/alert-line.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

LOG="$H/logs/fly-pool.log"
run_pool() {
  : > "$LOG"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_state() {
  local p
  for p in "$QD"/* "$MD"/* "$MD"/.[!.]* "$PD"/* "$H/builds"/* "$T/res"/* "$H/qrow.log" "$H/ta-calls" \
           "$H/ta-fixture" "$H/logs/project-5.log" "$H/ledger.json" "$H/ledger-puts" \
           "$T/gh-calls" "$T/gh-posts" "$T/gh-events.json" "$T/gh-comments.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
queued() { # queued <key> <ticket>
  jq -nc --arg k "$1" --arg t "$2" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-15 11:00:00Z"}' > "$QD/$1.json"
  touch -d "@$((NOW-3600))" "$QD/$1.json" 2>/dev/null || true
}
machine() { # machine <mid> <key> <ticket> <result>
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-15 11:40:00Z"}' > "$MD/$1.json"
  printf '%s\n' "$4" > "$T/res/$1"
}
gate() { printf '%s %s\n' "$1" "$2" >> "$H/ta-fixture"; }
spawned() { local n; n=$(grep -c "\] spawned [0-9a-z]* for $1 " "$LOG" 2>/dev/null); echo "${n:-0}"; }   # fly-pool.sh's spawn line
mjson() { grep -ls "\"key\": *\"$1\"" "$MD"/*.json 2>/dev/null | head -1; }
fails() { local n; n=$(grep -c "^done	project-5	$1	failed	" "$H/qrow.log" 2>/dev/null); echo "${n:-0}"; }

# ── P1 ──────────────────────────────────────────────────────────────────────
reset_state
gate BH-6853 1
queued BH-6853 6853
run_pool
[ "$(spawned BH-6853)" = 0 ] && ok || bad "P1: no spawned line for a refused key: $(cat "$LOG")"
[ -z "$(mjson BH-6853)" ] && ok || bad "P1: no machine json for a refused key"
grep -q 'machine run' "$T/fly-calls" && bad "P1: fly machine run was called: $(cat "$T/fly-calls")" || ok
[ -s "$PD/BH-6853.spawns" ] && bad "P1: a refusal must not count against the spawn cap: $(cat "$PD/BH-6853.spawns")" || ok
[ -e "$QD/BH-6853.json" ] && bad "P1: the queue file must go" || ok
[ "$(fails BH-6853)" = 1 ] && ok || bad "P1: exactly one failed QROW: $(cat "$H/qrow.log" 2>/dev/null)"
REASON=$(grep "^done	project-5	BH-6853	failed	" "$H/qrow.log" 2>/dev/null | cut -f5)
case "$REASON" in "SKIP_ACTOR BH-6853 — ignored bot actor=github-actions[bot]"*"no machine spawned"*) ok ;;
  *) bad "P1: the reason must start 'SKIP_ACTOR BH-6853 — ignored bot …' and say no machine spawned: '$REASON'" ;; esac
grep -q 'skipping BH-6853: SKIP_ACTOR — ignored bot actor=github-actions\[bot\].*(no machine spawned)' "$LOG" && ok \
  || bad "P1: fly-pool.log must carry the SKIP_ACTOR skip line: $(cat "$LOG")"
grep -q '\[project-5/BH-6853\] SKIP_ACTOR BH-6853' "$H/logs/project-5.log" 2>/dev/null && ok \
  || bad "P1: logs/project-5.log must carry the SKIP_ACTOR line: $(cat "$H/logs/project-5.log" 2>/dev/null)"
grep -q 'BH-6853\|SKIP_ACTOR' "$H/logs/ALERTS.log" && bad "P1: no ALERTS line for a refusal: $(cat "$H/logs/ALERTS.log")" || ok
[ "$(wc -l < "$H/ta-calls" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "P1: one gate call: $(cat "$H/ta-calls" 2>/dev/null)"
[ "$(cut -d' ' -f1-3 "$H/ta-calls" 2>/dev/null)" = "project-5 BH-6853 6853" ] && ok || bad "P1: the gate is asked for <p> <KEY> <ticket>: $(cat "$H/ta-calls" 2>/dev/null)"
BD=$(cut -d' ' -f4 "$H/ta-calls" 2>/dev/null)
[ -n "$BD" ] && [ ! -e "$BD" ] && ok || bad "P1: the gate's scratch build dir '$BD' must be removed"

# ── P2 ──────────────────────────────────────────────────────────────────────
run_pool
[ "$(spawned BH-6853)" = 0 ] && ok || bad "P2: still no spawn on tick 2: $(cat "$LOG")"
[ "$(fails BH-6853)" = 1 ] && ok || bad "P2: still one failed QROW over two ticks: $(cat "$H/qrow.log")"
[ "$(wc -l < "$H/ta-calls" | tr -d ' ')" = 1 ] && ok || bad "P2: a closed row is not read again: $(cat "$H/ta-calls")"

# ── P3 ──────────────────────────────────────────────────────────────────────
reset_state
gate BH-6853 0
queued BH-6853 6853
run_pool
[ "$(spawned BH-6853)" = 1 ] && ok || bad "P3: a re-armed key must spawn once: $(cat "$LOG")"
[ -n "$(mjson BH-6853)" ] && ok || bad "P3: the re-armed key has a machine json"
[ "$(fails BH-6853)" = 0 ] && ok || bad "P3: no failed QROW for an allowed key: $(cat "$H/qrow.log" 2>/dev/null)"

# ── P4 ──────────────────────────────────────────────────────────────────────
reset_state
gate BH-6853 1
machine m2 BH-5103 5103 "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5103"
queued BH-6853 6853
run_pool POOL_SPAWN=0
grep -q 'reused m2 for BH-6853' "$LOG" && bad "P4: a reaped machine must not take a refused key: $(cat "$LOG")" || ok
[ "$(fails BH-6853)" = 1 ] && ok || bad "P4: the handoff path closes the row SKIP_ACTOR: $(cat "$H/qrow.log" 2>/dev/null)"
grep "^done	project-5	BH-6853	failed	" "$H/qrow.log" 2>/dev/null | grep -q SKIP_ACTOR && ok || bad "P4: reason carries SKIP_ACTOR"
[ -e "$QD/BH-6853.json" ] && bad "P4: the queue file must go" || ok
# positive control: the same machine takes an allowed key
reset_state
machine m2 BH-5103 5103 "BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-5103"
queued BH-6854 6854
run_pool POOL_SPAWN=0
grep -q 'reused m2 for BH-6854' "$LOG" && ok || bad "P4b: an allowed key is still handed to the reaped machine: $(cat "$LOG")"

# ── P5 ──────────────────────────────────────────────────────────────────────
reset_state
gate BH-6853 2
queued BH-6853 6853
run_pool
[ "$(spawned BH-6853)" = 1 ] && ok || bad "P5: an unverifiable check spawns (fail-open): $(cat "$LOG")"
[ "$(grep -c 'actor check unverifiable for BH-6853 (events read: events page 1 rc=75 rate-limit)' "$LOG")" = 1 ] && ok \
  || bad "P5: one 'actor check unverifiable' line: $(cat "$LOG")"
[ "$(fails BH-6853)" = 0 ] && ok || bad "P5: an unverifiable check does not close the row"

# ── P6 ──────────────────────────────────────────────────────────────────────
if [ -n "$REASON" ] && ! grep -Eq 'died [0-9]+ times|deferred [0-9]+ times|ABANDONED' <<<"$REASON"; then ok
else bad "P6: the SKIP_ACTOR reason must not read as a resolver requeue reason: '$REASON'"; fi

# ── P8 ──────────────────────────────────────────────────────────────────────
reset_state
gate RB-77-abcdef12 1
queued RB-77-abcdef12 77
run_pool
grep -q 'RB-77-abcdef12' "$H/ta-calls" 2>/dev/null && bad "P8: a rebase row must not reach the gate" || ok
[ "$(fails RB-77-abcdef12)" = 0 ] && ok || bad "P8: a rebase row is never closed SKIP_ACTOR"

# ── P7: the real trigger-actor lib ───────────────────────────────────────────
scratch_rm "$H/bin/lib/trigger-actor.sh" || exit 1
scratch_install_closure bin/lib/trigger-actor.sh "$H" >/dev/null || { echo "closure install of bin/lib/trigger-actor.sh failed"; exit 1; }
cmp -s "$DIR/bin/lib/trigger-actor.sh" "$H/bin/lib/trigger-actor.sh" && ok || bad "P7: the real lib is installed"
SELF="HARNESS_SELF_APPS=cromford cromford-board"
reset_state
jq -nc '[{id:9001, event:"labeled", actor:{login:"github-actions[bot]", type:"Bot"}, label:{name:"ai-build"},
          created_at:"2026-10-15T08:00:00Z", performed_via_github_app:null}]' > "$T/gh-events.json"
echo '[]' > "$T/gh-comments.json"
queued BH-6853 6853
run_pool "$SELF" GH_ETAG=0
[ "$(spawned BH-6853)" = 0 ] && ok || bad "P7: the real gate must refuse the github-actions[bot] label: $(cat "$LOG")"
grep -q 'machine run' "$T/fly-calls" && bad "P7: no machine for a refused key" || ok
grep "^done	project-5	BH-6853	failed	" "$H/qrow.log" 2>/dev/null | grep -q 'SKIP_ACTOR BH-6853 — ignored bot actor=github-actions\[bot\] event=9001' && ok \
  || bad "P7: one failed row with the real refusal: $(cat "$H/qrow.log" 2>/dev/null) / $(cat "$LOG")"
[ "$(wc -l < "$T/gh-posts" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "P7: the gate comments once on the ticket: $(cat "$T/gh-posts" 2>/dev/null)"
grep -q '	trigger-actor	project-5 BH-6853	ignored\|^trigger-actor	project-5 BH-6853	ignored' "$H/ledger-puts" 2>/dev/null && ok \
  || bad "P7: the ignore is recorded in the trigger-actor ledger: $(cat "$H/ledger-puts" 2>/dev/null)"
# the same key, a human RETRY after the bot label: it builds
for p in "$H/qrow.log" "$MD"/*; do [ -e "$p" ] && scratch_rm "$p"; done
jq -nc '[{id:501, user:{login:"operator", type:"User"}, created_at:"2026-10-15T09:00:00Z", body:"RETRY", performed_via_github_app:null}]' > "$T/gh-comments.json"
queued BH-6853 6853
run_pool "$SELF" GH_ETAG=0
[ "$(spawned BH-6853)" = 1 ] && ok || bad "P7: a human RETRY after the bot label must spawn: $(cat "$LOG")"
[ "$(fails BH-6853)" = 0 ] && ok || bad "P7: the re-armed row is not closed: $(cat "$H/qrow.log" 2>/dev/null)"

echo "pool-actor-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
