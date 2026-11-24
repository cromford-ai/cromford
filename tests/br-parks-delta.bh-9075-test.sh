#!/bin/bash
# tests/br-parks-delta.bh-9075-test.sh — BH-9075 (BH-9067.3): the resolver
# reads its queue parks as a delta of the D1 `parks` table
# (bin/lib/br/opt/parks.sh, the br_candidates branch in bin/lib/br/discovery.sh).
#
#   D1  1,000 rows, 37 newer than since, 2 older hotfix rows; mode on, cursor
#       = since, empty mirror: the REAL br_candidates prints exactly 39 8-field
#       rows in under 2 s; a real lane tick's prof: discovery= is under 2
#   D2  no done row       D3  no other-project row     D4  limit 25 = 2 pages
#   D5  no row at exactly since                        D6  an older write loses
#   D7  on + a read failure = the files rows, no partial parks row
#   D8  off = 0 calls to /api/parks/changed (direct and a real lane tick)
#   D9  shadow, a 1,000-row mismatch: ONE parks-shadow: line, a capped list,
#       0 new ALERTS lines, output == files
#   D10 a second on tick with no change re-emits the same 39 rows
#   D11 shadow at cursor 0 backfills: the files rows are PUT (br-backfill)
#   D12 the page cap: the on output is files, the cursor moved, record files untouched
#   D13 a note whose PUT failed (still in the outbox) holds the cursor below
#       it; once the PUT works the row reaches the mirror and the on output
#   D14 the outbox marker state/parks-outbox/.dropped-at (written by the real
#       pw_flush over PW_OUTBOX_MAX): (a) newer than the cursor reads 0 and the
#       shadow tick backfills; (b) a cursor written after it reads the cursor;
#       (c) a .dropped-at under .bad/ has no effect
#
# No network: _jobs_req is tests/lib/parks-fake.bh-9075.sh (a local fake of the
# route contract), gh and the queue are stubs. Each case seeds its own table.
# Run from anywhere: tests/br-parks-delta.bh-9075-test.sh   (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin"
# The scripts the lane runs drive. The copy stays here so bin/test-impact.sh selects this suite.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/bin/blocked-resolver.d" "$H/bin/lib/br/opt" "$H/bin/lib/jobs" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/br/opt/profile.sh "$H" >/dev/null || exit 1
# The module under test and what it sources (bin/lib/parks-write.sh, bin/lib/jobs/parks.sh).
scratch_install_closure bin/lib/br/opt/parks.sh "$H" >/dev/null || exit 1
[ -f "$H/bin/lib/parks-write.sh" ] && [ -f "$H/bin/lib/jobs/parks.sh" ] || { echo "the closure of bin/lib/br/opt/parks.sh is incomplete"; exit 1; }
touch "$H/flags/blocked-resolver-observe" "$H/flags/fly-pool-tproj"
# The jobs client of the lane: the parks fake plus the queue the files source reads.
cat > "$H/bin/jobs-client.sh" <<EOF
. "$DIR/tests/lib/parks-fake.bh-9075.sh"
queue_list() { cat "$T/queue-rows.tsv" 2>/dev/null; return 0; }
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
EOF
ST="$H/state/blocked-resolver"; LOGF="$H/logs/blocked-resolver.log"
export PARKS_FAKE_DB="$T/db.json" PARKS_FAKE_CALLS="$T/calls.txt" PARKS_FAKE_BODIES="$T/bodies.txt"
S=$((NOW - 100000))

