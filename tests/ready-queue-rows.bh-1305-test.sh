#!/bin/bash
# tests/ready-queue-rows.bh-1305-test.sh — rq_drop with an EMPTY project must
# forget every board's row for the key, because the file half already does.
#
# THE BUG (BH-1305, carried note N1 from the #1161 delta review). The only
# production caller of rq_drop is bin/queue-line-drop.sh, and it always passes an
# empty project: it is handed keys and nothing else. The file half of that same
# consume strips EVERY line matching `^<KEY>[[:space:]]`, whatever project the
# line names. The row half picked ONE project per key
# (`awk '$2==k {print $1; exit}'`) and PATCHed only that row. So when one key is
# `ready` on two boards the file forgets both and the rows forget one: what is
# left is a `ready` row with no line, rq_any keeps answering "there is work",
# the 45-minute fingerprint never settles, and bin/triage-gate.sh buys paid ticks
# for a ticket a session already consumed — the exact failure the BH-1033 slice
# was built to remove.
#
# WHAT IS RED BEFORE THE FIX: cases A and B. The rest are the neighbours that
# must not move — a named project never fans out, a refused row keeps its live
# build and is never logged as an outage, the flag-off path makes no request.
#
# Run from anywhere: tests/ready-queue-rows.bh-1305-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/locks" "$T/fakebin"
for F in jobs-client.sh queue-line-drop.sh; do cp "$DIR/bin/$F" "$H/bin/"; done
for F in "$DIR"/bin/lib/*.sh; do cp "$F" "$H/bin/lib/" 2>/dev/null; done
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load.
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# ── The worker, as a file-backed stub ───────────────────────────────────────
# Same shape as tests/ready-queue-rows-test.sh's, trimmed to the three routes
# this suite needs, plus FLIP_ROW: `<project> <key> <status>` applied AFTER a
# ready-row list is served. That is the launch-then-drop RACE in production —
# the list said `ready`, a box claimed the row, and the PATCH is refused with a
# 409. It is the only way an empty-project drop reaches the rc 9 branch, because
# the list itself only ever returns `ready` rows.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
[ "${CURL_MODE:-up}" = down ] && exit 7
case "$M $URL" in
  "GET "*/api/settings/*)
    K="${URL##*/}"
    V=""
    [ "$K" = ready_queue_rows ] && V="${FLAG_READY:-0}"
    [ -n "$V" ] && printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "$V" \
                || printf '{}\n404\n'
    ;;
  "GET "*/api/queue*)
    P=""; case "$URL" in *project=*) P="${URL##*project=}"; P="${P%%&*}" ;; esac
    ST=""; case "$URL" in *status=*) ST="${URL##*status=}"; ST="${ST%%&*}" ;; esac
    awk -F'\t' -v p="$P" -v st="$ST" 'BEGIN{printf "{\"queue\":["; n=0}
      (p=="" || $1==p) && (st=="" || $4==st) {
        if (n++) printf ",";
        printf "{\"project\":\"%s\",\"ticket_key\":\"%s\",\"ticket_id\":\"%s\",\"status\":\"%s\",\"target\":\"local\",\"attempt\":0,\"enqueued_at\":\"2026-09-19T00:00:00Z\",\"meta\":\"{\\\"ready_line\\\":\\\"%s\\\"}\"}", $1,$2,$3,$4,$5 }
      END{print "]}"}' "$ROWS" 2>/dev/null
    echo 200
    if [ -n "${FLIP_ROW:-}" ]; then
      set -- $FLIP_ROW
      awk -F'\t' -v OFS='\t' -v p="$1" -v k="$2" -v s="$3" \
        '$1==p && $2==k{$4=s} {print}' "$ROWS" > "$ROWS.f" && mv "$ROWS.f" "$ROWS"
    fi
    ;;
  "PATCH "*/api/queue)
    P=$(jq -r '.project // ""' <<<"$BODY"); K=$(jq -r '.key // ""' <<<"$BODY")
    S=$(jq -r '.status // ""' <<<"$BODY")
    CUR=$(awk -F'\t' -v p="$P" -v k="$K" '$1==p && $2==k{print $4; exit}' "$ROWS")
    if [ -z "$CUR" ]; then printf '{"error":"nothing queued"}\n404\n'
    elif [ "$CUR" != ready ] && [ "$S" = dropped ]; then
      printf '{"error":"illegal transition","refused":true}\n409\n'
    else
      awk -F'\t' -v OFS='\t' -v p="$P" -v k="$K" -v s="$S" \
        '$1==p && $2==k{$4=s} {print}' "$ROWS" > "$ROWS.n" && mv "$ROWS.n" "$ROWS"
      printf '{"queued":{"status":"%s"}}\n200\n' "$S"
    fi
    ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

