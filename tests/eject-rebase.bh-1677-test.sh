#!/bin/bash
# tests/eject-rebase.bh-1677-test.sh — BH-1669.1 (BH-1677): a PR Mergify ejected
# for a BASE-BRANCH CONFLICT is rebased, not struck.
#
# THE CASCADE THIS ENDS. Each Mergify ejection was a strike. A PR that conflicts
# with the base is ejected, a later push or rebase puts it back, the base moves
# again and it is ejected again on its new head: two strikes, the row parks
# `queue-ejected-twice`, bin/blocked-resolver.sh rebuilds it from scratch, and
# with the tick's MC_REBASE_BUDGET spent the DIRTY PR meanwhile sits in
# NEEDS_REBASE with nobody rebasing it.
#
# WHAT IS PINNED.
#   §1  Mergify's newest `## Reason` naming a base conflict marks the (PR, head)
#       `ejectconflict` once and logs EJECTED_CONFLICT.
#   §2  seven inputs that must NOT mark (the ticket's six plus a Summary section).
#   §3  that head gets ONE rebase outside MC_REBASE_BUDGET, mark-first; the cap
#       refusal, the pool outage and observe-merge mode each spend nothing.
#   §4  a textual conflict still parks conflict-unresolvable, and never loops.
#   §5  the rebased head is audited (job_ledger_put + EJECT_REBASED) and walks
#       the ordinary READY path into the queue exactly once — whether GitHub
#       already lists the pushed head (§5) or the tick reads the job first (§5b).
#   §6  MC_EJECT_REBASE=0 is today: no marks, no spawn, two ejections park.
#   §7  THE REPRODUCTION: two conflict ejections on two heads do not park.
#
# Every section drives the REAL bin/merge-conductor.sh tick against a stub gh,
# a stub git and a stub jobs client, and asserts what the tick WROTE:
# attempts.txt, pr-state.tsv, logs/merge-conductor.log, the rebase job files,
# the stub's recorded writes and the stub ledger's argv. One clock read (NOW).
# Run from anywhere: tests/eject-rebase.bh-1677-test.sh   (exit 0 = all pass)
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
command -v jq    >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
NOW=$(date -u +%s)

SLUG=example-org/demo-os
K="$SLUG#21"
U="https://github.com/$SLUG/pull/21"
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
N1=9999999999999999999999999999999999999999

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos"
for f in gh-pr-list.sh merge-conductor-lib.sh gh-budget.sh gh-rest.sh gh-rest-var.sh gh-rest-list.sh; do
  cp "$DIR/bin/lib/$f" "$T/h/bin/lib/" || exit 1
done
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"
chmod +x "$T/h/bin/agent-call.sh"
# The jobs client: the approval rebind succeeds, every ledger write is RECORDED
# as argv, and the pool queue is up only while $T/pool-up exists.
cat > "$T/h/bin/jobs-client.sh" <<EOF
job_verdict_rebind() { return 0; }
job_ledger_put() { printf '%s\n' "\$*" >> "$T/ledger.txt"; return 0; }
queue_put() { [ -e "$T/pool-up" ] || return 1; printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
EOF

# ── the stub git: what the DETACHED rebase job runs ─────────────────────────
# rev-parse answers the head the job was spawned for on its first call and the
# pushed head after that; $T/ctl-conflict makes the merge leave an unmerged path.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *--version*) echo "git version 2.45.0"; exit 0 ;;
  *ls-remote*) echo "0000000000000000000000000000000000000000	HEAD"; exit 0 ;;
  *"merge --abort"*) exit 0 ;;
  *" merge "*) sleep "\${FAKE_GIT_MERGE_SLEEP:-0}"; [ -e "$T/ctl-conflict" ] && exit 1; exit 0 ;;
  *"--diff-filter=U"*) [ -e "$T/ctl-conflict" ] && echo "src/x.ts"; exit 0 ;;
  *"rev-parse HEAD"*)
    if [ -e "$T/rev2" ]; then echo "$N1"; else touch "$T/rev2"; cat "$T/ctl-head"; fi; exit 0 ;;
  *push*) touch "$T/pushed"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"

