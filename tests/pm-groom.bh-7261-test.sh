#!/bin/bash
# tests/pm-groom.bh-7261-test.sh — BH-7261 (BH-7244.3): the PM agent's weekly
# grooming brief. Drives the SHIPPED bin/pm-groom.sh against the REAL worker
# routes (settings.js, roadmap-ideas.js, pm-brief.js, model-routes.js) over a
# node:sqlite file built from the composed jobs schema.
# tests/lib/pm-groom.bh-7261.mjs is that worker; it logs every request in
# $T/reqlog and every step in $T/order.
#
# WHAT IS STUBBED. bin/agent-call.sh (it logs its argv and env, copies the
# prompt and answers the file $PG_ANSWER, with rc $T/ac.rc) and
# bin/archie-tg-send.sh (it logs the akey and the text, rc $T/tg.rc) and
# bin/alert-line.sh (it appends its text to logs/ALERTS.log). `gh` on
# PATH and every curl to a host that is not the fake worker count into
# $T/net.log. Nothing here reaches a model, Telegram, GitHub or the real worker.
# The lane clock (PM_GROOM_NOW) and the worker clock are pinned (D60). Each case
# uses its own project name and a fresh database.
#
# G1-G12: the plan's acceptance tests (plan.md "## Acceptance tests"). G13-G17:
# the other exit paths (off flags, --force, a failed call, a failed create, a
# failed read, a malformed answer). Then the node suites of this ticket:
# worker/jobs/test/pm-briefs.bh-7261.test.js and
# console-ui/tests/roadmap-brief.bh-7261.test.js.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pm-groom.bh-7261-test.sh
# Rewrite the W7 fixture from G1: PG_WRITE_FIXTURE=1 (then review the diff).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "pm-groom: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/pm-groom.sh"
PROMPT_MD="$DIR/prompts/product-stages/pm-groom.md"
WDRV="$DIR/tests/lib/pm-groom.bh-7261.mjs"
ROUTES="$DIR/worker/jobs/src/routes/pm-brief.js"
FRAG="$DIR/worker/jobs/schema.d/202610291810-bh-7261-pm-briefs.sql"
REG="$DIR/catalog/lanes.d/pm-groom.json"
SITE="$DIR/catalog/llm-sites.d/7261-pm-groom.json"
CRON="$DIR/cron/lanes/737-pm-groom.cron"
W7FX="$DIR/worker/jobs/test/fixtures/pm-brief-create.bh-7261.json"
# The console half (D41: every new source is named here).
CON_VIEW="$DIR/console-ui/src/screens/roadmap/brief-view.js"
CON_API="$DIR/console-ui/src/lib/roadmap-api/pm-brief.js"
CON_FRAG="$DIR/console-ui/functions/_lib/coord-writes.d/7261-pm-brief.js"
RET_FRAG="$DIR/worker/jobs/src/routes/retention.d/bh-7261-pm-briefs.js"
for f in "$LANE" "$PROMPT_MD" "$WDRV" "$ROUTES" "$FRAG" "$REG" "$SITE" "$CRON" "$CON_VIEW" "$CON_API" "$CON_FRAG" "$RET_FRAG"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "T1 the prompt states the evidence rule" '[ "$(grep -c evidence "$PROMPT_MD" 2>/dev/null)" -ge 1 ]'
check "M1 no hardcoded model string in the lane or the prompt" '! grep -nE "claude-(opus|sonnet|haiku|fable)|gpt-[0-9]|grok-[0-9]" "$LANE" "$PROMPT_MD"'
check "R1 registry: project lane, flag lane-off-pm-groom, cost stage pm, the 8 run-product boxes" \
  '[ "$(jq -r "[.scope, .switch.name, (.stats.cost_stage | tostring), .script, (.boxes | sort | join(\",\"))] | @tsv" "$REG" 2>/dev/null)" = "$(printf "project\tlane-off-pm-groom\tpm\tbin/pm-groom.sh\tproject-4,project-6-os,project-1,project-3,project-9,small,project-2,project-5")" ]'
check "R2 llm-site: through agent-call, stage pm, role product.pm marker found in the lane" \
  'm=$(jq -r ".[0].marker" "$SITE" 2>/dev/null); [ "$(jq -r ".[0] | [.kind, .stage, .through_agent_call] | @tsv" "$SITE")" = "$(printf "agent-call\tpm\ttrue")" ] && grep -qF "$m" "$LANE"'
