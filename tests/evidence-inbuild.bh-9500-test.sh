#!/bin/bash
# tests/evidence-inbuild.bh-9500-test.sh — BH-9500 (BH-9441 scope item 4): an
# all-INCONCLUSIVE evidence block does not end APPROVE. The claims become
# `[NOTE] not verified here: <reason>` lines in review.md, the recorded tier is
# 2, and the PR body says MERGE-WITH-NOTES.
#
# Driven: bin/lib/evidence-inbuild.sh as installed by scratch_install_closure,
# the shipped `# >>> evidence inbuild cap (BH-9500)` region of
# bin/lib/rb/review.sh and PR_BODY_FOR of bin/lib/rb/pr.sh (both flattened by
# rb_all).
#   S1-S6  ei_state: what "all inconclusive" is, and its near misses
#   N1-N3  ei_notes: one NOTE line per claim, the scorer's note as the reason
#   C1-C6  ei_cap on review.md: the block, the verdict reader, the tier reader,
#          an unresolved verdict window named as such
#   K1-K2  the knob: registry default, 0 = log only, a bad value enforces
#   E1-E3  the shipped review.sh region
#   P1-P2  the PR body provenance line
#   Z1     no model call
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/evidence-inbuild.bh-9500-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD EVIDENCE_INBUILD_CAP EI_PR_VERDICT EI_ENFORCE
# Hermetic verdict window (BH-9500 review): a builder shell exports _VP_WINDOW,
# CI does not. Drop both env sources so the window comes from the scratch
# tree's copy of the real registry (catalog/lanes.d/_lib.json, id
# verdict-parse), as on a clean runner.
unset _VP_WINDOW VERDICT_WINDOW_LINES
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }
FX="$DIR/tests/fixtures/evidence-inbuild.bh-9500"

mkdir -p "$T/h/state" "$T/h/logs"
scratch_install_closure bin/lib/evidence-inbuild.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
scratch_install_closure bin/lib/review-level.sh "$T/h" >/dev/null || { echo "FAIL: closure install (review-level)"; exit 1; }
[ -r "$T/h/bin/lib/verdict-parse.sh" ] && ok || bad "C0 bin/lib/verdict-parse.sh rides the lib's closure"
mkdir -p "$T/h/catalog/lanes.d" && cp "$DIR/catalog/lanes.d/_lib.json" "$T/h/catalog/lanes.d/_lib.json" \
  || { echo "FAIL: copy catalog/lanes.d/_lib.json (verdict window registry)"; exit 1; }
export HARNESS="$T/h"
LIB="$T/h/bin/lib/evidence-inbuild.sh"
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }

# bld <name> <evidence fixture|-> <review fixture|-> — a fresh build dir.
bld() {
  local b="$T/b/$1"; scratch_rm "$b"; mkdir -p "$b"
  [ "$2" = - ] || cp "$FX/$2" "$b/evidence.json"
  [ "$3" = - ] || cp "$FX/$3" "$b/review.md"
  printf '%s' "$b"
}

# ── S: ei_state ──────────────────────────────────────────────────────────────
[ "$(ei_state "$(bld s1 evidence-all-inc.json -)")" = "all-inconclusive 3" ] && ok || bad "S1 all-inc: $(ei_state "$T/b/s1")"
[ "$(ei_state "$(bld s2 evidence-mixed.json -)")" = proven ] && ok || bad "S2 mixed: $(ei_state "$T/b/s2")"
[ "$(ei_state "$(bld s3 evidence-refuted.json -)")" = proven ] && ok || bad "S3 refuted: $(ei_state "$T/b/s3")"
[ "$(ei_state "$(bld s4 evidence-zero.json -)")" = none ] && ok || bad "S4 zero: $(ei_state "$T/b/s4")"
[ "$(ei_state "$(bld s5 evidence-bad.json -)")" = unread ] && ok || bad "S5 counts not numbers: $(ei_state "$T/b/s5")"
[ "$(ei_state "$(bld s6 - -)")" = unread ] && ok || bad "S6 no file: $(ei_state "$T/b/s6")"
B=$(bld s1b - -); printf '%s' '{"total":1,"confirmed":0,"refuted":0,"inconclusive":1,"claims":[{"n":1,"claim":"FIXTURE one","verdict":"INCONCLUSIVE","artifact":"","note":"no artifact named","proposed":""}]}' > "$B/evidence.json"
[ "$(ei_state "$B")" = "all-inconclusive 1" ] && ok || bad "S1b one claim, inconclusive: $(ei_state "$B")"
printf 'not json' > "$B/evidence.json"
[ "$(ei_state "$B")" = unread ] && ok || bad "S5b not JSON: $(ei_state "$B")"

