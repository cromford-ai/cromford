#!/bin/bash
# tests/build-queue-rows-only.bh-1367-test.sh — BH-1026.3: with
# `build_queue_rows_only` armed, the `build_queue` ROW is the only source of
# "what is queued" and "what is claimed" for the fly lane. No ssh `ls`, no
# `scp`, no `rm -f` over ssh, and no state/build-queue/<p>/<KEY>.json written
# from a row.
#
# WHY DRIVEN AND NOT GREPPED. Every claim in this slice is about what does NOT
# happen — a second claim, a second machine, a file that is not written, an ssh
# hop that is not taken — and none of those is visible in a grep of the source.
# So `bash bin/fly-dispatch.sh`, `bash bin/fly-pool.sh <p>` and
# `bash bin/fly-results-ingest.sh <p>` are RUN, with curl/ssh/scp/fly/flock/
# timeout/sleep/tailscale stubbed onto $PATH and recording into sinks, and the
# assertions are about the sinks, the rows the stub worker really holds, the
# files on disk and the lines in the lane logs.
#
# THE WORKER IS FILE-BACKED. $T/rows.tsv is the `build_queue` table:
#   1 project  2 ticket_key  3 ticket_id  4 status  5 target
#   6 attempt  7 reason      8 meta(JSON) 9 machine
# `POST /api/queue/claim` really compare-and-swaps a `queued` row to `claimed`
# (and answers 409 under CURL_MODE=lost), `PATCH /api/queue` really moves the
# row, and `GET /api/queue` filters on project/status/target/key/limit — a stub
# that ignored those would make the double-claim assertions pass vacuously.
#
# Run from anywhere: tests/build-queue-rows-only.bh-1367-test.sh (exit 0 = pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/rt" "$H/logs" "$H/flags" "$H/locks" \
         "$H/builds" "$H/env" "$H/prompts" "$H/state/fly" \
         "$H/state/fly-pool/project-3" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-3" "$H/state/build-queue/project-5" \
         "$H/state/pool/project-5" "$H/state/remote-results/project-3" \
         "$T/fakebin" "$T/boxq"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/" 2>/dev/null
# The lane reads the row→job mapping out of this lib; the scratch tree runs the
# CHECKOUT's scripts, so it must find the lib beside the checkout OR here.
cp "$DIR"/bin/lib/queue-row-job.sh "$H/bin/lib/" 2>/dev/null

# THE PROJECT IS A REAL ONE, deliberately: bin/fly-dispatch.sh's ssh drain only
# runs for a project the registry can address, and a made-up name would make
# every "no ssh happened" assertion pass by never reaching the hop.
cp "$DIR/fleet.conf" "$H/fleet.conf"
printf 'FLY_API_TOKEN_PROJECT_3_OS=tok\nFLY_API_TOKEN_project-5=tok\n' > "$H/env/fly.env"
: > "$H/env/global.env"
touch "$H/flags/builder-fly-project-3"
printf '{"app":"builder-project-3","machine_id":"aa11bb22cc33dd"}\n' > "$H/state/fly/project-3.json"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"

ROWS="$T/rows.tsv"; : > "$ROWS"
ACTIVE="$H/state/fly/project-3-active.json"
QD="$H/state/build-queue/project-3"
POOLD="$H/state/fly-pool/project-5"
BOXQ="$T/boxq"

# ── hub scripts the lanes shell out to ──────────────────────────────────────
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/fly-lock-guard.sh"
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/fly-sync-harness.sh"
printf '#!/bin/bash\necho started\n'                             > "$H/bin/fly-api.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\necho OK\nexit 0\n'                          > "$H/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/overlap-guard.sh"
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/fly-results-ingest.sh"
printf '#!/bin/bash\nexit 0\n'                                   > "$H/bin/project-of.sh"
chmod +x "$H/bin"/*.sh

# ── stubs that RECORD and EMULATE ───────────────────────────────────────────
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
echo "ssh $*" >> "$SSH_SINK"
CMD="${!#}"
case "$CMD" in
  "ls "*)    ls "${BOXQ:-/nonexistent}" 2>/dev/null ;;
  *"rm -f"*) rm -f "${BOXQ:-/nonexistent}/${CMD##*/}" ;;
