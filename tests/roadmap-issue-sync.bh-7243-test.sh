#!/bin/bash
# tests/roadmap-issue-sync.bh-7243-test.sh — BH-7267 (BH-7243.4): the issue
# state sync lane. Drives the SHIPPED bin/roadmap-issue-sync.sh against the REAL
# worker routes (worker/jobs/src/routes/roadmap-wave-file.js: GET
# /api/roadmap/links/stale, PUT /api/roadmap/links/state) over a node:sqlite
# file built from the REAL jobs schema (composed from schema.d/).
#
# WHAT IS STUBBED. `gh` on PATH: a fake GitHub that answers
# `api -i -X GET repos/<repo>/issues/<n>` from $FXT/gh/issues/<n>.json (no file:
# 404; a file $FXT/gh/issues/<n>.status: that status, with a rate-limit body on
# 403/429 unless $FXT/gh/issues/<n>.body gives the body) and records every call in $FXT/gh.log. S11 adds a stub
# $H/bin/gh-rest-shim that logs to $FXT/shim.log and then runs the fake gh.
# Nothing here reaches GitHub or the real worker. The worker's clock is pinned
# to $NOW (FXT_NOW, D60).
#
# Sections: S1-S12 (the plan's acceptance cases), S7b (a jobs outage), S7c (a
# 410 deleted issue) and S7d (a dead issue does not hold the queue head over
# two ticks: the refute review's BLOCK).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/roadmap-issue-sync.bh-7243-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "roadmap-issue-sync: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/roadmap-issue-sync.sh"
ROUTE="$DIR/worker/jobs/src/routes/roadmap-wave-file.js"
CRON="$DIR/cron/lanes/744-roadmap-issue-sync.cron"
REG="$DIR/catalog/lanes.d/roadmap-issue-sync.json"

for f in "$LANE" "$ROUTE" "$CRON" "$REG"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
# S10: no LLM call. The script names no model, no agent call, no lane model.
check "S10 no claude, agent-call or lane_model in the lane" \
  '[ -f "$LANE" ] && ! grep -nE "claude|agent-call|lane_model" "$LANE"'
# S12: the cron line.
check "S12 cron: every 15 minutes, behind the hub lease" \
  'grep -qE "^\*/15 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/roadmap-issue-sync.sh " "$CRON" 2>/dev/null'
check "S12 registry: hub lane, flag lane-off-roadmap-issue-sync" \
  '[ "$(jq -r "[.scope, (.boxes|join(\",\")), .switch.name, .script, .cadence] | @tsv" "$REG" 2>/dev/null)" = "$(printf "hub\thub\tlane-off-roadmap-issue-sync\tbin/roadmap-issue-sync.sh\t*/15 * * * *")" ]'
check "S12 the lane declares no-graphql" 'grep -q "^# gh-rest: no-graphql" "$LANE" 2>/dev/null'
if [ ! -f "$LANE" ] || [ ! -f "$ROUTE" ]; then
  echo "roadmap-issue-sync: $PASS passed, $FAIL failed"; exit 1
fi

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "roadmap-issue-sync: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "roadmap-issue-sync: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-19T12:00:00Z
NOW_S=$(date -u -d "$NOW" +%s)
iso_min_ago() { date -u -d "@$((NOW_S - $1 * 60))" +%Y-%m-%dT%H:%M:%SZ; }
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
for L in bin/roadmap-issue-sync.sh bin/jobs-client.sh; do
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
m="$4"; p="$5"
printf '%s %s\n' "$m" "$p" >> "$FXT/gh.log"
R=example-org/cromford
case "$m $p" in
  "GET repos/$R/issues/"*)
    n=${p##*/}
    if [ -f "$G/issues/$n.status" ]; then
      s=$(cat "$G/issues/$n.status")
      if [ -f "$G/issues/$n.body" ]; then restpr --raw "$s" "$(cat "$G/issues/$n.body")"; exit 0; fi
      case "$s" in 403|429) restpr --raw "$s" '{"message":"API rate limit exceeded"}' ;; *) restpr --raw "$s" '{"message":"fixture"}' ;; esac
      exit 0
    fi
    [ -f "$G/issues/$n.json" ] && restpr --raw 200 "$(cat "$G/issues/$n.json")" || restpr --raw 404 '{"message":"Not Found"}'
    exit 0 ;;
