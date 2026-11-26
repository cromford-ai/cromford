#!/bin/bash
# tests/dequeue-watch-record.bh-9938-test.sh — BH-9938 (BH-9926.6): dequeue-watch
# reads the merge-queue/dequeued label lists, the Mergify payload and a MERGE
# verdict's lead-verdict status through prr_read dequeue-watch (the seam
# bin/lib/prr-shadow.d/dequeue-watch.sh), and a --dispatch makes ONE rate_limit
# judgment that its project runs take while it is fresh.
#
#   S1  labels: record and GitHub files give the same numbers and norm; a
#       changed number changes the norm
#   S2  labels misses: stale stamp, no-sync, worker fail, one list of two fails
#   S3  payload: the record line = the GitHub line (epoch aside) for a dequeued
#       payload, and the norms are equal
#   S4  payload misses and edges: no row, mergify_queue null, a dequeued row
#       with no run_id key (field:run_id), run_id null (hit, run -), a queued
#       row with no run_id key (hit), a bad at (malformed), worker fail
#   S7-S10 (BH-9938 C1, the C0 review notes): no lead-verdict entry is a miss
#       (A2); the payload epoch is updated_at and a row without it misses
#       (A3); a list of CHECKS_MAX names misses (A5); age = knob + 1 is stale
#       (PR_RECORD_FIELD_MAX_AGE_S, default 3900) for the payload and the
#       status reads (A7)
#   L5  step record with no lead-verdict entry: 3 misses, 3 GitHub status
#       reads, and no stale-status claim from the record
#   S5  status: the record maps to the combined-status shape with the GitHub
#       norm; an older head's entry only is a miss (none); a changed state
#       changes the norm
#   S6  payload norm: a changed run, state or cid changes it; the epoch does not
#   L1  step record: one tick over 5 labelled PRs with fresh records (3
#       dequeued and already owned, 2 queued) makes 0 GitHub calls
#   L2  step shadow: a record run_id changed on 1 PR logs exactly 1 PRR_SHADOW
#       line, and every event row carries GitHub's run id
#   L3  step off: today's GitHub calls (2 label lists, 5 comment lists, 3
#       comment reads) and no record list, payload or status read
#   L4  step record, a pre-BH-9938 row (no run_id): PRR_MISS why=field:run_id
#       fallback=github, and that PR's comments are read from GitHub
#   B1  --dispatch over 3 projects: exactly 1 `gh api rate_limit`, 3 project
#       summary lines
#   B2  a project run with a handoff older than the knob reads its own (1);
#       one just inside the knob reads none; one from the future reads its own
#   B3  a fresh handoff rc 0: the `gh-budget project=<p>` summary, 0 gh calls
#   B4  a handoff rc `abc` or 3 is ignored: the run reads its own budget
#   B5  a dispatch with no project in fleet.conf makes no rate_limit read
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/dequeue-watch-record.bh-9938-test.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FX="$REPO/tests/fixtures/dequeue-watch"
SEAM="$FX/pr-record-list.bh-9938.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $CASE: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: got '$2', wanted '$3'"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1795600000                        # a fixed clock (2026-11-24T08:26:40Z); D60
AT_ISO=$(date -u -d "@$((NOW - 120))" +%FT%TZ)
SLUG=example-org/cromford
LSLUG=example-org/cromford
HEAD=b49a1b832b0d294ee7a46325ac2ace79dc50d235
OTHER=0123456789abcdef0123456789abcdef01234567
H="$T/h"; F="$T/fix"; LOG="$H/logs/dequeue-watch.log"; REQ="$F/requests.log"; SHADOW="$H/logs/prr-shadow.log"
CASE=setup

mkdir -p "$H" "$T/shim"
cp -rs "$REPO/bin" "$H/bin"
cp -rs "$REPO/catalog" "$H/catalog"
for s in lane-alert lead-verdict needs-human-hold box-for agent-call alert-line; do
  rm -f "$H/bin/$s.sh"
  {
    echo '#!/bin/bash'
    echo 'printf "SCRIPT %s %s\n" "$(basename "$0")" "$*" >> "$DQW_FIX_DIR/requests.log"'
  } > "$H/bin/$s.sh"
  chmod +x "$H/bin/$s.sh"
