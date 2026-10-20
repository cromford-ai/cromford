#!/bin/bash
# tests/plan-diff-bind.bh-7273-test.sh — the plan-to-diff binding check
# (BH-7273): bin/lib/plan-diff-bind.sh and its rules-pack row.
#
#   A1-A5  the ticket's acceptance tests: a planned file the diff skips, a
#          class claim the diff breaks, an unplanned bin/ file, a bound plan
#          (with a verify-only line), a named case ID missing at HEAD.
#   B1-B6  planned-not-changed and case-missing edges: a glob, a dir scope, a
#          second token, a continuation line, a prose bullet, a Verify
#          section, conditional lines, R1 vs R10, D41, no add verb, a range
#          over 60, a task heading ID, `to` / `..` / en-dash ranges.
#   C1-C8  changed-not-planned edges: a task line, a `:12` suffix, a validate
#          line, a glob, docs/ and rules/, the ignore default and knob, a dir
#          scope, Verify and Sibling claims sections, a box path.
#   K1-K5  class-claim: a wrapped claim, `nothing in` ... `is edited`, quoted
#          examples, conditionals and exceptions, near misses.
#   S1-S6  plan selection (0, 2, deleted, requirements only, unchanged) and
#          rc 2.
#   P1     the production entry point: bin/rules-pack.sh --only plan-diff-bind,
#          red then green.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-diff-bind.bh-7273-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -n "${T:-}" ] && [ -d "$T" ] || { echo "FAIL: no scratch dir"; exit 1; }
cd "$T" || exit 1
LIB="$DIR/bin/lib/plan-diff-bind.sh"
mkdir -p "$T/inst"
( cd "$DIR" && scratch_install_closure bin/lib/plan-diff-bind.sh "$T/inst" ) >/dev/null \
  || bad "cannot install $LIB"
PDB="$T/inst/bin/lib/plan-diff-bind.sh"
PLANP=.harness/specs/BH-1/plan.md

# run <cmd...> — sets RC, OUT, ERR
run() {
  "$@" >"$T/out" 2>"$T/err"; RC=$?
  OUT=$(cat "$T/out"); ERR=$(cat "$T/err")
}
# new_repo <name> — a fixture repo on branch work, origin/main at its base
new_repo() {
  R="$T/$1"
  mkdir -p "$R/bin/lib" "$R/worker/jobs/src/routes" "$R/worker/jobs/schema.d" "$R/tests/mc/expected-map.d" \
    "$R/catalog" "$R/docs/notes" "$R/rules"
  for f in bin/x.sh bin/lib/flaky.sh bin/lib/mc-batch-impact.sh worker/jobs/src/routes/flags.js \
           catalog/c.tsv docs/notes/a.md rules/r.md tests/t.bh-1-test.sh; do
    echo "base $f" > "$R/$f"
  done
  rd_fixture_repo "$R" >/dev/null || { echo "FAIL: cannot build fixture $1"; exit 1; }
}
plan() { mkdir -p "$R/.harness/specs/BH-1"; cat > "$R/$PLANP"; }
change() { local f; for f; do mkdir -p "$R/$(dirname "$f")"; echo "change $f" >> "$R/$f"; done; }
commit() { rd_git "$R" add -A && rd_git "$R" commit -qm "${1:-head}"; }
check() { run bash "$PDB" --base origin/main "$R"; }
# lno <text> — the plan line that first holds <text>
lno() { grep -nF -- "$1" "$R/$PLANP" | head -n 1 | cut -d: -f1; }
# has <case> <prefix> — a stdout line starts with <prefix>
has() {
  printf '%s\n' "$OUT" | awk -v p="$2" 'index($0, p) == 1 { f = 1 } END { exit !f }' && ok \
    || bad "$1 stdout [$OUT] (want a line starting [$2])"
}
lines() { local n; n=$(grep -c . <<<"$OUT"); [ "$n" -eq "$2" ] && ok || bad "$1 $n finding lines (want $2): $OUT"; }
rc_is() { [ "$RC" -eq "$2" ] && ok || bad "$1 rc $RC (want $2): $OUT $ERR"; }
clean() { rc_is "$1" 0; [ -z "$OUT" ] && ok || bad "$1 stdout [$OUT] (want empty)"; }

# ── A: the ticket's acceptance tests ──────────────────────────────────────
# A1 the plan names worker/jobs/src/routes/flags.js as edited; the diff skips it
new_repo a1
plan <<'EOF'
# BH-1 plan

## Files to touch

