#!/bin/bash
# tests/size-gate-mentions-test.sh — the file axis of the size gate is the plan's
# DECLARED edit set, never the set of paths the plan happens to MENTION.
#
# WHY (BH-612, 2026-09-16). bin/planned-files.sh is a deliberate OVER-listing:
# its own header says over-listing "only costs a serialization, under-listing
# costs a conflict; prefer the former". It scrapes every repo-relative path
# token out of plan.md — the files to touch, the callers the planner read, the
# "## Out of scope" list, the "do NOT edit src/x.ts" line. That superset is the
# right input for bin/conflict-check.sh and the claims ledger, and it was also
# being fed to the size gate's file axis, where it is wrong.
#
# What that cost, on one night: project-5 #1906 declared `files=2 lines=45` and
# was DECOMPOSED into TK-1921/TK-1922 because its prose mentioned 18 paths;
# #1907 declared `files=2 lines=140` and was DECOMPOSED into TK-1919/TK-1920 on
# 16 mentions. Two trivial fixes turned into four tickets, four plans and four
# reviews. #1912, which honestly declared `files=17 lines=780`, still split —
# and still must.
#
# So: the DECLARED FILES gates. The superset is printed for the ledger
# (`SIZE_FILES_PLANNED:`) and, when it is over the tolerated file limit, named
# as `SIZE_FILES_MENTIONED: n (not gating)` so a reviewer can still see that the
# plan touched a lot of prose. A declaration that UNDER-counts is caught after
# execute, against the diff that actually shipped, by bin/evidence-summary.sh's
# `SIZE_DECLARATION_EXCEEDED` row (tests/evidence-block-test.sh pins that half).
#
# WHAT IS UNDER TEST, and why it is driven rather than grepped. Every case below
# runs the REAL bin/size-gate.sh, on a planned-files.txt produced by the REAL
# bin/planned-files.sh from a plan body shaped like the ones this box writes
# (a files-to-touch list, a callers list, an out-of-scope list, a do-NOT-edit
# line, plus test and doc paths that must not count). The conflict fixture runs
# the REAL bin/conflict-check.sh against a scratch $HARNESS, so the same file
# list is shown serializing a sibling AND not gating the size.
#
# No network, no model call, no secrets, no clock read, and nothing here touches
# a real box. Run from anywhere:
#   tests/size-gate-mentions-test.sh      (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

GATE="$DIR/bin/size-gate.sh"
PF="$DIR/bin/planned-files.sh"
CC="$DIR/bin/conflict-check.sh"
for S in "$GATE" "$PF" "$CC"; do
  [ -x "$S" ] && ok || bad "$(basename "$S") is missing or not executable"
done

# A build dir holding a plan.md, with the mention superset extracted from it by
# the production script — never a hand-written list, because the list's SHAPE
# (what planned-files.sh does and does not scrape) is half of what is wrong here.
mkbuild() { # mkbuild <name> <plan-body>
  local b="$T/$1"
  scratch_rm "$b"; mkdir -p "$b"
  printf '%s\n' "$2" > "$b/plan.md"
  "$PF" "$b" >/dev/null 2>&1
  printf '%s' "$b"
}
# The real shape of a plan that declares two files and names eighteen: the two
# it edits, the ten callers it read, the five it lists as out of scope, and the
# one it warns the builder off. Plus a test file and a doc, which are mentions
# too and must stay out of every count (size-scope owns that list).
MENTIONS_18=$(
  echo '# Ticket — one narrow fix'
  echo
  echo '## Files to touch (product)'
  echo '- `src/lib/gate.ts` — the verdict block'
  echo '- `src/lib/scope.ts` — one exported constant'
  echo
  echo '## Callers I read (graph evidence)'
  for i in 1 2 3 4 5 6 7 8 9 10; do echo "- src/api/route$i.ts calls gate()"; done
  echo
  echo '## Out of scope'
  for i in 1 2 3 4 5; do echo "- src/legacy/old$i.ts keeps its own copy"; done
  echo
  echo 'Do NOT edit src/shared/danger.ts — a sibling build owns it.'
  echo
  echo 'Tests / docs (not counted): tests/gate-test.sh, docs/GRAPH.md'
  echo
  echo '### Task 1 — fix it'
  echo '- VALIDATE: tests/gate-test.sh'
  echo '- SATISFIES: the ticket'
  echo
  echo '## Size'
  echo 'FILES: 2'
  echo 'LINES: 45'
  echo
  echo 'KIND: bug'
  echo 'SIZE: S'
)

