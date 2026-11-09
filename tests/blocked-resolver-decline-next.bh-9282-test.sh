#!/bin/bash
# tests/blocked-resolver-decline-next.bh-9282-test.sh — BH-9282: a declined
# supersede on a red reviewed PR is not a dead end.
#
# THE BUG (project-6, 2026-11-08). PR #3661: a lead MERGE-WITH-NOTES verdict,
# CI red, fix=1/1 on an older head. The ladder reached rebuild-fresh, the
# supersede guard declined on the verdict, the BH-9029 decline mark was
# written, and from then on every tick ended `SKIP decline-mark`. Nothing that
# skip read could change on its own, so the PR waited for ever. #3608 was the
# same shape with a BLOCK verdict (row 5317).
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, on the BH-9029
# fixture (tests/blocked-resolver-decline-mark.bh-9029-test.sh): every
# fragment, the stub verdicts reader keyed on $T/verdicts, and the PR's CI from
# a gh wrapper that answers `actions/runs?head_sha=<sha>` from $T/runs-<sha>.
# N2 drives the owning box's `--fix-here` entry on a real local git, as
# bin/fix-round-claim.sh does, and reads the prompt the agent was given.
#
# Run from anywhere: tests/blocked-resolver-decline-next.bh-9282-test.sh (exit 0 = pass)
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
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1
scratch_install_closure bin/lib/br/opt/profile.sh "$H" >/dev/null || exit 1
[ -f "$DIR/bin/blocked-resolver.d/bh-9282-decline-next.sh" ] \
  || bad "0: bin/blocked-resolver.d/bh-9282-decline-next.sh must exist"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
scratch_install_closure bin/lib/ticket-ownership.sh "$H" >/dev/null || exit 1
# STUB of bin/lib/verdicts.sh, the BH-9029 suite's: $T/verdicts is
# "<full-sha> <VERDICT> [<row-id>]" per line.
cat > "$H/bin/lib/verdicts.sh" <<EOF
vd_standing() {
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
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
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

# THE CI READ. mc_ci_state asks `gh api -i -X GET repos/<slug>/actions/runs?head_sha=<sha>`
# through gh_rest. $T/runs-<sha> holds the workflow_runs body; $T/runs-fail
# answers 502 (an unreadable CI read). Every other call goes to the fixture's gh.
GHWRAP() {
  mv "$T/fakebin/gh" "$T/fakebin/gh-base" || return 1
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"actions/runs?head_sha="*)
    a="\$*"; s="\${a##*head_sha=}"; s="\${s%%&*}"; s="\${s%% *}"
    printf '%s\n' "\$s" >> "$T/ci-asked.txt"
    if [ -e "$T/runs-fail" ]; then printf 'HTTP/2 502\r\nserver: x\r\n\r\n{"message":"stub outage"}'; exit 0; fi
    if [ -s "$T/runs-\$s" ]; then b=\$(cat "$T/runs-\$s"); else b='{"workflow_runs":[]}'; fi
    printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "\$b"; exit 0 ;;
esac
exec "$T/fakebin/gh-base" "\$@"
EOF
  chmod +x "$T/fakebin/gh"
}
GHWRAP || exit 1
# CI <sha> red|green|pending — one workflow's latest run on that sha.
CI() {
  local c s
  case "$2" in red) s=completed; c=failure ;; green) s=completed; c=success ;; *) s=in_progress; c="" ;; esac
  jq -nc --arg h "$1" --arg s "$s" --arg c "$c" \
    '{workflow_runs:[{id:11,name:"harness-ci",head_sha:$h,status:$s,conclusion:(if $c=="" then null else $c end),run_attempt:1,run_started_at:"2026-11-08T10:00:00Z"}]}' \
    > "$T/runs-$1"
}

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the counted rungs ran on
F=ffffffffffffffffffffffffffffffffffffffff   # the PR head now, with the verdict on it
C=cccccccccccccccccccccccccccccccccccccccc   # a head pushed later
G=1111111111111111111111111111111111111111   # an unrelated head
U9="https://github.com/o/tproj/pull/9"
LOGF="$H/logs/blocked-resolver.log"
RECF="$H/state/blocked-resolver/tproj/tproj-TK-9.json"
PREQ="prequeue-red: fast checks red on the PR head"
FIXDETAIL="agent rc=0, verify rc=1: ended without a verified push"

