#!/bin/bash
# tests/mc/requeue-after-foreign-red.bh-3776-test.sh — BH-3776: A PR MERGIFY
# EJECTED FROM A RED BATCH IT DID NOT BREAK GOES BACK IN, ONCE.
#
# THE CASE (#3759, 14h+). Mergify ejected a green, approved head when its batch
# draft #3767 went red on tests/fleet-propagate-test.sh, a suite the PR never
# touched; #3768 on the same main passed it minutes later. BH-636's re-entry arm
# should have put the PR back, and never did: after a real ejection Mergify
# leaves its own check runs on the head (`Rule: … (queue)` failure, `Mergify
# Merge Queue` neutral "Dequeued — checks failed"), GitHub reports the PR
# UNSTABLE, and the arm re-tested the RAW merge state for CLEAN. Every real
# ejection sat on `WAIT_CI queue-ejected — push a fix` for good.
#
# THE RULE. Mergify's own check runs do not count against re-entry. The batch
# failure is attributed first (the dequeue comment bound to THIS head names the
# draft and the failing runs; the run logs name the suites): a failure that
# touches the PR's files is the PR's own and keeps today's answer; one that does
# not, or one a later batch on the same main passed, re-queues once, says so
# once on the PR, and writes known flakes to the ci_flakes ledger.
#
# Driven against the real bin/merge-conductor.sh and a fake gh that records
# every label write, comment and merge call. One clock read (NOW).
# Run from anywhere: tests/mc/requeue-after-foreign-red.bh-3776-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
TODAY=$(date -u -d "@$NOW" +%Y-%m-%d)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
for f in merge-conductor-lib gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list flaky gh-ci-read mc-stale-dequeue; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/"
done
# The lib under test. Absent on main, which is exactly the red this suite opens on.
[ -r "$DIR/bin/lib/mc-foreign-red.sh" ] && cp "$DIR/bin/lib/mc-foreign-red.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=x\n' > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
# BH-3857: the tier file a later batch's plan is judged against (no nightly row).
mkdir -p "$T/h/catalog"; printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$T/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh

