#!/bin/bash
# tests/mq-cap-cancel-requeue.bh-7620-test.sh — BH-7620: a merge-queue batch
# whose shards were cancelled at the 45 min job cap, with no failed test, is
# not a strike. Its PRs go back in the queue once, with no person and no fix
# round. A real test failure next to a cancelled shard is still a strike.
#
# THE CASE (2026-10-19 ~21:22Z). Batch draft #7613 held #7417, #7515 and
# #7558. Run 39320354238 planned 12 shards; shards 4, 5, 7, 8 and 10 were
# cancelled at 45.4 min, both fan-ins printed only "shard i/12 left no verdict"
# and Mergify ejected the batch. The settle pass wrote `ejected` and counted
# strikes BEFORE anything read the batch, so a PR with an older ejection on an
# earlier head went to `queue-ejected-twice` and a fix round. the operator re-queued
# all three by hand.
#
# FIXTURES. The fan-in logs are written by the REAL bin/ci-verdicts.sh (12
# shards, shards 4,5,7,8,10 with no verdict file). The jobs page has the shape
# of the run's job list as the plan read it (7 shards success, 5 cancelled at
# 45.4 min); the API was not reachable from the build box, so the job names,
# conclusions and walls are the recorded ones, not a byte copy. The Mergify
# comment is the REAL #4121 dequeue comment (tests/fixtures/bh-4428/), edited
# to draft #7613, this head and the two fan-in run links, as BH-6336 does.
#
# Part 1 (U1-U11) is the strike count over seeded attempt lines.
# Part 2 drives the real bin/merge-conductor.sh, settle pass first:
#   C1  the first cap eject: EJECTED_NOVERDICT at the settle tick, WAIT_CI;
#       the next tick re-queues once; the jobs page is read once in total
#   C2  the same, with an `ejected` line on an OLDER head: not
#       queue-ejected-twice, no fix round, one requeue (red on 59abab56)
#   C3  a real test failure on shard 3 next to the cancelled shards: no
#       requeue, no EJECTED_NOVERDICT, the row ends where it ends without the lib
#   C4  the jobs page cannot be read at the settle tick: the ejection counts
#       (older strike -> queue-ejected-twice), no `nvunread` line
#   C5  the re-queued head ejected again by a second cap batch:
#       queue-ejected-twice, no second requeue, exactly one crit alert
#   C6  the #7613 shape: three PRs in one draft, one with an older strike:
#       each is re-queued exactly once (red on 59abab56)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mq-cap-cancel-requeue.bh-7620-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
FX4428="$REPO/tests/fixtures/bh-4428"
export HARNESS="$T/h"
NOW=$(date -u +%s)

PURE='Pure-logic gate fixtures'
TRACE='Tests cannot touch a real harness'
TS='2026-10-19T21:21:00.0000000Z'

