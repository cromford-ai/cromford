#!/bin/bash
# tests/registry-seed-idempotent.bh-5649-test.sh — BH-5649 (the ticket's
# tests/registry-seed-idempotent-test.sh): bin/registry-seed.sh builds one
# import payload from today's fleet.conf, lane registry and cost-accounts.json,
# and importing it twice through the real worker route writes nothing the
# second time.
#
#   S1 two --emit runs are byte-identical; the payload holds every fleet.conf
#      row, every (lane, box) pair of the lane registry, and the box_aliases map
#   S2 POST twice through worker/jobs/src/routes/registry.js (node:sqlite):
#      the second run changes 0 rows, keeps version 1, writes no audit row
#   S3 one changed box IP is one changed row, version 2, one audit row
#   S4 --emit makes no network call
#   S5 one box at two IPs: rc 2, a named reason, no call
#   S6 a POST needs JOBS_URL, HARNESS_SECRET and REGISTRY_ADMIN_TOKEN; the
#      secrets never reach curl's argv; a 2xx is rc 0, anything else rc 1
#   W  the worker's own route suite (worker/jobs/test/registry.bh-5649.test.js)
#
# Run from anywhere: tests/registry-seed-idempotent.bh-5649-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SEED="$DIR/bin/registry-seed.sh"
DRIVE="$DIR/tests/lib/registry-import-drive.bh-5649.mjs"
ROUTE="$DIR/worker/jobs/src/routes/registry.js"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/stub" "$T/h"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
S="${CURL_STUB_DIR:?}"
{ printf '%s ' "$@" | tr '\n' ' '; echo; } >> "$S/calls"
prev=""
for a in "$@"; do
  [ "$prev" = -H ] && case "$a" in @*) cat "${a#@}" >> "$S/headers" ;; esac
  prev="$a"
done
rc=$(cat "$S/rc" 2>/dev/null); rc=${rc:-0}
[ "$rc" = 0 ] || exit "$rc"
cat "$S/body" 2>/dev/null
printf '\n%s' "$(cat "$S/http" 2>/dev/null || echo 200)"
SH
chmod +x "$T/bin/curl"
: > "$T/stub/calls"; echo 0 > "$T/stub/rc"; echo 200 > "$T/stub/http"
calls() { wc -l < "$T/stub/calls" | tr -d ' '; }
seed() { env PATH="$T/bin:$PATH" HARNESS="$T/h" CURL_STUB_DIR="$T/stub" "$SEED" "$@"; }

[ -f "$ROUTE" ] && ok || bad "no $ROUTE"

# ---- S1 / S4 deterministic emit, no network -----------------------------------------
seed --emit --root "$DIR" > "$T/a.json" 2>"$T/err"; R=$?
[ "$R" = 0 ] && ok || bad "S1 --emit rc $R: $(head -c 300 "$T/err")"
seed --emit --root "$DIR" > "$T/b.json" 2>/dev/null
[ -s "$T/a.json" ] && cmp -s "$T/a.json" "$T/b.json" && ok || bad "S1 two --emit runs differ (or are empty)"
[ "$(calls)" = 0 ] && ok || bad "S4 --emit made $(calls) network call(s)"
WANT_P=$(awk '!/^[[:space:]]*(#|$)/' "$DIR/fleet.conf" | wc -l | tr -d ' ')
WANT_R=$(awk '$1 == "#" && $2 == "@retired" && NF >= 3' "$DIR/fleet.conf" | wc -l | tr -d ' ')
GOT_P=$(jq '[.projects[] | select(.status == "active")] | length' "$T/a.json" 2>/dev/null)
GOT_R=$(jq '[.projects[] | select(.status == "retired")] | length' "$T/a.json" 2>/dev/null)
[ "$GOT_P" = "$WANT_P" ] && [ "$WANT_P" -ge 10 ] && ok || bad "S1 active projects: payload $GOT_P, fleet.conf $WANT_P"
[ "$GOT_R" = "$WANT_R" ] && ok || bad "S1 retired projects: payload $GOT_R, fleet.conf $WANT_R"
. "$DIR/bin/lib/lanes-registry.sh"
LJ=$(lanes_json_path "$DIR")
WANT_L=$(jq '[.lanes[] | .id as $l | (.boxes // [])[] | [$l, .]] | unique | length' "$LJ")
GOT_L=$(jq '.lane_boxes | length' "$T/a.json" 2>/dev/null)
[ "$GOT_L" = "$WANT_L" ] && [ "$WANT_L" -gt 100 ] && ok || bad "S1 lane rows: payload $GOT_L, lane registry $WANT_L"
[ "$(jq -r '.boxes[] | select(.box == "box-hub") | .cost_box' "$T/a.json" 2>/dev/null)" = hub ] \
  && ok || bad "S1 box_aliases: box-hub has no row with cost_box hub"
