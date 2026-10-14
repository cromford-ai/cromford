#!/bin/bash
# tests/d1-schema-split.bh-1000-test.sh — the REAL worker/jobs/schema.sql, split
# by bin/lib/d1-schema.sh and APPLIED one statement at a time.
# Run from anywhere: bash tests/d1-schema-split.bh-1000-test.sh (exit 0 = pass)
#
# WHY (BH-1000). harness-sync now applies a worker's schema BEFORE it deploys
# the worker, one `wrangler d1 execute --command "<stmt>"` per statement,
# because `--file` fails under the hub's OAuth login (Authentication error
# [code: 10000]). That makes the SPLITTER load-bearing: a splitter that cut on
# every `;` would hand D1 half of the seed's ';'-bearing note ('one ticket, one
# claim, fleet-wide; the TK-66/67 …' — BH-1279 moved it onto the ticket row when
# the repo/box seed rows were removed) as a statement, the apply would fail
# mid-file and
# the deploy would be skipped on every run after that. A regex over the file
# cannot prove the pieces are valid SQL, so every piece is EXECUTED — against
# node:sqlite, with the same availability skip worker/jobs/test/settings-schema.test.js
# uses (sqlite3 is not installed on the boxes).
#
# The SECOND pass is the other half: the apply runs on every deploy whose
# worker tree sha moved, so each statement must be re-appliable and no re-apply
# may reset a knob an operator edited.
#
# Self-contained on purpose: it creates no files, runs no rm, sets no trap and
# never cd's, so it needs no scratch tree (checks/tests-scratch-only R1) and it
# runs identically with or without HARNESS_TEST_SANDBOX. No network, no clock,
# no randomness.
set -uo pipefail
ROOT=$(readlink -f "$(dirname "$0")/..")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v node >/dev/null || { echo "d1-schema-split.bh-1000-test: SKIP — node missing"; exit 0; }
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
SCHEMA="$ROOT/worker/jobs/schema.sql"
[ -r "$SCHEMA" ] || { echo "d1-schema-split.bh-1000-test: no $SCHEMA"; exit 1; }
# shellcheck source=bin/lib/d1-schema.sh
. "$ROOT/bin/lib/d1-schema.sh" || exit 1

COUNT=$(d1_schema_statements "$SCHEMA" | tr -dc '\0' | wc -c | tr -d ' ')

# The count, cross-checked WITHOUT the splitter: every statement in this file
# starts at column 0 with its verb, so the verb lines and the emitted pieces
# must be the same number. A splitter that merged two statements, or cut one in
# half, breaks that equality — and nobody has to maintain a magic number that
# goes stale the next time the schema grows a table.
KEYWORD_LINES=$(grep -cE '^(CREATE|INSERT|ALTER|DROP|PRAGMA|UPDATE|DELETE)[[:space:]]' "$SCHEMA")
[ "$COUNT" -gt 0 ] && ok || bad "the splitter produced no statements at all"
[ "$COUNT" = "$KEYWORD_LINES" ] \
  && ok || bad "split produced $COUNT statements but the file opens $KEYWORD_LINES statements at column 0"

# The literal that must not be cut. If this line ever leaves the schema the
# suite is no longer testing what it says it tests.
grep -q "fleet-wide; the TK-66/67" "$SCHEMA" \
  && ok || bad "fixture drift: schema.sql no longer holds the ';'-bearing string literal this suite is about"

APPLY=$(cat <<'NODEJS'
const fs = require("fs");
let DatabaseSync;
try { ({ DatabaseSync } = require("node:sqlite")); }
catch { console.log("SKIP node:sqlite unavailable"); process.exit(0); }

const parts = fs.readFileSync(process.argv[1]).toString("utf8").split("\0").filter((s) => s.length > 0);
console.log("COUNT=" + parts.length);
const db = new DatabaseSync(":memory:");
function applyAll(n) {
  for (let i = 0; i < parts.length; i++) {
    try {
      db.exec(parts[i]);
    } catch (e) {
      console.log("ERR pass" + n + " statement " + (i + 1) + "/" + parts.length + ": " + String(e && e.message).slice(0, 200));
      console.log("ERR_SQL: " + parts[i].split("\n")[0]);
      process.exit(1);
    }
  }
  console.log("APPLIED" + n + "=ok");
}
const named = (t) => db.prepare("SELECT name FROM sqlite_master WHERE name=?").get(t);
const seed = () => db.prepare("SELECT value FROM settings WHERE key='gh_budget_min_remaining'").get();

applyAll(1);
console.log("TABLE_hub_lease=" + (named("hub_lease") ? "yes" : "no"));
console.log("TABLE_settings=" + (named("settings") ? "yes" : "no"));
const s1 = seed();
console.log("SEED1=" + (s1 ? s1.value : "MISSING"));
applyAll(2);
const s2 = seed();
console.log("SEED2=" + (s2 ? s2.value : "MISSING"));
console.log("SEEDROWS=" + db.prepare("SELECT COUNT(*) AS c FROM settings WHERE key='gh_budget_min_remaining'").get().c);
NODEJS
)

# node reads the statements from a process substitution, so this suite writes
# nothing to disk and the recorded rc is node's own, not a pipeline's.
OUT=$(node -e "$APPLY" <(d1_schema_statements "$SCHEMA") 2>&1)
NRC=$?
case "$OUT" in
  # node:sqlite is Node >= 22, and CI, docker and the boxes are on Node 20 — so
  # this arm is the NORMAL path there, and a bare `exit 0` threw away the three
  # assertions above it (count > 0, count = keyword lines, the ';'-bearing
  # literal is still in the file). A splitter regression that merged two
  # statements was then green everywhere but a Node >= 22 laptop. The
  # SQLite half is skipped; what already ran still decides the exit code.
  SKIP*)
    echo "d1-schema-split.bh-1000-test: $PASS pass, $FAIL fail (SKIP — node:sqlite unavailable; the shell-side splitter checks still ran)"
    [ "$FAIL" -eq 0 ]; exit $? ;;
esac
has() { grep -q "$1" <<<"$OUT"; }

[ "$NRC" = 0 ] && ok || bad "applying the split statements failed (rc=$NRC): $OUT"
has "^COUNT=$COUNT\$" \
  && ok || bad "node counted a different number of statements than the shell did (shell says $COUNT): $OUT"
has '^APPLIED1=ok$' \
  && ok || bad "pass 1: not every statement executed: $OUT"
has '^APPLIED2=ok$' \
  && ok || bad "pass 2: re-applying the same statements failed: $OUT"
has '^TABLE_hub_lease=yes$' \
  && ok || bad "hub_lease is missing from sqlite_master after pass 1 — the table the outage was about"
has '^TABLE_settings=yes$' \
  && ok || bad "settings is missing from sqlite_master after pass 1"
has '^SEED1=800$' \
  && ok || bad "the gh_budget_min_remaining seed did not land in pass 1: $OUT"
S1=$(printf '%s\n' "$OUT" | sed -n 's/^SEED1=//p')
S2=$(printf '%s\n' "$OUT" | sed -n 's/^SEED2=//p')
[ -n "$S1" ] && [ "$S1" = "$S2" ] \
  && ok || bad "the gh_budget_min_remaining seed changed across a second apply: '$S1' -> '$S2'"
has '^SEEDROWS=1$' \
  && ok || bad "a second apply duplicated the gh_budget_min_remaining row: $OUT"

echo "d1-schema-split.bh-1000-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
