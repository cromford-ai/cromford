#!/bin/bash
# tests/pool-test-postgres-serial.bh-8499-test.sh — the throwaway Postgres on a
# small disk: the most-room root, the ENOSPC rerun of the failed files, and the
# serial run (one fresh cluster per file).
#
# What it asserts:
#   R1-R4   pgt_root picks the candidate with the MOST free MB (a tie keeps list
#           order); a file or a non-writable dir is skipped.
#   F1-F13  pgt_failed_files reads `FAIL <path>` lines of a red run: only real
#           test files in the repo, deduped, under the rerun cap knob; a FAIL
#           line it cannot use refuses the whole list (rc 3).
#   P1-P10  pgt_run_files runs each file on its own fresh cluster, inside the
#           budget knob, and returns 0 / the first red rc / 125 (could not run).
#   X1-X10  HARNESS_SUITE_RUN reruns the failed files once after an ENOSPC red,
#           and only when the rerun is eligible.
#   S1-S7   POOL_TEST_POSTGRES_SERIAL=1 runs a selected suite one file at a time.
#   K1      the three knob rows.
#
# The suite-run block is lifted VERBATIM from the pipeline by its markers, as
# pool-test-postgres-enospc.bh-8175-test does. initdb/pg_ctl/postgres, setpriv,
# npm, df and date are stubs under $T. No network, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset DATABASE_URL DIRECT_URL POSTGRES_URL PGPASSWORD SUPABASE_DB_URL POOL_TEST_POSTGRES POOL_TEST_SETUP_CMD \
  POOL_TEST_POSTGRES_MAJOR POOL_TEST_POSTGRES_MIN_FREE_MB POOL_TEST_POSTGRES_SERIAL POOL_TEST_PG_RERUN_MAX_FILES \
  POOL_TEST_PG_SERIAL_BUDGET_S PGT_BIN_DIR PGT_ROOTS TEST_RC TEST_OUT TEST_SELECT
NOW=1760140800

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"
awk '/^LIVE_SUITE\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RB" > "$T/live-suite.sh"
[ -s "$T/live-suite.sh" ] && ok || bad "could not extract LIVE_SUITE"

mkdir -p "$T/h" "$T/fakebin" "$T/pgbin" "$T/tmp" "$T/shm" "$T/free" "$T/out" "$T/rc" "$T/hook"
scratch_install_closure bin/lib/pg-test.sh "$T/h" > /dev/null || bad "cannot install bin/lib/pg-test.sh into the scratch harness"
scratch_install_closure bin/lib/lane-gate.sh "$T/h" > /dev/null || bad "cannot install bin/lib/lane-gate.sh into the scratch harness"
LIB="$T/h/bin/lib/pg-test.sh"

