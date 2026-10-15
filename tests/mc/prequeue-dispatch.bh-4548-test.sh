#!/bin/bash
# tests/mc/prequeue-dispatch.bh-4548-test.sh — BH-4548 (#4545 child 2): the
# pre-queue gate's resolver. bin/lib/mc-prequeue.d/dispatch.sh defines the
# pq_resolve hook the tracer (bin/lib/mc-prequeue.sh) asks on a miss or a
# pending entry. It dispatches .github/workflows/prequeue-gate.yml, reads the
# run's one prequeue-verdict annotation back on a later tick, and records it.
# Anything that is not a parsed verdict for exactly this (head, main) is
# could-not-run: one alert, then the enqueue proceeds.
#
#   W        the workflow: shape, run-name == pq_run_title, the verdict word set
#            == the parser's, no cap/budget literals, the main-red skip regex
#            matches its name, and a dry run of its run step against a scratch
#            repo prints exactly one verdict per case
#   L1-L10   real bin/merge-conductor.sh ticks against a stub gh (see the plan)
#   E3       a refused dispatch enqueues the same tick, one alert
#
# Driven, not grepped: every L/E case runs the conductor WHOLE in a scratch
# tree, with the real tracer and the real hook. Assertions read the sinks: the
# dispatch argv ($T/dispatch.txt), the enqueue argv ($T/c-enq.txt), the row
# table, the cache file, logs/ALERTS.log and the ready-why note.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/prequeue-dispatch.bh-4548-test.sh
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1

NOW=$(date +%s)
DISPATCH_LIB="$DIR/bin/lib/mc-prequeue.d/dispatch.sh"
WF="$DIR/.github/workflows/prequeue-gate.yml"
SLUG=example-org/demo-os
H1=$(printf 'a%.0s' $(seq 40))
H2=$(printf 'b%.0s' $(seq 40))
M=$(printf 'c%.0s' $(seq 40))
M_OLD=$(printf 'd%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
# title <num> <head> <main> — the dispatcher's own run title.
title() { ( . "$DISPATCH_LIB" >/dev/null 2>&1; pq_run_title "$@" ); }
[ -r "$DISPATCH_LIB" ] || bad "setup: bin/lib/mc-prequeue.d/dispatch.sh is missing"
[ -r "$WF" ] || bad "setup: .github/workflows/prequeue-gate.yml is missing"

# ============================================================================
# W. The workflow.
# ============================================================================
python3 - "$WF" "$T/w" <<'PY' || bad "W: the workflow must parse and carry its run step (see above)"
import sys, yaml, os
wf = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]; os.makedirs(out, exist_ok=True)
on = wf.get("on", wf.get(True))
inputs = on["workflow_dispatch"]["inputs"]
job = wf["jobs"]["gate"]
step = [s for s in job["steps"] if s.get("id") == "verdict"][0]
open(out + "/run.sh", "w").write(step["run"])
open(out + "/facts", "w").write("\n".join([
  "inputs=" + ",".join(sorted(inputs)),
  "required=" + ",".join(sorted(k for k, v in inputs.items() if v.get("required"))),
  "runs_on=" + str(job["runs-on"]),
  "permissions=" + str(wf.get("permissions")),
  "timeout=" + str(job.get("timeout-minutes")),
  "run_name=" + wf["run-name"],
  "name=" + wf["name"],
  "shell=" + str(step.get("shell")),
  "env=" + ",".join(sorted(step.get("env", {}))),
]) + "\n")
PY
fact() { sed -n "s/^$1=//p" "$T/w/facts" 2>/dev/null; }
# TEST-CHANGE (BH-6335): two optional inputs, learned and trace.
[ "$(fact inputs)" = "head,invariants,learned,main,pr,suites,trace" ] && ok || bad "W: inputs are pr/head/main/suites (got '$(fact inputs)')"
[ "$(fact required)" = "head,main,pr" ] && ok || bad "W: suites is optional, the rest required (got '$(fact required)')"
case "$(fact runs_on)" in *vars.CI_RUNNER*) ok ;; *) bad "W: runs-on reads vars.CI_RUNNER (got '$(fact runs_on)')" ;; esac
[ "$(fact permissions)" = "{'contents': 'read'}" ] && ok || bad "W: permissions are contents: read only (got '$(fact permissions)')"
[ "$(fact timeout)" = 25 ] && ok || bad "W: timeout-minutes is 25 (got '$(fact timeout)')"
RN=$(fact run_name); RN=${RN//'${{ inputs.pr }}'/4545}; RN=${RN//'${{ inputs.head }}'/$H1}; RN=${RN//'${{ inputs.main }}'/$M}
[ -n "$RN" ] && [ "$RN" = "$(title 4545 "$H1" "$M")" ] && ok || bad "W: run-name equals pq_run_title (got '$RN' vs '$(title 4545 "$H1" "$M")')"
# TEST-CHANGE (BH-6335): their env, PQ_LEARNED_IN and PQ_TRACE_IN.
# TEST-CHANGE (BH-6522): PQ_GIT_TOKEN, the job token for the one pull-head fetch.
[ "$(fact env)" = "PQ_GIT_TOKEN,PQ_HEAD,PQ_INVARIANTS_IN,PQ_LEARNED_IN,PQ_MAIN,PQ_PR,PQ_SUITES_IN,PQ_TRACE_IN" ] && ok || bad "W: inputs reach the script through env only (got '$(fact env)')"
grep -q '\${{' "$T/w/run.sh" && bad "W: no \${{ }} expression inside the run script (script injection)" || ok
case "$(fact shell)" in *-e*|None) bad "W: the run step must not use errexit (shell '$(fact shell)')" ;; *) ok ;; esac
[ "$(grep -c 'title=prequeue-verdict' "$T/w/run.sh")" = 1 ] && ok || bad "W: exactly one verdict print in the script"
grep -qE -- '--cap|--budget' "$T/w/run.sh" && bad "W: no --cap/--budget literal: the gate reads its own knob rows" || ok
WORDS=$(grep -oE '\bV=[a-z-]+' "$T/w/run.sh" | sed 's/^V=//' | sort -u | tr '\n' ' ')
PWORDS=$( ( . "$DISPATCH_LIB" >/dev/null 2>&1; printf '%s' "${PQ_VERDICT_RE:-}" ) | sed -E 's/^\^\(([^)]*)\).*/\1/' | tr '|' '\n' | sort -u | tr '\n' ' ')
[ -n "$PWORDS" ] && [ "$WORDS" = "$PWORDS" ] && ok || bad "W: the workflow's verdict words equal the parser's (workflow '$WORDS', parser '$PWORDS')"
SKIP_RE=$(jq -r '.. | objects | select(.env? == "MAIN_RED_SKIP_RE") | .default' "$DIR/catalog/lanes.d/main-red-pr-pair.json")
python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2], re.I) else 1)' "$SKIP_RE" "$(fact name)" && ok \
  || bad "W: the main-red detector's default skip regex '$SKIP_RE' must match the workflow name '$(fact name)'"

