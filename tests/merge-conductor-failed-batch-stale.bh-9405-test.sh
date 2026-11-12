#!/bin/bash
# tests/merge-conductor-failed-batch-stale.bh-9405-test.sh — BH-9405: a head
# Mergify dequeued for a failed batch, held by BH-8186 with no solo proof, is
# parked for the resolver after MC_FAILED_BATCH_STALE_TICKS conductor ticks.
#
# WHY (2026-11-10). project-6 #3697 sat ~38 h on the BH-8186 hold (WAIT_CI),
# which the resolver does not own. Only the 24 h window cleared it, and that
# requeued the head with no fix. #3726 waited the same way.
#
# The rig is tests/merge-conductor-failed-batch.bh-8186-test.sh's (copied): the
# REAL bin/merge-conductor.sh against a stub gh and worker, 0 vendor calls.
# Every case resets its own state (reset_case) inside this run's scratch tree.
# The tick env sets MC_FAILED_BATCH_STALE_TICKS=2.
#
#   G1 (THE REPRO) a CHECKS_FAILED ejection on draft #7 naming two checks, no
#      bs_batch: WAIT_CI after tick 1, BLOCKED_HUMAN queue-ejected-twice after
#      tick 2, a reason br_reason_of and mc_resolver_owns take, not enqueued,
#      FAILED_BATCH_STALE logged once over 3 ticks, the resolver launched
#   G2 one eject-cause `stale` line for H, cause checks, the two check names
#   G3 brec_checks / brec_brief (BH-9229) read the checks for H
#   G3b a same-patch rebase H -> H2: the park and the `stale` line name H2
#   G4 bs_batch `reproduces`: prequeue-red as before, no stale line
#   G5 bs_batch `pending` for 4 ticks: WAIT_CI, never parked
#   G6 a dqwculprit mark on H: WAIT_CI after 3 ticks, no stale line
#   G7 MC_FAILED_BATCH_STALE_TICKS=0: WAIT_CI after 3 ticks (the BH-8186 hold)
#   G8 PR_MANUALLY_DEQUEUED: no failed record, no park
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-failed-batch-stale.bh-9405-test.sh
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
# The resolver launch of the parked-row pass (mc_eject_fix_now): a stub that
# records the call, so no real resolver runs.
printf '#!/bin/bash\nprintf "%%s\\n" "${BR_ONLY_PR:-}" >> "%s/br-launch.txt"\nexit 0\n' "$T" > "$T/h/bin/blocked-resolver.sh"
chmod +x "$T/h/bin/blocked-resolver.sh"
EC="$T/h/state/merge-conductor/eject-cause/example-org_mgfy-os_31"
# payload2 <code> <left-sha> <draft> <check>... — a dequeue payload with several checks.
payload2() {
  local code="$1" sha="$2" d="$3" pl body; shift 3
  pl=$(jq -nc --arg c "$code" '{version:1,state:"dequeued",queue_rule_name:"default",dequeue_reason:{code:$c,checks:$ARGS.positional}}' --args "$@")
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n%s\n-*- Mergify Payload End -*-\n-->\n\n# Merge Queue Status\n\n- ❌ **Checks failed** — `2026-11-10 13:30 UTC` · on draft #%s\n- 🚫 **Left the queue** — `2026-11-10 14:06 UTC` · at `%s`\n' "$pl" "$d" "$sha")
  jq -nc --arg b "$body" '[{id:7366196632,user:{login:"mergify[bot]",type:"Bot"},created_at:"2026-11-10T05:10:00Z",updated_at:"2026-11-10T19:02:59Z",body:$b}]' > "$T/prcomments.json"
}
TK=(MC_FAILED_BATCH_STALE_TICKS=2)
# eject2 <head> [code] — QUEUED at <head>, dequeued on draft #7 with two checks.
eject2() { queued_at "$1"; payload2 "${2:-CHECKS_FAILED}" "$1" 7 'Unit tests 1/16' 'Unit tests 16/16'; run_tick "${TK[@]}"; }
stale_lines() { awk -F'\t' -v h="$1" '$2 == h && $3 == "stale"' "$EC" 2>/dev/null; }
nstale() { grep -c "FAILED_BATCH_STALE $K31 $1" "$CLOG"; }
CHK='Unit tests 1/16, Unit tests 16/16'
# shellcheck source=bin/lib/br/ladder.sh
. "$DIR/bin/lib/br/ladder.sh" 2>/dev/null || true