# Stubs. initdb logs the data dir it was given; df answers from $T/free/<name>.
cat > "$T/pgbin/initdb" <<EOF
#!/bin/bash
d=""; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { d="\$2"; shift; }; shift; done
echo "initdb \$d" >> "$T/pg.log"
mkdir -p "\$d"
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
# npm: `npm run test` (the whole run, or a multi-file selection) answers TEST_OUT/TEST_RC.
# `npm run test -- <one file>` sources $T/hook/<base> (a fake clock or disk change),
# prints $T/out/<base> and exits $T/rc/<base> (default 0). `npm run setup` is green.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
echo "\$*" >> "$T/order.log"
[ "\$1" = run ] || exit 0
case "\$2" in test) ;; setup) echo "setup ran"; exit 0 ;; *) exit 0 ;; esac
if [ "\${3:-}" = -- ] && [ \$# = 4 ]; then
  b=\$(basename "\$4")
  [ -r "$T/hook/\$b" ] && . "$T/hook/\$b"
  [ -r "$T/out/\$b" ] && cat "$T/out/\$b"
  exit "\$(cat "$T/rc/\$b" 2>/dev/null || echo 0)"
fi
[ -n "\${TEST_OUT:-}" ] && printf '%s\n' "\$TEST_OUT"
exit "\${TEST_RC:-0}"
EOF
cat > "$T/fakebin/df" <<EOF
#!/bin/bash
p="\${@: -1}"; f="$T/free/\$(echo "\$p" | tr / _)"
[ -r "\$f" ] || f="$T/free/default"
echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"
echo "fake 100000 1 \$(cat "\$f") 1% \$p"
EOF
# date: `date +%s` is the fake clock in $T/now.
cat > "$T/fakebin/date" <<EOF
#!/bin/bash
[ "\${1:-}" = +%s ] && [ -r "$T/now" ] && { cat "$T/now"; exit 0; }
exec /bin/date "\$@"
EOF
chmod +x "$T/pgbin/"* "$T/fakebin/"*
# free <root> <MB> — what the df stub answers for that root.
free() { echo "$2" > "$T/free/$(echo "$1" | tr / _)"; }
echo 100000 > "$T/free/default"
# fo <base> <rc> [output] — what `npm run test -- tests/<base>` answers.
fo() { echo "$2" > "$T/rc/$1"; if [ $# -ge 3 ]; then printf '%s\n' "$3" > "$T/out/$1"; else rm -f "$T/out/$1"; fi; }
# reset — every per-file answer green, roots roomy, the clock at 1000, no rows.
reset() {
  rm -f "$T/out/"* "$T/rc/"* "$T/hook/"*; echo 1000 > "$T/now"
  free "$T/shm" 4000; free "$T/tmp" 4000
  printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
}
row() { printf '{"fetched_at":%s,"values":{"lane.fly-pool.project-6-os.%s":"%s"},"seeded":{}}\n' "$NOW" "$1" "$2" > "$T/h/state/settings-cache.json"; }
mkdir -p "$T/h/state"; reset

# The selector stub: a TEST_SELECT=1 run selects what $T/select.txt holds.
mkdir -p "$T/h/bin/lib"
printf '#!/bin/bash\ncat "%s/select.txt"\n' "$T" > "$T/h/bin/lib/test-select.sh"; chmod +x "$T/h/bin/lib/test-select.sh"
printf 'tests/a.test.ts\ntests/b.test.ts\ntests/c.test.ts\n' > "$T/select.txt"

# mkrepo <dir> — a repo with test and setup scripts and real test files.
mkrepo() {
  scratch_rm "$1"; mkdir -p "$1/tests" "$1/src"
  printf '{"scripts":{"test":"x","setup":"y"}}\n' > "$1/package.json"
  for f in a b c d; do : > "$1/tests/$f.test.ts"; done
  : > "$1/tests/b.test.js"; : > "$1/tests/c.spec.tsx"; : > "$1/src/a.ts"
  for f in $(seq 1 21); do : > "$1/tests/n$f.test.ts"; done
}
REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"; UREPO="$T/urepo"
mkrepo "$UREPO"
# suite [phase] — HARNESS_SUITE_RUN <phase> (default lenses) in a fresh repo.
suite() {
  local phase="${1:-lenses}"
  mkrepo "$REPO"; scratch_rm "$BUILD"; mkdir -p "$BUILD"
  : > "$T/order.log"; : > "$T/pg.log"
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT=project-6-os KEY=TK-1 TEST_SELECT="${TEST_SELECT:-0}" \
      BASE=origin/main PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" LANE_GATE_NOW="$NOW" PGT_ROOTS="${PGT_ROOTS:-$T/shm $T/tmp}"
    STAMP() { echo 2026-10-27T00:00:00Z; }
    STAGE_START() { echo 1; }
    STAGE_END() { echo "STAGE_END $1" >> "$T/order.log"; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt "$phase" )
}
pgdirs() { { compgen -G "$T/tmp/pgtest.*"; compgen -G "$T/shm/pgtest.*"; compgen -G "$T/a/pgtest.*"; } | wc -l; }
datadir() { sed -n 's/^initdb //p' "$T/pg.log" | head -1; }
n() { grep -c -x -F -- "$1" "$2"; }
live() { ( LIVE() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }; . "$T/live-suite.sh"; LIVE_SUITE "$1" '' ); }
# lib <fn-call...> — run the lib in the unit repo with the stubs on PATH.
lib() {
  ( cd "$UREPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT=project-6-os LANE_GATE_NOW="$NOW" TMPDIR="$T/tmp" \
      PGT_BIN_DIR="$T/pgbin" PGT_ROOTS="${PGT_ROOTS:-$T/shm $T/tmp}"
    . "$LIB"; "$@" )
}
root_of() { lib bash -c '. "$0"; r=$(pgt_root) || { echo "rc=$?"; exit 0; }; echo "$r"' "$LIB"; }

# ---- R: the most-room root ---------------------------------------------------
free "$T/shm" 5000; free "$T/tmp" 9000
[ "$(root_of)" = "$T/tmp" ] && ok || bad "R1: shm 5000, tmp 9000 → tmp (most room): '$(root_of)'"
POOL_TEST_POSTGRES=1 suite
case "$(datadir)" in "$T/tmp/pgtest."??????/data) ok ;; *) bad "R1: the suite's data dir must be under $T/tmp: '$(datadir)'" ;; esac
free "$T/shm" 9000; free "$T/tmp" 5000
[ "$(root_of)" = "$T/shm" ] && ok || bad "R2: shm 9000, tmp 5000 → shm: '$(root_of)'"
free "$T/shm" 4000; free "$T/tmp" 4000
[ "$(root_of)" = "$T/shm" ] && ok || bad "R3: a tie keeps list order (shm first): '$(root_of)'"
mkdir -p "$T/a" "$T/b"; : > "$T/afile"; free "$T/a" 600; free "$T/afile" 9000
[ "$(PGT_ROOTS="$T/afile $T/a" root_of)" = "$T/a" ] && ok || bad "R4: a file with the most room is skipped: '$(PGT_ROOTS="$T/afile $T/a" root_of)'"
chmod 555 "$T/b"; free "$T/b" 9000
if [ ! -w "$T/b" ]; then
  [ "$(PGT_ROOTS="$T/b $T/a" root_of)" = "$T/a" ] && ok || bad "R4: a non-writable dir with the most room is skipped"
