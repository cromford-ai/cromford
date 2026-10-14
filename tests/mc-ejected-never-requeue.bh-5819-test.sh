#!/bin/bash
# tests/mc-ejected-never-requeue.bh-5819-test.sh — BH-5819: a CULPRIT head is
# never put back in the merge queue; only a new head clears it. A bystander
# Mergify dequeued with the culprit keeps its requeue.
#
# WHY (#5430, 2026-10-08). #5221, #5281 and #5301 were dequeued for a real batch
# failure and came back into batch #5455 on the SAME heads. And #5462 (13:39Z):
# a human dequeue with evidence, and a solo check that failed, were read as a
# flake and got one free requeue. But a bystander of a failed batch is innocent,
# and freezing it would stall good PRs until somebody pushes. So:
#
#   N1  a bystander (ejected, no culprit evidence): re-queued once (BH-636)
#   N1b MC_EJECTED_REQUEUE=never: the same head is held, EJECTED_HELD once
#   N2  a new head on the same PR: re-queued
#   N3  a human `@Mergifyio dequeue` after the head: the culprit (dqwculprit +
#       reejected), not re-queued, handed to the resolver as queue-ejected-twice
#   N4  the culprit and a bystander side by side: the culprit is held, the
#       bystander is re-queued (two PRs, one tick)
#   N5  a `@mergifyio dequeue` by a bot, or one older than the head: no mark,
#       and the head is re-queued as a bystander
#   N6  a failed solo check (cached a tick earlier, main not red): culprit marks
#   N7  the same, but two PRs failed alone on that base (main red): no mark
#   N8  the conductor's own CR `@mergifyio dequeue` (tagged <!-- mc:crdequeue -->)
#       after the crdequeue mark is cleared: not a culprit, re-queued (lead review r1)
#   N9  the head's commit date cannot be read: no culprit mark, nothing remembered
#   N10 mc_cr_dequeue posts the command alone on line 1 and the tag after it
#   N11 a `bejv` line written this tick (caller passes solo_ok 0) is not a culprit
#   N12 a clean human-dequeue read is remembered: the next tick reads no comments
#   N14 a REAL second ejection on an older head (reejected with no
#       culpritreejected) still counts: the new head goes to the resolver, as on main
#   N13 a culprit head (dqwculprit + reejected on H1), then a NEW head H2 that
#       still carries Mergify's `dequeued` label: H2 is re-queued, never
#       queue-ejected-twice (lead review of 4fedb2dd: strikes were per PR)
#
# The rig is tests/merge-conductor-dqw-culprit.bh-3719-test.sh's (the real
# bin/merge-conductor.sh against a stub gh and worker), with the PR's comments
# and the head's commit date answered for the culprit read.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-ejected-never-requeue.bh-5819-test.sh
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

H1=aaaaaaaa1111
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
echo none > "$T/checkmode"        # none | running | failed
echo green > "$T/cistate"         # green | red
: > "$T/labels"                   # the labels on PR 31 (one per line)
echo ok > "$T/qview"              # ok | fail   (the mc_queue_state read)
: > "$T/dqfail"                   # non-empty => the dequeued DELETE is refused 403

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  # The open-PR list over REST, from the list fixture (the full closure reads it
  # this way; the bridge is for suites with hand-copied libs).
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  # BH-5819: the PR's comments (a human dequeue) and the head's commit date.
  *"issues/31/comments"*) restpr --raw 200 "$(cat "$T/prcomments.json" 2>/dev/null || echo '[]')" ;;
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
  # The Mergify check-runs read is a REST decision read on the contract now
  # (BH-784): it answers with a status line, and "no check" is an answered empty
  # list rather than an echoed blank. Same facts as the old arm.
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # ---- writes -------------------------------------------------------------
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
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
for f in gh-calls label-adds label-removes comments merges reruns writes; do : > "$T/$f.txt"; done
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026091700$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <mergeState> <mergeable> <labels-csv>
  local lbl="[]"
  [ -n "${5:-}" ] && lbl=$(printf '%s' "$5" | jq -R 'split(",")|map({name:.})' -c)
  printf '{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}' \
    "$1" "$1" "$2" "$1" "$3" "$4" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "${CONDUCTOR:-$T/h/bin/merge-conductor.sh}" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
