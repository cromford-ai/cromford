#!/bin/bash
# tests/pool-test-postgres.bh-5962-test.sh — HARNESS_SUITE_RUN's npm arm starts a
# throwaway Postgres for a project with the fly-pool knob POOL_TEST_POSTGRES=1,
# gives DATABASE_URL (always 127.0.0.1) to the setup script and the suite only,
# and tears it down before HARNESS_EXIT.
#
# THE DEFECT THIS PINS (BH-5962). The pool runner had no Postgres, so a repo whose
# unit suite needs DATABASE_URL recorded HARNESS_EXIT: 1 on every review
# (project-6-os TK-3/34/35/36) while CI, which starts Postgres, passed.
#
# The block is lifted VERBATIM from run-build by its markers (the way
# verify-prelude.bh-1955-test does) and run in a scratch repo. bin/lib/pg-test.sh
# is the real lib; initdb/pg_ctl/postgres, setpriv and npm are stubs that log to
# $T. P11 runs the real Postgres only where the pool image installed it.
#
# No network, nothing written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset DATABASE_URL DIRECT_URL POSTGRES_URL PGPASSWORD SUPABASE_DB_URL POOL_TEST_POSTGRES POOL_TEST_POSTGRES_SETUP POOL_TEST_SETUP_CMD POOL_TEST_POSTGRES_MAJOR PGT_BIN_DIR INITDB_RC PGCTL_RC SETUP_RC TEST_RC
NOW=1760140800

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

mkdir -p "$T/h" "$T/fakebin" "$T/pgbin" "$T/empty" "$T/tmp"
scratch_install_closure bin/lib/pg-test.sh "$T/h" > /dev/null || bad "cannot install bin/lib/pg-test.sh into the scratch harness"
scratch_install_closure bin/lib/lane-gate.sh "$T/h" > /dev/null || bad "cannot install bin/lib/lane-gate.sh into the scratch harness"
LIB="$T/h/bin/lib/pg-test.sh"

