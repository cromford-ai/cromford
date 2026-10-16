#!/bin/bash
# bin/test-suite-run.sh — run every tests/*.sh and say which ones DIED.
#
# Replaces the inline `for t in tests/*.sh` loop that the `decisions` job of
# .github/workflows/harness-ci.yml used to carry. Same log, one addition: a
# suite that exited nonzero WITHOUT printing a summary line never counted
# anything, so it did not fail — it died. Those are collected and named once, at
# the end, where a reader will actually see them.
#
# The incident (2026-09-17): tests/checks-suite-test.sh sourced a tests/lib/
# file main did not have. It printed no summary, the log read as one more
# ordinary failure, and the same missing file also produced genuine FAIL lines
# in other suites — so the one line that explained the run was the hardest to
# find. bin/test-sources-lint.sh is the prevention; this is the diagnosis.
#
# Usage:  bash bin/test-suite-run.sh [--shard i/n] [--only-file <list>] [tests-dir...]
#         (dirs default: tests)
#
# More than one dir is the CI shape: the job passes `tests tests/mc` because
# CI's bash has no globstar (#929). The dirs are swept in order as one run, so
# an empty one (tests/mc carries no suite yet) is not by itself a failure —
# rc 2 is reserved for a sweep that found nothing ANYWHERE.
#
# --shard i/n runs ONE n-th of the sweep (BH-1192). The corpus took 35-45
# minutes serially and every PR in the drain waited for it, so CI now runs four
# shards in parallel and a fan-in job that keeps the old check name. The split
# itself is `suite_shard_filter` in bin/lib/suite-runner.sh and nowhere else:
# the union of the shards has to be the whole sweep, and a second copy of the
# rule is how that stops being true while four shards still read green. The
# dirs are still swept in order; the shard is picked from the sorted union of
# everything they matched, so it does not matter which dir a suite lives in.
#
# Exit codes:
#   0  every suite exited 0
#   1  at least one suite failed or died
#   2  no suites matched <tests-dir>/*.sh in any dir — a sweep over nothing is
#      not green — or a bad/empty --shard, or an --only-file that is unreadable
#      or names none of them
#
# A SUITE ERROR is classified narrowly: nonzero AND no summary line. A suite
# that ran, counted and reported failures is an ordinary FAIL and is left
# exactly as it reads today — calling it broken infrastructure would hide the
# real test failures this job exists to surface.
#
# One behaviour change from the loop: each suite's output is captured and
# printed when the suite finishes, not streamed live. A hung suite therefore
# shows nothing until the job times out; the trade is what lets a dead suite be
# classified from its own output.
#
# No errexit: one dead suite must never end the sweep. Reads CODEGRAPH_REQUIRED
# and SEMGREP_REQUIRED from the environment (CI exports them) and sets neither.
# Writes nothing to disk.
set -uo pipefail

# The split lives in the library both runners share; nothing here re-derives it.
# shellcheck source=lib/suite-runner.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/suite-runner.sh" || {
  echo "test-suite-run: cannot source bin/lib/suite-runner.sh" >&2; exit 2; }

SHARD=""
ONLY=""
DIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --only-file)
      # The impact selection (BH-1203). An unreadable or empty list is rc 2, not
      # "run everything" and not "run nothing": both of those are a CI job that
      # silently stopped doing its job, which is the failure this file exists
      # to refuse everywhere else.
      [ $# -ge 2 ] || { echo "test-suite-run: --only-file needs a path" >&2; exit 2; }
      ONLY="$2"; shift ;;
    --only-file=*) ONLY="${1#--only-file=}" ;;
    --shard)
      # An empty or missing spec is refused rather than ignored: a shard flag
      # that silently degrades to "everything" is a CI job doing four times the
      # work, and one that degrades to shard 0 is three quarters of the corpus
      # not running behind a green check.
      [ $# -ge 2 ] || { echo "test-suite-run: --shard needs a spec like 0/4" >&2; exit 2; }
      SHARD="$2"; shift ;;
    --shard=*) SHARD="${1#--shard=}" ;;
    -*) echo "test-suite-run: unknown flag $1" >&2; exit 2 ;;
    *)  DIRS+=("$1") ;;
  esac
  shift
done
[ "${#DIRS[@]}" -gt 0 ] || DIRS=(tests)

