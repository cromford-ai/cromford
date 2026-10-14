#!/bin/bash
# reads-run-build: raw — its §4 one-copy pin asserts the ACTIVE_KEY block is ABSENT
# from the raw driver and present once in bin/lib/rb/gates.sh: since the BH-572
# cut there is one copy, and only a raw read of the driver can see a second copy
# pasted back into it. The flatten would show the module's copy in the driver's
# place and could not tell the two apart.
# tests/queue-rows-flags.bh-1026-test.sh — the queues-are-rows CONTRACT slice
# (BH-1026.0 / BH-1364): three flag readers, the one shared `ACTIVE_KEY` read,
# and `queue_claim`'s optional machine.
#
# WHAT THIS SLICE PROMISES. It lands DARK. All three settings rows seed `'0'`,
# so with it merged the fleet behaves byte for byte as it does today — and the
# only way to prove that is to drive every path with the flag off and watch it
# answer exactly what the file answered.
#
# WHY DRIVEN AND NOT GREPPED. `build_queue_active_key` exists to replace a
# `jq -r '.key // ""'` that lives in TWO files, and both of those reads are a
# DEDUPE guard: a missed active job spawns a second machine for a key that is
# already building (the TK-70 shape). A grep for the function name would pass on
# a version that returned empty on an outage — which is precisely the bug,
# because an empty answer there reads as "nothing is active" and the guard opens.
# So the two blocks are EXTRACTED FROM THE REAL SCRIPTS and executed, and every
# case below asks them the question rather than asking their source text.
#
# Run from anywhere: tests/queue-rows-flags.bh-1026-test.sh   (exit 0 = all pass)
# No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state/fly" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
# BH-1194: the client is a shim over bin/lib/jobs/ and refuses to half-load, so
# a fixture that copies it must copy its modules too.
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR"/bin/lib/env-path.sh "$H/bin/lib/" 2>/dev/null

# ── The worker, as a file-backed stub ───────────────────────────────────────
# ROWS is $T/rows.tsv as `project<TAB>ticket_key<TAB>status<TAB>machine`, so a
# test can put a claimed row in the queue without going through the client.
# A `-` in the machine column is a row claimed before this slice: NULL, which is
# what every row in the live table is today.
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
    K="${URL##*/}"; V=absent
    [ "$K" = build_queue_rows_only ] && V="${FLAG_BQ:-0}"
    [ "$K" = merge_queue_rows_only ] && V="${FLAG_MQ:-0}"
    [ "$K" = deploy_queue_rows ]     && V="${FLAG_DQ:-0}"
    # `none` is a knob nobody has ever set: the worker answers 404, which
    # setting_get turns into rc 2 and the reader turns into its env fallback.
    case "$V" in
      absent|none) printf '{}\n404\n' ;;
      *) printf '{"setting":{"key":"%s","value":"%s"}}\n200\n' "$K" "$V" ;;
    esac
    ;;
  "GET "*/api/queue*)
    P=""; case "$URL" in *project=*) P="${URL##*project=}"; P="${P%%&*}" ;; esac
    ST=""; case "$URL" in *status=*) ST="${URL##*status=}"; ST="${ST%%&*}" ;; esac
    # ?key= and ?limit= are filtered FOR REAL, and the rows come back in file
    # order: the route is `ORDER BY enqueued_at ASC LIMIT n`, so the first row a
    # project-wide read sees is its OLDEST claim — which is the one most likely
    # to be a dead build nobody swept yet. A stub that ignored `key=` would hide
    # exactly the masking case §3 exists to pin.
    K=""; case "$URL" in *key=*) K="${URL##*key=}"; K="${K%%&*}" ;; esac
    LIM=0; case "$URL" in *limit=*) LIM="${URL##*limit=}"; LIM="${LIM%%&*}" ;; esac
    awk -F'\t' -v p="$P" -v st="$ST" -v k="$K" -v lim="$LIM" 'BEGIN{printf "{\"queue\":["; n=0}
      (p=="" || $1==p) && (st=="" || $3==st) && (k=="" || $2==k) {
        if (lim+0 > 0 && n >= lim+0) next
        if (n++) printf ",";
        printf "{\"project\":\"%s\",\"ticket_key\":\"%s\",\"status\":\"%s\",\"claimed_by\":\"box-a\",\"machine\":%s}",
          $1, $2, $3, ($4=="-" ? "null" : "\"" $4 "\"") }
      END{print "]}"}' "$ROWS" 2>/dev/null
    echo 200
    ;;
  "POST "*/api/queue/claim)
    printf '{"queued":{"project":"project-3","ticket_key":"TK-109","ticket_id":"109","target":"fly","attempt":1,"status":"claimed","machine":"1857abc"},"claimed":true}\n200\n'
    ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

