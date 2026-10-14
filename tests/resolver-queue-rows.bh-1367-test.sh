#!/bin/bash
# tests/resolver-queue-rows.bh-1367-test.sh — BH-1026.3, the READ side: once
# nothing writes `state/build-queue/<p>/<KEY>.failed.json`, the two readers of
# a parked build have to read the ROW.
#
#   bin/blocked-resolver.sh  br_from_queue — the re-entry point for a pool
#     build that died twice. With the flag on the `*.failed.json` fallback loop
#     is gone; with the flag off, or on an OUTAGE, it runs exactly as today,
#     because a worker that is down must never make a parked ticket invisible —
#     invisible is the state this lane exists to end.
#   bin/healthcheck.sh       the parked-build count. A count that silently goes
#     to 0 reads as "nothing parked" (D12), so on an unreadable list the sidecar
#     count stands.
#
# And the third half: with the flag on, bin/fly-pool.sh's reap stops writing the
# sidecar at all, because the row it closes on the line above already carries
# the reason br_from_queue keys on.
#
# HOW IT DRIVES: br_from_queue is EXTRACTED from the real script and executed
# (the same seam tests/blocked-resolver.bh-614-test.sh uses, and the reason the
# function carries `command -v` guards); bin/fly-pool.sh and bin/healthcheck.sh
# are run whole against a scratch $HARNESS with a file-backed worker stub.
# Run from anywhere: tests/resolver-queue-rows.bh-1367-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/fly" "$H/state/fly-pool/project-5" "$H/state/pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$T/fakebin" "$T/tmproot"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/" 2>/dev/null
cp "$DIR"/bin/lib/queue-row-job.sh "$H/bin/lib/" 2>/dev/null
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf 'FLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
touch "$H/flags/builder-fly-project-5"
printf '#!/bin/bash\nexit 0\n'  > "$H/bin/beat.sh"
printf '#!/bin/bash\necho stopped\n' > "$H/bin/fly-api.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n'  > "$H/bin/fly-lock-guard.sh"
chmod +x "$H/bin"/*.sh

ROWS="$T/rows.tsv"; : > "$ROWS"
QD="$H/state/build-queue/project-5"
POOLD="$H/state/fly-pool/project-5"

printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n'           > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n'           > "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 0\n'           > "$T/fakebin/ssh"
printf '#!/bin/bash\nexit 1\n'           > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 1\n'           > "$T/fakebin/tailscale"
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$* " in
  *"ssh sftp put"*)   exit 0 ;;
  *"ssh sftp get"*)   exit 0 ;;
  *"machines list"*)  echo '[]' ;;
  *"machine run"*)    printf 'Machine ID: 1234567890abcd\n' ;;
  *"machine status"*) echo "State: ${FLY_MSTATE:-started}" ;;
  *cat*RESULT*)       echo "PR_CREATED https://github.com/o/r/pull/1" ;;
  *RESULT*)           echo "${FLY_RESULT:-no}" ;;
  *wc*)               echo 42 ;;
  *)                  exit 0 ;;
esac
exit 0
STUB

# The worker, file-backed over $ROWS. Columns:
#   1 project 2 key 3 ticket_id 4 status 5 target 6 attempt 7 reason 8 meta 9 machine
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-up}" = down ] && exit 7
qparam() { case "$URL" in *"$1"=*) V="${URL##*"$1"=}"; printf '%s' "${V%%&*}" ;; esac; }
case "$M $URL" in
  "GET "*/api/settings/*)
    K="${URL##*/}"; V=absent
    [ "$K" = build_queue_rows_only ] && V="${FLAG_BQ:-0}"
    case "$V" in
      absent) printf '{}\n404\n' ;;
      *) printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "$V" ;;
    esac ;;
  "GET "*/api/queue*)
    # `qdown` is the case the flag alone cannot produce: the settings row
    # ANSWERED (so the lane is armed) and the list that follows did not. That is
    # rc 1 from queue_list, and it must never read as "nothing parked".
    [ "${CURL_MODE:-up}" = qdown ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    P=$(qparam project); ST=$(qparam status); TG=$(qparam target)
    K=$(qparam key); LIM=$(qparam limit)
    awk -F'\t' -v p="$P" -v st="$ST" -v tg="$TG" -v k="$K" -v lim="${LIM:-0}" '
      BEGIN{printf "{\"queue\":["; n=0}
      (p==""||$1==p)&&(st==""||$4==st)&&(tg==""||$5==tg)&&(k==""||$2==k){
        if (lim+0 > 0 && n >= lim+0) next
        if (n++) printf ",";
        printf "{\"project\":\"%s\",\"ticket_key\":\"%s\",\"ticket_id\":%s,\"status\":\"%s\",\"target\":\"%s\",\"attempt\":%s,\"claimed_by\":\"hub\",\"machine\":%s,\"enqueued_at\":\"2026-09-22T00:00:00Z\",\"reason\":%s,\"meta\":%s}",
          $1, $2, ($3=="-"||$3==""?"null":"\"" $3 "\""), $4, $5,
          ($6=="-"||$6==""?0:$6),
          ($9=="-"||$9==""?"null":"\"" $9 "\""),
          ($7=="-"||$7==""?"null":"\"" $7 "\""),
          ($8=="-"||$8==""?"null":$8) }
      END{print "]}"}' "$ROWS" 2>/dev/null
    echo 200 ;;
  "POST "*/api/queue/claim)
    [ "${CURL_MODE:-up}" = lost ] && { printf '{"refused":true}\n409\n'; exit 0; }
    CP=$(printf '%s' "$BODY" | jq -r '.project // ""' 2>/dev/null)
    CK=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    CM=$(printf '%s' "$BODY" | jq -r '.machine // ""' 2>/dev/null)
    HIT=$(awk -F'\t' -v p="$CP" -v k="$CK" '$1==p && (k=="" || $2==k) && $4=="queued" {print; exit}' "$ROWS")
    [ -n "$HIT" ] || { printf '{}\n404\n'; exit 0; }
    HK=$(printf '%s' "$HIT" | cut -f2); HT=$(printf '%s' "$HIT" | cut -f3)
    HG=$(printf '%s' "$HIT" | cut -f5); HA=$(printf '%s' "$HIT" | cut -f6)
    awk -F'\t' -v OFS='\t' -v p="$CP" -v k="$HK" -v m="$CM" \
      '!d && $1==p && $2==k && $4=="queued" { $4="claimed"; if (m != "") $9=m; d=1 } {print}' \
      "$ROWS" > "$ROWS.n" && mv "$ROWS.n" "$ROWS"
    printf '{"queued":{"project":"%s","ticket_key":"%s","ticket_id":"%s","target":"%s","attempt":%s,"status":"claimed"},"claimed":true}\n200\n' \
      "$CP" "$HK" "${HT:--}" "${HG:-fly}" "${HA:-0}" ;;
  "PATCH "*/api/queue)
    CP=$(printf '%s' "$BODY" | jq -r '.project // ""' 2>/dev/null)
    CK=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    CS=$(printf '%s' "$BODY" | jq -r '.status // ""' 2>/dev/null)
    CR=$(printf '%s' "$BODY" | jq -r '.reason // "-"' 2>/dev/null | tr '\t\n' '  ')
    awk -F'\t' -v OFS='\t' -v p="$CP" -v k="$CK" -v s="$CS" -v r="$CR" \
      '$1==p && $2==k { $4=s; if (r != "" && r != "-") $7=r } {print}' \
      "$ROWS" > "$ROWS.n" && mv "$ROWS.n" "$ROWS"
    printf '{"ok":true}\n200\n' ;;
  "POST "*/api/queue)
    CP=$(printf '%s' "$BODY" | jq -r '.project // ""' 2>/dev/null)
    CK=$(printf '%s' "$BODY" | jq -r '.key // ""' 2>/dev/null)
    CT=$(printf '%s' "$BODY" | jq -r '.ticket_id // "-"' 2>/dev/null)
    CA=$(printf '%s' "$BODY" | jq -r '.attempt // 0' 2>/dev/null)
    printf '%s\t%s\t%s\tqueued\tfly\t%s\t-\t-\t-\n' "$CP" "$CK" "$CT" "$CA" >> "$ROWS"
    printf '{"queued":{"ticket_key":"%s"}}\n200\n' "$CK" ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

