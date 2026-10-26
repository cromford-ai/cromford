#!/bin/bash
# tests/gate-trk-selfwrite.bh-8449-test.sh — BH-8449 (C1 of #7920): the REAL
# bin/triage-gate.sh absorbs a Jira or Linear fingerprint that moved only
# because WE commented, and runs on anything else.
#
# Linear is tests/lib/linear-stub.bh-7920.sh over a copy of the C0 fixtures
# (CRO-12: Todo, ai-build, two client comments). Each case seeds the consumed
# fingerprint with --seed and then moves the stub's answers.
#   A1  row tracker_linear.crolin.self_actors=Harness Bot, one new comment by
#       Harness Bot (2 -> 3, updatedAt newer): SKIP self-writes-only, the
#       consumed fingerprint is the new one, and the next tick is SKIP no-change
#   A2  the same comment with no self_actors row: RUN board-changed, 0 reads
#   A3  the new comment is by someone else (Client Person, harness bot,
#       "Harness  Bot", Harness Bot2): RUN board-changed, gate.json unchanged
#   A4  two new comments, ours then the client's: RUN board-changed
#   A5  two new comments, both ours: SKIP self-writes-only
#   A6  our comment plus a status change on the same row: RUN, 0 reads
#   A7  updatedAt moved with no comment delta: RUN board-changed
#   A8  a new ticket entered the list: RUN board-changed
#   A9  the thread read fails (not-found): RUN board-changed, gate.json unchanged
#   A10 6 changed rows, all our comments: RUN board-changed (MAX_CHANGED), 0 reads
#   A11 commentCount null on the new side (over the list cap): RUN board-changed
#   A12 Jira (tests/lib/tracker-jira-stub.sh): row tracker_jira.jproj.self_actors
#       and one new comment by Harness Bot on SCRUM-12: SKIP self-writes-only;
#       the same comment by another author: RUN board-changed
#   A13 the in-app board classifier is unchanged: gate-selfwrite.py with no
#       GATE_SELFWRITE_MODE prints ABSORB for a self comment, RUN for a client's
#   HARNESS_TEST_SANDBOX=1 bash tests/gate-trk-selfwrite.bh-8449-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/linear-stub.bh-7920.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

KEY=lin-api-fixture-sentinel-8449
GATE="$DIR/bin/triage-gate.sh"   # impact: bin/lib/gate-trk-selfwrite.sh bin/gate-selfwrite.py
FIX="$T/fix"; H="$T/h"
mkdir -p "$FIX" "$H/bin" "$H/env" "$H/state" "$H/logs" "$H/flags"
cp "$DIR/tests/fixtures/triage-intake.bh-7920/linear/"*.json "$FIX/"
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null || exit 1
printf '#!/bin/bash\necho "$*" >> "%s/logs/alert-line.log"\n' "$H" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset>
crolin  o/crolin  https://x.example  -  2
CONF
linear_stub_setup "$T" "$FIX" || { echo "stub setup failed"; exit 1; }
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 LS_KEY_EXPECT="$KEY"
printf 'LINEAR_API_KEY=%s\nLINEAR_TEAM=CRO\n' "$KEY" > "$H/env/crolin.env"
linear_set tracker_adapter.crolin linear
linear_set tracker_linear.crolin.team CRO
GJ="$H/state/crolin.gate.json"; GP="$H/state/crolin.gate.pending"
gate() { "$GATE" crolin "$@" 2>>"$T/gate.err"; }

T1=2026-10-22T10:00:00.000Z; T2=2026-10-22T10:05:00.000Z
# seed — a fresh consumed fingerprint from the stub's current answers.
seed() {
  rm -f "$GJ" "$GP" "$LS_STATE/issues.json" "$LS_STATE"/issue-*.json
  [ -n "${1:-}" ] && cp "$1" "$LS_STATE/issues.json"
  echo 9999999999 > "$H/state/crolin.gate-meta"   # the daily sweep is not due
  gate --seed >/dev/null
  cp "$GJ" "$T/seeded.json"
  linear_reset_log
}
# list_move <jq> — the TrkIssues answer becomes the seeded one with <jq> applied.
list_move() { jq "$1" "${2:-$FIX/issues.json}" > "$LS_STATE/issues.json"; }
# bump <n> [<updatedAt>] — CRO-12 gains n comments in the list.
bump() { list_move ".data.issues.nodes[0].comments.nodes += [range($1) | {id: \"c-new-\(.)\"}]
                    | .data.issues.nodes[0].updatedAt = \"${2:-$T2}\""; }
# thread <author>... — CRO-12's thread gains one comment per author, in order.
thread() {
  local a args='[]'
  for a in "$@"; do args=$(jq -c --arg a "$a" '. + [$a]' <<<"$args"); done
  jq --argjson as "$args" --arg t "$T1" '.data.issue.comments.nodes += [ $as | to_entries[]
      | {body: "note \(.key)", createdAt: ($t | sub("00.000Z$"; "0\(.key).000Z")), user: {name: .value, displayName: .value}, botActor: null} ]' \
    "$FIX/issue-CRO-12.json" > "$LS_STATE/issue-CRO-12.json"
}
self_on()  { linear_set tracker_linear.crolin.self_actors "Harness Bot, Deploy Bot"; }
self_off() { linear_unset tracker_linear.crolin.self_actors; }
unchanged() { cmp -s "$GJ" "$T/seeded.json"; }
reads() { linear_req_count TrkIssue; }

