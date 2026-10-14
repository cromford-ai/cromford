#!/bin/bash
# tests/pipeline-health-closeout-skip.bh-5941-test.sh — an aged-out close-out
# row is not read again on the next tick (BH-5941, AT-2).
#
# Checks 4 and 5 of bin/pipeline-health.sh are extracted VERBATIM by their
# markers, as in tests/pipeline-health-closeout-ageout-test.sh, and driven
# against a scratch tree with the real bin/lib/closeout-terminal.sh. The stubs:
#   bin/queued-fly-relayed.sh  records the dir it was asked about, exits 1
#   closeout_aged_table_on     answers 0 (the BH-1033 table flag is on)
#   closeout_aged_put          records the dir; rc 0 the first time, 3 after
# So qfr.calls and put.calls count exactly the per-dir work the skip set must
# stop: the fork and the worker call.
#
#   AT-2a  tick 2 reads nothing for a dir tick 1 aged out
#   AT-2b  an empty-url dir is recorded once, kind emptyurl; check 5 skips it
#   AT-2c  a rewritten RESULT is judged again (and pages)
#   AT-2d  a raised CLOSEOUT_AGE_OUT_H is judged again (and pages)
#   AT-2e  a failed record is not added to the skip set
#   AT-2f  a dir that is gone is pruned from the skip file
#   AT-2g  junk lines are ignored; a lib with no skip-set block is today's path
#   AT-2h  a live (2h) dir never enters the skip file
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-closeout-skip.bh-5941-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/locks" "$T/builds"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

printf 'x-os o/r https://x.example /api/board 2 local\n' > "$T/fleet.conf"
cat > "$T/bin/queued-fly-relayed.sh" <<'QFR'
#!/bin/bash
printf '%s\n' "${2##*/}" >> "$HARNESS/qfr.calls"
exit 1
QFR
chmod +x "$T/bin/queued-fly-relayed.sh"

awk '/^# >>> no board close-out/{f=1;next} /^# <<< no board close-out/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c4.sh"
awk '/^# >>> empty url/{f=1;next} /^# <<< empty url/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/c5.sh"
[ -s "$T/c4.sh" ] && [ -s "$T/c5.sh" ] && ok || bad "could not extract the close-out blocks — markers missing?"
# scratch-closure-allow: this suite unit-tests closeout-terminal.sh itself (a full and a stripped copy), it runs no lane
cp "$DIR/bin/lib/closeout-terminal.sh" "$T/bin/lib/closeout-terminal.sh" || bad "bin/lib/closeout-terminal.sh is missing"
# The same lib with the skip-set block cut out between its markers (AT-2g).
awk '/^# >>> closeout skip set \(BH-5941\)/{f=1;next} /^# <<< closeout skip set/{f=0;next} !f' \
  "$T/bin/lib/closeout-terminal.sh" > "$T/bin/lib/closeout-noskip.sh"
grep -q 'closeout skip set (BH-5941)' "$T/bin/lib/closeout-terminal.sh" \
  && ok || bad "the lib has no '# >>> closeout skip set (BH-5941)' block"

NOW=$(date +%s)
TSV="$T/state/closeout-aged-out.tsv"
SKIP="$T/state/pipeline-health/x-os/closeout-aged.tsv"
H200=720000; H30=108000; H2=7200

