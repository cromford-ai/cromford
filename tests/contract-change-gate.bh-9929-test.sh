#!/bin/bash
# tests/contract-change-gate.bh-9929-test.sh — BH-9929 T6, T7.
#
#   A2  the same DROP CONSTRAINT as a contract-change ticket passes after its
#       expand and migrate steps: expand (adds t2), migrate (backfill script
#       + counts + 0 old-shape reads), contract (DROP CONSTRAINT + backup +
#       restore test) — rc 0 each, through bin/contract-change-gate.sh
#   A2n the negatives of each step (expand with a DROP, migrate without the
#       counts, a short window, a script without `resumable`, a grep hit)
#   A3  a contract step with no BACKUP: line, with `BACKUP: TODO`, with
#       `RESTORE-TESTED: ... rc 1`, with no contract SQL, or with a DELETE or
#       GRANT beside the contract statement is refused (an index beside it passes)
#   A5  a contract step dropping report_choice while src/report.ts reads it is
#       refused with the count and the file:line; the name only in
#       scripts/migrations/, docs/x.md and the named backfill script passes;
#       report_choice_ext alone passes; a named drop needs OLD-SHAPE-READS
#   A5b the contract PR removes the last read itself: refused on main (the
#       code production serves until the deploy)
#   A5c the reads left main under CONTRACT_CHANGE_QUERY_LOG_WINDOW_H ago:
#       refused (git log -G on the base)
#   A6  a project whose migrations_glob row is prisma/sql/*.sql: a DROP TABLE
#       there refuses an expand step; a prisma/sql/ contract step passes (the
#       old prisma/sql/ files are not reads); an unreadable row is rc 2
#   P   the production `# >>> contract-change gate (BH-9929)` block of
#       bin/lib/rb/pr.sh, extracted by its markers and run under bash: a refused
#       step writes REVIEW_BLOCKED, exits 6 and adds nothing to the PR body; a
#       passing contract step adds the `## Contract step` section, and a DROP
#       TABLE step adds CONTRACT-HUMAN-VERDICT; the switch off runs nothing.
#       Then the `# >>> contract step labels (BH-9929)` block: the label POST
#       carries contract-step:<step> (+ contract-change:human) and cc_record
#       gets the step row.
#
# Every repo is a scratch git repo; 0 network calls (the gh in the labels block
# is a stub that records its argv).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "contract-change-gate: jq is required"; exit 1; }
GATE="$DIR/bin/contract-change-gate.sh"

R="$T/repo"; mkdir -p "$R"
# Every commit is 30 days old unless a case says otherwise: the contract
# step's window check (git log -G on the base) needs old history to pass.
OLD_DATE="$(( $(date +%s) - 30*86400 )) +0000"
export GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE"
G() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q -b main
mkdir -p "$R/src" "$R/scripts/migrations" "$R/docs"
printf 'CREATE TABLE report_choice (id INTEGER PRIMARY KEY, kind TEXT CONSTRAINT report_choice_kind_check CHECK (kind IN (\x27a\x27)));\n' > "$R/scripts/migrations/0001_init.sql"
printf 'import x from "y";\n// load\nconst rows = db.select("report_choice");\n' > "$R/src/report.ts"
G add -A && G commit -qm init

# gate <step> <evidence-file> — rc of the gate on the current branch vs main
gate() { "$GATE" project-3 "$R" "${3:-main}" "$1" "$2" > "$T/gate.out" 2>&1; echo $?; }
ev()   { printf '%s\n' "$@" > "$T/ev.md"; }
has()  { grep -qF -- "$1" "$T/gate.out"; }

