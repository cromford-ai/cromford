#!/bin/bash
# tests/mq-no-verdict-retry.bh-6336-test.sh — BH-6336: a merge-queue batch that
# failed ONLY because a CI shard left no verdict puts its PR back in the queue
# once, with no fix round. A second no-verdict ejection of the same head pages.
#
# THE CASE (2026-10-12 22:06Z). Batch draft #6316 held PR #5443 alone. The job
# `Tests, traced (shard 5/8)` was cancelled, bin/ci-verdicts.sh printed "shard
# 5/8 left no verdict", both fan-in checks went red and Mergify ejected #5443.
# The conductor called the draft `solo`, could not attribute the job-named
# failure, never put the PR back, and marked the head a culprit.
#
# FIXTURES. The fan-in logs are written by the REAL bin/ci-verdicts.sh over a
# scratch verdict dir, then prefixed in the `gh run view --log-failed` shape
# (`<job>\t<step>\t<ts> ##[error]…`). The real #5443 dequeue comment could not
# be read from the build box (the GitHub API answered 403), so the Mergify
# comment is the REAL #4121 dequeue comment (tests/fixtures/bh-4428/), edited
# here to the incident's shape: a single-PR draft #6316, the two fan-in checks,
# and run links on run ids this suite invents (3720000000x).
#
# Part 1 sources the lib and drives the classifier (nv_run_word) over the
# decision table T1-T15. Part 2 drives the real bin/merge-conductor.sh:
#   N1  the only failure is "shard 5/8 left no verdict": one requeue, QUEUED,
#       NOVERDICT_RETRY once, an "infra retry" PR line, no culprit, no fix round
#   N2  the same head ejected again by a second no-verdict batch:
#       BLOCKED_HUMAN queue-ejected-twice, no second requeue, exactly ONE alert
#   N3  a real test failure next to the no-verdict shard: no requeue, and the
#       row ends exactly where it ends with the lib absent (today's path)
#   N4  the run's jobs cannot be read: two ticks wait with their own reason,
#       the third hands the head to today's path
#   N5  a cached verdict: a later tick reads no jobs and no log
#   N6  observe mode (MERGES=0): "would REQUEUE", nothing written
#   N7  a human `@mergifyio dequeue` after the head still wins
#   N8  a non-Actions failing check: today's rule decides on the first tick
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mq-no-verdict-retry.bh-6336-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NVLIB="$DIR/bin/lib/mc-noverdict.sh"
EJLIB="$DIR/bin/lib/mc-batch-eject.sh"
FX4428="$DIR/tests/fixtures/bh-4428"
export HARNESS="$T/h"

PURE='Pure-logic gate fixtures'
TRACE='Tests cannot touch a real harness'
TS='2026-10-12T22:06:00.0000000Z'

