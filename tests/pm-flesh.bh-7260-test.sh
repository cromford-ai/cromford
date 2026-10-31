#!/bin/bash
# tests/pm-flesh.bh-7260-test.sh — BH-7260 (BH-7244.2): land SYNTH ideas with
# data evidence as pm-agent roadmap ideas (bin/lib/pm-ideas-land.sh), and the
# seven-section PM flesh-out of one idea (bin/pm-flesh.sh). Drives the SHIPPED
# lib and script against the REAL worker routes (settings.js, roadmap-ideas.js,
# pm.js, model-routes.js) over a node:sqlite file built from the composed
# jobs schema. tests/lib/pm-flesh.bh-7260.mjs is that worker; it logs every
# request in $T/reqlog and every step in $T/order.
#
# WHAT IS STUBBED. bin/agent-call.sh (it logs its argv and env, copies the
# prompt, appends its cost.csv row with $COST_RUN_ID plus a same-project
# review row and execute row of other runs, and answers the file $PF_ANSWER, rc
# $T/ac.rc), bin/draft-proposal.sh (it logs its argv, appends one cost.csv
# row, rc $T/draft.rc), bin/alert-line.sh (it appends its text to
# logs/ALERTS.log), and bin/post-proposal.sh and bin/run-build.sh (each only
# records a call). `gh` on PATH and every curl to a host that is not the fake
# worker count into $T/net.log. Nothing here reaches a model, a board, GitHub
# or the real worker. The worker clock is pinned (D60). Each case uses its own
# project name and a fresh database.
#
# L1-L7 land, F1-F13 flesh, D2d-D2h / D5a-D5j the decision rules,
# X1 usage, K0-K3 the FLESH OUT launcher (bin/pm-flesh-launch.sh through the
# real bin/cmd-run-script.sh and its allowlist). Then the node suites of this ticket:
# worker/jobs/test/pm-runs.bh-7260.test.js and console-ui/tests/roadmap-flesh.bh-7260.test.js.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pm-flesh.bh-7260-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "pm-flesh: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

SCRIPT="$DIR/bin/pm-flesh.sh"
LAND_LIB="$DIR/bin/lib/pm-ideas-land.sh"
PROMPT_MD="$DIR/prompts/product-stages/pm-flesh.md"
SYNTH_MD="$DIR/prompts/product-stages/synth.md"
WDRV="$DIR/tests/lib/pm-flesh.bh-7260.mjs"
ROUTES="$DIR/worker/jobs/src/routes/pm.js"
FRAG="$DIR/worker/jobs/schema.d/202610301916-bh-7260-pm-runs.sql"
RET_FRAG="$DIR/worker/jobs/src/routes/retention.d/bh-7260-pm-runs.js"
RT_FRAG="$DIR/worker/jobs/test/route-table.d/bh-7260-pm.txt"
SITE="$DIR/catalog/llm-sites.d/7260-pm-flesh.json"
ANSWER_FX="$DIR/worker/jobs/test/fixtures/pm-flesh-answer.bh-7260.md"
# The console half (D41: every new source is named here).
CON_SECTION="$DIR/console-ui/src/screens/roadmap/flesh-section.js"
CON_API="$DIR/console-ui/src/lib/roadmap-api/pm-flesh.js"
CON_VIEW="$DIR/console-ui/src/screens/roadmap/list-view.js"
for f in "$DIR/bin/pm-flesh-launch.sh" "$DIR/console-ui/functions/_lib/pm-flesh-command.js" "$SCRIPT" "$LAND_LIB" "$PROMPT_MD" "$WDRV" "$ROUTES" "$FRAG" "$RET_FRAG" "$RT_FRAG" "$SITE" "$ANSWER_FX" "$CON_SECTION" "$CON_API"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
F8=$(grep -c claude- "$SCRIPT" 2>/dev/null)
eq "F8 grep -c claude- bin/pm-flesh.sh" "${F8:-missing}" 0
check "F8b no model string in the script, the lib or the prompt" '! grep -nE "claude-(opus|sonnet|haiku|fable)|gpt-[0-9]|grok-[0-9]" "$SCRIPT" "$LAND_LIB" "$PROMPT_MD"'
check "T5 the lib keeps its owner line" 'grep -q "^# Owner: BH-7244.3" "$LAND_LIB"'
check "T5 synth.md asks for evidence_ids" 'grep -q "evidence_ids" "$SYNTH_MD"'
check "T6 the prompt names the seven sections in order" \
  '[ "$(grep -oE "^[0-9]+\. \*\*[A-Za-z ]+\*\*" "$PROMPT_MD" | sed -E "s/^[0-9]+\. \*\*//; s/\*\*$//" | paste -sd, -)" = "Problem,Evidence,User and job,Options,Scope cut,Acceptance criteria,Risks" ]'
check "T7 llm-site: agent-call, stage pm, lane run-product, through agent-call, marker found in the script" \
  'm=$(jq -r ".[0].marker" "$SITE" 2>/dev/null); [ "$(jq -r ".[0] | [.id, .kind, .stage, .lane, .through_agent_call, .script] | @tsv" "$SITE")" = "$(printf "pm-flesh\tagent-call\tpm\trun-product\ttrue\tbin/pm-flesh.sh")" ] && grep -qF "$m" "$SCRIPT"'
check "L2/F9 the lib and the script never name a poster, a build, gh or curl" \
  '! grep -vhE "^[[:space:]]*#" "$SCRIPT" "$LAND_LIB" | grep -nE "post-proposal|run-build|gh-rest|(^|[^_a-z-])gh |curl "'
check "T8 the idea page imports and renders the section" 'grep -q "flesh-section.js" "$CON_VIEW" && grep -q "pmRuns" "$CON_VIEW"'

if [ ! -f "$SCRIPT" ] || [ ! -f "$ROUTES" ]; then
  echo "pm-flesh: $PASS passed, $FAIL failed"; exit 1
fi
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "pm-flesh: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "pm-flesh: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

