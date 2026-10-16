#!/bin/bash
# tests/staff-activity.bh-6822-test.sh — BH-6822: the staff agent detail page.
# A wrapper the impact lane and the orphan ratchet can SEE: it names every new
# source by path, runs the node suites that prove them, and drives the SHIPPED
# bin/staff.sh tick against a fixture.
#
#   W   worker/jobs/test/staff-activity.bh-6822.test.js (A1-A11) and
#       route-table.test.js: the REAL worker.fetch over the composed schema.
#       Fails on 0 passing tests or any skipped one.
#   C   console-ui/tests/staff-agent-detail.bh-6822.test.js (C1-C6), run when
#       the console-ui dependencies are installed.
#   S1  a staff-kill-all flag stops the tick before any read
#   S2  staff-kill-watchman stops watchman; staff-kill-clerk does not
#   S3  no staff-kill flag: the tick runs
#   S4  one POST /api/staff/ticks per tick past the lock, its phase naming
#       where the tick stopped: collector rc 3 -> collect; agent-call rc 1 ->
#       model; a normal tick -> done with its counts; agent-call got
#       COST_RUN_ID=staff-tick:<tick_key>
#   S5  the tick POST fails: rc 0, no extra logs/staff.log line, one
#       logs/staff-ticks.log line
#   S6  the body staff.sh posted goes to the real worker, and the activity
#       read returns that tick with the same counts
#
# MUTATIONS (D1), each tried by hand once against bin/staff.sh: drop the
# staff-kill-all read -> S1 red; drop the staff-kill-<agent> read -> S2 red;
# leave PHASE at roster -> S4 red; drop COST_RUN_ID from the agent-call env ->
# S4 red; write the record failure to staff.log -> S5 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-activity.bh-6822-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-activity: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "staff-activity: node is required"; exit 1; }
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: staff-activity.bh-6822-test: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
lines() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

for SRC in "$DIR/worker/jobs/src/routes/staff-activity.js" \
           "$DIR/worker/jobs/schema.d/202610161355-bh-6822-staff-activity.sql" \
           "$DIR/worker/jobs/test/route-table.d/776-staff-activity.txt" \
           "$DIR/worker/jobs/test/staff-activity.bh-6822.test.js" \
           "$DIR/console-ui/src/lib/staff-activity.js" \
           "$DIR/console-ui/src/screens/staff/agent-chat.js" \
           "$DIR/console-ui/src/screens/staff/agent-learning.js" \
           "$DIR/console-ui/tests/staff-agent-detail.bh-6822.test.js" \
           "$DIR/bin/staff.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

# ═════ W: the worker suite ═══════════════════════════════════════════════════
if node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null; then
  LOG="$T/worker.log"
  (cd "$DIR/worker/jobs" && node --test --test-reporter=spec test/staff-activity.bh-6822.test.js test/route-table.test.js) >"$LOG" 2>&1
  RC=$?
  PASSED=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  SKIPPED=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$LOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$LOG"; bad "worker node --test rc=$RC"
  elif [ -z "$PASSED" ] || [ -z "$SKIPPED" ]; then cat "$LOG"; bad "worker: no test summary"
  elif [ "$PASSED" -eq 0 ]; then cat "$LOG"; bad "worker: 0 tests passed"
  elif [ "$SKIPPED" != 0 ]; then cat "$LOG"; bad "worker: $SKIPPED test(s) SKIPPED"
  else ok
  fi
  HAVE_SQLITE=1
else
  echo "staff-activity: worker suite and S6 SKIPPED — this node has no node:sqlite"
  HAVE_SQLITE=0
fi

# ═════ C: the console suite ══════════════════════════════════════════════════
if [ ! -d "$DIR/console-ui/node_modules/preact-render-to-string" ]; then
  echo "staff-activity: console node suite SKIPPED — console-ui dependencies are not installed (the console-ui CI job runs it)"
else
  CLOG="$T/console.log"
  if (cd "$DIR/console-ui" && node --test tests/staff-agent-detail.bh-6822.test.js) >"$CLOG" 2>&1; then ok
  else bad "console-ui/tests/staff-agent-detail.bh-6822.test.js failed:"; grep -E '^not ok|Error' "$CLOG" | head -20
  fi
fi

# ═════ S: bin/staff.sh tick, as shipped ══════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/prompts/staff" "$H/catalog/prompts" "$T/fakebin"
scratch_install_closure bin/staff.sh "$H" >/dev/null || bad "scratch_install_closure bin/staff.sh failed"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || bad "scratch_install_closure bin/jobs-client.sh failed"
cp "$DIR/bin/staff-core.mjs" "$H/bin/"
cp -r "$DIR/agent-core" "$H/agent-core"
cp "$DIR/prompts/staff/watchman-soul.md" "$H/prompts/staff/"
cp "$DIR/catalog/prompts/staff-tick.md" "$H/catalog/prompts/"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$1" "${COST_RUN_ID:-}" >> "$FXT/ac.log"
pf="${6#@}"
sed -n '/^## Items$/,$p' "$pf" | sed 1d \
  | jq -c '{decisions: [.[] | {fingerprint, action: "file a ticket", title: "Fixture title", body: "Fixture body."}]}' > "$5"
