#!/bin/bash
# tests/merge-conductor-stacked-base-test.sh — BH-410: the conductor never
# merges a PR into anything but its project's base branch.
#
# WHY A SECOND FILE AND NOT MORE OF merge-conductor-test.sh. That suite pins the
# CLASSIFIER's stacked-child answer: a list row whose baseRefName is a feature
# branch lands STACKED_WAIT. This one pins the guard at the MERGE ACTION, which
# is a different claim and fails for a different reason: with the list's base
# column EMPTY — the pre-#342 shape, and the shape any future tsv column added
# without a `-` placeholder brings back — the classifier abstains, the row
# classifies READY, and the pre-action re-read asked GitHub for `state` and
# `headRefOid` only. Nothing between READY and `gh pr merge` had ever looked at
# the base, so the child merged INTO its parent's branch.
#
# Driven, not grepped: sections 2-4 and 6 run bin/merge-conductor.sh itself with
# stubbed gh/curl, and assert on the state row, on logs/merge-conductor.log and
# on the recorded gh argv — `grep -q mc_base_guard bin/...` passes just as
# happily on a guard nothing ever reaches.
# Run from anywhere: tests/merge-conductor-stacked-base-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=aaaaaaaa1111
PB=ticket/TK-378-r2     # the parent branch of the ticket's own case

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/fakebin"
# bin/lib/gh-rest.sh rides along (BH-784): every decision read below goes through
# it, and without it the lib's fail-closed shim answers "unverifiable" to each one
# — a green suite on a conductor that never read anything.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# The stub `gh` answers the REST reads as FULL HTTP responses, because gh-rest.sh
# judges the status line and not gh's exit code. tests/lib/rest-emit.sh is the
# emitter; it is on the stub PATH as `restpr`.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

# ============================================================================
# 1. mc_base_guard, pure: which source refuses, and which one abstains
#
#    rc 0 = the merge may proceed. rc 1 = REFUSE, and stdout is the base that is
#    wrong. Either source that KNOWS a base and says it is not the project's
#    refuses; a source that knows nothing abstains. The FRESH read outranks the
#    list, because it is newer — the (main, main, ticket/…) row is that rule.
# ============================================================================
G() { # G <project-base> <list-base> <fresh-base> -> "<rc> <stdout>"
  local out rc
  out=$(mc_base_guard "$1" "$2" "$3"); rc=$?
  printf '%s %s' "$rc" "$out"
}
type mc_base_guard >/dev/null 2>&1 && ok || bad "mc_base_guard is not defined in bin/lib/merge-conductor-lib.sh — nothing guards the merge action"
[ "$(G main "$PB" "")"     = "1 $PB" ] && ok || bad "the LIST naming a feature branch must refuse and name it (got '$(G main "$PB" "")')"
[ "$(G main "" "$PB")"     = "1 $PB" ] && ok || bad "the FRESH read naming a feature branch must refuse even when the list knows nothing — this is the shape that merged the child into its parent (got '$(G main "" "$PB")')"
[ "$(G main - "$PB")"      = "1 $PB" ] && ok || bad "the tsv '-' placeholder is 'no base', not a base: the fresh read must still refuse (got '$(G main - "$PB")')"
[ "$(G main main "$PB")"   = "1 $PB" ] && ok || bad "a STALE list saying main must not outrank a fresh read saying $PB (got '$(G main main "$PB")')"
[ "$(G main main main)"    = "0 " ]    && ok || bad "both sources on the project base must proceed (got '$(G main main main)')"
[ "$(G main - -)"          = "0 " ]    && ok || bad "two placeholders are no evidence either way and must proceed — every existing fixture without baseRefName runs on this (got '$(G main - -)')"
[ "$(G main "" "")"        = "0 " ]    && ok || bad "two empty sources must proceed (got '$(G main "" "")')"
[ "$(G master master "")"  = "0 " ]    && ok || bad "the project base is PBASE, not the literal word main: master on a master repo must proceed (got '$(G master master "")')"
[ "$(G master main "")"    = "1 main" ] && ok || bad "on a master repo, main is the wrong base and must refuse (got '$(G master main "")')"
[ "$(G "" "$PB" "")"       = "1 $PB" ] && ok || bad "an unreadable project base defaults to main, and $PB is still refused (got '$(G "" "$PB" "")')"

# ============================================================================
# The scaffolding for the driven sections: one project, one PR, approved at its
# head and CI-green, so the ONLY thing that can keep it out of `gh pr merge` is
# the base.
# ============================================================================
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
REC="$T/h/builds/demo-os-TK-41-202609160001"; mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/41" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

