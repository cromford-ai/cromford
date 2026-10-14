#!/bin/bash
# tests/size-threshold-settings.bh-4985-test.sh — the size gate's limits are
# settings rows (BH-4985, the operator 2026-10-06: "that should be a database setting,
# not hard coded"), with 700 lines / 20 files as the code fallback.
#
# Per axis, first hit wins: size_gate.<axis>.<project> → size_gate.<axis> →
# flags/size-gate-<project> → catalog/size-thresholds.conf → 700/20. Rows come
# from state/settings-cache.json through bin/lib/lane-gate.sh, so every case
# here writes a cache fixture into a scratch harness and runs with JOBS_URL=
# and no bin/jobs-client.sh in that tree: nothing reaches the network.
#
# The flag/catalog cases with no rows stay in tests/size-gate-test.sh.
#   HARNESS_TEST_SANDBOX=1 bash tests/size-threshold-settings.bh-4985-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

THRESH="$DIR/bin/size-threshold.sh"
GATE="$DIR/bin/size-gate.sh"
h="$T/h"
mkdir -p "$h/state" "$h/flags" "$h/catalog" "$h/logs"
cache() { jq -n --argjson fa "$(date -u +%s)" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$h/state/settings-cache.json"; }
th() { HARNESS="$h" JOBS_URL= "$THRESH" "$@" 2>/dev/null; }
reset() { rm -f "$h/state/settings-cache.json" "$h/flags/size-gate-widget-os" "$h/catalog/size-thresholds.conf"; scratch_rm "$h/state/lane-gate"; }

# 1. a fleet line row, no file row
reset; cache '{"size_gate.lines":"650"}'
[ "$(th widget-os lines)" = 650 ] && ok || bad "1: fleet row size_gate.lines=650 must answer 650, got $(th widget-os lines)"
[ "$(th widget-os files)" = 20 ] && ok || bad "1: no file row must fall to the 20 default, got $(th widget-os files)"
[ "$(th widget-os src)" = "lines:row,files:default" ] && ok || bad "1: src must name each axis, got $(th widget-os src)"

# 2. the project row beats the fleet row, and only for its own project
reset; cache '{"size_gate.lines":"700","size_gate.lines.widget-os":"1200"}'
[ "$(th widget-os lines)" = 1200 ] && ok || bad "2: project row must win for widget-os, got $(th widget-os lines)"
[ "$(th other-os lines)" = 700 ] && ok || bad "2: another project gets the fleet row, got $(th other-os lines)"
# The slug is lowercased into the key, the worker's SETTING_KEY_RE.
[ "$(th Widget-OS lines)" = 1200 ] && ok || bad "2: an uppercase slug must read the lowercased row, got $(th Widget-OS lines)"
reset; cache '{"size_gate.lines.other-os":"999"}'
[ "$(th widget-os lines)" = 700 ] && ok || bad "2: other-os's row must not apply to widget-os"
# A slug outside the key charset has no row: no lookup, the fleet/default answers.
reset; cache '{"size_gate.lines":"640","size_gate.lines.a/b":"5"}'
[ "$(th 'a/b' lines)" = 640 ] && ok || bad "2: a slug with / must not be read as a key, got $(th 'a/b' lines)"

# 3. a row outranks the flag and the catalog, axis by axis
reset; cache '{"size_gate.lines":"800"}'
echo '150 4' > "$h/flags/size-gate-widget-os"
printf 'widget-os 900 30\n' > "$h/catalog/size-thresholds.conf"
[ "$(th widget-os lines)" = 800 ] && ok || bad "3: the row must beat the flag and catalog, got $(th widget-os lines)"
[ "$(th widget-os files)" = 4 ] && ok || bad "3: with no files row the flag keeps the file axis, got $(th widget-os files)"
[ "$(th widget-os src)" = "lines:row,files:flag" ] && ok || bad "3: src got $(th widget-os src)"

# 4. junk never becomes a threshold, in either row
for J in banana 0 -5 7e2 '700 20' '$(id)' ''; do
  reset; cache "$(jq -n --arg j "$J" '{"size_gate.lines":"640","size_gate.lines.widget-os":$j}')"
  [ "$(th widget-os lines)" = 640 ] && ok || bad "4: project row '$J' must fall through to the fleet row, got $(th widget-os lines)"
  reset; cache "$(jq -n --arg j "$J" '{"size_gate.lines":$j}')"
  [ "$(th widget-os lines)" = 700 ] && ok || bad "4: fleet row '$J' must fall through to the default, got $(th widget-os lines)"
  echo '150 4' > "$h/flags/size-gate-widget-os"
  [ "$(th widget-os lines)" = 150 ] && ok || bad "4: fleet row '$J' must fall through to the flag, got $(th widget-os lines)"
  rm -f "$h/flags/size-gate-widget-os"
  printf 'widget-os 900 30\n' > "$h/catalog/size-thresholds.conf"
  [ "$(th widget-os lines)" = 900 ] && ok || bad "4: fleet row '$J' must fall through to the catalog, got $(th widget-os lines)"
done

# 5. fail-safe: no cache, an unreadable cache, the escape hatch
reset
[ "$(th widget-os)" = "700 20" ] && ok || bad "5: no cache must answer 700 20, got $(th widget-os)"
[ "$(th widget-os src)" = default ] && ok || bad "5: no cache src must be default, got $(th widget-os src)"
reset; printf 'not json{' > "$h/state/settings-cache.json"
[ "$(th widget-os)" = "700 20" ] && ok || bad "5: a corrupt cache must answer 700 20, got $(th widget-os)"
reset; cache '{"size_gate.lines":"650"}'; chmod 000 "$h/state/settings-cache.json"
if [ -r "$h/state/settings-cache.json" ]; then
  echo "note: running as root, chmod 000 is still readable — unreadable-cache case skipped"
else
  [ "$(th widget-os)" = "700 20" ] && ok || bad "5: an unreadable cache must answer 700 20, got $(th widget-os)"
fi
chmod 644 "$h/state/settings-cache.json"
[ "$(LANE_GATE_DISABLE=1 th widget-os lines)" = 700 ] && ok || bad "5: LANE_GATE_DISABLE=1 must ignore the rows"

# 6. a fresh cache costs no request: no miss stamp is written
reset; cache '{"size_gate.lines":"650"}'
th widget-os >/dev/null
[ ! -e "$h/state/lane-gate/.settings-miss" ] && ok || bad "6: a fresh cache must not try a GET"

# 7. output shapes
reset; cache '{"size_gate.lines":"650","size_gate.files":"15"}'
[ "$(th widget-os all)" = "650 15 row" ] && ok || bad "7: all must print 'L F SRC', got $(th widget-os all)"
[ "$(th widget-os)" = "650 15" ] && ok || bad "7: no field must stay 'L F', got $(th widget-os)"
[ "$(th widget-os lines)" = 650 ] && [ "$(th widget-os files)" = 15 ] && ok || bad "7: lines/files must be one number each"

# 8. the default end to end: 650/15 builds whole, 900 is over 700
reset
splan() { printf '# Plan\n\n### Task 1\n- VALIDATE: x\n\n## Size\nFILES: %s\nLINES: %s\n' "$2" "$1" > "$T/plan.md"; }
splan 650 15
G=$("$GATE" "$T/plan.md" "$(th x lines)" "$(th x files)" 2>&1)
grep -q '^SIZE_VERDICT: within$' <<<"$G" && ok || bad "8: 650/15 must be within the default: $G"
splan 900 15
G=$("$GATE" "$T/plan.md" "$(th x lines)" "$(th x files)" 2>&1)
grep -q '^SIZE_VERDICT: over$' <<<"$G" && ok || bad "8: 900 must be over the default: $G"
grep -q 'lines=900>700' <<<"$G" && ok || bad "8: the over line must name 900>700: $G"

# 9. src on the SIZE_LIMITS line, only in the shapes size-threshold prints
splan 100 2
G=$(SIZE_LIMITS_SRC=row "$GATE" "$T/plan.md" 700 20 2>&1)
grep -q '^SIZE_LIMITS: lines=700 files=20 src=row$' <<<"$G" && ok || bad "9: src=row must ride SIZE_LIMITS: $G"
G=$(SIZE_LIMITS_SRC=lines:row,files:default "$GATE" "$T/plan.md" 700 20 2>&1)
grep -q '^SIZE_LIMITS: lines=700 files=20 src=lines:row,files:default$' <<<"$G" && ok || bad "9: a mixed src must ride SIZE_LIMITS: $G"
G=$(env -u SIZE_LIMITS_SRC "$GATE" "$T/plan.md" 700 20 2>&1)
grep -q '^SIZE_LIMITS: lines=700 files=20$' <<<"$G" && ok || bad "9: no src must leave the line as it was: $G"
G=$(SIZE_LIMITS_SRC='$(id)' "$GATE" "$T/plan.md" 700 20 2>&1)
grep -q '^SIZE_LIMITS: lines=700 files=20$' <<<"$G" && ok || bad "9: a junk src must not reach the record: $G"
# evidence-summary's parse of the files count still works with src on the end.
[ "$(printf 'SIZE_LIMITS: lines=700 files=20 src=row\n' | sed 's/^.*files=\([0-9]*\).*$/\1/')" = 20 ] \
  && ok || bad "9: evidence-summary's files= parse must survive src="
G=$("$GATE" "$T/plan.md" 2>&1)
grep -q '^SIZE_LIMITS: lines=700 files=20$' <<<"$G" && ok || bad "9: size-gate.sh's own arg fallback must be 700/20: $G"

# 10. the real plan-time block: the source lands in pipeline.log and the ledger
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' "$RB_ALL" > "$T/sizeblock.sh"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' "$RB_ALL" > "$T/switch.sh"
[ -s "$T/sizeblock.sh" ] && [ -s "$T/switch.sh" ] && ok || bad "10: could not extract the size-gate block"
for S in bin/size-threshold.sh bin/size-gate.sh bin/size-scope.sh bin/planned-files.sh; do
  scratch_install_closure "$S" "$h" >/dev/null || bad "10: could not install $S's closure"
done
[ -r "$h/bin/lib/lane-gate.sh" ] && ok || bad "10: the closure must bring lane-gate.sh, or no row is read"
drive() { # drive <plan-text> — prints the block's output; artifacts in $T/art.tsv
  rm -rf "$T/b"; mkdir -p "$T/b"; : > "$T/art.tsv"
  printf '%s\n' "$1" > "$T/b/plan.md"
  ( env HARNESS="$h" JOBS_URL= BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$h/logs/ALERTS.log" JOB_ID=job-1 SINK="$T/art.tsv" SWITCHBLOCK="$T/switch.sh" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { :; }
             job_artifact_put() { printf "%s\t%s\n" "$1" "$3" >> "$SINK"; }
             . "$SWITCHBLOCK"
             . "$0"; echo "CONTINUED"' "$T/sizeblock.sh" 2>&1 )
}
BODY=$(printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 4\nLINES: 120\n\nKIND: feature\nSIZE: M\n')
reset; cache '{"size_gate.lines":"650"}'
OUT=$(drive "$BODY")
grep -q CONTINUED <<<"$OUT" && ok || bad "10: a 120-line plan must reach EXECUTE: $OUT"
grep -q 'limits lines=650 files=20 src=lines:row,files:default' "$T/b/pipeline.log" \
  && ok || bad "10: pipeline.log must name the limits and their source: $(cat "$T/b/pipeline.log" 2>/dev/null)"
grep -q '^SIZE_LIMITS: lines=650 files=20 src=lines:row,files:default$' "$T/b/size-gate.txt" \
  && ok || bad "10: size-gate.txt must carry src: $(cat "$T/b/size-gate.txt" 2>/dev/null)"
[ "$(cut -f2 "$T/art.tsv" | head -1 | jq -r '.limits.src')" = "lines:row,files:default" ] \
  && ok || bad "10: the size_gate artifact must carry limits.src: $(cat "$T/art.tsv")"
[ "$(cut -f2 "$T/art.tsv" | head -1 | jq -r '.limits.lines')" = 650 ] \
  && ok || bad "10: the size_gate artifact must carry the row's line limit: $(cat "$T/art.tsv")"
# A threshold script that fails is the 700/20 fallback, recorded as default.
mv "$h/bin/size-threshold.sh" "$T/size-threshold.real"
printf '#!/bin/bash\nexit 1\n' > "$h/bin/size-threshold.sh"; chmod +x "$h/bin/size-threshold.sh"
OUT=$(drive "$BODY")
grep -q 'limits lines=700 files=20 src=default' "$T/b/pipeline.log" \
  && ok || bad "10: a failed threshold read must fall back to 700/20 src=default: $(cat "$T/b/pipeline.log" 2>/dev/null)"
mv -f "$T/size-threshold.real" "$h/bin/size-threshold.sh"

# 11. the seed: one idempotent statement, actor seed, an operator edit survives
SCHEMA="$DIR/worker/jobs/schema.sql"
[ "$(grep -c "'size_gate.lines','700'" "$SCHEMA")" = 1 ] && ok || bad "11: exactly one size_gate.lines seed of 700"
[ "$(grep -c "'size_gate.files','20'" "$SCHEMA")" = 1 ] && ok || bad "11: exactly one size_gate.files seed of 20"
# Keyed on the exact 'size_gate.lines', key: the hotfix tier's own seed
# (size_gate.lines.hotfix, 2026-10-07) is a separate statement and is pinned in
# tests/size-threshold-hotfix-tier.size-hotfix-test.sh.
SEED=$(awk '/^INSERT OR IGNORE INTO settings/{buf=$0; inseed=1; next}
            inseed{buf=buf"\n"$0; if ($0 ~ /;[[:space:]]*$/) { if (buf ~ /\x27size_gate\.lines\x27,/) print buf; inseed=0 } }' "$SCHEMA")
[ -n "$SEED" ] && ok || bad "11: the seed must be an INSERT OR IGNORE INTO settings statement"
grep -q "'size_gate.files','20'" <<<"$SEED" && ok || bad "11: both rows in the one statement"
grep -q "registry-seed" <<<"$SEED" && bad "11: actor registry-seed is invisible to lookups" || ok
[ "$(grep -c "'seed','" <<<"$SEED")" = 2 ] && ok || bad "11: both rows must carry actor 'seed'"
# sqlite3 the CLI, or python3's own sqlite module standing in for it:
# sql <db> [script] — the script from the arg or stdin; a SELECT prints its rows.
if command -v sqlite3 >/dev/null 2>&1; then
  sql() { sqlite3 "$@"; }
elif command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sqlite3' 2>/dev/null; then
  sql() { python3 -I -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); q=sys.argv[2] if len(sys.argv)>2 else sys.stdin.read()
if q.lstrip().upper().startswith("SELECT"):
    print("\n".join("|".join(str(x) for x in r) for r in c.execute(q)))
else:
    c.executescript(q); c.commit()' "$@"; }
fi
if command -v sql >/dev/null 2>&1; then
  DB="$T/seed.db"
  sql "$DB" "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT);
             INSERT INTO settings VALUES ('size_gate.lines','900','raised','operator','2026-10-07T00:00:00Z');"
  printf '%s\n' "$SEED" | sql "$DB" && printf '%s\n' "$SEED" | sql "$DB" \
    && ok || bad "11: the seed must apply twice cleanly"
  [ "$(sql "$DB" "SELECT value FROM settings WHERE key='size_gate.lines'")" = 900 ] \
    && ok || bad "11: a re-apply must not reset an operator's edit"
  [ "$(sql "$DB" "SELECT value||'/'||actor FROM settings WHERE key='size_gate.files'")" = 20/seed ] \
    && ok || bad "11: the missing row must be seeded 20 by seed"
  [ "$(sql "$DB" "SELECT count(*) FROM settings WHERE key LIKE 'size_gate.%'")" = 2 ] \
    && ok || bad "11: one row per key"
else
  echo "note: neither sqlite3 nor python3 sqlite — seed double-apply case skipped"
fi

# 12. the measured reasoning is in the header
grep -q 'WHY 700 AND 20 (the operator, 2026-10-06)' "$THRESH" && ok || bad "12: the header must carry WHY 700 AND 20"

echo "size-threshold-settings.bh-4985: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