# fanin_log <out> <n> <count> <spec…> — the --log-failed text of both fan-in
# jobs, from the real bin/ci-verdicts.sh. spec per shard i (0-based, as the
# verdict files are named): ok | missing | fail.
fanin_log() {
  local out="$1" n="$2" count="$3" vd="$T/verdicts" i s lane job rc body
  shift 3
  scratch_rm "$vd"; mkdir -p "$vd"; : > "$out"
  i=0
  for s in "$@"; do
    case "$s" in
      ok)   printf 'tests=%s\nfailed=0\nhits=0\npure=pass\ntrace=clean\n' "$((count / n))" > "$vd/shard-$i.txt" ;;
      fail) printf 'tests=%s\nfailed=1\nhits=0\npure=fail\ntrace=clean\n' "$((count / n))" > "$vd/shard-$i.txt" ;;
      missing) ;;
    esac
    i=$((i + 1))
  done
  for lane in pure trace; do
    job="$PURE"; [ "$lane" = trace ] && job="$TRACE"
    rc=0; body=$(PLAN_RESULT=success bash "$REPO/bin/ci-verdicts.sh" "$lane" "$vd" "$n" "$count" 2>&1) || rc=$?
    [ "$rc" = 0 ] && continue
    { printf '%s\n' "$body"; echo '::error::Process completed with exit code 1.'; } \
      | sed 's/^::error::/##[error]/' | sed "s/^/$job\tthe verdict\t$TS /" >> "$out"
  done
}
# cap_jobs <out> <spec…> — run 39320354238's job list: 12 traced shards, a
# spec per shard (0-based): ok (success, 20.7 min) | cap (cancelled at
# 45.4 min) | fail (failure, 31 min); plus the plan job and the two fan-ins.
cap_jobs() {
  local out="$1" i=0 s rows=""
  shift
  for s in "$@"; do
    case "$s" in
      ok)   rows+="Tests, traced (shard $i/12)|success|2026-10-19T20:36:10Z|2026-10-19T20:56:52Z"$'\n' ;;
      cap)  rows+="Tests, traced (shard $i/12)|cancelled|2026-10-19T20:36:10Z|2026-10-19T21:21:34Z"$'\n' ;;
      fail) rows+="Tests, traced (shard $i/12)|failure|2026-10-19T20:36:10Z|2026-10-19T21:07:10Z"$'\n' ;;
    esac
    i=$((i + 1))
  done
  rows+="$PURE|failure|2026-10-19T21:21:40Z|2026-10-19T21:21:58Z"$'\n'
  rows+="$TRACE|failure|2026-10-19T21:21:40Z|2026-10-19T21:22:01Z"$'\n'
  printf '%s' "$rows" | jq -Rsc 'split("\n") | map(select(length > 0) | split("|")
      | {name: .[0], status: "completed", conclusion: .[1], started_at: .[2], completed_at: .[3]})
    | ([{name: "CI plan (what this run tests)", status: "completed", conclusion: "success",
         started_at: "2026-10-19T20:34:02Z", completed_at: "2026-10-19T20:35:51Z"}] + .)
    | {total_count: length, jobs: .}' > "$out"
}
CAP12=(ok ok ok ok cap cap ok cap cap ok cap ok)
LOG12=(ok ok ok ok missing missing ok missing missing ok missing ok)

# ============================================================================
# PART 1 — the strike count over seeded attempt lines (no network).
# ============================================================================
(
  MC_ATTEMPTS="$T/p1-attempts.txt"
  MC_STATE_DIR="$T/p1-state"; mkdir -p "$MC_STATE_DIR"
  # shellcheck source=/dev/null
  . "$REPO/bin/lib/merge-conductor-lib.sh" || exit 1
  MC_ATTEMPTS="$T/p1-attempts.txt"
  P=0; F=0
  pok() { P=$((P+1)); }; pbad() { F=$((F+1)); echo "FAIL: $1"; }
  k="example-org/mgfy-os#7417"; h=7417aaaa7417aaaa7417aaaa7417aaaa7417aaaa; o=7417bbbb7417bbbb7417bbbb7417bbbb7417bbbb
  u() { # u <case> <want> <line…>
    local c="$1" want="$2" got; shift 2
    printf '%s\n' "$@" > "$MC_ATTEMPTS"
    got=$(mc_eject_head_strikes "$k" "$h")
    [ "$got" = "$want" ] && pok || pbad "$c: want $want strike(s), got '$got' (lines: $*)"
  }
  u U1  0 "ejected $k $h" "nvv $k $h 9001 noverdict 7613 39320354238 4/12,5/12"
  u U2  1 "ejected $k $o" "ejected $k $h" "nvv $k $h 9001 noverdict 7613 39320354238 4/12,5/12"
  u U3  1 "ejected $k $h" "nvv example-org/mgfy-os#7515 $h 9001 noverdict 7613 39320354238 4/12"
  u U4  1 "ejected $k $h" "nvv $k $h 9001 real 7613 39320354238 -"
  u U5  2 "ejected $k $h" "nvv $k $h 9001 noverdict 7613 39320354238 4/12" "requeued $k $h" "reejected $k $h"
  u U6  1 "ejected $k $h"
  u U7  1 "ejected $k $h" "nvv $k $h 9001 none 7613 - -"
  u U8  1 "ejected $k $h" "nvv $k $o 9001 noverdict 7613 39320354238 4/12"
  u U9  0 "ejected $k $h" "ejectconflict $k $h"
  u U10 1 "ejected $k $h" "nvv $k $h 9001 noverdict 7613 39320354238 4/12" "nvv $k $h 9002 real 7620 39320354239 -"
  printf '%s\n' "ejected $k $h" "nvv $k $h 9001 noverdict 7613 39320354238 4/12" > "$MC_ATTEMPTS"
  got=$(MC_EJECT_REBASE=0 mc_eject_head_strikes "$k" "$h")
  [ "$got" = 1 ] && pok || pbad "U11: MC_EJECT_REBASE=0 keeps the old count (want 1, got '$got')"
  echo "$P $F" > "$T/p1.result"
)
read -r p f < "$T/p1.result" 2>/dev/null || { p=0; f=1; echo "FAIL: part 1 did not run"; }
PASS=$((PASS+p)); FAIL=$((FAIL+f))

