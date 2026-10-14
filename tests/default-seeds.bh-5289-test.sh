#!/bin/bash
# tests/default-seeds.bh-5289-test.sh — BH-5289: the defaults a fresh install
# starts with. Each one is a settings row or a lane-catalog knob, and the code
# fallback behind it says the same value, so a hub with no row and a hub with
# the seeded row behave alike. docs/OPERATING.md's Defaults table states each.
#   S1 a fresh worker/jobs/schema.sql: size_gate 700/20, risk_tier.mode off,
#      and no queue_partition.mode row (a fresh install is serial)
#   S2 bin/size-threshold.sh's fallbacks equal the size_gate rows
#   S3 lead and builder review concurrency: catalog 10 == code fallback 10
#   S4 "$DIR/bin/lib/risk-tier.sh" rt_mode reads the fresh schema's rows: the
#      opted-in repo's own row wins, and once it is gone the global seed reads
#      off (the probative case). A repo outside RT_MODE_REPOS is off by that
#      constant whatever the rows say, so its case pins the constant, not the seed
#   S5 the review-worker /tmp floor: catalog 1536 == code fallback 1536
#   S6 docs/OPERATING.md's Defaults table states every value above
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/default-seeds.bh-5289-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- S1 a fresh schema --------------------------------------------------
# Apply the whole schema to an empty database, as a new hub's first sync does,
# and keep it: S4 reads its rows.
python3 -I - "$DIR/worker/jobs/schema.sql" "$T/hub.sqlite" > "$T/s1.err" 2>&1 <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.executescript(open(sys.argv[1]).read())
db.commit()
PY
[ "$?" = 0 ] && ok || bad "S1 schema.sql did not apply to a fresh database: $(head -3 "$T/s1.err")"
row() {
  python3 -I - "$T/hub.sqlite" "$1" <<'PY'
import sqlite3, sys
r = sqlite3.connect(sys.argv[1]).execute("SELECT value FROM settings WHERE key=?", (sys.argv[2],)).fetchone()
sys.exit(2) if r is None else print(r[0])
PY
}
SG_LINES=$(row size_gate.lines); SG_FILES=$(row size_gate.files); RT_GLOBAL=$(row risk_tier.mode)
[ "$SG_LINES" = 700 ] && ok || bad "S1 size_gate.lines seeds '$SG_LINES', want 700"
[ "$SG_FILES" = 20 ] && ok || bad "S1 size_gate.files seeds '$SG_FILES', want 20"
[ "$RT_GLOBAL" = off ] && ok || bad "S1 risk_tier.mode seeds '$RT_GLOBAL', want off"
[ "$(row risk_tier.mode.example-org.cromford)" = enforce ] && ok || bad "S1 the per-repo risk_tier.mode seed changed"
row queue_partition.mode >/dev/null; [ "$?" = 2 ] && ok || bad "S1 a queue_partition.mode row is seeded; the Defaults table says a fresh install is serial"

# ---------- S2 size gate code fallbacks equal the rows --------------------------
CODE_L=$(sed -n 's/^DEF_LINES=\([0-9][0-9]*\)$/\1/p' "$DIR/bin/size-threshold.sh")
CODE_F=$(sed -n 's/^DEF_FILES=\([0-9][0-9]*\)$/\1/p' "$DIR/bin/size-threshold.sh")
[ -n "$CODE_L" ] && [ "$CODE_L" = "$SG_LINES" ] && ok || bad "S2 bin/size-threshold.sh DEF_LINES='$CODE_L' vs row '$SG_LINES'"
[ -n "$CODE_F" ] && [ "$CODE_F" = "$SG_FILES" ] && ok || bad "S2 bin/size-threshold.sh DEF_FILES='$CODE_F' vs row '$SG_FILES'"

# ---------- S3 / S5 catalog knob defaults --------------------------------------
knob_default() {
  python3 -I - "$DIR/catalog/lanes.d/$1.json" "$2" <<'PY'
import json, sys
for k in json.load(open(sys.argv[1])).get("knobs", []):
    if k.get("env") == sys.argv[2]:
        print(k.get("default")); break
PY
}
[ "$(knob_default lead-review LEAD_REVIEW_CONCURRENCY)" = 10 ] && ok || bad "S3 LEAD_REVIEW_CONCURRENCY catalog default is not 10"
[ "$(knob_default review-prs REVIEW_CONCURRENCY)" = 10 ] && ok || bad "S3 REVIEW_CONCURRENCY catalog default is not 10"
# The code fallbacks, read exactly (absent line = 0 = red).
n=$(grep -cF 'knob LEAD_REVIEW_CONCURRENCY "${LEAD_REVIEW_CONCURRENCY:-10}" 10' "$DIR/bin/lead-review.sh")
[ "$n" = 1 ] && ok || bad "S3 bin/lead-review.sh fallback for LEAD_REVIEW_CONCURRENCY is not 10 ($n lines)"
n=$(grep -cE "''\|\*\[!0-9\]\*\|0\*\) RP_K=10 ;;" "$DIR/bin/review-prs.sh")
[ "$n" = 1 ] && ok || bad "S3 bin/review-prs.sh fallback RP_K is not 10 ($n lines)"

