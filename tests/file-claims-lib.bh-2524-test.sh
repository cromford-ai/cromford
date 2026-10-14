#!/bin/bash
# tests/file-claims-lib.bh-2524-test.sh — the fleet file-claims LIB (BH-2628,
# slice 2 of BH-2524) against the REAL worker route.
#
# _jobs_req is stubbed onto worker.fetch over ONE file-backed node:sqlite DB, so
# every fclaim_* call goes through the real router and the real SQL of
# worker/jobs/src/routes/file-claims.js:
#   S1. fclaim_put + fclaim_list_dir: one file per claiming key, first row per key wins,
#       the caller's own key included, .claimed_at TSV; fclaim_not_before_put +
#       fclaim_not_before_left; JC_MODULES untouched. S1-b: truncation on stderr.
#   S2. a ticket_id that is not key-shaped never becomes a path.
#   S3. the claim's ttl is FILE_CLAIM_TTL_S; unset gives the registry's 14400.
#   S4. the REAL bin/lib/jobs/req.sh against a dead port: every fclaim_* rc 1, no
#       stdout, and the outdir left empty.
# Run from anywhere: tests/file-claims-lib.bh-2524-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/file-claims.sh"
ROUTE="$DIR/worker/jobs/src/routes/file-claims.js"
[ -f "$LIB" ] && ok || bad "missing $LIB"
[ -f "$ROUTE" ] && ok || bad "missing $ROUTE"

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "file-claims-lib: SKIPPED, this node has no node:sqlite (CI's worker/jobs job runs the route suite)"
  echo "file-claims-lib: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
# core.js imports the GENERATED, git-ignored catalog/lanes.json statically.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --write >"$T/lb.out" 2>&1 \
  || bad "catalog/lanes.json could not be composed: $(cat "$T/lb.out")"

export HARNESS="$T" JOBS_HARNESS="$T" NODE_OPTIONS=--no-warnings
DB="$T/d1.sqlite"
cat >"$T/drv.mjs" <<EOF
import { readFileSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import worker from '$DIR/worker/jobs/src/index.js';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
const db = new DatabaseSync('$DB');
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
const [method, path, body] = process.argv.slice(2);
const res = await worker.fetch(new Request('https://jobs.test' + path, {
  method, headers: { authorization: 'Bearer s', 'content-type': 'application/json' },
  body: body ? body : undefined,
}), { DB: d1(db), HARNESS_SECRET: 's' });
process.stdout.write((await res.text()) + '\n' + res.status);
EOF
# The same rc mapping as bin/lib/jobs/req.sh's _jobs_req.
_jobs_req() {
  local out code
  out=$(node "$T/drv.mjs" "$1" "$2" "${3:-}") || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  case "$code" in
    2*) printf '%s' "$out"; return 0 ;;
    409) printf '%s' "$out"; return 9 ;;
    404) return 2 ;;
    *) return 1 ;;
  esac
}
sql() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1]);
  const r = db.prepare(process.argv[2]).all();
  for (const row of r) console.log(Object.values(row).join("\t"));' "$DB" "$1"; }
seed() {  # <id> <ticket> [status]
  sql "INSERT INTO jobs (id,project,ticket_id,kind,box,stage,status,created_at,updated_at)
       VALUES ('$1','cromford',$([ "$2" = NULL ] && echo NULL || echo "'$2'"),'build','boxA','execute','${3:-running}','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')" >/dev/null
}
# Create the schema (the driver's exec is idempotent) and widen job_claims.
node "$T/drv.mjs" GET "/api/file-claims?project=cromford" >/dev/null || bad "driver could not reach the worker"

# shellcheck source=/dev/null
. "$LIB"

