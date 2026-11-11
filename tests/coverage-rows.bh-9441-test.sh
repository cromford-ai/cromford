#!/bin/bash
# tests/coverage-rows.bh-9441-test.sh — BH-9441: a plan whose
# `## Requirements coverage` table has fewer rows than the ticket body's
# `## Scope` has items is refused by the plan gate (rc 2), gets one repair pass,
# then ends PLAN_MALFORMED.
#
# Driven: bin/lib/coverage-rows.sh, bin/plan-gate.sh as installed by
# scratch_install_closure, and the shipped `# >>> coverage rows note` and
# `# >>> plan gate` regions of bin/lib/rb/plan.sh (flattened by rb_all), with
# the model call (CC), the beat and the ledger stubbed.
#   P1-P9  cr_scope_count: what a scope item is
#   R1-R6  cr_plan_rows / cr_plan_check: what a coverage row is, the knob, unread
#   G1-G7  bin/plan-gate.sh with PLAN_GATE_TICKET (G1 = the ticket's acceptance test)
#   N1-N2  the coverage rows note region and UI_PLAN_NOTE
#   E1     the plan gate region: rc 2 twice ends PLAN_MALFORMED naming the gap
#   K1     the registry default equals CR_DEFAULT_ENFORCE
#   Z1     no model call: CC is a local stub
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/coverage-rows.bh-9441-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD COVERAGE_ROWS_ENFORCE
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }
FX="$DIR/tests/fixtures/coverage-rows.bh-9441"

mkdir -p "$T/h/state" "$T/h/logs"
scratch_install_closure bin/plan-gate.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
LIB="$T/h/bin/lib/coverage-rows.sh"
# G6: the lib rides the plan gate's closure, or a box gets a gate without it.
[ -r "$LIB" ] && ok || { bad "G6 bin/lib/coverage-rows.sh is not in the plan-gate closure"; LIB="$DIR/bin/lib/coverage-rows.sh"; }
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
PG="$T/h/bin/plan-gate.sh"

# ── P: cr_scope_count ────────────────────────────────────────────────────────
sc() { printf '%b' "$1" > "$T/sc.md"; cr_scope_count "$T/sc.md"; echo "rc=$?"; }
[ "$(cr_scope_count "$FX/ticket-bh-9441-body.json")" = 5 ] && ok \
  || bad "P1 this ticket's own body has 5 scope items, got '$(cr_scope_count "$FX/ticket-bh-9441-body.json")'"
[ "$(sc '## Problem\n\n- x\n\n## Out of scope\n\n- a\n- b\n- c\n')" = 'rc=1' ] && ok \
  || bad "P2 '## Out of scope' alone is no Scope section: $(sc '## Out of scope\n\n- a\n')"
[ "$(sc '## Scoped notes\n\n- a\n- b\n')" = 'rc=1' ] && ok || bad "P3 '## Scoped notes' is a near miss: $(sc '## Scoped notes\n\n- a\n')"
[ "$(sc '## Scope\n\n1. a\n   - sub\n   - sub\n2. b\n  * sub\n3. c\n4. d\n5. e\n')" = $'5\nrc=0' ] && ok \
  || bad "P4 sub-bullets are not counted: $(sc '## Scope\n\n1. a\n   - sub\n2. b\n')"
[ "$(sc '## Scope\n\n1. a\n```\n- x\n- y\n```\n2. b\n')" = $'2\nrc=0' ] && ok || bad "P5 a fenced list is not counted: $(sc '## Scope\n\n1. a\n```\n- x\n```\n')"
[ "$(sc '## Scope\n\n1) a\n2) b\n3) c\n')" = $'3\nrc=0' ] && ok || bad "P6 '1)' numbering counts: $(sc '## Scope\n\n1) a\n2) b\n3) c\n')"
[ "$(sc '## Plan\n\n### Scope\n\n- a\n- b\n\n### Other\n\n- c\n\n## Next\n\n- d\n')" = $'2\nrc=0' ] && ok \
  || bad "P7 '### Scope' closes at the next heading of its level: $(sc '## Plan\n\n### Scope\n\n- a\n- b\n\n### Other\n\n- c\n')"
