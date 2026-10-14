#!/bin/bash
# tests/schema-compose-tests.bh-6005-1-test.sh — the shell suites read the jobs
# schema from worker/jobs/schema.d/ (BH-6005.1, ticket BH-6008).
#
# WHY. worker/jobs/schema.sql is a render of schema.d/ (BH-4987) and is leaving
# git (BH-6005). A suite that reads the render must compose it first, through
# tests/lib/jobs-schema.sh, or it goes red the day the file is not in the tree.
#
#   G1 every suite (and tests/lib file) that reads <rootvar>/worker/jobs/schema.sql
#      calls jobs_schema_render; the two fixture-only suites read no real path;
#      the matcher flags a real read and none of the three negative shapes
#   G2 jobs_schema_render writes an absent file equal to bin/schema-build.sh,
#      replaces a different one, and does not write equal bytes
#   G3 a refused compose is rc 1 with a FAIL line, no temp file in $TMPDIR or
#      worker/jobs, the file as it was; no schema.d/ is rc 0 with a file and
#      rc 1 without one
#   G4 a read-only worker/jobs: equal bytes rc 0 and no write, different bytes
#      rc 1 and a clean $TMPDIR, no file at all rc 1
#   G5 no node test under worker/jobs/test/ reads ../schema.sql itself: each one
#      takes jobsSchemaSql()/jobsSchemaFile() from test/lib/jobs-schema.js (three
#      node suites added on main after this ticket's inventory did, lr-6093)
#   G6 no node code under tests/ reads worker/jobs/schema.sql itself: a tests/lib
#      .mjs/.js driver takes jobsSchemaSql() from worker/jobs/test/lib/
#      jobs-schema.js, and a suite whose embedded node driver reads the file
#      calls jobs_schema_render first (suite-reuse.bh-5366 and three drivers
#      that G1's root-variable regex cannot see, lr-6093 at 7c9b200b8)
#   D1 no statement appears twice in the composition of the real schema.d/, and
#      the check prints a statement that two fixture fragments both hold
#
# Run from anywhere: tests/schema-compose-tests.bh-6005-1-test.sh   (exit 0 = all pass)
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" || exit 1
# shellcheck source=bin/lib/d1-schema.sh
. "$DIR/bin/lib/d1-schema.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SB="$DIR/bin/schema-build.sh"
FRAG='CREATE TABLE IF NOT EXISTS fixture_a (id INTEGER);'

# ============================================================================
# G1. the static guard
# ============================================================================

# Suites that name <rootvar>/worker/jobs/schema.sql only for their OWN scratch
# repo ($R is "$T/r" in both). They read no real file, so they need no render.
FIXTURE_ONLY="queue-partition.bh-4979-test.sh rules-pack.bh-3510-test.sh regenerated-schema-conflicts.bh-6000-test.sh"
# The ticket's root variables, plus `root` for tests/lib/model-route-stub.sh.
READ_RE='\$\{?(DIR|ROOT|REPO|H|HARNESS|REPO_ROOT|SRC|R|root)\}?/worker/jobs/schema\.sql'