# The dry run. A bare origin with main and two pull heads: 41 merges cleanly,
# 42 conflicts. The checkout's bin/test-impact-gate.sh and bin/test-suite-run.sh
# are stubs, so what is driven is the workflow's own script.
O="$T/origin.git"; S="$T/seed"
git init -q --bare "$O"; git init -q "$S"
sg() { git -C "$S" -c user.email=t@example.com -c user.name=t "$@"; }
mkdir -p "$S/bin" "$S/tests"
cat > "$S/bin/test-impact-gate.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$GATE_ARGV"
f=""; while [ $# -gt 0 ]; do [ "$1" = --failed ] && f="$2"; shift; done
[ -n "$f" ] && printf '%s' "${STUB_FAILED:-}" > "$f"
echo "::notice title=prequeue-verdict::green main=$PQ_MAIN head=$PQ_HEAD suites="
exit "${STUB_RC:-0}"
SH
cat > "$S/bin/test-suite-run.sh" <<'SH'
#!/bin/bash
echo "$(cat "$2")" >> "$SUITE_ARGV"
bash "$(cat "$2")"
SH
printf '#!/bin/bash\nexit 1\n' > "$S/tests/a.sh"; printf '#!/bin/bash\nexit 0\n' > "$S/tests/b.sh"
echo base > "$S/x.txt"; sg add -A; sg commit -qm base
echo y > "$S/y.txt"; sg add -A; sg commit -qm head41; HOK=$(git -C "$S" rev-parse HEAD)
sg reset -q --hard HEAD~1; echo head > "$S/x.txt"; sg commit -qam head42; HCONF=$(git -C "$S" rev-parse HEAD)
sg reset -q --hard HEAD~1; echo main > "$S/x.txt"; sg commit -qam main; MS=$(git -C "$S" rev-parse HEAD)
sg push -q "$O" "$MS:refs/heads/main" "$HOK:refs/pull/41/head" "$HCONF:refs/pull/42/head"
# dry <case> <pr> <head> [VAR=value ...] — the run step in a fresh checkout of main.
dry() {
  local c="$1" pr="$2" h="$3"; shift 3
  git clone -q "$O" "$T/wd-$c" 2>/dev/null; git -C "$T/wd-$c" checkout -q "$MS"
  mkdir -p "$T/rt-$c"; : > "$T/suites-$c"
  ( cd "$T/wd-$c" && env PQ_PR="$pr" PQ_HEAD="$h" PQ_MAIN="$MS" PQ_SUITES_IN="" RUNNER_TEMP="$T/rt-$c" \
      GATE_ARGV="$T/gate-$c" SUITE_ARGV="$T/suites-$c" "$@" bash "$T/w/run.sh" ) > "$T/out-$c" 2>&1
  echo "rc=$?" >> "$T/out-$c"
}
# verdict <case> — the ONE verdict printed outside the ::stop-commands:: window.
verdict() {
  awk '/^::stop-commands::/ { tok = substr($0, 18); off = 1; next }
       off && $0 == "::" tok "::" { off = 0; next }
       !off && /^::notice title=prequeue-verdict::/ { sub(/^::notice title=prequeue-verdict::/, ""); print }' "$T/out-$1"
}
nverdicts() { verdict "$1" | grep -c .; }
dry green 41 "$HOK" STUB_RC=0
dry red 41 "$HOK" STUB_RC=1 STUB_FAILED=tests/a.sh
dry rednone 41 "$HOK" STUB_RC=1
dry rc2 41 "$HOK" STUB_RC=2
dry rc125 41 "$HOK" STUB_RC=125
dry conflict 42 "$HCONF" STUB_RC=0
dry moved 41 "$HCONF" STUB_RC=0
dry suites 41 "$HOK" PQ_SUITES_IN="$(printf 'tests/a.sh,tests/b.sh\n')"
dry badsuites 41 "$HOK" PQ_SUITES_IN="tests/../x.sh"
dry badinput "41;x" "$HOK"
for c in green red rednone rc2 rc125 conflict moved suites badsuites badinput; do
  [ "$(nverdicts "$c")" = 1 ] && ok || bad "W dry $c: exactly one verdict outside the stop-commands window (got $(nverdicts "$c"): $(tr '\n' '|' < "$T/out-$c"))"
  grep -qx 'rc=0' "$T/out-$c" && ok || bad "W dry $c: the job exits 0 once it printed a verdict ($(tail -1 "$T/out-$c"))"
done
[ "$(verdict green)" = "green main=$MS head=$HOK suites=" ] && ok || bad "W dry green: got '$(verdict green)'"
[ "$(verdict red)" = "red main=$MS head=$HOK suites=tests/a.sh" ] && ok || bad "W dry red: got '$(verdict red)'"
[ "$(verdict rednone)" = "could-not-run main=$MS head=$HOK suites= why=red-without-suites" ] && ok || bad "W dry rednone: got '$(verdict rednone)'"
[ "$(verdict rc2)" = "no-selection main=$MS head=$HOK suites=" ] && ok || bad "W dry rc2: got '$(verdict rc2)'"
[ "$(verdict rc125)" = "could-not-run main=$MS head=$HOK suites= why=rc-125" ] && ok || bad "W dry rc125: got '$(verdict rc125)'"
[ "$(verdict conflict)" = "conflict main=$MS head=$HCONF suites=" ] && ok || bad "W dry conflict: got '$(verdict conflict)'"
[ "$(verdict moved)" = "could-not-run main=$MS head=$HCONF suites= why=head-moved" ] && ok || bad "W dry moved: got '$(verdict moved)'"
[ "$(verdict suites)" = "red main=$MS head=$HOK suites=tests/a.sh" ] && ok || bad "W dry suites: got '$(verdict suites)'"
[ "$(tr '\n' ' ' < "$T/suites-suites")" = "tests/a.sh tests/b.sh " ] && ok || bad "W dry suites: each suite runs alone through test-suite-run (got '$(cat "$T/suites-suites")')"
[ -e "$T/gate-suites" ] && bad "W dry suites: the impact gate is not run when suites are named" || ok
[ "$(verdict badsuites)" = "could-not-run main=$MS head=$HOK suites= why=bad-suites" ] && ok || bad "W dry badsuites: got '$(verdict badsuites)'"
case "$(verdict badinput)" in "could-not-run "*"why=bad-input") ok ;; *) bad "W dry badinput: got '$(verdict badinput)'" ;; esac
[ "$(cat "$T/gate-green" 2>/dev/null)" = "--base $MS --head HEAD --runner local --failed $T/rt-green/failed" ] && ok \
  || bad "W dry green: the gate's argv (got '$(cat "$T/gate-green" 2>/dev/null)')"