# fanin_log <out> <plan-result> <n> <count> <spec…> — the --log-failed text of
# both fan-in jobs, from the real bin/ci-verdicts.sh. spec per shard i, in
# order: ok | missing | fail | dirty | zero. Only a red lane's lines are kept
# (a green fan-in job is not in --log-failed).
fanin_log() {
  local out="$1" plan="$2" n="$3" count="$4" vd="$T/verdicts" i s lane job rc body
  shift 4
  scratch_rm "$vd"; mkdir -p "$vd"; : > "$out"
  i=0
  for s in "$@"; do
    case "$s" in
      ok)    printf 'tests=%s\nfailed=0\nhits=0\npure=pass\ntrace=clean\n' "$((count / n))" > "$vd/shard-$i.txt" ;;
      fail)  printf 'tests=%s\nfailed=1\nhits=0\npure=fail\ntrace=clean\n' "$((count / n))" > "$vd/shard-$i.txt" ;;
      dirty) printf 'tests=%s\nfailed=0\nhits=2\npure=pass\ntrace=dirty\n' "$((count / n))" > "$vd/shard-$i.txt" ;;
      zero)  printf 'tests=0\nfailed=0\nhits=0\npure=pass\ntrace=clean\n' > "$vd/shard-$i.txt" ;;
      missing) ;;
    esac
    i=$((i + 1))
  done
  for lane in pure trace; do
    job="$PURE"; [ "$lane" = trace ] && job="$TRACE"
    rc=0; body=$(PLAN_RESULT="$plan" bash "$DIR/bin/ci-verdicts.sh" "$lane" "$vd" "$n" "$count" 2>&1) || rc=$?
    [ "$rc" = 0 ] && continue
    { printf '%s\n' "$body"; echo '::error::Process completed with exit code 1.'; } \
      | sed 's/^::error::/##[error]/' | sed "s/^/$job\tthe verdict\t$TS /" >> "$out"
  done
}
# jobs_of <out> <job:conclusion>… — an Actions jobs page.
jobs_of() {
  local out="$1" a; shift
  for a in "$@"; do printf '%s\n' "$a"; done \
    | jq -Rsc 'split("\n") | map(select(length > 0) | capture("^(?<name>.*):(?<conclusion>[a-z]+)$") | . + {status: "completed"})
      | ([{name: "CI plan (what this run tests)", status: "completed", conclusion: "success"}] + .) | {total_count: length, jobs: .}' > "$out"
}
S5='Tests, traced (shard 5/8)'
S2='Tests, traced (shard 2/8)'
S3='Tests, traced (shard 3/8)'
FANINS_RED=("$PURE:failure" "$TRACE:failure")

