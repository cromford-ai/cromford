#!/bin/bash
# tests/selection-gate-host-run.bh-8725-test.sh — BH-8725 fix round: the
# selection gate's run on the test host matches CI.
#
# THE BUG. With the rc-125 cause fixed, the gate ran 754 suites on a pool
# machine and went red on six that main is also red on there, none of them this
# diff's: four died on ERR_MODULE_NOT_FOUND catalog/lanes.json (CI composes the
# git-ignored catalogs before the suites, bin/remote-gate.sh did not), one read
# a shallow git context (fly-pool-split C3), one hit a 6 s wall-clock bound on a
# loaded host (issue-testhost-cert W1x).
#
# PINNED. The REAL bin/remote-gate.sh composes its suites job (flyctl, ssh,
# rsync, nc and ssh-keygen are PATH shims; the ssh shim captures the job) and
# the job RUNS here against a fixture tree, the tests/remote-gate-test.sh way.
# The REAL bin/selection-gate.sh runs with stub planner and runner, and the REAL
# bin/lib/selection-gate.sh sg_block runs from a scratch checkout. No network.
#   H1 the job composes the three catalogs once, in CI's order, before any copy
#   H2 no compose scripts: nothing composed; only lanes-build: only that one
#   H3 a failing compose: exit 125, one compose-<name> line, no suite, no token
#   H4 the job's compose list equals harness-ci.yml's tests-shard step
#   H5 the BH-8725 commits edit none of the six host-red suites, no CI, no quarantine
#   S7 rc 125 + a compose-failed line: why=compose-<name>: <line>; alert, no hint
#   S8 compose near misses: runner-rc-125 / red kept; the host-resources dump
#      after a RUNNER FAILURE line is never the reason
#   N1 the shipped host-notes file parses: 2 rows, both classes, both EREs
#   Q1 both live failure lines: rc 0, noted both, host-noted names the classes
#   Q2 a second, different failure in the same suite: red
#   Q3 W1x and W1ix both: noted
#   Q4 other C3 format, a suite with no row, a silent red: red each
#   Q5 bad rows (class, 3 fields, bad ERE): skipped with a line each, red
#   Q6 no notes dir, or a notes path that is not a dir: every red counts
#   Q7 quarantined + host-matching: in noted once; sg_block logs host-noted=2
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/selection-gate-host-run.bh-8725-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# S7/Q7 read the UTC day marker sg_cnr_alert writes; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
GATE="$REPO/bin/remote-gate.sh"
SG="$REPO/bin/selection-gate.sh"
LIB="$REPO/bin/lib/selection-gate.sh"
NOTES="$REPO/catalog/selection-gate-host-notes.d/bh-8725.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -f "$GATE" ] && [ -x "$SG" ] && [ -r "$LIB" ] || { echo "FAIL: a script under test is missing"; exit 1; }
TOK='FlyV1 fm2_fixture-8725'
S42=tests/fly-pool-split.bh-7542-test.sh
S10=tests/issue-testhost-cert.bh-5210-test.sh
C3LIVE='  FAIL C3 0100-head.sh is not a byte prefix of bin/fly-pool.sh at commit 8381f5e9f3a6 (re-cut it, see README.md)'
W1X='FAIL: W1x the spew ran 6s, to the timeout: the cap did not stop it'
W1IX='FAIL: W1ix with SIGPIPE ignored the spew ran 7s, to the timeout: the cap did not stop it'

