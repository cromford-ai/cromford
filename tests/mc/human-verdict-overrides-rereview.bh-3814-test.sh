#!/bin/bash
# tests/mc/human-verdict-overrides-rereview.bh-3814-test.sh — BH-3814: a lead or
# human MERGE / MERGE-WITH-NOTES verdict row on the EXACT head, recorded after
# the conductor's own head-bound re-review BLOCKED that head, overrides the
# BLOCK. The row goes WAIT_REVIEW and then READY, nothing is handed to
# bin/blocked-resolver.sh, and the resolver starts no agent fix round on it.
#
# WHAT HAPPENED (project-4 #1815, 2026-10-01). The re-review of 94fafc78 came back
# BLOCK at 16:04Z on a body-only finding. A human recorded MERGE-WITH-NOTES
# (verdict #366) on that head at 16:19Z. At 16:33Z the conductor consumed its
# own BLOCK, parked the row head-not-reapproved and handed it to the resolver
# for an agent fix round. It never read verdict #366.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh against a fake gh and a fake
# curl that answers GET /api/verdicts from $VD/<sha> (the BH-1525 fixture,
# tests/lead-verdicts.bh-1525-test.sh). The re-review job file is written the
# way mc_rr_write writes it. The real bin/blocked-resolver.sh is driven on its
# own fixture (tests/lib/fixture-harness.sh), with vd_standing stubbed to the
# real rc contract (the tests/blocked-resolver-green-at-head.bh-1671-test.sh
# shape).
#   H1  re-review BLOCK at T1, human MERGE-WITH-NOTES at T1+900: WAIT_REVIEW
#       with the override reason, no hand-off, no hbrefused, one comment;
#       the next tick READY. (Red on main: parked head-not-reapproved.)
#   H2  the human MERGE is on an OLDER head: parked, no override
#   H3  the human MERGE is OLDER than the BLOCK (T0 < T1): parked, no override
#   H4  a row already parked head-not-reapproved, then a newer human MERGE: the
#       next tick re-checks it and rebinds; the tick after that READY
#   H5  the verdicts table is unreadable (rc 2): the row holds, never READY
#   H6  scope item 2: re-review APPROVE plus a human BLOCK row: no merge
#   H7  the override is sticky per head (job file gone), and a human BLOCK
#       replacing the MERGE ends it
#   R   bin/blocked-resolver.sh on a parked head-not-reapproved row: no agent
#       call and no fix round once a newer human MERGE stands; the control
#       without one is offered the fix round; rc 2 keeps today's ladder
#
# Run from anywhere: tests/mc/human-verdict-overrides-rereview.bh-3814-test.sh   (exit 0 = all pass)
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/lpp-stub.sh
. "$(dirname "$0")/../lib/lpp-stub.sh" || exit 1
# The open-PR list is REST (BH-1585); this bridge answers it from the list stub.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh); every stamp
# below is derived from it.
NOW=$(date -u +%s)
T1=$((NOW - 1800))
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# A verdict row binds to a FULL sha, so the fixture heads are full shas.
H1=aaaaaaaa11111111111111111111111111111111
H0=0000000011111111111111111111111111111111   # an earlier head of the same PR
SLUG=example-org/demo-os
KEY="$SLUG#41"
PRURL="https://github.com/$SLUG/pull/41"
T_HEAD_OLD=2026-09-17T18:40:00Z

# ---------------------------------------------------------------------------
# The verdicts API stub: GET /api/verdicts?...&head=<sha> answers $VD/<sha> or
# "nothing stands"; $VD/down fails at the transport (rc 2 for vd_standing).
# ---------------------------------------------------------------------------
VD="$T/vd"; mkdir -p "$VD" "$T/fakebin"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "GET "*/api/verdicts\?*)
    printf '%s\n' "\$URL" >> "$VD/calls"
    [ -f "$VD/down" ] && exit 7
    h="\${URL##*head=}"; h="\${h%%&*}"
    if [ -f "$VD/\$h" ]; then printf '%s\n200\n' "\$(cat "$VD/\$h")"
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  # TEST-CHANGE BH-4145: default mode is now lane; this suite pins human-mode behaviour
  "GET "*/api/settings/lead_authority_mode) printf '{"setting":{"key":"lead_authority_mode","value":"human"}}\n200\n' ;;
  # TEST-CHANGE BH-4140: the lead_protected_paths rows (tests/lib/lpp-stub.sh, section L)
  *"/api/lead-protected-paths"*) lpp-answer "\$M" "\$URL"; exit 0 ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
