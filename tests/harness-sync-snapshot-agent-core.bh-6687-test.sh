#!/bin/bash
# tests/harness-sync-snapshot-agent-core.bh-6687-test.sh — the worker deploy
# snapshot carries agent-core/, and a failing deploy alerts at most once per
# interval while it keeps failing (BH-6687).
#
# WHY. worker/jobs/src/routes/staff*.js import ../../../../agent-core/ (BH-5559).
# snapshot_tree() in bin/harness-sync.sh archived worker/, catalog/ and the
# composers but not agent-core/, so `wrangler deploy` could not bundle and
# harness-jobs did not deploy from 2026-10-10 to 2026-10-14. Each failed pass
# wrote one ALERTS line: 694 lines in 4 days.
#
#   S0     safety probe: a dirty checkout refuses at rc 30.
#   A1-A6  the snapshot carries agent-core/ (and skips it on a commit without
#          it), the import resolves from the snapshot, and a worker that
#          imports agent-core/ keys its deploy on it (-core-<sha>).
#   R1-R10 the `wrangler deploy FAILED` alert: first failure alerts, a failure
#          inside HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S is held (one log line),
#          one at or past it alerts again, 0 alerts every time, a bad knob is
#          3600, corrupt or future state counts as absent, recovery clears the
#          state, state is per worker, and the settings row is read.
#
# The clock is pinned with HARNESS_SYNC_NOW.
# Run from anywhere: tests/harness-sync-snapshot-agent-core.bh-6687-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/locks" "$T/flags" "$T/prompts" \
         "$T/fly" "$T/catalog" "$T/checks" "$T/guardrails" "$T/config" "$T/env" "$T/fakebin"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v git >/dev/null && command -v flock >/dev/null \
  || { echo "git/flock missing — skipping"; exit 0; }

ALERTS="$T/logs/ALERTS.log"
ULOG="$T/logs/update-runners.log"
NPXLOG="$T/npx.log"
printf 'CLOUDFLARE_ACCOUNT_ID=fixture-account\nCLOUDFLARE_API_TOKEN=fixture-not-a-real-token\n' > "$T/env/cloudflare.env"
HAVE_NODE=0; command -v node >/dev/null && HAVE_NODE=1

# A fake npx that RECORDS instead of deploying. On `wrangler deploy` it says
# whether the snapshot carries agent-core/, tries the jobs import from the
# snapshot when node is there, and fails when $T/wrangler-fail-<w> exists.
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
NPX_LOG="$NPXLOG"
T="$T"
EOF
cat >> "$T/fakebin/npx" <<'EOF'
args=$(printf '%s ' "$@" | tr '\n\t' '  ')
printf '%s | %s\n' "$PWD" "$args" >> "$NPX_LOG"
if [ "${2:-}" = "wrangler" ] && [ "${3:-}" = "deploy" ]; then
  w=$(basename "$PWD")
  if [ -f "$PWD/../../agent-core/src/index.js" ]; then echo yes; else echo no; fi > "$T/snap-core-$w"
  if [ -f "$PWD/src/routes/staff-findings.js" ] && command -v node >/dev/null; then
    node --input-type=module -e "await import('$PWD/src/routes/staff-findings.js')" >/dev/null 2>&1
    echo $? > "$T/import-rc-$w"
  fi
  [ -f "$T/wrangler-fail-$w" ] && exit 1
fi
exit 0
EOF
chmod +x "$T/fakebin/npx"

if ! command -v rsync >/dev/null; then
  cat > "$T/fakebin/rsync" <<'EOF'
#!/bin/bash
paths=()
for a in "$@"; do case "$a" in -*) ;; *) paths+=("$a") ;; esac; done
SRC="${paths[0]:-}"; DST="${paths[1]:-}"
[ -d "$SRC" ] && [ -n "$DST" ] || exit 0
mkdir -p "$DST" && cp -a "$SRC". "$DST" 2>/dev/null
exit 0
EOF
  chmod +x "$T/fakebin/rsync"
fi

git init -q --bare "$T/origin"
git clone -q "$T/origin" "$T/ck" 2>/dev/null
git -C "$T/ck" config user.email t@t; git -C "$T/ck" config user.name t
mkdir -p "$T/ck/bin" "$T/ck/prompts" "$T/ck/fly" "$T/ck/catalog" \
         "$T/ck/worker/jobs/src/routes" "$T/ck/worker/plain/src" "$T/ck/agent-core/src"