# ---- A1 -------------------------------------------------------------------------------
self_on; seed; bump 1; thread "Harness Bot"
out=$(gate); eq "A1 one comment by us" "$out" "SKIP self-writes-only"
[ "$(jq -r '.linear[0].commentCount' "$GJ" 2>/dev/null)" = 3 ] && [ ! -e "$GP" ] && ok \
  || bad "A1 the consumed fingerprint is the new one: $(jq -c '.linear[0]' "$GJ" 2>/dev/null) pending=$([ -e "$GP" ] && echo yes)"
eq "A1 one thread read" "$(reads)" 1
eq "A1 the read was CRO-12" "$(linear_req_of TrkIssue | jq -r .variables.id)" CRO-12
out=$(gate); eq "A1 the next tick" "$out" "SKIP no-change (1 tickets)"

# ---- A2 -------------------------------------------------------------------------------
self_off; seed; bump 1; thread "Harness Bot"
out=$(gate); eq "A2 no self_actors row" "$out" "RUN board-changed"
eq "A2 0 reads" "$(reads)" 0
unchanged && ok || bad "A2 gate.json must not move"
self_on

# ---- A3 -------------------------------------------------------------------------------
for who in "Client Person" "harness bot" "Harness  Bot" "Harness Bot2" ""; do
  seed; bump 1; thread "$who"
  out=$(gate); eq "A3 a comment by '$who'" "$out" "RUN board-changed"
  unchanged && ok || bad "A3 '$who': gate.json must not move"
  [ -e "$GP" ] && ok || bad "A3 '$who': the pending fingerprint stays for the session"
done

# ---- A4 / A5 --------------------------------------------------------------------------
seed; bump 2; thread "Harness Bot" "Client Person"
out=$(gate); eq "A4 ours then the client's" "$out" "RUN board-changed"
seed; bump 2; thread "Client Person" "Harness Bot"
out=$(gate); eq "A4 the client's then ours" "$out" "RUN board-changed"
seed; bump 2; thread "Harness Bot" "Deploy Bot"
out=$(gate); eq "A5 two new comments, both ours" "$out" "SKIP self-writes-only"
# A count delta larger than the thread we can read is not proof.
seed; bump 2; thread "Harness Bot"
list_move '.data.issues.nodes[0].comments.nodes += [{id:"c-x"},{id:"c-y"},{id:"c-z"}] | .data.issues.nodes[0].updatedAt = "'"$T2"'"'
out=$(gate); eq "A4 more new comments than the thread holds" "$out" "RUN board-changed"

# ---- A6 / A7 / A8 ---------------------------------------------------------------------
seed; thread "Harness Bot"
list_move '.data.issues.nodes[0].comments.nodes += [{id:"c-new"}] | .data.issues.nodes[0].updatedAt = "'"$T2"'"
           | .data.issues.nodes[0].state = {name: "In Progress", type: "started"}'
out=$(gate); eq "A6 our comment plus a status move" "$out" "RUN board-changed"
eq "A6 0 reads" "$(reads)" 0
seed; thread "Harness Bot"
list_move '.data.issues.nodes[0].updatedAt = "'"$T2"'"'
out=$(gate); eq "A7 updatedAt only" "$out" "RUN board-changed"
seed; thread "Harness Bot"
list_move '.data.issues.nodes += [.data.issues.nodes[0] | .identifier = "CRO-15" | .url = "https://linear.app/crosstest/issue/CRO-15/x"]'
out=$(gate); eq "A8 a new ticket" "$out" "RUN board-changed"

# ---- A9 -------------------------------------------------------------------------------
seed; bump 1
mv "$FIX/issue-CRO-12.json" "$T/issue-CRO-12.away"
out=$(gate); eq "A9 a failed read" "$out" "RUN board-changed"
eq "A9 the read was tried" "$(reads)" 1
unchanged && ok || bad "A9 gate.json must not move"
mv "$T/issue-CRO-12.away" "$FIX/issue-CRO-12.json"

# ---- A10 ------------------------------------------------------------------------------
jq '.data.issues.nodes = [.data.issues.nodes[0] as $n | range(12; 18) as $i | ($n | .identifier = "CRO-\($i)")]' "$FIX/issues.json" > "$T/six.json"
seed "$T/six.json"
eq "A10 six tickets seeded" "$(jq -c '[.linear[].id]' "$GJ" 2>/dev/null)" '["CRO-12","CRO-13","CRO-14","CRO-15","CRO-16","CRO-17"]'
list_move '.data.issues.nodes |= map(.comments.nodes += [{id:"c-new"}] | .updatedAt = "'"$T2"'")' "$T/six.json"
out=$(gate); eq "A10 six changed rows" "$out" "RUN board-changed"
eq "A10 0 reads" "$(reads)" 0