# ============================================================================
# PART 1 — the classifier over the decision table (no network).
# ============================================================================
if [ -r "$NVLIB" ]; then
  (
    MC_ATTEMPTS="$T/p1-attempts.txt"; : > "$MC_ATTEMPTS"
    mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
    mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
    mc_log() { echo "$*" >> "$T/p1-log.txt"; }
    # shellcheck source=bin/lib/gh-ci-read.sh
    . "$DIR/bin/lib/gh-ci-read.sh" || exit 1
    # shellcheck source=bin/lib/mc-batch-eject.sh
    . "$EJLIB" || exit 1
    export FLAKY_LOG_MAX=200000
    gh() {
      case "$*" in
        "api repos/example-org/cromford/actions/runs/1/jobs?per_page=100")
          [ -e "$T/p1-jobsfail" ] && return 1; cat "$T/p1-jobs.json" ;;
        "run view 1 -R example-org/cromford --log-failed")
          [ -e "$T/p1-logfail" ] && return 1; cat "$T/p1-log" ;;
        *) return 1 ;;
      esac
    }
    P=0; F=0
    pok() { P=$((P+1)); }; pbad() { F=$((F+1)); echo "FAIL: $1"; }
    word() { nv_run_word example-org/cromford 1; }
    expect() { # expect <case> <want> (want: "noverdict<TAB>…", "real<TAB>-", rc2)
      local got rc=0
      got=$(word) || rc=$?
      [ "$rc" = 0 ] || got="rc$rc"
      [ "$got" = "$2" ] && pok || pbad "$1: want '$2', got '$got'"
    }
    rm -f "$T/p1-jobsfail" "$T/p1-logfail"
    # T1 (a) — the incident: shard 5 cancelled, both fan-ins say only that.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    grep -q "^$PURE	the verdict	$TS ##\[error\]shard 5/8 left no verdict" "$T/p1-log" && pok \
      || pbad "T1: bin/ci-verdicts.sh still prints the line the rule reads (got: $(cat "$T/p1-log"))"
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T1 "noverdict	5/8"
    # T2 (b) — two shards left no verdict, both jobs failed.
    fanin_log "$T/p1-log" success 8 160 ok ok missing ok ok missing ok ok
    jobs_of "$T/p1-jobs.json" "$S2:failure" "$S5:failure" "${FANINS_RED[@]}"
    expect T2 "noverdict	2/8,5/8"
    # T3 (c) — the shard job passed (its scan was rc 2): only the fan-ins failed.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    jobs_of "$T/p1-jobs.json" "$S5:success" "${FANINS_RED[@]}"
    expect T3 "noverdict	5/8"
    # T4 — the Actions log colours and CRLF-ends its lines: still read.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    sed -i $'s/##\\[error\\]/\033[31m##[error]/; s/$/\r/' "$T/p1-log"
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T4 "noverdict	5/8"
    # T5 — only one fan-in failed (the other check's step was skipped).
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    sed -i "/^$TRACE	/d" "$T/p1-log"
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "$PURE:failure"
    expect T5 "noverdict	5/8"
    # T6 (d) — N3: a real test failure on shard 2 next to the no-verdict shard 5.
    fanin_log "$T/p1-log" success 8 160 ok ok fail ok ok missing ok ok
    grep -q "shard 2/8: 1 of 20 tests failed" "$T/p1-log" && pok || pbad "T6: the fixture carries the real failure line"
    jobs_of "$T/p1-jobs.json" "$S2:failure" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T6 "real	-"
    # T7 (e) — trace hits on shard 3 next to the no-verdict shard.
    fanin_log "$T/p1-log" success 8 160 ok ok ok dirty ok missing ok ok
    jobs_of "$T/p1-jobs.json" "$S3:failure" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T7 "real	-"
    # T8 (f) — the plan job failed: no shard ran, every fan-in is red on that.
    fanin_log "$T/p1-log" failure 8 160 ok ok ok ok ok ok ok ok
    jobs_of "$T/p1-jobs.json" "CI plan (what this run tests):failure" "${FANINS_RED[@]}"
    expect T8 "real	-"
    # T9 (g) — a no-verdict shard plus a failed lint job with its own error.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    printf 'Syntax + shellcheck + config integrity\tshellcheck\t%s ##[error]bin/x.sh: SC2086\n' "$TS" >> "$T/p1-log"
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}" "Syntax + shellcheck + config integrity:failure"
    expect T9 "real	-"
    # T10 (h) — a failed shard job no no-verdict line names.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    jobs_of "$T/p1-jobs.json" "$S3:failure" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T10 "real	-"
    # T11 (i) — a failed fan-in that printed no error line at all.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    sed -i "/^$TRACE	/d" "$T/p1-log"
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T11 "real	-"
    # T12 — "ran 0 tests" on shard 4 next to the no-verdict shard.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok zero missing ok ok
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    expect T12 "real	-"
    # T13 — unread: the jobs read fails, a partial page, no failed job, the log
    #       read fails, an empty log, a log over FLAKY_LOG_MAX.
    fanin_log "$T/p1-log" success 8 160 ok ok ok ok ok missing ok ok
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    touch "$T/p1-jobsfail"; expect T13-jobs rc2; rm -f "$T/p1-jobsfail"
    jq -c '.total_count = 9' "$T/p1-jobs.json" > "$T/p1-j2" && mv "$T/p1-j2" "$T/p1-jobs.json"
    expect T13-partial rc2
    jobs_of "$T/p1-jobs.json"; expect T13-nofail rc2
    jobs_of "$T/p1-jobs.json" "$S5:cancelled" "${FANINS_RED[@]}"
    touch "$T/p1-logfail"; expect T13-log rc2; rm -f "$T/p1-logfail"
    cp "$T/p1-log" "$T/p1-log.keep"; : > "$T/p1-log"; expect T13-empty rc2
    cp "$T/p1-log.keep" "$T/p1-log"
    FLAKY_LOG_MAX=10 expect T13-cap rc2
    # T14 — the same incident, with the classifier asked twice: same answer.
    expect T14 "noverdict	5/8"
    # T15 — no dequeue reader loaded (fr_dequeue_batch): rc 3, the caller's
    #       own rule decides; never a wait, never a cached verdict.
    rc=0; nv_batch_word example-org/cromford 1 "example-org/cromford#1" abc1234 || rc=$?
    [ "$rc" = 3 ] && pok || pbad "T15: nothing to classify with is rc 3 (got $rc)"
    grep -q '^nvv ' "$MC_ATTEMPTS" && pbad "T15: nothing is cached" || pok
    echo "$P $F" > "$T/p1.result"
  )
  read -r p f < "$T/p1.result" 2>/dev/null || { p=0; f=1; echo "FAIL: part 1 did not run"; }
  PASS=$((PASS+p)); FAIL=$((FAIL+f))