- `bin/x.sh`: the change.
- `worker/jobs/src/routes/flags.js`: the route.
EOF
change bin/x.sh; commit
check
rc_is A1 1
has A1 "planned-not-changed worker/jobs/src/routes/flags.js $PLANP:$(lno 'routes/flags.js') — "
lines A1 1

# A2 "No path under bin/ or worker/ changes." and the diff changes bin/lib/flaky.sh
new_repo a2
plan <<'EOF'
# BH-1 plan

## Files to touch

- `bin/lib/flaky.sh`: the fix.

## Scope

No path under bin/ or worker/ changes.
EOF
change bin/lib/flaky.sh; commit
check
rc_is A2 1
has A2 "class-claim bin/lib/flaky.sh $PLANP:$(lno 'No path under') — "
lines A2 1

# A3 the diff changes bin/lib/mc-batch-impact.sh and the plan does not name it
new_repo a3
plan <<'EOF'
## Files to touch

- `bin/x.sh`: the change.
EOF
change bin/x.sh bin/lib/mc-batch-impact.sh; commit
check
rc_is A3 1
has A3 "changed-not-planned bin/lib/mc-batch-impact.sh $PLANP — "
lines A3 1

# A4 the named files equal the changed files, plus a verify-only file
new_repo a4
plan <<'EOF'
## Files to touch

- `bin/x.sh`: the change.
- `catalog/c.tsv`: one row.
- `tests/n.bh-1-test.sh` (NEW): the suite.
- `docs/notes/2026-01-01-BH-1-x.md` (NEW): the note.
- verify-only: `tests/z.bh-9-test.sh` runs as it is.
- `bin/lib/flaky.sh` verify-only: the caller, run not edited.
EOF
change bin/x.sh catalog/c.tsv tests/n.bh-1-test.sh docs/notes/2026-01-01-BH-1-x.md; commit
check
clean A4

# A5 a Files-to-touch line names R1-R7 as new; the file at HEAD has R1-R6 only
new_repo a5
plan <<'EOF'
## Files to touch

- `tests/x.bh-1-test.sh` (NEW) — cases R1-R7.
EOF
mkdir -p "$R/tests"
printf '%s\n' 'R1: a' 'R2: b' 'R3: c' 'R4: d' 'R5: e' 'R6: f' > "$R/tests/x.bh-1-test.sh"; commit
check
rc_is A5 1
has A5 "case-missing tests/x.bh-1-test.sh $PLANP:$(lno 'cases R1-R7') — case R7 "
lines A5 1

# ── B: planned-not-changed and case-missing edges ─────────────────────────
# B1 a glob path: no changed path matches it (red), then one does (clean)
new_repo b1
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.
- `worker/jobs/schema.d/<yyyymmddhhmm>-bh-1-x.sql` (new): the table.
EOF
change bin/x.sh; commit
check
rc_is B1 1
has B1 "planned-not-changed worker/jobs/schema.d/*-bh-1-x.sql $PLANP:$(lno 'schema.d/') — "
lines B1 1
change worker/jobs/schema.d/202610170000-bh-1-x.sql; commit
check
clean B1-match

# B2 a dir scope, a second token, a continuation, a prose bullet, Verify
new_repo b2
plan <<'EOF'
## Files to touch

- `docs/notes/`: a dated note.
- `bin/x.sh` — mirror `bin/lib/flaky.sh`.
- `catalog/c.tsv`: one row, as
  `bin/lib/mc-batch-impact.sh` does.
- `job_ledger_put merge` has other writers: `bin/lib/rb.sh:535`.

## Verify (run, not edited)

- `tests/v.bh-9-test.sh`
EOF
change docs/notes/n.md bin/x.sh catalog/c.tsv; commit
check
clean B2

# B3 conditional lines are exempt
new_repo b3
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.
- `bin/lib/flaky.sh`: only if the probe fails.
- `catalog/c.tsv` (optional): a row.
- `rules/r.md`: if needed.
EOF
change bin/x.sh; commit
check
clean B3

# B4 R1 is named, the file has R10 only: grep -w keeps them apart
new_repo b4
plan <<'EOF'
## Files to touch

- `tests/x.bh-1-test.sh`: add case R1.
EOF
mkdir -p "$R/tests"; echo 'R10: a case' > "$R/tests/x.bh-1-test.sh"; commit
check
rc_is B4 1
has B4 "case-missing tests/x.bh-1-test.sh $PLANP:$(lno 'add case R1') — case R1 "
lines B4 1

# B5 D41 is not an ID; no add verb is not judged; a tests/ path not in the
#    diff gets planned-not-changed and no case-missing
new_repo b5
plan <<'EOF'
## Files to touch

