#!/bin/bash
# tests/migration-gate.bh-1355-test.sh — BH-1355, the migration gate that said
# `none` on a PR carrying a migration.
#
# project-5 PR #3082 (TK-3071) ADDED
# `prisma/migrations/manual/2026-09-22-TK-3071-analysis-config-in-flight.sql`
# and changed `prisma/schema/misc.prisma`, and its Evidence block said
# `migration gate: none`. The whole file detection was one pathspec —
# `scripts/migrations/*.sql` — so anything under `prisma/` was invisible and the
# gate told a reviewer there was no schema in a PR that shipped schema.
#
# THE NEGATIVES ARE HALF THE POINT. A gate that starts reporting `present` on
# every PR is as useless as one that never does, so each widening case is pinned
# beside the case that must STILL say `none`, and the existing
# `scripts/migrations` vocabulary (`clean` / `flagged` / `gate-failed`) is pinned
# unchanged — the classifier's scope did not move, only what the EVIDENCE names.
#
# Sections:
#   A  bin/lib/migration-files.sh against a real git repo (cases 1-4)
#   B  the `# >>> migration gate` block out of bin/run-build.sh, run verbatim
#      against that repo with a stub classifier (case 5)
#   C  the `# >>> gates json` block out of bin/run-build.sh (cases 6-8)
#   D  bin/evidence-summary.sh's rendered row and --json (cases 9-11)
#
# Run from anywhere: tests/migration-gate.bh-1355-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The pipeline as ONE text, whatever state the BH-478 stage split is in: the two
# blocks below are extracted by their markers, and a marker that has moved into
# a bin/lib/rb/ module must still read in its original place.
# shellcheck source=/dev/null
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "migration-gate.bh-1355: jq is required"; exit 1; }

# ============================================================================
# fixture repo — one base commit, one branch per case
# ============================================================================
R="$T/repo"; mkdir -p "$R"
G() { git -C "$R" -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false "$@"; }
G init -q -b main >/dev/null 2>&1
mkdir -p "$R/prisma/sql" "$R/prisma/schema" "$R/scripts/migrations" "$R/src"
printf 'select 1;\n'      > "$R/prisma/sql/seed.sql"
printf 'model A {}\n'     > "$R/prisma/schema/misc.prisma"
printf 'datasource db {}\n' > "$R/prisma/schema.prisma"
printf 'export const x=1\n' > "$R/src/x.ts"
G add -A >/dev/null 2>&1; G commit -qm base >/dev/null 2>&1

MANUAL=prisma/migrations/manual/2026-09-22-x.sql

# branch <name> — a fresh branch off main; caller writes files, then `commit`
branch() { G checkout -q -B "$1" main >/dev/null 2>&1; }
commit() { G add -A >/dev/null 2>&1; G commit -qm "$1" >/dev/null 2>&1; }

branch b-manual
mkdir -p "$R/prisma/migrations/manual"
printf 'ALTER TABLE "AnalysisConfig" ADD COLUMN IF NOT EXISTS "inFlight" BOOLEAN;\n' > "$R/$MANUAL"
commit "the manual migration"

branch b-prisma-sql
printf 'select 2;\n' >> "$R/prisma/sql/seed.sql"
commit "seed sql"

branch b-prisma-sql-top
printf 'select 3;\n' > "$R/prisma/backfill.sql"
commit "a .sql directly under prisma/"

branch b-schema-dir
printf 'model B {}\n' >> "$R/prisma/schema/misc.prisma"
commit "schema dir"

branch b-schema-single
printf '// generator\n' >> "$R/prisma/schema.prisma"
commit "single-file schema"

branch b-none
printf 'export const y=2\n' >> "$R/src/x.ts"
commit "no migration"

branch b-scripts
printf 'ALTER TABLE t ADD COLUMN c text;\n' > "$R/scripts/migrations/2026-09-22-x.sql"
commit "a scripts/migrations file"

branch b-rename
G checkout -q -B b-rename main >/dev/null 2>&1
mkdir -p "$R/prisma/migrations/20260101000000_init"
printf 'CREATE TABLE t (id text);\n' > "$R/prisma/migrations/20260101000000_init/migration.sql"
commit "a prisma migration folder"

G checkout -q main >/dev/null 2>&1

# ============================================================================
# A. bin/lib/migration-files.sh (cases 1-4)
# ============================================================================
LIB="$DIR/bin/lib/migration-files.sh"
if [ -r "$LIB" ]; then
  ok
  # shellcheck source=/dev/null
  . "$LIB" || bad "A: bin/lib/migration-files.sh could not be sourced"
else
  bad "A: bin/lib/migration-files.sh is missing"
fi