# The verdicts the workflow prints are the ones the reader accepts, for this key.
parse() { ( . "$DISPATCH_LIB" >/dev/null 2>&1; pq_parse_verdict "$@" ); }
[ "$(parse "$(verdict red)" "$HOK" "$MS")" = "red tests/a.sh" ] && ok || bad "W: the reader parses the workflow's red (got '$(parse "$(verdict red)" "$HOK" "$MS")')"
[ "$(parse "$(verdict green)" "$HOK" "$MS")" = "green -" ] && ok || bad "W: the reader parses the workflow's green (got '$(parse "$(verdict green)" "$HOK" "$MS")')"

# ============================================================================
# The conductor fixture (the shape of tests/mc/prequeue-isolation.bh-4545-test.sh).
# ============================================================================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/h/bin/lib/mc-prequeue.d"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/gh-rest-list.sh" "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/autoenqueue.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/mc-hold-comment.sh" "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/mc-prequeue.sh" "$T/h/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/" || exit 1
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/" || exit 1
[ -r "$DISPATCH_LIB" ] && cp "$DISPATCH_LIB" "$T/h/bin/lib/mc-prequeue.d/"
printf 'to_lane_hold() { return 1; }\nto_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }\n' > "$T/h/bin/lib/ticket-ownership.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
# The alert path: one ALERTS line per call, the way bin/lane-alert.sh writes one.
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
# The hub's own gate: never run by the conductor, the workflow runs it on CI.
printf '#!/bin/bash\ntouch "%s/gate-ran"\n' "$T" > "$T/h/bin/test-impact-gate.sh"; chmod +x "$T/h/bin/test-impact-gate.sh"
REC="$T/h/builds/pool-demo-BH-20-202610050001"; mkdir -p "$REC"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
MCD="$T/h/state/merge-conductor"
# The stub gh. On top of the tracer suite's arms: the workflow probe (404 while
# $T/no-wf exists), the runs list ($T/runs.json), a run's jobs ($T/jobs.json),
# a check run's annotations ($T/ann.json), and the dispatch, whose argv goes to
# $T/dispatch.txt followed by the cache entry as it stood at that moment (the
# order proof), and whose rc is $T/dispatch.rc.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
N=\$(cat "$T/num")
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run prequeue-gate.yml"*)
    { printf '%s\n' "\$*"; printf 'cache-at-dispatch: '; cat "$MCD/prequeue/example-org_demo-os_\${N}_\$(cat "$T/head41")_$M" 2>/dev/null || echo none; } >> "$T/dispatch.txt"
    exit "\$(cat "$T/dispatch.rc" 2>/dev/null || echo 0)" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*) restpr --raw 200 "\$(cat "$T/runs.json")" ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    if [ -e "$T/no-wf" ]; then restpr --raw 404 '{"message":"Not Found"}'; else restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}'; fi ;;
  *"api -i -X GET repos/$SLUG/actions/runs/77/jobs"*) restpr --raw 200 "\$(cat "$T/jobs.json")" ;;
  *"api -i -X GET repos/$SLUG/check-runs/88/annotations"*) restpr --raw 200 "\$(cat "$T/ann.json")" ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 '{"sha":"$M"}' ;;
  # TEST-CHANGE (BH-6335): the reuse of an older main's verdict now reads how
  # far main moved (pq_main_behind). The older main is one commit behind.
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/\$N/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$T/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/\$N"*) restpr OPEN "\$(cat "$T/head41")" ticket/bh-20 main "" MERGEABLE CLEAN operator "" "Closes #20" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