# ============================================================================
# PART 2 — the real conductor, from the settle pass.
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
cp "$REPO/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=fixture-secret\n' > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/catalog"
. "$REPO/tests/lib/lpp-stub.sh" || exit 1
lpp_install "$T/fakebin" "$T/lpp-rows.json" "$T/lpp-down"
printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$T/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "only=%%s project=%%s\\n" "${BR_ONLY_PR:-}" "${1:-}" >> "%s/br-launch.txt"\n' "$T" > "$T/h/bin/blocked-resolver.sh"
chmod +x "$T/h/bin/"*.sh

BASE7=fa1ca57
MAIN_MOVED=9d50520aaaabbbbccccddddeeeeffff000011112
RUN1=39320354238
RUN2=39320354999
OLDH=0000aaaa0000bbbb0000cccc0000dddd0000eeee
headof() { printf '%s%s%s%s%s%s%s%s%s%s' "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" "$1" | cut -c1-40; }
key()    { printf 'example-org/mgfy-os#%s' "$1"; }
printf '7613\tmerge queue: checking #7417, #7515, #7558 on main (%s)\n7621\tmerge queue: checking #7417 on main (%s)\n' "$BASE7" "$BASE7" > "$T/drafts.tsv"
# dq_comment <pr> <draft> <run> <id> <created_at> — #4121's real dequeue
# comment, edited to this PR's head, draft and the two fan-in links on <run>.
dq_comment() {
  jq -c --arg d "$2" --arg r "$3" --arg h "$(headof "$1")" --argjson id "$4" --arg at "$5" --arg pure "$PURE" --arg trace "$TRACE" '
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
sha_of() { sed -n 's|.*/commits/\([0-9a-f]*\)/.*|\1|p' <<<"$*" | head -1; }
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
  # A head's checks: stale (Mergify's failed queue check, an ejection) until a
  # requeue write for that head's PR flips its mode to acked.
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    case "$(cat "$T/ckmode-$(sha_of "$*")" 2>/dev/null || echo stale)" in
      stale) restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked) restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*)
    restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-19T19:00:00Z"}}}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*)
    restpr --raw 200 "$(cat "$T/comments-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/branches/"*) restpr --raw 200 "{\"name\":\"main\",\"commit\":{\"sha\":\"$(cat "$T/mainsha")\"}}" ;;
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
    restpr --raw 200 "{\"id\":$RID,\"head_branch\":\"mergify/merge-queue/abc$RID\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-10-19T20:34:00Z\",\"head_sha\":\"cccccccc11112222333344445555666677778888\",\"display_title\":\"merge queue: checking #7417, #7515, #7558 on main (fa1ca57)\",\"pull_requests\":[]}" ;;
  *"run view "*"--log-failed"*)
    RID=$(awk '{print $3}' <<<"$*")
    cat "$T/log-$RID.txt" 2>/dev/null || exit 1 ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[{"filename":"bin/lib/mc/classify.sh"}]' ;;
  # ---- writes -------------------------------------------------------------
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    if grep -qiE '^@mergifyio (requeue|queue)' "$BF" 2>/dev/null; then
      N=$(pr_of "$*")
      printf '%s %s\n' "$*" "$(head -1 "$BF")" >> "$T/comments.txt"; echo acked > "$T/ckmode-$(cat "$T/head-$N")"
      restpr --raw 201 '{"id":1}'; exit 0
    fi
    { printf '<<PR %s>>\n' "$(pr_of "$*")"; cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/"*)
    N=$(pr_of "$*"); L=$(sed -n 's|.*/labels/\([^ ]*\).*|\1|p' <<<"$*"); printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF "$L" "$T/labels-$N" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels-$N"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-$N"; sort -u -o "$T/labels-$N" "$T/labels-$N"
    echo acked > "$T/ckmode-$(cat "$T/head-$N")"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
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

PRS=()
mkrec() { # mkrec <pr>
  local n="$1" h d
  h=$(headof "$n"); d="$T/h/builds/pool-mgfy-MG-$n-2026101900$n"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$n" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$h" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$h" > "$T/head-$n"
}
# list_rows — the open-PR list as it is NOW: every PR in PRS, its labels from
# labels-<n>, so a label the tick wrote is one the next tick reads.
list_rows() {
  local n out='[]' l
  for n in "${PRS[@]}"; do
    l=$(jq -R -s -c 'split("\n") | map(select(length > 0) | {name: .})' "$T/labels-$n" 2>/dev/null || echo '[]')
    out=$(jq -c --argjson n "$n" --arg h "$(headof "$n")" --argjson l "$l" \
      '. + [{number: $n, url: "https://github.com/example-org/mgfy-os/pull/\($n)", headRefOid: $h, headRefName: "ticket/mg-\($n)",
             isDraft: false, mergeStateStatus: "UNSTABLE", mergeable: "MERGEABLE", state: "OPEN", isInMergeQueue: false,
             labels: $l, baseRefName: "main"}]' <<<"$out")
  done
  printf '%s' "$out" > "$T/list.json"
}
run_tick() {
  list_rows
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.test \
    MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
    bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}
