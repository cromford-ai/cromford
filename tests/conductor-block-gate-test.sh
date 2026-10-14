#!/bin/bash
# tests/conductor-block-gate-test.sh — BH-762: a human BLOCK on the thread gates
# the merge, on the conductor AND on the tier-2 sweep.
#
# THE INCIDENT. harness-console issue #20 / PR #25: a review landed BLOCK at
# 18:47Z, and at 18:55Z the merge conductor rebased and squash-merged the same
# two commits it had approved earlier. Nothing between READY and `gh pr merge`
# had ever read a comment — the pre-action re-read asks GitHub for
# `state,headRefOid,baseRefName` and nothing else — so the block did not gate it.
#
# Driven, not grepped: every section runs bin/merge-conductor.sh or the tier-2
# merge sweep WHOLE against a stubbed gh, and asserts on the recorded gh argv
# ($T/gh-merges.txt, $T/gh-comments.txt), on logs/merge-conductor.log and on the
# state row. A grep for bg_scan in the source passes just as happily on a gate
# nothing ever reaches.
# Run from anywhere: tests/conductor-block-gate-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111
SLUG=example-org/demo-os
PRURL="https://github.com/$SLUG/pull/41"
BURL="https://github.com/$SLUG/issues/41#issuecomment-9001"
IURL="https://github.com/$SLUG/issues/20#issuecomment-7001"
# Every fixture time is a literal. Nothing here reads the wall clock.
T_HEAD_OLD=2026-09-17T18:40:00Z     # head authored BEFORE the block
T_HEAD_NEW=2026-09-17T18:50:00Z     # head authored AFTER it (an r2 landed)
T_BLOCK=2026-09-17T18:47:00Z
T_CLEAR=2026-09-17T18:52:00Z

