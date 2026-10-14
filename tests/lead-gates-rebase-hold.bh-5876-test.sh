#!/bin/bash
# tests/lead-gates-rebase-hold.bh-5876-test.sh — BH-5876 (BH-5870.3): gate 10
# of the enqueue, the rebase hold (BH-5796), as the worklist gate
# bin/lib/lead-gates.d/85-rebase-hold.sh. Every case drives bin/lead-review.sh
# tick WHOLE over the worklist fixture (tests/lib/lead-worklist-fixture.bh-4956.sh,
# lead-gates-fixture.bh-5875.sh, lead-gates-fixture.bh-5876.sh).
#   R1  mergeable_state dirty: no job, no traced dispatch, and two ticks write
#       ONE `[skip rebase]` line.
#   R2  the conductor has THIS head NEEDS_REBASE: held. R2b the same row on
#       another head: a job.
#   R3  a real merge-tree conflict in the clone: held, naming the path.
#   R4  a clean real head: a job.
#   R5  LEAD_REVIEW_REBASE_HOLD=0 and DIRTY: gate 10 passes, gate 10a holds
#       the DIRTY head and dispatches once.
#   R6  a clean head that re-adds a file main added: a job whose meta carries
#       dup_note `possible duplicate of <sha12> (<path>)`.
#   R7  dup notes older than 14 days are deleted; newer ones stay.
#   M1  85-rebase-hold.sh removed: R1 starts a job (D1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-gates-rebase-hold.bh-5876-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5875.sh" || exit 1
. "$(dirname "$0")/lib/lead-gates-fixture.bh-5876.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
lwf_setup
lgf_setup
lg6_setup
GD="$H/bin/lib/lead-gates.d"
SRC="$LWF_SRC"
for f in bin/lib/lead-gates.d/85-rebase-hold.sh bin/lib/dup-main.sh; do
  [ -r "$SRC/$f" ] && [ -r "$H/$f" ] && ok || bad "setup: $f not installed"
done
H1=$(printf '%040d' 104); H12=${H1:0:12}
summ() { lwf_summary; }
CS="$H/state/merge-conductor/pr-state.tsv"
# conductor <state> <head> <reason> — the conductor's row for PR 104
conductor() { mkdir -p "${CS%/*}"; printf '%s\t%s\t-\t%s\t-\t-\t%s\n' "example-org/cromford#104" "$1" "$2" "$3" > "$CS"; }

# ── R1: DIRTY: held, no dispatch, one line over two ticks ──
lg6_reset; lgf_needs "104:$H1"; echo dirty > "$FX/ms.104"
lwf_tick; lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "R1 a job for a DIRTY head: $(cat "$L")"
[ "$(lg6_dispatches)" = 0 ] && ok || bad "R1 a traced dispatch for a DIRTY head"
[ "$(lg6_skips rebase)" = 1 ] && ok || bad "R1 rebase lines=$(lg6_skips rebase)"
grep -qF "[skip rebase] example-org/cromford#104 @$H12 not requested: NEEDS_REBASE: GitHub lists this head DIRTY against main" "$L" && ok || bad "R1 line: $(grep skip "$L")"
[[ "$(summ)" == *" held=1 "* ]] && ok || bad "R1 summary: $(summ)"

# ── R2: the conductor's word on this head; R2b on another head ──
lg6_reset; lgf_needs "104:$H1"; conductor NEEDS_REBASE "$H1" "behind main"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "R2 a job for a NEEDS_REBASE head"
grep -qF "NEEDS_REBASE: the conductor has this head NEEDS_REBASE (behind main)" "$L" && ok || bad "R2 line: $(grep skip "$L")"
lg6_reset; lgf_needs "104:$H1"; conductor NEEDS_REBASE "$(printf '%040d' 9)" "behind main"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "R2b no job when the row names another head"
lg6_reset; lgf_needs "104:$H1"; conductor BLOCKED_HUMAN "$H1" "conflict-unresolvable:bin/x.sh"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "R2c a job for a head parked conflict-unresolvable"

