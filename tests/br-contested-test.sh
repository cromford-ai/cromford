#!/bin/bash
# tests/br-contested-test.sh — a conflict that keeps coming back is CONTESTED,
# and the ladder is not one shape for every park. Sections 9 and 10 of the old
# tests/blocked-resolver-test.sh (BH-579), moved here verbatim by BH-1196.
#
# WHY THEY ARE ONE SUITE. Section 10's cases are written against section 9's
# helpers and both run on the same real local git, so splitting them would mean
# rewriting assertions — which is the one thing a move is not allowed to do.
# What they pin: a path two open PRs both touch is contested, so the loser HOLDS
# rather than burning rungs it cannot win; and a SMALL conflict is worth a second
# fix round while a big one goes straight to the rebuild.
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   9.  a conflict that keeps coming back is contested
#   10. two ladder shapes
# Run from anywhere: tests/br-contested-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# The real local git both sections drive (the old suite's section-8 fixture,
# lines 846-988): branches that genuinely conflict with main, the mc_rebase rc
# contract, and the gh and agent-call stubs the ladder runs against.
fx_br_ladder_git "$DIR" "$T" || exit 1

# CARRIED SETUP (BH-1196). Section 9b drives a park on ticket/TK-88, and it
# expects today's rung to be the rebuild: in the monolith, section 8 (now
# tests/br-rungs-test.sh) had already spent that ticket's mechanical rung and its
# fix round in the same process, and the state json it left behind is what put
# the ladder on rung 3. Measured on the monolith at the start of section 9:
# tproj-TK-88 carries mechanicals 1, fixrounds 1, rebuilds 0. SPENT (the
# monolith's own helper, its line 685, now in tests/lib/fixture-harness.sh)
# states that history outright. No assertion below is touched.
SPENT tproj-TK-88

# ============================================================================
# 9. A CONFLICT THAT KEEPS COMING BACK IS CONTESTED (BH-579, 2026-09-17).
#
#    TK-1529 was rebuilt three times and then ABANDONED, and every rebuild hit
#    the SAME conflict on the same file: siblings kept landing edits to it while
#    this ticket walked its ladder. Rebuilding a ticket against a path somebody
#    else is still moving buys the same conflict at full price.
#
#    So the second time one path conflicts under a DIFFERENT (pr, head) of one
#    ticket, this lane writes a CONTESTED HOLD instead of the rebuild: the
#    ticket wins the path, every open PR and planned ticket touching it is
#    parked behind the hold, and the winner gets one bonus fix round to land.
#    The hold ends when the winner merges, is abandoned, or its TTL runs out —
#    and a release UNPARKS the losers, it never closes anything.
#
#    THE PARKS ARE THE DANGEROUS PART: this is the one thing in the lane that
#    acts on OTHER people's PRs. So the negatives carry the weight — the same
#    (pr, head) re-offered, a different path, src/a.ts vs src/a.tsx, the
#    winner's own rebuild PR, a PR nobody here authored, observe mode, a hold
#    that will not write, and a malformed hold file.
# ============================================================================
NOW=$(date -u +%s)
# ROWS writes SEVERAL rows at once (ROW overwrites the file with one): a hold
# parks competitors, so every case here needs a winner and its losers side by
# side. spec: key|STATE|reason|url|head|reviewed
ROWS() {
  local spec k st why url head rev
  : > "$H/state/merge-conductor/pr-state.tsv"
  for spec in "$@"; do
    IFS='|' read -r k st why url head rev <<<"$spec"
    printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
      "$k" "$st" "$NOW" "${head:-abc123}" "${rev:-abc123}" "$why" "$url" \
      >> "$H/state/merge-conductor/pr-state.tsv"
  done
}
ROWF() { awk -F'\t' -v k="$1" -v n="$2" '$1==k{print $n; exit}' "$H/state/merge-conductor/pr-state.tsv"; }
# The hold store's natural key is (project, path) — sha1 of the path, first 16.
HOLDF() { printf '%s/state/contested/tproj/%s' "$H" "$(printf '%s' "$1" | sha1sum | cut -c1-16)"; }
HOLDN() { find "$H/state/contested/tproj" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l; }
# lane-alert now records to the ALERTS log as well, because the release rules
# are asserted on what a reader of ALERTS.log would actually see.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\nexit 0\n' \
  "$T" "$H" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The open PRs of o/tproj, in the REST shape gh api answers with: #95 is the
# winner's own PR, #96 and #97 are the competitors, #100 is the winner's OWN
# rebuild (ticket/TK-95-r2 — never its own loser) and #200 belongs to somebody
# who is not this harness (harness_pr_list drops it before we ever see it).
cat > "$T/openprs" <<'EOF'
[
 {"number":95,"html_url":"https://github.com/o/tproj/pull/95","user":{"login":"operator","type":"User"},"state":"open","merged_at":null,"head":{"sha":"9595959595959595959595959595959595959595","ref":"ticket/TK-95"}},
 {"number":96,"html_url":"https://github.com/o/tproj/pull/96","user":{"login":"operator","type":"User"},"state":"open","merged_at":null,"head":{"sha":"9696969696969696969696969696969696969696","ref":"ticket/TK-96"}},
 {"number":97,"html_url":"https://github.com/o/tproj/pull/97","user":{"login":"app/cromford","type":"Bot"},"state":"open","merged_at":null,"head":{"sha":"9797979797979797979797979797979797979797","ref":"ticket/TK-97"}},
 {"number":100,"html_url":"https://github.com/o/tproj/pull/100","user":{"login":"operator","type":"User"},"state":"open","merged_at":null,"head":{"sha":"1001001001001001001001001001001001001000","ref":"ticket/TK-95-r2"}},
 {"number":200,"html_url":"https://github.com/o/tproj/pull/200","user":{"login":"somebody-else","type":"User"},"state":"open","merged_at":null,"head":{"sha":"2002002002002002002002002002002002002000","ref":"feature/theirs"}}
]
EOF
printf 'a.txt\n' > "$T/prfiles"
# Two planned tickets name a.txt and one names a.txtx: the path match is
# "equal, or this path's parent directory", never a prefix of the string.
mkdir -p "$H/plans/tproj-TK-95" "$H/plans/tproj-TK-97x" "$H/plans/tproj-TK-97y"
printf 'SOURCE: tier1\na.txt\n'  > "$H/plans/tproj-TK-95/planned-files.txt"
printf 'SOURCE: tier1\na.txt\n'  > "$H/plans/tproj-TK-97x/planned-files.txt"
printf 'SOURCE: tier1\na.txtx\n' > "$H/plans/tproj-TK-97y/planned-files.txt"
mkdir -p "$H/state/merge-conductor/conflict-size" "$H/state/contested/tproj"

