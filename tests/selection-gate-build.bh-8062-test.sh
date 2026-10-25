#!/bin/bash
# tests/selection-gate-build.bh-8062-test.sh — BH-8062 T3: the build runs the
# selection gate before the PR opens (bin/lib/selection-gate.sh, called by the
# `# >>> selection gate (BH-8062)` block of bin/lib/rb/pr.sh). A red gate ends
# the build GATE_RED with the suites named, posts one board comment, and no PR
# opens. Otherwise the record rides in the PR body for the lead review.
#
# The checkout is a scratch git repo whose bin/selection-gate.sh is a stub that
# writes gate.txt in the real script's format; GitHub is a stub gh and a stub
# gh_rest_comment. No network.
#
#   P1  D2: the REAL pr.sh block, red: exit 6, RESULT GATE_RED, no `pr create`
#   P2  D2: the real block, green: the push and `pr create` are reached, the
#       marker is in PREPR_SECTION (what PR_BODY_FOR renders into the body)
#   R1  red: rc 6, RESULT `GATE_RED 1 red: tests/x.sh; see …/gate.txt`, one
#       comment naming the suite, $BUILD/gate.txt, the RESULT carries the
#       builder-direct marker
#   R2  a second sg_notice posts nothing
#   R3  red, direct path off: RESULT with no marker, no comment
#   G1  green: no RESULT, SG_MARKER = the exact record, rc 0
#   G2  could-not-run: no RESULT, the marker says rc=could-not-run
#   G3  no-selection: the marker says rc=no-selection
#   K1  SELECTION_GATE=0: the script is not run, an rc=off marker
#   K2  no bin/selection-gate.sh in the checkout: skipped, rc 0, no marker
#   K3  the timeout and -P knobs reach the script; their fallbacks 2400 and 12
#   F1  SELECTION_GATE_FIX_ROUNDS=1: one CC fix turn, then the gate again
#   F2  SELECTION_GATE_FIX_ROUNDS unset: CC is never called
#   L1  the SELECTION-GATE log line's rc equals gate.txt's rc
#   T1  round trip: sg_marker's record → lr_gate_record → ok (the checkout's
#       base carries bin/selection-gate.sh, so the r3 F1 check applies)
#   N1  r3 F4: two could-not-run builds on one UTC day write exactly one
#       ALERTS line (through bin/alert-line.sh) naming the host and the why
#   N2  a green build writes none; SELECTION_GATE_CNR_ALERT=0 writes none and
#       leaves no day marker
#   N3  a day marker older than SELECTION_GATE_CNR_KEEP_DAYS is deleted
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-build.bh-8062-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: N2 and N3 read the UTC day stamp that sg_cnr_alert wrote; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LIB="$DIR/bin/lib/selection-gate.sh"
PRSH="$DIR/bin/lib/rb/pr.sh"
GR="$DIR/bin/lib/lead-review/gate-record.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/selection-gate.sh is missing"; exit 1; }
[ -r "$DIR/bin/selection-gate.sh" ] || bad "setup: bin/selection-gate.sh is missing"

# The harness: the lib's closure, and a fleet-conf stub (demo-os is a
# GitHub-Issues board).
HH="$T/h"; mkdir -p "$HH/bin"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
cat > "$HH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo - ;; repo) echo example-org/demo-os ;; *) exit 1 ;; esac
SH
chmod +x "$HH/bin/fleet-conf.sh"

# The checkout, with the stub gate. $STUB_DIR/mode is green|red|cnr|nosel;
# every run appends its argv to $STUB_DIR/argv.
CO="$T/co"; mkdir -p "$CO/bin"
cat > "$CO/bin/selection-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/argv"
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
mkdir -p "$out"; h=$(git rev-parse HEAD)
case "$(cat "$STUB_DIR/mode")" in
  green) rc=0 red=- why=- e=0 ;;
  red)   rc=1 red=tests/x.sh why=- e=1 ;;
  cnr)   rc=could-not-run red=- why=runner-rc-125 e=3 ;;
  nosel) rc=no-selection red=- why=empty-selection e=4 ;;
esac
printf 'head: %s\nbase: %s\nsuites: 5\nrc: %s\nred: %s\nnoted: -\nmode: batch-selected\nwhy: %s\nquarantine: env\n' "$h" "$h" "$rc" "$red" "$why" > "$out/gate.txt"
exit "$e"
SH
chmod +x "$CO/bin/selection-gate.sh"
git -C "$CO" init -q -b main; git -C "$CO" -c user.email=t@example.com -c user.name=t add -A
git -C "$CO" -c user.email=t@example.com -c user.name=t commit -qm base
HEADSHA=$(git -C "$CO" rev-parse HEAD)
git -C "$CO" update-ref refs/remotes/origin/main HEAD
NOGATE="$T/nogate"; mkdir -p "$NOGATE"

