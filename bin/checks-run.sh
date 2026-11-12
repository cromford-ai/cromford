#!/bin/bash
# bin/checks-run.sh — run the mined checks in checks/ over a unified diff.
#
# THE POINT. The rule miner has two lanes: prose rules into
# prompts/build-discipline.md (soft tier — a model can forget every one) and
# drafted guardrails promoted into PROJECT repos by bin/guardrail-promote.sh
# (strong tier, but it lands only after a whole adoption build). Neither one
# runs on the harness side, which is why a review-finding family can recur
# seven times across four projects and still be re-litigated by a paid model on
# the eighth. checks/ is the third lane: deterministic checks the HARNESS runs
# itself, on every diff it is about to review or merge, in milliseconds.
#
# DETECTION ONLY, BY CONSTRUCTION. This runner reads a diff and writes to
# stdout. It has no git write, no gh call, no edit path, and no argument that
# could add one. A hit parks a PR for adjudication by bin/blocked-resolver.sh
# (via bin/merge-sweep.sh and the merge conductor) and rides
# into the review prompt as evidence (bin/run-build.sh). Nothing here fixes,
# reverts, closes, or merges anything.
#
# Usage:  checks-run.sh <diff-file>     a unified diff (git diff / gh pr diff)
#         checks-run.sh -               the same, on stdin
#         checks-run.sh --tree <root>   a whole checkout, for the checks that can
#                                       read one (see "Tree mode" below)
# Env:    CHECKS_DIR   override the catalog directory (default: ../checks)
#
# Output: one "CHECK-HIT <slug> <path>:<line> <reason>" line per hit, then one
#         "CHECK-NOTE <slug> <path>:<line> <reason>" line per note (diff mode: a
#         check line "NOTE<TAB>path:line<TAB>reason", a skip its own
#         exclusions.tsv decided), then one summary line —
#         "CHECKS: clean (<n> check(s), <m> added line(s))" or
#         "CHECKS: <n> hit(s) — <slug>(xN) ...", each with
#         " — <k> note(s): <slug>(xN) ..." appended when k > 0.
# rc 0 = clean (notes do not count), 1 = at least one hit, 2 = could not run
#        (say so, never silently pass: a check that did not run must not read
#        as a check that passed).
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
CHECKS_DIR="${CHECKS_DIR:-$SELF/../checks}"

