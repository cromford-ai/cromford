#!/bin/bash
# tests/roadmap-render.bh-7243-test.sh — BH-7265 (BH-7243.2): the roadmap
# render lane. Drives the SHIPPED bin/roadmap-render.sh (and its
# bin/lib/roadmap-html.sh) against the REAL worker routes (GET
# /api/roadmap/board from worker/jobs/src/routes/roadmap-board.js, GET
# /api/settings/<key> and GET /api/projects) over a node:sqlite file built from
# the REAL jobs schema (composed from schema.d/).
#
# WHAT IS STUBBED. `gh` on PATH: a fake GitHub with state in $FXT/gh/ (the
# default branch, one file per ref, the refs, the open PRs). It answers the
# `gh api -i -X <M> <path> [--input f]` calls gh_rest makes, records every call
# in $FXT/gh.log, and exits 7 on anything else (logged in $FXT/net.log).
# Nothing here reaches GitHub or the real worker. ROADMAP_RENDER_NOW pins the
# generated-at line (D60).
#
# RR1  the same board twice -> identical bytes (roadmap_html)
# RR2  the default branch holds the render but for its generated-at line ->
#      UNCHANGED, no PUT, no pulls POST
# RR3  a change -> branch created from the default head, one PUT, exactly one
#      POST pulls, the summary names pr=<the fixture html_url>
# RR4  a second change -> a PUT on the same branch, no second POST pulls, PR_UPDATED
# RR4b the branch already holds this render and the PR is open -> no PUT, PR_OPEN
# RR5  a <script> title is escaped; no "<script" in the page; a non-GitHub url is not an href
# RR6  an empty roadmap.render_projects -> no gh call, no projects or board read
# RR7  the create answer has no html_url -> PR_FAILED and no pr=
# RR8  a rate limit on the first gh call -> stopped=rate-limited, no write, the next project not read
# RR9  the branch guard: a repo whose default branch is roadmap/render-<p> -> refused, no write
# RR10 the cron line and the registry fields
# RR11 no claude, agent-call or lane_model in the lane; no merge call
# RR12 the render reads back through bin/roadmap-import.sh --dry-run
# RR13 a project with no projects row -> skip=no-repo; a board read failure -> FAILED board-read
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/roadmap-render.bh-7243-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "roadmap-render: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/roadmap-render.sh"
LIB="$DIR/bin/lib/roadmap-html.sh"
ROUTE="$DIR/worker/jobs/src/routes/roadmap-board.js"
CRON="$DIR/cron/lanes/741-roadmap-render.cron"
REG="$DIR/catalog/lanes.d/roadmap-render.json"
FIXTURE="$DIR/worker/jobs/test/fixtures/roadmap-board.bh-7243.json"
IMPORT="$DIR/bin/roadmap-import.sh"

for f in "$LANE" "$LIB" "$ROUTE" "$CRON" "$REG" "$FIXTURE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
# RR10: the cron line and the registry.
check "RR10 cron: daily 06:41, behind the hub lease" \
  'grep -qE "^41 6 \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/roadmap-render.sh " "$CRON" 2>/dev/null'
check "RR10 cron: a hub-lanes fragment" 'head -1 "$CRON" 2>/dev/null | grep -qx "# @hub-lanes"'
check "RR10 registry: hub lane, flag lane-off-roadmap-render" \
  '[ "$(jq -r "[.scope, (.boxes|join(\",\")), .switch.name, .script, .cadence, .stats.log] | @tsv" "$REG" 2>/dev/null)" = "$(printf "hub\thub\tlane-off-roadmap-render\tbin/roadmap-render.sh\t41 6 * * *\tlogs/roadmap-render.log")" ]'
check "RR10 the lane declares no-graphql" 'grep -q "^# gh-rest: no-graphql" "$LANE" 2>/dev/null'
# RR11: no model call, no merge.
check "RR11 no claude, agent-call or lane_model in the lane" \
  '[ -f "$LANE" ] && ! grep -nE "claude|agent-call|lane_model" "$LANE" "$LIB"'
check "RR11 no merge call in the lane" '[ -f "$LANE" ] && ! grep -nE "/merge\b|pr merge|merges\"|PUT .*merge" "$LANE"'
if [ ! -f "$LANE" ] || [ ! -f "$LIB" ] || [ ! -f "$ROUTE" ]; then
  echo "roadmap-render: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ RR1, RR5, RR12: the renderer alone ════════════════════════════════════