PARK() {  # PARK <STATE> <reason> <judged-head>
  printf 'o/tproj#9\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" "$3" "$3" "$2" "$U9" \
    > "$H/state/merge-conductor/pr-state.tsv"
}
REC() { jq -r "$1" "$RECF" 2>/dev/null; }
EDIT() { jq -c "$@" "$RECF" > "$T/st.json" && cp "$T/st.json" "$RECF"; }
# FRESH <pr-head> <rung-head|-> — the #3661 shape. The ladder spent its
# mechanical and its one fix round; the counted rungs ran on <rung-head> ("-"
# = a legacy record with no rung_head); the lead's MERGE-WITH-NOTES row 41
# stands on the PR head; CI is red there; nothing was ever posted.
FRESH() {
  local ph="$1" rh="$2"
  scratch_rm "$H/state/blocked-resolver"
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg u "$U9" --arg ph "$ph" --arg rh "$rh" --arg d "$FIXDETAIL" --argjson t "$((NOW - 7200))" \
    '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:0,outcome:"",
      attempts:[{at:"2026-11-08 09:00:00Z",action:"mechanical",reason:"prequeue-red",detail:"merged main",url:$u},
                {at:"2026-11-08 09:30:00Z",action:"fix-round-failed",reason:"prequeue-red",detail:$d,url:$u}],
      sup_pr:$u,sup_head:$ph,sup_at:$t,sup_settle:false}
     + (if $rh == "-" then {} else {rung_pr:$u, rung_head:$rh} end)' > "$RECF"
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comment-bodies.txt"; : > "$T/comments.txt"
  : > "$LOGF"; : > "$T/lane-alert.txt"; : > "$T/ci-asked.txt"
  rm -f "$T/vd-down" "$T/runs-fail" "$T/st-comment" "$T"/runs-* "$H/flags/blocked-resolver-observe"
  scratch_rm "$H/state/blocked-resolver/tproj-marks"
  printf '%s MERGE-WITH-NOTES 41\n' "$ph" > "$T/verdicts"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"
  printf '%s' "$ph" > "$T/prhead"
  echo OPEN > "$T/prstate"
  CI "$ph" red
  PARK RED_TWICE "$PREQ" "$ph"
  BRENV=(BR_REGEN_RUNG=0 BR_SUPERSEDE_SETTLE_SECS=1800 BR_SUPERSEDE_DECLINE_ALERT_SECS=86400)
}
# TICK1: the decline tick. The ladder reaches rebuild-fresh, the guard declines
# on the verdict and the BH-9029 mark is written. The log is then cleared, so
# every assertion below is about the tick after it.
TICK1() {
  RUN
  grep -q 'SUPERSEDE DECLINED (verdict)' "$LOGF" || bad "$1: setup: tick 1 must decline on the verdict (log: $(tail -4 "$LOGF"))"
  [ -n "$(REC '.decl_mark.vrow // ""')" ] || bad "$1: setup: tick 1 must write the decline mark (record: $(REC -c .decl_mark))"
  : > "$LOGF"; : > "$T/comment-bodies.txt"; : > "$T/comments.txt"; : > "$T/lane-alert.txt"
}
CLOSED() { grep -q -- "-X PATCH.*pulls/9" "$T/closed.txt" 2>/dev/null; }
NSKIP()  { grep -c "SKIP decline-mark" "$LOGF" 2>/dev/null || true; }
NNEXT()  { grep -c "DECLINE NEXT — SUPERSEDE DECLINED" "$LOGF" 2>/dev/null || true; }
NPOST()  { grep -c "push a fix, merge it, or close it" "$T/comment-bodies.txt" 2>/dev/null || true; }
NOREC()  { grep -c 'NEEDS_HUMAN' "$T/lane-alert.txt" 2>/dev/null || true; }