H0=bbbbbbbb0000
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
reset_case() {
  : > "$A"; : > "$T/labels"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"
  : > "$T/comments.txt"; : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  echo green > "$T/cistate"; echo running > "$T/checkmode"; echo ok > "$T/qview"
  echo '[]' > "$T/prcomments.json"; : > "$T/commitfail"
}
# The C1 READY/ejected fixture of bh-636: green, approved on H1, CLEAN, ejected.
c1_fixture() {
  reset_case
  mkrec 31 "$H1"
  printf 'dequeued\n' > "$T/labels"
  printf '[%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" > "$T/list.json"
  echo "ejected $K31 $H1" >> "$A"
}
requeues() { grep -c 'labels\[\]=merge-queue' "$T/label-adds.txt"; }
culprit_logs() { grep -c "DQW_CULPRIT $K31 $H1" "$CLOG"; }

H2=cccccccc2222
# A requeue is the arm spending its one (PR, head) requeue: the `requeued` mark,
# written before the write (the label call's shape is the closure's, not ours).
requeues() { grep -cE "^requeued $K31 " "$A"; }
dq_comment() { # dq_comment <login> <type> <created_at>
  jq -nc --arg l "$1" --arg t "$2" --arg c "$3" '[{id:9,user:{login:$l,type:$t},created_at:$c,body:"@Mergifyio dequeue\n\nmerge-queue check #5469 ran it alone on main and it failed"}]' > "$T/prcomments.json"
}

# N1 — a bystander: re-queued once, as BH-636 does.
c1_fixture
run_tick
[ "$(requeues)" = 1 ] && pass "N1: a bystander (no culprit evidence) is re-queued once" || fail "N1: want 1 requeue, got $(requeues) (state $(state_of "$K31"), why '$(reason_of "$K31")')"

# N1b — MC_EJECTED_REQUEUE=never: every ejected head is held.
c1_fixture
run_tick MC_EJECTED_REQUEUE=never
[ "$(requeues)" = 0 ] && pass "N1b: never holds an ejected head" || fail "N1b: re-queued under never ($(requeues))"
case "$(reason_of "$K31")" in *"only a new head clears it"*) pass "N1b: the reason says only a new head clears it" ;; *) fail "N1b: WHY '$(reason_of "$K31")'" ;; esac
run_tick MC_EJECTED_REQUEUE=never
[ "$(requeues)" = 0 ] && [ "$(grep -c "EJECTED_HELD $K31 $H1" "$CLOG")" = 1 ] && pass "N1b: still held on tick 2, EJECTED_HELD logged once"   || fail "N1b: tick 2: requeues=$(requeues), EJECTED_HELD lines=$(grep -c "EJECTED_HELD $K31 $H1" "$CLOG")"

# N2 — a new head: the ejection was on the old one.
c1_fixture
mkrec 31 "$H2"
printf '[%s]' "$(list_row 31 "$H2" CLEAN MERGEABLE dequeued)" > "$T/list.json"
run_tick
[ "$(requeues)" = 1 ] && pass "N2: a new head on the same PR is re-queued" || fail "N2: want 1 requeue for the new head, got $(requeues) (state $(state_of "$K31"), why '$(reason_of "$K31")')"

