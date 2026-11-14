#!/bin/bash
# tests/mc-batch-eject-bystander.bh-4428-test.sh — BH-4428: A PR MERGIFY DID NOT
# NAME GOES BACK IN AFTER A BATCH EJECTION; THE ONE IT NAMED IS TOLD WHAT FAILED.
#
# THE CASE (2026-10-04). Nine innocent PRs sat `WAIT_CI queue-ejected — push a
# fix` for hours after Mergify batch ejections, every one green on its own head:
# the BH-636 re-entry arm's only gate (fr_reentry_gate) attributes by suite name,
# the failing check `Pure-logic gate fixtures` is a job name (`unknown`), and
# `unknown` on Mergify's leftover UNSTABLE never re-queues. Mergify's own verdict
# in the same dequeue comment, and its draft's membership, were never read.
#
# Fixtures are the REAL Mergify dequeue comments of #4121, #3981 and #4049 and
# the real titles of their drafts (tests/fixtures/bh-4428/, read 2026-10-04), at
# their real heads. The bystander payload Mergify sends for a multi-PR batch
# that did not name this PR is #4121's comment with its last `Checks failed`
# line moved to the real multi-PR draft #4276 and the `identified` marker
# dropped (plan A4: no such payload exists in the incident; unnamed members
# stayed `checking`).
#
# Part 1 drives the pure parser and the shared-red ledger by sourcing the lib.
# Part 2 drives the real bin/merge-conductor.sh with a fake gh that records
# every label write, comment and merge.
# Run from anywhere (exit 0 = all pass).
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
LIB="$DIR/bin/lib/mc-batch-eject.sh"
FX="$DIR/tests/fixtures/bh-4428"

H4121=2150c8f1f93ef0c0a94b05c09e87c425903e4eeb
H3981=ca43f1597875f06eb74e44bef972a497d407b37a
H4049=a1b5abb3c8a3a8d02764eba661eddaf24e0be296
MAIN_RED_BASE=a00ade0397ca85d2b8c7e3801176097f0d981d09
MAIN_MOVED=89f7dd83c7020a196f9a5082fd2a51e91398200a
CHECK='Pure-logic gate fixtures'
RUN4121='https://github.com/example-org/cromford/actions/runs/37172502842/job/111350523698'

# fx_comment <pr> [jq body edit] — the real dequeue comment as GitHub lists it.
fx_comment() {
  jq -c "${2:-.} | . + {user: {login: \"mergify[bot]\", type: \"Bot\"}}" "$FX/pr$1-dequeue.json"
}
BYSTANDER_EDIT='.body |= sub("on draft #4279 · identified as the failing PR"; "on draft #4276")'
NAMED_EDIT='.body |= sub("on draft #4279 · identified as the failing PR"; "on draft #4276 · identified as the failing PR")'

