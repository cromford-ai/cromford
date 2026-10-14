#!/bin/bash
# tests/ready-queue-rows-test.sh — the READY queue as build_queue `ready` ROWS
# (BH-1033, state→DB slice 8), with logs/READY-QUEUE.log left as a log.
#
# THE GAP THIS CLOSES. "This ticket is ready to build" lives in ONE file on ONE
# box. bin/stale-owed-tickets.sh has to ssh into the owning box to append a
# line; bin/triage-gate.sh brakes the whole tick on a grep of that file, so a
# box whose file never received the append triages nothing; and the 45-minute
# skip fingerprint is computed from the file's bytes, so a ready ticket that
# exists only as a row is invisible to every lane. A row is fleet-visible and
# needs no ssh.
#
# WHAT IS RED BEFORE THE SLICE (the ticket's own RED): a `ready` row with NO log
# line must un-brake triage and be pre-plannable. Today neither is true — both
# lanes read the file and nothing else.
#
# FAIL-OPEN IS THE CONTRACT. With the flag off, or the worker unreachable, every
# lane below must behave byte-for-byte as it does today and must not make a
# single request beyond the settings read. A queue that can refuse work when a
# database blinks is worse than no queue in a database at all.
#
# Run from anywhere: tests/ready-queue-rows-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/plans" "$T/fakebin"
for F in jobs-client.sh queue-line-drop.sh preplan-candidates.sh preplan-tick.sh; do
  [ -f "$DIR/bin/$F" ] && cp "$DIR/bin/$F" "$H/bin/"
done
for F in "$DIR"/bin/lib/*.sh; do cp "$F" "$H/bin/lib/" 2>/dev/null; done
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
# a fixture that copies it must copy its modules too.
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/project-of.sh" "$H/bin/" 2>/dev/null
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# ── The worker, as a file-backed stub ───────────────────────────────────────
# ROWS lives in $T/rows.tsv as `project<TAB>key<TAB>ticket_id<TAB>status<TAB>line`
# so a test can put a row on the queue without going through the client, and so
# a PATCH can be observed as a state change rather than only as a request line.
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
    [ "$K" = closeout_aged_table ] && V="${FLAG_CLOSEOUT:-0}"
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
    ;;
  "POST "*/api/queue)
    P=$(jq -r '.project // ""' <<<"$BODY"); K=$(jq -r '.key // ""' <<<"$BODY")
    S=$(jq -r '.status // "queued"' <<<"$BODY")
    TI=$(jq -r '.ticket_id // ""' <<<"$BODY")
    L=$(jq -r 'if (.meta|type)=="string" then (.meta|fromjson?|.ready_line // "") else (.meta.ready_line // "") end' <<<"$BODY" 2>/dev/null)
    if awk -F'\t' -v p="$P" -v k="$K" '$1==p && $2==k{f=1} END{exit f?0:1}' "$ROWS"; then
      printf '{"duplicate":true}\n200\n'
    else
      printf '%s\t%s\t%s\t%s\t%s\n' "$P" "$K" "$TI" "$S" "$L" >> "$ROWS"
      printf '{"duplicate":false}\n201\n'
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

