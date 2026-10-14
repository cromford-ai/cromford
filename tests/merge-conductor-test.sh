#!/bin/bash
# tests/merge-conductor-test.sh — the merge conductor's END-TO-END tick and its
# observe-only contract (docs/MERGE-CONDUCTOR.md).
#
# WHAT IS STILL HERE, AFTER BH-684. This suite used to carry the whole lib: 17
# numbered sections, 319 cases, 1,919 lines. When bin/lib/merge-conductor-lib.sh
# became a shim over bin/lib/mc/, the sections that exercise ONE module moved,
# verbatim, to the suite named for that module — and nothing was dropped on the
# way (the count is asserted in the PR that moved them):
#   tests/mc/classify-test.sh   the classifier, transitions, CI state, the red
#                               ladder and the stuck detector      (150 cases)
#   tests/mc/rebase-test.sh     detached re-reviews and rebases, stacked
#                               children, the restack, the CI kick (126 cases)
#   tests/mc/queue-test.sh      isInMergeQueue and the main-red freeze (20)
#   tests/mc/settle-test.sh     the closed-list settle pass and its budget (6)
# What stays here is the thing none of them is: the WHOLE script, driven once,
# end to end, and the contract that it writes nothing to GitHub.
#
# WHY DRIVEN AND NOT GREPPED. The claims under test are about control flow:
# which state each shape of PR lands in, that a moved head is HEAD_MOVED and
# not READY, that the kill switch and the absent flags leave GitHub untouched,
# and that a transition logs exactly once. `grep -q HEAD_MOVED bin/...` passes
# just as happily on a classifier that never reaches the branch.
#
# gh, curl (the jobs client), agent-call, beat and fleet-conf are stubbed; the
# gh stub records every argv and FAILS the run on any write verb, so an
# observe-only tick that merged, pushed, commented or closed would fail here
# rather than on a real repo.
# Run from anywhere: tests/merge-conductor-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
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

# ============================================================================
# 0. The scratch tree every section below runs in
# ============================================================================
# fixture: tests/lib/fixture-harness.sh (BH-1196) — what is copied into the
# scratch harness, and why each file is there, is documented in the lib.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/mc" ] || exit 1   # impact: this suite runs when bin/lib/mc/ changes (bin/test-impact.sh reads rooted tokens)
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
H1=aaaaaaaa1111; H2=bbbbbbbb2222

# ============================================================================
# 3. The whole script, observe-only: states from stubbed gh, NO write verb
# ============================================================================
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\nissuer example-org/issuer - - 3 box-issuer\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
: # flock is NOT stubbed: the per-PR lock shard is the thing under test
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
# A build record for PR 11 (APPROVE bound to head H1) and PR 12 (APPROVE bound to
# H1 while its head is H2 = moved). PR 13 has no record but a ticket/ branch.
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001" "$T/h/builds/pool-demo-os-TK-12-202609120002"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$T/h/builds/pool-demo-os-TK-12-202609120002/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/pool-demo-os-TK-12-202609120002/review.md"
echo "$H1" > "$T/h/builds/pool-demo-os-TK-12-202609120002/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
# Both list branches answer --json arrays: since #329 the conductor asks
# bin/lib/gh-pr-list.sh for the list (once per HARNESS_PR_AUTHORS login) and
# does its own jq, so a stub that pre-extracted TSV would be answering a
# question the conductor no longer asks.
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H1","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"},
 {"number":14,"url":"https://github.com/example-org/demo-os/pull/14","headRefOid":"$H1","headRefName":"fix/by-hand","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/demo-os/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":15,"html_url":"https://github.com/example-org/demo-os/pull/15","title":"TK-15","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/TK-15","sha":"deadbee"},"base":{"ref":"main"}}]
