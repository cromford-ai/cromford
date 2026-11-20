#!/bin/bash
# tests/pool-test-postgres-project-1.bh-9835-test.sh — project-1 pool builds get
# the throwaway Postgres (BH-5962) and a `prisma db push` schema setup, so the
# suite run ends green or red, never `could-not-run: DATABASE_URL`.
#
# THE DEFECT THIS PINS (BH-9835). project-1 had no lane.fly-pool rows, so its
# suite ran with no DATABASE_URL. The red suite had a Prisma DB signature, and
# sp_build_post recorded `could-not-run: DATABASE_URL (suite rc 1)` on TK-353,
# TK-406 and TK-329.
#
# The settings cache is built FROM the bh-9835 schema.d fragment's VALUES rows,
# so the seed itself is under test. The `harness suite run` block is lifted from
# run-build by its markers and run in a scratch repo with the real
# bin/lib/pg-test.sh, lane-gate.sh and suite-preflight.sh. initdb/pg_ctl/postgres,
# setpriv, npm and npx are stubs that log to $T. No network, nothing written
# outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset DATABASE_URL DIRECT_URL POSTGRES_URL PGPASSWORD PGHOST SUPABASE_DB_URL POOL_TEST_POSTGRES POOL_TEST_SETUP_CMD \
  POOL_TEST_POSTGRES_MAJOR POOL_TEST_POSTGRES_SERIAL PGT_BIN_DIR INITDB_RC PGCTL_RC PUSH_RC TEST_RC TEST_DBERR SUITE_PREFLIGHT_ENV
NOW=1760140800

FRAG=$(compgen -G "$DIR/worker/jobs/schema.d/*-bh-9835-project-1-pool-postgres.sql" | head -1)
[ -n "$FRAG" ] && [ -r "$FRAG" ] && ok || bad "no worker/jobs/schema.d/*-bh-9835-project-1-pool-postgres.sql fragment"

. "$DIR/tests/lib/rb-all.sh" || exit 1
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' "$RB" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

mkdir -p "$T/h" "$T/fakebin" "$T/pgbin" "$T/tmp"
for f in bin/lib/pg-test.sh bin/lib/lane-gate.sh bin/lib/suite-preflight.sh; do
  scratch_install_closure "$f" "$T/h" > /dev/null || bad "cannot install $f into the scratch harness"
done
LIB="$T/h/bin/lib/pg-test.sh"

cat > "$T/pgbin/initdb" <<EOF
#!/bin/bash
d=""; while [ \$# -gt 0 ]; do [ "\$1" = -D ] && { d="\$2"; shift; }; shift; done
echo initdb >> "$T/seq.log"
mkdir -p "\$d"
EOF
cat > "$T/pgbin/pg_ctl" <<EOF
#!/bin/bash
d=""; verb=""; while [ \$# -gt 0 ]; do case "\$1" in -D) d="\$2"; shift ;; start|stop) verb="\$1" ;; esac; shift; done
echo "pg_ctl \$verb" >> "$T/seq.log"
case "\$verb" in start) echo 1 > "\$d/postmaster.pid" ;; stop) rm -f "\$d/postmaster.pid" ;; esac
EOF
printf '#!/bin/bash\necho "postgres (PostgreSQL) 16.14"\n' > "$T/pgbin/postgres"
cat > "$T/fakebin/setpriv" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "${1#--}" != "$1" ]; do shift; done
exec "$@"
EOF
# npx: `prisma generate` (the prelude) and `prisma db push` (the setup).
cat > "$T/fakebin/npx" <<EOF
#!/bin/bash
printf 'npx %s\tDATABASE_URL=%s\n' "\$*" "\${DATABASE_URL:-UNSET}" >> "$T/seq.log"
case "\$*" in "prisma db push"*) exit "\${PUSH_RC:-0}" ;; esac
exit 0
EOF
# npm: the suite (`run test`) records its env; any other script is a setup.
cat > "$T/fakebin/npm" <<EOF
#!/bin/bash
printf 'npm %s\tDATABASE_URL=%s\n' "\$*" "\${DATABASE_URL:-UNSET}" >> "$T/seq.log"
if [ "\$2" = test ]; then
  env | grep -E '^[^=]*(DATABASE_URL|DIRECT_URL|DB_URL)[^=]*=|^(POSTGRES|PG|SUPABASE_DB)[^=]*=' | grep -v '^PGT_' | sort > "$T/suite-env.log"
  [ "\${TEST_DBERR:-0}" = 1 ] && echo "PrismaClientInitializationError: Can't reach database server at 127.0.0.1"
  exit "\${TEST_RC:-0}"
