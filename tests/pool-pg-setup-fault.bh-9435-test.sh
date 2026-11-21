#!/bin/bash
# tests/pool-pg-setup-fault.bh-9435-test.sh — a red POOL_TEST_SETUP_CMD is a named
# fault, and the suite does not run on a half-applied schema (BH-9435, plan T2).
#
# THE DEFECT THIS PINS. pgt_setup wrote `HARNESS_PG_SETUP: npm run <s> (rc=1)` and
# returned 0 ("rc is evidence, never a stop"), so HARNESS_SUITE_RUN ran the suite
# anyway. On project-6 (no pgvector in the pool Postgres) that was 967 to 1,325
# red files, and builders scoped down by hand (MK_SQL_DIR without the file).
#
# What it asserts:
#   S1  the REPRO: pgt_setup with a setup script that exits 1 writes
#       `HARNESS_FAULT: pg-setup (npm run s rc=1)` and returns 4.
#   S2  HARNESS_SUITE_RUN with setup rc 1: the fault line, the suite is never
#       called, HARNESS_EXIT: could-not-run, the Postgres is torn down, and one
#       pipeline.log `fault: pg-setup` line.
#   S3  setup rc 124 (the 300 s timeout) is the same fault.
#   S4  setup rc 0: no fault line, the suite runs, HARNESS_EXIT is its own.
#   S5  `none` and `refused` setups return 0 and write no fault line.
#   S6  pgt_run_files (the serial path): setup rc 1 on the first file marks it
#       `not run: pg-setup failed`, runs no file, and returns 125.
#   F-VR1  vr_run_files (fresh-main guard, fix-round repro) with a red `npm run`
#          setup: could-not-run, rc 2, VR_WHY names the fault, no file ran, the
#          cluster was stopped, and the node_modules link is gone.
#   F-VR2  vr_run_files with a green setup: green, and the file ran.
#   F-VR3  vr_run_files with a red `prisma db push` setup: the file still runs
#          (BH-9835 rule: a red push is evidence).
# The block is lifted VERBATIM from run-build by its markers. initdb/pg_ctl/
# postgres, setpriv and npm are stubs under $T. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset DATABASE_URL DIRECT_URL POSTGRES_URL PGPASSWORD SUPABASE_DB_URL POOL_TEST_POSTGRES POOL_TEST_SETUP_CMD \
  POOL_TEST_POSTGRES_MAJOR POOL_TEST_POSTGRES_SERIAL PGT_BIN_DIR PGT_ROOTS SETUP_RC TEST_RC TEST_SELECT
NOW=1760140800

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

mkdir -p "$T/h" "$T/fakebin" "$T/pgbin" "$T/tmp"
scratch_install_closure bin/lib/pg-test.sh "$T/h" > /dev/null || bad "cannot install bin/lib/pg-test.sh into the scratch harness"
scratch_install_closure bin/lib/lane-gate.sh "$T/h" > /dev/null || bad "cannot install bin/lib/lane-gate.sh into the scratch harness"
LIB="$T/h/bin/lib/pg-test.sh"

cat > "$T/pgbin/initdb" <<EOF
#!/bin/bash
d=""; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { d="\$2"; shift; }; shift; done
echo initdb >> "$T/pg.log"; mkdir -p "\$d"
EOF
cat > "$T/pgbin/pg_ctl" <<EOF
#!/bin/bash
d=""; verb=""; while [ \$# -gt 0 ]; do case "\$1" in -D) d="\$2"; shift ;; start|stop) verb="\$1" ;; esac; shift; done
echo "pg_ctl \$verb" >> "$T/pg.log"
case "\$verb" in start) echo 1 > "\$d/postmaster.pid" ;; stop) rm -f "\$d/postmaster.pid" ;; esac
EOF
printf '#!/bin/bash\necho "postgres (PostgreSQL) 16.14"\n' > "$T/pgbin/postgres"
cat > "$T/fakebin/setpriv" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done
exec "$@"
EOF
# npm: `run db:apply` is the setup (exit SETUP_RC); `run test` is the suite and
# leaves the marker file the cases check.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
echo "\$*" >> "$T/order.log"
case "\$2" in
  test) : > "$T/suite-ran"; exit "\${TEST_RC:-0}" ;;
  *)    exit "\${SETUP_RC:-0}" ;;
esac
EOF
chmod +x "$T/pgbin/"* "$T/fakebin/"*

REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
mkdir -p "$T/h/state"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
fresh() {
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"
  : > "$T/order.log"; : > "$T/pg.log"; rm -f "$T/suite-ran"
  printf '{"scripts":{"test":"x","db:apply":"y"}}\n' > "$REPO/package.json"
}
suite() {
  fresh
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT=project-6-os KEY=TK-1 TEST_SELECT=0 \
      PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" PGT_ROOTS="$T/tmp" LANE_GATE_NOW="$NOW"
    STAMP() { echo 2026-11-11T00:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
pgdirs() { compgen -G "$T/tmp/pgtest.*" | wc -l; }

# S1 — the plan's REPRO, as a unit.
d="$T/s1"; mkdir -p "$d"; printf '{"scripts":{"s":"exit 1"}}' > "$d/package.json"
( cd "$d" || exit 1
  export HARNESS="$T/h" POOL_TEST_SETUP_CMD="npm run s" PGT_URL=postgresql://harness@127.0.0.1:54321/postgres LANE_GATE_NOW="$NOW"
  # shellcheck source=/dev/null
  . "$LIB" || exit 9
  pgt_setup out.txt; echo "$?" > rc.txt )
grep -qx 'HARNESS_PG_SETUP: npm run s (rc=1)' "$d/out.txt" && ok || bad "S1: the setup line must stay byte for byte: $(cat "$d/out.txt")"
grep -qx 'HARNESS_FAULT: pg-setup (npm run s rc=1)' "$d/out.txt" && ok || bad "S1: a red setup must write the named fault: $(cat "$d/out.txt")"
[ "$(cat "$d/rc.txt")" = 4 ] && ok || bad "S1: a red setup must return 4 (got $(cat "$d/rc.txt"))"

# S2 — the build stops: no suite on a half-applied schema.
SETUP_RC=1 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
grep -qx 'HARNESS_FAULT: pg-setup (npm run db:apply rc=1)' "$OUT" && ok || bad "S2: the fault line must be in the suite file: $(cat "$OUT")"
[ -e "$T/suite-ran" ] && bad "S2: the suite must not run after a red setup: $(cat "$T/order.log")" || ok
grep -qx 'HARNESS_EXIT: could-not-run' "$OUT" && ok || bad "S2: HARNESS_EXIT must be could-not-run: $(cat "$OUT")"
grep -qx 'HARNESS_PG: torn down' "$OUT" && ok || bad "S2: the Postgres must be torn down: $(cat "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "S2: no pgtest.* dir may remain"
[ "$(grep -c 'HARNESS-VERIFY lenses fault: pg-setup (rc=1): the suite is not run' "$BUILD/pipeline.log")" = 1 ] && ok \
  || bad "S2: one pipeline.log fault line: $(cat "$BUILD/pipeline.log")"
tail -1 "$OUT" | grep -qx 'HARNESS_EXIT: could-not-run' && ok || bad "S2: HARNESS_EXIT must stay the last line"

# S3 — a setup timeout is the same fault.
SETUP_RC=124 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
grep -qx 'HARNESS_FAULT: pg-setup (npm run db:apply rc=124)' "$OUT" && ok || bad "S3: rc 124 must fault: $(cat "$OUT")"
[ -e "$T/suite-ran" ] && bad "S3: the suite must not run after a setup timeout" || ok
grep -qx 'HARNESS_EXIT: could-not-run' "$OUT" && ok || bad "S3: HARNESS_EXIT must be could-not-run"

# S4 — a green setup runs the suite as before.
SETUP_RC=0 TEST_RC=0 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
grep -q '^HARNESS_FAULT' "$OUT" && bad "S4: a green setup must write no fault: $(cat "$OUT")" || ok
[ -e "$T/suite-ran" ] && ok || bad "S4: a green setup must run the suite: $(cat "$T/order.log")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "S4: HARNESS_EXIT must be the suite's own: $(cat "$OUT")"
SETUP_RC=0 TEST_RC=1 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "S4: a red suite after a green setup stays its own number: $(cat "$OUT")"

# S5 — no setup asked for is no fault.
for c in '' 'npm run nope' 'rm -rf /'; do
  SETUP_RC=1 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD="$c" suite
  grep -q '^HARNESS_FAULT' "$OUT" && bad "S5('$c'): no setup run is no fault: $(cat "$OUT")" || ok
  [ -e "$T/suite-ran" ] && ok || bad "S5('$c'): the suite must still run: $(cat "$OUT")"
done

# S6 — the serial path.
fresh
mkdir -p "$REPO/src"; : > "$REPO/src/a.test.ts"; : > "$REPO/src/b.test.ts"
( cd "$REPO" || exit 1
  export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT=project-6-os PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" \
    PGT_ROOTS="$T/tmp" LANE_GATE_NOW="$NOW" SETUP_RC=1 POOL_TEST_SETUP_CMD='npm run db:apply'
  # shellcheck source=/dev/null
  . "$LIB" || exit 9
  pgt_run_files "$T/serial.txt" test src/a.test.ts src/b.test.ts; echo "$? $PGT_RUN_WHY" > "$T/serial.rc" )
[ "$(cut -d' ' -f1 "$T/serial.rc")" = 125 ] && ok || bad "S6: a red setup in the serial run must return 125 (got $(cat "$T/serial.rc"))"
grep -qx 'HARNESS_PG_FILE: src/a.test.ts (not run: pg-setup failed)' "$T/serial.txt" && ok || bad "S6: the first file is not run: $(cat "$T/serial.txt")"
grep -qx 'HARNESS_PG_FILE: src/b.test.ts (not run: an earlier pg-setup failed)' "$T/serial.txt" && ok || bad "S6: the rest are not run: $(cat "$T/serial.txt")"
[ -e "$T/suite-ran" ] && bad "S6: no file may run after a red setup" || ok
grep -q 'src/a.test.ts: pg-setup failed' "$T/serial.rc" && ok || bad "S6: PGT_RUN_WHY must name the fault: $(cat "$T/serial.rc")"
[ "$(pgdirs)" = 0 ] && ok || bad "S6: no pgtest.* dir may remain"

# F-VR1..3 — vr_run_files, the runner of the fresh-main guards and the fix-round repro.
scratch_install_closure bin/lib/verify-run.sh "$T/h" > /dev/null || bad "cannot install bin/lib/verify-run.sh into the scratch harness"
VRLIB="$T/h/bin/lib/verify-run.sh"
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
echo "npx \$*" >> "$T/order.log"
exit "\${SETUP_RC:-0}"
EOF
chmod +x "$T/fakebin/npx"
# vr <setup-cmd> <setup-rc>: one vr_run_files call on a fresh dir; writes vr.word, vr.rc and vr.why.
vr() {
  local d="$T/vr"
  scratch_rm "$d"; scratch_rm "$T/vrdeps"; mkdir -p "$d/src" "$T/vrdeps/node_modules"
  : > "$T/order.log"; : > "$T/pg.log"; rm -f "$T/suite-ran" "$T/vr.txt"
  printf '{"scripts":{"test":"x","db:apply":"y"}}\n' > "$d/package.json"
  : > "$d/src/a.test.ts"
  [ "$1" = "prisma db push" ] && { mkdir -p "$d/prisma"; : > "$d/prisma/schema.prisma"; }
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT=project-6-os PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" \
      PGT_ROOTS="$T/tmp" LANE_GATE_NOW="$NOW" SETUP_RC="$2" TEST_RC=0 POOL_TEST_POSTGRES=1 \
      POOL_TEST_SETUP_CMD="$1" VR_DEPS_FROM="$T/vrdeps"
    # shellcheck source=/dev/null
    . "$VRLIB" || exit 9
    vr_run_files "$d" "$T/vr.txt" 60 src/a.test.ts > "$T/vr.word"; echo "$?" > "$T/vr.rc"; printf '%s' "${VR_WHY:-}" > "$T/vr.why" )
}
vr 'npm run db:apply' 1
[ "$(cat "$T/vr.word")" = could-not-run ] && ok || bad "F-VR1: a red npm setup must be could-not-run (got $(cat "$T/vr.word"))"
[ "$(cat "$T/vr.rc")" = 2 ] && ok || bad "F-VR1: rc must be 2 (got $(cat "$T/vr.rc"))"
grep -q 'HARNESS_FAULT: pg-setup (npm run db:apply rc=1)' "$T/vr.why" && ok || bad "F-VR1: VR_WHY must name the fault: $(cat "$T/vr.why")"
[ -e "$T/suite-ran" ] && bad "F-VR1: no file may run after a red setup: $(cat "$T/order.log")" || ok
grep -qx 'pg_ctl stop' "$T/pg.log" && ok || bad "F-VR1: pgt_stop must run: $(cat "$T/pg.log")"
[ "$(pgdirs)" = 0 ] && ok || bad "F-VR1: no pgtest.* dir may remain"
[ -e "$T/vr/node_modules" ] && bad "F-VR1: the node_modules link must be removed" || ok
vr 'npm run db:apply' 0
[ "$(cat "$T/vr.word")" = green ] && ok || bad "F-VR2: a green setup must run green (got $(cat "$T/vr.word"): $(cat "$T/vr.txt"))"
[ -e "$T/suite-ran" ] && ok || bad "F-VR2: the file must run after a green setup: $(cat "$T/order.log")"
vr 'prisma db push' 1
grep -q '^npx prisma db push' "$T/order.log" && ok || bad "F-VR3: the prisma push must run: $(cat "$T/order.log")"
[ -e "$T/suite-ran" ] && ok || bad "F-VR3: a red prisma push is evidence, the file still runs: $(cat "$T/vr.txt")"
[ "$(cat "$T/vr.word")" = green ] && ok || bad "F-VR3: the run is the file's own verdict (got $(cat "$T/vr.word"))"
grep -q '^HARNESS_FAULT' "$T/vr.txt" && bad "F-VR3: a red prisma push writes no fault line" || ok

echo "pool-pg-setup-fault: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