for pair in "project-4 8 project-4" "project-1 2 project-1" "project-2 4 project-2" "project-3 6 project-3" "project-9 5 project-9" \
  "project-5 9 project-5" "small 1 project-8" "project-6-os 1 project-6-os"; do
  read -r cbox cmin cproj <<<"$pair"
  # The expected cron line goes in a variable, not in the eval'd text: a literal
  # `>> /root/...` inside an eval argument is a trace-safety HIT (BH-7261 fix).
  cwant="$cmin 11 * * 1 /root/harness/bin/pm-groom.sh $cproj >> /root/harness/logs/pm-groom.log 2>&1"
  check "C1 cron: $cbox runs $cproj at minute $cmin past 11 on Monday" \
    'awk -v b="$cbox" "/^# @box /{s=\$3; next} s==b" "$CRON" | grep -qxF "$cwant"'
done
check "G12 the lane never names a drafting, posting, build or GitHub path" \
  '! grep -vE "^[[:space:]]*#" "$LANE" | grep -nE "post-proposal|run-build|draft-proposal|gh-rest|(^|[^_a-z-])gh |curl "'

if [ ! -f "$LANE" ] || [ ! -f "$ROUTES" ]; then
  echo "pm-groom: $PASS passed, $FAIL failed"; exit 1
fi
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "pm-groom: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "pm-groom: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-19T11:05:00Z
NOW_S=$(date -u -d "$NOW" +%s)
WEEK=2026-W43
DAY=86400
iso_ago() { date -u -d "@$((NOW_S - $1))" +%Y-%m-%dT%H:%M:%SZ; }

cat > "$T/q.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [sql, ...binds] = process.argv.slice(2);
const st = db.prepare(sql);
if (/^\s*(select|with)/i.test(sql)) console.log(JSON.stringify(st.all(...binds)));
else { st.run(...binds); console.log('[]'); }
JS
cat > "$T/mkdb.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const db = new DatabaseSync(process.argv[2]);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
export FXT="$T" FXT_NOW="$NOW" PG_WORKER_DIR="$DIR/worker/jobs" NODE_NO_WARNINGS=1
node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err" || { echo "FAIL: the schema does not apply: $(head -3 "$T/mkdb.err")"; exit 1; }
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/flags" "$H/bin" "$H/prompts/product-stages" "$T/fakebin"
for L in bin/pm-groom.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
cp "$PROMPT_MD" "$H/prompts/product-stages/pm-groom.md"
mkdir -p "$H/catalog"; cp "$DIR/catalog/lanes.json" "$H/catalog/"
: > "$H/env/global.env"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv | lane | role | fp | no-tools
printf '%s|%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_ROLE:-}" "${AGENT_CALL_FP:-}" "${AGENT_CALL_NO_TOOLS:-}" >> "$FXT/agentcalls"
echo agent-call >> "$FXT/order"
n=$(grep -c . "$FXT/agentcalls")
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
cat "${PG_ANSWER:-/dev/null}" > "$5"
SH
# The ALERTS seam: the line lands in logs/ALERTS.log with no beat and no request.
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s %s\n' "$(date -u '+%F %TZ')" "$1" >> "$HARNESS/logs/ALERTS.log"
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
echo tg >> "$FXT/order"
printf '%s\n' "$1" >> "$FXT/tg.akeys"
printf '%s\n' "$2" > "$FXT/tg.text"
exit "$(cat "$FXT/tg.rc" 2>/dev/null || echo 0)"
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
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "$FXT/body.XXXXXX")
      case "$data" in @*) cp "${data#@}" "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    nt=$(mktemp -d "$FXT/nodetmp.XXXXXX")
    TMPDIR="$nt" node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; rm -rf "$nt"; exit "$rc" ;;
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
cp "$WDRV" "$T/wdrv.mjs"
: > "$T/net.log"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh7261 JOBS_RETRIES=0
unset PM_MODEL PM_GROOM_TIMEOUT_S CONSOLE_PAGES_URL 2>/dev/null || true

