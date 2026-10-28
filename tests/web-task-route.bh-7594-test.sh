#!/bin/bash
# tests/web-task-route.bh-7594-test.sh — how a web-task ticket reaches the
# web-task lane, and the pieces around the lane (BH-7594, slice S1).
#
# WHAT THIS SUITE PINS:
#   K  bin/kind-gate.sh: a `web-task` label or board type field gives KIND_HINT
#      web-task; a title prefix, a body sentence and look-alike labels never do.
#   H  the `# >>> web-task hook (BH-7594)` block, EXTRACTED VERBATIM from the
#      flattened pipeline (tests/lib/rb-all.sh) and run with the REAL
#      bin/lib/web-task/route.sh and the real kind gate, over a stub placement
#      lib: a labelled ticket is enqueued as one lane-run row and never reaches
#      the plan path; a live row defers; a hub placement fails; every other
#      ticket falls through to the plan.
#   R  the terminal words: result-prefix-ok, _job_finish, the gate-release and
#      split-chain owner checks, and the result-sweep rule in every prompt.
#   D  the lane-run image: the playwright module block and the browsers path.
#   Z  the four seam files: each function answers "not available", rc 69.
#   Q  the seed fragment on a scratch SQLite DB: the web-task route is copied
#      from triage rung 0, an operator's cut is kept, a re-apply is a no-op.
#   X  the lane header gates: lane_gate_or_exit and lane_env_apply run first.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/web-task-route.bh-7594-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

KG="$DIR/bin/kind-gate.sh"
ROUTE="$DIR/bin/lib/web-task/route.sh"
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-7594-web-task-seeds.sql 2>/dev/null | head -1)

# ═══════════════════════════════════════════════════════════════════════════
# K — the kind gate
# ═══════════════════════════════════════════════════════════════════════════
KB="$T/kb"; mkdir -p "$KB"
hint() { # hint <meta-json> -> "<KIND_HINT>|<KIND_HINT_SOURCE>"
  printf '%s\n' "$1" > "$KB/ticket-meta.json"
  local out; out=$(bash "$KG" "$KB" 2>/dev/null)
  printf '%s|%s' "$(sed -n 's/^KIND_HINT: //p' <<<"$out")" "$(sed -n 's/^KIND_HINT_SOURCE: //p' <<<"$out")"
}
[ "$(hint '{"title":"Read the Playwright version","labels":[{"name":"web-task"}]}')" = "web-task|label=web-task" ] && ok \
  || bad "K1: label web-task must give web-task, got $(hint '{"title":"x","labels":[{"name":"web-task"}]}')"
[ "$(hint '{"title":"x","labels":["WebTask"]}' | cut -d'|' -f1)" = web-task ] && ok || bad "K1: label WebTask must give web-task"
[ "$(hint '{"title":"x","type":"web-task","labels":[]}')" = "web-task|type=web-task" ] && ok || bad "K2: type field web-task must give web-task"
for t in 'web-task: read X' 'web-task S1: a web-task lane' 'Webtask: read X' 'web_task: read X' '[webtask] read X'; do
  [ "$(hint "$(jq -nc --arg t "$t" '{title:$t,labels:[]}')" | cut -d'|' -f1)" = none ] && ok \
    || bad "K3: title '$t' must give no hint, got $(hint "$(jq -nc --arg t "$t" '{title:$t,labels:[]}')")"
done
[ "$(hint '{"title":"web-task S1: a web-task lane","labels":[{"name":"ai-build"}],"body":"this is a web-task"}' | cut -d'|' -f1)" = none ] && ok \
  || bad "K3: this ticket's own shape (title web-task S1, label ai-build) must give no hint"
for l in web task web-tasks ai-build; do
  [ "$(hint "$(jq -nc --arg l "$l" '{title:"x",labels:[{name:$l}]}')" | cut -d'|' -f1)" = none ] && ok \
    || bad "K4: label '$l' must give no hint"
