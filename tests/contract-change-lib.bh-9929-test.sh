#!/bin/bash
# tests/contract-change-lib.bh-9929-test.sh — BH-9929 T1, T2, T3.
#
# The migration gate allows additive SQL only, and its refusal named no path.
# Builds cloned tables to get a value into a CHECK list. This suite pins:
#   L  cc_is_ticket / cc_step_of: the label and the marker line, and the
#      negatives (fenced marker, "no", "yes please", title only, a near label)
#   C  cc_classify_sql: one class per contract statement, and the statements
#      that are NOT contract changes (ADD COLUMN, DROP INDEX, the TK-130
#      self-cast, DROP NOT NULL, DELETE, TRUNCATE, CREATE TABLE <t>_ext)
#   G  A1: an ordinary DROP CONSTRAINT through bin/check-migration-appliable.sh
#      is still refused (rc 1, one FLAGGED line) and the refusal names the lane
#      and the marker; the hint line carries no FLAGGED word. Then the same
#      file through the production `# >>> migration gate` block: TIER=2 and
#      MIG_SECTION carries the hint.
#   S  cc_enabled: the per-project switch rows (project-6-os, project-3 on,
#      project-1 off), an unreachable worker = off, and K1: the code
#      fallbacks equal the registry defaults.
#
# 0 network calls: no jobs client in the scratch harness, the settings cache is
# a file this suite writes.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "contract-change-lib: jq is required"; exit 1; }

# shellcheck source=bin/lib/contract-change.sh
. "$DIR/bin/lib/contract-change.sh" || { echo "cannot source bin/lib/contract-change.sh"; exit 1; }

# ── L: the ticket type ───────────────────────────────────────────────────────
meta() { # meta <labels-json> <body>
  jq -n --argjson l "$1" --arg b "$2" '{title:"t", labels:$l, body:$b}' > "$T/meta.json"
}
is_t() { cc_is_ticket "$T/meta.json"; }

meta '[{"name":"ai-build"},{"name":"contract-change"}]' 'drop the constraint'
is_t && ok || bad "L1 label contract-change must be a contract-change ticket"
meta '[{"name":"Contract-Change"}]' ''
is_t && ok || bad "L2 label Contract-Change (case) must count"
meta '["contract-change"]' ''
is_t && ok || bad "L3 a string label must count"
meta '[]' $'Some text\nContract-change: yes\nmore'
is_t && ok || bad "L4 marker line must count"
meta '[]' $'- Contract-change: YES  '
is_t && ok || bad "L5 bullet + upper-case marker must count"
meta '[]' $'Example:\n```\nContract-change: yes\n```\n'
is_t && bad "L6 a marker inside a fence must NOT count" || ok
meta '[]' $'~~~\nContract-change: yes\n~~~'
is_t && bad "L7 a marker inside a ~~~ fence must NOT count" || ok
meta '[]' 'Contract-change: no'
is_t && bad "L8 Contract-change: no must NOT count" || ok
meta '[]' 'Contract-change: yes please'
is_t && bad "L9 Contract-change: yes please must NOT count" || ok
jq -n '{title:"Contract-change: yes", labels:[], body:"a contract change in prose"}' > "$T/meta.json"
is_t && bad "L10 the title and prose must NOT count" || ok
meta '[{"name":"contract-changes"}]' ''
is_t && bad "L11 label contract-changes must NOT count" || ok
cc_is_ticket "$T/none.json" && bad "L12 a missing meta must answer no" || ok

printf 'Part of #12\nContract-parent: #12\nContract-step: migrate\n' > "$T/child.md"
[ "$(cc_step_of "$T/child.md")" = migrate ] && ok || bad "L13 cc_step_of: [$(cc_step_of "$T/child.md")]"
[ "$(cc_parent_of "$T/child.md")" = 12 ] && ok || bad "L14 cc_parent_of: [$(cc_parent_of "$T/child.md")]"
printf 'Contract-step: shrink\n' > "$T/child2.md"
cc_step_of "$T/child2.md" >/dev/null && bad "L15 an unknown step word must answer no" || ok
printf '```\nContract-step: expand\n```\n' > "$T/child3.md"
cc_step_of "$T/child3.md" >/dev/null && bad "L16 a fenced step line must answer no" || ok

