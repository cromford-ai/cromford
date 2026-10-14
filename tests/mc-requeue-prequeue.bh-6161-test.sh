#!/bin/bash
# tests/mc-requeue-prequeue.bh-6161-test.sh — BH-6161: a requeue after a queue
# ejection waits for a pre-queue run on current main, and goes in only if that
# run passes.
#
# WHY. #4735 and #4029 were ejected for failing checks and put back on the SAME
# head with nothing run in between: the BH-636 re-entry arm and the BH-3480
# stale-dequeue arm posted `@mergifyio requeue` with no gate, and when the gate
# did run, pq_resolve reused the green verdict that had let the head into the
# failed batch. Now both arms ask pq_gate first (ec_requeue_gate,
# bin/lib/mc-eject-cause.sh), and a verdict dispatched before the ejection is
# not reused (PQ_MIN_AT, bin/lib/mc-prequeue.d/dispatch.sh).
#
#   Q1  the gate answers proceed: asked once, REQUEUE_PREQUEUE -> proceed, with
#       PQ_MIN_AT = the recorded ejection time
#   Q1b ...and the same tick posts the requeue and writes the requeued mark
#   Q2  hold: no requeue, WAIT_CI `queue-ejected: requeue waits for the pre-queue run`
#   Q3  red: BLOCKED_HUMAN prequeue-red, one pqred mark
#   Q4  the real pq_resolve: a green dispatched before the ejection on an older
#       main is not reused; a run is dispatched for the current main
#   Q5  the same green dispatched after the ejection is reused: proceed
#   Q6  the gate is asked before the requeue budget, and logs once per word
#   Q7  MC_REQUEUE_PREQUEUE=0: no gate, the requeue is posted as before
#   Q8  a cached conflict on current main: NEEDS_REBASE, no requeue
#   S1  sdq_arm, gate hold: no STALE_DEQUEUE_REQUEUED, WAIT_CI, PQ_MIN_AT = the dequeue time
#   S2  sdq_arm, gate proceed: STALE_DEQUEUE_REQUEUED once
#
# The rig is tests/mc-eject-cause.bh-6161-test.sh's (the real conductor closure
# against a stub gh). The gate's verdict comes from a pq_resolve hook dropped
# into bin/lib/mc-prequeue.d/, the pattern of tests/mc/prequeue-isolation.bh-4545-test.sh.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-requeue-prequeue.bh-6161-test.sh
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
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/mc-stale-dequeue.sh bin/lib/verdicts.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The lib under test. Absent on main: the red this suite opens on.
[ -r "$DIR/bin/lib/mc-eject-cause.sh" ] && { scratch_install_closure bin/lib/mc-eject-cause.sh "$T/h" >/dev/null || { echo "FAIL: closure of mc-eject-cause.sh"; exit 1; }; }
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/catalog"; cp "$DIR/catalog/lead-protected-paths.tsv" "$T/h/catalog/"
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
  *"api --paginate repos/example-org/mgfy-os/issues/"*"/comments"*) cat "$T/mcomments.json" 2>/dev/null || echo '[]' ;;
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
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

