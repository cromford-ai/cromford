#!/bin/bash
# tests/lesson-measure.bh-5808-test.sh — BH-5808 (BH-5794.3): measure and
# retire lessons. Drives the SHIPPED bin/lesson-measure.sh against the REAL
# worker routes (worker/jobs/src/routes/lessons.js and ledger.js) over a
# node:sqlite file built from the REAL jobs schema (composed from schema.d/).
#
# WHAT IS STUBBED. bin/archie-tg-send.sh (it records each akey and text, and
# answers rc $FXT/tg.rc), GET /api/settings (empty), and `gh` on PATH: a small
# fake GitHub that answers `api -i -X <METHOD> <path>` from the files under
# $FXT/gh (issues/<n>.json, pulls/<n>.json, repo/<path>), records every call in
# $FXT/gh.log and every --input body in $FXT/gh/in.<n>.json. Nothing here
# reaches GitHub, Telegram or the real worker. The worker's clock and the
# lane's clock are both pinned to $NOW (D60).
#
# Sections: L0-L11 (the plan's acceptance cases), K (knobs), C and M (the cron
# line, no model literal), then the worker's own node suite.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-measure.bh-5808-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "lesson-measure: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/lesson-measure.sh"
ROUTE="$DIR/worker/jobs/src/routes/lessons.js"
FRAG="$DIR/worker/jobs/schema.d/202610161105-bh-5808-lessons.sql"
CRON="$DIR/cron/lanes/734-lesson-measure.cron"
for f in "$LANE" "$ROUTE" "$FRAG" "$CRON" "$DIR/catalog/lanes.d/lesson-measure.json" "$DIR/worker/jobs/test/route-table.d/bh-5808-lessons.txt"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "M1 no hardcoded model string in the lane, the routes or the schema fragment" \
  '[ -f "$LANE" ] && [ -f "$FRAG" ] && [ -f "$ROUTE" ] && ! grep -nE "claude-(opus|sonnet|haiku|fable)|grok-[0-9]" "$LANE" "$FRAG" "$ROUTE"'
check "C1 cron: daily at 07:23, behind the hub lease" \
  'grep -qE "^23 7 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/lesson-measure.sh " "$CRON" 2>/dev/null'
check "A1 plan-contract §10 still has the '- docs/OPERATING' bullet wave 2 writes above" \
  'grep -q "^- docs/OPERATING" <<<"$(awk "/^## 10\\./{s=1;next} /^## /{s=0} s" "$DIR/prompts/plan-contract.md")"'
# L11: out of scope is the lead review itself. PR-scoped (BH-5684): only this
# branch's own diff is read, and only while it is non-empty. On main after the
# merge (or with no origin/main) the diff is empty and L11 is skipped.
L11_FILES=$(git -C "$DIR" diff --name-only "$(git -C "$DIR" merge-base origin/main HEAD 2>/dev/null)" HEAD 2>/dev/null)
# BH-7123: the scope rule is BH-5808's own. On any other branch (or a merge-queue
# draft carrying another ticket's diff) the lead review is in scope for that
# ticket, so L11 reads only a bh-5808 branch; elsewhere it is skipped.
case "$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" in *5808*) ;; *) L11_FILES="" ;; esac
if [ -z "$L11_FILES" ]; then
  echo "L11: skip — empty branch diff vs origin/main (merged, or no origin/main here)"
else
  check "L11 no bin/lead-review* file in the branch diff" \
    '! grep -q "^bin/lead-review" <<<"$L11_FILES"'
fi
if [ ! -f "$LANE" ] || [ ! -f "$ROUTE" ]; then
  echo "lesson-measure: $PASS passed, $FAIL failed"; exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "lesson-measure: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "lesson-measure: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "lesson-measure: lane sections SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
  echo "lesson-measure: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-14T12:00:00Z