- `tests/x.bh-1-test.sh`: add case R2, per D41.
- `tests/t.bh-1-test.sh`: edit the R9 wording.
- `tests/z.bh-1-test.sh` (NEW): cases Z1-Z3.
EOF
mkdir -p "$R/tests"; echo 'R2: a case' > "$R/tests/x.bh-1-test.sh"; change tests/t.bh-1-test.sh; commit
check
rc_is B5 1
has B5 "planned-not-changed tests/z.bh-1-test.sh $PLANP:$(lno 'tests/z.bh-1') — "
lines B5 1

# B6 a range over 60 and a task heading ID are not judged; `to`, `..` and
#    en-dash ranges expand
new_repo b6
plan <<'EOF'
## Files to touch

- `tests/x.bh-1-test.sh` (NEW): cases R1-R99, C1 to C3, K1..K2, E1–E2 and T2.

## Tasks

### T2. The suite
EOF
mkdir -p "$R/tests"; printf '%s\n' 'R1 a' 'C1 a' 'C2 b' 'C3 c' 'K1 a' 'K2 b' 'E1 a' 'E2 b' > "$R/tests/x.bh-1-test.sh"; commit
check
clean B6
printf '%s\n' 'R1 a' 'C1 a' 'C2 b' 'K1 a' 'E1 a' > "$R/tests/x.bh-1-test.sh"; commit
check
rc_is B6-red 1
has B6-red "case-missing tests/x.bh-1-test.sh $PLANP:$(lno 'cases R1-R99') — case C3 "
has B6-red "case-missing tests/x.bh-1-test.sh $PLANP:$(lno 'cases R1-R99') — case K2 "
has B6-red "case-missing tests/x.bh-1-test.sh $PLANP:$(lno 'cases R1-R99') — case E2 "
lines B6-red 3

# ── C: changed-not-planned edges ──────────────────────────────────────────
# C1 a path named in a task line; C2 a `:12` suffix; a validate line names too
new_repo c1
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

## Tasks

### T1
Edit `bin/lib/flaky.sh:12` as well, see [the note](docs/notes/a.md).
VALIDATE: `bash tests/t.bh-1-test.sh` exits 0.
EOF
change bin/x.sh bin/lib/flaky.sh tests/t.bh-1-test.sh; commit
check
clean C1-C2

# C3 a glob names what it matches; a broad glob in prose names nothing
new_repo c3
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

Every `bin/*.sh` script keeps its header. The table goes in
`worker/jobs/schema.d/<stamp>-bh-1-t.sql`.
EOF
change bin/x.sh bin/y.sh worker/jobs/schema.d/202610170000-bh-1-t.sql; commit
check
rc_is C3 1
has C3 "changed-not-planned bin/y.sh $PLANP — "
lines C3 1

# C4 docs/, rules/ and root files are outside the four roots
new_repo c4
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.
EOF
change bin/x.sh docs/notes/b.md rules/r.md README; commit
check
clean C4

# C5 tests/mc/expected-map.d/* is ignored by default; the knob turns it on
new_repo c5
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.
EOF
change bin/x.sh tests/mc/expected-map.d/x; commit
check
clean C5
run env PLAN_DIFF_BIND_IGNORE= bash "$PDB" --base origin/main "$R"
rc_is C5-knob 1
has C5-knob "changed-not-planned tests/mc/expected-map.d/x $PLANP — "

# C6 a 3-segment dir scope names its files; bin/lib/ in prose does not
new_repo c6
plan <<'EOF'
## Files to touch

- `worker/jobs/schema.d/`: a fragment.

A lib in bin/lib/ resolves its root from the env.
EOF
change worker/jobs/schema.d/q.sql bin/lib/flaky.sh; commit
check
rc_is C6 1
has C6 "changed-not-planned bin/lib/flaky.sh $PLANP — "
lines C6 1

# C7 a tests/ path named only in ## Verify (run, not edited)
new_repo c7
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

## Verify (run, not edited)

- `bash tests/t.bh-1-test.sh`
EOF
change bin/x.sh tests/t.bh-1-test.sh; commit
check
rc_is C7 1
has C7 "changed-not-planned tests/t.bh-1-test.sh $PLANP — "
lines C7 1

# C8 a catalog/ path named only under ## Sibling claims; a box path does not
#    name bin/x.sh; `$DIR/bin/lib/flaky.sh` does name flaky.sh
new_repo c8
plan <<'EOF'
## Design

