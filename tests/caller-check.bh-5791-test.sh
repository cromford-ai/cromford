#!/bin/bash
# tests/caller-check.bh-5791-test.sh — the caller check after the build's main
# merge (BH-5791): every caller of each changed interface is listed in the PR
# body as ported or left alone, with a reason, and the lead checks that list.
#
# HOW IT DRIVES. A scratch git repo: a base commit with a lib and two callers,
# and a branch that changes the interface. The K cases run the real
# "$DIR/bin/caller-check.sh" and "$DIR/bin/lib/caller-check.sh" from a
# scratch_install_closure tree. K5 lifts the `caller check (BH-5791)` block
# VERBATIM out of the flattened pipeline (tests/lib/rb-all.sh); K6 lifts the
# evidence block the way tests/evidence-block-test.sh does and renders
# PR_BODY_FOR under `set -u`. K9 reads "$DIR/prompts/lead-review-checklist.md".
#
#   K1-K4, K7, K8  the lib and the CLI
#   K5, K6         the pr.sh block and the PR body
#   K9             the lead review checklist item
# Run: HARNESS_TEST_SANDBOX=1 bash tests/caller-check.bh-5791-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$T/build"
scratch_install_closure bin/caller-check.sh "$H" >/dev/null || bad "K0: closure install failed for bin/caller-check.sh"
export HARNESS="$H"
TAB=$'\t'

# ── the git fixture ──────────────────────────────────────────────────────────
G() { git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
R="$T/repo"
git init -q -b main "$R"
cd "$R" || exit 1
mkdir -p lib docs
cat > lib/util.sh <<'SH'
#!/bin/bash
greet() { # greet <a>
  echo "$1"
}
gone_fn() { # gone_fn <a>
  echo "$1"
}
abc() { # abc
  :
}
SH
printf '#!/bin/bash\n. lib/util.sh\ngreet a\n' > x.sh
printf '#!/bin/bash\n. lib/util.sh\n# greet is called below\n\ngreet a\ngone_fn a\nabc\n' > y.sh
printf 'Call `greet a` to print a.\n' > docs/greet.md
G add -A && G commit -qm base
BASE_SHA=$(git rev-parse HEAD)
G checkout -q -b ticket/k1
sed -i 's/^greet() { # greet <a>$/greet() { # greet <a> <b>/' lib/util.sh
sed -i 's/^greet a$/greet a b/' x.sh
G commit -qam "K1: greet takes b"
K1_SHA=$(git rev-parse HEAD)

# ck <plan> [base] : run the CLI; OUT RC, $T/callers.txt
ck() {
  OUT=$(cd "$R" && "$H/bin/caller-check.sh" --repo "$R" --base "${2:-$BASE_SHA}" --head HEAD --plan "$1" --out "$T/callers.txt" 2>"$T/ck.err"); RC=$?
}
has() { grep -qF "$1" "$T/callers.txt" 2>/dev/null; }
printf '# plan\n\n## Scope\n\nChange greet.\n' > "$T/plan-none.md"

# K1 (ACCEPTANCE 2): a changed signature, one caller ported and one left alone
ck "$T/plan-none.md"
[ "$RC" = 0 ] && ok || bad "K1: the CLI must answer rc 0 (rc=$RC, $(cat "$T/ck.err"))"
has "greet${TAB}x.sh:3${TAB}ported" && ok || bad "K1: x.sh:3 must be ported: $(cat "$T/callers.txt" 2>/dev/null)"
has "greet${TAB}y.sh:5${TAB}left alone${TAB}no reason in the plan" && ok || bad "K1: y.sh:5 must be left alone with no reason: $(cat "$T/callers.txt" 2>/dev/null)"
case "$OUT" in CALLERS:*ported=1*left=1*noreason=1*) ok ;; *) bad "K1: summary wrong: $OUT" ;; esac

# K2: a definition gone at head, with a caller that still names it
G checkout -q -B ticket/k2 "$K1_SHA"
awk '/^gone_fn\(\)/{s=1} s&&/^}/{s=0; next} !s' lib/util.sh > lib/util.sh.new && mv lib/util.sh.new lib/util.sh
G commit -qam "K2: drop gone_fn"
ck "$T/plan-none.md"
has "gone_fn${TAB}y.sh:6${TAB}left alone${TAB}definition gone at head; this caller still names it" && ok || bad "K2: the gone def's caller must say so: $(cat "$T/callers.txt")"
case "$OUT" in *gone=1*) ok ;; *) bad "K2: summary must say gone=1: $OUT" ;; esac
G checkout -q ticket/k1