WEEK=2026-W42
NOW_S=$(date -u -d "$NOW" +%s)
iso_ago() { date -u -d "@$((NOW_S - $1 * 86400))" +%Y-%m-%dT%H:%M:%SZ; }

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { routes as ls } from '$ROUTE';
import { routes as lg } from '$DIR/worker/jobs/src/routes/ledger.js';
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
const hit = matchRoute([...ls, ...lg], method, path);
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
# pop.mjs <category> <start-iso> <days> <prs> <blocks>: <prs> PRs with one
# verdict each, spread over <days> days; the first <blocks> are BLOCK verdicts
# with one block_findings row in <category> (the rows POST /api/verdicts and
# POST /api/block-classify/settle write).
cat > "$T/pop.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [cat, start, days, prs, blocks] = process.argv.slice(2);
const R = 'example-org/cromford', SHA = 'c'.repeat(40);
const base = Number(db.prepare('SELECT COALESCE(MAX(pr), 20000) AS m FROM verdicts').get().m) + 1;
const v = db.prepare("INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, created_at) VALUES (?, ?, ?, ?, 'lead', 'mac-lead', ?)");
const f = db.prepare(`INSERT INTO block_findings (verdict_id, n, repo, pr, ticket, head_sha, source, category, cause, files, infra_false, text, verdict_at, created_at)
  VALUES (?, 1, ?, ?, 'BH-9001', ?, 'lead', ?, 'a cause', '[]', 0, '- [BLOCK] bin/x.sh:1: a finding', ?, ?)`);
const step = (Number(days) * 86400000) / Number(prs);
db.exec('BEGIN');
for (let i = 0; i < Number(prs); i++) {
  const at = new Date(Date.parse(start) + Math.floor(i * step) + 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
  const r = v.run(R, base + i, SHA, i < Number(blocks) ? 'BLOCK' : 'MERGE', at);
  if (i < Number(blocks)) f.run(Number(r.lastInsertRowid), R, base + i, SHA, cat, at, at);
}
db.exec('COMMIT');
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
# The lane and the jobs client it sources by $SELF (the closure follows bin/lib only).
for L in bin/lesson-measure.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
# akey | text, one call per line; rc from $FXT/tg.rc
printf '%s\n' "$1" >> "$FXT/tgcalls"
n=$(grep -c . "$FXT/tgcalls")
printf '%s' "$2" > "$FXT/tgtext.$n"
exit "$(cat "$FXT/tg.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/archie-tg-send.sh"
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
st() { local s; s=$(head -1 "$G/$1.status" 2>/dev/null); if [ -n "$s" ]; then sed -i 1d "$G/$1.status"; echo "$s"; else echo "$2"; fi; }
R=example-org/cromford
path="${p%%\?*}"; query=""; [ "$path" != "$p" ] && query="${p#*\?}"
next() { local c; c=$(cat "$G/counter" 2>/dev/null || echo 8000); c=$((c + 1)); echo "$c" > "$G/counter"; echo "$c"; }
list() { # list <dir> <statusname>
  local s; s=$(st "$2" 200)
  [ "$s" = 200 ] || { restpr --raw "$s" '{"message":"fixture"}'; exit 0; }
  if [ "$page" != 1 ]; then restpr --raw 200 '[]'; exit 0; fi
  restpr --raw 200 "$(cat "$G/$1"/*.json 2>/dev/null | jq -sc '[.[] | select(.state == "open")]')"; exit 0
}
case "$m $path" in
  "GET repos/$R/issues") list issues issues.list ;;
  "GET repos/$R/pulls") list pulls pulls.list ;;
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
unset LESSON_MEASURE_ENABLED LESSON_MEASURE_MAX_PER_TICK HARNESS_REPO 2>/dev/null || true

# plan-contract on the fake main, in the shape the real one has: a §10 list
# that ends with the `- docs/OPERATING` bullet, then `## 11.`. Wave 2 writes
# its bullets with the `(lesson-propose: <category>)` suffix.
plan_fixture() {
  cat <<'EOF'
# Plan contract

## 10. Operating lessons (BH-5289)

- A first lesson.
- Name test-cannot-fail in the plan when a test can not fail.
- A plan names one mutation per acceptance test. (lesson-propose: test-cannot-fail)
- Name the iron law the plan touches. (lesson-propose: iron-law)
- docs/OPERATING.md has the reasons and the knobs.

## 11. Conflict discipline

- An old line outside §10. (lesson-propose: test-cannot-fail)
EOF
}