MCLOG="$T/h/logs/merge-conductor.log"
ALERTS="$T/h/logs/ALERTS.log"
ROWS="$MCD/pr-state.tsv"
PQD="$MCD/prequeue"
NUM=41
# reset [num] — #<num> approved and green at H1, a fresh state, no runs, no
# dispatches. KEEP=1 keeps the verdict cache and ALERTS.log (a later tick of the
# same key, re-asked from READY).
reset() {
  NUM="${1:-41}"
  if [ "${KEEP:-0}" = 1 ]; then rm -rf "$T/keep"; mkdir -p "$T/keep"; cp -a "$PQD" "$T/keep/pq" 2>/dev/null; cp "$ALERTS" "$T/keep/alerts" 2>/dev/null; fi
  rm -f "$T/c-enq.txt" "$T/tick.err" "$T/no-wf" "$T/dispatch.rc" "$T/gate-ran"
  : > "$T/c-enq.txt"
  scratch_rm "$MCD"; scratch_rm "$T/h/state/tier2-autoenqueue.txt"
  rm -f "$T/h/logs/"*.log; mkdir -p "$MCD"; : > "$ROWS"
  if [ "${KEEP:-0}" = 1 ]; then
    [ -d "$T/keep/pq" ] && cp -a "$T/keep/pq" "$PQD"; [ -r "$T/keep/alerts" ] && cp "$T/keep/alerts" "$ALERTS"
  else
    : > "$T/dispatch.txt"; echo '{"workflow_runs":[]}' > "$T/runs.json"; echo '[]' > "$T/ann.json"
    echo '{"jobs":[{"id":88,"name":"gate"}]}' > "$T/jobs.json"
  fi
  echo "$NUM" > "$T/num"; echo "$H1" > "$T/head41"
  echo "PR_CREATED $U/$NUM" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
  cat > "$T/list.json" <<J
[{"number":$NUM,"url":"$U/$NUM","headRefOid":"$H1","headRefName":"ticket/bh-20","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}]
J
  touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
}
tick() {
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_DETACHED_REBASE=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$T/tick.err"; }
}
# put <main> <state> <dispatched_at> [suites] — one cache entry for (#NUM, H1), through the tracer's writer.
put() {
  ( MC_STATE_DIR="$MCD" P=demo
    . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1 || exit 1
    pq_cache_put "$(pq_key "$SLUG" "$NUM" "$H1" "$1")" "$2" "$3" - "${4:-}" ) || bad "fixture: pq_cache_put failed for $*"
}
cache() { head -n1 "$PQD/example-org_demo-os_${NUM}_${2:-$H1}_${1:-$M}" 2>/dev/null; }
# run <conclusion|-> [title] — one run in the list, completed unless conclusion is -.
run() {
  local c="$1" t="${2:-$(title "$NUM" "$H1" "$M")}"
  if [ "$c" = - ]; then jq -nc --arg t "$t" '{workflow_runs:[{id:77,display_title:$t,status:"in_progress",conclusion:null,created_at:"2026-10-05T01:00:00Z"}]}'
  else jq -nc --arg t "$t" --arg c "$c" '{workflow_runs:[{id:77,display_title:$t,status:"completed",conclusion:$c,created_at:"2026-10-05T01:00:00Z"}]}'; fi > "$T/runs.json"
}
# ann <message>... — the verdict annotations on job 88 (plus one unrelated).
ann() {
  { printf '%s\n' '{"title":"other","message":"x"}'
    for m in "$@"; do jq -nc --arg m "$m" '{title:"prequeue-verdict",message:$m,annotation_level:"notice"}'; done; } | jq -sc . > "$T/ann.json"
}
K() { printf '%s#%s' "$SLUG" "$NUM"; }
state()  { awk -F'\t' -v k="$(K)" '$1==k {print $2}' "$ROWS"; }
reason() { awk -F'\t' -v k="$(K)" '$1==k {print $7}' "$ROWS"; }
enq()  { grep -c "issues/$NUM/comments\|issues/$NUM/labels\|pulls/$NUM/merge\|pr merge $U/$NUM" "$T/c-enq.txt" 2>/dev/null || true; }
ndisp() { grep -c '^workflow run prequeue-gate.yml' "$T/dispatch.txt" 2>/dev/null || true; }
nalerts() { grep -c "prequeue gate could-not-run on head ${H1:0:12} main ${1:-${M:0:12}}" "$ALERTS" 2>/dev/null || true; }
why() { cat "$MCD/ready-why/"* 2>/dev/null; }
display() { ( . "$T/h/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1; mc_state_display "$1" "$2" ); }
clog() { grep -F "$(K)" "$MCLOG" 2>/dev/null | tail -"${1:-6}"; }
enqueued() {
  [ "$(enq)" -ge 1 ] && ok || bad "$1: the head must be enqueued (argv: $(cat "$T/c-enq.txt"); state '$(state)'; log: $(clog))"
  [ "$(state)" != BLOCKED_HUMAN ] && ok || bad "$1: the row must not be parked (reason '$(reason)')"
}
held() {
  [ "$(enq)" = 0 ] && ok || bad "$1: nothing enqueued on a hold (argv: $(cat "$T/c-enq.txt"))"
  [ "$(state)" = READY ] && ok || bad "$1: the row stays READY (state '$(state)'; log: $(clog))"
  grep -q "	$H1	prequeue-pending	" <<<"$(why)" && ok || bad "$1: ready-why says prequeue-pending (note: $(why))"
}

# ============================================================================
# L1. No workflow on the repo: proceed, silent, nothing written.
# ============================================================================
reset; touch "$T/no-wf"; tick
enqueued L1
[ "$(ndisp)" = 0 ] && ok || bad "L1: no dispatch (got $(cat "$T/dispatch.txt"))"
grep -q prequeue "$ALERTS" 2>/dev/null && bad "L1: no alert (alerts: $(cat "$ALERTS"))" || ok
[ -z "$(ls -A "$PQD" 2>/dev/null)" ] && ok || bad "L1: no cache entry (got $(ls "$PQD"))"

# ============================================================================
# L2. First sight: one dispatch, pending written FIRST, held.
# ============================================================================
reset; tick
[ "$(ndisp)" = 1 ] && ok || bad "L2: exactly one dispatch (got $(ndisp): $(cat "$T/dispatch.txt"); err: $(tail -3 "$T/tick.err"))"
D=$(grep '^workflow run prequeue-gate.yml' "$T/dispatch.txt")
case "$D" in *"-R $SLUG --ref main "*"-f pr=41"*"-f head=$H1"*"-f main=$M"*) ok ;; *) bad "L2: the dispatch argv (got '$D')" ;; esac
grep -q '^cache-at-dispatch: pending ' "$T/dispatch.txt" && ok || bad "L2: pending is on disk BEFORE the dispatch call (got $(grep cache-at "$T/dispatch.txt"))"
case "$(cache)" in "pending "*) ok ;; *) bad "L2: the cache entry is pending (got '$(cache)')" ;; esac
held L2
grep -q "prequeue-gate.yml dispatched for main ${M:0:12}" <<<"$(why)" && ok || bad "L2: the hold says what it waits on (note: $(why))"
[ -e "$T/gate-ran" ] && bad "L2: the hub's own gate is never run" || ok
# Still running on the next tick: held, no second dispatch.
KEEP=1 reset; run -; tick
[ "$(ndisp)" = 1 ] && ok || bad "L2: a pending run is not dispatched again (got $(ndisp))"
held "L2 tick 2"