# K3: the plan's reason reaches the left-alone row
printf '# plan\n\n## Changed symbols\n\n- function `greet` — takes b; callers: left alone: the new arg is optional\n' > "$T/plan-reason.md"
ck "$T/plan-reason.md"
has "greet${TAB}y.sh:5${TAB}left alone${TAB}the new arg is optional" && ok || bad "K3: the plan's reason must reach y.sh:5: $(cat "$T/callers.txt")"
case "$OUT" in *noreason=0*) ok ;; *) bad "K3: summary must say noreason=0: $OUT" ;; esac

# K4: comments, docs and the def line are not callers; a short name is skipped
has "y.sh:3" && bad "K4: the comment line y.sh:3 must not be listed" || ok
has "docs/greet.md" && bad "K4: a .md file must not be listed" || ok
has "lib/util.sh:2" && bad "K4: the def line must not be listed" || ok
printf '# plan\n\n## Changed symbols\n\n- function `abc`: a new body.\n' > "$T/plan-short.md"
ck "$T/plan-short.md"
has "abc${TAB}skipped (name too short)" && ok || bad "K4: a 3-letter name must be skipped: $(cat "$T/callers.txt")"

# K7: the bullet cap, and the off switch
printf '#!/bin/bash\ngreet 1\ngreet 2\ngreet 3\n' > z.sh
G add z.sh && G commit -qm "K7: three more callers"
ck "$T/plan-none.md"
S=$(bash -c '. "$HARNESS/bin/lib/caller-check.sh" || exit 9; cc_section "$1" 2' _ "$T/callers.txt" 2>/dev/null)
[ "$(printf '%s\n' "$S" | grep -c '^- `greet`')" = 2 ] && ok || bad "K7: a cap of 2 must print 2 greet bullets: $S"
grep -qF '… and 3 more in callers.txt on the build box' <<<"$S" && ok || bad "K7: the cap must count the rest (5 callers, 2 shown): $S"
S=$(bash -c '. "$HARNESS/bin/lib/caller-check.sh" || exit 9; cc_section "$1" 0' _ "$T/callers.txt" 2>/dev/null)
[ -z "$S" ] && ok || bad "K7: a cap of 0 must give an empty section: $S"
G reset -q --hard "$K1_SHA"

# K8: an unresolvable base
ck "$T/plan-none.md" 0123456789abcdef0123456789abcdef01234567
[ "$RC" = 3 ] && ok || bad "K8: an unresolvable base must answer rc 3 (rc=$RC)"
S=$(bash -c '. "$HARNESS/bin/lib/caller-check.sh" || exit 9; cc_section "$1" 60' _ "$T/callers.txt" 2>/dev/null)
grep -q 'The caller check could not run:' <<<"$S" && ok || bad "K8: the section must say it could not run: $S"

# K10: a JS signature change; the plan lists nothing, so the diff finds it
G checkout -q -B ticket/k10 "$BASE_SHA"
printf 'export function priceFor(item) {\n  return item.p;\n}\n' > lib/price.js
printf 'import { priceFor } from "./lib/price.js";\nconsole.log(priceFor(a));\n' > use.js
G add -A && G commit -qm "K10: base for the JS case"
K10_BASE=$(git rev-parse HEAD)
sed -i 's/^export function priceFor(item) {$/export function priceFor(item, project-2) {/' lib/price.js
G commit -qam "K10: priceFor takes project-2"
ck "$T/plan-none.md" "$K10_BASE"
has "INTERFACE${TAB}priceFor${TAB}function${TAB}diff${TAB}changed" && ok || bad "K10: the JS def change must be an interface: $(cat "$T/callers.txt")"
has "priceFor${TAB}use.js:2${TAB}left alone${TAB}no reason in the plan" && ok || bad "K10: the JS caller must be left alone: $(cat "$T/callers.txt")"
has "priceFor${TAB}lib/price.js:1" && bad "K10: the JS def line must not be listed" || ok
G checkout -q ticket/k1

