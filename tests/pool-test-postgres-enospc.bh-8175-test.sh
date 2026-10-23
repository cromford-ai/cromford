#!/bin/bash
# tests/pool-test-postgres-enospc.bh-8175-test.sh — a full disk on the pool box is
# a box fault, not a red suite.
#
# THE DEFECT THIS PINS (BH-8175). The throwaway Postgres (bin/lib/pg-test.sh,
# BH-5962) made its data dir under ${TMPDIR:-/tmp} with no space check. On a
# pool machine's small root overlay the suite hit ENOSPC, HARNESS_SUITE_RUN
# wrote the raw `HARNESS_EXIT: 1`, and the review BLOCKed good code.
#
# What it asserts:
#   E1-E2  the data root is the first of PGT_ROOTS that is a writable dir with
#          the knob's free MB (/dev/shm, then TMPDIR by default).
#   E3     no root has room: no suite run, HARNESS_DISK: low, could-not-run.
#   E4-E6  a nonzero suite whose output says `No space left on device` is
#          could-not-run with a HARNESS_DISK: ENOSPC line, knob on or off.
#   E7     LIVE_SUITE reads that file as not-run and names the disk.
#   E8     the min-free knob: row, fallback 512, non-integer is 512.
#   E9     a real red suite is never relabelled.
#   E10    the three review prompts say could-not-run is never by itself a BLOCK.
#
# The block is lifted VERBATIM from the pipeline by its markers, the way
# pool-test-postgres.bh-5962-test does. initdb/pg_ctl/postgres, setpriv, npm and
# df are stubs under $T. No network, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset DATABASE_URL DIRECT_URL POSTGRES_URL PGPASSWORD SUPABASE_DB_URL POOL_TEST_POSTGRES POOL_TEST_SETUP_CMD \
  POOL_TEST_POSTGRES_MAJOR POOL_TEST_POSTGRES_MIN_FREE_MB PGT_BIN_DIR PGT_ROOTS TEST_RC TEST_OUT
NOW=1760140800

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"
awk '/^LIVE_SUITE\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RB" > "$T/live-suite.sh"
[ -s "$T/live-suite.sh" ] && ok || bad "could not extract LIVE_SUITE"

mkdir -p "$T/h" "$T/fakebin" "$T/pgbin" "$T/tmp" "$T/shm"
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
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
echo "\$*" >> "$T/order.log"
[ "\$2" = test ] || exit 0
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
chmod +x "$T/pgbin/"* "$T/fakebin/"*
mkdir -p "$T/free"
# free <root> <MB> — what the df stub answers for that root.
free() { echo "$2" > "$T/free/$(echo "$1" | tr / _)"; }
echo 100000 > "$T/free/default"

REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
mkdir -p "$T/h/state"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
# suite — HARNESS_SUITE_RUN lenses in a fresh repo; PGT_ROOTS defaults to $T/shm $T/tmp.
suite() {
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"
  : > "$T/order.log"; : > "$T/pg.log"
  printf '{"scripts":{"test":"x"}}\n' > "$REPO/package.json"
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT=project-6-os KEY=TK-1 TEST_SELECT=0 \
      PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" LANE_GATE_NOW="$NOW" PGT_ROOTS="${PGT_ROOTS:-$T/shm $T/tmp}"
    STAMP() { echo 2026-10-23T00:00:00Z; }
    STAGE_START() { echo 1; }
    STAGE_END() { echo "STAGE_END $1" >> "$T/order.log"; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
pgdirs() { { compgen -G "$T/tmp/pgtest.*"; compgen -G "$T/shm/pgtest.*"; } | wc -l; }
datadir() { sed -n 's/^initdb //p' "$T/pg.log" | head -1; }
# root_of [env assignments...] — pgt_root's answer under the stubs, "rc=N" on failure.
root_of() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" PROJECT=project-6-os LANE_GATE_NOW="$NOW" TMPDIR="$T/tmp"
    for a in "$@"; do export "${a?}"; done
    . "$LIB"; command -v pgt_root >/dev/null || { echo "no-pgt_root"; exit 0; }
    r=$(pgt_root) || { echo "rc=$?"; exit 0; }; echo "$r" )
}

# E1 — both roots have room: the first one (shm) holds the data dir, torn down after.
free "$T/shm" 4000; free "$T/tmp" 4000
POOL_TEST_POSTGRES=1 suite
case "$(datadir)" in "$T/shm/pgtest."??????/data) ok ;; *) bad "E1: the data dir must be under the first root $T/shm: '$(datadir)'" ;; esac
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "E1: green suite: $(cat "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "E1: no pgtest.* dir may remain"

# E2 — shm is short, tmp has room: tmp. A missing first root is skipped.
free "$T/shm" 100
POOL_TEST_POSTGRES=1 suite
case "$(datadir)" in "$T/tmp/pgtest."??????/data) ok ;; *) bad "E2: shm below min, the data dir must be under $T/tmp: '$(datadir)'" ;; esac
PGT_ROOTS="$T/nope $T/tmp" POOL_TEST_POSTGRES=1 suite
case "$(datadir)" in "$T/tmp/pgtest."??????/data) ok ;; *) bad "E2: a missing root is skipped: '$(datadir)'" ;; esac
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "E2: green suite: $(cat "$OUT")"