printf '{"body":"## Problem\\n\\nplain\\n","comments":[{"body":"## Scope\\n\\n1. a\\n2. b\\n"}]}' > "$T/meta-comment.json"
cr_scope_count "$T/meta-comment.json" >/dev/null && bad "P8 a Scope list in a comment must never count" || ok
[ "$(sc '## Scope (files: `a.md`, `b.sh`)\n\n1. a\n2. b\n')" = $'2\nrc=0' ] && ok || bad "P9 '## Scope (files: ...)' matches: $(sc '## Scope (files: a)\n\n1. a\n')"

# ── R: cr_plan_rows / cr_plan_check ─────────────────────────────────────────
pr() { printf '%b' "$1" > "$T/pr.md"; cr_plan_rows "$T/pr.md"; }
[ "$(pr '## Requirements coverage\n\n| a | b |\n|---|---|\n')" = 0 ] && ok \
  || bad "R1 header + separator are not rows: $(pr '## Requirements coverage\n\n| a | b |\n|---|---|\n')"
[ "$(pr '## Requirements coverage\n\n- a\n- b\n  - sub\n1. c\n')" = 3 ] && ok || bad "R2 list rows count, sub-bullets do not: $(pr '## Requirements coverage\n\n- a\n- b\n  - sub\n1. c\n')"
[ "$(pr '## Requirements coverage\n\n| h |\n|:-:|\n| a |\n\n## Acceptance tests\n\n| h |\n|---|\n| x |\n| y |\n- z\n')" = 1 ] && ok \
  || bad "R3 rows in a later section are not counted: $(pr '## Requirements coverage\n\n| h |\n|:-:|\n| a |\n\n## Acceptance tests\n\n| x |\n')"
[ "$(pr '## Requirements coverage\n\n```\n| a |\n| b |\n```\n| c |\n')" = 1 ] && ok || bad "R4 a fenced table is not counted: $(pr '## Requirements coverage\n\n```\n| a |\n```\n| c |\n')"
OUT=$(COVERAGE_ROWS_ENFORCE=0 cr_plan_check "$FX/plan-3-rows.md" "$FX/ticket-4-items.json"); RC=$?
[ "$RC" = 0 ] && grep -q '^  NOTE: coverage (COVERAGE_ROWS_ENFORCE=0) — ' <<<"$OUT" && ! grep -q 'UNTRACED' <<<"$OUT" \
  && grep -qx 'PLAN_COVERAGE: short (not enforced, COVERAGE_ROWS_ENFORCE=0)' <<<"$OUT" && ok \
  || bad "R5 COVERAGE_ROWS_ENFORCE=0 logs and never refuses, rc $RC: $OUT"
OUT=$(cr_plan_check "$FX/plan-3-rows.md" "$T/does-not-exist.json"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = 'PLAN_COVERAGE: unread' ] && ok || bad "R6 an unreadable ticket never refuses, rc $RC: $OUT"
OUT=$(cr_plan_check "$T/no-plan.md" "$FX/ticket-4-items.json"); RC=$?
[ "$RC" = 2 ] && grep -q "no '## Requirements coverage' section, the ticket's Scope has 4 item(s)" <<<"$OUT" && ok \
  || bad "R6b no coverage section is short, rc $RC: $OUT"
OUT=$(COVERAGE_ROWS_ENFORCE=maybe bash -c '. "$1"; cr_conf; echo "$CR_ENFORCE|$CR_CONF_WARN"' _ "$LIB")
case "$OUT" in "1|COVERAGE_ROWS_ENFORCE='maybe' is not on/off"*) ok ;; *) bad "R7 an unknown knob value enforces with a warning: $OUT" ;; esac

# ── G: bin/plan-gate.sh ─────────────────────────────────────────────────────
gate() { # gate <plan> [ticket] -> $T/g.out, rc in GRC
  if [ -n "${2:-}" ]; then PLAN_GATE_TICKET="$2" "$PG" "$1" > "$T/g.out" 2>&1; GRC=$?
  else env -u PLAN_GATE_TICKET "$PG" "$1" > "$T/g.out" 2>&1; GRC=$?; fi
}
gate "$FX/plan-3-rows.md" "$FX/ticket-4-items.json"
[ "$GRC" = 2 ] && ok || bad "G1 a 4-item Scope and a 3-row table must be refused (rc 2), got rc $GRC: $(cat "$T/g.out")"
grep -qx 'PLAN_COVERAGE: short' "$T/g.out" && ok || bad "G1 PLAN_COVERAGE: short: $(cat "$T/g.out")"
grep -qx "  UNTRACED: coverage — '## Requirements coverage' has 3 row(s), the ticket's Scope has 4 item(s)" "$T/g.out" && ok \
  || bad "G1 the UNTRACED line names 3 rows and 4 items: $(cat "$T/g.out")"