# mk_gh <list-base-json-fragment> <fresh-base-word>
#   <list-base-json-fragment> is spliced into the PR-list row: `,"baseRefName":"…"`
#     for a list that carries the column, or EMPTY for the shape that lost it.
#   <fresh-base-word> is the third word the pre-action re-read answers.
#
#   The re-read is ONE REST GET of the pull object now (BH-784) — state, head sha
#   and base.ref all ride on the same call — so the stub answers it with the whole
#   object and the conductor picks the fields it asks for. There is no `pr view`
#   arm left on purpose: a conductor that went back to GraphQL would fall through
#   to the catch-all and fail here rather than quietly pass.
mk_gh() {
  local listbase="$1" freshbase="$2"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
# pr41 <OPEN|MERGED> — the pull object for #41.
#   An EMPTY <fresh-base-word> is the "GitHub knows no base either" shape of
#   section 8, i.e. base.ref NULL. restpr's positional default would turn an
#   empty argument into main, so that one is built by nulling the field on the
#   object restpr printed — never by hand-rolling the row.
pr41() {
  local msha=""; [ "\$1" = MERGED ] && msha=cccccccc3333
  if [ -n "$freshbase" ]; then
    restpr "\$1" "$H1" ticket/TK-41 "$freshbase" "" MERGEABLE CLEAN app/cromford "\$msha"
  else
    restpr --raw 200 "\$(restpr "\$1" "$H1" ticket/TK-41 main "" MERGEABLE CLEAN app/cromford "\$msha" \
                        | tail -1 | jq -c '.base.ref=null')"
  fi
}
# plist <OPEN|MERGED|CLOSED> <pr-number> — the one-element array the
#   \`pulls?state=all&head=owner:branch\` list read answers. The state half comes
#   out of restpr, so MERGED stays closed-WITH-merged_at here too.
plist() {
  restpr --raw 200 "[\$(restpr "\$1" x - - '' | tail -1 \
    | jq -c --arg u "https://github.com/example-org/demo-os/pull/\$2" '{state,merged_at,html_url:\$u}')]"
}
case "\$*" in
  *"pr merge https://github.com/example-org/demo-os/pull/41 --squash --match-head-commit $H1"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged41"; exit 0 ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -i -X DELETE"*|*"pr edit"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/41/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/41"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/41"*)
    if [ -f "$T/merged41" ]; then pr41 MERGED; else pr41 OPEN; fi ;;
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all -f head=example-org:$PB "*) plist OPEN 40 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":41,"url":"https://github.com/example-org/demo-os/pull/41","headRefOid":"$H1","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[]$listbase}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/fakebin/gh"
}
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
                 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