reset() {
  local p
  for p in reqlog order agentcalls out rc ac.rc tg.rc tg.akeys tg.text; do scratch_rm "$T/$p" || exit 1; done
  rm -f "$T"/prompt.* "$T"/fail.*
  for p in state locks flags products; do scratch_rm "$H/$p" || exit 1; done
  rm -f "$H/logs/"*
  mkdir -p "$H/flags"
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"; : > "$T/order"
}
# run [VAR=value...] -- <args>: one run of the lane.
run() {
  local -a e=() a=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; a=("$@"); break ;; *) e+=("$1"); shift ;; esac
  done
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 PM_GROOM_NOW="$NOW_S" "${e[@]}" bash "$H/bin/pm-groom.sh" "${a[@]}" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()      { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls()  { n "$T/agentcalls"; }
req()    { local c; c=$(grep -cE "$1" "$T/reqlog" 2>/dev/null); printf '%s' "${c:-0}"; }
LOGF="$H/logs/pm-groom.log"
ALF="$H/logs/ALERTS.log"
lastlog() { grep -E ' week=' "$LOGF" 2>/dev/null | tail -1; }
logf()   { lastlog | grep -oE "(^| )$1=[^ ]+" | cut -d= -f2; }
alerts() { local c; c=$(grep -c 'pm-groom' "$ALF" 2>/dev/null); printf '%s' "${c:-0}"; }
brief()  { q "SELECT * FROM pm_briefs WHERE project=?" "$1" | jq -c '.[0] // {}'; }
bf()     { brief "$1" | jq -r --arg f "$2" '.[$f] // "null" | tostring'; }
body()   { brief "$1" | jq -c '(.body // "null") | fromjson'; }
moves()  { q "SELECT * FROM pm_moves WHERE project=? ORDER BY id" "$1"; }
nbriefs() { q "SELECT COUNT(*) AS n FROM pm_briefs WHERE project=?" "$1" | jq -r '.[0].n'; }
# idea <project> <id> <lane> <age-seconds> [updated_at override]
idea() {
  local ua="${5:-$(iso_ago "$4")}"
  q "INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at) VALUES (?, ?, ?, 'operator', ?, 1, 'operator', '2026-01-01T00:00:00Z', ?)" \
    "$2" "$1" "Idea $2" "$3" "$ua" >/dev/null
}
# five <project>: the 5 ideas of G1 at 0, 10, 29, 30 and 31 days.
five() {
  idea "$1" "$1-d0" ideas 0; idea "$1" "$1-d10" next $((10 * DAY)); idea "$1" "$1-d29" ideas $((29 * DAY))
  idea "$1" "$1-d30" ideas $((30 * DAY)); idea "$1" "$1-d31" next $((31 * DAY))
}
# signals <project>: two cycle dirs; the newer one has signal.new-ok (ok) and
# signal.nc (not-configured); the older one has signal.old-ok.
signals() {
  mkdir -p "$H/products/$1/2026-10-12" "$H/products/$1/2026-10-19"
  jq -n '{snapshot_hash:"hash-old", generated_at:"2026-10-12T09:01:00Z", evidence:[{id:"signal.old-ok", source:"qa", metric:"open_findings", value:3, window:"7d", link:"", status:"ok"}]}' \
    > "$H/products/$1/2026-10-12/data-signals.json"
  jq -n '{snapshot_hash:"hash-new-fixture", generated_at:"2026-10-19T09:01:00Z", evidence:[
      {id:"signal.new-ok", source:"board", metric:"open_tickets", value:12, window:"7d", link:"https://example.com/board", status:"ok"},
      {id:"signal.nc", source:"analytics", metric:"dau", value:null, window:"", link:"", status:"not-configured"}]}' \
    > "$H/products/$1/2026-10-19/data-signals.json"
}
answer() { printf '%s\n' "$1" > "$T/answer.json"; export PG_ANSWER="$T/answer.json"; }
mv1() { jq -nc --arg i "$1" --arg f "$2" --arg t "$3" --argjson e "$4" '{idea_id:$i, from_col:$f, to_col:$t, reason:"fixture reason", evidence:$e}'; }

# ═════ G1: 5 ideas, 2 stale; 1 brief, 1 call, Telegram sent ═════════════════
reset; P=pg1; five $P; signals $P
answer "$(jq -nc --argjson m "[$(mv1 $P-d30 ideas next '["signal.new-ok","stale.pg1-d30"]'),$(mv1 $P-d31 next discarded '["stale.pg1-d31"]')]" \
  '{summary:"Two ideas are stale. Move the 30-day idea up.", scores:[{idea_id:"pg1-d0", score:80, why:"fresh"}], moves:$m, now:[], next_wave:["pg1-d30","pg1-d0"]}')"
run -- $P
eq "G1 rc 0 ($(cat "$T/out"))" "$(cat "$T/rc")" 0
eq "G1 one brief row" "$(nbriefs $P)" 1
eq "G1 the brief is ready" "$(bf $P status)" ready
eq "G1 stale is exactly the 31 d and 30 d ideas, oldest first" "$(body $P | jq -c '[.stale[].idea_id]')" '["pg1-d31","pg1-d30"]'
eq "G1 stale ages" "$(body $P | jq -c '[.stale[].age_days]')" '[31,30]'
eq "G1 two moves stored" "$(moves $P | jq 'length')" 2
eq "G1 one agent call" "$(calls)" 1
check "G1 agent-call: stage pm, project, lane pm-groom, role product.pm, fp, no tools ($(head -1 "$T/agentcalls"))" \
  'grep -qE "^pm pg1 [^ ]+ 300 [^ ]+ @[^ ]+\|pm-groom\|product.pm\|pm-groom:pg1:$WEEK\|1$" "$T/agentcalls"'