fresh() {
  printf '[]' > "$PARKS_FAKE_DB"; : > "$PARKS_FAKE_CALLS"; : > "$PARKS_FAKE_BODIES"
  : > "$T/queue-rows.tsv"; : > "$T/cond-rows.tsv"; : > "$LOGF"
  scratch_rm "$ST/parks" 2>/dev/null; scratch_rm "$H/state/parks-outbox" 2>/dev/null
  unset PARKS_FAKE_FAIL PARKS_FAKE_FAIL_PATH
}
seed_d1() { # the D1 table: 1,000 rows
  jq -n --argjson s "$S" '
    [range(0;37)  as $i | {project:"tproj", ck:"tproj-TK-\(1000+$i)", state:"parked", updated_at:($s + 10 + $i * 10)}]
  + [range(0;2)   as $i | {project:"tproj", ck:"tproj-TK-\(2000+$i)", state:"hotfix", updated_at:($s - 500 - $i)}]
  + [{project:"tproj", ck:"tproj-TK-3000", state:"parked", updated_at:$s}]
  + [range(0;10)  as $i | {project:"tproj", ck:"tproj-TK-\(4000+$i)", state:"done", updated_at:($s + 5 + $i)}]
  + [range(0;50)  as $i | {project:"oproj", ck:"oproj-TK-\(5000+$i)", state:"parked", updated_at:($s + 20 + $i)}]
  + [range(0;900) as $i | {project:"tproj", ck:"tproj-TK-\(6000+$i)", state:"parked", updated_at:($s - 1000 - $i)}]
  | map(. + {source:"queue", head:"-", reason:"pool-died-twice", url:"-", rec:"-",
             ticket:(.ck | sub("^[a-z]+-"; "")), writer:"fly-pool", parked_at:null})' > "$PARKS_FAKE_DB"
  mkdir -p "$ST/parks"; : > "$ST/parks/tproj.mirror"; printf '%s\n' "$S" > "$ST/parks/tproj.cursor"
}
# cand [VAR=value ...] — the REAL br_candidates (discovery.sh + opt/parks.sh),
# with the queue source reading $T/queue-rows.tsv and the other sources
# replaced by a fixture conductor source ($T/cond-rows.tsv) and no-ops.
cand() {
  ( export "$@"
    H="$H"; ST="$ST"; ONLY=tproj; BR_LIB_DIR="$H/bin/lib/br"
    say() { printf '%s %s\n' "$(date -u '+%F %TZ')" "$*" >> "$LOGF"; }
    STAMP() { date -u '+%F %TZ'; }
    . "$H/bin/lib/br/record.sh"; . "$H/bin/lib/br/ladder.sh"; . "$H/bin/lib/br/discovery.sh"
    . "$H/bin/jobs-client.sh"
    br_from_rebuilds() { :; }; br_from_builds() { :; }; br_from_reviews() { :; }
    br_from_conductor() { cat "$T/cond-rows.tsv"; }
    br_candidates )
}
calls() { grep -c -- "$1" "$PARKS_FAKE_CALLS" 2>/dev/null || true; }
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
          BR_PER_TICK=1 env "$@" bash "$H/bin/blocked-resolver.sh" >>"$T/run.log" 2>&1 ) || true; }
alerts() { cat "$H/logs/ALERTS.log" "$T/lane-alert.txt" 2>/dev/null | wc -l; }

# ── D1-D6, D10 ──────────────────────────────────────────────────────────────
fresh; seed_d1
# D6: an older write of a stored row loses (the route's guard; the fake keeps it).
printf 'tproj\ttproj-TK-1000\tqueue\tparked\t-\tolder-write\t-\t-\tTS-1000\t%s\tfly-pool\t-\n' "$((S - 99999))" > "$T/older.tsv"
( . "$H/bin/jobs-client.sh"; HARNESS="$H" . "$H/bin/lib/jobs/parks.sh"; HARNESS="$H" parks_put "$T/older.tsv" ) > "$T/older.out"
: > "$PARKS_FAKE_CALLS"
T0=$(date +%s%N)
OUT=$(cand BR_PARKS_MODE=on BR_PARKS_PAGE=25)
MS=$(( ($(date +%s%N) - T0) / 1000000 ))
N=$(grep -c . <<<"$OUT")
[ "$N" = 39 ] && ok || bad "D1 THE CLAIM: mode on must print exactly 39 rows (37 changed + 2 hotfix), got $N: $(head -3 <<<"$OUT")"
[ "$(awk -F'\t' 'NF != 8' <<<"$OUT" | wc -l)" = 0 ] && ok || bad "D1 every row has 8 fields"
[ "$MS" -lt 2000 ] && ok || bad "D1 br_candidates must take under 2 s (took ${MS} ms)"
WANT=$( { for i in $(seq 1000 1036); do echo "tproj-TK-$i"; done; echo tproj-TK-2000; echo tproj-TK-2001; } | sort)
[ "$(cut -f3 <<<"$OUT" | sort)" = "$WANT" ] && ok || bad "D1 the 39 cks must be the 37 changed and the 2 hotfix rows"
grep -qx "queue	tproj	tproj-TK-1000	pool-died-twice	-	-	TK-1000	-" <<<"$OUT" && ok || bad "D1 a row is the br_from_queue tuple: $(grep TK-1000 <<<"$OUT")"
grep -q 'tproj-TK-40' <<<"$OUT" && bad "D2 a done row was offered" || ok
grep -q 'oproj' <<<"$OUT" && bad "D3 another project's row was offered" || ok
[ "$(calls 'GET /api/parks/changed')" = 2 ] && ok || bad "D4 limit 25 over 47 changed rows = 2 page calls (got $(calls 'GET /api/parks/changed'))"
grep -q 'tproj-TK-3000' <<<"$OUT" && bad "D5 the row at exactly since was offered" || ok
grep -q 'older-write' <<<"$OUT" && bad "D6 an older write must lose" || ok
grep -q 'upserted=0' "$T/older.out" && ok || bad "D6 the older write upserts 0 ($(cat "$T/older.out"))"
[ "$(head -c 20 "$ST/parks/tproj.cursor")" != "$S" ] && ok || bad "D1 the cursor must move after a full read"
OUT2=$(cand BR_PARKS_MODE=on BR_PARKS_PAGE=25)
[ "$(sort <<<"$OUT2")" = "$(sort <<<"$OUT")" ] && ok || bad "D10 a second tick with no change must re-emit the same 39 rows (got $(grep -c . <<<"$OUT2"))"