M_OLD=dddddddddddddddddddddddddddddddddddddddd

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
requeues()  { grep -cE "^requeued $K31 " "$A"; }
# A requeue write: our merge-queue label back on, or a `@mergifyio requeue` comment.
posts()     { cat "$T/label-adds.txt" "$T/comments.txt" 2>/dev/null | grep -cE 'labels\[\]=merge-queue|@mergifyio requeue'; }
gate_calls() { [ -r "$T/resolve-calls" ] && wc -l < "$T/resolve-calls" || echo 0; }
gate_lines() { grep -c "REQUEUE_PREQUEUE $K31 " "$CLOG"; }
# hook <word> — the pq_resolve hook answers <word> (red names tests/a.sh) and
#   records "<head> <main> <PQ_MIN_AT>" per call.
hook() {
  echo "$1" > "$T/pqword"
  cat > "$T/h/bin/lib/mc-prequeue.d/zz-stub.sh" <<HOOK
pq_resolve() { echo "\$4 \$5 \${PQ_MIN_AT:-}" >> "$T/resolve-calls"; PQ_WHY=stub-why
  w=\$(cat "$T/pqword"); [ "\$w" = red ] && PQ_SUITES=tests/a.sh; echo "\$w"; }
HOOK
}
# ejected_ready — the BH-636 bystander: READY on H1, green, approved, CLEAN,
#   Mergify's dequeued label on, an `ejected` mark and one ejection record.
ejected_ready() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/cmtfail"; : > "$CLOG"
  rm -f "$MCD/pr-state.tsv" "$T/resolve-calls"; touch "$MCD/pr-state.tsv"
  scratch_rm "$MCD/tick"; scratch_rm "$MCD/mergify-asks"; scratch_rm "$MCD/eject-cause"; scratch_rm "$MCD/prequeue"
  echo running > "$T/checkmode"; echo '[]' > "$T/prcomments.json"
  printf 'dequeued\n' > "$T/labels"
  mkrec 31 "$H1"
  list_row 31 "$H1" dequeued > "$T/list.json"
  echo "ejected $K31 $H1" >> "$A"
  ( . "$T/h/bin/lib/mc-eject-cause.sh" && ec_record example-org/mgfy-os 31 "$H1" first checks "Pure-logic gate fixtures" ) 2>/dev/null
  EJAT=$( ( . "$T/h/bin/lib/mc-eject-cause.sh" && ec_last_at example-org/mgfy-os 31 "$H1" ) 2>/dev/null)
}

# Q1 / Q1b — proceed: asked once, then requeued.
ejected_ready; hook proceed
run_tick
[ "$(gate_calls)" = 1 ] && pass "Q1: the re-entry arm asks the pre-queue gate once" || fail "Q1: gate calls $(gate_calls) (state $(state_of "$K31"), reason '$(reason_of "$K31")')"
[ -n "${EJAT:-}" ] && [ "$(cut -d' ' -f3 "$T/resolve-calls" 2>/dev/null)" = "$EJAT" ] \
  && pass "Q1: PQ_MIN_AT is the recorded ejection time" || fail "Q1: PQ_MIN_AT '$(cut -d' ' -f3 "$T/resolve-calls" 2>/dev/null)' want '${EJAT:-}'"
[ "$(grep -c "REQUEUE_PREQUEUE $K31 $H1 main=${M:0:12} -> proceed" "$CLOG")" = 1 ] \
  && pass "Q1: one REQUEUE_PREQUEUE -> proceed line" || fail "Q1: $(grep -o 'REQUEUE_PREQUEUE.*' "$CLOG" | head -2)"
[ "$(requeues)" = 1 ] && [ "$(posts)" -ge 1 ] && pass "Q1b: the same tick posts the requeue and writes the requeued mark" \
  || fail "Q1b: requeues $(requeues), posts $(posts) (state $(state_of "$K31"), reason '$(reason_of "$K31")')"

# Q2 — hold: no requeue.
ejected_ready; hook hold
run_tick
[ "$(requeues)" = 0 ] && [ "$(posts)" = 0 ] && pass "Q2: a hold posts no requeue and spends no requeue mark" || fail "Q2: requeues $(requeues), posts $(posts)"
[ "$(state_of "$K31")" = WAIT_CI ] && pass "Q2: the row waits (WAIT_CI)" || fail "Q2: state '$(state_of "$K31")'"
case "$(reason_of "$K31")" in "queue-ejected: requeue waits for the pre-queue run on main ${M:0:12}: stub-why"*) pass "Q2: the reason says the requeue waits for the pre-queue run" ;;
  *) fail "Q2: reason '$(reason_of "$K31")'" ;; esac

