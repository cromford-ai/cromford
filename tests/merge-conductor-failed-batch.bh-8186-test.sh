#!/bin/bash
# tests/merge-conductor-failed-batch.bh-8186-test.sh — BH-8186: a head Mergify
# dequeued for a failed batch is not enqueued again while it carries the same
# PATCH, not only the same sha.
#
# WHY (2026-10-23). #8127 was dequeued at 14:06Z with
# BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS at 3b036d00. At 15:43Z the harness
# rebased it to 653fca8a: same patch, new sha. Every failure mark is keyed on
# the sha, and the approval follows the patch (rebind_patch_id), so the new sha
# was READY with no failure, and at 19:02Z the READY arm enqueued it again.
#
# The rig is tests/mc-ejected-never-requeue.bh-5819-test.sh's: the REAL
# bin/merge-conductor.sh against a stub gh and worker. Patch-ids are seeded as
# mc_patch_id_file files beside the build record, so no git fetch runs.
#
#   E0 no record: a READY head is enqueued (label POST + @mergifyio queue)
#   R1 a QUEUED row ejected with a BATCH_MAX payload at H: `ejected` plus one
#      `failed` record line with H, the patch-id, the draft and the check
#   R2 PR_MANUALLY_DEQUEUED and CONFLICT_WITH_BASE_BRANCH: no `failed` line
#   E1 the next tick at the same H: not enqueued, WAIT_CI, the failed-batch why
#   E2 the head rebased to H2 (same patch-id): not enqueued over 2 ticks,
#      FAILED_BATCH_HELD logged once (THE REPRO: main enqueues it)
#   E2b the same, with Mergify's `dequeued` label still on: not enqueued
#   E3 a push H3 (a different patch-id): enqueued, record ends cleared:new-patch
#   B1 H2 with a solo re-run `clean` (bs_batch stub): enqueued, cleared:bystander
#   J1 H2 with a solo re-run `reproduces`: BLOCKED_HUMAN prequeue-red, not enqueued
#   W1 the record is older than MC_FAILED_BATCH_UNJUDGED_HOLD_S: cleared:window
#   K1 MC_FAILED_BATCH=0: the rebased head is enqueued, as before this ticket
#   NP a record with no patch-id (`-`): a rebased head mc_patch_same proves the
#      same patch is held; one it judges a new patch is enqueued
#   PD a failed comments read at the ejection: a `pending` line; the hold
#      re-reads it on the next tick and records the failure
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-failed-batch.bh-8186-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The driver sources its fragments by a glob, so the closure does not follow
# them: the BH-8186 fragment and its lib are installed by their own closure.
# Before BH-8186 the fragment does not exist, and the tick runs as on main.
if [ -r "$DIR/bin/merge-conductor.d/bh-8186-failed-batch.sh" ]; then
  ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-8186-failed-batch.sh "$T/h" >/dev/null ) || { echo "FAIL: closure of the BH-8186 fragment"; exit 1; }
fi
# shellcheck disable=SC2034  # restpr is the shared REST emitter the stub answers with
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

cat > "$T/h/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$T/h/bin/lib/pr-dep-gate.sh"