# --- S1 -----------------------------------------------------------------------
seed j1 BH-1; seed j2 BH-2
printf 'bin/a.sh\nbin/b.sh\n' >"$T/p1"; printf 'bin/c.sh\n' >"$T/p2"; printf 'bin/zzz.sh\n' >"$T/p1b"
( export JOB_ID=j1; fclaim_put "$T/p1" ) >"$T/o" 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/o" ] && ok || bad "S1 fclaim_put j1 rc=$rc out=[$(cat "$T/o")]"
fclaim_put "$T/p2" j2 >"$T/o" 2>&1 && [ ! -s "$T/o" ] && ok || bad "S1 fclaim_put j2 failed: $(cat "$T/o")"
sleep 1.1
seed j1b BH-1
fclaim_put "$T/p1b" j1b && ok || bad "S1 fclaim_put j1b failed"
mkdir -p "$T/out"
fclaim_list_dir cromford "$T/out" >"$T/o" 2>"$T/e"; rc=$?
[ "$rc" = 0 ] && ok || bad "S1 fclaim_list_dir rc=$rc err=[$(cat "$T/e")]"
[ ! -s "$T/o" ] && [ ! -s "$T/e" ] && ok || bad "S1 fclaim_list_dir printed out=[$(cat "$T/o")] err=[$(cat "$T/e")]"
cmp -s "$T/out/BH-1" "$T/p1" && ok || bad "S1 out/BH-1 is not the FIRST claim's list: [$(cat "$T/out/BH-1" 2>&1)]"
cmp -s "$T/out/BH-2" "$T/p2" && ok || bad "S1 out/BH-2 != planned files: [$(cat "$T/out/BH-2" 2>&1)]"
[ "$(ls -A "$T/out" | sort | tr '\n' ' ')" = ".claimed_at BH-1 BH-2 " ] && ok || bad "S1 outdir holds: $(ls -A "$T/out")"
[ "$(wc -l <"$T/out/.claimed_at")" = 2 ] \
  && grep -qxE $'BH-1\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' "$T/out/.claimed_at" \
  && grep -qxE $'BH-2\t[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z' "$T/out/.claimed_at" \
  && ok || bad "S1 .claimed_at is not two KEY<TAB>iso lines: [$(cat "$T/out/.claimed_at")]"
[ "$(grep $'^BH-1\t' "$T/out/.claimed_at" | cut -f2)" = "$(sql "SELECT files_claimed_at FROM job_claims WHERE job_id='j1'")" ] \
  && ok || bad "S1 .claimed_at BH-1 is not j1's (first) claim time"
fclaim_not_before_put 300 j1 && ok || bad "S1 fclaim_not_before_put failed"
left=$(fclaim_not_before_left cromford BH-1); rc=$?
[ "$rc" = 0 ] && [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -gt 290 ] && [ "$left" -le 300 ] && ok \
  || bad "S1 fclaim_not_before_left BH-1 rc=$rc left=[$left], want (290,300]"
