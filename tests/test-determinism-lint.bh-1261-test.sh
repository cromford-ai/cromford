#!/bin/bash
# tests/test-determinism-lint.bh-1261-test.sh — the branch-arm-ungated rule.
#
#   THE PROPERTY UNDER TEST: a suite line that captures THIS BRANCH's diff
#   against main and asserts on it, inside a block that never gates on whose
#   branch it is, is a finding. The same arm with an own-slice gate — the
#   ticket's spec dir, or a path the block declares with `own-slice:` — is
#   quiet, and so is every arm that judges a fixture TREE rather than a branch.
#
# 2026-09-21: tests/inapp-prompt-blocked-rule.bh-903-test.sh and
# tests/file-children.bh-981-test.sh each carried "this branch must not touch X"
# computed from `git diff --name-only origin/main...HEAD` with no gate. #1158
# went red for editing worker/ on its own ticket, #727 for editing
# bin/triage-gate.sh on BH-590. #1260 gated those two by hand; this rule is the
# class, so the next one cannot merge ungated.
#
# determinism: ok-file branch-arm-ungated the fixtures below carry the ungated
# branch-arm shape as DATA for the lint to find; this suite asserts on the
# lint's output, and judges no branch of its own.
# Run from anywhere: tests/test-determinism-lint.bh-1261-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/test-determinism-lint.sh"
CONF="$DIR/catalog/determinism-lint.conf"
mkdir -p "$T/h/flags"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run <dir-or-file> [flags...] -> stdout in $OUT, rc in $RC. HARNESS points at a
# scratch tree so a box-local flags/determinism-lint.conf can never leak in.
run() { OUT=$(HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
runc() { local c="$1"; shift; OUT=$(DETERMINISM_LINT_CONF="$c" HARNESS="$T/h" bash "$LINT" "$@" 2>&1); RC=$?; }
has() { grep -qE "$1" <<<"$OUT"; }
nfind() { grep -c 'branch-arm-ungated' <<<"$OUT"; }
case_dir() { rm -rf "$T/c"; mkdir -p "$T/c/tests"; }

# ── 1. THE SHAPE: bh-903's arm as it stood before #1260 ──────────────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)
  if grep -q '^worker/' <<<"$CHANGED"; then
    bad "this branch edits worker/ — that receiver is its own ticket, not this one"
  else ok; fi
fi
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'x-test\.sh:3: branch-arm-ungated'; } && ok \
  || bad "1: an ungated branch arm was not flagged at its capture line (rc=$RC): $OUT"
has 'own-slice' && ok || bad "1: the finding must name the two ways out (spec dir, own-slice): $OUT"

# ── 2. GATED on the ticket's spec dir (#1260's fix) ──────────────────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)
  if ! grep -qE '^(\.harness/specs/BH-903/|guardrails/inapp-prompt)' <<<"$(printf '%s\n' "$CHANGED")"; then
    echo "SKIP (this branch is not BH-903's slice) — the negative-diff arm judges only the ticket's own branch."
  else
  if grep -q '^worker/' <<<"$CHANGED"; then
    bad "this branch edits worker/ — that receiver is its own ticket, not this one"
  else ok; fi
  fi
fi
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "2: a spec-dir gate in the block must silence the arm (rc=$RC): $OUT"

# ── 3. GATED by declaration: the block says which path it owns ───────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
OWN=$(git -C "$DIR" diff --name-only "$B" 2>/dev/null)
if ! grep -qE '^bin/lib/foo\.sh$' <<<"$(printf '%s\n' "$OWN")"; then  # own-slice: bin/lib/foo.sh
  echo "note: this branch is not foo's slice — this arm judges only its own branch"
else
  [ -z "$(git -C "$DIR" diff --name-only "$B" -- bin/other/)" ] && ok || bad "a stray file"
fi
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "3: an own-slice declaration must silence every capture in the block (rc=$RC): $OUT"

# ── 4. A FIXTURE REPO with no assertion in the block (bh-806's tier_of) ──────
# The diff is the fixture's own two commits and nothing judges a path: the
# helper returns a tier, and the assertion lives in its own paragraph.
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
tier_of() { # tier_of <repo> — the TIER the production line decides
  ( set -uo pipefail; cd "$1"
    BASE=$(git rev-parse HEAD~1); TIER=1
    CHANGED=$(git diff --name-only "$BASE"...HEAD)
    [ "${#CHANGED}" -gt 65536 ] || { echo "FIXTURE-TOO-SMALL:${#CHANGED}"; exit 0; }
    echo "$TIER" )
}

[ "$(tier_of "$T/diff-schema")" = 2 ] && ok || bad "D: a schema change must be TIER 2"
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "4: a capture with no assertion in its block must stay quiet (rc=$RC): $OUT"

# ── 5. TREE judgments: a scratch repo's own diff is not this branch ──────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
[ -z "$(git -C "$R" diff --name-only --diff-filter=U)" ] && ok || bad "conflict markers survived"
CH=$(git -C "$T/repo" diff --name-only main...HEAD)
[ "$CH" = "a.txt" ] && ok || bad "the branch must carry exactly a.txt, got: $CH"
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "5: a fixture-tree diff must not be read as a branch arm (rc=$RC): $OUT"

# ── 6. PROSE: the command quoted in an echo is not an arm ────────────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  ok
else
  echo "SKIP the builder pastes \`git diff --name-only origin/main...HEAD\` output in the PR body instead."
  bad "no main ref and no pasted evidence"
fi
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "6: a capture quoted inside an echo must stay quiet (rc=$RC): $OUT"

# ── 7. SAME-LINE capture and assertion (hotfix-lib's no-new-sink arm) ────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
B=main; git -C "$DIR" rev-parse --verify -q main >/dev/null || B=origin/main
if git -C "$DIR" rev-parse --verify -q "$B" >/dev/null; then
  [ "$(git -C "$DIR" diff --name-only --diff-filter=AR "$B" -- bin/ | grep -c '^bin/alert-')" = 0 ] \
    && ok || bad "this slice must not add a new bin/alert-* sink"
fi
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'x-test\.sh:4: branch-arm-ungated'; } && ok \
  || bad "7: a capture asserted on the next line was not flagged (rc=$RC): $OUT"

