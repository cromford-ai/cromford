#!/bin/bash
# tests/responder-per-project.bh-5942-test.sh — BH-5942: the watchdog responder
# runs once per project on the per-project runner.
#
# Drives the real bin/watchdog-responder.sh: no argument = a dispatch through
# bin/project-lane-run.sh, one run per fleet.conf project. Only the paid session
# (bin/agent-call.sh) and the App token mint (bin/gh-token.sh) are stubbed, and
# what they receive is the assertion.
#
#   R1  two projects run in parallel: A blocks inside its session while B
#       finishes; each holds only locks/watchdog-responder-<p>.lock and the old
#       locks/responder.lock is not held; B's lock is free once its run exits
#       (polled, 10 s bound)
#   R2  each run's prompt names only its own stale ticket
#   R3  a wedged job of projfix-b is not in projfix-a's prompt
#   R4  each run's session sees ACCOUNT_PROJECT_FOR_LANE=responder=<p> and its
#       own App token; the run does not refresh the fleet-wide stale snapshot
#   R5  two runs stamp handled.json at the same moment: both keep their keys;
#       a handled.json lock that is not free stamps nothing (one log line);
#       a session refused before the call (rc 76) stamps nothing
#   R6  a project's own history gives a persisted item on its next pass
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/responder-per-project.bh-5942-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/tmp"
for L in bin/watchdog-responder.sh bin/project-lane-run.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" JOBS_URL="" GH_TOKEN="tok-fixture-default"
export LLM_LANE_DISPATCH_SPREAD_SECS=0
cat > "$H/fleet.conf" <<'EOF'
projfix-a o/projfix-a - - 2 box-a 192.0.2.1
projfix-b o/projfix-b - - 2 box-b 192.0.2.2
EOF
printf 'JOBS_URL=\nGH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"
# The single tooled call: this suite is about which project a run sees, not the prefetch.
: > "$H/flags/responder-prefetch-off"
# Each project's App token.
printf '# fixture: no real App key\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
# The fleet-wide sweep must not run from a project run.
printf '#!/bin/sh\necho called >> "%s/sweep.log"\n' "$T" > "$H/bin/stale-owed-tickets.sh"
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
# args: triage responder <model> <timeout> <out> <prompt>
out="\$5"; p="\${out##*/responder-run.}"; p="\${p%.txt}"
printf '%s' "\$6" > "$T/prompt.\$p"
# Shared: the other run's session probes the same file at the same moment (BH-6571).
old=free; flock -n -s "$H/locks/responder.lock" true 2>/dev/null || old=held
own=free; flock -n "$H/locks/watchdog-responder-\$p.lock" true || own=held
printf '%s\t%s\t%s\t%s\t%s\n' "\$p" "\${ACCOUNT_PROJECT_FOR_LANE:-none}" "\${GH_TOKEN:-none}" "\$own" "\$old" >> "$T/calls.tsv"
if [ -e "$T/hold.\$p" ]; then for i in \$(seq 1 300); do [ -e "$T/release" ] && break; sleep 0.1; done; fi
: > "\$out"
echo "\$p" >> "$T/done.txt"
exit "\${STUB_AC_RC:-0}"
EOF
chmod +x "$H/bin/"*.sh

WAITFOR() { local i; for i in $(seq 1 300); do eval "$1" && return 0; sleep 0.2; done; return 1; }
# LOCKFREE <lock> — the lock is free within 10 s. A run holds its lock until it
# exits, and it still logs and stamps after its session returns (BH-6571).
LOCKFREE() { local i; for i in $(seq 1 100); do flock -n "$1" true && return 0; sleep 0.1; done; return 1; }
COL() { awk -F'\t' -v p="$1" -v c="$2" '$1 == p {print $c; exit}' "$T/calls.tsv"; }
NDONE() { grep -c . "$T/done.txt" 2>/dev/null; }
SNAP='{"projfix-a":{"tickets":[{"key":"PFA-1","status":"todo","waitingOn":"team","hours":30,"title":"alpha stuck"}]},
       "projfix-b":{"tickets":[{"key":"PFB-1","status":"todo","waitingOn":"team","hours":31,"title":"bravo stuck"}]}}'
