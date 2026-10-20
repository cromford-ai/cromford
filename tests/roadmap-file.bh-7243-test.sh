#!/bin/bash
# tests/roadmap-file.bh-7243-test.sh — BH-7267 (BH-7243.4): the filing lane.
# Drives the SHIPPED bin/roadmap-file.sh against the REAL worker routes
# (worker/jobs/src/routes/roadmap-wave-file.js) over a node:sqlite file built
# from the REAL jobs schema (composed from schema.d/).
#
# WHAT IS STUBBED. bin/lane-alert.sh (it records each call in $FXT/alerts) and
# `gh` on PATH: a small fake GitHub that answers `api -i -X <METHOD> <path>`
# from the files under $FXT/gh (issues/<n>.json; a POST adds one), records every
# call in $FXT/gh.log and every --input body in $FXT/gh/in.<n>.json. The
# search/issues arm answers every issue file whose body holds the q phrase.
# $FXT/gh/issues.post.status holds one status per line for the next creates.
# $FXT/crash makes the fake gh kill the lane right after it answers a create.
# Nothing here reaches GitHub or the real worker. The worker's clock is pinned
# to $NOW (FXT_NOW, D60).
#
# Sections: F0-F10 (the plan's acceptance cases), F4b (rate limit ends the tick).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/roadmap-file.bh-7243-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "roadmap-file: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/roadmap-file.sh"
ROUTE="$DIR/worker/jobs/src/routes/roadmap-wave-file.js"
RTABLE="$DIR/worker/jobs/test/route-table.d/bh-7243-roadmap-wave-file.txt"
CRON="$DIR/cron/lanes/743-roadmap-file.cron"
REG="$DIR/catalog/lanes.d/roadmap-file.json"

# ═════ F0: the files, no model literal, the cron line, the registry ══════════
for f in "$LANE" "$ROUTE" "$RTABLE" "$CRON" "$REG"; do
  [ -f "$f" ] && ok || bad "F0 missing $f"
done
check "F0 no hardcoded model string in the lane or the routes" \
  '[ -f "$LANE" ] && [ -f "$ROUTE" ] && ! grep -nE "claude-(opus|sonnet|haiku|fable)" "$LANE" "$ROUTE"'
check "F0 cron: every 5 minutes, behind the hub lease" \
  'grep -qE "^\*/5 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/roadmap-file.sh " "$CRON" 2>/dev/null'
check "F0 registry: hub lane, flag lane-off-roadmap-file, knob ROADMAP_FILE_MAX_PER_TICK 3 (1..20)" \
  '[ "$(jq -r "[.scope, (.boxes|join(\",\")), .switch.name, .script, (.knobs[] | select(.env == \"ROADMAP_FILE_MAX_PER_TICK\") | \"\(.default)/\(.min)/\(.max)\")] | @tsv" "$REG" 2>/dev/null)" = "$(printf "hub\thub\tlane-off-roadmap-file\tbin/roadmap-file.sh\t3/1/20")" ]'
check "F0 the lane declares no-graphql" 'grep -q "^# gh-rest: no-graphql" "$LANE" 2>/dev/null'
if [ ! -f "$LANE" ] || [ ! -f "$ROUTE" ]; then
  echo "roadmap-file: $PASS passed, $FAIL failed"; exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "roadmap-file: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "roadmap-file: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-19T12:00:00Z
LATER=2026-10-19T12:31:00Z
NOW_S=$(date -u -d "$NOW" +%s)
R=example-org/cromford

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { routes as rw } from '$ROUTE';
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
const hit = matchRoute([...rw], method, path);
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
else { const r = st.run(...binds); console.log(JSON.stringify([{ changes: Number(r.changes) }])); }
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
else bad "schema.sql applies twice: $(head -3 "$T/mkdb.err")"; fi
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/flags" "$H/bin" "$T/fakebin"
# The lane and the jobs client it sources by $SELF (the closure follows bin/lib only).
for L in bin/roadmap-file.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
# This suite drives `gh` direct; the shim path is pinned in the sync suite (S11).
rm -f "$H/bin/gh-rest-shim"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts"
exit 0
SH
chmod +x "$H/bin/lane-alert.sh"
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
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
G="$FXT/gh"
[ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ "${3:-}" = -X ] || { printf 'gh %s\n' "$*" >> "$FXT/net.log"; exit 7; }
m="$4"; p="$5"; shift 5
input=""; qs=""
while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="$2"; shift 2 ;;
    -f|-F) case "$2" in q=*) qs="${2#q=}" ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
