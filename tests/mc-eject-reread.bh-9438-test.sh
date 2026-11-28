#!/bin/bash
# tests/mc-eject-reread.bh-9438-test.sh — BH-9438 item 4: a queue-ejected-twice
# park that carries the old "unknown (no Mergify dequeue reason)" label is
# re-read once and re-routed by its real cause (bin/merge-conductor.d/
# bh-9438-eject-reread.sh, called from the parked-row pass of
# bin/merge-conductor.sh).
#
# WHY. Before BH-9229 (2026-11-08) ec_classify read only a `## Reason`
# heading, so 138 of 182 ejections on the hub read `unknown (no Mergify dequeue
# reason)` and parked `queue-ejected-twice` on that label. The parked-row pass
# visits every OPEN park each tick but never read the cause again: a conflict
# stayed a fix-round park, and every park kept the wrong label.
#
#   X1,X2   the two mislabel shapes (record line, row reason) are re-read
#   X3-X6   the negatives: another unknown detail, a real cause, an unreadable
#           record with no old label, provider github, knob 0, observe mode
#   X7,X8   the mark is written before the read; a second call reads nothing
#   X9      11 candidates, cap 10: 10 reads, the 11th waits
#   X10     a conflict: ejectconflict, `queue-ejected: conflict …`, released
#   X11     the real #9189 CHECKS_FAILED payload (tests/fixtures/bh-9229/):
#           re-labelled `queue-ejected-twice: checks (…) — re-read (BH-9438)`
#   X12     unreadable comments: the mark is cleared, counted; 3rd keeps it
#   X13     the `reread` record line round trip, ec_summary
#   X14     mc_handoff_owns on both new reasons; still-unknown keeps the park,
#           spent per classifier revision (ejreread-none-r<EC_CLASSIFY_REV>)
#   X15     the real CURRENT-format conflict comment (#8713, `**Reason**`,
#           payload code CONFLICT_WITH_BASE_BRANCH, tests/fixtures/bh-9438/):
#           the conflict route, not unknown
#   T1      THE REPRODUCTION, whole bin/merge-conductor.sh ticks: a real park
#           with the old label, then a conflict comment: re-read, ejectconflict,
#           released, and the row leaves queue-ejected-twice
#   T3      whole ticks, T1 on the current-format #8713 conflict comment
#   T2      whole ticks, the #9189 checks payload: re-labelled, and the caller
#           still hands it to the fix round (mc_eject_fix_now)
#
# The rig is tests/mc-eject-cause.bh-6161-test.sh's: the real conductor
# closure against a stub gh. No test reads GitHub.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-eject-reread.bh-9438-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-9438-eject-reread.sh"
FX="$DIR/tests/fixtures/bh-9229/pr9189-mergify-comments.json"
FXC="$DIR/tests/fixtures/bh-9438/pr8713-conflict-comment.json"
[ -f "$DIR/bin/merge-conductor.sh" ] && [ -f "$DIR/bin/lib/mc-eject-cause.sh" ] && [ -f "$FX" ] && [ -f "$FXC" ] || exit 1   # impact: bin/merge-conductor.sh bin/lib/mc-eject-cause.sh bin/merge-conductor.d/bh-9438-eject-reread.sh tests/fixtures/bh-9229/pr9189-mergify-comments.json tests/fixtures/bh-9438/pr8713-conflict-comment.json
NOW=$(date -u +%s)

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || { echo "FAIL: closure of bin/merge-conductor.sh"; exit 1; }
for s in bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/mc-eject-cause.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The fragment under test, where the driver sources it (absent on the merge base).
mkdir -p "$T/h/bin/merge-conductor.d"
[ -f "$FRAG" ] && cp "$FRAG" "$T/h/bin/merge-conductor.d/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"
done

H1=082b2964a1b2c3d4e5f60718293a4b5c6d7e8f90   # the head #9189's CHECKS_FAILED comment left at (082b296)
H2=7f2cff9e0000bbbb1111222233334444555566ee
M=cccccccccccccccccccccccccccccccccccccccc
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')

