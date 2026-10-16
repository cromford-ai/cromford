#!/bin/bash
# tests/lesson-propose.bh-5807-test.sh — BH-5807 (BH-5794.2): propose fixes for
# repeat causes. Drives the SHIPPED bin/lesson-propose.sh against the REAL
# worker routes (worker/jobs/src/routes/lesson-propose.js, ledger.js and
# model-routes.js) over a node:sqlite file built from the REAL jobs schema
# (composed from schema.d/).
#
# WHAT IS STUBBED. bin/agent-call.sh (it counts calls and answers from
# $FXT/answer with rc $FXT/ac.rc), GET /api/settings (empty), and `gh` on PATH:
# a small fake GitHub that answers `api -i -X <METHOD> <path>` from the files
# under $FXT/gh (issues/<n>.json, pulls/<n>.json, repo/<path>), records every
# call in $FXT/gh.log and every --input body in $FXT/gh/in.<n>.json. Nothing
# here reaches a model, GitHub or the real worker. The worker's clock and the
# lane's clock are both pinned to $NOW (D60).
#
# Sections: L1-L18 (the plan's acceptance cases, with L8b, L18b-L18d
# from the refute review), L19 (the 4000-char ledger detail), K (knobs), T (triggers
# unreadable), A (the real prompt files carry the anchors the lane edits), M
# and C (no model literal, the cron line), then the worker's own node suite.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-propose.bh-5807-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "lesson-propose: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/lesson-propose.sh"
ROUTE="$DIR/worker/jobs/src/routes/lesson-propose.js"
FRAG="$DIR/worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql"
CRON="$DIR/cron/lanes/733-lesson-propose.cron"
for f in "$LANE" "$FRAG" "$CRON" "$DIR/catalog/lanes.d/lesson-propose.json" "$DIR/catalog/llm-sites.d/5807-lesson-propose.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "M1 no hardcoded model string in the lane or the schema fragment" \
  '[ -f "$LANE" ] && [ -f "$FRAG" ] && ! grep -nE "claude-(opus|sonnet|haiku|fable)|grok-[0-9]" "$LANE" "$FRAG"'
check "C1 cron: daily at 06:41, behind the hub lease" \
  'grep -qE "^41 6 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/lesson-propose.sh " "$CRON" 2>/dev/null'
# A: the lane edits the real prompt files at run time; their anchors must exist.
check "A1 plan-contract §10 ends with the '- docs/OPERATING' bullet the lane inserts above" \
  'awk "/^## 10\\./{s=1;next} /^## /{s=0} s" "$DIR/prompts/plan-contract.md" | grep -q "^- docs/OPERATING"'
check "A2 build-discipline carries **D<n> rules the lane numbers after" \
  'grep -qE "^- \*\*D[0-9]+ " "$DIR/prompts/build-discipline.md"'
if [ ! -f "$LANE" ]; then
  echo "lesson-propose: $PASS passed, $FAIL failed"; exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "lesson-propose: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "lesson-propose: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "lesson-propose: lane sections SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
  echo "lesson-propose: $PASS passed, $FAIL failed"
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
if node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err"; then ok
else bad "S1 schema.sql applies twice: $(head -3 "$T/mkdb.err")"; fi
q() { node "$T/q.mjs" "$@"; }

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
    node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
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

# ═════ L1: 3 findings in one category from 3 verdicts -> 1 plan-lesson PR ════
reset
trig test-cannot-fail 3
FP=$(fp_of test-cannot-fail "$IDS")
printf '%s\n' "$PLAN" > "$T/answer"
run
check "L1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "L1 one model call" "$(calls)" 1
LINE1=$(head -1 "$T/agentcalls" 2>/dev/null)
check "L1 agent-call: stage lesson-propose, lane, role lesson.propose, fp lesson-propose:<fp>, no tools ($LINE1)" \
  'grep -qE "^lesson-propose fleet [^ ]+ [0-9]+ .*\|lesson-propose\|lesson.propose\|lesson-propose:$FP\|1$" <<<"$LINE1"'
check "L1 the findings enter the prompt as untrusted input" 'grep -q "UNTRUSTED INPUT" "$T/prompt.1" 2>/dev/null && grep -q "finding of verdict" "$T/prompt.1"'
eq "L1 one POST pulls" "$(ghn POST "repos/$R/pulls")" 1
eq "L1 one PUT of plan-contract" "$(ghn PUT "repos/$R/contents/prompts/plan-contract.md")" 1
PC=$(put_content 1 2>/dev/null)
check "L1 the new bullet sits directly above the §10 '- docs/OPERATING' line" \
  'grep -B1 "^- docs/OPERATING" <<<"$PC" | head -1 | grep -qF -- "- A plan names one mutation per acceptance test - and the test it turns red. (lesson-propose: test-cannot-fail)"'
