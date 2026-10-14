#!/bin/bash
# tests/mc/dep-hold-release.bh-4497-test.sh — BH-4497: a READY PR held by the
# PR-dependency gate is released, and said to be released, on the first tick
# after its dependency closes, and its STUCK page names the dependency as read
# THIS tick, never the hold line logged when it was first held.
#
# THE INCIDENT (2026-10-04). #4415 was held READY at 21:33Z behind "Order 6
# behind #4075 (PR #4242 QUEUED)". #4242 merged at 21:38 and #4075 closed. At
# 21:57 the conductor paged `STUCK 25m in READY … #4242 QUEUED`: the STUCK text
# for a READY row falls back to the last "READY and HELD by" log line, because
# the dependency gate wrote no ready-why note and logged nothing on release.
#
# Driven, not grepped: every case runs bin/merge-conductor.sh WHOLE in a scratch
# tree with the REAL bin/lib/pr-dep-gate.sh, against a stub gh whose issue, PR
# and list answers come from fixture files, so a dependency changes state
# between ticks without touching the clock. Assertions read the sinks: the gh
# write argv ($T/c-enq.txt), logs/merge-conductor.log and logs/ALERTS.log.
# Every fixture time is a literal; nothing here reads the wall clock.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/dep-hold-release.bh-4497-test.sh
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1

