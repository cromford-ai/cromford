#!/bin/bash
# tests/fly-pool-sync-streak.bh-8780-test.sh — the pool stops its destroy loop
# after N push-path harness syncs in a row fail (BH-8780).
#
# On 2026-10-29 05:00Z-12:10Z every launch on the hub failed its harness sftp,
# was destroyed, and the next tick launched a machine for every queued row
# again: 996 times, with no alert that named the cause.
#
# UNIT (bin/lib/pool-sync-streak.sh, a scratch $HARNESS, a stub alert-line):
#   U1  pss_max: unset, 5, 0, 100 give 5, 5, 0, 100.
#   U2  pss_max: abc, -1, 101, " 7x" give 5 and one line naming the value.
#   U3  pss_count: missing file, garbage, "3\t..." give 0, 0, 3.
#   U4  4 fails with max 5: count 4, no alert, no marker.
#   U5  the 5th fail: 1 alert with the count, key, mid and reason, plus the
#       marker; the 6th and 7th fail: still 1 alert.
#   U6  ok: count 0, no marker, one "streak ends" line; 5 more fails: a 2nd alert.
#   U7  a reason with a tab and a newline is stored on one line; count reads 3.
#   U8  alert-line rc 1: no marker; the next fail tries the alert again.
#   U9  max 0: 50 fails, 0 alerts; the gate leaves BUDGET 3; no stop.
#   U10 no root (HARNESS and H empty): pss_note rc 1, pss_count 0 rc 1, the
#       gate does not trip; a state path that is a file: no streak, no alert.
#   U11 an unknown verb: rc 2, the count does not move.
# STATIC:
#   S1  the lib is sourced once from config/fly-pool.d/0100-head.sh, beside the
#       other pool libs; no config/fly-pool.d/*-bh-8780-* fragment exists.
# DRIVEN (`bash bin/fly-pool.sh project-5`, fly/gh/curl stubbed onto $PATH, the
# rig of tests/fly-pool-fly-stderr-test.sh, copied; each case its own scratch):
#   D1  streak 4, one row, the sftp fails: the FAILED line, streak 5, ONE alert
#       that names the flyctl error.
#   D2  streak 5, 3 rows: ONE `machine run`, 2 queue files left, the probe line.
#   D3  streak 5, one row, the sync passes: streak 0, no marker, "streak ends".
#   D4  streak 4, a machine run with no id: streak still 4, no alert.
#   D5  streak 0, 3 rows, the syncs pass: 3 `machine run` (healthy = as before).
#   D6  streak 4 at the tick gate, 5 after row 1 launches (the curl stub writes
#       it; the syncs fail, so no reset races the walk): ONE `machine run`,
#       the "streak reached 5 during this tick" line.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date +%s)
LIB="$DIR/bin/lib/pool-sync-streak.sh"

# ══ UNIT ═════════════════════════════════════════════════════════════════════
# uh <name> — a fresh scratch harness for one unit case, with an alert-line stub
# that appends its text to logs/ALERTS.log and exits $ALERT_RC.
uh() {
  local h="$T/u-$1"
  mkdir -p "$h/bin" "$h/logs" "$h/state"
  cat > "$h/bin/alert-line.sh" <<'AL'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --id|--project|--severity) shift 2 ;; *) break ;; esac; done
[ "${ALERT_RC:-0}" = 0 ] || exit "$ALERT_RC"
printf '%s\n' "$*" >> "$HARNESS/logs/ALERTS.log"
AL
  chmod +x "$h/bin/alert-line.sh"; : > "$h/logs/ALERTS.log"; : > "$h/logs/say.log"
  printf '%s' "$h"
}
# u <harness> <cmd...> — run one lib call in a subshell with say → logs/say.log.
u() {
  local h="$1"; shift
  ( HARNESS="$h"; P="${P:-project-5}"
    say() { echo "$*" >> "$HARNESS/logs/say.log"; }
    # shellcheck source=bin/lib/pool-sync-streak.sh
    . "$LIB" || exit 9
    "$@" )
}
alerts() { grep -c . "$1/logs/ALERTS.log" 2>/dev/null || true; }
SD=state/pool-sync-streak