# drive <block> [VAR=VAL ...] — one extracted block against the scratch tree.
# LIB=<file> picks the lib copy; FAIL_RECORD=1 makes closeout_record_aged fail.
drive() {
  local blk="$1"; shift
  : > "$T/alerts.txt"; : > "$T/err.txt"
  ( export HARNESS="$T" T="$T" NOW_PIN="$NOW"
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW="$NOW_PIN"; PROJECTS="x-os"
      STAMP() { echo TS; }
      alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
      . "$T/bin/lib/${LIB:-closeout-terminal.sh}"
      closeout_aged_table_on() { return 0; }
      closeout_aged_put() {
        printf "%s\n" "$2" >> "$T/put.calls"
        grep -qxF "$2" "$T/put.seen" 2>/dev/null && return 3
        printf "%s\n" "$2" >> "$T/put.seen"; return 0; }
      [ "${FAIL_RECORD:-0}" = 1 ] && closeout_record_aged() { return 1; }
      . "$0"' "$T/$blk.sh" 2>"$T/err.txt" )
}
mkrec() { # mkrec <dirname> <age-seconds> <RESULT first line>
  local d="$T/builds/$1"; mkdir -p "$d"
  printf '%s\n' "$3" > "$d/RESULT"
  touch -d "@$(( NOW - $2 ))" "$d/RESULT"
}
reset() {
  rm -rf "$T/builds" "$T/state/pipeline-health"; mkdir -p "$T/builds"
  rm -f "$TSV" "$T/qfr.calls" "$T/put.calls" "$T/put.seen"
  : > "$T/logs/pipeline-health.log"
}
n() { [ -s "$1" ] && grep -c . "$1" || echo 0; }
alerts() { cat "$T/alerts.txt" 2>/dev/null; }
health() { cat "$T/logs/pipeline-health.log" 2>/dev/null; }

echo "--- AT-2a: an aged-out row is not read again"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
drive c4
[ "$(n "$T/qfr.calls")" = 1 ] && ok || bad "AT-2a tick 1: qfr.calls=$(n "$T/qfr.calls"), want 1"
[ "$(n "$T/put.calls")" = 1 ] && ok || bad "AT-2a tick 1: put.calls=$(n "$T/put.calls"), want 1"
[ "$(n "$TSV")" = 1 ] && ok || bad "AT-2a tick 1: tsv rows=$(n "$TSV"), want 1"
grep -qxF "x-os-TK-1-202607010000"$'\t'"$((NOW - H200))"$'\t'"aged" "$SKIP" 2>/dev/null \
  && ok || bad "AT-2a tick 1: skip file wrong: $(cat "$SKIP" 2>/dev/null) err=$(cat "$T/err.txt")"
cp "$TSV" "$T/tsv.1"; : > "$T/logs/pipeline-health.log"
drive c4
[ "$(n "$T/qfr.calls")" = 1 ] && ok || bad "AT-2a tick 2: qfr was forked again (qfr.calls=$(n "$T/qfr.calls"))"
[ "$(n "$T/put.calls")" = 1 ] && ok || bad "AT-2a tick 2: closeout_aged_put was called again (put.calls=$(n "$T/put.calls"))"
cmp -s "$T/tsv.1" "$TSV" && ok || bad "AT-2a tick 2: the audit tsv changed"
health | grep -q 'x-os close-out: aged-out 1, terminal 0, still-open 0' \
  && ok || bad "AT-2a tick 2: summary wrong: $(health)"
[ ! -s "$T/alerts.txt" ] && ok || bad "AT-2a tick 2: an aged dir paged: $(alerts)"
[ ! -s "$T/err.txt" ] && ok || bad "AT-2a: stderr: $(cat "$T/err.txt")"

echo "--- AT-2b: an empty-url dir, c4 then c5"
reset
mkrec pool-x-os-TK-5-202607241847 "$H200" "PR_CREATED "
drive c4; drive c5
grep -qxF "pool-x-os-TK-5-202607241847"$'\t'"$((NOW - H200))"$'\t'"emptyurl" "$SKIP" 2>/dev/null \
  && ok || bad "AT-2b tick 1: kind emptyurl not recorded: $(cat "$SKIP" 2>/dev/null)"
[ "$(n "$SKIP")" = 1 ] && ok || bad "AT-2b tick 1: skip file has $(n "$SKIP") lines, want 1"
PUT1=$(n "$T/put.calls"); : > "$T/logs/pipeline-health.log"
drive c4; drive c5
health | grep -q 'x-os empty-url: aged-out 1, still-open 0' \
  && ok || bad "AT-2b tick 2: c5 summary wrong: $(health)"
[ "$(n "$T/put.calls")" = "$PUT1" ] && ok || bad "AT-2b tick 2: put.calls grew $PUT1 -> $(n "$T/put.calls")"
[ ! -s "$T/alerts.txt" ] && ok || bad "AT-2b tick 2: paged: $(alerts)"

echo "--- AT-2c: a rewritten RESULT is judged again"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
drive c4
touch -d "@$(( NOW - H2 ))" "$T/builds/x-os-TK-1-202607010000/RESULT"
drive c4
alerts | grep -q '^7200|uncommented:x-os:1|' && ok || bad "AT-2c: the rewritten dir did not page: $(alerts)"
[ "$(n "$T/qfr.calls")" = 2 ] && ok || bad "AT-2c: qfr.calls=$(n "$T/qfr.calls"), want 2"
grep -q '^x-os-TK-1-202607010000' "$SKIP" 2>/dev/null && bad "AT-2c: the stale skip line was kept: $(cat "$SKIP")" || ok

echo "--- AT-2d: a raised ceiling is judged again"
reset
mkrec x-os-TK-1-202607010000 "$H30" "PR_CREATED https://github.com/o/r/pull/1"
drive c4 CLOSEOUT_AGE_OUT_H=24
[ ! -s "$T/alerts.txt" ] && grep -q $'\taged$' "$SKIP" 2>/dev/null && ok || bad "AT-2d setup: 30h dir not aged at 24h: $(alerts) skip=$(cat "$SKIP" 2>/dev/null)"
drive c4 CLOSEOUT_AGE_OUT_H=168
alerts | grep -q '^7200|uncommented:x-os:1|' && ok || bad "AT-2d: a raised ceiling did not page: $(alerts)"

echo "--- AT-2e: a failed record is not skipped"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
drive c4 FAIL_RECORD=1
drive c4 FAIL_RECORD=1
[ "$(n "$T/qfr.calls")" = 2 ] && ok || bad "AT-2e: qfr.calls=$(n "$T/qfr.calls"), want 2"
grep -q '^x-os-TK-1-202607010000' "$SKIP" 2>/dev/null && bad "AT-2e: a failed record entered the skip file" || ok

echo "--- AT-2f: a dir that is gone is pruned"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
mkrec x-os-TK-2-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/2"
drive c4
[ "$(n "$SKIP")" = 2 ] && ok || bad "AT-2f setup: skip lines=$(n "$SKIP"), want 2"
rm -rf "$T/builds/x-os-TK-1-202607010000"
drive c4
grep -q '^x-os-TK-1-' "$SKIP" 2>/dev/null && bad "AT-2f: the gone dir is still in the skip file" || ok
grep -q '^x-os-TK-2-202607010000'$'\t' "$SKIP" 2>/dev/null && ok || bad "AT-2f: the live entry was dropped: $(cat "$SKIP" 2>/dev/null)"

echo "--- AT-2g: junk lines, and a lib with no skip-set block"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
mkdir -p "${SKIP%/*}"
printf 'notab\nx-os-TK-1-202607010000\tabc\taged\nx-os-TK-1-202607010000\t%s\tzzz\n' "$((NOW - H200))" > "$SKIP"
drive c4
[ ! -s "$T/err.txt" ] && ok || bad "AT-2g: junk lines wrote stderr: $(cat "$T/err.txt")"
[ "$(n "$T/qfr.calls")" = 1 ] && [ "$(n "$T/put.calls")" = 1 ] && ok \
  || bad "AT-2g: junk lines changed the verdict (qfr=$(n "$T/qfr.calls") put=$(n "$T/put.calls"), want 1 1)"
reset
mkrec x-os-TK-1-202607010000 "$H200" "PR_CREATED https://github.com/o/r/pull/1"
drive c4 LIB=closeout-noskip.sh
drive c4 LIB=closeout-noskip.sh
[ ! -e "$SKIP" ] && ok || bad "AT-2g: no skip-set lib, but a skip file was written"
[ "$(n "$T/qfr.calls")" = 2 ] && ok || bad "AT-2g: no skip-set lib must judge the dir every tick (qfr.calls=$(n "$T/qfr.calls"))"
health | grep -q 'aged-out 1, terminal 0, still-open 0' && ok || bad "AT-2g: summary wrong with no skip lib: $(health)"
[ ! -s "$T/err.txt" ] && ok || bad "AT-2g: no skip-set lib wrote stderr: $(cat "$T/err.txt")"

echo "--- AT-2h: a live dir never enters the skip file"
reset
mkrec x-os-TK-3-202610100000 "$H2" "PR_CREATED https://github.com/o/r/pull/3"
drive c4; drive c5; drive c4
grep -q '^x-os-TK-3-' "$SKIP" 2>/dev/null && bad "AT-2h: a 2h dir entered the skip file" || ok
alerts | grep -q '^7200|uncommented:x-os:1|' && ok || bad "AT-2h: the live dir stopped paging: $(alerts)"

echo "pipeline-health-closeout-skip: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