esac
exit 0
STUB
cat > "$T/fakebin/scp" <<'STUB'
#!/bin/bash
echo "scp $*" >> "$SSH_SINK"
SRC=""; DST=""
for a in "$@"; do
  case "$a" in -*) ;; *:*) SRC="${a#*:}" ;; *) DST="$a" ;; esac
done
[ -n "$SRC" ] && [ -n "$DST" ] && cp "${BOXQ:-/nonexistent}/$(basename "$SRC")" "$DST" 2>/dev/null
exit 0
STUB
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n'           > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 1\n'           > "$T/fakebin/tailscale"
printf '#!/bin/bash\nexit 0\n'           > "$T/fakebin/sleep"
printf '#!/bin/bash\nexit 1\n'           > "$T/fakebin/gh"

# The fly stub records every invocation and answers the four console shapes the
# dispatcher's push_file needs (RESULT probe, size probe, mv, sftp put) plus the
# pool's machine run / machines list.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
echo "fly $*" >> "${FLY_SINK:-/dev/null}"
case "$* " in
  *"ssh sftp put"*)  exit 0 ;;
  *"ssh sftp get"*)  exit 0 ;;
  *"machines list"*) echo '[]' ;;
  # FLY_NOMID=1 is the real shape of a failed spawn: flyctl exits 0 having
  # printed no "Machine ID:" line, so the pool gets an empty $MID.
  *"machine run"*)   [ "${FLY_NOMID:-0}" = 1 ] || printf 'Machine ID: 1234567890abcd\n' ;;
  *"machine status"*) echo "State: started" ;;
  *cat*RESULT*)      echo "PR_CREATED https://github.com/o/r/pull/1" ;;
  *RESULT*)          echo "${FLY_RESULT:-no}" ;;
  *wc*)              echo 42 ;;
  *)                 exit 0 ;;
esac
exit 0
STUB

# The worker, file-backed over $ROWS. Claims really CAS; PATCH really moves the
# row; GET really filters.
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
    [ "${CURL_MODE:-up}" = lost ] && { printf '{"refused":true,"reason":"taken"}\n409\n'; exit 0; }
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
    CG=$(printf '%s' "$BODY" | jq -r '.target // "fly"' 2>/dev/null)
    CA=$(printf '%s' "$BODY" | jq -r '.attempt // 0' 2>/dev/null)
    CE=$(printf '%s' "$BODY" | jq -r '.meta // "-"' 2>/dev/null | tr '\t\n' '  ')
    printf '%s\t%s\t%s\tqueued\t%s\t%s\t-\t%s\t-\n' "$CP" "$CK" "$CT" "$CG" "$CA" "$CE" >> "$ROWS"
    printf '{"queued":{"ticket_key":"%s"}}\n200\n' "$CK" ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin"/*

