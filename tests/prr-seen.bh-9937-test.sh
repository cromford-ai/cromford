#!/bin/bash
# tests/prr-seen.bh-9937-test.sh — BH-9937 (BH-9926 wave 5): the per-PR wake
# gate bin/lib/prr-seen.sh, "stop reading a PR that had no wake since its last
# read". The wake feed is the REAL prs_wake_seen (bin/lib/pr-snapshot-wakes.sh)
# on a seeded changed.tsv and wakes.state, in the format _prsw_refresh writes,
# and the decision is the REAL wb_due (bin/lib/wake-backstop.sh).
#
#   S1-S17  the decision table of prr_seen_due (plan, Failure modes), first
#           match wins: no-state, head, wake:pr:<n>, wake:checks:<head>,
#           no-feed, backstop, off, quiet, and the near misses
#   S18     a bad lane id or a bad head is no-state (read now), never quiet
#   RT      round trip: mark -> due rc 1; keep without n -> due rc 0 no-state;
#           keep with n keeps the row
#   L2      two lanes, one mark each: each lane reads only its own row
#   LK      a held lock: prr_seen_mark rc 0 and the file is not written
#   KB      the knob PRR_SEEN_BACKSTOP_S is registered (lib prr-seen, int,
#           default 1800, min 0, max 86400) and the state path is a cache
#
# The real prs_wake_seen bounds its window on the box clock (as WB9 of
# tests/wake-backstop.bh-6976-test.sh does), so every epoch here is computed
# from one NOWR read, and wb_due's clock is pinned to the same value through
# WAKE_BACKSTOP_NOW (the sandbox seam).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/prr-seen.bh-9937-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/prr-seen.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$LIB" ] || { echo "FAIL: $LIB is missing"; echo "prr-seen.bh-9937: 0 passed, 1 failed"; exit 1; }

"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "prr-seen.bh-9937: 0 passed, 1 failed"; exit 1; }

NOWR=$(date +%s)  # determinism: ok the real prs_wake_seen reads the box clock; wb_due is pinned to this value
H="$T/h"; mkdir -p "$H"
SLUG=o/r; SD="$H/state/pr-snapshot/o_r"
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); AU=$(printf 'A%.0s' {1..40})
LANE=pr-state-reconcile
SEEN="$H/state/prr-seen/$LANE/o_r.tsv"
cat > "$T/jobs.sh" <<'EOF'
_jobs_req() { case "$2" in /api/settings*) echo '{"settings":[]}' ;; *) return 1 ;; esac; }
EOF

# feed <complete> [kind:key:at]... — the mirror the real prs_wake_seen reads
feed() {
  local c="$1" r k y a i=100; shift
  scratch_rm "$SD"; mkdir -p "$SD"
  printf '%s\t%s\t1\t%s\n' "$NOWR" "$c" "$((NOWR - 7200))" > "$SD/wakes.state"
  echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
  for r in "$@"; do
    IFS=: read -r k y a <<<"$r"; i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$k" "$y" "$i" "$a" >> "$SD/changed.tsv"
  done
}
# seen <row>... — the lane's mark file, written as is
seen() { mkdir -p "$(dirname "$SEEN")"; : > "$SEEN"; local r; for r in "$@"; do printf '%s\n' "$r" >> "$SEEN"; done; }
# run [VAR=val...] -- <shell> — one call in a clean env; sets OUT and RC
run() {
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 WAKE_BACKSTOP_NOW="$NOWR" LANE_REGISTRY="$T/lanes.json" \
    "${envs[@]}" bash -c '. "$T/jobs.sh"; . "$LIB"; '"$1" 2>"$T/err")
  RC=$?
}
# want <case> <rc> <word> <call args...>
want() {
  local c="$1" r="$2" w="$3"; shift 3
  local -a envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" LIB="$LIB" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 WAKE_BACKSTOP_NOW="$NOWR" LANE_REGISTRY="$T/lanes.json" \
    "${envs[@]}" bash -c '. "$T/jobs.sh"; . "$LIB"; prr_seen_due "$@"' _ "$@" 2>"$T/err")
  RC=$?
  [ "$RC" = "$r" ] && [ "$OUT" = "$w" ] && ok || bad "$c wanted rc $r '$w', got rc $RC '$OUT' ($(head -3 "$T/err"))"
}
M=$((NOWR - 30))

