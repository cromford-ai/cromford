#!/bin/bash
# tests/prequeue-reuse.bh-5572-test.sh — BH-5572: the pre-queue gate reuses a
# fresh green verdict when main moves, and dispatches nothing for a head the
# conductor will refuse this tick anyway.
#
# THE DEFECT THIS PINS. bin/lib/mc-prequeue.d/dispatch.sh pq_resolve aged a
# sibling verdict (same PR and head, older main) by its DISPATCH time. A run is
# read back one or two ticks (12-19 min each) after its dispatch, so a green
# verdict was often older than MC_PREQUEUE_FRESH_S the moment it was known,
# and every main move dispatched prequeue-gate.yml again (#4034: 14:29, 15:11,
# 15:46Z, never enqueued). It also dispatched for heads with a standing BLOCK.
#
#   R1  green on main A, read 10 min ago (dispatched 40 min ago), head merges
#       clean into main B: enqueued, no dispatch, one `PREQUEUE reuse` line
#   R2  the same green read 33 min ago: one dispatch for B, held
#   R3  green, but the head conflicts with B: NEEDS_REBASE, no dispatch
#   R4  red on A: parked on B, and still parked on a third main
#   R5  a standing BLOCK: no dispatch, the block gate still refuses
#   R5b an unreadable BLOCK read, or BLOCK_GATE_ENFORCE=0: dispatch as before
#   R6  MC_PREQUEUE_REUSE=0: the dispatch-age rule, no reuse line, no veto
#   R7  the merge test cannot answer: the dispatch-age rule decides
#   R8  the veto saw a BLOCK the block gate no longer sees: held, not enqueued
#   R9  a lead PR the lead fence holds: no dispatch
#
# Driven, not grepped: every case runs bin/merge-conductor.sh WHOLE in a
# scratch tree with the real tracer, the real dispatch.sh and the real
# mc_merge_tree against a real local git origin. Assertions read the sinks.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-reuse.bh-5572-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v git   >/dev/null || { echo "git missing — skipping";   exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
[ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.sh" ] && [ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/dispatch.sh bin/lib/mc-prequeue.sh bin/merge-conductor.sh

NOW=$(date +%s)
SLUG=example-org/demo-os
U="https://github.com/$SLUG/pull"
NUM=41

# ── a real origin that never leaves this box ─────────────────────────────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$T/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$T/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
# main A; main B = A + one line changed in x.txt; HOK = A + y.txt (merges clean
# into B); HCONF = A + the same x.txt line changed differently (conflicts with B).
S="$T/seed"; git init -q --bare "$T/origin.git"; git init -q "$S"
printf 'one\ntwo\n' > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm A; MA=$(git -C "$S" rev-parse HEAD)
echo y > "$S/y.txt"; git -C "$S" add -A; git -C "$S" commit -qm hok; HOK=$(git -C "$S" rev-parse HEAD)
git -C "$S" reset -q --hard "$MA"; printf 'one\nhead\n' > "$S/x.txt"; git -C "$S" commit -qam hconf; HCONF=$(git -C "$S" rev-parse HEAD)
git -C "$S" reset -q --hard "$MA"; printf 'one\nmain\n' > "$S/x.txt"; git -C "$S" commit -qam B; MB=$(git -C "$S" rev-parse HEAD)
git -C "$S" push -q "$T/origin.git" "$MB:refs/heads/main" "$HOK:refs/pull/41/head" "$HCONF:refs/pull/42/head" || exit 1
MC3=$(printf 'e%.0s' $(seq 40))   # a third main tip for R4 (never fetched)

# ── the scratch harness: the conductor's whole closure, two libs stubbed ─────
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
# The lead fence: never held at the READY arm's own fence; the pure read the
# veto asks (to_lead_merge_hold) is held while $T/lead-held exists.
cat > "$T/h/bin/lib/ticket-ownership.sh" <<EOF
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { echo "\$*" >> "$T/lead-calls"; [ -e "$T/lead-held" ] && { printf 'held\tlead PR\n'; return 0; }; return 1; }
EOF
# The block gate: each read is one line in $T/bg-calls; its answer is $T/bg.rc,
# or the next line of $T/bg.seq while that file has lines left.
cat > "$T/h/bin/lib/block-gate.sh" <<EOF
bg_enforce() { [ "\${BLOCK_GATE_ENFORCE:-1}" = 1 ]; }
_bg_rc() {
  local n rc
  if [ -s "$T/bg.seq" ]; then n=\$(wc -l < "$T/bg-calls"); rc=\$(sed -n "\${n}p" "$T/bg.seq"); fi
  [ -n "\${rc:-}" ] || rc=\$(cat "$T/bg.rc" 2>/dev/null || echo 0)
  echo "\$rc"
}
bg_scan_read() {
  echo "read \$*" >> "$T/bg-calls"; local rc; rc=\$(_bg_rc)
  [ "\$rc" = 1 ] && printf 'https://x/c1\toperator\t2026-10-08T00:00:00Z\t1'
  [ "\$rc" = 2 ] && printf 'comments'
  return "\$rc"
}
bg_scan() { bg_scan_read "\$@"; }
bg_why() { echo "BLOCK by operator"; }
bg_reason() { echo "BLOCK by operator"; }
bg_refuse() { echo "\$*" >> "$T/bg-refuse"; return 0; }
EOF
# The open list comes from the stub's `gh pr list` (tests/lib/gh-list-bridge.sh),
# not the shared PR snapshot: an empty pr-snapshot.sh keeps HPL_SNAPSHOT unset.
: > "$T/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
# gh-limit-logger.sh wraps gh in a function that calls `command gh`, which would
# step around tests/lib/gh-list-bridge.sh; the conductor sources it optionally.
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
MCD="$T/h/state/merge-conductor"

# The stub gh: main is $T/main, the PR head is $T/head, the dispatch argv goes
# to $T/dispatch.txt. Writes that enqueue go to $T/c-enq.txt.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=$NUM; HD=\$(cat "$T/head"); MN=\$(cat "$T/main")
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*) printf '%s\n' "\$*" >> "$T/dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*) restpr --raw 200 '{"workflow_runs":[]}' ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 "{\"sha\":\"\$MN\"}" ;;
  # TEST-CHANGE (BH-6335): reusing an older main's verdict now reads how far
  # main moved (pq_main_behind). Main B is main A plus one commit.
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/\$N/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*) restpr OPEN "\$HD" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":%s,"url":"$U/%s","headRefOid":"%s","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]\n' "\$N" "\$N" "\$HD" ;;
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
ROWS="$MCD/pr-state.tsv"
PQD="$MCD/prequeue"
# reset <head> <main> — #41 approved and green at <head>, a fresh state, no
# dispatches, no BLOCK. KEEP=1 keeps the verdict store.
reset() {
  if [ "${KEEP:-0}" = 1 ]; then rm -rf "$T/keep"; mkdir -p "$T/keep"; cp -a "$PQD" "$T/keep/pq" 2>/dev/null; fi
  rm -f "$T/tick.err" "$T/bg.rc" "$T/bg.seq" "$T/lead-held" "$T/lead-calls" "$T/bg-refuse"
  : > "$T/c-enq.txt"; : > "$T/dispatch.txt"; : > "$T/bg-calls"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"; scratch_rm "$T/h/tmp/conductor"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  [ "${KEEP:-0}" = 1 ] && [ -d "$T/keep/pq" ] && cp -a "$T/keep/pq" "$PQD"
  echo "$1" > "$T/head"; echo "$2" > "$T/main"
  echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$T/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# seed <main> <state> <dispatched_age_s> <settled_age_s> [suites] — one cache
# entry for (#41, current head) through the tracer's writer; its mtime is when
# the conductor read the verdict.
seed() {
  local f
  f=$( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    f=$(pq_key "$SLUG" "$NUM" "$(cat "$T/head")" "$1")
    pq_cache_put "$f" "$2" "$((NOW - $3))" - "${5:-}" && printf '%s' "$f" ) || { bad "fixture: pq_cache_put failed for $*"; return 1; }
  touch -d "@$((NOW - $4))" "$f"
}
K() { printf '%s#%s' "$SLUG" "$NUM"; }
state()  { awk -F'\t' -v k="$(K)" '$1==k {print $2}' "$ROWS"; }
reason() { awk -F'\t' -v k="$(K)" '$1==k {print $7}' "$ROWS"; }
enq()    { grep -c "issues/$NUM/comments\|issues/$NUM/labels\|pulls/$NUM/merge\|pr merge $U/$NUM" "$T/c-enq.txt" 2>/dev/null || true; }
ndisp()  { grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null || true; }
why()    { cat "$MCD/ready-why/"* 2>/dev/null; }
whykind() { why | awk -F'\t' -v h="$(cat "$T/head")" '$2==h {print $3}' | tail -1; }
clog()   { grep -F "$(K)" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }
reuse_lines() { grep -c 'PREQUEUE reuse #' "$MCLOG" 2>/dev/null || true; }
not_enqueued() { [ "$(enq)" = 0 ] && ok || bad "$1: nothing enqueued (argv: $(cat "$T/c-enq.txt"))"; }
enqueued() {
  [ "$(enq)" -ge 1 ] && ok || bad "$1: the head must be enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state)'; why '$(why)'; log: $(clog))"
  [ "$(state)" != BLOCKED_HUMAN ] && ok || bad "$1: the row must not be parked (reason '$(reason)')"
}

# ============================================================================
# R1. Green on main A, dispatched 40 min ago, read 10 min ago; main is now B and
# the head merges clean into it: reused, enqueued, nothing dispatched.
# ============================================================================
reset "$HOK" "$MB"; seed "$MA" green 2400 600; tick
enqueued R1
[ "$(ndisp)" = 0 ] && ok || bad "R1: no dispatch for a fresh green on an older main (got $(cat "$T/dispatch.txt"))"
grep -qE "PREQUEUE reuse #41 head=${HOK:0:12} verdict-main=${MA:0:12} current-main=${MB:0:12} age=6[0-9][0-9]s verdict=green -> proceed" "$MCLOG" 2>/dev/null \
  && ok || bad "R1: one reuse line naming the head, both mains, the age and the outcome (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"
[ "$(reuse_lines)" = 1 ] && ok || bad "R1: exactly one reuse line (got $(reuse_lines))"

# ============================================================================
# R2. The same green, read 33 min ago: past FRESH_S, one dispatch for B, held.
# ============================================================================
reset "$HOK" "$MB"; seed "$MA" green 2400 2000; tick
[ "$(ndisp)" = 1 ] && grep -q -- "-f main=$MB" "$T/dispatch.txt" && ok || bad "R2: one dispatch for main B (got $(cat "$T/dispatch.txt"))"
not_enqueued R2
[ "$(state)" = READY ] && ok || bad "R2: the row stays READY (state '$(state)')"
[ "$(whykind)" = prequeue-pending ] && ok || bad "R2: ready-why prequeue-pending (note: $(why))"
grep -q 'PREQUEUE reuse .*-> proceed' "$MCLOG" 2>/dev/null && bad "R2: no proceed reuse line for a stale verdict" || ok

# ============================================================================
# R3. Green, but the head conflicts with main B: NEEDS_REBASE, no dispatch.
# ============================================================================
reset "$HCONF" "$MB"; seed "$MA" green 2400 600; tick
not_enqueued R3
[ "$(ndisp)" = 0 ] && ok || bad "R3: no dispatch (got $(cat "$T/dispatch.txt"))"
[ "$(state)" = NEEDS_REBASE ] && ok || bad "R3: the row goes to NEEDS_REBASE (state '$(state)', reason '$(reason)'; log: $(clog))"
case "$(reason)" in "prequeue reuse: head"*) ok ;; *) bad "R3: the reason starts 'prequeue reuse: head' (got '$(reason)')" ;; esac
grep -qE "PREQUEUE reuse #41 head=${HCONF:0:12} .* -> rebase" "$MCLOG" 2>/dev/null && ok || bad "R3: the reuse line ends '-> rebase' (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"

