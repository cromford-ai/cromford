#!/bin/bash
# tests/fly-pool-placement-safety.bh-7519-test.sh — BH-7519: the fence and the
# write-back fixes of the #7515 review, in bin/fly-pool.sh itself.
#
#   F1  a lease lost just before `fly machine run` buys no machine, hands the
#       claimed row back queued, records nothing against the spawn cap and
#       leaves no bundle dir. The first fence (top of spawn_one) passes, so this
#       is the check that runs minutes later. A control run with the lease kept
#       does spawn, which also proves the machine's tick can renew at all
#       (bin/lib/project-lease.sh is loaded on demand by pp_fence_ok).
#   F2  the reuse handoff of next_job_or_destroy is fenced: a lost lease means
#       no handoff, and the queued job stays queued. A control with no lease
#       env hands the machine on.
#   C1  the reap posts a write-back (pp_checkpoint) BEFORE it destroys the
#       reaped machine, and after the park record is written.
#
# DRIVEN, NOT GREPPED, except the park record (C1 last case), which needs a PR
# verification the stubs here do not give. `bash bin/fly-pool.sh project-5` runs
# against a scratch $HARNESS with fly/gh/curl stubbed onto $PATH (the harness of
# tests/fly-pool-bundle-before-spawn.bh-4859-test.sh and
# tests/fly-pool-reuse-defer.bh-5025-test.sh). POOL_ON_MACHINE=1 with the lease
# env is what bin/fly-pool-project.sh gives the tick on a lane-run machine; a
# stop file stands for a lost lease.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin" "$T/res"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
# The placement lib and the lease client are sourced by name at run time.
for L in bin/lib/pool-placement.sh bin/lib/lane-placement.sh bin/lib/project-lease.sh; do
  mkdir -p "$H/$(dirname "$L")"; cp "$DIR/$L" "$H/$L"
done
# The machine's write-back, as a recorder: one line in the event log.
cat > "$H/bin/lib/lane-run-inputs.sh" <<'LRI'
lri_checkpoint() { echo "ckpt $*" >> "${EV:-/dev/null}"; return 0; }
LRI
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

# The bundler stub: EB_TOUCH (a path) is touched while it runs, which is the
# lease being lost between the top of spawn_one and the launch.
EB_MARK="bh7519-$$-$NOW"
cat > "$H/bin/fly-envbundle.sh" <<'EB'
#!/bin/bash
mkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"
printf '%s\n' "${EB_MARK:-}" > "$2/.bh7519-marker"
[ -z "${EB_TOUCH:-}" ] || : > "$EB_TOUCH"
echo "bundled 2 files"; exit 0
EB

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

# Fly stub: every call is a line in $EV (the same log the write-back recorder
# writes) and in $T/fly.txt. A machine's RESULT comes from $T/res/<machine>.
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
echo "fly $*" >> "${EV:-/dev/null}"
M=""; prev=""
for a in "$@"; do [ "$prev" = --machine ] && M="$a"; prev="$a"; done
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh sftp put"*) : ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$M" ] && [ -f "$RESDIR/$M" ] && cat "$RESDIR/$M" ;;
  *"ssh console"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\n' ;;
esac
exit 0
FLY

cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/10"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" == *"git/ref/heads/ticket/bh-10"* ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH

# The worker, file-backed over $ROWS (the 4859 stub), plus the project lease
# renew, which always answers 200.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
qparam() { case "$URL" in *"$1"=*) V="${URL##*"$1"=}"; printf '%s' "${V%%&*}" ;; esac; }
case "$M $URL" in
  "POST "*/api/project-leases/renew)
    printf '{"lease_until":"2099-01-01T00:00:00Z"}\n200\n' ;;
  "GET "*/api/settings/*)
    K="${URL##*/}"
    if [ "$K" = build_queue_rows_only ]; then
      printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "${FLAG_BQ:-0}"
    else printf '{}\n404\n'; fi ;;
  "GET "*/api/queue*)
    P=$(qparam project); ST=$(qparam status); TG=$(qparam target); K=$(qparam key)
    awk -F'\t' -v p="$P" -v st="$ST" -v tg="$TG" -v k="$K" '
      BEGIN{printf "{\"queue\":["; n=0}
      (p==""||$1==p)&&(st==""||$4==st)&&(tg==""||$5==tg)&&(k==""||$2==k){
        if (n++) printf ",";
        printf "{\"project\":\"%s\",\"ticket_key\":\"%s\",\"ticket_id\":\"%s\",\"status\":\"%s\",\"target\":\"%s\",\"attempt\":%s,\"claimed_by\":\"hub\",\"machine\":null,\"enqueued_at\":\"2026-09-22T00:00:00Z\",\"reason\":null,\"meta\":null}",
          $1, $2, $3, $4, $5, $6 }
      END{print "]}"}' "$ROWS" 2>/dev/null
    echo 200 ;;
  "POST "*/api/queue/claim)
    CP=$(printf '%s' "$BODY" | jq -r '.project // ""')
    CK=$(printf '%s' "$BODY" | jq -r '.key // ""')
    HIT=$(awk -F'\t' -v p="$CP" -v k="$CK" '$1==p && (k=="" || $2==k) && $4=="queued" {print; exit}' "$ROWS")
    [ -n "$HIT" ] || { printf '{}\n404\n'; exit 0; }
    HK=$(printf '%s' "$HIT" | cut -f2)
    awk -F'\t' -v OFS='\t' -v p="$CP" -v k="$HK" \
      '!d && $1==p && $2==k && $4=="queued" { $4="claimed"; d=1 } {print}' \
      "$ROWS" > "$ROWS.n" && mv "$ROWS.n" "$ROWS"
    printf '{"queued":{"project":"%s","ticket_key":"%s","ticket_id":"1016","target":"fly","attempt":0,"status":"claimed"},"claimed":true}\n200\n' "$CP" "$HK" ;;
  "PATCH "*/api/queue)
    CP=$(printf '%s' "$BODY" | jq -r '.project // ""')
    CK=$(printf '%s' "$BODY" | jq -r '.key // ""')
    CS=$(printf '%s' "$BODY" | jq -r '.status // ""')
    CR=$(printf '%s' "$BODY" | jq -r '.reason // "-"')
    printf '%s\n' "$CR" > "$ROWS.lastreason"
    awk -F'\t' -v OFS='\t' -v p="$CP" -v k="$CK" -v s="$CS" \
      '$1==p && $2==k { $4=s } {print}' "$ROWS" > "$ROWS.n" && mv "$ROWS.n" "$ROWS" ;
    printf '{"ok":true}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

ROWS="$T/rows.tsv"; : > "$ROWS"
EV="$T/events.txt"
STOPF="$T/stop"
SP="$H/state/pool/project-5/BH-1016.spawns"
QD="$H/state/build-queue/project-5"
QF="$QD/BH-1016.json"
MD="$H/state/fly-pool/project-5"
LOG="$H/logs/fly-pool.log"

# The lease env a lane-run machine gives its tick (bin/fly-pool-project.sh).
LEASE_ENV=(POOL_ON_MACHINE=1 POOL_LEASE_FENCE=1 POOL_LEASE_PROJECT=project-5 POOL_LEASE_HOLDER=h1 POOL_STOP_FILE="$STOPF")