# ============================================================================
# N1. THE #3661 REPLAY: MERGE-WITH-NOTES row 41 on F, CI red on F, fix 1/1
#     with the counted rungs on A. The tick after the decline resets the
#     per-head budget and dispatches a fix round; no SKIP line.
# ============================================================================
FRESH "$F" "$A"
TICK1 N1
RUN
[ "$(NSKIP)" = 0 ] && ok || bad "N1: THE BUG: a red reviewed head must not end SKIP decline-mark (log: $(tail -5 "$LOGF"))"
grep -q "DECLINE NEXT — SUPERSEDE DECLINED (verdict) stands (MERGE-WITH-NOTES row 41 on ${F:0:12}) and CI is red there: fix round 1 of 1 on this head" "$LOGF" && ok \
  || bad "N1: the decision line names the verdict, the head and the round (log: $(grep -E 'DECLINE|HEAD RESET' "$LOGF"))"
grep -q -- "-> fix-round " "$LOGF" && ok || bad "N1: a fix round is dispatched (log: $(grep -- '->' "$LOGF"))"
LN=$(grep -n 'DECLINE NEXT' "$LOGF" | head -1 | cut -d: -f1); LD=$(grep -n -- '-> fix-round ' "$LOGF" | head -1 | cut -d: -f1)
[ -n "$LN" ] && [ -n "$LD" ] && [ "$LN" -lt "$LD" ] && ok || bad "N1: the decision line comes before the dispatch line ($LN, $LD)"
grep -q 'HEAD RESET' "$LOGF" && ok || bad "N1: the per-head reset is logged (log: $(tail -5 "$LOGF"))"
[ "$(REC '.head_resets // 0')" = 1 ] && ok || bad "N1: head_resets=1 (record: $(REC -c '{head_resets,fixrounds,mechanicals,ladder_reset}'))"
[ "$(REC '.ladder_reset.to // ""')" = "$F" ] && ok || bad "N1: ladder_reset.to is the PR head"
[ "$(REC '.decl_mark.vrow // ""')" = 41 ] && ok || bad "N1: the decline mark stays as the record (record: $(REC -c .decl_mark))"
[ "$(REC '.decline_next.head // ""')" = "$F" ] && [ "$(REC '.decline_next.url // ""')" = "$U9" ] && ok \
  || bad "N1: .decline_next names the url and the head (record: $(REC -c .decline_next))"
[ "$(REC '.decline_next.offered_at // ""')" != "" ] && ok || bad "N1: the offer is stamped"
CLOSED && bad "N1: nothing is closed" || ok
[ "$(NPOST)" = 0 ] && ok || bad "N1: no needs-human comment while a round is available"

# N1b. A ci-red reason (red-twice). After the reset the ladder's own answer is
#      rung 1 (mechanical: merge main, re-run CI); the admitted row runs the
#      fix round instead, as the decision line said.
FRESH "$F" "$A"
PARK RED_TWICE "red-twice: CI red again on the same head after one rerun" "$F"
TICK1 N1b
RUN
grep -q 'ladder rung: mechanical' "$LOGF" && ok || bad "N1b: setup: the reset ladder answers rung 1 (log: $(grep 'ladder rung' "$LOGF"))"
grep -q -- "-> fix-round " "$LOGF" && ok || bad "N1b: the admitted row runs the fix round, not rung 1 (log: $(grep -- '->' "$LOGF"))"
grep -q -- "-> mechanical" "$LOGF" && bad "N1b: no mechanical rung" || ok

# ============================================================================
# N3. A NEW HEAD C (verdict rebound to C), the counted rungs on A: reset and a
#     round. N3b: the rungs on the SAME head: no round, no reset. N3c: a legacy
#     record with no rung_head: not read as a new head. N3d: the ladder was
#     already reset to F once: no second reset. N3e: F is the head this lane's
#     own fix round pushed: no fresh budget (that would buy a round per push).
# ============================================================================
FRESH "$C" "$A"
TICK1 N3
RUN
[ "$(REC '.head_resets // 0')" = 1 ] && [ "$(REC '.ladder_reset.to // ""')" = "$C" ] && ok \
  || bad "N3: a new head resets the budget (record: $(REC -c '{head_resets,ladder_reset}'))"
grep -q -- "-> fix-round " "$LOGF" && ok || bad "N3: a fix round is offered on the new head (log: $(tail -4 "$LOGF"))"
[ "$(REC '.attempts | map(select(.action=="head-reset")) | length')" = 1 ] && ok || bad "N3: one head-reset attempt"