check "G1 the prompt holds both stale ids" 'grep -qF "\"idea_id\":\"pg1-d31\"" "$T/prompt.1" && grep -qF "\"idea_id\":\"pg1-d30\"" "$T/prompt.1"'
check "G1 the prompt holds the newest evidence id and the stale evidence ids" 'grep -qF "signal.new-ok" "$T/prompt.1" && grep -qF "stale.pg1-d30" "$T/prompt.1"'
check "G1 the prompt holds no older-cycle or not-configured id" '! grep -qE "signal\.old-ok|signal\.nc" "$T/prompt.1"'
check "G1 both lane reads went to the worker" \
  '[ "$(req "^GET /api/roadmap/ideas\?project=pg1&lane=ideas&limit=1000$")" = 1 ] && [ "$(req "^GET /api/roadmap/ideas\?project=pg1&lane=next&limit=1000$")" = 1 ]'
eq "G1 tg=sent in the log ($(lastlog))" "$(logf tg)" sent
eq "G1 sent_tg=1" "$(bf $P sent_tg)" 1
eq "G1 sent_mc=1" "$(bf $P sent_mc)" 1
eq "G1 log counts" "$(lastlog | grep -oE 'ideas=[0-9]+ stale=[0-9]+ moves=[0-9]+ dropped=[0-9]+ now=[0-9]+ call=[01]')" "ideas=5 stale=2 moves=2 dropped=0 now=0 call=1"
eq "G1 the akey" "$(cat "$T/tg.akeys")" "pm-brief:pg1:$WEEK"
M0=$(moves $P | jq -r '.[0].id')
check "G1 the Telegram text links each move on Mission Control" \
  'grep -qF "https://console.example.pages.dev/roadmap/pg1?view=brief&week=$WEEK&move=$M0" "$T/tg.text" && grep -qF "Brief: https://console.example.pages.dev/roadmap/pg1?view=brief&week=$WEEK" "$T/tg.text"'
check "G1 the Telegram text carries the summary and the stale count" 'grep -qF "Two ideas are stale." "$T/tg.text" && grep -qF "2 stale idea(s)." "$T/tg.text"'
eq "G1 the step order" "$(grep -E '^(jobs POST /api/pm/briefs(/claim|/sent)?|agent-call|tg)$' "$T/order" | tr '\n' ' ')" \
  "jobs POST /api/pm/briefs/claim agent-call jobs POST /api/pm/briefs tg jobs POST /api/pm/briefs/sent "
# The create payload the lane sent is the W7 fixture of the node suite.
CREATE=$(grep -E '^POST /api/pm/briefs \{' "$T/reqlog" | head -1 | cut -d' ' -f3-)
if [ "${PG_WRITE_FIXTURE:-}" = 1 ]; then
  jq '{week, body, moves}' <<<"$CREATE" > "$W7FX"; echo "pm-groom: wrote $W7FX"
fi
# Field by field: the week, the moves, and every body field the fixture holds.
check "G1 the create payload matches the W7 fixture (rewrite: PG_WRITE_FIXTURE=1)" \
  '[ -f "$W7FX" ] && jq -e --slurpfile f "$W7FX" ". as \$c | (\$f[0].week == .week) and (\$f[0].moves == .moves)
     and (\$f[0].body | to_entries | all(.value == \$c.body[.key]))" <<<"$CREATE" >/dev/null'

# ═════ G2: the boundary at pm.stale_days 30 ══════════════════════════════════
reset; P=pg2
idea $P $P-29d23h ideas $((29 * DAY + 23 * 3600)); idea $P $P-29 ideas $((29 * DAY))
idea $P $P-30 ideas $((30 * DAY)); idea $P $P-31 next $((31 * DAY))
answer '{"summary":"Nothing to move.","moves":[]}'
run -- $P
eq "G2 rc 0" "$(cat "$T/rc")" 0
eq "G2 29 d 23 h and 29 d are not stale; 30 d and 31 d are" "$(body $P | jq -c '[.stale[].idea_id] | sort')" '["pg2-30","pg2-31"]'

# ═════ G3: pm.stale_days 7; a .123Z time parses; a bad one is not stale ═════
reset; P=pg3; five $P
idea $P $P-frac ideas 0 "$(date -u -d "@$((NOW_S - 8 * DAY))" +%Y-%m-%dT%H:%M:%S).123Z"
idea $P $P-bad ideas 0 "not-a-date"
q "UPDATE settings SET value='7' WHERE key='pm.stale_days'" >/dev/null
answer '{"summary":"Seven-day window.","moves":[]}'
run -- $P
eq "G3 rc 0" "$(cat "$T/rc")" 0
eq "G3 the 7 d window gives 10, 29, 30, 31 d and the .123Z idea" "$(body $P | jq -c '[.stale[].idea_id] | sort')" \
  '["pg3-d10","pg3-d29","pg3-d30","pg3-d31","pg3-frac"]'
