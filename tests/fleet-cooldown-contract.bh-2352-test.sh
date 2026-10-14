#!/bin/bash
# tests/fleet-cooldown-contract.bh-2352-test.sh — BH-2352 (BH-2319.0): the
# contract every other slice of #2319 imports. Sources the REAL
# bin/lib/fleet-cooldown.sh and drives fcd_put / fcd_clear / fcd_live / fcd_list
# against a FLEET_COOLDOWN_STORE file in $T.
#
#   A1  put then live rc 0; an expired put and a never-put key rc 1
#   A2  account codex/default does not make account claude/default live (BH-940)
#   A3  model claude-fable-x/a does not make claude-fable-x/b or claude-fable-x live
#   A4  lane openrouter/hub does not make codex/hub or openrouter/small live
#   A5  upsert: account keeps the later until, lane refreshes it, since is kept
#   A6  clear rc 0, then rc 1, and live rc 1 after
#   A7  FLEET_COOLDOWN_DB=0 writes nothing; live/clear rc 2, list empty
#   A8  no store, worker not configured: put 0, live/clear 2, list empty, survives set -euo pipefail
#   A9  list prints live rows of the kind only, six tab-separated fields;
#       16 concurrent puts to one store lose no row; 16 concurrent clears
#       (8 hits, 8 misses) each return their own rc
#   A10 the fleet_cooldowns table and its (kind, until_at) index are in schema.sql
#   A11 sourcing the lib creates no file and prints nothing
#   A12 bad input: a non-numeric until writes nothing, an unknown kind is rc 2
#   A13 neither HARNESS nor H set: no state dir, and a lane put/clear/live still
#       answers from the store and writes no file outside it
#
# No clock pinning: every live until is 4102444800 (2100-01-01), every expired one is 1.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/fleet-cooldown-contract.bh-2352-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/fleet-cooldown.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# rc_is <want> <label> <cmd...>
rc_is() { local want=$1 label=$2 rc=0; shift 2; "$@" || rc=$?; if [ "$rc" = "$want" ]; then ok; else bad "$label: rc=$rc want $want"; fi; }

unset FLEET_COOLDOWN_DB FLEET_COOLDOWN_STORE
# TEST-CHANGE (BH-2353): the lib keeps a cache and a lane clear guard under
# $HARNESS/state/fleet-cooldown, so the suite roots it in $T. Unrooted it touches
# nothing at all (A13); it never falls back to a real /root/harness.
export HARNESS="$T"
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
FUT=4102444800
PAST=1
S="$T/store.tsv"
export FLEET_COOLDOWN_STORE="$S"

# ---------- A1 ---------------------------------------------------------------
rc_is 0 "A1 put live" fcd_put account claude a "$FUT"
rc_is 0 "A1 live after put" fcd_live account claude a
rc_is 0 "A1 put expired" fcd_put account claude b "$PAST"
rc_is 1 "A1 live on expired" fcd_live account claude b
rc_is 1 "A1 live on never-put key" fcd_live account claude nobody

# ---------- A2 (BH-940 negative) --------------------------------------------
fcd_put account codex default "$FUT"
rc_is 1 "A2 codex/default makes claude/default live" fcd_live account claude default
rc_is 0 "A2 codex/default itself live" fcd_live account codex default

# ---------- A3 ---------------------------------------------------------------
fcd_put model claude claude-fable-x/a "$FUT"
rc_is 1 "A3 x/a makes x/b live" fcd_live model claude claude-fable-x/b
rc_is 1 "A3 x/a makes unsuffixed x live" fcd_live model claude claude-fable-x
rc_is 0 "A3 x/a itself live" fcd_live model claude claude-fable-x/a

# ---------- A4 ---------------------------------------------------------------
fcd_put lane openrouter hub "$FUT"
rc_is 1 "A4 openrouter/hub makes codex/hub live" fcd_live lane codex hub
rc_is 1 "A4 openrouter/hub makes openrouter/small live" fcd_live lane openrouter small
rc_is 0 "A4 openrouter/hub itself live" fcd_live lane openrouter hub

# ---------- A5 upsert ---------------------------------------------------------
row_of() { fcd_list "$1" | awk -F'\t' -v v="$2" -v s="$3" '$1==v && $2==s'; }
fcd_put account claude c "$FUT" 100 r1
fcd_put account claude c "$((FUT-1000))" 200 r2
r=$(row_of account claude c)
[ "$(printf '%s' "$r" | cut -f3)" = "$FUT" ] && ok || bad "A5 account shorter put shortened until: $r"
[ "$(printf '%s' "$r" | cut -f4)" = "100" ] && ok || bad "A5 account since not kept: $r"
[ "$(printf '%s' "$r" | cut -f5)" = "r2" ] && ok || bad "A5 account reason not the latest: $r"
fcd_put lane claude hub "$FUT" 100
fcd_put lane claude hub "$((FUT-1000))" 200
r=$(row_of lane claude hub)
[ "$(printf '%s' "$r" | cut -f3)" = "$((FUT-1000))" ] && ok || bad "A5 lane put did not refresh until: $r"
[ "$(printf '%s' "$r" | cut -f4)" = "100" ] && ok || bad "A5 lane since not kept: $r"
[ "$(grep -c "^lane	claude	hub	" "$S")" = 1 ] && ok || bad "A5 upsert duplicated the lane row"