[ "$(jq -r '.boxes[] | select(.box == "box-project-3-2") | .box_id' "$T/a.json" 2>/dev/null)" = project-3 ] \
  && ok || bad "S1 box_id: box-project-3-2 is not project-3"
[ "$(jq -r '.projects[] | select(.project == "project-1") | "\(.position) \(.box) \(.prod)"' "$T/a.json" 2>/dev/null)" \
  = "0 box-project-1-1 https://os.project-1.example" ] && ok || bad "S1 project-1 row is wrong"
[ "$(jq -r '.box_accounts[] | select(.box == "pool-*") | .kind' "$T/a.json" 2>/dev/null | head -1)" = jobs ] \
  && ok || bad "S1 box_accounts: the pool-* jobs glob is missing"
[ "$(jq -r '.boxes[] | select(.box == "box-small") | "\(.standby_hub_name) \(.standby_hub_id)"' "$T/a.json" 2>/dev/null)" \
  = "box-hub hub" ] && ok || bad "S1 the @standby directive is not on box-small"

# ---- S2 / S3 twice through the real route ---------------------------------------------
jq '(.boxes[] | select(.box == "box-project-4-1") | .tailnet_ip) = "100.0.0.8"' "$T/a.json" > "$T/c.json"
OUT=$(cd "$DIR/worker/jobs" && node "$DRIVE" "$T/a.json" "$T/a.json" "$T/c.json" 2>"$T/node.err"); R=$?
if [ "$R" = 3 ]; then
  echo "SKIP: S2/S3 node:sqlite is not available"
elif [ "$R" != 0 ]; then
  bad "S2 the import driver failed rc $R: $(head -c 400 "$T/node.err")"
else
  q() { jq -r "$1" <<<"$OUT"; }
  [ "$(q '.posts[0].status')" = 200 ] && [ "$(q '.posts[0].changed > 0')" = true ] && [ "$(q '.posts[0].version')" = 1 ] \
    && ok || bad "S2 first import: $(q '.posts[0]')"
  [ "$(q '.posts[0].rows.projects')" = "$((GOT_P + GOT_R))" ] && [ "$(q '.posts[0].rows.lane_boxes')" = "$GOT_L" ] \
    && ok || bad "S2 first import stored $(q '.posts[0].rows')"
  [ "$(q '.posts[1].changed')" = 0 ] && [ "$(q '.posts[1].version')" = 1 ] && ok || bad "S2 second import: $(q '.posts[1]')"
  [ "$(q '.posts[0].rows == .posts[1].rows')" = true ] && ok || bad "S2 row counts moved on the second run"
  [ "$(q '.posts[0].audit == .posts[1].audit')" = true ] && ok || bad "S2 the second run wrote audit rows"
  [ "$(q '.posts[2].changed')" = 1 ] && [ "$(q '.posts[2].version')" = 2 ] && ok || bad "S3 third import: $(q '.posts[2]')"
  [ "$(q '.posts[2].audit - .posts[1].audit')" = 1 ] && ok || bad "S3 want exactly 1 new audit row"
  [ "$(q '.audit[-1] | (.old_value | contains("10.0.0.4")) and (.new_value | contains("100.0.0.8")) and .entity == "box"')" = true ] \
    && ok || bad "S3 the audit row lacks the old and new IP: $(q '.audit[-1]')"
fi

# ---- S5 conflicting IPs refuse ---------------------------------------------------------
mkdir -p "$T/r5/catalog"
cp "$DIR/catalog/cost-accounts.json" "$T/r5/catalog/"
echo '{"lanes":[{"id":"demo","boxes":["small"]}]}' > "$T/r5/lanes.json"
cat > "$T/r5/fleet.conf" <<'EOF'
a-os Acme/a-os - - 1 box-small 10.1.1.1
b-os Acme/b-os - - 2 box-small 10.1.1.2
EOF
: > "$T/stub/calls"
OUT=$(env LANE_REGISTRY="$T/r5/lanes.json" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
  REGISTRY_ADMIN_TOKEN=fixture-admin-token PATH="$T/bin:$PATH" HARNESS="$T/h" CURL_STUB_DIR="$T/stub" \
  "$SEED" --root "$T/r5" 2>&1); R=$?