# ── N: ei_notes ──────────────────────────────────────────────────────────────
B=$(bld n1 evidence-all-inc.json -)
( cd "$T/b/n1" && ei_notes "$B" > "$T/notes.txt" )
[ "$(wc -l < "$T/notes.txt")" = 3 ] && ok || bad "N1 three NOTE lines: $(cat "$T/notes.txt")"
i=0; nbad=0
while IFS= read -r l; do i=$((i+1)); case "$l" in "- [NOTE] not verified here: claim $i: FIXTURE claim"*) ;; *) nbad=1 ;; esac; done < "$T/notes.txt"
[ "$nbad" = 0 ] && ok || bad "N1 each line starts '- [NOTE] not verified here: claim <n>:': $(cat "$T/notes.txt")"
sed -n 1p "$T/notes.txt" | grep -qF '(harness suite could not run (harness-suite.txt))' && ok || bad "N2 claim 1 reason is the scorer note: $(sed -n 1p "$T/notes.txt")"
sed -n 2p "$T/notes.txt" | grep -qF '(no artifact named)' && ok || bad "N2 claim 2 reason is the scorer note: $(sed -n 2p "$T/notes.txt")"
sed -n 3p "$T/notes.txt" | grep -qF '(no reason recorded by the scorer)' && ok || bad "N2 an empty note names that: $(sed -n 3p "$T/notes.txt")"
sed -n 2p "$T/notes.txt" | grep -qF '$(touch PWNED) and `touch PWNED2`' && ok || bad "N3 shell text stays text: $(sed -n 2p "$T/notes.txt")"
[ ! -e "$T/b/n1/PWNED" ] && [ ! -e "$T/b/n1/PWNED2" ] && [ ! -e "$T/PWNED" ] && ok || bad "N3 a claim's \$(...) or backtick ran"

# ── C: ei_cap ────────────────────────────────────────────────────────────────
EI_ENFORCE=1
B=$(bld c1 evidence-all-inc.json review-approve.md)
ei_cap "$B" "$B/review.md" >/dev/null
C1_VERDICT="${EI_PR_VERDICT:-}"
grep -qxF '<!-- evidence-inbuild-cap -->' "$B/review.md" && ok || bad "C1 marker line in review.md"
[ "$(grep -c '^- \[NOTE\] not verified here: claim ' "$B/review.md")" = 3 ] && ok || bad "C1 three NOTE lines in review.md: $(cat "$B/review.md")"
[ "$C1_VERDICT" = "MERGE-WITH-NOTES, 0 of 3 acceptance claims proven" ] && ok || bad "C1 EI_PR_VERDICT: '$C1_VERDICT'"
case "${EI_STATUS:-}" in "EVIDENCE INBUILD CAP: applied (0 of 3 claims proven)"*) ok ;; *) bad "C1 status: '${EI_STATUS:-}'" ;; esac
grep -q 'MERGE-WITH-NOTES, not APPROVE' "$B/review.md" && ok || bad "C1 the review report says MERGE-WITH-NOTES, not APPROVE"
head -10 "$B/review.md" | cmp -s - "$FX/review-approve.md" && ok || bad "C1 the lens text above the block is unchanged"
verdict_is APPROVE -L "$B/review.md" && ok || bad "C2 verdict_is APPROVE -L still reads APPROVE (no fix round on a check this box cannot run)"
verdict_is APPROVE "$B/review.md" && ok || bad "C2 verdict_is APPROVE (no -L) still reads APPROVE: $(verdict_parse "$B/review.md")"
# The tier reader at bin/lib/rb/pr.sh, verbatim.
TIER=1; tail -2 "$B/review.md" | grep -q 'TIER: 1' || TIER=2
[ "$TIER" = 2 ] && grep -qx 'TIER: 2' <<<"$(tail -2 "$B/review.md")" && ok || bad "C3 the pr.sh tier reader records tier 2: $(tail -2 "$B/review.md")"
[ "$(grep -oE 'TIER: [12]' "$B/review.md" | tail -1)" = "TIER: 2" ] && ok || bad "C3 the last TIER line (review-rescue, builder-direct) is 2"