ROWS="$T/rows.tsv"; : > "$ROWS"
Q="$H/logs/READY-QUEUE.log"
RQLOG="$H/logs/ready-queue.log"

# run <flag 0|1> <curl-mode up|down> <command...> — one lane, one tick.
run() {
  local flag="$1" mode="$2"; shift 2
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a JOBS_RETRIES=0 \
           JOBS_TIMEOUT=5 CURL_MODE="$mode" REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           FLAG_READY="$flag" FLIP_ROW="${FLIP_ROW:-}"
    "$@" )
}
# lib <flag> <mode> <shell snippet> — the ready-queue library, driven directly.
lib() {
  local flag="$1" mode="$2" snip="$3"
  run "$flag" "$mode" bash -c '
    . "$HARNESS/bin/jobs-client.sh"
    . "$HARNESS/bin/lib/ready-queue.sh"
    '"$snip"
}
# `grep -c x f || echo 0` prints 0 AND THEN 0 when the count is zero, so the
# count helpers are awk.
patches() { awk '/^PATCH .*\/api\/queue/{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }
qreqs()   { awk '/\/api\/queue/{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }
# statuses <key> — `project/status` for every row with that key, sorted.
statuses() { awk -F'\t' -v k="$1" '$2==k{print $1"/"$4}' "$ROWS" | sort | tr '\n' ' '; }

two_boards() { # two_boards [x-status] [y-status]
  : > "$ROWS"
  printf 'x-os\tAR-9\TK-9\t%s\tAR-9 t-9 — owed project=x-os\n' "${1:-ready}" >> "$ROWS"
  printf 'y-os\tAR-9\TK-9\t%s\tAR-9 t-9 — owed project=y-os\n' "${2:-ready}" >> "$ROWS"
}

# ══ A. THE RED: an empty project drops EVERY board's row for the key ════════
FLIP_ROW=
two_boards
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(statuses TK-9)" = "x-os/dropped y-os/dropped " ] \
  && ok || bad "RED CORE: with the same key ready on two boards, an empty-project rq_drop must drop BOTH rows — the file half already forgot both lines, got: $(statuses TK-9)"
[ "$(patches)" = 2 ] \
  && ok || bad "two boards holding the key must be exactly two PATCHes, got $(patches): $(cat "$T/req.txt")"

# N boards, not just two: the fan-out is over the row set, not a special case.
: > "$ROWS"
for P in x-os y-os z-os; do
  printf '%s\tAR-9\TK-9\tready\tAR-9 t-9 — owed project=%s\n' "$P" "$P" >> "$ROWS"
done
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(statuses TK-9)" = "x-os/dropped y-os/dropped z-os/dropped " ] \
  && ok || bad "the fan-out must cover N boards, not two, got: $(statuses TK-9)"
[ "$(patches)" = 3 ] \
  && ok || bad "three boards holding the key must be exactly three PATCHes, got $(patches)"

# One project, one row: the ordinary case must not have grown a second request.
: > "$ROWS"; printf 'x-os\tAR-9\TK-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
{ [ "$(statuses TK-9)" = "x-os/dropped " ] && [ "$(patches)" = 1 ]; } \
  && ok || bad "the single-board case must stay one PATCH and one dropped row, got: $(statuses TK-9) / $(patches) PATCHes"

# ══ B. THE PRODUCTION ENTRY POINT: bin/queue-line-drop.sh ═══════════════════
# The file half and the row half must forget the SAME thing. This is the whole
# bug: the script strips `^TK-9 ` for every project, so a surviving `ready` row
# is a ticket rq_any re-brakes triage on forever.
two_boards
printf 'TK-9 t-9 — owed project=x-os\nAR-9 t-9 — owed project=y-os\nAR-1 t-1 — waiting project=x-os\n' > "$Q"
OUTPUT=$(run 1 up bash "$H/bin/queue-line-drop.sh" TK-9 2>&1); RC=$?
[ "$RC" = 0 ] \
  && ok || bad "queue-line-drop.sh must exit 0, got rc=$RC: $OUTPUT"
{ ! grep -q '^TK-9 ' "$Q" && grep -q '^TK-1 ' "$Q"; } \
  && ok || bad "queue-line-drop.sh must strip every TK-9 line and keep the rest: $(cat "$Q")"
[ "$(statuses TK-9)" = "x-os/dropped y-os/dropped " ] \
  && ok || bad "RED CORE: through the production caller, the rows must forget what the file forgot — a surviving ready row with no line re-brakes triage forever, got: $(statuses TK-9) / $OUTPUT"
grep -q 'dropped 2 line(s) for: TK-9' <<<"$OUTPUT" \
  && ok || bad "queue-line-drop.sh must still print today's count line, got: $OUTPUT"

# ...and with no queue file at all (the path the slice exists for) both rows
# still go: the ssh append that would have made the file is the thing that failed.
rm -f "$Q"
two_boards
OUTPUT=$(run 1 up bash "$H/bin/queue-line-drop.sh" TK-9 2>&1)
[ "$(statuses TK-9)" = "x-os/dropped y-os/dropped " ] \
  && ok || bad "RED CORE: with no READY-QUEUE.log at all both boards' rows must still be dropped, got: $(statuses TK-9) / $OUTPUT"

# ══ C. THE NEIGHBOURS THAT MUST NOT MOVE ════════════════════════════════════
# A row that is not `ready` is not in the ready list at all, so the fan-out must
# never reach it: the live build on x-os keeps its row and its claim.
two_boards claimed ready
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(statuses TK-9)" = "x-os/claimed y-os/dropped " ] \
  && ok || bad "a claimed row must keep its live build while the ready one drops, got: $(statuses TK-9)"
[ "$(patches)" = 1 ] \
  && ok || bad "the fan-out must PATCH only the rows the ready list returned, got $(patches): $(cat "$T/req.txt")"

# THE RACE, which is the only way the empty-project path reaches rc 9: the list
# said both were ready, a box claimed x-os in between, and the PATCH is refused.
# A refusal is NOT an outage (the worker answered perfectly), and it must not
# stop the other board's row being dropped.
two_boards
: > "$RQLOG"
FLIP_ROW="x-os TK-9 claimed"
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
FLIP_ROW=
[ "$(statuses TK-9)" = "x-os/claimed y-os/dropped " ] \
  && ok || bad "a refusal on one board must not stop the next board's drop, got: $(statuses TK-9)"
grep -q 'x-os/TK-9' "$RQLOG" \
  && ok || bad "a refused drop must leave one line naming the project/key, log: $(cat "$RQLOG")"
grep -qi 'unreachable' "$RQLOG" \
  && bad "a 409 refusal must never be logged as an outage: $(cat "$RQLOG")" || ok

# A NAMED project never fans out — that seam is what keeps the drop honest for
# any future caller that does know its project.
two_boards
lib 1 up 'rq_drop "$HARNESS" y-os TK-9' >/dev/null
[ "$(statuses TK-9)" = "x-os/ready y-os/dropped " ] \
  && ok || bad "a named project must drop only that project's row, got: $(statuses TK-9)"
[ "$(patches)" = 1 ] \
  && ok || bad "a named project must make exactly one PATCH, got $(patches)"

# An outage on the rows read is one line and rc 0 — the file line is gone either
# way, and the drop must never become a failure the caller sees.
two_boards
: > "$RQLOG"
lib 1 down 'rq_drop "$HARNESS" "" TK-9' >/dev/null && ok \
  || bad "an unreachable worker must still leave rq_drop at rc 0"
[ "$(statuses TK-9)" = "x-os/ready y-os/ready " ] \
  && ok || bad "an outage must touch no row, got: $(statuses TK-9)"

# ══ D. FLAG OFF IS TODAY, BYTE FOR BYTE ═════════════════════════════════════
two_boards
lib 0 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(statuses TK-9)" = "x-os/ready y-os/ready " ] \
  && ok || bad "with the flag off rq_drop must touch nothing, got: $(statuses TK-9)"
[ "$(qreqs)" = 0 ] \
  && ok || bad "with the flag off rq_drop must make NO /api/queue request, got $(qreqs): $(cat "$T/req.txt")"

# ══ E. A KEY WITH NO ROW ANYWHERE IS QUIET, NOT A FAILURE ═══════════════════
two_boards
lib 1 up 'rq_drop "$HARNESS" "" NOPE-1' >/dev/null && ok \
  || bad "dropping a key with no row must be rc 0 — idempotence is the whole contract of the drop"
[ "$(patches)" = 0 ] \
  && ok || bad "a key with no row must make no PATCH at all, got $(patches): $(cat "$T/req.txt")"
[ "$(statuses TK-9)" = "x-os/ready y-os/ready " ] \
  && ok || bad "a key with no row must leave every other row alone, got: $(statuses TK-9)"

# Several keys in one call, each fanned out over its own boards.
: > "$ROWS"
printf 'x-os\tAR-9\TK-9\tready\tl\ny-os\tAR-9\TK-9\tready\tl\nx-os\tAR-8\TK-8\tready\tl\n' >> "$ROWS"
lib 1 up 'rq_drop "$HARNESS" "" TK-9 TK-8' >/dev/null
{ [ "$(statuses TK-9)" = "x-os/dropped y-os/dropped " ] && [ "$(statuses TK-8)" = "x-os/dropped " ]; } \
  && ok || bad "a multi-key drop must fan each key out over its own boards, got: $(statuses TK-9)/ $(statuses TK-8)"

echo "ready-queue-rows.bh-1305: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
