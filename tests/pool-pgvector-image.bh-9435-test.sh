#!/bin/bash
# tests/pool-pgvector-image.bh-9435-test.sh — the pool image's throwaway Postgres
# carries the pgvector extension, so `CREATE EXTENSION vector` succeeds in it.
#
# THE DEFECT THIS PINS (BH-9435). bake-pgtest installs the
# @embedded-postgres/linux-x64 tarball into /opt/pgtest, and that tarball has no
# `vector` extension. Since project-6's 20261028194822_knowledge_chunk.sql a full
# suite run there fails 967 to 1,325 files on `extension "vector" is not
# available`.
#
# V1-V5 read fly/Dockerfile and bin/lib/pgtest-pin.sh (static, run everywhere).
# V6 is the live image check. It runs only where the image baked pgvector (the
# block writes /opt/pgtest/PGVECTOR_VERSION). A /opt/pgtest without that file
# is an image built before this change, and V6 prints a SKIP with that reason.
# No network. Nothing is written outside $T.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

DF="$DIR/fly/Dockerfile"
PIN="$DIR/bin/lib/pgtest-pin.sh"
block() { awk -v m="$1" '$0 == "# >>> " m {f=1; next} $0 == "# <<< " m {f=0} f' "$DF"; }
stage() { awk -v s="$1" '/^FROM /{f=($0 ~ (" AS " s "$"))} f' "$DF"; }
BUILD_BLK=$(block pgvector-build)
BAKE_BLK=$(block bake-pgvector)