fi
exit 0
EOF
chmod +x "$T/pgbin/"* "$T/fakebin/"*

REPO="$T/repo"; BUILD="$T/build"; OUT="$BUILD/harness-suite.txt"
LOCAL_RE='^postgresql://harness@127\.0\.0\.1:[0-9]{4,5}/postgres$'
SUPA=postgresql://postgres:pw@db.kxwocreggzngjhymahge.supabase.co:5432/postgres

# The settings cache lane_knob reads, built from the fragment's VALUES rows.
frag_values() {
  sed -nE "s/^[[:space:]]*\('([^']*)','([^']*)',.*$/\1\t\2/p" "$FRAG" \
    | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'
}
settings() {
  mkdir -p "$T/h/state"
  printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$T/h/state/settings-cache.json"
}
# suite <prisma: file|dir|none> — HARNESS_SUITE_RUN lenses in a fresh repo for $PROJ.
suite() {
  scratch_rm "$REPO"; scratch_rm "$BUILD"; scratch_rm "$T/h/state/suite-preflight"
  mkdir -p "$REPO" "$BUILD"
  : > "$T/seq.log"; : > "$T/suite-env.log"
  printf '{"scripts":{"test":"x","db:apply":"y"}}\n' > "$REPO/package.json"
  case "${1:-file}" in
    file) mkdir -p "$REPO/prisma"; echo 'datasource db { provider = "postgresql" url = env("DATABASE_URL") }' > "$REPO/prisma/schema.prisma" ;;
    dir)  mkdir -p "$REPO/prisma/schema"; echo 'model A { id Int @id }' > "$REPO/prisma/schema/a.prisma" ;;
  esac
  ( cd "$REPO" || exit 1
    export PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD PROJECT="${PROJ:-project-1}" KEY=TK-1 TEST_SELECT=0 \
      PGT_BIN_DIR="$T/pgbin" TMPDIR="$T/tmp" PGT_ROOTS="$T/tmp" LANE_GATE_NOW="$NOW" SUITE_PREFLIGHT_TODAY=20261119
    STAMP() { echo 2026-11-19T00:00:00Z; }
    # shellcheck source=/dev/null
    . "$T/suite-run.sh"
    HARNESS_SUITE_RUN harness-suite.txt lenses )
}
pushes() { grep -c '^npx prisma db push' "$T/seq.log"; }
SV=$(frag_values 2>/dev/null)
[ -n "$SV" ] || SV='{}'
settings "$SV"

# M1 — the fragment's rows resolve through pgt_knob for project-1.
r=$( export HARNESS="$T/h" PROJECT=project-1 LANE_GATE_NOW="$NOW"; . "$LIB"
     printf '%s|%s' "$(pgt_knob POOL_TEST_POSTGRES)" "$(pgt_knob POOL_TEST_SETUP_CMD)" )
[ "$r" = '1|prisma db push' ] && ok || bad "M1: the bh-9835 rows must give POOL_TEST_POSTGRES=1 and POOL_TEST_SETUP_CMD='prisma db push' (got '$r')"
grep -q 'INSERT OR IGNORE INTO settings' "$FRAG" && ok || bad "M1: the seed must be INSERT OR IGNORE (an operator row wins)"