# ---- 9a. THE SECOND PARK ON THE SAME PATH WRITES THE HOLD.
#          Tick A is an ordinary ladder: the mechanical rung conflicts on a.txt,
#          the fix round lands. Tick B is the same path again on the head that
#          fix round pushed — a DIFFERENT (pr, head) — and the rung after it
#          would be the rebuild.
U95=https://github.com/o/tproj/pull/95
U96=https://github.com/o/tproj/pull/96
U97=https://github.com/o/tproj/pull/97
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-95.json"
touch "$T/agent-resolves"
printf 'ticket/TK-95\n' > "$T/prbranch"; osha ticket/TK-95 > "$T/prhead"
H1=$(osha ticket/TK-95)
# The conductor measured this conflict at 500 lines: the LARGE ladder, one fix
# round then the rebuild, which is what makes tick B's next rung the rebuild.
printf '500\t%s\ta.txt\n' "$H1" > "$H/state/merge-conductor/conflict-size/o_tproj_95"
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
ROWS "o/tproj#95|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U95|$H1|$H1" \
     "o/tproj#96|NEEDS_REBASE|dirty|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|NEEDS_REBASE|dirty|$U97|9797979797979797979797979797979797979797|rev97sha"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ "$(STATEJSON tproj-TK-95 | jq -r .fixrounds)" = 1 ] && ok \
  || bad "9a tick A must land one fix round (got $(STATEJSON tproj-TK-95 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'))"
[ "$(STATEJSON tproj-TK-95 | jq -r '.conflicts|length')" = 1 ] && ok \
  || bad "tick A must record ONE conflict occurrence for one (pr, head) (got $(STATEJSON tproj-TK-95 | jq -c '.conflicts'))"
[ "$(STATEJSON tproj-TK-95 | jq -r .conflict_lines)" = 500 ] && ok \
  || bad "the sidecar measurement must win over the fix round's own smaller one (conflict_lines is a max)"
[ "$(HOLDN)" = 0 ] && ok || bad "one park on a path is not a recurrence — no hold may exist yet"

# main moves on a.txt again, so the next park is a REAL second conflict on the
# same path rather than a fixture that says the word.
git -C "$SEED" checkout -q main
git -C "$SEED" pull -q --ff-only origin main
printf 'main changed this line again\n' >> "$SEED/a.txt"
git -C "$SEED" commit -qam "main work 2"; git -C "$SEED" push -q origin main
H2=$(osha ticket/TK-95)
printf '%s\n' "$H2" > "$T/prhead"
ROWS "o/tproj#95|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U95|$H2|$H2" \
     "o/tproj#96|NEEDS_REBASE|dirty|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|NEEDS_REBASE|dirty|$U97|9797979797979797979797979797979797979797|rev97sha"

