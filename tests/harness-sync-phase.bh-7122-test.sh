#!/bin/bash
# tests/harness-sync-phase.bh-7122-test.sh — bin/harness-sync.sh writes how far
# it got, cuts each post-copy step at its own timeout, and keeps a deploy step
# pending until it succeeds.
#
# WHY (BH-7122). fleet-propagate runs the whole sync under one outer timeout.
# The code copy runs early and most kills land after it, so a kill paged
# "Still running the OLD harness: hub" while the live bin/ was already new.
#
# Cases (H1-H6, H8, H9, H11 drive bin/harness-sync.sh itself against a scratch
# $HARNESS and a real bare origin + clone; H7 and H10 drive the detached runner
# bin/harness-sync-step.sh):
#   H1  a clean sync stamps `done <HEAD>`; inside agent-rules it read
#       `step=agent-rules <HEAD>`
#   H2  agent-rules hangs, post-step 2 s: rc 0, `step=agent-rules rc=124`,
#       secs < 20, the later steps ran, the success stamp exists
#   H3  agent-rules hangs, post-step 600 s, outer timeout 5 s: the stamp says
#       `step=agent-rules <HEAD>` and the live bin/ is the new code
#   H4  `wrangler deploy` hangs, post-step 2 s: marker `rc=124 1`, one ALERTS
#       line naming worker-phase, no worker-deployed stamp
#   H6  the same failure again at the same sha: still one ALERTS line
#   H5  the next sync with a working deploy re-runs it: deploy count 0 -> 1,
#       marker gone, `re-running pending step worker-phase`, `rc=0`
#   H7  runner, lock held: `rc=busy`, command not run, marker still queued
#   H8  knob from the settings row (3 s cuts at 3-10 s); `abc` is 240 + one line
#   H9  HARNESS_SYNC_POST_STEP_TIMEOUT_S=0 is 240 + one line
#   H10 runner rc 0 with another sha keeps the marker; the same sha clears it
#   H11 no lib anywhere: rc 0, no phase file, no step line (today's behaviour)
#
# Run from anywhere: tests/harness-sync-phase.bh-7122-test.sh (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null && command -v timeout >/dev/null \
  && command -v pgrep >/dev/null \
  || { echo "harness-sync-phase.bh-7122-test: SKIPPED — git/flock/timeout/pgrep missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x

LIB="$DIR/bin/lib/harness-sync-step.sh"
RUNNER="$DIR/bin/harness-sync-step.sh"
STUBPIDS="$T/stub.pids"; : > "$STUBPIDS"
kill_stubs() {
  local p
  for p in $(cat "$STUBPIDS" 2>/dev/null); do kill "$p" 2>/dev/null; done
}
trap 'kill_stubs; __scratch_exit_trap' EXIT

mkdir -p "$T/fakebin"
# npx: `wrangler deploy` hangs when $T/npx.mode says sleep, else counts a deploy.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
case "\$*" in *"wrangler deploy"*) ;; *) exit 0 ;; esac
if [ "\$(cat "$T/npx.mode" 2>/dev/null)" = sleep ]; then
  echo \$\$ >> "$STUBPIDS"
  for _ in \$(seq 1 600); do sleep 1; done   # determinism: ok — the hung deploy of the ticket; cut by the step timeout
fi
echo ok >> "$T/deploys"
exit 0
EOF
chmod +x "$T/fakebin/npx"

