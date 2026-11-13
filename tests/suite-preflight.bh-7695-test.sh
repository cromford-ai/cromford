#!/bin/bash
# tests/suite-preflight.bh-7695-test.sh — BH-7695: a box that cannot run the
# repo suite records `could-not-run: <item>`, never a red suite.
#
# THE DEFECT THIS PINS. On 2026-10-20 a build box ran project-6 #2084's suite
# with no node_modules and no DATABASE_URL. HARNESS_SUITE_RUN wrote
# `HARNESS_EXIT: 127`, and the lens prompt reads a nonzero exit as a BLOCK, so
# the review blocked on the box, not on the code. LIVE_SUITE matched only the
# exact word `could-not-run`, so `could-not-run: node_modules` read as FAILED.
#
#   L1-L13  bin/lib/suite-preflight.sh sp_hard (node_modules)
#   L14-L19 sp_soft DATABASE_URL (only on a DB-error signature in the output)
#   L20     sp_soft SUITE_PREFLIGHT_ENV names
#   S1-S4   sp_lead_suite (the lead review host suite: no install, no alert)
#   B1-B12  HARNESS_SUITE_RUN's npm arm (the block lifted VERBATIM by its
#           markers, as verify-prelude does) with npm/npx stubs on PATH
#   V1-V4   LIVE_SUITE (lifted verbatim) on the new exit values
#   R1-R3   the #2084 replay: a project-6-shaped fixture
#   K1      every per-project settings key of the three knobs is legal
#
# No network: npm and npx are stubs, bin/alert-line.sh is a stub in the scratch
# harness. Nothing is written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset DATABASE_URL SUITE_PREFLIGHT_INSTALL SUITE_PREFLIGHT_SETUP_S SUITE_PREFLIGHT_ENV FOO \
  POOL_TEST_POSTGRES TEST_RC TEST_OUT

LIB="$DIR/bin/lib/suite-preflight.sh"
[ -r "$LIB" ] && ok || bad "$LIB is missing"

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"
awk '/^LIVE_SUITE\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RB" > "$T/live-suite.sh"
[ -s "$T/live-suite.sh" ] && ok || bad "could not extract LIVE_SUITE"

# The harness root the block loads the lib from: the lib's closure (lane-gate.sh
# with a fresh, empty settings cache, so sp_knob reads no row and falls to the
# env). bin/alert-line.sh is a stub that appends to $T/ALERTS.log.
NOW=1762041600
H="$T/h"; mkdir -p "$H/state" "$T/fakebin"
scratch_install_closure bin/lib/suite-preflight.sh "$H" >/dev/null || bad "cannot install bin/lib/suite-preflight.sh into the scratch harness"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$H/state/settings-cache.json"
export LANE_GATE_NOW="$NOW"
cat > "$H/bin/alert-line.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/ALERTS.log"
exit 0
EOF
chmod +x "$H/bin/alert-line.sh"

cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
printf 'npx %s\n' "\$*" >> "$T/order.log"
exit 0
EOF
# npm: `run test*` prints TEST_OUT (127 prints the #2084 line) and exits
# NPM_TEST_RC; `ci` and `install` exit NPM_CI_RC and make node_modules/x only
# when NPM_CI_MAKES=1.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/order.log"
case "\$1" in
  run) rc=\${NPM_TEST_RC:-0}
       if [ "\$rc" = 127 ]; then echo 'sh: 1: vitest: not found'
       else printf '%s\n' "\${TEST_OUT:-npm stub output}"; fi
       exit "\$rc" ;;
  ci|install) [ "\${NPM_CI_MAKES:-0}" = 1 ] && mkdir -p node_modules/x; exit \${NPM_CI_RC:-0} ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/npx" "$T/fakebin/npm"