TICK() { run_tick env MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv"; }
reset_tick() {
  rm -f "$T/merged41" "$T/gh-merges.txt" "$T/gh-writes.txt" "$T/gh-calls.txt" "$T/tick.err"
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs" "$T/h/locks"
  mkdir -p "$T/h/logs" "$T/h/locks"
  : > "$T/gh-merges.txt"; : > "$T/gh-writes.txt"
}
ACTFLAGS() { touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"; }
OBSERVE()  { rm -f "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"; }

# ============================================================================
# 2. The ticket's own case: an UNLABELLED child whose list base is its parent's
#    branch, with merges turned ON. It parks and it does not merge — label or no
#    label. (The parse that makes this reachable is PR #342's; this pins that
#    the conductor still reads it and still refuses to act on it.)
# ============================================================================
TSVQ=$(grep -o "jq -r '\.\[\] | \[\.number.*@tsv' 2>/dev/null" "$T/h/bin/merge-conductor.sh" | head -1 | sed "s/^jq -r '//; s/' 2>\/dev\/null$//")
[ -n "$TSVQ" ] && ok || bad "could not find the conductor's own PR-list jq in the script"
ROW=$(printf '[{"number":41,"url":"u","headRefOid":"h","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"%s"}]' "$PB" | jq -r "$TSVQ")
# BH-1486 added `updatedAt` as the 12th column and BH-1529 `isCrossRepository`
# as the 13th, so this read — which is pr_worker's, variable for variable —
# takes thirteen names. A fixture with no updatedAt must land the documented
# `-` there and leave BASEREF alone.
IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ XLBL XBASE XUPD XCROSS <<<"$ROW"
[ "$XBASE" = "$PB" ] && ok || bad "an UNLABELLED PR must still land baseRefName in BASEREF (got lbl='$XLBL' base='$XBASE')"
[ "$XUPD" = - ] && ok || bad "a list row with no updatedAt must emit the '-' placeholder (got '$XUPD')"
[ "$XCROSS" = - ] && ok || bad "a list row with no isCrossRepository must emit the '-' placeholder (got '$XCROSS')"

reset_tick; ACTFLAGS; mk_gh ",\"baseRefName\":\"$PB\"" "$PB"
TICK
[ "$(state_of 'example-org/demo-os#41')" = STACKED_WAIT ] && ok || bad "an unlabelled child based on an OPEN parent's branch must park STACKED_WAIT with merges ON (got $(state_of 'example-org/demo-os#41'))"
[ -s "$T/gh-merges.txt" ] && bad "the conductor MERGED a PR based on $PB: $(cat "$T/gh-merges.txt")" || ok
[ -s "$T/gh-writes.txt" ] && bad "a parked stacked child took a gh write: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 3. THE SAME PR, BASED ON main: it merges. The guard must refuse a wrong base
#    and nothing else — a guard that parks everything would pass section 2 and
#    section 4 and stop the fleet.
# ============================================================================
reset_tick; ACTFLAGS; mk_gh ',"baseRefName":"main"' main
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "a PR based on main must merge with --squash --match-head-commit (nothing was merged)"
[ "$(state_of 'example-org/demo-os#41')" = MERGED ] && ok || bad "after the merge the row must be MERGED (got $(state_of 'example-org/demo-os#41'))"

# ============================================================================
# 4. THE REPRO. The list has NO base column at all — the pre-#342 shape, and
#    what any future positional column added without a `-` placeholder brings
#    back — so the classifier abstains and the row is READY. GitHub, asked
#    fresh, says the base is $PB.
#
#    On main the pre-action re-read asks for `state,headRefOid` only, so nothing
#    ever sees $PB and `gh pr merge` lands the child INTO its parent's branch.
# ============================================================================
reset_tick; ACTFLAGS; mk_gh "" "$PB"
TICK
[ -s "$T/gh-merges.txt" ] && bad "THE DEFECT: the conductor merged #41 into $PB — the list lost its base column and the pre-action re-read never asked GitHub for the base ($(cat "$T/gh-merges.txt"))" || ok
[ "$(state_of 'example-org/demo-os#41')" = STACKED_WAIT ] && ok || bad "a PR GitHub says is based on $PB must park STACKED_WAIT (got $(state_of 'example-org/demo-os#41'))"
grep -q 'MERGE_REFUSED' "$T/h/logs/merge-conductor.log" && ok || bad "the refusal must log MERGE_REFUSED"
grep -q "MERGE_REFUSED.*$PB" "$T/h/logs/merge-conductor.log" && ok || bad "the MERGE_REFUSED line must name the base it refused ($PB)"
grep -q "reason=merge refused: based on $PB, not main" "$T/h/logs/merge-conductor.log" && ok || bad "the parked row's reason must say the merge was refused and name both bases (got: $(grep -o 'reason=.*' "$T/h/logs/merge-conductor.log" | tail -1))"
[ -s "$T/gh-writes.txt" ] && bad "the refusal took a gh write: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 5. Tabs INSIDE a field, read through the conductor's own jq: every positional
#    column still lands where the loop expects it. @tsv escapes a tab as \t, so
#    the row stays one line and thirteen columns whatever a title carries
#    (eleven until BH-1486 appended `updatedAt`, twelve until BH-1529 appended
#    `isCrossRepository`).
# ============================================================================
ROW=$(jq -rn --arg pb "$PB" '[{number:41,url:"u",headRefOid:"h",headRefName:"ticket/TK-41",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",labels:[],baseRefName:$pb,title:"a\tb\tc"}]' | jq -r "$TSVQ")
[ "$(printf '%s' "$ROW" | wc -l)" = 0 ] && ok || bad "a title with tabs must not split the row across lines"
IFS=$'\t' read -r C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 <<<"$ROW"
[ "$C1" = 41 ] && [ "$C2" = u ] && [ "$C3" = h ] && [ "$C4" = ticket/TK-41 ] && [ "$C5" = false ] \
  && [ "$C6" = CLEAN ] && [ "$C7" = MERGEABLE ] && [ "$C8" = OPEN ] && [ "$C9" = false ] \
  && [ "$C10" = - ] && [ "$C11" = "$PB" ] && [ "$C12" = - ] && [ "$C13" = - ] \
  && ok || bad "every column must parse to its fixture value with tabs in the title (got: $C1|$C2|$C3|$C4|$C5|$C6|$C7|$C8|$C9|$C10|$C11|$C12|$C13)"

# ============================================================================
# 6. Observe mode. No flags at all: the row still says what it is, and nothing
#    is written to GitHub. A guard that only refused when merges were ON would
#    leave the operator reading READY on a PR that must never merge.
# ============================================================================
reset_tick; OBSERVE; mk_gh "" "$PB"
TICK
[ -s "$T/gh-merges.txt" ] && bad "observe mode merged: $(cat "$T/gh-merges.txt")" || ok
[ -s "$T/gh-writes.txt" ] && bad "observe mode took a write verb: $(cat "$T/gh-writes.txt")" || ok
reset_tick; OBSERVE; mk_gh ",\"baseRefName\":\"$PB\"" "$PB"
TICK
[ "$(state_of 'example-org/demo-os#41')" = STACKED_WAIT ] && ok || bad "observe mode must still classify a stacked child STACKED_WAIT (got $(state_of 'example-org/demo-os#41'))"
[ -s "$T/gh-writes.txt" ] && bad "observe mode took a write verb: $(cat "$T/gh-writes.txt")" || ok

# ============================================================================
# 7. A CHILD RETARGETED EARLIER IN THE SAME TICK STILL MERGES. The guard refuses
#    a wrong base and NOTHING else — and the list's base is the one fact in the
#    arm that a retarget makes stale: the worker read `ticket/TK-39` at the top
#    of the tick, PATCHed the PR onto main ten lines later, and the list-side
#    check would then refuse a PR that is correctly based on main. This is the
#    whole reason the retarget sites refresh BASEREF.
#
#    PR 42's parent MERGED, its head is CI-green (so the retarget buys no CI
#    kick), and it is approved at that head: it classifies READY in the SAME
#    tick and must land.
# ============================================================================
REC42="$T/h/builds/demo-os-TK-42-202609160002"; mkdir -p "$REC42"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/42" > "$REC42/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC42/review.md"
echo "$H1" > "$REC42/reviewed-sha"
reset_tick; ACTFLAGS
rm -f "$T/retargeted42"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
pr42() { # pr42 <OPEN|MERGED> — the fresh read says main, because the retarget landed
  local msha=""; [ "\$1" = MERGED ] && msha=cccccccc3333
  restpr "\$1" "$H1" ticket/TK-42 main "" MERGEABLE CLEAN app/cromford "\$msha"
}
plist() { # plist <OPEN|MERGED|CLOSED> <pr-number>
  restpr --raw 200 "[\$(restpr "\$1" x - - '' | tail -1 \
    | jq -c --arg u "https://github.com/example-org/demo-os/pull/\$2" '{state,merged_at,html_url:\$u}')]"
}
case "\$*" in
  *"auth token"*) echo faketoken ;;
  *"api -X PATCH repos/example-org/demo-os/pulls/42 -f base=main"*) touch "$T/retargeted42"; exit 0 ;;
  *"pr merge https://github.com/example-org/demo-os/pull/42 --squash --match-head-commit $H1"*)
    printf '%s\n' "\$*" >> "$T/gh-merges.txt"; touch "$T/merged41"; exit 0 ;;
  *"pr merge"*|*"api -X PATCH"*|*"api -i -X PATCH"*|*"api -i -X POST"*|*"api -i -X DELETE"*|*"pr edit"*|*"pr review"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/42/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/42"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/42"*)
    if [ -f "$T/merged41" ]; then pr42 MERGED; else pr42 OPEN; fi ;;
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all -f head=example-org:ticket/TK-39 "*) plist MERGED 39 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls -f state=all"*) restpr --raw 200 '[]' ;;
  *"pr list -R example-org/demo-os --state open"*)
    B42=ticket/TK-39; [ -f "$T/retargeted42" ] && B42=main
    cat <<J