# The stubs. Each one logs what it was asked to do; nothing listens on a port.
cat > "$T/pgbin/initdb" <<EOF
#!/bin/bash
d=""; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { d="\$2"; shift; }; shift; done
echo initdb >> "$T/pg.log"
[ "\${INITDB_RC:-0}" = 0 ] || { echo "initdb: fixture failure"; exit "\$INITDB_RC"; }
mkdir -p "\$d"
EOF
cat > "$T/pgbin/pg_ctl" <<EOF
#!/bin/bash
d=""; verb=""; while [ \$# -gt 0 ]; do case "\$1" in -D) d="\$2"; shift ;; start|stop) verb="\$1" ;; esac; shift; done
echo "pg_ctl \$verb" >> "$T/pg.log"
[ "\${PGCTL_RC:-0}" = 0 ] || exit "\$PGCTL_RC"
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
printf '%s\t%s\n' "\$*" "DATABASE_URL=\${DATABASE_URL:-UNSET}" >> "$T/order.log"
{ echo "== \$*"; env | grep -E '^[^=]*(DATABASE_URL|DIRECT_URL|DB_URL)[^=]*=|^(POSTGRES|PG|SUPABASE_DB)[^=]*=' | sort; } >> "$T/env.log"
if [ "\$2" = test ]; then
  [ -n "\${DATABASE_URL:-}" ] || { echo "Error: DATABASE_URL is unset"; exit 1; }
  echo "db reachable"; exit "\${TEST_RC:-0}"
fi
exit "\${SETUP_RC:-0}"
EOF
chmod +x "$T/pgbin/"* "$T/fakebin/"*

REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
LOCAL_RE='^postgresql://harness@127\.0\.0\.1:[0-9]{4,5}/postgres$'
# settings <json-values> — the settings cache lane_knob reads, fresh at NOW.
settings() {
  mkdir -p "$T/h/state"
  printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$T/h/state/settings-cache.json"
}
# suite [nodbapply] — HARNESS_SUITE_RUN lenses in a fresh repo.
suite() {
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"
  : > "$T/order.log"; : > "$T/pg.log"; : > "$T/env.log"
  if [ "${1:-}" = nodbapply ]; then printf '{"scripts":{"test":"x"}}\n' > "$REPO/package.json"
  else printf '{"scripts":{"test":"x","db:apply":"y"}}\n' > "$REPO/package.json"; fi
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT="${PROJ:-project-6-os}" KEY=TK-1 TEST_SELECT=0 \
      PGT_BIN_DIR="${PGT_BIN_DIR:-$T/pgbin}" TMPDIR="$T/tmp" LANE_GATE_NOW="$NOW"
    STAMP() { echo 2026-10-11T00:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
pgdirs() { compgen -G "$T/tmp/pgtest.*" | wc -l; }
suite_url() { awk -F'\t' '$1=="run test"{sub(/^DATABASE_URL=/,"",$2); print $2}' "$T/order.log"; }
up_url() { sed -n 's/^HARNESS_PG: up (PostgreSQL [^,]*, throwaway, \(.*\))$/\1/p' "$OUT"; }
settings '{}'

# P1 — off (unset, then 0): today's run, byte for byte in what it executes.
for v in unset 0; do
  if [ "$v" = unset ]; then suite; else POOL_TEST_POSTGRES=0 suite; fi
  grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "P1($v): the fixture suite needs DATABASE_URL, so off must stay HARNESS_EXIT: 1: $(cat "$OUT")"
  grep -q '^HARNESS_PG' "$OUT" && bad "P1($v): off must write no HARNESS_PG line: $(cat "$OUT")" || ok
  [ -s "$T/pg.log" ] && bad "P1($v): off must run no pg command: $(cat "$T/pg.log")" || ok
  [ "$(cat "$T/order.log")" = "run test	DATABASE_URL=UNSET" ] && ok || bad "P1($v): only the suite runs, with no DATABASE_URL: $(cat "$T/order.log")"
  grep -q 'postgres:' "$BUILD/pipeline.log" && bad "P1($v): off must log no postgres line" || ok
done

# P2 — on: the suite gets the throwaway's URL and goes green.
POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "P2: with the knob on the suite must reach HARNESS_EXIT: 0: $(cat "$OUT")"
[ "$(grep -c '^HARNESS_PG: up (PostgreSQL 16.14, throwaway, postgresql://harness@127.0.0.1:[0-9]*/postgres)$' "$OUT")" = 1 ] && ok \
  || bad "P2: one up line naming 16.14 and the local URL: $(cat "$OUT")"
U=$(up_url); S=$(suite_url)
[ -n "$U" ] && [ "$U" = "$S" ] && ok || bad "P2: the suite must see the URL the up line names (up='$U' suite='$S')"
grep -q 'HARNESS-VERIFY lenses postgres: HARNESS_PG: up' "$BUILD/pipeline.log" && ok || bad "P2: pipeline.log must carry the postgres line: $(cat "$BUILD/pipeline.log")"
# P6 (after green)
tail -1 "$T/pg.log" | grep -qx 'pg_ctl stop' && ok || bad "P6: the last pg command must be the stop: $(cat "$T/pg.log")"
[ "$(tail -2 "$OUT" | head -1)" = 'HARNESS_PG: torn down' ] && ok || bad "P6: 'torn down' must be the line before HARNESS_EXIT: $(cat "$OUT")"
tail -1 "$OUT" | grep -q '^HARNESS_EXIT: ' && ok || bad "P6: HARNESS_EXIT must stay the last line"
[ "$(pgdirs)" = 0 ] && ok || bad "P6: no pgtest.* dir may remain after a green run"

# P3 — a real-looking URL in the box env never reaches setup or the suite.
DATABASE_URL=postgresql://u:p@db.prod.example.com:5432/app POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
n=0; while IFS=$'\t' read -r _ e; do
  n=$((n+1)); [[ "${e#DATABASE_URL=}" =~ $LOCAL_RE ]] || bad "P3: a child saw a non-local URL: $e"
done < "$T/order.log"
[ "$n" = 2 ] && ok || bad "P3: setup and suite must both run: $(cat "$T/order.log")"
grep -q prod "$T/order.log" && bad "P3: the box URL leaked into a child: $(cat "$T/order.log")" || ok
# P3b — the other names a project env can carry a prod address in (refute review,
# finding 1): Prisma's directUrl, POSTGRES_URL*, the libpq PG* vars, Supabase.
# The children see DATABASE_URL and DIRECT_URL, both local, and nothing else.
DATABASE_URL=postgresql://u:p@db.prod.example.com:5432/app \
  DIRECT_URL=postgresql://u:p@direct.prod.example.com:5432/app \
  POSTGRES_URL_NON_POOLING=postgresql://u:p@pool.prod.example.com/app \
  DATABASE_URL_UNPOOLED=postgresql://u:p@unpooled.prod.example.com/app \
  SUPABASE_DB_URL=postgresql://u:p@supa.prod.example.com/app \
  PGHOST=pghost.prod.example.com PGPASSWORD=prodsecret \
  POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
[ "$(grep -c '^== ' "$T/env.log")" = 2 ] && ok || bad "P3b: setup and suite must both run: $(cat "$T/env.log")"
grep -Eq 'prod|prodsecret' "$T/env.log" && bad "P3b: a box DB address reached a child: $(cat "$T/env.log")" || ok
n=0; while IFS= read -r l; do
  case "$l" in '== '*) continue ;; esac
  n=$((n+1))
  case "${l%%=*}" in DATABASE_URL|DIRECT_URL) [[ "${l#*=}" =~ $LOCAL_RE ]] || bad "P3b: ${l%%=*} is not local: $l" ;;
    *) bad "P3b: a child saw a DB-address name it must not: $l" ;; esac
