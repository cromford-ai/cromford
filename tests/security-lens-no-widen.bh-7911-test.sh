#!/bin/bash
# tests/security-lens-no-widen.bh-7911-test.sh — the attack-class notes make the
# security lens sharper and buy nothing else (BH-7911).
#
# Drives the real `# >>> review lenses` block of the review stage, extracted
# through tests/lib/rb-all.sh as tests/parallel-lenses-test.sh does, with a stub
# CC that records every launch and the prompt it was given. What is pinned:
#   N1 KIND: copy with a README diff  -> 1 launch, no security lens, no diff file
#   N2 a non-risky diff               -> 1 launch, no security lens, no diff file
#   N3 a risky diff                   -> 2 launches; the security prompt carries
#      the class notes and the "never a whole-repo audit here" line, and the
#      general prompt carries no class text
#   N4 the counts 1, 1, 2 equal the counts of the merge base's block
#   N5 lib absent                     -> 2 launches, no class text, "off (lib missing)"
#   N6 a malformed table              -> 2 launches, no class text, "off (rc 2:", no RESULT
# Run from anywhere: tests/security-lens-no-widen.bh-7911-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# extract <repo-dir> <out-dir> — the lens, timing and suite-run blocks of that tree.
extract() {
  local all
  mkdir -p "$2"
  all=$(rb_all "$1" "$2/run-build.all.sh") || return 1
  awk '/^# >>> review lenses/{f=1;next} /^# <<< review lenses/{exit} f' "$all" > "$2/lenses.sh"
  awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' "$all" > "$2/timing.sh"
  awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$all" > "$2/suite-run.sh"
  [ -s "$2/lenses.sh" ] && [ -s "$2/timing.sh" ] && [ -s "$2/suite-run.sh" ]
}
extract "$DIR" "$T/head" && ok || bad "could not extract the review-lens block of this tree"
grep -q '# >>> security lens classes (BH-7911)' "$T/head/lenses.sh" && ok \
  || bad "the review-lens block carries no '# >>> security lens classes (BH-7911)' block"

# A harness root with the lib's closure, the real table and the real class files.
H="$T/h"
mkdir -p "$H/bin" "$H/catalog" "$H/prompts"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/findings-log.sh"; chmod +x "$H/bin/findings-log.sh"
scratch_install_closure bin/lib/security-lens-classes.sh "$H" >/dev/null || bad "could not install the lib closure"
cp "$DIR/catalog/security-classes.tsv" "$H/catalog/security-classes.tsv"
cp -R "$DIR/prompts/security-classes" "$H/prompts/security-classes"
# The review block renders prompts/stages/*.md through $HARNESS/bin/lib/stage-prompt.sh (BH-7970); the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$H" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$H/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$H/prompts/stages/"

REPO="$T/repo"
setup_repo() { # setup_repo <file>... — files whose NAMES decide which lenses run
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo base > README.md
    git add -A; git -c commit.gpgsign=false commit -qm base
    git checkout -q -b feat
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo x >> "$f"; done
    git add -A; git -c commit.gpgsign=false commit -qm work ) >/dev/null 2>&1
}

