#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/mc-stack-fast.bh-5520-test.sh — BH-5520 Task 5: a stacked child whose
# parent is already QUEUED (approved on its head, in the Mergify queue) is
# retargeted to the project base in the same tick, classifies READY and is
# enqueued right behind the parent. When the parent leaves the queue unmerged
# the conductor revokes it: our label off, `@mergifyio dequeue` with the
# conductor's own tag, and the base moved back onto the parent's branch.
#
#   F1  one whole bin/merge-conductor.sh tick: PATCH base=main, THEN the child's
#       enqueue, in the same tick; the mark file; the STACK_FAST log line.
#   F2  parent row READY (not queued): the same whole tick, no PATCH, the child
#       row stays STACKED_WAIT.
#   F3  parent QUEUED but its head moved after review (col4 != col5): no PATCH.
#   F4  child verdict on an older head; child CI pending; child REQUEST_CHANGES;
#       a DIRTY child; a parent tip not in the child: no PATCH.
#   F5  merge_method=squash, or no conf: no PATCH, MSF_WHY names the method.
#   F6  MC_STACK_FAST=0: no PATCH. Observe mode: `WOULD STACK_FAST`, no PATCH.
#   F7  revoke: attempt line, label DELETE, `@mergifyio dequeue` + tag, PATCH
#       back, in that order; mark gone; a second call on the same head posts no
#       second comment. A refused PATCH keeps the mark. Observe mode writes
#       nothing. A QUEUED parent keeps the mark.
#   F8  parent merged: no writes, mark deleted. Unreadable read (exit 75): no
#       writes, mark kept. msf_sweep drops only marks past the TTL.
#   F9  (lead BLOCK on f6f879ef, the iron-law case) the merge guard is
#       Mergify's, not the tick's: the child's body carries `Depends-On: #71`
#       BEFORE the base PATCH and the enqueue, so a parent that Mergify
#       dequeues between two ticks cannot merge under the child. A body that
#       cannot be read or written means no base PATCH and no mark; a body that
#       already holds the line is not written again.
#   F10 (lead BLOCK on 95d38af8, whole ticks) a CLOSED parent whose branch
#       refuses the PATCH back: the child is parked BLOCKED_HUMAN on the
#       resolver-owned `orphaned-child` reason, its Depends-On line comes off,
#       and it is never enqueued, on that tick or the next one (after the mark
#       is gone, which is where the sweep left it before this fix).
#   F11 (lead BLOCK on 95d38af8) the Depends-On line comes off: after a revoke,
#       and after a retarget whose base PATCH failed. A removal that fails is
#       owed (<mark>.depoff) and lands on the next msf_depends_settle; observe
#       mode keeps it owed; a new retarget cancels it.
#
# F2-F8 source bin/lib/mc-stack-fast.sh on the fixture harness; F1 and F2
# drive the real tick (D2), so deleting the conductor's hook turns F1 red.
# Run from anywhere: tests/mc-stack-fast.bh-5520-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: bin/merge-conductor.sh bin/lib/mc-stack-fast.sh

SLUG=example-org/demo-os
NOW=2000000000
PH=dddd0071dddddddddddddddddddddddddddddddd      # the parent's head (= its reviewed sha)
PH_OLD=cccc0071cccccccccccccccccccccccccccccccc  # an older parent head
H72=bbbb0072bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb     # the child's head
H72_OLD=aaaa0072aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PURL="https://github.com/$SLUG/pull/71"
CURL72="https://github.com/$SLUG/pull/72"

# ── the scratch harness ──────────────────────────────────────────────────────
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"
fx_mc_harness "$DIR" "$T" || exit 1
# The scripts this suite drives. Not fx_conductor_tick: its ticket-ownership
# lib adds the BH-1606 lead fence, whose lead row this fixture has no worker for.
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
mkdir -p "$T/h/tmp" "$T/h/config/mergify/repos" "$T/repos"
LIBOK=1
scratch_install_closure bin/lib/mc-stack-fast.sh "$T/h" >/dev/null 2>&1 || LIBOK=0
[ -f "$T/h/bin/lib/mc-stack-fast.sh" ] || LIBOK=0
[ "$LIBOK" = 1 ] && ok || bad "bin/lib/mc-stack-fast.sh could not be installed (it does not exist yet?)"

printf 'demo %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
CONF="$T/h/config/mergify/repos/demo.conf"
conf_merge()  { printf 'slug=%s\nqueue_mode=fixture\nmerge_method=merge\n' "$SLUG" > "$CONF"; }
conf_squash() { printf 'slug=%s\nqueue_mode=fixture\nmerge_method=squash\n' "$SLUG" > "$CONF"; }
conf_merge