JR
    ;;
  *"pr list -R example-org/issuer --state open"*) echo "[]" ;;
  # TEST-CHANGE (BH-782): the CLOSED list is all-mappable, so it is a REST read
  # (bin/lib/gh-rest.sh) and a REST failure is no longer retried over
  # a GraphQL pr list. The shim answers the REST path with a status line and a
  # REST-shaped body; the open list still carries GraphQL-only fields
  # (mergeStateStatus/mergeable/isInMergeQueue) and is unchanged.
  *"repos/example-org/issuer/pulls?state=closed"*)
    printf 'HTTP/2.0 200\r\n\r\n'
    cat <<'JR'
[{"number":7,"html_url":"https://github.com/example-org/issuer/pull/7","title":"IS-7","body":"","state":"closed","merged_at":null,"closed_at":"2026-09-12T01:00:00Z","created_at":"2026-09-11T00:00:00Z","updated_at":"2026-09-12T01:00:00Z","draft":false,"labels":[],"user":{"login":"operator","type":"User"},"head":{"ref":"ticket/is-7","sha":"deadbe7"},"base":{"ref":"main"}}]
JR
    ;;
  # THE ISSUE STATE IS A REST READ NOW (BH-784): gh api -i -X GET, judged on the
  # HTTP status line restpr prints. This replaces the "issue view 7" arm, which
  # was the GraphQL spelling of the same read and no caller makes any more.
  # (No backticks anywhere in this heredoc: it EXPANDS, comments included, and a
  # backtick in a comment is a command substitution that runs the REAL gh.)
  *"api -i -X GET repos/example-org/issuer/issues/7") restpr --raw 200 '{"state":"open"}' ;;
  # TEST-CHANGE (BH-1592): the settle reads a candidate by number now.
  *"api -i -X GET repos/example-org/issuer/pulls/7") restpr CLOSED deadbe7 ticket/is-7 main "" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11") restpr OPEN "$H1" ticket/TK-11 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12") restpr OPEN "$H2" ticket/TK-12 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/13") restpr OPEN "$H1" ticket/TK-13 main "" CONFLICTING DIRTY ;;
  # PR 14 is the hand-cut branch: its body is the only test left that can say
  # whether it is a harness PR, and it must not carry run-build's marker.
  *"api -i -X GET repos/example-org/demo-os/pulls/14") restpr OPEN "$H1" fix/by-hand main "" MERGEABLE CLEAN somebody "" "plain body" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/15") restpr CLOSED "$H1" ticket/TK-15 main "" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  # BH-1606: the seeded lead_pr_authors row. The conductor's lead fence fails
  # CLOSED on an unreadable row (#1603), so a fixture that 404s it merges nothing.
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  # The jobs ledger's answer for one PR. A 404 (no job recorded this PR) is the
  # default and is what every case below 4j runs on; 4j drops a row in the file
  # to drive mc_job_running through the real client.
  "GET "*/api/verdict*) if [ -s "${JOBROW:-/nonexistent}" ]; then printf '%s\n200\n' "$(cat "$JOBROW")"
                        else printf '{"error":"not found"}\n404\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x REQ_SINK="$T/req.txt" JOBROW="$T/ledger-job.json" "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
# TEST-CHANGE (BH-1592): the closed-unmerged settle no longer walks the repo's
# raw closed list; it reads the PR numbers the harness already holds. demo-os#15
# and issuer#7 were reachable only through that walk, so they get the pr-state
# rows an earlier tick would have written while they were open. The assertions
# on them below are unchanged.
printf 'example-org/demo-os#15\tWAIT_CI\t1\t-\t-\t-\t-\thttps://github.com/example-org/demo-os/pull/15\nexample-org/issuer#7\tWAIT_CI\t1\t-\t-\t-\t-\thttps://github.com/example-org/issuer/pull/7\n' \
  >> "$T/h/state/merge-conductor/pr-state.tsv"
