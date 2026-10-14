#!/bin/bash
# tests/worker-schema-upgrade.bh-2473-test.sh — schema.sql must apply OVER
# main's schema.sql, not only to a fresh database (BH-2473).
#
# #2462 (BH-2303) added `CREATE INDEX … ON cost_rows(lane_id, ts)` to
# worker/jobs/schema.sql while `lane_id` reached live D1 only through
# ensureColumns, which runs AFTER deploy. bin/harness-sync.sh applies schema.sql
# BEFORE `wrangler deploy`, so the index failed with `no such column` and every
# deploy after it was skipped. Every schema test in CI applied the file to a
# FRESH database, where the CREATE TABLE makes every column, so none saw it.
#
# This suite drives bin/worker-schema-upgrade.sh (the replay CI runs over the
# PR's base) end to end on real SQL, and the #2462 shape through
# bin/checks-run.sh's catalog entry checks/worker-schema-ensure-columns/check.sh.
# It reads "$ROOT/worker/jobs/schema.sql" (R3), so bin/test-impact.sh picks it
# on every schema.sql change: that is the pre-PR mirror of the CI step.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
UP="$ROOT/bin/worker-schema-upgrade.sh"
RUN="$ROOT/bin/checks-run.sh"
CHK="$ROOT/checks/worker-schema-ensure-columns/check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -x "$UP" ] && ok || bad "bin/worker-schema-upgrade.sh missing or not executable"
[ -x "$CHK" ] && ok || bad "checks/worker-schema-ensure-columns/check.sh missing or not executable"