done
echo 'echo box-2' >> "$H/bin/box-for.sh"
cat > "$T/shim/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$DQW_FIX_DIR/requests.log"
case "$1 $2" in
  "api rate_limit")
    echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":1},"graphql":{"remaining":4000,"limit":5000,"reset":1}}}'
    exit 0 ;;
  "api --paginate")
    n=$(printf '%s' "$3" | sed -n 's#.*/issues/\([0-9]*\)/comments.*#\1#p')
    [ -r "$DQW_FIX_DIR/comments-$n.json" ] && exec cat "$DQW_FIX_DIR/comments-$n.json" ;;
  "run view") [ -r "$DQW_FIX_DIR/log-$3.txt" ] && exec cat "$DQW_FIX_DIR/log-$3.txt" ;;
esac
exit 1
EOF
chmod +x "$T/shim/gh"

# ── fixture writers ───────────────────────────────────────────────────────────
rest() { mkdir -p "$F/rest"; cat > "$F/rest/$(printf '%s' "$1" | tr '/?&=' '____')"; }
# gh_lists <dequeued nums> -- <queued nums>: GitHub's two label lists.
gh_lists() {
  local dq=() qd=() seen=0 a
  for a in "$@"; do if [ "$a" = -- ]; then seen=1; elif [ "$seen" = 0 ]; then dq+=("$a"); else qd+=("$a"); fi; done
  { printf '%s\n' "${dq[@]}" | jq -c '{number: (. | tonumber), pull_request: {url: "x"}, labels: [{name: "merge-queue"}, {name: "dequeued"}]}'
    [ "${#qd[@]}" = 0 ] || printf '%s\n' "${qd[@]}" | jq -c '{number: (. | tonumber), pull_request: {url: "x"}, labels: [{name: "merge-queue"}]}'
  } | jq -sc . | rest "repos/$SLUG/issues?labels=merge-queue&state=open&per_page=100"
  printf '%s\n' "${dq[@]}" | jq -sc 'map({number: (. | tonumber), pull_request: {url: "x"}, labels: [{name: "merge-queue"}, {name: "dequeued"}]})' \
    | rest "repos/$SLUG/issues?labels=dequeued&state=open&per_page=100"
}
# rec_list <dequeued nums> -- <queued nums>: the record's open list (labels as stored).
rec_list() {
  local dq=() qd=() seen=0 a
  for a in "$@"; do if [ "$a" = -- ]; then seen=1; elif [ "$seen" = 0 ]; then dq+=("$a"); else qd+=("$a"); fi; done
  mkdir -p "$F/records"
  { printf '%s\n' "${dq[@]}" | jq -c '{number: (. | tonumber), title: "t", labels: ["merge-queue", "dequeued"]}'
    [ "${#qd[@]}" = 0 ] || printf '%s\n' "${qd[@]}" | jq -c '{number: (. | tonumber), title: "t", labels: ["merge-queue"]}'
  } | jq -sc . > "$F/records/list-open.json"
  echo 0 > "$F/records/list.age"
}
# payload <num> <payload-file>: GitHub's comment list and the comment.
payload() {
  jq -n --rawfile b "$2" --arg at "$AT_ISO" --argjson n "$1" \
    '[{id: (9000 + $n), user: {login: "mergify[bot]"}, body: $b, created_at: $at, updated_at: $at}]' > "$F/comments-$1.json"
  jq -n --rawfile b "$2" '{body: $b}' | rest "repos/$SLUG/issues/comments/$((9000 + $1))"
}
# rec <num> <state> [run_id JSON | nokey] [statuses-state] — the record row.
rec() {
  local n="$1" st="$2" run="${3:-5001}" sst="${4:-success}" mq
  mkdir -p "$F/records"
  if [ "$st" = dequeued ]; then
    mq=$(jq -nc --argjson n "$n" --arg at "$AT_ISO" --arg h "$HEAD" \
      '{state: "dequeued", code: null, draft_pr: 201, failing_checks: ["Pure-logic gate fixtures"], left_sha: $h, comment_id: (9000 + $n), at: $at, updated_at: $at}')
  else
    mq=$(jq -nc --argjson n "$n" --arg at "$AT_ISO" --arg s "$st" \
      '{state: $s, code: null, draft_pr: null, failing_checks: [], left_sha: null, comment_id: (9000 + $n), at: $at, updated_at: $at}')
  fi
  [ "$run" = nokey ] || mq=$(jq -c --argjson r "$run" '. + {run_id: $r}' <<<"$mq")
  jq -nc --arg r "$LSLUG" --argjson n "$n" --arg h "$HEAD" --argjson mq "$mq" --arg s "$sst" \
    '{repo: $r, number: $n, state: "open", head_sha: $h, head_ref: "ticket/bh-9\($n)", mergeable_state: "clean",
      mergify_queue: $mq,
      statuses: {"lead-verdict": {state: $s, description: "v", sha: $h, at: "2026-11-24T08:00:00Z"}}}' > "$F/records/$n.json"
  echo 0 > "$F/records/$n.age"
}
queued_md() { sed 's/"state": "dequeued"/"state": "queued"/' "$FX/payload-dequeued-batch1.md" > "$F/queued.md"; }

