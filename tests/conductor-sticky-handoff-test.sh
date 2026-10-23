#!/bin/bash
# tests/conductor-sticky-handoff-test.sh — a hand-off to bin/blocked-resolver.sh
# stays parked until something REAL changes, and a hand-off whose row already
# moved on is recovered by the resolver rather than lost.
#
# THE BUG THIS PINS (2026-09-14, hub logs). project-5 #759 went
# `REBASING -> BLOCKED_HUMAN reason=conflict-unresolvable` at 16:30:30Z with the
# `BLOCKED_AGENT … handed to bin/blocked-resolver.sh` line beside it. Twenty-two
# seconds later the next tick's DIRTY branch re-classified it:
# `BLOCKED_HUMAN -> NEEDS_REBASE reason=mergeState DIRTY`. From there, 25 ticks
# in 45 minutes logged `MERGE_TREE conflict on 382730a5 … GitHub is right,
# rebasing` and nothing else — the rebase was capped, the resolver reads rows in
# BLOCKED_HUMAN so it could not see the PR at all, and the one-alert-per-PR-per-
# state rule had already fired. #749 and project-7#438 are the same shape.
#
# WHY DRIVEN AND NOT GREPPED. Both halves are claims about control flow across
# ticks: that the SECOND and THIRD tick over a parked PR do nothing, and that the
# resolver's candidate list contains a PR whose row says WAIT_CI. A grep for
# `mc_handoff_sticky` in the source passes on a branch that is never reached.
# Run from anywhere: tests/conductor-sticky-handoff-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin" "$T/repos"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/jobs-client.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh lane-alert.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# git: every rebase-side call answers, and `merge-tree` CONFLICTS — this PR is
# exactly the #759 shape, a branch that cannot be merged into main.
cat > "$T/fakebin/git" <<'EOF'
#!/bin/bash
case "$*" in
  *merge-tree*) echo "CONFLICT (content): Merge conflict in tests/static-guards.txt"; exit 1 ;;
  *merge-base*) echo base0000base0000 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

export HARNESS="$H"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$H/bin/lib/merge-conductor-lib.sh"; mc_init
KEY=example-org/demo-os#759
URL=https://github.com/example-org/demo-os/pull/759
H1=382730a5382730a5382730a5382730a5382730a5
H2=beef0002beef0002beef0002beef0002beef0002
# One head per case from section 9 on: the release label works once per (PR,
# head), so a case that re-used a head would be testing the marker, not itself.
H3=cafe0003cafe0003cafe0003cafe0003cafe0003
H4=dead0004dead0004dead0004dead0004dead0004
H5=face0005face0005face0005face0005face0005
H6=feed0006feed0006feed0006feed0006feed0006
MCLOG="$H/logs/merge-conductor.log"