# N3 — a human dequeue after the head: the culprit, never re-queued.
c1_fixture
dq_comment operator User 2026-10-09T10:37:00Z
run_tick
[ "$(requeues)" = 0 ] && pass "N3: a human-dequeued head is not re-queued" || fail "N3: re-queued ($(requeues))"
grep -qx "dqwculprit $K31 $H1" "$A" && grep -qx "reejected $K31 $H1" "$A" && pass "N3: marked dqwculprit + reejected"   || fail "N3: marks missing (attempts: $(tr '
' '|' < "$A"))"
grep -q "EJECT_CULPRIT $K31 $H1 — a human dequeue by operator" "$CLOG" && pass "N3: EJECT_CULPRIT names the human dequeue" || fail "N3: no EJECT_CULPRIT line ($(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && [ "$(reason_of "$K31")" = queue-ejected-twice ] && pass "N3: handed to the resolver (queue-ejected-twice)"   || fail "N3: state '$(state_of "$K31")' why '$(reason_of "$K31")'"

# N4 — the culprit and a bystander of one failed batch, in one tick.
c1_fixture
H32=dddddddd3333; K32='example-org/mgfy-os#32'
mkrec 32 "$H32"
printf '[%s,%s]' "$(list_row 31 "$H1" CLEAN MERGEABLE dequeued)" "$(list_row 32 "$H32" CLEAN MERGEABLE dequeued)" > "$T/list.json"
printf 'ejected %s %s
dqwculprit %s %s
' "$K32" "$H32" "$K32" "$H32" >> "$A"
run_tick
grep -qE "^requeued $K31 $H1" "$A" && pass "N4: the bystander (#31) is re-queued" || fail "N4: the bystander was not re-queued (attempts: $(tr '
' '|' < "$A"))"
grep -qE "^requeued $K32 $H32" "$A" && fail "N4: the culprit (#32) was re-queued" || pass "N4: the culprit (#32) is not re-queued"

# N5 — a bot's dequeue, or a human one older than the head: not a culprit.
c1_fixture
dq_comment 'mergify[bot]' Bot 2026-10-09T10:37:00Z
run_tick
grep -q "^dqwculprit $K31 $H1" "$A" && fail "N5: a bot's dequeue must not mark the culprit" || pass "N5: a bot's dequeue is not a culprit mark"
[ "$(requeues)" = 1 ] && pass "N5: ...and the head is re-queued as a bystander" || fail "N5: want 1 requeue, got $(requeues)"
c1_fixture
dq_comment operator User 2026-10-07T10:37:00Z
run_tick
grep -q "^dqwculprit $K31 $H1" "$A" && fail "N5: a dequeue older than the head must not mark it" || pass "N5: a dequeue older than the head is not a culprit mark"

# N6/N7 — the solo-check culprit, through mc_eject_culprit_mark itself (the
# lane's bej_* reads stubbed: their own suite, mc-batch-eject-bystander, pins them).
solo_case() { # solo_case <shared-count> -> rc of mc_eject_culprit_mark
  c1_fixture
  echo "bejv $K31 $H1 solo a00ade0 main 4279 x x" >> "$A"
  ( gh_rest_issue_comments() { echo '[]'; }
    bej_verdict() { BEJ_WORD=solo; BEJ_BASE=a00ade0; BEJ_CHECKS=x; BEJ_DRAFT=4279; BEJ_CACHED=1; }
    bej_solo_note() { :; }; bej_culprit_note() { echo culprit-note >> "$T/solo-notes.txt"; }
    bej_shared_count() { echo "$1_unused" >/dev/null; echo "$SHARED"; }
    _bej_knob() { echo 2; }
    SHARED="$1" mc_eject_culprit_mark example-org/mgfy-os 31 "$K31" "$H1" )
}
: > "$T/solo-notes.txt"
solo_case 1; RCS=$?
[ "$RCS" = 0 ] && grep -qx "dqwculprit $K31 $H1" "$A" && grep -qx "reejected $K31 $H1" "$A"   && pass "N6: a failed solo check marks the culprit" || fail "N6: rc=$RCS attempts: $(tr '
' '|' < "$A")"
grep -q "EJECT_CULPRIT $K31 $H1 — a failed solo check (draft #4279" "$CLOG" && pass "N6: EJECT_CULPRIT names the solo draft" || fail "N6: no EJECT_CULPRIT line ($(tail -2 "$CLOG"))"
[ "$(grep -c culprit-note "$T/solo-notes.txt")" = 1 ] && pass "N6: the PR is told what failed (bej_culprit_note)" || fail "N6: no culprit note"
solo_case 2; RCS=$?
[ "$RCS" = 1 ] && ! grep -q "^dqwculprit $K31 $H1" "$A" && pass "N7: main red (two PRs failed alone) is not a culprit" || fail "N7: rc=$RCS attempts: $(tr '
' '|' < "$A")"