# base <case> <d1> <d2> <d3> <q1> <q2>: GitHub answers for 3 dequeued and 2 queued PRs, and matching records.
base() {
  CASE="$1"; shift
  D1=$1 D2=$2 D3=$3 Q1=$4 Q2=$5
  local d n
  for d in "$F" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$F/rest" "$F/records" "$H/state/merge-conductor" "$H/logs"
  : > "$REQ"
  printf 'proj %s https://example.invalid - 5 box-2\n' "$SLUG" > "$H/fleet.conf"
  gh_lists "$D1" "$D2" "$D3" -- "$Q1" "$Q2"
  rec_list "$D1" "$D2" "$D3" -- "$Q1" "$Q2"
  queued_md
  for n in "$D1" "$D2" "$D3"; do
    payload "$n" "$FX/payload-dequeued-batch1.md"
    jq -nc --arg h "$HEAD" --arg r "ticket/bh-9$n" '{head: {sha: $h, ref: $r}, mergeable_state: "clean"}' | rest "repos/$SLUG/pulls/$n"
    rest "repos/$SLUG/pulls/$n/files?per_page=100" < "$FX/pr-files-101.json"
    rec "$n" dequeued
  done
  for n in "$Q1" "$Q2"; do payload "$n" "$F/queued.md"; rec "$n" queued; done
  rest "repos/$SLUG/actions/runs?event=push&per_page=100" < "$FX/runs-batch1.json"
  cp "$FX/log-rule-break.txt" "$F/log-5001.txt"
  jq -n --arg c "$(base64 -w0 < "$FX/sources-lib-root.txt")" '{content: $c, encoding: "base64"}' \
    | rest "repos/$SLUG/contents/tests/lib-root-literal-ratchet.bh-2613-test.sh?ref=main"
  echo MERGE > "$F/verdict"
  echo '{"statuses":[{"context":"lead-verdict","state":"success","updated_at":"2026-11-24T08:00:00Z"}]}' | rest "repos/$SLUG/commits/$HEAD/status"
}

lastsum() { grep -E '^[0-9-]+T[0-9:]+Z (tick |off$|disabled$|locked|gh-budget|lib-missing )' "$LOG" 2>/dev/null | tail -1; }
cnt() { grep -cF -- "$1" "$REQ" 2>/dev/null || true; }
ghcalls() { grep -cE '^(REST |gh )' "$REQ" 2>/dev/null || true; }
shadow_lines() { grep -cE " PRR_SHADOW lane=dequeue-watch " "$SHADOW" 2>/dev/null || true; }
misses() { if [ -e "$SHADOW" ]; then grep -c ' PRR_MISS lane=dequeue-watch ' "$SHADOW" || true; else echo 0; fi; }
run_lane() {   # run_lane <GH_SOURCE> [env...]
  local src="$1"; shift
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret-fixture \
    HARNESS_TEST_SANDBOX=1 DEQUEUE_WATCH_FIXTURE="$SEAM" DQW_FIX_DIR="$F" DEQUEUE_WATCH_ACT=1 GH_SOURCE="$src" "$@" \
    bash "$H/bin/dequeue-watch.sh" > "$T/lane.out" 2> "$T/lane.err"
  RC=$?
  [ "$RC" = 0 ] && ok || bad "the lane exited $RC: $(head -c 600 "$T/lane.err")"
}

# ── S: the seam functions, sourced on the same fixture ────────────────────────
CASE=S0
bash -n "$REPO/bin/lib/prr-shadow.d/dequeue-watch.sh" && ok || bad "the seam bin/lib/prr-shadow.d/dequeue-watch.sh does not parse"
# seam <fn> <args...> — one seam call in a subshell with the fixture's fakes;
# stdout of the call to $T/s.out, the file arg is $T/s.file, rc to $T/s.rc.
seam() {
  ( export HARNESS="$H" DQW_FIX_DIR="$F" DQW_TMP="$T/dqwtmp" HARNESS_TEST_SANDBOX=1
    unset GH_SOURCE PR_RECORD_LIST_MAX_AGE_S
    mkdir -p "$DQW_TMP"
    # shellcheck source=/dev/null
    . "$H/bin/lib/pr-record.sh"; . "$H/bin/lib/mc-stale-dequeue.sh"; . "$H/bin/lib/dequeue-watch/attribute.sh"
    . "$H/bin/lib/dequeue-watch/gather.sh"; . "$H/bin/lib/prr-shadow.sh"; prr_seam_load dequeue-watch || exit 9
    . "$SEAM"
    PATH="$T/shim:$PATH"
    "$@" > "$T/s.out" 2>/dev/null; echo $? > "$T/s.rc" )
}
src() { cat "$T/s.rc"; }
out() { cat "$T/s.out"; }
norm() { seam "$1" "$2"; out; }