esac
printf 'gh %s %s\n' "$m" "$p" >> "$FXT/net.log"; exit 7
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh7267 JOBS_RETRIES=0 GH_ETAG=0

reset() {
  local p
  for p in reqlog net.log gh.log shim.log out rc gh; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/fail.* "$H/bin/gh-rest-shim"
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
  mkdir -p "$T/gh/issues"
}
# link <idea> <issue> [state_seen_at]: one roadmap_links row in the shape the filed route writes.
link() {
  q "INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, created_by, created_at, state_seen_at) VALUES (?, 'cromford', ?, ?, 'w1', 'roadmap-file', ?, ?)" \
    "$1" "$R" "$2" "$NOW" "${3:-}" >/dev/null
  [ -n "${3:-}" ] || q "UPDATE roadmap_links SET state_seen_at = NULL WHERE idea_id = ? AND issue = ?" "$1" "$2" >/dev/null
}
# gissue <n> <state> [state_reason]: the GitHub REST issue object.
gissue() {
  jq -nc --argjson n "$1" --arg s "$2" --arg r "${3:-}" \
    '{number:$n, state:$s, state_reason:(if $r == "" then null else $r end), title:"t", body:"b"}' > "$T/gh/issues/$1.json"
}
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 "$@" bash "$H/bin/roadmap-issue-sync.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt()   { local c; c=$(grep -cE -e "$1" "$2" 2>/dev/null); printf '%s' "${c:-0}"; }
gets()  { cnt '^GET repos/' "$T/gh.log"; }
st()    { q "SELECT issue_state AS v FROM roadmap_links WHERE idea_id = ? AND issue = ?" "$1" "$2" | jq -r '.[0].v // "null"'; }
seen()  { q "SELECT state_seen_at AS v FROM roadmap_links WHERE idea_id = ? AND issue = ?" "$1" "$2" | jq -r '.[0].v // "null"'; }
sumline() { grep -E 'read=[0-9]+ written=' "$T/out" | tail -1; }
loglast() { tail -1 "$H/logs/roadmap-issue-sync.log" 2>/dev/null; }

# ═════ S1-S4: the state map ══════════════════════════════════════════════════
reset
link i1 101; gissue 101 open
link i2 102; gissue 102 closed completed
link i3 103; gissue 103 closed not_planned
link i4 104; gissue 104 closed
run
eq "S1-S4 rc 0" "$(cat "$T/rc")" 0
eq "S1 open -> open" "$(st i1 101)" open
eq "S2 closed/completed -> closed_completed" "$(st i2 102)" closed_completed
eq "S3 closed/not_planned -> closed_other" "$(st i3 103)" closed_other
eq "S4 closed/null -> closed_other" "$(st i4 104)" closed_other
eq "S1-S4 state_seen_at is the worker clock" "$(seen i1 101)" "$NOW"
eq "S1-S4 four GETs" "$(gets)" 4
eq "S1-S4 summary on stdout" "$(sumline)" "read=4 written=4 failed=0 stopped=none"
check "S1-S4 summary in the log ($(loglast))" 'loglast | grep -qE " read=4 written=4 failed=0 stopped=none$"'
reset
link i5 105; gissue 105 closed reopened
run
eq "S4b closed/reopened -> closed_other" "$(st i5 105)" closed_other

# ═════ S5: two links on one issue -> one GET, both rows ══════════════════════
reset
link i1 201; link i2 201; gissue 201 closed completed
run
eq "S5 one GET for the issue" "$(cnt '^GET repos/example-org/cromford/issues/201$' "$T/gh.log")" 1
eq "S5 row 1 updated" "$(st i1 201)" closed_completed
eq "S5 row 2 updated" "$(st i2 201)" closed_completed
eq "S5 summary" "$(sumline)" "read=1 written=1 failed=0 stopped=none"