# U1
H=$(uh u1)
R="$(SYNC_FAIL_STREAK_MAX='' u "$H" pss_max) $(SYNC_FAIL_STREAK_MAX=5 u "$H" pss_max) $(SYNC_FAIL_STREAK_MAX=0 u "$H" pss_max) $(SYNC_FAIL_STREAK_MAX=100 u "$H" pss_max)"
[ "$R" = "5 5 0 100" ] && ok || bad "U1: pss_max unset/5/0/100 gave '$R'"
# U2
for V in abc -1 101 ' 7x'; do
  H=$(uh "u2$(printf '%s' "$V" | tr -dc 'a-z0-9')")
  R=$(SYNC_FAIL_STREAK_MAX="$V" u "$H" pss_max)
  [ "$R" = 5 ] && ok || bad "U2: pss_max '$V' gave '$R', want 5"
  [ "$(grep -c "SYNC_FAIL_STREAK_MAX=$V is not" "$H/logs/say.log")" = 1 ] && ok || bad "U2: one line must name '$V': $(cat "$H/logs/say.log")"
done
# U3
H=$(uh u3)
R1=$(u "$H" pss_count project-5); mkdir -p "$H/$SD"
printf 'garbage\n' > "$H/$SD/project-5.streak"; R2=$(u "$H" pss_count project-5)
printf '3\t1\tBH-1\tm\twhy\n' > "$H/$SD/project-5.streak"; R3=$(u "$H" pss_count project-5)
[ "$R1 $R2 $R3" = "0 0 3" ] && ok || bad "U3: missing/garbage/3 gave '$R1 $R2 $R3'"
# U4, U5
H=$(uh u45)
for i in 1 2 3 4; do u "$H" pss_note fail project-5 "BH-$i" "mid$i" "Error: tunnel unavailable"; done
[ "$(u "$H" pss_count project-5)" = 4 ] && ok || bad "U4: 4 fails must count 4, got $(u "$H" pss_count project-5)"
[ "$(alerts "$H")" = 0 ] && ok || bad "U4: 4 fails with max 5 must not alert: $(cat "$H/logs/ALERTS.log")"
[ ! -e "$H/$SD/project-5.alerted" ] && ok || bad "U4: no marker before the max"
u "$H" pss_note fail project-5 BH-5 mid5 "Error: tunnel unavailable: timed out"
[ "$(u "$H" pss_count project-5)" = 5 ] && ok || bad "U5: 5 fails must count 5"
[ "$(alerts "$H")" = 1 ] && ok || bad "U5: the 5th fail must alert once, got $(alerts "$H")"
grep -q 'harness sync failed 5 times in a row.*BH-5 to mid5: Error: tunnel unavailable: timed out' "$H/logs/ALERTS.log" && ok \
  || bad "U5: the alert must name the count, key, mid and reason: $(cat "$H/logs/ALERTS.log")"
[ -e "$H/$SD/project-5.alerted" ] && ok || bad "U5: the marker must exist after the alert"
u "$H" pss_note fail project-5 BH-6 mid6 x; u "$H" pss_note fail project-5 BH-7 mid7 x
[ "$(alerts "$H")" = 1 ] && ok || bad "U5: the 6th and 7th fail must not alert again, got $(alerts "$H")"
# U6
u "$H" pss_note ok project-5 BH-8 mid8
[ "$(u "$H" pss_count project-5)" = 0 ] && ok || bad "U6: ok must reset the count"
[ ! -e "$H/$SD/project-5.alerted" ] && ok || bad "U6: ok must remove the marker"
[ "$(grep -c 'harness sync passed for BH-8 on mid8: the streak of 7 failures ends' "$H/logs/say.log")" = 1 ] && ok \
  || bad "U6: one 'streak ends' line: $(cat "$H/logs/say.log")"