# g1_offenders <file>... — print each file that reads the schema through a root
# variable on a non-comment line and never calls jobs_schema_render.
g1_offenders() {
  local f b skip x body
  for f in "$@"; do
    b=${f##*/}; skip=0
    for x in $FIXTURE_ONLY; do [ "$b" = "$x" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    # Into a variable first: `grep -v … | grep -q` under pipefail fails when
    # grep -q exits early and the first grep takes a SIGPIPE (BH-1818).
    body=$(grep -v -E '^\s*#' "$f")
    grep -q -E "$READ_RE" <<< "$body" || continue
    grep -q 'jobs_schema_render' <<< "$body" || echo "$f"
  done
}

OFF=$(g1_offenders "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh "$DIR"/tests/lib/*.sh)
if [ -z "$OFF" ]; then ok; else
  while IFS= read -r f; do bad "G1: ${f#"$DIR"/} reads worker/jobs/schema.sql and never calls jobs_schema_render — add '. \"\$(dirname \"\$0\")/lib/jobs-schema.sh\" && jobs_schema_render || exit 1' after its scratch.sh line"; done <<< "$OFF"
fi
# The guard must have something to guard: the corpus has readers today.
N_READERS=$(for f in "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh "$DIR"/tests/lib/*.sh; do
  grep -v -E '^\s*#' "$f" | grep -E "$READ_RE" >/dev/null && echo "$f"; done | wc -l)
[ "$N_READERS" -ge 50 ] && ok || bad "G1: only $N_READERS readers matched — the regex no longer finds the corpus"

for x in $FIXTURE_ONLY; do
  if [ ! -f "$DIR/tests/$x" ]; then
    bad "G1: fixture-only suite tests/$x is gone — drop it from FIXTURE_ONLY"
  elif grep -v -E '^\s*#' "$DIR/tests/$x" | grep -E '\$\{?(DIR|ROOT|REPO)\}?/worker/jobs/schema\.sql' >/dev/null; then
    bad "G1: tests/$x reads the REAL worker/jobs/schema.sql, so it is not fixture-only — give it jobs_schema_render"
  else ok; fi
done

# The matcher over scratch files: three shapes it must not flag, one it must.
SP="worker/jobs/schema"
mkdir -p "$T/g1"
printf '#!/bin/bash\n# cat "$DIR/%s.sql"\n' "$SP" > "$T/g1/comment-test.sh"
printf '#!/bin/bash\ntouch "$R/%s.sql"\n' "$SP" > "$T/g1/rules-pack.bh-3510-test.sh"
printf '#!/bin/bash\ngit show base:%s.sql\n' "$SP" > "$T/g1/gitpath-test.sh"
printf '#!/bin/bash\ncat "$DIR/%s.sql"\n' "$SP" > "$T/g1/reader-test.sh"
OFF=$(g1_offenders "$T"/g1/*.sh)
[ "$OFF" = "$T/g1/reader-test.sh" ] && ok || bad "G1 matcher: want only reader-test.sh flagged, got: ${OFF:-nothing}"

# ============================================================================
# G2. render, replace, no write when equal
# ============================================================================
# G2 and G3 render with their own TMPDIR: the helper's temp file lives there
# (tests/lib/jobs-schema.sh), so an empty dir after each case is "no leak".
TMPDIR_G23="$T/g23-tmp"; mkdir -p "$TMPDIR_G23"
S="$T/g2"
mkdir -p "$S/worker/jobs/schema.d"
printf '%s\n' "$FRAG" > "$S/worker/jobs/schema.d/0000-fixture.sql"
OUT=$(TMPDIR="$TMPDIR_G23" jobs_schema_render "$S"); RC=$?
[ "$RC" = 0 ] && ok || bad "G2: first render rc $RC, want 0 ($OUT)"
if [ -f "$S/worker/jobs/schema.sql" ] && cmp -s "$S/worker/jobs/schema.sql" <("$SB" --root "$S" --worker jobs); then ok
else bad "G2: the render is not bin/schema-build.sh --root <scratch> --worker jobs"; fi
touch -d @0 "$S/worker/jobs/schema.sql"
OUT=$(TMPDIR="$TMPDIR_G23" jobs_schema_render "$S"); RC=$?
[ "$RC" = 0 ] && ok || bad "G2: second render rc $RC, want 0 ($OUT)"
[ "$(stat -c %Y "$S/worker/jobs/schema.sql")" = 0 ] && ok || bad "G2: equal bytes were written again (mtime moved)"
printf 'fixture-stale\n' > "$S/worker/jobs/schema.sql"
OUT=$(TMPDIR="$TMPDIR_G23" jobs_schema_render "$S"); RC=$?
if [ "$RC" = 0 ] && cmp -s "$S/worker/jobs/schema.sql" "$S/worker/jobs/schema.d/0000-fixture.sql"; then ok
else bad "G2: a stale file was not replaced by the composition (rc $RC, $OUT)"; fi
! compgen -G "$S/worker/jobs/.schema.sql.*" >/dev/null && ok || bad "G2: a .schema.sql.* temp file was left"
[ -z "$(ls -A "$TMPDIR_G23")" ] && ok || bad "G2: \$TMPDIR holds a leftover: $(ls -A "$TMPDIR_G23" | tr '\n' ' ')"

# ============================================================================
# G3. a refused compose, and no schema.d/
# ============================================================================
S="$T/g3"
mkdir -p "$S/worker/jobs/schema.d"
printf '%s\n' "$FRAG" > "$S/worker/jobs/schema.d/0000-fixture.sql"
printf 'fixture notes\n' > "$S/worker/jobs/schema.d/README"
printf 'fixture-old\n' > "$S/worker/jobs/schema.sql"
OUT=$(TMPDIR="$TMPDIR_G23" jobs_schema_render "$S"); RC=$?
[ "$RC" = 1 ] && ok || bad "G3: a stray schema.d/README gave rc $RC, want 1"
case "$OUT" in *"FAIL: jobs_schema_render: bin/schema-build.sh failed:"*README*) ok ;;
  *) bad "G3: no FAIL line naming README: $OUT" ;; esac
! compgen -G "$S/worker/jobs/.schema.sql.*" >/dev/null && ok || bad "G3: a .schema.sql.* temp file was left"
[ -z "$(ls -A "$TMPDIR_G23")" ] && ok || bad "G3: \$TMPDIR holds a leftover: $(ls -A "$TMPDIR_G23" | tr '\n' ' ')"
[ "$(cat "$S/worker/jobs/schema.sql")" = fixture-old ] && ok || bad "G3: the refused compose touched schema.sql"

S="$T/g3-none"
mkdir -p "$S/worker/jobs"
OUT=$(jobs_schema_render "$S"); RC=$?
if [ "$RC" = 1 ] && [[ $OUT == *"FAIL: jobs_schema_render: no schema.d and no schema.sql under $S"* ]]; then ok
else bad "G3: no schema.d and no file gave rc $RC: $OUT"; fi
printf 'fixture-only-file\n' > "$S/worker/jobs/schema.sql"
OUT=$(jobs_schema_render "$S"); RC=$?
if [ "$RC" = 0 ] && [ "$(cat "$S/worker/jobs/schema.sql")" = fixture-only-file ]; then ok
else bad "G3: no schema.d with a file gave rc $RC or changed it: $OUT"; fi

# ============================================================================
# G4. a read-only worker/jobs (the impact gate's nobody snapshot)
# ============================================================================
# as_user <cmd> — run a jobs_schema_render call as a user the 0555 mode binds.
# Root ignores the mode, so as root it drops to nobody through setpriv.
G4=1
if [ "$(id -u)" -eq 0 ]; then
  if command -v setpriv >/dev/null && id nobody >/dev/null 2>&1 \
     && ! setpriv --reuid nobody --regid "$(id -g nobody)" --clear-groups -- test -x "$T" -a -r "$DIR/tests/lib/jobs-schema.sh" 2>/dev/null \
     && ! { chmod o+x "$T" && setpriv --reuid nobody --regid "$(id -g nobody)" --clear-groups -- test -x "$T" -a -r "$DIR/tests/lib/jobs-schema.sh" 2>/dev/null; }; then
    # A box runs its builds as root with the scratch dir and the repo under
    # /root (mode 700): nobody cannot reach either, so every call would answer
    # "no schema.d" and test nothing (lead review lr-6093). CI runs G4 as a
    # normal user, where the 0555 mode binds without setpriv.
    echo "G4: SKIP — as root, nobody cannot reach $T or $DIR/tests/lib, so the 0555 check cannot run here"; G4=0
  elif command -v setpriv >/dev/null && id nobody >/dev/null 2>&1; then
    chmod o+x "$T"
    as_user() { setpriv --reuid nobody --regid "$(id -g nobody)" --clear-groups -- env TMPDIR="$TMPDIR_G4" bash -c '. "$1" && jobs_schema_render "$2"' _ "$DIR/tests/lib/jobs-schema.sh" "$1"; }
  else
    echo "G4: SKIP — running as root and setpriv/nobody is unavailable, so 0555 binds nobody"; G4=0
  fi
else
  as_user() { TMPDIR="$TMPDIR_G4" jobs_schema_render "$1"; }
fi
if [ "$G4" = 1 ]; then
  TMPDIR_G4="$T/g4-tmp"; mkdir -p "$TMPDIR_G4"; chmod 777 "$TMPDIR_G4"
  S="$T/g4"
  mkdir -p "$S/worker/jobs/schema.d"
  printf '%s\n' "$FRAG" > "$S/worker/jobs/schema.d/0000-fixture.sql"
  cp "$S/worker/jobs/schema.d/0000-fixture.sql" "$S/worker/jobs/schema.sql"
  touch -d @0 "$S/worker/jobs/schema.sql"
  chmod -R a+rX "$S"; chmod 0555 "$S/worker/jobs"
  OUT=$(as_user "$S"); RC=$?
  [ "$RC" = 0 ] && ok || bad "G4: read-only and equal gave rc $RC, want 0 ($OUT)"
  [ "$(stat -c %Y "$S/worker/jobs/schema.sql")" = 0 ] && ok || bad "G4: read-only and equal wrote the file"
  chmod 0755 "$S/worker/jobs"; printf 'fixture-stale\n' > "$S/worker/jobs/schema.sql"; chmod 0555 "$S/worker/jobs"
  OUT=$(as_user "$S"); RC=$?
  if [ "$RC" = 1 ] && [[ $OUT == *"differs from schema.d and $S/worker/jobs is not writable"* ]]; then ok
  else bad "G4: read-only and different gave rc $RC: $OUT"; fi
  [ "$(cat "$S/worker/jobs/schema.sql")" = fixture-stale ] && ok || bad "G4: read-only and different changed the file"
  [ -z "$(ls -A "$TMPDIR_G4")" ] && ok || bad "G4: \$TMPDIR holds a leftover: $(ls -A "$TMPDIR_G4" | tr '\n' ' ')"
  chmod 0755 "$S/worker/jobs"; rm -f "$S/worker/jobs/schema.sql"; chmod 0555 "$S/worker/jobs"
  OUT=$(as_user "$S"); RC=$?
  if [ "$RC" = 1 ] && [[ $OUT == *"is not writable and holds no schema.sql"* ]]; then ok
  else bad "G4: read-only and no file gave rc $RC: $OUT"; fi
  chmod 0755 "$S/worker/jobs"
fi

# ============================================================================
# G5. no node test reads ../schema.sql itself
# ============================================================================
G5=$(cd "$DIR/worker/jobs/test" && grep -lE "new URL\(['\"]\.\./schema\.sql['\"]" -- *.js 2>/dev/null)
if [ -z "$G5" ]; then ok; else
  while IFS= read -r f; do bad "G5: worker/jobs/test/$f reads ../schema.sql — use jobsSchemaSql() from ./lib/jobs-schema.js"; done <<< "$G5"
fi

# ============================================================================
# G6. no node code under tests/ reads worker/jobs/schema.sql itself
# ============================================================================
NODE_RE="readFileSync\\(.*worker/jobs/schema\\.sql"
# g6_offenders <file>... — a .mjs/.js file that reads the path at all, or a .sh
# file that reads it from embedded node and never calls jobs_schema_render.
g6_offenders() {
  local f body
  for f in "$@"; do
    [ -f "$f" ] || continue
    body=$(grep -v -E '^\s*(#|//)' "$f")
    grep -q -E "$NODE_RE" <<< "$body" || continue
    case "$f" in
      *.sh) grep -q 'jobs_schema_render' <<< "$body" || echo "$f" ;;
      *) echo "$f" ;;
    esac
  done
}
G6=$(g6_offenders "$DIR"/tests/*.sh "$DIR"/tests/mc/*.sh "$DIR"/tests/lib/*.sh "$DIR"/tests/lib/*.mjs "$DIR"/tests/lib/*.js)
if [ -z "$G6" ]; then ok; else
  while IFS= read -r f; do bad "G6: ${f#"$DIR"/} reads worker/jobs/schema.sql from node — use jobsSchemaSql() from worker/jobs/test/lib/jobs-schema.js (or jobs_schema_render in a shell suite)"; done <<< "$G6"
fi
# The matcher over scratch files: two shapes it must flag, two it must not.
mkdir -p "$T/g6"
printf "db.exec(readFileSync(\`\${ROOT}%s.sql\`, 'utf8'));\n" "$SP" > "$T/g6/driver.mjs"
printf "#!/bin/bash\ncat > d.mjs <<'EOF'\ndb.exec(readFileSync(dir + '/%s.sql', 'utf8'));\nEOF\n" "$SP" > "$T/g6/embedded-test.sh"
printf "#!/bin/bash\n. lib/jobs-schema.sh && jobs_schema_render || exit 1\ncat > d.mjs <<'EOF'\ndb.exec(readFileSync(dir + '/%s.sql', 'utf8'));\nEOF\n" "$SP" > "$T/g6/rendered-test.sh"
printf "// db.exec(readFileSync(\`\${ROOT}%s.sql\`));\ndb.exec(jobsSchemaSql());\n" "$SP" > "$T/g6/fixed.mjs"
OFF=$(g6_offenders "$T"/g6/*)
[ "$OFF" = "$T/g6/driver.mjs"$'\n'"$T/g6/embedded-test.sh" ] && ok || bad "G6 matcher: want driver.mjs and embedded-test.sh flagged, got: ${OFF:-nothing}"

# ============================================================================
# D1. no statement twice in the composition
# ============================================================================
# dup_stmts <file> — every statement d1_schema_statements splits <file> into
# more than once, whitespace collapsed, one a line.
dup_stmts() { d1_schema_statements "$1" | tr '\n\t' '  ' | tr -s ' ' | tr '\0' '\n' | LC_ALL=C sort | uniq -d; }

REAL=$("$SB" --root "$DIR" --worker jobs); RC=$?
if [ "$RC" != 0 ] || [ -z "$REAL" ]; then bad "D1: bin/schema-build.sh --worker jobs failed (rc $RC)"
else
  DUP=$(dup_stmts <(printf '%s' "$REAL"))
  [ -z "$DUP" ] && ok || bad "D1: worker/jobs/schema.d holds a statement twice: $(head -n 3 <<<"$DUP")"
fi
S="$T/d1"
mkdir -p "$S/worker/jobs/schema.d"
printf '%s\n' "$FRAG" > "$S/worker/jobs/schema.d/0000-a.sql"
printf '%s\nCREATE TABLE IF NOT EXISTS fixture_b (id INTEGER);\n' "$FRAG" > "$S/worker/jobs/schema.d/0001-b.sql"
DUP=$(dup_stmts <("$SB" --root "$S" --worker jobs))
[ "$DUP" = "$FRAG" ] && ok || bad "D1: two fragments holding '$FRAG' must print it once as a duplicate, got: ${DUP:-nothing}"

echo "schema-compose-tests.bh-6005-1-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
