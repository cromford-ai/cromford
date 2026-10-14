#!/bin/bash
# tests/alert-triage-hooks-discovery.bh-4608-test.sh — BH-4608: a new alert family
# (seed row + bin/alert-verify script) or a new alert-triage knob needs no edit to
# tests/alert-triage-hooks.bh-2544-test.sh or tests/alert-verify-seeds.bh-2577-test.sh,
# and both still go red on a broken seed or a moved contract knob.
# It copies the repo's real files into scratch, mutates the copy the way a family
# ticket would, and runs the two real suites there.
#   bash tests/alert-triage-hooks-discovery.bh-4608-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HOOKS=alert-triage-hooks.bh-2544-test.sh
SEEDS=alert-verify-seeds.bh-2577-test.sh

# --- a scratch repo holding exactly what the two suites read ------------------
R="$T/repo"
mkdir -p "$R/tests" "$R/worker/jobs" "$T/pristine"
cp -a "$DIR/bin" "$DIR/catalog" "$DIR/fleet.conf" "$R/"
cp -a "$DIR/tests/lib" "$DIR/tests/$HOOKS" "$DIR/tests/$SEEDS" "$R/tests/"
cp "$DIR/worker/jobs/schema.sql" "$R/worker/jobs/"
SCHEMA="$R/worker/jobs/schema.sql"
CAT="$R/catalog/lanes.d/alert-triage.json"
VDIR="$R/bin/alert-verify"
cp "$SCHEMA" "$T/pristine/schema.sql"
cp "$CAT" "$T/pristine/alert-triage.json"
cp -a "$VDIR" "$T/pristine/alert-verify"
cp "$R/bin/lanes-build.sh" "$T/pristine/lanes-build.sh"

restore() {
  cp "$T/pristine/schema.sql" "$SCHEMA"
  cp "$T/pristine/alert-triage.json" "$CAT"
  scratch_rm "$VDIR" || exit 1; cp -a "$T/pristine/alert-verify" "$VDIR"
  cp "$T/pristine/lanes-build.sh" "$R/bin/lanes-build.sh"
}

# suite <case> <file>: run a REAL suite in the scratch repo; sets RC, output in $T/out.<case>
suite() {
  (cd "$R" && HARNESS_TEST_SANDBOX=1 bash "$R/tests/$2") > "$T/out.$1" 2>&1; RC=$?
}

PROBE_COLS="(id,match_kind,match,verify,on_clear,on_repro,enabled,priority,note,actor,updated_at)"
PROBE_VALS="('bh4608-probe','akey_prefix','bh4608probe:','bh4608-probe','settle','model',1,999,'probe','seed-bh-4608','2026-10-05T00:00:00Z');"
add_row()    { printf '%s INTO alert_family_scripts %s VALUES\n  %s\n' "${1:-INSERT OR IGNORE}" "$PROBE_COLS" "$PROBE_VALS" >> "$SCHEMA"; }
add_script() { printf '#!/bin/sh\nexit 0\n' > "$VDIR/bh4608-probe.sh"; [ "${1:-x}" = x ] && chmod +x "$VDIR/bh4608-probe.sh"; }
jq_cat()     { jq "$1" "$CAT" > "$T/cat.json" && mv "$T/cat.json" "$CAT"; }
nrows() {
  python3 - "$SCHEMA" <<'PY'
import sqlite3, sys
db = sqlite3.connect(":memory:"); db.executescript(open(sys.argv[1]).read())
print(db.execute("SELECT count(*) FROM alert_family_scripts").fetchone()[0])
PY
}
PROBE_KNOB='{"env":"TRIAGE_VERIFY_PROBE","read_in":"bin/triage-family-scripts.sh","type":"int","default":1,"min":0,"max":2,"unit":null,"zero_means":null,"note":"BH-4608 probe"}'
failed0() { grep -q ' 0 failed$' "$T/out.$1"; }

# ---------- D1 new family + new knob: neither shared suite needs an edit (AC1, AC2)
restore; add_row; add_script x
jq_cat ".knobs += [$PROBE_KNOB]"
N=$(nrows)
[ "$N" = 11 ] && ok || bad "D1: vacuity guard: the copy's schema must hold 11 family rows (got $N)"
[ "$(jq '[.knobs[]|select(.env=="TRIAGE_VERIFY_PROBE")]|length' "$CAT")" = 1 ] && ok || bad "D1: vacuity guard: the probe knob is not in the copy's catalog"
suite d1h "$HOOKS"
[ "$RC" = 0 ] && failed0 d1h && ok || bad "D1: hooks suite must stay green with an 11th family and a new knob (rc $RC): $(grep '^FAIL' "$T/out.d1h" | head -5)"
suite d1s "$SEEDS"
[ "$RC" = 0 ] && failed0 d1s && ok || bad "D1: seeds suite must stay green with an 11th family (rc $RC): $(grep '^FAIL' "$T/out.d1s" | head -5)"