[{"number":42,"url":"https://github.com/example-org/demo-os/pull/42","headRefOid":"$H1","headRefName":"ticket/TK-42","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"\$B42"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
TICK
[ -f "$T/retargeted42" ] && ok || bad "the merged parent's child must be retargeted to main first — the rest of this section is about what happens after that"
[ -s "$T/gh-merges.txt" ] && ok || bad "a child retargeted earlier in THIS tick must still merge: its stale list base must not refuse it (log: $(grep -o 'MERGE_REFUSED.*' "$T/h/logs/merge-conductor.log" | head -1))"
grep -q 'MERGE_REFUSED' "$T/h/logs/merge-conductor.log" && bad "a correctly retargeted PR must not log MERGE_REFUSED" || ok
[ "$(state_of 'example-org/demo-os#42')" = MERGED ] && ok || bad "the retargeted child must end the tick MERGED (got $(state_of 'example-org/demo-os#42'))"

# ============================================================================
# 8. TWO SOURCES THAT KNOW NOTHING MUST NOT PARK THE FLEET. No base column in
#    the list and no base in the fresh read (a null baseRefName, an answer with
#    the field missing) is NOT evidence that the base is wrong — and it is the
#    shape ~50 fixture rows across the conductor suites carry. It merges, which
#    is exactly today's behaviour.
# ============================================================================
reset_tick; ACTFLAGS; mk_gh "" ""
TICK
[ -s "$T/gh-merges.txt" ] && ok || bad "an unknown base on BOTH sources must abstain and merge, not park (log: $(grep -o 'MERGE_REFUSED.*' "$T/h/logs/merge-conductor.log" | head -1))"
grep -q 'MERGE_REFUSED' "$T/h/logs/merge-conductor.log" && bad "no base on either source is not a refusal" || ok

echo "merge-conductor-stacked-base: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