# ═════ S6: an unknown state -> no issue_state write, a tried stamp ═══════════
reset
link i1 301; gissue 301 weird
link i2 302; printf 'not json at all' > "$T/gh/issues/302.json"
run
eq "S6 unknown state: no issue_state write" "$(st i1 301)" null
eq "S6 ... state_seen_at is the tried stamp" "$(seen i1 301)" "$NOW"
eq "S6 unparseable body: no issue_state write" "$(st i2 302)" null
eq "S6 no issue_state PUT" "$(cnt '^PUT .*issue_state' "$T/reqlog")" 0
eq "S6 two tried PUTs" "$(cnt '^PUT /api/roadmap/links/state .*"tried":true' "$T/reqlog")" 2
eq "S6 summary" "$(sumline)" "read=2 written=0 failed=2 stopped=none"

# ═════ S7: a 404 -> no issue_state write, a tried stamp, failed=1 ════════════
reset
link i1 401
run
eq "S7 rc 0" "$(cat "$T/rc")" 0
eq "S7 no issue_state write" "$(st i1 401)" null
eq "S7 no issue_state PUT" "$(cnt '^PUT .*issue_state' "$T/reqlog")" 0
eq "S7 the tried stamp" "$(seen i1 401)" "$NOW"
eq "S7 summary" "$(sumline)" "read=1 written=0 failed=1 stopped=none"

# ═════ S7b: the jobs read fails -> exit 0, no GitHub call ════════════════════
reset
link i1 451; gissue 451 open
touch "$T/fail.GET._api_roadmap_links_stale"
run
eq "S7b rc 0" "$(cat "$T/rc")" 0
eq "S7b no GitHub call" "$(cnt . "$T/gh.log")" 0
check "S7b one log line names the failed read" 'grep -q "links/stale" "$H/logs/roadmap-issue-sync.log"'

# ═════ S7c: a 410 (GitHub deleted the issue) -> closed_other ═════════════════
reset
link i1 461; echo 410 > "$T/gh/issues/461.status"
link i2 462; gissue 462 open
run
eq "S7c 410 -> closed_other" "$(st i1 461)" closed_other
eq "S7c ... the loop goes on" "$(st i2 462)" open
eq "S7c summary" "$(sumline)" "read=2 written=2 failed=0 stopped=none"

# ═════ S7d: a dead issue never holds the queue head (two ticks) ══════════════
# Before the fix a failed read wrote nothing, so the dead link kept the oldest
# state_seen_at and was first on every tick: no other link was read again.
reset
q "INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('roadmap.issue_sync_batch', '2', 'fixture', 'test', ?)" "$NOW" >/dev/null
link i1 471 "$(iso_min_ago 400)"
link i2 472 "$(iso_min_ago 300)"
link i3 473 "$(iso_min_ago 200)"; gissue 473 closed completed
run
eq "S7d tick 1: the two 404 links fill the batch" "$(sumline)" "read=2 written=0 failed=2 stopped=none"
eq "S7d tick 1: the 3rd link not read yet" "$(st i3 473)" null
: > "$T/gh.log"
run
eq "S7d tick 2: the 404 links are not read again" "$(cnt '/issues/47[12]$' "$T/gh.log")" 0
eq "S7d tick 2: the 3rd link is read" "$(st i3 473)" closed_completed
# A non-rate-limit answer stops the run and goes to the back of the queue too.
reset
link i1 481 "$(iso_min_ago 400)"; gissue 481 open; echo 403 > "$T/gh/issues/481.status"
printf '{"message":"Resource not accessible by integration"}' > "$T/gh/issues/481.body"
link i2 482 "$(iso_min_ago 300)"; gissue 482 closed completed
run
eq "S7d 403 not a rate limit: the run stops" "$(sumline)" "read=1 written=0 failed=0 stopped=unverifiable"
eq "S7d ... the 403 link gets the tried stamp" "$(seen i1 481)" "$NOW"
: > "$T/gh.log"
run
eq "S7d tick 2: the 403 link is not read again" "$(cnt '/issues/481$' "$T/gh.log")" 0
eq "S7d tick 2: the next link is read" "$(st i2 482)" closed_completed

