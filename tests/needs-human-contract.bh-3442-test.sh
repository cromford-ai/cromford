#!/bin/bash
# tests/needs-human-contract.bh-3442-test.sh — the needs-human contract slice
# (BH-3442, order 1 of BH-3433). Every function is a stub with its documented
# default except nh_fingerprint, which is real. After this slice, behaviour is
# unchanged: no hold, no alert, no RESULT suffix, no prompt text, no PR section.
#   F1-F8  bin/lib/needs-human.sh: constants, nh_fingerprint, guard, fail-open
#   C/T/R  the classify / trip / release stubs and their documented defaults;
#          C3 pins nh_prompt_field_note's real sentence since BH-3444 implemented it
#   H1-H3  bin/needs-human-hold.sh: argc, exit 0 off an issues board, no side effect
#   K1     the lib knob composes into catalog/lanes.json
#   S1-S2  review.sh's needs-human seam block: issue/slug for an issues board only
#   L1-L3  LENS_REFUSE cut from the flattened pipeline: REVIEW_BLOCKED unchanged,
#          and the suffix position proved by a stubbed nh_on_block
#   P1     pr.sh's PR body: byte-identical with the stub lib, wired when it answers
#   N1     no ALERTS.log anywhere
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS_TEST_SANDBOX=1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/needs-human.sh"
CLASSIFY="$DIR/bin/lib/needs-human/classify.sh"
TRIP="$DIR/bin/lib/needs-human/trip.sh"
RELEASE="$DIR/bin/lib/needs-human/release.sh"
HOLD="$DIR/bin/needs-human-hold.sh"
for f in "$LIB" "$CLASSIFY" "$TRIP" "$RELEASE" "$HOLD"; do
  [ -r "$f" ] && ok || bad "D41: $f is missing"
done

# gh / gh_rest / alert-line / jobs on PATH record any call.
mkdir -p "$T/bin" "$T/h/logs"
for s in gh gh_rest alert-line jobs; do
  printf '#!/bin/bash\n: > "%s/called.%s"\nexit 0\n' "$T" "$s" > "$T/bin/$s"; chmod +x "$T/bin/$s"
done
export PATH="$T/bin:$PATH"

# ── F: the lib ─────────────────────────────────────────────────────────────
# shellcheck disable=SC1090
. "$LIB"; RC=$?
[ "$RC" = 0 ] && ok || bad "F0: sourcing the lib returned $RC"
[ "${NH_MARKER_PREFIX:-}" = "NEEDS-HUMAN:" ] && [ "${NH_DONE_PREFIX:-}" = "HUMAN-STEP-DONE:" ] \
  && [ "${NH_FP_TAG:-}" = "nh-fp" ] && ok || bad "F1: constants '${NH_MARKER_PREFIX:-}' '${NH_DONE_PREFIX:-}' '${NH_FP_TAG:-}'"

A=$(nh_fingerprint "Test at line 4242 asserts nothing (D3) FRAUD: weakened-tests")
B=$(nh_fingerprint "Test at line 97 asserts nothing (D1, D4)")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "F2: digit / D-cite / FRAUD variants differ: '$A' vs '$B'"
[[ "$A" =~ ^[0-9a-f]{12}$ ]] && ok || bad "F2: fingerprint is not 12 lowercase hex: '$A'"
# A D-cite's whole parenthesis goes, prose inside it included.
A=$(nh_fingerprint "retry loop never bounded (D21 bound recurring work)")
B=$(nh_fingerprint "retry loop never bounded (D9)")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "F2: D-cite prose changed the fingerprint: '$A' vs '$B'"
A=$(nh_fingerprint "commit 4f3a9c1e2b broke the retry loop")
B=$(nh_fingerprint "commit 9e8d7c6b5a4 broke the retry loop")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "F3: sha variants differ: '$A' vs '$B'"
A=$(nh_fingerprint 'retry loop, `foo()`, never bounded!')
B=$(nh_fingerprint "retry loop foo never bounded")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "F4: punctuation / backtick variants differ: '$A' vs '$B'"
A=$(nh_fingerprint "this retry loop that would never have been bounded")
B=$(nh_fingerprint "retry loop never bounded")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "F4: stopword variants differ: '$A' vs '$B'"
A=$(nh_fingerprint "retry loop never bounded")
B=$(nh_fingerprint "migration missing row level security")
[ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] && ok || bad "F5: different findings collide: '$A' vs '$B'"
# A 7+ letter a-f word with no digit is a word, not a sha.
A=$(nh_fingerprint "the page was defaced"); B=$(nh_fingerprint "the page was")
[ "$A" != "$B" ] && ok || bad "F5b: 'defaced' was stripped as a hex run"
for IN in "" "the 1234567 of a"; do
  OUT=$(nh_fingerprint "$IN"); RC=$?
  [ -z "$OUT" ] && [ "$RC" = 1 ] && ok || bad "F6: '$IN' gave '$OUT' rc $RC, want nothing rc 1"