base S1 401 402 403 404 405
seam dqw_labels_record "$T/s.rec" "$SLUG";   eq "S1 record rc" "$(src)" 0
seam dqw_labels_github "$T/s.gh" "$SLUG";    eq "S1 github rc" "$(src)" 0
FILT='add | map(select(.pull_request != null) | select([.labels[]?.name] | (index("queued") or index("checking")) | not)) | unique_by(.number) | [.[].number] | join(" ")'
eq "S1 record numbers" "$(jq -rs "$FILT" "$T/s.rec")" "401 402 403 404 405"
eq "S1 github numbers" "$(jq -rs "$FILT" "$T/s.gh")" "401 402 403 404 405"
NR=$(norm dqw_labels_norm "$T/s.rec"); NG=$(norm dqw_labels_norm "$T/s.gh")
eq "S1 norms equal" "$NR" "$NG"
eq "S1 norm shape" "$NR" '[{"n":401},{"n":402},{"n":403},{"n":404},{"n":405}]'
rec_list 401 402 403 -- 404 406
seam dqw_labels_record "$T/s.rec2" "$SLUG"
[ "$(norm dqw_labels_norm "$T/s.rec2")" != "$NG" ] && ok || bad "S1 a changed number left the norm equal"

CASE=S2
echo 901 > "$F/records/list.age"
seam dqw_labels_record "$T/s.rec" "$SLUG";  eq "S2 stale" "$(src):$(out)" "1:stale"
rm -f "$F/records/list-open.json"
seam dqw_labels_record "$T/s.rec" "$SLUG";  eq "S2 no-sync" "$(src):$(out)" "1:no-sync"
rec_list 401 402 403 -- 404 405
touch "$F/records/FAIL"
seam dqw_labels_record "$T/s.rec" "$SLUG";  eq "S2 worker fail" "$(src):$(out)" "1:unreadable"
rm -f "$F/records/FAIL" "$F/records/list.calls"
: > "$REQ"
LIST_FAIL_AFTER=1 seam dqw_labels_record "$T/s.rec" "$SLUG"; eq "S2 the second list fails" "$(src):$(out)" "1:unreadable"
eq "S2 2 list GETs" "$(cnt "JOBS GET /api/pr-records?repo=$LSLUG&state=open&need=labels")" 2
rm -f "$F/records/list.calls"
unrest_list() { rm -f "$F/rest/$(printf '%s' "repos/$SLUG/issues?labels=dequeued&state=open&per_page=100" | tr '/?&=' '____')"; }
unrest_list
seam dqw_labels_github "$T/s.gh" "$SLUG";  eq "S2 github: an unread list is rc 1" "$(src)" 1

base S3 411 412 413 414 415
seam dqw_payload_record "$T/s.rec" "$SLUG" 411;  eq "S3 record rc" "$(src)" 0
seam dqw_payload_github "$T/s.gh" "$SLUG" 411;   eq "S3 github rc" "$(src)" 0
eq "S3 github line (epoch aside)" "$(cut -f1,3- "$T/s.gh")" "$(printf 'dequeued\t9411\t201\t5001\t%s\tPure-logic gate fixtures' "$HEAD")"
eq "S3 record line = github line (epoch aside)" "$(cut -f1,3- "$T/s.rec")" "$(cut -f1,3- "$T/s.gh")"
eq "S3 record epoch is the record at" "$(cut -f2 "$T/s.rec")" "$((NOW - 120))"
NR=$(norm dqw_payload_norm "$T/s.rec"); NG=$(norm dqw_payload_norm "$T/s.gh")
eq "S3 norms equal" "$NR" "$NG"
seam dqw_payload_record "$T/s.rec" "$SLUG" 414;  eq "S3 queued record" "$(src):$(cut -f1,3- "$T/s.rec")" "$(printf '0:queued\t9414\t-\t-\t-\t-')"
seam dqw_payload_github "$T/s.gh" "$SLUG" 414;   eq "S3 queued github" "$(src):$(cut -f1,3- "$T/s.gh")" "$(printf '0:queued\t9414\t-\t-\t-\t-')"
eq "S3 queued norms equal" "$(norm dqw_payload_norm "$T/s.rec")" "$(norm dqw_payload_norm "$T/s.gh")"