reset() {
  local p
  for p in reqlog net.log gh.log gh.in.log out rc tgcalls tg.rc gh; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/tgtext.* "$T"/fail.*
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
  mkdir -p "$T/gh/issues" "$T/gh/pulls" "$T/gh/repo/prompts"
  plan_fixture > "$T/gh/repo/prompts/plan-contract.md"
}
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LESSON_MEASURE_NOW="$NOW" "$@" bash "$H/bin/lesson-measure.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()      { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
ghn()    { local c; c=$(grep -cE "^$1 $2\$" "$T/gh.log" 2>/dev/null); printf '%s' "${c:-0}"; }
writes() { local c; c=$(grep -cE '^(POST|PUT|PATCH|DELETE) ' "$T/gh.log" 2>/dev/null); printf '%s' "${c:-0}"; }
tgn()    { n "$T/tgcalls"; }
R=example-org/cromford
pop() { node "$T/pop.mjs" "$@"; }
# scenario <category> <merged-days-ago> <before-prs> <before-blocks> <after-prs> <after-blocks>:
# the 14 days before and after a merge.
scenario() {
  local m; m=$(( NOW_S - $2 * 86400 ))
  pop "$1" "$(date -u -d "@$((m - 14 * 86400))" +%FT%TZ)" 14 "$3" "$4"
  pop "$1" "$(date -u -d "@$m" +%FT%TZ)" 14 "$5" "$6"
}
# put_led <category> <status> <detail>: a lesson_proposal row in the shape
# bin/lesson-propose.sh writes it.
put_led() { q "INSERT INTO ledgers (kind, key, status, actor, detail, created_at, updated_at) VALUES ('lesson_proposal', ?, ?, 'hub', ?, ?, ?)" "$1" "$2" "$3" "$NOW" "$NOW" >/dev/null; }
led_det() { # led_det <kind pr|issue> <number> <target> <at>
  jq -nc --arg k "$1" --argjson n "$2" --arg t "$3" --arg at "$4" \
    '{fp:"0123456789abcdef", target:$t, kind:$k, path:(if $k == "pr" then "prompts/plan-contract.md" else null end), number:$n,
      url:("https://github.com/example-org/cromford/" + (if $k == "pr" then "pull" else "issues" end) + "/" + ($n|tostring)),
      at:$at, attempts:1, blocks:3, seen:[1,2,3], draft:{target:$t, title:"Make every new test fail once", text:"x", acceptance_tests:[], why:"y"}}'
}
# lesson <category> <change_type> <kind> <number> <merged-days-ago> [status]:
# a lessons row in the shape POST /api/lessons writes it. Sets LID.
lesson() {
  LID=$(q "INSERT INTO lessons (category, change_type, kind, repo, number, url, title, source, merged_at, status, created_at, updated_at) VALUES (?, ?, ?, '$R', ?, ?, 't', 'proposal', ?, ?, ?, ?)" \
    "$1" "$2" "$3" "$4" "https://github.com/$R/$( [ "$3" = pr ] && echo pull || echo issues)/$4" "$(iso_ago "$5")" "${6:-measuring}" "$NOW" "$NOW" | jq -r '.[0].id')
}
lrow() { q "SELECT * FROM lessons WHERE id = ?" "$1" | jq -c '.[0] // {}'; }
lval() { lrow "$1" | jq -r --arg f "$2" '.[$f] // "null" | tostring'; }
lcount() { q "SELECT COUNT(*) AS n FROM lessons" | jq -r '.[0].n'; }
wk() { q "SELECT status, detail FROM ledgers WHERE kind='lesson_measure' AND key=?" "$WEEK" | jq -c '.[0] // {}'; }
loglast() { tail -1 "$H/logs/lesson-measure.log" 2>/dev/null; }
put_content() { local f; f=$(grep '^PUT ' "$T/gh.in.log" | sed -n "${1}p" | awk '{print $3}'); jq -r '.content' "$T/gh/$f.json" | base64 -d; }