# changed <branch> — the lib's file list for that branch, as one space-joined line
changed() {
  G checkout -q "$1" >/dev/null 2>&1
  migration_files_changed main "$R" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}
added() {
  G checkout -q "$1" >/dev/null 2>&1
  migration_sql_added main "$R" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

# case 1 — the ticket's own branch: ONLY prisma/migrations/manual/*.sql
V=$(changed b-manual)
[ "$V" = "$MANUAL" ] && ok || bad "1: the manual migration is not reported: [$V]"
V=$(added b-manual)
[ -z "$V" ] && ok || bad "1: a prisma file must never reach the classifier: [$V]"

# case 2 — any *.sql under prisma/
V=$(changed b-prisma-sql)
[ "$V" = "prisma/sql/seed.sql" ] && ok || bad "2: prisma/sql/seed.sql is not reported: [$V]"
V=$(changed b-prisma-sql-top)
[ "$V" = "prisma/backfill.sql" ] && ok || bad "2: a .sql directly under prisma/ is not reported: [$V]"

# case 3 — prisma/schema/*.prisma and the single-file layout
V=$(changed b-schema-dir)
[ "$V" = "prisma/schema/misc.prisma" ] && ok || bad "3: prisma/schema/misc.prisma is not reported: [$V]"
V=$(changed b-schema-single)
[ "$V" = "prisma/schema.prisma" ] && ok || bad "3: prisma/schema.prisma is not reported: [$V]"
V=$(changed b-rename)
[ "$V" = "prisma/migrations/20260101000000_init/migration.sql" ] \
  && ok || bad "3: a prisma migration folder is not reported: [$V]"

# case 4 — the negative: a branch with no migration-shaped file says nothing,
# and says it with rc 0. A gate that cries wolf on every PR is the same bug.
G checkout -q b-none >/dev/null 2>&1
V=$(migration_files_changed main "$R"); RC=$?
[ "$RC" = 0 ] && [ -z "$V" ] && ok || bad "4: a plain code branch must report nothing (rc=$RC out=[$V])"
V=$(migration_sql_added main "$R"); RC=$?
[ "$RC" = 0 ] && [ -z "$V" ] && ok || bad "4: migration_sql_added must report nothing (rc=$RC out=[$V])"
# An unresolvable base is empty, never a crash — the gate is advisory.
V=$(migration_files_changed no-such-ref "$R"); RC=$?
[ "$RC" = 0 ] && [ -z "$V" ] && ok || bad "4: an unresolvable base must be empty, not a crash (rc=$RC out=[$V])"

# scripts/migrations keeps BOTH answers: listed as a migration file AND handed
# to the classifier, exactly as before this ticket.
V=$(changed b-scripts)
[ "$V" = "scripts/migrations/2026-09-22-x.sql" ] && ok || bad "A: scripts/migrations lost its listing: [$V]"
V=$(added b-scripts)
[ "$V" = "scripts/migrations/2026-09-22-x.sql" ] && ok || bad "A: the classifier input changed: [$V]"

# ============================================================================
# B. the production gate block, extracted by its markers (case 5)
# ============================================================================
mkdir -p "$T/h/bin/lib" "$T/h/logs"
awk '/^# >>> migration gate/{f=1;next} /^# <<< migration gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "5: could not extract the migration gate block — markers missing?"
[ -r "$LIB" ] && cp "$LIB" "$T/h/bin/lib/migration-files.sh"

# The classifier stub records its argv and passes. A `prisma/` file that reached
# it would be a scope change this ticket did not make.
cat > "$T/h/bin/check-migration-appliable.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_SINK"
exit "${STUB_RC:-0}"
EOF
chmod +x "$T/h/bin/check-migration-appliable.sh"

run_gate() { # run_gate <branch> [STUB_RC=n]
  G checkout -q "$1" >/dev/null 2>&1; shift
  rm -rf "$T/gbuild"; mkdir -p "$T/gbuild"
  : > "$T/stub.txt"
  ( cd "$R" || exit 1
    env HARNESS="$T/h" BUILD="$T/gbuild" STUB_SINK="$T/stub.txt" \
        WT="$R" BASE=main "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=p; KEY=K; TIER=1
      . "$0"
      printf "MIG_FILES=[%s]\n" "${MIG_FILES:-}"
      printf "ADDED_SQL=[%s]\n" "${ADDED_SQL:-}"
      # MIG_NOTE is flattened: the existing NFLAG fallback (`grep -c || echo "?"`)
      # can put two lines in it, and gval() reads one line per variable.
      printf "MIG_NOTE=[%s]\n"  "$(printf "%s" "${MIG_NOTE:-}" | tr "\n" " ")"
      printf "TIER=[%s]\n"      "${TIER:-}"
    ' "$T/gate.sh" ) > "$T/gate-out.txt" 2>"$T/gate-err.txt"
}
gval() { sed -n "s/^$1=\[\(.*\)\]$/\1/p" "$T/gate-out.txt"; }

# case 5 — the ticket's branch through the production block
run_gate b-manual
[ "$(gval MIG_FILES)" = "$MANUAL" ] \
  && ok || bad "5: the block does not see the manual migration: [$(gval MIG_FILES)] err=$(head -3 "$T/gate-err.txt")"
[ -z "$(gval ADDED_SQL)" ] && ok || bad "5: ADDED_SQL must stay empty: [$(gval ADDED_SQL)]"
[ ! -s "$T/stub.txt" ] && ok || bad "5: the classifier was invoked on a prisma file: $(cat "$T/stub.txt")"
[ -z "$(gval MIG_NOTE)" ] && ok || bad "5: MIG_NOTE must stay empty: [$(gval MIG_NOTE)]"
[ "$(gval TIER)" = 1 ] && ok || bad "5: the tier moved: [$(gval TIER)]"
grep -qF "MIGRATION GATE: 1 migration file(s) in diff: $MANUAL" "$T/gbuild/pipeline.log" \
  && ok || bad "5: no pipeline.log line names the migration: $(cat "$T/gbuild/pipeline.log" 2>/dev/null)"

# 5b — the negative through the same block: a plain code branch logs nothing.
run_gate b-none
[ -z "$(gval MIG_FILES)" ] && ok || bad "5b: a code-only branch reported files: [$(gval MIG_FILES)]"
grep -q 'MIGRATION GATE' "$T/gbuild/pipeline.log" 2>/dev/null \
  && bad "5b: a code-only branch logged a migration line" || ok

# 5c — scripts/migrations still reaches the classifier and still forces tier 2
# when the classifier refuses. The behaviour this ticket must NOT change.
run_gate b-scripts
[ "$(gval ADDED_SQL)" = "scripts/migrations/2026-09-22-x.sql" ] \
  && ok || bad "5c: the classifier input changed: [$(gval ADDED_SQL)]"
grep -q 'scripts/migrations/2026-09-22-x.sql' "$T/stub.txt" \
  && ok || bad "5c: the classifier was not invoked: $(cat "$T/stub.txt")"
[ "$(gval TIER)" = 1 ] && ok || bad "5c: a passing classifier must not demote: [$(gval TIER)]"
run_gate b-scripts STUB_RC=1
[ "$(gval TIER)" = 2 ] && ok || bad "5c: a refusing classifier must force tier 2: [$(gval TIER)]"
[ -n "$(gval MIG_NOTE)" ] && ok || bad "5c: a refusing classifier must set MIG_NOTE"

# ============================================================================
# C. the gates.json write, extracted by its markers (cases 6-8)
# ============================================================================
awk '/^# >>> gates json/{f=1;next} /^# <<< gates json/{exit} f' \
  "$RB_ALL" > "$T/gatesjson.sh"
[ -s "$T/gatesjson.sh" ] && ok || bad "6: could not extract the gates json block — markers missing?"

run_gates() { # run_gates <MIG_FILES> <ADDED_SQL> <MIG_NOTE> [flagged-text]
  rm -rf "$T/jb"; mkdir -p "$T/jb"
  [ -n "${4:-}" ] && printf '%s\n' "$4" > "$T/jb/migration-gate.txt"
  env BUILD="$T/jb" MIG_FILES="$1" ADDED_SQL="$2" MIG_NOTE="$3" bash -c '
    set -uo pipefail
    TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0; E2E_VERDICT=pass
    . "$0"' "$T/gatesjson.sh" >"$T/jb-out.txt" 2>&1
}
jval() { jq -r "$1" "$T/jb/gates.json" 2>/dev/null; }

# case 6 — a prisma migration alone is `present`, and the file is named
run_gates "$MANUAL" "" ""
[ "$(jval .migration)" = present ] \
  && ok || bad "6: a prisma migration must read present: $(cat "$T/jb/gates.json" 2>/dev/null) $(head -3 "$T/jb-out.txt")"
[ "$(jval '.migration_files[0]')" = "$MANUAL" ] \
  && ok || bad "6: gates.json does not carry the file list: $(cat "$T/jb/gates.json" 2>/dev/null)"

# case 7 — the negative: nothing migration-shaped is still `none`, with an
# empty list rather than a missing key
run_gates "" "" ""
[ "$(jval .migration)" = none ] && ok || bad "7: a clean branch must read none: $(jval .migration)"
[ "$(jval '.migration_files | length')" = 0 ] \
  && ok || bad "7: the file list must be empty, not absent: $(cat "$T/jb/gates.json" 2>/dev/null)"

# case 8 — scripts/migrations keeps the classifier's own vocabulary
run_gates "scripts/migrations/x.sql" "scripts/migrations/x.sql" ""
[ "$(jval .migration)" = clean ] && ok || bad "8: a linted migration must stay clean: $(jval .migration)"
run_gates "scripts/migrations/x.sql" "scripts/migrations/x.sql" \
  " | MIGRATION GATE: 1 statement(s) outside the appliable allowlist — tier 2" "FLAGGED: DROP TABLE"
[ "$(jval .migration)" = flagged ] && ok || bad "8: a refused migration must stay flagged: $(jval .migration)"
run_gates "scripts/migrations/x.sql" "scripts/migrations/x.sql" \
  " | MIGRATION GATE: ? statement(s) outside the appliable allowlist — tier 2"
[ "$(jval .migration)" = gate-failed ] \
  && ok || bad "8: a crashed classifier must stay gate-failed: $(jval .migration)"
# The word the classifier owns wins over the word the file list owns: a FLAGGED
# build must never be softened to `present`.
[ "$(jval '.migration_files[0]')" = "scripts/migrations/x.sql" ] \
  && ok || bad "8: the file list was lost on a gate-failed build"

# ============================================================================
# D. bin/evidence-summary.sh — the row a human reads (cases 9-11)
# ============================================================================
mkdir -p "$T/bin"
cp "$DIR/bin/evidence-summary.sh" "$T/bin/evidence-summary.sh"
cp "$DIR/bin/size-scope.sh" "$T/bin/size-scope.sh"

render() { # render <gates.json literal> ; sets ROW / OUT / JSON
  rm -rf "$T/eb"; mkdir -p "$T/eb"
  printf '%s\n' "$1" > "$T/eb/gates.json"
  OUT=$(bash "$T/bin/evidence-summary.sh" "$T/eb" 2 why settled 2>"$T/eb-err.txt")
  JSON=$(bash "$T/bin/evidence-summary.sh" --json "$T/eb" 2 why settled 2>/dev/null)
  ROW=$(printf '%s\n' "$OUT" | grep -F '| migration gate |' || true)
}

# case 9 — present, with both files named
render '{"tamper":"0","repro":"0","intent":"0","e2e":"pass","migration":"present","migration_files":["prisma/migrations/manual/2026-09-22-x.sql","prisma/schema/misc.prisma"]}'
grep -qF <<<"$OUT" \
  '| migration gate | present — prisma/migrations/manual/2026-09-22-x.sql, prisma/schema/misc.prisma |' \
  && ok || bad "9: the Evidence row does not name the files: [$ROW]"
printf '%s' "$JSON" | jq -e '.migration_files | test("2026-09-22-x.sql") and test("misc.prisma")' >/dev/null 2>&1 \
  && ok || bad "9: --json carries no migration_files: $(printf '%s' "$JSON" | jq -c '.migration_files' 2>/dev/null)"
D=$(printf '%s\n' "$OUT" | grep -o 'migration=[a-z-]*' | head -1)
[ "$D" = "migration=present" ] && ok || bad "9: the digest word changed: [$D]"
grep -q '^Digest:.*prisma/' <<<"$(printf '%s\n' "$OUT")" \
  && bad "9: the digest must not carry file paths" || ok

# case 10 — an old record, with no migration_files key at all, renders byte-for
# byte as it did before this ticket
render '{"tamper":"0","repro":"0","intent":"0","e2e":"pass","migration":"none"}'
[ "$ROW" = '| migration gate | none |' ] && ok || bad "10: an old record no longer renders: [$ROW]"
printf '%s' "$JSON" | jq -e 'has("migration_files")' >/dev/null 2>&1 \
  && bad "10: --json invented a migration_files key on an old record" || ok

# case 11 — a path carrying a pipe and a control character cannot break the
# table. clean() owns this; the row must still be one row of three cells.
render "$(printf '{"tamper":"0","repro":"0","intent":"0","e2e":"pass","migration":"present","migration_files":["prisma/a|b.sql","prisma/c\\u0001d.sql"]}')"
N=$(printf '%s\n' "$OUT" | grep -cF '| migration gate |')
[ "$N" = 1 ] && ok || bad "11: expected exactly one migration gate row, got $N"
CELLS=$(printf '%s\n' "$ROW" | awk -F'|' '{print NF}')
[ "$CELLS" = 4 ] && ok || bad "11: the row is not 3 pipe-separated cells: [$ROW]"
grep -q $'\001' <<<"$(printf '%s\n' "$ROW")" && bad "11: a control character reached the row" || ok

G checkout -q main >/dev/null 2>&1
echo "migration-gate.bh-1355: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