# run <blocks-dir> <harness-root> [env...] — run the block once. The stub CC
# appends "<stage> <basename out>" to $T/launch.log, writes its prompt to
# $T/prompt.<basename out>, and approves.
run() {
  local blocks="$1" har="$2"; shift 2
  rm -rf "$T/build" "$T"/prompt.*; mkdir -p "$T/build"; : > "$T/launch.log"
  ( cd "$REPO" || exit 1
    env HARNESS="$har" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=feat \
        REVIEW_MODEL=rm FIX_MODEL=fm LAUNCH="$T/launch.log" PDIR="$T" \
        REOPEN_HOT=0 REOPEN_NOTE="" KIND_SKIP_SECLENS=0 REOPEN_EXTRA_LENS=0 \
        GATES_NOTE="" SPEC_DIR=.harness/specs CG_ORIENT=x LENSES_PARALLEL=1 \
        "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      BB() { :; }
      PUSH_BRANCH() { :; }
      CC() {
        local stage="$1" out="$4" prompt="$5" base
        base=$(basename "$out")
        printf "%s %s\n" "$stage" "$base" >> "$LAUNCH"
        printf "%s" "$prompt" > "$PDIR/prompt.$base"
        case "$base" in
          review-run.txt)          printf "ok\nTIER: 1\nVERDICT: APPROVE\n" > "$BUILD/review.md" ;;
          security-review-run.txt) printf "ok\nVERDICT: APPROVE\n" > "$BUILD/security-review.md" ;;
          refute-review-run.txt)   printf "ok\nVERDICT: APPROVE\n" > "$BUILD/refute-review.md" ;;
        esac
      }
      . "$1"; . "$2"; . "$0"
    ' "$blocks/lenses.sh" "$blocks/timing.sh" "$blocks/suite-run.sh" >/dev/null 2>&1 )
}
launches() { wc -l < "$T/launch.log" | tr -d ' '; }

AUDIT_LINE='Never ask for, and never perform, a whole-repo audit here'

# ── N1 KIND: copy ───────────────────────────────────────────────────────────
setup_repo README.md
run "$T/head" "$H" KIND_SKIP_SECLENS=1
N1=$(launches)
[ "$N1" = 1 ] && ok || bad "N1 KIND: copy launched $N1 lenses: $(paste -sd, "$T/launch.log")"
[ "$(cat "$T/launch.log")" = "review review-run.txt" ] && ok || bad "N1 the one launch is not the general review: $(cat "$T/launch.log")"
[ ! -e "$T/prompt.security-review-run.txt" ] && ok || bad "N1 a security lens ran on a KIND: copy diff"
[ ! -e "$T/build/security-lens.diff" ] && ok || bad "N1 the class block ran a git diff with no security lens"
grep -q 'security-lens-classes\|SECURITY LENS CLASSES' "$T/build/pipeline.log" 2>/dev/null \
  && bad "N1 the class block logged with no security lens" || ok

# ── N2 non-risky ────────────────────────────────────────────────────────────
setup_repo src/app.ts
run "$T/head" "$H"
N2=$(launches)
[ "$N2" = 1 ] && ok || bad "N2 a non-risky diff launched $N2 lenses: $(paste -sd, "$T/launch.log")"
[ ! -e "$T/prompt.security-review-run.txt" ] && ok || bad "N2 a security lens ran on a non-risky diff"
[ ! -e "$T/build/security-lens.diff" ] && ok || bad "N2 the class block ran a git diff with no security lens"

# ── N3 risky ────────────────────────────────────────────────────────────────
setup_repo src/auth/session.ts
run "$T/head" "$H"
N3=$(launches)
[ "$N3" = 2 ] && ok || bad "N3 a risky diff launched $N3 lenses: $(paste -sd, "$T/launch.log")"
grep -qx 'review security-review-run.txt' "$T/launch.log" && ok || bad "N3 no security lens launch"
SP="$T/prompt.security-review-run.txt"
grep -qF "ATTACK-CLASS NOTES for this diff's surface (web-auth)" "$SP" 2>/dev/null && ok \
  || bad "N3 the security prompt lacks the ATTACK-CLASS NOTES (web-auth) header"
grep -qF '=== attack class: web-auth (prompts/security-classes/web-auth.md) ===' "$SP" 2>/dev/null && ok \
  || bad "N3 the security prompt lacks the web-auth class text"
grep -qF -- "$(sed -n 1p "$DIR/prompts/security-classes/web-auth.md")" "$SP" 2>/dev/null && ok \
  || bad "N3 the security prompt does not carry the vendored web-auth file"
grep -qF -- "$AUDIT_LINE" "$SP" 2>/dev/null && ok || bad "N3 the security prompt lacks the whole-repo audit line"
grep -qF 'SECURITY-ONLY review of the diff of branch feat' "$SP" 2>/dev/null && ok \
  || bad "N3 the security prompt lost its own brief"