# ═════ L0: the sweep records only merged lessons ═════════════════════════════
reset
put_led test-cannot-fail merged "$(led_det pr 7101 plan-lesson "$(iso_ago 20)")"
put_led iron-law open "$(led_det pr 7102 builder-rule "$(iso_ago 30)")"
jq -nc '{number:7102, state:"closed", merged_at:"2026-10-05T09:00:00Z", closed_at:"2026-10-05T09:00:00Z", title:"Lesson: y [lesson:iron-law]", body:"", html_url:"https://github.com/example-org/cromford/pull/7102"}' > "$T/gh/pulls/7102.json"
put_led scope-creep open "$(led_det issue 7103 check "$(iso_ago 5)")"
jq -nc '{number:7103, state:"open", state_reason:null, closed_at:null, title:"Lesson: z [lesson:scope-creep]", body:"", html_url:"https://github.com/example-org/cromford/issues/7103"}' > "$T/gh/issues/7103.json"
put_led no-test closed "$(led_det pr 7104 plan-lesson "$(iso_ago 5)")"
put_led skip-ci open "$(led_det issue 7105 harness-bug "$(iso_ago 9)")"
jq -nc '{number:7105, state:"closed", state_reason:"not_planned", closed_at:"2026-10-06T09:00:00Z", title:"Lesson: w [lesson:skip-ci]", body:"", html_url:"https://github.com/example-org/cromford/issues/7105"}' > "$T/gh/issues/7105.json"
LED_BEFORE=$(q "SELECT key, status, detail, updated_at FROM ledgers WHERE kind='lesson_proposal' ORDER BY key")
run
check "L0 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "L0 exactly 2 lessons rows (merged, open-then-merged)" "$(lcount)" 2
L0A=$(q "SELECT category, change_type, kind, number, merged_at, source, status FROM lessons WHERE number = 7101" | jq -c '.[0]')
eq "L0 the merged row: plan-lesson, merged_at from the ledger" "$L0A" "{\"category\":\"test-cannot-fail\",\"change_type\":\"plan-lesson\",\"kind\":\"pr\",\"number\":7101,\"merged_at\":\"$(iso_ago 20)\",\"source\":\"proposal\",\"status\":\"measuring\"}"
eq "L0 the open-then-merged row: builder-rule, merged_at live" "$(q "SELECT change_type || ' ' || merged_at AS x FROM lessons WHERE number = 7102" | jq -r '.[0].x')" "builder-rule 2026-10-05T09:00:00Z"
eq "L0 an open, a closed and a closed-unmerged proposal are no lesson" "$(q "SELECT COUNT(*) AS n FROM lessons WHERE number IN (7103, 7104, 7105)" | jq -r '.[0].n')" 0
eq "L0 the lane writes no lesson_proposal row" "$(q "SELECT key, status, detail, updated_at FROM ledgers WHERE kind='lesson_proposal' ORDER BY key")" "$LED_BEFORE"
eq "L0 no GitHub write" "$(writes)" 0
check "L0 the summary line counts 2 recorded" 'grep -q "recorded=2 " <<<"$(loglast)"'
run
eq "L0 a second tick records nothing new" "$(lcount)" 2
eq "L0 ... and writes no second summary line (it did no work)" "$(grep -c "recorded=" "$H/logs/lesson-measure.log")" 1

# ═════ L1: 10/100 before, 2/100 after -> working; the digest lists the rate ══
reset
# Merged 25 days ago: the after-window [-25d, -11d) is out of the 7-day digest window.
put_led test-cannot-fail merged "$(led_det pr 7101 plan-lesson "$(iso_ago 25)")"
scenario test-cannot-fail 25 100 10 100 2
pop test-cannot-fail "$(iso_ago 5)" 4 20 3
pop iron-law "$(iso_ago 5)" 4 20 1
run
check "L1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
L1=$(q "SELECT id FROM lessons WHERE number = 7101" | jq -r '.[0].id')
eq "L1 the lesson is working" "$(lval "$L1" status)" working
eq "L1 counts before/after" "$(lval "$L1" before_blocks)/$(lval "$L1" before_reviewed) $(lval "$L1" after_blocks)/$(lval "$L1" after_reviewed)" "10/100 2/100"
eq "L1 one digest send with the week akey" "$(cat "$T/tgcalls" 2>/dev/null)" "lesson-digest:$WEEK"
TXT=$(cat "$T/tgtext.1" 2>/dev/null)
check "L1 the digest names the overall rate (4 BLOCKs in 40 PRs, 10.0)" 'grep -qF "BLOCK rate: 10 per 100 reviewed PRs (4 BLOCKs in 40 PRs)." <<<"$TXT"'
check "L1 the digest lists the per-category rate (test-cannot-fail 3, 7.5)" 'grep -qE "^- .+ \(test-cannot-fail\): 3, 7.5, lesson working$" <<<"$TXT"'
check "L1 ... and iron-law (1, 2.5) as an uncovered cause" 'grep -qE "^- .+ \(iron-law\): 1, 2.5$" <<<"$TXT" && grep -qF "(iron-law): 1 BLOCKs" <<<"$(grep -A3 "Top uncovered" <<<"$TXT")"'
check "L1 the digest has no em dash and is at most 3500 chars" '! grep -q "—" <<<"$TXT" && [ "${#TXT}" -le 3500 ]'
eq "L1 the week row is done" "$(wk | jq -r .status)" done
eq "L1 its detail: judged 1, working 1, sent, a retention count" "$(wk | jq -c '.detail | fromjson | [.judged, .working, .digest.sent, .retention.eligible]')" "[1,1,true,0]"
check "L1 the summary line" 'grep -q "recorded=1 escalated=0 removal_prs=0 retired=0 reopened=0 held=0 judged=1 working=1 not_working=0 digest=sent" <<<"$(loglast)"'
eq "L1 no GitHub write (a working lesson is not escalated)" "$(writes)" 0