eq "G3 one warn line for the unparsable updated_at" "$(grep -c 'warn: idea pg3-bad has an updated_at that does not parse' "$LOGF")" 1
reset; P=pg3b; five $P
q "UPDATE settings SET value='abc' WHERE key='pm.stale_days'" >/dev/null
answer '{"summary":"Bad knob.","moves":[]}'
run -- $P
eq "G3b a value that is not an integer: 30 d window" "$(body $P | jq -c '[.stale[].idea_id] | sort')" '["pg3b-d30","pg3b-d31"]'
eq "G3b one warn line" "$(grep -c 'warn: pm.stale_days=abc' "$LOGF")" 1
reset; P=pg3c; five $P
q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('pm.backlog_limit','3','','test','2026-10-20T00:00:00Z')" >/dev/null
answer '{"summary":"Small reads.","moves":[]}'
run -- $P
check "G3c pm.backlog_limit 3 is the limit of both lane reads" \
  '[ "$(req "^GET /api/roadmap/ideas\?project=pg3c&lane=ideas&limit=3$")" = 1 ] && [ "$(req "^GET /api/roadmap/ideas\?project=pg3c&lane=next&limit=3$")" = 1 ]'

# ═════ G4: invalid moves are dropped ═════════════════════════════════════════
reset; P=pg4; five $P; signals $P
answer "$(jq -nc --argjson m "[
  $(mv1 pg4-nope ideas next '["signal.new-ok"]'),
  $(mv1 pg4-d0 next discarded '["signal.new-ok"]'),
  $(mv1 pg4-d0 ideas ideas '["signal.new-ok"]'),
  $(mv1 pg4-d29 ideas shipped '["signal.new-ok"]'),
  $(mv1 pg4-d29 ideas next '["signal.nc"]'),
  $(mv1 pg4-d30 ideas next '[]'),
  $(mv1 pg4-d30 ideas next '["signal.old-ok","made-up"]')]" '{summary:"All bad.", moves:$m}')"
run -- $P
eq "G4 rc 0" "$(cat "$T/rc")" 0
eq "G4 dropped=7 in the log ($(lastlog))" "$(logf dropped)" 7
eq "G4 no move stored" "$(moves $P | jq 'length')" 0
eq "G4 one log line per dropped move" "$(grep -c 'dropped a move:' "$LOGF")" 7
check "G4 the reasons name the cause" 'grep -q "pg4-nope is not in the backlog" "$LOGF" && grep -q "pg4-d0 is in ideas, not next" "$LOGF" && grep -q "to_col shipped" "$LOGF" && grep -q "pg4-d29 cites no evidence id" "$LOGF"'

# ═════ G5: a Now proposal is text in the body, never a move row ═════════════
reset; P=pg5; five $P; signals $P
answer "$(jq -nc --argjson m "[$(mv1 pg5-d29 ideas now '["signal.new-ok"]')]" \
  '{summary:"Start one now.", moves:$m, now:[{idea_id:"pg5-d10", reason:"blocks the launch", evidence:["signal.new-ok","signal.nc"]}]}')"
run -- $P
eq "G5 rc 0" "$(cat "$T/rc")" 0
eq "G5 body.now holds both proposals" "$(body $P | jq -c '[.now[].idea_id] | sort')" '["pg5-d10","pg5-d29"]'
eq "G5 a now entry cites only listed evidence" "$(body $P | jq -c '.now[] | select(.idea_id == "pg5-d10") | .evidence')" '["signal.new-ok"]'
eq "G5 no move row" "$(moves $P | jq 'length')" 0
eq "G5 no row goes to now" "$(q "SELECT COUNT(*) AS n FROM pm_moves WHERE to_col='now'" | jq -r '.[0].n')" 0
check "G5 the Telegram text lists the Now proposals" 'grep -qF "Now proposals:" "$T/tg.text" && grep -qF "Idea pg5-d10: blocks the launch" "$T/tg.text"'

# ═════ G6: the same week twice: 1 row, 1 call ════════════════════════════════
reset; P=pg6; five $P
answer "$(jq -nc --argjson m "[$(mv1 pg6-d30 ideas next '["stale.pg6-d30"]')]" '{summary:"Once.", moves:$m}')"
run -- $P
run -- $P
eq "G6 rc 0" "$(cat "$T/rc")" 0
eq "G6 one brief row" "$(nbriefs $P)" 1
eq "G6 one agent call over two runs" "$(calls)" 1
check "G6 the second run logs already billed" 'grep -q "already billed for $WEEK" "$LOGF"'
eq "G6 the second run made no call" "$(logf call)" 0