for c in "c4m evidence-mixed.json review-approve.md" "c4r evidence-refuted.json review-approve.md" \
         "c4z evidence-zero.json review-approve.md" "c4n - review-approve.md" "c4b evidence-all-inc.json review-block.md"; do
  set -- $c
  B=$(bld "$1" "$2" "$3")
  EI_PR_VERDICT=stale; ei_cap "$B" "$B/review.md" >/dev/null
  cmp -s "$B/review.md" "$FX/$3" && [ -z "${EI_PR_VERDICT+x}" ] && ok \
    || bad "C4 $1 ($2, $3): review.md unchanged and EI_PR_VERDICT unset, got '${EI_PR_VERDICT:-}' / ${EI_STATUS:-}"
done

B=$(bld c5 evidence-all-inc.json review-approve.md)
ei_cap "$B" "$B/review.md" >/dev/null; ei_cap "$B" "$B/review.md" >/dev/null
[ "$(grep -cxF '<!-- evidence-inbuild-cap -->' "$B/review.md")" = 1 ] && [ "$(grep -c '^TIER: 2$' "$B/review.md")" = 1 ] && ok \
  || bad "C5 twice: one block only: $(cat "$B/review.md")"
[ "${EI_PR_VERDICT:-}" = "MERGE-WITH-NOTES, 0 of 3 acceptance claims proven" ] && ok || bad "C5 the second call still sets EI_PR_VERDICT"
# shellcheck source=/dev/null
. "$T/h/bin/lib/review-level.sh" || bad "C5 cannot source review-level.sh"
if command -v rl_cap >/dev/null 2>&1; then
  ( cd "$T/b/c5" && PROJECT=p rl_cap "$B/review.md" p --approve APPROVE --block BLOCK --lens inbuild --golive stand >/dev/null 2>&1 )
  ! grep -q '\[BLOCK' "$B/review.md" && verdict_is APPROVE -L "$B/review.md" && ok \
    || bad "C5 rl_cap on the capped file adds no BLOCK and keeps APPROVE: $(tail -5 "$B/review.md")"
else
  bad "C5 rl_cap not defined"
fi

# ── K: the knob ──────────────────────────────────────────────────────────────
REG="$DIR/catalog/lanes.d/_lib.evidence-inbuild.json"
[ "$(jq -r '.libs[] | select(.id == "evidence-inbuild") | .file' "$REG" 2>/dev/null)" = bin/lib/evidence-inbuild.sh ] && ok \
  || bad "K1 the registry names bin/lib/evidence-inbuild.sh"
