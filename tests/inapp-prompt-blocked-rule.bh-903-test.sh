#!/bin/bash
# tests/inapp-prompt-blocked-rule.bh-903-test.sh — BH-903 (BH-815.4): the
# in-app triage prompts carry the `blocked: true` rule, and the dated note
# records the webhook fast-path finding.
#
# The deliverable here IS text: seven prompt files a model reads at triage
# time, plus one note under docs/notes/. So this suite is presence-and-shape
# over those files by nature (D3) — what the CODE does with `blocked` is pinned
# by tests/triage-gate-fingerprint-deps.bh-899-test.sh and the #900/#901/#902
# suites. What keeps a presence check honest is the two guards below:
#
#   * an absent or unreadable prompt is a FAIL printed by name, never a skip —
#     a grep over a missing file passes silently;
#   * the per-file checker is a function, and assertion 6 runs it over scratch
#     copies that have the rule deleted and the rule carrying an em dash, and
#     requires it to go red on both. A checker that cannot go red is not a
#     check (D1).
#
# No network, no model, no bin/ call.
#
# TEST-CHANGE (BH-1024, 2026-09-19): §7's two negative diff assertions were
# scoped to branches that touch THIS slice's subject. They are unchanged and
# still run in full there; what changed is that a branch touching neither the
# prompts nor the dated note now prints N/A instead of failing an assertion
# about somebody else's slice. Written up where §7 is, and disclosed in the
# BH-1024 commit and PR body rather than only in this file.
#
# Run from anywhere: tests/inapp-prompt-blocked-rule.bh-903-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1

DIR=$(cd "$(dirname "$0")/.." && pwd)
NOTE="$DIR/docs/notes/2026-09-18-BH-815-inapp-dependencies-read-side.md"
PROMPTS="TEMPLATE project-4 project-1 project-2 project-3 project-8 project-9"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The arrow a line uses. `→` wins when both appear, because that is the glyph
# the decision tables are written in; `->` is the ascii fallback some prompts
# use in prose.
arrow_of() {
  case "$1" in
    *"→"*)  printf '%s' "→" ;;
    *"->"*) printf '%s' "->" ;;
    *)      printf '%s' "" ;;
  esac
}

# The blocked-rule line of a prompt file, or empty. Deliberately the same
# extraction the checker uses, so assertion 4 compares what assertion 2-3 read.
rule_line_of() {
  grep -n -- 'blocked: true' "$1" 2>/dev/null | head -1 | cut -d: -f2-
}

# check_file <path> — every per-file assertion, as one function so the mutation
# guard can run it over a deliberately broken copy. Prints its reasons, returns
# nonzero on any failure.
check_file() {
  local f="$1" rc=0 nl bl nline rline
  if [ ! -r "$f" ]; then
    echo "  - $f is missing or unreadable"
    return 1
  fi

  nl=$(grep -n -- 'needs_clarification' "$f" | head -1 | cut -d: -f1)
  bl=$(grep -n -- 'blocked: true' "$f" | head -1 | cut -d: -f1)

  if [ -z "$nl" ]; then
    echo "  - $f has no needs_clarification rule to anchor against"
    return 1
  fi
  if [ -z "$bl" ]; then
    echo "  - $f carries no \`blocked: true\` rule line"
    return 1
  fi

  nline=$(sed -n "${nl}p" "$f")
  rline=$(sed -n "${bl}p" "$f")

  # 2. placement: after the turn rule, within 3 lines of it.
  if [ "$bl" -le "$nl" ]; then
    echo "  - $f: the \`blocked: true\` rule (line $bl) must come AFTER the needs_clarification rule (line $nl)"
    rc=1
  elif [ $((bl - nl)) -gt 3 ]; then
    echo "  - $f: the \`blocked: true\` rule (line $bl) is $((bl - nl)) lines from the needs_clarification rule (line $nl), more than 3"
    rc=1
  fi

  # 3. content of the rule line.
  case "$rline" in
    *dependsOn*) ;;
    *) echo "  - $f: the blocked rule does not name \`dependsOn\`: $rline"; rc=1 ;;
  esac
  case "$rline" in
    *"NOT actionable"*) ;;
    *) echo "  - $f: the blocked rule does not say NOT actionable: $rline"; rc=1 ;;
  esac
  case "$rline" in
    *"—"*) echo "  - $f: the blocked rule carries an em dash (house voice: near-zero em dashes): $rline"; rc=1 ;;
  esac

  local want got
  want=$(arrow_of "$nline")
  got=$(arrow_of "$rline")
  if [ -z "$want" ]; then
    echo "  - $f: the needs_clarification rule on line $nl has no arrow to match"
    rc=1
  elif [ "$got" != "$want" ]; then
    echo "  - $f: the blocked rule uses arrow '${got:-none}' but line $nl uses '$want'"
    rc=1
  fi

  return $rc
}

# ── 1-3. the seven prompts ───────────────────────────────────────────────────
for p in $PROMPTS; do
  if check_file "$DIR/prompts/$p.md"; then ok; else bad "prompts/$p.md does not carry the blocked rule correctly (see above)"; fi
