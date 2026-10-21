#!/bin/bash
# tests/fly-orphan-jobs-test.sh — a queued job whose machine Fly no longer
# returns must be requeued or terminally failed WITH A REASON, never left
# orphaned; and the count must be visible somewhere a human reads (BH-660).
#
# WHY THIS EXISTS. The pool asked one `machine status` per tracked machine and
# nothing at all about the app as a whole, so "3 orphan jobs" was a number
# computed off-repo by the watchdog's enrichment — there was no line in this
# repo anyone could grep for it. The tick now reads ONE listing and every
# liveness answer comes from it: a machine that is absent is dead, a machine
# that is `failed` or `suspended` is dead (they used to fall through to a
# heartbeat probe that cannot reach a machine which is not running, so the job
# sat there for ever), and what the sweep observed lands in
# state/fly-pool/<p>/.sweep.json for bin/fleet-fly-block.sh to publish.
#
# Sections 1-4 drive the REAL bin/fly-pool.sh. Section 5 drives the sweep's own
# `# >>> dead-machine sweep` region, extracted verbatim, for the one path the
# in-tick reap normally makes unreachable — a tracking file that survives the
# reap. Section 6 drives bin/fleet-fly-block.sh, section 7 the whole
# bin/fly-pool-tick.sh.
#
# Run from anywhere: tests/fly-orphan-jobs-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX POOL_STOPPED_TTL_S POOL_SWEEP_MAX_DESTROY
# ONE clock read for the whole file.
NOW=$(date +%s)
FRESH=$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/state/fly" \
         "$H/state/fly-pool/tproj" "$H/state/build-queue/tproj" "$H/builds" "$T/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf '1\n' > "$H/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj"}\n' > "$H/state/fly/tproj.json"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "$*" >> "$FLY_CALLS"
case "$*" in
  *"machines list"*) cat "$FIX/listing.json" 2>/dev/null || echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   cat "$FIX/heartbeat" 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