# ── the remote-gate shims (tests/remote-gate-test.sh's, trimmed) ─────────────
FIX="$T/fix"; mkdir -p "$FIX" "$T/fakebin" "$T/wt" "$T/h/flags"
echo "a worktree file" > "$T/wt/file.txt"
: > "$T/h/flags/lane-off-testhost-tick"
: > "$FIX/proxy-up"
printf 'key\n' > "$T/key"; printf 'cert\n' > "$T/key-cert.pub"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flyctl"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/nc"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/rsync"
cat > "$T/fakebin/ssh" <<'STUB'
#!/bin/bash
case "$*" in *"bash -s"*) cat > "$FIX/job"; exit 0 ;; esac
exit 0
STUB
cat > "$T/fakebin/ssh-keygen" <<'STUB'
#!/bin/bash
echo "        Valid: from 2026-01-01T00:00:00 to 2099-01-01T00:00:00"
STUB
chmod +x "$T/fakebin"/*
export FIX
# job <suite...> — the real gate composes the suites job into $FIX/job.
job() {
  rm -f "$FIX/job"
  env -u POOL_MODE -u TESTHOST_TARGET -u TESTHOST_MACHINE -u HARNESS_ENV_DIR -u REMOTE_GATE_ROUTE_ENV -u REMOTE_GATE_TRANSPORT -u FLY_API_TOKEN PATH="$T/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$T" HARNESS="$T/h" TESTHOST_APP=bh-testhost-fixture TESTHOST_PORT=10022 TESTHOST_ORG=fixture-org \
    TESTHOST_KEY="$T/key" REMOTE_GATE_PROXY_WAIT_S=2 bash "$GATE" -P 2 "$T/wt" "$@" > "$T/job.out" 2>&1
  [ -s "$FIX/job" ] || { echo "FAIL: setup: no job was composed ($(cat "$T/job.out"))"; exit 1; }
}
# runjob <rundir> — run the captured job locally; JOUT, JERR, JRC.
runjob() {
  env -u HARNESS_TEST_SANDBOX RG_RUN_DIR="$1" HOME="$T" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$FIX/job" > "$T/jout" 2> "$T/jerr"; JRC=$?
  JOUT=$(cat "$T/jout"); JERR=$(cat "$T/jerr")
}
# stub_build <base> <name> <catalog> [fail] — a compose script that logs its
# call and writes its catalog (or, with fail, prints two lines and exits 2).
stub_build() {
  mkdir -p "$1/bin" "$1/catalog"
  if [ "${4:-}" = fail ]; then
    printf '#!/bin/bash\necho "%s $* sandbox=$HARNESS_TEST_SANDBOX" >> "%s/compose-calls"\necho "bad fragment x.json"\necho "%s"\necho\nexit 2\n' \
      "$2" "$T" "$TOK" > "$1/bin/$2.sh"
  else
    printf '#!/bin/bash\necho "%s $* sandbox=$HARNESS_TEST_SANDBOX" >> "%s/compose-calls"\necho "{}" > catalog/%s\n' \
      "$2" "$T" "$3" > "$1/bin/$2.sh"
  fi
}
# a.sh needs all three catalogs (what the node suites need).
need_suite() {
  mkdir -p "$1/tests"
  printf '#!/bin/bash\nfor f in lanes llm-sites context-budgets; do [ -f catalog/$f.json ] || { echo "FAIL: catalog/$f.json missing"; exit 1; }; done\nexit 0\n' > "$1/tests/a.sh"
}

# ── H1: the three, once, in order, before the suites ─────────────────────────
job tests/a.sh tests/a.sh
B="$T/r1/base"; mkdir -p "$B"
stub_build "$B" lanes-build lanes.json; stub_build "$B" llm-sites-build llm-sites.json; stub_build "$B" context-budgets-build context-budgets.json
need_suite "$B"; rm -f "$T/compose-calls"
runjob "$T/r1"
[ "$JRC" = 0 ] && ok || bad "H1 the job exited $JRC with the catalogs composed: $JOUT / $JERR"
[ "$(grep -c '^PASS tests/a.sh$' <<<"$JOUT")" = 2 ] && ok || bad "H1 both suite copies passed ($JOUT)"
WANT=$'lanes-build --write sandbox=1\nllm-sites-build --compose sandbox=1\ncontext-budgets-build --compose sandbox=1'
[ "$(cat "$T/compose-calls" 2>/dev/null)" = "$WANT" ] && ok || bad "H1 three calls, CI's order, once each, sandbox 1 (got: $(cat "$T/compose-calls" 2>/dev/null))"
grep -qx 'remote-gate: composed the catalogs CI composes before the suites (lanes-build llm-sites-build context-budgets-build)' <<<"$JOUT" \
  && ok || bad "H1 the one success line ($JOUT)"
[ ! -e "$T/r1" ] && ok || bad "H1 the run dir is removed"

# ── H2: no compose scripts; only one of them ─────────────────────────────────
job tests/a.sh
B="$T/r2/base"; mkdir -p "$B"; need_suite "$B"; rm -f "$T/compose-calls"
runjob "$T/r2"
[ "$JRC" = 1 ] && grep -q '^FAIL tests/a.sh (rc 1)$' <<<"$JOUT" && ok || bad "H2 no compose scripts: the suite runs and fails on the missing file (rc $JRC: $JOUT)"
grep -q 'compose' <<<"$JOUT$JERR" && bad "H2 a compose line with no compose script ($JOUT / $JERR)" || ok
[ ! -e "$T/compose-calls" ] && ok || bad "H2 nothing composed"
B="$T/r2b/base"; mkdir -p "$B"; need_suite "$B"; stub_build "$B" lanes-build lanes.json; rm -f "$T/compose-calls"
runjob "$T/r2b"
[ "$(cat "$T/compose-calls" 2>/dev/null)" = 'lanes-build --write sandbox=1' ] && ok || bad "H2 only lanes-build runs (got: $(cat "$T/compose-calls" 2>/dev/null))"
grep -qx 'remote-gate: composed the catalogs CI composes before the suites (lanes-build)' <<<"$JOUT" && ok || bad "H2 the line names only lanes-build ($JOUT)"

# ── H3: a failing compose ────────────────────────────────────────────────────
job tests/a.sh
B="$T/r3/base"; mkdir -p "$B"; need_suite "$B"
stub_build "$B" lanes-build lanes.json; stub_build "$B" llm-sites-build llm-sites.json fail; stub_build "$B" context-budgets-build context-budgets.json
rm -f "$T/compose-calls"
runjob "$T/r3"
[ "$JRC" = 125 ] && ok || bad "H3 a failed compose exits 125 (got $JRC: $JOUT / $JERR)"
H3LINE='remote-gate: compose-llm-sites-build failed (rc 2): bad fragment x.json'
[ "$(grep -c '^remote-gate: compose-' <<<"$JERR")" = 1 ] && grep -qxF "$H3LINE" <<<"$JERR" && ok || bad "H3 one compose-failed line on stderr ($JERR)"
grep -q 'fm2_' <<<"$JOUT$JERR" && bad "H3 the token reached the output" || ok
grep -qE '^(PASS|FAIL) tests/' <<<"$JOUT" && bad "H3 a suite ran after a failed compose ($JOUT)" || ok
grep -q context-budgets-build "$T/compose-calls" 2>/dev/null && bad "H3 the compose went on after the failure" || ok
[ ! -e "$T/r3" ] && ok || bad "H3 the run dir is removed"
cp "$T/jerr" "$T/h3.err"

# ── H4: the host list is CI's list ───────────────────────────────────────────
CI=$(awk '/^  tests-shard:/ { j = 1; next } j && /^  [a-z]/ { j = 0 }
  j && /- name: render the lane registry and the llm-sites catalog the worker imports/ { s = 1; next }
  s && /- name:/ { s = 0 } s' "$REPO/.github/workflows/harness-ci.yml" | grep -oE 'bin/[a-z0-9-]+\.sh( --[a-z-]+)*')
HOST=$(awk "/^RG_COMPOSE='/ { s = 1; sub(/^RG_COMPOSE='/, \"\") } s { l = \$0; e = (l ~ /'\$/); sub(/'\$/, \"\", l); print l; if (e) exit }" "$GATE")
[ -n "$CI" ] && [ "$CI" = "$HOST" ] && ok || bad "H4 the host compose list equals harness-ci.yml's tests-shard step (CI: $CI / host: $HOST)"
[ "$(grep -c . <<<"$HOST")" = 3 ] && ok || bad "H4 three commands (got: $HOST)"

# ── H5: this ticket's commits leave the six suites and CI alone ──────────────
if git -C "$REPO" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  CH=$(git -C "$REPO" log --format= --name-only --grep=BH-8725 origin/main..HEAD 2>/dev/null | sort -u)
  [ -n "$CH" ] || echo "H5: skipped (no BH-8725 commits above main in this checkout)"
  BADF=$(grep -xE 'tests/(lane-fleet\.bh-6126|scheduler-enforce\.bh-6979|ticket-edges\.bh-6977|web-task-totp\.bh-7596|fly-pool-split\.bh-7542|issue-testhost-cert\.bh-5210)-test\.sh|\.github/.*|bin/flaky-tier\.sh|bin/lib/pool-testhost-route\.sh|bin/ci-plan\.sh' <<<"$CH")
  [ -z "$BADF" ] && ok || bad "H5 the BH-8725 commits edit a file the fix round must not: $BADF"
else
  echo "H5: skipped (no origin/main in this checkout)"
fi

# ── selection-gate fixtures ──────────────────────────────────────────────────
R="$T/repo"; mkdir -p "$R/catalog/selection-gate-host-notes.d"
cp "$NOTES" "$R/catalog/selection-gate-host-notes.d/"
g() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
g init -q -b main; g add -A; g commit -qm base
g checkout -q -b ticket/bh-8725; echo b > "$R/b.txt"; g add -A; g commit -qm change
cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' tests/fly-pool-split.bh-7542-test.sh tests/issue-testhost-cert.bh-5210-test.sh tests/x.sh > "$out"; exit 0
SH
# The runner stub prints $STUB_FILE (the run.txt body) and exits STUB_RC.
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
[ -n "${STUB_FILE:-}" ] && cat "$STUB_FILE"
exit "${STUB_RC:-0}"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
# run <case> <tree> [VAR=value …] — one REAL bin/selection-gate.sh run.
run() {
  local c="$1" tr="$2"; shift 2
  mkdir -p "$T/$c"
  env -u CI_QUARANTINE -u SELECTION_GATE_WHY_MAX HARNESS="$T/no-harness" REPO_SLUG= \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    "$@" bash "$SG" --tree "$tr" --base main --out "$T/$c/out" > "$T/$c/stdout" 2> "$T/$c/stderr"
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
# section <suite> <line...> — one remote-gate summary section.
section() { local s="$1"; shift; printf '\n===== %s (rc 1) =====\n' "$s"; printf '%s\n' "$@"; }
# body <file> <sections...> — a run.txt: the per-suite lines, the sections, the total.
body() {
  local f="$1"; shift
  { echo "remote-gate: host git context — HEAD abc, base origin/main def, merge base abc"
    echo "remote-gate: composed the catalogs CI composes before the suites (lanes-build llm-sites-build context-budgets-build)"
    grep -oE '^===== tests/[^ ]+' <<<"$*" | sed 's/^===== //' | while read -r s; do echo "FAIL $s (rc 1)"; done
    printf '%s' "$*"
    printf '\nremote-gate: 3 suites, %s failing\n' "$(grep -c '^===== ' <<<"$*")"; } > "$f"
}

# ── S7: a compose failure is could-not-run why=compose-<name> ───────────────
printf '%s\n' 'remote-gate: host git context — HEAD abc, base origin/main def, merge base abc' "$H3LINE" 'remote-gate:   Mem: 1 2 3' > "$T/s7.run"
run s7 "$R" STUB_RC=125 STUB_FILE="$T/s7.run"
S7WHY="compose-llm-sites-build: $H3LINE"
[ "$RC" = 3 ] && [ "$(gv s7 rc)" = could-not-run ] && [ "$(gv s7 why)" = "$S7WHY" ] && ok \
  || bad "S7 why=compose-<name>: <line> (exit $RC; $(cat "$T/s7/out/gate.txt" 2>/dev/null))"
# The real H3 output fed to the gate gives the same why (writer -> reader).
{ echo "remote-gate: host git context — x"; cat "$T/h3.err" 2>/dev/null; } > "$T/s7b.run"
run s7b "$R" STUB_RC=125 STUB_FILE="$T/s7b.run"
[ "$(gv s7b why)" = "$S7WHY" ] && ok || bad "S7 H3's own stderr gives the compose why (got '$(gv s7b why)')"

# ── S8: near misses ──────────────────────────────────────────────────────────
printf '%s\n' 'remote-gate: the upload to the test host failed (rsync rc 2: x) — nothing ran' > "$T/s8a.run"
run s8a "$R" STUB_RC=125 STUB_FILE="$T/s8a.run"
[ "$(gv s8a why)" = 'runner-rc-125: remote-gate: the upload to the test host failed (rsync rc 2: x) — nothing ran' ] && ok || bad "S8 another 125 keeps runner-rc-125 (got '$(gv s8a why)')"
printf '%s\n' ' remote-gate: compose-x failed (rc 1): y' > "$T/s8b.run"
run s8b "$R" STUB_RC=125 STUB_FILE="$T/s8b.run"
[ "$(gv s8b why)" = runner-rc-125 ] && ok || bad "S8 a leading-space compose line is not a compose why (got '$(gv s8b why)')"
printf '%s\n' 'remote-gate: composed the catalogs CI composes before the suites (lanes-build)' 'remote-gate: RUNNER FAILURE — x' > "$T/s8c.run"
run s8c "$R" STUB_RC=125 STUB_FILE="$T/s8c.run"
case "$(gv s8c why)" in runner-rc-125*) ok ;; *) bad "S8 the success line is not a compose why (got '$(gv s8c why)')" ;; esac
printf '%s\n' 'remote-gate: RUNNER FAILURE — the test host has 10 MB free on /srv/tmp, need 900; nothing ran' 'remote-gate:   Mem: 1 2 3' 'remote-gate:   /dev/root 7.8G 7.7G 0.1G 99% /' > "$T/s8e.run"
run s8e "$R" STUB_RC=125 STUB_FILE="$T/s8e.run"
[ "$(gv s8e why)" = 'runner-rc-125: remote-gate: RUNNER FAILURE — the test host has 10 MB free on /srv/tmp, need 900; nothing ran' ] && ok \
  || bad "S8 the host-resources dump after a runner failure is not the reason (got '$(gv s8e why)')"
body "$T/s8d.run" "$(section tests/x.sh 'remote-gate: compose-lanes-build failed (rc 2): z' '  FAIL a real one')"
run s8d "$R" STUB_RC=1 STUB_FILE="$T/s8d.run"
[ "$RC" = 1 ] && [ "$(gv s8d red)" = tests/x.sh ] && ok || bad "S8 a red with a compose line in its log stays red (exit $RC; $(cat "$T/s8d/out/gate.txt"))"

# ── N1: the shipped file parses through the gate's reader ────────────────────
N1=$( TREE="$R"; OUT="$T/n1"
  eval "$(sed -n '/^HOST_NOTE_CLASSES=/,/^}/p' "$SG")"
  host_notes_load 2> "$T/n1.err"
  printf '%s\n' "${#HN_SUITE[@]}"
  for i in "${!HN_SUITE[@]}"; do printf '%s=%s\n' "${HN_SUITE[$i]}" "${HN_CLASS[$i]}"
    grep -qE -- "${HN_ERE[$i]}" </dev/null; [ $? = 1 ] || echo "ERE-BAD $i"; done )
[ "$N1" = "2"$'\n'"$S42=shallow-context"$'\n'"$S10=host-timing" ] && [ ! -s "$T/n1.err" ] && ok \
  || bad "N1 the shipped notes: 2 rows, both classes, both EREs compile (got: $N1; $(cat "$T/n1.err"))"
grep -qE -- "$(cut -f3 <<<"$(grep -F "$S42" "$NOTES")")" <<<"$C3LIVE" && ok || bad "N1 the C3 ERE matches the live line"
grep -qE -- "$(cut -f3 <<<"$(grep -F "$S10" "$NOTES")")" <<<"$W1IX" && ok || bad "N1 the W1x ERE matches the W1ix line"

# ── Q1: both live lines: noted ───────────────────────────────────────────────
body "$T/q1.run" "$(section "$S42" '  ok C1 x' "$C3LIVE" 'fly-pool-split: 40 passed, 1 failed')$(section "$S10" "$W1X" 'issue-testhost-cert: 30 passed, 1 failed')"
run q1 "$R" STUB_RC=2 STUB_FILE="$T/q1.run"
HNQ1="$S42=shallow-context,$S10=host-timing"
[ "$RC" = 0 ] && [ "$(gv q1 rc)" = 0 ] && [ "$(gv q1 red)" = - ] && [ "$(gv q1 noted)" = "$S42,$S10" ] && ok \
  || bad "Q1 rc 0, red -, noted both (exit $RC; $(cat "$T/q1/out/gate.txt" 2>/dev/null))"
[ "$( . "$LIB" && _sg_field "$T/q1/out/gate.txt" host-noted )" = "$HNQ1" ] && ok || bad "Q1 host-noted read back with _sg_field ($(cat "$T/q1/out/gate.txt"))"
[ "$(tail -n 1 "$T/q1/out/gate.txt")" = "host-noted: $HNQ1" ] && ok || bad "Q1 host-noted is gate.txt's last line"

# ── Q2: a partial match stays red ────────────────────────────────────────────
body "$T/q2.run" "$(section "$S42" "$C3LIVE" '  FAIL C3 fpb_validate (sourced) on the real tree is rc 0')"
run q2 "$R" STUB_RC=1 STUB_FILE="$T/q2.run"
[ "$RC" = 1 ] && [ "$(gv q2 red)" = "$S42" ] && [ "$(gv q2 host-noted)" = - ] && ok || bad "Q2 a second failure keeps it red (exit $RC; $(cat "$T/q2/out/gate.txt"))"

# ── Q3: W1x and W1ix ─────────────────────────────────────────────────────────
body "$T/q3.run" "$(section "$S10" "$W1X" "$W1IX")"
run q3 "$R" STUB_RC=1 STUB_FILE="$T/q3.run"
[ "$RC" = 0 ] && [ "$(gv q3 host-noted)" = "$S10=host-timing" ] && ok || bad "Q3 W1x + W1ix noted (exit $RC; $(cat "$T/q3/out/gate.txt"))"

# ── Q4: other format, no row, silent red ─────────────────────────────────────
body "$T/q4a.run" "$(section "$S42" '  FAIL C3 0100-head.sh is not a byte prefix of bin/fly-pool.sh at the working tree (re-cut it, see README.md)')"
run q4a "$R" STUB_RC=1 STUB_FILE="$T/q4a.run"
[ "$RC" = 1 ] && [ "$(gv q4a red)" = "$S42" ] && ok || bad "Q4 'at the working tree' stays red ($(cat "$T/q4a/out/gate.txt"))"
body "$T/q4b.run" "$(section tests/x.sh "$C3LIVE")"
run q4b "$R" STUB_RC=1 STUB_FILE="$T/q4b.run"
[ "$RC" = 1 ] && [ "$(gv q4b red)" = tests/x.sh ] && ok || bad "Q4 a suite with no row stays red ($(cat "$T/q4b/out/gate.txt"))"
body "$T/q4c.run" "$(section "$S10" 'issue-testhost-cert: died')"
run q4c "$R" STUB_RC=1 STUB_FILE="$T/q4c.run"
[ "$RC" = 1 ] && [ "$(gv q4c red)" = "$S10" ] && ok || bad "Q4 a silent red stays red ($(cat "$T/q4c/out/gate.txt"))"
# The W1x line in ANOTHER suite's section does not note bh-5210.
body "$T/q4d.run" "$(section "$S10" 'FAIL: W2 something else')$(section tests/x.sh "$W1X")"
run q4d "$R" STUB_RC=2 STUB_FILE="$T/q4d.run"
[ "$RC" = 1 ] && [ "$(gv q4d red)" = "$S10,tests/x.sh" ] && ok || bad "Q4 the section stops at the next suite ($(cat "$T/q4d/out/gate.txt"))"

# ── Q6: the window hides nothing: the suite's own count must equal the matched FAIL lines ──
# run.txt holds a tail window of each suite (bin/remote-gate.sh RG_TAIL). A real FAIL above
# the window with a noted FAIL inside it must stay red: the count line says 2 failed, one matched.
body "$T/q6.run" "$(section "$S10" "$W1X" 'issue-testhost-cert (BH-5210): 88 passed, 2 failed')"
run q6 "$R" STUB_RC=1 STUB_FILE="$T/q6.run"
[ "$RC" = 1 ] && [ "$(gv q6 red)" = "$S10" ] && [ "$(gv q6 host-noted)" = - ] && ok || bad "Q6 a count line above the matched FAIL lines keeps it red ($(cat "$T/q6/out/gate.txt"))"
body "$T/q6b.run" "$(section "$S10" "$W1X" 'issue-testhost-cert (BH-5210): 89 passed, 1 failed')"
run q6b "$R" STUB_RC=1 STUB_FILE="$T/q6b.run"
[ "$RC" = 0 ] && [ "$(gv q6b host-noted)" = "$S10=host-timing" ] && ok || bad "Q6 a count line that equals the matched FAIL lines still notes ($(cat "$T/q6b/out/gate.txt"))"

# ── Q5: bad rows are skipped, loudly ─────────────────────────────────────────
R5="$T/repo5"; cp -a "$R" "$R5"
printf '%s\t%s\t%s\t%s\n' "$S10" flaky 'W1i?x' 'a wrong class' > "$R5/catalog/selection-gate-host-notes.d/bh-8725.tsv"
printf '%s\t%s\t%s\n' "$S10" host-timing 'W1i?x' >> "$R5/catalog/selection-gate-host-notes.d/bh-8725.tsv"
printf '%s\t%s\t%s\t%s\n' "$S10" host-timing 'W1(x' 'a bad ERE' >> "$R5/catalog/selection-gate-host-notes.d/bh-8725.tsv"
body "$T/q5.run" "$(section "$S10" "$W1X")"
run q5 "$R5" STUB_RC=1 STUB_FILE="$T/q5.run"
[ "$RC" = 1 ] && [ "$(gv q5 red)" = "$S10" ] && ok || bad "Q5 bad rows note nothing ($(cat "$T/q5/out/gate.txt"))"
[ "$(grep -c '^selection-gate: host-notes: skipped .*bh-8725.tsv:[123] (' "$T/q5/stderr")" = 3 ] && ok || bad "Q5 one skipped line per bad row ($(cat "$T/q5/stderr"))"

# ── Q6: no notes dir; a notes path that is not a dir ─────────────────────────
R6="$T/repo6"; cp -a "$R" "$R6"; scratch_rm "$R6/catalog/selection-gate-host-notes.d"
body "$T/q6.run" "$(section "$S10" "$W1X")"
run q6 "$R6" STUB_RC=1 STUB_FILE="$T/q6.run"
[ "$RC" = 1 ] && [ "$(gv q6 red)" = "$S10" ] && [ "$(gv q6 host-noted)" = - ] && [ ! -s "$T/q6/stderr" ] && ok || bad "Q6 no notes dir: red, quiet ($(cat "$T/q6/out/gate.txt"); $(cat "$T/q6/stderr"))"
echo x > "$R6/catalog/selection-gate-host-notes.d"
run q6b "$R6" STUB_RC=1 STUB_FILE="$T/q6.run"
[ "$RC" = 1 ] && [ "$(gv q6b red)" = "$S10" ] && ok || bad "Q6 a notes path that is a file: red ($(cat "$T/q6b/out/gate.txt"))"

# ── Q7: quarantine + host note; the lib's log line ───────────────────────────
run q7 "$R" STUB_RC=2 STUB_FILE="$T/q1.run" CI_QUARANTINE="$S10"
[ "$RC" = 0 ] && [ "$(gv q7 noted)" = "$S42,$S10" ] && [ "$(gv q7 host-noted)" = "$HNQ1" ] && ok \
  || bad "Q7 a quarantined, host-matching suite is in noted once ($(cat "$T/q7/out/gate.txt"))"
HH="$T/h2"; mkdir -p "$HH/bin"
scratch_install_closure bin/lib/selection-gate.sh "$HH" >/dev/null || { echo "FAIL: setup: cannot install the lib closure"; exit 1; }
cat > "$HH/bin/alert-line.sh" <<'SH'
#!/bin/bash
[ "$1" = --id ] && shift 2
mkdir -p "$HARNESS/logs"; echo "2026-10-28 00:00:00Z $*" >> "$HARNESS/logs/ALERTS.log"
SH
chmod +x "$HH/bin/alert-line.sh"
CO="$T/co"; mkdir -p "$CO/bin"; cp -a "$R/catalog" "$CO/"
cp "$SG" "$CO/bin/selection-gate.sh"; chmod +x "$CO/bin/selection-gate.sh"
git -C "$CO" init -q -b main
git -C "$CO" -c user.email=t@example.com -c user.name=t add -A
git -C "$CO" -c user.email=t@example.com -c user.name=t commit -qm base
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
lib q7l STUB_RC=2 STUB_FILE="$T/q1.run"
grep -q 'SELECTION-GATE rc=0 suites=3 red=- exit=0 host-noted=2$' "$T/c/q7l/build/pipeline.log" 2>/dev/null \
  && ok || bad "Q7 the SELECTION-GATE line carries host-noted=2 ($(cat "$T/c/q7l/build/pipeline.log" 2>/dev/null); $(cat "$T/c/q7l/out"))"
lib q7r STUB_RC=1 STUB_FILE="$T/q2.run"
grep -q 'SELECTION-GATE rc=1 .*red=tests/fly-pool-split' "$T/c/q7r/build/pipeline.log" 2>/dev/null && ! grep -q 'host-noted=' "$T/c/q7r/build/pipeline.log" \
  && ok || bad "Q7 no host-noted on the line when none ($(cat "$T/c/q7r/build/pipeline.log" 2>/dev/null))"
# S7 through sg_cnr_alert: one ALERTS line with the compose why, no hint.
lib s7l STUB_RC=125 STUB_FILE="$T/s7.run"
A=$(grep 'SELECTION GATE COULD NOT RUN' "$HH/logs/ALERTS.log" 2>/dev/null)
[ "$(grep -c . <<<"$A")" = 1 ] && grep -qF "COULD NOT RUN on $(hostname): $S7WHY. Builds open PRs" <<<"$A" && ok || bad "S7 one alert with the compose why ($A)"
grep -q 'Needed:' <<<"$A" && bad "S7 the generic hint is in a compose alert ($A)" || ok

echo "selection-gate-host-run.bh-8725: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
