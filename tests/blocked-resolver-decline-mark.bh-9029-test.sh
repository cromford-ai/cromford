#!/bin/bash
# tests/blocked-resolver-decline-mark.bh-9029-test.sh — BH-9029 fix 2: a
# `SUPERSEDE DECLINED (verdict)` writes a decline mark on the record, and while
# the same verdict row stands on the same head (and the ladder has not moved)
# the next tick skips the row before any rung, with one line per episode.
#
# THE BUG (hub, 2026-11-03). PR #8999: prequeue-red, fix rounds spent, rung
# rebuild-fresh, and every tick ended `SUPERSEDE DECLINED (verdict): a
# lead/human MERGE-WITH-NOTES verdict stands on 9819485e`. The same 330 s run
# repeated each tick, and nothing it read could change on its own.
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, on the
# fixture of tests/blocked-resolver-supersede.bh-1642-test.sh: the verdicts
# reader and the hold reader are stubs keyed on files, with the real contracts'
# rc shapes; the stub verdict carries a row id column so a NEW verdict on the
# same head is a different row.
#
# Run from anywhere: tests/blocked-resolver-decline-mark.bh-9029-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
# Every fragment rides with the driver copy, as bin/harness-sync.sh puts them on
# a box, and the profile module that writes the prof: line is installed too.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/br/opt/profile.sh "$H" >/dev/null || exit 1
[ -f "$DIR/bin/blocked-resolver.d/bh-9029-decline-mark.sh" ] \
  || bad "0: bin/blocked-resolver.d/bh-9029-decline-mark.sh must exist"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
# The ownership lib is the REAL one; verdicts.sh and hold.sh are stubs below
# (written after the closure install, so the stub is what the lane reads).
scratch_install_closure bin/lib/ticket-ownership.sh "$H" >/dev/null || exit 1
# STUB of bin/lib/verdicts.sh: $T/verdicts is "<full-sha> <VERDICT> [<row-id>]"
# per line (row id 7 when absent), $T/vd-down makes every read unreadable.
cat > "$H/bin/lib/verdicts.sh" <<EOF
vd_standing() {
  printf '%s %s %s\n' "\$1" "\$2" "\$3" >> "$T/vd-asked.txt"
  [ -e "$T/vd-down" ] && return 2
  [[ "\$3" =~ ^[0-9a-f]{40}\$ ]] || return 2
  local v id; read -r v id < <(awk -v h="\$3" '\$1==h {print \$2, \$3; exit}' "$T/verdicts" 2>/dev/null)
  [ -n "\$v" ] || return 1
  printf '%s\tlead\t%s\t2026-11-03T12:00:00Z\t-\toperator\n' "\$v" "\${id:-7}"
}
vd_clear_word() {
  local line v
  line=\$(vd_standing "\$@") || return 1
  v=\$(cut -f1 <<<"\$line")
  case "\$v" in MERGE|MERGE-WITH-NOTES) printf '%s' "\$v"; return 0 ;; esac
  return 1
}
EOF
cat > "$H/bin/lib/hold.sh" <<EOF
hold_check() {
  if [ -s "$T/hold" ]; then cat "$T/hold"; return "\$(cat "$T/hold-rc" 2>/dev/null || echo 1)"; fi
  printf 'clear\tno hold on this ticket\n'; return 0
}
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { case "\${1:-}" in *"	hold:"*)    return 0 ;; esac; return 1; }
hold_is_abandon() { case "\${1:-}" in *"	abandon:"*) return 0 ;; esac; return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj"
BASEENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
BRENV=("${BASEENV[@]}")

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the fix round pushed over
F=ffffffffffffffffffffffffffffffffffffffff   # the head this lane's fix round pushed
C=cccccccccccccccccccccccccccccccccccccccc   # a head pushed later
U9="https://github.com/o/tproj/pull/9"
LOGF="$H/logs/blocked-resolver.log"
RECF="$H/state/blocked-resolver/tproj/tproj-TK-9.json"
PREQ="prequeue-red: fast checks red on the PR head"