# ── A2: expand ───────────────────────────────────────────────────────────────
G checkout -qb s-expand
printf 'CREATE TABLE report_kind (id TEXT PRIMARY KEY);\nALTER TABLE report_choice ADD COLUMN kind_id TEXT;\n' > "$R/scripts/migrations/0002_expand.sql"
G add -A && G commit -qm expand
ev ''
RC=$(gate expand "$T/ev.md"); [ "$RC" = 0 ] && has 'CONTRACT-GATE: pass expand' && ok || bad "A2 expand must pass: rc=$RC $(cat "$T/gate.out")"
# negative: a DROP in expand
printf 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;\n' > "$R/scripts/migrations/0003_bad.sql"
G add -A && G commit -qm bad
RC=$(gate expand "$T/ev.md"); [ "$RC" = 1 ] && has 'refused: expand adds the new shape only' && ok || bad "A2n expand with a DROP must refuse: rc=$RC $(cat "$T/gate.out")"
G reset -q --hard HEAD~1

# ── A2: migrate ──────────────────────────────────────────────────────────────
G checkout -qb s-migrate
cat > "$R/scripts/backfill-report-kind.ts" <<'EOF'
// Backfill report_choice.kind -> report_choice.kind_id.
// idempotent: upserts on the id; resumable: cursor on the last id written.
EOF
printf 'import x from "y";\n// load\nconst rows = db.select("report_kind");\n' > "$R/src/report.ts"
G add -A && G commit -qm migrate
MIG_OK=('BACKFILL-SCRIPT: scripts/backfill-report-kind.ts' 'BACKFILL-COUNTS: before=10 after=10' 'OLD-SHAPE: report_choice' 'OLD-SHAPE-READS: grep=0 query-log=0 window=168h')
ev "${MIG_OK[@]}"
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 0 ] && ok || bad "A2 migrate must pass: rc=$RC $(cat "$T/gate.out")"
ev 'BACKFILL-SCRIPT: scripts/backfill-report-kind.ts' 'OLD-SHAPE: report_choice' 'OLD-SHAPE-READS: grep=0 query-log=0 window=168h'
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 1 ] && has 'refused: no BACKFILL-COUNTS' && ok || bad "A2n migrate without counts must refuse: rc=$RC"
ev 'BACKFILL-SCRIPT: scripts/backfill-report-kind.ts' 'BACKFILL-COUNTS: before=10 after=10' 'OLD-SHAPE: report_choice' 'OLD-SHAPE-READS: grep=0 query-log=0 window=24h'
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 1 ] && has 'window is 24h, under the 168h' && ok || bad "A2n a 24h window must refuse: rc=$RC $(cat "$T/gate.out")"
ev 'BACKFILL-SCRIPT: scripts/backfill-report-kind.ts' 'BACKFILL-COUNTS: before=10 after=10' 'OLD-SHAPE: report_choice' 'OLD-SHAPE-READS: grep=0 query-log=3 window=168h'
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 1 ] && has 'query-log=3, not 0' && ok || bad "A2n query-log=3 must refuse: rc=$RC"
# the backfill script reads the old shape: excluded. A src/ read: refused.
printf 'const old = db.select("report_choice");\n' > "$R/src/legacy.ts"; G add -A && G commit -qm legacy
ev "${MIG_OK[@]}"
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 1 ] && has 'refused: 1 read(s) of report_choice in src/legacy.ts:1' && ok || bad "A2n a src read in migrate must refuse: rc=$RC $(cat "$T/gate.out")"
ev "${MIG_OK[@]}" 'OLD-SHAPE-WRITERS: src/legacy.ts'
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 0 ] && ok || bad "A2 a named old-shape writer is allowed until contract: rc=$RC $(cat "$T/gate.out")"
G reset -q --hard HEAD~1
sed -i 's/resumable/restartable/' "$R/scripts/backfill-report-kind.ts"
ev "${MIG_OK[@]}"
RC=$(gate migrate "$T/ev.md"); [ "$RC" = 1 ] && has "does not say 'resumable'" && ok || bad "A2n a script without 'resumable' must refuse: rc=$RC"
G checkout -q -- .