SHARD_I=""; SHARD_N=""
if [ -n "$SHARD" ]; then
  SPEC=$(suite_shard_parse "$SHARD") || exit 2
  SHARD_I=${SPEC% *}; SHARD_N=${SPEC#* }
fi

# The summary shapes this repo uses: "<name>: N pass(ed), M fail(ed)" (about 170
# suites) and "pass=N fail=M" (about 20). Either one proves the suite got to the
# end and counted, which is the whole question here.
#
# The name is NOT matched — only the counts are, either at the start of a line
# or after a "<anything>: " prefix. An earlier version anchored a name class of
# [A-Za-z0-9._/ -] and rejected four real suites: a parenthesised ticket key
# (heartbeat-reaper (BH-638): 7 passed, 1 failed; review-prs-state (BH-977)),
# a prefixed alt shape (tg-outbound-topic: pass=7 fail=1) and a bare count with
# no name (cache-hit-report: 7 pass, 1 fail). An honest failure in any of those
# printed under "these suites did not run" — the same misread as the incident,
# in the other direction.
SUMMARY_RE='(^|: )([0-9]+ pass(ed)?, [0-9]+ fail(ed)?|pass=[0-9]+ fail=[0-9]+)'
# The shapes a shell prints when a script dies rather than fails.
ERROR_RE='(: line [0-9]+: |No such file or directory|command not found|unbound variable|syntax error|Permission denied)'

SEEN=0
FAIL=0
NERR=0
ERRORS=

SUITES=()
for d in "${DIRS[@]}"; do
  for t in "$d"/*.sh; do
    [ -f "$t" ] || continue
    SUITES+=("$t")
  done
done

# The empty-sweep refusal is made BEFORE the shard is applied, so its rc and its
# wording are exactly what they were, and an empty shard gets its own message.
if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "test-suite-run: no suites under ${DIRS[*]}" >&2
  exit 2
fi

# --only-file NARROWS THE SWEEP BEFORE THE SHARD SPLIT (BH-1203), so the four
# shards divide the selection rather than each taking a quarter of the corpus
# and then dropping most of it. The count is printed, never implied: a reader of
# one shard's log has to see how much of the corpus this green covers, and the
# whole risk of an impact lane is a small run that looks like a fast one.
if [ -n "$ONLY" ]; then
  [ -r "$ONLY" ] || { echo "test-suite-run: cannot read --only-file '$ONLY'" >&2; exit 2; }
  KEPT=()
  while IFS= read -r t; do [ -n "$t" ] && KEPT+=("$t"); done \
    < <(printf '%s\n' "${SUITES[@]}" | LC_ALL=C sort | grep -xF -f "$ONLY" 2>/dev/null)
  [ "${#KEPT[@]}" -gt 0 ] \
    || { echo "test-suite-run: --only-file '$ONLY' selected none of the ${#SUITES[@]} suites under ${DIRS[*]}" >&2; exit 2; }
  echo "impact: ${#KEPT[@]} of ${#SUITES[@]} suites under ${DIRS[*]} (--only-file $ONLY)"
  SUITES=("${KEPT[@]}")
fi

if [ -n "$SHARD_N" ]; then
  PICKED=()
  while IFS= read -r t; do [ -n "$t" ] && PICKED+=("$t"); done \
    < <(suite_shard_filter "$SHARD_I" "$SHARD_N" "${SUITES[@]}")
  [ "${#PICKED[@]}" -gt 0 ] \
    || { echo "test-suite-run: shard $SHARD selected none of the ${#SUITES[@]} suites under ${DIRS[*]}" >&2; exit 2; }
  # Printed, not implied: a reader of one shard's log has to be able to see how
  # much of the corpus this green covers.
  echo "shard $SHARD_I/$SHARD_N: ${#PICKED[@]} of ${#SUITES[@]} suites under ${DIRS[*]}"
  SUITES=("${PICKED[@]}")
fi

for t in "${SUITES[@]}"; do
  SEEN=$((SEEN+1))
  echo "--- $t"
  OUT=$(bash "$t" 2>&1); RC=$?
  # Echoed unchanged, combined stream, same as the loop this replaces. The
  # -n guard is so a silent suite stays silent instead of gaining a blank line.
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  [ "$RC" -eq 0 ] && continue
  FAIL=1
  # No pipeline here: under pipefail, grep -q exiting on the match while printf
  # still has more than a pipe buffer to write turns an honest FAIL into rc 141
  # and a SUITE ERROR. A here-string has no writer to kill.
  grep -Eq "$SUMMARY_RE" <<<"$OUT" && continue

  LINE=$(grep -Em1 "$ERROR_RE" <<<"$OUT")
  [ -n "$LINE" ] || LINE=$(grep -Em1 '[^[:space:]]' <<<"$OUT")
  [ -n "$LINE" ] || LINE="exited $RC with no output"
  NERR=$((NERR+1))
  ERRORS="${ERRORS}${t}: ${LINE}"$'\n'
done

# SEEN is the count the loop actually reached; the empty cases are refused
# above, so a zero here would mean the list moved between the two and is worth
# the same rc 2 rather than a green.
if [ "$SEEN" -eq 0 ]; then
  echo "test-suite-run: no suites under ${DIRS[*]}" >&2
  exit 2
fi

if [ "$NERR" -gt 0 ]; then
  echo "SUITE ERRORS (these suites did not run, the FAIL lines above are noise):"
  printf '%s' "$ERRORS"
  exit 1
fi

exit $FAIL