grep -qx 'PLAN_TRACE: untraced' "$T/g.out" && ok || bad "G1 the final verdict is untraced: $(tail -1 "$T/g.out")"
cp "$T/g.out" "$T/g1.out"

gate "$FX/plan-4-rows.md" "$FX/ticket-4-items.json"
[ "$GRC" = 0 ] && grep -qx 'PLAN_COVERAGE: ok (4 row(s) for 4 scope item(s))' "$T/g.out" && grep -qx 'PLAN_TRACE: ok' "$T/g.out" && ok \
  || bad "G2 a 4-row table for a 4-item Scope passes, rc $GRC: $(cat "$T/g.out")"

gate "$FX/plan-3-rows.md"; cp "$T/g.out" "$T/g3-unset.txt"; R1=$GRC
[ "$R1" = 0 ] && ! grep -q 'PLAN_COVERAGE' "$T/g3-unset.txt" && ok || bad "G3 no PLAN_GATE_TICKET: no coverage line, rc 0, rc $R1: $(cat "$T/g3-unset.txt")"

jq -n --arg b $'## Problem\n\nA bug.\n\n## Out of scope\n\n- a\n- b\n- c\n' '{body:$b}' > "$T/plain.json"
gate "$FX/plan-3-rows.md" "$T/plain.json"
[ "$GRC" = 0 ] && ! grep -q 'PLAN_COVERAGE' "$T/g.out" && ok || bad "G4 a ticket with no Scope prints no coverage line, rc $GRC: $(cat "$T/g.out")"
grep -v '^PLAN_SPEC_TRACE: ' "$T/g.out" | cmp -s - <(grep -v '^PLAN_SPEC_TRACE: ' "$T/g3-unset.txt") && ok \
  || bad "G4 a no-Scope ticket changes nothing else in the gate output: $(diff "$T/g3-unset.txt" "$T/g.out")"

{ printf '# Plan\n\n## Tasks\n\n### Task 1 — untraced\nno trace lines here\n\n### Task 2 — traced\nVALIDATE: bash t.sh\nSATISFIES: x\n\n'
  printf '## Requirements coverage\n\n- one\n\nKIND: feature\nSIZE: S\n'; } > "$T/both.md"
gate "$T/both.md" "$FX/ticket-4-items.json"
[ "$GRC" = 2 ] && grep -q '^  UNTRACED: .*Task 1' "$T/g.out" && grep -q '^  UNTRACED: coverage — ' "$T/g.out" && ok \
  || bad "G5 an untraced and short plan stays rc 2 with both UNTRACED lines, rc $GRC: $(cat "$T/g.out")"

gate "$FX/plan-3-rows.md" "$FX/ticket-bh-9441-body.json"
[ "$GRC" = 2 ] && grep -q "has 3 row(s), the ticket's Scope has 5 item(s)" "$T/g.out" && ok \
  || bad "G7 this ticket's own body (5 items) refuses a 3-row plan, rc $GRC: $(cat "$T/g.out")"