H1=aaaaaaaa11112222333344445555666677778888
HOLD=bbbbbbbb11112222333344445555666677778888
BATCH=cccccccc11112222333344445555666677778888
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# ---- fixture switches -------------------------------------------------------
# ckmode   stale | acked | stale_red | stale_big | none
#          stale     Mergify's queue rule failure + "Dequeued — checks failed"
#                    neutral, and one green github-actions run
#          acked     Mergify's queue check in progress (an acknowledgement)
# noflip   non-empty => the @mergifyio requeue post does NOT move the check
# vstatus  the lead-verdict commit status state
# cmfail   non-empty => issues/31/comments answers 502
# logmode  suite | none   (what `gh run view --log-failed` yields)
# files    the PR's changed files, one per line
# later    the actions/runs?event=pull_request answer (JSON)
# flakes   the GET /api/metrics/flakes answer (JSON)
# run2     the second failing run 5004 (named only when the comment lists it):
#          ok | nolog | nopath | nobase | nohead | notmq
dq_comment() { # dq_comment <left-at sha> [draft yes|no] [extra run id] [comment id] [updated_at]
  #   -> one mergify[bot] dequeue comment (JSON object)
  local body draft="" extra=""
  [ "${2:-yes}" = yes ] && draft=' · on draft #3767'
  [ -n "${3:-}" ] && extra=$(printf '\n- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/mgfy-os/actions/runs/%s/job/90002) ([job log](https://github.com/example-org/mgfy-os/actions/runs/%s/job/90002))' "$3" "$3")
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "dequeued", "queue_rule_name": "default"}\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-30 09:40 UTC` · Rule: `default`\n- ❌ **Checks failed**%s\n- 🚫 **Left the queue** — `2026-09-30 10:12 UTC` · at `%s`\n\n## Reason\n\nThe merge conditions cannot be satisfied due to failing checks\n\n- `Pure-logic gate fixtures`\n\nFailing checks:\n- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/mgfy-os/actions/runs/5003/job/90001) ([job log](https://github.com/example-org/mgfy-os/actions/runs/5003/job/90001))%s\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n' "$draft" "$1" "$extra")
  jq -nc --arg b "$body" --argjson id "${4:-7001}" --arg u "${5:-2026-09-30T10:12:00Z}" '{id: $id, user: {login: "mergify[bot]", type: "Bot"}, body: $b,
    created_at: "2026-09-30T09:40:00Z", updated_at: $u}'
}
older_comment() { # a mergify comment created EARLIER but edited LATER, naming another state
  jq -nc '{id: 6001, user: {login: "mergify[bot]", type: "Bot"},
    body: "-*- Mergify Payload -*-\n{\"version\": 1, \"state\": \"merged\"}\n-*- Mergify Payload End -*-\nold",
    created_at: "2026-09-29T09:00:00Z", updated_at: "2026-09-30T11:00:00Z"}'
}
later_run() { # later_run <id> <draft#> <path> <base7> <created_at> [conclusion]
  jq -nc --argjson id "$1" --argjson d "$2" --arg p "$3" --arg b "$4" --arg c "$5" --arg co "${6:-success}" \
    '{id: $id, head_branch: ("mergify/merge-queue/" + ($id|tostring)), path: $p, status: "completed",
      conclusion: $co, created_at: $c, head_sha: "dddd0000", event: "pull_request",
      display_title: ("merge queue: checking #3749 on main (" + $b + ")"),
      pull_requests: [{number: $d}]}'
}

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nH1=%s\nBATCH=%s\n' "$T" "$MGFY_YML" "$H1" "$BATCH"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
# jobs_json <failed job name>... — a run's jobs answer, every named job failed;
# gh's own -q is honoured, as the real gh does.
jobs_json() {
  local q="" prev=""
  for a in "${ARGS[@]}"; do [ "$prev" = -q ] && q="$a"; prev="$a"; done
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | {name: ., status: "completed", conclusion: "failure"})
    | {total_count: length, jobs: .} | if $tc != "" then .total_count = ($tc | tonumber) else . end' --arg tc "$(cat "$T/jobstotal" 2>/dev/null)" | if [ -n "$q" ]; then jq -r "$q"; else cat; fi
}
ARGS=("$@")
CK=$(cat "$T/ckmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
GHA_RED='{"name":"Pure-logic gate fixtures","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CK" in
      stale)     restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      stale_red) restpr --raw 200 "{\"total_count\":4,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK,$GHA_RED]}" ;;
      stale_big) restpr --raw 200 "{\"total_count\":150,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked)     restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
      *)         restpr --raw 200 '{"total_count":0,"check_runs":[]}' ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 "{\"state\":\"$(cat "$T/vstatus")\",\"statuses\":[{\"context\":\"lead-verdict\",\"state\":\"$(cat "$T/vstatus")\"}]}" ;;
  *"api -i -X GET repos/"*"/issues/31/comments"*)
    [ -s "$T/cmfail" ] && { restpr --raw 502 '{"message":"Server Error"}'; exit 0; }
    restpr --raw 200 "$(cat "$T/comments.json")" ;;
  *"api -i -X GET repos/"*"/actions/runs/5003"*)
    restpr --raw 200 "{\"id\":5003,\"head_branch\":\"mergify/merge-queue/abc123\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-30T10:00:00Z\",\"head_sha\":\"$BATCH\",\"display_title\":\"merge queue: checking #31 on main (474d69b)\",\"pull_requests\":[{\"number\":3767}]}" ;;
  *"api -i -X GET repos/"*"/actions/runs/5004"*)
    R2=$(cat "$T/run2" 2>/dev/null || echo ok)
    P='.github/workflows/harness-ci.yml'; BR='mergify/merge-queue/abc124'; HS="$BATCH"; TI='merge queue: checking #31 on main (474d69b)'
    case "$R2" in nopath) P="" ;; nobase) TI='merge queue: checking #31' ;; nohead) HS="" ;; notmq) BR='ticket/other' ;; esac
    restpr --raw 200 "{\"id\":5004,\"head_branch\":\"$BR\",\"path\":\"$P\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-09-30T10:00:00Z\",\"head_sha\":\"$HS\",\"display_title\":\"$TI\",\"pull_requests\":[]}" ;;
  *"run view 5004"*"--log-failed"*)
    case "$(cat "$T/run2" 2>/dev/null || echo ok)" in
      nolog) ;;
      jobonly) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z ##[error]Process completed with exit code 1.\n' ;;
      *) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/other-suite-test.sh rc=1 3s\n' ;;
    esac ;;
  *"api repos/"*"/actions/runs/5004/jobs"*)
    [ "$(cat "$T/run2" 2>/dev/null || echo ok)" = nolog ] || jobs_json 'Pure-logic gate fixtures' ;;
  # BH-3857: for the harness repo a later batch counts only when its CI-plan
  # job log proves it ran the suite. Every later batch here is a full-mode
  # merge-queue plan that dropped nothing (the line bin/ci-plan.sh prints).
  *"api -i -X GET repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    restpr --raw 200 "{\"total_count\":1,\"jobs\":[{\"id\":77$RID,\"name\":\"CI plan (what this run tests)\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *"api repos/"*"/actions/jobs/"*"/logs"*)
    echo '2026-09-30T10:31:00.1234567Z impact: 3 of 3 suites (full: merge queue batch lb; tiers: 3 suite(s) run (0 guard(s) triggered), 0 left to the nightly run) — 1 shard(s), mode=full' ;;
  *"api -i -X GET repos/"*"/actions/runs"*"event=pull_request"*)
    restpr --raw 200 "$(cat "$T/later")" ;;
  # logmode: suite (one harness suite line) | none (the log reads, but names no
  # test: the jobs API stands in) | fail (`gh run view` itself fails) | many (21
  # suites, the 21st last) | title (a vitest-style title that is not a path).
  *"run view 5003"*"--log-failed"*)
    case "$(cat "$T/logmode")" in
      suite) printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n' ;;
      none)  printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z ##[error]Process completed with exit code 1.\n' ;;
      fail)  echo "failed to get run log: HTTP 410" >&2; exit 1 ;;
      many)  for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
               printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/s%s-test.sh rc=1 3s\n' "$i"; done
             printf 'Pure-logic gate fixtures\tgate\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n' ;;
      title) printf 'Pure-logic gate fixtures\tvitest\t2026-09-30T10:05:00Z × Makefile 12ms\n' ;;
      # mixed: one shard names an untouched suite, the SPA job (a build this PR
      # broke) names nothing (BH-3776 round 3, N2).
      mixed) printf 'Tests, traced (shard 2 of 8)\tsuite\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n'
             printf 'Mission Control SPA — unit tests + build\tconsole-ui builds clean\t2026-09-30T10:06:00Z src/App.tsx(12,3): error TS2304: Cannot find name foo.\n'
             printf 'Mission Control SPA — unit tests + build\tconsole-ui builds clean\t2026-09-30T10:06:01Z ##[error]Process completed with exit code 2.\n' ;;
      # Runner titles and file lines as gh --log-failed really prints them:
      # "<job>\t<step>\t<timestamp> <runner line>" (#3798 round 4, F1/F3).
      advvitest) printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > GET /api/x > returns 200\n'
             printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:00Z    × GET /api/x > returns 200 12ms\n'
             printf 'Jobs worker — routes + schema\tworker/jobs unit tests\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advjest) printf 'test\tnpm test\t2026-09-30T10:05:00Z FAIL src/foo.test.ts\n'
             printf 'test\tnpm test\t2026-09-30T10:05:00Z   ● foo › works\n' ;;
      jestfile) printf 'test\tnpm test\t2026-09-30T10:05:00Z FAIL src/foo.test.ts\n' ;;
      # advone/advslash: vitest titles with no shape tell — one word, or a
      # slash — behind the file they ran in (#3798 round 5).
      advone) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > works\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z    × works 12ms\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advslash) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z  FAIL  test/routes.test.js > api/health\n'
             printf 'Jobs worker\tunit\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n' ;;
      advbare) printf 'Jobs worker\tunit\t2026-09-30T10:05:00Z    × works 12ms\n' ;;
      # fanin*: the real harness-ci shape. A shard names the suite; the fan-in
      # check `Pure-logic gate fixtures` names none, only what bin/ci-verdicts.sh
      # printed ($T/fanin.txt, produced by the real script).
      fanin*) printf 'Tests, traced (shard 1/2)\ttests\t2026-09-30T10:05:00Z --- tests/fleet-propagate-test.sh rc=1 3s\n'
             printf 'Tests, traced (shard 1/2)\ttests\t2026-09-30T10:05:01Z ##[error]Process completed with exit code 1.\n'
             sed 's/^/Pure-logic gate fixtures\tverdicts\t2026-09-30T10:07:00Z /' "$T/fanin.txt" ;;
    esac ;;
  *"api repos/"*"/actions/runs/5003/jobs"*)
    if [ -s "$T/jobs5003" ]; then ( set -f; IFS=$'\n'; jobs_json $(cat "$T/jobs5003") ); else jobs_json 'Pure-logic gate fixtures'; fi ;;
  *"api -i -X GET repos/"*"/pulls/31/files"*)
    restpr --raw 200 "$(jq -Rsc '[split("\n")[] | select(length > 0) | {filename: .}]' < "$T/files")" ;;
  # ---- writes -------------------------------------------------------------
  *"api -i -X POST repos/"*"/issues/31/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    { cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) [ -s "$T/noflip" ] || echo acked > "$T/ckmode" ;; esac
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
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main \
           "$LBL" MERGEABLE CLEAN operator ;;
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
{ printf '#!/bin/bash\nT=%s\n' "$T"; cat <<'EOF'
URL="${!#}"; M=GET; B=""
while [ $# -gt 0 ]; do case "$1" in -X) M=$2; shift ;; --data-binary) B=$2; shift ;; esac; shift; done
case "$M $URL" in
  "PUT "*/api/metrics/flakes) printf '%s\n' "$B" >> "$T/flake-puts.txt"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/metrics/flakes\?*) printf '%s\n200\n' "$(cat "$T/flakes" 2>/dev/null || echo '{"flakes":[]}')" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"

mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <mergeState> <labels-csv>
  local lbl="[]"
  [ -n "${4:-}" ] && lbl=$(printf '%s' "$4" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
K31='example-org/mgfy-os#31'
EJWHY='queue-ejected — push a fix; the next head is enqueued on its own merits'
SENT_FOREIGN='re-queued: batch #3767 failed tests/fleet-propagate-test.sh, which this PR does not touch'
SENT_LATER='re-queued: batch #3767 failed tests/fleet-propagate-test.sh; #3768 on the same main passed it'
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# reset_case [mergeState] — the #3759 shape: an approved, green head, ejected
# last tick (a local `ejected` mark, Mergify's `dequeued` label), its batch red
# on a suite this PR does not touch, no later batch.
reset_case() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/attr-comments.txt"; : > "$T/flake-puts.txt"
  : > "$T/reruns.txt"; : > "$T/writes.txt"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" 2>/dev/null
  rm -f "$T/h/bin/test-impact.sh" "$T/jobs5003" "$T/jobstotal" "$T/h/bin/lib/train-shape.sh"
  echo stale > "$T/ckmode"; : > "$T/noflip"; echo success > "$T/vstatus"; : > "$T/cmfail"
  echo suite > "$T/logmode"; echo ok > "$T/run2"; printf 'bin/lib/mc/classify.sh\ntests/mc-x.bh-1-test.sh\n' > "$T/files"
  echo '{"total_count":0,"workflow_runs":[]}' > "$T/later"; echo '{"flakes":[]}' > "$T/flakes"
  printf '[%s,%s]' "$(older_comment)" "$(dq_comment "$H1")" > "$T/comments.json"
  printf 'dequeued\n' > "$T/labels"
  mkrec 31 "$H1"
  printf '[%s]' "$(list_row 31 "$H1" "${1:-UNSTABLE}" dequeued)" > "$T/list.json"
  echo "ejected $K31 $H1" >> "$A"
}
not_requeued() { # not_requeued <case>
  [ ! -s "$T/label-adds.txt" ] && ok || bad "$1: no merge-queue label may go on (got: $(cat "$T/label-adds.txt"))"
  grep -q '@mergifyio requeue' "$T/comments.txt" && bad "$1: no @mergifyio requeue (got: $(cat "$T/comments.txt"))" || ok
  grep -qE "^requeued $K31 " "$A" && bad "$1: no requeued mark (attempts: $(cat "$A"))" || ok
  grep -q 're-queued:' "$T/attr-comments.txt" && bad "$1: no re-queued comment (got: $(cat "$T/attr-comments.txt"))" || ok
  [ ! -s "$T/merges.txt" ] && ok || bad "$1: nothing merges (got: $(cat "$T/merges.txt"))"
}

# ============================================================================
# R1 — THE #3759 SHAPE (red-first: fails on main). Mergify-only UNSTABLE, the
#      batch red on a suite the PR does not touch: back in, once, and said once.
# ============================================================================
reset_case
run_tick
[ "$(cnt 'labels/dequeued' "$T/label-removes.txt")" = 1 ] && ok || bad "R1: the dequeued label must come off once (got: $(cat "$T/label-removes.txt"))"
[ "$(cnt 'labels\[\]=merge-queue' "$T/label-adds.txt")" = 1 ] && ok || bad "R1: the merge-queue label must go on once (got: $(cat "$T/label-adds.txt"))"
[ "$(cnt '@mergifyio requeue' "$T/comments.txt")" = 1 ] && ok || bad "R1: exactly one @mergifyio requeue (got: $(cat "$T/comments.txt"))"
[ "$(grep -cE "^requeued $K31 $H1 [0-9]+$" "$A")" = 1 ] && ok || bad "R1: exactly one requeued mark (attempts: $(cat "$A"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R1: the row must reach QUEUED (got $(state_of "$K31"), reason '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_FOREIGN" "$T/attr-comments.txt")" = 1 ] && ok || bad "R1: exactly one PR comment starting '$SENT_FOREIGN' (got: $(cat "$T/attr-comments.txt"))"
[ "$(cnt "REQUEUE_ATTRIBUTED $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R1: exactly one REQUEUE_ATTRIBUTED line (log: $(grep -o 'mgfy-os#31 .*' "$CLOG" | tail -3))"
grep -q "REQUEUE_ATTRIBUTED $K31 $H1 — $SENT_FOREIGN" "$CLOG" && ok || bad "R1: the log line carries the sentence (log: $(grep REQUEUE_ATTRIBUTED "$CLOG"))"
grep -q '—' "$T/attr-comments.txt" && bad "R1: the PR comment carries no em dash (got: $(cat "$T/attr-comments.txt"))" || ok
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R1: an unknown flake with no later evidence writes no ledger row (got: $(cat "$T/flake-puts.txt"))"
# The second tick: the row is QUEUED and Mergify's check is in progress.
printf '[%s]' "$(list_row 31 "$H1" UNSTABLE merge-queue)" > "$T/list.json"
run_tick
[ "$(cnt 'labels\[\]=merge-queue' "$T/label-adds.txt")" = 1 ] && ok || bad "R1: no second label add on the next tick (got: $(cat "$T/label-adds.txt"))"
[ "$(grep -c "^re-queued:" "$T/attr-comments.txt")" = 1 ] && ok || bad "R1: no second PR comment on the next tick (got: $(cat "$T/attr-comments.txt"))"
[ "$(cnt "REQUEUE_ATTRIBUTED $K31" "$CLOG")" = 1 ] && ok || bad "R1: no second REQUEUE_ATTRIBUTED line (got $(cnt "REQUEUE_ATTRIBUTED $K31" "$CLOG"))"
grep -qxF "reejected $K31 $H1" "$A" && bad "R1: an acknowledged requeue is not a second ejection (attempts: $(cat "$A"))" || ok
[ ! -s "$T/merges.txt" ] && ok || bad "R1: this sweep NEVER merges (got: $(cat "$T/merges.txt"))"

# ============================================================================
# R1m — the test-impact map for the harness's own repo: an `always` row reaches
#       every diff, THIS one included, so the suite is never "untouched". With
#       no later pass that is `unknown`: not re-queued, nothing ledgered.
#       TEST-CHANGE (#3798 round 2, G3): this case used to assert QUEUED with the
#       "which this PR does not touch" sentence. the operator's rule (16:02Z/18:54Z) is
#       that a suite tied to the PR is never cleared as foreign; an always-run
#       suite runs because of this diff as much as any other, so the sentence
#       was false. R18-always/full/fail below carry the rest of G3.
# ============================================================================
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\talways\\t*\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued R1m
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R1m: an always-run suite is not untouched: unknown (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R1m: no ledger row (got: $(cat "$T/flake-puts.txt"))"
# ...and a `source` row from the map IS a touch: the PR's own.
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\tsource\\tbin/lib/mc/classify.sh\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued R1m-source
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R1m-source: a suite the map says reaches this diff is the PR's own (got '$(reason_of "$K31")')"

# ============================================================================
# R2 — THE PR'S OWN. The failing suite is in the PR's diff, no later batch.
# ============================================================================
reset_case
printf 'tests/fleet-propagate-test.sh\nbin/x.sh\n' > "$T/files"
run_tick
not_requeued R2
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "R2: the row waits (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R2: with today's reason (got '$(reason_of "$K31")')"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R2: one FOREIGN_RED_OWN line (got $(cnt FOREIGN_RED_OWN "$CLOG"))"
run_tick
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R2: still one after a second tick (got $(cnt FOREIGN_RED_OWN "$CLOG"))"
not_requeued R2-tick2

# ============================================================================
# R3 — SECOND EJECTION: the strike counter answers before any attribution read.
# ============================================================================
reset_case
printf 'requeued %s %s %s\nreejected %s %s\n' "$K31" "$H1" "$((NOW-900))" "$K31" "$H1" >> "$A"
run_tick
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && ok || bad "R3: ejected twice is the resolver's (got $(state_of "$K31"))"
[ "$(reason_of "$K31")" = queue-ejected-twice ] && ok || bad "R3: reason queue-ejected-twice (got '$(reason_of "$K31")')"
[ ! -s "$T/label-adds.txt" ] && ok || bad "R3: no third enqueue (got: $(cat "$T/label-adds.txt"))"
grep -q '@mergifyio' "$T/comments.txt" && bad "R3: no requeue comment (got: $(cat "$T/comments.txt"))" || ok
grep -q 'issues/31/comments' "$T/gh-calls.txt" && bad "R3: no attribution read is spent on a head the resolver owns" || ok

# ============================================================================
# R4 — a NON-Mergify check is red next to Mergify's failure: not re-queued.
# ============================================================================
reset_case; echo stale_red > "$T/ckmode"
run_tick
not_requeued R4
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R4: today's reason (got '$(reason_of "$K31")')"
grep -q 'issues/31/comments' "$T/gh-calls.txt" && bad "R4: no attribution read on a head with a real red check" || ok
# R4b — the lead-verdict status is pending.
reset_case; echo pending > "$T/vstatus"
run_tick
not_requeued R4b
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R4b: today's reason (got '$(reason_of "$K31")')"
# R4c — more check runs than the page holds: no guess.
reset_case; echo stale_big > "$T/ckmode"
run_tick
not_requeued R4c
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R4c: today's reason (got '$(reason_of "$K31")')"

# ============================================================================
# R5 — RAW CLEAN, the PR's own suite: the new veto. And its control.
# ============================================================================
reset_case CLEAN
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
run_tick
not_requeued R5
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R5: a batch red on the PR's own suite is not re-queued even when CLEAN (got '$(reason_of "$K31")')"
reset_case CLEAN; echo acked > "$T/ckmode"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R5-control: raw CLEAN and an untouched suite still re-queues, the BH-636 path (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(cnt '@mergifyio requeue' "$T/comments.txt")" = 1 ] && ok || bad "R5-control: one requeue (got: $(cat "$T/comments.txt"))"

# ============================================================================
# R6 — the dequeue comment is about an OLDER head: unknown, not re-queued.
# ============================================================================
reset_case
printf '[%s]' "$(dq_comment "$HOLD")" > "$T/comments.json"
run_tick
not_requeued R6
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R6: today's reason (got '$(reason_of "$K31")')"
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R6: one FOREIGN_RED_UNKNOWN line (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"

# ============================================================================
# R7 — no parseable test name, `job:` only, and no later batch.
# ============================================================================
reset_case; echo none > "$T/logmode"
run_tick
not_requeued R7
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R7: a job name with no evidence is unknown (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"

# ============================================================================
# R8 — a later green batch on ANOTHER main base proves nothing (own suite).
# ============================================================================
reset_case
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
printf '{"total_count":1,"workflow_runs":[%s]}' "$(later_run 5010 3768 .github/workflows/harness-ci.yml deadbee 2026-09-30T10:30:00Z)" > "$T/later"
run_tick
not_requeued R8
# R8b — same base, a different workflow.
reset_case
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
printf '{"total_count":1,"workflow_runs":[%s]}' "$(later_run 5010 3768 .github/workflows/other.yml 474d69b 2026-09-30T10:30:00Z)" > "$T/later"
run_tick
not_requeued R8b
# R8c — same base and path, but EARLIER than the ejecting run.
reset_case
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
printf '{"total_count":1,"workflow_runs":[%s]}' "$(later_run 5001 3765 .github/workflows/harness-ci.yml 474d69b 2026-09-30T09:00:00Z)" > "$T/later"
run_tick
not_requeued R8c

# ============================================================================
# R9 — the comments read fails: wait, no strike, and the next tick re-queues.
# ============================================================================
reset_case; echo x > "$T/cmfail"
run_tick
not_requeued R9
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "R9: the reason must say the read failed (got '$(reason_of "$K31")')" ;; esac
grep -qE "^(requeued|reejected) $K31 " "$A" && bad "R9: no mark of any kind (attempts: $(cat "$A"))" || ok
: > "$T/cmfail"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R9: the read restored, the next tick re-queues (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_FOREIGN" "$T/attr-comments.txt")" = 1 ] && ok || bad "R9: with the one comment (got: $(cat "$T/attr-comments.txt"))"

# ============================================================================
# R10 — THE PR'S OWN SUITE, AND A LATER BATCH ON THE SAME MAIN PASSED IT: STILL
#       THE PR'S OWN. A later batch that does not contain this PR passes whether
#       or not this PR broke the suite, so its pass says nothing about who caused
#       the red. Not re-queued, nothing said, nothing ledgered (BH-3776 review,
#       item 1: `own` is never upgraded).
# ============================================================================
later_pass() { # the #3768 shape: a later green batch on the same main, plus a red one after it
  printf '{"total_count":2,"workflow_runs":[%s,%s]}' \
    "$(later_run 5010 3768 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:30:00Z)" \
    "$(later_run 5011 3769 .github/workflows/harness-ci.yml 474d69b 2026-09-30T10:40:00Z failure)" > "$T/later"
}
reset_case
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
later_pass
run_tick
not_requeued R10
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "R10: a later green batch never overrides the PR's own suite (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(reason_of "$K31")" = "$EJWHY" ] && ok || bad "R10: with today's reason (got '$(reason_of "$K31")')"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R10: one FOREIGN_RED_OWN line (got $(cnt FOREIGN_RED_OWN "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R10: a suite in the PR's own diff is never written to ci_flakes (got: $(cat "$T/flake-puts.txt"))"
grep -qx own "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null && ok || bad "R10: the cached verdict is own (got: $(cat "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null))"
# R10-raw — the same under raw CLEAN: the veto holds there too.
reset_case CLEAN
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
later_pass
run_tick
not_requeued R10-raw
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R10-raw: no ledger row (got: $(cat "$T/flake-puts.txt"))"
# R10-gate — the suite is in the PR's diff AND already a known flake (3 heads in
#   the ledger) AND a later batch passed it: still own, and still no ledger row.
reset_case
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
later_pass
jq -nc --arg d "$TODAY" '{flakes: [range(0;3) | {day: $d, repo: "example-org/mgfy-os", workflow: ".github/workflows/harness-ci.yml",
  test: "tests/fleet-propagate-test.sh", head: ("h" + tostring), kind: "flake"}]}' > "$T/flakes"
run_tick
not_requeued R10-gate
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R10-gate: a known flake in the PR's own diff is still never ledgered from here (got: $(cat "$T/flake-puts.txt"))"
# R10-map — touched only through the harness test-impact map, a later batch passed: own.
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\tsource\\tbin/lib/mc/classify.sh\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued R10-map
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R10-map: a suite the map ties to this diff is never ledgered (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# R10b — later-batch evidence upgrades UNKNOWN only, and only when the PR is
#        known to touch NONE of the failing tests. A `job:` name says which job
#        failed, not which test, so touch cannot be checked: a later pass never
#        lifts it (the operator, 16:02Z). The R7 shape plus a later pass stays unknown.
#        TEST-CHANGE (#3798 round 3b): this asserted QUEUED with the
#        later-batch sentence. Stricter now: not re-queued, nothing ledgered.
# ============================================================================
reset_case; echo none > "$T/logmode"
later_pass
run_tick
not_requeued R10b
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R10b: job:-only + a later pass stays unknown (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R10b: a job: name is never ledgered (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# R10c — an untouched suite AND a later pass: foreign with both clauses, and the
#        suite is ledgered as a flake keyed on the batch head.
# ============================================================================
reset_case
later_pass
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R10c: re-queued (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_FOREIGN; #3768 on the same main passed it\$" "$T/attr-comments.txt")" = 1 ] \
  && ok || bad "R10c: both clauses (got: $(cat "$T/attr-comments.txt"))"
[ "$(grep -c . "$T/flake-puts.txt")" = 1 ] && ok || bad "R10c: one flake row (got: $(cat "$T/flake-puts.txt"))"
jq -e --arg h "$BATCH" '.test=="tests/fleet-propagate-test.sh" and .workflow==".github/workflows/harness-ci.yml" and .head==$h and .kind=="flake" and .repo=="example-org/mgfy-os"' \
  "$T/flake-puts.txt" >/dev/null 2>&1 && ok || bad "R10c: the flake row is keyed on the batch head (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# R11 — the ledger only takes a KNOWN flake when there is no later evidence.
# ============================================================================
reset_case
run_tick
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R11: empty gate set, no later batch: no flake PUT (got: $(cat "$T/flake-puts.txt"))"
reset_case
jq -nc --arg d "$TODAY" '{flakes: [range(0;3) | {day: $d, repo: "example-org/mgfy-os", workflow: ".github/workflows/harness-ci.yml",
  test: "tests/fleet-propagate-test.sh", head: ("h" + tostring), kind: "flake"}]}' > "$T/flakes"
run_tick
[ "$(grep -c . "$T/flake-puts.txt")" = 1 ] && ok || bad "R11: a suite the ledger knows on 3 heads is written once (got: $(cat "$T/flake-puts.txt"))"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R11: and the PR is re-queued (got $(state_of "$K31"))"

# ============================================================================
# R12 — NO FALSE WITNESS. The requeue does not move Mergify's leftover failure:
#       the row waits on the witness, and the next tick strikes nothing.
# ============================================================================
reset_case; echo x > "$T/noflip"
run_tick
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "R12: a stale failure is not an acknowledgement (got $(state_of "$K31"), '$(reason_of "$K31")')"
case "$(reason_of "$K31")" in *witness*) ok ;; *) bad "R12: the reason names the witness (got '$(reason_of "$K31")')" ;; esac
[ "$(cnt "REQUEUE_ATTRIBUTED $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R12: the requeue was asked, so it is said once (got $(cnt REQUEUE_ATTRIBUTED "$CLOG"))"
printf '[%s]' "$(list_row 31 "$H1" UNSTABLE merge-queue)" > "$T/list.json"
run_tick
grep -qxF "reejected $K31 $H1" "$A" && bad "R12: the leftover failure must not read as a second ejection (attempts: $(cat "$A"))" || ok
[ "$(reason_of "$K31")" = queue-ejected-twice ] && bad "R12: no false strike" || ok
[ "$(cnt 'labels\[\]=merge-queue' "$T/label-adds.txt")" = 1 ] && ok || bad "R12: no second label add (got: $(cat "$T/label-adds.txt"))"
[ "$(state_of "$K31")" = QUEUED ] && bad "R12: our own label plus the stale failure is not a witness on the next tick either (got QUEUED)" || ok
# A third tick on the same stale failure: still no strike — then Mergify moves.
run_tick
grep -qxF "reejected $K31 $H1" "$A" && bad "R12: no false second ejection on the third tick (attempts: $(cat "$A"))" || ok
echo acked > "$T/ckmode"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R12: a real acknowledgement puts the row in QUEUED (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(cnt 'labels\[\]=merge-queue' "$T/label-adds.txt")" = 1 ] && ok || bad "R12: still one label add (got: $(cat "$T/label-adds.txt"))"

# ============================================================================
# R13 — observe mode: says what it would do, writes nothing.
# ============================================================================
reset_case
rm -f "$T/h/flags/merge-conductor-merge"
later_pass
run_tick
grep -q "would REQUEUE $K31 .*re-queued: batch #3767" "$CLOG" && ok || bad "R13: the observe line carries the attribution (log: $(grep 'would REQUEUE' "$CLOG"))"
not_requeued R13
[ ! -s "$T/label-removes.txt" ] && ok || bad "R13: no label removed (got: $(cat "$T/label-removes.txt"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "R13: no flake PUT (got: $(cat "$T/flake-puts.txt"))"
grep -qE "^(fqattr|fqlog) " "$A" && bad "R13: no attempt mark (attempts: $(cat "$A"))" || ok
touch "$T/h/flags/merge-conductor-merge"

# ============================================================================
# R14 — THE CULPRIT HOLD WINS (BH-3728 x BH-3776). The R1 shape, but
#       dequeue-watch named this head the culprit of its batch: the foreign-red
#       requeue must never put it back; a fix round owns it.
# ============================================================================
reset_case
echo "dqwculprit $K31 $H1" >> "$A"
run_tick
not_requeued R14
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "R14: a culprit-marked head waits (got $(state_of "$K31"))"
case "$(reason_of "$K31")" in *culprit*) ok ;; *) bad "R14: the reason names the culprit hold (got '$(reason_of "$K31")')" ;; esac

# ============================================================================
# R15 — FAIL CLOSED. Two failing runs: 5003 is readable and untouched (alone it
#       would be foreign); 5004's log, path, base or head cannot be read, or it
#       is not a merge-queue run. The whole verdict is unreadable: not re-queued,
#       nothing said, nothing ledgered, and nothing cached as foreign.
# ============================================================================
for m in nolog nopath nobase nohead notmq; do
  reset_case; echo "$m" > "$T/run2"
  printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
  later_pass
  run_tick
  not_requeued "R15-$m"
  case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "R15-$m: the reason says the read failed (got '$(reason_of "$K31")')" ;; esac
  [ ! -s "$T/flake-puts.txt" ] && ok || bad "R15-$m: no ledger row (got: $(cat "$T/flake-puts.txt"))"
  grep -qx foreign "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null && bad "R15-$m: nothing is cached as foreign" || ok
done
# R15-ok — the control: 5004 readable and untouched too, so the two runs are foreign.
reset_case
printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R15-ok: both runs readable and untouched: re-queued (got $(state_of "$K31"), '$(reason_of "$K31")')"
grep -q 'tests/fleet-propagate-test.sh, tests/other-suite-test.sh, which this PR does not touch' "$T/attr-comments.txt" \
  && ok || bad "R15-ok: the comment names both suites (got: $(cat "$T/attr-comments.txt"))"
# R15-later — the unreadable run recovers on the next tick: re-queued then.
reset_case; echo nolog > "$T/run2"
printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
run_tick
not_requeued R15-recover-tick1
echo ok > "$T/run2"
# TEST-CHANGE (BH-3857): `unreadable` is now cached for MC_FR_UNREADABLE_TTL_MINS
# (default 15), so the recovery is seen on the first tick past the TTL, not the
# very next one. The cache file is aged past it; the assertion is unchanged.
touch -d '-20 min' "$T/h/state/merge-conductor/foreign-red/"*mgfy-os_31_*
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R15-recover: the log readable again, the next tick re-queues (got $(state_of "$K31"), '$(reason_of "$K31")')"

# ============================================================================
# R16 — UNKNOWN IS CACHED ON THE DEQUEUE COMMENT. An `always` suite with no
#       later pass is unknown (TEST-CHANGE, round 3b: this used R7's job:-only
#       shape, which no later pass may lift any more, so the re-judge below
#       needs a liftable unknown); the next tick on the same comment spends no run,
#       log or file read, only the ONE later-batch read (G1, below). A new
#       dequeue comment (or the same one edited) is new evidence, read in full.
#       TEST-CHANGE (#3798 round 2, G1): tick 2 used to assert no
#       `event=pull_request` read either. That read is the only place later-batch
#       evidence comes from and Mergify never edits the dequeue comment when
#       another batch passes, so forbidding it froze the row in WAIT_CI.
# ============================================================================
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\talways\\t*\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued R16-tick1
grep -q 'actions/runs/5003' "$T/gh-calls.txt" && ok || bad "R16: the first tick reads the run"
: > "$T/gh-calls.txt"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued R16-tick2
grep -qE 'actions/runs/5003|run view 5003|pulls/31/files' "$T/gh-calls.txt" \
  && bad "R16: a cached unknown on the same dequeue comment re-reads no run, log or file list (got: $(grep -E 'actions/runs|run view|pulls/31/files' "$T/gh-calls.txt"))" || ok
grep -q 'event=pull_request' "$T/gh-calls.txt" && ok || bad "R16: a cached unknown still makes the one later-batch read (G1)"
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R16: still one FOREIGN_RED_UNKNOWN line (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
# The same comment edited by Mergify, with a later pass now visible: read again, foreign.
printf '[%s,%s]' "$(older_comment)" "$(dq_comment "$H1" yes "" 7001 2026-09-30T12:00:00Z)" > "$T/comments.json"
later_pass
: > "$T/gh-calls.txt"
run_tick HARNESS_REPO=example-org/mgfy-os
grep -q 'actions/runs/5003' "$T/gh-calls.txt" && ok || bad "R16: an edited dequeue comment is read in full"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R16: the new evidence re-queues (got $(state_of "$K31"), '$(reason_of "$K31")')"

# ============================================================================
# R17 — NO `on draft #N` IN THE COMMENT. The empty draft field must not collapse
#       under `IFS=$'\t' read` and swallow the run ids: still attributed.
# ============================================================================
reset_case
printf '[%s]' "$(dq_comment "$H1" no)" > "$T/comments.json"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R17: a comment with no draft number is still attributed (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c '^re-queued: the batch failed tests/fleet-propagate-test.sh, which this PR does not touch$' "$T/attr-comments.txt")" = 1 ] \
  && ok || bad "R17: the sentence has no draft number (got: $(cat "$T/attr-comments.txt"))"

