#!/bin/bash
# tests/fly-pool-overlap-defer-uncounted.bh-5912-test.sh — an overlap or After:
# deferral does not use up the per-key pool spawn cap, and a key whose After:
# hold is live gets no machine at all (BH-5912).
#
# TK-7 (project-6-os, 2026-10-09) reached the cap of 12 spawns in 24 h with
# twelve short machines that each ended OVERLAP_DEFER behind a sibling: no
# build ran, and the key stopped. The reap now un-records the spawn for the
# four overlap-family RESULT shapes bin/lib/rb/gates.sh writes (the BH-1279
# call a refused claim gets), and pool_spawn_decision asks bin/plan-after.sh
# before it spawns a key that has deferred.
#
#   A1-A3  overlap / After: / not-before / file-overlap reaps leave .spawns flat
#   A2     the deferral still advances `deferrals` (DEFER_MAX still bounds it)
#   A4/A5  negative controls: other deferral shapes still count
#   B1-B4  the step-3b After: gate on the spawn loop (stub and real plan-after.sh)
#   B5     the same gate on next_job_or_destroy's reuse handoff
#   B6     a hotfix row skips the step-3b gate and spawns (BH-6292)
#
# HOW IT DRIVES: the real bin/fly-pool.sh, run as a subprocess against a
# scratch harness with fly/gh stubs (the tests/fly-pool-refused-not-counted.
# bh-1279-test.sh harness). The file anchors wall-clock time in $NOW; every
# fixture timestamp is derived from that one value.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/beat.sh" "$H/bin/result-prefix-ok.sh" "$H/bin/fly-envbundle.sh" "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}

# Fly stub: supports reap reads, machine run, and a no-op ssh console / sftp.
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}

write_gh_stub() {
  local head_sha="${1:-}" pr_count="${2:-0}" issue_state="${3:-open}"
  cat > "$T/fakebin/gh" <<GH
#!/bin/bash
for a in "\$@"; do
  case "\$a" in issue) echo "\$*" >> "${T}/gh-sink.txt"; exit 0 ;; esac
done
if [[ "\$*" == *"issues/"*"/comments"* ]] && [[ "\$*" == *"body=@"* ]]; then
  echo '{"id":1}'
  exit 0