GEN=2026-10-17T06:41:00Z
html_of() { bash -c '. "$1" || exit 9; roadmap_html "$2" "$3" "$4"' _ "$LIB" "$@"; }
html_of "$FIXTURE" cromford "$GEN" > "$T/r1.html"; RC1=$?
html_of "$FIXTURE" cromford "$GEN" > "$T/r2.html"
eq "RR1 roadmap_html rc 0" "$RC1" 0
check "RR1 the same board twice gives identical bytes" 'cmp -s "$T/r1.html" "$T/r2.html" && [ -s "$T/r1.html" ]'
eq "RR1 line 2 is the generated-at line" "$(sed -n 2p "$T/r1.html")" "<!-- generated-at: $GEN -->"
html_of "$FIXTURE" cromford 2026-10-18T06:41:00Z > "$T/r3.html"
eq "RR1 another clock changes line 2 only" "$(diff "$T/r1.html" "$T/r3.html" | grep -c '^[<>]')" 2
check "RR1 sections in order now, next, later, shipped, decisions, open" \
  '[ "$(grep -oE "<h2 id=\"[a-z]+\"" "$T/r1.html" | sed -E "s/.*id=\"([a-z]+)\"/\1/" | tr "\n" " ")" = "now next later shipped decisions open " ]'
check "RR1 lane tables carry the project-6 columns" \
  '[ "$(grep -c "<thead><tr><th>Issue</th><th>Item</th><th>Status</th><th>Label</th><th>Size</th><th>Notes</th></tr></thead>" "$T/r1.html")" = 4 ]'
check "RR1 later is the Ideas column, newest first" \
  'awk "/id=\"later\"/{f=1} /id=\"shipped\"/{f=0} f" "$T/r1.html" | grep -oE "<td>(Alpha|Bravo) idea</td>" | tr "\n" " " | grep -qx "<td>Alpha idea</td> <td>Bravo idea</td> "'
check "RR1 a link cell is an href to the issue" 'grep -q "<a href=\"https://github.com/example-org/cromford/issues/101\">#101</a>" "$T/r1.html"'
check "RR1 decisions: Date | Decision | Source" 'grep -q "<th>Date</th><th>Decision</th><th>Source</th>" "$T/r1.html"'
check "RR1 open: Topic | Question | Where" 'grep -q "<th>Topic</th><th>Question</th><th>Where</th>" "$T/r1.html"'
eq "RR1 a bad generated_at is refused" "$(html_of "$FIXTURE" cromford 'x -->' >/dev/null; echo $?)" 1
echo '{"error":"no"}' > "$T/notboard.json"
eq "RR1 a non-board answer is refused" "$(html_of "$T/notboard.json" cromford "$GEN" >/dev/null; echo $?)" 1

jq '.columns.ideas[0].title = "<script>alert(1)</script>" | .columns.ideas[0].note = "a & b \"q\" '"'"'s'"'"'"
  | .columns.now[0].links[0].url = "javascript:alert(2)"' "$FIXTURE" > "$T/evil.json"
html_of "$T/evil.json" cromford "$GEN" > "$T/evil.html"
check "RR5 the title is escaped" 'grep -q "&lt;script&gt;alert(1)&lt;/script&gt;" "$T/evil.html"'
check "RR5 no <script in the page" '! grep -qi "<script" "$T/evil.html"'
ESC_WANT='a &amp; b &quot;q&quot; &#39;s&#39;'
check "RR5 the note's & quotes and apostrophes are escaped" 'grep -qF "$ESC_WANT" "$T/evil.html"'
check "RR5 a non-GitHub url is plain text, not an href" '! grep -q "href=\"javascript" "$T/evil.html" && grep -q "<td>#101 " "$T/evil.html"'

if [ -x "$IMPORT" ] && command -v python3 >/dev/null 2>&1; then
  IMP=$("$IMPORT" --project cromford --file "$T/r1.html" --dry-run 2>&1); RCI=$?
  eq "RR12 the importer reads the render (rc)" "$RCI" 0
  eq "RR12 the importer's counts" "$(grep -E 'ideas=|decisions=' <<<"$IMP" | tr '\n' ' ')" \
    "roadmap-import: now ideas=1 roadmap-import: next ideas=1 roadmap-import: later ideas=2 roadmap-import: shipped ideas=1 roadmap-import: decisions decisions=1 roadmap-import: open decisions=1 "