# ---- A11 ------------------------------------------------------------------------------
seed; thread "Harness Bot"
list_move '.data.issues.nodes[0].comments.nodes += [{id:"c-new"}] | .data.issues.nodes[0].comments.pageInfo.hasNextPage = true
           | .data.issues.nodes[0].updatedAt = "'"$T2"'"'
out=$(gate); eq "A11 commentCount null" "$out" "RUN board-changed"
eq "A11 the pending row's count is null" "$(jq -r '.linear[0].commentCount' "$GP" 2>/dev/null)" null

[ ! -s "$LS_STATE/gh.log" ] && ok || bad "Linear cases called gh: $(cat "$LS_STATE/gh.log")"
[ ! -e "$LS_STATE/authbad" ] && ok || bad "a Linear call carried the wrong key"
LEAK=$(grep -rlF -- "$KEY" "$H/state" "$H/logs" "$H/flags" "$LS_STATE" 2>/dev/null)
[ -z "$LEAK" ] && ok || bad "the Linear key reached: $LEAK"

# ---- A12: Jira --------------------------------------------------------------------------
a12() { # a12 <author> -> the gate's answer after one new comment by <author>
  ( . "$DIR/tests/lib/tracker-jira-stub.sh" || exit 9
    jira_stub_setup "$T/j" || exit 9
    export JIRA_STUB_FIX="$DIR/tests/fixtures/triage-intake.bh-7920/jira"
    scratch_install_closure bin/fleet-conf.sh "$T/j/h" >/dev/null || exit 9
    printf 'jproj  o/j  https://j.example  -  9\n' > "$T/j/h/fleet.conf"
    export FLEET_CONF="$T/j/h/fleet.conf" GH_ETAG=0
    for r in write_projects comment_projects waiting_on_field triage_verdict_field; do jira_unset "tracker_jira.jproj.$r"; done
    jira_set tracker_jira.jproj.read_projects SCRUM
    jira_set tracker_jira.jproj.self_actors "Harness Bot"
    S="$JIRA_STUB_STATE"; rm -f "$S/search-page1.json" "$S/comments-SCRUM-12.json" "$T/j/h/state/jproj.gate.json"
    echo 9999999999 > "$T/j/h/state/jproj.gate-meta"
    "$GATE" jproj --seed >/dev/null 2>&1
    jq '.issues[0].fields.comment.total = 3 | .issues[0].fields.updated = "2026-10-22T10:05:00.000+0000"' \
      "$JIRA_STUB_FIX/search-page1.json" > "$S/search-page1.json"
    jq --arg a "$1" '.comments += [{id: "10103", author: {displayName: $a, accountId: "acct-fixture-9"},
        body: {type: "doc", version: 1, content: [{type: "paragraph", content: [{type: "text", text: "Shipped."}]}]},
        created: "2026-10-22T10:05:00.000+0000"}] | .total = 3' \
      "$JIRA_STUB_FIX/comments-SCRUM-12.json" > "$S/comments-SCRUM-12.json"
    "$GATE" jproj 2>/dev/null
    [ -s "$S/gh.log" ] && echo "GH-CALLED" )
}
eq "A12 jira, our comment" "$(a12 "Harness Bot")" "SKIP self-writes-only"
eq "A12 jira, another author" "$(a12 "Client User")" "RUN board-changed"

# ---- A13: the board classifier, default mode ---------------------------------------
mkdir -p "$T/bstub"
cat > "$T/bstub/curl" <<'SH'
#!/bin/bash
echo "curl $*" >> "$BSTUB_LOG"
printf '{"ticket":{"id":"t1","comments":[{"author":{"name":"%s"},"createdAt":"2026-10-22T10:00:00Z"}]}}' "$BSTUB_AUTHOR"
SH
chmod +x "$T/bstub/curl"
printf '{"b1":[{"id":"t1","status":"todo","commentCount":1,"lastActivityAt":"2026-10-22T09:00:00Z"}]}' > "$T/b-old.json"
printf '{"b1":[{"id":"t1","status":"todo","commentCount":2,"lastActivityAt":"2026-10-22T10:00:00Z"}]}' > "$T/b-new.json"
gsw() { ( unset GATE_SELFWRITE_MODE; PATH="$T/bstub:$PATH" BSTUB_LOG="$T/bstub.log" BSTUB_AUTHOR="$1" \
          GATE_OLD="$T/b-old.json" GATE_NEW="$T/b-new.json" BASE=https://board.example BP=/api/board \
          TOKEN=tok-fixture-board SELF_ACTORS="Harness Bot" python3 "$DIR/bin/gate-selfwrite.py" ); }
eq "A13 board, a self comment" "$(gsw "Harness Bot")" ABSORB
eq "A13 board, a client comment" "$(gsw "Client Person")" RUN
grep -q 'https://board.example/api/board/tickets/t1' "$T/bstub.log" && ok || bad "A13 the board ticket was fetched: $(cat "$T/bstub.log" 2>/dev/null)"

echo "gate-trk-selfwrite.bh-8449: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
