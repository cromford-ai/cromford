#!/bin/bash
# tests/queue-culprit-flip.bh-5373-test.sh — BH-5373 (BH-5356.1): THE CULPRIT
# FLIP, held back (lead review 2026-10-14, the operator's replay 6167883368). BH-4980
# shipped the impact map dark. This ticket keeps it dark on the default path:
# MC_BATCH_IMPACT stays 1 (shadow) in the catalog, and the default Mergify
# queue still bisects (no batch_max_failure_resolution_attempts key). It ships
# the two lib fixes the replay proved (bin/lib/flaky.sh, bin/lib/mc-batch-impact.sh).
# Enforce (2) is still reachable by an env value or a settings row, and the
# cases below that test enforce pass MC_BATCH_IMPACT=2 explicitly.
#
#   T1     no MC_BATCH_IMPACT in the env: the real lane_knob reads this tree's
#          catalog, the mode is 1, the decision is only logged, and the gate
#          decides exactly as mode 0
#   T1e    MC_BATCH_IMPACT=2: the gate ejects the one PR that reaches the
#          failing suite, re-queues the others and never runs the solo re-run
#   T2     an unmapped check: every member asks the solo re-run, as mode 0
#   T3     bisect stays on: the conf sets no batch_failure_attempts and the
#          committed .mergify.yml has no batch_max_failure_resolution_attempts
#   U1-U2  an `unknown` map answer (log-unreadable, not-paths) under the
#          shipped defaults: the PR Mergify's bisect names keeps the culprit
#          path and is not re-queued, exactly as mode 0
#   N1-N5  the negatives: always-suite, two members, a full row, Mergify's own
#          pick, the main-red freeze. None of them ejects on the map.
#   K1-K2  the switches with no deploy: an env value and a per-project settings row
#   E1-E3  the strict log parse drops GitHub's run: script echo, so a real red
#          draft yields its suites, not `skip not-paths` (bin/lib/flaky.sh)
#   A1     a member that adds the failing suite reaches it
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-culprit-flip.bh-5373-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BIM_LIB="$DIR/bin/lib/mc-batch-impact.sh"
BEJ_LIB="$DIR/bin/lib/mc-batch-eject.sh"
LG_LIB="$DIR/bin/lib/lane-gate.sh"
for f in "$BIM_LIB" "$BEJ_LIB" "$LG_LIB"; do [ -r "$f" ] || bad "missing $f"; done
# The registry lane_knob reads, composed from this tree's catalog/lanes.d the
# way every box composes it (catalog/lanes.json is a git-ignored render).
REG="$T/lanes.json"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 && [ -s "$REG" ] \
  || bad "setup: bin/lanes-build.sh could not compose the registry"

SLUG=example-org/cromford
BASE40=abc1234def5678901234567890abcdef12345678
H11=1111111111111111111111111111111111111111
H12=1212121212121212121212121212121212121212
H13=1313131313131313131313131313131313131313
WSUITE=tests/jobs-worker-test.sh
PCHECK='Pure-logic gate fixtures'

# The fixture tree: the real bin/test-impact.sh and a hand-written map.
R="$T/r"; mkdir -p "$R/bin" "$R/tests" "$R/state"
scratch_install_closure bin/test-impact.sh "$R" >/dev/null
MAP="$T/map"
{
  printf 'tests/always-test.sh\t*\n'
  printf '%s\tworker/\n' "$WSUITE"
  printf 'tests/mc-test.sh\tbin/lib/mc/\n'
  printf 'tests/other-test.sh\tbin/other.sh\n'
} | LC_ALL=C sort > "$MAP"
for s in $(cut -f1 "$MAP" | sort -u); do printf '#!/bin/bash\n:\n' > "$R/$s"; done

# settings <json-values> — a fresh settings cache, so lane_knob never calls
# the jobs worker and reads exactly these rows.
settings() {
  jq -nc --argjson fa "$(date +%s)" --argjson v "$1" '{fetched_at: $fa, values: $v, seeded: {}}' \
    > "$R/state/settings-cache.json"
}
settings '{}'