# ============================================================================
# G1 — A CACHED `unknown` IS RE-JUDGED ON LATER-BATCH EVIDENCE, WITH THE DEQUEUE
#      COMMENT UNEDITED (what Mergify really does). Tick 1 is unknown and cached;
#      tick 2 sees a later green batch of the same workflow on the same main and
#      re-queues, spending no run, log or file read.
#      TEST-CHANGE (round 3b): the unknown here was R7's job:-only shape, which
#      a later pass may no longer lift (R10b, J1-J4). It is now an `always`
#      suite: checked against the PR, untouched, yet not "untouched path".
# ============================================================================
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\talways\\t*\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued G1-tick1
later_pass
: > "$T/gh-calls.txt"
run_tick HARNESS_REPO=example-org/mgfy-os
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "G1: a later pass after a cached unknown re-queues (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_LATER\$" "$T/attr-comments.txt")" = 1 ] \
  && ok || bad "G1: the later-batch sentence (got: $(cat "$T/attr-comments.txt"))"
grep -qE 'actions/runs/5003|run view 5003|pulls/31/files' "$T/gh-calls.txt" \
  && bad "G1: the re-judge spends no run, log or file read (got: $(grep -E 'actions/runs/5003|run view|pulls/31/files' "$T/gh-calls.txt"))" || ok
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G1: an always suite is never ledgered (got: $(cat "$T/flake-puts.txt"))"
grep -qx foreign "$T/h/state/merge-conductor/foreign-red/"*mgfy-os_31_* 2>/dev/null && ok || bad "G1: the re-judged verdict is cached as foreign"
# G1-ledger — the cached rows carry the untouched suite: a path name next to an
# `always` suite in a second run is unknown on tick 1, foreign on tick 2 with ONE
# ledger row keyed on the batch head. (TEST-CHANGE, round 3b: the second run was
# job:-only, which no longer lifts; J3 below pins that.)
reset_case
printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
printf '#!/bin/bash\nprintf "tests/other-suite-test.sh\\talways\\t*\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued G1-ledger-tick1
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "G1-ledger: re-queued on tick 2 (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c . "$T/flake-puts.txt")" = 1 ] && ok || bad "G1-ledger: one flake row (got: $(cat "$T/flake-puts.txt"))"
jq -e --arg h "$BATCH" '.test=="tests/fleet-propagate-test.sh" and .head==$h' "$T/flake-puts.txt" >/dev/null 2>&1 \
  && ok || bad "G1-ledger: the row is the untouched suite on the batch head (got: $(cat "$T/flake-puts.txt"))"
