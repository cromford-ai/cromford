#!/bin/bash
# contract-test: C1 pins the exact JSON body jw_cg_note sends to
# POST /api/lifecycle/note; worker/jobs/test/lifecycle-note.bh-9160.test.js N7
# posts the same body shape to the route.
# tests/jobs-watchdog-cg-terminal.bh-9160-test.sh — BH-9160 (comment 6502199389
# on #8734, the operator, 2026-10-29): bin/jobs-watchdog.sh does not re-queue an RR or
# LR row whose last outcome is `AGENT_CALL_REFUSED call-guard repeat` on its
# head, and writes ONE ticket_events row (POST /api/lifecycle/note) that names
# the verdict already on that head. Driven through the REAL watchdog, jobs
# client and bin/lib/verdicts.sh, with a stub `curl` on PATH. 0 network.
#
#   C1  an RR call-guard row (case a): no POST /api/queue; one note with actor
#       watchdog, the key and pr, naming the standing verdict word and row id;
#       no QUEUE DEFERRAL REQUEUED line for it
#   C2  a second tick writes no second note and still re-queues nothing
#   C3  LR (b), ledger-paid (c) and fingerprint-only (d) rows are held too
#   C4  old path: e-i are re-queued as on main; k (parked) is skipped
#   C5  j (fp head does not match the key's head8) takes the old path
#   C6  a note the worker refuses: not re-queued, no latch; the next tick writes it
#   C7  verdicts unreadable: no note, no re-queue; no standing row: the box
#       word; neither: "no verdict recorded on this head"
#   C8  the scan line counts the held rows, and a refused note is not counted
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/jobs-watchdog-cg-terminal.bh-9160-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
mkdir -p "$T/logs" "$T/locks" "$T/state" "$T/env" "$T/fakebin"
{ ( cd "$DIR" && scratch_install_closure bin/jobs-watchdog.sh "$T" \
    && scratch_install_closure bin/jobs-client.sh "$T" \
    && scratch_install_closure bin/lib/verdicts.sh "$T" \
    && scratch_install_closure bin/lib/jobs/lifecycle.sh "$T" ); } >/dev/null \
  || { echo "FAIL: closure of bin/jobs-watchdog.sh"; exit 1; }
for f in bin/jobs-client.sh bin/lib/jobs/lifecycle.sh bin/lib/verdicts.sh; do
  [ -f "$T/$f" ] || { echo "FAIL: the closure has no $f"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/lane-alert.sh"; chmod +x "$T/bin/lane-alert.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/jobs\?status=running*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue\?status=claimed*) printf '{"queue":[]}\n200\n' ;;
  */api/queue\?status=done*)    cat "${QUEUE_DONE_JSON:-/dev/null}"; printf '\n200\n' ;;
  */api/queue\?status=failed*)  printf '{"queue":[]}\n200\n' ;;
  */api/queue)                  printf '{"queued":{"status":"queued"},"duplicate":false}\n201\n' ;;
  */api/verdicts\?*standing_only=1*)
    case "${VD_MODE:-lead}" in
      lead) printf '{"standing":{"verdict":"BLOCK","source":"lead","id":7,"created_at":"2026-11-06T10:00:00Z"}}\n200\n' ;;
      none|nobox) printf '{"standing":null}\n200\n' ;;
      down) printf '{"error":"bad"}\n400\n' ;;
    esac ;;
  */api/verdicts\?*)
    if [ "${VD_MODE:-lead}" = nobox ]; then printf '{"rows":[]}\n200\n'; else
      H=$(printf '%s' "$URL" | sed 's/.*head=\([0-9a-f]*\).*/\1/')
      printf '{"rows":[{"source":"box","verdict":"MERGE-WITH-NOTES","head_sha":"%s"}]}\n200\n' "$H"
    fi ;;
  */api/lifecycle/note)
    if [ "${NOTE_MODE:-ok}" = ok ]; then printf '{"ok":true,"duplicate":false,"event_id":1}\n200\n'
    else printf '{"error":"reason"}\n400\n'; fi ;;
  *) printf '{}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