# run <flag 0|1> <curl-mode up|down> <command...>  — one lane, one tick.
#   flag: 0 = the settings row says off, 1 = it says on, env = the row is
#   unreadable and the DOCUMENTED env fallback says on (which is the only way a
#   lane is on while the worker is down — see the outage section).
run() {
  local flag="$1" mode="$2"; shift 2
  : > "$T/req.txt"
  local envflag=0
  case "$flag" in env) envflag=1; flag=0 ;; esac
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a JOBS_RETRIES=0 \
           JOBS_TIMEOUT=5 CURL_MODE="$mode" REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           FLAG_READY="$flag" FLAG_CLOSEOUT=0 REPOS_ROOT="$T/repos" \
           READY_QUEUE_ROWS="$envflag"
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
# `grep -c x f || echo 0` prints 0 AND THEN 0 when the count is zero (grep exits
# 1), so the count helpers are awk.
qreqs() { awk '/\/api\/queue/{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }

# ══ 1. THE LIBRARY EXISTS AND IS THE ONE DEFINITION ═════════════════════════
[ -r "$DIR/bin/lib/ready-queue.sh" ] \
  && ok || bad "bin/lib/ready-queue.sh missing — the ready set must have ONE definition, not one grep per lane"
bash -n "$DIR/bin/lib/ready-queue.sh" 2>/dev/null \
  && ok || bad "bin/lib/ready-queue.sh does not parse"

# ══ 2. FLAG OFF IS TODAY, BYTE FOR BYTE ═════════════════════════════════════
printf 'TK-1 t-1 — waiting project=x-os\n' > "$Q"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
OUT=$(lib 0 up 'rq_lines "$HARNESS" x-os')
[ "$OUT" = 'TK-1 t-1 — waiting project=x-os' ] \
  && ok || bad "flag off must yield exactly the file's lines, got: $OUT"
[ "$(qreqs)" = 0 ] \
  && ok || bad "flag off must make NO /api/queue request, got $(qreqs): $(cat "$T/req.txt")"

# ══ 3. RED CORE: A READY ROW WITH NO LOG LINE IS REAL WORK ══════════════════
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
grep -q '^TK-9 ' <<<"$OUT" \
  && ok || bad "a ready ROW with no log line must appear in the ready set, got: $OUT"
grep -q '^TK-1 ' <<<"$OUT" \
  && ok || bad "the file's lines must still come out with the flag on, got: $OUT"
[ "$(grep -c '^TK-9' <<<"$OUT")" = 1 ] \
  && ok || bad "a row must appear once, got: $OUT"
grep -q 'project=x-os' <<<"$(grep '^TK-9' <<<"$OUT")" \
  && ok || bad "a synthesized line must carry project=, or bin/project-of.sh cannot bucket it: $OUT"

# A row for ANOTHER project is not this project's work.
printf 'other-os\tZZ-4\tt-4\tready\tZZ-4 t-4 — owed project=other-os\n' >> "$ROWS"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
grep -q 'ZZ-4' <<<"$OUT" \
  && bad "a ready row for another project must not leak into x-os's set: $OUT" || ok

# NO DOUBLE COUNTING: a key that is on the file AND in a row is one line.
printf 'x-os\tAR-1\tt-1\tready\tAR-1 t-1 — owed project=x-os\n' >> "$ROWS"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
[ "$(grep -c '^TK-1' <<<"$OUT")" = 1 ] \
  && ok || bad "a key on the file AND in a row must be ONE line (the file wins), got: $OUT"

# THE PRODUCTION LINE SHAPE. bin/stale-owed-tickets.sh is the ONLY writer of a
# ready_line and it emits `<KEY> OWED-STALE <n>h [<status>/<waitingOn>] <title>`
# — no `project=` token anywhere in it. The ROW carries the project; the line
# must say so. Without it bin/preplan-candidates.sh falls through to
# bin/project-of.sh mention-matching on the TITLE and DROPS the line when the
# guess is not $PROJECT (the row is never pre-plannable, which is the ticket's
# own RED), and bin/preplan-tick.sh — which reads rows FLEET-WIDE — pre-plans it
# under whichever project the title happens to mention.
: > "$Q"
: > "$ROWS"; printf 'x-os\tAR-77\tt-77\tready\tAR-77 OWED-STALE 27h [in_progress/-] Fix the widget\n' >> "$ROWS"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
[ "$OUT" = 'TK-77 OWED-STALE 27h [in_progress/-] Fix the widget project=x-os' ] \
  && ok || bad "RED CORE: a ready row whose line is the PRODUCTION stale-owed shape must carry project= from the row's own column, got: [$OUT]"
# The FLEET-WIDE read is bin/preplan-tick.sh's, and it is the one that can
# mis-file a ticket rather than merely lose it.
OUT=$(lib 1 up 'rq_lines "$HARNESS" ""')
grep -q 'project=x-os' <<<"$OUT" \
  && ok || bad "the fleet-wide read must carry project= too (bin/preplan-tick.sh buckets on it), got: [$OUT]"
# A line that ALREADY names its project is emitted character for character.
: > "$ROWS"; printf 'x-os\tAR-78\tt-78\tready\tAR-78 t-78 — owed project=x-os\n' >> "$ROWS"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
[ "$OUT" = 'TK-78 t-78 — owed project=x-os' ] \
  && ok || bad "a line that already carries project= must be emitted verbatim, got: [$OUT]"

# ══ 4. rq_any — the brake ═══════════════════════════════════════════════════
: > "$Q"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
lib 1 up 'rq_any "$HARNESS" x-os' \
  && ok || bad "RED CORE: an empty log file plus a ready ROW must still be 'there is work' — the triage brake reads this"
lib 0 up 'rq_any "$HARNESS" x-os' \
  && bad "with the flag off an empty file must be 'no work', exactly as today" || ok
: > "$ROWS"
lib 1 up 'rq_any "$HARNESS" x-os' \
  && bad "no file lines and no rows must be 'no work'" || ok

# ══ 5. AN OUTAGE IS NOT AN EMPTY QUEUE, AND IT SAYS SO ══════════════════════
printf 'TK-1 t-1 — waiting project=x-os\n' > "$Q"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
: > "$H/logs/ready-queue.log" 2>/dev/null
# A worker that is down cannot even be asked whether the flag is on, and that
# reads as OFF — a blinking worker must never switch a lane onto a new path.
OUT=$(lib 1 down 'rq_lines "$HARNESS" x-os')
[ "$OUT" = 'TK-1 t-1 — waiting project=x-os' ] \
  && ok || bad "an outage must degrade to the file's lines, not to nothing, got: $OUT"
lib 1 down 'rq_on' \
  && bad "an unreadable flag must NEVER read as ON" || ok
# With the env fallback ON, the flag is on and the ROW READ is what fails. That
# is the fail-open this lib has to survive: the file's lines, and a line saying
# the set was incomplete.
OUT=$(lib env down 'rq_lines "$HARNESS" x-os')
[ "$OUT" = 'TK-1 t-1 — waiting project=x-os' ] \
  && ok || bad "an unreachable row read must degrade to the file's lines, got: $OUT"
grep -qi 'unreachable' "$H/logs/ready-queue.log" 2>/dev/null \
  && ok || bad "a reader that failed open must leave a log line (iron law), log: $(cat "$H/logs/ready-queue.log" 2>/dev/null)"

# ══ 6. THE FINGERPRINT — a new row is new-world, a restamp is not ═══════════
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — last probe 2026-09-19T01:02:03Z project=x-os\n' >> "$ROWS"
A=$(lib 1 up 'rq_fp "$HARNESS" x-os')
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — last probe 2026-09-19T09:09:09Z project=x-os\n' >> "$ROWS"
B=$(lib 1 up 'rq_fp "$HARNESS" x-os')
[ "$A" = "$B" ] && [ -n "$A" ] \
  && ok || bad "a RESTAMPED row must not change the fingerprint (the \$90/day project-1 loop): [$A] vs [$B]"
printf 'x-os\tAR-10\tt-10\tready\tAR-10 t-10 — owed project=x-os\n' >> "$ROWS"
C=$(lib 1 up 'rq_fp "$HARNESS" x-os')
[ "$C" != "$B" ] \
  && ok || bad "a NEW ready row must change the fingerprint, or triage sleeps through it"
D=$(lib 0 up 'rq_fp "$HARNESS" x-os')
[ -z "$D" ] \
  && ok || bad "with the flag off the fingerprint contribution must be EMPTY (byte-identical ticks), got: [$D]"

# ══ 7. rq_drop — consuming a line consumes the row ══════════════════════════
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
lib 1 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(awk -F'\t' '$2=="TK-9"{print $4}' "$ROWS")" = dropped ] \
  && ok || bad "rq_drop must patch the row out of ready, got: $(cat "$ROWS")"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tline\n' >> "$ROWS"
lib 0 up 'rq_drop "$HARNESS" "" TK-9' >/dev/null
[ "$(awk -F'\t' '$2=="TK-9"{print $4}' "$ROWS")" = ready ] \
  && ok || bad "with the flag off rq_drop must touch nothing"
lib 1 up 'rq_drop "$HARNESS" "" NOPE-1' >/dev/null && ok \
  || bad "dropping a key with no row is rc 0 and quiet — idempotence is the whole contract of the drop"
# A REFUSAL AND AN OUTAGE ARE NOT THE SAME LINE (round-3 N3). The worker refuses
# to drop a row that is no longer `ready` — a box is building that key — and it
# answers 409, which the client maps to rc 9. An operator reading
# logs/ready-queue.log after a launch-then-drop race must not be told the
# coordination worker was unreachable when it answered perfectly.
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tclaimed\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
: > "$H/logs/ready-queue.log"
lib 1 up 'rq_drop "$HARNESS" x-os TK-9' >/dev/null
[ "$(awk -F'\t' '$2=="TK-9"{print $4}' "$ROWS")" = claimed ] \
  && ok || bad "a claimed row must keep its live build when a drop refuses, got: $(cat "$ROWS")"
grep -qi 'unreachable' "$H/logs/ready-queue.log" \
  && bad "a 409 refusal must not be logged as an outage: $(cat "$H/logs/ready-queue.log")" || ok
grep -q 'TK-9' "$H/logs/ready-queue.log" \
  && ok || bad "a refused drop must still leave one line naming the key, log: $(cat "$H/logs/ready-queue.log")"
# …and a real outage still says so.
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
: > "$H/logs/ready-queue.log"
lib env down 'rq_drop "$HARNESS" x-os TK-9' >/dev/null
grep -qi 'unreachable' "$H/logs/ready-queue.log" \
  && ok || bad "an unreachable worker must still be logged as one, log: $(cat "$H/logs/ready-queue.log")"

# ══ 8. rq_put — an enqueue nobody has to ssh for ════════════════════════════
: > "$ROWS"
lib 1 up 'rq_put "$HARNESS" x-os TK-11 t-11 "TK-11 t-11 — OWED-STALE project=x-os"' >/dev/null
[ "$(awk -F'\t' '$2=="TK-11"{print $1"/"$4}' "$ROWS")" = "x-os/ready" ] \
  && ok || bad "rq_put must insert a READY row, got: $(cat "$ROWS")"
[ "$(awk -F'\t' '$2=="TK-11"{print $5}' "$ROWS")" = "TK-11 t-11 — OWED-STALE project=x-os" ] \
  && ok || bad "the row must carry the LINE — a row that cannot reproduce the line is not a replacement for it"
lib 1 up 'rq_put "$HARNESS" x-os TK-11 t-11 "TK-11 t-11 — OWED-STALE project=x-os"' >/dev/null
[ "$(grep -c 'TK-11' "$ROWS")" = 1 ] \
  && ok || bad "rq_put must be idempotent on project+key (the 24h cooldown depends on it)"
: > "$ROWS"
lib 0 up 'rq_put "$HARNESS" x-os TK-12 t-12 line' >/dev/null
[ ! -s "$ROWS" ] && ok || bad "with the flag off rq_put must write nothing"

# ══ 9. bin/queue-line-drop.sh — the file AND the row ════════════════════════
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
printf 'TK-9 t-9 — owed project=x-os\nAR-1 t-1 — waiting project=x-os\n' > "$Q"
OUTPUT=$(run 1 up bash "$H/bin/queue-line-drop.sh" TK-9 2>&1)
grep -q '^TK-1 ' "$Q" && ! grep -q '^TK-9 ' "$Q" \
  && ok || bad "queue-line-drop must still drop exactly its own file line: $(cat "$Q")"
[ "$(awk -F'\t' '$2=="TK-9"{print $4}' "$ROWS")" = dropped ] \
  && ok || bad "queue-line-drop must patch the ready ROW too, or the row re-brakes triage forever: $(cat "$ROWS") / $OUTPUT"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tl\n' >> "$ROWS"
printf 'TK-9 t-9 — owed project=x-os\n' > "$Q"
# THE LOCKS ARE RELEASED BEFORE THE NETWORK CALL. A flock lives on the open
# descriptor until the process exits, so a drop that ran with fds 8 and 9 still
# open would hold the queue's sidecar lock and harden-state.lock for the length
# of an HTTP round trip — on the one file every parallel triager is waiting to
# rename. Ordered, because the release only counts if it comes FIRST.
CLOSE_AT=$(grep -n 'exec 8>&- 9>&-' "$DIR/bin/queue-line-drop.sh" | head -1 | cut -d: -f1)
DROP_AT=$(grep -n 'rq_drop' "$DIR/bin/queue-line-drop.sh" | tail -1 | cut -d: -f1)
{ [ -n "$CLOSE_AT" ] && [ -n "$DROP_AT" ] && [ "$CLOSE_AT" -lt "$DROP_AT" ]; } \
  && ok || bad "queue-line-drop.sh must close its two lock fds BEFORE the row drop (close=$CLOSE_AT drop=$DROP_AT)"
MV_AT=$(grep -n 'mv -f "$TMP" "$Q"' "$DIR/bin/queue-line-drop.sh" | head -1 | cut -d: -f1)
{ [ -n "$MV_AT" ] && [ "$MV_AT" -lt "$CLOSE_AT" ]; } \
  && ok || bad "the file rewrite must land BEFORE the locks are dropped (mv=$MV_AT close=$CLOSE_AT)"

run 1 down bash "$H/bin/queue-line-drop.sh" TK-9 >/dev/null 2>&1
if grep -q '^TK-9' "$Q" 2>/dev/null; then
  bad "an outage must not stop the FILE line being dropped — the file is still the queue: $(cat "$Q")"
else ok; fi

# NO QUEUE FILE IS NOT "NOTHING TO DROP". A box whose logs/READY-QUEUE.log does
# not exist yet is precisely the case this slice exists for — the ssh append
# that would have created the file is the thing that failed, so the ROW is the
# whole queue. Returning before the row drop leaves a `ready` row for a key the
# session has already consumed: rq_any keeps answering "there is work", the
# fingerprint never changes, and bin/triage-gate.sh's 4-hour ceiling buys a paid
# tick per project for a ticket nobody will launch.
rm -f "$Q"
: > "$ROWS"; printf 'x-os\tAR-78\tt-78\tready\tAR-78 t-78 — owed project=x-os\n' >> "$ROWS"
OUTPUT=$(run 1 up bash "$H/bin/queue-line-drop.sh" TK-78 2>&1)
[ "$(awk -F'\t' '$2=="TK-78"{print $4}' "$ROWS")" = dropped ] \
  && ok || bad "RED CORE: with no READY-QUEUE.log at all the ready ROW must still be dropped, got: $(cat "$ROWS") / $OUTPUT"
grep -q 'dropped 0' <<<"$OUTPUT" \
  && ok || bad "the no-file path must still print today's 'dropped 0' line, got: $OUTPUT"
# A key that is not a ticket key is refused on the no-file path too, rather than
# being handed to the worker unvalidated (the loop that exits 2 never runs here).
: > "$ROWS"; printf 'x-os\tAR-78\tt-78\tready\tl\n' >> "$ROWS"
run 1 up bash "$H/bin/queue-line-drop.sh" 'TK-78;rm -rf /' >/dev/null 2>&1
[ "$(awk -F'\t' '$2=="TK-78"{print $4}' "$ROWS")" = ready ] \
  && ok || bad "a malformed key must never reach the row drop: $(cat "$ROWS")"

# A HALF-SYNCED bin/ MUST NOT EAT THE DROP (round-5 nit). The lib sources
# bin/jobs-client.sh, whose BH-1194 shim `exit 1`s when bin/lib/jobs/ is not
# beside it. rq_drop_keys runs AFTER the durable file rewrite and BEFORE the
# "dropped N line(s)" line, so an exit taken in the caller's own shell throws
# away the rc and the output of work that already succeeded: the triage shard
# (bin/lib/rt/shards.sh) reads rc 1 and "missing module" for a queue line that
# is gone. The ROW half may be lost on such a box — the file half and the
# caller's contract may not.
H2="$T/h2"; scratch_rm "$H2"; cp -R "$H" "$H2"; scratch_rm "$H2/bin/lib/jobs"
half() { # half <args...> — queue-line-drop.sh on the half-synced copy
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H2" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a JOBS_RETRIES=0 \
           JOBS_TIMEOUT=5 CURL_MODE=up REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           FLAG_READY=1 FLAG_CLOSEOUT=0
    bash "$H2/bin/queue-line-drop.sh" "$@" 2>&1 )
}
printf 'TK-9 t-9 — owed project=x-os\nAR-1 t-1 — waiting project=x-os\n' > "$H2/logs/READY-QUEUE.log"
OUTPUT=$(half TK-9); RC=$?
[ "$RC" = 0 ] \
  && ok || bad "RED CORE: on a half-synced bin/ the drop must still exit 0 — the file rewrite already landed, got rc=$RC: $OUTPUT"