# ---- the OBSERVE negative runs first: the same park, the kill switch on.
touch "$H/flags/blocked-resolver-observe"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'WOULD write a contested hold' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe mode must SAY what it would hold (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(HOLDN)" = 0 ] && ok || bad "observe mode must write no hold at all"
[ "$(ROWF o/tproj#96 2)" = NEEDS_REBASE ] && ok || bad "observe mode must park nobody (row 96 is $(ROWF o/tproj#96 2))"
[ "$(STATEJSON tproj-TK-95 | jq -r '.fixround_bonus // 0')" = 0 ] && ok \
  || bad "observe mode must not grant the bonus round either"
rm -f "$H/flags/blocked-resolver-observe"

# ---- and now the real tick B.
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$H/logs/blocked-resolver.log"
: > "$H/logs/ALERTS.log"
RUN
HOLD=$(HOLDF a.txt)
grep -q 'EVENT resolver_contested' "$H/logs/blocked-resolver.log" && ok \
  || bad "writing a hold is an event like every other transition (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
grep -q 'rung 2 fix-round' "$H/logs/blocked-resolver.log" && ok \
  || bad "the hold buys the winner a BONUS fix round, not a rebuild (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && bad "a contested park must not close the PR (closed: $(cat "$T/closed.txt"))" || ok
[ -s "$T/queue.txt" ] && bad "a contested park must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok
[ -s "$HOLD" ] && ok || bad "the hold file must exist at the (project, path) key"
[ "$(jq -r .winner_key "$HOLD" 2>/dev/null)" = TK-95 ] && ok \
  || bad "the ticket that kept hitting the conflict is the winner (got $(jq -r .winner_key "$HOLD" 2>/dev/null))"
[ "$(jq -c '[.loser_prs[].num]|sort' "$HOLD" 2>/dev/null)" = '[96,97]' ] && ok \
  || bad "the losers are the open harness PRs touching a.txt — not #95, not its own rebuild #100, not #200 which is nobody's of ours (got $(jq -c '[.loser_prs[].num]' "$HOLD" 2>/dev/null))"
[ "$(jq -c .loser_tickets "$HOLD" 2>/dev/null)" = '["TK-97x"]' ] && ok \
  || bad "the planned tickets are the ones whose list NAMES a.txt — never TK-95 itself, never TK-97y's a.txtx (got $(jq -c .loser_tickets "$HOLD" 2>/dev/null))"
[ "$(ROWF o/tproj#96 2)" = BLOCKED_HUMAN ] && ok || bad "loser #96 must be parked (state $(ROWF o/tproj#96 2))"
[ "$(ROWF o/tproj#96 7)" = 'contested:a.txt (winner TK-95)' ] && ok \
  || bad "the park reason names the path and the winner (got '$(ROWF o/tproj#96 7)')"
[ "$(ROWF o/tproj#97 7)" = 'contested:a.txt (winner TK-95)' ] && ok \
  || bad "both losers are parked, not just the first (got '$(ROWF o/tproj#97 7)')"
[ "$(ROWF o/tproj#96 5)" = rev96sha ] && ok \
  || bad "parking a loser must keep its reviewed sha — that approval is still good (got '$(ROWF o/tproj#96 5)')"
[ "$(STATEJSON tproj-TK-95 | jq -r .fixrounds)" = 2 ] && ok \
  || bad "the bonus round must RUN (fixrounds $(STATEJSON tproj-TK-95 | jq -r .fixrounds))"
[ "$(STATEJSON tproj-TK-95 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "and nothing may be rebuilt while the hold is fresh"
[ "$(STATEJSON tproj-TK-95 | jq -r .fixround_bonus)" = 1 ] && ok \
  || bad "the bonus is persisted BEFORE the round runs, so a crash cannot grant it twice (got $(STATEJSON tproj-TK-95 | jq -r '.fixround_bonus // "absent"'))"
[ "$(STATEJSON tproj-TK-95 | jq -c '.contested.paths')" = '["a.txt"]' ] && ok \
  || bad "the ticket carries the contested mark, which is what stops a second hold (got $(STATEJSON tproj-TK-95 | jq -c '.contested'))"
[ "$(STATEJSON tproj-TK-95 | jq -r '.conflicts|length')" = 2 ] && ok \
  || bad "two occurrences on two heads must be two entries (got $(STATEJSON tproj-TK-95 | jq -c '[.conflicts[].head]'))"
[ "$(STATEJSON tproj-TK-95 | jq -r '[.conflicts[].head]|unique|length')" = 2 ] && ok \
  || bad "and those entries must be on DIFFERENT heads, or nothing recurred"
[ "$(grep -c 'pulls?state=open' "$T/gh.txt")" = 1 ] && ok \
  || bad "ONE open-PR list call per hold creation (got $(grep -c 'pulls?state=open' "$T/gh.txt"))"

# ---- 9b. A DIFFERENT PATH IS NOT A RECURRENCE. Same ticket, same ladder, but
#          the park is on b.txt this time: today's rung, no hold.
printf 'ticket/TK-88\n' > "$T/prbranch"; osha ticket/TK-88 > "$T/prhead"
printf '500\t%s\tb.txt\n' "$(osha ticket/TK-88)" > "$H/state/merge-conductor/conflict-size/o_tproj_88"
ROWS "o/tproj#88|BLOCKED_HUMAN|conflict-unresolvable: b.txt|https://github.com/o/tproj/pull/88|$(osha ticket/TK-88)|abc123" \
     "o/tproj#95|WAIT_CI|rebased|$U95|$(osha ticket/TK-95)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'pulls/88' "$T/closed.txt" && ok \
  || bad "a park on a path that never recurred must take today's rung — the rebuild (closed: $(cat "$T/closed.txt"))"
grep -q '^tproj TK-88 88 fly 0 ' "$T/queue.txt" && ok \
  || bad "and enqueue the ticket fresh (got: $(cat "$T/queue.txt"))"
[ -e "$(HOLDF b.txt)" ] && bad "b.txt never recurred — it must have no hold" || ok
[ "$(HOLDN)" = 1 ] && ok || bad "the only hold in the store is still a.txt's (got $(HOLDN))"

# ---- 9c. A LOSER SPENDS NOTHING. #96 is parked on the contested path and the
#          conductor offers it as an ordinary conflict park: this lane must
#          answer with one log line and no gh call at all.
printf 'ticket/TK-96\n' > "$T/prbranch"
printf '9696969696969696969696969696969696969696\n' > "$T/prhead"
ROWS "o/tproj#96|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U97|9797979797979797979797979797979797979797|rev97sha" \
     "o/tproj#95|WAIT_CI|rebased|$U95|$(osha ticket/TK-95)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'held: contested a.txt (winner TK-95)' "$H/logs/blocked-resolver.log" && ok \
  || bad "a loser must be answered with ONE line naming the path and the winner (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-96.json" ] \
  && bad "a loser spends no rung and writes no state (got $(STATEJSON tproj-TK-96))" || ok
[ -s "$T/closed.txt" ] && bad "a loser's PR must never be closed" || ok
[ -s "$T/queue.txt" ] && bad "a loser must never be rebuilt while somebody else holds the path" || ok
# ONE read names #96 this tick and it is DISCOVERY's (#783 moved
# br_conductor_emit's head-branch read to `gh api repos/<slug>/pulls/<n>`, which
# every candidate pays before br_one ever sees it). The skip itself buys
# nothing: a second read of #96 is a decision read this rung must never make.
# The pattern is anchored past the number (BH-872): the review-verdict source is
# DISCOVERY too, and it names this PR as `pulls/96/reviews` on every tick. What
# this pins is unchanged — the head-branch read `pulls/96`, once, and no second
# decision read bought by the skip.
[ "$(grep -cE 'pulls/96($|[^/])' "$T/gh.txt")" = 1 ] && ok \
  || bad "the loser skip must buy no read of its own — only discovery's one head-branch read may name #96 (got: $(cat "$T/gh.txt"))"
grep -q 'o-tproj-97' "$H/logs/blocked-resolver.log" \
  && bad "a row already parked 'contested:…' must not even be offered to the ladder" || ok

# ---- 9d. THE WINNER MERGED: the sweep releases the hold and hands the losers
#          back to the conductor, with no alert and no gh call.
ROWS "o/tproj#95|MERGED|merged|$U95|$(osha ticket/TK-95)|abc123" \
     "o/tproj#96|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U97|9797979797979797979797979797979797979797|rev97sha"
: > "$T/gh.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"
RUN
[ -e "$HOLD" ] && bad "a merged winner ends its hold" || ok
[ "$(ROWF o/tproj#96 2)" = NEEDS_REBASE ] && ok \
  || bad "a released loser goes back to the conductor as NEEDS_REBASE (got $(ROWF o/tproj#96 2))"
[ "$(ROWF o/tproj#96 7)" = 'contested released: winner merged' ] && ok \
  || bad "the release says why (got '$(ROWF o/tproj#96 7)')"
[ "$(ROWF o/tproj#97 2)" = NEEDS_REBASE ] && ok || bad "both losers are released, not just the first"
[ "$(grep -c contested "$H/logs/ALERTS.log")" = 0 ] && ok \
  || bad "a winner that MERGED is the happy ending — it must not page (got: $(cat "$H/logs/ALERTS.log"))"
# DISCOVERY'S OWN READS ARE NOT THE SWEEP'S (BH-872): the review-verdict source
# buys one open-PR list per tick and one reviews read per open harness PR before
# any rung runs. The sweep itself must still read nothing — which is what this
# counts, every gh line that is not one of those.
[ "$(grep -cEv 'pulls\?state=open|pulls/[0-9]+/reviews' "$T/gh.txt")" = 0 ] && ok \
  || bad "the sweep reads the conductor's row, not GitHub (got: $(cat "$T/gh.txt"))"

# ---- 9d2. THE WINNER HAS NO ROW: the one arm that asks GitHub, and it asks
#           over REST, through br_pr_state — the file's own three-answer read
#           (#783). `gh pr view --json state` is GraphQL, and the GraphQL bucket
#           is the one that dies first on these accounts — a sweep that cannot
#           read the winner leaves every loser parked until the TTL. A read
#           GitHub did NOT answer is its own answer here: the hold stays and the
#           `UNVERIFIABLE (HTTP …)` line says so, instead of a raw read
#           collapsing a 5xx into "not merged" with nothing in the log.
jq -nc --argjson created "$NOW" \
  '{project:"tproj",repo:"o/tproj",path:"a.txt",winner_key:"TK-95",
    winner_url:"https://github.com/o/tproj/pull/95",
    loser_prs:[{num:96,url:"https://github.com/o/tproj/pull/96",key:"TK-96"},
               {num:97,url:"https://github.com/o/tproj/pull/97",key:"TK-97"}],
    loser_tickets:[],created:$created,ttl:21600,why:"fixture"}' > "$HOLD"
ROWS "o/tproj#96|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U97|9797979797979797979797979797979797979797|rev97sha"
printf 'OPEN\n' > "$T/prstate"
: > "$T/closed.txt"
: > "$T/gh.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$HOLD" ] && ok || bad "an OPEN winner keeps its hold — only MERGED and CLOSED end it"
[ "$(ROWF o/tproj#96 2)" = BLOCKED_HUMAN ] && ok \
  || bad "and its losers stay parked (got $(ROWF o/tproj#96 2))"
grep -q -- '-i -X GET repos/o/tproj/pulls/95' "$T/gh.txt" && ok \
  || bad "the no-row arm must read the winner's state through br_pr_state's REST envelope (calls: $(cat "$T/gh.txt"))"
grep -q 'pr view https://github.com/o/tproj/pull/95' "$T/gh.txt" \
  && bad "and never over GraphQL — that is the bucket that dies first (calls: $(cat "$T/gh.txt"))" || ok
# A READ GITHUB WOULD NOT ANSWER. Every hold stays exactly where it is, and the
# line that says why is br_pr_state's own — a raw `gh api -q` collapsed a 5xx
# and a rate limit into "not merged" and logged nothing at all.
echo 502 > "$T/st-pr"
: > "$T/gh.txt"; : > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$HOLD" ] && ok || bad "an UNVERIFIABLE winner keeps its hold — unknown is never 'merged' and never 'closed'"
[ "$(ROWF o/tproj#96 2)" = BLOCKED_HUMAN ] && ok \
  || bad "and its losers stay parked on a read nobody could make (got $(ROWF o/tproj#96 2))"
grep -q 'pr state UNVERIFIABLE (HTTP 502' "$H/logs/blocked-resolver.log" && ok \
  || bad "and the sweep says so in the log — silence is what the raw read gave us (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(grep -c contested "$H/logs/ALERTS.log")" = 0 ] && ok \
  || bad "a read that failed is not a winner that failed — it must not page (got: $(cat "$H/logs/ALERTS.log"))"