# mkrepo <origin> <clone> <with-lib 0|1> — a bare origin and the box checkout.
mkrepo() {
  local o="$1" c="$2"
  git init -q --bare "$o"
  git clone -q "$o" "$c" 2>/dev/null
  mkdir -p "$c/bin/lib" "$c/prompts" "$c/fly" "$c/catalog" "$c/worker/jobs/src"
  printf '#!/bin/bash\n:\n' > "$c/bin/x.sh"
  printf 'p\n' > "$c/prompts/p.md"
  printf 'f\n' > "$c/fly/f.txt"
  printf 'fleet\n' > "$c/fleet.conf"
  if [ "$3" = 1 ]; then
    scratch_install_closure bin/harness-sync-step.sh "$c" >/dev/null || exit 1
  fi
  cp "$DIR/bin/alert-line.sh" "$c/bin/"
  # agent-rules: copies the phase stamp while it runs; hangs in mode sleep.
  cat > "$c/bin/sync-agent-rules.sh" <<EOF
#!/bin/bash
[ "\${1:-}" = apply ] || exit 0
cp "\$HARNESS/state/harness-sync-phase" "$T/phase.during-agent-rules" 2>/dev/null
if [ "\$(cat "$T/agent.mode" 2>/dev/null)" = sleep ]; then
  echo \$\$ >> "$STUBPIDS"
  for _ in \$(seq 1 600); do sleep 1; done   # determinism: ok — the hung step of the ticket; cut by the step timeout
fi
exit 0
EOF
  # codegraph: the last step; its start file proves the later steps ran.
  cat > "$c/bin/codegraph-harness-index.sh" <<EOF
#!/bin/bash
: > "$T/codegraph.started"
EOF
  # jobs-client: answers only the post-step settings row, from $T/setting.val.
  cat > "$c/bin/jobs-client.sh" <<EOF
#!/bin/bash
if [ "\${1:-}" = setting-get ] && [ "\${2:-}" = lane.fleet-propagate.harness_sync_post_step_timeout_s ]; then
  echo get >> "$T/setting.calls"
  cat "$T/setting.val" 2>/dev/null
  exit 0
fi
exit 1
EOF
  chmod +x "$c/bin/"*.sh
  cat > "$c/worker/jobs/wrangler.toml" <<'EOF'
name = "jobs-test"
main = "src/index.js"
compatibility_date = "2026-07-01"
EOF
  printf 'export default { fetch: () => new Response("ok") };\n' > "$c/worker/jobs/src/index.js"
  git -C "$c" add -A >/dev/null
  git -C "$c" commit -qm seed
  git -C "$c" branch -M main 2>/dev/null
  git -C "$c" push -q origin main
  git -C "$c" branch --set-upstream-to=origin/main main >/dev/null 2>&1
}
# mklive <dir> — a scratch live install with cloudflare credentials (fixture).
mklive() {
  mkdir -p "$1/bin" "$1/logs" "$1/state" "$1/locks" "$1/flags" "$1/env"
  cp "$DIR/bin/alert-line.sh" "$1/bin/"
  printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$1/env/cloudflare.env"
}
mkrepo "$T/origin" "$T/ck" 1
mklive "$T/h"
H="$T/h"; RUNLOG="$H/logs/update-runners.log"; PHASE="$H/state/harness-sync-phase"
PEND="$H/state/harness-sync-pending"