# N8 — the conductor's own CR dequeue, read after its crdequeue mark is gone
# (CR dequeue, CR cleared, re-queued on the same head, then ejected as a
# bystander). The shared PAT posts it as type User, so only the tag tells it apart.
c1_fixture
jq -nc '[{id:11,user:{login:"operator",type:"User"},created_at:"2026-10-09T10:37:00Z",body:"@mergifyio dequeue\n\n<!-- mc:crdequeue -->"}]' > "$T/prcomments.json"
run_tick
grep -q "^dqwculprit $K31 $H1" "$A" && fail "N8: the conductor's own tagged dequeue must not mark the culprit (attempts: $(tr '\n' '|' < "$A"))" \
  || pass "N8: the conductor's own tagged dequeue is not a culprit mark"
[ "$(requeues)" = 1 ] && pass "N8: ...and the bystander is re-queued" || fail "N8: want 1 requeue, got $(requeues)"

# N9 — the head's commit date cannot be read: never the epoch.
c1_fixture
dq_comment operator User 2026-10-07T10:37:00Z
echo 1 > "$T/commitfail"
run_tick
grep -q "^dqwculprit $K31 $H1" "$A" && fail "N9: an unread head date must not count an old dequeue (attempts: $(tr '\n' '|' < "$A"))" \
  || pass "N9: an unread head date marks no culprit"
grep -q "^culpritchecked $K31 $H1" "$A" && fail "N9: an unread head date must not be remembered as checked" \
  || pass "N9: ...and nothing is remembered, so a later tick reads again"

# N10 — the body mc_cr_dequeue posts: the command alone on line 1, then the tag.
c1_fixture
: > "$T/gh-calls.txt"
( mc_cr_dequeue example-org/mgfy-os "$K31" "$U31" "$H1" 1 "$(printf 'x\tlead\t2026-10-09T10:00:00Z\tcr-1@x')"; echo "rc=$?" ) > "$T/n10.out" 2>&1
# gh-calls.txt holds every argv, one per line; the body's newlines split it.
B=$(sed -n '/-X POST repos\/example-org\/mgfy-os\/issues\/31\/comments/,$p' "$T/gh-calls.txt")
[ "$(head -1 <<<"$B" | grep -c -- '-f body=@mergifyio dequeue$')" = 1 ] && grep -qxF '<!-- mc:crdequeue -->' <<<"$B" \
  && pass "N10: the CR dequeue keeps the command alone on line 1 and carries the tag" \
  || fail "N10: the posted comment: $B (run: $(cat "$T/n10.out"); log: $(tail -2 "$CLOG"))"
[ "${MC_CRDEQUEUE_TAG:-}" = '<!-- mc:crdequeue -->' ] && pass "N10: the tag the read ignores is the tag the post writes" \
  || fail "N10: MC_CRDEQUEUE_TAG is '${MC_CRDEQUEUE_TAG:-}'"