printf '#!/bin/bash\n:\n' > "$T/ck/bin/x.sh"
printf 'p\n' > "$T/ck/prompts/p.md"
printf 'f\n' > "$T/ck/fly/f.txt"
printf '{}\n' > "$T/ck/catalog/c.json"
printf 'fleet\n' > "$T/ck/fleet.conf"
# worker/jobs: no D1 binding (no schema apply), one route that imports agent-core/.
cat > "$T/ck/worker/jobs/wrangler.jsonc" <<'EOF'
{ "name": "jobs-test", "main": "src/index.js" }
EOF
printf 'export default {};\n' > "$T/ck/worker/jobs/src/index.js"
printf 'import { fingerprint } from "../../../../agent-core/src/index.js";\nexport const f = fingerprint;\n' \
  > "$T/ck/worker/jobs/src/routes/staff-findings.js"
printf 'export const fingerprint = () => "x";\n' > "$T/ck/agent-core/src/index.js"
printf '{ "name": "@fixture/agent-core", "type": "module", "private": true }\n' > "$T/ck/agent-core/package.json"
# worker/plain: no agent-core/ import.
cat > "$T/ck/worker/plain/wrangler.toml" <<'EOF'
name = "plain-test"
main = "src/index.js"
EOF
printf 'export default {};\n' > "$T/ck/worker/plain/src/index.js"
git -C "$T/ck" add -A >/dev/null
git -C "$T/ck" commit -qm seed
git -C "$T/ck" branch -M main 2>/dev/null
git -C "$T/ck" push -q origin main
git -C "$T/ck" branch --set-upstream-to=origin/main main >/dev/null 2>&1

sync() {
  ( export HARNESS="$T" HARNESS_CHECKOUT="$T/ck" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/harness-sync.sh" "$@" ) >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
}
reset_run() { : > "$NPXLOG"; : > "$ALERTS"; : > "$ULOG"; rm -f "$T"/snap-core-* "$T"/import-rc-*; }
deployed() { grep -F 'wrangler deploy' "$NPXLOG" 2>/dev/null | grep -cF "/worker/$1 "; }
push() { git -C "$T/ck" add -A >/dev/null; git -C "$T/ck" commit -qm "$1"; git -C "$T/ck" push -q origin main; }
failed_alerts() { grep -c 'wrangler deploy FAILED' "$ALERTS" 2>/dev/null; }
# failed_has <text> [last]: a 'wrangler deploy FAILED' line (or only the last
# one) carries <text>. Captured first, so no grep -q ends a live pipe.
failed_has() {
  local lines
  lines=$(grep -F 'wrangler deploy FAILED' "$ALERTS" 2>/dev/null)
  [ "${2:-}" = last ] && lines=$(printf '%s\n' "$lines" | tail -1)
  case "$lines" in *"$1"*) return 0 ;; esac
  return 1
}
FST="$T/state/worker-deploy-failing-jobs"

# ── S0. SAFETY PROBE: a dirty checkout must refuse at rc 30 into
#    $HARNESS/logs/ALERTS.log, or the deploy path below would rsync this
#    fixture over the live /root/harness. ─────────────────────────────────────
echo probe >> "$T/ck/bin/x.sh"
sync
if [ "$RC" != 30 ] || ! grep -q 'harness sync REFUSED' "$ALERTS" 2>/dev/null; then
  echo "FAIL: bin/harness-sync.sh does not honour \$HARNESS (rc=$RC, nothing in $ALERTS) —"
  echo "      refusing to run the deploy path, which would rsync this fixture over the live /root/harness."
  echo "harness-sync-snapshot-agent-core.bh-6687-test: $PASS pass, $((FAIL+1)) fail"
  exit 1
fi
ok
git -C "$T/ck" checkout -q -- bin/x.sh
reset_run

# ── A1. the deploy snapshot carries agent-core/, and the import resolves ─────
sync
[ "$RC" = 0 ] && ok || bad "A1: a clean sync must exit 0, got $RC: $(cat "$T/err.txt")"
[ "$(cat "$T/snap-core-jobs" 2>/dev/null)" = yes ] \
  && ok || bad "A1: the jobs deploy snapshot must carry agent-core/src/index.js (snap-core-jobs=$(cat "$T/snap-core-jobs" 2>/dev/null || echo none))"