# sync [outer-timeout] — bin/harness-sync.sh itself -> rc in $RC. The env knob
# rides in $POST (unset when empty).
sync() {
  ( export HARNESS="$H" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    if [ -n "${POST:-}" ]; then export HARNESS_SYNC_POST_STEP_TIMEOUT_S="$POST"; else unset HARNESS_SYNC_POST_STEP_TIMEOUT_S; fi
    timeout "${1:-90}" bash "${HSYNC:-$DIR/bin/harness-sync.sh}" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
commit_push() { # commit_push <file> <content>
  printf '%s\n' "$2" > "$T/ck/$1"
  git -C "$T/ck" add -A >/dev/null
  git -C "$T/ck" commit -qm "$1"
  git -C "$T/ck" push -q origin main
}
head40() { git -C "$T/ck" rev-parse HEAD; }
reset_case() { : > "$RUNLOG"; : > "$H/logs/ALERTS.log"; rm -f "$T/codegraph.started" "$T/phase.during-agent-rules" "$T/setting.calls"; kill_stubs; : > "$STUBPIDS"; }
nalerts() { grep -c "$1" "$H/logs/ALERTS.log" 2>/dev/null || true; }

# ── S0. SAFETY PROBE: a dirty checkout refuses at rc 30 inside $T ────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$H/logs/ALERTS.log" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC) — refusing to run the deploy path."
  echo "harness-sync-phase.bh-7122-test: 0 pass, 1 fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh

# ── H1. a clean sync: `done <HEAD>`, and `step=agent-rules <HEAD>` inside it ─
reset_case; echo ok > "$T/agent.mode"; echo ok > "$T/npx.mode"; POST=""
sync
SHA=$(head40)
[ "$RC" = 0 ] && ok || bad "H1 a clean sync must be rc 0 (rc=$RC: $(cat "$T/err.txt"))"
P1=""; S1=""; TS1=""; read -r P1 S1 TS1 < "$PHASE" 2>/dev/null
[ "$P1 $S1" = "done $SHA" ] && ok || bad "H1 the phase stamp must be 'done $SHA', got: $(cat "$PHASE" 2>/dev/null)"
[[ "${TS1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]] && ok || bad "H1 the stamp's third field must be an ISO time, got '${TS1:-}'"
[ "$(cut -d' ' -f1-2 "$T/phase.during-agent-rules" 2>/dev/null)" = "step=agent-rules $SHA" ] && ok \
  || bad "H1 inside agent-rules the stamp must read 'step=agent-rules $SHA', got: $(cat "$T/phase.during-agent-rules" 2>/dev/null)"
grep -q 'harness sync: step=agent-rules rc=0 secs=[0-9]' "$RUNLOG" && ok || bad "H1 agent-rules must write its step line: $(cat "$RUNLOG")"
grep -q 'harness sync: step=worker-phase rc=0 secs=' "$RUNLOG" && ok || bad "H1 the worker phase must write its step line: $(cat "$RUNLOG")"
[ "$(grep -c . "$T/deploys" 2>/dev/null)" = 1 ] && ok || bad "H1 the worker must deploy once"
[ ! -e "$PEND/worker-phase" ] && ok || bad "H1 a worker phase that ended rc 0 must clear its marker: $(cat "$PEND/worker-phase" 2>/dev/null)"
[ "$(nalerts 'harness sync step')" = 0 ] && ok || bad "H1 a clean sync must not alert: $(cat "$H/logs/ALERTS.log")"

# ── H2. agent-rules hangs; post-step 2 s cuts it; the later steps still run ──
reset_case; echo sleep > "$T/agent.mode"; POST=2
commit_push bin/x.sh '#!/bin/bash
echo h2'
sync 60
[ "$RC" = 0 ] && ok || bad "H2 a cut step must leave harness-sync rc 0 (rc=$RC)"
L=$(grep -o 'step=agent-rules rc=124 secs=[0-9]*' "$RUNLOG")
SECS=${L##*secs=}
[ -n "$L" ] && [ "${SECS:-99}" -lt 20 ] && ok || bad "H2 want 'step=agent-rules rc=124 secs=<20', got '$L' in: $(cat "$RUNLOG")"
[ -e "$T/codegraph.started" ] && ok || bad "H2 the steps after the cut one must still run (codegraph never started)"
[ -e "$H/state/harness-sync-last-success" ] && ok || bad "H2 the success stamp must be written after a cut step"
[ "$(cut -d' ' -f1-2 "$PHASE")" = "done $(head40)" ] && ok || bad "H2 the sync must still end 'done', got: $(cat "$PHASE")"

# ── H3. agent-rules hangs past the OUTER timeout: the stamp names the step ───
reset_case; echo sleep > "$T/agent.mode"; POST=600
commit_push bin/x.sh '#!/bin/bash
echo h3'
sync 5
[ "$RC" = 124 ] && ok || bad "H3 the outer timeout must cut the sync (rc=$RC)"
[ "$(cut -d' ' -f1-2 "$PHASE")" = "step=agent-rules $(head40)" ] && ok \
  || bad "H3 the stamp must say 'step=agent-rules $(head40)', got: $(cat "$PHASE")"
cmp -s "$T/ck/bin/x.sh" "$H/bin/x.sh" && ok || bad "H3 the live bin/ must already hold the new code"
kill_stubs

# ── H4. `wrangler deploy` hangs: the worker phase is cut, pending, ONE alert ──
reset_case; echo ok > "$T/agent.mode"; echo sleep > "$T/npx.mode"; POST=2
: > "$T/deploys"; rm -f "$H/state/worker-deployed-jobs"
commit_push worker/jobs/src/index.js 'export default { fetch: () => new Response("h4") };'
sync 60
SHA=$(head40)
[ "$RC" = 0 ] && ok || bad "H4 a cut deploy step must leave harness-sync rc 0 (rc=$RC)"
MS=""; MST=""; MAL=""; read -r MS _ MST MAL < "$PEND/worker-phase" 2>/dev/null
[ "$MS $MST $MAL" = "$SHA rc=124 1" ] && ok || bad "H4 marker must read '$SHA <epoch> rc=124 1', got: $(cat "$PEND/worker-phase" 2>/dev/null)"
[ "$(nalerts 'harness sync step worker-phase')" = 1 ] && ok || bad "H4 want exactly 1 ALERTS line naming worker-phase: $(cat "$H/logs/ALERTS.log")"
[ ! -e "$H/state/worker-deployed-jobs" ] && ok || bad "H4 a cut deploy must not stamp worker-deployed"
grep -q 'step=worker-phase rc=124 secs=' "$RUNLOG" && ok || bad "H4 the step line must say rc=124: $(cat "$RUNLOG")"
kill_stubs

# ── H6. the same failure at the same sha: no second ALERT ───────────────────
: > "$RUNLOG"
sync 60
[ "$(nalerts 'harness sync step worker-phase')" = 1 ] && ok || bad "H6 the same failure at the same sha must not alert twice: $(cat "$H/logs/ALERTS.log")"
grep -q "re-running pending step worker-phase from ${SHA:0:7} (rc=124)" "$RUNLOG" && ok \
  || bad "H6 the second sync must log the re-run: $(cat "$RUNLOG")"
kill_stubs

# ── H5. the next sync with a working deploy re-runs the pending step ────────
reset_case; echo ok > "$T/npx.mode"; POST=2; : > "$T/deploys"
sync 60
[ "$(grep -c . "$T/deploys")" = 1 ] && ok || bad "H5 the pending deploy must run once on the next sync (got $(grep -c . "$T/deploys"))"
[ ! -e "$PEND/worker-phase" ] && ok || bad "H5 a re-run that ends rc 0 must clear the marker: $(cat "$PEND/worker-phase" 2>/dev/null)"
grep -q 're-running pending step worker-phase' "$RUNLOG" && ok || bad "H5 the re-run must be logged: $(cat "$RUNLOG")"
grep -q 'step=worker-phase rc=0 secs=' "$RUNLOG" && ok || bad "H5 the step line must say rc=0: $(cat "$RUNLOG")"
[ -e "$H/state/worker-deployed-jobs" ] && ok || bad "H5 the re-run deploy must stamp worker-deployed"

# ── H7. runner: a held lock is rc=busy, no launch, the marker stays queued ──
reset_case
( HARNESS="$H" HS_SHA="$SHA"; . "$LIB"; hs_pending_queue console-pages )
LOCKF="$H/locks/console-pages-deploy.lock"; : > "$LOCKF"
exec 3>"$LOCKF"; flock -n 3
( HARNESS="$H" bash "$RUNNER" --step console-pages --kind deploy --lock "$LOCKF" --sha "$SHA" \
    -- bash -c ": > '$T/h7.started'" ) >/dev/null 2>&1
exec 3>&-
grep -q 'harness sync: step=console-pages rc=busy secs=0' "$RUNLOG" && ok || bad "H7 a busy lock must write rc=busy: $(cat "$RUNLOG")"
[ ! -e "$T/h7.started" ] && ok || bad "H7 a busy lock must not launch the command"
[ "$(cut -d' ' -f3 "$PEND/console-pages" 2>/dev/null)" = queued ] && ok || bad "H7 the marker must stay queued: $(cat "$PEND/console-pages" 2>/dev/null)"
# The same runner with the lock free runs the command and clears the marker.
( HARNESS="$H" bash "$RUNNER" --step console-pages --kind deploy --lock "$LOCKF" --sha "$SHA" \
    -- bash -c ": > '$T/h7.started'" ) >/dev/null 2>&1
[ -e "$T/h7.started" ] && [ ! -e "$PEND/console-pages" ] && ok || bad "H7 a free lock must run the command and clear the marker"

# ── H10. runner rc 0 with ANOTHER sha keeps the marker ──────────────────────
reset_case
( HARNESS="$H" HS_SHA="$SHA"; . "$LIB"; hs_pending_queue model-prices )
OTHER=0000000000000000000000000000000000000001
( HARNESS="$H" bash "$RUNNER" --step model-prices --kind deploy --sha "$OTHER" -- true ) >/dev/null 2>&1
[ -e "$PEND/model-prices" ] && ok || bad "H10 an rc 0 from another sha must not clear the marker"
( HARNESS="$H" bash "$RUNNER" --step model-prices --kind deploy --sha "$SHA" -- bash -c 'exit 3' ) >/dev/null 2>&1
[ "$(cut -d' ' -f3- "$PEND/model-prices")" = "rc=3 1" ] && ok || bad "H10 a failed runner step must mark rc=3 and alert: $(cat "$PEND/model-prices")"
[ "$(nalerts 'harness sync step model-prices')" = 1 ] && ok || bad "H10 one ALERTS line for the failed runner step"
grep -q 'step=model-prices rc=3 secs=' "$RUNLOG" && ok || bad "H10 the runner must write the step line"
( HARNESS="$H" bash "$RUNNER" --step model-prices --kind deploy --sha "$SHA" -- true ) >/dev/null 2>&1
[ ! -e "$PEND/model-prices" ] && ok || bad "H10 an rc 0 from the same sha must clear the marker"

# ── H8. the knob from the settings row; a bad row value is 240 + one line ───
reset_case; echo sleep > "$T/agent.mode"; POST=""; echo 3 > "$T/setting.val"
commit_push bin/x.sh '#!/bin/bash
echo h8'
sync 60
L=$(grep -o 'step=agent-rules rc=124 secs=[0-9]*' "$RUNLOG"); SECS=${L##*secs=}
[ -n "$L" ] && [ "$SECS" -ge 3 ] && [ "$SECS" -le 10 ] && ok \
  || bad "H8 the settings row 3 must cut agent-rules at 3-10 s, got '$L': $(cat "$RUNLOG")"
[ "$(grep -c . "$T/setting.calls" 2>/dev/null)" = 1 ] && ok || bad "H8 the row must be read once per run (got $(grep -c . "$T/setting.calls" 2>/dev/null))"
kill_stubs
reset_case; echo ok > "$T/agent.mode"; echo abc > "$T/setting.val"
sync 60
[ "$RC" = 0 ] && ok || bad "H8 rc=$RC"
[ "$(grep -c 'harness_sync_post_step_timeout_s=abc is not a number of seconds above 0 — post-copy steps use 240s' "$RUNLOG")" = 1 ] && ok \
  || bad "H8 a bad row must log exactly one line and use 240: $(cat "$RUNLOG")"
rm -f "$T/setting.val"

# ── H9. HARNESS_SYNC_POST_STEP_TIMEOUT_S=0 is 240 + one line ────────────────
reset_case; POST=0
sync 60
[ "$(grep -c 'HARNESS_SYNC_POST_STEP_TIMEOUT_S=0 is not a number of seconds above 0 — post-copy steps use 240s' "$RUNLOG")" = 1 ] && ok \
  || bad "H9 env 0 must log exactly one line and use 240: $(cat "$RUNLOG")"
grep -q 'step=agent-rules rc=0' "$RUNLOG" && ok || bad "H9 the steps must still run"

# ── H11. no lib anywhere: today's behaviour, no phase file, no step line ────
mkrepo "$T/origin11" "$T/ck11" 0
mklive "$T/h11"
mkdir -p "$T/solo"; cp "$DIR/bin/harness-sync.sh" "$T/solo/harness-sync.sh"
: > "$T/agent.mode"
( export HARNESS="$T/h11" HARNESS_CHECKOUT="$T/ck11" PATH="$T/fakebin:$PATH"
  timeout 60 bash "$T/solo/harness-sync.sh" ) >"$T/out11.txt" 2>"$T/err11.txt"
RC=$?
[ "$RC" = 0 ] && ok || bad "H11 a sync with no lib must be rc 0 (rc=$RC: $(cat "$T/err11.txt"))"
[ ! -e "$T/h11/state/harness-sync-phase" ] && ok || bad "H11 no lib must write no phase file"
grep -q 'step=' "$T/h11/logs/update-runners.log" 2>/dev/null && bad "H11 no lib must write no step line" || ok
[ -e "$T/h11/state/worker-deployed-jobs" ] && ok || bad "H11 the worker must still deploy without the lib"

echo "harness-sync-phase.bh-7122-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