# case_env <case> <mode> — a fresh build dir and stub dir.
case_env() {
  C="$T/c/$1"; mkdir -p "$C/build" "$C/stub"; : > "$C/stub/argv"; : > "$C/stub/comments"; : > "$C/stub/gh"
  printf '%s\n' "$2" > "$C/stub/mode"
}
# lib <case> <mode> <checkout> [VAR=value …] — sg_block in a subshell, from the
# checkout; sinks: $C/rc, $C/build/RESULT, $C/marker, $C/stub/comments.
lib() {
  local c="$1" m="$2" co="$3"; shift 3
  case_env "$c" "$m"
  ( cd "$co" || exit 99
    env -u SELECTION_GATE -u SELECTION_GATE_TIMEOUT_S -u SELECTION_GATE_P -u SELECTION_GATE_FIX_ROUNDS \
      HARNESS="$HH" STUB_DIR="$C/stub" BUILD="$C/build" PROJECT=demo-os KEY=BH-7 TICKET=7 BASE=main \
      BUILDER_DIRECT_ON=1 JOBS_URL='' "$@" bash -c '
      STAMP() { echo 2026-10-24T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      gh_rest_comment() { { echo "== $1#$2"; cat "$3"; } >> "$STUB_DIR/comments"; }
      [ -n "${WITH_CC:-}" ] && CC() { printf "%s\n" "$1" >> "$STUB_DIR/cc"; echo green > "$STUB_DIR/mode"; }
      . "$1" || exit 98
      sg_block; rc=$?
      echo "$rc" > "$STUB_DIR/rc"; printf "%s" "$SG_MARKER" > "$STUB_DIR/marker"
      if [ "${NOTICE_AGAIN:-}" = 1 ]; then sg_notice; echo "$?" > "$STUB_DIR/rc2"; fi' _ "$LIB"
  ) > "$C/out" 2>&1
}
res() { cat "$T/c/$1/build/RESULT" 2>/dev/null; }
mark() { cat "$T/c/$1/stub/marker" 2>/dev/null; }
rcof() { cat "$T/c/$1/stub/rc" 2>/dev/null; }
ncomments() { grep -c '^== ' "$T/c/$1/stub/comments" 2>/dev/null; }

# ── R1/R2: red ───────────────────────────────────────────────────────────────
lib r1 red "$CO" NOTICE_AGAIN=1
[ "$(rcof r1)" = 6 ] && ok || bad "R1 red: sg_block returns 6 (got '$(rcof r1)'; $(cat "$T/c/r1/out"))"
case "$(res r1)" in "GATE_RED 1 red: tests/x.sh; see $T/c/r1/build/gate.txt"*) ok ;; *) bad "R1 RESULT GATE_RED names the suite (got '$(res r1)')" ;; esac
[ "$(ncomments r1)" = 1 ] && grep -q '^== example-org/demo-os#7$' "$T/c/r1/stub/comments" && grep -qF 'tests/x.sh' "$T/c/r1/stub/comments" \
  && ok || bad "R1 one comment on demo-os#7 that names tests/x.sh ($(cat "$T/c/r1/stub/comments"))"
grep -qF 'We did not open a PR' "$T/c/r1/stub/comments" && ok || bad "R1 the comment says no PR opened"
[ -s "$T/c/r1/build/gate.txt" ] && grep -qx 'red: tests/x.sh' "$T/c/r1/build/gate.txt" && ok || bad "R1 \$BUILD/gate.txt is the gate's record"
( . "$HH/bin/lib/builder-direct.sh" 2>/dev/null; bd_closed_out "$(res r1)" ) && ok || bad "R1 the RESULT carries the builder-direct marker, so the sweep does not post again ($(res r1))"
[ -z "$(mark r1)" ] && ok || bad "R1 a red sets no marker"
[ "$(cat "$T/c/r1/stub/rc2" 2>/dev/null)" = 3 ] && [ "$(ncomments r1)" = 1 ] && ok || bad "R2 a second sg_notice posts nothing (rc $(cat "$T/c/r1/stub/rc2" 2>/dev/null), $(ncomments r1) comments)"

# ── R3: red, the direct path off ─────────────────────────────────────────────
lib r3 red "$CO" BUILDER_DIRECT_ON=0
[ "$(rcof r3)" = 6 ] && [ "$(ncomments r3)" = 0 ] && ok || bad "R3 direct off: rc 6, no comment"
( . "$HH/bin/lib/builder-direct.sh" 2>/dev/null; ! bd_closed_out "$(res r3)" ) && case "$(res r3)" in "GATE_RED 1 red: tests/x.sh; see "*) true ;; *) false ;; esac \
  && ok || bad "R3 the RESULT has no builder-direct marker, so the sweep posts it ($(res r3))"