for case_ in N3b N3c N3d N3e; do
  case "$case_" in
    N3b) FRESH "$F" "$F" ;;
    N3c) FRESH "$F" - ;;
    N3d) FRESH "$F" "$A"; EDIT --arg u "$U9" --arg a "$A" --arg f "$F" '.ladder_reset={url:$u,from:$a,to:$f,at:"x",base:{fixround:1}}' ;;
    N3e) FRESH "$F" "$A"; EDIT --arg u "$U9" --arg a "$A" --arg f "$F" '.fix_pr=$u | .fix_head=$f | .fix_base=$a' ;;
  esac
  TICK1 "$case_"
  HR0=$(REC '.head_resets // 0')
  RUN
  [ "$(REC '.head_resets // 0')" = "$HR0" ] && ok || bad "$case_: no reset (head_resets $HR0 -> $(REC '.head_resets // 0'); log: $(grep 'HEAD RESET' "$LOGF"))"
  [ "$(NNEXT)" = 0 ] && ok || bad "$case_: no round offered (log: $(grep 'DECLINE NEXT' "$LOGF"))"
  grep -q -- "-> fix-round " "$LOGF" && bad "$case_: no fix round dispatched" || ok
  [ "$(REC '.fixrounds')" = 1 ] && ok || bad "$case_: the spent budget stands (fixrounds=$(REC .fixrounds))"
  [ "$(REC '.decline_next.head // ""')" = "$F" ] && ok || bad "$case_: the human clock starts on the head (record: $(REC -c .decline_next))"
  grep -q "needs-human comment waits" "$LOGF" && ok || bad "$case_: one line says the human comment waits (log: $(tail -3 "$LOGF"))"
  [ "$(NPOST)" = 0 ] && ok || bad "$case_: no comment before the window"
  CLOSED && bad "$case_: nothing is closed" || ok
done

# ============================================================================
# N4. THE BUDGET IS SPENT ON F AND CI IS STILL RED 13 h later (knob 12):
#     exactly one needs-human comment, on the ticket's issue. N4b: the next
#     tick posts nothing. N4c: 11 h -> nothing. N4d: the post fails -> one lane
#     alert, no "told" line, and the next tick posts nothing. N4e: a new head
#     starts a new clock.
# ============================================================================
SINCE() { EDIT --arg u "$U9" --arg h "$1" --argjson s "$2" '.decline_next={url:$u,head:$h,since:$s,vrow:"41",vword:"MERGE-WITH-NOTES"}'; }
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 13*3600))"
TICK1 N4
RUN
[ "$(NPOST)" = 1 ] && ok || bad "N4: exactly one needs-human comment (bodies: $(cat "$T/comment-bodies.txt"); log: $(tail -4 "$LOGF"))"
grep -q "issues/9/comments" "$T/comments.txt" && ok || bad "N4: the comment goes on the ticket's issue #9 (posts: $(cat "$T/comments.txt"))"
B=$(cat "$T/comment-bodies.txt")
case "$B" in *"$U9"*) ok ;; *) bad "N4: the body names the PR ($B)" ;; esac
case "$B" in *MERGE-WITH-NOTES*) ok ;; *) bad "N4: the body names the verdict word" ;; esac
case "$B" in *"row 41"*) ok ;; *) bad "N4: the body names the verdict row" ;; esac
case "$B" in *"${F:0:12}"*) ok ;; *) bad "N4: the body names the head" ;; esac
case "$B" in *"fix-round-failed"*"$FIXDETAIL"*) ok ;; *) bad "N4: the body names the last fix round and its result ($B)" ;; esac
case "$B" in *"push a fix, merge it, or close it"*) ok ;; *) bad "N4: the body says what a person can do" ;; esac
grep -q "told o/tproj#9" "$LOGF" && ok || bad "N4: one told line (log: $(tail -3 "$LOGF"))"
[ "$(REC '.decline_next.human_head // ""')" = "$F" ] && ok || bad "N4: the post is recorded per head"
ls "$H/state/blocked-resolver/tproj/tproj-TK-9.decline-human-${F:0:12}" >/dev/null 2>&1 && ok || bad "N4: the comment marker file is written"
CLOSED && bad "N4: nothing is closed" || ok
# N4b
RUN; RUN
[ "$(NPOST)" = 1 ] && ok || bad "N4b: once per head, not every tick ($(NPOST) bodies)"
# N4b2: the record lost its human_head (a hub rebuilt from the row), the marker still holds.
EDIT 'del(.decline_next.human_head)'
RUN
[ "$(NPOST)" = 1 ] && ok || bad "N4b: the comment marker alone holds the once-per-head rule ($(NPOST) bodies)"
# N4c
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 11*3600))"
TICK1 N4c
RUN
[ "$(NPOST)" = 0 ] && ok || bad "N4c: 11 h of a 12 h window posts nothing"
grep -q "needs-human comment waits 1h more" "$LOGF" && ok || bad "N4c: the wait line names the hours left (log: $(tail -3 "$LOGF"))"
# N4d
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 13*3600))"
TICK1 N4d
echo 500 > "$T/st-comment"
RUN
grep -q "told o/tproj#9" "$LOGF" && bad "N4d: a failed post is never a told line" || ok
grep -q "$U9" "$T/lane-alert.txt" && grep -q 'HTTP 500' "$T/lane-alert.txt" && ok \
  || bad "N4d: one lane alert names the PR and the HTTP status (alerts: $(cat "$T/lane-alert.txt"))"