# ═════ L2: 10/100 then 9/100 -> not-working and ONE escalation issue ═════════
reset
put_led test-cannot-fail merged "$(led_det pr 7101 plan-lesson "$(iso_ago 20)")"
scenario test-cannot-fail 20 100 10 100 9
run
L2=$(q "SELECT id FROM lessons WHERE number = 7101" | jq -r '.[0].id')
eq "L2 the lesson is not-working" "$(lval "$L2" status)" not-working
eq "L2 ONE issue" "$(ghn POST "repos/$R/issues")" 1
ISS=$(cat "$T/gh/issues/8001.json" 2>/dev/null)
check "L2 the title asks for a builder-rule with the wave 2 tag" 'jq -e ".title == \"Lesson escalation: test-cannot-fail needs a builder-rule [lesson:test-cannot-fail]\"" <<<"$ISS" >/dev/null'
check "L2 label ai-build" 'jq -e "[.labels[].name] == [\"ai-build\"]" <<<"$ISS" >/dev/null'
check "L2 the body names the counts, the rates and the marker" 'IB=$(jq -r .body <<<"$ISS"); grep -qF "10 BLOCKs in 100 reviewed PRs, 10.0 per 100" <<<"$IB" && grep -qF "9 BLOCKs in 100 reviewed PRs, 9.0 per 100" <<<"$IB" && grep -qF "<!-- lesson-measure: escalate lesson=$L2 category=test-cannot-fail stage=builder-rule -->" <<<"$IB"'
eq "L2 the row carries the escalation" "$(lval "$L2" escalation_stage) $(lval "$L2" escalation_number) $(lval "$L2" escalation_url)" "builder-rule 8001 https://github.com/$R/issues/8001"
check "L2 the summary counts it" 'grep -q "escalated=1 .*not_working=1" <<<"$(loglast)"'
# L8: wave 2's REAL lp_marker_hit (extracted from bin/lesson-propose.sh) sees the issue.
sed -n '/^lp_marker_hit() {/,/^}/p' "$DIR/bin/lesson-propose.sh" > "$T/lpmh.sh"
mkdir -p "$T/l8"; jq -s '.' "$T/gh/issues/8001.json" > "$T/l8/open-issues.json"; echo '[]' > "$T/l8/open-prs.json"
L8=$( . "$T/lpmh.sh" && TMPD="$T/l8" lp_marker_hit test-cannot-fail 2>/dev/null )
check "L8 the lp_marker_hit block was extracted" 'grep -q "lp_marker_hit()" "$T/lpmh.sh"'
eq "L8 wave 2's lp_marker_hit finds the escalation" "$(jq -r '"\(.kind) \(.number)"' <<<"$L8" 2>/dev/null)" "issue 8001"
# L7: a second tick in the same week files nothing and sends nothing.
run
eq "L7 the second tick files no issue" "$(ghn POST "repos/$R/issues")" 1
eq "L7 ... and sends no second digest" "$(tgn)" 1
# The escalation issue closes as completed: it is recorded as its own lesson,
# with the escalation stage.
jq -c '.state = "closed" | .state_reason = "completed" | .closed_at = "2026-10-14T10:00:00Z"' "$T/gh/issues/8001.json" > "$T/x.json" && mv "$T/x.json" "$T/gh/issues/8001.json"
run
eq "L2c the closed escalation is a lesson: builder-rule, source escalation" "$(q "SELECT change_type || ' ' || source || ' ' || merged_at AS x FROM lessons WHERE kind = 'issue' AND number = 8001" | jq -r '.[0].x')" "builder-rule escalation 2026-10-14T10:00:00Z"
eq "L2c ... and nothing is filed for it" "$(ghn POST "repos/$R/issues")" 1