PARK() {  # PARK <STATE> <reason> <judged-head>
  printf 'o/tproj#9\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" "$3" "$3" "$2" "$U9" \
    > "$H/state/merge-conductor/pr-state.tsv"
}
HANDOFF() {  # HANDOFF <head> — an open (unreleased) hand-off for #9
  mkdir -p "$H/state/merge-conductor/handoff" "$H/state/merge-conductor/handoff-released"
  printf '%s\t%s\thead-not-reapproved\t%s\n' "$NOW" "$1" "$U9" > "$H/state/merge-conductor/handoff/o_tproj_9"
  rm -f "$H/state/merge-conductor/handoff-released/o_tproj_9"
}
RELEASED() { [ -e "$H/state/merge-conductor/handoff-released/o_tproj_9" ]; }
# FRESH: the #8999 shape. TK-9's ladder spent its mechanical and its fix round;
# the fix round pushed F over A two hours ago (past the settle window); the
# lead's MERGE-WITH-NOTES stands on F's predecessor A (the vd_clear_word arm).
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg u "$U9" --arg f "$F" --arg a "$A" --argjson t "$((NOW - 7200))" \
    '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:0,outcome:"",attempts:[],
      fix_pr:$u,fix_head:$f,fix_base:$a,fix_at:$t,sup_pr:$u,sup_head:$f,sup_at:$t,sup_settle:false}' > "$RECF"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$LOGF"
  : > "$T/vd-asked.txt"; rm -f "$T/vd-down" "$T/hold" "$T/hold-rc"
  : > "$T/lane-alert.txt"
  printf '%s MERGE-WITH-NOTES 41\n' "$A" > "$T/verdicts"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf '%s' "$F" > "$T/prhead"
  echo OPEN > "$T/prstate"
  PARK RED_TWICE "$PREQ" "$F"
  BRENV=("${BASEENV[@]}")
}
CLOSED() { grep -q -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null; }
NDECL() { grep -c "\]: SUPERSEDE DECLINED" "$LOGF" 2>/dev/null || true; }
NSKIP() { grep -c "SKIP decline-mark" "$LOGF" 2>/dev/null || true; }
MARK() { jq -r ".decl_mark.$1 // \"\"" "$RECF" 2>/dev/null; }
ALERTS() { grep -c 'SUPERSEDE DECLINED' "$T/lane-alert.txt" 2>/dev/null || true; }

# ============================================================================
# M1. TICK 1 DECLINES ON THE VERDICT AND WRITES THE MARK, with the verdict row.
# ============================================================================
FRESH
RUN
grep -q 'ladder rung: rebuild-fresh' "$LOGF" && ok || bad "M1: the park must reach rung rebuild-fresh (log: $(tail -5 "$LOGF"))"
[ "$(grep -c 'SUPERSEDE DECLINED (verdict)' "$LOGF")" = 1 ] && ok || bad "M1: one verdict decline (log: $(grep 'SUPERSEDE' "$LOGF"))"
[ "$(MARK vrow)" = 41 ] && ok || bad "M1: THE BUG: the decline must write decl_mark with the verdict row (record: $(jq -c .decl_mark "$RECF" 2>/dev/null))"
[ "$(MARK head)" = "$F" ] && [ "$(MARK vhead)" = "$A" ] && [ "$(MARK url)" = "$U9" ] && ok \
  || bad "M1: the mark binds the PR head, the verdict head and the url (mark: $(jq -c .decl_mark "$RECF"))"
[ "$(MARK vword)" = MERGE-WITH-NOTES ] && [ "$(MARK kind)" = verdict ] && ok || bad "M1: the mark keeps the verdict word and kind"
CLOSED && bad "M1: nothing is closed" || ok

# ============================================================================
# M2. TICK 2, SAME HEAD, SAME VERDICT ROW: one SKIP line, no decline line, no
#     rung, nothing closed or enqueued. The guard's two verdict reads are not
#     made; the skip reads the one verdict head once.
# ============================================================================
: > "$LOGF"; : > "$T/vd-asked.txt"
RUN
[ "$(NDECL)" = 0 ] && ok || bad "M2: THE BUG: a standing verdict decline must not be retried every tick (log: $(grep 'SUPERSEDE' "$LOGF"))"
[ "$(NSKIP)" = 1 ] && ok || bad "M2: ONE skip line (log: $(tail -4 "$LOGF"))"
grep -q "SKIP decline-mark — SUPERSEDE DECLINED (verdict) stands: verdict row 41 on ${A:0:12}, PR head ${F:0:12}" "$LOGF" && ok \
  || bad "M2: the skip line names the row and both heads (log: $(grep 'SKIP' "$LOGF"))"