# G1-nolater — a later batch on ANOTHER main never lifts the cached unknown.
reset_case; echo none > "$T/logmode"
run_tick
printf '{"total_count":1,"workflow_runs":[%s]}' "$(later_run 5010 3768 .github/workflows/harness-ci.yml deadbee 2026-09-30T10:30:00Z)" > "$T/later"
run_tick
not_requeued G1-nolater
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "G1-nolater: still one unknown line (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"

# ============================================================================
# G2 — AN UNREADABLE LOG IS UNREADABLE, NOT `job:<name>`. `gh run view
#      --log-failed` fails, the jobs API answers, the PR's diff holds the suite
#      that really failed, and a later batch passed: today the job: fallback
#      reads as "nothing touched" and the PR is re-queued as foreign.
# ============================================================================
reset_case; echo fail > "$T/logmode"
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
later_pass
run_tick
not_requeued G2
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "G2: an unreadable log is unreadable (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G2: no ledger row (got: $(cat "$T/flake-puts.txt"))"
grep -qx foreign "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null && bad "G2: nothing is cached as foreign" || ok

# ============================================================================
# G3 — THE TEST-IMPACT MAP, FAIL CLOSED. An `always` or `full` suite is never
#      untouched; a failed `select` is unreadable.
# ============================================================================
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\talways\\t*\\n"\necho "impact: 1 of 1516 suites (selected: 2 changed path(s))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "G3-always-later: a later pass lifts it (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_LATER\$" "$T/attr-comments.txt")" = 1 ] && ok || bad "G3-always-later: the later clause only, never 'does not touch' (got: $(cat "$T/attr-comments.txt"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G3-always-later: an always-run suite is never ledgered (got: $(cat "$T/flake-puts.txt"))"
reset_case
printf '#!/bin/bash\nprintf "tests/fleet-propagate-test.sh\\tfull\\tfull: infra change (bin/lib/mc/classify.sh)\\n"\necho "impact: 1516 of 1516 suites (full: infra change (bin/lib/mc/classify.sh))" >&2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued G3-full
# TEST-CHANGE (#3798 round 3, N1/X2): this asserted FOREIGN_RED_UNKNOWN. A
# `full` row means THIS diff made CI run the whole corpus, so every suite in it
# is tied to the PR: own (stricter than unknown — raw CLEAN no longer re-queues).
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "G3-full: a suite this diff ran through the corpus is the PR's own (got own=$(cnt FOREIGN_RED_OWN "$CLOG") unknown=$(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G3-full: no ledger row (got: $(cat "$T/flake-puts.txt"))"
reset_case
printf '#!/bin/bash\necho "test-impact: no such root" >&2; exit 2\n' > "$T/h/bin/test-impact.sh"; chmod +x "$T/h/bin/test-impact.sh"
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued G3-fail
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "G3-fail: a failed select is unreadable (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G3-fail: no ledger row (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# G4 — A CAPPED NAME LIST IS UNREADABLE. 21 failing suites, the PR's own the
#      21st: a 20-name cap would drop it and call the rest "untouched".
# ============================================================================
reset_case; echo many > "$T/logmode"
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
run_tick
not_requeued G4
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "G4: a capped list is unreadable (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/flake-puts.txt" ] && ok || bad "G4: no ledger row (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# HOLD — raw CLEAN never re-queues an `unreadable` verdict; raw CLEAN with
#        `unknown` still re-queues (the BH-636 path).
# ============================================================================
reset_case CLEAN; echo acked > "$T/ckmode"; echo nolog > "$T/run2"
printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
run_tick
not_requeued HOLD-unreadable
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "HOLD-unreadable: raw CLEAN + unreadable waits with the read reason (got '$(reason_of "$K31")')" ;; esac
reset_case CLEAN; echo acked > "$T/ckmode"; echo none > "$T/logmode"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "HOLD-unknown: raw CLEAN + unknown still re-queues, BH-636 (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(cnt '@mergifyio requeue' "$T/comments.txt")" = 1 ] && ok || bad "HOLD-unknown: one requeue (got: $(cat "$T/comments.txt"))"