# ═════ L2b: a not-working harness-bug has no stronger stage ══════════════════
reset
put_led skip-ci merged "$(led_det issue 7106 harness-bug "$(iso_ago 20)")"
scenario skip-ci 20 100 10 100 9
run
eq "L2b not-working" "$(q "SELECT status FROM lessons WHERE number = 7106" | jq -r '.[0].status')" not-working
eq "L2b no issue" "$(writes)" 0
check "L2b one log line says there is no stronger stage" '[ "$(grep -c "skip-ci: lesson .* (harness-bug) is not working and has no stronger stage; nothing filed" "$H/logs/lesson-measure.log")" = 1 ]'

# ═════ L3 / L3b: a superseded plan lesson is removed by ONE PR ═══════════════
reset
lesson test-cannot-fail plan-lesson pr 7201 40 working; L3=$LID
lesson test-cannot-fail check issue 7202 20; L3C=$LID
run
eq "L3 ONE PR" "$(ghn POST "repos/$R/pulls")" 1
eq "L3 ONE PUT of plan-contract" "$(ghn PUT "repos/$R/contents/prompts/plan-contract.md")" 1
PC=$(put_content 1 2>/dev/null)
check "L3 the new file lacks the (lesson-propose: test-cannot-fail) §10 bullet" '! grep -qF "(lesson-propose: test-cannot-fail)" <<<"$(awk "/^## 10\\./{s=1;next} /^## /{s=0} s" <<<"$PC")"'
eq "L3b every other line stays (hand bullet, other category, docs/OPERATING, outside §10)" "$PC" "$(plan_fixture | grep -vxF -- '- A plan names one mutation per acceptance test. (lesson-propose: test-cannot-fail)')"
PRJ=$(cat "$T/gh/pulls/8001.json" 2>/dev/null)
check "L3 the title carries [lesson-retire:], never [lesson:]" 'jq -e ".title == \"Lesson retired: test-cannot-fail superseded by a check [lesson-retire:test-cannot-fail]\"" <<<"$PRJ" >/dev/null'
check "L3 the head is harness/lesson-retire-test-cannot-fail-$L3-<main sha8>" 'jq -e ".head.ref == \"harness/lesson-retire-test-cannot-fail-$L3-c0ffee00\"" <<<"$PRJ" >/dev/null'
BODY=$(jq -r .body <<<"$PRJ")
check "L3 the body has the marker and the removed line" 'grep -qF "<!-- lesson-measure: retire lesson=$L3 category=test-cannot-fail -->" <<<"$BODY" && grep -qF "A plan names one mutation per acceptance test." <<<"$BODY"'
eq "L3 the body ends with the trailer block" "$(printf '%s\n' "$BODY" | grep -v '^$' | tail -2 | paste -sd'|')" "Harness-Job: lane:lesson-measure|Harness-Ticket: none"
eq "L3 an OPEN removal PR is recorded; the row is NOT superseded yet" "$(lval "$L3" status) $(lval "$L3" removal_number) $(lval "$L3" superseded_by)" "working 8001 $L3C"
check "L3 the summary counts the PR, not a retirement" 'grep -q "removal_prs=1 retired=0 " <<<"$(loglast)"'
# L7: a second tick opens no second PR, and the open PR changes nothing.
run
eq "L7 the second tick opens no PR" "$(ghn POST "repos/$R/pulls")" 1
eq "L7 the row is still not superseded" "$(lval "$L3" status) $(lval "$L3" removal_number)" "working 8001"
# L3f: the removal PR closes WITHOUT a merge: the PR is cleared, the next tick opens a new one.
jq '.state = "closed" | .closed_at = "2026-10-14T10:00:00Z"' "$T/gh/pulls/8001.json" > "$T/pr.tmp" && mv "$T/pr.tmp" "$T/gh/pulls/8001.json"
run
eq "L3f closed unmerged: cleared, not superseded" "$(lval "$L3" status) $(lval "$L3" removal_number)" "working null"
check "L3f the summary counts it reopened" 'grep -q "retired=0 reopened=1 " <<<"$(loglast)"'
eq "L3f no new PR in the clearing tick" "$(ghn POST "repos/$R/pulls")" 1
run
eq "L3f the next tick opens a new removal PR" "$(ghn POST "repos/$R/pulls")" 2
eq "L3f the row records the new PR" "$(lval "$L3" status) $(lval "$L3" removal_number)" "working 8002"
# L3g: the new removal PR merges: only now is the row superseded.
jq '.state = "closed" | .merged_at = "2026-10-14T11:00:00Z" | .closed_at = "2026-10-14T11:00:00Z"' "$T/gh/pulls/8002.json" > "$T/pr.tmp" && mv "$T/pr.tmp" "$T/gh/pulls/8002.json"
run
eq "L3g merged: superseded with the merged PR" "$(lval "$L3" status) $(lval "$L3" removal_number)" "superseded 8002"
check "L3g the summary counts one retirement" 'grep -q "retired=1 " <<<"$(loglast)"'
run
eq "L3g a superseded row opens no further PR" "$(ghn POST "repos/$R/pulls")" 2