# ── drivers ─────────────────────────────────────────────────────────────────
dispatch() { # dispatch  (knobs FLAG_BQ / CURL_MODE come from the caller)
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"
  : > "$H/logs/fly-dispatch.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           ROWS="$ROWS" BOXQ="$BOXQ" FLEET_CONF="$H/fleet.conf" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/fly-dispatch.sh" >/dev/null 2>&1 )
}
pool() { # pool  — one fly-pool tick for project-5
  : > "$T/req.txt"; : > "$T/fly.txt"; : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" FLY_SINK="$T/fly.txt" ROWS="$ROWS" \
           FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_PROJECT_5=tok FLY_NOMID="${FLY_NOMID:-0}" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
claims() { awk '/\/api\/queue\/claim/{n++} END{print n+0}' "$T/req.txt"; }
pushes() { awk '/ssh sftp put/ && /job.json/{n++} END{print n+0}' "$T/fly.txt"; }
rowstat() { awk -F'\t' -v p="$1" -v k="$2" '$1==p && $2==k {print $4; exit}' "$ROWS"; }
reset()  { : > "$ROWS"; rm -f "$ACTIVE" "$QD"/*.json "$POOLD"/*.json "$BOXQ"/*.json
           rm -f "$H/logs/ALERTS.log"; }

# The registry must answer, or every drain assertion below is vacuous.
TNIP=$(FLEET_CONF="$H/fleet.conf" "$DIR/bin/fleet-conf.sh" --tailnet-ip project-3 2>/dev/null)
[ -n "$TNIP" ] \
  && ok || bad "precondition: project-3 must resolve to a tailnet_ip — without it every ssh assertion here is vacuous"

# ══ 1. A QUEUED ROW IS CLAIMED AND DISPATCHED ONCE ══════════════════════════
reset
printf 'project-3\tFR-109\t109\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
FLAG_BQ=1 dispatch
[ "$(claims)" = 1 ] \
  && ok || bad "a queued row must be claimed exactly once, got $(claims) claim(s): $(grep -c . "$T/req.txt") request(s)"
grep -q '"key":"TK-109"' "$T/req.txt" \
  && ok || bad "the claim must name the key it is dispatching: $(grep claim "$T/req.txt")"
[ "$(jq -r '.key // ""' "$ACTIVE" 2>/dev/null)" = TK-109 ] \
  && ok || bad "<p>-active.json is still the write-through cache and must name the dispatched key, got: $(cat "$ACTIVE" 2>/dev/null)"
[ "$(pushes)" = 1 ] \
  && ok || bad "the job must be pushed to the builder exactly once, got $(pushes): $(cat "$T/fly.txt")"
[ ! -f "$QD/TK-109.json" ] \
  && ok || bad "NO state/build-queue/<p>/<KEY>.json may be written from a row under the flag: $(cat "$QD/TK-109.json" 2>/dev/null)"
[ "$(rowstat project-3 TK-109)" = claimed ] \
  && ok || bad "the row must be CLAIMED after dispatch, got '$(rowstat project-3 TK-109)'"
# A second tick makes no second claim — the claimed row and the cache both say so.
FLAG_BQ=1 dispatch
[ "$(claims)" = 0 ] \
  && ok || bad "a second tick must not re-claim a key already dispatched, got $(claims)"
[ "$(pushes)" = 0 ] \
  && ok || bad "a second tick must not push the same job again, got $(pushes)"

# ══ 2. NO ssh, NO scp, NO rm -f OVER ssh WITH THE FLAG ON ═══════════════════
reset
printf '{"key":"TK-109","ticket_id":"109","attempt":0}\n' > "$QD/TK-109.json"
FLAG_BQ=1 dispatch
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "with the flag on the dispatcher must take no ssh/scp hop at all: $(cat "$T/ssh.txt")"
[ "$(claims)" = 0 ] \
  && ok || bad "a hub-local FILE is never a row and must never be claimed, got $(claims)"
[ "$(pushes)" = 0 ] \
  && ok || bad "a hub-local file must never be launched from under the flag, got $(pushes)"
[ -f "$QD/TK-109.json" ] \
  && ok || bad "a file whose key has NO row is not custody — it must be left exactly where it is"

# ══ 3. FLAG OFF IS TODAY, BYTE FOR BYTE ═════════════════════════════════════
printf '{"key":"TK-109","ticket_id":"109","attempt":0}\n' > "$BOXQ/TK-109.json"
FLAG_BQ=0 dispatch
grep -q '^ssh .*ls ' "$T/ssh.txt" \
  && ok || bad "with the flag OFF the ssh drain must still list the owning box: $(cat "$T/ssh.txt")"
grep -q '^ssh .*rm -f' "$T/ssh.txt" \
  && ok || bad "with the flag OFF the drain must still rm the box's copy: $(cat "$T/ssh.txt")"

# ══ 4. A REFUSED CLAIM (409) SPAWNS AND PUSHES NOTHING ══════════════════════
reset
printf 'project-3\tFR-109\t109\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
FLAG_BQ=1 CURL_MODE=lost dispatch
[ "$(pushes)" = 0 ] \
  && ok || bad "a refused claim must push nothing, got $(pushes)"
[ ! -f "$ACTIVE" ] \
  && ok || bad "a refused claim must leave no active cache behind — that is the double build"
grep -q 'refused' "$H/logs/fly-dispatch.log" \
  && ok || bad "a refused claim must say so in one line: $(cat "$H/logs/fly-dispatch.log")"

# ══ 5. AN OUTAGE BEHAVES EXACTLY AS FLAG-OFF ════════════════════════════════
reset
printf '{"key":"TK-50","ticket_id":"50","attempt":0}\n' > "$BOXQ/TK-50.json"
FLAG_BQ=1 CURL_MODE=down dispatch
# The env bundle's mktemp name is the only thing that legitimately differs
# between two runs of the same path; everything else must be identical.
sed 's#/dev/shm/flyenv\.[A-Za-z0-9]*#/dev/shm/flyenv.X#g' "$T/ssh.txt" > "$T/ssh-down.txt"
# The two runs start from the same state or the comparison is about the state,
# not about the flag: the first one dispatched, and an active job left behind
# would make the second tick take the "still building" arm.
reset
printf '{"key":"TK-50","ticket_id":"50","attempt":0}\n' > "$BOXQ/TK-50.json"
FLAG_BQ=0 CURL_MODE=down dispatch
sed 's#/dev/shm/flyenv\.[A-Za-z0-9]*#/dev/shm/flyenv.X#g' "$T/ssh.txt" > "$T/ssh-off.txt"
diff -q "$T/ssh-down.txt" "$T/ssh-off.txt" >/dev/null \
  && ok || bad "flag on + worker DOWN must take exactly the flag-off hops: $(diff "$T/ssh-down.txt" "$T/ssh-off.txt")"
rm -f "$BOXQ"/*.json "$QD"/*.json

# ══ 6. AN UNUSABLE REBASE META IS REFUSED, NOT DISPATCHED ═══════════════════
reset
printf 'project-3\tRB-7-abc\t7\tqueued\tfly\t0\t-\t{"kind":"rebase","slug":"o/r","url":"https://x","pr":"7","branch":"bad branch","head":"h","base":"main"}\t-\n' > "$ROWS"
FLAG_BQ=1 dispatch
[ "$(rowstat project-3 RB-7-abc)" = failed ] \
  && ok || bad "a row whose rebase meta is unusable must be closed FAILED, got '$(rowstat project-3 RB-7-abc)'"
[ "$(claims)" = 0 ] \
  && ok || bad "a refused rebase row must never be claimed, got $(claims)"
[ "$(pushes)" = 0 ] \
  && ok || bad "a refused rebase row must never be dispatched, got $(pushes)"
N=$(grep -c "rebase meta is unusable" "$H/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] \
  && ok || bad "exactly ONE ALERTS line names the refusal, got $N"
[ ! -f "$QD/RB-7-abc.json" ] \
  && ok || bad "no queue file may be written for a refused rebase row"

# ══ 7. A CLAIMED ROW IS IN FLIGHT EVEN WITH THE CACHE DELETED ═══════════════
# The TK-70 shape: the active file is gone, the row still says a build is
# running, and a second dispatch would be a second machine on the same key.
reset
printf 'project-3\tFR-109\t109\tclaimed\tfly\t0\t-\t-\taa11bb22cc33dd\n'  > "$ROWS"
printf 'project-3\tFR-110\t110\tqueued\tfly\t0\t-\t-\t-\n'               >> "$ROWS"
FLAG_BQ=1 dispatch
[ "$(claims)" = 0 ] \
  && ok || bad "with a claimed row in flight no second key may be claimed, got $(claims)"
[ "$(pushes)" = 0 ] \
  && ok || bad "with a claimed row in flight nothing may be pushed, got $(pushes)"
grep -q "wip of" "$H/logs/fly-dispatch.log" \
  && ok || bad "the in-flight refusal must say so: $(cat "$H/logs/fly-dispatch.log")"

# ══ 8. meta.deferrals SURVIVES THE DISPATCH ═════════════════════════════════
reset
printf 'project-3\tFR-111\t111\tqueued\tfly\t2\t-\t{"deferrals":3}\t-\n' > "$ROWS"
FLAG_BQ=1 dispatch
[ "$(jq -r '.deferrals // "absent"' "$ACTIVE" 2>/dev/null)" = 3 ] \
  && ok || bad "the stand-down count must ride the row into job.json, got: $(cat "$ACTIVE" 2>/dev/null)"
[ "$(jq -r '.attempt // "absent"' "$ACTIVE" 2>/dev/null)" = 2 ] \
  && ok || bad "the attempt count must survive, or a requeued build looks brand new: $(cat "$ACTIVE" 2>/dev/null)"
[ "$(jq -r '.ticket_id // "absent"' "$ACTIVE" 2>/dev/null)" = 111 ] \
  && ok || bad "the ticket id must survive — the launch needs it: $(cat "$ACTIVE" 2>/dev/null)"

# ══ 9a. A KEY ALREADY LIVE IN THE POOL IS NOT CLAIMED ═══════════════════════
reset
printf 'project-3\tFR-109\t109\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
printf '{"machine":"m1","key":"TK-109"}\n' > "$H/state/fly-pool/project-3/m1.json"
FLAG_BQ=1 dispatch
[ "$(claims)" = 0 ] \
  && ok || bad "a key already live on a pool machine must not be claimed again (TK-70), got $(claims)"
[ "$(pushes)" = 0 ] \
  && ok || bad "a key already live on a pool machine must not be dispatched again, got $(pushes)"
rm -f "$H/state/fly-pool/project-3/m1.json"

# ══ 9b. CUSTODY IS A CLOSED LIST ════════════════════════════════════════════
# claimed = this hub owns the launch, so the leftover file goes. ready, dropped
# and "no row at all" are NOT custody: those files are a producer's outage
# fallback and deleting one loses a build whose only record says it is safe.
reset
for K in TK-1 TK-2 TK-3 TK-4; do
  printf '{"key":"%s","ticket_id":"1","attempt":0}\n' "$K" > "$QD/$K.json"
done
{ printf 'project-3\tFR-1\t1\tclaimed\tfly\t0\t-\t-\t-\n'
  printf 'project-3\tFR-2\t2\tready\tlocal\t0\t-\t-\t-\n'
  printf 'project-3\tFR-3\t3\tdropped\tlocal\t0\t-\t-\t-\n'; } > "$ROWS"
FLAG_BQ=1 dispatch
[ ! -f "$QD/TK-1.json" ] \
  && ok || bad "a leftover file whose row is CLAIMED must be removed — its build is already in flight"
[ -f "$QD/TK-2.json" ] \
  && ok || bad "a READY row is not custody: the file must be left alone"
[ -f "$QD/TK-3.json" ] \
  && ok || bad "a DROPPED row is not custody: the file must be left alone"
[ -f "$QD/TK-4.json" ] \
  && ok || bad "a file with NO row at all is real work: it must be left alone"
[ ! -s "$T/ssh.txt" ] \
  && ok || bad "the custody sweep is hub-local: no ssh, no scp, no rm over ssh: $(cat "$T/ssh.txt")"
rm -f "$QD"/*.json

# ══ 10. THE POOL TAKES ITS QUEUE FROM THE ROWS ══════════════════════════════
reset
printf 'project-5\tTS-1\t1\tqueued\tfly\t0\t-\t{"deferrals":2}\t-\n' > "$ROWS"
FLAG_BQ=1 pool
N=$(ls "$POOLD"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 1 ] \
  && ok || bad "a queued ROW alone must spawn exactly one pool machine, got $N: $(cat "$H/logs/fly-pool.log")"
[ "$(jq -r '.key // ""' "$POOLD"/*.json 2>/dev/null)" = TK-1 ] \
  && ok || bad "the machine json must name the row's key: $(cat "$POOLD"/*.json 2>/dev/null)"
[ "$(jq -r '.deferrals // "absent"' "$POOLD"/*.json 2>/dev/null)" = 2 ] \
  && ok || bad "meta.deferrals must ride the row onto the machine, got: $(cat "$POOLD"/*.json 2>/dev/null)"
[ -z "$(ls "$H/state/build-queue/project-5"/*.json 2>/dev/null)" ] \
  && ok || bad "the pool must write no state/build-queue file from a row: $(ls "$H/state/build-queue/project-5")"
[ "$(rowstat project-5 TK-1)" = claimed ] \
  && ok || bad "the pool's claim is the hand-off and must land, got '$(rowstat project-5 TK-1)'"

# ══ 11. A REFUSED CLAIM SPAWNS NO MACHINE ═══════════════════════════════════
reset
printf 'project-5\tTS-2\t2\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
FLAG_BQ=1 CURL_MODE=lost pool
N=$(ls "$POOLD"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 0 ] \
  && ok || bad "a 409 must spawn NOTHING — the claim happens before the machine run (got $N machines)"
grep -q 'machine run' "$T/fly.txt" \
  && bad "a refused claim must not reach \`fly machine run\` at all: $(cat "$T/fly.txt")" || ok
grep -qi 'refused' "$H/logs/fly-pool.log" \
  && ok || bad "a refused claim logs one line: $(cat "$H/logs/fly-pool.log")"

# ══ 11b. A SPAWN THAT FAILS AFTER THE CLAIM HANDS THE ROW BACK ══════════════
# The claim is won BEFORE `fly machine run`, so every failure from there down
# owns a row nothing is building. Under the flag there is no $QDIR file left to
# re-offer it, so a claim left standing is a key in flight for the six hours of
# bin/jobs-watchdog.sh's stale-claim sweep — invisible to the queue count and to
# the pool's own budget. flyctl printing no "Machine ID:" line is the real shape.
reset
printf 'project-5\tTS-4\t4\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
FLAG_BQ=1 FLY_NOMID=1 pool
[ "$(rowstat project-5 TK-4)" = queued ] \
  && ok || bad "a spawn that failed after the claim must put the row back to queued, got '$(rowstat project-5 TK-4)': $(cat "$H/logs/fly-pool.log")"
grep -q 'PATCH https://jobs.invalid/api/queue ' "$T/req.txt" \
  && ok || bad "the hand-back must be a real PATCH on the row: $(cat "$T/req.txt")"
N=$(ls "$POOLD"/*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = 0 ] \
  && ok || bad "a spawn with no machine id must leave no machine json behind, got $N"
# …and the claim really was taken first, or this case proves nothing.
[ "$(claims)" = 1 ] \
  && ok || bad "the spawn path must still claim before the machine run, got $(claims) claim(s)"

# ══ 12. THE REUSE HANDOFF CLAIMS WITH ITS MACHINE ID ════════════════════════
# next_job_or_destroy is extracted and driven alone — the same seam
# tests/pool-account-routing-test.sh uses, and the reason the function carries
# `command -v` guards. Driving it is what proves the claim happens BEFORE the
# push and carries the machine the job is about to land on.
awk '/^next_job_or_destroy\(\) \{/,/^\}$/' "$DIR/bin/fly-pool.sh" > "$T/njod.sh"
[ -s "$T/njod.sh" ] && grep -q 'queue_claim' "$T/njod.sh" \
  && ok || bad "next_job_or_destroy did not extract, or lost its queue_claim — every assertion below would be vacuous"
reset
RQ="$T/rq"; mkdir -p "$RQ"
printf '{"key":"TK-9","ticket_id":"9","attempt":0}\n' > "$RQ/TK-9.json"
: > "$T/req.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
         REQ_SINK="$T/req.txt" ROWS="$ROWS" FLAG_BQ=1 CURL_MODE=up
  . "$H/bin/jobs-client.sh"
  P=project-5; QDIR="$RQ"; POOL="$POOLD"; MID=1234567890abcd; MSTATE=started
  KEY=TK-0; MF="$T/mf.json"; LOG="$H/logs/fly-pool.log"; ROWS_ONLY=1
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  say() { echo "$*" >> "$LOG"; }
  mexec() { return 0; }
  mput()  { return 0; }
  . "$T/njod.sh"
  next_job_or_destroy ) >/dev/null 2>&1
B=$(grep -m1 'POST .*/api/queue/claim' "$T/req.txt" | awk '{ $1=""; $2=""; sub(/^ +/,""); print }')
[ "$(printf '%s' "$B" | jq -r '.machine // "absent"' 2>/dev/null)" = 1234567890abcd ] \
  && ok || bad "the reuse claim must name the machine the job is about to run on, got: $B"
[ "$(printf '%s' "$B" | jq -r '.key // "absent"' 2>/dev/null)" = TK-9 ] \
  && ok || bad "the reuse claim must name the key it is handing over, got: $B"

# ══ 12b. A REUSE PUSH THAT FAILS AFTER THE CLAIM HANDS THE ROW BACK ═════════
# Same seam as 11b, one path over: the say line here has always read "job stays
# queued", and under the flag that sentence is only true if the row goes back —
# $NJ lives in the tick's scratch directory and vanishes with it.
reset
printf 'project-5\tTS-9\t9\tqueued\tfly\t0\t-\t-\t-\n' > "$ROWS"
printf '{"key":"TK-9","ticket_id":"9","attempt":0}\n' > "$RQ/TK-9.json"
: > "$T/req.txt"
( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
         JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
         REQ_SINK="$T/req.txt" ROWS="$ROWS" FLAG_BQ=1 CURL_MODE=up
  . "$H/bin/jobs-client.sh"
  P=project-5; QDIR="$RQ"; POOL="$POOLD"; MID=1234567890abcd; MSTATE=started
  KEY=TK-0; MF="$T/mf.json"; LOG="$H/logs/fly-pool.log"; ROWS_ONLY=1
  STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
  say() { echo "$*" >> "$LOG"; }
  mexec() { return 0; }
  mput()  { return 1; }
  . "$T/njod.sh"
  next_job_or_destroy ) >/dev/null 2>&1
[ "$(rowstat project-5 TK-9)" = queued ] \
  && ok || bad "a reuse push that failed after the claim must put the row back to queued, got '$(rowstat project-5 TK-9)'"
grep -q '"status":"queued"' "$T/req.txt" \
  && ok || bad "the hand-back must be a real PATCH back to queued: $(cat "$T/req.txt")"

# ══ 13. THE INGEST READS AND CLEARS THE CLAIM THROUGH THE ROW ═══════════════
reset
rm -f "$ACTIVE"
printf 'project-3\tFR-109\t109\tclaimed\tfly\t0\t-\t-\taa11bb22cc33dd\n' > "$ROWS"
ingest() {
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           ROWS="$ROWS" FLEET_CONF="$H/fleet.conf" FLY_RESULT=yes \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/fly-results-ingest.sh" project-3 >/dev/null 2>&1 )
}
FLAG_BQ=1 ingest
[ "$(rowstat project-3 TK-109)" = done ] \
  && ok || bad "with no active file, the claimed ROW is what the ingest reads and clears, got '$(rowstat project-3 TK-109)'"
grep -q 'PATCH https://jobs.invalid/api/queue ' "$T/req.txt" \
  && ok || bad "the clear must be a PATCH on the row: $(cat "$T/req.txt")"
# FLAG OFF: no active file means there is nothing to ingest, exactly as today.
printf 'project-3\tFR-109\t109\tclaimed\tfly\t0\t-\t-\taa11bb22cc33dd\n' > "$ROWS"
FLAG_BQ=0 ingest
[ "$(rowstat project-3 TK-109)" = claimed ] \
  && ok || bad "with the flag off an absent active file is still 'nothing to ingest', got '$(rowstat project-3 TK-109)'"

# ══ 13b. THE WIDENED SWEEP STILL SKIPS A POOL PROJECT ═══════════════════════
# Under the flag the sweep can no longer key off `<p>-active.json`, so it offers
# every provisioned project — and a POOL project has both a state/fly/<p>.json
# and claimed rows (the pool claims them), which would put an `fly ssh console`
# against the single-machine BUILDER app on every pool project every two
# minutes. Worse, a leftover RESULT there would be staged under the pool's key
# and close the pool's claimed row `done` against another build's result.
# bin/fly-dispatch.sh's dispatch_project stands down on the same flag.
sweep() {
  : > "$T/req.txt"; : > "$T/ssh.txt"; : > "$T/fly.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 JOBS_TIMEOUT=5 \
           REQ_SINK="$T/req.txt" SSH_SINK="$T/ssh.txt" FLY_SINK="$T/fly.txt" \
           ROWS="$ROWS" FLEET_CONF="$H/fleet.conf" FLY_RESULT=yes \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}"
    bash "$DIR/bin/fly-results-ingest.sh" sweep >/dev/null 2>&1 )
}
reset
rm -f "$ACTIVE"
printf 'project-5\tTS-5\t5\tclaimed\tfly\t0\t-\t-\t1234567890abcd\n' > "$ROWS"
[ -f "$H/flags/fly-pool-project-5" ] \
  && ok || bad "precondition: project-5 must be pool-flagged or this case is vacuous"
FLAG_BQ=1 sweep
grep -q 'pool-project-5' "$T/fly.txt" \
  && bad "the sweep must not reach a pool project's builder app: $(cat "$T/fly.txt")" || ok
[ "$(rowstat project-5 TK-5)" = claimed ] \
  && ok || bad "a pool project's claimed row is the POOL's, and the sweep must not close it, got '$(rowstat project-5 TK-5)'"

echo "build-queue-rows-only.bh-1367-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