DEPS='{"scripts":{"test":"vitest run"},"dependencies":{"a":"1"},"devDependencies":{"vitest":"1"}}'
NODEPS='{"scripts":{"test":"vitest run"}}'
REPO="$T/repo"; BUILD="$T/build"
# fx <package.json text|-> [prisma|prisma-dir|nm|nm-empty|pnp|lock|env-test]... -> a fresh $REPO
fx() {
  scratch_rm "$REPO"; mkdir -p "$REPO"
  [ "$1" = - ] || printf '%s\n' "$1" > "$REPO/package.json"; shift
  local a
  for a in "$@"; do
    case "$a" in
      prisma)     mkdir -p "$REPO/prisma"; echo 'generator client {}' > "$REPO/prisma/schema.prisma" ;;
      prisma-dir) mkdir -p "$REPO/prisma/schema"; echo 'model A {}' > "$REPO/prisma/schema/a.prisma" ;;
      nm)         mkdir -p "$REPO/node_modules/a" ;;
      nm-empty)   mkdir -p "$REPO/node_modules" ;;
      pnp)        echo '//' > "$REPO/.pnp.cjs" ;;
      lock)       echo '{}' > "$REPO/package-lock.json" ;;
      env-test)   echo 'DATABASE_URL=postgres://x' > "$REPO/.env.test" ;;
    esac
  done
}
# hard <cmd> -> "<SP_HARD>|<rc>" for $REPO
hard() {
  ( export HARNESS="$H"
    # shellcheck source=/dev/null
    . "$H/bin/lib/suite-preflight.sh" || exit 9
    command -v sp_hard >/dev/null || { printf 'no-sp_hard'; exit 0; }
    sp_hard "$REPO" "$1"; rc=$?
    printf '%s|%s' "$SP_HARD" "$rc" ) 2>"$T/chk.err"
}
# soft <db-provided> <output text> [from-line] -> "<SP_SOFT>|<rc>" for $REPO
soft() {
  printf '%s\n' "$2" > "$T/soft.out"
  ( export HARNESS="$H"
    # shellcheck source=/dev/null
    . "$H/bin/lib/suite-preflight.sh" || exit 9
    command -v sp_soft >/dev/null || { printf 'no-sp_soft'; exit 0; }
    sp_soft "$REPO" "$1" p "$T/soft.out" "${3:-1}"; rc=$?
    printf '%s|%s' "$SP_SOFT" "$rc" ) 2>"$T/chk.err"
}
want() { # want <case> <got> <expected>
  [ "$2" = "$3" ] && ok || bad "$1: want '$3', got '$2' ($(cat "$T/chk.err" 2>/dev/null))"
}