NOW=2026-10-30T06:00:00Z

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
export FXT="$T" FXT_NOW="$NOW" PF_WORKER_DIR="$DIR/worker/jobs" NODE_NO_WARNINGS=1
# The worker test lib writes a jobs-schema-* dir under os.tmpdir() once a
# process and never removes it, so a node run here gets a TMPDIR in the scratch tree.
NT="$T/nodetmp"; mkdir -p "$NT" || exit 1
node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err" || { echo "FAIL: the schema does not apply: $(head -3 "$T/mkdb.err")"; exit 1; }
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$H/flags" "$H/bin" "$H/prompts/product-stages" "$T/fakebin"
for L in bin/pm-flesh.sh bin/jobs-client.sh bin/lib/pm-ideas-land.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
done
cp "$PROMPT_MD" "$H/prompts/product-stages/pm-flesh.md"
mkdir -p "$H/catalog"; cp "$DIR/catalog/lanes.json" "$H/catalog/"
: > "$H/env/global.env"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
# argv | lane | role | fp | no-tools
printf '%s|%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_ROLE:-}" "${AGENT_CALL_FP:-}" "${AGENT_CALL_NO_TOOLS:-}" >> "$FXT/agentcalls"
echo agent-call >> "$FXT/order"
n=$(grep -c . "$FXT/agentcalls")
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
printf '2026-10-30T06:00:00Z,box-fixture,%s,%s,claude,model-fixture,0,1,1,1,0,0,0.25,%s,fixture\n' "$2" "$1" "${COST_RUN_ID:-}" >> "$HARNESS/logs/cost.csv"
printf '2026-10-30T06:00:00Z,box-fixture,other-project,%s,claude,model-fixture,0,1,1,1,0,0,9.00,%s,fixture\n' "$1" "${COST_RUN_ID:-}" >> "$HARNESS/logs/cost.csv"
# A review of the SAME project in the same window (another lane): never this run's cost.
printf '2026-10-30T06:00:00Z,box-fixture,%s,review,claude,model-fixture,0,1,1,1,0,0,4.10,cromford-X-1,fixture\n' "$2" >> "$HARNESS/logs/cost.csv"
printf '2026-10-30T06:00:00Z,box-fixture,%s,execute,claude,model-fixture,0,1,1,1,0,0,2.20,,fixture\n' "$2" >> "$HARNESS/logs/cost.csv"
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
cat "${PF_ANSWER:-/dev/null}" > "$5"
SH
cat > "$H/bin/draft-proposal.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/draft.calls"
echo draft >> "$FXT/order"
[ -s "$2/idea.json" ] && cp "$2/idea.json" "$FXT/draft.idea.json"
if [ -s "$FXT/draft.prd" ]; then cp "$FXT/draft.prd" "$2/prd.md"; else printf '# PRD fixture\n\nThe drafted PRD.\n' > "$2/prd.md"; fi
printf '2026-10-30T06:00:00Z,box-fixture,%s,prd,claude,model-fixture,0,1,1,1,0,0,0.50,%s,fixture\n' "$1" "${COST_RUN_ID:-}" >> "$HARNESS/logs/cost.csv"
printf '%s\n' "${COST_RUN_ID:-}" >> "$FXT/draft.runid"
exit "$(cat "$FXT/draft.rc" 2>/dev/null || echo 0)"
SH
for s in post-proposal run-build; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$FXT/forbidden.log"\n' "$s" > "$H/bin/$s.sh"
done
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s %s\n' "$(date -u '+%F %TZ')" "$1" >> "$HARNESS/logs/ALERTS.log"
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
chmod +x "$H/bin/agent-call.sh" "$H/bin/draft-proposal.sh" "$H/bin/post-proposal.sh" "$H/bin/run-build.sh" \
  "$H/bin/alert-line.sh" "$T/fakebin/curl" "$T/fakebin/gh"
cp "$WDRV" "$T/wdrv.mjs"
: > "$T/net.log"; : > "$T/forbidden.log"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh7260 JOBS_RETRIES=0
unset PM_MODEL CONSOLE_PAGES_URL LOG 2>/dev/null || true

reset() {
  local p
  for p in reqlog order agentcalls out rc ac.rc draft.rc draft.calls draft.runid draft.idea.json draft.prd land.rc; do scratch_rm "$T/$p" || exit 1; done
  rm -f "$T"/prompt.* "$T"/fail.*
  for p in state locks flags products; do scratch_rm "$H/$p" || exit 1; done
  rm -f "$H/logs/"*
  printf 'ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,run_id,note\n' > "$H/logs/cost.csv"
  mkdir -p "$H/flags"
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"; : > "$T/order"
}
n()      { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls()  { n "$T/agentcalls"; }
req()    { local c; c=$(grep -cE "$1" "$T/reqlog" 2>/dev/null); printf '%s' "${c:-0}"; }
ALF="$H/logs/ALERTS.log"
alerts() { local c; c=$(grep -c 'pm-flesh' "$ALF" 2>/dev/null); printf '%s' "${c:-0}"; }
project() { q "INSERT INTO projects (project, repo, cron_offset, created_at, updated_at) VALUES (?, ?, 0, ?, ?)" "$1" "o/$1-fixture" "$NOW" "$NOW" >/dev/null; }

# ═════ LAND ══════════════════════════════════════════════════════════════════
LANDLOG="$H/logs/product.log"
# land <project> <cycle_dir>: pm_ideas_land the way bin/run-product.sh calls it.
land() {
  bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/pm-ideas-land.sh"; LOG="$3"; pm_ideas_land "$1" "$2"; echo $? > "$4"' \
    _ "$1" "$2" "$LANDLOG" "$T/land.rc" > "$T/out" 2>&1
}
landf() { grep -E 'pm-land: ' "$LANDLOG" 2>/dev/null | tail -1 | grep -oE "(^| )$1=[^ ]+" | cut -d= -f2; }
ideas_of() { q "SELECT * FROM roadmap_ideas WHERE project=? ORDER BY idem_key" "$1"; }
signals_ok() { # signals_ok <cycle_dir>
  mkdir -p "$1"
  jq -n '{snapshot_hash:"hash-fixture-1", evidence:[
    {id:"alerts.7d", source:"alerts", metric:"alerts", value:41, window:"7d", link:"", status:"ok"},
    {id:"qa.open", source:"qa", metric:"open_findings", value:3, window:"7d", link:"", status:"ok"},
    {id:"cost.30d", source:"cost", metric:"usd", value:null, window:"30d", link:"", status:"not-configured"},
    {id:"board.stale", source:"board", metric:"stale", value:null, window:"7d", link:"", status:"error"}]}' > "$1/data-signals.json"
}
idea_j() { # idea_j <slug> <extra-json>
  jq -nc --arg s "$1" --argjson x "$2" '{slug:$s, title:("Idea " + $s), summary:("Summary of " + $s), dus:"unclog", impact:3} + $x'
}

