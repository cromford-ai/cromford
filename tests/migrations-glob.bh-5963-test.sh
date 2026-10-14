#!/bin/bash
# tests/migrations-glob.bh-5963-test.sh — the per-project migrations glob.
#
# example-org/project-6 keeps its SQL in prisma/sql/, and four readers looked only
# at the literal scripts/migrations/*.sql. The settings row
# migrations_glob.<project> (bin/lib/migrations-glob.sh) now tells them where a
# project's SQL lives. Two properties matter and both are driven here, through
# the real scripts where the scripts are runnable:
#   * no row: every reader behaves exactly as before (H1, S1, S4, M2, P5)
#   * hotfix-migrate and the conductor's proof gate fingerprint the same files,
#     so a proof is never stale or invisible because of the row (P1-P4, P6)
#   * row prisma/sql/*.sql: a PR that adds prisma/sql/0003_x.sql is found (H2,
#     S2, M1, Z1), and nothing outside <dir>/*.sql is (H3, G4)
# The settings worker is a stub jobs-client.sh that reads $ROWS/<key> (absent =
# no row, $ROWS/FAIL = outage) and logs every key it is asked to $CALLS.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/migrations-glob.bh-5963-test.sh
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "git missing — skipping"; exit 0; }

H="$T/h"; ROWS="$T/rows"; CALLS="$T/calls"
export ROWS CALLS
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/state" "$H/locks" "$ROWS" "$T/fakebin"
: > "$H/env/global.env"; : > "$CALLS"
# Stubs first: scratch_install_closure never overwrites a file already there.
cat > "$H/bin/jobs-client.sh" <<'EOF'
setting_get() {
  printf '%s\n' "$1" >> "$CALLS"
  [ -e "$ROWS/FAIL" ] && return 1
  [ -f "$ROWS/$1" ] || return 2
  cat "$ROWS/$1"
}
EOF
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/gh-token.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.log"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/gh-token.sh" "$H/bin/alert-line.sh"
for s in bin/hotfix-migrate.sh bin/check-migration-appliable.sh bin/scope-gate.sh bin/size-scope.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "cannot install the closure of $s"
done
LIB="$H/bin/lib/migrations-glob.sh"
[ -f "$LIB" ] && ok || bad "bin/lib/migrations-glob.sh is not in any reader's closure"

rows_reset() { scratch_rm "$ROWS"; mkdir -p "$ROWS"; : > "$CALLS"; }
row() { printf '%s' "$2" > "$ROWS/$1"; }

# mg <fn> <args...> — the helper in a fresh shell; stdout, then SRC=<MG_SRC>.
mg() {
  ( export HARNESS="$H"; . "$LIB" || exit 9
    "$@"; printf 'SRC=%s\n' "$MG_SRC" ) 2>"$T/mg.err"
}

# ── G1: no row → the default, from a real "no row" answer ───────────────────
rows_reset
OUT=$(mg mg_glob project-6-os)
[ "$OUT" = $'scripts/migrations/*.sql\nSRC=default' ] && ok || bad "G1: no row must print the default, got: $OUT"
grep -qx 'migrations_glob.project-6-os' "$CALLS" && ok || bad "G1: the row key must be asked for, calls: $(cat "$CALLS")"

# ── G2: a row (and the same row with blanks) wins; mg_dir drops /*.sql ──────
for v in 'prisma/sql/*.sql' '  prisma/sql/*.sql  '; do
  rows_reset; row migrations_glob.project-6-os "$v"
  OUT=$(mg mg_glob project-6-os)
  [ "$OUT" = $'prisma/sql/*.sql\nSRC=migrations_glob.project-6-os' ] && ok || bad "G2: row '$v' must be used, got: $OUT"
done
OUT=$(mg mg_dir project-6-os)
[ "$(head -1 <<<"$OUT")" = prisma/sql ] && ok || bad "G2: mg_dir must print prisma/sql, got: $OUT"