# D1 on the real lane: the prof: line's discovery seconds.
fresh; seed_d1
RUN BR_PARKS_MODE=on BR_PARKS_PAGE=25
PD=$(grep ' prof: ' "$LOGF" | tail -1 | sed -nE 's/.* discovery=([0-9]+).*/\1/p')
[ -n "$PD" ] && [ "$PD" -lt 2 ] && ok || bad "D1 the lane's prof: discovery= must be under 2 (got '${PD}'; $(grep -c . "$LOGF") log lines, last: $(tail -1 "$LOGF"))"
[ "$(calls 'GET /api/parks/changed')" -ge 1 ] && ok || bad "D1 the real lane in mode on must read the parks delta"

# ── D7 ──────────────────────────────────────────────────────────────────────
fresh; seed_d1
printf 'tproj\tTS-77\t7\tfailed\t-\t1\t-\t-\tdied twice\t-\n' > "$T/queue-rows.tsv"
FILES=$(cand BR_PARKS_MODE=off)
export PARKS_FAKE_FAIL=500 PARKS_FAKE_FAIL_PATH='/api/parks/changed*'
OUT=$(cand BR_PARKS_MODE=on)
unset PARKS_FAKE_FAIL PARKS_FAKE_FAIL_PATH
[ -n "$FILES" ] && [ "$OUT" = "$FILES" ] && ok || bad "D7 a read failure in mode on must give the files rows ('$OUT' vs '$FILES')"
grep -q 'tproj-TK-10' <<<"$OUT" && bad "D7 no partial parks row may leak" || ok
grep -q 'parks: tproj read failed' "$LOGF" && ok || bad "D7 the fallback is logged"

# ── D8 ──────────────────────────────────────────────────────────────────────
fresh; seed_d1
OUT=$(cand BR_PARKS_MODE=off)
[ "$(calls '/api/parks')" = 0 ] && ok || bad "D8 mode off must make 0 parks calls (got $(cat "$PARKS_FAKE_CALLS"))"
printf 'tproj\tTS-78\t7\tfailed\t-\t1\t-\t-\tdied twice\t-\n' > "$T/queue-rows.tsv"
RUN BR_PARKS_MODE=off
[ "$(calls '/api/parks/changed')" = 0 ] && ok || bad "D8 a real lane tick in mode off must never call /api/parks/changed"
grep -q 'tick: candidates=1 ' "$LOGF" && ok || bad "D8 the lane tick ran and saw the files row (tick: $(grep 'tick:' "$LOGF" | tail -1))"

# ── D9 ──────────────────────────────────────────────────────────────────────
fresh
mkdir -p "$ST/parks"; : > "$ST/parks/tproj.mirror"; printf '%s\n' "$((NOW - 10))" > "$ST/parks/tproj.cursor"
for i in $(seq 7000 7999); do printf 'tproj\tTS-%s\t%s\tfailed\t-\t1\t-\t-\tdied 2 times (state=gone)\t-\n' "$i" "$i"; done > "$T/queue-rows.tsv"
FILES=$(cand BR_PARKS_MODE=off)
A0=$(alerts); : > "$LOGF"
OUT=$(cand BR_PARKS_MODE=shadow BR_PARKS_SHADOW_LIST_MAX=20)
[ "$OUT" = "$FILES" ] && [ "$(grep -c . <<<"$OUT")" = 1000 ] && ok || bad "D9 shadow output must equal the files output (1,000 rows)"
[ "$(grep -c 'parks-shadow:' "$LOGF")" = 1 ] && ok || bad "D9 exactly ONE parks-shadow: line (got $(grep -c 'parks-shadow:' "$LOGF"))"
L=$(grep 'parks-shadow:' "$LOGF")
grep -q 'files=1000 parks=0 ' <<<"$L" && grep -q 'missing=[^ ]*\[+980\] ' <<<"$L" && grep -q 'extra=- ' <<<"$L" \
  && grep -q 'queue=1000/0 conductor=0/0 projects=1' <<<"$L" && ok || bad "D9 the line carries the counts and a capped list: $L"
