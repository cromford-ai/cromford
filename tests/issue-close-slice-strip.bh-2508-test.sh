#!/bin/bash
# tests/issue-close-slice-strip.bh-2508-test.sh — BH-2508: a merge that only
# SLICED a master takes `ai-build` off the master, and the planner's split
# output carries a machine-readable `SLICE: C<n> of #<master>` line the close
# guard matches.
#
# WHY. BH-2477 stopped the close-out closing #2320 when PR #2390 only built its
# C0 slice, but it left the label on, so every watcher tick still saw #2320 as
# an `ai-build` ticket to relaunch. And the guard found the slice through a
# planner SENTENCE ("The build for THIS ticket is C0"), prose a planner may
# phrase differently tomorrow.
#
# WHAT THIS PINS, on the REST argv that reached the stub `gh` and the word each
# helper prints, never on source text:
#   L  issue_close_guard matches `SLICE: C<n> of #<this issue>` at line start,
#      and nothing that only talks about it
#   B  issue_close_shipped: every slice verdict comments FIRST, then strips
#      under the close path's own rules (split-child, switch, noop, failure)
#   C  mc_close_shipped: the same, the comment still paid once per record, and
#      a failed comment strips nothing
#   P  the planner prompt, as bin/lib/rb/plan.sh expands it, asks for the line
#      and both repair prompts (plan-gate, size-gate) tell the model to keep it
#
#   HARNESS_TEST_SANDBOX=1 bash tests/issue-close-slice-strip.bh-2508-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/lib/issue-state-lib.sh" ] || { echo "FAIL: bin/lib/issue-state-lib.sh missing"; exit 1; }

mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
cp "$DIR/bin/lib/issue-state-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
ghfx_extra <<'SH'
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init

S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/2390
REC="$T/h/builds/pool-proj-BH-2320-202609251756"
mkdir -p "$REC"
# The real #2390 body line (D4), and a Closes body for the non-slice cases.
REFS_BODY=$'## Summary\nRefs #2320\n\nThis builds C0. The PR body says `Refs #2320` and not `Closes`: C1 to C6 follow.'
CLOSES_BODY=$'## Summary\nCloses #2320\n\nharness build'

xref() {
  jq -nc --argjson n "$1" --arg st "$2" --arg b "$3" \
    '{event:"cross-referenced",source:{type:"issue",issue:{number:$n,state:$st,body:$b}}}'
}
reset() {
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"
  rm -f "$REC/plan.md" "$REC/issue-commented" "$T/h/flags/close-strip-ai-build-off"
  unset CLOSE_STRIP_AI_BUILD
}
pr_body()  { ghfx_route GET "repos/$S/pulls/2390" 200 "$(jq -nc --arg b "$1" '{number:2390,state:"closed",body:$b}')"; }
timeline() { ghfx_route GET "repos/$S/issues/2320/timeline*" 200 "$1"; }
# issue_read <labels-json> [body] — the master as GET issues/2320 answers it
issue_read() { ghfx_route GET "repos/$S/issues/2320" 200 "$(jq -nc --argjson l "$1" --arg b "${2:-master ticket}" '{state:"open",body:$b,labels:$l}')"; }
writes() { # comment, close, label strip; the label read is added per case
  ghfx_route POST   "repos/$S/issues/2320/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/2320" 200 '{"state":"closed"}'
  ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
}
KID="[$(xref 2407 open $'Scope.\nPart of #2320')]"  # TEST-CHANGE BH-4662: the open child the strip cases now need
LBL='[{"name":"ai-build"},{"name":"enhancement"}]'
n_patch()  { grep -c -- "-X PATCH repos/$S/issues/2320" "$T/gh-argv.log"; }
n_post()   { grep -c -- "-X POST repos/$S/issues/2320/comments" "$T/gh-argv.log"; }
n_delete() { grep -c -- "-X DELETE repos/$S/issues/2320/labels/ai-build" "$T/gh-argv.log"; }
guard() { issue_close_guard "$S" 2320 "$PRURL" "$REC" 2>/dev/null; }
ics()   { issue_close_shipped "$S" 2320 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }
mcs()   { mc_close_shipped "$S" 2320 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# L. the SLICE line
# ════════════════════════════════════════════════════════════════════════════
# L1 the line itself, a Closes body, no children: slice:plan with no read at all
reset; pr_body "$CLOSES_BODY"; timeline '[]'
printf '# BH-2320\n\nScope of C0.\n\nSLICE: C0 of #2320\n\n## Tasks\n' > "$REC/plan.md"
W=$(guard); [ "$W" = slice:plan ] && ok || bad "L1: 'SLICE: C0 of #2320' must be slice:plan (got '$W')"
[ ! -s "$T/gh-argv.log" ] && ok || bad "L1: the SLICE line is local and must stop before any REST read ($(cat "$T/gh-argv.log"))"
# L2 / L3 markdown the planner may wrap it in
for line in '**SLICE:** C3 of #2320' '> SLICE: C0 of #2320 (contract)' '  _SLICE:_ C12 of #2320.'; do
  reset; pr_body "$CLOSES_BODY"; timeline '[]'
  printf 'intro\n%s\n' "$line" > "$REC/plan.md"
  W=$(guard); [ "$W" = slice:plan ] && ok || bad "L2/L3: '$line' must be slice:plan (got '$W')"
done
# L4-L8 adversarial negatives (plan System invariants c): each must be close
for line in 'SLICE: C0 of #23201' 'SLICE: C0 of #999' 'Plans quote `SLICE: C0 of #2320` mid-line in prose.' \
            'We write SLICE: C0 of #2320 when a plan splits.' 'SLICE: C of #2320' 'slice: c0 of #2320' \
            '| SLICE: C0 of #2320 |' 'No slice marker at all.'; do
  reset; pr_body "$CLOSES_BODY"; timeline '[]'
  printf '# plan\n%s\n' "$line" > "$REC/plan.md"
  W=$(guard); [ "$W" = close ] && ok || bad "L4-L8: '$line' must NOT be a slice of #2320 (got '$W')"
done

# ════════════════════════════════════════════════════════════════════════════
# B. issue_close_shipped — batch train and tier-1 close-out
# ════════════════════════════════════════════════════════════════════════════
# B1 the #2390 Refs body: comment first, then the strip, no close
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped ] && ok || bad "B1: a Refs PR must answer kept-slice:no-keyword+stripped rc 0 (rc=$RC w=$W)"
[ "$(n_patch)" = 0 ] && ok || bad "B1: a slice must never PATCH the master ($(n_patch))"
[ "$(n_post)" = 1 ] && ok || bad "B1: exactly one slice comment (got $(n_post))"
[ "$(n_delete)" = 1 ] && ok || bad "B1: a slice must take ai-build off the master once (got $(n_delete) DELETEs)"
[ "$(head -1 "$T/posted.txt")" = 'Slice delivered: #2390; children own the rest.' ] && ok \
  || bad "B1: first line must be 'Slice delivered: #2390; children own the rest.' (got '$(head -1 "$T/posted.txt")')"