# ── G3: outage → the default, named on stderr, never silent ─────────────────
rows_reset; row migrations_glob.project-6-os 'prisma/sql/*.sql'; : > "$ROWS/FAIL"
OUT=$(mg mg_glob project-6-os)
[ "$OUT" = $'scripts/migrations/*.sql\nSRC=unreadable' ] && ok || bad "G3: an outage must fall back to the default, got: $OUT"
[ "$(grep -c 'migrations_glob.project-6-os unreadable' "$T/mg.err")" = 1 ] && ok || bad "G3: one stderr line must name the unreadable key: $(cat "$T/mg.err")"

# ── G4: anything that is not <dir>/*.sql in a plain relative path is refused ─
for v in 'prisma/sql/**/*.sql' '/etc/*.sql' '../x/*.sql' 'prisma/../../x/*.sql' 'prisma/sql/*.ts' \
         'prisma/sql' 'a b/*.sql' '$(id)/*.sql' '*.sql' 'prisma/sql/*.sql;rm' ' '; do
  rows_reset; row migrations_glob.project-6-os "$v"
  OUT=$(mg mg_glob project-6-os)
  [ "$OUT" = $'scripts/migrations/*.sql\nSRC=invalid' ] && ok || bad "G4: '$v' must be refused, got: $OUT"
  grep -q 'migrations_glob.project-6-os=' "$T/mg.err" && ok || bad "G4: '$v' must be named on stderr"
done

# ── G5: no project → no lookup at all ───────────────────────────────────────
for p in - ''; do
  rows_reset; row migrations_glob.- 'db/sql/*.sql'
  OUT=$(mg mg_glob "$p")
  [ "$OUT" = $'scripts/migrations/*.sql\nSRC=no-project' ] && ok || bad "G5: project '$p' must use the default, got: $OUT"
  [ -s "$CALLS" ] && bad "G5: project '$p' must not ask the worker: $(cat "$CALLS")" || ok
done

# ── G6: the ERE escape ──────────────────────────────────────────────────────
OUT=$(mg mg_dir_ere prisma/sql.v2)
[ "$(head -1 <<<"$OUT")" = 'prisma/sql\.v2' ] && ok || bad "G6: mg_dir_ere must escape dots, got: $OUT"

# ── G7: no client anywhere → the default, no-client ─────────────────────────
OUT=$( ( HARNESS="$T/nowhere"; H=""; . "$LIB"; mg_glob project-6-os; printf 'SRC=%s\n' "$MG_SRC" ) 2>/dev/null )
[ "$OUT" = $'scripts/migrations/*.sql\nSRC=no-client' ] && ok || bad "G7: no jobs client must use the default, got: $OUT"

# ============================================================================
# hotfix-migrate.sh, driven through hm_main against a scratch repo
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api repos/"*"/issues/"*"/comments"*) echo 4242; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
  "pr checks"*) printf 'build\tpass\t1s\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

mkwt() { # mkwt <dir> <added-path>...
  local d="$1" f; shift
  git init -q -b main "$d" 2>/dev/null
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name t
  echo readme > "$d/README.md"
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/p.git
  git -C "$d" checkout -q -b ticket/bh-9
  for f in "$@"; do
    mkdir -p "$d/$(dirname "$f")"
    printf 'CREATE TABLE "X%s" ("id" TEXT NOT NULL);\nALTER TABLE "X%s" ENABLE ROW LEVEL SECURITY;\n' "${#f}" "${#f}" > "$d/$f"
  done
  git -C "$d" add -A >/dev/null; git -C "$d" commit -qm sql
}
B="$H/builds/project-6-os-BH-9-202610100001"
run_hm() { # run_hm <worktree> -> prints rc
  scratch_rm "$B"; mkdir -p "$B"; scratch_rm "$H/locks"; mkdir -p "$H/locks"
  ( cd "$T" && PATH="$T/fakebin:$PATH" env HARNESS="$H" WT="$1" BASE=main SLUG=o/p \
      BRANCH=ticket/bh-9 PR_URL=https://github.com/o/p/pull/9 HOTFIX_CI_WAIT=2 \
      bash "$H/bin/hotfix-migrate.sh" project-6-os "$B" > "$T/hm.out" 2> "$T/hm.err" )
  echo $?
}
WTP="$T/wt-prisma"; mkwt "$WTP" prisma/sql/0003_x.sql