# ============================================================================
# PART 1 — the parser, the members, the word, the ledger (no network).
# ============================================================================
if [ -r "$LIB" ]; then
  (
    MC_ATTEMPTS="$T/p1-attempts.txt"; : > "$MC_ATTEMPTS"
    mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
    mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
    # shellcheck source=bin/lib/mc-batch-eject.sh
    . "$LIB" || exit 1
    P=0; F=0
    pok() { P=$((P+1)); }; pbad() { F=$((F+1)); echo "FAIL: $1"; }
    # P1 — #4121, identified alone on draft #4279.
    out=$(bej_parse_dequeue "[$(fx_comment 4121)]" "$H4121"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "4279	1	Pure-logic%20gate%20fixtures	$RUN4121" ] && pok || pbad "P1: #4121 parses (rc $rc, got '$out')"
    # P2 — #3981, the LAST Checks failed line wins over five earlier rounds.
    out=$(bej_parse_dequeue "[$(fx_comment 3981)]" "$H3981")
    [ "$(cut -f1,2 <<<"$out")" = "4290	1" ] && pok || pbad "P2: #3981 is draft #4290, named (got '$out')"
    # P3 — #4049 on draft #4335.
    out=$(bej_parse_dequeue "[$(fx_comment 4049)]" "$H4049")
    [ "$(cut -f1,2,3 <<<"$out")" = "4335	1	Pure-logic%20gate%20fixtures" ] && pok || pbad "P3: #4049 (got '$out')"
    # P4 — the `stacked on #P` number is never a member.
    out=$(bej_draft_members "$(awk -F'\t' '$1==4335{print $2}' "$FX/draft-titles.tsv")")
    [ "$out" = "4049	a00ade0	main	1" ] && pok || pbad "P4: draft #4335 holds #4049 alone (got '$out')"
    out=$(bej_draft_members "$(awk -F'\t' '$1==4236{print $2}' "$FX/draft-titles.tsv")")
    [ "$out" = "4002	9d50520	main	1" ] && pok || pbad "P4: draft #4236 holds #4002 alone, not #3994 (got '$out')"
    # P5 — a multi-PR draft.
    out=$(bej_draft_members "$(awk -F'\t' '$1==4276{print $2}' "$FX/draft-titles.tsv")")
    [ "$out" = "4121 4221 4029 4097 4150 4123 3981 4026	a00ade0	main	0" ] && pok || pbad "P5: draft #4276's eight members (got '$out')"
    bej_draft_members "Add the thing (#4121)" >/dev/null && pbad "P5: a non-Mergify title is not a draft" || pok
    # P6 — the words, and what does not parse.
    [ "$(bej_word 4121 1 '4121')" = solo ] && pok || pbad "P6: alone = solo"
    [ "$(bej_word 4049 1 '4049')" = solo ] && pok || pbad "P6: alone + stacked = solo"
    [ "$(bej_word 4121 1 '4121 4221 3981')" = culprit ] && pok || pbad "P6: named in a batch = culprit"
    [ "$(bej_word 4121 0 '4121 4221 3981')" = bystander ] && pok || pbad "P6: unnamed in a batch = bystander"
    [ "$(bej_word 4121 0 '4221 3981')" = unknown ] && pok || pbad "P6: a draft without this PR = unknown"
    bej_parse_dequeue "[$(fx_comment 4121)]" "$H3981" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "P6: another head's comment is rc 1 (got $rc)"
    bej_parse_dequeue "[$(jq -c '. + {user: {login: "mergify[bot]"}}' "$FX/pr4221-checking.json")]" "$H4121" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "P6: a 'checking … not the cause' payload is not a dequeue (got $rc)"
    bej_parse_dequeue "[$(jq -c '. + {user: {login: "operator"}}' "$FX/pr4121-dequeue.json")]" "$H4121" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "P6: a human quoting the payload is not Mergify (got $rc)"
    bej_parse_dequeue "not json" "$H4121" >/dev/null; rc=$?
    [ "$rc" = 2 ] && pok || pbad "P6: unreadable JSON is rc 2 (got $rc)"
    out=$(bej_parse_dequeue "[$(fx_comment 4121 "$BYSTANDER_EDIT")]" "$H4121")
    [ "$(cut -f1,2 <<<"$out")" = "4276	0" ] && pok || pbad "P6: the bystander payload is draft #4276, not named (got '$out')"
    # S1 — two PRs alone on one base, same check: shared.
    bej_solo_note example-org/x a00ade0 Pure-logic%20gate%20fixtures 'example-org/x#1'
    [ "$(bej_shared_count example-org/x a00ade0 Pure-logic%20gate%20fixtures)" = 1 ] && pok || pbad "S1: one PR noted"
    bej_solo_note example-org/x a00ade0 Pure-logic%20gate%20fixtures,Other 'example-org/x#2'
    [ "$(bej_shared_count example-org/x a00ade0 Pure-logic%20gate%20fixtures)" = 2 ] && pok || pbad "S1: two PRs share the base and check"
    # S2 — same base, a check nobody else failed: not shared.
    bej_solo_note example-org/x a00ade0 Lonely 'example-org/x#3'
    [ "$(bej_shared_count example-org/x a00ade0 Lonely)" = 1 ] && pok || pbad "S2: disjoint checks are not shared"
    [ "$(bej_shared_count example-org/x 9d50520 Pure-logic%20gate%20fixtures)" = 0 ] && pok || pbad "S2: another base shares nothing"
    # S3 — one PR noted twice (two heads) counts once; notes are not repeated.
    bej_solo_note example-org/x a00ade0 Lonely 'example-org/x#3'
    [ "$(bej_shared_count example-org/x a00ade0 Lonely)" = 1 ] && pok || pbad "S3: one PR, two notes, counted once"
    [ "$(grep -c 'Lonely example-org/x#3' "$MC_ATTEMPTS")" = 1 ] && pok || pbad "S3: the ledger line is written once"
    # Encoding round-trip.
    [ "$(_bej_dec "$(_bej_enc 'a b,c%d')")" = 'a b,c%d' ] && pok || pbad "enc/dec round-trip"
    echo "$P $F" > "$T/p1.result"
  )
  read -r p f < "$T/p1.result" 2>/dev/null || { p=0; f=1; echo "FAIL: part 1 did not run"; }
  PASS=$((PASS+p)); FAIL=$((FAIL+f))