# ── C: the SQL classes ───────────────────────────────────────────────────────
cls() { printf '%s\n' "$1" > "$T/c.sql"; cc_classify_sql "$T/c.sql" | paste -sd, -; }
chk() { local got; got=$(cls "$1"); [ "$got" = "$2" ] && ok || bad "C [$1] -> [$got], want [$2]"; }
chk 'ALTER TABLE report_choice DROP CONSTRAINT report_choice_kind_check;' constraint
chk 'ALTER TABLE t DROP CONSTRAINT IF EXISTS c;' constraint
chk 'ALTER TABLE t ALTER COLUMN x TYPE INTEGER;' type
chk 'ALTER TABLE t ALTER COLUMN x SET DATA TYPE bigint;' type
chk 'ALTER TABLE t ALTER COLUMN x SET NOT NULL;' nullability
chk 'ALTER TABLE t RENAME COLUMN a TO b;' rename
chk 'ALTER TABLE a RENAME TO b;' rename
chk 'ALTER TABLE t DROP COLUMN legacy;' drop-column
chk 'ALTER TABLE t DROP legacy;' drop-column
chk 'DROP TABLE t;' drop-table
chk 'DROP TABLE IF EXISTS t;' drop-table
chk 'alter table t drop constraint c;' constraint
# a CHECK-list change: the drop and the re-add
chk $'ALTER TABLE t DROP CONSTRAINT c;\nALTER TABLE t ADD CONSTRAINT c CHECK (k IN (\'a\',\'b\'));' 'constraint,constraint'
chk "ALTER TABLE t DROP CONSTRAINT c, ADD CONSTRAINT c CHECK (k IN ('a','b'));" constraint
# a merge: INSERT .. SELECT .. FROM b + DROP TABLE b
chk $'INSERT INTO a (x) SELECT x FROM b;\nDROP TABLE b;' merge
# not contract changes
chk 'ALTER TABLE t ADD COLUMN z TEXT;' ''
chk 'ALTER TABLE t ADD CONSTRAINT u UNIQUE (z);' ''
chk "ALTER TABLE t ADD CONSTRAINT c CHECK (k IN ('a'));" ''
chk 'ALTER TABLE t ALTER COLUMN x TYPE TEXT USING x::text;' ''
chk 'ALTER TABLE t ALTER COLUMN x DROP NOT NULL;' ''
chk 'DROP INDEX idx_x;' ''
chk 'DELETE FROM t;' ''
chk 'TRUNCATE t;' ''
chk 'CREATE TABLE report_choice_ext (id INTEGER PRIMARY KEY);' ''
chk "ALTER TYPE e ADD VALUE 'x';" ''
chk '-- DROP TABLE t;' ''
# old-shape names
printf 'DROP TABLE report_choice;\nALTER TABLE t DROP COLUMN legacy;\nALTER TABLE t RENAME COLUMN a TO b;\nALTER TABLE t DROP CONSTRAINT c;\n' > "$T/n.sql"
[ "$(cc_old_names "$T/n.sql" | paste -sd, -)" = "a,legacy,report_choice" ] && ok \
  || bad "C old names: [$(cc_old_names "$T/n.sql" | paste -sd, -)]"
# residue: the statements that are not contract statements (BH-9929 review)
printf -- '-- note\nALTER TABLE t DROP CONSTRAINT c;\nDELETE FROM users;\nCREATE INDEX i ON t(x);\n' > "$T/r.sql"
[ "$(cc_residue_sql "$T/r.sql" | paste -sd'|' -)" = "DELETE FROM users;|CREATE INDEX i ON t(x);" ] && ok \
  || bad "C residue: [$(cc_residue_sql "$T/r.sql" | paste -sd'|' -)]"