SLUG=example-org/demo-os
H1=$(printf 'a%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
FX="$T/fx"
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$FX"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/mc-hold-comment.sh" "$DIR/bin/lib/pr-dep-gate.sh" "$DIR/bin/lib/lane-switch.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
# The ticket fences are not under test: no HOLD on the ticket, not a lead PR.
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
# demo-os is a GitHub-Issues board (board_prefix `-`), so the gate's ticket half runs.
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
REC="$T/h/builds/pool-demo-BH-20-202610040001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# The conductor's own open-PR list: only #41. The sibling's PR #40 is seen by the
# gate through its own REST list (pulls -f state=open), as on the hub.
cat > "$T/list.json" <<J
[{"number":41,"url":"$U/41","headRefOid":"$H1","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub. Issue/PR/list reads the gate makes are answered from $FX:
#   issue-<n>.json   GET repos/<slug>/issues/<n>   (absent: 404)
#   issues-list.json GET repos/<slug>/issues -f state=open …
#   pulls-list.json  GET repos/<slug>/pulls  -f state=open …
#   body41           #41's PR body, in the conductor's and the gate's pulls/41 read
# The enqueue (`@mergifyio queue` on #41) and any merge land in $T/c-enq.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-04T21:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-04T21:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-04T21:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) : ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*) : ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/issues -f state=open"*) restpr --raw 200 "\$(cat "$FX/issues-list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*)  restpr --raw 200 "\$(cat "$FX/pulls-list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/issues/"*)
    n=\$(printf '%s' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p')
    if [ -f "$FX/issue-\$n.json" ]; then restpr --raw 200 "\$(cat "$FX/issue-\$n.json")"
    else restpr --raw 404 '{"message":"Not Found"}'; fi ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "$H1" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "\$(cat "$FX/body41")" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

MCLOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
# issue <n> <open|closed> <body> [pr-merged_at|null] — one issue fixture; the
# 4th argument makes it a PR's issue object (pull_request.merged_at).
issue() {
  if [ -n "${4:-}" ]; then
    jq -n --argjson n "$1" --arg s "$2" --arg b "$3" --arg m "$4" \
      '{number:$n, state:$s, body:$b, labels:[], pull_request:{url:"x", merged_at:(if $m=="null" then null else $m end)}}' > "$FX/issue-$1.json"
  else
    jq -n --argjson n "$1" --arg s "$2" --arg b "$3" '{number:$n, state:$s, body:$b, labels:[{name:"ai-build"}]}' > "$FX/issue-$1.json"
  fi
}
issues_list() { local n; for n in "$@"; do cat "$FX/issue-$n.json"; done | jq -s . > "$FX/issues-list.json"; }
# pulls_list <n:ref:body>... — the gate's open-PR list
pulls_list() {
  local e; for e in "$@"; do
    jq -n --argjson n "${e%%:*}" --arg r "$(cut -d: -f2 <<<"$e")" --arg b "$(cut -d: -f3- <<<"$e")" \
      '{number:$n, state:"open", head:{ref:$r}, body:$b}'
  done | jq -s . > "$FX/pulls-list.json"
}
# reset — a fresh harness state: no rows, no ledger, no logs, no fixtures.
reset() {
  rm -f "$FX"/* "$T/c-enq.txt" "$T/tick.err"; : > "$T/c-enq.txt"
  scratch_rm "$T/h/state/merge-conductor"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"
  rm -f "$T/h/logs/"*.log; mkdir -p "$T/h/state/merge-conductor"; : > "$ROWS"
  echo "PR_CREATED $U/41" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
# tick — one conductor tick; state persists across ticks inside a case.
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_DETACHED_REBASE=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# sibling_row <state> — the conductor's row for the sibling PR #40 (BH-1678 reads it)
sibling_row() {
  awk -F'\t' -v k="$SLUG#40" '$1!=k' "$ROWS" > "$ROWS.t" 2>/dev/null; mv -f "$ROWS.t" "$ROWS"
  printf '%s\t%s\t1759600000\tbbbbbbbb2222\t-\t-\t-\t%s\n' "$SLUG#40" "$1" "$U/40" >> "$ROWS"
}
# age41 — make #41's READY row older than the READY TTL (literal since)
age41() { awk -F'\t' -v OFS='\t' -v k="$SLUG#41" '$1==k { $3=1000000000 } 1' "$ROWS" > "$ROWS.t" && mv -f "$ROWS.t" "$ROWS"; }
state41() { awk -F'\t' -v k="$SLUG#41" '$1==k {print $2}' "$ROWS"; }
enq() { grep -c "repos/$SLUG/issues/41/comments\|pulls/41/merge\|pr merge $U/41" "$T/c-enq.txt" 2>/dev/null || true; }
released() { grep -c "$SLUG#41 READY and RELEASED by the PR-dependency gate" "$MCLOG" 2>/dev/null || true; }
clog() { grep -F "$SLUG#41" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }

# The incident's fixture: #41 closes issue #20, which is Order 2 of 3 under #9.
# Its lower-Order sibling #19 has an open PR #40 on ticket/bh-19, row QUEUED.
order_fixture() {
  echo "Closes #20" > "$FX/body41"
  issue 9 open "the parent"
  issue 19 open "Part of #9
Order: 1 of 3"
  issue 20 open "Part of #9
Order: 2 of 3"
  issues_list 19 20
  pulls_list "40:ticket/bh-19:Closes #19" "41:ticket/bh-20:Closes #20"
  sibling_row QUEUED
}
# dep_lands — #40 merges and #19 closes, between ticks; nothing else changes.
dep_lands() {
  issue 19 closed "Part of #9
Order: 1 of 3"
  issues_list 20
  pulls_list "41:ticket/bh-20:Closes #20"
  sibling_row MERGED
}

# ============================================================================
# C1-C3. Order hold, then the dependency merges, on the SAME head.
# ============================================================================
reset; order_fixture; tick
[ "$(state41)" = READY ] && ok || bad "C1 setup: #41 must reach READY (state '$(state41)'; log: $(clog); err: $(tail -3 "$T/tick.err"))"
[ "$(enq)" = 0 ] && ok || bad "C1 a held row must not be enqueued or merged (argv: $(cat "$T/c-enq.txt"))"
grep -q "$SLUG#41 READY and HELD by the PR-dependency gate on ${H1:0:8}: it declares Order 2 behind #19 (PR #40 QUEUED)" "$MCLOG" && ok \
  || bad "C1 one HELD line naming 'Order 2 behind #19 (PR #40 QUEUED)' (log: $(clog))"
[ "$(released)" = 0 ] && ok || bad "C1 a held tick logs no RELEASED line (log: $(clog))"

dep_lands; : > "$T/c-enq.txt"; tick
[ "$(enq)" = 1 ] && grep -q "issues/41/comments.*@mergifyio queue" "$T/c-enq.txt" && ok \
  || bad "C2 the tick after the dependency merged must enqueue #41 exactly once (argv: $(cat "$T/c-enq.txt"); log: $(clog))"
[ "$(released)" = 1 ] && ok || bad "C2 exactly ONE RELEASED line for #41 on the release tick (got $(released); log: $(clog))"
# #19 closed, so it is off the open ai-build list and no sibling is waiting: the
# live read is the ticket half with nothing to hold on.
grep -q "RELEASED by the PR-dependency gate on ${H1:0:8}: read this tick — no declared dependency in the PR body; issue #20; it goes on to the merge checks this tick" "$MCLOG" && ok \
  || bad "C2 the RELEASED line names the live read: no declared dependency in the PR body; issue #20 (log: $(clog))"
grep -q "#40" <<<"$(grep "RELEASED by the PR-dependency gate" "$MCLOG")" \
  && bad "C2 the RELEASED line must not name the merged #40: $(grep RELEASED "$MCLOG")" || ok
grep -qi "enqueued" <<<"$(grep "RELEASED by the PR-dependency gate" "$MCLOG")" \
  && bad "C2 the RELEASED line must not claim 'enqueued' (D13): $(grep RELEASED "$MCLOG")" || ok

tick
[ "$(released)" = 1 ] && ok || bad "C3 a second passing tick on the same head logs no second RELEASED line (got $(released))"

# ============================================================================
# C4. Body form `Depends on #30 (PR #31)`, the dependency PR closed UNMERGED.
# ============================================================================
reset
printf 'Depends on #30 (PR #31)\n' > "$FX/body41"
issue 31 open "the dependency" null
issues_list; pulls_list "41:ticket/bh-20:Depends on #30 (PR #31)"
tick
[ "$(enq)" = 0 ] && grep -q "$SLUG#41 READY and HELD by the PR-dependency gate" "$MCLOG" && ok \
  || bad "C4 tick 1: #31 open holds #41 (argv: $(cat "$T/c-enq.txt"); log: $(clog))"
issue 31 closed "the dependency" null; : > "$T/c-enq.txt"; tick
[ "$(released)" = 1 ] && grep -q "RELEASED by the PR-dependency gate on ${H1:0:8}: read this tick — dependency landed, closed unmerged #31" "$MCLOG" && ok \
  || bad "C4 a dependency closed without a merge releases with a line that says 'closed unmerged #31' (log: $(clog))"
[ "$(enq)" = 1 ] && ok || bad "C4 the released row goes on to its enqueue that tick (argv: $(cat "$T/c-enq.txt"))"

# ============================================================================
# C5. STUCK after the dependency landed: the page reads the gate LIVE.
# ============================================================================
reset; order_fixture; tick
age41; dep_lands; : > "$ALERTS"; tick
stuck=$(grep -F "$SLUG#41" "$ALERTS" | grep STUCK)
[ -n "$stuck" ] && ok || bad "C5 setup: a READY row past its TTL pages STUCK (alerts: $(cat "$ALERTS"); log: $(clog))"
grep -q "#40 QUEUED" <<<"$stuck" \
  && bad "C5 THE DEFECT: the STUCK page replays the cached tick-1 hold '#40 QUEUED' after #40 merged: $stuck" || ok
grep -q "waiting on the merge itself — the PR-dependency gate, read this tick: released — no declared dependency in the PR body; issue #20; the READY arm goes on" <<<"$stuck" && ok \
  || bad "C5 the STUCK page names the live read (released, issue #20 with no sibling waiting): $stuck"

# ============================================================================
# C6. STUCK while still held: the page says so, as read this tick.
# ============================================================================
reset; order_fixture; tick
age41; : > "$ALERTS"; tick
stuck=$(grep -F "$SLUG#41" "$ALERTS" | grep STUCK)
grep -q "the PR-dependency gate, read this tick: still open — it declares Order 2 behind #19 (PR #40 QUEUED)" <<<"$stuck" && ok \
  || bad "C6 a still-held STUCK page names the dependency as read this tick, still open: ${stuck:-<no STUCK alert>} (log: $(clog))"
[ "$(enq)" = 0 ] && ok || bad "C6 a still-held row is not enqueued (argv: $(cat "$T/c-enq.txt"))"

# C6b. The held tick writes its own dep-hold note, not only the one the hold
#      comment leaves after it posts: with the comment contract off, the note is
#      still there for this head.
reset; order_fixture; tick MC_HOLD_COMMENT=0
grep -qs "	$H1	dep-hold	held by the PR-dependency gate: it declares Order 2 behind #19 (PR #40 QUEUED)" "$T/h/state/merge-conductor/ready-why/"* && ok \
  || bad "C6b every held tick writes the dep-hold ready-why note (note: $(cat "$T/h/state/merge-conductor/ready-why/"* 2>/dev/null))"

# ============================================================================
# C7. The other three lanes are not opted in: pdg_hold without PDG_SAY_PASS
#     prints nothing on a pass; with it, the pass reason.
# ============================================================================
reset; order_fixture; dep_lands
out=$( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" bash -c '. "$HARNESS/bin/lib/gh-rest.sh"; . "$HARNESS/bin/lib/gh-rest-var.sh"; . "$HARNESS/bin/lib/pr-dep-gate.sh"; pdg_hold "$1" 41 "$2" ""; echo "rc=$?"' _ "$SLUG" "$U/41" )
[ "$out" = "rc=1" ] && ok || bad "C7 pdg_hold without PDG_SAY_PASS prints nothing on a pass (got '$out')"
out=$( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" PDG_SAY_PASS=1 bash -c '. "$HARNESS/bin/lib/gh-rest.sh"; . "$HARNESS/bin/lib/gh-rest-var.sh"; . "$HARNESS/bin/lib/pr-dep-gate.sh"; pdg_hold "$1" 41 "$2" ""; echo " rc=$?"' _ "$SLUG" "$U/41" )
[ "$out" = "no declared dependency in the PR body; issue #20 rc=1" ] && ok \
  || bad "C7 with PDG_SAY_PASS=1 the pass prints its reason (got '$out')"
order_fixture; sibling_row WAIT_CI
out=$( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" PDG_SAY_PASS=1 bash -c '. "$HARNESS/bin/lib/gh-rest.sh"; . "$HARNESS/bin/lib/gh-rest-var.sh"; . "$HARNESS/bin/lib/pr-dep-gate.sh"; pdg_hold "$1" 41 "$2" ""; echo " rc=$?"' _ "$SLUG" "$U/41" )
[ "$out" = "no declared dependency in the PR body; issue #20, lower Order siblings #19 not waiting rc=1" ] && ok \
  || bad "C7 a sibling whose PR is not READY/QUEUED is named as not waiting (got '$out')"
out=$( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" PDG_SAY_PASS=1 PR_DEP_GATE=0 bash -c '. "$HARNESS/bin/lib/gh-rest.sh"; . "$HARNESS/bin/lib/gh-rest-var.sh"; . "$HARNESS/bin/lib/pr-dep-gate.sh"; pdg_hold "$1" 41 "$2" ""; echo " rc=$?"' _ "$SLUG" "$U/41" )
[ "$out" = "dep gate OFF rc=1" ] && ok || bad "C7 the kill-switch pass says 'dep gate OFF' under PDG_SAY_PASS (got '$out')"

echo "dep-hold-release.bh-4497: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
