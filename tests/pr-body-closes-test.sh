#!/bin/bash
# tests/pr-body-closes-test.sh — bin/run-build.sh on an issue-driven project
# (fleet.conf board prefix "-") puts "Closes #<n>" in the PR body, so a merge
# closes the issue and the box's issue-fingerprint gate sees it move; and after
# a verified tier-1 merge CLOSE_ISSUE_AFTER_MERGE comments on + closes the
# issue explicitly. Board projects get neither. (2026-09-12: hand-merged
# project-5 PRs closed no issue and the tick said "gate no-change" all day.)
# The evidence block is extracted VERBATIM by its markers, as
# tests/evidence-block-test.sh does, and driven with the same variable set.
# Run from anywhere: tests/pr-body-closes-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
mkdir -p "$T/bin/lib" "$T/build" "$T/fakebin" "$T/repo"
# (BH-781) CLOSE_ISSUE_AFTER_MERGE's fallback pair writes through
# bin/lib/gh-rest.sh, which bin/run-build.sh sources at the top.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T" >/dev/null || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
[ -s "$T/block.sh" ] && grep -q CLOSES_LINE "$T/block.sh" && ok || bad "could not extract the evidence block with CLOSES_LINE — markers moved?"
awk '/^# >>> merge note fn/{f=1;next} /^# <<< merge note fn/{exit} f' "$RB_ALL" > "$T/mergenote.sh"
( cd "$T/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "TK-269: the subject" ) >/dev/null 2>&1
cat > "$T/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "${2:-}" = board_prefix ] && cat "$T/prefix"
SH
chmod +x "$T/bin/fleet-conf.sh"
# The stub answers in the wire shape bin/lib/gh-rest.sh reads: a status line, a
# blank line, then the body. The PATCH is followed by a VERIFYING RE-READ, so
# the GET has to agree the issue is closed or gh_rest_close returns 75.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
if [ "${GH_RC:-0}" != 0 ]; then
  printf 'HTTP/2.0 403 Forbidden\nx-stub: 1\n\n{"message":"refused"}\n'; exit "${GH_RC:-0}"
fi
case "$*" in
  *"-X POST"*comments*) printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
  *"-X PATCH"*)         printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
  *"-X GET"*)           printf 'HTTP/2.0 200 OK\nx-stub: 1\n\n{"state":"closed"}\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"

drive() { # drive <prefix> <key> [env...]
  local prefix="$1" key="$2"; shift 2
  echo "$prefix" > "$T/prefix"; : > "$T/gh.txt"; : > "$T/build/pipeline.log"; : > "$T/body.txt"
  ( cd "$T/repo" || exit 1
    env PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" BUILD="$T/build" GH_SINK="$T/gh.txt" KEY="$key" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=ts; SLUG=o/r; BASE=main; TIER=1; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="because"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$HARNESS/bin/lib/gh-rest.sh"
      . "$0"; . "$1"
      printf "%s" "$(PR_BODY_FOR "$EVIDENCE_SECTION")" > "$2"
      CLOSE_ISSUE_AFTER_MERGE https://github.com/o/r/pull/7
    ' "$T/mergenote.sh" "$T/block.sh" "$T/body.txt" 2>"$T/err.txt" )
}

# 1. issue-driven project, numeric key: the body carries "Closes #269" right under the ticket line
drive "-" TK-269
grep -qx "Closes #269" "$T/body.txt" && ok || bad "no Closes line: $(head -4 "$T/body.txt") err=$(cat "$T/err.txt")"
[ "$(sed -n 2p "$T/body.txt")" = "Closes #269" ] && ok || bad "Closes line is not the second line: $(head -3 "$T/body.txt")"
grep -q "^## What" "$T/body.txt" && ok || bad "the What section vanished"
# ...and the explicit close after a verified merge: comment, then close, then a log line
grep -q -- "-X POST repos/o/r/issues/269/comments" "$T/gh.txt" \
  && grep -q -- "-X PATCH repos/o/r/issues/269" "$T/gh.txt" \
  && grep -q -- "-X GET repos/o/r/issues/269" "$T/gh.txt" \
  && grep -q "closed issue #269 after merge" "$T/build/pipeline.log" \
  && ok || bad "issue not commented+closed: gh=$(cat "$T/gh.txt") log=$(cat "$T/build/pipeline.log")"
# 2. gh refuses: one honest log line, never a failed build
drive "-" TK-269 GH_RC=1
grep -q "issue #269 could not be commented/closed — bin/reconcile-prs.sh re-reads merged PRs" "$T/build/pipeline.log" && ok || bad "a failed close must be logged, naming the lane that retries it: $(cat "$T/build/pipeline.log")"
# 3. board project: no Closes line, no issue calls, body otherwise identical in shape
drive "/api/board" TK-12
grep -q "Closes" "$T/body.txt" && bad "a board project got a Closes line" || ok
[ ! -s "$T/gh.txt" ] && ok || bad "a board project called gh issue: $(cat "$T/gh.txt")"
[ "$(sed -n 2p "$T/body.txt")" = "" ] && [ "$(sed -n 3p "$T/body.txt")" = "## What" ] && ok || bad "board body shape moved: $(head -3 "$T/body.txt")"
# 4. no fleet-conf.sh at all (an old box): fail-open, no line
drive "-" TK-269 HARNESS="$T/nowhere"
grep -q "Closes" "$T/body.txt" && bad "Closes line without a registry answer" || ok

echo "pr-body-closes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