grep -qF '=== attack class:' "$T/prompt.review-run.txt" 2>/dev/null && bad "N3 the general review prompt got class text" || ok
grep -qF 'SECURITY LENS CLASSES: web-auth' "$T/build/pipeline.log" && ok || bad "N3 pipeline.log lacks 'SECURITY LENS CLASSES: web-auth'"
[ ! -e "$T/build/RESULT" ] && ok || bad "N3 the block wrote a RESULT: $(cat "$T/build/RESULT")"

# ── N4 the same counts as the merge base ────────────────────────────────────
MB=$(cd "$DIR" && git merge-base HEAD origin/main 2>/dev/null)
if [ -n "$MB" ] && mkdir -p "$T/base-tree" \
   && (cd "$DIR" && git archive "$MB" bin/run-build.sh bin/lib/rb) | tar -x -C "$T/base-tree" 2>/dev/null \
   && extract "$T/base-tree" "$T/base"; then
  setup_repo README.md;        run "$T/base" "$H" KIND_SKIP_SECLENS=1; B1=$(launches)
  setup_repo src/app.ts;       run "$T/base" "$H";                     B2=$(launches)
  setup_repo src/auth/session.ts; run "$T/base" "$H";                  B3=$(launches)
  [ "$N1 $N2 $N3" = "$B1 $B2 $B3" ] && ok || bad "N4 launches $N1 $N2 $N3 differ from the merge base's $B1 $B2 $B3"
else
  echo "N4 skipped: no merge base"
fi
[ "$N1 $N2 $N3" = "1 1 2" ] && ok || bad "N4 launches are $N1 $N2 $N3, not 1 1 2"

# ── N5 lib absent ───────────────────────────────────────────────────────────
H5="$T/h5"; mkdir -p "$H5/bin"; cp "$H/bin/findings-log.sh" "$H5/bin/"
scratch_install_closure bin/lib/stage-prompt.sh "$H5" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the N5 harness"
mkdir -p "$H5/prompts"; cp -R "$H/prompts/stages" "$H5/prompts/stages"
setup_repo src/auth/session.ts
run "$T/head" "$H5"
[ "$(launches)" = 2 ] && ok || bad "N5 lib absent launched $(launches) lenses"
grep -qF -- "$AUDIT_LINE" "$SP" 2>/dev/null && ok || bad "N5 the security prompt lacks the whole-repo audit line"
grep -qF '=== attack class:' "$SP" 2>/dev/null && bad "N5 class text with no lib" || ok
grep -qF 'security-lens-classes: off (lib missing)' "$T/build/pipeline.log" && ok || bad "N5 pipeline.log lacks 'off (lib missing)'"

# ── N6 malformed table ──────────────────────────────────────────────────────
H6="$T/h6"; cp -R "$H" "$H6"
printf 'web-auth\tauth\tthree-fields\n' > "$H6/catalog/security-classes.tsv"
run "$T/head" "$H6"
[ "$(launches)" = 2 ] && ok || bad "N6 a bad table launched $(launches) lenses"
grep -qF '=== attack class:' "$SP" 2>/dev/null && bad "N6 class text from a bad table" || ok
grep -qF -- "$AUDIT_LINE" "$SP" 2>/dev/null && ok || bad "N6 the security prompt lacks the whole-repo audit line"
grep -qF 'security-lens-classes: off (rc 2:' "$T/build/pipeline.log" && ok || bad "N6 pipeline.log lacks 'off (rc 2:'"
grep -qF 'SECURITY LENS CLASSES:' "$T/build/pipeline.log" && bad "N6 a bad table logged SECURITY LENS CLASSES" || ok
[ ! -e "$T/build/RESULT" ] && ok || bad "N6 the block wrote a RESULT: $(cat "$T/build/RESULT")"

echo "security-lens-no-widen.bh-7911-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
