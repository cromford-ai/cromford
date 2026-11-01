#!/bin/bash
# tests/test-impact-size.bh-8050-test.sh — BH-8050: AN UPPER BOUND ON WHAT
# THREE ORDINARY DIFFS SELECT, ON THE REAL TREE.
#
# A one-ticket PR selected 409 to 1,038 suites in its merge-queue batch. This
# suite builds the real map of this checkout once and runs three plain selects
# (--changed, --map, --why), the shapes the ticket names:
#
#   Z1  one lane script and its own suite (bin/stuck-work.sh +
#       tests/stuck-work-classify.bh-3781-test.sh): `selected`, at most
#       Z1_OWN_MAX non-always suites, every kind in {self, reads, named, source, closure,
#       learned, regression, always}, the suite's own `self` row, and as many
#       `always` rows as `bin/test-impact.sh always` prints
#   Z2  one prompt (prompts/build-discipline.md): `selected`, at most
#       Z2_OWN_MAX non-always suites, the always rows equal to the always set,
#       no `full` row, no `closure` row for another path
#   Z3  one doc (docs/REMOTE-GATE.md): `selected`, at most Z3_OWN_MAX
#       non-always suites, the always rows equal to the always set, every kind
#       in {source, reads, always}
#   Z4  the same three on a map built with TI_DIR_ROWS=0 select at least as
#       many suites each, and Z1 strictly more: the knob is a real rollback
#
# THE BOUNDS cap the rows this suite owns: every selected suite that is not an
# `always` row (self, reads, named, source, closure, learned, regression). The
# always count is capped once, by R3 of
# tests/test-impact-always-cut.bh-8098-test.sh, and each Z here checks that its
# always rows are exactly the always set. Each own bound is the total measured
# on the C1+C2 tree minus the always rows of that tree, so a growth of the
# directory, source or closure rows fails at the same count as before. The
# ticket's target is a lane diff under 200 and a median batch under 300. Z1
# does NOT meet the 200 target: it is a code diff, which the comment-only rule
# never narrows, and most of its rows are suites that scan bin/. The
# comment-only lane shape is pinned under 200 in
# tests/test-impact-comment-only.bh-8099-test.sh (Z5).
#
# Self-contained: no network, no secrets, no clock read. It reads the tree and
# writes only under $T.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Non-always rows. The C1+C2 totals (docs/notes/2026-10-23-BH-8099-comment-only.md)
# plus at most 10%, minus the 51 always rows they were measured with
# (docs/notes/2026-10-31-BH-8853-size-bounds-own-rows.md).
Z1_OWN_MAX=233   # measured 208 own; ticket target under 200 NOT met (a code diff)
Z2_OWN_MAX=46    # measured 38 own
Z3_OWN_MAX=17    # measured 11 own (this suite names the doc itself)

for f in bin/stuck-work.sh tests/stuck-work-classify.bh-3781-test.sh prompts/build-discipline.md docs/REMOTE-GATE.md; do
  [ -f "$DIR/$f" ] || { echo "FAIL: fixture path $f is gone from the tree; pick another of the same shape"; exit 1; }
done

"$TI" map --out "$T/map" 2> "$T/map.err" || { echo "FAIL: the map could not be built: $(cat "$T/map.err")"; exit 1; }
TI_DIR_ROWS=0 "$TI" map --out "$T/map0" 2> "$T/map0.err" || { echo "FAIL: the TI_DIR_ROWS=0 map could not be built"; exit 1; }
ALWAYS=$("$TI" always | grep -c .)

# sel <label> <map> <path>... — a plain select with --why; sets N (suites), NA
# (the `always` rows), OWN (N - NA) and RS (the reason line).
sel() {
  local l="$1" m="$2"; shift 2
  printf '%s\n' "$@" > "$T/$l.changed"
  "$TI" select --map "$m" --changed "$T/$l.changed" --why > "$T/$l.why" 2> "$T/$l.err"
  N=$(cut -f1 "$T/$l.why" | LC_ALL=C sort -u | grep -c .)
  NA=$(awk -F'\t' '$2 == "always"' "$T/$l.why" | grep -c .)
  OWN=$((N - NA))
  RS=$(grep '^impact:' "$T/$l.err" | tail -1)
}
kinds_in() { # <label> <allowed kinds regex> — rc 0 when every row's kind matches
  ! awk -F'\t' -v re="^($2)\$" '$2 !~ re { bad = 1 } END { exit !bad }' "$T/$1.why"
}
kinds() { cut -f2 "$T/$1.why" | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }'; }