# ── 8. eq IS an assertion (render-rules' B6 consumers arm) ───────────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
REF=$(git -C "$DIR" rev-parse -q --verify origin/main 2>/dev/null)
if [ -n "$REF" ]; then
  CH=$(git -C "$DIR" diff --name-only "$REF" -- bin/update-runners.sh bin/sync-agent-rules.sh \
       fly/builder-runner.sh bin/rules-drift-check.sh bin/context-signature.sh)
  eq "B6 the five consumers of rules/CLAUDE.md are untouched" "$CH" ""
fi
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'x-test\.sh:4: branch-arm-ungated'; } && ok \
  || bad "8: eq as the assertion must count (rc=$RC): $OUT"

# ── 9. the waiver, and the reasonless waiver ─────────────────────────────────
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)   # determinism: ok this fixture repo IS the branch under test
  if grep -q '^worker/' <<<"$CHANGED"; then
    bad "this branch edits worker/"
  else ok; fi
fi
EOF
run "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "9: a waiver with a reason must silence the line (rc=$RC): $OUT"
sed -i 's/# determinism: ok this fixture repo IS the branch under test/# determinism: ok/' "$T/c/tests/x-test.sh"
run "$T/c"
{ [ "$RC" = 1 ] && has 'waiver-no-reason'; } && ok \
  || bad "9: a reasonless waiver must be its own finding (rc=$RC): $OUT"

# ── 10. the gate at the if head, the captures below it (priority-rank A10) ───
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
B=main; git -C "$DIR" rev-parse --verify -q main >/dev/null || B=origin/main
# This arm judges BH-644/BH-645's OWN slices; on any other branch it stays inert.
OWN=$(git -C "$DIR" diff --name-only "$B" 2>/dev/null; git -C "$DIR" diff --name-only 2>/dev/null)
if ! grep -qE '^(\.harness/specs/BH-64[45]/|bin/lib/hotfix-lib\.sh$)' <<<"$(printf '%s\n' "$OWN")"; then
  echo "note: this branch is not BH-644/BH-645's slice"