check "L1 nothing else in the file moved" '[ "$(grep -vF "(lesson-propose: test-cannot-fail)" <<<"$PC")" = "$(plan_fixture)" ]'
PRB=$(jq -r '.body' "$T/gh/pulls/7001.json" 2>/dev/null)
for pr in 601 602 603; do
  check "L1 the PR body lists evidence PR $R#$pr with its report URL" 'grep -qF "$R#$pr" <<<"$PRB" && grep -qF "https://github.com/$R/pull/$pr#lr" <<<"$PRB"'
done
check "L1 the PR body names the category id and name" 'grep -qF "test-cannot-fail" <<<"$PRB" && grep -qF "Test cannot fail or uses unreal fixtures" <<<"$PRB"'
check "L1 the PR body says the expected BLOCKs avoided" 'grep -qF "Expected BLOCKs avoided: up to 3 in 14 days" <<<"$PRB"'
check "L1 the PR body carries the marker" 'grep -qF "<!-- lesson-propose: test-cannot-fail fp=$FP -->" <<<"$PRB"'
check "L1 the never-merges line is the last body line above the trailer block" '[ "$(grep -v "^$" <<<"$PRB" | grep -v "^Harness-" | tail -1)" = "Opened by bin/lesson-propose.sh. It never merges." ]'
check "L1 the PR body ends with the BH-4015 trailer block (lane, no ticket)" '[ "$(tail -n 2 <<<"$PRB")" = "$(printf "Harness-Job: lane:lesson-propose\nHarness-Ticket: none")" ]'
check "L1 no em dash in the PR body or the file" '! grep -q "—" <<<"$PRB$PC"'
check "L1 the PR title carries the tag" 'jq -r .title "$T/gh/pulls/7001.json" | grep -qF "[lesson:test-cannot-fail]"'
check "L1 the branch is harness/lesson-<category>-<fp8>" 'grep -qx "harness/lesson-test-cannot-fail-${FP:0:8}" "$T/gh/refs"'
eq "L1 ledger open" "$(led_st test-cannot-fail)" open
eq "L1 ledger number" "$(led_d test-cannot-fail number)" 7001
eq "L1 ledger path" "$(led_d test-cannot-fail path)" prompts/plan-contract.md
eq "L1 ledger fp" "$(led_d test-cannot-fail fp)" "$FP"
check "L1 one summary line" 'grep -qE " triggers=1 clusters=0 categories_added=0 proposed=1 filed=0 held=0 skipped=0 failed=0 calls=1$" "$H/logs/lesson-propose.log"'
check "L1 no network outside the stubs" '[ ! -s "$T/net.log" ]'

# ═════ L2: a second run with the same fixtures: 0 calls, 0 writes ════════════
W=$(writes)
LI=$(ghn GET "repos/$R/issues")
run
eq "L2 still one call" "$(calls)" 1
# The ledger row decides first: a live-open PR skips before the open-list search.
eq "L2 the open lists were not read (the ledger row decided)" "$(ghn GET "repos/$R/issues")" "$LI"
eq "L2 no new GitHub write" "$(writes)" "$W"
eq "L2 the row stays open" "$(led_st test-cannot-fail)" open
check "L2 the open PR was read live" 'grep -q "^GET repos/$R/pulls/7001$" "$T/gh.log"'

# ═════ L1b: a builder-rule answer appends D<max+1> to build-discipline ═══════
reset
trig test-cannot-fail 3
printf '%s\n' "$BUILDER" > "$T/answer"
run
eq "L1b one PUT of build-discipline" "$(ghn PUT "repos/$R/contents/prompts/build-discipline.md")" 1
BD=$(put_content 1 2>/dev/null)
check "L1b the new rule is D67 under a dated heading" \
  'grep -qF "## Added 2026-10-14 (lesson-propose: test-cannot-fail)" <<<"$BD" && grep -qF -- "- **D67 Break each new test once.** Break the code each new test pins" <<<"$BD"'
check "L1b the file is the fixture plus the append" '[ "$(head -n "$(bd_fixture | wc -l)" <<<"$BD")" = "$(bd_fixture)" ]'
eq "L1b ledger path" "$(led_d test-cannot-fail path)" prompts/build-discipline.md