# ---------- A6 clear ----------------------------------------------------------
rc_is 0 "A6 first clear" fcd_clear account claude a
rc_is 1 "A6 second clear" fcd_clear account claude a
rc_is 1 "A6 live after clear" fcd_live account claude a
rc_is 0 "A6 clear of an expired row still removes a row" fcd_clear account claude b

# ---------- A7 FLEET_COOLDOWN_DB=0 -------------------------------------------
(
  export FLEET_COOLDOWN_DB=0 FLEET_COOLDOWN_STORE="$T/off.tsv"
  rc_is 0 "A7 put" fcd_put account claude a "$FUT"
  [ ! -e "$T/off.tsv" ] && ok || bad "A7 DB=0 put wrote $T/off.tsv"
  rc_is 2 "A7 live" fcd_live account claude a
  rc_is 2 "A7 clear" fcd_clear account claude a
  [ -z "$(fcd_list account)" ] && ok || bad "A7 list printed something"
  echo "$PASS $FAIL" > "$T/a7.counts"
)
read -r PASS FAIL < "$T/a7.counts"
# DB=0 must also leave an EXISTING store untouched.
before=$(cksum < "$S")
FLEET_COOLDOWN_DB=0 fcd_put account claude zz "$FUT"
[ "$(cksum < "$S")" = "$before" ] && ok || bad "A7 DB=0 put changed an existing store"