# ── N, E: the shipped regions of bin/lib/rb/plan.sh ──────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> coverage rows note \(BH-9441\)/{f=1;next} /^# <<< coverage rows note \(BH-9441\)/{exit} f' "$RB_ALL" > "$T/note.sh"
awk '/^# >>> plan gate$/{f=1;next} /^# <<< plan gate$/{exit} f' "$RB_ALL" > "$T/pgblock.sh"
[ -s "$T/note.sh" ] && ok || bad "N0 could not extract the coverage rows note region"
[ -s "$T/pgblock.sh" ] && grep -q 'PLAN_GATE_TICKET=' "$T/pgblock.sh" && ok || bad "E0 the plan gate region must pass PLAN_GATE_TICKET"
# Z1: the only CC in this suite is this stub; it writes the prompt to a file.
cat > "$T/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { :; }
CC() { printf '%s\n' "$5" >> "$CCLOG"; printf 'stub repair\n' > "$4"; }
UI_PLAN_NOTE="${UI_PLAN_NOTE_IN:-}"
. "$NOTE"
printf '%s' "$UI_PLAN_NOTE" > "$NOTEOUT"
[ "${GATE:-0}" = 1 ] || exit 0
. "$PGBLOCK"
echo CONTINUED
EOS
drive() { # drive <ticket-json> <plan> [env...]
  local tk="$1" pl="$2"; shift 2
  rm -rf "$T/b"; mkdir -p "$T/b"; cp "$tk" "$T/b/ticket-meta.json"; cp "$pl" "$T/b/plan.md"
  : > "$T/cc.log"; : > "$T/h/logs/ALERTS.log"; rm -f "$T/h/state/plan-malformed.txt"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=1 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" NOTE="$T/note.sh" PGBLOCK="$T/pgblock.sh" \
        NOTEOUT="$T/noteout" "$@" bash "$T/drive.sh" 2>&1 )
}
drive "$FX/ticket-4-items.json" "$FX/plan-4-rows.md" UI_PLAN_NOTE_IN='pre ' >/dev/null
N1=$(cat "$T/noteout")
case "$N1" in "pre  REQUIREMENTS COVERAGE"*) ok ;; *) bad "N1 the note is appended to UI_PLAN_NOTE: $N1" ;; esac
grep -q 'at least 4 rows' <<<"$N1" && grep -q '## Requirements coverage' <<<"$N1" && grep -q 'file and the test' <<<"$N1" && ok \
  || bad "N1 the note names the count, the section and the row rule: $N1"
drive "$T/plain.json" "$FX/plan-4-rows.md" UI_PLAN_NOTE_IN='pre ' >/dev/null
[ "$(cat "$T/noteout")" = 'pre ' ] && ok || bad "N2 a no-Scope ticket leaves UI_PLAN_NOTE byte-identical: '$(cat "$T/noteout")'"

OUT=$(drive "$FX/ticket-4-items.json" "$FX/plan-3-rows.md" GATE=1)
grep -q '^RESULT=PLAN_MALFORMED ' <<<"$OUT" && ok || bad "E1 rc 2 twice must end PLAN_MALFORMED: $OUT"
grep -q CONTINUED <<<"$OUT" && bad "E1 the build must not continue past a short coverage table" || ok
[ "$(grep -c 'Repair the plan' "$T/cc.log")" = 1 ] && grep -q "coverage — '## Requirements coverage' has 3 row(s)" "$T/cc.log" \
  && grep -q 'REQUIREMENTS COVERAGE: the coverage table is short' "$T/cc.log" && ok \
  || bad "E1 the one repair prompt carries the coverage line and the repair note: $(cat "$T/cc.log")"
grep -q 'the coverage table is still short (3 row(s) for 4 scope item(s))' <<<"$OUT" && ok || bad "E1 the PLAN_MALFORMED reason names the coverage gap: $OUT"
OUT=$(drive "$FX/ticket-4-items.json" "$FX/plan-4-rows.md" GATE=1)
grep -q CONTINUED <<<"$OUT" && [ ! -s "$T/cc.log" ] && ok || bad "E1 a full table continues with no repair session: $OUT"

# ── K1: the registry default is the lib's fallback ──────────────────────────
REG="$DIR/catalog/lanes.d/_lib.coverage-rows.json"
[ "$(jq -r '.libs[] | select(.id == "coverage-rows") | .file' "$REG" 2>/dev/null)" = bin/lib/coverage-rows.sh ] && ok \
  || bad "K1 the registry names bin/lib/coverage-rows.sh"
KD=$(jq -r '.libs[] | select(.id == "coverage-rows") | .knobs[] | select(.env == "COVERAGE_ROWS_ENFORCE") | .default' "$REG" 2>/dev/null)
[ "$KD" = "$CR_DEFAULT_ENFORCE" ] && ok || bad "K1 COVERAGE_ROWS_ENFORCE: registry '$KD' != lib CR_DEFAULT_ENFORCE '$CR_DEFAULT_ENFORCE'"

# ── Z1: no model call ───────────────────────────────────────────────────────
# The suite's only CC is the drive.sh stub, and nothing here names a model CLI.
[ "$(grep -c '^CC() {' "$0")" = 1 ] && ! grep -qE '(^|[^-])\b(claude|agent-call)[[:space:]]+-' "$0" && ok \
  || bad "Z1 the suite defines one CC stub and invokes no model CLI"

echo "coverage-rows.bh-9441: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