# L1: every D1 row as one fixture idea in one ideas.json.
reset; P=pl1; project $P; C="$T/cyc-l1"; signals_ok "$C"
{
  echo '{"ideas":['
  idea_j l-ids '{"evidence_ids":["alerts.7d"]}'; echo ,
  idea_j l-text '{"evidence":"ALERTS rose (alerts.7d: 41 in 7 days)"}'; echo ,
  idea_j l-obj '{"evidence":[{"evidence_id":"qa.open"}]}'; echo ,
  idea_j l-period '{"evidence":"see alerts.7d."}'; echo ,
  idea_j l-nc '{"evidence_id":"cost.30d"}'; echo ,
  idea_j l-err '{"evidence":"board.stale is high"}'; echo ,
  idea_j l-prefix '{"evidence":"alerts.7 rose"}'; echo ,
  idea_j l-super '{"evidence_ids":["alerts.7dx"]}'; echo ,
  jq -nc '{slug:"l-title", title:"About alerts.7d", summary:"alerts.7d in the summary", evidence:"a client said so"}'; echo ,
  jq -nc '{slug:"l-none", title:"No evidence", summary:"none"}'
  echo ']}'
} > "$C/ideas.json"
land $P "$C"
eq "L1 rc 0 ($(cat "$T/out"))" "$(cat "$T/land.rc")" 0
eq "L1 four POSTs" "$(req '^POST /api/roadmap/ideas \{')" 4
eq "L1 exactly the D1-positive slugs land" "$(ideas_of $P | jq -r '[.[].idem_key] | join(",")')" "pm-l-ids,pm-l-obj,pm-l-period,pm-l-text"
eq "L1 every POST carries source pm-agent and actor pm-agent" \
  "$(grep -E '^POST /api/roadmap/ideas \{' "$T/reqlog" | cut -d' ' -f3- | jq -sr '[.[] | select(.source == "pm-agent" and .actor == "pm-agent" and (.idem_key | test("^pm-l-")))] | length')" 4
eq "L1 every landed idea is in the ideas lane with source pm-agent" "$(ideas_of $P | jq -r '[.[] | select(.lane == "ideas" and .source == "pm-agent")] | length')" 4
check "L1 the note carries the summary and the ok evidence ids" \
  'ideas_of $P | jq -e ".[] | select(.idem_key == \"pm-l-obj\") | .note | (startswith(\"Summary of l-obj\") and contains(\"Evidence: qa.open\"))" >/dev/null'
eq "L1 the summary line" "$(grep -oE 'candidates=[0-9]+ evidence=[0-9]+ landed=[0-9]+ replay=[0-9]+ changed=[0-9]+ errors=[0-9]+' "$LANDLOG" | tail -1)" \
  "candidates=10 evidence=4 landed=4 replay=0 changed=0 errors=0"
# L1b: an ok id is cited, but run-product removed data-signals.json.
C2="$T/cyc-l1b"; mkdir -p "$C2"; cp "$C/ideas.json" "$C2/"
reset; P=pl1b; project $P
land $P "$C2"
eq "L1b no data-signals.json: rc 0" "$(cat "$T/land.rc")" 0
eq "L1b no data-signals.json: no POST" "$(req '^POST /api/roadmap/ideas')" 0
eq "L1b evidence=0" "$(landf evidence)" 0

# L3: the same cycle twice: 1 idea per slug (replay); L4: a changed summary is 409.
reset; P=pl3; project $P
land $P "$C"; land $P "$C"
eq "L3 rc 0" "$(cat "$T/land.rc")" 0
eq "L3 four ideas after two lands, not eight" "$(ideas_of $P | jq length)" 4
eq "L3 the second land is replay=4 landed=0" "$(landf replay) $(landf landed)" "4 0"
NOTE_BEFORE=$(ideas_of $P | jq -c '[.[] | select(.idem_key == "pm-l-ids") | .note, .version]')
jq '(.ideas[] | select(.slug == "l-ids") | .summary) = "A changed summary"' "$C/ideas.json" > "$C2/ideas.json"; signals_ok "$C2"
land $P "$C2"
eq "L4 a changed summary counts as changed" "$(landf changed)" 1
eq "L4 the other three are replays" "$(landf replay)" 3
eq "L4 the stored note and version are unchanged" "$(ideas_of $P | jq -c '[.[] | select(.idem_key == "pm-l-ids") | .note, .version]')" "$NOTE_BEFORE"

# L5: no ideas.json: rc 0 and no request.
reset; P=pl5; project $P
C5="$T/cyc-l5"; signals_ok "$C5"
land $P "$C5"
eq "L5 rc 0" "$(cat "$T/land.rc")" 0
eq "L5 no request" "$(n "$T/reqlog")" 0
# The seam as run-product sources it, with no jobs client loaded: rc 0, nothing sent.
bash -c '. "$1"; pm_ideas_land p "$2"' _ "$LAND_LIB" "$C" >/dev/null 2>&1
eq "L5b no jobs client: rc 0" "$?" 0
eq "L5b no jobs client: no request" "$(n "$T/reqlog")" 0

