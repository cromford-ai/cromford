#!/bin/bash
# tests/schema-fragment-name.bh-5788-test.sh — a NEW schema.d fragment is named
# by its ticket key, ordered by a recorded stamp: `<yyyymmddhhmm>-<key>-<name>.sql`
# (BH-5788).
#
# WHY. A number picked as "the next free one" collides: main holds two 0022
# fragments on 2026-10-14. The ticket key makes the name unique; the UTC minute
# the builder creates the file is the order key, so a plain LC_ALL=C name sort
# still composes the schema (old NNNN fragments first, then by stamp).
# rp_schema_fragment_name (bin/lib/rules-pack-checks.sh):
#   N1 an added NNNN fragment whose number the base already has is a finding
#      that names the base fragment (tracked, untracked, any worker)
#   N2 a name in neither form is a finding
#   N3 a stamp equal to or earlier than the newest stamp-key fragment of the
#      same worker at the base is clean when it uses none of its tables, and a
#      finding that names that fragment when it does (BH-7229)
#   N4 a stamp that is not a real UTC minute (month 13, day 32, hour 24, ...)
#      is a finding
#   N5 an added NNNN fragment on a free number (or renumbered to one) is a
#      finding too (BH-6192)
#   N6 a later stamp is clean (another worker's stamps do not count); the
#      first stamp in a worker with only NNNN fragments is clean; edits,
#      deletes and files outside schema.d/ are clean; no base is rc 125
#   N7 an untracked new fragment is judged like an added one
# bin/schema-build.sh:
#   N8 a stamp-key fragment composes after every NNNN one, in stamp order; a
#      key-only name, a short stamp, an upper-case key and an 8-digit date are
#      refused with `not a fragment name`
# Catalog rows and the real entry points:
#   N9 the self-check row body-schema-stamp is off (BH-6192) and silent on a
#      new NNNN fragment and a stamp-form one; the rules-pack row runs through
#      bin/rules-pack.sh, green on a clean diff and red on a reused number
# Fixture repos only, fixed commit dates. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/schema-fragment-name.bh-5788-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# shellcheck source=../bin/lib/rules-pack-checks.sh
. "$DIR/bin/lib/rules-pack-checks.sh" || { echo "FAIL: cannot source bin/lib/rules-pack-checks.sh"; exit 1; }
command -v rp_schema_fragment_name >/dev/null 2>&1 || bad "rp_schema_fragment_name is not defined in bin/lib/rules-pack-checks.sh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_AUTHOR_DATE="@1700000000 +0000" GIT_COMMITTER_DATE="@1700000000 +0000"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
SD=worker/jobs/schema.d
MSG='schema-fragment-name: a new fragment is named <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key), never a picked number'

# ── N8 the composer ────────────────────────────────────────────────────────
# compose <tag> <file>... — a scratch tree with the composer's closure and the
# named fragments (each holds one table named for its file); sets RC, OUT, ERR.
compose() {
  local W="$T/c-$1" f; shift
  mkdir -p "$W/$SD"
  scratch_install_closure bin/schema-build.sh "$W" >/dev/null || { echo "FAIL: closure install"; exit 1; }
  for f in "$@"; do printf 'CREATE TABLE t_%s (id INTEGER);\n' "$(printf '%s' "${f%.sql}" | tr -c 'a-z0-9\n' '_')" > "$W/$SD/$f"; done
  OUT=$( cd "$W" && bin/schema-build.sh --worker jobs 2>"$T/err" ); RC=$?; ERR=$(cat "$T/err")
}
tables() { printf '%s\n' "$OUT" | sed -n 's/^CREATE TABLE t_\([a-z0-9_]*\) .*/\1/p' | tr '\n' ' '; }