done < "$T/env.log"
[ "$n" = 4 ] && ok || bad "P3b: each child must see exactly DATABASE_URL and DIRECT_URL: $(cat "$T/env.log")"
grep -q prod "$OUT" && bad "P3b: a box DB address reached the suite file: $(cat "$OUT")" || ok
# Knob off: the build's env is not touched (today's run).
DIRECT_URL=postgresql://u:p@direct.prod.example.com:5432/app suite
grep -qx 'DIRECT_URL=postgresql://u:p@direct.prod.example.com:5432/app' "$T/env.log" && ok || bad "P3b: off must not change the env: $(cat "$T/env.log")"

# P4 — the URL guard accepts only the shape pgt_start builds.
( . "$LIB" 2>/dev/null; command -v pgt_local_url >/dev/null || exit 9
  r=""
  pgt_local_url 'postgresql://harness@127.0.0.1:55187/postgres' || r="$r accept-55187"
  pgt_local_url 'postgresql://harness@127.0.0.1:5432/postgres'  || r="$r accept-5432"
  for u in 'postgresql://harness@127.0.0.1:5@evil.example:5432/postgres' \
           'postgresql://harness@127.0.0.1.evil.example:5432/postgres' \
           'postgresql://u:p@db.prod.example.com:5432/postgres' \
           $'postgresql://harness@127.0.0.1:55187/postgres\n' ''; do
    pgt_local_url "$u" && r="$r refuse:$u"
  done
  [ -z "$r" ] || { echo "$r"; exit 1; } )
case $? in 0) ok ;; 9) bad "P4: bin/lib/pg-test.sh has no pgt_local_url" ;; *) bad "P4: the URL guard got a case wrong" ;; esac

# P5 — setup (spec 2026-10-11: the row pool_test_setup_cmd, default empty = no
# setup; only `npm run <a script the repo's package.json declares>` ever runs).
POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG_SETUP: none (no setup command is set)' "$OUT" && ok || bad "P5a: an empty setup command runs no setup: $(cat "$OUT")"
[ "$(cut -f1 "$T/order.log")" = 'run test' ] && ok || bad "P5a: with no setup command only the suite runs: $(cat "$T/order.log")"
POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
[ "$(sed -n 1p "$T/order.log" | cut -f1)" = 'run db:apply' ] && ok || bad "P5b: line 1 must be the setup: $(cat "$T/order.log")"
[[ "$(sed -n 1p "$T/order.log" | cut -f2 | sed 's/^DATABASE_URL=//')" =~ $LOCAL_RE ]] && ok || bad "P5b: the setup must get the local URL"
[ "$(sed -n 2p "$T/order.log" | cut -f1)" = 'run test' ] && ok || bad "P5b: line 2 must be the suite: $(cat "$T/order.log")"
grep -qx 'HARNESS_PG_SETUP: npm run db:apply (rc=0)' "$OUT" && ok || bad "P5b: the setup line with rc=0: $(cat "$OUT")"
SETUP_RC=1 POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite
grep -qx 'HARNESS_PG_SETUP: npm run db:apply (rc=1)' "$OUT" && ok || bad "P5c: a red setup must be recorded as rc=1: $(cat "$OUT")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "P5c: the suite still runs and its exit is its own: $(cat "$OUT")"
grep -qx 'HARNESS_PG: torn down' "$OUT" && ok || bad "P6: teardown after a red setup"
for s in 'rm -rf /' 'npm run a;b' $'npm run db:apply\nx' 'db:apply' 'npm run db:apply --force' 'npx prisma migrate deploy' \
         'npm  run db:apply' "npm run $(printf 'a%.0s' {1..65})"; do
  POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD="$s" suite
  grep -q '^HARNESS_PG_SETUP: refused (' "$OUT" && ok || bad "P5d: '$s' must be refused: $(cat "$OUT")"
  [ "$(cut -f1 "$T/order.log")" = 'run test' ] && ok || bad "P5d: '$s' must run nothing but the suite: $(cat "$T/order.log")"