# ═════ S8: a rate limit on the 2nd issue stops the loop ══════════════════════
reset
link i1 501 "$(iso_min_ago 300)"; gissue 501 open
link i2 502 "$(iso_min_ago 200)"; gissue 502 open; echo 429 > "$T/gh/issues/502.status"
link i3 503 "$(iso_min_ago 100)"; gissue 503 open
run
eq "S8 rc 0" "$(cat "$T/rc")" 0
eq "S8 the 1st issue written" "$(st i1 501)" open
eq "S8 the 2nd not written" "$(st i2 502)" null
eq "S8 the 3rd never requested" "$(cnt '/issues/503$' "$T/gh.log")" 0
eq "S8 a rate limit stamps nothing on the 2nd" "$(seen i2 502)" "$(iso_min_ago 200)"
eq "S8 summary" "$(sumline)" "read=2 written=1 failed=0 stopped=rate-limited"
# A non-rate-limit 5xx is unverifiable, and it stops the loop too.
reset
link i1 511 "$(iso_min_ago 300)"; gissue 511 open; echo 502 > "$T/gh/issues/511.status"
link i2 512 "$(iso_min_ago 200)"; gissue 512 open
run
eq "S8b a 502 stops the loop" "$(cnt '/issues/512$' "$T/gh.log")" 0
eq "S8b ... and the 502 link gets the tried stamp" "$(seen i1 511)" "$NOW"
eq "S8b summary" "$(sumline)" "read=1 written=0 failed=0 stopped=unverifiable"

# ═════ S9: 60 stale links, batch 50 -> at most 50 GETs ═══════════════════════
reset
for i in $(seq 601 660); do
  q "INSERT INTO roadmap_links (idea_id, project, repo, issue, wave_id, created_by, created_at) VALUES (?, 'cromford', ?, ?, 'w1', 'roadmap-file', ?)" "i$i" "$R" "$i" "$NOW" >/dev/null
  gissue "$i" open
done
q "INSERT OR REPLACE INTO settings (key, value, note, actor, updated_at) VALUES ('roadmap.issue_sync_batch', '50', 'fixture', 'test', ?)" "$NOW" >/dev/null
run
eq "S9 exactly 50 GETs (the batch, not the 60 stale)" "$(gets)" 50
eq "S9 written = GETs" "$(sumline | sed -n 's/.* written=\([0-9]*\) .*/\1/p')" "$(gets)"

# ═════ S11: the shim when present, else gh direct ════════════════════════════
reset
link i1 701; gissue 701 open
cat > "$H/bin/gh-rest-shim" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/shim.log"
exec gh "$@"
SH
chmod +x "$H/bin/gh-rest-shim"
run
eq "S11 the GET went through the shim" "$(cnt '^api -i -X GET repos/example-org/cromford/issues/701$' "$T/shim.log")" 1
eq "S11 ... and reached gh once" "$(gets)" 1
eq "S11 written" "$(st i1 701)" open
reset
link i1 702; gissue 702 open
run
eq "S11 no shim: no shim call" "$(cnt . "$T/shim.log")" 0
eq "S11 no shim: gh api direct" "$(cnt '^GET repos/example-org/cromford/issues/702$' "$T/gh.log")" 1

# ═════ lane-off flag -> exit 0, no roadmap request ═══════════════════════════
reset
link i1 801; gissue 801 open
touch "$H/flags/lane-off-roadmap-issue-sync"
LGN=$(( NOW_S - NOW_S % 3600 + 420 ))
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" bash "$H/bin/roadmap-issue-sync.sh" > "$T/out" 2>&1; echo $? > "$T/rc"
rm -f "$H/flags/lane-off-roadmap-issue-sync"
eq "S12b lane off: rc 0" "$(cat "$T/rc")" 0
eq "S12b lane off: no roadmap request" "$(cnt '/api/roadmap/' "$T/reqlog")" 0
eq "S12b lane off: no gh call" "$(cnt . "$T/gh.log")" 0
# The control: the same gated run with no flag does read the links.
env HARNESS_TEST_SANDBOX=1 LANE_GATE_NOW="$LGN" bash "$H/bin/roadmap-issue-sync.sh" > "$T/out" 2>&1
eq "S12b control: no flag, the gated run reads the links" "$(cnt '^GET /api/roadmap/links/stale' "$T/reqlog")" 1

echo "roadmap-issue-sync: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
