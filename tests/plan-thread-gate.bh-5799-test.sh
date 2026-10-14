#!/bin/bash
# tests/plan-thread-gate.bh-5799-test.sh — BH-5799: a plan must apply the
# newest ticket comments. Twelve review BLOCKs in 300 PRs were plans built from
# the ticket body while a later comment by the operator or the triage had changed the
# scope (#5459, #5237, #4785, #4761).
#
# What this suite pins:
#   §1-§3  bin/lib/plan-thread.sh: the pure classifier, the own-post ledger.
#   §4     the `# >>> plan thread gate (BH-5799)` block (a reused or adopted
#          plan is refused and planned fresh in the same run, unless the build
#          is resumed or its branch already carries a diff: then PLAN_STALE).
#   §5     the `# >>> plan thread pre-review (BH-5799)` block at the top of
#          rb_review (PLAN_STALE, exit 3, plan.md moved aside).
#   §6     the knob PLAN_THREAD_GATE_ENFORCE through lib_env_apply.
#   §7     the plan prompt and the pre-plan prompt carry the section rule, and
#          both write the plan-thread-at stamp.
#   §8     the PR body section and the plan gate's contract-section list.
#   §9     the lead review thread render carries each comment's id, and the
#          checklist is v6.
#   §10    the stamp rides the coordination DB row: preplan_put sends it,
#          preplan_fetch writes it back, and a DB-adopted pre-plan with an old
#          uncited comment and `none` is adopted.
#   §11    the resolver's adjudication post on the issue lands in the build's
#          own-post ledger, so the ACCEPT's resume is not refused by it.
# The blocks are EXTRACTED VERBATIM from the shipped pipeline through
# tests/lib/rb-all.sh, never paraphrased. gh_rest is a stub; no network, no
# wall clock in any assertion (fixture stamps are literals).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/plan-thread-gate.bh-5799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
. "$SRC/tests/lib/rb-all.sh" || exit 1
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
RB_ALL=$(rb_all "$SRC" "$T/run-build.all.sh")
xb() { # xb <marker> <out> — one marked block, verbatim
  awk -v n="$1" 'index($0, "# >>> " n)==1 {f=1;next} index($0, "# <<< " n)==1 {exit} f' "$RB_ALL" > "$2"
}

H="$T/h"; mkdir -p "$H/bin/lib" "$H/plans" "$H/builds" "$H/env" "$H/flags" "$H/logs" "$H/state"
scratch_install_closure bin/lib/plan-thread.sh "$H" >/dev/null || bad "cannot install the closure of bin/lib/plan-thread.sh"
: > "$H/env/global.env"
# fleet-conf stub: board_prefix answers from $H/prefix ("-" = GitHub-issue lane)
cat > "$H/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in
  board_prefix) cat "$(dirname "$0")/../prefix" ;;
  repo) echo example-org/cromford ;;
  *) echo - ;;
esac
EOF
chmod +x "$H/bin/fleet-conf.sh"; echo - > "$H/prefix"
LIB="$H/bin/lib/plan-thread.sh"

# gh_rest stub: serves $H/page<N>.json for page N, logs every call, and answers
# rc from $H/gh.rc (default 0). An absent page file is an empty array.
GH_STUB='gh_rest() {
  local p; p=$(sed -nE "s/.*[?&]page=([0-9]+).*/\1/p" <<<"$2")
  printf "%s %s\n" "$1" "$2" >> "$HARNESS/gh.log"
  [ -s "$HARNESS/gh.rc" ] && return "$(cat "$HARNESS/gh.rc")"
  if [ -s "$HARNESS/page$p.json" ]; then cat "$HARNESS/page$p.json"; else echo "[]"; fi
}'
eval "$GH_STUB"

STAMP0='2026-10-09T10:00:00Z'
# cm <id> <login> <type> <created> [updated] [body] — one REST comment
cm() {
  jq -nc --argjson id "$1" --arg l "$2" --arg t "$3" --arg c "$4" --arg u "${5:-$4}" --arg b "${6:-a comment}" \
    '{id:$id, node_id:("IC_kwDOfixture" + ($id|tostring)), user:{login:$l,type:$t}, created_at:$c, updated_at:$u, body:$b}'
}
arr() { jq -sc '.' ; }
PLAN_PLAIN="$T/plan-plain.md"
printf '# Plan\n\n## Spec changes from comments\n\nnone\n\n## Tasks\n### Task 1\nVALIDATE: x\nSATISFIES: y\nSIZE: S\n' > "$PLAN_PLAIN"
PLAN_CITED="$T/plan-cited.md"
printf '# Plan\n\n## Spec changes from comments\n\n- 9002 (operator): adds region column → Task 2\n\n## Tasks\nSIZE: S\n' > "$PLAN_CITED"
APPS='["cromford-board"]'

classify() { # classify <plan> <since> <comments-json> [own-file] -> $OUT, $RC
  OUT=$(HARNESS="$H"; . "$LIB" && ptg_classify "$1" "$2" "$3" "$APPS" "${4:-}"); RC=$?
}