# G1 — THE REPRO.
reset_case; : > "$T/br-launch.txt"; pid_of "$H1" pid-one
eject2 "$H1"
ready_at "$H1" dequeued
: > "$T/label-adds.txt"; : > "$T/comments.txt"; : > "$CLOG"
run_tick "${TK[@]}"
[ "$(state_of "$K31")" = WAIT_CI ] && pass "G1: after tick 1 the row is held WAIT_CI" || fail "G1: tick 1 state $(state_of "$K31") why '$(reason_of "$K31")'"
run_tick "${TK[@]}"
W=$(reason_of "$K31")
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "G1: after tick 2 the row is BLOCKED_HUMAN" || fail "G1: tick 2 state $(state_of "$K31") why '$W'"
case "$W" in "queue-ejected-twice: CHECKS_FAILED in batch #7 ($CHK) on ${H1:0:8}; no solo proof after 2 ticks"*) pass "G1: the reason names the code, batch and checks" ;; *) fail "G1: why '$W'" ;; esac
if command -v br_reason_of >/dev/null 2>&1; then
  [ "$(br_reason_of "$W")" = queue-ejected-twice ] && pass "G1: br_reason_of answers queue-ejected-twice" || fail "G1: br_reason_of '$(br_reason_of "$W")'"
else fail "G1: br_reason_of not loaded"; fi
( . "$DIR/bin/lib/mc/classify.sh" 2>/dev/null; mc_resolver_owns "$W" ) && pass "G1: mc_resolver_owns owns the reason" || fail "G1: mc_resolver_owns refuses '$W'"
run_tick "${TK[@]}"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "G1: tick 3 keeps the park" || fail "G1: tick 3 state $(state_of "$K31")"
enqueued && fail "G1: the stale head was enqueued ($(qwrites))" || pass "G1: not enqueued"
[ "$(nstale "$H1")" = 1 ] && pass "G1: FAILED_BATCH_STALE logged once over 3 ticks" || fail "G1: STALE lines $(nstale "$H1")"
grep -qxF "$K31" "$T/br-launch.txt" && pass "G1: the parked-row pass launched the resolver for the PR" || fail "G1: no resolver launch ($(tr '\n' '|' < "$T/br-launch.txt"); log $(grep -c 'queue-ejected-twice' "$CLOG"))"
# G2 — the eject-cause line.
SL=$(stale_lines "$H1")
[ "$(grep -c . <<<"$SL")" = 1 ] && [ "$(cut -f4 <<<"$SL")" = checks ] && [ "$(cut -f5 <<<"$SL")" = "$CHK" ] \
  && pass "G2: one stale checks line for H with the two checks, after 3 ticks" || fail "G2: eject-cause '$(cat "$EC" 2>/dev/null)'"
# G3 — the resolver's brief reads it (BH-9229).
GOT=$( export MC_STATE_DIR="$T/h/state/merge-conductor"; . "$DIR/bin/blocked-resolver.d/bh-9229-eject-checks.sh"; brec_checks "$U31" "$H1"; echo "|"; brec_brief "$U31" "$H1" )
case "$GOT" in "$CHK"*"|"*"FAILING CHECKS ON THIS HEAD: $CHK."*) pass "G3: brec_checks and brec_brief name the checks" ;; *) fail "G3: got '$GOT'" ;; esac

# G3b — a same-patch rebase H -> H2: the park and its line are for H2.
H2=$(printf "c%.0s" $(seq 32))cccc2222
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
eject2 "$H1"
ready_at "$H2"
: > "$CLOG"
run_tick "${TK[@]}"; run_tick "${TK[@]}"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && case "$(reason_of "$K31")" in *"${H2:0:8} carries the same patch") true ;; *) false ;; esac \
  && pass "G3b: the rebased same-patch head is parked" || fail "G3b: state $(state_of "$K31") why '$(reason_of "$K31")'"
[ "$(stale_lines "$H2" | cut -f4)" = checks ] && pass "G3b: the stale line names H2" || fail "G3b: eject-cause '$(cat "$EC" 2>/dev/null)'"
GOT=$( export MC_STATE_DIR="$T/h/state/merge-conductor"; . "$DIR/bin/blocked-resolver.d/bh-9229-eject-checks.sh"; brec_checks "$U31" "$H2" )
[ "$GOT" = "$CHK" ] && pass "G3b: brec_checks answers for the row head H2" || fail "G3b: brec_checks '$GOT'"