done
[ "$(hint '{"title":"x","labels":[{"name":"bug"}]}')" = "bug|label=bug" ] && ok || bad "K5: a bug label must still give bug"
printf '{"title":"x","labels":[]}\n' > "$KB/ticket-meta.json"
printf '# p\n\nKIND: web-task\n' > "$KB/plan.md"
[ "$(bash "$KG" "$KB" 2>/dev/null | sed -n 's/^KIND_PLAN: //p')" = none ] && ok || bad "K6: a planner's 'KIND: web-task' line must not classify"
rm -f "$KB/plan.md"

# ═══════════════════════════════════════════════════════════════════════════
# H — the pipeline hook
# ═══════════════════════════════════════════════════════════════════════════
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"; }
HOOK="$T/hook.sh"; RESULTFN="$T/resultfn.sh"
marked '# >>> web-task hook (BH-7594)' '# <<< web-task hook (BH-7594)' "$RB" > "$HOOK"
sed -n '/^RESULT() {/,/^}$/p' "$RB" > "$RESULTFN"
[ -s "$HOOK" ] && ok || bad "H0: the '# >>> web-task hook (BH-7594)' block is missing from the pipeline"
[ -s "$RESULTFN" ] && ok || bad "H0: RESULT is missing from the pipeline"
bash -n "$HOOK" 2>/dev/null && ok || bad "H0: the hook block is not valid bash on its own"
# the block sits after the untrusted input gate and before the plan launch
LN_UI=$(grep -n '^# <<< untrusted input gate (BH-4491)' "$RB" | head -1 | cut -d: -f1)
LN_WT=$(grep -n '^# >>> web-task hook (BH-7594)' "$RB" | head -1 | cut -d: -f1)
LN_CC=$(grep -n '^CC plan ' "$RB" | head -1 | cut -d: -f1)
[ -n "$LN_UI" ] && [ -n "$LN_WT" ] && [ -n "$LN_CC" ] && [ "$LN_UI" -lt "$LN_WT" ] && [ "$LN_WT" -lt "$LN_CC" ] && ok \
  || bad "H0: the hook must sit after the untrusted input gate and before the PLAN call (ui=$LN_UI wt=$LN_WT cc=$LN_CC)"

H="$T/h"; mkdir -p "$H/bin/lib/web-task"
scratch_install_closure bin/lib/web-task/route.sh "$H" >/dev/null || bad "H: cannot install route.sh"
scratch_install_closure bin/kind-gate.sh "$H" >/dev/null || bad "H: cannot install kind-gate"
# the stub placement lib: the answer and the enqueue rc come from the test
cat > "$H/bin/lib/lane-placement.sh" <<'SH'
# shellcheck shell=bash
lp_decide() { printf 'decide %s\n' "$*" >> "$LP_REC"; LP_PLACE="${STUB_PLACE:-fly}"; LP_WHY="stub-why"; return 0; }
lp_enqueue() { { printf 'enqueue'; printf ' [%s]' "$@"; printf '\n'; } >> "$LP_REC"; return "${STUB_ENQ_RC:-0}"; }
SH
# stub lane-gate and factory-stop libs: the pause answers come from the test
cat > "$H/bin/lib/lane-gate.sh" <<'SH'
# shellcheck shell=bash
lane_paused() { printf 'paused? %s\n' "$*" >> "$LP_REC"; [ -n "${STUB_PAUSED:-}" ] || return 1; LANE_PAUSED_WHY="$STUB_PAUSED"; return 0; }
SH
cat > "$H/bin/lib/factory-stop.sh" <<'SH'
# shellcheck shell=bash
factory_stopped() { [ "${STUB_FSTOP:-0}" = 1 ]; }
SH
# fleet.conf answers: the issues lane (prefix "-") unless the test says board
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in
  board_prefix) printf '%s\n' "${STUB_PREFIX:--}" ;;
  repo)         printf 'o/r\n' ;;
  prod)         printf -- '-\n' ;;
