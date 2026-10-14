#!/bin/bash
# tests/mc-eject-cause.bh-6161-test.sh — BH-6161: every merge-queue ejection
# records its cause (bin/lib/mc-eject-cause.sh, wired into the conductor's
# settle arm).
#
# WHY. #4735 and #4029 were ejected again and again. Mergify stated a cause on
# every dequeue (`## Reason`, failing checks, the check names, and the head it
# left at), but the conductor wrote `queue-ejected` / `queue-ejected-twice` with
# no cause and logged "the batch build went red" for every ejection. Nobody
# could tell a conflict from a red check or a head move.
#
#   C1-C12  ec_classify on Mergify bodies (the cause table, its negatives)
#   C11,C13-C16 ec_cause: which comment is read, and when no read is made
#   E1      THE REPRODUCTION: a full tick ejects a QUEUED head; the row reason,
#           one EJECT_CAUSE line and one record line carry `checks (<name>)`
#   E2      a conflict Reason: `queue-ejected: conflict`, the BH-1677 mark stays
#   E3      the same head ejected again: queue-ejected-twice: 1 …; 2 …
#   E4      the head moved while queued: head-moved, no comments read
#   E5,E6   the resolver's readers and the sticky hand-off still match E3
#   E7      the comments read fails: unknown, and the ejection still counts
#   W1-W4   the record file: round trip, prefix match, unwritable, knob off
#   D1,D2   the two knobs: code default and catalog entries
#
# The rig is tests/mc-ejected-stale-dequeue.bh-5819-test.sh's: the real
# bin/merge-conductor.sh closure against a stub gh. Fixture bodies are cut from
# the real Mergify dequeue comment of #4049 (tests/fixtures/bh-4428/).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-eject-cause.bh-6161-test.sh
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
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/br/ladder.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The lib under test. Absent on main: the red this suite opens on.
[ -r "$DIR/bin/lib/mc-eject-cause.sh" ] && { scratch_install_closure bin/lib/mc-eject-cause.sh "$T/h" >/dev/null || { echo "FAIL: closure of mc-eject-cause.sh"; exit 1; }; }
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done

H1=4735b6ce79b6aaaa1111222233334444555566ff
H2=7f2cff9e0000bbbb1111222233334444555566ee
M=cccccccccccccccccccccccccccccccccccccccc
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nM=%s\n' "$T" "$MGFY_YML" "$M"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  # No prequeue-gate.yml on this repo: the gate proceeds (a 404, as GitHub answers).
  *"actions/workflows/prequeue-gate.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # The PR's comments: Mergify's dequeue comments live here.
  *"api -i -X GET repos/example-org/mgfy-os/issues/31/comments"*)
    [ -s "$T/cmtfail" ] && { restpr --raw 403 '{"message":"API rate limit exceeded"}'; exit 0; }
    restpr --raw 200 "$(cat "$T/prcomments.json" 2>/dev/null || echo '[]')" ;;
  *"api --paginate repos/example-org/mgfy-os/issues/"*"/comments"*) echo '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/main"*) restpr --raw 200 "{\"sha\":\"$M\"}" ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*) restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-05T20:00:00Z"}}}' ;;
  # ---- writes -------------------------------------------------------------
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*|*"api -i -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":901}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
MCD="$T/h/state/merge-conductor"
A="$MCD/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
REC_FILE="$MCD/eject-cause/example-org_mgfy-os_31"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ---- Mergify bodies, cut from the real #4049 dequeue comment ----------------
# mg_body <left-sha|-> <reason text|-> — the status list, the Left-the-queue
#   line (unless -), the `## Reason` section (unless -), the real Hint and an
#   "All conditions" list that names #-conflict, #changes-requested-reviews-by
#   and github-review-approved, all satisfied (the #1677 and #4049 shapes).
mg_body() {
  printf '%s\n' '<!---' 'DO NOT EDIT' '-*- Mergify Payload -*-' \
    '{"version": 1, "state": "dequeued", "queue_rule_name": "default"}' '-*- Mergify Payload End -*-' '-->' '' \
    '# Merge Queue Status' '' \
    '- ✅ **Entered queue** — `2026-10-05 22:40 UTC` · Rule: `default`' \
    '- ❌ **Checks failed** — `2026-10-05 23:10 UTC` · on draft #4801'
  [ "$1" != - ] && printf -- '- 🚫 **Left the queue** — `2026-10-05 23:18 UTC` · at `%s`\n' "$1"
  if [ "$2" != - ]; then printf '\n## Reason\n\n%s\n' "$2"; fi
  printf '%s\n' '' '## Hint' '' \
    'You may have to fix your CI before adding the pull request to the queue again.' \
    'If you update this pull request, to fix the CI, it will automatically be requeued once the queue conditions match again.' \
    '' '<details>' '<summary>All conditions</summary>' '' \
    '- [X] `#-conflict = 0`' \
    '- `#changes-requested-reviews-by=0`' '  - [X] #4735' \
    '- [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]' \
    '  - [X] #4735' \
    '- [X] `check-success = "Syntax + shellcheck + config integrity"`' '' '</details>'
}
R_CHECKS='The merge conditions cannot be satisfied due to failing checks