# ── the extracted br_from_queue, driven ─────────────────────────────────────
: > "$T/src.sh"
# EXTRACTED FROM THE CHECKOUT, never copied into the scratch tree: this suite
# drives two functions, not the lane, so it has no business installing
# bin/lib/br/*.sh beside a copy of the script (tests/br-split-layout-test.sh
# case 7 refuses a fixture that copies the lane without its modules, and it is
# right to — a half-installed lane refuses its own tick).
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
awk '/^br_rkey\(\) \{/{p=1} p{print} p&&/^}$/{exit}'      "$T/br-corpus.sh" >> "$T/src.sh"
awk '/^br_from_queue\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/src.sh"
grep -q '^br_from_queue() {' "$T/src.sh" && grep -q '^br_rkey() {' "$T/src.sh" \
  && ok || bad "precondition: br_from_queue/br_rkey did not extract — every assertion below would be vacuous"

queue() { # queue  (FLAG_BQ / CURL_MODE from the caller)
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}" \
           H="$H" ONLY=project-5
    . "$H/bin/jobs-client.sh"
    . "$T/src.sh"
    br_from_queue ) 2>/dev/null
}

# ══ 1. A `died twice` ROW IS THE PARK ═══════════════════════════════════════
printf 'project-5\tTS-1\t1\tfailed\tfly\t1\tdied 2 times (state=stopped) — parked for the blocked-resolver\t-\t-\n' > "$ROWS"
OUT=$(FLAG_BQ=1 queue)
N=$(printf '%s\n' "$OUT" | grep -c 'pool-died-twice')
[ "$N" = 1 ] \
  && ok || bad "a failed row saying 'died 2 times' must be offered exactly once as pool-died-twice, got $N: $OUT"