# L6: 25 qualifying ideas, pm.land_max 20: 20 POSTs; pm.land_max 0: none.
reset; P=pl6; project $P
C6="$T/cyc-l6"; signals_ok "$C6"
jq -n '{ideas: [range(1; 26) | {slug: "many-\(.)", title: "Many \(.)", summary: "s", evidence_ids: ["alerts.7d"]}]}' > "$C6/ideas.json"
land $P "$C6"
eq "L6 pm.land_max 20 caps the POSTs" "$(req '^POST /api/roadmap/ideas \{')" 20
eq "L6 the cap is in the summary line" "$(landf capped)" 5
reset; P=pl6b; project $P
q "UPDATE settings SET value='0' WHERE key='pm.land_max'" >/dev/null
land $P "$C6"
eq "L6b pm.land_max 0: rc 0" "$(cat "$T/land.rc")" 0
eq "L6b pm.land_max 0: no POST" "$(req '^POST /api/roadmap/ideas')" 0

# L7: a slug the idem key cannot carry is skipped with a log line; an unknown project is an error.
reset; P=pl7; project $P
C7="$T/cyc-l7"; signals_ok "$C7"
jq -n --arg long "$(printf 'x%.0s' $(seq 1 78))" --arg max "$(printf 'y%.0s' $(seq 1 77))" '{ideas: [
  {slug: "bad slug", title: "Bad", summary: "s", evidence_ids: ["alerts.7d"]},
  {slug: $long, title: "Long", summary: "s", evidence_ids: ["alerts.7d"]},
  {slug: $max, title: "Longest", summary: "s", evidence_ids: ["alerts.7d"]},
  {slug: "good-1", title: "Good", summary: "s", evidence_ids: ["alerts.7d"]}]}' > "$C7/ideas.json"
land $P "$C7"
eq "L7 the good slug and the 77-character slug land" "$(ideas_of $P | jq -r '[.[].idem_key | .[0:8]] | join(",")')" "pm-good-,pm-yyyyy"
eq "L7 skipped=2" "$(landf skipped)" 2
eq "L7 one log line per skipped slug" "$(grep -c 'pm-land: skip slug' "$LANDLOG")" 2
reset; P=pl7b
land $P "$C7"
eq "L7b an unknown project: rc 0" "$(cat "$T/land.rc")" 0
eq "L7b an unknown project: errors=2 (both landable slugs)" "$(landf errors)" 2

# ═════ FLESH ═════════════════════════════════════════════════════════════════
LOGF="$H/logs/pm-flesh.log"
lastlog() { grep -E ' idea=' "$LOGF" 2>/dev/null | tail -1; }
logf()   { lastlog | grep -oE "(^| )$1=[^ ]+" | cut -d= -f2; }
runrow() { q "SELECT * FROM pm_runs WHERE project=? ORDER BY created_at, id" "$1" | jq -c '.[-1] // {}'; }
rf()     { runrow "$1" | jq -r --arg f "$2" '.[$f] // "null" | tostring'; }
nruns()  { q "SELECT COUNT(*) AS n FROM pm_runs WHERE project=?" "$1" | jq -r '.[0].n'; }
idea_row() { q "SELECT * FROM roadmap_ideas WHERE project=? AND id=?" "$1" "$2" | jq -c '.[0] // {}'; }
# seed_idea <project> <id> [note]
seed_idea() {
  q "INSERT INTO roadmap_ideas (id, project, title, note, source, lane, version, created_by, created_at, updated_at) VALUES (?, ?, ?, ?, 'pm-agent', 'ideas', 1, 'pm-agent', ?, ?)" \
    "$2" "$1" "Owner per alert" "${3:-The user note.}" "$NOW" "$NOW" >/dev/null
}
flesh_signals() { signals_ok "$H/products/$1/2026-10-29"; }
answer() { cp "$1" "$T/answer.md"; export PF_ANSWER="$T/answer.md"; }
answer "$ANSWER_FX"
# F11: every path a pm-flesh run leaves under state/ whose first segment
# catalog/state-paths.json does not class cache or box-local (none is allowed).
# The model-route and lane-gate caches the sourced libs keep are such classed
# segments; a pm-flesh work dir is not.
: > "$T/state.writes"
STATE_OK=$(jq -r '[.paths[] | select(.class == "cache" or .class == "box-local") | .path | split("/")[0]] | unique | .[]' "$DIR/catalog/state-paths.json")
[ -n "$STATE_OK" ] || bad "F11 cannot read the classed segments of catalog/state-paths.json"
# Each pm-flesh run gets this suite's own TMPDIR, so the F11 temp-dir scan sees
# only this run's dirs, never those of a parallel run on the same box (BH-7563 5).
PF_TMP="$T/pf-tmp"; mkdir -p "$PF_TMP" || bad "F11 cannot make $PF_TMP"
# run [VAR=value...] -- <args>
run() {
  local -a e=() a=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; a=("$@"); break ;; *) e+=("$1"); shift ;; esac
  done
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 TMPDIR="$PF_TMP" "${e[@]}" bash "$H/bin/pm-flesh.sh" "${a[@]}" > "$T/out" 2>&1
  echo $? > "$T/rc"
  local f seg
  while IFS= read -r f; do
    seg=${f#"$H/state/"}; seg=${seg%%/*}
    grep -qxF -- "$seg" <<<"$STATE_OK" || printf '%s\n' "$f" >> "$T/state.writes"
  done < <(find "$H/state" -mindepth 1 2>/dev/null)
  find "$PF_TMP" -mindepth 1 -maxdepth 1 2>/dev/null >> "$T/tmp.left"
}
URL_BASE=https://console.example.pages.dev

# F1: one run: seven sections, one done row with result_ref, draft and cost; the idea row is not edited.
reset; P=pf1; ID=idea-f1; seed_idea $P $ID; flesh_signals $P
run -- $P $ID
eq "F1 rc 0 ($(head -5 "$T/out"))" "$(cat "$T/rc")" 0
eq "F1 one agent call" "$(calls)" 1
eq "F1 the seven headings are printed, in order" "$(grep -E '^## ' "$T/out" | paste -sd'|' -)" \
  "## Problem|## Evidence|## User and job|## Options|## Scope cut|## Acceptance criteria|## Risks"
