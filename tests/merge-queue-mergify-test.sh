#!/bin/bash
# tests/merge-queue-mergify-test.sh — MERGIFY as the fleet's merge-queue provider.
#
# WHY A SECOND PROVIDER. GitHub's native merge queue needs a `merge_queue`
# ruleset rule, and the rulesets API rejects one on a PRIVATE repo for a
# GitHub **Team** org (422 Invalid rule 'merge_queue'); GitHub limits private-repo
# merge queues to Enterprise Cloud. example-org is Team, so every native-queue path
# shipped in #272 is inert across the whole fleet. Mergify is a GitHub App that
# gives the same guarantee (a batch is built on top of main and only merged when
# that tree is green) on the plan we have.
#
# WHAT DIFFERS, AND SO WHAT THIS PINS. Under the native queue the conductor's
# merge CALL is the enqueue (`gh pr merge` enqueues and exits 0). Under Mergify
# there is no such call: entry is a LABEL (`merge-queue`), the witness is a
# Mergify CHECK RUN on the head, and — the dangerous part — `gh pr merge` on a
# Mergify repo still MERGES OUTRIGHT, bypassing the queue entirely. So:
#   * provider detection must tell github / mergify / none apart, fail-closed;
#   * a READY PR on a mergify repo is LABELLED, never `gh pr merge`d;
#   * the QUEUED -> MERGED settle still runs exactly once, with the real sha;
#   * a failed Mergify check is an EJECTION (WAIT_CI + our label removed);
#   * every other merger in the fleet must STAND DOWN on a mergify repo rather
#     than merge around the queue.
# A grep cannot see which tick does what, so this test drives the scripts.
# Run from anywhere: tests/merge-queue-mergify-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
# The decision reads go through bin/lib/gh-rest.sh since BH-784, so the fixture
# tree carries it exactly as a box does. Without it merge-sweep.sh's fail-closed
# shims answer "unverifiable" to every read and this suite would be green on a
# sweep that never reads anything.
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/h/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
H1=aaaaaaaa1111; H2=bbbbbbbb2222; MSHA=cccccccc3333
printf 'mgfy example-org/mgfy-os - - 2 box-m\n' > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/deployreq.txt"\nexit 0\n' "$T" > "$T/h/bin/deploy-request.sh"; chmod +x "$T/h/bin/deploy-request.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/prearm-calls.txt"\nexit 0\n' "$T" > "$T/h/bin/pre-arm-guards.sh"; chmod +x "$T/h/bin/pre-arm-guards.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/codegraph-ensure.sh"; chmod +x "$T/h/bin/codegraph-ensure.sh"

# The build record: PR 31 on the mergify repo, APPROVE bound to H1, issue-driven
# (fleet.conf board prefix "-"), so a landing owes an issue close and a deploy.
REC="$T/h/builds/pool-mgfy-MG-31-202609120001"
mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/mgfy-os/pull/31" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
echo "$H1" > "$REC/reviewed-sha"
: > "$REC/pipeline.log"

# .mergify.yml, base64 as the contents API returns it.
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# A config with no queue_rules: at all — a repo that uses Mergify for something
# else is NOT a merge-queue repo.
NOQ_YML=$(printf 'pull_request_rules:\n  - name: hi\n' | base64 | tr -d '\n')

open_list() { # open_list <labels-csv> | none
  if [ "$1" = none ]; then echo "[]" > "$T/list.json"; return; fi
  local lbl="[]"
  [ -n "$1" ] && lbl=$(printf '%s' "$1" | jq -R 'split(",")|map({name:.})' -c)
  cat > "$T/list.json" <<J
[{"number":31,"url":"https://github.com/example-org/mgfy-os/pull/31","headRefOid":"$H1","headRefName":"ticket/mg-31","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":$lbl}]
J
}
open_list ""
echo open > "$T/prstate"     # open | merged | closed
echo none > "$T/checkmode"   # none | running | failed
: > "$T/labels"              # the labels Mergify/we see on PR 31

labels_csv() { tr '\n' ',' < "$T/labels" | sed 's/,$//'; }

