#!/bin/bash
# tests/block-gate-lanes-test.sh — BH-762 on the other four merge paths: the
# box merge queue (assembly, train landing and serial), the tier-1 gate inside a
# build, the reviewer, and batch-resolve's candidate loop.
#
# WHY ALL FIVE LANES AND NOT JUST THE CONDUCTOR. A PR has six actors that can
# land it. A gate on one of them is not a gate — whichever lane picks the PR up
# first is the one that merges, and the box queue and review-prs run on every
# watcher box on their own crons. tests/conductor-block-gate-test.sh covers the
# conductor and the tier-2 sweep; this file covers the rest.
#
# Driven, not grepped: section Q runs bin/merge-queue.sh whole, and sections B,
# R and Q-train extract the production block VERBATIM by its `# >>> …` markers
# and run THAT, so deleting the gate's call site fails a test here.
# Every fixture time is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/block-gate-lanes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
H1=aaaaaaaa1111
BURL="https://github.com/$SLUG/issues/41#issuecomment-9001"
T_HEAD_OLD=2026-09-17T18:40:00Z
T_BLOCK=2026-09-17T18:47:00Z
T_CLEAR=2026-09-17T18:52:00Z

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# bin/lib/gh-rest.sh rides with the conductor lib (BH-784): every decision read
# in bin/merge-queue.sh goes through it now. Without it in the fixture tree the
# lib's fail-closed shims answer "unverifiable" to every read and this queue
# never reaches a merge at all, so the gate below would be green on nothing.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# BH-5914: the conductor-verdict rule every merge lane shares, installed with
# its closure (it sources nothing, so the closure is the one file). Only if it
# exists, so the V cases below are red on a tree without it.
[ -f "$DIR/bin/lib/conductor-verdict.sh" ] && { ( cd "$DIR" && scratch_install_closure bin/lib/conductor-verdict.sh "$T/h" ) >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/lib/conductor-verdict.sh"; exit 1; }; }
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"; : > "$T/h/env/demo-os.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in beat.sh deploy-request.sh lander.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"; done
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
# The shared REST answer emitter. gh-rest.sh judges the HTTP STATUS LINE that
# `gh api -i` prints, so a stub arm that just echoes a word says nothing at all;
# `restpr` prints a whole response. tests/lib/rest-emit.sh documents the shapes.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"; }
# One gh stub for every section: the three comment sources come out of files
# named after the PR number, so a section sets a thread by writing one file.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*)   printf '%s\n' "\$*" >> "$T/gh-merges.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  *"api repos/$SLUG/issues/"*"/comments"*)
    N=\$(sed -E 's|.*/issues/([0-9]+)/comments.*|\1|' <<<"\$*")
    cat "$T/thread-\$N" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/"*"/reviews"*) exit 0 ;;
  # THE QUEUE'S DECISION READS ARE REST (BH-784): mq_pr goes through
  # gh api -i -X GET repos/$SLUG/pulls/<n>, judged on the HTTP status line, so
  # the stub prints a whole response. Same facts the --json arms below carry:
  # an OPEN, MERGEABLE PR on ticket/TK-41, MERGED once something has been
  # merged, and cccccccc3333 as the merge commit.
  *"api -i -X GET repos/$SLUG/pulls/"*)
    if [ -s "$T/gh-merges.txt" ]; then restpr MERGED "$H1" ticket/TK-41 main "" MERGEABLE CLEAN operator cccccccc3333
    else restpr OPEN "$H1" ticket/TK-41 main "" MERGEABLE CLEAN operator; fi ;;
  # The head-time read is REST since BH-1131 (repos/<slug>/pulls/<n>/commits),
  # never the CLI's GraphQL --json commits. (No backticks: this is an unquoted
  # heredoc, and a backtick here would RUN what it describes.)
  *"api repos/$SLUG/pulls/"*"/commits"*) cat "$T/headtime" 2>/dev/null; exit 0 ;;
  *"--json headRefOid"*) echo "$H1" ;;
  *"--json state,mergeable,headRefName"*) echo "OPEN MERGEABLE ticket/TK-41" ;;
  *"--json state,headRefName"*) echo "OPEN ticket/TK-41" ;;
  *"--json state"*) [ -s "$T/gh-merges.txt" ] && echo MERGED || echo OPEN ;;
  *"--json mergeCommit"*) echo cccccccc3333 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