# ── R3: a real conflict, found by merge-tree on the clone ──
lg6_reset
HC=$(lg6_head 104 a.txt "pr side") || bad "R3 setup: head"
lg6_main a.txt "main side" >/dev/null || bad "R3 setup: main"
lgf_needs "104:$HC"
lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "R3 a job for a conflicting head: $(cat "$L")"
grep -qF "[skip rebase] example-org/cromford#104 @${HC:0:12} not requested: NEEDS_REBASE: conflicts with origin/main in a.txt" "$L" && ok || bad "R3 line: $(grep skip "$L")"
lg6_main_back

# ── R4: a clean real head: a job ──
lg6_reset
HK=$(lg6_head 104 r4/new.txt "clean") || bad "R4 setup: head"
lgf_needs "104:$HK"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "R4 no job for a clean head: $(cat "$L")"
[ "$(lg6_skips rebase)" = 0 ] && ok || bad "R4 a rebase line"
[ -z "$(lg6_meta 104 dup_note)" ] && ok || bad "R4 a dup_note on a clean head: $(lg6_meta 104 dup_note)"

# ── R5: the hold off, DIRTY: gate 10a takes the DIRTY head ──
lg6_reset; lgf_needs "104:$H1"; echo dirty > "$FX/ms.104"
LEAD_REVIEW_REBASE_HOLD=0 lwf_tick
[ "$(lgf_jobs 104)" = 0 ] && ok || bad "R5 a job for a DIRTY head with the rebase hold off"
[ "$(lg6_skips rebase)" = 0 ] && ok || bad "R5 a rebase line with the hold off"
[ "$(lg6_skips traced)" = 1 ] && ok || bad "R5 traced lines=$(lg6_skips traced): $(cat "$L")"
[ "$(lg6_dispatches)" = 1 ] && ok || bad "R5 dispatches=$(lg6_dispatches)"

# ── R6: a clean head that re-adds main's file: a job with dup_note ──
lg6_reset
DUP=$'line one of the shared file\nline two of the shared file\nline three of the shared file\nline four\nline five\nline six'
HD=$(lg6_head 104 dup/x.txt "$DUP") || bad "R6 setup: head"
MD=$(lg6_main dup/x.txt "$DUP") || bad "R6 setup: main"
lgf_needs "104:$HD"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "R6 a clean dup head held: $(cat "$L")"
[ "$(lg6_meta 104 dup_note)" = "possible duplicate of ${MD:0:12} (dup/x.txt)" ] && ok || bad "R6 dup_note='$(lg6_meta 104 dup_note)' main=${MD:0:12}"
lg6_main_back

# ── R7: dup notes older than 14 days are deleted once a tick; newer ones stay ──
lg6_reset; lgf_needs "104:$H1"
G="$H/state/lead-review-gates"; mkdir -p "$G"
echo old > "$G/dup-example-org_cromford-7-aaaaaaaaaaaa"; touch -d '2020-01-01 00:00:00' "$G/dup-example-org_cromford-7-aaaaaaaaaaaa"
echo new > "$G/dup-example-org_cromford-8-bbbbbbbbbbbb"
lwf_tick
[ -e "$G/dup-example-org_cromford-7-aaaaaaaaaaaa" ] && bad "R7 an old dup note kept" || ok
[ -e "$G/dup-example-org_cromford-8-bbbbbbbbbbbb" ] && ok || bad "R7 a new dup note deleted"

# ── M1: no rebase gate: the R1 head starts ──
mv "$GD/85-rebase-hold.sh" "$T/85.off"
lg6_reset; lgf_needs "104:$H1"; echo dirty > "$FX/ms.104"
lwf_tick
[ "$(lgf_jobs 104)" = 1 ] && ok || bad "M1 no job with 85-rebase-hold.sh gone: $(cat "$L")"
mv "$T/85.off" "$GD/85-rebase-hold.sh"

echo "lead-gates-rebase-hold.bh-5876: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