# ── Z1: one lane script and its suite ───────────────────────────────────────
sel z1 "$T/map" bin/stuck-work.sh tests/stuck-work-classify.bh-3781-test.sh; Z1=$N; Z1_OWN=$OWN
case "$RS" in "impact: $N of "*" (selected: 2 changed path(s))") ok ;; *) bad "Z1: the reason line must be selected (got '$RS')" ;; esac
[ "$OWN" -le "$Z1_OWN_MAX" ] && ok || bad "Z1: a lane script + its suite must select at most $Z1_OWN_MAX non-always suites (got $OWN own, $NA always: $(kinds z1))"
kinds_in z1 'self|reads|named|source|closure|learned|regression|always' && ok || bad "Z1: an unexpected kind ($(kinds z1))"
grep -qxF "tests/stuck-work-classify.bh-3781-test.sh	self	tests/stuck-work-classify.bh-3781-test.sh" "$T/z1.why" && ok || bad "Z1: the suite's own self row is missing"
[ "$NA" = "$ALWAYS" ] && ok || bad "Z1: the always rows must equal 'bin/test-impact.sh always' ($ALWAYS; got $(kinds z1))"

# ── Z2: one prompt ──────────────────────────────────────────────────────────
sel z2 "$T/map" prompts/build-discipline.md; Z2=$N; Z2_OWN=$OWN
case "$RS" in "impact: $N of "*" (selected: 1 changed path(s))") ok ;; *) bad "Z2: the reason line must be selected (got '$RS')" ;; esac
[ "$OWN" -le "$Z2_OWN_MAX" ] && ok || bad "Z2: one prompt must select at most $Z2_OWN_MAX non-always suites (got $OWN own, $NA always: $(kinds z2))"
[ "$NA" = "$ALWAYS" ] && ok || bad "Z2: the always rows must equal 'bin/test-impact.sh always' ($ALWAYS; got $(kinds z2))"
[ -z "$(awk -F'\t' '$2 == "full"' "$T/z2.why")" ] && ok || bad "Z2: no full row"
[ -z "$(awk -F'\t' '$2 == "closure" && $3 != "prompts/build-discipline.md"' "$T/z2.why")" ] && ok || bad "Z2: a closure row for another path"

# ── Z3: one doc ─────────────────────────────────────────────────────────────
sel z3 "$T/map" docs/REMOTE-GATE.md; Z3=$N; Z3_OWN=$OWN
case "$RS" in "impact: $N of "*" (selected: 1 changed path(s))") ok ;; *) bad "Z3: the reason line must be selected (got '$RS')" ;; esac
[ "$OWN" -le "$Z3_OWN_MAX" ] && ok || bad "Z3: one doc must select at most $Z3_OWN_MAX non-always suites (got $OWN own, $NA always: $(kinds z3))"
[ "$NA" = "$ALWAYS" ] && ok || bad "Z3: the always rows must equal 'bin/test-impact.sh always' ($ALWAYS; got $(kinds z3))"
kinds_in z3 'source|reads|always' && ok || bad "Z3: kinds must be source, reads, always ($(kinds z3))"

# ── Z4: the knob is a real rollback ─────────────────────────────────────────
sel z1off "$T/map0" bin/stuck-work.sh tests/stuck-work-classify.bh-3781-test.sh
[ "$N" -gt "$Z1" ] && ok || bad "Z4: TI_DIR_ROWS=0 must select more for the lane diff ($N, on: $Z1)"
sel z2off "$T/map0" prompts/build-discipline.md
[ "$N" -ge "$Z2" ] && ok || bad "Z4: TI_DIR_ROWS=0 must select at least as many for the prompt ($N, on: $Z2)"
sel z3off "$T/map0" docs/REMOTE-GATE.md
[ "$N" -ge "$Z3" ] && ok || bad "Z4: TI_DIR_ROWS=0 must select at least as many for the doc ($N, on: $Z3)"

echo "test-impact-size-8050: Z1=$Z1 ($Z1_OWN own) Z2=$Z2 ($Z2_OWN own) Z3=$Z3 ($Z3_OWN own), always=$ALWAYS (own bounds $Z1_OWN_MAX $Z2_OWN_MAX $Z3_OWN_MAX)"
echo "test-impact-size-8050: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