dequeue_comment() { # <head> <draft> <check> [named 0|1]
  local ident=""; [ "${4:-0}" = 1 ] && ident=" · identified as the failing PR"
  local body
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "dequeued", "queue_rule_name": "default"}\n-*- Mergify Payload End -*-\n-->\n# Merge Queue Status\n- ❌ **Checks failed** · on draft #%s%s\n- 🚫 **Left the queue** — `2026-10-13 01:00 UTC` · at `%s`\n## Reason\nThe merge conditions cannot be satisfied due to failing checks\nFailing checks:\n- ❌ [`%s`](https://github.com/example-org/cromford/actions/runs/9%s/job/1)\n## Hint\nfix it\n' \
    "$2" "$ident" "$1" "$3" "$2")
  jq -nc --arg b "$body" '[{id: 1, created_at: "2026-10-13T01:00:00Z", user: {login: "mergify[bot]", type: "Bot"}, body: $b}]'
}

G="$T/g"; mkdir -p "$G"
# g_setup <files11> <files12> <files13> — draft #20 holds #11-#13 and failed
# $WSUITE; Mergify names nobody.
g_setup() {
  local n i=0 heads=("$H11" "$H12" "$H13")
  scratch_rm "$G/s" 2>/dev/null; mkdir -p "$G/s/state" "$G/s/files" "$G/s/comments"
  : > "$G/s/attempts"; : > "$G/s/log"; : > "$G/s/posted"; : > "$G/s/bs-calls"; : > "$G/s/bs-out"
  printf 'merge queue: checking #11 + #12 + #13 together on main (abc1234)' > "$G/s/title-20"
  for n in 11 12 13; do
    tr ' ' '\n' <<<"$1" > "$G/s/files/$n"
    dequeue_comment "${heads[$i]}" 20 "$PCHECK" > "$G/s/comments/$n"
    echo "${heads[$i]}" > "$G/s/head-$n"
    i=$((i+1)); shift
  done
  printf 'ok %s %s 11 12 13\n' "$BASE40" "$WSUITE" > "$G/s/facts"
}
# gate <pr> [env…] — bej_reentry_gate for that member, with the REAL lane-gate
# lib loaded: the mode comes from lane_knob, not from a stub. MC_BATCH_IMPACT
# is removed from the env unless a case passes it. Prints
# rc|FR_WHY|FR_LINE|FR_STATE.
gate() {
  local n="$1"; shift
  ( env -u MC_BATCH_IMPACT -u JOBS_URL -u HARNESS_SECRET "$@" bash -c '
    set -uo pipefail
    S="$1"; BEJ="$2"; BIM="$3"; R="$4"; MAP="$5"; n="$6"; slug="$7"; LG="$8"; REG="$9"
    export HARNESS="$R" HARNESS_REPO="$slug" HARNESS_TEST_SANDBOX=1 MC_BATCH_IMPACT_MAP="$MAP" LANE_REGISTRY="$REG"
    unset H
    MERGES=1; P=bh; MC_ATTEMPTS="$S/attempts"; MC_STATE_DIR="$S/state"
    . "$LG" || exit 9
    mc_log() { echo "$*" >> "$S/log"; }
    mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
    mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
    mc_rest_var() { local __o="$1" __v="" __rc=0; shift; __v=$("$@") || __rc=$?; printf -v "$__o" "%s" "$__v"; return "$__rc"; }
    gh_rest_issue_comments() { cat "$S/comments/$2"; }
    gh_rest() {
      case "$2" in
        */pulls/20) jq -nc --arg t "$(cat "$S/title-20")" "{number: 20, title: \$t, state: \"closed\"}" ;;
        */pulls/*) [ -s "$S/head-${2##*/}" ] || return 44
                   jq -nc --arg h "$(cat "$S/head-${2##*/}")" "{head: {sha: \$h}, state: \"open\"}" ;;
        *) return 44 ;;
      esac
    }
    mc_pr_files() { [ -s "$S/files/$2" ] && cat "$S/files/$2"; }
    gh_rest_comment() { { printf "<<PR %s>>\n" "$2"; cat "$3"; printf "<<END>>\n"; } >> "$S/posted"; }
    mc_requeue_mergify() { echo "$2" >> "$S/requeues"; }
    bs_batch() { echo "$2" >> "$S/bs-calls"; BS_SUITES="tests/jobs-worker-test.sh"; BS_BASE="abc1234def5678901234567890abcdef12345678"; cat "$S/bs-out"; }
    _bs_facts() { _bs_f=$(cat "$S/facts"); [ -n "$_bs_f" ]; }
    fr_reentry_gate() { echo "fr $2" >> "$S/fr-calls"; FR_WHY="fr-said-no"; return 1; }
    fr_mergify_only_unstable() { return 0; }
    . "$BEJ" || exit 9
    declare -F bim_verdict >/dev/null || . "$BIM" || exit 9
    echo "mode=$(bim_mode)" >> "$S/modes"
    rc=0; bej_reentry_gate "$slug" "$n" "$slug#$n" "https://github.com/$slug/pull/$n" "$(cat "$S/head-$n")" CLEAN || rc=$?
    printf "%s|%s|%s|%s\n" "$rc" "${FR_WHY:-}" "${FR_LINE:-}" "${FR_STATE:-}"
  ' _ "$G/s" "$BEJ_LIB" "$BIM_LIB" "$R" "$MAP" "$n" "$SLUG" "$LG_LIB" "$REG" ) 2>>"$G/err"
}
run_all() { # run_all "<prs>" env… — every gate result, what was posted, what re-ran
  local prs="$1" n; shift
  for n in $prs; do printf '#%s %s\n' "$n" "$(gate "$n" "$@")"; done
  printf 'posted:%s\n' "$(cat "$G/s/posted")"
  printf 'bs:%s\n' "$(tr '\n' ' ' < "$G/s/bs-calls")"
}
same_as_off() { # same_as_off <case> <prs> <setup-fn> <env…>
  local c="$1" prs="$2" setup="$3" a b; shift 3
  "$setup"; a=$(run_all "$prs" "$@" MC_BATCH_IMPACT=0)
  "$setup"; b=$(run_all "$prs" "$@")
  [ "$a" = "$b" ] && ok || bad "$c decides exactly as mode 0: $(diff <(echo "$a") <(echo "$b"))"
}
nbs() { grep -c . "$G/s/bs-calls" 2>/dev/null | tr -d ' '; }