# ── A2/A3: contract ──────────────────────────────────────────────────────────
G checkout -qb s-contract
printf 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;\n' > "$R/scripts/migrations/0004_contract.sql"
G add -A && G commit -qm contract
CON_OK=('BACKUP: branch project-3-pre-9929' 'RESTORE-TESTED: turso db shell project-3-scratch < dump.sql -> project-3-scratch rc 0')
# a contract step that drops or renames a named shape also carries the reads line
CON_NM=("${CON_OK[@]}" 'OLD-SHAPE-READS: grep=0 query-log=0 window=168h')
ev "${CON_OK[@]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 0 ] && has 'CONTRACT-GATE: pass contract (classes: constraint)' && ok || bad "A2 contract must pass: rc=$RC $(cat "$T/gate.out")"
ev "${CON_OK[1]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'CONTRACT-GATE: refused: no BACKUP: line' && ok || bad "A3 no BACKUP must refuse: rc=$RC $(cat "$T/gate.out")"
ev 'BACKUP: TODO' "${CON_OK[1]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'placeholder' && ok || bad "A3 BACKUP: TODO must refuse: rc=$RC"
ev 'BACKUP: <ref>' "${CON_OK[1]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && ok || bad "A3 BACKUP: <ref> must refuse: rc=$RC"
ev "${CON_OK[0]}" 'RESTORE-TESTED: turso db shell project-3-scratch < dump.sql -> project-3-scratch rc 1'
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'RESTORE-TESTED' && ok || bad "A3 RESTORE-TESTED rc 1 must refuse: rc=$RC"
ev "${CON_OK[0]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'no RESTORE-TESTED: line' && ok || bad "A3 no RESTORE-TESTED must refuse: rc=$RC"
RC=$(gate contract "$T/none.md"); [ "$RC" = 1 ] && has 'no BACKUP: line' && ok || bad "A3 no evidence file must refuse: rc=$RC"
# a contract step whose file also carries a DELETE or a GRANT (BH-9929 review):
# the lane applies the whole file, so a non-additive rider is refused
G checkout -q s-contract && G checkout -qb s-rider
printf 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;\nDELETE FROM users;\n' > "$R/scripts/migrations/0004_contract.sql"
G add -A && G commit -qm rider
ev "${CON_OK[@]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'not a contract change and not additive' && has 'DELETE FROM users' && ok \
  || bad "A3 a contract step with a DELETE rider must refuse: rc=$RC $(cat "$T/gate.out")"
printf 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;\nGRANT ALL ON users TO anon;\n' > "$R/scripts/migrations/0004_contract.sql"
G add -A && G commit -qm grant
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'GRANT to anon' && ok || bad "A3 a contract step with a GRANT rider must refuse: rc=$RC $(cat "$T/gate.out")"
# a rider ACTION inside the contract ALTER TABLE (BH-9929 review): refused
for st in 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check, DISABLE ROW LEVEL SECURITY;' \
          'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check, OWNER TO anon;'; do
  printf '%s\n' "$st" > "$R/scripts/migrations/0004_contract.sql"
  G add -A && G commit -qm "rider action"
  RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'inside a contract statement' && ok \
    || bad "A3 a rider action [$st] must refuse: rc=$RC $(cat "$T/gate.out")"
done
# an additive rider (a new index) beside the contract statement passes
printf 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;\nCREATE INDEX IF NOT EXISTS idx_rc_kind ON report_choice(kind_id);\n' > "$R/scripts/migrations/0004_contract.sql"
G add -A && G commit -qm idx
RC=$(gate contract "$T/ev.md"); [ "$RC" = 0 ] && ok || bad "A3 an additive rider must pass: rc=$RC $(cat "$T/gate.out")"
# a contract step with no contract SQL
G checkout -q main && G checkout -qb s-empty
ev "${CON_OK[@]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'no contract statement' && ok || bad "A3 a contract step that removes nothing must refuse: rc=$RC"