grep -q 'ladder rung:' "$LOGF" && bad "M2: no rung runs on a skip (log: $(grep 'ladder rung' "$LOGF"))" || ok
CLOSED && bad "M2: nothing is closed" || ok
[ -s "$T/queue.txt" ] && bad "M2: nothing is enqueued (queue: $(cat "$T/queue.txt"))" || ok
[ "$(wc -l < "$T/vd-asked.txt")" = 1 ] && ok || bad "M2: the skip asks the verdict reader once (asked: $(cat "$T/vd-asked.txt"))"
[ "$(jq -r .rebuilds "$RECF")" = 0 ] && ok || bad "M2: no rebuild is counted"

# ============================================================================
# M3. TICK 3 is quiet: no second SKIP line in the episode.
# ============================================================================
RUN
[ "$(NSKIP)" = 1 ] && [ "$(NDECL)" = 0 ] && ok || bad "M3: one line per episode (skips $(NSKIP), declines $(NDECL))"

# ============================================================================
# M4. A NEW HEAD clears the mark and the guard runs again on it.
# ============================================================================
printf '%s' "$C" > "$T/prhead"
PARK RED_TWICE "$PREQ" "$C"
jq -c --arg c "$C" '.fix_head=$c' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"
: > "$LOGF"
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=0 BR_SUPERSEDE_DECLINE_ALERT_SECS=3600)
RUN
grep -q 'decline mark cleared: the PR head moved' "$LOGF" && ok || bad "M4: a new head clears the mark (log: $(tail -4 "$LOGF"))"
[ "$(NSKIP)" = 0 ] && ok || bad "M4: no skip on a new head"
[ "$(grep -c "SUPERSEDE DECLINED (verdict).*" "$LOGF")" = 1 ] && ok || bad "M4: the guard runs again and declines on the new head (log: $(grep SUPERSEDE "$LOGF"))"
[ "$(MARK head)" = "$C" ] && ok || bad "M4: the new decline marks the new head (mark: $(jq -c .decl_mark "$RECF"))"

# ============================================================================
# M5. A NEW VERDICT ROW on the same head clears the mark.
# ============================================================================
FRESH; RUN
printf '%s MERGE-WITH-NOTES 42\n' "$A" > "$T/verdicts"
: > "$LOGF"
RUN
grep -q 'decline mark cleared: verdict row 41 no longer stands' "$LOGF" && ok || bad "M5: a new verdict row clears the mark (log: $(tail -4 "$LOGF"))"
[ "$(MARK vrow)" = 42 ] && ok || bad "M5: the guard re-marks with the new row (mark: $(jq -c .decl_mark "$RECF"))"
# M5b. The verdict word changes on the same row id (supersede §4c's shape): cleared.
FRESH; RUN
printf '%s BLOCK 41\n' "$A" > "$T/verdicts"
: > "$LOGF"
RUN
grep -q 'decline mark cleared: verdict row 41 no longer stands' "$LOGF" && ok || bad "M5b: a changed verdict word clears the mark (log: $(tail -4 "$LOGF"))"
# M5c. No verdict stands any more: cleared.
FRESH; RUN
: > "$T/verdicts"; : > "$LOGF"
RUN
grep -q 'decline mark cleared: verdict row 41 no longer stands' "$LOGF" && ok || bad "M5c: no standing verdict clears the mark (log: $(tail -4 "$LOGF"))"
# M5d. A ladder counter moved: cleared.
FRESH; RUN
jq -c '.mechanicals=2' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"; : > "$LOGF"
RUN
grep -q 'decline mark cleared: the ladder moved' "$LOGF" && ok || bad "M5d: a ladder change clears the mark (log: $(tail -4 "$LOGF"))"
# M5e. The head is now in noop_heads (BH-4149): cleared.
FRESH; RUN
jq -c --arg f "$F" '.noop_heads=[$f]' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"; : > "$LOGF"
RUN
grep -q 'decline mark cleared: the head is frozen in noop_heads' "$LOGF" && ok || bad "M5e: a frozen head clears the mark (log: $(tail -4 "$LOGF"))"
# M5f. The reason changed: cleared.
FRESH; RUN
PARK BLOCKED_HUMAN "head-not-reapproved" "$F"; : > "$LOGF"
RUN
grep -q 'decline mark cleared: the reason changed' "$LOGF" && ok || bad "M5f: a new reason clears the mark (log: $(tail -4 "$LOGF"))"
# M5g. The mark is about another PR: not used, not cleared, the row runs.
FRESH; RUN
jq -c '.decl_mark.url="https://github.com/o/tproj/pull/10"' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"; : > "$LOGF"
RUN
[ "$(NSKIP)" = 0 ] && ok || bad "M5g: a mark for another PR does not skip this one"
grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" && ok || bad "M5g: the row runs as today (log: $(tail -3 "$LOGF"))"