else
  bad "part 1: bin/lib/mc-noverdict.sh is absent (the red this suite opens on)"
fi

# ============================================================================
# PART 2 — the real conductor.
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=fixture-secret\n' > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
# BH-4148 (#4614): the lead's protected paths are worker rows, not
# catalog/lead-protected-paths.tsv; the fake worker answers the route with no
# rows for the repo (tests/lib/lpp-stub.sh), as the deleted TSV did.
mkdir -p "$T/h/catalog" "$T/fakebin"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_install "$T/fakebin" "$T/lpp-rows.json" "$T/lpp-down"
printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$T/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "only=%%s project=%%s\\n" "${BR_ONLY_PR:-}" "${1:-}" >> "%s/br-launch.txt"\n' "$T" > "$T/h/bin/blocked-resolver.sh"
chmod +x "$T/h/bin/"*.sh

N=5443
H=5443aaaa5443bbbb5443cccc5443dddd5443eeee
BASE7=fa1ca57
MAIN_MOVED=9d50520aaaabbbbccccddddeeeeffff000011112
RUN1=37200000001
RUN2=37200000002
K="example-org/mgfy-os#$N"
printf '6316\tmerge queue: checking #%s on main (%s)\n6401\tmerge queue: checking #%s on main (%s)\n' "$N" "$BASE7" "$N" "$BASE7" > "$T/drafts.tsv"
# dq_comment <draft> <run> <id> <created_at> — #4121's real dequeue comment,
# edited to a single-PR draft at this head failing both fan-ins on <run>.
dq_comment() {
  jq -c --arg d "$1" --arg r "$2" --arg h "$H" --argjson id "$3" --arg at "$4" --arg pure "$PURE" --arg trace "$TRACE" '
    .body |= (sub("on draft #4279 · identified as the failing PR"; "on draft #\($d) · identified as the failing PR")
             | sub("2150c8f1f93ef0c0a94b05c09e87c425903e4eeb"; $h)
             | sub("Failing checks:\n[^\n]*\n"; "Failing checks:\n- ❌ [`\($pure)`](https://github.com/example-org/mgfy-os/actions/runs/\($r)/job/1\($r)) ([job log](https://github.com/example-org/mgfy-os/actions/runs/\($r)/job/1\($r)))\n- ❌ [`\($trace)`](https://github.com/example-org/mgfy-os/actions/runs/\($r)/job/2\($r)) ([job log](https://github.com/example-org/mgfy-os/actions/runs/\($r)/job/2\($r)))\n"))
    | .id = $id | .created_at = $at | .updated_at = $at
    | . + {user: {login: "mergify[bot]", type: "Bot"}}' "$FX4428/pr4121-dequeue.json"
}
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
pr_of() { sed -n 's|.*/issues/\([0-9]*\)/.*|\1|p; s|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*" | head -1; }
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"actions/workflows/prequeue-gate.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/main") restpr --raw 200 '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    case "$(cat "$T/ckmode" 2>/dev/null || echo stale)" in
      stale) restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked) restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*)
    restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-12T20:00:00Z"}}}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*)
    restpr --raw 200 "$(cat "$T/comments-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/branches/"*) restpr --raw 200 "{\"name\":\"main\",\"commit\":{\"sha\":\"$(cat "$T/mainsha")\"}}" ;;
  # The batch run reads: its jobs (gh_ci_api / flaky_run_tests_strict) and its
  # failed-job log, from jobs-<run>.json and log-<run>.txt.
  *"api -i -X GET repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    restpr --raw 200 "$(cat "$T/jobs-$RID.json" 2>/dev/null || echo '{"total_count":0,"jobs":[]}')" ;;
  *"api repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    [ -e "$T/jobsfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    cat "$T/jobs-$RID.json" 2>/dev/null || exit 1 ;;
  *"api -i -X GET repos/"*"/actions/runs"*"event=pull_request"*) restpr --raw 200 '{"total_count":0,"workflow_runs":[]}' ;;
  *"api -i -X GET repos/"*"/actions/runs/"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p' <<<"$*")
    restpr --raw 200 "{\"id\":$RID,\"head_branch\":\"mergify/merge-queue/abc$RID\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-10-12T22:00:00Z\",\"head_sha\":\"cccccccc11112222333344445555666677778888\",\"display_title\":\"merge queue: checking #5443 on main (fa1ca57)\",\"pull_requests\":[]}" ;;
  *"run view "*"--log-failed"*)
    RID=$(awk '{print $3}' <<<"$*")
    cat "$T/log-$RID.txt" 2>/dev/null || exit 1 ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[{"filename":"bin/lib/mc/classify.sh"}]' ;;
  # ---- writes -------------------------------------------------------------
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    # The queue command over REST (mc_enqueue_mergify): a requeue write.
    if grep -qiE '^@mergifyio (requeue|queue)' "$BF" 2>/dev/null; then
      printf '%s %s\n' "$*" "$(head -1 "$BF")" >> "$T/comments.txt"; echo acked > "$T/ckmode"
      restpr --raw 201 '{"id":1}'; exit 0
    fi
    { printf '<<PR %s>>\n' "$(pr_of "$*")"; cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels-$N" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels-$N"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-$N"; sort -u -o "$T/labels-$N" "$T/labels-$N"
    echo acked > "$T/ckmode"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) echo acked > "$T/ckmode" ;; esac
    exit 0 ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(pr_of "$*")
    TI=$(awk -F'\t' -v n="$PN" '$1==n {print $2}' "$T/drafts.tsv")
    if [ -n "$TI" ]; then
      restpr --raw 200 "$(jq -nc --argjson n "$PN" --arg t "$TI" '{number: $n, title: $t, state: "closed"}')"
    else
      LBL=$(tr '\n' ',' < "$T/labels-$PN" 2>/dev/null | sed 's/,$//')
      # An ejected head is UNSTABLE: Mergify leaves its own failed check on it.
      restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main "$LBL" MERGEABLE UNSTABLE operator
    fi ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
{ printf '#!/bin/bash\n'; cat <<'EOF'
URL="${!#}"; M=GET; prev=""; for a in "$@"; do [ "$prev" = -X ] && M="$a"; prev="$a"; done
case "$URL" in
  */api/lead-protected-paths*) "$(dirname "$0")/lpp-answer" "$M" "$URL"; exit 0 ;;