# ── A5: the grep still finds a read ──────────────────────────────────────────
G checkout -q main && G checkout -qb s-drop
printf 'DROP TABLE report_choice;\n' > "$R/scripts/migrations/0005_drop.sql"
G add -A && G commit -qm drop
ev "${CON_NM[@]}"
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'CONTRACT-GATE: refused: 1 read(s) of report_choice in src/report.ts:3' && ok \
  || bad "A5 a live read must refuse with file:line: rc=$RC $(cat "$T/gate.out")"
# A5b (refute review): the contract PR removes the last read itself, in the
# same PR as the drop. main still reads it, and production serves main until
# the deploy (hotfix-migrate applies before the merge): refused on main.
printf 'const rows = db.select("report_choice_ext");\n' > "$R/src/report.ts"
G add -A && G commit -qm same-pr-switch
RC=$(gate contract "$T/ev.md"); [ "$RC" = 1 ] && has 'refused: 1 read(s) of report_choice in src/report.ts:3 on main (the code production serves' && ok \
  || bad "A5b a read removed in the contract PR itself must refuse on main: rc=$RC $(cat "$T/gate.out")"
# m2: the migrate step merged long ago (reads switched, the backfill script on
# main); the contract step off m2 carries migration SQL only.
G checkout -q main && G checkout -qb m2
printf 'const rows = db.select("report_choice_ext");\n' > "$R/src/report.ts"
printf 'We dropped report_choice.\n' > "$R/docs/x.md"
printf '// Backfill report_choice -> report_kind.\n// idempotent and resumable: cursor on the last id.\nconst rows = db.select("report_choice");\n' > "$R/src/backfill-rc.ts"
G add -A && G commit -qm switch
G checkout -qb s-drop2
printf 'DROP TABLE report_choice;\n' > "$R/scripts/migrations/0005_drop.sql"
G add -A && G commit -qm drop2
ev "${CON_NM[@]}"
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 1 ] && has 'read(s) of report_choice in src/backfill-rc.ts:1 src/backfill-rc.ts:3' && ok \
  || bad "A5 an unnamed backfill script is a read: rc=$RC $(cat "$T/gate.out")"
ev "${CON_NM[@]}" 'BACKFILL-SCRIPT: src/backfill-rc.ts'
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 0 ] && ok || bad "A5 migrations/docs/_ext/the named backfill script only must pass: rc=$RC $(cat "$T/gate.out")"
CON_M2=("${CON_NM[@]}" 'BACKFILL-SCRIPT: src/backfill-rc.ts')
ev "${CON_OK[@]}" 'BACKFILL-SCRIPT: src/backfill-rc.ts'
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 1 ] && has 'no OLD-SHAPE-READS' && ok || bad "A5 a named drop with no OLD-SHAPE-READS line must refuse: rc=$RC $(cat "$T/gate.out")"
ev "${CON_OK[@]}" 'OLD-SHAPE-READS: grep=0 query-log=0 window=24h' 'BACKFILL-SCRIPT: src/backfill-rc.ts'
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 1 ] && has 'window is 24h, under the 168h' && ok || bad "A5 a 24h query-log window at contract must refuse: rc=$RC"
ev "${CON_NM[@]}" 'BACKFILL-SCRIPT: src/report.ts'
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 1 ] && has 'is not a backfill script on m2' && ok || bad "A5 a BACKFILL-SCRIPT that is not one must refuse: rc=$RC $(cat "$T/gate.out")"
ev "${CON_M2[@]}"
# a nested markdown file is excluded too (the *.md glob is not top-level only)
mkdir -p "$R/docs/deep"; printf 'report_choice\n' > "$R/docs/deep/y.md"; G add -A && G commit -qm deep
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 0 ] && ok || bad "A5 a nested .md must be excluded: rc=$RC $(cat "$T/gate.out")"
# a comment line in code IS a read (conservative)
printf '// report_choice is gone\n' > "$R/src/c.ts"; G add -A && G commit -qm cmt
RC=$(gate contract "$T/ev.md" m2); [ "$RC" = 1 ] && has 'src/c.ts:1' && ok || bad "A5 a comment in code is a hit: rc=$RC"
G reset -q --hard HEAD~1
# A5c (refute review, Scope 2 window): the reads left main only now. The
# contract step waits CONTRACT_CHANGE_QUERY_LOG_WINDOW_H after that merge.
G checkout -q main && G checkout -qb m3
printf 'const rows = db.select("report_choice_ext");\n' > "$R/src/report.ts"
G add -A && GIT_AUTHOR_DATE="$(date +%s) +0000" GIT_COMMITTER_DATE="$(date +%s) +0000" G commit -qm fresh-switch
G checkout -qb s-drop3
printf 'DROP TABLE report_choice;\n' > "$R/scripts/migrations/0005_drop.sql"
G add -A && G commit -qm drop3
ev "${CON_NM[@]}"
RC=$(gate contract "$T/ev.md" m3); [ "$RC" = 1 ] && has 'the old shape must be unread on m3 for 168h' && ok \
  || bad "A5c a read removed from the base under the window ago must refuse: rc=$RC $(cat "$T/gate.out")"