# V1. The pins exist in bin/lib/pgtest-pin.sh, and the sha256 is 64 hex.
PV=$( . "$PIN" 2>/dev/null; echo "${PGVECTOR_PIN_VERSION:-}")
PS=$( . "$PIN" 2>/dev/null; echo "${PGVECTOR_PIN_SHA256:-}")
[[ "$PV" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok || bad "V1: bin/lib/pgtest-pin.sh must set PGVECTOR_PIN_VERSION to x.y.z (got '$PV')"
[[ "$PS" =~ ^[0-9a-f]{64}$ ]] && ok || bad "V1: bin/lib/pgtest-pin.sh must set PGVECTOR_PIN_SHA256 to 64 hex (got '$PS')"

# V2. A pgvector-build stage FROM base builds the pinned source: the ARGs equal
# the pin, the download is checked with sha256sum -c, and make runs against the
# PG 16 pg_config with portable flags (no -march=native from the build host).
if [ -n "$BUILD_BLK" ]; then
  awk '/^FROM /{s=$0} /^# >>> pgvector-build$/{exit !(s=="FROM base AS pgvector-build")}' "$DF" && ok \
    || bad "V2: the pgvector-build block must sit in a 'FROM base AS pgvector-build' stage"
  grep -qx "ARG PGVECTOR_VERSION=$PV" <<<"$BUILD_BLK" && grep -qx "ARG PGVECTOR_SHA256=$PS" <<<"$BUILD_BLK" && ok \
    || bad "V2: pgvector-build's ARGs must equal bin/lib/pgtest-pin.sh"
  grep -q 'sha256sum -c' <<<"$BUILD_BLK" && ok || bad "V2: pgvector-build must check the tarball with sha256sum -c"
  grep -q 'postgresql-server-dev-16' <<<"$BUILD_BLK" && grep -q 'PG_CONFIG=/usr/lib/postgresql/16/bin/pg_config' <<<"$BUILD_BLK" && ok \
    || bad "V2: pgvector-build must build against the PG 16 headers and pg_config"
  grep -q 'OPTFLAGS=""' <<<"$BUILD_BLK" && ok || bad "V2: pgvector-build must build with OPTFLAGS=\"\" (portable, no -march=native)"
  grep -q 'DESTDIR=/out' <<<"$BUILD_BLK" && ok || bad "V2: pgvector-build must install into DESTDIR=/out"
else
  bad "V2: no '# >>> pgvector-build' block in fly/Dockerfile"
fi

# V3. The bake-pgvector block is in the final stage, after bake-pgtest and
# before cli-pin-verify.
if [ -n "$BAKE_BLK" ]; then
  awk '/^FROM /{s=$0} /^# >>> bake-pgvector$/{exit !(s=="FROM base AS final")}' "$DF" && ok \
    || bad "V3: bake-pgvector must be in the final stage"
  awk '/^# >>> bake-pgtest$/{p=NR} /^# >>> bake-pgvector$/{v=NR} /^# >>> cli-pin-verify$/{c=NR} END{exit !(p && v && c && p < v && v < c)}' "$DF" && ok \
    || bad "V3: bake-pgvector must stand after bake-pgtest and before cli-pin-verify"
else
  bad "V3: no '# >>> bake-pgvector' block in fly/Dockerfile"
fi

# V4. The block copies the three artifacts into the dirs /opt/pgtest's postgres
# resolves ($libdir = lib/postgresql, extension dir = share/postgresql/extension),
# and its RUN proves the extension loads: initdb, CREATE EXTENSION vector and a
# vector cast, with a backend that exits nonzero on an error.
if [ -n "$BAKE_BLK" ]; then
  grep -qx "ARG PGVECTOR_VERSION=$PV" <<<"$BAKE_BLK" && ok || bad "V4: bake-pgvector's ARG must equal bin/lib/pgtest-pin.sh"
  grep -q '^COPY --from=pgvector-build .*vector\.so /opt/pgtest/lib/postgresql/' <<<"$BAKE_BLK" && ok \
    || bad "V4: bake-pgvector must COPY vector.so into /opt/pgtest/lib/postgresql/"
  grep -q '^COPY --from=pgvector-build .* /opt/pgtest/share/postgresql/extension/' <<<"$BAKE_BLK" && ok \
    || bad "V4: bake-pgvector must COPY the control and sql files into /opt/pgtest/share/postgresql/extension/"
  RUNTXT=$(grep -v '^COPY\|^ARG\|^#' <<<"$BAKE_BLK")
  grep -q 'CREATE EXTENSION vector' <<<"$RUNTXT" && ok || bad "V4: the bake-pgvector RUN must run CREATE EXTENSION vector"
  grep -qF "'[1,2]'::vector" <<<"$RUNTXT" && ok || bad "V4: the bake-pgvector RUN must cast a value to vector"
  grep -q 'initdb' <<<"$RUNTXT" && grep -q 'exit_on_error=on' <<<"$RUNTXT" && ok \
    || bad "V4: the bake-pgvector RUN must initdb a cluster and run with exit_on_error=on (an ERROR must fail the layer)"
  grep -q 'bake_verify pgvector "\$PGVECTOR_VERSION"' <<<"$RUNTXT" && ok || bad "V4: the bake-pgvector RUN must bake_verify the extension version"
  grep -q '/opt/pgtest/PGVECTOR_VERSION' <<<"$RUNTXT" && ok || bad "V4: the bake-pgvector RUN must write /opt/pgtest/PGVECTOR_VERSION (the V6 marker)"
fi

# V5. The PG dev headers stay in the build stage: the final stage never installs
# them. (build-essential is not checked here: the project-rust block of the
# final stage installs it on purpose, BH-8319.)
FINAL=$(stage final)
grep -q 'postgresql-server-dev' <<<"$FINAL" && bad "V5: the final stage must not install postgresql-server-dev" || ok
[ "$(grep -c '^FROM base AS pgvector-build$' "$DF")" = 1 ] && ok || bad "V5: exactly one pgvector-build stage"

# V6. Live: the extension loads in the real /opt/pgtest.
if [ ! -x /opt/pgtest/bin/postgres ]; then
  echo "SKIP (no /opt/pgtest)"
elif [ ! -r /opt/pgtest/PGVECTOR_VERSION ]; then
  echo "SKIP (/opt/pgtest predates bake-pgvector: no /opt/pgtest/PGVECTOR_VERSION)"
else
  W=$(mktemp -d "$T/pgv.XXXXXX"); chmod 755 "$T"
  AS=(env LD_LIBRARY_PATH=/opt/pgtest/lib)
  [ "$(id -u)" = 0 ] && { chown nobody:nogroup "$W"; AS=(setpriv --reuid=nobody --regid=nogroup --clear-groups env LD_LIBRARY_PATH=/opt/pgtest/lib); }
  if "${AS[@]}" /opt/pgtest/bin/initdb -D "$W/data" -U harness --auth=trust -E UTF8 --no-sync > "$W/initdb.log" 2>&1; then
    printf "CREATE EXTENSION vector;\nSELECT '[1,2]'::vector;\n" \
      | "${AS[@]}" /opt/pgtest/bin/postgres --single -D "$W/data" -c exit_on_error=on postgres > "$W/single.log" 2>&1
    rc=$?
    [ "$rc" = 0 ] && grep -qF '[1,2]' "$W/single.log" && ok \
      || bad "V6: CREATE EXTENSION vector must return rc 0 in /opt/pgtest (rc=$rc): $(grep -m2 -E 'FATAL|ERROR' "$W/single.log")"
  else
    bad "V6: initdb failed in /opt/pgtest: $(tail -1 "$W/initdb.log")"
  fi
fi

echo "pool-pgvector-image.bh-9435: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