# hist <project> — this project's own history, written at epoch 0 so the 90-minute
# window has always passed (no wall clock in the fixture).
hist() { mkdir -p "$H/state/watchdog-responder/$1"
  jq -nc --argjson s "$SNAP" --arg p "$1" '{ts:0, snap:{($p): $s[$p]}}' > "$H/state/watchdog-responder/$1/stale-history.json"; }
RESET() {
  local x
  for x in "$H/state/responder" "$H/state/watchdog-responder" "$H/state/build-queue" "$T/calls.tsv" "$T/done.txt" \
           "$T/release" "$T/hold.projfix-a" "$T/hold.projfix-b" "$T/prompt.projfix-a" "$T/prompt.projfix-b" \
           "$T/sweep.log" "$H/logs/responder.log" "$H/logs/watchdog-responder-cron.log"; do
    scratch_rm "$x" || exit 1
  done
  mkdir -p "$H/state/responder"; echo '{}' > "$H/state/responder/handled.json"
  : > "$T/calls.tsv"; : > "$T/done.txt"
  printf '%s\n' "$SNAP" | jq -c . > "$H/state/stale-owed.json"
  hist projfix-a; hist projfix-b
  mkdir -p "$H/state/build-queue/projfix-b"
  echo '{"key":"PFB-W9"}' > "$H/state/build-queue/projfix-b/PFB-W9.json"
  touch -d '@1000000000' "$H/state/build-queue/projfix-b/PFB-W9.json"
}

# ============================================================================
# R1-R4. ONE DISPATCH, TWO PROJECT RUNS.
# ============================================================================
RESET; touch "$T/hold.projfix-a"
OUT=$(bash "$H/bin/watchdog-responder.sh"); RC=$?
[ "$RC" = 0 ] && ok || bad "R1: dispatch exits 0 (rc=$RC)"
case "$OUT" in "watchdog-responder dispatch: started 2 project run(s)"*) ok ;; *) bad "R1: one dispatch line for 2 runs: $OUT" ;; esac
WAITFOR 'grep -qx projfix-b "$T/done.txt"' && ok || bad "R1: projfix-b finished its session (log: $(tail -5 "$H/logs/watchdog-responder-cron.log" 2>/dev/null))"
# projfix-a is held in its session, so its row comes; wait for it before the A-side reads.
WAITFOR '[ "$(COL projfix-a 1)" = projfix-a ]' || bad "R1: projfix-a's session started (calls: $(cat "$T/calls.tsv"))"
grep -qx projfix-a "$T/done.txt" && bad "R1: projfix-a's session must still be blocked when projfix-b finishes" || ok
[ "$(COL projfix-a 4)" = held ] && [ "$(COL projfix-b 4)" = held ] && ok \
  || bad "R1: each session runs under its own project lock (a=$(COL projfix-a 4) b=$(COL projfix-b 4))"
[ "$(COL projfix-a 5)" = free ] && [ "$(COL projfix-b 5)" = free ] && ok \
  || bad "R1: the old global locks/responder.lock is not held (a=$(COL projfix-a 5) b=$(COL projfix-b 5))"
LOCKFREE "$H/locks/watchdog-responder-projfix-b.lock" && ok || bad "R1: projfix-b's lock is free once its run ended"
flock -n "$H/locks/watchdog-responder-projfix-a.lock" true && bad "R1: projfix-a's lock is held while its run is live" || ok