echo "--- §1 no comments"
if [ -r "$LIB" ]; then
  classify "$PLAN_PLAIN" "$STAMP0" '[]'
  [ "$RC" = 0 ] && [ "${OUT%%$'\t'*}" = ok ] && ok || bad "§1 no comments must be ok rc 0 (rc=$RC out=$OUT)"
else
  bad "§1 bin/lib/plan-thread.sh does not exist"
fi

echo "--- §2 classifier"
C_NEW=$(cm 9002 operator User 2026-10-09T11:00:00Z '' 'add a region column' | arr)
classify "$PLAN_PLAIN" "$STAMP0" "$C_NEW"
{ [ "$RC" = 1 ] && [ "${OUT%%$'\t'*}" = refuse ] && grep -q '9002' <<<"$OUT"; } && ok \
  || bad "§2a a newer uncited person comment must refuse naming 9002 (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "$STAMP0" "$(cm 9003 'cromford-board[bot]' Bot 2026-10-09T11:00:00Z | arr)"
[ "$RC" = 1 ] && ok || bad "§2b a newer uncited triage App comment must refuse (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "$STAMP0" "$( { cm 9004 'coderabbitai[bot]' Bot 2026-10-09T11:00:00Z; cm 9005 'mergify[bot]' Bot 2026-10-09T11:05:00Z; } | arr)"
[ "$RC" = 0 ] && ok || bad "§2c third-party bots must never refuse (rc=$RC out=$OUT)"
classify "$PLAN_CITED" "$STAMP0" "$C_NEW"
[ "$RC" = 0 ] && ok || bad "§2d the plan that lists the newer column comment must pass (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "$STAMP0" "$(cm 9001 operator User 2026-10-09T09:00:00Z 2026-10-09T11:30:00Z | arr)"
[ "$RC" = 1 ] && ok || bad "§2e an old comment edited after the plan must refuse (rc=$RC out=$OUT)"
printf '# Plan\nsee IC_kwDOfixture9002 for the column\n' > "$T/plan-node.md"
classify "$T/plan-node.md" "$STAMP0" "$C_NEW"
[ "$RC" = 0 ] && ok || bad "§2f a node-id citation must count (rc=$RC out=$OUT)"
printf '# Plan\nhttps://github.com/example-org/cromford/issues/5799#issuecomment-9002\n' > "$T/plan-url.md"
classify "$T/plan-url.md" "$STAMP0" "$C_NEW"
[ "$RC" = 0 ] && ok || bad "§2f an issuecomment- URL citation must count (rc=$RC out=$OUT)"
printf '# Plan\nsee 190027 and 90021\n' > "$T/plan-sub.md"
classify "$T/plan-sub.md" "$STAMP0" "$C_NEW"
[ "$RC" = 1 ] && ok || bad "§2g an id seen only inside a longer number must not count (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "$STAMP0" "$(cm 9001 operator User 2026-10-09T09:00:00Z | arr)"
[ "$RC" = 0 ] && ok || bad "§2h a comment older than the plan must not refuse (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "" "$C_NEW"
[ "$RC" = 2 ] && [ "${OUT%%$'\t'*}" = unreadable ] && ok || bad "§2i an empty since must be rc 2 unreadable (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" garbage "$C_NEW"
[ "$RC" = 2 ] && ok || bad "§2i a garbage since must be rc 2 (rc=$RC out=$OUT)"
classify "$PLAN_PLAIN" "$STAMP0" "$( for i in 1 2 3 4 5 6 7; do cm "800$i" operator User "2026-10-09T11:0$i:00Z"; done | arr)"
{ [ "$RC" = 1 ] && grep -q '+2 more' <<<"$OUT"; } && ok || bad "§2j seven uncited comments name five and '+2 more' (out=$OUT)"

echo "--- §3 own-post ledger"
B3="$T/b3"; mkdir -p "$B3"
printf 'BUILD BLOCKED notice\nline two\n' > "$T/own-body.md"
(HARNESS="$H"; . "$LIB" && ptg_own_post "$B3" "$T/own-body.md")
[ "$(wc -l < "$B3/own-comments.sha256" 2>/dev/null)" = 1 ] && ok || bad "§3a ptg_own_post must write one sha line"
printf 'BUILD BLOCKED notice  \r\nline two\r\n\r\n' > "$T/own-crlf.md"
(HARNESS="$H"; . "$LIB" && ptg_own_post "$B3" "$T/own-crlf.md")
[ "$(sort -u "$B3/own-comments.sha256" 2>/dev/null | wc -l)" = 1 ] && ok || bad "§3b CRLF and trailing-space variants must hash the same"
C_OWN=$(cm 9010 'cromford-board[bot]' Bot 2026-10-09T12:00:00Z '' "$(printf 'BUILD BLOCKED notice\nline two')" | arr)
classify "$PLAN_PLAIN" "$STAMP0" "$C_OWN" "$B3/own-comments.sha256"
[ "$RC" = 0 ] && ok || bad "§3c the build's own notice must not refuse its plan (rc=$RC out=$OUT)"
C_OWNX=$(cm 9010 'cromford-board[bot]' Bot 2026-10-09T12:00:00Z '' "$(printf 'BUILD BLOCKED notice!\nline two')" | arr)
classify "$PLAN_PLAIN" "$STAMP0" "$C_OWNX" "$B3/own-comments.sha256"
[ "$RC" = 1 ] && ok || bad "§3c one extra character is not our post and must refuse (rc=$RC out=$OUT)"