# ============================================================================
# R4. Red on main A: parked on B; then main moves again and it stays parked.
# ============================================================================
reset "$HOK" "$MB"; seed "$MA" red 2400 600 tests/a.sh; tick
[ "$(state)" = BLOCKED_HUMAN ] && ok || bad "R4: parked (state '$(state)')"
case "$(reason)" in "prequeue-red: tests/a.sh on main ${MA:0:12}"*) ok ;; *) bad "R4: the reason names the suite and main A (got '$(reason)')" ;; esac
[ "$(ndisp)" = 0 ] && ok || bad "R4: no dispatch (got $(ndisp))"
not_enqueued R4
KEEP=1 reset "$HOK" "$MC3"; tick
[ "$(state)" = BLOCKED_HUMAN ] && ok || bad "R4 third main: still parked (state '$(state)')"
[ "$(ndisp)" = 0 ] && ok || bad "R4 third main: no dispatch (got $(ndisp))"
not_enqueued "R4 third main"

# ============================================================================
# R5. A standing BLOCK on the head: no dispatch, and the block gate still runs.
# ============================================================================
reset "$HOK" "$MB"; echo 1 > "$T/bg.rc"; tick
[ "$(ndisp)" = 0 ] && ok || bad "R5: no dispatch for a head with a standing BLOCK (got $(cat "$T/dispatch.txt"))"
not_enqueued R5
[ "$(state)" = READY ] && ok || bad "R5: the row stays READY (state '$(state)')"
[ "$(whykind)" = block-gate ] && ok || bad "R5: the block gate arm refused it (ready-why: $(why))"
[ "$(grep -c . "$T/bg-refuse" 2>/dev/null || echo 0)" = 1 ] && ok || bad "R5: one refusal comment (got $(cat "$T/bg-refuse" 2>/dev/null))"
grep -qF "PREQUEUE skip-dispatch #41 head=${HOK:0:12} current-main=${MB:0:12} reason=standing BLOCK on the thread" "$MCLOG" 2>/dev/null \
  && ok || bad "R5: the skip-dispatch line (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"