sed -n 2p "$T/posted.txt" | grep -qxF "$PRURL" && ok || bad "B1: the PR url must be on line 2 ($(sed -n 2p "$T/posted.txt"))"
grep -q 'Closing this issue' "$T/posted.txt" && bad "B1: a slice must never say 'Closing this issue'" || ok
[ "$(grep -c '—' "$T/posted.txt")" = 0 ] && ok || bad "B1: no em dashes in a client-visible comment"
grep -qiE 'label|removed' "$T/posted.txt" && bad "B1: the comment must not claim the label was removed (D13)" || ok
P=$(grep -n -- '-X POST' "$T/gh-argv.log" | head -1 | cut -d: -f1); D=$(grep -n -- '-X DELETE' "$T/gh-argv.log" | head -1 | cut -d: -f1)
[ -n "$P" ] && [ -n "$D" ] && [ "$P" -lt "$D" ] && ok || bad "B1: the comment must precede the strip (post line $P, delete line $D)"

# B2 an open child
reset; pr_body "$CLOSES_BODY"; timeline "[$(xref 2407 open $'Scope.\nPart of #2320')]"; writes; issue_read "$LBL"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = 'kept-slice:open-children:#2407+stripped' ] && ok || bad "B2: an open child must answer kept-slice:open-children:#2407+stripped (rc=$RC w=$W)"
[ "$(n_delete)" = 1 ] && [ "$(n_patch)" = 0 ] && ok || bad "B2: one DELETE, no PATCH (delete=$(n_delete) patch=$(n_patch))"

# B3 the SLICE plan line
reset; pr_body "$CLOSES_BODY"; timeline "$KID"; writes; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
printf 'SLICE: C0 of #2320\n' > "$REC/plan.md"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:plan+stripped ] && ok || bad "B3: a SLICE plan must answer kept-slice:plan+stripped (rc=$RC w=$W)"
[ "$(n_delete)" = 1 ] && [ "$(n_patch)" = 0 ] && ok || bad "B3: one DELETE, no PATCH (delete=$(n_delete) patch=$(n_patch))"

# B4 the master is itself a split child: the label stays (decompose-parent-close reads it)
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL" $'Part of #100\nOrder: 1 of 3'  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+kept-split-child ] && ok || bad "B4: a split-child master must keep its label (rc=$RC w=$W)"
[ "$(n_delete)" = 0 ] && ok || bad "B4: a split child must not be stripped ($(n_delete))"