# L3c: no bullet with the suffix -> removed, removal_note absent, no PR.
reset
lesson no-test plan-lesson pr 7301 40; L3N=$LID
lesson no-test harness-bug issue 7302 20
run
eq "L3c no PR" "$(writes)" 0
eq "L3c marked removed / absent" "$(lval "$L3N" status) $(lval "$L3N" removal_note)" "removed absent"
# L3d: negatives: an EARLIER check, a check in another category and a later builder rule retire nothing.
reset
lesson iron-law check issue 7401 50
lesson iron-law plan-lesson pr 7402 40; L3E=$LID
lesson scope-creep check issue 7403 20
lesson test-cannot-fail plan-lesson pr 7404 40; L3F=$LID
lesson test-cannot-fail builder-rule pr 7405 20
run
eq "L3d nothing retired, no write" "$(writes)" 0
eq "L3d both plan lessons untouched" "$(lval "$L3E" status) $(lval "$L3F" status)" "measuring measuring"
# L3e: held while a wave 2 lesson PR is open on plan-contract.
reset
lesson test-cannot-fail plan-lesson pr 7501 40; L3H=$LID
lesson test-cannot-fail check issue 7502 20
jq -nc '{number:7600, state:"open", title:"Lesson: x [lesson:iron-law]", body:"Prompt file: `prompts/plan-contract.md`\n", html_url:"https://github.com/example-org/cromford/pull/7600"}' > "$T/gh/pulls/7600.json"
run
eq "L3e held: no write" "$(writes)" 0
eq "L3e the row is not retired" "$(lval "$L3H" status)" measuring
check "L3e held is logged and counted" 'grep -q "held: the open PR #7600 edits prompts/plan-contract.md" "$H/logs/lesson-measure.log" && grep -q "held=1 " <<<"$(loglast)"'

# ═════ L4: the ledger unreadable -> nothing recorded, no GitHub write ═════════
reset
put_led test-cannot-fail merged "$(led_det pr 7101 plan-lesson "$(iso_ago 20)")"
lesson iron-law plan-lesson pr 7601 30 not-working
: > "$T/fail.GET._api_ledger"
run
eq "L4 nothing recorded" "$(lcount)" 1
eq "L4 no GitHub call" "$(n "$T/gh.log")" 0
eq "L4 no weekly claim" "$(grep -c '^POST /api/ledger/claim' "$T/reqlog")" 0
check "L4 one log line" '[ "$(n "$H/logs/lesson-measure.log")" = 1 ] && grep -q "the lesson_proposal ledger could not be read" "$H/logs/lesson-measure.log"'