eq "F1 one pm_runs row" "$(nruns $P)" 1
eq "F1 the row is done" "$(rf $P status)" done
eq "F1 draft=ok" "$(rf $P draft)" ok
eq "F1 the drafted PRD is kept in the row (the temp dir is gone)" "$(rf $P prd)" "$(printf '# PRD fixture\n\nThe drafted PRD.\n')"
check "F1 the PRD reads back through GET /api/pm/runs latest" \
  '[ "$(TMPDIR="$NT" node "$T/wdrv.mjs" GET "/api/pm/runs?project=$P&idea_id=$ID" | head -1 | jq -r ".latest.prd | startswith(\"# PRD fixture\")")" = true ]'
eq "F1 cost_usd is the sum of this run's cost rows (call 0.25 + draft 0.50)" "$(rf $P cost_usd)" 0.75
RUNID=$(runrow $P | jq -r .id)
check "F1c the call ran with COST_RUN_ID=pm-flesh:<run id>" 'grep -qxF "pm-flesh:$RUNID" "$T/draft.runid" && [ "$(grep -c ",pm-flesh:$RUNID,fixture$" "$H/logs/cost.csv")" = 3 ]'
check "F1c a same-project review and execute row in the window are in cost.csv and not counted" \
  'grep -q ",$P,review,.*,4.10,cromford-X-1," "$H/logs/cost.csv" && grep -q ",$P,execute,.*,2.20,," "$H/logs/cost.csv"'
check "F1 the stored result has the seven headings and no PM_FLESH_DONE" \
  'r=$(runrow $P | jq -r .result); [ "$(grep -cE "^## " <<<"$r")" = 7 ] && ! grep -q PM_FLESH_DONE <<<"$r" && ! grep -q "I read the idea" <<<"$r"'
check "F1 the result reads back through GET /api/pm/runs (done <=> readable)" \
  '[ "$(TMPDIR="$NT" node "$T/wdrv.mjs" GET "/api/pm/runs?project=$P&idea_id=$ID" | head -1 | jq -r ".latest.status + \" \" + (.latest.result | split(\"\n\") | map(select(startswith(\"## \"))) | length | tostring)")" = "done 7" ]'
eq "F1 result_ref is the idea page link" "$(rf $P result_ref)" "$URL_BASE/roadmap/pf1/idea/idea-f1#pm-flesh"
eq "F1 the idea row is not edited (version 1, the note kept)" "$(idea_row $P $ID | jq -r '[.version, .note] | @tsv')" "$(printf '1\tThe user note.')"
eq "F1 no idea edit request" "$(req '^POST /api/roadmap/ideas/edit')" 0
check "F1 agent-call: stage pm, project, timeout 900, lane run-product, role product.pm, fp, no tools ($(head -1 "$T/agentcalls"))" \
  'grep -qE "^pm pf1 [^ ]+ 900 [^ ]+ @[^ ]+\|run-product\|product.pm\|pm-flesh:pf1:idea-f1:[0-9a-f]{12}\|1$" "$T/agentcalls"'
check "F1 the prompt holds the idea and only the ok evidence" \
  'grep -qF "Owner per alert" "$T/prompt.1" && grep -qF "alerts.7d" "$T/prompt.1" && ! grep -qE "cost\.30d|board\.stale" "$T/prompt.1"'
eq "F1 the step order" "$(grep -E '^(jobs POST /api/pm/(claim|result)|agent-call|draft)$' "$T/order" | tr '\n' ' ')" \
  "jobs POST /api/pm/claim agent-call jobs POST /api/pm/result draft jobs POST /api/pm/result "
eq "F1 the first result POST is answered, the second done" \
  "$(grep -E '^POST /api/pm/result ' "$T/reqlog" | cut -d' ' -f3- | jq -r .status | paste -sd, -)" "answered,done"
eq "F1 draft-proposal got the idea file" "$(jq -r '(.slug | startswith("pmflesh-")) and (.prd_notes | startswith("## Problem"))' "$T/draft.idea.json" 2>/dev/null)" true
eq "F1 the log line" "$(lastlog | grep -oE 'claim=[a-z]+ call=[01] draft=[a-z]+ rc=[0-9]+')" "claim=new call=1 draft=ok rc=0"
eq "F1 no ALERTS line" "$(alerts)" 0

# F2: the same inputs again: 0 calls, the stored result.
run -- $P $ID
eq "F2 rc 0" "$(cat "$T/rc")" 0
eq "F2 no second agent call" "$(calls)" 1
eq "F2 one pm_runs row" "$(nruns $P)" 1
eq "F2 the stored result is printed" "$(grep -cE '^## ' "$T/out")" 7
eq "F2 claim=already call=0" "$(lastlog | grep -oE 'claim=[a-z]+ call=[01]')" "claim=already call=0"
# D2f: --force on a done row: the stored result, 0 calls.
run -- $P $ID --force
eq "D2f --force on done: rc 0" "$(cat "$T/rc")" 0
eq "D2f --force on done: 0 calls" "$(calls)" 1
eq "D2f --force on done: the stored result" "$(grep -cE '^## ' "$T/out")" 7
# A person edits the note: a new hash, a new run.
TMPDIR="$NT" node "$T/wdrv.mjs" POST /api/roadmap/ideas/edit <(jq -nc --arg i $ID --arg p $P '{id:$i, project:$p, note:"A new user note.", expected_version:1, actor:"operator"}') >/dev/null
run -- $P $ID
eq "F2b a changed note is a new run with one call" "$(calls) $(nruns $P)" "2 2"