[ -e "$PQD/example-org_demo-os_41_${HOK}_$MB" ] && bad "R5: nothing is written to the store ($(cat "$PQD/example-org_demo-os_41_${HOK}_$MB"))" || ok

# R5b. Fail open: an unreadable BLOCK read is no veto, and neither is warn-only.
reset "$HOK" "$MB"; echo 2 > "$T/bg.rc"; tick
[ "$(ndisp)" = 1 ] && ok || bad "R5b: an unreadable BLOCK read dispatches as before (got $(ndisp))"
reset "$HOK" "$MB"; echo 1 > "$T/bg.rc"; tick BLOCK_GATE_ENFORCE=0
[ "$(ndisp)" = 1 ] && ok || bad "R5b: BLOCK_GATE_ENFORCE=0 dispatches as before (got $(ndisp))"

# ============================================================================
# R6. MC_PREQUEUE_REUSE=0: today's gate exactly.
# ============================================================================
reset "$HOK" "$MB"; seed "$MA" green 2400 600; tick MC_PREQUEUE_REUSE=0
[ "$(ndisp)" = 1 ] && ok || bad "R6: siblings age from dispatch time, so it dispatches (got $(ndisp))"
not_enqueued R6
[ "$(reuse_lines)" = 0 ] && ok || bad "R6: no reuse line (got $(grep PREQUEUE "$MCLOG"))"
reset "$HOK" "$MB"; echo 1 > "$T/bg.rc"; tick MC_PREQUEUE_REUSE=0
[ "$(ndisp)" = 1 ] && ok || bad "R6: a blocked head is dispatched as before (got $(ndisp))"
grep -q 'PREQUEUE skip-dispatch' "$MCLOG" 2>/dev/null && bad "R6: no skip-dispatch line" || ok