: > "$T/gh-calls.txt"; : > "$T/req.txt"
run_tick
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
[ "$(state_of 'example-org/demo-os#11')" = READY ]        && ok || bad "PR 11 (approved at head, clean, green) must be READY (got $(state_of 'example-org/demo-os#11'))"
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ]   && ok || bad "PR 12 (approved at $H1, head $H2) must be HEAD_MOVED (got $(state_of 'example-org/demo-os#12'))"
[ "$(state_of 'example-org/demo-os#13')" = NEEDS_REBASE ] && ok || bad "PR 13 (ticket/ branch, no record, no verdict, DIRTY) must go NEEDS_REBASE — the rebase comes before the review (got $(state_of 'example-org/demo-os#13'))"
[ -z "$(state_of 'example-org/demo-os#14')" ]             && ok || bad "PR 14 (hand branch, no record) must not get a row"
grep -q 'demo-os#14 not a harness PR' "$T/h/logs/merge-conductor.log" && ok || bad "a hand PR is logged once as not-harness"
[ "$(state_of 'example-org/demo-os#15')" = CLOSED ]       && ok || bad "closed-unmerged harness PR must be CLOSED"
[ "$(state_of 'example-org/issuer#7')" = CLOSED ]         && ok || bad "closed-unmerged issue PR must be CLOSED"
grep -q 'issuer#7 CLOSED' "$T/h/logs/ALERTS.log" && ok || bad "closed-unmerged with an OPEN issue must alert once"
grep -q 'demo-os#15 CLOSED' "$T/h/logs/ALERTS.log" && bad "a board project's closed PR must not claim the ticket is open" || ok
[ -s "$T/gh-writes.txt" ] && bad "observe-only tick used a write verb: $(cat "$T/gh-writes.txt")" || ok
grep -q 'PUT .*/api/ledger .*pr_state' "$T/req.txt" && ok || bad "rows must reach the ledger as kind=pr_state"
grep -q '"key":"example-org/demo-os#11"' "$T/req.txt" && ok || bad "ledger key must be owner/repo#N"
N1=$(grep -c 'demo-os#11 - -> READY' "$T/h/logs/merge-conductor.log")
run_tick
N2=$(grep -c 'demo-os#11' "$T/h/logs/merge-conductor.log")
[ "$N1" = 1 ] && [ "$N2" = 1 ] && ok || bad "a second identical tick must log no new transition (first=$N1 total=$N2)"

# 3b. flags on, kill switch present: still no write verb
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge" "$T/h/flags/automerge-disabled"
: > "$T/gh-writes.txt"; run_tick
[ -s "$T/gh-writes.txt" ] && bad "kill switch present but a write verb ran: $(cat "$T/gh-writes.txt")" || ok
[ "$(state_of 'example-org/demo-os#11')" = READY ] && ok || bad "states must keep updating under the kill switch"
rm -f "$T/h/flags/automerge-disabled"
# 3c. actions+merge on, observe pin present: still no write verb
touch "$T/h/flags/merge-conductor-observe"; : > "$T/gh-writes.txt"; run_tick
[ -s "$T/gh-writes.txt" ] && bad "observe pin present but a write verb ran: $(cat "$T/gh-writes.txt")" || ok
rm -f "$T/h/flags/merge-conductor-observe"
# 3d. merge flag WITHOUT actions flag: refused, logged
rm -f "$T/h/flags/merge-conductor-actions"; : > "$T/gh-writes.txt"; run_tick
[ -s "$T/gh-writes.txt" ] && bad "merge without actions ran a write verb" || ok
grep -q 'merge flag set without the actions flag' "$T/h/logs/merge-conductor.log" && ok || bad "merge-without-actions must be logged as refused"