echo "--- §4 call site A (reused or adopted plan)"
xb 'plan thread gate (BH-5799)' "$T/gate-a.sh"
[ -s "$T/gate-a.sh" ] && ok || bad "§4 could not extract '# >>> plan thread gate (BH-5799)' from the pipeline"
RUN=0
run_a() { # run_a <case> [VAR=VAL ...] — drives block A in $BLD, PP_DIR from $PPD; rc in $RA
  RUN=$((RUN+1)); BLD="$H/builds/a-$RUN"; mkdir -p "$BLD"
  ( cd "${A_CWD:-$H}" || exit 9
    HARNESS="$H"; PROJECT=cromford; KEY=BH-5799; BUILD="$BLD"; PP_DIR="${PPD:-}"
    PP_OUTCOME=$(cat "$BLD/preplan-outcome" 2>/dev/null); PP_RESUMED=0; BASE=main
    [ $# -gt 0 ] && export "$@"
    eval "$GH_STUB"
    STAMP() { printf '2026-10-09 12:00:00Z'; }
    PLAN_IS_BLOCKED() { head -1 "$1" | grep -q '^BLOCKED'; }
    BB() { printf 'BB %s %s\n' "$1" "${6:-}" >> "$BUILD/bb.log"; }
    RESULT() { printf '%s\n' "$1" > "$BUILD/RESULT"; }
    # shellcheck source=/dev/null
    . "$T/gate-a.sh"; echo fell-through > "$BUILD/fell-through" ) >/dev/null 2>&1; RA=$?
}
seed_a() { # seed_a <plan> [stamp|-] [preplan-outcome] — the next $BLD, pre-seeded
  local b="$H/builds/a-$((RUN+1))"; mkdir -p "$b"
  cp "$1" "$b/plan.md"; echo fp > "$b/ticket-fp"; echo cfp > "$b/call-fp"
  [ "${2:--}" != - ] && printf '%s\n' "$2" > "$b/plan-thread-at"
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$b/preplan-outcome"
  return 0
}
pp_dir() { PPD="$H/plans/cromford-BH-5799"; mkdir -p "$PPD"; echo x > "$PPD/plan.md"; }
rm -f "$H/page"*.json "$H/gh.rc"; echo "$C_NEW" > "$H/page1.json"
pp_dir; seed_a "$PLAN_PLAIN" "$STAMP0" "HIT adopted"; run_a 4a
{ [ ! -e "$BLD/plan.md" ] && [ -s "$BLD/plan.md.thread-refused" ]; } && ok \
  || bad "§4a an uncited newer comment must move the reused plan aside"
[ ! -e "$PPD" ] && ok || bad "§4a the hub pre-plan dir must be removed so it is not adopted again"
case "$(head -1 "$BLD/preplan-outcome" 2>/dev/null)" in STALE*9002*) ok ;; *) bad "§4a preplan-outcome must start STALE and name 9002 (got: $(cat "$BLD/preplan-outcome" 2>/dev/null))" ;; esac
{ [ ! -e "$BLD/ticket-fp" ] && [ ! -e "$BLD/call-fp" ] && [ ! -e "$BLD/plan-thread-at" ]; } && ok \
  || bad "§4a ticket-fp, call-fp and plan-thread-at must be removed"
[ "$(grep -c 'PLAN_THREAD_REFUSED' "$BLD/pipeline.log" 2>/dev/null)" = 1 ] && ok \
  || bad "§4a exactly one PLAN_THREAD_REFUSED line (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"

[ "$RA" = 0 ] && [ -e "$BLD/fell-through" ] && [ ! -e "$BLD/RESULT" ] && ok \
  || bad "§4a a fresh (not resumed) build must fall through to plan fresh, not end the run (rc=$RA)"

# 4e/4f (lead review of e8a769a8): a RESUMED build re-entered its branch with
# the first execute's commits, and EXECUTE skips on a branch that carries them.
# Planning fresh there would ship the old diff under a plan citing the comment.
# So a resumed build, or a branch already carrying a diff, ends PLAN_STALE
# (exit 3), the same as call site B.
seed_a "$PLAN_PLAIN" "$STAMP0"; run_a 4e RESUME_BUILD=/x/build
{ [ "$RA" = 3 ] && [ ! -e "$BLD/fell-through" ]; } && ok || bad "§4e a resumed build must end the run (exit 3), got rc=$RA"
case "$(cat "$BLD/RESULT" 2>/dev/null)" in "PLAN_STALE"*9002*) ok ;; *) bad "§4e RESULT must be PLAN_STALE naming 9002 (got: $(cat "$BLD/RESULT" 2>/dev/null))" ;; esac
{ [ ! -e "$BLD/plan.md" ] && [ -s "$BLD/plan.md.thread-refused" ]; } && ok || bad "§4e the refused plan is still moved aside"
grep -q '^BB plan_stale' "$BLD/bb.log" 2>/dev/null && ok || bad "§4e the board beat must say plan_stale"
grep -q 'planning fresh' "$BLD/pipeline.log" 2>/dev/null && bad "§4e must not log 'planning fresh'" || ok
GW="$T/gw"; mkdir -p "$GW"
( cd "$GW" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
  && git checkout -q -b ticket/bh-5799 && echo x > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m work ) \
  || bad "§4f fixture repo"