exit "$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)"
SH
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
mkdir -p "$H/bin/staff"
cat > "$H/bin/staff/watchman-collect.sh" <<'SH'
#!/bin/bash
touch "$FXT/collected"
cat "$FXT/items.jsonl" 2>/dev/null
exit "$(cat "$FXT/collect.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh" "$H/bin/staff/watchman-collect.sh"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/req.log"
  case "$1 $2" in
    "GET /api/staff/agent?name="*)
      printf '{"agent":{"name":"watchman","autonomy":"augmentation","cap":"augmentation","status":"active","soul":"prompts/staff/watchman-soul.md"}}'
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/req.log"
  local fp
  case "$2" in
    /api/staff/findings/claim)
      fp=$(jq -cS .item "$3" | sha256sum | cut -c1-64)
      printf '{"claimed":true,"fingerprint":"%s","finding":{"agent":"watchman","status":"claimed"}}' "$fp"; return 0 ;;
    # BH-6823: every tick past the soul check takes its chat notes; none here.
    /api/staff/chat/take) printf '{"notes":[],"failed":[]}'; return 0 ;;
    /api/staff/findings/record) printf '{"ok":true}'; return 0 ;;
    /api/staff/ticks)
      [ -f "$FXT/ticks.fail" ] && return 1
      printf '{"tick":{"id":1}}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  [ "${3:-}" = --input ] && cp "$4" "$FXT/gh-payload.json"
  GH_REST_STATUS=201
  printf '{"number":7,"html_url":"https://github.com/example/fixture/issues/7"}\n'
  return 0
}
gh_rest_issue_list() { GH_REST_STATUS=200; echo '[]'; return 0; }
lane_role_model() { printf 'stub-model\n'; }
SH
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT" "$H/flags"
  : > "$FXT/req.log"; : > "$FXT/ac.log"
  jq -cn '{item: {id: "s-1"}, title: "Fixture finding s-1", source: {kind: "fixture", url: "https://example.com/fx/s-1", labels: []},
    observedAt: "2026-10-10T00:00:00Z"}' > "$FXT/items.jsonl"
}
tick() { # tick [agent] — the shipped entry point, sandboxed
  env HARNESS="$H" FXT="$FXT" STAFF_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 STAFF_TIMED=1 JOBS_URL= PATH="$T/fakebin:$PATH" \
    bash "$H/bin/staff.sh" tick "${1:-watchman}" >"$T/out.txt" 2>&1
  RC=$?
}
staffreq() { grep -c '/api/staff' "$FXT/req.log"; }
tickposts() { grep -c '^POST /api/staff/ticks ' "$FXT/req.log"; }
tickbody() { grep '^POST /api/staff/ticks ' "$FXT/req.log" | tail -1 | cut -d' ' -f3-; }

# ═════ S1: staff-kill-all ════════════════════════════════════════════════════
reset; touch "$H/flags/staff-kill-all"; tick
eq "S1 rc" "$RC" 0
eq "S1 staff requests" "$(staffreq)" 0
[ ! -e "$FXT/collected" ] && ok || bad "S1: the collector ran"
grep -q 'killed by staff-kill-all' "$H/logs/staff.log" 2>/dev/null && ok || bad "S1: no 'killed by staff-kill-all' line"
eq "S1 tick records" "$(tickposts)" 0

# ═════ S2: staff-kill-<agent> ════════════════════════════════════════════════
reset; touch "$H/flags/staff-kill-watchman"; tick
eq "S2 own flag rc" "$RC" 0
eq "S2 own flag staff requests" "$(staffreq)" 0
grep -q 'killed by staff-kill-watchman' "$H/logs/staff.log" 2>/dev/null && ok || bad "S2: no 'killed by staff-kill-watchman' line"
reset; touch "$H/flags/staff-kill-clerk"; tick
[ -e "$FXT/collected" ] && ok || bad "S2: staff-kill-clerk stopped watchman"
reset; touch "$H/flags/staff-kill-"; tick
[ -e "$FXT/collected" ] && ok || bad "S2: a bare staff-kill- flag stopped watchman"

# ═════ S3: no flag, the tick runs ════════════════════════════════════════════
reset; tick
eq "S3 rc" "$RC" 0
[ -e "$FXT/collected" ] && ok || bad "S3: the collector did not run"
eq "S3 agent-calls" "$(lines "$FXT/ac.log")" 1

