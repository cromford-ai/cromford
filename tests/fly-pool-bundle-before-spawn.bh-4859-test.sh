#!/bin/bash
# tests/fly-pool-bundle-before-spawn.bh-4859-test.sh — BH-4859.
#
# Four things the pool's spawn_one / pool_spawn_decision must now do:
#   A. bundle the env BEFORE `fly machine run`, so a bundle failure buys no
#      machine, records no spawn against the per-key cap, hands the row back
#      queued, and says WHY (the bundler's FATAL line) in the log and the row;
#   B. un-record the spawn-cap entry on every infra exit after the record
#      (no machine id, harness sync failed, no GitHub credential, env/job push
#      failed), so only a
#      machine that really got its job counts;
#   C. at the cap, keep the row queued and say when it retries — never close it
#      `failed … deferred to a human`, which nothing ever read again.
#
# DRIVEN, NOT GREPPED: `bash bin/fly-pool.sh project-5` runs against a scratch
# $HARNESS with fly/gh/curl/timeout/sleep/flock stubbed onto $PATH, and every
# assertion is about the sinks (fly calls, worker requests, rows), the files on
# disk and the lane's log lines.
#
# The file anchors wall-clock time in $NOW; every fixture timestamp is derived
# from that one value so the suite does not flake on calendar drift.
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
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"

cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"

# The bundler stub. Every mode first writes the bundle dir it was handed (two
# env files and a marker carrying this run's unique id), because the real one
# writes before it can fail, and A9 is about that dir being removed on every
# exit. EB_MODE picks what it then says and how it exits.
EB_MARK="bh4859-$$-$NOW"
# A7's credential-shaped fixture is built at runtime, so no token literal sits
# in this file for the share-mirror leak guard to trip on.
EB_TOKEN="ghp_$(printf 'a1B2c3D4e5F6g7H8i9J0%.0s' 1 2)"
cat > "$H/bin/fly-envbundle.sh" <<'EB'
#!/bin/bash
echo "bundle $*" >> "${EB_SINK:-/dev/null}"
mkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"
printf '%s\n' "${EB_MARK:-}" > "$2/.bh4859-marker"
case "${EB_MODE:-ok}" in
  ok)     echo "bundled 2 files"; exit 0 ;;
  fail)   echo "fly-envbundle/$1: resolving owner box" >&2
          echo "fly-envbundle/$1 FATAL: ssh env extract from 10.0.0.13 failed (ssh rc 255)" >&2
          exit 1 ;;
  silent) exit 1 ;;
  secret) echo "fly-envbundle/$1 FATAL: bad line GH_TOKEN=${EB_TOKEN:?}" >&2
          exit 1 ;;
  ctl)    printf 'fly-envbundle/%s FATAL: split\there\rand gone\n' "$1" >&2
          exit 1 ;;
esac
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

# Fly stub: records every call; FLY_SFTP_FAIL fails the harness sync,
# FLY_NOMID makes `machine run` print no id, FLY_JOBPUT_FAIL fails the
# job.json push (mput goes through `ssh console`).
cat > "$T/fakebin/fly" <<'FLY'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh sftp put"*) [ "${FLY_SFTP_FAIL:-0}" = 1 ] && exit 1 ;;
  *"ssh console"*"/run/harness/job.json"*) [ "${FLY_JOBPUT_FAIL:-0}" = 1 ] && exit 1 ;;
  *"ssh console"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) [ "${FLY_NOMID:-0}" = 1 ] || printf 'Machine ID: 1234567890abcd\n' ;;
esac
exit 0
FLY

# gh stub: an open ai-build ticket 1016, no branch, no open PR.
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" == *"issues/1016"* ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" == *"git/ref/heads/ticket/bh-1016"* ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH

# The worker, file-backed over $ROWS (same shape as
# tests/build-queue-rows-only.bh-1367-test.sh): claims really CAS, PATCH really
# moves the row and writes its reason, GET really filters. Columns:
#   1 project 2 key 3 ticket_id 4 status 5 target 6 attempt 7 reason 8 meta 9 machine
# The reason is stored VERBATIM (no tab scrubbing here) so A8 is about what the
# pool sends, not about the stub tidying it.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
qparam() { case "$URL" in *"$1"=*) V="${URL##*"$1"=}"; printf '%s' "${V%%&*}" ;; esac; }
case "$M $URL" in
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
SP="$H/state/pool/project-5/BH-1016.spawns"
QF="$H/state/build-queue/project-5/BH-1016.json"
POOLD="$H/state/fly-pool/project-5"