# ============================================================================
# R19 — ANY EXACT MATCH IS A TOUCH. A failing name that is not path-shaped (a
#       vitest title) but equals a file in the PR's diff is the PR's own, even
#       with a later pass. This is what makes the ledger filter unreachable.
# ============================================================================
reset_case; echo title > "$T/logmode"
printf 'Makefile\n' > "$T/files"
later_pass
run_tick
not_requeued R19
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R19: a name equal to a PR file is own (got $(cnt FOREIGN_RED_OWN "$CLOG"))"

# ============================================================================
# R20 — OBSERVE MODE LOGS OWN/UNKNOWN ONCE PER HEAD, and still marks nothing.
# ============================================================================
reset_case
rm -f "$T/h/flags/merge-conductor-merge"
printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
run_tick; run_tick
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R20-own: one line over two observe ticks (got $(cnt FOREIGN_RED_OWN "$CLOG"))"
reset_case; echo none > "$T/logmode"
rm -f "$T/h/flags/merge-conductor-merge"
run_tick; run_tick
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "R20-unknown: one line over two observe ticks (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
grep -qE "^(fqattr|fqlog) " "$A" && bad "R20: no attempt mark in observe mode (attempts: $(cat "$A"))" || ok
touch "$T/h/flags/merge-conductor-merge"