else
  bad "part 1: bin/lib/mc-batch-eject.sh is absent (the red this suite opens on)"
fi

# ============================================================================
# PART 2 — the real conductor.
# ============================================================================
NOW=$(date -u +%s)
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
for f in merge-conductor-lib gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list flaky gh-ci-read mc-stale-dequeue mc-foreign-red main-red-gate; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/"
done
# The lib under test. Absent on main, which is the red this suite opens on.
[ -r "$LIB" ] && cp "$LIB" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=x\n' > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
mkdir -p "$T/h/catalog"; printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$T/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh
cp "$FX/draft-titles.tsv" "$T/drafts.tsv"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# Per-PR fixture files: comments-<n>.json, labels-<n>, head-<n>.
# Switches: ckmode (stale | stale_red | acked) per PR in ckmode-<n>; draftfail
# (non-empty: every draft read 404s); mainsha (the base branch's head; empty =
# the branch read 502s).
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
ARGS=("$@")
pr_of() { sed -n 's|.*/issues/\([0-9]*\)/.*|\1|p; s|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*" | head -1; }
jobs_json() {
  local q="" prev=""
  for a in "${ARGS[@]}"; do [ "$prev" = -q ] && q="$a"; prev="$a"; done
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | {name: ., status: "completed", conclusion: "failure"})
    | {total_count: length, jobs: .}' | if [ -n "$q" ]; then jq -r "$q"; else cat; fi
}
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
GHA_RED='{"name":"Pure-logic gate fixtures","status":"completed","conclusion":"failure","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    SHA=$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"$*")
    N=$(grep -lx "$SHA" "$T"/head-* 2>/dev/null | head -1); N=${N##*-}
    case "$(cat "$T/ckmode-$N" 2>/dev/null || echo stale)" in
      stale)     restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      stale_red) restpr --raw 200 "{\"total_count\":4,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK,$GHA_RED]}" ;;
      acked)     restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*)
    restpr --raw 200 "$(cat "$T/comments-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/branches/"*)
    if [ -s "$T/mainsha" ]; then restpr --raw 200 "{\"name\":\"main\",\"commit\":{\"sha\":\"$(cat "$T/mainsha")\"}}"
    else restpr --raw 502 '{"message":"Server Error"}'; fi ;;
  # fr_reentry_gate's reads (the BH-3776 path): a batch run whose log names no
  # test, only the failed job, so its verdict is `unknown`.
  *"api -i -X GET repos/"*"/actions/runs/"*"/jobs"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\)/jobs.*|\1|p' <<<"$*")
    restpr --raw 200 "{\"total_count\":1,\"jobs\":[{\"id\":77$RID,\"name\":\"CI plan (what this run tests)\",\"status\":\"completed\",\"conclusion\":\"success\"}]}" ;;
  *"api repos/"*"/actions/runs/"*"/jobs"*) jobs_json 'Pure-logic gate fixtures' ;;
  *"api -i -X GET repos/"*"/actions/runs"*"event=pull_request"*) restpr --raw 200 '{"total_count":0,"workflow_runs":[]}' ;;
  *"api -i -X GET repos/"*"/actions/runs/"*)
    RID=$(sed -n 's|.*/actions/runs/\([0-9]*\).*|\1|p' <<<"$*")
    restpr --raw 200 "{\"id\":$RID,\"head_branch\":\"mergify/merge-queue/abc$RID\",\"path\":\".github/workflows/harness-ci.yml\",\"status\":\"completed\",\"conclusion\":\"failure\",\"created_at\":\"2026-10-04T01:00:00Z\",\"head_sha\":\"cccccccc11112222333344445555666677778888\",\"display_title\":\"merge queue: checking #1 on main (a00ade0)\",\"pull_requests\":[]}" ;;
  *"run view "*"--log-failed"*)
    printf 'Pure-logic gate fixtures\tgate\t2026-10-04T01:05:00Z ##[error]Process completed with exit code 1.\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*)
    restpr --raw 200 '[{"filename":"bin/lib/mc/classify.sh"}]' ;;
  # ---- writes -------------------------------------------------------------
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    # One writer at a time: two PRs commented in parallel interleaved their blocks (#9607 queue run 43375112445).
    { flock 9; { printf '<<PR %s>>\n' "$(pr_of "$*")"; cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"; } 9> "$T/attr-comments.lock"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels-$N" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels-$N"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels-$N"; sort -u -o "$T/labels-$N" "$T/labels-$N"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) echo acked > "$T/ckmode-$N" ;; esac
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
      [ -s "$T/draftfail" ] && { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
      restpr --raw 200 "$(jq -nc --argjson n "$PN" --arg t "$TI" '{number: $n, title: $t, state: "closed"}')"
    else
      LBL=$(tr '\n' ',' < "$T/labels-$PN" 2>/dev/null | sed 's/,$//')
      restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main "$LBL" MERGEABLE CLEAN operator
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
printf '{"error":"not found"}\n404\n'
EOF
} > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"

mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-202610040$1"
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
key_of() { printf 'example-org/mgfy-os#%s' "$1"; }
requeues_of() { local n; n=$(grep -c "issues/$1/comments.*@mergifyio requeue" "$T/comments.txt" 2>/dev/null); echo "${n:-0}"; }
labeladds_of() { local n; n=$(grep -c "issues/$1/labels" "$T/label-adds.txt" 2>/dev/null); echo "${n:-0}"; }
pr_comments_of() { local n; n=$(grep -c "^<<PR $1>>" "$T/attr-comments.txt" 2>/dev/null); echo "${n:-0}"; }
culprit_comments_of() { # the culprit comment's own sentence, per PR
  awk -v p="<<PR $1>>" '$0==p {on=1; next} /^<<END>>$/ {on=0} on && /out of the queue/ {n++} END {print n+0}' "$T/attr-comments.txt"
}
EJWHY='queue-ejected — push a fix; the next head is enqueued on its own merits'
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# reset_case — no PRs yet; add_pr adds one ejected, approved, green head.
reset_case() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/attr-comments.txt"
  : > "$T/reruns.txt"; : > "$T/writes.txt"; : > "$CLOG"; : > "$T/draftfail"
  printf '%s' "$MAIN_MOVED" > "$T/mainsha"
  rm -f "$T"/ckmode-* "$T"/labels-* "$T"/comments-*.json "$T"/head-* "$T/h/flags/main-red-mgfy"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/foreign-red" "$T/h/state/merge-conductor/batch-eject" \
         "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/merge-conductor/pr-files" 2>/dev/null
  rm -rf "$T/h/builds/"pool-mgfy-* 2>/dev/null
  printf '[' > "$T/list.json.parts"; LIST_SEP=""
}
add_pr() { # add_pr <num> <head> <comments json array> [mergeState]
  printf '%s' "$3" > "$T/comments-$1.json"
  printf 'dequeued\n' > "$T/labels-$1"
  echo stale > "$T/ckmode-$1"
  mkrec "$1" "$2"
  printf '%s%s' "$LIST_SEP" "$(list_row "$1" "$2" "${4:-UNSTABLE}" dequeued)" >> "$T/list.json.parts"; LIST_SEP=,
  { cat "$T/list.json.parts"; printf ']'; } > "$T/list.json"
  echo "ejected $(key_of "$1") $2" >> "$A"
}
requeued_list() { # the rows after an acknowledged requeue: our label back, Mergify checking
  local n parts="" sep=""
  for n in "$@"; do parts+="$sep$(list_row "$n" "$(cat "$T/head-$n")" UNSTABLE merge-queue)"; sep=,; done
  printf '[%s]' "$parts" > "$T/list.json"
}
not_requeued() { # not_requeued <case> <pr>
  [ "$(labeladds_of "$2")" = 0 ] && ok || bad "$1: no merge-queue label on #$2 (got: $(cat "$T/label-adds.txt"))"
  [ "$(requeues_of "$2")" = 0 ] && ok || bad "$1: no @mergifyio requeue on #$2 (got: $(cat "$T/comments.txt"))"
  grep -qE "^requeued $(key_of "$2") " "$A" && bad "$1: no requeued mark on #$2" || ok
  [ ! -s "$T/merges.txt" ] && ok || bad "$1: nothing merges (got: $(cat "$T/merges.txt"))"
}