done
POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run test:setup' suite
grep -qx "HARNESS_PG_SETUP: none (package.json declares no 'test:setup' script)" "$OUT" && ok || bad "P5e: a script the repo lacks is none, not refused: $(cat "$OUT")"
POOL_TEST_POSTGRES=1 POOL_TEST_SETUP_CMD='npm run db:apply' suite nodbapply
grep -qx "HARNESS_PG_SETUP: none (package.json declares no 'db:apply' script)" "$OUT" && ok || bad "P5e: no db:apply declared: $(cat "$OUT")"
[ "$(cut -f1 "$T/order.log")" = 'run test' ] && ok || bad "P5e: only the suite runs: $(cat "$T/order.log")"
POOL_TEST_POSTGRES=1 POOL_TEST_POSTGRES_SETUP=db:apply suite
grep -q '^HARNESS_PG_SETUP: npm run' "$OUT" && bad "P5f: the old POOL_TEST_POSTGRES_SETUP knob must no longer run anything: $(cat "$OUT")" || ok

# P12 — the major version (spec 2026-10-11: row pool_test_postgres_major, default 16).
POOL_TEST_POSTGRES=1 suite
grep -q '^HARNESS_PG: up (PostgreSQL 16\.' "$OUT" && grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "P12a: an unset major starts Postgres 16: $(cat "$OUT")"
POOL_TEST_POSTGRES=1 POOL_TEST_POSTGRES_MAJOR=17 suite
grep -qx 'HARNESS_PG: could-not-start (major 17 is not in the image: it holds 16)' "$OUT" && ok || bad "P12b: a major the image lacks is an honest could-not-start: $(cat "$OUT")"
grep -q initdb "$T/pg.log" && bad "P12b: a wrong major must start nothing: $(cat "$T/pg.log")" || ok
[ "$(cat "$T/order.log")" = "run test	DATABASE_URL=UNSET" ] && ok || bad "P12b: the suite runs with no URL: $(cat "$T/order.log")"
[ "$(pgdirs)" = 0 ] && ok || bad "P12b: no pgtest.* dir"
POOL_TEST_POSTGRES=1 POOL_TEST_POSTGRES_MAJOR=abc suite
grep -qx "HARNESS_PG: could-not-start (major 'abc' is not a number)" "$OUT" && ok || bad "P12c: a non-number major: $(cat "$OUT")"
settings '{"lane.fly-pool.project-6-os.pool_test_postgres":"1","lane.fly-pool.project-6-os.pool_test_postgres_major":"16","lane.fly-pool.project-6-os.pool_test_setup_cmd":"npm run db:apply"}'
suite
grep -q '^HARNESS_PG: up (PostgreSQL 16\.' "$OUT" && grep -qx 'HARNESS_PG_SETUP: npm run db:apply (rc=0)' "$OUT" && ok \
  || bad "P12d: the three project-6-os rows (on, major 16, npm run db:apply) work together: $(cat "$OUT")"
settings '{}'

# P6 — a red suite still reaches the teardown, and HARNESS_EXIT stays last.
TEST_RC=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG: torn down' "$OUT" && ok || bad "P6: teardown after a red suite: $(cat "$OUT")"
[ "$(tail -1 "$OUT")" = 'HARNESS_EXIT: 1' ] && ok || bad "P6: a red suite's own exit is the last line: $(cat "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "P6: no pgtest.* dir may remain after a red suite"

