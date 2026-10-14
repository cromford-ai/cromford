#!/bin/bash
# tests/utilization-route.bh-3988-test.sh — BH-4008 (BH-3988 tracer): the box
# side of /api/utilization and the table it lands in.
#
# The client is the REAL bin/jobs-client.sh (with its bin/lib/jobs/*.sh modules)
# copied into a scratch harness; only `curl` is a stub, so the real _jobs_req
# builds the request and classifies the status. The stub prints FAKE_BODY plus
# "\n<FAKE_CODE>" (exactly what `curl -w '\n%{http_code}'` prints) and records
# every argument it got, so assertions are on the wire, not on source text.
#
#   C1  utilization_put + 200: rc 0, the body carries project, hour, verdict,
#       the payload object, box and retention_days
#   C2  utilization_put + 500: rc 1
#   C3  utilization_put + 404 (route not deployed): rc 1, never "written" (D9)
#   C4  utilization_rows + 200 with rows: rc 0, raw body on stdout, the URL
#       carries url-encoded project= and since=
#   C5  utilization_rows + 200 with rows:[]: rc 2
#   C6  utilization_rows + 404: rc 1, never 2 "empty" (D11)
#   C7  utilization_rows + 503, transport failure, or a 200 that is not JSON
#       with a rows array: rc 1
#   S1  worker/jobs/schema.sql creates utilization_snapshots and its index, and
#       no DROP/DELETE line names the table (D20)
#   S2  JC_MODULES names utilization
#   N1  the node suite for the route (when node:sqlite is available)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/utilization-route.bh-3988-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

CLIENT_SRC="$DIR/bin/lib/jobs/utilization.sh"
ROUTE_SRC="$DIR/worker/jobs/src/routes/utilization.js"
LANE_SRC="$DIR/bin/utilization-push.sh"
VERDICT_SRC="$DIR/bin/lib/utilization.sh"
SECTION_SRC="$DIR/bin/lib/utilization/section-builds.sh"
for f in "$CLIENT_SRC" "$ROUTE_SRC" "$LANE_SRC" "$VERDICT_SRC" "$SECTION_SRC"; do
  [ -f "$f" ] && ok || bad "missing source $f"
done

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$T/stub"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$CURL_ARGS"
[ "${FAKE_CURL_RC:-0}" = 0 ] || exit "$FAKE_CURL_RC"
printf '%s\n%s' "${FAKE_BODY:-}" "${FAKE_CODE:-200}"
SH
chmod +x "$T/stub/curl"
export CURL_ARGS="$T/curl-args"

# drive <verb> <args...> — one call in a fresh shell with the real client.
# Prints stdout to $T/out and returns the verb's rc.
drive() {
  rm -f "$CURL_ARGS"
  env -i PATH="$T/stub:$PATH" HOME="$T" HARNESS="$H" HARNESS_ENV_DIR="$T/env" \
    JOBS_URL=http://jobs.test HARNESS_SECRET=s3cret JOBS_BOX=box-fixture JOBS_RETRY_SLEEP=0 \
    FAKE_BODY="${FAKE_BODY:-}" FAKE_CODE="${FAKE_CODE:-200}" FAKE_CURL_RC="${FAKE_CURL_RC:-0}" CURL_ARGS="$CURL_ARGS" \
    bash -c '. "$HARNESS/bin/jobs-client.sh" || exit 99; "$@"' _ "$@" > "$T/out" 2> "$T/err"
}
sent_body() { awk 'p{print; exit} /^--data-binary$/{p=1}' "$CURL_ARGS" 2>/dev/null; }
sent_url()  { tail -n 1 "$CURL_ARGS" 2>/dev/null; }
sent_method() { awk 'p{print; exit} /^-X$/{p=1}' "$CURL_ARGS" 2>/dev/null; }

PAY='{"builds":{"running":1,"pool_cap":3,"free_slots":2},"basis":{"builds":"measured"}}'

# ── C1 ──────────────────────────────────────────────────────────────────────
FAKE_BODY='{"ok":true}' FAKE_CODE=200 drive utilization_put acme 2026-10-03T18:00:00Z unknown "$PAY" 35; rc=$?
eq "C1 rc" "$rc" 0
eq "C1 method" "$(sent_method)" PUT
eq "C1 url" "$(sent_url)" "http://jobs.test/api/utilization"
eq "C1 body" "$(sent_body | jq -c '[.project,.hour,.verdict,.payload,.box,.retention_days]' 2>&1)" \
  "[\"acme\",\"2026-10-03T18:00:00Z\",\"unknown\",$PAY,\"box-fixture\",35]"
FAKE_BODY='{"ok":true}' FAKE_CODE=200 drive utilization_put acme 2026-10-03T18:00:00Z unknown "$PAY"; rc=$?
eq "C1 no retention rc" "$rc" 0
eq "C1 no retention: the key is absent, not 0" "$(sent_body | jq -c 'has("retention_days")')" false
# An invalid payload sends nothing.
FAKE_CODE=200 drive utilization_put acme 2026-10-03T18:00:00Z unknown 'not json'; rc=$?
eq "C1 invalid payload rc" "$rc" 1
[ -e "$CURL_ARGS" ] && bad "C1 an invalid payload still called curl" || ok