# ── the stub gh ──────────────────────────────────────────────────────────────
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\n' "$T" "$MGFY_YML" "$SLUG"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  # Mergify's comments on the PR: the fixture list, or an unreadable read.
  *"api -i -X GET repos/$SLUG/issues/21/comments"*)
    case "$(cat "$T/cmtmode" 2>/dev/null || echo ok)" in
      403) restpr --raw 403 '{"message":"Resource not accessible by integration"}' ;;
      000) echo "gh: error connecting to api.github.com" >&2; exit 1 ;;
      *)   restpr --raw 200 "$(cat "$T/comments.json" 2>/dev/null || echo '[]')" ;;
    esac ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -X DELETE repos/"*"/labels/"*)
    L=$(sed -n 's|.*/labels/\([^ ]*\).*|\1|p' <<<"$*")
    grep -vxF "$L" "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments-posted.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    restpr OPEN "$(cat "$T/ctl-head")" ticket/TK-21 main "$LBL" "$(cat "$T/ctl-mg")" "$(cat "$T/ctl-ms")" operator ;;
  # The list carries the PR's labels as they are NOW, so a label the tick wrote
  # is one the next tick reads.
  *"pr list -R $SLUG --state open"*)
    jq -c --argjson l "$(jq -R -s -c 'split("\n")|map(select(length>0))|map({name:.})' "$T/labels")" \
      'map(.labels = $l)' "$T/list.json" ;;
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
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
ST="$T/h/state/merge-conductor"
A="$ST/attempts.txt"
LOG="$T/h/logs/merge-conductor.log"
REC="$T/h/builds/demo-os-TK-21-2026092300021"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ── fixtures ────────────────────────────────────────────────────────────────
# Mergify's dequeue comment, trimmed the way tests/conductor-dequeue-surface-test.sh
# trims its real project-5 bodies: the status list, the conditions checklist,
# then `## Reason` and `## Hint`.
CONFLICT_CMT='# Merge Queue Status\n\n- ✅ **Entered queue** — `2026-09-23 06:51 UTC` · Rule: `default`\n- 🚫 **Left the queue** — `2026-09-23 07:35 UTC` · at `1111111111111111111111111111111111111111`\n\n<details>\n<summary>All conditions</summary>\n\n- [X] `check-success = "Build + Unit tests"`\n- [X] `#-conflict = 0`\n\n</details>\n\n## Reason\n\nThe pull request conflicts with the base branch: it became a base branch conflict after #12 merged\n\n## Hint\n\nYou should update or rebase your pull request manually. If you do, this pull request will automatically be requeued once the queue conditions match again.\n'
CHECKLIST_CMT='# Merge Queue Status\n\n- 🚫 **Left the queue** — `2026-09-23 07:35 UTC`\n\n<details>\n<summary>All conditions</summary>\n\n- [X] `#-conflict = 0`\n- [ ] `check-success = "Build + Unit tests"`\n\n</details>\n\n## Reason\n\nThe merge conditions cannot be satisfied: a required check failed\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n'
TIMEOUT_CMT='# Merge Queue Status\n\n- ❌ **Checks timed out (attempt 2/2)** · on draft #2041\n\n## Reason\n\nThe merge conditions cannot be satisfied: the checks did not pass within the automatic checks timeout of 24 minutes 14 seconds, derived from this queue recent CI runtime\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n'
REVIEW_CMT='# Merge Queue Status\n\n- 🚫 **Left the queue** — `2026-09-18 08:47 UTC`\n\n## Reason\n\nPull request #21 has been dequeued\n\nmerge conditions no longer match. Blocked by:\n\n> - `github-review-approved`\n\n## Hint\n\nYou should look at the reason for the failure and decide if the pull request needs to be fixed.\n'
FAILED_CMT='# Merge Queue Status\n\n- ❌ **Checks failed** · on draft #2031\n\n## Reason\n\nThe merge conditions cannot be satisfied: the checks failed\n\n## Hint\n\nYou may have to fix your CI before adding the pull request to the queue again.\n'
SUMMARY_CMT='## Summary\n\nThis pull request conflicts with the base branch, a base branch conflict Mergify noticed earlier.\n\n## Reason\n\nThe merge conditions cannot be satisfied: the checks failed\n'
cmts() { # cmts <login> <body> [<login> <body>...]  — oldest first, as the API lists
  local out='[]' i=9000
  while [ $# -ge 2 ]; do
    i=$((i+1))
    out=$(jq -c --argjson id "$i" --arg l "$1" --arg b "$(printf '%b' "$2")" \
      '. + [{id:$id,created_at:"2026-09-23T07:00:00Z",user:{login:$l},body:$b}]' <<<"$out")
    shift 2
  done
  printf '%s' "$out" > "$T/comments.json"; echo ok > "$T/cmtmode"
}
list_row() { # list_row <head> <mergeState> <mergeable> <labels-csv>
  local lbl="[]"
  [ -n "${4:-}" ] && lbl=$(printf '%s' "$4" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":21,"url":"%s","headRefOid":"%s","headRefName":"ticket/TK-21","isDraft":false,"mergeStateStatus":"%s","mergeable":"%s","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}]' \
    "$U" "$1" "$2" "$3" "$lbl" > "$T/list.json"
  echo "$1" > "$T/ctl-head"; echo "$2" > "$T/ctl-ms"; echo "$3" > "$T/ctl-mg"
  : > "$T/labels"; [ -n "${4:-}" ] && printf '%s\n' "$4" | tr ',' '\n' > "$T/labels"
  return 0
}
mkrec() { # mkrec <reviewed-head>
  mkdir -p "$REC"
  echo "PR_CREATED $U" > "$REC/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
}
# queued_at <head> — the row this conductor put in the queue, and the list/PR
# reads that show the queue has let go of it (Mergify's check failed, our label
# still on): the settle pass's ejection.
queued_at() {
  mkrec "$1"
  list_row "$1" CLEAN MERGEABLE merge-queue
  echo failed > "$T/checkmode"
  mc_row_put "$K" QUEUED $((NOW-300)) "$1" "$1" - "in the merge queue" "$U"
}
# dirty_at <head> — after the ejection GitHub reports the conflict.
dirty_at() { list_row "$1" DIRTY CONFLICTING ""; echo none > "$T/checkmode"; }
reset_case() {
  scratch_rm "$ST/rebase"; mkdir -p "$ST/rebase"
  : > "$A"; : > "$LOG"; : > "$ST/pr-state.tsv"; rm -f "$ST/tick"/* 2>/dev/null
  : > "$T/ledger.txt"; : > "$T/queue.txt"; : > "$T/comments-posted.txt"; : > "$T/merges.txt"
  : > "$T/git-argv.txt"; rm -f "$T/rev2" "$T/pushed" "$T/ctl-conflict" "$T/pool-up"
  rm -f "$T/h/flags/fly-pool-app-demo-os" "$T/h/env/demo-os.env"
  touch "$T/h/flags/merge-conductor-merge"
  echo '[]' > "$T/comments.json"; echo ok > "$T/cmtmode"
}
tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_REPOS="$T/repos" \
  MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
  MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
state_of()  { awk -F'\t' -v k="$K" '$1==k {print $2}' "$ST/pr-state.tsv"; }
head_of()   { awk -F'\t' -v k="$K" '$1==k {print $4}' "$ST/pr-state.tsv"; }
reason_of() { awk -F'\t' -v k="$K" '$1==k {print $7}' "$ST/pr-state.tsv"; }
cnt()       { grep -c -- "$1" "$2" 2>/dev/null || true; }
cntx()      { grep -cxF -- "$1" "$2" 2>/dev/null || true; }
jobs_n()    { ls "$ST"/rebase/*.json 2>/dev/null | wc -l | tr -d ' '; }
wait_done() { local f i; for f in "$ST"/rebase/*.json; do [ -f "$f" ] || continue
  for i in $(seq 1 150); do [ "$(jq -r .status "$f" 2>/dev/null)" = done ] && break; sleep 0.2; done; done; }

# ============================================================================
# §1. A base-conflict ejection is marked once per (PR, head)
# ============================================================================
reset_case
queued_at "$H1"
cmts 'mergify[bot]' "$FAILED_CMT" 'mergify[bot]' "$CONFLICT_CMT"
tick
[ "$(cntx "ejectconflict $K $H1" "$A")" = 1 ] && ok \
  || bad "§1: the ejection must be marked ejectconflict once (attempts: $(cat "$A"))"
[ "$(cnt "EJECTED_CONFLICT $K $H1" "$LOG")" = 1 ] && ok \
  || bad "§1: and logged EJECTED_CONFLICT (log: $(grep -o 'demo-os#21.*' "$LOG" | head -5))"
[ "$(cntx "ejected $K $H1" "$A")" = 1 ] && ok || bad "§1: the ejection itself is still recorded (attempts: $(cat "$A"))"
# The same head is put back and ejected again: the mark does not double.
queued_at "$H1"
tick
[ "$(cntx "ejectconflict $K $H1" "$A")" = 1 ] && ok \
  || bad "§1: a second tick on the same head adds no second mark (got $(cntx "ejectconflict $K $H1" "$A"))"
[ "$(cnt "EJECTED_CONFLICT $K" "$LOG")" = 1 ] && ok \
  || bad "§1: nor a second EJECTED_CONFLICT line (got $(cnt "EJECTED_CONFLICT $K" "$LOG"))"

# ============================================================================
# §2. What must NOT read as a base conflict. Each one is a strike, as today.
# ============================================================================
neg() { # neg <label> — the fixture is already in place
  tick
  [ "$(cnt "^ejectconflict " "$A")" = 0 ] && ok || bad "§2 $1: must not mark ejectconflict (attempts: $(cat "$A"))"
  [ "$(cnt "EJECTED_CONFLICT" "$LOG")" = 0 ] && ok || bad "§2 $1: must not log EJECTED_CONFLICT"
  case "$(state_of) $(reason_of)" in
    "WAIT_CI queue-ejected-twice"*) bad "§2 $1: one ejection is one strike, not two" ;;
    "WAIT_CI queue-ejected"*) ok ;;
    *) bad "§2 $1: the row is one strike, WAIT_CI queue-ejected (got $(state_of) '$(reason_of)')" ;;
  esac
}
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$CHECKLIST_CMT"; neg "checklist #-conflict, no conflict Reason"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$TIMEOUT_CMT"; neg "checks timeout"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$REVIEW_CMT"; neg "review dequeue"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT" 'mergify[bot]' "$FAILED_CMT"; neg "older conflict, newest checks failed"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$FAILED_CMT" someone '> This pull request conflicts with the base branch\n\nplease rebase'; neg "a human quoting it"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"; echo 403 > "$T/cmtmode"; neg "comments read 403"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"; echo 000 > "$T/cmtmode"; neg "comments read 000"
reset_case; queued_at "$H1"; cmts 'mergify[bot]' "$SUMMARY_CMT"; neg "Summary section, not Reason"

# ============================================================================
# §3. ONE rebase for that head, outside the tick's rebase budget
# ============================================================================
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
tick MC_REBASE_BUDGET=0 FAKE_GIT_MERGE_SLEEP=4
[ "$(cnt "EJECT_REBASE_SPAWNED $K $H1" "$LOG")" = 1 ] && ok \
  || bad "§3: exactly one EJECT_REBASE_SPAWNED (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -4))"
[ "$(jobs_n)" = 1 ] && ok || bad "§3: exactly one rebase job file (got $(jobs_n))"
[ "$(cnt LAND_REBASE_SPAWNED "$LOG")" = 0 ] && ok || bad "§3: the land arm stays off"
[ "$(cntx "ejectrebase $K $H1" "$A")" = 1 ] && ok || bad "§3: the ejectrebase mark is written (attempts: $(cat "$A"))"
[ "$(cntx "rebase $K $H1" "$A")" = 1 ] && ok || bad "§3: and the head's one rebase is recorded"
[ "$(state_of)" = REBASING ] && ok || bad "§3: the row moves to REBASING (got $(state_of) '$(reason_of)')"
tick MC_REBASE_BUDGET=0
[ "$(cnt "_SPAWNED" "$LOG")" = 1 ] && ok || bad "§3: the second tick spawns nothing (got $(cnt "_SPAWNED" "$LOG"))"
[ "$(jobs_n)" = 1 ] && ok || bad "§3: still one job file (got $(jobs_n))"
wait_done

# §3b. The cap: one rebase already running and MC_LAND_REBASE_PARALLEL=1.
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
mc_rb_write "$ST/rebase/other.json" running "$$" "$NOW" 0 - "$H2" - "$ST/rebase/other.out"
tick MC_REBASE_BUDGET=0 MC_LAND_REBASE_PARALLEL=1
[ "$(cnt "EJECT_REBASE_DEFER" "$LOG")" -ge 1 ] && ok || bad "§3b: the cap refusal is logged EJECT_REBASE_DEFER (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
[ "$(cntx "ejectrebase $K $H1" "$A")" = 0 ] && ok || bad "§3b: a refused spawn leaves no ejectrebase mark (attempts: $(cat "$A"))"
[ "$(cntx "rebase $K $H1" "$A")" = 0 ] && ok || bad "§3b: nor a rebase mark"
[ "$(jobs_n)" = 1 ] && ok || bad "§3b: and no new job file (got $(jobs_n))"
rm -f "$ST/rebase/other.json"
tick MC_REBASE_BUDGET=0 MC_LAND_REBASE_PARALLEL=1 FAKE_GIT_MERGE_SLEEP=2
[ "$(cnt "EJECT_REBASE_SPAWNED $K $H1" "$LOG")" = 1 ] && ok || bad "§3b: the next tick under the cap spawns it"
wait_done

# §3c. The pool path: queue unreachable spends nothing, the next tick spawns.
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
touch "$T/h/flags/fly-pool-app-demo-os"; echo 'REBASE_ON_POOL=1' > "$T/h/env/demo-os.env"
tick MC_REBASE_BUDGET=0
[ "$(cnt "EJECT_REBASE_DEFER" "$LOG")" -ge 1 ] && ok || bad "§3c: pool unreachable is EJECT_REBASE_DEFER (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
[ "$(cntx "ejectrebase $K $H1" "$A")" = 0 ] && ok || bad "§3c: rc 7 leaves no ejectrebase mark (attempts: $(cat "$A"))"
[ "$(cntx "rebase $K $H1" "$A")" = 0 ] && ok || bad "§3c: nor a rebase mark"
touch "$T/pool-up"
tick MC_REBASE_BUDGET=0
[ "$(cnt "EJECT_REBASE_SPAWNED $K $H1" "$LOG")" = 1 ] && ok || bad "§3c: with the pool up the next tick queues it (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
[ "$(wc -l < "$T/queue.txt" | tr -d ' ')" = 1 ] && ok || bad "§3c: one pool queue row (got $(cat "$T/queue.txt"))"
[ "$(cntx "ejectrebase $K $H1" "$A")" = 1 ] && ok || bad "§3c: and the head is marked"
[ "$(state_of)" = REBASING ] && ok || bad "§3c: the row is REBASING (got $(state_of) '$(reason_of)')"
[ "$(cnt " merge " "$T/git-argv.txt")" = 0 ] && ok || bad "§3c: the hub runs no git merge under the pool flag"

# §3d. Merge flag off: say so, spawn nothing.
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
rm -f "$T/h/flags/merge-conductor-merge"
tick MC_REBASE_BUDGET=0
[ "$(cnt "would EJECT_REBASE" "$LOG")" -ge 1 ] && ok || bad "§3d: merge mode off logs 'would EJECT_REBASE' (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
[ "$(jobs_n)" = 0 ] && ok || bad "§3d: and spawns no job (got $(jobs_n))"
[ "$(cntx "ejectrebase $K $H1" "$A")" = 0 ] && ok || bad "§3d: and writes no mark"

# ============================================================================
# §4. A textual conflict still goes to the resolver, and never loops
# ============================================================================
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"; touch "$T/ctl-conflict"
tick MC_REBASE_BUDGET=0
wait_done
tick MC_REBASE_BUDGET=0
[ "$(state_of)" = BLOCKED_HUMAN ] && ok || bad "§4: the row parks BLOCKED_HUMAN (got $(state_of) '$(reason_of)')"
case "$(reason_of)" in conflict-unresolvable*) ok ;; *) bad "§4: with conflict-unresolvable (got '$(reason_of)')" ;; esac
[ "$(cnt "BLOCKED_AGENT conflict-unresolvable" "$LOG")" = 1 ] && ok || bad "§4: and hands it to the resolver (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
tick MC_REBASE_BUDGET=0; tick MC_REBASE_BUDGET=0; tick MC_REBASE_BUDGET=0
[ "$(cnt "_SPAWNED" "$LOG")" = 1 ] && ok || bad "§4: three more ticks spawn nothing more (got $(cnt "_SPAWNED" "$LOG"))"

# ============================================================================
# §5. The rebased head is audited and re-enters the queue by the ordinary path
# ============================================================================
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
echo "ejectrebase $K $H1" >> "$A"; echo "rebase $K $H1" >> "$A"
mc_transition "$K" REBASING "REBASING ${H1:0:8} (detached rebase spawned)" "$H1" "$H1" "$U" APPROVE DIRTY "$REC" >/dev/null
JF=$(mc_rb_file "$SLUG" 21 "$H1"); printf '%s' "$N1" > "${JF%.json}.out"
mc_rb_write "$JF" done 0 "$NOW" "$NOW" 0 "$H1" "$N1" "${JF%.json}.out"
# The job pushed N1 and its rebind moved the approval onto it.
mkrec "$N1"; list_row "$N1" CLEAN MERGEABLE ""; echo running > "$T/checkmode"
tick
[ "$(cnt "EJECT_REBASED $K ${H1:0:8} -> ${N1:0:8}" "$LOG")" = 1 ] && ok \
  || bad "§5: the consume logs EJECT_REBASED (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -4))"
[ "$(cntx "rebase $U@$N1 REBASED rebased_after_ejection=1 from=${H1:0:8}" "$T/ledger.txt")" = 1 ] && ok \
  || bad "§5: and writes the ledger row (ledger: $(grep '^rebase ' "$T/ledger.txt"))"
[ "$(head_of)" = "$N1" ] && ok || bad "§5: the row is on the pushed head (got $(head_of))"
tick; tick; tick
[ "$(cnt "@mergifyio" "$T/comments-posted.txt")" = 1 ] && ok \
  || bad "§5: the ordinary READY path enqueues exactly once (posted: $(cat "$T/comments-posted.txt"))"
[ "$(state_of)" = QUEUED ] && ok || bad "§5: and the row is QUEUED (got $(state_of) '$(reason_of)')"
[ "$(cnt "EJECT_REBASED" "$LOG")" = 1 ] && ok || bad "§5: the audit is written once (got $(cnt "EJECT_REBASED" "$LOG"))"
[ "$(cnt "^rebase " "$T/ledger.txt")" = 1 ] && ok || bad "§5: one rebase ledger row (got $(grep '^rebase ' "$T/ledger.txt"))"

# §5b. The same audit when the tick reads the finished job ITSELF: GitHub still
#      lists the old head, so rebase_consume applies the result.
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
dirty_at "$H1"
echo "ejectrebase $K $H1" >> "$A"; echo "rebase $K $H1" >> "$A"
mc_transition "$K" REBASING "REBASING ${H1:0:8} (detached rebase spawned)" "$H1" "$H1" "$U" APPROVE DIRTY "$REC" >/dev/null
JF=$(mc_rb_file "$SLUG" 21 "$H1"); printf '%s' "$N1" > "${JF%.json}.out"
mc_rb_write "$JF" done 0 "$NOW" "$NOW" 0 "$H1" "$N1" "${JF%.json}.out"
mkrec "$N1"
tick
grep -q "$K rebased: pushed ${N1:0:8} over ${H1:0:8}" "$LOG" && ok \
  || bad "§5b: rebase_consume applies the job (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -3))"
[ "$(cnt "EJECT_REBASED $K ${H1:0:8} -> ${N1:0:8}" "$LOG")" = 1 ] && ok || bad "§5b: and audits it EJECT_REBASED"
[ "$(cntx "rebase $U@$N1 REBASED rebased_after_ejection=1 from=${H1:0:8}" "$T/ledger.txt")" = 1 ] && ok \
  || bad "§5b: with the ledger row (ledger: $(grep '^rebase ' "$T/ledger.txt"))"
list_row "$N1" CLEAN MERGEABLE ""; echo running > "$T/checkmode"
tick; tick
[ "$(cnt "EJECT_REBASED" "$LOG")" = 1 ] && [ "$(cnt "^rebase " "$T/ledger.txt")" = 1 ] && ok \
  || bad "§5b: once, not again when the list catches up (log $(cnt "EJECT_REBASED" "$LOG"), ledger $(cnt "^rebase " "$T/ledger.txt"))"
[ "$(cnt "@mergifyio" "$T/comments-posted.txt")" = 1 ] && ok \
  || bad "§5b: and it re-enters the queue once (posted: $(cat "$T/comments-posted.txt"))"

# ============================================================================
# §6. MC_EJECT_REBASE=0 is today's conductor
# ============================================================================
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick MC_EJECT_REBASE=0
[ "$(cnt "^ejectconflict " "$A")" = 0 ] && ok || bad "§6: no ejectconflict mark at 0 (attempts: $(cat "$A"))"
# The operator set 0 AFTER marks were written: those marks buy nothing either.
echo "ejectconflict $K $H1" >> "$A"
dirty_at "$H1"
tick MC_EJECT_REBASE=0 MC_REBASE_BUDGET=0
[ "$(cnt "^ejectrebase " "$A")" = 0 ] && ok || bad "§6: no ejectrebase mark at 0"
[ "$(jobs_n)" = 0 ] && ok || bad "§6: and no rebase with the budget spent (got $(jobs_n) job files)"
queued_at "$H2"
echo "ejectconflict $K $H2" >> "$A"
tick MC_EJECT_REBASE=0
[ "$(state_of)" = BLOCKED_HUMAN ] && [ "$(reason_of)" = queue-ejected-twice ] && ok \
  || bad "§6: two conflict ejections at 0 park queue-ejected-twice, as today (got $(state_of) '$(reason_of)')"
# ...and a rebase that finishes after the flip is not audited as one.
reset_case
dirty_at "$H1"; mkrec "$H1"
echo "ejectrebase $K $H1" >> "$A"; echo "rebase $K $H1" >> "$A"
mc_transition "$K" REBASING "REBASING ${H1:0:8} (detached rebase spawned)" "$H1" "$H1" "$U" APPROVE DIRTY "$REC" >/dev/null
JF=$(mc_rb_file "$SLUG" 21 "$H1"); printf '%s' "$N1" > "${JF%.json}.out"
mc_rb_write "$JF" done 0 "$NOW" "$NOW" 0 "$H1" "$N1" "${JF%.json}.out"
mkrec "$N1"
tick MC_EJECT_REBASE=0
grep -q "$K rebased: pushed ${N1:0:8}" "$LOG" && ok || bad "§6: the finished rebase is still applied at 0 (log: $(grep -o 'demo-os#21.*' "$LOG" | tail -2))"
[ "$(cnt "EJECT_REBASED" "$LOG")" = 0 ] && [ "$(cnt "^rebase " "$T/ledger.txt")" = 0 ] && ok \
  || bad "§6: but writes no EJECT_REBASED audit at 0 (ledger: $(grep '^rebase ' "$T/ledger.txt"))"

# ============================================================================
# §7. THE REPRODUCTION: two base-conflict ejections on two heads are no strike
# ============================================================================
reset_case
queued_at "$H1"; cmts 'mergify[bot]' "$CONFLICT_CMT"
tick
queued_at "$H2"
tick
[ "$(cntx "ejected $K $H2" "$A")" = 1 ] && ok || bad "§7: the second ejection is recorded (attempts: $(cat "$A"))"
[ "$(reason_of)" != queue-ejected-twice ] && ok \
  || bad "§7: two base-conflict ejections must not park queue-ejected-twice (got $(state_of) '$(reason_of)')"
# The next tick reads the READY arm's strike count on the ejected head.
tick
[ "$(reason_of)" != queue-ejected-twice ] && ok \
  || bad "§7: nor on the tick after, through the READY arm's count (got $(state_of) '$(reason_of)')"

echo "eject-rebase.bh-1677: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
