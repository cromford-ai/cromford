#!/bin/bash
# tests/parks-writers.bh-9075-test.sh — BH-9075 (BH-9067.3): the parks client
# (bin/lib/jobs/parks.sh) and the parks writers (bin/lib/parks-write.sh) with
# their three real call sites: the rendered bin/fly-pool.sh reap lines, the
# br_set_outcome line in bin/lib/br/record.sh and the conductor tick-end sync.
#
#   W1  parks_put: one PUT, `upserted=<n>`, rc 0
#   W2  parks_changed: row / hotfix / next lines, keyset paging, truncated
#   W3  a failure prints NOTHING and answers rc 1 (no answer, 500, bad JSON,
#       no next), for parks_changed and parks_put
#   W4  a failed flush keeps the outbox; the next flush sends and deletes; a
#       held lock is rc 0 with no send; over PW_OUTBOX_MAX the oldest go, the
#       marker state/parks-outbox/.dropped-at is written and the resolver
#       cursor file is not touched (the resolver reads it as 0, D14)
#   W5  the reason decision rule equals the REAL br_from_queue, row for row
#   W6  the two rendered bin/fly-pool.sh lines, run with fixture vars, give the
#       8-field row br_from_queue gives; MHF=true gives state hotfix
#   W7  pw_conductor_sync: park then un-park gives parked then done; the row
#       read back equals br_conductor_emit's tuple; an unchanged sync sends nothing
#   W8  the real br_set_outcome: ABANDONED notes done, rebuild-landed nothing
#   W9  PW_ENABLED=0 writes no outbox file and makes 0 calls
#
# No network: _jobs_req is tests/lib/parks-fake.bh-9075.sh, a local fake of
# the route contract. Each case uses its own table file and its own project ids.
# Run from anywhere: tests/parks-writers.bh-9075-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

export HARNESS="$T/h"; H="$HARNESS"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/br" "$H/bin/lib/mc" "$H/state" "$H/logs" "$H/locks" "$H/builds" || exit 1
# The writers and what they source (bin/lib/jobs/parks.sh, bin/lib/br/keys.sh),
# and bin/lib/br/ for the real br_from_queue, br_set_outcome and br_reason_of.
scratch_install_closure bin/lib/parks-write.sh "$H" >/dev/null || exit 1
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
[ -f "$H/bin/lib/jobs/parks.sh" ] || { echo "the closure of bin/lib/parks-write.sh is incomplete"; exit 1; }
# shellcheck source=tests/lib/parks-fake.bh-9075.sh
. "$DIR/tests/lib/parks-fake.bh-9075.sh" || exit 1
# shellcheck source=bin/lib/jobs/parks.sh
. "$H/bin/lib/jobs/parks.sh" || exit 1
# shellcheck source=bin/lib/parks-write.sh
. "$H/bin/lib/parks-write.sh" || exit 1

# fresh <case> — a new table, call log and outbox for one case.
fresh() {
  export PARKS_FAKE_DB="$T/db-$1.json" PARKS_FAKE_CALLS="$T/calls-$1.txt" PARKS_FAKE_BODIES="$T/bodies-$1.txt"
  printf '[]' > "$PARKS_FAKE_DB"; : > "$PARKS_FAKE_CALLS"; : > "$PARKS_FAKE_BODIES"
  unset PARKS_FAKE_FAIL PARKS_FAKE_FAIL_PATH PW_ENABLED PW_OUTBOX_MAX PW_BATCH
  scratch_rm "$H/state/parks-outbox" 2>/dev/null; scratch_rm "$H/state/parks-conductor" 2>/dev/null
  scratch_rm "$H/state/blocked-resolver" 2>/dev/null
}
calls() { grep -c -- "$1" "$PARKS_FAKE_CALLS" 2>/dev/null || true; }
outbox_n() { find "$H/state/parks-outbox" -maxdepth 1 -name '*.tsv' 2>/dev/null | wc -l; }
# readback <project> <ck> — the 12 columns of one row through the real client.
readback() { parks_changed "$1" 0 1000 0 | awk -F'\t' -v ck="$2" '$1 == "row" && $3 == ck { $1 = ""; sub(/^ /, ""); print }' OFS='\t' | sed 's/^\t//'; }
# as8 <12-col line> — the 8-field queue candidate row a mirror row becomes.
as8() { awk -F'\t' -v OFS='\t' '{ print "queue", $1, $2, $6, $7, $8, $9, $12 }' <<<"$1"; }