# ============================================================================
# ROUND 3 (#3798 re-review of 4cbe3956). the operator's rule: a failing suite the PR
# touches — by file, by map tie, or because the diff made CI run the corpus —
# is ALWAYS own; a failing run or check that cannot be FULLY attributed is
# unreadable. Never re-queued, never ledgered.
# ============================================================================
impact_stub() { # impact_stub <rows-printf> <reason|-> [fd] — a test-impact stand-in
  #   writing its reason line where the real one does (stderr: ti_emit routes
  #   fd 3 there) or on fd 3; `-` writes no reason line at all.
  local fd="${3:-2}"
  { printf '#!/bin/bash\nprintf "%s"\n' "$1"
    [ "$2" = - ] || printf 'echo "impact: 97 of 1516 suites (%s)" >&%s\n' "$2" "$fd"; } > "$T/h/bin/test-impact.sh"
  chmod +x "$T/h/bin/test-impact.sh"
}
CORPUS='map-only: CI runs the corpus, full: infra change (catalog/lanes.d/merge-conductor.json)'

# N1 — AN INFRA / UNKNOWN-REACH DIFF RUNS THE CORPUS. --map-only lists only the
#      map's picks; the reason line says CI ran everything. Every failing suite
#      is then the PR's own (X1), on stderr (the real channel) or fd 3.
for fd in 2 3; do
  reset_case
  printf 'catalog/lanes.d/merge-conductor.json\n' > "$T/files"
  impact_stub 'tests/lanes-build-test.sh\\tsource\\tcatalog/lanes.d/merge-conductor.json\\n' "$CORPUS" "$fd"
  run_tick HARNESS_REPO=example-org/mgfy-os
  not_requeued "N1-X1-fd$fd"
  [ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "N1-X1-fd$fd: a corpus diff owns every failing suite (got own=$(cnt FOREIGN_RED_OWN "$CLOG"), '$(reason_of "$K31")')"
done
# X1b — the same, and a later batch on the same main passed: still own, and the
#       PR's own break never reaches ci_flakes.
reset_case
printf 'catalog/lanes.d/merge-conductor.json\n' > "$T/files"
impact_stub 'tests/lanes-build-test.sh\\tsource\\tcatalog/lanes.d/merge-conductor.json\\n' "$CORPUS"
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued N1-X1b
[ ! -s "$T/flake-puts.txt" ] && ok || bad "N1-X1b: the PR's own break is never ledgered (got: $(cat "$T/flake-puts.txt"))"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "N1-X1b: own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
# X2 — a `full` row is touched, not liftable: own even with a later pass.
reset_case
impact_stub 'tests/fleet-propagate-test.sh\\tfull\\tfull: infra change (bin/lib/mc/classify.sh)\\n' 'full: infra change (bin/lib/mc/classify.sh)'
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued N1-X2
[ ! -s "$T/flake-puts.txt" ] && ok || bad "N1-X2: no ledger row (got: $(cat "$T/flake-puts.txt"))"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "N1-X2: a full row is own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
# N1-fullrow — a `full` row (any suite) means CI ran the corpus, whatever the reason line says.
reset_case
impact_stub 'tests/lanes-build-test.sh\\tfull\\tfull: the selection came back empty\\n' 'selected: 2 changed path(s)'
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued N1-fullrow
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "N1-fullrow: a full row is own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
# N1-noreason — rows but no reason line: whether CI ran the corpus is unknown,
#   so the map cannot clear anything: unreadable.
reset_case
impact_stub 'tests/lanes-build-test.sh\\tsource\\tbin/lib/mc/classify.sh\\n' -
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued N1-noreason
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "N1-noreason: no reason line is unreadable (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/flake-puts.txt" ] && ok || bad "N1-noreason: no ledger row (got: $(cat "$T/flake-puts.txt"))"
# N1-contract — the REAL bin/test-impact.sh: a selector catalog and a test
#   helper read as the corpus; a mapped lib path and a mapped catalog/ path
#   (BH-7027) as a selection.
if [ -x "$DIR/bin/test-impact.sh" ]; then
  for c in 'catalog/test-tiers.tsv corpus' 'catalog/lanes.d/merge-conductor.json selected' 'tests/lib/scratch.sh corpus' 'bin/lib/mc-foreign-red.sh selected'; do
    printf '%s\n' "${c% *}" > "$T/ti-changed"
    "$DIR/bin/test-impact.sh" select --why --map-only --changed "$T/ti-changed" --root "$DIR" >/dev/null 2>"$T/ti-reason" 3>&2
    got=$( . "$T/h/bin/lib/mc-foreign-red.sh" 2>/dev/null; _fr_impact_scope "$T/ti-reason" 2>/dev/null) || got="rc$?"
    [ "$got" = "${c#* }" ] && ok || bad "N1-contract: ${c% *} reads as ${c#* } from the real test-impact (got '$got'; reason: $(cat "$T/ti-reason"))"
  done
fi

# N2 — EVERY FAILED JOB MUST NAME WHAT FAILED. One shard names an untouched
#      suite, the SPA job (a build the PR broke) names nothing: not fully
#      attributed, unreadable (X3), later pass or not (X3b).
for v in X3 X3b; do
  reset_case; echo mixed > "$T/logmode"
  printf 'Tests, traced (shard 2 of 8)\nMission Control SPA — unit tests + build\n' > "$T/jobs5003"
  printf 'console-ui/src/App.tsx\n' > "$T/files"
  [ "$v" = X3b ] && later_pass
  run_tick
  not_requeued "N2-$v"
  case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "N2-$v: a failed job that names nothing is unreadable (got '$(reason_of "$K31")')" ;; esac
  [ ! -s "$T/flake-puts.txt" ] && ok || bad "N2-$v: no ledger row (got: $(cat "$T/flake-puts.txt"))"
  grep -qx foreign "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null && bad "N2-$v: nothing is cached as foreign" || ok