seed_a "$PLAN_PLAIN" "$STAMP0"; A_CWD="$GW" run_a 4f
{ [ "$RA" = 3 ]; } && ok || bad "§4f a branch already carrying a diff over BASE must end PLAN_STALE (exit 3), got rc=$RA"
( cd "$GW" && git checkout -q main ) || true
seed_a "$PLAN_PLAIN" "$STAMP0"; A_CWD="$GW" run_a 4g
{ [ "$RA" = 0 ] && [ -e "$BLD/fell-through" ]; } && ok || bad "§4g a branch with no diff over BASE plans fresh, got rc=$RA"

pp_dir; seed_a "$PLAN_CITED" "$STAMP0" "HIT adopted"; run_a 4b
{ cmp -s "$BLD/plan.md" "$PLAN_CITED" && [ ! -e "$BLD/plan.md.thread-refused" ] && [ -d "$PPD" ]; } && ok \
  || bad "§4b a plan that cites the newer comment must be reused untouched"
grep -q 'plan-thread: ok' "$BLD/pipeline.log" 2>/dev/null && ok || bad "§4b the ok line must be logged"

seed_a "$PLAN_PLAIN" "$STAMP0"; run_a 4c PLAN_THREAD_GATE_ENFORCE=0
{ cmp -s "$BLD/plan.md" "$PLAN_PLAIN" && [ "$(grep -c 'PLAN_THREAD_WARN' "$BLD/pipeline.log" 2>/dev/null)" = 1 ]; } && ok \
  || bad "§4c enforce=0 must warn once and keep the plan (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"

# 4d: an adopted pre-plan with NO stamp cannot say when it read the thread, so
# every comment counts as newer; an uncited one refuses it.
echo "$(cm 9001 operator User 2026-10-08T09:00:00Z | arr)" > "$H/page1.json"
pp_dir; seed_a "$PLAN_PLAIN" - "HIT adopted"; run_a 4d
[ ! -e "$BLD/plan.md" ] && [ -s "$BLD/plan.md.thread-refused" ] && ok \
  || bad "§4d an adopted pre-plan with no stamp and an uncited comment must be refused (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
# 4d': the same with an empty thread is adopted
echo '[]' > "$H/page1.json"
pp_dir; seed_a "$PLAN_PLAIN" - "HIT adopted"; run_a 4d2
cmp -s "$BLD/plan.md" "$PLAN_PLAIN" && ok || bad "§4d an adopted pre-plan with no stamp and an empty thread must be kept"

# 4e: a resumed dir with no stamp reads plan.md's mtime
echo "$(cm 9001 operator User 2026-10-08T09:00:00Z | arr)" > "$H/page1.json"
seed_a "$PLAN_PLAIN" -; touch -d '2026-10-09T10:00:00Z' "$H/builds/a-$((RUN+1))/plan.md"; run_a 4e
{ cmp -s "$BLD/plan.md" "$PLAN_PLAIN" && grep -q 'no stamp, using plan.md mtime' "$BLD/pipeline.log" 2>/dev/null; } && ok \
  || bad "§4e a resume with no stamp uses the plan.md mtime (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"

# 4f: a BLOCKED plan is not judged here (the checkpoint already re-plans it)
echo "$C_NEW" > "$H/page1.json"
printf 'BLOCKED-NEEDS-CLARIFICATION\n' > "$T/plan-blocked.md"
seed_a "$T/plan-blocked.md" "$STAMP0"; run_a 4f
[ -s "$BLD/plan.md" ] && [ ! -e "$BLD/plan.md.thread-refused" ] && ok || bad "§4f a BLOCKED plan must be left to the checkpoint"

echo "--- §5 call site B (pre-review)"
xb 'plan thread pre-review (BH-5799)' "$T/gate-b.sh"
[ -s "$T/gate-b.sh" ] && ok || bad "§5 could not extract '# >>> plan thread pre-review (BH-5799)' from the pipeline"
run_b() { # run_b [VAR=VAL ...] — the block, then a marker proving it fell through; rc in $RB
  RUN=$((RUN+1)); BLD="$H/builds/b-$RUN"; mkdir -p "$BLD"
  cp "$PLAN_PLAIN" "$BLD/plan.md"; printf '%s\n' "$STAMP0" > "$BLD/plan-thread-at"
  [ -n "${PLANF:-}" ] && cp "$PLANF" "$BLD/plan.md"
  [ -n "${OWNF:-}" ] && cp "$OWNF" "$BLD/own-comments.sha256"
  : > "$H/gh.log"
  ( HARNESS="$H"; PROJECT=cromford; KEY=BH-5799; BUILD="$BLD"
    [ $# -gt 0 ] && export "$@"
    eval "$GH_STUB"
    STAMP() { printf '2026-10-09 12:00:00Z'; }
    BB() { printf 'BB %s %s\n' "$1" "${6:-}" >> "$BUILD/bb.log"; }
    RESULT() { printf '%s\n' "$1" > "$BUILD/RESULT"; }
    # shellcheck source=/dev/null
    . "$T/gate-b.sh"
    : > "$BUILD/fell-through" ) >/dev/null 2>&1
  RB=$?
}
echo "$C_NEW" > "$H/page1.json"; rm -f "$H/gh.rc"
PLANF="" run_b
{ [ "$RB" = 3 ] && case "$(cat "$BLD/RESULT" 2>/dev/null)" in "PLAN_STALE uncited comment(s) newer than the plan: 9002"*) true ;; *) false ;; esac; } && ok \
  || bad "§5a an uncited newer comment must end PLAN_STALE naming 9002, exit 3 (rc=$RB RESULT=$(cat "$BLD/RESULT" 2>/dev/null))"
{ [ ! -e "$BLD/plan.md" ] && [ -s "$BLD/plan.md.thread-refused" ] && [ ! -e "$BLD/plan-thread-at" ] && [ ! -e "$BLD/fell-through" ]; } && ok \
  || bad "§5a plan.md must be moved aside and the stage must stop"