for i in 1 2 3 4 5; do u "$H" pss_note fail project-5 "BH-2$i" m x; done
[ "$(alerts "$H")" = 2 ] && ok || bad "U6: a new episode must alert again, got $(alerts "$H")"
# U7
H=$(uh u7)
for i in 1 2 3; do u "$H" pss_note fail project-5 BH-1 m "$(printf 'a\tb\nc')"; done
[ "$(wc -l < "$H/$SD/project-5.streak" | tr -d ' ')" = 1 ] && ok || bad "U7: the streak file must be one line"
[ "$(cut -f5 "$H/$SD/project-5.streak")" = "a b c" ] && ok || bad "U7: the reason must be flattened, got '$(cut -f5 "$H/$SD/project-5.streak")'"
[ "$(u "$H" pss_count project-5)" = 3 ] && ok || bad "U7: the round trip must read 3"
# U8
H=$(uh u8)
for i in 1 2 3 4; do u "$H" pss_note fail project-5 BH-1 m x; done
ALERT_RC=1 u "$H" pss_note fail project-5 BH-1 m x
[ ! -e "$H/$SD/project-5.alerted" ] && [ "$(alerts "$H")" = 0 ] && ok || bad "U8: a failed alert must leave no marker"
u "$H" pss_note fail project-5 BH-1 m x
[ -e "$H/$SD/project-5.alerted" ] && [ "$(alerts "$H")" = 1 ] && ok || bad "U8: the next fail must try the alert again"
# U9
H=$(uh u9)
for i in $(seq 50); do SYNC_FAIL_STREAK_MAX=0 u "$H" pss_note fail project-5 BH-1 m x; done
[ "$(alerts "$H")" = 0 ] && ok || bad "U9: max 0 must never alert"
R=$(SYNC_FAIL_STREAK_MAX=0 BUDGET=3 HOTFIX_EXTRA=2 u "$H" eval 'pss_tick_gate; echo "$BUDGET $HOTFIX_EXTRA $PSS_TICK_TRIPPED"')
[ "$R" = "3 2 0" ] && ok || bad "U9: max 0 must leave the budget, got '$R'"
SYNC_FAIL_STREAK_MAX=0 u "$H" eval 'PSS_TICK_TRIPPED=0; pss_stop_due' && bad "U9: max 0 must never stop" || ok
# The gate and the stop at max 5, count 50 (the trip side of U9).
R=$(BUDGET=3 HOTFIX_EXTRA=2 u "$H" eval 'pss_tick_gate; echo "$BUDGET $HOTFIX_EXTRA $PSS_TICK_TRIPPED"')
[ "$R" = "1 0 1" ] && ok || bad "U9: a tripped gate must set BUDGET 1, HOTFIX_EXTRA 0, got '$R'"
u "$H" eval 'PSS_TICK_TRIPPED=1; pss_stop_due' && bad "U9: a tick that started tripped must not stop (the probe)" || ok
u "$H" eval 'PSS_TICK_TRIPPED=0; pss_stop_due' && ok || bad "U9: a streak reached mid-tick must stop"

# U10
R=$( HARNESS=""; H=""; P=project-5; say() { :; }
     . "$LIB" || exit 9
     pss_note fail project-5 BH-1 m x; a=$?
     c=$(pss_count project-5); b=$?
     BUDGET=3; HOTFIX_EXTRA=1; SYNC_FAIL_STREAK_MAX=0 pss_tick_gate
     echo "$a $c $b $BUDGET $PSS_TICK_TRIPPED" )
[ "$R" = "1 0 1 3 0" ] && ok || bad "U10: no root must refuse and read no streak, got '$R'"
H=$(uh u10); : > "$H/$SD"
for i in 1 2 3 4 5 6; do u "$H" pss_note fail project-5 BH-1 m x; done
[ -f "$H/$SD" ] && [ "$(u "$H" pss_count project-5)" = 0 ] && [ "$(alerts "$H")" = 0 ] && ok \
  || bad "U10: a state path the lib cannot make must give no streak and no alert"
# U11
H=$(uh u11)
u "$H" pss_note fail project-5 BH-1 m x; u "$H" pss_note bogus project-5 BH-1 m; RC=$?
[ "$RC" = 2 ] && [ "$(u "$H" pss_count project-5)" = 1 ] && ok || bad "U11: an unknown verb must be rc 2 and not move the count (rc=$RC)"

# ══ STATIC ═══════════════════════════════════════════════════════════════════
# S1
[ "$(grep -c 'pool-sync-streak.sh' "$DIR/config/fly-pool.d/0100-head.sh")" = 2 ] \
  && [ "$(grep -c '^\[ -r "\$HARNESS/bin/lib/pool-sync-streak.sh" \] && \. ' "$DIR/config/fly-pool.d/0100-head.sh")" = 1 ] && ok \
  || bad "S1: 0100-head.sh must source bin/lib/pool-sync-streak.sh once"
