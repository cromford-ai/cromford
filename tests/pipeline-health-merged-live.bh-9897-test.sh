#!/bin/bash
# tests/pipeline-health-merged-live.bh-9897-test.sh — BH-9897 item 4: count the
# live conductor rows whose PR has a `merged` closed-watch memo, and send one
# alert when the count stands above 0 for PH_MC_MERGED_LIVE_ALERT_MIN (60)
# minutes.
#
# THE CENSUS (2026-11-22). 962 of 1,133 live merge-conductor rows belonged to
# PRs that were merged or closed, and nothing paged.
#
#   L   mc_merged_live_count (bin/lib/mc-merged-live.sh) on its own: a live
#       row with a `merged` memo counts; a MERGED row with one does not; an
#       `open` memo does not; field 1 must be exactly `merged`; the prefix
#       slug demox is not demo; an unreadable rows file is rc 1
#   G   the block runs in the fleet part (a ph_fleet group)
#   P1  3 live merged rows, first tick: one log line, the clock starts, 0 alerts
#   P2  61 min later: exactly 1 alert, key mcmergedlive:fleet, names 3 and the
#       slug; with PH_MC_MERGED_LIVE_ALERT_MIN=0 the first tick alerts
#   P3  0 live merged rows: 0 alerts, the clock goes. Rows file absent: 0
#       alerts, the clock stays, +=mcmergedlive:fleet carries in $FIRED
#   P4  knobs unset -> 60 and 86400; knob `abc` -> the same fallbacks; the
#       block appends mcmergedlive to RETRACT_NS
#
# The block is cut out of bin/pipeline-health.sh by its markers and driven with
# a recording alert(). Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