grep -q '^BB plan_stale' "$BLD/bb.log" 2>/dev/null && ok || bad "§5a the board beat must say plan_stale"
PLANF="$PLAN_CITED" run_b
{ [ "$RB" = 0 ] && [ ! -e "$BLD/RESULT" ] && [ -e "$BLD/fell-through" ] && grep -q 'plan-thread: ok' "$BLD/pipeline.log"; } && ok \
  || bad "§5b a cited comment must continue with one ok line (rc=$RB log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
echo 75 > "$H/gh.rc"; PLANF="" run_b; rm -f "$H/gh.rc"
{ [ "$RB" = 0 ] && [ ! -e "$BLD/RESULT" ] && grep -q 'fails open' "$BLD/pipeline.log" 2>/dev/null; } && ok \
  || bad "§5c a rate-limited thread must fail open with one line (rc=$RB log: $(cat "$BLD/pipeline.log" 2>/dev/null))"
echo /api/board > "$H/prefix"; PLANF="" run_b; echo - > "$H/prefix"
{ [ "$RB" = 0 ] && [ ! -s "$H/gh.log" ] && grep -q 'n/a' "$BLD/pipeline.log" 2>/dev/null; } && ok \
  || bad "§5d an in-app board must make no gh call and log n/a (gh: $(cat "$H/gh.log"))"
for i in $(seq 1 100); do cm "$((7000+i))" operator User 2026-10-09T09:00:00Z; done | arr > "$H/page1.json"
cm 9002 operator User 2026-10-09T11:00:00Z | arr > "$H/page2.json"
PLANF="" run_b
{ [ "$RB" = 3 ] && grep -q '9002' "$BLD/RESULT" 2>/dev/null; } && ok || bad "§5e a newer comment on page 2 must be found (rc=$RB)"
grep -q 'page=2' "$H/gh.log" && ok || bad "§5e page 2 must be read"
# the own-post ledger protects a resolver ACCEPT resume: our notice is newer
# than the plan, and the build must not refuse its own plan on it
rm -f "$H/page2.json"; echo "$C_OWN" > "$H/page1.json"
OWNF="$B3/own-comments.sha256" PLANF="" run_b
[ "$RB" = 0 ] && [ ! -e "$BLD/RESULT" ] && ok || bad "§5f the build's own BLOCKED notice must not refuse its plan (rc=$RB)"
echo "$C_NEW" > "$H/page1.json"; PLANF="" run_b PLAN_THREAD_GATE_ENFORCE=0
{ [ "$RB" = 0 ] && [ -s "$BLD/plan.md" ] && grep -q 'PLAN_THREAD_WARN' "$BLD/pipeline.log"; } && ok \
  || bad "§5g enforce=0 must warn and continue (rc=$RB)"

echo "--- §6 the knob"
# resolved from a registry rendered in the scratch tree, never the checkout's
scratch_install_closure bin/lanes-build.sh "$H" >/dev/null || bad "§6 cannot install bin/lanes-build.sh"
mkdir -p "$H/catalog"; cp -r "$SRC/catalog/lanes.d" "$H/catalog/"
V=$( cd "$H" && unset PLAN_THREAD_GATE_ENFORCE LANE_REGISTRY; HARNESS="$H"
     . bin/lib/lane-gate.sh && . bin/lib/lanes-registry.sh \
       && LANE_REGISTRY=$(lanes_json_path "$H") && export LANE_REGISTRY \
       && lib_env_apply plan-thread >/dev/null 2>&1; printf '%s' "${PLAN_THREAD_GATE_ENFORCE:-unset}" ) 2>/dev/null
[ "$V" = 1 ] && ok || bad "§6 lib_env_apply plan-thread must resolve PLAN_THREAD_GATE_ENFORCE=1 from the registry (got: $V)"
jq -e '.libs[] | select(.id=="plan-thread") | .knobs[] | select(.env=="PLAN_THREAD_GATE_ENFORCE" and .default==1 and .min==0 and .max==1)' \
  "$SRC/catalog/lanes.d/_lib.plan-thread.json" >/dev/null 2>&1 && ok || bad "§6 the knob fragment must declare PLAN_THREAD_GATE_ENFORCE 0..1 default 1"