[ "$(knob_default lead-review LEAD_REVIEW_TMP_MIN_MB)" = 1536 ] && ok || bad "S5 LEAD_REVIEW_TMP_MIN_MB catalog default is not 1536"
[ "$(knob_default review-prs REVIEW_TMP_MIN_MB)" = 1536 ] && ok || bad "S5 REVIEW_TMP_MIN_MB catalog default is not 1536"
n=$(grep -cF '_rpool_knob TMP_MIN_MB 1536' "$DIR/bin/lib/review-pool.sh")
[ "$n" = 2 ] && ok || bad "S5 bin/lib/review-pool.sh carries the 1536 fallback on $n call sites, want 2"

# ---------- S4 rt_mode over the fresh schema's rows ----------------------------
# setting_get answers from the database S1 built: the value, or rc 2 for no row.
setting_get() { row "$1"; }
# shellcheck source=/dev/null
. "$DIR/bin/lib/risk-tier.sh" || bad "S4 bin/lib/risk-tier.sh did not source"
if command -v rt_mode >/dev/null 2>&1; then
  # Off because acme/new-repo is not in RT_MODE_REPOS, not because of the seed:
  # this pins the constant the Defaults row documents. Even its own shadow row
  # must not switch it on.
  m=$(rt_mode acme/new-repo | cut -f1)
  [ "$m" = off ] && ok || bad "S4 a repo outside RT_MODE_REPOS reads '$m', want off"
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("INSERT INTO settings (key,value,note,actor,updated_at) VALUES (?,?,?,?,?)", ("risk_tier.mode.acme.new-repo","shadow","test","test","2026-10-07T00:00:00Z")); c.commit()' "$T/hub.sqlite"
  m=$(rt_mode acme/new-repo | cut -f1)
  [ "$m" = off ] && ok || bad "S4 a repo outside RT_MODE_REPOS with its own shadow row reads '$m', want off"
  m=$(rt_mode example-org/cromford | cut -f1)
  [ "$m" = enforce ] && ok || bad "S4 the opted-in repo's own row no longer wins: '$m'"
  # Without its own row the opted-in repo falls to the global seed, which must
  # not turn enforcement on.
  python3 -I -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("DELETE FROM settings WHERE key=?", ("risk_tier.mode.example-org.cromford",)); c.commit()' "$T/hub.sqlite"
  out=$(rt_mode example-org/cromford)
  [ "$out" = "$(printf 'off\t')" ] && ok || bad "S4 with only the global seed the repo reads '$out', want off with no reason"
else
  bad "S4 rt_mode is not defined"
fi

# ---------- S6 the Defaults table states each value ----------------------------
OP="$DIR/docs/OPERATING.md"
if [ -f "$OP" ]; then
  awk '/^## Defaults$/ { on = 1; next } /^## / { on = 0 } on' "$OP" > "$T/defaults.md"
  default_cell() {  # default_cell <Setting cell substring> -> the trimmed Default cell, rc 1 if no row
    local line
    line=$(grep -iF -- "$1" "$T/defaults.md" | head -1)
    case "$line" in
      '|'*) printf '%s\n' "$line" | awk -F'|' '{ c = $3; gsub(/^[ \t]+|[ \t]+$/, "", c); print c }' ;;
      *) return 1 ;;
    esac
  }
  check() {  # check <Setting cell substring> <Default cell substring>
    local cell
    cell=$(default_cell "$1") || { bad "S6 the Defaults table has no '$1' row"; return; }
    case "$cell" in *"$2"*) ok ;; *) bad "S6 Defaults row '$1' has Default '$cell', want '$2'" ;; esac
  }
  check_is() {  # check_is <Setting cell substring> <whole Default cell>
    local cell
    cell=$(default_cell "$1") || { bad "S6 the Defaults table has no '$1' row"; return; }
    [ "$cell" = "$2" ] && ok || bad "S6 Defaults row '$1' has Default '$cell', want exactly '$2'"
  }
  check 'review concurrency' '10'
  check 'Size gate' "$SG_LINES lines"
  check 'Size gate' "$SG_FILES files"
  check_is 'Risk tier' "$RT_GLOBAL"
  # The row names the constant that limits which repos the mode rows reach.
  grep -iF 'Risk tier' "$T/defaults.md" | head -1 | grep -qF 'RT_MODE_REPOS' && ok || bad "S6 the Risk tier row does not name RT_MODE_REPOS"
  grep -qF 'RT_MODE_REPOS' "$OP" && grep -qF "RT_MODE_REPOS='example-org/cromford'" "$DIR/bin/lib/risk-tier.sh" && ok || bad "S6 RT_MODE_REPOS is named in OPERATING.md but no longer the constant in bin/lib/risk-tier.sh"
  check 'floor for review workers' '1536'
  check 'floor for review workers' '1.5 GB'
  check_is 'Fast-lint' 'report-only'
  # No queue_partition.mode row is seeded (S1 below), so a fresh install is
  # serial; the Default cell must say so and not claim lanes are on.
  check 'Merge queue' 'serial'
  check 'Merge queue' 'off until a repo opts in'
  check_is 'Impact CI' 'on'
  check_is 'Stale-review dismissal' 'on'
  for col in 'Trade-off' 'Where it lives'; do
    grep -m1 '^|' "$T/defaults.md" | grep -qF "$col" && ok || bad "S6 the Defaults table has no '$col' column"
  done
else
  bad "S6 docs/OPERATING.md does not exist"
fi

echo "default-seeds.bh-5289: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