if [ "$HAVE_NODE" = 1 ]; then
  [ "$(cat "$T/import-rc-jobs" 2>/dev/null)" = 0 ] \
    && ok || bad "A1: staff-findings.js must import agent-core/ from the snapshot (node rc=$(cat "$T/import-rc-jobs" 2>/dev/null || echo none))"
fi
grep -qF 'worker jobs deployed at' "$ULOG" && ok || bad "A1: update-runners.log must say 'worker jobs deployed at': $(cat "$ULOG")"
# ── A3 (pass 1). a worker with no agent-core/ import deploys too ─────────────
[ "$(deployed plain)" = 1 ] && ok || bad "A3: worker plain must deploy in pass 1: $(cat "$NPXLOG")"
[ ! -s "$ALERTS" ] && ok || bad "A1: a clean pass writes no ALERT: $(cat "$ALERTS")"

# ── A4. only the worker that imports agent-core/ keys on it ──────────────────
CORE1=$(git -C "$T/ck" rev-list -1 HEAD -- agent-core)
case "$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" in
  *"-core-$CORE1") ok ;;
  *) bad "A4: the jobs stamp must end in -core-$CORE1: $(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" ;;
esac
case "$(cat "$T/state/worker-deployed-plain" 2>/dev/null)" in
  *-core-*|'') bad "A4: the plain stamp must exist and carry no -core- part: $(cat "$T/state/worker-deployed-plain" 2>/dev/null)" ;;
  *) ok ;;
esac

# ── A6. a pass with no change deploys nothing ────────────────────────────────
reset_run
sync
[ "$(grep -cF 'wrangler deploy' "$NPXLOG")" = 0 ] && ok || bad "A6: an unchanged pass runs no wrangler deploy: $(cat "$NPXLOG")"

# ── A5. an agent-core/-only commit redeploys jobs and not plain ──────────────
reset_run
printf 'export const fingerprint = () => "y";\n' > "$T/ck/agent-core/src/index.js"
push "agent-core only"
sync
[ "$(deployed jobs)" = 1 ] && ok || bad "A5: an agent-core/-only commit must redeploy jobs: $(cat "$NPXLOG")"
[ "$(deployed plain)" = 0 ] && ok || bad "A5: an agent-core/-only commit must not redeploy plain: $(cat "$NPXLOG")"
CORE2=$(git -C "$T/ck" rev-list -1 HEAD -- agent-core)
case "$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" in
  *"-core-$CORE2") ok ;;
  *) bad "A5: the jobs stamp must move to -core-$CORE2: $(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" ;;
esac

# ── R1. the first failure alerts once, with the count, and stamps nothing ────
# The same commit moves plain, which deploys fine (R9).
reset_run
cp "$T/state/worker-deployed-jobs" "$T/wd.before"
touch "$T/wrangler-fail-jobs"
printf 'export default { v: 2 };\n' > "$T/ck/worker/jobs/src/index.js"
printf 'export default { v: 2 };\n' > "$T/ck/worker/plain/src/index.js"
push "move both workers"
HARNESS_SYNC_NOW=1000000 sync
[ "$RC" = 0 ] && ok || bad "R1: a failed deploy must not fail the sync, got $RC"
[ "$(failed_alerts)" = 1 ] && ok || bad "R1: exactly one 'wrangler deploy FAILED' ALERT: $(cat "$ALERTS")"
failed_has '(1 failed attempt(s))' \
  && ok || bad "R1: the ALERT must carry '(1 failed attempt(s))': $(cat "$ALERTS")"
failed_has 'failing since 1970-01-12 13:46:40Z' \
  && ok || bad "R1: the ALERT must say when it started failing: $(cat "$ALERTS")"
[ "$(cat "$FST" 2>/dev/null)" = "1000000 1000000 1" ] \
  && ok || bad "R1: the failing state must be '1000000 1000000 1': $(cat "$FST" 2>/dev/null || echo absent)"
cmp -s "$T/state/worker-deployed-jobs" "$T/wd.before" \
  && ok || bad "R1: a failed deploy must not move state/worker-deployed-jobs"
# ── R9. per-worker state: plain deployed, and has no failing state ───────────
[ "$(deployed plain)" = 1 ] && ok || bad "R9: plain must deploy in the same pass: $(cat "$NPXLOG")"
[ ! -e "$T/state/worker-deploy-failing-plain" ] && ok || bad "R9: plain must have no failing state"
grep -qF 'worker plain deployed at' "$ULOG" && ok || bad "R9: plain must log its deploy: $(cat "$ULOG")"

