#!/bin/bash
# tests/mc/rebind-publishes-status.bh-4596-test.sh — BH-4596: AN APPROVAL
# REBOUND TO A MOVED HEAD REPUBLISHES THE lead-verdict STATUS.
#
# THE INCIDENT (#4375, #4415, #4357). A Mergify-queued PR took a clean main
# merge. The conductor rebound the approval to the new head (patch-id or
# patch-same, BH-2310), but a commit status is keyed by sha, so the new head had
# no `lead-verdict`. The row stayed QUEUED (the labels survive the push), so
# mc_enqueue_mergify — the only conductor publisher — never ran again, and
# Mergify waited on `check-success = "lead-verdict"` until a human posted it.
# The TTL page fired and stuck_rekick said "no deterministic re-kick".
#
# THE RULE. Both rebind arms carry success onto the new head (mc_rebind_publish,
# once per (PR, head)) when the row is QUEUED or the old head already had it; a
# failed publish is owed and retried next tick; the QUEUED TTL re-kick
# republishes from a standing verdict bound to the head when the head carries
# no status, and never over a failure. A READY row is never cleared by either
# path: the conductor may be holding it (main-red freeze, a dependency), and
# its own enqueue publishes once those gates pass (review F1/F2).
#
# Driven against the real bin/merge-conductor.sh, a stub gh that keeps commit
# statuses in $T/statuses.txt, and a stub git whose patch-id is md5 of
# $T/patch.<sha> (tests/mc/rebase-test.sh §4). One clock read (NOW).
# Run from anywhere: tests/mc/rebind-publishes-status.bh-4596-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" \
         "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
# scratch-closure-allow: pins the conductor's minimal lib set; the closure also installs the optional libs it loads only when present (GitHub App auth among them), which moves every gh call off this fixture's stub
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# verdict-status.sh is what loads vs_publish into the conductor (BH-3348);
# main-red-gate.sh is the freeze the READY cases (T6, R8) hold a row with.
for f in merge-conductor-lib main-red-gate gh-pr-list gh-budget gh-rest gh-rest-var gh-rest-list gh-rest-etag verdict-status; do
  cp "$DIR/bin/lib/$f.sh" "$T/h/bin/lib/"
done
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\nnatv example-org/natv-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
for s in beat pre-arm-guards codegraph-ensure deploy-request; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; done
chmod +x "$T/h/bin/"*.sh

MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

# git: patch-id is md5 of whatever `git diff` printed for that sha, so "same
# patch" and "different patch" are one file each (tests/mc/rebase-test.sh §4).
# For the overlap rebind (R7): merge-base of <sha> is $T/mbase.<sha>, and
# `diff --name-only <a> <b>` prints $T/names.<a>.<b>.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *ls-remote*|*"remote set-url"*|*clone*) exit 0 ;;
  *fetch*)    exit 0 ;;
  *merge-base*) S="\${A##* }"; cat "$T/mbase.\$S" 2>/dev/null || echo base0000base0000; exit 0 ;;
  *patch-id*) md5sum | cut -d' ' -f1; exit 0 ;;
  *"diff --name-only"*) cat "$T/names.\$(awk '{print \$(NF-1)"."\$NF}' <<<"\$A")" 2>/dev/null; exit 0 ;;
  *" diff "*) SHA="\${A##* }"; cat "$T/patch.\$SHA" 2>/dev/null || printf 'diff-%s\n' "\$SHA"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/git"

