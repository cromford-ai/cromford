#!/bin/bash
# tests/selection-gate-host-notes.bh-9047-test.sh — BH-9047 r6: the two
# host-only reds of the pre-PR selection gate get host-note rows
# (catalog/selection-gate-host-notes.d/bh-9047.tsv, the BH-8725 seam).
#
# THE CASE. r4 and r5 stopped at the gate (GATE_RED) on two suites that are
# red only on the test host:
#   - tests/lead-review-libs.bh-7455-test.sh S2 reads the commit before
#     0010-llm-gate.sh from git history; a shallow or snapshot context does not
#     hold it (4 `FAIL: S2:` lines, `130 passed, 4 failed`).
#   - tests/context-kill-lanes.bh-2309-test.sh case C races a stub against a
#     1 s context-kill poll; a loaded host lets the stub finish first (6
#     `FAIL: C:` lines, `51 pass, 6 fail`). Main eb5b44789 shows the same red.
#
# PINNED. The REAL bin/selection-gate.sh runs with a stub planner and a stub
# runner that prints a fixture as the run output. No network.
#   N1 each real fixture is noted: rc 0, red -, host-noted <suite>=<class>
#   N2 near misses stay red: an extra `FAIL: S5:` line, only `FAIL: S3:` lines,
#      a `5 failed` summary over 4 S2 lines, an extra `FAIL: B:` line in
#      context-kill-lanes, the C lines under the lead-review-libs name
#   N3 every bh-9047 row loads with no skipped line, and its ERE matches at
#      least one FAIL line of its fixture
#   N4 the S2 lines under tests/lead-review-libs.bh-9999-test.sh stay red
#
# Fixtures (tests/fixtures/selection-gate-host-notes.bh-9047/), each inside a
# remote-gate section:
#   lead-review-libs.run.txt: the real output of `HARNESS_TEST_SANDBOX=1 bash
#     tests/lead-review-libs.bh-7455-test.sh` in a `git clone --depth 30` of
#     main eb5b44789 (2026-11-07).
#   context-kill-lanes.run.txt: the real output of `HARNESS_TEST_SANDBOX=1 bash
#     tests/context-kill-lanes.bh-2309-test.sh` on main eb5b44789 under load
#     (2026-11-07). The cost row is cut after its first 3 fields, and its box
#     name is scrubbed to fixture-box.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-host-notes.bh-9047-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
SG="$DIR/bin/selection-gate.sh"
NOTES="$DIR/catalog/selection-gate-host-notes.d/bh-9047.tsv"
FX="$DIR/tests/fixtures/selection-gate-host-notes.bh-9047"
LRL=tests/lead-review-libs.bh-7455-test.sh
CKL=tests/context-kill-lanes.bh-2309-test.sh
[ -x "$SG" ] || { echo "FAIL: bin/selection-gate.sh is missing"; exit 1; }
[ -r "$NOTES" ] || bad "setup: $NOTES is missing"
[ -r "$FX/lead-review-libs.run.txt" ] && [ -r "$FX/context-kill-lanes.run.txt" ] || bad "setup: a fixture is missing"