# vd_put <head> <verdict> <source> <id> <created_at-iso> — one standing row
vd_put() {
  jq -nc --arg v "$2" --arg s "$3" --argjson id "$4" --arg h "$1" --arg at "$5" \
    '{standing:{id:$id,repo:"example-org/demo-os",pr:41,head_sha:$h,verdict:$v,source:$s,
      created_at:$at,report_url:null,reviewer:"operator"},head:$h,rows:[]}' > "$VD/$1"
}
vd_reset() { rm -f "$VD"/*; : > "$VD/calls"; }
export JOBS_RETRIES=0

# ---------------------------------------------------------------------------
# The conductor's scratch harness (the BH-1525 section C fixture).
# ---------------------------------------------------------------------------
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/block-gate.sh" \
   "$DIR/bin/lib/verdicts.sh" "$T/h/bin/lib/" || exit 1
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
REC="$T/h/builds/demo-os-TK-20-202609160001"; mkdir -p "$REC"
echo "PR_CREATED $PRURL" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
PRJSON_OPEN=$(jq -nc --arg u "$PRURL" --arg h "$H1" '{number:41,html_url:$u,title:"t",body:"",state:"open",merged_at:null,merge_commit_sha:null,mergeable_state:"clean",draft:false,head:{sha:$h,ref:"ticket/TK-20"},base:{ref:"main"},user:{login:"operator",type:"User"},labels:[],created_at:"2026-09-12T00:00:00Z",updated_at:"2026-09-12T00:00:00Z",closed_at:null}')
PRLIST=$(jq -nc --arg u "$PRURL" --arg h "$H1" '[{number:41,url:$u,headRefOid:$h,headRefName:"ticket/TK-20",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",labels:[],baseRefName:"main"}]')
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge $PRURL --squash --match-head-commit $H1"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  *"api -i -X POST repos/$SLUG/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X POST repos/$SLUG/issues/41/comments"*)
    # One line per comment: the body file's text, flattened.
    for a in "\$@"; do case "\$a" in body=@*) tr '\n' ' ' < "\${a#body=@}" >> "$T/gh-comments.txt" ;; esac; done
    echo >> "$T/gh-comments.txt"; restpr --raw 201 '{"id":1}' ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH repos/"*|*"api -i -X POST repos/"*"/comments"*\
  |*"pr edit"*|*"issue close"*|*"issue comment"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"
    case "\$*" in *"api -i -X"*) restpr --raw 500 '{"message":"refused"}'; exit 0 ;; esac
    exit 1 ;;
  *"api repos/$SLUG/issues/41/comments"*) exit 0 ;;
  *"api repos/$SLUG/pulls/41/reviews"*)   exit 0 ;;
  "api repos/$SLUG/pulls/41") echo '$PRJSON_OPEN'; exit 0 ;;
  *"api -i -X GET repos/$SLUG/pulls/41/files"*)   # la_decide's REST file read (section L)
    if [ -f "$T/files500" ]; then restpr --raw 500 '{"message":"boom"}'
    else restpr --raw 200 "\$(cat "$T/files.json" 2>/dev/null || echo '[{"filename":"src/x.ts"}]')"; fi ;;
  *"repos/$SLUG/pulls/41/files"*) echo '[[{"filename":"src/x.ts"}]]'; exit 0 ;;
  *"api repos/$SLUG/issues/20/comments"*) exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/$SLUG/pulls/41"*) restpr OPEN "$H1" ticket/TK-20 main "" MERGEABLE CLEAN operator ;;
  *"api repos/$SLUG/pulls/41/commits"*) printf '%s\n' "$T_HEAD_OLD"; exit 0 ;;
  *"--json state,headRefOid,baseRefName"*) echo "OPEN $H1 main" ;;
  *"--json state,headRefOid"*)             echo "OPEN $H1" ;;
  *"pr view"*"--json state"*)              echo OPEN ;;
  *"pr list -R $SLUG --state open"*) echo '$PRLIST' ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|success' ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf 'demo-os %s https://demo.example /api/board 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
TICK() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test \
             MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 \
             bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
         || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
MCST="$T/h/state/merge-conductor"
MCLOG="$T/h/logs/merge-conductor.log"
state_of()  { awk -F'\t' -v k="$KEY" '$1==k {print $2}' "$MCST/pr-state.tsv" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$KEY" '$1==k {print $7}' "$MCST/pr-state.tsv" 2>/dev/null; }
# The re-review's own findings, the file the job's out_file names.
printf 'Finding: the PR body lacks the probe-run URL.\n\nTIER: 2\nVERDICT: BLOCK\n' > "$T/rr-out.md"
# rr_put <head> <verdict> <finished_epoch> — the detached job, as mc_rr_write writes it
rr_put() {
  mkdir -p "$MCST/rereview"
  jq -nc --arg v "$2" --arg h "$1" --arg r "$H0" --arg o "$T/rr-out.md" --argjson fin "$3" \
    '{status:"done",pid:0,started_at:($fin-600),finished_at:$fin,verdict:$v,head_sha:$h,reviewed_sha:$r,out_file:$o,reason:""}' \
    > "$MCST/rereview/example-org_demo-os_41_$1.json"
}
reset_tick() {
  vd_reset
  rm -f "$T/tick.err"
  scratch_rm "$MCST"; scratch_rm "$T/h/state/block-gate"; scratch_rm "$T/h/logs"; scratch_rm "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/locks"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"; : > "$T/gh-comments.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/h/flags/merge-conductor-merge"
  touch "$T/h/flags/merge-conductor-actions"
  # The approval on the ledger was bound to the earlier head: HEAD_MOVED.
  echo "$H0" > "$REC/reviewed-sha"
}
handed_off() { grep -q "BLOCKED_AGENT head-not-reapproved" "$MCLOG" 2>/dev/null; }
hbrefused()  { grep -qxF "hbrefused $KEY $H1" "$MCST/attempts.txt" 2>/dev/null; }
ctx() { printf '(state %s / %s; log tail: %s)' "$(state_of)" "$(reason_of)" "$(tail -3 "$MCLOG" 2>/dev/null | tr '\n' '|')"; }
# parked_no_override <case> — today's park, exactly: the hand-off and no override
parked_no_override() {
  [ "$(state_of)" = BLOCKED_HUMAN ] && [ "$(reason_of)" = head-not-reapproved ] && ok \
    || bad "$1: the row must stay parked BLOCKED_HUMAN head-not-reapproved $(ctx)"
  handed_off && ok || bad "$1: the BLOCK must still be handed to the resolver $(ctx)"
  grep -q "overrides re-review BLOCK" "$MCLOG" && bad "$1: no override line may be logged $(ctx)" || ok
}

# ============================================================================
# H1. THE TICKET'S CASE: BLOCK at T1, human MERGE-WITH-NOTES #366 at T1+900.
# ============================================================================
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE-WITH-NOTES human 366 "$(iso $((T1 + 900)))"
TICK
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "H1: a newer human MERGE must override the BLOCK — the row goes WAIT_REVIEW $(ctx)"
case "$(reason_of)" in *"human verdict #366 overrides re-review BLOCK"*) ok ;;
  *) bad "H1: the reason must say 'human verdict #366 overrides re-review BLOCK' $(ctx)" ;; esac
grep -q "human verdict #366 overrides re-review BLOCK on ${H1:0:8}" "$MCLOG" && ok || bad "H1: the override must be logged $(ctx)"
handed_off && bad "H1: nothing may be handed to bin/blocked-resolver.sh $(ctx)" || ok
hbrefused && bad "H1: no hbrefused row may be written for this head" || ok
[ "$(cat "$REC/reviewed-sha")" = "$H1" ] && ok || bad "H1: the approval must be rebound to $H1 (reviewed-sha $(cat "$REC/reviewed-sha"))"
[ "$(grep -c . "$T/gh-comments.txt")" = 1 ] && ok || bad "H1: exactly one PR comment (got: $(cat "$T/gh-comments.txt"))"
grep -q "Human verdict #366" "$T/gh-comments.txt" && ok || bad "H1: the comment must name the human verdict (got: $(cat "$T/gh-comments.txt"))"
TICK
[ "$(state_of)" = READY ] && ok || bad "H1: the next tick must classify the row READY $(ctx)"
[ "$(grep -c . "$T/gh-comments.txt")" = 1 ] && ok || bad "H1: the second tick posts nothing (got: $(cat "$T/gh-comments.txt"))"
[ -s "$T/gh-merges.txt" ] && bad "H1: the merge flag is off — nothing merges" || ok

# ============================================================================
# H2. The human MERGE is on an OLDER head: nothing stands on $H1.
# ============================================================================
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H0" MERGE human 366 "$(iso $((T1 + 900)))"
TICK
parked_no_override H2

# ============================================================================
# H3. The human MERGE is OLDER than the BLOCK: the newest verdict wins.
# ============================================================================
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE human 366 "$(iso $((T1 - 600)))"
TICK
parked_no_override H3
hbrefused && ok || bad "H3: the BLOCK records hbrefused as today"

# ============================================================================
# H4. ALREADY PARKED, then a newer human MERGE lands: the next tick re-checks.
#     (Carries on from H3's tree.)
# ============================================================================
: > "$T/gh-comments.txt"
vd_put "$H1" MERGE human 367 "$(iso $((T1 + 600)))"
TICK
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "H4: a parked row with a newer human MERGE must leave the park $(ctx)"
case "$(reason_of)" in *"human verdict #367 overrides re-review BLOCK"*) ok ;;
  *) bad "H4: the reason must name verdict #367 $(ctx)" ;; esac
hbrefused && bad "H4: the hbrefused row must be cleared, or mc_classify re-parks the head" || ok
[ -e "$MCST/handoff-released/example-org_demo-os_41" ] && ok || bad "H4: the park must be released (handoff-released marker)"
[ "$(cat "$REC/reviewed-sha")" = "$H1" ] && ok || bad "H4: the approval must be rebound to $H1"
grep -q "Human verdict #367\|human verdict #367" "$T/gh-comments.txt" && ok || bad "H4: one comment naming verdict #367 (got: $(cat "$T/gh-comments.txt"))"
TICK
[ "$(state_of)" = READY ] && ok || bad "H4: the tick after must classify the row READY $(ctx)"

# ============================================================================
# H5. THE VERDICTS TABLE IS UNREADABLE (rc 2): today's behaviour, never READY.
# ============================================================================
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE-WITH-NOTES human 366 "$(iso $((T1 + 900)))"
touch "$VD/down"
TICK
parked_no_override H5
grep -q "verdicts read failed" "$T/h/logs/verdicts.log" 2>/dev/null && ok || bad "H5: the failed read must be logged in logs/verdicts.log"
TICK
case "$(state_of)" in READY|WAIT_REVIEW) bad "H5: a parked row must hold while the verdicts table is unreadable $(ctx)" ;; *) ok ;; esac

# ============================================================================
# H6. SCOPE ITEM 2: the re-review APPROVED $H1 and a human BLOCK stands on it.
# ============================================================================
reset_tick
rr_put "$H1" APPROVE "$T1"
vd_put "$H1" BLOCK human 368 "$(iso $((T1 + 900)))"
TICK
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "H6: the APPROVE rebinds as today $(ctx)"
touch "$T/h/flags/merge-conductor-merge"
TICK
[ -s "$T/gh-merges.txt" ] && bad "H6: a human BLOCK must beat the lane APPROVE — merged: $(cat "$T/gh-merges.txt")" || ok
grep -q "MERGE_REFUSED block-gate.*human-verdict" "$MCLOG" && ok || bad "H6: the refusal must name the human verdict $(ctx)"
[ "$(state_of)" = READY ] && ok || bad "H6: the row stays READY, refused, not merged $(ctx)"

# ============================================================================
# H7. The override is STICKY per head, and a human BLOCK ends it.
# ============================================================================
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE-WITH-NOTES human 366 "$(iso $((T1 + 900)))"
TICK
lib() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test
          . "$T/h/bin/lib/merge-conductor-lib.sh" && mc_init >/dev/null 2>&1
          . "$T/h/bin/jobs-client.sh"; . "$T/h/bin/lib/verdicts.sh"; "$@" ); }
rm -f "$MCST/rereview/"*.json; rm -f "$MCST/handoff/"*   # the job gc'd, no park record
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 0 ] && ok || bad "H7: an override already applied to this head must still answer rc 0 with the job gone (got $RC)"
vd_put "$H1" BLOCK human 369 "$(iso $((T1 + 1200)))"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "H7: a human BLOCK replacing the MERGE must end the override (got $RC)"
touch "$VD/down"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 2 ] && ok || bad "H7: an unreadable verdicts table is rc 2 (got $RC)"
rm -f "$VD/down"
# Equal seconds are not newer.
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE human 370 "$(iso "$T1")"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "H7: a MERGE in the same second as the BLOCK is not newer (got $RC)"
vd_put "$H1" MERGE box 371 "$(iso $((T1 + 900)))"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "H7: only a lead or human row overrides, never source=box (got $RC)"

# ============================================================================
# R. THE RESOLVER: a parked head-not-reapproved row, driven through the real
#    bin/blocked-resolver.sh. fx_br_harness owns T and H from here on.
# ============================================================================
# --- V: the hvoverride marker never skips the time comparison (review 2026-10-01)
# An override already applied to this head, then the lane re-review is re-run
# on the SAME head and BLOCKs again AFTER the human MERGE: the newest BLOCK wins.
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE-WITH-NOTES human 366 "$(iso $((T1 + 900)))"
TICK
grep -qxF "hvoverride $KEY $H1" "$MCST/attempts.txt" 2>/dev/null && ok || bad "V1: setup — the override must have been applied (marker) $(ctx)"
rr_put "$H1" BLOCK $((T1 + 1200))
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "V1: a re-review BLOCK re-run on the same head after the override, newer than the MERGE, must end the override despite the hvoverride marker (got $RC)"
rr_put "$H1" BLOCK $((T1 + 300))
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 0 ] && ok || bad "V1: control — a re-run BLOCK OLDER than the MERGE leaves the override standing (got $RC)"

# --- N: a newer human BLOCK beats an older human MERGE, pinned at the override layer
reset_tick
rr_put "$H1" BLOCK "$T1"
jq -nc --arg h "$H1" --arg m "$(iso $((T1 + 900)))" --arg b "$(iso $((T1 + 1200)))" \
  '{standing:{id:373,repo:"example-org/demo-os",pr:41,head_sha:$h,verdict:"BLOCK",source:"human",created_at:$b,report_url:null,reviewer:"operator"},
    head:$h,rows:[{id:372,head_sha:$h,verdict:"MERGE",source:"human",created_at:$m},{id:373,head_sha:$h,verdict:"BLOCK",source:"human",created_at:$b}]}' > "$VD/$H1"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "N1: a human BLOCK newer than a human MERGE on the same head must not override (got $RC)"
TICK
parked_no_override N1

# --- L: a lead MERGE is only an override where lead authority stands (BH-3683)
# The real bin/lib/lead-authority.sh (through verdict-status.sh, as in prod),
# the production rows plus one PUT-added row for this repo's protected glob (the
# worker stub, tests/lib/lpp-stub.sh), and a PR whose files touch it. lead_authority_mode=human (the curl arm above, BH-4145): the
# lane is the authority except on the path.
cp "$DIR/bin/lib/verdict-status.sh" "$DIR/bin/lib/lead-authority.sh" "$T/h/bin/lib/" || exit 1
LPP="$T/lpp.json"
lpp_install "$T/fakebin" "$LPP" "$T/lpp-down"
set -f; lpp_set "$LPP" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
"$T/fakebin/lpp-answer" PUT http://lpp.stub/api/lead-protected-paths "{\"repo\":\"$SLUG\",\"glob\":\"bin/merge-conductor.sh\",\"op\":\"add\",\"added_by\":\"t\"}" >/dev/null
jq -e --arg r "$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z')" '[.rows[] | select(.repo == $r and .glob == "bin/merge-conductor.sh")] | length == 1' "$LPP" >/dev/null || exit 1
printf '[{"filename":"bin/merge-conductor.sh"},{"filename":"src/x.ts"}]' > "$T/files.json"
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE lead 380 "$(iso $((T1 + 900)))"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 1 ] && ok || bad "L1: a lead MERGE on a protected-path PR (advisory, authority:human-required) must not override the lane BLOCK (got $RC)"
TICK
parked_no_override L1
hbrefused && ok || bad "L1: the BLOCK records hbrefused as today"
: > "$T/gh-comments.txt"
vd_put "$H1" MERGE human 381 "$(iso $((T1 + 1000)))"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 0 ] && ok || bad "L2: a human MERGE on the same protected-path PR still overrides (got $RC)"
TICK
[ "$(state_of)" = WAIT_REVIEW ] && ok || bad "L2: the parked row leaves the park on the human MERGE $(ctx)"
case "$(reason_of)" in *"human verdict #381 overrides re-review BLOCK"*) ok ;;
  *) bad "L2: the reason must name verdict #381 $(ctx)" ;; esac
printf '[{"filename":"src/x.ts"}]' > "$T/files.json"
reset_tick
rr_put "$H1" BLOCK "$T1"
vd_put "$H1" MERGE lead 382 "$(iso $((T1 + 900)))"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 0 ] && ok || bad "L0: control — a lead MERGE where lead authority stands (no protected path) overrides (got $RC)"
touch "$T/files500"
lib mc_hv_override "$KEY" "$H1"; RC=$?
[ "$RC" = 2 ] && ok || bad "L3: la_decide rc 2 (the PR's files unreadable) holds: rc 2, never an override (got $RC)"
TICK
parked_no_override L3
rm -f "$T/files500" "$T/files.json"

CT="$T"; unset HARNESS
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
BT="$CT/br"; mkdir -p "$BT/h/bin" || exit 1
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$BT/h/bin/" || exit 1
fx_br_harness "$DIR" "$BT" || exit 1
[ -f "$DIR/bin/lib/mc/classify.sh" ] || exit 1   # impact: mc_hv_override is the judge both lanes ask
# vd_standing with the real rc contract, answered from $RVD/<sha> (one TSV line)
# or $RVD/down (rc 2). Every call is recorded.
RVD="$BT/rvd"; mkdir -p "$RVD"
cat > "$H/bin/lib/verdicts.sh" <<EOF
vd_standing() {
  printf '%s\n' "\$*" >> "$RVD/calls"
  [[ "\$3" =~ ^[0-9a-f]{40}\$ ]] || return 2
  [ -f "$RVD/down" ] && return 2
  [ -f "$RVD/\$3" ] || return 1
  cat "$RVD/\$3"
}
vd_clear_word() { return 1; }
EOF
cat > "$H/bin/lib/hold.sh" <<'EOF'
hold_check() { printf 'clear\tno hold on this ticket\n'; return 0; }
hold_check_thread() { printf 'clear\tno-hold\n'; return 0; }
hold_is_pause()   { return 1; }
hold_is_abandon() { return 1; }
EOF
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
# The "agent": every call recorded. A fix round that reaches it is the defect.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/agent.txt"\nexit 1\n' "$T" > "$H/bin/agent-call.sh"; chmod +x "$H/bin/agent-call.sh"
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # the head the shared gh stub answers
PR9="https://github.com/o/tproj/pull/9"
BLOG="$H/logs/blocked-resolver.log"
R_RESET() {
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/merge-conductor/handoff"
  scratch_rm "$H/state/merge-conductor/handoff-released"
  rm -f "$H/flags/blocked-resolver-observe" "$H/state/merge-conductor/attempts.txt" "$RVD"/*
  : > "$BLOG"; : > "$T/agent.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$RVD/calls"
  printf 'ticket/TK-9' > "$T/prbranch"; printf 'TK-9: a thing' > "$T/prtitle"; printf '%s' "$A" > "$T/prhead"
  echo OPEN > "$T/prstate"
  # The conductor's park, as mc_transition and mc_handoff_record write it: the
  # BLOCK parked $A at T1.
  printf 'o/tproj#9\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\thead-not-reapproved\t%s\n' "$T1" "$A" "$A" "$PR9" \
    > "$H/state/merge-conductor/pr-state.tsv"
  mkdir -p "$H/state/merge-conductor/handoff"
  printf '%s\t%s\thead-not-reapproved\t%s\n' "$T1" "$A" "$PR9" > "$H/state/merge-conductor/handoff/o_tproj_9"
  printf '%s o/tproj#9 BLOCKED_AGENT head-not-reapproved: the moved head was not re-approved — handed to bin/blocked-resolver.sh (agent fix round): %s\n' \
    "$(date -u -d "@$T1" '+%Y-%m-%d %H:%M:%S')Z" "$PR9" > "$H/logs/merge-conductor.log"
}
# rvd_put <head> <verdict> <source> <id> <created_at-iso> — vd_standing's TSV line
rvd_put() { printf '%s\t%s\t%s\t%s\t-\toperator\n' "$2" "$3" "$4" "$5" > "$RVD/$1"; }
rctx() { printf '(log: %s)' "$(tail -4 "$BLOG" 2>/dev/null | tr '\n' '|')"; }
FIXROUNDS() { jq -r '.fixrounds // 0' "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null | head -1; }

# R1. A newer human MERGE stands on the parked head: no agent, no fix round.
R_RESET; rvd_put "$A" MERGE-WITH-NOTES human 367 "$(iso $((T1 + 600)))"
RUN
grep -q "o/tproj#9.*$A\|o/tproj 9 $A" "$RVD/calls" && ok || bad "R1: the resolver must ask vd_standing about the parked head (calls: $(cat "$RVD/calls"))"
grep -q "human verdict #367.*no fix round" "$BLOG" && ok || bad "R1: the refusal must be logged naming verdict #367 $(rctx)"
[ -s "$T/agent.txt" ] && bad "R1: the agent stub must not be called (calls: $(cat "$T/agent.txt"))" || ok
grep -v "no fix round" "$BLOG" > "$T/blog-other"
grep -qi "fix-round\|fix round" "$T/blog-other" && bad "R1: no fix-round rung may be taken $(rctx)" || ok
case "$(FIXROUNDS)" in ''|0|null) ok ;; *) bad "R1: no fix round may be counted (fixrounds $(FIXROUNDS))" ;; esac
# R1o. The same in observe mode: no 'WOULD run a fix round'.
R_RESET; rvd_put "$A" MERGE-WITH-NOTES human 367 "$(iso $((T1 + 600)))"; touch "$H/flags/blocked-resolver-observe"
RUN
grep -q "WOULD run a fix round" "$BLOG" && bad "R1o: observe mode must not offer the fix round either $(rctx)" || ok
grep -q "human verdict #367.*no fix round" "$BLOG" && ok || bad "R1o: the refusal is logged in observe mode too $(rctx)"

# R0. CONTROL: no verdict row, observe mode — the same park IS offered the fix
#     round, so R1's assertions are not vacuous.
R_RESET; touch "$H/flags/blocked-resolver-observe"
RUN
grep -q "WOULD run a fix round" "$BLOG" && ok || bad "R0: control — with no verdict the park must be offered the fix round $(rctx)"
grep -q "no fix round" "$BLOG" && bad "R0: control — no refusal without a verdict $(rctx)" || ok

# R2. The human MERGE is OLDER than the park: the ladder runs as today.
R_RESET; rvd_put "$A" MERGE human 366 "$(iso $((T1 - 600)))"; touch "$H/flags/blocked-resolver-observe"
RUN
grep -q "WOULD run a fix round" "$BLOG" && ok || bad "R2: an older MERGE must not stop the fix round $(rctx)"

# R5. The verdicts table is unreadable: the ladder runs as it did before.
R_RESET; rvd_put "$A" MERGE human 367 "$(iso $((T1 + 600)))"; touch "$RVD/down" "$H/flags/blocked-resolver-observe"
RUN
grep -q "could not be read.*the ladder runs as it did before BH-3814" "$BLOG" && ok || bad "R5: rc 2 must be said once $(rctx)"
grep -q "WOULD run a fix round" "$BLOG" && ok || bad "R5: rc 2 keeps today's ladder $(rctx)"

# R6: the guard reads the LIVE PR head, never the hand-off file's. The hand-off
# record says A, but the PR moved to B and the MERGE stands only on A: the
# override must not apply, and the ladder runs.
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
R_RESET; rvd_put "$A" MERGE human 367 "$(iso $((T1 + 600)))"; printf '%s' "$B" > "$T/prhead"; touch "$H/flags/blocked-resolver-observe"
RUN
grep -q "human verdict #367.*no fix round" "$BLOG" && bad "R6: a MERGE on the hand-off file's stale head must not stop the round on the live head $(rctx)" || ok
grep -q "$B" "$RVD/calls" && ok || bad "R6: vd_standing must be asked about the live head $B (calls: $(cat "$RVD/calls"))"

echo "human-verdict-overrides-rereview.bh-3814: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