[ "$R" = 2 ] && ok || bad "S5 two IPs for one box: rc $R, want 2 ($OUT)"
grep -q 'box-small' <<<"$OUT" && grep -qi 'ip' <<<"$OUT" && ok || bad "S5 the reason does not name the box: $OUT"
[ "$(calls)" = 0 ] && ok || bad "S5 a refused payload still made $(calls) call(s)"

# ---- S6 POST needs all three values ------------------------------------------------------
OUT=$(env JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret PATH="$T/bin:$PATH" HARNESS="$T/h" \
  CURL_STUB_DIR="$T/stub" "$SEED" --root "$DIR" 2>&1); R=$?
[ "$R" = 2 ] && grep -q REGISTRY_ADMIN_TOKEN <<<"$OUT" && ok || bad "S6 no admin token: rc $R ($OUT)"
OUT=$(env JOBS_URL=https://jobs.test REGISTRY_ADMIN_TOKEN=fixture-admin-token PATH="$T/bin:$PATH" HARNESS="$T/h" \
  CURL_STUB_DIR="$T/stub" "$SEED" --root "$DIR" 2>&1); R=$?
[ "$R" = 2 ] && grep -q HARNESS_SECRET <<<"$OUT" && ok || bad "S6 no secret: rc $R ($OUT)"
[ "$(calls)" = 0 ] && ok || bad "S6 a refused POST still made $(calls) call(s)"
# TEST-CHANGE (BH-5651): the seeder now asks GET /api/registry/version first and
# refuses a seeded registry without --force. This stub answers every call with
# the same body, so S6 passes --force to keep pinning the POST itself; the
# guard has its own cases in tests/registry-export.bh-5651-test.sh.
post() { env JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret REGISTRY_ADMIN_TOKEN=fixture-admin-token \
  PATH="$T/bin:$PATH" HARNESS="$T/h" CURL_STUB_DIR="$T/stub" "$SEED" --root "$DIR" --force "$@"; }
printf '%s' '{"ok":true,"changed":0,"version":1,"stale":["box:x"]}' > "$T/stub/body"; echo 200 > "$T/stub/http"
OUT=$(post 2>&1); R=$?
[ "$R" = 0 ] && [ "$OUT" = "registry-seed: changed=0 version=1 stale=1" ] && ok || bad "S6 a 200 answer: rc $R '$OUT'"
grep -q 'jobs.test/api/registry/import' "$T/stub/calls" && ok || bad "S6 the POST did not go to /api/registry/import"
grep -qE 'fixture-admin-token|fixture-secret' "$T/stub/calls" && bad "S6 a secret reached curl's argv" || ok
grep -q '^x-registry-admin-token: fixture-admin-token$' "$T/stub/headers" 2>/dev/null \
  && grep -q '^authorization: Bearer fixture-secret$' "$T/stub/headers" && ok || bad "S6 the header file did not carry both credentials"
STRAY=$(ls -A "$T/h/state/registry" 2>/dev/null | grep -vx '\.seed\.lock')
[ -z "$STRAY" ] && ok || bad "S6 the seeder left files behind: $STRAY"
printf '%s' '{"error":"registry writes need the registry admin token"}' > "$T/stub/body"; echo 403 > "$T/stub/http"
OUT=$(post 2>&1); R=$?
[ "$R" = 1 ] && grep -q 'http=403' <<<"$OUT" && ok || bad "S6 a 403 answer: rc $R '$OUT'"
echo 7 > "$T/stub/rc"
post >/dev/null 2>&1; R=$?
[ "$R" = 1 ] && ok || bad "S6 a transport failure: rc $R, want 1"
echo 0 > "$T/stub/rc"
post --actor 'bad actor' >/dev/null 2>&1; R=$?
[ "$R" = 2 ] && ok || bad "S6 a bad --actor: rc $R, want 2"

# ---- W the worker route suite ---------------------------------------------------------------
if (cd "$DIR/worker/jobs" && node --test test/registry.bh-5649.test.js >"$T/w.out" 2>&1); then ok
else bad "W worker/jobs/test/registry.bh-5649.test.js failed: $(grep -m3 'not ok' "$T/w.out")"; fi

echo "registry-seed-idempotent: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