# ── L1-L13: sp_hard node_modules (rc 0 = no miss) ──
fx "$DEPS";                                         want L1  "$(hard "")" "node_modules|1"
fx '{"dependencies":{"a":"1"}}' nm-empty;           want L2  "$(hard "")" "node_modules|1"
fx '{"devDependencies":{"v":"1"}}';                 want L3  "$(hard "npm test")" "node_modules|1"
fx '{"dependencies":{"a":"1"}}';                    want L4  "$(hard "npx vitest run")" "node_modules|1"
fx '{"scripts":{"test:unit":"vitest run"}}';        want L5  "$(hard "")" "|0"
fx "$DEPS" nm;                                      want L6  "$(hard "")" "|0"
fx "$DEPS" pnp;                                     want L7  "$(hard "")" "|0"
fx "$DEPS";                                         want L8  "$(hard "bash tests/run.sh")" "|0"
fx -;                                               want L9  "$(hard "")" "|0"
fx '{"dependencies": {not json';                    want L10 "$(hard "")" "|0"
fx "$DEPS";                                         want L11 "$(hard "npm ci && npm test")" "|0"
fx "$DEPS";                                         want L12 "$(hard "pnpm install --frozen-lockfile && pnpm test")" "|0"
fx "$DEPS";                                         want L13 "$(hard "npm test -- --grep install")" "node_modules|1"
fx "$DEPS";                                         want L13b "$(hard "yarn test")" "node_modules|1"
fx "$DEPS";                                         want L13c "$(hard "yarn && yarn test")" "|0"
# ── L14-L19: sp_soft DATABASE_URL (rc 0 = a miss) ──
fx "$NODEPS" prisma;     want L14 "$(soft 0 'Error: P1001: Can'"'"'t reach database server at x')" "DATABASE_URL|0"
fx "$NODEPS" prisma-dir; got=$(DATABASE_URL="" soft 0 'Environment variable not found: DATABASE_URL.'); want L15 "$got" "DATABASE_URL|0"
fx "$NODEPS" prisma;     want L16 "$(soft 0 'AssertionError: expected 2 to be 3')" "|1"
fx "$NODEPS" prisma;     got=$(DATABASE_URL=postgres://x soft 0 'Error: P1001'); want L17a "$got" "|1"
fx "$NODEPS" prisma;     want L17b "$(soft 1 'Error: P1001')" "|1"
fx "$NODEPS" prisma env-test; want L18 "$(soft 0 'Error: P1001')" "|1"
fx "$NODEPS";            want L19a "$(soft 0 'Error: P1001')" "|1"
fx "$NODEPS" prisma;     want L19b "$(soft 0 $'PrismaClientInitializationError in the prelude\nok 1 suite\nAssertionError: x' 2)" "|1"
# ── L20: SUITE_PREFLIGHT_ENV names; a bad name is ignored on stderr ──
fx "$NODEPS"; got=$(SUITE_PREFLIGHT_ENV="FOO bad-name" soft 0 'x'); want L20a "$got" "FOO|0"
grep -q 'bad-name' "$T/chk.err" && ok || bad "L20: an unusable name must be named on stderr: $(cat "$T/chk.err")"
fx "$NODEPS"; got=$(FOO=1 SUITE_PREFLIGHT_ENV="FOO" soft 0 'x'); want L20b "$got" "|1"

# ── S1-S4: sp_lead_suite, the lead review host suite ──
# lead <cmd> -> "<SP_LINE>|<SP_RC>" for $REPO; the suite output goes to $T/lead.out
lead() {
  : > "$T/order.log"; rm -f "$T/lead.out"
  ( export HARNESS="$H" PATH="$T/fakebin:$PATH"
    # shellcheck source=/dev/null
    . "$H/bin/lib/suite-preflight.sh" || exit 9
    command -v sp_lead_suite >/dev/null || { printf 'no-sp_lead_suite'; exit 0; }
    SP_RC=""
    sp_lead_suite "$REPO" "$1" 60 p "$T/lead.out" || printf 'rc-nonzero:'
    printf '%s|%s' "$SP_LINE" "$SP_RC" ) 2>"$T/chk.err"
}
calm_lead() { rm -f "$T/ALERTS.log"; }
# S1: a hard miss runs nothing and says so in the line and in the output.
calm_lead; fx "$DEPS"
want S1 "$(lead "npm run test")" "host suite: could-not-run: node_modules (not run; the review worktree has no installed packages): npm run test|"
[ -s "$T/order.log" ] && bad "S1 the suite or an install ran: $(cat "$T/order.log")" || ok
grep -q '^HARNESS_PREFLIGHT: could-not-run: node_modules .*never a BLOCK' "$T/lead.out" 2>/dev/null && ok || bad "S1 no note in the output: $(cat "$T/lead.out" 2>/dev/null)"
grep -qF 'No host suite ran on this head.' "$T/lead.out" 2>/dev/null && ok || bad "S1 the output must say no suite ran"
[ -s "$T/ALERTS.log" ] && bad "S1 the lead path must not alert" || ok
# S2: ready, green: today's line, byte for byte.
fx "$DEPS" nm; got=$(NPM_TEST_RC=0 TEST_OUT='ok 3 passed' lead "npm run test")
want S2 "$got" "host suite: npm run test rc=0|0"
grep -qx 'run test' "$T/order.log" && ok || bad "S2 the suite did not run: $(cat "$T/order.log")"
grep -qx 'ok 3 passed' "$T/lead.out" 2>/dev/null && ok || bad "S2 the suite output is not in the out file"
# S3: ready, an assertion red stays red.
fx "$DEPS" nm; got=$(NPM_TEST_RC=1 TEST_OUT='AssertionError: expected 2 to be 3' lead "npm run test")
want S3 "$got" "host suite: npm run test rc=1|1"
grep -q '^HARNESS_PREFLIGHT' "$T/lead.out" 2>/dev/null && bad "S3 a real red carries a note" || ok
# S4: prisma, no URL, a DB-signature red: could-not-run, note first and last.
fx "$NODEPS" prisma; got=$(NPM_TEST_RC=1 TEST_OUT="Error: P1001: Can't reach database server at localhost:5432" lead "npm run test")
want S4 "$got" "host suite: could-not-run: DATABASE_URL (suite rc 1): npm run test|1"
head -n 1 "$T/lead.out" 2>/dev/null | grep -q '^HARNESS_PREFLIGHT: could-not-run: DATABASE_URL (suite rc 1)' && ok || bad "S4 the note must be the first line: $(head -n 1 "$T/lead.out" 2>/dev/null)"
tail -n 1 "$T/lead.out" 2>/dev/null | grep -q '^HARNESS_PREFLIGHT: could-not-run: DATABASE_URL (suite rc 1)' && ok || bad "S4 the note must be the last line: $(tail -n 1 "$T/lead.out" 2>/dev/null)"
grep -q 'P1001' "$T/lead.out" 2>/dev/null && ok || bad "S4 the suite output must stay in the file"
[ -s "$T/ALERTS.log" ] && bad "S4 the lead path must not alert" || ok

# ── the build arm ──
# run [lib|nolib] -> HARNESS_SUITE_RUN lenses over $REPO into a fresh $BUILD
run() {
  scratch_rm "$BUILD"; mkdir -p "$BUILD"; : > "$T/order.log"
  # nolib: the lib is moved aside for this run only (the code before BH-7695)
  [ "${1:-lib}" = nolib ] && mv "$H/bin/lib/suite-preflight.sh" "$T/suite-preflight.off"
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$H" BUILD PROJECT="${PROJ:-p}" KEY=K-1 TEST_SELECT=0 SUITE_PREFLIGHT_TODAY=20261102
    STAMP() { echo 2026-11-02T00:00:00Z; }
    STAGE_START() { echo 1; }
    STAGE_END() { echo "STAGE_END $1" >> "$T/order.log"; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
  [ -e "$T/suite-preflight.off" ] && mv "$T/suite-preflight.off" "$H/bin/lib/suite-preflight.sh"
  return 0
}
F="$BUILD/harness-suite.txt"
last() { tail -n 1 "$F"; }
ran_suite() { grep -q '^run test' "$T/order.log"; }
alerts() { grep -c 'suite-preflight' "$T/ALERTS.log" 2>/dev/null || true; }
calm() { rm -f "$T/ALERTS.log"; scratch_rm "$H/state/suite-preflight"; }

# B1: one setup attempt that works, then the suite runs.
calm; fx "$DEPS" lock; NPM_CI_MAKES=1 run
grep -qx 'HARNESS_PREFLIGHT: setup npm ci --no-audit --no-fund (rc=0)' "$F" && ok || bad "B1 no setup line: $(cat "$F")"
ran_suite && ok || bad "B1 the suite must run after a setup that made node_modules: $(cat "$T/order.log")"
[ "$(last)" = 'HARNESS_EXIT: 0' ] && ok || bad "B1 last line: $(last)"

# B2: the setup fails and makes nothing: the suite never runs.
calm; fx "$DEPS" lock prisma; NPM_CI_RC=1 run
ran_suite && bad "B2 the suite ran on a box with no node_modules: $(cat "$T/order.log")" || ok
grep -q '^npx prisma' "$T/order.log" && bad "B2 the prisma prelude ran: $(cat "$T/order.log")" || ok
[ "$(last)" = 'HARNESS_EXIT: could-not-run: node_modules' ] && ok || bad "B2 last line: $(last)"
grep -qx 'HARNESS_PREFLIGHT: setup npm ci --no-audit --no-fund (rc=1)' "$F" && ok || bad "B2 the setup rc must be the real one: $(cat "$F")"
grep -q '^HARNESS_PREFLIGHT: could-not-run: node_modules .*never a BLOCK' "$F" && ok || bad "B2 no could-not-run preflight line: $(cat "$F")"
grep -q 'HARNESS-VERIFY lenses preflight: could-not-run: node_modules' "$BUILD/pipeline.log" && ok || bad "B2 pipeline.log: $(cat "$BUILD/pipeline.log")"
grep -qx 'STAGE_END suite' "$T/order.log" && ok || bad "B2 STAGE_END still runs: $(cat "$T/order.log")"
# an install whose rc is 0 but which made nothing is not trusted
calm; fx "$DEPS" lock; run
[ "$(last)" = 'HARNESS_EXIT: could-not-run: node_modules' ] && ok || bad "B2 rc 0 with no node_modules must still be could-not-run: $(last)"
cp -r "$BUILD" "$T/build-b2"

# B3: SUITE_PREFLIGHT_INSTALL=0: no install, the same could-not-run.
calm; fx "$DEPS" lock; SUITE_PREFLIGHT_INSTALL=0 NPM_CI_MAKES=1 run
grep -qE '^(ci|install)' "$T/order.log" && bad "B3 install ran with the knob at 0: $(cat "$T/order.log")" || ok
[ "$(last)" = 'HARNESS_EXIT: could-not-run: node_modules' ] && ok || bad "B3 last line: $(last)"
# B3b: no lockfile: npm install with no lockfile written.
calm; fx "$DEPS"; NPM_CI_MAKES=1 run
grep -qx 'install --no-audit --no-fund --no-package-lock' "$T/order.log" && ok || bad "B3b no-lock install call: $(cat "$T/order.log")"
grep -qx 'HARNESS_PREFLIGHT: setup npm install --no-audit --no-fund --no-package-lock (rc=0)' "$F" && ok || bad "B3b setup line: $(cat "$F")"
# B3c: the SUITE_PREFLIGHT_SETUP_S knob is the bound the setup runs under (a
# `timeout` stub, first on PATH for this case only, logs its first two words).
mkdir -p "$T/tbin"
cat > "$T/tbin/timeout" <<EOF
#!/bin/bash
printf 'timeout %s %s\n' "\$1" "\$2" >> "$T/order.log"
shift; exec "\$@"
EOF
chmod +x "$T/tbin/timeout"
calm; fx "$DEPS" lock; PATH="$T/tbin:$PATH" SUITE_PREFLIGHT_SETUP_S=60 NPM_CI_MAKES=1 run
grep -qx 'timeout 60 npm' "$T/order.log" && ok || bad "B3c the setup must run under timeout 60: $(cat "$T/order.log")"
calm; fx "$DEPS" lock; PATH="$T/tbin:$PATH" SUITE_PREFLIGHT_SETUP_S=5 NPM_CI_MAKES=1 run
grep -qx 'timeout 900 npm' "$T/order.log" && ok || bad "B3c an out-of-range bound must fall back to 900: $(cat "$T/order.log")"

# B4/B5: prisma, no URL: an assertion red stays red; a DB-signature red is the box's.
calm; fx "$NODEPS" prisma; NPM_TEST_RC=1 TEST_OUT='AssertionError: expected 2 to be 3' run
[ "$(last)" = 'HARNESS_EXIT: 1' ] && ok || bad "B4 a real red must stay red: $(last)"
grep -q '^HARNESS_PREFLIGHT' "$F" && bad "B4 a real red carries a preflight line: $(cat "$F")" || ok
calm; fx "$NODEPS" prisma; NPM_TEST_RC=1 TEST_OUT="Error: P1001: Can't reach database server at localhost:5432" run
ran_suite && ok || bad "B5 a soft miss must still run the suite"
[ "$(last)" = 'HARNESS_EXIT: could-not-run: DATABASE_URL (suite rc 1)' ] && ok || bad "B5 last line: $(last)"
grep -q '^HARNESS_PREFLIGHT: could-not-run: DATABASE_URL' "$F" && ok || bad "B5 no preflight line: $(cat "$F")"
calm; fx "$NODEPS" prisma; NPM_TEST_RC=0 TEST_OUT="Error: P1001" run
[ "$(last)" = 'HARNESS_EXIT: 0' ] && ok || bad "B5 a green stays green: $(last)"

# B6: the real evidence-summary prints the value as it is.
OUT=$(bash "$DIR/bin/evidence-summary.sh" "$T/build-b2" 2>/dev/null)
grep -qF '`HARNESS_EXIT: could-not-run: node_modules`' <<<"$OUT" && ok || bad "B6 evidence-summary: $(grep -i 'repo suite' <<<"$OUT")"

# B7: the real evidence reader skips the could-not-run file as a source.
sed -i '$i FAIL tests/a.test.ts > x' "$T/build-b2/harness-suite.txt"
got=$( . "$DIR/bin/lib/evidence.sh" && evidence_locate "$T/build-b2" tests/a.test.ts | cut -f1 )
[ "$got" != fail ] && ok || bad "B7 a could-not-run file must decide nothing: $got"

# B8: no deps, no prisma, rc 3: the bytes of a run with no lib at all.
calm; fx "$NODEPS"; NPM_TEST_RC=3 run lib; cp "$F" "$T/b8-lib"
NPM_TEST_RC=3 run nolib; cp "$F" "$T/b8-nolib"
[ "$(tail -n 1 "$T/b8-lib")" = 'HARNESS_EXIT: 3' ] && ok || bad "B8 last line: $(tail -n 1 "$T/b8-lib")"
cmp -s "$T/b8-lib" "$T/b8-nolib" && ok || bad "B8 the ready path changed the file: $(diff "$T/b8-lib" "$T/b8-nolib")"
[ -s "$T/ALERTS.log" ] && bad "B8 a ready repo alerted" || ok

# B9: one alert per project per UTC day, through bin/alert-line.sh --id.
calm; fx "$DEPS"; NPM_CI_RC=1 run; NPM_CI_RC=1 run
[ "$(alerts)" = 1 ] && ok || bad "B9 two misses must alert once: $(cat "$T/ALERTS.log" 2>/dev/null)"
PROJ=q NPM_CI_RC=1 run
[ "$(alerts)" = 2 ] && ok || bad "B9 a second project must alert: $(cat "$T/ALERTS.log" 2>/dev/null)"
grep -q -- '--id suite-preflight-q-' "$T/ALERTS.log" 2>/dev/null && ok || bad "B9 the alert must go through --id: $(cat "$T/ALERTS.log" 2>/dev/null)"
grep -q 'q/K-1.*could-not-run: node_modules' "$T/ALERTS.log" 2>/dev/null && ok || bad "B9 the line names project q and the item"
grep -q 'Infra, not a PR finding' "$T/ALERTS.log" 2>/dev/null && ok || bad "B9 the alert must say infra: $(cat "$T/ALERTS.log" 2>/dev/null)"
[ -e "$H/state/suite-preflight/alerted-q-20261102" ] && ok || bad "B9 no flag for q today: $(ls "$H/state/suite-preflight/" 2>/dev/null)"
# an old flag is dropped on the next write
calm; mkdir -p "$H/state/suite-preflight"; : > "$H/state/suite-preflight/alerted-p-20200101"; fx "$DEPS"; NPM_CI_RC=1 run
[ -e "$H/state/suite-preflight/alerted-p-20200101" ] && bad "B9 an old flag must be deleted" || ok

# B10: ENOSPC red (BH-8175 path) with no deps: could-not-run, unchanged.
calm; fx "$NODEPS" prisma; NPM_TEST_RC=1 TEST_OUT=$'Error: P1001\nENOSPC: no space left on device, write' run
[ "$(last)" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "B10 the ENOSPC exit must stay as it is: $(last)"

# B11: the BH-8499 serial path (each file on its own harness Postgres) provides
# the DB, so a P1001 red there stays the integer red it is. pg-test.sh and the
# selector are stubs for this case: serial on, one selected file, a red run.
# Two guards hold here: the serial run writes above the from-line (n0), and
# serial=1 counts as a provided DB. This case cannot tell them apart.
cat > "$H/bin/lib/pg-test.sh" <<'EOF'
pgt_enabled() { return 0; }
pgt_serial() { return 0; }
pgt_run_files() { echo "Error: P1001: Can't reach database server at 127.0.0.1" >> "$1"; return 1; }
pgt_verdict() { PGT_VERDICT_RC=1; PGT_VERDICT="1 of 1 file(s) red"; PGT_RUN_DISK=""; }
EOF
printf '#!/bin/bash\necho tests/a.test.ts\n' > "$H/bin/lib/test-select.sh"; chmod +x "$H/bin/lib/test-select.sh"
calm; fx "$NODEPS" prisma; BASE=x TEST_SELECT_EFFECTIVE=1 run
grep -q '^HARNESS_PG_SERIAL: on' "$F" && ok || bad "B11 the serial path did not run: $(cat "$F")"
[ "$(last)" = 'HARNESS_EXIT: 1' ] && ok || bad "B11 a red on the harness Postgres must stay red: $(last)"
scratch_rm "$H/bin/lib/pg-test.sh"; scratch_rm "$H/bin/lib/test-select.sh"

# B12: a CI-locale miss (BH-9285, ce_suite_record rc 1) on a ready repo: the
# block's own `could-not-run` passes the post hook unchanged.
cat > "$H/bin/lib/ci-env.sh" <<'EOF'
ce_suite_record() { echo "HARNESS_LOCALE: could-not-run (stub)" >> "$2"; return 1; }
EOF
calm; fx "$DEPS" nm prisma; NPM_TEST_RC=1 TEST_OUT='Error: P1001' run
[ "$(last)" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "B12 the CI-locale exit must stay as it is: $(last)"
grep -q '^HARNESS_PREFLIGHT' "$F" && bad "B12 a locale miss carries a preflight line: $(cat "$F")" || ok
scratch_rm "$H/bin/lib/ci-env.sh"

# ── V1-V4: LIVE_SUITE ──
live() { # live <exit value> -> "<kind>|<text>"
  printf 'HARNESS_SUITE: x\nHARNESS_EXIT: %s\n' "$1" > "$T/live.txt"
  ( LIVE() { printf '%s|%s' "$2" "$3"; }
    # shellcheck source=/dev/null
    . "$T/live-suite.sh"; LIVE_SUITE "$T/live.txt" "" )
}
got=$(live 'could-not-run: node_modules')
case "$got" in "not-run|"*node_modules*) ok ;; *) bad "V1 could-not-run: node_modules must be not-run naming it: $got" ;; esac
case "$got" in *FAILED*) bad "V1 must not say FAILED: $got" ;; *) ok ;; esac
got=$(live 'could-not-run: DATABASE_URL (suite rc 1)')
case "$got" in "not-run|"*'DATABASE_URL (suite rc 1)'*) ok ;; *) bad "V2: $got" ;; esac
got=$(live 'could-not-run')
case "$got" in "not-run|"*HARNESS_DISK*) ok ;; *) bad "V3 the bare word keeps today's text: $got" ;; esac
got=$(live 'could-not-runx'); case "$got" in "fail|"*) ok ;; *) bad "V4 near miss must be fail: $got" ;; esac
got=$(live 1); case "$got" in "fail|"*) ok ;; *) bad "V4 1 must be fail: $got" ;; esac
got=$(live 0); case "$got" in "pass|"*) ok ;; *) bad "V4 0 must be pass: $got" ;; esac