PH="$DIR/bin/pipeline-health.sh"
LIB="$DIR/bin/lib/mc-merged-live.sh"
A=$(grep -c '^# >>> merged rows live (BH-9897)' "$PH"); B=$(grep -c '^# <<< merged rows live' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok || bad "bin/pipeline-health.sh must carry one '# >>> merged rows live' block (open=$A close=$B)"
awk '/^# >>> merged rows live \(BH-9897\)/{f=1;next} /^# <<< merged rows live/{exit} f' "$PH" > "$T/block.sh"
grep -q 'mcmergedlive:fleet' "$T/block.sh" && ok || bad "the extracted block is not the merged-rows-live check"
# A fleet check: the block sits inside a `if ph_fleet; then` group, so the
# --dispatch fleet run counts it and a --project run does not. (The no-progress
# block is per project, inside a ph_proj group, so the block is not beside it.)
GRP=$(awk '/^if ph_(fleet|proj); then$/{g=$0} /^fi # /{g=""} /^# >>> merged rows live \(BH-9897\)/{print g; exit}' "$PH")
[ "$GRP" = "if ph_fleet; then" ] && ok || bad "the block must sit in a top-level ph_fleet group (group: [$GRP])"

H="$T/h"
mkdir -p "$H/state/merge-conductor/closed-watch" "$H/logs" "$H/bin/lib"
# scratch-closure-allow: the one lib the cut-out block sources is copied in so the block can find it at $H/bin/lib; no script is run
[ -r "$LIB" ] && cp "$LIB" "$H/bin/lib/mc-merged-live.sh"
ROWS="$H/state/merge-conductor/pr-state.tsv"
CW="$H/state/merge-conductor/closed-watch"
CLK="$H/state/mc-merged-live/since"
NOW=1795000000
STAMP() { echo "2026-11-22 00:00:00Z"; }
memo() { mkdir -p "$CW/$1"; printf '%s\n' "$3" > "$CW/$1/$2"; }   # memo <safe-slug> <num> <line>
row()  { printf '%s\t%s\t0\th\th\t-\tr\tu\n' "$1" "$2" >> "$ROWS"; }
RNS0=$( eval "$(grep -m1 '^RETRACT_NS=' "$PH")"; printf '%s' "$RETRACT_NS" )
[ "$(grep -c '^RETRACT_NS=' "$PH")" = 1 ] && ok || bad "P4: the block must not add a second '^RETRACT_NS=' line (suites read that line)"
drive() { # drive <now> [VAR=value ...]
  : > "$T/alerts.txt"; : > "$T/fired.txt"; : > "$T/rns.txt"
  local now="$1"; shift
  ( alert() { printf '%s\t%s\t%s\n' "$2" "$1" "$3" >> "$T/alerts.txt"; }
    unset PH_MC_MERGED_LIVE_ALERT_MIN PH_MC_MERGED_LIVE_ALERT_TTL_S
    for kv in "$@"; do export "${kv?}"; done
    NOW="$now"; FIRED="$T/fired.txt"; RETRACT_NS="$RNS0"
    # shellcheck disable=SC1090
    . "$T/block.sh"
    printf '%s\n' "$RETRACT_NS" > "$T/rns.txt" )
}
three() { # three live rows of demo with merged memos, plus near misses
  : > "$ROWS"; scratch_rm "$CW"; mkdir -p "$CW"
  row 'example-org/demo#1' BLOCKED_HUMAN; memo example-org_demo 1 $'merged\t1795000000\turl\tbr'
  row 'example-org/demo#2' HEAD_MOVED;    memo example-org_demo 2 'merged'
  row 'example-org/demo#3' WAIT_CI;       memo example-org_demo 3 $'merged\t1795000000'
  row 'example-org/demo#4' MERGED;        memo example-org_demo 4 'merged'
  row 'example-org/demo#5' READY;         memo example-org_demo 5 'open 1'
}

# ── L: the lib on its own ──
if [ -r "$LIB" ]; then
  : > "$ROWS"; scratch_rm "$CW"; mkdir -p "$CW"
  row 'example-org/demo#1' BLOCKED_HUMAN;  memo example-org_demo 1 'merged'
  row 'example-org/demo#2' MERGED;         memo example-org_demo 2 'merged'
  row 'example-org/demo#3' CLOSED;         memo example-org_demo 3 'merged'
  row 'example-org/demo#4' ABANDONED;      memo example-org_demo 4 'merged'
  row 'example-org/demo#5' WAIT_CI;        memo example-org_demo 5 'open 0'
  row 'example-org/demo#6' WAIT_CI;        memo example-org_demo 6 'mergedx'
  row 'example-org/demo#7' WAIT_CI;        memo example-org_demo 7 'closed 1'
  row 'example-org/demo#8' WAIT_CI
  row 'example-org/demox#9' RED_TWICE;     memo example-org_demox 9 'merged'
  row 'example-org/demox#10' RED_TWICE;    memo example-org_demo 10 'merged'
  row 'example-org/demo#11' NEEDS_REBASE;  memo example-org_demo 11 $'merged\t17\tx'
  row 'example-org/demo#12' NEEDS_REBASE;  memo example-org_demo 12 'merged 17'
  OUT=$( # shellcheck disable=SC1090
    . "$LIB"; mc_merged_live_count "$ROWS" "$CW"); RC=$?
  [ "$RC" = 0 ] && ok || bad "L: rc 0 on a readable rows file (rc=$RC)"
  [ "$OUT" = "$(printf '3\texample-org/demo=2,example-org/demox=1')" ] && ok \
    || bad "L: only live rows with an exact 'merged' field 1 count, slugs sorted: [$OUT]"
  OUT=$( # shellcheck disable=SC1090
    . "$LIB"; mc_merged_live_count "$T/no-such.tsv" "$CW"); RC=$?
  [ "$RC" = 1 ] && [ -z "$OUT" ] && ok || bad "L: an absent rows file is rc 1 with no output (rc=$RC out=[$OUT])"
  OUT=$( # shellcheck disable=SC1090
    . "$LIB"; mc_merged_live_count "$CW" "$CW"); RC=$?
  [ "$RC" = 1 ] && ok || bad "L: a directory is not a rows file (rc=$RC)"
  : > "$T/empty.tsv"
  OUT=$( # shellcheck disable=SC1090
    . "$LIB"; mc_merged_live_count "$T/empty.tsv" "$CW"); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = "$(printf '0\t')" ] && ok || bad "L: an empty rows file is 0 with an empty second field (rc=$RC out=[$OUT])"
  SRC=$(bash -c '. "$1"; echo done' _ "$LIB" 2>&1)
  [ "$SRC" = done ] && ok || bad "L: sourcing the lib has no side effect: [$SRC]"
else
  bad "L: bin/lib/mc-merged-live.sh is missing"
fi

# ── P1: first tick ──
three; rm -f "$CLK" "$H/logs/pipeline-health.log"
drive "$NOW"
[ ! -s "$T/alerts.txt" ] && ok || bad "P1: no alert on the first tick: $(cat "$T/alerts.txt")"
grep -q 'merged-rows-live: 3 (example-org/demo=3)$' "$H/logs/pipeline-health.log" 2>/dev/null && ok \
  || bad "P1: one log line with the count: $(tail -1 "$H/logs/pipeline-health.log" 2>/dev/null)"
[ "$(head -n 1 "$CLK" 2>/dev/null)" = "$NOW" ] && ok || bad "P1: the clock holds the first-seen epoch: $(cat "$CLK" 2>/dev/null)"

# ── P2: 61 min later ──
drive "$((NOW + 3660))"
[ "$(grep -c . "$T/alerts.txt")" = 1 ] && ok || bad "P2: exactly one alert: $(cat "$T/alerts.txt")"
grep -q '^mcmergedlive:fleet	86400	3 conductor row(s) of merged PRs are still live for 61 min (PH_MC_MERGED_LIVE_ALERT_MIN=60): example-org/demo=3. Run bin/mc-stale-rows-sweep.sh, then --apply.$' "$T/alerts.txt" && ok \
  || bad "P2: THE POINT: the alert names 3 and the slug: $(cat "$T/alerts.txt")"