else echo "SKIP R4 not-writable: running as root"; fi
chmod 755 "$T/b"
free "$T/b" 400
[ "$(PGT_ROOTS="$T/b $T/a" root_of)" = "$T/a" ] && ok || bad "R4: 400 MB is below the 512 min: '$(PGT_ROOTS="$T/b $T/a" root_of)'"
[ "$(PGT_ROOTS="$T/b" root_of)" = "rc=1" ] && ok || bad "R4: no root with room is rc 1"
reset

# ---- F: the failed files of a red run -----------------------------------------
# ff <from-line> [VAR=val...] < output — "rc=N|path,path,"
ff() {
  cat > "$T/ff.txt"
  local from="$1"; shift
  lib env "$@" bash -c '. "$0"; command -v pgt_failed_files >/dev/null || { echo no-fn; exit 0; }
    l=$(pgt_failed_files "$1" "$2"); r=$?; printf "rc=%s|%s" "$r" "$(printf "%s" "$l" | tr "\n" ",")"' "$LIB" "$T/ff.txt" "$from"
}
v=$(printf ' FAIL  tests/a.test.ts > suite > adds\n' | ff 1)
[ "$v" = 'rc=0|tests/a.test.ts' ] && ok || bad "F1: vitest FAIL line: '$v'"
v=$(printf 'FAIL tests/b.test.js\n' | ff 1)
[ "$v" = 'rc=0|tests/b.test.js' ] && ok || bad "F2: jest FAIL line: '$v'"
v=$(printf '\033[31mFAIL\033[39m tests/c.spec.tsx\n' | ff 1)
[ "$v" = 'rc=0|tests/c.spec.tsx' ] && ok || bad "F3: an ANSI-coloured FAIL line: '$v'"
v=$(printf ' FAIL  tests/a.test.ts > s > x\nFAIL tests/b.test.js\n FAIL  tests/a.test.ts > s > y\n' | ff 1)
[ "$v" = 'rc=0|tests/a.test.ts,tests/b.test.js' ] && ok || bad "F4: dedupe in first-seen order: '$v'"
# Lines that are not FAIL lines name no file.
NEAR=$(printf '%s\n' 'PASS tests/a.test.ts' '✓ tests/a.test.ts' 'Test Files  2 failed | 3 passed' 'FAILED: x' \
  '  ✗ handles FAIL tests/a.test.ts' 'FAILtests/a.test.ts')