# ═════ L3: an infra category files a bug, no model call ══════════════════════
reset
trig rp-repo-setup-failed 3
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3 no model call" "$(calls)" 0
eq "L3 one POST issues" "$(ghn POST "repos/$R/issues")" 1
eq "L3 no POST pulls" "$(ghn POST "repos/$R/pulls")" 0
check "L3 the issue carries the ai-build label" 'jq -e "[.labels[].name] | index(\"ai-build\")" "$T/gh/issues/7001.json" >/dev/null 2>&1'
check "L3 the issue title is Lesson: ... [lesson:rp-repo-setup-failed]" 'jq -r .title "$T/gh/issues/7001.json" | grep -qE "^Lesson: .+ \[lesson:rp-repo-setup-failed\]$"'
check "L3 the issue body names the evidence and the expected BLOCKs" \
  'jq -r .body "$T/gh/issues/7001.json" | grep -qF "Expected BLOCKs avoided: up to 3 in 14 days" && jq -r .body "$T/gh/issues/7001.json" | grep -qF "$R#601"'
eq "L3 ledger open, kind issue" "$(led_st rp-repo-setup-failed)/$(led_d rp-repo-setup-failed kind)/$(led_d rp-repo-setup-failed target)" open/issue/harness-bug
check "L3 filed=1 in the log" 'grep -qE " proposed=0 filed=1 .* calls=0$" "$H/logs/lesson-propose.log"'

# L3b: a builder-stage category with 2 of 3 findings infra_false files a bug too.
reset
finding test-cannot-fail "" 1; finding test-cannot-fail "" 1; finding test-cannot-fail "" 0
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3b 2 of 3 infra_false: no call" "$(calls)" 0
eq "L3b 2 of 3 infra_false: one issue" "$(ghn POST "repos/$R/issues")" 1
# ... and 1 of 3 is not infra: a model call.
reset
finding test-cannot-fail "" 1; finding test-cannot-fail "" 0; finding test-cannot-fail "" 0
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L3b 1 of 3 infra_false: one call" "$(calls)" 1
eq "L3b 1 of 3 infra_false: no issue" "$(ghn POST "repos/$R/issues")" 0

# ═════ L4: a check answer files an issue with the acceptance tests ═══════════
reset
trig test-cannot-fail 3
printf '%s\n' "$CHECK" > "$T/answer"
run
eq "L4 one call" "$(calls)" 1
eq "L4 one issue" "$(ghn POST "repos/$R/issues")" 1
eq "L4 no PR" "$(ghn POST "repos/$R/pulls")" 0
IB=$(jq -r .body "$T/gh/issues/7001.json" 2>/dev/null)
check "L4 the body has #### Acceptance tests with both tests" \
  'grep -q "^#### Acceptance tests" <<<"$IB" && grep -qF "a suite that stays green under mutation is red" <<<"$IB" && grep -qF "a suite that goes red under mutation passes" <<<"$IB"'
check "L4 the title is Lesson: <title> [lesson:<category>]" '[ "$(jq -r .title "$T/gh/issues/7001.json")" = "Lesson: Lint tests that cannot fail [lesson:test-cannot-fail]" ]'
eq "L4 ledger target check" "$(led_d test-cannot-fail target)" check
# A check with no acceptance test is failed, attempt counted, nothing filed.
reset
trig test-cannot-fail 3
printf '%s\n' '{"target":"check","title":"x","text":"y","acceptance_tests":[],"why":"z"}' > "$T/answer"
run
eq "L4b a check with no test: failed, attempt 1" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/1
eq "L4b nothing filed" "$(writes)" 0