compose n1 0000-base.sql 0019-bh-5653-x.sql 202610121200-bh-9001-probe.sql
[ "$RC" = 0 ] && ok || bad "N8 a stamp-key fragment must compose, rc $RC err [$ERR]"
[ "$(tables)" = "0000_base 0019_bh_5653_x 202610121200_bh_9001_probe " ] && ok \
  || bad "N8 order [$(tables)] (want the NNNN fragments first, then the stamp-key one)"

compose n2 0000-base.sql 202610121200-bh-9001-late.sql 202610110900-bh-9999-early.sql 202610121200-bh-6005-4-tie.sql
[ "$RC" = 0 ] && ok || bad "N8 rc $RC err [$ERR]"
[ "$(tables)" = "0000_base 202610110900_bh_9999_early 202610121200_bh_6005_4_tie 202610121200_bh_9001_late " ] && ok \
  || bad "N8 order [$(tables)] (want stamp order, then name order within one minute)"

for n in bh-9001-probe.sql 2026101212-bh-9001-probe.sql 202610121200-BH-9001-probe.sql 20261014-x.sql; do
  compose "n3-${n%%.*}" 0000-base.sql "$n"
  [ "$RC" = 1 ] && grep -qF "$SD/$n: not a fragment name" <<<"$ERR" && ok \
    || bad "N8 the composer must refuse [$n], rc $RC err [$ERR]"
done

# ── N1-N7 the lint ───────────────────────────────────────────────────────────────
# fixture <tag> — a repo with two NNNN fragments under jobs and one under cloud.
fixture() {
  R="$T/$1"; scratch_rm "$R"; mkdir -p "$R/$SD" "$R/worker/other/schema.d" "$R/docs"
  printf '%s\n' 'CREATE TABLE probe_a (id INTEGER);' > "$R/$SD/0000-base.sql"
  printf '%s\n' 'CREATE TABLE probe_b (id INTEGER);' > "$R/$SD/0001-bh-1-b.sql"
  printf '%s\n' 'CREATE TABLE probe_c (id INTEGER);' > "$R/worker/other/schema.d/0000-base.sql"
  git init -q -b main "$R"; git -C "$R" add -A; git -C "$R" commit -qm base
  BASE=$(git -C "$R" rev-parse HEAD)
}
lint() { OUT=$(rp_schema_fragment_name "$R" "$BASE" 2>"$T/err"); RC=$?; }
add() { printf '%s\n' 'CREATE TABLE probe_n (id INTEGER);' > "$R/$1"; }

# A new NNNN fragment whose number the base already has: the real collision.
TAKEN() { printf '%s: schema-fragment-name: number %s is already taken at the base by %s; name a new fragment <yyyymmddhhmm>-<ticket-key>-<name>.sql (the UTC minute you create it, then the key)' "$1" "$2" "$3"; }
fixture a; add "$SD/0001-bh-9001-x.sql"; git -C "$R" add -A; lint
[ "$RC" = 1 ] && [ "$OUT" = "$(TAKEN "$SD/0001-bh-9001-x.sql" 0001 "$SD/0001-bh-1-b.sql")" ] && ok \
  || bad "N1 a new fragment reusing a base number: rc $RC out [$OUT] (want one finding)"
fixture b; add "$SD/0000-x.sql"; lint
[ "$RC" = 1 ] && [ "$OUT" = "$(TAKEN "$SD/0000-x.sql" 0000 "$SD/0000-base.sql")" ] && ok \
  || bad "N7 an untracked fragment reusing a base number: rc $RC out [$OUT] (want one finding)"
fixture c; add "worker/other/schema.d/0000-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm c; lint
[ "$RC" = 1 ] && [ "$OUT" = "$(TAKEN worker/other/schema.d/0000-x.sql 0000 worker/other/schema.d/0000-base.sql)" ] && ok \
  || bad "N1 a reused number under another worker: rc $RC out [$OUT]"