# F3: no product.pm route: rc 75, 0 calls, 0 claims, no idea read.
reset; P=pf3; ID=idea-f3; seed_idea $P $ID
q "DELETE FROM model_routes WHERE role='product.pm'" >/dev/null
run -- $P $ID
eq "F3 rc 75" "$(cat "$T/rc")" 75
eq "F3 0 calls" "$(calls)" 0
eq "F3 no claim" "$(req '^POST /api/pm/claim')" 0
eq "F3 no idea read" "$(req '^GET /api/roadmap/ideas')" 0
eq "F3 no row" "$(nruns $P)" 0

# F4: the claim route is down: rc 75, 0 calls.
reset; P=pf4; ID=idea-f4; seed_idea $P $ID
: > "$T/fail.POST._api_pm_claim"
run -- $P $ID
eq "F4 rc 75" "$(cat "$T/rc")" 75
eq "F4 0 calls" "$(calls)" 0
eq "F4 the claim was tried once" "$(req '^POST /api/pm/claim')" 1
eq "F4 no row" "$(nruns $P)" 0
# The idea read down: rc 75 and no claim; a missing idea: rc 1 and no claim.
reset; P=pf4b; ID=idea-f4b; seed_idea $P $ID
: > "$T/fail.GET._api_roadmap_ideas_$ID"
run -- $P $ID
eq "F4b idea read down: rc 75" "$(cat "$T/rc")" 75
eq "F4b idea read down: no claim" "$(req '^POST /api/pm/claim')" 0
reset; P=pf4c
run -- $P no-such-idea
eq "F4c no such idea: rc 1" "$(cat "$T/rc")" 1
eq "F4c no such idea: no claim" "$(req '^POST /api/pm/claim')" 0
eq "F4c no such idea: 0 calls" "$(calls)" 0

# F5: the done POST fails once: the row stays answered; the re-run makes 0 calls and finishes with draft=unknown.
reset; P=pf5; ID=idea-f5; seed_idea $P $ID; flesh_signals $P
printf '"status":"done"' > "$T/failbody.POST._api_pm_result"
run -- $P $ID
eq "F5 the failed done POST: rc 1" "$(cat "$T/rc")" 1
eq "F5 the row stays answered" "$(rf $P status)" answered
check "F5 the answered row holds the result" '[ "$(rf $P result | grep -cE "^## ")" = 7 ]'
eq "F5 one ALERTS line" "$(alerts)" 1
rm -f "$T/failbody.POST._api_pm_result"
run -- $P $ID
eq "F5 the resume: rc 0" "$(cat "$T/rc")" 0
eq "F5 the resume makes 0 calls" "$(calls)" 1
eq "F5 the resume runs no second draft" "$(n "$T/draft.calls")" 1
eq "F5 the row is done" "$(rf $P status)" done
eq "F5 draft=unknown" "$(rf $P draft)" unknown
eq "F5 the cost of the first run is kept" "$(rf $P cost_usd)" 0.75
eq "F5 the resume prints the result" "$(grep -cE '^## ' "$T/out")" 7
eq "F5 claim=resume call=0 draft=unknown" "$(lastlog | grep -oE 'claim=[a-z]+ call=[01] draft=[a-z]+')" "claim=resume call=0 draft=unknown"
# D2d: the answered POST fails: the row stays claimed; a re-run is "already billed", 0 calls.
reset; P=pf5b; ID=idea-f5b; seed_idea $P $ID; flesh_signals $P
printf '"status":"answered"' > "$T/failbody.POST._api_pm_result"
run -- $P $ID
eq "D2d the failed answered POST: rc 1" "$(cat "$T/rc")" 1
eq "D2d the row stays claimed" "$(rf $P status)" claimed
eq "D2d one ALERTS line" "$(alerts)" 1
rm -f "$T/failbody.POST._api_pm_result"
run -- $P $ID
eq "D2d claimed: rc 0" "$(cat "$T/rc")" 0
eq "D2d claimed: 0 calls" "$(calls)" 1
eq "D2d claim=billed" "$(logf claim)" billed
eq "D2d the row stays claimed" "$(rf $P status)" claimed
# D2g: --force on a claimed row claims it again and calls once more.
run -- $P $ID --force
eq "D2g --force on claimed: rc 0, one more call" "$(cat "$T/rc") $(calls)" "0 2"
eq "D2g the row is done" "$(rf $P status)" done

# F7: the answer cites a not-configured id: failed and billed; a re-run makes 0 calls.
reset; P=pf7; ID=idea-f7; seed_idea $P $ID; flesh_signals $P
sed 's/^- alerts.7d: 41 alerts in 7 days\./- cost.30d: no data./' "$ANSWER_FX" > "$T/answer-f7.md"; answer "$T/answer-f7.md"
run -- $P $ID
eq "F7 rc 1" "$(cat "$T/rc")" 1
eq "F7 status failed" "$(rf $P status)" failed
check "F7 the error names the id" 'rf $P error | grep -q "cost.30d"'
eq "F7 one ALERTS line" "$(alerts)" 1
eq "F7 no draft" "$(n "$T/draft.calls")" 0
run -- $P $ID
eq "F7 the re-run: rc 0" "$(cat "$T/rc")" 0
eq "F7 the re-run makes 0 calls" "$(calls)" 1
eq "F7 claim=billed" "$(logf claim)" billed
# D2h: --force on a failed row claims it again and calls once more.
answer "$ANSWER_FX"
run -- $P $ID --force
eq "D2h --force on failed: rc 0" "$(cat "$T/rc")" 0
eq "D2h --force on failed: one more call" "$(calls)" 2
eq "D2h the row is done" "$(rf $P status)" done
# F7b: a failed agent call is failed and billed too.
reset; P=pf7b; ID=idea-f7b; seed_idea $P $ID
echo 3 > "$T/ac.rc"
run -- $P $ID
eq "F7b agent-call rc 3: rc 1, status failed" "$(cat "$T/rc") $(rf $P status)" "1 failed"
# F12: draft-proposal fails: the flesh-out is still done, with draft=failed; rc 75 is skipped.
for dr in 3:failed 75:skipped; do
  reset; P=pf12; ID=idea-f12; seed_idea $P $ID; flesh_signals $P
  echo "${dr%%:*}" > "$T/draft.rc"
  run -- $P $ID
  eq "F12 draft rc ${dr%%:*}: rc 0, done, draft=${dr#*:}" "$(cat "$T/rc") $(rf $P status) $(rf $P draft)" "0 done ${dr#*:}"