esac
printf '{"error":"not found"}\n404\n'
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
ALOG="$T/h/logs/ALERTS.log"

mkrec() {
  local d="$T/h/builds/pool-mgfy-MG-$N-202610120$N"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$N" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$H" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$H" > "$T/head-$N"
}
list_row() { # list_row <mergeState> <label>
  printf '[{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[{"name":"%s"}],"baseRefName":"main"}]' \
    "$N" "$N" "$H" "$N" "$1" "$2" > "$T/list.json"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$K" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$K" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
# A requeue write: our merge-queue label back on, or a `@mergifyio requeue` comment.
requeues() { cat "$T/label-adds.txt" "$T/comments.txt" 2>/dev/null | grep -cE "issues/$N/(labels -f labels\[\]=merge-queue|comments.*@mergifyio requeue)"; }
row() { echo "$(state_of) '$(reason_of)'"; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# reset_case <log spec…> — one ejected, approved, green head whose batch #6316
# failed on run RUN1, whose fan-in log the real bin/ci-verdicts.sh wrote.
reset_case() {
  : > "$A"; : > "$CLOG"; : > "$ALOG"
  for f in label-adds label-removes comments merges gh-calls attr-comments reruns writes br-launch; do : > "$T/$f.txt"; done
  rm -f "$T"/comments-*.json "$T"/labels-* "$T"/head-* "$T"/jobs-*.json "$T"/log-*.txt "$T/jobsfail" "$T/h/flags/main-red-mgfy"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" "$T/h/state/merge-conductor/batch-eject" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" "$T/h/state/merge-conductor/eject-runs" 2>/dev/null
  rm -rf "$T/h/builds/"pool-mgfy-* 2>/dev/null
  printf '%s' "$MAIN_MOVED" > "$T/mainsha"
  echo stale > "$T/ckmode"
  printf '[%s]' "$(dq_comment 6316 "$RUN1" 9001 2026-10-12T22:06:30Z)" > "$T/comments-$N.json"
  printf 'dequeued\n' > "$T/labels-$N"
  mkrec
  list_row UNSTABLE dequeued
  fanin_log "$T/log-$RUN1.txt" success 8 160 "$@"
  echo "ejected $K $H" >> "$A"
}
no_culprit() { # no_culprit <case>
  grep -qE "^(dqwculprit|reejected|ejectfix|bejculprit) $K " "$A" && bad "$1: no culprit, strike or fix-round mark (got: $(grep -E "^(dqwculprit|reejected|ejectfix|bejculprit) " "$A"))" || ok
  [ ! -s "$T/br-launch.txt" ] && ok || bad "$1: no blocked-resolver launch (got: $(cat "$T/br-launch.txt"))"
}

# ============================================================================
# N1 — the incident: one requeue, QUEUED, no culprit, no fix round. Red on main.
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "N1: exactly one @mergifyio requeue (got $(requeues); row $(row))"
[ "$(state_of)" = QUEUED ] && ok || bad "N1: the row is QUEUED (got $(row))"
[ "$(cnt "NOVERDICT_RETRY $K $H" "$CLOG")" = 1 ] && ok || bad "N1: NOVERDICT_RETRY logged once (log: $(grep -o "mgfy-os#$N .*" "$CLOG" | tail -5))"
grep -q "NOVERDICT_RETRY $K $H — draft #6316 run $RUN1: shard(s) 5/8 left no verdict" "$CLOG" && ok || bad "N1: the log line names the draft, the run and the shard"
grep -q "That is an infra retry, not a failure of this PR" "$T/attr-comments.txt" && ok || bad "N1: the PR line says infra retry (got: $(cat "$T/attr-comments.txt"))"
grep -q "shard(s) 5/8 left no verdict" "$T/attr-comments.txt" && ok || bad "N1: the PR line names the shard"
grep -q "out of the queue" "$T/attr-comments.txt" && bad "N1: no culprit comment (got: $(cat "$T/attr-comments.txt"))" || ok
grep -q "^nvv $K $H 9001 noverdict 6316 $RUN1 5/8$" "$A" && ok || bad "N1: the verdict is cached (got: $(grep '^nvv' "$A"))"
grep -q "^bejv $K " "$A" && bad "N1: no #4428 solo verdict is written for a no-verdict head" || ok
no_culprit N1
# The next tick, Mergify acknowledged: no second requeue, still no culprit.
list_row UNSTABLE merge-queue
run_tick
[ "$(requeues)" = 1 ] && ok || bad "N1: the second tick posts no second requeue (got $(requeues))"
[ "$(cnt "NOVERDICT_RETRY $K $H" "$CLOG")" = 1 ] && ok || bad "N1: still one NOVERDICT_RETRY"
no_culprit N1-tick2

# ============================================================================
# N2 — the same head, ejected again by a second no-verdict batch (#6401, run
#      RUN2): queue-ejected-twice, no second requeue, exactly ONE alert.
# ============================================================================
# The conductor's own lines for the second ejection (what its settle pass
# writes: bin/merge-conductor.sh, `reejected` for a head it re-queued).
echo "reejected $K $H" >> "$A"
printf '[%s,%s]' "$(dq_comment 6316 "$RUN1" 9001 2026-10-12T22:06:30Z)" "$(dq_comment 6401 "$RUN2" 9002 2026-10-12T23:10:00Z)" > "$T/comments-$N.json"
fanin_log "$T/log-$RUN2.txt" success 8 160 ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN2.json" "$S5:failure" "${FANINS_RED[@]}"
printf 'dequeued\n' > "$T/labels-$N"; echo stale > "$T/ckmode"
list_row UNSTABLE dequeued
run_tick
case "$(state_of):$(reason_of)" in BLOCKED_HUMAN:queue-ejected-twice*) ok ;; *) bad "N2: BLOCKED_HUMAN queue-ejected-twice (got $(row))" ;; esac
run_tick
run_tick
[ "$(requeues)" = 1 ] && ok || bad "N2: no second requeue (got $(requeues))"
[ "$(cnt "left no verdict twice" "$ALOG")" = 1 ] && ok || bad "N2: exactly one alert over three ticks (got: $(cat "$ALOG"))"
grep -q "https://github.com/example-org/mgfy-os/pull/$N left no verdict twice on ${H:0:12} (batch drafts #6316, #6401; shard(s) 5/8)" "$ALOG" && ok || bad "N2: the alert names the PR, both drafts and the shard (got: $(cat "$ALOG"))"
grep -q "^nvtwice $K $H$" "$A" && ok || bad "N2: the nvtwice mark is written"
[ "$(cnt "NOVERDICT_TWICE $K $H" "$CLOG")" = 1 ] && ok || bad "N2: NOVERDICT_TWICE logged once"
grep -q "^ejectfix $K $H$" "$A" && ok || bad "N2: the resolver ladder still goes on (ejectfix; attempts: $(grep -E '^(ejectfix|nv)' "$A"))"