[ "$(grep -c "$U9" "$T/lane-alert.txt")" = 1 ] && ok || bad "N4d: exactly one alert"
: > "$T/comments.txt"; rm -f "$T/st-comment"
RUN
[ -s "$T/comments.txt" ] && bad "N4d: the marker stays, so the next tick posts nothing (posts: $(cat "$T/comments.txt"))" || ok
# N4e: the head moves to C (the mark is cleared, then the guard re-declines on C).
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 13*3600))"
EDIT --arg c "$C" '.rung_head=$c'
printf '%s' "$C" > "$T/prhead"; printf '%s MERGE-WITH-NOTES 41\n' "$C" > "$T/verdicts"; CI "$C" red
PARK RED_TWICE "$PREQ" "$C"; EDIT --arg c "$C" '.sup_head=$c'
TICK1 N4e
RUN
[ "$(REC '.decline_next.head // ""')" = "$C" ] && ok || bad "N4e: the clock moves to the new head (record: $(REC -c .decline_next))"
[ "$(REC '.decline_next.since // 0')" -gt "$((NOW - 600))" ] && ok || bad "N4e: a new head starts a new clock (since=$(REC '.decline_next.since'))"
[ "$(NPOST)" = 0 ] && ok || bad "N4e: a new head posts nothing at once"

# ============================================================================
# N5. GREEN CI (and, separately, PENDING) on the declined head: not touched.
#     One SKIP line, no decision, no counter, no comment.
# ============================================================================
for ci_ in green pending; do
  FRESH "$F" "$A"; SINCE "$F" "$((NOW - 13*3600))"
  CI "$F" "$ci_"
  TICK1 "N5-$ci_"
  BEFORE=$(REC -c '{mechanicals,fixrounds,head_resets,rebuilds}')
  RUN
  [ "$(NSKIP)" = 1 ] && ok || bad "N5-$ci_: the old skip, one line (log: $(tail -3 "$LOGF"))"
  [ "$(NNEXT)" = 0 ] && ok || bad "N5-$ci_: no decision on a $ci_ head"
  [ "$(REC -c '{mechanicals,fixrounds,head_resets,rebuilds}')" = "$BEFORE" ] && ok || bad "N5-$ci_: counters unchanged"
  [ "$(NPOST)" = 0 ] && [ "$(NOREC)" = 0 ] && ok || bad "N5-$ci_: no comment, no alert"
  grep -q -- "-> " "$LOGF" && bad "N5-$ci_: no rung (log: $(grep -- '->' "$LOGF"))" || ok
  CLOSED && bad "N5-$ci_: nothing is closed" || ok
done

