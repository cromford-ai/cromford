#!/bin/bash
# tests/mc-ci-record.bh-9936-test.sh — BH-9936 (BH-9926.4): the REAL
# bin/merge-conductor.sh keyed tick (MC_ONLY_PR) reads its CI word through
# prr_read (lane merge-conductor, row lane.merge-conductor.gh_source).
#
#   M1  GH_SOURCE=record, the PR record holds a complete green check set for the
#       head: 0 check-runs and 0 actions/runs calls, and the row is not WAIT_CI
#   M2  GH_SOURCE=shadow: exactly 1 actions/runs?head_sha= call (the conductor
#       still acts on GitHub) and 1 pr-records GET
#   M3  GH_SOURCE=record, the jobs worker answers 500: 1 actions/runs call and
#       1 PRR_MISS line (fail open to GitHub)
#
# The fixture is the one of tests/mc-ci-read-bound.bh-6346-test.sh: a stub `gh`
# that logs every call, a stub `curl` jobs worker. No network, no clock read by
# an assertion. Everything under $T.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-ci-record.bh-9936-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID GH_SOURCE
hd() { printf '%02d%038d' "$1" 0; }

SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
F="$T/f"
mkdir -p "$F/h/logs" "$F/h/state/merge-conductor" "$F/h/flags" "$F/h/locks" "$F/h/builds" "$F/h/env" "$F/h/tmp" "$F/fakebin"
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
for s in bin/merge-conductor.sh bin/fleet-conf.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$F/h" >/dev/null || { echo "closure install failed for $s"; exit 1; }
done
scratch_rm "$F/h/bin/lib/gh-limit-logger.sh"
for f in bin/lib/prr-shadow.sh bin/lib/prr-ci-state.sh bin/lib/prr-shadow.d/merge-conductor.sh bin/lib/pr-record.sh; do
  [ -r "$F/h/$f" ] && ok || bad "setup: the conductor's closure must carry $f"
done
mkdir -p "$F/h/catalog" && cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$F/h/catalog/" || exit 1
printf 'demo %s - - 2 box-m\n' "$SLUG" > "$F/h/fleet.conf"
: > "$F/h/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/$s.sh"; chmod +x "$F/h/bin/$s.sh"; done
printf '#!/bin/bash\nexit 0\n' > "$F/h/bin/lane-alert.sh"; chmod +x "$F/h/bin/lane-alert.sh"
REC="$F/h/builds/pool-demo-BH-1-202611240001"; mkdir -p "$REC"
echo "PR_CREATED $U/1" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
hd 1 > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
cp "$DIR/tests/lib/rest-emit.sh" "$F/fakebin/restpr"; chmod +x "$F/fakebin/restpr"
jq -nc --arg s "$SLUG" --arg h "$(hd 1)" '[{number:1, html_url:("https://github.com/"+$s+"/pull/1"),
  title:"t", body:"", draft:false, state:"open", merged_at:null, labels:[], user:{login:"operator",type:"User"},
  updated_at:"2026-11-24T00:00:00Z", head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:$s}},
  base:{ref:"main", repo:{full_name:$s}}, mergeable_state:"clean", mergeable:true}]' > "$F/open.json"
# The PR record the jobs worker serves: open, head = hd 1, every check completed/success on it.
jq -nc --arg h "$(hd 1)" '{repo:"example-org/demo", number:1, state:"open", head_sha:$h,
  checks:{"Build + Unit tests":{status:"completed",conclusion:"success",sha:$h,at:"2026-11-24T00:10:00Z"},
          "workflow:Harness CI":{status:"completed",conclusion:"success",sha:$h,at:"2026-11-24T00:10:00Z"},
          "Summary":{status:"completed",conclusion:"success",sha:$h,at:"2026-11-24T00:10:00Z"}}}' > "$F/record.json"
cat > "$F/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$F/c-calls.txt"
A="\$*"
N=\$(grep -oE '(pulls|issues)/[0-9]+' <<<"\$A" | head -1 | grep -oE '[0-9]+\$')
case "\$A" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"git/matching-refs/heads/"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/branches/ticket/bh-"*) restpr --raw 200 '{"name":"ticket/bh-1","commit":{"sha":"'"\$(printf '%02d%038d' 1 0)"'"}}' ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$F/open.json")" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-11-24T00:00:00Z"}]}' ;;
  *"-X POST"*|*"-X DELETE"*|*"-X PATCH"*|*"-X PUT"*|*"pr close"*|*"pr edit"*|*"issue close"*|*"pr merge"*) printf '%s\n' "\$A" >> "$F/c-writes.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api --paginate repos/"*"/comments"*) echo '[]' ;;
  *"api repos/$SLUG/issues/"*) printf '{"number":%s,"state":"open","labels":[],"body":""}\n' "\$N" ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr OPEN "\$(printf '%02d%038d' "\$N" 0)" "ticket/bh-\$N" main "" MERGEABLE CLEAN operator "" "" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
esac
exit 0
EOF
chmod +x "$F/fakebin/gh"
# The jobs worker. $F/jobs-down = every pr-records request answers 500.
cat > "$F/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$URL" in *"/api/lead-protected-paths"*) "\$(dirname "\$0")/lpp-answer" "\$M" "\$URL"; exit 0 ;; esac
case "\$URL" in *"/api/pr-records"*) printf '%s %s\n' "\$M" "\${URL#*worker.test}" >> "$F/jobs.log" ;; esac
case "\$M \$URL" in
  *"/api/pr-records"*) [ -f "$F/jobs-down" ] && { printf '{"error":"boom"}\n500\n'; exit 0; } ;;