# M2 — the box env names the Supabase project; the suite sees only the local URL.
DATABASE_URL="$SUPA" DIRECT_URL="$SUPA" SUPABASE_DB_URL="$SUPA" POSTGRES_URL="$SUPA" suite file
U=$(sed -n 's/^DATABASE_URL=//p' "$T/suite-env.log"); D=$(sed -n 's/^DIRECT_URL=//p' "$T/suite-env.log")
[[ "$U" =~ $LOCAL_RE ]] && ok || bad "M2: the suite's DATABASE_URL must be local and non-empty (got '$U'): $(cat "$OUT")"
[ -n "$D" ] && [ "$D" = "$U" ] && ok || bad "M2: DIRECT_URL must equal DATABASE_URL (got '$D')"
grep -qi supabase "$T/suite-env.log" && bad "M2: a supabase host reached the suite: $(cat "$T/suite-env.log")" || ok
grep -Eq '^(SUPABASE_DB_URL|POSTGRES_URL)=' "$T/suite-env.log" && bad "M2: SUPABASE_DB_URL/POSTGRES_URL must be unset in the suite" || ok
# The setup (push) and the suite. The `prisma generate` prelude runs in the build env
# on purpose (BH-1955) and opens no connection, so it is not one of the children.
grep -qi supabase <<<"$(grep -E '^(npx prisma db push|npm run test)' "$T/seq.log")" && bad "M2: a supabase host reached the setup or the suite: $(cat "$T/seq.log")" || ok
[ "$(grep -cE '^(npx prisma db push|npm run test)' "$T/seq.log")" = 2 ] && ok || bad "M2: the push and the suite must both run: $(cat "$T/seq.log")"

# M3 — the setup is `prisma db push` against the local URL, after the start, before the suite.
suite file
seq=$(cut -f1 "$T/seq.log" | tr '\n' '|')
case "$seq" in
  *'initdb|pg_ctl start|npx prisma db push --skip-generate --accept-data-loss|npm run test|pg_ctl stop|') ok ;;
  *) bad "M3: order must be initdb, pg_ctl start, push, suite, stop (got '$seq')" ;;
esac
pu=$(awk -F'\t' '$1 ~ /^npx prisma db push/{sub(/^DATABASE_URL=/,"",$2); print $2}' "$T/seq.log")
[[ "$pu" =~ $LOCAL_RE ]] && ok || bad "M3: the push must get the local URL (got '$pu')"
grep -qx 'HARNESS_PG_SETUP: prisma db push (rc=0)' "$OUT" && ok || bad "M3: setup line rc=0: $(cat "$OUT")"
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "M3: green suite is HARNESS_EXIT: 0: $(cat "$OUT")"

# M4 — a red suite with a DB signature while the throwaway is up is red, not could-not-run.
TEST_RC=1 TEST_DBERR=1 suite file
grep -qx 'HARNESS_EXIT: 1' "$OUT" && ok || bad "M4: red suite with the throwaway up must be HARNESS_EXIT: 1: $(cat "$OUT")"
grep -q 'could-not-run: DATABASE_URL' "$OUT" "$BUILD/pipeline.log" && bad "M4: no could-not-run: DATABASE_URL with the throwaway up: $(cat "$OUT")" || ok
compgen -G "$T/h/state/suite-preflight/alerted-project-1-*" > /dev/null && bad "M4: no suite-preflight alert with the throwaway up" || ok
# Control: the same red output with the throwaway off IS the soft miss (the M4 check can go red).
settings '{"lane.fly-pool.project-1.pool_test_postgres":"0"}'
TEST_RC=1 TEST_DBERR=1 suite file
grep -q '^HARNESS_EXIT: could-not-run: DATABASE_URL' "$OUT" && ok || bad "M4 control: off must still be could-not-run: DATABASE_URL: $(cat "$OUT")"
settings "$SV"