# bs7 <word> — the solo re-run's answer for PR 31 on draft 7.
bs7() { printf 'bs_batch() { BS_SUITES=tests/x-test.sh; BS_BASE=eeeeeeeeeeee; printf "31 %%s %s\\n" "$(cat "%s/head-31")"; }\n' "$1" "$T" > "$T/h/bin/merge-conductor.d/zz-test-bs.sh"; }

# G4 — a solo `reproduces`: unchanged (prequeue-red), no stale line.
reset_case; pid_of "$H1" pid-one
eject2 "$H1"; ready_at "$H1"; bs7 reproduces; : > "$CLOG"
run_tick "${TK[@]}"; run_tick "${TK[@]}"; run_tick "${TK[@]}"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && case "$(reason_of "$K31")" in prequeue-red:*) true ;; *) false ;; esac \
  && pass "G4: reproduces parks prequeue-red, as BH-8186 J1" || fail "G4: state $(state_of "$K31") why '$(reason_of "$K31")'"
[ -z "$(stale_lines "$H1")" ] && [ "$(nstale "$H1")" = 0 ] && pass "G4: no stale line, no FAILED_BATCH_STALE" || fail "G4: stale '$(stale_lines "$H1")' log $(nstale "$H1")"

# G5 — a solo `pending` for 4 ticks: never parked.
reset_case; pid_of "$H1" pid-one
eject2 "$H1"; ready_at "$H1"; bs7 pending; : > "$CLOG"
for _ in 1 2 3 4; do run_tick "${TK[@]}"; done
[ "$(state_of "$K31")" = WAIT_CI ] && [ "$(nstale "$H1")" = 0 ] && pass "G5: a pending solo run keeps WAIT_CI over 4 ticks" || fail "G5: state $(state_of "$K31") why '$(reason_of "$K31")'"

# G6 — dequeue-watch named H the culprit: the hold stands.
reset_case; pid_of "$H1" pid-one
eject2 "$H1"; ready_at "$H1"; mc_attempt_put "dqwculprit $K31 $H1"; : > "$CLOG"
run_tick "${TK[@]}"; run_tick "${TK[@]}"; run_tick "${TK[@]}"
[ "$(state_of "$K31")" = WAIT_CI ] && [ -z "$(stale_lines "$H1")" ] && [ "$(nstale "$H1")" = 0 ] \
  && pass "G6: a dqwculprit head keeps WAIT_CI, no stale line" || fail "G6: state $(state_of "$K31") why '$(reason_of "$K31")' stale '$(stale_lines "$H1")'"
# G6b — the same through the READY arm (the requeue arm checks dqwculprit itself): the BH-8186 hold.
reset_case; pid_of "$H1" pid-one; pid_of "$H2" pid-one
eject2 "$H1"; ready_at "$H2"; mc_attempt_put "dqwculprit $K31 $H2"; : > "$CLOG"
run_tick "${TK[@]}"; run_tick "${TK[@]}"; run_tick "${TK[@]}"
[ "$(state_of "$K31")" = WAIT_CI ] && [ -z "$(stale_lines "$H2")" ] && ! enqueued \
  && pass "G6b: a dqwculprit rebased head keeps the hold, not enqueued" || fail "G6b: state $(state_of "$K31") why '$(reason_of "$K31")'"

# G7 — the knob off: the BH-8186 hold, as before.
reset_case; pid_of "$H1" pid-one
eject2 "$H1"; ready_at "$H1"; : > "$CLOG"
run_tick MC_FAILED_BATCH_STALE_TICKS=0; run_tick MC_FAILED_BATCH_STALE_TICKS=0; run_tick MC_FAILED_BATCH_STALE_TICKS=0
[ "$(state_of "$K31")" = WAIT_CI ] && [ "$(nstale "$H1")" = 0 ] && pass "G7: MC_FAILED_BATCH_STALE_TICKS=0 keeps WAIT_CI" || fail "G7: state $(state_of "$K31") why '$(reason_of "$K31")'"

# G8 — a dequeue that is not a counted failure: no record, no park.
reset_case; pid_of "$H1" pid-one
eject2 "$H1" PR_MANUALLY_DEQUEUED; ready_at "$H1"; : > "$CLOG"
run_tick "${TK[@]}"; run_tick "${TK[@]}"
! grep -q $'\tfailed\t' "$FB" 2>/dev/null && [ "$(nstale "$H1")" = 0 ] && [ -z "$(stale_lines "$H1")" ] \
  && pass "G8: PR_MANUALLY_DEQUEUED writes no record and parks nothing" || fail "G8: record '$(cat "$FB" 2>/dev/null)' state $(state_of "$K31")"

echo "merge-conductor-failed-batch-stale.bh-9405: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
