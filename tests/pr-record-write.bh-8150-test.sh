#!/bin/bash
# tests/pr-record-write.bh-8150-test.sh — BH-8150 (C1 of BH-8067): the fleet's
# own GitHub writes update its PR record. bin/lib/pr-record-write.sh
# (prr_write, prr_note_push) and the write sites in bin/lib/mc/*.sh,
# bin/merge-queue.sh, bin/lib/rb/pr.sh, bin/lib/rb-pr-labels.sh and
# bin/lib/rb-full-ci-label.sh, driven over real curl against the REAL jobs
# worker (tests/lib/gh-budget-worker.bh-6974.mjs) and a stub `gh` first on
# PATH that logs every call and answers from per-case files in $GHT.
#
#   W1  labels POST answering [a,b]: rc 0, stdout identical, record labels [a,b]
#   W2  labels DELETE answering []: record labels []
#   W3  comment answering {id:123}: last_comment_id 123
#   W4  `gh pr comment` URL #issuecomment-987: 987; a #discussion_r55 URL: no write
#   W5  the @mergifyio verb table, near misses included
#   W6  the command fails (rc 1, stderr boom): rc 1, stderr exactly boom, no row
#   W7  no jobs client loaded: the command runs, 0 worker requests
#   W8  a dead worker: two writes in one process, one failed request, one log
#       line, both rc 0; the second sends nothing
#   W9  PR_RECORD_WRITES=0: 0 worker requests; =yes: written, one log line
#   W10 push note: new sha resets checks; same sha keeps them; no sha: no write
#   W11 at is taken BEFORE the write: a webhook that lands during the write wins;
#       a push note older than a webhook PUT is stale
#   W12 labels kind, empty stdout: no write
#   W13 stdout bytes pass through exactly (with and without a trailing newline)
#   W14 a site file sourced with the writer lib absent: the write still runs
#   W15 a bad slug or number: the command runs, no write
#   S1  mc_mergify_command "@mergifyio queue": queue_state requested + comment id
#   S2  mc_dequeue_label: labels from the DELETE answer
#   S3  mc_label_remove: labels from the DELETE answer
#   S4  mc_cr_dequeue: labels and queue_state dequeue_requested
#   S5  mc_close_for_rebuild: last_comment_id, then state closed
#   S6  mc_retarget_base: base_ref and base_sha from the PATCH answer
#   S7  mq_land (extracted by its markers): queue_state merge_requested
#   S8  prl_apply then fcl_apply: labels equal the stub's final set
#   S9  rb/pr.sh's preview-QA comment line: last_comment_id 987
#   B1  budget: every worker request went to 127.0.0.1, gh is the stub
#   B2  no GitHub read added: the gh log of each case holds only its writes
#       (plus the reads the function made before this ticket)
#
# Run from anywhere: tests/pr-record-write.bh-8150-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRV="$REPO/tests/lib/gh-budget-worker.bh-6974.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or git missing"; exit 0; }
# The worker imports these git-ignored renders; a fresh checkout has none.
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" --root "$REPO" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$REPO/bin/llm-sites-build.sh" --compose --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$REPO/bin/context-budgets-build.sh" --repo "$REPO" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/tmp"
for L in bin/lib/merge-conductor-lib.sh bin/jobs-client.sh bin/lib/rb-pr-labels.sh bin/lib/rb-full-ci-label.sh bin/merge-queue.sh; do
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
for L in bin/lib/merge-conductor-lib.sh bin/lib/rb-pr-labels.sh bin/lib/rb-full-ci-label.sh bin/merge-queue.sh bin/lib/rb/pr.sh; do
  ( cd "$REPO" && scratch_closure_list "$L" ) 2>/dev/null | grep -qx 'bin/lib/pr-record-write.sh' \
    && ok "the closure of $L carries bin/lib/pr-record-write.sh" || bad "the closure of $L lacks bin/lib/pr-record-write.sh"
done

export HARNESS="$H" HARNESS_SECRET=fixture-harness-secret BOX_NAME=fixture-box
export JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 JOBS_TIMEOUT=5
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR PR_RECORD_WRITES PR_RECORD_MAX_AGE_S LANE_REGISTRY
printf 'HARNESS_SECRET=fixture-harness-secret\n' > "$H/env/global.env"

