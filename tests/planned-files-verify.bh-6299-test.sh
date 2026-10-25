#!/bin/bash
# tests/planned-files-verify.bh-6299-test.sh — a path a plan only RUNS is not
# a path it claims.
#
# WHY (BH-6299). project-6-os plans named six repo-wide guard tests on their
# VALIDATE lines and in their file lists, because each slice runs them. The
# builds almost never edit them, but bin/planned-files.sh scraped every path,
# so the six tickets collided on files none of them touched. The planner now
# puts run-only paths under '## Verify (run, not edited)', and the extractor
# skips that section and every VALIDATE: line. A path named on any other line
# is still listed.
#
# P1-P3 drive the real bin/planned-files.sh. P4 drives the real
# bin/run-preplan.sh with a stub agent and asserts the rule is in the prompt
# it sends; for bin/lib/rb/plan.sh (no standalone entry) it checks the call is
# in the prompt line and that the rule renders.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/planned-files-verify.bh-6299-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PF="$DIR/bin/planned-files.sh"
VL="$DIR/bin/lib/verify-list.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
has() { grep -qxF "$2" "$1/planned-files.txt"; }

B="$T/b"; mkdir -p "$B"
cat > "$B/plan.md" <<'EOF'
# TK-61 plan

## Files to touch
- `src/registry/TK-61.ts` (NEW)
- `src/lib/db/scoped.ts` — one export added

## Tasks
### Task 1
Add the registry entry in `src/registry/TK-61.ts`.
VALIDATE: npx vitest run tests/unit/registry-loader.test.ts
- VALIDATE: `node scripts/checks/only-on-validate.mjs`
  * VALIDATE: npx vitest run tests/unit/bullet-validate.test.ts

## Verify (run, not edited)
- `tests/unit/rls-baseline.TK-1.test.ts`
- `scripts/checks/company-query.mjs`
- `src/lib/db/scoped.ts`

### Notes under verify
- `tests/e2e/os-shell.TK-1.spec.ts`

## Verification checklist
- `tests/unit/TK-61-new.test.ts` is created by Task 1 and must pass.

## Acceptance tests
- `tests/unit/TK-61.test.ts` asserts the entry loads.
REPRO: npx vitest run tests/unit/repro-line.test.ts
EOF
"$PF" "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "planned-files.sh rc=$rc"
# P1: only under ## Verify -> absent (sub-headings stay inside the section)
for p in tests/unit/rls-baseline.TK-1.test.ts scripts/checks/company-query.mjs tests/e2e/os-shell.TK-1.spec.ts; do
  has "$B" "$p" && bad "P1: $p is only under ## Verify, it must not be claimed: $(cat "$B/planned-files.txt")" || ok
done
# P2: only on a VALIDATE: line -> absent, bare or bulleted
for p in tests/unit/registry-loader.test.ts scripts/checks/only-on-validate.mjs tests/unit/bullet-validate.test.ts; do
  has "$B" "$p" && bad "P2: $p is only on a VALIDATE line, it must not be claimed: $(cat "$B/planned-files.txt")" || ok
done
# P3: also named in files-to-touch -> present; the next ## heading ends Verify;
# "## Verification checklist" is not the Verify section
for p in tests/unit/TK-61-new.test.ts src/registry/TK-61.ts src/lib/db/scoped.ts tests/unit/TK-61.test.ts tests/unit/repro-line.test.ts; do
  has "$B" "$p" && ok || bad "P3: $p must still be claimed: $(cat "$B/planned-files.txt")"
done

# ---------- P4: the planner is told -----------------------------------------
[ -f "$VL" ] && ok || bad "bin/lib/verify-list.sh must exist"
R=$(bash -c '. "$1" 2>/dev/null && vl_plan_rule' _ "$VL" 2>/dev/null)
grep -qF '## Verify (run, not edited)' <<<"$R" && ok || bad "P4: vl_plan_rule must name the '## Verify (run, not edited)' heading (got: $R)"
grep -qF 'MODIFY or CREATE' <<<"$R" && ok || bad "P4: vl_plan_rule must say MODIFY or CREATE (got: $R)"
# bin/lib/rb/plan.sh: the call must be inside the CC plan prompt line. The
# count guards the absent-symbol case, so a deleted call is red.
# TEST-CHANGE (BH-7970): the call moved from the CC plan line to the SP_PLAN_VL precompute, and the template carries its token.
N=$(grep -c '^SP_PLAN_VL=.*vl_plan_rule' "$DIR/bin/lib/rb/plan.sh")
[ "${N:-0}" -ge 1 ] && grep -qF '${SP_PLAN_VL}' "$DIR/prompts/stages/plan.md" && ok || bad "P4: bin/lib/rb/plan.sh's plan prompt must call vl_plan_rule"
N=$(grep -c 'lib/verify-list.sh' "$DIR/bin/lib/rb/plan.sh")
[ "${N:-0}" -ge 1 ] && ok || bad "P4: bin/lib/rb/plan.sh must source bin/lib/verify-list.sh"

# bin/run-preplan.sh, driven: the stub agent keeps the prompt.
P="$T/pp"
mkdir -p "$P/bin/lib" "$P/env" "$P/flags" "$P/logs" "$P/plans" "$P/locks" "$P/repos/proj"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$P" proj || exit 1
scratch_install_closure bin/run-preplan.sh "$P" >/dev/null || bad "cannot install the run-preplan closure"
: > "$P/env/global.env"
cat > "$P/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s' "$6" > "${PROMPT_DIR:?}/prompt.txt"
exit 0
STUB
chmod +x "$P/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$P/bin/git"; chmod +x "$P/bin/git"
lane() { rm -f "$P/prompt.txt"; PATH="$P/bin:$PATH" PROMPT_DIR="$P" HARNESS="$P" REPOS_ROOT="$P/repos" bash "$P/bin/run-preplan.sh" proj 1 "$1" >/dev/null 2>&1; }
lane TK-61; RC=$?
[ "$RC" = 0 ] && ok || bad "P4: the pre-plan lane must exit 0 (rc $RC)"
PR=$(cat "$P/prompt.txt" 2>/dev/null)
grep -qF '## Verify (run, not edited)' <<<"$PR" && ok || bad "P4: the pre-plan prompt must carry the verify-list rule"
grep -qF 'MODIFY or CREATE' <<<"$PR" && ok || bad "P4: the pre-plan prompt must say MODIFY or CREATE"
# A box whose sync has not landed the lib pre-plans exactly as before.
mv "$P/bin/lib/verify-list.sh" "$T/vl-parked.sh" 2>/dev/null
lane TK-62; RC=$?
PR=$(cat "$P/prompt.txt" 2>/dev/null)
[ "$RC" = 0 ] && grep -qF 'Write a precise implementation plan' <<<"$PR" && ok \
  || bad "P4: with the lib absent the lane must still send its prompt (rc $RC)"
grep -qF '## Verify (run, not edited)' <<<"$PR" && bad "P4: with no lib there is no rule to send" || ok

echo "planned-files-verify.bh-6299: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