# ── R1-R3: the #2084 replay ──
# project-6's package.json shape (example-org/project-6 main), its prisma/schema/
# dir, no node_modules, no DATABASE_URL, an `npm ci` that fails and makes
# nothing, and a suite that cannot find vitest.
MK='{"name":"project-6","private":true,"scripts":{"test":"vitest run --reporter=agent"},"dependencies":{"@prisma/client":"6","next":"15"},"devDependencies":{"prisma":"6","vitest":"4"}}'
# R1 first: the block with no lib is the code before this change.
calm; fx "$MK" prisma-dir lock; NPM_CI_RC=1 NPM_TEST_RC=127 run nolib
[ "$(last)" = 'HARNESS_EXIT: 127' ] && ok || bad "R1 the run before the change must be 127: $(last)"
calm; fx "$MK" prisma-dir lock; NPM_CI_RC=1 NPM_TEST_RC=127 run
ran_suite && bad "R2 the #2084 replay ran the suite: $(cat "$T/order.log")" || ok
[ "$(last)" = 'HARNESS_EXIT: could-not-run: node_modules' ] && ok || bad "R2 last line: $(last)"
grep -q 'vitest: not found' "$F" && bad "R3 a suite output is in the file" || ok
cp "$F" "$T/live.txt"
got=$( LIVE() { printf '%s' "$2"; }; . "$T/live-suite.sh"; LIVE_SUITE "$T/live.txt" "" )
[ "$got" = not-run ] && ok || bad "R3 LIVE_SUITE over the replay file: $got"

