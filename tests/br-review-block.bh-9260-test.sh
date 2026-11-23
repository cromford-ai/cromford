#!/bin/bash
# tests/br-review-block.bh-9260-test.sh — BH-9260: bin/blocked-resolver.sh takes
# the conductor's `review-block` park (a machine review BLOCK on a READY head).
#
#   R1   the why round-trips: written by mc_rbp_park, read back by
#        br_reason_of (head-not-reapproved), br_ladder_class (review-blocked),
#        br_skips_mechanical, mc_resolver_owns, mc_handoff_owns and
#        br_handoff_lines (the hand-off log line the park writes)
#   R2   a WHOLE resolver tick over pr-state.tsv: one candidate,
#        head-not-reapproved, at the fix round; R2b the row back at READY
#        (UNBLOCK) -> no candidate, and the hand-off is not recovered
#   R3   br_findings: the BLOCK comment, by id, is the fix round's brief; an
#        untrusted author (a person, a non-verdict-author bot, a marker for
#        another head or none) falls back to the head-bound comment; a 500 is rc 75
#
# GitHub is a stub (fixture-harness) or a gh_rest function over files; nothing
# reads the network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/br-review-block.bh-9260-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc/review-block-park.sh" ] || { echo "FAIL: bin/lib/mc/review-block-park.sh is missing (BH-9260)"; exit 1; }

HEADX=abc123abc123abc123abc123abc123abc123abc1
URL530="https://github.com/o/tproj/pull/530"
BURL="https://github.com/o/tproj/pull/530#issuecomment-9001"
WHY="review-block: 9001 [BLOCK core-flow-broken] $BURL"
AP_BODY="<!-- harness-review-autopilot ${HEADX:0:12} -->
- [BLOCK core-flow-broken] the sign-in form posts to a route the CSP blocks

VERDICT: BLOCK"

# ============================================================================
# R1 — the round trip, through the real libs
# ============================================================================
echo "R1: the why round-trips through every reader"
U="$T/u"; mkdir -p "$U/h/state" "$U/h/logs"
r1=$( export HARNESS="$U/h" HARNESS_VERDICT_AUTHORS=app/cromford HARNESS_OPERATOR_LOGIN=operator
  # The conductor and the resolver both load the verdict-trust set; the park
  # trusts only a verdict author's head-bound comment (mc_rbp_trusted).
  . "$DIR/bin/lib/gh-pr-list.sh" >/dev/null 2>&1 || exit 9
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 9
  . "$DIR/bin/lib/br/ladder.sh" || exit 9
  mc_init >/dev/null 2>&1
  bg_scan_read() { :; }
  mc_rbp_read() { printf '%s\t%s\n%s' 'cromford[bot]' "$BURL" "$AP_BODY"; }
  mc_transition "o/tproj#530" READY "clean approved checks green" "$HEADX" "$HEADX" "$URL530" APPROVE CLEAN - >/dev/null
  mc_rbp_park "o/tproj#530" o/tproj 530 "$URL530" - "$HEADX" "$HEADX" CLEAN "$(printf '%s\t%s\t%s\t%s' "$BURL" 'cromford[bot]' 2026-11-08T00:42:58Z 9001)" 2 || exit 8
  why=$(mc_row_field "o/tproj#530" 7)
  r=$(br_reason_of "$why")
  printf 'why=%s\nreason=%s\nclass=%s\n' "$why" "$r" "$(br_ladder_class "$r")"
  br_skips_mechanical "$(br_ladder_class "$r")" && echo skips=0 || echo skips=1
  mc_resolver_owns "$why" && echo owns=0 || echo owns=1
  mc_handoff_owns "$why" && echo handoff=0 || echo handoff=1
  echo "display=$(mc_state_display BLOCKED_HUMAN "$why")"
  # br_handoff_lines' own sed over the line the park logged (the function reads
  # $H/logs/merge-conductor.log; the expression is lifted, not retyped).
  sed -nE 's#^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8})Z ([^ ]+) (BLOCKED_AGENT|RED_TWICE) ([^ :]+).*(https://github\.com/[^ ]+)$#\2\t\4\t\5#p' "$MC_LOG" \
    | sed 's/^/hl=/'
); r1rc=$?
[ "$r1rc" = 0 ] && ok || bad "R1 the park did not run (rc $r1rc): $r1"
grep -qxF "why=$WHY" <<<"$r1" && ok || bad "R1 the written why: $r1"
grep -qx "reason=head-not-reapproved" <<<"$r1" && ok || bad "R1 br_reason_of -> head-not-reapproved: $r1"
grep -qx "class=review-blocked" <<<"$r1" && ok || bad "R1 br_ladder_class -> review-blocked: $r1"
grep -qx "skips=0" <<<"$r1" && ok || bad "R1 br_skips_mechanical: the fix round is rung 1: $r1"
grep -qx "owns=0" <<<"$r1" && grep -qx "handoff=0" <<<"$r1" && ok || bad "R1 resolver-owned hand-off: $r1"
grep -qx "display=BLOCKED_AGENT" <<<"$r1" && ok || bad "R1 displays BLOCKED_AGENT: $r1"
grep -qxF "hl=o/tproj#530	review-block	$URL530" <<<"$r1" && ok || bad "R1 br_handoff_lines parses the park's log line: $(grep '^hl=' <<<"$r1")"
# br_handoff_lines' expression is the one in the lane, character for character.
grep -qF "sed -nE 's#^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8})Z ([^ ]+) (BLOCKED_AGENT|RED_TWICE) ([^ :]+).*(https://github\\.com/[^ ]+)\$#\\1\\t\\2\\t\\4\\t\\5#p'" "$DIR/bin/blocked-resolver.sh" \
  && ok || bad "R1 the lifted br_handoff_lines expression no longer matches bin/blocked-resolver.sh"