# ============================================================================
# K5. the pr.sh block, lifted from the pipeline
# ============================================================================
awk 'index($0,"# >>> caller check (BH-5791)")==1{f=1} f{print} index($0,"# <<< caller check (BH-5791)")==1{exit}' "$RB" > "$T/ck-block.sh"
[ -s "$T/ck-block.sh" ] && bash -n "$T/ck-block.sh" && ok || bad "K5: could not lift a valid caller check block"
L_RV=$(grep -n '^# <<< rebase verify' "$RB" | head -1 | cut -d: -f1)
L_CK=$(grep -n '^# >>> caller check (BH-5791)' "$RB" | head -1 | cut -d: -f1)
L_SE=$(grep -n '^STAGE_END rebase' "$RB" | head -1 | cut -d: -f1)
[ -n "$L_CK" ] && [ -n "$L_RV" ] && [ -n "$L_SE" ] && [ "$L_RV" -lt "$L_CK" ] && [ "$L_CK" -lt "$L_SE" ] && ok \
  || bad "K5: the block must sit after the rebase verify and before STAGE_END rebase (${L_RV:-?} < ${L_CK:-?} < ${L_SE:-?})"
G branch -q -f fake-main "$BASE_SHA"
G update-ref refs/remotes/origin/fake-main "$BASE_SHA"
OUT=$(cd "$R" && env BUILD="$T/build" PROJECT=tproj KEY=BH-5791 BASE=fake-main \
      bash -c 'STAMP() { echo TS; }; RESULT() { echo "$*" > "$0.result"; }; . "$0"; printf "%s" "$CALLERS_SECTION"' "$T/ck-block.sh" 2>"$T/k5.err"); RC=$?
[ "$(awk 'NF { print; exit }' <<<"$OUT")" = '## Interface callers (BH-5791)' ] && ok || bad "K5: CALLERS_SECTION must start with the heading (rc=$RC): $OUT $(head -3 "$T/k5.err")"
grep -qF '`greet` y.sh:5 — left alone — no reason in the plan' <<<"$OUT" && ok || bad "K5: the section must list the left-alone caller: $OUT"
[ "$(grep -c 'caller check: ' "$T/build/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "K5: exactly one caller check log line: $(cat "$T/build/pipeline.log" 2>/dev/null)"
[ ! -e "$T/ck-block.sh.result" ] && ok || bad "K5: the block must never call RESULT"
[ -s "$T/build/callers.txt" ] && ok || bad "K5: the block must write callers.txt"

# ============================================================================
# K6. PR_BODY_FOR carries the section last in the notes, and nothing when unset
# ============================================================================
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB" > "$T/evblock.sh"
grep -q 'CALLERS_SECTION:-' "$T/evblock.sh" && ok || bad "K6: PR_BODY_FOR must read \${CALLERS_SECTION:-}"
sed 's/\${CALLERS_SECTION:-}//' "$T/evblock.sh" > "$T/evblock.before.sh"
render() { # render <block> [CALLERS_SECTION value]
  ( cd "$R" && env PATH="$PATH" HARNESS="$T/h" BUILD="$T/build" "${@:2}" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=p; KEY=K; BASE=main; CHANGED="x.sh"
      TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; E2E_VERDICT=pass; ADDED_SQL=""; MIG_NOTE=""
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes; STACK_SECTION=""; MERGE_NOTE=""
      . "$0" >/dev/null 2>&1
      # The block resets both; set them after it, as the pipeline does.
      ASSUMPTIONS_SECTION=""; NH_PR_SECTION="
## Needs human
nh"
      PR_BODY_FOR "EVIDENCE"' "$1" 2>/dev/null )
}
A=$(render "$T/evblock.sh"); B=$(render "$T/evblock.before.sh")
[ -n "$A" ] && [ "$A" = "$B" ] && ok || bad "K6: with CALLERS_SECTION unset the body must be byte-identical to the block without it"
C=$(render "$T/evblock.sh" CALLERS_SECTION="
## Interface callers (BH-5791)
interfaces=1")
printf '%s\n' "$C" | awk '/^## Needs human/{n=NR} /^## Interface callers \(BH-5791\)/{c=NR} END{exit !(n>0 && c>n)}' && ok || bad "K6: the section must follow the needs-human section: $C"

# ============================================================================
# K9. the lead review checklist
# ============================================================================
CL="$DIR/prompts/lead-review-checklist.md"
grep -qE '^13\. Interface callers' "$CL" && ok || bad "K9: the checklist has no item 13 Interface callers"
grep -qF '## Interface callers' "$CL" && ok || bad "K9: item 13 must name the ## Interface callers section"
head -1 "$CL" | grep -qE '^Checklist-Version: [0-9]+$' && ok || bad "K9: line 1 must stay the version line"

echo "caller-check.bh-5791-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
