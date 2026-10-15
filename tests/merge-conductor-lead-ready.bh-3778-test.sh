#!/bin/bash
# tests/merge-conductor-lead-ready.bh-3778-test.sh — BH-3778: A STANDING LEAD
# MERGE ON THE LIVE HEAD OF A NON-PROTECTED PR REACHES THE MERGE QUEUE.
#
# 2026-10-01: ten cromford PRs carried a lead MERGE-WITH-NOTES and a green
# lead-verdict status on their head and none was in the queue. The conductor
# only read a READY from the builder's own APPROVE, so a head the builder had
# not approved sat in HEAD_MOVED. bin/lib/mc-lead-ready.sh now treats the lead
# row as an approval bound to that head when la_decide lets the lane clear it.
#
#   U  the pure mc_lead_ready gate table, its readers stubbed
#   C  real bin/merge-conductor.sh ticks against a fake gh and a fake worker
# Run from anywhere (exit 0 = all pass).
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LR="$DIR/bin/lib/mc-lead-ready.sh"
H1=1111111111111111111111111111111111111111
H2=8747024e0b1c2d3e4f5061728394a5b6c7d8e9f0

# ============================================================================
# U. mc_lead_ready — the pure gate table
# ============================================================================
# A tree without the lib fails here and still runs C below, so the red run on
# the merge base shows the conductor's own answer for the incident shape.
[ -r "$LR" ] || echo "bad U0: $LR is missing" > "$T/u.out"
[ -r "$LR" ] && (
  # shellcheck source=bin/lib/mc-lead-ready.sh
  . "$LR"
  CALLS="$T/u-calls"; ATT="$T/u-att"; ULOG="$T/u-log"
  SCOPE=0; VD="MERGE-WITH-NOTES	lead	7	2026-10-01T13:35:00Z	-	lead"; VDRC=0; LARC=0
  la_scope()    { echo "scope $1" >> "$CALLS"; return "$SCOPE"; }
  vd_standing() { echo "vd $*" >> "$CALLS"; [ "$VDRC" = 0 ] && printf '%s\n' "$VD"; return "$VDRC"; }
  la_decide()   { echo "la $*" >> "$CALLS"; LA_REASON="no protected path"; return "$LARC"; }
  mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$ATT"; }
  mc_log() { echo "$*" >> "$ULOG"; }
  reset() { : > "$CALLS"; : > "$ATT"; : > "$ULOG"; SCOPE=0; VDRC=0; LARC=0
            VD="MERGE-WITH-NOTES	lead	7	2026-10-01T13:35:00Z	-	lead"; unset MC_LEAD_READY; }
  # row <name> <want-rc> <verdict> <reviewed> <headbound>
  row() { local n="$1" w="$2" g; shift 2
    mc_lead_ready K o/r 31 "$H2" "$@"; g=$?
    [ "$g" = "$w" ] && echo ok || echo "bad $n: want rc $w, got $g for ($*) calls: $(tr '\n' ';' < "$CALLS")"; }
  vdcalls() { grep -c '^vd ' "$CALLS"; }

  reset; row U1 0 - - -                                     # no builder verdict, lead MWN, la rc 0
  grep -q "^la o/r 31 $H2 conductor$" "$CALLS" && echo ok || echo "bad U1: la_decide must be asked as the conductor on the live head ($(cat "$CALLS"))"
  reset; VD="MERGE	lead	8	x	-	lead"; row U2 0 APPROVE "$H1" n/a   # APPROVE on an old sha + MERGE
  reset; VD="MERGE	human	8	x	-	operator"; row U2b 0 APPROVE "$H1" -   # a human MERGE too
  reset; row U3 1 APPROVE "$H2" n/a                         # already bound: nothing to do
  [ "$(vdcalls)" = 0 ] && echo ok || echo "bad U3: an APPROVE on the head must cost no verdicts read"
  reset; VDRC=1; row U4 1 - - -                             # nothing stands
  reset; VD="BLOCK	lead	9	x	-	lead"; row U4b 1 - - -     # a standing lead BLOCK
  reset; VD="MERGE	box	9	x	-	box"; VDRC=1; row U4c 1 - - -  # a box row never stands (worker answers none)
  reset; LARC=1; row U5 1 - - -                             # protected path / authority revoked
  reset; LARC=2; row U6 1 - - -                             # undecidable
  reset; VDRC=2; row U7 1 - - -                             # verdicts worker unreadable
  [ "$(grep -c '^la ' "$CALLS")" = 0 ] && echo ok || echo "bad U7: an unreadable verdict must not go on to la_decide"
  for v in BLOCK CONTRADICTION; do reset; row "U8-$v" 1 "$v" "$H1" -
    [ "$(vdcalls)" = 0 ] && echo ok || echo "bad U8-$v: a builder $v must cost no verdicts read"; done
  reset; row U8b 1 APPROVE "$H1" "blocked@$H2"
  [ "$(vdcalls)" = 0 ] && echo ok || echo "bad U8b: headbound blocked@head must cost no verdicts read"
  reset; row U8c 0 APPROVE "$H1" "blocked@$H1"              # a block on ANOTHER head is not this head's
  reset; SCOPE=1; row U9 1 - - -                            # ungoverned repo
  [ "$(vdcalls)" = 0 ] && echo ok || echo "bad U9: an ungoverned repo must cost no verdicts read"
  reset; SCOPE=2; row U9b 1 - - -                           # unreadable catalog
  reset; MC_LEAD_READY=0; row U10 1 - - -
  [ ! -s "$CALLS" ] && echo ok || echo "bad U10: MC_LEAD_READY=0 must ask nothing"
  reset; row U11a 0 - - -; row U11b 0 - - -
  [ "$(grep -c 'LEAD_READY' "$ULOG")" = 1 ] && echo ok || echo "bad U11: one LEAD_READY line per (PR, head), got $(grep -c LEAD_READY "$ULOG")"
  grep -qxF "leadready K $H2" "$ATT" && echo ok || echo "bad U11: the attempts line must be leadready <key> <head> ($(cat "$ATT"))"
) > "$T/u.out" 2>&1
PASS=$((PASS + $(grep -c '^ok$' "$T/u.out")))
while IFS= read -r l; do bad "${l#bad }"; done < <(grep -v '^ok$' "$T/u.out")