# ── R2. a failure inside the interval is held: one log line, no ALERT ────────
reset_run
HARNESS_SYNC_NOW=1000100 sync
[ "$(deployed jobs)" = 1 ] && ok || bad "R2: the failed worker is retried on the next pass: $(cat "$NPXLOG")"
[ "$(failed_alerts)" = 0 ] && ok || bad "R2: a failure inside the interval writes no ALERT: $(cat "$ALERTS")"
[ "$(grep -c 'worker jobs deploy FAILED again (2 since 1970-01-12 13:46:40Z); alert held, next in 3500s' "$ULOG")" = 1 ] \
  && ok || bad "R2: one 'alert held' line in update-runners.log: $(cat "$ULOG")"
[ "$(cat "$FST" 2>/dev/null)" = "1000000 1000000 2" ] \
  && ok || bad "R2: the failing state must be '1000000 1000000 2': $(cat "$FST" 2>/dev/null)"

# ── R3. at the interval (now - last = 3600) it alerts again ──────────────────
reset_run
HARNESS_SYNC_NOW=1003600 sync
[ "$(failed_alerts)" = 1 ] && ok || bad "R3: a failure at the interval edge must ALERT: $(cat "$ALERTS")"
failed_has '(3 failed attempt(s))' \
  && ok || bad "R3: the ALERT must carry '(3 failed attempt(s))': $(cat "$ALERTS")"
[ "$(cat "$FST" 2>/dev/null)" = "1000000 1003600 3" ] \
  && ok || bad "R3: the failing state must be '1000000 1003600 3': $(cat "$FST" 2>/dev/null)"
grep -qF 'alert held' "$ULOG" && bad "R3: an alerting pass writes no held line: $(cat "$ULOG")" || ok

# ── R4. 3590 s after the last alert it is held ───────────────────────────────
reset_run
HARNESS_SYNC_NOW=1007190 sync
[ "$(failed_alerts)" = 0 ] && ok || bad "R4: 3590 s after the last ALERT must hold: $(cat "$ALERTS")"
grep -qF 'alert held, next in 10s' "$ULOG" && ok || bad "R4: the held line says 10s: $(cat "$ULOG")"

# ── R7b. a last-alert in the future counts as absent: alert, count restarts ──
reset_run
printf '1000000 2000000 4\n' > "$FST"
HARNESS_SYNC_NOW=1010000 sync
[ "$(failed_alerts)" = 1 ] && ok || bad "R7b: a future last-alert must ALERT: $(cat "$ALERTS")"
failed_has '(1 failed attempt(s))' \
  && ok || bad "R7b: the count restarts at 1: $(cat "$ALERTS")"
[ "$(cat "$FST" 2>/dev/null)" = "1010000 1010000 1" ] \
  && ok || bad "R7b: the failing state must be '1010000 1010000 1': $(cat "$FST" 2>/dev/null)"

# ── R7. a corrupt state file counts as absent ────────────────────────────────
reset_run
printf 'garbage\n' > "$FST"
HARNESS_SYNC_NOW=1020000 sync
[ "$(failed_alerts)" = 1 ] && ok || bad "R7: a corrupt state must ALERT: $(cat "$ALERTS")"
failed_has '(1 failed attempt(s))' \
  && ok || bad "R7: the count restarts at 1: $(cat "$ALERTS")"
[ "$(cat "$FST" 2>/dev/null)" = "1020000 1020000 1" ] \
  && ok || bad "R7: the failing state must be '1020000 1020000 1': $(cat "$FST" 2>/dev/null)"

# ── R6. a non-numeric knob is 3600: the next failure is held ─────────────────
reset_run
HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S=abc HARNESS_SYNC_NOW=1020010 sync
[ "$(failed_alerts)" = 0 ] && ok || bad "R6: a bad knob falls back to 3600, so this failure is held: $(cat "$ALERTS")"
grep -qF 'alert held, next in 3590s' "$ULOG" && ok || bad "R6: the held line says 3590s: $(cat "$ULOG")"

# ── R5. 0 alerts on every failure ────────────────────────────────────────────
reset_run
HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S=0 HARNESS_SYNC_NOW=1020020 sync
HARNESS_SYNC_DEPLOY_ALERT_REPEAT_S=0 HARNESS_SYNC_NOW=1020021 sync
[ "$(failed_alerts)" = 2 ] && ok || bad "R5: 0 must ALERT on each of 2 failures: $(cat "$ALERTS")"
failed_has '(4 failed attempt(s))' last \
  && ok || bad "R5: the count keeps going: $(cat "$ALERTS")"

