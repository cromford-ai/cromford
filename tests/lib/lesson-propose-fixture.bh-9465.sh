#!/bin/bash
# tests/lib/lesson-propose-fixture.bh-9465.sh — the shared fixture of the
# bin/lesson-propose.sh suites (BH-5807). Sourced after tests/lib/scratch.sh,
# with LP_NAME set to the suite's name for its summary line. Never executed.
#
# The suites: tests/lesson-propose.bh-5807-test.sh (files, M1, C1, A1, A2,
# L1-L5), tests/lesson-propose-cooldown.bh-9465-test.sh (L6-L12),
# tests/lesson-propose-delivery.bh-9465-test.sh (L13-L18) and
# tests/lesson-propose-ledger.bh-9465-test.sh (L19, K, T, the worker node suite).
#
# WHAT IS STUBBED. bin/agent-call.sh (it counts calls and answers from
# $FXT/answer with rc $FXT/ac.rc), GET /api/settings (empty), and `gh` on PATH:
# a small fake GitHub that answers `api -i -X <METHOD> <path>` from the files
# under $FXT/gh (issues/<n>.json, pulls/<n>.json, repo/<path>), records every
# call in $FXT/gh.log and every --input body in $FXT/gh/in.<n>.json. Nothing
# here reaches a model, GitHub or the real worker. The worker's clock and the
# lane's clock are both pinned to $NOW (D60).
#
# At source time: the jobs schema render, the llm-sites compose, the counters
# and check helpers. Each suite then sets LANE, ROUTE, FRAG and CRON and calls
# lp_setup. lp_setup builds the worker driver over a sqlite file from the REAL
# jobs schema, the scratch harness, the fake curl and gh, and the
# reset/run/finding helpers. It exits the suite (with its summary line) when the
# lane is missing, or node:sqlite or catalog/lanes.json is absent.
: "${LP_NAME:=lesson-propose}"
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "$LP_NAME: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