# ============================================================================
# C. Through the real conductor
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/block-gate.sh" \
   "$DIR/bin/lib/verdict-status.sh" "$DIR/bin/lib/lead-authority.sh" "$T/h/bin/lib/"
[ -r "$DIR/bin/lib/mc-lead-ready.sh" ] && cp "$DIR/bin/lib/mc-lead-ready.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
# The repo is governed: one lead_protected_paths row (the worker stub,
# tests/lib/lpp-stub.sh), so la_scope is rc 0.
LPP="$T/lpp.json"
lpp_install "$T/fakebin" "$LPP" "$T/lpp-down"
lpp_set "$LPP" example-org/mgfy-os 'protected/**'
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure lane-alert; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$T" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
RUNS=$(cat "$T/runs" 2>/dev/null || echo 'completed|success')
BASE=$(cat "$T/base" 2>/dev/null || echo main)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/^,*//; s/,$//')
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/check-runs"*) restpr --raw 200 '{"check_runs":[]}' ;;
  # ---- writes -------------------------------------------------------------
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; exit 0 ;;
  *"statuses/"*) printf '%s\n' "$*" >> "$T/statuses.txt"; restpr --raw 201 '{"state":"success"}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  # ---- reads --------------------------------------------------------------
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  # la_decide's files read (BH-3683): the PR's file list, from $T/files.
  *"api -i -X GET repos/example-org/mgfy-os/pulls/31/files?per_page=100&page="*)
    restpr --raw 200 "$(jq -Rnc '[inputs | select(length>0) | {filename:.}]' < "$T/files")" ;;
  # the block gate's thread reads: an empty thread, the head commit's date.
  *"/pulls/31/reviews"*|*"api repos/example-org/mgfy-os/issues/31/comments"*) echo "" ;;
  *"api repos/example-org/mgfy-os/pulls/31/commits"*) echo "2026-09-12T00:00:00Z" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" "$BASE" "$LBL" MERGEABLE CLEAN operator ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  "api repos/example-org/mgfy-os/pulls/"[0-9]*)
    RN=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p')
    RLJ=$(printf '%s' "$LBL" | tr ',' '\n' | sed '/^$/d' | sed 's/.*/{"name":"&"}/' | paste -sd, -)
    printf '{"number":%s,"html_url":"https://github.com/example-org/mgfy-os/pull/%s","title":"t","body":"","state":"open","merged_at":null,"merge_commit_sha":null,"mergeable_state":"clean","draft":false,"head":{"sha":"%s","ref":"ticket/mg-31"},"base":{"ref":"%s"},"user":{"login":"operator","type":"User"},"labels":[%s],"created_at":"2026-09-12T00:00:00Z","updated_at":"2026-09-12T00:00:00Z","closed_at":null}\n' \
      "$RN" "$RN" "$(cat "$T/head-$RN" 2>/dev/null || echo unknown)" "$BASE" "$RLJ" ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs "$RUNS" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