v=$(printf '%s\n' "$NEAR" | ff 1)
[ "$v" = 'rc=1|' ] && ok || bad "F5: no near miss is a failed file: '$v'"
v=$(printf '%s\nFAIL tests/d.test.ts\n' "$NEAR" | ff 1)
[ "$v" = 'rc=0|tests/d.test.ts' ] && ok || bad "F6: near misses around one real FAIL line keep only it: '$v'"
# F13 — a FAIL line whose path does not count (not a test file, missing, a symlink,
# absolute, `..`) is rc 3 with no list, alone and next to a real FAIL line: the
# rerun cannot run that file, so it must not run the rest (D9).
ln -s a.test.ts "$UREPO/tests/link.test.ts" 2>/dev/null
for d in 'FAIL src/a.ts' 'FAIL tests/gone.test.ts' 'FAIL tests/link.test.ts' 'FAIL /etc/x.test.ts' 'FAIL ../x.test.ts' \
  "FAIL $UREPO/tests/a.test.ts" 'FAIL tests/../tests/a.test.ts' 'FAIL tests' ' FAIL  tests/helper-db.ts > s'; do
  v=$(printf '%s\n' "$d" | ff 1)
  [ "$v" = 'rc=3|' ] && ok || bad "F13: '$d' alone is rc 3: '$v'"
  v=$(printf 'FAIL tests/d.test.ts\n%s\n' "$d" | ff 1)
  [ "$v" = 'rc=3|' ] && ok || bad "F13: '$d' next to a real FAIL line is rc 3, no list: '$v'"
done
rm -f "$UREPO/tests/link.test.ts"
MANY=$(for i in $(seq 1 21); do echo "FAIL tests/n$i.test.ts"; done)
v=$(printf '%s\n' "$MANY" | ff 1)
[ "$v" = 'rc=2|' ] && ok || bad "F7: 21 files over the default cap 20 is rc 2, no list: '$v'"
v=$(head -20 <<<"$MANY" | ff 1)
case "$v" in rc=0\|tests/n1.test.ts,*,tests/n20.test.ts) ok ;; *) bad "F8: exactly 20 files is a list: '$v'" ;; esac
v=$(printf 'FAIL tests/a.test.ts\n' | ff 1 POOL_TEST_PG_RERUN_MAX_FILES=0)
[ "$v" = 'rc=1|' ] && ok || bad "F9: cap 0 means no rerun (rc 1): '$v'"
row pool_test_pg_rerun_max_files 1
v=$(printf 'FAIL tests/a.test.ts\nFAIL tests/b.test.js\n' | ff 1)
[ "$v" = 'rc=2|' ] && ok || bad "F10: the settings row 1 caps two files: '$v'"
reset
v=$(printf '%s\n' "$MANY" | ff 1 POOL_TEST_PG_RERUN_MAX_FILES=abc)
[ "$v" = 'rc=2|' ] && ok || bad "F11: a non-integer cap is 20: '$v'"
v=$(printf 'FAIL tests/a.test.ts\n' | ff 1 POOL_TEST_PG_RERUN_MAX_FILES=abc)
[ "$v" = 'rc=0|tests/a.test.ts' ] && ok || bad "F11: a non-integer cap still reruns one file: '$v'"
v=$(printf 'FAIL tests/a.test.ts\nFAIL tests/b.test.js\n' | ff 2)
[ "$v" = 'rc=0|tests/b.test.js' ] && ok || bad "F12: from-line 2 skips line 1: '$v'"
v=$(printf '' | ff 1)
[ "$v" = 'rc=1|' ] && ok || bad "F12: an empty output names no file: '$v'"