# ── W1 ──────────────────────────────────────────────────────────────────────
fresh w1
printf 'w1proj\tw1proj-TK-1\tqueue\tparked\t-\tpool-died-twice\t-\t-\tTS-1\t%s\tfly-pool\t-\nw1proj\tw1proj-TK-2\tqueue\thotfix\t-\tpool-deferred-max\t-\t-\tTS-2\t%s\tfly-pool\t77\n' "$NOW" "$NOW" > "$T/w1.tsv"
OUT=$(parks_put "$T/w1.tsv"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "upserted=2" ] && ok || bad "W1 parks_put rc=$RC out='$OUT' (want rc 0, upserted=2)"
[ "$(calls 'PUT /api/parks')" = 1 ] && ok || bad "W1 one PUT for two rows (calls: $(cat "$PARKS_FAKE_CALLS"))"
[ "$(jq -r '[.[] | select(.ck == "w1proj-TK-2")][0].parked_at' "$PARKS_FAKE_DB")" = 77 ] && ok || bad "W1 parked_at 77 must be sent as a number"
[ "$(jq -r '[.[] | select(.ck == "w1proj-TK-1")][0].parked_at' "$PARKS_FAKE_DB")" = null ] && ok || bad "W1 parked_at - must be sent as null"

# ── W2 ──────────────────────────────────────────────────────────────────────
fresh w2
jq -n --argjson n "$NOW" '[range(0;5) as $i | {project:"w2proj", ck:"w2proj-TK-\($i)", source:"queue", state:(if $i == 4 then "hotfix" else "parked" end),
   head:"-", reason:"pool-died-twice\tx", url:"-", rec:"-", ticket:"TK-\($i)", updated_at:($n - 100 + ($i / 2 | floor)), writer:"fly-pool", parked_at:null}]' > "$PARKS_FAKE_DB"
OUT=$(parks_changed w2proj "$((NOW - 1000))" 3 1); RC=$?
[ "$RC" = 0 ] && ok || bad "W2 rc=$RC"
[ "$(grep -c '^row	' <<<"$OUT")" = 3 ] && ok || bad "W2 page 1 must hold 3 row lines: $OUT"
[ "$(grep -c '^hotfix	' <<<"$OUT")" = 1 ] && ok || bad "W2 hotfix=1 must add the hotfix row: $OUT"
LAST=$(tail -n 1 <<<"$OUT")
[ "$LAST" = "next	$((NOW - 99)):w2proj-TK-2	1" ] && ok || bad "W2 last line must be next<TAB><ts>:<ck><TAB>1, got '$LAST'"
[ "$(grep '^row	' <<<"$OUT" | head -1 | awk -F'\t' '{print NF}')" = 13 ] && ok || bad "W2 a row line is the word plus 12 columns"
grep -q 'pool-died-twice x' <<<"$OUT" && ok || bad "W2 a tab inside a value must print as a space"
OUT2=$(parks_changed w2proj "$((NOW - 99)):w2proj-TK-2" 3 0)
[ "$(grep -c '^row	' <<<"$OUT2")" = 2 ] && [ "$(tail -n 1 <<<"$OUT2" | cut -f3)" = 0 ] && ok \
  || bad "W2 page 2 by the keyset token must hold the last 2 rows, truncated 0: $OUT2"