# ============================================================================
# N6. A KNOB THAT IS NOT A NUMBER: one line, and the fallback 12 h applies.
# ============================================================================
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 13*3600))"
TICK1 N6
BRENV+=(BR_DECLINE_HUMAN_HOURS=abc)
RUN
[ "$(grep -c "BR_DECLINE_HUMAN_HOURS is 'abc', not a number — the fallback 12 is used" "$LOGF")" = 1 ] && ok \
  || bad "N6: one fallback line (log: $(tail -3 "$LOGF"))"
[ "$(NPOST)" = 1 ] && ok || bad "N6: the 12 h fallback posts at 13 h"
# N6b: the knob is read: 24 h holds the same 13 h-old clock.
FRESH "$F" "$F"; SINCE "$F" "$((NOW - 13*3600))"
TICK1 N6b
BRENV+=(BR_DECLINE_HUMAN_HOURS=24)
RUN
[ "$(NPOST)" = 0 ] && ok || bad "N6b: a 24 h knob holds a 13 h clock"
grep -q "waits 11h more" "$LOGF" && ok || bad "N6b: the wait line reads the knob (log: $(tail -2 "$LOGF"))"

# ============================================================================
# N7. OBSERVE MODE: a WOULD line, the record byte for byte unchanged.
# ============================================================================
FRESH "$F" "$A"
TICK1 N7
touch "$H/flags/blocked-resolver-observe"
cp "$RECF" "$T/rec-before.json"
RUN
grep -q "DECLINE NEXT — WOULD" "$LOGF" && ok || bad "N7: a WOULD line (log: $(tail -3 "$LOGF"))"
cmp -s "$RECF" "$T/rec-before.json" && ok || bad "N7: observe mode writes nothing (diff: $(diff "$RECF" "$T/rec-before.json"))"
grep -q -- "-> fix-round " "$LOGF" && bad "N7: observe mode dispatches nothing" || ok
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# N8. THE CI READ FAILS: unreadable is not red. The old skip, nothing else.
# ============================================================================
FRESH "$F" "$A"
TICK1 N8
touch "$T/runs-fail"
RUN
[ "$(NSKIP)" = 1 ] && [ "$(NNEXT)" = 0 ] && ok || bad "N8: an unreadable CI read keeps the old skip (log: $(tail -3 "$LOGF"))"
[ "$(REC '.head_resets // 0')" = 0 ] && ok || bad "N8: no reset"
# N8b: a head with no runs at all (`none`) is not red either.
FRESH "$F" "$A"
TICK1 N8b
rm -f "$T/runs-$F"
RUN
[ "$(NSKIP)" = 1 ] && [ "$(NNEXT)" = 0 ] && ok || bad "N8b: no runs is not red"

# ============================================================================
# N9. A REASON WHOSE ACTION IS NOT THE LADDER (merge-failed-twice goes straight
#     to rebuild-fresh): the old skip.
# ============================================================================
FRESH "$F" "$A"
PARK BLOCKED_HUMAN "merge-failed-twice: the merge API refused twice" "$F"
TICK1 N9
RUN
[ "$(NSKIP)" = 1 ] && [ "$(NNEXT)" = 0 ] && ok || bad "N9: a non-ladder reason keeps the old skip (log: $(tail -3 "$LOGF"))"
[ "$(REC '.head_resets // 0')" = 0 ] && ok || bad "N9: no reset"

# ============================================================================
# N2. THE #3608 REPLAY: a BLOCK verdict row 5317. Tick 1 declines, tick 2
#     offers the round and writes .decline_next; the owning box runs the round
#     (--fix-here, on the record copy the hub hands over) and the agent's brief
#     carries the lead's review findings for that head. N2b: the reviews read
#     fails -> no rung spent, the "could not be read" line.
# ============================================================================
fx_br_ladder_git "$DIR" "$T" || exit 1
GHWRAP || exit 1
mkbranch ticket/TK-9 clean
git -C "$T/repos/tproj" fetch -q origin 2>/dev/null
HB=$(osha ticket/TK-9)
FRESH "$HB" "$A"
printf '%s BLOCK 5317\n' "$HB" > "$T/verdicts"
FINDING='- [BLOCK wrong-data] bin/x.sh: fixture finding'
jq -nc --arg c "$HB" --arg b "$(printf '<!-- lead-review:77 -->\nLead review: BLOCK\n\n%s\n' "$FINDING")" \
  '[{user:{login:"cromford[bot]",type:"Bot"},author_association:"NONE",commit_id:$c,state:"COMMENTED",body:$b,id:5}]' \
  > "$T/prreviews.json"