# THE DECISION READS ARE REST NOW (BH-784). `gh api -i -X GET repos/…/pulls/<n>`
# prints response HEADERS then the body, and bin/lib/gh-rest.sh judges the HTTP
# STATUS LINE — so a stub arm has to emit a whole HTTP response, not a bare JSON
# line. tests/lib/rest-emit.sh is the shared emitter. The LABEL is now read off
# that one pull object (mc_queue_state's single read), which is what makes the
# $T/labels fixture below the queue witness.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
PRSTATE=\$(cat "$T/prstate" 2>/dev/null || echo open)
CHECK=\$(cat "$T/checkmode" 2>/dev/null || echo none)
LBL=\$(tr '\n' ',' < "$T/labels" 2>/dev/null | sed 's/,\$//')
issue_num() { printf '%s' "\$1" | sed -n 's|.*/issues/\([0-9][0-9]*\).*|\1|p'; }
case "\$*" in
  # --- the budget read: a 0-byte answer here leaves gh-budget.sh an empty cache
  #     file and the NEXT tick in this scratch tree dies silently.
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # --- provider probes ----------------------------------------------------
  # mgfy-os: no ruleset merge_queue rule, but a .mergify.yml WITH queue_rules.
  # BH-1586: the probes are gh_rest reads (\`api -i -X GET …\`) and answer the
  # REAL REST shapes: a rulesets list, a ruleset object, a contents object with
  # base64 \`content\`, and a 404 where the thing does not exist.
  *"api -i -X GET repos/example-org/mgfy-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/mgfy-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  # queued-os: the NATIVE queue (a merge_queue ruleset rule) — provider github.
  *"api -i -X GET repos/example-org/queued-os/rulesets/9"*)
    restpr --raw 200 '{"id":9,"enforcement":"active","conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"]}},"rules":[{"type":"merge_queue"}]}' ;;
  *"api -i -X GET repos/example-org/queued-os/rulesets"*) restpr --raw 200 '[{"id":9,"enforcement":"active"}]' ;;
  *"api -i -X GET repos/example-org/queued-os/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  # plain-os: neither. nomq-os: a .mergify.yml with no queue_rules.
  *"api -i -X GET repos/example-org/plain-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/plain-os/contents/.mergify.yml"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"api -i -X GET repos/example-org/nomq-os/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/example-org/nomq-os/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$NOQ_YML"}' ;;
  # broken-os: every API call errors — must fail CLOSED to "none".
  *"api -i -X GET repos/example-org/broken-os/rulesets"*) restpr --raw 502 '{"message":"could not resolve"}' ;;
  *"api -i -X GET repos/example-org/broken-os/contents/.mergify.yml"*) restpr --raw 500 '{"message":"Server Error"}' ;;
  # --- the Mergify check run on the head ----------------------------------
  # REST, and on the contract (BH-784): the check-runs read is a DECISION read —
  # "no check on this head" is what mc_queue_state turns into an ejection — so a
  # status line is the answer and an unanswered read is not an empty list. The
  # \$CHECK cases carry exactly the facts the old \`-q\` arm carried.
  *"api -i -X GET repos/"*"/commits/$H1/check-runs"*)
    case "\$CHECK" in
      running) restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"in_progress","conclusion":null,"output":{"title":""}}]}' ;;
      failed)  restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"failure","output":{"title":""}}]}' ;;
      ready)   restpr --raw 200 '{"check_runs":[{"name":"Mergify Merge Queue","status":"completed","conclusion":"neutral","output":{"title":"Merge queue is ready"}}]}' ;;
      *)       restpr --raw 200 '{"check_runs":[]}' ;;
    esac ;;
  # --- writes --------------------------------------------------------------
  *"api -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/queue-cmds.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/labels"*)
    [ -n "\${LABEL_ADD_FAILS:-}" ] && { echo "GraphQL: Projects (classic) is being deprecated" >&2; exit 1; }
    printf '%s\n' "\$*" >> "$T/label-adds.txt"
    printf 'merge-queue\n' >> "$T/labels"; sort -u -o "$T/labels" "$T/labels" ;;
  *"api -X DELETE repos/"*"/issues/"*"/labels/merge-queue"*)
    printf '%s\n' "\$*" >> "$T/label-removes.txt"
    grep -vxF 'merge-queue' "$T/labels" > "$T/labels.tmp" 2>/dev/null; mv -f "$T/labels.tmp" "$T/labels" ;;
  # A merge really merges: mc_merge VERIFIES through gh rather than trusting the
  # exit code, so the stub has to move the PR's state the way GitHub would.
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merge-calls.txt"; echo merged > "$T/prstate"; exit 0 ;;
  # The issue close-out is REST now: a comment POST, then a PATCH to state=closed
  # that gh_rest_close only believes after a FRESH read says closed — so the
  # PATCH has to actually move the issue in this stub's world. These are the
  # "gh api -i" calls; Mergify's own label add and @mergifyio comment above are
  # plain "gh api" and stay exactly where they are.
  *"api -i -X POST repos/"*"/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X PATCH repos/"*"/issues/"*)
    printf '%s\n' "\$*" >> "$T/issue-calls.txt"
    issue_num "\$*" >> "$T/closed-issues"
    restpr --raw 200 '{"state":"closed"}' ;;
  # --- reads ---------------------------------------------------------------
  *"api -i -X GET repos/"*"/issues/"*)
    if grep -qxF "\$(issue_num "\$*")" "$T/closed-issues" 2>/dev/null
    then restpr --raw 200 '{"state":"closed"}'
    else restpr --raw 200 '{"state":"open"}'; fi ;;
  # The DIFF media type shares the /pulls/<n> path, so it is matched first.
  *"api -i -X GET repos/example-org/mgfy-os/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  # ONE read answers state, head, branch, labels and the merge sha — the labels
  # carry the queue witness mc_queue_state and mc_mergify_witness now read, and
  # OUR label is still never a witness on its own (that is the lib's job, not
  # the stub's).
  *"api -i -X GET repos/example-org/mgfy-os/pulls/31"*)
    case "\$PRSTATE" in
      merged) restpr MERGED "$H1" ticket/mg-31 main "\$LBL" MERGEABLE CLEAN operator "$MSHA" ;;
      closed) restpr CLOSED "$H1" ticket/mg-31 main "\$LBL" MERGEABLE CLEAN operator ;;
      *)      restpr OPEN   "$H1" ticket/mg-31 main "\$LBL" MERGEABLE CLEAN operator ;;
    esac ;;
  # the stacked-parent probe: no parent PR on any branch here
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/example-org/mgfy-os -q .id"*) echo 1 ;;
  *"pr list -R example-org/mgfy-os --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

