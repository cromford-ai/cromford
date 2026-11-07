#!/bin/bash
# tests/lane-wake-gate.bh-9072-test.sh — BH-9072 (BH-9067.0): the lane wake
# gate. bin/lib/lane-wake-gate.sh (lwg_mode, lwg_take, lwg_ring) and its hook
# in lane_gate_or_exit, driven against the REAL worker routes (lane-wakes.js,
# wakes.js, settings.js and pm-groom's own families) over a node:sqlite file
# built from the composed jobs schema. G4, G5 and G11 run the SHIPPED
# bin/pm-groom.sh through the real lane_gate_or_exit.
#
# WHAT IS STUBBED. bin/agent-call.sh (one line per call in $T/agentcalls),
# bin/archie-tg-send.sh and bin/alert-line.sh (ALERTS.log), as in
# tests/pm-groom.bh-7261-test.sh. `curl` sends every request for the fake
# worker to $T/wdrv.mjs, which appends `<METHOD> <path>` to $T/hits; any other
# host (and `gh`) goes to $T/net.log and fails. Nothing reaches a model,
# Telegram, GitHub or a real worker. Both clocks are pinned (LANE_GATE_NOW,
# PM_GROOM_NOW, the worker's FXT_NOW). Each case starts from a fresh database
# copy and an empty state/ and logs/ (reset), and uses its own ids.
#
# Fixture switches under $T: down (curl exits 7 for the worker), take.answer
# (the take route answers this file: line 1 payload, line 2 status).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-wake-gate.bh-9072-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "lane-wake-gate: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
# case_start <name>: a PASS line for the case before it when it added no FAIL.
CASE=""; CASE_FAIL=0
case_end() { [ -z "$CASE" ] || { [ "$FAIL" -eq "$CASE_FAIL" ] && echo "PASS: $CASE" || echo "FAIL-CASE: $CASE"; }; }
case_start() { case_end; CASE="$1"; CASE_FAIL=$FAIL; }

LIB="$DIR/bin/lib/lane-wake-gate.sh"
ROUTES="$DIR/worker/jobs/src/routes/lane-wakes.js"
FRAG="$DIR/worker/jobs/test/route-table.d/bh-9072-lane-wakes.txt"
REGF="$DIR/catalog/lane-wakes.d/pm-groom.json"
KNOBS="$DIR/catalog/lanes.d/_lib.lane-wake-gate.json"
for f in "$LIB" "$ROUTES" "$FRAG" "$REGF" "$KNOBS"; do [ -f "$f" ] && ok || bad "missing $f"; done
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "lane-wake-gate: SKIPPED — node with node:sqlite is not installed on this box"
  echo "lane-wake-gate: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
[ -f "$LIB" ] && [ -f "$ROUTES" ] || { echo "lane-wake-gate: $PASS passed, $FAIL failed"; exit 1; }

NOW=2026-11-09T11:05:00Z           # a Monday, minute 5: no quarter-hour start offset
NOW_S=$(date -u -d "$NOW" +%s)
REPO=example-org/project-3-fixture

