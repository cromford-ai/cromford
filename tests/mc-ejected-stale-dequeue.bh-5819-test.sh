#!/bin/bash
# tests/mc-ejected-stale-dequeue.bh-5819-test.sh — BH-5819: a verdict newer than
# the dequeue does not put a CULPRIT head back in the merge queue.
#
# WHY (#5430, 07:16Z). At 06:28Z bin/lib/mc-stale-dequeue.sh requeued #5221,
# #5281 and #5301 because lead verdicts re-landed by hand bound their SAME
# failed heads after the dequeue. Only a new head clears a culprit's ejection;
# a bystander keeps the arm's requeue:
#
#   S1  the BH-3480 C3b shape (a lead MERGE newer than the dequeue) on a head
#       marked the culprit (dqwculprit): no requeue, the hold logged
#   S2  the same, with the ejection on an OLDER head: requeued (BH-3480 as before)
#   S3  sdq_arm, sourced, a bystander (ejected, no culprit evidence): requeued
#   S4  sdq_arm, sourced, a culprit head: held, STALE_DEQUEUE_EJECTED, no post
#   S6  nothing seeded, a human dequeue after the head: the arm reads it and holds
#   S6b nothing seeded, no culprit evidence: requeued
#   (S1 and S4 seed `dqwculprit` alone, as dequeue-watch writes it)
#   S5  sdq_arm, sourced, MC_EJECTED_REQUEUE=never on a bystander: held
#
# The rig is tests/merge-conductor-stale-dequeue.bh-3480-test.sh's section C.
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
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
FIX="$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json"
SDQ="$DIR/bin/lib/mc-stale-dequeue.sh"
[ -r "$SDQ" ] || { echo "FAIL: $SDQ is missing"; echo "merge-conductor-stale-dequeue.bh-3480: 0 passed, 1 failed"; exit 1; }
# The real dequeued comment of #3396, verbatim, as the template every
# time-relative fixture below is cut from (D4: the shape Mergify writes).
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$FIX")
# mcom <state> <created-epoch> <updated-epoch> <id> [login] — one comment object
mcom() {
  jq -nc --arg b "${DQBODY/\"state\": \"dequeued\"/\"state\": \"$1\"}" --arg c "$(iso "$2")" --arg u "$(iso "$3")" \
     --argjson id "$4" --arg l "${5:-mergify[bot]}" '{id:$id, created_at:$c, updated_at:$u, user:{login:$l}, body:$b}'
}

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/mc-stale-dequeue.sh bin/lib/verdicts.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/catalog"; cp "$DIR/catalog/lead-protected-paths.tsv" "$T/h/catalog/"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done