# ═════ L5: a cluster of 3 `other` findings adds a category row ══════════════
reset
finding other "Stale Lockfile"; A=$FID; finding other "stale-lockfile"; B=$FID; finding other "stale lockfile"; C=$FID
printf '%s\n' "$CHECK" > "$T/answer"
run
ROW=$(q "SELECT * FROM block_categories WHERE id='stale-lockfile'" | jq -c '.[0] // {}')
eq "L5 the row is added by lesson-propose" "$(jq -r '.added_by // "none"' <<<"$ROW")" lesson-propose
REASON=$(jq -r '.reason // ""' <<<"$ROW")
check "L5 the reason names 3 verdicts and their ids ($REASON)" '[[ $REASON == *"3 BLOCK verdicts"* && $REASON == *"$A, $B, $C"* ]]'
eq "L5 the name is the most common raw label" "$(jq -r '.name' <<<"$ROW")" "Stale Lockfile"
eq "L5 the 3 findings moved" "$(q "SELECT count(*) n FROM block_findings WHERE category='stale-lockfile'" | jq -r '.[0].n')" 3
eq "L5 the cluster is proposed like a category: one call" "$(calls)" 1
eq "L5 one issue for it" "$(ghn POST "repos/$R/issues")" 1
check "L5 the log counts the cluster and the row" 'grep -qE " triggers=1 clusters=1 categories_added=1 " "$H/logs/lesson-propose.log"'
# Negative: 3 different labels make no row and no call.
reset
finding other "alpha thing"; finding other "beta thing"; finding other "gamma thing"
run
eq "L5n 3 different labels: no new row" "$(q "SELECT count(*) n FROM block_categories WHERE added_by='lesson-propose'" | jq -r '.[0].n')" 0
eq "L5n no call" "$(calls)" 0
check "L5n a tick with no trigger writes no log line" '[ ! -s "$H/logs/lesson-propose.log" ]'
# A retired slug is skipped with a log line, nothing written.
reset
q "UPDATE block_categories SET status='retired' WHERE id='iron-law'" >/dev/null
finding other "Iron Law"; finding other "iron law"; finding other "iron-law"
run
eq "L5r a retired slug: no call" "$(calls)" 0
check "L5r a retired slug: one log line" 'grep -q "cluster iron-law: the category is retired; skipped" "$H/logs/lesson-propose.log"'
eq "L5r the findings stay other" "$(q "SELECT count(*) n FROM block_findings WHERE category='other'" | jq -r '.[0].n')" 3

# ═════ L6/L7: the merged cooldown ════════════════════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail merged "$(jq -nc --arg at "$(iso_ago 13)" '{fp:"0000000000000000", at:$at, target:"plan-lesson", kind:"pr", number:42}')"
run
eq "L6 merged 13 days ago: no call" "$(calls)" 0
eq "L6 no write" "$(writes)" 0
reset
trig test-cannot-fail 4
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail merged "$(jq -nc --arg at "$(iso_ago 15)" '{fp:"0000000000000000", at:$at, target:"plan-lesson", kind:"pr", number:42}')"
run
eq "L7 merged 15 days ago with a 4th verdict: one call" "$(calls)" 1
eq "L7 a new PR" "$(ghn POST "repos/$R/pulls")" 1

# ═════ L8: a blank answer is empty and terminal for that evidence ════════════
reset
trig test-cannot-fail 3
printf '\n' > "$T/answer"
run
eq "L8 one call" "$(calls)" 1
eq "L8 empty" "$(led_st test-cannot-fail)" empty
run
eq "L8 rerun: no new call" "$(calls)" 1
printf '%s\n' '{"target":"none","title":"","text":"","acceptance_tests":[],"why":"nothing to learn"}' > "$T/answer"
finding test-cannot-fail
run
eq "L8 a new verdict (new fp): one more call" "$(calls)" 2
eq "L8 target none is empty too" "$(led_st test-cannot-fail)" empty
eq "L8 nothing filed" "$(writes)" 0
# L8b: the window slides. A verdict that ages out changes the fp, but it is
# not new evidence: the empty row stays terminal. A closed (rejected) lesson too.
reset
trig test-cannot-fail 4
OLD=${IDS%%,*}
printf '\n' > "$T/answer"
run
eq "L8b one call" "$(calls)" 1
q "UPDATE block_findings SET verdict_at=? WHERE verdict_id=?" "$(iso_ago 20)" "$OLD" >/dev/null
q "UPDATE verdicts SET created_at=? WHERE id=?" "$(iso_ago 20)" "$OLD" >/dev/null
run
eq "L8b a verdict aged out (new fp, no new id): no new call" "$(calls)" 1
eq "L8b still empty" "$(led_st test-cannot-fail)" empty
finding test-cannot-fail
run
eq "L8b a new verdict id: one more call" "$(calls)" 2
reset
trig test-cannot-fail 4
OLD=${IDS%%,*}
put_led test-cannot-fail closed "$(jq -nc --arg fp "$(fp_of test-cannot-fail "$IDS")" --argjson s "[${IDS}]" '{fp:$fp, kind:"pr", number:7001, path:"prompts/plan-contract.md", seen:$s, attempts:1}')"
q "UPDATE block_findings SET verdict_at=? WHERE verdict_id=?" "$(iso_ago 20)" "$OLD" >/dev/null
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L8b a closed lesson, a verdict aged out: no call" "$(calls)" 0
eq "L8b a closed lesson, a verdict aged out: no PR" "$(ghn POST "repos/$R/pulls")" 0