printf 'DROP TABLE a;\nALTER TABLE t DROP COLUMN b;\n' > "$T/r2.sql"
[ -z "$(cc_residue_sql "$T/r2.sql")" ] && ok || bad "C residue of an all-contract file must be empty: [$(cc_residue_sql "$T/r2.sql")]"
cc_residue_sql "$T/no-such.sql" >/dev/null 2>&1 && bad "C residue of an unreadable file must be rc 1" || ok
# The action splitter skips '...' literals and "..." names (BH-9929 review):
# a `)` in a literal or a `(` in a quoted name never hides a DROP COLUMN.
chk "ALTER TABLE orders DROP CONSTRAINT orders_status_check, ADD CONSTRAINT orders_status_check CHECK (note NOT LIKE '%:)'), DROP COLUMN legacy_status;" 'constraint,drop-column'
chk 'ALTER TABLE t DROP CONSTRAINT "a(b", DROP COLUMN secret;' 'constraint,drop-column'
chk "ALTER TABLE t ADD CONSTRAINT c CHECK (s <> 'it''s,)'), DROP COLUMN x;" 'drop-column'
printf '%s\n' "ALTER TABLE orders DROP CONSTRAINT o, ADD CONSTRAINT o CHECK (note NOT LIKE '%:)'), DROP COLUMN legacy_status;" > "$T/q.sql"
[ "$(cc_old_names "$T/q.sql")" = legacy_status ] && ok || bad "C old names behind a quoted ')': [$(cc_old_names "$T/q.sql")]"
# riders: a non-contract, non-additive ACTION inside a contract statement
# (BH-9929 review). Each of these must print a rider.
rid() { printf '%s\n' "$1" > "$T/rd.sql"; cc_riders_sql "$T/rd.sql" | cut -f2 | paste -sd'|' -; }
for st in \
  'ALTER TABLE public.clients ALTER COLUMN tier TYPE text, DISABLE ROW LEVEL SECURITY;' \
  'ALTER TABLE public.clients DROP CONSTRAINT c1, NO FORCE ROW LEVEL SECURITY, OWNER TO anon;' \
  'ALTER TABLE orders DROP CONSTRAINT c; ALTER TABLE orders ADD CONSTRAINT c CHECK (s IN (1,2)), DISABLE ROW LEVEL SECURITY;' \
  'ALTER TYPE status OWNER TO anon;' \
  'ALTER TYPE status ADD ATTRIBUTE a int, DROP ATTRIBUTE b;' \
  'DROP TABLE a, b;' \
  'DROP TABLE a CASCADE;' \
  'ALTER TABLE t DROP COLUMN x CASCADE;' \
  'ALTER TABLE t DROP CONSTRAINT c CASCADE;' \
  'ALTER TABLE t ALTER COLUMN x SET DEFAULT 0, DROP COLUMN y;' \
  "ALTER TABLE t DROP CONSTRAINT c, ADD CONSTRAINT c CHECK (s <> 'a\\'), DROP COLUMN y;" \
  "ALTER TABLE t DROP CONSTRAINT c, ADD CONSTRAINT c CHECK (s <> 'open);"; do
  [ -n "$(rid "$st")" ] && ok || bad "C riders: [$st] must print a rider"
done
for st in \
  'ALTER TABLE t DROP CONSTRAINT c, ADD CONSTRAINT c CHECK (s IN (1,2));' \
  "ALTER TABLE orders DROP CONSTRAINT o, ADD CONSTRAINT o CHECK (note NOT LIKE '%:)'), DROP COLUMN legacy_status;" \
  'ALTER TABLE t ALTER COLUMN x TYPE integer USING x::integer;' \
  'ALTER TABLE t ALTER COLUMN x SET NOT NULL;' \
  'ALTER TABLE t RENAME COLUMN a TO b;' \
  'ALTER TABLE t RENAME TO t2;' \
  'DROP TABLE IF EXISTS a;' \
  "ALTER TYPE status RENAME VALUE 'a' TO 'b';" \
  'ALTER TABLE t DROP COLUMN IF EXISTS x;'; do
  [ -z "$(rid "$st")" ] && ok || bad "C riders: [$st] is clean, got [$(rid "$st")]"