ROWS="$T/h/state/merge-conductor/pr-state.tsv"
state_of()  { awk -F'\t' -v k="$1" '$1==k {print $2}' "$ROWS" 2>/dev/null; }
reason_of() { awk -F'\t' -v k="$1" '$1==k {print $7}' "$ROWS" 2>/dev/null; }
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
  MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }

touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt label-removes.txt prearm-calls.txt; do : > "$T/$f"; done

# ============================================================================
# 1. Provider detection — github / mergify / none, fail-closed
# ============================================================================
# shellcheck source=/dev/null
export PATH="$T/fakebin:$PATH"; . "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
MC_QUEUE_TTL=0
[ "$(mc_queue_provider example-org/mgfy-os)"   = mergify ] && ok || bad "a repo with a .mergify.yml carrying queue_rules: must be provider 'mergify' (got '$(mc_queue_provider example-org/mgfy-os)')"
[ "$(mc_queue_provider example-org/queued-os)" = github ]  && ok || bad "a repo with a merge_queue ruleset rule must stay provider 'github' (got '$(mc_queue_provider example-org/queued-os)')"
[ "$(mc_queue_provider example-org/plain-os)"  = none ]    && ok || bad "a repo with neither must be provider 'none' (got '$(mc_queue_provider example-org/plain-os)')"
[ "$(mc_queue_provider example-org/nomq-os)"   = none ]    && ok || bad "a .mergify.yml WITHOUT queue_rules: is not a merge queue (got '$(mc_queue_provider example-org/nomq-os)')"
[ "$(mc_queue_provider example-org/broken-os)" = none ]    && ok || bad "an API error must FAIL CLOSED to provider 'none' (got '$(mc_queue_provider example-org/broken-os)')"
# mc_queue_enabled is the fleet-wide switch every #272 stand-down reads: it must
# be true for EITHER provider, so a Mergify repo gets all of them for free.
mc_queue_enabled example-org/mgfy-os   && ok || bad "mc_queue_enabled must be true for a mergify repo (every #272 stand-down keys on it)"
mc_queue_enabled example-org/queued-os && ok || bad "mc_queue_enabled must stay true for a native-queue repo"
mc_queue_enabled example-org/plain-os  && bad "mc_queue_enabled must be false for a repo with no queue at all" || ok
# Only MERGIFY makes a direct `gh pr merge` a queue BYPASS (under the native
# queue that same call is the enqueue), so the stand-down helper is provider-
# specific and must not fire on a github-queue repo.
mc_queue_conductor_only example-org/mgfy-os   && ok || bad "mc_queue_conductor_only must be true on a mergify repo — gh pr merge there BYPASSES the queue"
mc_queue_conductor_only example-org/queued-os && bad "mc_queue_conductor_only must be FALSE on a native-queue repo — there gh pr merge IS the enqueue" || ok
mc_queue_conductor_only example-org/plain-os  && bad "mc_queue_conductor_only must be false with no queue" || ok
# The probe is cached per slug per tick, like the ruleset probe it replaces.
MC_QUEUE_TTL=300; : > "$T/gh-calls.txt"
mc_queue_provider example-org/mgfy-os >/dev/null
grep -qE 'rulesets|contents/.mergify.yml' "$T/gh-calls.txt" && bad "a cached provider probe must not re-hit the API within the tick" || ok
MC_QUEUE_TTL=0