CASE=S4
seam dqw_payload_record "$T/s.rec" "$SLUG" 499;  eq "S4 no row" "$(src):$(out)" "1:unknown"
jq -c '.mergify_queue = null' "$F/records/412.json" > "$F/records/x" && mv "$F/records/x" "$F/records/412.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 412;  eq "S4 mergify_queue null" "$(src):$(out)" "1:none"
rec 413 dequeued nokey
seam dqw_payload_record "$T/s.rec" "$SLUG" 413;  eq "S4 a dequeued row with no run_id key" "$(src):$(out)" "1:field:run_id"
rec 413 dequeued null
seam dqw_payload_record "$T/s.rec" "$SLUG" 413;  eq "S4 run_id null is a hit, run -" "$(src):$(cut -f4,5 "$T/s.rec")" "$(printf '0:201\t-')"
rec 415 queued nokey
seam dqw_payload_record "$T/s.rec" "$SLUG" 415;  eq "S4 a queued row with no run_id key is a hit" "$(src):$(cut -f1 "$T/s.rec")" "0:queued"
jq -c '.mergify_queue.at = "yesterday"' "$F/records/411.json" > "$F/records/x" && mv "$F/records/x" "$F/records/411.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 411;  eq "S4 a bad at" "$(src):$(out)" "1:malformed"
rec 411 dequeued
jq -c '.mergify_queue.left_sha = "b49a1b8"' "$F/records/411.json" > "$F/records/x" && mv "$F/records/x" "$F/records/411.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 411;  eq "S4 a short left sha is -, as the GitHub parse" "$(src):$(cut -f6 "$T/s.rec")" "0:-"
touch "$F/records/FAIL"
seam dqw_payload_record "$T/s.rec" "$SLUG" 411;  eq "S4 worker fail" "$(src):$(out)" "1:unreadable"
rm -f "$F/records/FAIL"

base S5 421 422 423 424 425
seam dqw_status_record "$T/s.rec" "$SLUG" 421 "$HEAD"; eq "S5 record rc" "$(src)" 0
eq "S5 record shape" "$(jq -c '.statuses' "$T/s.rec")" '[{"context":"lead-verdict","state":"success","updated_at":"2026-11-24T08:00:00Z"}]'
seam dqw_status_github "$T/s.gh" "$SLUG" 421 "$HEAD"; eq "S5 github rc" "$(src)" 0
NR=$(norm dqw_status_norm "$T/s.rec"); NG=$(norm dqw_status_norm "$T/s.gh")
eq "S5 norms equal" "$NR" "$NG"
eq "S5 norm shape" "$NR" '[{"n":"lead-verdict","v":"success"}]'
rec 422 dequeued 5001 failure
seam dqw_status_record "$T/s.rec" "$SLUG" 422 "$HEAD"
[ "$(norm dqw_status_norm "$T/s.rec")" != "$NG" ] && ok || bad "S5 a changed state left the norm equal"
# BH-9938 C1: asking a head that is not the row's head is the miss `head`;
# a row at that head whose entries are all for an older head is `none`.
seam dqw_status_record "$T/s.rec" "$SLUG" 421 "$OTHER"; eq "S5 a head that is not the row's head" "$(src):$(out)" "1:head"
jq -c --arg o "$OTHER" '.head_sha = $o' "$F/records/421.json" > "$F/records/x" && mv "$F/records/x" "$F/records/421.json"
seam dqw_status_record "$T/s.rec" "$SLUG" 421 "$OTHER"; eq "S5 only an older head's entry" "$(src):$(out)" "1:none"

# ── S7-S10: the BH-9938 C1 review notes (A2, A3, A5, A7) ─────────────────────
base S7 471 472 473 474 475
# A2: the record holds only harness-verdict for the head: a miss, never "no verdict".
jq -c --arg h "$HEAD" '.statuses = {"harness-verdict": {state: "success", description: "v", sha: $h, at: "2026-11-24T08:00:00Z"}}' \
  "$F/records/471.json" > "$F/records/x" && mv "$F/records/x" "$F/records/471.json"