grep -q 'dropped 1 line(s)' <<<"$OUTPUT" \
  && ok || bad "RED CORE: on a half-synced bin/ the caller must still get its 'dropped N line(s)' line, got: $OUTPUT"
{ grep -q '^TK-1 ' "$H2/logs/READY-QUEUE.log" && ! grep -q '^TK-9 ' "$H2/logs/READY-QUEUE.log"; } \
  && ok || bad "the file half must be untouched by the missing module: $(cat "$H2/logs/READY-QUEUE.log")"
rm -f "$H2/logs/READY-QUEUE.log"
OUTPUT=$(half TK-78); RC=$?
{ [ "$RC" = 0 ] && grep -q 'dropped 0 (no queue file)' <<<"$OUTPUT"; } \
  && ok || bad "RED CORE: the no-file path on a half-synced bin/ must still print today's line and exit 0, got rc=$RC: $OUTPUT"
# The exit must be contained by a SUBSHELL, not by the shim being absent: a
# later edit that unwraps the source reintroduces the whole finding.
grep -qE '^\s*\(\s*\[ -r .*ready-queue\.sh' "$DIR/bin/queue-line-drop.sh" \
  && ok || bad "the ready-queue source inside rq_drop_keys must stay inside a subshell, or a half-synced box takes the caller down with it"