run_pool() { # run_pool [VAR=val ...] — one tick; logs are KEPT across calls in a case
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           FLY_SINK="$T/fly.txt" EB_SINK="$T/eb.txt" EB_MARK="$EB_MARK" EB_TOKEN="$EB_TOKEN" \
           FLY_API_TOKEN_project-5=tok FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_case() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json "$POOLD"/*.json "$H/state/pool/project-5"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$ROWS"; rm -f "$ROWS.lastreason"
  : > "$T/req.txt"; : > "$T/fly.txt"; : > "$T/eb.txt"
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  return 0
}
queue_file() {
  jq -nc '{ticket_id:"1016",key:"BH-1016",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-09-19T21:28:00Z"}' > "$QF"
}
queue_row() { printf 'project-5\tBH-1016\t1016\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"; }
rowstat() { awk -F'\t' '$2=="BH-1016" {print $4; exit}' "$ROWS"; }
machine_runs() { grep -c 'machine run' "$T/fly.txt" 2>/dev/null; }
claims() { grep -c '/api/queue/claim' "$T/req.txt" 2>/dev/null; }
# Our own bundle dirs still on /dev/shm: a dir whose marker carries THIS run's id.
leftover_bundles() {
  local d n=0
  for d in /dev/shm/pool.*; do
    [ -f "$d/.bh4859-marker" ] && grep -qx "$EB_MARK" "$d/.bh4859-marker" 2>/dev/null && n=$((n+1))
  done
  echo "$n"
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
OLD1=$((NOW-90000)); OLD2=$((NOW-7200))

# ══ AT-1: a failing bundler costs nothing and says why (flag-off) ═══════════
reset_case
queue_file
printf '%s\n%s\n' "$OLD1" "$OLD2" > "$SP"; cp "$SP" "$T/spawns.before"
run_pool EB_MODE=fail
[ -s "$T/eb.txt" ] && ok || bad "A1 precondition: the bundler was never called: $(log)"
[ "$(machine_runs)" = 0 ] && ok \
  || bad "A1: a failed bundle must buy no machine — fly calls: $(cat "$T/fly.txt")"
grep -qF 'env bundle FAILED for BH-1016: ssh env extract from 10.0.0.13 failed (ssh rc 255) — no machine spawned, job stays queued' "$H/logs/fly-pool.log" \
  && ok || bad "A2: the log must carry the bundler's FATAL reason: $(log)"
cmp -s "$SP" "$T/spawns.before" && ok \
  || bad "A3: a failed bundle must record nothing against the cap: before=[$(tr '\n' ' ' < "$T/spawns.before")] after=[$(tr '\n' ' ' < "$SP" 2>/dev/null)]"
[ -f "$QF" ] && ok || bad "A4: flag-off, the queue file must stay for the next tick"
[ -z "$(ls "$POOLD"/*.json 2>/dev/null)" ] && ok || bad "A4: no machine json may be written: $(ls "$POOLD")"
[ "$(leftover_bundles)" = 0 ] && ok || bad "A9: the bundle dir (secrets) survived a bundle failure on /dev/shm"

# ══ A5: rows-only — the row goes back queued with the reason, claim first ═══
reset_case
queue_row
run_pool EB_MODE=fail FLAG_BQ=1
[ "$(rowstat)" = queued ] && ok || bad "A5: the row must be handed back queued, got '$(rowstat)': $(log)"
[ "$(cat "$ROWS.lastreason" 2>/dev/null)" = 'env bundle failed: ssh env extract from 10.0.0.13 failed (ssh rc 255)' ] \
  && ok || bad "A5: the row's reason must name the bundler's failure, got '$(cat "$ROWS.lastreason" 2>/dev/null)'"
[ "$(claims)" = 1 ] && ok || bad "A5: exactly one claim, before the bundle, got $(claims)"
[ "$(machine_runs)" = 0 ] && ok || bad "A5: no machine run under rows-only either"

# ══ A6: a bundler that says nothing still leaves a reason ═══════════════════
reset_case
queue_file
run_pool EB_MODE=silent
grep -qF 'env bundle FAILED for BH-1016: fly-envbundle.sh exited rc 1 and printed no reason' "$H/logs/fly-pool.log" \
  && ok || bad "A6: an empty-output failure must say so: $(log)"

# ══ A7: a credential-shaped reason is withheld from the log and the row ═════
reset_case
queue_row
run_pool EB_MODE=secret FLAG_BQ=1
grep -q 'env bundle FAILED for BH-1016: reason withheld' "$H/logs/fly-pool.log" \
  && ok || bad "A7: the log must withhold a credential-shaped reason: $(log)"
grep -q 'reason withheld' "$ROWS.lastreason" 2>/dev/null \
  && ok || bad "A7: the row must withhold it too: $(cat "$ROWS.lastreason" 2>/dev/null)"
N=$(cat "$H/logs/fly-pool.log" "$ROWS" "$ROWS.lastreason" "$T/req.txt" 2>/dev/null | grep -c 'ghp_')
[ "$N" = 0 ] && ok || bad "A7: a token reached the log or the worker ($N hits)"

# ══ A8: control characters never split the row's reason ═════════════════════
reset_case
queue_row
run_pool EB_MODE=ctl FLAG_BQ=1
R=$(cat "$ROWS.lastreason" 2>/dev/null)
case "$R" in
  *$'\t'*|*$'\r'*) bad "A8: the reason carried a tab or CR: $(printf '%q' "$R")" ;;
  'env bundle failed: '*) ok ;;
  *) bad "A8: no bundle-failed reason was sent: '$R'" ;;
esac
[ "$(wc -l < "$ROWS.lastreason" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "A8: the reason is not one line"

# ══ AT-2 B1: a harness-sync failure after the spawn is un-recorded ══════════
reset_case
queue_file
printf '%s\n%s\n%s\n' "$((NOW-5000))" "$((NOW-4000))" "$((NOW-3000))" > "$SP"; cp "$SP" "$T/spawns.before"
run_pool FLY_SFTP_FAIL=1 POOL_SPAWN_CAP_PER_KEY=12
[ "$(machine_runs)" = 1 ] && ok || bad "B1 precondition: machine run must have been called once, got $(machine_runs)"
grep -q 'machine destroy 1234567890abcd' "$T/fly.txt" && ok || bad "B1: the synced-nothing machine must be destroyed"
grep -q 'harness sync FAILED' "$H/logs/fly-pool.log" && ok || bad "B1: sync failure must be logged: $(log)"
cmp -s "$SP" "$T/spawns.before" && ok \
  || bad "B1: a sync failure must leave the cap count unchanged: [$(tr '\n' ' ' < "$SP")]"
[ -f "$QF" ] && ok || bad "B1: the queue file must be kept"
[ "$(leftover_bundles)" = 0 ] && ok || bad "A9/B1: the bundle dir survived a sync failure"

# ══ B2: machine run printed no id ═══════════════════════════════════════════
reset_case
queue_file
printf '%s\n' "$((NOW-3000))" > "$SP"; cp "$SP" "$T/spawns.before"
run_pool FLY_NOMID=1
[ "$(machine_runs)" = 1 ] && ok || bad "B2 precondition: machine run not attempted"
cmp -s "$SP" "$T/spawns.before" && ok || bad "B2: a no-machine spawn must not count: [$(tr '\n' ' ' < "$SP")]"
grep -q 'machine destroy' "$T/fly.txt" && bad "B2: nothing to destroy, yet destroy was called" || ok
[ "$(leftover_bundles)" = 0 ] && ok || bad "A9/B2: the bundle dir survived a machine-run failure"

# ══ B4: env/job push failed — the machine never got its job ═════════════════
reset_case
queue_file
printf '%s\n' "$((NOW-3000))" > "$SP"; cp "$SP" "$T/spawns.before"
run_pool FLY_JOBPUT_FAIL=1
grep -q 'env/job push FAILED' "$H/logs/fly-pool.log" && ok || bad "B4 precondition: push failure not reached: $(log)"
cmp -s "$SP" "$T/spawns.before" && ok || bad "B4: a machine that never got its job must not count: [$(tr '\n' ' ' < "$SP")]"
[ "$(leftover_bundles)" = 0 ] && ok || bad "A9/B4: the bundle dir survived a push failure"

# ══ B5: no GitHub credential for the machine (lead review lr-4895) ══════════
# App tokens are armed (env/github-app.env + an executable bin/gh-token.sh),
# the mint answers nothing and the bundle carries no PAT: fly-pool.sh refuses
# the spawn before it buys a machine (BH-7215). The cap entry must go too
# (ticket item 2).
reset_case
queue_file
printf '%s\n' "$((NOW-3000))" > "$SP"; cp "$SP" "$T/spawns.before"
printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
printf '#!/bin/bash\nexit 1\n' > "$H/bin/gh-token.sh"; chmod +x "$H/bin/gh-token.sh"
run_pool
grep -q 'no App token for .* and the bundle carries no PAT' "$H/logs/fly-pool.log" && ok \
  || bad "B5 precondition: the no-credential exit was not reached: $(log)"
# BH-7215: the credential swap runs before `fly machine run`, so no machine is
# bought and none is destroyed.
[ "$(machine_runs)" = 0 ] && ok || bad "B5: no credential must buy no machine, got $(machine_runs) machine run(s)"
grep -q 'machine destroy' "$T/fly.txt" && bad "B5: no machine was bought, yet destroy was called" || ok
cmp -s "$SP" "$T/spawns.before" && ok \
  || bad "B5: a machine destroyed for no GitHub credential must not count against the cap: [$(tr '\n' ' ' < "$SP")]"
[ -f "$QF" ] && ok || bad "B5: the queue file must be kept"
scratch_rm "$H/env/github-app.env"; scratch_rm "$H/bin/gh-token.sh"

# ══ B3: control — a real spawn still records exactly one entry ══════════════
reset_case
queue_file
printf '%s\n' "$((NOW-3000))" > "$SP"
run_pool
MJ=$(ls "$POOLD"/*.json 2>/dev/null | head -1)
[ -n "$MJ" ] && ok || bad "B3: a good bundle must spawn: $(log)"
[ "$(wc -l < "$SP" | tr -d ' ')" = 2 ] && ok || bad "B3: a real spawn records exactly one line, got [$(tr '\n' ' ' < "$SP")]"
[ "$(tail -1 "$SP")" = "$(jq -r '.spawn_cap_ts // ""' "$MJ" 2>/dev/null)" ] && ok \
  || bad "B3: spawn_cap_ts must equal the recorded line"
# ORDER: the bundle ran before the machine was bought.
EBN=$(grep -c . "$T/eb.txt"); [ "$EBN" = 1 ] && ok || bad "B3: the bundler ran $EBN times"
[ "$(leftover_bundles)" = 0 ] && ok || bad "A9/B3: the bundle dir survived a good spawn"

# ══ AT-3 C1-C3: 12 real spawns, then the cap is a timed retry ═══════════════
reset_case
queue_file
: > "$SP"; for i in 0 1 2 3 4 5 6 7 8 9 10 11; do echo "$((NOW-3600+i*320))" >> "$SP"; done
run_pool POOL_SPAWN_CAP_PER_KEY=12 POOL_SPAWN_CAP_WINDOW_S=86400
WANT=$(date -u -d "@$((NOW-3600+86400+1))" '+%H:%MZ')
[ "$(machine_runs)" = 0 ] && ok || bad "C1: no machine at the cap"
grep -q 'skipping BH-1016: spawn cap reached' "$H/logs/fly-pool.log" && ok || bad "C1: cap skip not logged: $(log)"
grep -qF "retried after $WANT" "$H/logs/fly-pool.log" && ok \
  || bad "C1: the log must say the retry time $WANT: $(log)"
[ -f "$QF" ] && ok || bad "C2: flag-off, the capped queue file must be kept"
run_pool POOL_SPAWN_CAP_PER_KEY=12 POOL_SPAWN_CAP_WINDOW_S=86400
[ "$(grep -c 'POOL_SPAWN_CAP_WAIT' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "C3: exactly one POOL_SPAWN_CAP_WAIT page over two capped ticks: $(cat "$H/logs/ALERTS.log")"
grep -qF "spawns again after $WANT" "$H/logs/ALERTS.log" && ok || bad "C3: the page must say when: $(cat "$H/logs/ALERTS.log")"
grep -q 'POOL_DEFER_TO_HUMAN' "$H/logs/ALERTS.log" && bad "C3: the old human-deferral token paged" || ok
# C4: age every entry out of the window — the same row spawns with no operator step.
: > "$SP"; for i in 0 1 2 3 4 5 6 7 8 9 10 11; do echo "$((NOW-90000-i))" >> "$SP"; done
run_pool POOL_SPAWN_CAP_PER_KEY=12 POOL_SPAWN_CAP_WINDOW_S=86400
[ -n "$(ls "$POOLD"/*.json 2>/dev/null)" ] && ok || bad "C4: the timed retry must spawn once the window rolls: $(log)"
[ ! -f "$H/state/pool/project-5/BH-1016.defer-to-human" ] && ok || bad "C4: the page sentinel must clear"

# C2 (rows-only) + C5: the capped row stays queued, no PATCH sets it failed.
reset_case
queue_row
: > "$SP"; for i in 0 1 2 3 4 5 6 7 8 9 10 11; do echo "$((NOW-3600+i*320))" >> "$SP"; done
run_pool FLAG_BQ=1 POOL_SPAWN_CAP_PER_KEY=12 POOL_SPAWN_CAP_WINDOW_S=86400
grep -q 'skipping BH-1016: spawn cap reached' "$H/logs/fly-pool.log" && ok || bad "C2 precondition: rows-only cap not reached: $(log)"
[ "$(rowstat)" = queued ] && ok || bad "C2: rows-only, the capped row must stay queued, got '$(rowstat)'"
grep -q '"failed"' <<<"$(grep 'PATCH' "$T/req.txt")" && bad "C5: a PATCH closed the capped row failed: $(grep PATCH "$T/req.txt")" || ok
grep -q 'deferred to a human' <<<"$(cat "$T/req.txt" "$H/logs/fly-pool.log" "$H/logs/ALERTS.log")" \
  && bad "C2: something still says 'deferred to a human'" || ok
grep -q 'spawn cap' "$T/req.txt" && bad "C5: a worker request carried the spawn cap: $(grep 'spawn cap' "$T/req.txt")" || ok

echo "fly-pool-bundle-before-spawn: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