listing() { printf '%s\n' "$1" > "$T/listing.json"; }
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=tok FLY_CALLS="$T/fly-calls.log" FIX="$T" POOL_SPAWN=0 "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
reset() {
  rm -f "$H/state/fly-pool/tproj"/*.json "$H/state/fly-pool/tproj/.sweep.json"
  rm -f "$H/state/build-queue/tproj"/*.json "$H/flags"/alerted-pool-* "$T/heartbeat"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"; : > "$T/fly-calls.log"
}
# Every listing below carries one untracked `started` machine, because an EMPTY
# listing beside tracked files is deliberately treated as unusable — that is the
# fail-open half, pinned in tests/fly-pool-sweep-test.sh.
LIVE_ROW="{\"id\":\"m4smoke\",\"state\":\"started\",\"updated_at\":\"$FRESH\"}"

# ══ 1. A MACHINE THE LISTING NO LONGER CARRIES IS A DEATH, AND A REQUEUE ════
reset
jq -nc '{machine:"m9gone",key:"OJ-1",ticket_id:"77",attempt:0,deferrals:0,deaths:0}' \
  > "$H/state/fly-pool/tproj/m9gone.json"
listing "[$LIVE_ROW]"
tick
[ -f "$H/state/build-queue/tproj/OJ-1.json" ] && ok \
  || bad "the job must be requeued, not orphaned (queue: $(ls "$H/state/build-queue/tproj"))"
[ "$(jq -r '.deaths' "$H/state/build-queue/tproj/OJ-1.json" 2>/dev/null)" = 1 ] && ok \
  || bad "the requeue must carry deaths=1: $(cat "$H/state/build-queue/tproj/OJ-1.json" 2>/dev/null)"
[ "$(jq -r '.attempt' "$H/state/build-queue/tproj/OJ-1.json" 2>/dev/null)" = 1 ] && ok \
  || bad "the requeue must carry attempt=1: $(cat "$H/state/build-queue/tproj/OJ-1.json" 2>/dev/null)"
[ "$(jq -r '.ticket_id' "$H/state/build-queue/tproj/OJ-1.json" 2>/dev/null)" = 77 ] && ok \
  || bad "the requeue must keep the ticket id"
[ -f "$H/state/fly-pool/tproj/m9gone.json" ] \
  && bad "the tracking file for a machine Fly does not return must go" || ok
grep -q 'machine m9gone for OJ-1 dead (state=gone)' "$H/logs/fly-pool.log" && ok \
  || bad "the death must be logged with its reason: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.orphan_jobs | length' "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null)" = 0 ] && ok \
  || bad "no orphan may remain after the tick that killed it: $(cat "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null)"
# One listing answered the liveness question: no per-machine status call at all.
grep -q 'machine status' "$T/fly-calls.log" \
  && bad "a usable listing must replace the per-machine status calls ($(cat "$T/fly-calls.log"))" || ok

# ══ 2. THE SECOND OBSERVED DEATH PARKS THE TICKET ═══════════════════════════
reset
jq -nc '{machine:"m9gone",key:"OJ-1",ticket_id:"77",attempt:0,deferrals:0,deaths:1}' \
  > "$H/state/fly-pool/tproj/m9gone.json"
listing "[$LIVE_ROW]"
tick
[ -f "$H/state/build-queue/tproj/OJ-1.failed.json" ] && ok \
  || bad "a second death must park the ticket for bin/blocked-resolver.sh (queue: $(ls "$H/state/build-queue/tproj"))"
[ -f "$H/state/build-queue/tproj/OJ-1.json" ] \
  && bad "a parked ticket must not also be re-offered" || ok
[ "$(jq -r '.deaths' "$H/state/build-queue/tproj/OJ-1.failed.json" 2>/dev/null)" = 2 ] && ok \
  || bad "the park must record both deaths: $(cat "$H/state/build-queue/tproj/OJ-1.failed.json" 2>/dev/null)"

# ══ 3. `failed` AND `suspended` ARE DEATHS TOO ═════════════════════════════
# These used to fall through to the heartbeat probe, whose mexec cannot reach a
# machine that is not running: HB came back empty, DEAD stayed 0, and the job
# sat on a machine that would never build it again, tick after tick.
for ST in failed suspended; do
  reset
  jq -nc '{machine:"m9bad",key:"OJ-2",ticket_id:"78",attempt:0,deferrals:0,deaths:0}' \
    > "$H/state/fly-pool/tproj/m9bad.json"
  listing "[$LIVE_ROW,{\"id\":\"m9bad\",\"state\":\"$ST\",\"updated_at\":\"$FRESH\"}]"
  tick
  [ -f "$H/state/build-queue/tproj/OJ-2.json" ] && ok \
    || bad "a '$ST' machine is dead and its job must be requeued (queue: $(ls "$H/state/build-queue/tproj"))"
  grep -q "machine m9bad for OJ-2 dead (state=$ST)" "$H/logs/fly-pool.log" && ok \
    || bad "the log must name the state that killed it: $(cat "$H/logs/fly-pool.log")"
  [ -f "$H/state/fly-pool/tproj/m9bad.json" ] \
    && bad "a '$ST' machine's tracking file must go" || ok
done

# ══ 4. A HEALTHY MACHINE IS LEFT ALONE ═════════════════════════════════════
# The negative that keeps §1-§3 honest: same code path, live machine, no
# requeue, no destroy, file intact.
reset
jq -nc '{machine:"m5live",key:"OJ-3",ticket_id:"79",attempt:0,deferrals:0,deaths:0}' \
  > "$H/state/fly-pool/tproj/m5live.json"
listing "[$LIVE_ROW,{\"id\":\"m5live\",\"state\":\"started\",\"updated_at\":\"$FRESH\"}]"
printf '5\n' > "$T/heartbeat"
tick
[ -f "$H/state/fly-pool/tproj/m5live.json" ] && ok || bad "a started machine with a fresh heartbeat must survive"
ls "$H/state/build-queue/tproj"/*.json >/dev/null 2>&1 \
  && bad "a live build must not be requeued: $(ls "$H/state/build-queue/tproj")" || ok
grep -q 'machine destroy' "$T/fly-calls.log" \
  && bad "a live build's machine must never be destroyed ($(cat "$T/fly-calls.log"))" || ok
[ "$(jq -r '.orphan_jobs | length' "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null)" = 0 ] && ok \
  || bad "a machine that IS in the listing is not an orphan: $(cat "$H/state/fly-pool/tproj/.sweep.json" 2>/dev/null)"

# ══ 5. THE SWEEP'S LAST-RESORT ORPHAN CHECK ════════════════════════════════
# A tracking file that outlives the reap for a machine Fly no longer returns is
# a job nothing will ever finish. The reap closes every one of those itself
# (§1), so this drives the sweep region VERBATIM — extracted by its
# `# >>> dead-machine sweep` markers, the same way the other pool suites extract
# next_job_or_destroy — rather than asserting on a shape production cannot reach.
SW="$T/sw"; mkdir -p "$SW/pool" "$SW/flags" "$SW/logs"
mkdir -p "$SW/bin" && cp "$DIR/bin/alert-line.sh" "$SW/bin/"
sed -n '/^# >>> dead-machine sweep (BH-660)/,/^# <<< dead-machine sweep/p' "$DIR/bin/fly-pool.sh" > "$SW/sweep.sh"
[ -s "$SW/sweep.sh" ] && grep -q 'orphan_jobs' "$SW/sweep.sh" && ok \
  || bad "could not extract the dead-machine sweep region"
jq -nc '{machine:"m9ghost",key:"OJ-9",ticket_id:"99"}' > "$SW/pool/m9ghost.json"
printf '[%s]\n' "$LIVE_ROW" > "$SW/listing.json"
( set +u
  HARNESS="$SW"; P=tproj; APP=pool-tproj; POOL="$SW/pool"; POOL_APP=pool-tproj
  LIST_OK=1; LISTING="$SW/listing.json"; LIST_WHY=""; REAPED_IDS=" "
  STAMP() { echo "2026-09-17 00:00:00Z"; }
  say() { echo "$*" >> "$SW/logs/fly-pool.log"; }
  destroy_machine() { echo "destroy $1" >> "$SW/logs/destroys"; return 0; }
  . "$SW/sweep.sh" ) >/dev/null 2>&1
[ "$(jq -r '.orphan_jobs[0].key' "$SW/pool/.sweep.json" 2>/dev/null)" = OJ-9 ] && ok \
  || bad "an orphaned job must be reported in .sweep.json: $(cat "$SW/pool/.sweep.json" 2>/dev/null)"
[ "$(jq -r '.orphan_jobs[0].machine' "$SW/pool/.sweep.json" 2>/dev/null)" = m9ghost ] && ok \
  || bad "the orphan must name its machine: $(cat "$SW/pool/.sweep.json" 2>/dev/null)"
[ "$(grep -c 'OJ-9 still tracked on m9ghost' "$SW/logs/ALERTS.log")" = 1 ] && ok \
  || bad "an orphan must page once: $(cat "$SW/logs/ALERTS.log" 2>/dev/null)"
[ -f "$SW/logs/destroys" ] && bad "the orphan check must not destroy anything" || ok
grep -q 'orphans=1' "$SW/logs/fly-pool.log" && ok \
  || bad "the readout line must carry the orphan count: $(cat "$SW/logs/fly-pool.log")"

# ══ 6. THE FLEET SNAPSHOT PUBLISHES THE COUNTS ═════════════════════════════
# bin/fleet-fly-block.sh is what the console Fleet tile and the watchdog read.
# The shape it emits WITHOUT a sweep file must be byte-identical to today's, or
# every existing consumer changes shape for a project that has no sweep.
FB="$T/fb"; mkdir -p "$FB/state/fly-pool/tproj" "$FB/state/fly" "$FB/flags"
cat > "$FB/fleet.conf" <<'EOF'
tproj  Org/tproj  https://tproj.example  /api/board  2 box-tproj
EOF
fblock() { ( export HARNESS="$FB" FLEET_CONF="$FB/fleet.conf"; "$DIR/bin/fleet-fly-block.sh" 2>/dev/null ); }
printf 'pool-tproj\n' > "$FB/flags/fly-pool-app-tproj"
OUT=$(fblock); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '."tproj"' <<<"$OUT")" = '{"pool_app":"pool-tproj","builder":null,"machines":[]}' ] && ok \
  || bad "no sweep file must emit exactly today's shape (rc=$RC got: $(jq -c '."tproj"' <<<"$OUT"))"
echo 'not json' > "$FB/state/fly-pool/tproj/.sweep.json"
OUT=$(fblock); RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '."tproj"' <<<"$OUT")" = '{"pool_app":"pool-tproj","builder":null,"machines":[]}' ] && ok \
  || bad "an unparseable sweep file must not change the shape or the rc (rc=$RC got: $(jq -c '."tproj"' <<<"$OUT"))"
jq -nc '{at:"2026-09-17 18:00:00Z",listing:"ok",listed:4,
         stopped:[{machine:"m8",state:"stopped",age_s:60}],unaged:["mX"],
         destroyed:["m2old"],destroy_failed:[{machine:"m1",rc:1,error:"rate limited"}],
         orphan_jobs:[{machine:"m9",key:"OJ-9",ticket_id:"9"}]}' \
  > "$FB/state/fly-pool/tproj/.sweep.json"
OUT=$(fblock)
[ "$(jq -r '."tproj".orphan_jobs | length' <<<"$OUT")" = 1 ] && ok \
  || bad "orphan_jobs must reach the snapshot (got: $(jq -c '."tproj"' <<<"$OUT"))"
[ "$(jq -r '."tproj".orphan_jobs[0].key' <<<"$OUT")" = OJ-9 ] && ok || bad "the orphan's key must survive the hop"
[ "$(jq -r '."tproj".stopped_machines' <<<"$OUT")" = 2 ] && ok \
  || bad "stopped_machines counts stopped + unaged (got $(jq -r '."tproj".stopped_machines' <<<"$OUT"))"
[ "$(jq -r '."tproj".destroy_failed[0].machine' <<<"$OUT")" = m1 ] && ok || bad "destroy_failed must reach the snapshot"
[ "$(jq -r '."tproj".sweep_at' <<<"$OUT")" = "2026-09-17 18:00:00Z" ] && ok || bad "sweep_at must reach the snapshot"
[ "$(jq -r '."tproj".sweep_listing' <<<"$OUT")" = ok ] && ok || bad "sweep_listing must reach the snapshot"
# A sweep that could not list says so rather than publishing zeros.
jq -nc '{at:"2026-09-17 18:02:00Z",listing:"failed",reason:"empty-with-tracked"}' \
  > "$FB/state/fly-pool/tproj/.sweep.json"
OUT=$(fblock)
[ "$(jq -r '."tproj".sweep_listing' <<<"$OUT")" = failed ] && ok || bad "a failed listing must be visible as such"
[ "$(jq -r '."tproj".stopped_machines' <<<"$OUT")" = 0 ] && ok \
  || bad "a failed listing publishes no counts (got $(jq -r '."tproj".stopped_machines' <<<"$OUT"))"

# ══ 7. THE TICK LEAVES A BUILDER RECORD ALONE; RETIRED RECORDS STAY UNPUBLISHED
# The BH-660 one-shot that moved a top-level machine_id under builder_retired
# ran on every pool project and left in BH-7433. The tick now rewrites no
# record and pages nobody, and it still runs no Fly command against a
# builder-* app. Records the one-shot retired stay on the hub in that shape, so
# bin/fleet-fly-block.sh must keep not publishing them as a builder.
TK="$T/tk"; mkdir -p "$TK/bin" "$TK/logs" "$TK/flags" "$TK/state/fly" "$TK/fakebin"
cp "$DIR/bin/pool-cap.sh" "$DIR/bin/alert-line.sh" "$TK/bin/"
printf '#!/bin/bash\nexit 0\n' > "$TK/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nexit 0\n' > "$TK/bin/fly-pool.sh"
printf '#!/bin/bash\necho "$*" >> "%s/fly-calls.log"\nexit 0\n' "$TK" > "$TK/fakebin/fly"
chmod +x "$TK/bin"/*.sh "$TK/fakebin"/*
printf '1\n' > "$TK/flags/fly-pool-tproj"
printf 'pool-tproj\n' > "$TK/flags/fly-pool-app-tproj"
printf '{"app":"builder-tproj","machine_id":"7845007b999738","region":"iad"}\n' > "$TK/state/fly/tproj.json"
cp "$TK/state/fly/tproj.json" "$TK/tproj.before"
# A project with no pool flag is not pool-routed and must be left exactly alone.
printf '{"app":"builder-other","machine_id":"85762e7f406658","region":"iad"}\n' > "$TK/state/fly/other.json"
cp "$TK/state/fly/other.json" "$TK/other.before"
pooltick() { ( export PATH="$TK/fakebin:$PATH" HARNESS="$TK" POOL_AUTOSCALE=0
                bash "$DIR/bin/fly-pool-tick.sh" >/dev/null 2>&1 ); }
pooltick
cmp -s "$TK/state/fly/tproj.json" "$TK/tproj.before" && ok \
  || bad "the tick must leave a pool project's builder record byte-identical: $(cat "$TK/state/fly/tproj.json")"
! grep -qs '7845007b999738' "$TK/logs/ALERTS.log" && ok \
  || bad "the tick must page nobody about the builder machine: $(cat "$TK/logs/ALERTS.log" 2>/dev/null)"
! grep -q 'builder record retired' "$TK/logs/fly-pool.log" 2>/dev/null && ok \
  || bad "the tick must log no record retirement: $(cat "$TK/logs/fly-pool.log" 2>/dev/null)"
[ -s "$TK/fly-calls.log" ] \
  && bad "the tick must run NO Fly command against a builder-* app: $(cat "$TK/fly-calls.log")" || ok
cmp -s "$TK/state/fly/other.json" "$TK/other.before" && ok \
  || bad "a project with no fly-pool flag must be untouched: $(cat "$TK/state/fly/other.json")"
# A retired record is not published as a builder.
# The shape the BH-660 one-shot wrote, as the hub still holds it.
mkdir -p "$FB/state/fly-pool/tproj"
printf '{"app":"builder-tproj","builder_retired":{"machine_id":"7845007b999738","region":"iad","retired_at":"2026-09-14T00:00:00Z","retired_by":"bin/fly-pool-tick.sh (BH-660)"}}\n' \
  > "$FB/state/fly/tproj.json"
rm -f "$FB/state/fly-pool/tproj/.sweep.json"
OUT=$(fblock)
[ "$(jq -r '."tproj".builder' <<<"$OUT")" = null ] && ok \
  || bad "a retired record must not be published as a builder with a blank id (got $(jq -c '."tproj".builder' <<<"$OUT"))"
printf '{"app":"builder-tproj","machine_id":"9080ee"}\n' > "$FB/state/fly/tproj.json"
OUT=$(fblock)
[ "$(jq -c '."tproj".builder' <<<"$OUT")" = '{"app":"builder-tproj","machine_id":"9080ee"}' ] && ok \
  || bad "a real builder must still be published (got $(jq -c '."tproj".builder' <<<"$OUT"))"

echo "fly-orphan-jobs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