# ---- P: one fresh cluster per file ------------------------------------------
P="$T/p.txt"
# prun [VAR=val...] -- <file>... — "rc=N dir=<PGT_DIR after>"
prun() {
  local vars=(); while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  : > "$P"; : > "$T/order.log"; : > "$T/pg.log"
  lib env ${vars[@]+"${vars[@]}"} bash -c '. "$0"; command -v pgt_run_files >/dev/null || { echo no-fn; exit 0; }
    pgt_run_files "$1" test "${@:2}"; r=$?; echo "rc=$r dir=${PGT_DIR:-}"' "$LIB" "$P" "$@"
}
v=$(prun -- tests/a.test.ts tests/b.test.ts)
[ "$v" = 'rc=0 dir=' ] && ok || bad "P1: two green files → rc 0 and no PGT_DIR: '$v'"
[ "$(n 'HARNESS_PG_FILE: tests/a.test.ts (rc=0)' "$P")$(n 'HARNESS_PG_FILE: tests/b.test.ts (rc=0)' "$P")" = 11 ] && ok || bad "P1: one rc=0 line per file: $(cat "$P")"
[ "$(grep -c '^HARNESS_PG: up ' "$P")$(n 'HARNESS_PG: torn down' "$P")" = 22 ] && ok || bad "P1: two up and two torn down lines: $(cat "$P")"
[ "$(cat "$T/order.log" | tr '\n' '|')" = 'run test -- tests/a.test.ts|run test -- tests/b.test.ts|' ] && ok || bad "P1: npm once per file, in order: $(cat "$T/order.log")"
[ "$(pgdirs)" = 0 ] && ok || bad "P8: no pgtest.* dir after P1"
[ "$(sed -n 's/^initdb //p' "$T/pg.log" | sort -u | wc -l)" = 2 ] && ok || bad "P2: each file gets its own data dir: $(cat "$T/pg.log")"
v=$(prun POOL_TEST_SETUP_CMD='npm run setup' -- tests/a.test.ts tests/b.test.ts)
[ "$(n 'HARNESS_PG_SETUP: npm run setup (rc=0)' "$P")" = 2 ] && ok || bad "P3: setup runs per fresh cluster: $(cat "$P")"
fo b.test.ts 1 'boom'
v=$(prun -- tests/a.test.ts tests/b.test.ts tests/c.test.ts)
[ "$v" = 'rc=1 dir=' ] && ok || bad "P4: one red file → its rc: '$v'"
grep -qx 'HARNESS_PG_FILE: tests/b.test.ts (rc=1)' "$P" && ok || bad "P4: the red file's line: $(cat "$P")"
grep -qx 'HARNESS_PG_FILE: tests/c.test.ts (rc=0)' "$P" && ok || bad "P4: the files after a red one still run: $(cat "$P")"
reset
printf 'echo 100 > "%s"; echo 100 > "%s"\n' "$T/free/$(echo "$T/shm" | tr / _)" "$T/free/$(echo "$T/tmp" | tr / _)" > "$T/hook/a.test.ts"
v=$(prun -- tests/a.test.ts tests/b.test.ts tests/c.test.ts)
[ "$v" = 'rc=125 dir=' ] && ok || bad "P5: low disk on the 2nd start → 125: '$v'"
grep -qx 'HARNESS_PG_FILE: tests/b.test.ts (not run: low disk)' "$P" && ok || bad "P5: (not run: low disk): $(cat "$P")"
grep -q '^HARNESS_PG_FILE: tests/c.test.ts (not run: ' "$P" && ok || bad "P5: a file after the stop is listed as not run: $(cat "$P")"
grep -q 'run test -- tests/b.test.ts' "$T/order.log" && bad "P5: no run after low disk: $(cat "$T/order.log")" || ok
[ "$(pgdirs)" = 0 ] && ok || bad "P8: no pgtest.* dir after P5"
reset
echo "echo 1100 > \"$T/now\"" > "$T/hook/a.test.ts"
v=$(prun POOL_TEST_PG_SERIAL_BUDGET_S=60 -- tests/a.test.ts tests/b.test.ts tests/c.test.ts)
[ "$v" = 'rc=125 dir=' ] && ok || bad "P6: budget spent → 125: '$v'"
grep -qx 'HARNESS_PG_FILE: tests/a.test.ts (rc=0)' "$P" && ok || bad "P6: the first file ran: $(cat "$P")"
[ "$(n 'HARNESS_PG_FILE: tests/b.test.ts (not run: budget spent)' "$P")$(n 'HARNESS_PG_FILE: tests/c.test.ts (not run: budget spent)' "$P")" = 11 ] && ok \
  || bad "P6: every file past the budget is listed as not run: $(cat "$P")"
[ "$(grep -c '^HARNESS_PG: up ' "$P")" = 1 ] && ok || bad "P6: no cluster starts past the budget: $(cat "$P")"
reset
fo a.test.ts 124
v=$(prun -- tests/a.test.ts tests/b.test.ts)
[ "$v" = 'rc=125 dir=' ] && ok || bad "P7: a timeout (124) is could-not-run (125), not red: '$v'"
reset
fo b.test.ts 1 'Error: ENOSPC: no space left on device, write'
v=$(prun -- tests/a.test.ts tests/b.test.ts)
[ "$v" = 'rc=125 dir=' ] && ok || bad "P9: ENOSPC in a file → 125: '$v'"
grep -qx 'HARNESS_PG_FILE: tests/b.test.ts (rc=1, ENOSPC)' "$P" && ok || bad "P9: the ENOSPC file's line: $(cat "$P")"
fo a.test.ts 2 'expected 1 to be 2'
v=$(prun -- tests/a.test.ts tests/b.test.ts)
[ "$v" = 'rc=2 dir=' ] && ok || bad "P9: a red file beats an ENOSPC file: '$v'"
# Only a file's own lines count: ENOSPC text already in the file is not this file's.
reset; fo a.test.ts 1 'expected 1 to be 2'
v=$(lib env bash -c '. "$0"; echo "old: No space left on device" > "$1"; pgt_run_files "$1" test tests/a.test.ts; echo "rc=$?"' "$LIB" "$P")
[ "$v" = 'rc=1' ] && ok || bad "P9: earlier ENOSPC text in the outfile does not mark this file: '$v' $(cat "$P")"
[ "$(pgdirs)" = 0 ] && ok || bad "P8: no pgtest.* dir after P9"
# P10 — no file is never green: nothing ran.
v=$(prun --)
[ "$v" = 'rc=125 dir=' ] && ok || bad "P10: no file → 125, never 0: '$v'"
reset