# ── G1-G3: green, could-not-run, no-selection ────────────────────────────────
lib g1 green "$CO"
[ "$(rcof g1)" = 0 ] && [ -z "$(res g1)" ] && ok || bad "G1 green: rc 0, no RESULT ($(rcof g1) / $(res g1))"
[ "$(mark g1)" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=0 -->" ] && ok || bad "G1 the marker (got '$(mark g1)')"
lib g2 cnr "$CO"
[ "$(rcof g2)" = 0 ] && [ -z "$(res g2)" ] && [ "$(mark g2)" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=could-not-run -->" ] \
  && ok || bad "G2 could-not-run: no RESULT, marker rc=could-not-run (got '$(mark g2)' / '$(res g2)')"
lib g3 nosel "$CO"
[ "$(mark g3)" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=no-selection -->" ] && ok || bad "G3 no-selection marker (got '$(mark g3)')"

# ── K1-K3: the switch, other repos, the knobs ────────────────────────────────
lib k1 red "$CO" SELECTION_GATE=0
[ ! -s "$T/c/k1/stub/argv" ] && [ "$(rcof k1)" = 0 ] && [ -z "$(res k1)" ] \
  && [ "$(mark k1)" = "<!-- selection-gate: head=$HEADSHA suites=0 rc=off -->" ] && ok || bad "K1 SELECTION_GATE=0: not run, rc 0, an rc=off marker (got '$(mark k1)')"
grep -q 'SELECTION-GATE off (SELECTION_GATE=0), record rc=off' "$T/c/k1/build/pipeline.log" && ok || bad "K1 one log line says off"
lib k2 red "$NOGATE"
[ "$(rcof k2)" = 0 ] && [ -z "$(mark k2)" ] && [ -z "$(res k2)" ] && grep -q 'SELECTION-GATE skipped (repo carries no bin/selection-gate.sh)' "$T/c/k2/build/pipeline.log" \
  && ok || bad "K2 a checkout with no gate: skipped, rc 0"
grep -q -- '--timeout 2400 -P 12$' "$T/c/g1/stub/argv" && grep -q -- "--tree . --base main --out $T/c/g1/build/selection-gate" "$T/c/g1/stub/argv" \
  && ok || bad "K3 the fallbacks 2400 and 12, the tree and base ($(cat "$T/c/g1/stub/argv"))"
lib k3 green "$CO" SELECTION_GATE_TIMEOUT_S=900 SELECTION_GATE_P=4
grep -q -- '--timeout 900 -P 4$' "$T/c/k3/stub/argv" && ok || bad "K3 the knobs reach the script ($(cat "$T/c/k3/stub/argv"))"

# ── F1/F2: the fix round ─────────────────────────────────────────────────────
lib f1 red "$CO" SELECTION_GATE_FIX_ROUNDS=1 WITH_CC=1
[ "$(grep -c . "$T/c/f1/stub/cc" 2>/dev/null)" = 1 ] && [ "$(grep -c . "$T/c/f1/stub/argv")" = 2 ] && [ "$(rcof f1)" = 0 ] && [ -z "$(res f1)" ] \
  && ok || bad "F1 one fix turn, the gate runs again, green goes on (cc $(grep -c . "$T/c/f1/stub/cc" 2>/dev/null), runs $(grep -c . "$T/c/f1/stub/argv"), rc $(rcof f1))"
lib f2 red "$CO" WITH_CC=1
[ ! -s "$T/c/f2/stub/cc" ] && [ "$(rcof f2)" = 6 ] && ok || bad "F2 no fix round by default"

# ── L1: the log line is the record's rc ──────────────────────────────────────
grep -q 'SELECTION-GATE rc=1 suites=5 red=tests/x.sh exit=1' "$T/c/r1/build/pipeline.log" \
  && grep -q 'SELECTION-GATE rc=could-not-run suites=5 red=- exit=3' "$T/c/g2/build/pipeline.log" \
  && ok || bad "L1 the SELECTION-GATE line carries gate.txt's rc ($(cat "$T/c/r1/build/pipeline.log" "$T/c/g2/build/pipeline.log"))"

# ── P1/P2: the real pr.sh block (D2) ─────────────────────────────────────────
sed -n '/^# >>> selection gate (BH-8062)$/,/^# <<< selection gate$/p' "$PRSH" > "$T/block.sh"
grep -q 'sg_block' "$T/block.sh" && ok || bad "P setup: the pr.sh block is present and calls sg_block"
# blk <case> <mode> — the block, then the stand-ins for the push and the create.
blk() {
  case_env "$1" "$2"
  ( cd "$CO" || exit 99
    env -u SELECTION_GATE HARNESS="$HH" STUB_DIR="$C/stub" BUILD="$C/build" PROJECT=demo-os KEY=BH-7 TICKET=7 BASE=main \
      BUILDER_DIRECT_ON=1 JOBS_URL='' bash -c '
      STAMP() { echo 2026-10-24T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      gh_rest_comment() { { echo "== $1#$2"; cat "$3"; } >> "$STUB_DIR/comments"; }
      gh() { printf "%s\n" "$*" >> "$STUB_DIR/gh"; }
      PREPR_SECTION=""
      . "$1"
      gh pr create --head ticket/bh-7 --base main
      printf "%s" "$PREPR_SECTION" > "$STUB_DIR/prepr"' _ "$T/block.sh"
    echo "$?" > "$C/stub/rc"
  ) > "$C/out" 2>&1
}
blk p1 red
[ "$(rcof p1)" = 6 ] && ok || bad "P1 the real block exits 6 on red (got $(rcof p1); $(cat "$T/c/p1/out"))"
! grep -q '^pr create' "$T/c/p1/stub/gh" && ok || bad "P1 no gh pr create on red ($(cat "$T/c/p1/stub/gh"))"
case "$(res p1)" in "GATE_RED 1 red: tests/x.sh"*) ok ;; *) bad "P1 RESULT GATE_RED (got '$(res p1)')" ;; esac
[ "$(ncomments p1)" = 1 ] && grep -qF tests/x.sh "$T/c/p1/stub/comments" && ok || bad "P1 one board comment names the suite"
blk p2 green
[ "$(rcof p2)" = 0 ] && grep -q '^pr create ' "$T/c/p2/stub/gh" && ok || bad "P2 green reaches gh pr create (rc $(rcof p2); $(cat "$T/c/p2/out"))"
grep -qxF "<!-- selection-gate: head=$HEADSHA suites=5 rc=0 -->" "$T/c/p2/stub/prepr" && ok || bad "P2 the marker is in PREPR_SECTION ($(cat "$T/c/p2/stub/prepr" 2>/dev/null))"

# ── T1: the round trip to the lead review's reader ───────────────────────────
if [ -r "$GR" ]; then
  GOT=$( . "$GR" && lr_gate_record "Body text.
$(mark g1)
" "$HEADSHA" ticket/bh-7 block "$CO" main )
  [ "$GOT" = "ok 5 0" ] && ok || bad "T1 lr_gate_record reads sg_marker's record as ok (got '$GOT')"
else
  bad "T1 bin/lib/lead-review/gate-record.sh is missing"
fi

# ── N1-N3: one could-not-run alert per box per UTC day (r3, F4) ──────────────
cat > "$HH/bin/alert-line.sh" <<'SH'
#!/bin/bash
[ "$1" = --id ] && shift 2
mkdir -p "$HARNESS/logs"; echo "2026-10-24 00:00:00Z $*" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$HH/bin/alert-line.sh"
reset_alerts() { scratch_rm "$HH/state/selection-gate"; scratch_rm "$HH/logs/ALERTS.log"; }
nalerts() { cat "$HH/logs/ALERTS.log" 2>/dev/null | grep -c 'SELECTION GATE COULD NOT RUN'; }
reset_alerts
lib n2 green "$CO"
[ "$(nalerts)" = 0 ] && ok || bad "N2 a green build writes no alert ($(nalerts))"
lib n2b cnr "$CO" SELECTION_GATE_CNR_ALERT=0
[ "$(nalerts)" = 0 ] && [ ! -d "$HH/state/selection-gate/cnr-$(date -u +%Y%m%d)" ] && ok || bad "N2 knob 0: no alert, no marker ($(nalerts))"
mkdir -p "$HH/state/selection-gate/cnr-20000101"; touch -d '30 days ago' "$HH/state/selection-gate/cnr-20000101"
lib n1 cnr "$CO"
lib n1b cnr "$CO"
[ "$(nalerts)" = 1 ] && ok || bad "N1 two could-not-run builds on one day: one alert (got $(nalerts): $(cat "$HH/logs/ALERTS.log" 2>/dev/null))"
grep -q "SELECTION GATE COULD NOT RUN on $(hostname): runner-rc-125\. Builds open PRs with no pre-PR selection run; the batch is the only check\." "$HH/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "N1 the alert names the host and the why ($(cat "$HH/logs/ALERTS.log" 2>/dev/null))"
[ "$(rcof n1)" = 0 ] && [ "$(rcof n1b)" = 0 ] && [ "$(mark n1b)" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=could-not-run -->" ] \
  && ok || bad "N1 the alert does not stop the build or its record"
[ ! -e "$HH/state/selection-gate/cnr-20000101" ] && [ -d "$HH/state/selection-gate/cnr-$(date -u +%Y%m%d)" ] && ok || bad "N3 the old day marker is pruned, today's stays"

echo "selection-gate-build.bh-8062: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