# ============================================================================
# 1 — BYSTANDER: a multi-PR batch, not named, the job-named check, Mergify-only
#     UNSTABLE. Exactly one requeue (label + @mergifyio requeue), QUEUED; a
#     second tick posts nothing. (Red on main: WAIT_CI push a fix for good.)
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
run_tick
[ "$(requeues_of 4121)" = 1 ] && ok || bad "1: exactly one @mergifyio requeue (got: $(cat "$T/comments.txt"); state $(state_of "$(key_of 4121)") '$(reason_of "$(key_of 4121)")')"
[ "$(labeladds_of 4121)" = 1 ] && ok || bad "1: exactly one merge-queue label add (got: $(cat "$T/label-adds.txt"))"
[ "$(state_of "$(key_of 4121)")" = QUEUED ] && ok || bad "1: the row is QUEUED (got $(state_of "$(key_of 4121)"), '$(reason_of "$(key_of 4121)")')"
grep -q "REQUEUED $(key_of 4121) $H4121" "$CLOG" && ok || bad "1: REQUEUED in the log"
grep -q "BATCH_EJECT_BYSTANDER $(key_of 4121) $H4121" "$CLOG" && ok || bad "1: BATCH_EJECT_BYSTANDER in the log"
[ "$(culprit_comments_of 4121)" = 0 ] && ok || bad "1: no culprit comment on a bystander (got: $(cat "$T/attr-comments.txt"))"
grep -q "named another PR, not this one" "$T/attr-comments.txt" && ok || bad "1: the one requeue note says why (got: $(cat "$T/attr-comments.txt"))"
requeued_list 4121
run_tick
[ "$(requeues_of 4121)" = 1 ] && ok || bad "1: the second tick posts no second requeue (got: $(cat "$T/comments.txt"))"
[ "$(labeladds_of 4121)" = 1 ] && ok || bad "1: the second tick adds no label"
[ "$(pr_comments_of 4121)" = 1 ] && ok || bad "1: the second tick posts no PR comment (got $(pr_comments_of 4121))"