rm -f "$T/st-pr"
printf 'MERGED\n' > "$T/prstate"
: > "$T/gh.txt"; : > "$H/logs/ALERTS.log"
RUN
[ -e "$HOLD" ] && bad "a winner GitHub says is merged ends the hold" || ok
[ "$(ROWF o/tproj#96 2)" = NEEDS_REBASE ] && ok \
  || bad "and hands the losers back (got $(ROWF o/tproj#96 2))"
[ "$(grep -c contested "$H/logs/ALERTS.log")" = 0 ] && ok \
  || bad "a merged winner is still the happy ending — no page (got: $(cat "$H/logs/ALERTS.log"))"
jq -nc --argjson created "$NOW" \
  '{project:"tproj",repo:"o/tproj",path:"a.txt",winner_key:"TK-95",
    winner_url:"https://github.com/o/tproj/pull/95",
    loser_prs:[{num:96,url:"https://github.com/o/tproj/pull/96",key:"TK-96"}],
    loser_tickets:[],created:$created,ttl:21600,why:"fixture"}' > "$HOLD"
ROWS "o/tproj#96|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U96|9696969696969696969696969696969696969696|rev96sha"
printf 'CLOSED\n' > "$T/prstate"
: > "$H/logs/ALERTS.log"
RUN
[ -e "$HOLD" ] && bad "a CLOSED winner ends the hold too" || ok
[ "$(grep -c 'contested.*closed' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "a winner closed without merging pages once — it was held for nothing (got: $(cat "$H/logs/ALERTS.log"))"
printf 'OPEN\n' > "$T/prstate"

# ---- 9e. THE WINNER WAS ABANDONED: br_abandon releases every hold it won, in
#          the same tick, with one alert.
jq -nc --argjson created "$NOW" \
  '{project:"tproj",repo:"o/tproj",path:"a.txt",winner_key:"TK-95",
    winner_url:"https://github.com/o/tproj/pull/95",
    loser_prs:[{num:96,url:"https://github.com/o/tproj/pull/96",key:"TK-96"},
               {num:97,url:"https://github.com/o/tproj/pull/97",key:"TK-97"}],
    loser_tickets:["TK-97x"],created:$created,ttl:21600,why:"fixture"}' > "$HOLD"
jq -nc '{project:"tproj",rkey:"tproj-TK-95",mechanicals:1,fixrounds:2,rebuilds:3,
         conflict_lines:500,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-95.json"
printf 'ticket/TK-95\n' > "$T/prbranch"; osha ticket/TK-95 > "$T/prhead"
ROWS "o/tproj#95|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U95|$(osha ticket/TK-95)|abc123" \
     "o/tproj#96|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U97|9797979797979797979797979797979797979797|rev97sha"
: > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"; : > "$T/queue.txt"
RUN
grep -q 'ABANDONED' "$H/logs/blocked-resolver.log" && ok \
  || bad "9e must reach the terminal (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ -e "$HOLD" ] && bad "an abandoned winner may not keep holding other people's PRs" || ok
[ "$(ROWF o/tproj#96 2)" = NEEDS_REBASE ] && ok \
  || bad "its losers go back to the conductor at once (got $(ROWF o/tproj#96 2))"
[ "$(ROWF o/tproj#96 7)" = 'contested released: winner abandoned' ] && ok \
  || bad "and the release says the winner was abandoned (got '$(ROWF o/tproj#96 7)')"
[ "$(grep -c 'contested.*abandoned' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "exactly one ALERTS line for the release (got: $(grep -c 'contested.*abandoned' "$H/logs/ALERTS.log"))"

# ---- 9f. THE HOLD EXPIRED. A TTL release is not a time kill: it unparks the
#          losers and closes nothing.
jq -nc --argjson created "$((NOW - 21601))" \
  '{project:"tproj",repo:"o/tproj",path:"a.txt",winner_key:"TK-95",
    winner_url:"https://github.com/o/tproj/pull/95",
    loser_prs:[{num:96,url:"https://github.com/o/tproj/pull/96",key:"TK-96"},
               {num:97,url:"https://github.com/o/tproj/pull/97",key:"TK-97"}],
    loser_tickets:[],created:$created,ttl:21600,why:"fixture"}' > "$HOLD"
ROWS "o/tproj#95|WAIT_CI|rebased|$U95|$(osha ticket/TK-95)|abc123" \
     "o/tproj#96|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|BLOCKED_HUMAN|contested:a.txt (winner TK-95)|$U97|9797979797979797979797979797979797979797|rev97sha"
: > "$H/logs/ALERTS.log"; : > "$T/closed.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -e "$HOLD" ] && bad "a hold past its ttl must not stay in the store" || ok
[ "$(ROWF o/tproj#96 2)" = NEEDS_REBASE ] && ok \
  || bad "an expired hold UNPARKS its losers (got $(ROWF o/tproj#96 2))"