# ============================================================================
# N3 — a real test failure on shard 2 next to the no-verdict shard 5: no
#      requeue, no NOVERDICT_RETRY, and the row ends where it ends today.
# ============================================================================
n3_run() {
  reset_case ok ok fail ok ok missing ok ok
  jobs_of "$T/jobs-$RUN1.json" "$S2:failure" "$S5:cancelled" "${FANINS_RED[@]}"
  run_tick; run_tick
}
n3_run
[ "$(requeues)" = 0 ] && ok || bad "N3: no requeue (got $(requeues); row $(row))"
[ "$(cnt NOVERDICT_ "$CLOG")" = 0 ] && ok || bad "N3: no NOVERDICT line (got: $(grep NOVERDICT "$CLOG"))"
grep -q "^nvv $K $H 9001 real " "$A" && ok || bad "N3: the verdict is real (got: $(grep '^nvv' "$A"))"
N3_WITH=$(row)
[ -e "$T/h/bin/lib/mc-noverdict.sh" ] && mv "$T/h/bin/lib/mc-noverdict.sh" "$T/nv.off"
n3_run
N3_WITHOUT=$(row)
[ -e "$T/nv.off" ] && mv "$T/nv.off" "$T/h/bin/lib/mc-noverdict.sh"
[ "$N3_WITH" = "$N3_WITHOUT" ] && ok || bad "N3: the row is today's (with the lib: $N3_WITH; without: $N3_WITHOUT)"