Run /root/harness/bin/x.sh once. The suite names "$DIR/bin/lib/flaky.sh".

## Sibling claims (not touched)

- BH-9 holds `catalog/c.tsv`.

## Tasks

- T1. Nothing else.
EOF
change bin/x.sh bin/lib/flaky.sh catalog/c.tsv; commit
check
rc_is C8 1
has C8 "changed-not-planned bin/x.sh $PLANP — "
has C8 "changed-not-planned catalog/c.tsv $PLANP — "
lines C8 2

# ── K: class-claim ────────────────────────────────────────────────────────
# K1 a claim wrapped over two lines; the line is the first one
new_repo k1
plan <<'EOF'
## Files to touch

- `worker/jobs/src/routes/flags.js`: the route.

Scope. No path under bin/
or worker/ changes.
EOF
change worker/jobs/src/routes/flags.js; commit
check
rc_is K1 1
has K1 "class-claim worker/jobs/src/routes/flags.js $PLANP:$(lno 'Scope.') — "
lines K1 1

# K2 "Nothing in `tests/` is edited." with a tests/ path in the diff
new_repo k2
plan <<'EOF'
## Files to touch

- `tests/t.bh-1-test.sh`: one case.

Nothing in `tests/` is edited.
EOF
change tests/t.bh-1-test.sh; commit
check
rc_is K2 1
has K2 "class-claim tests/t.bh-1-test.sh $PLANP:$(lno 'Nothing in') — "
lines K2 1

# K3 quoted examples are not claims
new_repo k3
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

The ticket says "No path under bin/ changes" as an example.
The regex `no path under bin/ changes` is an example too.
A quoted 'No path under bin/ changes.' is not a claim.
The planner quotes “Nothing in bin/ is edited.” too.
EOF
change bin/x.sh; commit
check
clean K3

# K4 conditionals, exceptions and a verb not at sentence end
new_repo k4
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

If no path under bin/ changes, skip the section.
No path under bin/ changes except `bin/x.sh`.
No path under bin/ changes its exit code.
When nothing in bin/ is edited, stop.
EOF
change bin/x.sh; commit
check
clean K4

# K5 a claim the diff keeps (docs only); the planner prompt wording
new_repo k5
plan <<'EOF'
## Files to touch

- `docs/notes/a.md`: the note.

No path under bin/ changes.
EOF
change docs/notes/a.md; commit
check
clean K5
new_repo k5b
plan <<'EOF'
## Files to touch

- `bin/x.sh`: x.

If this plan changes a path under bin/, list it under Files to touch.
EOF
change bin/x.sh; commit
check
clean K5-prompt

# ── S: plan selection and rc 2 ────────────────────────────────────────────
# S1 no plan in the diff
new_repo s1
change bin/x.sh; commit
check
clean S1
grep -qF 'plan-diff-bind: skip (no plan in this diff)' <<<"$ERR" && ok || bad "S1 stderr [$ERR] (want the skip note)"

# S2 two plans (a merge-queue batch)
new_repo s2
plan <<'EOF'
## Files to touch

- `worker/jobs/src/routes/flags.js`: never changed.
EOF
mkdir -p "$R/.harness/specs/BH-2"; cp "$R/$PLANP" "$R/.harness/specs/BH-2/plan.md"
change bin/x.sh; commit
check
clean S2
grep -qF 'plan-diff-bind: skip (2 plans in this diff)' <<<"$ERR" && ok || bad "S2 stderr [$ERR] (want the 2-plans note)"

# S3 the plan deleted at HEAD
new_repo s3
plan <<'EOF'
## Files to touch

- `worker/jobs/src/routes/flags.js`: never changed.
EOF
commit base2; rd_git "$R" update-ref refs/remotes/origin/main HEAD
rm "$R/$PLANP"; change bin/x.sh; commit
check
clean S3
grep -qF 'skip (no plan in this diff)' <<<"$ERR" && ok || bad "S3 stderr [$ERR] (want the skip note)"

# S4 a requirements.md and no plan.md; a plan one level too deep
new_repo s4
mkdir -p "$R/.harness/specs/BH-1/old"
echo '- `worker/jobs/src/routes/flags.js`' > "$R/.harness/specs/BH-1/requirements.md"
printf '## Files to touch\n\n- `worker/jobs/src/routes/flags.js`: x.\n' > "$R/.harness/specs/BH-1/old/plan.md"
change bin/x.sh; commit
check
clean S4

# S5 the plan is on the base and this diff does not change it
new_repo s5
plan <<'EOF'
## Files to touch