# ═════ L9: the marker on an open issue heals a lost ledger row ══════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:4242, state:"open", title:"Lesson: something [lesson:test-cannot-fail]", body:"x\n<!-- lesson-propose: test-cannot-fail fp=1111111111111111 -->\n", html_url:"https://github.com/example-org/cromford/issues/4242"}' > "$T/gh/issues/4242.json"
run
eq "L9 no call" "$(calls)" 0
eq "L9 no write" "$(writes)" 0
eq "L9 the row is back to open with that issue" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail number)" open/4242
# The marker must name THIS category: another category's marker is no hit.
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:4243, state:"open", title:"x", body:"<!-- lesson-propose: test-cannot-fail-two fp=1 -->", html_url:"https://github.com/example-org/cromford/issues/4243"}' > "$T/gh/issues/4243.json"
run
eq "L9b another category's marker: one call" "$(calls)" 1

# ═════ L10: a ledger outage stops the whole tick ═════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
: > "$T/fail.GET._api_ledger"
run
eq "L10 no call" "$(calls)" 0
eq "L10 no GitHub write" "$(writes)" 0
eq "L10 no claim" "$(claims)" 0
eq "L10 no ledger row" "$(led_st test-cannot-fail)" none
check "L10 one log line names the outage" 'grep -q "ledger" "$H/logs/lesson-propose.log"'

# ═════ L11: the open-issue list unreadable: no claim, no call ════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 500 > "$T/gh/issues.list.status"
run
eq "L11 no claim" "$(claims)" 0
eq "L11 no call" "$(calls)" 0
eq "L11 no write" "$(writes)" 0

# ═════ L12: a fresh drafting row (another tick holds it): no call ════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
put_led test-cannot-fail drafting '{}'
run
eq "L12 no call" "$(calls)" 0
eq "L12 one claim, refused" "$(claims)" 1
eq "L12 the row is still drafting" "$(led_st test-cannot-fail)" drafting

# ═════ L13/L14: refused calls are free, billed failures count ════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 75 > "$T/ac.rc"
run
eq "L13 rc 75: failed, attempts 0" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/0
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 1 > "$T/ac.rc"
run; run
scratch_rm "$T/ac.rc" || exit 1
printf 'I think the tests are weak.\n' > "$T/answer"
run
eq "L14 rc 1 twice and one unparseable answer: failed, attempts 3" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail attempts)" failed/3
eq "L14 three calls" "$(calls)" 3
run
eq "L14 the fourth run: no call" "$(calls)" 3

# ═════ L15: a failed delivery keeps the draft; the next tick delivers it free ═
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
echo 500 > "$T/gh/pulls.post.status"
run
eq "L15 one call" "$(calls)" 1
eq "L15 undelivered" "$(led_st test-cannot-fail)" undelivered
check "L15 the draft is in the ledger" 'led test-cannot-fail | jq -r .detail | jq -r .draft.text | grep -qF "A plan names one mutation per acceptance test"'
check "L15 the log says proposed=0" 'grep -qE " proposed=0 " "$H/logs/lesson-propose.log"'
check "L15 one log line names the step and the HTTP status" 'grep -qE "test-cannot-fail: delivery failed at pulls \(http 500" "$H/logs/lesson-propose.log"'
rm -f "$T/gh/pulls.post.status"
run
eq "L15 next run: no new call" "$(calls)" 1
eq "L15 next run: one PR" "$(ls "$T/gh/pulls" | wc -l | tr -d ' ')" 1
check "L15 the PR carries the same text" 'cat "$T/gh/pulls/"*.json | jq -r .body | grep -qF "A plan names one mutation per acceptance test - and the test it turns red."'
eq "L15 open" "$(led_st test-cannot-fail)" open
check "L15 the second log line says proposed=1 calls=0" 'loglast | grep -qE " proposed=1 .* calls=0$"'

# ═════ L16: no §10 anchor and no ## 11. heading: failed, no PUT ═══════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
printf '# Plan contract\n\n## 9. Something\n\n- one\n' > "$T/gh/repo/prompts/plan-contract.md"
run
eq "L16 failed" "$(led_st test-cannot-fail)" failed
eq "L16 no PUT" "$(grep -c '^PUT ' "$T/gh.log" 2>/dev/null || true)" 0
eq "L16 no PR" "$(ghn POST "repos/$R/pulls")" 0
# With no `- docs/OPERATING` bullet but a ## 11. heading, the bullet goes above ## 11.
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
printf '# Plan contract\n\n## 10. Lessons\n\n- one\n\n## 11. Next\n' > "$T/gh/repo/prompts/plan-contract.md"
run
check "L16b the bullet sits above ## 11." 'put_content 1 | grep -A1 -F "(lesson-propose: test-cannot-fail)" | tail -1 | grep -q "^$" && put_content 1 | grep -A2 -F "(lesson-propose: test-cannot-fail)" | tail -1 | grep -q "^## 11\."'