# ============================================================================
# 2 — CULPRIT named in a multi-PR batch: not re-queued, WAIT_CI queue-ejected,
#     ONE comment naming the check and its run link; nothing on a second tick.
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$NAMED_EDIT")]"
run_tick
not_requeued 2 4121
[ "$(state_of "$(key_of 4121)")" = WAIT_CI ] && ok || bad "2: WAIT_CI (got $(state_of "$(key_of 4121)"))"
case "$(reason_of "$(key_of 4121)")" in queue-ejected*) ok ;; *) bad "2: reason starts queue-ejected (got '$(reason_of "$(key_of 4121)")')" ;; esac
[ "$(culprit_comments_of 4121)" = 1 ] && ok || bad "2: exactly one culprit comment (got: $(cat "$T/attr-comments.txt"))"
grep -q "\`$CHECK\`: $RUN4121" "$T/attr-comments.txt" && ok || bad "2: the comment names the check and its run link (got: $(cat "$T/attr-comments.txt"))"
grep -q "draft #4276" "$T/attr-comments.txt" && ok || bad "2: the comment names the draft"
grep -q "BATCH_EJECT_CULPRIT $(key_of 4121) $H4121 draft=#4276 checks=$CHECK" "$CLOG" && ok || bad "2: BATCH_EJECT_CULPRIT log line"
grep -q '—' "$T/attr-comments.txt" && bad "2: the PR comment carries no em dash (got: $(cat "$T/attr-comments.txt"))" || ok
run_tick
[ "$(culprit_comments_of 4121)" = 1 ] && ok || bad "2: the second tick posts nothing (got $(culprit_comments_of 4121))"
not_requeued 2-tick2 4121
# 2b — observe mode (MERGES=0) posts nothing.
reset_case
rm -f "$T/h/flags/merge-conductor-merge"
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$NAMED_EDIT")]"
run_tick; run_tick
[ ! -s "$T/attr-comments.txt" ] && ok || bad "2b: observe mode posts no comment (got: $(cat "$T/attr-comments.txt"))"
not_requeued 2b 4121
touch "$T/h/flags/merge-conductor-merge"