# E3 — no root has room: no suite, HARNESS_DISK: low, could-not-run, nothing left.
free "$T/shm" 100; free "$T/tmp" 200
POOL_TEST_POSTGRES=1 suite
grep -qx "HARNESS_PG: could-not-start (low disk: no root has 512 MB free: $T/shm 100 MB, $T/tmp 200 MB)" "$OUT" && ok \
  || bad "E3: the could-not-start line must name the min and each root's free MB: $(cat "$OUT")"
grep -qx "HARNESS_DISK: low (no root has 512 MB free: $T/shm 100 MB, $T/tmp 200 MB)" "$OUT" && ok || bad "E3: HARNESS_DISK: low line: $(cat "$OUT")"
grep -q '^test' "$T/order.log" && bad "E3: npm test must not run on low disk: $(cat "$T/order.log")" || ok
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "E3: last line must be HARNESS_EXIT: could-not-run: $(cat "$OUT")"
[ "$(tail -2 "$OUT" | head -1 | cut -c1-15)" = 'HARNESS_DISK: l' ] && ok || bad "E3: HARNESS_DISK must precede the exit line: $(cat "$OUT")"
grep -qx 'STAGE_END suite' "$T/order.log" && ok || bad "E3: STAGE_END still runs: $(cat "$T/order.log")"
[ -s "$T/pg.log" ] && bad "E3: low disk must start nothing: $(cat "$T/pg.log")" || ok
[ "$(pgdirs)" = 0 ] && ok || bad "E3: no pgtest.* dir after low disk"
grep -q 'HARNESS-VERIFY lenses disk: low' "$BUILD/pipeline.log" && ok || bad "E3: pipeline.log names the low disk: $(cat "$BUILD/pipeline.log")"
free "$T/shm" 4000; free "$T/tmp" 4000

# E4 — Node ENOSPC in a red suite: could-not-run with the matched line.
TEST_OUT=$'  ✓ a passing test\nError: ENOSPC: no space left on device, write\n  ✗ 3 failed' TEST_RC=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_DISK: ENOSPC (rc=1): Error: ENOSPC: no space left on device, write' "$OUT" && ok || bad "E4: HARNESS_DISK: ENOSPC line: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "E4: last line must be could-not-run: $(cat "$OUT")"
cp "$OUT" "$T/e4.txt"
# E6 (knob on) — teardown before the exit line, HARNESS_DISK before both.
[ "$(tail -3 "$OUT" | cut -c1-18 | tr '\n' '|')" = 'HARNESS_DISK: ENOS|HARNESS_PG: torn d|HARNESS_EXIT: coul|' ] && ok \
  || bad "E6: order must be HARNESS_DISK, torn down, HARNESS_EXIT: $(tail -3 "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "E6: no pgtest.* dir after an ENOSPC run"

# E5 — Postgres-style, mixed case, other rc.
TEST_OUT='ERROR:  could not extend file "base/1/2": No space left on device' TEST_RC=2 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_DISK: ENOSPC (rc=2): ERROR:  could not extend file "base/1/2": No space left on device' "$OUT" && ok || bad "E5: Postgres ENOSPC: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "E5: could-not-run: $(cat "$OUT")"
# A very long line is cut to 200 chars.
TEST_OUT="write failed: No space left on device $(printf 'x%.0s' {1..400})" TEST_RC=1 suite
l=$(sed -n 's/^HARNESS_DISK: ENOSPC (rc=1): //p' "$OUT")
[ "${#l}" = 200 ] && ok || bad "E5: the matched line is cut to 200 chars, got ${#l}"

# E6 — the map is not knob-gated: off, ENOSPC is still could-not-run.
TEST_OUT='cp: error writing x: No space left on device' TEST_RC=1 suite
grep -q '^HARNESS_PG' "$OUT" && bad "E6: knob off writes no HARNESS_PG line" || ok
grep -qx 'HARNESS_DISK: ENOSPC (rc=1): cp: error writing x: No space left on device' "$OUT" && ok || bad "E6: knob off ENOSPC line: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: could-not-run' ] && ok || bad "E6: knob off could-not-run: $(cat "$OUT")"

# E7 — LIVE_SUITE on the E4 file: not-run, names the disk and the head's CI.
live() { ( LIVE() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }; . "$T/live-suite.sh"; LIVE_SUITE "$1" '' ); }
v=$(live "$T/e4.txt")
case "$v" in "tests_green|not-run|"*disk*) ok ;; *) bad "E7: LIVE_SUITE must say not-run and name the disk: '$v'" ;; esac
case "$v" in *"CI run on the PR head"*) ok ;; *) bad "E7: LIVE_SUITE must say the head's CI is the verdict: '$v'" ;; esac