state_of()  { awk -F'\t' -v k="$(key "$1")" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$(key "$1")" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
row()       { echo "$(state_of "$1") '$(reason_of "$1")'"; }
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }
# requeues <pr> — requeue writes for the PR: our label back on, or a
# `@mergifyio requeue|queue` comment.
requeues() { cat "$T/label-adds.txt" "$T/comments.txt" 2>/dev/null | grep -cE "issues/$1/(labels -f labels\[\]=merge-queue|comments.*@mergifyio (requeue|queue))"; }
jobs_reads() { grep -cE "actions/runs/$1/jobs" "$T/gh-calls.txt" 2>/dev/null || true; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# reset_case <draft> <run> <pr…> — every PR queued by this conductor on its
# head (a QUEUED row, our label on), and Mergify's failed queue check and its
# dequeue comment for draft <draft> on run <run>: the settle pass's ejection.
reset_case() {
  local d="$1" r="$2" n
  shift 2
  : > "$A"; : > "$CLOG"; : > "$ALOG"
  for f in label-adds label-removes comments merges gh-calls attr-comments reruns writes br-launch; do : > "$T/$f.txt"; done
  rm -f "$T"/comments-*.json "$T"/labels-* "$T"/head-* "$T"/ckmode-* "$T"/jobs-*.json "$T"/log-*.txt "$T/jobsfail" "$T/h/flags/main-red-mgfy"
  : > "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" "$T/h/state/merge-conductor/batch-eject" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" "$T/h/state/merge-conductor/eject-runs" 2>/dev/null
  rm -rf "$T/h/builds/"pool-mgfy-* 2>/dev/null
  printf '%s' "$MAIN_MOVED" > "$T/mainsha"
  PRS=("$@")
  for n in "$@"; do
    mkrec "$n"
    printf '[%s]' "$(dq_comment "$n" "$d" "$r" 9001 2026-10-19T21:22:30Z)" > "$T/comments-$n.json"
    printf 'merge-queue\n' > "$T/labels-$n"
    mc_row_put "$(key "$n")" QUEUED $((NOW-300)) "$(headof "$n")" "$(headof "$n")" - "in the merge queue" "https://github.com/example-org/mgfy-os/pull/$n"
  done
}
no_fix_round() { # no_fix_round <case> <pr>
  local k; k=$(key "$2")
  grep -qE "^(dqwculprit|reejected|ejectfix|bejculprit) $k " "$A" && bad "$1: no culprit, strike or fix-round mark (got: $(grep -E "^(dqwculprit|reejected|ejectfix|bejculprit) $k " "$A"))" || ok
  [ ! -s "$T/br-launch.txt" ] && ok || bad "$1: no blocked-resolver launch (got: $(cat "$T/br-launch.txt"))"
}

# ============================================================================
# C1 — the first cap eject, no earlier strike.
# ============================================================================
N=7417; K=$(key $N); H=$(headof $N)
reset_case 7613 "$RUN1" $N
cap_jobs "$T/jobs-$RUN1.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN1.txt" 12 240 "${LOG12[@]}"
grep -q "shard 4/12 left no verdict" "$T/log-$RUN1.txt" && ok || bad "C1 setup: bin/ci-verdicts.sh prints the no-verdict line (got: $(head -3 "$T/log-$RUN1.txt"))"
run_tick
grep -qxF "ejected $K $H" "$A" && ok || bad "C1: the settle pass recorded the ejection (attempts: $(cat "$A"); row $(row $N))"
case "$(state_of $N):$(reason_of $N)" in WAIT_CI:queue-ejected*) ok ;; *) bad "C1: the settle tick leaves WAIT_CI queue-ejected (got $(row $N))" ;; esac
[ "$(cnt "EJECTED_NOVERDICT $K $H" "$CLOG")" = 1 ] && ok || bad "C1: EJECTED_NOVERDICT logged once at the settle tick (log: $(grep -o "mgfy-os#$N .*" "$CLOG" | tail -5))"
grep -q "EJECTED_NOVERDICT $K $H — draft #7613 run $RUN1: shard(s) 4/12, 5/12, 7/12, 8/12, 10/12 left no verdict; not a strike" "$CLOG" && ok \
  || bad "C1: the log line names the draft, the run and the shards (got: $(grep EJECTED_NOVERDICT "$CLOG"))"