else
  echo "roadmap-render: RR12 SKIPPED — bin/roadmap-import.sh or python3 missing"
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "roadmap-render: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "roadmap-render: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { routes as rb } from '$ROUTE';
import { routes as rp } from '$DIR/worker/jobs/src/routes/projects.js';
import { routes as rs } from '$DIR/worker/jobs/src/routes/settings.js';
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
const sw = T + '/fail.' + method + '.' + path.replace(/[\/.]/g, '_');
if (existsSync(sw)) out(500, { error: 'fixture outage' });
const db = new DatabaseSync(T + '/d1.sqlite');
const hit = matchRoute([...rb, ...rp, ...rs], method, path);
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
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
NOW=2026-10-17T06:41:00Z
export FXT="$T" FXT_NOW="$NOW" NODE_NO_WARNINGS=1
if node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err"; then ok
else bad "schema.sql applies: $(head -3 "$T/mkdb.err")"; fi
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/flags" "$H/bin" "$T/fakebin"
for L in bin/roadmap-render.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
rm -f "$H/bin/gh-rest-shim"
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
    fi
    printf '%s %s\n' "$method" "${url#"$JOBS_URL"}" >> "$FXT/reqlog"
    node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The fake GitHub. State in $FXT/gh/<repo-slug>/:
#   default        the default branch name (missing: main)
#   refs/<b>       one file per branch: its head sha
#   files/<b>      docs/ROADMAP.html on branch <b> (missing: 404)
#   pulls.json     the open PRs (missing: [])
#   create.body    the POST pulls answer body (missing: a 201 with html_url)
# $FXT/gh/ratelimit: every call answers 403 rate limit.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] && [ "${2:-}" = -i ] && [ "${3:-}" = -X ] || { printf 'gh %s\n' "$*" >> "$FXT/net.log"; exit 7; }
m="$4"; p="$5"; shift 5
input=""; [ "${1:-}" = --input ] && input="$2"
printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
[ -n "$input" ] && cp "$input" "$FXT/gh.last.$m.json"
if [ -f "$FXT/gh/ratelimit" ]; then restpr --raw 403 '{"message":"API rate limit exceeded"}'; exit 0; fi
repo=$(sed -E 's#^repos/([^/]+/[^/?]+).*#\1#' <<<"$p")
S="$FXT/gh/${repo/\//__}"
[ -d "$S" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
rest=${p#"repos/$repo"}
def=$(cat "$S/default" 2>/dev/null || echo main)
mkdir -p "$S/refs" "$S/files"
[ -f "$S/refs/${def//\//__}" ] || echo "sha-$def-fixture" > "$S/refs/${def//\//__}"
enc() { printf '%s' "${1//\//__}"; }
case "$m $rest" in
  "GET ")
    restpr --raw 200 "$(jq -nc --arg d "$def" '{default_branch:$d}')" ;;
  "GET /contents/docs/ROADMAP.html?ref="*)
    b=${rest#*ref=}; f="$S/files/$(enc "$b")"
    if [ -f "$f" ]; then restpr --raw 200 "$(jq -nc --arg c "$(base64 < "$f")" --arg s "$(sha1sum < "$f" | cut -c1-40)" '{content:$c, sha:$s, encoding:"base64"}')"
    else restpr --raw 404 '{"message":"Not Found"}'; fi ;;
  "GET /git/ref/heads/"*)
    b=${rest#/git/ref/heads/}
    if [ -f "$S/refs/$(enc "$b")" ]; then restpr --raw 200 "$(jq -nc --arg s "$(cat "$S/refs/$(enc "$b")")" '{object:{sha:$s}}')"
    else restpr --raw 404 '{"message":"Not Found"}'; fi ;;
  "POST /git/refs")
    b=$(jq -r '.ref' "$input" | sed 's#^refs/heads/##')
    if [ -f "$S/refs/$(enc "$b")" ]; then restpr --raw 422 '{"message":"Reference already exists"}'; exit 0; fi
    jq -r '.sha' "$input" > "$S/refs/$(enc "$b")"
    cp "$input" "$FXT/gh.refs.json"
    [ -f "$S/files/$(enc "$def")" ] && cp "$S/files/$(enc "$def")" "$S/files/$(enc "$b")"
    restpr --raw 201 '{"ref":"ok"}' ;;
  "PUT /contents/docs/ROADMAP.html")
    b=$(jq -r '.branch' "$input"); f="$S/files/$(enc "$b")"
    if [ -f "$f" ] && [ "$(jq -r '.sha // ""' "$input")" != "$(sha1sum < "$f" | cut -c1-40)" ]; then
      restpr --raw 409 '{"message":"sha does not match"}'; exit 0; fi
    jq -r '.content' "$input" | base64 -d > "$f"
    restpr --raw 200 '{"content":{"path":"docs/ROADMAP.html"}}' ;;
  "GET /pulls?state=open&head="*)
    restpr --raw 200 "$(cat "$S/pulls.json" 2>/dev/null || echo '[]')" ;;
  "POST /pulls")
    if [ -f "$S/create.body" ]; then restpr --raw 201 "$(cat "$S/create.body")"; exit 0; fi
    url="https://github.com/$repo/pull/77"
    jq -nc --arg u "$url" --arg h "$(jq -r .head "$input")" '[{number:77, html_url:$u, head:{ref:$h}}]' > "$S/pulls.json"
    restpr --raw 201 "$(jq -nc --arg u "$url" '{number:77, html_url:$u}')" ;;
  *) printf 'gh %s %s\n' "$m" "$p" >> "$FXT/net.log"; restpr --raw 404 '{"message":"Not Found"}' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh7265 JOBS_RETRIES=0 GH_ETAG=0