# ═════ L5: issue POST 500, then 201 next tick -> one issue total ══════════════
reset
lesson iron-law plan-lesson pr 7701 30 not-working; L5=$LID
echo 500 > "$T/gh/issues.post.status"
run
eq "L5 tick 1: no issue" "$(ls "$T/gh/issues" | grep -c '\.json$')" 0
eq "L5 tick 1: the stage is marked before the POST, no number" "$(lval "$L5" escalation_stage) $(lval "$L5" escalation_number)" "builder-rule null"
check "L5 tick 1: escalated=0" 'grep -q "escalated=0 " <<<"$(loglast)"'
run
eq "L5 tick 2: one issue total" "$(ls "$T/gh/issues" | grep -c '\.json$')" 1
eq "L5 tick 2: the number is marked" "$(lval "$L5" escalation_number)" 8001
check "L5 tick 2: escalated=1" 'grep -q "escalated=1 " <<<"$(loglast)"'
# A lost mark: the open issue's marker heals it, no second issue.
q "UPDATE lessons SET escalation_number = NULL, escalation_url = NULL WHERE id = ?" "$L5" >/dev/null
run
eq "L5 heal: no second issue" "$(ghn POST "repos/$R/issues")" 2
eq "L5 heal: the number is back" "$(lval "$L5" escalation_number)" 8001

# ═════ L6: send rc 1 then rc 0 -> two calls, one akey; a third tick sends 0 ═══
reset
echo 1 > "$T/tg.rc"
run
eq "L6 tick 1: one send" "$(tgn)" 1
eq "L6 tick 1: the week row is failed" "$(wk | jq -r .status)" failed
check "L6 tick 1: digest=failed" 'grep -q "digest=failed" <<<"$(loglast)"'
echo 0 > "$T/tg.rc"
run
eq "L6 tick 2: two sends, one akey" "$(sort -u "$T/tgcalls" | paste -sd,)/$(tgn)" "lesson-digest:$WEEK/2"
eq "L6 tick 2: done" "$(wk | jq -r .status)" done
run
eq "L6 tick 3: no third send" "$(tgn)" 2
reset; echo 2 > "$T/tg.rc"
run
eq "L6b rc 2 (not configured): done, sent=false" "$(wk | jq -c '[.status, (.detail | fromjson | .digest.sent)]')" '["done",false]'

# ═════ L9 / L10: the cap; working, inconclusive and measuring rows are left ═══
reset
for i in 1 2 3 4 5; do lesson "cat-$i" plan-lesson pr "780$i" 30 not-working; done
run
eq "L9 5 not-working rows: 3 issues on tick 1" "$(ghn POST "repos/$R/issues")" 3
run
eq "L9 the other 2 on tick 2" "$(ghn POST "repos/$R/issues")" 5
reset
lesson cat-a plan-lesson pr 7901 30 working
lesson cat-b plan-lesson pr 7902 30 inconclusive
lesson cat-c plan-lesson pr 7903 5 measuring
run
eq "L10 working, inconclusive and measuring rows: 0 issues" "$(writes)" 0

# ═════ K: knobs ══════════════════════════════════════════════════════════════
reset
for i in 1 2 3 4 5; do lesson "cat-$i" plan-lesson pr "780$i" 30 not-working; done
run LESSON_MEASURE_MAX_PER_TICK=x
check "K1 a junk MAX_PER_TICK: one warn line" '[ "$(grep -c "warn: LESSON_MEASURE_MAX_PER_TICK=x is not an integer in 1..20; using the default 3" "$H/logs/lesson-measure.log")" = 1 ]'
eq "K1 ... and the default 3 applies" "$(ghn POST "repos/$R/issues")" 3
reset
put_led test-cannot-fail merged "$(led_det pr 7101 plan-lesson "$(iso_ago 20)")"
run LESSON_MEASURE_ENABLED=0
eq "K2 ENABLED=0: no lane request" "$(grep -vc '^GET /api/settings' "$T/reqlog")" 0
eq "K2 ENABLED=0: no GitHub call" "$(n "$T/gh.log")" 0

# ═════ the worker half, as its own node suite ════════════════════════════════
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/lessons.bh-5808.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/lessons.bh-5808.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30; fi

echo "lesson-measure: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