# mc_queue_state, read directly.
: > "$T/labels"; echo none > "$T/checkmode"; echo open > "$T/prstate"
printf 'merge-queue\n' > "$T/labels"; echo running > "$T/checkmode"
[ "$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")" = queued ] && ok || bad "label present + a live Mergify check = queued (got '$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")')"
echo failed > "$T/checkmode"
[ "$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")" = ejected ] && ok || bad "a FAILED Mergify check = ejected (got '$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")')"
echo none > "$T/checkmode"; : > "$T/labels"
[ "$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")" = ejected ] && ok || bad "no label and no check = ejected (got '$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")')"
# THE IDLE CHECK IS NOT A WITNESS (project-5 #547, 2026-09-13). Mergify posts a
# neutral "Mergify Merge Queue — Merge queue is ready" check on every PR it has
# evaluated, queued or not: #546 carried it with no label ever. A witness that
# accepts any check named Mergify* reports QUEUED the moment our label goes on,
# and the rc-3 fallback can never fire.
echo ready > "$T/checkmode"; : > "$T/labels"
[ "$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")" = ejected ] && ok || bad "no label + Mergify's idle 'ready' check = NOT queued (got '$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")')"
mc_mergify_witness example-org/mgfy-os https://github.com/example-org/mgfy-os/pull/31 "$H1" && bad "the idle 'Merge queue is ready' check must not witness an enqueue" || ok
printf 'merge-queue\n' > "$T/labels"
mc_mergify_inqueue example-org/mgfy-os 'example-org/mgfy-os#31' https://github.com/example-org/mgfy-os/pull/31 "$H1" "merge-queue" "" && bad "our label + the idle check must not read as in-queue" || ok
printf 'merge-queue\nqueued\n' > "$T/labels"
mc_mergify_inqueue example-org/mgfy-os 'example-org/mgfy-os#31' https://github.com/example-org/mgfy-os/pull/31 "$H1" "merge-queue,queued" "" && ok || bad "Mergify's own queued label is the witness even beside the idle check"
echo none > "$T/checkmode"; : > "$T/labels"
echo merged > "$T/prstate"
[ "$(mc_queue_state https://github.com/example-org/mgfy-os/pull/31 "$H1")" = merged ] && ok || bad "a MERGED PR is merged whatever the labels say"
echo open > "$T/prstate"

# ============================================================================
# 2. Tick one on a mergify repo: LABEL, never `gh pr merge`
# ============================================================================
rm -rf "$T/h/state/merge-conductor"; : > "$T/labels"; echo none > "$T/checkmode"
for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt label-removes.txt prearm-calls.txt; do : > "$T/$f"; done
: > "$T/beats.txt"
open_list ""
echo running > "$T/checkmode"   # Mergify answers the label within the tick
run_tick
grep -q -- 'labels\[\]=merge-queue' "$T/label-adds.txt" && ok || bad "a READY PR on a mergify repo must be enqueued by ADDING the merge-queue label (got: $(cat "$T/label-adds.txt"))"
grep -q -- '@mergifyio queue' "$T/queue-cmds.txt" 2>/dev/null && ok || bad "the conductor must also post the @mergifyio queue command — the label alone did not queue project-5 #516 (got: $(cat "$T/queue-cmds.txt" 2>/dev/null))"
[ -s "$T/merge-calls.txt" ] && bad "the conductor must NEVER run gh pr merge on a mergify repo — that bypasses the queue (got: $(cat "$T/merge-calls.txt"))" || ok
[ "$(state_of 'example-org/mgfy-os#31')" = QUEUED ] && ok || bad "after the label the row must be QUEUED (got '$(state_of 'example-org/mgfy-os#31')')"
[ -s "$T/prearm-calls.txt" ] && bad "pre-arm-guards.sh must be skipped on a queue repo of either provider" || ok
grep -qxF 'https://github.com/example-org/mgfy-os/pull/31' "$T/h/state/merge-sweep-done.txt" 2>/dev/null \
  && bad "a LABELLED PR must not be written to merge-sweep-done.txt — it has not merged" || ok