# ═════ L17: 5 triggers, MAX_PER_TICK=3: 3 deliveries ════════════════════════
reset
for c in test-cannot-fail test-hand-copies-lib evidence-not-bound-to-head missing-live-probe closes-overclaim; do trig "$c" 3; done
printf '%s\n' "$CHECK" > "$T/answer"
run LESSON_PROPOSE_MAX_PER_TICK=3
eq "L17 three calls" "$(calls)" 3
eq "L17 three issues" "$(ghn POST "repos/$R/issues")" 3
eq "L17 two rows untouched" "$(q "SELECT count(*) n FROM ledgers WHERE kind='lesson_proposal'" | jq -r '.[0].n')" 3

# ═════ L18: a second lesson on the same prompt file is held ══════════════════
reset
trig logic-alert-blast-radius 4
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "L18 two calls" "$(calls)" 2
eq "L18 one PR" "$(ghn POST "repos/$R/pulls")" 1
eq "L18 the first is open" "$(led_st logic-alert-blast-radius)" open
eq "L18 the second is held" "$(led_st test-cannot-fail)" held
check "L18 the log counts it" 'grep -qE " proposed=1 filed=0 held=1 " "$H/logs/lesson-propose.log"'
jq -c '.state = "closed" | .merged_at = "2026-10-14T10:00:00Z"' "$T/gh/pulls/7001.json" > "$T/gh/m.json" && mv "$T/gh/m.json" "$T/gh/pulls/7001.json"
run
eq "L18 after the first merged: no new call" "$(calls)" 2
eq "L18 the first reads merged" "$(led_st logic-alert-blast-radius)" merged
eq "L18 the held one is delivered" "$(led_st test-cannot-fail)" open
eq "L18 two PRs in all" "$(ghn POST "repos/$R/pulls")" 2
# L18b: the open lesson's category left the trigger set (its verdicts aged
# out), and its PR merged. No lp_one reads that row again, so the hold check
# must read it live: the new lesson is delivered, not held for good.
reset
printf '%s\n' "$PLAN" > "$T/answer"
jq -nc '{number:7001, state:"closed", merged_at:"2026-10-13T10:00:00Z", title:"Lesson: x [lesson:logic-alert-blast-radius]", body:"", html_url:"https://github.com/example-org/cromford/pull/7001"}' > "$T/gh/pulls/7001.json"
echo 7001 > "$T/gh/counter"
put_led logic-alert-blast-radius open '{"fp":"0000000000000000","kind":"pr","number":7001,"path":"prompts/plan-contract.md","seen":[1,2,3]}'
trig test-cannot-fail 3
run
eq "L18b one call" "$(calls)" 1
eq "L18b the stale open row reads merged" "$(led_st logic-alert-blast-radius)" merged
eq "L18b the new lesson is open, not held" "$(led_st test-cannot-fail)" open
eq "L18b one PR" "$(ghn POST "repos/$R/pulls")" 1
check "L18b the log says held=0" 'loglast | grep -qE " proposed=1 filed=0 held=0 "'
# L18d: a backslash in the drafted text reaches the prompt file unchanged.
reset
printf '%s\n' '{"target":"plan-lesson","title":"Quote the regex","text":"Match ids with ^BH-\\d+$ and a tab is \\t.","acceptance_tests":[],"why":"w"}' > "$T/answer"
trig test-cannot-fail 3
run
check "L18d the bullet keeps its backslashes" 'put_content 1 | grep -qF -- "- Match ids with ^BH-\d+\$ and a tab is \t. (lesson-propose: test-cannot-fail)"'
# L18c: held stored drafts cost no call, so they never use a slot: with 3
# held behind a PR that is really open, a 4th category is still drafted.
reset
printf '%s\n' "$CHECK" > "$T/answer"
jq -nc '{number:7001, state:"open", merged_at:null, title:"Lesson: x [lesson:logic-alert-blast-radius]", body:"", html_url:"https://github.com/example-org/cromford/pull/7001"}' > "$T/gh/pulls/7001.json"
echo 7001 > "$T/gh/counter"
put_led logic-alert-blast-radius open '{"fp":"0000000000000000","kind":"pr","number":7001,"path":"prompts/plan-contract.md","seen":[1,2,3]}'
for c in test-hand-copies-lib evidence-not-bound-to-head missing-live-probe; do
  trig "$c" 4
  put_led "$c" held "$(jq -nc --arg fp "$(fp_of "$c" "$IDS")" --argjson d "$PLAN" --argjson s "[${IDS}]" '{fp:$fp, target:"plan-lesson", kind:"pr", path:"prompts/plan-contract.md", attempts:1, seen:$s, draft:$d}')"