# ── Tree mode ───────────────────────────────────────────────────────────────
# A diff cannot answer "is anything in this checkout dangerous?", only "did this
# PR add something dangerous?" — and the exclusion set above drops every tests/
# path before a check sees it, so a whole class of rule can never fire in diff
# mode at all. Tree mode is the complete pass: it hands a ROOT to the checks
# that can read one and lets them walk the files themselves.
#
# A check is tree-capable iff its directory ships fixtures/tree-bad/ — the same
# "prove it on a fixture" contract the catalog already has for violation.diff.
# A stdin-only check is never handed --tree: it would read an empty stream, find
# nothing, and report a pass it never earned.
#
# rc 0 = clean, 1 = hits, 2 = could not run — and "could not run" covers a check
# that crashed AND a catalog with nothing tree-capable in it, because a scan
# that did not happen must never read as a tree with nothing to find.
if [ "${1:-}" = "--tree" ]; then
  ROOT="${2:-}"
  if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
    echo "CHECKS: could not run — no such tree '$ROOT'"
    exit 2
  fi
  if [ ! -d "$CHECKS_DIR" ]; then
    echo "CHECKS: could not run — no catalog at $CHECKS_DIR"
    exit 2
  fi
  TT=$(mktemp -d) || { echo "CHECKS: could not run — mktemp failed"; exit 2; }
  trap 'rm -rf "$TT"' EXIT
  NTREE=0; TOTAL=0; SUMMARY=""; ERRORS=0
  for C in "$CHECKS_DIR"/*/check.sh; do
    [ -x "$C" ] || continue
    CDIR=$(dirname "$C")
    [ -d "$CDIR/fixtures/tree-bad" ] || continue
    SLUG=$(basename "$CDIR")
    NTREE=$((NTREE + 1))
    OUT=$("$C" --tree "$ROOT" </dev/null 2>"$TT/err"); RC=$?
    if [ "$RC" -gt 1 ]; then
      echo "CHECK-ERROR $SLUG rc=$RC $(head -c 200 "$TT/err" | tr '\n' ' ')"
      ERRORS=$((ERRORS + 1))
      continue
    fi
    [ -n "$OUT" ] || continue
    N=$(printf '%s\n' "$OUT" | grep -c . )
    TOTAL=$((TOTAL + N))
    SUMMARY="$SUMMARY $SLUG(x$N)"
    printf '%s\n' "$OUT" | while IFS=$'\t' read -r LOC REASON; do
      echo "CHECK-HIT $SLUG $LOC $REASON"
    done
  done
  if [ "$TOTAL" -gt 0 ]; then
    echo "CHECKS: $TOTAL hit(s) —$SUMMARY"
    exit 1
  fi
  if [ "$ERRORS" -gt 0 ]; then
    echo "CHECKS: could not run — a tree check crashed"
    exit 2
  fi
  if [ "$NTREE" -eq 0 ]; then
    echo "CHECKS: could not run — no tree-capable check in $CHECKS_DIR"
    exit 2
  fi
  echo "CHECKS: clean ($NTREE tree check(s), root $ROOT)"
  exit 0
fi

SRC="${1:--}"
if [ "$SRC" = "-" ]; then SRC=/dev/stdin; fi
if [ "$SRC" != "/dev/stdin" ] && [ ! -r "$SRC" ]; then
  echo "CHECKS: could not run — no readable diff at '$SRC'"
  exit 2
fi
if [ ! -d "$CHECKS_DIR" ]; then
  echo "CHECKS: could not run — no catalog at $CHECKS_DIR"
  exit 2
fi

T=$(mktemp -d) || { echo "CHECKS: could not run — mktemp failed"; exit 2; }
trap 'rm -rf "$T"' EXIT

# ── Normalization: the diff becomes one TAB-separated record per ADDED line,
# "<path>\t<line-in-new-file>\t<text>", and every check reads that stream. Doing
# it once here is what keeps each check five lines long, and it means the
# exclusions below are decided in ONE place instead of drifting per check.
#
# The exclusion set is bin/merge-sweep.sh's, deliberately: test and mock files
# (they assert against these very patterns), scripts/migrations/ (seed rows ARE
# the DB-driven pattern), .harness/specs/ (ticket prose, not code), and the
# fixture directories under checks/ and guardrails/ (a seeded violation is the
# proof a check works, not a violation). Comment-only added lines are excluded
# for the same reason merge-sweep excludes them: a doc comment citing a law is
# compliance, not a breach.
awk '
  /^\+\+\+ /{
    p=$2; sub(/^b\//,"",p)
    skip = (p=="/dev/null") \
      || (p ~ /\.(test|spec)\.[a-zA-Z]+$/) \
      || (p ~ /__tests__\//) || (p ~ /__mocks__\//) \
      || (p ~ /(^|\/)tests?\//) \
      || (p ~ /scripts\/migrations\//) \
      || (p ~ /\.harness\/specs\//) \
      || (p ~ /(checks|guardrails)\/[^\/]+\/fixtures\//)
    next
  }
  /^@@ /{
    # @@ -a,b +c,d @@ — c is the first line number of the new-file hunk.
    n=$3; sub(/^[+]/,"",n); sub(/,.*$/,"",n); cur=n+0
    next
  }
  /^\+/{
    if (!skip) {
      t=substr($0,2)
      if (t !~ /^[[:space:]]*(\/\/|\*|\/\*|#|--|<!--)/) printf "%s\t%d\t%s\n", p, cur, t
    }
    cur++
    next
  }
  /^-/{ next }
  /^ /{ cur++ }
' "$SRC" > "$T/added.tsv"

NLINES=$(wc -l < "$T/added.tsv" | tr -d ' ')
NCHECKS=0; TOTAL=0; SUMMARY=""; NTOTAL=0; NSUMMARY=""
for C in "$CHECKS_DIR"/*/check.sh; do
  [ -x "$C" ] || continue
  SLUG=$(basename "$(dirname "$C")")
  NCHECKS=$((NCHECKS + 1))
  OUT=$("$C" < "$T/added.tsv" 2>"$T/err"); RC=$?
  if [ "$RC" -gt 1 ]; then
    # A crashed check is reported, never swallowed — see the rc-2 note above.
    echo "CHECK-ERROR $SLUG rc=$RC $(head -c 200 "$T/err" | tr '\n' ' ')"
    continue
  fi
  [ -n "$OUT" ] || continue
  # A line whose first TAB field is NOTE is a skip the check's own
  # exclusions.tsv decided. It is shown, never counted: only hits park a PR.
  NOTES=$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "NOTE"')
  HITS=$(printf '%s\n' "$OUT" | awk -F'\t' 'length($0) && $1 != "NOTE"')
  if [ -n "$NOTES" ]; then
    K=$(printf '%s\n' "$NOTES" | grep -c . )
    NTOTAL=$((NTOTAL + K))
    NSUMMARY="$NSUMMARY $SLUG(x$K)"
    printf '%s\n' "$NOTES" | while IFS=$'\t' read -r _ LOC REASON; do
      echo "CHECK-NOTE $SLUG $LOC $REASON"
    done >> "$T/notes.txt"
  fi
  [ -n "$HITS" ] || continue
  N=$(printf '%s\n' "$HITS" | grep -c . )
  TOTAL=$((TOTAL + N))
  SUMMARY="$SUMMARY $SLUG(x$N)"
  printf '%s\n' "$HITS" | while IFS=$'\t' read -r LOC REASON; do
    echo "CHECK-HIT $SLUG $LOC $REASON"
  done
done

# Notes print after every hit, so a reader that takes the head of the output
# sees the hits first.
[ -s "$T/notes.txt" ] && cat "$T/notes.txt"
NSUFFIX=""
[ "$NTOTAL" -gt 0 ] && NSUFFIX=" — $NTOTAL note(s):$NSUMMARY"
if [ "$TOTAL" -gt 0 ]; then
  echo "CHECKS: $TOTAL hit(s) —$SUMMARY$NSUFFIX"
  exit 1
fi
echo "CHECKS: clean ($NCHECKS check(s), $NLINES added line(s) scanned)$NSUFFIX"
exit 0