done
cc_riders_sql "$T/no-such.sql" >/dev/null 2>&1 && bad "C riders of an unreadable file must be rc 1" || ok
cc_human_class constraint nullability rename && bad "C cc_human_class: constraint/nullability/rename must not need a human" || ok
cc_human_class type && ok || bad "C cc_human_class: a type change needs a human (a cast can lose values)"
printf 'ALTER TABLE invoices ALTER COLUMN amount TYPE integer USING NULL;\n' > "$T/lossy.sql"
cc_human_class "$(cc_classify_sql "$T/lossy.sql")" && ok || bad "C a 'TYPE integer USING NULL' file needs a human: $(cc_classify_sql "$T/lossy.sql")"
cc_human_class $'constraint\ndrop-column' && ok || bad "C cc_human_class: drop-column needs a human"
cc_human_class merge && ok || bad "C cc_human_class: merge needs a human"
cc_human_class drop-table && ok || bad "C cc_human_class: drop-table needs a human"

# ── G: A1, the ordinary build's refusal names the lane ──────────────────────
mkdir -p "$T/g/scripts/migrations"
printf 'ALTER TABLE t DROP CONSTRAINT c;\n' > "$T/g/scripts/migrations/0001_x.sql"
OUT=$("$DIR/bin/check-migration-appliable.sh" project-3 "$T/g" scripts/migrations/0001_x.sql); RC=$?
[ "$RC" = 1 ] && ok || bad "G1 the gate must still refuse: rc=$RC"
[ "$(grep -c 'FLAGGED (' <<<"$OUT")" = 1 ] && ok || bad "G2 one FLAGGED line: $OUT"
HINT=$(grep ': contract-change: ' <<<"$OUT")
[ "$(grep -c . <<<"$HINT")" = 1 ] && ok || bad "G3 one contract-change line: $OUT"
grep -qF '"Contract-change: yes"' <<<"$HINT" && grep -qF 'label contract-change' <<<"$HINT" \
  && grep -qF 'expand, migrate, contract' <<<"$HINT" && ok || bad "G4 the hint must name the marker, the label and the lane: $HINT"
grep -q FLAGGED <<<"$HINT" && bad "G5 the hint line must carry no FLAGGED word" || ok
# DELETE and DROP INDEX: refused, no hint
printf 'DELETE FROM t;\nDROP INDEX i;\n' > "$T/g/d.sql"
OUT=$("$DIR/bin/check-migration-appliable.sh" project-3 "$T/g" "$T/g/d.sql"); RC=$?
[ "$RC" = 1 ] && ! grep -q 'contract-change' <<<"$OUT" && ok || bad "G6 DELETE/DROP INDEX: refused, no hint: rc=$RC $OUT"
# additive SQL: unchanged, silent, rc 0
printf 'ALTER TABLE t ADD COLUMN z TEXT;\nCREATE INDEX i ON t(z);\n' > "$T/g/a.sql"
OUT=$("$DIR/bin/check-migration-appliable.sh" project-3 "$T/g" "$T/g/a.sql"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "G7 additive SQL: rc 0 and silent: rc=$RC [$OUT]"

# The production block: a git repo with the file ADDED on a branch, the REAL
# gate and lib copied into a scratch harness.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || exit 1
awk '/^# >>> migration gate/{f=1;next} /^# <<< migration gate/{exit} f' "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "G8 could not extract the migration gate block"
mkdir -p "$T/h/bin/lib"
cp "$DIR/bin/check-migration-appliable.sh" "$T/h/bin/"
# scratch-closure-allow: the migration-gate block is extracted and run alone; it sources only these libs beside the real gate
cp "$DIR/bin/lib/contract-change.sh" "$DIR/bin/lib/migration-files.sh" "$T/h/bin/lib/"
R="$T/repo"; mkdir -p "$R"
G() { git -C "$R" -c user.email=t@t -c user.name=t "$@"; }
G init -q -b main && echo x > "$R/README" && G add -A && G commit -qm init
G checkout -qb b-cc && mkdir -p "$R/scripts/migrations" \
  && printf 'ALTER TABLE t DROP CONSTRAINT c;\n' > "$R/scripts/migrations/0001_x.sql" \
  && G add -A && G commit -qm mig
mkdir -p "$T/gbuild"
( cd "$R" && env HARNESS="$T/h" BUILD="$T/gbuild" WT="$R" BASE=main bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    PROJECT=project-3; KEY=K; TIER=1
    . "$0"
    printf "TIER=[%s]\n" "$TIER"
    printf "%s\n" "$MIG_SECTION" > "$BUILD/mig-section.txt"
  ' "$T/gate.sh" ) > "$T/gate-out.txt" 2>"$T/gate-err.txt"
grep -qx 'TIER=\[2\]' "$T/gate-out.txt" && ok || bad "G9 the block must force tier 2: $(cat "$T/gate-out.txt" "$T/gate-err.txt")"
grep -qF 'Contract-change: yes' "$T/gbuild/mig-section.txt" && ok || bad "G10 MIG_SECTION must carry the hint: $(cat "$T/gbuild/mig-section.txt")"

# ── S: the switch ────────────────────────────────────────────────────────────
REG="$T/lanes.json"
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 || bad "S0 lanes-build could not compose the registry"
mkdir -p "$T/s/state"
jq -nc '{fetched_at:1700000000, values:{
  "lib.contract-change.project-6-os.contract_change_enabled":"1",
  "lib.contract-change.project-3.contract_change_enabled":"1"}, seeded:{}}' > "$T/s/state/settings-cache.json"