# ── H1: no row → today's answer: rc 4, "adds no migration files" ────────────
rows_reset
RC=$(run_hm "$WTP")
[ "$RC" = 4 ] && ok || bad "H1: no row must answer rc 4 (got $RC: $(head -c 300 "$T/hm.err"))"
grep -q 'adds no migration files' "$T/hm.err" && ok || bad "H1: stderr must say adds no migration files: $(cat "$T/hm.err")"
grep -q 'looked under: scripts/migrations/\*.sql prisma/migrations/manual/\*.sql; endpoint glob from default' "$T/hm.err" && ok || bad "H1: stderr must name the glob it used: $(cat "$T/hm.err")"

# ── H2: row prisma/sql/*.sql → the file is found and reaches the gate ───────
rows_reset; row migrations_glob.project-6-os 'prisma/sql/*.sql'
RC=$(run_hm "$WTP")
[ "$RC" = 5 ] && ok || bad "H2: with the row the SQL must be found and answer no-path rc 5 (got $RC: $(head -c 300 "$T/hm.err"))"
[ -f "$B/hotfix-gate.txt" ] && ok || bad "H2: the appliability gate must have run"
[ "$(jq -r '[.files[].path]|join(",")' "$B/hotfix-migrate.json" 2>/dev/null)" = prisma/sql/0003_x.sql ] && ok \
  || bad "H2: the ledger must carry exactly prisma/sql/0003_x.sql, got: $(cat "$B/hotfix-migrate.json" 2>/dev/null)"

# ── H3: a subdirectory or a non-.sql file under the dir is NOT found ───────
for f in prisma/sql/sub/0003_x.sql prisma/sql/0003_x.ts; do
  W="$T/wt-$(tr '/.' '--' <<<"$f")"; mkwt "$W" "$f"
  RC=$(run_hm "$W")
  [ "$RC" = 4 ] && ok || bad "H3: $f must not match prisma/sql/*.sql (got rc $RC)"
done