# The child's build record: APPROVE bound to H72.
REC="$T/h/builds/demo-DM-2-202610110001"; mkdir -p "$REC"
echo "PR_CREATED $CURL72" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H72" > "$REC/reviewed-sha"
: > "$REC/pipeline.log"

MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: merge\n' | base64 | tr -d '\n')

# gh: every argv to gh.log; every WRITE also to events.txt, in order. The
# DELETE arm records whether the revoke's attempt line was already on disk.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
LBL=\$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,\$//')
case "\$*" in
  *"auth token"*) echo tok-fixture-1 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/"*"/commits/$H72/check-runs"*)
    if grep -qx merge-queue "$T/labels" 2>/dev/null; then
      restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}'
    else restpr --raw 200 '{"check_runs":[]}'; fi ;;
  *"api -X PATCH repos/$SLUG/pulls/72 -f base="*)
    printf 'PATCH %s\n' "\$*" >> "$T/events.txt"
    [ -f "$T/patch-fails" ] && exit 1
    A="\$*"; printf '%s' "\${A##*base=}" > "$T/child-base"; exit 0 ;;
  *"api repos/$SLUG/pulls/72 --jq"*)
    [ -f "$T/body-read-fails" ] && exit 1
    cat "$T/child-body" ;;
  *"api -X PATCH repos/$SLUG/pulls/72 -F body=@"*)
    printf 'BODY %s\n' "\$*" >> "$T/events.txt"
    [ -f "$T/body-patch-fails" ] && exit 1
    A="\$*"; cp "\${A##*body=@}" "$T/child-body"; exit 0 ;;
  *"api -X PATCH repos/"*) printf 'OTHERPATCH %s\n' "\$*" >> "$T/events.txt"; exit 0 ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    printf 'LABEL %s\n' "\$*" >> "$T/events.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels" ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/"*)
    printf 'DELETE attempt-on-disk=%s %s\n' "\$(grep -c '^stackfast-revoke ' "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null)" "\$*" >> "$T/events.txt"
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*)
    printf 'COMMENT %s\n' "\$(printf '%s' "\$*" | tr '\n' '|')" >> "$T/events.txt" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf 'ICOMMENT %s\n' "\$*" >> "$T/events.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*)
    printf 'IPATCH %s\n' "\$*" >> "$T/events.txt"; restpr --raw 200 '{"state":"closed"}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/72"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/72"*)
    restpr OPEN "$H72" ticket/demo-2 "\$(cat "$T/child-base")" "\$LBL" MERGEABLE CLEAN app/cromford ;;
  *"api -i -X GET repos/$SLUG/pulls/71"*)
    case "\$(cat "$T/parent-state")" in
      fail75) exit 75 ;;
      merged) restpr MERGED "$PH" ticket/demo-1 main "" MERGEABLE CLEAN app/cromford eeee0071 ;;
      closed) restpr CLOSED "$PH" ticket/demo-1 main "" MERGEABLE CLEAN app/cromford ;;
      *)      restpr OPEN   "$PH" ticket/demo-1 main "merge-queue,queued" MERGEABLE CLEAN app/cromford ;;
    esac ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=all -f head=example-org:ticket/demo-1 "*)
    restpr --raw 200 '[{"state":"open","merged_at":null,"html_url":"$PURL"}]' ;;
  *"api -i -X GET repos/"*"/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  *"pr list -R $SLUG --state open"*)
    printf '[{"number":72,"url":"$CURL72","headRefOid":"$H72","headRefName":"ticket/demo-2","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isCrossRepository":false,"isInMergeQueue":false,"labels":[],"baseRefName":"%s"}]\n' "\$(cat "$T/child-base")" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# git: only what mc_stack_parent_moved asks. The parent tip is in the child's
# history unless $T/not-ancestor exists.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/git.log"
SUB=""
while [ \$# -gt 0 ]; do
  case "\$1" in -C) shift 2 ;; -c) shift 2 ;; *) SUB="\$1"; shift; break ;; esac