for n in 202610121200-probe.sql 202613121200-bh-9001-x.sql 202610321200-bh-9001-x.sql \
         202610122400-bh-9001-x.sql 202610121260-bh-9001-x.sql 199910121200-bh-9001-x.sql; do
  fixture "d-${n%%-*}"; add "$SD/$n"; git -C "$R" add -A; lint
  [ "$RC" = 1 ] && [ "$OUT" = "$SD/$n: $MSG" ] && ok || bad "N4 [$n] must be a finding, rc $RC out [$OUT]"
done
# A name in neither form.
fixture n2; add "$SD/x.sql"; git -C "$R" add -A; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/x.sql: $MSG" ] && ok || bad "N2 [x.sql] must be a finding, rc $RC out [$OUT]"
# Untracked is judged like added: a bad untracked name is a finding too.
fixture n7u; add "$SD/202613121200-bh-9001-x.sql"; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/202613121200-bh-9001-x.sql: $MSG" ] && ok \
  || bad "N7 an untracked bad stamp must be a finding, rc $RC out [$OUT]"
# ── N5 a new NNNN fragment on a FREE number: refused by the pack, and the
# self-check row body-schema-stamp is off ────────────────────────────────────
# TEST-CHANGE (BH-6192): N5 pinned "a free-number NNNN fragment passes the pack"
# while open NNNN PRs drained. They drained; the ticket makes every new NNNN
# fragment a finding (the generic line), renumbered ones included.
fixture n7; add "$SD/0002-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm n7; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/0002-bh-9001-x.sql: $MSG" ] && ok || bad "N5 a new NNNN fragment on a free number must be refused by the pack, rc $RC out [$OUT]"
fixture n7r; git -C "$R" mv "$SD/0001-bh-1-b.sql" "$SD/0002-bh-1-b.sql"; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/0002-bh-1-b.sql: $MSG" ] && ok || bad "N5 a fragment renumbered to a free number must be refused by the pack, rc $RC out [$OUT]"
# TEST-CHANGE (BH-6192): N9 pinned the body-schema-stamp row in mode note; the
# pack refuses now, so the ticket sets the row to off.
N=$(grep -c $'^body-schema-stamp\toff\tadded=worker/\*/schema.d/\[0-9\]\[0-9\]\[0-9\]\[0-9\]-\*.sql\t' "$DIR/catalog/pr-self-check.tsv")
[ "$N" = 1 ] && ok || bad "N9 catalog/pr-self-check.tsv must carry one body-schema-stamp off row on added NNNN fragments (got $N)"
printf '## Why\nA fixture.\n' > "$T/body.md"
psc() { # psc <repo> — the real self-check, this row only
  ( cd "$1" && PR_SELF_CHECK_CATALOG="$DIR/catalog/pr-self-check.tsv" bash "$DIR/bin/pr-self-check.sh" check --repo . \
      --base "$BASE" --head HEAD --body "$T/body.md" --only '^body-schema-stamp$' ) >"$T/psc.out" 2>&1; RC=$?
}
fixture n7; add "$SD/0002-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm n7; psc "$R"
# TEST-CHANGE (BH-6192): this case expected a NOTE line; the row is off now.
[ "$RC" = 0 ] && ! grep -q 'body-schema-stamp' "$T/psc.out" && ok \
  || bad "N9 the off self-check row must print no body-schema-stamp line on a new NNNN fragment: rc $RC [$(cat "$T/psc.out")]"
fixture n7s; add "$SD/202610121200-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm n7s; psc "$R"
[ "$RC" = 0 ] && ! grep -q 'body-schema-stamp' "$T/psc.out" && ok \
  || bad "N9 a stamp-form fragment gets no note: rc $RC [$(cat "$T/psc.out")]"