{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nM=%s\n' "$T" "$MGFY_YML" "$M"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
CHECK=$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,$//')
case "$*" in
  *"api -i -X GET repos/example-org/mgfy-os/pulls?state=open"*|*"api -i -X GET repos/example-org/mgfy-os/pulls -f state=open"*)
    restpr --raw 200 "$(jq -c '[.[] | {number, state:"open", draft:false, html_url:.url, head:{sha:.headRefOid, ref:.headRefName, repo:{full_name:"example-org/mgfy-os"}}, base:{ref:.baseRefName, repo:{full_name:"example-org/mgfy-os"}}, labels, user:{login:"operator", type:"User"}, mergeable_state:(.mergeStateStatus | ascii_downcase)}]' "$T/list.json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"actions/workflows/prequeue-gate.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/"*"/check-runs"*)
    case "$CHECK" in
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  *"api -i -X GET repos/example-org/mgfy-os/issues/31/comments"*)
    [ -s "$T/cmtfail" ] && { restpr --raw 403 '{"message":"API rate limit exceeded"}'; exit 0; }
    restpr --raw 200 "$(cat "$T/prcomments.json" 2>/dev/null || echo '[]')" ;;
  *"api --paginate repos/example-org/mgfy-os/issues/"*"/comments"*) echo '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/main"*) restpr --raw 200 "{\"sha\":\"$M\"}" ;;
  *"api -i -X GET repos/example-org/mgfy-os/commits/"*) restpr --raw 200 '{"commit":{"committer":{"date":"2026-10-05T20:00:00Z"}}}' ;;
  *"api -X DELETE repos/"*"/labels/dequeued"*)
    grep -vxF 'dequeued' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X DELETE repos/"*"/labels/"*)
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*)
    printf '%s\n' "$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*|*"api -i -X POST repos/"*"/comments"*) printf '%s\n' "$*" >> "$T/comments.txt"; restpr --raw 201 '{"id":901}' ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*|*"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(sed -n "s|.*/pulls/\([0-9]*\).*|\1|p" <<<"$*")
    restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/mg-$PN" main "$LBL" MERGEABLE "$(cat "$T/mstate" 2>/dev/null || echo CLEAN)" operator ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
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
URL="${!#}"
case "$URL" in
  */api/ledger) printf '{"ok":true}\n200\n' ;;
  */api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
MCD="$T/h/state/merge-conductor"
A="$MCD/attempts.txt"
CLOG="$T/h/logs/merge-conductor.log"
SLUG=example-org/mgfy-os
K31="$SLUG#31"
U31=https://github.com/$SLUG/pull/31
REC_FILE="$MCD/eject-cause/example-org_mgfy-os_31"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
OLD='queue-ejected-twice: 1 unknown (no Mergify dequeue reason) on 082b2964; 2 unknown (no Mergify dequeue reason) on 082b2964'
TAB=$'\t'

# cmt <login> <body> — one comment object, in API shape.
cmt() { jq -nc --arg l "$1" --arg b "$2" '{id:1, user:{login:$l}, created_at:"2026-10-05T23:18:00Z", body:$b}'; }
# conflict_body <left-sha> — an old-format Mergify dequeue whose `## Reason`
#   names a base-branch conflict (the shape tests/mc-eject-cause.bh-6161 uses).
conflict_body() {
  printf '%s\n' '# Merge Queue Status' '' \
    "- 🚫 **Left the queue** — \`2026-10-05 23:18 UTC\` · at \`$1\`" '' \
    '## Reason' '' 'The pull request conflicts with the base branch: it became a base branch conflict after #12 merged' '' \
    '## Hint' '' 'You may have to fix your CI before adding the pull request to the queue again.'
}
CONFLICT_JSON="[$(cmt 'mergify[bot]' "$(conflict_body "$H1")")]"
CHECKS_JSON=$(jq -c . "$FX")
# The real #8713 comment (current format, left at 47baee4), its Left-the-queue
#   sha set to this rig's head.
CONFLICT_NEW_JSON=$(jq -c --arg h "${H1:0:7}" 'map(.body |= gsub("`47baee4`"; "`" + $h + "`"))' "$FXC")
NOMERGIFY_JSON="[$(cmt operator 'nothing here')]"

