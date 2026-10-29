#!/bin/bash
# tests/queue-eject-culprit.bh-4980-test.sh — BH-4980 (BH-4974.2): EJECT THE
# CULPRIT AND DON'T BISECT. When a Mergify batch fails, the failing test is
# mapped back through bin/test-impact.sh's map to the PR or PRs whose changes
# reach it. Exactly one: that PR is ejected with a comment naming the test, and
# the others go straight back in. None or several: the existing solo re-run
# (bs_batch, BH-4550) decides, unchanged.
#
#   U1-U8  bin/lib/mc-batch-impact.sh on a fixture map, through the real
#          bin/test-impact.sh select --why: reach, units, candidates, decide
#   G1-G6  bin/lib/mc-batch-eject.sh bej_reentry_gate with the reads stubbed:
#          the eject, the bystanders, no solo re-run, none/several fall back,
#          and every negative decides exactly as mode 0 does
#   K1     an invalid MC_BATCH_IMPACT is mode 0 plus one log line
#   M1-M3  bin/mergify-template.sh batch_failure_attempts (dark)
#   E1     the real bin/merge-conductor.sh, a batch of four, one touches worker/
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-eject-culprit.bh-4980-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/mergify-pause-filter.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
# E1's conductor parses review verdicts (vpf).
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

BIM_LIB="$DIR/bin/lib/mc-batch-impact.sh"
BEJ_LIB="$DIR/bin/lib/mc-batch-eject.sh"
[ -r "$BIM_LIB" ] || bad "bin/lib/mc-batch-impact.sh does not exist (BH-4980 not built)"

SLUG=example-org/cromford
BASE40=abc1234def5678901234567890abcdef12345678
H11=1111111111111111111111111111111111111111
H12=1212121212121212121212121212121212121212
H13=1313131313131313131313131313131313131313
H14=1414141414141414141414141414141414141414
WSUITE=tests/jobs-worker-test.sh
PCHECK='Pure-logic gate fixtures'
JCHECK='Jobs worker — routes + schema'
enc() { local s="${1//%/%25}"; s="${s// /%20}"; printf '%s' "${s//,/%2C}"; }

# ============================================================================
# The fixture tree: a scratch root with the real bin/test-impact.sh and a
# hand-written map, so a reach is exactly what the cases say it is.
# ============================================================================
R="$T/r"; mkdir -p "$R/bin" "$R/tests"
scratch_install_closure bin/test-impact.sh "$R" >/dev/null
MAP="$T/map"
{
  printf 'tests/always-test.sh\t*\n'
  printf '%s\tworker/\n' "$WSUITE"
  printf 'tests/mc-test.sh\tbin/lib/mc/\n'
  printf 'tests/console-test.sh\tconsole-ui/\n'
  printf 'tests/other-test.sh\tbin/other.sh\n'
} | LC_ALL=C sort > "$MAP"
for s in $(cut -f1 "$MAP" | sort -u); do printf '#!/bin/bash\n:\n' > "$R/$s"; done

# dequeue_comment <head> <draft> <check> [named 0|1] — a Mergify dequeue
# comment in the shape bej_parse_dequeue reads (tests/fixtures/bh-4428).
dequeue_comment() {
  local ident=""; [ "${4:-0}" = 1 ] && ident=" · identified as the failing PR"
  local body
  body=$(printf '<!---\nDO NOT EDIT\n-*- Mergify Payload -*-\n{"version": 1, "state": "dequeued", "queue_rule_name": "default"}\n-*- Mergify Payload End -*-\n-->\n# Merge Queue Status\n- ❌ **Checks failed** · on draft #%s%s\n- 🚫 **Left the queue** — `2026-10-07 01:00 UTC` · at `%s`\n## Reason\nThe merge conditions cannot be satisfied due to failing checks\nFailing checks:\n- ❌ [`%s`](https://github.com/example-org/cromford/actions/runs/9%s/job/1)\n## Hint\nfix it\n' \
    "$2" "$ident" "$1" "$3" "$2")
  jq -nc --arg b "$body" '[{id: 1, created_at: "2026-10-07T01:00:00Z", user: {login: "mergify[bot]", type: "Bot"}, body: $b}]'
}