# ============================================================================
# T1 — the catalog default is shadow: the map logs, the gate decides as mode 0.
# ============================================================================
g_t1() { g_setup "worker/jobs/src/x.js" "docs/a.md" "bin/lib/mc/x.sh"; }
g_t1; : > "$G/s/modes"; gate 11 >/dev/null
[ "$(sort -u "$G/s/modes")" = "mode=1" ] && ok || bad "T1 bim_mode is 1 with no env value (catalog default): $(cat "$G/s/modes")"
grep -q "BATCH_IMPACT_EJECT $SLUG#11 $H11 — draft=#20 eject 11 $WSUITE mode=1" "$G/s/log" && ok \
  || bad "T1 shadow logs the decision it did not take: $(grep BATCH_IMPACT "$G/s/log")"
grep -q "only this PR reaches it" "$G/s/posted" && bad "T1 shadow posts no culprit comment: $(cat "$G/s/posted")" || ok
same_as_off "T1 the catalog default" "11 12 13" g_t1

# ============================================================================
# T1e — enforce, set by the env. #11 alone touches worker/, the suite that failed.
# ============================================================================
E2=MC_BATCH_IMPACT=2
g_t1; : > "$G/s/modes"
OUT=$(gate 11 "$E2")
[ "$(sort -u "$G/s/modes")" = "mode=2" ] && ok || bad "T1e bim_mode is 2 with MC_BATCH_IMPACT=2 in the env: $(cat "$G/s/modes")"
[ "${OUT%%|*}" = 1 ] && ok || bad "T1e #11 is not re-queued (rc 1): $OUT $(tail -3 "$G/err")"
[ "$(cut -d'|' -f2 <<<"$OUT")" = "queue-ejected — $WSUITE failed in draft #20 and only this PR reaches it (impact map)" ] && ok \
  || bad "T1e #11 FR_WHY names the test: $OUT"
[ "$(grep -c '^<<PR 11>>' "$G/s/posted")" = 1 ] && grep -q "only this one" "$G/s/posted" && ok \
  || bad "T1e exactly one culprit comment on #11: $(cat "$G/s/posted")"
grep -q "BATCH_IMPACT_EJECT $SLUG#11 $H11 — draft=#20 eject 11 $WSUITE mode=2" "$G/s/log" && ok \
  || bad "T1e the enforce line: $(grep BATCH_IMPACT "$G/s/log")"