# ============================================================================
# L3. The run lands green: proceed, recorded, never re-run for this key.
# ============================================================================
KEEP=1 reset; run success; ann "green main=$M head=$H1 suites="; tick
enqueued L3
case "$(cache)" in "green "*) ok ;; *) bad "L3: the cache records green (got '$(cache)')" ;; esac
KEEP=1 reset; tick
enqueued "L3 re-asked"
[ "$(ndisp)" = 1 ] && ok || bad "L3: an exact-key hit dispatches nothing (got $(ndisp))"

# ============================================================================
# L4. The run lands red: parked prequeue-red naming both suites.
# ============================================================================
reset; tick; KEEP=1 reset; run success; ann "red main=$M head=$H1 suites=tests/a.sh,tests/b.sh"; tick
[ "$(enq)" = 0 ] && ok || bad "L4: a red is not enqueued (argv: $(cat "$T/c-enq.txt"))"
[ "$(state)" = BLOCKED_HUMAN ] && [ "$(display "$(state)" "$(reason)")" = BLOCKED_AGENT ] && ok \
  || bad "L4: parked, displayed BLOCKED_AGENT (state '$(state)', reason '$(reason)'; err: $(tail -3 "$T/tick.err"))"
case "$(reason)" in "prequeue-red: tests/a.sh,tests/b.sh on main ${M:0:12}"*) ok ;; *) bad "L4: the park reason names both suites (got '$(reason)')" ;; esac
case "$(cache)" in "red "*"tests/a.sh,tests/b.sh") ok ;; *) bad "L4: the cache records red with both suites (got '$(cache)')" ;; esac
grep -q prequeue "$ALERTS" 2>/dev/null && bad "L4: a red is a park, not an alert" || ok