esac
case "\$M \$URL" in
  "GET "*"/api/pr-records?repo=example-org/demo&number=1") printf '{"row":%s,"age_s":5}\n200\n' "\$(cat "$F/record.json")" ;;
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$F/fakebin/curl"
. "$DIR/tests/lib/lpp-stub.sh" || exit 1
lpp_set "$F/lpp.json" "$SLUG"
lpp_install "$F/fakebin" "$F/lpp.json" "$F/lpp-down"
CLOG="$F/h/logs/merge-conductor.log"
ROWS="$F/h/state/merge-conductor/pr-state.tsv"
PLOG="$F/h/logs/prr-shadow.log"
# fresh — a clean state dir (no read memo) with one WAIT_CI row for #1.
fresh() { scratch_rm "$F/h/state"; mkdir -p "$F/h/state/merge-conductor"
  printf '%s\t%s\t%s\t%s\t%s\t-\t-\t%s/%s\n' "$SLUG#1" WAIT_CI 1795000000 "$(hd 1)" "$(hd 1)" "$U" 1 > "$ROWS"
  : > "$F/c-calls.txt"; : > "$F/jobs.log"; rm -f "$F/jobs-down" "$PLOG"; touch "$F/c-writes.txt"; }
ENVC=(PATH="$F/fakebin:$PATH" HARNESS="$F/h" FLEET_CONF="$F/h/fleet.conf" HARNESS_SECRET=x JOBS_URL=http://worker.test
  GH_TOKEN=pat-fixture-default HARNESS_PR_AUTHORS=operator GH_ETAG=0 JOBS_RETRIES=0
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 MC_HEAD_LAG_MINS=10 MC_STEP_POLL_S=1 MC_ONLY_PR="$SLUG#1"
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_PREQUEUE_GATE=0)
tick() { ( unset -f gh; cd "$F" && env -u MC_STEP_HOLD_MAX -u MC_CI_READ_TIMEOUT_S -u MC_STEP_TIMEOUT_S -u MC_STEP_SLOW_S "${ENVC[@]}" \
  "$@" bash "$F/h/bin/merge-conductor.sh" > "$F/mc.out" 2>&1 ); }
calls() { grep -cF -- "$1" "$F/c-calls.txt" 2>/dev/null || true; }
row_state() { awk -F'\t' -v k="$SLUG#1" '$1==k {print $2}' "$ROWS" 2>/dev/null | tail -1; }

# M1 — record step: 0 CI reads on GitHub.
fresh
tick GH_SOURCE=record
[ "$(calls 'actions/runs')" = 0 ] && ok || bad "M1 record step: 0 actions/runs calls, got $(calls 'actions/runs'): $(grep 'actions/runs' "$F/c-calls.txt")"
[ "$(calls 'check-runs')" = 0 ] && ok || bad "M1 record step: 0 check-runs calls, got $(calls 'check-runs')"
[ "$(grep -c '^GET /api/pr-records?repo=example-org/demo&number=1' "$F/jobs.log" 2>/dev/null)" -ge 1 ] && ok || bad "M1 the tick read the PR record: $(cat "$F/jobs.log" 2>/dev/null)"
S=$(row_state)
[ -n "$S" ] && [ "$S" != WAIT_CI ] && ok || bad "M1 the row is not WAIT_CI (got '$S'); log: $(grep -F "$SLUG#1" "$CLOG" 2>/dev/null | tail -3)"
# BH-9938 C1: the open list also reads through prr_read now; this fixture has
# no record list, so its key ($SLUG#open) misses and reads GitHub. The CI read
# (key $SLUG#<n>@<sha12>) and the flake read still log nothing on a hit.
PL_CI=$(grep -v " key=$SLUG#open " "$PLOG" 2>/dev/null)
[ -z "$PL_CI" ] && ok || bad "M1 a record hit logs nothing: $PL_CI"

# M2 — shadow step: the GitHub read stays, and the record is read beside it.
fresh
tick GH_SOURCE=shadow
[ "$(calls 'actions/runs?head_sha=')" = 1 ] && ok || bad "M2 shadow step: exactly 1 actions/runs read, got $(calls 'actions/runs?head_sha=')"
[ "$(grep -c '^GET /api/pr-records?repo=example-org/demo&number=1' "$F/jobs.log" 2>/dev/null)" = 1 ] && ok || bad "M2 shadow step: 1 pr-records GET: $(cat "$F/jobs.log" 2>/dev/null)"
N=$(grep -c PRR_SHADOW "$PLOG" 2>/dev/null); [ "${N:-0}" = 0 ] && ok || bad "M2 both green: no PRR_SHADOW line: $(cat "$PLOG" 2>/dev/null)"

# M3 — record step, jobs worker down: GitHub read, PRR_MISS.
fresh; touch "$F/jobs-down"
tick GH_SOURCE=record
[ "$(calls 'actions/runs?head_sha=')" = 1 ] && ok || bad "M3 record miss: 1 actions/runs read, got $(calls 'actions/runs?head_sha=')"
[ "$(grep -c "PRR_MISS lane=merge-conductor key=$SLUG#1@$(hd 1 | cut -c1-12) why=ci:unknown fallback=github" "$PLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "M3 one PRR_MISS line: $(cat "$PLOG" 2>/dev/null)"


echo "mc-ci-record.bh-9936: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
