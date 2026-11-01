#!/bin/bash
# tests/fly-pool-sync-boot-wait.bh-8824-test.sh — #8824: the harness sync
# retries while flyctl says the machine is not started, inside the
# POOL_SYNC_BOOT_WAIT_S budget; any other error fails at once.
#
# Rig: the stubbed fly/gh/curl of tests/fly-pool-fly-stderr-test.sh. The fly
# stub reads SFTP_NOTSTART_FILE, a count of "is not started" failures the sftp
# copy returns before it succeeds, besides SFTP_ERR/SFTP_RC. The stub sleep
# returns at once, so these cases prove the try cap and the error class, not
# the wall-clock bound (that bound is arithmetic on the same budget).
#
# Cases:
#   B1  two "is not started" failures then success: the machine is synced,
#       two retry lines name the wait, no sync FAILED line.
#   B2  POOL_SYNC_BOOT_WAIT_S=0: one attempt, the known FAILED line with the
#       reason, the row back queued (the path before this change).
#   B3  another error text: fails at once, no retry line.
#   B4  the try cap: POOL_SYNC_BOOT_WAIT_S=10 (step 2, cap 6 tries) with four
#       failures still syncs; with seven failures it stops after 6 tries.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-sync-boot-wait.bh-8824-test.sh   (exit 0 = pass)
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
# The bundler stub. Its marker file finds this run's bundle dir in /dev/shm;
# EB_TOUCH is never set here.
EB_MARK="flyerr-$$-$NOW"
cat > "$H/bin/fly-envbundle.sh" <<'EB'
#!/bin/bash
mkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"
printf '%s\n' "${EB_MARK:-}" > "$2/.flyerr-marker"
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
  *"ssh sftp put"*)
    # SFTP_NOTSTART_FILE holds a count: while it is above 0 the copy fails with
    # flyctl's "is not started" line and the count drops by one.
    if [ -n "${SFTP_NOTSTART_FILE:-}" ] && [ -s "$SFTP_NOTSTART_FILE" ] && [ "$(cat "$SFTP_NOTSTART_FILE")" -gt 0 ]; then
      echo "$(( $(cat "$SFTP_NOTSTART_FILE") - 1 ))" > "$SFTP_NOTSTART_FILE"
      printf 'Error: machine %s is not started\n' "$M" >&2; exit 1
    fi
    [ -n "${SFTP_ERR:-}" ] && printf '%s\n' "$SFTP_ERR" >&2; exit "${SFTP_RC:-0}" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$M" ] && [ -f "$RESDIR/$M" ] && cat "$RESDIR/$M" ;;
  *"ssh console"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*)
    [ -n "${RUN_ERR:-}" ] && printf '%s\n\n' "$RUN_ERR" >&2
    [ "${RUN_NOID:-0}" = 1 ] && exit 1
    printf 'Machine ID: 1234567890abcd\n' ;;
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
leftover_errs() { # flyctl stderr files of this run left in /dev/shm or $TMPDIR
  local d n=0
  for d in /dev/shm/pool.*; do
    [ -f "$d/.flyerr-marker" ] && grep -qx "$EB_MARK" "$d/.flyerr-marker" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
spawn_case() { # spawn_case [VAR=val ...] — one tick with BH-1016 queued
  reset_case; queue_row
  printf '%s\n' "$((NOW-3000))" > "$SP"
  run_pool "${LEASE_ENV[@]}" FLAG_BQ=1 "$@"
}


NS="$T/notstart.count"
# ══ B1: two "is not started" failures, then success ═════════════════════════
echo 2 > "$NS"
spawn_case SFTP_NOTSTART_FILE="$NS"
[ "$(grep -c 'not started yet' "$LOG")" = 2 ] && ok || bad "B1: want two retry lines, got $(grep -c 'not started yet' "$LOG"): $(cat "$LOG")"
grep -q 'spawned 1234567890abcd for BH-1016' "$LOG" && ok || bad "B1: the machine must be synced and spawned: $(cat "$LOG")"
grep -q 'harness sync FAILED' "$LOG" && bad "B1: no sync FAILED line is allowed: $(cat "$LOG")" || ok
[ "$(cat "$NS")" = 0 ] && ok || bad "B1: the stub must have failed exactly twice, count left $(cat "$NS")"
[ "$(leftover_errs)" = 0 ] && ok || bad "B1: the bundle dir was left behind"

# ══ B2: the knob at 0 is one attempt, as before ═════════════════════════════
echo 1 > "$NS"
spawn_case SFTP_NOTSTART_FILE="$NS" POOL_SYNC_BOOT_WAIT_S=0
grep -q 'harness sync FAILED to 1234567890abcd for BH-1016 — destroying, job stays queued :: Error: machine 1234567890abcd is not started$' "$LOG" && ok \
  || bad "B2: want the FAILED line with the reason: $(cat "$LOG")"
grep -q 'not started yet' "$LOG" && bad "B2: no retry line with the knob at 0: $(cat "$LOG")" || ok
[ "$(rowstat)" = queued ] && ok || bad "B2: the row must go back queued, got '$(rowstat)'"

# ══ B3: another error fails at once ═════════════════════════════════════════
spawn_case SFTP_RC=1 SFTP_ERR='Error: ssh: tunnel to fdaa::3 failed'
grep -q 'harness sync FAILED to 1234567890abcd for BH-1016 — destroying, job stays queued :: Error: ssh: tunnel to fdaa::3 failed$' "$LOG" && ok \
  || bad "B3: want the FAILED line with the reason: $(cat "$LOG")"
grep -q 'not started yet' "$LOG" && bad "B3: no retry for another error: $(cat "$LOG")" || ok

# ══ B4: the try cap bounds the tries ════════════════════════════════════════
# Budget 10: step = (10+8)/9 = 2, cap = 10/2 + 1 = 6 tries.
echo 4 > "$NS"
spawn_case SFTP_NOTSTART_FILE="$NS" POOL_SYNC_BOOT_WAIT_S=10
grep -q 'spawned 1234567890abcd for BH-1016' "$LOG" && ok || bad "B4a: four failures sit inside a cap of 6, the machine must sync: $(cat "$LOG")"
[ "$(grep -c 'not started yet' "$LOG")" = 4 ] && ok || bad "B4a: want four retry lines, got $(grep -c 'not started yet' "$LOG")"
echo 7 > "$NS"
spawn_case SFTP_NOTSTART_FILE="$NS" POOL_SYNC_BOOT_WAIT_S=10
grep -q 'harness sync FAILED to 1234567890abcd for BH-1016 — destroying, job stays queued :: Error: machine 1234567890abcd is not started$' "$LOG" && ok \
  || bad "B4b: seven failures pass the cap, want the FAILED line with the reason: $(cat "$LOG")"
[ "$(( 7 - $(cat "$NS") ))" = 6 ] && ok || bad "B4b: exactly 6 tries at a 10 s budget (cap = 10/2 + 1), got $(( 7 - $(cat "$NS") ))"

echo "fly-pool-sync-boot-wait: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