# B5 the switch, by env and by flag file: label stays, comment still posted
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(CLOSE_STRIP_AI_BUILD=0 ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+strip-off ] && ok || bad "B5: CLOSE_STRIP_AI_BUILD=0 must answer +strip-off (rc=$RC w=$W)"
[ "$(n_delete)" = 0 ] && [ "$(n_post)" = 1 ] && ok || bad "B5: switched off: no DELETE, one comment (delete=$(n_delete) post=$(n_post))"
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL"; touch "$T/h/flags/close-strip-ai-build-off"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); [ "$W" = kept-slice:no-keyword+strip-off ] && [ "$(n_delete)" = 0 ] && ok || bad "B5: the flag file must switch the strip off (w=$W delete=$(n_delete))"

# B6 the DELETE fails: a named word, never 'stripped', rc 0
reset; pr_body "$REFS_BODY"; timeline "$KID"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
ghfx_route POST   "repos/$S/issues/2320/comments" 201 '{"id":1}'
ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 500 '{"message":"boom"}'
issue_read "$LBL"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+strip-failed ] && ok || bad "B6: a failed DELETE must answer +strip-failed rc 0 (rc=$RC w=$W)"
# B6b the label is already gone: no DELETE
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read '[{"name":"enhancement"}]'  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); [ "$W" = kept-slice:no-keyword+strip-noop ] && [ "$(n_delete)" = 0 ] && ok || bad "B6b: an absent label must answer +strip-noop with no DELETE (w=$W delete=$(n_delete))"
# B6c a failed comment still strips, and says the comment failed
reset; pr_body "$REFS_BODY"; timeline "$KID"; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
ghfx_route POST   "repos/$S/issues/2320/comments" 403 '{"message":"no"}'
ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped,comment-failed ] && ok || bad "B6c: a refused comment must answer +stripped,comment-failed (rc=$RC w=$W)"

# B7 unknown: no write of any kind
reset; ghfx_route GET "repos/$S/pulls/2390" 403 '{"message":"nope"}'; timeline '[]'; writes; issue_read "$LBL"
W=$(ics); RC=$?
[ "$RC" = 1 ] && ok || bad "B7: an unknown must be rc 1 (rc=$RC w=$W)"
case "$W" in close-deferred:*) ok ;; *) bad "B7: an unknown must print close-deferred:* (got '$W')" ;; esac
[ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_patch)" = 0 ] && ok \
  || bad "B7: an unknown writes nothing (post=$(n_post) delete=$(n_delete) patch=$(n_patch))"

# B8 a real Closes merge: today's path, one PATCH, the caller's comment, word stripped
reset; pr_body "$CLOSES_BODY"; timeline '[]'; writes
ghfx_route GET "repos/$S/issues/2320" 200 "{\"state\":\"closed\",\"body\":\"master\",\"labels\":$LBL}"
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = stripped ] && [ "$(n_patch)" = 1 ] && [ "$(n_delete)" = 1 ] && ok \
  || bad "B8: a Closes merge must close and strip as today (rc=$RC w=$W patch=$(n_patch) delete=$(n_delete))"
head -1 "$T/posted.txt" | grep -q '^Merged in' && ok || bad "B8: the close comment is the caller's own body"
grep -q 'Slice delivered' "$T/posted.txt" && bad "B8: a Closes merge must post no slice comment" || ok

# B9 the slice comment is paid once per build record (review D11): the first
# close-out writes <record>/issue-commented, and a second lane on the same record
# posts nothing and answers strip-noop once the label is gone
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics)
[ -f "$REC/issue-commented" ] && [ "$(n_post)" = 1 ] && ok \
  || bad "B9: the first slice close-out must post once and write <record>/issue-commented (post=$(n_post) w=$W)"
ghfx_routes_reset; ghfx_log_reset
pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read '[{"name":"enhancement"}]'  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+strip-noop ] && ok || bad "B9: the second lane must answer +strip-noop rc 0 (rc=$RC w=$W)"
[ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && ok || bad "B9: the second lane posts and deletes nothing (post=$(n_post) delete=$(n_delete))"
# B10 the conductor paid it first (mc_close_shipped's marker): no second comment
reset; pr_body "$REFS_BODY"; timeline '[]'; writes; issue_read "$LBL"
W=$(mcs); ghfx_log_reset
W=$(ics)
[ "$(n_post)" = 0 ] && ok || bad "B10: after the conductor's slice comment, issue_close_shipped must not post again (post=$(n_post) w=$W)"
# B11 a refused comment writes no marker, so the next lane still posts it
reset; pr_body "$REFS_BODY"; timeline '[]'; issue_read "$LBL"
ghfx_route POST   "repos/$S/issues/2320/comments" 403 '{"message":"no"}'
ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
W=$(ics)
[ ! -f "$REC/issue-commented" ] && ok || bad "B11: a refused comment must not write <record>/issue-commented (w=$W)"

# ════════════════════════════════════════════════════════════════════════════
# C. mc_close_shipped — merge conductor and tier-2 sweep
# ════════════════════════════════════════════════════════════════════════════
# C1 Refs: comment, marker, strip, no close
reset; pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read "$LBL"  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(mcs); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+stripped ] && ok || bad "C1: the conductor must answer kept-slice:no-keyword+stripped rc 0 (rc=$RC w=$W)"
[ -f "$REC/issue-commented" ] && ok || bad "C1: the slice comment must write <record>/issue-commented"
[ "$(n_delete)" = 1 ] && [ "$(n_patch)" = 0 ] && [ "$(n_post)" = 1 ] && ok \
  || bad "C1: one comment, one DELETE, no PATCH (post=$(n_post) delete=$(n_delete) patch=$(n_patch))"
