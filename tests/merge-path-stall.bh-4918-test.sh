#!/bin/bash
# tests/merge-path-stall.bh-4918-test.sh — BH-4918: one slow PR worker no longer
# takes its siblings down with it, and a READY row leaves every tick enqueued or
# held with a reason.
#
# THE STALL. bin/merge-conductor-backstop.sh runs the keyed conductor under
# `timeout`, which signals its whole process group. Every pr_worker of the tick
# is in that group, so one worker stuck on a slow GitHub read took the six
# healthy siblings (and the tick's ae_project enqueue) down with it, and the
# next tick reported `run died before fan-in`. The fix is a per-worker deadline,
# MC_WORKER_DEADLINE_S (bin/lib/fanin.sh mc_worker_bounded), that the backstop
# keeps under its own timeout.
#
#   D1  one slow worker (#34), six enqueue: the REAL backstop into the REAL
#       conductor, 7 READY rows on a Mergify repo
#   D2  the stall reproduced: deadline off and a backstop timeout shorter than
#       the slow read kill the whole run, no sibling is enqueued, and the next
#       fire reports the dead run with #34 among the missing
#   D3  the killed worker's PR lock is released: the next fire on #34 enqueues it
#   D4  a detached (setsid) child of the killed worker survives the kill
#   D5  a second deadline kill on the same (PR, head) sends no second alert
#   R1  READY held by the block gate: `READY held:block-gate`, note fresh each tick
#   R2  READY held by the budget on tick N, enqueued on tick N+1
#   R3  a READY row the worker left with no note is `READY unexplained`, loudly, once
#   R4  a PR whose lock another worker holds is `READY held:worker-locked`
#   K1  the knob: garbage reads as the default; the backstop caps every worker at
#       its timeout minus 45s (floor 30s), even one whose own knob is 0
#   G1  no GitHub write verb beyond the enqueue posts across the suite
#
# Run from anywhere: tests/merge-path-stall.bh-4918-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }
NOW=$(date +%s)
SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
PRS="31 32 33 34 35 36 37"
hd() { printf '%02d%038d' "$1" 0; }

# ---- the scratch harness: the REAL backstop and conductor, gh/curl stubbed ----
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
for s in bin/merge-conductor-backstop.sh bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
# gh-limit-logger.sh wraps gh in a function that calls `command gh`, which would
# step around tests/lib/gh-list-bridge.sh; the conductor sources it optionally.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
# Two fixture seams, appended to the scratch copies (never the repo's):
#   $T/block-<n>   bg_scan answers a standing non-CI BLOCK on #n (R1, #4184's shape)
#   $T/silent-<n>  #n's worker leaves at its first step and writes no note (R3):
#                  an `exit 0` from the per-PR heartbeat call, inside the worker
cat >> "$T/h/bin/lib/block-gate.sh" <<EOF

eval "_fx_bg_scan_real() \$(declare -f bg_scan | tail -n +2)"
bg_scan() {
  if [ -e "$T/block-\$2" ]; then
    printf '%s\t%s\t%s\t%s\n' "https://github.com/\$1/pull/\$2#issuecomment-777" the-lead 2026-10-06T00:00:00Z 777; return 1
  fi
  _fx_bg_scan_real "\$@"
}
EOF
cat >> "$T/h/bin/lib/heartbeat.sh" <<EOF

eval "_fx_hb_tick_real() \$(declare -f hb_tick | tail -n +2)"
hb_tick() { case "\${2:-}" in "pr "*) [ -e "$T/silent-\${2#pr }" ] && exit 0 ;; esac; _fx_hb_tick_real "\$@"; }
EOF
# The lead authority the enqueue asks (R2) reads its protected paths.
# TEST-CHANGE BH-4148 (merge of main): globs come from the DB, not the TSV.
# The lead_protected_paths rows (tests/lib/lpp-stub.sh): example-org/demo has none,
# so it is not governed, as it was not in the deleted TSV.
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
for n in $PRS; do
  REC="$T/h/builds/pool-demo-DM-$n-202610060001"; mkdir -p "$REC"
  echo "PR_CREATED $U/$n" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  hd "$n" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# list.json — the open list; `only <n>...` narrows it.