# ---- fixture switches -------------------------------------------------------
# head-<repo>  the PR's head sha       labels-<repo>  labels, comma-separated
# statuses.txt `<sha> <state> <description>` per POST that answered 201
# vs-fail      every statuses POST answers 500   vs-unread  every status GET 503
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
repo_of() { sed -n 's|.*example-org/\([a-z]*\)-os.*|\1|p' <<<"$*" | head -1; }
R=$(repo_of "$*"); HD=$(cat "$T/head-$R" 2>/dev/null); LBL=$(cat "$T/labels-$R" 2>/dev/null)
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"api -i -X GET repos/example-org/natv-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"name":"main","enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/example-org/natv-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/natv-os/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X POST repos/"*"/statuses/"*)
    SHA=$(sed -n 's|.*/statuses/\([0-9a-f]*\).*|\1|p' <<<"$*"); ST=""; DS=""
    for a in "$@"; do case "$a" in state=*) ST="${a#state=}" ;; description=*) DS="${a#description=}" ;; esac; done
    printf '%s %s %s\n' "$SHA" "$ST" "$DS" >> "$T/status-posts.txt"
    if [ -e "$T/vs-fail" ]; then restpr --raw 500 '{"message":"Server Error"}'
    else printf '%s %s %s\n' "$SHA" "$ST" "$DS" >> "$T/statuses.txt"; restpr --raw 201 '{"id":1}'; fi ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    [ -e "$T/vs-unread" ] && { restpr --raw 503 '{"message":"unavailable"}'; exit 0; }
    SHA=$(sed -n 's|.*/commits/\([0-9a-f]*\)/status.*|\1|p' <<<"$*")
    J=$(awk -v s="$SHA" '$1==s {print $2}' "$T/statuses.txt" 2>/dev/null | tail -1 \
        | jq -R -s -c '[split("\n")[] | select(length > 0) | {context:"lead-verdict", state:.}]')
    restpr --raw 200 "{\"state\":\"pending\",\"statuses\":${J:-[]}}" ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"api -X POST repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"api -i -X POST repos/"*) printf '%s\n' "$*" >> "$T/writes.txt"; restpr --raw 201 '{}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff ;;
  *"/pulls/"*"/files"*) restpr --raw 200 "$(cat "$T/prfiles" 2>/dev/null || echo '[]')" ;;
  *"/pulls/"*"/commits"*|*"/pulls/"*"/reviews"*|*"/pulls/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$HD" "ticket/t-$PN" main "$LBL" MERGEABLE CLEAN operator ;;
  *"pr list -R example-org/"*"-os --state open"*)
    [ -n "$HD" ] || { echo "[]"; exit 0; }
    PN=$([ "$R" = mgfy ] && echo 31 || echo 41)
    LJ=$(printf '%s' "$LBL" | jq -R -c 'split(",") | map(select(length > 0) | {name: .})'); LJ=${LJ:-[]}
    printf '[{"number":%s,"url":"https://github.com/example-org/%s-os/pull/%s","headRefOid":"%s","headRefName":"ticket/t-%s","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":%s,"author":{"login":"operator"}}]\n' \
      "$PN" "$R" "$PN" "$HD" "$PN" "$LJ" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
A="$T/h/state/merge-conductor/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
OWED="$T/h/state/merge-conductor/vs-owed"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_DETACHED_DEPLOY_VERIFY=0 MC_LAND_REBASE=0 \
  MC_MAIN_RED_TEST_PATHS="tests/*" MC_REPOS="$T/repos" MC_RR_PATH="$T/fakebin:$PATH" env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
nlines()    { local n; n=$(grep -c "$@" 2>/dev/null) || true; printf '%s' "${n:-0}"; }
posts_on()  { nlines "^$1 " "$T/status-posts.txt"; }            # every POST (2xx or not) on a sha
succ_on()   { nlines "^$1 success" "$T/statuses.txt"; }          # successes that landed on a sha
K31='example-org/mgfy-os#31'
U31=https://github.com/example-org/mgfy-os/pull/31
KN='example-org/natv-os#41'
UN=https://github.com/example-org/natv-os/pull/41
OWED31="$OWED/$(mc_handoff_id "$K31")"
REC31="$T/h/builds/pool-mgfy-os-X-31-202610050000"
REC41="$T/h/builds/pool-natv-os-X-41-202610050000"

sha() { printf '%s%s' "$1" "$(printf '0%.0s' $(seq 1 $((40 - ${#1}))))"; }

mkrec() { # mkrec <dir> <repo> <num> <reviewed-sha>
  scratch_rm "$1" || exit 1; mkdir -p "$1"
  echo "PR_CREATED https://github.com/example-org/$2-os/pull/$3" > "$1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$1/review.md"
  echo "$4" > "$1/reviewed-sha"
  : > "$1/pipeline.log"
}