# S1 no file
feed 1; rm -f "$SEEN"
want S1 0 no-state -- "$LANE" "$SLUG" 7 "$A"
# S2 a row for another PR only
seen "8	$M	$A"
want S2 0 no-state -- "$LANE" "$SLUG" 7 "$A"
# S3 malformed rows: a non-digit epoch, a short head
seen "7	abc	$A"
want S3 0 no-state -- "$LANE" "$SLUG" 7 "$A"
seen "7	$M	abc123"
want S3b 0 no-state -- "$LANE" "$SLUG" 7 "$A"
# S4 the row's head is an upper-case copy of the asked head: the same head (near miss)
seen "7	$M	$AU"
want S4 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S5 the row's head differs
seen "7	$M	$A"
want S5 0 head -- "$LANE" "$SLUG" 7 "$B"
# S6 a pr wake for this n after the mark
feed 1 "pr:7:$((NOWR - 5))"
want S6 0 wake:pr:7 -- "$LANE" "$SLUG" 7 "$A"
# S7 a pr wake for ANOTHER n after the mark (near miss)
feed 1 "pr:8:$((NOWR - 5))"
want S7 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S8 a pr wake for this n two minutes BEFORE the mark (near miss)
feed 1 "pr:7:$((M - 120))"
want S8 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S9 a checks wake keyed on this head
feed 1 "checks:$A:$((NOWR - 5))"
want S9 0 "wake:checks:$A" -- "$LANE" "$SLUG" 7 "$A"
# S10 a checks wake keyed on another head (near miss)
feed 1 "checks:$B:$((NOWR - 5))"
want S10 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S11 an issue wake with key = this n (another kind, near miss)
feed 1 "issue:7:$((NOWR - 5))"
want S11 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S12 a push wake on the base (near miss: the gate asks pr and checks only)
feed 1 "push:$B:$((NOWR - 5))"
want S12 1 quiet -- "$LANE" "$SLUG" 7 "$A"
# S13 the feed cannot tell (wakes.state incomplete)
feed 0
want S13 0 no-feed -- "$LANE" "$SLUG" 7 "$A"
# S14 a mark older than the backstop
feed 1; seen "7	$((NOWR - 2000))	$A"
want S14 0 backstop -- "$LANE" "$SLUG" 7 "$A"
# S15 the knob 0 is off
seen "7	$M	$A"
want S15 0 off PRR_SEEN_BACKSTOP_S=0 -- "$LANE" "$SLUG" 7 "$A"
# S16 WAKE_BACKSTOP=0 is off
want S16 0 off WAKE_BACKSTOP=0 -- "$LANE" "$SLUG" 7 "$A"
# S17 a mark 30 s old, no wakes, knob 1800
want S17 1 quiet PRR_SEEN_BACKSTOP_S=1800 -- "$LANE" "$SLUG" 7 "$A"
# S18 a bad lane id, a bad number or a bad head is read now, never quiet
want S18 0 no-state -- "Bad_Lane" "$SLUG" 7 "$A"
want S18b 0 no-state -- "$LANE" "$SLUG" 07x "$A"
want S18c 0 no-state -- "$LANE" "$SLUG" 7 "not-a-sha"
want S18d 0 no-state -- "$LANE" "" 7 "$A"