list() { local n first=1 ns=("$@"); [ "$#" -gt 0 ] || read -ra ns <<<"$PRS"; printf '['
  for n in "${ns[@]}"; do [ "$first" = 1 ] || printf ','; first=0
    printf '{"number":%s,"url":"%s/%s","headRefOid":"%s","headRefName":"ticket/dm-%s","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}' \
      "$n" "$U" "$n" "$(hd "$n")" "$n"
  done; printf ']\n'; }
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The gh stub. Every call is logged; the PR number is read off the path. A
# file $T/slow-<n> makes every per-PR read of #n sleep 60 s, or the number of
# seconds the file holds (the slow PR); a label POST marks the PR `queued` for
# the Mergify witness ($T/queued-<n>); and
# $T/detach-<n> makes that read first start a detached `setsid sleep 30` whose
# pid lands in $T/detached.pid (D4).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
if [ -n "\$N" ] && [ -e "$T/slow-\$N" ] && [ "\${HPL_READ_ROLE:-}" != list-lazy ]; then
  if [ -e "$T/detach-\$N" ]; then rm -f "$T/detach-\$N"; setsid sleep 30 >/dev/null 2>&1 < /dev/null & echo \$! > "$T/detached.pid"; fi
  echo "\$N" >> "$T/slow-hit.txt"; Z=\$(cat "$T/slow-\$N" 2>/dev/null); sleep "\${Z:-60}"
fi
HEADN=\$(printf '%02d%038d' "\${N:-0}" 0)
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments -f body=@mergifyio queue"*)
    printf '%s\n' "\$A" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"api -X POST repos/$SLUG/issues/"*"/labels -f labels[]=merge-queue"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; : > "$T/queued-\$N" ;;
  *"api -X POST repos/"*"/issues/"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"pr merge"*|*"/pulls/"*"/merge"*) printf '%s\n' "\$A" >> "$T/c-writes.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$A" >> "$T/c-comments.txt"; restpr --raw 201 '{"id":1}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*) printf '%s\n' "\$A" >> "$T/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"api repos/"*"/issues/"*"/comments"*) : ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) LB=""; [ -e "$T/queued-\$N" ] && LB=merge-queue,queued
    restpr OPEN "\$HEADN" "ticket/dm-\$N" main "\$LB" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL NOBODY)
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"the-lead"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# The timeout seam (D2). The backstop starts every keyed run as
# `timeout <TO> merge-conductor.sh`. A file $T/to-<n> holds a SHORTER timeout
# for #n's run only, so D2 can kill the slow run by `timeout` while its
# siblings keep the fire's own, longer one. Any other `timeout` call passes
# through unchanged.
REAL_TIMEOUT=$(command -v timeout) || { echo "timeout missing"; exit 1; }
cat > "$T/fakebin/timeout" <<EOF
#!/bin/bash
N="\${MC_ONLY_PR##*#}"
case "\${2:-}" in
  */merge-conductor.sh) [ -n "\$N" ] && [ -s "$T/to-\$N" ] && { shift; set -- "\$(cat "$T/to-\$N")" "\$@"; } ;;