done
case "\$SUB" in
  clone) for a in "\$@"; do case "\$a" in /*) mkdir -p "\$a/.git" ;; esac; done; exit 0 ;;
  rev-parse)
    for a in "\$@"; do
      case "\$a" in
        origin/ticket/demo-1*) echo "$PH"; exit 0 ;;
        origin/ticket/demo-2*) echo "$H72"; exit 0 ;;
      esac
    done
    exit 1 ;;
  merge-base) [ -f "$T/not-ancestor" ] && exit 1; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/fakebin/git"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"not found"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
LOG="$T/h/logs/merge-conductor.log"
MARK="$T/h/state/merge-conductor/stack-fast/example-org__demo-os#72"
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
# parent_row <state> <head> <reviewed> — the parent's conductor row, written
# with the lib's own row writer (key state since head reviewed alerted reason url).
parent_row() {
  ( . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
    mc_row_put "$SLUG#71" "$1" "$NOW" "$2" "$3" 0 "fixture parent row" "$PURL" ) >/dev/null 2>&1
}
reset_fx() {
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs" "$T/h/locks" "$T/h/tmp"
  mkdir -p "$T/h/logs" "$T/h/locks" "$T/h/tmp" "$T/h/state/merge-conductor"
  : > "$T/events.txt"; : > "$T/gh.log"; : > "$T/git.log"; : > "$T/labels"
  rm -f "$T/patch-fails" "$T/not-ancestor" "$T/body-read-fails" "$T/body-patch-fails"
  printf 'Child PR body\nRefs #2\n' > "$T/child-body"
  echo ticket/demo-1 > "$T/child-base"; echo open > "$T/parent-state"
  conf_merge
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x GH_LIST_BRIDGE_ROOT="$T" \
  MC_REPOS="$T/repos" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_KICK_REOPEN_SLEEP=0 MC_PR_PARALLEL=1 "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"

# ============================================================================
# F1 (acceptance 3). One whole tick: the parent is QUEUED on its reviewed head,
#    the child is APPROVE on its head, green, CLEAN, on ticket/demo-1, and the
#    parent tip is in its history. PATCH base=main, THEN the enqueue.
# ============================================================================
reset_fx; parent_row QUEUED "$PH" "$PH"
run_tick
PL=$(grep -n "^PATCH .*pulls/72 -f base=main" "$T/events.txt" | head -1 | cut -d: -f1)
QL=$(grep -nE "^(LABEL .*issues/72/labels|COMMENT .*issues/72/comments.*@mergifyio queue)" "$T/events.txt" | head -1 | cut -d: -f1)
[ -n "$PL" ] && ok || bad "F1: the tick must PATCH #72 base=main (events: $(tr '\n' ';' < "$T/events.txt"))"
[ -n "$QL" ] && ok || bad "F1: the tick must enqueue #72 in the same tick (events: $(tr '\n' ';' < "$T/events.txt"); row $(state_of "$SLUG#72"))"
[ -n "$PL" ] && [ -n "$QL" ] && [ "$PL" -lt "$QL" ] && ok || bad "F1: the PATCH must come BEFORE the enqueue (patch line ${PL:-none}, enqueue line ${QL:-none})"
[ -s "$MARK" ] && ok || bad "F1: the mark file must exist after the retarget"
MB=""; MPN=""; MPH=""; MEP=""; [ -s "$MARK" ] && IFS=$'\t' read -r MB MPN MPH MEP < "$MARK"
[ "${MB:-}" = ticket/demo-1 ] && [ "${MPN:-}" = 71 ] && [ "${MPH:-}" = "$PH" ] && [[ "${MEP:-}" =~ ^[0-9]+$ ]] \
  && ok || bad "F1: the mark must be <baseref>\\t<parent-num>\\t<parent-head>\\t<epoch> (got '${MB:-}' '${MPN:-}' '${MPH:-}' '${MEP:-}')"
grep -q "STACK_FAST $SLUG#72 retargeted ticket/demo-1 -> main behind QUEUED parent #71 (${PH:0:8})" "$LOG" \
  && ok || bad "F1: the conductor log must carry the STACK_FAST line (log: $(grep -i 'stack' "$LOG" | tail -3))"
[ "$(state_of "$SLUG#72")" = QUEUED ] && ok || bad "F1: the child row must be QUEUED after the enqueue (got '$(state_of "$SLUG#72")')"

# F9 (the iron-law case, whole tick). Mergify can dequeue the parent with no
#    conductor action, and the next tick may be 5 minutes away. Nothing in the
#    conductor runs in between, so the only guard is what Mergify itself reads:
#    the child's body must already say `Depends-On: #71` when the child is
#    retargeted and enqueued.
BL=$(grep -n "^BODY .*pulls/72 -F body=@" "$T/events.txt" | head -1 | cut -d: -f1)
[ -n "$BL" ] && ok || bad "F9: the retarget tick must write the child's body (events: $(tr '\n' ';' < "$T/events.txt"))"
[ -n "$BL" ] && [ -n "$PL" ] && [ "$BL" -lt "$PL" ] && ok || bad "F9: the Depends-On body write must come BEFORE the base PATCH (body line ${BL:-none}, patch line ${PL:-none})"
grep -qx 'Depends-On: #71' "$T/child-body" && ok || bad "F9: the child body must hold 'Depends-On: #71' (body: $(tr '\n' '|' < "$T/child-body"))"
grep -q '^Refs #2$' "$T/child-body" && ok || bad "F9: the body write must keep the old body (body: $(tr '\n' '|' < "$T/child-body"))"

# F1 (revoke, whole tick). The next tick finds the parent BLOCKED_HUMAN (it
#    left the queue unmerged). The conductor's revoke hook dequeues the child,
#    moves it back onto ticket/demo-1 and classifies it STACKED_WAIT: no enqueue.
: > "$T/events.txt"
parent_row BLOCKED_HUMAN "$PH" "$PH"
run_tick
grep -q "^DELETE .*issues/72/labels/merge-queue" "$T/events.txt" && ok || bad "F1r: the revoke tick must take our label off (events: $(tr '\n' ';' < "$T/events.txt"))"
grep -q "^COMMENT .*issues/72/comments.*@mergifyio dequeue" "$T/events.txt" && ok || bad "F1r: the revoke tick must post @mergifyio dequeue"
grep -q "^PATCH .*pulls/72 -f base=ticket/demo-1" "$T/events.txt" && ok || bad "F1r: the revoke tick must PATCH the base back onto ticket/demo-1"
grep -qE "^(LABEL |COMMENT .*@mergifyio queue)" "$T/events.txt" && bad "F1r: a revoked child must not be enqueued again" || ok
[ -e "$MARK" ] && bad "F1r: the mark must be gone after the revoke" || ok
[ "$(state_of "$SLUG#72")" = STACKED_WAIT ] && ok || bad "F1r: the revoked child must classify STACKED_WAIT (got '$(state_of "$SLUG#72")')"
grep -q "STACK_FAST_REVOKED $SLUG#72" "$LOG" && ok || bad "F1r: the STACK_FAST_REVOKED line"
grep -q '^Depends-On: #71' "$T/child-body" && bad "F1r: the revoke must take the Depends-On: #71 line off (body: $(tr '\n' '|' < "$T/child-body"))" || ok

# ============================================================================
# F10. A closed parent whose branch is gone (lead BLOCK on 95d38af8). Tick 1
#      fast-tracks the child; tick 2 finds the parent CLOSED and the PATCH
#      back refused; tick 3 runs with the mark already gone.
# ============================================================================
reset_fx; parent_row QUEUED "$PH" "$PH"
run_tick
[ -s "$MARK" ] && grep -qx 'Depends-On: #71' "$T/child-body" && ok || bad "F10: tick 1 must fast-track the child (mark and Depends-On line)"
: > "$T/events.txt"; echo closed > "$T/parent-state"; parent_row BLOCKED_HUMAN "$PH" "$PH"; touch "$T/patch-fails"
run_tick
grep -q "^PATCH .*pulls/72 -f base=ticket/demo-1" "$T/events.txt" && ok || bad "F10: tick 2 must try the PATCH back (events: $(tr '\n' ';' < "$T/events.txt"))"
grep -qE "^(LABEL |COMMENT .*@mergifyio queue)" "$T/events.txt" && bad "F10: tick 2 must not enqueue the child (events: $(tr '\n' ';' < "$T/events.txt"))" || ok
[ "$(state_of "$SLUG#72")" = BLOCKED_HUMAN ] && ok || bad "F10: tick 2 must park the child BLOCKED_HUMAN (got '$(state_of "$SLUG#72")')"
R10=$(awk -F'\t' -v k="$SLUG#72" '$1==k {print $7}' "$ROWS")
case "$R10" in orphaned-child:*"ticket/demo-1 (parent $PURL closed without merging"*) ok ;; *) bad "F10: the reason must be the resolver-owned orphaned-child with the dead branch and the parent url (got '$R10')" ;; esac
grep -q "BLOCKED_AGENT orphaned-child: STACK_FAST parent #71 closed without merging" "$LOG" && ok || bad "F10: the BLOCKED_AGENT orphaned-child line (log: $(grep -i stack "$LOG" | tail -3))"
grep -q '^Depends-On: #71' "$T/child-body" && bad "F10: the Depends-On: #71 line must come off (body: $(tr '\n' '|' < "$T/child-body"))" || ok
[ -e "$MARK" ] && bad "F10: the mark must be gone once the child is parked" || ok
: > "$T/events.txt"
run_tick
grep -qE "^(LABEL |COMMENT .*@mergifyio queue)" "$T/events.txt" && bad "F10: tick 3 (no mark) must not enqueue the child (events: $(tr '\n' ';' < "$T/events.txt"))" || ok
[ "$(state_of "$SLUG#72")" = BLOCKED_HUMAN ] && ok || bad "F10: tick 3 must keep the child BLOCKED_HUMAN (got '$(state_of "$SLUG#72")')"
rm -f "$T/patch-fails"

# ============================================================================
# F2. The parent row is READY, not queued: the same tick, no PATCH, the child
#     parks STACKED_WAIT.
# ============================================================================
reset_fx; parent_row READY "$PH" "$PH"
run_tick
grep -q "pulls/72 -f base=" "$T/events.txt" && bad "F2: no PATCH for a child of a READY parent ($(cat "$T/events.txt"))" || ok
[ "$(state_of "$SLUG#72")" = STACKED_WAIT ] && ok || bad "F2: the child must stay STACKED_WAIT (got '$(state_of "$SLUG#72")')"
[ -e "$MARK" ] && bad "F2: no mark for a child that was not retargeted" || ok

# ============================================================================
# F3-F8 source the lib on the same fixture tree.
# ============================================================================
if [ "$LIBOK" != 1 ]; then
  bad "F3-F8: skipped, the lib is missing"
  echo "mc-stack-fast.bh-5520-test: $PASS pass, $FAIL fail"
  exit 1
fi
reset_fx
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=bin/lib/mc-stack-fast.sh
. "$T/h/bin/lib/mc-stack-fast.sh" || bad "the lib must source cleanly"
mc_now() { echo "$NOW"; }    # the pinned clock
unset MC_STACK_FAST
# TRY [actions] — the conductor's call, with the F1 inputs unless a variable
# overrides one. rc 0 = retargeted.
TRY() {
  msf_try "$SLUG" demo "$SLUG#72" 72 "$PURL" "$H72" "${REV:-$H72}" "${VER:-APPROVE}" "${CIS:-green}" \
    "${MS:-CLEAN}" "${MG:-MERGEABLE}" ticket/demo-1 ticket/demo-2 main "${1:-1}"
}
nopatch() { ! grep -q "pulls/72 -f base=" "$T/events.txt"; }
fresh() { : > "$T/events.txt"; : > "$LOG"; rm -f "$MARK"; MSF_WHY=""; }

# F3. Parent QUEUED, but col4 (head) != col5 (reviewed).
fresh; parent_row QUEUED "$PH" "$PH_OLD"
TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F3: a QUEUED parent whose head moved after review is not eligible (rc $rc; $(cat "$T/events.txt"))"
case "$MSF_WHY" in *head*) ok ;; *) bad "F3: MSF_WHY must name the parent's head (got '$MSF_WHY')" ;; esac

# F4. The child itself is not ready.
parent_row QUEUED "$PH" "$PH"
fresh; REV=$H72_OLD TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F4a: a verdict on an older child head is not eligible (rc $rc)"
fresh; CIS=pending TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F4b: a child with CI pending is not eligible (rc $rc)"
fresh; VER=REQUEST_CHANGES TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F4c: a child with REQUEST_CHANGES is not eligible (rc $rc)"
fresh; MS=DIRTY MG=CONFLICTING TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F4d: a DIRTY child is not eligible (rc $rc)"
fresh; touch "$T/not-ancestor"; TRY; rc=$?; rm -f "$T/not-ancestor"
[ "$rc" != 0 ] && nopatch && ok || bad "F4e: a parent tip that is not in the child is not eligible (rc $rc)"
fresh; parent_row WAIT_CI "$PH" "$PH"; TRY; rc=$?; parent_row QUEUED "$PH" "$PH"
[ "$rc" != 0 ] && nopatch && ok || bad "F4f: a WAIT_CI parent is not eligible (rc $rc)"

# F5. The merge method.
fresh; conf_squash; TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F5a: a squash repo is never eligible (rc $rc)"
case "$MSF_WHY" in *merge_method*squash*) ok ;; *) bad "F5a: MSF_WHY must name the merge method (got '$MSF_WHY')" ;; esac
fresh; rm -f "$CONF"; TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F5b: a repo with no mergify conf is never eligible (rc $rc)"
case "$MSF_WHY" in *merge_method*) ok ;; *) bad "F5b: MSF_WHY must name the merge method (got '$MSF_WHY')" ;; esac
conf_merge

# F6. The kill knob, and observe mode.
fresh; MC_STACK_FAST=0 TRY; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F6a: MC_STACK_FAST=0 turns the fast path off (rc $rc)"
fresh; TRY 0; rc=$?
[ "$rc" != 0 ] && nopatch && ok || bad "F6b: observe mode writes nothing (rc $rc; $(cat "$T/events.txt"))"
grep -q "WOULD STACK_FAST $SLUG#72" "$LOG" && ok || bad "F6b: observe mode logs WOULD STACK_FAST (log: $(cat "$LOG"))"
[ -e "$MARK" ] && bad "F6b: observe mode writes no mark" || ok
# The control: the same inputs in merge mode do fire (so F3-F6 are not green
# on a lib that never fires).
fresh; TRY; rc=$?
[ "$rc" = 0 ] && grep -q "pulls/72 -f base=main" "$T/events.txt" && [ -s "$MARK" ] \
  && ok || bad "F6c: the eligible control must retarget and mark (rc $rc; $(cat "$T/events.txt"))"
# A refused PATCH writes no mark and no STACK_FAST line.
fresh; touch "$T/patch-fails"; TRY; rc=$?; rm -f "$T/patch-fails"
[ "$rc" != 0 ] && [ ! -e "$MARK" ] && ! grep -q "STACK_FAST $SLUG#72 retargeted" "$LOG" \
  && ok || bad "F6d: a refused PATCH leaves no mark and no STACK_FAST line (rc $rc)"

# F9 (lib). The body guard: no Depends-On line, no retarget.
fresh; touch "$T/body-read-fails"; TRY; rc=$?; rm -f "$T/body-read-fails"
[ "$rc" != 0 ] && nopatch && [ ! -e "$MARK" ] && ok || bad "F9a: an unreadable body means no base PATCH and no mark (rc $rc; $(cat "$T/events.txt"))"
grep -q "STACK_FAST not taken: the Depends-On: #71 line could not be written" "$LOG" && ok || bad "F9a: the refusal is logged (log: $(cat "$LOG"))"
fresh; printf 'Child PR body\n' > "$T/child-body"; touch "$T/body-patch-fails"; TRY; rc=$?; rm -f "$T/body-patch-fails"
[ "$rc" != 0 ] && nopatch && [ ! -e "$MARK" ] && ok || bad "F9b: a refused body PATCH means no base PATCH and no mark (rc $rc; $(cat "$T/events.txt"))"
fresh; printf 'Child PR body\n\nDepends-On: #71\n' > "$T/child-body"; TRY; rc=$?
[ "$rc" = 0 ] && ! grep -q '^BODY ' "$T/events.txt" && grep -q "pulls/72 -f base=main" "$T/events.txt" \
  && ok || bad "F9c: a body that already holds the line is not written again, and the retarget goes out (rc $rc; $(cat "$T/events.txt"))"

# ============================================================================
# F7. Revoke: the parent left the queue unmerged.
# ============================================================================
mkmark() { fresh; msf_retarget "$SLUG" "$SLUG#72" 72 main ticket/demo-1 71 "$PH" >/dev/null 2>&1; : > "$T/events.txt"; : > "$LOG"; }
REVOKE() { MSF_BASE=""; msf_check_revoke "$SLUG" "$SLUG#72" 72 "$CURL72" "$H72" "${1:-1}"; }
ATT="$T/h/state/merge-conductor/attempts.txt"
sed -i '/^stackfast-revoke /d' "$ATT" 2>/dev/null
mkmark
[ -s "$MARK" ] && ok || bad "F7: msf_retarget must write the mark the revoke reads"
parent_row BLOCKED_HUMAN "$PH" "$PH"; echo open > "$T/parent-state"
REVOKE; rc=$?
[ "$rc" = 0 ] && [ "$MSF_BASE" = ticket/demo-1 ] && ok || bad "F7: a revoke answers rc 0 with MSF_BASE=ticket/demo-1 (rc $rc, '$MSF_BASE')"
grep -qx "stackfast-revoke $SLUG#72 $H72" "$ATT" && ok || bad "F7: the attempt line must be written"
DL=$(grep -n "^DELETE attempt-on-disk=1 .*issues/72/labels/merge-queue" "$T/events.txt" | head -1 | cut -d: -f1)
CL=$(grep -n "^COMMENT .*issues/72/comments.*body=@mergifyio dequeue|.*<!-- mc:crdequeue -->" "$T/events.txt" | head -1 | cut -d: -f1)
BL=$(grep -n "^PATCH .*pulls/72 -f base=ticket/demo-1" "$T/events.txt" | head -1 | cut -d: -f1)
[ -n "$DL" ] && ok || bad "F7: the label DELETE must come after the attempt line is on disk (events: $(tr '\n' ';' < "$T/events.txt"))"
[ -n "$CL" ] && ok || bad "F7: a comment whose first line is @mergifyio dequeue and which carries the crdequeue tag (events: $(tr '\n' ';' < "$T/events.txt"))"
[ -n "$BL" ] && ok || bad "F7: the PATCH back onto ticket/demo-1 (events: $(tr '\n' ';' < "$T/events.txt"))"
[ -n "$DL" ] && [ -n "$CL" ] && [ -n "$BL" ] && [ "$DL" -lt "$CL" ] && [ "$CL" -lt "$BL" ] \
  && ok || bad "F7: the order is label DELETE, comment, PATCH (lines ${DL:-?} ${CL:-?} ${BL:-?})"
[ -e "$MARK" ] && bad "F7: the mark must be gone after the PATCH back" || ok
grep -q "STACK_FAST_REVOKED $SLUG#72 parent #71 left the queue unmerged" "$LOG" && ok || bad "F7: the STACK_FAST_REVOKED line (log: $(cat "$LOG"))"
grep -q '^Depends-On: #71' "$T/child-body" && bad "F7: the revoke must take the Depends-On: #71 line off (body: $(tr '\n' '|' < "$T/child-body"))" || ok
grep -q '^Child PR body$' "$T/child-body" && ok || bad "F7: the removal must keep the rest of the body (body: $(tr '\n' '|' < "$T/child-body"))"
[ -e "$MARK.depoff" ] && bad "F7: a removal that landed owes nothing" || ok
# A second revoke of the same head posts no second comment.
mkmark; parent_row BLOCKED_HUMAN "$PH" "$PH"
REVOKE >/dev/null; REVOKE >/dev/null
[ "$(grep -c '^COMMENT ' "$T/events.txt")" = 0 ] && ok || bad "F7: a second revoke on the same head posts no second comment ($(cat "$T/events.txt"))"
[ "$(grep -c '^stackfast-revoke ' "$ATT")" = 1 ] && ok || bad "F7: exactly one attempt line per head"
# A closed parent revokes too.
sed -i '/^stackfast-revoke /d' "$ATT"
mkmark; parent_row QUEUED "$PH" "$PH"; echo closed > "$T/parent-state"
REVOKE; rc=$?
[ "$rc" = 0 ] && grep -q "^PATCH .*base=ticket/demo-1" "$T/events.txt" && ok || bad "F7: a CLOSED parent revokes (rc $rc; $(cat "$T/events.txt"))"
# A refused PATCH back keeps the mark (the next tick retries it).
sed -i '/^stackfast-revoke /d' "$ATT"
mkmark; parent_row BLOCKED_HUMAN "$PH" "$PH"; echo open > "$T/parent-state"; touch "$T/patch-fails"
REVOKE; rc=$?; rm -f "$T/patch-fails"
[ "$rc" != 0 ] && [ -s "$MARK" ] && ok || bad "F7: a refused PATCH back keeps the mark (rc $rc)"
grep -q STACK_FAST_REVOKED "$LOG" && bad "F7: no STACK_FAST_REVOKED before the PATCH back answered rc 0" || ok
# Observe mode: WOULD revoke, nothing written.
sed -i '/^stackfast-revoke /d' "$ATT"
mkmark; parent_row BLOCKED_HUMAN "$PH" "$PH"
REVOKE 0; rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/events.txt" ] && [ -s "$MARK" ] && ok || bad "F7: observe mode writes nothing and keeps the mark (rc $rc; $(cat "$T/events.txt"))"
grep -q "WOULD revoke" "$LOG" && ok || bad "F7: observe mode logs WOULD revoke"
grep -q '^stackfast-revoke ' "$ATT" && bad "F7: observe mode writes no attempt line" || ok
# The parent is still QUEUED: keep the mark, no writes.
mkmark; parent_row QUEUED "$PH" "$PH"; echo open > "$T/parent-state"
REVOKE; rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/events.txt" ] && [ -s "$MARK" ] && ok || bad "F7: a QUEUED open parent keeps the mark (rc $rc)"

# ============================================================================
# F11. The Depends-On line comes off (lead BLOCK on 95d38af8).
# ============================================================================
# A retarget whose base PATCH failed takes back the line it wrote.
fresh; parent_row QUEUED "$PH" "$PH"; echo open > "$T/parent-state"; printf 'Child PR body\nRefs #2\n' > "$T/child-body"
touch "$T/patch-fails"; TRY; rc=$?; rm -f "$T/patch-fails"
[ "$rc" != 0 ] && ! grep -q '^Depends-On: #71' "$T/child-body" && [ ! -e "$MARK.depoff" ] \
  && ok || bad "F11a: a failed base PATCH leaves no Depends-On line and nothing owed (rc $rc; body: $(tr '\n' '|' < "$T/child-body"))"
# A removal that fails is owed, and the next settle lands it.
sed -i '/^stackfast-revoke /d' "$ATT"
mkmark; parent_row BLOCKED_HUMAN "$PH" "$PH"; echo open > "$T/parent-state"; touch "$T/body-patch-fails"
REVOKE; rc=$?; rm -f "$T/body-patch-fails"
[ "$rc" = 0 ] && [ -s "$MARK.depoff" ] && grep -qx 'Depends-On: #71' "$T/child-body" \
  && ok || bad "F11b: a failed removal is owed in <mark>.depoff (rc $rc)"
msf_depends_settle "$SLUG" "$SLUG#72" 72 0; rc=$?
[ "$rc" != 0 ] && [ -s "$MARK.depoff" ] && grep -qx 'Depends-On: #71' "$T/child-body" \
  && ok || bad "F11c: observe mode keeps the removal owed and writes nothing (rc $rc)"
msf_depends_settle "$SLUG" "$SLUG#72" 72 1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$MARK.depoff" ] && ! grep -q '^Depends-On: #71' "$T/child-body" \
  && ok || bad "F11d: the next settle removes the line and drops the debt (rc $rc; body: $(tr '\n' '|' < "$T/child-body"))"
# A new retarget cancels an older owed removal: the line stays. (A new head
# would be retargeted after a revoke; this fixture reuses H72, so the revoke's
# attempt line is cleared first.)
sed -i '/^stackfast-revoke /d' "$ATT"
fresh; parent_row QUEUED "$PH" "$PH"; printf 'depoff\t71\t-\t%s\n' "$NOW" > "$MARK.depoff"
TRY; rc=$?
[ "$rc" = 0 ] && [ ! -e "$MARK.depoff" ] && grep -qx 'Depends-On: #71' "$T/child-body" \
  && ok || bad "F11e: a new retarget cancels the owed removal and keeps the line (rc $rc)"
sed -i '/^stackfast-revoke /d' "$ATT"

# ============================================================================
# F8. Merged parent: drop the mark. Unreadable: keep everything.
# ============================================================================
mkmark; echo merged > "$T/parent-state"
REVOKE; rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/events.txt" ] && [ ! -e "$MARK" ] && ok || bad "F8: a merged parent drops the mark and writes nothing (rc $rc; $(cat "$T/events.txt"))"
mkmark; parent_row BLOCKED_HUMAN "$PH" "$PH"; echo fail75 > "$T/parent-state"
REVOKE; rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/events.txt" ] && [ -s "$MARK" ] && ok || bad "F8: an unreadable parent read keeps the mark and writes nothing (rc $rc; $(cat "$T/events.txt"))"
grep -q '^stackfast-revoke ' "$ATT" && bad "F8: an unreadable read writes no attempt line" || ok
# The TTL sweep.
SFD="$T/h/state/merge-conductor/stack-fast"
printf 'ticket/demo-1\t71\t%s\t%s\n' "$PH" $((NOW - 700000)) > "$SFD/example-org__demo-os#90"
printf 'ticket/demo-1\t71\t%s\t%s\n' "$PH" $((NOW - 10)) > "$SFD/example-org__demo-os#91"
# Another repo whose name starts with this slug: its old mark is not this sweep's.
printf 'ticket/demo-1\t71\t%s\t%s\n' "$PH" $((NOW - 700000)) > "$SFD/example-org__demo-os2#92"
msf_sweep "$SLUG"
[ -e "$SFD/example-org__demo-os2#92" ] && ok || bad "F8: msf_sweep <slug> must not drop another repo's mark"
[ -e "$SFD/example-org__demo-os#90" ] && bad "F8: msf_sweep must drop a mark past MC_STACK_FAST_MARK_TTL_S" || ok
[ -e "$SFD/example-org__demo-os#91" ] && ok || bad "F8: msf_sweep must keep a fresh mark"

echo "mc-stack-fast.bh-5520-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
