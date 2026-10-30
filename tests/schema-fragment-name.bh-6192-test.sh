#!/bin/bash
# tests/schema-fragment-name.bh-6192-test.sh — the rules pack refuses EVERY new
# NNNN schema.d fragment, not only a number the base already has (BH-6192).
#
# WHY. BH-5788 let a new NNNN fragment on a free number pass the pack and only
# NOTED it (self-check row body-schema-stamp), so the PRs then open with an
# NNNN fragment stayed green. Those PRs drained; a free number is still a
# picked number, and the next build picks it too. The stamp form
# <yyyymmddhhmm>-<ticket-key>-<name>.sql is the only new name.
# rp_schema_fragment_name (bin/lib/rules-pack-checks.sh):
#   F1 an added NNNN fragment on a free number is one finding, rc 1
#   F2 the same fragment untracked is the same one finding
#   F3 a free number under another worker is one finding
#   F4 a base fragment renamed to a free NNNN number is one finding (new path)
#   F5 a reused base number keeps its "already taken" line, one finding only
#   F6 a stamp-form fragment, an edit, a delete, a file outside schema.d/ and a
#      base NNNN fragment renamed to the stamp form are clean
#   F7 a 5-digit number and a number with no name are findings
# The real entry points:
#   F8 bin/rules-pack.sh --only schema-fragment-name is red on F1's tree
#   F9 the self-check row body-schema-stamp is off and prints nothing
# Fixture repos only, fixed commit dates. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-fragment-name.bh-6192-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
SD=worker/jobs/schema.d
OD=worker/other/schema.d
MSG='schema-fragment-name: a new fragment is named <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key), never a picked number'
TAKEN() { printf '%s: schema-fragment-name: number %s is already taken at the base by %s; name a new fragment <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key)' "$1" "$2" "$3"; }

# fixture <tag> — a repo with two NNNN fragments under jobs and one under other.
fixture() {
  R="$T/$1"; scratch_rm "$R"; mkdir -p "$R/$SD" "$R/$OD" "$R/docs"
  printf '%s\n' 'CREATE TABLE probe_a (id INTEGER);' > "$R/$SD/0000-base.sql"
  printf '%s\n' 'CREATE TABLE probe_b (id INTEGER);' > "$R/$SD/0001-bh-1-b.sql"
  printf '%s\n' 'CREATE TABLE probe_c (id INTEGER);' > "$R/$OD/0000-base.sql"
  git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
lint() { OUT=$(rp_schema_fragment_name "$R" "$BASE" 2>"$T/err"); RC=$?; }
add() { printf '%s\n' 'CREATE TABLE probe_n (id INTEGER);' > "$R/$1"; }

# ── F1-F4 a new NNNN fragment on a free number is a finding ─────────────────
fixture f1; add "$SD/0002-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm f1; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/0002-bh-9001-x.sql: $MSG" ] && ok \
  || bad "F1 an added NNNN fragment on a free number must be one finding: rc $RC out [$OUT]"
fixture f2; add "$SD/0002-bh-9001-x.sql"; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/0002-bh-9001-x.sql: $MSG" ] && ok \
  || bad "F2 an untracked NNNN fragment on a free number must be one finding: rc $RC out [$OUT]"
fixture f3; add "$OD/0007-bh-9001-x.sql"; git -C "$R" add -A; lint
[ "$RC" = 1 ] && [ "$OUT" = "$OD/0007-bh-9001-x.sql: $MSG" ] && ok \
  || bad "F3 a free number under another worker must be one finding: rc $RC out [$OUT]"
fixture f4; git -C "$R" mv "$SD/0001-bh-1-b.sql" "$SD/0002-bh-1-b.sql"; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/0002-bh-1-b.sql: $MSG" ] && ok \
  || bad "F4 a fragment renumbered to a free number must be one finding on the new path: rc $RC out [$OUT]"

# ── F5 near miss: a reused base number keeps the specific line ──────────────
fixture f5; add "$SD/0001-bh-9001-x.sql"; git -C "$R" add -A; lint
[ "$RC" = 1 ] && [ "$OUT" = "$(TAKEN "$SD/0001-bh-9001-x.sql" 0001 "$SD/0001-bh-1-b.sql")" ] && ok \
  || bad "F5 a reused base number must be one TAKEN finding (not two): rc $RC out [$OUT]"

# ── F6 the clean side ──────────────────────────────────────────────────────
fixture f6a; add "$SD/202610301200-bh-9001-x.sql"; git -C "$R" add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F6 a stamp-form fragment must be clean: rc $RC out [$OUT]"
fixture f6b; printf '%s\n' 'CREATE INDEX probe_ix ON probe_b(id);' >> "$R/$SD/0001-bh-1-b.sql"; add "docs/0002-x.sql"; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F6 an edit to a base NNNN fragment and a file outside schema.d must be clean: rc $RC out [$OUT]"
fixture f6c; git -C "$R" rm -q "$SD/0001-bh-1-b.sql"; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F6 a deleted fragment must be clean: rc $RC out [$OUT]"
fixture f6d; git -C "$R" mv "$SD/0001-bh-1-b.sql" "$SD/202610301200-bh-1-b.sql"; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "F6 a base NNNN fragment renamed to the stamp form must be clean: rc $RC out [$OUT]"

# ── F7 near-miss names ─────────────────────────────────────────────────────
for n in 00002-x.sql 0002.sql; do
  fixture "f7-${n%%.*}"; add "$SD/$n"; git -C "$R" add -A; lint
  [ "$RC" = 1 ] && [ "$OUT" = "$SD/$n: $MSG" ] && ok || bad "F7 [$n] must be one finding: rc $RC out [$OUT]"
done

# ── F8 the real rules pack ─────────────────────────────────────────────────
mkdir -p "$T/nolg"
fixture p1; add "$SD/0002-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm red
env HARNESS="$T/nolg" bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$BASE" --runner local \
  --out "$T/o1" --only schema-fragment-name >"$T/pack.out" 2>"$T/pack.err"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$T/pack.out")" = "schema-fragment-name: $SD/0002-bh-9001-x.sql: $MSG" ] && ok \
  || bad "F8 the pack must refuse a free-number NNNN fragment: rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"

# ── F9 the self-check row is off ───────────────────────────────────────────
N=$(grep -c $'^body-schema-stamp\toff\t' "$DIR/catalog/pr-self-check.tsv")
[ "$N" = 1 ] && ok || bad "F9 catalog/pr-self-check.tsv must carry one body-schema-stamp row in mode off (got $N)"
printf '## Why\nA fixture.\n' > "$T/body.md"
( cd "$R" && PR_SELF_CHECK_CATALOG="$DIR/catalog/pr-self-check.tsv" bash "$DIR/bin/pr-self-check.sh" check --repo . \
    --base "$BASE" --head HEAD --body "$T/body.md" --only '^body-schema-stamp$' ) >"$T/psc.out" 2>&1; RC=$?
[ "$RC" = 0 ] && ! grep -q 'body-schema-stamp' "$T/psc.out" && ok \
  || bad "F9 the self-check must print no body-schema-stamp line: rc $RC [$(cat "$T/psc.out")]"

echo "schema-fragment-name.bh-6192: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