[ -s "$T/issue-calls.txt" ] && bad "a queued PR must not close its issue: $(cat "$T/issue-calls.txt")" || ok
[ -s "$T/deployreq.txt" ] && bad "a queued PR must not request a deploy: $(cat "$T/deployreq.txt")" || ok

# A second tick while Mergify still holds it: still QUEUED, no second label add.
: > "$T/label-adds.txt"; open_list "merge-queue"
run_tick
[ "$(state_of 'example-org/mgfy-os#31')" = QUEUED ] && ok || bad "a PR still in the Mergify queue stays QUEUED (got '$(state_of 'example-org/mgfy-os#31')')"
[ -s "$T/label-adds.txt" ] && bad "a PR already carrying the label must not be re-enqueued: $(cat "$T/label-adds.txt")" || ok

# 2b. Mergify answers the label with ONLY its idle check: that is no answer.
# The tick must take the rc-3 path (a HOLD + the alert since BH-2199; it was a
# degraded direct merge before), and the row must never be written QUEUED on
# the strength of the idle check.
rm -rf "$T/h/state/merge-conductor"; : > "$T/labels"; echo ready > "$T/checkmode"; echo open > "$T/prstate"
for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt label-removes.txt prearm-calls.txt queue-cmds.txt; do : > "$T/$f"; done
: > "$T/h/logs/ALERTS.log"
open_list ""
run_tick
grep -q -- 'labels\[\]=merge-queue' "$T/label-adds.txt" && ok || bad "2b: the label still goes on first (got: $(cat "$T/label-adds.txt"))"
grep -q -- '@mergifyio queue' "$T/queue-cmds.txt" && ok || bad "2b: the command is still posted"
# TEST-CHANGE (BH-2199): the conductor no longer merges around a queue_rules
# repo's queue. These two lines asserted the degraded direct merge (MERGED, and
# a "merged directly (degraded)" alert); the ticket reverses exactly that, so
# they now assert the hold. Nothing else in 2b changed.
[ "$(state_of 'example-org/mgfy-os#31')" = READY ] && ok || bad "2b: with only the idle check the conductor must HOLD the PR READY, never merge around the queue (got '$(state_of 'example-org/mgfy-os#31')')"
[ ! -s "$T/merge-calls.txt" ] && ok || bad "2b: no direct merge on a queue_rules repo (got: $(cat "$T/merge-calls.txt"))"
grep -q 'READY PRs are held, NOT merged' "$T/h/logs/ALERTS.log" && ok || bad "2b: the queue-silent alert must fire when Mergify answers only 'ready' (ALERTS: $(cat "$T/h/logs/ALERTS.log"))"

# ============================================================================
# 3. Mergify merges it: settle exactly once, with the REAL merge sha
# ============================================================================
# TEST-CHANGE (BH-2199): this section's settle used to be satisfied by 2b's
# in-tick DIRECT merge (2b left the row MERGED and wrote the done-file, the
# issue close and the deploy request this section counts). 2b now HOLDS, so the
# section starts from what its title says — a PR the queue holds (a QUEUED row
# carrying our label) — and counts only its own settle. The assertions are
# unchanged.
rm -rf "$T/h/state/merge-conductor"; mkdir -p "$T/h/state/merge-conductor"
: > "$T/h/state/merge-conductor/attempts.txt"
: > "$T/issue-calls.txt"; : > "$T/deployreq.txt"; : > "$T/beats.txt"; : > "$T/h/state/merge-sweep-done.txt"
printf 'merge-queue\n' > "$T/labels"
printf 'example-org/mgfy-os#31\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/mgfy-os/pull/31\n' \
  "$(date -u +%s)" "$H1" "$H1" "${H1:0:8}" > "$ROWS"