# ═════ G7: no model route: rc 75, 0 calls, 0 claims ══════════════════════════
reset; P=pg7; five $P
q "DELETE FROM model_routes WHERE role='product.pm'" >/dev/null
run -- $P
eq "G7 rc 75" "$(cat "$T/rc")" 75
eq "G7 no agent call" "$(calls)" 0
eq "G7 no claim" "$(req '^POST /api/pm/briefs/claim')" 0
eq "G7 no backlog read" "$(req '^GET /api/roadmap/ideas')" 0
eq "G7 no brief row" "$(nbriefs $P)" 0

# ═════ G8: no data-signals.json: stale evidence only ═════════════════════════
reset; P=pg8; five $P
answer "$(jq -nc --argjson m "[$(mv1 pg8-d31 next discarded '["signal.new-ok","stale.pg8-d31"]')]" '{summary:"No signals.", moves:$m}')"
run -- $P
eq "G8 rc 0" "$(cat "$T/rc")" 0
eq "G8 the brief is ready" "$(bf $P status)" ready
eq "G8 the move cites only stale.* ids" "$(moves $P | jq -c '[.[].evidence | fromjson | .[]]')" '["stale.pg8-d31"]'
check "G8 one log line names the missing file" 'grep -q "no data-signals.json for pg8" "$LOGF"'
eq "G8 snapshot_hash is null" "$(body $P | jq -c '.snapshot_hash')" null

# ═════ G9: Telegram fails: sent_tg=0, brief readable; G10: the rerun sends ════
reset; P=pg9; five $P
answer "$(jq -nc --argjson m "[$(mv1 pg9-d30 ideas next '["stale.pg9-d30"]')]" '{summary:"Send fails.", moves:$m}')"
echo 1 > "$T/tg.rc"
run -- $P
eq "G9 rc 0" "$(cat "$T/rc")" 0
eq "G9 sent_tg=0" "$(bf $P sent_tg)" 0
eq "G9 no /sent POST" "$(req '^POST /api/pm/briefs/sent')" 0
eq "G9 exactly one ALERTS line" "$(alerts)" 1
eq "G9 tg=failed in the log" "$(logf tg)" failed
eq "G9 the step order: claim, call, create, tg" "$(grep -E '^(jobs POST /api/pm/briefs(/claim|/sent)?|agent-call|tg)$' "$T/order" | tr '\n' ' ')" \
  "jobs POST /api/pm/briefs/claim agent-call jobs POST /api/pm/briefs tg "
G9GET=$(node "$T/wdrv.mjs" GET "/api/pm/briefs?project=$P&week=$WEEK" | head -1)
eq "G9 the brief GET answers ready" "$(jq -r '.brief.status' <<<"$G9GET")" ready
eq "G9 the brief GET has its move" "$(jq -r '.moves | length' <<<"$G9GET")" 1
echo 0 > "$T/tg.rc"
run -- $P
eq "G10 rc 0" "$(cat "$T/rc")" 0
eq "G10 no second agent call" "$(calls)" 1
eq "G10 sent_tg=1" "$(bf $P sent_tg)" 1
eq "G10 tg=sent call=0" "$(lastlog | grep -oE 'call=[01] tg=[a-z]+')" "call=0 tg=sent"
check "G10 the resend carries the move link" 'grep -qF "&move=" "$T/tg.text"'

# ═════ G11: the product lock is held: no read, no call ═══════════════════════
reset; P=pg11; five $P
mkdir -p "$H/locks"
flock "$H/locks/$P-product.lock" sleep 30 & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$H/locks/$P-product.lock" true 2>/dev/null || break; sleep 0.2; done
run -- $P
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
eq "G11 rc 0" "$(cat "$T/rc")" 0
eq "G11 no backlog read" "$(req '^GET /api/roadmap/ideas')" 0
eq "G11 no claim" "$(req '^POST /api/pm/briefs')" 0
eq "G11 no settings read of pm.stale_days" "$(req '^GET /api/settings/pm.stale_days')" 0
eq "G11 no agent call" "$(calls)" 0
check "G11 one log line says the lock is held" 'grep -q "product lock is held" "$LOGF"'

# ═════ G13: run-product's off switch and the paused flag stop it ════════════
# The lane gate runs here (LANE_GATE_DISABLE=0): lane_paused reads run-product's
# switch, and the fake worker has no flags route, so the file decides.
for fl in lane-off-run-product product-paused-pg13; do
  reset; P=pg13; five $P
  : > "$H/flags/$fl"
  run LANE_GATE_DISABLE=0 -- $P
  eq "G13 $fl: rc 0" "$(cat "$T/rc")" 0
  eq "G13 $fl: no backlog read" "$(req '^GET /api/roadmap/ideas')" 0
  eq "G13 $fl: no claim" "$(req '^POST /api/pm/briefs/claim')" 0
  eq "G13 $fl: no call" "$(calls)" 0
  check "G13 $fl: one log line says why" 'grep -qE "run-product is off|product-paused-pg13 is set" "$LOGF"'