[ "$(head -n 1 "$CLK" 2>/dev/null)" = "$NOW" ] && ok || bad "P2: the clock keeps its first epoch"
rm -f "$CLK"
drive "$NOW" PH_MC_MERGED_LIVE_ALERT_MIN=0
grep -q '^mcmergedlive:fleet	86400	3 conductor row(s) .* still live for 0 min (PH_MC_MERGED_LIVE_ALERT_MIN=0)' "$T/alerts.txt" && ok \
  || bad "P2: knob 0 alerts on the first tick: $(cat "$T/alerts.txt")"

# ── P3: the count is 0; the rows file is absent ──
: > "$ROWS"; scratch_rm "$CW"; mkdir -p "$CW"
row 'example-org/demo#1' MERGED; row 'example-org/demo#2' MERGED; row 'example-org/demo#3' MERGED
row 'example-org/demo#5' READY;  memo example-org_demo 5 'open 1'
row 'example-org/demo#4' MERGED; memo example-org_demo 4 'merged'
printf '%s\n' "$NOW" > "$CLK"; : > "$H/logs/pipeline-health.log"
drive "$((NOW + 7200))"
[ ! -s "$T/alerts.txt" ] && ok || bad "P3: 0 live merged rows, no alert: $(cat "$T/alerts.txt")"
[ ! -e "$CLK" ] && ok || bad "P3: a count of 0 removes the clock"
grep -q 'merged-rows-live' "$H/logs/pipeline-health.log" && bad "P3: no log line at 0" || ok
grep -q 'mcmergedlive' "$T/fired.txt" && bad "P3: a clear writes no carry marker: $(cat "$T/fired.txt")" || ok
rm -f "$ROWS"; printf '%s\n' "$NOW" > "$CLK"
drive "$((NOW + 7200))"
[ ! -s "$T/alerts.txt" ] && ok || bad "P3: an absent rows file sends no alert: $(cat "$T/alerts.txt")"
[ "$(head -n 1 "$CLK" 2>/dev/null)" = "$NOW" ] && ok || bad "P3: an absent rows file leaves the clock as it was"
grep -qx '+=mcmergedlive:fleet' "$T/fired.txt" && ok || bad "P3: an absent rows file carries the key (a skip is not a clear): $(cat "$T/fired.txt")"
# The lib missing on the box: skipped with a carry, never a clear.
three; printf '%s\n' "$NOW" > "$CLK"; mv "$H/bin/lib/mc-merged-live.sh" "$T/lib.bak" 2>/dev/null
drive "$((NOW + 7200))"
[ ! -s "$T/alerts.txt" ] && [ -e "$CLK" ] && grep -qx '+=mcmergedlive:fleet' "$T/fired.txt" && ok \
  || bad "P3: a missing lib skips with a carry: alerts=[$(cat "$T/alerts.txt")] fired=[$(cat "$T/fired.txt")]"
mv "$T/lib.bak" "$H/bin/lib/mc-merged-live.sh" 2>/dev/null

# ── P4: defaults and fallbacks ──
for K in "" abc; do
  three; printf '%s\n' "$((NOW - 3540))" > "$CLK"
  if [ -n "$K" ]; then drive "$NOW" PH_MC_MERGED_LIVE_ALERT_MIN="$K" PH_MC_MERGED_LIVE_ALERT_TTL_S="$K"; else drive "$NOW"; fi
  [ ! -s "$T/alerts.txt" ] && ok || bad "P4[${K:-unset}]: 59 min is under the 60 default: $(cat "$T/alerts.txt")"
  printf '%s\n' "$((NOW - 3600))" > "$CLK"
  if [ -n "$K" ]; then drive "$NOW" PH_MC_MERGED_LIVE_ALERT_MIN="$K" PH_MC_MERGED_LIVE_ALERT_TTL_S="$K"; else drive "$NOW"; fi
  grep -q '^mcmergedlive:fleet	86400	3 conductor row(s) .* for 60 min (PH_MC_MERGED_LIVE_ALERT_MIN=60)' "$T/alerts.txt" && ok \
    || bad "P4[${K:-unset}]: 60 min and TTL 86400 are the defaults: $(cat "$T/alerts.txt")"
done
three; printf '%s\n' "$((NOW - 600))" > "$CLK"
drive "$NOW" PH_MC_MERGED_LIVE_ALERT_MIN=10 PH_MC_MERGED_LIVE_ALERT_TTL_S=3600
grep -q '^mcmergedlive:fleet	3600	.*(PH_MC_MERGED_LIVE_ALERT_MIN=10)' "$T/alerts.txt" && ok \
  || bad "P4: set knobs are read: $(cat "$T/alerts.txt")"
RNS=$(cat "$T/rns.txt")
grep -qE "^($RNS):" <<<"mcmergedlive:fleet" && ok || bad "P4: mcmergedlive is not in RETRACT_NS after the block: [$RNS]"
grep -qE "^($RNS0):" <<<"mcmergedlive:fleet" && bad "P4: the shared RETRACT_NS= line must not carry mcmergedlive (the block appends it)" || ok

echo "pipeline-health-merged-live.bh-9897: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