# ── W3 ──────────────────────────────────────────────────────────────────────
fresh w3
printf 'w3proj\tw3proj-TK-1\tqueue\tparked\t-\tpool-died-twice\t-\t-\tTS-1\t%s\tfly-pool\t-\n' "$NOW" > "$T/w3.tsv"
for mode in noanswer 500 badjson nonext; do
  export PARKS_FAKE_FAIL=$mode
  OUT=$(parks_changed w3proj 0 10 1); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "W3 parks_changed under $mode: rc=$RC out='$OUT' (want rc 1, no output)"
  OUT=$(parks_put "$T/w3.tsv"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "W3 parks_put under $mode: rc=$RC out='$OUT' (want rc 1, no output)"
done
unset PARKS_FAKE_FAIL
OUT=$(parks_changed 'BAD PROJECT' 0); [ $? = 1 ] && [ -z "$OUT" ] && ok || bad "W3 a bad project is rc 1 with no request"
OUT=$( unset -f _jobs_req; HARNESS="$T/nowhere" parks_changed w3proj 0 ); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "W3 no client: rc=$RC out='$OUT'"

# ── W4 ──────────────────────────────────────────────────────────────────────
fresh w4
export PARKS_FAKE_FAIL=500
pw_note w4proj w4proj-TK-1 queue parked - pool-died-twice - - TK-1 fly-pool -; RC=$?
[ "$RC" = 0 ] && ok || bad "W4 pw_note must answer rc 0 when the worker fails (rc=$RC)"
[ "$(outbox_n)" = 1 ] && ok || bad "W4 THE FIX: a failed flush must KEEP the outbox file (have $(outbox_n))"
grep -q 'pw_flush: PUT /api/parks failed' "$H/logs/parks-write.log" && ok || bad "W4 a failed flush writes one log line"
pw_note w4proj w4proj-TK-2 queue parked - pool-died-twice - - TK-2 fly-pool -
[ "$(grep -c 'pw_flush: PUT' "$H/logs/parks-write.log")" = 1 ] && ok || bad "W4 the failure line is throttled (one per hour)"
[ "$(outbox_n)" = 2 ] && ok || bad "W4 both notes are kept (have $(outbox_n))"
unset PARKS_FAKE_FAIL
# A held lock: rc 0, no send, nothing deleted.
exec 9>"$H/locks/parks-outbox.lock"; flock -n 9
N0=$(calls 'PUT /api/parks')
( pw_flush ); RC=$?
[ "$RC" = 0 ] && [ "$(calls 'PUT /api/parks')" = "$N0" ] && [ "$(outbox_n)" = 2 ] && ok \
  || bad "W4 a held lock must be rc 0 with no send (rc=$RC, puts $N0 -> $(calls 'PUT /api/parks'), files $(outbox_n))"
exec 9>&-
pw_flush
[ "$(outbox_n)" = 0 ] && ok || bad "W4 the next flush with the worker up must send and delete (left $(outbox_n))"
[ "$(jq 'length' "$PARKS_FAKE_DB")" = 2 ] && ok || bad "W4 both rows reached the table"
# Over the cap.
export PARKS_FAKE_FAIL=noanswer PW_OUTBOX_MAX=3
mkdir -p "$H/state/blocked-resolver/parks"; echo 5 > "$H/state/blocked-resolver/parks/w4proj.cursor"
for i in 1 2 3 4 5; do pw_note w4proj "w4proj-TK-c$i" queue parked - pool-died-twice - - "TK-c$i" fly-pool -; done
[ "$(outbox_n)" = 3 ] && ok || bad "W4 PW_OUTBOX_MAX=3 keeps 3 files (have $(outbox_n))"
[ -s "$H/state/parks-outbox/.dropped-at" ] && ok || bad "W4 over the cap pw_flush writes state/parks-outbox/.dropped-at"
[ "$(cat "$H/state/blocked-resolver/parks/w4proj.cursor" 2>/dev/null)" = 5 ] && ok || bad "W4 over the cap the resolver cursor file is not touched"
grep -q 'outbox over PW_OUTBOX_MAX=3' "$H/logs/parks-write.log" && ok || bad "W4 over the cap writes a log line"
unset PARKS_FAKE_FAIL PW_OUTBOX_MAX

# ── W5 ──────────────────────────────────────────────────────────────────────
# The real br_from_queue over one queue row with the reason, against
# pw_queue_park over the same reason, read back through the real client.
w5_files() { # w5_files <reason> — br_from_queue's rows
  ( ST="$H/state/blocked-resolver"; ONLY=""
    # shellcheck source=bin/lib/br/record.sh
    . "$H/bin/lib/br/record.sh"; . "$H/bin/lib/br/discovery.sh"
    queue_list() { printf 'w5proj\tTS-5\t5\tfailed\t-\t1\t-\t-\t%s\t-\n' "$W5R"; }
    W5R="$1" br_from_queue )
}
for R in "died 2 times (state=gone) — parked for the blocked-resolver" "died twice" \
         "deferred 3 times (no slot) — parked for the blocked-resolver" "spawn cap reached; deferred to a human" \
         "deferred 3 times (RUNNER_EXHAUSTED)" "deferred 3 times (lane failed class=auth)" "died once" \
         "PR_CREATE_FAILED: died 2 times"; do
  fresh w5
  WANT=$(w5_files "$R")
  pw_queue_park w5proj TK-5 "$R" false
  GOT=""; L=$(readback w5proj w5proj-TK-5); [ -n "$L" ] && GOT=$(as8 "$L")
  [ "$GOT" = "$WANT" ] && ok || bad "W5 '$R': parks row '$GOT' != br_from_queue '$WANT'"
done
[ -n "$(w5_files 'died twice')" ] && [ -z "$(w5_files 'died once')" ] && ok || bad "W5 the table must hold a park and a near miss"

# ── W6 ──────────────────────────────────────────────────────────────────────
FP="$DIR/bin/fly-pool.sh"
mapfile -t LINES < <(grep -E '^[[:space:]]*command -v pw_queue_park >/dev/null 2>&1 && pw_queue_park ' "$FP" | sed 's/^[[:space:]]*//')
[ "${#LINES[@]}" = 2 ] && ok || bad "W6 bin/fly-pool.sh must carry the 2 pw_queue_park lines (have ${#LINES[@]})"
grep -q '^\[ -r "\$HARNESS/bin/lib/parks-write.sh" \] && \. "\$HARNESS/bin/lib/parks-write.sh"' "$FP" && ok \
  || bad "W6 the render must source bin/lib/parks-write.sh (fragment 3400, before the reap loop)"
# Each line is the line after its own QROW park line in the render.
AFTER=$(grep -A1 'QROW failed "$KEY" "deferred $DNEXT times ($DWHY)' "$FP")
grep -q 'pw_queue_park "$P" "$KEY" "deferred $DNEXT times ($DWHY)" "$MHF"' <<<"$AFTER" && ok \
  || bad "W6 the deferral line must follow the deferral QROW park"
AFTER=$(grep -A1 'QROW failed "$KEY" "died $DNEXT times' "$FP")
grep -q 'pw_queue_park "$P" "$KEY" "died $DNEXT times" "$MHF"' <<<"$AFTER" && ok \
  || bad "W6 the death line must follow the death QROW park"
for i in 0 1; do
  for MHF in false true; do
    fresh "w6$i$MHF"
    P=w6proj; KEY=TK-6; DNEXT=3; DWHY="no slot"; MSTATE=gone
    eval "${LINES[$i]}"
    case "$i" in 0) QR="deferred $DNEXT times ($DWHY) — parked for the blocked-resolver" ;; *) QR="died $DNEXT times (state=${MSTATE:-gone}) — parked for the blocked-resolver" ;; esac
    WANT=$( ( ST="$H/state/blocked-resolver"; ONLY=""; . "$H/bin/lib/br/record.sh"; . "$H/bin/lib/br/discovery.sh"
              queue_list() { printf 'w6proj\tTS-6\t6\tfailed\t-\t1\t-\t-\t%s\t-\n' "$QR"; }; br_from_queue ) )
    L=$(readback w6proj w6proj-TK-6)
    [ -n "$WANT" ] && [ "$(as8 "$L")" = "$WANT" ] && ok || bad "W6 line $i MHF=$MHF: '$(as8 "$L")' != br_from_queue '$WANT'"
    ST6=$(cut -f4 <<<"$L"); W6=$([ "$MHF" = true ] && echo hotfix || echo parked)
    [ "$ST6" = "$W6" ] && ok || bad "W6 line $i MHF=$MHF must store state $W6 (got $ST6)"
  done