# ============================================================================
# U — the pure lib.
# ============================================================================
if [ -r "$BIM_LIB" ]; then
  (
    HARNESS="$R"; unset H
    mc_log() { echo "$*" >> "$T/u.log"; }
    # shellcheck source=bin/lib/mc-batch-eject.sh
    . "$BEJ_LIB" || exit 1
    # shellcheck source=bin/lib/mc-batch-impact.sh
    . "$BIM_LIB" || exit 1
    P_=0; F_=0
    pok() { P_=$((P_+1)); }; pbad() { F_=$((F_+1)); echo "FAIL: $1"; }
    U="$T/u"; mkdir -p "$U"
    # U1 — worker/ reaches the worker suite; docs/ does not.
    printf 'worker/jobs/src/x.js\n' > "$U/f12"; printf 'docs/a.md\n' > "$U/f11"
    out=$(bim_reach "$U/f12" "$MAP"); rc=$?
    [ "$rc" = 0 ] && grep -qxF "$WSUITE" <<<"$out" && pok || pbad "U1 worker/jobs/src/x.js reaches $WSUITE (rc $rc): $out"
    out=$(bim_reach "$U/f11" "$MAP"); rc=$?
    [ "$rc" = 0 ] && ! grep -qxF "$WSUITE" <<<"$out" && grep -qxF tests/always-test.sh <<<"$out" && pok \
      || pbad "U1 docs/a.md reaches the always-suite and not $WSUITE (rc $rc): $out"
    # U2 — a file main's map cannot place (a PR adds it) is a full row: `*`.
    printf 'bin/lib/brand-new.sh\n' > "$U/fnew"
    out=$(bim_reach "$U/fnew" "$MAP"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = '*' ] && pok || pbad "U2 an unplaceable file reaches * (rc $rc): $out"
    # (a runner, not a workflow: a top-level workflow file reaches its readers
    # since BH-6876)
    printf 'bin/run-tests-in-docker.sh\n' > "$U/finfra"
    out=$(bim_reach "$U/finfra" "$MAP")
    [ "$out" = '*' ] && pok || pbad "U2 an infra file reaches *: $out"
    # U3 — an empty or absent list is unknown, never "reaches nothing".
    : > "$U/fempty"
    bim_reach "$U/fempty" "$MAP" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U3 an empty list is rc 1 (got $rc)"
    bim_reach "$U/nope" "$MAP" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U3 an absent list is rc 1 (got $rc)"
    ( HARNESS=""; bim_reach "$U/f12" "$MAP" >/dev/null ); rc=$?
    [ "$rc" = 1 ] && pok || pbad "U3 no root is rc 1 (got $rc)"
    # U4 — units from the solo facts' `ok` line.
    _bs_facts() { _bs_f="$FACTS"; return "${FACTS_RC:-0}"; }
    FACTS="ok $BASE40 $WSUITE 11 12 13 14"
    out=$(bim_units "$SLUG" 20 "$(enc "$PCHECK")"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "S	$WSUITE" ] && pok || pbad "U4 one S unit (rc $rc): '$out'"
    FACTS="ok $BASE40 tests/a-test.sh,tests/b-test.sh 11 12"
    out=$(bim_units "$SLUG" 20 "$(enc "$PCHECK")")
    [ "$out" = "S	tests/a-test.sh
S	tests/b-test.sh" ] && pok || pbad "U4 two suites are two S units: '$out'"
    # U5 — job-only: the failing check through the check-to-path map.
    FACTS="skip job-only"
    out=$(bim_units "$SLUG" 20 "$(enc "$JCHECK")"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "P	$JCHECK	worker/jobs/" ] && pok || pbad "U5 the jobs check maps to worker/jobs/ (rc $rc): '$out'"
    bim_units "$SLUG" 20 "$(enc "$PCHECK")" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U5 an unmapped check is rc 1 (got $rc)"
    bim_units "$SLUG" 20 "$(enc "$JCHECK"),$(enc "$PCHECK")" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U5 one unmapped check among mapped ones is rc 1 (got $rc)"
    out=$(MC_BATCH_IMPACT_CHECK_PATHS="$PCHECK=bin/lib/,tests/" bim_units "$SLUG" 20 "$(enc "$PCHECK")"); rc=$?
    [ "$rc" = 0 ] && [ "$out" = "P	$PCHECK	bin/lib/
P	$PCHECK	tests/" ] && pok || pbad "U5 the knob replaces the map (rc $rc): '$out'"
    FACTS="skip log-unreadable"
    bim_units "$SLUG" 20 "$(enc "$JCHECK")" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U5 another skip reason is rc 1 (got $rc)"
    FACTS=""; FACTS_RC=1
    bim_units "$SLUG" 20 "$(enc "$JCHECK")" >/dev/null; rc=$?
    [ "$rc" = 1 ] && pok || pbad "U5 a failed facts read is rc 1 (got $rc)"
    FACTS_RC=0
    # Reach files as bim_reach writes them, for four members.
    RD="$U/reach"; mkdir -p "$RD"
    mkreach() { # mkreach <pr> <file>...
      printf '%s\n' "${@:2}" > "$RD/$1.files"; bim_reach "$RD/$1.files" "$MAP" > "$RD/$1.reach"
    }
    mkreach 11 docs/a.md; mkreach 12 worker/jobs/src/x.js; mkreach 13 bin/lib/mc/x.sh; mkreach 14 console-ui/src/a.js
    printf 'S\t%s\n' "$WSUITE" > "$U/units.s"
    # U6 — exactly one candidate.
    c=$(bim_candidates "$U/units.s" "$RD" "11 12 13 14")
    out=$(bim_decide "$c"); rc=$?
    [ "$out" = "eject 12 $WSUITE" ] && pok || pbad "U6 one candidate ejects #12 (rc $rc): '$out' from '$c'"
    printf 'P\t%s\tworker/jobs/\n' "$JCHECK" > "$U/units.p"
    out=$(bim_decide "$(bim_candidates "$U/units.p" "$RD" "11 12 13 14")")
    [ "$out" = "eject 12 $(enc "$JCHECK")" ] && pok || pbad "U6 a P unit ejects #12 by its files: '$out'"
    # U7 — two, zero, unknown.
    mkreach 13 worker/x.js bin/lib/mc/x.sh
    out=$(bim_decide "$(bim_candidates "$U/units.s" "$RD" "11 12 13 14")")
    [ "$out" = "bisect several 12,13 $WSUITE" ] && pok || pbad "U7 two candidates are several: '$out'"
    mkreach 13 bin/lib/mc/x.sh
    printf 'S\ttests/other-test.sh\n' > "$U/units.o"
    out=$(bim_decide "$(bim_candidates "$U/units.o" "$RD" "11 12 13 14")" "$U/units.o")
    [ "$out" = "bisect none - tests/other-test.sh" ] && pok || pbad "U7 no candidate is none: '$out'"
    mv "$RD/13.reach" "$RD/13.reach.off"
    out=$(bim_decide "$(bim_candidates "$U/units.s" "$RD" "11 12 13 14")")
    [ "${out%% *}" = bisect ] && [ "$(cut -d' ' -f2 <<<"$out")" = unknown ] && pok || pbad "U7 a member with no reach is unknown: '$out'"
    mv "$RD/13.reach.off" "$RD/13.reach"
    rm -f "$RD/14.files"
    out=$(bim_decide "$(bim_candidates "$U/units.p" "$RD" "11 12 13 14")")
    [ "$(cut -d' ' -f1,2 <<<"$out")" = "bisect unknown" ] && pok || pbad "U7 a member with no file list is unknown: '$out'"
    mkreach 14 console-ui/src/a.js
    # A member that adds an unplaceable file reaches everything.
    mkreach 13 bin/lib/brand-new.sh
    out=$(bim_decide "$(bim_candidates "$U/units.p" "$RD" "11 12 13 14")")
    [ "$(cut -d' ' -f1-3 <<<"$out")" = "bisect several 12,13" ] && pok || pbad "U7 a * reach is a candidate for a P unit too: '$out'"
    mkreach 13 bin/lib/mc/x.sh
    # U8 — a failing always-suite is reached by every member.
    printf 'S\ttests/always-test.sh\n' > "$U/units.a"
    out=$(bim_decide "$(bim_candidates "$U/units.a" "$RD" "11 12 13 14")")
    [ "$(cut -d' ' -f1-3 <<<"$out")" = "bisect several 11,12,13,14" ] && pok || pbad "U8 an always-suite is several: '$out'"
    echo "$P_ $F_" > "$T/u.result"
  )
  read -r p f < "$T/u.result" 2>/dev/null || { p=0; f=1; echo "FAIL: part U did not run"; }
  PASS=$((PASS+p)); FAIL=$((FAIL+f))
fi

# ============================================================================
# G — the gate, with every read stubbed at the function the lib calls.
# ============================================================================
G="$T/g"; mkdir -p "$G"
# g_setup <files11> <files12> <files13> <files14> — the four members' files
# (`-` = the read fails), draft #20 holding all four, dequeue comments bound to
# each head, Mergify naming nobody.
g_setup() {
  local n i=0 heads=("$H11" "$H12" "$H13" "$H14")
  scratch_rm "$G/s" 2>/dev/null; mkdir -p "$G/s/state" "$G/s/files" "$G/s/comments"
  : > "$G/s/attempts"; : > "$G/s/log"; : > "$G/s/posted"; : > "$G/s/bs-calls"; : > "$G/s/bs-out"
  printf 'merge queue: checking #11 + #12 + #13 + #14 together on main (abc1234)' > "$G/s/title-20"
  for n in 11 12 13 14; do
    [ "$1" != - ] && tr ' ' '\n' <<<"$1" > "$G/s/files/$n"
    dequeue_comment "${heads[$i]}" 20 "$PCHECK" > "$G/s/comments/$n"
    echo "${heads[$i]}" > "$G/s/head-$n"
    i=$((i+1)); shift
  done
  printf 'ok %s %s 11 12 13 14\n' "$BASE40" "$WSUITE" > "$G/s/facts"
}
# gate <pr> [env…] — bej_reentry_gate for that member; prints
# rc|FR_WHY|FR_LINE|FR_STATE on one line.
gate() {
  local n="$1"; shift
  ( env "$@" bash -c '
    set -uo pipefail
    S="$1"; BEJ="$2"; BIM="$3"; R="$4"; MAP="$5"; n="$6"; slug="$7"
    export HARNESS="$R" HARNESS_REPO="${G_HARNESS_REPO:-$slug}" HARNESS_TEST_SANDBOX=1 MC_BATCH_IMPACT_MAP="$MAP"
    unset H
    MERGES=1; P=bh; MC_ATTEMPTS="$S/attempts"; MC_STATE_DIR="$S/state"
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
    bs_batch() { echo "$2" >> "$S/bs-calls"; BS_SUITES="tests/jobs-worker-test.sh"; BS_BASE="abc1234def5678901234567890abcdef12345678"; cat "$S/bs-out"; }
    _bs_facts() { _bs_f=$(cat "$S/facts"); [ -n "$_bs_f" ]; }
    fr_reentry_gate() { echo "fr $2" >> "$S/fr-calls"; FR_WHY="fr-said-no"; return 1; }
    fr_mergify_only_unstable() { return 0; }
    . "$BEJ" || exit 9
    [ -r "$BIM" ] && { declare -F bim_verdict >/dev/null || . "$BIM"; }
    rc=0; bej_reentry_gate "$slug" "$n" "$slug#$n" "https://github.com/$slug/pull/$n" "$(cat "$S/head-$n")" CLEAN || rc=$?
    printf "%s|%s|%s|%s\n" "$rc" "${FR_WHY:-}" "${FR_LINE:-}" "${FR_STATE:-}"
  ' _ "$G/s" "$BEJ_LIB" "$BIM_LIB" "$R" "$MAP" "$n" "$SLUG" ) 2>>"$G/err"
}
# snapshot <pr…> <env…> — every member's gate result + what was posted and
# re-run, for comparing a mode against mode 0 on a fresh copy of the fixture.
run_all() { # run_all "<prs>" env…
  local prs="$1" n; shift
  for n in $prs; do printf '#%s %s\n' "$n" "$(gate "$n" "$@")"; done
  printf 'posted:%s\n' "$(cat "$G/s/posted")"
  printf 'bs:%s\n' "$(tr '\n' ' ' < "$G/s/bs-calls")"
}

# G1 — mode 2, a batch of four, only #12 touches worker/: #12 is ejected.
g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
OUT=$(gate 12 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 1 ] && ok || bad "G1 #12 is not re-queued (rc 1): $OUT $(tail -3 "$G/err")"
[ "$(cut -d'|' -f2 <<<"$OUT")" = "queue-ejected — $WSUITE failed in draft #20 and only this PR reaches it (impact map)" ] && ok \
  || bad "G1 FR_WHY names the test: $OUT"
grep -q "^<<PR 12>>" "$G/s/posted" && grep -qF "\`$WSUITE\`" "$G/s/posted" && grep -q "only this one" "$G/s/posted" && ok \
  || bad "G1 one comment on #12 naming the test: $(cat "$G/s/posted")"
grep -q "Of the 4 PRs in it" "$G/s/posted" && ok || bad "G1 the comment counts the batch: $(cat "$G/s/posted")"
grep -qF "\`$PCHECK\`: https://github.com/example-org/cromford/actions/runs/920/job/1" "$G/s/posted" && ok \
  || bad "G1 the failing checks list and its run link stay: $(cat "$G/s/posted")"
grep -q '—' "$G/s/posted" && bad "G1 the comment carries no em dash: $(cat "$G/s/posted")" || ok
grep -q "BATCH_IMPACT_EJECT $SLUG#12 $H12 — draft=#20 eject 12 $WSUITE mode=2" "$G/s/log" && ok \
  || bad "G1 the BATCH_IMPACT line: $(grep BATCH_IMPACT "$G/s/log")"
OUT2=$(gate 12 MC_BATCH_IMPACT=2)
[ "$OUT2" = "$OUT" ] && [ "$(grep -c '^<<PR 12>>' "$G/s/posted")" = 1 ] && ok || bad "G1 a second tick decides the same and posts nothing: $OUT2 / $(grep -c '^<<PR' "$G/s/posted")"
# G2 — the other three go back in, naming #12.
for n in 11 13 14; do
  OUT=$(gate "$n" MC_BATCH_IMPACT=2)
  [ "${OUT%%|*}" = 0 ] && ok || bad "G2 #$n is re-queued (rc 0): $OUT"
  [ "$(cut -d'|' -f3 <<<"$OUT")" = "re-queued: draft #20 failed \`$WSUITE\`, and the impact map says only #12 reaches it. This head's own checks are green." ] && ok \
    || bad "G2 #$n FR_LINE names #12: $OUT"
done
grep -q "^<<PR 1[134]>>" "$G/s/posted" && bad "G2 nothing is posted on a bystander: $(cat "$G/s/posted")" || ok
# G3 — no solo re-run for anyone, and one decision for the whole draft.
[ ! -s "$G/s/bs-calls" ] && ok || bad "G3 bs_batch is never called when the map names one PR: $(cat "$G/s/bs-calls")"
[ -s "$G/s/state/batch-impact/example-org_cromford_20" ] && [ "$(head -1 "$G/s/state/batch-impact/example-org_cromford_20")" = "eject 12 $WSUITE" ] && ok \
  || bad "G3 the draft's decision is cached: $(cat "$G/s/state/batch-impact/"* 2>&1)"

# A mode-0 baseline for a fixture, against the same fixture and env in another mode.
# same_as_off <case> <prs> <setup-fn> <env…>
same_as_off() {
  local c="$1" prs="$2" setup="$3" a b; shift 3
  # The same env with the mode forced to 0 (env: the last assignment wins).
  "$setup"; a=$(run_all "$prs" "$@" MC_BATCH_IMPACT=0)
  "$setup"; b=$(run_all "$prs" "$@")
  [ "$a" = "$b" ] && ok || bad "$c decides exactly as mode 0: $(diff <(echo "$a") <(echo "$b"))"
}
# G4 — bisect none: nobody reaches the failing suite. The solo gate runs and
# everything matches mode 0.
g_none() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
           printf 'ok %s tests/other-test.sh 11 12 13 14\n' "$BASE40" > "$G/s/facts"; }
g_none; run_all "11 12 13 14" MC_BATCH_IMPACT=2 > /dev/null
[ "$(grep -c . "$G/s/bs-calls")" = 4 ] && ok || bad "G4 none: every member asks the solo re-run: $(cat "$G/s/bs-calls")"
grep -q "BATCH_IMPACT_NONE $SLUG#11 $H11 — draft=#20 bisect none" "$G/s/log" && ok || bad "G4 the none line: $(grep BATCH_IMPACT "$G/s/log")"
same_as_off G4 "11 12 13 14" g_none MC_BATCH_IMPACT=2
# G5 — two members touch worker/: candidates wait on their solo verdict, the
# others go back in at once.
g_two() { g_setup "docs/a.md" "worker/jobs/src/x.js" "worker/jobs/src/y.js" "console-ui/src/a.js"
          printf '12 %s pending\n13 %s pending\n11 %s pending\n14 %s pending\n' "$H12" "$H13" "$H11" "$H14" > "$G/s/bs-out"; }
g_two
OUT=$(gate 12 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 1 ] && [ "$(cut -d'|' -f2 <<<"$OUT")" = "queue-ejected — draft #20 failed $WSUITE; 2 PRs reach it, waiting on the solo re-run" ] && ok \
  || bad "G5 a candidate with a pending solo verdict is held: $OUT"
OUT=$(gate 11 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 0 ] && [ "$(cut -d'|' -f3 <<<"$OUT")" = "re-queued: draft #20 failed \`$WSUITE\`, and the impact map says only #12, #13 reach it. This head's own checks are green." ] && ok \
  || bad "G5 a non-candidate is re-queued at once: $OUT"
gate 14 MC_BATCH_IMPACT=2 >/dev/null
[ "$(tr '\n' ' ' < "$G/s/bs-calls")" = "20 " ] && ok || bad "G5 only the candidate asked the solo re-run: $(cat "$G/s/bs-calls")"
printf '12 %s reproduces\n13 %s clean\n11 %s clean\n14 %s clean\n' "$H12" "$H13" "$H11" "$H14" > "$G/s/bs-out"
OUT=$(gate 13 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 0 ] && ok || bad "G5 a candidate whose solo run is clean is re-queued as today: $OUT"
OUT=$(gate 12 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 1 ] && [ "$(cut -d'|' -f4 <<<"$OUT")" = BLOCKED_HUMAN ] && ok || bad "G5 a candidate that reproduces is parked as today: $OUT"
# G6 — negatives: each decides exactly as mode 0.
g_named() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
            dequeue_comment "$H12" 20 "$PCHECK" 1 > "$G/s/comments/12"; }
# Mergify's word wins for the PR it named: #12 is decided exactly as mode 0
# (its own comment says culprit, so the impact rung never runs for it).
same_as_off "G6 Mergify named #12" "12" g_named MC_BATCH_IMPACT=2
g_solo() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
           printf 'merge queue: checking #12 on main (abc1234)' > "$G/s/title-20"; }