# The jobs worker: the standing verdict on PR 31 is $T/verdict when the asked
# head is $T/vhead; the lane authority row is $T/authority when it exists.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  # TEST-CHANGE BH-4140: the lead_protected_paths rows (only ever read here)
  */api/lead-protected-paths*) lpp-answer GET "\$URL"; exit 0 ;;
  */api/verdicts\?*)
    if [ -s "$T/verdict" ] && [ "\${URL#*head=\$(cat "$T/vhead")}" != "\$URL" ]; then
      printf '{"standing":%s,"rows":[],"truncated":false}\n200\n' "\$(cat "$T/verdict")"
    else printf '{"standing":null,"rows":[],"truncated":false}\n200\n'; fi ;;
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  */api/settings/lead_authority_mode) printf '{"setting":{"key":"k","value":"human"}}\n200\n' ;;
  */api/settings/lead_authority.example-org.mgfy-os)
    if [ -s "$T/authority" ]; then printf '{"setting":{"key":"k","value":"%s"}}\n200\n' "\$(cat "$T/authority")"
    else printf '{"error":"no such setting"}\n404\n'; fi ;;
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

mkrec() { # mkrec <num> <head> <reviewed-sha> — the builder approved an OLDER head
  local d="$T/h/builds/pool-mgfy-MG-$1-2026100100$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <base>
  printf '[{"number":%s,"url":"https://github.com/example-org/mgfy-os/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[],"baseRefName":"%s"}]' \
    "$1" "$1" "$2" "$1" "$3"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$T/h/state/merge-conductor/pr-state.tsv"; }
label_posts() { grep -c 'labels' "$T/label-adds.txt"; }
queue_asks()  { grep -c '@mergifyio queue' "$T/comments.txt"; }
why() { echo "row $(state_of "$K31") '$(reason_of "$K31")'; log: $(grep -o 'mgfy-os#31.*' "$CLOG" | tail -3 | tr '\n' '|')"; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# setup [vhead] — the incident shape: the builder approved H1, the head is H2,
# a lead MERGE-WITH-NOTES stands on H2, checks green, CLEAN, base main.
setup() {
  : > "$A"; : > "$T/label-adds.txt"; : > "$T/label-removes.txt"; : > "$T/comments.txt"; : > "$T/statuses.txt"
  : > "$T/merges.txt"; : > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/labels"; : > "$T/authority"; : > "$CLOG"
  : > "$T/lane-alerts.txt"
  rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
  rm -rf "$T/h/state/merge-conductor/tick" "$T/h/state/merge-conductor/mergify-asked" "$T/h/state/lead-authority" 2>/dev/null
  echo main > "$T/base"; echo 'completed|success' > "$T/runs"; printf 'src/x.ts\n' > "$T/files"
  mkrec 31 "$H2" "$H1"
  list_row 31 "$H2" main > "$T/list.json"
  printf '{"verdict":"MERGE-WITH-NOTES","source":"lead","id":7,"created_at":"2026-10-01T13:35:00Z","report_url":null,"reviewer":"lead"}' > "$T/verdict"
  echo "${1:-$H2}" > "$T/vhead"
}

# C1 — the incident: exactly one label POST and one @mergifyio queue.
setup
run_tick
[ "$(label_posts)" = 1 ] && ok || bad "C1: exactly one merge-queue label POST (got $(label_posts); $(why))"
[ "$(queue_asks)" = 1 ] && ok || bad "C1: exactly one @mergifyio queue (got $(queue_asks); $(why))"
case "$(state_of "$K31")" in READY|QUEUED) ok ;; *) bad "C1: the row must reach READY or QUEUED ($(why))" ;; esac
grep -q "$K31 LEAD_READY on ${H2:0:8}: a lead MERGE-WITH-NOTES stands on this head" "$CLOG" && ok || bad "C1: one LEAD_READY line ($(why))"
[ ! -s "$T/merges.txt" ] && ok || bad "C1: a Mergify repo is enqueued, never merged directly ($(cat "$T/merges.txt"))"

# C2 — a second tick on the same head: no second label, no second ask.
run_tick
[ "$(label_posts)" = 1 ] && ok || bad "C2: a second tick must not POST the label again (got $(label_posts); $(why))"
[ "$(queue_asks)" = 1 ] && ok || bad "C2: a second tick must not ask @mergifyio queue again (got $(queue_asks); $(why))"
[ "$(grep -c 'LEAD_READY' "$CLOG")" = 1 ] && ok || bad "C2: LEAD_READY is said once per head (got $(grep -c LEAD_READY "$CLOG"))"

# C3 — a protected path: no rebind, no enqueue, not READY.
setup
printf 'src/x.ts\nprotected/rule.md\n' > "$T/files"
run_tick
[ "$(label_posts)" = 0 ] && ok || bad "C3: a protected path must get no label (got $(label_posts); $(why))"
[ "$(queue_asks)" = 0 ] && ok || bad "C3: a protected path must get no @mergifyio queue (got $(queue_asks))"
case "$(state_of "$K31")" in READY|QUEUED) bad "C3: a protected path must not read READY ($(why))" ;; *) ok ;; esac
grep -q LEAD_READY "$CLOG" && bad "C3: no LEAD_READY on a protected path" || ok
grep -q 'files?per_page=100&page=1' "$T/gh-calls.txt" && ok || bad "C3: la_decide must have read the PR's files to find the protected path"