# ============================================================================
# the BH-370 contract: hotfix-migrate's FP and the conductor's FP agree
# ============================================================================
# mc_hotfix_proof (bin/lib/mc/classify.sh) computes its FP from the PR's files
# read; hotfix-migrate computes it from the worktree. A proof marker built from
# hotfix-migrate's ledger must read `hold` (its decision is no-path): FP BEFORE
# DECISION, so `stale` means the two sides counted different files, and `n/a`
# means the conductor saw no SQL at all and would merge it unapplied.
CLASSIFY="$DIR/bin/lib/mc/classify.sh"
proof() { # proof <worktree> <project> -> the conductor's word for the hm ledger
  local w="$1" f
  { printf '['; local sep=""
    while IFS= read -r f; do
      printf '%s{"filename":"%s","status":"added","sha":"%s"}' "$sep" "$f" "$(git -C "$w" rev-parse "HEAD:$f")"; sep=,
    done < <(git -C "$w" diff --name-only --diff-filter=A main...HEAD)
    printf ']'; } > "$T/pr-files.json"
  jq -n --arg b "<!-- hotfix-migrate-proof fp=$(jq -r .fp "$B/hotfix-migrate.json" 2>/dev/null) decision=$(jq -r .decision "$B/hotfix-migrate.json" 2>/dev/null) -->"$'\nbody' \
    '[{body:$b}]' > "$T/pr-comments.json"
  ( export HARNESS="$H"; . "$CLASSIFY" || exit 9
    mc_rest_var() { local -n _v="$1"; case "$4" in pulls/*) _v=$(cat "$T/pr-files.json") ;; *) _v=$(cat "$T/pr-comments.json") ;; esac; }
    mc_hotfix_proof o/p 9 hotfix "" "$2" ) 2>>"$T/proof.err"
}

# ── P1: row prisma/sql/*.sql, the PR adds prisma/sql/0003_x.sql ─────────────
rows_reset; row migrations_glob.project-6-os 'prisma/sql/*.sql'
RC=$(run_hm "$WTP")
[ "$RC" = 5 ] && ok || bad "P1: hotfix-migrate must find the SQL (got rc $RC)"
[ "$(proof "$WTP" project-6-os)" = hold ] && ok || bad "P1: the conductor must read the no-path proof as hold, got: $(proof "$WTP" project-6-os)"

# ── P2: prisma/sql plus prisma/migrations/manual → one FP on both sides ────
W2="$T/wt-p2"; mkwt "$W2" prisma/sql/0003_x.sql prisma/migrations/manual/0004_y.sql
RC=$(run_hm "$W2")
[ "$RC" = 5 ] && ok || bad "P2: hotfix-migrate must find both files (got rc $RC)"
[ "$(jq -r '[.files[].path]|sort|join(",")' "$B/hotfix-migrate.json" 2>/dev/null)" = prisma/migrations/manual/0004_y.sql,prisma/sql/0003_x.sql ] && ok \
  || bad "P2: the ledger must carry both files: $(cat "$B/hotfix-migrate.json" 2>/dev/null)"
[ "$(proof "$W2" project-6-os)" = hold ] && ok || bad "P2: the two FPs must match (hold), got: $(proof "$W2" project-6-os)"

# ── P3: the row never hides scripts/migrations from hotfix-migrate ──────────
W3="$T/wt-p3"; mkwt "$W3" scripts/migrations/0003_x.sql
RC=$(run_hm "$W3")
[ "$RC" = 5 ] && ok || bad "P3: scripts/migrations SQL must still be found with a row set (got rc $RC: $(head -c 300 "$T/hm.err"))"
[ "$(proof "$W3" project-6-os)" = hold ] && ok || bad "P3: the two FPs must match (hold), got: $(proof "$W3" project-6-os)"

# ── P4: a row in a subdirectory is not counted by either side ───────────────
W4="$T/wt-p4"; mkwt "$W4" prisma/sql/sub/0003_x.sql
RC=$(run_hm "$W4")
[ "$RC" = 4 ] && ok || bad "P4: hotfix-migrate must not count prisma/sql/sub (got rc $RC)"
[ "$(proof "$W4" project-6-os)" = n/a ] && ok || bad "P4: the conductor must not count prisma/sql/sub, got: $(proof "$W4" project-6-os)"

# ── P5: no row → both sides as before: no SQL found, n/a ────────────────────
rows_reset
RC=$(run_hm "$WTP")
[ "$RC" = 4 ] && ok || bad "P5: no row must answer rc 4 (got $RC)"
[ "$(proof "$WTP" project-6-os)" = n/a ] && ok || bad "P5: no row must read n/a, got: $(proof "$WTP" project-6-os)"
[ "$(proof "$WTP" -)" = n/a ] && ok || bad "P5: project - must read n/a"

# ── P6: an unreadable row fails closed at the conductor: missing, not n/a ───
row migrations_glob.project-6-os 'prisma/sql/*.sql'; : > "$ROWS/FAIL"
[ "$(proof "$WTP" project-6-os)" = missing ] && ok || bad "P6: an outage must read missing, got: $(proof "$WTP" project-6-os)"
rows_reset

# ============================================================================
# scope-gate.sh, run as a process against a real git diff
# ============================================================================
mkrepo() { # mkrepo <name> <added-path>... ; sets R (repo), SB (build dir), BASE0
  R="$T/sg-$1/repo"; SB="$T/sg-$1/b"; shift
  scratch_rm "${R%/repo}"; mkdir -p "$R" "$SB"
  git -C "$R" init -q . ; git -C "$R" config user.email t@example.com; git -C "$R" config user.name t
  echo one > "$R/README.md"; git -C "$R" add -A >/dev/null; git -C "$R" commit -qm base
  BASE0=$(git -C "$R" rev-parse HEAD)
  local f; for f in "$@"; do mkdir -p "$R/$(dirname "$f")"; echo x > "$R/$f"; done
  git -C "$R" add -A >/dev/null; git -C "$R" commit -qm work
  printf '{"project":"project-6-os","key":"TK-1"}\n' > "$SB/job.json"
}
gate() { G=$(env HARNESS="$H" "$H/bin/scope-gate.sh" "$SB" "$BASE0" "$R" 2>&1); GRC=$?; }
cls() { grep -E "^  \[[a-z]+\] $1\$" <<<"$G" | sed -E 's/^  \[([a-z]+)\].*/\1/'; }

# ── S1: no row → db/sql is foreign, verdict unplanned (today's answer) ──────
rows_reset; mkrepo s1 bin/a.sh db/sql/0003_x.sql
printf 'bin/a.sh\n' > "$SB/planned-files.txt"
gate
[ "$GRC" = 2 ] && ok || bad "S1: no row must be rc 2 unplanned (got $GRC: $G)"
[ "$(cls db/sql/0003_x.sql)" = foreign ] && ok || bad "S1: db/sql/0003_x.sql must be foreign with no row: $G"
grep -qx 'migrations_glob.project-6-os' "$CALLS" && ok || bad "S1: the gate must ask for the row of job.json's project: $(cat "$CALLS")"

# ── S2: row prisma/sql/*.sql, plan names the file positively → in-scope ─────
rows_reset; row migrations_glob.project-6-os 'prisma/sql/*.sql'
mkrepo s2 prisma/sql/0003_x.sql
printf 'prisma/sql/0003_x.sql\n' > "$SB/planned-files.txt"
printf 'Add `prisma/sql/0003_x.sql` with the new table.\n' > "$SB/plan.md"
gate
[ "$GRC" = 0 ] && ok || bad "S2: a planned prisma/sql file must be in-scope (got $GRC: $G)"

# ── S3: row db/sql/*.sql, same diff as S1 → protected ───────────────────────
rows_reset; row migrations_glob.project-6-os 'db/sql/*.sql'
mkrepo s3 bin/a.sh db/sql/0003_x.sql
printf 'bin/a.sh\n' > "$SB/planned-files.txt"
gate
[ "$GRC" = 1 ] && ok || bad "S3: an unplanned file in the configured dir must be rc 1 protected (got $GRC: $G)"
grep -q '^SCOPE_PROTECTED: db/sql/0003_x.sql$' <<<"$G" && ok || bad "S3: SCOPE_PROTECTED must name db/sql/0003_x.sql: $G"

# ── S4: row db/sql/*.sql never un-protects scripts/migrations ───────────────
mkrepo s4 bin/a.sh scripts/migrations/0003_x.sql
printf 'bin/a.sh\n' > "$SB/planned-files.txt"
gate
[ "$GRC" = 1 ] && ok || bad "S4: an unplanned scripts/migrations file must stay protected (got $GRC: $G)"

# ── S5: a planned migration in the configured dir is the plan's territory,
#        but a "do not touch" sentence does not plan it ──────────────────────
mkrepo s5 db/sql/0003_x.sql db/sql/0004_y.sql
printf 'db/sql/0003_x.sql\n' > "$SB/planned-files.txt"
printf 'Add `db/sql/0003_x.sql` for the new table.\n' > "$SB/plan.md"
gate
[ "$GRC" = 2 ] && ok || bad "S5a: a planned db/sql migration makes a sibling unplanned, not protected (got $GRC: $G)"
printf 'Do not touch `db/sql/0003_x.sql` here.\n' > "$SB/plan.md"
gate
[ "$GRC" = 1 ] && ok || bad "S5b: a db/sql file named only in a non-goal must not count as planned (got $GRC: $G)"

# ── S6: no job.json → no lookup, today's answer ─────────────────────────────
rows_reset; row migrations_glob.project-6-os 'db/sql/*.sql'
mkrepo s6 bin/a.sh db/sql/0003_x.sql; rm -f "$SB/job.json"
printf 'bin/a.sh\n' > "$SB/planned-files.txt"
gate
[ "$GRC" = 2 ] && ok || bad "S6: no job.json must use the default (got $GRC: $G)"
[ -s "$CALLS" ] && bad "S6: no project must not ask the worker: $(cat "$CALLS")" || ok

# ============================================================================
# the MIGF alert in the reviewed-merge sweep: its block, extracted verbatim
# ============================================================================
SWEEP="$DIR/bin/merge-sweep.sh"
awk '/^    if grep -q "MIGRATION GATE" "\$D\/RESULT"; then$/ {on=1} on {print} on && /^    fi$/ {exit}' \
  "$SWEEP" > "$T/migf-block.sh"
grep -q 'mg_first_named' "$T/migf-block.sh" && ok || bad "M0: the sweep's MIGF block must call mg_first_named: $(cat "$T/migf-block.sh")"
scratch_install_closure bin/merge-sweep.sh "$T/ms" > "$T/ms.list" 2>/dev/null
grep -qx 'bin/lib/migrations-glob.sh' "$T/ms.list" && ok || bad "M0: the sweep must source bin/lib/migrations-glob.sh"

migf() { # migf <project> -> the alert text the block sends
  : > "$T/alerts.log"
  ( export HARNESS="$H"; H="$H"; D="$T/rec"; PR=https://github.com/o/p/pull/9; PROJ="$1"
    . "$LIB"; . "$T/migf-block.sh" ) >/dev/null 2>&1
  cat "$T/alerts.log"
}
mkdir -p "$T/rec"
printf 'PR_CREATED x\nMIGRATION GATE flagged\n' > "$T/rec/RESULT"
printf 'FLAGGED scripts/migrations/0002_old.sql\nFLAGGED prisma/sql/0003_x.sql\nFLAGGED db/sql/7.sql\n' > "$T/rec/migration-gate.txt"

# ── M1: the configured dir is the one named ─────────────────────────────────
rows_reset; row migrations_glob.project-6-os 'prisma/sql/*.sql'
grep -q 'apply prisma/sql/0003_x.sql via' <<<"$(migf project-6-os)" && ok || bad "M1: the alert must name prisma/sql/0003_x.sql: $(cat "$T/alerts.log")"
OUT=$(mg mg_first_named project-6-os "$T/rec/migration-gate.txt" "$T/rec/RESULT")
[ "$(head -1 <<<"$OUT")" = prisma/sql/0003_x.sql ] && ok || bad "M1: mg_first_named must print prisma/sql/0003_x.sql, got: $OUT"
rows_reset; row migrations_glob.project-6-os 'db/sql/*.sql'
grep -q 'apply db/sql/7.sql via' <<<"$(migf project-6-os)" && ok || bad "M1: the alert must name db/sql/7.sql: $(cat "$T/alerts.log")"

# ── M2: no row, or the unresolved `-` bucket → scripts/migrations as today ──
rows_reset
grep -q 'apply scripts/migrations/0002_old.sql via' <<<"$(migf project-6-os)" && ok || bad "M2: no row must name the scripts/migrations file: $(cat "$T/alerts.log")"
row migrations_glob.- 'prisma/sql/*.sql'
grep -q 'apply scripts/migrations/0002_old.sql via' <<<"$(migf -)" && ok || bad "M2: project - must name the scripts/migrations file: $(cat "$T/alerts.log")"

# ============================================================================
# size-scope.sh: prisma/sql already counts as product code (plan A2)
# ============================================================================
for f in prisma/sql/0003_x.sql scripts/migrations/0003_x.sql; do
  "$H/bin/size-scope.sh" --is-product "$f" && ok || bad "Z1: $f must count as product code"
done

# ============================================================================
# the seed row, applied from the committed schema the way harness-sync applies it
# ============================================================================
if command -v python3 >/dev/null 2>&1; then
  python3 -I - "$DIR/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/d1.err" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
PY
  V=$(python3 -I -c 'import sqlite3, sys; r = sqlite3.connect(sys.argv[1]).execute("SELECT value FROM settings WHERE key=?", ("migrations_glob.project-6-os",)).fetchone(); print(r[0] if r else "")' "$T/hub.sqlite" 2>>"$T/d1.err")
  [ "$V" = 'prisma/sql/*.sql' ] && ok || bad "D1: worker/jobs/schema.sql must seed migrations_glob.project-6-os=prisma/sql/*.sql (got '$V'; $(head -c 300 "$T/d1.err"))"
else
  echo "SKIP: D1 needs python3"
fi

echo "migrations-glob: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