done
trig test-cannot-fail 3
run LESSON_PROPOSE_MAX_PER_TICK=3
eq "L18c the three stay held" "$(led_st test-hand-copies-lib)/$(led_st evidence-not-bound-to-head)/$(led_st missing-live-probe)" held/held/held
eq "L18c the 4th is drafted: one call" "$(calls)" 1
eq "L18c the 4th is filed" "$(ghn POST "repos/$R/issues")" 1
eq "L18c no PR" "$(ghn POST "repos/$R/pulls")" 0

# ═════ L19: the ledger detail stays under the 4000 chars the worker keeps ═════
# PUT /api/ledger cuts a detail at 4000 chars, and a cut detail is no JSON.
# bulk <category> <first-id> <count> <days>: count BLOCK verdicts, one finding
# each, in two statements (one node call each, not 2*count).
bulk() {
  local sha; sha=$(printf 'b%.0s' $(seq 40))
  q "WITH RECURSIVE c(i) AS (SELECT CAST(?1 AS INTEGER) UNION ALL SELECT i + 1 FROM c WHERE i < ?1 + ?2 - 1)
     INSERT INTO verdicts (id, repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at)
     SELECT i, '$R', i, '$sha', 'BLOCK', 'lead', 'mac-lead', 'https://github.com/$R/pull/' || i || '#lr', 'n', ?3 FROM c" \
    "$2" "$3" "$(iso_ago "$4")" >/dev/null
  q "WITH RECURSIVE c(i) AS (SELECT CAST(?1 AS INTEGER) UNION ALL SELECT i + 1 FROM c WHERE i < ?1 + ?2 - 1)
     INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, raw_category, confidence, cause, files, infra_false, text, model, verdict_at, created_at)
     SELECT i, 1, '$R', i, 'BH-9001', '$sha', 'lead', ?4, '', 0.8, 'cause of ' || i, '[\"bin/x.sh\"]', 0, '- [BLOCK] bin/x.sh: finding of verdict ' || i, 'm', ?3, ?3 FROM c" \
    "$2" "$3" "$(iso_ago "$4")" "$1" >/dev/null
}
age() { q "UPDATE block_findings SET verdict_at=?3 WHERE verdict_id BETWEEN ?1 AND ?2" "$1" "$2" "$(iso_ago 20)" >/dev/null; }
seen_n() { led "$1" | jq -r '.detail | fromjson | .seen | length'; }
# L19a: 400 verdict ids over two ticks. `seen` keeps the window, not every id.
reset
bulk test-cannot-fail 200001 200 5
printf '\n' > "$T/answer"
run
eq "L19a tick 1: one call" "$(calls)" 1
eq "L19a tick 1: seen holds the 200 window ids" "$(seen_n test-cannot-fail)" 200
age 200001 200200
bulk test-cannot-fail 200201 200 2
run
eq "L19a tick 2: 200 new ids, one more call" "$(calls)" 2
eq "L19a tick 2: seen holds the 200 window ids, not 400" "$(seen_n test-cannot-fail)" 200
check "L19a tick 2: seen is the new window" '[ "$(led test-cannot-fail | jq -r ".detail | fromjson | .seen | min")" = 200201 ]'
run
eq "L19a tick 3: same evidence, no call" "$(calls)" 2
# L19b: a window too large for the ledger. 700 six-digit ids are about 4900
# chars of `seen`: the row stores seen_max, parses, and still dedups.
reset
bulk test-cannot-fail 300001 700 5
printf '\n' > "$T/answer"
run
eq "L19b one call" "$(calls)" 1
eq "L19b empty" "$(led_st test-cannot-fail)" empty
check "L19b the detail is JSON, at most 4000 chars" 'led test-cannot-fail | jq -e ".detail | (fromjson | type == \"object\") and length <= 4000" >/dev/null'
eq "L19b seen_max is the largest id" "$(led_d test-cannot-fail seen_max)" 300700
eq "L19b no seen list" "$(led_d test-cannot-fail seen)" null
check "L19b one log line names seen_max" '[ "$(grep -c "seen (700 ids) is stored as seen_max" "$H/logs/lesson-propose.log")" = 1 ]'
age 300001 300010
run
eq "L19b 10 ids aged out (new fp, no new id): no call" "$(calls)" 1
eq "L19b still empty" "$(led_st test-cannot-fail)" empty
finding test-cannot-fail
q "UPDATE verdicts SET id=400001 WHERE id=?" "$FID" >/dev/null
q "UPDATE block_findings SET verdict_id=400001 WHERE verdict_id=?" "$FID" >/dev/null
run
eq "L19b an id above seen_max: one more call" "$(calls)" 2
# L19c: a full-size check draft over a large window is stored whole: the
# undelivered and open rows parse, so the next tick reads the lesson live.
reset
bulk test-cannot-fail 300001 700 5
jq -nc '{target:"check", title:("t" * 200), text:("x" * 1500), acceptance_tests:[range(6) | ("a\"" * 150)], why:("w" * 400)}' > "$T/answer"
run
eq "L19c one issue" "$(ghn POST "repos/$R/issues")" 1
eq "L19c open" "$(led_st test-cannot-fail)" open
check "L19c the open detail is JSON, at most 4000 chars" 'led test-cannot-fail | jq -e ".detail | (fromjson | .number | type == \"number\") and length <= 4000" >/dev/null'
run
eq "L19c rerun: the open issue is read live, no call" "$(calls)" 1
eq "L19c rerun: no new issue" "$(ghn POST "repos/$R/issues")" 1
# L19d: an open row whose detail was cut (no JSON) is not stuck: one log
# line, and the marker search finds the open issue and heals the row.
reset
trig test-cannot-fail 3
jq -nc '{number:7001, state:"open", title:"Lesson: x [lesson:test-cannot-fail]", body:"", html_url:"https://github.com/example-org/cromford/issues/7001"}' > "$T/gh/issues/7001.json"
put_led test-cannot-fail open '{"fp":"0000000000000000","kind":"issue","number":70'
printf '%s\n' "$PLAN" > "$T/answer"
run
check "L19d the cut detail is logged" 'grep -q "test-cannot-fail: the open ledger detail is no JSON" "$H/logs/lesson-propose.log"'
eq "L19d no call" "$(calls)" 0
eq "L19d the row is healed to #7001" "$(led_st test-cannot-fail)/$(led_d test-cannot-fail number)" open/7001
eq "L19d nothing filed" "$(writes)" 0