- `worker/jobs/src/routes/flags.js`: never changed.
EOF
commit base2; rd_git "$R" update-ref refs/remotes/origin/main HEAD
change bin/x.sh; commit
check
clean S5

# S6 rc 2: a base that does not resolve, a stray argument, the sourced lib
#    called with no base
new_repo s6
change bin/x.sh; commit
run bash "$PDB" --base no-such-ref "$R"
rc_is S6 2
grep -qF 'cannot resolve base no-such-ref' <<<"$ERR" && ok || bad "S6 stderr [$ERR] (want the base reason)"
run bash "$PDB" --base origin/main "$R" extra
rc_is S6-arg 2
run bash -c '. "$1" && pdb_check "$2" ""' _ "$PDB" "$R"
rc_is S6-lib 2

# ── P1: the rules pack, the entry point the prepush gate and CI run ───────
# The fixture is this checkout's HEAD with the working rules-pack files laid
# over it, so the case means the same thing before and after the commit.
F="$T/fx"
mkdir -p "$F"
git -C "$DIR" archive HEAD | tar -x -C "$F" || { echo "FAIL: cannot archive HEAD"; exit 1; }
for p in bin/lib/plan-diff-bind.sh bin/rules-pack.sh catalog/rules-pack.tsv; do
  [ -f "$DIR/$p" ] && cp -p "$DIR/$p" "$F/$p"
done
rd_fixture_repo "$F" >/dev/null || { echo "FAIL: cannot build the P1 fixture"; exit 1; }
rd_git "$F" config gc.auto 0; rd_git "$F" config maintenance.auto false
FB=$(rd_git "$F" rev-parse HEAD)
mkdir -p "$F/.harness/specs/BH-1" "$F/docs/notes"
printf '%s\n' '## Files to touch' '' '- `docs/notes/p1.md`: the note.' '- `worker/jobs/src/routes/flags.js`: the route.' > "$F/$PLANP"
echo p1 > "$F/docs/notes/p1.md"
rd_git "$F" add -A && rd_git "$F" commit -qm P1
mkdir -p "$T/nolg"
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only plan-diff-bind --runner local --out "$T/o1"
rc_is P1 1
[ "$OUT" = "plan-diff-bind: planned-not-changed worker/jobs/src/routes/flags.js $PLANP:4 — the plan names this path as edited and the diff does not change it; edit the path, or fix the plan line (mark it verify-only: if it is only run)" ] \
  && ok || bad "P1 stdout [$OUT] (want the one routed planned-not-changed line)"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o1/summary.json" 2>/dev/null)" = "plan-diff-bind red" ] && ok \
  || bad "P1 summary.json components[0] $(jq -c '.components[0]' "$T/o1/summary.json" 2>/dev/null) (want plan-diff-bind red)"

# P1-many: 12 findings all reach stdout. Without the plan-diff-bind arm in
# rp_extract the pack keeps only the last 10 lines of the output.
{ printf '%s\n' '## Files to touch' '' '- `docs/notes/p1.md`: the note.'
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do printf -- '- `bin/p1-%s.sh`: never changed.\n' "$i"; done
} > "$F/$PLANP"
rd_git "$F" add -A && rd_git "$F" commit -qm P1-many
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only plan-diff-bind --runner local --out "$T/o3"
rc_is P1-many 1
lines P1-many 12
has P1-many "plan-diff-bind: planned-not-changed bin/p1-01.sh $PLANP:4 — "
has P1-many "plan-diff-bind: planned-not-changed bin/p1-12.sh $PLANP:15 — "

rd_git "$F" reset -q --hard "$FB"
mkdir -p "$F/.harness/specs/BH-1" "$F/docs/notes"
printf '%s\n' '## Files to touch' '' '- `docs/notes/p1.md`: the note.' > "$F/$PLANP"
echo p1 > "$F/docs/notes/p1.md"
rd_git "$F" add -A && rd_git "$F" commit -qm P1-green
run env HARNESS="$T/nolg" HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/rules-pack.sh" --tree "$F" --base "$FB" \
  --only plan-diff-bind --runner local --out "$T/o2"
rc_is P1-green 0
[ -z "$OUT" ] && ok || bad "P1-green stdout [$OUT] (want empty)"
[ "$(jq -r '.components[0].id + " " + .components[0].state' "$T/o2/summary.json" 2>/dev/null)" = "plan-diff-bind green" ] && ok \
  || bad "P1-green summary.json components[0] $(jq -c '.components[0]' "$T/o2/summary.json" 2>/dev/null) (want plan-diff-bind green)"

echo "plan-diff-bind: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