fi
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/1016"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"$issue_state","labels":[{"name":"ai-build"}],"title":"","body":""}'
  exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'
    exit 0
  fi
  if [[ "\$*" == *"git/ref/heads/ticket/bh-1016"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    [ -n "$head_sha" ] && echo "{\"object\":{\"sha\":\"$head_sha\"}}" || echo '{}'
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n'
    if [ "$pr_count" = 0 ]; then echo '[]'; else
      echo '[{"number":55,"state":"open","html_url":"https://github.com/example-org/project-5/pull/55","head":{"ref":"ticket/bh-1016","repo":{"full_name":"example-org/project-5"}}}]'
    fi
    exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'
  exit 0
fi
exit 0
GH
  chmod +x "$T/fakebin/gh"
}

reset_state() { # reset_state [builds]
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  # This suite's own fixtures: the plan-after.sh under test, its call log, and
  # the marker / claim files the real script reads.
  for p in "$H/bin/plan-after.sh" "$T/pa-calls" "$H/state/overlap-after" "$H/state/claims"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  if [ "${1:-}" = builds ]; then
    for p in "$H/builds"/*; do [ -e "$p" ] && scratch_rm "$p"; done
  fi
  return 0
}

queue_bh1016() { # queue_bh1016 [deferrals] [hotfix]
  jq -nc --argjson d "${1:-0}" --arg hf "${2:-}" '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:$d,deaths:0,enqueued_at:"2026-09-19T21:28:00Z"} + (if $hf == "hotfix" then {hotfix:true} else {} end)' \
    > "$H/state/build-queue/project-5/BH-1016.json"
}


spawns_of() { cat "$H/state/pool/project-5/BH-1016.spawns" 2>/dev/null; }
spawn_count() { spawns_of | grep -c .; }

# machine_json <machine> <spawn_cap_ts> <deferrals> — a live BH-1016 machine
# that the next run reaps.
machine_json() {
  jq -nc --arg m "$1" --arg k "BH-1016" --arg t "1016" --arg sct "$2" --argjson d "$3" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-10-09T22:00:00Z",spawn_cap_ts:$sct}' \
    > "$H/state/fly-pool/project-5/$1.json"
}

# stub_plan_after <rc> <stdout> [only-key] — an executable $H/bin/plan-after.sh
# that logs its args and answers as told (for every key, or only for one).
stub_plan_after() {
  cat > "$H/bin/plan-after.sh" <<PA
#!/bin/bash
echo "\$*" >> "$T/pa-calls"
if [ -z "${3:-}" ] || [ "\$3" = "${3:-}" ]; then
  [ -n "$2" ] && echo "$2"
  exit $1
fi
exit 0
PA
  chmod +x "$H/bin/plan-after.sh"
}

# ── A1: three overlap-family reaps leave the 24 h spawn count unchanged ────
# Each machine records its own spawn (SCT_i) when it is spawned; the reap of an
# overlap deferral must take exactly that line back off, and leave PRIOR (an
# earlier machine that really built) on the ledger.
SHAPES=(
  "BUILD_DEFERRED OVERLAP_DEFER BH-1016 vs BH-1015 files=[a.sh]; After: BH-1015 — held until it merges (not before 2026-10-09 22:10:00Z), then the next triage tick re-offers BH-1016 to any free box"
  "BUILD_DEFERRED After: BH-1015 in flight — BH-1016 overlaps it on a non-splittable file and builds after it merges; re-checked each tick before any plan is bought"
  "BUILD_DEFERRED plan overlap not-before 22:10:00Z — BH-1016 stood down on a file overlap and its window has 9m left; the next tick after that re-offers it and re-runs the overlap test"
)
{
  reset_state builds
  write_gh_stub "" 0
  PRIOR=$((NOW-7200))
  echo "$PRIOR" > "$H/state/pool/project-5/BH-1016.spawns"
  for i in 1 2 3; do
    SCT=$((NOW-60+i))
    echo "$SCT" >> "$H/state/pool/project-5/BH-1016.spawns"
    machine_json "m-ovl$i" "$SCT" "$((i-1))"
    write_fly_stub "${SHAPES[$((i-1))]}"
    Q="$H/state/build-queue/project-5/BH-1016.json"; [ -e "$Q" ] && scratch_rm "$Q"
    run_pool POOL_SPAWN=0
    [ "$(spawn_count)" = 1 ] && [ "$(spawns_of)" = "$PRIOR" ] \
      && ok "A1.$i: the overlap reap took its own spawn back off the ledger" \
      || bad "A1.$i: expected .spawns to hold only PRIOR=$PRIOR after reap $i ('${SHAPES[$((i-1))]%% —*}'), got: $(spawns_of | tr '\n' ' ')"
    # A stand-down that names its blocker logs the BH-5967 wait line
    # (`waits for BH-1015 … row stays queued`); any other logs `requeued`.
    [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
      && grep -Eq 'DEFERRED BH-1016.*(requeued|row stays queued)' "$H/logs/fly-pool.log" \
      && ok "A1.$i: the deferral is still requeued" || bad "A1.$i: no requeue line: $(cat "$H/logs/fly-pool.log")"
  done
  # ── A2: the deferral still advances `deferrals` (DEFER_MAX bounds the loop)
  D=$(jq -r '.deferrals // ""' "$H/state/build-queue/project-5/BH-1016.json" 2>/dev/null)
  [ "$D" = 3 ] && ok "A2: three overlap reaps advanced deferrals to 3" \
    || bad "A2: expected deferrals 3 on the requeued row, got '$D'"
}

# ── A3: the `file overlap` shape ───────────────────────────────────────────
{
  reset_state builds
  write_gh_stub "" 0
  PRIOR=$((NOW-7200)); SCT=$((NOW-60))
  { echo "$PRIOR"; echo "$SCT"; } > "$H/state/pool/project-5/BH-1016.spawns"
  machine_json "m-fov" "$SCT" 0
  write_fly_stub "BUILD_DEFERRED file overlap — BH-1015 holds x.sh; wakes when BH-1015 merges"
  run_pool POOL_SPAWN=0
  [ "$(spawns_of)" = "$PRIOR" ] && ok "A3: a file-overlap reap took its own spawn back off the ledger" \
    || bad "A3: expected .spawns = PRIOR only, got: $(spawns_of | tr '\n' ' ')"
}

# ── A4: negative control — a wip-limit deferral still counts ───────────────
{
  reset_state builds
  write_gh_stub "" 0
  PRIOR=$((NOW-7200)); SCT=$((NOW-60))
  { echo "$PRIOR"; echo "$SCT"; } > "$H/state/pool/project-5/BH-1016.spawns"
  machine_json "m-wip" "$SCT" 0
  write_fly_stub "BUILD_DEFERRED wip-limit 2 reached"
  run_pool POOL_SPAWN=0
  [ "$(spawn_count)" = 2 ] && grep -qx "$SCT" "$H/state/pool/project-5/BH-1016.spawns" \
    && ok "A4: a wip-limit deferral still counts against the cap" \
    || bad "A4: expected the wip-limit spawn to stay counted, got: $(spawns_of | tr '\n' ' ')"
}

# ── A5: negative control — the words in the middle of a line do not match ──
{
  reset_state builds
  write_gh_stub "" 0
  PRIOR=$((NOW-7200)); SCT=$((NOW-60))
  { echo "$PRIOR"; echo "$SCT"; } > "$H/state/pool/project-5/BH-1016.spawns"
  machine_json "m-busy" "$SCT" 0
  write_fly_stub "BUILD_DEFERRED all 3 slots busy (After: tag)"
  run_pool POOL_SPAWN=0
  [ "$(spawn_count)" = 2 ] && grep -qx "$SCT" "$H/state/pool/project-5/BH-1016.spawns" \
    && ok "A5: a slot deferral that mentions After: mid-line still counts" \
    || bad "A5: expected the busy-slot spawn to stay counted, got: $(spawns_of | tr '\n' ' ')"
}

# ── B1: After: PR open — skipped before spawn, with a named log line ───────
{
  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  : > "$T/fly-calls"
  stub_plan_after 3 "AFTER BH-1015 PR #55 open"
  queue_bh1016 1
  run_pool
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && bad "B1: a machine was spawned for a key whose After: PR is open" \
    || ok "B1: no machine json for the held key"
  [ "$(spawn_count)" = 0 ] && ok "B1: .spawns unchanged" || bad "B1: the held key recorded a spawn: $(spawns_of)"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] \
    && ok "B1: the row stays queued" || bad "B1: the held key's queue file was removed"
  D=$(jq -r '.deferrals' "$H/state/build-queue/project-5/BH-1016.json" 2>/dev/null)
  [ "$D" = 1 ] && ok "B1: deferrals unchanged" || bad "B1: deferrals changed to '$D'"
  grep -q 'machine run' "$T/fly-calls" && bad "B1: fly machine run was called" || ok "B1: no fly machine run"
  grep -q 'skipping BH-1016: After: BH-1015 PR #55 open' "$H/logs/fly-pool.log" \
    && ok "B1: the skip is logged with the sibling and why" \
    || bad "B1: no 'skipping BH-1016: After:' line: $(cat "$H/logs/fly-pool.log")"
  grep -q 'After:' "$H/logs/ALERTS.log" && bad "B1: a normal After: wait wrote an ALERTS line" || ok "B1: no ALERTS line"
  grep -qx 'check project-5 BH-1016' "$T/pa-calls" 2>/dev/null \
    && ok "B1: plan-after.sh was asked 'check project-5 BH-1016'" \
    || bad "B1: plan-after.sh calls: $(cat "$T/pa-calls" 2>/dev/null)"
}

# ── B2: hold released (rc 0) — the key spawns and counts ───────────────────
{
  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  stub_plan_after 0 ""
  queue_bh1016 1
  run_pool
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && ok "B2: a released key spawns" || bad "B2: no machine spawned after plan-after.sh rc 0: $(cat "$H/logs/fly-pool.log")"
  [ "$(spawn_count)" = 1 ] && ok "B2: the spawn counts" || bad "B2: expected 1 .spawns line, got $(spawn_count)"
}

# ── B3: the REAL plan-after.sh — a marker and an in-flight sibling ─────────
# Writer and reader in one test: the marker is the shape `plan-after.sh record`
# writes, and the hold answer is the real script's.
{
  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  scratch_install_closure bin/plan-after.sh "$H" >/dev/null || bad "B3: closure install of bin/plan-after.sh failed"
  mkdir -p "$H/state/overlap-after/project-5" "$H/state/claims/project-5"
  printf 'BH-1015\t%s\n' "$((NOW-60))" > "$H/state/overlap-after/project-5/BH-1016"
  : > "$H/state/claims/project-5/BH-1015"
  queue_bh1016 1
  run_pool
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && bad "B3: a machine was spawned while the sibling is in flight" || ok "B3: no machine for the held key"
  grep -q 'skipping BH-1016: After: BH-1015 in flight' "$H/logs/fly-pool.log" \
    && ok "B3: the real plan-after.sh hold is logged" \
    || bad "B3: no 'After: BH-1015 in flight' line: $(cat "$H/logs/fly-pool.log")"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] && ok "B3: the row stays queued" || bad "B3: queue file removed"
}

# ── B4: a never-deferred row is not asked, and spawns ──────────────────────
{
  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  stub_plan_after 3 "AFTER BH-1015 PR #55 open"
  queue_bh1016 0
  run_pool
  [ -s "$T/pa-calls" ] && bad "B4: plan-after.sh was asked about a key that never deferred: $(cat "$T/pa-calls")" \
    || ok "B4: plan-after.sh not called for deferrals 0"
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && ok "B4: the never-deferred key spawns" || bad "B4: no machine spawned for a fresh row"
}

# ── B5: the reuse handoff runs the same gate (BH-1075 case k's shape) ──────
# next_job_or_destroy hands a queued row to the machine it just reaped without
# passing the spawn loop; it calls pool_spawn_decision, so the hold applies.
{
  reset_state builds
  write_fly_stub "BUILD_DEFERRED REFUSED box :: box max 1 already running"
  write_gh_stub "" 0
  stub_plan_after 3 "AFTER BH-1015 PR #55 open" BH-1016
  jq -nc '{machine:"m-reuse",key:"BH-1015",ticket_id:"1015",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-09T22:00:00Z"}' \
    > "$H/state/fly-pool/project-5/m-reuse.json"
  queue_bh1016 1
  run_pool POOL_SPAWN=0
  RK=$(jq -r '.key // ""' "$H/state/fly-pool/project-5/m-reuse.json" 2>/dev/null)
  [ "$RK" != "BH-1016" ] && ok "B5: the held key was not handed to the reaped machine" \
    || bad "B5: the reuse handoff gave the held key BH-1016 to the reaped machine"
  [ -f "$H/state/build-queue/project-5/BH-1016.json" ] && ok "B5: the held row stays queued" || bad "B5: queue file removed"
  grep -q 'skipping BH-1016: After: BH-1015 PR #55 open' "$H/logs/fly-pool.log" \
    && ok "B5: the handoff logged the After: skip" \
    || bad "B5: no After: skip on the handoff: $(cat "$H/logs/fly-pool.log")"
}

# ── B6: a hotfix row with a live After: hold spawns (BH-6292) ──────────────
# A key labelled hotfix after it deferred carries `hotfix:true` and
# deferrals > 0. The pool must not ask plan-after.sh: a hotfix is never
# deferred. B1 is the control: the same stub without the flag skips the key.
# The REAL plan-after.sh with a live marker and an in-flight sibling (B3's
# fixture) is the second half: it would hold, and the hotfix still spawns.
{
  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  : > "$T/fly-calls"
  stub_plan_after 3 "AFTER BH-1015 PR #55 open"
  queue_bh1016 1 hotfix
  run_pool
  [ -s "$T/pa-calls" ] && bad "B6: plan-after.sh was asked about a hotfix row: $(cat "$T/pa-calls")" \
    || ok "B6: plan-after.sh not called for a hotfix row"
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && ok "B6: the hotfix key spawns despite the hold" \
    || bad "B6: no machine spawned for a hotfix row: $(cat "$H/logs/fly-pool.log")"
  grep -q 'machine run' "$T/fly-calls" && ok "B6: fly machine run was called" || bad "B6: no fly machine run"
  grep -q 'skipping BH-1016: After:' "$H/logs/fly-pool.log" \
    && bad "B6: the hotfix row was skipped on its After: hold" || ok "B6: no After: skip line"
  grep -q 'BH-1016 is a hotfix: After: hold not checked' "$H/logs/fly-pool.log" \
    && ok "B6: the hotfix bypass is logged" \
    || bad "B6: no hotfix bypass line: $(cat "$H/logs/fly-pool.log")"

  reset_state builds
  write_fly_stub ""
  write_gh_stub "" 0
  scratch_install_closure bin/plan-after.sh "$H" >/dev/null || bad "B6: closure install of bin/plan-after.sh failed"
  mkdir -p "$H/state/overlap-after/project-5" "$H/state/claims/project-5"
  printf 'BH-1015\t%s\n' "$((NOW-60))" > "$H/state/overlap-after/project-5/BH-1016"
  : > "$H/state/claims/project-5/BH-1015"
  queue_bh1016 1 hotfix
  run_pool
  ls "$H/state/fly-pool/project-5"/*.json >/dev/null 2>&1 \
    && ok "B6: real plan-after.sh hold: the hotfix key still spawns" \
    || bad "B6: real plan-after.sh hold kept the hotfix key: $(cat "$H/logs/fly-pool.log")"
  grep -q 'skipping BH-1016: After: BH-1015 in flight' "$H/logs/fly-pool.log" \
    && bad "B6: the real hold skipped the hotfix key" || ok "B6: no real-hold skip line"
}

echo "fly-pool-overlap-defer-uncounted: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