# M5 — a project with no rows and no prisma: no new variable, no Postgres.
PROJ=plain suite none
grep -q '^HARNESS_PG' "$OUT" && bad "M5: no HARNESS_PG/HARNESS_PG_SETUP line for a plain repo: $(cat "$OUT")" || ok
[ "$(cut -f2 "$T/seq.log")" = 'DATABASE_URL=UNSET' ] && ok || bad "M5: the suite sees no DATABASE_URL: $(cat "$T/seq.log")"
[ -s "$T/suite-env.log" ] && bad "M5: no DB-address name in the suite env: $(cat "$T/suite-env.log")" || ok
grep -qx 'HARNESS_EXIT: 0' "$OUT" && ok || bad "M5: HARNESS_EXIT: 0: $(cat "$OUT")"

# M6 — the setup-value decision table.
POOL_TEST_SETUP_CMD='prisma db push' suite dir
[ "$(pushes)" = 1 ] && grep -qx 'HARNESS_PG_SETUP: prisma db push (rc=0)' "$OUT" && ok || bad "M6: a prisma/schema/ dir is a prisma repo: $(cat "$OUT")"
POOL_TEST_SETUP_CMD='prisma db push' suite none
[ "$(pushes)" = 0 ] && grep -qx 'HARNESS_PG_SETUP: none (no prisma schema)' "$OUT" && ok || bad "M6: no prisma schema is none, not a push: $(cat "$OUT")"
grep -q 'HARNESS_PG_SETUP: prisma db push (rc=0)' "$OUT" && bad "M6: none must never read as rc=0" || ok
for s in 'prisma db push --force-reset' 'npx prisma db push' ' prisma db push' 'prisma db push;rm -rf x' \
         'prisma migrate deploy' $'prisma db push\nx' 'PRISMA DB PUSH' 'prisma  db push' 'prisma db push '; do
  settings "$(jq -c --arg s "$s" '. + {"lane.fly-pool.project-1.pool_test_setup_cmd": $s}' <<<"$SV")"
  suite file
  [ "$(pushes)" = 0 ] && ok || bad "M6: '$s' must run no push: $(cat "$T/seq.log")"
  grep -q '^HARNESS_PG_SETUP: refused (' "$OUT" && ok || bad "M6: '$s' must be refused: $(cat "$OUT")"
done
settings "$(jq -c '. + {"lane.fly-pool.project-1.pool_test_setup_cmd": "npm run db:apply"}' <<<"$SV")"
suite file
grep -q $'^npm run db:apply\t' "$T/seq.log" && [ "$(pushes)" = 0 ] && grep -qx 'HARNESS_PG_SETUP: npm run db:apply (rc=0)' "$OUT" && ok \
  || bad "M6: 'npm run db:apply' still runs the npm script: $(cat "$OUT")"
settings "$SV"

# M7 — a red push is evidence: rc recorded, the suite still runs, teardown before HARNESS_EXIT.
PUSH_RC=1 suite file
grep -qx 'HARNESS_PG_SETUP: prisma db push (rc=1)' "$OUT" && ok || bad "M7: red push rc=1: $(cat "$OUT")"
grep -q $'^npm run test\t' "$T/seq.log" && ok || bad "M7: the suite still runs after a red push"
[ "$(tail -2 "$OUT" | head -1)" = 'HARNESS_PG: torn down' ] && tail -1 "$OUT" | grep -qx 'HARNESS_EXIT: 0' && ok \
  || bad "M7: torn down, then HARNESS_EXIT last: $(cat "$OUT")"
[ "$(compgen -G "$T/tmp/pgtest.*" | wc -l)" = 0 ] && ok || bad "M7: no pgtest.* dir left"

# M8 — project-1 only.
o=$(grep -oE "'lane\.fly-pool\.[^.']+\." "$FRAG" | sort -u)
[ "$o" = "'lane.fly-pool.project-1." ] && ok || bad "M8: the fragment seeds only project-1 fly-pool rows (got: $o)"
PROJ=project-1-staging suite file
grep -q '^HARNESS_PG' "$OUT" && bad "M8: project-1-staging gets no throwaway: $(cat "$OUT")" || ok
[ "$(pushes)" = 0 ] && ok || bad "M8: project-1-staging runs no push"

echo "pool-test-postgres-project-1.bh-9835: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