# reset_case <repo> <reviewed> <head> <row-state> <labels>
#   One open PR whose build record approves <reviewed>, at <head>, its row in
#   <row-state> on <head>. Every other fixture switch is cleared.
reset_case() {
  local repo="$1" rev="$2" head="$3" st="$4" lbl="$5" d
  : > "$A"; : > "$CLOG"; : > "$T/h/logs/ALERTS.log"
  for f in gh-calls writes merges comments statuses status-posts; do : > "$T/$f.txt"; done
  rm -f "$T"/head-* "$T"/labels-* "$T/vs-fail" "$T/vs-unread" "$T"/mbase.* "$T"/names.* "$T/prfiles" "$T/h/flags/main-red-mgfy"
  for d in "$OWED" "$T/h/state/gh-etag" "$T/h/state/merge-conductor/stuck" "$T/h/state/merge-conductor/rereview" \
           "$T/h/state/merge-conductor/mergify-ask" "$T/h/state/merge-conductor/patch-id"; do
    scratch_rm "$d" || exit 1
  done
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -f "$T/h/state/merge-conductor/tick"/* 2>/dev/null
  scratch_rm "$REC31" || exit 1; scratch_rm "$REC41" || exit 1
  echo "$head" > "$T/head-$repo"; printf '%s' "$lbl" > "$T/labels-$repo"
  if [ "$repo" = mgfy ]; then
    mkrec "$REC31" mgfy 31 "$rev"
    mc_row_put "$K31" "$st" $((NOW-300)) "$head" "$rev" - "in the merge queue" "$U31"
  else
    mkrec "$REC41" natv 41 "$rev"
    mc_row_put "$KN" "$st" $((NOW-300)) "$head" "$rev" - "in the merge queue" "$UN"
  fi
}

# ============================================================================
# R1 — a patch-id rebind on a QUEUED Mergify PR publishes success ONCE on the
#      new head (the incident shape: labels kept, row stays QUEUED).
# ============================================================================
H1=$(sha a1); H2=$(sha b1)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'the same patch\n' > "$T/patch.$H1"; printf 'the same patch\n' > "$T/patch.$H2"
run_tick
grep -q "$K31 REBOUND ${H1:0:8} -> ${H2:0:8}" "$CLOG" && ok || bad "R1: the patch-id rebind fires ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
[ "$(nlines . "$T/status-posts.txt")" = 1 ] && ok || bad "R1: exactly ONE status POST ($(cat "$T/status-posts.txt"))"
[ "$(succ_on "$H2")" = 1 ] && ok || bad "R1: and it is success on the new head ($(cat "$T/statuses.txt"))"
grep -q "^$H2 success .*rebound from ${H1:0:12}" "$T/statuses.txt" && ok || bad "R1: the description names the old head ($(cat "$T/statuses.txt"))"
[ "$(posts_on "$H1")" = 0 ] && ok || bad "R1: nothing POSTed on the old head"
[ "$(state_of "$K31")" = QUEUED ] && ok || bad "R1: the row stays QUEUED (got $(state_of "$K31"))"
[ ! -s "$T/comments.txt" ] && ok || bad "R1: no enqueue ask was posted ($(cat "$T/comments.txt"))"
grep -q "$K31 VS_REBIND_PUBLISHED $H2 lead-verdict=success (rebound from ${H1:0:12})" "$CLOG" && ok || bad "R1: the publish is logged"
grep -qxF "vsrebind $K31 $H2" "$A" && ok || bad "R1: the once-per-head mark is written ($(cat "$A"))"
run_tick
[ "$(nlines . "$T/status-posts.txt")" = 1 ] && ok || bad "R1: a second tick POSTs nothing more ($(cat "$T/status-posts.txt"))"

# ============================================================================
# R2 — a failed publish is owed, retried next tick, and never succeeds twice.
# ============================================================================
H1=$(sha a2); H2=$(sha b2)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch two\n' > "$T/patch.$H1"; printf 'patch two\n' > "$T/patch.$H2"
touch "$T/vs-fail"
run_tick
[ "$(posts_on "$H2")" = 1 ] && ok || bad "R2: tick 1 POSTs once on the new head ($(cat "$T/status-posts.txt"))"
[ "$(succ_on "$H2")" = 0 ] && ok || bad "R2: and it did not land"
[ -s "$OWED31" ] && ok || bad "R2: the publish is owed ($(ls "$OWED" 2>/dev/null))"
[ "$(cut -f1 "$OWED31" 2>/dev/null)" = "$H2" ] && ok || bad "R2: owed on the new head ($(cat "$OWED31" 2>/dev/null))"
grep -q "$K31 VS_REBIND_OWED on ${H2:0:8}: .*HTTP 500.* — retried next tick" "$CLOG" && ok || bad "R2: the log names the failure and the retry ($(grep -o 'mgfy-os#31 VS_.*' "$CLOG" | head -3))"
rm -f "$T/vs-fail"
run_tick
[ "$(succ_on "$H2")" = 1 ] && ok || bad "R2: tick 2 retries and lands ONE success ($(cat "$T/statuses.txt"))"
[ ! -e "$OWED31" ] && ok || bad "R2: the owed file is gone"
grep -q "$K31 VS_REBIND_PUBLISHED $H2" "$CLOG" && ok || bad "R2: the retry is logged as published"
run_tick
[ "$(succ_on "$H2")" = 1 ] && ok || bad "R2: tick 3 POSTs no second success ($(cat "$T/statuses.txt"))"
[ "$(posts_on "$H2")" = 2 ] && ok || bad "R2: two POSTs in all, one failed and one landed ($(cat "$T/status-posts.txt"))"

# ============================================================================
# R3 — an owed head that is no longer the head is dropped, never published.
# ============================================================================
H1=$(sha a3); H2=$(sha b3); H3=$(sha c3)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch three\n' > "$T/patch.$H1"; printf 'patch three\n' > "$T/patch.$H2"
printf 'a different patch three\n' > "$T/patch.$H3"
touch "$T/vs-fail"
run_tick
[ -s "$OWED31" ] && ok || bad "R3: the failed publish is owed"
rm -f "$T/vs-fail"; echo "$H3" > "$T/head-mgfy"; : > "$T/status-posts.txt"; : > "$CLOG"
run_tick
[ ! -s "$T/status-posts.txt" ] && ok || bad "R3: no POST on H2 or H3 ($(cat "$T/status-posts.txt"))"
[ ! -e "$OWED31" ] && ok || bad "R3: the stale owed file is dropped"
grep -q "$K31 VS_REBIND_DROPPED ${H2:0:8}: head moved to ${H3:0:8}" "$CLOG" && ok || bad "R3: the drop is logged ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
grep -q "$K31 REREVIEW_SPAWNED" "$CLOG" && ok || bad "R3: the new head takes the re-review path as today"

# ============================================================================
# R4 — a head move that is not a rebind publishes nothing and carries nothing.
# ============================================================================
H1=$(sha a4); H2=$(sha b4)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch four\n' > "$T/patch.$H1"; printf 'patch four, edited\n' > "$T/patch.$H2"
run_tick
grep -q "$K31 REBOUND" "$CLOG" && bad "R4: a different patch must not rebind" || ok
[ ! -s "$T/status-posts.txt" ] && ok || bad "R4: zero status POSTs ($(cat "$T/status-posts.txt"))"
[ ! -e "$OWED31" ] && ok || bad "R4: nothing owed"
grep -q "$K31 REREVIEW_SPAWNED" "$CLOG" && ok || bad "R4: the head takes the re-review path ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"

# ============================================================================
# R5 — merges off: nothing POSTed, the publish is owed and paid when they return.
# ============================================================================
H1=$(sha a5); H2=$(sha b5)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch five\n' > "$T/patch.$H1"; printf 'patch five\n' > "$T/patch.$H2"
rm -f "$T/h/flags/merge-conductor-merge"
run_tick
[ ! -s "$T/status-posts.txt" ] && ok || bad "R5: merges off POSTs nothing ($(cat "$T/status-posts.txt"))"
[ -s "$OWED31" ] && ok || bad "R5: the publish is owed"
grep -q "$K31 WOULD publish lead-verdict=success on ${H2:0:8}" "$CLOG" && ok || bad "R5: the log says WOULD ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
run_tick
[ "$(nlines -F "WOULD publish lead-verdict=success on ${H2:0:8}" "$CLOG")" = 1 ] && ok || bad "R5: a second paused tick does not repeat the WOULD line ($(grep -c WOULD "$CLOG"))"
[ ! -s "$T/status-posts.txt" ] && ok || bad "R5: and still POSTs nothing"
touch "$T/h/flags/merge-conductor-merge"
run_tick
[ "$(succ_on "$H2")" = 1 ] && ok || bad "R5: merges back on: exactly one success ($(cat "$T/status-posts.txt"))"
[ ! -e "$OWED31" ] && ok || bad "R5: and nothing is owed any more"

# ============================================================================
# R6 — not Mergify: the native queue gets no status POST from a rebind.
# ============================================================================
H1=$(sha a6); H2=$(sha b6)
reset_case natv "$H1" "$H2" READY ""
printf 'patch six\n' > "$T/patch.$H1"; printf 'patch six\n' > "$T/patch.$H2"
run_tick
grep -q "$KN REBOUND ${H1:0:8} -> ${H2:0:8}" "$CLOG" && ok || bad "R6: the native-queue PR still rebinds ($(grep -o 'natv-os#41 .*' "$CLOG" | head -3))"
[ ! -s "$T/status-posts.txt" ] && ok || bad "R6: and gets no status POST ($(cat "$T/status-posts.txt"))"
[ -z "$(ls -A "$OWED" 2>/dev/null)" ] && ok || bad "R6: and owes nothing"

# ============================================================================
# R7 — the overlap rebind (W2-D) publishes the same way: a different patch, but
#      only a main merge between the heads and no file of this PR in it.
# ============================================================================
H1=$(sha a7); H2=$(sha b7)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch r7\n' > "$T/patch.$H1"; printf 'patch r7, on a new base\n' > "$T/patch.$H2"
echo baseA > "$T/mbase.$H1"; echo baseB > "$T/mbase.$H2"
echo docs/landed.md > "$T/names.baseA.baseB"; echo docs/landed.md > "$T/names.$H1.$H2"
printf '[{"filename":"src/x.ts"}]' > "$T/prfiles"
run_tick
grep -q "$K31 NO_OVERLAP rebound ${H1:0:8} -> ${H2:0:8}" "$CLOG" && ok || bad "R7: the overlap rebind fires ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
[ "$(nlines . "$T/status-posts.txt")" = 1 ] && ok || bad "R7: exactly ONE status POST ($(cat "$T/status-posts.txt"))"
grep -q "^$H2 success .*rebound from ${H1:0:12}" "$T/statuses.txt" && ok || bad "R7: success on the new head ($(cat "$T/statuses.txt"))"
grep -q "$K31 VS_REBIND_PUBLISHED $H2" "$CLOG" && ok || bad "R7: the publish is logged"

# ============================================================================
# T1 — a standing verdict on the head, no status, at the QUEUED TTL: republished once.
# ============================================================================
H2=$(sha bd)
reset_case mgfy "$H2" "$H2" QUEUED "merge-queue,queued"
printf 'patch seven\n' > "$T/patch.$H2"
run_tick env MC_TTL_QUEUED=0
[ "$(nlines -F "STUCK:" "$T/h/logs/ALERTS.log")" -ge 1 ] && ok || bad "T1: the STUCK page goes out ($(tail -2 "$T/h/logs/ALERTS.log"))"
[ "$(posts_on "$H2")" = 1 ] && ok || bad "T1: ONE POST on the head ($(cat "$T/status-posts.txt"))"
grep -q "^$H2 success .*republished at the QUEUED TTL" "$T/statuses.txt" && ok || bad "T1: success, from the TTL arm ($(cat "$T/statuses.txt"))"
grep -q "$K31 VS_REPUBLISHED" "$CLOG" && ok || bad "T1: the log says VS_REPUBLISHED ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
grep -q "$K31 stuck in QUEUED past its TTL — no deterministic re-kick" "$CLOG" && bad "T1: the old shrug must not be logged" || ok
run_tick env MC_TTL_QUEUED=0
[ "$(posts_on "$H2")" = 1 ] && ok || bad "T1: a second tick POSTs nothing ($(cat "$T/status-posts.txt"))"
# A READY row past its TTL is NOT republished (review F1): the conductor may be
# the one holding it, and its own enqueue publishes once its gates pass. With
# no hold, that enqueue is the only POST ("cleared … for the queue").
H2=$(sha b8)
reset_case mgfy "$H2" "$H2" READY ""
printf 'patch eight\n' > "$T/patch.$H2"
run_tick env MC_TTL_READY=0
[ "$(nlines -F "republished at the READY TTL" "$T/statuses.txt")" = 0 ] && ok || bad "T1-READY: the READY TTL republishes nothing ($(cat "$T/status-posts.txt"))"
grep -q "$K31 VS_REPUBLISHED" "$CLOG" && bad "T1-READY: no VS_REPUBLISHED on a READY row" || ok

# ============================================================================
# T6 — a READY row the main-red freeze holds, past its TTL: zero status POSTs,
#      so Mergify is never handed a clearance the freeze withheld (review F1).
#      The merge-queue label from an earlier head is still on, the shape where
#      a stray success would have queued it straight through the freeze.
# ============================================================================
H2=$(sha be)
reset_case mgfy "$H2" "$H2" READY "merge-queue"
printf 'patch fourteen\n' > "$T/patch.$H2"
echo "main is red" > "$T/h/flags/main-red-mgfy"
run_tick env MC_TTL_READY=0
grep -q "$K31 READY and HELD by the main-red freeze" "$CLOG" && ok || bad "T6: the freeze holds the row ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
[ ! -s "$T/status-posts.txt" ] && ok || bad "T6: zero status POSTs under the freeze ($(cat "$T/status-posts.txt"))"
# TEST-CHANGE (BH-6000): READY past its TTL now has a re-kick arm
# (mc_ready_rekick: one keyed conductor run per head when no hold is recorded).
# This row IS held (the main-red freeze, recorded as its ready-why), so the arm
# must name the hold and launch nothing. The status assertions are unchanged.
grep -q "$K31 stuck in READY past its TTL on .* — the conductor holds it on purpose" "$CLOG" && ok || bad "T6: the READY TTL names the freeze hold and re-kicks nothing ($(grep -o 'mgfy-os#31 stuck.*' "$CLOG" | head -2))"
run_tick env MC_TTL_READY=0
[ ! -s "$T/status-posts.txt" ] && ok || bad "T6: and a second tick still POSTs nothing ($(cat "$T/status-posts.txt"))"

# ============================================================================
# R8 — a rebind on a READY row CARRIES, it never clears (review F2). Under the
#      freeze: the old head had no lead-verdict, so nothing is POSTed; the old
#      head had success, so the same success is carried to the new head.
# ============================================================================
H1=$(sha af); H2=$(sha bf)
reset_case mgfy "$H1" "$H2" READY ""
printf 'patch fifteen\n' > "$T/patch.$H1"; printf 'patch fifteen\n' > "$T/patch.$H2"
echo "main is red" > "$T/h/flags/main-red-mgfy"
run_tick
grep -q "$K31 REBOUND ${H1:0:8} -> ${H2:0:8}" "$CLOG" && ok || bad "R8: the rebind fires ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -3))"
[ ! -s "$T/status-posts.txt" ] && ok || bad "R8: no status on the old head: zero POSTs ($(cat "$T/status-posts.txt"))"
grep -q "$K31 lead-verdict not carried to ${H2:0:8}: the row is READY" "$CLOG" && ok || bad "R8: the log says why ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
[ ! -e "$OWED31" ] && ok || bad "R8: and nothing is owed"
H1=$(sha a0); H2=$(sha b0)
reset_case mgfy "$H1" "$H2" READY ""
printf 'patch sixteen\n' > "$T/patch.$H1"; printf 'patch sixteen\n' > "$T/patch.$H2"
printf '%s success seeded\n' "$H1" > "$T/statuses.txt"
echo "main is red" > "$T/h/flags/main-red-mgfy"
run_tick
[ "$(nlines . "$T/status-posts.txt")" = 1 ] && ok || bad "R8: the old head had success: ONE POST ($(cat "$T/status-posts.txt"))"
grep -q "^$H2 success .*rebound from ${H1:0:12}" "$T/statuses.txt" && ok || bad "R8: and it is the carried success ($(cat "$T/statuses.txt"))"

# ============================================================================
# T2 — already green: nothing POSTed, the log says the status is there.
# ============================================================================
H2=$(sha b9)
reset_case mgfy "$H2" "$H2" QUEUED "merge-queue,queued"
printf 'patch nine\n' > "$T/patch.$H2"
printf '%s success seeded\n' "$H2" > "$T/statuses.txt"
run_tick env MC_TTL_QUEUED=0
[ ! -s "$T/status-posts.txt" ] && ok || bad "T2: zero POSTs ($(cat "$T/status-posts.txt"))"
grep -q "$K31 stuck in QUEUED past its TTL — lead-verdict is already success on ${H2:0:8}" "$CLOG" && ok || bad "T2: the log says it is present ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"

# ============================================================================
# T3 — a lead BLOCK (failure) on the head is never overwritten.
# ============================================================================
H2=$(sha ba)
reset_case mgfy "$H2" "$H2" QUEUED "merge-queue,queued"
printf 'patch ten\n' > "$T/patch.$H2"
printf '%s failure seeded\n' "$H2" > "$T/statuses.txt"
run_tick env MC_TTL_QUEUED=0
[ ! -s "$T/status-posts.txt" ] && ok || bad "T3: zero POSTs over a failure ($(cat "$T/status-posts.txt"))"
grep -q "$K31 stuck in QUEUED past its TTL — lead-verdict is failure on ${H2:0:8}" "$CLOG" && ok || bad "T3: the log names the failure ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"

# ============================================================================
# T4 — an unread status: no POST, one line, the STUCK page still stands.
# ============================================================================
H2=$(sha bb)
reset_case mgfy "$H2" "$H2" QUEUED "merge-queue,queued"
printf 'patch eleven\n' > "$T/patch.$H2"
touch "$T/vs-unread"
run_tick env MC_TTL_QUEUED=0
[ ! -s "$T/status-posts.txt" ] && ok || bad "T4: zero POSTs on an unread status ($(cat "$T/status-posts.txt"))"
grep -q "$K31 stuck in QUEUED past its TTL — the lead-verdict status on ${H2:0:8} could not be read" "$CLOG" && ok || bad "T4: one log line ($(grep -o 'mgfy-os#31 .*' "$CLOG" | head -4))"
[ "$(nlines -F "STUCK:" "$T/h/logs/ALERTS.log")" -ge 1 ] && ok || bad "T4: the STUCK alert is in ALERTS.log"

# ============================================================================
# T5 — no standing verdict on the head (reviewed H1, head H2, no rebind): no POST.
# ============================================================================
H1=$(sha ac); H2=$(sha bc)
reset_case mgfy "$H1" "$H2" QUEUED "merge-queue,queued"
printf 'patch twelve\n' > "$T/patch.$H1"; printf 'patch twelve, edited\n' > "$T/patch.$H2"
run_tick env MC_TTL_QUEUED=0 MC_TTL_HEAD_MOVED=0
[ ! -s "$T/status-posts.txt" ] && ok || bad "T5: zero POSTs without a verdict on the head ($(cat "$T/status-posts.txt"))"

echo "rebind-publishes-status.bh-4596: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