# ═════ S4: one tick record per tick, its phase ═══════════════════════════════
B=$(tickbody)
eq "S4 done: one record" "$(tickposts)" 1
eq "S4 done: phase" "$(jq -r .phase <<<"$B")" done
eq "S4 done: counts" "$(jq -c '[.collected, .new_items, .model_calls, .filed, .digested, .held]' <<<"$B")" '[1,1,1,1,0,0]'
eq "S4 done: collector_rc" "$(jq -r .collector_rc <<<"$B")" 0
eq "S4 done: model_rc" "$(jq -r .model_rc <<<"$B")" 0
[[ $(jq -r .tick_key <<<"$B") =~ ^watchman-[0-9]{8}t[0-9]{6}z-[0-9]+$ ]] && ok || bad "S4: tick_key shape: $B"
eq "S4 done: cost_run_id" "$(jq -r .cost_run_id <<<"$B")" "staff-tick:$(jq -r .tick_key <<<"$B")"
eq "S4 done: agent-call COST_RUN_ID" "$(cut -d'|' -f2 "$FXT/ac.log")" "$(jq -r .cost_run_id <<<"$B")"
[[ $(jq -r .collector_s <<<"$B") =~ ^[0-9]+$ ]] && ok || bad "S4: collector_s: $B"
printf '%s\n' "$B" > "$T/done-body.json"

reset; echo 3 > "$FXT/collect.rc"; tick
B=$(tickbody)
eq "S4 collect: one record" "$(tickposts)" 1
eq "S4 collect: phase" "$(jq -r .phase <<<"$B")" collect
eq "S4 collect: collector_rc" "$(jq -r .collector_rc <<<"$B")" 3
eq "S4 collect: no cost_run_id" "$(jq -r .cost_run_id <<<"$B")" null
eq "S4 collect: model_calls" "$(jq -r .model_calls <<<"$B")" 0

reset; echo 1 > "$FXT/ac.rc"; tick
B=$(tickbody)
eq "S4 model: one record" "$(tickposts)" 1
eq "S4 model: phase" "$(jq -r .phase <<<"$B")" model
eq "S4 model: model_rc" "$(jq -r .model_rc <<<"$B")" 1
eq "S4 model: cost_run_id" "$(jq -r .cost_run_id <<<"$B")" "staff-tick:$(jq -r .tick_key <<<"$B")"

# A tick that never gets its lock records nothing.
reset; mkdir -p "$H/locks"; exec 8>"$H/locks/staff-watchman.lock"; flock -n 8 || bad "S4: cannot take the lock"; tick; exec 8>&-
eq "S4 lock held: records" "$(tickposts)" 0

# ═════ S5: a failed record changes nothing else ═════════════════════════════
reset; touch "$FXT/ticks.fail"; tick
eq "S5 rc" "$RC" 0
eq "S5 staff.log lines" "$(lines "$H/logs/staff.log")" 1
eq "S5 staff-ticks.log lines" "$(lines "$H/logs/staff-ticks.log")" 1
grep -q 'agent=watchman tick watchman-.* record failed rc=1' "$H/logs/staff-ticks.log" 2>/dev/null \
  && ok || bad "S5 line: $(cat "$H/logs/staff-ticks.log" 2>/dev/null)"
reset; tick
eq "S5 a good record: no staff-ticks.log" "$(lines "$H/logs/staff-ticks.log")" 0

# ═════ S6: the real worker reads what staff.sh posted ════════════════════════
if [ "$HAVE_SQLITE" = 1 ] && [ -s "$T/done-body.json" ]; then
  OUT=$(cd "$DIR/worker/jobs" && node --input-type=module -e "
import { readFileSync } from 'node:fs';
const worker = (await import('$DIR/worker/jobs/src/index.js')).default;
const { openDb } = await import('$DIR/worker/jobs/test/lib/d1-sqlite.bh-1030.js');
const { DB } = await openDb();
const env = { DB, HARNESS_SECRET: 's-fixture' };
const call = (path, init = {}) => worker.fetch(new Request('https://jobs.test' + path,
  { ...init, headers: { authorization: 'Bearer s-fixture', 'content-type': 'application/json' } }), env)
  .then(async (r) => ({ status: r.status, body: await r.json() }));
const body = readFileSync('$T/done-body.json', 'utf8');
const p = await call('/api/staff/ticks', { method: 'POST', body });
const a = await call('/api/staff/agent/watchman/activity');
const e = (a.body.events || []).find((x) => x.kind === 'tick');
console.log(JSON.stringify({ post: p.status, get: a.status, phase: e && e.phase,
  counts: e && [e.collected, e.new_items, e.model_calls, e.filed, e.digested, e.held], run: e && e.cost_run_id }));
" 2>&1)
  eq "S6 post" "$(jq -r .post <<<"$OUT" 2>/dev/null)" 201
  eq "S6 get" "$(jq -r .get <<<"$OUT" 2>/dev/null)" 200
  eq "S6 phase" "$(jq -r .phase <<<"$OUT" 2>/dev/null)" done
  eq "S6 counts" "$(jq -c .counts <<<"$OUT" 2>/dev/null)" '[1,1,1,1,0,0]'
  eq "S6 cost_run_id" "$(jq -r .run <<<"$OUT" 2>/dev/null)" "$(jq -r .cost_run_id "$T/done-body.json")"
elif [ "$HAVE_SQLITE" = 1 ]; then
  bad "S6: no tick body was captured in S4"
fi

echo "staff-activity.bh-6822-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