# ============================================================================
# R2 — a whole resolver tick
# ============================================================================
echo "R2: br_from_conductor offers the park, once"
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/bin/blocked-resolver.d" && cp "$DIR/bin/blocked-resolver.d/bh-9260-review-block-skip.sh" "$H/bin/blocked-resolver.d/" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
LOGF="$H/logs/blocked-resolver.log"
MCS="$H/state/merge-conductor"
NOWS=1794150000
FRESH() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$MCS/handoff"
  : > "$LOGF"; : > "$T/lane-alert.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"
  : > "$H/logs/merge-conductor.log"
}
ROW1() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#530" "$1" "$NOWS" "$HEADX" "$HEADX" "$2" "$URL530" > "$MCS/pr-state.tsv"; }
FRESH
ROW1 BLOCKED_HUMAN "$WHY"
touch "$H/flags/blocked-resolver-observe"
RUN
grep -q 'tick: candidates=1 ' "$LOGF" && ok || bad "R2 exactly one candidate (log: $(grep 'tick:' "$LOGF" | tail -1))"
grep -q 'head-not-reapproved/review-blocked' "$LOGF" && ok || bad "R2 the candidate's reason and ladder class (log: $(tail -5 "$LOGF"))"
grep -q 'unmapped-reason' "$LOGF" && bad "R2 a review-block park is not unmapped: $(grep unmapped "$LOGF")" || ok

echo "R2b: the row back at READY (UNBLOCK) -> no candidate"
FRESH
ROW1 READY "clean approved checks green"
# The hand-off record and its log line outlive the park; neither may revive it.
mkdir -p "$MCS/handoff"
printf '%s\t%s\t%s\t%s\n' "$NOWS" "$HEADX" "$WHY" "$URL530" > "$MCS/handoff/o_tproj_530"
printf '%s o/tproj#530 BLOCKED_AGENT %s — machine review BLOCK on %s, handed to bin/blocked-resolver.sh (agent fix round against that finding): %s\n' \
  "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$WHY" "${HEADX:0:8}" "$URL530" > "$H/logs/merge-conductor.log"  # determinism: ok — br_handoff_lines keeps only lines from the last 48 h of the real clock