same_as_off "G6 a batch of one" "12" g_solo MC_BATCH_IMPACT=2
g_one() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"; }
same_as_off "G6 shadow mode" "11 12 13 14" g_one MC_BATCH_IMPACT=1
grep -q "BATCH_IMPACT_EJECT $SLUG#12 $H12 — draft=#20 eject 12 $WSUITE mode=1" "$G/s/log" && ok || bad "G6 shadow logs the decision: $(grep BATCH_IMPACT "$G/s/log")"
same_as_off "G6 an invalid mode" "11 12 13 14" g_one MC_BATCH_IMPACT=7
same_as_off "G6 the main-red freeze is on" "11 12 13 14" g_one MC_BATCH_IMPACT=2 MAIN_RED=1
g_unread() { g_setup "docs/a.md" "worker/jobs/src/x.js" - "console-ui/src/a.js"; }
same_as_off "G6 a member's file list is unreadable" "11 12 13 14" g_unread MC_BATCH_IMPACT=2
grep -q "draft=#20 bisect unknown" "$G/s/log" && ok || bad "G6 an unreadable list is bisect unknown: $(grep BATCH_IMPACT "$G/s/log")"
[ ! -e "$G/s/state/batch-impact/example-org_cromford_20" ] && ok || bad "G6 an unknown from a failed read is not cached"
g_adds() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/brand-new.sh" "console-ui/src/a.js"
           : > "$G/s/bs-out"; }