# Q3 — red: parked prequeue-red, the resolver's.
ejected_ready; hook red
run_tick
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "Q3: a red gate parks the head" || fail "Q3: state '$(state_of "$K31")' reason '$(reason_of "$K31")'"
case "$(reason_of "$K31")" in "prequeue-red: tests/a.sh on main ${M:0:12}"*) pass "Q3: the reason is prequeue-red and names the suite" ;; *) fail "Q3: reason '$(reason_of "$K31")'" ;; esac
[ "$(grep -c "^pqred $K31 $H1 $M" "$A")" = 1 ] && [ "$(requeues)" = 0 ] && pass "Q3: one pqred mark, no requeue" || fail "Q3: pqred $(grep -c '^pqred' "$A"), requeues $(requeues)"

# Q6 — the gate is asked BEFORE the requeue budget, and says so once per word.
ejected_ready; hook hold
run_tick MC_REQUEUE_CAP=0
run_tick MC_REQUEUE_CAP=0
grep -q "REQUEUE_DEFERRED $K31" "$CLOG" && fail "Q6: a held head reached the requeue budget" || pass "Q6: a held head never reaches the requeue budget"
[ "$(gate_lines)" = 1 ] && [ "$(gate_calls)" = 2 ] && pass "Q6: two ticks ask twice and log one REQUEUE_PREQUEUE line" || fail "Q6: lines $(gate_lines), calls $(gate_calls)"
[ "$(requeues)" = 0 ] && [ "$(posts)" = 0 ] && pass "Q6: nothing posted" || fail "Q6: requeues $(requeues), posts $(posts)"

# Q7 — knob off: no gate, requeued as before.
ejected_ready; hook hold
run_tick MC_REQUEUE_PREQUEUE=0
[ "$(gate_calls)" = 0 ] && [ "$(requeues)" = 1 ] && pass "Q7: MC_REQUEUE_PREQUEUE=0 requeues with no gate" || fail "Q7: gate calls $(gate_calls), requeues $(requeues)"

# Q8 — a cached conflict for (H1, current main): NEEDS_REBASE.
ejected_ready; rm -f "$T/h/bin/lib/mc-prequeue.d/zz-stub.sh"
( MC_STATE_DIR="$MCD" P=mgfy; . "$T/h/bin/lib/mc-prequeue.sh" || exit 1
  pq_cache_put "$(pq_key example-org/mgfy-os 31 "$H1" "$M")" conflict "$NOW" 77 "" ) || fail "Q8: fixture write"
run_tick
[ "$(state_of "$K31")" = NEEDS_REBASE ] && [ "$(requeues)" = 0 ] && pass "Q8: a cached conflict goes to NEEDS_REBASE, not the queue" \
  || fail "Q8: state '$(state_of "$K31")' reason '$(reason_of "$K31")' requeues $(requeues)"

# ============================================================================
# Q4, Q5: the real pq_resolve and the PQ_MIN_AT filter.
# ============================================================================
# resolve_case <entry-at> -> pq_resolve's word; dispatches land in $T/dispatches.
resolve_case() {
  scratch_rm "$MCD/prequeue"; : > "$T/dispatches"
  ( MC_STATE_DIR="$MCD" MC_H="$T/h" P=mgfy PQ_MAIN="" PQ_SUITES="" PQ_WHY="" PQ_PATH=""
    . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; . "$T/h/bin/lib/mc-prequeue.sh" || exit 1
    pq_cache_put "$(pq_key example-org/mgfy-os 31 "$H1" "$M_OLD")" green "$1" 55 "" || exit 1
    pq_wf_present() { _pq_wf=yes; }; pq_prune() { :; }; pq_dispatch_veto() { return 1; }
    pq_merge_test() { return 0; }; pq_dispatch() { echo "$4" >> "$T/dispatches"; return 0; }
    # BH-6335 (TEST-CHANGE): pq_resolve also drops a green whose main is more
    # than MC_PREQUEUE_FRESH_COMMITS behind (one compare read). The stub gh has
    # no compare route, so pin the distance at 0: Q4/Q5 test PQ_MIN_AT only.
    pq_main_behind() { _pq_bn=0; echo 0; }
    PQ_MIN_AT=$((NOW-300)) pq_resolve example-org/mgfy-os 31 "$U31" "$H1" "$M" "$(pq_key example-org/mgfy-os 31 "$H1" "$M")" | tail -n1 ) 2>/dev/null
}
Q4=$(resolve_case $((NOW-360)))
[ "$Q4" = hold ] && pass "Q4: a green dispatched before the ejection is not reused: hold" || fail "Q4: want hold (a new run), got '$Q4'"
[ "$(cat "$T/dispatches")" = "$M" ] && pass "Q4: a run is dispatched for the current main" || fail "Q4: dispatches '$(cat "$T/dispatches")'"
Q5=$(resolve_case $((NOW-240)))
[ "$Q5" = proceed ] && [ ! -s "$T/dispatches" ] && pass "Q5: a green dispatched after the ejection is reused" || fail "Q5: word '$Q5', dispatches '$(cat "$T/dispatches")'"