# ============================================================================
# M6. THE VERDICT READ IS DOWN: the mark is kept and the row runs as today,
#     which fails closed (verdict-unreadable).
# ============================================================================
FRESH; RUN
touch "$T/vd-down"; : > "$LOGF"
RUN
[ "$(NSKIP)" = 0 ] && ok || bad "M6: an unreadable verdict is not a standing one: no skip"
grep -q 'SUPERSEDE DECLINED (verdict-unreadable)' "$LOGF" && ok || bad "M6: the row runs as today (log: $(tail -3 "$LOGF"))"
[ "$(MARK vrow)" = 41 ] && ok || bad "M6: the mark is kept through an outage"
grep -q 'decline mark cleared' "$LOGF" && bad "M6: an outage clears nothing" || ok

# ============================================================================
# M7. hold and settle-window declines write no mark: they change on their own
#     or must fail closed every tick.
# ============================================================================
FRESH
printf 'held\thold:body HOLD: the lead is on it\n' > "$T/hold"; echo 1 > "$T/hold-rc"
: > "$T/verdicts"
RUN
grep -qE 'SUPERSEDE DECLINED \(hold\)|HOLD respected' "$LOGF" && ok || bad "M7: the hold stops the rung (log: $(tail -3 "$LOGF"))"
[ -z "$(MARK vrow)" ] && ok || bad "M7: a hold decline writes no mark"
FRESH
jq -c --argjson t "$NOW" '.fix_at=$t' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"
RUN
grep -q 'SUPERSEDE DECLINED (settle-window)' "$LOGF" && ok || bad "M7: the window declines (log: $(tail -3 "$LOGF"))"
[ -z "$(MARK vrow)" ] && ok || bad "M7: a settle-window decline writes no mark"

# ============================================================================
# M8. THE PAGE STILL FIRES ON A SKIP TICK. Threshold 600 s: tick 1 is inside
#     it; the episode start is moved back an hour; the skip tick pages once;
#     later skip ticks do not page again.
# ============================================================================
FRESH
BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=600)
RUN
[ "$(ALERTS)" = 0 ] && ok || bad "M8: inside the threshold nothing pages"
jq -c '.decl_since = (.decl_since - 3600)' "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"
RUN
[ "$(NSKIP)" = 1 ] && ok || bad "M8: tick 2 is a skip (log: $(tail -3 "$LOGF"))"
[ "$(ALERTS)" = 1 ] && ok || bad "M8: the skip tick pages once past the threshold (alerts: $(cat "$T/lane-alert.txt"))"
RUN; RUN
[ "$(ALERTS)" = 1 ] && ok || bad "M8: exactly one page in the episode (alerts: $(ALERTS))"

# ============================================================================
# M9. A SKIP RELEASES THE CONDUCTOR'S PARK, exactly as the decline did.
# ============================================================================
FRESH
PARK BLOCKED_HUMAN "head-not-reapproved" "$F"
HANDOFF "$F"
RUN
RELEASED && ok || bad "M9: the verdict decline releases the park (tick 1)"
HANDOFF "$F"; : > "$LOGF"
RUN
[ "$(NSKIP)" = 1 ] && ok || bad "M9: tick 2 is a skip (log: $(tail -3 "$LOGF"))"
RELEASED && ok || bad "M9: the skip releases the re-made park"
grep -q 'blocked-resolver/decline-mark' "$H/state/merge-conductor/handoff-released/o_tproj_9" 2>/dev/null && ok \
  || bad "M9: the release names the decline mark (got: $(cat "$H/state/merge-conductor/handoff-released/o_tproj_9" 2>/dev/null))"

# ============================================================================
# M10. THE CURRENT-HEAD ARM marks too: a lead MERGE on the PR's own head.
# ============================================================================
FRESH
printf '%s MERGE 55\n' "$F" > "$T/verdicts"
RUN
[ "$(MARK vrow)" = 55 ] && [ "$(MARK vhead)" = "$F" ] && [ "$(MARK vword)" = MERGE ] && ok \
  || bad "M10: a verdict on the current head marks it (mark: $(jq -c .decl_mark "$RECF" 2>/dev/null))"
: > "$LOGF"
RUN
[ "$(NSKIP)" = 1 ] && [ "$(NDECL)" = 0 ] && ok || bad "M10: and the next tick skips (log: $(tail -3 "$LOGF"))"

echo "blocked-resolver-decline-mark.bh-9029: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
