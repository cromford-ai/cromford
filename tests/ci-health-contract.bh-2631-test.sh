#!/bin/bash
# tests/ci-health-contract.bh-2631-test.sh — BH-2517.0: the CI health seam.
#
# Pins the three additive D1 tables (flaky_quarantine, flaky_quarantine_changes,
# ci_health) as the deploy path's splitter hands them to D1, and the two box-side
# clients in bin/lib/jobs/cost.sh (metric_flake_quarantine_list, ci_health_put),
# loaded through the real bin/jobs-client.sh shim with a recording _jobs_req,
# plus one pass through the real _jobs_req against a stubbed curl that answers
# 404, which is what every box sees until the sibling routes land.
#
# Run from anywhere: tests/ci-health-contract.bh-2631-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/bin/lib/d1-schema.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- 1. the schema as the splitter emits it ----------------------------------
mapfile -t -d '' S < <(d1_schema_statements "$DIR/worker/jobs/schema.sql")
count_matching() { # count_matching <fixed-string> [must-also-contain]
  local n=0 s
  for s in "${S[@]}"; do
    case "$s" in *"$1"*) ;; *) continue ;; esac
    [ -n "${2:-}" ] && case "$s" in *"$2"*) ;; *) continue ;; esac
    n=$((n+1))
  done
  echo "$n"
}
stmt_of() { local s; for s in "${S[@]}"; do case "$s" in *"$1"*) printf '%s' "$s"; return 0 ;; esac; done; return 1; }

[ "$(count_matching 'CREATE TABLE IF NOT EXISTS flaky_quarantine (' 'PRIMARY KEY (repo, test)')" = 1 ] \
  && ok || bad "1a: want one flaky_quarantine statement with PRIMARY KEY (repo, test)"
[ "$(count_matching 'CREATE TABLE IF NOT EXISTS flaky_quarantine_changes (' 'AUTOINCREMENT')" = 1 ] \
  && ok || bad "1b: want one flaky_quarantine_changes statement with AUTOINCREMENT"
[ "$(count_matching 'CREATE TABLE IF NOT EXISTS ci_health (' 'PRIMARY KEY (repo, metric)')" = 1 ] \
  && ok || bad "1b: want one ci_health statement with PRIMARY KEY (repo, metric)"
[ "$(count_matching 'CREATE INDEX IF NOT EXISTS idx_flaky_quarantine_changes_rt ON flaky_quarantine_changes(repo, test, at)')" = 1 ] \
  && ok || bad "1c: want one idx_flaky_quarantine_changes_rt statement"

# Each statement is valid SQLite on its own, exactly as harness-sync sends it.
SQL_RUN=""
if command -v sqlite3 >/dev/null 2>&1; then SQL_RUN=sqlite3
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import sqlite3' 2>/dev/null; then SQL_RUN=python3
fi
if [ -z "$SQL_RUN" ]; then
  echo "note: 1d skipped, neither sqlite3 nor python3 sqlite3 on this box"
else
  ALL=""
  for k in 'CREATE TABLE IF NOT EXISTS flaky_quarantine (' 'CREATE TABLE IF NOT EXISTS flaky_quarantine_changes (' \
           'CREATE INDEX IF NOT EXISTS idx_flaky_quarantine_changes_rt' 'CREATE TABLE IF NOT EXISTS ci_health ('; do
    st=$(stmt_of "$k") || { ALL=""; break; }
    ALL="$ALL$st"$'\n'
  done
  # Check the columns land: insert one row per table and read it back.
  PROBE="${ALL}INSERT INTO flaky_quarantine VALUES ('r','t',1,'a','why','2026-09-26');
INSERT INTO flaky_quarantine_changes (repo,test,before_active,after_active,actor,reason,at) VALUES ('r','t',NULL,1,'a','why','2026-09-26');
INSERT INTO ci_health VALUES ('r','minutes','{}',NULL,'2026-09-26');
--PROBE
SELECT (SELECT count(*) FROM flaky_quarantine) || (SELECT count(*) FROM flaky_quarantine_changes) || (SELECT count(*) FROM ci_health);"
  if [ -z "$ALL" ]; then bad "1d: a statement is missing, nothing to run"
  elif [ "$SQL_RUN" = sqlite3 ]; then
    OUT=$(printf '%s\n' "$PROBE" | sqlite3 :memory: 2>&1)
    [ "$OUT" = "111" ] && ok || bad "1d: sqlite3 said: $OUT"
  else
    OUT=$(printf '%s\n' "$PROBE" | python3 -c '
import sqlite3, sys
c = sqlite3.connect(":memory:")
sql = sys.stdin.read()
head, sel = sql.split("--PROBE", 1)
c.executescript(head)
print(c.execute(sel).fetchone()[0])' 2>&1)
    [ "$OUT" = "111" ] && ok || bad "1d: python3 sqlite3 said: $OUT"
  fi
fi

# --- the real client modules, loaded through the shim -------------------------
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
echo 'HARNESS_SECRET=test-secret' > "$T/env/global.env"

# fn <fake-rc> <fake-body> <function> [args...] — run a client function with
# _jobs_req replaced by a recorder: one line "METHOD PATH" then the body.
fn() {
  local frc="$1" fbody="$2"; shift 2
  ( export HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    _jobs_req() { printf '%s %s\n%s\n' "$1" "$2" "${3:-}" >> "$T/req.log"; [ "$frc" -eq 0 ] || return "$frc"; printf '%s' "$fbody"; }
    "$@" )
}
reqs() { if [ -f "$T/req.log" ]; then grep -c '^[A-Z]* /' "$T/req.log"; else echo 0; fi; }

# --- 2. quarantine list prints .rows[].test one per line ----------------------
rm -f "$T/req.log"
OUT=$(fn 0 '{"rows":[{"test":"t1"},{"test":"t2"},{"reason":"no test field"}]}' metric_flake_quarantine_list example-org/x); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = $'t1\nt2' ] && ok || bad "2: rc=$RC out='$OUT', wanted 0 't1\\nt2'"