# ============================================================================
# S1, S2: the BH-3480 stale-dequeue arm asks the same gate.
# ============================================================================
FIX="$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json"
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$FIX")
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
DQT=$((NOW-3600))
sdq_src() { # sdq_src [VAR=value ...] — sdq_arm in a subshell, decision forced to `requeue`
  : > "$CLOG"; : > "$A"; : > "$T/comments.txt"; : > "$T/label-adds.txt"; rm -f "$T/resolve-calls"; scratch_rm "$MCD/tick"
  jq -nc --arg b "$DQBODY" --arg c "$(iso $((DQT-100)))" --arg u "$(iso "$DQT")" '[{id:100, created_at:$c, updated_at:$u, user:{login:"mergify[bot]"}, body:$b}]' > "$T/mcomments.json"
  ( export HARNESS_SECRET=x JOBS_URL=http://worker.test "$@"
    SLUG=example-org/mgfy-os NUM=31 KEY="$K31" HEAD="$H1" URL="$U31" P=mgfy MERGES=1 MGABLE=MERGEABLE MSTATE=CLEAN CI=green
    VERDICT=APPROVE REVIEWED="$H1" RAWLBL=merge-queue STATE=READY WHY="" PBASE=main
    # The libs the conductor loads beside it: the gate, and the requeue gate.
    . "$T/h/bin/lib/mc-prequeue.sh"; . "$T/h/bin/lib/mc-eject-cause.sh" 2>/dev/null
    . "$T/h/bin/lib/mc-stale-dequeue.sh"
    sdq_decide() { echo requeue; }
    sdq_arm
    printf '%s\t%s\n' "$STATE" "$WHY" > "$T/sdq.out" )
}
ejected_ready; hook hold
sdq_src
grep -q "STALE_DEQUEUE_REQUEUED $K31" "$CLOG" && fail "S1: a held head was requeued by the stale-dequeue arm" || pass "S1: gate hold: no STALE_DEQUEUE_REQUEUED"
case "$(cat "$T/sdq.out" 2>/dev/null)" in "WAIT_CI	dequeued by Mergify; requeue waits"*) pass "S1: WAIT_CI, dequeued by Mergify; requeue waits …" ;; *) fail "S1: got '$(cat "$T/sdq.out" 2>/dev/null)'" ;; esac
[ "$(cut -d' ' -f3 "$T/resolve-calls" 2>/dev/null)" = "$DQT" ] && pass "S1: PQ_MIN_AT is Mergify's dequeue time" || fail "S1: PQ_MIN_AT '$(cut -d' ' -f3 "$T/resolve-calls" 2>/dev/null)' want $DQT"
ejected_ready; hook proceed
sdq_src
[ "$(grep -c "STALE_DEQUEUE_REQUEUED $K31" "$CLOG")" = 1 ] && pass "S2: gate proceed: STALE_DEQUEUE_REQUEUED once" || fail "S2: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3)"

echo "mc-requeue-prequeue.bh-6161: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