lp_setup() {
if [ ! -f "$LANE" ]; then
  echo "$LP_NAME: $PASS passed, $FAIL failed"; exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "$LP_NAME: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "$LP_NAME: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "$LP_NAME: lane sections SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
  echo "$LP_NAME: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-14T12:00:00Z
NOW_S=$(date -u -d "$NOW" +%s)
iso_ago() { date -u -d "@$((NOW_S - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { routes as bf } from '$ROUTE';
import { routes as lg } from '$DIR/worker/jobs/src/routes/ledger.js';
import { routes as mr } from '$DIR/worker/jobs/src/routes/model-routes.js';
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
if (method === 'GET' && path === '/api/settings') out(200, { settings: [] });
// Outage switches: a file named fail.<METHOD>.<route> answers 500.
const sw = T + '/fail.' + method + '.' + path.replace(/\//g, '_');
if (existsSync(sw)) out(500, { error: 'fixture outage' });
const db = new DatabaseSync(T + '/d1.sqlite');
const hit = matchRoute([...bf, ...lg, ...mr], method, path);
if (!hit) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
let body = null;
if (bodyFile) { try { body = JSON.parse(readFileSync(bodyFile, 'utf8')); } catch { body = null; } }
const res = await hit.handler({ env: { DB: d1(db) }, url, path, t: process.env.FXT_NOW, body, m: hit.m });
process.stdout.write(await res.text() + '\n' + res.status);
JS
cat > "$T/q.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [sql, ...binds] = process.argv.slice(2);
const st = db.prepare(sql);
if (/^\s*(select|with)/i.test(sql)) console.log(JSON.stringify(st.all(...binds)));
else { const r = st.run(...binds); console.log(JSON.stringify([{ id: Number(r.lastInsertRowid) }])); }
JS
cat > "$T/mkdb.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const db = new DatabaseSync(process.argv[2]);
const sql = readFileSync('$DIR/worker/jobs/schema.sql', 'utf8');
db.exec(sql);
db.exec(sql);
JS
export FXT="$T" FXT_NOW="$NOW" NODE_NO_WARNINGS=1
# Every node process that loads the worker test lib writes a 748 KB
# jobs-schema-* dir under os.tmpdir() and never removes it. A run spawns
# about 9100 of them (one full run of the old single file), so each node
# call gets a TMPDIR inside the scratch tree, which the EXIT trap removes.
mkdir -p "$T/nodetmp" || exit 1
if TMPDIR="$T/nodetmp" node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err"; then ok
else bad "S1 schema.sql applies twice: $(head -3 "$T/mkdb.err")"; fi
q() { TMPDIR="$T/nodetmp" node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/flags" "$H/bin" "$T/fakebin"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv | lane | role | fp | no-tools
printf '%s|%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_ROLE:-}" "${AGENT_CALL_FP:-}" "${AGENT_CALL_NO_TOOLS:-}" >> "$FXT/agentcalls"
n=$(grep -c . "$FXT/agentcalls")
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
cat "$FXT/answer" > "$5"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"
# The lane and the jobs client it sources by $SELF (the closure follows bin/lib only).
for L in bin/lesson-propose.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/lanes.json" "$H/catalog/"
: > "$H/env/global.env"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary|-d|--data) data="$2"; [ "$method" = GET ] && method=POST; shift 2 ;;
    -o|-w|-H|-m|--max-time|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  "$JOBS_URL"/*)
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "$FXT/body.XXXXXX")
      case "$data" in @*) cp "${data#@}" "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
      printf '%s %s %s\n' "$method" "${url#"$JOBS_URL"}" "$(cat "$bf")" >> "$FXT/reqlog"
    else
      printf '%s %s\n' "$method" "${url#"$JOBS_URL"}" >> "$FXT/reqlog"
    fi
    TMPDIR="$FXT/nodetmp" node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
# The fake GitHub. State lives under $FXT/gh: issues/<n>.json and pulls/<n>.json
# are the repo's issues and PRs (a POST adds one), repo/<path> is main's tree,
# refs lists the branches created, <name>.status overrides one answer's status.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
G="$FXT/gh"
[ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ "${3:-}" = -X ] || { printf 'gh %s\n' "$*" >> "$FXT/net.log"; exit 7; }
m="$4"; p="$5"; shift 5
input=""; page=1
while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    -f|-F) case "$2" in page=*) page="${2#page=}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
n_in=0
if [ -n "$input" ]; then n_in=$(( $(ls "$G"/in.*.json 2>/dev/null | wc -l) + 1 )); cp "$input" "$G/in.$n_in.json"; printf '%s %s in.%s\n' "$m" "$p" "$n_in" >> "$FXT/gh.in.log"; fi
st() { cat "$G/$1.status" 2>/dev/null || echo "$2"; }
R=example-org/cromford
path="${p%%\?*}"; query=""; [ "$path" != "$p" ] && query="${p#*\?}"
next() { local c; c=$(cat "$G/counter" 2>/dev/null || echo 7000); c=$((c + 1)); echo "$c" > "$G/counter"; echo "$c"; }
list() { # list <dir> <statusname>
  local s; s=$(st "$2" 200)
  [ "$s" = 200 ] || { restpr --raw "$s" '{"message":"fixture"}'; exit 0; }
  if [ "$page" != 1 ]; then restpr --raw 200 '[]'; exit 0; fi
  restpr --raw 200 "$(cat "$G/$1"/*.json 2>/dev/null | jq -sc '[.[] | select(.state == "open")]')"; exit 0
}
case "$m $path" in
  "GET repos/$R/issues") list issues issues.list ;;
  "GET repos/$R/pulls") list pulls pulls.list ;;
  "GET repos/$R/pulls/"*/files) restpr --raw 200 "$(cat "$G/files.json" 2>/dev/null || echo '[{"filename":"bin/x.sh","patch":"@@ -1 +1 @@\n-old line\n+new line"}]')"; exit 0 ;;
  "GET repos/$R/pulls/"*) n=${path##*/}; [ -f "$G/pulls/$n.json" ] && restpr --raw 200 "$(cat "$G/pulls/$n.json")" || restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
  "GET repos/$R/issues/"*) n=${path##*/}; [ -f "$G/issues/$n.json" ] && restpr --raw 200 "$(cat "$G/issues/$n.json")" || restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
  "GET repos/$R/contents/"*)
    f="${path#repos/$R/contents/}"; ref="${query#ref=}"
    [ -f "$G/repo/$f" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
    restpr --raw "$(st contents.get 200)" "$(jq -nc --arg c "$(base64 -w0 < "$G/repo/$f")" --arg s "blob-$ref" '{sha:$s, content:$c, encoding:"base64"}')"; exit 0 ;;
  "GET repos/$R/git/ref/heads/main") restpr --raw 200 '{"object":{"sha":"c0ffee0000000000000000000000000000000000"}}'; exit 0 ;;
  "GET repos/$R/git/ref/heads/"*) br="${path#repos/$R/git/ref/heads/}"; grep -qxF "$br" "$G/refs" 2>/dev/null && restpr --raw 200 '{"object":{"sha":"c0ffee"}}' || restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
  "POST repos/$R/git/refs")
    br=$(jq -r '.ref | sub("^refs/heads/"; "")' "$input")
    if grep -qxF "$br" "$G/refs" 2>/dev/null; then restpr --raw 422 '{"message":"Reference already exists"}'; exit 0; fi
    echo "$br" >> "$G/refs"; restpr --raw 201 '{"ref":"x"}'; exit 0 ;;
  "PUT repos/$R/contents/"*) restpr --raw "$(st contents.put 200)" '{"content":{"sha":"new"}}'; exit 0 ;;
  "POST repos/$R/pulls")
    s=$(st pulls.post 201); [ "$s" = 201 ] || { restpr --raw "$s" '{"message":"fixture"}'; exit 0; }
    n=$(next); jq -c --argjson n "$n" '{number:$n, state:"open", merged_at:null, title, body, head:{ref:.head}, html_url:("https://github.com/example-org/cromford/pull/" + ($n|tostring))}' "$input" > "$G/pulls/$n.json"
    restpr --raw 201 "$(cat "$G/pulls/$n.json")"; exit 0 ;;
  "POST repos/$R/issues")
    s=$(st issues.post 201); [ "$s" = 201 ] || { restpr --raw "$s" '{"message":"fixture"}'; exit 0; }
    n=$(next); jq -c --argjson n "$n" '{number:$n, state:"open", state_reason:null, closed_at:null, title, body, labels:[.labels[]? | {name:.}], html_url:("https://github.com/example-org/cromford/issues/" + ($n|tostring))}' "$input" > "$G/issues/$n.json"
    restpr --raw 201 "$(cat "$G/issues/$n.json")"; exit 0 ;;