# R2 — own stale ticket only.
grep -q 'PFB-1' "$T/prompt.projfix-b" && ok || bad "R2: projfix-b's prompt names PFB-1"
grep -q 'PFA-1' "$T/prompt.projfix-b" && bad "R2: projfix-b's prompt must not name projfix-a's PFA-1" || ok
# R3 — own wedged job only.
grep -q 'projfix-b PFB-W9 queued' "$T/prompt.projfix-b" && ok || bad "R3: projfix-b's prompt has its wedged job"
touch "$T/release"
WAITFOR 'grep -qx projfix-a "$T/done.txt"' && ok || bad "R1: projfix-a finishes after release"
WAITFOR '! pgrep -f "$H/bin/watchdog-responder.sh" >/dev/null' || bad "R1: the runs exit"
grep -q 'PFA-1' "$T/prompt.projfix-a" && ok || bad "R2: projfix-a's prompt names PFA-1"
grep -q 'PFB-1' "$T/prompt.projfix-a" && bad "R2: projfix-a's prompt must not name projfix-b's PFB-1" || ok
grep -q 'PFB-W9' "$T/prompt.projfix-a" && bad "R3: projfix-a's prompt must not carry projfix-b's wedged job" || ok
grep -q 'valid names, rendered from fleet.conf on this run: projfix-a ' "$T/prompt.projfix-a" && ok \
  || bad "R2: projfix-a's escalation contract names only its own project"

# R4 — account word and App token per run; no fleet-wide sweep.
[ "$(COL projfix-a 2)" = responder=projfix-a ] && [ "$(COL projfix-b 2)" = responder=projfix-b ] && ok \
  || bad "R4: ACCOUNT_PROJECT_FOR_LANE per run (a=$(COL projfix-a 2) b=$(COL projfix-b 2))"
[ "$(COL projfix-a 3)" = ghs_fixture_o_projfix-a ] && [ "$(COL projfix-b 3)" = ghs_fixture_o_projfix-b ] && ok \
  || bad "R4: each session carries its own App token after global.env (a=$(COL projfix-a 3) b=$(COL projfix-b 3))"
[ ! -e "$T/sweep.log" ] && ok || bad "R4: a project run does not run the fleet-wide stale-owed sweep"

# R5 — both runs' stamps survive.
K=$(jq -c 'keys' "$H/state/responder/handled.json")
[ "$K" = '["projfix-a:PFA-1","projfix-b:PFB-1","projfix-b:PFB-W9"]' ] && ok || bad "R5: both runs' keys are stamped, nothing else: $K"

# R5 — two runs released at the same moment.
RESET; touch "$T/hold.projfix-a" "$T/hold.projfix-b"
bash "$H/bin/watchdog-responder.sh" >/dev/null
WAITFOR '[ "$(grep -c . "$T/calls.tsv")" -ge 2 ]' || bad "R5 setup: two sessions started"
touch "$T/release"
WAITFOR '[ "$(NDONE)" -ge 2 ] && ! pgrep -f "$H/bin/watchdog-responder.sh" >/dev/null' || bad "R5 setup: both runs ended"
K=$(jq -c 'keys' "$H/state/responder/handled.json")
[ "$K" = '["projfix-a:PFA-1","projfix-b:PFB-1","projfix-b:PFB-W9"]' ] && ok || bad "R5: concurrent stamps keep both runs' keys: $K"

# R5 — the stamp lock is not free: nothing stamped, one line, the keys come back.
RESET
exec 7>"$H/state/responder/handled.json.lock"; flock -n 7 || bad "R5 setup: could not hold the handled lock"
bash "$H/bin/watchdog-responder.sh" projfix-a >/dev/null 2>&1; RC=$?
exec 7>&-
[ "$RC" = 0 ] && ok || bad "R5: a run whose stamp lock is busy still exits 0 (rc=$RC)"
[ "$(jq -c 'keys' "$H/state/responder/handled.json")" = '[]' ] && ok || bad "R5: a busy stamp lock stamps nothing: $(cat "$H/state/responder/handled.json")"
[ "$(grep -c 'project=projfix-a: handled.json lock not free in 5 s or the rewrite failed — nothing stamped' "$H/logs/responder.log")" = 1 ] && ok \
  || bad "R5: one log line for the busy lock: $(tail -3 "$H/logs/responder.log")"