reset_lane() {
  : > "$T/gh-calls.txt"; : > "$T/gh-merges.txt"; : > "$T/gh-comments.txt"
  rm -f "$T"/thread-*; printf '%s\n' "$T_HEAD_OLD" > "$T/headtime"
  rm -rf "$T/h/state/block-gate"
}
block_on() { cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding" > "$T/thread-$1"; }
clear_on() { { cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding"
               cmt 9002 "$T_CLEAR" reviewer-h "$BURL-2" "UNBLOCK"; } > "$T/thread-$1"; }

# ============================================================================
# Q. bin/merge-queue.sh, run WHOLE with one queued entry.
# ============================================================================
Q="$T/h/state/merge-queue/demo-os"; mkdir -p "$Q"
mq() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
         bash "$T/h/bin/merge-queue.sh" demo-os >/dev/null 2>"$T/mq.err" ) || true; }
MQLOG="$T/h/logs/merge-queue.log"

reset_lane; block_on 41; : > "$MQLOG"; rm -f "$Q"/*; : > "$Q/41"
mq
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT, queue side: the box merge queue landed #41 over a BLOCK ($(cat "$T/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED block-gate.*$BURL" "$MQLOG" && ok || bad "the queue must log the refusal with the comment URL: $(cat "$MQLOG")"
[ -f "$Q/41" ] && ok || bad "the entry must STAY queued — the hold ends by itself when the block clears"
[ -f "$Q/41.blocked" ] && bad "a blocked-by-a-human entry must not be parked .blocked: nobody has to put it back" || ok
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "exactly one refusal comment: $(cat "$T/gh-comments.txt")"

reset_lane; clear_on 41; : > "$MQLOG"; rm -f "$Q"/*; : > "$Q/41"
mq
grep -q "pr merge 41" "$T/gh-merges.txt" && ok || bad "a cleared BLOCK must land on the next pass: $(cat "$MQLOG") err=$(cat "$T/mq.err")"

# Q-train. The union merge train's member loop, extracted verbatim: a blocked PR
# never enters the batch, so it is neither typechecked into the candidate nor
# landed by the cheap gh merges that follow.
awk '/^    # >>> head-bound train members/{f=1;next} /^    # <<< head-bound train members/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/train.sh"
[ -s "$T/train.sh" ] && ok || bad "could not extract the train member loop — markers missing?"
# bg_queue_hold itself is the queue's own, extracted by ITS markers — the loop
# under test calls it by name, so a paraphrase here would prove nothing.
awk '/^# >>> block gate/{f=1;next} /^# <<< block gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/qhold.sh"
[ -s "$T/qhold.sh" ] && ok || bad "could not extract bg_queue_hold from bin/merge-queue.sh"
reset_lane; block_on 7; clear_on 8
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/git"; chmod +x "$T/fakebin/git"
BATCH_OUT=$( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT=demo-os \
  LOG="$T/train.log" WT="$T" QUEUED="7 8" \
  bash -c 'set -uo pipefail
    STAMP() { echo TS; }
    bh_held() { return 1; }
    hb_blocked() { return 1; }
    # The member loop reads through mq_pr / mc_rest_status since BH-784, which
    # bin/merge-queue.sh builds on the conductor lib. Sourced and defined here
    # exactly as the queue does it, so the loop under test runs the real read
    # against the stub gh rather than a paraphrase of it.
    . "$HARNESS/bin/lib/merge-conductor-lib.sh"
    mq_pr() { mc_pr_view "https://github.com/$SLUG/pull/${1:?num}" "${2:?expr}"; }
    . "$HARNESS/bin/lib/block-gate.sh"
    . "'"$T"'/qhold.sh"
    BATCH=""
    . "$0"
    printf "BATCH=[%s]" "$BATCH"' "$T/train.sh" 2>"$T/train.err" )
[ -s "$T/train.err" ] && echo "train stderr: $(cat "$T/train.err")"
grep -q 'BATCH=\[ 8\]' <<<"$BATCH_OUT" && ok || bad "a blocked PR must not enter the merge train's batch (got $BATCH_OUT)"

# Q-land. The train's LANDING loop, extracted verbatim. Assembly and landing are
# minutes apart on a real repo — a union fetch, a merge round per member and a
# full typecheck sit between them — so the thread is asked again here. A member
# blocked inside that window must not be one of the cheap gh merges.
awk '/^        # >>> train landing/{f=1;next} /^        # <<< train landing/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/land.sh"
[ -s "$T/land.sh" ] && ok || bad "could not extract the train landing loop — markers missing?"
# mq_land is the queue's own landing call (BH-892), extracted by ITS markers for
# the same reason bg_queue_hold is: the loop under test calls it by name, and a
# paraphrase here would prove nothing. With no bin/lib/gh-pr-merge.sh in this
# fixture it is today's `gh pr merge` line, which is what this lane asserts on.
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mqland.sh"
[ -s "$T/mqland.sh" ] && ok || bad "could not extract mq_land from bin/merge-queue.sh"
reset_lane; block_on 7; clear_on 8; : > "$MQLOG"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT=demo-os \
  LOG="$MQLOG" Q="$T/h/state/merge-queue/demo-os" BATCH="7 8" \
  bash -c 'set -uo pipefail
    STAMP() { echo TS; }
    MQROW() { :; }
    LANDED=0; LAST_SHA=""
    . "$HARNESS/bin/lib/block-gate.sh"
    . "'"$T"'/qhold.sh"
    . "'"$T"'/mqland.sh"
    . "$0"' "$T/land.sh" >/dev/null 2>"$T/land.err" ) || true
[ -s "$T/land.err" ] && echo "land stderr: $(cat "$T/land.err")"
grep -q 'pr merge 7 ' "$T/gh-merges.txt" && bad "a member blocked between assembly and landing must not be merged ($(cat "$T/gh-merges.txt"))" || ok
grep -q 'pr merge 8 ' "$T/gh-merges.txt" && ok || bad "the unblocked members of the train must still land: $(cat "$T/gh-merges.txt")"
grep -q "MERGE_REFUSED block-gate.*$BURL" "$MQLOG" && ok || bad "the train must log the refusal with the URL: $(cat "$MQLOG")"

# ============================================================================
# B. bin/run-build.sh's tier-1 merge gate, extracted and driven, exactly as
#    tests/conductor-owns-merges-test.sh drives it.
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the tier-1 merge gate — markers missing?"
run_gate() { # run_gate ; prints the RESULT line
  rm -f "$T/RESULT"; mkdir -p "$T/h/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/gate/review.md"; printf 'plan\n' > "$T/h/builds/gate/plan.md"
  : > "$T/h/builds/gate/pipeline.log"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD="$T/h/builds/gate" ALERTS="$T/h/logs/ALERTS.log" \
      PROJECT=demo-os KEY=TK-41 SLUG="$SLUG" TIER=1 PR_URL="https://github.com/$SLUG/pull/41" \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" CLOSES_LINE="${RG_CLOSES:-Closes #41}" HEADBOUND_SHA="$H1" \
      BUILDER_NO_MERGE= \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        . "$HARNESS/bin/lib/block-gate.sh"
        . "$0"' "$T/gate.sh" >/dev/null 2>&1 ) || true
  cat "$T/RESULT" 2>/dev/null
}
reset_lane; block_on 41
OUT=$(run_gate)
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT, tier-1 side: the build merged its own PR over a BLOCK ($(cat "$T/gh-merges.txt"))" || ok
grep -q "^PR_CREATED https://github.com/$SLUG/pull/41" <<<"$OUT" && ok || bad "a blocked tier-1 build must exit through PR_CREATED (got '$OUT')"
grep -q "tier-1 merge REFUSED block-gate.*$BURL" "$T/h/builds/gate/pipeline.log" \
  && ok || bad "the build log must name the blocking comment: $(cat "$T/h/builds/gate/pipeline.log")"
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "one refusal comment on the PR: $(cat "$T/gh-comments.txt")"

# BH-5798: a partial build's CLOSES_LINE is "Refs #N", not "Closes #N". On an
# Issues board the ticket thread (issue 269 here, not the PR's own thread 41)
# carries the BLOCK, so the gate must read issue 269 for both prefixes.
for RGC in "Closes #269" "Refs #269"; do
  reset_lane; block_on 269
  OUT=$(RG_CLOSES="$RGC" run_gate)
  [ -s "$T/gh-merges.txt" ] && bad "CLOSES_LINE='$RGC': the tier-1 build merged its own PR over a BLOCK on the ticket thread ($(cat "$T/gh-merges.txt"))" || ok
  grep -q "tier-1 merge REFUSED block-gate.*$BURL" "$T/h/builds/gate/pipeline.log" \
    && ok || bad "CLOSES_LINE='$RGC': the gate must read issue 269's thread and name the blocking comment: $(cat "$T/h/builds/gate/pipeline.log")"
done

reset_lane; clear_on 41
OUT=$(run_gate)
[ -s "$T/gh-merges.txt" ] && ok || bad "with no standing BLOCK a tier-1 build must merge exactly as it always has"
grep -q "^PR_MERGED https://github.com/$SLUG/pull/41" <<<"$OUT" && ok || bad "a real tier-1 merge must still report PR_MERGED (got '$OUT')"

# ============================================================================
# R. bin/review-prs.sh's merge step, extracted by its markers and driven.
# ============================================================================
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' \
  "$DIR/bin/review-prs.sh" > "$T/rmerge.sh"
[ -s "$T/rmerge.sh" ] && ok || bad "could not extract the review-prs merge step — markers missing?"
run_review() { # run_review ; prints MERGED=<value>
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT=demo-os SLUG="$SLUG" LOG="$T/pr-reviews.log" \
      bash -c 'set -uo pipefail
        STAMP() { echo TS; }
        rp_prov_is_claude() { [ "${1:-}" = claude ]; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        # TEST-CHANGE (BH-1585): the merge step reads the state-after and the
        # merge commit over REST now (mc_pr_view / gh_rest, which review-prs.sh
        # always has in scope), so the driver provides both, over the same
        # `api -i -X GET …/pulls/<n>` arm the queue reads already use.
        # TEST-CHANGE (BH-1285): merge_step now reads .base.ref before the
        # direct merge (a stacked PR is held), so the shim carries base.ref too.
        . "'"$DIR"'/bin/lib/gh-rest.sh"
        mc_pr_view() { local f; f=$(mktemp); gh_rest GET "repos/$SLUG/pulls/${1##*/}" > "$f" || { rm -f "$f"; return 75; }
          jq -r "{STATE: (if .merged_at != null then \"MERGED\" elif .state == \"open\" then \"OPEN\" else \"CLOSED\" end), base: {ref: .base.ref}} | ${2:-.}" "$f"; rm -f "$f"; }
        . "$HARNESS/bin/lib/block-gate.sh"
        . "$0"
        merge_step 41 '"$H1"' claude
        printf "MERGED=%s" "$MERGED"' "$T/rmerge.sh" 2>/dev/null )
}
reset_lane; block_on 41; : > "$T/pr-reviews.log"
OUT=$(run_review)
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT, reviewer side: review-prs merged an APPROVE over a BLOCK ($(cat "$T/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED block-gate.*$BURL" "$T/pr-reviews.log" && ok || bad "review-prs must log the refusal with the URL: $(cat "$T/pr-reviews.log")"
grep -q 'MERGED=no' <<<"$OUT" && ok || bad "a held merge must report merged=no (got $OUT)"
[ -f "$T/h/state/merge-queue/demo-os/41" ] && bad "a blocked PR must not be pushed onto the box merge queue either" || ok

reset_lane; clear_on 41; : > "$T/pr-reviews.log"
OUT=$(run_review)
grep -q "pr merge 41" "$T/gh-merges.txt" && ok || bad "with the block cleared review-prs must merge as it always has: $(cat "$T/pr-reviews.log")"
grep -q 'MERGED=yes' <<<"$OUT" && ok || bad "a real merge must report merged=yes (got $OUT)"

# R-order. The fleet kill switch is asked BEFORE the gate. While automerge is
# off nothing merges anyway, so reading the thread on every PR on every tick
# buys nothing — and telling a client "it merges when a newer commit is pushed"
# about a merge that was never going to happen is worse than nothing.
reset_lane; block_on 41; : > "$T/pr-reviews.log"
touch "$T/h/flags/automerge-disabled"
OUT=$(run_review)
rm -f "$T/h/flags/automerge-disabled"
[ -s "$T/gh-merges.txt" ] && bad "the kill switch must still stop the merge ($(cat "$T/gh-merges.txt"))" || ok
grep -q 'MERGED=no' <<<"$OUT" && ok || bad "a paused fleet reports merged=no (got $OUT)"
[ -s "$T/gh-comments.txt" ] && bad "a paused fleet must not spend reads or comment on the PR: $(cat "$T/gh-comments.txt")" || ok
grep -q 'issues/41/comments' "$T/gh-calls.txt" && bad "the thread must not be read at all while the fleet is paused" || ok

# ============================================================================
# X. bin/batch-resolve.sh's candidate loop — the SIXTH merge path, and the one
#    that hides best. A member of a union train never reaches the conductor's
#    READY arm while the train is in flight, and the train is a NEW PR whose own
#    thread is empty, so a gate on the five lanes above still puts a blocked
#    PR's code on main. The loop is extracted by its markers and run.
# ============================================================================
awk '/^# >>> batch candidates/{f=1;next} /^# <<< batch candidates/{exit} f' \
  "$DIR/bin/batch-resolve.sh" > "$T/cand.sh"
[ -s "$T/cand.sh" ] && ok || bad "could not extract the batch candidate loop — markers missing?"
awk '/^# >>> block gate/{f=1;next} /^# <<< block gate/{exit} f' \
  "$DIR/bin/batch-resolve.sh" > "$T/bhold.sh"
[ -s "$T/bhold.sh" ] && ok || bad "could not extract bg_batch_hold from bin/batch-resolve.sh"
# A real git: the loop fetches the branch and insists origin/<br> is still the
# head the PR list gave it, so rev-parse has to answer.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
case "\$*" in *rev-parse*) echo "$H1" ;; esac
exit 0
EOF
chmod +x "$T/fakebin/git"
mkdir -p "$T/bstate" "$T/rec"; printf 'TIER: 2\nVERDICT: APPROVE\n' > "$T/rec/review.md"
run_batch() { # run_batch ; prints CAND=[...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT=demo-os \
      H="$T/h" LOG="$T/batch.log" STATE="$T/bstate" REPO="$T/repo" PBASE=main \
      bash -c 'set -uo pipefail
        say() { echo "$*" >> "$LOG"; }
        mc_record_for() { printf "%s" "'"$T"'/rec"; }
        mc_is_harness_pr() { return 0; }
        mc_verdict() { printf "APPROVE\tclaude\t'"$H1"'\t-\t-"; }
        mc_prov_held() { return 1; }
        mc_prov_cleared() { return 0; }
        mc_issue_of() { grep -oE "[0-9]+" <<<"${2##*/}" | head -1; }
        classify_pair() { echo "allowed -"; }
        . "$HARNESS/bin/lib/block-gate.sh"
        . "'"$T"'/bhold.sh"
        declare -A HEADOF URLOF BRANCHOF
        CONFLICTS_SEEN=0
        ROWS=()
        for N in 7 8; do
          ROWS+=("$(printf "%s\thttps://github.com/'"$SLUG"'/pull/%s\t'"$H1"'\tticket/aio-%s\tmain\tfalse\tCLEAN" "$N" "$N" "$N")")
        done
        . "$0"
        printf "CAND=[%s]" "${CAND[*]:-}"' "$T/cand.sh" 2>"$T/batch.err" )
}
reset_lane; block_on 7; clear_on 8; : > "$T/batch.log"
OUT=$(run_batch)
[ -s "$T/batch.err" ] && echo "batch stderr: $(cat "$T/batch.err")"
grep -q 'CAND=\[8\]' <<<"$OUT" && ok || bad "THE DEFECT, train side: a blocked PR must not become a train candidate (got $OUT)"
grep -q "MERGE_REFUSED block-gate.*$BURL" "$T/batch.log" && ok || bad "batch-resolve must log the refusal with the comment URL: $(cat "$T/batch.log")"
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "one refusal comment on the blocked member: $(cat "$T/gh-comments.txt")"
[ -s "$T/bstate/abandoned.txt" ] && bad "a human block must not write an exclusion row — the next pass batches it the moment it clears" || ok

reset_lane; clear_on 7; clear_on 8; : > "$T/batch.log"
OUT=$(run_batch)
grep -q 'CAND=\[7 8\]' <<<"$OUT" && ok || bad "with no standing BLOCK the train is assembled exactly as before (got $OUT: $(cat "$T/batch.log"))"
[ -s "$T/gh-comments.txt" ] && bad "nothing to refuse, nothing to say: $(cat "$T/gh-comments.txt")" || ok

# ============================================================================
# V. BH-5914: the merge conductor's per-head verdict holds the reviewer's merge
#    and the tier-1 merge too (project-6 #27: the conductor refused a head and a
#    second lane merged it 20 seconds later). The row is the jobs-ledger row
#    mc_merge_verdict_put writes: kind mc-merge-verdict, key <slug>#<n>,
#    detail "<head> <reason>". job_ledger_row is stubbed and exported for these
#    cases only; no thread BLOCK is standing (clear_on), so the verdict is the
#    one thing in the way.
# ============================================================================
job_ledger_row() { [ "$1 $2" = "mc-merge-verdict $SLUG#41" ] || return 2; cat "$T/cvrow" 2>/dev/null || return 2; }
export -f job_ledger_row
export T SLUG
cvhold() { jq -nc --arg d "$1 diff-unread: the diff read was UNVERIFIABLE (HTTP 406), iron-law scan NOT run" '{status:"hold", detail:$d}' > "$T/cvrow"; }

# V-R. review-prs: a held head is not merged, not counted, not queued
reset_lane; clear_on 41; : > "$T/pr-reviews.log"; cvhold "$H1"
OUT=$(run_review)
[ -s "$T/gh-merges.txt" ] && bad "V-R review-prs must not merge a head the conductor holds ($(cat "$T/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED conductor-verdict.*${H1:0:8}.*diff-unread" "$T/pr-reviews.log" && ok || bad "V-R review-prs must log MERGE_REFUSED conductor-verdict with the head and reason: $(cat "$T/pr-reviews.log")"
grep -q 'MERGED=no' <<<"$OUT" && ok || bad "V-R a held merge must report merged=no (got $OUT)"
[ -f "$T/h/state/merge-queue/demo-os/41" ] && bad "V-R a held PR must not be pushed onto the box merge queue" || ok
# V-R2. a hold on another head does not stop this one
reset_lane; clear_on 41; : > "$T/pr-reviews.log"; cvhold "ffffffff9999"
OUT=$(run_review)
grep -q "pr merge 41" "$T/gh-merges.txt" && ok || bad "V-R2 a hold on another head must not stop review-prs: $(cat "$T/pr-reviews.log")"

# V-B. the run-build tier-1 merge: a held head exits through PR_CREATED
reset_lane; clear_on 41; cvhold "$H1"
OUT=$(run_gate)
[ -s "$T/gh-merges.txt" ] && bad "V-B the tier-1 merge must not merge a head the conductor holds ($(cat "$T/gh-merges.txt"))" || ok
grep -q "^PR_CREATED https://github.com/$SLUG/pull/41" <<<"$OUT" && ok || bad "V-B a held tier-1 build must exit through PR_CREATED (got '$OUT')"
grep -q "MERGE_REFUSED conductor-verdict.*${H1:0:8}" "$T/h/builds/gate/pipeline.log" && ok || bad "V-B the build log must say MERGE_REFUSED conductor-verdict: $(cat "$T/h/builds/gate/pipeline.log")"
# V-B2. a cleared head merges as it always has
reset_lane; clear_on 41; jq -nc --arg d "$H1 iron-law scan clean" '{status:"clear", detail:$d}' > "$T/cvrow"
OUT=$(run_gate)
[ -s "$T/gh-merges.txt" ] && ok || bad "V-B2 a cleared head must merge (got '$OUT')"
unset -f job_ledger_row; rm -f "$T/cvrow"

echo "block-gate-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