# ============================================================================
# N4 — the run's jobs cannot be read: two ticks wait with their own reason;
#      the third hands the head to today's path (#4428's solo verdict).
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
touch "$T/jobsfail"
for i in 1 2; do
  run_tick
  case "$(reason_of)" in *"whether batch draft #6316 left no verdict could not be read this tick"*) ok ;; *) bad "N4: tick $i waits with its own reason (got $(row))" ;; esac
done
grep -q "^bejv $K " "$A" && bad "N4: no #4428 verdict while unread" || ok
run_tick
grep -q "NOVERDICT_UNREAD $K $H" "$CLOG" && ok || bad "N4: the third unread tick is logged"
grep -q "^bejv $K $H solo " "$A" && ok || bad "N4: the third tick is today's path (bejv: $(grep '^bejv' "$A"))"
[ "$(requeues)" = 0 ] && ok || bad "N4: no requeue"
grep -q "^nvv " "$A" && bad "N4: an unread verdict is never cached" || ok

# ============================================================================
# N5 — a cached verdict reads nothing again. Under the main-red freeze the head
#      waits (and says why); the next tick spends no jobs or log read; once the
#      freeze lifts it is re-queued.
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
echo "main red" > "$T/h/flags/main-red-mgfy"
run_tick MC_MAIN_RED_TEST_PATHS='tests/*'
case "$(reason_of)" in *"main-red freeze is on"*) ok ;; *) bad "N5: the freeze holds it (got $(row))" ;; esac
[ "$(requeues)" = 0 ] && ok || bad "N5: no requeue under the freeze"
: > "$T/gh-calls.txt"
run_tick MC_MAIN_RED_TEST_PATHS='tests/*'
grep -qE "actions/runs/$RUN1/jobs|run view $RUN1" "$T/gh-calls.txt" && bad "N5: a cached verdict spends no jobs or log read (got: $(grep -E "runs/$RUN1" "$T/gh-calls.txt"))" || ok
rm -f "$T/h/flags/main-red-mgfy"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "N5: re-queued once the freeze lifts (got $(requeues); row $(row))"