# ----------------------------------------------------------------------------
# The unit rig: the fragment in a subshell with the conductor lib and the
# eject-cause lib, the comments read stubbed over $T/cjson (counted in
# $T/reads.txt; $T/cmtfail makes it fail).
# ----------------------------------------------------------------------------
reset_pr() { # reset_pr <num> <reason> [record cause<TAB>detail|-]
  local k="$SLUG#$1" f="$MCD/eject-cause/example-org_mgfy-os_$1"
  mc_row_put "$k" BLOCKED_HUMAN $((NOW-600)) "$H1" "$H1" - "$2" "https://github.com/$SLUG/pull/$1"
  rm -f "$f"
  if [ "${3:--}" != - ]; then mkdir -p "${f%/*}"; printf '%s\t%s\tfirst\t%s\n%s\t%s\tagain\t%s\n' $((NOW-900)) "$H1" "$3" $((NOW-600)) "$H1" "$3" > "$f"; fi
}
ejr() { # ejr <num> [reason] — one mc_ejr_reread; prints rc=<n>
  local n="$1" why="${2:-}"
  [ -n "$why" ] || why=$(mc_row_field "$SLUG#$n" 7)
  bash -c ". '$T/h/bin/lib/merge-conductor-lib.sh' >/dev/null 2>&1; mc_init >/dev/null 2>&1
    . '$T/h/bin/lib/mc-eject-cause.sh'; [ -r '$FRAG' ] && . '$FRAG'
    gh_rest_issue_comments() { echo \"\$2\" >> '$T/reads.txt'
      grep -qx \"ejreread $SLUG#\$2 $H1\" '$A' && echo marked >> '$T/reads-marked.txt'
      [ -s '$T/cmtfail' ] && return 1; cat '$T/cjson'; }
    PROVIDER=\${PROV:-mergify}; ACTIONS=\${ACT:-1}; MC_TICK_ID=\${TICKN:-u1}; P=mgfy
    mc_ejr_reread mgfy '$SLUG' '$SLUG#$n' '$H1' 'https://github.com/$SLUG/pull/$n' '$why'; echo rc=\$?" 2>>"$T/ejr.err"
}
reads() { [ -f "$T/reads.txt" ] && wc -l < "$T/reads.txt" || echo 0; }
fresh() { : > "$A"; : > "$T/reads.txt"; : > "$T/reads-marked.txt"; : > "$T/cmtfail"; : > "$CLOG"; rm -f "$MCD/pr-state.tsv"; touch "$MCD/pr-state.tsv"
          scratch_rm "$MCD/tick"; scratch_rm "$MCD/eject-cause"; scratch_rm "$MCD/handoff-released"; mkdir -p "$MCD/handoff-released"; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$MCD/pr-state.tsv"; }
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$MCD/pr-state.tsv"; }

# X1 — the record line carries the old label; the row reason does not.
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"
reset_pr 31 "queue-ejected-twice" "unknown${TAB}no Mergify dequeue reason"
O=$(ejr 31)
[ "$(reads)" = 1 ] && [ "$O" = rc=1 ] && pass "X1: a record line 'unknown / no Mergify dequeue reason': one re-read" || fail "X1: reads $(reads), $O; err $(tail -2 "$T/ejr.err")"
# X11 — that read was the real #9189 CHECKS_FAILED payload.
case "$(reason_of "$K31")" in
  "queue-ejected-twice: checks (Pure-logic gate fixtures, Tests, traced (shard 7/9)) on 082b2964 — re-read (BH-9438)") pass "X11: the #9189 payload re-labels the park 'queue-ejected-twice: checks (…) — re-read (BH-9438)', rc 1" ;;
  *) fail "X11: reason '$(reason_of "$K31")'" ;;
