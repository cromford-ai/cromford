#!/bin/bash
# tests/lesson-classify.bh-5915-test.sh — BH-5915: a lead report cut at the
# worker's 4000-unit artifact cap is classified from the full copy on the hub
# (job_transcripts, source lead_report), and `bin/lesson-classify.sh
# --requeue-truncated` re-opens the verdicts the lane parked for that cut.
# Drives the SHIPPED bin/lesson-classify.sh against the REAL worker routes
# (block-findings.js, block-classify-reset.js, transcripts.js, model-routes.js)
# over a node:sqlite file built from the REAL jobs schema.
#
# WHAT IS STUBBED. bin/agent-call.sh (it counts calls, keeps each prompt and
# answers from $FXT/answer), GET /api/jobs/<job>/artifacts (the report from
# $FXT/report.<job>.md, cut to its first 4000 units with truncated:true when
# $FXT/trunc.<job> exists), GET /api/jobs/<job> and GET /api/settings. Fault
# switches: $FXT/idx404 and $FXT/idx503 (the transcripts index), $FXT/body503
# (one transcript body), $FXT/noreset (the reset route is not deployed) and
# $FXT/reset503.<verdict> (one reset answers 503).
#
# Sections: F (the lane reads the hub copy), Q (the one-shot), E (the ticket's
# end-to-end case), M (no model literal), then the worker's node suite.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-classify.bh-5915-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "lesson-classify-5915: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/lesson-classify.sh"
RESET_ROUTE="$DIR/worker/jobs/src/routes/block-classify-reset.js"
for f in "$LANE" "$RESET_ROUTE"; do [ -f "$f" ] && ok || bad "missing $f"; done
if [ ! -f "$LANE" ]; then
  echo "lesson-classify-5915: $PASS passed, $FAIL failed"; exit 1
fi
check "M1 no hardcoded model string in the lane" '! grep -nE "claude-(opus|sonnet|haiku|fable)|grok-[0-9]" "$LANE"'

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "lesson-classify-5915: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "lesson-classify-5915: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "lesson-classify-5915: lane sections SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
  echo "lesson-classify-5915: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { nowIso } from '$DIR/worker/jobs/src/lib/http.js';
