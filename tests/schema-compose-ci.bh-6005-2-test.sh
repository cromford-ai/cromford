#!/bin/bash
# tests/schema-compose-ci.bh-6005-2-test.sh — every CI and lint reader of
# worker/jobs/schema.sql composes from worker/jobs/schema.d/, and every gate
# keyed on that path also fires on a fragment diff (BH-6005, child 3: BH-6009).
#
# Since BH-4987 a new table is one fragment under schema.d/. A PR that carries
# only the fragment made five gates vacuous: the seed lint said `nothing to
# check`, the ensure-columns check never read the index, the risk tier missed
# the path, the merge-queue batch did not gate the SPA job, and test selection
# never picked the suites that read schema.sql. The upgrade replay read only
# schema.sql files, so a worker with fragments only was never replayed.
#
#   W1-W5 bin/worker-schema-upgrade.sh --base composes head and base
#   M1-M6 bin/model-route-seed-lint.sh triggers on a fragment and composes
#   C1-C3 checks/worker-schema-ensure-columns/check.sh reads a fragment index
#   R1    bin/lib/risk-tier.sh: a fragment is high
#   E1    catalog/ci-batch-escalate.tsv: a fragment affects spa and worker
#   T1-T4 bin/test-impact.sh select aliases a fragment to schema.sql
#   N1    the negative paths trigger none of the above
#   K1-K2 this child keeps schema.sql tracked and stays out of the contract
#
# Run from anywhere: bash tests/schema-compose-ci.bh-6005-2-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
UP="$DIR/bin/worker-schema-upgrade.sh"
LINT="$DIR/bin/model-route-seed-lint.sh"
CHK="$DIR/checks/worker-schema-ensure-columns/check.sh"
RUN="$DIR/bin/checks-run.sh"
TI="$DIR/bin/test-impact.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: wanted '$3' in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: did not want '$3' in: $2" ;; *) ok ;; esac; }