# ── the scratch repo, with only the bh-9047 notes ────────────────────────────
R="$T/repo"; mkdir -p "$R/catalog/selection-gate-host-notes.d"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; echo a > "$R/a.txt"; g add -A; g commit -qm base
g checkout -q -b ticket/bh-9047; echo b > "$R/b.txt"
[ -r "$NOTES" ] && cp "$NOTES" "$R/catalog/selection-gate-host-notes.d/"
g add -A; g commit -qm change
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' "$STUB_SUITES" > "$out"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
cat "$STUB_FILE"
exit 1
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
# run <case> <suite> <run file> — one REAL bin/selection-gate.sh.
run() {
  mkdir -p "$T/$1"
  env -u CI_QUARANTINE -u SELECTION_GATE_WHY_MAX -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S \
    -u SELECTION_GATE_BASELINE_RESERVE_PAD_S -u SELECTION_GATE_MAIN_TIMEOUT_MIN_S \
    HARNESS="$T/no-harness" REPO_SLUG= SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    STUB_SUITES="$2" STUB_FILE="$3" \
    bash "$SG" --tree "$R" --base main --out "$T/$1/out" --timeout 60 > "$T/$1/stdout" 2> "$T/$1/stderr"
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
# red_ok <case> <suite> <what> — the gate keeps <suite> red.
red_ok() {
  [ "$RC" = 1 ] && [ "$(gv "$1" red)" = "$2" ] && [ "$(gv "$1" host-noted)" = - ] && ok \
    || bad "$3 stays red (exit $RC; $(cat "$T/$1/out/gate.txt" 2>/dev/null); $(cat "$T/$1/stderr"))"
}

# ── N1: the real fixtures are noted ──────────────────────────────────────────
run n1a "$LRL" "$FX/lead-review-libs.run.txt"
[ "$RC" = 0 ] && [ "$(gv n1a rc)" = 0 ] && [ "$(gv n1a red)" = - ] && [ "$(gv n1a host-noted)" = "$LRL=shallow-context" ] && ok \
  || bad "N1 lead-review-libs S2 is noted shallow-context (exit $RC; $(cat "$T/n1a/out/gate.txt" 2>/dev/null); $(cat "$T/n1a/stderr"))"
run n1b "$CKL" "$FX/context-kill-lanes.run.txt"
[ "$RC" = 0 ] && [ "$(gv n1b rc)" = 0 ] && [ "$(gv n1b red)" = - ] && [ "$(gv n1b host-noted)" = "$CKL=host-timing" ] && ok \
  || bad "N1 context-kill-lanes C is noted host-timing (exit $RC; $(cat "$T/n1b/out/gate.txt" 2>/dev/null); $(cat "$T/n1b/stderr"))"

# ── N2: near misses stay red ─────────────────────────────────────────────────
S5='FAIL: S5: bin/lib/lead-review/libs.d/ sources 27 libs, want 28'
awk -v x="$S5" '{ print } /^FAIL: S2: cannot read/ { print x }' "$FX/lead-review-libs.run.txt" \
  | sed 's/130 passed, 4 failed/130 passed, 5 failed/' > "$T/n2a.run"
[ "$(grep -c '^FAIL: ' "$T/n2a.run")" = 5 ] && ok || bad "N2 setup: the S5 line is in the section"
run n2a "$LRL" "$T/n2a.run"; red_ok n2a "$LRL" "N2 an extra S5 line"
sed 's/^FAIL: S2: /FAIL: S3: /' "$FX/lead-review-libs.run.txt" > "$T/n2b.run"
run n2b "$LRL" "$T/n2b.run"; red_ok n2b "$LRL" "N2 only S3 lines"
sed 's/130 passed, 4 failed/130 passed, 5 failed/' "$FX/lead-review-libs.run.txt" > "$T/n2c.run"
grep -q '5 failed' "$T/n2c.run" && ok || bad "N2 setup: the summary says 5 failed"
run n2c "$LRL" "$T/n2c.run"; red_ok n2c "$LRL" "N2 a 5 failed summary over 4 S2 lines"
awk '{ print } /^FAIL: C: an over-budget/ { print "FAIL: B: the under-budget call was cut short" }' "$FX/context-kill-lanes.run.txt" > "$T/n2d.run"
[ "$(grep -c '^FAIL: ' "$T/n2d.run")" = 7 ] && ok || bad "N2 setup: the B line is in the section"
run n2d "$CKL" "$T/n2d.run"; red_ok n2d "$CKL" "N2 an extra B line in context-kill-lanes"
sed "s|$CKL|$LRL|g" "$FX/context-kill-lanes.run.txt" > "$T/n2e.run"
run n2e "$LRL" "$T/n2e.run"; red_ok n2e "$LRL" "N2 the C lines under the lead-review-libs name"

# ── N3: every row loads and matches its fixture ──────────────────────────────
N3=$( TREE="$R"; OUT="$T/n3"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2> "$T/n3.err"
  for i in "${!HN_SUITE[@]}"; do
    case "${HN_SUITE[$i]}" in "$LRL") f="$FX/lead-review-libs.run.txt" ;; "$CKL") f="$FX/context-kill-lanes.run.txt" ;; *) echo "unknown ${HN_SUITE[$i]}"; continue ;; esac
    if grep -qE -- "${HN_ERE[$i]}" <<<"$(grep -E '(^|[[:space:]])FAIL[: ]' "$f")"; then echo "match ${HN_SUITE[$i]}"; else echo "nomatch ${HN_SUITE[$i]}"; fi
  done )
NROWS=$(grep -cv '^#' "$NOTES" 2>/dev/null)
[ "$NROWS" = 2 ] && [ "$N3" = "match $LRL
match $CKL" ] && [ ! -s "$T/n3.err" ] && ok \
  || bad "N3 every bh-9047 row parses and matches its fixture (rows $NROWS; got '$N3'; $(cat "$T/n3.err" 2>/dev/null))"
# The real tree loads the fragment with no skipped line too.
N3R=$( TREE="$DIR"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2>&1 >/dev/null | grep -F 'bh-9047.tsv' )
[ -z "$N3R" ] && ok || bad "N3 the real tree skips a bh-9047 row ($N3R)"

# ── N4: another suite name stays red ─────────────────────────────────────────
OTHER=tests/lead-review-libs.bh-9999-test.sh
sed "s|$LRL|$OTHER|g" "$FX/lead-review-libs.run.txt" > "$T/n4.run"
run n4 "$OTHER" "$T/n4.run"; red_ok n4 "$OTHER" "N4 the S2 lines under $OTHER"

echo "selection-gate-host-notes.bh-9047: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
