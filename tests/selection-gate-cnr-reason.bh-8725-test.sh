#!/bin/bash
# tests/selection-gate-cnr-reason.bh-8725-test.sh — BH-8725: a could-not-run
# selection gate says WHY, and the hub gets the record.
#
# THE BUG. Every pool build's gate.txt said `why: runner-rc-125` and dropped
# remote-gate's own reason line. The alert repeated a generic hint, and the
# hub never got gate.txt or run.txt back from a pool machine.
#
# PINNED. The REAL bin/selection-gate.sh (planner and runner are stubs through
# its seams SELECTION_GATE_PLAN / SELECTION_GATE_RUNNER) and the REAL
# bin/lib/selection-gate.sh sg_block, run from a scratch checkout that carries
# the real script. The record files go through the REAL bin/lib/pool-record.sh.
# No network.
#   S1 route-incomplete line, rc 125: why is `runner-rc-125: <that line>`
#   S2 git-context line, then the upload line: why is the upload line
#   S3 route line, then `flyctl is not on PATH`: why is the route line
#   S4 a 400-char line: the reason is cut to 160 (no env), to 50 (env 50)
#   S5 red-without-names, a red with names, a leading-space near miss, rc 137
#   S6 a token line: `<token line dropped>`; fm2_ in no output or gate.txt
#   L1 sg_block's SELECTION-GATE line carries ` why=<why>`
#   L2 $BUILD/gate-run.tail.txt is the last 40 lines of run.txt (knob: 5)
#   L3 the alert carries the reason in place of the `Needed:` hint
#   L4 a bare token keeps the `Needed:` hint
#   L5 the tail drops token lines; no run.txt -> no tail file
#   P1 POOL_RECORD_FILES and the fly-pool.sh ssh pull list end with the two names
#   P2 pool_record_put posts both files byte-equal; absent -> neither posted
#   P3 pool_record_get writes both into the hub stage dir
#   K1 both knob JSONs, defaults 40 and 160, read in bin/lib/selection-gate.sh
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-cnr-reason.bh-8725-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# L3/L4 read the UTC day marker sg_cnr_alert writes; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SG="$REPO/bin/selection-gate.sh"
LIB="$REPO/bin/lib/selection-gate.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -x "$SG" ] && [ -r "$LIB" ] || { echo "FAIL: bin/selection-gate.sh or its lib is missing"; exit 1; }
TOK='FlyV1 fm2_fixture-token-8725'

# A scratch repo with a base on main and one change.
R="$T/repo"; mkdir -p "$R"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; echo a > "$R/a.txt"; g add -A; g commit -qm base
g checkout -q -b ticket/bh-8725; echo b > "$R/b.txt"; g add -A; g commit -qm change

# The planner stub: 5 suites. The runner stub: $STUB_RUN_ERR to stderr (the
# way remote-gate prints its reason), $STUB_LINES numbered lines to stdout,
# exit STUB_RC.
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf 'tests/s%03d.sh\n' 1 2 3 4 5 > "$out"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
i=1; while [ "$i" -le "${STUB_LINES:-0}" ]; do echo "run line $i"; i=$((i+1)); done
[ -n "${STUB_RUN_ERR:-}" ] && printf '%b\n' "$STUB_RUN_ERR" >&2
exit "${STUB_RC:-0}"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"

# run <case> [VAR=value …] — one REAL bin/selection-gate.sh run.
run() {
  local c="$1"; shift
  mkdir -p "$T/$c"
  env -u CI_QUARANTINE -u SELECTION_GATE_WHY_MAX HARNESS="$T/no-harness" REPO_SLUG= \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    "$@" bash "$SG" --tree "$R" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }

ROUTE='remote-gate: pool test-host route incomplete: flyctl=MISSING route=/x/testhost.env (MISSING) transport=fly-ssh token=MISSING'
# ── S1 ──────────────────────────────────────────────────────────────────────
run s1 STUB_RC=125 STUB_RUN_ERR="$ROUTE"
[ "$RC" = 3 ] && [ "$(gv s1 rc)" = could-not-run ] && ok || bad "S1 exit 3 could-not-run (exit $RC; $(cat "$T/s1/out/gate.txt" 2>/dev/null))"
[ "$(gv s1 why)" = "runner-rc-125: $ROUTE" ] && ok || bad "S1 why carries the route line (got '$(gv s1 why)')"
grep -qF "why=runner-rc-125: remote-gate: pool test-host route incomplete:" "$T/s1/stdout" && ok || bad "S1 the stdout line carries the why ($(cat "$T/s1/stdout"))"