E1=$(HARNESS="$H"; unset PLAN_THREAD_GATE_ENFORCE; . "$LIB" 2>/dev/null && ptg_enforce)
E0=$(HARNESS="$H"; export PLAN_THREAD_GATE_ENFORCE=0; . "$LIB" 2>/dev/null && ptg_enforce)
[ "$E1" = 1 ] && [ "$E0" = 0 ] && ok || bad "§6 ptg_enforce: default 1, env 0 is warn (got $E1/$E0)"

echo "--- §7 prompts and stamps"
xb 'plan prompt' "$T/plan-prompt.sh"
[ -s "$T/plan-prompt.sh" ] && ok || bad "§7 could not extract the plan prompt block"
BLD="$H/builds/p7"; mkdir -p "$BLD"
( HARNESS="$H"; PROJECT=cromford; KEY=BH-5799; TICKET=5799; BUILD="$BLD"; PLAN_MODEL=m
  PLAN_AMBIGUITY_RULE=""; KIND_HINT_LINE=""; CARRIED_NOTE_LINE=""
  . "$LIB"
  CC() { printf '%s' "$5" > "$BUILD/prompt.txt"; }
  # shellcheck source=/dev/null
  . "$T/plan-prompt.sh" ) >/dev/null 2>&1
for s in '## Spec changes from comments' 'NEWEST FIRST' "'none'"; do
  grep -qF "$s" "$BLD/prompt.txt" 2>/dev/null && ok || bad "§7 the plan prompt must carry: $s"
done
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$BLD/plan-thread-at" 2>/dev/null && ok \
  || bad "§7 the fresh plan must write the plan-thread-at stamp"
# run-preplan.sh, driven as shipped with an agent-call.sh stub in the scratch tree
P7="$T/pp"; mkdir -p "$P7/bin/lib" "$P7/logs" "$P7/env" "$P7/plans" "$P7/state/model-routes" "$T/repos7/.preplan-cromford" "$T/fb7"
scratch_install_closure bin/run-preplan.sh "$P7" >/dev/null || bad "§7 cannot install the run-preplan closure"
: > "$P7/env/global.env"; : > "$P7/logs/cost.csv"
printf '0\tmodel-fixture\tclaude\n' > "$P7/state/model-routes/plan@cromford.tsv"
cat > "$P7/bin/agent-call.sh" <<'EOF2'
#!/bin/bash
printf '%s' "$6" > "$(dirname "$5")/prompt.txt"
[ -n "${STUB_WRITE_PLAN:-}" ] && printf '# plan\nSIZE: S\n' > "$(dirname "$5")/plan.md"
exit 0
EOF2
chmod +x "$P7/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fb7/git"; chmod +x "$T/fb7/git"
cp "$H/bin/fleet-conf.sh" "$P7/bin/fleet-conf.sh"; cp "$H/prefix" "$P7/prefix"
preplan() { env -u JOBS_URL PATH="$T/fb7:$PATH" HARNESS="$P7" REPOS_ROOT="$T/repos7" PREPLAN_SPECULATIVE=0 "$@" \
  bash "$P7/bin/run-preplan.sh" cromford 5799 BH-5799 >/dev/null 2>&1; }
preplan STUB_WRITE_PLAN=1
PPP="$P7/plans/cromford-BH-5799"
for s in '## Spec changes from comments' 'NEWEST FIRST' "'none'"; do
  grep -qF "$s" "$PPP/prompt.txt" 2>/dev/null && ok || bad "§7 the pre-plan prompt must carry: $s"
done
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$PPP/plan-thread-at" 2>/dev/null && ok \
  || bad "§7 the pre-plan must write plan-thread-at beside its plan"
# a session that writes no plan leaves no stamp behind
scratch_rm "$PPP"; preplan STUB_WRITE_PLAN=
[ ! -e "$PPP/plan-thread-at" ] && ok || bad "§7 a pre-plan with no plan.md must leave no plan-thread-at"
# the hub relays the stamp to the Fly machine with the rest of the consumable record
grep -qE 'for f in base-sha planned-files.txt ticket-fp plan-thread-at; do' "$SRC/bin/fly-pool.sh" && ok \
  || bad "§7 bin/fly-pool.sh push_preplan must relay plan-thread-at"
# the adopt arm copies the stamp
xb 'preplan adopt' "$T/adopt.sh"
grep -q 'plan-thread-at' "$T/adopt.sh" && ok || bad "§7 the pre-plan HIT arm must copy plan-thread-at"

echo "--- §8 PR body section and the plan gate"
xb 'spec changes section (BH-5799)' "$T/spec.sh"
[ -s "$T/spec.sh" ] && ok || bad "§8 could not extract '# >>> spec changes section (BH-5799)'"
spec() { BLD="$T/b8"; mkdir -p "$BLD"; cp "$1" "$BLD/plan.md"
  SPEC_OUT=$(BUILD="$BLD"; . "$T/spec.sh" 2>/dev/null; printf '%s' "${SPEC_CHANGES_SECTION:-}"); }
spec "$PLAN_CITED"
{ grep -q '^## Spec changes from comments' <<<"$SPEC_OUT" && grep -q '9002 (operator): adds region column' <<<"$SPEC_OUT" && ! grep -q '^## Tasks' <<<"$SPEC_OUT"; } && ok \
  || bad "§8 the section must reach the PR body verbatim and stop at the next heading (got: $SPEC_OUT)"
