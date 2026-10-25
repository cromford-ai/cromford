#!/bin/bash
# tests/spec-artifact-test.sh — the spec-artifact stage of bin/run-build.sh,
# extracted VERBATIM and driven against a real git repo, plus the merge sweep's
# added-line scan run over a diff that contains a spec file.
#
# What is actually at risk here, and therefore what this pins:
#
#   1. The PR must CARRY the plan it was built from. A spec that stays in the
#      build dir dies with the box that ran it.
#   2. The stage must be IDEMPOTENT. Fix rounds and checkpoint-resumes re-enter
#      this code; a second copy of the spec, or an empty commit per round, is
#      the failure shape.
#   3. It must land AFTER the EXECUTE checkpoint. That checkpoint asks "does
#      this branch already carry commits?" — a spec commit made before it would
#      make every resumed build skip the stage that writes the code.
#   4. Spec text is NOT code: the merge sweep's iron-law scan reads ADDED lines,
#      and a plan quoting a client's "no more confirm() dialogs" must not park
#      its own PR on the words it used to describe the fix.
#
# Run from anywhere: tests/spec-artifact-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin" "$T/build"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> spec artifact/{f=1;next} /^# <<< spec artifact/{exit} f' \
  "$RB_ALL" > "$T/spec.sh"
[ -s "$T/spec.sh" ] && ok || bad "could not extract the spec-artifact block — markers missing?"

# --- a repo shaped like a worktree at the moment the stage runs ---------------
# i.e. branch cut from base, EXECUTE has already committed code onto it.
mkrepo() {
  rm -rf "$T/repo"; mkdir -p "$T/repo"
  git -C "$T/repo" init -q -b main
  git -C "$T/repo" config user.email harness@example.invalid
  git -C "$T/repo" config user.name harness-test
  echo "export const x = 1" > "$T/repo/app.ts"
  git -C "$T/repo" add -A && git -C "$T/repo" commit -qm base
  git -C "$T/repo" checkout -qb ticket/TK-42
  echo "export const x = 2" > "$T/repo/app.ts"
  git -C "$T/repo" commit -qam "TK-42: bump x"
}