# ============================================================================
# Scaffolding: one project, one PR, approved at its head and CI-green, so the
# ONLY thing that can keep it out of `gh pr merge` is the thread.
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/fakebin"
# bin/lib/gh-rest.sh rides with the conductor lib (BH-784): the pre-merge
# re-read and the diff read below go through it, and a tree without it keeps the
# lib's fail-closed shims — every read then answers "unverifiable" and this
# suite would be green on a conductor that never reaches its merge arm.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
[ -r "$DIR/bin/lib/block-gate.sh" ] && cp "$DIR/bin/lib/block-gate.sh" "$T/h/bin/lib/"
# The shared REST answer emitter: gh-rest.sh judges the HTTP STATUS LINE that
# `gh api -i` prints, so a stub arm that echoes a word says nothing at all.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# The record's KEY is TK-20, so the ticket's ISSUE (#20) is NOT the PR number
# (#41) — the two threads have to be distinguishable or section I proves nothing.
REC="$T/h/builds/demo-os-TK-20-202609160001"; mkdir -p "$REC"
echo "PR_CREATED $PRURL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# The gh stub answers the three comment sources out of FILES, so a section sets
# the thread by writing the file. The files hold exactly what `gh api … -q` would
# print: one TSV line per comment (id, time, login, html_url, body@base64).
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
cmt() { # cmt <id> <time> <login> <html_url> <body>
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")"
}
mk_gh() {
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge $PRURL --squash --match-head-commit $H1"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged41"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  # The write shapes, refused exactly as before. The REST ones (BH-784) are the
  # same writes on a new argv: a close PATCH and a comment POST whose body
  # travels as a file. They are recorded and answered 500, which is what gh's
  # old exit 1 said — the write did not land.
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH repos/"*|*"api -i -X POST repos/"*"/comments"*\
  |*"pr edit"*|*"issue close"*|*"issue comment"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"
    case "\$*" in *"api -i -X"*) restpr --raw 500 '{"message":"refused"}'; exit 0 ;; esac
    exit 1 ;;
  *"api repos/$SLUG/issues/41/comments"*)
    [ -f "$T/comments-fail" ] && exit 1
    cat "$T/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/41/reviews"*)   cat "$T/reviews" 2>/dev/null; exit 0 ;;
  # The PR object itself, over REST since BH-597: the conductor reads state,
  # head sha, base, labels and body from this one call instead of the GraphQL
  # pr view cases below. MERGED once the squash landed, OPEN before it.
  "api repos/$SLUG/pulls/41")
    if [ -f "$T/merged41" ]; then
      echo '{"number":41,"html_url":"$PRURL","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"cccccccc3333","mergeable_state":"clean","draft":false,"head":{"sha":"$H1","ref":"ticket/TK-20"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}'
    else
      echo '{"number":41,"html_url":"$PRURL","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"$H1","ref":"ticket/TK-20"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}'
    fi
    exit 0 ;;
  *"repos/$SLUG/pulls/41/files"*) echo '[[{"filename":"src/x.ts"}]]'; exit 0 ;;
  *"api repos/$SLUG/issues/20/comments"*) cat "$T/issuecomments" 2>/dev/null; exit 0 ;;
  # THE CONDUCTOR'S DECISION READS ARE REST (BH-784): the pre-merge re-read is
  # gh api -i -X GET repos/$SLUG/pulls/41 and the iron-law diff is the same path
  # under the v3.diff media type, which is why the diff is matched FIRST. Same
  # facts the --json arms below carry: OPEN on $H1 off main until the merge
  # marker exists, MERGED with cccccccc3333 after it.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*)
    if [ -f "$T/merged41" ]; then restpr MERGED "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator cccccccc3333
    else restpr OPEN "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator; fi ;;
  # The head-time read is REST since BH-1131 (repos/<slug>/pulls/<n>/commits),
  # never the CLI's GraphQL --json commits. (No backticks: this is an unquoted
  # heredoc, and a backtick here would RUN what it describes.)
  *"api repos/$SLUG/pulls/41/commits"*) cat "$T/headtime" 2>/dev/null; exit 0 ;;
  *"--json state,headRefOid,baseRefName"*) [ -f "$T/merged41" ] && echo "MERGED $H1 main" || echo "OPEN $H1 main" ;;
  *"--json state,headRefOid"*)             [ -f "$T/merged41" ] && echo "MERGED $H1" || echo "OPEN $H1" ;;
  *"pr view"*"--json state"*)              [ -f "$T/merged41" ] && echo MERGED || echo OPEN ;;
  *"pr view"*"--json mergeCommit"*) echo "cccccccc3333" ;;
  *"pr list -R $SLUG --state open"*)
    cat <<'J'