# ---- X: the ENOSPC rerun in HARNESS_SUITE_RUN ---------------------------------
ENO=$' FAIL  tests/a.test.ts > s > n\n FAIL  tests/b.test.ts > s > m\nError: ENOSPC: no space left on device, write'
TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 0' ] && ok || bad "X1: a green rerun is HARNESS_EXIT: 0, last: $(cat "$OUT")"
grep -qx 'HARNESS_PG_RERUN: green' "$OUT" && ok || bad "X1: HARNESS_PG_RERUN: green: $(cat "$OUT")"
grep -qx 'HARNESS_PG_RERUN: 2 failed file(s) after ENOSPC, once, one at a time, each on a fresh cluster' "$OUT" && ok || bad "X1: the rerun header: $(cat "$OUT")"
grep -q '^HARNESS_DISK: ENOSPC (rc=1): ' "$OUT" && ok || bad "X1: HARNESS_DISK: ENOSPC stays as the first run's record: $(cat "$OUT")"
[ "$(n 'HARNESS_PG_FILE: tests/a.test.ts (rc=0)' "$OUT")$(n 'HARNESS_PG_FILE: tests/b.test.ts (rc=0)' "$OUT")" = 11 ] && ok || bad "X1: one HARNESS_PG_FILE per file: $(cat "$OUT")"
[ "$(cat "$T/order.log" | tr '\n' '|')" = 'run test|run test -- tests/a.test.ts|run test -- tests/b.test.ts|STAGE_END suite|' ] && ok \
  || bad "X1: one full run, then one run per failed file, then STAGE_END: $(cat "$T/order.log")"
grep -q 'HARNESS-VERIFY lenses rerun: green' "$BUILD/pipeline.log" && ok || bad "X1: pipeline.log rerun line: $(cat "$BUILD/pipeline.log")"
[ "$(pgdirs)" = 0 ] && ok || bad "X1: no pgtest.* dir after the rerun"
cp "$OUT" "$T/x1.txt"
v=$(live "$T/x1.txt")
case "$v" in "tests_green|pass|"*) ok ;; *) bad "X2: LIVE_SUITE reads a green rerun as green: '$v'" ;; esac
[ "$(grep -c '^HARNESS_PG: up ' "$OUT")$(grep -c '^HARNESS_PG: torn down$' "$OUT")" = 33 ] && ok || bad "X3: three clusters, each torn down: $(cat "$OUT")"
[ "$(grep '^HARNESS_PG: ' "$OUT" | tail -1)" = 'HARNESS_PG: torn down' ] && ok || bad "X3: the last HARNESS_PG: line is the last cluster's teardown"
fo b.test.ts 1 'expected 1 to be 2'
TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "X4: a red rerun file is HARNESS_EXIT: 1, never 0: $(cat "$OUT")"
grep -qx 'HARNESS_PG_RERUN: red (rc=1)' "$OUT" && ok || bad "X4: HARNESS_PG_RERUN: red: $(cat "$OUT")"
reset
fo b.test.ts 1 'could not extend file: No space left on device'
TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "X5: ENOSPC again → could-not-run: $(cat "$OUT")"
grep -q '^HARNESS_PG_RERUN: could-not-run (tests/b.test.ts' "$OUT" && ok || bad "X5: the could-not-run line names the file: $(cat "$OUT")"
[ "$(n 'run test' "$T/order.log")$(n 'run test -- tests/a.test.ts' "$T/order.log")$(n 'run test -- tests/b.test.ts' "$T/order.log")" = 111 ] && ok \
  || bad "X5: a rerun never reruns: $(cat "$T/order.log")"