# C3b — the lane authority revoked for the repo: the same as protected.
setup
echo human > "$T/authority"
run_tick
[ "$(label_posts)" = 0 ] && [ "$(queue_asks)" = 0 ] && ok || bad "C3b: a revoked authority must get no enqueue (labels $(label_posts), asks $(queue_asks); $(why))"

# C4 — stacked on a feature branch: STACKED_WAIT, nothing posted.
setup
echo ticket/parent > "$T/base"; list_row 31 "$H2" ticket/parent > "$T/list.json"
run_tick
[ "$(state_of "$K31")" = STACKED_WAIT ] && ok || bad "C4: a stacked PR parks STACKED_WAIT ($(why))"
[ "$(label_posts)" = 0 ] && [ "$(queue_asks)" = 0 ] && ok || bad "C4: a stacked PR must get no enqueue (labels $(label_posts), asks $(queue_asks))"

# C5 — red checks: WAIT_CI, nothing posted.
setup
echo 'completed|failure' > "$T/runs"
run_tick
[ "$(state_of "$K31")" = WAIT_CI ] && ok || bad "C5: red checks wait in WAIT_CI ($(why))"
[ "$(label_posts)" = 0 ] && [ "$(queue_asks)" = 0 ] && ok || bad "C5: red checks must get no enqueue (labels $(label_posts), asks $(queue_asks))"

# C6 — the kill switch: today's behavior, no enqueue.
setup
run_tick MC_LEAD_READY=0
[ "$(label_posts)" = 0 ] && [ "$(queue_asks)" = 0 ] && ok || bad "C6: MC_LEAD_READY=0 must not enqueue (labels $(label_posts), asks $(queue_asks); $(why))"
grep -q LEAD_READY "$CLOG" && bad "C6: and say nothing" || ok

# C7 — the lead row stands on an OLDER head, not the live one.
setup "$H1"
run_tick
[ "$(label_posts)" = 0 ] && [ "$(queue_asks)" = 0 ] && ok || bad "C7: a lead MERGE on an older head must not enqueue the live one (labels $(label_posts), asks $(queue_asks); $(why))"

# C9 — the conductor already spawned a detached re-review of this head (it does
#      the moment a moved head goes green) and the job is still running when
#      the lead MERGE lands. The BH-764 autopilot arm is never asked while a job
#      runs, so before BH-3778 the PR sat in HEAD_MOVED "REREVIEWING" tick after
#      tick. The lead row now enqueues it on the first tick, both ticks once.
setup
sleep 600 & RRPID=$!
mkdir -p "$T/h/state/merge-conductor/rereview"
printf '{"status":"running","pid":%s,"started_at":%s}\n' "$RRPID" "$(date -u +%s)" \
  > "$T/h/state/merge-conductor/rereview/example-org_mgfy-os_31_$H2.json"
run_tick
[ "$(label_posts)" = 1 ] && [ "$(queue_asks)" = 1 ] && ok || bad "C9: a lead MERGE on a head under a running re-review must enqueue once (labels $(label_posts), asks $(queue_asks); $(why))"
run_tick
[ "$(label_posts)" = 1 ] && [ "$(queue_asks)" = 1 ] && ok || bad "C9: and a second tick adds nothing (labels $(label_posts), asks $(queue_asks); $(why))"
kill "$RRPID" 2>/dev/null; wait "$RRPID" 2>/dev/null
rm -rf "$T/h/state/merge-conductor/rereview"

# C8 — D2: the production call site is what does it. A scratch conductor with
#      the call removed leaves C1 unenqueued.
cp "$T/h/bin/merge-conductor.sh" "$T/mc.orig"
grep -qF '&& mc_lead_ready "$KEY"' "$T/mc.orig" || bad "C8: the conductor has no mc_lead_ready call to remove"
sed 's/&& mc_lead_ready "\$KEY".*; then$/\&\& false; then/' "$T/mc.orig" > "$T/h/bin/merge-conductor.sh"
bash -n "$T/h/bin/merge-conductor.sh" || bad "C8: the mutated conductor does not parse"
setup
run_tick
[ "$(label_posts)" = 0 ] && ok || bad "C8: with the call site removed C1 still enqueued — the suite is not pinning the conductor (got $(label_posts))"
cp "$T/mc.orig" "$T/h/bin/merge-conductor.sh"

echo "merge-conductor-lead-ready.bh-3778: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