S1F=$(find "$DIR/config/fly-pool.d" -name '*-bh-8780-*' 2>/dev/null)
[ -z "$S1F" ] && ok || bad "S1: no ticket fragment for BH-8780 (the lib is sourced from 0100-head.sh): $S1F"

# ══ DRIVEN ═══════════════════════════════════════════════════════════════════
# rig <name> — a fresh scratch harness, fake bin and row file for one case.
rig() {
  H="$T/d-$1"; FB="$T/d-$1/fakebin"; RD="$T/d-$1/res"
  mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
           "$H/state/fly" "$H/state/fly-pool/project-5" \
           "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
           "$H/state/pool/project-5" "$H/builds" "$FB" "$RD"
  printf 'FLY_API_TOKEN_project-5=tok-fixture-1\n' > "$H/env/fly.env"
  : > "$H/env/global.env"
  printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
  printf '3\n' > "$H/flags/fly-pool-project-5"
  printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
  printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
  printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
  cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
  scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
  for L in bin/lib/pool-placement.sh bin/lib/lane-placement.sh bin/lib/project-lease.sh; do
    mkdir -p "$H/$(dirname "$L")"; [ -e "$H/$L" ] || cp "$DIR/$L" "$H/$L"
  done
  cat > "$H/bin/lib/lane-run-inputs.sh" <<'LRI'
lri_checkpoint() { echo "ckpt $*" >> "${EV:-/dev/null}"; return 0; }
LRI
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
  printf '#!/bin/bash\nshift; exec "$@"\n' > "$FB/timeout"
  printf '#!/bin/bash\nexit 0\n' > "$FB/flock"
  printf '#!/bin/bash\nexit 0\n' > "$FB/sleep"
  cat > "$H/bin/fly-envbundle.sh" <<'EB'
#!/bin/bash
mkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"
echo "bundled 2 files"; exit 0
EB
cat > "$FB/base64" <<'B64'
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
cat > "$FB/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
echo "fly $*" >> "${EV:-/dev/null}"
M=""; prev=""
for a in "$@"; do [ "$prev" = --machine ] && M="$a"; prev="$a"; done
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh sftp put"*) [ -n "${SFTP_ERR:-}" ] && printf '%s\n' "$SFTP_ERR" >&2; exit "${SFTP_RC:-0}" ;;
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

cat > "$FB/gh" <<'GH'
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
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
# D6: the model-route read of the first launch (pool_mr_bundle, in the walk's
# own shell) writes the streak at 5, as a sync failure that lands mid-tick.
case "$URL" in *model-route*)
  if [ -n "${STREAK_BUMP:-}" ] && [ ! -e "$STREAK_BUMP.done" ]; then
    printf '5\t0\tBH-1\tm\tbump\n' > "$STREAK_BUMP"; : > "$STREAK_BUMP.done"
  fi ;;