[ "$(grep -c 'expired after 21600s' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "an expiry pages exactly once, naming the window (got: $(cat "$H/logs/ALERTS.log"))"
[ -s "$T/closed.txt" ] && bad "NO TIME KILLS: an expiry may never close a PR" || ok

# ---- 9g. A MALFORMED HOLD IS EVIDENCE, NOT A CRASH. It is not live (so it
#          holds nobody), it is left in place, and it pages nobody.
printf 'not json\n' > "$HOLD"
ROWS "o/tproj#96|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#95|WAIT_CI|rebased|$U95|$(osha ticket/TK-95)|abc123"
printf 'ticket/TK-96\n' > "$T/prbranch"
printf '9696969696969696969696969696969696969696\n' > "$T/prhead"
: > "$H/logs/ALERTS.log"; : > "$H/logs/blocked-resolver.log"; : > "$T/closed.txt"; : > "$T/queue.txt"
RUN
[ -e "$HOLD" ] && ok || bad "a malformed hold is evidence of a bad write — this lane never deletes it"
grep -q 'malformed' "$H/logs/blocked-resolver.log" && ok \
  || bad "and it says so every tick (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q contested "$H/logs/ALERTS.log" \
  && bad "a malformed hold must not page — the sweep leaves it alone (got: $(grep contested "$H/logs/ALERTS.log"))" || ok
grep -q 'held: contested' "$H/logs/blocked-resolver.log" \
  && bad "a malformed hold holds NOBODY — #96 must take its own ladder" || ok
rm -f "$HOLD"

# ---- 9h. THE PARSER AND THE RECURRENCE RULE, driven as the pure functions they
#          are. These decide whether other people's PRs get parked, so the
#          negatives are the point.
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the record functions moved out of the driver into bin/lib/br/record.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
: > "$T/pure.sh"
for fn in br_paths_of_reason br_recurring_paths br_conflict_note br_json_edit \
          br_file br_load br_save br_num br_shape br_fix_cap br_rebuild_cap \
          br_note_conflict_lines; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/pure.sh"
done
mkdir -p "$T/purestate/tproj"
pure() { bash -c '
  ST="'"$T"'/purestate"
  STAMP() { printf "2026-09-17 00:00:00Z\n"; }
  . "'"$T"'/pure.sh"
  "$@"' _ "$@"; }
[ "$(pure br_paths_of_reason 'conflict-unresolvable: CONFLICT (content): a.txt')" = 'a.txt' ] && ok \
  || bad "the legacy reason parses to a.txt and nothing else (got '$(pure br_paths_of_reason 'conflict-unresolvable: CONFLICT (content): a.txt')')"
[ "$(pure br_paths_of_reason 'conflict-unresolvable: src/a.ts docs/x.md' | tr '\n' ' ')" = 'docs/x.md src/a.ts ' ] && ok \
  || bad "the modern reason parses to every path it names (got '$(pure br_paths_of_reason 'conflict-unresolvable: src/a.ts docs/x.md' | tr '\n' ' ')')"
[ -z "$(pure br_paths_of_reason 'conflict-unresolvable: Auto-merging Merge conflict in CONFLICT (content):')" ] && ok \
  || bad "CONFLICT, (content):, Merge, in and Auto-merging are noise, never paths (got '$(pure br_paths_of_reason 'conflict-unresolvable: Auto-merging Merge conflict in CONFLICT (content):')')"
CJ='{"conflicts":[{"pr":95,"head":"H1","paths":["src/a.ts"]}]}'
[ -z "$(pure br_recurring_paths "$CJ" 95 H1 'src/a.ts')" ] && ok \
  || bad "THE SAME (pr, head) RE-OFFERED IS ONE OCCURRENCE — a park read twice must never buy a hold"
[ "$(pure br_recurring_paths "$CJ" 95 H2 'src/a.ts')" = 'src/a.ts' ] && ok \
  || bad "a new HEAD of the same PR is a recurrence (got '$(pure br_recurring_paths "$CJ" 95 H2 'src/a.ts')')"
[ "$(pure br_recurring_paths "$CJ" 96 H1 'src/a.ts')" = 'src/a.ts' ] && ok \
  || bad "and so is the same path on a rebuilt PR (got '$(pure br_recurring_paths "$CJ" 96 H1 'src/a.ts')')"
[ -z "$(pure br_recurring_paths "$CJ" 95 H2 'src/a.tsx')" ] && ok \
  || bad "src/a.ts and src/a.tsx are different files — the match is exact"
[ -z "$(pure br_recurring_paths '{}' 95 H2 'src/a.ts')" ] && ok \
  || bad "a ticket with no memory has nothing to recur"
rm -f "$T/purestate/tproj/CK.json"
pure br_conflict_note tproj CK 95 H1 'a.txt'
pure br_conflict_note tproj CK 95 H1 'a.txt'
[ "$(jq -r '.conflicts|length' "$T/purestate/tproj/CK.json")" = 1 ] && ok \
  || bad "one (pr, head) is appended once however often it is offered (got $(jq -c '.conflicts' "$T/purestate/tproj/CK.json"))"
pure br_conflict_note tproj CK 95 H2 'a.txt'
[ "$(jq -r '.conflicts|length' "$T/purestate/tproj/CK.json")" = 2 ] && ok \
  || bad "a different head is a second occurrence (got $(jq -c '.conflicts' "$T/purestate/tproj/CK.json"))"
pure br_conflict_note tproj CK '' H3 'a.txt'
pure br_conflict_note tproj CK 96 - 'a.txt'
pure br_conflict_note tproj CK 96 H3 ''
[ "$(jq -r '.conflicts|length' "$T/purestate/tproj/CK.json")" = 2 ] && ok \
  || bad "a note with no pr, no head or no path is not an occurrence (got $(jq -c '.conflicts' "$T/purestate/tproj/CK.json"))"

# ---- 9i. TWO PATHS RECUR AT ONCE, AND EACH HOLD GETS ITS OWN COMPETITORS
#          (review round 1, finding 3). The first cut computed the loser set for
#          the FIRST recurring path and stamped it onto every hold it wrote, so
#          a sibling touching only the SECOND path was named by no hold, parked
#          by nobody and raced the winner exactly as before — while the second
#          path's hold parked PRs that never touch it. One open-PR list call
#          still covers the whole hold creation; what is per-path is the file
#          match, which is already cached per (PR, head).
printf 'ticket/TK-70\n' > "$T/prbranch"; osha ticket/TK-70 > "$T/prhead"
U70=https://github.com/o/tproj/pull/70
H70=$(osha ticket/TK-70)
# #96 touches a.txt and nothing else; #97 touches b.txt and nothing else. The
# winner's own PR (#95) and its rebuild (#100) touch neither, so the only thing
# that can put a PR in a hold is the path that hold is about.
printf 'a.txt\n'       > "$T/prfiles-96"
printf 'b.txt\n'       > "$T/prfiles-97"
printf 'src/other.ts\n' > "$T/prfiles-95"
printf 'src/other.ts\n' > "$T/prfiles-100"
# and one planned ticket per path, so the ticket side is per-path too.
mkdir -p "$H/plans/tproj-TK-70y"
printf 'SOURCE: tier1\nb.txt\n' > "$H/plans/tproj-TK-70y/planned-files.txt"
# The memory: ONE earlier occurrence, on a different head, naming both paths.
# That is what makes this tick's park a recurrence on a.txt AND b.txt.
jq -nc --arg h "$H70" '{project:"tproj",rkey:"tproj-TK-70",mechanicals:1,fixrounds:1,
    rebuilds:0,conflict_lines:500,outcome:"",attempts:[],
    conflicts:[{pr:70,head:"7070707070707070707070707070707070707070",paths:["a.txt","b.txt"]}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-70.json"
printf '500\t%s\ta.txt b.txt\n' "$H70" > "$H/state/merge-conductor/conflict-size/o_tproj_70"
touch "$T/agent-resolves"
# mc_pr_files caches per (PR, head) and §9a already bought #96's and #97's lists
# at these same heads — so the cache is dropped, or this section would be
# asserting on §9a's fixture instead of its own.
scratch_rm "$H/state/merge-conductor/pr-files"
ROWS "o/tproj#70|BLOCKED_HUMAN|conflict-unresolvable: a.txt b.txt|$U70|$H70|$H70" \
     "o/tproj#96|NEEDS_REBASE|dirty|$U96|9696969696969696969696969696969696969696|rev96sha" \
     "o/tproj#97|NEEDS_REBASE|dirty|$U97|9797979797979797979797979797979797979797|rev97sha"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$H/logs/blocked-resolver.log"
: > "$H/logs/ALERTS.log"
RUN
HOLDA=$(HOLDF a.txt); HOLDB=$(HOLDF b.txt)
[ -s "$HOLDA" ] && [ -s "$HOLDB" ] && ok \
  || bad "two recurring paths are two holds (a.txt: $([ -s "$HOLDA" ] && echo yes || echo no), b.txt: $([ -s "$HOLDB" ] && echo yes || echo no))"
[ "$(jq -c '[.loser_prs[].num]|sort' "$HOLDA" 2>/dev/null)" = '[96]' ] && ok \
  || bad "the a.txt hold names the PRs that touch a.txt (got $(jq -c '[.loser_prs[].num]' "$HOLDA" 2>/dev/null))"
[ "$(jq -c '[.loser_prs[].num]|sort' "$HOLDB" 2>/dev/null)" = '[97]' ] && ok \
  || bad "THE BUG: the b.txt hold must name b.txt's own competitors, not the ones the FIRST path computed (got $(jq -c '[.loser_prs[].num]' "$HOLDB" 2>/dev/null))"
[ "$(jq -c '.loser_tickets' "$HOLDA" 2>/dev/null)" = '["TK-95","TK-97x"]' ] && ok \
  || bad "the planned tickets are per path too — a.txt's are the lists that NAME a.txt (got $(jq -c '.loser_tickets' "$HOLDA" 2>/dev/null))"
[ "$(jq -c '.loser_tickets' "$HOLDB" 2>/dev/null)" = '["TK-70y"]' ] && ok \
  || bad "and b.txt's are the lists that name b.txt (got $(jq -c '.loser_tickets' "$HOLDB" 2>/dev/null))"
[ "$(ROWF o/tproj#97 2)" = BLOCKED_HUMAN ] && ok \
  || bad "THE BUG's cost: a sibling that only touches the SECOND path must be parked, not left racing the winner (got $(ROWF o/tproj#97 2))"
[ "$(ROWF o/tproj#97 7)" = 'contested:b.txt (winner TK-70)' ] && ok \
  || bad "and its park names the path IT conflicts on (got '$(ROWF o/tproj#97 7)')"
[ "$(ROWF o/tproj#96 7)" = 'contested:a.txt (winner TK-70)' ] && ok \
  || bad "while #96 is parked on a.txt (got '$(ROWF o/tproj#96 7)')"
[ "$(STATEJSON tproj-TK-70 | jq -c '.contested.paths')" = '["a.txt","b.txt"]' ] && ok \
  || bad "the ticket is marked contested on both paths (got $(STATEJSON tproj-TK-70 | jq -c '.contested'))"
[ "$(STATEJSON tproj-TK-70 | jq -r '.fixround_bonus')" = 1 ] && ok \
  || bad "two holds are still ONE bonus round (got $(STATEJSON tproj-TK-70 | jq -r '.fixround_bonus // "absent"'))"
[ -s "$T/queue.txt" ] && bad "a contested park must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok
[ "$(grep -c 'pulls?state=open' "$T/gh.txt")" = 1 ] && ok \
  || bad "TWO holds still cost ONE open-PR list call — the list is hoisted, only the file match is per path (got $(grep -c 'pulls?state=open' "$T/gh.txt"))"
# and the store is left as this section found it — including mc_pr_files' own
# per-(PR, head) cache, which would otherwise answer §10's scan with the file
# lists this section wrote.
rm -f "$HOLDA" "$HOLDB" "$T/prfiles-96" "$T/prfiles-97" "$T/prfiles-95" "$T/prfiles-100"
scratch_rm "$H/plans/tproj-TK-70y"
scratch_rm "$H/state/merge-conductor/pr-files"

# ============================================================================
# 10. TWO LADDER SHAPES (BH-579): a SMALL conflict is worth a second fix round
#     and is not worth three rebuilds; an unmeasured one keeps today's ladder.
# ============================================================================
# ---- 10a. the shape table, pure.
[ "$(pure br_shape '{}')" = large ] && ok || bad "an UNMEASURED conflict is large — today's ladder, never a guess at small"
[ "$(pure br_shape '{"conflict_lines":300}')" = small ] && ok || bad "300 lines is small (the threshold is inclusive)"
[ "$(pure br_shape '{"conflict_lines":301}')" = large ] && ok || bad "301 lines is large"
[ "$(pure br_shape '{"conflict_lines":"x"}')" = large ] && ok || bad "an unparseable measurement is large, never 0"
# A MEASURED 0 IS UNKNOWN, NOT TINY. A delete/modify conflict leaves no
# `<<<<<<<` markers, so mc_conflict_lines honestly answers 0 over a tree that
# really is conflicted (tests/contested-store-test.sh §1 proves that on a real
# UD tree). Reading that 0 as "a nought-line conflict" hands a ticket whose
# sibling deleted or renamed its file the SMALL ladder — one rebuild instead of
# three, then ABANDONED — and `.conflict_lines` is a MAX, so the same conflict
# can never raise it later.
[ "$(pure br_shape '{"conflict_lines":0}')" = large ] && ok \
  || bad "a measured 0 (a delete/modify conflict has no markers) is UNKNOWN — the large ladder"
[ "$(pure br_fix_cap '{"conflict_lines":0}')" = 1 ] && ok \
  || bad "so it keeps the large ticket's one fix round (got $(pure br_fix_cap '{"conflict_lines":0}'))"
[ "$(pure br_rebuild_cap '{"conflict_lines":0}')" = 3 ] && ok \
  || bad "and its three rebuilds (got $(pure br_rebuild_cap '{"conflict_lines":0}'))"
[ "$(pure br_fix_cap '{}')" = 1 ] && ok || bad "a large ticket keeps one fix round (got $(pure br_fix_cap '{}'))"
[ "$(pure br_fix_cap '{"conflict_lines":300}')" = 2 ] && ok || bad "a small one gets two (got $(pure br_fix_cap '{"conflict_lines":300}'))"
[ "$(pure br_fix_cap '{"conflict_lines":5,"fixround_bonus":1}')" = 3 ] && ok \
  || bad "and the contested bonus rides on top (got $(pure br_fix_cap '{"conflict_lines":5,"fixround_bonus":1}'))"
[ "$(pure br_fix_cap '{"fixround_bonus":1}')" = 2 ] && ok \
  || bad "the bonus rides on the large cap too (got $(pure br_fix_cap '{"fixround_bonus":1}'))"
[ "$(pure br_rebuild_cap '{}')" = 3 ] && ok || bad "a large ticket keeps three rebuilds"
[ "$(pure br_rebuild_cap '{"conflict_lines":5}')" = 1 ] && ok \
  || bad "a small conflict is not worth three rebuilds (got $(pure br_rebuild_cap '{"conflict_lines":5}'))"
[ "$(MAX_FIXROUNDS_SMALL=3 pure br_fix_cap '{"conflict_lines":5}')" = 3 ] && ok \
  || bad "every cap here is a knob read at call time, not a constant"
# AND A 0 IS NEVER RECORDED AS A MEASUREMENT AT ALL. The sidecar of a
# delete/modify conflict carries 0, and a record that carries `conflict_lines:0`
# reads to a human as "measured, tiny" — it is neither.
rm -f "$T/purestate/tproj/ZK.json"
pure br_note_conflict_lines tproj ZK 0
[ "$(pure br_load tproj ZK | jq -r '.conflict_lines // "absent"')" = absent ] && ok \
  || bad "a 0 is the ABSENCE of a measurement and must not be written (got $(pure br_load tproj ZK | jq -c .))"
pure br_note_conflict_lines tproj ZK 12
[ "$(pure br_load tproj ZK | jq -r '.conflict_lines')" = 12 ] && ok \
  || bad "a real measurement still lands (got $(pure br_load tproj ZK | jq -c .))"
pure br_note_conflict_lines tproj ZK 0
[ "$(pure br_load tproj ZK | jq -r '.conflict_lines')" = 12 ] && ok \
  || bad "and a later 0 may not lower it either (got $(pure br_load tproj ZK | jq -c .))"

# ---- 10b. THE SMALL LADDER END TO END. A failed round with rounds REMAINING
#           ends the tick and keeps its branch; with none remaining it cascades
#           exactly as the large one always has.
rm -f "$T/agent-resolves"
scratch_rm "$H/plans/tproj-TK-95"; scratch_rm "$H/plans/tproj-TK-97x"; scratch_rm "$H/plans/tproj-TK-97y"
printf '[]\n' > "$T/openprs"
U98=https://github.com/o/tproj/pull/98
printf 'ticket/TK-98\n' > "$T/prbranch"; osha ticket/TK-98 > "$T/prhead"
printf '50\t%s\ta.txt\n' "$(osha ticket/TK-98)" > "$H/state/merge-conductor/conflict-size/o_tproj_98"
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
ROWS "o/tproj#98|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U98|$(osha ticket/TK-98)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'fix round 1 of 2 did not land — fix round 2 next tick' "$H/logs/blocked-resolver.log" && ok \
  || bad "a small conflict's first failed round must END THE TICK, not cascade (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && bad "with a round still owed, nothing may be closed (closed: $(cat "$T/closed.txt"))" || ok
[ -s "$T/queue.txt" ] && bad "with a round still owed, nothing may be enqueued (got: $(cat "$T/queue.txt"))" || ok
git -C "$T/repos/tproj" rev-parse --verify -q brfix/tproj-TK-98 >/dev/null 2>&1 && ok \
  || bad "the checkpoint branch stays for the round that is still owed — deleting it buys the same tokens twice"
[ "$(STATEJSON tproj-TK-98 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv')" = "1,1,0" ] && ok \
  || bad "tick 1 spends the mechanical rung and one round, and nothing else (got $(STATEJSON tproj-TK-98 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'))"
# tick 2: the second round runs, fails, and NOW the ladder cascades.
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
SEQ98=$(grep -o 'rung [123]' "$H/logs/blocked-resolver.log" | tr -d '\n' | tr -s ' ')
[ "$SEQ98" = "rung 2rung 3" ] && ok \
  || bad "tick 2 is the second round and then the rebuild (got '$SEQ98')"
grep -q 'pulls/98' "$T/closed.txt" && ok || bad "the spent ladder must close the stale PR (closed: $(cat "$T/closed.txt"))"
grep -q '^tproj TK-98 98 fly 0 ' "$T/queue.txt" && ok || bad "and enqueue it fresh (got: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj-TK-98 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "2,1" ] && ok \
  || bad "two rounds and one rebuild (got $(STATEJSON tproj-TK-98 | jq -r '[.fixrounds,.rebuilds]|@csv'))"
# tick 3: the rebuild the small shape allows is already spent, so the ticket
# reaches its terminal after ONE rebuild instead of three.
printf 'ticket/TK-98-r2\n' > "$T/prbranch"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$T/prhead"
ROWS "o/tproj#99|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|https://github.com/o/tproj/pull/99|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
RUN
grep -q 'no open PR or planned ticket touches it — nothing to hold' "$H/logs/blocked-resolver.log" && ok \
  || bad "a recurrence with NOBODY to hold must say so and take today's rung (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ "$(HOLDN)" = 0 ] && ok || bad "and it must write no hold at all (an empty hold protects nobody)"
grep -q 'ABANDONED — rebuilt fresh 1 times' "$H/logs/blocked-resolver.log" && ok \
  || bad "a small ticket's ladder ends after ONE rebuild (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-98 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "and the terminal is recorded (got '$(STATEJSON tproj-TK-98 | jq -r .outcome)')"

# ---- 10c. THE LARGE LADDER IS BYTE-FOR-BYTE WHAT IT WAS: one tick, all three
#           rungs, and the rebuild cap still 3.
U101=https://github.com/o/tproj/pull/101
printf 'ticket/TK-101\n' > "$T/prbranch"; osha ticket/TK-101 > "$T/prhead"
printf '500\t%s\ta.txt\n' "$(osha ticket/TK-101)" > "$H/state/merge-conductor/conflict-size/o_tproj_101"
ROWS "o/tproj#101|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U101|$(osha ticket/TK-101)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
SEQ101=$(grep -o 'rung [123]' "$H/logs/blocked-resolver.log" | tr -d '\n' | tr -s ' ')
[ "$SEQ101" = "rung 1rung 2rung 3" ] && ok \
  || bad "a large conflict still walks all three rungs in one tick (got '$SEQ101')"
[ "$(STATEJSON tproj-TK-101 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv')" = "1,1,1" ] && ok \
  || bad "one of each rung (got $(STATEJSON tproj-TK-101 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'))"
[ "$(STATEJSON tproj-TK-101 | jq -r .outcome)" = ABANDONED ] \
  && bad "one failed large ladder is not an abandonment — its rebuild cap is still 3" || ok

# ---- 10d. THE SMALL FIX CAP IS A KNOB, read where the operator sets it.
U102=https://github.com/o/tproj/pull/102
printf 'ticket/TK-102\n' > "$T/prbranch"; osha ticket/TK-102 > "$T/prhead"
printf '50\t%s\ta.txt\n' "$(osha ticket/TK-102)" > "$H/state/merge-conductor/conflict-size/o_tproj_102"
ROWS "o/tproj#102|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U102|$(osha ticket/TK-102)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
BRENV=(BR_MAX_FIXROUNDS_SMALL=3)
RUN
BRENV=()
grep -q 'fix round 1 of 3 did not land — fix round 2 next tick' "$H/logs/blocked-resolver.log" && ok \
  || bad "BR_MAX_FIXROUNDS_SMALL must reach the rung that runs, not just the one that is chosen (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && bad "three rounds bought means nothing is closed after the first (closed: $(cat "$T/closed.txt"))" || ok

# ---- 10e. A HOLD THAT WILL NOT WRITE CHANGES NOTHING. The store is read-only,
#           so the recurrence is real and the hold is impossible: today's rung,
#           one log line, and nothing recorded as contested.
printf '[]\n' > "$T/openprs"
mkdir -p "$H/plans/tproj-TK-97x"
printf 'SOURCE: tier1\na.txt\n' > "$H/plans/tproj-TK-97x/planned-files.txt"
printf 'ticket/TK-101\n' > "$T/prbranch"; osha ticket/TK-101 > "$T/prhead"
jq -nc --arg h "$(osha ticket/TK-101)" \
  '{project:"tproj",rkey:"tproj-TK-101",mechanicals:1,fixrounds:1,rebuilds:0,conflict_lines:500,
    outcome:"",attempts:[],conflicts:[{at:"x",pr:101,head:"OLDHEAD",paths:["a.txt"]}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-101.json"
ROWS "o/tproj#101|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U101|$(osha ticket/TK-101)|abc123"
# A FILE where the project's hold directory belongs: `mkdir -p` cannot make it,
# so the write refuses for a reason no permission bit can hide from root.
scratch_rm "$H/state/contested/tproj"; : > "$H/state/contested/tproj"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
rm -f "$H/state/contested/tproj"; mkdir -p "$H/state/contested/tproj"
grep -q 'contested hold could not be written — rebuilding as before' "$H/logs/blocked-resolver.log" && ok \
  || bad "a hold that would not write must say so (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ "$(HOLDN)" = 0 ] && ok || bad "and leave no half-written hold behind (got $(HOLDN))"
[ "$(STATEJSON tproj-TK-101 | jq -r '.contested // "absent"')" = absent ] && ok \
  || bad "a failed hold write records nothing as contested (got $(STATEJSON tproj-TK-101 | jq -c '.contested'))"
[ "$(STATEJSON tproj-TK-101 | jq -r '.fixround_bonus // 0')" = 0 ] && ok \
  || bad "and grants no bonus round for a hold that does not exist"
grep -q 'pulls/101' "$T/closed.txt" && ok \
  || bad "it takes today's rung instead — the rebuild (closed: $(cat "$T/closed.txt"))"

# ---- 10f. THE SCAN CAP IS DECLARED, NOT SILENT, and a loser with no conductor
#           row is left alone — this lane invents no rows.
cat > "$T/openprs" <<'EOF'
[
 {"number":95,"html_url":"https://github.com/o/tproj/pull/95","user":{"login":"operator","type":"User"},"state":"open","merged_at":null,"head":{"sha":"9595959595959595959595959595959595959595","ref":"ticket/TK-95"}},
 {"number":96,"html_url":"https://github.com/o/tproj/pull/96","user":{"login":"operator","type":"User"},"state":"open","merged_at":null,"head":{"sha":"9696969696969696969696969696969696969696","ref":"ticket/TK-96"}},
 {"number":97,"html_url":"https://github.com/o/tproj/pull/97","user":{"login":"app/cromford","type":"Bot"},"state":"open","merged_at":null,"head":{"sha":"9797979797979797979797979797979797979797","ref":"ticket/TK-97"}},
 {"number":200,"html_url":"https://github.com/o/tproj/pull/200","user":{"login":"somebody-else","type":"User"},"state":"open","merged_at":null,"head":{"sha":"2002002002002002002002002002002002002000","ref":"feature/theirs"}}
]
EOF
jq -nc '{project:"tproj",rkey:"tproj-TK-101",mechanicals:1,fixrounds:1,rebuilds:0,conflict_lines:500,
         outcome:"",attempts:[],conflicts:[{at:"x",pr:101,head:"OLDHEAD",paths:["a.txt"]}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-101.json"
ROWS "o/tproj#101|BLOCKED_HUMAN|conflict-unresolvable: CONFLICT (content): a.txt|$U101|$(osha ticket/TK-101)|abc123"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
BRENV=(CONTESTED_PR_SCAN_MAX=1)
RUN
BRENV=()
grep -q 'contested scan capped at 1 of 3' "$H/logs/blocked-resolver.log" && ok \
  || bad "a capped scan must say how much of the list it read (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
grep -qE 'were not read and are NOT parked' "$H/logs/blocked-resolver.log" && ok \
  || bad "and which PRs it therefore did NOT park (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ "$(jq -c '[.loser_prs[].num]' "$HOLD" 2>/dev/null)" = '[95]' ] && ok \
  || bad "only the PRs actually read may be held (got $(jq -c '[.loser_prs[].num]' "$HOLD" 2>/dev/null))"
jq -r .why "$HOLD" 2>/dev/null | grep -q 'scan capped at 1 of 3' && ok \
  || bad "the hold itself must carry the cap, or a reader of the store cannot tell it is partial (got '$(jq -r .why "$HOLD" 2>/dev/null)')"
grep -q 'loser #95 has no conductor row — left to the conductor' "$H/logs/blocked-resolver.log" && ok \
  || bad "a loser with no row is reported (log: $(tail -6 "$H/logs/blocked-resolver.log"))"
[ -z "$(ROWF o/tproj#95 2)" ] && ok \
  || bad "and no row is INVENTED for it (got '$(ROWF o/tproj#95 2)')"

# ---- 8f-8. NO TIME KILLS, as a property of the source (the operator, 2026-09-16).
#            br_close_pr's callers are ENUMERATED BY NAME and none may be
#            reached from an age comparison: the audit is code, so it cannot rot
#            into prose.
# Every caller TESTS the close (#783) — `if ! br_close_pr …` — because a close
# GitHub refused defers the rung instead of being assumed, so the pattern allows
# the `if !` in front of the call and nothing else.
#
# THREE, NOT TWO, SINCE BH-1460, and the pin is deliberately WIDENED rather than
# loosened. Splitting the hold vocabulary gave the resolver a third close: a
# ticket whose thread says ABANDON has its PR closed by br_hold_abandon. That is
# a new close path in the lane this pin exists to police, so the pin now names
# the three functions instead of counting to two — a fourth close, or a close
# that moves into a function nobody named, is still red. A bare count would have
# let the next one in silently.
CALLERS=$(grep -nE '^\s*(if ! )?br_close_pr ' "$DIR/bin/blocked-resolver.sh" | grep -cv '^[0-9]*:\s*#' || true)
[ "$CALLERS" = 3 ] && ok \
  || bad "br_close_pr must have exactly the three documented callers (rebuild-fresh, ladder abandon, ticket ABANDON) — got $CALLERS: $(grep -nE '^\s*(if ! )?br_close_pr ' "$DIR/bin/blocked-resolver.sh")"
# ...and they are those three BY NAME: the enclosing function of every call.
CALLER_FNS=$(awk '/^[a-z_]+\(\) \{/ { fn=$1; sub(/\(\)$/,"",fn) }
                  /^[[:space:]]*(if ! )?br_close_pr / && $0 !~ /^[[:space:]]*#/ { print fn }' \
             "$DIR/bin/blocked-resolver.sh" | sort | tr '\n' ' ')
[ "$CALLER_FNS" = "br_abandon br_hold_abandon br_rebuild_fresh " ] && ok \
  || bad "the three closers must be br_rebuild_fresh (rebuild-fresh), br_abandon (ladder exhausted) and br_hold_abandon (the ticket says ABANDON) — got '$CALLER_FNS'"
# No close/abandon/rebuild call sits in a function that compares an age. The
# resolver holds no age comparison at all outside the hand-off recovery window
# (BR_HANDOFF_MAX_AGE_SECS), which only ever ADDS a park to the drain.
# br_hold_abandon is named explicitly: `br_abandon ` does not match it, so the
# third closer would have walked past this audit unexamined (BH-1460).
AGED=$(grep -nE 'br_close_pr|br_abandon |br_hold_abandon |br_rebuild_fresh ' "$DIR/bin/blocked-resolver.sh" \
       | grep -vE '^[0-9]+:\s*#' | grep -iE 'age|older|minutes|elapsed|since' || true)
[ -z "$AGED" ] && ok || bad "a close/abandon/rebuild must never be guarded by an age: $AGED"
# `gh pr close` specifically: bin/merge-sweep.sh does close the ISSUE a PR was
# built for, and that is the event `Closes #n` would have fired anyway — it runs
# only after the merge lands, off the merged PR's own build key, and never off a
# clock. A PR, though, is closed in exactly one lane.
for f in merge-conductor.sh merge-sweep.sh jobs-watchdog.sh pipeline-health.sh unblocked-children.sh; do
  HITS=$(grep -nE 'gh pr close' "$DIR/bin/$f" 2>/dev/null | grep -vE '^[0-9]+:\s*#' || true)
  [ -z "$HITS" ] && ok || bad "bin/$f must not close a PR at all — closes belong to the resolver's event ladder: $HITS"
done

echo "br-contested-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