esac
printf 'gh %s %s\n' "$m" "$p" >> "$FXT/net.log"; exit 7
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=test JOBS_RETRIES=0
unset LESSON_PROPOSE_ENABLED LESSON_PROPOSE_MAX_PER_TICK LESSON_PROPOSE_TIMEOUT_S HARNESS_REPO 2>/dev/null || true

# The two prompt files on the fake main, in the shape the real ones have: a §10
# list that ends with the `- docs/OPERATING` bullet, then `## 11.`; and a
# build-discipline with **D<n> rules up to D66.
plan_fixture() {
  cat <<'EOF'
# Plan contract

## 10. Operating lessons (BH-5289)

- A first lesson.
- A second lesson.
- docs/OPERATING.md has the reasons and the knobs.

## 11. Conflict discipline
EOF
}
bd_fixture() {
  cat <<'EOF'
# Build discipline

## A. Tests
- **D1 Mutation-check before you claim a test.** Break it once.
- **D65 A test belongs to its ticket (D51, enforced).** Put it in its own file.

## Added 2026-10-13 (BH-6394): stacked commits
- **D66 A PR carries only its own ticket's commits (enforced).** Never rebase.
EOF
}

reset() {
  local p
  for p in reqlog agentcalls net.log gh.log gh.in.log out rc ac.rc answer gh; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/prompt.* "$T"/fail.*
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
  mkdir -p "$T/gh/issues" "$T/gh/pulls" "$T/gh/repo/prompts"
  plan_fixture > "$T/gh/repo/prompts/plan-contract.md"
  bd_fixture > "$T/gh/repo/prompts/build-discipline.md"
  VID=500; PRN=600
}
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LESSON_PROPOSE_NOW="$NOW" "$@" bash "$H/bin/lesson-propose.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()      { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls()  { n "$T/agentcalls"; }
ghn()    { local c; c=$(grep -cE "^$1 $2\$" "$T/gh.log" 2>/dev/null); printf '%s' "${c:-0}"; }
writes() { local c; c=$(grep -cE '^(POST|PUT|PATCH|DELETE) ' "$T/gh.log" 2>/dev/null); printf '%s' "${c:-0}"; }
claims() { local c; c=$(grep -c '^POST /api/ledger/claim ' "$T/reqlog" 2>/dev/null); printf '%s' "${c:-0}"; }
R=example-org/cromford
# finding <category> [raw] [infra 0|1] [days]: one new BLOCK verdict (its own PR)
# with one finding, the rows POST /api/block-classify/settle writes. Sets FID to the
# verdict id (a global, never $( ): the counters must survive the call).
finding() {
  VID=$((VID + 1)); PRN=$((PRN + 1))
  q "INSERT INTO verdicts (id, repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at) VALUES (?, '$R', ?, ?, 'BLOCK', 'lead', 'mac-lead', ?, 'n', ?)" \
    "$VID" "$PRN" "$(printf 'b%.0s' $(seq 40))" "https://github.com/$R/pull/$PRN#lr" "$(iso_ago "${4:-1}")" >/dev/null
  q "INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, raw_category, confidence, cause, files, infra_false, text, model, verdict_at, created_at) VALUES (?, 1, '$R', ?, 'BH-9001', ?, 'lead', ?, ?, 0.8, ?, '[\"bin/x.sh\"]', ?, ?, 'm', ?, ?)" \
    "$VID" "$PRN" "$(printf 'b%.0s' $(seq 40))" "$1" "${2:-}" "cause of $VID" "${3:-0}" "- [BLOCK] bin/x.sh:$VID: finding of verdict $VID" "$(iso_ago "${4:-1}")" "$(iso_ago "${4:-1}")" >/dev/null
  FID=$VID
}
# trig <category> <k>: k verdicts in one category. Sets IDS (comma list, sorted).
trig() { local i ids=(); for ((i = 0; i < $2; i++)); do finding "$1"; ids+=("$FID"); done; IDS=$(printf '%s\n' "${ids[@]}" | sort -n | paste -sd,); }
fp_of() { printf '%s|%s' "$1" "$2" | sha256sum | cut -c1-16; }
led()     { q "SELECT status, detail FROM ledgers WHERE kind='lesson_proposal' AND key=?" "$1" | jq -c '.[0] // {}'; }
led_st()  { led "$1" | jq -r '.status // "none"'; }
led_d()   { led "$1" | jq -r --arg f "$2" '(.detail // "{}") | fromjson | .[$f] // "null" | tostring'; }
put_led() { q "INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at) VALUES ('lesson_proposal', ?, ?, 't', ?, ?, ?)" "$1" "$2" "$3" "${4:-$NOW}" "${4:-$NOW}" >/dev/null; }
# put_content <n>: the decoded content of the n-th PUT body.
put_content() { local f; f=$(grep '^PUT ' "$T/gh.in.log" | sed -n "${1}p" | awk '{print $3}'); jq -r '.content' "$T/gh/$f.json" | base64 -d; }
put_path()    { grep '^PUT ' "$T/gh.in.log" | sed -n "${1}p" | awk '{print $2}'; }
loglast() { tail -1 "$H/logs/lesson-propose.log" 2>/dev/null; }

PLAN='{"target":"plan-lesson","title":"Make every new test fail once","text":"A plan names one mutation per acceptance test — and the test it turns red.","acceptance_tests":[],"why":"3 BLOCKs had tests that could not fail"}'
BUILDER='{"target":"builder-rule","title":"Break each new test once.","text":"Break the code each new test pins and watch the test go red before you commit.","acceptance_tests":[],"why":"tests that cannot fail"}'
CHECK='{"target":"check","title":"Lint tests that cannot fail","text":"Add a check that runs each new suite against a mutated tree.","acceptance_tests":["a suite that stays green under mutation is red","a suite that goes red under mutation passes"],"why":"tests that cannot fail"}'
}