mkrepo() { # mkrepo <dir> — an empty scratch git repo
  mkdir -p "$1" && git -C "$1" init -q \
    && git -C "$1" config user.email fixture@example.com && git -C "$1" config user.name fixture
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2" && git -C "$1" rev-parse HEAD; }

# ── fixtures ────────────────────────────────────────────────────────────────
cat > "$T/0000-fixture.sql" <<'EOF'
-- fixture base: two tables
CREATE TABLE IF NOT EXISTS fixture_rows (id INTEGER PRIMARY KEY, ts TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS cost_rows (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, usd REAL);
EOF
printf 'CREATE INDEX IF NOT EXISTS ix_fixture ON fixture_rows(ts);\n' > "$T/0100-clean.sql"
printf 'CREATE INDEX IF NOT EXISTS ix_fixture_lane ON cost_rows(lane_id);\n' > "$T/0100-lane.sql"
seed() { # seed <model> — one model_routes seed for fixture.role
  printf "INSERT OR IGNORE INTO model_routes (project, repo, role, position, model, runner, updated_by, updated_at) VALUES\n  ('hub', NULL, 'fixture.role', 0, '%s', 'claude', 'seed', '2026-01-01');\n" "$1"
}
seed model-fixture-a > "$T/routes-base.sql"
seed model-fixture-b > "$T/routes-head.sql"

# ── W: the upgrade replay composes ──────────────────────────────────────────
# W1: ref A has fragments only, the working tree adds a clean fragment.
G="$T/w"; mkrepo "$G"; mkdir -p "$G/worker/jobs/schema.d"
cp "$T/0000-fixture.sql" "$G/worker/jobs/schema.d/0000-fixture.sql"
A=$(commit "$G" base)
cp "$T/0100-clean.sql" "$G/worker/jobs/schema.d/0100-fixture.sql"
OUT=$("$UP" --base "$A" --root "$G" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W1: rc $RC, expected 0: $OUT"
grep -Eq '^SCHEMA-UPGRADE: ok \(jobs: base 2 \+ head 3 statements\)' <<<"$OUT" \
  && ok || bad "W1: summary is not 'jobs: base 2 + head 3': $OUT"
hasnt "W1 not a new worker" "$OUT" "NEW worker"

# W2: the new fragment indexes cost_rows(lane_id), which the base CREATE lacks.
cp "$T/0100-lane.sql" "$G/worker/jobs/schema.d/0100-fixture.sql"
OUT=$("$UP" --base "$A" --root "$G" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "W2: rc $RC, expected 1: $OUT"
grep -q '^SCHEMA-UPGRADE FAIL worker/jobs/schema.sql statement 3/3: no such column: lane_id' <<<"$OUT" \
  && ok || bad "W2: no FAIL line against worker/jobs/schema.sql: $OUT"

# W3: a stray file in the working schema.d/ is could-not-run, never an ok.
rm -f "$G/worker/jobs/schema.d/0100-fixture.sql"; echo "fixture notes" > "$G/worker/jobs/schema.d/README"
OUT=$("$UP" --base "$A" --root "$G" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "W3: rc $RC, expected 2: $OUT"
has "W3 could not run" "$OUT" "could not run — worker/jobs/schema.d could not be composed"
has "W3 names the stray file" "$OUT" "worker/jobs/schema.d/README"
hasnt "W3 no ok" "$OUT" "SCHEMA-UPGRADE: ok"
rm -f "$G/worker/jobs/schema.d/README"

# W5: the REF's schema.d does not compose -> rc 2, never an empty base.
echo "fixture notes" > "$G/worker/jobs/schema.d/README"
B=$(commit "$G" stray)
rm -f "$G/worker/jobs/schema.d/README"
OUT=$("$UP" --base "$B" --root "$G" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "W5: a REF whose schema.d does not compose gave rc $RC, expected 2: $OUT"
has "W5 says the base" "$OUT" "could not run — worker/jobs/schema.d at $B could not be composed"
hasnt "W5 not a new worker" "$OUT" "NEW worker"

# W4: the base tracks schema.sql (today's main), the head has fragments only.
G4="$T/w4"; mkrepo "$G4"; mkdir -p "$G4/worker/jobs"
cp "$T/0000-fixture.sql" "$G4/worker/jobs/schema.sql"
A4=$(commit "$G4" base)
rm -f "$G4/worker/jobs/schema.sql"; mkdir -p "$G4/worker/jobs/schema.d"
cp "$T/0000-fixture.sql" "$G4/worker/jobs/schema.d/0000-fixture.sql"
cp "$T/0100-clean.sql" "$G4/worker/jobs/schema.d/0100-fixture.sql"
OUT=$("$UP" --base "$A4" --root "$G4" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "W4: rc $RC, expected 0: $OUT"
grep -q '^SCHEMA-UPGRADE: ok (jobs: base 2 + head 3 statements)' <<<"$OUT" \
  && ok || bad "W4: summary is not 'jobs: base 2 + head 3': $OUT"

# ── M: the seed lint ────────────────────────────────────────────────────────
MR="$T/mroot"; mkdir -p "$MR"
lint() { # lint <files> [ENV=VAL...] -> $OUT, $RC (the seams, base/head SQL fixtures)
  local files="$1"; shift
  OUT=$(env -u PR_BODY MRSL_ROOT="$MR" MRSL_BASE_SQL="$T/routes-base.sql" MRSL_HEAD_SQL="$T/routes-head.sql" \
    MRSL_FILES="$files" MRSL_ADDED="" "$@" bash "$LINT" 2>&1); RC=$?
}
lint worker/jobs/schema.d/0100-routes.sql
[ "$RC" = 1 ] && ok || bad "M1: a fragment-only diff with a changed rung gave rc $RC, expected 1: $OUT"
has "M1 names the role" "$OUT" "fixture.role"
hasnt "M1 not skipped" "$OUT" "nothing to check"

lint worker/jobs/schema.d/0100-routes.sql MRSL_ADDED='+-- seed-only: fresh-db'
[ "$RC" = 0 ] && ok || bad "M2: the waiver gave rc $RC, expected 0: $OUT"
has "M2 waived" "$OUT" "WAIVED"

lint docs/x.md
[ "$RC" = 0 ] && ok || bad "M3: rc $RC, expected 0: $OUT"
has "M3 skip line" "$OUT" "worker/jobs/schema.sql not in the diff (no schema.sql, no schema.d fragment) — nothing to check"

lint worker/jobs/schema.d/README
[ "$RC" = 0 ] && ok || bad "M4: a non-.sql path under schema.d/ gave rc $RC, expected 0: $OUT"
has "M4 skip line" "$OUT" "nothing to check"

# M5: no MRSL_HEAD_SQL, and the root's schema.d/ does not compose -> rc 2.
M5="$T/m5"; mkdir -p "$M5/worker/jobs/schema.d"; echo "fixture notes" > "$M5/worker/jobs/schema.d/README"
OUT=$(env -u PR_BODY MRSL_ROOT="$M5" MRSL_BASE_SQL="$T/routes-base.sql" \
  MRSL_FILES=worker/jobs/schema.d/0100-routes.sql MRSL_ADDED="" bash "$LINT" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "M5: an uncomposable head gave rc $RC, expected 2: $OUT"
has "M5 could not run" "$OUT" "could not run"

# M1g: the git path, no seams. The base commit has fragments only, the head
# commit changes the rung in a fragment: HEAD composes from the tree, BASE
# composes through --ref, FILES and ADDED come from git.
GM="$T/mg"; mkrepo "$GM"; mkdir -p "$GM/worker/jobs/schema.d"
cp "$T/0000-fixture.sql" "$GM/worker/jobs/schema.d/0000-fixture.sql"
cp "$T/routes-base.sql" "$GM/worker/jobs/schema.d/0100-routes.sql"
MB=$(commit "$GM" base)
cp "$T/routes-head.sql" "$GM/worker/jobs/schema.d/0100-routes.sql"
commit "$GM" head >/dev/null
OUT=$(cd "$GM" && env -u PR_BODY -u MRSL_ROOT -u MRSL_FILES -u MRSL_ADDED -u MRSL_BASE_SQL -u MRSL_HEAD_SQL \
  bash "$LINT" "$MB" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "M1g: the git path gave rc $RC, expected 1: $OUT"
has "M1g names the role" "$OUT" "fixture.role"

# M2g: the waiver on an added line of the FRAGMENT diff counts (ADDED spans schema.d).
{ echo '-- seed-only: fresh-db'; cat "$T/routes-head.sql"; } > "$GM/worker/jobs/schema.d/0100-routes.sql"
commit "$GM" waiver >/dev/null
OUT=$(cd "$GM" && env -u PR_BODY -u MRSL_ROOT -u MRSL_FILES -u MRSL_ADDED -u MRSL_BASE_SQL -u MRSL_HEAD_SQL \
  bash "$LINT" "$MB" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "M2g: a waiver in the fragment diff gave rc $RC, expected 0: $OUT"
has "M2g waived" "$OUT" "WAIVED"

# M1h: the base tracks schema.sql, the head has fragments only (the blob base).
GH="$T/mh"; mkrepo "$GH"; mkdir -p "$GH/worker/jobs"
cat "$T/0000-fixture.sql" "$T/routes-base.sql" > "$GH/worker/jobs/schema.sql"
MBH=$(commit "$GH" base)
rm -f "$GH/worker/jobs/schema.sql"; mkdir -p "$GH/worker/jobs/schema.d"
cp "$T/0000-fixture.sql" "$GH/worker/jobs/schema.d/0000-fixture.sql"
cp "$T/routes-head.sql" "$GH/worker/jobs/schema.d/0100-routes.sql"
commit "$GH" head >/dev/null
OUT=$(cd "$GH" && env -u PR_BODY -u MRSL_ROOT -u MRSL_FILES -u MRSL_ADDED -u MRSL_BASE_SQL -u MRSL_HEAD_SQL \
  bash "$LINT" "$MBH" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "M1h: blob base, composed head gave rc $RC, expected 1: $OUT"
has "M1h names the role" "$OUT" "fixture.role"

# M6: the merge-base's schema.d does not compose -> rc 2, never an empty base.
G6="$T/m6"; mkrepo "$G6"; mkdir -p "$G6/worker/jobs/schema.d"
cp "$T/routes-base.sql" "$G6/worker/jobs/schema.d/0100-routes.sql"
echo "fixture notes" > "$G6/worker/jobs/schema.d/README"
MB6=$(commit "$G6" base)
rm -f "$G6/worker/jobs/schema.d/README"; cp "$T/routes-head.sql" "$G6/worker/jobs/schema.d/0100-routes.sql"
commit "$G6" head >/dev/null
OUT=$(cd "$G6" && env -u PR_BODY -u MRSL_ROOT -u MRSL_FILES -u MRSL_ADDED -u MRSL_BASE_SQL -u MRSL_HEAD_SQL \
  bash "$LINT" "$MB6" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "M6: an uncomposable base gave rc $RC, expected 2: $OUT"
has "M6 could not run" "$OUT" "could not run"

# ── C: ensure-columns reads a fragment index ────────────────────────────────
SRCJS='worker/jobs/src/lib/core.js'
FRAG='worker/jobs/schema.d/0100-x.sql'
printf '%s\t%s\t%s\n' "$SRCJS" 10 '["fixture_col", "TEXT"]' \
  "$FRAG" 3 'CREATE INDEX IF NOT EXISTS ix ON t(fixture_col)' > "$T/c1.tsv"
OUT=$("$CHK" < "$T/c1.tsv" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C1: rc $RC, expected 1: $OUT"
grep -q "^$FRAG:3	.*fixture_col" <<<"$OUT" && ok || bad "C1: hit not at $FRAG:3: $OUT"

printf '%s\t%s\t%s\n' "$SRCJS" 10 '["fixture_col", "TEXT"]' \
  "$FRAG" 3 'CREATE INDEX IF NOT EXISTS ix ON t(other_col)' > "$T/c2.tsv"
OUT=$("$CHK" < "$T/c2.tsv" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C2: an index on another column gave rc $RC: $OUT"

# C3: the same shape as a diff, through the production runner.
{ printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,0 +1,1 @@\n+%s\n' "$SRCJS" "$SRCJS" "$SRCJS" "$SRCJS" '  t: [["fixture_col", "TEXT"]],'
  printf 'diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,1 @@\n+%s\n' "$FRAG" "$FRAG" "$FRAG" 'CREATE INDEX IF NOT EXISTS ix ON t(fixture_col);'
} > "$T/c3.diff"
OUT=$("$RUN" "$T/c3.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C3: checks-run on a fragment diff gave rc $RC, expected 1: $OUT"
grep -q "^CHECK-HIT worker-schema-ensure-columns $FRAG:1 .*fixture_col" <<<"$OUT" \
  && ok || bad "C3: no CHECK-HIT at $FRAG:1: $OUT"

# ── R: the risk tier ────────────────────────────────────────────────────────
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$T/rt" "$T/tmp"
  : > "$T/rt/catalog.tsv"
  R1OUT=$(
    export TMPDIR="$T/tmp" LA_CATALOG="$T/rt/catalog.tsv"
    setting_get() { return 2; }
    # shellcheck source=bin/lib/risk-tier.sh
    . "$DIR/bin/lib/risk-tier.sh" || exit 1
    jq -nc '{total_commits:1, commits:[], files:[{filename:"worker/jobs/schema.d/0100-x.sql", additions:3, deletions:0, status:"added"}]}' > "$T/rt/r1.json"
    rt_classify "$T/rt/r1.json" example-org/demo-os
  )
  [ "$(cut -f1 <<<"$R1OUT")" = high ] && ok || bad "R1: a fragment is not high: $R1OUT"
  has "R1 reason names the path" "$(cut -f2 <<<"$R1OUT")" "worker/jobs/schema.d/0100-x.sql"
else
  bad "R1: jq missing — rt_classify cannot run"
fi

# ── E: merge-queue batch escalation ────────────────────────────────────────
E1OUT=$(
  # shellcheck source=bin/lib/ci-batch-escalate.sh
  . "$DIR/bin/lib/ci-batch-escalate.sh" || exit 1
  for k in spa worker; do cbe_affects "$k" worker/jobs/schema.d/0100-x.sql && echo "$k=1" || echo "$k=0"; done
  cbe_affects spa worker/jobs/src/x.js && echo "neg=1" || echo "neg=0"
)
has "E1 spa" "$E1OUT" "spa=1"
has "E1 worker" "$E1OUT" "worker=1"
has "E1 negative: a worker source does not gate spa" "$E1OUT" "neg=0"

# ── T: test selection ───────────────────────────────────────────────────────
# A scratch git copy of the committed tree. The selector under test is this
# checkout's bin/test-impact.sh, pointed at the copy with --root.
TT="$T/tree"; mkdir -p "$TT"
if git -C "$DIR" archive HEAD | tar -x -C "$TT" && mkrepo "$TT" && commit "$TT" c0 >/dev/null; then
  "$TI" map --root "$TT" > "$T/map" 2>/dev/null || bad "T: map build failed"
  printf 'CREATE TABLE IF NOT EXISTS fixture_t1 (id INTEGER PRIMARY KEY);\n' > "$TT/worker/jobs/schema.d/0100-fixture.sql"
  commit "$TT" t1 >/dev/null

  # T1: a fragment-only commit selects the suites that read only schema.sql.
  OUT=$("$TI" select HEAD~1..HEAD --root "$TT" --map "$T/map" --why 2>/dev/null); RC=$?
  [ "$RC" = 0 ] && ok || bad "T1: select rc $RC"
  grep -qP '^tests/schema-additive\.bh-1000-test\.sh\t' <<<"$OUT" && ok || bad "T1: schema-additive not selected"
  grep -qP '^tests/d1-schema-split\.bh-1000-test\.sh\t.*\tworker/jobs/schema\.sql$' <<<"$OUT" \
    && ok || bad "T1: d1-schema-split not selected through worker/jobs/schema.sql"

  # T4: the merge queue's --changed path aliases too.
  printf 'worker/jobs/schema.d/0100-fixture.sql\n' > "$T/changed"
  OUT=$("$TI" select --changed "$T/changed" --root "$TT" --map "$T/map" 2>/dev/null); RC=$?
  [ "$RC" = 0 ] && ok || bad "T4: select --changed rc $RC"
  grep -qx 'tests/d1-schema-split.bh-1000-test.sh' <<<"$OUT" && ok || bad "T4: --changed did not select d1-schema-split"

  # T2 + N1: a worker source change and the negative paths alias nothing.
  printf '%s\n' worker/plain/src/index.js worker/jobs/schemax.sql worker/jobs/src/schema.d.js \
    worker/jobs/schema.d/README docs/x.md > "$T/neg"
  OUT=$("$TI" select --changed "$T/neg" --root "$TT" --map "$T/map" --map-only --why 2>/dev/null)
  grep -qP '\tworker/[a-z]+/schema\.sql$' <<<"$OUT" && bad "T2/N1: a negative path was aliased: $(grep -P '\tworker/[a-z]+/schema\.sql$' <<<"$OUT" | head -3)" || ok
  grep -q . <<<"$OUT" && ok || bad "T2/N1: --map-only selected nothing (vacuous)"

  # T3: schema.sql untracked — the index carries the alias, so a suite that
  # names only $DIR/worker/jobs/schema.sql is still selected (a fresh map).
  # Not the `commit` helper here: its `add -A` would track schema.sql again.
  git -C "$TT" rm -q --cached worker/jobs/schema.sql && git -C "$TT" commit -qm untrack
  printf 'CREATE TABLE IF NOT EXISTS fixture_t3 (id INTEGER PRIMARY KEY);\n' > "$TT/worker/jobs/schema.d/0101-fixture.sql"
  git -C "$TT" add worker/jobs/schema.d/0101-fixture.sql && git -C "$TT" commit -qm t3
  git -C "$TT" ls-files --error-unmatch worker/jobs/schema.sql >/dev/null 2>&1 \
    && bad "T3: schema.sql is still tracked in the scratch copy (vacuous)" || ok
  OUT=$("$TI" select HEAD~1..HEAD --root "$TT" --why 2>/dev/null); RC=$?
  [ "$RC" = 0 ] && ok || bad "T3: select rc $RC"
  grep -qP '^tests/d1-schema-split\.bh-1000-test\.sh\t.*\tworker/jobs/schema\.sql$' <<<"$OUT" \
    && ok || bad "T3: with schema.sql untracked, d1-schema-split is not selected"
else
  bad "T: could not build the scratch copy of the tree"
fi

# ── N1: the negative paths trigger neither the seed lint nor the index arm ──
for p in docs/x.md worker/plain/src/x.js worker/jobs/schema.d/README worker/jobs/schemax.sql worker/jobs/src/schema.d.js; do
  lint "$p"
  [ "$RC" = 0 ] && ok || bad "N1: seed lint on $p gave rc $RC: $OUT"
  has "N1 seed lint skips $p" "$OUT" "nothing to check"
  printf '%s\t%s\t%s\n' "$SRCJS" 10 '["fixture_col", "TEXT"]' \
    "$p" 3 'CREATE INDEX IF NOT EXISTS ix ON t(fixture_col)' > "$T/n1.tsv"
  OUT=$("$CHK" < "$T/n1.tsv" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "N1: ensure-columns fired on $p: $OUT"
done

# ── K: this child keeps schema.sql tracked and stays out of the contract ────
# PR-scoped: only while this ticket's commits are on the branch (BH-5684).
K_FILES=$(git -C "$DIR" log --format= --name-only --grep='^BH-6009' origin/main..HEAD 2>/dev/null | sort -u)
if [ -z "$K_FILES" ]; then
  echo "K1/K2: skip — no BH-6009 commit in origin/main..HEAD (merged, or no origin/main here)"
else
  git -C "$DIR" ls-files --error-unmatch worker/jobs/schema.sql >/dev/null 2>&1 \
    && ok || bad "K1: worker/jobs/schema.sql is no longer tracked"
  K2=$(grep -E '^(bin/schema-build\.sh|bin/harness-sync\.sh|bin/lib/mc/|tests/lib/|tests/schema-additive\.bh-1000-test\.sh)' <<<"$K_FILES")
  [ -z "$K2" ] && ok || bad "K2: this ticket touched a file it must not: $K2"
fi

echo "schema-compose-ci.bh-6005-2: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