fixture f; add "$SD/202610121200-bh-9001-probe.sql"; add "$SD/202610121201-bh-6005-4-child.sql"; git -C "$R" add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N6 the first stamp-key fragments of a worker must be clean, rc $RC out [$OUT]"
fixture g; printf '%s\n' 'CREATE INDEX probe_ix ON probe_b(id);' >> "$R/$SD/0001-bh-1-b.sql"; add "docs/0002-x.sql"; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N6 an edit to an existing fragment and a file outside schema.d must be clean, rc $RC out [$OUT]"
fixture h; git -C "$R" rm -q "$SD/0001-bh-1-b.sql"; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N6 a deleted fragment must be clean, rc $RC out [$OUT]"
OUT=$(rp_schema_fragment_name "$R" "" 2>/dev/null); RC=$?
[ "$RC" = 125 ] && ok || bad "N6 no base must be rc 125, got $RC"

# ── N3 / N6 order follows dependency, not stamp age (BH-7229) ────────────────────
# TEST-CHANGE (BH-7229): N3 pinned "an earlier or equal stamp is a finding".
# The ticket makes a stamp that is only older than the base's newest clean; the
# finding is now a USE of a table a later-sorting fragment creates.
LATE="schema-fragment-name: uses table probe_n, which $SD/202610121200-bh-1-newest.sql at the base creates and which sorts after this fragment; take a stamp later than 202610121200 (bin/prepush-gate.sh --restamp)"
fixture6() { fixture "$1"; add "$SD/202610121200-bh-1-newest.sql"; add "worker/other/schema.d/202610130000-bh-3-cloud.sql"
             git -C "$R" add -A; git -C "$R" commit -qm stamped; BASE=$(git -C "$R" rev-parse HEAD); }
use() { printf '%s\n' 'INSERT INTO probe_n (id) VALUES (1);' > "$R/$1"; }
fixture6 n6a; add "$SD/202610121100-bh-2-older.sql"; git -C "$R" add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N3 an earlier stamp with no dependency must be clean: rc $RC out [$OUT]"
fixture6 n6b; add "$SD/202610121200-bh-2-same.sql"; git -C "$R" add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N3 an equal stamp with no dependency must be clean: rc $RC out [$OUT]"
fixture6 n6d; use "$SD/202610121100-bh-2-older.sql"; git -C "$R" add -A; lint
[ "$RC" = 1 ] && [ "$OUT" = "$SD/202610121100-bh-2-older.sql: $LATE" ] && ok \
  || bad "N3 an earlier stamp that uses the later table: rc $RC out [$OUT]"
fixture6 n6c; add "$SD/202610121201-bh-2-later.sql"; git -C "$R" add -A; lint
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "N6 a later stamp (worker/other's later one does not count) must be clean: rc $RC out [$OUT]"

# ── N9 the catalog row, and the real pack ─────────────────────────────────────
N=$(grep -c $'^schema-fragment-name\tdelta\tbuiltin\trp_schema_fragment_name\t' "$DIR/catalog/rules-pack.tsv")
[ "$N" = 1 ] && ok || bad "N9 catalog/rules-pack.tsv must carry one schema-fragment-name delta builtin row (got $N)"
mkdir -p "$T/nolg"
pack() {
  env HARNESS="$T/nolg" bash "$DIR/bin/rules-pack.sh" --tree "$R" --base "$BASE" --runner local \
    --out "$T/$1" --only schema-fragment-name >"$T/pack.out" 2>"$T/pack.err"; RC=$?
}
fixture p1; add "$SD/202610121200-bh-9001-probe.sql"; git -C "$R" add -A; git -C "$R" commit -qm clean; pack o1
[ "$RC" = 0 ] && [ ! -s "$T/pack.out" ] && ok || bad "N9 clean diff: pack rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"
fixture p2; add "$SD/0001-bh-9001-x.sql"; git -C "$R" add -A; git -C "$R" commit -qm red; pack o2
[ "$RC" = 1 ] && [ "$(cat "$T/pack.out")" = "schema-fragment-name: $(TAKEN "$SD/0001-bh-9001-x.sql" 0001 "$SD/0001-bh-1-b.sql")" ] && ok \
  || bad "N9 red diff: pack rc $RC out [$(cat "$T/pack.out")] err [$(tail -3 "$T/pack.err")]"

echo "schema-fragment-name.bh-5788: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