# ═════ the fake worker ═══════════════════════════════════════════════════════
cat > "$T/wdrv.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
const W = process.env.LWG_WORKER_DIR;
const { d1 } = await import(`${W}/test/lib/d1-sqlite.bh-1030.js`);
const { matchRoute } = await import(`${W}/src/lib/router.js`);
const routes = [];
for (const f of ['lane-wakes', 'wakes', 'settings', 'roadmap-ideas', 'pm-brief', 'model-routes']) {
  routes.push(...(await import(`${W}/src/routes/${f}.js`)).routes);
}
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
// answer() decides; ONE write at the end, then a normal exit (process.exit
// right after a write cuts a large answer short on a pipe).
async function answer() {
  let raw = '';
  if (bodyFile) { try { raw = readFileSync(bodyFile, 'utf8'); } catch { raw = ''; } }
  const url = new URL('https://jobs.test' + pathq);
  appendFileSync(`${T}/hits`, `${method} ${url.pathname}\n`);
  if (url.pathname === '/api/lane-wakes/take') appendFileSync(`${T}/takes`, raw + '\n');
  if (url.pathname === '/api/lane-wakes/take' && existsSync(`${T}/take.answer`)) {
    const [p, s] = readFileSync(`${T}/take.answer`, 'utf8').split('\n');
    return [Number(s), p];
  }
  let body = null;
  if (raw) { try { body = JSON.parse(raw); } catch { body = null; } }
  const hit = matchRoute(routes, method, url.pathname);
  if (!hit) return [404, JSON.stringify({ error: 'unknown endpoint' })];
  const db = new DatabaseSync(`${T}/d1.sqlite`, { timeout: 10000 });
  const res = await hit.handler({ env: { DB: d1(db) }, url, path: url.pathname, t: process.env.FXT_NOW, body: body || {}, m: hit.m });
  return [res.status, await res.text()];
}
const [code, text] = await answer();
process.stdout.write(text + '\n' + code);
JS
cat > "$T/q.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [sql, ...binds] = process.argv.slice(2);
const st = db.prepare(sql);
if (/^\s*(select|with)|returning/i.test(sql)) console.log(JSON.stringify(st.all(...binds)));
else { st.run(...binds); console.log('[]'); }
JS
cat > "$T/mkdb.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const db = new DatabaseSync(process.argv[2]);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
export FXT="$T" FXT_NOW="$NOW" LWG_WORKER_DIR="$DIR/worker/jobs" NODE_NO_WARNINGS=1
node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err" || { echo "FAIL: the schema does not apply: $(head -3 "$T/mkdb.err")"; exit 1; }
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/bin" "$H/catalog/lane-wakes.d" "$H/prompts/product-stages" "$T/fakebin"
for L in bin/pm-groom.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/lane-wake-gate.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
cp "$DIR/prompts/product-stages/pm-groom.md" "$H/prompts/product-stages/pm-groom.md"
cp "$DIR/catalog/lanes.json" "$H/catalog/"
cp "$REGF" "$H/catalog/lane-wakes.d/"
: > "$H/env/global.env"
printf 'project-3 %s https://project-3.example.com /api/feature-board 0 local\nacme example-org/acme-fixture https://acme.example.com - 0 local\n' "$REPO" > "$T/fleet.conf"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/agentcalls"
printf '%s\n' '{"summary":"Nothing to move.","moves":[]}' > "$5"
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s\n' "$1" >> "$HARNESS/logs/ALERTS.log"
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
exit 0
SH
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
    [ -f "$FXT/down" ] && { printf '%s %s\n' "$method" "${url#"$JOBS_URL"}" >> "$FXT/down.hits"; exit 7; }
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "$FXT/body.XXXXXX")
      case "$data" in @*) cp "${data#@}" "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$FXT/net.log"
exit 7
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh" "$H/bin/archie-tg-send.sh" "$T/fakebin/curl" "$T/fakebin/gh"
: > "$T/net.log"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh9072 \
  FLEET_CONF="$T/fleet.conf" LANE_GATE_NOW="$NOW_S" HARNESS_TEST_SANDBOX=1 JOBS_RETRY_SLEEP=0
unset MODE_DEFAULT MODE_PM_GROOM LWG_TIMEOUT_S LWG_FAIL_LOG_EVERY_S LANE_GATE_DISABLE LANE_REGISTRY 2>/dev/null || true