[ "$(sed -nE 's/.*missing=([^ []*).*/\1/p' <<<"$L" | tr ',' '\n' | grep -c .)" = 20 ] && ok || bad "D9 the missing list is capped at 20"
[ "$(alerts)" = "$A0" ] && ok || bad "D9 0 new ALERTS lines"

# ── D11 ─────────────────────────────────────────────────────────────────────
fresh
for i in 1 2 3 4 5; do printf 'tproj\tTS-8%s\t8\tfailed\t-\t1\t-\t-\tdied twice\t-\n' "$i"; done > "$T/queue-rows.tsv"
printf 'conductor\ttproj\to-tproj-91\tmerge-failed-twice\thttps://github.com/o/tproj/pull/91\t-\tTS-91\t1700000000\n' > "$T/cond-rows.tsv"
OUT=$(cand BR_PARKS_MODE=shadow)
[ "$(calls 'PUT /api/parks')" -ge 1 ] && ok || bad "D11 cursor 0 in shadow must PUT the files rows (calls: $(cat "$PARKS_FAKE_CALLS"))"
[ "$(jq -r '.rows[]? | select(.writer == "br-backfill") | .ck' "$PARKS_FAKE_BODIES" | sort | tr '\n' ' ')" = "o-tproj-91 tproj-TK-81 tproj-TK-82 tproj-TK-83 tproj-TK-84 tproj-TK-85 " ] \
  && ok || bad "D11 the backfill PUT holds the 5 queue rows and the conductor row ($(jq -c '.rows[]?.ck' "$PARKS_FAKE_BODIES" | tr '\n' ' '))"
grep -q 'parks-shadow: files=6 parks=6 missing=- extra=- queue=5/5 conductor=1/1 projects=1' "$LOGF" && ok \
  || bad "D11 after the backfill the shadow compare matches: $(grep 'parks-shadow' "$LOGF")"
[ -s "$ST/parks/tproj.cursor" ] && [ -s "$ST/parks/tproj.mirror" ] && ok || bad "D11 the mirror and cursor exist after the backfill"

# ── D12 ─────────────────────────────────────────────────────────────────────
fresh; seed_d1
printf 'tproj\tTS-77\t7\tfailed\t-\t1\t-\t-\tdied twice\t-\n' > "$T/queue-rows.tsv"
mkdir -p "$ST/tproj"; printf '{"outcome":"HELD"}\n' > "$ST/tproj/tproj-TK-1.json"
RF0=$(find "$ST" -name '*.json' | wc -l)
FILES=$(cand BR_PARKS_MODE=off)
OUT=$(cand BR_PARKS_MODE=on BR_PARKS_PAGE=25 BR_PARKS_MAX_PAGES=1)
[ "$OUT" = "$FILES" ] && ok || bad "D12 a page-cap stop must use the files rows ('$OUT')"
C=$(cat "$ST/parks/tproj.cursor")
[ "$C" != "$S" ] && [ "${C%%:*}" -gt "$S" ] && ok || bad "D12 the progress is kept: the cursor moved past since (cursor '$C')"
[ "$(wc -l < "$ST/parks/tproj.mirror")" -gt 0 ] && ok || bad "D12 the page read was applied to the mirror"
[ "$(find "$ST" -name '*.json' | wc -l)" = "$RF0" ] && ok || bad "D12 the state-record files stay as the cache (count changed)"
grep -q 'stopped at BR_PARKS_MAX_PAGES' "$LOGF" && ok || bad "D12 the page cap is logged"

# ── D13 ─────────────────────────────────────────────────────────────────────
# A fly-pool park note written at S+100 (the clock seam below) whose PUT fails.
# The changed read works, and D1 already holds rows newer than the note.
fresh; seed_d1
export PARKS_FAKE_FAIL=500 PARKS_FAKE_FAIL_PATH='/api/parks'
( HARNESS="$H"; . "$H/bin/jobs-client.sh"; . "$H/bin/lib/parks-write.sh"
  date() { if [ "$*" = "-u +%s" ]; then echo $((S + 100)); else command date "$@"; fi; }
  pw_queue_park tproj TK-9900 "died 2 times (state=gone)" false )