for n in 12 13; do
  OUT=$(gate "$n" "$E2")
  [ "${OUT%%|*}" = 0 ] && ok || bad "T1e #$n is re-queued (rc 0): $OUT"
  [ "$(cut -d'|' -f3 <<<"$OUT")" = "re-queued: draft #20 failed \`$WSUITE\`, and the impact map says only #11 reaches it. This head's own checks are green." ] && ok \
    || bad "T1e #$n FR_LINE names #11: $OUT"
done
grep -q "^<<PR 1[23]>>" "$G/s/posted" && bad "T1e nothing is posted on a bystander: $(cat "$G/s/posted")" || ok
[ ! -s "$G/s/bs-calls" ] && ok || bad "T1e no solo re-run (bs_batch) for any member: $(cat "$G/s/bs-calls")"
# A second tick posts nothing more.
gate 11 "$E2" >/dev/null
[ "$(grep -c '^<<PR 11>>' "$G/s/posted")" = 1 ] && ok || bad "T1e a second tick posts no second comment"

# ============================================================================
# T2-N5 run under enforce (MC_BATCH_IMPACT=2): they prove what enforce does
# once a settings row turns it on.
# T2 — an unattributable failure (a check outside the check map) bisects as
# today: the solo re-run for every member, and the same answer as mode 0.
# ============================================================================
g_t2() { g_t1; echo "skip job-only" > "$G/s/facts"; }
g_t2; run_all "11 12 13" "$E2" > /dev/null
[ "$(nbs)" = 3 ] && ok || bad "T2 every member asks the solo re-run: $(cat "$G/s/bs-calls")"
grep -q "only this PR reaches it" "$G/s/posted" && bad "T2 no culprit comment on an unmapped check" || ok
same_as_off T2 "11 12 13" g_t2 "$E2"

# ============================================================================
# N1-N5 — the negatives: none ejects on the map.
# ============================================================================
# N1 — the failing suite is an always-suite every member reaches.
g_n1() { g_t1; printf 'ok %s tests/always-test.sh 11 12 13\n' "$BASE40" > "$G/s/facts"; }
g_n1; run_all "11 12 13" "$E2" > /dev/null
[ "$(nbs)" = 3 ] && ! grep -q "only this PR" "$G/s/posted" && ok || bad "N1 an always-suite: solo for all, no eject: $(cat "$G/s/bs-calls")"
same_as_off N1 "11 12 13" g_n1 "$E2"
# N2 — #11 and #12 reach the suite: those two ask the solo re-run, #13 goes back in.
g_n2() { g_setup "worker/jobs/src/x.js" "worker/jobs/src/y.js" "bin/lib/mc/x.sh"
         printf '11 %s pending\n12 %s pending\n13 %s pending\n' "$H11" "$H12" "$H13" > "$G/s/bs-out"; }
g_n2
O11=$(gate 11 "$E2"); O12=$(gate 12 "$E2"); O13=$(gate 13 "$E2")
[ "$(nbs)" = 2 ] && [ "${O13%%|*}" = 0 ] && ok || bad "N2 bs_batch for #11 and #12 only, #13 re-queued: bs=$(nbs) / $O13"
[ "${O11%%|*}" = 1 ] && [ "${O12%%|*}" = 1 ] && ! grep -q "only this PR" "$G/s/posted" && ok \
  || bad "N2 the two candidates wait on the solo verdict, no culprit comment: $O11 / $O12"
grep -q "draft=#20 bisect several 11,12" "$G/s/log" && ok || bad "N2 the several line: $(grep BATCH_IMPACT "$G/s/log")"
# N3 — a full row: #12 and #13 touch the docker test runner, so they reach
# every suite (a top-level workflow file reaches its readers since BH-6876).
# All three are candidates and nobody is ejected on the map.
g_n3() { g_setup "worker/jobs/src/x.js" "bin/run-tests-in-docker.sh" "bin/run-tests-in-docker.sh"; : > "$G/s/bs-out"; }
g_n3; run_all "11 12 13" "$E2" > /dev/null
grep -q "draft=#20 bisect several 11,12,13" "$G/s/log" && ! grep -q "only this PR" "$G/s/posted" && ok \
  || bad "N3 a full row makes every member a candidate: $(grep BATCH_IMPACT "$G/s/log")"