# run <key> -> runs the extracted stage in $T/repo; SPEC_LINE lands in SPECLINE.txt
run() {
  rm -f "$T/SPECLINE.txt"
  ( cd "$T/repo" && PROJECT=demo KEY="$1" BUILD="$T/build" \
      bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"; printf "%s" "${SPEC_LINE:-}" > '"$T"'/SPECLINE.txt' \
      "$T/spec.sh" >/dev/null 2>&1 )
  echo "$?"
}
commits() { git -C "$T/repo" rev-list --count HEAD; }
tracked() { git -C "$T/repo" ls-files "$1"; }

mkrepo
printf '# Plan for TK-42\n\nSwap the native confirm() for the shared modal.\n\nVALIDATE: npm test\nSATISFIES: the ticket\nSIZE: S\n' > "$T/build/plan.md"
BEFORE=$(commits)
RC=$(run TK-42)

# ---------- 1. the build commits its spec ----------
[ "$RC" = 0 ] && ok || bad "the spec stage must exit 0 (got $RC)"
[ -f "$T/repo/.harness/specs/TK-42/plan.md" ] \
  && ok || bad "the plan must be written to .harness/specs/<ticket>/plan.md"
[ -n "$(tracked '.harness/specs/TK-42/plan.md')" ] \
  && ok || bad "the spec must be TRACKED in git, not just left in the working tree"
diff -q "$T/build/plan.md" "$T/repo/.harness/specs/TK-42/plan.md" >/dev/null \
  && ok || bad "the committed spec must be the build's plan.md byte for byte"
[ "$(commits)" -eq $((BEFORE + 1)) ] \
  && ok || bad "exactly one commit for the spec (before=$BEFORE after=$(commits))"
grep -q 'spec(TK-42)' <<<"$(git -C "$T/repo" log -1 --format=%s)" \
  && ok || bad "the spec commit must name the ticket (got: $(git -C "$T/repo" log -1 --format=%s))"
# Same commit stream as the build: the PR diff shows spec AND code.
grep -qx '.harness/specs/TK-42/plan.md' <<<"$(git -C "$T/repo" diff --name-only main...HEAD)" \
  && ok || bad "the spec must appear in the branch's diff against the base"
grep -qx 'app.ts' <<<"$(git -C "$T/repo" diff --name-only main...HEAD)" \
  && ok || bad "the code commit must survive the spec commit"
[ -z "$(git -C "$T/repo" status --porcelain)" ] \
  && ok || bad "the stage must leave a clean tree (got: $(git -C "$T/repo" status --porcelain))"
grep -q '.harness/specs/TK-42/plan.md' "$T/SPECLINE.txt" \
  && ok || bad "SPEC_LINE must name the in-repo spec path for the PR body"

# ---------- 2. idempotence: re-runs overwrite, never duplicate ----------
# The fix round and the checkpoint-resume both re-enter this code.
MID=$(commits)
: > "$T/build/pipeline.log"
run TK-42 >/dev/null
[ "$(commits)" -eq "$MID" ] \
  && ok || bad "an unchanged plan must make NO new commit (before=$MID after=$(commits))"
# git would refuse the empty commit on its own, so "no new commit" alone does
# not prove the no-op was RECOGNISED. Without the staged-diff guard the stage
# reaches its failure branch and logs that the PR shipped without its spec —
# a false alarm on the most common path there is (every fix round re-enters
# here with an unchanged plan).
grep -q 'spec artifact unchanged' "$T/build/pipeline.log" \
  && ok || bad "an unchanged plan must be logged as unchanged (got: $(cat "$T/build/pipeline.log"))"
grep -q 'commit FAILED' "$T/build/pipeline.log" \
  && bad "a no-op re-run must not report a failed commit" || ok
[ "$(tracked '.harness/specs' | wc -l)" -eq 1 ] \
  && ok || bad "a re-run must not add a second spec file (got: $(tracked '.harness/specs' | tr '\n' ' '))"
[ -z "$(git -C "$T/repo" status --porcelain)" ] \
  && ok || bad "a no-op re-run must still leave a clean tree"

# A plan that CHANGED (repair pass, re-plan on resume) updates the same file.
printf '# Plan for TK-42 (revised)\n\nSIZE: M\n' > "$T/build/plan.md"
run TK-42 >/dev/null
[ "$(commits)" -eq $((MID + 1)) ] \
  && ok || bad "a changed plan must commit once (before=$MID after=$(commits))"
[ "$(tracked '.harness/specs' | wc -l)" -eq 1 ] \
  && ok || bad "a changed plan must overwrite the same path, not add another"
grep -q 'revised' "$T/repo/.harness/specs/TK-42/plan.md" \
  && ok || bad "the committed spec must be the CURRENT plan after a fix round"

# ---------- 3. requirements.md rides along only when it exists ----------
[ -z "$(tracked '.harness/specs/TK-42/requirements.md')" ] \
  && ok || bad "requirements.md must not be invented when the plan stage wrote none"
grep -q 'requirements' "$T/SPECLINE.txt" \
  && bad "SPEC_LINE must not claim a requirements.md that does not exist" || ok
printf '# Requirements\n\n- one thing\n' > "$T/build/requirements.md"
run TK-42 >/dev/null
[ -n "$(tracked '.harness/specs/TK-42/requirements.md')" ] \
  && ok || bad "requirements.md must be committed when the plan stage emitted one"
grep -q 'requirements.md' "$T/SPECLINE.txt" \
  && ok || bad "SPEC_LINE must mention requirements.md once it is in the tree"
rm -f "$T/build/requirements.md"

# ---------- 4. no plan, no claim ----------
# An empty plan is a model/session failure the pipeline already handles; the
# spec stage must not invent a file or tell the PR body one exists.
mkrepo
: > "$T/build/plan.md"
BEFORE=$(commits)
RC=$(run TK-42)
[ "$RC" = 0 ] && ok || bad "an empty plan must not fail the build (got $RC)"
[ "$(commits)" -eq "$BEFORE" ] && ok || bad "an empty plan must produce no commit"
[ ! -s "$T/SPECLINE.txt" ] && ok || bad "SPEC_LINE must be empty when no spec was committed"

# ---------- 4b. a refused commit never claims a spec it did not ship --------
# The realistic way this happens is a repo-side pre-commit hook. `git add` has
# already put the file in the index at that point, so anything reading the
# INDEX would advertise a spec the PR does not actually contain.
mkrepo
printf '# Plan\nSIZE: S\n' > "$T/build/plan.md"
printf '#!/bin/sh\nexit 1\n' > "$T/repo/.git/hooks/pre-commit"; chmod +x "$T/repo/.git/hooks/pre-commit"
: > "$T/build/pipeline.log"
BEFORE=$(commits)
RC=$(run TK-42)
[ "$RC" = 0 ] && ok || bad "a refused commit must not fail the build (got $RC)"
[ "$(commits)" -eq "$BEFORE" ] && ok || bad "a refused commit must leave the history alone"
[ ! -s "$T/SPECLINE.txt" ] \
  && ok || bad "the PR body must not claim a spec that was never committed (got: $(cat "$T/SPECLINE.txt"))"
grep -q 'ships WITHOUT its spec' "$T/build/pipeline.log" \
  && ok || bad "a refused spec commit must say so in the pipeline log"
rm -f "$T/repo/.git/hooks/pre-commit"

# ---------- 5. the ticket key cannot walk out of the repo ----------
# Keys come off a board; a path built from one is untrusted input.
mkrepo
printf '# Plan\nSIZE: S\n' > "$T/build/plan.md"
run '../../etc/evil' >/dev/null
[ ! -e "$T/repo/../../etc/evil" ] && ok || bad "a traversing ticket key must not escape the repo"
ESC=$(tracked '.harness/specs' | grep -c '\.\./' || true)
[ "${ESC:-0}" -eq 0 ] && ok || bad "no spec path may contain a .. segment"
[ "$(tracked '.harness/specs' | wc -l)" -ge 1 ] \
  && ok || bad "a sanitized key must still get a spec (got none)"

# ---------- 6. ORDER: the spec commit lands after the EXECUTE checkpoint ------
# The checkpoint reads `git diff $BASE...HEAD` to decide whether a resumed build
# still needs to run EXECUTE. A spec commit before it would answer "yes, this
# branch has commits" for every resume and skip the code stage entirely.
EX_LINE=$(grep -n 'end EXECUTE checkpoint' "$RB_ALL" | head -1 | cut -d: -f1)
SP_LINE=$(grep -n '^# >>> spec artifact' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$EX_LINE" ] && [ -n "$SP_LINE" ] && [ "$SP_LINE" -gt "$EX_LINE" ] \
  && ok || bad "the spec stage must sit AFTER the EXECUTE checkpoint (execute=$EX_LINE spec=$SP_LINE)"

# ---------- 7. the PR body links the spec, the review prompt skips it --------
grep -q '"\$VERIFY_LINE" "\$SPEC_LINE"' "$RB_ALL" \
  && ok || bad "the PR body must be given SPEC_LINE"
# TEST-CHANGE (BH-7970): the general review prompt text moved to prompts/stages/review.md.
grep -q 'SPEC ARTIFACT, NOT CODE' "$DIR/prompts/stages/review.md" \
  && ok || bad "the review prompt must tell the reviewer the spec is not a review target"
grep -q 'Judge the code against the spec; never judge the spec' "$DIR/prompts/stages/review.md" \
  && ok || bad "the review prompt must say which way the judging runs"
grep -q "exclude).harness/specs'" "$RB_ALL" \
  && ok || bad "the tier size heuristic must exclude the spec (a plan is not blast radius)"

# ---------- 8. the merge sweep's added-line scan ignores spec text -----------
# Run the sweep's OWN pipeline, extracted verbatim, over a diff fixture. gh is
# stubbed so the scan reads the fixture instead of GitHub.
awk '/^ *# >>> iron-law scan/{f=1;next} /^ *# <<< iron-law scan/{exit} f' \
  "$DIR/bin/merge-sweep.sh" > "$T/scan.sh"
[ -s "$T/scan.sh" ] && ok || bad "could not extract the merge-sweep scan block — markers missing?"
# The scan reads the diff through mc_pr_diff now (BH-784): one
# `gh api -i -X GET repos/o/r/pulls/1 -H "Accept: application/vnd.github.v3.diff"`
# whose answer is judged on its HTTP status line, so the stub prints a whole 200
# response whose body is the fixture. The block is sourced with the conductor lib
# that owns the read, and gh-rest.sh rides with it — without it the lib's
# fail-closed shims answer "unverifiable" and the scan skips the PR unscanned.
cp "$DIR/tests/lib/rest-emit.sh" "$T/bin/restpr"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --raw 200; cat "$FIXTURE_DIFF" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
EOF
chmod +x "$T/bin/gh" "$T/bin/restpr"
mkdir -p "$T/harness/bin/lib"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/harness/bin/lib/"
mkdir -p "$T/harness/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/harness/bin/lib/mc/"

scan() { # scan <fixture> -> the FLAGS count
  ( PATH="$T/bin:$PATH" FIXTURE_DIFF="$1" PR="https://github.com/o/r/pull/1" \
    HARNESS="$T/harness" LIB="$T/harness/bin/lib/merge-conductor-lib.sh" LOG="$T/scan.log" \
    bash -c 'set -uo pipefail; STAMP() { date -u "+%F %TZ"; }
             . "$LIB"; . "$0"; echo "${FLAGS:-x}"' "$T/scan.sh" 2>/dev/null )
}

# A spec quoting the ticket back at itself: every red flag the scan hunts for,
# all of it prose describing the fix rather than shipping the violation.
cat > "$T/spec-only.diff" <<'EOF'
diff --git a/.harness/specs/TK-42/plan.md b/.harness/specs/TK-42/plan.md
new file mode 100644
--- /dev/null
+++ b/.harness/specs/TK-42/plan.md
@@ -0,0 +1,6 @@
+# Plan for TK-42
+The client asked us to stop using window.confirm( on the delete button.
+Replace it with the shared confirm dialog component.
+The agent must resolve claude-opus-5 through the DB resolver, never inline.
+Self-fetch stays on the production domain, never VERCEL_URL.
+SIZE: S
EOF
[ "$(scan "$T/spec-only.diff")" = 0 ] \
  && ok || bad "a spec-only diff must score 0 red flags (got: $(scan "$T/spec-only.diff"))"

# The same prose, alongside a REAL violation in real code. The exclusion must
# not have blinded the scan to the thing it exists to catch.
cat > "$T/spec-plus-code.diff" <<'EOF'
diff --git a/.harness/specs/TK-42/plan.md b/.harness/specs/TK-42/plan.md
new file mode 100644
--- /dev/null
+++ b/.harness/specs/TK-42/plan.md
@@ -0,0 +1,3 @@
+# Plan for TK-42
+Stop using window.confirm( on the delete button; use the shared modal.
+SIZE: S
diff --git a/src/components/delete-button.tsx b/src/components/delete-button.tsx
--- a/src/components/delete-button.tsx
+++ b/src/components/delete-button.tsx
@@ -1,3 +1,4 @@
 export function DeleteButton() {
+  if (!window.confirm("Delete this record?")) return
   return null
 }
EOF
[ "$(scan "$T/spec-plus-code.diff")" = 1 ] \
  && ok || bad "a real violation in code must still be flagged (got: $(scan "$T/spec-plus-code.diff"))"

# And the pre-existing exclusions are untouched by the edit.
cat > "$T/test-file.diff" <<'EOF'
diff --git a/tests/dialog.test.ts b/tests/dialog.test.ts
--- a/tests/dialog.test.ts
+++ b/tests/dialog.test.ts
@@ -1,2 +1,3 @@
 it("bans native dialogs", () => {
+  expect(src).not.toContain("window.confirm(")
 })
EOF
[ "$(scan "$T/test-file.diff")" = 0 ] \
  && ok || bad "test files must still be excluded from the scan (got: $(scan "$T/test-file.diff"))"

# ---------- 9. the sweep skip is anchored on the real path -------------------
grep -q 'harness\\/specs\\/' "$DIR/bin/merge-sweep.sh" \
  && ok || bad "merge-sweep's file skip must name .harness/specs/"

echo "spec-artifact-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