done

# ── 4. the seven lines are byte-identical ────────────────────────────────────
LINES="$T/rule-lines.txt"
: > "$LINES"
for p in $PROMPTS; do
  rule_line_of "$DIR/prompts/$p.md" >> "$LINES"
done
UNIQ=$(sort -u "$LINES" | wc -l)
if [ "$UNIQ" -eq 1 ] && [ -s "$LINES" ]; then ok; else
  bad "the blocked rule is not byte-identical across the seven prompts ($UNIQ distinct variants):"
  sort -u "$LINES"
fi

# ── 5. the dated note ────────────────────────────────────────────────────────
if [ ! -r "$NOTE" ]; then
  bad "docs/notes/2026-09-18-BH-815-inapp-dependencies-read-side.md is missing or unreadable at $NOTE"
else
  ok
  if grep -qE '^Doc:.*EVENTS' "$NOTE"; then ok; else
    bad "the note has no \`Doc:\` line naming EVENTS (D37: a note declares the docs it belongs to)"
  fi
  RC_COUNT=$(grep -c -- 'releasedChildren' "$NOTE")
  if [ "$RC_COUNT" -ge 1 ]; then ok; else
    bad "the note never names \`releasedChildren\` — the field the boards would send in a status-change webhook"
  fi
fi

# ── 6. mutation guard (D1): the checker must go red on a broken copy ─────────
MUT="$T/mutants"
mkdir -p "$MUT"
SRC="$DIR/prompts/project-3.md"
if [ ! -r "$SRC" ]; then
  bad "cannot run the mutation guard: $SRC is unreadable"
else
  # (a) the rule line deleted.
  sed '/blocked: true/d' "$SRC" > "$MUT/deleted.md"
  if check_file "$MUT/deleted.md" >/dev/null 2>&1; then
    bad "mutation guard: the checker stayed green on a copy with the blocked rule DELETED"
  else ok; fi

  # (b) the rule line carrying an em dash.
  sed 's/\(blocked: true.*\)NOT actionable/\1NOT actionable —/' "$SRC" > "$MUT/emdash.md"
  if ! grep -q -- '—' "$MUT/emdash.md"; then
    bad "mutation guard: could not build the em-dash mutant from $SRC (the rule line did not match)"
  elif check_file "$MUT/emdash.md" >/dev/null 2>&1; then
    bad "mutation guard: the checker stayed green on a copy whose blocked rule carries an em dash"
  else ok; fi
fi

# ── 7. the negative diff: this slice touches no monolith doc and no worker ───
# This arm judges BH-903's OWN slice. It runs on every branch CI builds, so on a
# branch that is not this ticket's (one that edits worker/ for its own reasons)
# it must stay inert: the diff is "this ticket's" only when it touches the
# ticket's spec or its guardrail. (2026-09-21: #1158 and #727 went red here for
# editing worker/ on unrelated tickets.) TEST-CHANGE (BH-1024, rebase merge):
# main's own #1260 fixed this same landmine independently, scoped to
# `.harness/specs/BH-903/` and `guardrails/inapp-prompt`; BH-1024's round-4 fix
# scoped it to `prompts/` and BH-815's dated note. Both are real "this is BH-903's
# slice" signals, so the gate ORs them rather than picking one — neither fix is
# weakened by carrying the other's paths. TEST-CHANGE (BH-1950, fix round):
# `prompts/` as a whole matched any branch that adds a prompt of its own
# (BH-1950 adds prompts/lead-review.md and a worker/ schema row), so the arm
# judged a foreign ticket. The signal is now the seven prompts this suite
# checks ($PROMPTS); every assertion in the arm is unchanged.
if git -C "$DIR" rev-parse --verify origin/main >/dev/null 2>&1; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-903's own slice
  CHANGED=$(git -C "$DIR" diff --name-only origin/main...HEAD)
  SLICE_PROMPTS=$(printf 'prompts/%s\.md|' $PROMPTS)
  if ! grep -qE "^(\.harness/specs/BH-903/|guardrails/inapp-prompt|${SLICE_PROMPTS%|}|docs/notes/2026-09-18-BH-815)" <<<"$(printf '%s\n' "$CHANGED")"; then
    echo "SKIP (this branch is not BH-903's slice) — the negative-diff arm judges only the ticket's own branch."
  else
  if grep -qx 'docs/EVENTS.md' <<<"$CHANGED"; then
    bad "this branch edits docs/EVENTS.md — the finding belongs in the dated note (D37, guardrails/doc-monolith-edit)"
  else ok; fi
  if grep -q '^worker/' <<<"$CHANGED"; then
    bad "this branch edits worker/ — the board-facing webhook receiver is its own ticket, not this one"
  else ok; fi
  fi
else
  echo "SKIP (no origin/main in this checkout) — the negative diff assertion could not run here;"
  echo "SKIP   the builder pastes \`git diff --name-only origin/main...HEAD\` output in the PR body instead."
fi

echo "inapp-prompt-blocked-rule: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