# ── R10. no env value: the settings row is read through jobs-client.sh ───────
reset_run
cat > "$T/bin/jobs-client.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/jobs-client.calls"
[ "\$1" = setting-get ] && [ "\$2" = lane.fleet-propagate.harness_sync_deploy_alert_repeat_s ] && { echo ' 0 '; exit 0; }
exit 1
EOF
chmod +x "$T/bin/jobs-client.sh"
HARNESS_SYNC_NOW=1020022 sync
[ "$(failed_alerts)" = 1 ] && ok || bad "R10: a settings row of 0 must ALERT 1 s after the last one: $(cat "$ALERTS")"
grep -qF 'setting-get lane.fleet-propagate.harness_sync_deploy_alert_repeat_s' "$T/jobs-client.calls" 2>/dev/null \
  && ok || bad "R10: the settings row must be read: $(cat "$T/jobs-client.calls" 2>/dev/null)"
rm -f "$T/bin/jobs-client.sh" "$T/jobs-client.calls"

# ── R8. recovery clears the state, logs it, stamps, and writes no ALERT ──────
reset_run
rm -f "$T/wrangler-fail-jobs"
HARNESS_SYNC_NOW=1020100 sync
[ ! -e "$FST" ] && ok || bad "R8: a successful deploy must remove the failing state: $(cat "$FST")"
grep -qF 'worker jobs deploy recovered after 5 failed attempt(s) since 1970-01-12 19:20:00Z' "$ULOG" \
  && ok || bad "R8: update-runners.log must say the deploy recovered: $(cat "$ULOG")"
grep -qF 'worker jobs deployed at' "$ULOG" && ok || bad "R8: the deploy must be logged: $(cat "$ULOG")"
cmp -s "$T/state/worker-deployed-jobs" "$T/wd.before" \
  && bad "R8: the stamp must move on success" || ok
[ ! -s "$ALERTS" ] && ok || bad "R8: recovery writes no ALERT: $(cat "$ALERTS")"
# the next failure alerts at once again
reset_run
touch "$T/wrangler-fail-jobs"
printf 'export default { v: 3 };\n' > "$T/ck/worker/jobs/src/index.js"
push "move jobs again"
HARNESS_SYNC_NOW=1020200 sync
[ "$(failed_alerts)" = 1 ] && ok || bad "R8: the first failure after a recovery ALERTs at once: $(cat "$ALERTS")"
failed_has '(1 failed attempt(s))' \
  && ok || bad "R8: the count restarts at 1 after a recovery: $(cat "$ALERTS")"
rm -f "$T/wrangler-fail-jobs"

# ── A2. a commit with no agent-core/ still snapshots and deploys ─────────────
reset_run
git -C "$T/ck" rm -rq agent-core worker/jobs/src/routes
push "drop agent-core"
sync
[ "$RC" = 0 ] && ok || bad "A2: a sync of a commit with no agent-core/ must exit 0, got $RC"
[ "$(deployed jobs)" = 1 ] && ok || bad "A2: worker jobs must deploy: $(cat "$NPXLOG")"
[ "$(cat "$T/snap-core-jobs" 2>/dev/null)" = no ] \
  && ok || bad "A2: the snapshot has no agent-core/ (snap-core-jobs=$(cat "$T/snap-core-jobs" 2>/dev/null || echo none))"
grep -q 'could not snapshot' "$ALERTS" && bad "A2: no 'could not snapshot' ALERT: $(cat "$ALERTS")" || ok
case "$(cat "$T/state/worker-deployed-jobs" 2>/dev/null)" in
  *-core-*) bad "A2: with no import the jobs stamp carries no -core- part: $(cat "$T/state/worker-deployed-jobs")" ;;
  *) ok ;;
esac
# ── A3 (pass 2). plain deploys on a commit that moves it ─────────────────────
reset_run
printf 'export default { v: 3 };\n' > "$T/ck/worker/plain/src/index.js"
push "move plain"
sync
[ "$(deployed plain)" = 1 ] && ok || bad "A3: worker plain must deploy in pass 2: $(cat "$NPXLOG")"

echo "harness-sync-snapshot-agent-core.bh-6687-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