# ---- the stub gh ---------------------------------------------------------------
GHT="$T/ghfx"; mkdir -p "$GHT" "$T/bin"; export GHT
cat > "$T/bin/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
case "\$*" in
  "api -i repos/"*"/labels/"*) printf 'HTTP/2 200\r\nserver: x\r\n\r\n{}'; exit 0 ;;
  "api repos/"*"/pulls/"*) exit 1 ;;
  "pr merge"*) exit 0 ;;
  "pr comment"*) cat "$GHT/prcomment"; exit 0 ;;
  "api -X POST "*"/comments"*) cat "$GHT/comment"; exit 0 ;;
  "api -X POST "*"/labels"*|"api -X DELETE "*"/labels/"*) cat "$GHT/labels"; exit 0 ;;
  "api -X PATCH "*"/pulls/"*) cat "$GHT/pull"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/bin/gh"
PATH="$T/bin:$PATH"

# ---- the worker ----------------------------------------------------------------
NOW=$(date -u +%s)
: > "$T/w.log"
node "$SRV" "$T/w.log" "$NOW" > "$T/w.port" 2> "$T/w.err" &
WPID=$!
trap 'kill $WPID 2>/dev/null; __scratch_exit_trap' EXIT
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$WPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port" 2>/dev/null)
if [ -z "$PORT" ]; then
  wait "$WPID"; rc=$?
  [ "$rc" = 3 ] && { echo "SKIP: node:sqlite unavailable"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
row() { curl -sS -H "authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/pr-records?repo=$1&number=$2" | jq -c '.row'; }
fld() { row "$1" "$2" | jq -c --arg f "$3" '.[$f]'; }
wreq() { wc -l < "$T/w.log" | tr -d ' '; }
LOG="$H/logs/pr-record.log"
SHA_A=$(printf 'a%.0s' $(seq 40)); SHA_B=$(printf 'b%.0s' $(seq 40))

# case <name> — fresh per-case answers, gh log and latch dir (TMPDIR), so no
# case reads another's state and the cases run in any order.
case_start() {
  rm -f "$GHT"/*; : > "$T/gh.log"
  export TMPDIR="$T/tmp-$1"; mkdir -p "$TMPDIR"
}
# rec <cmd...> — run in a fresh subshell with the jobs client and the writer
# loaded, the way a lane has them. stdout to $T/out, stderr to $T/err, rc to $T/rc.
rec() {
  ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/pr-record-write.sh"; "$@" ) > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
# mc <cmd...> — the same, with the merge-conductor lib (and through it the writer).
mc() {
  ( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_init >/dev/null 2>&1; "$@" ) > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
emit() { printf '%s' "$1"; }

# ---- W1: labels POST ------------------------------------------------------------
case_start w1
rec prr_write fixture-org/fixture-w 201 labels - emit '[{"name":"a","id":1},{"name":"b","id":2}]'
eq "W1 rc 0" "$(cat "$T/rc")" 0
eq "W1 stdout is the command's stdout" "$(cat "$T/out")" '[{"name":"a","id":1},{"name":"b","id":2}]'
eq "W1 record labels [a,b]" "$(fld fixture-org/fixture-w 201 labels)" '["a","b"]'
eq "W1 last_source fleet" "$(fld fixture-org/fixture-w 201 last_source)" '"fleet"'

# ---- W2: labels DELETE answering [] -----------------------------------------------
case_start w2
rec prr_write fixture-org/fixture-w 202 labels - emit '[]'
eq "W2 an empty label set is stored as []" "$(fld fixture-org/fixture-w 202 labels)" '[]'

# ---- W3: a comment object ---------------------------------------------------------
case_start w3
rec prr_write fixture-org/fixture-w 203 comment - emit '{"id":123,"html_url":"https://github.com/o/r/pull/203#issuecomment-999"}'
eq "W3 last_comment_id from .id" "$(fld fixture-org/fixture-w 203 last_comment_id)" 123

# ---- W4: a comment URL --------------------------------------------------------------
case_start w4
rec prr_write fixture-org/fixture-w 204 comment - emit $'https://github.com/fixture-org/fixture-w/pull/204#issuecomment-987\n'
eq "W4 last_comment_id from the URL" "$(fld fixture-org/fixture-w 204 last_comment_id)" 987
W0=$(wreq)
rec prr_write fixture-org/fixture-w 205 comment - emit $'https://github.com/fixture-org/fixture-w/pull/205#discussion_r55\n'
eq "W4 a #discussion_r URL: no worker request" "$(wreq)" "$W0"
eq "W4 a #discussion_r URL: no row" "$(row fixture-org/fixture-w 205)" null

# ---- W5: the mergify verb table ---------------------------------------------------
case_start w5
w5() { rec prr_mergify_extra "$1"; eq "W5 '$(head -1 <<<"$1")' -> $2" "$(cat "$T/out")" "$2"; }
w5 '@mergifyio queue' '{"queue_state":"requested"}'
w5 '@mergifyio requeue' '{"queue_state":"requested"}'
w5 '@mergifyio dequeue' '{"queue_state":"dequeue_requested"}'
w5 $'@mergifyio dequeue\n\n<!-- tag -->' '{"queue_state":"dequeue_requested"}'
w5 '@MergifyIO queue' '{"queue_state":"requested"}'
w5 '@mergifyio refresh' '-'
w5 '@mergifyio queued' '-'
w5 'the conductor will @mergifyio queue later' '-'
w5 '' '-'
rec prr_write fixture-org/fixture-w 206 comment "$(bash -c '. "$1"; prr_mergify_extra "@mergifyio queue"' _ "$H/bin/lib/pr-record-write.sh")" emit '{"id":61}'
eq "W5 a queue comment: queue_state requested" "$(fld fixture-org/fixture-w 206 queue_state)" '"requested"'
eq "W5 a queue comment: last_comment_id" "$(fld fixture-org/fixture-w 206 last_comment_id)" 61

# ---- W6: the command fails ----------------------------------------------------------
case_start w6
failer() { printf 'boom' >&2; printf '[{"name":"x"}]'; return 1; }
W0=$(wreq)
rec prr_write fixture-org/fixture-w 207 labels - failer
eq "W6 rc 1 kept" "$(cat "$T/rc")" 1
eq "W6 stderr is exactly the command's" "$(cat "$T/err")" boom
eq "W6 0 worker requests" "$(wreq)" "$W0"
eq "W6 no row" "$(row fixture-org/fixture-w 207)" null
rec prr_write fixture-org/fixture-w 207 labels - bash -c 'exit 44'
eq "W6 rc 44 kept" "$(cat "$T/rc")" 44

# ---- W7: no jobs client in the caller -------------------------------------------
case_start w7
printf '[{"name":"a"}]' > "$GHT/labels"
W0=$(wreq)
( . "$H/bin/lib/pr-record-write.sh"
  prr_write fixture-org/fixture-w 208 labels - gh api -X POST repos/fixture-org/fixture-w/issues/208/labels -f 'labels[]=a' ) > "$T/out" 2>&1
eq "W7 rc 0" "$?" 0
eq "W7 the gh write ran" "$(grep -c '^api -X POST repos/fixture-org/fixture-w/issues/208/labels' "$T/gh.log")" 1
eq "W7 0 worker requests" "$(wreq)" "$W0"
eq "W7 the answer still passed through" "$(cat "$T/out")" '[{"name":"a"}]'
eq "W7 no row" "$(row fixture-org/fixture-w 208)" null

# ---- W8: a dead worker sets the latch once -----------------------------------------
case_start w8
: > "$LOG"; : > "$H/logs/jobs-client.log"
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/pr-record-write.sh"
  export JOBS_URL="http://127.0.0.1:9"
  prr_write fixture-org/fixture-w 209 labels - emit '[{"name":"a"}]'; echo "rc1=$?"
  r=$(prr_write fixture-org/fixture-w 210 labels - emit '[{"name":"b"}]'); echo "rc2=$? out2=$r" ) > "$T/out" 2>&1
grep -q '^\[{"name":"a"}\]rc1=0$' "$T/out" && ok "W8 the first write: stdout and rc 0" || bad "W8 first: $(cat "$T/out")"
grep -q '^rc2=0 out2=\[{"name":"b"}\]$' "$T/out" && ok "W8 the second write (in a \$(...)): stdout and rc 0" || bad "W8 second: $(cat "$T/out")"
eq "W8 one failed request" "$(grep -c 'PUT /api/pr-records transport' "$H/logs/jobs-client.log")" 1
eq "W8 one log line" "$(grep -c 'put=failed' "$LOG")" 1
grep -q 'write fixture-org/fixture-w#209 labels put=failed (curl_rc=[0-9]*): record writes off for pid [0-9]*$' "$LOG" \
  && ok "W8 the line names the repo, the kind and the latch" || bad "W8 log: $(cat "$LOG")"
TMPDIR="$T/tmp-w8" bash -c '. "$1/bin/jobs-client.sh" >/dev/null 2>&1; . "$1/bin/lib/pr-record-write.sh"
  prr_write fixture-org/fixture-w 211 labels - printf "[{\"name\":\"c\"}]"' _ "$H" >/dev/null 2>&1
eq "W8 another process (a new pid, same TMPDIR) is not latched" "$(fld fixture-org/fixture-w 211 labels)" '["c"]'

# ---- W9: the knob --------------------------------------------------------------
case_start w9
: > "$LOG"; W0=$(wreq)
PR_RECORD_WRITES=0 rec prr_write fixture-org/fixture-w 212 labels - emit '[{"name":"a"}]'
eq "W9 =0: rc 0" "$(cat "$T/rc")" 0
eq "W9 =0: 0 worker requests" "$(wreq)" "$W0"
PR_RECORD_WRITES=yes rec prr_write fixture-org/fixture-w 213 labels - emit '[{"name":"a"}]'
eq "W9 =yes: the record is written" "$(fld fixture-org/fixture-w 213 labels)" '["a"]'
eq "W9 =yes: one log line names yes" "$(grep -c "PR_RECORD_WRITES='yes'" "$LOG")" 1

# ---- W10: the push note ---------------------------------------------------------
case_start w10
GR="$T/repo"; mkdir -p "$GR"
( cd "$GR" && git init -q -b main && git -c user.email=f@fixture.invalid -c user.name=fixture commit -q --allow-empty -m one \
  && git -c user.email=f@fixture.invalid -c user.name=fixture commit -q --allow-empty -m two )
NEW=$(git -C "$GR" rev-parse HEAD); OLD=$(git -C "$GR" rev-parse HEAD~1)
rec pr_record_put fixture-org/fixture-w 214 webhook '{"checks":{"ci":{"conclusion":"success"}},"mergeable_state":"clean"}' "$(date -u -d '-60 sec' +%FT%TZ)"
rec prr_note_push fixture-org/fixture-w 214 "$(date -u +%FT%TZ)" "$GR" HEAD "$OLD"
eq "W10 new sha: rc 0" "$(cat "$T/rc")" 0
eq "W10 new sha: head_sha" "$(fld fixture-org/fixture-w 214 head_sha)" "\"$NEW\""
eq "W10 new sha: checks reset" "$(fld fixture-org/fixture-w 214 checks)" '{}'
eq "W10 new sha: mergeable_state unknown" "$(fld fixture-org/fixture-w 214 mergeable_state)" '"unknown"'
rec pr_record_put fixture-org/fixture-w 215 webhook '{"checks":{"ci":{"conclusion":"success"}},"mergeable_state":"clean"}' "$(date -u -d '-60 sec' +%FT%TZ)"
rec prr_note_push fixture-org/fixture-w 215 "$(date -u +%FT%TZ)" "$GR" HEAD "$NEW"
eq "W10 same sha: head_sha" "$(fld fixture-org/fixture-w 215 head_sha)" "\"$NEW\""
eq "W10 same sha: checks kept" "$(fld fixture-org/fixture-w 215 checks)" '{"ci":{"conclusion":"success"}}'
eq "W10 same sha: mergeable_state kept" "$(fld fixture-org/fixture-w 215 mergeable_state)" '"clean"'
rec prr_note_push fixture-org/fixture-w 216 "$(date -u +%FT%TZ)" "$GR" no-such-ref new
eq "W10 a ref that does not resolve: rc 0" "$(cat "$T/rc")" 0
eq "W10 a ref that does not resolve: no row" "$(row fixture-org/fixture-w 216)" null
rec prr_note_push fixture-org/fixture-w 217 "" "$GR" HEAD new
eq "W10 lease new (first push): full reset" "$(fld fixture-org/fixture-w 217 checks)" '{}'

# ---- W11: ordering against webhooks --------------------------------------------
case_start w11
# A webhook for the event lands WHILE the write runs (the command sleeps past a
# second boundary, then writes as the webhook). The fleet's at was taken before
# the command, so the webhook's value stays.
hookwrite() {
  sleep 1.2
  pr_record_put fixture-org/fixture-w 218 webhook '{"labels":["from-webhook"]}' "$(date -u +%FT%TZ)" >/dev/null || return 9
  printf '[{"name":"from-fleet"}]'
}
rec prr_write fixture-org/fixture-w 218 labels - hookwrite
eq "W11 rc 0" "$(cat "$T/rc")" 0
eq "W11 the webhook that landed during the write wins" "$(fld fixture-org/fixture-w 218 labels)" '["from-webhook"]'
T0=$(date -u +%s)
rec pr_record_put fixture-org/fixture-w 219 webhook '{"checks":{"ci":{"conclusion":"failure"}}}' "$(date -u -d "@$((T0 + 5))" +%FT%TZ)"
rec prr_note_push fixture-org/fixture-w 219 "$(date -u -d "@$T0" +%FT%TZ)" "$GR" HEAD "$OLD"
eq "W11 a push note older than a webhook keeps the webhook's checks" "$(fld fixture-org/fixture-w 219 checks)" '{"ci":{"conclusion":"failure"}}'
eq "W11 ... and still writes head_sha" "$(fld fixture-org/fixture-w 219 head_sha)" "\"$NEW\""

# ---- W12: an empty answer -------------------------------------------------------
case_start w12
W0=$(wreq)
rec prr_write fixture-org/fixture-w 220 labels - true
eq "W12 rc 0" "$(cat "$T/rc")" 0
eq "W12 empty stdout: 0 worker requests" "$(wreq)" "$W0"
rec prr_write fixture-org/fixture-w 220 labels - emit '{"message":"Validation Failed"}'
eq "W12 an error object with rc 0: 0 worker requests" "$(wreq)" "$W0"
rec prr_write fixture-org/fixture-w 220 pull - emit '{"message":"Not Found"}'
eq "W12 a pull kind error object: 0 worker requests" "$(wreq)" "$W0"

# ---- W13: stdout bytes ------------------------------------------------------------
case_start w13
rec prr_write fixture-org/fixture-w 221 none - printf 'x\n'
printf 'x\n' > "$T/want"; cmp -s "$T/out" "$T/want" && ok "W13 'x\\n' passes through byte for byte" || bad "W13 x\\n: $(od -c "$T/out")"
rec prr_write fixture-org/fixture-w 221 none - printf 'x'
printf 'x' > "$T/want"; cmp -s "$T/out" "$T/want" && ok "W13 'x' (no newline) passes through byte for byte" || bad "W13 x: $(od -c "$T/out")"
rec prr_write fixture-org/fixture-w 221 none - printf 'a\n\n'
printf 'a\n\n' > "$T/want"; cmp -s "$T/out" "$T/want" && ok "W13 trailing blank lines are kept" || bad "W13 a\\n\\n: $(od -c "$T/out")"

# ---- W14: the writer lib is absent --------------------------------------------
case_start w14
mkdir -p "$T/nolib"
( cd "$REPO" && scratch_install_closure bin/lib/rb-full-ci-label.sh "$T/nolib" ) >/dev/null 2>&1 || bad "W14 setup: could not install the closure"
rm -f "$T/nolib/bin/lib/pr-record-write.sh" "$T/nolib/bin/lib/pr-record.sh"
[ -e "$T/nolib/bin/lib/pr-record-write.sh" ] && bad "W14 setup: the writer lib is still there"
printf '[{"name":"full-ci"}]' > "$GHT/labels"
W0=$(wreq)
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$T/nolib/bin/lib/rb-full-ci-label.sh"
  type prr_write | grep -q 'shift 4' || echo "NOT-THE-FALLBACK"
  FULL_CI_LABEL=full-ci fcl_apply fixture "https://github.com/fixture-org/fixture-w/pull/222" "" main "$T/w14.plog" ) > "$T/out" 2>&1
eq "W14 the pass-through fallback is what loaded" "$(grep -c NOT-THE-FALLBACK "$T/out")" 0
eq "W14 the label write still ran" "$(grep -c '^api -X POST repos/fixture-org/fixture-w/issues/222/labels -f labels\[\]=full-ci$' "$T/gh.log")" 1
grep -q "labelled https://github.com/fixture-org/fixture-w/pull/222 'full-ci'" "$T/w14.plog" && ok "W14 the caller saw rc 0" || bad "W14 plog: $(cat "$T/w14.plog")"
eq "W14 0 worker requests" "$(wreq)" "$W0"
( type prr_write >/dev/null 2>&1; . "$T/nolib/bin/lib/rb-full-ci-label.sh"; prr_write a b c d bash -c 'exit 7' ); eq "W14 the fallback keeps the rc" "$?" 7

# ---- W15: bad args -----------------------------------------------------------------
case_start w15
W0=$(wreq)
rec prr_write owner 223 labels - emit '[{"name":"a"}]'
eq "W15 slug 'owner': the command ran" "$(cat "$T/out")" '[{"name":"a"}]'
rec prr_write fixture-org/fixture-w 12a labels - emit '[{"name":"a"}]'
eq "W15 number 12a: rc 0" "$(cat "$T/rc")" 0
rec prr_write fixture-org/fixture-w 0 labels - emit '[{"name":"a"}]'
eq "W15 bad args: 0 worker requests" "$(wreq)" "$W0"

# ---- S1: mc_mergify_command ---------------------------------------------------------
case_start s1
printf '{"id":7001}' > "$GHT/comment"
mc mc_mergify_command fixture-org/fixture-s 301 "@mergifyio queue"
eq "S1 rc 0" "$(cat "$T/rc")" 0
eq "S1 queue_state requested" "$(fld fixture-org/fixture-s 301 queue_state)" '"requested"'
eq "S1 last_comment_id" "$(fld fixture-org/fixture-s 301 last_comment_id)" 7001
eq "S1 B2: only the write call" "$(wc -l < "$T/gh.log" | tr -d ' ') $(grep -c '^api -X POST repos/fixture-org/fixture-s/issues/301/comments' "$T/gh.log")" "1 1"
mc mc_mergify_command fixture-org/fixture-s 302 "@mergifyio refresh"
eq "S1 a refresh: last_comment_id only, no queue_state" "$(row fixture-org/fixture-s 302 | jq -c '[.queue_state,.last_comment_id]')" '[null,7001]'

# ---- S2: mc_dequeue_label -----------------------------------------------------------
case_start s2
printf 'mergify' > "$H/tmp/merge-queue-fixture-org_fixture-s.provider"
printf '[{"name":"ai-build"}]' > "$GHT/labels"
mc mc_dequeue_label https://github.com/fixture-org/fixture-s/pull/303
eq "S2 labels from the DELETE answer" "$(fld fixture-org/fixture-s 303 labels)" '["ai-build"]'
# mc_queue_provider's repo reads (rulesets, .mergify.yml) are the function's
# own, from before this ticket: none of them reads the PR.
eq "S2 B2: one write, no read of the PR" "$(grep -cE '^api -X DELETE ' "$T/gh.log") $(grep -cE '(issues|pulls)/303' "$T/gh.log")" "1 1"

# ---- S3: mc_label_remove ------------------------------------------------------------
case_start s3
printf '[{"name":"ai-build"},{"name":"hotfix"}]' > "$GHT/labels"
mc mc_label_remove https://github.com/fixture-org/fixture-s/pull/304 needs-human
eq "S3 rc 0" "$(cat "$T/rc")" 0
eq "S3 labels from the DELETE answer" "$(fld fixture-org/fixture-s 304 labels)" '["ai-build","hotfix"]'
eq "S3 B2: only the write call" "$(cat "$T/gh.log")" "api -X DELETE repos/fixture-org/fixture-s/issues/304/labels/needs-human"

# ---- S4: mc_cr_dequeue --------------------------------------------------------------
case_start s4
printf '[{"name":"ai-build"}]' > "$GHT/labels"; printf '{"id":7004}' > "$GHT/comment"
mc mc_cr_dequeue fixture-org/fixture-s fixture-s#305 https://github.com/fixture-org/fixture-s/pull/305 "$SHA_A" 1 $'x\tfixture-lead\t2026-10-23T00:00:00Z\tcr-1@fixture'
eq "S4 rc 0" "$(cat "$T/rc")" 0
eq "S4 labels from the DELETE answer" "$(fld fixture-org/fixture-s 305 labels)" '["ai-build"]'
eq "S4 queue_state dequeue_requested" "$(fld fixture-org/fixture-s 305 queue_state)" '"dequeue_requested"'
eq "S4 last_comment_id" "$(fld fixture-org/fixture-s 305 last_comment_id)" 7004
eq "S4 B2: only the two write calls" "$(grep -cE '^(api|pr) ' "$T/gh.log") $(grep -cE '^api -X (DELETE|POST) ' "$T/gh.log")" "2 2"

# ---- S5: mc_close_for_rebuild ------------------------------------------------------
case_start s5
printf '{"id":7005}' > "$GHT/comment"
jq -nc --arg s "$SHA_B" '{state:"closed",merged_at:null,draft:false,head:{ref:"ticket/fixture-s5",sha:$s},base:{ref:"main",sha:$s},mergeable_state:"unknown",labels:[{name:"ai-build"}]}' > "$GHT/pull"
mc mc_close_for_rebuild fixture-org/fixture-s 306 "closing for a rebuild"
eq "S5 rc 0" "$(cat "$T/rc")" 0
eq "S5 last_comment_id" "$(fld fixture-org/fixture-s 306 last_comment_id)" 7005
eq "S5 state closed from the PATCH answer" "$(fld fixture-org/fixture-s 306 state)" '"closed"'
eq "S5 head_sha from the PATCH answer" "$(fld fixture-org/fixture-s 306 head_sha)" "\"$SHA_B\""
eq "S5 B2: the writes plus the one hold read it made before" "$(grep -vc '^api -X ' "$T/gh.log") $(grep -c '^api -X ' "$T/gh.log")" "1 2"

# ---- S6: mc_retarget_base -----------------------------------------------------------
case_start s6
jq -nc --arg a "$SHA_A" --arg b "$SHA_B" '{state:"open",merged_at:null,draft:false,head:{ref:"ticket/fixture-s6",sha:$a},base:{ref:"ticket/parent",sha:$b}}' > "$GHT/pull"
mc mc_retarget_base fixture-org/fixture-s 307 ticket/parent
eq "S6 rc 0" "$(cat "$T/rc")" 0
eq "S6 base_ref from the PATCH answer" "$(fld fixture-org/fixture-s 307 base_ref)" '"ticket/parent"'
eq "S6 base_sha from the PATCH answer" "$(fld fixture-org/fixture-s 307 base_sha)" "\"$SHA_B\""
eq "S6 state open" "$(fld fixture-org/fixture-s 307 state)" '"open"'
eq "S6 B2: only the write call" "$(cat "$T/gh.log")" "api -X PATCH repos/fixture-org/fixture-s/pulls/307 -f base=ticket/parent"

# ---- S7: mq_land ------------------------------------------------------------------
case_start s7
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' "$H/bin/merge-queue.sh" > "$T/mqland.sh"
grep -q 'prr_write "$SLUG" "$num" none' "$T/mqland.sh" && ok "S7 the mq_land block carries the record write" || bad "S7 the mq_land block was not extracted"
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/pr-record-write.sh"
  SLUG=fixture-org/fixture-s; PROJECT=fixture; LOG="$T/mq.log"; STAMP() { date -u +%FT%TZ; }
  hb_sha() { :; }
  . "$T/mqland.sh"; mq_land 308 "$SHA_A" ) > "$T/out" 2>&1
eq "S7 queue_state merge_requested" "$(fld fixture-org/fixture-s 308 queue_state)" '"merge_requested"'
eq "S7 B2: only the merge verb" "$(cat "$T/gh.log")" "pr merge 308 -R fixture-org/fixture-s --squash --match-head-commit $SHA_A"

# ---- S8: prl_apply then fcl_apply --------------------------------------------------
case_start s8
jq -nc '{body:"PR-Labels: area-x"}' > "$T/meta.json"
printf '[{"name":"ai-build"},{"name":"area-x"}]' > "$GHT/labels"
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/rb-pr-labels.sh"
  prl_apply fixture https://github.com/fixture-org/fixture-s/pull/309 "$T/meta.json" "$T/s8.plog" ) >/dev/null 2>&1
eq "S8 after prl_apply: labels from its POST answer" "$(fld fixture-org/fixture-s 309 labels)" '["ai-build","area-x"]'
printf '[{"name":"ai-build"},{"name":"area-x"},{"name":"full-ci"}]' > "$GHT/labels"
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/rb-full-ci-label.sh"
  FULL_CI_LABEL=full-ci fcl_apply fixture https://github.com/fixture-org/fixture-s/pull/309 "" main "$T/s8.plog" ) >/dev/null 2>&1
eq "S8 after fcl_apply: the stub's final set" "$(fld fixture-org/fixture-s 309 labels)" '["ai-build","area-x","full-ci"]'
eq "S8 B2: the one label read prl_apply made before, and two writes" "$(grep -c '^api -i ' "$T/gh.log") $(grep -c '^api -X POST ' "$T/gh.log") $(wc -l < "$T/gh.log" | tr -d ' ')" "1 2 3"

# ---- S9: rb/pr.sh's preview-QA comment line ---------------------------------------
case_start s9
printf 'https://github.com/fixture-org/fixture-s/pull/310#issuecomment-987\n' > "$GHT/prcomment"
RBP="$REPO/bin/lib/rb/pr.sh"
{ grep -E '^PRR_(SLUG|NUM)=' "$RBP"; grep -E '^ *prr_write "\$PRR_SLUG" "\$PRR_NUM" comment - gh pr comment ' "$RBP"; } > "$T/s9.sh"
eq "S9 the three lines came out of bin/lib/rb/pr.sh" "$(wc -l < "$T/s9.sh" | tr -d ' ')" 3
mkdir -p "$T/s9b"; printf 'QA: FAIL\n' > "$T/s9b/qa.md"
( . "$H/bin/jobs-client.sh" >/dev/null 2>&1; . "$H/bin/lib/pr-record-write.sh"
  PR_URL=https://github.com/fixture-org/fixture-s/pull/310 QA_MODEL=fixture-model BUILD="$T/s9b"
  . "$T/s9.sh" ) > "$T/out" 2>&1
eq "S9 last_comment_id 987" "$(fld fixture-org/fixture-s 310 last_comment_id)" 987
eq "S9 the URL still printed" "$(cat "$T/out")" "https://github.com/fixture-org/fixture-s/pull/310#issuecomment-987"
eq "S9 B2: only the comment write" "$(grep -c '^pr comment https://github.com/fixture-org/fixture-s/pull/310 --body' "$T/gh.log") $(grep -cE '^(api|pr) ' "$T/gh.log")" "1 1"

# ---- B1: budget -----------------------------------------------------------------
case "$JOBS_URL" in http://127.0.0.1:*) ok "B1 every worker request went to 127.0.0.1" ;; *) bad "B1 JOBS_URL is $JOBS_URL" ;; esac
eq "B1 gh resolves to the stub" "$(command -v gh)" "$T/bin/gh"

echo "pr-record-write.bh-8150: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