seam dqw_status_record "$T/s.rec" "$SLUG" 471 "$HEAD"; eq "S7 no lead-verdict entry is a miss" "$(src):$(out)" "1:field:lead-verdict"
# A3: the epoch is updated_at, the time sdq_payload_last reads; a row without it misses.
jq -c '.mergify_queue.updated_at = "2026-11-24T08:30:00Z"' "$F/records/472.json" > "$F/records/x" && mv "$F/records/x" "$F/records/472.json"
jq '.[0].updated_at = "2026-11-24T08:30:00Z"' "$F/comments-472.json" > "$F/x" && mv "$F/x" "$F/comments-472.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 472; eq "S8 record rc" "$(src)" 0
seam dqw_payload_github "$T/s.gh" "$SLUG" 472;  eq "S8 github rc" "$(src)" 0
eq "S8 record epoch = GitHub epoch (the edit time)" "$(cut -f2 "$T/s.rec")" "$(cut -f2 "$T/s.gh")"
eq "S8 the epoch is the edit time" "$(cut -f2 "$T/s.rec")" "$(date -u -d 2026-11-24T08:30:00Z +%s)"
jq -c 'del(.mergify_queue.updated_at)' "$F/records/473.json" > "$F/records/x" && mv "$F/records/x" "$F/records/473.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 473; eq "S8 a row with no updated_at misses" "$(src):$(out)" "1:field:updated_at"
# A5: a failing-check list as long as the worker's cut may be cut: a miss.
jq -c '.mergify_queue.failing_checks = [range(100) | "c\(.)"]' "$F/records/471.json" > "$F/records/x" && mv "$F/records/x" "$F/records/471.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 471; eq "S9 a list of 100 names misses" "$(src):$(out)" "1:field:failing_checks"
jq -c '.mergify_queue.failing_checks = [range(99) | "c\(.)"]' "$F/records/471.json" > "$F/records/x" && mv "$F/records/x" "$F/records/471.json"
seam dqw_payload_record "$T/s.rec" "$SLUG" 471; eq "S9 a list of 99 names is a hit" "$(src)" 0
# A7: the age check on the payload and the status reads (PR_RECORD_FIELD_MAX_AGE_S, default 3900).
echo 3901 > "$F/records/474.age"
seam dqw_payload_record "$T/s.rec" "$SLUG" 474; eq "S10 payload: age = knob + 1 is stale" "$(src):$(out)" "1:stale"
seam dqw_status_record "$T/s.rec" "$SLUG" 474 "$HEAD"; eq "S10 status: age = knob + 1 is stale" "$(src):$(out)" "1:stale"
echo 3900 > "$F/records/474.age"
seam dqw_payload_record "$T/s.rec" "$SLUG" 474; eq "S10 payload: age = knob is a hit" "$(src)" 0
seam dqw_status_record "$T/s.rec" "$SLUG" 474 "$HEAD"; eq "S10 status: age = knob is a hit" "$(src)" 0

CASE=S6
printf 'dequeued\t100\t9\t201\t5001\t%s\tx\n' "$HEAD" > "$T/n1"
printf 'dequeued\t999\t9\t201\t5001\t%s\tx\n' "$HEAD" > "$T/n2"
eq "S6 the epoch is not compared" "$(norm dqw_payload_norm "$T/n1")" "$(norm dqw_payload_norm "$T/n2")"
N1=$(norm dqw_payload_norm "$T/n1")
printf 'dequeued\t100\t9\t201\t5002\t%s\tx\n' "$HEAD" > "$T/n2"
[ "$(norm dqw_payload_norm "$T/n2")" != "$N1" ] && ok || bad "S6 a changed run left the norm equal"
printf 'queued\t100\t9\t-\t-\t-\t-\n' > "$T/n2"
[ "$(norm dqw_payload_norm "$T/n2")" != "$N1" ] && ok || bad "S6 a changed state left the norm equal"
printf 'dequeued\t100\t8\t201\t5001\t%s\tx\n' "$HEAD" > "$T/n2"
[ "$(norm dqw_payload_norm "$T/n2")" != "$N1" ] && ok || bad "S6 a changed cid left the norm equal"