g_adds; gate 13 MC_BATCH_IMPACT=2 >/dev/null
grep -q "draft=#20 bisect several 12,13" "$G/s/log" && ok || bad "G6 a member adding an unplaceable file is a candidate: $(grep BATCH_IMPACT "$G/s/log")"
g_always() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
             printf 'ok %s tests/always-test.sh 11 12 13 14\n' "$BASE40" > "$G/s/facts"; }
same_as_off "G6 the failing suite is an always-suite" "11 12 13 14" g_always MC_BATCH_IMPACT=2
g_unmapped() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
               echo "skip job-only" > "$G/s/facts"; }
same_as_off "G6 the failing check is not in the check map" "11 12 13 14" g_unmapped MC_BATCH_IMPACT=2
g_jobs() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"
           echo "skip job-only" > "$G/s/facts"
           for n in 11 12 13 14; do dequeue_comment "$(cat "$G/s/head-$n")" 20 "$JCHECK" > "$G/s/comments/$n"; done; }
g_jobs; OUT=$(gate 12 MC_BATCH_IMPACT=2)
[ "${OUT%%|*}" = 1 ] && grep -qF "\`$JCHECK\`" "$G/s/posted" && ok || bad "G6 a mapped job check ejects the one PR under its path: $OUT $(cat "$G/s/posted")"
g_foreign() { g_setup "docs/a.md" "worker/jobs/src/x.js" "bin/lib/mc/x.sh" "console-ui/src/a.js"; }
g_foreign; OUT=$(gate 12 MC_BATCH_IMPACT=2 G_HARNESS_REPO=example-org/elsewhere)
grep -q "draft=#20 bisect unknown" "$G/s/log" && ! grep -q "draft=#20 eject" "$G/s/log" && ok \
  || bad "G6 a repo the map is not built from is bisect unknown, never an eject: $(grep BATCH_IMPACT "$G/s/log")"