# ── S2 ──────────────────────────────────────────────────────────────────────
UP='remote-gate: the upload to the test host failed (rsync rc 2: protocol version mismatch -- is your shell clean?) — nothing ran'
run s2 STUB_RC=125 STUB_RUN_ERR="remote-gate: git context — HEAD abc1234 over origin/main def5678\n$UP"
[ "$(gv s2 why)" = "runner-rc-125: $UP" ] && ok || bad "S2 why is the last remote-gate line (got '$(gv s2 why)')"

# ── S3 ──────────────────────────────────────────────────────────────────────
run s3 STUB_RC=125 STUB_RUN_ERR="$ROUTE\nremote-gate: flyctl is not on PATH (install it)"
[ "$(gv s3 why)" = "runner-rc-125: $ROUTE" ] && ok || bad "S3 the route line wins over a later line (got '$(gv s3 why)')"

# ── S4 ──────────────────────────────────────────────────────────────────────
LONG="remote-gate: $(printf 'x%.0s' $(seq 1 387))"
run s4 STUB_RC=125 STUB_RUN_ERR="$LONG"
W=$(gv s4 why); RS=${W#runner-rc-125: }
[ "${#LONG}" = 400 ] && [ "${#RS}" = 160 ] && [ "$RS" = "${LONG:0:160}" ] && ok || bad "S4 the reason is cut to 160 (got ${#RS}: '$W')"
run s4b STUB_RC=125 STUB_RUN_ERR="$LONG" SELECTION_GATE_WHY_MAX=50
W=$(gv s4b why); RS=${W#runner-rc-125: }
[ "${#RS}" = 50 ] && ok || bad "S4 SELECTION_GATE_WHY_MAX=50 cuts to 50 (got ${#RS}: '$W')"
run s4c STUB_RC=125 STUB_RUN_ERR="$LONG" SELECTION_GATE_WHY_MAX=abc
W=$(gv s4c why); RS=${W#runner-rc-125: }
[ "${#RS}" = 160 ] && ok || bad "S4 a bad SELECTION_GATE_WHY_MAX falls back to 160 (got ${#RS})"

# ── S5 ──────────────────────────────────────────────────────────────────────
run s5a STUB_RC=1 STUB_RUN_ERR='something broke'
[ "$(gv s5a why)" = red-without-names ] && ok || bad "S5 no remote-gate line: bare red-without-names (got '$(gv s5a why)')"
run s5b STUB_RC=1 STUB_RUN_ERR='FAIL tests/x.sh (rc 1)\nremote-gate: 1 of 5 suites failed'
[ "$RC" = 1 ] && [ "$(gv s5b rc)" = 1 ] && [ "$(gv s5b red)" = tests/x.sh ] && [ "$(gv s5b why)" = - ] && ok \
  || bad "S5 a named red stays red, why - (exit $RC; $(cat "$T/s5b/out/gate.txt" 2>/dev/null))"
run s5c STUB_RC=125 STUB_RUN_ERR=' remote-gate: x\nxremote-gate: y'
[ "$(gv s5c why)" = runner-rc-125 ] && ok || bad "S5 near misses give the bare token (got '$(gv s5c why)')"
run s5d STUB_RC=137 STUB_RUN_ERR='remote-gate: killed by the host'
[ "$(gv s5d why)" = "runner-rc-137: remote-gate: killed by the host" ] && ok || bad "S5 rc 137 under the budget carries the reason (got '$(gv s5d why)')"
run s5e STUB_RC=1 STUB_RUN_ERR='noise\nremote-gate: the host ran out of disk'
[ "$(gv s5e why)" = "red-without-names: remote-gate: the host ran out of disk" ] && ok || bad "S5 red-without-names carries the reason (got '$(gv s5e why)')"
run s5f STUB_RC=0 STUB_RUN_ERR='remote-gate: all 5 suites passed'
[ "$RC" = 0 ] && [ "$(gv s5f rc)" = 0 ] && [ "$(gv s5f why)" = - ] && ok || bad "S5 rc 0 stays green, why - (got $(gv s5f rc) / '$(gv s5f why)')"
# The why round-trips through the lib's reader.
[ "$( . "$LIB" && _sg_field "$T/s1/out/gate.txt" why )" = "runner-rc-125: $ROUTE" ] && ok || bad "S5 _sg_field reads the long why back"

# ── S6 ──────────────────────────────────────────────────────────────────────
run s6 STUB_RC=125 STUB_RUN_ERR="remote-gate: flyctl said $TOK"
[ "$(gv s6 why)" = "runner-rc-125: <token line dropped>" ] && ok || bad "S6 the token line is dropped (got '$(gv s6 why)')"
grep -q 'fm2_' "$T/s6/out/gate.txt" "$T/s6/stdout" && bad "S6 the token reached gate.txt or stdout" || ok

# ── L: sg_block from a checkout that carries the real script ────────────────
HH="$T/h"; mkdir -p "$HH/bin"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
cat > "$HH/bin/alert-line.sh" <<'SH'
#!/bin/bash
[ "$1" = --id ] && shift 2
mkdir -p "$HARNESS/logs"; echo "2026-10-28 00:00:00Z $*" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$HH/bin/alert-line.sh"
CO="$T/co"; mkdir -p "$CO/bin"
cp "$SG" "$CO/bin/selection-gate.sh"; chmod +x "$CO/bin/selection-gate.sh"
git -C "$CO" init -q -b main
git -C "$CO" -c user.email=t@example.com -c user.name=t add -A
git -C "$CO" -c user.email=t@example.com -c user.name=t commit -qm base
# lib <case> [VAR=value …] — sg_block in a subshell; $T/c/<case>/build is BUILD.
lib() {
  local c="$1"; shift
  C="$T/c/$c"; mkdir -p "$C/build"
  ( cd "$CO" || exit 99
    env -u SELECTION_GATE -u SELECTION_GATE_WHY_MAX -u SELECTION_GATE_RUN_TAIL_LINES -u CI_QUARANTINE \
      HARNESS="$HH" BUILD="$C/build" PROJECT=demo-os KEY=BH-8725 TICKET=8725 BASE=main JOBS_URL='' REPO_SLUG= \
      SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- "$@" bash -c '
      STAMP() { echo 2026-10-28T00:00:00Z; }
      RESULT() { printf "%s\n" "$*" > "$BUILD/RESULT"; }
      . "$1" || exit 98
      sg_block; echo "$?" > "$BUILD/rc"' _ "$LIB"
  ) > "$C/out" 2>&1
}
reset_alerts() { scratch_rm "$HH/state/selection-gate"; scratch_rm "$HH/logs/ALERTS.log"; }

# ── L1 + L3 ─────────────────────────────────────────────────────────────────
reset_alerts
lib l1 STUB_RC=125 STUB_RUN_ERR="$ROUTE"
[ "$(cat "$T/c/l1/build/rc" 2>/dev/null)" = 0 ] && ok || bad "L1 sg_block rc 0 on could-not-run ($(cat "$T/c/l1/out"))"
grep -qF "SELECTION-GATE rc=could-not-run suites=5 red=- exit=3 why=runner-rc-125: $ROUTE" "$T/c/l1/build/pipeline.log" \
  && ok || bad "L1 the log line carries the why ($(cat "$T/c/l1/build/pipeline.log" 2>/dev/null))"
A=$(grep 'SELECTION GATE COULD NOT RUN' "$HH/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -c . <<<"$A")" = 1 ] && ok || bad "L3 one alert line (got: $A)"
grep -qF "SELECTION GATE COULD NOT RUN on $(hostname): runner-rc-125: $ROUTE. Builds open PRs with no pre-PR selection run; the batch is the only check." <<<"$A" \
  && ok || bad "L3 the alert carries the reason ($A)"
grep -q 'Needed:' <<<"$A" && bad "L3 the generic hint is still in a reason alert ($A)" || ok

# ── L4 ──────────────────────────────────────────────────────────────────────
reset_alerts
lib l4 STUB_RC=125
A=$(grep 'SELECTION GATE COULD NOT RUN' "$HH/logs/ALERTS.log" 2>/dev/null)
grep -qF "SELECTION GATE COULD NOT RUN on $(hostname): runner-rc-125. Builds open PRs" <<<"$A" && grep -q 'Needed: a test-host route' <<<"$A" \
  && ok || bad "L4 a bare token keeps the hint ($A)"
grep -q 'SELECTION-GATE rc=could-not-run suites=5 red=- exit=3 why=runner-rc-125$' "$T/c/l4/build/pipeline.log" \
  && ok || bad "L4 the bare why in the log line ($(cat "$T/c/l4/build/pipeline.log" 2>/dev/null))"

# ── L2 ──────────────────────────────────────────────────────────────────────
lib l2 STUB_RC=125 STUB_LINES=100 STUB_RUN_ERR="$ROUTE"
TL="$T/c/l2/build/gate-run.tail.txt"
[ -f "$TL" ] && [ "$(wc -l < "$TL")" = 40 ] && cmp -s "$TL" <(tail -n 40 "$T/c/l2/build/selection-gate/run.txt") \
  && ok || bad "L2 the tail is the last 40 lines of run.txt ($(wc -l < "$TL" 2>/dev/null) lines)"
lib l2b STUB_RC=125 STUB_LINES=100 SELECTION_GATE_RUN_TAIL_LINES=5
[ "$(wc -l < "$T/c/l2b/build/gate-run.tail.txt" 2>/dev/null)" = 5 ] && ok || bad "L2 SELECTION_GATE_RUN_TAIL_LINES=5 gives 5 lines"
lib l2c STUB_RC=125 STUB_RUN_ERR="$LONG" SELECTION_GATE_WHY_MAX=60
W=$(sed -n 's/^why: //p' "$T/c/l2c/build/gate.txt"); RS=${W#runner-rc-125: }
[ "${#RS}" = 60 ] && ok || bad "L2 sg_block passes SELECTION_GATE_WHY_MAX to the script (got ${#RS})"
[ "$(sed -n 's/^rc: //p' "$T/c/l2/build/gate.txt")" = could-not-run ] && ok || bad "L2 \$BUILD/gate.txt is the record"

# ── L5 ──────────────────────────────────────────────────────────────────────
lib l5 STUB_RC=125 STUB_LINES=3 STUB_RUN_ERR="x $TOK y\nremote-gate: the upload failed"
TL="$T/c/l5/build/gate-run.tail.txt"
grep -qx '<token line dropped>' "$TL" 2>/dev/null && grep -qx 'run line 3' "$TL" && ok || bad "L5 the token line is replaced ($(cat "$TL" 2>/dev/null))"
grep -q 'fm2_' "$T/c/l5/build/selection-gate/run.txt" && ok || bad "L5 setup: run.txt holds the token"
LEAK=$(grep -rl 'fm2_' "$T/c/l5/build" 2>/dev/null | grep -v '/selection-gate/run.txt$')
[ -z "$LEAK" ] && ok || bad "L5 the token reached $LEAK"
# No run.txt: no tail file (a stale one is removed). A checkout whose gate
# writes nothing and exits 3.
CO2="$T/co2"; mkdir -p "$CO2/bin"; printf '#!/bin/bash\nexit 3\n' > "$CO2/bin/selection-gate.sh"; chmod +x "$CO2/bin/selection-gate.sh"
git -C "$CO2" init -q -b main
git -C "$CO2" -c user.email=t@example.com -c user.name=t add -A
git -C "$CO2" -c user.email=t@example.com -c user.name=t commit -qm base
mkdir -p "$T/c/l5b/build"; echo stale > "$T/c/l5b/build/gate-run.tail.txt"
CO_SAVE="$CO"; CO="$CO2"; lib l5b; CO="$CO_SAVE"
[ ! -e "$T/c/l5b/build/gate-run.tail.txt" ] && ok || bad "L5 no run.txt: the stale tail is removed"

# ── P1-P3: the hub record ───────────────────────────────────────────────────
PR="$T/pr"; mkdir -p "$PR/bin" "$PR/tmp"
scratch_install_closure bin/lib/pool-record.sh "$PR" >/dev/null || { echo "FAIL: setup: cannot install pool-record"; exit 1; }
cp "$REPO/bin/result-prefix-ok.sh" "$PR/bin/" && chmod +x "$PR/bin/result-prefix-ok.sh"
P=$( . "$REPO/bin/lib/pool-record.sh" && printf '%s\n' "${POOL_RECORD_FILES[@]}" )
[ "$(tail -n 2 <<<"$P" | tr '\n' ' ')" = "gate.txt gate-run.tail.txt " ] && ok || bad "P1 POOL_RECORD_FILES ends with the two names ($(tail -n 2 <<<"$P" | tr '\n' ' '))"
SSHL=$(awk '/^      for A in plan\.md /{f=1} f{print} f&&/; do$/{exit}' "$REPO/bin/fly-pool.sh" | tr -s ' \\\n' ' ')
case "$SSHL" in *"ticket-meta.json gate.txt gate-run.tail.txt; do"*) ok ;; *) bad "P1 the fly-pool.sh ssh pull list ends with the two names ($SSHL)" ;; esac
BD="$T/m/builds/demo-os-BH-8725-202610281741"; mkdir -p "$BD"
cp "$T/c/l5/build/gate.txt" "$BD/gate.txt"; cp "$T/c/l2/build/gate-run.tail.txt" "$BD/gate-run.tail.txt"
printf 'pipeline\n' > "$BD/pipeline.log"
RF="$T/m/RESULT"; printf 'PR_CREATED https://github.com/o/r/pull/9\nBUILD_DIR: /data/harness/builds/demo-os-BH-8725-202610281741\n' > "$RF"
_jobs_req_file() { cp "$3" "$PRFIX/body.json"; return 0; }
_jobs_req() { [ "$1" = GET ] && cat "$PRFIX/get-answer"; return 0; }
export PRFIX="$T/pr"; export -f _jobs_req_file _jobs_req
( export HARNESS="$PR" TMPDIR="$PR/tmp"; . "$REPO/bin/lib/pool-record.sh" && pool_record_put demo-os BH-8725 m1 "$RF" "$BD" "" ) >/dev/null 2>&1
for n in gate.txt gate-run.tail.txt; do
  jq -r --arg n "$n" '.files[] | select(.name==$n) | .b64' "$PR/body.json" 2>/dev/null | base64 -d 2>/dev/null | cmp -s - "$BD/$n" \
    && ok || bad "P2 $n posted byte-equal"
done
jq -c '{record:{build_dir, machine:"m1", posted_at:"2026-10-28T17:50:00Z",
  files:[.files[] | {name, body:(.b64 // null), bytes:0, skipped:0}]}}' "$PR/body.json" > "$PR/get-answer" 2>/dev/null
OUT=$( export HARNESS="$PR" TMPDIR="$PR/tmp"; . "$REPO/bin/lib/pool-record.sh" && pool_record_get demo-os BH-8725 m1 "2026-10-28 17:41:00Z" "$T/stage" ); GRC=$?
[ "$GRC" = 0 ] && cmp -s "$T/stage/gate.txt" "$BD/gate.txt" && cmp -s "$T/stage/gate-run.tail.txt" "$BD/gate-run.tail.txt" \
  && ok || bad "P3 pool_record_get writes both files into the stage dir (rc $GRC, out '$OUT', $(ls "$T/stage" 2>/dev/null | tr '\n' ' '))"
rm -f "$BD/gate.txt" "$BD/gate-run.tail.txt" "$PR/body.json"
( export HARNESS="$PR" TMPDIR="$PR/tmp"; . "$REPO/bin/lib/pool-record.sh" && pool_record_put demo-os BH-8725 m1 "$RF" "$BD" "" ) >/dev/null 2>&1
[ "$(jq -r '[.files[].name] | map(select(. == "gate.txt" or . == "gate-run.tail.txt")) | length' "$PR/body.json" 2>/dev/null)" = 0 ] \
  && jq -e '.files[] | select(.name=="pipeline.log")' "$PR/body.json" >/dev/null 2>&1 && ok || bad "P2 absent files are not posted"

# ── K1 ──────────────────────────────────────────────────────────────────────
KD="$REPO/catalog/lanes.d/fly-pool.knobs.d"
[ "$(jq -r '[.env,.type,.default,.read_in]|join(" ")' "$KD/SELECTION_GATE_RUN_TAIL_LINES.json" 2>/dev/null)" = "SELECTION_GATE_RUN_TAIL_LINES int 40 bin/lib/selection-gate.sh" ] \
  && ok || bad "K1 SELECTION_GATE_RUN_TAIL_LINES.json default 40"
[ "$(jq -r '[.env,.type,.default,.read_in]|join(" ")' "$KD/SELECTION_GATE_WHY_MAX.json" 2>/dev/null)" = "SELECTION_GATE_WHY_MAX int 160 bin/lib/selection-gate.sh" ] \
  && ok || bad "K1 SELECTION_GATE_WHY_MAX.json default 160"

echo "selection-gate-cnr-reason.bh-8725: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