esac
SH
chmod +x "$H/bin/fleet-conf.sh"
cat > "$T/drive-hook.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { echo "2026-10-19 00:00:00Z"; }
. "$RESULTFN"
KIND_PROBE=$("$HARNESS/bin/kind-gate.sh" "$BUILD" 2>/dev/null)
KIND_HINT=$(sed -n 's/^KIND_HINT:[[:space:]]*//p' <<<"$KIND_PROBE" | tail -1)
KIND_HINT_SRC=$(sed -n 's/^KIND_HINT_SOURCE:[[:space:]]*//p' <<<"$KIND_PROBE" | tail -1)
. "$HOOK"
printf 'sentinel\n' > "$BUILD/sentinel"
DRIVE
B="$T/build"
run_hook() { # run_hook <meta-json> -> HRC, RESULT in $B/RESULT, enqueue log in $T/lp.rec
  scratch_rm "$B"; mkdir -p "$B"; : > "$T/lp.rec"
  printf '%s\n' "$1" > "$B/ticket-meta.json"
  HARNESS="$H" BUILD="$B" PROJECT=proj KEY=AB-7 TICKET=7 JOB_ID=job-fixture-9 \
    HOOK="$HOOK" RESULTFN="$RESULTFN" LP_REC="$T/lp.rec" STUB_PLACE="${STUB_PLACE:-fly}" STUB_ENQ_RC="${STUB_ENQ_RC:-0}" STUB_PREFIX="${STUB_PREFIX:--}" \
    STUB_PAUSED="${STUB_PAUSED:-}" STUB_FSTOP="${STUB_FSTOP:-0}" \
    bash "$T/drive-hook.sh" > "$T/hook.out" 2>&1
  HRC=$?
}
res() { cat "$B/RESULT" 2>/dev/null; }
LABELLED='{"title":"Read the Playwright version","labels":[{"name":"web-task"}],"body":"read it"}'
run_hook "$LABELLED"
[ "$HRC" = 0 ] && ok || bad "H1: a queued web-task must exit 0, got $HRC: $(cat "$T/hook.out")"
[ "$(grep '^enqueue' "$T/lp.rec")" = "enqueue [web-task] [proj] [$H/bin/web-task.sh] [7] [AB-7] [job-fixture-9]" ] && ok \
  || bad "H1: enqueue argv must be web-task proj <H>/bin/web-task.sh 7 AB-7 job-fixture-9, got: $(cat "$T/lp.rec")"