[ -n "$qs" ] && printf '%s\n' "$qs" >> "$FXT/gh.q.log"
n_in=0
if [ -n "$input" ]; then n_in=$(( $(ls "$G"/in.*.json 2>/dev/null | wc -l) + 1 )); cp "$input" "$G/in.$n_in.json"; fi
st() { local s; s=$(head -1 "$G/$1.status" 2>/dev/null); if [ -n "$s" ]; then sed -i 1d "$G/$1.status"; echo "$s"; else echo "$2"; fi; }
err() { case "$1" in 403|429) restpr --raw "$1" '{"message":"API rate limit exceeded"}' ;; *) restpr --raw "$1" '{"message":"fixture"}' ;; esac; }
R=example-org/cromford
next() { local c; c=$(cat "$G/counter" 2>/dev/null || echo 8000); c=$((c + 1)); echo "$c" > "$G/counter"; echo "$c"; }
case "$m $p" in
  "GET search/issues")
    s=$(st search.get 200); [ "$s" = 200 ] || { err "$s"; exit 0; }
    phrase=$(printf '%s' "$qs" | sed -n 's/.*in:body "\(.*\)"$/\1/p')
    [ -n "$phrase" ] || { restpr --raw 422 '{"message":"fixture: no phrase"}'; exit 0; }
    items=$(for f in "$G"/issues/*.json; do [ -f "$f" ] || continue; jq -c --arg ph "$phrase" 'select((.body // "") | contains($ph))' "$f"; done | jq -sc '{total_count: length, incomplete_results: false, items: .}')
    restpr --raw 200 "$items"; exit 0 ;;
  "POST repos/$R/issues")
    s=$(st issues.post 201); [ "$s" = 201 ] || { err "$s"; exit 0; }
    n=$(next); jq -c --argjson n "$n" '{number:$n, state:"open", state_reason:null, title, body, labels:[.labels[]? | {name:.}], html_url:("https://github.com/example-org/cromford/issues/" + ($n|tostring))}' "$input" > "$G/issues/$n.json"
    restpr --raw 201 "$(cat "$G/issues/$n.json")"
    if [ -f "$FXT/crash" ]; then rm -f "$FXT/crash"; kill -9 "$PPID"; fi
    exit 0 ;;
esac
printf 'gh %s %s\n' "$m" "$p" >> "$FXT/net.log"; exit 7
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh7267 JOBS_RETRIES=0 GH_ETAG=0
unset ROADMAP_FILE_MAX_PER_TICK 2>/dev/null || true

DRAFT='{"slices":[
 {"title":"Slice one","body":"First slice body.","acceptance_tests":["A1 one works"],"spec_refs":["docs/spec.md#one"],"files":["bin/one.sh"],"seam_files":[],"blocked_by":[]},
 {"title":"Slice two","body":"Second slice body.","acceptance_tests":["A2 two works"],"spec_refs":[],"files":["bin/two.sh"],"seam_files":["bin/lib/seam.sh"],"blocked_by":[]},
 {"title":"Slice three","body":"Third slice body.","acceptance_tests":["A3 three works","A4 three again"],"spec_refs":[],"files":["bin/three.sh"],"seam_files":[],"blocked_by":[1]}
],"notes":""}'

reset() {
  local p
  for p in reqlog net.log gh.log gh.q.log out rc alerts gh crash; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/fail.*
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/flags" || exit 1
  mkdir -p "$H/flags"
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
  mkdir -p "$T/gh/issues"
  q "INSERT OR REPLACE INTO projects (project, repo, board_api_prefix, cron_offset, created_at, updated_at) VALUES ('cromford', ?, NULL, 0, ?, ?)" "$R" "$NOW" "$NOW" >/dev/null
}
# draft <id> [status] [draft-json]: one wave in the contract shape the shaping lane writes.
draft() {
  q "INSERT INTO roadmap_waves (id, project, status, input_fp, idea_ids, draft, created_at, updated_at) VALUES (?, 'cromford', ?, ?, '[\"i1\",\"i2\"]', ?, ?, ?)" \
    "$1" "${2:-draft}" "fp-$1" "${3:-$DRAFT}" "$NOW" "$NOW" >/dev/null
}
# wcall <method> <path> [json]: one REAL route call; prints the body, a newline and the status.
wcall() {
  local bf=""
  if [ -n "${3:-}" ]; then bf="$T/wbody.json"; printf '%s' "$3" > "$bf"; fi
  node "$T/wdrv.mjs" "$1" "$2" "$bf"
}
approve() {
  local o; o=$(wcall POST /api/roadmap/waves/approve "{\"id\":\"$1\",\"project\":\"cromford\",\"expected_status\":\"draft\",\"actor\":\"operator@example.com\"}")
  [ "${o##*$'\n'}" = 200 ] || { echo "approve $1 answered: $o"; return 1; }
}
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 "$@" bash "$H/bin/roadmap-file.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt()    { local c; c=$(grep -cE -e "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
creates() { cnt "^POST repos/$R/issues\$" "$T/gh.log"; }
ghn()    { cnt . "$T/gh.log"; }
wv()     { q "SELECT $2 AS v FROM roadmap_waves WHERE id = ?" "$1" | jq -r '.[0].v // "null" | tostring'; }
links()  { q "SELECT COUNT(*) AS n FROM roadmap_links WHERE wave_id = ?" "$1" | jq -r '.[0].n'; }
issue_body() { jq -r '.body' "$T/gh/issues/$1.json"; }
loglast() { tail -1 "$H/logs/roadmap-file.log" 2>/dev/null; }

# ═════ F1: one run files 3 issues in order, 6 links, wave filed ══════════════
reset
draft w1
approve w1 || bad "F1 the approve route did not answer 200"
eq "F1 the approve route set approved" "$(wv w1 status)" approved
run
eq "F1 rc 0 ($(head -c 300 "$T/out"))" "$(cat "$T/rc")" 0
eq "F1 three creates" "$(creates)" 3
eq "F1 creates in slice order" "$(for i in 1 2 3; do jq -r '.title' "$T/gh/in.$i.json" 2>/dev/null; done | paste -sd'|')" "Slice one|Slice two|Slice three"
eq "F1 every create carries the ai-build label only" "$(for i in 1 2 3; do jq -c '.labels' "$T/gh/in.$i.json" 2>/dev/null; done | sort -u)" '["ai-build"]'
eq "F1 one search per slice" "$(cnt '^GET search/issues$' "$T/gh.log")" 3
eq "F1 six link rows (3 slices x 2 ideas)" "$(links w1)" 6
eq "F1 the link rows name the three issues" "$(q "SELECT DISTINCT issue FROM roadmap_links WHERE wave_id='w1' ORDER BY issue" | jq -r 'map(.issue) | join(",")')" "8001,8002,8003"
eq "F1 the link rows carry both ideas for slice 1" "$(q "SELECT idea_id FROM roadmap_links WHERE wave_id='w1' AND issue=8001 ORDER BY idea_id" | jq -r 'map(.idea_id) | join(",")')" "i1,i2"
eq "F1 wave filed" "$(wv w1 status)" filed
check "F1 one summary line ($(loglast))" '[ "$(cnt . "$H/logs/roadmap-file.log")" = 1 ] && loglast | grep -qE " waves=1 filed=1 created=3 reused=0 failed=0$"'
eq "F1 no alert" "$(cnt . "$T/alerts")" 0
eq "F1 nothing else reached the network" "$(cnt . "$T/net.log")" 0

# ═════ F2: the body of slice 3 ═══════════════════════════════════════════════
B3=$(issue_body 8003 2>/dev/null)
check "F2 slice 3 is Blocked-by slice 1's issue" 'grep -qxF "Blocked-by: #8001" <<<"$B3"'
eq "F2 slice 3 has one Blocked-by line" "$(grep -c '^Blocked-by:' <<<"$B3")" 1
check "F2 the wave line" 'grep -qxF "Part of roadmap wave w1" <<<"$B3"'
eq "F2 the marker is the last line" "$(tail -1 <<<"$B3")" "<!-- harness-roadmap-slice: w1/3 -->"
check "F2 the slice body, headings and lists" 'grep -qxF "Third slice body." <<<"$B3" && grep -qxF "## Acceptance tests" <<<"$B3" && grep -qxF -- "- A4 three again" <<<"$B3" && grep -qxF "## Spec refs" <<<"$B3" && grep -qxF "## Files" <<<"$B3" && grep -qxF -- "- bin/three.sh" <<<"$B3" && grep -qxF "## Seam files" <<<"$B3"'
eq "F2 slice 1 has no Blocked-by line" "$(issue_body 8001 | grep -c '^Blocked-by:')" 0

# ═════ F3: a crash after slice 1's create; the re-run reuses it ══════════════
reset
draft w1; approve w1 || bad "F3 approve"
touch "$T/crash"
run
check "F3 the lane was killed (rc $(cat "$T/rc"))" '[ "$(cat "$T/rc")" != 0 ]'
eq "F3 slice 1 was created once" "$(creates)" 1
eq "F3 wave left filing" "$(wv w1 status)" filing
eq "F3 slice 1 not linked" "$(links w1)" 0
# Same clock: the filing claim is fresh, so nothing is claimable.
run
eq "F3 a fresh filing claim is not reclaimed" "$(creates)" 1
eq "F3 ... still filing" "$(wv w1 status)" filing
run FXT_NOW="$LATER"
eq "F3 re-run rc 0" "$(cat "$T/rc")" 0
eq "F3 re-run created only slices 2 and 3 (3 creates in all)" "$(creates)" 3
eq "F3 the issue store holds 3 issues" "$(ls "$T/gh/issues" | grep -c '\.json$')" 3
eq "F3 creates were slices 1, 2, 3" "$(for i in 1 2 3; do jq -r '.title' "$T/gh/in.$i.json" 2>/dev/null; done | paste -sd'|')" "Slice one|Slice two|Slice three"
eq "F3 slice 1 linked to the reused issue" "$(q "SELECT COUNT(*) AS n FROM roadmap_links WHERE wave_id='w1' AND issue=8001" | jq -r '.[0].n')" 2
eq "F3 six links" "$(links w1)" 6
eq "F3 wave filed" "$(wv w1 status)" filed
check "F3 slice 3 still Blocked-by the reused slice 1" 'issue_body 8003 | grep -qxF "Blocked-by: #8001"'
check "F3 summary counts the reuse ($(loglast))" 'loglast | grep -qE " waves=1 filed=1 created=2 reused=1 failed=0$"'

# ═════ F4: the 2nd create fails -> approved + error, slice 1 linked only ════
reset
draft w1; approve w1 || bad "F4 approve"
printf '201\n422\n' > "$T/gh/issues.post.status"
run
eq "F4 rc 0" "$(cat "$T/rc")" 0
eq "F4 two creates tried" "$(creates)" 2
eq "F4 no search for slice 3" "$(cnt '^GET search/issues$' "$T/gh.log")" 2
eq "F4 wave back to approved" "$(wv w1 status)" approved
eq "F4 the error names the slice and the status" "$(wv w1 error)" "slice 2: http 422"
eq "F4 two link rows, both slice 1" "$(q "SELECT COUNT(*) AS n, COUNT(DISTINCT issue) AS d, MIN(issue) AS i FROM roadmap_links WHERE wave_id='w1'" | jq -r '.[0] | "\(.n)/\(.d)/\(.i)"')" "2/1/8001"
eq "F4 one warn alert" "$(cnt '--id roadmap-file:w1 --severity warn roadmap-file ' "$T/alerts")" 1
check "F4 summary ($(loglast))" 'loglast | grep -qE " waves=1 filed=0 created=1 reused=0 failed=1$"'

# ═════ F4b: a rate limit on the create ends the tick ═════════════════════════
reset
draft w1; approve w1 || bad "F4b approve w1"
draft w2; approve w2 || bad "F4b approve w2"
printf '429\n' > "$T/gh/issues.post.status"
run
eq "F4b one claim only" "$(cnt '^POST /api/roadmap/waves/file-claim ' "$T/reqlog")" 1
eq "F4b one create tried" "$(creates)" 1
eq "F4b the first wave carries the error" "$(q "SELECT error FROM roadmap_waves WHERE error IS NOT NULL" | jq -r '.[0].error')" "slice 1: http 429"
eq "F4b the other wave was never claimed" "$(q "SELECT COUNT(*) AS n FROM roadmap_waves WHERE status='approved' AND error IS NULL AND claimed_by IS NULL" | jq -r '.[0].n')" 1

# ═════ F5: two failing waves -> exactly 2 warn alerts, no flag file ═════════
reset
draft w1; approve w1 || bad "F5 approve w1"
draft w2; approve w2 || bad "F5 approve w2"
printf '500\n500\n' > "$T/gh/issues.post.status"
run
eq "F5 rc 0" "$(cat "$T/rc")" 0
eq "F5 exactly 2 alert calls" "$(cnt . "$T/alerts")" 2
eq "F5 both warn" "$(cnt '--severity warn ' "$T/alerts")" 2
eq "F5 the two ids" "$(grep -oE -- '--id roadmap-file:w[0-9]+' "$T/alerts" | sort | paste -sd'|')" "--id roadmap-file:w1|--id roadmap-file:w2"
eq "F5 nothing under flags/" "$(find "$H/flags" -mindepth 1 | wc -l | tr -d ' ')" 0
eq "F5 both waves approved with an error" "$(q "SELECT COUNT(*) AS n FROM roadmap_waves WHERE status='approved' AND error = 'slice 1: http 500'" | jq -r '.[0].n')" 2
check "F5 summary ($(loglast))" 'loglast | grep -qE " waves=2 filed=0 created=0 reused=0 failed=2$"'

# ═════ F6: an in-app board -> no GitHub call ═════════════════════════════════
reset
q "UPDATE projects SET board_api_prefix = 'https://board.example.com/api' WHERE project = 'cromford'" >/dev/null
draft w1; approve w1 || bad "F6 approve"
run
eq "F6 rc 0" "$(cat "$T/rc")" 0
eq "F6 no GitHub call at all" "$(ghn)" 0
eq "F6 wave approved" "$(wv w1 status)" approved
eq "F6 the error" "$(wv w1 error)" "board not GitHub Issues"
eq "F6 one warn alert" "$(cnt '--id roadmap-file:w1 --severity warn ' "$T/alerts")" 1
eq "F6 no link row" "$(links w1)" 0

# ═════ F7: near-miss search hits are never reused ════════════════════════════
reset
draft w1; approve w1 || bad "F7 approve"
printf '%s\n' '{"number":7012,"state":"open","title":"other","body":"x\n<!-- harness-roadmap-slice: w1/12 -->"}' > "$T/gh/issues/7012.json"
printf '%s\n' '{"number":7013,"state":"open","title":"a pr","body":"x\n<!-- harness-roadmap-slice: w1/1 -->","pull_request":{"url":"https://api.github.com/repos/example-org/cromford/pulls/7013"}}' > "$T/gh/issues/7013.json"
printf '%s\n' '{"number":7014,"state":"open","title":"other wave","body":"x\n<!-- harness-roadmap-slice: w10/1 -->"}' > "$T/gh/issues/7014.json"
run
eq "F7 the search did answer the near misses" "$(cnt 'harness-roadmap-slice: w1/1"$' "$T/gh.q.log")" 1
eq "F7 all 3 slices created (no near miss reused)" "$(creates)" 3
eq "F7 slice 1 linked to the new issue, not 7012/7013" "$(q "SELECT MIN(issue) AS i FROM roadmap_links WHERE wave_id='w1'" | jq -r '.[0].i')" 8001
eq "F7 wave filed" "$(wv w1 status)" filed

# ═════ F8: --dry-run writes nothing ══════════════════════════════════════════
reset
draft w1; approve w1 || bad "F8 approve"
SNAP() { q "SELECT * FROM roadmap_waves ORDER BY id"; q "SELECT * FROM roadmap_links ORDER BY idea_id, issue"; }
BEFORE=$(SNAP)
env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 bash "$H/bin/roadmap-file.sh" --dry-run > "$T/out" 2>&1; echo $? > "$T/rc"
eq "F8 rc 0" "$(cat "$T/rc")" 0
eq "F8 D1 rows byte-identical" "$(SNAP)" "$BEFORE"
eq "F8 no POST to GitHub" "$(cnt '^POST ' "$T/gh.log")" 0
eq "F8 the marker searches ran" "$(cnt '^GET search/issues$' "$T/gh.log")" 3
eq "F8 the claim asked for a dry run" "$(grep '^POST /api/roadmap/waves/file-claim ' "$T/reqlog" | sed 's/^[^{]*//' | jq -r '.dry_run' | paste -sd,)" true
eq "F8 no write route" "$(cnt '/api/roadmap/(waves/(filed|file-done|approve)|links/state)' "$T/reqlog")" 0
eq "F8 three would-be issues on stdout" "$(grep -c '"title"' "$T/out")" 3
check "F8 the printed JSON is the create payload" 'grep "\"Slice three\"" "$T/out" | head -1 | jq -e ".labels == [\"ai-build\"] and (.body | endswith(\"<!-- harness-roadmap-slice: w1/3 -->\"))" >/dev/null'

# ═════ F9: a wave never approved is never read ═══════════════════════════════
reset
draft w1 draft; draft w2 requested
run
eq "F9 rc 0" "$(cat "$T/rc")" 0
eq "F9 no gh call at all" "$(ghn)" 0
eq "F9 both rows unchanged" "$(q "SELECT status FROM roadmap_waves ORDER BY id" | jq -r 'map(.status) | join(",")')" "draft,requested"
eq "F9 no log line (no work)" "$(cnt . "$H/logs/roadmap-file.log")" 0

# ═════ F10: lane-off flag -> exit 0, no roadmap request ══════════════════════
reset
draft w1; approve w1 || bad "F10 approve"
touch "$H/flags/lane-off-roadmap-file"
LGN=$(( NOW_S - NOW_S % 3600 + 420 ))  # a minute that is not :00/:15/:30/:45: no start offset
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" bash "$H/bin/roadmap-file.sh" > "$T/out" 2>&1; echo $? > "$T/rc"
eq "F10 rc 0 ($(head -c 200 "$T/out"))" "$(cat "$T/rc")" 0
eq "F10 no roadmap request" "$(cnt '/api/roadmap/' "$T/reqlog")" 0
eq "F10 no gh call" "$(ghn)" 0
eq "F10 wave still approved" "$(wv w1 status)" approved
# The control: the same gated run with no flag does claim the wave.
rm -f "$H/flags/lane-off-roadmap-file"
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" bash "$H/bin/roadmap-file.sh" > "$T/out" 2>&1
eq "F10 control: no flag, the gated run files the wave" "$(wv w1 status)" filed

echo "roadmap-file: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