RC=$(CONTRACT_CHANGE_QUERY_LOG_WINDOW_H=0 gate contract "$T/ev.md" m3); [ "$RC" = 0 ] && ok \
  || bad "A5c the window is the registry knob (0 = no wait): rc=$RC $(cat "$T/gate.out")"
G checkout -q main
# could not run: unknown step and no worktree
"$GATE" project-3 "$R" main shrink "$T/ev.md" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && ok || bad "G2 an unknown step must be rc 2: rc=$RC"
"$GATE" project-3 "$T/nope" main contract "$T/ev.md" >/dev/null 2>&1; RC=$?; [ "$RC" = 2 ] && ok || bad "G2 no worktree must be rc 2: rc=$RC"

# ── A6: a project whose SQL is not in scripts/migrations/ (BH-9929 review) ──
# project-6-os keeps its migrations in prisma/sql/ (settings row
# migrations_glob.project-6-os). The gate reads that glob too, and fails closed
# when the row is unreadable. setting_get is a fixture in a scratch harness.
MGH="$T/mgh"; mkdir -p "$MGH/bin"
cat > "$MGH/bin/jobs-client.sh" <<EOF
setting_get() {
  [ "\$1" = migrations_glob.mk-os ] || return 2
  [ -f "$T/mg-row" ] || return 2
  [ "\$(cat "$T/mg-row")" = UNREADABLE ] && return 1
  cat "$T/mg-row"
}
EOF
mgate() { HARNESS="$MGH" "$GATE" mk-os "$R" "${3:-main}" "$1" "$2" > "$T/gate.out" 2>&1; echo $?; }
printf 'prisma/sql/*.sql' > "$T/mg-row"
G checkout -q main && G checkout -qb s-mk-expand
mkdir -p "$R/prisma/sql"
printf 'DROP TABLE report_choice_ext;\n' > "$R/prisma/sql/0002_drop.sql"
G add -A && G commit -qm mk-expand
ev ''
RC=$(mgate expand "$T/ev.md"); [ "$RC" = 1 ] && has "refused: expand adds the new shape only; it carries a 'drop-table' change" && ok \
  || bad "A6 a DROP TABLE in prisma/sql/ on an expand step must refuse: rc=$RC $(cat "$T/gate.out")"
# the same file with no row: the default glob, so this gate does not see it
rm -f "$T/mg-row"
RC=$(mgate expand "$T/ev.md"); [ "$RC" = 0 ] && ok || bad "A6 no row: the default glob only: rc=$RC $(cat "$T/gate.out")"
printf UNREADABLE > "$T/mg-row"
RC=$(mgate expand "$T/ev.md"); [ "$RC" = 2 ] && has 'could not run' && has 'migrations_glob.mk-os' && ok \
  || bad "A6 an unreadable row must be could-not-run (rc 2): rc=$RC $(cat "$T/gate.out")"