grep -q '^decide web-task proj$' "$T/lp.rec" && ok || bad "H1: placement must be asked for web-task proj"
[ "$(res)" = "WEBTASK_QUEUED lane-run row for proj/AB-7" ] && ok || bad "H1: RESULT must be WEBTASK_QUEUED, got '$(res)'"
[ ! -f "$B/sentinel" ] && ok || bad "H1: a web-task ticket must never reach the plan path"
grep -q 'WEB-TASK' "$B/pipeline.log" 2>/dev/null && ok || bad "H1: the decision must leave a pipeline.log line"
STUB_ENQ_RC=3 run_hook "$LABELLED"
case "$(res)" in "BUILD_DEFERRED web-task: a web-task run for proj is already live"*) ok ;; *) bad "H2: rc 3 must defer, got '$(res)'" ;; esac
[ "$HRC" = 3 ] && [ ! -f "$B/sentinel" ] && ok || bad "H2: a deferred web-task must exit 3 and not plan (rc $HRC)"
STUB_ENQ_RC=1 run_hook "$LABELLED"
case "$(res)" in "WEBTASK_FAILED could not enqueue the lane-run row (lp_enqueue rc 1)"*) ok ;; *) bad "H3: an enqueue failure must be WEBTASK_FAILED, got '$(res)'" ;; esac
[ ! -f "$B/sentinel" ] && ok || bad "H3: a failed enqueue must not fall into the plan"
# H3b — a paused lane (lane-off-web-task or the project switch) enqueues
# nothing: no lane-run machine boots only to exit on its own gate
STUB_PAUSED=lane-off-web-task run_hook "$LABELLED"
case "$(res)" in "BUILD_DEFERRED web-task: lane paused (lane-off-web-task)"*) ok ;; *) bad "H3b: a paused lane must be BUILD_DEFERRED, got '$(res)'" ;; esac
[ "$HRC" = 3 ] && [ ! -f "$B/sentinel" ] && ok || bad "H3b: a paused lane must exit 3 and not plan (rc $HRC)"
grep -q '^enqueue' "$T/lp.rec" && bad "H3b: a paused lane must enqueue nothing: $(cat "$T/lp.rec")" || ok
grep -q '^decide' "$T/lp.rec" && bad "H3b: a paused lane must not even ask placement: $(cat "$T/lp.rec")" || ok
grep -q '^paused? web-task proj$' "$T/lp.rec" && ok || bad "H3b: the pause must be asked for web-task proj, got: $(cat "$T/lp.rec")"
# H3c — factory-stop on: the same, nothing enqueued
STUB_FSTOP=1 run_hook "$LABELLED"
case "$(res)" in "BUILD_DEFERRED web-task: factory-stop is on"*) ok ;; *) bad "H3c: factory-stop must be BUILD_DEFERRED, got '$(res)'" ;; esac
[ "$HRC" = 3 ] && [ ! -f "$B/sentinel" ] && ok || bad "H3c: factory-stop must exit 3 and not plan (rc $HRC)"
grep -q '^enqueue' "$T/lp.rec" && bad "H3c: factory-stop must enqueue nothing: $(cat "$T/lp.rec")" || ok
STUB_PLACE=hub run_hook "$LABELLED"
case "$(res)" in "WEBTASK_FAILED lane web-task is not placed on fly for proj (stub-why)"*) ok ;; *) bad "H4: hub placement must be WEBTASK_FAILED, got '$(res)'" ;; esac
grep -q '^enqueue' "$T/lp.rec" && bad "H4: hub placement must enqueue nothing" || ok
# an in-app board project: its ticket number is no GitHub issue, so no row
STUB_PREFIX=/api/board run_hook "$LABELLED"
case "$(res)" in "BUILD_REFUSED web-task: proj is an in-app board project"*) ok ;; *) bad "H4b: an in-app board project must be BUILD_REFUSED (the in-app prompts' word), got '$(res)'" ;; esac
[ "$HRC" = 3 ] && [ ! -f "$B/sentinel" ] && ok || bad "H4b: an in-app refusal must exit 3 and not plan (rc $HRC)"
grep -q '^enqueue' "$T/lp.rec" && bad "H4b: an in-app board project must enqueue nothing" || ok
run_hook '{"title":"x","type":"web-task","labels":[]}'
[ "$(res)" = "WEBTASK_QUEUED lane-run row for proj/AB-7" ] && ok || bad "H5: a type field must route too, got '$(res)'"
for meta in '{"title":"web-task: read X","labels":[]}' \
            '{"title":"web-task S1: a web-task lane","labels":[{"name":"ai-build"}],"body":"this is a web-task"}' \
            '{"title":"x","labels":[{"name":"bug"}]}' '{"title":"x","labels":[]}'; do
  run_hook "$meta"
  [ -f "$B/sentinel" ] && [ ! -s "$T/lp.rec" ] && [ -z "$(res)" ] && ok \
    || bad "H6: '$meta' must fall through to the plan untouched (sentinel=$([ -f "$B/sentinel" ] && echo y || echo n), lp=$(cat "$T/lp.rec"), result='$(res)')"
done
# wt_route itself refuses a hint whose source is not a label or a type field
# (the kind gate never gives one today; this is the second layer)
cat > "$T/drive-route.sh" <<'DRIVE'
#!/bin/bash
. "$HARNESS/bin/lib/lane-placement.sh"
. "$HARNESS/bin/lib/web-task/route.sh"
wt_route proj 7 AB-7 job-fixture-9 web-task "$SRC"; rc=$?
printf '%s|%s\n' "$rc" "$WT_LINE"
DRIVE
: > "$T/lp.rec"
for src in "title=web-task" "plan" "none" ""; do
  OUT=$(HARNESS="$H" SRC="$src" LP_REC="$T/lp.rec" bash "$T/drive-route.sh" 2>/dev/null)
  [ "$OUT" = "1|" ] && ok || bad "H8: wt_route must ignore a web-task hint from source '$src', got '$OUT'"