printf '# Plan\n## Tasks\nSIZE: S\n' > "$T/plan-nosec.md"; spec "$T/plan-nosec.md"
grep -qF "The plan carried no 'Spec changes from comments' section." <<<"$SPEC_OUT" && ok \
  || bad "§8 a plan with no section gets the one-line note (got: $SPEC_OUT)"
# TEST-CHANGE: the section moved after REPRO_SECTION. main's
# prebuild-repro-contract A13f pins the literal
# "${ASSUMPTIONS_SECTION}${PREPR_SECTION:-}${REPRO_SECTION:-}", and the queue
# batch for #5864 failed on it. The section is still in the PR body argument.
grep -qF '${REPRO_SECTION:-}${SPEC_CHANGES_SECTION:-}' "$SRC/bin/lib/rb/pr.sh" && ok \
  || bad "§8 the PR body argument must carry SPEC_CHANGES_SECTION (after REPRO_SECTION)"
PGA="$T/pg-a.md"; PGB="$T/pg-b.md"
printf '# Plan\n## Tasks\n### Task 1\nVALIDATE: a\nSATISFIES: b\n### Task 2\nVALIDATE: c\nSATISFIES: d\n\nSIZE: S\n' > "$PGA"
printf '# Plan\n## Spec changes from comments\n- Task 3: region column, from 6083307738 (operator)\n- 6083307739 cadence → Task 4\n## Tasks\n### Task 1\nVALIDATE: a\nSATISFIES: b\n### Task 2\nVALIDATE: c\nSATISFIES: d\n\nSIZE: S\n' > "$PGB"
GA=$(bash "$SRC/bin/plan-gate.sh" "$PGA" 2>/dev/null | grep -E '^PLAN_(TASKS|UNTRACED):')
GB=$(bash "$SRC/bin/plan-gate.sh" "$PGB" 2>/dev/null | grep -E '^PLAN_(TASKS|UNTRACED):')
{ [ -n "$GA" ] && [ "$GA" = "$GB" ]; } && ok || bad "§8 the section must not change the plan gate's task count (without: $GA / with: $GB)"

echo "--- §9 lead review"
awk '/^# >>> ticket thread render \(BH-5799\)$/{f=1;next} /^# <<< ticket thread render \(BH-5799\)$/{exit} f' "$SRC/bin/lead-review.sh" > "$T/render.sh"
[ -s "$T/render.sh" ] && ok || bad "§9 could not extract '# >>> ticket thread render (BH-5799)' from bin/lead-review.sh"
W9="$T/w9"
printf '{"title":"The ask","body":"spec text"}' > "$W9.issue"
jq -nc '[{id:9002,user:{login:"operator"},created_at:"2026-10-09T11:00:00Z",body:"add a region column"},
         {user:{login:"client"},created_at:"2026-10-09T12:00:00Z",body:"no id here"}]' > "$W9.comments"
( WT="$W9"; tn=42; tdone=1
  # shellcheck source=/dev/null
  . "$T/render.sh" ) >/dev/null 2>&1
grep -q '^### operator at 2026-10-09T11:00:00Z$' "$W9.thread" 2>/dev/null && ok || bad "§9 the heading line must stay byte-identical"
nx=$(awk '/^### operator at /{f=1;next} f&&NF{print;exit}' "$W9.thread" 2>/dev/null)
[ "$nx" = "comment-id: 9002" ] && ok || bad "§9 the line after the heading must be 'comment-id: 9002' (got: $nx)"
grep -q 'comment-id: *$\|comment-id: null' "$W9.thread" 2>/dev/null && bad "§9 a comment with no id must get no empty id line" || ok
# TEST-CHANGE: v3 became v4 in the main merge (main's BH-5797 took v3 first),
# then v6 (main's BH-5800 took v4 and BH-5802 took v5 first). The assertion is
# the same: this PR's checklist change carries its own version.
# TEST-CHANGE: BH-6381 took v7 (item 14). The check is now "v6 or later":
# BH-5799's change is in v6, and every later version keeps it.
ckv=$(sed -n 's/^Checklist-Version: \([0-9][0-9]*\)$/\1/p;1q' "$SRC/prompts/lead-review-checklist.md")
[ -n "$ckv" ] && [ "$ckv" -ge 6 ] && ok || bad "§9 the checklist must be v6 or later (got '${ckv}')"
grep -q 'Spec changes from comments' "$SRC/prompts/lead-review-checklist.md" && ok || bad "§9 checklist item 1 must name the Spec changes section"
grep -q '## Spec changes from comments' "$SRC/prompts/plan-contract.md" && ok || bad "§9 plan-contract.md must name the section"

echo "--- §10 the stamp in the coordination DB row"
P10="$T/p10"; mkdir -p "$P10/src" "$P10/dst"
printf '# plan\n' > "$P10/src/plan.md"; echo abc1234 > "$P10/src/base-sha"; echo "$STAMP0" > "$P10/src/plan-thread-at"
PUT_BODY=$( . "$SRC/bin/lib/jobs/queue.sh" 2>/dev/null
  _jobs_req() { printf '%s' "$3" > "$P10/put.json"; return 0; }
  JOBS_BOX=box-fixture preplan_put cromford BH-5799 "$P10/src" >/dev/null; cat "$P10/put.json" 2>/dev/null)