# ============================================================================
# 1. THE REPRODUCTION (BH-612). files=2 lines=45, eighteen paths mentioned.
# ============================================================================
B=$(mkbuild b-a "$MENTIONS_18")
G=$("$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok \
  || bad "a 45-line, 2-file plan that MENTIONS 18 paths must exit 0 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" \
  && ok || bad "the declared edit set is 2 files — the verdict must be 'within': $G"
grep -q '^SIZE_DECLARED: files=2 lines=45$' <<<"$G" \
  && ok || bad "the declaration must be on the record verbatim: $G"
# The superset is still COUNTED and still on the ledger — the ticket removed its
# authority, not its visibility. 18 product paths out of 20 mentions: the test
# file and the doc are excluded by bin/size-scope.sh, the same list section 1 of
# tests/size-gate-test.sh pins.
grep -q '^SIZE_FILES_PLANNED: 18$' <<<"$G" \
  && ok || bad "the mention superset must still be counted and printed: $G"
grep -q '^SIZE_FILES_MENTIONED: 18 (not gating)$' <<<"$G" \
  && ok || bad "a superset over the tolerated file limit must be NAMED as not gating: $G"
# ...and it must never turn into a verdict about the size.
grep -q 'plan file list' <<<"$G" \
  && bad "the superset still produced a SIZE_OVER/SIZE_TOLERATED line: $G" || ok
grep -q '^SIZE_OVER:' <<<"$G" \
  && bad "a plan inside both declared limits must print no SIZE_OVER line: $G" || ok

# ============================================================================
# 2. AN HONEST OVER-DECLARATION STILL SPLITS (the #1912 shape)
# ============================================================================
# The gate did not get quieter, it got right. A plan that says 17 files and 780
# lines is over on both axes and is handed to the decomposer exactly as before.
B=$(mkbuild b-b "$(printf '%s\n' '# Ticket' '' '### Task 1' '- VALIDATE: x' '- SATISFIES: y' '' '## Size' 'FILES: 17' 'LINES: 780' '' 'KIND: feature' 'SIZE: L')")
G=$("$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "files=17 lines=780 must still exit 2 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: over$' <<<"$G" && ok || bad "the #1912 shape must still be 'over': $G"
grep -q '^SIZE_OVER: lines=780>300; files=17>12$' <<<"$G" \
  && ok || bad "SIZE_OVER must still name both axes against the NOMINAL limits: $G"

# ============================================================================
# 3. THE TOLERANCE BAND IS JUDGED ON THE DECLARATION TOO
# ============================================================================
# files=13 against 12 is inside the 15% band, so it builds whole with the
# overshoot named — and the 30 paths the plan mentions change nothing except one
# informational line.
THIRTY=$(
  echo '# Ticket'
  echo
  echo '## Out of scope — files this change reads but does not edit'
  for i in $(seq 1 30); do echo "- src/lib/mod$i.ts"; done
  echo
  echo '### Task 1'
  echo '- VALIDATE: x'
  echo '- SATISFIES: y'
  echo
  echo '## Size'
  echo 'FILES: 13'
  echo 'LINES: 200'
  echo
  echo 'KIND: feature'
  echo 'SIZE: M'
)
B=$(mkbuild b-c "$THIRTY")
G=$("$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "files=13 inside the 15% band must build whole (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "a tolerated plan is 'within': $G"
grep -q '^SIZE_TOLERATED: files=13>12 (within the 15% band, building whole)$' <<<"$G" \
  && ok || bad "the declared overshoot must still be named on the record: $G"
grep -q '^SIZE_FILES_MENTIONED: 30 (not gating)$' <<<"$G" \
  && ok || bad "30 mentioned paths must be reported as not gating: $G"
grep -q 'plan file list' <<<"$G" \
  && bad "30 mentions must not reach SIZE_OVER/SIZE_TOLERATED: $G" || ok

# ============================================================================
# 4. NO DECLARATION: ESTIMATED FROM THE SUPERSET, SPLIT ONLY PAST 2x
# ============================================================================
# TEST-CHANGE BH-5292: this block pinned the undeclared output byte for byte
# (exit 3, the PLAN_MALFORMED input). the operator changed the rule (2026-10-07): a
# missing `## Size` is a warning, and the superset this file is about becomes
# the ESTIMATE's input. What it still guards: the superset never decides a
# declared plan (sections 1-3), and as an estimate it only splits past 2x the
# nominal limit, because it over-lists by construction (BH-612).
TWENTY=$(
  echo '# Ticket with no size section'
  echo
  for i in $(seq 1 20); do echo "- src/lib/thing$i.ts"; done
  echo
  echo '### Task 1'
  echo '- VALIDATE: x'
  echo '- SATISFIES: y'
  echo
  echo 'KIND: feature'
  echo 'SIZE: M'
)
B=$(mkbuild b-d "$TWENTY")
"$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" > "$T/d.out" 2>&1; GRC=$?
[ "$GRC" = 0 ] && ok || bad "20 mentions against a 12-file limit (under 2x) must proceed (rc=$GRC): $(cat "$T/d.out")"
# TEST-CHANGE (BH-8739): the gate prints SIZE_SLICES_EXPECTED (ceil(500/300) = 2)
# after SIZE_LIMITS on the estimated path; still byte for byte otherwise.
cat > "$T/d.expected" <<'EXP'
SIZE_GATE_WARNING: the plan carries no '## Size' section with both FILES: and LINES: — size estimated from its file list, building on
SIZE_ESTIMATED: files=20 lines=500 (from the plan's file list, 20 product file(s); lines = files x 300/12)
SIZE_LIMITS: lines=300 files=12
SIZE_SLICES_EXPECTED: 2
SIZE_VERDICT: estimated
EXP
if diff -u "$T/d.expected" "$T/d.out" >"$T/d.diff" 2>&1; then ok
else bad "the estimated output is not what was pinned: $(cat "$T/d.diff")"; fi
[ "$(grep -c . "$B/planned-files.txt")" -ge 20 ] \
  && ok || bad "the fixture is not exercising a big superset: $(cat "$B/planned-files.txt")"

# ============================================================================
# 5. SIZE_GATE_TOLERANCE_PCT=0 KEEPS THE DECLARED-SET RULE
# ============================================================================
# Turning the band off makes the gate stricter about the DECLARATION. It must not
# hand the file axis back to the superset.
B=$(mkbuild b-e "$(printf '%s\n' '# Ticket' '' '## Size' 'FILES: 13' 'LINES: 100' '' '### Task 1' '- VALIDATE: x' '- SATISFIES: y' '' 'KIND: feature' 'SIZE: M')")
G=$(SIZE_GATE_TOLERANCE_PCT=0 "$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "tolerance 0 and files=13 declared must exit 2 (rc=$GRC: $G)"
grep -q '^SIZE_OVER: files=13>12$' <<<"$G" \
  && ok || bad "with the band off the declared file count must trip the gate: $G"
# ...and a plan that declares exactly the limit is within, however much prose it
# carries. Forty mentions, tolerance off, twelve declared files: within.
FORTY=$(
  echo '# Ticket'
  echo
  echo '## Callers'
  for i in $(seq 1 40); do echo "- src/api/h$i.ts"; done
  echo
  echo '## Size'
  echo 'FILES: 12'
  echo 'LINES: 100'
  echo
  echo '### Task 1'
  echo '- VALIDATE: x'
  echo '- SATISFIES: y'
  echo
  echo 'KIND: feature'
  echo 'SIZE: M'
)
B=$(mkbuild b-e2 "$FORTY")
G=$(SIZE_GATE_TOLERANCE_PCT=0 "$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "tolerance 0, files=12 declared, 40 mentioned must exit 0 (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "12 declared against 12 is within: $G"
grep -q '^SIZE_FILES_MENTIONED: 40 (not gating)$' <<<"$G" \
  && ok || bad "with the band off the line fires above the nominal limit: $G"

# ============================================================================
# 6. THE INFORMATIONAL LINE IS BOUNDED AND ABSENT WHEN IT HAS NOTHING TO SAY
# ============================================================================
# A note on every build is a note nobody reads, so it appears only ABOVE the
# tolerated limit (13 files with 12/15%) — strictly greater, never at it.
SMALLSET() { # SMALLSET <n>
  echo '# Ticket'
  echo
  for i in $(seq 1 "$1"); do echo "- src/lib/m$i.ts"; done
  echo
  echo '## Size'
  echo 'FILES: 2'
  echo 'LINES: 40'
  echo
  echo '### Task 1'
  echo '- VALIDATE: x'
  echo '- SATISFIES: y'
  echo
  echo 'KIND: feature'
  echo 'SIZE: S'
}
B=$(mkbuild b-f13 "$(SMALLSET 13)")
[ "$(grep -c . "$B/planned-files.txt")" = 13 ] \
  && ok || bad "fixture drift: expected 13 mentioned paths, got $(grep -c . "$B/planned-files.txt")"
G=$("$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1)
grep -q '^SIZE_FILES_MENTIONED:' <<<"$G" \
  && bad "a superset exactly AT the tolerated limit must stay quiet: $G" || ok
grep -q '^SIZE_FILES_PLANNED: 13$' <<<"$G" \
  && ok || bad "the count itself is always on the record: $G"
B=$(mkbuild b-f14 "$(SMALLSET 14)")
G=$("$GATE" "$B/plan.md" 300 12 "$B/planned-files.txt" 2>&1)
grep -q '^SIZE_FILES_MENTIONED: 14 (not gating)$' <<<"$G" \
  && ok || bad "one path past the tolerated limit must fire the line: $G"
# No list at all is not evidence of anything, and must add no line.
B=$(mkbuild b-f0 "$(SMALLSET 2)")
G=$("$GATE" "$B/plan.md" 300 12 "$T/no-such-list.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "an absent planned-files.txt must not change the verdict (rc=$GRC: $G)"
grep -qE '^SIZE_FILES_(PLANNED|MENTIONED):' <<<"$G" \
  && bad "an absent list must produce neither count line: $G" || ok

# ============================================================================
# 7. THE SAME LIST STILL SERIALIZES A SIBLING (the superset's real job)
# ============================================================================
# This is the half the ticket deliberately did NOT change. Two builds whose plans
# only MENTION src/lib/shared.ts — in an out-of-scope line, neither one editing
# it — must still refuse to run concurrently, because a mention is cheap evidence
# that they might collide and a serialization is cheaper than a conflict.
mkdir -p "$T/h/builds"
sibling() { # sibling <dir-name> <own-edit-file>
  local d="$T/h/builds/$1"
  mkdir -p "$d"
  { echo '# Ticket'
    echo
    echo "## Files to touch"
    echo "- $2"
    echo
    echo 'Out of scope: do NOT edit src/lib/shared.ts — it is shared.'
    echo
    echo '### Task 1'
    echo '- VALIDATE: x'
    echo '- SATISFIES: y'
    echo
    echo '## Size'
    echo 'FILES: 1'
    echo 'LINES: 20'
    echo
    echo 'KIND: feature'
    echo 'SIZE: S'; } > "$d/plan.md"
  "$PF" "$d" >/dev/null 2>&1
  printf '%s' "$d"
}
# WD-1 is RUNNING: a fresh build dir with no RESULT file, which is exactly what
# conflict-check.sh's 4h mtime window means by running.
S1=$(sibling widget-os-WD-1-x src/lib/one.ts)
S2=$(sibling widget-os-WD-2-x src/lib/two.ts)
grep -q '^src/lib/shared.ts$' "$S1/planned-files.txt" \
  && ok || bad "planned-files.sh stopped scraping the out-of-scope mention: $(cat "$S1/planned-files.txt")"
CONF=$(HARNESS="$T/h" "$CC" widget-os "$S2" 2>&1); CRC=$?
[ "$CRC" = 1 ] && ok || bad "two plans that only MENTION the same file must still conflict (rc=$CRC: $CONF)"
[ "$CONF" = "CONFLICT with widget-os-WD-1-x: src/lib/shared.ts ~ src/lib/shared.ts" ] \
  && ok || bad "the conflict reason must name the sibling and the shared path: $CONF"
# ...and the very same list, on the very same build, does not gate its size.
G=$("$GATE" "$S2/plan.md" 300 12 "$S2/planned-files.txt" 2>&1); GRC=$?
[ "$GRC" = 0 ] && ok || bad "the serializing list must not also gate the size (rc=$GRC: $G)"
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "a 1-file plan is within: $G"
# A finished sibling is not a sibling: the RESULT skip is untouched.
printf 'PR_CREATED https://example/1\n' > "$S1/RESULT"
HARNESS="$T/h" "$CC" widget-os "$S2" >/dev/null 2>&1 \
  && ok || bad "a sibling that already wrote RESULT must not block the candidate"
rm -f "$S1/RESULT"
# A candidate with no plan data cannot be judged and is allowed through, as before.
mkdir -p "$T/h/builds/widget-os-WD-3-x"
HARNESS="$T/h" "$CC" widget-os "$T/h/builds/widget-os-WD-3-x" >/dev/null 2>&1 \
  && ok || bad "a candidate with no planned-files.txt must still be allowed through"

echo "size-gate-mentions-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