# ── fixtures ────────────────────────────────────────────────────────────────
cat > "$T/base.sql" <<'EOF'
-- main: cost_rows as the live database has it
CREATE TABLE IF NOT EXISTS cost_rows (
  id INTEGER PRIMARY KEY,
  ts TEXT NOT NULL,
  usd REAL
);
EOF
cat > "$T/head.sql" <<'EOF'
-- the PR: lane_id added to the CREATE (fresh databases) and indexed
CREATE TABLE IF NOT EXISTS cost_rows (
  id INTEGER PRIMARY KEY,
  ts TEXT NOT NULL,
  usd REAL,
  lane_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_cost_rows_lane_ts ON cost_rows(lane_id, ts);
EOF
: > "$T/empty.sql"

# ── R1: the #2462 shape fails over main's schema ────────────────────────────
OUT=$("$UP" --files "$T/base.sql" "$T/head.sql" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R1: rc $RC over base, expected 1: $OUT"
grep -q 'SCHEMA-UPGRADE FAIL .* statement 2/2: no such column: lane_id :: CREATE INDEX IF NOT EXISTS idx_cost_rows_lane_ts' <<<"$OUT" \
  && ok || bad "R1: statement 2/2 and 'no such column: lane_id' not named: $OUT"
grep -q '^SCHEMA-UPGRADE: 1 statement(s) fail' <<<"$OUT" && ok || bad "R1: no failing summary line: $OUT"
grep -q 'SCHEMA-UPGRADE: ok' <<<"$OUT" && bad "R1: printed ok on a failing upgrade: $OUT" || ok

# ── R2: the same head on a FRESH database passes — the replay is what catches it
OUT=$("$UP" --files "$T/empty.sql" "$T/head.sql" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R2: fresh-db path rc $RC, expected 0: $OUT"
grep -q '^SCHEMA-UPGRADE: ok' <<<"$OUT" && ok || bad "R2: no ok summary: $OUT"

# ── R3: today's main passes over its own merge base (the --base production path)
if BASE=$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null) && [ -n "$BASE" ]; then
  [ -r "$ROOT/worker/jobs/schema.sql" ] && ok || bad "R3: $ROOT/worker/jobs/schema.sql unreadable"
  OUT=$("$UP" --base "$BASE" --root "$ROOT" 2>&1); RC=$?
  [ "$RC" = 0 ] && ok || bad "R3: main's schema.sql over its merge base: rc $RC: $OUT"
  # The ok line lists every worker with a schema.sql (alphabetical), so jobs is
  # not necessarily first.
  grep -Eq '^SCHEMA-UPGRADE: ok \(.*\bjobs: base [1-9][0-9]* \+ head [1-9][0-9]* statements' <<<"$OUT" \
    && ok || bad "R3: summary does not name the jobs worker's counts: $OUT"
  # An unresolvable ref is could-not-run, never a pass.
  OUT=$("$UP" --base no-such-ref-bh2473 --root "$ROOT" 2>&1); RC=$?
  [ "$RC" = 2 ] && ok || bad "R3: unresolvable ref gave rc $RC, expected 2: $OUT"
else
  echo "R3: DID NOT RUN — origin/main is not resolvable here (shallow checkout); the CI step is the authoritative run. Not counted as a pass."
fi

# ── R3b: --base over a scratch repo — a worker absent at the ref is NEW, and a
# ref that has it is replayed. This is the git path without origin/main.
G="$T/repo"; mkdir -p "$G/worker/jobs" "$G/bin"
git -C "$G" init -q && git -C "$G" config user.email t@t && git -C "$G" config user.name t
echo "x" > "$G/README"; git -C "$G" add README; git -C "$G" commit -qm init
cp "$T/base.sql" "$G/worker/jobs/schema.sql"
OUT=$("$UP" --base HEAD --root "$G" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R3b: new worker rc $RC, expected 0: $OUT"
grep -q 'NEW worker' <<<"$OUT" && ok || bad "R3b: a worker absent at the ref is not called new: $OUT"
git -C "$G" add worker; git -C "$G" commit -qm base
cp "$T/head.sql" "$G/worker/jobs/schema.sql"
OUT=$("$UP" --base HEAD --root "$G" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R3b: #2462 shape over a git base: rc $RC, expected 1: $OUT"
grep -q 'SCHEMA-UPGRADE FAIL worker/jobs/schema.sql statement 2/2: no such column: lane_id' <<<"$OUT" \
  && ok || bad "R3b: failure not named against worker/jobs/schema.sql: $OUT"
mkdir -p "$T/noworkers"
OUT=$("$UP" --base HEAD --root "$T/noworkers" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "R3b: a root with no worker schema gave rc $RC, expected 2: $OUT"

# ── R4: main's own schema failing is could-not-run, not a pass and not a fail
printf 'CREATE TABLE t (a TEXT);\nCREATE INDEX i ON t(nope);\n' > "$T/badbase.sql"
OUT=$("$UP" --files "$T/badbase.sql" "$T/head.sql" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "R4: failing base gave rc $RC, expected 2: $OUT"
grep -q 'SCHEMA-UPGRADE: ok' <<<"$OUT" && bad "R4: printed ok: $OUT" || ok

# ── R5: an empty head is could-not-run (0 statements), as is an unreadable one
OUT=$("$UP" --files "$T/base.sql" "$T/empty.sql" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "R5: empty head gave rc $RC, expected 2: $OUT"
grep -q '0 statements' <<<"$OUT" && ok || bad "R5: does not say 0 statements: $OUT"
OUT=$("$UP" --files "$T/base.sql" "$T/missing.sql" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "R5: missing head gave rc $RC, expected 2: $OUT"
OUT=$("$UP" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "R5: no arguments gave rc $RC, expected 2"

# ── R6: the shared splitter is in use — a trigger body and a ';' in a literal
cat > "$T/trig.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS cost_rows (id INTEGER PRIMARY KEY, ts TEXT NOT NULL, usd REAL);
CREATE TABLE IF NOT EXISTS audit (note TEXT);
INSERT OR IGNORE INTO audit (note) VALUES ('ids are ;-joined; keep it');
CREATE TRIGGER IF NOT EXISTS cost_rows_ai AFTER INSERT ON cost_rows
BEGIN
  INSERT INTO audit (note) VALUES ('row; added');
  UPDATE audit SET note = note WHERE 0;
END;
EOF
OUT=$("$UP" --files "$T/base.sql" "$T/trig.sql" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R6: trigger + literal ';' gave rc $RC, expected 0 (naive split?): $OUT"
grep -q 'head 4 statements' <<<"$OUT" && ok || bad "R6: head did not split into 4 statements: $OUT"

# ── R7: every failing head statement is named, not only the first
cat > "$T/two.sql" <<'EOF'
CREATE INDEX IF NOT EXISTS idx_a ON cost_rows(lane_id);
CREATE TABLE IF NOT EXISTS other (x TEXT);
CREATE INDEX IF NOT EXISTS idx_b ON cost_rows(job_id);
EOF
OUT=$("$UP" --files "$T/base.sql" "$T/two.sql" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "R7: rc $RC, expected 1: $OUT"
grep -q 'statement 1/3: no such column: lane_id' <<<"$OUT" && ok || bad "R7: first failure not named: $OUT"
grep -q 'statement 3/3: no such column: job_id' <<<"$OUT" && ok || bad "R7: second failure not named: $OUT"
grep -q '^SCHEMA-UPGRADE: 2 statement(s) fail' <<<"$OUT" && ok || bad "R7: summary does not count 2: $OUT"

# ── C: the checks/ catalog entry, through the production runner ────────────
# C1: the #2462 shape in one diff fires; C2..C5 are the adversarial negatives
# that must NOT park a PR in merge-sweep.
mkdiff() { # <path> <added lines...> — a one-hunk unified diff adding lines
  local p="$1"; shift
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,0 +1,%d @@\n' "$p" "$p" "$p" "$p" "$#"
  local l; for l in "$@"; do printf '+%s\n' "$l"; done
}
SRC='worker/jobs/src/lib/core.js'
SQL='worker/jobs/schema.sql'
TUPLE='  cost_rows: [["lane_id", "TEXT"]],'
IDX='CREATE INDEX IF NOT EXISTS idx_cost_rows_lane_ts ON cost_rows(lane_id, ts);'

{ mkdiff "$SRC" "$TUPLE"; mkdiff "$SQL" "$IDX"; } > "$T/c1.diff"
OUT=$("$RUN" "$T/c1.diff" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C1: #2462 shape rc $RC, expected 1: $OUT"
grep -q "^CHECK-HIT worker-schema-ensure-columns $SQL:1 .*lane_id" <<<"$OUT" \
  && ok || bad "C1: no hit naming lane_id at $SQL:1: $OUT"

# C2: the column added only in a NEW table's CREATE — no tuple in src.
{ mkdiff "$SQL" 'CREATE TABLE IF NOT EXISTS lane_costs (lane_id TEXT, ts TEXT);' \
    'CREATE INDEX IF NOT EXISTS idx_lc ON lane_costs(lane_id, ts);'; } > "$T/c2.diff"
OUT=$("$RUN" "$T/c2.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C2: new-table index fired (rc $RC): $OUT"

# C3: a tuple of the same shape outside worker/*/src/ (console-ui, bin).
{ mkdiff 'console-ui/src/lib/cols.js' "$TUPLE"; mkdiff 'bin/x.js' "$TUPLE"; mkdiff "$SQL" "$IDX"; } > "$T/c3.diff"
OUT=$("$RUN" "$T/c3.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C3: a tuple outside worker/*/src fired (rc $RC): $OUT"

# C4: an index with no ADDED_COLUMNS change in the diff.
mkdiff "$SQL" "$IDX" > "$T/c4.diff"
OUT=$("$RUN" "$T/c4.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C4: an index alone fired (rc $RC): $OUT"

# C5: a commented-out index, and another project's diff with no schema.sql.
{ mkdiff "$SRC" "$TUPLE"; mkdiff "$SQL" "-- $IDX"; } > "$T/c5.diff"
OUT=$("$RUN" "$T/c5.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C5: a commented-out index fired (rc $RC): $OUT"
{ mkdiff 'src/lib/cols.ts' "$TUPLE"; mkdiff 'prisma/schema.sql' "$IDX"; } > "$T/c6.diff"
OUT=$("$RUN" "$T/c6.diff" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C6: another project's diff fired (rc $RC): $OUT"

# C7: the check on its own, on the normalized stream — UNIQUE index, other table.
printf '%s\t%s\t%s\n' "$SRC" 10 '  model_prices: [["tier", "TEXT"]],' \
  "$SQL" 20 'CREATE UNIQUE INDEX IF NOT EXISTS ux ON model_prices (tier);' > "$T/c7.tsv"
OUT=$("$CHK" < "$T/c7.tsv" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "C7: unique index on an ensureColumns column rc $RC: $OUT"
grep -q "^$SQL:20	.*tier" <<<"$OUT" && ok || bad "C7: hit not at $SQL:20 naming tier: $OUT"

echo "worker-schema-upgrade.bh-2473: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