grep -qxF "nvv $K $H 9001 noverdict 7613 $RUN1 4/12,5/12,7/12,8/12,10/12" "$A" && ok || bad "C1: the verdict is cached at the settle tick (got: $(grep '^nvv' "$A"))"
[ "$(requeues $N)" = 0 ] && ok || bad "C1: the settle tick does not requeue (got $(requeues $N))"
run_tick
[ "$(requeues $N)" = 1 ] && ok || bad "C1: the next tick re-queues once (got $(requeues $N); row $(row $N))"
[ "$(state_of $N)" = QUEUED ] && ok || bad "C1: the row is QUEUED (got $(row $N))"
grep -q "That is an infra retry, not a failure of this PR" "$T/attr-comments.txt" && ok || bad "C1: the PR line says infra retry (got: $(cat "$T/attr-comments.txt"))"
[ "$(jobs_reads $RUN1)" = 1 ] && ok || bad "C1: the jobs page is read once over both ticks (got $(jobs_reads $RUN1))"
[ "$(cnt "^nvv $K " "$A")" = 1 ] && ok || bad "C1: one nvv line (got $(grep '^nvv' "$A"))"
no_fix_round C1 $N

# ============================================================================
# C2 — the same cap eject, with an `ejected` line on an OLDER head of the PR.
# ============================================================================
reset_case 7613 "$RUN1" $N
echo "ejected $K $OLDH" >> "$A"
cap_jobs "$T/jobs-$RUN1.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN1.txt" 12 240 "${LOG12[@]}"
run_tick
case "$(state_of $N):$(reason_of $N)" in WAIT_CI:queue-ejected*) ok ;; *) bad "C2: an earlier head's strike does not park a cap eject (got $(row $N))" ;; esac
grep -q "queue-ejected-twice" <(reason_of $N) && bad "C2: not queue-ejected-twice" || ok
run_tick
[ "$(requeues $N)" = 1 ] && ok || bad "C2: one requeue (got $(requeues $N); row $(row $N))"
[ "$(state_of $N)" = QUEUED ] && ok || bad "C2: the row is QUEUED (got $(row $N))"
no_fix_round C2 $N

# ============================================================================
# C3 — a real test failure on shard 3 next to the cancelled shards.
# ============================================================================
c3_run() {
  reset_case 7613 "$RUN1" $N
  cap_jobs "$T/jobs-$RUN1.json" ok ok ok fail cap cap ok cap cap ok cap ok
  fanin_log "$T/log-$RUN1.txt" 12 240 ok ok ok fail missing missing ok missing missing ok missing ok
  run_tick; run_tick; run_tick
}
c3_run
grep -q "shard 3/12: 1 of 20 tests failed" "$T/log-$RUN1.txt" && ok || bad "C3 setup: the log carries the real failure line (got: $(grep 'shard 3/12' "$T/log-$RUN1.txt"))"
[ "$(requeues $N)" = 0 ] && ok || bad "C3: no requeue (got $(requeues $N); row $(row $N))"
[ "$(cnt EJECTED_NOVERDICT "$CLOG")" = 0 ] && ok || bad "C3: no EJECTED_NOVERDICT (got: $(grep EJECTED_NOVERDICT "$CLOG"))"
grep -q "^nvv $K $H 9001 real " "$A" && ok || bad "C3: the verdict is real (got: $(grep '^nvv' "$A"))"
C3_WITH=$(row $N)
mv "$T/h/bin/lib/mc-noverdict.sh" "$T/nv.off"
c3_run
C3_WITHOUT=$(row $N)
mv "$T/nv.off" "$T/h/bin/lib/mc-noverdict.sh"
[ "$C3_WITH" = "$C3_WITHOUT" ] && ok || bad "C3: the row is the one without the lib (with: $C3_WITH; without: $C3_WITHOUT)"