# E8 — the min-free knob.
free "$T/a" 600; free "$T/b" 400; mkdir -p "$T/a" "$T/b"
[ "$(root_of "PGT_ROOTS=$T/b $T/a")" = "$T/a" ] && ok || bad "E8: no row = 512: 400 MB skipped, 600 MB chosen: '$(root_of "PGT_ROOTS=$T/b $T/a")'"
[ "$(root_of "PGT_ROOTS=$T/b $T/a" POOL_TEST_POSTGRES_MIN_FREE_MB=abc)" = "$T/a" ] && ok || bad "E8: a non-integer min is 512"
[ "$(root_of "PGT_ROOTS=$T/a" POOL_TEST_POSTGRES_MIN_FREE_MB=1000)" = "rc=1" ] && ok || bad "E8: min 1000 skips a 600 MB root: '$(root_of "PGT_ROOTS=$T/a" POOL_TEST_POSTGRES_MIN_FREE_MB=1000)'"
[ "$(root_of "PGT_ROOTS=$T/a" POOL_TEST_POSTGRES_MIN_FREE_MB=600)" = "$T/a" ] && ok || bad "E8: exactly min free is chosen"
printf '{"fetched_at":%s,"values":{"lane.fly-pool.project-6-os.pool_test_postgres_min_free_mb":"1000"},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
[ "$(root_of "PGT_ROOTS=$T/a")" = "rc=1" ] && ok || bad "E8: the settings row 1000 skips a 600 MB root"
printf '{"fetched_at":%s,"values":{},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
chmod 555 "$T/b"; free "$T/b" 4000
if [ ! -w "$T/b" ]; then
  [ "$(root_of "PGT_ROOTS=$T/b $T/a")" = "$T/a" ] && ok || bad "E8: a root that is not writable is skipped"
else echo "SKIP E8 not-writable: running as root"; fi
chmod 755 "$T/b"
: > "$T/afile"; free "$T/afile" 4000
[ "$(root_of "PGT_ROOTS=$T/afile $T/a")" = "$T/a" ] && ok || bad "E8: a root that is a file, not a dir, is skipped"
# The default list: /dev/shm first, then TMPDIR.
free /dev/shm 0; free "$T/tmp" 4000
[ "$(root_of PGT_ROOTS=)" = "$T/tmp" ] && ok || bad "E8: default list falls to TMPDIR when /dev/shm is short: '$(root_of PGT_ROOTS=)'"
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
  free /dev/shm 4000
  [ "$(root_of PGT_ROOTS=)" = /dev/shm ] && ok || bad "E8: default list starts with /dev/shm: '$(root_of PGT_ROOTS=)'"
else echo "SKIP E8 /dev/shm-first: no writable /dev/shm here"; fi
J="$DIR/catalog/lanes.d/fly-pool.knobs.d/POOL_TEST_POSTGRES_MIN_FREE_MB.json"
[ "$(jq -c '[.env,.type,.default,.read_in,.settable]' "$J" 2>/dev/null)" = '["POOL_TEST_POSTGRES_MIN_FREE_MB","int",512,"bin/lib/pg-test.sh",true]' ] && ok \
  || bad "E8: knob row POOL_TEST_POSTGRES_MIN_FREE_MB (int, default 512, read in bin/lib/pg-test.sh, settable)"

# E9 — negatives: a real red suite is never relabelled.
TEST_OUT='log: No space left on device (simulated, recovered)' TEST_RC=0 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 0' ] && ok || bad "E9: rc 0 is never remapped: $(cat "$OUT")"
grep -q '^HARNESS_DISK' "$OUT" && bad "E9: rc 0 writes no HARNESS_DISK" || ok
TEST_OUT='  ✗ retries on ENOSPC' TEST_RC=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "E9: the bare token ENOSPC is not a disk fault: $(cat "$OUT")"
TEST_OUT='Error: no space left in buffer' TEST_RC=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "E9: 'no space left in buffer' is not a disk fault: $(cat "$OUT")"
TEST_OUT='  ✗ adds two numbers' TEST_RC=1 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "E9: a plain red suite stays 1: $(cat "$OUT")"
grep -q '^HARNESS_DISK' "$OUT" && bad "E9: a plain red writes no HARNESS_DISK" || ok
TEST_OUT='timed out' TEST_RC=124 suite
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 124' ] && ok || bad "E9: 124 with no disk text stays 124: $(cat "$OUT")"

# E10 — the three review prompt sites.
for site in "review.sh:Adversarially review the diff of branch" "review.sh:RE-REVIEW AFTER ONE MERGED FIX ROUND" "result.sh:RE-REVIEW ON A MOVED HEAD"; do
  f="$DIR/bin/lib/rb/${site%%:*}"; line=$(grep -F "${site#*:}" "$f" | head -1)
  [ -n "$line" ] || { bad "E10: prompt site '$site' not found"; continue; }
  case "$line" in *"never by itself a reason to BLOCK"*) ok ;; *) bad "E10: '$site' must say could-not-run is never by itself a reason to BLOCK" ;; esac
  case "$line" in *HARNESS_DISK*) ok ;; *) bad "E10: '$site' must name the HARNESS_DISK line" ;; esac
done

echo "pool-test-postgres-enospc.bh-8175: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
