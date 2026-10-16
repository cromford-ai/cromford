#!/bin/bash
# tests/lane-identity.bh-2537-test.sh — BH-2667 (BH-2537.2): the pre-plan,
# review-prs, merge-conductor re-review and lead-review lanes declare the
# ticket or PR they are paying for, so the cost row bin/lib/cost-row.sh writes
# for the call carries it (cost_row_tags falls back to AGENT_CALL_TICKET /
# AGENT_CALL_PR since #2665).
#
#   T9a  bin/run-preplan.sh           AGENT_CALL_TICKET=<KEY>, no AGENT_CALL_FP
#   T9b  bin/review-prs.sh            AGENT_CALL_PR=https://github.com/<slug>/pull/<n>;
#                                     no slug = no call and no URL built from the project
#   T9c  mc_rereview (bin/lib/mc)     AGENT_CALL_PR for <slug>#<num>
#   T9d  bin/lead-review.sh tick      AGENT_CALL_PR on the call AND the format retry
#
# The PR lanes declare the PR only, never a ticket. Every case drives the REAL
# lane with a stub bin/agent-call.sh that appends what it was handed to a sink,
# on the fixtures of the suites that already drive each lane
# (run-preplan-prompt.bh-580, review-prs-d1-hold.bh-2457,
# mc-rereview-model.bh-998, lead-review-lane.bh-2202).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-identity.bh-2537-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# Whatever session runs this suite may carry its own identity; the lanes must
# be the only source of what the sink sees.
unset AGENT_CALL_TICKET AGENT_CALL_PR AGENT_CALL_FP HARNESS_TICKET
RES="$T/results"; : > "$RES"
ok()  { echo PASS >> "$RES"; }
bad() { echo "FAIL: $1" | tee -a "$RES"; }
export SINK="$T/sink" RES

# The sink line every stub writes. ${VAR-<unset>} keeps "set but empty"
# apart from "never set".
SINK_LINE='printf "stage=%s AGENT_CALL_TICKET=%s AGENT_CALL_PR=%s AGENT_CALL_FP=%s\n" "$1" "${AGENT_CALL_TICKET-<unset>}" "${AGENT_CALL_PR-<unset>}" "${AGENT_CALL_FP-<unset>}" >> "$SINK"'
sink() { cat "$SINK" 2>/dev/null; }

# ---------- T9a: run-preplan declares its ticket ----------------------------
t9a() {
  local P="$T/pp"
  mkdir -p "$P/bin/lib" "$P/env" "$P/flags" "$P/logs" "$P/plans" "$P/locks" "$P/repos/proj"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$P" proj || exit 1
  cp "$DIR/bin/run-preplan.sh" "$P/bin/"
  cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/test-home-lib.sh" "$P/bin/lib/"
  : > "$P/env/global.env"
  { echo '#!/bin/bash'; echo "$SINK_LINE"; echo 'exit 0'; } > "$P/bin/agent-call.sh"
  printf '#!/bin/bash\nexit 0\n' > "$P/bin/git"
  chmod +x "$P/bin/agent-call.sh" "$P/bin/git"
  : > "$SINK"
  PATH="$P/bin:$PATH" HARNESS="$P" REPOS_ROOT="$P/repos" bash "$P/bin/run-preplan.sh" proj 1 BH-77 >/dev/null 2>&1
  local rc=$?
  [ "$rc" = 0 ] && ok || bad "T9a the pre-plan lane must exit 0 against the scratch tree (rc: $rc)"
  [ "$(sink | wc -l)" -eq 1 ] && ok || bad "T9a expected exactly one agent call: $(sink)"
  sink | grep -q '^stage=preplan AGENT_CALL_TICKET=BH-77 ' && ok \
    || bad "T9a the preplan call must declare AGENT_CALL_TICKET=BH-77: $(sink)"
  sink | grep -q ' AGENT_CALL_FP=<unset>$' && ok \
    || bad "T9a the preplan call must not declare an AGENT_CALL_FP: $(sink)"
}