esac
exec "$REAL_TIMEOUT" "\$@"
EOF
chmod +x "$T/fakebin/timeout"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge" "$T/h/flags/conductor-owns-merges"
CLOG="$T/h/logs/merge-conductor.log"
ROWS="$T/h/state/merge-conductor/pr-state.tsv"
# rows <n>... — those PRs READY, approved on their head.
rows() { local n; : > "$ROWS"; for n in "$@"; do
  printf '%s\tREADY\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#$n" $((NOW-600)) "$(hd "$n")" "$(hd "$n")" "$U" "$n" >> "$ROWS"; done; }
reset_calls() { : > "$T/c-posts.txt"; : > "$T/c-calls.txt"; : > "$T/c-alerts.txt"; touch "$T/c-writes.txt" "$T/c-comments.txt"; }
# bs [env...] — one backstop fire in its own session; output in $T/bs.out.
# MC_BACKSTOP_MAX_KEYS=0: every case here is about ONE run over all its rows (7
# in D1/D2), and the default cap is 6 since BH-4842.
# TEST-CHANGE (BH-6000): the backstop now starts one DETACHED run per
# candidate and returns at once; bs then waits for every run to end (each holds
# its locks/mc-backstop-<key>.lock for its whole life), so the cases below read
# finished runs exactly as before.
# TEST-CHANGE (BH-7376): a keyed run raises its PR worker to MC_KEYED_READY_ARM_S
# (default 490 s) and the backstop's timeout to that + 45 s. This suite's small
# deadlines and timeouts stand in for the real ones, so it pins the knob to 1
# (no floor in effect); tests/merge-conductor-keyed-timeout-test.sh pins the floor.
# It also sets MC_BACKSTOP_MAX_RUNNING=0 (BH-7376 count cap off): K13 there pins the cap.
bs() { ( cd "$T" && setsid -w env -u MC_ONLY_PR PATH="$T/fakebin:$PATH" HARNESS="$T/h" MC_KEYED_READY_ARM_S=1 MC_BACKSTOP_MAX_RUNNING=0 HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
  MC_BACKSTOP_MAX_KEYS=0 MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0 "$@" \
  bash "$T/h/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 ) 2>/dev/null
  local lk; for lk in "$T/h/locks"/mc-backstop-*.lock; do [ -e "$lk" ] && flock -w 300 "$lk" true 2>/dev/null; done; sleep 0.5; }
posted() { grep -c "issues/$1/comments -f body=@mergifyio queue" "$T/c-posts.txt" 2>/dev/null || true; }
since() { tail -n +"$(( ${1:-0} + 1 ))" "$CLOG" 2>/dev/null; }
loglen() { if [ -f "$CLOG" ]; then wc -l < "$CLOG"; else echo 0; fi; }

# ============================================================================
# D2 — red-first proof: with the deadline off and the backstop's timeout
# shorter than the slow read, the stall reproduces. The group kill takes the
# whole tick: no sibling is enqueued, and the next fire's fan-in names the
# dead run.
# ============================================================================
list > "$T/list.json"; rows $PRS; reset_calls
# TEST-CHANGE (lead review lr-6015 of 9fc9454d1): one fire-wide 10 s timeout
# also killed the six siblings on a box where 7 concurrent runs take ~27 s
# each (49/2 there), so D2 depended on box speed. Now the fire's timeout is
# 150 s (its worker cap 105 s), far above a concurrent run's length, and only
# #34's run gets a 50 s timeout (the $T/to-34 seam), with its read slower than
# that (300 s). 50 s is above the time a run needs to reach the read, and
# below #34's worker cap (105 s), so `timeout` kills #34's run, not its
# deadline. The same facts are asserted: #34's run hit timeout and never
# reached fan-in, the six siblings are enqueued, the next fire names #34.
echo 300 > "$T/slow-34"; echo 50 > "$T/to-34"
bs MC_WORKER_DEADLINE_S=0 MC_BACKSTOP_TIMEOUT_S=150
rm -f "$T/to-34"
grep -q "$SLUG#34: keyed conductor run hit timeout" "$T/bs.out" && ok || bad "D2 setup: #34's keyed run is killed by its timeout (bs: $(cat "$T/bs.out"))"
grep -qx 34 "$T/slow-hit.txt" 2>/dev/null && ok || bad "D2 setup: #34's run reached the slow read before the kill (slow-hit: $(cat "$T/slow-hit.txt" 2>/dev/null))"
[ "$(grep -c 'keyed conductor run rc=0' "$T/bs.out")" = 6 ] && ok || bad "D2 setup: the six sibling runs end rc=0, none hit a timeout (bs: $(cat "$T/bs.out"))"
N2=0; for n in 31 32 33 35 36 37; do N2=$((N2 + $(posted "$n"))); done
# TEST-CHANGE (BH-6000): this was the red-first proof of the stall, "the group
# kill takes the healthy siblings' enqueue with it (posted 0)". With one keyed
# run per PR the stall cannot happen: the timeout kills #34's run alone, and
# the six siblings, each in its own run, are enqueued even with the deadline
# off. So the case now asserts the fix: posted 6.
[ "$N2" = 6 ] && ok || bad "D2 with one run per PR the timeout kills #34's run alone, and the six siblings are enqueued (posted $N2)"
rm -f "$T/slow-34"; : > "$T/c-alerts.txt"
rows 31; bs MC_WORKER_DEADLINE_S=0
DA=$(grep -F 'run died before fan-in' "$T/c-alerts.txt")
grep -q "missing: .*$SLUG#34" <<<"$DA" && ok || bad "D2 the next fire reports the dead run, #34 among the missing (alerts: $(cat "$T/c-alerts.txt"))"
# A clean slate for the cases below: no attempt, ask or row survives D2.
scratch_rm "$T/h/state"; mkdir -p "$T/h/state/merge-conductor"; : > "$CLOG"

# ============================================================================
# D1 — one slow worker, six enqueue (Acceptance 1).
# ============================================================================
list > "$T/list.json"; rows $PRS; reset_calls
echo 60 > "$T/slow-34"; touch "$T/detach-34"
M0=$(loglen); S0=$(date +%s)   # determinism: ok elapsed-time bound, not a date assertion
bs MC_WORKER_DEADLINE_S=15 MC_BACKSTOP_TIMEOUT_S=120
D1_S=$(( $(date +%s) - S0 ))   # determinism: ok elapsed-time bound, not a date assertion
for n in 31 32 33 35 36 37; do
  [ "$(posted "$n")" = 1 ] && ok || bad "D1(a) exactly one @mergifyio queue for #$n (got $(posted "$n"); bs: $(tail -2 "$T/bs.out"); log: $(since "$M0" | grep -F "#$n" | tail -3))"
done
[ "$(posted 34)" = 0 ] && ok || bad "D1(a) no enqueue for the slow #34 (got $(posted 34))"
FL=$(since "$M0" | grep -F "FANIN merge-conductor $SLUG:")
# TEST-CHANGE (BH-6000): each PR now has its own keyed run, so the one FANIN
# line "enumerated 7 accounted 7 (...)" is seven lines, one per run, each
# "enumerated 1 accounted 1". The same facts are asserted over the seven.
[ "$(grep -c 'enumerated 1 accounted 1 (' <<<"$FL")" = 7 ] && ok || bad "D1(b) FANIN: seven runs, each enumerated 1 accounted 1 (got: ${FL:-none})"
[ "$(grep -cE 'killed:deadline( rc=[0-9]+)? 1(,|\))' <<<"$FL")" = 1 ] && ok || bad "D1(b) FANIN counts one killed:deadline (got: ${FL:-none})"
[ "$(grep -c 'READY held:budget 1' <<<"$FL")" = 6 ] && ok || bad "D1(b) the six siblings are READY held:budget (MC_MERGE_BUDGET=0; ae_project enqueues them) (got: ${FL:-none})"
! grep -q 'missing:\|run died before fan-in' <<<"$(since "$M0")" && ! grep -q 'missing:\|run died before fan-in' "$T/c-alerts.txt" \
  && ok || bad "D1(c) no missing:/run died before fan-in ($(grep 'FANIN' "$T/c-alerts.txt"))"
DL=$(grep -F "WORKER_DEADLINE $SLUG#34" "$T/c-alerts.txt")
[ "$(grep -c . <<<"$DL")" = 1 ] && grep -q 'stage: ' <<<"$DL" && grep -q -- '--severity warn merge-conductor' <<<"$DL" \
  && ok || bad "D1(d) one warn lane-alert 'WORKER_DEADLINE $SLUG#34 … stage:' (got: ${DL:-none})"
grep -q "$SLUG#34 WORKER_DEADLINE: worker killed after 15s on 34000000 at stage: " "$CLOG" \
  && ok || bad "D1(d) the log line names the PR, the deadline, the head and the stage (log: $(grep WORKER_DEADLINE "$CLOG"))"
! grep -q "WORKER_DEADLINE $SLUG#3[1235-7]" "$T/c-alerts.txt" && ok || bad "D1(d) no sibling is named by a deadline alert"
grep -q 'keyed conductor run rc=0' "$T/bs.out" && ! grep -q 'hit timeout' "$T/bs.out" \
  && ok || bad "D1(e) the backstop's run finished rc=0, not killed by its timeout (bs: $(cat "$T/bs.out"))"
[ "$D1_S" -lt 120 ] && ok || bad "D1 the fire ended before the backstop timeout (took ${D1_S}s)"
[ -z "$(find "$T/h/state/merge-conductor/worker-deadline" -type f 2>/dev/null)" ] && ok || bad "D1 the deadline marker is removed once read"

# D4 — the slow worker's detached (setsid) child survives the deadline kill.
DP=$(cat "$T/detached.pid" 2>/dev/null)
[ -n "$DP" ] && kill -0 "$DP" 2>/dev/null && ok || bad "D4 the setsid child (${DP:-no pid}) is still alive after the deadline kill"
[ -n "$DP" ] && kill "$DP" 2>/dev/null

# D5 — the same (PR, head) killed again: in the tally, but no second alert.
rows 34; : > "$T/c-alerts.txt"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=15 MC_BACKSTOP_TIMEOUT_S=120
since "$M0" | grep -F "FANIN merge-conductor $SLUG:" | grep -q 'killed:deadline' && ok || bad "D5 setup: #34 is killed again ($(since "$M0" | grep FANIN))"
! grep -q 'WORKER_DEADLINE' "$T/c-alerts.txt" && ok || bad "D5 no second WORKER_DEADLINE alert for the same head ($(cat "$T/c-alerts.txt"))"

# D3 — the killed worker held #34's PR lock; the next fire is not locked out.
rm -f "$T/slow-34"; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=15 MC_BACKSTOP_TIMEOUT_S=120
! grep -q "$SLUG#34: an earlier conductor worker still holds this PR's lock" <<<"$(since "$M0")" && ok || bad "D3 #34's lock was released by the kill ($(since "$M0" | grep -F '#34' | tail -3))"
[ "$(posted 34)" = 1 ] && ok || bad "D3 #34 is enqueued on the next fire (posts $(posted 34))"

# ============================================================================
# R — a READY row leaves every tick enqueued or held with a reason (Acceptance 2).
# ============================================================================
note() { cat "$T/h/state/merge-conductor/ready-why/example-org_demo_$1" 2>/dev/null; }
tally() { since "$1" | grep -F "FANIN merge-conductor $SLUG:" | tail -1; }
# R1 — held by a standing non-CI BLOCK on tick N, and again on tick N+1.
touch "$T/block-31"; rows 31
for tick in N N+1; do
  M0=$(loglen); T0=$(date +%s)   # determinism: ok the note's stamp is compared with this tick's own start
  bs MC_MERGE_BUDGET=5
  grep -q 'READY held:block-gate 1' <<<"$(tally "$M0")" && ok || bad "R1 tick $tick: READY held:block-gate (got: $(tally "$M0"); log: $(since "$M0" | grep -F '#31' | tail -3))"
  IFS=$'\t' read -r R1TS R1H R1K _ <<<"$(note 31)"
  [ "${R1K:-}" = block-gate ] && [ "${R1H:-}" = "$(hd 31)" ] && [ "${R1TS:-0}" -ge "$T0" ] \
    && ok || bad "R1 tick $tick: a fresh block-gate note on the head (note: $(note 31))"
  ! grep -q 'READY_UNEXPLAINED' <<<"$(since "$M0")" && ok || bad "R1 tick $tick: never unexplained"
done
rm -f "$T/block-31"
# R2 — held by the merge budget on tick N, enqueued on tick N+1.
rows 32; M0=$(loglen)
bs MC_MERGE_BUDGET=0
grep -q 'READY held:budget 1' <<<"$(tally "$M0")" && ok || bad "R2 tick N: READY held:budget (got: $(tally "$M0"))"
LB0=$(grep -c 'issues/32/labels' "$T/c-writes.txt" || true)
M0=$(loglen); bs MC_MERGE_BUDGET=5
grep -q 'QUEUED 1' <<<"$(tally "$M0")" && ok || bad "R2 tick N+1: the row is QUEUED (got: $(tally "$M0"); log: $(since "$M0" | grep -F '#32' | tail -3))"
[ "$(( $(grep -c 'issues/32/labels' "$T/c-writes.txt" || true) - LB0 ))" = 1 ] && ok || bad "R2 tick N+1: one enqueue (label POST) for #32"
[ "$(grep -F "$SLUG#32"$'\t' "$ROWS" | cut -f2)" = QUEUED ] && ok || bad "R2 the pr-state row is QUEUED ($(grep -F "$SLUG#32" "$ROWS"))"
# R3 — a worker that leaves READY with no enqueue and no note is loud, once.
touch "$T/silent-33"; rows 33; : > "$T/c-alerts.txt"
for tick in N N+1; do
  M0=$(loglen); bs MC_MERGE_BUDGET=5
  grep -q 'READY unexplained 1' <<<"$(tally "$M0")" && ok || bad "R3 tick $tick: READY unexplained (got: $(tally "$M0"))"
done
[ "$(grep -c "$SLUG#33 READY_UNEXPLAINED on 33000000: the worker left the row READY with no enqueue and no recorded hold this tick" "$CLOG")" = 1 ] \
  && ok || bad "R3 one READY_UNEXPLAINED log line over two ticks ($(grep -c READY_UNEXPLAINED "$CLOG"))"
[ "$(grep -c "READY_UNEXPLAINED $SLUG#33" "$T/c-alerts.txt")" = 1 ] && grep -q -- '--severity warn merge-conductor' "$T/c-alerts.txt" \
  && ok || bad "R3 one warn lane-alert over two ticks ($(cat "$T/c-alerts.txt"))"
rm -f "$T/silent-33"
# R4 — a PR whose lock an earlier worker still holds is held, with that reason.
rows 35; M0=$(loglen)
LK="$T/h/locks/merge-conductor-demo-35.lock"
( exec 9>"$LK"; flock 9; : > "$T/lk-held"; sleep 60 ) & LKP=$!
for _ in $(seq 50); do [ -e "$T/lk-held" ] && break; sleep 0.1; done
bs MC_MERGE_BUDGET=5
kill "$LKP" 2>/dev/null; wait "$LKP" 2>/dev/null
since "$M0" | grep -q "$SLUG#35: an earlier conductor worker still holds this PR's lock" && ok || bad "R4 setup: #35's lock was held"
grep -q 'READY held:worker-locked 1' <<<"$(tally "$M0")" && ok || bad "R4 READY held:worker-locked (got: $(tally "$M0"))"

# ============================================================================
# K1 — the knob, and the cap the backstop hands its keyed run.
# ============================================================================
echo 5 > "$T/slow-36"; rows 36; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=abc MC_BACKSTOP_TIMEOUT_S=120
! grep -q 'killed:deadline' <<<"$(tally "$M0")" && ok || bad "K1 MC_WORKER_DEADLINE_S=abc reads as 180: a 5s read is not killed (got: $(tally "$M0"))"
grep -q 'worker deadline capped at 75s under timeout 120s' "$T/bs.out" && ok || bad "K1 timeout 120 caps the worker deadline at 75s (bs: $(cat "$T/bs.out"))"
rm -f "$T/slow-36"
bs MC_BACKSTOP_TIMEOUT_S=240
grep -q 'worker deadline capped at 195s under timeout 240s' "$T/bs.out" && ok || bad "K1 timeout 240 caps at 195s (bs: $(cat "$T/bs.out"))"
bs MC_BACKSTOP_TIMEOUT_S=60
grep -q 'worker deadline capped at 30s under timeout 60s' "$T/bs.out" && ok || bad "K1 timeout 60 floors the cap at 30s (bs: $(cat "$T/bs.out"))"
bs MC_BACKSTOP_TIMEOUT_S=junk
grep -q 'worker deadline capped at 195s under timeout 240s' "$T/bs.out" && ok || bad "K1 a junk timeout reads as 240 (bs: $(cat "$T/bs.out"))"
# The backstop's cap binds a conductor whose own knob is off (a settings row of
# 0 cannot put the group timeout back in charge).
echo 90 > "$T/slow-37"; rows 37; M0=$(loglen)
bs MC_WORKER_DEADLINE_S=0 MC_BACKSTOP_TIMEOUT_S=60
tally "$M0" | grep -q 'killed:deadline' && ok || bad "K1 the backstop's 30s cap bounds a worker whose knob is 0 (got: $(tally "$M0"))"
# Since BH-4842 the cap is what is left of the run's 30 s worker window when
# the worker starts (mc_window_cap), so the run's own start-up (a second or
# two in this fixture) comes off it: 30 s at most, never under 25 s here.
grep -Eq "$SLUG#37 WORKER_DEADLINE: worker killed after (2[5-9]|30)s" "$CLOG" && ok || bad "K1 the kill names the 30s cap, less the run's start-up ($(grep -F '#37 WORKER_DEADLINE' "$CLOG"))"
grep -q 'keyed conductor run rc=0' "$T/bs.out" && ok || bad "K1 the capped run ends before its 60s timeout (bs: $(cat "$T/bs.out"))"
rm -f "$T/slow-37"

# ============================================================================
# G1 — across the whole suite GitHub saw no write beyond the enqueue posts, the
# merge-queue label and the block gate's refusal comment: no merge, no close, no
# label removal.
# ============================================================================
BADW=$(grep -vE "^api -X POST repos/$SLUG/issues/3[1-7]/(labels -f labels\[\]=merge-queue|comments -f body=@mergifyio queue)$" "$T/c-writes.txt" | grep -v '/statuses/' || true)
[ -z "$BADW" ] && ok || bad "G1 an unexpected GitHub write: $BADW"
BADC=$(grep -v "issues/31/comments" "$T/c-comments.txt" || true)
[ -z "$BADC" ] && ok || bad "G1 a comment outside R1's block refusal: $BADC"

[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
echo "merge-path-stall.bh-4918: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