# R5 — a session refused before the call stamps nothing.
RESET
STUB_AC_RC=76 bash "$H/bin/watchdog-responder.sh" projfix-a >/dev/null 2>&1
[ "$(COL projfix-a 1)" = projfix-a ] && ok || bad "R5: the refused run did reach agent-call"
[ "$(jq -c 'keys' "$H/state/responder/handled.json")" = '[]' ] && ok || bad "R5: rc 76 stamps nothing: $(cat "$H/state/responder/handled.json")"

# ============================================================================
# R6. THE PROJECT'S OWN HISTORY.
# ============================================================================
RESET; scratch_rm "$H/state/watchdog-responder" || exit 1
bash "$H/bin/watchdog-responder.sh" projfix-a >/dev/null 2>&1
[ "$(grep -c . "$T/calls.tsv")" = 0 ] && ok || bad "R6: a first pass with no history makes no call"
HF="$H/state/watchdog-responder/projfix-a/stale-history.json"
[ "$(jq -c '.snap | keys' "$HF" 2>/dev/null)" = '["projfix-a"]' ] && ok || bad "R6: the history holds only projfix-a's snapshot: $(cat "$HF" 2>/dev/null)"
jq -c '.ts = 0' "$HF" > "$HF.tmp" && mv "$HF.tmp" "$HF"     # the next pass, 90+ minutes later
bash "$H/bin/watchdog-responder.sh" projfix-a >/dev/null 2>&1
[ "$(COL projfix-a 1)" = projfix-a ] && grep -q 'PFA-1' "$T/prompt.projfix-a" && ok \
  || bad "R6: the second pass finds PFA-1 persisted in its own history (calls: $(cat "$T/calls.tsv"))"
[ ! -e "$H/state/responder/stale-history.json" ] && ok || bad "R6: no shared stale-history.json is written"

# ============================================================================
# R7 — a scripted-fix stamp (bin/lib/responder-fix.sh _rfix_stamp) never erases
# another project run's keys (lead BLOCK at 897dab888). A run holds the
# handled.json lock across its read-modify-write (watchdog-responder.sh's
# stamp); a scripted stamp that lands in the middle must wait for it, so both
# keys survive. Two scripted stamps at the same time both survive too.
# ============================================================================
R7="$T/r7"; mkdir -p "$R7"; echo '{"old:1":1}' > "$R7/handled.json"
printf 'fix:1\n' > "$R7/keys-fix"; printf 'fix:2\n' > "$R7/keys-fix2"
( exec 8>"$R7/handled.json.lock"; flock 8
  base=$(cat "$R7/handled.json"); sleep 1.5
  jq -c '. + {"run:A": 5}' <<<"$base" > "$R7/handled.json.A.tmp" && mv "$R7/handled.json.A.tmp" "$R7/handled.json" ) &
RUNA=$!
sleep 0.4
for kf in keys-fix keys-fix2; do
  ( HANDLED="$R7/handled.json" HANDLED_LOCK="$R7/handled.json.lock" NOW=7 LOG="$R7/log" LLP_PROJECT="p-$kf" BRAKE_DB=0
    STAMP() { echo t; }; . "$DIR/bin/lib/responder-fix.sh" 2>/dev/null; _rfix_stamp "$R7/$kf" ) &
done
wait
for k in old:1 run:A fix:1 fix:2; do
  jq -e --arg k "$k" 'has($k)' "$R7/handled.json" >/dev/null 2>&1 && ok \
    || bad "R7: handled.json lost $k under concurrent stamps: $(cat "$R7/handled.json")"
done
ls "$R7"/*.tmp >/dev/null 2>&1 && bad "R7: a temp file was left behind: $(ls "$R7")" || ok

echo "responder-per-project.bh-5942: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