# P7 — no binaries: an honest could-not-start, and today's run.
PGT_BIN_DIR="$T/empty" POOL_TEST_POSTGRES=1 suite
grep -qx "HARNESS_PG: could-not-start (no postgres in $T/empty)" "$OUT" && ok || bad "P7: could-not-start must name the missing binary: $(cat "$OUT")"
[ "$(cat "$T/order.log")" = "run test	DATABASE_URL=UNSET" ] && ok || bad "P7: the suite runs without a URL: $(cat "$T/order.log")"
grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "P7: the suite's own exit: $(cat "$OUT")"
grep -q 'postgres: HARNESS_PG: could-not-start' "$BUILD/pipeline.log" && ok || bad "P7: pipeline.log names the could-not-start"
[ "$(pgdirs)" = 0 ] && ok || bad "P7: no pgtest.* dir"

# P10 — initdb fails: could-not-start with its last line, nothing left behind.
INITDB_RC=1 POOL_TEST_POSTGRES=1 suite
grep -qx 'HARNESS_PG: could-not-start (initdb failed: initdb: fixture failure)' "$OUT" && ok || bad "P10: initdb failure line: $(cat "$OUT")"
[ "$(cut -f2 "$T/order.log")" = 'DATABASE_URL=UNSET' ] && ok || bad "P10: no URL after a failed start: $(cat "$T/order.log")"
[ "$(pgdirs)" = 0 ] && ok || bad "P10: no pgtest.* dir after a failed initdb"
# A start that fails on every port is the same honest line.
PGCTL_RC=1 POOL_TEST_POSTGRES=1 suite
grep -q '^HARNESS_PG: could-not-start (pg_ctl start failed on 10 ports' "$OUT" && ok || bad "P10: pg_ctl failure line: $(cat "$OUT")"
[ "$(pgdirs)" = 0 ] && ok || bad "P10: no pgtest.* dir after a failed start"

# P9 — the per-project settings row is the one the lib reads.
settings '{"lane.fly-pool.project-6-os.pool_test_postgres":"1"}'
suite
grep -q '^HARNESS_PG: up ' "$OUT" && grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "P9: the project-6-os row must turn it on: $(cat "$OUT")"
PROJ=other-project suite
grep -q '^HARNESS_PG' "$OUT" && bad "P9: the row is per project; another project stays off: $(cat "$OUT")" || ok
settings '{"lane.fly-pool.project-6-os.pool_test_postgres":"0"}'
POOL_TEST_POSTGRES=1 suite
grep -q '^HARNESS_PG' "$OUT" && bad "P9: a row of 0 wins over the env: $(cat "$OUT")" || ok
settings '{}'
J="$DIR/catalog/lanes.d/fly-pool.json"
[ "$(jq -c '.knobs[] | select(.env=="POOL_TEST_POSTGRES") | [.default,.min,.max,.zero_means,.read_in]' "$J")" = '[0,0,1,"off","bin/lib/pg-test.sh"]' ] && ok \
  || bad "P9: POOL_TEST_POSTGRES must default 0 (min 0, max 1, zero off) read in bin/lib/pg-test.sh"
[ "$(jq -c '.knobs[] | select(.env=="POOL_TEST_POSTGRES_MAJOR") | [.default,.read_in,.settable]' "$J")" = '[16,"bin/lib/pg-test.sh",true]' ] && ok \
  || bad "P9: POOL_TEST_POSTGRES_MAJOR must default 16, read in bin/lib/pg-test.sh"
[ "$(jq -c '.knobs[] | select(.env=="POOL_TEST_SETUP_CMD") | [.default,.read_in]' "$J")" = '["","bin/lib/pg-test.sh"]' ] && ok \
  || bad "P9: POOL_TEST_SETUP_CMD must default empty, read in bin/lib/pg-test.sh"