done

# ── W7 ──────────────────────────────────────────────────────────────────────
fresh w7
eval "$(sed -n '/^mc_record_for() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
MC_H="$H"; export MC_ROWS="$T/w7-rows.tsv"
URL=https://github.com/o/w7proj/pull/41
REC="$H/builds/w7proj-TK-41-202611010000"; mkdir -p "$REC"
printf 'PR_CREATED %s\n' "$URL" > "$REC/RESULT"; printf '{"key":"TK-41"}\n' > "$REC/ticket-meta.json"
printf 'o/w7proj#41\tBLOCKED_HUMAN\t1700000000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\t%s\n' "$URL" > "$MC_ROWS"
printf 'o/w7proj#42\tWAIT_CI\t1700000000\tdef456\t-\t-\t-\thttps://github.com/o/w7proj/pull/42\n' >> "$MC_ROWS"
printf 'o/other#43\tBLOCKED_HUMAN\t1700000000\tdef456\t-\t-\tred-twice\thttps://github.com/o/other/pull/43\n' >> "$MC_ROWS"
pw_conductor_sync w7proj o/w7proj
L=$(readback w7proj o-w7proj-41)
[ "$(cut -f4 <<<"$L")" = parked ] && ok || bad "W7 a BLOCKED_HUMAN row notes parked: '$L'"
GOT=$( . "$H/bin/lib/br/ladder.sh"; IFS=$'\t' read -r p ck _s _st _h why url rec tk _u _w pa <<<"$L"
       printf 'conductor\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$p" "$ck" "$(br_reason_of "$why")" "$url" "$rec" "$tk" "$pa" )
WANT=$(printf 'conductor\tw7proj\to-w7proj-41\tmerge-failed-twice\t%s\t%s\tTS-41\t1700000000' "$URL" "$REC")
[ "$GOT" = "$WANT" ] && ok || bad "W7 read back '$GOT' != br_conductor_emit's '$WANT'"
[ -z "$(readback w7proj o-w7proj-42)" ] && [ -z "$(readback w7proj o-other-43)" ] && ok || bad "W7 a WAIT_CI row and another repo's row are not noted"
N0=$(calls 'PUT /api/parks'); pw_conductor_sync w7proj o/w7proj
[ "$(calls 'PUT /api/parks')" = "$N0" ] && ok || bad "W7 an unchanged sync sends nothing"
printf 'o/w7proj#41\tMERGED\t1700000500\tabc123\tabc123\t-\t-\t%s\n' "$URL" > "$MC_ROWS"
pw_conductor_sync w7proj o/w7proj
[ "$(cut -f4 <<<"$(readback w7proj o-w7proj-41)")" = done ] && ok || bad "W7 an un-park notes done: '$(readback w7proj o-w7proj-41)'"
[ "$(cut -f6 <<<"$(readback w7proj o-w7proj-41)")" = "merge-failed-twice: gh pr merge refused" ] && ok || bad "W7 a done note keeps the stored reason (- keeps)"
[ ! -s "$H/state/parks-conductor/w7proj.tsv" ] && ok || bad "W7 the fingerprint file drops the un-parked ck"

# ── W8 ──────────────────────────────────────────────────────────────────────
fresh w8
OUT=$( ST="$H/state/blocked-resolver"; STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
       . "$H/bin/lib/br/record.sh"
       br_set_outcome w8proj w8proj-TK-9 ABANDONED; echo "rc=$?"
       br_set_outcome w8proj w8proj-TK-10 rebuild-landed; echo "rc=$?" )
[ "$OUT" = "rc=0
rc=0" ] && ok || bad "W8 br_set_outcome keeps rc 0 (got $OUT)"
[ "$(cut -f4 <<<"$(readback w8proj w8proj-TK-9)")" = done ] && ok || bad "W8 ABANDONED must note done (got '$(readback w8proj w8proj-TK-9)')"
[ "$(jq -r '.outcome' "$H/state/blocked-resolver/w8proj/w8proj-TK-9.json")" = ABANDONED ] && ok || bad "W8 the record file still gets its outcome"
[ -z "$(readback w8proj w8proj-TK-10)" ] && ok || bad "W8 rebuild-landed must note nothing"
[ "$(calls 'PUT /api/parks')" = 1 ] && ok || bad "W8 exactly one PUT for the two outcomes (calls: $(calls 'PUT /api/parks'))"

# ── W9 ──────────────────────────────────────────────────────────────────────
fresh w9
export PW_ENABLED=0
pw_note w9proj w9proj-TK-1 queue parked - pool-died-twice - - TK-1 fly-pool -
pw_queue_park w9proj TK-2 "died twice" false
[ "$(outbox_n)" = 0 ] && [ ! -s "$PARKS_FAKE_CALLS" ] && ok || bad "W9 PW_ENABLED=0 must write no file ($(outbox_n)) and make 0 calls ($(wc -l < "$PARKS_FAKE_CALLS"))"
unset PW_ENABLED

echo "parks-writers.bh-9075: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