# ============================================================================
# L5. Main moved.
# ============================================================================
# L5a/L5b pin the dispatch-time rule, which is MC_PREQUEUE_REUSE=0 since BH-5572;
# tests/prequeue-reuse.bh-5572-test.sh pins the reuse rule (REUSE=1).
reset; put "$M_OLD" green $((NOW - 600)); tick MC_PREQUEUE_REUSE=0
enqueued "L5a fresh green on an older main"
[ "$(ndisp)" = 0 ] && ok || bad "L5a: no dispatch inside FRESH_S (got $(ndisp))"
reset; put "$M_OLD" green $((NOW - 2000)); tick MC_PREQUEUE_REUSE=0
[ "$(ndisp)" = 1 ] && grep -q -- "-f main=$M" "$T/dispatch.txt" && ok || bad "L5b: past FRESH_S, one dispatch for the new main (got $(cat "$T/dispatch.txt"))"
held L5b
reset; put "$M_OLD" red $((NOW - 600)) tests/a.sh; tick
[ "$(state)" = BLOCKED_HUMAN ] && [ "$(ndisp)" = 0 ] && ok || bad "L5a red: a fresh red on an older main parks, no dispatch (state '$(state)', dispatches $(ndisp))"
case "$(reason)" in "prequeue-red: tests/a.sh on main ${M_OLD:0:12}"*) ok ;; *) bad "L5a red: the reason names the main it failed on (got '$(reason)')" ;; esac
reset; put "$M_OLD" pending $((NOW - 600)); run - "$(title 41 "$H1" "$M_OLD")"; tick
[ "$(ndisp)" = 0 ] && ok || bad "L5c: a fresh pending sibling is not re-dispatched (got $(ndisp))"
held L5c
grep -q "prequeue run for main ${M_OLD:0:12} still running" <<<"$(why)" && ok || bad "L5c: the hold names the main it waits on (note: $(why))"
# ...and once that sibling's run lands, the miss settles it and acts on it.
reset; put "$M_OLD" pending $((NOW - 600)); run success "$(title 41 "$H1" "$M_OLD")"; ann "green main=$M_OLD head=$H1 suites="; tick
enqueued "L5d a settled sibling's green"
case "$(cache "$M_OLD")" in "green "*) ok ;; *) bad "L5d: the sibling is recorded green (got '$(cache "$M_OLD")')" ;; esac
[ "$(ndisp)" = 0 ] && ok || bad "L5d: no dispatch (got $(ndisp))"

