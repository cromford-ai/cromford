#!/bin/bash
# tests/checks-false-positives.bh-9436-test.sh — the mined checks apply their
# own known-false-positive lists, and every skip stays visible as a NOTE.
#
# THE DEFECT. Three checks under checks/ parked PRs on lines their own WHY.md
# already called false positives: a cron, webhook, admin or test-fake lookup
# by id (client-id-trust), a Prisma `$queryRaw<T>` tagged call with a generic
# and SQL in a .md, e2e or seed file (sql-command-injection), and a log line
# that prints a secret NAME and no value (secret-literals). The four sampled
# lines (cromford#9372, project-6#3074, project-4#2205, project-3#649) gave
# 6 CHECK-HITs on the merge base.
#
# Every case drives the REAL runner, bin/checks-run.sh, the one entry point
# bin/merge-sweep.sh, mc_iron_law_scan and the review gates reach the checks
# through (D2).
#
# Sections:
#   A  the 4 sampled lines, inline: 0 CHECK-HIT
#   R  runner NOTE protocol on a stub catalog (rc, order, summary)
#   C  client-id-trust decision table + fixtures
#   S  sql-command-injection decision table + fixtures
#   K  secret-literals name-only decision table + fixtures
#   P  the review prompt block shows CHECK-NOTE lines on rc 0
#   L  lint of each checks/<slug>/exclusions.tsv and WHY.md
#   M  mutation: a check copied without its exclusions.tsv hits again (D1)
#
# Run from anywhere (exit 0 = pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RUN="$DIR/bin/checks-run.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The three list files this ticket adds, by rooted path (D41).
LIST_CID="$DIR/checks/client-id-trust/exclusions.tsv"
LIST_SQL="$DIR/checks/sql-command-injection/exclusions.tsv"
LIST_SEC="$DIR/checks/secret-literals/exclusions.tsv"

# mkdiff <path> <added line>... — one unified diff on stdout.
mkdiff() {
  local p=$1; shift
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,0 +1,%d @@\n' "$p" "$p" "$p" "$p" "$#"
  local l; for l in "$@"; do printf '+%s\n' "$l"; done
}
N=0
# one <path> <line> — run the runner on a one-line diff; sets OUT and RC.
one() {
  N=$((N+1)); mkdiff "$1" "$2" > "$T/one-$N.diff"
  OUT=$("$RUN" "$T/one-$N.diff" 2>&1); RC=$?
}
has() { # has <prefix> — some line of OUT starts with the literal prefix
  awk -v p="$1" 'index($0, p) == 1 { f = 1 } END { exit !f }' <<<"$OUT"
}
# expect <slug> <HIT|NOTE|silent> <path> <label>   (reads OUT)
expect() {
  local s=$1 want=$2 p=$3 lab=$4 h=0 n=0
  has "CHECK-HIT $s $p:" && h=1
  has "CHECK-NOTE $s $p:" && n=1
  grep -q '^CHECK-ERROR' <<<"$OUT" && { bad "$lab: CHECK-ERROR: $OUT"; return; }
  case "$want" in
    HIT)    [ "$h" = 1 ] && ok || bad "$lab: expected CHECK-HIT $s, got: $OUT" ;;
    NOTE)   [ "$h" = 0 ] && [ "$n" = 1 ] && ok || bad "$lab: expected CHECK-NOTE $s and no hit, got: $OUT" ;;
    silent) [ "$h" = 0 ] && [ "$n" = 0 ] && ok || bad "$lab: expected silence from $s, got: $OUT" ;;
  esac
}
nhits() { grep -c '^CHECK-HIT ' <<<"$1"; }