# ============================================================================
# N6 — observe mode (MERGES=0): "would REQUEUE", nothing written.
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
rm -f "$T/h/flags/merge-conductor-merge"
run_tick
grep -q "would REQUEUE $K $H" "$CLOG" && ok || bad "N6: would REQUEUE logged (log: $(grep -o "mgfy-os#$N .*" "$CLOG" | tail -3))"
[ "$(requeues)" = 0 ] && [ ! -s "$T/label-adds.txt" ] && [ ! -s "$T/attr-comments.txt" ] && ok || bad "N6: nothing written"
touch "$T/h/flags/merge-conductor-merge"

# ============================================================================
# N7 — a human `@mergifyio dequeue` after the head still wins over the rule.
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
printf '[%s,%s]' "$(dq_comment 6316 "$RUN1" 9001 2026-10-12T22:06:30Z)" \
  '{"id":9003,"user":{"login":"operator","type":"User"},"body":"@mergifyio dequeue","created_at":"2026-10-12T22:10:00Z","updated_at":"2026-10-12T22:10:00Z"}' > "$T/comments-$N.json"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "N7: a human dequeue is never re-queued (got $(requeues); row $(row))"
grep -q "^dqwculprit $K $H$" "$A" && ok || bad "N7: the human dequeue makes it the culprit"

# ============================================================================
# N8 — a failing check that is not an Actions run (a Vercel build) next to the
#      fan-ins: no shard explains it, so today's rule decides on the FIRST
#      tick, with no wait and no unread count.
# ============================================================================
reset_case ok ok ok ok ok missing ok ok
jobs_of "$T/jobs-$RUN1.json" "$S5:cancelled" "${FANINS_RED[@]}"
dq_comment 6316 "$RUN1" 9001 2026-10-12T22:06:30Z \
  | jq -c '.body |= sub("Failing checks:\n"; "Failing checks:\n- ❌ [`Vercel – mgfy-os`](https://vercel.com/example-org/mgfy-os/abc)\n")' > "$T/one.json"
printf '[%s]' "$(cat "$T/one.json")" > "$T/comments-$N.json"
grep -q 'Vercel' "$T/comments-$N.json" && ok || bad "N8: the fixture carries the Vercel bullet"
run_tick
grep -q "^bejv $K $H solo " "$A" && ok || bad "N8: today's rule decided on tick 1 (bejv: $(grep '^bejv' "$A"); row $(row))"
grep -qE "^(nvv|nvunread) " "$A" && bad "N8: no verdict and no unread count (got: $(grep -E '^nv' "$A"))" || ok
[ "$(requeues)" = 0 ] && ok || bad "N8: no requeue (got $(requeues))"

echo "mq-no-verdict-retry (BH-6336): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