elif git -C "$DIR" rev-parse --verify -q "$B" >/dev/null; then
  STRAY=$(git -C "$DIR" diff --name-only "$B" -- bin/ \
          | grep -v -e '^bin/lib/hotfix-lib.sh$' -e '^bin/run-build.sh$' | head -5)
  [ -z "$STRAY" ] && ok || bad "the slices on this branch may touch only those: $STRAY"
  [ "$(git -C "$DIR" diff --name-only "$B" -- bin/lib/ | grep -c .)" -le 1 ] \
    && ok || bad "no second lib may change in this slice"
fi
EOF
run "$T/c"
{ [ "$RC" = 0 ] && [ "$(nfind)" = 0 ]; } && ok \
  || bad "10: a gate at the if head must cover the captures in the elif body (rc=$RC): $OUT"

# ── 11. A COMMENT IS NEVER A GATE ────────────────────────────────────────────
# Comments are never findings and never gates: the sentence "this judges BH-1's
# own slice" in a comment is exactly what the two red suites had.
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
# this arm judges BH-1's own slice (.harness/specs/BH-1/) and nothing else
CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)
grep -q '^worker/' <<<"$(printf '%s\n' "$CHANGED")" && bad "worker/ is another ticket" || ok
EOF
run "$T/c"
{ [ "$RC" = 1 ] && has 'x-test\.sh:3: branch-arm-ungated'; } && ok \
  || bad "11: a comment naming a spec dir must not gate the block (rc=$RC): $OUT"

# ── 12. the rule, its vocabulary and its knobs are the conf, not the script ──
case_dir
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)
  if grep -q '^worker/' <<<"$CHANGED"; then
    bad "this branch edits worker/"
  else ok; fi
fi
EOF
grep -v '^rule[[:space:]]*branch-arm-ungated' "$CONF" > "$T/conf-norule.conf"
runc "$T/conf-norule.conf" "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "12: deleting the rule line from the conf must silence it (rc=$RC): $OUT"
run "$T/c"
[ "$RC" = 1 ] && ok || bad "12: the same fixture must still be a finding under the shipped conf (rc=$RC): $OUT"
# the assertion vocabulary is a knob: narrow it to bad and the eq arm slips through
cat > "$T/c/tests/x-test.sh" <<'EOF'
#!/bin/bash
REF=$(git -C "$DIR" rev-parse -q --verify origin/main 2>/dev/null)
if [ -n "$REF" ]; then
  CH=$(git -C "$DIR" diff --name-only "$REF" -- bin/update-runners.sh)
  eq "B6 the five consumers of rules/CLAUDE.md are untouched" "$CH" ""
fi
EOF
{ grep -v '^opt[[:space:]]*branch_arm_assert_re' "$CONF"
  printf 'opt branch_arm_assert_re (^|[^A-Za-z0-9_])bad[[:space:]]\n'; } > "$T/conf-badonly.conf"
runc "$T/conf-badonly.conf" "$T/c"
{ [ "$RC" = 0 ] && ! has 'branch-arm-ungated'; } && ok \
  || bad "12: branch_arm_assert_re must decide what counts as an assertion (rc=$RC): $OUT"
run "$T/c"
{ [ "$RC" = 1 ] && has 'branch-arm-ungated'; } && ok \
  || bad "12: the shipped conf must count eq (rc=$RC): $OUT"
run --rules
{ [ "$RC" = 0 ] && has '^rule[[:space:]]+branch-arm-ungated[[:space:]]+error[[:space:]]+sh' \
  && [ "$(grep -c 'branch_arm_' <<<"$OUT")" = 4 ]; } && ok \
  || bad "12: --rules must print the rule and its four knobs: $OUT"

# ── 13. this repo's own tree carries no ungated branch arm ───────────────────
# The audit half of BH-1261: the rule ships with the corpus already clean, so
# it cannot turn main red on the day it lands. Case 12 above pins the rule as
# an ERROR, so the job's rc 0 means no branch-arm-ungated finding.
# The whole-tree scan is not repeated here. The "Test determinism lint" job in
# .github/workflows/harness-ci.yml runs bin/test-determinism-lint.sh over this
# repo's tree on every PR, batch and push, and a finding fails it with rc 1.
# Re-running that scan here only doubled its cost in every batch.
# tests/dedicated-job-coverage-test.sh checks that the job keeps running it.

echo "test-determinism-lint.bh-1261: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