printf '%s' "$HEADX" > "$T/prhead"
RUN
grep -q 'candidates=[1-9]\|head-not-reapproved\|review-block' "$LOGF" && bad "R2b no candidate once the park is released (log: $(tail -5 "$LOGF"))" || ok
grep -q 'recovered from the hand-off' "$LOGF" && bad "R2b a released review-block park must not be recovered from the hand-off: $(grep recovered "$LOGF")" || ok
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# R3 — br_findings reads the parked BLOCK as the brief
# ============================================================================
echo "R3: br_findings"
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
extract() { local f="$1"; shift; for fn in "$@"; do awk -v F="^$fn\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$f"; done; }
extract "$T/br-corpus.sh" br_findings br_findings_join br_slug_of_url > "$T/bf.sh"
[ "$(grep -c '^br_.*() {' "$T/bf.sh")" = 3 ] && ok || bad "R3 could not extract br_findings"
G="$T/r3"; mkdir -p "$G/gh" "$G/h/state" "$G/h/logs"
bf() { # bf <row-why> -> "<rc>|<stdout>"
  ( export HARNESS="$G/h" HARNESS_VERDICT_AUTHORS=app/cromford HARNESS_OPERATOR_LOGIN=operator
    . "$DIR/bin/lib/gh-pr-list.sh" >/dev/null 2>&1 || exit 9
    . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 9
    mc_init >/dev/null 2>&1
    . "$T/bf.sh"
    say() { printf 'say: %s\n' "$*" >> "$G/say.txt"; }
    gh_rest() {
      local f; f="$G/gh/$(printf '%s' "$2" | tr '/?=&' '____')"
      [ -f "$f.status" ] && { GH_REST_STATUS=$(cat "$f.status"); return 75; }
      [ -f "$f" ] && { cat "$f"; return 0; }
      GH_REST_STATUS=404; return 44
    }
    printf 'o/tproj#530\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$NOWS" "$HEADX" "$HEADX" "$1" "$URL530" > "$MC_ROWS"
    out=$(br_findings "$URL530" head-not-reapproved "$HEADX"); rc=$?
    printf '%s|%s' "$rc" "$out" )
}
cfile() { printf '%s\n' "$2" > "$G/gh/$(printf 'repos/o/tproj/issues/comments/%s' "$1" | tr '/?=&' '____')"; }
listf="$G/gh/$(printf 'repos/o/tproj/issues/530/comments' | tr '/?=&' '____')"
jq -nc '[{user:{login:"cromford[bot]"},body:"Head-bound harness re-review: BLOCK. Finding: the OLD brief."}]' > "$listf"
cfile 9001 "$(jq -nc --arg b "$AP_BODY" --arg u "$BURL" '{id:9001,user:{login:"cromford[bot]"},html_url:$u,body:$b,issue_url:"https://api.github.com/repos/o/tproj/issues/530"}')"
got=$(bf "$WHY")
[ "${got%%|*}" = 0 ] && ok || bad "R3a rc 0: $got"
grep -qF "Review BLOCK [BLOCK core-flow-broken] ($BURL) on ${HEADX:0:12}:" <<<"$got" && ok || bad "R3a the header line names the tag, url and head: $got"
grep -qF "the sign-in form posts to a route the CSP blocks" <<<"$got" && ok || bad "R3a the BLOCK body is the brief: $got"
grep -q "the OLD brief" <<<"$got" && bad "R3a the head-bound grep must not replace the parked BLOCK: $got" || ok
cfile 9001 "$(jq -nc --arg b "$AP_BODY" '{id:9001,user:{login:"someuser"},html_url:"u",body:$b}')"
got=$(bf "$WHY")
[ "${got%%|*}" = 0 ] && grep -q "the OLD brief" <<<"$got" && ! grep -q "CSP blocks" <<<"$got" && ok \
  || bad "R3b an untrusted author is not the brief; the head-bound comment is: $got"
# R3e-h: only a verdict author (or the operator login) with the marker of THIS
# head is a brief; every other comment falls back to the head-bound read.
r3fall() { # r3fall <name> <login> <body>
  cfile 9001 "$(jq -nc --arg l "$2" --arg b "$3" --arg u "$BURL" '{id:9001,user:{login:$l},html_url:$u,body:$b}')"
  got=$(bf "$WHY")
  [ "${got%%|*}" = 0 ] && grep -q "the OLD brief" <<<"$got" && ! grep -q "CSP blocks" <<<"$got" && ok \
    || bad "$1: not a brief; the head-bound comment is: $got"
}
r3fall "R3e github-actions[bot] with this head's marker" 'github-actions[bot]' "$AP_BODY"
r3fall "R3f a non-verdict-author bot (dependabot[bot]) with this head's marker" 'dependabot[bot]' "$AP_BODY"
r3fall "R3g a verdict author whose marker names a DIFFERENT head" 'cromford[bot]' "<!-- harness-review-autopilot def456def456 -->
- [BLOCK core-flow-broken] the sign-in form posts to a route the CSP blocks"
r3fall "R3h a verdict author with no marker" 'cromford[bot]' "- [BLOCK core-flow-broken] the sign-in form posts to a route the CSP blocks
VERDICT: BLOCK"
cfile 9001 "$(jq -nc --arg b "$AP_BODY" --arg u "$BURL" '{id:9001,user:{login:"operator"},html_url:$u,body:$b}')"
got=$(bf "$WHY")
[ "${got%%|*}" = 0 ] && grep -q "CSP blocks" <<<"$got" && ok || bad "R3i the operator login with this head's marker is the brief (project-4-site#4): $got"
echo 500 > "$G/gh/$(printf 'repos/o/tproj/issues/comments/9001' | tr '/?=&' '____').status"
got=$(bf "$WHY")
[ "${got%%|*}" = 75 ] && ok || bad "R3c an unreadable BLOCK is rc 75 (no rung spent): $got"
got=$(bf "head-not-reapproved")
[ "${got%%|*}" = 0 ] && grep -q "the OLD brief" <<<"$got" && ok || bad "R3d any other park reads the head-bound comment as before: $got"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