printf 'prisma/sql/*.sql' > "$T/mg-row"
G checkout -q main && G checkout -qb s-mk-base
mkdir -p "$R/prisma/sql"
printf 'CREATE TABLE report_choice_ext (id INTEGER PRIMARY KEY);\n' > "$R/prisma/sql/0001_ext.sql"
G add -A && G commit -qm mk-base
G checkout -qb s-mk-contract
printf 'DROP TABLE report_choice_ext;\n' > "$R/prisma/sql/0003_contract.sql"
G add -A && G commit -qm mk-contract
ev "${CON_NM[@]}"
RC=$(mgate contract "$T/ev.md" s-mk-base)
[ "$RC" = 0 ] && has 'CONTRACT-GATE: pass contract (classes: drop-table)' && ok \
  || bad "A6 a prisma/sql/ contract step passes, its old migration files are not reads: rc=$RC $(cat "$T/gate.out")"
G checkout -q main

# ── P: the production PR-stage blocks ────────────────────────────────────────
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
awk '/^# >>> contract-change gate \(BH-9929\)/{f=1;next} /^# <<< contract-change gate \(BH-9929\)/{exit} f' "$RB_ALL" > "$T/ccg.sh"
awk '/^# >>> contract step labels \(BH-9929\)/{f=1;next} /^# <<< contract step labels \(BH-9929\)/{exit} f' "$RB_ALL" > "$T/ccl.sh"
[ -s "$T/ccg.sh" ] && ok || bad "P0 could not extract the contract-change gate block"
[ -s "$T/ccl.sh" ] && ok || bad "P0 could not extract the contract step labels block"
H="$T/h"; mkdir -p "$H/bin/lib" "$H/fakebin"
cp "$DIR/bin/contract-change-gate.sh" "$DIR/bin/check-migration-appliable.sh" "$H/bin/"
# scratch-closure-allow: the pr.sh blocks are extracted and run alone; they source only these libs from $HARNESS
cp "$DIR/bin/lib/contract-change.sh" "$DIR/bin/lib/migration-files.sh" "$H/bin/lib/"
# cc_enabled is the real one: the lane-gate registry read over a settings
# cache this suite writes (project-3 on, project-1 off).
# scratch-closure-allow: the pr.sh blocks are extracted and run alone; they source only these libs from $HARNESS
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "P0 lanes-build could not compose the registry"
mkdir -p "$H/state"
jq -nc '{fetched_at:1700000000, values:{"lib.contract-change.project-3.contract_change_enabled":"1"}, seeded:{}}' > "$H/state/settings-cache.json"
cat > "$H/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
EOF
chmod +x "$H/fakebin/gh"
cat > "$H/bin/lib/contract-change-record.sh" <<'EOF'
cc_record() { printf '%s\n' "$*" >> "$REC_SINK"; }
EOF