echo merged > "$T/prstate"; open_list none
run_tick
[ "$(state_of 'example-org/mgfy-os#31')" = MERGED ] && ok || bad "a PR Mergify merged must settle to MERGED (got '$(state_of 'example-org/mgfy-os#31')')"
grep -qxF 'https://github.com/example-org/mgfy-os/pull/31' "$T/h/state/merge-sweep-done.txt" && ok || bad "the settle must ledger the merge where the sweep looks (merge-sweep-done.txt)"
# The close is `gh api -i -X PATCH repos/<slug>/issues/<n> -f state=closed` since
# BH-784 — same claim, new verb.
[ "$(grep -c 'PATCH repos/example-org/mgfy-os/issues/31 ' "$T/issue-calls.txt")" = 1 ] && ok || bad "the settle must close the issue exactly once (got $(cat "$T/issue-calls.txt"))"
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "the settle must request exactly one deploy (got $(cat "$T/deployreq.txt"))"
grep -q "$MSHA" "$T/deployreq.txt" && ok || bad "the deploy request must carry the REAL merge sha (got $(cat "$T/deployreq.txt"))"
grep -q 'conductor_merged' "$T/beats.txt" && ok || bad "the settle must beat the merge"
run_tick
[ "$(wc -l < "$T/deployreq.txt" | tr -d ' ')" = 1 ] && ok || bad "a later tick must not enqueue a second deploy (got $(cat "$T/deployreq.txt"))"

# ============================================================================
# 4. A failed Mergify batch = EJECTION: WAIT_CI, and OUR label is removed
# ============================================================================
rm -rf "$T/h/state/merge-conductor"; mkdir -p "$T/h/state/merge-conductor"
: > "$T/h/state/merge-conductor/attempts.txt"
: > "$T/label-removes.txt"; : > "$T/label-adds.txt"
echo open > "$T/prstate"; echo failed > "$T/checkmode"
printf 'merge-queue\n' > "$T/labels"
printf 'example-org/mgfy-os#31\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/mgfy-os/pull/31\n' \
  "$(date -u +%s)" "$H1" "$H1" "${H1:0:8}" > "$ROWS"
open_list "merge-queue"
run_tick
[ "$(state_of 'example-org/mgfy-os#31')" = WAIT_CI ] && ok || bad "a Mergify check FAILURE must eject to WAIT_CI, not BLOCKED_HUMAN (got '$(state_of 'example-org/mgfy-os#31')')"
grep -q 'queue-ejected' <<<"$(reason_of 'example-org/mgfy-os#31')" && ok || bad "the ejection reason must say queue-ejected (got '$(reason_of 'example-org/mgfy-os#31')')"
grep -q -- 'labels/merge-queue' "$T/label-removes.txt" && ok || bad "an ejected PR must have OUR label removed so the next enqueue is a fresh signal (got: $(cat "$T/label-removes.txt"))"
[ -s "$T/label-adds.txt" ] && bad "an ejected head must NOT be re-labelled in the same tick — that is the forever-loop shape: $(cat "$T/label-adds.txt")" || ok

# A second ejection on this PR is a human's problem.
printf 'ejected example-org/mgfy-os#31 %s\n' "$H2" >> "$T/h/state/merge-conductor/attempts.txt"
printf 'merge-queue\n' > "$T/labels"
printf 'example-org/mgfy-os#31\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/mgfy-os/pull/31\n' \
  "$(date -u +%s)" "$H1" "$H1" "${H1:0:8}" > "$ROWS"
run_tick
[ "$(state_of 'example-org/mgfy-os#31')" = BLOCKED_HUMAN ] && ok || bad "a second ejection must be BLOCKED_HUMAN (got '$(state_of 'example-org/mgfy-os#31')')"
grep -q 'queue-ejected-twice' <<<"$(reason_of 'example-org/mgfy-os#31')" && ok || bad "the second ejection's reason must be queue-ejected-twice (got '$(reason_of 'example-org/mgfy-os#31')')"