# ── L1: step record, fresh records, 3 owned + 2 queued -> 0 GitHub calls ──────
base L1 431 432 433 434 435
run_lane off                                   # tick 1 on GitHub: the 3 dequeued PRs are claimed (owned)
eq "L1 tick 1 claims" "$(cnt 'JOBS POST /api/dequeue-watch/actions/claim ')" 3
: > "$REQ"; : > "$LOG"
scratch_rm "$F/rest" || exit 1                 # GitHub answers nothing now
rm -f "$F"/comments-*.json; mkdir -p "$F/rest"
run_lane record
eq "L1 GitHub calls" "$(ghcalls)" 0
eq "L1 owned skips" "$(grep -c 'already-owned' "$LOG")" 3
eq "L1 queued skips" "$(grep -cE "#43[45] payload says 'queued', not dequeued" "$LOG")" 2
lastsum | grep -q ' dequeued=5 ' && ok || bad "L1 summary '$(lastsum)' should say dequeued=5"
eq "L1 PRR_MISS lines" "$(misses)" 0

# ── L2: step shadow, one record run_id differs -> 1 PRR_SHADOW, GitHub's run ──
base L2 441 442 443 444 445
rec 442 dequeued 7777
run_lane shadow
eq "L2 PRR_SHADOW lines" "$(shadow_lines)" 1
grep -qE " PRR_SHADOW lane=dequeue-watch key=$SLUG#442:payload record=1 github=1 only_record=0 only_github=0 changed=1\$" "$SHADOW" \
  && ok || bad "L2 shadow line: $(cat "$SHADOW" 2>/dev/null)"
eq "L2 PRR_MISS lines" "$(misses)" 0
eq "L2 event runs" "$(jq -r '.run_id' "$F/db/events.jsonl" | sort -u | paste -sd' ')" "5001"
eq "L2 events" "$(jq -r '.pr' "$F/db/events.jsonl" | sort -u | paste -sd' ')" "441 442 443"
eq "L2 status reads on GitHub" "$(cnt "REST GET repos/$SLUG/commits/$HEAD/status")" 3

# ── L3: step off -> today's GitHub calls, no record list/payload/status read ──
base L3 451 452 453 454 455
run_lane off
eq "L3 label lists" "$(cnt "REST GET repos/$SLUG/issues?labels=")" 2
eq "L3 comment lists" "$(cnt "gh api --paginate repos/$SLUG/issues/")" 5
eq "L3 comment reads" "$(cnt "REST GET repos/$SLUG/issues/comments/")" 3
eq "L3 record list GETs" "$(cnt "JOBS GET /api/pr-records?repo=$LSLUG&state=")" 0
eq "L3 record row GETs (the BH-8269 pulls path only)" "$(cnt "JOBS GET /api/pr-records?repo=$LSLUG&number=")" 3
[ -s "$SHADOW" ] && bad "L3 prr-shadow.log: $(cat "$SHADOW")" || ok

# ── L4: step record, a pre-BH-9938 row -> field:run_id miss, GitHub comments ──
base L4 461 462 463 464 465
rec 462 dequeued nokey
run_lane record
grep -qE " PRR_MISS lane=dequeue-watch key=$SLUG#462:payload why=field:run_id fallback=github\$" "$SHADOW" \
  && ok || bad "L4 miss line: $(cat "$SHADOW" 2>/dev/null)"
eq "L4 PRR_MISS lines" "$(misses)" 1
eq "L4 comment list of 462" "$(cnt "gh api --paginate repos/$SLUG/issues/462/comments")" 1
eq "L4 comment read of 462" "$(cnt "REST GET repos/$SLUG/issues/comments/9462")" 1
eq "L4 comment lists in all" "$(cnt "gh api --paginate repos/$SLUG/issues/")" 1
eq "L4 label lists on GitHub" "$(cnt "REST GET repos/$SLUG/issues?labels=")" 0
eq "L4 event of 462 keyed on GitHub's run" "$(jq -r 'select(.pr == 462) | .run_id' "$F/db/events.jsonl")" 5001

# ── L5: step record, a record with no lead-verdict entry -> miss, GitHub's status ──
base L5 481 482 483 484 485
for n in 481 482 483; do
  jq -c --arg h "$HEAD" '.statuses = {"harness-verdict": {state: "success", description: "v", sha: $h, at: "2026-11-24T08:00:00Z"}}' \
    "$F/records/$n.json" > "$F/records/x" && mv "$F/records/x" "$F/records/$n.json"
done
run_lane record
eq "L5 PRR_MISS field:lead-verdict lines" "$(grep -c ' PRR_MISS lane=dequeue-watch key=.*:status why=field:lead-verdict fallback=github' "$SHADOW" 2>/dev/null || true)" 3
eq "L5 status reads on GitHub" "$(cnt "REST GET repos/$SLUG/commits/$HEAD/status")" 3
grep -q 'stale-status' "$LOG" && bad "L5 the lane claimed stale-status on a record miss: $(grep stale-status "$LOG" | head -2)" || ok