esac
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "X11: the park stays BLOCKED_HUMAN (the fix round goes on)" || fail "X11: state $(state_of "$K31")"
grep -q "EJECT_REREAD $K31 082b2964 was=unknown now=checks (Pure-logic gate fixtures, Tests, traced (shard 7/9)) route=park" "$CLOG" \
  && pass "X11: one EJECT_REREAD line names the real cause" || fail "X11: log $(grep -o 'EJECT_REREAD.*' "$CLOG")"
# X13 — the record round trip.
[ "$(tail -n1 "$REC_FILE" | cut -f2-5)" = "$H1${TAB}reread${TAB}checks${TAB}Pure-logic gate fixtures, Tests, traced (shard 7/9)" ] \
  && pass "X13: one record line of ord 'reread' with the real cause" || fail "X13: record $(tail -n1 "$REC_FILE")"
X13=$( ( . "$T/h/bin/lib/mc-eject-cause.sh"; ec_summary "$SLUG" 31; printf '|'; ec_head_why "$SLUG" 31 "$H1" ) 2>/dev/null)
[ "$X13" = "2 unknown (no Mergify dequeue reason) on 082b2964; 3 checks (Pure-logic gate fixtures, Tests, traced (shard 7/9)) on 082b2964|checks (Pure-logic gate fixtures, Tests, traced (shard 7/9))" ] \
  && pass "X13: ec_summary and ec_head_why read the re-read line back" || fail "X13: got '$X13'"
( mc_handoff_owns "$(reason_of "$K31")" ) && pass "X14: a re-labelled park is still a hand-off (mc_handoff_owns rc 0)" || fail "X14: mc_handoff_owns refused '$(reason_of "$K31")'"
# X8 — a second call reads nothing.
O=$(ejr 31 "$OLD")
[ "$(reads)" = 1 ] && pass "X8: a second call on the same head: 0 reads" || fail "X8: reads $(reads)"

# X2 — no record; the row reason carries the old label.
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"
reset_pr 31 "$OLD" -
O=$(ejr 31)
[ "$(reads)" = 1 ] && pass "X2: a row reason with 'unknown (no Mergify dequeue reason)': one re-read" || fail "X2: reads $(reads), $O"
# X7 — the mark was on the ledger when the read ran.
[ "$(wc -l < "$T/reads-marked.txt")" = 1 ] && pass "X7: the ejreread mark is written before the read" || fail "X7: mark not seen at read time"

# X3-X6 — the negatives.
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"
reset_pr 31 "queue-ejected-twice: 1 unknown (Mergify's newest dequeue names 1234abcd, not this head) on 082b2964" "unknown${TAB}Mergify's newest dequeue names 1234abcd, not this head"
ejr 31 >/dev/null
[ "$(reads)" = 0 ] && pass "X3: another unknown detail (newest dequeue names another head): 0 reads" || fail "X3: reads $(reads)"
reset_pr 31 "queue-ejected-twice: 1 checks (ci) on 082b2964" "checks${TAB}ci"
ejr 31 >/dev/null
reset_pr 31 "queue-ejected-twice: 1 conflict (x) on 082b2964" "conflict${TAB}The pull request conflicts with the base branch"
ejr 31 >/dev/null
[ "$(reads)" = 0 ] && pass "X4: a record with a real cause (checks, conflict): 0 reads" || fail "X4: reads $(reads)"
reset_pr 31 "queue-ejected-twice: 1 unknown (dequeue comments unreadable) on 082b2964" "unknown${TAB}dequeue comments unreadable"
ejr 31 >/dev/null
[ "$(reads)" = 0 ] && pass "X4: 'unknown (dequeue comments unreadable)' with no old label: 0 reads" || fail "X4 unreadable: reads $(reads)"
reset_pr 31 "$OLD" -
O=$(PROV=github ejr 31)
[ "$(reads)" = 0 ] && [ "$O" = rc=1 ] && pass "X5: provider github: 0 reads" || fail "X5: reads $(reads), $O"
O=$(MC_EJECT_REREAD=0 ejr 31)
[ "$(reads)" = 0 ] && [ "$O" = rc=1 ] && pass "X6: MC_EJECT_REREAD=0: 0 reads" || fail "X6: reads $(reads), $O"
O=$(MC_EJECT_REREAD_PER_TICK=0 ejr 31)
[ "$(reads)" = 0 ] && pass "X6: MC_EJECT_REREAD_PER_TICK=0: off, 0 reads" || fail "X6 cap 0: reads $(reads)"
O=$(ACT=0 ejr 31)
[ "$(reads)" = 0 ] && ! grep -q "^ejreread " "$A" && grep -q "$K31 would re-read the queue-ejected-twice cause of 082b2964" "$CLOG" \
  && pass "X6: observe mode: one WOULD line, no mark, 0 reads" || fail "X6 observe: reads $(reads), log $(tail -1 "$CLOG")"