# ============================================================================
# 5. THE QUEUE IS NOT ANSWERING: HOLD, never merge around it (BH-2199)
# ============================================================================
# THE LIVE EVIDENCE (project-5 #510, 2026-09-12): Mergify answered
# `@mergifyio queue` with "The product Merge Queue needs to be activated". The
# app was installed, the config was right, the label was right — the QUEUE
# PRODUCT was off. That is a standing condition on the REPO that somebody fixes
# in a dashboard, and nothing about the PR.
#
# Parking on the two-strike mergefail path is still wrong: it puts EVERY ready
# PR on the repo in BLOCKED_HUMAN for one toggle, to be cleared by hand one at a
# time. Until BH-2199 the answer was a DIRECT merge around the queue; #2196
# landed that way over a lead CHANGES_REQUESTED while Mergify was merely slow.
# TEST-CHANGE (BH-2199): the section now pins the HOLD the ticket asks for — the
# row stays READY with our label on, nothing merges, no strike, one alert — in
# place of the direct-merge assertions it carried (head-pinned merge, MERGED,
# label removed, landing ledgered, issue closed, deploy requested).
rm -rf "$T/h/state/merge-conductor"; : > "$T/labels"
for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt label-removes.txt queue-cmds.txt; do : > "$T/$f"; done
: > "$T/h/logs/ALERTS.log"; : > "$T/h/state/merge-sweep-done.txt"; : > "$T/beats.txt"
echo open > "$T/prstate"
echo none > "$T/checkmode"    # Mergify acknowledges NOTHING — the product is off
open_list ""
run_tick
grep -q -- 'labels\[\]=merge-queue' "$T/label-adds.txt" && ok || bad "the queue must still be ASKED first — the label goes on before any fallback (got: $(cat "$T/label-adds.txt"))"
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "a queue that answers nothing must NEVER be bypassed by a direct merge on a queue_rules repo (got: $(cat "$T/merge-calls.txt"))"
[ "$(state_of 'example-org/mgfy-os#31')" = READY ] && ok || bad "the unanswered PR must be HELD READY (got '$(state_of 'example-org/mgfy-os#31')')"
[ -s "$T/label-removes.txt" ] && bad "a held PR keeps our label on, so the queue can still pick it up (removed: $(cat "$T/label-removes.txt"))" || ok
grep -q 'mergify queue not answering for example-org/mgfy-os — READY PRs are held, NOT merged' "$T/h/logs/ALERTS.log" && ok \
  || bad "the hold must raise the named alert line (ALERTS: $(cat "$T/h/logs/ALERTS.log"))"
grep -q 'example-org/mgfy-os#31 MERGE_HELD' "$T/h/logs/merge-conductor.log" && ok || bad "the conductor log must say MERGE_HELD for the held PR"
# Nothing a landing owes happens, because nothing landed.
grep -qxF 'https://github.com/example-org/mgfy-os/pull/31' "$T/h/state/merge-sweep-done.txt" && bad "a held PR must not be ledgered as landed" || ok
grep -q 'PATCH repos/example-org/mgfy-os/issues/31 ' "$T/issue-calls.txt" && bad "a held PR must not close its issue: $(cat "$T/issue-calls.txt")" || ok
[ -s "$T/deployreq.txt" ] && bad "a held PR must not request a deploy: $(cat "$T/deployreq.txt")" || ok
grep -q 'mergefail' "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && bad "a queue that never answered must NOT record a merge-failure strike: $(cat "$T/h/state/merge-conductor/attempts.txt")" || ok
[ "$(state_of 'example-org/mgfy-os#31')" = BLOCKED_HUMAN ] && bad "an unanswering queue must never park a PR BLOCKED_HUMAN — that is hand-clearing work for a dashboard toggle" || ok

# 5c. THE LABEL WRITE ITSELF FAILS (2026-09-13: `gh pr edit --add-label` died on every
#     example-org PR with a GraphQL "Projects (classic)" error and four READY PRs were
#     parked). A queue the conductor cannot even ask is the same condition as one that
#     never answers: held (BH-2199; a degraded direct merge before), one alert, never a
#     strike, never BLOCKED_HUMAN.
rm -rf "$T/h/state/merge-conductor"; : > "$T/labels"
for f in gh-calls.txt merge-calls.txt issue-calls.txt deployreq.txt label-adds.txt label-removes.txt queue-cmds.txt; do : > "$T/$f"; done
: > "$T/h/logs/ALERTS.log"; : > "$T/h/state/merge-sweep-done.txt"; : > "$T/beats.txt"
echo open > "$T/prstate"; echo none > "$T/checkmode"
open_list ""
LABEL_ADD_FAILS=1 run_tick
[ ! -s "$T/label-adds.txt" ] && ok || bad "the stub must have refused the label write (got: $(cat "$T/label-adds.txt"))"
# TEST-CHANGE (BH-2199): these two asserted the direct-merge fallback; they now
# assert the hold.
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "a label write that fails must NOT fall back to a direct merge (got: $(cat "$T/merge-calls.txt"))"
[ "$(state_of 'example-org/mgfy-os#31')" = READY ] && ok || bad "a failed label write must be held READY, not '$(state_of 'example-org/mgfy-os#31')'"
grep -q 'mergefail' "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null \
  && bad "a failed label write must NOT record a merge-failure strike" || ok