# ============================================================================
# 3 — SINGLE-PR DRAFT, no other PR on that base: the culprit. Not re-queued;
#     one comment, on the tick after its verdict was read; never a second.
#     S4: that tick spends no draft read.
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
run_tick
not_requeued 3 4121
[ "$(culprit_comments_of 4121)" = 0 ] && ok || bad "3: the first tick waits a tick before the culprit comment"
grep -q "^bejv $(key_of 4121) $H4121 solo a00ade0 main 4279 " "$A" && ok || bad "3: the verdict is cached (attempts: $(grep bej "$A"))"
: > "$T/gh-calls.txt"
run_tick
[ "$(culprit_comments_of 4121)" = 1 ] && ok || bad "3: one culprit comment on the second tick (got: $(cat "$T/attr-comments.txt"))"
grep -q "tested this PR alone in draft #4279" "$T/attr-comments.txt" && ok || bad "3: the comment says it was tested alone (got: $(cat "$T/attr-comments.txt"))"
grep -q 'pulls/4279' "$T/gh-calls.txt" && bad "S4: a cached verdict spends no draft read" || ok
run_tick
[ "$(culprit_comments_of 4121)" = 1 ] && ok || bad "3: still one after a third tick"
not_requeued 3-tick3 4121
# 3b — `checking #4049 on main (a00ade0), stacked on #4187` is single-PR.
reset_case
add_pr 4049 "$H4049" "[$(fx_comment 4049)]"
run_tick; run_tick
not_requeued 3b 4049
grep -q "^bejv $(key_of 4049) $H4049 solo " "$A" && ok || bad "3b: a stacked single-PR draft is solo, not a bystander (attempts: $(grep bej "$A"))"
[ "$(culprit_comments_of 4049)" = 1 ] && ok || bad "3b: and its culprit comment (got $(culprit_comments_of 4049))"