# X9 — 11 candidates in one tick, cap 10.
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"
for n in $(seq 31 41); do reset_pr "$n" "$OLD" -; done
for n in $(seq 31 41); do TICKN=x9 ejr "$n" >/dev/null; done
[ "$(reads)" = 10 ] && [ "$(grep -c "waits — this tick's 10 re-reads (MC_EJECT_REREAD_PER_TICK) are spent" "$CLOG")" = 1 ] \
  && pass "X9: 11 candidates, cap 10: 10 reads, the 11th waits" || fail "X9: reads $(reads), waits $(grep -c waits "$CLOG")"
TICKN=x9b ejr 41 >/dev/null
[ "$(reads)" = 11 ] && pass "X9: the 11th is read on the next tick" || fail "X9 next tick: reads $(reads)"

# X10 — a conflict.
fresh; printf '%s' "$CONFLICT_JSON" > "$T/cjson"
reset_pr 31 "$OLD" -
mc_handoff_record "$K31" "$H1" "$OLD" "$U31"
O=$(ejr 31)
[ "$O" = rc=0 ] && grep -qx "ejectconflict $K31 $H1" "$A" && pass "X10: a conflict: rc 0, the BH-1677 ejectconflict mark" || fail "X10: $O, attempts $(tr '\n' '|' < "$A")"
case "$(reason_of "$K31")" in
  "queue-ejected: conflict (The pull request conflicts with the base branch: it became a base branch conflict after #12 merged) — re-read (BH-9438); a rebase, not a fix round") pass "X10: the row reason reads 'queue-ejected: conflict (…) — re-read'" ;;
  *) fail "X10: reason '$(reason_of "$K31")'" ;;
esac
[ -e "$(mc_handoff_rel_file "$K31")" ] && grep -q eject-reread "$(mc_handoff_rel_file "$K31")" \
  && pass "X10: the hand-off is released (eject-reread)" || fail "X10: no release marker"
( mc_handoff_owns "$(reason_of "$K31")" ) && fail "X14: the conflict re-reason must not be a hand-off" || pass "X14: the conflict re-reason is not a hand-off (mc_handoff_owns rc 1)"
( mc_handoff_sticky "$K31" "$H1" ) && fail "X10: the park is still sticky" || pass "X10: the park is no longer sticky: the next tick classifies it"
[ "$(mc_eject_strikes "$K31")" = 0 ] && pass "X10: ejectconflict leaves the head out of the strike count" || fail "X10: strikes $(mc_eject_strikes "$K31")"

# X12 — unreadable comments.
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"; echo 1 > "$T/cmtfail"
reset_pr 31 "$OLD" -
O=$(ejr 31)
[ "$O" = rc=1 ] && ! grep -q "^ejreread $K31 " "$A" && [ "$(grep -c "^ejreread-unread $K31 $H1" "$A")" = 1 ] && [ "$(reason_of "$K31")" = "$OLD" ] \
  && pass "X12: unreadable: the mark is cleared, one ejreread-unread line, the reason is kept" || fail "X12: $O, attempts $(tr '\n' '|' < "$A")"
ejr 31 >/dev/null; ejr 31 >/dev/null; ejr 31 >/dev/null
[ "$(reads)" = 3 ] && grep -q "^ejreread $K31 $H1" "$A" && pass "X12: the third failure keeps the mark: 3 reads, not one a tick" || fail "X12: reads $(reads), attempts $(tr '\n' '|' < "$A")"
grep -q "could not be read 3 times (MC_EJECT_REREAD_UNREAD_MAX)" "$CLOG" \
  && pass "X12: the spent line names the cap and its knob" || fail "X12: log $(grep -o 'could not be read.*' "$CLOG" | tail -1)"