import { routes as bf } from '$DIR/worker/jobs/src/routes/block-findings.js';
import { routes as tr } from '$DIR/worker/jobs/src/routes/transcripts.js';
import { routes as mr } from '$DIR/worker/jobs/src/routes/model-routes.js';
// A missing reset route answers as an undeployed one (404), so the lane
// sections still run and say what is missing.
const rs = existsSync('$RESET_ROUTE') ? (await import('$RESET_ROUTE')).routes : [];
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
let body = null;
if (bodyFile) { try { body = JSON.parse(readFileSync(bodyFile, 'utf8')); } catch { body = null; } }
if (method === 'GET' && path === '/api/settings') out(200, { settings: [] });
const jobm = path.match(/^\/api\/jobs\/([^/]+)$/);
if (method === 'GET' && jobm) out(200, { job: { id: jobm[1], beat_box: 'box-small' } });
const art = path.match(/^\/api\/jobs\/([^/]+)\/artifacts$/);
if (method === 'GET' && art) {
  const f = T + '/report.' + art[1] + '.md';
  if (!existsSync(f)) out(200, { artifacts: [] });
  const full = readFileSync(f, 'utf8');
  // The worker's artifact cap: the detail keeps the first 4000 UTF-16 units.
  if (existsSync(T + '/trunc.' + art[1])) {
    out(200, { artifacts: [{ artifact_kind: 'lead_review_report', detail: JSON.stringify({ body: full.slice(0, 4000), truncated: true, path: '/root/harness/state/lead-reviews/x.md' }) }] });
  }
  out(200, { artifacts: [{ artifact_kind: 'lead_review_report', detail: JSON.stringify({ body: full, truncated: false }) }] });
}
if (method === 'GET' && /^\/api\/jobs\/[^/]+\/transcripts$/.test(path)) {
  if (existsSync(T + '/idx404')) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
  if (existsSync(T + '/idx503')) out(503, { error: 'd1 unavailable' });
}
if (method === 'GET' && /^\/api\/jobs\/[^/]+\/transcript$/.test(path) && existsSync(T + '/body503')) out(503, { error: 'd1 unavailable' });
if (path === '/api/block-classify/reset') {
  if (existsSync(T + '/noreset')) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
  if (body && existsSync(T + '/reset503.' + body.verdict_id)) out(503, { error: 'd1 unavailable' });
}
const db = new DatabaseSync(T + '/d1.sqlite');
const hit = matchRoute([...bf, ...rs, ...tr, ...mr], method, path);
if (!hit) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
const res = await hit.handler({ env: { DB: d1(db) }, url, path, t: nowIso(), body, m: hit.m });
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
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
export FXT="$T" NODE_NO_WARNINGS=1
if node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err"; then ok
else bad "S1 schema.sql applies: $(head -3 "$T/mkdb.err")"; fi
q() { node "$T/q.mjs" "$@"; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog" "$H/env" "$H/logs" "$H/flags" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp "$DIR/catalog/lanes.json" "$H/catalog/"
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/alert-line.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$*" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
n=$(grep -c . "$FXT/agentcalls")
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
cat "$FXT/answer" > "$5"
exit 0
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh"

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
      printf '%s %s %s\n' "$method" "${url#"$JOBS_URL"}" "$(head -c 300 "$bf")" >> "$FXT/reqlog"
    else
      printf '%s %s\n' "$method" "${url#"$JOBS_URL"}" >> "$FXT/reqlog"
    fi
    node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
# gh: the lane reads a verdict's PR for its ticket; here every PR read is a
# 404 (no ticket), logged to gh.log. Anything else is unexpected (net.log).
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"api -i -X GET repos/example-org/cromford/pulls/"[0-9]*)
    printf 'gh %s\n' "$*" >> "$FXT/gh.log"; restpr --raw 404 '{"message":"Not Found"}'; exit 0 ;;
esac
printf 'gh %s\n' "$*" >> "$FXT/net.log"; exit 7
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=test-fixture-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0
unset LESSON_CLASSIFY_ENABLED LESSON_CLASSIFY_MAX_PER_TICK LESSON_CLASSIFY_TIMEOUT_S 2>/dev/null || true