# ============================================================================
# R7. The merge test cannot answer: the dispatch-age rule decides.
# ============================================================================
reset "$HOK" "$MB"; seed "$MA" green 2400 600; tick MC_MERGE_TREE=0
[ "$(ndisp)" = 1 ] && ok || bad "R7: dispatched 40 min ago, no merge test: dispatch (got $(ndisp))"
not_enqueued R7
grep -qE "PREQUEUE reuse #41 .* -> merge-test-unanswered \(" "$MCLOG" 2>/dev/null && ok || bad "R7: the reuse line says merge-test-unanswered (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"
reset "$HOK" "$MB"; seed "$MA" green 600 600; tick MC_MERGE_TREE=0
enqueued "R7 dispatched 10 min ago"
[ "$(ndisp)" = 0 ] && ok || bad "R7: inside FRESH_S by dispatch time, no dispatch (got $(ndisp))"

# ============================================================================
# R8. The veto saw a BLOCK, the block gate saw none: held, not enqueued.
# ============================================================================
reset "$HOK" "$MB"; printf '1\n0\n' > "$T/bg.seq"; tick
[ "$(ndisp)" = 0 ] && ok || bad "R8: no dispatch (got $(ndisp))"
not_enqueued R8
[ "$(state)" = READY ] && ok || bad "R8: the row stays READY (state '$(state)')"
[ "$(grep -c . "$T/bg-calls")" = 2 ] && ok || bad "R8: the veto and the block gate each read once (got $(cat "$T/bg-calls"))"
[ "$(whykind)" = prequeue-pending ] && why | grep -q 'nothing refused it this tick' && ok || bad "R8: ready-why prequeue-pending, nothing refused it (note: $(why))"
grep -rqs "^ready $(K) $HOK\$" "$T/h/state" && bad "R8: no ready mark for the self-enqueue" || ok

# ============================================================================
# R9. A lead PR the lead fence holds: no dispatch.
# ============================================================================
reset "$HOK" "$MB"; touch "$T/lead-held"; echo 0 > "$T/bg.rc"; tick
[ "$(ndisp)" = 0 ] && ok || bad "R9: no dispatch for a held lead PR (got $(ndisp))"
not_enqueued R9
grep -qF "PREQUEUE skip-dispatch #41 head=${HOK:0:12} current-main=${MB:0:12} reason=lead PR waiting on a lead MERGE row" "$MCLOG" 2>/dev/null \
  && ok || bad "R9: the skip-dispatch line names the lead hold (log: $(grep PREQUEUE "$MCLOG" 2>/dev/null))"

# ============================================================================
# R0. The control: no verdict, no BLOCK: one dispatch, as before.
# ============================================================================
reset "$HOK" "$MB"; tick
[ "$(ndisp)" = 1 ] && ok || bad "R0: a clean head with no verdict is dispatched (got $(ndisp); err: $(tail -3 "$T/tick.err"))"
[ "$(whykind)" = prequeue-pending ] && ok || bad "R0: held prequeue-pending (note: $(why))"

echo "prequeue-reuse.bh-5572: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