# X12b — the unreadable cap is the knob MC_EJECT_REREAD_UNREAD_MAX, not a literal (lr-9493).
fresh; printf '%s' "$CHECKS_JSON" > "$T/cjson"; echo 1 > "$T/cmtfail"
reset_pr 31 "$OLD" -
for _ in 1 2 3 4; do MC_EJECT_REREAD_UNREAD_MAX=2 ejr 31 >/dev/null; done
[ "$(reads)" = 2 ] && grep -q "^ejreread $K31 $H1" "$A" && grep -q "try 1 of 2" "$CLOG" && grep -q "could not be read 2 times" "$CLOG" \
  && pass "X12b: MC_EJECT_REREAD_UNREAD_MAX=2: the second failure keeps the mark, 2 reads" || fail "X12b: reads $(reads), log $(grep -o 'could not be read.*' "$CLOG" | tr '\n' '|')"

# X14 — still unknown after the re-read: nothing re-reasoned, the head is
#   spent for this classifier revision only.
fresh; printf '%s' "$NOMERGIFY_JSON" > "$T/cjson"
reset_pr 31 "$OLD" -
O=$(ejr 31); ejr 31 >/dev/null
REV=$( ( . "$T/h/bin/lib/mc-eject-cause.sh"; echo "$EC_CLASSIFY_REV" ) 2>/dev/null)
[ "$O" = rc=1 ] && [ "$(reads)" = 1 ] && [ "$(reason_of "$K31")" = "$OLD" ] && grep -q "route=none" "$CLOG" \
  && pass "X14: still unknown: rc 1, the reason is kept, one read for two calls" || fail "X14: $O, reads $(reads), reason '$(reason_of "$K31")'"
grep -qx "ejreread-none-r$REV $K31 $H1" "$A" && ! grep -q "^ejreread $K31 " "$A" \
  && pass "X14: still 'no Mergify dequeue reason': the mark is ejreread-none-r$REV, not a spent ejreread" || fail "X14: attempts $(tr '\n' '|' < "$A")"
# A mark of an older classifier revision does not stop a read.
sed -i "s/^ejreread-none-r$REV /ejreread-none-r$((REV - 1)) /" "$A"
printf '%s' "$CONFLICT_NEW_JSON" > "$T/cjson"
O=$(ejr 31)
[ "$O" = rc=0 ] && [ "$(reads)" = 2 ] && pass "X14: a new classifier revision reads the head once more, and finds the conflict" || fail "X14 rev: $O, reads $(reads)"

# X15 — the real current-format conflict comment (#8713): no `## Reason`.
fresh; printf '%s' "$CONFLICT_NEW_JSON" > "$T/cjson"
reset_pr 31 "$OLD" -
mc_handoff_record "$K31" "$H1" "$OLD" "$U31"
O=$(ejr 31)
[ "$O" = rc=0 ] && grep -qx "ejectconflict $K31 $H1" "$A" && pass "X15: a current-format conflict: rc 0, the ejectconflict mark" || fail "X15: $O, attempts $(tr '\n' '|' < "$A"), log $(grep -o 'EJECT_REREAD.*' "$CLOG")"
[ "$(reason_of "$K31")" = "queue-ejected: conflict (CONFLICT_WITH_BASE_BRANCH) — re-read (BH-9438); a rebase, not a fix round" ] \
  && pass "X15: the row reason reads 'queue-ejected: conflict (CONFLICT_WITH_BASE_BRANCH) — re-read'" || fail "X15: reason '$(reason_of "$K31")'"
[ -e "$(mc_handoff_rel_file "$K31")" ] && pass "X15: the hand-off is released" || fail "X15: no release marker"