# ============================================================================
# L6-L9. Every other answer is could-not-run: enqueued, never parked, ONE alert
# over two asks of the same key.
# ============================================================================
# cnr <case> <why> — after the setup: tick, then re-ask the same key from READY.
cnr() {
  tick
  enqueued "$1"
  case "$(cache)" in "could-not-run "*" alerted"*) ok ;; *) bad "$1: the cache is could-not-run, alerted (got '$(cache)')" ;; esac
  grep -q "($2" "$ALERTS" 2>/dev/null && ok || bad "$1: the alert names why '$2' (alerts: $(cat "$ALERTS" 2>/dev/null))"
  grep -qF "$U/$NUM" "$ALERTS" 2>/dev/null && ok || bad "$1: the alert carries the PR url"
  KEEP=1 reset "$NUM"; tick
  enqueued "$1 re-asked"
  [ "$(nalerts)" = 1 ] && ok || bad "L9 $1: exactly one ALERTS line over two ticks (got $(nalerts): $(cat "$ALERTS" 2>/dev/null))"
}
pend() { reset "${1:-41}"; put "$M" pending $((NOW - 60)); }
pend; run success; ann "green main=$M head=$H2 suites="; cnr "L6a another head" stale-head
pend; run success; ann "red main=$M_OLD head=$H1 suites=tests/a.sh"; cnr "L6b another main" stale-main
pend; run cancelled; ann "red main=$M head=$H1 suites=tests/a.sh"; cnr "L7a cancelled" cancelled
pend; run timed_out; ann "red main=$M head=$H1 suites=tests/a.sh"; cnr "L7b timed_out" timed_out
pend; run success; ann; cnr "L7c no annotation" annotation-count-0
pend; run success; ann "red main=$M head=$H1 suites=tests/a.sh" "green main=$M head=$H1 suites="; cnr "L7d two annotations" annotation-count-2
pend; run success; ann "RED main=$M head=$H1 suites=tests/a.sh"; cnr "L8a RED" malformed
pend; run success; ann "red main=$M head=$H1 suites="; cnr "L8b red naming no suite" red-without-suites
pend; run success; ann "green main=$M head=$H1 suites= "; cnr "L8c trailing space" malformed
pend; run success; ann "could-not-run main=$M head=$H1 suites= why=head-moved"; cnr "L8g the workflow's own could-not-run" head-moved
# L8d. PR #4545 sees only runs that are not exactly its title: held under the
# deadline, then could-not-run (deadline).
pend 4545
jq -nc --arg a "prequeue pr=45 head=$H1 main=$M" --arg b "$(title 4545 "$H1" "$M") extra" \
  '{workflow_runs:[{id:77,display_title:$a,status:"completed",conclusion:"success",created_at:"2026-10-05T01:00:00Z"},
                   {id:77,display_title:$b,status:"completed",conclusion:"success",created_at:"2026-10-05T01:00:01Z"}]}' > "$T/runs.json"