[{"number":41,"url":"https://github.com/example-org/demo-os/pull/41","headRefOid":"aaaaaaaa1111","headRefName":"ticket/TK-20","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
mk_gh

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
                 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
TICK() { run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 "$@"; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
# thread <head-time> [<pr-comment-lines-file-content>] — reset every fixture file
thread() {
  printf 'demo-os %s https://demo.example - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
  : > "$T/prcomments"; : > "$T/reviews"; : > "$T/issuecomments"
  printf '%s\n' "$1" > "$T/headtime"
  rm -f "$T/comments-fail"
}
reset_tick() {
  rm -f "$T/merged41" "$T/gh-merges.txt" "$T/gh-writes.txt" "$T/gh-calls.txt" "$T/gh-comments.txt" "$T/tick.err"
  rm -rf "$T/h/state/merge-conductor" "$T/h/state/block-gate" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/locks"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-comments.txt"; : > "$T/gh-calls.txt"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
MCLOG="$T/h/logs/merge-conductor.log"

# ============================================================================
# A. THE INCIDENT. A BLOCK on the PR conversation, newer than the head, and the
#    conductor is READY to merge. It must NOT merge, it must say why in the log
#    naming the comment's URL, it must post exactly one PR comment, and the row
#    must stay READY (no new state, no budget spent).
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding

The channel adoption posts client-named alerts into a public channel." > "$T/prcomments"
TICK
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT: the conductor merged $PRURL over a BLOCK posted at $T_BLOCK, 7 minutes after the head was authored ($(cat "$T/gh-merges.txt"))" || ok
grep -q "MERGE_REFUSED block-gate" "$MCLOG" && ok || bad "the refusal must log MERGE_REFUSED block-gate (log: $(tail -3 "$MCLOG" 2>/dev/null))"
grep -q "MERGE_REFUSED block-gate.*$BURL" "$MCLOG" && ok || bad "the log line must name the blocking comment's URL ($BURL)"
grep -q "reviewer-h" "$MCLOG" && ok || bad "the log line must name who blocked"
[ "$(grep -c 'pr comment' "$T/gh-comments.txt")" = 1 ] && ok || bad "exactly one PR comment must be posted, got $(cat "$T/gh-comments.txt")"
grep -q "$BURL" "$T/gh-comments.txt" && ok || bad "the posted comment must link the blocking comment: $(cat "$T/gh-comments.txt")"
[ "$(state_of "$SLUG#41")" = READY ] && ok || bad "a blocked PR must stay READY — no new state, nothing for the resolver (got '$(state_of "$SLUG#41")')"
grep -qxF "$SLUG#41 $H1 9001" "$T/h/state/block-gate/posted.txt" && ok || bad "the posted-comment ledger must carry one line per (PR, head, comment): $(cat "$T/h/state/block-gate/posted.txt" 2>/dev/null)"

# A3. A SECOND TICK refuses again and posts NO second comment.
rm -f "$T/gh-merges.txt"; : > "$T/gh-merges.txt"; : > "$T/gh-comments.txt"
TICK
[ -s "$T/gh-merges.txt" ] && bad "the second tick merged over the same BLOCK" || ok
[ -s "$T/gh-comments.txt" ] && bad "the second tick posted a second comment for the same (PR, head, block): $(cat "$T/gh-comments.txt")" || ok
[ "$(grep -c 'MERGE_REFUSED block-gate' "$MCLOG")" -ge 2 ] && ok || bad "every tick must log the refusal — a hold nobody can see is the thing this fixes"

# A2. THE BLOCK LANDED AFTER THE REVIEW. Same fixture, but the block is a REVIEW
#     body posted after the record's APPROVE — thread recency is law on the merge
#     side too, so the ledger's APPROVE does not outrank a later BLOCK.
reset_tick; thread "$T_HEAD_OLD"
cmt 4100 "$T_BLOCK" reviewer-h "https://github.com/$SLUG/pull/41#pullrequestreview-4100" "VERDICT: BLOCK" > "$T/reviews"
TICK
[ -s "$T/gh-merges.txt" ] && bad "a BLOCK posted as a REVIEW body after the APPROVE must still gate ($(cat "$T/gh-merges.txt"))" || ok
grep -q "pullrequestreview-4100" "$MCLOG" && ok || bad "the refusal must name the review's URL (log: $(tail -3 "$MCLOG"))"

# ============================================================================
# B. A BLOCK OLDER THAN THE HEAD. An r2 was pushed after it, so the block is
#    about code that no longer exists — it merges.
# ============================================================================
reset_tick; thread "$T_HEAD_NEW"
cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding" > "$T/prcomments"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a BLOCK older than the head must not gate — an r2 clears its own block (log: $(grep -o 'block-gate.*' "$MCLOG" | head -1))"

# ============================================================================
# C. BLOCK then UNBLOCK by the SAME login — it merges.
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" reviewer-h "$BURL-2" "UNBLOCK — the finding is a false positive"; } > "$T/prcomments"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a BLOCK cleared by its own author must merge (log: $(grep -o 'block-gate.*' "$MCLOG" | head -1))"

# ============================================================================
# D. BLOCK by A, CLEARED by B — a different login cannot clear it.
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" someone-else "$BURL-2" "CLEARED as far as I'm concerned"; } > "$T/prcomments"
TICK
[ -s "$T/gh-merges.txt" ] && bad "a CLEARED from a DIFFERENT login must not clear reviewer-h's BLOCK" || ok
grep -q "MERGE_REFUSED block-gate.*$BURL" "$MCLOG" && ok || bad "the refusal must still name reviewer-h's comment"

# ============================================================================
# E. NO BLOCK ANYWHERE — merges exactly as today, and the head's commit dates
#    are never bought (the happy path costs no extra API call beyond the reads).
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
{ cmt 9001 2026-09-17T18:30:00Z reviewer-h "$BURL" "VERDICT: APPROVE"
  cmt 9002 "$T_CLEAR" someone-else "$BURL-2" "BLOCKED_HUMAN is a state word, not a block"; } > "$T/prcomments"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a thread with no BLOCK must merge exactly as today (log: $(grep -o 'block-gate.*' "$MCLOG" | head -1))"
grep -q -- "pulls/41/commits" "$T/gh-calls.txt" && bad "the head's commit dates must be read ONLY when a BLOCK marker exists" || ok
[ -s "$T/gh-comments.txt" ] && bad "nothing may be posted on the happy path: $(cat "$T/gh-comments.txt")" || ok

# ============================================================================
# F. THE READ FAILED. gh exits nonzero on the comments — the gate cannot judge,
#    so nothing merges, nothing is posted, and the log says which read failed.
#    rc 2 is never mapped to "no block".
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"; touch "$T/comments-fail"
TICK
[ -s "$T/gh-merges.txt" ] && bad "an unreadable thread must NOT merge — rc 2 is not rc 0" || ok
grep -q "block gate could not read comments" "$MCLOG" && ok || bad "the log must name the read that failed (log: $(tail -3 "$MCLOG"))"
[ -s "$T/gh-comments.txt" ] && bad "a could-not-judge tick must post nothing: $(cat "$T/gh-comments.txt")" || ok

# ============================================================================
# G. THE ROLLBACK SWITCH. BLOCK_GATE_ENFORCE=0 — warn only: it merges, the log
#    carries WARN-ONLY and the URL, and no comment is posted.
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding" > "$T/prcomments"
TICK BLOCK_GATE_ENFORCE=0
[ -s "$T/gh-merges.txt" ] && ok || bad "BLOCK_GATE_ENFORCE=0 must merge exactly as today"
grep -q "WARN-ONLY" "$MCLOG" && grep -q "$BURL" "$MCLOG" && ok || bad "warn-only must log the URL it would have refused on (log: $(tail -3 "$MCLOG"))"
[ -s "$T/gh-comments.txt" ] && bad "warn-only must post nothing: $(cat "$T/gh-comments.txt")" || ok

# ============================================================================
# I. THE TICKET THREAD, not the PR conversation. On an issue-driven project
#    (fleet.conf board prefix "-") the BLOCK on issue #20 gates PR #41. On a
#    board project the issue thread is not read at all — there is no GitHub
#    issue to read.
# ============================================================================
reset_tick; thread "$T_HEAD_OLD"
cmt 7001 "$T_BLOCK" reviewer-h "$IURL" "BLOCK, one blocking finding" > "$T/issuecomments"
TICK
[ -s "$T/gh-merges.txt" ] && bad "a BLOCK on the TICKET thread must gate the merge on an issue-driven project" || ok
grep -q "MERGE_REFUSED block-gate.*$IURL" "$MCLOG" && ok || bad "the refusal must name the issue comment's URL (log: $(tail -3 "$MCLOG"))"

reset_tick; thread "$T_HEAD_OLD"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
cmt 7001 "$T_BLOCK" reviewer-h "$IURL" "BLOCK, one blocking finding" > "$T/issuecomments"
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a board project has no GitHub issue thread — it must merge (log: $(grep -o 'block-gate.*' "$MCLOG" | head -1))"
grep -q "issues/20/comments" "$T/gh-calls.txt" && bad "a board project must not read a GitHub issue thread" || ok

# ============================================================================
# S. THE SAME ASSERTIONS ON THE TIER-2 MERGE SWEEP. The gate cannot be bypassed
#    by whichever lane picks the PR up first. The sweep is copied standalone and
#    driven whole, exactly as tests/merge-sweep-invisible-repo-test.sh does.
# ============================================================================
SW="$T/sw"
mkdir -p "$SW/bin/lib" "$SW/logs" "$SW/state" "$SW/flags" "$SW/locks" "$SW/env" "$SW/builds"
cp "$DIR/bin/merge-sweep.sh" "$SW/bin/sweep.sh"
mkdir -p "$SW/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$SW/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$SW/bin/"
mkdir -p "$SW/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$SW/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$SW/bin/lib/"
mkdir -p "$SW/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$SW/bin/lib/mc/"
[ -r "$DIR/bin/lib/block-gate.sh" ] && cp "$DIR/bin/lib/block-gate.sh" "$SW/bin/lib/"
for stub in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$SW/bin/$stub"; chmod +x "$SW/bin/$stub"; done
printf '#!/bin/bash\nexit 2\n' > "$SW/bin/pre-arm-guards.sh"; chmod +x "$SW/bin/pre-arm-guards.sh"
cat > "$SW/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") echo ts ;;
  "ts repo") echo "example-org/demo-os" ;;
  "ts board_prefix") echo "-" ;;
esac
SH
chmod +x "$SW/bin/fleet-conf.sh"
cat > "$SW/fakegh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$GH_SINK"
case "\$*" in
  "api repos/$SLUG -q .id") exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$SW/comments.txt"; exit 0 ;;
  *"pr merge"*) echo merged >> "\$MERGE_SINK"; exit 0 ;;
  *"api repos/$SLUG/issues/41/comments"*) cat "$SW/prcomments" 2>/dev/null; exit 0 ;;
  *"api repos/$SLUG/pulls/41/reviews"*)   cat "$SW/reviews" 2>/dev/null; exit 0 ;;
  # The sweep's PR state read, over REST since BH-597 — the same OPEN/CLEAN PR
  # the state,mergeStateStatus case below answers, MERGED once it landed.
  "api repos/$SLUG/pulls/41")
    if [ -s "\$MERGE_SINK" ]; then
      echo '{"number":41,"html_url":"$PRURL","title":"t","body":"","state":"closed","merged_at":"2026-09-12T01:00:00Z","merge_commit_sha":"deadbeefcafe","mergeable_state":"clean","draft":false,"head":{"sha":"$H1","ref":"ticket/TK-20"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","closed_at":"2026-09-12T01:00:00Z"}'
    else
      echo '{"number":41,"html_url":"$PRURL","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"$H1","ref":"ticket/TK-20"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}'
    fi ;;
  *"api repos/$SLUG/issues/20/comments"*) cat "$SW/issuecomments" 2>/dev/null; exit 0 ;;
  # The sweep's decision reads are REST too (BH-784): one GET on the pull for
  # state, merge state, author, head sha and merge commit, and the same path
  # under the v3.diff media type for the iron-law scan — matched FIRST because
  # it shares the path. Same facts the --json arms below carry.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*)
    if [ -s "\$MERGE_SINK" ]; then restpr MERGED "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator; fi ;;
  # The issue close-out, which used to be \`gh issue comment\`/\`gh issue close\`:
  # a comment POST (body by file, so nothing is recorded here, exactly as the
  # old silent arm), the close PATCH, and the re-read gh_rest_close does before
  # it reports the close landed.
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/$SLUG/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/$SLUG/issues/"*)   restpr --raw 200 '{"state":"closed"}' ;;
  # The head-time read is REST since BH-1131 (repos/<slug>/pulls/<n>/commits),
  # never the CLI's GraphQL --json commits. (No backticks: this is an unquoted
  # heredoc, and a backtick here would RUN what it describes.)
  *"api repos/$SLUG/pulls/41/commits"*) cat "$SW/headtime" 2>/dev/null; exit 0 ;;
  *"--json state,isInMergeQueue"*) [ -s "\$MERGE_SINK" ] && echo "MERGED false" || echo "OPEN false" ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator $H1 " ;;
  *"--json headRefName"*) echo "ticket/TK-20" ;;
  *"--json state -q .state"*) [ -s "\$MERGE_SINK" ] && echo MERGED || echo OPEN ;;
  *"pr diff"*) echo "+ const x = 1;" ;;
  *"--json mergeCommit"*) echo "deadbeefcafe" ;;
  *"issue comment"*|*"issue close"*) exit 0 ;;
  *) echo "" ;;