esac
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
  chmod +x "$H/bin"/*.sh "$FB"/*
  ROWS="$H/rows.tsv"; : > "$ROWS"; EV="$H/events.txt"; : > "$EV"
  FLYLOG="$H/fly.txt"; : > "$FLYLOG"; : > "$H/logs/ALERTS.log"
  LOG="$H/logs/fly-pool.log"; : > "$LOG"
  mkdir -p "$H/$SD"
}
# rows <n> — n queued rows BH-1016.. (rows-only mode reads them from the worker)
rows() {
  local i k
  for i in $(seq 0 $(($1 - 1))); do
    k="BH-$((1016 + i))"
    printf 'project-5\t%s\t%s\tqueued\tfly\t0\t-\t-\t-\n' "$k" "$((1016 + i))" >> "$ROWS"
    printf '%s\n' "$((NOW-3000))" > "$H/state/pool/project-5/$k.spawns"
  done
}
streak() { printf '%s\t%s\tBH-1\tm\tpreset\n' "$1" "$NOW" > "$H/$SD/project-5.streak"; }
run_pool() { # run_pool [VAR=val ...] — one tick
  ( export PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=secret-fixture-1 JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 REQ_SINK="$H/req.txt" ROWS="$ROWS" \
           FLY_SINK="$FLYLOG" EV="$EV" RESDIR="$RD" \
           FLY_API_TOKEN_project-5=tok-fixture-1 FLY_BIN_DIR="$FB" \
           POOL_ON_MACHINE=1 POOL_LEASE_FENCE=1 POOL_LEASE_PROJECT=project-5 POOL_LEASE_HOLDER=h1 \
           POOL_STOP_FILE="$H/stop" FLAG_BQ=1 "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
runs() { grep -c 'machine run' "$FLYLOG" 2>/dev/null || true; }
dcount() { awk -F'\t' 'NR==1{print $1}' "$H/$SD/project-5.streak" 2>/dev/null; }
queued() { awk -F'\t' '$4=="queued"' "$ROWS" | grep -c . || true; }

# D1
rig d1; rows 1; streak 4
run_pool SFTP_RC=1 SFTP_ERR='Error: tunnel unavailable: 2001:db8::3 timed out'
grep -q 'harness sync FAILED to 1234567890abcd for BH-1016 — destroying, job stays queued :: Error: tunnel unavailable: 2001:db8::3 timed out$' "$LOG" && ok \
  || bad "D1: the FAILED line must stay the same: $(cat "$LOG")"
[ "$(dcount)" = 5 ] && ok || bad "D1: the streak must be 5, got '$(dcount)'"
[ "$(grep -c 'harness sync failed 5 times in a row' "$H/logs/ALERTS.log")" = 1 ] && grep -q 'tunnel unavailable' "$H/logs/ALERTS.log" && ok \
  || bad "D1: ONE alert naming the flyctl error: $(grep -c "harness sync failed" "$H/logs/ALERTS.log") streak line(s)"
# D2
rig d2; rows 3; streak 5
run_pool SFTP_RC=1 SFTP_ERR='Error: tunnel unavailable'
[ "$(runs)" = 1 ] && ok || bad "D2: a tripped tick must launch ONE probe, got $(runs) machine runs"
[ "$(queued)" = 3 ] && ok || bad "D2: every row must stay queued (2 untouched, the probe's handed back), got $(queued)"
grep -q 'one probe launch this tick, the other rows stay queued' "$LOG" && ok || bad "D2: the probe line: $(grep 'harness sync' "$LOG")"
# D3
rig d3; rows 1; streak 5; : > "$H/$SD/project-5.alerted"
run_pool
[ "$(dcount)" = 0 ] && ok || bad "D3: a passed sync must reset the streak, got '$(dcount)'"
[ ! -e "$H/$SD/project-5.alerted" ] && ok || bad "D3: a passed sync must remove the marker"
grep -q 'harness sync passed for BH-1016 on 1234567890abcd: the streak of 5 failures ends' "$LOG" && ok || bad "D3: the 'streak ends' line: $(grep 'harness sync' "$LOG")"
# D4
rig d4; rows 1; streak 4
run_pool RUN_NOID=1 RUN_ERR='Error: could not launch machine'
grep -q 'machine run FAILED for BH-1016' "$LOG" && ok || bad "D4: the launch must fail: $(cat "$LOG")"
[ "$(dcount)" = 4 ] && ok || bad "D4: a machine run failure must not count, got '$(dcount)'"
grep -q "harness sync failed" "$H/logs/ALERTS.log" && bad "D4: no streak alert: $(grep "harness sync failed" "$H/logs/ALERTS.log")" || ok
# D5
rig d5; rows 3; streak 0
run_pool
[ "$(runs)" = 3 ] && ok || bad "D5: a healthy pool must launch 3, got $(runs)"
grep -q 'harness sync:' "$LOG" && bad "D5: no streak line when healthy: $(grep 'harness sync:' "$LOG")" || ok
# D6
rig d6; rows 3; streak 4
run_pool STREAK_BUMP="$H/$SD/project-5.streak" SFTP_RC=1 SFTP_ERR="Error: tunnel unavailable"
[ -e "$H/$SD/project-5.streak.done" ] && ok || bad "D6: the curl stub must see the model-route read (the bump is the setup)"
grep -q 'harness sync: streak reached 5 during this tick — no more launches this tick' "$LOG" && ok \
  || bad "D6: the mid-tick stop line: $(grep 'harness sync' "$LOG")"
[ "$(runs)" = 1 ] && ok || bad "D6: a streak reached after row 1 must stop the walk at row 2, got $(runs) machine runs"
[ "$(queued)" = 3 ] && ok || bad "D6: every row stays queued, got $(queued)"

echo "fly-pool-sync-streak: $PASS passed, $FAIL failed (FAIL=$FAIL)"
[ "$FAIL" -eq 0 ]