H1=$(printf "a%.0s" $(seq 32))aaaa1111
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=ci\n    merge_method: squash\n' | base64 | tr -d '\n')
echo none > "$T/checkmode"        # none | running | failed
echo green > "$T/cistate"         # green | red
: > "$T/labels"                   # the labels on PR 31 (one per line)
echo ok > "$T/qview"              # ok | fail   (the mc_queue_state read)
: > "$T/dqfail"                   # non-empty => the dequeued DELETE is refused 403
: > "$T/commentsfail"             # non-empty => the comments read answers 502

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  # The open-PR list over REST, from the list fixture (the full closure reads it
  # this way; the bridge is for suites with hand-copied libs).
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  # The block gate's thread reads (bg_read): no comment, no review.
  *"--paginate -q"*) exit 0 ;;
  *"api --paginate repos/example-org/mgfy-os/issues/31/comments"*) cat "$T/prcomments.json" 2>/dev/null || echo '[]' ;;
  # BH-8186: the PR's comments carry Mergify's dequeue payload. A GET only:
  # the `@mergifyio queue` POST must reach the writes arm below.
  *"-X GET repos/example-org/mgfy-os/issues/31/comments"*)
    [ -s "$T/commentsfail" ] && { restpr --raw 502 '{"message":"Bad Gateway"}'; exit 0; }
    restpr --raw 200 "$(cat "$T/prcomments.json" 2>/dev/null || echo '[]')" ;;
  # The Mergify check-runs read is a REST decision read on the contract now
  # (BH-784): it answers with a status line, and "no check" is an answered empty
  # list rather than an echoed blank. Same facts as the old arm.
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-10-22T09:00:00Z","completed_at":"2026-10-22T09:10:00Z"},{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-10-22T09:00:00Z","completed_at":"2026-10-22T09:10:00Z"},{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[{"name":"ci","status":"completed","conclusion":"success","started_at":"2026-10-22T09:00:00Z","completed_at":"2026-10-22T09:10:00Z"}]}' ;;
    esac ;;
  # BH-6161: the requeue arm asks the pre-queue gate, which reads main's tip
  # (the real commits shape carries a sha); mgfy-os has no prequeue-gate.yml.
  *"api -i -X GET repos/example-org/mgfy-os/commits/main") restpr --raw 200 '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
  *"actions/workflows/prequeue-gate.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*)
    [ -s "$T/commitfail" ] && { restpr --raw 502 '{"message":"Bad Gateway"}'; exit 0; }
    restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-08T09:00:00Z"}}}' ;;
  # BH-1586: the provider probes are gh_rest reads in the real REST shapes.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  # ---- writes -------------------------------------------------------------
  # The READY arm's enqueue (autoenqueue): the label and the queue command, -i.
  *"api -i -X POST repos/"*"/issues/31/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/31/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -i -X POST "*) printf '%s\n' "$*" >> "$T/writes.txt"; restpr --raw 201 '{}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    [ -s "$T/dqfail" ] && { echo "gh: HTTP 403: Resource not accessible" >&2; exit 1; }
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/merge-queue"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  # THE DECISION READS ARE REST NOW (BH-784): `gh api -i -X GET`, judged on the
  # HTTP status line, so restpr prints a whole response instead of one echoed
  # line. Every `--json` arm below collapses into the single pulls/<n> read —
  # the pull object carries state, head sha, head ref, labels, mergeable,
  # mergeStateStatus and author all at once — so the facts are the same ones,
  # read out of one answer.
  # The diff shares the pulls path and is told apart by its Accept header, so it
  # is matched first; so are the sub-resources, which this fixture answers with
  # nothing exactly as it did before.
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/reviews"*|*"api -i -X GET repos/"*"/pulls/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    # qview=fail is the outage the old `--json state,headRefOid,labels` arm
    # expressed with `exit 1`. Over REST a read that could not answer is a
    # non-2xx, and 403 is the one the contract maps to UNVERIFIABLE.
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && { restpr --raw 403 '{"message":"Forbidden"}'; exit 0; }
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main \
           "$LBL" MERGEABLE CLEAN operator ;;
  *"--json state,headRefOid,labels"*)
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && exit 1
    SHA=$(sed -n "s|.*/pull/\([0-9]*\).*|\1|p" <<<"$*"); echo "OPEN $(cat "$T/head-$SHA" 2>/dev/null || echo unknown) $LBL" ;;
  *"--json state,headRefName"*) echo "OPEN ticket/mg-31" ;;
  *"--json state,headRefOid"*)  echo "OPEN $(cat "$T/head-31" 2>/dev/null)" ;;
  *"--json labels"*) echo "$LBL" ;;
  *"--json state,mergeStateStatus,author,headRefOid"*) echo "OPEN CLEAN operator $(cat "$T/head-31" 2>/dev/null)" ;;
  *"--json state"*) echo OPEN ;;
  *"--json mergeCommit"*) echo "" ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  # The PR object over REST (BH-597): state, head sha and labels come from this
  # one call now instead of the paired GraphQL reads above. The $T/qview=fail
  # switch still makes the read FAIL, because that is what this suite pins.
  "api repos/example-org/mgfy-os/pulls/"[0-9]*)
    [ "$(cat "$T/qview" 2>/dev/null)" = fail ] && exit 1
    RN=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    RLB=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
    RLJ=$(printf '%s' "$RLB" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/{"name":"&"}/' | paste -sd, -)
    printf '{"number":%s,"html_url":"https://github.com/example-org/mgfy-os/pull/%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"%s","ref":"ticket/mg-31"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[%s],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
      "$RN" "$RN" "$(cat "$T/head-$RN" 2>/dev/null || cat "$T/head-31" 2>/dev/null || echo unknown)" "$RLJ" ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*)
    case "$(cat "$T/cistate" 2>/dev/null)" in
      red) restpr --runs 'completed|failure' ;;
      *)   restpr --runs 'completed|success' ;;
    esac ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open","body":"","labels":[]}' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
