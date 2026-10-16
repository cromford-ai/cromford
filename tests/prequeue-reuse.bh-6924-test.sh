#!/bin/bash
# tests/prequeue-reuse.bh-6924-test.sh — BH-6924 item 1: the pre-queue gate
# reuses an older main's green verdict when the main move misses the PR's
# impact set, and dispatches again when it does not.
#
#   I1  green on main A read 40 min ago; main B changes docs/x.md only, the PR
#       changes bin/lib/a.sh: no dispatch, an entry for (head, B) with its
#       .reuse sidecar naming main A, enqueued, one impact-reuse line; a second
#       tick reads that entry as a plain hit (no compare read)
#   I2  main B changes bin/lib/a.sh, the PR's own file: one dispatch, held
#   I3  main B changes bin/lib/a2.sh, which reaches the PR's suite: one dispatch
#   I4  main B changes .github/workflows/harness-ci.yml (full): one dispatch,
#       the line says main-full
#   I5  the PR itself is full: one dispatch, the line says pr-full
#   I6  disjoint, but the head conflicts with B (a file/directory clash):
#       NEEDS_REBASE and no dispatch
#   I7  MC_PREQUEUE_IMPACT_REUSE=0: one dispatch, no impact line
#   I8  the candidate was dispatched before PQ_MIN_AT, or more than
#       MC_PREQUEUE_IMPACT_MAX_S ago: one dispatch
#   I9  a repo that is not HARNESS_REPO: one dispatch, no impact line
#   I10 the candidate is could-not-run or conflict: never reused, one dispatch
#   I11 the chain: after I1 main moves to C, disjoint from B: the B entry is
#       the candidate, the compare read is B...C, nothing is dispatched
#   I12 an unreadable compare, or a compare of 300 files: dispatch
#
# Driven, not grepped: every case runs bin/merge-conductor.sh WHOLE in a
# scratch tree with the real tracer, the real dispatch.sh and impact-reuse.sh,
# the real bin/test-impact.sh select (on a pinned map) and the real
# mc_merge_tree against a real local git origin. GitHub is a stub whose compare
# and file-list answers are computed from that origin with git.
# Run from anywhere: bash tests/prequeue-reuse.bh-6924-test.sh. The tick sets
# HARNESS_TEST_SANDBOX=1 itself: pq_ir_map honours the pinned map only under
# it, and the traced CI corpus does not set it (harness-ci.yml, #388).
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
[ -f "$DIR/bin/lib/mc-prequeue.d/impact-reuse.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/impact-reuse.sh bin/lib/mc-prequeue.d/dispatch.sh bin/merge-conductor.sh

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
S="$T/seed"; git init -q --bare "$T/origin.git"; git init -q "$S"
mkdir -p "$S/bin/lib" "$S/docs" "$S/.github/workflows"
for f in bin/lib/a.sh bin/lib/a2.sh bin/lib/b.sh docs/x.md .github/workflows/harness-ci.yml; do printf 'one\ntwo\n' > "$S/$f"; done
git -C "$S" add -A; git -C "$S" commit -qm A; MA=$(git -C "$S" rev-parse HEAD)
# commit_on <base> <msg> <path> <line2> — <base> with <path>'s second line set.
commit_on() {
  git -C "$S" checkout -q --detach "$1"; mkdir -p "$(dirname "$S/$3")"; printf 'one\n%s\n' "$4" > "$S/$3"
  git -C "$S" add -A; git -C "$S" commit -qm "$2"; git -C "$S" rev-parse HEAD
}
HA=$(commit_on "$MA" head-a bin/lib/a.sh head)                          # the PR: bin/lib/a.sh
HF=$(commit_on "$MA" head-full .github/workflows/harness-ci.yml head)   # I5: the PR is full
HDF=$(commit_on "$MA" head-df docs/new head)                            # I6: a file docs/new
MB=$(commit_on "$MA" main-docs docs/x.md main)                          # disjoint
MBA=$(commit_on "$MA" main-a bin/lib/a.sh main)                         # I2: the PR's file
MBA2=$(commit_on "$MA" main-a2 bin/lib/a2.sh main)                      # I3: the PR's suite
MBW=$(commit_on "$MA" main-wf .github/workflows/harness-ci.yml main)    # I4: full
MBDF=$(commit_on "$MA" main-df docs/new/y.md main)                      # I6: a dir docs/new
MC=$(commit_on "$MB" main-c docs/y.md main)                             # I11: B + docs/y.md

# ── the impact root and its pinned map ───────────────────────────────────────
# The real bin/test-impact.sh in a checkout ON main with a tests/ dir, the
# shape _fr_ti_root picks (MC_TI_ROOT). tests/a.sh reaches bin/lib/a.sh and
# bin/lib/a2.sh, tests/b.sh reaches bin/lib/b.sh, tests/always.sh is `*`.
TI="$T/ti"; mkdir -p "$TI/tests"
scratch_install_closure bin/test-impact.sh "$TI" >/dev/null || exit 1
chmod +x "$TI/bin/test-impact.sh"
for s in always a b; do printf '#!/bin/bash\nexit 0\n' > "$TI/tests/$s.sh"; done
git -C "$TI" init -q; git -C "$TI" add -A; git -C "$TI" commit -qm ti
printf 'tests/always.sh\t*\ntests/a.sh\tbin/lib/a.sh\ntests/a.sh\tbin/lib/a2.sh\ntests/b.sh\tbin/lib/b.sh\n' > "$T/map"

# ── the scratch harness: the conductor's whole closure, two libs stubbed ─────
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
cat > "$T/h/bin/lib/ticket-ownership.sh" <<EOF
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
cat > "$T/h/bin/lib/block-gate.sh" <<EOF
bg_enforce() { return 0; }
bg_scan_read() { return 0; }
bg_scan() { return 0; }
bg_why() { echo "BLOCK by operator"; }
bg_reason() { echo "BLOCK by operator"; }
bg_refuse() { return 0; }
EOF
: > "$T/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
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

# The compare answer for <a>...<b>, computed from the origin the way GitHub
# reports it: status, ahead_by and the changed files. $T/cmp.fail answers 404;
# $T/cmp.big answers 300 files. Each read is one line in $T/compare.txt.
cat > "$T/fakebin/compare" <<EOF
#!/bin/bash
r=\$(printf '%s' "\$*" | grep -o 'compare/[0-9a-f]*\.\.\.[0-9a-f]*' | head -1); r=\${r#compare/}
a=\${r%%...*}; b=\${r##*...}
echo "\$a...\$b" >> "$T/compare.txt"
[ -e "$T/cmp.fail" ] && { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
if [ -e "$T/cmp.big" ]; then restpr --raw 200 "\$(seq 300 | jq -R -s -c '{status:"ahead",ahead_by:1,files:[split("\n")[]|select(length>0)|{filename:("docs/f"+.+".md")}]}')"; exit 0; fi
mb=\$(git -C "$S" merge-base "\$a" "\$b" 2>/dev/null)
if [ "\$a" = "\$b" ]; then st=identical; elif [ "\$mb" = "\$a" ]; then st=ahead; elif [ "\$mb" = "\$b" ]; then st=behind; else st=diverged; fi
n=\$(git -C "$S" rev-list --count "\$a..\$b")
restpr --raw 200 "\$(git -C "$S" diff --name-only "\$a" "\$b" | jq -R -s -c --arg st "\$st" --argjson n "\$n" '{status:\$st,ahead_by:\$n,files:[split("\n")[]|select(length>0)|{filename:.}]}')"
EOF
chmod +x "$T/fakebin/compare"
# The PR's files: the head against its merge base with main, as GitHub lists them.
cat > "$T/fakebin/prfiles" <<EOF
#!/bin/bash
HD=\$(cat "$T/head"); MN=\$(cat "$T/main")
restpr --raw 200 "\$(git -C "$S" diff --name-only "\$(git -C "$S" merge-base "\$MN" "\$HD")" "\$HD" | jq -R -s -c '[split("\n")[]|select(length>0)|{filename:.}]')"
EOF
chmod +x "$T/fakebin/prfiles"
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
  *"api -i -X GET repos/$SLUG/compare/"*) compare "\$@" ;;
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
  *"api -i -X GET repos/$SLUG/pulls/\$N/files"*) prfiles ;;
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
# reset <head> <main> — #41 approved and green at <head>, origin's main at
# <main>, a fresh state, no dispatches. KEEP=1 keeps the verdict store.
reset() {
  if [ "${KEEP:-0}" = 1 ]; then rm -rf "$T/keep"; mkdir -p "$T/keep"; cp -a "$PQD" "$T/keep/pq" 2>/dev/null; fi
  rm -f "$T/tick.err" "$T/cmp.fail" "$T/cmp.big"
  : > "$T/c-enq.txt"; : > "$T/dispatch.txt"; : > "$T/compare.txt"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"; scratch_rm "$T/h/tmp/conductor"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  [ "${KEEP:-0}" = 1 ] && [ -d "$T/keep/pq" ] && cp -a "$T/keep/pq" "$PQD"
  git -C "$S" push -q -f "$T/origin.git" "$2:refs/heads/main" "$1:refs/pull/$NUM/head" || bad "fixture: push failed"
  echo "$1" > "$T/head"; echo "$2" > "$T/main"
  echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$T/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 \
    HARNESS_REPO="$SLUG" MC_TI_ROOT="$TI" HARNESS_TEST_SANDBOX=1 MC_PREQUEUE_IMPACT_MAP="$T/map" "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# seed <main> <state> <dispatched_age_s> <read_age_s> [suites] — one cache entry for
# (#41, current head), run 777, through the tracer's writer; mtime = read time.
seed() {
  local f
  f=$( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    f=$(pq_key "$SLUG" "$NUM" "$(cat "$T/head")" "$1")
    pq_cache_put "$f" "$2" "$((NOW - $3))" 777 "${5:-}" && printf '%s' "$f" ) || { bad "fixture: pq_cache_put failed for $*"; return 1; }
  touch -d "@$((NOW - $4))" "$f"
}
K() { printf '%s#%s' "$SLUG" "$NUM"; }
state()  { awk -F'\t' -v k="$(K)" '$1==k {print $2}' "$ROWS"; }
reason() { awk -F'\t' -v k="$(K)" '$1==k {print $7}' "$ROWS"; }
enq()    { grep -c "issues/$NUM/comments\|issues/$NUM/labels\|pulls/$NUM/merge\|pr merge $U/$NUM" "$T/c-enq.txt" 2>/dev/null || true; }
ndisp()  { grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null || true; }
pqlog()  { grep PREQUEUE "$MCLOG" 2>/dev/null; }
impact_lines() { grep -c 'PREQUEUE reuse #41 .* -> impact-' "$MCLOG" 2>/dev/null || true; }
entry()  { cat "$PQD/example-org_demo-os_41_$(cat "$T/head")_$1" 2>/dev/null; }
not_enqueued() { [ "$(enq)" = 0 ] && ok || bad "$1: nothing enqueued (argv: $(cat "$T/c-enq.txt"))"; }
enqueued() { [ "$(enq)" -ge 1 ] && ok || bad "$1: the head must be enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state)'; log: $(pqlog); err: $(tail -3 "$T/tick.err"))"; }
one_dispatch() {   # <case> <main>
  [ "$(ndisp)" = 1 ] && grep -q -- "-f main=$2" "$T/dispatch.txt" && ok || bad "$1: one dispatch for main ${2:0:12} (got $(cat "$T/dispatch.txt"); log: $(pqlog))"
  not_enqueued "$1"
  [ "$(state)" = READY ] && ok || bad "$1: the row stays READY (state '$(state)')"
  [ -e "$PQD/example-org_demo-os_41_$(cat "$T/head")_$2.reuse" ] && bad "$1: no .reuse sidecar" || ok
}

# ============================================================================
# I1. Green on main A, read 40 min ago (outside FRESH_S), main B changes
# docs/x.md only: reused for B, enqueued, nothing dispatched.
# ============================================================================
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick
enqueued I1
[ "$(ndisp)" = 0 ] && ok || bad "I1: no dispatch (got $(cat "$T/dispatch.txt"); log: $(pqlog))"
case "$(entry "$MB")" in "green $((NOW - 3000)) 777"*) ok ;; *) bad "I1: the (head, B) entry is the candidate's line (got '$(entry "$MB")')" ;; esac
[ "$(cat "$PQD/example-org_demo-os_41_${HA}_$MB.reuse" 2>/dev/null)" = "reused-from main=$MA run=777 commits=1 files=1 reason=impact-disjoint" ] \
  && ok || bad "I1: the .reuse reason line (got '$(cat "$PQD/example-org_demo-os_41_${HA}_$MB.reuse" 2>/dev/null)')"
grep -qE "PREQUEUE reuse #41 head=${HA:0:12} verdict-main=${MA:0:12} current-main=${MB:0:12} age=24[0-9][0-9]s verdict=green -> impact-reuse \(disjoint, commits=1 files=1\)" "$MCLOG" 2>/dev/null \
  && ok || bad "I1: one impact-reuse line (log: $(pqlog))"
[ "$(impact_lines)" = 1 ] && ok || bad "I1: exactly one impact line (got $(impact_lines))"
[ "$(grep -c . "$T/compare.txt")" = 1 ] && [ "$(cat "$T/compare.txt")" = "$MA...$MB" ] && ok || bad "I1: one compare read A...B (got $(cat "$T/compare.txt"))"
# The read-back: the entry is a plain hit on the next tick.
KEEP=1 reset "$HA" "$MB"; tick
enqueued "I1 read-back"
[ "$(ndisp)" = 0 ] && [ ! -s "$T/compare.txt" ] && ok || bad "I1 read-back: a hit, no dispatch and no compare read (dispatch $(ndisp); compare $(cat "$T/compare.txt"))"
[ "$(impact_lines)" = 0 ] && ok || bad "I1 read-back: no impact line on a hit (log: $(pqlog))"

# ============================================================================
# I11. The chain: main C = B + docs/y.md. The B entry is the candidate.
# ============================================================================
KEEP=1 reset "$HA" "$MC"
# The B entry was read seconds ago, so FRESH_S (BH-5572) would reuse it first;
# age it to 37 min (past FRESH_S, still newer than the A entry read 40 min
# ago), so the chain is impact reuse's to decide.
touch -d "@$((NOW - 2200))" "$PQD/example-org_demo-os_41_${HA}_$MB"; tick
enqueued I11
grep -q "PREQUEUE reuse #41 head=${HA:0:12} verdict-main=${MB:0:12} current-main=${MC:0:12} .* -> impact-reuse (disjoint, commits=1 files=1)" "$MCLOG" 2>/dev/null \
  && ok || bad "I11: the impact-reuse line names B and C (log: $(pqlog))"
[ "$(ndisp)" = 0 ] && ok || bad "I11: no dispatch (got $(cat "$T/dispatch.txt"); log: $(pqlog))"
[ "$(cat "$T/compare.txt")" = "$MB...$MC" ] && ok || bad "I11: the compare read is B...C (got $(cat "$T/compare.txt"))"
case "$(cat "$PQD/example-org_demo-os_41_${HA}_$MC.reuse" 2>/dev/null)" in "reused-from main=$MB run=777 "*) ok ;; *) bad "I11: .reuse names main B (got '$(cat "$PQD/example-org_demo-os_41_${HA}_$MC.reuse" 2>/dev/null)')" ;; esac