# N4 — Mergify named #12 itself: #12 takes Mergify's culprit path, the map is
# not asked for it, and it decides exactly as mode 0.
g_n4() { g_t1; dequeue_comment "$H12" 20 "$PCHECK" 1 > "$G/s/comments/12"; }
g_n4; gate 12 "$E2" >/dev/null
grep -q "BATCH_IMPACT_[A-Z]* $SLUG#12 " "$G/s/log" && bad "N4 the map is not asked for the PR Mergify named: $(grep BATCH_IMPACT "$G/s/log")" || ok
same_as_off N4 "12" g_n4 "$E2"
# N5 — the main-red freeze is on: nothing is ejected on the map.
g_t1; run_all "11 12 13" MAIN_RED=1 "$E2" > /dev/null
grep -q "only this PR" "$G/s/posted" && bad "N5 the main-red freeze stops a map eject: $(cat "$G/s/posted")" || ok
same_as_off N5 "11 12 13" g_t1 MAIN_RED=1 "$E2"

# ============================================================================
# K — the switches, no deploy needed.
# ============================================================================
# K1 — an env value wins over the catalog default: 1 is shadow, as mode 0 decides.
same_as_off "K1 MC_BATCH_IMPACT=1 in the env is shadow" "11 12 13" g_t1 MC_BATCH_IMPACT=1
grep -q "eject 11 $WSUITE mode=1" "$G/s/log" && ok || bad "K1 shadow still logs the decision: $(grep BATCH_IMPACT "$G/s/log")"
# K2 — the per-project settings row lane.merge-conductor.bh.mc_batch_impact=2
# turns enforce on with no deploy (the later flip, once #6688 lands).
settings '{"lane.merge-conductor.bh.mc_batch_impact": "2"}'
g_t1; : > "$G/s/modes"; OUT=$(gate 11)
[ "$(sort -u "$G/s/modes")" = "mode=2" ] && [ "${OUT%%|*}" = 1 ] && grep -q "only this one" "$G/s/posted" && ok \
  || bad "K2 the per-project row turns the eject on: $(cat "$G/s/modes") / $OUT"
settings '{}'

# ============================================================================
# T3 — bisect stays on: no key in the conf, none in the committed render.
# ============================================================================
MT="$DIR/bin/mergify-template.sh"
CONF="$DIR/config/mergify/repos/cromford.conf"
# compare, not cmp: the committed file carries hand comments the render does not.
OUT=$(bash "$MT" compare "$CONF" "$DIR/.mergify.yml" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "T3 the committed conf matches the committed .mergify.yml (rc $RC): $(head -5 <<<"$OUT")"
grep -q '^batch_failure_attempts=' "$CONF" && bad "T3 cromford.conf sets no batch_failure_attempts (Mergify bisects)" || ok
grep -q '^[[:space:]]*batch_max_failure_resolution_attempts:' "$DIR/.mergify.yml" \
  && bad "T3 .mergify.yml has no batch_max_failure_resolution_attempts key: $(grep -n batch_max_failure "$DIR/.mergify.yml")" || ok
bash "$MT" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "T3 bin/mergify-template.sh --check (rc $RC)"
# The catalog the knob reads is the one lanes-build renders.
[ "$(jq -r '.. | objects | select(.env? == "MC_BATCH_IMPACT") | .default' "$DIR/catalog/lanes.d/merge-conductor.json")" = 1 ] && ok \
  || bad "T3 catalog/lanes.d/merge-conductor.json MC_BATCH_IMPACT default is 1"

# ============================================================================
# U — an `unknown` map answer under the shipped defaults. the operator's replay found
# 6 of 16 red drafts here (log-unreadable 4, a non-suite name 2). With bisect
# on, Mergify's bisect names the culprit in its dequeue comment: that PR keeps
# the culprit path and is not re-queued, and the gate decides as mode 0.
# ============================================================================
g_u() { g_t1; echo "skip $UKIND" > "$G/s/facts"; dequeue_comment "$H12" 20 "$PCHECK" 1 > "$G/s/comments/12"; }
for u in "U1 log-unreadable" "U2 not-paths"; do
  set -- $u; UKIND="$2"
  g_u; : > "$G/s/modes"; O12=$(gate 12)
  [ "$(sort -u "$G/s/modes")" = "mode=1" ] && ok || bad "$1 the shipped default is shadow: $(cat "$G/s/modes")"
  [ "${O12%%|*}" != 0 ] && ok || bad "$1 the PR Mergify's bisect named is not re-queued: $O12"
  grep -q "BATCH_IMPACT_[A-Z]* $SLUG#12 " "$G/s/log" && bad "$1 the map is not asked for the named PR: $(grep BATCH_IMPACT "$G/s/log")" || ok
  same_as_off "$1" "11 12 13" g_u
done

# ============================================================================
# E — the failing units a real red draft yields. The offline replay of drafts
# #6503, #6555, #6563 and #6573 found every one `unknown`: GitHub's echo of a
# step's run: script (`# A failed install must FAIL the job`, harness-ci.yml)
# read as a failing test, so _bs_facts answered `skip not-paths`.
# ============================================================================
mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh-strict" <<'GS'
#!/bin/bash
case "$*" in
  *"run view"*"--log-failed"*) cat "$STRICT_LOG" ;;
  *"/jobs"*) printf '{"total_count":1,"jobs":[{"name":"J","status":"completed","conclusion":"failure"}]}\n' ;;