# pstage <branch> <step-body> <evidence...> — run both blocks, as pr.sh does
pstage() {
  local br="$1" body="$2"; shift 2
  G checkout -q "$br"
  rm -rf "$T/b"; mkdir -p "$T/b"; : > "$T/gh.txt"; : > "$T/rec.txt"; : > "$T/alerts"
  printf '%s\n' "$@" > "$T/b/contract-step.md"
  jq -n --arg b "$body" '{title:"t", labels:[], body:$b}' > "$T/b/ticket-meta.json"
  ( cd "$R" && env HARNESS="$H" BUILD="$T/b" WT="$R" BASE="${PBASE:-main}" GH_SINK="$T/gh.txt" REC_SINK="$T/rec.txt" \
      PATH="$H/fakebin:$PATH" P="${P:-project-3}" LANE_REGISTRY="$REG" LANE_GATE_NOW=1700000010 bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { printf "RESULT %s\n" "$*"; }
      prr_write() { shift 4; "$@"; }
      PROJECT=$P; KEY=K; ALERTS="$BUILD/../alerts"; PREPR_SECTION=""
      ADDED_SQL=$(git diff --name-only --diff-filter=A "$BASE"...HEAD -- "scripts/migrations/*.sql")
      . "$HARNESS/bin/lib/contract-change.sh"
      . "$0"
      printf "%s" "$PREPR_SECTION" > "$BUILD/prepr.txt"
      PR_URL=https://github.com/o/r/pull/7
      . "$0.labels"
      echo "END"
    ' "$T/ccg.sh" ) > "$T/p.out" 2>&1
  echo $?
}
cp "$T/ccl.sh" "$T/ccg.sh.labels"

STEP_BODY=$'Contract-parent: #41\nContract-step: contract\n\nscope'
# P1: refused (no backup) -> REVIEW_BLOCKED, exit 6, no section, no label
RC=$(pstage s-drop "$STEP_BODY" "${CON_OK[1]}")
[ "$RC" = 6 ] && grep -q '^RESULT REVIEW_BLOCKED contract-change gate (contract): ' "$T/p.out" && ok || bad "P1 a refused step: rc 6 + REVIEW_BLOCKED: rc=$RC $(cat "$T/p.out")"
grep -q END "$T/p.out" && bad "P1 a refused step must stop before the PR" || ok
[ ! -s "$T/gh.txt" ] && ok || bad "P1 a refused step must write no label"
# P2: a passing DROP TABLE step (reads switched) -> section + human line + labels + record
RC=$(PBASE=m2 pstage s-drop2 "$STEP_BODY" "${CON_M2[@]}")
[ "$RC" = 0 ] && grep -q END "$T/p.out" && ok || bad "P2 a passing step must reach the PR: rc=$RC $(cat "$T/p.out")"
grep -qx 'CONTRACT STEP: contract of #41' "$T/b/prepr.txt" && ok || bad "P2 the body must carry CONTRACT STEP: $(cat "$T/b/prepr.txt")"
grep -qx 'CONTRACT-HUMAN-VERDICT: required' "$T/b/prepr.txt" && ok || bad "P2 a DROP TABLE step must carry CONTRACT-HUMAN-VERDICT"
grep -qxF "${CON_OK[0]}" "$T/b/prepr.txt" && ok || bad "P2 the evidence lines must ride in the body"
grep -qF 'labels[]=contract-step:contract' "$T/gh.txt" && grep -qF 'labels[]=contract-change:human' "$T/gh.txt" && ok || bad "P2 labels: $(cat "$T/gh.txt")"
grep -qF 'project-3 41 contract pr_url=https://github.com/o/r/pull/7' "$T/rec.txt" && grep -qF 'backup_ref=branch project-3-pre-9929' "$T/rec.txt" \
  && ok || bad "P2 cc_record: $(cat "$T/rec.txt")"
# P3: a passing constraint step -> no human line, no human label
RC=$(pstage s-contract "$STEP_BODY" "${CON_OK[@]}")
[ "$RC" = 0 ] && ! grep -q 'CONTRACT-HUMAN-VERDICT' "$T/b/prepr.txt" && ! grep -q 'contract-change:human' "$T/gh.txt" \
  && grep -qF 'labels[]=contract-step:contract' "$T/gh.txt" && ok || bad "P3 a constraint step needs no human: rc=$RC $(cat "$T/gh.txt")"
# P4: the switch off -> nothing (an ordinary PR)
RC=$(P=project-1 pstage s-drop "$STEP_BODY" "${CON_OK[1]}")
[ "$RC" = 0 ] && [ ! -s "$T/b/prepr.txt" ] && [ ! -s "$T/gh.txt" ] && ok || bad "P4 the switch off must run nothing: rc=$RC $(cat "$T/p.out")"
# P5: an ordinary ticket (no Contract-step) -> nothing, even with a DROP
RC=$(pstage s-drop $'just a ticket\nContract-change: yes' "${CON_OK[1]}")
[ "$RC" = 0 ] && [ ! -s "$T/b/prepr.txt" ] && [ ! -s "$T/gh.txt" ] && ok || bad "P5 an ordinary ticket must run nothing: rc=$RC"

echo "contract-change-gate.bh-9929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