# The PR: approved at its own head, green CI, and DIRTY — so the classifier's
# NEEDS_REBASE arm (the one that re-flipped #759) is live on every tick.
REC="$H/builds/demo-os-TK-759-202609140001"; mkdir -p "$REC"
echo "PR_CREATED $URL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
mk_gh() { # mk_gh <head> [state] [labels-csv]
  # The labels ride the `pr list` row exactly as GitHub returns them — a JSON
  # array of objects — because that is what the tick's jq turns into the tsv
  # field the release label is read from. A hand-written CSV fed to the helper
  # would prove nothing about the parse.
  local LBLJSON="[]" one parts=()
  if [ -n "${3:-}" ]; then
    local IFS=','
    read -r -a parts <<<"$3"
    LBLJSON=""
    for one in ${parts[@]+"${parts[@]}"}; do LBLJSON="$LBLJSON{\"name\":\"$one\"},"; done
    LBLJSON="[${LBLJSON%,}]"
  fi
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  # bin/blocked-resolver.sh decides over REST (#783): one PR object carries the
  # state, the head and the branch this fixture used to answer field by field.
  *"-i -X GET"*"/comments"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-i -X GET"*"search/issues"*) printf 'HTTP/2 200\r\n\r\n{"items":[]}' ;;
  *"-i -X GET"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg st "${2:-OPEN}" --arg h "$1" \
      '{state:(if \$st=="OPEN" then "open" else "closed" end),
        merged_at:(if \$st=="MERGED" then "2026-01-01T00:00:00Z" else null end),
        head:{sha:\$h,ref:"ticket/TK-759"},base:{ref:"main"},title:"TK-759: a thing"}' ;;
  # TEST-CHANGE (BH-782): the all-mappable PR lists read REST through
  # bin/lib/gh-rest.sh now -- 'gh api -i -X GET .../pulls?state=...'. A GET is a
  # READ: without this arm it falls to the catch-all below and lands in
  # gh-writes.txt, so every "no GitHub write" assertion fails on a read. The
  # answer is the empty list the 'pr list' arm already gave for this state.
  # NO BACKTICKS IN THIS COMMENT: it lives inside an unquoted <<EOF, so a
  # backtick pair here is a command substitution the harness runs for real at
  # stub-generation time and splices into the stub (BH-782 review r2, round 1).
  # TEST-CHANGE (BH-1585): the OPEN list is a REST page too now, and its rows are
  # the 'pr list' arm below (tests/lib/gh-list-bridge.sh serves them), so this
  # empty answer is narrowed to the closed list it was written for.
  *"-i -X GET"*"/pulls?state=closed"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  # The OPEN page has no REST arm of its own: answering nothing hands it to the
  # bridge, which serves the 'pr list' rows below (not a write, so not logged as one).
  *"-i -X GET"*"/pulls?state=open"*) echo "" ;;
  # BH-1586: the CI read is gh_rest too (the raw arm below answered it before),
  # in the real REST shape: one completed, successful workflow run.
  *"-i -X GET"*"actions/runs?head_sha="*)
    printf 'HTTP/2 200\r\n\r\n{"total_count":1,"workflow_runs":[{"id":1,"name":"ci","status":"completed","conclusion":"success","run_started_at":"2026-01-01T00:00:00Z","run_attempt":1}]}' ;;
  # And so are the queue-provider policy reads (rulesets, .mergify.yml): a GET
  # is a READ, never a write. 404 = none, which is what the raw arm's empty
  # answer meant. Only non-GET -i calls below are recorded as writes.
  *"-i -X GET"*) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}' ;;
  *"-i -X "*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; printf 'HTTP/2 200\r\n\r\n{}' ;;
  *"auth token"*) echo faketoken ;;
  *"api -X DELETE"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr close"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/comments.txt" ;;
  *"pr view $URL --json state,headRefOid"*) echo "${2:-OPEN} $1" ;;
  *"pr view"*"--json state"*) echo "${2:-OPEN}" ;;
  *"pr view"*"--json headRefOid"*) echo "$1" ;;
  *"pr view"*"--json headRefName"*) echo "ticket/TK-759" ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr list -R example-org/demo-os --state open"*)
    [ "${2:-OPEN}" = OPEN ] || { echo "[]"; exit 0; }
    cat <<'J'