esac
GS
chmod +x "$T/fakebin/gh-strict"
strict() { # strict <log lines (printf)> — sets SOUT, SRC
  printf "$1" > "$T/strict.log"
  SOUT=$(cd "$T" && STRICT_LOG="$T/strict.log" GH_STRICT="$T/fakebin/gh-strict" FLAKY_LOG_MAX=1000000 bash -c '
    gh() { "$GH_STRICT" "$@"; }
    . "$1/bin/lib/flaky.sh" || exit 9
    flaky_run_tests_strict example-org/cromford 9001' _ "$DIR" 2>/dev/null); SRC=$?
}
TS='J\tUNKNOWN STEP\t2026-10-13T23:46:50.2640165Z '
MARK="${TS}--- tests/a-test.sh rc=1 4s\n"
# E1 — the script echo as GitHub serves it: the escape spelled `^[`, not the byte.
strict "${TS}^[[36;1m# A failed install must FAIL the job, never fall through to the skip^[[0m\n${MARK}"
{ [ "$SRC" = 0 ] && [ "$SOUT" = "P	tests/a-test.sh" ]; } && ok \
  || bad "E1 a ^[-spelled script echo is not a test; only the suite is named (rc=$SRC, got: $(cat -v <<<"$SOUT"))"
# E2 — the same echo with the escape byte.
strict "${TS}\033[36;1m# A failed install must FAIL the job\033[0m\n${MARK}"
{ [ "$SRC" = 0 ] && [ "$SOUT" = "P	tests/a-test.sh" ]; } && ok \
  || bad "E2 a script echo with the escape byte is not a test (rc=$SRC, got: $(cat -v <<<"$SOUT"))"
# E3 — a ^[-coloured runner line is still output: the colour goes, the name stays.
strict "${TS}^[[31m FAIL ^[[39m src/x.test.ts > works\n"
{ [ "$SRC" = 0 ] && grep -qxP 'P\tsrc/x.test.ts' <<<"$SOUT" && ! grep -qF '^[' <<<"$SOUT"; } && ok \
  || bad "E3 a ^[-coloured FAIL line names its file, uncoloured (rc=$SRC, got: $(cat -v <<<"$SOUT"))"

# ============================================================================
# A — a member that ADDS the failing suite reaches it. test-impact select skips
# a changed tests/ path, and main's map has never seen a new suite, so #6515
# (it added tests/no-flag-files.bh-4154-test.sh, which then failed in draft
# #6555) was no candidate, and the map would have re-queued Mergify's pick.
# ============================================================================
A="$T/a"; mkdir -p "$A/rd"
printf 'S\ttests/new-suite.bh-1-test.sh\n' > "$A/units"
printf 'tests/new-suite.bh-1-test.sh\nbin/lib/new.sh\n' > "$A/rd/31.files"; printf 'tests/always-test.sh\n' > "$A/rd/31.reach"
printf 'docs/a.md\n' > "$A/rd/32.files"; printf 'tests/always-test.sh\n' > "$A/rd/32.reach"
out=$(bash -c '. "$1" || exit 9; bim_decide "$(bim_candidates "$2/units" "$2/rd" "31 32")" "$2/units"' _ "$BIM_LIB" "$A" 2>/dev/null)
[ "$out" = "eject 31 tests/new-suite.bh-1-test.sh" ] && ok \
  || bad "A1 the member whose files hold the failing suite is its one candidate: '$out'"

echo "queue-culprit-flip (BH-5373): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