# The fake curl: the jobs worker. A standing lead MERGE-WITH-NOTES on every head.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
out=""; w=""; M=GET; URL=""
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$T/curl-all.log"
emit() {
  if [ -n "\$out" ]; then printf '%s' "\$2" > "\$out"; else printf '%s' "\$2"; fi
  case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$1" ;; *) printf '%s' "\$1" ;; esac
}
case "\$M \$URL" in
  "GET "*/api/verdicts\?*) emit 200 '{"standing":{"verdict":"MERGE-WITH-NOTES","source":"lead","id":3490,"created_at":"2026-10-22T09:20:00Z","report_url":"-","reviewer":"lead"}}' ;;
  "PUT "*|"POST "*) emit 200 '{"ok":true}' ;;
  *) emit 404 '{"error":"not found"}' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
FB="$T/h/state/merge-conductor/failed-batch/example-org_mgfy-os_31"
REC="$T/h/builds/pool-mgfy-MG-31-202609170031"
for f in gh-calls label-adds label-removes comments merges reruns writes; do : > "$T/$f.txt"; done
mkrec() { # mkrec <head> — approved and bound to <head>
  mkdir -p "$REC"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/31" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"
  : > "$REC/pipeline.log"
  echo "$1" > "$T/head-31"
}
pid_of() { mkdir -p "$REC"; echo "$2" > "$REC/patch-id.$1"; }   # pid_of <sha> <patch-id>
list_row() { # list_row <num> <head> <mergeState> <mergeable> <labels-csv>
  local lbl="[]"
  [ -n "${5:-}" ] && lbl=$(printf '%s' "$5" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$4" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret \
  JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture MC_MERGE_BUDGET=0 MC_MAIN_RED_DETECT=0 \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "${CONDUCTOR:-$T/h/bin/merge-conductor.sh}" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
reset_case() {
  # Every case its own state: the autoenqueue ledger file, the ask marks and
  # the tick memos of an earlier case must not answer for this one.
  scratch_rm "$T/h/state"; mkdir -p "$T/h/state"; mc_init
  : > "$A"; : > "$T/labels"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"
  : > "$T/comments.txt"; : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  rm -rf "$T/h/state/merge-conductor/failed-batch" "$REC" "$T/h/bin/merge-conductor.d/zz-test-bs.sh" "$T/h/bin/merge-conductor.d/zz-test-ps.sh"
  echo green > "$T/cistate"; echo none > "$T/checkmode"; echo ok > "$T/qview"
  echo '[]' > "$T/prcomments.json"; : > "$T/commentsfail"
}
# payload <code> <left-sha> [draft] [check] — Mergify's dequeue comment, the
# shape of #8127 comment 6366196632 (state dequeued, a dequeue_reason, the
# `Left the queue … at` line and the draft it failed on).
payload() {
  local code="$1" sha="$2" d="${3:-8165}" chk="${4:-Pure-logic gate fixtures}" pl body
  pl=$(jq -nc --arg c "$code" --arg k "$chk" '{version:1,state:"dequeued",queue_rule_name:"default",dequeue_reason:{code:$c,checks:[$k]}}')
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n%s\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-10-23 05:10 UTC`\n- ❌ **Checks failed** — `2026-10-23 13:30 UTC` · on draft #%s\n- 🚫 **Left the queue** — `2026-10-23 14:06 UTC` · at `%s`\n\n## Reason\n\nFailing checks:\n- ❌ [`%s`](https://github.com/example-org/mgfy-os/actions/runs/1/job/2)\n' "$pl" "$d" "$sha" "$chk")
  jq -nc --arg b "$body" '[{id:6366196632,user:{login:"mergify[bot]",type:"Bot"},created_at:"2026-10-23T05:10:00Z",updated_at:"2026-10-23T19:02:59Z",body:$b}]' > "$T/prcomments.json"
}
# ready_at <head> [labels] — approved on <head>, CLEAN, green, not queued.
ready_at() { mkrec "$1"; printf '%s\n' "${2:-}" | tr ',' '\n' | sed '/^$/d' > "$T/labels"
  printf '[%s]' "$(list_row 31 "$1" CLEAN MERGEABLE "${2:-}")" > "$T/list.json"; echo none > "$T/checkmode"; }
# queued_at <head> — QUEUED by this conductor, and Mergify's check now failed.
queued_at() { mkrec "$1"; printf 'merge-queue\n' > "$T/labels"
  printf '[%s]' "$(list_row 31 "$1" CLEAN MERGEABLE merge-queue)" > "$T/list.json"
  echo failed > "$T/checkmode"
  mc_row_put "$K31" QUEUED $(( $(date +%s) - 300 )) "$1" "$1" - "in the merge queue" "$U31"; }
# enqueued — the READY arm's two writes: our label and the queue command.
enqueued() { grep -qi '@mergifyio queue' "$T/comments.txt"; }
qwrites() { printf 'label-adds=%s queue-comments=%s; %s' "$(grep -c 'merge-queue' "$T/label-adds.txt")" "$(grep -ci '@mergifyio queue' "$T/comments.txt")" \
  "$(grep -E 'AUTOENQUEUE|FAILED_BATCH|REQUEUE|merge deferred' "$CLOG" | tail -2 | cut -c22-260 | tr '\n' '|')"; }
live_word() { awk -F'\t' '{w=$4} END {print w}' "$FB" 2>/dev/null; }
bs_stub() { # bs_stub <word> — the solo re-run's answer for PR 31 on draft 8165
  printf 'bs_batch() { BS_SUITES=tests/x-test.sh; BS_BASE=eeeeeeeeeeee; printf "31 %%s %s\\n" "$(cat "%s/head-31")"; }\n' "$1" "$T" > "$T/h/bin/merge-conductor.d/zz-test-bs.sh"
}
# eject_at <head> <code> — R1's tick: QUEUED at <head>, dequeued with <code>.
eject_at() { queued_at "$1"; payload "$2" "$1"; run_tick; }

# E0 — no record: a READY head is enqueued, as before.
reset_case
H0=$(printf "b%.0s" $(seq 32))bbbb0000
ready_at "$H0"; pid_of "$H0" pid-zero
run_tick
enqueued && pass "E0: a READY head with no record is enqueued" || fail "E0: not enqueued ($(qwrites); state $(state_of "$K31") why '$(reason_of "$K31")')"
[ -e "$FB" ] && fail "E0: a record file appeared with no ejection" || pass "E0: no record file"

# R1 — the ejection writes the record.
reset_case
pid_of "$H1" pid-one
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
grep -qx "ejected $K31 $H1" "$A" && pass "R1: the settle arm marks the ejection" || fail "R1: no ejected mark (attempts: $(tr '\n' '|' < "$A"); state $(state_of "$K31"))"
FL=$(awk -F'\t' '$4=="failed"' "$FB" 2>/dev/null)
IFS=$'\t' read -r _ RH RP RW RC RD RK <<<"$FL"
[ "$RH" = "$H1" ] && [ "$RP" = pid-one ] && [ "$RW" = failed ] && [ "$RC" = BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS ] && [ "$RD" = 8165 ] && [ "$RK" = 'Pure-logic%20gate%20fixtures' ] \
  && pass "R1: one failed line with the head, patch-id, code, draft and check" || fail "R1: record '$(cat "$FB" 2>/dev/null)'"
[ "$(grep -c "FAILED_BATCH_RECORDED $K31 $H1" "$CLOG")" = 1 ] && pass "R1: FAILED_BATCH_RECORDED logged once" || fail "R1: log $(grep -c FAILED_BATCH_RECORDED "$CLOG")"

# R2 — dequeues that are not a failed batch leave no failed line.
for code in PR_MANUALLY_DEQUEUED CONFLICT_WITH_BASE_BRANCH; do
  reset_case; pid_of "$H1" pid-one
  eject_at "$H1" "$code"
  grep -q $'\tfailed\t' "$FB" 2>/dev/null && fail "R2: $code wrote a failed line ($(cat "$FB"))" || pass "R2: $code writes no failed line"
done

# E1 — the next tick on the same head H: held.
reset_case; pid_of "$H1" pid-one
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
ready_at "$H1" dequeued
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
run_tick
enqueued && fail "E1: the failed head was enqueued again ($(qwrites))" || pass "E1: the failed head is not enqueued again"
grep -qE "^requeued $K31 $H1" "$A" && fail "E1: the failed head spent a requeue" || pass "E1: no requeue mark on the failed head"
[ "$(state_of "$K31")" = WAIT_CI ] && case "$(reason_of "$K31")" in *"failed in Mergify batch #8165"*) true ;; *) false ;; esac \
  && pass "E1: WAIT_CI with the failed-batch reason" || fail "E1: state $(state_of "$K31") why '$(reason_of "$K31")'"

# E2 — THE REPRO: the harness rebased H to H2. Same patch, new sha.
H2=$(printf "c%.0s" $(seq 32))cccc2222
pid_of "$H2" pid-one
ready_at "$H2"
: > "$T/label-adds.txt"; : > "$T/comments.txt"; : > "$CLOG"
run_tick
run_tick
enqueued && fail "E2: the rebased same-patch head was enqueued again ($(qwrites))" || pass "E2: a rebased head with the failed patch is not enqueued"
[ "$(grep -c "FAILED_BATCH_HELD $K31 $H2" "$CLOG")" = 1 ] && pass "E2: FAILED_BATCH_HELD logged once over 2 ticks" || fail "E2: HELD lines $(grep -c "FAILED_BATCH_HELD $K31 $H2" "$CLOG")"
case "$(reason_of "$K31")" in *"${H2:0:8} carries the same patch"*) pass "E2: the reason names the failed head and the same patch" ;; *) fail "E2: why '$(reason_of "$K31")'" ;; esac

# E2b — the same, with Mergify's own `dequeued` label still on the PR.
ready_at "$H2" dequeued
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && fail "E2b: the rebased head with the dequeued label was enqueued ($(qwrites))" || pass "E2b: ...also with the dequeued label on"

# E3 — a real push: a new patch clears the record, and the head is enqueued.
H3=$(printf "d%.0s" $(seq 32))dddd3333
pid_of "$H3" pid-three
# patch_same judges the two heads (this sandbox has no repo to fetch): a
# different patch. An unjudged answer must wait instead (A4b in the lib suite).
printf 'mc_patch_same() { MC_PATCH_SAME_UNJUDGED=0; return 1; }\n' > "$T/h/bin/merge-conductor.d/zz-test-ps.sh"
ready_at "$H3"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && pass "E3: a head with a new patch is enqueued" || fail "E3: not enqueued ($(qwrites); state $(state_of "$K31") why '$(reason_of "$K31")')"
[ "$(live_word)" = cleared:new-patch ] && pass "E3: the record ends cleared:new-patch" || fail "E3: last word '$(live_word)'"

# B1 — a solo re-run proves a bystander: cleared, enqueued.
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
ready_at "$H2"; bs_stub clean
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && pass "B1: a solo-clean bystander is enqueued" || fail "B1: not enqueued ($(qwrites); state $(state_of "$K31") why '$(reason_of "$K31")')"
[ "$(live_word)" = cleared:bystander ] && pass "B1: the record ends cleared:bystander" || fail "B1: last word '$(live_word)'"

# J1 — the solo re-run reproduces the failure: parked for the resolver.
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
ready_at "$H2"; bs_stub reproduces
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && fail "J1: a reproduced failure was enqueued ($(qwrites))" || pass "J1: a reproduced failure is not enqueued"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && case "$(reason_of "$K31")" in prequeue-red:*) true ;; *) false ;; esac \
  && pass "J1: BLOCKED_HUMAN prequeue-red (the resolver's reason)" || fail "J1: state $(state_of "$K31") why '$(reason_of "$K31")'"

# W1 — no proof for a whole window: held one second under it, released at it.
# The record's clock is pinned (MC_FAILED_BATCH_NOW): no wall-clock wait.
NOW0=1792731960
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
queued_at "$H1"; payload BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS "$H1"; run_tick MC_FAILED_BATCH_NOW=$NOW0
ready_at "$H2"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick MC_FAILED_BATCH_NOW=$((NOW0 + 86399))
enqueued && fail "W1: enqueued one second under the window ($(qwrites))" || pass "W1: one second under the window the head is held"
run_tick MC_FAILED_BATCH_NOW=$((NOW0 + 86400))
enqueued && pass "W1: past the window the head is enqueued" || fail "W1: not enqueued ($(qwrites); why '$(reason_of "$K31")')"
[ "$(live_word)" = cleared:window ] && pass "W1: the record ends cleared:window" || fail "W1: last word '$(live_word)'"

# K1 — the switch off: the rebased head is enqueued, as on main.
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
ready_at "$H2"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick MC_FAILED_BATCH=0
enqueued && pass "K1: MC_FAILED_BATCH=0 holds nothing" || fail "K1: not enqueued under the switch off ($(qwrites); why '$(reason_of "$K31")')"

# NP — no patch-id at record time (`-`): mc_patch_same alone judges the rebase.
reset_case
eject_at "$H1" BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS
[ "$(awk -F'\t' '$4 == "failed" {p = $3} END {print p}' "$FB" 2>/dev/null)" = - ] \
  && pass "NP: the record carries no patch-id" || fail "NP: record '$(cat "$FB" 2>/dev/null)'"
printf 'mc_patch_same() { MC_PATCH_SAME_UNJUDGED=0; return 0; }\n' > "$T/h/bin/merge-conductor.d/zz-test-ps.sh"
ready_at "$H2"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && fail "NP: a same-patch rebase of a '-' record was enqueued ($(qwrites))" || pass "NP: mc_patch_same holds a same-patch rebase of a '-' record"
printf 'mc_patch_same() { MC_PATCH_SAME_UNJUDGED=0; return 1; }\n' > "$T/h/bin/merge-conductor.d/zz-test-ps.sh"
ready_at "$H3"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && pass "NP: a new patch on a '-' record is enqueued" || fail "NP: not enqueued ($(qwrites); why '$(reason_of "$K31")')"
[ "$(live_word)" = cleared:new-patch ] && pass "NP: the record ends cleared:new-patch" || fail "NP: last word '$(live_word)'"

# PD — the comments read fails at the ejection: pending, then read on the hold.
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
queued_at "$H1"; payload BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS "$H1"; echo 1 > "$T/commentsfail"
run_tick
[ "$(live_word)" = pending ] && pass "PD: a failed read records pending" || fail "PD: record '$(cat "$FB" 2>/dev/null)'"
: > "$T/commentsfail"
ready_at "$H2"
: > "$T/label-adds.txt"; : > "$T/comments.txt"
run_tick
enqueued && fail "PD: the pending head was enqueued ($(qwrites))" || pass "PD: a pending record holds the rebased head"
[ "$(live_word)" = failed ] && pass "PD: the hold read the payload and recorded the failure" || fail "PD: last word '$(live_word)'"

echo "merge-conductor-failed-batch.bh-8186: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