# ============================================================================
# C4 — the jobs page cannot be read at the settle tick: the ejection counts.
# ============================================================================
reset_case 7613 "$RUN1" $N
echo "ejected $K $OLDH" >> "$A"
cap_jobs "$T/jobs-$RUN1.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN1.txt" 12 240 "${LOG12[@]}"
touch "$T/jobsfail"
run_tick
case "$(state_of $N):$(reason_of $N)" in BLOCKED_HUMAN:queue-ejected-twice*) ok ;; *) bad "C4: an unread batch is a strike (got $(row $N))" ;; esac
grep -q "^nvunread $K " "$A" && bad "C4: the settle call writes no nvunread line (got: $(grep '^nvunread' "$A"))" || ok
grep -q "^nvv $K " "$A" && bad "C4: an unread verdict is never cached" || ok
[ "$(cnt "EJECTED_NOVERDICT_UNREAD $K $H" "$CLOG")" = 1 ] && ok || bad "C4: EJECTED_NOVERDICT_UNREAD logged once (log: $(grep -o "mgfy-os#$N .*" "$CLOG" | tail -5))"
[ "$(requeues $N)" = 0 ] && ok || bad "C4: no requeue"

# ============================================================================
# C5 — the re-queued head is ejected again by a second cap batch.
# ============================================================================
reset_case 7613 "$RUN1" $N
cap_jobs "$T/jobs-$RUN1.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN1.txt" 12 240 "${LOG12[@]}"
run_tick; run_tick
[ "$(state_of $N)" = QUEUED ] && [ "$(requeues $N)" = 1 ] && ok || bad "C5 setup: the first cap eject was re-queued (got $(row $N), $(requeues $N))"
# The second batch (draft #7621, run RUN2): Mergify fails its queue check again.
printf '[%s,%s]' "$(dq_comment $N 7613 "$RUN1" 9001 2026-10-19T21:22:30Z)" "$(dq_comment $N 7621 "$RUN2" 9002 2026-10-19T22:40:00Z)" > "$T/comments-$N.json"
cap_jobs "$T/jobs-$RUN2.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN2.txt" 12 240 "${LOG12[@]}"
echo stale > "$T/ckmode-$H"
run_tick
case "$(state_of $N):$(reason_of $N)" in BLOCKED_HUMAN:queue-ejected-twice*) ok ;; *) bad "C5: the second ejection parks (got $(row $N))" ;; esac
grep -qxF "reejected $K $H" "$A" && ok || bad "C5: the second ejection is a reejected line"
run_tick; run_tick
[ "$(requeues $N)" = 1 ] && ok || bad "C5: no second requeue (got $(requeues $N))"
[ "$(cnt "left no verdict twice" "$ALOG")" = 1 ] && ok || bad "C5: exactly one alert over three ticks (got: $(cat "$ALOG"))"
grep -q "batch drafts #7613, #7621" "$ALOG" && ok || bad "C5: the alert names both drafts (got: $(cat "$ALOG"))"

# ============================================================================
# C6 — the #7613 shape: three PRs in one draft; #7515 has an older strike.
# ============================================================================
reset_case 7613 "$RUN1" 7417 7515 7558
echo "ejected $(key 7515) $OLDH" >> "$A"
cap_jobs "$T/jobs-$RUN1.json" "${CAP12[@]}"
fanin_log "$T/log-$RUN1.txt" 12 240 "${LOG12[@]}"
run_tick; run_tick; run_tick
for n in 7417 7515 7558; do
  [ "$(requeues $n)" = 1 ] && ok || bad "C6: #$n re-queued exactly once (got $(requeues $n); row $(row $n))"
  [ "$(state_of $n)" = QUEUED ] && ok || bad "C6: #$n is QUEUED (got $(row $n))"
  no_fix_round "C6 #$n" "$n"
done

echo "mq-cap-cancel-requeue (BH-7620): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