# ── K1: every per-project settings key of the three knobs is legal ──
# The settings route accepts ^[a-z0-9_.-]{1,64}$ (worker/jobs/src/routes/settings.js).
# PR #8960 named the bound SUITE_PREFLIGHT_INSTALL_TIMEOUT_S, 67 chars at the
# longest project, and tests/lanes-registry-test.sh went red on main.
PROJS=$(awk 'NF && $1!~/^#/{print $1}' "$DIR/fleet.conf" | sort -u)
[ -n "$PROJS" ] && ok || bad "K1 no project in fleet.conf"
for knob in SUITE_PREFLIGHT_INSTALL SUITE_PREFLIGHT_SETUP_S SUITE_PREFLIGHT_ENV; do
  kf="$DIR/catalog/lanes.d/fly-pool.knobs.d/$knob.json"
  [ "$(jq -r .env "$kf" 2>/dev/null)" = "$knob" ] && ok || bad "K1 $kf is missing or names another env"
  low=$(printf '%s' "$knob" | tr '[:upper:]' '[:lower:]')
  for proj in $PROJS; do
    k="lane.fly-pool.$proj.$low"
    [[ "$k" =~ ^[a-z0-9_.-]{1,64}$ ]] && ok || bad "K1 settings key $k (${#k}) is refused by the settings route"
  done
done
# near miss: the #8960 name at the longest project is over the limit
long=$(awk '{ if (length($0) > length(m)) m=$0 } END { print m }' <<<"$PROJS")
k="lane.fly-pool.$long.suite_preflight_install_timeout_s"
[[ "$k" =~ ^[a-z0-9_.-]{1,64}$ ]] && bad "K1 near miss: $k (${#k}) should be over 64" || ok

echo "suite-preflight.bh-7695: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