H2=8747024e0b1c2d3e4f5061728394a5b6c7d8e9f0
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  # The open-PR list over REST, from the list fixture (the full closure reads it so).
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # ---- the two reads BH-3480 adds -----------------------------------------
  *"api --paginate repos/example-org/mgfy-os/issues/"*"/comments"*)
    [ -s "$T/cfail" ] && { echo "gh: HTTP 502" >&2; exit 1; }
    cat "$T/mcomments.json" ;;
  *"api repos/example-org/mgfy-os/commits/"*) cat "$T/headdate" ;;
  # The culprit read (BH-5819) over REST: the PR's comments and the head's date.
  *"api -i -X GET repos/example-org/mgfy-os/issues/31/comments"*) restpr --raw 200 "$(cat "$T/prcomments.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  # BH-6161: the requeue arms ask the pre-queue gate, which reads main's tip
  # (the real commits shape carries a sha); mgfy-os has no prequeue-gate.yml.
  *"api -i -X GET repos/example-org/mgfy-os/commits/main") restpr --raw 200 '{"sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' ;;
  *"actions/workflows/prequeue-gate.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*) restpr --raw 200 "{\"commit\":{\"committer\":{\"date\":\"$(cat "$T/headdate")\"}}}" ;;
  # ---- writes -------------------------------------------------------------
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    printf '%s\n' "$*" >> "$T/label-removes.txt"
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
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
  "api repos/example-org/mgfy-os/pulls/"[0-9]*)
    RN=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    RLJ=$(printf '%s' "$LBL" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/{"name":"&"}/' | paste -sd, -)
    printf '{"number":%s,"html_url":"https://github.com/example-org/mgfy-os/pull/%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"%s","ref":"ticket/mg-31"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"},"labels":[%s],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
      "$RN" "$RN" "$(cat "$T/head-$RN" 2>/dev/null || echo unknown)" "$RLJ" ;;
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
# The jobs worker: the standing verdict on PR 31 is whatever $T/verdict says.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  */api/verdicts\?*)
    if [ -s "$T/verdict" ]; then printf '{"standing":%s}\n200\n' "\$(cat "$T/verdict")"; else printf '{"standing":null}\n200\n'; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31

mkrec() { # mkrec <num> <head> <reviewed-sha>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026092900$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
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
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
requeues()  { grep -c '@mergifyio requeue' "$T/comments.txt"; }
payload_reads() { grep -c 'api --paginate repos/example-org/mgfy-os/issues/31/comments' "$T/gh-calls.txt"; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# The #3396 shape: merge-queue still on (no Mergify label), the row QUEUED from
# last tick, Mergify's newest payload `dequeued` an hour ago.
# setup <labels> <head-committed-epoch> <reviewed-sha>
setup() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/verdict"; : > "$T/cfail"; : > "$CLOG"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/mergify-asks" 2>/dev/null
  echo running > "$T/checkmode"
  printf '%s\n' "$1" | tr ',' '\n' > "$T/labels"
  iso "$2" > "$T/headdate"
  mkrec 31 "$H2" "$3"
  list_row 31 "$H2" "$1" > "$T/list.json"
  printf '[%s]' "$(mcom dequeued $((NOW-3700)) $((NOW-3600)) 100)" > "$T/mcomments.json"
  mc_row_put "$K31" QUEUED $((NOW-300)) "$H2" "$H2" - "in the merge queue" "$U31"
  echo '[]' > "$T/prcomments.json"
}


# A requeue is the arm spending its one (PR, head) requeue: the `requeued` mark,
# written before the write (the post's shape is the closure's, not ours).
requeues() { grep -cE "^requeued $K31 " "$A"; }
H0=0000000011112222333344445555666677778888
lead_merge() { printf '{"verdict":"MERGE","source":"lead","id":7,"created_at":"%s","report_url":null,"reviewer":"lead"}' "$(iso $((NOW-60)))" > "$T/verdict"; }

sdq_src() { # sdq_src [VAR=value ...] — sdq_arm in a subshell, decision forced to `requeue`
  ( export HARNESS_SECRET=x JOBS_URL=http://worker.test "$@"
    SLUG=example-org/mgfy-os NUM=31 KEY="$K31" HEAD="$H2" URL="$U31" P=mgfy MERGES=1 MGABLE=MERGEABLE MSTATE=CLEAN CI=green
    VERDICT=APPROVE REVIEWED="$H2" RAWLBL=merge-queue STATE=READY WHY=""
    . "$T/h/bin/lib/mc-stale-dequeue.sh"
    sdq_decide() { echo requeue; }
    sdq_arm
    printf '%s	%s
' "$STATE" "$WHY" > "$T/sdq.out" )
}

# S1 — dequeue-watch named this head the culprit (`dqwculprit` only: it writes
# no `ejected` line, and the conductor never saw this ejection), a lead MERGE
# newer than the dequeue: not requeued (lead review of 2cc40e58).
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
printf 'dqwculprit %s %s\n' "$K31" "$H2" >> "$A"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "S1: a culprit head must not be requeued on a newer verdict (got $(requeues); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -qE "(STALE_DEQUEUE_EJECTED|EJECTED_HELD|DQW_CULPRIT) $K31 $H2" "$CLOG" && ok || bad "S1: the hold must be logged (log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -qE "^requeued $K31 $H2" "$A" && bad "S1: no requeue mark may be spent" || ok

# S2 — the ejection was on an older head: this head is requeued as before.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
printf 'ejected %s %s
dqwculprit %s %s
' "$K31" "$H0" "$K31" "$H0" >> "$A"
run_tick
[ "$(requeues)" = 1 ] && ok || bad "S2: an ejection on an older head must not hold this one (got $(requeues); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"

# S3 — a bystander: the arm's requeue stands.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
echo "ejected $K31 $H2" >> "$A"
sdq_src
[ "$(requeues)" = 1 ] && ok || bad "S3: a bystander (no culprit evidence) keeps the stale-dequeue requeue (got $(requeues); $(cat "$T/sdq.out" 2>/dev/null))"

# S4 — a culprit head (`dqwculprit` only): held, said, nothing posted.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
printf 'dqwculprit %s %s\n' "$K31" "$H2" >> "$A"
sdq_src
[ "$(requeues)" = 0 ] && ok || bad "S4: sdq_arm requeued a culprit head (got $(requeues))"
case "$(cut -f2 "$T/sdq.out" 2>/dev/null)" in *"as the culprit"*) ok ;; *) bad "S4: WHY '$(cat "$T/sdq.out" 2>/dev/null)'" ;; esac
grep -q "STALE_DEQUEUE_EJECTED $K31 $H2" "$CLOG" && ok || bad "S4: STALE_DEQUEUE_EJECTED must be logged (log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -2))"

# S5 — never: a bystander is held too.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
echo "ejected $K31 $H2" >> "$A"
sdq_src MC_EJECTED_REQUEUE=never
[ "$(requeues)" = 0 ] && ok || bad "S5: MC_EJECTED_REQUEUE=never holds every ejected head (got $(requeues))"

# S6 — nothing seeded: a human `@Mergifyio dequeue` after the head is read by
# this arm itself, and the head is held as the culprit.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
jq -nc --arg c "$(iso $((NOW-1800)))" '[{id:9,user:{login:"operator",type:"User"},created_at:$c,body:"@Mergifyio dequeue\n\nthis head broke batch #5455"}]' > "$T/prcomments.json"
run_tick
[ "$(requeues)" = 0 ] && ok || bad "S6: a human-dequeued head must not be requeued by the stale-dequeue arm (got $(requeues); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"
grep -qx "dqwculprit $K31 $H2" "$A" && ok || bad "S6: the arm must mark the culprit itself (attempts: $(tr '\n' '|' < "$A"))"
# S6b — nothing seeded, no human dequeue: the arm's requeue stands.
setup merge-queue $((NOW-7200)) "$H2"; lead_merge
run_tick
[ "$(requeues)" = 1 ] && ok || bad "S6b: with no culprit evidence the stale-dequeue requeue stands (got $(requeues); log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3))"

echo "mc-ejected-stale-dequeue.bh-5819: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