ann "red main=$M head=$H1 suites=tests/a.sh"; tick
held "L8d not this PR's run"
[ "$(state)" != BLOCKED_HUMAN ] && ok || bad "L8d: another PR's red never parks this one"
case "$(cache)" in "pending "*) ok ;; *) bad "L8d: still pending under the deadline (got '$(cache)')" ;; esac
KEEP=1 reset 4545; put "$M" pending $((NOW - 3000)); cnr "L8d past the deadline" deadline
# L8e/f. no-selection and conflict are verdicts: enqueued, no alert.
for v in no-selection conflict; do
  pend; run success; ann "$v main=$M head=$H1 suites="; tick
  enqueued "L8 $v"
  case "$(cache)" in "$v "*) ok ;; *) bad "L8 $v: recorded (got '$(cache)')" ;; esac
  grep -q prequeue "$ALERTS" 2>/dev/null && bad "L8 $v: no alert (alerts: $(cat "$ALERTS"))" || ok
done

# ============================================================================
# E3. A refused dispatch: enqueued the same tick, one alert, the hub's gate untouched.
# ============================================================================
reset; echo 1 > "$T/dispatch.rc"; tick
enqueued E3
grep -q '@mergifyio queue' "$T/c-enq.txt" && ok || bad "E3: a @mergifyio queue enqueue (argv: $(cat "$T/c-enq.txt"))"
case "$(cache)" in "could-not-run "[0-9]*" dispatch-refused alerted"*) ok ;; *) bad "E3: the cache says dispatch-refused, alerted (got '$(cache)')" ;; esac
[ "$(grep -c could-not-run "$ALERTS" 2>/dev/null)" = 1 ] && ok || bad "E3: exactly one could-not-run ALERTS line (got: $(cat "$ALERTS" 2>/dev/null))"
[ -e "$T/gate-ran" ] && bad "E3: the hub's own bin/test-impact-gate.sh is never executed" || ok
KEEP=1 reset; echo 1 > "$T/dispatch.rc"; tick
[ "$(ndisp)" = 1 ] && [ "$(nalerts)" = 1 ] && ok || bad "E3: re-asked, no second dispatch and no second alert (dispatches $(ndisp), alerts $(nalerts))"

# ============================================================================
# L10. The prune: older than 7 days goes, once per tick.
# ============================================================================
reset; mkdir -p "$PQD"
echo "green 1 -" > "$PQD/example-org_demo-os_9_${H2}_$M"; touch -d "@$((NOW - 8 * 86400))" "$PQD/example-org_demo-os_9_${H2}_$M"
echo "green 1 -" > "$PQD/example-org_demo-os_8_${H2}_$M"
tick
[ -e "$PQD/example-org_demo-os_9_${H2}_$M" ] && bad "L10: an 8-day-old entry is pruned" || ok
[ -e "$PQD/example-org_demo-os_8_${H2}_$M" ] && ok || bad "L10: today's entry stays"
# Once per tick: a second call under the same MC_TICK_ID prunes nothing.
( MC_STATE_DIR="$MCD" MC_TICK_DIR="$T/l10tick" MC_TICK_ID=t1
  mc_safe_name() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
  . "$T/h/bin/lib/mc-prequeue.sh" >/dev/null 2>&1
  pq_prune
  echo x > "$PQD/old2"; touch -d "@$((NOW - 9 * 86400))" "$PQD/old2"
  pq_prune
  [ -e "$PQD/old2" ] || exit 1
  MC_TICK_ID=t2; pq_prune; [ ! -e "$PQD/old2" ] ) && ok || bad "L10: pq_prune runs once per tick id, and again on the next tick"

echo "prequeue-dispatch.bh-4548: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