LOGW="$H/logs/lane-wake-gate.log"
ALF="$H/logs/ALERTS.log"
# reset [mode_pm_groom] [mode_default]: a fresh database, empty state and logs;
# the rows lib.lane-wake-gate.mode_pm_groom / .mode_default when given (an
# empty first argument writes no lane row); the settings cache primed
# through the REAL _lg_settings_refresh, then the hit logs emptied.
reset() {
  local p
  for p in hits takes agentcalls down down.hits take.answer rc out; do scratch_rm "$T/$p" || exit 1; done
  for p in state locks flags products logs; do scratch_rm "$H/$p" || exit 1; done
  mkdir -p "$H/logs" "$H/flags"
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  [ -z "${1:-}" ] || setrow lib.lane-wake-gate.mode_pm_groom "$1"
  [ -z "${2:-}" ] || setrow lib.lane-wake-gate.mode_default "$2"
  prime
}
setrow() { q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'fixture','fixture','2026-11-09T00:00:00Z')" "$1" "$2" >/dev/null; }
prime() {
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; _lg_settings_refresh' >/dev/null 2>&1
  [ -s "$H/state/settings-cache.json" ] || bad "the settings cache was not primed"
  scratch_rm "$T/hits" || exit 1; : > "$T/hits"
}
# take <lane> <scope>: lwg_take in a shell that sourced the gate like a lane does.
take() {
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_take "$@"' _ "$@" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
mode() { bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_mode "$1"' _ "$1" 2>/dev/null; }
ring() { bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; . "$HARNESS/bin/lib/lane-wake-gate.sh"; lwg_ring "$@"' _ "$@" 2>/dev/null; }
# lane [VAR=value...]: one scheduled tick of the REAL bin/pm-groom.sh project-3.
lane() {
  env LANE_SINGLE_RUN=1 PM_GROOM_NOW="$NOW_S" "$@" bash "$H/bin/pm-groom.sh" project-3 > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls() { n "$T/agentcalls"; }
rc()    { cat "$T/rc"; }
lines() { n "$LOGW"; }
last()  { tail -1 "$LOGW" 2>/dev/null | cut -d' ' -f2-; }
wm()    { cat "$H/state/lane-wake-gate/pm-groom.project-3.after" 2>/dev/null; }
setwm() { mkdir -p "$H/state/lane-wake-gate"; printf '%s\n' "$1" > "$H/state/lane-wake-gate/pm-groom.project-3.after"; }
hook()  { local r; r=$(q "INSERT INTO wakes (repo, kind, key, event, minute, at) VALUES (?, ?, ?, ?, ?, '2026-11-09T10:00:00Z') RETURNING id" \
            "$1" "$2" "$3" "${4:-issues}" "${5:-m-$3}"); jq -r '.[0].id' <<<"$r"; }
alerts() { n "$ALF"; }
# idea: one roadmap idea for project-3, so a run that is let through makes its call.
idea()  { q "INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at) VALUES ('project-3-i1','project-3','Idea one','operator','ideas',1,'operator','2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')" >/dev/null; }

case_start G1
# ═════ G1: mode off = rc 0, 0 worker hits, no lwg line ═══════════════════════
reset off; setwm 5
take pm-groom project-3
eq "G1 rc" "$(rc)" 0
eq "G1 0 worker hits ($(cat "$T/hits"))" "$(n "$T/hits")" 0
eq "G1 no lwg line" "$(lines)" 0
eq "G1 watermark same" "$(wm)" 5

case_start G2
# ═════ G2: shadow, nothing new = rc 0, would-skip ════════════════════════════
reset shadow; setwm 5
take pm-groom project-3
eq "G2 rc" "$(rc)" 0
eq "G2 line" "$(last)" "lwg pm-groom project-3 would-skip"
eq "G2 watermark same" "$(wm)" 5
eq "G2 one take, the only hit" "$(cat "$T/hits")" "POST /api/lane-wakes/take"
eq "G2 the take sent the registry kinds and the watermark" \
  "$(jq -c '[.lane, .scope, .kinds, .repo, .after_id]' "$T/takes")" "[\"pm-groom\",\"project-3\",[\"issue\",\"issue_comment\"],\"$REPO\",5]"

case_start G3
# ═════ G3: shadow, one ring = run wake=<id> ══════════════════════════════════
reset shadow; setwm 5
eq "G3 lwg_ring answers inserted=1" "$(ring pm-groom project-3 cal:2026-11-09T11)" inserted=1
eq "G3 a replayed ring answers inserted=0" "$(ring pm-groom project-3 cal:2026-11-09T11)" inserted=0
RID=$(q "SELECT id FROM wakes WHERE repo='harness/lanes' AND key='pm-groom:project-3'" | jq -r '.[0].id')
take pm-groom project-3
eq "G3 rc" "$(rc)" 0
eq "G3 line" "$(last)" "lwg pm-groom project-3 run wake=$RID"
eq "G3 the ring is acked" "$(q "SELECT acked_at FROM wakes WHERE id=?" "$RID" | jq -r '.[0].acked_at')" "$NOW"

case_start G4
# ═════ G4: on, nothing new, REAL pm-groom = rc 0, skip, the body never runs ══
reset on; setwm 5; idea
lane
eq "G4 lane rc 0 (a gated tick is not a failure) ($(head -3 "$T/out"))" "$(rc)" 0
eq "G4 line" "$(last)" "lwg pm-groom project-3 skip"
eq "G4 0 agent calls" "$(calls)" 0
eq "G4 the only worker hit is the take" "$(cat "$T/hits")" "POST /api/lane-wakes/take"
take pm-groom project-3
eq "G4 lwg_take itself answers rc 3 on a skip" "$(rc)" 3

case_start G5
# ═════ G5: REAL pm-groom, mode on: a ring = 1 call; the next tick = 0 calls ══
reset on; setwm 5; idea
eq "G5 the ring is stored" "$(ring pm-groom project-3 cal:2026-11-09T11)" inserted=1
RID=$(q "SELECT id FROM wakes WHERE repo='harness/lanes' AND minute='lw:cal:2026-11-09t11'" | jq -r '.[0].id')
scratch_rm "$T/hits" || exit 1; : > "$T/hits"
lane
eq "G5 tick 1 rc ($(head -3 "$T/out"))" "$(rc)" 0
eq "G5 tick 1 line" "$(last)" "lwg pm-groom project-3 run wake=$RID"
eq "G5 tick 1 exactly 1 agent call" "$(calls)" 1
eq "G5 tick 1 starts with the take" "$(head -1 "$T/hits")" "POST /api/lane-wakes/take"
scratch_rm "$T/hits" || exit 1; : > "$T/hits"
lane
eq "G5 tick 2 rc" "$(rc)" 0
eq "G5 tick 2 line" "$(last)" "lwg pm-groom project-3 skip"
eq "G5 tick 2 adds 0 agent calls" "$(calls)" 1
eq "G5 tick 2 the hit log holds only the take" "$(cat "$T/hits")" "POST /api/lane-wakes/take"
eq "G5 0 ALERTS lines" "$(alerts)" 0

case_start G6
# ═════ G6: on, a newer issue webhook = run webhook=<id>, watermark moves ═════
reset on
B0=$(hook "$REPO" issue 1); setwm "$B0"
WID=$(hook "$REPO" issue 2)
take pm-groom project-3
eq "G6 rc" "$(rc)" 0
eq "G6 line" "$(last)" "lwg pm-groom project-3 run webhook=$WID"
eq "G6 watermark = that id" "$(wm)" "$WID"
take pm-groom project-3
eq "G6 the next take reads the watermark back: skip" "$(rc)/$(last)" "3/lwg pm-groom project-3 skip"

case_start G7
# ═════ G7: near misses, each alone, mode on: rc 3, skip ══════════════════════
g7() { # g7 <name> <setup command...>
  local name="$1"; shift
  reset on
  B0=$(hook "$REPO" issue 1); setwm "$B0"
  "$@"
  take pm-groom project-3
  eq "G7 $name rc" "$(rc)" 3
  eq "G7 $name line" "$(last)" "lwg pm-groom project-3 skip"
  eq "G7 $name watermark same" "$(wm)" "$B0"
}
g7_pr()      { hook "$REPO" pr 7 >/dev/null; }
g7_repo()    { hook example-org/other-fixture issue 7 >/dev/null; }
g7_equal()   { :; }    # the only issue row has id = the watermark
g7_scope()   { ring pm-groom other cal:1 >/dev/null; }
g7_scope_after() {
  eq "G7 the scope-other ring is still unacked" \
    "$(q "SELECT COUNT(*) AS n FROM wakes WHERE key='pm-groom:other' AND acked_at IS NULL" | jq -r '.[0].n')" 1
}
g7_lead()    { hook harness/lanes lead-review pm-groom:project-3 lane:lead-review lane:1 >/dev/null; }
g7_nudge()   { hook "$REPO" issue 7 nudge:untriaged nudge:7 >/dev/null; }
g7 "a pr webhook for the repo" g7_pr
g7 "an issue webhook for another repo" g7_repo
g7 "an issue row with id equal to the watermark" g7_equal
g7 "a ring for scope other" g7_scope; g7_scope_after
g7 "a lead-review row keyed pm-groom:project-3" g7_lead
g7 "a nudge: row for the repo" g7_nudge

case_start G8
# ═════ G8: the worker does not answer = rc 0, one throttled line, 0 ALERTS ═══
reset on; setwm 5; : > "$T/down"
take pm-groom project-3
eq "G8 rc" "$(rc)" 0
eq "G8 line" "$(last)" "lwg pm-groom project-3 fail-open (no-answer)"
eq "G8 one try, no retry" "$(n "$T/down.hits")" 1
take pm-groom project-3
eq "G8 a 2nd failing tick in the window writes no 2nd line" "$(lines)" 1
eq "G8 0 ALERTS lines" "$(alerts)" 0
eq "G8 watermark same" "$(wm)" 5
LANE_GATE_NOW=$((NOW_S + 3600)) take pm-groom project-3
eq "G8 after LWG_FAIL_LOG_EVERY_S the line comes again" "$(lines)" 2

case_start G9
# ═════ G9: 500, a taken that is not an array, non-JSON = fail-open (bad-answer)
for ans in '{"error":"fixture"}|500' '{"taken":"7","webhook_max_id":null}|200' 'not json|200' '{"taken":[],"webhook_max_id":"9"}|200'; do
  reset on; setwm 5
  printf '%s\n%s\n' "${ans%|*}" "${ans##*|}" > "$T/take.answer"
  take pm-groom project-3
  eq "G9 [$ans] rc" "$(rc)" 0
  eq "G9 [$ans] line" "$(last)" "lwg pm-groom project-3 fail-open (bad-answer)"
  eq "G9 [$ans] watermark same" "$(wm)" 5
done

case_start G10
# ═════ G10: jq not on PATH = fail-open (no-jq), 0 worker hits ════════════════
reset on; setwm 5
mkdir -p "$T/nojq"
for b in bash cat tr date mkdir mktemp rm mv printf dirname head grep sed awk; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$T/nojq/$b"
done
ln -sf "$T/fakebin/curl" "$T/nojq/curl"
PATH="$T/nojq" take pm-groom project-3
eq "G10 rc" "$(rc)" 0
eq "G10 line" "$(last)" "lwg pm-groom project-3 fail-open (no-jq)"
eq "G10 0 take hits" "$(grep -c lane-wakes "$T/hits")" 0

case_start G11
# ═════ G11: no registry file, or a helper call = no take, the lane runs ══════
reset on; setwm 5
bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/lane-gate.sh"; LANE_SINGLE_RUN=1 lane_gate_or_exit pm-ideas project-3; echo gate-passed' > "$T/out" 2>&1
eq "G11 a lane with no registry file passes the gate" "$(tail -1 "$T/out")" gate-passed
eq "G11 no take for it" "$(grep -c lane-wakes "$T/hits")" 0
eq "G11 no lwg line" "$(lines)" 0
reset on; setwm 5; idea
lane LANE_SINGLE_RUN=0
eq "G11 pm-groom as a helper call (LANE_SINGLE_RUN=0): 0 take hits" "$(grep -c lane-wakes "$T/hits")" 0
eq "G11 pm-groom as a helper call: the lane ran its call" "$(calls)" 1
eq "G11 pm-groom as a helper call: no lwg line" "$(lines)" 0

case_start G12
# ═════ G12: no watermark file: run first, then pending, then the normal table
reset on
H1=$(hook "$REPO" issue 1); H2=$(hook "$REPO" issue 2)
take pm-groom project-3
eq "G12 tick 1 rc" "$(rc)" 0
eq "G12 tick 1 line" "$(last)" "lwg pm-groom project-3 run first"
eq "G12 tick 1 sent no kinds (rings only)" "$(jq -c '[.kinds, has("repo"), has("after_id")]' <<<"$(tail -1 "$T/takes")")" '[[],false,false]'
eq "G12 tick 1 watermark" "$(wm)" pending
take pm-groom project-3
eq "G12 tick 2 sent the kinds with after_id 0" "$(jq -c '[.kinds, .after_id]' <<<"$(tail -1 "$T/takes")")" '[["issue","issue_comment"],0]'
eq "G12 tick 2 watermark = the history max" "$(wm)" "$H2"
eq "G12 tick 2 history never starts a run: skip" "$(rc)/$(last)" "3/lwg pm-groom project-3 skip"
H3=$(hook "$REPO" issue 3)
take pm-groom project-3
eq "G12 tick 3 the normal table: run webhook" "$(rc)/$(last)" "0/lwg pm-groom project-3 run webhook=$H3"
reset on; setwm pending
take pm-groom project-3
eq "G12 pending with no webhook row: watermark 0" "$(wm)" 0

case_start G13
# ═════ G13: a bad mode word is ignored ═══════════════════════════════════════
for w in ON maybe; do
  reset "$w"; setwm 5
  eq "G13 mode_pm_groom=$w falls to the registry default" "$(mode pm-groom)" shadow
  take pm-groom project-3
  eq "G13 mode_pm_groom=$w acts as shadow" "$(rc)/$(last)" "0/lwg pm-groom project-3 would-skip"
  check_bad=$(grep -c "bad-mode lib.lane-wake-gate.mode_pm_groom=$w ignored" "$LOGW")
  eq "G13 mode_pm_groom=$w is named once" "$check_bad" 1
done

case_start G14
# ═════ G14: inherited state: mode_default and no rows at all ═════════════════
reset "" off
eq "G14 no lane row, mode_default=off: off" "$(mode pm-groom)" off
setwm 5; take pm-groom project-3
eq "G14 off: no take" "$(grep -c lane-wakes "$T/hits")/$(lines)" "0/0"
reset
eq "G14 no rows at all: shadow" "$(mode pm-groom)" shadow
eq "G14 a lane with no MODE_ knob and no rows: off" "$(mode pm-ideas)" off
# The mode knob is the registry file's mode_knob, not a name built from the lane.
printf '{"lane":"pm-ideas","scope":"project","kinds":["issue"],"mode_knob":"MODE_PM_GROOM"}\n' > "$H/catalog/lane-wakes.d/pm-ideas.json"
eq "G14 mode_knob names the knob: pm-ideas reads MODE_PM_GROOM's default" "$(mode pm-ideas)" shadow
printf '{"lane":"pm-ideas","scope":"project","kinds":["issue"],"mode_knob":"MODE_pm;x"}\n' > "$H/catalog/lane-wakes.d/pm-ideas.json"
eq "G14 a bad mode_knob falls to MODE_PM_IDEAS (none): off" "$(mode pm-ideas)" off
rm -f "$H/catalog/lane-wakes.d/pm-ideas.json"
setwm 5; idea; lane MODE_DEFAULT=on MODE_PM_GROOM=on
eq "G14 the env is never read for the mode: shadow, the lane still runs its call" "$(last)/$(calls)" "lwg pm-groom project-3 would-skip/1"
reset on off
eq "G14 a lane row wins over mode_default" "$(mode pm-groom)" on

case_start "0 network"
eq "the fake curl reached no other host ($(head -3 "$T/net.log"))" "$(n "$T/net.log")" 0
case_end
echo "lane-wake-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