done

# F14: a PRD over pm.flesh_prd_max_chars is cut with a note line, never refused.
reset; P=pf14; ID=idea-f14; seed_idea $P $ID; flesh_signals $P
q "UPDATE settings SET value='1024' WHERE key='pm.flesh_prd_max_chars'" >/dev/null
head -c 3000 /dev/zero | tr '\0' x > "$T/draft.prd"
run -- $P $ID
eq "F14 rc 0, done, draft=ok" "$(cat "$T/rc") $(rf $P status) $(rf $P draft)" "0 done ok"
check "F14 the kept PRD is 1024 characters and ends with the cut note" \
  'r=$(rf $P prd); [ "${#r}" = 1024 ] && grep -qF "[The PRD was cut at pm.flesh_prd_max_chars=1024 characters.]" <<<"$r"'
q "UPDATE settings SET value='131072' WHERE key='pm.flesh_prd_max_chars'" >/dev/null

# F10: the product lock is held: rc 75, no read, no call.
reset; P=pf10; ID=idea-f10; seed_idea $P $ID
mkdir -p "$H/locks"
flock "$H/locks/$P-product.lock" sleep 30 & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$H/locks/$P-product.lock" true 2>/dev/null || break; sleep 0.2; done
run -- $P $ID
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
eq "F10 rc 75" "$(cat "$T/rc")" 75
eq "F10 no request" "$(n "$T/reqlog")" 0
eq "F10 0 calls" "$(calls)" 0

# F13: run-product's off switch and the paused flag stop it: rc 0, no request.
for fl in lane-off-run-product product-paused-pf13; do
  reset; P=pf13; ID=idea-f13; seed_idea $P $ID
  : > "$H/flags/$fl"
  : > "$T/reqlog"
  run LANE_GATE_DISABLE=0 -- $P $ID
  eq "F13 $fl: rc 0" "$(cat "$T/rc")" 0
  eq "F13 $fl: no claim" "$(req '^POST /api/pm/claim')" 0
  eq "F13 $fl: 0 calls" "$(calls)" 0
done

# X1: usage: rc 2, no request.
reset
for args in "../x idea" "p" "p a/b" "p -x" "p $(printf 'i%.0s' $(seq 1 81))" "p i --nope"; do
  # shellcheck disable=SC2086
  run -- $args
  eq "X1 usage ($args): rc 2" "$(cat "$T/rc")" 2
done
eq "X1 no request" "$(n "$T/reqlog")" 0

# F11: no run wrote under state/, and no temp dir outlived its run.
eq "F11 no pm-flesh path under state/ ($(head -3 "$T/state.writes" | tr '\n' ' '))" "$(n "$T/state.writes")" 0
eq "F11 no pm-flesh temp dir is left ($(head -3 "$T/tmp.left" 2>/dev/null | tr '\n' ' '))" "$(n "$T/tmp.left")" 0

# ═════ D5: the answer check ══════════════════════════════════════════════════
SIGF="$T/d5-signals.json"; signals_ok "$T/d5"; cp "$T/d5/data-signals.json" "$SIGF"
d5() { # d5 <answer-file> [max]: prints "ok" or "bad: <why>"
  local out rc
  out=$(PM_FLESH_LIB=1 bash -c '. "$1"; pm_flesh_check "$2" "$3" "$4"' _ "$SCRIPT" "$1" "$SIGF" "${2:-32768}"); rc=$?
  if [ "$rc" = 0 ]; then echo ok; else echo "bad: $out"; fi
}
mk() { printf '%s\n' "$1" > "$T/d5.md"; echo "$T/d5.md"; }
FX=$(cat "$ANSWER_FX")
eq "D5a the fixture is valid" "$(d5 "$ANSWER_FX")" ok
check "D5b a missing heading is invalid" '[[ "$(d5 "$(mk "${FX/$'"'"'## Scope cut'"'"'/Scope cut}")")" == bad:* ]]'
check "D5c headings out of order are invalid" '[[ "$(d5 "$(mk "$(sed "s/^## Problem$/## TMP/; s/^## Evidence$/## Problem/; s/^## TMP$/## Evidence/" "$ANSWER_FX")")")" == bad:* ]]'
check "D5d an extra ## Notes is invalid" '[[ "$(d5 "$(mk "${FX/PM_FLESH_DONE/## Notes
more
PM_FLESH_DONE}")")" == bad:* ]]'
check "D5e ## problem (wrong case) is invalid" '[[ "$(d5 "$(mk "$(sed "s/^## Problem$/## problem/" "$ANSWER_FX")")")" == bad:* ]]'
check "D5f a cited not-configured id is invalid" '[[ "$(d5 "$(mk "${FX/- alerts.7d:/- cost.30d:}")")" == bad:*cost.30d* ]]'
check "D5g over the cap is invalid" '[[ "$(d5 "$ANSWER_FX" 100)" == bad:* ]]'
check "D5h PM_FLESH_FAILED as the final line is invalid" '[[ "$(d5 "$(mk "${FX/PM_FLESH_DONE/PM_FLESH_FAILED no evidence}")")" == bad:* ]]'
eq "D5i text before the first heading is dropped, PM_FLESH_DONE is dropped" \
  "$(PM_FLESH_LIB=1 bash -c '. "$1"; pm_flesh_check "$2" "$3" 32768' _ "$SCRIPT" "$ANSWER_FX" "$SIGF" | sed -n '1p;$p' | paste -sd'|' -)" "## Problem|The owner can be away. A fallback owner is a later step."
check "D5j an error-status id is invalid; an id not in the file is not checked" \
  '[[ "$(d5 "$(mk "${FX/- alerts.7d:/- board.stale:}")")" == bad:* ]] && [ "$(d5 "$(mk "${FX/- alerts.7d:/- made.up:}")")" = ok ]'