# ---------- D2 a row with no script, and a script with no row (AC3) ----------
restore; add_row; printf '#!/bin/sh\nexit 0\n' > "$VDIR/bh4608-orphan.sh"; chmod +x "$VDIR/bh4608-orphan.sh"
suite d2 "$HOOKS"
L=$(grep '^FAIL: 7:' "$T/out.d2")
[ "$RC" != 0 ] && ok || bad "D2: hooks suite must go red on a row with no script and an orphan script"
case "$L" in *"bh4608-probe: verify 'bh4608-probe' has no executable"*) ok ;; *) bad "D2: no check-7 line for the row with no script (got: $L)" ;; esac
case "$L" in *orphan*bh4608-orphan.sh*) ok ;; *) bad "D2: no check-7 line naming the orphan script (got: $L)" ;; esac

# ---------- D3 the script is there but not executable (AC3) ------------------
restore; add_row; add_script noexec
suite d3 "$HOOKS"
L=$(grep '^FAIL: 7:' "$T/out.d3")
[ "$RC" != 0 ] && ok || bad "D3: hooks suite must go red on a non-executable verify script"
case "$L" in *"has no executable"*) ok ;; *) bad "D3: no check-7 line for the non-executable script (got: $L)" ;; esac

# ---------- D4 a contract knob moved, another dropped (AC3) ------------------
restore
jq_cat '(.knobs[]|select(.env=="TRIAGE_VERIFY_MAX")|.default) = 21 | .knobs |= map(select(.env!="TRIAGE_RUNNERS"))'
suite d4 "$HOOKS"
[ "$RC" != 0 ] && ok || bad "D4: hooks suite must go red on a moved and a dropped contract knob"
grep -q '^FAIL: 9: TRIAGE_VERIFY_MAX' "$T/out.d4" && ok || bad "D4: no check-9 line for TRIAGE_VERIFY_MAX: $(grep '^FAIL' "$T/out.d4")"
grep -q '^FAIL: 9: TRIAGE_RUNNERS .*(got \[\])' "$T/out.d4" && ok || bad "D4: no check-9 line for the dropped TRIAGE_RUNNERS: $(grep '^FAIL' "$T/out.d4")"

# ---------- D5 a re-apply that clobbers an operator edit (AC3) ---------------
restore; add_row 'INSERT OR REPLACE'; add_script x
suite d5 "$HOOKS"
[ "$RC" != 0 ] && ok || bad "D5: hooks suite must go red when a re-apply overwrites an operator edit"
grep '^FAIL: 7:' "$T/out.d5" | grep -q 'overwrote 1 operator-edited rows' && ok || bad "D5: no check-7 line for the clobbered edit: $(grep '^FAIL' "$T/out.d5")"

# ---------- D6 BH-2577 still pins its own ten rows (AC4) ---------------------
restore
python3 - "$SCHEMA" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
i = next(n for n, l in enumerate(lines) if l.startswith("  ('lane-silent',"))
assert lines[i - 1].startswith("INSERT OR IGNORE INTO alert_family_scripts")
del lines[i - 1:i + 1]
open(p, "w").write("\n".join(lines))
PY
suite d6 "$SEEDS"
[ "$RC" != 0 ] && ok || bad "D6: seeds suite must go red with one seed-bh-2544 row removed"
grep -q '^FAIL: R1: .*9 rows, want 10' "$T/out.d6" && ok || bad "D6: no R1 '9 rows, want 10' line: $(grep '^FAIL' "$T/out.d6")"
grep -q '^FAIL: B2: 9 seed statements, want 10' "$T/out.d6" && ok || bad "D6: no B2 '9 seed statements' line: $(grep '^FAIL' "$T/out.d6")"

# ---------- D7 a declared knob the composer does not carry through (AC3) ----
# No catalog edit alone can make bin/lanes-build.sh drop a knob, so the copy's
# composer is wrapped: the real one runs, then the probe knob is cut from what
# it wrote. Check 9's discovered half must name the knob it lost.
restore; jq_cat ".knobs += [$PROBE_KNOB]"
mv "$R/bin/lanes-build.sh" "$R/bin/lanes-build.real.sh"
cat > "$R/bin/lanes-build.sh" <<'STUB'
#!/bin/bash
"$(dirname "$0")/lanes-build.real.sh" "$@" || exit
to=; while [ $# -gt 0 ]; do [ "$1" = --to ] && to=$2; shift; done
[ -n "$to" ] && jq '(.lanes[]|select(.id=="alert-triage")|.knobs) |= map(select(.env!="TRIAGE_VERIFY_PROBE"))' "$to" > "$to.x" && mv "$to.x" "$to"
STUB
chmod +x "$R/bin/lanes-build.sh"
suite d7 "$HOOKS"
[ "$RC" != 0 ] && ok || bad "D7: hooks suite must go red on a declared knob the composer dropped"
grep -q '^FAIL: 9: knobs declared .*TRIAGE_VERIFY_PROBE' "$T/out.d7" && ok || bad "D7: no check-9 line naming TRIAGE_VERIFY_PROBE: $(grep '^FAIL' "$T/out.d7")"

echo "alert-triage-hooks-discovery.bh-4608: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