jq -e '.knobs[] | select(.env=="POOL_TEST_POSTGRES_SETUP")' "$J" >/dev/null && bad "P9: POOL_TEST_POSTGRES_SETUP is replaced by POOL_TEST_SETUP_CMD" || ok
# Turning it on for a project is a settings change after merge, never a seed.
ls "$DIR"/worker/jobs/schema.d/*bh-5962* >/dev/null 2>&1 && bad "P9: no schema.d seed: project-6-os is turned on by a settings row after merge" || ok
# A missing schema.sql is a failure, never a pass: grep exits 2 on it, and
# `grep -q … && bad || ok` read that as ok (lead review lr-6093).
if [ -r "$DIR/worker/jobs/schema.sql" ]; then
  grep -q 'pool_test_postgres' "$DIR/worker/jobs/schema.sql" && bad "P9: worker/jobs/schema.sql must carry no pool_test_postgres seed" || ok
else
  bad "P9: worker/jobs/schema.sql is missing, so the no-seed check checked nothing"
fi

# P8 — the image block bakes the pin.
PIN="$DIR/bin/lib/pgtest-pin.sh"
BLK=$(awk '/^# >>> bake-pgtest/{f=1;next} /^# <<< bake-pgtest/{f=0} f' "$DIR/fly/Dockerfile")
if [ -r "$PIN" ] && [ -n "$BLK" ]; then
  ( . "$PIN"
    grep -qx "ARG PGTEST_PKG_VERSION=$PGTEST_PIN_PKG_VERSION" <<<"$BLK" \
    && grep -qx "ARG PGTEST_SHA256=$PGTEST_PIN_SHA256" <<<"$BLK" \
    && grep -qx "ARG PGTEST_PG_VERSION=$PGTEST_PIN_PG_VERSION" <<<"$BLK" ) && ok || bad "P8: the Dockerfile ARGs must equal bin/lib/pgtest-pin.sh"
  grep -q 'sha256sum -c' <<<"$BLK" && grep -q 'bake_verify postgres' <<<"$BLK" && ok || bad "P8: the block must check the sha256 and bake_verify postgres"
  awk '/^FROM base AS final/{f=1} /^# >>> bake-pgtest/{p=NR} /^# >>> cli-pin-verify/{c=NR} END{exit !(f && p && c && p < c)}' "$DIR/fly/Dockerfile" \
    && awk '/^FROM /{s=$0} /^# >>> bake-pgtest/{exit !(s=="FROM base AS final")}' "$DIR/fly/Dockerfile" && ok \
    || bad "P8: bake-pgtest must be in the final stage, before cli-pin-verify"
  [ "$( . "$PIN"; echo "$PGTEST_PIN_DIR/bin")" = "$(env -u PGT_BIN_DIR bash -c '. "$1"; echo "$PGT_BIN_DIR"' _ "$DIR/bin/lib/pg-test.sh")" ] && ok \
    || bad "P8: pg-test.sh's PGT_BIN_DIR default must be the pin's dir/bin"
else
  bad "P8: bin/lib/pgtest-pin.sh and the fly/Dockerfile bake-pgtest block must both exist"
fi

# P11 — the real Postgres, only on the pool image.
if [ -x /opt/pgtest/bin/postgres ]; then
  mkdir -p "$T/realbin"
  cat > "$T/realbin/npm" <<'EOF'
#!/bin/bash
[ "$2" = test ] || exit 0
p="${DATABASE_URL##*:}"; p="${p%%/*}"
(exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "cannot connect to $DATABASE_URL"; exit 1; }
echo "db reachable"
EOF
  chmod +x "$T/realbin/npm"; chmod 755 "$T" "$T/tmp"
  scratch_rm "$REPO"; scratch_rm "$BUILD"; mkdir -p "$REPO" "$BUILD"
  printf '{"scripts":{"test":"x"}}\n' > "$REPO/package.json"
  ( cd "$REPO" || exit 1
    export PATH="$T/realbin:$PATH" HARNESS="$T/h" BUILD PROJECT=project-6-os KEY=TK-1 TEST_SELECT=0 \
      PGT_BIN_DIR=/opt/pgtest/bin TMPDIR="$T/tmp" LANE_GATE_NOW="$NOW" POOL_TEST_POSTGRES=1
    STAMP() { echo 2026-10-11T00:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
  grep -q '^HARNESS_PG: up (PostgreSQL 16.14, ' "$OUT" && grep -qx 'HARNESS_EXIT: 0' "$OUT" && grep -qx 'HARNESS_PG: torn down' "$OUT" && ok \
    || bad "P11: the real Postgres 16.14 must come up, serve the suite and go down: $(cat "$OUT")"
  [ "$(pgdirs)" = 0 ] && ok || bad "P11: no pgtest.* dir after the real run"
else
  echo "SKIP P11: no /opt/pgtest on this host"
fi

echo "pool-test-postgres.bh-5962: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