# ══ 10. bin/preplan-candidates.sh — a row is pre-plannable ══════════════════
# Driven for real: the GitHub-Issues lane with an empty `gh` answer, which is
# the path that emits the buffered queued lines and exits.
printf '#!/bin/bash\ncase "$2" in board_prefix) echo - ;; repo) echo o/r ;; *) echo "" ;; esac\n' \
  > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
: > "$Q"
: > "$ROWS"; printf 'x-os\tAR-9\tt-9\tready\tAR-9 t-9 — owed project=x-os\n' >> "$ROWS"
OUT=$(run 1 up bash "$H/bin/preplan-candidates.sh" x-os 2>/dev/null)
grep -qE '^TK-9[[:space:]]+t-9[[:space:]]+queued' <<<"$OUT" \
  && ok || bad "RED CORE: a ready ROW with no log line must be a 'queued' pre-plan candidate, got: [$OUT]"
OUT=$(run 0 up bash "$H/bin/preplan-candidates.sh" x-os 2>/dev/null)
grep -q 'TK-9' <<<"$OUT" \
  && bad "with the flag off preplan-candidates must see only the file: [$OUT]" || ok

# AND WITH THE LINE PRODUCTION ACTUALLY WRITES. bin/stale-owed-tickets.sh's
# line has no `project=` token, so before the fix bin/preplan-candidates.sh fell
# through to bin/project-of.sh mention-matching on the TITLE and dropped the
# line — `[]`, the ticket's RED unmet for the only shape that ships.
: > "$Q"
: > "$ROWS"; printf 'x-os\tAR-77\tt-77\tready\tAR-77 OWED-STALE 27h [in_progress/-] Fix the widget\n' >> "$ROWS"
OUT=$(run 1 up bash "$H/bin/preplan-candidates.sh" x-os 2>/dev/null)
grep -qE '^TK-77[[:space:]].*[[:space:]]queued$' <<<"$OUT" \
  && ok || bad "RED CORE: a ready row carrying the PRODUCTION stale-owed line must be a 'queued' pre-plan candidate, got: [$OUT]"