v=$(live "$OUT")
case "$v" in "tests_green|not-run|"*disk*) ok ;; *) bad "X5: LIVE_SUITE says not-run and names the disk: '$v'" ;; esac
[ "$(pgdirs)" = 0 ] && ok || bad "X5: no pgtest.* dir"
fo a.test.ts 3 'expected 1 to be 2'
TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 3' ] && ok || bad "X6: red + ENOSPC files → the red rc: $(cat "$OUT")"
reset
for ph in fix head; do
  TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite "$ph"
  [ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 0' ] && ok || bad "X7: phase $ph reruns too: $(cat "$OUT")"
  grep -qx "STAGE_END suite-$ph" "$T/order.log" && ok || bad "X7: phase $ph STAGE_END: $(cat "$T/order.log")"
done
row pool_test_pg_rerun_max_files 0
TEST_OUT="$ENO" TEST_RC=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "X8: cap row 0 → no rerun, could-not-run: $(cat "$OUT")"
grep -q '^HARNESS_PG_RERUN' "$OUT" && bad "X8: cap 0 writes no HARNESS_PG_RERUN: $(cat "$OUT")" || ok
grep -q -- ' -- ' "$T/order.log" && bad "X8: cap 0 runs no file: $(cat "$T/order.log")" || ok
grep -q 'HARNESS-VERIFY lenses rerun: none (' "$BUILD/pipeline.log" && ok || bad "X8: pipeline.log says rerun: none: $(cat "$BUILD/pipeline.log")"
reset
# X9 — not eligible: no file run, no new line in the suite file.
x9() { # x9 <label> <expected exit> — after a suite() call
  [ "$(tail -1 "$OUT")" = "HARNESS_EXIT: $2" ] && ok || bad "X9 $1: HARNESS_EXIT: $2: $(cat "$OUT")"
  grep -qE '^HARNESS_PG_(RERUN|FILE|SERIAL)' "$OUT" && bad "X9 $1: no rerun line: $(cat "$OUT")" || ok
  grep -q -- ' -- ' "$T/order.log" && bad "X9 $1: no file rerun: $(cat "$T/order.log")" || ok
}
TEST_OUT="$ENO" TEST_RC=124 POOL_TEST_POSTGRES=1 suite; x9 "rc 124" could-not-run
TEST_OUT="$ENO" TEST_RC=2 POOL_TEST_POSTGRES=1 suite; x9 "rc 2" could-not-run
TEST_OUT="$ENO" TEST_RC=1 suite; x9 "knob off" could-not-run
TEST_OUT=$'  ✓ a passing test\nError: ENOSPC: no space left on device, write\n  ✗ 3 failed' TEST_RC=1 POOL_TEST_POSTGRES=1 suite; x9 "no FAIL line" could-not-run
[ "$(tail -3 "$OUT" | cut -c1-18 | tr '\n' '|')" = 'HARNESS_DISK: ENOS|HARNESS_PG: torn d|HARNESS_EXIT: coul|' ] && ok \
  || bad "X9 no FAIL line: the BH-8175 E4/E6 tail is unchanged: $(tail -3 "$OUT")"
TEST_OUT="$ENO" TEST_RC=0 POOL_TEST_POSTGRES=1 suite; x9 "rc 0" 0
TEST_OUT=$' FAIL  tests/a.test.ts > s > n' TEST_RC=1 POOL_TEST_POSTGRES=1 suite; x9 "a plain red" 1
# X10 — one FAIL file the rerun can run (green alone) next to one it cannot: no
# rerun, could-not-run as on main, never HARNESS_EXIT: 0 (D9).
TEST_OUT=$' FAIL  tests/a.test.ts > s > n\n FAIL  tests/helper-db.ts > s > m\n FAIL  tests/missing.test.ts > s\nError: ENOSPC: no space left on device, write' \
  TEST_RC=1 POOL_TEST_POSTGRES=1 suite; x9 "a dropped FAIL line" could-not-run
grep -q 'HARNESS-VERIFY lenses rerun: none (a FAIL line names a file the rerun cannot run)' "$BUILD/pipeline.log" && ok \
  || bad "X10: pipeline.log names the dropped FAIL line: $(cat "$BUILD/pipeline.log")"

# ---- S: the serial run ----------------------------------------------------------
TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG_SERIAL: on (3 file(s), one fresh cluster each)' "$OUT" && ok || bad "S1: HARNESS_PG_SERIAL: on line: $(cat "$OUT")"
[ "$(cat "$T/order.log" | tr '\n' '|')" = 'run test -- tests/a.test.ts|run test -- tests/b.test.ts|run test -- tests/c.test.ts|STAGE_END suite|' ] && ok \
  || bad "S1: no single run, one run per file: $(cat "$T/order.log")"
[ "$(sed -n 's/^initdb //p' "$T/pg.log" | sort -u | wc -l)" = 3 ] && ok || bad "S1: three fresh clusters: $(cat "$T/pg.log")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 0' ] && ok || bad "S1: HARNESS_EXIT: 0 last: $(cat "$OUT")"
grep -qx 'HARNESS_PG_SERIAL: green' "$OUT" && ok || bad "S1: HARNESS_PG_SERIAL: green: $(cat "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "S1: no pgtest.* dir"
POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG_SERIAL: off (a full run names no files)' "$OUT" && ok || bad "S2: a full run says serial is off: $(cat "$OUT")"
[ "$(cat "$T/order.log" | tr '\n' '|')" = 'run test|STAGE_END suite|' ] && ok || bad "S2: today's single run: $(cat "$T/order.log")"
fo b.test.ts 1 'expected 1 to be 2'
TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "S3: a red file → HARNESS_EXIT: 1: $(cat "$OUT")"
grep -qx 'HARNESS_PG_SERIAL: red (rc=1)' "$OUT" && ok || bad "S3: HARNESS_PG_SERIAL: red: $(cat "$OUT")"
reset
free "$T/shm" 100; free "$T/tmp" 200
TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
grep -qx "HARNESS_DISK: low (no root has 512 MB free: $T/shm 100 MB, $T/tmp 200 MB)" "$OUT" && ok || bad "S4: HARNESS_DISK: low: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "S4: could-not-run: $(cat "$OUT")"
grep -q '^run test' "$T/order.log" && bad "S4: npm test must not run on low disk: $(cat "$T/order.log")" || ok
grep -q 'HARNESS-VERIFY lenses disk: low' "$BUILD/pipeline.log" && ok || bad "S4: pipeline.log names the low disk: $(cat "$BUILD/pipeline.log")"
reset
fo b.test.ts 1 'Error: ENOSPC: no space left on device, write'
TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "S5: ENOSPC in a serial file → could-not-run: $(cat "$OUT")"
grep -q '^HARNESS_PG_RERUN' "$OUT" && bad "S5: a serial run is never rerun: $(cat "$OUT")" || ok
grep -q '^HARNESS_DISK: ENOSPC' "$OUT" && ok || bad "S5: HARNESS_DISK: ENOSPC names the disk: $(cat "$OUT")"
[ "$(grep -c -- ' -- ' "$T/order.log")" = 3 ] && ok || bad "S5: each file runs once: $(cat "$T/order.log")"
fo a.test.ts 1 'expected 1 to be 2'
TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL=1 POOL_TEST_POSTGRES=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "S7: red + ENOSPC serial files → the red rc, never could-not-run: $(cat "$OUT")"
reset
for sv in yes 2; do
  TEST_SELECT=1 POOL_TEST_POSTGRES_SERIAL="$sv" POOL_TEST_POSTGRES=1 suite
  grep -q '^HARNESS_PG_SERIAL' "$OUT" && bad "S6: serial '$sv' is off: $(cat "$OUT")" || ok
  [ "$(cat "$T/order.log" | tr '\n' '|')" = 'run test -- tests/a.test.ts tests/b.test.ts tests/c.test.ts|STAGE_END suite|' ] && ok \
    || bad "S6: serial '$sv' runs today's selected run: $(cat "$T/order.log")"
done
row pool_test_postgres_serial 1
TEST_SELECT=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG_SERIAL: on (3 file(s), one fresh cluster each)' "$OUT" && ok || bad "S6: the settings row 1 turns serial on: $(cat "$OUT")"
reset

# ---- K: the knob rows -----------------------------------------------------------
for k in 'POOL_TEST_POSTGRES_SERIAL:0' 'POOL_TEST_PG_RERUN_MAX_FILES:20' 'POOL_TEST_PG_SERIAL_BUDGET_S:1500'; do
  J="$DIR/catalog/lanes.d/fly-pool.knobs.d/${k%%:*}.json"
  [ "$(jq -c '[.env,.type,.default,.read_in,.settable]' "$J" 2>/dev/null)" = "[\"${k%%:*}\",\"int\",${k#*:},\"bin/lib/pg-test.sh\",true]" ] && ok \
    || bad "K1: knob row ${k%%:*} (int, default ${k#*:}, read in bin/lib/pg-test.sh, settable)"
done

echo "pool-test-postgres-serial.bh-8499: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