done
# The control: the gate on and no flag, the lane runs.
reset; P=pg13c; five $P
answer '{"summary":"Gate on.","moves":[]}'
run LANE_GATE_DISABLE=0 -- $P
eq "G13 control: the gate on and no flag writes the brief" "$(bf $P status)" ready
reset
run -- 'bad/name'
eq "G13 a bad project name is usage, rc 2" "$(cat "$T/rc")" 2
run -- pg13 --nope
eq "G13 an unknown flag is usage, rc 2" "$(cat "$T/rc")" 2

# ═════ G14: a failed call is billed and final; --force re-runs it ═══════════
reset; P=pg14; five $P
answer "$(jq -nc --argjson m "[$(mv1 pg14-d30 ideas next '["stale.pg14-d30"]')]" '{summary:"After force.", moves:$m}')"
echo 1 > "$T/ac.rc"
run -- $P
eq "G14 rc 0" "$(cat "$T/rc")" 0
eq "G14 the brief failed" "$(bf $P status)" failed
eq "G14 the error names the rc" "$(bf $P error)" "agent-call rc=1"
eq "G14 one ALERTS line" "$(alerts)" 1
eq "G14 no Telegram" "$(n "$T/tg.akeys")" 0
echo 0 > "$T/ac.rc"
run -- $P
eq "G14 a rerun without --force makes no call" "$(calls)" 1
eq "G14 still failed" "$(bf $P status)" failed
run -- $P --force
eq "G14 --force: rc 0" "$(cat "$T/rc")" 0
eq "G14 --force: a second call" "$(calls)" 2
eq "G14 --force: ready with its move" "$(bf $P status) $(moves $P | jq 'length')" "ready 1"
eq "G14 --force: one brief row" "$(nbriefs $P)" 1

# ═════ G15: the create fails after the call: claimed, rc 1 ═══════════════════
reset; P=pg15; five $P
answer '{"summary":"Create fails.","moves":[]}'
: > "$T/fail.POST._api_pm_briefs"
run -- $P
eq "G15 rc 1" "$(cat "$T/rc")" 1
eq "G15 the row stays claimed" "$(bf $P status)" claimed
eq "G15 one ALERTS line" "$(alerts)" 1
check "G15 the ALERTS line says create failed after call" 'grep -q "create failed after call" "$ALF"'
eq "G15 no Telegram" "$(n "$T/tg.akeys")" 0
check "G15 the paid answer outlives the run" \
  'jq -e ".week == \"$WEEK\" and (.answer | test(\"Create fails\"))" "$H/state/pm-groom/$P.failed-create.json" >/dev/null 2>&1'

# ═════ G16: a failed read: rc 1, no claim, no call ═══════════════════════════
reset; P=pg16; five $P
: > "$T/fail.GET._api_roadmap_ideas"
run -- $P
eq "G16 rc 1" "$(cat "$T/rc")" 1
eq "G16 no claim" "$(req '^POST /api/pm/briefs/claim')" 0
eq "G16 no call" "$(calls)" 0
eq "G16 one ALERTS line" "$(alerts)" 1

# ═════ G17: a malformed answer: failed, rc 0 ═════════════════════════════════
reset; P=pg17; five $P
answer 'I think you should move some ideas.'
run -- $P
eq "G17 rc 0" "$(cat "$T/rc")" 0
eq "G17 the brief failed" "$(bf $P status)" failed
eq "G17 one ALERTS line" "$(alerts)" 1
reset; P=pg17b; five $P
printf '```json\n{\n  "summary": "Pretty JSON.",\n  "moves": []\n}\n```\n' > "$T/answer.json"; export PG_ANSWER="$T/answer.json"
run -- $P
eq "G17b a fenced multi-line answer parses" "$(bf $P status)" ready