# ---------- T9b: review-prs declares its PR ---------------------------------
t9b() {
  local R="$T/rp" FB="$T/rp-fakebin"
  mkdir -p "$FB"
  # One open PR, #12; no review of its head on GitHub.
  cat > "$FB/gh" <<'STUB'
#!/bin/bash
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  printf '12\thead12aaaaaa\texternaldev\tChange under review\n'
elif [ "${1:-}" = api ] && [[ "$*" == */pulls/*/reviews* ]]; then
  Q=""; prev=""
  for a in "$@"; do [ "$prev" = "-q" ] && Q="$a"; prev="$a"; done
  printf '[]' | "$REAL_JQ" -r "${Q:-.}"
elif [ "${1:-}" = pr ] && [ "${2:-}" = diff ]; then
  if [[ "$*" == *--name-only* ]]; then printf 'lib/pricing.ts\n'
  else printf 'diff --git a/a.ts b/a.ts\n+const changed = true\n'; fi
elif [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  printf '\n'
fi
exit 0
STUB
  chmod +x "$FB/gh"
  # The bridge answers the lane's REST list reads from the stub's `pr list`.
  REAL_JQ=$(command -v jq); export REAL_JQ
  . "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1
  rp_harness() {
    scratch_rm "$R" || exit 1
    mkdir -p "$R/bin/lib" "$R/state" "$R/logs" "$R/locks" "$R/env" "$R/builds"
    { echo '#!/bin/bash'; echo "$SINK_LINE"
      echo "printf 'Static review.\nTIER: 2\nVERDICT: REQUEST_CHANGES\n' > \"\$5\""
      echo "printf 'claude\n' > \"\$5.runner\""; } > "$R/bin/agent-call.sh"
    printf '#!/bin/bash\necho subscription\n' > "$R/bin/billing-mode.sh"
    printf '#!/bin/bash\nexit 0\n' | tee "$R/bin/beat.sh" "$R/bin/deploy-request.sh" "$R/bin/merge-queue.sh" >/dev/null
    chmod +x "$R/bin/"*.sh
    cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/e2e-paths.sh" "$R/bin/lib/"
    cp "$DIR/bin/alert-line.sh" "$R/bin/"
    mrs_fixture "$R" proj
    printf '{}\n' > "$R/state/proj.pr-reviews.json"
    : > "$SINK"
  }
  rp_run() { # rp_run <fleet.conf repo column>
    printf '# project repo prod board offset box\nproj %s https://proj.test /api/board 1 box-demo\n' "$1" > "$T/rp-fleet.conf"
    env -u AGENT_CALL_RUNNERS -u CALL_GUARD_FAIL_CLOSED_METERED -u HARNESS_SECRET JOBS_URL= \
      PATH="$FB:$PATH" HARNESS="$R" FLEET_CONF="$T/rp-fleet.conf" \
      bash "$DIR/bin/review-prs.sh" proj > "$T/rp.out" 2>&1
  }
  # (i) the registry names the repo: the call carries the canonical PR URL.
  rp_harness; rp_run acme/widgets
  [ "$(sink | wc -l)" -eq 1 ] && ok || bad "T9b(i) expected one review call: $(sink) / $(tail -5 "$T/rp.out")"
  sink | grep -q '^stage=review .* AGENT_CALL_PR=https://github.com/acme/widgets/pull/12 ' && ok \
    || bad "T9b(i) the review call must declare AGENT_CALL_PR=https://github.com/acme/widgets/pull/12: $(sink)"
  sink | grep -q 'AGENT_CALL_TICKET=<unset> ' && ok \
    || bad "T9b(i) review-prs declares the PR only, never a ticket: $(sink)"
  # TEST-CHANGE (BH-3940): review-prs buys under the shared per-head key now.
  sink | grep -q 'AGENT_CALL_FP=review:acme/widgets#12@head12aaaaaa$' && ok \
    || bad "T9b(i) the K3 fingerprint must be the per-head key: $(sink)"
  # (ii) no repo slug: the lane stops before any call, and no URL is ever built
  # from the project name.
  rp_harness; rp_run -
  [ "$(sink | wc -l)" -eq 0 ] && ok || bad "T9b(ii) a project with no repo slug must not buy a review: $(sink)"
  grep -rq 'github.com/proj' "$SINK" "$R/logs" "$T/rp.out" 2>/dev/null \
    && bad "T9b(ii) a PR URL was built from the project name: $(grep -rh 'github.com/proj' "$SINK" "$R/logs" "$T/rp.out")" || ok
  grep -q "no repo slug for 'proj'" "$R/logs/ALERTS.log" 2>/dev/null && ok \
    || bad "T9b(ii) the missing slug must be the reason the lane stopped: $(cat "$R/logs/ALERTS.log" 2>/dev/null)"
}

# ---------- T9c: the conductor's re-review declares its PR ------------------
t9c() {
  local H="$T/mc" FB="$T/mc-fakebin"
  export HARNESS="$H"
  mkdir -p "$H/bin/lib/mc" "$H/logs" "$H/state" "$H/env" "$FB"
  . "$DIR/tests/lib/verdict-fixture.sh" || exit 1
  vpf_export || exit 1
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
     "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-pr-list.sh" \
     "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
  cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
  cp "$DIR/tests/lib/rest-emit.sh" "$FB/restpr"; chmod +x "$FB/restpr"
  . "$DIR/tests/lib/model-route-stub.sh" || exit 1
  mrs_fixture "$H" proj
  { echo '#!/bin/bash'; echo "$SINK_LINE"
    echo "printf 'VERDICT: APPROVE\n' > \"\$5\""
    echo "printf 'claude\n' > \"\$5.runner\""; } > "$H/bin/agent-call.sh"
  cat > "$FB/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/acme/widgets/pulls/34"*)
    restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
  chmod +x "$H/bin/agent-call.sh" "$FB/gh"
  : > "$SINK"
  local V
  V=$(PATH="$FB:$PATH" bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    . "$HARNESS/bin/lib/merge-conductor-lib.sh"
    mc_rereview acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha newsha "" "$0.out"' "$T/rr" 2>/dev/null)
  [ "$V" = APPROVE ] && ok || bad "T9c mc_rereview must still answer APPROVE (got '$V')"
  [ "$(sink | wc -l)" -eq 1 ] && ok || bad "T9c expected one re-review call: $(sink)"
  sink | grep -q '^stage=review AGENT_CALL_TICKET=<unset> AGENT_CALL_PR=https://github.com/acme/widgets/pull/34 ' && ok \
    || bad "T9c the re-review must declare AGENT_CALL_PR=https://github.com/acme/widgets/pull/34 and no ticket: $(sink)"
  # TEST-CHANGE (BH-3940): the conductor's re-review shares the per-head key now.
  sink | grep -q 'AGENT_CALL_FP=review:acme/widgets#34@newsha$' && ok \
    || bad "T9c the K3 fingerprint must be the per-head key: $(sink)"
}

# ---------- T9d: lead-review declares its PR on both calls ------------------
t9d() {
  local H="$T/lr" FB="$T/lr-fakebin" L="$T/lr-log"
  mkdir -p "$H/bin/lib/jobs" "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$FB" "$L" "$T/lr-repos" "$T/lr-tmp"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/lead-review.sh" "$H/bin/"
  # TEST-CHANGE (BH-6293): bin/lead-review.sh loads its modules from bin/lib/lead-review/.
  scratch_install_closure bin/lib/lead-review/load.sh "$H" >/dev/null || { bad "t9d: closure install of bin/lib/lead-review failed"; return; }
  cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
  local f
  for f in env-path lead-reviews verdicts model-route verdict-parse gh-rest hub-box lane-gate review-pool lead-worklist; do
    cp "$DIR/bin/lib/$f.sh" "$H/bin/lib/"
  done
  cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
  cp "$DIR/prompts/lead-review.md" "$H/prompts/"
  cp "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
  echo box-demo > "$H/state/box-name"
  printf '# project repo prod board offset box\ndemo-os example-org/demo-os https://demo.test /api/board 1 box-demo\n' > "$H/fleet.conf"
  # origin with main + the PR head at refs/pull/41/head
  local o="$T/lr-origin.git" w="$T/lr-work" sha
  git init -q --bare -b main "$o"; git init -q -b main "$w"
  printf '# demo\n\n## Verification Contract\n\n```bash\nexit 0\n```\n' > "$w/CLAUDE.md"; echo one > "$w/a.txt"
  git -C "$w" add -A; git -C "$w" -c user.email=t@t -c user.name=t commit -qm base
  git -C "$w" push -q "$o" main
  echo two >> "$w/a.txt"; git -C "$w" -c user.email=t@t -c user.name=t commit -qam "pr change"
  git -C "$w" push -q "$o" "HEAD:refs/pull/41/head"
  git clone -q "$o" "$T/lr-repos/demo-os"
  sha=$(git -C "$w" rev-parse HEAD)
  jq -nc --arg s "$sha" '{requests:[{id:"lr-1",repo:"example-org/demo-os",pr:41,head_sha:$s,scope_notes:"only the lane",prior_verdict_ref:"verdict-9",status:"requested"}],truncated:false}' > "$T/lr-requests.json"
  # The stub worker: the request list, a job that starts, a claim that holds,
  # a result that lands, and a model route.
  cat > "$FB/curl" <<EOF
#!/bin/bash
m=GET; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/lead-reviews"*) out=\$(cat "$T/lr-requests.json") ;;
  "POST /api/jobs") out='{"job":{"id":"job-7"}}' ;;
  "GET /api/model-routes/"*) out='{"ladder":[{"position":0,"model":"stub-model","runner":"claude"}],"source":"hub"}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
EOF
  cat > "$FB/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"-i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/2 200\r\n\r\n'
    jq -nc --arg s "$sha" '{head:{sha:\$s},base:{ref:"main"},title:"Add the thing",body:"PR body text"}' ;;
esac
exit 0
EOF
  # No verdict in the answer, so the lane makes its one format retry.
  { echo '#!/bin/bash'; echo "$SINK_LINE"; echo ': > "$5"'; echo 'exit 0'; } > "$H/bin/agent-call.sh"
  chmod +x "$FB/curl" "$FB/gh" "$H/bin/agent-call.sh"
  : > "$SINK"
  ( cd "$T" && env -u BOX_NAME -u JOBS_BOX -u LEAD_REVIEW_MAX_PER_TICK -u LEAD_REVIEW_DEADLINE_S \
      PATH="$FB:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BEAT_SECS=1 TMPDIR="$T/lr-tmp" REPOS_ROOT="$T/lr-repos" FLEET_CONF="$H/fleet.conf" \
      LANE_GATE_DISABLE=1 GH_ETAG=0 bash "$H/bin/lead-review.sh" tick ) > "$T/lr.out" 2>&1
  [ "$(sink | wc -l)" -eq 2 ] && ok || bad "T9d expected the call and its format retry (2 calls): $(sink) / $(tail -5 "$T/lr.out")"
  [ "$(sink | grep -c '^stage=lead-review AGENT_CALL_TICKET=<unset> AGENT_CALL_PR=https://github.com/example-org/demo-os/pull/41 ')" -eq 2 ] && ok \
    || bad "T9d both lead-review calls must declare AGENT_CALL_PR=https://github.com/example-org/demo-os/pull/41 and no ticket: $(sink)"
}

( t9a ); ( t9b ); ( t9c ); ( t9d )

PASS=$(grep -c '^PASS$' "$RES"); FAIL=$(grep -c '^FAIL' "$RES")
echo "lane-identity.bh-2537: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