R=example-org/cromford
GS="$T/gh/example-org__cromford"
reset() {
  local p
  for p in reqlog net.log gh.log out rc gh; do scratch_rm "$T/$p" || exit 1; done
  rm -f "$T"/fail.* "$T"/gh.last.* "$T/gh.refs.json"
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"; : > "$T/gh.log"
  mkdir -p "$GS/files" "$GS/refs"
  q "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('cromford', ?, 0, ?, ?)" "$R" "$NOW" "$NOW" >/dev/null
  q "INSERT INTO roadmap_ideas (id, project, title, source, lane, created_by, created_at, updated_at) VALUES ('i1', 'cromford', 'First idea', 'operator', 'ideas', 'operator', ?, ?)" "$NOW" "$NOW" >/dev/null
}
setp() { q "INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('roadmap.render_projects', ?, 'fixture', 'test', ?)" "$1" "$NOW" >/dev/null; }
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 ROADMAP_RENDER_NOW="${RNOW:-$NOW}" bash "$H/bin/roadmap-render.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt()  { local c; c=$(grep -cE -e "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
sumline() { grep -E '^projects=[0-9]+ ' "$T/out" | tail -1; }
pline() { grep -E "^$1 " "$T/out" | tail -1; }
# render <out>: what the lane renders for the current DB at the pinned clock.
render() {
  node "$T/wdrv.mjs" GET "/api/roadmap/board?project=cromford" | sed '$d' > "$T/board.now.json"
  html_of "$T/board.now.json" cromford "${RNOW:-$NOW}" > "$1"
}

# ═════ RR6: an empty roadmap.render_projects -> nothing ══════════════════════
reset
run
eq "RR6 rc 0" "$(cat "$T/rc")" 0
eq "RR6 the seed is empty: projects=0" "$(sumline)" "projects=0 created=0 updated=0 unchanged=0 failed=0 skipped=0 stopped=none"
eq "RR6 no gh call" "$(cnt . "$T/gh.log")" 0
eq "RR6 no projects or board read" "$(cnt '/api/projects|/api/roadmap/' "$T/reqlog")" 0
check "RR6 the summary is in the log" 'grep -qE " projects=0 created=0" "$H/logs/roadmap-render.log"'
setp ' , ,'
run
eq "RR6 blanks only: projects=0, no gh call" "$(sumline):$(cnt . "$T/gh.log")" "projects=0 created=0 updated=0 unchanged=0 failed=0 skipped=0 stopped=none:0"

# ═════ RR3: a change -> branch, PUT, ONE PR ══════════════════════════════════
reset
setp cromford
run
eq "RR3 rc 0" "$(cat "$T/rc")" 0
eq "RR3 the project line" "$(pline cromford)" "cromford PR_CREATED pr=https://github.com/$R/pull/77"
eq "RR3 the summary" "$(sumline)" "projects=1 created=1 updated=0 unchanged=0 failed=0 skipped=0 stopped=none"
eq "RR3 one POST pulls" "$(cnt '^POST repos/.*/pulls$' "$T/gh.log")" 1
eq "RR3 the branch created from the default head" "$(cnt "^POST repos/$R/git/refs$" "$T/gh.log")" 1
eq "RR3 ... at the main sha" "$(jq -r '.ref + " " + .sha' "$T/gh.refs.json" 2>/dev/null)" "refs/heads/roadmap/render-cromford sha-main-fixture"
eq "RR3 one PUT" "$(cnt "^PUT repos/$R/contents/docs/ROADMAP.html$" "$T/gh.log")" 1
eq "RR3 the PUT went to roadmap/render-cromford" "$(jq -r .branch "$T/gh.last.PUT.json")" roadmap/render-cromford
check "RR3 the default branch is never written" '[ ! -f "$GS/files/main" ]'
render "$T/want.html"
check "RR3 the branch file is the render" 'cmp -s "$GS/files/roadmap__render-cromford" "$T/want.html"'
eq "RR3 the PR: head, base, title" "$(jq -r '[.head, .base, .title] | join("|")' "$T/gh.last.POST.json")" \
  "roadmap/render-cromford|main|Roadmap: render docs/ROADMAP.html (cromford)"