H1=f44d3cf5aaaabbbbccccddddeeeeffff00001111
H2=e8f497e3aaaabbbbccccddddeeeeffff00002222
H3=25e98935aaaabbbbccccddddeeeeffff00003333
H4=3247abcdaaaabbbbccccddddeeeeffff00004444
HJ=99999999aaaabbbbccccddddeeeeffff00005555
CG="REREVIEW_DEFERRED AGENT_CALL_REFUSED call-guard repeat review-head paid=1/1"
RRA="RR-3191-${H1:0:8}"; LRB="LR-3212-${H2:0:8}"; RRC="RR-3247-${H4:0:8}"; RRD="RR-2985-${H3:0:8}"
RRJ="RR-3236-abcdef01"
DEFMETA='{"deferrals":0}'
row() { # row <key> <reason> [meta-json-string]
  jq -nc --arg k "$1" --arg r "$2" --arg m "${3:-$DEFMETA}" \
    '{project:"project-6-os",ticket_key:$k,status:"done",target:"fly",attempt:0,reason:$r,meta:$m}'
}
{
  echo '{"queue":['
  row "$RRA" "$CG fp=review:example-org/project-6#3191@$H1" \
    "$(jq -nc --arg h "$H1" '{kind:"rereview",rereview:{slug:"example-org/project-6",pr:3191,head:$h,reviewed:"-",reason:"noverdict"}}')"; echo ,
  row "$LRB" "AGENT_CALL_REFUSED call-guard repeat lead-head paid=1/1 fp=lead:example-org/project-6#3212@$H2" \
    "$(jq -nc --arg h "$H2" '{slug:"example-org/project-6",pr:3212,head:$h}')"; echo ,
  row "$RRC" "AGENT_CALL_REFUSED call-guard repeat ledger-paid attempts=2 fp=review:example-org/project-6#3247@$H4"; echo ,
  row "$RRD" "$CG fp=review:example-org/project-6#2985@$H3"; echo ,
  # The old path: e-k.
  row BH-123 "AGENT_CALL_REFUSED call-guard repeat build-head paid=1/1"; echo ,
  row RR-3300-aaaaaaaa "AGENT_CALL_REFUSED llm-gate usd-cap-day"; echo ,
  row RR-3301-bbbbbbbb "BUILD_DEFERRED slots"; echo ,
  row TK-3302-cccccccc "AGENT_CALL_REFUSED call-guard repeat fix-head paid=1/1"; echo ,
  row rr-3303-dddddddd "AGENT_CALL_REFUSED call-guard repeat review-head paid=1/1"; echo ,
  row "$RRJ" "$CG fp=review:example-org/project-6#3236@$HJ"; echo ,
  row RR-3304-eeeeeeee "deferred 6 times ($CG) — parked for the blocked-resolver"
  echo ']}'
} > "$T/q.json"
jq -e '.queue | length == 11' "$T/q.json" >/dev/null || { echo "FAIL: fixture"; exit 1; }
HELD="$RRA $LRB $RRC $RRD"