sw() { env -u CONTRACT_CHANGE_ENABLED HARNESS="$T/s" LANE_REGISTRY="$REG" LANE_GATE_NOW=1700000010 bash -c '. "$1"; cc_enabled "$2"' _ "$DIR/bin/lib/contract-change.sh" "$1"; }
sw project-6-os; RC=$?; [ "$RC" = 0 ] && ok || bad "S1 project-6-os must be on: rc=$RC"
sw project-3;      RC=$?; [ "$RC" = 0 ] && ok || bad "S2 project-3 must be on: rc=$RC"
sw project-1;  RC=$?; [ "$RC" = 1 ] && ok || bad "S3 project-1 must be off: rc=$RC"
# the worker cannot be read and no row is cached: off (fail closed)
rm -f "$T/s/state/settings-cache.json"
sw project-3; RC=$?; [ "$RC" -ne 0 ] && ok || bad "S4 an unreachable worker must be off: rc=$RC"
# the seed fragment holds exactly these two rows on
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-9929-contract-change-switch.sql 2>/dev/null | head -1)
[ -r "$SEED" ] && grep -qF "'lib.contract-change.project-6-os.contract_change_enabled','1'" "$SEED" \
  && grep -qF "'lib.contract-change.project-3.contract_change_enabled','1'" "$SEED" && ok || bad "S5 the seed must turn on project-6-os and project-3"
# K1: the code fallbacks equal the registry defaults
regdef() { jq -r --arg e "$1" '.libs[] | select(.id=="contract-change") | .knobs[] | select(.env==$e) | .default' "$REG"; }
[ "$(regdef CONTRACT_CHANGE_ENABLED)" = 0 ] && grep -qF '${CONTRACT_CHANGE_ENABLED:-0}' "$DIR/bin/lib/contract-change.sh" \
  && ok || bad "K1 CONTRACT_CHANGE_ENABLED: registry [$(regdef CONTRACT_CHANGE_ENABLED)] vs code"
if [ -r "$DIR/bin/contract-change-gate.sh" ]; then
  W=$(regdef CONTRACT_CHANGE_QUERY_LOG_WINDOW_H); X=$(regdef CONTRACT_CHANGE_GREP_EXCLUDE)
  grep -qF "\${CONTRACT_CHANGE_QUERY_LOG_WINDOW_H:-$W}" "$DIR/bin/contract-change-gate.sh" && ok || bad "K1 window fallback != registry $W"
  grep -qF "\${CONTRACT_CHANGE_GREP_EXCLUDE:-$X}" "$DIR/bin/contract-change-gate.sh" && ok || bad "K1 exclude fallback != registry $X"
fi

echo "contract-change-lib.bh-9929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