# ── B: the rate_limit judgment, no fixture seam (the real gh-budget lib) ──────
B="$T/b"
brun() {       # brun <out-name> [env...] -- <args...>
  local name="$1" e=()
  shift
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do e+=("$1"); shift; done
  shift
  env -i PATH="$T/shim:$PATH" HOME="$T" HARNESS="$H" JOBS_URL= HARNESS_SECRET=test-secret-fixture \
    HARNESS_TEST_SANDBOX=1 FLEET_CONF="$H/fleet.conf" DQW_FIX_DIR="$B" GH_BUDGET_DB=0 GH_BUDGET_TTL_S=0 DQW_NOW="$NOW" DEQUEUE_WATCH_ACT=0 \
    PL_DISPATCH_SPREAD_PCT=0 ${e[@]+"${e[@]}"} \
    bash "$H/bin/dequeue-watch.sh" "$@" > "$T/$name.out" 2> "$T/$name.err"
}
bbase() {
  CASE="$1"
  local d
  for d in "$B" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/tmp"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$B" "$H/logs" "$H/state"
  : > "$B/requests.log"
  { for I in 1 2 3; do printf 'bp%s o/bp%s https://example.invalid - 5 box-2\n' "$I" "$I"; done; } > "$H/fleet.conf"
}
rl() { grep -c '^gh api rate_limit' "$B/requests.log" 2>/dev/null || true; }
psum() { grep -cE "^[0-9-]+T[0-9:]+Z (tick |gh-budget).* project=bp[123]\$" "$H/logs/dequeue-watch.log" 2>/dev/null || true; }

bbase B1
brun b1 -- --dispatch
i=0; until [ "$(psum)" -ge 3 ] || [ "$i" -ge 300 ]; do sleep 0.2; i=$((i + 1)); done
eq "B1 project summary lines" "$(psum)" 3
eq "B1 rate_limit calls" "$(rl)" 1
# The runs are detached: wait (bounded) until none is alive before the next case.
i=0; while pgrep -f "$H/bin/dequeue-watch.sh" >/dev/null 2>&1 && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i + 1)); done

bbase B2
brun b2 DQW_GH_BUDGET_RC=1 "DQW_GH_BUDGET_AT=$((NOW - 60))" -- bp1
eq "B2 a handoff 60 s old (knob 60) reads its own" "$(rl)" 1
: > "$B/requests.log"
brun b2b DQW_GH_BUDGET_RC=1 "DQW_GH_BUDGET_AT=$((NOW - 59))" -- bp1
eq "B2 a handoff 59 s old reads none" "$(rl)" 0
brun b2c DQW_GH_BUDGET_RC=1 "DQW_GH_BUDGET_AT=$((NOW + 5))" -- bp1
eq "B2 a handoff from the future reads its own" "$(rl)" 1
: > "$B/requests.log"
brun b2d GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S=0 DQW_GH_BUDGET_RC=1 "DQW_GH_BUDGET_AT=$NOW" -- bp1
eq "B2 the knob at 0: every process reads" "$(rl)" 1

bbase B3
brun b3 DQW_GH_BUDGET_RC=0 "DQW_GH_BUDGET_AT=$NOW" -- bp2
grep -qE "^[0-9-]+T[0-9:]+Z gh-budget project=bp2\$" "$H/logs/dequeue-watch.log" && ok \
  || bad "B3 no gh-budget summary: $(tail -3 "$H/logs/dequeue-watch.log" 2>/dev/null)"
eq "B3 gh calls" "$(grep -c '^gh ' "$B/requests.log" || true)" 0

bbase B4
brun b4 DQW_GH_BUDGET_RC=abc "DQW_GH_BUDGET_AT=$NOW" -- bp1
eq "B4 rc abc: its own read" "$(rl)" 1
: > "$B/requests.log"
brun b4b DQW_GH_BUDGET_RC=3 "DQW_GH_BUDGET_AT=$NOW" -- bp1
eq "B4 rc 3: its own read" "$(rl)" 1
: > "$B/requests.log"
brun b4c DQW_GH_BUDGET_RC=1 DQW_GH_BUDGET_AT=x -- bp1
eq "B4 a non-digit time: its own read" "$(rl)" 1

bbase B5
printf '# no project\n' > "$H/fleet.conf"
brun b5 -- --dispatch
eq "B5 no project, no rate_limit read" "$(rl)" 0

echo "dequeue-watch-record.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