# The empty set is rc 0 and no output.
OUT=$(fn 0 '{"rows":[]}' metric_flake_quarantine_list example-org/x); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "2b: empty rows rc=$RC out='$OUT'"

# --- 3. transport failure is non-zero, never an empty rc-0 list ---------------
OUT=$(fn 1 '' metric_flake_quarantine_list example-org/x); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok || bad "3: transport fail rc=$RC out='$OUT', wanted non-zero and empty"

# --- 4. the request: sanitised slug and active=1; empty repo sends nothing ---
rm -f "$T/req.log"
fn 0 '{"rows":[]}' metric_flake_quarantine_list example-org/x >/dev/null
[ "$(head -1 "$T/req.log")" = "GET /api/metrics/flakes/quarantine?repo=example-org/x&active=1" ] \
  && ok || bad "4: request was '$(head -1 "$T/req.log")'"
rm -f "$T/req.log"
fn 0 '{"rows":[]}' metric_flake_quarantine_list 'a b;c' >/dev/null
[ "$(head -1 "$T/req.log")" = "GET /api/metrics/flakes/quarantine?repo=abc&active=1" ] \
  && ok || bad "4b: unsafe repo sent as '$(head -1 "$T/req.log")'"
rm -f "$T/req.log"
OUT=$(fn 0 '{"rows":[{"test":"t1"}]}' metric_flake_quarantine_list ''); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && [ "$(reqs)" = 0 ] && ok || bad "4c: empty repo rc=$RC out='$OUT' reqs=$(reqs)"
OUT=$(fn 0 '{"rows":[{"test":"t1"}]}' metric_flake_quarantine_list ';;  '); RC=$?
[ "$RC" -ne 0 ] && [ "$(reqs)" = 0 ] && ok || bad "4d: all-unsafe repo rc=$RC reqs=$(reqs)"

# --- 5. ci_health_put sends PUT /api/ci-health {repo,metric,payload,box} -----
rm -f "$T/req.log"
fn 0 '{"ok":true}' ci_health_put example-org/x minutes '{"used":5}'; RC=$?
LINE=$(sed -n 1p "$T/req.log"); BODY=$(sed -n 2p "$T/req.log")
[ "$RC" -eq 0 ] && [ "$LINE" = "PUT /api/ci-health" ] && ok || bad "5: rc=$RC request '$LINE'"
if [ "$(printf '%s' "$BODY" | jq -r '.repo')" = "example-org/x" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.metric')" = "minutes" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.payload|type')" = "object" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.payload.used')" = "5" ] \
   && [ "$(printf '%s' "$BODY" | jq -r '.box')" = "$(hostname)" ]; then ok
else bad "5b: body wrong: $BODY"; fi

# --- 6. an invalid payload sends nothing and fails ---------------------------
rm -f "$T/req.log"
fn 0 '{"ok":true}' ci_health_put example-org/x minutes '{nope'; RC=$?
[ "$RC" -ne 0 ] && [ "$(reqs)" = 0 ] && ok || bad "6: invalid payload rc=$RC reqs=$(reqs)"
rm -f "$T/req.log"
fn 0 '{"ok":true}' ci_health_put example-org/x '' '{"used":5}'; RC=$?
[ "$RC" -ne 0 ] && [ "$(reqs)" = 0 ] && ok || bad "6b: empty metric rc=$RC reqs=$(reqs)"

# --- 7. a failed PUT is non-zero ---------------------------------------------
fn 1 '' ci_health_put example-org/x minutes '{"used":5}'; RC=$?
[ "$RC" -ne 0 ] && ok || bad "7: failed PUT rc=$RC, wanted non-zero"

# --- 8. through the REAL _jobs_req: a worker without the routes answers 404 ---
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
printf '{"error":"unknown endpoint"}\n404\n'
EOF
chmod +x "$T/fakebin/curl"
real() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh" 2>/dev/null
    "$@" )
}
OUT=$(real metric_flake_quarantine_list example-org/x); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] && ok || bad "8: 404 quarantine list rc=$RC out='$OUT'"
real ci_health_put example-org/x minutes '{"used":5}' >/dev/null; RC=$?
[ "$RC" -ne 0 ] && ok || bad "8b: 404 ci_health_put rc=$RC"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