grep -q 'READY PRs are held, NOT merged' "$T/h/logs/ALERTS.log" && ok || bad "a failed label write must raise the queue-silent alert (ALERTS: $(cat "$T/h/logs/ALERTS.log"))"

# A SECOND rc-3 event the same day: it is held too, and the alert does NOT repeat.
# (The condition belongs to the repo, so one line a day is the whole signal; one
# per PR per tick is a page nobody reads.)
: > "$T/label-adds.txt"; : > "$T/merge-calls.txt"; : > "$T/label-removes.txt"
: > "$ROWS"; echo open > "$T/prstate"; : > "$T/labels"; open_list ""
run_tick
# TEST-CHANGE (BH-2199): asserted a second direct merge; now the second PR is held.
[ ! -s "$T/merge-calls.txt" ] && ok || bad "the second unanswered PR of the day must also be held, never merged directly (got: $(cat "$T/merge-calls.txt"))"
[ "$(grep -c 'mergify queue not answering' "$T/h/logs/ALERTS.log")" = 1 ] && ok \
  || bad "the queue-not-answering alert must fire ONCE per repo per day, not once per PR (got $(grep -c 'mergify queue not answering' "$T/h/logs/ALERTS.log"))"

# A row that is ALREADY QUEUED is NOT merged underneath the queue. A witnessed
# enqueue owns that PR and the queue may be about to land it; merging here is the
# double-merge this whole lane exists to prevent.
: > "$T/merge-calls.txt"; : > "$T/label-removes.txt"
echo open > "$T/prstate"; echo none > "$T/checkmode"; printf 'merge-queue\n' > "$T/labels"
printf 'example-org/mgfy-os#31\tQUEUED\t%s\t%s\t%s\t-\tenqueued at %s\thttps://github.com/example-org/mgfy-os/pull/31\n' \
  "$(date -u +%s)" "$H1" "$H1" "${H1:0:8}" > "$ROWS"
open_list "merge-queue"
run_tick
[ -s "$T/merge-calls.txt" ] && bad "a row already QUEUED must NEVER be merged directly — that is a double merge under a live queue (got: $(cat "$T/merge-calls.txt"))" || ok
[ -s "$T/label-removes.txt" ] && bad "a QUEUED row's label must not be stripped by the degraded path: $(cat "$T/label-removes.txt")" || ok

# ============================================================================
# 6. bin/merge-sweep.sh must STAND DOWN on a mergify repo
# ============================================================================
# Under the NATIVE queue the sweep's `gh pr merge` is an enqueue, so #272 kept
# it. On a MERGIFY repo the same call merges outright — around the queue, with
# none of its batch verification. The sweep must leave the PR to the conductor.
mkdir -p "$T/h/state/merge-queue"
: > "$T/merge-calls.txt"; : > "$T/issue-calls.txt"; : > "$T/h/state/merge-sweep-done.txt"
: > "$T/h/logs/merge-sweep.log"; : > "$T/h/logs/ALERTS.log"; : > "$T/prearm-calls.txt"
rm -f "$T/h/tmp"/*.probe "$T/h/tmp"/*.provider 2>/dev/null
echo open > "$T/prstate"; printf 'merge-queue\n' > "$T/labels"; echo running > "$T/checkmode"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
  bash "$T/h/bin/merge-sweep.sh" >/dev/null 2>"$T/sweep.err" ) || true
[ -s "$T/merge-calls.txt" ] && bad "the sweep must NOT run gh pr merge on a mergify repo — it would merge around the queue (got: $(cat "$T/merge-calls.txt"))" || ok
grep -qxF 'https://github.com/example-org/mgfy-os/pull/31' "$T/h/state/merge-sweep-done.txt" \
  && bad "the sweep must not record an OPEN, queued PR as merged" || ok
[ -s "$T/issue-calls.txt" ] && bad "the sweep must not close the issue of a queued PR: $(cat "$T/issue-calls.txt")" || ok
grep -qi 'mergify' "$T/h/logs/merge-sweep.log" && ok || bad "the sweep must log WHY it stood down (log: $(cat "$T/h/logs/merge-sweep.log"))"

echo "merge-queue-mergify-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