done
# The fan-in check. `Pure-logic gate fixtures` only judges the shards' verdict
# files (bin/ci-verdicts.sh pure): its log names no test, only "shard i/N: k of
# m tests failed. Open '<shard job>'". That is attributed THROUGH the shard it
# points at, when that shard is itself a failed job that named its suites. The
# text is produced by the real script, so a reworded message turns this red.
mk_fanin() { # mk_fanin ok|missing0
  local vd="$T/verdicts"; scratch_rm "$vd"; mkdir -p "$vd"
  [ "$1" = missing0 ] || printf 'tests=10\nfailed=0\nhits=0\npure=pass\ntrace=clean\n' > "$vd/shard-0.txt"
  printf 'tests=5\nfailed=1\nhits=0\npure=fail\ntrace=clean\n' > "$vd/shard-1.txt"
  PLAN_RESULT=success bash "$DIR/bin/ci-verdicts.sh" pure "$vd" 2 15 2>&1 | sed 's/^::error::/##[error]/' > "$T/fanin.txt"
  echo '##[error]Process completed with exit code 1.' >> "$T/fanin.txt"
}
mk_fanin ok
grep -q "^##\[error\]shard 1/2: 1 of 5 tests failed\. Open 'Tests, traced (shard 1/2)'" "$T/fanin.txt" \
  && ok || bad "N2-fanin: bin/ci-verdicts.sh still prints the shard pointer the attribution reads (got: $(cat "$T/fanin.txt"))"
reset_case; echo fanin > "$T/logmode"; mk_fanin ok
printf 'Tests, traced (shard 1/2)\nPure-logic gate fixtures\n' > "$T/jobs5003"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "N2-fanin: a fan-in pointing at a named shard is attributed: re-queued (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_FOREIGN\$" "$T/attr-comments.txt")" = 1 ] && ok || bad "N2-fanin: the foreign sentence (got: $(cat "$T/attr-comments.txt"))"
# ...pointing at a shard that is not a failed job of this run: unreadable.
reset_case; echo fanin > "$T/logmode"; mk_fanin ok
sed -i 's#shard 1/2#shard 0/2#g' "$T/fanin.txt"
printf 'Tests, traced (shard 1/2)\nPure-logic gate fixtures\n' > "$T/jobs5003"
later_pass
run_tick
not_requeued N2-fanin-stray
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "N2-fanin-stray: unreadable (got '$(reason_of "$K31")')" ;; esac
# ...and a fan-in that also says a shard left no verdict: that shard's tests are
#    unknown, so the run is not fully attributed.
reset_case; echo fanin > "$T/logmode"; mk_fanin missing0
printf 'Tests, traced (shard 1/2)\nPure-logic gate fixtures\n' > "$T/jobs5003"
later_pass
run_tick
not_requeued N2-fanin-missing
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "N2-fanin-missing: unreadable (got '$(reason_of "$K31")')" ;; esac

# N3 — A NON-ACTIONS FAILING CHECK. The dequeue comment lists a Vercel build next
#      to an Actions run that names an untouched suite: the Vercel failure cannot
#      be read, so the batch is unreadable (X6).
reset_case
dq_comment "$H1" | jq -c '.body |= sub("Failing checks:\n"; "Failing checks:\n- ❌ [`Vercel – mgfy-os`](https://vercel.com/example-org/mgfy-os/abc)\n")' > "$T/one.json"
printf '[%s]' "$(cat "$T/one.json")" > "$T/comments.json"
grep -q 'Vercel' "$T/comments.json" && ok || bad "N3: the fixture injected the Vercel bullet"
later_pass
run_tick
not_requeued N3-X6
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "N3-X6: a non-Actions failing check is unreadable (got '$(reason_of "$K31")')" ;; esac
[ ! -s "$T/flake-puts.txt" ] && ok || bad "N3-X6: no ledger row (got: $(cat "$T/flake-puts.txt"))"

# MINOR — the once-per-head log mark carries its verdict: an `own` line after an
#         `unknown` line on the same head is still written (merges on).
#         (A head's file list is cached per head, so it is the same both ticks;
#         the re-read dequeue comment is what brings the suite name.)
reset_case; echo none > "$T/logmode"; printf 'tests/fleet-propagate-test.sh\n' > "$T/files"
run_tick
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "MINOR: tick 1 is unknown (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
echo suite > "$T/logmode"
printf '[%s,%s]' "$(older_comment)" "$(dq_comment "$H1" yes "" 7001 2026-09-30T12:00:00Z)" > "$T/comments.json"
run_tick
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "MINOR: an own line after an unknown line on the same head is logged (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"

# ============================================================================
# J — A `job:` NAME IS NEVER LIFTED (the operator, 16:02Z). Later-batch evidence may
#     turn unknown into foreign only when the PR touches none of the failing
#     tests; a job name cannot be checked for touch, so any verdict holding one
#     stays unknown: not re-queued on Mergify-only UNSTABLE, never ledgered.
#     Raw CLEAN + unknown keeps BH-636's plain requeue.
# ============================================================================
# J1 — job:-only, the later pass already visible on tick 1.
reset_case; echo none > "$T/logmode"; later_pass
run_tick
not_requeued J1
[ ! -s "$T/flake-puts.txt" ] && ok || bad "J1: no flake row (got: $(cat "$T/flake-puts.txt"))"
grep -qx foreign "$T/h/state/merge-conductor/foreign-red/"* 2>/dev/null && bad "J1: nothing is cached as foreign" || ok
# J2 — job:-only cached as unknown on tick 1, the later pass arrives on tick 2.
reset_case; echo none > "$T/logmode"
run_tick
later_pass
run_tick
not_requeued J2
[ ! -s "$T/flake-puts.txt" ] && ok || bad "J2: no flake row (got: $(cat "$T/flake-puts.txt"))"
# J3 — an untouched path in one run, job:-only in another, later pass on both
#      ticks: the job: run cannot be cleared, so neither is the batch.
reset_case; echo jobonly > "$T/run2"
printf '[%s]' "$(dq_comment "$H1" yes 5004)" > "$T/comments.json"
later_pass
run_tick; run_tick
not_requeued J3
[ ! -s "$T/flake-puts.txt" ] && ok || bad "J3: no flake row, not even for the path suite (got: $(cat "$T/flake-puts.txt"))"
# J4 — raw CLEAN: job:-only + a later pass is unknown, and CLEAN + unknown is
#      BH-636's plain requeue: re-queued, but no attribution comment, no row.
reset_case CLEAN; echo acked > "$T/ckmode"; echo none > "$T/logmode"; later_pass
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "J4: CLEAN + unknown keeps the BH-636 requeue (got $(state_of "$K31"), '$(reason_of "$K31")')"
grep -q 're-queued:' "$T/attr-comments.txt" && bad "J4: no foreign attribution comment (got: $(cat "$T/attr-comments.txt"))" || ok
[ ! -s "$T/flake-puts.txt" ] && ok || bad "J4: no flake row (got: $(cat "$T/flake-puts.txt"))"

# ============================================================================
# ROUND 4 (#3798 re-review of b9c0bc8e)
# ============================================================================
# F1 — A TEST TITLE IS NEVER LIFTED. A vitest/jest title ("GET /api/x > returns
#      200", "foo › works") names a test, not a file: whether the PR touches it
#      cannot be checked, exactly like a job: name. A later pass never makes it
#      foreign: not re-queued, nothing said, nothing ledgered.
reset_case; echo advvitest > "$T/logmode"; printf 'Jobs worker — routes + schema\n' > "$T/jobs5003"
printf 'worker/jobs/src/index.js\n' > "$T/files"
impact_stub 'tests/jobs-worker-test.sh\\tsource\\tworker/jobs/src/index.js\\n' 'selected: 1 changed path(s)'
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued F1-A2
[ ! -s "$T/flake-puts.txt" ] && ok || bad "F1-A2: no flake row (got: $(cat "$T/flake-puts.txt"))"
[ "$(cnt "FOREIGN_RED_UNKNOWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "F1-A2: a title is unknown (got $(cnt FOREIGN_RED_UNKNOWN "$CLOG"))"
# A2b — the title cached as unknown on tick 1, the later pass on tick 2.
reset_case; echo advvitest > "$T/logmode"; printf 'Jobs worker — routes + schema\n' > "$T/jobs5003"
printf 'worker/jobs/src/index.js\n' > "$T/files"
impact_stub 'tests/jobs-worker-test.sh\\tsource\\tworker/jobs/src/index.js\\n' 'selected: 1 changed path(s)'
run_tick HARNESS_REPO=example-org/mgfy-os
later_pass
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued F1-A2b
[ ! -s "$T/flake-puts.txt" ] && ok || bad "F1-A2b: no flake row (got: $(cat "$T/flake-puts.txt"))"
# A3 — a product repo: a jest file line (untouched path) and a jest title.
reset_case; echo advjest > "$T/logmode"; printf 'test\n' > "$T/jobs5003"; printf 'src/foo.ts\n' > "$T/files"
later_pass
run_tick
not_requeued F1-A3
[ ! -s "$T/flake-puts.txt" ] && ok || bad "F1-A3: no flake row (got: $(cat "$T/flake-puts.txt"))"

# F3 — THE NAME IS THE RUNNER'S, NOT "<job><step><timestamp> FAIL …". A jest
#      FAIL file line read through gh's job/step/timestamp prefix is the path
#      itself: foreign and said cleanly when untouched, own when the PR has it.
reset_case; echo jestfile > "$T/logmode"; printf 'test\n' > "$T/jobs5003"; printf 'src/foo.ts\n' > "$T/files"
run_tick
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "F3: an untouched jest file is foreign (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c '^re-queued: batch #3767 failed src/foo.test.ts, which this PR does not touch$' "$T/attr-comments.txt")" = 1 ] \
  && ok || bad "F3: the sentence names the bare path (got: $(cat "$T/attr-comments.txt"))"