# The ticket-id column is the LINE's second field, and the stale-owed shape puts
# `OWED-STALE` there. Pre-existing and unchanged: the identical line has always
# gone into logs/READY-QUEUE.log and been parsed the same way. Asserted so the
# boundary is on the record rather than discovered later as a surprise.
grep -qE '^TK-77[[:space:]]+OWED-STALE[[:space:]]+queued$' <<<"$OUT" \
  && ok || bad "the tid column must be the line's 2nd field, as it is for the identical FILE line: [$OUT]"
# ...and it stays this project's work: another project's candidates must not
# pick it up off the title.
OUT=$(run 1 up bash "$H/bin/preplan-candidates.sh" other-os 2>/dev/null)
grep -q 'TK-77' <<<"$OUT" \
  && bad "x-os's ready row must not become other-os's pre-plan candidate: [$OUT]" || ok

# ══ 11. THE CALL SITES READ THE LIBRARY, NOT THEIR OWN GREP ═════════════════
# One definition of the ready set. A lane that kept its own grep would pass
# every behaviour test above and still be blind to a row.
for F in bin/triage-gate.sh bin/preplan-tick.sh bin/preplan-candidates.sh bin/stale-owed-tickets.sh bin/queue-line-drop.sh bin/lib/rt/scope.sh; do
  grep -q 'lib/ready-queue.sh' "$DIR/$F" \
    && ok || bad "$F must source bin/lib/ready-queue.sh"
done
# The triage brake and the PR-number scan must both go through it.
grep -q 'rq_any' "$DIR/bin/triage-gate.sh" \
  && ok || bad "bin/triage-gate.sh's queue brake must ask rq_any, not grep READY-QUEUE.log"
grep -q 'rq_fp' "$DIR/bin/triage-gate.sh" \
  && ok || bad "bin/triage-gate.sh's queue fingerprint must include the ready rows (rq_fp)"
grep -q 'rq_lines' "$DIR/bin/triage-gate.sh" \
  && ok || bad "bin/triage-gate.sh's PR-number scan must read the whole ready set (rq_lines)"
grep -q 'rq_put' "$DIR/bin/stale-owed-tickets.sh" \
  && ok || bad "bin/stale-owed-tickets.sh must INSERT a ready row instead of relying on the ssh append alone"
grep -q 'rq_drop' "$DIR/bin/queue-line-drop.sh" \
  && ok || bad "bin/queue-line-drop.sh must patch the row it just dropped from the file"
grep -q 'rq_lines' "$DIR/bin/preplan-tick.sh" \
  && ok || bad "bin/preplan-tick.sh must walk the ready set, not the file"
# THE FILE STAYS A LOG for one cycle: every writer still appends.
grep -q 'READY-QUEUE.log' "$DIR/bin/stale-owed-tickets.sh" \
  && ok || bad "the file append must stay for one cycle — the file is still the fallback"

# ══ 12. THE JOB ROW CARRIES THE BRANCH (the mislinked-PR half) ══════════════
# The driver is read as ONE text (tests/lib/rb-all.sh), so this assertion holds
# at every state of the bin/lib/rb/ split.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/rb-all.sh" 2>/dev/null)
[ -s "${RB_ALL:-/nonexistent}" ] \
  && ok || bad "could not flatten bin/run-build.sh through tests/lib/rb-all.sh"
grep -q 'job_artifact_put branch' "${RB_ALL:-/nonexistent}" \
  && ok || bad "bin/run-build.sh must record the branch it pushed on the job row (pr-url-reconcile reads it)"
# The dark stage module is a VERBATIM slice of the driver: a write added to one
# and not the other becomes a silent behaviour change the day the call site flips.
grep -q 'job_artifact_put branch' "$DIR/bin/lib/rb/plan.sh" \
  && ok || bad "bin/lib/rb/plan.sh must carry the same branch artifact write as the driver"
awk '/# >>> branch from the job row/{f=1} f; /# <<< branch from the job row/{exit}' \
  "$DIR/bin/pr-url-reconcile.sh" | grep -q 'job_for_record' \
  && ok || bad "bin/pr-url-reconcile.sh's branch_of must ask the JOB ROW before scraping pipeline.log"

# branch_of, lifted by its marker and driven: the row wins, and an absent row
# leaves today's scrape exactly as it is.
# The WHOLE function, lifted by its own opening and closing lines, so what runs
# below is the production text and not a paraphrase of it.
awk '/^branch_of\(\) \{/{f=1} f{print} f && /^\}/{exit}' \
  "$DIR/bin/pr-url-reconcile.sh" > "$T/branch_of.sh"
{ [ -s "$T/branch_of.sh" ] && grep -q '# >>> branch from the job row' "$T/branch_of.sh"; } \
  && ok || bad "bin/pr-url-reconcile.sh is missing branch_of or its '# >>> branch from the job row' marker"
