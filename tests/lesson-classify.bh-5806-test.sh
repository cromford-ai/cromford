#!/bin/bash
# tests/lesson-classify.bh-5806-test.sh — BH-5806 (BH-5794.1): classify every
# BLOCK. Drives the SHIPPED bin/lesson-classify.sh against the REAL worker
# routes (worker/jobs/src/routes/block-findings.js and model-routes.js) over a
# node:sqlite file built from the REAL jobs schema (composed from schema.d/).
#
# WHAT IS STUBBED. bin/agent-call.sh (it counts calls and answers from
# $FXT/answer with rc $FXT/ac.rc), GET /api/jobs/<job>/artifacts (the lead
# report from $FXT/report.<job>.md) and GET /api/settings (empty). Nothing here
# reaches a model, GitHub or the real worker.
#
# Sections: C1-C8 (the ticket's acceptance and the negatives), M (no model
# literal), then the worker's own node suite.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lesson-classify.bh-5806-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "lesson-classify: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE="$DIR/bin/lesson-classify.sh"
ROUTE="$DIR/worker/jobs/src/routes/block-findings.js"
for f in "$LANE" "$ROUTE" "$DIR/catalog/lanes.d/lesson-classify.json" "$DIR/cron/lanes/727-lesson-classify.cron"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$LANE" ] || [ ! -f "$ROUTE" ]; then
  echo "lesson-classify: $PASS passed, $FAIL failed"; exit 1
fi
check "M1 no hardcoded model string in the lane" '! grep -nE "claude-(opus|sonnet|haiku|fable)|grok-[0-9]" "$LANE"'
check "R1 cron: hourly at minute 23, behind the hub lease" \
  'grep -qE "^23 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/lesson-classify.sh " "$DIR/cron/lanes/727-lesson-classify.cron"'

if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "lesson-classify: lane sections SKIPPED — node with node:sqlite is not installed on this box"
  echo "lesson-classify: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi
if [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "lesson-classify: lane sections SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
  echo "lesson-classify: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# ═════ the worker driver: the REAL route handlers over a sqlite file ═════════
cat > "$T/wdrv.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync, existsSync } from 'node:fs';
import { d1 } from '$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js';
import { matchRoute } from '$DIR/worker/jobs/src/lib/router.js';
import { nowIso } from '$DIR/worker/jobs/src/lib/http.js';
import { routes as bf } from '$ROUTE';
import { routes as mr } from '$DIR/worker/jobs/src/routes/model-routes.js';
const [method, pathq, bodyFile] = process.argv.slice(2);
const T = process.env.FXT;
const out = (code, body) => { process.stdout.write(JSON.stringify(body) + '\n' + code); process.exit(0); };
const url = new URL('https://jobs.test' + pathq);
const path = url.pathname;
if (method === 'GET' && path === '/api/settings') out(200, { settings: [] });
const jobm = path.match(/^\/api\/jobs\/([^/]+)$/);
if (method === 'GET' && jobm) out(200, { job: { id: jobm[1], beat_box: 'box-small' } });
const art = path.match(/^\/api\/jobs\/([^/]+)\/artifacts$/);
if (method === 'GET' && art) {
  const f = T + '/report.' + art[1] + '.md';
  if (!existsSync(f)) out(200, { artifacts: [] });
  // A job with a trunc.<job> file plays a report the worker cut at its cap:
  // the body is its first BLOCK only, truncated is true, path is that file's text.
  const tf = T + '/trunc.' + art[1];
  if (existsSync(tf)) {
    const full = readFileSync(f, 'utf8');
    const cut = full.slice(0, full.indexOf('- [BLOCK] tests/'));
    out(200, { artifacts: [{ artifact_kind: 'lead_review_report', detail: JSON.stringify({ body: cut, truncated: true, path: readFileSync(tf, 'utf8').trim() }) }] });
  }
  out(200, { artifacts: [{ artifact_kind: 'lead_review_report', detail: JSON.stringify({ body: readFileSync(f, 'utf8'), truncated: false }) }] });
}
const db = new DatabaseSync(T + '/d1.sqlite');
const hit = matchRoute([...bf, ...mr], method, path);
if (!hit) out(404, { error: 'unknown endpoint', worker: 'harness-jobs' });
let body = null;
if (bodyFile) { try { body = JSON.parse(readFileSync(bodyFile, 'utf8')); } catch { body = null; } }
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
const sql = readFileSync('$DIR/worker/jobs/schema.sql', 'utf8');
db.exec(sql);
db.exec(sql);
JS
export FXT="$T" NODE_NO_WARNINGS=1
if node "$T/mkdb.mjs" "$T/d1.template.sqlite" 2> "$T/mkdb.err"; then ok
else bad "S1 schema.sql applies twice: $(head -3 "$T/mkdb.err")"; fi
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
# argv | lane | role | fp
printf '%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_ROLE:-}" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
n=$(grep -c . "$FXT/agentcalls")
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.$n" ;; esac
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
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
# gh: the PR read the lane makes for a verdict's ticket (repos/<repo>/pulls/<n>)
# answers from $FXT/prs/<n>.json and is logged to gh.log; anything else is
# unexpected network (net.log, exit 7).
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"api -i -X GET repos/example-org/cromford/pulls/"[0-9]*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    printf 'gh %s\n' "$*" >> "$FXT/gh.log"
    if [ -f "$FXT/prs/$n.json" ]; then restpr --raw 200 "$(cat "$FXT/prs/$n.json")"; else restpr --raw 404 '{"message":"Not Found"}'; fi
    exit 0 ;;
esac
printf 'gh %s\n' "$*" >> "$FXT/net.log"; exit 7
SH
chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
export HARNESS="$H" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=test JOBS_RETRIES=0
unset LESSON_CLASSIFY_ENABLED LESSON_CLASSIFY_MAX_PER_TICK LESSON_CLASSIFY_TIMEOUT_S 2>/dev/null || true

reset() {
  local p
  for p in reqlog agentcalls alerts.log net.log gh.log out rc ac.rc answer; do
    scratch_rm "$T/$p" || exit 1
  done
  rm -f "$T"/prompt.* "$T"/report.*.md "$T"/trunc.*
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1
  rm -f "$H/logs/"*
  cp "$T/d1.template.sqlite" "$T/d1.sqlite"
  : > "$T/reqlog"
}
run() {
  env HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 "$@" bash "$H/bin/lesson-classify.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }
calls() { n "$T/agentcalls"; }
claims() { local c; c=$(grep -c '^POST /api/block-classify/claim ' "$T/reqlog" 2>/dev/null); printf '%s' "${c:-0}"; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# verdict <pr> <note> [source] -> the new verdicts.id
verdict() {
  q "INSERT INTO verdicts (repo, pr, head_sha, verdict, source, reviewer, report_url, note, created_at) VALUES ('example-org/cromford', ?, ?, 'BLOCK', ?, 'mac-lead', ?, ?, ?)" \
    "$1" "$(printf 'b%.0s' $(seq 40))" "${3:-lead}" "https://github.com/example-org/cromford/pull/$1" "$2" "$(now_iso)" | jq -r '.[0].id'
}
run_row() { q "SELECT * FROM block_classify_runs WHERE verdict_id = ?" "$1" | jq -c '.[0] // {}'; }
run_fld() { run_row "$1" | jq -r --arg f "$2" '.[$f] // "null" | tostring'; }
findings() { q "SELECT count(*) n FROM block_findings WHERE verdict_id = ?" "$1" | jq -r '.[0].n'; }

report() { # report <job> <pr>: a lead report with 3 BLOCKs and 1 NOTE, headed the
  # way bin/lead-review.sh heads it (lr-<pr>-<sha12>); its PR is on ticket/bh-9001.
  local sha; sha=$(printf 'b%.0s' $(seq 40))
  mkdir -p "$T/prs"
  jq -nc --arg n "$2" '{number: ($n | tonumber), title: "fix the thing", head: {ref: "ticket/bh-9001"}}' > "$T/prs/$2.json"
  cat > "$T/report.$1.md" <<EOF
# Lead review lr-$2-${sha:0:12} (example-org/cromford#$2 at $sha)

Verdict: BLOCK

- [BLOCK] bin/lead-review-land.sh:120: the summary drops skipped_rebase, so the doorbell suite reads the wrong field
- [BLOCK] tests/foo.bh-9001-test.sh:14: the test copies bin/lib/x.sh into the scratch tree by hand
  and the closure lint goes red
- [NOTE] docs/notes/x.md:1: a typo
- [BLOCK] worker/jobs/schema.sql:4400: a CREATE TABLE with no doc line
EOF
}
ANS3='{"findings":[{"n":1,"category":"ci-tests-skipped","confidence":0.7,"cause":"summary field dropped","infra_false":false},{"n":2,"category":"test-hand-copies-lib","confidence":0.9,"cause":"hand-copied lib","infra_false":false},{"n":3,"category":"no-such-bucket","confidence":0.4,"cause":"doc line missing","infra_false":false}]}'

# ═════ C1: a BLOCK verdict with 3 findings writes 3 rows ═════════════════════
reset
report j1 501
V1=$(verdict 501 "lead-review:r1 lead-job:j1")
printf '%s\n' "$ANS3" > "$T/answer"
run
check "C1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "C1 one model call" "$(calls)" 1
eq "C1 3 findings rows" "$(findings "$V1")" 3
eq "C1 the run is ok" "$(run_fld "$V1" status)" ok
eq "C1 one attempt" "$(run_fld "$V1" attempts)" 1
check "C1 the claim came before the call" \
  '[ "$(grep -n "^POST /api/block-classify/claim " "$T/reqlog" | head -1 | cut -d: -f1)" -lt "$(grep -n "^POST /api/block-classify/settle " "$T/reqlog" | head -1 | cut -d: -f1)" ]'
eq "C1 finding 2's files come from the text, not the model" \
  "$(q "SELECT files FROM block_findings WHERE verdict_id=? AND n=2" "$V1" | jq -r '.[0].files')" '["tests/foo.bh-9001-test.sh","bin/lib/x.sh"]'
eq "C1 finding 2 keeps its continuation line" \
  "$(q "SELECT text FROM block_findings WHERE verdict_id=? AND n=2" "$V1" | jq -r '.[0].text' | grep -c 'closure lint')" 1
eq "C1 an unknown bucket is stored as other" \
  "$(q "SELECT category || '/' || raw_category AS c FROM block_findings WHERE verdict_id=? AND n=3" "$V1" | jq -r '.[0].c')" other/no-such-bucket
# TEST-CHANGE (lead review of fd7dde5e): the fixture used to head the report
# "# Lead review BH-9001", which bin/lead-review.sh never writes. Real reports are
# headed lr-<pr>-<sha12>, so the ticket now comes from the PR's branch.
eq "C1 the ticket comes from the PR's ticket branch" "$(q "SELECT DISTINCT ticket FROM block_findings WHERE verdict_id=?" "$V1" | jq -r '.[0].ticket')" BH-9001
check "C1 the report heading is the real lr-<pr>-<sha12> form" 'grep -qE "^# Lead review lr-501-b{12} \(example-org/cromford#501 at b{40}\)$" "$T/report.j1.md"'
eq "C1 the NOTE is not a finding" "$(q "SELECT count(*) n FROM block_findings WHERE text LIKE '%typo%'" | jq -r '.[0].n')" 0
LINE1=$(head -1 "$T/agentcalls")
check "C1 agent-call: stage lesson-classify, lane lesson-classify, role lesson.classify, fp per verdict ($LINE1)" \
  'grep -qE "^lesson-classify fleet [^ ]+ [0-9]+ .*\|lesson-classify\|lesson.classify\|lesson-classify:$V1$" <<<"$LINE1"'
check "C1 the model is the lesson.classify route" 'grep -q "haiku" <<<"$LINE1"'
check "C1 the prompt lists the DB categories" 'grep -q "rp-suite-missing-at-head" "$T/prompt.1" && grep -q "^other" "$T/prompt.1"'
check "C1 the prompt carries the 3 numbered findings" 'grep -q "^1\. " "$T/prompt.1" && grep -q "^3\. " "$T/prompt.1" && ! grep -q "^4\. " "$T/prompt.1"'
check "C1 one summary line in the log" 'grep -qE "verdicts=1 classified=1 empty=0 failed=0 skipped=0 calls=1$" "$H/logs/lesson-classify.log"'
check "C1 no network outside the stub worker" '[ ! -s "$T/net.log" ]'

# ═════ C2: running the lane twice on the same verdict makes 0 new model calls ═
run
eq "C2 still one model call" "$(calls)" 1
eq "C2 still 3 rows" "$(findings "$V1")" 3
eq "C2 still one attempt" "$(run_fld "$V1" attempts)" 1
# Even a pending list that names it again (an operator replaying by hand)
# reaches the claim, and the claim refuses: still no call.
CL=$(curl -sS -X POST --data-binary "{\"verdict_id\":$V1}" "$JOBS_URL/api/block-classify/claim" | tail -1)
eq "C2 the ledger refuses a terminal verdict" "$CL" 409

# ═════ C3: an empty model answer is terminal `empty`, not retried ═══════════
reset
report j2 502
V2=$(verdict 502 "lead-review:r2 lead-job:j2")
printf '\n' > "$T/answer"
run
eq "C3 one call" "$(calls)" 1
eq "C3 status empty" "$(run_fld "$V2" status)" empty
eq "C3 no rows" "$(findings "$V2")" 0
run
eq "C3 rerun: no new call" "$(calls)" 1
printf '{"findings":[]}\n' > "$T/answer"
# TEST-CHANGE (lead review of 5d9dd371): each verdict has its own report,
# headed with its own repo#pr at head, as bin/lead-review.sh writes it; the
# lane now refuses a report for another PR (C14), so a shared job no longer fits.
report j2b 503
V2b=$(verdict 503 "lead-review:r2b lead-job:j2b")
run
eq "C3 an empty findings list is empty too" "$(run_fld "$V2b" status)" empty
eq "C3 two calls in all" "$(calls)" 2

# ═════ C4: no lesson.classify route -> no claim, no call ════════════════════
reset
report j1 504
V4=$(verdict 504 "lead-review:r4 lead-job:j1")
q "DELETE FROM model_routes WHERE role='lesson.classify'" >/dev/null
printf '%s\n' "$ANS3" > "$T/answer"
run
check "C4 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "C4 no call" "$(calls)" 0
eq "C4 no claim" "$(claims)" 0
eq "C4 no ledger row" "$(run_row "$V4")" '{}'

# ═════ C5: a verdict with no findings text -> empty, with no call ═══════════
reset
V5=$(verdict 505 "" box)
run
eq "C5 no call" "$(calls)" 0
eq "C5 status empty" "$(run_fld "$V5" status)" empty
check "C5 the run says why" 'grep -q "no findings text" <<<"$(run_fld "$V5" error)"'

# A builder-review (box) BLOCK carries its finding in the note: one row.
V5b=$(verdict 506 "bin/run-build.sh:12: the retry loop never ends" box)
printf '{"findings":[{"n":1,"category":"other","confidence":0.5,"cause":"retry loop","infra_false":false}]}\n' > "$T/answer"
run
eq "C5b one call for the box BLOCK" "$(calls)" 1
eq "C5b one row from the note" "$(findings "$V5b")" 1

# ═════ C6: agent-call refused (rc 74, nothing billed) -> failed, attempt refunded
reset
report j1 507
V6=$(verdict 507 "lead-review:r6 lead-job:j1")
echo 74 > "$T/ac.rc"
run
eq "C6 status failed" "$(run_fld "$V6" status)" failed
eq "C6 the attempt is refunded" "$(run_fld "$V6" attempts)" 0

# ═════ C7: a billed failure and an unparseable answer count; the cap stops it ═
reset
report j1 508
V7=$(verdict 508 "lead-review:r7 lead-job:j1")
echo 1 > "$T/ac.rc"
run
eq "C7 a billed failure is failed, attempt 1" "$(run_fld "$V7" status)/$(run_fld "$V7" attempts)" failed/1
scratch_rm "$T/ac.rc" || exit 1
printf 'I think these are about tests.\n' > "$T/answer"
run
eq "C7 an unparseable answer is failed, attempt 2" "$(run_fld "$V7" status)/$(run_fld "$V7" attempts)" failed/2
run
run
eq "C7 the cap (lesson_classify.max_attempts=3) stops the calls" "$(calls)" 3
eq "C7 attempts stop at 3" "$(run_fld "$V7" attempts)" 3

# ═════ C8: off switches and the per-tick cap ═════════════════════════════════
reset
report j1 509
report j8b 510
V8=$(verdict 509 "lead-review:r8 lead-job:j1")
V9=$(verdict 510 "lead-review:r9 lead-job:j8b")
printf '%s\n' "$ANS3" > "$T/answer"
run LESSON_CLASSIFY_ENABLED=0
# lane_env_apply reads the settings rows first (ENABLED may be one of them);
# after that, ENABLED=0 must stop the lane before any block-classify request.
eq "C8 ENABLED=0: no lane request" "$(grep -vc '^GET /api/settings' "$T/reqlog")" 0
run LESSON_CLASSIFY_MAX_PER_TICK=1
eq "C8 MAX_PER_TICK=1: one call" "$(calls)" 1
run LESSON_CLASSIFY_MAX_PER_TICK=1
eq "C8 the next tick takes the other" "$(calls)" 2
eq "C8 both ok" "$(run_fld "$V8" status)/$(run_fld "$V9" status)" ok/ok

# ═════ C9: a report the worker cut at its 4000-unit cap is never settled ok ══
# (lead reviews of 53154bc5 and fd7dde5e: 31 of 163 lead BLOCK reports are over
# the cap; the posted review is built from the same artifact, and the full
# report is only on the reviewing box, never on the hub.) Terminal and cheap:
# failed with a refund, parked, and the request id, box and path logged.
reset
report j9 511
echo "/root/harness/state/lead-reviews/lr-511-bbbbbbbbbbbb.md" > "$T/trunc.j9"
V9a=$(verdict 511 "lead-review:r9a lead-job:j9")
printf '%s\n' "$ANS3" > "$T/answer"
run
eq "C9 a truncated report: no model call" "$(calls)" 0
eq "C9 status failed, never ok" "$(run_fld "$V9a" status)" failed
eq "C9 the attempt is refunded (no call was made)" "$(run_fld "$V9a" attempts)" 0
eq "C9 no finding rows from a cut report" "$(findings "$V9a")" 0
check "C9 the run says the report was truncated" 'grep -q "truncated" <<<"$(run_fld "$V9a" error)"'
check "C9 the log names the request id, the box and the path" \
  'grep -q "verdict $V9a: .*truncated.*request r9a, job j9, box box-small, path /root/harness/state/lead-reviews/lr-511-bbbbbbbbbbbb.md" "$H/logs/lesson-classify.log"'
run
run
eq "C9 never claimed again (parked)" "$(claims)" 1
eq "C9 still no model call" "$(calls)" 0

# ═════ C13: a lead BLOCK whose report artifact is missing is never empty ════
# (lead review of 5d9dd371: rc 3 from job_artifact_detail settled `empty`,
# which is terminal and says "billed and nothing there".) It is failed with a
# refund, parked, logged, and no model call is made.
reset
V13=$(verdict 518 "lead-review:r13 lead-job:j-none")
printf '%s\n' "$ANS3" > "$T/answer"
run
eq "C13 a missing report: no model call" "$(calls)" 0
eq "C13 status failed, not empty" "$(run_fld "$V13" status)" failed
eq "C13 the attempt is refunded" "$(run_fld "$V13" attempts)" 0
check "C13 the log says the report is missing" 'grep -q "verdict $V13: .*no lead_review_report" "$H/logs/lesson-classify.log"'
run
eq "C13 parked: never claimed again" "$(claims)" 1

# ═════ C14: a report for another PR or head is not this verdict's ══════════
# (lead-review-land posts a report only when its title is this repo#pr at this
# head; the lane now holds the same rule.)
reset
report j14 519
sed -i "1s/at b\{40\}/at $(printf 'c%.0s' $(seq 40))/" "$T/report.j14.md"
V14=$(verdict 519 "lead-review:r14 lead-job:j14")
printf '%s\n' "$ANS3" > "$T/answer"
run
eq "C14 a report for another head: no model call" "$(calls)" 0
eq "C14 status failed" "$(run_fld "$V14" status)" failed
eq "C14 no rows" "$(findings "$V14")" 0

# ═════ C10: the model's finding number as a string still joins ══════════════
reset
report j1 514
V10=$(verdict 514 "lead-review:r10 lead-job:j1")
printf '%s\n' '{"findings":[{"n":"1","category":"ci-tests-skipped","confidence":0.7,"cause":"x","infra_false":false},{"n":"2","category":"test-hand-copies-lib","confidence":0.9,"cause":"y","infra_false":false},{"n":"3","category":"other","confidence":0.4,"cause":"z","infra_false":false}]}' > "$T/answer"
run
eq "C10 \"n\":\"2\" is finding 2" "$(q "SELECT category FROM block_findings WHERE verdict_id=? AND n=2" "$V10" | jq -r '.[0].category')" test-hand-copies-lib

# ═════ C11: more findings than the worker takes (51 > its cap of 50) ════════
# The worker would refuse the ok settle after the paid call, so the lane parks
# the verdict before it: no call, failed, and never claimed again (lead review
# of fd7dde5e; on 53154bc5 it paid for the call and then left the run claimed).
reset
{ printf '# Lead review lr-515-%s (example-org/cromford#515 at %s)\n\nVerdict: BLOCK\n\n' "$(printf 'b%.0s' $(seq 12))" "$(printf 'b%.0s' $(seq 40))"
  for i in $(seq 1 51); do printf -- '- [BLOCK] bin/x%s.sh:1: finding %s\n' "$i" "$i"; done; } > "$T/report.j11.md"
V11=$(verdict 515 "lead-review:r11 lead-job:j11")
printf '%s\n' "$ANS3" > "$T/answer"
run
eq "C11 no model call for 51 findings" "$(calls)" 0
eq "C11 the run is failed" "$(run_fld "$V11" status)" failed
run
eq "C11 the next tick claims nothing for it" "$(claims)" 1

# ═════ C12: a parked verdict never takes one of the tick's slots ═══════════
reset
report j1 516
V12a=$(verdict 516 "lead-review:r12a lead-job:j1")
V12b=$(verdict 517 "lead-review:r12b lead-job:j1")
mkdir -p "$H/state/lesson-classify"; : > "$H/state/lesson-classify/parked-$V12b"
printf '%s\n' "$ANS3" > "$T/answer"
run LESSON_CLASSIFY_MAX_PER_TICK=1
eq "C12 the one slot goes to the verdict that is not parked" "$(run_fld "$V12a" status)" ok
eq "C12 the parked one is never claimed" "$(run_row "$V12b")" '{}'

# ═════ the worker half, as its own node suite ════════════════════════════════
if NOUT=$(cd "$DIR/worker/jobs" && node --test test/block-findings.bh-5806.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/block-findings.bh-5806.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30; fi

echo "lesson-classify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