reset_case; echo jestfile > "$T/logmode"; printf 'test\n' > "$T/jobs5003"; printf 'src/foo.test.ts\n' > "$T/files"
later_pass
run_tick
not_requeued F3-own
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "F3-own: the PR's own jest file is own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
[ ! -s "$T/flake-puts.txt" ] && ok || bad "F3-own: no flake row (got: $(cat "$T/flake-puts.txt"))"

# F4 — A JOBS PAGE THAT DOES NOT HOLD EVERY JOB IS NO ANSWER. The R1 shape,
#      but the jobs API says 5 jobs and lists 1: unreadable.
reset_case; echo 5 > "$T/jobstotal"
later_pass
run_tick
not_requeued F4
case "$(reason_of "$K31")" in *"could not be read this tick"*) ok ;; *) bad "F4: a partial jobs page is unreadable (got '$(reason_of "$K31")')" ;; esac

# F2 — THE MAP CANNOT BE BUILT HERE (the hub: MC_H has no tests/, so the real
#      test-impact answers `full: the map could not be built`, rc 0). That is
#      not a corpus diff and not the PR's own: attribution is impossible in this
#      environment, so the arm falls back to exactly BH-636 (re-queue only on raw
#      CLEAN, no attribution comment, no cache, no ledger), logged once a head.
for ms in CLEAN UNSTABLE; do
  reset_case "$ms"; [ "$ms" = CLEAN ] && echo acked > "$T/ckmode"
  cp "$DIR/bin/test-impact.sh" "$T/h/bin/test-impact.sh"; cp "$DIR/bin/lib/train-shape.sh" "$T/h/bin/lib/" 2>/dev/null
  later_pass
  run_tick HARNESS_REPO=example-org/mgfy-os
  [ "$(cnt "FOREIGN_RED_OWN $K31" "$CLOG")" = 0 ] && ok || bad "F2-$ms: a map that cannot be built is not own (got $(grep FOREIGN_RED "$CLOG"))"
  grep -qx own "$T/h/state/merge-conductor/foreign-red/"*mgfy-os_31_* 2>/dev/null && bad "F2-$ms: nothing cached as own" || ok
  grep -q 're-queued:' "$T/attr-comments.txt" && bad "F2-$ms: no attribution comment (got: $(cat "$T/attr-comments.txt"))" || ok
  [ ! -s "$T/flake-puts.txt" ] && ok || bad "F2-$ms: no flake row (got: $(cat "$T/flake-puts.txt"))"
  if [ "$ms" = CLEAN ]; then
    [ "$(state_of "$K31")" = QUEUED ] && ok || bad "F2-CLEAN: BH-636 re-queues raw CLEAN (got $(state_of "$K31"), '$(reason_of "$K31")')"
    [ "$(cnt '@mergifyio requeue' "$T/comments.txt")" = 1 ] && ok || bad "F2-CLEAN: one requeue (got: $(cat "$T/comments.txt"))"
  else
    not_requeued F2-UNSTABLE
    run_tick HARNESS_REPO=example-org/mgfy-os
    [ "$(cnt "FOREIGN_RED_NOMAP $K31 $H1" "$CLOG")" = 1 ] && ok || bad "F2-UNSTABLE: one FOREIGN_RED_NOMAP line over two ticks (got $(cnt FOREIGN_RED_NOMAP "$CLOG"))"
  fi
done

# ============================================================================
# ROUND 5 (#3798 re-review of 56c8d734) — A NAME IS A PATH BY PROVENANCE, NOT
# SHAPE. Only the harness `--- tests/<x>.sh rc=` line and a jest/vitest
# `FAIL <file>` token are paths; every other runner name is a title and
# unattributable, whatever it looks like (`works`, `api/health`).
# ============================================================================
# ADV-1 — product repo, a one-word title in a test file the PR edited, later
#         pass: the FAIL file is the PR's own.
reset_case; echo advone > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'test/routes.test.js\n' > "$T/files"
later_pass
run_tick
not_requeued ADV-1
[ ! -s "$T/flake-puts.txt" ] && ok || bad "ADV-1: no flake row (got: $(cat "$T/flake-puts.txt"))"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "ADV-1: the FAIL file the PR edited is own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
# ADV-1b — the same title, file untouched, later pass: the title is not a path,
#          so it is unknown, never lifted.
reset_case; echo advone > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'src/other.ts\n' > "$T/files"
later_pass
run_tick
not_requeued ADV-1b
[ ! -s "$T/flake-puts.txt" ] && ok || bad "ADV-1b: no flake row (got: $(cat "$T/flake-puts.txt"))"
# ADV-1c — a bare `×` title, no FAIL line, later pass: unattributable.
reset_case; echo advbare > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'src/other.ts\n' > "$T/files"
later_pass
run_tick
not_requeued ADV-1c
[ ! -s "$T/flake-puts.txt" ] && ok || bad "ADV-1c: no flake row (got: $(cat "$T/flake-puts.txt"))"
# ADV-2 — a title with a slash, the PR edited the test file, no later pass.
reset_case; echo advslash > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'test/routes.test.js\n' > "$T/files"
run_tick
not_requeued ADV-2
grep -q 'which this PR does not touch' "$T/attr-comments.txt" && bad "ADV-2: a title is never an untouched path (got: $(cat "$T/attr-comments.txt"))" || ok
# ADV-2b — the slash title, file untouched, no later pass: still not a path.
reset_case; echo advslash > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'src/other.ts\n' > "$T/files"
run_tick
not_requeued ADV-2b
# ADV-3 — ADV-2 plus a later pass: no ledger row for the title.
reset_case; echo advslash > "$T/logmode"; printf 'Jobs worker\n' > "$T/jobs5003"; printf 'test/routes.test.js\n' > "$T/files"
later_pass
run_tick
not_requeued ADV-3
[ ! -s "$T/flake-puts.txt" ] && ok || bad "ADV-3: no flake row (got: $(cat "$T/flake-puts.txt"))"

# ANCHOR — `nomap` is read from test-impact's own reason line only. A PR path
#          that contains the phrase must not switch attribution off.
NMP='docs/full: the map could not be built.md'
reset_case; printf '%s\n' "$NMP" > "$T/files"
impact_stub "tests/x-test.sh\\\\tsource\\\\t$NMP\\\\n" "map-only: CI runs the corpus, full: unknown reach ($NMP)"
run_tick HARNESS_REPO=example-org/mgfy-os
not_requeued ANCHOR-corpus
[ "$(cnt "FOREIGN_RED_NOMAP $K31" "$CLOG")" = 0 ] && ok || bad "ANCHOR-corpus: a path holding the phrase is not nomap"
[ "$(cnt "FOREIGN_RED_OWN $K31 $H1" "$CLOG")" = 1 ] && ok || bad "ANCHOR-corpus: the corpus diff is own (got own=$(cnt FOREIGN_RED_OWN "$CLOG"))"
reset_case; printf '%s\n' "$NMP" > "$T/files"
impact_stub "tests/x-test.sh\\\\tsource\\\\t$NMP\\\\n" 'selected: 1 changed path(s)'
run_tick HARNESS_REPO=example-org/mgfy-os
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "ANCHOR-selected: an untouched suite is foreign, not nomap (got $(state_of "$K31"), '$(reason_of "$K31")')"
[ "$(grep -c "^$SENT_FOREIGN\$" "$T/attr-comments.txt")" = 1 ] && ok || bad "ANCHOR-selected: the foreign sentence (got: $(cat "$T/attr-comments.txt"))"

echo "requeue-after-foreign-red.bh-3776: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