# ── C2 / C3 ─────────────────────────────────────────────────────────────────
FAKE_BODY='{"error":"boom"}' FAKE_CODE=500 drive utilization_put acme 2026-10-03T18:00:00Z unknown "$PAY"; rc=$?
eq "C2 500 rc" "$rc" 1
FAKE_BODY='{"error":"unknown endpoint","worker":"harness-jobs"}' FAKE_CODE=404 drive utilization_put acme 2026-10-03T18:00:00Z unknown "$PAY"; rc=$?
eq "C3 404 rc (never written)" "$rc" 1
FAKE_BODY='{"error":"utilization_snapshots schema not applied"}' FAKE_CODE=503 drive utilization_put acme 2026-10-03T18:00:00Z unknown "$PAY"; rc=$?
eq "C3 503 rc" "$rc" 1

# ── C4 ──────────────────────────────────────────────────────────────────────
ROWS='{"rows":[{"project":"a b","hour":"2026-10-03T18:00:00Z","verdict":"unknown","payload":{},"box":"hub","as_of":"2026-10-03T18:07:00Z"}],"as_of":"2026-10-03T18:07:00Z"}'
FAKE_BODY="$ROWS" FAKE_CODE=200 drive utilization_rows 'a b' 2026-10-01T00:00:00Z; rc=$?
eq "C4 rc" "$rc" 0
eq "C4 stdout is the raw body" "$(cat "$T/out")" "$ROWS"
eq "C4 method" "$(sent_method)" GET
eq "C4 url" "$(sent_url)" "http://jobs.test/api/utilization?project=a%20b&since=2026-10-01T00%3A00%3A00Z"

# ── C5 / C6 / C7 ────────────────────────────────────────────────────────────
FAKE_BODY='{"rows":[],"as_of":"x"}' FAKE_CODE=200 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C5 empty page rc" "$rc" 2
[ -s "$T/out" ] && bad "C5 printed on an empty page: $(cat "$T/out")" || ok
FAKE_BODY='{"error":"unknown endpoint"}' FAKE_CODE=404 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C6 404 rc (an outage, never empty)" "$rc" 1
FAKE_BODY='{"error":"x"}' FAKE_CODE=503 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C7 503 rc" "$rc" 1
FAKE_CURL_RC=7 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C7 transport rc" "$rc" 1
FAKE_BODY='<html>' FAKE_CODE=200 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C7 non-JSON 200 rc" "$rc" 1
[ -s "$T/out" ] && bad "C7 printed a non-JSON body: $(cat "$T/out")" || ok
FAKE_BODY='{"rows":"x"}' FAKE_CODE=200 drive utilization_rows acme 2026-10-01T00:00:00Z; rc=$?
eq "C7 rows-not-array rc" "$rc" 1
# Arguments are checked before any request.
drive utilization_rows acme; rc=$?
eq "C7 missing since rc" "$rc" 1
[ -e "$CURL_ARGS" ] && bad "C7 a missing argument still called curl" || ok

# ── S1 / S2 ─────────────────────────────────────────────────────────────────
SCHEMA="$DIR/worker/jobs/schema.sql"
grep -Fqx 'CREATE TABLE IF NOT EXISTS utilization_snapshots (project TEXT NOT NULL, hour TEXT NOT NULL, verdict TEXT NOT NULL, payload TEXT NOT NULL, box TEXT, as_of TEXT NOT NULL, PRIMARY KEY (project, hour));' "$SCHEMA" \
  && ok || bad "S1 schema.sql has no utilization_snapshots CREATE"
grep -Fqx 'CREATE INDEX IF NOT EXISTS idx_util_hour ON utilization_snapshots(hour);' "$SCHEMA" \
  && ok || bad "S1 schema.sql has no idx_util_hour"
n=$(grep -iE '^[^-]*\b(DROP|DELETE)\b' "$SCHEMA" | grep -c utilization_snapshots)
eq "S1 DROP/DELETE lines naming utilization_snapshots" "$n" 0
mods=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh")
case " $mods " in *" utilization "*) ok ;; *) bad "S2 JC_MODULES does not name utilization: $mods" ;; esac

# ── N1: the route's node suite, when this node has node:sqlite ──────────────
if command -v node >/dev/null && node -e 'require("node:sqlite")' 2>/dev/null; then
  ( cd "$DIR/worker/jobs" && node --test test/routes/utilization.bh-3988.test.js ) > "$T/node.out" 2>&1 \
    && ok || { bad "N1 node suite for $ROUTE_SRC failed"; tail -n 40 "$T/node.out"; }
else
  echo "N1 skipped: node:sqlite unavailable"
fi

echo "utilization-route: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