esac
EOF
chmod +x "$SW/fakegh"
mkdir -p "$SW/fakebin"; cp "$SW/fakegh" "$SW/fakebin/gh"
cp "$DIR/tests/lib/rest-emit.sh" "$SW/fakebin/restpr"; chmod +x "$SW/fakebin/restpr"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$SW/fakebin/curl"; chmod +x "$SW/fakebin/curl"
sw_setup() { # sw_setup <head-time>
  scratch_rm "$SW/builds"; scratch_rm "$SW/state/block-gate"; mkdir -p "$SW/builds/pool-ts-TK-20-202609160001"
  echo "PR_CREATED $PRURL" > "$SW/builds/pool-ts-TK-20-202609160001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SW/builds/pool-ts-TK-20-202609160001/review.md"
  : > "$SW/builds/pool-ts-TK-20-202609160001/pipeline.log"
  : > "$SW/state/merge-sweep-done.txt"; : > "$SW/logs/merge-sweep.log"; : > "$SW/logs/ALERTS.log"
  : > "$SW/merges.txt"; : > "$SW/gh.txt"; : > "$SW/comments.txt"
  : > "$SW/prcomments"; : > "$SW/reviews"; : > "$SW/issuecomments"
  printf '%s\n' "$1" > "$SW/headtime"
}
sweep() {
  ( export PATH="$SW/fakebin:$SW/bin:$PATH" HARNESS="$SW" HARNESS_SECRET=s \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b \
           MERGE_SINK="$SW/merges.txt" GH_SINK="$SW/gh.txt"; unset GH_TOKEN
    bash "$SW/bin/sweep.sh" >/dev/null 2>"$SW/err.txt" )
}