KD=$(jq -r '.libs[] | select(.id == "evidence-inbuild") | .knobs[] | select(.env == "EVIDENCE_INBUILD_CAP") | .default' "$REG" 2>/dev/null)
[ "$KD" = "$EI_DEFAULT_ENFORCE" ] && ok || bad "K1 EVIDENCE_INBUILD_CAP: registry '$KD' != lib EI_DEFAULT_ENFORCE '$EI_DEFAULT_ENFORCE'"
unset EI_ENFORCE; ei_conf p; [ "$EI_ENFORCE" = 1 ] && [ -z "$EI_CONF_WARN" ] && ok || bad "K1 unset knob enforces: '$EI_ENFORCE' '$EI_CONF_WARN'"
B=$(bld k2 evidence-all-inc.json review-approve.md)
EVIDENCE_INBUILD_CAP=0 ei_conf p
[ "$EI_ENFORCE" = 0 ] && ok || bad "K2 EVIDENCE_INBUILD_CAP=0 -> EI_ENFORCE 0, got '$EI_ENFORCE'"
ei_cap "$B" "$B/review.md" >/dev/null
cmp -s "$B/review.md" "$FX/review-approve.md" && [ -z "${EI_PR_VERDICT+x}" ] && case "$EI_STATUS" in *"not enforced"*) true ;; *) false ;; esac && ok \
  || bad "K2 knob 0: no edit, no PR verdict, status 'not enforced': ${EI_STATUS:-}"
EVIDENCE_INBUILD_CAP=maybe ei_conf p
[ "$EI_ENFORCE" = 1 ] && [ -n "$EI_CONF_WARN" ] && ok || bad "K2 a bad value enforces and warns: '$EI_ENFORCE' '$EI_CONF_WARN'"

# C6: an unresolved verdict window is named as such, review.md untouched.
B=$(bld c6 evidence-all-inc.json review-approve.md)
OUT=$( _VP_ROOT="$T/nowin"; HARNESS="$T/nowin"; unset _VP_WINDOW VERDICT_WINDOW_LINES
       ei_cap "$B" "$B/review.md" >/dev/null; printf '%s|%s' "$EI_STATUS" "${EI_PR_VERDICT:-<unset>}" )
case "$OUT" in *"could not run (verdict unknown"*"|<unset>") cmp -s "$B/review.md" "$FX/review-approve.md" && ok || bad "C6 review.md changed" ;;
  *) bad "C6 unresolved window: status names it: $OUT" ;; esac

# ── E: the shipped region of bin/lib/rb/review.sh ───────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> evidence inbuild cap \(BH-9500\)/{f=1;next} /^# <<< evidence inbuild cap \(BH-9500\)/{exit} f' "$RB_ALL" > "$T/region.sh"
[ -s "$T/region.sh" ] && ok || bad "E0 could not extract the evidence inbuild cap region from bin/lib/rb/review.sh"
cat > "$T/drive-region.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
PROJECT=p; KEY=K
. "$1"
printf 'EIV=%s\n' "${EI_PR_VERDICT:-<unset>}"
EOS
region() { # region <harness> <build>
  ( unset EI_ENFORCE EI_PR_VERDICT EVIDENCE_INBUILD_CAP
    HARNESS="$1" BUILD="$2" ALERTS="$T/alerts.log" bash "$T/drive-region.sh" "$T/region.sh" 2>"$T/region.err" )
}
B=$(bld e1 evidence-all-inc.json review-approve.md)
OUT=$(region "$T/h" "$B")
grep -q '^TS \[p/K\] EVIDENCE INBUILD CAP: applied (0 of 3 claims proven)' "$B/pipeline.log" 2>/dev/null \
  && [ "$(grep -c '^- \[NOTE\] not verified here: claim ' "$B/review.md")" = 3 ] && grep -qx 'TIER: 2' <<<"$(tail -2 "$B/review.md")" && ok \
  || bad "E1 all-inc: block in review.md and the applied line in pipeline.log: $(cat "$B/pipeline.log" 2>/dev/null) $(cat "$T/region.err")"
