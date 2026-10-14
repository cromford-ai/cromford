#!/bin/bash
# tests/merge-sweep-async-test.sh — bin/merge-sweep.sh must stop treating gh's
# EXIT CODE as proof of a landing.
#
# WHY. On a repo whose main is behind GitHub's native merge queue,
# `gh pr merge <url> --squash` ENQUEUES and exits 0. The sweep's old
# `if gh pr merge …; then` therefore recorded the merge (sweep_record merged,
# which is the ledger row AND state/merge-sweep-done.txt), CLOSED THE ISSUE, and
# beat `tier2_sweep_merged` — for a PR that was still open, with mergeCommit.oid
# null so the deploy hand-off silently skipped. It also passed --delete-branch,
# which on a queued PR deletes the branch the queue is about to build.
#
# The fix is to ask GitHub what happened instead of asking gh whether it was
# willing to try: MERGED → today's consequence block, in the queue → one log
# line and nothing else (the merge conductor owns the settle), neither → the
# existing failure path.
# Run from anywhere: tests/merge-sweep-async-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
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

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/tmp" "$T/fakebin"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# bin/lib/gh-rest.sh rides with the lib because the sweep's decision reads go
# through it (BH-784). Without it the lib's fail-closed shims answer
# "unverifiable" to every read and the sweep never reaches a merge at all.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
printf 'q o/queued - - 2 box-q\np o/plain - - 3 box-p\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/prearm-calls.txt"\nexit 0\n' "$T" > "$T/bin/pre-arm-guards.sh"
chmod +x "$T/bin/pre-arm-guards.sh"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/o/queued/rulesets/9"*)
    restpr --raw 200 '{"id":9,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/o/queued/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/o/plain/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  "api repos/o/queued -q .id"|"api repos/o/plain -q .id") echo 1 ;;
  # An empty rate_limit answer leaves bin/lib/gh-budget.sh a 0-byte cache file
  # and a later run in this scratch tree dies on it.
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # gh exits 0 on a merge-queue repo: it ENQUEUED, it did not merge. The marker
  # is what makes the PLAIN repo's PR read MERGED afterwards — gh's exit code is
  # never the landing, GitHub's answer is.
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; touch "$T/merged"; exit 0 ;;
  # THE DECISION READS ARE REST (BH-784): gh api -i -X GET repos/SLUG/pulls/N,
  # judged on the HTTP status line, so restpr prints a whole response. The diff
  # shares the pulls path and is told apart by its Accept header, which is why it
  # is matched FIRST.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/o/queued/pulls/7"*) restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator ;;
  *"api -i -X GET repos/o/plain/pulls/8"*)
    if [ -f "$T/merged" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  # The issue close-out: a comment POST, a close PATCH, and the re-read
  # gh_rest_close does before it reports the close landed.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# No ledger rows anywhere: the build record decides, exactly as in prod with a
# worker outage (tests/merge-sweep-invisible-repo-test.sh uses the same stub).
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

setup() { # setup <project> <slug> <pr-number>
  rm -rf "$T/builds"; mkdir -p "$T/builds/pool-$1-XX-$3-202609120001"
  echo "PR_CREATED https://github.com/$2/pull/$3" > "$T/builds/pool-$1-XX-$3-202609120001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/builds/pool-$1-XX-$3-202609120001/review.md"
  : > "$T/builds/pool-$1-XX-$3-202609120001/pipeline.log"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merge-calls.txt"; : > "$T/issue-calls.txt"; : > "$T/prearm-calls.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/merged"
  rm -f "$T/tmp"/*.probe 2>/dev/null
}
run_sweep() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
  bash "$T/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) || { echo "sweep rc=$? stderr:"; cat "$T/sweep.err"; }; }

# ============================================================================
# 1. Merge-queue repo: gh exits 0, the PR is still OPEN and in the queue
# ============================================================================
setup q o/queued 7
run_sweep
[ -s "$T/merge-calls.txt" ] && ok || bad "the sweep must still attempt the merge on a queue repo (that is the enqueue)"
grep -q -- "--delete-branch" "$T/merge-calls.txt" \
  && bad "the sweep must NOT pass --delete-branch on a queue repo — the PR has not merged yet (got: $(cat "$T/merge-calls.txt"))" || ok
grep -qxF 'https://github.com/o/queued/pull/7' "$T/state/merge-sweep-done.txt" \
  && bad "gh exit 0 + OPEN + isInMergeQueue must NOT be recorded as merged" || ok
[ -s "$T/issue-calls.txt" ] \
  && bad "a PR that was only ENQUEUED must not have its issue closed: $(cat "$T/issue-calls.txt")" || ok
grep -qi 'enqueued' "$T/logs/merge-sweep.log" && ok \
  || bad "the sweep must log that the PR was enqueued and the conductor settles it (log: $(cat "$T/logs/merge-sweep.log"))"
[ -s "$T/prearm-calls.txt" ] \
  && bad "pre-arm-guards.sh must be skipped on a queue repo (the merge_group run subsumes it)" || ok

# ============================================================================
# 2. Ordinary repo: gh exits 0 AND GitHub says MERGED — nothing changes
# ============================================================================
setup p o/plain 8
run_sweep
grep -qxF 'https://github.com/o/plain/pull/8' "$T/state/merge-sweep-done.txt" && ok \
  || bad "a real merge on a non-queue repo must still be recorded (done-file)"
# The close is a REST PATCH on the ISSUE now (BH-784), not `gh issue close`, so
# the argv this asserts on names the resource that had to be closed.
grep -q 'PATCH repos/o/plain/issues/8' "$T/issue-calls.txt" && ok \
  || bad "a real merge on an issue-driven project must still close the issue (got: $(cat "$T/issue-calls.txt"))"
# TEST-CHANGE (BH-1715): this used to pin --delete-branch on the non-queue gh
# line. Real gh deletes the head ref without retargeting the PRs stacked on it,
# and GitHub closes them, so the flag is gone; the branch is deleted children
# first through bin/lib/gh-pr-merge.sh (tests/branch-delete-order.bh-1715-test.sh E).
grep -q -- "--delete-branch" "$T/merge-calls.txt" \
  && bad "the gh fallback must not pass --delete-branch, on any repo (got: $(cat "$T/merge-calls.txt"))" || ok
[ -s "$T/prearm-calls.txt" ] && ok || bad "pre-arm-guards.sh must still run on a non-queue repo"
grep -q 'MERGED https://github.com/o/plain/pull/8' "$T/logs/merge-sweep.log" && ok \
  || bad "a real merge must still log MERGED (log: $(cat "$T/logs/merge-sweep.log"))"

echo "merge-sweep-async-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
