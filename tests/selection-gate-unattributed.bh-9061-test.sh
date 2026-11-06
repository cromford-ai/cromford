#!/bin/bash
# tests/selection-gate-unattributed.bh-9061-test.sh — BH-9061 slice C0: an
# unattributed red must not discard the build.
#
# THE BUG. The pre-PR selection gate went red on 27 of 38 gates on 2026-11-04,
# and in every one the base run (BH-8901) could not run: `baseline:
# could-not-run: timeout` (the main run took the whole --timeout, then the base
# run got its own bound on top of it). sg_block never read baseline:, so a red
# the gate could not attribute to the diff ended GATE_RED, rc 6, and the build
# was thrown away.
#
# PINNED. The REAL bin/lib/selection-gate.sh sg_block runs from a scratch
# checkout whose bin/selection-gate.sh is a stub that writes a given gate.txt;
# the REAL bin/selection-gate.sh runs with a stub planner and runner; the REAL
# lead-review gate-record lib reads the marker. No network.
#   U1 rc 1 + red + `baseline: could-not-run: timeout`: rc 0, no RESULT,
#      `unattributed:` in $BUILD/gate.txt, one log line, the marker
#      rc=could-not-run and a sentence that names the suite, no notice
#   U2 the same red with `baseline: ran 1 …`: rc 6, GATE_RED, no unattributed
#   U3 runner-rc-125, no-worktree (two suites), runner-failure: rc 0 each
#   U4 near misses (head-is-base, no baseline lines, leading space, substring,
#      red -): never unattributed
#   U5 U1's marker through the real lr_gate_record: ok 5 could-not-run
#   U6 one COULD NOT ATTRIBUTE alert per box per day; knob 0: none, no marker;
#      a could-not-run build that day still writes its own line
#   U7 the U1 run calls no gh and no curl
#   M1 baseline on: the main run gets TO - BTO - 60 (1440 of 2400)
#   M2 never under SELECTION_GATE_MAIN_TIMEOUT_MIN_S (300, or the knob), never
#      over --timeout
#   M3 baseline off: the whole --timeout; pad 0: TO - BTO
#   M4 the timeout verdict uses the main-run bound
#   H1 the bh-9061 row notes ci-durations-db on its real shallow-context output
#   H2 another failure line of that suite (alone or with it) stays red
#   H3 every bh-9061 row parses and matches a FAIL line of its fixture
#
# The fixture tests/fixtures/selection-gate-host-notes.bh-9061/ci-durations-db.run.txt
# is the real output of `HARNESS_TEST_SANDBOX=1 bash tests/ci-durations-db.bh-5653-test.sh`
# (rc 1) in the BH-9061 build worktree, where `git rev-parse
# --is-shallow-repository` answered `true`, inside a remote-gate section.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-unattributed.bh-9061-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: U6 reads the UTC day marker sg_cnr_alert writes; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
LIB="$DIR/bin/lib/selection-gate.sh"
SG="$DIR/bin/selection-gate.sh"
GR="$DIR/bin/lib/lead-review/gate-record.sh"
NOTES="$DIR/catalog/selection-gate-host-notes.d/bh-9061.tsv"
FIXRUN="$DIR/tests/fixtures/selection-gate-host-notes.bh-9061/ci-durations-db.run.txt"
CID=tests/ci-durations-db.bh-5653-test.sh
[ -r "$LIB" ] && [ -x "$SG" ] && [ -r "$GR" ] || { echo "FAIL: a file under test is missing"; exit 1; }
[ -r "$FIXRUN" ] || bad "setup: the ci-durations-db fixture is missing"

# ── the harness: the lib's closure, a fleet-conf stub, an alert-line stub ────
HH="$T/h"; mkdir -p "$HH/bin"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
cat > "$HH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in board_prefix) echo - ;; repo) echo example-org/demo-os ;; *) exit 1 ;; esac
SH
cat > "$HH/bin/alert-line.sh" <<'SH'
#!/bin/bash
[ "$1" = --id ] && shift 2
mkdir -p "$HARNESS/logs"; echo "2026-11-05 00:00:00Z $*" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$HH/bin/fleet-conf.sh" "$HH/bin/alert-line.sh"