# ============================================================================
# I2. Main B changes bin/lib/a.sh, the PR's own file: dispatch.
# ============================================================================
reset "$HA" "$MBA"; seed "$MA" green 3000 2400; tick
one_dispatch I2 "$MBA"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (impact-hit bin/lib/a.sh)" "$MCLOG" 2>/dev/null && ok || bad "I2: impact-hit names the shared file (log: $(pqlog))"

# ============================================================================
# I3. Main B changes bin/lib/a2.sh: a different file, the same suite.
# ============================================================================
reset "$HA" "$MBA2"; seed "$MA" green 3000 2400; tick
one_dispatch I3 "$MBA2"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (impact-hit tests/a.sh)" "$MCLOG" 2>/dev/null && ok || bad "I3: impact-hit names the shared suite (log: $(pqlog))"

# ============================================================================
# I4. Main B changes the CI workflow: full.
# ============================================================================
reset "$HA" "$MBW"; seed "$MA" green 3000 2400; tick
one_dispatch I4 "$MBW"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (main-full: full: infra change (.github/workflows/harness-ci.yml))" "$MCLOG" 2>/dev/null \
  && ok || bad "I4: the line says main-full (log: $(pqlog))"

# ============================================================================
# I5. The PR itself is full.
# ============================================================================
reset "$HF" "$MB"; seed "$MA" green 3000 2400; tick
one_dispatch I5 "$MB"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (pr-full: " "$MCLOG" 2>/dev/null && ok || bad "I5: the line says pr-full (log: $(pqlog))"

# ============================================================================
# I6. Disjoint files, but docs/new is a file on the head and a directory on B.
# ============================================================================
reset "$HDF" "$MBDF"; seed "$MA" green 3000 2400; tick
not_enqueued I6
[ "$(ndisp)" = 0 ] && ok || bad "I6: no dispatch (got $(cat "$T/dispatch.txt"))"
[ "$(state)" = NEEDS_REBASE ] && ok || bad "I6: NEEDS_REBASE (state '$(state)', reason '$(reason)'; log: $(pqlog))"
grep -q "PREQUEUE reuse #41 .* -> impact-rebase (disjoint, conflict)" "$MCLOG" 2>/dev/null && ok || bad "I6: the impact-rebase line (log: $(pqlog))"
[ -z "$(entry "$MBDF")" ] && ok || bad "I6: no entry for (head, B) (got '$(entry "$MBDF")')"

# ============================================================================
# I7. The knob off: the behaviour before BH-6924.
# ============================================================================
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick MC_PREQUEUE_IMPACT_REUSE=0
one_dispatch I7 "$MB"
[ "$(impact_lines)" = 0 ] && ok || bad "I7: no impact line (log: $(pqlog))"
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick MC_PREQUEUE_REUSE=0
one_dispatch "I7 REUSE=0" "$MB"

# ============================================================================
# I8. Dispatched before PQ_MIN_AT, or older than MC_PREQUEUE_IMPACT_MAX_S.
# ============================================================================
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick PQ_MIN_AT=$((NOW - 2000))
one_dispatch "I8 PQ_MIN_AT" "$MB"
[ "$(impact_lines)" = 0 ] && ok || bad "I8: no candidate, no impact line (log: $(pqlog))"
reset "$HA" "$MB"; seed "$MA" green 25200 2400; tick
one_dispatch "I8 7h old" "$MB"
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick MC_PREQUEUE_IMPACT_MAX_S=2000
one_dispatch "I8 MAX_S=2000" "$MB"

# ============================================================================
# I9. A repo that is not the harness repo.
# ============================================================================
reset "$HA" "$MB"; seed "$MA" green 3000 2400; tick HARNESS_REPO=example-org/other-os
one_dispatch I9 "$MB"
[ "$(impact_lines)" = 0 ] && [ ! -s "$T/compare.txt" ] && ok || bad "I9: no impact line, no compare read (log: $(pqlog); compare $(cat "$T/compare.txt"))"

# ============================================================================
# I10. could-not-run and conflict are never reused.
# ============================================================================
for v in could-not-run conflict; do
  reset "$HA" "$MB"; seed "$MA" "$v" 3000 2400; tick
  one_dispatch "I10 $v" "$MB"
  grep -q "PREQUEUE reuse #41 .* verdict=$v -> impact-none (the newest verdict is $v)" "$MCLOG" 2>/dev/null && ok || bad "I10 $v: impact-none line (log: $(pqlog))"
done
# A newer red on another main is never stepped over to reach an older green.
reset "$HA" "$MB"; seed "$MA" green 3000 2400; seed "$MBA" red 2500 2000 tests/a.sh; tick
[ "$(ndisp)" = 1 ] && ok || bad "I10 newer red: one dispatch (got $(cat "$T/dispatch.txt"); log: $(pqlog))"
not_enqueued "I10 newer red"

# ============================================================================
# I12. An unreadable compare, or one GitHub capped at 300 files.
# ============================================================================
reset "$HA" "$MB"; seed "$MA" green 3000 2400; touch "$T/cmp.fail"; tick
one_dispatch "I12 unreadable" "$MB"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (compare-unusable: unreadable)" "$MCLOG" 2>/dev/null && ok || bad "I12: compare-unusable unreadable (log: $(pqlog))"
reset "$HA" "$MB"; seed "$MA" green 3000 2400; touch "$T/cmp.big"; tick
one_dispatch "I12 300 files" "$MB"
grep -q "PREQUEUE reuse #41 .* -> impact-dispatch (compare-unusable: status=ahead files=300)" "$MCLOG" 2>/dev/null && ok || bad "I12: compare-unusable 300 (log: $(pqlog))"

echo "prequeue-reuse.bh-6924: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