[{"number":759,"url":"$URL","headRefOid":"$1","headRefName":"ticket/TK-759","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN","labels":$LBLJSON,"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$H" MC_REPOS="$T/repos" MC_MERGE_SETTLE=0 \
             MC_RR_PATH="$T/fakebin:$PATH" "$@" bash "$H/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
           || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$H/state/merge-conductor/pr-state.tsv"; }
sinceof()  { awk -F'\t' -v k="$1" '$1==k {print $3}' "$H/state/merge-conductor/pr-state.tsv"; }
# Lines about THIS PR only, since a mark the caller takes before its ticks.
since_mark() { tail -n "+$(( ${1:-0} + 1 ))" "$MCLOG" 2>/dev/null | grep -F "demo-os#759"; }
mark() { wc -l < "$MCLOG" 2>/dev/null | tr -d ' '; }
park() { # put the PR back in the parked-by-hand-off state at <head>
  awk -F'\t' -v k="$KEY" '$1!=k' "$H/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
  mv -f "$T/rows.tmp" "$H/state/merge-conductor/pr-state.tsv"
  grep -vF "$KEY" "$H/state/merge-conductor/attempts.txt" > "$T/att.tmp" 2>/dev/null
  mv -f "$T/att.tmp" "$H/state/merge-conductor/attempts.txt"
  rm -f "$H/state/merge-conductor/handoff"/* "$H/state/merge-conductor/handoff-released"/* \
        "$H/state/merge-conductor/rebase"/* 2>/dev/null
  mc_transition "$KEY" REBASING "rebasing" "$1" "$1" "$URL" APPROVE DIRTY "$REC" >/dev/null
  mc_transition "$KEY" BLOCKED_HUMAN "conflict-unresolvable: tests/static-guards.txt" "$1" "$1" "$URL" APPROVE DIRTY "$REC" >/dev/null
}
touch "$H/flags/merge-conductor-actions" "$H/flags/merge-conductor-merge"

# ============================================================================
# 1. mc_handoff_owns: the hand-off reasons, and only those
# ============================================================================
for R in "conflict-unresolvable: tests/static-guards.txt" rebase-gate-red queue-ejected-twice \
         "merge-failed-twice: nope" "queue-enqueue-failed-twice: nope" no-verdict head-not-reapproved \
         "orphaned-child: the PR this one is stacked on (ticket/TK-1529) closed without merging"; do
  mc_handoff_owns "$R" && ok || bad "mc_handoff_owns must own the hand-off reason '$R'"
  mc_resolver_owns "$R" && ok || bad "every sticky reason must still be resolver-owned ('$R')"
done
# A park that needs a PERSON, or that the classifier re-derives every tick, must
# NOT be frozen: iron-law clears on an adjudication marker, red-ci-twice on a
# rerun, and the other four were never the resolver's at all.
# `parent-closed` is the one that must stay unfrozen AND unowned: it is the word
# for a tick that could not READ the branch (no checkout, no token, an old git),
# and that clears by itself the moment the next tick can. Its sibling
# `orphaned-child` — the tick DID read the branch and the branch is the problem —
# is both, and is asserted above.
for R in "iron-law (2 hit(s))" red-ci-twice migration-gated verdict-contradiction provenance tightened parent-closed; do
  mc_handoff_owns "$R" && bad "mc_handoff_owns must NOT freeze '$R'" || ok
done
mc_resolver_owns parent-closed \
  && bad "parent-closed must not be resolver-owned either — a fix round on a branch nobody could read is a guess" || ok
[ "$(mc_handoff_id "$KEY")" = example-org_demo-os_759 ] && ok || bad "the hand-off id must be <owner>_<repo>_<num> (got $(mc_handoff_id "$KEY"))"

# ============================================================================
# 2. The park is STICKY: three ticks after a hand-off change nothing
# ============================================================================
mk_gh "$H1"
park "$H1"
[ -s "$(mc_handoff_file "$KEY")" ] && ok || bad "entering BLOCKED_HUMAN on a hand-off reason must record the hand-off"
[ "$(cut -f2 "$(mc_handoff_file "$KEY")")" = "$H1" ] && ok || bad "the hand-off must record the head it parked"
SINCE0=$(sinceof "$KEY"); M=$(mark)
tick; tick; tick
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "3 ticks after a hand-off the row must still be BLOCKED_HUMAN (got $(state_of "$KEY"))"
[ "$(sinceof "$KEY")" = "$SINCE0" ] && ok || bad "a sticky park must not restart its own clock"
grep -q MERGE_TREE <<<"$(since_mark "$M")" && bad "a parked PR must buy NO merge-tree test: $(since_mark "$M" | grep MERGE_TREE | head -1)" || ok
grep -q REBASE_SPAWNED <<<"$(since_mark "$M")" && bad "a parked PR must spawn NO rebase" || ok
grep -q REREVIEW_SPAWNED <<<"$(since_mark "$M")" && bad "a parked PR must buy NO re-review" || ok
grep -q 'NEEDS_REBASE' <<<"$(since_mark "$M")" && bad "a parked PR must never be re-classified: $(since_mark "$M" | grep NEEDS_REBASE | head -1)" || ok
[ -s "$T/gh-writes.txt" ] && bad "a parked PR must take no GitHub write: $(cat "$T/gh-writes.txt")" || ok
# ONE line for the operator, not one per tick.
[ "$(since_mark "$M" | grep -c 'PARKED')" = 1 ] && ok || bad "a sticky park must log exactly once over 3 ticks (got $(since_mark "$M" | grep -c 'PARKED'))"
since_mark "$M" | grep -q 'bin/blocked-resolver.sh owns it' && ok || bad "the one line must name the lane that owns the park"
# ...and again after MC_STICKY_LOG_SECS, so a park that outlives a day is visible
M2=$(mark); tick env MC_STICKY_LOG_SECS=0
[ "$(since_mark "$M2" | grep -c 'PARKED')" = 1 ] && ok || bad "MC_STICKY_LOG_SECS must let the park re-state itself"

# ============================================================================
# 3. Release 1: the head moved (a fix round, or a rebase by hand)
# ============================================================================
mk_gh "$H2"; M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "a head that MOVED must end the park (still $(state_of "$KEY"))"
[ "$(state_of "$KEY")" = HEAD_MOVED ] && ok || bad "after the park ends the PR classifies normally — an unreviewed head is HEAD_MOVED (got $(state_of "$KEY"))"
since_mark "$M" | grep -q 'BLOCKED_HUMAN -> HEAD_MOVED' && ok || bad "the release must show up as an ordinary transition"

# ============================================================================
# 4. Release 2: the resolver's release marker
# ============================================================================
mk_gh "$H1"; park "$H1"; M=$(mark); tick
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "re-parked: the row must be sticky again"
mc_handoff_release "$KEY" blocked-resolver/rebuild-fresh
[ -s "$(mc_handoff_rel_file "$KEY")" ] && ok || bad "mc_handoff_release must write the release marker"
M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "the resolver's release marker must end the park (still $(state_of "$KEY"))"
since_mark "$M" | grep -q MERGE_TREE && ok || bad "a released PR must be tested again like any other"
# A NEW park on the same PR clears the stale release, or the park would never
# take again and the loop would be back.
park "$H1"
[ -e "$(mc_handoff_rel_file "$KEY")" ] && bad "a new hand-off must clear the old release marker" || ok
tick
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "a re-park after a release must be sticky again (got $(state_of "$KEY"))"

# ============================================================================
# 5. MC_STICKY_HANDOFF=0 = exactly today's behaviour
# ============================================================================
mk_gh "$H1"; park "$H1"; M=$(mark)
tick env MC_STICKY_HANDOFF=0
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "MC_STICKY_HANDOFF=0 must not park the row (still $(state_of "$KEY"))"
since_mark "$M" | grep -q 'BLOCKED_HUMAN -> NEEDS_REBASE' && ok || bad "MC_STICKY_HANDOFF=0 must re-classify the parked row, exactly as before"
since_mark "$M" | grep -q MERGE_TREE && ok || bad "MC_STICKY_HANDOFF=0 must run the merge-tree test again"
since_mark "$M" | grep -q REBASE_SPAWNED && ok || bad "MC_STICKY_HANDOFF=0 must spawn the rebase again"
grep -q PARKED <<<"$(since_mark "$M")" && bad "MC_STICKY_HANDOFF=0 must not log the park line either" || ok

# ============================================================================
# 6. The resolver recovers a hand-off whose row was already re-flipped, and
#    never one whose PR merged.
#
#    This is the state the two live PRs are in RIGHT NOW: the row says WAIT_CI /
#    HEAD_MOVED, the hand-off is only in the conductor log, and the old
#    br_from_conductor (rows in BLOCKED_HUMAN, full stop) saw nothing at all.
# ============================================================================
BRLOG="$H/logs/blocked-resolver.log"
: > "$H/state/merge-conductor/pr-state.tsv"; : > "$MCLOG"; : > "$BRLOG"
rm -f "$H/state/merge-conductor/handoff"/* "$H/state/merge-conductor/handoff-released"/* 2>/dev/null
mkdir -p "$H/state/blocked-resolver"
NOW=$(date -u '+%Y-%m-%d %H:%M:%SZ')
# #749: handed off, then re-flipped to WAIT_CI two minutes later (the real shape).
# #438: handed off, then re-flipped to HEAD_MOVED (the real shape).
# TEST-CHANGE (BH-594): a HEAD_MOVED row on the handed-off head is the
# conductor's head-bound re-review of that head in flight, and the resolver now
# WAITS for it (ask 4, the TK-1669 race) instead of recovering it. #439 carries
# the "a recovered hand-off keeps its own rung" half #438 used to: the same
# head-not-reapproved hand-off, re-flipped to WAIT_CI instead.
# #900: handed off and MERGED since — the #304 guard must hold.
# #901: handed off 5 days ago and long re-flipped — past the recovery window.
{
  echo "$NOW example-org/demo-os#749 BLOCKED_AGENT conflict-unresolvable: tests/x.ts — handed to bin/blocked-resolver.sh (fresh rebuild against current main): https://github.com/example-org/demo-os/pull/749"
  echo "$NOW example-org/demo-os#438 BLOCKED_AGENT head-not-reapproved: the moved head was not re-approved, findings posted on the PR — handed to bin/blocked-resolver.sh (agent fix round against those findings): https://github.com/example-org/demo-os/pull/438"
  echo "$NOW example-org/demo-os#439 BLOCKED_AGENT head-not-reapproved: the moved head was not re-approved, findings posted on the PR — handed to bin/blocked-resolver.sh (agent fix round against those findings): https://github.com/example-org/demo-os/pull/439"
  echo "$NOW example-org/demo-os#900 BLOCKED_AGENT conflict-unresolvable: tests/y.ts — handed to bin/blocked-resolver.sh (fresh rebuild against current main): https://github.com/example-org/demo-os/pull/900"
  echo "$(date -u -d '5 days ago' '+%Y-%m-%d %H:%M:%SZ') example-org/demo-os#901 BLOCKED_AGENT conflict-unresolvable: tests/z.ts — handed to bin/blocked-resolver.sh (fresh rebuild against current main): https://github.com/example-org/demo-os/pull/901"
  # The budget line, which is an AGE REPORT on a row that is still parked. It
  # must not be read as a hand-off: the row source already owns that PR.
  echo "$NOW example-org/demo-os#777 120m in BLOCKED_AGENT (iron-law (1 hit(s))) — handed to bin/blocked-resolver.sh, not paged: https://github.com/example-org/demo-os/pull/777"
} >> "$MCLOG"
NS=$(date -u +%s)
{
  printf 'example-org/demo-os#749\tWAIT_CI\t%s\t%s\t%s\t-\tchecks none\thttps://github.com/example-org/demo-os/pull/749\n' "$NS" "$H1" "$H1"
  printf 'example-org/demo-os#438\tHEAD_MOVED\t%s\t%s\t%s\t-\thead moved\thttps://github.com/example-org/demo-os/pull/438\n' "$NS" "$H1" "$H1"
  printf 'example-org/demo-os#439\tWAIT_CI\t%s\t%s\t%s\t-\tchecks none\thttps://github.com/example-org/demo-os/pull/439\n' "$NS" "$H1" "$H1"
  printf 'example-org/demo-os#900\tWAIT_CI\t%s\t%s\t%s\t-\tchecks none\thttps://github.com/example-org/demo-os/pull/900\n' "$NS" "$H1" "$H1"
  printf 'example-org/demo-os#901\tWAIT_CI\t%s\t%s\t%s\t-\tchecks none\thttps://github.com/example-org/demo-os/pull/901\n' "$NS" "$H1" "$H1"
  # Still parked AND still on the head: the ordinary row source owns it, and it
  # must appear exactly once however many times the log mentions it.
  printf 'example-org/demo-os#750\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\tno-verdict\thttps://github.com/example-org/demo-os/pull/750\n' "$NS" "$H1" "$H1"
} >> "$H/state/merge-conductor/pr-state.tsv"
echo "$NOW example-org/demo-os#750 BLOCKED_AGENT no-verdict: — handed to bin/blocked-resolver.sh (one more re-review, then a fresh rebuild): https://github.com/example-org/demo-os/pull/750" >> "$MCLOG"
# gh for the resolver: every PR is OPEN at H1 except #900, which merged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  # The same REST reads (#783): #900 is the MERGED one, everything else is open.
  *"-i -X GET"*"/comments"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-i -X GET"*"search/issues"*) printf 'HTTP/2 200\r\n\r\n{"items":[]}' ;;
  *"-i -X GET"*"/pulls/900"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "$H1" '{state:"closed",merged_at:"2026-01-01T00:00:00Z",head:{sha:\$h,ref:"ticket/TK-749"},base:{ref:"main"},title:"TK-749: a thing"}' ;;
  *"-i -X GET"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg h "$H1" '{state:"open",merged_at:null,head:{sha:\$h,ref:"ticket/TK-749"},base:{ref:"main"},title:"TK-749: a thing"}' ;;
  # TEST-CHANGE (BH-782): the all-mappable PR lists read REST through
  # bin/lib/gh-rest.sh now -- 'gh api -i -X GET .../pulls?state=...'. A GET is a
  # READ: without this arm it falls to the catch-all below and lands in
  # gh-writes.txt, so every "no GitHub write" assertion fails on a read. The
  # answer is the empty list the 'pr list' arm already gave for this state.
  # NO BACKTICKS IN THIS COMMENT: it lives inside an unquoted <<EOF, so a
  # backtick pair here is a command substitution the harness runs for real at
  # stub-generation time and splices into the stub (BH-782 review r2, round 1).
  # TEST-CHANGE (BH-1585): the OPEN list is a REST page too now, and its rows are
  # the 'pr list' arm below (tests/lib/gh-list-bridge.sh serves them), so this
  # empty answer is narrowed to the closed list it was written for.
  *"-i -X GET"*"/pulls?state=closed"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  # The OPEN page has no REST arm of its own: answering nothing hands it to the
  # bridge, which serves the 'pr list' rows below (not a write, so not logged as one).
  *"-i -X GET"*"/pulls?state=open"*) echo "" ;;
  # BH-1586: the CI read is gh_rest too (the raw arm below answered it before),
  # in the real REST shape: one completed, successful workflow run.
  *"-i -X GET"*"actions/runs?head_sha="*)
    printf 'HTTP/2 200\r\n\r\n{"total_count":1,"workflow_runs":[{"id":1,"name":"ci","status":"completed","conclusion":"success","run_started_at":"2026-01-01T00:00:00Z","run_attempt":1}]}' ;;
  # And so are the queue-provider policy reads (rulesets, .mergify.yml): a GET
  # is a READ, never a write. 404 = none, which is what the raw arm's empty
  # answer meant. Only non-GET -i calls below are recorded as writes.
  *"-i -X GET"*) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}' ;;
  *"-i -X "*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; printf 'HTTP/2 200\r\n\r\n{}' ;;
  *"pull/900"*"--json state,headRefOid"*) echo "MERGED $H1" ;;
  *"pull/900"*"--json state"*) echo MERGED ;;
  *"--json state,headRefOid"*) echo "OPEN $H1" ;;
  *"--json state"*) echo OPEN ;;
  *"--json headRefName"*) echo "ticket/TK-749" ;;
  *"--json headRefOid"*) echo "$H1" ;;
  *"pr list"*"--state merged"*) echo "" ;;
  *"pr close"*|*"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The candidate list is driven through the script's own discovery, in observe
# mode: what is under test is WHICH PRs this lane can see, not what it then buys.
touch "$H/flags/blocked-resolver-observe"
( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
    bash "$H/bin/blocked-resolver.sh" demo-os >/dev/null 2>"$T/br.err" ) || { echo "resolver rc=$?"; cat "$T/br.err"; }
cand() { grep -c "example-org-demo-os-$1 \[conductor/" "$BRLOG" 2>/dev/null; }
[ "$(cand 749)" -ge 1 ] && ok || bad "a re-flipped conflict-unresolvable hand-off (#749) must be a candidate again"
[ "$(cand 438)" = 0 ] && ok || bad "a hand-off re-flipped to HEAD_MOVED on its own head (#438) is a re-review in flight — the resolver waits (BH-594)"
grep -q "example-org/demo-os#438: re-review in flight on ${H1:0:8}, resolver waits" "$BRLOG" && ok \
  || bad "the wait on #438 must be said in the resolver log"
[ "$(cand 439)" -ge 1 ] && ok || bad "a re-flipped head-not-reapproved hand-off (#439) must be a candidate again"
[ "$(cand 750)" = 1 ] && ok || bad "a PR the row source already reports must appear exactly once (got $(cand 750))"
[ "$(cand 900)" = 0 ] && ok || bad "a hand-off whose PR has MERGED must never be rebuilt (#304 guard)"
[ "$(cand 901)" = 0 ] && ok || bad "a hand-off older than the recovery window must not be resurrected"
[ "$(cand 777)" = 0 ] && ok || bad "the 'not paged' budget line is an age report, not a hand-off"
grep -q 'example-org/demo-os#749: the conductor handed this off' "$BRLOG" && ok || bad "the recovery must say so in the resolver log"
grep -q 'example-org-demo-os-439 \[conductor/head-not-reapproved\] -> fix-round' "$BRLOG" && ok || bad "a recovered hand-off must keep its own rung (#439 owes a fix round)"
[ -s "$T/gh-writes.txt" ] && bad "observe mode must write nothing to GitHub: $(cat "$T/gh-writes.txt")" || ok
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# 7. The resolver releases the park once it has taken the PR
# ============================================================================
: > "$H/state/merge-conductor/pr-state.tsv"; : > "$MCLOG"; : > "$BRLOG"
rm -f "$H/state/merge-conductor/handoff"/* "$H/state/merge-conductor/handoff-released"/* 2>/dev/null
scratch_rm "$H/state/blocked-resolver"; mkdir -p "$H/state/blocked-resolver"
mc_transition "$KEY" BLOCKED_HUMAN "conflict-unresolvable: tests/static-guards.txt" "$H1" "$H1" "$URL" APPROVE DIRTY "$REC" >/dev/null
[ -e "$(mc_handoff_rel_file "$KEY")" ] && bad "no release marker before the resolver runs" || ok
( PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
    bash "$H/bin/blocked-resolver.sh" demo-os >/dev/null 2>&1 ) || true
[ -s "$(mc_handoff_rel_file "$KEY")" ] && ok || bad "taking a conductor candidate must write the release marker"
grep -q 'blocked-resolver/' "$(mc_handoff_rel_file "$KEY")" && ok || bad "the release marker must name what released it"

# ============================================================================
# 8. The release label's helpers (BH-292): whole-name membership, and the
#    once-per-head marker rides the same two-week sweep as every other marker.
# ============================================================================
HUMDIR="$H/state/merge-conductor/handoff-human"
mc_labels_csv_has "hotfix,Conductor-Release" conductor-release && ok || bad "the release label must match whatever case GitHub returns it in"
mc_labels_csv_has " conductor-release , queued" conductor-release && ok || bad "a label list is trimmed before it is compared"
mc_labels_csv_has "-" conductor-release && bad "the tsv placeholder for 'no labels' must not match" || ok
mc_labels_csv_has "" conductor-release && bad "an empty label list must not match" || ok
mc_labels_csv_has "conductor-released" conductor-release && bad "a label that merely STARTS with the release label must not match" || ok
mc_labels_csv_has "hotfix,queued" conductor-release && bad "an unrelated label list must not match" || ok
mkdir -p "$HUMDIR"
: > "$HUMDIR/example-org_demo-os_111_aaaaaaaaaaaa"; : > "$HUMDIR/example-org_demo-os_112_bbbbbbbbbbbb"
touch -d "@$((NS - 15*86400))" "$HUMDIR/example-org_demo-os_111_aaaaaaaaaaaa"
mc_handoff_gc
[ -e "$HUMDIR/example-org_demo-os_111_aaaaaaaaaaaa" ] && bad "mc_handoff_gc must collect a 15-day-old release marker" || ok
[ -e "$HUMDIR/example-org_demo-os_112_bbbbbbbbbbbb" ] && ok || bad "mc_handoff_gc must keep a fresh release marker"

# ============================================================================
# 9. Release 3: a person puts the conductor-release label on the PR
# ============================================================================
: > "$T/gh-writes.txt"
rm -f "$HUMDIR"/* 2>/dev/null
mk_gh "$H1" OPEN conductor-release
park "$H1"
# This head's rebase has already been spent — which is the state EVERY parked
# conflict is in. Without forgetting it the released row lands in NEEDS_REBASE
# where mc_attempted refuses a second rebase on the same head, and the label
# visibly does nothing.
printf 'rebase %s %s\nmergetree %s %s\n' "$KEY" "$H1" "$KEY" "$H1" >> "$H/state/merge-conductor/attempts.txt"
M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "the release label must end the park in ONE tick (still $(state_of "$KEY"))"
[ "$(since_mark "$M" | grep -c 'RELEASED by the conductor-release label')" = 1 ] && ok || bad "the release must log exactly one line (got $(since_mark "$M" | grep -c 'RELEASED by the conductor-release label'))"
grep -q 'human/conductor-release' "$(mc_handoff_rel_file "$KEY")" 2>/dev/null && ok || bad "the release marker must name the label as what released it"
[ -e "$HUMDIR/example-org_demo-os_759_382730a53827" ] && ok || bad "the release must record the (PR, head) the label was used on"
since_mark "$M" | grep -q MERGE_TREE && ok || bad "a released PR must be tested again like any other"
since_mark "$M" | grep -q REBASE_SPAWNED && ok || bad "the release must forget this head's rebase attempt, or the label moves nothing"
grep -qF "api -X DELETE repos/example-org/demo-os/issues/759/labels/conductor-release" "$T/gh-writes.txt" && ok || bad "actions mode must take the label back off the PR"

# ============================================================================
# 10. The label works ONCE per (PR, head) — and a new head honours it again
# ============================================================================
GW=$(wc -l < "$T/gh-writes.txt")
park "$H1"                       # a fresh park on the SAME head, label still listed
M=$(mark); tick; tick
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "a re-park on a head the label already released must stay parked (got $(state_of "$KEY"))"
grep -q 'RELEASED by the conductor-release label' <<<"$(since_mark "$M")" && bad "the label must not release the same head twice" || ok
since_mark "$M" | grep PARKED | grep -q 'the conductor-release label was already used on this head' && ok || bad "the PARKED line must say why the re-applied label did nothing"
grep -q MERGE_TREE <<<"$(since_mark "$M")" && bad "a re-parked PR must buy no merge-tree test" || ok
[ "$(wc -l < "$T/gh-writes.txt")" = "$GW" ] && ok || bad "a label that released nothing must not be removed again: $(tail -1 "$T/gh-writes.txt")"
mk_gh "$H2" OPEN conductor-release; park "$H2"; M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "a NEW head must honour the label again (still $(state_of "$KEY"))"
[ -e "$HUMDIR/example-org_demo-os_759_beef0002beef" ] && ok || bad "the new head gets its own once-per-head marker"

# ============================================================================
# 11. Observe mode: the park is released locally, GitHub is not written to
# ============================================================================
GW=$(wc -l < "$T/gh-writes.txt")
rm -f "$H/flags/merge-conductor-actions"
mk_gh "$H3" OPEN conductor-release; park "$H3"; M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "observe mode honours the label — classifying a row is not a GitHub write (still $(state_of "$KEY"))"
since_mark "$M" | grep -q 'RELEASED by the conductor-release label' && ok || bad "observe mode must log the release"
[ "$(wc -l < "$T/gh-writes.txt")" = "$GW" ] && ok || bad "observe mode must not touch the label on GitHub: $(tail -1 "$T/gh-writes.txt")"
touch "$H/flags/merge-conductor-actions"

# ============================================================================
# 12. The off switches, and a label on a PR nobody parked
# ============================================================================
GW=$(wc -l < "$T/gh-writes.txt")
mk_gh "$H4" OPEN conductor-release; park "$H4"; M=$(mark)
tick env MC_RELEASE_LABEL=
tick env MC_RELEASE_LABEL=
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "MC_RELEASE_LABEL= must turn the release off (got $(state_of "$KEY"))"
grep -q RELEASED <<<"$(since_mark "$M")" && bad "MC_RELEASE_LABEL= must not release anything" || ok
[ -e "$HUMDIR/example-org_demo-os_759_dead0004dead" ] && bad "the off switch must not even record the head" || ok
[ "$(wc -l < "$T/gh-writes.txt")" = "$GW" ] && ok || bad "the off switch must take no GitHub write: $(tail -1 "$T/gh-writes.txt")"
# MC_STICKY_HANDOFF=0 has no park at all, so there is nothing for the label to release.
M=$(mark); tick env MC_STICKY_HANDOFF=0
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "MC_STICKY_HANDOFF=0 is exactly today's behaviour, label or no label"
grep -q RELEASED <<<"$(since_mark "$M")" && bad "with no sticky park there is no release to log" || ok
[ -e "$HUMDIR/example-org_demo-os_759_dead0004dead" ] && bad "MC_STICKY_HANDOFF=0 must not spend the label's one use" || ok
# A person may pre-apply the label to a PR that is not parked: nothing happens
# to it, and the label is left where they put it.
GW=$(wc -l < "$T/gh-writes.txt")
mk_gh "$H5" OPEN conductor-release
awk -F'\t' -v k="$KEY" '$1!=k' "$H/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
mv -f "$T/rows.tmp" "$H/state/merge-conductor/pr-state.tsv"
rm -f "$H/state/merge-conductor/handoff"/* "$H/state/merge-conductor/handoff-released"/* 2>/dev/null
M=$(mark); tick
[ "$(state_of "$KEY")" != BLOCKED_HUMAN ] && ok || bad "an unparked PR classifies normally (got $(state_of "$KEY"))"
grep -q RELEASED <<<"$(since_mark "$M")" && bad "there is no park to release on an unparked PR" || ok
[ -e "$HUMDIR/example-org_demo-os_759_face0005face" ] && bad "an unparked PR must not spend the label's one use" || ok
[ "$(wc -l < "$T/gh-writes.txt")" = "$GW" ] && ok || bad "a pre-applied label is left alone: $(tail -1 "$T/gh-writes.txt")"

# ============================================================================
# 13. The conflict park names the recommended human move (BH-292)
# ============================================================================
mc_park_human_action "conflict-unresolvable: tests/static-guards.txt" \
  | grep -q 'an agent fix round (bin/blocked-resolver.sh) merges main into this branch and resolves the conflict, or re-plans the ticket with the conflicting files in scope; no person rebases' && ok || bad "the conflict park must name the human move"
[ -z "$(mc_park_human_action head-not-reapproved)" ] && ok || bad "head-not-reapproved has no rebase-by-hand move"
[ -z "$(mc_park_human_action rebase-gate-red)" ] && ok || bad "rebase-gate-red has no rebase-by-hand move"
mc_stuck_waiting_on BLOCKED_HUMAN "conflict-unresolvable: x" | grep -q 'next step: an agent fix round' && ok || bad "the stuck alert for a conflict park must carry the human move"
grep -q 'next step:' <<<"$(mc_stuck_waiting_on BLOCKED_HUMAN rebase-gate-red)" && bad "only the conflict park names a human move" || ok
grep -q 'recommended human action' <<<"$(mc_stuck_waiting_on WAIT_CI checks)" && bad "a WAIT_CI stuck line is unchanged" || ok
# ...and the hand-off line itself, through the tick that reads a finished rebase.
mk_gh "$H6" OPEN
awk -F'\t' -v k="$KEY" '$1!=k' "$H/state/merge-conductor/pr-state.tsv" > "$T/rows.tmp" 2>/dev/null
mv -f "$T/rows.tmp" "$H/state/merge-conductor/pr-state.tsv"
rm -f "$H/state/merge-conductor/handoff"/* "$H/state/merge-conductor/handoff-released"/* 2>/dev/null
JF=$(mc_rb_file example-org/demo-os 759 "$H6"); mkdir -p "$(dirname "$JF")"
printf 'CONFLICT (content): Merge conflict in tests/static-guards.txt\n' > "${JF%.json}.out"
mc_rb_write "$JF" done 0 "$NS" "$NS" 1 "$H6" - "${JF%.json}.out"
M=$(mark); tick
since_mark "$M" | grep -q 'BLOCKED_AGENT conflict-unresolvable: .*tests/static-guards.txt.*next step: an agent fix round (bin/blocked-resolver.sh) merges main into this branch and resolves the conflict, or re-plans the ticket with the conflicting files in scope; no person rebases' \
  && ok || bad "the hand-off line must name the files AND the human move: $(since_mark "$M" | grep BLOCKED_AGENT | head -1)"
[ "$(state_of "$KEY")" = BLOCKED_HUMAN ] && ok || bad "a conflicted rebase result parks the row (got $(state_of "$KEY"))"
M=$(mark); tick
since_mark "$M" | grep PARKED | grep -q 'next step: an agent fix round' && ok || bad "the PARKED line must carry the human move too: $(since_mark "$M" | grep PARKED | head -1)"

echo "conductor-sticky-handoff-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