# RT round trip: mark, due, keep, due
feed 1; rm -f "$SEEN"
run -- "prr_seen_mark $LANE $SLUG 7 $AU $M && prr_seen_due $LANE $SLUG 7 $A"
[ "$RC" = 1 ] && [ "$OUT" = quiet ] && ok || bad "RT mark then due: rc $RC '$OUT' ($(cat "$T/err"))"
[ "$(cat "$SEEN" 2>/dev/null)" = "7	$M	$A" ] && ok || bad "RT the row is not '7<TAB>$M<TAB><lower head>': $(cat "$SEEN" 2>/dev/null)"
run -- "prr_seen_mark $LANE $SLUG 9 $B $M && prr_seen_mark $LANE $SLUG 7 $B $((M + 1))"
[ "$(wc -l < "$SEEN")" = 2 ] && grep -qx "7	$((M + 1))	$B" "$SEEN" && grep -qx "9	$M	$B" "$SEEN" \
  && ok || bad "RT a second mark must replace the row, not add one: $(cat "$SEEN")"
run -- "prr_seen_keep $LANE $SLUG 9 12"
grep -q '^7	' "$SEEN" && bad "RT keep without 7 must drop its row: $(cat "$SEEN")" || ok
grep -q '^9	' "$SEEN" && ok || bad "RT keep with 9 must keep its row: $(cat "$SEEN")"
want RT2 0 no-state -- "$LANE" "$SLUG" 7 "$B"
run -- "prr_seen_keep $LANE $SLUG"
[ ! -s "$SEEN" ] && ok || bad "RT keep with no open PR must empty the file: $(cat "$SEEN")"

# L2 two lanes, one mark each
feed 1; scratch_rm "$H/state/prr-seen"
run -- "prr_seen_mark lane-a $SLUG 7 $A $M"
run -- 'prr_seen_due lane-b o/r 7 '"$A"
[ "$RC" = 0 ] && [ "$OUT" = no-state ] && ok || bad "L2 lane-a's mark quieted lane-b: rc $RC '$OUT'"
run -- 'prr_seen_due lane-a o/r 7 '"$A"
[ "$RC" = 1 ] && ok || bad "L2 lane-a's own mark must quiet lane-a: rc $RC '$OUT'"
[ -f "$H/state/prr-seen/lane-a/o_r.tsv" ] && [ ! -e "$H/state/prr-seen/lane-b/o_r.tsv" ] \
  && ok || bad "L2 marks must live per lane: $(find "$H/state/prr-seen" -type f | sort | tr '\n' ' ')"

# LK a held lock: rc 0, no write
seen "7	$M	$A"
exec {LFD}>"$SEEN.lock"; flock -n "$LFD" || bad "LK the test could not take the lock"
run -- "prr_seen_mark $LANE $SLUG 7 $B $((M + 5))"
[ "$RC" = 0 ] && ok || bad "LK a held lock must be rc 0, got $RC"
[ "$(cat "$SEEN")" = "7	$M	$A" ] && ok || bad "LK a held lock must leave the file: $(cat "$SEEN")"
run -- "prr_seen_keep $LANE $SLUG 8"
[ "$(cat "$SEEN")" = "7	$M	$A" ] && ok || bad "LK keep under a held lock must leave the file: $(cat "$SEEN")"
exec {LFD}>&-

# prr_seen_now is wb_due's clock
run -- 'prr_seen_now'
[ "$OUT" = "$NOWR" ] && ok || bad "prr_seen_now must be the WAKE_BACKSTOP_NOW clock in the sandbox: '$OUT'"

# KB the knob and the state class
K=$(jq -c '.libs[]? | select(.id=="prr-seen") | .knobs[] | select(.env=="PRR_SEEN_BACKSTOP_S") | [.type, .default, .min, .max]' "$T/lanes.json" 2>/dev/null)
[ "$K" = '["int",1800,0,86400]' ] && ok || bad "KB knob PRR_SEEN_BACKSTOP_S (lib prr-seen) int 1800 0..86400, got '$K'"
SP=$(jq -c '[.[] | select(.path=="prr-seen") | .class]' "$DIR/catalog/state-paths.d/9937-prr-seen.json" 2>/dev/null)
[ "$SP" = '["cache"]' ] && ok || bad "KB state path prr-seen must be class cache, got '$SP'"

echo "prr-seen.bh-9937: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