check "RR3 the PR body carries the lane trailer" 'jq -r .body "$T/gh.last.POST.json" | grep -qx "Harness-Job: lane:roadmap-render"'
eq "RR3 no unknown gh call" "$(cnt . "$T/net.log")" 0

# ═════ RR4: another change -> the same branch, no second PR ══════════════════
q "UPDATE roadmap_ideas SET title = 'First idea, renamed', updated_at = ? WHERE id = 'i1'" "$NOW" >/dev/null
: > "$T/gh.log"
run
eq "RR4 PR_UPDATED with the open PR's url" "$(pline cromford)" "cromford PR_UPDATED pr=https://github.com/$R/pull/77"
eq "RR4 one PUT" "$(cnt '^PUT ' "$T/gh.log")" 1
eq "RR4 ... on the same branch" "$(jq -r .branch "$T/gh.last.PUT.json")" roadmap/render-cromford
check "RR4 ... with the branch blob sha" '[ -n "$(jq -r ".sha // empty" "$T/gh.last.PUT.json")" ]'
eq "RR4 no second POST pulls" "$(cnt '^POST repos/.*/pulls$' "$T/gh.log")" 0
eq "RR4 the branch is not created again" "$(cnt '^POST repos/.*/git/refs$' "$T/gh.log")" 0
check "RR4 the branch file has the new title" 'grep -q "First idea, renamed" "$GS/files/roadmap__render-cromford"'

# ═════ RR4b: the branch holds this render already -> no PUT, PR_OPEN ═════════
: > "$T/gh.log"
RNOW=2026-10-18T06:41:00Z run
eq "RR4b PR_OPEN, no PUT" "$(pline cromford):$(cnt '^PUT ' "$T/gh.log")" "cromford PR_OPEN pr=https://github.com/$R/pull/77:0"
eq "RR4b the summary counts it as updated" "$(sumline)" "projects=1 created=0 updated=1 unchanged=0 failed=0 skipped=0 stopped=none"

# ═════ RR2: main already holds the render (another day) -> UNCHANGED ═════════
reset
setp cromford
render "$GS/files/main"
: > "$T/gh.log"
RNOW=2026-10-18T06:41:00Z run
eq "RR2 UNCHANGED" "$(pline cromford)" "cromford UNCHANGED"
eq "RR2 summary" "$(sumline)" "projects=1 created=0 updated=0 unchanged=1 failed=0 skipped=0 stopped=none"
eq "RR2 no PUT and no POST" "$(cnt '^(PUT|POST) ' "$T/gh.log")" 0
eq "RR2 only the repo and contents reads" "$(tr '\n' ' ' < "$T/gh.log")" "GET repos/$R GET repos/$R/contents/docs/ROADMAP.html?ref=main "
# A change to any other line is a change.
sed -i 's#<h1>Roadmap: cromford</h1>#<h1>Roadmap: cromford (edited)</h1>#' "$GS/files/main"
: > "$T/gh.log"
run
eq "RR2 control: one other line differs -> a PR" "$(pline cromford)" "cromford PR_CREATED pr=https://github.com/$R/pull/77"

# ═════ RR7: the create answer has no html_url -> PR_FAILED, no pr= ═══════════
reset
setp cromford
rm -f "$GS/pulls.json" "$GS/refs/roadmap__render-cromford" "$GS/files/"*
echo '{"number":78}' > "$GS/create.body"
run
check "RR7 PR_FAILED" 'pline cromford | grep -qE "^cromford PR_FAILED "'
check "RR7 no pr= anywhere in the output" '! grep -q "pr=" "$T/out"'
eq "RR7 summary counts a failure" "$(sumline)" "projects=1 created=0 updated=0 unchanged=0 failed=1 skipped=0 stopped=none"
rm -f "$GS/create.body"