same_as_off "G6 a repo the map is not built from" "11 12 13 14" g_foreign MC_BATCH_IMPACT=2 G_HARNESS_REPO=example-org/elsewhere

# K1 — an invalid mode reads as 0 with one log line, however many times it is read.
g_one; gate 12 MC_BATCH_IMPACT=7 >/dev/null; gate 11 MC_BATCH_IMPACT=7 >/dev/null
[ "$(grep -c 'BATCH_IMPACT_MODE_INVALID MC_BATCH_IMPACT=7' "$G/s/log")" = 1 ] && ok || bad "K1 one invalid-mode line: $(grep -c MODE_INVALID "$G/s/log")"
grep -qE 'BATCH_IMPACT_(EJECT|SEVERAL|NONE|UNKNOWN)' "$G/s/log" && bad "K1 an invalid mode computes nothing: $(grep BATCH_IMPACT "$G/s/log")" || ok

# ============================================================================
# M — bin/mergify-template.sh batch_failure_attempts.
# ============================================================================
MT="$DIR/bin/mergify-template.sh"
# M1 — 0 renders under default only.
# TEST-CHANGE (BH-5373): the real conf now sets batch_failure_attempts=0, and a
# second copy of a key is refused as a duplicate. M1 and M3 strip the conf's own
# line and append theirs, so they still ask the same question of the renderer.
grep -v '^batch_failure_attempts=' "$DIR/config/mergify/repos/cromford.conf" > "$T/m-base.conf"
{ cat "$T/m-base.conf"; echo "batch_failure_attempts=0"; } > "$T/m1.conf"
bash "$MT" render "$T/m1.conf" > "$T/m1.yml" 2>"$T/m1.err"; RC=$?
Y=$(python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$T/m1.yml" 2>/dev/null \
    || ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' "$T/m1.yml" 2>/dev/null)
if [ -n "$Y" ]; then
  [ "$RC" = 0 ] && [ "$(jq -r '.queue_rules[] | select(.name == "default") | .batch_max_failure_resolution_attempts' <<<"$Y")" = 0 ] && ok \
    || bad "M1 default carries batch_max_failure_resolution_attempts: 0 (rc $RC): $(cat "$T/m1.err")"
  [ "$(jq -r '.queue_rules[] | select(.name == "hotfix") | has("batch_max_failure_resolution_attempts")' <<<"$Y")" = false ] && ok \
    || bad "M1 hotfix never carries it"
else
  [ "$RC" = 0 ] && [ "$(grep -c '^    batch_max_failure_resolution_attempts: 0$' "$T/m1.yml")" = 1 ] \
    && awk '/- name: default/{d=1} d && /batch_max_failure_resolution_attempts: 0/{f=1} END{exit !f}' "$T/m1.yml" && ok \
    || bad "M1 one batch_max_failure_resolution_attempts: 0 line, under default (rc $RC): $(cat "$T/m1.err")"
fi
bash "$MT" compare "$T/m1.conf" "$T/m1.yml" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "M1 the render compares equal to itself (rc $RC)"
# M2 — without the key, both renders are byte-identical to before this change.
if git -C "$DIR" rev-parse --verify -q origin/main >/dev/null; then
  OLD="$T/old"; mkdir -p "$OLD/bin" "$OLD/config/mergify"
  git -C "$DIR" show origin/main:bin/mergify-template.sh > "$OLD/bin/mergify-template.sh"
  git -C "$DIR" show origin/main:config/mergify/template.yml > "$OLD/config/mergify/template.yml"
  for c in project-5 cromford; do
    # main's renderer may refuse keys a later wave added; render it a copy without them
    # TEST-CHANGE (BH-5430): solo_label joins the list, and the new renderer
    # renders the SAME stripped copy. M2 asks "without the key, the render is
    # byte-identical to main"; a key a later PR adds (the solo queue) is the
    # render's job to change, so both sides leave it out. BH-7279's
    # flake_fix_label (the flake-fix queue) is the same case.
    grep -vE '^(queue_mode|scope_default_capacity|solo_label|flake_fix_label)=' "$DIR/config/mergify/repos/$c.conf" > "$T/old-$c.conf"
    bash "$OLD/bin/mergify-template.sh" render "$T/old-$c.conf" > "$T/old-$c.yml" 2>/dev/null
    bash "$MT" render "$T/old-$c.conf" > "$T/new-$c.yml"
    # TEST-CHANGE (BH-8706): drop the main-red breaker's pause lines from both
    # sides only while the base has none (tests/lib/mergify-pause-filter.sh).
    mergify_pause_filter "$T/old-$c.yml" "$T/new-$c.yml"
    [ -s "$T/old-$c.yml" ] && cmp -s "$T/old-$c.yml" "$T/new-$c.yml" && ok \
      || bad "M2 $c.conf renders byte-identical to main: $(diff "$T/old-$c.yml" "$T/new-$c.yml" | head -5)"
  done
else
  echo "M2 no origin/main ref — byte-identity against main skipped"
fi
bash "$MT" compare "$DIR/config/mergify/repos/cromford.conf" "$DIR/.mergify.yml" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "M2 cromford.conf still matches the committed .mergify.yml (rc $RC)"
# M3 — 9 is refused, naming the line.
{ cat "$T/m-base.conf"; echo "batch_failure_attempts=9"; } > "$T/m3.conf"
N=$(grep -c '' "$T/m3.conf")
ERR=$(bash "$MT" render "$T/m3.conf" 2>&1 >/dev/null); RC=$?
[ "$RC" = 2 ] && grep -q "m3.conf:$N: batch_failure_attempts 9 is outside 0..8" <<<"$ERR" && ok || bad "M3 9 is rc 2 naming line $N (rc $RC): $ERR"

# ============================================================================
# E1 — the real conductor: draft #20 held #11-#14, failed tests/jobs-worker-test.sh,
# only #12 touches worker/. One comment on #12, three requeues, no solo re-run.
# ============================================================================
E="$T/e"
export HARNESS="$E/h"
mkdir -p "$E/h/logs" "$E/h/state" "$E/h/flags" "$E/h/locks" "$E/h/builds" "$E/h/env" "$E/h/tmp" "$E/h/tests" "$E/fakebin"
scratch_install_closure bin/merge-conductor.sh "$E/h" >/dev/null || bad "E1 the conductor's closure installs"
for s in bin/test-impact.sh bin/merge-sweep.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$E/h" >/dev/null || bad "E1 $s's closure installs"
done
for s in $(cut -f1 "$MAP" | sort -u); do printf '#!/bin/bash\n:\n' > "$E/h/$s"; done
cp "$DIR/tests/lib/rest-emit.sh" "$E/fakebin/restpr"; chmod +x "$E/fakebin/restpr"
printf 'JOBS_URL=http://jobs.test\nHARNESS_SECRET=x\n' > "$E/h/env/global.env"
printf 'bh example-org/cromford - - 2 box-m\n' > "$E/h/fleet.conf"
export FLEET_CONF="$E/h/fleet.conf"
# TEST-CHANGE BH-4148 (merge of main): the lead protected paths come from the
# lead_protected_paths rows (tests/lib/lpp-stub.sh), not the deleted TSV. The rows
# are the cromford globs the TSV held (the fixture); the curl stub below answers them.
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"
set -f; lpp_set "$LPPF" example-org/cromford $(cat "$DIR/tests/fixtures/lead-protected-paths.bh-4148.txt"); set +f
lpp_install "$E/fakebin" "$LPPF" "$LPPDOWN"
mkdir -p "$E/h/catalog"; printf 'tests/g-test.sh\tguard\t5\tbin/x.sh\tr\n' > "$E/h/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$E/h/bin/agent-call.sh"
for s in beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$E/h/bin/$s.sh"; done
chmod +x "$E/h/bin/"*.sh
printf '20\tmerge queue: checking #11 + #12 + #13 + #14 together on main (abc1234)\n' > "$E/drafts.tsv"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\n' "$E" "$MGFY_YML"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
pr_of() { sed -n 's|.*/issues/\([0-9]*\)/.*|\1|p; s|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*" | head -1; }
GHA_OK='{"name":"Syntax + shellcheck","status":"completed","conclusion":"success","app":{"slug":"github-actions"},"output":{"title":""}}'
MG_RULE='{"name":"Rule: queue on the harness label (queue)","status":"completed","conclusion":"failure","app":{"slug":"mergify"},"output":{"title":"The pull request has been removed from the queue"}}'
MG_DQ='{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","app":{"slug":"mergify"},"output":{"title":"Dequeued — checks failed"}}'
MG_RUN='{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"app":{"slug":"mergify"},"output":{"title":"The pull request is embarked for merge"}}'
case "$*" in
  *"api -i -X GET repos/example-org/cromford/pulls"*"state=open"*) restpr --raw 200 "$(cat "$T/pulls-rest.json")" ;;
  *"api -i -X GET repos/example-org/cromford/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/cromford/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/"*"/actions/workflows/prequeue-gate.yml"*) restpr --raw 200 '{"id":7,"state":"active"}' ;;
  # BH-6161: a requeue after an ejection asks the pre-queue gate, which reads main's tip.
  *"api -i -X GET repos/example-org/cromford/commits/main") restpr --raw 200 '{"sha":"89f7dd83c7020a196f9a5082fd2a51e91398200a"}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*)
    SHA=$(sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p' <<<"$*")
    N=$(grep -lx "$SHA" "$T"/head-* 2>/dev/null | head -1); N=${N##*-}
    case "$(cat "$T/ckmode-$N" 2>/dev/null || echo stale)" in
      stale) restpr --raw 200 "{\"total_count\":3,\"check_runs\":[$MG_RULE,$MG_DQ,$GHA_OK]}" ;;
      acked) restpr --raw 200 "{\"total_count\":2,\"check_runs\":[$MG_RUN,$GHA_OK]}" ;;
    esac ;;
  *"api -i -X GET repos/"*"/commits/"*"/status"*)
    restpr --raw 200 '{"state":"success","statuses":[{"context":"lead-verdict","state":"success"}]}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*)
    restpr --raw 200 "$(cat "$T/comments-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/"*"/branches/"*) restpr --raw 200 '{"name":"main","commit":{"sha":"89f7dd83c7020a196f9a5082fd2a51e91398200a"}}' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*)
    restpr --raw 200 "$(cat "$T/files-$(pr_of "$*").json" 2>/dev/null || echo '[]')" ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    BF=""; for a in "$@"; do case "$a" in body=@*) BF=${a#body=@} ;; esac; done
    { printf '<<PR %s>>\n' "$(pr_of "$*")"; cat "$BF"; printf '\n<<END>>\n'; } >> "$T/attr-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"api -X DELETE repos/"*"/labels/"*) printf '%s\n' "$*" >> "$T/label-removes.txt"; exit 0 ;;
  *"api -X POST repos/"*"/labels"*) printf '%s\n' "$*" >> "$T/label-adds.txt"; exit 0 ;;
  *"api -X POST repos/"*"/comments"*)
    N=$(pr_of "$*"); printf '%s\n' "$*" >> "$T/comments.txt"
    case "$*" in *"@mergifyio requeue"*|*"@mergifyio queue"*) echo acked > "$T/ckmode-$N" ;; esac
    exit 0 ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"workflow run"*) printf '%s\n' "$*" >> "$T/dispatches.txt"; exit 0 ;;
  *"pr merge"*) printf '%s\n' "$*" >> "$T/merges.txt"; exit 0 ;;
  *"run rerun"*) printf '%s\n' "$*" >> "$T/reruns.txt"; exit 0 ;;
  *"issue comment"*|*"issue close"*|*"pr comment"*) printf '%s\n' "$*" >> "$T/writes.txt"; exit 0 ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/"*"/pulls/"*"/commits"*) echo "" ;;
  *"api -i -X GET repos/"*"/pulls -f"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    PN=$(pr_of "$*")
    TI=$(awk -F'\t' -v n="$PN" '$1==n {print $2}' "$T/drafts.tsv")
    if [ -n "$TI" ]; then
      restpr --raw 200 "$(jq -nc --argjson n "$PN" --arg t "$TI" '{number: $n, title: $t, state: "closed", head: {sha: "dddddddddddddddddddddddddddddddddddddddd"}}')"
    else
      restpr OPEN "$(cat "$T/head-$PN" 2>/dev/null || echo unknown)" "ticket/bh-$PN" main dequeued MERGEABLE UNSTABLE operator
    fi ;;
  *"api repos/example-org/cromford -q .id"*) echo 1 ;;
  *"pr list -R example-org/cromford --state open"*) cat "$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  # BH-6336: the no-verdict gate reads the failing batch run's jobs and its
  # failed-job log. Draft #20 failed a real test, so the fan-in names a shard
  # whose tests failed: not a no-verdict batch, and #4428's rule decides.
  *"api repos/"*"/actions/runs/"*"/jobs"*)
    printf '{"total_count":2,"jobs":[{"name":"Pure-logic gate fixtures","status":"completed","conclusion":"failure"},{"name":"Tests, traced (shard 1/2)","status":"completed","conclusion":"failure"}]}\n' ;;
  *"run view "*"--log-failed"*)
    printf "Pure-logic gate fixtures\tthe verdict\t2026-10-07T01:00:00Z ##[error]shard 1/2: 1 of 5 tests failed. Open 'Tests, traced (shard 1/2)'\n" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$E/fakebin/gh"