# S-A. blocked head: no merge, a log line naming the URL, one comment, and NOT
#      recorded in the done-ledger (a recorded park is invisible for ever).
sw_setup "$T_HEAD_OLD"
cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding" > "$SW/prcomments"
sweep
[ -s "$SW/merges.txt" ] && bad "THE DEFECT, sweep side: the tier-2 sweep merged over a BLOCK (err: $(cat "$SW/err.txt"))" || ok
grep -q "block-gate.*$BURL" "$SW/logs/merge-sweep.log" && ok || bad "the sweep must log the refusal with the comment URL: $(cat "$SW/logs/merge-sweep.log")"
[ "$(grep -c 'pr comment' "$SW/comments.txt")" = 1 ] && ok || bad "the sweep must post exactly one refusal comment, got: $(cat "$SW/comments.txt")"
grep -q "pull/41" "$SW/state/merge-sweep-done.txt" && bad "a blocked PR must NOT be ledgered — it would never be re-offered" || ok

# S-C. cleared by the same login: it merges.
sw_setup "$T_HEAD_OLD"
{ cmt 9001 "$T_BLOCK" reviewer-h "$BURL" "BLOCK, one blocking finding"
  cmt 9002 "$T_CLEAR" reviewer-h "$BURL-2" "UNBLOCK"; } > "$SW/prcomments"
sweep
grep -q merged "$SW/merges.txt" && ok || bad "the sweep must merge a cleared BLOCK: $(cat "$SW/logs/merge-sweep.log") err=$(cat "$SW/err.txt")"

# S-E. no block: merges exactly as today, and no commit-date read.
sw_setup "$T_HEAD_OLD"
sweep
grep -q merged "$SW/merges.txt" && ok || bad "the sweep must merge a clean thread: $(cat "$SW/logs/merge-sweep.log") err=$(cat "$SW/err.txt")"
grep -q -- "pulls/41/commits" "$SW/gh.txt" && bad "the sweep must not buy the head's commit dates with no BLOCK in the thread" || ok
[ -s "$SW/comments.txt" ] && bad "the sweep must post nothing on the happy path: $(cat "$SW/comments.txt")" || ok

echo "conductor-block-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