- `Pure-logic gate fixtures`

Failing checks:
- ❌ [`Pure-logic gate fixtures`](https://github.com/example-org/cromford/actions/runs/37180690428/job/111374696421) ([job log](https://github.com/example-org/cromford/actions/runs/37180690428/job/111374696421))'
R_CHECKS2="$R_CHECKS
- ❌ [\`Syntax + shellcheck + config integrity\`](https://github.com/example-org/cromford/actions/runs/37180690428/job/111374696500)"
R_CONFLICT='The pull request conflicts with the base branch: it became a base branch conflict after #12 merged'
R_REVIEW='Pull request #2458 has been dequeued

merge conditions no longer match. Blocked by:

> - `github-review-approved`
>
> - [ ] `check-success = "Build + Unit tests"`
> - [ ] [`github-review-approved`](https://docs.mergify.com/configuration/conditions/#pull-request-attributes-github-review-approved) [🛡 GitHub repository ruleset rule `main`]'
R_TIMEOUT='The merge conditions cannot be satisfied: the checks did not pass within the automatic checks timeout of 24 minutes 14 seconds, derived from this queue recent CI runtime

Failing checks:
- 🟠 [Build + Unit tests](https://github.com/example-org/project-5/actions/runs/35193185334)'
R_DEQUEUED='Pull request #4801 has been dequeued by a `dequeue` command'
R_UPDATED='The pull request has been updated with new commits since it entered the queue'
R_OTHER='The queue rule `default` was removed from the configuration'

# klass <head> <body> -> ec_classify's line, in a subshell with the lib loaded.
klass() { ( . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$T/h/bin/lib/mc-eject-cause.sh" 2>/dev/null
            printf '%s\n' "$2" | ec_classify "$1" ) 2>/dev/null; }
f1() { cut -f1 <<<"$1"; }
f2() { cut -f2 <<<"$1"; }
# cmt <login> <body> — one comment object, in API shape.
cmt() { jq -nc --arg l "$1" --arg b "$2" '{id:1, user:{login:$l}, created_at:"2026-10-05T23:18:00Z", body:$b}'; }

# ============================================================================
# C1-C12: the cause table.
# ============================================================================
O=$(klass "$H1" "$(mg_body "$H1" "$R_CHECKS2")")
[ "$(f1 "$O")" = checks ] && [ "$(f2 "$O")" = "Pure-logic gate fixtures, Syntax + shellcheck + config integrity" ] \
  && pass "C1: failing checks with two names: checks, both names" || fail "C1: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_CONFLICT")")
[ "$(f1 "$O")" = conflict ] && [ "$(f2 "$O")" = "$R_CONFLICT" ] && pass "C2: a base-branch conflict Reason: conflict" || fail "C2: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_REVIEW")")
[ "$(f1 "$O")" = review ] && [ "$(f2 "$O")" = github-review-approved ] && pass "C3: a review Reason: review" || fail "C3: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_TIMEOUT")")
[ "$(f1 "$O")" = timeout ] && pass "C4: a checks timeout is timeout, not checks" || fail "C4: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_DEQUEUED")")
[ "$(f1 "$O")" = dequeued ] && pass "C5: a dequeue command: dequeued" || fail "C5: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_UPDATED")")
[ "$(f1 "$O")" = head-moved ] && pass "C6: the pull request was updated: head-moved" || fail "C6: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "$R_OTHER")")
[ "$(f1 "$O")" = other ] && [ "$(f2 "$O")" = 'The queue rule default was removed from the configuration' ] \
  && pass "C7: an unknown Reason: other, the first line without backticks" || fail "C7: got '$O'"
O=$(klass "$H1" "$(mg_body "$H2" "$R_CHECKS")")
[ "$(f1 "$O")" = unknown ] && [ "$(f2 "$O")" = "Mergify's newest dequeue names ${H2:0:8}, not this head" ] \
  && pass "C8: a Left-the-queue sha for another head: unknown" || fail "C8: got '$O'"
O=$(klass "${H1:0:8}" "$(mg_body "$H1" "$R_CHECKS")")
[ "$(f1 "$O")" = checks ] && [ "$(f2 "$O")" = "Pure-logic gate fixtures" ] \
  && pass "C9: the Hint ('If you update this pull request') and the conditions list are not the Reason: checks" || fail "C9: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" "The merge conditions cannot be satisfied due to failing checks")")
[ "$(f1 "$O")" = checks ] && pass "C10: a satisfied review condition and #-conflict in All conditions: checks, not review or conflict" || fail "C10: got '$O'"
O=$(klass "$H1" "$(mg_body "$H1" -)")
[ -z "$O" ] && pass "C12: a body with no ## Reason classifies to nothing" || fail "C12: got '$O'"

# ec_cause, sourced, with the comments read stubbed: <provider> <live> <comments-json>
cause_src() {
  ( . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$T/h/bin/lib/mc-eject-cause.sh" 2>/dev/null
    gh_rest_issue_comments() { echo "$*" >> "$T/cause-reads.txt"; printf '%s' "$CJSON"; }
    CJSON="$3" ec_cause "$1" example-org/mgfy-os "$U31" "$H1" "$2" ) 2>/dev/null
}
: > "$T/cause-reads.txt"
O=$(cause_src mergify "" "[$(cmt 'mergify[bot]' "$(mg_body "$H1" "$R_CHECKS")"),$(cmt operator "> ## Reason
>
> $R_CONFLICT")]")
[ "$(f1 "$O")" = checks ] && pass "C11: a human comment quoting a conflict Reason is not read" || fail "C11: got '$O'"
: > "$T/cause-reads.txt"
O=$(cause_src mergify "$H2" "[$(cmt 'mergify[bot]' "$(mg_body "$H1" "$R_CHECKS")")]")
[ "$O" = "$(printf 'head-moved\tPR head is now %s' "${H2:0:8}")" ] && [ ! -s "$T/cause-reads.txt" ] \
  && pass "C13: a live head that differs: head-moved, no comments read" || fail "C13: got '$O', reads $(wc -l < "$T/cause-reads.txt")"
O=$(cause_src github "" "[]")
[ "$O" = "$(printf 'batch-red\tmerge_group build')" ] && [ ! -s "$T/cause-reads.txt" ] \
  && pass "C14: the native queue: batch-red, no comments read" || fail "C14: got '$O', reads $(wc -l < "$T/cause-reads.txt")"
O=$(cause_src mergify "$H1" "[$(cmt 'mergify[bot]' "$(mg_body "$H1" "$R_CONFLICT")"),$(cmt 'mergify[bot]' "$(mg_body "$H2" "$R_CHECKS")")]")
[ "$(f1 "$O")" = conflict ] && pass "C15: the newest Mergify comment is for another head: the one for this head is read" || fail "C15: got '$O'"
O=$(cause_src mergify "" "[$(cmt 'mergify[bot]' "$(mg_body - "$R_TIMEOUT")"),$(cmt 'mergify[bot]' "$(mg_body - -)")]")
[ "$(f1 "$O")" = timeout ] && pass "C16: no Left-the-queue line anywhere: the newest comment with a ## Reason is read" || fail "C16: got '$O'"
O=$(cause_src mergify "" "[$(cmt operator "nothing here")]")
[ "$O" = "$(printf 'unknown\tno Mergify dequeue reason')" ] && pass "C17: no Mergify comment: unknown (no Mergify dequeue reason)" || fail "C17: got '$O'"

# ============================================================================
# E: the settle arm, through a whole conductor tick.
# ============================================================================
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026100500$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <labels-csv>
  local lbl="[]"
  [ -n "${3:-}" ] && lbl=$(printf '%s' "$3" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}]' \
    "$1" "$1" "$2" "$1" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$MCD/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$MCD/pr-state.tsv"; }
cause_lines() { grep -c "EJECT_CAUSE $K31 " "$CLOG"; }
comment_reads() { grep -c 'issues/31/comments' "$T/gh-calls.txt"; }

# queued <head> <reason-body|-> — #31 QUEUED on <head>, Mergify's check failed,
#   and its newest comment says why (unless -).
queued() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/cmtfail"; : > "$CLOG"
  rm -f "$MCD/pr-state.tsv"; touch "$MCD/pr-state.tsv"
  scratch_rm "$MCD/tick"; scratch_rm "$MCD/mergify-asks"; scratch_rm "$MCD/eject-cause"
  echo failed > "$T/checkmode"
  printf 'merge-queue\n' > "$T/labels"
  mkrec 31 "$1"
  list_row 31 "$1" merge-queue > "$T/list.json"
  mc_row_put "$K31" QUEUED $((NOW-300)) "$1" "$1" - "in the merge queue" "$U31"
  if [ "$2" = - ]; then echo '[]' > "$T/prcomments.json"
  else printf '[%s]' "$(cmt 'mergify[bot]' "$2")" > "$T/prcomments.json"; fi
}

# E1 — THE REPRODUCTION. Mergify left on H1 with failing checks.
queued "$H1" "$(mg_body "$H1" "$R_CHECKS")"
run_tick
case "$(reason_of "$K31")" in
  "queue-ejected: checks (Pure-logic gate fixtures)"*) pass "E1: the row reason carries the cause: queue-ejected: checks (Pure-logic gate fixtures)" ;;
  *) fail "E1: the row reason must name the cause (state '$(state_of "$K31")', reason '$(reason_of "$K31")')" ;;
esac
[ "$(grep -c "EJECT_CAUSE $K31 ${H1:0:8} first checks (Pure-logic gate fixtures)" "$CLOG")" = 1 ] \
  && pass "E1: one EJECT_CAUSE line names the check" || fail "E1: EJECT_CAUSE lines: $(grep -o 'EJECT_CAUSE.*' "$CLOG" | head -3)"
grep -q 'the batch build went red' "$CLOG" && fail "E1: the log still claims 'the batch build went red' for every ejection" \
  || pass "E1: no line claims 'the batch build went red'"
grep -q "ejected from the merge queue on ${H1:0:8} — cause: checks (Pure-logic gate fixtures)" "$CLOG" \
  && pass "E1: the ejection line names the cause" || fail "E1: ejection line: $(grep -o 'mgfy-os#31 ejected from.*' "$CLOG" | head -2)"
[ -r "$REC_FILE" ] && [ "$(wc -l < "$REC_FILE")" = 1 ] && [ "$(cut -f2-5 "$REC_FILE")" = "$(printf '%s\tfirst\tchecks\tPure-logic gate fixtures' "$H1")" ] \
  && pass "E1: one record line: head, first, checks, the check name" || fail "E1: record: $(cat "$REC_FILE" 2>/dev/null)"
grep -qx "ejected $K31 $H1" "$A" && pass "E1: the ejection is still counted (ejected mark)" || fail "E1: no ejected mark ($(tr '\n' '|' < "$A"))"

# E3 / W1 — put back once (the requeue mark), then ejected again on the same head.
mc_attempt_put "requeued $K31 $H1 $((NOW-120))"
mc_row_put "$K31" QUEUED $((NOW-120)) "$H1" "$H1" - "requeued on ${H1:0:8} after a flake ejection" "$U31"
printf 'merge-queue\n' > "$T/labels"; list_row 31 "$H1" merge-queue > "$T/list.json"
scratch_rm "$MCD/tick"; : > "$CLOG"
run_tick
E3WHY=$(reason_of "$K31")
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "E3: the second ejection hands the head to the resolver" || fail "E3: state '$(state_of "$K31")' reason '$E3WHY'"
[[ "$E3WHY" =~ ^queue-ejected-twice:\ 1\ checks\ \(.*\)\ on\ [0-9a-f]{8}\;\ 2\ checks ]] \
  && pass "E3: queue-ejected-twice names both causes" || fail "E3: reason '$E3WHY'"
grep -q "EJECT_CAUSE $K31 ${H1:0:8} again checks" "$CLOG" && pass "E3: the second EJECT_CAUSE line says again" || fail "E3: $(grep -o 'EJECT_CAUSE.*' "$CLOG" | head -2)"
[ "$(cut -f2-4 "$REC_FILE" 2>/dev/null | tr '\t\n' ' |')" = "$H1 first checks|$H1 again checks|" ] \
  && pass "W1: the record holds both ejections, oldest first" || fail "W1: record: $(cat "$REC_FILE" 2>/dev/null)"
W1=$( ( . "$T/h/bin/lib/mc-eject-cause.sh"; ec_summary example-org/mgfy-os 31; printf '|'; ec_last_at example-org/mgfy-os 31 "$H1" ) 2>/dev/null)
[[ "$W1" =~ ^1\ checks\ \(Pure-logic\ gate\ fixtures\)\ on\ ${H1:0:8}\;\ 2\ checks\ \(Pure-logic\ gate\ fixtures\)\ on\ ${H1:0:8}\|[0-9]+$ ]] \
  && [ "${W1##*|}" = "$(tail -n1 "$REC_FILE" | cut -f1)" ] \
  && pass "W1: ec_summary and ec_last_at read the record back" || fail "W1: got '$W1'"

# E5 / E6 — the readers of the row reason still match.
E5=$( ( . "$T/h/bin/lib/br/ladder.sh" >/dev/null 2>&1; w=$(br_reason_of "$E3WHY"); printf '%s %s' "$w" "$(br_ladder_class "$w")" ) 2>/dev/null)
[ "$E5" = "queue-ejected-twice ci-red" ] && pass "E5: br_reason_of / br_ladder_class read queue-ejected-twice / ci-red" || fail "E5: got '$E5'"
( mc_handoff_owns "$E3WHY" ) && pass "E6: mc_handoff_owns keeps the row sticky" || fail "E6: mc_handoff_owns refused '$E3WHY'"

# W2 — an 8-char head finds the 40-char line.
W2=$( ( . "$T/h/bin/lib/mc-eject-cause.sh"; ec_last_at example-org/mgfy-os 31 "${H1:0:8}" ) 2>/dev/null)
[ -n "$W2" ] && [ "$W2" = "$(tail -n1 "$REC_FILE" | cut -f1)" ] && pass "W2: an 8-char head matches the 40-char record line" || fail "W2: got '$W2'"
W2b=$( ( . "$T/h/bin/lib/mc-eject-cause.sh"; ec_last_at example-org/mgfy-os 31 "${H2:0:8}" ) 2>/dev/null)
[ -z "$W2b" ] && pass "W2: another head finds nothing" || fail "W2: another head got '$W2b'"

# E2 — a conflict Reason.
queued "$H1" "$(mg_body "$H1" "$R_CONFLICT")"
run_tick
case "$(reason_of "$K31")" in queue-ejected:\ conflict*) pass "E2: the reason starts queue-ejected: conflict" ;; *) fail "E2: reason '$(reason_of "$K31")'" ;; esac
grep -qx "ejectconflict $K31 $H1" "$A" && pass "E2: the BH-1677 ejectconflict mark is still written" || fail "E2: no ejectconflict mark ($(tr '\n' '|' < "$A"))"

# E4 — the head moved while queued: the PR read answers H2.
queued "$H1" "$(mg_body "$H1" "$R_CHECKS")"
echo "$H2" > "$T/head-31"; list_row 31 "$H2" merge-queue > "$T/list.json"
run_tick
grep -q "EJECT_CAUSE $K31 ${H1:0:8} first head-moved (PR head is now ${H2:0:8})" "$CLOG" \
  && pass "E4: a moved head is head-moved (PR head is now <new>)" || fail "E4: $(grep -o 'EJECT_CAUSE.*' "$CLOG" | head -2)"
[ "$(cut -f4 "$REC_FILE" 2>/dev/null)" = head-moved ] && pass "E4: the record says head-moved" || fail "E4: record $(cat "$REC_FILE" 2>/dev/null)"

# E7 — the comments read fails: unknown, and the ejection still counts.
queued "$H1" "$(mg_body "$H1" "$R_CHECKS")"
echo 1 > "$T/cmtfail"
run_tick
case "$(reason_of "$K31")" in "queue-ejected: unknown (dequeue comments unreadable)"*) pass "E7: an unreadable comments list: unknown (dequeue comments unreadable)" ;;
  *) fail "E7: reason '$(reason_of "$K31")'" ;; esac
grep -qx "ejected $K31 $H1" "$A" && pass "E7: the ejected mark is written" || fail "E7: no ejected mark ($(tr '\n' '|' < "$A"))"

# W3 — the record cannot be written: one line, and the ejection still happens.
queued "$H1" "$(mg_body "$H1" "$R_CHECKS")"
: > "$MCD/eject-cause"     # a FILE where the record dir goes: no record can be written (root too)
run_tick
[ "$(grep -c "EJECT_CAUSE_UNRECORDED $K31" "$CLOG")" = 1 ] && pass "W3: an unwritable record is one log line" || fail "W3: $(grep -o 'EJECT_CAUSE.*' "$CLOG" | head -3)"
case "$(reason_of "$K31")" in queue-ejected*) pass "W3: the ejection transition is still written" ;; *) fail "W3: state '$(state_of "$K31")' reason '$(reason_of "$K31")'" ;; esac
rm -f "$MCD/eject-cause"

# W4 — MC_EJECT_CAUSE=0: the reason before BH-6161, no record, no cause read.
queued "$H1" "$(mg_body "$H1" "$R_CHECKS")"
run_tick MC_EJECT_CAUSE=0
[ "$(cause_lines)" = 0 ] && [ ! -e "$REC_FILE" ] && pass "W4: knob 0: no EJECT_CAUSE line and no record" || fail "W4: lines $(cause_lines), record $(cat "$REC_FILE" 2>/dev/null)"
grep -q "ejected from the merge queue on ${H1:0:8} — cause: not read (MC_EJECT_CAUSE=0)" "$CLOG" \
  && pass "W4: the ejection line says the cause was not read" || fail "W4: $(grep -o 'mgfy-os#31 ejected from.*' "$CLOG" | head -2)"
case "$(reason_of "$K31")" in queue-ejected:*) fail "W4: knob 0 must not add a cause (reason '$(reason_of "$K31")')" ;;
  queue-ejected*) pass "W4: the reason has no cause" ;; *) fail "W4: reason '$(reason_of "$K31")'" ;; esac

# ============================================================================
# D1, D2: the two knobs.
# ============================================================================
D1=$( ( unset MC_EJECT_CAUSE MC_REQUEUE_PREQUEUE; . "$T/h/bin/lib/mc-eject-cause.sh"
        printf '%s %s ' "$(ec_knob MC_EJECT_CAUSE 1)" "$(ec_knob MC_REQUEUE_PREQUEUE 1)"
        MC_EJECT_CAUSE=0 MC_REQUEUE_PREQUEUE=x; export MC_EJECT_CAUSE MC_REQUEUE_PREQUEUE
        printf '%s %s' "$(ec_knob MC_EJECT_CAUSE 1)" "$(ec_knob MC_REQUEUE_PREQUEUE 1)" ) 2>/dev/null)
[ "$D1" = "1 1 0 1" ] && pass "D1: both knobs default to 1; 0 reads 0; junk reads the default" || fail "D1: got '$D1'"
D2=$(jq -r '[.knobs[] | select(.env == "MC_EJECT_CAUSE" or .env == "MC_REQUEUE_PREQUEUE")
  | "\(.env)=\(.default):\(.min)-\(.max):\(.read_in)"] | sort | join(" ")' "$DIR/catalog/lanes.d/merge-conductor.json" 2>/dev/null)
[ "$D2" = "MC_EJECT_CAUSE=1:0-1:bin/lib/mc-eject-cause.sh MC_REQUEUE_PREQUEUE=1:0-1:bin/lib/mc-eject-cause.sh" ] \
  && pass "D2: both knobs are catalog entries read in bin/lib/mc-eject-cause.sh" || fail "D2: got '$D2'"

echo "mc-eject-cause.bh-6161: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