# 3f. BH-1585 review round 2 (B3): a row the open list marks UNVERIFIABLE (its
#     own per-PR merge-state read failed) is not a state. The worker returns
#     before anything reads, classifies or writes: the row is byte-for-byte what
#     it was, nothing is written to GitHub, and the tick says so in ONE line.
#     The bridge fails the list's read of #11 only (a 502, not a rate limit), so
#     the rest of the repo's list still stands.
ROW11=$(grep -F 'example-org/demo-os#11	' "$T/h/state/merge-conductor/pr-state.tsv")
M=$(wc -l < "$T/h/logs/merge-conductor.log"); : > "$T/gh-writes.txt"; : > "$T/gh-calls.txt"
printf '11\n' > "$T/lazy-fail"
run_tick env GH_LIST_BRIDGE_FAIL_LAZY="$T/lazy-fail"
rm -f "$T/lazy-fail"
NEW11=$(tail -n +"$((M+1))" "$T/h/logs/merge-conductor.log" | grep -F 'demo-os#11 ')
grep -q 'pulls?state=open' "$T/gh-calls.txt" && ok || bad "3f: the tick must have read the open list (this case would otherwise prove nothing)"
[ "$(grep -c . <<<"$NEW11")" = 1 ] && grep -q 'merge state UNVERIFIABLE this tick' <<<"$NEW11" \
  && ok || bad "3f: an UNVERIFIABLE row must produce exactly ONE log line, saying so (got: $NEW11)"
[ "$(grep -F 'example-org/demo-os#11	' "$T/h/state/merge-conductor/pr-state.tsv")" = "$ROW11" ] \
  && ok || bad "3f: an UNVERIFIABLE row must be left exactly as it was (was '$ROW11')"
grep -qE 'v3\.diff' "$T/gh-calls.txt" && grep -q 'v3.diff' <<<"$(grep -F 'pulls/11' "$T/gh-calls.txt")" \
  && bad "3f: an UNVERIFIABLE row must not be read further (a diff read of #11 was made)" || ok
[ -s "$T/gh-writes.txt" ] && bad "3f: an UNVERIFIABLE row must cause no GitHub write: $(cat "$T/gh-writes.txt")" || ok
[ "$(state_of 'example-org/demo-os#12')" = HEAD_MOVED ] && ok || bad "3f: the rest of the repo's list still stands (#12 got $(state_of 'example-org/demo-os#12'))"

# 3e. merge mode, for real (stubbed): READY PR 11 merges with --match-head-commit, once
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
# Both list branches answer --json arrays: since #329 the conductor asks
# bin/lib/gh-pr-list.sh for the list (once per HARNESS_PR_AUTHORS login) and
# does its own jq, so a stub that pre-extracted TSV would be answering a
# question the conductor no longer asks.
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge https://github.com/example-org/demo-os/pull/11 --squash --match-head-commit $H1"*) touch "$T/merged11"; exit 0 ;;
  *"pr merge"*) echo "wrong merge form: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  # ONE REST read now answers what state, headRefOid and mergeCommit used to take
  # three gh pr view calls to say. MERGED is state "closed" WITH merged_at set,
  # which is how GitHub really answers it — restpr owns that shape.
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11")
    if [ -f "$T/merged11" ]; then restpr MERGED "$H1" ticket/TK-11 main "" MERGEABLE CLEAN app/cromford cccccccc3333
    else restpr OPEN "$H1" ticket/TK-11 main "" MERGEABLE CLEAN app/cromford ""; fi ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
rm -f "$T/merged11"; : > "$T/gh-writes.txt"
run_tick env MC_MERGE_SETTLE=0
[ -f "$T/merged11" ] && ok || bad "merge mode must merge the READY PR with --squash --match-head-commit <head>"
[ -s "$T/gh-writes.txt" ] && bad "$(cat "$T/gh-writes.txt")" || ok
[ "$(state_of 'example-org/demo-os#11')" = MERGED ] && ok || bad "after the merge the row must be MERGED (got $(state_of 'example-org/demo-os#11'))"
grep -q 'MERGED example-org/demo-os#11 by conductor' "$T/h/logs/merge-conductor.log" && ok || bad "the merge must log MERGED … by conductor"
grep -qxF 'https://github.com/example-org/demo-os/pull/11' "$T/h/state/merge-sweep-done.txt" && ok || bad "a conductor merge must be ledgered where the sweep looks (merge-sweep-done.txt)"


echo "merge-conductor-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