run_wd() { # run_wd [VAR=value...]
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid REQ_SINK="$T/req.log" QUEUE_DONE_JSON="$T/q.json"
    env "$@" bash "$T/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}
notes() { grep '^POST .*/api/lifecycle/note ' "$T/req.log" 2>/dev/null | cut -d' ' -f3-; }
note_for() { notes | jq -c --arg k "$1" 'select(.ticket_key == $k)' 2>/dev/null; }
queued() { grep '^POST .*/api/queue ' "$T/req.log" 2>/dev/null | cut -d' ' -f3- | jq -r '.key' 2>/dev/null; }
scanline() { grep ' scan: ' "$T/logs/jobs-watchdog.log" 2>/dev/null | tail -1; }
held_none_queued() { # held_none_queued <case>
  local k q; q=$(queued)
  for k in $HELD; do grep -qxF "$k" <<<"$q" && { bad "$1: $k was re-queued into the same refusal"; return; }; done
  ok
}

# --- C1 / C3 / C4 / C5 / C8: one tick --------------------------------------
rm -f "$T/req.log"
run_wd VD_MODE=lead
Q=$(queued)
held_none_queued C1
for k in BH-123 RR-3300-aaaaaaaa RR-3301-bbbbbbbb TK-3302-cccccccc rr-3303-dddddddd; do
  grep -qxF "$k" <<<"$Q" && ok || bad "C4 $k lost the old path (not re-queued): $Q"
done
grep -qxF RR-3304-eeeeeeee <<<"$Q" && bad "C4 a parked row was re-queued" || ok
[ -z "$(note_for RR-3304-eeeeeeee)" ] && ok || bad "C4 a parked row got a note"
grep -qxF "$RRJ" <<<"$Q" && ok || bad "C5 a head-mismatch row lost the old path: $Q"
[ -z "$(note_for "$RRJ")" ] && ok || bad "C5 a head-mismatch row got a note"
N1=$(note_for "$RRA")
[ "$(jq -c 'keys_unsorted' <<<"$N1")" = '["project","ticket_key","actor","reason","pr"]' ] \
  && ok || bad "C1 the note body keys: $N1"
[ "$(jq -r '.project, .actor, .pr' <<<"$N1" | tr '\n' ' ')" = "project-6-os watchdog 3191 " ] \
  && ok || bad "C1 the note names project, actor and pr: $N1"
jq -r .reason <<<"$N1" | grep -qF 'existing verdict BLOCK (lead, verdict row 7)' \
  && ok || bad "C1 the note does not name the standing verdict: $N1"
jq -r .reason <<<"$N1" | grep -qF "example-org/project-6#3191@${H1:0:12}" \
  && ok || bad "C1 the note does not name the head: $N1"
grep -q "QUEUE DEFERRAL REQUEUED: project-6-os/$RRA" "$T/logs/ALERTS.log" 2>/dev/null \
  && bad "C1 a held row still wrote a QUEUE DEFERRAL REQUEUED line" || ok
grep -q "QUEUE DEFERRAL REQUEUED: project-6-os/RR-3301-bbbbbbbb" "$T/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "C4 an old-path row lost its QUEUE DEFERRAL REQUEUED line"
[ "$(jq -r .pr <<<"$(note_for "$LRB")")" = 3212 ] && ok || bad "C3 the LR row has no note: $(notes)"
[ "$(jq -r .pr <<<"$(note_for "$RRC")")" = 3247 ] && ok || bad "C3 the ledger-paid row has no note: $(notes)"
jq -r .reason <<<"$(note_for "$RRD")" | grep -qF 'existing verdict BLOCK (lead' \
  && ok || bad "C3 a fingerprint-only row did not name the verdict: $(note_for "$RRD")"
[ "$(jq -r .pr <<<"$(note_for "$RRD")")" = 2985 ] && ok || bad "C3 a fingerprint-only row lost its pr"
[ "$(notes | wc -l)" = 4 ] && ok || bad "C1 expected 4 notes, got $(notes | wc -l): $(notes)"
grep -q ', 4 call-guard review row(s) held terminal' <<<"$(scanline)" \
  && ok || bad "C8 the scan line does not count the held rows: $(scanline)"
grep -q "queue-cg-terminal project-6-os/$RRA: not re-queued" "$T/logs/jobs-watchdog.log" \
  && ok || bad "C1 no queue-cg-terminal log line"

# --- C2: the next tick writes nothing new ----------------------------------
rm -f "$T/req.log"
run_wd VD_MODE=lead
[ -z "$(notes)" ] && ok || bad "C2 a second tick wrote a second note: $(notes)"
held_none_queued C2
grep -q ', 0 call-guard review row(s) held terminal' <<<"$(scanline)" \
  && ok || bad "C2 the second tick counted latched rows again: $(scanline)"

# --- C6 / C8: a refused note is owed, not latched, not counted --------------
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt" "$T/state/jobs-watchdog-cg-noted.txt"
run_wd VD_MODE=lead NOTE_MODE=refuse
held_none_queued C6
grep -q "$RRA#cg" "$T/state/jobs-watchdog-cg-noted.txt" 2>/dev/null \
  && bad "C6 a failed note was latched" || ok
grep -q ', 0 call-guard review row(s) held terminal' <<<"$(scanline)" \
  && ok || bad "C8 a refused note was counted as held: $(scanline)"
grep -q "queue-cg-hold project-6-os/$RRA: ticket_events write answered rc" "$T/logs/jobs-watchdog.log" \
  && ok || bad "C6 no queue-cg-hold log line for the refused note"
rm -f "$T/req.log"
run_wd VD_MODE=lead
[ -n "$(note_for "$RRA")" ] && ok || bad "C6 the next tick did not write the owed note"
grep -qxF "project-6-os/$RRA#cg" "$T/state/jobs-watchdog-cg-noted.txt" 2>/dev/null \
  && ok || bad "C6 the written note was not latched"

# --- C7: verdicts unreadable, then no standing row, then nothing at all -----
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt" "$T/state/jobs-watchdog-cg-noted.txt"
run_wd VD_MODE=down
[ -z "$(notes | jq -r 'select(.ticket_key != "'"$RRJ"'") | .ticket_key' 2>/dev/null)" ] \
  && ok || bad "C7 a note was written with the verdicts unreadable: $(notes)"
held_none_queued C7
rm -f "$T/req.log"
run_wd VD_MODE=none
jq -r .reason <<<"$(note_for "$RRA")" | grep -qF 'existing verdict MERGE-WITH-NOTES (box)' \
  && ok || bad "C7 with no standing row the note does not name the box verdict: $(note_for "$RRA")"
rm -f "$T/req.log" "$T/state/jobs-watchdog-deferred.txt" "$T/state/jobs-watchdog-cg-noted.txt"
run_wd VD_MODE=nobox
jq -r .reason <<<"$(note_for "$RRA")" | grep -qF 'no verdict recorded on this head' \
  && ok || bad "C7 with no verdict at all the note does not say so: $(note_for "$RRA")"
held_none_queued C7

echo "jobs-watchdog-cg-terminal (BH-9160): $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