# ============================================================================
# T1, T2: whole ticks. A real queue-ejected-twice park on the OLD label, made
# by the settle arm itself (two ejections, no Mergify comment), then the
# comments say why.
# ============================================================================
mkrec() { # mkrec <num> <head>
  local d="$T/h/builds/pool-mgfy-MG-$1-2026100500$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$1" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$2" > "$d/reviewed-sha"
  : > "$d/pipeline.log"
  echo "$2" > "$T/head-$1"
}
list_row() { # list_row <num> <head> <labels-csv> [mergeState]
  local lbl="[]"
  [ -n "${3:-}" ] && lbl=$(printf '%s' "$3" | jq -R 'split(",")|map({name:.})' -c)
  printf '[{"number":%s,"url":"https://github.com/%s/pull/%s","headRefOid":"%s","headRefName":"ticket/mg-%s","isDraft":false,"mergeStateStatus":"%s","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":%s,"baseRefName":"main"}]' \
    "$1" "$SLUG" "$1" "$2" "$1" "${4:-CLEAN}" "$lbl"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 env "$@" \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }; }
comment_reads() { grep -c 'issues/31/comments' "$T/gh-calls.txt"; }
# park_old — two ejections of #31 on H1 with no Mergify comment: the settle
#   arm parks it `queue-ejected-twice: 1 unknown (no Mergify dequeue reason) …`.
#   The fragment is out of the tree for these two ticks: the parks this fixes
#   were made before it shipped, so they carry no `ejreread` mark.
park_old() {
  mv "$T/h/bin/merge-conductor.d" "$T/frag-off" 2>/dev/null
  fresh; : > "$T/gh-calls.txt"; : > "$T/label-adds.txt"; : > "$T/comments.txt"; : > "$T/merges.txt"; : > "$T/writes.txt"
  echo CLEAN > "$T/mstate"; echo failed > "$T/checkmode"; printf 'merge-queue\n' > "$T/labels"
  mkrec 31 "$H1"; list_row 31 "$H1" merge-queue > "$T/list.json"; echo '[]' > "$T/prcomments.json"
  mc_row_put "$K31" QUEUED $((NOW-300)) "$H1" "$H1" - "in the merge queue" "$U31"
  run_tick
  mc_attempt_put "requeued $K31 $H1 $((NOW-120))"
  mc_row_put "$K31" QUEUED $((NOW-120)) "$H1" "$H1" - "requeued on ${H1:0:8} after a flake ejection" "$U31"
  printf 'merge-queue\n' > "$T/labels"; list_row 31 "$H1" merge-queue > "$T/list.json"
  scratch_rm "$MCD/tick"
  run_tick
  mv "$T/frag-off" "$T/h/bin/merge-conductor.d" 2>/dev/null
}

# T1 — the conflict.
park_old
T1WHY=$(reason_of "$K31")
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && [[ "$T1WHY" == queue-ejected-twice:*"unknown (no Mergify dequeue reason)"* ]] \
  && pass "T1: setup: the settle arm parked #31 on the old label" || fail "T1 setup: state '$(state_of "$K31")' reason '$T1WHY'"
printf '%s' "$CONFLICT_JSON" > "$T/prcomments.json"
echo none > "$T/checkmode"; : > "$T/labels"; list_row 31 "$H1" "" DIRTY > "$T/list.json"; echo DIRTY > "$T/mstate"
: > "$CLOG"; : > "$T/gh-calls.txt"; scratch_rm "$MCD/tick"
run_tick
grep -q "EJECT_REREAD $K31 ${H1:0:8} was=unknown now=conflict" "$CLOG" && pass "T1: a tick re-reads the park: one EJECT_REREAD line, now=conflict" \
  || fail "T1: no EJECT_REREAD line; log: $(grep -o "$K31.*" "$CLOG" | tail -4 | tr '\n' '|')"