# ═════ RR8: a rate limit on the first gh call -> stop, no write ══════════════
reset
q "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('proj-b', 'o/proj-b', 0, ?, ?)" "$NOW" "$NOW" >/dev/null
setp 'cromford, proj-b'
rm -f "$GS/pulls.json" "$GS/refs/"* "$GS/files/"*
touch "$T/gh/ratelimit"
run
rm -f "$T/gh/ratelimit"
eq "RR8 rc 0" "$(cat "$T/rc")" 0
eq "RR8 one gh call, then the stop" "$(cnt . "$T/gh.log")" 1
eq "RR8 no PUT or POST" "$(cnt '^(PUT|POST) ' "$T/gh.log")" 0
eq "RR8 the next project's board is not read" "$(cnt 'project=proj-b' "$T/reqlog")" 0
eq "RR8 summary" "$(sumline)" "projects=1 created=0 updated=0 unchanged=0 failed=1 skipped=0 stopped=rate-limited"

# ═════ RR9: the branch guard ═════════════════════════════════════════════════
reset
setp cromford
rm -f "$GS/pulls.json" "$GS/refs/"* "$GS/files/"*
echo roadmap/render-cromford > "$GS/default"
run
rm -f "$GS/default" "$GS/refs/"*
check "RR9 the guard refuses the default branch" 'pline cromford | grep -q "FAILED branch-guard"'
eq "RR9 no write" "$(cnt '^(PUT|POST) ' "$T/gh.log")" 0
G=$(bash -c 'eval "$(sed -n "/^branch_ok() {/,/^}/p" "$1")"; for b in "main main" "main dev" "roadmap/render-x main" "roadmap/render-x roadmap/render-x" "roadmap/render- main" "roadmap/render-a/b main" "master main"; do set -- $b; branch_ok "$1" "$2" && echo "$1:ok" || echo "$1:no"; done' _ "$LANE" | tr '\n' ' ')
eq "RR9 branch_ok: only roadmap/render-<p>, never the default, main or master" "$G" \
  "main:no main:no roadmap/render-x:ok roadmap/render-x:no roadmap/render-:no roadmap/render-a/b:no master:no "

# ═════ RR13: no repo -> skip; a board read failure -> FAILED, next project ═══
reset
q "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES ('proj-b', 'o/proj-b', 0, ?, ?)" "$NOW" "$NOW" >/dev/null
setp 'ghost, cromford, proj-b'
rm -f "$GS/pulls.json" "$GS/refs/"* "$GS/files/"*
touch "$T/fail.GET._api_roadmap_board"
run
eq "RR13 ghost: skip=no-repo" "$(pline ghost)" "ghost skip=no-repo"
eq "RR13 a failed board read" "$(pline cromford)" "cromford FAILED board-read (http 500)"
check "RR13 the next project still runs (404 repo on the fake GitHub)" 'pline proj-b | grep -q "FAILED"'
eq "RR13 no GitHub call for a failed board read" "$(cnt "repos/$R" "$T/gh.log")" 0
eq "RR13 summary" "$(sumline)" "projects=3 created=0 updated=0 unchanged=0 failed=2 skipped=1 stopped=none"

# ═════ lane-off flag -> exit 0, no request ═══════════════════════════════════
reset
setp cromford
touch "$H/flags/lane-off-roadmap-render"
NOW_S=$(date -u -d "$NOW" +%s)
LGN=$(( NOW_S - NOW_S % 3600 + 420 ))
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" ROADMAP_RENDER_NOW="$NOW" bash "$H/bin/roadmap-render.sh" > "$T/out" 2>&1; echo $? > "$T/rc"
rm -f "$H/flags/lane-off-roadmap-render"
eq "lane off: rc 0" "$(cat "$T/rc")" 0
eq "lane off: no settings, projects or board read (the gate makes its own flag calls)" "$(cnt '/api/settings/|/api/projects|/api/roadmap/' "$T/reqlog")" 0
eq "lane off: no gh call" "$(cnt . "$T/gh.log")" 0
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" ROADMAP_RENDER_NOW="$NOW" bash "$H/bin/roadmap-render.sh" > "$T/out" 2>&1
eq "lane off control: no flag, the gated run reads the setting" "$(cnt '^GET /api/settings/roadmap.render_projects' "$T/reqlog")" 1

echo "roadmap-render: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