[ "$(head -1 "$T/posted.txt")" = 'Slice delivered: #2390; children own the rest.' ] && ok || bad "C1: the slice comment copy ($(head -1 "$T/posted.txt"))"

# C2 the other lane on the same record, label already gone: no comment, strip-noop
ghfx_routes_reset; ghfx_log_reset
pr_body "$REFS_BODY"; timeline "$KID"; writes; issue_read '[{"name":"enhancement"}]'  # TEST-CHANGE BH-4662: one open child, so this case still pins the strip path it was written for (no child now keeps the label)
W=$(mcs); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-keyword+strip-noop ] && ok || bad "C2: the second lane must answer +strip-noop (rc=$RC w=$W)"
[ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && ok || bad "C2: the second lane posts and deletes nothing (post=$(n_post) delete=$(n_delete))"

# C3 the comment fails: deferred, and the label stays so no master loses it unexplained
reset; pr_body "$REFS_BODY"; timeline '[]'; issue_read "$LBL"
ghfx_route POST   "repos/$S/issues/2320/comments" 403 '{"message":"no"}'
ghfx_route DELETE "repos/$S/issues/2320/labels/ai-build" 200 '[]'
W=$(mcs); RC=$?
[ "$RC" = 1 ] && [ "$W" = comment-deferred ] && ok || bad "C3: a refused comment must be comment-deferred rc 1 (rc=$RC w=$W)"
[ "$(n_delete)" = 0 ] && ok || bad "C3: a refused comment must strip nothing ($(n_delete))"

# ════════════════════════════════════════════════════════════════════════════
# P. the planner prompt, expanded the way bin/lib/rb/plan.sh expands it
# ════════════════════════════════════════════════════════════════════════════
CCLINE=$(grep -m1 '^CC plan ' "$DIR/bin/lib/rb/plan.sh")
[ -n "$CCLINE" ] && ok || bad "P1: bin/lib/rb/plan.sh has no 'CC plan' line"
PROMPT=$( set +u; CC() { printf '%s' "$5"; }; TICKET=2320 KEY=BH-2320 PROJECT=proj BUILD=/b; eval "$CCLINE" )
grep -qF 'SLICE: C<n> of #2320' <<<"$PROMPT" && ok \
  || bad "P1: the expanded planner prompt must ask for 'SLICE: C<n> of #2320' (prompt tail: ${PROMPT: -300})"
grep -qF 'PLAN ONLY' <<<"$PROMPT" && ok || bad "P1: the extraction must be the real planner prompt"

# P2/P3. the repair pass rewrites plan.md IN PLACE, so it must tell the model to
# keep a 'SLICE:' line the planner wrote; a repair that drops it turns a sliced
# master back into a ticket the close-out closes.
# TEST-CHANGE BH-5292: size-repair-run.txt left this loop because that repair
# pass is gone (a missing `## Size` is now a warning, no session is bought). The
# remaining repair keeps the full check.
for RP in plan-repair-run.txt; do
  RLINE=$(grep -m1 "^[[:space:]]*CC plan .*$RP" "$DIR/bin/lib/rb/plan.sh" | sed 's/^[[:space:]]*//')
  [ -n "$RLINE" ] && ok || bad "P2: bin/lib/rb/plan.sh has no 'CC plan' line for $RP"
  RPROMPT=$( set +u; CC() { printf '%s' "$5"; }; TICKET=2320 KEY=BH-2320 PROJECT=proj BUILD=/b HARNESS=/h; eval "$RLINE" )
  grep -qF 'Repair the plan' <<<"$RPROMPT" && ok || bad "P2: the $RP extraction must be the real repair prompt"
  grep -qF "'SLICE:" <<<"$RPROMPT" && ok \
    || bad "P3: the $RP repair prompt must tell the model to keep a 'SLICE:' line (prompt tail: ${RPROMPT: -300})"
done

echo "issue-close-slice-strip (BH-2508): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