[ "$(jq -r '.thread_at // ""' <<<"$PUT_BODY" 2>/dev/null)" = "$STAMP0" ] && ok \
  || bad "§10a preplan_put must send plan-thread-at as thread_at (body: $PUT_BODY)"
rm -f "$P10/src/plan-thread-at"
PUT_BODY=$( . "$SRC/bin/lib/jobs/queue.sh" 2>/dev/null
  _jobs_req() { printf '%s' "$3" > "$P10/put.json"; return 0; }
  JOBS_BOX=box-fixture preplan_put cromford BH-5799 "$P10/src" >/dev/null; cat "$P10/put.json" 2>/dev/null)
jq -e 'has("thread_at") | not' <<<"$PUT_BODY" >/dev/null 2>&1 && ok \
  || bad "§10a a dir with no stamp must send no thread_at (body: $PUT_BODY)"
fetch10() { # fetch10 <row-json> — preplan_fetch into $P10/dst with a stubbed row
  ( . "$SRC/bin/lib/preplan-lib.sh" 2>/dev/null
    preplan_get() { printf '%s\n' "$ROW10"; }
    ROW10="$1" preplan_fetch "$H" cromford BH-5799 "$P10/dst" ) >/dev/null 2>&1
}
fetch10 "$(jq -nc --arg t "$STAMP0" '{ticket_key:"BH-5799",plan_md:"# plan\n",base_sha:"abc1234",thread_at:$t}')"
[ "$(cat "$P10/dst/plan-thread-at" 2>/dev/null)" = "$STAMP0" ] && ok \
  || bad "§10b preplan_fetch must write the row's thread_at to plan-thread-at"
fetch10 "$(jq -nc '{ticket_key:"BH-5799",plan_md:"# plan\n",base_sha:"abc1234",thread_at:null}')"
[ ! -e "$P10/dst/plan-thread-at" ] && ok \
  || bad "§10c a row with no thread_at must leave no plan-thread-at behind (a stale one included)"
# 10d: the case the DB path used to refuse. The fetched stamp is the since, the
# only comment is older than it, the plan says `none`: adopted.
fetch10 "$(jq -nc --arg t "$STAMP0" '{ticket_key:"BH-5799",plan_md:"# plan\n",base_sha:"abc1234",thread_at:$t}')"
echo "$(cm 9001 operator User 2026-10-08T09:00:00Z | arr)" > "$H/page1.json"
pp_dir; seed_a "$PLAN_PLAIN" "$(cat "$P10/dst/plan-thread-at" 2>/dev/null)" "HIT fresh"; run_a 10d
{ cmp -s "$BLD/plan.md" "$PLAN_PLAIN" && [ ! -e "$BLD/plan.md.thread-refused" ]; } && ok \
  || bad "§10d a DB-adopted pre-plan with an old uncited comment and 'none' must be adopted (log: $(cat "$BLD/pipeline.log" 2>/dev/null))"

echo "--- §11 the resolver's adjudication post"
awk 'index($0, "# >>> adjudication issue post (BH-5799)") {f=1;next} index($0, "# <<< adjudication issue post (BH-5799)") {exit} f' \
  "$SRC/bin/blocked-resolver.sh" > "$T/adj.sh"
[ -s "$T/adj.sh" ] && ok || bad "§11 could not extract '# >>> adjudication issue post (BH-5799)' from bin/blocked-resolver.sh"
REC11="$H/builds/r11"
adj11() { # adj11 <post-rc> — drives the block; the posted body lands in $T/adj-posted.md
  scratch_rm "$REC11"; mkdir -p "$REC11"; rm -f "$T/adj-posted.md"
  ( H="$H"; p=cromford; tkey=BH-5799; slug=example-org/cromford; rec="$REC11"
    adj_model=model-fixture; reason=test-tamper; verdict=ACCEPT; adj_prefix=""
    adj="$T/adj-run.txt"; printf 'the test was split, not weakened\nACCEPT\n' > "$adj"
    br_issue_comment() { printf '%s\n' "$3" > "$T/adj-posted.md"; return "$POST_RC"; }
    run() { . "$T/adj.sh"; }
    POST_RC="$1" run ) >/dev/null 2>&1
}
adj11 0
[ -s "$T/adj-posted.md" ] && ok || bad "§11a the block must post the adjudication on the issue"
C11=$(cm 9020 operator User 2026-10-09T12:00:00Z '' "$(cat "$T/adj-posted.md" 2>/dev/null)" | arr)
classify "$PLAN_PLAIN" "$STAMP0" "$C11" "$REC11/own-comments.sha256"
[ "$RC" = 0 ] && ok || bad "§11a the resumed plan must not be refused by the resolver's own adjudication (rc=$RC out=$OUT)"
adj11 1
[ ! -e "$REC11/own-comments.sha256" ] && ok || bad "§11b a post that failed must not enter the own-post ledger"

echo
echo "plan-thread-gate.bh-5799: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