# ═════ K: knobs ══════════════════════════════════════════════════════════════
reset
trig test-cannot-fail 3
printf '%s\n' "$PLAN" > "$T/answer"
run LESSON_PROPOSE_MAX_PER_TICK=x
check "K1 a junk MAX_PER_TICK: one warn line" '[ "$(grep -c "warn: LESSON_PROPOSE_MAX_PER_TICK=x is not an integer in 1..20; using the default 3" "$H/logs/lesson-propose.log")" = 1 ]'
eq "K1 ... and the default still runs the tick" "$(calls)" 1
reset
trig test-cannot-fail 3
run LESSON_PROPOSE_ENABLED=0
eq "K2 ENABLED=0: no lane request" "$(grep -vc '^GET /api/settings' "$T/reqlog")" 0
eq "K2 ENABLED=0: no GitHub call" "$(n "$T/gh.log")" 0

# ═════ T: the triggers route unreadable, or no model route ═══════════════════
reset
trig test-cannot-fail 3
: > "$T/fail.GET._api_lesson-propose_triggers"
run
eq "T1 triggers unreadable: no call" "$(calls)" 0
eq "T1 no claim" "$(claims)" 0
check "T1 one log line" '[ "$(n "$H/logs/lesson-propose.log")" = 1 ] && grep -q "could not read" "$H/logs/lesson-propose.log"'
reset
trig test-cannot-fail 3
q "DELETE FROM model_routes WHERE role='lesson.propose'" >/dev/null
printf '%s\n' "$PLAN" > "$T/answer"
run
eq "T2 no lesson.propose route: no call" "$(calls)" 0
eq "T2 no claim" "$(claims)" 0
check "T2 the log says so" 'grep -q "no lesson.propose model route" "$H/logs/lesson-propose.log"'

# ═════ the worker half, as its own node suite ════════════════════════════════
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/lesson-propose.bh-5807.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/lesson-propose.bh-5807.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30; fi

echo "lesson-propose: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