SHA=$(printf 'b%.0s' $(seq 40))
reset() {
  local p
  for p in reqlog agentcalls alerts.log net.log gh.log out rc answer idx404 idx503 body503 noreset; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/prompt.* "$T"/report.*.md "$T"/trunc.* "$T"/reset503.* "$T"/full.*.md
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
}
run() { # run [VAR=value ...] [-- lane args]
  local -a envs=() args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; args=("$@"); break ;; *) envs+=("$1"); shift ;; esac
  done
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 "${envs[@]}" bash "$H/bin/lesson-classify.sh" "${args[@]}" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls() { n "$T/agentcalls"; }
reqs()  { local c; c=$(grep -c "$1" "$T/reqlog" 2>/dev/null); printf '%s' "${c:-0}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
verdict() { # verdict <pr> <job> -> the new verdicts.id
  q "INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at) VALUES ('example-org/cromford', ?, ?, 'BLOCK', 'lead', 'mac-lead', ?, ?, ?)" \
    "$1" "$SHA" "https://github.com/example-org/cromford/pull/$1" "lead-review:r$1 lead-job:$2" "$(now_iso)" | jq -r '.[0].id'
}
run_fld() { q "SELECT * FROM block_classify_runs WHERE verdict_id = ?" "$1" | jq -r --arg f "$2" '.[0][$f] // "null" | tostring'; }
findings() { q "SELECT count(*) n FROM block_findings WHERE verdict_id = ?" "$1" | jq -r '.[0].n'; }
marker() { [ -e "$H/state/lesson-classify/parked-$1" ]; }
LOG() { cat "$H/logs/lesson-classify.log" 2>/dev/null; }

# bigreport <job> <pr> [title-sha] [tag-suffix]: a lead report the way
# bin/lead-review.sh heads it, with 8 BLOCK items TAG-1..TAG-8, each padded to
# about 1500 units, so the whole is over 12000 units and items 5 to 8 start
# after unit 4000 (the artifact cap). Written to $T/full.<job>.md.
bigreport() {
  local job="$1" pr="$2" tsha="${3:-$SHA}" sfx="${4:-}" i pad
  pad=$(printf 'pad %.0s' $(seq 370))
  {
    printf '# Lead review lr-%s-%s (example-org/cromford#%s at %s)\n\nVerdict: BLOCK\n\n' "$pr" "${tsha:0:12}" "$pr" "$tsha"
    for i in 1 2 3 4 5 6 7 8; do
      printf -- '- [BLOCK] bin/f%s.sh:1: TAG-%s%s finding %s %s\n' "$i" "$i" "$sfx" "$i" "$pad"
    done
  } > "$T/full.$job.md"
}
# cut <job> <pr>: the artifact for <job> is the 12000-unit report, cut at 4000.
cut() { bigreport "$1" "$2"; cp "$T/full.$1.md" "$T/report.$1.md"; : > "$T/trunc.$1"; }
job_row() {
  q "INSERT INTO jobs (id, project, kind, box, stage, status, created_at, updated_at) VALUES (?, 'cromford', 'lead_review', 'box-small', 'done', 'done', ?, ?)" "$1" "$(now_iso)" "$(now_iso)" >/dev/null
}
# push <job> <file> [attempt] [truncated]: the full report through the REAL
# POST /api/jobs/<job>/transcript route, in the shape bin/transcript-push.sh
# sends for source lead_report (no phase, attempt 100).
push() {
  local b; b=$(mktemp "$T/push.XXXXXX")
  jq -n --rawfile b "$2" --argjson a "${3:-100}" --argjson t "${4:-0}" \
    '{body: $b, actor: "box-small", stage: "lead-review", runner: "pipeline", source: "lead_report", attempt: $a, truncated: $t}' > "$b"
  curl -sS -X POST --data-binary "@$b" "$JOBS_URL/api/jobs/$1/transcript" | tail -1
  rm -f "$b"
}
ANS8='{"findings":[{"n":1,"category":"other","confidence":0.5,"cause":"c1","infra_false":false},{"n":2,"category":"other","confidence":0.5,"cause":"c2","infra_false":false},{"n":3,"category":"other","confidence":0.5,"cause":"c3","infra_false":false},{"n":4,"category":"other","confidence":0.5,"cause":"c4","infra_false":false},{"n":5,"category":"other","confidence":0.5,"cause":"c5","infra_false":false},{"n":6,"category":"other","confidence":0.5,"cause":"c6","infra_false":false},{"n":7,"category":"other","confidence":0.5,"cause":"c7","infra_false":false},{"n":8,"category":"other","confidence":0.5,"cause":"c8","infra_false":false}]}'

# ═════ the fixture is what the ticket asks for ═══════════════════════════════
reset
bigreport jx 600
eq "S2 the fixture has 8 BLOCK items" "$(grep -c '^- \[BLOCK\]' "$T/full.jx.md")" 8
check "S2 the fixture is over 12000 units" '[ "$(wc -c < "$T/full.jx.md")" -ge 12000 ]'
check "S2 item 5 starts after unit 4000" '[ "$(head -c 4000 "$T/full.jx.md" | grep -c "TAG-5")" = 0 ]'

# ═════ F1: a cut artifact + the full lead_report row -> classified from it ═══
reset
cut j1 601; job_row j1
eq "F1 the full report is stored through the real route" "$(push j1 "$T/full.j1.md")" 200
V1=$(verdict 601 j1)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F1 rc 0" "$(cat "$T/rc")" 0
eq "F1 one model call" "$(calls)" 1
check "F1 the prompt holds TAG-8 (past the cut)" 'grep -q "TAG-8" "$T/prompt.1"'
eq "F1 the run is ok" "$(run_fld "$V1" status)" ok
eq "F1 8 findings rows" "$(findings "$V1")" 8
check "F1 not parked" '! marker "$V1"'
check "F1 the log says where the text came from" \
  'LOG | grep -qE "verdict $V1: the artifact is cut; classified from the full report on the hub \(job j1, source lead_report, [0-9]+B\)"'

# ═════ F2: two lead_report rows -> the newest is used ════════════════════════
reset
cut j2 602; job_row j2
bigreport j2old 602 "$SHA" -OLD; bigreport j2new 602 "$SHA" -NEW
push j2 "$T/full.j2old.md" 100 >/dev/null; push j2 "$T/full.j2new.md" 101 >/dev/null
V2=$(verdict 602 j2)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F2 one call" "$(calls)" 1
check "F2 the newest row's tag is in the prompt" 'grep -q "TAG-8-NEW" "$T/prompt.1" && ! grep -q "TAG-8-OLD" "$T/prompt.1"'
eq "F2 ok" "$(run_fld "$V2" status)" ok

# ═════ F3: the transcripts index answers 404 -> parked as before, (absent) ═══
reset
cut j3 603; : > "$T/idx404"
V3=$(verdict 603 j3)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F3 no call" "$(calls)" 0
eq "F3 failed, attempt refunded" "$(run_fld "$V3" status)/$(run_fld "$V3" attempts)" failed/0
check "F3 parked" 'marker "$V3"'
check "F3 the error names the cap and (absent)" \
  'run_fld "$V3" error | grep -q "4000-unit artifact cap.*no full copy on the hub (absent)"'
check "F3 the log line keeps its prefix and adds the reason" \
  'LOG | grep -q "verdict $V3: the lead report is truncated at the artifact cap (request r603, job j3, box box-small, path .*); parked, not classified; no full copy on the hub (absent)"'

# ═════ F4: the ledger kept only the tail -> parked, (tail-only) ═════════════
reset
cut j4 604; job_row j4
push j4 "$T/full.j4.md" 100 1 >/dev/null
V4=$(verdict 604 j4)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F4 no call" "$(calls)" 0
check "F4 parked" 'marker "$V4"'
check "F4 the error says tail-only" 'run_fld "$V4" error | grep -q "(tail-only)"'

# ═════ F5: the stored copy is for another head -> parked, (title-mismatch) ═══
reset
cut j5 605; job_row j5
bigreport j5other 605 "$(printf 'c%.0s' $(seq 40))"
push j5 "$T/full.j5other.md" >/dev/null
V5=$(verdict 605 j5)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F5 no call" "$(calls)" 0
check "F5 parked" 'marker "$V5"'
check "F5 the error says title-mismatch" 'run_fld "$V5" error | grep -q "(title-mismatch)"'

# ═════ F6: the index answers 503 -> refunded, NOT parked; healthy next tick ok
reset
cut j6 606; job_row j6
push j6 "$T/full.j6.md" >/dev/null
V6=$(verdict 606 j6)
printf '%s\n' "$ANS8" > "$T/answer"
: > "$T/idx503"
run
eq "F6 no call" "$(calls)" 0
eq "F6 failed, attempt refunded" "$(run_fld "$V6" status)/$(run_fld "$V6" attempts)" failed/0
check "F6 not parked" '! marker "$V6"'
check "F6 the log says the next tick retries" \
  'LOG | grep -q "verdict $V6: the full report of job j6 could not be read (unreadable); not parked, the next tick retries"'
check "F6 no ALERTS line" '[ ! -e "$H/logs/ALERTS.log" ]'
# The same with the index healthy and the body read failing (a row listed).
scratch_rm "$T/idx503" || exit 1; : > "$T/body503"
run
eq "F6b body read fails: still no call" "$(calls)" 0
check "F6b still not parked" '! marker "$V6"'
scratch_rm "$T/body503" || exit 1
run
eq "F6 the healthy tick classifies it" "$(run_fld "$V6" status)" ok
eq "F6 one call in all" "$(calls)" 1

# ═════ F7: a report that fits -> the transcripts path is never asked ════════
reset
bigreport j7 607; head -c 3000 "$T/full.j7.md" > "$T/report.j7.md"; echo >> "$T/report.j7.md"
V7=$(verdict 607 j7)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "F7 one call" "$(calls)" 1
eq "F7 no transcripts request" "$(reqs '/transcript')" 0
eq "F7 ok" "$(run_fld "$V7" status)" ok

# ═════ Q: the one-shot --requeue-truncated ══════════════════════════════════
# The parks are made by the lane itself: two cut reports with no hub copy, and
# one lead BLOCK whose job has no report artifact at all.
qsetup() {
  reset
  cut jq1 611; cut jq2 612
  QA=$(verdict 611 jq1); QB=$(verdict 612 jq2); QC=$(verdict 613 jq-none)
  printf '%s\n' "$ANS8" > "$T/answer"
  run
  : > "$T/reqlog"; rm -f "$H/logs/lesson-classify.log"
}
qsetup
check "Q0 the lane parked all three" 'marker "$QA" && marker "$QB" && marker "$QC"'
check "Q0 the third is parked for another reason" 'run_fld "$QC" error | grep -q "no lead_review_report"'
eq "Q0 no call" "$(calls)" 0

run -- --requeue-truncated
eq "Q1 rc 0" "$(cat "$T/rc")" 0
check "Q1 the summary on stdout" 'grep -qx "requeue-truncated: parked=3 requeued=2 kept=1 errors=0" "$T/out"'
check "Q1 the two cap-parked markers are gone" '! marker "$QA" && ! marker "$QB"'
check "Q1 the other marker stays" 'marker "$QC"'
eq "Q1 exactly one requeue-truncated log line" "$(LOG | grep -c 'requeue-truncated:')" 1
check "Q1 the log line carries the counts" 'LOG | grep -q "requeue-truncated: parked=3 requeued=2 kept=1 errors=0"'
eq "Q1 two rows carry the requeued: prefix" "$(q "SELECT count(*) n FROM block_classify_runs WHERE error LIKE 'requeued: %'" | jq -r '.[0].n')" 2
eq "Q1 the reset runs are at attempt 0" "$(run_fld "$QA" attempts)/$(run_fld "$QB" attempts)" 0/0
check "Q1 no ALERTS line" '[ ! -e "$H/logs/ALERTS.log" ] && [ ! -e "$T/alerts.log" ]'
eq "Q1 no model call, no claim" "$(calls)/$(reqs '/api/block-classify/claim')" 0/0

run -- --requeue-truncated
eq "Q5 a second run: rc 0" "$(cat "$T/rc")" 0
check "Q5 a second run: nothing more to requeue" 'grep -qx "requeue-truncated: parked=1 requeued=0 kept=1 errors=0" "$T/out"'

# Q2: a tick holds the lock -> rc 1, nothing removed, no request.
qsetup
mkdir -p "$H/locks"
exec 8>"$H/locks/lesson-classify.lock"
flock -n 8 || bad "Q2 the test could not take the lock"
run -- --requeue-truncated
exec 8>&-
eq "Q2 rc 1" "$(cat "$T/rc")" 1
check "Q2 says the lock is held" 'grep -q "requeue-truncated: a lesson-classify tick holds the lock; run it again" "$T/out"'
check "Q2 every marker stays" 'marker "$QA" && marker "$QB" && marker "$QC"'
eq "Q2 no request" "$(n "$T/reqlog")" 0

# Q3: the route is not deployed -> rc 1, nothing removed.
: > "$T/noreset"
run -- --requeue-truncated
eq "Q3 rc 1" "$(cat "$T/rc")" 1
check "Q3 says the route is not answering" 'grep -q "requeue-truncated: POST /api/block-classify/reset is not answering (http 404); nothing removed" "$T/out"'
check "Q3 every marker stays" 'marker "$QA" && marker "$QB" && marker "$QC"'
eq "Q3 only the probe was sent" "$(reqs '/api/block-classify/reset')" 1
scratch_rm "$T/noreset" || exit 1

# Q4: one reset answers 503 -> that marker stays, errors=1, rc 1.
: > "$T/reset503.$QB"
run -- --requeue-truncated
eq "Q4 rc 1" "$(cat "$T/rc")" 1
check "Q4 the counts" 'grep -qx "requeue-truncated: parked=3 requeued=1 kept=1 errors=1" "$T/out"'
check "Q4 the failed one stays, the good one is gone" 'marker "$QB" && ! marker "$QA"'
eq "Q4 the 503 run is not reset" "$(run_fld "$QB" attempts)" 0
check "Q4 its error has no requeued: prefix" '! run_fld "$QB" error | grep -q "^requeued:"'
check "Q4 no ALERTS line" '[ ! -e "$H/logs/ALERTS.log" ]'

# Q6: an unknown argument -> usage, rc 2, no request.
: > "$T/reqlog"
run -- --nope
eq "Q6 rc 2" "$(cat "$T/rc")" 2
check "Q6 usage" 'grep -q "usage: lesson-classify.sh \[--requeue-truncated\]" "$T/out"'
eq "Q6 no request" "$(n "$T/reqlog")" 0

# ═════ E1: the ticket's case, end to end ════════════════════════════════════
# A 12000-unit report is cut; the first tick finds no hub copy and parks the
# verdict. The full report is then stored through the real route, the one-shot
# re-opens the run, and the next tick classifies it from the full report.
reset
cut je 620; job_row je
VE=$(verdict 620 je)
printf '%s\n' "$ANS8" > "$T/answer"
run
eq "E1 tick 1: no call" "$(calls)" 0
check "E1 tick 1: parked for the cap, no copy" 'marker "$VE" && run_fld "$VE" error | grep -q "4000-unit artifact cap.*(absent)"'
eq "E1 the backfill stores the full report" "$(push je "$T/full.je.md")" 200
run
eq "E1 a tick before the one-shot leaves it parked" "$(calls)" 0
run -- --requeue-truncated
eq "E1 one-shot rc 0" "$(cat "$T/rc")" 0
check "E1 the marker is gone" '! marker "$VE"'
eq "E1 the run is re-opened" "$(run_fld "$VE" status)/$(run_fld "$VE" attempts)" failed/0
check "E1 the error is prefixed" 'run_fld "$VE" error | grep -q "^requeued: "'
run
eq "E1 tick 2: one call" "$(calls)" 1
eq "E1 tick 2: ok" "$(run_fld "$VE" status)" ok
eq "E1 8 findings" "$(findings "$VE")" 8
check "E1 finding 8's text holds TAG-8" \
  '[ "$(q "SELECT text FROM block_findings WHERE verdict_id=? AND n=8" "$VE" | jq -r ".[0].text" | grep -c "TAG-8 ")" = 1 ]'
check "E1 the log says it read the hub copy" 'LOG | grep -q "verdict $VE: the artifact is cut; classified from the full report on the hub (job je"'
check "E1 no network outside the stub worker" '[ ! -s "$T/net.log" ]'

# ═════ the worker half, as its own node suite ════════════════════════════════
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/block-classify-reset.bh-5915.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/block-classify-reset.bh-5915.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30; fi

echo "lesson-classify-5915: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