# ═════ LAUNCH: the FLESH OUT button's box half ═══════════════════════════════
# The console row reaches the box as run_script {script: pm-flesh-launch.sh,
# args: [<p>, <id>]}; bin/cmd-run-script.sh runs it only from its allowlist.
for L in bin/pm-flesh-launch.sh bin/cmd-run-script.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || bad "install $L"
done
cp -r "$DIR/catalog/run-script-allowlist.json" "$DIR/catalog/run-script-allowlist.d" "$H/catalog/"
printf '# fixture\npk1 o/pk1 - - 1 hub\npk2 o/pk2 - - 2 hub\n' > "$T/fleet.conf"
LAUNCH="$H/bin/pm-flesh-launch.sh"
lrun() { OUT=$(env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 FLEET_CONF="$T/fleet.conf" "$@" 2>"$T/lerr"); RC=$?; }
lj() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
# wait_done <project> <id>: up to 60 s for the detached run's log line.
wait_done() {
  local i=0
  while ! grep -qE " idea=$2 .* rc=" "$LOGF" 2>/dev/null && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
  grep -qE " idea=$2 .* rc=" "$LOGF" 2>/dev/null
}
check "K0 the allowlist fragment names the launcher" \
  '[ "$(jq -r ".scripts | join(\",\")" "$DIR/catalog/run-script-allowlist.d/bh-7260-pm-flesh.json")" = pm-flesh-launch.sh ]'

# K1: through the real cmd-run-script: started, then the detached run is done.
reset; P=pk1; ID=idea-k1; seed_idea $P $ID; flesh_signals $P
lrun bash "$H/bin/cmd-run-script.sh" $P "$(jq -nc --arg p $P --arg i $ID '{script:"pm-flesh-launch.sh", args:[$p, $i]}')" 91
eq "K1 run_script rc 0 ($OUT $(head -c 300 "$T/lerr"))" "$RC" 0
eq "K1 run_script result ok" "$(lj .result)" ok
eq "K1 the launcher answered started" "$(jq -r .result <<<"$(lj .tail)" 2>/dev/null)" started
check "K1 the detached run finished in 60 s" 'wait_done $P $ID'
eq "K1 the run rc 0" "$(logf rc)" 0
eq "K1 one agent call" "$(calls)" 1
eq "K1 one pm_runs row, done" "$(nruns $P)/$(rf $P status)" 1/done
eq "K1 its cost is this run's rows only" "$(rf $P cost_usd)" 0.75

# K2: the refusals. Nothing starts, no call.
reset; P=pk1
lrun bash "$LAUNCH" $P --force
eq "K2a an id that starts with - is refused (rc 3)" "$RC/$(lj .result)" 3/refused
lrun bash "$LAUNCH" $P 'a/b'
eq "K2b an id with / is refused (rc 3)" "$RC/$(lj .result)" 3/refused
lrun bash "$LAUNCH" nope idea-x
eq "K2c a project not in fleet.conf is refused (rc 3)" "$RC/$(lj .result)" 3/refused
lrun bash "$LAUNCH" $P idea-x --force
eq "K2d a third arg is usage (rc 2)" "$RC/$(lj .result)" 2/usage
lrun bash "$LAUNCH" $P
eq "K2e one arg is usage (rc 2)" "$RC/$(lj .result)" 2/usage
lrun bash "$H/bin/cmd-run-script.sh" $P '{"script":"pm-flesh.sh","args":["pk1","idea-x"]}' 92
eq "K2f run_script refuses pm-flesh.sh itself (not on the allowlist)" "$RC/$(lj .result)" 3/refused

# K3: the product lock is held: busy, nothing starts.
reset; P=pk2; ID=idea-k3; seed_idea $P $ID; mkdir -p "$H/locks"
exec 6>"$H/locks/$P-product.lock"; flock -n 6
lrun bash "$LAUNCH" $P $ID
eq "K3 busy, rc 0" "$RC/$(lj .result)" 0/busy
sleep 1
eq "K3 no call" "$(calls)" 0
eq "K3 no pm_runs row" "$(nruns $P)" 0
exec 6>&-
eq "K2/K3 no agent call on any refused or busy launch" "$(calls)" 0

# ═════ the negatives over the whole suite ════════════════════════════════════
eq "L2/F9 no post-proposal or run-build call in the whole suite" "$(n "$T/forbidden.log")" 0
eq "L2/F9 no gh or non-worker curl call in the whole suite" "$(n "$T/net.log")" 0

# ═════ the seam test of BH-7258 and the node suites of this ticket ══════════
HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/pm-signals.bh-7258-test.sh" > "$T/pm-signals.txt" 2>&1
rc=$?; eq "tests/pm-signals.bh-7258-test.sh rc ($(tail -1 "$T/pm-signals.txt"))" "$rc" 0
( cd "$DIR/worker/jobs" && TMPDIR="$NT" node --test test/pm-runs.bh-7260.test.js ) > "$T/node-w.txt" 2>&1
rc=$?; eq "worker/jobs/test/pm-runs.bh-7260.test.js rc ($(grep -E '^# (pass|fail)' "$T/node-w.txt" | tr '\n' ' '))" "$rc" 0
[ "$rc" = 0 ] || grep -E '^not ok' "$T/node-w.txt"
if [ -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  ( cd "$DIR/console-ui" && node --test tests/roadmap-flesh.bh-7260.test.js ) > "$T/node-c.txt" 2>&1
  rc=$?; eq "console-ui/tests/roadmap-flesh.bh-7260.test.js rc ($(grep -E '^# (pass|fail)' "$T/node-c.txt" | tr '\n' ' '))" "$rc" 0
  [ "$rc" = 0 ] || grep -E '^not ok' "$T/node-c.txt"
else
  echo "pm-flesh: console-ui/tests/roadmap-flesh.bh-7260.test.js SKIPPED — console-ui has no node_modules (npm ci in console-ui)"
fi

echo "pm-flesh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