# The hub queues the round for the owning box (BH-2674) and runs no agent work
# itself: the hub identity lib, with this box named as the hub.
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1
TICK1 N2
BRENV+=(HUB_BOX_NAME=hubx BOX_NAME=hubx)
RUN
grep -q -- "-> fix-round " "$LOGF" && ok || bad "N2: the hub tick dispatches the fix round (log: $(tail -4 "$LOGF"))"
CLOSED && bad "N2: nothing is closed on the hub tick" || ok
grep -q "DECLINE NEXT — SUPERSEDE DECLINED (verdict) stands (BLOCK row 5317 on ${HB:0:12})" "$LOGF" && ok \
  || bad "N2: tick 2 offers the round on the BLOCK head (log: $(grep -E 'DECLINE|SKIP|->' "$LOGF"))"
[ "$(REC '.decline_next.vword // ""')" = BLOCK ] && [ "$(REC '.decline_next.vrow // ""')" = 5317 ] && ok \
  || bad "N2: .decline_next carries the verdict word and row (record: $(REC -c .decline_next))"
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$H/bin/blocked-resolver.sh" --fix-here tproj tproj-TK-9 "$PREQ" "$U9" - TK-9 < "$T/rec-in.json" ) 2>>"$T/run.log"; }
# The record copy the hub hands the box: this record, with the round not yet spent.
EDIT '.fixrounds=0 | .mechanicals=0'
cp "$RECF" "$T/rec-in.json"; cp "$RECF" "$T/rec-n2.json"
: > "$T/prompt.txt"; : > "$LOGF"; : > "$T/closed.txt"
FIXHERE > "$T/fh.out"
P=$(cat "$T/prompt.txt")
case "$P" in *"LEAD FINDINGS — every item must be addressed in code"*) ok ;; *) bad "N2: THE BUG: the brief must carry the lead header (prompt: ${P:0:400}; log: $(tail -6 "$LOGF"))" ;; esac
case "$P" in *"BLOCK verdict row 5317 on ${HB:0:12}"*) ok ;; *) bad "N2: the brief names the verdict row and head" ;; esac
case "$P" in *"$FINDING"*) ok ;; *) bad "N2: the brief carries the finding line" ;; esac
# N2-neg: a MERGE-WITH-NOTES .decline_next gets no lead block from a COMMENTED review.
jq -c '.decline_next.vword="MERGE-WITH-NOTES"' "$T/rec-in.json" > "$T/rec-mwn.json" && cp "$T/rec-mwn.json" "$T/rec-in.json"
: > "$T/prompt.txt"; : > "$T/closed.txt"
FIXHERE > /dev/null
[ -s "$T/prompt.txt" ] && ok || bad "N2: the MERGE-WITH-NOTES round reaches the agent (log: $(tail -3 "$LOGF"))"
case "$(cat "$T/prompt.txt")" in *"verdict row 5317"*) bad "N2: a MERGE-WITH-NOTES head is not briefed as a BLOCK" ;; *) ok ;; esac
# N2b
cp "$T/rec-n2.json" "$T/rec-in.json"
touch "$T/reviews-fail"; : > "$T/prompt.txt"; : > "$LOGF"; : > "$T/closed.txt"
FIXHERE > "$T/fh.out"
rm -f "$T/reviews-fail"
grep -q "the posted findings could not be read this tick" "$LOGF" && ok || bad "N2b: a failed reviews read says so (log: $(tail -4 "$LOGF"))"
[ -s "$T/prompt.txt" ] && bad "N2b: no agent call on an unread brief" || ok
REC2B=$(grep '^FIX_RECORD ' "$T/fh.out" | head -1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
[ "$(jq -r '.fixrounds // 0' <<<"${REC2B:-{\}}" 2>/dev/null)" = 0 ] && ok || bad "N2b: no fixround spent (record: $(jq -c '{fixrounds}' <<<"${REC2B:-{\}}" 2>/dev/null))"

echo "blocked-resolver-decline-next.bh-9282: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