chmod +x "$E/fakebin/gh"
cat > "$E/fakebin/curl" <<'CURL'
#!/bin/bash
# TEST-CHANGE BH-4148: the lead protected paths read answers the rows; every other worker call 404s, as before.
case "${!#}" in */api/lead-protected-paths*) lpp-answer GET "${!#}"; exit 0 ;; esac
printf '{"error":"not found"}\n404\n'
CURL
chmod +x "$E/fakebin/curl"
: > "$E/gh-calls.txt"; : > "$E/attr-comments.txt"; : > "$E/comments.txt"; : > "$E/dispatches.txt"
: > "$E/label-adds.txt"; : > "$E/merges.txt"
EA="$E/h/state/merge-conductor/attempts.txt"; mkdir -p "${EA%/*}"; : > "$EA"
LIST=""; sep=""
for n in 11 12 13 14; do
  eval "h=\$H$n"
  d="$E/h/builds/pool-bh-BH-$n-20261007000$n"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/cromford/pull/$n" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$h" > "$d/reviewed-sha"; : > "$d/pipeline.log"
  echo "$h" > "$E/head-$n"; echo stale > "$E/ckmode-$n"
  dequeue_comment "$h" 20 "$PCHECK" > "$E/comments-$n.json"
  echo "ejected example-org/cromford#$n $h" >> "$EA"
  LIST+="$sep$(printf '{"number":%s,"url":"https://github.com/example-org/cromford/pull/%s","headRefOid":"%s","headRefName":"ticket/bh-%s","isDraft":false,"mergeStateStatus":"UNSTABLE","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[{"name":"dequeued"}],"baseRefName":"main"}' "$n" "$n" "$h" "$n")"; sep=,