done
# shellcheck disable=SC1090
. "$LIB"; RC=$?
[ "$RC" = 0 ] && [ "${_NH_LIB_LOADED:-}" = 1 ] && ok || bad "F7: double source rc $RC loaded='${_NH_LIB_LOADED:-}'"
# The second source re-runs nothing: a function redefined after the first stays.
OUT=$(nh_classify() { echo mine; }; . "$LIB"; nh_classify)
[ "$OUT" = mine ] && ok || bad "F7: a second source re-loaded the sub-libs: '$OUT'"
mkdir -p "$T/lib"; cp "$LIB" "$T/lib/needs-human.sh"
OUT=$(bash -c 'set -u; . "$1"; echo "rc=$?"; nh_fingerprint "retry loop never bounded"; type nh_classify >/dev/null 2>&1 && echo classify-defined' _ "$T/lib/needs-human.sh" 2>&1)
[ "$(sed -n 1p <<<"$OUT")" = "rc=0" ] && [[ "$(sed -n 2p <<<"$OUT")" =~ ^[0-9a-f]{12}$ ]] \
  && [ "$(wc -l <<<"$OUT")" = 2 ] && ok || bad "F8: half-synced lib did not load fail-open: $OUT"

# ── C / T / R: the stubs ───────────────────────────────────────────────────
printf 'NEEDS-HUMAN: set the Vercel env\nFRAUD: false-completion\nthe human step is owed\nVERDICT: BLOCK\n' > "$T/review.md"
OUT=$(nh_classify "$T/review.md"); RC=$?
[ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "C1: nh_classify file gave '$OUT' rc $RC"
OUT=$(nh_classify --text "anything"); RC=$?
[ "$OUT" = none ] && [ "$RC" = 1 ] && ok || bad "C1: nh_classify --text gave '$OUT' rc $RC"
OUT=$(nh_on_block p 1 "$T/review.md" "$T/b"); RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok || bad "C2: nh_on_block gave '$OUT' rc $RC"
# C3 (BH-3444): the prompt note is implemented — one non-empty line asking for
# the NEEDS_HUMAN: field above TIER:.
OUT=$(nh_prompt_field_note); RC=$?
[ -n "${OUT// /}" ] && [ "$(wc -l <<<"$OUT")" = 1 ] && [[ "$OUT" == *"NEEDS_HUMAN:"* ]] && [[ "$OUT" == *"TIER:"* ]] \
  && [ "$RC" = 0 ] && ok || bad "C3: nh_prompt_field_note gave '$OUT' rc $RC"
OUT=$(nh_trip_note p 1 abcdef123456 b1); RC=$?
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "T1: nh_trip_note with no jobs client gave '$OUT' rc $RC, want rc 2 (unreadable, BH-3445)"
OUT=$(nh_trip_on_block p 1 "$T/review.md" b1); RC=$?
[ -z "$OUT" ] && [ "$RC" = 0 ] && ok || bad "T2: nh_trip_on_block gave '$OUT' rc $RC"
# BH-3446 made release real: an empty stub reply is an unreadable thread, so the
# evidence read says rc 2 and the two renderers fold that to nothing, rc 0.
OUT=$(nh_release_evidence o/r 1); RC=$?
[ -z "$OUT" ] && [ "$RC" = 2 ] && ok || bad "R1: nh_release_evidence gave '$OUT' rc $RC, want nothing rc 2"
for fn in nh_prompt_release_note nh_pr_body_section; do
  OUT=$("$fn" o/r 1); RC=$?
  [ -z "$OUT" ] && [ "$RC" = 0 ] && ok || bad "R1: $fn gave '$OUT' rc $RC"
done

# ── H: the placer stub ─────────────────────────────────────────────────────
[ "$(sed -n 2p "$HOLD")" = "# gh-identity: app-token" ] && ok || bad "H0: line 2 is not the app-token marker"
BEFORE=$(find "$T" | sort)
# BH-3443 replaced the stub with the real placer: project p is not an issues
# board, so it says so and exits 0, still writing nothing and calling nothing
# (no HARNESS, so no log). The fp is hex now because the placer validates it.
ERR=$(cd "$T" && bash "$HOLD" p 1 abc123 act review 2>&1 >/dev/null); RC=$?
[ "$RC" = 0 ] && [[ "$ERR" == *"not an issues board"* ]] && ok || bad "H1: rc $RC stderr '$ERR'"
[ "$(find "$T" | sort)" = "$BEFORE" ] && ok || bad "H1: the placer wrote a file or called a stub"
(cd "$T" && bash "$HOLD" p 1 fp act >/dev/null 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "H2: 4 args exited 0"
(cd "$T" && bash "$HOLD" >/dev/null 2>&1); RC=$?
[ "$RC" != 0 ] && ok || bad "H3: 0 args exited 0"

# ── K: the knob composes ───────────────────────────────────────────────────
mkdir -p "$T/k"; cp -r "$DIR/catalog" "$DIR/bin" "$T/k/"
rm -f "$T/k/catalog/lanes.json"
if bash "$DIR/bin/lanes-build.sh" --root "$T/k" --write >/dev/null 2>"$T/k.err"; then
  jq -e '.libs[]|select(.id=="needs-human")|(.note|contains("needs-human-hold-off")) and (.knobs[0]|.env=="NEEDS_HUMAN_TRIP_COUNT" and .type=="int" and .default==2 and .min==2 and .max==10)' \
    "$T/k/catalog/lanes.json" >/dev/null && ok || bad "K1: the needs-human lib/knob is not in the composed lanes.json"
else bad "K1: lanes-build --write failed: $(cat "$T/k.err")"; fi

# ── S / L / P: the hooks, cut from the flattened pipeline ──────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
cut_block() { awk -v n="$1" 'index($0,"# >>> " n)==1{f=1;next} index($0,"# <<< " n)==1{exit} f' "$RB_ALL" > "$2"; }
cut_fn() { awk -v f="$1" 'index($0, f "() {")==1{p=1} p{print} p&&/^}/{exit}' "$RB_ALL"; }
cut_block "needs-human seam" "$T/seam.sh"
cut_block "stage lane verdict" "$T/lane.sh"
{ cut_fn LENS_ART; cut_fn LENS_VARS; cut_fn LENS_REFUSE; } > "$T/lens.sh"
for B in seam lane lens; do [ -s "$T/$B.sh" ] && ok || bad "could not extract '$B' from the pipeline text"; done

# S: the seam sources the lib and resolves issue/slug for an issues board only.
mkdir -p "$T/s/bin/lib/needs-human" "$T/s/repo"
cp "$LIB" "$T/s/bin/lib/"; cp "$CLASSIFY" "$TRIP" "$RELEASE" "$T/s/bin/lib/needs-human/"
printf '#!/bin/bash\n[ "${2:-}" = board_prefix ] && cat "%s/prefix"\n' "$T" > "$T/s/bin/fleet-conf.sh"; chmod +x "$T/s/bin/fleet-conf.sh"
git -C "$T/s/repo" init -q && git -C "$T/s/repo" remote add origin https://github.com/o/r.git
SEAM() { echo "$1" > "$T/prefix"; (cd "$T/s/repo" && HARNESS="$T/s" PROJECT=p KEY=BH-77 bash -c 'set -u; . "$1"; echo "$NH_ISSUE|$NH_SLUG|$(type -t nh_on_block)"' _ "$T/seam.sh" 2>&1); }
OUT=$(SEAM "-");  [ "$OUT" = "77|o/r|function" ] && ok || bad "S1: issues board seam gave '$OUT'"
OUT=$(SEAM "FR"); [ "$OUT" = "||function" ] && ok || bad "S2: board project seam gave '$OUT'"

# L: LENS_REFUSE review, driven the way the BH-1853 suite drives it.
DRIVE() { # DRIVE <build-dir> <with-lib:1|0> <script>
  local B="$1"
  ( BUILD="$B"; PROJECT=project-5; KEY=BH-1016; BASE=main; BRANCH=ticket/bh-1016
    REVIEW_MODEL=m; FIX_MODEL=m; RISKY=1; HIGHRISK=1
    STAMP() { echo 2026-09-29T00:00:00Z; }
    RESULT() { echo "$*" > "$B/RESULT"; }
    BB() { :; }
    # shellcheck disable=SC1090
    [ "$2" = 1 ] && . "$LIB"
    # shellcheck disable=SC1090
    . "$T/lane.sh"; . "$T/lens.sh"
    eval "$3" ) >/dev/null 2>"$B/stderr"
  echo "$? $(cat "$B/RESULT" 2>/dev/null || echo none)"
}
NB=0
fresh() { NB=$((NB+1)); B="$T/lb$NB"; mkdir -p "$B"; cp "$T/review.md" "$B/review.md"; }
fresh; OUT=$(DRIVE "$B" 1 'LENS_REFUSE review')
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md" ] && ok || bad "L1: with the stub lib: '$OUT'"
fresh; OUT=$(DRIVE "$B" 0 'LENS_REFUSE review')
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md" ] && ok || bad "L2: with no lib: '$OUT'"
[ ! -s "$B/stderr" ] && ok || bad "L2: the missing lib leaked stderr: $(cat "$B/stderr")"
fresh; OUT=$(DRIVE "$B" 1 'nh_on_block() { printf " NEEDS_HUMAN:abc123def456:set-env"; }; LENS_REFUSE review')
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md NEEDS_HUMAN:abc123def456:set-env" ] && ok || bad "L3: the suffix is not wired: '$OUT'"
fresh; OUT=$(DRIVE "$B" 1 'nh_on_block() { printf " NEEDS_HUMAN:abc123def456:set-env"; }; LENS_REFUSE security')
[ "$OUT" = "6 SECURITY_BLOCKED $B/security-review.md" ] && ok || bad "L3: the security lens took the suffix: '$OUT'"
fresh; OUT=$(DRIVE "$B" 1 'nh_trip_on_block() { echo "$1|$2|$4" > "$BUILD/trip"; return 9; }; nh_on_block() { return 7; }; LENS_REFUSE review')
[ "$OUT" = "6 REVIEW_BLOCKED $B/review.md" ] && [ "$(cat "$B/trip" 2>/dev/null)" = "project-5||lb$NB" ] \
  && ok || bad "L3: a failing hook changed the terminal or the trip hook was not called: '$OUT' trip='$(cat "$B/trip" 2>/dev/null)'"

# P: the PR body, via the evidence block as tests/pr-body-closes-test.sh drives it.
cut_block "evidence block" "$T/block.sh"
cut_block "merge note fn" "$T/mergenote.sh"
[ -s "$T/block.sh" ] && [ -s "$T/mergenote.sh" ] && ok || bad "could not extract the evidence block"
mkdir -p "$T/p/bin/lib" "$T/p/build" "$T/p/repo"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/p/bin/lib/"
cp "$T/s/bin/fleet-conf.sh" "$T/p/bin/"
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T/p" >/dev/null || exit 1
( cd "$T/p/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && git remote add origin https://github.com/o/r.git \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "TK-269: the subject" ) >/dev/null 2>&1
PBODY() { # PBODY <out> [pre-eval]
  echo "-" > "$T/prefix"
  ( cd "$T/p/repo" || exit 1
    env HARNESS="$T/p" BUILD="$T/p/build" KEY=TK-7 PRE="${2:-}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=ts; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/gh-rest.sh"
      eval "$PRE"
      . "$0"; . "$1"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
    ' "$T/mergenote.sh" "$T/block.sh" "$1" 2>"$1.err" )
}
PBODY "$T/body.none"                                   # no lib anywhere
mkdir -p "$T/p/bin/lib/needs-human"; cp "$LIB" "$T/p/bin/lib/"; cp "$CLASSIFY" "$TRIP" "$RELEASE" "$T/p/bin/lib/needs-human/"
PBODY "$T/body.stub"                                   # the stub lib, sourced by pr.sh itself
[ -s "$T/body.none" ] && grep -q '^Closes #7$' "$T/body.none" && ok || bad "P1: baseline body did not render: $(cat "$T/body.none.err")"
cmp -s "$T/body.none" "$T/body.stub" && ok || bad "P1: the stub lib changed the PR body: $(diff "$T/body.none" "$T/body.stub" | head -5)"
PBODY "$T/body.wired" '. "$HARNESS/bin/lib/needs-human.sh"; nh_pr_body_section() { printf "\n## Human step\n%s %s\n" "$1" "$2"; }'
grep -q '^## Human step$' "$T/body.wired" && grep -qx 'o/r 7' "$T/body.wired" && ok || bad "P1: nh_pr_body_section is not wired into the body: $(cat "$T/body.wired.err")"

# ── N: nothing alerted ─────────────────────────────────────────────────────
[ -z "$(find "$T" -name ALERTS.log)" ] && ok || bad "N1: an ALERTS.log was written"
# gh / gh_rest are reads now (BH-3446's release lib reads the thread); nothing alerts or queues a job.
[ -z "$(find "$T" -maxdepth 1 \( -name 'called.alert-line' -o -name 'called.jobs' \))" ] && ok || bad "N1: an alert/jobs stub was called: $(ls "$T"/called.* 2>/dev/null)"

echo "needs-human-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