# ── A. the 4 sampled false positives, inline (red on the merge base) ────────
{
  mkdiff bin/selfhost-install.sh \
    '    echo "SECRET ANTHROPIC_API_KEY_$(printf '"'"'%s'"'"' "$p" | tr '"'"'a-z-'"'"' '"'"'A-Z_'"'"') needed-by=claude_auth.$p where=fly-secret"'
  mkdiff src/lib/search/web-search.ts \
    '    const [reserved] = await tx.$queryRaw<{ ok: boolean }[]>`SELECT public.mk_web_search_spend_reserve(${day}::date, ${price}::numeric, ${globalCap}::numeric) AS ok`;'
  mkdiff src/server/fakes/prisma.ts \
    '  findUnique: ({ where }: Args) => rows.find((r) => r.id === where.id) ?? findBy({ where: { id: where.id } }),'
  mkdiff 'app/api/admin/members/[id]/route.ts' \
    '  const member = await prisma.member.findUnique({where:{id:memberId}})'
} > "$T/samples.diff"
OUT=$("$RUN" "$T/samples.diff" 2>&1); RC=$?
[ "$(nhits "$OUT")" = 0 ] && ok || bad "A: the 4 sampled lines still hit: $(grep '^CHECK-HIT ' <<<"$OUT")"
[ "$RC" = 0 ] && ok || bad "A: runner rc on the 4 samples was $RC, expected 0"
[ "$(grep -c '^CHECK-NOTE ' <<<"$OUT")" = 3 ] && ok \
  || bad "A: expected 3 CHECK-NOTE lines (2 client-id-trust, 1 secret-literals), got: $OUT"