# ---------- A8 worker not configured, under set -euo pipefail ----------------
# TEST-CHANGE (BH-2353): the worker branch is real now, so A8 pins it to $T with
# no secret and no URL. Without that it would read the box's env and PUT a real
# row into the fleet's worker. The answers are the contract's "unknown" ones.
mkdir -p "$T/logs" "$T/env"
out=$(env -u FLEET_COOLDOWN_STORE -u FLEET_COOLDOWN_DB -u HARNESS_SECRET -u JOBS_URL \
      HARNESS="$T" HARNESS_ENV_DIR="$T/env" bash -c '
  set -euo pipefail
  . "$1"
  fcd_put account claude a 4102444800
  rc=0; fcd_live account claude a || rc=$?; echo "live=$rc"
  rc=0; fcd_clear account claude a || rc=$?; echo "clear=$rc"
  echo "list=[$(fcd_list account)]"
  echo survived' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "A8 set -e subshell rc=$rc: $out"
[ "$out" = "$(printf 'live=2\nclear=2\nlist=[]\nsurvived')" ] && ok || bad "A8 output: $out"
[ "$(grep -c 'fleet-cooldown: put account/claude/a not recorded' "$T/logs/agent-rules.log" 2>/dev/null)" = 1 ] \
  && ok || bad "A8 the unrecorded put was not logged in \$T"

# ---------- A9 list -----------------------------------------------------------
S9="$T/list.tsv"
FLEET_COOLDOWN_STORE="$S9" fcd_put account claude live1 "$FUT" 50 "why	with tab"
FLEET_COOLDOWN_STORE="$S9" fcd_put account claude dead1 "$PAST"
FLEET_COOLDOWN_STORE="$S9" fcd_put model claude m1 "$FUT"
out=$(FLEET_COOLDOWN_STORE="$S9" fcd_list account)
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && ok || bad "A9 list rows: [$out]"
[ "$(printf '%s' "$out" | awk -F'\t' '{print NF}')" = 6 ] && ok || bad "A9 list fields: [$out]"
[ "$(printf '%s' "$out" | cut -f1,2)" = "$(printf 'claude\tlive1')" ] && ok || bad "A9 list vendor/subject: [$out]"
[ "$(printf '%s' "$out" | cut -f5)" = "why with tab" ] && ok || bad "A9 reason not sanitized: [$out]"
FLEET_COOLDOWN_STORE="$S9" fcd_put account claude bs1 "$FUT" "" 'a\tb'
[ "$(FLEET_COOLDOWN_STORE="$S9" fcd_list account | awk -F'\t' '$2=="bs1" {print NF "|" $5}')" = '6|a\tb' ] && ok || bad "A9 a backslash in the reason was expanded"
[ -z "$(FLEET_COOLDOWN_STORE="$T/absent.tsv" fcd_list account)" ] && ok || bad "A9 absent store printed rows"
rc_is 1 "A9 absent store live" env FLEET_COOLDOWN_STORE="$T/absent.tsv" bash -c '. "$1"; fcd_live account claude a' _ "$LIB"
rc_is 2 "A9 missing store dir live" env FLEET_COOLDOWN_STORE="$T/nodir/s.tsv" bash -c '. "$1"; fcd_live account claude a' _ "$LIB"

# Concurrent puts to one store (two simulated boxes) lose no row.
SC="$T/conc.tsv"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
  FLEET_COOLDOWN_STORE="$SC" fcd_put account claude "acct$i" "$FUT" &
done
wait
[ "$(wc -l < "$SC")" = 16 ] && ok || bad "A9 concurrent puts lost rows: $(wc -l < "$SC") of 16"

# Concurrent clears from one shell: each call answers for its own row. Eight
# hits must each be rc 0 and eight misses each rc 1, and no marker is left.
RD="$T/conc-rc"; mkdir -p "$RD"
for i in 1 2 3 4 5 6 7 8; do
  ( FLEET_COOLDOWN_STORE="$SC" fcd_clear account claude "acct$i"; echo "$?" > "$RD/hit$i" ) &
  ( FLEET_COOLDOWN_STORE="$SC" fcd_clear account claude "nope$i"; echo "$?" > "$RD/miss$i" ) &
done
wait
wrong=""
for i in 1 2 3 4 5 6 7 8; do
  [ "$(cat "$RD/hit$i")" = 0 ] || wrong="$wrong hit$i=$(cat "$RD/hit$i")"
  [ "$(cat "$RD/miss$i")" = 1 ] || wrong="$wrong miss$i=$(cat "$RD/miss$i")"
done
[ -z "$wrong" ] && ok || bad "A9 concurrent clears answered wrong:$wrong"
[ "$(wc -l < "$SC")" = 8 ] && ok || bad "A9 concurrent clears left $(wc -l < "$SC") of 8 rows"
[ -z "$(ls "$T" | grep 'conc.tsv.cleared')" ] && ok || bad "A9 clear markers left behind"

# ---------- A10 schema --------------------------------------------------------
[ "$(grep -c fleet_cooldowns "$DIR/worker/jobs/schema.sql")" -ge 1 ] && ok || bad "A10 no fleet_cooldowns in schema.sql"
[ "$(grep -c 'ON fleet_cooldowns(kind, until_at)' "$DIR/worker/jobs/schema.sql")" = 1 ] && ok || bad "A10 index on (kind, until_at) missing"
grep -Eq 'PRIMARY KEY \(kind, vendor, subject\)' "$DIR/worker/jobs/schema.sql" && ok || bad "A10 PK (kind, vendor, subject) missing"

# ---------- A11 sourcing has no side effects ---------------------------------
mkdir -p "$T/empty"
out=$(cd "$T/empty" && bash -c 'set -euo pipefail; . "$1"; . "$1"' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok || bad "A11 source rc=$rc out=[$out]"
[ -z "$(ls -A "$T/empty")" ] && ok || bad "A11 source created files: $(ls -A "$T/empty")"

# ---------- A12 bad input -----------------------------------------------------
rc_is 0 "A12 put non-numeric until" fcd_put account claude badu notanumber
[ "$(awk -F'\t' '$3=="badu"' "$S" | wc -l)" = 0 ] && ok || bad "A12 non-numeric until was written"
rc_is 0 "A12 put non-numeric since" fcd_put account claude bads "$FUT" yesterday
[ "$(awk -F'\t' '$3=="bads"' "$S" | wc -l)" = 0 ] && ok || bad "A12 non-numeric since was written"
rc_is 2 "A12 live unknown kind" fcd_live bogus claude a
rc_is 2 "A12 clear unknown kind" fcd_clear bogus claude a
rc_is 2 "A12 live empty subject" fcd_live account claude ""
rc_is 0 "A12 put tabbed subject" fcd_put account claude "x	y" "$FUT"
[ "$(awk -F'\t' 'NF!=8' "$S" | wc -l)" = 0 ] && ok || bad "A12 a tabbed subject corrupted the store"

# ---------- A13 unrooted: no state dir, no real path -------------------------
mkdir -p "$T/a13"
out=$(cd "$T/a13" && env -u HARNESS -u H FLEET_COOLDOWN_STORE="$T/a13/s.tsv" bash -c '
  set -euo pipefail
  . "$1"
  rc=0; _fcd_state >/dev/null || rc=$?; echo "state=$rc"
  fcd_put lane openrouter hub 4102444800
  rc=0; fcd_clear lane openrouter hub || rc=$?; echo "clear=$rc"
  rc=0; fcd_live lane openrouter hub || rc=$?; echo "live=$rc"' _ "$LIB" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'state=1\nclear=0\nlive=1')" ] && ok || bad "A13 unrooted rc=$rc out=[$out]"
[ "$(ls -A "$T/a13")" = "s.tsv
s.tsv.lock" ] && ok || bad "A13 unrooted lane clear wrote outside the store: $(ls -A "$T/a13")"

echo "fleet-cooldown-contract: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