# ============================================================================
# 4 — a bystander ejected twice on the same head: BLOCKED queue-ejected-twice.
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
printf 'requeued %s %s %s\nreejected %s %s\n' "$(key_of 4121)" "$H4121" "$((NOW-900))" "$(key_of 4121)" "$H4121" >> "$A"
run_tick
[ "$(state_of "$(key_of 4121)")" = BLOCKED_HUMAN ] && ok || bad "4: BLOCKED_HUMAN (got $(state_of "$(key_of 4121)"))"
[ "$(reason_of "$(key_of 4121)")" = queue-ejected-twice ] && ok || bad "4: queue-ejected-twice (got '$(reason_of "$(key_of 4121)")')"
[ "$(requeues_of 4121)" = 0 ] && [ "$(labeladds_of 4121)" = 0 ] && ok || bad "4: not re-queued again"

# ============================================================================
# 5 — MC_QUEUE_REENTRY=0 with case 1's fixture: nothing at all.
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
run_tick MC_QUEUE_REENTRY=0
not_requeued 5 4121
[ "$(reason_of "$(key_of 4121)")" = "$EJWHY" ] && ok || bad "5: WAIT_CI queue-ejected (got '$(reason_of "$(key_of 4121)")')"
[ ! -s "$T/attr-comments.txt" ] && ok || bad "5: no comment"

# ============================================================================
# 6 — SHARED RED (the incident): #4121 and #3981 each identified ALONE on
#     a00ade0 with the same check, main has moved: each re-queued once, no
#     culprit comment. (Red on main.)
# ============================================================================
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
add_pr 3981 "$H3981" "[$(fx_comment 3981)]"
run_tick
run_tick
for n in 4121 3981; do
  [ "$(requeues_of $n)" = 1 ] && ok || bad "6: #$n re-queued exactly once (got $(requeues_of $n); state $(state_of "$(key_of $n)") '$(reason_of "$(key_of $n)")')"
  [ "$(culprit_comments_of $n)" = 0 ] && ok || bad "6: no culprit comment on #$n (got: $(cat "$T/attr-comments.txt"))"
done
grep -q "PRs tested alone on that same base failed it too" "$T/attr-comments.txt" && ok || bad "6: the requeue note says main was red (got: $(cat "$T/attr-comments.txt"))"
requeued_list 4121 3981
run_tick
for n in 4121 3981; do [ "$(requeues_of $n)" = 1 ] && ok || bad "6: no second requeue on #$n"; done
# 6b — main is still at the red base: wait, and say so.
reset_case
printf '%s' "$MAIN_RED_BASE" > "$T/mainsha"
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
add_pr 3981 "$H3981" "[$(fx_comment 3981)]"
run_tick; run_tick
not_requeued 6b 4121; not_requeued 6b 3981
case "$(reason_of "$(key_of 4121)")" in *"main at a00ade0 failed"*"re-queued once main moves"*) ok ;; *) bad "6b: the reason names main at a00ade0 (got '$(reason_of "$(key_of 4121)")')" ;; esac
[ "$(culprit_comments_of 4121)" = 0 ] && [ "$(culprit_comments_of 3981)" = 0 ] && ok || bad "6b: no culprit comments (got: $(cat "$T/attr-comments.txt"))"
: > "$T/gh-calls.txt"
run_tick
grep -qE 'issues/(4121|3981)/comments|pulls/(4279|4290)' "$T/gh-calls.txt" && bad "S4: a cached sharedred spends no comments or draft read (got: $(grep -E 'comments|pulls/42' "$T/gh-calls.txt"))" || ok
# ...and once main moves, they go back in.
printf '%s' "$MAIN_MOVED" > "$T/mainsha"
run_tick
[ "$(requeues_of 4121)" = 1 ] && [ "$(requeues_of 3981)" = 1 ] && ok || bad "6b: once main moves, each re-queued once (got 4121=$(requeues_of 4121) 3981=$(requeues_of 3981))"
# 6c — the branch read fails: no requeue.
reset_case
: > "$T/mainsha"
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
add_pr 3981 "$H3981" "[$(fx_comment 3981)]"
run_tick; run_tick
not_requeued 6c 4121; not_requeued 6c 3981
case "$(reason_of "$(key_of 4121)")" in *"could not be read"*) ok ;; *) bad "6c: the reason says main could not be read (got '$(reason_of "$(key_of 4121)")')" ;; esac
# 6d — the main-red freeze is on: no requeue.
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
add_pr 3981 "$H3981" "[$(fx_comment 3981)]"
echo "main red" > "$T/h/flags/main-red-mgfy"
# The freeze's log line names the exempt test paths; a box's lane registry
# supplies them, and this scratch tree has none.
run_tick MC_MAIN_RED_TEST_PATHS='tests/*'; run_tick MC_MAIN_RED_TEST_PATHS='tests/*'
grep -q 'MAIN_RED_FREEZE in force' "$CLOG" && ok || bad "6d: the freeze is in force (log: $(tail -3 "$CLOG"))"
not_requeued 6d 4121; not_requeued 6d 3981
case "$(reason_of "$(key_of 4121)")" in *"main-red freeze is on"*) ok ;; *) bad "6d: the reason names the freeze (got '$(reason_of "$(key_of 4121)")')" ;; esac
# 6e — two PRs alone on the same base with DISJOINT checks: both culprits.
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121)]"
add_pr 3981 "$H3981" "[$(fx_comment 3981 '.body |= gsub("Pure-logic gate fixtures"; "Test determinism lint")')]"
run_tick; run_tick
not_requeued 6e 4121; not_requeued 6e 3981
[ "$(culprit_comments_of 4121)" = 1 ] && [ "$(culprit_comments_of 3981)" = 1 ] && ok || bad "6e: disjoint checks are two culprits (got: $(cat "$T/attr-comments.txt"))"