done
printf '[%s]' "$LIST" > "$E/list.json"
# The same rows as REST's open-PR list answers them.
jq -c '[.[] | {number, html_url: .url, title: ("BH-" + (.number | tostring)), body: "", draft: false, state: "open",
  merged_at: null, closed_at: null, labels, user: {login: "operator", type: "User"},
  head: {ref: .headRefName, sha: .headRefOid, repo: {full_name: "example-org/cromford"}},
  base: {ref: "main", repo: {full_name: "example-org/cromford"}}, mergeable_state: "unstable", mergeable: true}]' \
  "$E/list.json" > "$E/pulls-rest.json"
printf '[{"filename":"docs/a.md"}]' > "$E/files-11.json"
printf '[{"filename":"worker/jobs/src/x.js"},{"filename":"docs/b.md"}]' > "$E/files-12.json"
printf '[{"filename":"bin/lib/mc/x.sh"}]' > "$E/files-13.json"
printf '[{"filename":"console-ui/src/a.js"}]' > "$E/files-14.json"
# The draft's solo facts as _bs_facts writes them after reading the failed
# run's log (bin/lib/mc-prequeue.d/batch-solo.sh): its one failing suite.
mkdir -p "$E/h/state/merge-conductor/prequeue"
printf 'ok %s %s 11 12 13 14\n' "$BASE40" "$WSUITE" > "$E/h/state/merge-conductor/prequeue/batchsolo_example-org_cromford_20"
# BH-6161: a requeue after an ejection waits for a pre-queue run on current
# main. The bystanders' runs on that main came back green (the gate's own
# writer, pq_cache_put), so the gate answers proceed and dispatches nothing.
for n in 11 13 14; do
  eval "h=\$H$n"
  ( MC_STATE_DIR="$E/h/state/merge-conductor"; . "$E/h/bin/lib/mc-prequeue.sh" \
    && pq_cache_put "$(pq_key example-org/cromford "$n" "$h" 89f7dd83c7020a196f9a5082fd2a51e91398200a)" green 1791700000 "9$n" "" ) \
    || bad "E1 fixture: the green pre-queue verdict for #$n"