[ "$OUT" = "EIV=MERGE-WITH-NOTES, 0 of 3 acceptance claims proven" ] && ok || bad "E1 the region leaves EI_PR_VERDICT for pr.sh: '$OUT'"
B=$(bld e2 evidence-mixed.json review-approve.md)
OUT=$(region "$T/h" "$B")
grep -q 'EVIDENCE INBUILD CAP: not applied (proven)' "$B/pipeline.log" 2>/dev/null && cmp -s "$B/review.md" "$FX/review-approve.md" && [ "$OUT" = "EIV=<unset>" ] && ok \
  || bad "E2 mixed: not applied (proven), review.md unchanged: $(cat "$B/pipeline.log" 2>/dev/null) $OUT"
mkdir -p "$T/nolib"
B=$(bld e3 evidence-all-inc.json review-approve.md)
OUT=$(region "$T/nolib" "$B")
grep -q 'EVIDENCE INBUILD CAP: could not run (lib absent)' "$B/pipeline.log" 2>/dev/null && cmp -s "$B/review.md" "$FX/review-approve.md" && [ "$OUT" = "EIV=<unset>" ] && ok \
  || bad "E3 no lib: one could-not-run line and nothing else: $(cat "$B/pipeline.log" 2>/dev/null) $OUT"
[ ! -s "$T/alerts.log" ] && ok || bad "E ALERTS stays empty with a good knob: $(cat "$T/alerts.log")"

# ── P: the PR body line in bin/lib/rb/pr.sh ─────────────────────────────────
awk '/^PR_BODY_FOR\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$RB_ALL" > "$T/prbody.sh"
[ -s "$T/prbody.sh" ] && ok || bad "P0 could not extract PR_BODY_FOR"
cat > "$T/drive-body.sh" <<'EOS'
set -uo pipefail
HOTFIX_PREFIX=""; KEY=K; PR_SUBJECT="K: subject"; CLOSES_LINE="Closes #1"; STACK_SECTION=""
WHAT_LIST="- a thing"; WHY_EXCERPT="because"; VERIFY_LINE="verify"; SPEC_LINE="spec"; ASSUMPTIONS_SECTION=""
BUILD=/tmp/b-K; PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MERGE_NOTE=""; MIG_SECTION=""; COST_LINE="cost"
CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
. "$1"
PR_BODY_FOR "EVIDENCE"
EOS
BODY=$(cd "$T" && EI_PR_VERDICT="$C1_VERDICT" bash "$T/drive-body.sh" "$T/prbody.sh" 2>"$T/body.err")
grep -qF "adversarially reviewed on rm (VERDICT: MERGE-WITH-NOTES, 0 of 3 acceptance claims proven)." <<<"$BODY" \
  && ! grep -qF '(VERDICT: APPROVE)' <<<"$BODY" && ok \
  || bad "P1 an all-inc build's body says MERGE-WITH-NOTES, not APPROVE: $(grep -F 'adversarially' <<<"$BODY") $(cat "$T/body.err")"
grep -qF 'cost' <<<"$BODY" && grep -qF 'EVIDENCE' <<<"$BODY" && ok || bad "P1 the arguments after the verdict stay in place"
BODY2=$(cd "$T" && unset EI_PR_VERDICT && bash "$T/drive-body.sh" "$T/prbody.sh" 2>"$T/body2.err")
grep -qF "adversarially reviewed on rm (VERDICT: APPROVE). " <<<"$BODY2" && [ ! -s "$T/body2.err" ] && ok \
  || bad "P2 unset EI_PR_VERDICT keeps '(VERDICT: APPROVE)' under set -u: $(grep -F 'adversarially' <<<"$BODY2") $(cat "$T/body2.err")"

# ── Z1: no model call ───────────────────────────────────────────────────────
! grep -qE '(^|[^-])\b(claude|agent-call)[[:space:]]+-|^[[:space:]]*CC[[:space:]]' "$0" && ok \
  || bad "Z1 the suite invokes no model CLI and no CC"

echo "evidence-inbuild.bh-9500: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