mkdir -p "$T/rec"
printf 'pr create failed and no open PR exists on ticket/TK-9-r2: boom\n' > "$T/rec/pipeline.log"
drive_branch() { # drive_branch <artifact-branch-or-empty>
  ( export HARNESS="$H" JOB_BRANCH="$1"
    bash -c '
      job_for_record() { [ -n "${JOB_BRANCH:-}" ] || return 2; printf "job-1"; }
      job_artifacts()  { [ -n "${JOB_BRANCH:-}" ] || return 1; printf "branch\t%s\t-\n" "$JOB_BRANCH"; }
      . "$0"
      branch_of "$1" "$2"' "$T/branch_of.sh" "$T/rec" TK-9 ) 2>/dev/null
}
[ "$(drive_branch ticket/TK-9-r7)" = ticket/TK-9-r7 ] \
  && ok || bad "branch_of must prefer the job row's branch, got: $(drive_branch ticket/TK-9-r7)"
[ "$(drive_branch '')" = ticket/TK-9-r2 ] \
  && ok || bad "with no row, branch_of must scrape pipeline.log exactly as today, got: $(drive_branch '')"

# The lift above takes the FIRST `branch_of() {`; a second definition would be
# silently ignored and this whole section would test a dead function.
[ "$(grep -c '^branch_of() {' "$DIR/bin/pr-url-reconcile.sh")" = 1 ] \
  && ok || bad "bin/pr-url-reconcile.sh must define branch_of exactly once (the lift takes the first)"

# THE PROJECT ARGUMENT IS ACTUALLY HANDED OVER. job_for_record's memo AND its
# `result` feed are per project; a branch_of that dropped its third argument
# would resolve every record against an empty project, get rc 1, and quietly
# never find a row — the fail-open would look exactly like "no artifact yet".
# COVERAGE BOUNDARY, said out loud: job_for_record maps a record through the
# `result` artifact feed (newest ${JOB_FOR_RECORD_LIMIT:-500}), so a build that
# died before result-put, or one older than that window, has no mapping and
# falls through to the scrape — never worse than today, but not covered either.
JFR_ARGS="$T/jfr-args.txt"; : > "$JFR_ARGS"
( export HARNESS="$H" JFR_ARGS="$JFR_ARGS"
  bash -c '
    job_for_record() { printf "%s|%s\n" "${1:-}" "${2:-}" >> "$JFR_ARGS"; return 2; }
    job_artifacts()  { return 1; }
    . "$0"
    branch_of "$1" "$2" "$3"' "$T/branch_of.sh" "$T/rec" TK-9 x-os ) >/dev/null 2>&1
[ "$(cat "$JFR_ARGS")" = "x-os|rec" ] \
  && ok || bad "branch_of must hand <project> and <record> through to job_for_record, got: [$(cat "$JFR_ARGS")]"
# And the call site passes a project rather than letting it default to empty.
[ "$(grep -cE '\$\(branch_of "[^"]+" "[^"]+" "\$[A-Za-z_]+"\)' "$DIR/bin/pr-url-reconcile.sh")" = 1 ] \
  && ok || bad "the branch_of call site must pass the project through, got: $(grep -nE '\$\(branch_of ' "$DIR/bin/pr-url-reconcile.sh")"

# ══ 13. THE SSH DRAIN MUST NOT DELETE AN OUTAGE-FALLBACK BOX FILE ═══════════
# bin/fly-dispatch.sh pulls leftover build-queue files off a box and deletes
# the ones the DB says it already has custody of. That file is written in
# exactly one place — bin/run-build.sh's outage fallback, when queue_put failed
# — under an alert that says verbatim "The build is NOT lost". `ready` and
# `dropped` join the status vocabulary with THIS slice and neither is custody:
# nobody owns a launch for that key, which is precisely what rc 2 (no row at
# all) means to this loop. A drain that reads "not queued" as "mine" deletes a
# build that only exists as that file, and the only record says it was safe.
# The production block is lifted by its own markers and driven, so what runs
# here is the drain's text and not a paraphrase of it.
# LIFTED ON THE STATEMENT ITSELF, not on this slice's markers: a lift keyed to
# a comment the fix introduced would come back EMPTY against the code before it
# and every assertion below would pass on nothing. The anchor is the `if
# command -v queue_status` guard and its own closing `fi` at that indent, which
# is the shape this block has had since the ledger check landed.
awk '/^    if command -v queue_status /{f=1} f{print} f && /^    fi$/{exit}' \
  "$DIR/bin/fly-dispatch.sh" > "$T/ledger.sh"
{ [ -s "$T/ledger.sh" ] && grep -q 'queue_status' "$T/ledger.sh" && grep -q '^    fi$' "$T/ledger.sh"; } \
  && ok || bad "could not lift bin/fly-dispatch.sh's queue_status block (the 'if command -v queue_status' guard through its closing fi)"
grep -q '# >>> the ledger outranks the leftover file' "$DIR/bin/fly-dispatch.sh" \
  && ok || bad "bin/fly-dispatch.sh should mark the block so a reader finds what this section drives"
{ printf '%s\n' \
    'set -u' \
    'queue_status() { [ -n "${KST_STUB:-}" ] || return 2; printf "%s" "$KST_STUB"; }' \
    'timeout() { printf "RM %s\n" "$*"; }' \
    'say() { :; }' \
    'P=x-os; IP=10.0.0.5' \
    'for RF in TK-77.json; do' \
    '  K="${RF%.json}"; K="${K%.failed}"'
  cat "$T/ledger.sh"
  printf '%s\n' '  printf "PULL %s\n" "$RF"' 'done'
} > "$T/drain.sh"
bash -n "$T/drain.sh" 2>/dev/null \
  && ok || bad "the lifted drain block does not parse — the markers must bracket a complete statement"
drain() { ( export KST_STUB="$1"; bash "$T/drain.sh" ) 2>/dev/null; }
# RED CORE: the two new words must fall through to the pull.
[ "$(drain ready)" = "PULL TK-77.json" ] \
  && ok || bad "RED CORE: a 'ready' row must NOT make the drain delete the box file (an outage-fallback build, lost under a 'NOT lost' alert), got: [$(drain ready)]"
[ "$(drain dropped)" = "PULL TK-77.json" ] \
  && ok || bad "RED CORE: a 'dropped' row must NOT make the drain delete the box file, got: [$(drain dropped)]"
# ...and today's behaviour is unchanged on every other answer.
[ "$(drain queued)" = "PULL TK-77.json" ] \
  && ok || bad "a 'queued' row must still fall through to the pull, got: [$(drain queued)]"
[ "$(drain '')" = "PULL TK-77.json" ] \
  && ok || bad "rc 2 (no row at all) must still fall through to the pull, got: [$(drain '')]"
for ST in claimed done failed; do
  OUT=$(drain "$ST")
  { grep -q "^RM .*rm -f /root/harness/state/build-queue/x-os/TK-77.json" <<<"$OUT" \
      && ! grep -q '^PULL' <<<"$OUT"; } \
    && ok || bad "custody ($ST) must still drop the leftover file and skip the pull, got: [$OUT]"
done
# The list is CLOSED, not "anything that is not queued": a status this repo has
# not defined yet must not silently become custody-by-default either way — the
# assertion that matters is that the three nobody-owns-a-launch words are named.
grep -qE 'queued\|ready\|dropped' "$T/ledger.sh" \
  && ok || bad "the drain must name the nobody-owns-a-launch words explicitly, not test != queued"
# The contract comment on queue_status must say what it can print, or the next
# caller writes the same '!= queued' test against a vocabulary that grew.
awk '/^# queue_status <project> <key>/{f=1} f{print} f && /^queue_status\(\) \{/{exit}' \
  "$DIR/bin/lib/jobs/queue.sh" | grep -q 'ready' \
  && ok || bad "bin/lib/jobs/queue.sh's queue_status contract must list the statuses it can print, including ready/dropped"

# ══ 14. THE SESSION'S QUEUE SCOPE READS THE SET THE GATE BRAKED ON ══════════
# The gate fires on a row (§3, rq_any) — but the prompt the paid session reads
# is built in bin/lib/rt/scope.sh's queue-pending arm. A scope that kept its own
# grep of READY-QUEUE.log collapses to "(none)" for a row-only ticket: the tick
# is bought, the session runs the full SOP against the same file, and the row is
# never surfaced. The production assignment is lifted verbatim and driven.
awk '/^ *QLINES=\$\(/{print; exit}' "$DIR/bin/lib/rt/scope.sh" > "$T/qlines.sh"
[ -s "$T/qlines.sh" ] \
  && ok || bad "could not lift the QLINES assignment from bin/lib/rt/scope.sh"
grep -qE 'QLINES=\$\(grep ' "$T/qlines.sh" \
  && bad "bin/lib/rt/scope.sh's QLINES must not be its own grep of READY-QUEUE.log: $(cat "$T/qlines.sh")" || ok
: > "$Q"
: > "$ROWS"; printf 'x-os\tAR-77\tt-77\tready\tAR-77 OWED-STALE 27h [in_progress/-] Fix the widget\n' >> "$ROWS"
OUT=$(lib 1 up 'PROJECT=x-os; . '"$T"'/qlines.sh; printf "%s" "${QLINES:-}"')
grep -q '^TK-77 OWED-STALE' <<<"$OUT" \
  && ok || bad "RED CORE: a row-only ticket must reach the SESSION's queue scope, or the tick is bought for a prompt that says the queue is empty, got: [$OUT]"
# A row for another project must not reach this project's prompt.
: > "$ROWS"; printf 'other-os\tZZ-4\tt-4\tready\tZZ-4 t-4 — owed project=other-os\n' >> "$ROWS"
OUT=$(lib 1 up 'PROJECT=x-os; . '"$T"'/qlines.sh; printf "%s" "${QLINES:-}"')
grep -q 'ZZ-4' <<<"$OUT" \
  && bad "another project's ready row must not reach x-os's session prompt: [$OUT]" || ok
# FLAG OFF IS TODAY, BYTE FOR BYTE: exactly the file's lines, no request.
printf 'TK-1 t-1 — waiting project=x-os\n' > "$Q"
: > "$ROWS"; printf 'x-os\tAR-77\tt-77\tready\tAR-77 OWED-STALE 27h [x/-] w\n' >> "$ROWS"
OUT=$(lib 0 up 'PROJECT=x-os; . '"$T"'/qlines.sh; printf "%s" "${QLINES:-}"')
[ "$OUT" = 'TK-1 t-1 — waiting project=x-os' ] \
  && ok || bad "flag off, the session scope must be exactly the file's lines, got: [$OUT]"
[ "$(qreqs)" = 0 ] \
  && ok || bad "flag off, the session scope must make NO /api/queue request, got $(qreqs)"
# An unreachable worker leaves the file's lines, never an empty prompt.
OUT=$(lib env down 'PROJECT=x-os; . '"$T"'/qlines.sh; printf "%s" "${QLINES:-}"')
[ "$OUT" = 'TK-1 t-1 — waiting project=x-os' ] \
  && ok || bad "an outage must degrade the session scope to the file, got: [$OUT]"

# ══ 15. THE PRE-PLAN HOUSEKEEPING SWEEP MUST NOT EAT A LIVE PLAN ════════════
# bin/preplan-tick.sh is `set -u` only — but sourcing bin/lib/ready-queue.sh
# pulls in bin/jobs-client.sh, which sets `-o pipefail` for the whole shell. The
# sweep asked `printf … | grep -q "^$k "`; grep -q exits at the first match, so
# above the pipe buffer printf takes SIGPIPE, the pipeline is 141, and the `||`
# deletes the pre-plan of a key that IS on the queue. Same shape as the BH-1044
# dedupe read. Both sweeps are lifted by their markers and driven under pipefail
# with a ready set past the buffer.
# Lifted on the `find` statement and its own `done`, for the same reason §13 is:
# a marker this slice introduced lifts nothing from the code before it.
awk -v out="$T/hk" '/^find "\$HARNESS\/plans" -maxdepth 1 -mindepth 1 -type d -mmin \+1440/{f=1; n++} f{print > (out n ".sh")} f && /^done$/{f=0}' \
  "$DIR/bin/preplan-tick.sh"
{ [ -s "$T/hk1.sh" ] && [ -s "$T/hk2.sh" ] && grep -q '^done$' "$T/hk1.sh"; } \
  && ok || bad "could not lift both pre-plan housekeeping sweeps (legacy + fan-out) from bin/preplan-tick.sh"
[ "$(grep -c '# >>> queue housekeeping' "$DIR/bin/preplan-tick.sh")" = 2 ] \
  && ok || bad "both housekeeping sweeps should carry the '# >>> queue housekeeping' marker so a reader finds what this section drives"
cmp -s "$T/hk1.sh" "$T/hk2.sh" \
  && ok || bad "the two housekeeping sweeps must stay identical — the fan-out adds candidates, never a second retention rule"
# ~180KB of ready set, with the key to keep as the FIRST line so grep -q exits
# while printf still has bytes to write. A 50-line set cannot reproduce this.
BIG=$(awk 'BEGIN{printf "TK-77 t-77 — ready project=x-os\n"; for(i=1;i<=6000;i++) printf "ZZ-%d t-%d — pad project=x-os\n", i, i}')
sweep() { # sweep <ready-set>
  rm -rf "$T/pl"; mkdir -p "$T/pl/plans/x-os-TK-77" "$T/pl/plans/x-os-TK-99"
  printf 'plan\n' > "$T/pl/plans/x-os-TK-77/plan.md"
  printf 'plan\n' > "$T/pl/plans/x-os-TK-99/plan.md"
  touch -t 202001010000 "$T/pl/plans/x-os-TK-77" "$T/pl/plans/x-os-TK-99"
  ( set -uo pipefail; HARNESS="$T/pl"; RQL="$1"; . "$T/hk1.sh" ) 2>/dev/null
}
sweep "$BIG"
[ -d "$T/pl/plans/x-os-TK-77" ] \
  && ok || bad "RED CORE: with a ready set past the pipe buffer, the sweep must keep the pre-plan of a key that IS on the queue (pipefail + SIGPIPE = rc 141 = 'not on the queue')"
[ -d "$T/pl/plans/x-os-TK-99" ] \
  && bad "a pre-plan whose key left the queue must still be dropped (big set)" || ok
# ...and the small-set behaviour is unchanged.
sweep 'TK-77 t-77 — ready project=x-os'
[ -d "$T/pl/plans/x-os-TK-77" ] \
  && ok || bad "the sweep must keep a pre-plan whose key is on the queue (small set)"
[ -d "$T/pl/plans/x-os-TK-99" ] \
  && bad "a pre-plan whose key left the queue must still be dropped (small set)" || ok
# No pipeline left at either site: the next edit must not reintroduce it.
grep -q 'printf .*"\$RQL" | grep -q' "$DIR/bin/preplan-tick.sh" && bad "the housekeeping sweep must read \$RQL with a here-string, not a pipe into grep -q" || ok  # determinism: ok race-sigpipe-echo the shape is a grep PATTERN that asserts it is absent from bin/; no pipe runs here

# ══ 16. THE LIB'S OWN DEDUPE MUST NOT PIPE INTO grep -q EITHER ═════════════
# Round-3 N2. rq_lines de-duplicates a key present in BOTH halves with
# `printf '%s\n' "$keys" | grep -qxF "$key"`, and it runs under the SAME
# pipefail §15 is about: bin/lib/ready-queue.sh sources bin/jobs-client.sh.
# Above the pipe buffer grep -q exits on the match while printf still has bytes
# to write, printf takes SIGPIPE, the pipeline is 141, the `&& continue` never
# fires — and the row's line is emitted A SECOND TIME for a key the file
# already carried. Not a deletion like §15, but a queue that says a ticket is
# owed twice is a queue two lanes disagree about, and the fix is the same shape.
# The key to match sorts FIRST (the list is `sort -u`'d) so grep exits early.
: > "$ROWS"; printf 'x-os\tAA-1\tt-1\tready\tAA-1 t-1 — owed project=x-os\n' >> "$ROWS"
awk 'BEGIN{printf "AA-1 t-1 — waiting project=x-os\n"; for(i=1;i<=12000;i++) printf "ZZ-%d t-%d — pad project=x-os\n", i, i}' > "$Q"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
[ "$(grep -c '^AA-1 ' <<<"$OUT")" = 1 ] \
  && ok || bad "RED CORE: with the file's key list past the pipe buffer, a key on BOTH the file and a row must still be ONE line (pipefail + SIGPIPE = rc 141 = 'not in the file'), got $(grep -c '^AA-1 ' <<<"$OUT")"
# The small-set behaviour is unchanged, and a row whose key is NOT on the file
# still comes out — the de-dupe must not become "drop every row".
: > "$ROWS"
printf 'x-os\tAA-1\tt-1\tready\tAA-1 t-1 — owed project=x-os\n' >> "$ROWS"
printf 'x-os\tAR-5\tt-5\tready\tAR-5 t-5 — owed project=x-os\n' >> "$ROWS"
printf 'AA-1 t-1 — waiting project=x-os\n' > "$Q"
OUT=$(lib 1 up 'rq_lines "$HARNESS" x-os')
[ "$(grep -c '^AA-1 ' <<<"$OUT")" = 1 ] \
  && ok || bad "small set: a key on both halves must be ONE line, got: [$OUT]"
grep -q '^TK-5 ' <<<"$OUT" \
  && ok || bad "a row whose key is NOT on the file must still be emitted, got: [$OUT]"
# No pipeline left at the site: the next edit must not reintroduce it.
grep -q 'printf .*"\$keys" | grep -q' "$DIR/bin/lib/ready-queue.sh" && bad "rq_lines must test key membership without piping into grep -q" || ok  # determinism: ok race-sigpipe-echo the shape is a grep PATTERN that asserts it is absent from bin/; no pipe runs here

echo "ready-queue-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
