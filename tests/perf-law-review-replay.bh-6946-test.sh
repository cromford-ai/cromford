#!/bin/bash
# tests/perf-law-review-replay.bh-6946-test.sh — BH-6946: a review that carries
# the performance-by-default law blocks a sequential await over independent
# loaders.
#
#   O1  the fixture tests/fixtures/perf-law-replay.bh-6946/department-page.diff
#       applies to the file its - side describes, and its + side awaits the five
#       loaders one at a time inside a for loop
#   O2  the replay prompt carries the review text R, read from the general
#       review line of bin/lib/rb/review.sh (not a copy kept in this test)
#   LIVE (only with PERF_LAW_REPLAY=1): one metered review call through
#       bin/agent-call.sh; the answer ends VERDICT: BLOCK and has a [BLOCK] line
#       that names the sequential await. The model comes from REVIEW_MODEL.
#       agent-call rc 74..79 means nothing was called: the suite prints
#       NOT RUN with the rc and exits 0. That is a skip, never a pass.
# Offline (CI): HARNESS_TEST_SANDBOX=1 bash tests/perf-law-review-replay.bh-6946-test.sh
# Live, once by hand: PERF_LAW_REPLAY=1 REVIEW_MODEL=<model> HARNESS_TEST_SANDBOX=1 bash tests/perf-law-review-replay.bh-6946-test.sh
# perf-law-review-replay (BH-6946, re-sided by BH-7123): the review prompt's
# performance law, replayed against a fixture diff that turns a Promise.all into
# a sequential for-await. Under the REVIEW LEVELS rule a sequential await is a
# [NOTE], not a BLOCK (a BLOCK needs a measured regression over the thresholds
# or a perf ticket), so the live replay (PERF_LAW_REPLAY=1) expects VERDICT:
# APPROVE with a [NOTE] line that names the sequential await.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FX="$DIR/tests/fixtures/perf-law-replay.bh-6946/department-page.diff"
PAGE='src/app/os/departments/[slug]/(overview)/page.tsx'

# ── O1 the fixture is a real diff with a sequential await loop ───────────────
[ -s "$FX" ] && ok || bad "O1 fixture missing: $FX"
A="$T/apply"; mkdir -p "$A/$(dirname "$PAGE")"; git -C "$A" init -q
# The - side of the hunk is the pre-image: context lines plus removed lines.
sed -n '/^@@/,$p' "$FX" | sed 1d | grep -E '^[ -]' | cut -c2- > "$A/$PAGE"
git -C "$A" apply --check "$FX" 2>"$T/apply.err" && ok || bad "O1 the fixture does not apply to its own pre-image: $(head -c 200 "$T/apply.err")"
git -C "$A" apply "$FX" 2>/dev/null
post="$A/$PAGE"
grep -qE '^[[:space:]]*for \(const load of loaders\)' "$post" && ok || bad "O1 the post-image has no for loop over the loaders"
awk '/for \(const load of loaders\)/{f=1} f&&/await load\(\)/{print; exit}' "$post" | grep -q 'await' && ok || bad "O1 the for loop does not await each loader"
grep -q 'Promise.all' "$post" && bad "O1 the post-image still has Promise.all" || ok
for l in departmentSampleTools loadWorkspace departmentFacts listAddedBlocks connectNotReady; do
  grep -q "$l(slug)" "$post" && ok || bad "O1 the post-image does not load $l"
done

# ── O2 the replay prompt carries R from the real review prompt ───────────────
# TEST-CHANGE (BH-7970): the general review line moved from bin/lib/rb/review.sh to prompts/stages/review.md.
R=$(grep -E '^Adversarially review the diff of branch' "$DIR/prompts/stages/review.md" \
      | grep -oE 'PERFORMANCE BY DEFAULT \(BH-6946\), each one a \[NOTE\] \(a BLOCK only [^)]*\):.*before its first content\.')
[ -n "$R" ] && ok || bad "O2 the general review line of prompts/stages/review.md carries no performance law"
PROMPT="Review this diff of a Next.js server page against these rules. $R

$(cat "$FX")

Write findings, one per line, each starting [BLOCK] or [NOTE]. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."
grep -qF -- "sequential await over independent reads" <<<"$PROMPT" && ok || bad "O2 the replay prompt lacks R"
grep -qF -- "for (const load of loaders)" <<<"$PROMPT" && ok || bad "O2 the replay prompt lacks the fixture diff"

# ── LIVE one replayed review ──────────────────────────────────────────────────
if [ "${PERF_LAW_REPLAY:-}" = 1 ]; then
  "$DIR/bin/agent-call.sh" review cromford "${REVIEW_MODEL:?set REVIEW_MODEL}" 600 "$T/out.txt" "$PROMPT"; rc=$?
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
    echo "NOT RUN: agent-call rc $rc (nothing was called): $(head -1 "$T/out.txt" 2>/dev/null)"
  elif [ "$rc" != 0 ]; then
    bad "LIVE agent-call failed rc $rc: $(head -c 300 "$T/out.txt" 2>/dev/null)"
  else
    echo "--- live review output"; cat "$T/out.txt"; echo "---"
    last=$(grep -v '^[[:space:]]*$' "$T/out.txt" | tail -1)
    [ "$last" = "VERDICT: APPROVE" ] && ok || bad "LIVE last line is '$last', not VERDICT: APPROVE (a sequential await is a [NOTE] under the REVIEW LEVELS rule, BH-7123)"
    grep -E '^\[NOTE\]' "$T/out.txt" | grep -qiE 'sequential|in sequence|await' && ok || bad "LIVE no [NOTE] line names the sequential await"
    grep -qE '^\[BLOCK' "$T/out.txt" && bad "LIVE a [BLOCK] line on a diff with no ALWAYS-BLOCK class" || ok
  fi
else
  echo "SKIP live replay (set PERF_LAW_REPLAY=1)"
fi

echo "perf-law-review-replay.bh-6946: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