left=$(fclaim_not_before_left cromford BH-2); rc=$?
[ "$rc" = 0 ] && [ -z "$left" ] && ok || bad "S1 fclaim_not_before_left BH-2 rc=$rc left=[$left], want rc 0 and nothing"
# The lib rides on jobs-client's _jobs_req; it is NOT a jobs-client module.
# Pinned without git history: the gate's isolated runner has no origin/main.
mods=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh")
[ -n "$mods" ] && ! grep -qiE 'claim|file' <<<"$mods" \
  && ! ls "$DIR"/bin/lib/jobs/*claim* >/dev/null 2>&1 && ok \
  || bad "S1 JC_MODULES changed or a claims module was added under bin/lib/jobs: [$mods]"

# S1-b: over the cap -> rc 0 and the exact INCOMPLETE line on stderr.
node -e '
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(process.argv[1]);
  const iso = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  const now = Date.now(); // determinism: ok fixture anchor for seeded claims
  for (let i = 0; i < 201; i++) {
    db.prepare("INSERT INTO jobs (id,project,ticket_id,kind,box,stage,status,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?)")
      .run("t" + i, "trunc", "TK-" + i, "build", "b", "execute", "running", iso(now), iso(now));
    db.prepare("INSERT INTO job_claims (job_id,planned_files,files_claimed_at,files_expires_at,updated_at) VALUES (?,?,?,?,?)")
      .run("t" + i, "f" + i, iso(now - 1000), iso(now + 3600000), iso(now));
  }' "$DB"
mkdir -p "$T/outt"
fclaim_list_dir trunc "$T/outt" >"$T/o" 2>"$T/e"; rc=$?
[ "$rc" = 0 ] && ok || bad "S1-b fclaim_list_dir rc=$rc"
[ "$(cat "$T/e")" = "FILE_CLAIMS_INCOMPLETE trunc: >200 live claims, remainder not judged" ] && ok \
  || bad "S1-b stderr=[$(cat "$T/e")]"
[ "$(wc -l <"$T/outt/.claimed_at")" = 200 ] && ok || bad "S1-b .claimed_at lines=$(wc -l <"$T/outt/.claimed_at")"

# --- S2 -----------------------------------------------------------------------
seed jx '../x'; fclaim_put "$T/p2" jx && ok || bad "S2 fclaim_put jx failed"
seed jn NULL; fclaim_put "$T/p2" jn && ok || bad "S2 fclaim_put jn failed"
seed jl "$(printf 'A%.0s' $(seq 65))"; fclaim_put "$T/p2" jl && ok || bad "S2 fclaim_put jl failed"
node "$T/drv.mjs" GET "/api/file-claims?project=cromford" | grep -q '"ticket_id":"../x"' && ok \
  || bad "S2 the worker does not list the ../x claim"
touch "$T/marker"; sleep 1.1
rm -rf "$T/out2"; mkdir -p "$T/out2/sub"
fclaim_list_dir cromford "$T/out2/sub" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "S2 fclaim_list_dir rc=$rc"
[ -f "$T/out2/sub/BH-1" ] && ok || bad "S2 BH-1 not written"
[ ! -e "$T/out2/x" ] && ok || bad "S2 ../x became a path"
[ "$(ls -A "$T/out2/sub" | sort | tr '\n' ' ')" = ".claimed_at BH-1 BH-2 " ] && ok || bad "S2 outdir holds: $(ls -A "$T/out2/sub")"
stray=$(find "$T" -newer "$T/marker" -type f ! -path "$T/out2/sub/*" ! -name 'd1.sqlite*' ! -path "$T/logs/*")
[ -z "$stray" ] && ok || bad "S2 files written outside the outdir: $stray"

# --- S3 -----------------------------------------------------------------------
span() { node -e '
  const { DatabaseSync } = require("node:sqlite");
  const r = new DatabaseSync(process.argv[1]).prepare("SELECT files_claimed_at a, files_expires_at b FROM job_claims WHERE job_id=?").get(process.argv[2]);
  console.log((Date.parse(r.b) - Date.parse(r.a)) / 1000);' "$DB" "$1"; }
( export FILE_CLAIM_TTL_S=120; fclaim_put "$T/p1" j1 ) && ok || bad "S3 fclaim_put ttl=120 failed"
[ "$(span j1)" = 120 ] && ok || bad "S3 ttl=120 gave span $(span j1)"
( unset FILE_CLAIM_TTL_S; fclaim_put "$T/p1" j1 ) && ok || bad "S3-b fclaim_put ttl unset failed"
[ "$(span j1)" = 14400 ] && ok || bad "S3-b unset ttl gave span $(span j1)"
( export FILE_CLAIM_TTL_S=30; fclaim_put "$T/p1" j1 ) >"$T/o" 2>&1; rc=$?
[ "$rc" != 0 ] && [ ! -s "$T/o" ] && ok || bad "S3-c out-of-range ttl=30 rc=$rc out=[$(cat "$T/o")] (must fail open)"
[ "$(span j1)" = 14400 ] && ok || bad "S3-c a refused ttl changed the claim"
printf '  \n\t\n' >"$T/blank"
fclaim_put "$T/blank" j1 >/dev/null 2>&1 && bad "S3-d a blank list returned 0" || ok
fclaim_put "$T/nope" j1 >/dev/null 2>&1 && bad "S3-d a missing file returned 0" || ok
( unset JOB_ID; fclaim_put "$T/p1" ) >/dev/null 2>&1 && bad "S3-d no job id returned 0" || ok
fclaim_put "$T/p1" 'a/../b' >/dev/null 2>&1 && bad "S3-d a path-shaped job id returned 0" || ok
fclaim_not_before_put 1.5 j1 >/dev/null 2>&1 && bad "S3-d a non-integer secs returned 0" || ok

# --- S4: the real transport, worker down --------------------------------------
( unset -f _jobs_req
  export JOBS_URL=http://127.0.0.1:9 HARNESS_SECRET=x JOBS_RETRIES=0 JOBS_TIMEOUT=2
  # shellcheck source=/dev/null
  . "$DIR/bin/jobs-client.sh" >/dev/null 2>&1
  command -v _jobs_req >/dev/null || { echo "NO_REQ"; exit 1; }
  rm -rf "$T/out4"; mkdir -p "$T/out4"
  for fn in put nbput list left; do
    case $fn in
      put)   out=$(fclaim_put "$T/p1" j1) ;;
      nbput) out=$(fclaim_not_before_put 60 j1) ;;
      list)  out=$(fclaim_list_dir cromford "$T/out4") ;;
      left)  out=$(fclaim_not_before_left cromford BH-1) ;;
    esac
    echo "$fn rc=$? out=[$out]"
  done
  echo "dir=[$(ls -A "$T/out4")]"
) >"$T/s4" 2>/dev/null
for fn in put nbput list left; do
  grep -qxF "$fn rc=1 out=[]" "$T/s4" && ok || bad "S4 $fn: $(grep "^$fn " "$T/s4")"
done
grep -qxF "dir=[]" "$T/s4" && ok || bad "S4 outdir not empty: $(grep '^dir=' "$T/s4")"
grep -q NO_REQ "$T/s4" && bad "S4 bin/jobs-client.sh did not define _jobs_req" || ok

echo "file-claims-lib: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