grep -qx "ejectconflict $K31 $H1" "$A" && pass "T1: the ejectconflict mark is written" || fail "T1: attempts $(tr '\n' '|' < "$A")"
[ -e "$(mc_handoff_rel_file "$K31")" ] && pass "T1: the hand-off release marker is written" || fail "T1: no release marker"
T1R=$(comment_reads)
: > "$CLOG"; scratch_rm "$MCD/tick"
run_tick
case "$(reason_of "$K31")" in
  queue-ejected-twice*) fail "T1: after the next tick the row is still '$(state_of "$K31")' '$(reason_of "$K31")'" ;;
  *) pass "T1: after the next tick the row has left queue-ejected-twice ($(state_of "$K31"): $(reason_of "$K31" | cut -c1-60))" ;;
esac
grep -q "EJECT_REREAD" "$CLOG" && fail "T1: the next tick re-read again" || pass "T1: the next tick does not re-read (once per head)"
[ "$T1R" -ge 1 ] && pass "T1: the re-read was a comments read through the stub gh ($T1R)" || fail "T1: no comments read"

# T3 — T1 on the current-format #8713 conflict comment.
park_old
[[ "$(reason_of "$K31")" == queue-ejected-twice:*"unknown (no Mergify dequeue reason)"* ]] \
  && pass "T3: setup: the settle arm parked #31 on the old label" || fail "T3 setup: state '$(state_of "$K31")' reason '$(reason_of "$K31")'"
printf '%s' "$CONFLICT_NEW_JSON" > "$T/prcomments.json"
echo none > "$T/checkmode"; : > "$T/labels"; list_row 31 "$H1" "" DIRTY > "$T/list.json"; echo DIRTY > "$T/mstate"
: > "$CLOG"; : > "$T/gh-calls.txt"; scratch_rm "$MCD/tick"
run_tick
grep -q "EJECT_REREAD $K31 ${H1:0:8} was=unknown now=conflict (CONFLICT_WITH_BASE_BRANCH) route=rebase" "$CLOG" \
  && pass "T3: a tick re-reads the current-format park: now=conflict, route=rebase" \
  || fail "T3: log: $(grep -o "$K31.*" "$CLOG" | tail -4 | tr '\n' '|')"
grep -qx "ejectconflict $K31 $H1" "$A" && pass "T3: the ejectconflict mark is written" || fail "T3: attempts $(tr '\n' '|' < "$A")"
: > "$CLOG"; scratch_rm "$MCD/tick"
run_tick
case "$(reason_of "$K31")" in
  queue-ejected-twice*) fail "T3: after the next tick the row is still '$(state_of "$K31")' '$(reason_of "$K31")'" ;;
  *) pass "T3: after the next tick the row has left queue-ejected-twice ($(state_of "$K31"))" ;;
esac

# T2 — the #9189 checks payload: re-labelled, the fix round goes on.
park_old
grep -q "^ejectfix $K31 $H1" "$A" && pass "T2: setup: the second ejection handed the park to the fix round (ejectfix)" || fail "T2 setup: attempts $(tr '\n' '|' < "$A")"
# Drop the hand-over mark so this tick shows whether the caller still makes it.
mc_attempt_clear ejectfix "$K31" "$H1"
printf '%s' "$CHECKS_JSON" > "$T/prcomments.json"
echo none > "$T/checkmode"; : > "$T/labels"; list_row 31 "$H1" "" > "$T/list.json"
: > "$CLOG"; scratch_rm "$MCD/tick"
run_tick
case "$(reason_of "$K31")" in
  "queue-ejected-twice: checks (Pure-logic gate fixtures, Tests, traced (shard 7/9)) on 082b2964 — re-read (BH-9438)") pass "T2: a tick re-labels the park with the real checks" ;;
  *) fail "T2: state '$(state_of "$K31")' reason '$(reason_of "$K31")'; log $(grep -o "EJECT_REREAD.*" "$CLOG")" ;;
esac
grep -q "^ejectfix $K31 $H1" "$A" && pass "T2: the caller still hands the re-labelled park to the fix round (mc_eject_fix_now ran)" || fail "T2: no ejectfix mark; attempts $(tr '\n' '|' < "$A")"
[ "$(state_of "$K31")" = BLOCKED_HUMAN ] && pass "T2: the park stays BLOCKED_HUMAN" || fail "T2: state $(state_of "$K31")"

echo "mc-eject-reread.bh-9438: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