# gh and curl shims: any call is logged (U7).
SHIMS="$T/shims"; mkdir -p "$SHIMS"
for b in gh curl; do printf '#!/bin/bash\necho "%s $*" >> "$NETLOG"\nexit 1\n' "$b" > "$SHIMS/$b"; done
chmod +x "$SHIMS"/*

# ── the checkout, with a stub gate ───────────────────────────────────────────
# $STUB_DIR/red, rc and exit hold the run's red list, rc field and exit code;
# $STUB_DIR/tail holds the lines after the 10 BH-8725 fields, verbatim.
CO="$T/co"; mkdir -p "$CO/bin"
cat > "$CO/bin/selection-gate.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
mkdir -p "$out"; h=$(git rev-parse HEAD)
printf 'head: %s\nbase: %s\nsuites: 5\nrc: %s\nred: %s\nnoted: -\nmode: batch-selected\nwhy: %s\nquarantine: env\nhost-noted: -\n' \
  "$h" "$h" "$(cat "$STUB_DIR/rc")" "$(cat "$STUB_DIR/red")" "$(cat "$STUB_DIR/why")" > "$out/gate.txt"
cat "$STUB_DIR/tail" >> "$out/gate.txt"
exit "$(cat "$STUB_DIR/exit")"
SH
chmod +x "$CO/bin/selection-gate.sh"
git -C "$CO" init -q -b main; git -C "$CO" -c user.email=t@example.com -c user.name=t add -A
git -C "$CO" -c user.email=t@example.com -c user.name=t commit -qm base
HEADSHA=$(git -C "$CO" rev-parse HEAD)
git -C "$CO" update-ref refs/remotes/origin/main HEAD

# lib <case> <rc> <red> <tail> [VAR=value …] — sg_block in a subshell from the
# checkout. <tail> is printf'd (so \n splits lines); exit 1 for rc 1, else 3.
lib() {
  local c="$1" r="$2" red="$3" tl="$4" e=1; shift 4
  [ "$r" = 1 ] || e=3
  C="$T/c/$c"; mkdir -p "$C/build" "$C/stub"
  : > "$C/stub/comments"; : > "$C/stub/net"
  printf '%s\n' "$r" > "$C/stub/rc"; printf '%s\n' "$red" > "$C/stub/red"; printf '%s\n' "$e" > "$C/stub/exit"
  if [ "$r" = could-not-run ]; then echo runner-rc-125 > "$C/stub/why"; else echo - > "$C/stub/why"; fi
  printf "$tl" > "$C/stub/tail"
  ( cd "$CO" || exit 99
    env -u SELECTION_GATE -u SELECTION_GATE_TIMEOUT_S -u SELECTION_GATE_P -u SELECTION_GATE_FIX_ROUNDS -u SELECTION_GATE_CNR_ALERT \
      PATH="$SHIMS:$PATH" NETLOG="$C/stub/net" \
      HARNESS="$HH" STUB_DIR="$C/stub" BUILD="$C/build" PROJECT=demo-os KEY=BH-7 TICKET=7 BASE=main \
      BUILDER_DIRECT_ON=1 JOBS_URL='' "$@" bash -c '
      STAMP() { echo 2026-11-05T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      gh_rest_comment() { { echo "== $1#$2"; cat "$3"; } >> "$STUB_DIR/comments"; }
      . "$1" || exit 98
      sg_block; rc=$?
      echo "$rc" > "$STUB_DIR/sgrc"; printf "%s" "$SG_MARKER" > "$STUB_DIR/marker"' _ "$LIB"
  ) > "$C/out" 2>&1
}
rcof() { cat "$T/c/$1/stub/sgrc" 2>/dev/null; }
res() { cat "$T/c/$1/build/RESULT" 2>/dev/null; }
mark() { cat "$T/c/$1/stub/marker" 2>/dev/null; }
ua() { sed -n 's/^unattributed: //p' "$T/c/$1/build/gate.txt" 2>/dev/null; }
ncomments() { grep -c '^== ' "$T/c/$1/stub/comments" 2>/dev/null; }
reset_alerts() { scratch_rm "$HH/state/selection-gate"; scratch_rm "$HH/logs/ALERTS.log"; }
DAY=$(date -u +%Y%m%d)
CNR_TO='baseline-red: -\nbaseline: could-not-run: timeout\n'

# ── U1: the live case ────────────────────────────────────────────────────────
reset_alerts
lib u1 1 tests/a.sh "$CNR_TO"
[ "$(rcof u1)" = 0 ] && ok || bad "U1 sg_block returns 0 on an unattributed red (got '$(rcof u1)'; $(cat "$T/c/u1/out"))"
[ -z "$(res u1)" ] && [ ! -e "$T/c/u1/build/RESULT" ] && ok || bad "U1 no RESULT (got '$(res u1)')"
[ "$(grep -c '^unattributed: ' "$T/c/u1/build/gate.txt" 2>/dev/null)" = 1 ] && [ "$(ua u1)" = tests/a.sh ] && ok \
  || bad "U1 \$BUILD/gate.txt has one 'unattributed: tests/a.sh' line ($(cat "$T/c/u1/build/gate.txt" 2>/dev/null))"
grep -qx 'rc: 1' "$T/c/u1/build/gate.txt" && grep -qx 'red: tests/a.sh' "$T/c/u1/build/gate.txt" && ok || bad "U1 rc: and red: keep the true run result"
UL=$(grep -c 'SELECTION-GATE unattributed=1 red=\[tests/a.sh\] baseline=could-not-run: timeout: the base run could not run, so the PR opens and the merge queue is the gate of record' "$T/c/u1/build/pipeline.log" 2>/dev/null)
[ "$UL" = 1 ] && ok || bad "U1 one SELECTION-GATE unattributed= log line (got $UL; $(cat "$T/c/u1/build/pipeline.log" 2>/dev/null))"
M1L=$(mark u1 | sed -n 1p); M2L=$(mark u1 | sed -n 2p)
[ "$M1L" = "<!-- selection-gate: head=$HEADSHA suites=5 rc=could-not-run -->" ] && ok || bad "U1 marker line 1 is the rc=could-not-run record (got '$M1L')"
case "$M2L" in *'`tests/a.sh`'*unattributed*|*unattributed*'`tests/a.sh`'*) ok ;; *) bad "U1 marker line 2 names the suite and says unattributed (got '$M2L')" ;; esac
[ "$M2L" = 'Selection gate: 1 suite(s) failed on the head and the base run could not run (could-not-run: timeout), so the gate could not attribute them (unattributed): `tests/a.sh`. The merge queue is the gate of record.' ] \
  && ok || bad "U1 the marker sentence (got '$M2L')"
[ ! -e "$T/c/u1/build/gate-red-noticed" ] && [ "$(ncomments u1)" = 0 ] && ok || bad "U1 no board notice ($(ncomments u1) comments)"
# U7: no network on the U1 run.
[ ! -s "$T/c/u1/stub/net" ] && ok || bad "U7 the U1 run called gh or curl ($(cat "$T/c/u1/stub/net"))"

# ── U2: an attributed red still ends the build ───────────────────────────────
lib u2 1 tests/a.sh "baseline-red: -\nbaseline: ran 1 on ${HEADSHA:0:12} (0 cached)\n"
[ "$(rcof u2)" = 6 ] && ok || bad "U2 baseline ran: rc 6 (got '$(rcof u2)')"
case "$(res u2)" in "GATE_RED 1 red: tests/a.sh"*) ok ;; *) bad "U2 RESULT GATE_RED (got '$(res u2)')" ;; esac
[ -z "$(ua u2)" ] && [ -z "$(mark u2)" ] && ok || bad "U2 no unattributed: line, no marker ($(ua u2) / $(mark u2))"
grep -q 'SELECTION-GATE unattributed=' "$T/c/u2/build/pipeline.log" && bad "U2 an unattributed log line on an attributed red" || ok
[ "$(ncomments u2)" = 1 ] && ok || bad "U2 one board notice (got $(ncomments u2))"

# ── U3: every could-not-run shape ────────────────────────────────────────────
lib u3a 1 tests/a.sh 'baseline-red: -\nbaseline: could-not-run: runner-rc-125: remote-gate: no flyctl\n'
[ "$(rcof u3a)" = 0 ] && [ "$(ua u3a)" = tests/a.sh ] && [ -z "$(res u3a)" ] && ok || bad "U3 runner-rc-125: unattributed (rc $(rcof u3a), $(res u3a))"
lib u3b 1 tests/a.sh,tests/b.sh 'baseline-red: -\nbaseline: could-not-run: no-worktree\n'
[ "$(rcof u3b)" = 0 ] && [ "$(ua u3b)" = tests/a.sh,tests/b.sh ] && ok || bad "U3 no-worktree: unattributed, both suites (rc $(rcof u3b), '$(ua u3b)')"
case "$(mark u3b | sed -n 2p)" in 'Selection gate: 2 suite(s) failed'*'`tests/a.sh`, `tests/b.sh`.'*) ok ;; *) bad "U3 the sentence names both ($(mark u3b))" ;; esac
grep -q 'SELECTION-GATE unattributed=2 red=\[tests/a.sh,tests/b.sh\]' "$T/c/u3b/build/pipeline.log" && ok || bad "U3 the log line counts 2"
lib u3c 1 tests/a.sh 'baseline-red: -\nbaseline: could-not-run: runner-failure\n'
[ "$(rcof u3c)" = 0 ] && [ "$(ua u3c)" = tests/a.sh ] && ok || bad "U3 runner-failure: unattributed (rc $(rcof u3c))"

# ── U4: near misses are attributed reds ──────────────────────────────────────
for nm in 'u4a|baseline-red: -\nbaseline: skipped: head-is-base\n' 'u4b|' \
          'u4c|baseline-red: -\nbaseline:  could-not-run: x\n' 'u4d|baseline-red: -\nbaseline: ran 2 (could-not-run elsewhere)\n'; do
  c=${nm%%|*}; tl=${nm#*|}
  lib "$c" 1 tests/a.sh "$tl"
  [ "$(rcof "$c")" = 6 ] && [ -z "$(ua "$c")" ] && case "$(res "$c")" in "GATE_RED 1 red: tests/a.sh"*) true ;; *) false ;; esac \
    && ok || bad "U4 $c: GATE_RED rc 6 (rc $(rcof "$c"), '$(res "$c")', ua '$(ua "$c")')"
done
lib u4e 1 - "$CNR_TO"
[ -z "$(ua u4e)" ] && [ -z "$(res u4e)" ] && ok || bad "U4 red - : no unattributed: line, no RESULT ('$(ua u4e)' / '$(res u4e)')"

# ── U5: the marker round trip to the lead review ─────────────────────────────
GOT=$( . "$GR" && lr_gate_record "Body text.
$(mark u1)
" "$HEADSHA" ticket/bh-7 block "$CO" main )
[ "$GOT" = "ok 5 could-not-run" ] && ok || bad "U5 lr_gate_record reads the unattributed marker as ok 5 could-not-run (got '$GOT')"

# ── U6: one alert per box per day, its own kind ──────────────────────────────
nua() { cat "$HH/logs/ALERTS.log" 2>/dev/null | grep -c 'COULD NOT ATTRIBUTE'; }
ncnr() { cat "$HH/logs/ALERTS.log" 2>/dev/null | grep -c 'COULD NOT RUN'; }
# U1 above already wrote today's line.
grep -qF "SELECTION GATE COULD NOT ATTRIBUTE 1 red suite(s) on $(hostname): the base run could-not-run: timeout. Builds open PRs; the merge queue is the gate of record." "$HH/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "U6 the alert names the host and the base run ($(cat "$HH/logs/ALERTS.log" 2>/dev/null))"
reset_alerts
lib u6k 1 tests/a.sh "$CNR_TO" SELECTION_GATE_CNR_ALERT=0
[ "$(nua)" = 0 ] && [ ! -d "$HH/state/selection-gate/cnr-unattributed-$DAY" ] && [ "$(rcof u6k)" = 0 ] && ok \
  || bad "U6 knob 0: no alert, no day marker, still rc 0 ($(nua), rc $(rcof u6k))"
lib u6a 1 tests/a.sh "$CNR_TO"
lib u6b 1 tests/b.sh "$CNR_TO"
[ "$(nua)" = 1 ] && [ -d "$HH/state/selection-gate/cnr-unattributed-$DAY" ] && ok || bad "U6 two unattributed builds, one day: one alert (got $(nua): $(cat "$HH/logs/ALERTS.log" 2>/dev/null))"
lib u6c could-not-run - ''
[ "$(ncnr)" = 1 ] && [ "$(nua)" = 1 ] && ok || bad "U6 a could-not-run build that day writes its own line (cnr $(ncnr), ua $(nua))"

# ── M1-M4: the main run's timeout (the real script) ──────────────────────────
R="$T/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; echo a > "$R/a.txt"; g add -A; g commit -qm base
g checkout -q -b ticket/bh-9061; echo b > "$R/b.txt"; g add -A; g commit -qm change
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/a.sh} > "$out"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
[ -n "${STUB_FILE:-}" ] && cat "$STUB_FILE"
[ -n "${STUB_SLEEP:-}" ] && exec sleep "$STUB_SLEEP"
exit "${STUB_RC:-0}"
SH
REALTO=$(command -v timeout)
TOBIN="$T/tobin"; mkdir -p "$TOBIN"
printf '#!/bin/bash\necho "$*" >> "$TOLOG"\nexec %s "$@"\n' "$REALTO" > "$TOBIN/timeout"
chmod +x "$T/plan.sh" "$T/runner.sh" "$TOBIN/timeout"
# run <case> <tree> [VAR=value …] -- <script args> — one REAL bin/selection-gate.sh.
run() {
  local c="$1" tr="$2"; shift 2
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  mkdir -p "$T/$c"; : > "$T/$c/tolog"
  env -u CI_QUARANTINE -u SELECTION_GATE_WHY_MAX -u SELECTION_GATE_BASELINE_RUN -u SELECTION_GATE_BASELINE_TIMEOUT_S \
    -u SELECTION_GATE_BASELINE_RESERVE_PAD_S -u SELECTION_GATE_MAIN_TIMEOUT_MIN_S \
    PATH="$TOBIN:$PATH" TOLOG="$T/$c/tolog" HARNESS="$T/no-harness" REPO_SLUG= \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    "${ev[@]}" bash "$SG" --tree "$T/$tr" --base main --out "$T/$c/out" "$@" > "$T/$c/stdout" 2> "$T/$c/stderr"
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
mto() { sed -n 1p "$T/$1/tolog" | awk '{ print $3 }'; }
run m1 repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 -- --timeout 2400
[ "$RC" = 0 ] && [ "$(sed -n 1p "$T/m1/tolog")" = "-k 30 1440 $T/runner.sh $T/repo tests/a.sh" ] && ok \
  || bad "M1 the main run gets 2400 - 900 - 60 = 1440 (rc $RC; $(cat "$T/m1/tolog"); $(cat "$T/m1/stderr"))"
run m2 repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 -- --timeout 1000
[ "$(mto m2)" = 300 ] && ok || bad "M2 never under 300 (got '$(mto m2)')"
run m2b repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 SELECTION_GATE_MAIN_TIMEOUT_MIN_S=400 -- --timeout 1000
[ "$(mto m2b)" = 400 ] && ok || bad "M2 the floor is the knob (got '$(mto m2b)')"
run m2c repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 -- --timeout 250
[ "$(mto m2c)" = 250 ] && ok || bad "M2 never over --timeout (got '$(mto m2c)')"
run m3 repo -- --timeout 2400
[ "$(mto m3)" = 2400 ] && ok || bad "M3 baseline off: the whole --timeout (got '$(mto m3)')"
run m3b repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=900 SELECTION_GATE_BASELINE_RESERVE_PAD_S=0 -- --timeout 2400
[ "$(mto m3b)" = 1500 ] && ok || bad "M3 pad 0: 2400 - 900 = 1500 (got '$(mto m3b)')"
t0=$SECONDS
run m4 repo SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_BASELINE_TIMEOUT_S=1 SELECTION_GATE_BASELINE_RESERVE_PAD_S=60 \
  SELECTION_GATE_MAIN_TIMEOUT_MIN_S=3 STUB_SLEEP=8 -- --timeout 64
m4el=$((SECONDS - t0))
[ "$(mto m4)" = 3 ] && [ "$(gv m4 rc)" = could-not-run ] && [ "$(gv m4 why)" = timeout ] && [ "$m4el" -lt 40 ] && ok \
  || bad "M4 the main-run bound decides the timeout (mto '$(mto m4)', $(cat "$T/m4/out/gate.txt" 2>/dev/null), ${m4el}s)"

# ── H1-H3: the ci-durations-db host note ─────────────────────────────────────
mkdir -p "$R/catalog/selection-gate-host-notes.d"
[ -r "$NOTES" ] && cp "$NOTES" "$R/catalog/selection-gate-host-notes.d/"
g add -A; g commit -qm notes >/dev/null
run h1 repo STUB_SUITES=$CID STUB_RC=1 STUB_FILE="$FIXRUN" -- --timeout 60
[ "$RC" = 0 ] && [ "$(gv h1 rc)" = 0 ] && [ "$(gv h1 red)" = - ] && [ "$(gv h1 noted)" = "$CID" ] && ok \
  || bad "H1 the real shallow-context output is noted (exit $RC; $(cat "$T/h1/out/gate.txt" 2>/dev/null); $(cat "$T/h1/stderr"))"
[ "$(gv h1 host-noted)" = "$CID=shallow-context" ] && ok || bad "H1 host-noted names the class (got '$(gv h1 host-noted)')"
DB1='  FAIL DB1 seed --dry-run rc=1 x'
sed "s|^  FAIL no seed in git history (0 rows)\$|$DB1|" "$FIXRUN" > "$T/h2a.run"
grep -qxF "$DB1" "$T/h2a.run" && ok || bad "H2 setup: the other failure line is in the section"
run h2a repo STUB_SUITES=$CID STUB_RC=1 STUB_FILE="$T/h2a.run" -- --timeout 60
[ "$RC" = 1 ] && [ "$(gv h2a red)" = "$CID" ] && [ "$(gv h2a host-noted)" = - ] && ok || bad "H2 another failure stays red ($(cat "$T/h2a/out/gate.txt" 2>/dev/null))"
awk -v d="$DB1" '{ print } /^  FAIL no seed in git history/ { print d }' "$FIXRUN" > "$T/h2b.run"
run h2b repo STUB_SUITES=$CID STUB_RC=1 STUB_FILE="$T/h2b.run" -- --timeout 60
[ "$RC" = 1 ] && [ "$(gv h2b red)" = "$CID" ] && ok || bad "H2 both lines stay red ($(cat "$T/h2b/out/gate.txt" 2>/dev/null))"
H3=$( TREE="$R"; OUT="$T/h3"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2> "$T/h3.err"
  for i in "${!HN_SUITE[@]}"; do
    case "${HN_SUITE[$i]}" in "$CID") ;; *) continue ;; esac
    if grep -E '(^|[[:space:]])FAIL[: ]' "$FIXRUN" | grep -qE -- "${HN_ERE[$i]}"; then echo "match ${HN_SUITE[$i]}"; else echo "nomatch ${HN_SUITE[$i]}"; fi
  done )
NROWS=$(grep -cv '^#' "$NOTES" 2>/dev/null)
[ "$NROWS" = 1 ] && [ "$H3" = "match $CID" ] && [ ! -s "$T/h3.err" ] && ok \
  || bad "H3 every bh-9061 row parses and matches its fixture (rows $NROWS; got '$H3'; $(cat "$T/h3.err" 2>/dev/null))"

echo "selection-gate-unattributed.bh-9061: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