run_pool() { # run_pool [VAR=val ...] — one tick
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           FLY_SINK="$T/fly.txt" EV="$EV" RESDIR="$T/res" EB_MARK="$EB_MARK" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_case() {
  local p
  for p in "$QD"/*.json "$MD"/*.json "$H/state/pool/project-5"/* "$T/res"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$ROWS"; rm -f "$ROWS.lastreason" "$STOPF"
  : > "$T/req.txt"; : > "$T/fly.txt"; : > "$EV"; : > "$LOG"; : > "$H/logs/ALERTS.log"
  return 0
}
queue_file() { # queue_file <key> <ticket>
  jq -nc --arg k "$1" --arg t "$2" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-19T21:28:00Z"}' > "$QD/$1.json"
  touch -d "@$((NOW-3600))" "$QD/$1.json" 2>/dev/null || true
}
queue_row() { printf 'project-5\tBH-1016\t1016\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"; }
rowstat() { awk -F'\t' '$2=="BH-1016" {print $4; exit}' "$ROWS"; }
machine_runs() { grep -c 'machine run' "$T/fly.txt" 2>/dev/null; }
renews() { grep -c 'project-leases/renew' "$T/req.txt" 2>/dev/null; }
leftover_bundles() {
  local d n=0
  for d in /dev/shm/pool.*; do
    [ -f "$d/.bh7519-marker" ] && grep -qx "$EB_MARK" "$d/.bh7519-marker" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
# line number of the first event matching a pattern, 0 when none
evline() { grep -n -m1 -- "$1" "$EV" 2>/dev/null | cut -d: -f1; }
machine() { # machine <mid> <key> <ticket> <result>
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" \
    --arg ts "$(date -u -d "@$((NOW-600))" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo 2026-10-07T03:00:00Z)" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:$ts}' > "$MD/$1.json"
  printf '%s\n' "$4" > "$T/res/$1"
}
DEFLINE="BUILD_DEFERRED all 1 slots busy — the next tick re-offers BH-1016"

# ══ F1a: control — the lease is kept, the machine's tick spawns ═════════════
reset_case
queue_row
printf '%s\n' "$((NOW-3000))" > "$SP"
run_pool "${LEASE_ENV[@]}" FLAG_BQ=1
[ "$(machine_runs)" = 1 ] && ok || bad "F1a: with the lease kept the tick must spawn once, got $(machine_runs): $(cat "$LOG")"
[ "$(renews)" -ge 2 ] && ok || bad "F1a: the lease is renewed at the top of spawn_one AND before the launch, got $(renews) renew calls"
[ "$(leftover_bundles)" = 0 ] || bad "F1a: a bundle dir was left behind"

# ══ F1b: the lease is lost during setup — no machine, the row goes back ═════
reset_case
queue_row
printf '%s\n' "$((NOW-3000))" > "$SP"; cp "$SP" "$T/spawns.before"
run_pool "${LEASE_ENV[@]}" FLAG_BQ=1 EB_TOUCH="$STOPF"
[ "$(machine_runs)" = 0 ] && ok || bad "F1b: a lease lost before the launch must buy no machine: $(cat "$T/fly.txt")"
grep -q 'BH-1016: the project lease was lost during setup — no machine spawned, job stays queued' "$LOG" && ok || bad "F1b: the log must say the lease was lost during setup: $(cat "$LOG")"
[ "$(rowstat)" = queued ] && ok || bad "F1b: the claimed row must be handed back queued, got '$(rowstat)'"
grep -q 'project lease lost before the launch' "$ROWS.lastreason" 2>/dev/null && ok || bad "F1b: the row's reason names the lost lease: '$(cat "$ROWS.lastreason" 2>/dev/null)'"
cmp -s "$SP" "$T/spawns.before" && ok || bad "F1b: nothing may count against the spawn cap: [$(tr '\n' ' ' < "$SP")]"
[ "$(leftover_bundles)" = 0 ] && ok || bad "F1b: the bundle dir (secrets) survived the lost lease"
[ -z "$(ls "$MD"/*.json 2>/dev/null)" ] && ok || bad "F1b: no machine record may be written: $(ls "$MD")"

# ══ F2: the reuse handoff ═══════════════════════════════════════════════════
# control: no lease env (the hub tick), m1 is handed BH-1017
reset_case
machine m1 BH-1016 1016 "$DEFLINE"
queue_file BH-1017 1017
run_pool
grep -q 'reused m1 for BH-1017' "$LOG" && ok || bad "F2a: the control must hand m1 on: $(cat "$LOG")"
# the lease is lost (a stop file): no handoff, the job stays queued
reset_case
machine m1 BH-1016 1016 "$DEFLINE"
queue_file BH-1017 1017
: > "$STOPF"
run_pool "${LEASE_ENV[@]}"
grep -q 'reused m1' "$LOG" && bad "F2b: no handoff on a lost lease: $(grep reused "$LOG")" || ok
grep -q 'm1: the project lease is lost — no handoff of BH-1017' "$LOG" && ok || bad "F2b: the log must say why: $(cat "$LOG")"
[ -f "$QD/BH-1017.json" ] && ok || bad "F2b: BH-1017 must stay queued"
grep -q 'machine destroy m1' "$T/fly.txt" && bad "F2b: a run that lost the lease must not destroy either" || ok

# ══ C1: the reap's write-back comes before the destroy ══════════════════════
reset_case
machine m1 BH-1016 1016 "$DEFLINE"
run_pool POOL_ON_MACHINE=1 LANE_RUN_ID=77
CK=$(evline '^ckpt fly-pool project-5'); DS=$(evline 'machine destroy m1')
[ -n "$CK" ] && [ -n "$DS" ] && [ "$CK" -lt "$DS" ] && ok || bad "C1: the checkpoint must come before the destroy (ckpt line '${CK:-none}', destroy line '${DS:-none}'): $(cat "$EV")"
reset_case
machine m1 BH-1016 1016 "$DEFLINE"
run_pool LANE_RUN_ID=77
grep -q '^ckpt' "$EV" && bad "C1: the hub tick (no POOL_ON_MACHINE) posts no write-back" || ok

# the park record: pp_checkpoint follows the write of state/remote-results/<p>/<key>.json
FP="$DIR/bin/fly-pool.sh"
awk '/> "\$HARNESS\/state\/remote-results\/\$P\/\$KEY.json"/{f=1} f&&/pp_checkpoint/{print "yes"; exit}' "$FP" > "$T/awk.out"
grep -qx yes "$T/awk.out" && ok || bad "C1: no pp_checkpoint after the reap park record"
awk '/^next_job_or_destroy\(\)/{f=1} f&&/pp_checkpoint/{c=NR} f&&/destroy_machine "\$MID" "reaped after/{d=NR} f&&/^}/{exit !(c && d && c < d)}' "$FP" \
  && ok || bad "C1: pp_checkpoint must precede destroy_machine in next_job_or_destroy"

echo "fly-pool-placement-safety.bh-7519: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