# ============================================================================
# 7 — NEGATIVES: none of these is re-queued or commented on.
# ============================================================================
neg() { # neg <case> <comments json> [mergeState]
  reset_case
  add_pr 4121 "$H4121" "$2" "${3:-UNSTABLE}"
  run_tick; run_tick
  not_requeued "$1" 4121
  [ ! -s "$T/attr-comments.txt" ] && ok || bad "$1: no PR comment (got: $(cat "$T/attr-comments.txt"))"
}
neg 7a "[$(jq -c '. + {user: {login: "mergify[bot]", type: "Bot"}}' "$FX/pr4221-checking.json")]"
neg 7b "[$(fx_comment 4121 "$BYSTANDER_EDIT | .body |= sub(\"$H4121\"; \"$H3981\")")]"
neg 7c "[$(jq -c --argjson c "$(fx_comment 4121 "$BYSTANDER_EDIT")" -n '$c | .user.login = "operator"')]"
neg 7d "[$(fx_comment 4121 "$BYSTANDER_EDIT | .body |= sub(\"Failing checks:\"; \"Conflicts:\")")]"
# 7e — the draft read 404s: unknown, today's fr_reentry_gate decides.
reset_case
echo 1 > "$T/draftfail"
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
run_tick
not_requeued 7e 4121
grep -q "FOREIGN_RED_UNKNOWN $(key_of 4121) $H4121" "$CLOG" && ok || bad "7e: today's fr_reentry_gate decided (log: $(grep -o 'mgfy-os#4121 .*' "$CLOG" | tail -3))"
grep -q "^bejv " "$A" && bad "7e: a failed read is never cached" || ok
# 7f — a bystander whose own head has a real red check.
reset_case
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
echo stale_red > "$T/ckmode-4121"
run_tick
not_requeued 7f 4121

# ============================================================================
# 8 — FALLBACK: the lib absent from the tree, case 1's fixture: today exactly.
# ============================================================================
reset_case
rm -f "$T/h/bin/lib/mc-batch-eject.sh"
add_pr 4121 "$H4121" "[$(fx_comment 4121 "$BYSTANDER_EDIT")]"
run_tick
not_requeued 8 4121
[ "$(reason_of "$(key_of 4121)")" = "$EJWHY" ] && ok || bad "8: WAIT_CI push a fix, as before (got '$(reason_of "$(key_of 4121)")')"
[ -r "$LIB" ] && cp "$LIB" "$T/h/bin/lib/"

echo "mc-batch-eject-bystander (BH-4428): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
