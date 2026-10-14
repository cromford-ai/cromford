#!/bin/bash
# tests/merge-sweep-invisible-repo-test.sh — two 2026-09-12 rules in bin/merge-sweep.sh:
#   * a PR whose repo NO gh token can see is an ALERT (once per repo per day)
#     and a logged skip, never a silent `continue` — the shape that hid six
#     approved project-5 PRs for days
#   * after a tier-2 merge on an issue-driven project the sweep comments on and
#     closes the issue itself (a squash by another actor may not carry the
#     body's "Closes #n", and an open issue is invisible to the box's gate)
# The sweep is copied standalone into a scratch tree and driven with a gh shim,
# exactly like tests/head-bound-approval-test.sh does.
# Run from anywhere: tests/merge-sweep-invisible-repo-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin" "$T/env"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
# Since BH-784 every decision read in the sweep goes through the conductor lib
# and bin/lib/gh-rest.sh. Both have to be in the scratch box's bin/lib or the
# sweep's fail-closed shims answer "unverifiable" to every read and no PR is
# ever swept.
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
for stub in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/bin/$stub"; chmod +x "$T/bin/$stub"; done
printf '#!/bin/bash\nexit 2\n' > "$T/bin/pre-arm-guards.sh"; chmod +x "$T/bin/pre-arm-guards.sh"
# fleet-conf: project ts owns o/r; its board prefix comes from $T/prefix
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ") echo ts ;;
  "ts repo") echo "o/r" ;;
  "ts board_prefix") cat "$T/prefix" ;;
esac
SH
chmod +x "$T/bin/fleet-conf.sh"
# gh shim: $T/blind makes o/r invisible to every token; everything else is a happy CLEAN PR.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/o/r -q .id")  [ -f "$T/blind" ] && { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }; exit 0 ;;
  # An empty rate_limit answer leaves bin/lib/gh-budget.sh a 0-byte cache file
  # and a later sweep in this scratch tree dies on it mid-tick.
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # THE DECISION READS ARE REST (BH-784): gh api -i -X GET repos/o/r/pulls/7,
  # judged on the HTTP status line, so restpr prints a whole response. The diff
  # shares that path and is told apart by its Accept header, so it matches FIRST.
  # The post-merge re-read is the same GET: gh's exit code is not a landing (on a
  # merge-queue repo the same call only enqueues), so the sweep asks GitHub, and
  # the answer carries the merge sha the record is stamped with.
  *"v3.diff"*) restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/o/r/pulls/7"*)
    if [ -s "$MERGE_SINK" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"pr merge"*)           echo merged >> "$MERGE_SINK"; exit 0 ;;
  # The issue close-out: a comment POST whose body travels as a FILE (never on
  # argv), the close PATCH, and the re-read gh_rest_close does before it reports
  # the close landed. The body file is copied into its own sink so the assertion
  # can still read what the comment said.
  *"api -i -X POST repos/o/r/issues/"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >> "$ISSUE_BODY_SINK"; echo >> "$ISSUE_BODY_SINK" ;; esac; done
    restpr --raw 200 '{"id":1}' ;;
  *"api -i -X PATCH repos/o/r/issues/"*) restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/o/r/issues/"*)   restpr --raw 200 '{"state":"closed"}' ;;
  *)                      echo "" ;;
esac
SH
chmod +x "$T/fakebin/gh"
# worker stub: no ledger rows at all (rc 2 everywhere) -> the record decides
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

setup() { # setup <board-prefix>
  rm -rf "$T/builds"; mkdir -p "$T/builds/pool-ts-TK-269-202609120001"
  echo "PR_CREATED https://github.com/o/r/pull/7" > "$T/builds/pool-ts-TK-269-202609120001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/builds/pool-ts-TK-269-202609120001/review.md"
  : > "$T/builds/pool-ts-TK-269-202609120001/pipeline.log"
  echo "$1" > "$T/prefix"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merges.txt"; : > "$T/gh.txt"; : > "$T/issue-body.txt"
}
sweep() {
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" T="$T" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid JOBS_BOX=b \
           MERGE_SINK="$T/merges.txt" GH_SINK="$T/gh.txt" ISSUE_BODY_SINK="$T/issue-body.txt"; unset GH_TOKEN
    bash "$T/bin/sweep.sh" >/dev/null 2>"$T/err.txt" )
}

# 1. invisible repo: ALERT + logged skip, no merge, NOT ledgered (it lands the day the token can see it)
setup "-"; touch "$T/blind"; rm -f "$T"/flags/alerted-repo-invisible-*
sweep
grep -q "\[merge-sweep\] repo o/r is INVISIBLE to the default gh token (the admin token cannot see it either) — its approved PRs are SKIPPED, not swept" "$T/logs/ALERTS.log" \
  && ok || bad "no invisible-repo ALERT: $(cat "$T/logs/ALERTS.log") err=$(cat "$T/err.txt")"
grep -q "pull/7 skipped: its repo is invisible to every gh token" "$T/logs/merge-sweep.log" && ok || bad "the skip was not logged: $(cat "$T/logs/merge-sweep.log")"
[ ! -s "$T/merges.txt" ] && ok || bad "merged through an invisible repo?"
grep -q "pull/7" "$T/state/merge-sweep-done.txt" && bad "an invisible-repo skip was ledgered — it can never land" || ok
grep -q admintok "$T/logs/ALERTS.log" "$T/logs/merge-sweep.log" && bad "token value leaked into a log" || ok
# 1b. next tick same day: skip logged again, ALERT not repeated
sweep
[ "$(grep -c INVISIBLE "$T/logs/ALERTS.log")" = 1 ] && [ "$(grep -c "skipped: its repo is invisible" "$T/logs/merge-sweep.log")" -ge 2 ] \
  && ok || bad "dedup: ALERTS=$(grep -c INVISIBLE "$T/logs/ALERTS.log") log=$(grep -c invisible "$T/logs/merge-sweep.log")"

# 2. visible again, issue-driven project: merges, then comments on and closes issue #269
setup "-"; rm -f "$T/blind"
sweep
grep -q merged "$T/merges.txt" && ok || bad "did not merge a CLEAN APPROVE: $(cat "$T/logs/merge-sweep.log") err=$(cat "$T/err.txt")"
# Same two facts, in the REST argv they are spoken in now (BH-784): the comment
# POST on issue 269 of o/r whose body names the merged PR, and the close PATCH on
# that same issue. The body is a file, so it is asserted from the body sink.
grep -q "^api -i -X POST repos/o/r/issues/269/comments" "$T/gh.txt" \
  && grep -q "^Merged in https://github.com/o/r/pull/7" "$T/issue-body.txt" \
  && grep -q "^api -i -X PATCH repos/o/r/issues/269 " "$T/gh.txt" \
  && ok || bad "the issue was not commented+closed after the merge: $(cat "$T/gh.txt") body=$(cat "$T/issue-body.txt")"
grep -q "pull/7 closed issue #269 on o/r" "$T/logs/merge-sweep.log" && ok || bad "close not logged: $(cat "$T/logs/merge-sweep.log")"

# 3. a board project (prefix is a path): merges, touches no issue
setup "/api/board"
sweep
# Same fact, new argv: no call on the repo's ISSUES resource at all (BH-784 made
# the comment a POST and the close a PATCH under repos/o/r/issues/).
grep -q merged "$T/merges.txt" && ! grep -q "/issues/" "$T/gh.txt" \
  && ok || bad "a board project must not get issue calls: $(cat "$T/gh.txt")"

echo "merge-sweep-invisible-repo: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