done
[ ! -s "$T/lp.rec" ] && ok || bad "H8: a refused source must not ask placement or enqueue: $(cat "$T/lp.rec")"
OUT=$(HARNESS="$H" SRC="label=web-task" LP_REC="$T/lp.rec" bash "$T/drive-route.sh" 2>/dev/null)
[ "$OUT" = "0|WEBTASK_QUEUED lane-run row for proj/AB-7" ] && ok || bad "H8: control: a label source must queue, got '$OUT'"
# no route lib on the box: a labelled ticket still never reaches the plan
mv "$H/bin/lib/web-task/route.sh" "$T/route.sh.away"
run_hook "$LABELLED"
case "$(res)" in WEBTASK_FAILED*) ok ;; *) bad "H7: a missing route lib must fail the web-task, not plan it, got '$(res)'" ;; esac
[ ! -f "$B/sentinel" ] && ok || bad "H7: a missing route lib must not fall into the plan"
mv "$T/route.sh.away" "$H/bin/lib/web-task/route.sh"

# ═══════════════════════════════════════════════════════════════════════════
# R — the terminal words
# ═══════════════════════════════════════════════════════════════════════════
bash "$DIR/bin/result-prefix-ok.sh" "WEBTASK_QUEUED lane-run row for p/AB-7" && ok || bad "R1: WEBTASK_QUEUED must be a RESULT line"
bash "$DIR/bin/result-prefix-ok.sh" "WEBTASK_FAILED why" && ok || bad "R1: WEBTASK_FAILED must be a RESULT line"
bash "$DIR/bin/result-prefix-ok.sh" " WEBTASK_QUEUED x" && bad "R1: a leading space must still be a miss" || ok
JOBFIN="$T/jobfin.sh"
awk '/^_job_finish\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" > "$JOBFIN"
[ -s "$JOBFIN" ] && ok || bad "R2: _job_finish is missing from the pipeline"
cat > "$T/drive-jobfin.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
job_beat_stop() { :; }
job_update() { printf 'job_update %s\n' "$*" >> "$REC"; }
job_event() { :; }
job_phase_close_open() { echo ""; }
. "$JOBFIN"
_job_finish
DRIVE
jobfin() {
  JB="$T/jb"; scratch_rm "$JB"; mkdir -p "$JB"; printf '%s\n' "$1" > "$JB/RESULT"; : > "$T/jf.rec"
  JOB_ID=7 JOB_BEAT="" BUILD="$JB" PROJECT=proj KEY=AB-7 REC="$T/jf.rec" JOBFIN="$JOBFIN" bash "$T/drive-jobfin.sh" >/dev/null 2>&1
  cat "$T/jf.rec"
}
grep -q 'status=done' <<<"$(jobfin "WEBTASK_QUEUED lane-run row for proj/AB-7")" && ok || bad "R2: WEBTASK_QUEUED must close the job done"
OUT=$(jobfin "WEBTASK_FAILED lane web-task is not placed on fly")
grep -q 'status=failed' <<<"$OUT" && ! grep -q 'status=done' <<<"$OUT" && ok || bad "R2: WEBTASK_FAILED must close the job failed, got: $OUT"
# split-chain: a WEBTASK_QUEUED build owns the key
HR="$T/hr"; mkdir -p "$HR/builds/proj-AB-7-202610190000" "$HR/locks"
cat > "$T/drive-sc.sh" <<'DRIVE'
#!/bin/bash
. "$SCLIB"
_sc_idle "$HR" proj AB-7
DRIVE
printf 'WEBTASK_QUEUED lane-run row for proj/AB-7\n' > "$HR/builds/proj-AB-7-202610190000/RESULT"
SCLIB="$DIR/bin/lib/split-chain.sh" HR="$HR" HARNESS="$HR" bash "$T/drive-sc.sh" >/dev/null 2>&1 && bad "R3: split-chain must see a WEBTASK_QUEUED build as the owner" || ok
printf 'BUILD_DEFERRED x\n' > "$HR/builds/proj-AB-7-202610190000/RESULT"
SCLIB="$DIR/bin/lib/split-chain.sh" HR="$HR" HARNESS="$HR" bash "$T/drive-sc.sh" >/dev/null 2>&1 && ok || bad "R3: control: a deferred build must leave the key idle"
# gate-release: WEBTASK_QUEUED already owns the key
cat > "$T/drive-gr.sh" <<'DRIVE'
#!/bin/bash
rq_lines() { :; }; lock_spawn_unheld() { :; }; pause_active() { return 1; }
gr_state_dir() { mkdir -p "$1/state/gr" && printf '%s' "$1/state/gr"; }
gr_newest_result() { printf '2026-10-19T00:00:00Z\t%s\n' "$WORD"; }
gr_ticket_id() { printf '7'; }
_GR_LIBDIR=/nonexistent
. "$GRLIB"
gr_owned "$HR" proj AB-7 7 sha1
DRIVE
gr() { WORD="$1" GRLIB="$DIR/bin/lib/gate-release/queue.sh" HR="$HR" bash "$T/drive-gr.sh" >/dev/null 2>&1; }
mkdir -p "$HR/logs"
gr "WEBTASK_QUEUED lane-run row for proj/AB-7" && bad "R4: gate-release must see WEBTASK_QUEUED as the owner" || ok
gr "BUILD_DEFERRED x" && ok || bad "R4: control: a deferred build must leave the key free for gate-release"
# the sweep rule rides beside the rollout rule in every GitHub-issue prompt
# (its rollout rule talks about re-label); an in-app prompt never sees a
# WEBTASK_* word (wt_route answers BUILD_REFUSED there) and must already close
# BUILD_REFUSED with an ALERTS line
NGH=0
for F in $(grep -l 'ROLLOUT_FILED' "$DIR"/prompts/*.md); do
  if awk '/ROLLOUT_FILED/ && /re-label/ {f=1} END {exit !f}' "$F"; then
    NGH=$((NGH + 1))
    awk '/WEBTASK_QUEUED/ && /WEBTASK_FAILED/ && /ALERTS\.log/ && /COMMENTED/ {f=1} END {exit !f}' "$F" && ok \
      || bad "R5: ${F#"$DIR"/} is a GitHub-issue prompt with no WEBTASK_QUEUED/WEBTASK_FAILED/ALERTS.log/COMMENTED sweep rule"
  else
    awk '/BUILD_REFUSED/ && /ALERTS\.log/ {f=1} END {exit !f}' "$F" && ok \
      || bad "R5: ${F#"$DIR"/} is an in-app prompt with no BUILD_REFUSED -> ALERTS.log rule"
  fi
done
[ "$NGH" -ge 8 ] && ok || bad "R5: want the 8 GitHub-issue prompts, found $NGH"

# ═══════════════════════════════════════════════════════════════════════════
# D — the lane-run image
# ═══════════════════════════════════════════════════════════════════════════
LDF="$DIR/fly/lane-run.Dockerfile"
lnum() { grep -n -F -x -- "$1" "$LDF" | head -1 | cut -d: -f1; }
L_ENV=$(lnum 'ENV PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers')
L_PWE=$(lnum '# <<< bake-playwright')
L_MS=$(lnum '# >>> web-task-playwright-module')
L_ME=$(lnum '# <<< web-task-playwright-module')
L_HC=$(grep -n '^ARG HARNESS_COMMIT' "$LDF" | head -1 | cut -d: -f1)
L_PWS=$(lnum '# >>> bake-playwright')
[ -n "$L_ENV" ] && [ -n "$L_PWS" ] && [ "$L_ENV" -lt "$L_PWS" ] && ok || bad "D1: ENV PLAYWRIGHT_BROWSERS_PATH must come before the bake-playwright block (env=$L_ENV pw=$L_PWS)"
[ -n "$L_MS" ] && [ -n "$L_ME" ] && [ -n "$L_PWE" ] && [ -n "$L_HC" ] && [ "$L_PWE" -lt "$L_MS" ] && [ "$L_ME" -lt "$L_HC" ] && ok \
  || bad "D2: the module block must sit after bake-playwright and before ARG HARNESS_COMMIT (pw=$L_PWE ms=$L_MS me=$L_ME hc=$L_HC)"
MB=$(sed -n "${L_MS:-1},${L_ME:-1}p" "$LDF")
grep -q 'npm install -g "playwright@${PLAYWRIGHT_VERSION}"' <<<"$MB" && grep -q "require(" <<<"$MB" && ok \
  || bad "D3: the module block must install the pinned playwright globally and require it"
grep -qF -- '--build-arg PLAYWRIGHT_VERSION=$($JC setting-get bake.playwright.version)' "$DIR/fly/lane-run.toml" && ok \
  || bad "D4: fly/lane-run.toml's recipe must pass the pinned PLAYWRIGHT_VERSION"
grep -q '^playwright PLAYWRIGHT_VERSION ' "$DIR/bin/lib/bake-deps.sh" && ok || bad "D5: the bake-deps manifest must carry the playwright pin row"

# ═══════════════════════════════════════════════════════════════════════════
# Z — the seam files for later slices
# ═══════════════════════════════════════════════════════════════════════════
for pair in "vault.sh wt_vault_get" "otp.sh wt_otp_wait" "session.sh wt_session_load" "session.sh wt_session_save"; do
  set -- $pair
  f="$DIR/bin/lib/web-task/$1"
  bash -n "$f" 2>/dev/null && ok || bad "Z: $1 does not parse"
  OUT=$(bash -c '. "$1" || exit 9; "$2" a b' _ "$f" "$2" 2>/dev/null); RC=$?
  [ "$RC" = 69 ] && [ "$OUT" = "not available" ] && ok || bad "Z: $2 must print 'not available' and return 69, got rc $RC '$OUT'"
done
# approval.sh is no longer a stub: BH-8386 filled it on main (its behaviour is
# tests/web-task-approval.bh-8386-test.sh). The seam contract S1 relies on
# stays: it parses, defines both functions bin/web-task.sh may call, and a
# call with bad arguments and no LANE_RUN_ID never answers rc 0 (never approves).
f="$DIR/bin/lib/web-task/approval.sh"
bash -n "$f" 2>/dev/null && ok || bad "Z: approval.sh does not parse"
for fn in wt_approval_request wt_approval_status; do
  OUT=$(env -u LANE_RUN_ID bash -c '. "$1" || exit 9; declare -F "$2" >/dev/null || exit 8; "$2" a b' _ "$f" "$fn" 2>/dev/null); RC=$?
  [ "$RC" != 0 ] && [ "$RC" != 8 ] && [ "$RC" != 9 ] && ok || bad "Z: $fn must be defined and must not answer rc 0 to a bad call, got rc $RC '$OUT'"
done
ls "$DIR/bin/lib/web-task/vault.sh" "$DIR/bin/lib/web-task/otp.sh" "$DIR/bin/lib/web-task/session.sh" "$DIR/bin/lib/web-task/approval.sh" >/dev/null 2>&1 && ok || bad "Z: a seam file is missing"

# ═══════════════════════════════════════════════════════════════════════════
# Q — the seed fragment
# ═══════════════════════════════════════════════════════════════════════════
[ -n "$SEED" ] && ok || bad "Q: no worker/jobs/schema.d/*-bh-7594-web-task-seeds.sql fragment"
if [ -n "$SEED" ]; then
  for t in model_routes model_route_changes settings; do
    awk -v t="$t" '$0 ~ "^CREATE TABLE IF NOT EXISTS " t " \\(" {f=1} f{print} f && /^\);/{exit}' "$DIR"/worker/jobs/schema.d/000*.sql
  done > "$T/tables.sql"
  cat > "$T/q.py" <<'PY'
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.executescript(open(sys.argv[1]).read())
db.execute("INSERT INTO model_routes (scope,project,role,position,model,runner,updated_by,updated_at) VALUES ('hub',NULL,'triage',0,'model-fixture-triage','claude','seed','2026-01-01T00:00:00Z')")
db.execute("INSERT INTO model_routes (scope,project,role,position,model,runner,updated_by,updated_at) VALUES ('hub',NULL,'triage',1,'model-fixture-other','codex','seed','2026-01-01T00:00:00Z')")
if sys.argv[3] == "cut":
    db.execute("INSERT INTO model_route_changes (scope,project,role,position,actor,at) VALUES ('hub',NULL,'web-task',0,'operator','2026-01-01T00:00:00Z')")
seed = open(sys.argv[2]).read()
db.executescript(seed); db.executescript(seed)
for r in db.execute("SELECT role, position, model, runner FROM model_routes WHERE role='web-task' ORDER BY position"):
    print("route", *r)
for r in db.execute("SELECT key, value FROM settings WHERE key LIKE 'lane_placement.web-task%' OR key LIKE 'lane.web-task.%'"):
    print("setting", *r)
PY
  QOUT=$(python3 -I "$T/q.py" "$T/tables.sql" "$SEED" plain 2>&1)
  [ "$(grep -c '^route ' <<<"$QOUT")" = 1 ] && grep -qx 'route web-task 0 model-fixture-triage claude' <<<"$QOUT" && ok \
    || bad "Q1: want one web-task route copied from triage rung 0 (and a re-apply adds none), got: $QOUT"
  grep -qx 'setting lane_placement.web-task fly' <<<"$QOUT" && ok || bad "Q2: want lane_placement.web-task=fly, got: $QOUT"
  # Q3 is about allowed_domains alone: the lane's llm-gate rows are lane.web-task.* too.
  grep -q '^setting lane\.web-task\..*allowed_domains' <<<"$QOUT" && bad "Q3: no allowed_domains row may be seeded (empty = refuse): $QOUT" || ok
  # Q3b: the llm-gate values are settings rows (the registry keeps the BH-2533 defaults).
  grep -qx 'setting lane.web-task.llm_runner_allowed claude' <<<"$QOUT" && grep -qx 'setting lane.web-task.llm_usd_cap_day 5' <<<"$QOUT" && ok \
    || bad "Q3b: want lane.web-task.llm_runner_allowed=claude and lane.web-task.llm_usd_cap_day=5, got: $QOUT"
  QOUT=$(python3 -I "$T/q.py" "$T/tables.sql" "$SEED" cut 2>&1)
  grep -q '^route ' <<<"$QOUT" && bad "Q4: an operator's cut (a model_route_changes row) must be kept: $QOUT" || ok
  grep -qiE "claude-[a-z0-9]" "$SEED" && bad "Q5: the seed must carry no model literal" || ok
fi

# ═══════════════════════════════════════════════════════════════════════════
# X — the lane header, executed: an all-off flag stops it before any work
# ═══════════════════════════════════════════════════════════════════════════
HX="$T/hx"; mkdir -p "$HX/flags" "$HX/logs" "$HX/catalog"
scratch_install_closure bin/web-task.sh "$HX" >/dev/null || bad "X: cannot install the lane closure"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$HX/catalog/lanes.json" >/dev/null 2>&1 || bad "X: cannot compose the lane registry"
: > "$HX/flags/lane-off-web-task"
XOUT=$(env -i PATH="$PATH" HOME="$T" HARNESS="$HX" HARNESS_TEST_SANDBOX=1 PL_SLUG=o/r bash "$HX/bin/web-task.sh" 7 AB-7 "" proj 2>&1); XRC=$?
[ "$XRC" = 0 ] && ! grep -q 'WEBTASK_' <<<"$XOUT" && ok || bad "X1: the lane-off flag must stop the lane before its body (rc $XRC): $XOUT"
grep -q 'web-task' "$HX/logs/lane-gate.log" 2>/dev/null && ok || bad "X1: the gate must record the skip in logs/lane-gate.log"

echo "web-task-route: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