# N11 — the solo verdict was cached THIS tick (after the re-entry gate): wait.
c1_fixture
echo "bejv $K31 $H1 solo a00ade0 main 4279 x x" >> "$A"
( gh_rest_issue_comments() { echo '[]'; }
  bej_verdict() { BEJ_WORD=solo; BEJ_BASE=a00ade0; BEJ_CHECKS=x; BEJ_DRAFT=4279; BEJ_CACHED=1; }
  bej_solo_note() { :; }; bej_culprit_note() { :; }; bej_shared_count() { echo 1; }; _bej_knob() { echo 2; }
  mc_eject_culprit_mark example-org/mgfy-os 31 "$K31" "$H1" 0 ); RCS=$?
[ "$RCS" = 1 ] && ! grep -q "^dqwculprit $K31 $H1" "$A" && pass "N11: a bejv line from this tick does not mark the culprit yet" \
  || fail "N11: rc=$RCS attempts: $(tr '\n' '|' < "$A")"

# N12 — a clean read is remembered for the head.
c1_fixture
run_tick MC_REQUEUE_CAP=0
grep -qx "culpritread $K31 $H1" "$A" && pass "N12: a clean human-dequeue read is remembered" || fail "N12: no culpritread mark (attempts: $(tr '\n' '|' < "$A"))"
grep -qE "commits/$H1\$" "$T/gh-calls.txt" && pass "N12: tick 1 did run the culprit read (the line tick 2 must not repeat)" || fail "N12: tick 1 shows no commits/$H1 read, so tick 2's check proves nothing"
: > "$T/gh-calls.txt"
run_tick MC_REQUEUE_CAP=0
# The culprit check's first read is the head's commit (the re-entry gate reads
# the comments for its own verdict, so they are not this check's signal).
grep -qE "commits/$H1\$" "$T/gh-calls.txt" && fail "N12: tick 2 ran the culprit read again" || pass "N12: tick 2 does not run the culprit read again"

# N13 — the culprit's marks are its head's: a new head is queued.
c1_fixture
# The marks mc_eject_culprit_mark writes: dqwculprit, reejected, culpritreejected.
printf 'dqwculprit %s %s\nreejected %s %s\nculpritreejected %s %s\n' "$K31" "$H1" "$K31" "$H1" "$K31" "$H1" >> "$A"
mkrec 31 "$H2"
printf '[%s]' "$(list_row 31 "$H2" CLEAN MERGEABLE dequeued)" > "$T/list.json"
run_tick
[ "$(requeues)" = 1 ] && pass "N13: a new head after a culprit head is re-queued" \
  || fail "N13: want 1 requeue for H2, got $(requeues) (state $(state_of "$K31"), why '$(reason_of "$K31")')"
# A prefix match (BH-6161): queue-ejected-twice may carry its causes after a colon.
case "$(reason_of "$K31")" in queue-ejected-twice*) fail "N13: H2 went to the resolver as queue-ejected-twice ('$(reason_of "$K31")')" ;; *) pass "N13: ...and is not handed to the resolver" ;; esac
grep -q 'labels/dequeued' "$T/label-removes.txt" && pass "N13: the stale dequeued label is removed for the new head" || fail "N13: the dequeued label stayed on ($(cat "$T/label-removes.txt"))"

# N14 — H1 was requeued and ejected again for real, and dequeue-watch named it:
# two real strikes, so a new head is the resolver's, as on main (review note).
c1_fixture
printf 'requeued %s %s 1\nreejected %s %s\ndqwculprit %s %s\n' "$K31" "$H1" "$K31" "$H1" "$K31" "$H1" >> "$A"
mkrec 31 "$H2"
printf '[%s]' "$(list_row 31 "$H2" CLEAN MERGEABLE dequeued)" > "$T/list.json"
run_tick
[ "$(reason_of "$K31")" = queue-ejected-twice ] && pass "N14: a real second ejection on an older head still counts" \
  || fail "N14: want queue-ejected-twice, got state $(state_of "$K31") why '$(reason_of "$K31")' (requeues $(requeues))"

echo "mc-ejected-never-requeue.bh-5819: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