grep -q 'project-5-TK-1' <<<"$OUT" \
  && ok || bad "the offered tuple must name the resolver key, got: $OUT"

# ══ 2. THE SIDECAR LOOP IS GONE UNDER THE FLAG, AND ONLY UNDER IT ═══════════
: > "$ROWS"
printf '{"key":"TK-2","ticket_id":"2","attempt":2,"deaths":2}\n' > "$QD/TK-2.failed.json"
OUT=$(FLAG_BQ=1 queue)
[ -z "$(printf '%s' "$OUT" | grep 'TK-2')" ] \
  && ok || bad "with the flag on the *.failed.json fallback loop must not run, got: $OUT"
OUT=$(FLAG_BQ=0 queue)
N=$(printf '%s\n' "$OUT" | grep -c 'TK-2')
[ "$N" = 1 ] \
  && ok || bad "with the flag OFF the sidecar is still the fallback and must be offered once, got $N: $OUT"

# ══ 5. AN OUTAGE KEEPS THE SIDECAR FALLBACK ═════════════════════════════════
# rc 1 is NOT "nothing parked". A worker that blinks must not make a parked
# ticket invisible — that is the state this lane exists to end.
OUT=$(FLAG_BQ=1 CURL_MODE=down queue)
N=$(printf '%s\n' "$OUT" | grep -c 'TK-2')
[ "$N" = 1 ] \
  && ok || bad "flag on + worker DOWN must still read the sidecar, got $N line(s): $OUT"
# …and the armed-but-unreadable case, which the flag alone cannot produce: the
# settings row ANSWERED on, the list did not answer at all.
OUT=$(FLAG_BQ=1 CURL_MODE=qdown queue)
N=$(printf '%s\n' "$OUT" | grep -c 'TK-2')
[ "$N" = 1 ] \
  && ok || bad "flag on + an unreadable LIST must still read the sidecar (rc 1 is not 'nothing parked'), got $N: $OUT"