done
touch "$E/h/flags/merge-conductor-actions" "$E/h/flags/merge-conductor-merge"
( cd "$E" && PATH="$E/fakebin:$PATH" HARNESS="$E/h" HARNESS_SECRET=x JOBS_URL=http://jobs.test \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 HARNESS_TEST_SANDBOX=1 MC_BATCH_IMPACT_MAP="$MAP" MC_BATCH_IMPACT=2 \
  bash "$E/h/bin/merge-conductor.sh" >/dev/null 2>"$E/tick.err" ) || { echo "E1 tick rc=$?:"; tail -5 "$E/tick.err"; }
ELOG="$E/h/logs/merge-conductor.log"
[ "$(grep -c '^<<PR' "$E/attr-comments.txt" | tr -d ' ')" -ge 1 ] && ok || bad "E1 a comment was posted (log: $(grep -E 'BATCH_|REQUEUE' "$ELOG" | tail -8))"
CUL=$(awk '/^<<PR /{p=$2} /only this one/{print p}' "$E/attr-comments.txt" | sort -u | tr -d '>' | tr '\n' ' ')
[ "$CUL" = "12 " ] && ok || bad "E1 exactly one culprit comment, on #12: '$CUL' $(cat "$E/attr-comments.txt")"
awk '/^<<PR 12>>/{on=1} /^<<END>>/{on=0} on' "$E/attr-comments.txt" | grep -qF "\`$WSUITE\`" && ok || bad "E1 #12's comment names the test: $(cat "$E/attr-comments.txt")"
# The requeue is the arm's own: BH-636's `requeued` mark, then the merge-queue
# label back on (mc_requeue_mergify).
for n in 11 13 14; do
  eval "h=\$H$n"
  grep -qE "^requeued example-org/cromford#$n $h " "$EA" && [ "$(grep -c "issues/$n/labels" "$E/label-adds.txt")" = 1 ] && ok \
    || bad "E1 #$n is re-queued this tick: $(grep "^requeued" "$EA") / $(cat "$E/label-adds.txt") / $(grep "#$n" "$ELOG" | tail -3)"
done
grep -q "issues/12/labels" "$E/label-adds.txt" && bad "E1 #12 gets no merge-queue label: $(cat "$E/label-adds.txt")" || ok
grep -qE "^requeued example-org/cromford#12 " "$EA" && bad "E1 #12 carries no requeued mark" || ok
grep -q "issues/12/comments.*@mergifyio" "$E/comments.txt" && bad "E1 #12 is not asked back in: $(cat "$E/comments.txt")" || ok
[ ! -s "$E/dispatches.txt" ] && ok || bad "E1 no prequeue-gate dispatch: $(cat "$E/dispatches.txt")"
grep -q 'BATCH_SOLO' "$ELOG" && bad "E1 no solo re-run line: $(grep BATCH_SOLO "$ELOG")" || ok
[ ! -s "$E/merges.txt" ] && ok || bad "E1 nothing merges directly: $(cat "$E/merges.txt")"
awk -F'\t' '$1 == "example-org/cromford#12" {print $7}' "$E/h/state/merge-conductor/pr-state.tsv" \
  | grep -qF "queue-ejected — $WSUITE failed in draft #20 and only this PR reaches it (impact map)" && ok \
  || bad "E1 #12's row says why: $(awk -F'\t' '$1 ~ /#12$/' "$E/h/state/merge-conductor/pr-state.tsv")"

[ -n "${BIM_KEEP:-}" ] && cp -r "$E" "$BIM_KEEP"
echo "queue-eject-culprit (BH-4980): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