ROWS="$T/rows.tsv"; : > "$ROWS"
ACTIVE="$H/state/fly/project-3-active.json"

# run <snippet> — one tick, in a clean subshell. The fixture's knobs come from
# the CALLER's environment so a case reads as one line:
#   FLAG_BQ=1 CURL_MODE=down run '…'
# FLAG_*  what the settings row says (`none` = no row at all, a 404)
# BUILD_QUEUE_ROWS_ONLY / MERGE_QUEUE_ROWS_ONLY / DEPLOY_QUEUE_ROWS — the
#         DOCUMENTED env fallbacks, which is the only way a lane is on while the
#         worker is unreachable.
run() {
  : > "$T/req.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-a JOBS_RETRIES=0 \
           JOBS_TIMEOUT=5 REQ_SINK="$T/req.txt" ROWS="$ROWS" \
           CURL_MODE="${CURL_MODE:-up}" FLAG_BQ="${FLAG_BQ:-0}" \
           FLAG_MQ="${FLAG_MQ:-0}" FLAG_DQ="${FLAG_DQ:-0}"
    bash -c "$1" ) 2>/dev/null
}
CLIENT='. "$HARNESS/bin/jobs-client.sh" || exit 1'
# lib <snippet> — the same, with the client sourced first.
lib() { run "$CLIENT
$1"; }
# `grep -c x f || echo 0` prints 0 AND THEN 0 when the count is zero (grep exits
# 1), so the count helpers are awk.
sreqs() { awk '/\/api\/settings\//{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }
qreqs() { awk '/\/api\/queue/{n++} END{print n+0}' "$T/req.txt" 2>/dev/null || echo 0; }
body_of() {
  grep -m1 "^$1 https://jobs.invalid$2" "$T/req.txt" \
    | awk '{ $1=""; $2=""; sub(/^ +/, ""); print }'
}

# ══ 1. THE THREE READERS RESOLVE ROW → DOCUMENTED ENV → 0 ═══════════════════
# One resolution mechanism (_flag_on_row), three knobs. Every value that is not
# an explicit yes-word reads OFF: a knob is armed on purpose or not at all, and
# `2` is not a truthy half-measure (D11 — absent ≠ zero ≠ approved).
for CASE in "1:0" "on:0" "true:0" "yes:0" "0:1" "off:1" "false:1" "2:1" ":1" "none:1"; do
  V="${CASE%:*}"; WANT="${CASE#*:}"
  RC=$(FLAG_BQ="$V" lib 'build_queue_rows_only_on; echo $?')
  [ "$RC" = "$WANT" ] && ok || bad "build_queue_rows_only='$V' must resolve rc $WANT, got $RC"
  RC=$(FLAG_MQ="$V" lib 'merge_queue_rows_only_on; echo $?')
  [ "$RC" = "$WANT" ] && ok || bad "merge_queue_rows_only='$V' must resolve rc $WANT, got $RC"
  RC=$(FLAG_DQ="$V" lib 'deploy_queue_rows_on; echo $?')
  [ "$RC" = "$WANT" ] && ok || bad "deploy_queue_rows='$V' must resolve rc $WANT, got $RC"
done

# The ROW WINS over the env: an operator who flips the row off must not be
# overruled by a value left in env/global.env from the rollout.
RC=$(FLAG_BQ=0 BUILD_QUEUE_ROWS_ONLY=1 lib 'build_queue_rows_only_on; echo $?')
[ "$RC" = 1 ] && ok || bad "the settings ROW must win over the env fallback, got rc $RC"
# …and with NO row the documented env value is what answers.
RC=$(FLAG_BQ=none BUILD_QUEUE_ROWS_ONLY=1 lib 'build_queue_rows_only_on; echo $?')
[ "$RC" = 0 ] && ok || bad "with no row the documented env fallback must answer, got rc $RC"
RC=$(FLAG_MQ=none MERGE_QUEUE_ROWS_ONLY=1 lib 'merge_queue_rows_only_on; echo $?')
[ "$RC" = 0 ] && ok || bad "merge_queue_rows_only must read MERGE_QUEUE_ROWS_ONLY, got rc $RC"
RC=$(FLAG_DQ=none DEPLOY_QUEUE_ROWS=1 lib 'deploy_queue_rows_on; echo $?')
[ "$RC" = 0 ] && ok || bad "deploy_queue_rows must read DEPLOY_QUEUE_ROWS, got rc $RC"
# Each knob is its OWN row: arming one must not arm its siblings, or the split's
# three PRs become one switch.
OUT=$(FLAG_BQ=1 lib 'build_queue_rows_only_on; printf "%s" $?
  merge_queue_rows_only_on; printf "%s" $?
  deploy_queue_rows_on; printf "%s" $?')
[ "$OUT" = "011" ] && ok || bad "three knobs, three rows: arming build_queue_rows_only armed a sibling ($OUT)"

# ══ 2. AN OUTAGE IS NEVER CACHED, AND NEVER SWITCHES A LANE ON ══════════════
OUT=$(CURL_MODE=down FLAG_BQ=1 lib 'build_queue_rows_only_on; printf "%s" $?
  build_queue_rows_only_on; printf "%s" $?')
[ "$OUT" = "11" ] && ok || bad "an unreadable flag must NEVER read as ON, got '$OUT'"
[ "$(sreqs)" = 2 ] \
  && ok || bad "an outage must NOT be memoised — a worker that blinks cannot pin one answer for the process (settings reads: $(sreqs))"
# A REAL answer is memoised: a tick that asks per ticket must not buy a read per
# ticket.
OUT=$(FLAG_BQ=0 lib 'build_queue_rows_only_on; build_queue_rows_only_on; build_queue_rows_only_on')
[ "$(sreqs)" = 1 ] \
  && ok || bad "a readable answer must be memoised per process, got $(sreqs) settings reads"
# THE DOCUMENTED ENV FALLBACK SURVIVES AN OUTAGE. This is the only way a lane is
# on while the worker is down, and it is deliberate: the resolution continues,
# it does not force off.
RC=$(CURL_MODE=down BUILD_QUEUE_ROWS_ONLY=1 lib 'build_queue_rows_only_on; echo $?')
[ "$RC" = 0 ] && ok || bad "BUILD_QUEUE_ROWS_ONLY=1 must still read ON through an outage, got rc $RC"
# With the flag off, not one request beyond the settings read.
FLAG_BQ=0 lib 'build_queue_rows_only_on' >/dev/null
[ "$(qreqs)" = 0 ] && ok || bad "a flag read must never touch /api/queue: $(cat "$T/req.txt")"

# ══ 3. build_queue_active_key — the shared read the two call sites owe ══════
# THE ROW ANSWER, with the file deleted: this is the case the whole slice is for.
printf 'project-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"
rm -f "$ACTIVE"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3; echo "rc=$?"')
[ "$(head -1 <<<"$OUT")" = "$(printf 'TK-9\t1857abc')" ] \
  && ok || bad "flag on + a claimed row must print key<TAB>machine with no file at all, got: $(head -1 <<<"$OUT" | cat -A)"
grep -q '^rc=0$' <<<"$OUT" \
  && ok || bad "an active key is rc 0, got: $OUT"

# A claimed row that predates the column prints `-`, never a bare tab and never
# an empty second field that shifts a reader's columns.
printf 'project-3\tFR-9\tclaimed\t-\n' > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3')
[ "$OUT" = "$(printf 'TK-9\t-')" ] \
  && ok || bad "a claimed row with no machine must print '-', got: $(printf '%s' "$OUT" | cat -A)"

# NOT EVERY ROW IS ACTIVE. `queued` is waiting and `done` is finished; reporting
# either as active would refuse to launch a ticket nothing is building.
for ST in queued done failed ready; do
  printf 'project-3\tFR-9\t%s\t1857abc\n' "$ST" > "$ROWS"
  OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3; echo "rc=$?"')
  [ "$OUT" = "rc=1" ] \
    && ok || bad "a '$ST' row is not an ACTIVE build — must be rc 1 with empty stdout, got: $(printf '%s' "$OUT" | cat -A)"
done

# FLAG OFF IS THE FILE, byte for byte what the call site does today.
: > "$ROWS"
printf '{"key":"TK-5","machine":"deadbeef"}\n' > "$ACTIVE"
OUT=$(FLAG_BQ=0 lib 'build_queue_active_key project-3; echo "rc=$?"')
[ "$(head -1 <<<"$OUT")" = "$(printf 'TK-5\t-')" ] \
  && ok || bad "flag off must answer from <p>-active.json, got: $(head -1 <<<"$OUT" | cat -A)"
[ "$(qreqs)" = 0 ] && ok || bad "flag off must make NO queue request: $(cat "$T/req.txt")"

# AN OUTAGE FALLS TO THE FILE and never prints an empty answer as "nothing
# claimed": that is the dedupe guard opening, and a second machine for a key
# that is already building (TK-70).
OUT=$(FLAG_BQ=1 CURL_MODE=down lib 'build_queue_active_key project-3')
[ "$OUT" = "$(printf 'TK-5\t-')" ] \
  && ok || bad "an outage must fall back to the file, got: $(printf '%s' "$OUT" | cat -A)"

# THE WRITE-THROUGH CYCLE: flag on, worker reachable, no claimed row yet — the
# file is still the cache and still answers, because nothing writes the row for
# the fly lane until a sibling slice lands.
: > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3')
[ "$OUT" = "$(printf 'TK-5\t-')" ] \
  && ok || bad "flag on + no row must still read the file for one full cycle, got: $(printf '%s' "$OUT" | cat -A)"

# NOTHING ANYWHERE is rc 1 and silence — which is exactly what today's
# `jq -r '.key // ""'` on a missing file yields to the caller's comparison.
rm -f "$ACTIVE"; : > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3; echo "rc=$?"')
[ "$OUT" = "rc=1" ] \
  && ok || bad "no row and no file is rc 1 with empty stdout, got: $(printf '%s' "$OUT" | cat -A)"
# A row for ANOTHER project is not this project's active build.
printf 'other-os\tZZ-4\tclaimed\tbeef\n' > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3; echo "rc=$?"')
[ "$OUT" = "rc=1" ] \
  && ok || bad "another project's claimed row must not leak in, got: $(printf '%s' "$OUT" | cat -A)"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "an empty project must refuse, got: $OUT"

# ══ 3b. THE KEYED READ — the question the call site actually asks ═══════════
# "IS THIS KEY BUILDING", not "is anything building". A project runs local
# builds (claimed with an empty target by the build pipeline, bin/lib/rb/
# gates.sh) and pool machines (bin/fly-pool.sh) beside the single fly job, and a
# claim whose build died sits `claimed` for 6h until bin/jobs-watchdog.sh sweeps
# it — so the OLDEST claimed row, which `ORDER BY enqueued_at ASC LIMIT 1`
# returns, is routinely a different ticket and routinely a dead one.
#
# THE MASKING CASE. A stale claim for TK-1 sits in front of the live fly job
# TK-9. A project-wide row read answers TK-1, the file is never consulted, the
# caller's `[ "$ACTIVE_KEY" = "$KEY" ]` is false for the key that IS building,
# and the dedupe guard opens: a second Fly machine, a second Claude session, two
# PRs racing one branch (the TK-70 shape this helper exists to prevent).
printf 'project-3\tFR-1\tclaimed\t-\nproject-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"
printf '{"key":"TK-9"}\n' > "$ACTIVE"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3 TK-9; echo "rc=$?"')
[ "$(head -1 <<<"$OUT")" = "$(printf 'TK-9\t1857abc')" ] \
  && ok || bad "a stale claim for ANOTHER key must not mask the key being asked about, got: $(head -1 <<<"$OUT" | cat -A)"
grep -q '^rc=0$' <<<"$OUT" && ok || bad "the keyed read is rc 0 when that key is claimed, got: $OUT"
# …and the same fixture, asked about a key nothing holds, is rc 1: the helper
# must not report SOMEBODY ELSE's claim as this key's.
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3 TK-140; echo "rc=$?"')
[ "$OUT" = "rc=1" ] \
  && ok || bad "a key nothing is building must be rc 1 even with other claims in the queue, got: $(printf '%s' "$OUT" | cat -A)"
# THE FILE STILL ANSWERS FOR THE KEY IT NAMES, with the row store empty — the
# write-through cycle, keyed.
: > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3 TK-9')
[ "$OUT" = "$(printf 'TK-9\t-')" ] \
  && ok || bad "flag on + no row must still read the file for the asked key, got: $(printf '%s' "$OUT" | cat -A)"
# …and an outage keyed the same way never prints "nothing".
OUT=$(FLAG_BQ=1 CURL_MODE=down lib 'build_queue_active_key project-3 TK-9')
[ "$OUT" = "$(printf 'TK-9\t-')" ] \
  && ok || bad "an outage must fall back to the file for the asked key, got: $(printf '%s' "$OUT" | cat -A)"
# A file naming a DIFFERENT key is rc 1 for this key — which is what the caller's
# comparison makes of it today, character for character.
OUT=$(FLAG_BQ=0 lib 'build_queue_active_key project-3 TK-140; echo "rc=$?"')
[ "$OUT" = "rc=1" ] \
  && ok || bad "the file naming another key is not THIS key's active build, got: $(printf '%s' "$OUT" | cat -A)"

# THE UNKEYED READ IS A UNION, not a row-or-file choice: one line per active
# key, so a row answer can only ever ADD an active key and never hide one.
printf 'project-3\tFR-1\tclaimed\t-\n' > "$ROWS"
printf '{"key":"TK-9"}\n' > "$ACTIVE"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3')
[ "$(printf '%s\n' "$OUT" | wc -l)" = 2 ] \
  && ok || bad "the project-wide read must union the rows and the file, got: $(printf '%s' "$OUT" | cat -A)"
# Counted, not `grep -q … && grep -q …`: two greps on one line is the shape
# tests/rollup-crash-loud-test.sh refuses (a pipefail SIGPIPE flake).
N1=$(printf '%s\n' "$OUT" | grep -c '^TK-1')
N9=$(printf '%s\n' "$OUT" | grep -c '^TK-9')
[ "$N1" = 1 ] && [ "$N9" = 1 ] \
  && ok || bad "the union must name BOTH the claimed row and the file's key, got: $(printf '%s' "$OUT" | cat -A)"
# One key is ONE line even when the row and the file agree — a duplicate would
# have a reader believe two things are building.
printf 'project-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"
OUT=$(FLAG_BQ=1 lib 'build_queue_active_key project-3')
[ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && [ "$OUT" = "$(printf 'TK-9\t1857abc')" ] \
  && ok || bad "row and file naming one key must print one line, got: $(printf '%s' "$OUT" | cat -A)"

# ══ 4. THE ONE `ACTIVE_KEY` CALL SITE, EXTRACTED AND DRIVEN ═════════════════
# Until the BH-572 cut this block lived twice — inline in bin/run-build.sh and in
# the stage module bin/lib/rb/gates.sh — and this section drove both to prove the
# two copies agreed. After the cut there is one copy, in gates.sh, and the drift
# it guarded is impossible. So the pin is ONE COPY: absent from the raw driver,
# present exactly once in its module, present once in the pipeline the driver
# runs (the flatten), and the module's block is pulled out and executed against
# every case, so the answer is observed rather than read off source.
extract() {
  awk '/command -v build_queue_active_key/{f=1} f{print} f && /^[[:space:]]*fi[[:space:]]*$/{exit}' "$1"
}
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: rb_all could not flatten bin/run-build.sh"; exit 1; }
N_DRV=$(grep -c 'command -v build_queue_active_key' "$DIR/bin/run-build.sh")
N_MOD=$(grep -c 'command -v build_queue_active_key' "$DIR/bin/lib/rb/gates.sh")
N_ALL=$(grep -c 'command -v build_queue_active_key' "$RB_ALL")
[ "$N_DRV" = 0 ] \
  && ok || bad "bin/run-build.sh carries its own build_queue_active_key block again ($N_DRV) — a second copy is the drift the cut removed"
[ "$N_MOD" = 1 ] \
  && ok || bad "bin/lib/rb/gates.sh must hold the build_queue_active_key block exactly once (got $N_MOD)"
[ "$N_ALL" = 1 ] \
  && ok || bad "the pipeline (flatten) must run the build_queue_active_key block exactly once (got $N_ALL)"
extract "$DIR/bin/lib/rb/gates.sh"   > "$T/blk-gates.sh"
# GUARD THE ABSENT-SYMBOL CASE (D3): an extraction that found nothing would make
# every assertion below about the empty string trivially true.
[ -s "$T/blk-gates.sh" ] \
  && ok || bad "bin/lib/rb/gates.sh has no build_queue_active_key block to extract — the call-site swap never happened"
grep -q 'ACTIVE_KEY=' "$T/blk-gates.sh" \
  && ok || bad "the extracted gates block must assign ACTIVE_KEY: $(cat "$T/blk-gates.sh")"

# blk <block-file> <armed 0|1> [key] — drive the call site's block for project-3,
# for the KEY this launch is about (the block passes it to the helper, because
# "is anything building" is not the question a dedupe guard asks).
blk() {
  local snip="PROJECT=project-3
KEY=${3:-TK-9}"
  [ "$2" = 1 ] && snip="$snip
$CLIENT"
  snip="$snip
$(cat "$1")
printf '%s\n' \"\$ACTIVE_KEY\""
  run "$snip"
}

# Every case from §3, asked of the call site.
printf 'project-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"; rm -f "$ACTIVE"
B=$(FLAG_BQ=1 blk "$T/blk-gates.sh" 1)
[ "$B" = TK-9 ] \
  && ok || bad "the call site must read the claimed ROW's key with the flag on (gates='$B')"

# THE GUARD MUST NOT OPEN BEHIND A STALE CLAIM. TK-1 died claimed hours ago and
# is the oldest row; TK-9 is the live fly job the file names. The call site
# must still see TK-9 — an answer of TK-1 (or of nothing) is `ACTIVE_KEY != KEY`
# for a key that IS building, which spawns the second machine.
printf 'project-3\tFR-1\tclaimed\t-\nproject-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"
printf '{"key":"TK-9"}\n' > "$ACTIVE"
B=$(FLAG_BQ=1 blk "$T/blk-gates.sh" 1)
[ "$B" = TK-9 ] \
  && ok || bad "a stale claim for another key must not open the dedupe guard (gates='$B')"
# …and the same queue, for a key nothing holds, must leave the block empty —
# another ticket's claim is not this one's, and reporting it would REFUSE a
# launch nothing is running.
B=$(FLAG_BQ=1 blk "$T/blk-gates.sh" 1 TK-140)
[ -z "$B" ] \
  && ok || bad "another ticket's claim must not read as THIS key's active build (gates='$B')"

printf '{"key":"TK-5"}\n' > "$ACTIVE"; : > "$ROWS"
B=$(FLAG_BQ=0 blk "$T/blk-gates.sh" 1 TK-5)
[ "$B" = TK-5 ] \
  && ok || bad "with the flag off the call site answers from the file, exactly as today (gates='$B')"

B=$(FLAG_BQ=1 CURL_MODE=down blk "$T/blk-gates.sh" 1 TK-5)
[ "$B" = TK-5 ] \
  && ok || bad "an outage must leave the call site on the file (gates='$B')"

rm -f "$ACTIVE"
B=$(FLAG_BQ=1 blk "$T/blk-gates.sh" 1 TK-5)
[ -z "$B" ] \
  && ok || bad "nothing active must be the empty string the call site compares against (gates='$B')"

# AN UNARMED BOX: no client sourced, so `command -v` misses and the block is
# today's file read, character for character — the raw key the file names, with
# no key filter of any kind, which is what shipped before this slice.
printf '{"key":"TK-5"}\n' > "$ACTIVE"
printf 'project-3\tFR-9\tclaimed\t1857abc\n' > "$ROWS"
B=$(FLAG_BQ=1 blk "$T/blk-gates.sh" 0 TK-140)
[ "$B" = TK-5 ] \
  && ok || bad "an unarmed box must stay on the file read (gates='$B')"
[ "$(qreqs)" = 0 ] \
  && ok || bad "an unarmed box must make no request at all: $(cat "$T/req.txt")"

# ══ 5. queue_claim's optional 4th argument ══════════════════════════════════
OUT=$(lib 'queue_claim project-3 fly "" 1857abc')
B=$(body_of POST /api/queue/claim)
[ "$(jq -r '.machine // "absent"' <<<"$B")" = 1857abc ] \
  && ok || bad "a machine must ride the claim body, got: $B"
# AN EMPTY MACHINE IS OMITTED, never sent as "": an empty string is a value that
# compares, and it would land on the row as one (D11).
lib 'queue_claim project-3 fly' >/dev/null
B=$(body_of POST /api/queue/claim)
[ "$(jq -r '.machine // "absent"' <<<"$B")" = absent ] \
  && ok || bad "an empty machine must be OMITTED from the body, not sent as \"\": $B"
# THE OUTPUT TSV IS UNCHANGED — existing parsers read columns 1-4 positionally.
[ "$(cut -f1 <<<"$OUT")" = TK-109 ] && ok || bad "column 1 is still the key, got '$OUT'"
[ "$(cut -f2 <<<"$OUT")" = 109 ]    && ok || bad "column 2 is still the ticket_id, got '$OUT'"
[ "$(cut -f3 <<<"$OUT")" = fly ]    && ok || bad "column 3 is still the target, got '$OUT'"
[ "$(cut -f4 <<<"$OUT")" = 1 ]      && ok || bad "column 4 is still the attempt, got '$OUT'"
[ "$(awk -F'\t' '{print NF; exit}' <<<"$OUT")" = 4 ] \
  && ok || bad "queue_claim must still print FOUR columns — a fifth shifts every parser, got '$OUT'"

echo "queue-rows-flags.bh-1026-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