rm -f "$QD"/*.failed.json

# ══ 3. THE POOL'S REAP STOPS WRITING THE SIDECAR UNDER THE FLAG ═════════════
pool() {
  : > "$T/req.txt"; : > "$T/fly.txt"; : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" FLY_SINK="$T/fly.txt" ROWS="$ROWS" \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_project-5=tok FLY_MSTATE=stopped \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
deadmachine() {
  rm -f "$POOLD"/*.json "$QD"/*.json
  printf '{"machine":"1234567890abcd","key":"TK-1","ticket_id":"1","attempt":1,"deaths":1}\n' \
    > "$POOLD/1234567890abcd.json"
  printf 'project-5\tTS-1\t1\tclaimed\tfly\t1\t-\t-\t1234567890abcd\n' > "$ROWS"
}
deadmachine
FLAG_BQ=1 pool
[ ! -f "$QD/TK-1.failed.json" ] \
  && ok || bad "with the flag on nothing may write the .failed.json sidecar: $(cat "$QD/TK-1.failed.json" 2>/dev/null)"
[ "$(awk -F'\t' '$2=="TK-1"{print $4; exit}' "$ROWS")" = failed ] \
  && ok || bad "the row is the record and must be closed failed, got '$(awk -F'\t' '$2=="TK-1"{print $4}' "$ROWS")'"
awk -F'\t' '$2=="TK-1"{print $7}' "$ROWS" | grep -q 'died 2 times' \
  && ok || bad "the row's reason must be the one br_from_queue keys on, got: $(awk -F'\t' '$2=="TK-1"{print $7}' "$ROWS")"
# …and with the flag OFF the sidecar is still written, byte for byte as today.
deadmachine
FLAG_BQ=0 pool
[ -f "$QD/TK-1.failed.json" ] \
  && ok || bad "with the flag off the sidecar must still be written — br_from_queue's fallback reads it"
rm -f "$QD"/*.json "$POOLD"/*.json

# ══ 4. THE HEALTHCHECK'S PARKED COUNT COMES FROM THE ROWS ═══════════════════
health() {
  : > "$H/logs/ALERTS.log"; : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" ROWS="$ROWS" HEALTHCHECK_TMP_ROOT="$T/tmproot" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/healthcheck.sh" project-5 >/dev/null 2>&1 )
  grep -o 'FLY: [0-9]* \.failed build job(s) in queue' "$H/logs/ALERTS.log" 2>/dev/null | head -1
}
{ printf 'project-5\tTS-3\t3\tfailed\tfly\t2\tdied 2 times (state=stopped)\t-\t-\n'
  printf 'project-5\tTS-4\t4\tfailed\tfly\t2\tdeferred 6 times (REFUSED)\t-\t-\n'
  printf 'project-5\tTS-5\t5\tdone\tfly\t0\t-\t-\t-\n'; } > "$ROWS"
rm -f "$QD"/*.failed.json
[ "$(FLAG_BQ=1 health)" = "FLY: 2 .failed build job(s) in queue" ] \
  && ok || bad "flag on: the parked count must be the PARKED rows, got '$(FLAG_BQ=1 health)'"
# …and ONLY those. `failed` is the terminal status for every way a fly build can
# end badly, and terminal rows are never pruned — counting all of them pages a
# number that can only grow and never returns to 0, which is the same lie as a
# silent 0 wearing the other sign. The reason test is br_from_queue's park
# trigger, because these are the rows the resolver will actually re-enter.
{ printf 'project-5\tTS-6\t6\tfailed\tfly\t1\topen PR already exists — nothing to build\t-\t-\n'
  printf 'project-5\tTS-7\t7\tfailed\tfly\t1\tABANDONED by the blocked-resolver\t-\t-\n'
  printf 'project-5\tTS-8\t8\tfailed\tfly\t0\tspawn cap reached for this key\t-\t-\n'; } >> "$ROWS"
[ "$(FLAG_BQ=1 health)" = "FLY: 2 .failed build job(s) in queue" ] \
  && ok || bad "a terminal row that is not a PARK must not be counted, got '$(FLAG_BQ=1 health)'"
# The same rows with no park among them at all must page nothing, not "5".
{ printf 'project-5\tTS-6\t6\tfailed\tfly\t1\topen PR already exists — nothing to build\t-\t-\n'
  printf 'project-5\tTS-7\t7\tfailed\tfly\t1\tABANDONED by the blocked-resolver\t-\t-\n'; } > "$ROWS"
[ -z "$(FLAG_BQ=1 health)" ] \
  && ok || bad "with no parked row the alert must not fire at all, got '$(FLAG_BQ=1 health)'"
{ printf 'project-5\tTS-3\t3\tfailed\tfly\t2\tdied 2 times (state=stopped)\t-\t-\n'
  printf 'project-5\tTS-4\t4\tfailed\tfly\t2\tdeferred 6 times (REFUSED)\t-\t-\n'; } > "$ROWS"
# A count that silently goes to 0 reads as 'nothing parked' (D12): on an
# unreadable list the sidecar count stands.
printf '{"key":"TK-9","ticket_id":"9"}\n' > "$QD/TK-9.failed.json"
[ "$(FLAG_BQ=1 CURL_MODE=down health)" = "FLY: 1 .failed build job(s) in queue" ] \
  && ok || bad "flag on + worker DOWN must keep the sidecar count, never 0, got '$(FLAG_BQ=1 CURL_MODE=down health)'"
[ "$(FLAG_BQ=0 health)" = "FLY: 1 .failed build job(s) in queue" ] \
  && ok || bad "flag off must count the sidecars exactly as today, got '$(FLAG_BQ=0 health)'"
# The armed-but-unreadable case: the flag row answered ON and the LIST did not.
[ "$(FLAG_BQ=1 CURL_MODE=qdown health)" = "FLY: 1 .failed build job(s) in queue" ] \
  && ok || bad "flag on + an unreadable LIST must keep the sidecar count, never 0, got '$(FLAG_BQ=1 CURL_MODE=qdown health)'"
rm -f "$QD"/*.failed.json

echo "resolver-queue-rows.bh-1367-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