# ── R. runner NOTE protocol, on a stub catalog ──────────────────────────────
mkdir -p "$T/stub-a/stub" "$T/stub-b/stub"
printf '#!/bin/bash\nprintf "NOTE\\tp:1\\twhy\\n"\nexit 0\n' > "$T/stub-a/stub/check.sh"
printf '#!/bin/bash\nprintf "NOTE\\tp:1\\twhy\\n"\nprintf "q:2\\treal\\n"\nexit 1\n' > "$T/stub-b/stub/check.sh"
chmod +x "$T/stub-a/stub/check.sh" "$T/stub-b/stub/check.sh"
mkdiff x.ts 'const a = 1' > "$T/r.diff"
OUT=$(CHECKS_DIR="$T/stub-a" "$RUN" "$T/r.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R: notes only must be rc 0, got $RC: $OUT"
has "CHECK-NOTE stub p:1 why" && ok || bad "R: no CHECK-NOTE line for the stub note: $OUT"
[ "$(nhits "$OUT")" = 0 ] && ok || bad "R: a NOTE was counted as a hit: $OUT"
SUM=$(tail -1 <<<"$OUT")
grep -q '^CHECKS: clean (' <<<"$SUM" && ok || bad "R: notes-only summary must start 'CHECKS: clean (', got: $SUM"
grep -q '1 note(s)' <<<"$SUM" && ok || bad "R: notes-only summary must count '1 note(s)', got: $SUM"
OUT=$(CHECKS_DIR="$T/stub-b" "$RUN" "$T/r.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R: note plus hit must be rc 1, got $RC: $OUT"
[ "$(nhits "$OUT")" = 1 ] && ok || bad "R: expected exactly 1 CHECK-HIT, got: $OUT"
has "CHECK-HIT stub q:2 real" && ok || bad "R: hit line missing: $OUT"
HL=$(grep -n '^CHECK-HIT ' <<<"$OUT" | head -1 | cut -d: -f1)
NL=$(grep -n '^CHECK-NOTE ' <<<"$OUT" | head -1 | cut -d: -f1)
[ -n "$HL" ] && [ -n "$NL" ] && [ "$NL" -gt "$HL" ] && ok || bad "R: CHECK-NOTE must come after CHECK-HIT: $OUT"
grep -q '^CHECKS: 1 hit(s)' <<<"$(tail -1 <<<"$OUT")" && ok || bad "R: summary must say '1 hit(s)': $OUT"

# ── C. client-id-trust ──────────────────────────────────────────────────────
S=client-id-trust; L='  const x = await prisma.t.findUnique({ where: { id } })'
while IFS='|' read -r WANT P LINE; do
  [ -n "$WANT" ] || continue
  [ -n "$LINE" ] || LINE=$L
  one "$P" "$LINE"; expect "$S" "$WANT" "$P" "C $P"
done <<EOF
NOTE|app/api/cron/sync/route.ts|
NOTE|src/app/api/webhooks/stripe/route.ts|
NOTE|src/server/fakes/prisma.ts|
NOTE|src/server/clerk/fake.ts|
NOTE|src/server/db/prisma.fake.ts|
NOTE|src/server/__fixtures__/rows.ts|
NOTE|app/api/admin/members/[id]/route.ts|  const m = await prisma.member.findUnique({where:{id:memberId}})
NOTE|app/(admin)/api/members/route.ts|
HIT|app/api/crons/sync/route.ts|
HIT|app/api/webhook/route.ts|
HIT|app/api/invoices/[id]/route.ts|  const inv = await prisma.invoice.update({ where: { id }, data })
HIT|app/api/fakeNews/[id]/route.ts|
HIT|app/api/administrators/[id]/route.ts|
HIT|src/server/unfaked.ts|
silent|app/api/cron/x/route.ts|  const x = await prisma.t.findFirst({ where: { id, orgId } })
EOF
for F in fp-cron-route fp-webhook-route fp-test-fake fp-admin-route; do
  OUT=$("$RUN" "$DIR/checks/$S/fixtures/$F.bh-9436.diff" 2>&1)
  [ "$(nhits "$OUT")" = 0 ] && ok || bad "C $F: still hits: $OUT"
  grep -q "^CHECK-NOTE $S " <<<"$OUT" && ok || bad "C $F: no CHECK-NOTE $S: $OUT"
  grep -q "excluded by checks/$S/exclusions.tsv row [0-9]" <<<"$OUT" && ok || bad "C $F: note does not name its list row: $OUT"
done
for F in "fixtures/tp-tenant-write.bh-9436.diff" "fixtures/violation.diff"; do
  OUT=$("$RUN" "$DIR/checks/$S/$F" 2>&1); RC=$?
  grep -q "^CHECK-HIT $S " <<<"$OUT" && [ "$RC" = 1 ] && ok || bad "C $F: must hit (rc 1), got rc $RC: $OUT"
done

# ── S. sql-command-injection ────────────────────────────────────────────────
S=sql-command-injection
while IFS='|' read -r WANT P LINE; do
  [ -n "$WANT" ] || continue
  one "$P" "$LINE"; expect "$S" "$WANT" "$P" "S $P: $LINE"
done <<'EOF'
silent|src/lib/search/web-search.ts|    const [reserved] = await tx.$queryRaw<{ ok: boolean }[]>`SELECT f(${day}::date) AS ok`;
silent|src/db.ts|  const rows = await sql`SELECT * FROM t WHERE id = ${id}`
silent|src/db.ts|  const frag = Prisma.sql`WHERE id = ${id}`
silent|src/db.ts|  const rows = await sql<Row[]>`SELECT * FROM t WHERE id = ${id}`
silent|src/db.ts|  const rows = await db.sql `SELECT * FROM t WHERE id = ${id}`
silent|docs/queries.md|Run `SELECT * FROM t WHERE id = ${id}` to check.
silent|e2e/helpers/db.ts|  await db.exec(`DELETE FROM users WHERE email = ${email}`)
silent|prisma/seed.ts|  await db.$executeRawUnsafe(`INSERT INTO t VALUES (${v})`)
silent|prisma/seeds/demo.ts|  await db.query(`SELECT * FROM t WHERE id = ${id}`)
silent|scripts/seed-demo.ts|  await db.query(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/db.ts|  const rows = await db.query(`SELECT * FROM users WHERE email = '${req.query.email}'`)
HIT|src/db.ts|  const rows = await sql.unsafe(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/db.ts|  const rows = await Prisma.raw(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/db.ts|  const rows = await mysql`SELECT * FROM t WHERE id = ${id}`
HIT|src/db.ts|  x = sql`SELECT 1`; q(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/db.ts|  const f = () => `SELECT * FROM t WHERE id = ${id}`
HIT|src/seedling.ts|  await db.query(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/readme.md.ts|  await db.query(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/e2ex/db.ts|  await db.query(`SELECT * FROM t WHERE id = ${id}`)
HIT|src/db.ts|  const rows = await prisma.$queryRawUnsafe(q)
EOF
for F in fp-queryraw-generic fp-md-e2e-seed; do
  OUT=$("$RUN" "$DIR/checks/$S/fixtures/$F.bh-9436.diff" 2>&1); RC=$?
  [ "$(nhits "$OUT")" = 0 ] && [ "$RC" = 0 ] && ok || bad "S $F: must not hit (rc 0), got rc $RC: $OUT"
done
for F in "fixtures/tp-string-built.bh-9436.diff" "fixtures/violation.diff"; do
  OUT=$("$RUN" "$DIR/checks/$S/$F" 2>&1); RC=$?
  grep -q "^CHECK-HIT $S " <<<"$OUT" && [ "$RC" = 1 ] && ok || bad "S $F: must hit (rc 1), got rc $RC: $OUT"
done

# ── K. secret-literals name-only rule ───────────────────────────────────────
S=secret-literals
while IFS='|' read -r WANT P LINE; do
  [ -n "$WANT" ] || continue
  one "$P" "$LINE"; expect "$S" "$WANT" "$P" "K $LINE"
done <<'EOF'
NOTE|bin/a.sh|    echo "SECRET ANTHROPIC_API_KEY_$(printf '%s' "$p" ¦ tr 'a-z-' 'A-Z_') needed-by=claude_auth.$p where=fly-secret"
NOTE|bin/a.sh|  echo "set ANTHROPIC_API_KEY in env/global.env"
NOTE|src/a.ts|  console.error("CRON_SECRET is not set")
NOTE|src/a.ts|  console.error("CRON_SECRET missing for", project)
NOTE|src/a.ts|  logger.warn('GH_TOKEN expired; refresh it')
HIT|src/a.ts|console.log("cron auth header", process.env.CRON_SECRET)
HIT|bin/a.sh|  echo "token: $GH_TOKEN"
HIT|bin/a.sh|  echo "using ${API_KEY}"
HIT|bin/a.sh|  echo "using ${!SECRET_VAR}"
HIT|bin/a.sh|  echo "$(printenv GH_TOKEN)"
HIT|bin/a.sh|  echo "k=`cat $HOME/.TOKEN`"
HIT|src/a.ts|  console.log(`key ${API_KEY}`)
HIT|src/a.ts|  console.log(`key ${ cfg.API_KEY }`)
HIT|src/a.ts|  console.log("API_KEY", key)
HIT|src/a.ts|  console.log("API_KEY:", key)
HIT|src/a.ts|  console.log("SECRET=" + s)
HIT|src/a.ts|  console.log(API_TOKEN)
HIT|bin/a.sh|  echo "TOKEN=$t"
HIT|bin/a.sh|  echo "TOKEN=$(cat tokenfile)"
HIT|bin/a.sh|  echo "TOKEN" "$t"
HIT|src/a.ts|const FALLBACK_KEY = "sk-ant-api03-FIXTURE-NOT-A-REAL-KEY"
silent|src/a.ts|console.error(`[TOKEN-ALLOWANCE-RESET] pool refill failed:`, message)
EOF
# The table above writes the one pipe of the #9372 line as "¦" so the row
# splits on "|"; drive the verbatim line through its committed fixture too.
F="$DIR/checks/$S/fixtures/fp-name-only.bh-9436.diff"
grep -qF "\"\$p\" | tr 'a-z-'" "$F" && ok || bad "K: fp-name-only fixture is not the verbatim #9372 line"
OUT=$("$RUN" "$F" 2>&1); RC=$?
[ "$(nhits "$OUT")" = 0 ] && [ "$RC" = 0 ] && ok || bad "K fp-name-only: must not hit (rc 0), got rc $RC: $OUT"
[ "$(grep -c "^CHECK-NOTE $S " <<<"$OUT")" = 1 ] && ok || bad "K fp-name-only: expected 1 CHECK-NOTE $S: $OUT"
for F in "fixtures/tp-literal-and-printed-value.bh-9436.diff" "fixtures/violation.diff"; do
  OUT=$("$RUN" "$DIR/checks/$S/$F" 2>&1); RC=$?
  grep -q "^CHECK-HIT $S " <<<"$OUT" && [ "$RC" = 1 ] && ok || bad "K $F: must hit (rc 1), got rc $RC: $OUT"
done
OUT=$("$RUN" "$DIR/checks/$S/fixtures/tp-literal-and-printed-value.bh-9436.diff" 2>&1)
[ "$(grep -c "^CHECK-HIT $S " <<<"$OUT")" = 2 ] && ok || bad "K tp: both the literal and the printed value must hit: $OUT"

# ── P. the review prompt block shows the notes on rc 0 ──────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^  case "\$CHECKS_RC" in/{f=1} f{print} f && /^  esac/{exit}' "$RB_ALL" > "$T/checks-case.sh"
[ -s "$T/checks-case.sh" ] && ok || bad "P: could not extract the MINED CHECKS case block"
BUILD="$T/pbuild"; mkdir -p "$BUILD"
{ echo "CHECK-NOTE client-id-trust app/api/cron/x/route.ts:3 data access scoped only by id [excluded by checks/client-id-trust/exclusions.tsv row 9: cron]"
  echo "CHECKS: clean (5 check(s), 3 added line(s) scanned) — 1 note(s): client-id-trust(x1)"; } > "$BUILD/checks.txt"
CHECKS_RC=0; CHECKS_NOTE=""
# shellcheck disable=SC1090
. "$T/checks-case.sh"
grep -q '^MINED CHECKS: clean' <<<"$CHECKS_NOTE" && ok || bad "P: rc 0 arm lost its clean line: $CHECKS_NOTE"
grep -qF "CHECK-NOTE client-id-trust app/api/cron/x/route.ts:3" <<<"$CHECKS_NOTE" && ok \
  || bad "P: rc 0 arm does not show the CHECK-NOTE line to the reviewer: $CHECKS_NOTE"
grep -q 'exclusions.tsv' <<<"$(grep -v '^CHECK-NOTE' <<<"$CHECKS_NOTE")" && ok \
  || bad "P: the note block has no lead line naming exclusions.tsv: $CHECKS_NOTE"
echo "CHECKS: clean (5 check(s), 3 added line(s) scanned)" > "$BUILD/checks.txt"
CHECKS_NOTE=""; . "$T/checks-case.sh"
[ "$(grep -c . <<<"$CHECKS_NOTE")" = 1 ] && ok || bad "P: with no notes the rc 0 arm must stay one line: $CHECKS_NOTE"

# ── L. list lint ────────────────────────────────────────────────────────────
for LST in "$LIST_CID" "$LIST_SQL" "$LIST_SEC"; do
  SL=$(basename "$(dirname "$LST")")
  [ -f "$LST" ] && ok || { bad "L: $LST missing"; continue; }
  case "$SL" in
    client-id-trust) KINDS="path" ;; sql-command-injection) KINDS="path|tag" ;; secret-literals) KINDS="rule" ;;
  esac
  ROWS=0; LN=0
  while IFS= read -r ROW || [ -n "$ROW" ]; do
    LN=$((LN+1))
    case "$ROW" in ''|'#'*) continue ;; esac
    ROWS=$((ROWS+1))
    NF=$(awk -F'\t' '{ print NF }' <<<"$ROW")
    [ "$NF" = 4 ] && ok || { bad "L: $SL row $LN has $NF TAB fields, expected 4: $ROW"; continue; }
    K=$(cut -f1 <<<"$ROW"); A=$(cut -f2 <<<"$ROW"); PAT=$(cut -f3 <<<"$ROW"); W=$(cut -f4 <<<"$ROW")
    grep -qxE "$KINDS" <<<"$K" && ok || bad "L: $SL row $LN kind '$K' is not one of $KINDS"
    grep -qxE 'note|skip' <<<"$A" && ok || bad "L: $SL row $LN action '$A' is not note or skip"
    [ -n "$PAT" ] && [ -n "$W" ] && ok || bad "L: $SL row $LN has an empty pattern or why"
    if [ "$K" = path ]; then
      awk -v r="$PAT" 'BEGIN { if ("x" ~ r) {} }' </dev/null 2>/dev/null && ok || bad "L: $SL row $LN pattern does not compile in awk: $PAT"
      grep -q '{[0-9]' <<<"$PAT" && bad "L: $SL row $LN uses an interval quantifier (mawk): $PAT" || ok
    fi
    [ "$K" = rule ] && { [ "$PAT" = name-only ] && ok || bad "L: $SL row $LN names an unknown rule '$PAT'"; }
  done < "$LST"
  [ "$ROWS" -gt 0 ] && ok || bad "L: $SL list has no rows"
  grep -q 'exclusions.tsv' "$DIR/checks/$SL/WHY.md" && ok || bad "L: checks/$SL/WHY.md does not name exclusions.tsv"
done
grep -q 'exclusions.tsv' "$DIR/checks/README.md" && ok || bad "L: checks/README.md layout does not name exclusions.tsv"
grep -q 'NOTE' "$DIR/checks/README.md" && ok || bad "L: checks/README.md contract does not describe the NOTE line"

# ── M. mutation: the list, not a code literal, carries each exclusion (D1) ──
for PAIR in "client-id-trust fp-cron-route" "client-id-trust fp-admin-route" \
            "sql-command-injection fp-md-e2e-seed" "secret-literals fp-name-only"; do
  set -- $PAIR
  rm -rf "$T/mcat"; mkdir -p "$T/mcat"
  cp -r "$DIR/checks/$1" "$T/mcat/$1"
  OUT=$(CHECKS_DIR="$T/mcat" "$RUN" "$DIR/checks/$1/fixtures/$2.bh-9436.diff" 2>&1)
  [ "$(nhits "$OUT")" = 0 ] && ok || bad "M: $1 with its list still hits $2: $OUT"
  rm -f "$T/mcat/$1/exclusions.tsv"
  OUT=$(CHECKS_DIR="$T/mcat" "$RUN" "$DIR/checks/$1/fixtures/$2.bh-9436.diff" 2>&1); RC=$?
  grep -q "^CHECK-HIT $1 " <<<"$OUT" && [ "$RC" = 1 ] && ok || bad "M: $1 without exclusions.tsv must hit $2 again (strict form), got rc $RC: $OUT"
  # An invalid row is ignored the same way: strict, more hits, never fewer.
  printf 'path\tnote\n# a comment\nbogus\tnote\t.*\twhy\nrule\tmaybe\tname-only\twhy\ntag\tskip\n' > "$T/mcat/$1/exclusions.tsv"
  OUT=$(CHECKS_DIR="$T/mcat" "$RUN" "$DIR/checks/$1/fixtures/$2.bh-9436.diff" 2>&1)
  grep -q "^CHECK-HIT $1 " <<<"$OUT" && ok || bad "M: $1 with only invalid rows must stay strict on $2: $OUT"
done

# The built-in $queryRaw/$executeRaw exclusion takes the <...> generic on its
# own: a missing list must not re-open the project-6#3074 false positive.
rm -rf "$T/mcat"; mkdir -p "$T/mcat"
cp -r "$DIR/checks/sql-command-injection" "$T/mcat/"; rm -f "$T/mcat/sql-command-injection/exclusions.tsv"
OUT=$(CHECKS_DIR="$T/mcat" "$RUN" "$DIR/checks/sql-command-injection/fixtures/fp-queryraw-generic.bh-9436.diff" 2>&1); RC=$?
[ "$(nhits "$OUT")" = 0 ] && [ "$RC" = 0 ] && ok || bad "M: \$queryRaw<T> must stay silent with no list (built-in exclusion), got rc $RC: $OUT"

echo "checks-false-positives.bh-9436: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