[ "$(find "$H/state/parks-outbox" -maxdepth 1 -name '*.tsv' | wc -l)" = 1 ] && ok || bad "D13 the failed note stays in the outbox"
OUT=$(cand BR_PARKS_MODE=on)
C=$(cat "$ST/parks/tproj.cursor")
[ "${C%%:*}" -lt $((S + 100)) ] && ok || bad "D13 the cursor must stay below the outbox note at $((S + 100)) (cursor '$C')"
grep -q 'tproj-TK-9900' <<<"$OUT" && bad "D13 the note is not in D1 yet, so it is not offered" || ok
unset PARKS_FAKE_FAIL PARKS_FAKE_FAIL_PATH
OUT=$(cand BR_PARKS_MODE=on)
[ "$(find "$H/state/parks-outbox" -maxdepth 1 -name '*.tsv' | wc -l)" = 0 ] && ok || bad "D13 the next flush sends the note"
[ "$(jq -r --argjson t $((S + 100)) '[.[] | select(.ck == "tproj-TK-9900" and .updated_at == $t)] | length' "$PARKS_FAKE_DB")" = 1 ] \
  && ok || bad "D13 the row reaches the table with its write-time updated_at"
grep -q 'tproj-TK-9900' "$ST/parks/tproj.mirror" && ok || bad "D13 the late row reaches the mirror"
grep -qx "queue	tproj	tproj-TK-9900	pool-died-twice	-	-	TK-9900	-" <<<"$OUT" && ok || bad "D13 the late row is in the mode-on output ($(grep -c . <<<"$OUT") rows)"

# ── D14 ─────────────────────────────────────────────────────────────────────
cur() { ( ST="$ST"; HARNESS="$H"; . "$H/bin/lib/br/opt/parks.sh"; _brp_cursor tproj ) 2>/dev/null; }
fresh
mkdir -p "$ST/parks"; : > "$ST/parks/tproj.mirror"; printf '%s\n' "$S" > "$ST/parks/tproj.cursor"
touch -d '@'"$((NOW - 60))" "$ST/parks/tproj.cursor"
# (c) first: a marker under .bad/ is not read.
mkdir -p "$H/state/parks-outbox/.bad"; date -u +%s > "$H/state/parks-outbox/.bad/.dropped-at"
[ "$(cur)" = "$S" ] && ok || bad "D14c a .dropped-at under .bad/ must not reset the cursor ('$(cur)')"
# (a) the real pw_flush over the cap writes the marker after the cursor.
( HARNESS="$H"; export PARKS_FAKE_FAIL=noanswer PW_OUTBOX_MAX=1; . "$H/bin/jobs-client.sh"; . "$H/bin/lib/parks-write.sh"
  pw_note tproj tproj-TK-d1 queue parked - pool-died-twice - - TK-d1 fly-pool -
  pw_note tproj tproj-TK-d2 queue parked - pool-died-twice - - TK-d2 fly-pool - )
[ -s "$H/state/parks-outbox/.dropped-at" ] && ok || bad "D14a pw_flush over the cap writes the marker"
[ "$(cat "$ST/parks/tproj.cursor")" = "$S" ] && ok || bad "D14a pw_flush leaves the cursor file as it was"
[ "$(cur)" = 0 ] && ok || bad "D14a a marker newer than the cursor reads 0 ('$(cur)')"
scratch_rm "$H/state/parks-outbox" 2>/dev/null; mkdir -p "$H/state/parks-outbox"
date -u +%s > "$H/state/parks-outbox/.dropped-at"; touch -d '@'"$((NOW - 30))" "$H/state/parks-outbox/.dropped-at"
: > "$PARKS_FAKE_CALLS"; : > "$PARKS_FAKE_BODIES"
for i in 1 2 3; do printf 'tproj\tTS-8%s\t8\tfailed\t-\t1\t-\t-\tdied twice\t-\n' "$i"; done > "$T/queue-rows.tsv"
OUT=$(cand BR_PARKS_MODE=shadow)
[ "$(jq -r '.rows[]? | select(.writer == "br-backfill") | .ck' "$PARKS_FAKE_BODIES" | sort | tr '\n' ' ')" = "tproj-TK-81 tproj-TK-82 tproj-TK-83 " ] \
  && ok || bad "D14a cursor 0 from the marker backfills the files rows ($(jq -c '.rows[]?.ck' "$PARKS_FAKE_BODIES" | tr '\n' ' '))"
# (b) the tick wrote a new cursor after the marker: the marker is read once per drop.
C=$(cur)
[ "$C" != 0 ] && [ "$C" = "$(tr -d '\n ' < "$ST/parks/tproj.cursor")" ] && ok || bad "D14b a cursor written after the marker reads the cursor ('$C')"

echo "br-parks-delta.bh-9075: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