# ═════ G18: the text cuts are settings rows (BH-7945) ═══════════════════════
reset; P=pg18; five $P; signals $P
for kv in pm.reason_max_chars:7 pm.summary_max_chars:5 pm.score_why_max_chars:4 pm.next_wave_max:3; do
  q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES (?,?,'','test','2026-10-20T00:00:00Z')" "${kv%%:*}" "${kv#*:}" >/dev/null
done
answer "$(jq -nc --argjson m "[$(mv1 pg18-d29 ideas next '["signal.new-ok"]')]" \
  '{summary:"Long summary text.", moves:$m, scores:[{idea_id:"pg18-d0", score:5, why:"a long why"}]}')"
run -- $P
eq "G18 rc 0" "$(cat "$T/rc")" 0
eq "G18 pm.reason_max_chars 7 cuts the move reason" "$(moves $P | jq -r '.[0].reason')" "fixture"
eq "G18 pm.summary_max_chars 5 cuts the summary" "$(body $P | jq -r '.summary')" "Long "
eq "G18 pm.score_why_max_chars 4 cuts the score why" "$(body $P | jq -r '.scores[0].why')" "a lo"
check "G18 the prompt Input carries NEXT_WAVE_MAX" 'grep -qx "NEXT_WAVE_MAX: 3" "$T/prompt.1"'

# ═════ G19: a big backlog and a wide move still fit the worker caps ══════════
# 350 stale ideas, a score with a 120-character why for each, and one move that
# cites 25 evidence ids. Before the fit, the body passed pm.body_max_chars and
# the move passed pm.evidence_max: the worker answered 400 after the paid call.
reset; P=pg19
q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('roadmap.list_limit','1000','','test','2026-10-20T00:00:00Z')" >/dev/null
q "INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at) VALUES $(
  for i in $(seq -w 1 350); do printf "('%s-i%s','%s','Idea %s','operator','ideas',1,'operator','2026-01-01T00:00:00Z','%s')," "$P" "$i" "$P" "$i" "$(iso_ago $((40 * DAY)))"; done | sed 's/,$//')" >/dev/null
WHY120=$(printf 'w%.0s' $(seq 1 120))
answer "$(jq -nc --arg p "$P" --arg why "$WHY120" '
  {summary:"A big backlog.",
   scores:[range(1; 351) | {idea_id: ("\($p)-i" + (tostring | if length < 3 then ("00" + .)[-3:] else . end)), score: (. % 101), why: $why}],
   moves:[{idea_id: "\($p)-i001", from_col: "ideas", to_col: "discarded", reason: "stale",
           evidence: [range(1; 26) | "stale.\($p)-i" + (tostring | ("00" + .)[-3:])]}]}')"
run -- $P
eq "G19 rc 0 ($(cat "$T/out"))" "$(cat "$T/rc")" 0
eq "G19 the brief is ready" "$(bf $P status)" ready
check "G19 the stored body is within pm.body_max_chars 65536" '[ "$(brief $P | jq -r ".body | length")" -le 65536 ]'
eq "G19 the move is stored with pm.evidence_max 20 ids" "$(moves $P | jq -r '.[0].evidence | fromjson | length')" 20
eq "G19 stale cut to pm.stale_max 200, stale_partial set" "$(body $P | jq -c '[(.stale | length), .stale_partial]')" '[200,true]'
check "G19 scores were cut and say so, highest score first" \
  'body $P | jq -e "(.scores | length) > 0 and (.scores | length) < 350 and .scores_partial and (.scores[0].score == 100)" >/dev/null'
eq "G19 all 350 ideas were read, so the stale cut is pm.stale_max" "$(logf ideas)" 350
eq "G19 no ALERTS line" "$(alerts)" 0
reset; P=pg19b; five $P
q "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('pm.scores_max','2','','test','2026-10-20T00:00:00Z')" >/dev/null
answer "$(jq -nc --arg p "$P" '{summary:"Three scores.", moves:[], scores:[{idea_id:"\($p)-d0",score:10,why:"a"},{idea_id:"\($p)-d10",score:90,why:"b"},{idea_id:"\($p)-d29",score:50,why:"c"}]}')"
run -- $P
eq "G19b pm.scores_max 2 keeps the two highest scores" "$(body $P | jq -c '[.scores[].score, .scores_partial]')" '[90,50,true]'

# ═════ G12: no vendor call over the whole suite ══════════════════════════════
eq "G12 no gh or non-worker curl call in the whole suite" "$(n "$T/net.log")" 0

# ═════ the node suites of this ticket ═══════════════════════════════════════
( cd "$DIR/worker/jobs" && node --test test/pm-briefs.bh-7261.test.js ) > "$T/node-w.txt" 2>&1
rc=$?; eq "worker/jobs/test/pm-briefs.bh-7261.test.js rc ($(grep -E '^# (pass|fail)' "$T/node-w.txt" | tr '\n' ' '))" "$rc" 0
[ "$rc" = 0 ] || grep -E '^not ok' "$T/node-w.txt"
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  ( cd "$DIR/console-ui" && node --test tests/roadmap-brief.bh-7261.test.js ) > "$T/node-c.txt" 2>&1
  rc=$?; eq "console-ui/tests/roadmap-brief.bh-7261.test.js rc ($(grep -E '^# (pass|fail)' "$T/node-c.txt" | tr '\n' ' '))" "$rc" 0
  [ "$rc" = 0 ] || grep -E '^not ok' "$T/node-c.txt"
else
  echo "pm-groom: console-ui/tests/roadmap-brief.bh-7261.test.js SKIPPED — console-ui has no node_modules (npm ci in console-ui)"
fi

echo "pm-groom: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
