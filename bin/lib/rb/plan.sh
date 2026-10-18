# bin/lib/rb/plan.sh — the plan stage: the lane checkpoints, context signature, codegraph and verification-map orientation, the CC runner, ticket fingerprint and meta, thread-stability gate, preplan adopt, the PLAN run, the plan gate, kind flow, the size switch with its size gate and decompose hand-off, and claims publish.
# The body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
#
# WHERE THE SLICE STARTS, AND WHY IT IS NOT THE ANCHOR #478 NAMED. The parent
# plan drew this boundary at `# >>> checkpoint adopt`. That line sits INSIDE the
# `else` arm of the driver's `if [ -n "${TARGET_BRANCH:-}" ]` — the `if`, the
# `then` arm and the `else` all belong to the preceding slice (gates.sh,
# rb_gate_claim_and_workspace), and only the closing `fi` would have landed
# here. A body that opens with somebody else's `fi` does not parse: `bash -n`
# and the ticket's own side-effect check both refuse it, and after the cut the
# pipeline would open an `if` in one function and close it in another. So the
# body starts at the first line AFTER that `fi` (`# Record the branch for
# checkpoint-resume:`), which is the nearest boundary that keeps the block
# whole. The checkpoint-adopt block (`# >>> checkpoint adopt` through its `fi`)
# therefore stays with the slice that opens its `if`; #478 and #569 are told.
# Entry functions, pipeline order: rb_plan
# Reads: _ ALERTS BASE BRANCH BUILD BUILD_CALL_FP CARRIED_NOTE_LINE CARRIED_NOTE_SRC CC_ARTIFACT_FILE
#   CC_ARTIFACT_KIND CG_ORIENT CHECKPOINT_SQUASH CHECKPOINTS CKPT_ACTIVE CKPT_PID CKPT_WIP_N
#   CTX_COMMIT CTX_FRESH CTX_SIG CTX_SYNC FP_AFTER FP_BEFORE FP_PLAN HARNESS HOTFIX JOB_ID KEY KIND
#   KIND_ENFORCE KIND_EXEC_NOTE KIND_GATE_ENFORCE KIND_HINT KIND_HINT_LINE KIND_HINT_SRC
#   KIND_MISS KIND_OUT KIND_PROBE KIND_RC KIND_REPRO KIND_SKIP_E2E KIND_SRC PG_ENFORCE PG_LIST
#   PG_MAX PG_RC PG_TASKS PG_UNTRACED PG_VERDICT PG_WHY PLAN_AMBIGUITY_RULE PLAN_GATE_ENFORCE
#   PLAN_GATE_MAX_LIST PLAN_MODEL PM_ART PM_STATUS PP_DIR PP_FP PP_OUTCOME PP_RC PP_RESUMED
#   PP_WHY PROJECT REPO SG_BODY SG_CHILD SG_CHILD_SRC SG_DECL SG_ENFORCE SG_LIMITS SG_MAXF SG_MAXL SG_OUT SG_RC
#   SG_SPLIT SG_SRC SG_SWITCH_SRC SG_TIER SG_TITLE SG_TLOG SG_UNDECL_WHY SG_VERDICT SG_WHY SQUASH_OK TH_N TH_P TH_R
#   TH_REC TH_RN TICKET VMAP_ORIENT WT
#   GH_AUTH_SLUG PC_CONF_WARN PC_ENFORCE UI_PLAN_NOTE
# Writes: AGENT_CALL_ARTIFACT_KIND BCF_OUT REOPEN_REASON_LINE RR_LINE RR_LOG REVERT_REASON_LINE RV_LINE RV_LOG BUILD_CALL_FP BUILD_NOTE_RELAY CARRIED_NOTE_LINE CARRIED_NOTE_SRC CC_ARTIFACT_KIND CG_ORIENT
#   CHECKPOINT_PARENT_PID CN_SRC CP_M CP_PARENT CP_PREAMBLE CP_RC CP_WHY CKPT_ACTIVE CKPT_PID CTX_COMMIT CTX_FRESH CTX_SIG CTX_SYNC FP_AFTER
#   FP_BEFORE FP_PLAN KIND KIND_EXEC_NOTE KIND_HINT KIND_HINT_LINE KIND_HINT_SRC KIND_MISS
#   KIND_OUT KIND_PROBE KIND_REPRO KIND_SKIP_E2E KIND_SKIP_SECLENS KIND_SRC PG_LIST PG_TASKS
#   PG_UNTRACED PG_VERDICT PG_WHY PLAN_AMBIGUITY_RULE PLAN_MODEL PM_ART PM_STATUS PP_DIR PP_EV PP_EV_DETAIL PP_EV_RC PP_FP PP_OUTCOME
#   PP_RESUMED PP_WHY PTG_DETAIL PTG_IDS PTG_OUT PTG_RC PTG_SINCE PTG_SRC REROUTE_EXEC_NOTE SG_BODY SG_CHILD SG_CHILD_SRC SG_DECL SG_ENFORCE SG_LIMITS SG_MAXF SG_MAXL
#   SG_OUT SG_RC SG_SPLIT SG_SRC SG_SWITCH_SRC SG_TIER SG_TITLE SG_TLOG SG_UNDECL_WHY SG_VERDICT SG_WHY TH_N TH_REC
#   TH_RN VMAP_ORIENT
#   PC_BASE PC_HITS PC_N PC_NH PC_RC PC_RESOLVED PC_SLUG PC_SUMMARY PC_UNRES PC_VERDICT STN_NOTE UI_PLAN_NOTE
# shellcheck shell=bash

rb_plan() {
# Record the branch for checkpoint-resume: a relaunched run re-enters it
# instead of cutting ticket/<key>-rN and abandoning the finished commits.
echo "$BRANCH" > "$BUILD/branch"
# >>> branch artifact (BH-1033)
# ...and on the JOB ROW, which is the copy a lane on another box can read. The
# file above is on this machine's disk, and bin/pr-url-reconcile.sh runs on the
# hub: with no row it SCRAPES pipeline.log for the name, silently falls back to
# the stem when the scrape misses, and can then relink a record to whatever PR
# happens to sit on ticket/<key> — someone else's. The name is settled HERE, by
# the code that chose it, before the push and before the PR.
# Fail-open and quiet: no client, no row, or an unreachable worker and the
# scrape is exactly what it was.
command -v job_artifact_put >/dev/null 2>&1 && [ -n "${JOB_ID:-}" ] \
  && job_artifact_put branch "$BRANCH" \
       "$(jq -nc --arg r "$(basename "$BUILD")" --arg b "$BRANCH" \
          '{record:$r,branch:$b,source:"run-build"}' 2>/dev/null)" >/dev/null 2>&1
# <<< branch artifact

# >>> lane checkpoints (tests/run-build-checkpoint-test.sh drives this block)
# --- NO FINISHED WORK IS EVER LOST (2026-09-15, docs/CHECKPOINTS.md) ----------
# Seventeen lanes died at max-turns in 24h with "NO PR". Today's project-5
# migrations lane had COMMITTED twelve files and died before it could push; the
# operator pushed the branch by hand as project-5 #1156. PUSH_BRANCH below makes
# origin the second copy of the tree, but it only runs AFTER the execute stage
# has returned — which is exactly what a max-turns death prevents.
#
# So the execute stage gets a heartbeat. bin/lane-checkpoint.sh commits whatever
# the worktree is carrying as `wip: checkpoint <stage> <ISO>` and pushes the
# branch: on a timer (--watch) while the session runs, and once more when the
# stage ends for ANY reason — clean return, rc != 0, timeout, max-turns, or the
# SIGTERM of a reaped machine. Each run writes one CHECKPOINT line to this
# build's pipeline.log, so the operator can see the net working.
#
# CHECKPOINT_EVERY_MIN (env/global.env, default 15) is the cadence. CHECKPOINTS=0
# or flags/lane-checkpoints-off (or the `switch.lane-checkpoints-off` settings
# row) switches the whole thing off and every line below
# becomes a no-op — the pre-2026-09-15 pipeline, byte for byte.
# shellcheck source=../lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
CKPT_ACTIVE=0; CKPT_PID=""; CKPT_RESUME_NOTE=""; CKPT_WIP_N="${CKPT_WIP_N:-0}"
# THE BUILD TRIPWIRE seam (BH-3481.0), read by CC() below. Alert only since
# BH-6705: the check never stops a build. A box without the lib has no check.
# shellcheck source=../build-tripwire.sh
command -v tw_check_build >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../build-tripwire.sh" 2>/dev/null || true
CKPT_ON() { # read at every call site, so a flag dropped mid-build still lands
  lane_switch lane-checkpoints-off file && return 1
  case "$(printf '%s' "${CHECKPOINTS:-1}" | tr '[:upper:]' '[:lower:]')" in 0|off|false|no) return 1 ;; esac
  return 0
}
CKPT_RUN() { # CKPT_RUN <stage> — one checkpoint, never fatal to this pipeline
  "$HARNESS/bin/lane-checkpoint.sh" "$BUILD" "$WT" "$BRANCH" "$1" >/dev/null 2>&1 || true
  return 0
}
# Counted off the SUBJECT line, not the diff: "is there real work here" and "is
# there a tree here" are different questions, and conflating them is how a
# checkpoint-only branch would sail into review as a finished build.
CKPT_WIP_COUNT()    { git log --format=%s "$BASE..HEAD" 2>/dev/null | grep -c  '^wip: checkpoint ' ; }
CKPT_NONWIP_COUNT() { git log --format=%s "$BASE..HEAD" 2>/dev/null | grep -vc '^wip: checkpoint ' ; }
CKPT_START() {
  CKPT_ON || return 0
  CKPT_ACTIVE=1
  CHECKPOINT_PARENT_PID=$$ "$HARNESS/bin/lane-checkpoint.sh" --watch "$BUILD" "$WT" "$BRANCH" execute >/dev/null 2>&1 &
  CKPT_PID=$!
  # A SIGTERM'd bash does NOT run its EXIT trap unless the signal is trapped, and
  # a reaped Fly machine or a watchdog kill is exactly a SIGTERM. Both handlers
  # save first and then re-raise, so the EXIT trap below still closes the job row.
  trap 'CKPT_ON_EXIT; trap - TERM; kill -TERM $$' TERM
  trap 'CKPT_ON_EXIT; trap - INT;  kill -INT  $$' INT
}
CKPT_STOP() { # the stage ended on its own terms: disarm, then save once more
  [ -n "$CKPT_PID" ] && { kill "$CKPT_PID" 2>/dev/null; wait "$CKPT_PID" 2>/dev/null; CKPT_PID=""; }
  trap - TERM; trap - INT
  [ "$CKPT_ACTIVE" = 1 ] || return 0
  CKPT_ACTIVE=0
  CKPT_RUN execute-end
}
CKPT_ON_EXIT() { # the stage's exit trap: rc != 0, timeout, max-turns, signal
  [ "${CKPT_ACTIVE:-0}" = 1 ] || return 0
  CKPT_ACTIVE=0
  [ -n "${CKPT_PID:-}" ] && kill "$CKPT_PID" 2>/dev/null
  CKPT_RUN execute-exit
}
# --- Tidy before the PR ------------------------------------------------------
# The checkpoints are a safety net, not history anybody should have to read, so
# they collapse into one commit before a reviewer or a PR ever sees them. The
# TREE is untouched by construction (a soft reset re-commits the same index), so
# every diff-shaped gate downstream sees byte-identical input. It is also the
# invariant --resume-branch leans on: wip commits at a tip mean a lane died
# before the PR step, and a finished build must therefore never leave any.
#
# THE NON-WIP MESSAGES ARE CARRIED VERBATIM, deliberately: bin/test-tamper-scan.sh
# reads TEST-CHANGE justifications out of the commit messages in range, and a
# squash that dropped them would turn a justified test edit into a blocked build.
#
# Two things it refuses to do: rewrite a branch this pipeline did not cut (a
# dispatcher-supplied TARGET_BRANCH is an existing PR's head), and rewrite a head
# the reviewer is already bound to by anything other than equality — the same
# fail-toward-being-read rule the rebase carry above follows.
CKPT_SQUASH_WIP() {
  [ "${CHECKPOINT_SQUASH:-1}" = 0 ] && return 0
  [ "${SQUASH_OK:-0}" = 1 ] || return 0
  local n_all n_wip rh head msgf mb
  # BH-1310: $BASE is the LOCAL ref for main, and a box that pulled main fresh
  # mid-build leaves it ahead of the commit this branch actually forked from.
  # Squashing onto $BASE directly re-parents the collapsed commit onto that
  # fresh tip; the tree is untouched (a soft reset never changes it), but every
  # file main gained since the real fork now reads as DELETED in the diff a
  # reviewer or gate takes against that new parent. The branch's real base is
  # merge-base($BASE, HEAD) — resolve THAT, once, and reset/count/log against
  # it instead. A base that cannot be resolved is never silently treated as the
  # tip: fail loud and leave the wip commits in place.
  mb=$(git merge-base "$BASE" HEAD 2>/dev/null)
  if [ -z "$mb" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT squash FAILED — could not resolve merge-base($BASE, HEAD), refusing to squash onto an unrelated base" >> "$BUILD/pipeline.log"
    return 1
  fi
  n_all=$(git rev-list --count "$mb..HEAD" 2>/dev/null || echo 0)
  n_wip=$(CKPT_WIP_COUNT)
  [ "$n_wip" -ge 1 ] && [ "$n_all" -ge 2 ] || return 0
  head=$(git rev-parse HEAD 2>/dev/null)
  rh=$(cat "$BUILD/review-head" 2>/dev/null || true)
  if [ -n "$rh" ] && [ "$rh" != "$head" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT squash skipped: the reviewed head ${rh:0:8} is not this head — leaving $n_wip wip commit(s) rather than orphaning an approval" >> "$BUILD/pipeline.log"
    return 0
  fi
  msgf="$BUILD/wip-squash-msg.txt"
  git log --format='%B' --reverse "$mb..HEAD" 2>/dev/null | grep -v '^wip: checkpoint ' > "$msgf"
  grep -q '[^[:space:]]' "$msgf" || printf '%s: work recovered from %s lane checkpoint(s)\n' "$KEY" "$n_wip" > "$msgf"
  if git reset --soft "$mb" >> "$BUILD/pipeline.log" 2>&1 && git commit -q --no-verify -F "$msgf" >> "$BUILD/pipeline.log" 2>&1; then
    [ -n "$rh" ] && git rev-parse HEAD > "$BUILD/review-head"
    echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT squash: $n_all commit(s) ($n_wip wip) collapsed into $(git rev-parse --short HEAD) — same tree, tidy history" >> "$BUILD/pipeline.log"
  else
    # BH-1319: rc 1, the same answer the unresolved-merge-base path above gives.
    # The two FAILED paths log the same word, and a caller that could only see
    # one of them was reading half the refusals as successes.
    echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT squash FAILED — the PR ships with its $n_wip wip commit(s), which costs nothing but a noisy log" >> "$BUILD/pipeline.log"
    return 1
  fi
  return 0
}
# CKPT_SQUASH_REFUSED <execute|pr> — the squash returned 1 (unresolved merge-base, or the
# reset/commit failed). STILL NEVER FATAL: the build goes on with its wip commits. What
# changes is that the refusal is RECORDED as the step that failed — a `squash` phase row
# closed failed rc 1 on the job (the same fail-open pattern the e2e stage uses), so a
# later SCAN_FAILED or REVIEW_BLOCKED reads back to this and not to a deleted-file mystery.
CKPT_SQUASH_REFUSED() {
  local where="${1:-execute}" why
  why=$(grep 'CHECKPOINT squash FAILED' "$BUILD/pipeline.log" 2>/dev/null | tail -1 | sed 's/^.*CHECKPOINT squash FAILED[^A-Za-z]*//')
  echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT squash refused before $where — recorded as the failed step; the build continues with its wip commits" >> "$BUILD/pipeline.log"
  command -v job_phase_open >/dev/null 2>&1 || return 0
  job_phase_open squash "$(hostname)" "" "checkpoint squash before $where" >/dev/null 2>&1 || return 0
  job_phase_close 1 "" "${why:-refused}" >/dev/null 2>&1 || true
  return 0
}
# <<< lane checkpoints

# Re-measure against the WORKTREE now that it exists — the gate above ran
# against $REPO, which cannot see a worktree-local project CLAUDE.md/AGENTS.md.
# The gate has already accepted the machine context; this only refines the
# manifest that the PR body and any later comparison will quote.
"$HARNESS/bin/context-signature.sh" "$PROJECT" "$WT" > "$BUILD/context.json" 2>/dev/null
CTX_SIG=$(python3 -c "import json;print(json.load(open('$BUILD/context.json'))['signature_short'])" 2>/dev/null || echo unknown)
CTX_COMMIT=$(python3 -c "import json;print(json.load(open('$BUILD/context.json'))['harness_commit'])" 2>/dev/null || echo unknown)
CTX_SYNC=$(python3 -c "import json;d=json.load(open('$BUILD/context.json'));print('ok' if d['machine_rules_in_sync'] and d['harness_bin_in_sync'] else 'DRIFTED')" 2>/dev/null || echo unknown)
# Freshness of the checkout the two above are measured against (2026-08-14):
# "in sync with my own checkout" means nothing if that checkout is a day old.
CTX_FRESH=$(python3 -c "import json;d=json.load(open('$BUILD/context.json'));v=d.get('checkout_fresh');print('current with origin ('+str(d.get('origin_commit'))+')' if v is True else ('STALE vs origin '+str(d.get('origin_commit'))) if v is False else 'unknown')" 2>/dev/null || echo unknown)
echo "$(STAMP) [$PROJECT/$KEY] context $CTX_SIG (harness $CTX_COMMIT, $CTX_SYNC, checkout $CTX_FRESH)" >> "$BUILD/pipeline.log"

# --- CODEGRAPH (begin) ---
# Every build gets the graph, and gets told the ONE command that reaches it.
# The soft "if this repo is indexed, use codegraph" sentence this replaces is
# what produced a session probing `ls .codegraph/` in a worktree, seeing the
# directory the committed .gitignore materialises there, concluding "indexed",
# and then doing a hundred shell reads against an index it never touched.
# codegraph-ensure.sh creates/refreshes the MAIN clone's index and emits a
# capability-tested line; a failure degrades to NOT AVAILABLE, never blocks.
CG_ORIENT=$("$HARNESS/bin/codegraph-ensure.sh" "$PROJECT" "$WT" 2>/dev/null) \
  || CG_ORIENT="CODEGRAPH NOT AVAILABLE (codegraph-ensure.sh failed)"
echo "$(STAMP) [$PROJECT/$KEY] $(head -1 <<<"$CG_ORIENT")" >> "$BUILD/pipeline.log"
# --- CODEGRAPH (end) ---

# --- VERIFICATION MAP (begin) ---
# The primer PLAN has been told to read since July finally gets written. Both
# this script (below) and run-preplan.sh have carried "if
# state/<project>-context.md exists, read it FIRST" while nothing wrote the
# file — a read contract dangling on an empty hook. render composes it from the
# repo's own docs/verification-map/, its CLAUDE.md verification contract and its
# AGENT_ARCHITECTURE.md, citing each, and says ABSENT for whichever it does not
# find. orient is the one-line availability note CC() injects, the same shape
# codegraph-ensure.sh established.
#
# FAIL-OPEN, both calls: a missing or broken map is not a reason to stop
# building. A render failure costs one pipeline.log line, and orient degrades to
# a NOT AVAILABLE line — never to silence, which a planner cannot tell apart
# from "nobody looked" and will go hunting to resolve.
"$HARNESS/bin/verification-map.sh" render "$PROJECT" --repo "$WT" --hotspots-out "$BUILD/hotspots.txt" >> "$BUILD/pipeline.log" 2>&1 \
  || echo "$(STAMP) [$PROJECT/$KEY] verification-map render failed — building without a primer" >> "$BUILD/pipeline.log"
# Computed ONCE here and reused by every stage: a build that edits routes and
# the map in its own working tree will still see the line as it stood at build
# start. That is the intended reading — it orients against the base the build
# started from — and it is why the freshness gate that matters is CI's
# verification-map-freshness on the finished diff, not this line.
VMAP_ORIENT=$("$HARNESS/bin/verification-map.sh" orient "$PROJECT" --repo "$WT" 2>/dev/null) \
  || VMAP_ORIENT="VERIFICATION MAP NOT AVAILABLE (verification-map.sh failed)"
[ -n "$VMAP_ORIENT" ] || VMAP_ORIENT="VERIFICATION MAP NOT AVAILABLE (verification-map.sh returned nothing)"
echo "$(STAMP) [$PROJECT/$KEY] $(head -1 <<<"$VMAP_ORIENT")" >> "$BUILD/pipeline.log"
# --- VERIFICATION MAP (end) ---

CC() { # CC <stage> <model> <timeout-sec> <outfile> <prompt>  (runner + cost via agent-call.sh)
  local stage="$1" model="$2" to="$3" out="$4" prompt="$5"
  # One injection point for twelve call sites: the code-touching stages get the
  # graph line FIRST, before anything else in their prompt. QA and other stages
  # do not read code this way and are left alone.
  #
  # The map line rides beside it for the stages that decide WHAT to build and
  # whether it was built right. A fix round works from named review findings and
  # QA gets its map pointer inside its own prompt, so neither needs this.
  # Defaulted, not bare: an unset VMAP_ORIENT is a harness bug, and a harness bug
  # must degrade to an honest line rather than killing a build stage under
  # `set -u`. Same reason the render above is fail-open.
  case "$stage" in
    plan|execute|review) prompt="${VMAP_ORIENT:-VERIFICATION MAP NOT AVAILABLE (never rendered for this build)}

$prompt" ;;
  esac
  case "$stage" in
    plan|execute|review|fix) prompt="$CG_ORIENT

$prompt" ;;
  esac
  # Phase 7: the stage's DECLARED OUTCOME, handed to agent-call.sh so it can
  # record the artifact on the claim right before it closes the phase. Consumed
  # once and cleared, so a declaration can never leak onto the next stage and
  # credit it with an artifact it did not produce.
  local _ak="${CC_ARTIFACT_KIND:-}" _af="${CC_ARTIFACT_FILE:-}"
  CC_ARTIFACT_KIND=""; CC_ARTIFACT_FILE=""
  # BH-2413: the call guard's fingerprint for this call. The plan and the
  # execute run are the ticket's build fp (BUILD_CALL_FP, written at plan time),
  # so a second build of the same unchanged ticket on the same main is the SAME
  # work to the guard. A fix round adds its outfile and the tree it fixes, so
  # the lens, merged and QA rounds of one build stay distinct. Plan and size
  # repairs, and every other stage, pass nothing: agent-call's per-prompt
  # fallback, as before. No build fp means nothing passed for any stage.
  local _fp="" _tree=""
  if [ -n "${BUILD_CALL_FP:-}" ]; then
    case "$stage:${out##*/}" in
      plan:plan-run.txt|execute:execute-run.txt) _fp="$BUILD_CALL_FP" ;;
      fix:*) _tree=$(git rev-parse --short=12 'HEAD^{tree}' 2>/dev/null) && [ -n "$_tree" ] \
               && _fp="$BUILD_CALL_FP:${out##*/}:t$_tree" ;;
    esac
  fi
  # BH-3481.0: the build tripwire measures the spend so far and alerts on a
  # trip. It never stops the build (BH-6705), so its answer is not read.
  if [ -n "${BUILD:-}" ]; then
    command -v tw_check_build >/dev/null 2>&1 && tw_check_build "$PROJECT" "${KEY:-}" "$BUILD" 0 >/dev/null || true
    # BH-4488: a build dir holding BUDGET_STOP is over its hard cap (agent-call
    # wrote it on the refused call). The build ends here with its terminal.
    if [ -f "$BUILD/BUDGET_STOP" ]; then
      BB budget_stop "" BUDGET_STOP "" false "$(head -c 1200 "$BUILD/BUDGET_STOP")"
      RESULT "BUILD_REFUSED BUDGET_STOP $(head -1 "$BUILD/BUDGET_STOP")"
      exit 3
    fi
    # BH-4489: a sibling call already deferred this build on a day cap (a lens
    # in a background subshell, whose own exit 3 ended only that subshell). It
    # is not terminal, so no BB event: defer without buying this call too.
    if [ -s "$BUILD/BUDGET_DEFER" ]; then
      RESULT "BUILD_DEFERRED $(head -1 "$BUILD/BUDGET_DEFER")"
      exit 3
    fi
  fi
  # BH-2578: every build call is the fly-pool lane's, so its knobs bind. A prefix,
  # not an export: run-decompose and prebuild-repro launched from here keep theirs.
  # BH-5839: AGENT_CALL_STEER=1 makes this call a step boundary for the ticket
  # page's notes. Only CC() sets it, because only CC() stops on a steer-hold.
  local _rc=0
  AGENT_CALL_STEER=1 AGENT_CALL_LANE=fly-pool AGENT_CALL_ARTIFACT_KIND="$_ak" AGENT_CALL_ARTIFACT_FILE="$_af" AGENT_CALL_FP="$_fp" \
    "$HARNESS/bin/agent-call.sh" "$stage" "$PROJECT" "$model" "$to" "$out" "$prompt" || _rc=$?
  if [ -n "${BUILD:-}" ] && [ -f "$BUILD/BUDGET_STOP" ]; then
    BB budget_stop "" BUDGET_STOP "" false "$(head -c 1200 "$BUILD/BUDGET_STOP")"
    RESULT "BUILD_REFUSED BUDGET_STOP $(head -1 "$BUILD/BUDGET_STOP")"
    exit 3
  fi
  # BH-4489: a day budget cap (stage-day / project-day) refused the call, or a
  # day cap could not be read inside the build (fail closed). Neither is
  # terminal: the day resets, the worker comes back. The build defers. Nothing
  # resumes it (resume-dead.sh leaves a first run's BUILD_DEFERRED to triage and
  # skips pool dirs): the ticket is re-offered as a fresh build, and the launch
  # gate in gates.sh refuses that re-offer while this project's day cap or any
  # build stage's stage-day cap is over or unreadable, so the retry buys no
  # plan or execute call before 00:00Z. BUDGET_DEFER
  # carries the deferral out of a backgrounded call (the parallel review
  # lenses): `exit 3` ends only that subshell, so the parent reads the marker
  # after the join, and every later CC() refuses on it. A resume clears it.
  if [ "$_rc" = 74 ]; then
    local _bl
    _bl=$(head -1 "$out" 2>/dev/null | tr -d '\r')
    case "$_bl" in
      "AGENT_CALL_REFUSED budget-stage-day "*|"AGENT_CALL_REFUSED budget-project-day "*|"AGENT_CALL_REFUSED budget-cap-unreadable "*)
        if [ -n "${BUILD:-}" ]; then
          echo "$(STAMP) [$PROJECT/${KEY:-}] $stage deferred on a budget cap: ${_bl#AGENT_CALL_REFUSED }" >> "$BUILD/pipeline.log"
          printf '%s\n' "${_bl#AGENT_CALL_REFUSED }" > "$BUILD/BUDGET_DEFER"
        fi
        RESULT "BUILD_DEFERRED ${_bl#AGENT_CALL_REFUSED }"
        exit 3 ;;
      # A person held this ticket from its page while this build ran.
      # bin/agent-call.sh refused the next step on the hold note; the build
      # stops here, after the step it was in. The hold label keeps the re-offer
      # from starting until someone resumes it. The same marker stops the
      # parallel review lenses; its line says which reason it was.
      "AGENT_CALL_REFUSED steer-hold "*)
        if [ -n "${BUILD:-}" ]; then
          echo "$(STAMP) [$PROJECT/${KEY:-}] $stage deferred: held from Mission Control (${_bl#AGENT_CALL_REFUSED })" >> "$BUILD/pipeline.log"
          printf '%s\n' "${_bl#AGENT_CALL_REFUSED }" > "$BUILD/BUDGET_DEFER"
        fi
        RESULT "BUILD_DEFERRED ${_bl#AGENT_CALL_REFUSED }"
        exit 3 ;;
    esac
  fi
  return $_rc
}

# >>> stage lane verdict (BH-1853)
# A stage whose session ended because the RUNNER LANE was out (an account at
# its limit, a credential refused) did not fail on the ticket. bin/agent-call.sh
# leaves that verdict beside every outfile as <outfile>.class; the plan stage
# has read it since BH-642, and these two let every later stage read it too.
# The predicate is bin/fly-pool.sh's pool_lane_failure, so the RESULT this
# writes is one the pool reap cools, unpins and requeues on without charging
# the ticket a deferral. Only the sidecars are read, never a review body that
# might quote the token. First line only, capped at 1000 bytes so the
# `exhausted=` and `resets_at=` fields at its end survive a long `seen=` list.
stage_lane_class() { # stage_lane_class <outfile>... -> prints the line, 0 when one blames the lane
  local f line
  for f in "$@"; do
    [ -s "$f.class" ] || continue
    line=$(head -1 "$f.class" 2>/dev/null | head -c 1000)
    case "$line" in *RUNNER_EXHAUSTED*|*" class=auth"*) printf '%s\n' "$line"; return 0 ;; esac
  done
  return 1
}
STAGE_LANE_DEFER() { # STAGE_LANE_DEFER <stage-label> <outfile>... — exits 3 when the lane failed
  local line
  line=$(stage_lane_class "${@:2}") || return 0
  echo "$(STAMP) [$PROJECT/$KEY] $1: the runner lane failed ($line) — deferring, not a verdict on the ticket" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED $1 session ended $line"; exit 3
}
# <<< stage lane verdict

# --- GATE: thread-stability snapshot (2026-08-14) -----------------------------
# TK-143 #517 shipped a code lane built against a comment the client superseded
# 10 minutes into planning — the plan prompt's THREAD RECENCY law can only see
# the thread as it stood when the planner READ it. Mechanical complement:
# fingerprint the ticket's activity before PLAN, re-fetch after, and defer the
# build if the thread moved underneath the planner. Fail-OPEN on API weather
# (board down must not stop builds); boardless projects (fleet prefix "-")
# return an empty fingerprint and skip the gate entirely.
TICKET_FP() {
  local base prefix tok tv
  base=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" prod 2>/dev/null)
  prefix=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)
  [ -n "$base" ] && [ "$base" != "-" ] || return 0
  # BH-1955: the token through bin/lib/board-creds.sh. None or two is one
  # ALERTS line and NO board call — the gate's fail-open "no snapshot".
  command -v board_token_var >/dev/null 2>&1 && tv=$(board_token_var "$PROJECT" "$HENV/$PROJECT.env" run-build) || return 0
  tok=$(board_env_value "$tv" "$HENV/$PROJECT.env")
  [ -n "$tok" ] || return 0
  curl -s -m 20 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$prefix/tickets/$TICKET" 2>/dev/null \
    | jq -r '(.ticket // .) as $t | "\($t.lastActivityAt // "")|\($t.updatedAt // "")|\($t.turnChangedAt // "")|\((.comments // $t.comments // []) | length)"' 2>/dev/null
}
FP_BEFORE=$(TICKET_FP)
[ -n "$FP_BEFORE" ] || echo "$(STAMP) [$PROJECT/$KEY] stale-check: no pre-PLAN activity snapshot (no board / API failure) — gate fails open" >> "$BUILD/pipeline.log"

# >>> ticket meta
# --- What the board already says this ticket IS (SDLC item 7) ----------------
# The deterministic half of the KIND classifier's evidence — the board's own
# type field, the GitHub issue's labels, the title — fetched ONCE here and
# written to $BUILD/ticket-meta.json, so bin/kind-gate.sh stays a pure file
# reader that an operator can re-run against an archived record and get the
# same answer this build got. The ticket BODY rides the same call (BH-985): the
# rollout hook below reads it from this file, so dispatching a rollout master
# costs no API call of its own. kind-gate.sh reads named fields only, so the
# extra key is inert there.
#
# FAIL-OPEN ON EVERY BRANCH, like TICKET_FP above: no board, no token, no gh,
# an API that 500s — all leave no file, and the classifier falls back to the
# plan's own KIND line. Fetched only when the file is absent, so a resume
# classifies the ticket as it stood when the plan was written rather than
# re-reading a board that may have moved.
TICKET_META() {
  local base prefix tok tv repo issue t rc=0
  base=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" prod 2>/dev/null)
  prefix=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)
  if [ -n "$base" ] && [ "$base" != "-" ] && [ "$prefix" != "-" ]; then
    # BH-1955: same resolver and same no-call refusal as TICKET_FP above.
    command -v board_token_var >/dev/null 2>&1 && tv=$(board_token_var "$PROJECT" "$HENV/$PROJECT.env" run-build) || return 0
    tok=$(board_env_value "$tv" "$HENV/$PROJECT.env")
    [ -n "$tok" ] || return 0
    curl -s -m 20 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$prefix/tickets/$TICKET" 2>/dev/null \
      | jq -c '(.ticket // .) | {title:(.title // ""),
                                 type:(.type // .ticketType // .issueType // ""),
                                 labels:(.labels // []),
                                 body:((.description // .body) // "")}' 2>/dev/null
    return 0
  fi
  # GitHub-issue projects (board prefix "-"): the `bug` label is the whole
  # deterministic signal there, and the jq projection keeps this to the three
  # fields the classifier and the rollout hook read instead of a full issue
  # object. A read that is not rc 0 prints nothing, so no empty file is promoted.
  repo=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  [ -n "$repo" ] && [ -n "$issue" ] && command -v gh >/dev/null 2>&1 || return 0
  t=$(mktemp "${TMPDIR:-/tmp}/ticket-meta.XXXXXX") || return 0
  gh_rest GET "repos/$repo/issues/$issue" > "$t" || rc=$?
  [ "$rc" = 0 ] && jq -c '{title:(.title // ""),labels:(.labels // []),body:(.body // "")}' "$t" 2>/dev/null
  rm -f "$t"
  return 0
}
if [ ! -s "$BUILD/ticket-meta.json" ]; then
  TICKET_META > "$BUILD/ticket-meta.new" 2>/dev/null
  if [ -s "$BUILD/ticket-meta.new" ]; then mv "$BUILD/ticket-meta.new" "$BUILD/ticket-meta.json"
  else rm -f "$BUILD/ticket-meta.new"
       echo "$(STAMP) [$PROJECT/$KEY] KIND: no ticket metadata (no board / no gh / API failure) — the plan's own KIND line decides" >> "$BUILD/pipeline.log"; fi
fi
KIND_PROBE=$("$HARNESS/bin/kind-gate.sh" "$BUILD" 2>/dev/null)
KIND_HINT=$(sed -n 's/^KIND_HINT:[[:space:]]*//p' <<<"$KIND_PROBE" | tail -1)
KIND_HINT_SRC=$(sed -n 's/^KIND_HINT_SOURCE:[[:space:]]*//p' <<<"$KIND_PROBE" | tail -1)
if [ -n "${KIND_HINT:-}" ] && [ "$KIND_HINT" != none ]; then
  # A type field or a label is the board SAYING the kind. A title prefix is the
  # gate READING one off how somebody typed a sentence, and it is the source
  # that misfires — so it asks rather than asserts, while the gate's precedence
  # rule stays as it is and still prints the disagreement either way.
  case "$KIND_HINT_SRC" in
    title=*) KIND_HINT_LINE="THE TICKET TITLE READS AS KIND: $KIND_HINT (evidence: $KIND_HINT_SRC) — a title prefix, which is the weakest evidence the board offers, so if the thread says otherwise write the KIND you actually find and say why. Whichever you write, the gate compares it to that prefix and prints the disagreement for the reviewer rather than resolving it silently." ;;
    *)       KIND_HINT_LINE="THE BOARD ALREADY CLASSIFIES THIS TICKET as KIND: $KIND_HINT (evidence: $KIND_HINT_SRC), and that classification wins over yours — write that KIND line. If you think it is wrong, write it anyway and say why in the plan, because a reviewer can read the thread and adjudicate; silently reclassifying cannot be reviewed." ;;
  esac
else
  KIND_HINT_LINE="The board carries no type field, label or title prefix for this ticket, so your KIND line is the only classification this build will have — read the thread and choose honestly."
fi
# >>> plan ambiguity rule
# WHO IS ON THE OTHER SIDE OF AN OPEN QUESTION (the operator, 2026-09-13).
#
# On an IN-APP PRODUCT BOARD the other side is the CLIENT. A plan that guesses
# at a client's intent ships the wrong feature and costs a revert plus a
# conversation, so BLOCKED-NEEDS-CLARIFICATION is exactly right there and is
# left alone — the early-engagement incident is the standing lesson.
#
# On a GITHUB-ISSUES LANE (fleet.conf board prefix "-": project-5, project-7,
# project-6) the other side is OPERATOR, and the operator does not answer build questions —
# "the reality is I will never do a human review". A plan that parks there is a
# ticket that never ships. So the planner runs ASSUMPTION-FORWARD: it takes the
# most conservative reading it can defend, writes what it assumed under an
# ASSUMPTIONS heading, and builds. The assumptions ride into the PR body
# (PR_BODY_FOR below), which is where they are cheap to correct.
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  PLAN_AMBIGUITY_RULE="AMBIGUITY IS NOT A STOP ON THIS LANE. This ticket is a GitHub issue, and nobody is standing by to answer a question about it — a plan that parks is a ticket that never ships. So do NOT write BLOCKED-NEEDS-CLARIFICATION for an unconfirmed mechanism. Instead: pick the MOST CONSERVATIVE reading you can defend (the one that changes the least, breaks the least, and is easiest to reverse if it is wrong), and write a '## ASSUMPTIONS' section in plan.md listing every such pick as its own line — what was ambiguous, what you assumed, and what you would have done under the other reading. That section is copied verbatim into the PR body, so a wrong assumption is caught at review instead of stalling the build. The ONE thing that still stops you: if the thread's LATEST state says the work is on hold, manual/data-entry, or already shipped, that is not ambiguity and it is not yours to assume past — write BLOCKED as the first line with that quote."
else
  PLAN_AMBIGUITY_RULE="If the thread does NOT actually confirm the mechanism, write BLOCKED-NEEDS-CLARIFICATION as the first line of plan.md with the open questions."
fi
# <<< plan ambiguity rule
# >>> carried note
# A NOTE THE RESOLVER LEFT FOR THIS KEY (2026-09-13, bin/blocked-resolver.sh).
# When an adjudication ACCEPTS something the pipeline is going to block on again
# — today that is one thing, a TEST-CHANGE justification for a deletion a Fable
# ruling found legitimate — the ruling has to reach the NEXT build, and a pool
# build cannot be resumed (its machine is gone, and the hub holds only a copy of
# its record). So the resolver writes the note here, keyed on the ticket, and
# the plan stage CONSUMES it: the file is moved into this build's own directory,
# so it is read exactly once and a later, unrelated build of the same key never
# inherits a ruling about a diff it does not contain.
#
# A POOL MACHINE HAS NO HUB STATE, so bin/fly-pool.sh relays the hub's note
# beside the job (push_build_note) to build-note-$PROJECT-$KEY.md in the relay
# dir; that copy is read first, then the local one (a hub build).
#
# A WATCHER BOX HAS NEITHER (BH-5003), so the note is also the ledger row
# build_note/"$PROJECT $KEY" (bin/lib/build-note-db.sh, sourced by
# bin/run-build.sh). The order is relay file, then the row (bn_take claims a
# `pending` row as `consumed`, atomically across boxes, and only a won claim
# writes the note), then the local file. A relay or local consume marks the row
# consumed too, so no second box uses the same ruling, and a local file whose
# row another box already used (bn_used: the row's detail is THIS file, never an
# earlier note's row left behind) is retired (.relayed-<epoch>, the name the
# re-plan floor counts) instead of consumed again. Every DB step is behind
# `command -v`, and every failure (no lib, BUILD_NOTE_DB=0, a 404, an outage)
# leaves exactly the file behaviour above. pipeline.log names the source.
CARRIED_NOTE_LINE=""
CARRIED_NOTE_SRC="$HARNESS/state/build-notes/$PROJECT/$KEY.md"
BUILD_NOTE_RELAY="/run/harness/build-note-$PROJECT-$KEY.md"
CN_FROM=""
if [ -s "$BUILD_NOTE_RELAY" ] && [ ! -s "$BUILD/carried-note.md" ]; then
  CN_SRC="$BUILD_NOTE_RELAY"; CN_FROM=relay
elif [ ! -s "$BUILD/carried-note.md" ] && command -v bn_take >/dev/null 2>&1 \
     && bn_take "$PROJECT" "$KEY" "$BUILD/carried-note.md"; then
  CN_SRC="ledger build_note/$PROJECT $KEY"; CN_FROM=db
  # A hub build holds the same note as its file: the full text replaces the
  # row's 4000-byte copy, and the file is used up exactly as a local consume.
  [ -s "$CARRIED_NOTE_SRC" ] && { mv -f "$CARRIED_NOTE_SRC" "$BUILD/carried-note.md" 2>/dev/null || rm -f "$CARRIED_NOTE_SRC"; }
  echo "$(STAMP) [$PROJECT/$KEY] carried note from bin/blocked-resolver.sh consumed into $BUILD/carried-note.md (source: db — $CN_SRC)" >> "$BUILD/pipeline.log"
elif [ -s "$CARRIED_NOTE_SRC" ] && [ ! -s "$BUILD/carried-note.md" ]; then
  CN_SRC="$CARRIED_NOTE_SRC"; CN_FROM=local
  if command -v bn_used >/dev/null 2>&1; then
    case "$(bn_used "$PROJECT" "$KEY" "$CARRIED_NOTE_SRC" 2>/dev/null)" in
      consumed|relayed)
        mv -f "$CARRIED_NOTE_SRC" "$CARRIED_NOTE_SRC.relayed-$(date +%s)" 2>/dev/null || rm -f "$CARRIED_NOTE_SRC"
        echo "$(STAMP) [$PROJECT/$KEY] carried note $CARRIED_NOTE_SRC NOT used: its ledger row says another box already used it (retired .relayed-*)" >> "$BUILD/pipeline.log"
        CN_FROM="" ;;
    esac
  fi
fi
if [ "$CN_FROM" = relay ] || [ "$CN_FROM" = local ]; then
  mv -f "$CN_SRC" "$BUILD/carried-note.md" 2>/dev/null || cp -f "$CN_SRC" "$BUILD/carried-note.md"
  echo "$(STAMP) [$PROJECT/$KEY] carried note from bin/blocked-resolver.sh consumed into $BUILD/carried-note.md (source: $CN_FROM — $CN_SRC)" >> "$BUILD/pipeline.log"
  if command -v bn_mark >/dev/null 2>&1; then bn_mark "$PROJECT" "$KEY" consumed >/dev/null 2>&1 || true; fi
fi
# KIND: ci-replan (policy, the operator 2026-09-24): a prior PR of this ticket stayed
# CI-red through its repair rounds and was parked; this build is the automatic
# NARROWER re-plan, and the note is its evidence, not an adjudication ruling.
if [ -s "$BUILD/carried-note.md" ] && [ "$(head -1 "$BUILD/carried-note.md" 2>/dev/null)" = "KIND: ci-replan" ]; then
  CARRIED_NOTE_LINE=" THIS BUILD IS AN AUTOMATIC NARROWER RE-PLAN. A prior PR of this ticket stayed CI-red after its repair rounds and was parked. Plan a NARROWER change than the prior attempt: the smallest slice of the ticket that can land green on its own, informed by the failing checks below; leave the rest for a follow-up and do not repeat the prior approach unchanged. EVIDENCE: $(tail -n +2 "$BUILD/carried-note.md" | head -c 1500 | tr '\n' ' ')"
# KIND: stale-replan (BH-3935): a prior PR of this ticket sat with no new commit
# and no new review past pr_stale.replan_days and was parked; this build is the
# automatic re-plan. Nothing was refused, so it is not framed as a ruling.
elif [ -s "$BUILD/carried-note.md" ] && [ "$(head -1 "$BUILD/carried-note.md" 2>/dev/null)" = "KIND: stale-replan" ]; then
  CARRIED_NOTE_LINE=" THIS BUILD IS AN AUTOMATIC RE-PLAN. A prior PR of this ticket sat with no new commits and no new review for days and was parked. Re-read the ticket thread and plan it fresh against current main; do not assume the prior PR's approach. EVIDENCE: $(tail -n +2 "$BUILD/carried-note.md" | head -c 1500 | tr '\n' ' ')"
elif [ -s "$BUILD/carried-note.md" ]; then
  CARRIED_NOTE_LINE=" A PRIOR BUILD OF THIS TICKET WAS BLOCKED AND THE BLOCK WAS ADJUDICATED. The ruling is below, verbatim. Honor it: if it carries a 'TEST-CHANGE:' block, copy that block into plan.md word for word (the test-tamper gate reads plan.md for exactly that string, and without it this build blocks again on a change that has already been ruled acceptable). If it says something was REJECTED, do not do that thing again. RULING: $(head -c 1500 "$BUILD/carried-note.md" | tr '\n' ' ')"
fi
# <<< carried note
# >>> reopen reason (BH-6159)
# A ticket the client sent back carries the comments posted around that move,
# saved by the reopen lane (bin/lib/reopen-reason.sh, row reopen_reason/"<p> <KEY>").
# The plan prompt gets them so the rebuild answers the rejection. Fails open.
REOPEN_REASON_LINE=""; RR_LOG=none
[ -r "$HARNESS/bin/lib/reopen-reason.sh" ] && . "$HARNESS/bin/lib/reopen-reason.sh" 2>/dev/null
if command -v rr_plan_line >/dev/null 2>&1 && rr_on; then
  rr_plan_line "$PROJECT" "$KEY" >/dev/null 2>&1
  REOPEN_REASON_LINE="${RR_LINE:-}"
fi
echo "$(STAMP) [$PROJECT/$KEY] REOPEN REASON: ${RR_LOG:-none}" >> "$BUILD/pipeline.log"
# <<< reopen reason (BH-6159)
# >>> revert reason (BH-6160)
# A ticket whose merge was reverted carries the failure signal of that revert,
# saved by the reopen lane (bin/lib/revert-reason.sh, row revert_reason/"<p> <KEY>").
# The plan prompt gets it so the rebuild does not fail the same way. Fails open.
REVERT_REASON_LINE=""; RV_LOG=none
[ -r "$HARNESS/bin/lib/revert-reason.sh" ] && . "$HARNESS/bin/lib/revert-reason.sh" 2>/dev/null
if command -v rv_plan_line >/dev/null 2>&1; then
  rv_plan_line "$PROJECT" "$KEY" >/dev/null 2>&1
  REVERT_REASON_LINE="${RV_LINE:-}"
fi
echo "$(STAMP) [$PROJECT/$KEY] REVERT REASON: ${RV_LOG:-none}" >> "$BUILD/pipeline.log"
# <<< revert reason (BH-6160)
# <<< ticket meta
# >>> rollout hook
# A ROLLOUT MASTER FILES ITS WAVES, IT NEVER BUYS A PLAN (BH-985, child .4 of
# #816). A ticket whose body carries a `## Rollout` section is a sequence its
# author already wrote down. Planning it is a model call for work that is
# already decided, and the size gate splitting it is a split of a thing that is
# already split — so the decision is made HERE, above the pre-plan adoption and
# the PLAN launch, on the ticket meta the block above already fetched.
#
# FAIL-OPEN ON EVERY ABSENCE, and that is what lets this slice ship before
# bin/run-rollout.sh (#984) exists: no ticket-meta.json, no body field, an empty
# body, or no executable lane script on this box, and the block does nothing at
# all. `-x` rather than `-r` on purpose — a non-executable file is a half-synced
# box, and the ordinary plan path is the safe default there.
#
# DETECTION IS DELEGATED. `--is-rollout` is the lane's own answer (it runs
# bin/lib/file-children.sh's fence-safe detector); a second copy of that state
# machine here is exactly the bug that library exists to prevent. Anything but
# rc 0 — a no, or a crash — falls through to the plan, because filing issues on
# a real repo is irreversible and a detector that did not say yes has not said
# yes. The child regex is the size gate's own, byte for byte: a `.n` title is a
# wave, and a wave is planned like any other ticket.
RH_BODY=""
if [ -s "$BUILD/ticket-meta.json" ] && [ -x "$HARNESS/bin/run-rollout.sh" ]; then
  RH_BODY=$(jq -r '.body // ""' "$BUILD/ticket-meta.json" 2>/dev/null)
fi
if [ -n "$RH_BODY" ]; then
  RH_TITLE=$(jq -r '.title // ""' "$BUILD/ticket-meta.json" 2>/dev/null)
  printf '%s\n' "$RH_BODY" > "$BUILD/ticket-body.md"
  if ! grep -qE '^[[:space:]]*[A-Za-z]+-[0-9]+\.[0-9]+' <<<"$RH_TITLE" \
     && "$HARNESS/bin/run-rollout.sh" --is-rollout "$BUILD/ticket-body.md" >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT/$KEY] ROLLOUT: the ticket body carries a rollout section — filing its waves instead of planning it (no model call)" >> "$BUILD/pipeline.log"
    "$HARNESS/bin/run-rollout.sh" "$PROJECT" "$TICKET" "$KEY" "$BUILD" > "$BUILD/rollout-hook.out" 2>&1
    RH_RC=$?
    # The lane's own word, wherever it wrote it (stdout, its run log, or both —
    # last match wins), bare or in the `RESULT "…"` form. NO LINE IS A FAILURE,
    # and so is a FILED line from a run that exited non-zero: `done` here must
    # mean the waves are on the board, never "the script ended".
    # Quoted form FIRST, then `t` so a matched `RESULT "…"` line is never re-read
    # as a bare one: the reason is free text the lane writes, and a reason that
    # names a wave quotes it (`… unknown wave "foo"`). Matching up to the first
    # inner `"` matched nothing at all and lost the lane's word to the generic
    # fallback below (BH-1338). Only the quoted form strips a closing `"`; a bare
    # reason that legitimately ends in one is kept whole.
    RH_LINE=$(cat "$BUILD/rollout-run.txt" "$BUILD/rollout-hook.out" 2>/dev/null \
      | sed -nE -e 's/^RESULT[[:space:]]+"(ROLLOUT_(FILED|FAILED).*)"[[:space:]]*$/\1/p' -e t \
                -e 's/^(RESULT[[:space:]]+)?(ROLLOUT_(FILED|FAILED)([^[:space:]]|.*[^[:space:]])?)[[:space:]]*$/\2/p' | tail -1)
    [ -n "$RH_LINE" ] || RH_LINE="ROLLOUT_FAILED bin/run-rollout.sh ended rc=$RH_RC without a result line (see $BUILD/rollout-run.txt)"
    case "$RH_LINE" in ROLLOUT_FILED*) [ "$RH_RC" = 0 ] || RH_LINE="ROLLOUT_FAILED bin/run-rollout.sh wrote '$RH_LINE' but exited rc=$RH_RC" ;; esac
    RESULT "$RH_LINE"
    exit 0
  fi
fi
# <<< rollout hook
# >>> untrusted input gate (BH-4491)
# --- TICKET TEXT IS DATA: THE INJECTION-SHAPE CHECK RUNS BEFORE ANY PLAN SPEND --
# bin/lib/untrusted-input.sh reads the ticket (title, body, comments not
# written by the harness or by a trigger.actors.<p> human) and greps it for
# instructions aimed at the agent. The settings row untrusted_input.mode says
# what a flag does: log (record only), warn (record, and the plan prompt names
# the flagged spans as hostile data; the default), block (refuse with ONE
# comment quoting the span, ledger untrusted-input "<p> <KEY>"). Here, above the
# repro drive, the pre-plan adoption and the CC plan call, so under block no
# plan model call is made. A resumed build runs it again: it is grep, no model.
# BUILD_REFUSED for a block, COMMENTED only when the ticket carries our comment
# for this episode (a failed post leaves the sweep its ALERTS line).
# BUILD_DEFERRED when the answer cannot be trusted (unreadable text under block,
# a flag under an unknown mode, no ledger). TOP LEVEL ONLY: the exit 3 is the point.
UI_PLAN_NOTE=""
# shellcheck source=bin/lib/untrusted-input.sh
if [ -r "$(dirname "$0")/lib/untrusted-input.sh" ]; then . "$(dirname "$0")/lib/untrusted-input.sh" 2>/dev/null
elif [ -r "$HARNESS/bin/lib/untrusted-input.sh" ]; then . "$HARNESS/bin/lib/untrusted-input.sh" 2>/dev/null
fi
if ! command -v ui_gate >/dev/null 2>&1; then
  echo "$(STAMP) [$PROJECT/$KEY] UNTRUSTED-INPUT defer: lib missing on $(hostname) (half-synced bin/?)" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED untrusted-input lib missing on $(hostname) — the next tick re-offers $KEY"
  exit 3
fi
UI_RC=0
ui_gate "$PROJECT" "$KEY" "${TICKET:-}" "$BUILD" || UI_RC=$?
if [ "$UI_RC" = 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] UNTRUSTED-INPUT $UI_LINE" >> "$BUILD/pipeline.log"
elif [ "$UI_RC" = 1 ]; then
  UI_LINE="SKIP_UNTRUSTED $KEY — $UI_LINE"
  echo "$(STAMP) [$PROJECT/$KEY] UNTRUSTED-INPUT $UI_LINE" >> "$BUILD/pipeline.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] $UI_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
  RESULT "BUILD_REFUSED $UI_LINE"
  [ "${UI_SPOKE:-0}" = 1 ] && touch "$BUILD/COMMENTED"
  exit 3
else
  echo "$(STAMP) [$PROJECT/$KEY] UNTRUSTED-INPUT defer: $UI_LINE" >> "$BUILD/pipeline.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] UNTRUSTED-INPUT defer: $UI_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
  RESULT "BUILD_DEFERRED untrusted-input unverifiable ($UI_LINE) — the next tick re-offers $KEY"
  exit 3
fi
# <<< untrusted input gate (BH-4491)
# >>> pr-body-requires note (BH-7378)
# The planner lists each section or literal the PR body must carry in a
# fenced ```pr-body-requires block, and the pre-review self-check NOTEs each
# one the live body lacks. It rides in front of PLAN ONLY through
# UI_PLAN_NOTE, so the prompt line itself does not change. No lib on the box:
# the variable stays as it was.
# shellcheck source=bin/lib/pr-body-requires.sh
[ -r "$HARNESS/bin/lib/pr-body-requires.sh" ] && . "$HARNESS/bin/lib/pr-body-requires.sh" 2>/dev/null
command -v pbr_plan_rule >/dev/null 2>&1 && UI_PLAN_NOTE="${UI_PLAN_NOTE:-}$(pbr_plan_rule) "
# <<< pr-body-requires note (BH-7378)
# >>> changed symbols note (BH-5791)
# The planner lists the symbols it changes, so the design collisions block
# below can check them against main and the open PRs. It rides in front of
# PLAN ONLY through UI_PLAN_NOTE, so the prompt line itself does not change.
# No lib on the box: the variable stays as it was.
# shellcheck source=bin/lib/plan-collisions.sh
[ -r "$HARNESS/bin/lib/plan-collisions.sh" ] && . "$HARNESS/bin/lib/plan-collisions.sh" 2>/dev/null
command -v pc_plan_note >/dev/null 2>&1 && UI_PLAN_NOTE="${UI_PLAN_NOTE:-}$(pc_plan_note) "
# <<< changed symbols note (BH-5791)
# >>> stack section note (BH-6389)
# A child planned on its parent's OPEN branch is told the `## Stack` rule; the
# note is empty unless the stacked child block left $BUILD/stack-wait-pending.
SWN_NOTE=""; command -v sw_plan_note >/dev/null 2>&1 && SWN_NOTE=$(sw_plan_note "$BUILD")
[ -n "$SWN_NOTE" ] && UI_PLAN_NOTE="${UI_PLAN_NOTE:-}$SWN_NOTE "
# <<< stack section note (BH-6389)
# >>> spec trace note (BH-6485)
# A ticket body with `Spec:` or `Reference:` lines tells the planner the
# `## Spec trace` rule (prompts/plan-contract.md §17) through UI_PLAN_NOTE, so
# the prompt line does not change. No such lines, or no lib: nothing is added.
# shellcheck source=bin/lib/spec-trace.sh
[ -r "$HARNESS/bin/lib/spec-trace.sh" ] && . "$HARNESS/bin/lib/spec-trace.sh" 2>/dev/null
STN_NOTE=""; command -v st_plan_note >/dev/null 2>&1 && STN_NOTE=$(st_plan_note "$BUILD/ticket-meta.json")
[ -n "$STN_NOTE" ] && UI_PLAN_NOTE="${UI_PLAN_NOTE:-}$STN_NOTE"
# <<< spec trace note (BH-6485)
# >>> replan check (BH-3955)
# A SPLIT CHILD WHOSE BLOCKERS HAVE MERGED GETS ONE CHEAP LOOK BEFORE ITS PLAN.
# bin/replan-check.sh decides eligibility itself (a `<KEY>.<n>` child, n >= 1,
# with `Part of #` and every `Blocked-by` merged, not stacked) and writes
# $BUILD/replan-verdict on every path; a resume reuses that file, so this costs
# one call per build dir at most. amend: the amended scope rides the plan prompt
# below and the pre-plan adoption is bypassed. escalate: the script already put
# the `hold` label on and sent the one beat, so this build parks as PLAN_BLOCKED,
# the terminal the sweep, the blocked-resolver and the hold label already own.
# Anything else, a missing script included, plans exactly as before.
REPLAN_LINE=""
if [ -x "$HARNESS/bin/replan-check.sh" ]; then
  STACK_ON="${STACK_ON:-}" HARNESS="$HARNESS" timeout 300 "$HARNESS/bin/replan-check.sh" "$PROJECT" "$TICKET" "$KEY" "$BUILD" >> "$BUILD/replan-check.out" 2>&1
fi
case "$(head -1 "$BUILD/replan-verdict" 2>/dev/null)" in
  amend*)
    [ -s "$BUILD/replan-amendment.md" ] && REPLAN_LINE=" THE BLOCKERS OF THIS CHILD HAVE MERGED AND A REPLAN CHECK AMENDED ITS SCOPE. Plan against the AMENDED scope and acceptance tests below; they supersede the issue body where they differ. AMENDMENT: $(head -c 4000 "$BUILD/replan-amendment.md" | tr '\n' ' ')" ;;
  escalate*)
    # A failed hold put no label on, so the copy must not say one parks it.
    case "$(head -1 "$BUILD/replan-verdict" 2>/dev/null)" in
      "escalate hold-failed"*) RPC_PARK='The `hold` label could NOT be applied (see ALERTS.log), so nothing parks it yet; put the label on, or answer the decision on the thread.' ;;
      *) RPC_PARK='The `hold` label parks it; remove the label once the decision is on the thread.' ;;
    esac
    printf 'BLOCKED: REPLAN escalate :: %s\n\nEvery blocker of this child merged, and a replan check found a decision only a human can make before it builds. %s Evidence: %s\n' \
      "$(head -1 "$BUILD/replan-decision.txt" 2>/dev/null)" "$RPC_PARK" "$BUILD/replan-evidence.md" > "$BUILD/plan.md"
    BB plan_blocked "" "" "" false "$(head -c 1200 "$BUILD/plan.md" 2>/dev/null)"
    RESULT "PLAN_BLOCKED $BUILD/plan.md"; exit 4 ;;
esac
# <<< replan check (BH-3955)
# >>> prebuild repro (BH-2004)
# REPRODUCE A BUG BEFORE PAYING FOR ITS BUILD. bin/prebuild-repro.sh records
# $BUILD/prebuild-repro.txt and answers 0 (build), 10 (stopped, the ticket was
# commented) or 11 (stop wanted, the comment failed). The record's presence is
# the resume guard, so a resumed build never pays for the repro twice; rc 11
# deletes it so the next offer retries. Every stage is a stub today (BH-2039):
# a bug records cannot-drive and builds as before. A box without the runner or
# its library fails open, the same rationale as the rollout hook above.
REPRO_BRIEF_LINE=""
# shellcheck disable=SC1091
[ -r "$HARNESS/bin/lib/prebuild-repro.sh" ] && . "$HARNESS/bin/lib/prebuild-repro.sh"
if [ ! -e "$BUILD/prebuild-repro.txt" ] && [ -x "$HARNESS/bin/prebuild-repro.sh" ]; then
  "$HARNESS/bin/prebuild-repro.sh" "$PROJECT" "$TICKET" "$KEY" "$BUILD" >> "$BUILD/prebuild-repro.out" 2>&1
  PRR_RC=$?
  case "$PRR_RC" in
    10) RESULT "BUILD_DEFERRED repro NOT_REPRODUCED — commented on the ticket, waiting on the client"; touch "$BUILD/COMMENTED"; exit 3 ;;
    11) rm -f "$BUILD/prebuild-repro.txt"; RESULT "BUILD_DEFERRED repro NOT_REPRODUCED but the board comment failed — retrying next offer"; exit 3 ;;
  esac
fi
command -v pr_brief_line >/dev/null 2>&1 && REPRO_BRIEF_LINE="$(pr_brief_line "$BUILD")"
# <<< prebuild repro
# >>> preplan adopt
# ADOPT A PRE-PLAN (the operator, 2026-09-14). bin/run-preplan.sh has written plans into
# plans/<project>-<KEY>/ since 2026-07-23 and this file never read one: the
# checkpoint below guards on $BUILD/plan.md, which a FRESH build dir never has.
# So every pre-plan the fleet ever paid for was thrown away and every build paid
# the PLAN stage again — 7-10 minutes of a 60-75 minute ticket, measured tonight
# on project-5. Consuming one is the entire point of that stage existing.
#
# IT IS A COPY INTO $BUILD, NOT A SECOND CODE PATH. The plan lands exactly where
# the checkpoint already looks, so from here on this build is byte-identical to
# a resumed one: same BLOCKED check, same resume-stale gate, same plan gate,
# same size gate, and bin/planned-files.sh re-derives the claim list from the
# adopted plan the way it does from a fresh one. ticket-fp rides along for that
# reason — without it the adopted plan would skip the thread-stability gate
# every other plan in this pipeline passes through (TK-143 #517).
#
# THE POOL READS A RELAYED COPY. A fly builder has no hub plans/ dir, so
# bin/fly-pool.sh pushes the pre-plan to /run/harness/preplan beside the job
# file it already pushes; preplan_find looks there FIRST and demands the dir's
# `key` file match this KEY, because a pool machine is reused between jobs.
#
# STALE IS DISCARD. bin/lib/preplan-lib.sh:preplan_check refuses a plan whose
# listed files have moved on main since it was written, and refuses one it
# cannot judge at all. Either way the pre-plan is dropped and this build plans
# fresh — re-planning costs 7-10 min, executing a stale plan costs a revert.
#
# THE THREAD IS CHECKED HERE, NOT LATER (BH-658). A pre-plan carries the board
# fingerprint it was written against, and the adopt used to copy that file into
# $BUILD — where the resume-stale gate below would compare it, find the thread
# had moved, and exit PLAN_STALE. On a Fly machine that ends the whole build and
# wastes the machine, for a condition whose correct answer is simply "plan
# fresh". So the comparison happens here, and a plan written against an older
# thread is DISCARDED and this run continues into a normal PLAN stage.
#
# EVERY BRANCH WRITES $BUILD/preplan-outcome AND ONE pipeline.log LINE. Adopted
# without saying so, and skipped without saying so, were both invisible before:
# 0 of 1052 build records on box-project-4-1 carried a PREPLAN_ line while
# that box's own plans/ held 58 plan dirs. bin/evidence-summary.sh renders the
# outcome into the PR body from that file.
#
# Kill flag: PREPLAN_SPECULATIVE=0 or flags/preplan-speculative-off — no lib
# call, no adopt, and this build plans for itself exactly as it does today.
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HARNESS/bin/lib/preplan-lib.sh" ] && . "$HARNESS/bin/lib/preplan-lib.sh"
PP_DIR=""; PP_OUTCOME=""; PP_WHY=""; PP_RC=0; PP_FP=""; PP_RESUMED=0
if [ -s "$BUILD/plan.md" ]; then
  # A RESUME. The plan is already here, so there is nothing to adopt — but if an
  # earlier attempt in this same dir recorded how it got here, THAT answer
  # stands: re-labelling a HIT as a MISS because the plan is now on disk would
  # make the evidence row lie about a pre-plan the fleet did use.
  #
  # It is FIRST in the chain for that reason. Below the kill flag, a resume of a
  # build that adopted a pre-plan would answer OFF the moment someone set
  # PREPLAN_SPECULATIVE=0 — the same lie in a different word — and below the
  # library check it would answer MISS on a box that had lost the lib.
  PP_RESUMED=1
  PP_OUTCOME=$(head -1 "$BUILD/preplan-outcome" 2>/dev/null)
  [ -n "$PP_OUTCOME" ] || PP_OUTCOME="MISS resumed dir already carries a plan"
# BH-3955: a pre-plan predates the replan check's amendment, so it plans the
# scope the amendment replaced.
elif [ -s "$BUILD/replan-amendment.md" ]; then
  PP_OUTCOME="MISS replan amended the child's scope after the pre-plan was written"
elif ! command -v preplan_find >/dev/null 2>&1; then
  PP_OUTCOME="MISS the pre-plan library is not on this box"
elif [ "$(preplan_speculative "$HARNESS")" != 1 ]; then
  PP_OUTCOME="OFF speculative pre-planning is switched off"
elif ! PP_DIR=$(preplan_find "$HARNESS" "$PROJECT" "$KEY") \
     && ! { command -v preplan_fetch >/dev/null 2>&1 && _preplan_client "$HARNESS"; }; then
  PP_OUTCOME="MISS no pre-plan for $KEY (relay dir empty, hub plans/ empty, coordination DB not asked)"
elif [ -z "$PP_DIR" ] && { preplan_fetch "$HARNESS" "$PROJECT" "$KEY" "$BUILD/preplan-db"; PP_RC=$?; [ "$PP_RC" != 0 ]; }; then
  # THE BUILDER ASKS THE DB ITSELF (BH-3437). The hub's push_preplan reads the
  # row once, at dispatch, and a pre-plan published a few seconds later never
  # reached the machine: BH-3437's own build missed its pre-plan by 21 s. So a
  # relay/plans/ miss asks the coordination DB here, into $BUILD, and a row
  # found falls through to the same thread and staleness checks below.
  # preplan_fetch rc 1 is the DB saying "no row"; rc 2 is no usable answer,
  # and an outage is never written down as a real miss.
  if [ "$PP_RC" = 1 ]; then
    PP_OUTCOME="MISS no pre-plan for $KEY (relay dir empty, hub plans/ empty, coordination DB has no row)"
  else
    PP_OUTCOME="MISS no pre-plan for $KEY (relay dir empty, hub plans/ empty, coordination DB unreachable)"
  fi
  PP_RC=0
else
  [ -n "$PP_DIR" ] || PP_DIR="$BUILD/preplan-db"
  PP_FP=$(cat "$PP_DIR/ticket-fp" 2>/dev/null)
  # Absence fails OPEN on both sides, exactly as the resume gate below does: a
  # boardless project prints no fingerprint at all, and board weather at either
  # end must not throw away a plan that is still perfectly true of the code.
  if [ -n "$PP_FP" ] && [ -n "$FP_BEFORE" ] && [ "$PP_FP" != "$FP_BEFORE" ]; then
    PP_OUTCOME="STALE thread moved since the pre-plan was written ($PP_FP -> $FP_BEFORE)"
  else
    PP_WHY=$(preplan_check "$PP_DIR" "$WT" "$BASE"); PP_RC=$?
    if [ "$PP_RC" = 0 ]; then
      cp -f "$PP_DIR/plan.md" "$BUILD/plan.md" 2>/dev/null
      [ -s "$PP_DIR/ticket-fp" ] && cp -f "$PP_DIR/ticket-fp" "$BUILD/ticket-fp" 2>/dev/null
      [ -s "$PP_DIR/plan-thread-at" ] && cp -f "$PP_DIR/plan-thread-at" "$BUILD/plan-thread-at" 2>/dev/null
      PP_OUTCOME="HIT $PP_WHY"
    else
      PP_OUTCOME="STALE $PP_WHY"
    fi
  fi
fi
if [ "$PP_RESUMED" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_${PP_OUTCOME%% *} resumed dir already carries a plan — outcome unchanged ($PP_OUTCOME)" >> "$BUILD/pipeline.log"
else
case "$PP_OUTCOME" in
  HIT*)
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_HIT adopted $PP_DIR (${PP_OUTCOME#HIT }) — PLAN stage skipped" >> "$BUILD/pipeline.log"
    BB preplan_adopted "" "" "" false "${PP_OUTCOME#HIT }" ;;
  STALE*)
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_STALE $PP_DIR (${PP_OUTCOME#STALE }) — discarded, planning fresh" >> "$BUILD/pipeline.log"
    # Only the HUB copy is removed. The relayed copy lives on an ephemeral
    # machine that is about to be destroyed, and rm-ing it would be the one
    # write this block makes outside $BUILD for no benefit at all.
    case "$PP_DIR" in "$HARNESS/plans/"*) rm -rf "$PP_DIR" ;; esac ;;
  OFF*)
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_OFF ${PP_OUTCOME#OFF } — planning fresh" >> "$BUILD/pipeline.log" ;;
  *)
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_MISS ${PP_OUTCOME#MISS } — planning fresh" >> "$BUILD/pipeline.log" ;;
esac
fi
printf '%s\n' "$PP_OUTCOME" > "$BUILD/preplan-outcome"
# <<< preplan adopt
# >>> preplan outcome event (BH-2543)
# ONE stage_events ROW PER NON-RESUMED BUILD, so GET /api/preplans/adoption
# counts each build's pre-plan outcome exactly once: HIT->ADOPTED, STALE, OFF,
# anything else MISS (the adopt block's own `*)` arm). A resumed dir already
# posted its row the first time through, so it posts nothing. It sits outside
# the adopt markers because tests/preplan-adopt.bh-776-test.sh holds that block
# to exactly one PREPLAN_ line per run. Every path is logged and the block ends
# in `true`: a hub that cannot take the row never changes the build's rc.
#
# A MISS/STALE/OFF build has no plan.md until PLAN finishes, so a build that
# died mid-PLAN is not PP_RESUMED on its next attempt and would post a second
# row. $BUILD/preplan-event is written only after a post succeeds, and a dir
# that carries it posts nothing again; a failed post leaves no marker, so the
# next attempt still tries (BH-2543.1).
if [ "$PP_RESUMED" != 1 ]; then
if [ -e "$BUILD/preplan-event" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_EVENT already recorded by an earlier attempt ($(head -1 "$BUILD/preplan-event" 2>/dev/null)) — not re-posted" >> "$BUILD/pipeline.log"
else
  case "$PP_OUTCOME" in HIT*) PP_EV=ADOPTED ;; STALE*) PP_EV=STALE ;; OFF*) PP_EV=OFF ;; *) PP_EV=MISS ;; esac
  case "$PP_OUTCOME" in *' '*) PP_EV_DETAIL=${PP_OUTCOME#* } ;; *) PP_EV_DETAIL="" ;; esac
  PP_EV_DETAIL=${PP_EV_DETAIL:0:400}
  if [ -z "${JOB_ID:-}" ] || ! command -v job_event >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_EVENT not recorded (no job row)" >> "$BUILD/pipeline.log"
  elif job_event "$JOB_ID" preplan "$PP_EV" "$PP_EV_DETAIL"; then
    printf '%s\n' "$PP_EV" > "$BUILD/preplan-event" 2>/dev/null
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_EVENT $PP_EV recorded" >> "$BUILD/pipeline.log"
  else
    PP_EV_RC=$?
    echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_EVENT not recorded (post failed rc=$PP_EV_RC)" >> "$BUILD/pipeline.log"
  fi
fi
fi
true
# <<< preplan outcome event (BH-2543)
# >>> build call fp
# THE BUILD'S CALL-GUARD FINGERPRINT (BH-2413). Every plan and execute prompt
# embeds this build's own $BUILD dir, so the guard's per-prompt fallback sees a
# new build of the same ticket as new work, and a ticket relaunched all day was
# re-planned all day. The build fp names the WORK instead: the ticket key, a
# hash of its title + body + thread, and the main sha the plan reads. CC()
# above hands it to plan, execute and fix.
#
# The thread is FP_BEFORE on an in-app board. On a GitHub-issue project
# (prefix "-") FP_BEFORE is always empty, so the thread is the issue's WHOLE
# comment thread projected to [id, updated_at]: a new comment adds an id, an
# edit moves a stamp. The endpoint is oldest first, so it is paged to its end,
# up to 1000 comments (BH-2485: one page never saw comment 101+). Past 1000
# there is no signal. Only rc 0 and an array on every page count; a rate limit
# (75) is no signal, not "no comments", and a partial thread is never signed.
# Any missing input is NO build fp, and those calls fall back to the per-build
# fingerprint: never an fp that could fold two pieces of work.
TICKET_THREAD_SIG() { # prints the thread signature, rc 1 when there is none
  local repo issue t rc page acc='[]' sig=""
  if [ -n "${FP_BEFORE:-}" ]; then printf '%s\n' "$FP_BEFORE"; return 0; fi
  [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ] || return 1
  repo=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  [ -n "$repo" ] && [ -n "$issue" ] && command -v gh_rest >/dev/null 2>&1 || return 1
  t=$(mktemp "${TMPDIR:-/tmp}/ticket-thread.XXXXXX") || return 1
  for page in 1 2 3 4 5 6 7 8 9 10; do
    rc=0; gh_rest GET "repos/$repo/issues/$issue/comments?per_page=100&page=$page" > "$t" || rc=$?
    { [ "$rc" = 0 ] && jq -e 'type == "array"' "$t" >/dev/null 2>&1; } || { rm -f "$t"; return 1; }
    acc=$(jq -sc '.[0] + .[1]' <(printf '%s\n' "$acc") "$t" 2>/dev/null) || { rm -f "$t"; return 1; }
    [ "$(jq 'length' "$t")" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$t"; return 1; }
  done
  rm -f "$t"
  sig=$(jq -ce '[.[] | [.id, .updated_at]]' <<<"$acc" 2>/dev/null)
  [ -n "$sig" ] || return 1
  printf '%s\n' "$sig"
}
BUILD_CALL_FP_COMPUTE() { # prints the build fp (rc 0) or why there is none (rc 1)
  local mat sig sha fp
  mat=$(jq -c '{title, body}' "$BUILD/ticket-meta.json" 2>/dev/null) && [ -n "$mat" ] \
    || { echo "no ticket-meta.json"; return 1; }
  sig=$(TICKET_THREAD_SIG) || { echo "no thread signal"; return 1; }
  sha=$(git -C "$WT" rev-parse --verify -q "origin/$BASE^{commit}" 2>/dev/null) \
    || { echo "origin/$BASE does not resolve"; return 1; }
  # Sourced in this command substitution's subshell: the guard lib's globals
  # never reach the pipeline.
  fp=$( . "$HARNESS/bin/lib/call-guard.sh" && printf '%s\n%s' "$mat" "$sig" | call_guard_build_fp "$KEY" "$sha" ) \
    && [ -n "$fp" ] || { echo "fingerprint inputs incomplete"; return 1; }
  printf '%s\n' "$fp"
}
# <<< build call fp
# >>> ticket fingerprint
# SDLC item 5: the snapshot OUTLIVES THE PROCESS. $BUILD/ticket-fp records the
# thread as it stood when THIS dir's plan was written, so the resume below can
# ask the question this gate could not ask before ("has the thread moved since
# the plan I am about to reuse was written?") instead of comparing against a
# fingerprint taken seconds ago in the same run. Read here, written in the
# fresh-plan branch — a REUSE never rewrites it.
FP_PLAN=$(cat "$BUILD/ticket-fp" 2>/dev/null)
# <<< ticket fingerprint
# >>> call fp reuse
# A resumed build keeps the build fp its plan was written under (the resume
# stale gate below already defers one whose thread moved). Rewritten, or
# removed, in the fresh-plan branch.
BUILD_CALL_FP=$(cat "$BUILD/call-fp" 2>/dev/null)
# <<< call fp reuse
# >>> context pack (BH-3478)
# A SPLIT CHILD PLANS FROM ITS PARENT'S MAP, on the child plan route
# (bin/lib/child-plan.sh). A ticket is a child only when a context_packs row
# exists for (project, key). The pack is kept in $BUILD, so a resume reuses it
# and the child plan tripwire below reads the same file instead of a second GET.
# This block sits OUTSIDE the checkpoint if/else on purpose: an adopted pre-plan
# or a resumed plan takes the `then` arm, and PLAN_MODEL must still be the child
# model for the plan-gate and size repairs and the PR body. Every path sets
# CP_PARENT and CP_PREAMBLE, so a value inherited from the environment cannot
# turn a non-child into a child. No token cap on the build plan. Fail-open: a
# non-child's prompt and model are exactly today's.
CP_WHY=""
# shellcheck source=bin/lib/context-pack.sh
[ -r "$HARNESS/bin/lib/context-pack.sh" ] && . "$HARNESS/bin/lib/context-pack.sh" 2>/dev/null
# shellcheck source=bin/lib/child-plan.sh
[ -r "$HARNESS/bin/lib/child-plan.sh" ] && . "$HARNESS/bin/lib/child-plan.sh" 2>/dev/null
if [ -s "$BUILD/context-pack.md" ] && [ -s "$BUILD/context-pack.md.parent" ]; then CP_RC=0
elif ! command -v cp_fetch >/dev/null 2>&1; then CP_RC=9; CP_WHY="no context-pack lib"
else JOBS_ALERT=0 cp_fetch "$PROJECT" "$KEY" "$BUILD/context-pack.md" >/dev/null 2>&1; CP_RC=$?
fi
case "$CP_RC" in 0|9) ;; 2) CP_WHY="no context pack" ;; *) CP_WHY="context pack unreachable" ;; esac
if [ "$CP_RC" = 0 ] && command -v cp_preamble >/dev/null 2>&1 \
   && CP_PREAMBLE="$(cp_preamble "$BUILD/context-pack.md")"$'\n\n' \
   && CP_PARENT=$(head -n1 "$BUILD/context-pack.md.parent" 2>/dev/null) && [ -n "$CP_PARENT" ]; then
  command -v child_plan_model >/dev/null 2>&1 \
    && CP_M=$(child_plan_model "$PROJECT" "$PLAN_MODEL") && [ -n "$CP_M" ] && PLAN_MODEL=$CP_M
  echo "$(STAMP) [$PROJECT/$KEY] CHILD_PLAN parent=$CP_PARENT model=$PLAN_MODEL" >> "$BUILD/pipeline.log"
else
  CP_PARENT=""; CP_PREAMBLE=""
  echo "$(STAMP) [$PROJECT/$KEY] CHILD_PLAN none (${CP_WHY:-unusable context pack})" >> "$BUILD/pipeline.log"
fi
# <<< context pack
# >>> plan thread gate (BH-5799)
# A REUSED OR ADOPTED PLAN MUST HAVE READ THE NEWEST COMMENTS. On a GitHub-issue
# project TICKET_FP is empty, so the resume stale gate below never compares a
# reused plan, or a pre-plan adopted above, with the thread. bin/lib/plan-thread.sh
# does: a comment by a person or our App that is newer than the plan and not
# cited by id in it refuses the plan. Refused here, plan.md is moved aside
# BEFORE the checkpoint, which then takes its fresh-plan arm in this same run,
# unless the build is a resume or its branch already carries a diff: then the
# run ends PLAN_STALE (exit 3), as rb_review's call site does.
# A refused hub pre-plan is removed like a PREPLAN_STALE one, so the next build
# does not adopt it again. An unreadable thread fails open with one line.
# shellcheck source=bin/lib/plan-thread.sh
[ -r "$HARNESS/bin/lib/plan-thread.sh" ] && . "$HARNESS/bin/lib/plan-thread.sh" 2>/dev/null
if [ -s "$BUILD/plan.md" ] && ! PLAN_IS_BLOCKED "$BUILD/plan.md" && command -v ptg_check >/dev/null 2>&1; then
  if PTG_SINCE=$(ptg_since "$BUILD"); then
    PTG_SRC=${PTG_SINCE#*$'\t'}; PTG_SINCE=${PTG_SINCE%%$'\t'*}
    [ "$PTG_SRC" = stamp ] || echo "$(STAMP) [$PROJECT/$KEY] plan-thread: $PTG_SRC ($PTG_SINCE)" >> "$BUILD/pipeline.log"
    PTG_OUT=$(ptg_check "$PROJECT" "$KEY" "$BUILD/plan.md" "$PTG_SINCE" "$BUILD/own-comments.sha256"); PTG_RC=$?
    PTG_DETAIL=${PTG_OUT#*$'\t'}
    case "$PTG_RC" in
      0) echo "$(STAMP) [$PROJECT/$KEY] plan-thread: ${PTG_OUT%%$'\t'*} $PTG_DETAIL (reused plan)" >> "$BUILD/pipeline.log" ;;
      1)
        PTG_IDS=$(ptg_ids "$PTG_DETAIL")
        if [ "$(ptg_enforce)" = 1 ]; then
          ptg_refuse_plan "$BUILD"
          case "$(head -1 "$BUILD/preplan-outcome" 2>/dev/null)" in
            HIT*)
              PP_OUTCOME="STALE uncited newer comment(s) $PTG_IDS"
              printf '%s\n' "$PP_OUTCOME" > "$BUILD/preplan-outcome"
              case "${PP_DIR:-}" in "$HARNESS/plans/"?*) rm -rf "$PP_DIR" ;; esac ;;
          esac
          # A RESUMED build re-entered its branch before rb_plan, and EXECUTE
          # skips a branch that carries commits (rb/execute.sh). Planning fresh
          # here would ship the first execute's diff under a plan that cites
          # the comment (lead review of e8a769a8). So a resume, or a branch that
          # already carries a diff over BASE (git diff exit 1, never an error),
          # ends PLAN_STALE like call site B in rb_review.
          if [ -n "${RESUME_BUILD:-}" ] || { git diff --quiet "${BASE:-main}"...HEAD >/dev/null 2>&1; [ "$?" = 1 ]; }; then
            echo "$(STAMP) [$PROJECT/$KEY] PLAN_THREAD_REFUSED (reused plan, resumed branch) $PTG_DETAIL — PLAN_STALE, the branch carries work planned without it" >> "$BUILD/pipeline.log"
            BB plan_stale "" "" "" false "uncited comment(s) newer than the plan: $PTG_IDS"
            RESULT "PLAN_STALE uncited comment(s) newer than the plan: $PTG_IDS — re-plan"; exit 3
          fi
          echo "$(STAMP) [$PROJECT/$KEY] PLAN_THREAD_REFUSED (reused plan) $PTG_DETAIL — planning fresh" >> "$BUILD/pipeline.log"
        else
          echo "$(STAMP) [$PROJECT/$KEY] PLAN_THREAD_WARN (reused plan) $PTG_DETAIL — PLAN_THREAD_GATE_ENFORCE=0, plan kept" >> "$BUILD/pipeline.log"
        fi ;;
      *) echo "$(STAMP) [$PROJECT/$KEY] plan-thread: $PTG_DETAIL — gate fails open" >> "$BUILD/pipeline.log" ;;
    esac
  else
    echo "$(STAMP) [$PROJECT/$KEY] plan-thread: no plan time — gate fails open" >> "$BUILD/pipeline.log"
  fi
fi
# <<< plan thread gate (BH-5799)

# BH-5910: the cross-repo-read lib. Sourced here, above the checkpoint, because
# the plan prompt asks for its note and the gate below the checkpoint runs on
# a fresh plan, a pre-plan and a resumed plan alike.
[ -r "$HARNESS/bin/lib/rb/cross-repo-read.sh" ] && . "$HARNESS/bin/lib/rb/cross-repo-read.sh" 2>/dev/null
# BH-6372.1: a perf/cost ticket's plan states a target and an outcome replay.
# pt_build_perf sets PT_BODY/PT_TITLE/PT_LABELS for the prompt and
# PLAN_GATE_PERF for the plan gate below. Above the checkpoint, so a reused
# plan is gated as a perf plan too.
[ -r "$HARNESS/bin/lib/perf-plan-rule.sh" ] && . "$HARNESS/bin/lib/perf-plan-rule.sh" 2>/dev/null
PLAN_GATE_PERF=0
if command -v pt_build_perf >/dev/null 2>&1; then
  pt_build_perf "$BUILD"
  [ "$PLAN_GATE_PERF" = 1 ] && echo "$(STAMP) [$PROJECT/$KEY] plan: perf ticket ($PT_EVIDENCE)" >> "$BUILD/pipeline.log"
fi
# Checkpoint: a valid non-BLOCKED plan from a prior attempt is reused verbatim
# (fresh dirs never have one, so the normal path is unchanged).
if [ -s "$BUILD/plan.md" ] && ! PLAN_IS_BLOCKED "$BUILD/plan.md"; then
  # >>> resume stale gate
  # The reused plan was written against the thread as it stood at ticket-fp.
  # A resume can be hours or days later — TK-143 #517 shipped against a comment
  # superseded ten minutes into planning, and a resume is that window widened.
  # Absence is never a mismatch: a record from before item 5 (no ticket-fp), a
  # boardless project and board API weather all fail OPEN, exactly as the
  # in-run gate below does.
  if [ -n "$FP_PLAN" ] && [ -n "$FP_BEFORE" ] && [ "$FP_PLAN" != "$FP_BEFORE" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] PLAN_STALE on resume: thread moved since the reused plan was written ($FP_PLAN -> $FP_BEFORE)" >> "$BUILD/pipeline.log"
    BB plan_stale "" "" "" false "thread moved since the reused plan was written — deferred for re-plan"
    RESULT "PLAN_STALE thread moved since the reused plan was written — re-run"; exit 3
  fi
  # <<< resume stale gate
  echo "$(STAMP) [$PROJECT/$KEY] PLAN checkpoint hit — reusing $BUILD/plan.md" >> "$BUILD/pipeline.log"
else
# CodeGraph freshness: cheap incremental sync so the planner's graph reflects HEAD.
command -v codegraph >/dev/null 2>&1 && [ -d "$REPO/.codegraph" ] && (cd "$REPO" && codegraph sync >/dev/null 2>&1 || true)
# >>> plan launch
# >>> plan malformed hold
# THE HOLD IS A GATE, NOT A LABEL (BH-657). PM_TERMINAL below writes `requeued`
# on a ticket's FIRST malformed plan and `held` on its second, and until now
# nothing read those rows BEFORE a plan was bought — so "held for a human" was a
# RESULT string and a ledger row, never a refusal. Every launcher funnels through
# these lines (the triage sweep's relaunch, an unscoped tick that still sees the
# handoff label, bin/blocked-resolver.sh's rebuild-fresh rung, a Fly machine
# running this same script), and each one paid for a full Fable plan that died at
# the same gate. harness-console HC-10 bought three of them 30 minutes apart on
# 2026-09-17 — the triage cadence, not the resolver's 90-minute floor, which is
# what proves the choke point is here rather than in one launcher.
#
# FAIL-OPEN, DELIBERATELY: only the literal statuses `held` and `skipped` hold a
# ticket. An unreadable file, a ledger outage, an empty or unrecognised status all
# launch, because a wrong hold costs a ticket that never ships and a wrong launch
# costs one plan session. And the hold has a documented way out — an operator
# appends a `released` row (last row wins) — or it would be a park nobody can
# leave.
PM_HOLD_STATUS() { # the ticket's last known plan-malformed status, or empty
  local pm_row pm_file="" pm_st="" pm_led pm_first=file
  pm_row=$(grep "^$PROJECT $KEY " "$HARNESS/state/plan-malformed.txt" 2>/dev/null | tail -1)
  [ -n "$pm_row" ] && pm_file=$(printf '%s\n' "$pm_row" | awk '{print $3}')
  # WHICH HALF IS THE RECORD. Off (today): the box's own file is its word and the
  # ledger answers only when the file has no row at all — a state dir that was
  # rebuilt, or a second malformed plan that ran on another machine. With the
  # no-twin-ledgers flag up (BH-1036) the order flips: the ROW is the record and
  # the file is the cache behind it, so a wiped state dir cannot un-hold a
  # ticket two malformed plans already parked. Either way rc 1 (outage) and rc 2
  # (no row) both mean "no status" and the other half is asked.
  type lt_on >/dev/null 2>&1 && lt_on && pm_first=row
  if [ "$pm_first" = file ] && [ -n "$pm_file" ]; then printf '%s' "$pm_file"; return 0; fi
  if type job_ledger_get >/dev/null 2>&1; then
    if pm_led=$(job_ledger_get plan_malformed "$PROJECT $KEY" 2>/dev/null); then
      pm_st=$(head -1 <<<"$pm_led" | awk '{print $1}')
    fi
  fi
  printf '%s' "${pm_st:-$pm_file}"
}
PM_STATUS=$(PM_HOLD_STATUS)
case "$PM_STATUS" in
  held|skipped)
    PM_ART=$(grep "^$PROJECT $KEY held " "$HARNESS/state/plan-malformed.txt" 2>/dev/null | tail -1 | awk '{print $5}')
    [ -n "$PM_ART" ] || PM_ART="no artifact recorded"
    echo "$(STAMP) [$PROJECT/$KEY] PLAN skipped: $KEY is held after 2 malformed plans — no plan session spent ($PM_ART)" >> "$BUILD/pipeline.log"
    # ONE ALERTS line per held ticket, and the ROW is what remembers it: the alert
    # rides the `held` -> `skipped` transition, so every later launch is log-only
    # no matter which box or machine it lands on. The file row is written before
    # the alert, so a ledger outage still records the transition on this box.
    if [ "$PM_STATUS" = held ]; then
      mkdir -p "$HARNESS/state"
      echo "$PROJECT $KEY skipped $(STAMP) $PM_ART" >> "$HARNESS/state/plan-malformed.txt"
      if type job_ledger_put >/dev/null 2>&1; then
        job_ledger_put plan_malformed "$PROJECT $KEY" skipped \
          "held after 2 malformed plans — launches are skipped before the planner" >/dev/null 2>&1 || true
      fi
      echo "$(STAMP) [$PROJECT/$KEY] PLAN_MALFORMED hold: $KEY already produced 2 malformed plans and is skipped before the planner from now on — no third plan session. Release: append '$PROJECT $KEY released <stamp>' to state/plan-malformed.txt and job_ledger_put plan_malformed '$PROJECT $KEY' released ($PM_ART)" >> "$ALERTS"
    fi
    BB plan_malformed "" "" "" false "held after 2 malformed plans — skipped before the planner, no plan session spent"
    # The RESULT keeps the PLAN_MALFORMED verb and the "held for a human" phrase on
    # purpose: every sweep SOP, the console's parked mapping and blocked-resolver
    # already have a rule for that shape, and this skip wants exactly that rule.
    RESULT "PLAN_MALFORMED held for a human: $KEY already produced 2 malformed plans — skipped before the planner, no plan session spent ($PM_ART)"
    exit 4
    ;;
esac
# <<< plan malformed hold
echo "$(STAMP) [$PROJECT/$KEY] PLAN ($PLAN_MODEL)" >> "$BUILD/pipeline.log"
BB planning
# >>> ticket fingerprint write
# Written on EVERY re-plan, next to the planner it describes: a build that died
# mid-PLAN and got resumed writes a NEW plan against the CURRENT thread, and a
# snapshot left over from the dead attempt would fail the next resume as stale
# against a thread that never moved. No fingerprint now (boardless project,
# board outage) means no snapshot — absence fails open below, a stale file does not.
if [ -n "$FP_BEFORE" ]; then printf '%s\n' "$FP_BEFORE" > "$BUILD/ticket-fp"; else rm -f "$BUILD/ticket-fp"; fi
# <<< ticket fingerprint write
# >>> call fp write
if BCF_OUT=$(BUILD_CALL_FP_COMPUTE); then
  BUILD_CALL_FP=$BCF_OUT
  printf '%s\n' "$BUILD_CALL_FP" > "$BUILD/call-fp"
else
  BUILD_CALL_FP=""
  rm -f "$BUILD/call-fp"
  echo "$(STAMP) [$PROJECT/$KEY] no stable call fp ($BCF_OUT) — plan/execute/fix use the per-build fingerprint" >> "$BUILD/pipeline.log"
fi
# <<< call fp write
# >>> plan prompt (tests/run-build-test-home.bh-580-test.sh drives this block)
# The naming rule rides in FRONT of the plan instructions, not inside them: the
# planner has to know where this ticket's test cases go before it writes a
# files-to-touch list. Empty on a box with no lib, so that box's prompt is
# byte-identically today's. The untrusted-input rule (BH-4491) and, under warn,
# the flagged spans ride directly in front of PLAN ONLY, by the same rule.
# BH-5799: the time this plan starts reading the thread, for the plan thread
# gate. Written before the session, so a comment the planner could have read is
# never newer than the stamp. A box without the lib writes none.
if command -v ptg_stamp >/dev/null 2>&1; then ptg_stamp "$BUILD/plan-thread-at"; else rm -f "$BUILD/plan-thread-at"; fi
# BH-5802: work already on main. The note asks the planner to search the base
# since the ticket was filed (by key, files and symbols) and to park the plan
# with `BLOCKED: already done on main by <sha>` when the work is done.
[ -r "$HARNESS/bin/lib/dup-main.sh" ] && . "$HARNESS/bin/lib/dup-main.sh" 2>/dev/null
# BH-5800: the failure-mode checklist, rendered from catalog/plan-failure-modes.tsv
# into the prompt below and into the plan-gate repair pass.
[ -r "$HARNESS/bin/lib/plan-failure-modes.sh" ] && . "$HARNESS/bin/lib/plan-failure-modes.sh" 2>/dev/null
# BH-6299: files to touch are edits only; run-only paths go under ## Verify.
[ -r "$HARNESS/bin/lib/verify-list.sh" ] && . "$HARNESS/bin/lib/verify-list.sh" 2>/dev/null
CC_ARTIFACT_KIND=plan_file CC_ARTIFACT_FILE="$BUILD/plan.md" \
CC plan "$PLAN_MODEL" 1200 "$BUILD/plan-run.txt" "${CP_PREAMBLE:-}$(command -v th_plan_rule >/dev/null 2>&1 && th_plan_rule "$KEY")$(command -v th_fragment_rule >/dev/null 2>&1 && th_fragment_rule "$KEY" .)$(command -v ui_notice >/dev/null 2>&1 && printf '%s ' "$(ui_notice)")${UI_PLAN_NOTE:-}PLAN ONLY - do not modify any files except writing the plan. Read ticket $KEY (id $TICKET) on this project's product board (access method in /root/harness/prompts/$PROJECT.md), including its FULL comment thread. THREAD RECENCY IS LAW: anchor the mechanism on the NEWEST comments — a later comment that narrows, reverses, or manualizes an earlier confirmation VOIDS the earlier one (TK-143 #517 shipped a code lane 10 minutes after the board promised the client manual data entry, because the plan anchored on a stale comment). If the thread's LATEST state says the work is manual/data-entry, on hold, or awaiting an answer, that is BLOCKED-NEEDS-CLARIFICATION, not a build. SPEC CHANGES FROM COMMENTS: read the ticket's comment thread NEWEST FIRST. plan.md MUST carry a '## Spec changes from comments' section with one line per comment that changes scope (a new or removed column or field, a cadence, 'do not merge', an input folded in, a narrowed or reversed body item). Start each line with the comment's id (the number after #issuecomment- on a GitHub issue), then the author, then what changed and which task delivers it. If no comment changes scope, write the single line 'none'. A comment by the operator or the triage that is newer than this plan and not cited by id in plan.md makes the pipeline refuse the plan before review. If /root/harness/state/$PROJECT-context.md exists, read it FIRST — it is the project primer (architecture, conventions, reference implementations, cross-repo pointers) written by an understand-pass; trust it for orientation, verify specifics in code. Read the relevant code in this repo. $(command -v dup_main_plan_note >/dev/null 2>&1 && dup_main_plan_note . "origin/${BASE:-main}" "$KEY" "${ISSUE_CREATED_AT:-}")$(command -v xrepo_plan_note >/dev/null 2>&1 && xrepo_plan_note)CODEGRAPH: the line at the TOP of this prompt already says whether the graph is available and gives the EXACT command — do not probe for a .codegraph/ directory (in this worktree that directory exists and is EMPTY; a bare codegraph command here finds nothing). If it says AVAILABLE the graph pass is MANDATORY, not optional: your FIRST code step is that command, and a plan that never consulted the graph is incomplete. Identify the change's file set through the graph BEFORE reading files — explore returns the relevant symbols' source plus call paths (including dynamic-dispatch hops grep misses) and query finds symbols; derive the plan's 'files to touch' and regression-risk lists from graph evidence (callers, dependents), CITE that evidence in the plan (which callers/dependents made each file a risk), then read those files to confirm. ACTIVE FILE CLAIMS: list /root/harness/state/claims/$PROJECT/ — each file there names a SIBLING build running right now and the repo files it is editing (cat them). Design this plan to avoid those files where a reasonable seam exists (different module, additive new file, adjacent component); if overlap is genuinely unavoidable, keep it and say so — a build whose planned files overlap a live sibling's is DEFERRED to a later tick and re-planned from scratch (the pipeline no longer waits for the sibling), so avoidance is what keeps this ticket moving. Write every note about a sibling claim's files ONLY under a '## Sibling claims (not touched)' heading, which bin/planned-files.sh skips when it builds this build's own claim — a sibling's path named anywhere else in plan.md becomes YOUR claim and defers this build; never list a file you will edit in that section. If the line says NOT AVAILABLE, skip this and proceed with your usual tools. Write a precise implementation plan to $BUILD/plan.md: scope, files to touch, edge cases, how the iron laws in ~/.claude/CLAUDE.md apply (sortable headers, list-over-cards, drill-down, DB-driven config, RLS, indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table, De-AI, and — if the change calls any metered/billable API — dedup-before-spend: a persisted 'already paid for this?' check BEFORE the call, 'succeeded but empty' treated as billed+terminal, ledger keyed on a stable input fingerprint not a tokenized URL), and a verification checklist. PERFORMANCE BY DEFAULT (BH-6946): a plan for a screen or loader lists its reads, which of them run in parallel, the expected statement count, the indexes they use, and the loading skeleton. PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). A follow-up ticket is filed only for a core-flow defect a user would notice (review.followup_min_level, BH-7123); smoke-level findings stay as [NOTE] lines in the review, and a ticket that is itself a follow-up files no follow-ups. Read /root/harness/prompts/build-discipline.md and design the plan so the build cannot violate it (name which rules bite this ticket). $(command -v pfm_plan_rule >/dev/null 2>&1 && pfm_plan_rule)$(command -v pt_plan_rule >/dev/null 2>&1 && pt_plan_rule "$PT_BODY" "$PT_TITLE" "$PT_LABELS")$(command -v vl_plan_rule >/dev/null 2>&1 && vl_plan_rule)EVERY TASK IN THE PLAN CARRIES TWO LINES, no exceptions: 'VALIDATE: <the exact command, or the exact observable check, that proves this task is done>' (a real runnable thing — 'npm test -- path/to/file.test.ts', 'curl -s <route> | grep <field>', 'load <route> at 375px and confirm no horizontal scroll' — never 'verify it works') and 'SATISFIES: <the ticket acceptance criterion or client sentence this task exists to deliver>' (quote or name it; if a task satisfies nothing the client asked for, delete the task — that is scope creep, and the plan is where it gets caught). A plan whose tasks cannot each name their criterion is not a plan, it is a wish list. The plan MUST end with FIVE sections. '## System invariants' — for SIZE M/L/XL, the feature-level decisions no single task owns, decided HERE not by the builder: (a) any cross-run state names its store and defends it (a real table with a natural unique key for anything that dedups/watermarks/claims — config-JSON only for operator knobs, never pruned against a capped query); (b) failure-vs-success semantics for EVERY external side effect (what is recorded on success / failure / not-configured, and the write-vs-send ordering — 'stamped done without delivery' must be impossible by construction); (c) an adversarial negative list for any classifier/matcher gating an irreversible or client-visible action (realistic inputs that must NOT trigger, which the tests must include); (d) neighbor interactions — the caps, cron lanes, locks, schedulers, and sibling agents this change's queries or registry entries touch, each with a spec clause or a written non-interaction argument. For SIZE S write 'None beyond the iron laws' plus one sentence of why. '## Requirements coverage' — a REVERSE matrix over the ticket: every distinct requirement in the ticket/thread (including NEGATIVE ones — 'stop doing X', 'no more Y to channel Z' get a row naming the task that REMOVES the behavior and the test that pins its absence) mapped to the task and acceptance test that deliver it; a requirement with no row is a plan defect — SATISFIES lines prove tasks trace to requirements, this matrix proves requirements trace to tasks, and both directions are required. Then '## Acceptance tests' — the ticket's acceptance criteria written as CONCRETE test cases (test file path + what each asserts, in the repo's test framework per the Verification Contract in its CLAUDE.md; if the repo has no test framework, say so and give a manual verification script instead) — and '## QA screens' — the app routes/screens a browser QA pass should exercise, with the primary user flow per screen. Also name which existing test suites are at regression risk. Then '## Size', and it is REQUIRED and MECHANICALLY CHECKED — a plan without it is sized by a coarse estimate from every file it mentions, which errs large. Three lines, exactly these keys: 'FILES: <n>' (how many files this change touches), 'LINES: <n>' (your honest estimate of lines added plus deleted) and 'DIFF_KB: <n>' (your estimate of the WHOLE diff in kilobytes, tests, docs, fixtures and generated files included). The lead review reads at most LEAD_REVIEW_DIFF_MAX_BYTES of a diff (400 KB by default). A plan over that is split, the same as a plan over the line limit. For FILES and LINES, COUNT PRODUCT CODE ONLY: do NOT count test files, docs or markdown, the plan or spec itself, lockfiles, generated code or Prisma migration snapshots (`bin/size-scope.sh --rules` prints the exact list the gate applies). 250 lines of source with 400 lines of tests is 'LINES: 250'. Size the work, not the paperwork, and do not shade the number down to avoid a split: over the threshold this ticket is SPLIT into small children that each ship on their own, which is a better outcome for the client than one PR nobody can review, and the file count you DECLARE is what the gate judges (paths you merely mention as callers or out-of-scope are not counted), while the shipped diff is compared with your declaration after the build and an under-declared plan is flagged SIZE_DECLARATION_EXCEEDED on its PR. $PLAN_AMBIGUITY_RULE KIND, on the line immediately BEFORE the SIZE line: 'KIND: bug', 'KIND: feature', 'KIND: copy', 'KIND: migration' or 'KIND: infra' — what kind of work this ticket is, because the pipeline routes on it (a bug is proven by a reproduction, not by a feature test; a copy change buys no browser smoke).${REPLAN_LINE:-} ${REVERT_REASON_LINE:-}${REOPEN_REASON_LINE:-}$KIND_HINT_LINE$CARRIED_NOTE_LINE${REPRO_BRIEF_LINE:-} IF KIND IS BUG, the plan MUST also carry a '## Reproduction' section, and it is the most important section in the file: 'REPRO: <the exact command or test that FAILS against the code as it stands today>' (a real runnable thing a shell can run — the executor turns this into red.txt and bin/repro-gate.sh checks it against the merge base), 'OBSERVED: <what it does now>', 'EXPECTED: <what it should do>', 'ROOT CAUSE: <file:line>' (a real path and line number you found by READING the code — the place the defect lives, never the call site where the symptom showed; a fail-closed 404 or an auth-gated route is not missing code, so check git log and the auth design before you call something absent — TK-44), and 'BLAST RADIUS: <the callers and dependents that share this code path>' from the graph. Write those five as their own colon-anchored lines and NOT as VALIDATE:/SATISFIES: lines — a reproduction is evidence about the defect, not a task that delivers a criterion. If you cannot write a REPRO that fails today, say so in the section and treat that as the finding: five pre-existing failures were once blamed on a PR that did not cause them (TK-113), and 'prove innocence on main' is the first step of a bug, not the last. PLAN ECONOMY: a small ticket deserves a small plan — for copy/docs/small-UI scope, a dozen lines plus the two required sections is correct and padding wastes build time; spend planning depth only where regression risk is real. The VERY LAST line of plan.md must be 'SIZE: S', 'SIZE: M', 'SIZE: L' or 'SIZE: XL' — your honest estimate of build effort. This T-shirt line is SEPARATE from the numeric '## Size' section: that section is what the size gate measures against this project's threshold, this line is the coarse effort call the rest of the prompt routes on. XL means it cannot fit one ~1-hour build session OR it bundles multiple independent workstreams; size honestly, an XL plan gets split into parallel child tickets instead of built whole. IF THIS PLAN BUILDS ONLY ONE SLICE of the ticket and leaves the rest to child tickets, write the line 'SLICE: C<n> of #$TICKET' on its own line in plan.md (C0 for the first slice): the merge close-out reads that exact line to leave this ticket open and take ai-build off it."
# <<< plan prompt
# <<< plan launch
# An EMPTY plan is a model/session failure (limits, auth, crash) — retryable
# infrastructure weather, NOT a product block. A plan is a product block only
# when its FIRST LINE OPENS with the parked marker (PLAN_IS_BLOCKED above) — a
# title that merely mentions the word is a plan like any other. (2026-07-31: an
# project-3 Fable-limit hit produced an empty plan that got mislabeled PLAN_BLOCKED.
# BH-387: the unanchored match refused four complete plans on their titles.)
# >>> plan empty-output verdict
# WHY THE STAGE'S OWN VERDICT WINS (BH-642). "produced no output" is true of a
# model that ran and said nothing, and equally true of a ladder that burned
# because every account was out of credits — and telling those apart used to
# mean reading failovers.log by hand. bin/agent-call.sh now leaves its verdict
# beside the outfile as <outfile>.class (RUNNER_EXHAUSTED / RUNNER_RATE_LIMITED
# / RUNNER_ERROR plus the classes it saw), so when there is one it is what gets
# reported. With no sidecar the original sentence is rendered unchanged, because
# that state still happens and the sentence is still true in it.
if [ ! -s "$BUILD/plan.md" ]; then
  WHY_BB="plan session produced no output (model limit/failure?)"
  WHY_RESULT="plan session produced no output"
  # A call-guard refusal (BH-2305) ran no session and wrote no .class; say so.
  WHY_CG=$(head -1 "$BUILD/plan-run.txt" 2>/dev/null)
  case "$WHY_CG" in
    "AGENT_CALL_REFUSED call-guard "*)
      WHY_BB="plan refused by the call-guard before the call: $(head -c 300 <<<"$WHY_CG")"
      WHY_RESULT="$WHY_BB" ;;
  esac
  if [ -s "$BUILD/plan-run.txt.class" ]; then
    WHY_BB="plan session ended $(head -1 "$BUILD/plan-run.txt.class" | head -c 1000 | tr -d '\n')"
    WHY_RESULT="$WHY_BB"
  fi
  BB plan_deferred "" "" "" false "$WHY_BB"
  RESULT "BUILD_DEFERRED $WHY_RESULT"; exit 3
fi
# <<< plan empty-output verdict
# >>> plan blocked gate
if PLAN_IS_BLOCKED "$BUILD/plan.md"; then
  BB plan_blocked "" "" "" false "$(head -c 1200 "$BUILD/plan.md" 2>/dev/null)"
  RESULT "PLAN_BLOCKED $BUILD/plan.md"; exit 4
fi
# <<< plan blocked gate

# Thread-stability re-check (see GATE above): the thread moving during PLAN
# means the plan may be anchored on a comment that is no longer the latest
# turn — the TK-143 #517 failure exactly. Defer like the other retryable
# paths; the next triage pass re-reads the thread and re-plans from current
# state. A failed re-fetch fails open (one plan built on a snapshot beats
# blocking every build on board API weather). Runs BEFORE the plan gate below
# so a stale plan defers without spending a repair session on it.
if [ -n "$FP_BEFORE" ]; then
  FP_AFTER=$(TICKET_FP)
  if [ -z "$FP_AFTER" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] stale-check: post-PLAN re-fetch failed — gate fails open" >> "$BUILD/pipeline.log"
  elif [ "$FP_AFTER" != "$FP_BEFORE" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] PLAN_STALE: thread moved during planning ($FP_BEFORE -> $FP_AFTER)" >> "$BUILD/pipeline.log"
    BB plan_stale "" "" "" false "thread moved during planning — deferred for re-plan"
    RESULT "PLAN_STALE thread moved during planning — re-run"; exit 3
  fi
fi

fi  # end PLAN checkpoint

# >>> cross-repo-read gate (BH-5910)
# A plan that declares `CROSS-REPO-READ: <owner>/<repo>` for a repo every token
# of this build answers 404 on stops HERE, not after an execute that ends with an
# empty diff. bin/lib/rb/cross-repo-read.sh owns the parse and the probe; an
# unknown probe is one pipeline.log line and never blocks. Absent lib: no gate.
# IT RUNS OUTSIDE THE PLAN CHECKPOINT, like the plan gate below: a pre-plan HIT
# and a resumed build both reuse a plan.md, and both must meet this check too.
# The lib is sourced above the checkpoint, so the plan prompt has its note.
if command -v xrepo_gate >/dev/null 2>&1; then
  XR_OWN=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || XR_OWN=""
  case "$XR_OWN" in
    */*) ;;
    *) XR_OWN=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#^.*github\.com[:/]##; s#\.git$##') ;;
  esac
  XR_MISS=$(xrepo_gate "$BUILD/plan.md" "$XR_OWN" "$BUILD/pipeline.log"); XR_RC=$?
  if [ "$XR_RC" = 4 ] && [ -n "$XR_MISS" ]; then
    # The reason is written into plan.md and ALERTS BEFORE the RESULT: a
    # PLAN_BLOCKED never exists without the line that says why.
    { printf 'BLOCKED: cross-repo-read %s — this build'"'"'s GitHub tokens cannot read %s. Set lane.fly-pool.%s.extra_read_repos to include it, or add a '"'"'Spec-repo: %s'"'"' line to the ticket body, and install the builders App on it, then re-run.\n\n' \
        "$XR_MISS" "$XR_MISS" "$PROJECT" "$XR_MISS"
      cat "$BUILD/plan.md"; } > "$BUILD/plan.md.xr" && mv "$BUILD/plan.md.xr" "$BUILD/plan.md"
    echo "$(STAMP) [$PROJECT/$KEY] PLAN_BLOCKED cross-repo-read $XR_MISS: the plan reads $XR_MISS and no GitHub token of this build can (404 on every token). Set lane.fly-pool.$PROJECT.extra_read_repos to include $XR_MISS, or add a 'Spec-repo: $XR_MISS' line to the ticket body, and install the builders App on it, then re-run $KEY." >> "$ALERTS"
    BB plan_blocked "" "" "" false "$(head -c 1200 "$BUILD/plan.md" 2>/dev/null)"
    RESULT "PLAN_BLOCKED cross-repo-read $XR_MISS $BUILD/plan.md"; exit 4
  fi
fi
# <<< cross-repo-read gate

# >>> plan gate
# --- Plan gate: every TASK carries its proof and its trace (SDLC item 5) -----
# The 2026-08-14 template check asked whether the file contained a VALIDATE line
# and a SATISFIES line ANYWHERE. One traced task in a ten-task plan passed it,
# and a plan that failed it got one repair pass and then went to EXECUTE anyway
# with a logged warning — so the executor and a paid reviewer both worked from a
# plan nobody could trace back to the ticket. bin/plan-gate.sh scores each task
# block (and owns the whole-file floor, whose old regex missed the `- VALIDATE:`
# bullet form most plans actually use), and this refuses.
#
# IT RUNS OUTSIDE THE CHECKPOINT, on the reused plan too: a resumed build was
# the one path that skipped the check entirely, and an untraced plan does not
# become traced by being resumed.
#
# REFUSES, and that is deliberate where every other new gate warns first. The
# SDLC review named this one "the plan gate that refuses": the cost of being
# wrong here is one re-plan, where the cost of proceeding is a whole execute +
# review wave against a plan with no acceptance trace. Measured before arming —
# of the 637 plans on this box, every plan written since the contract shipped on
# 2026-08-14 passes, and every refusal is a plan that predates it.
#   PLAN_GATE_ENFORCE=1  shipped default: a still-untraced plan ends in
#                        PLAN_MALFORMED instead of a log line.
#   PLAN_GATE_ENFORCE=0  the kill switch — back to the logged warning, build
#                        continues. Set it in env/global.env, not fleet.conf.
#   PLAN_GATE_MAX_LIST=8 how many offenders bin/plan-gate.sh names (its own).
# PLAN_GATE_PERF: 1 when pt_build_perf classified the ticket perf/cost (§16).
# PLAN_GATE_HOTSPOTS: the hotlist the render above wrote (absent = unread).
# The gate reports a hotspot the plan names outside `## Shared files`; it never
# changes PG_RC (plan-contract §11).
PG_RUN() { PLAN_GATE_PERF="${PLAN_GATE_PERF:-0}" PLAN_GATE_HOTSPOTS="$BUILD/hotspots.txt" PLAN_GATE_TICKET="$BUILD/ticket-meta.json" "$HARNESS/bin/plan-gate.sh" "$BUILD/plan.md" > "$BUILD/plan-gate.txt" 2>&1; }
PG_RUN; PG_RC=$?
if [ "$PG_RC" = 2 ]; then
  # ONE repair pass, exactly as before — the plan's substance is usually fine
  # and it is the proof-and-trace scaffolding that is missing. What is new is
  # that the repair prompt is TOLD WHICH blocks failed, and that a second
  # failure is a terminal rather than a warning.
  case "${PLAN_GATE_MAX_LIST:-}" in ''|*[!0-9]*) PG_MAX=8 ;; *) PG_MAX=$PLAN_GATE_MAX_LIST ;; esac
  PG_LIST=$(sed -n 's/^  UNTRACED: //p' "$BUILD/plan-gate.txt" | head -n "$PG_MAX" | tr '\n' ';' | sed 's/;$//')
  echo "$(STAMP) [$PROJECT/$KEY] plan gate: untraced tasks — one repair pass ($PG_LIST)" >> "$BUILD/pipeline.log"
  CC plan "$PLAN_MODEL" 600 "$BUILD/plan-repair-run.txt" "Repair the plan at $BUILD/plan.md IN PLACE (rewrite the file; change nothing about its scope, approach or size line). EVERY task must carry BOTH lines, each on its own line: 'VALIDATE: <the exact command or observable check that proves this task is done>' and 'SATISFIES: <the ticket acceptance criterion it delivers>'. These task blocks are missing one of them right now: $PG_LIST. If a task satisfies nothing the ticket asked for, delete it. Keep the '## Acceptance tests' and '## QA screens' sections, the final SIZE line and any 'SLICE:' line exactly as they are.$(command -v pfm_repair_note >/dev/null 2>&1 && pfm_repair_note "$BUILD/plan-gate.txt")$(command -v pt_repair_note >/dev/null 2>&1 && pt_repair_note "$BUILD/plan-gate.txt")$(command -v st_repair_note >/dev/null 2>&1 && st_repair_note "$BUILD/plan-gate.txt")"
  PG_RUN; PG_RC=$?
  [ "$PG_RC" = 2 ] || echo "$(STAMP) [$PROJECT/$KEY] plan gate: repaired, every task now carries both lines" >> "$BUILD/pipeline.log"
fi
PG_VERDICT=$(sed -n 's/^PLAN_TRACE:[[:space:]]*//p' "$BUILD/plan-gate.txt" 2>/dev/null | tail -1)
[ -n "$PG_VERDICT" ] || PG_VERDICT=not-recorded
PG_SHARED=$(sed -n 's/^PLAN_SHARED:[[:space:]]*//p' "$BUILD/plan-gate.txt" 2>/dev/null | tail -1)
echo "$(STAMP) [$PROJECT/$KEY] plan gate: shared files ${PG_SHARED:-off} (unlisted=$(grep -c '^  SHARED_UNLISTED: ' "$BUILD/plan-gate.txt" 2>/dev/null), noreason=$(grep -c '^  SHARED_NOREASON: ' "$BUILD/plan-gate.txt" 2>/dev/null))" >> "$BUILD/pipeline.log"
PG_TASKS=$(sed -n 's/^PLAN_TASKS:[[:space:]]*//p' "$BUILD/plan-gate.txt" 2>/dev/null | tail -1)
PG_UNTRACED=$(sed -n 's/^PLAN_UNTRACED:[[:space:]]*//p' "$BUILD/plan-gate.txt" 2>/dev/null | tail -1)
case "${PG_TASKS:-}"    in ''|*[!0-9]*) PG_TASKS=0 ;; esac
case "${PG_UNTRACED:-}" in ''|*[!0-9]*) PG_UNTRACED=0 ;; esac
# THE LEDGER LEARNS THIS EVEN WHEN NOTHING IS WRONG. A PLAN_MALFORMED build
# never reaches the verdict artifact (it stops here, before the PR), so plan
# time is the only time this fact exists — and a row written only on failure
# would make "no row" mean both "clean" and "old box". Fail-open like every
# other ledger write in this pipeline; $BUILD/plan-gate.txt is the fallback.
if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  job_artifact_put plan_gate "$PG_VERDICT" \
    "$(jq -nc --arg v "$PG_VERDICT" --argjson t "$PG_TASKS" --argjson u "$PG_UNTRACED" \
        --arg r "$(sed -n 's/^  UNTRACED: //p' "$BUILD/plan-gate.txt" | head -4 | tr '\n' ';' | cut -c1-600)" \
        '{verdict:$v,tasks:$t,untraced:$u} + (if $r == "" then {} else {detail:$r} end)' 2>/dev/null)" \
    >/dev/null 2>&1 || true
fi
case "$(printf '%s' "${PLAN_GATE_ENFORCE:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|no|off) PG_ENFORCE=0 ;;
  1|''|true|yes|on) PG_ENFORCE=1 ;;
  *) PG_ENFORCE=1
     echo "$(STAMP) [$PROJECT/$KEY] PLAN_GATE_ENFORCE='${PLAN_GATE_ENFORCE:-}' is not a recognized on/off value — treating as ON (the gate refuses)" >> "$ALERTS" ;;
esac
# >>> plan malformed terminal
# REQUEUED ONCE, THEN A HUMAN. The count is per TICKET and lives in the D1
# ledger (kind plan_malformed) with state/plan-malformed.txt as the offline
# fallback, because the requeue is a NEW BUILD in a new dir — a marker in this
# build dir could never be read by the attempt that needs it. It is
# deliberately never cleared: a ticket whose planner produced two untraced
# plans in its life is a ticket that needs reading, not a third session.
#
# A FUNCTION since 2026-09-12, because TWO gates end here now: the trace gate
# above, and the size gate below. An unsized plan and an untraced plan are the
# same class of defect — a spec the pipeline cannot check — and two copies of
# "requeue once, then hold" would drift apart the first time one of them was
# fixed. One ledger, one vocabulary, one terminal. The held terminal is not a
# request for a person: bin/blocked-resolver.sh drains PLAN_MALFORMED rows the
# same way it drains every other park, with a fresh build against current main.
PM_TERMINAL() { # PM_TERMINAL <why> <artifact> <what-the-planner-cannot-do>
  local pm_why="$1" pm_art="$2" pm_cannot="$3" pm_seen=0 pm_status
  grep -q "^$PROJECT $KEY " "$HARNESS/state/plan-malformed.txt" 2>/dev/null && pm_seen=1
  if [ "$pm_seen" = 0 ] && type job_ledger_get >/dev/null 2>&1; then
    job_ledger_get plan_malformed "$PROJECT $KEY" >/dev/null 2>&1 && pm_seen=1
  fi
  if [ "$pm_seen" = 0 ]; then pm_status=requeued; else pm_status=held; fi
  mkdir -p "$HARNESS/state"
  # FIVE fields since BH-657: the ARTIFACT rides on the row, so the pre-plan hold
  # guard above can name what the planner failed at ($BUILD/size-gate.txt,
  # $BUILD/plan-gate.txt) without opening build dirs that may already be pruned.
  # Readers key on the `^$PROJECT $KEY ` prefix and field 3, so rows written
  # before this (four fields) still read exactly as they did.
  echo "$PROJECT $KEY $pm_status $(STAMP) $pm_art" >> "$HARNESS/state/plan-malformed.txt"
  if type job_ledger_put >/dev/null 2>&1; then
    job_ledger_put plan_malformed "$PROJECT $KEY" "$pm_status" "$pm_why" >/dev/null 2>&1 || true
  fi
  echo "$(STAMP) [$PROJECT/$KEY] PLAN_MALFORMED: $pm_why ($pm_status)" >> "$BUILD/pipeline.log"
  BB plan_malformed "" "" "" false "$(head -c 600 "$pm_art" 2>/dev/null)"
  if [ "$pm_status" = requeued ]; then
    RESULT "PLAN_MALFORMED $pm_why — requeued once, the sweep relaunches it ($pm_art)"
    exit 3
  fi
  echo "$(STAMP) [$PROJECT/$KEY] PLAN_MALFORMED twice on $KEY (2 of 2 malformed plans — every later launch of $KEY is skipped before the planner) — the planner cannot $pm_cannot; handed to bin/blocked-resolver.sh for a fresh build against current main ($pm_art)" >> "$ALERTS"
  RESULT "PLAN_MALFORMED $pm_why — held here, handed to the blocked-resolver; this ticket already re-planned once ($pm_art)"
  exit 4
}
# <<< plan malformed terminal
if [ "$PG_RC" = 2 ] && [ "$PG_ENFORCE" = 1 ]; then
  PG_WHY="$PG_UNTRACED of $PG_TASKS task(s) still untraced after one repair pass"
  [ "$PG_TASKS" = 0 ] && PG_WHY="the plan carries no VALIDATE/SATISFIES lines at all, after one repair pass"
  grep -q '^PLAN_SPEC_TRACE: missing$' "$BUILD/plan-gate.txt" 2>/dev/null \
    && PG_WHY="${PG_WHY}; the spec trace is still missing ($(grep -c '^  UNTRACED: spec trace' "$BUILD/plan-gate.txt") gap(s))"
  PM_TERMINAL "$PG_WHY" "$BUILD/plan-gate.txt" "produce a traced plan"
fi
[ "$PG_RC" = 2 ] && echo "$(STAMP) [$PROJECT/$KEY] plan gate: $PG_UNTRACED untraced task(s) — PLAN_GATE_ENFORCE=0, executor gets an untraced plan" >> "$BUILD/pipeline.log"
# <<< plan gate
# >>> design collisions (BH-5791)
# --- A PLAN THAT CHANGES WHAT ANOTHER TICKET CHANGED SAYS HOW THE TWO COMBINE --
# #4332 and #5163 both rewrote flag_active and flag_set, and review found it
# after both were built. bin/plan-collisions.sh reads the plan's
# `## Changed symbols` and asks git which commits touched each one since the
# plan's base, on main and in every open PR. The note it gives goes into
# plan.md as `## Design collision check (BH-5791)`.
#
# OUTSIDE THE CHECKPOINT, like the plan gate above: an adopted pre-plan and a
# resumed plan are checked too. The base is the one an earlier run of this
# build used ($BUILD/collision-base), else the pre-plan's base-sha, else the
# merge base, so a resume checks the same window.
#
# A LISTED symbol that collides needs a `combine` or `needs-human` line under
# `## Design collisions`. With none, ONE repair pass ($BUILD/collision-repair-done
# is written BEFORE the call, so a resume never pays twice), then PLAN_BLOCKED
# with the questions at the top of plan.md, as the plan blocked gate parks it.
# Derived symbols (no `## Changed symbols` section), an unread main and an
# unread PR list never refuse. PLAN_COLLISION_ENFORCE=0 is the kill switch.
# Formats: docs/notes/2026-10-10-BH-5791-design-collisions.md.
PC_VERDICT=could-not-run; PC_HITS=0; PC_RESOLVED=0; PC_UNRES=""; PC_NH=""
# shellcheck source=bin/lib/plan-collisions.sh
command -v pc_note >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/plan-collisions.sh" ] && . "$HARNESS/bin/lib/plan-collisions.sh" 2>/dev/null; }
if ! command -v pc_note >/dev/null 2>&1 || [ ! -x "$HARNESS/bin/plan-collisions.sh" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] design collisions: lib missing on $(hostname) — not checked verdict=could-not-run" >> "$BUILD/pipeline.log"
else
  pc_conf "$PROJECT"
  [ -z "$PC_CONF_WARN" ] || echo "$(STAMP) [$PROJECT/$KEY] $PC_CONF_WARN" >> "$ALERTS"
  PC_BASE=$(head -1 "$BUILD/collision-base" 2>/dev/null)
  if [ -z "$PC_BASE" ]; then
    case "${PP_OUTCOME:-}" in HIT*) [ -n "${PP_DIR:-}" ] && PC_BASE=$(head -1 "$PP_DIR/base-sha" 2>/dev/null) ;; esac
    [ -n "$PC_BASE" ] || PC_BASE=$(git merge-base HEAD "origin/$BASE" 2>/dev/null)
    [ -z "$PC_BASE" ] || printf '%s\n' "$PC_BASE" > "$BUILD/collision-base"
  fi
  PC_SLUG="${GH_AUTH_SLUG:-}"
  [ -n "$PC_SLUG" ] || PC_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
  PC_SUMMARY=$("$HARNESS/bin/plan-collisions.sh" --plan "$BUILD/plan.md" --repo . --base "$PC_BASE" \
    --main "origin/$BASE" --slug "$PC_SLUG" --self-branch "$BRANCH" --self-key "$KEY" --stack-base "$BASE" \
    --project "$PROJECT" --out "$BUILD/collisions.txt" 2>>"$BUILD/pipeline.log"); PC_RC=$?
  PC_CHECK() { # sets PC_RESOLVED PC_UNRES PC_NH over the listed collisions
    local n r
    PC_RESOLVED=0; PC_UNRES=""; PC_NH=""
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      r=0; pc_resolved "$BUILD/plan.md" "$n" || r=$?
      case "$r" in 0) PC_RESOLVED=$((PC_RESOLVED + 1)) ;; 2) PC_NH="$PC_NH; $n" ;; *) PC_UNRES="$PC_UNRES; $n" ;; esac
    done < <(pc_listed_hits "$BUILD/collisions.txt")
    PC_UNRES="${PC_UNRES#; }"; PC_NH="${PC_NH#; }"
  }
  if [ "$PC_RC" = 3 ] || [ ! -s "$BUILD/collisions.txt" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] design collisions: ${PC_SUMMARY:-no summary} — not checked" >> "$BUILD/pipeline.log"
  else
    PC_HITS=$(grep -c '^COLLISION	' "$BUILD/collisions.txt")
    PC_CHECK
    if [ "$PC_ENFORCE" = 1 ] && [ -n "$PC_UNRES" ] && [ -z "$PC_NH" ] && [ ! -e "$BUILD/collision-repair-done" ]; then
      touch "$BUILD/collision-repair-done"
      echo "$(STAMP) [$PROJECT/$KEY] design collisions: unresolved ($PC_UNRES) — one repair pass" >> "$BUILD/pipeline.log"
      CC plan "$PLAN_MODEL" 600 "$BUILD/collision-repair-run.txt" "Repair the plan at $BUILD/plan.md IN PLACE. Other work changed symbols this plan lists under '## Changed symbols' after the plan's base: $(awk -F'\t' '$1 == "COLLISION" && $2 == "listed" { s = s sep sprintf("`%s` (%s %s, %s)", $3, ($4 == "main" ? "main" : "PR " $4), $5, $6); sep = "; " } END { printf "%s", s }' "$BUILD/collisions.txt"). Read each of those commits (git show <sha>, or the open PR) and the plan's design for the symbol. Then add a '## Design collisions' section to plan.md (or extend it), one bullet per symbol: '- \`<name>\`: combine — <how the two designs combine, in one or two sentences>' when they can combine, or '- \`<name>\`: needs-human — <the question a person must answer>' when they cannot. Change nothing else. Keep the '## Acceptance tests', '## QA screens' and '## Size' sections and the KIND, SIZE and SLICE lines exactly as they are."
      PC_CHECK
    fi
    pc_note "$BUILD/plan.md" "$BUILD/collisions.txt"
    if [ "$PC_HITS" = 0 ]; then PC_VERDICT=none
    elif [ -n "$PC_UNRES$PC_NH" ] && [ "$PC_ENFORCE" = 1 ]; then PC_VERDICT=blocked
    elif [ -n "$PC_UNRES$PC_NH" ] || [ "$PC_RESOLVED" = 0 ]; then PC_VERDICT=note-only
    else PC_VERDICT=resolved
    fi
  fi
  echo "$(STAMP) [$PROJECT/$KEY] design collisions: listed=$(sed -n 's/^SYMBOLS: listed=\([0-9]*\).*/\1/p' "$BUILD/collisions.txt" 2>/dev/null) derived=$(sed -n 's/^SYMBOLS: .*derived=\([0-9]*\).*/\1/p' "$BUILD/collisions.txt" 2>/dev/null) hits=$PC_HITS resolved=$PC_RESOLVED main=$(sed -n 's/^MAIN: \([a-z]*\).*/\1/p' "$BUILD/collisions.txt" 2>/dev/null) prs=$(sed -n 's/^OPEN_PRS: \([a-z]*\).*/\1/p' "$BUILD/collisions.txt" 2>/dev/null) verdict=$PC_VERDICT" >> "$BUILD/pipeline.log"
  if [ "$PC_VERDICT" = blocked ]; then
    {
      echo "BLOCKED-NEEDS-CLARIFICATION"
      echo "needs-human: design collision (BH-5791)"
      while IFS= read -r PC_N; do
        [ -n "$PC_N" ] || continue
        echo "- Other work changed \`$PC_N\` after this plan's base. How do the two designs combine?"
      done < <(printf '%s\n' "$PC_UNRES" "$PC_NH" | tr ';' '\n' | sed 's/^ *//')
      echo ""
      cat "$BUILD/plan.md"
    } > "$BUILD/plan.md.pc" && mv "$BUILD/plan.md.pc" "$BUILD/plan.md"
    BB plan_blocked "" "" "" false "$(head -c 1200 "$BUILD/plan.md" 2>/dev/null)"
    RESULT "PLAN_BLOCKED $BUILD/plan.md"; exit 4
  fi
fi
# <<< design collisions (BH-5791)
# >>> replan comment (BH-3955)
# The replan check's amendment, posted on the child once the plan is written.
# AFTER the thread-stability re-check on purpose: our own comment moves the
# thread, and posted earlier it would defer this build as PLAN_STALE. ticket-fp
# is refreshed after it for the same reason, so a resume does not read it as
# someone else's turn. APP ONLY, like bin/lib/ticket-hold-cmd.sh: a PAT comment
# is a human comment to hold_classify, and model-written text could carry hold
# or lift vocabulary. replan-commented follows a successful post only, so a
# failed post is retried by a resume; no App identity writes the distinct
# replan-comment-skipped, so nothing reads as delivered. Neither blocks the build.
if [ -s "$BUILD/replan-comment.md" ] && [ ! -e "$BUILD/replan-commented" ] && [ ! -e "$BUILD/replan-comment-skipped" ]; then
  RPC_SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null)
  RPC_N=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  case "${GH_TOKEN:-}" in
    ghs_*)
      if gh_rest_comment "$RPC_SLUG" "$RPC_N" "$BUILD/replan-comment.md"; then
        touch "$BUILD/replan-commented"
        command -v ptg_own_post >/dev/null 2>&1 && ptg_own_post "$BUILD" "$BUILD/replan-comment.md"
        echo "$(STAMP) [$PROJECT/$KEY] replan comment posted on $RPC_SLUG#$RPC_N" >> "$BUILD/pipeline.log"
        if [ -n "${FP_BEFORE:-}" ]; then
          FP_BEFORE=$(TICKET_FP)
          [ -n "$FP_BEFORE" ] && printf '%s\n' "$FP_BEFORE" > "$BUILD/ticket-fp"
        fi
      else
        echo "$(STAMP) [$PROJECT/$KEY] replan comment NOT posted on $RPC_SLUG#$RPC_N (rc=$?) — a resume retries it; the amendment already reached the plan" >> "$BUILD/pipeline.log"
      fi ;;
    *)
      touch "$BUILD/replan-comment-skipped"
      echo "$(STAMP) [$PROJECT/$KEY] replan comment skipped: no App identity on this build (a PAT comment would read as a human's) — the amendment already reached the plan" >> "$BUILD/pipeline.log" ;;
  esac
fi
# <<< replan comment (BH-3955)

# >>> kind flow
# --- KIND: what kind of work is this? (SDLC item 7, 2026-09-06) --------------
# One workflow served every ticket: a copy tweak, a schema migration and a
# DEFECT all got the same execute prompt ("implement the acceptance tests
# first") and the same lens routing. The defect is the one that suffers — what
# proves a bug fix is a REPRODUCTION that fails on the code as it stands, and
# the pipeline had no stage that asked for one. TK-44 and TK-113 are both that
# gap, and docs/LESSONS.md item 9 ("prove innocence on main") is a bug-flow step
# written as doctrine because there was nowhere else to put it.
#
# bin/kind-gate.sh settles it from the board's own evidence first (type field,
# GitHub label, title prefix) and the plan's KIND line second, and checks the
# bug contract. It runs HERE, after the plan gate's repair pass, so the plan it
# reads is the plan EXECUTE will get — and outside the PLAN checkpoint, like
# the plan gate, so a resumed build is classified too.
#
# WARN-FIRST, the standing rule for a new gate that can demote or skip:
#   KIND_GATE_ENFORCE=0  SHIPPED DEFAULT. The classification reaches the
#                        planner, the executor, the reviewer, the PR's evidence
#                        block and the ledger; a bug with no reproduction is
#                        noted and keeps its tier; a copy ticket still buys the
#                        E2E smoke. Nothing is withheld on a classifier's word.
#   KIND_GATE_ENFORCE=1  arms the two consequences: a bug whose plan carries no
#                        complete '## Reproduction' demotes to tier 2, and a
#                        copy ticket skips the browser smoke and the
#                        reopen-armed extra security lens.
# The bug flow's EXECUTE prompt is NOT behind the flag: adapting how a defect is
# built is the item itself, it withholds nothing, and a prompt that only fires
# when a flag is on is a prompt nobody measures.
T_KIND=$(STAGE_START)
KIND_OUT=$("$HARNESS/bin/kind-gate.sh" "$BUILD" 2>&1); KIND_RC=$?
STAGE_END kind "$T_KIND"
printf '%s\n' "$KIND_OUT" > "$BUILD/kind.txt"
KIND=$(sed -n 's/^KIND:[[:space:]]*//p' "$BUILD/kind.txt" | tail -1)
KIND_REPRO=$(sed -n 's/^KIND_REPRO:[[:space:]]*//p' "$BUILD/kind.txt" | tail -1)
KIND_SRC=$(sed -n 's/^KIND_SOURCE:[[:space:]]*//p' "$BUILD/kind.txt" | tail -1)
KIND_MISS=$(sed -n 's/^KIND_REPRO_MISSING:[[:space:]]*//p' "$BUILD/kind.txt" | tail -1)
# A gate that could not run is `unknown`, never a kind — the same rule the
# scope gate follows, and for the same reason: not-measured and feature are
# different facts, and only one of them is a claim.
[ -n "$KIND" ] || KIND=unknown
[ -n "$KIND_REPRO" ] || KIND_REPRO="n/a"
[ -n "$KIND_SRC" ] || KIND_SRC=none
echo "$(STAMP) [$PROJECT/$KEY] KIND: $KIND (source $KIND_SRC, repro $KIND_REPRO, rc=$KIND_RC)" >> "$BUILD/pipeline.log"
case "$(printf '%s' "${KIND_GATE_ENFORCE:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)     KIND_ENFORCE=1 ;;
  0|''|false|no|off) KIND_ENFORCE=0 ;;
  *) KIND_ENFORCE=0
     echo "$(STAMP) [$PROJECT/$KEY] KIND_GATE_ENFORCE='${KIND_GATE_ENFORCE:-}' is not a recognized on/off value — treating as OFF (warn-only)" >> "$ALERTS" ;;
esac
# The copy skips, armed only with the flag. They REMOVE verification, so unlike
# a demotion they cost nothing to hold back and everything to get wrong.
KIND_SKIP_E2E=0
[ "$KIND" = copy ] && [ "$KIND_ENFORCE" = 1 ] && KIND_SKIP_E2E=1
KIND_SKIP_SECLENS=$KIND_SKIP_E2E
# The bug flow's own instruction to the executor. Empty for every other kind,
# so those prompts stay byte-identical.
KIND_EXEC_NOTE=""
if [ "$KIND" = bug ]; then
  KIND_EXEC_NOTE="BUG FLOW — READ THIS BEFORE THE INSTRUCTIONS BELOW. This ticket is a DEFECT (KIND: bug), so the first artifact you produce is proof the bug exists, not a feature test. Read the plan's '## Reproduction' section and run its REPRO command against the code EXACTLY AS IT STANDS, before you change one line, and save its FAILING output verbatim to $BUILD/red.txt — that failure IS this build's red proof, and bin/repro-gate.sh re-runs your tests at the merge base to check it. If the REPRO does NOT fail, STOP AND SAY SO in your final output rather than editing anything: either the reproduction is wrong or the defect is not where the plan says, and both are findings a human needs (TK-113 blamed five pre-existing failures on a PR that did not cause them; TK-44 shipped a replacement route over a fail-closed one that was working as designed). Then fix the ROOT CAUSE the plan named, at the file:line it named — never the call site where the symptom showed — re-run the same REPRO command to green, and check the BLAST RADIUS callers the plan listed still work. Where the repo's test framework allows it, the reproduction belongs in the suite as a NEW test file so the defect cannot come back unnoticed. Everything below still applies; where it says to write the acceptance tests first, the reproduction is the first of them. "
  [ "$KIND_REPRO" = ok ] || KIND_EXEC_NOTE="$KIND_EXEC_NOTE THE PLAN'S REPRODUCTION IS INCOMPLETE (missing: ${KIND_MISS:-the whole section}). Do not invent one to look complete: derive the failing command from the ticket thread yourself, record in red.txt what you actually ran and what it did, and say plainly in your final output which of the five facts the plan never established. "
fi
# The ledger learns the KIND even when nothing is wrong, for the same reason the
# plan gate's row does: a build that stops before the PR never reaches the
# verdict artifact, and a row written only for bugs would make "no row" mean
# both "not a bug" and "old box". jobs.kind is a DIFFERENT vocabulary
# (triage|build|fix|qa|migration — which pipeline this is), so this rides as its
# own artifact rather than overwriting that column; $BUILD/kind.txt is the
# documented file fallback. Fail-open like every other ledger write here.
if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  job_artifact_put build_kind "$KIND" \
    "$(jq -nc --arg k "$KIND" --arg s "$KIND_SRC" --arg r "$KIND_REPRO" \
        --arg m "$(printf '%s' "$KIND_MISS" | cut -c1-300)" \
        '{kind:$k,source:$s,repro:$r} + (if $m == "" then {} else {repro_missing:$m} end)' 2>/dev/null)" \
    >/dev/null 2>&1 || true
fi
# <<< kind flow
REROUTE_EXEC_NOTE=""
# Sibling of KIND_EXEC_NOTE above, and empty for exactly the same reason: the
# `# >>> test reroute` block below fills it only when this ticket's test files
# were actually rerouted, so every other build's execute prompt is unchanged.
# It sits one line OUTSIDE the kind-flow block on purpose — that block is
# extracted verbatim by tests/kind-flow-test.sh, whose byte-identical-prompt row
# would otherwise be judging a different block than the one that ships.

# >>> size enforce switch
# --- IS THE SIZE GATE ARMED ON THIS BUILD? ----------------------------------
# ARMED BY DEFAULT SINCE 2026-09-14 (the operator). The gate shipped warn-only on
# 2026-09-12 and the fleet then watched it be right and do nothing: TK-552
# shipped 1,900 product lines across 18 files in ONE 33-minute execute, TK-556
# was flagged decomposable the same night, and both were built whole because the
# switch was off. Two or three parallel 15-minute children would have been
# faster to build AND reviewable at the end. So the default flips.
#
# The ways to turn it back off are the three a box actually has, first hit wins:
#   flags/size-gate-enforce-off     the fleet kill flag (or the
#                                   `switch.size-gate-enforce-off` settings
#                                   row). No deploy, no env edit,
#                                   and while it is there every path below is
#                                   byte-for-byte what it was before this
#                                   change: an oversized plan is logged and
#                                   built whole, an unsized plan still builds,
#                                   and `SIZE: XL` still splits.
#   SIZE_GATE_ENFORCE_<project>=0   one project opts out, in env/<project>.env.
#                                   A repo whose changes are honestly wide is a
#                                   per-project fact, the same way its threshold
#                                   is (bin/size-threshold.sh). The name is also
#                                   read uppercased with dashes as underscores,
#                                   because `project-3` is not a shell identifier.
#   SIZE_GATE_ENFORCE=0             the global switch, unchanged in meaning.
#
# JUNK IS NEVER A SWITCH VALUE — it falls through to the next source and says so
# in ALERTS, the same rule bin/size-threshold.sh applies to a threshold. That
# reasoning inverted with the default: while the gate was off, a typo must not
# ARM something that withholds a build; now that it is on, a typo must not
# silently DISARM the fleet's only defence against 1,900-line PRs.
#
# Resolved by a function rather than inline because BOTH halves of this gate
# read the same switch — the plan-time split below and the post-hoc demotion at
# PR-open — and two copies would drift into a build that splits at plan time and
# then says SIZE_GATE_ENFORCE=0 in its own PR body. Memoized, so the second
# caller is free and an ALERTS line is written once per build.
SG_ENFORCE=0
SG_SWITCH_SRC=""
# shellcheck source=../lane-switch.sh
command -v lane_switch >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lane-switch.sh" 2>/dev/null || lane_switch() { [ -e "${HARNESS:-${H:-/root/harness}}/flags/$1" ]; }
SG_SWITCH_RESOLVE() {
  [ -n "$SG_SWITCH_SRC" ] && return 0
  local v raw
  if lane_switch size-gate-enforce-off file; then
    SG_ENFORCE=0
    # BH-2412 split the no-row answer into legacy-file and legacy-row.
    case "${LANE_SWITCH_SRC:-legacy}" in
      legacy|legacy-file) SG_SWITCH_SRC="flags/size-gate-enforce-off" ;;
      legacy-row) SG_SWITCH_SRC="pause_flags size-gate-enforce-off" ;;
      *) SG_SWITCH_SRC="settings switch.size-gate-enforce-off ($LANE_SWITCH_SRC)" ;;
    esac
    return 0
  fi
  for v in "SIZE_GATE_ENFORCE_$PROJECT" \
           "SIZE_GATE_ENFORCE_$(printf '%s' "$PROJECT" | tr '[:lower:].-' '[:upper:]__')" \
           SIZE_GATE_ENFORCE; do
    case "$v" in *[!A-Za-z0-9_]*) continue ;; esac
    raw="${!v:-}"
    [ -n "$raw" ] || continue
    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on)  SG_ENFORCE=1; SG_SWITCH_SRC="$v" ; return 0 ;;
      0|false|no|off) SG_ENFORCE=0; SG_SWITCH_SRC="$v" ; return 0 ;;
      *) echo "$(STAMP) [$PROJECT/$KEY] $v='$raw' is not a recognized on/off value — ignoring it and reading the next source (to turn the size gate off, touch $HARNESS/flags/size-gate-enforce-off)" >> "$ALERTS" ;;
    esac
  done
  SG_ENFORCE=1; SG_SWITCH_SRC="the shipped default (armed)"
  return 0
}
# <<< size enforce switch

# >>> size gate
# --- SIZE: the plan declares how big it is, and too big is SPLIT, not built ---
# SCALE-PLAN wave 2 gave this pipeline a decomposer on 2026-07-28, and for six
# weeks it fired on exactly one input: a planner voluntarily writing `SIZE: XL`
# on the last line of its own plan. Self-reported, all-or-nothing, and
# unmeasured — an `L` plan that turned into 1,400 lines was indistinguishable
# from an `L` plan that turned into 200.
#
# MEASURED (the operator, 2026-09-12): the MEDIAN diff across 381 merged harness PRs is
# 1,268 lines changed. Large orgs land 100-300, because review cost, conflict
# probability and re-review cost all grow superlinearly with size — a
# 1,200-line PR is not four times the work of a 300-line one to review, it is
# the one nobody reviews properly. So decomposition becomes the DEFAULT above a
# threshold instead of an XL-only escape hatch.
#
# THE UNIT IS PRODUCT LINES, not diff lines. bin/size-scope.sh owns the
# exclusion list (tests, docs, specs, lockfiles, generated files, Prisma
# migration snapshots) and is the only place it lives — the post-hoc guard at
# PR-open calls the same helper on the diff that actually shipped, so the two
# sides cannot disagree about what they measured. Counting tests would punish
# the red-first discipline the rest of this pipeline pays to enforce.
#
# THE THRESHOLD IS NOT A CONSTANT. bin/size-threshold.sh resolves it per
# project and per axis (BH-4985): the settings rows size_gate.<axis>.<project>
# then size_gate.<axis> (seeded 700/20, edited on /config) — or, for a hotfix
# ticket, size_gate.<axis>.hotfix[.<project>] (1500/30) ahead of both — then
# flags/size-gate-<project> on the box, then the repo-tracked
# catalog/size-thresholds.conf, then 700 lines / 20 files. The source it used
# rides the SIZE line below and the size_gate ledger artifact as src=.
#
# WARN-FIRST FOR TWO DAYS, THEN ARMED (the operator, 2026-09-14). The gate shipped
# disarmed on 2026-09-12 under the standing rule for a new gate that can
# withhold a build, and warn-only did exactly what it promised: it measured,
# logged, and watched TK-552 build 1,900 product lines in 18 files whole. The
# switch now resolves through `# >>> size enforce switch` above and defaults to
# ARMED:
#   armed    an over-threshold plan is handed to bin/run-decompose.sh instead of
#            built (row 21). A plan that declares no size is a WARNING since
#            BH-5292: its size is estimated from its file list and it builds
#            whole unless the estimate is past 2x the threshold. Only a missing
#            or empty plan.md is still PLAN_MALFORMED (row 20c).
#   disarmed the estimate is still parsed, judged, logged and written to the
#            ledger; an oversized plan is named here and built whole, exactly as
#            it did before this change. flags/size-gate-enforce-off is the fleet
#            lever, SIZE_GATE_ENFORCE_<project>=0 the per-project one.
# `SIZE: XL` still splits either way when the gate could not measure or agrees:
# it was the ONLY decomposition trigger this pipeline had, and shipping the
# replacement disarmed while removing the original would leave the fleet with
# no decomposition at all. A measured `within` overrides it (see below).
# >>> size threshold call (tests/size-threshold-hotfix-tier.size-hotfix-test.sh drives this block)
# A HOTFIX ticket is sized against its own, bigger tier (the operator, 2026-10-07): the
# rows size_gate.<axis>.hotfix[.<project>], seeded 1500/30, so an emergency
# builds as one PR instead of being split. HOTFIX is the value `# >>> hotfix
# detect` in gates.sh already settled (job env, label read once, kill flag
# honoured) — no second GitHub read here. Not a hotfix: no tier, today's answer.
SG_TIER=""
[ "${HOTFIX:-}" = 1 ] && SG_TIER=hotfix
SG_LIMITS=$(SIZE_TIER="$SG_TIER" "$HARNESS/bin/size-threshold.sh" "$PROJECT" all 2>/dev/null) || SG_LIMITS=""
SG_MAXL=$(printf '%s' "$SG_LIMITS" | awk '{print $1}')
SG_MAXF=$(printf '%s' "$SG_LIMITS" | awk '{print $2}')
SG_SRC=$(printf '%s' "$SG_LIMITS" | awk '{print $3}')
case "${SG_SRC:-}" in ''|*[!a-z:,]*) SG_SRC=default ;; esac
case "${SG_MAXL:-}" in ''|*[!0-9]*) SG_MAXL=700; SG_SRC=default ;; esac
case "${SG_MAXF:-}" in ''|*[!0-9]*) SG_MAXF=20; SG_SRC=default ;; esac
# <<< size threshold call
# The plan's MENTION list, handed to the gate for the record only: it prints the
# count and names it `SIZE_FILES_MENTIONED: n (not gating)` above the tolerated
# file limit, and judges the file axis on the declaration alone (BH-612 — this
# list is a deliberate over-listing and it was decomposing 45-line fixes whose
# prose named eighteen callers).
#
# Re-derived UNCONDITIONALLY, not skipped when the file is
# already there: a resumed build whose plan was rewritten in the same dir would
# otherwise be checked against the DEAD attempt's file list. It is a pure
# function of plan.md with no network and no model call, and planned-files.sh
# runs once more below for the claims ledger, so paying for it twice is free.
"$HARNESS/bin/planned-files.sh" "$BUILD" 2>/dev/null || true
# A FUNCTION since BH-657 (when a repair pass re-measured the plan; that pass is
# gone since BH-5292, the function stayed). Everything downstream reads it off
# the file on disk rather than off a session's claim about what it wrote.
SG_MEASURE() {
  SG_OUT=$(SIZE_LIMITS_SRC="$SG_SRC" "$HARNESS/bin/size-gate.sh" "$BUILD/plan.md" "$SG_MAXL" "$SG_MAXF" "$BUILD/planned-files.txt" 2>&1)
  SG_RC=$?
  printf '%s\n' "$SG_OUT" > "$BUILD/size-gate.txt"
  SG_VERDICT=$(sed -n 's/^SIZE_VERDICT:[[:space:]]*//p' "$BUILD/size-gate.txt" 2>/dev/null | tail -1)
  SG_WHY=$(sed -n 's/^SIZE_OVER:[[:space:]]*//p' "$BUILD/size-gate.txt" 2>/dev/null | tail -1)
  SG_DECL=$(sed -n 's/^SIZE_DECLARED:[[:space:]]*//p' "$BUILD/size-gate.txt" 2>/dev/null | tail -1)
  # A gate that could not run is `not-recorded`, never a size — the rule the kind
  # and scope gates already follow, because not-measured and small-enough are
  # different facts and only one of them is a claim. rc 0/2/3 are verdicts; a
  # crash, a missing helper on a half-synced box or a `set -u` death is not.
  case "$SG_RC" in
    0|2|3) [ -n "$SG_VERDICT" ] || SG_VERDICT=not-recorded ;;
    *) SG_VERDICT=not-recorded
       echo "$(STAMP) [$PROJECT/$KEY] SIZE: the size gate could not run (rc=$SG_RC) — this plan was NOT sized, do not read that as small" >> "$BUILD/pipeline.log" ;;
  esac
}
SG_MEASURE
# >>> live emit plan
# The first thing an operator wants to know about a running build: was a plan
# written, did it size itself, and did the size gate let it through.
type LIVE >/dev/null 2>&1 && LIVE plan "${SG_VERDICT:-not-recorded}" \
  "plan written: ${SG_DECL:-no size declared}; ${PG_TASKS:-0} task(s) traced, ${PG_UNTRACED:-0} untraced; size gate: ${SG_VERDICT:-not-recorded}"
# <<< live emit plan
# The switch is resolved once per build, as before — both halves of the gate
# still read this one function.
SG_SWITCH_RESOLVE
echo "$(STAMP) [$PROJECT/$KEY] SIZE: enforcement $([ "$SG_ENFORCE" = 1 ] && echo ON || echo OFF), from $SG_SWITCH_SRC" >> "$BUILD/pipeline.log"
# NO REPAIR PASS FOR A MISSING `## Size` (BH-5292, the operator 2026-10-07). BH-657
# bought one planner session here so a plan with no heading would not die at
# PLAN_MALFORMED. A missing heading is now a WARNING: bin/size-gate.sh estimates
# the size from the plan's file list and the build proceeds (`estimated`), so a
# model session spent writing a number nobody is blocked on is pure spend.
echo "$(STAMP) [$PROJECT/$KEY] SIZE: $SG_VERDICT (${SG_DECL:-nothing declared}, limits lines=$SG_MAXL files=$SG_MAXF src=$SG_SRC, rc=$SG_RC)${SG_WHY:+ — $SG_WHY}" >> "$BUILD/pipeline.log"
# THE LEDGER LEARNS THE SIZE EVEN WHEN NOTHING IS WRONG, for the same reason the
# plan-gate row is written on clean builds: a decomposed or malformed build
# never reaches the verdict artifact, and a row written only on failure would
# make "no row" mean both "small" and "old box". Fail-open; the file fallback is
# $BUILD/size-gate.txt.
if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  job_artifact_put size_gate "$SG_VERDICT" \
    "$(jq -nc --arg v "$SG_VERDICT" --arg d "$SG_DECL" --arg o "$SG_WHY" \
        --argjson ml "$SG_MAXL" --argjson mf "$SG_MAXF" --arg ms "$SG_SRC" \
        '{verdict:$v,limits:{lines:$ml,files:$mf,src:$ms}} + (if $d == "" then {} else {declared:$d} end) + (if $o == "" then {} else {over:$o} end)' 2>/dev/null)" \
    >/dev/null 2>&1 || true
fi
# NO `## Size` IS A WARNING (BH-5292): the gate estimated the size from the
# plan's file list and the build goes on, armed or not. Only a plan the gate
# could not read at all (`undeclared`: no plan.md, or an empty one) is still a
# malformed plan, through the same requeue-once ledger the trace gate uses.
if [ "$SG_VERDICT" = estimated ]; then
  echo "$(STAMP) [$PROJECT/$KEY] SIZE WARNING: the plan declares no '## Size' section — $(sed -n 's/^SIZE_ESTIMATED:[[:space:]]*//p' "$BUILD/size-gate.txt" 2>/dev/null | tail -1), building whole" >> "$BUILD/pipeline.log"
fi
if [ "$SG_VERDICT" = undeclared ]; then
  if [ "$SG_ENFORCE" = 1 ]; then
    PM_TERMINAL "the size gate found no readable plan to size" \
                "$BUILD/size-gate.txt" "write a plan the size gate can read"
  fi
  echo "$(STAMP) [$PROJECT/$KEY] SIZE: undeclared — size enforcement is OFF (from $SG_SWITCH_SRC), the build continues unsized" >> "$BUILD/pipeline.log"
fi
SG_SPLIT=""
# MEASURED BEATS SELF-REPORTED (the operator, 2026-09-16: "not create a decomposition
# as a rule"). BH-597 declared FILES: 5 / LINES: 210, measured `within`, and was
# still split into four serial children because its planner also wrote
# `SIZE: XL` on the last line. The T-shirt line is the planner's mood; the
# `## Size` section is a number the plan is held to — declared here, and
# compared with the diff that actually shipped in the evidence block at PR-open.
# When the number says it fits, XL is a note, not a trigger. XL keeps its
# old power only when the gate could not measure (undeclared, not-recorded) or
# agrees (over). Armed-only: a disarmed box (kill flag, SIZE_GATE_ENFORCE=0)
# keeps XL as its sole trigger, byte-for-byte what it had before the gate.
if tail -3 "$BUILD/plan.md" | grep -qE '^SIZE: *XL'; then
  if [ "$SG_VERDICT" = within ] && [ "$SG_ENFORCE" = 1 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] SIZE: the plan sized itself XL but measures ${SG_DECL:-?}, within the threshold — measured beats self-reported, building whole" >> "$BUILD/pipeline.log"
  else
    SG_SPLIT="the plan sized itself XL"
  fi
fi
if [ "$SG_VERDICT" = over ]; then
  if [ "$SG_ENFORCE" = 1 ]; then
    SG_SPLIT="${SG_SPLIT:-the plan is over the decomposition threshold ($SG_WHY)}"
  else
    echo "$(STAMP) [$PROJECT/$KEY] SIZE: over the threshold ($SG_WHY) — decomposable, but size enforcement is OFF (from $SG_SWITCH_SRC), so this builds whole" >> "$BUILD/pipeline.log"
  fi
fi
# DEPTH 1, AND ONLY DEPTH 1 (2026-09-14). bin/run-decompose.sh titles every
# child it files `<PARENT KEY>.<n>: ...` on both lanes, so a split child says out
# loud that it is already a slice of something. A slice that STILL sizes over
# the threshold is built whole with this one line as the note: splitting it again
# buys another Fable call, another ticket, another 6-8 minute push-to-review dead
# gap, and the thing being split is by construction the narrowest scope anyone
# has written down yet. It is also the only thing between one bad estimate and a
# split loop that files tickets forever. Armed-only, so the kill flag leaves the
# XL path exactly as it was, and fail-open: a build whose ticket-meta.json never
# arrived is not treated as a child, because "we could not read the title" and
# "this is a top-level ticket" are different facts and only one of them is here.
# THE BODY IS A SECOND LOCAL SOURCE (BH-851). A title can be edited, and the
# meta file can arrive without one, but the filer also writes a column-0
# `Split child (depth 1): ...` line into every decompose child's footer
# (fc_child_footer), so the body on disk is read too: `.body` in the meta, else
# ticket-body.md. Never a network call. The match is strict (column 0, outside
# ``` / ~~~ fences, the filer's exact text), because a ticket that only QUOTES
# the line must still split. The decision is logged either way.
# >>> split child check
SG_CHILD=""; SG_CHILD_SRC=none
SG_TITLE=$(jq -r '.title // ""' "$BUILD/ticket-meta.json" 2>/dev/null)
grep -qE '^[[:space:]]*[A-Za-z]+-[0-9]+\.[0-9]+' <<<"${SG_TITLE:-}" && { SG_CHILD=1; SG_CHILD_SRC=meta; }
if [ -z "$SG_CHILD" ]; then
  SG_BODY=$(jq -r '.body // ""' "$BUILD/ticket-meta.json" 2>/dev/null)
  [ -n "$SG_BODY" ] || SG_BODY=$(cat "$BUILD/ticket-body.md" 2>/dev/null)
  printf '%s\n' "${SG_BODY:-}" | awk '
    f == "" && /^(```|~~~)/        { f = substr($0, 1, 3); next }
    f != "" && index($0, f) == 1   { f = ""; next }
    f == "" && /^Split child \(depth 1\):/ { m = 1; exit }
    END { exit !m }' && { SG_CHILD=1; SG_CHILD_SRC=body; }
fi
if [ -s "$BUILD/ticket-meta.json" ]; then
  SG_TLOG=$(printf '%s' "${SG_TITLE:-}" | tr -d '[:cntrl:]' | cut -c1-120)
else
  SG_TLOG=unread
fi
echo "$(STAMP) [$PROJECT/$KEY] SIZE: child check: title=$SG_TLOG source=$SG_CHILD_SRC" >> "$BUILD/pipeline.log"
# <<< split child check
if [ -n "$SG_SPLIT" ] && [ "$SG_ENFORCE" = 1 ] && [ -n "$SG_CHILD" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] SIZE: $SG_SPLIT, but this ticket is ALREADY a split child (depth 1) — building it whole instead of splitting it again" >> "$BUILD/pipeline.log"
  SG_SPLIT=""
fi
if [ -n "$SG_SPLIT" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] DECOMPOSE: $SG_SPLIT — splitting instead of building" >> "$BUILD/pipeline.log"
  # >>> live emit size
  type LIVE >/dev/null 2>&1 && LIVE size split "size gate: splitting instead of building ($SG_SPLIT)"
  # <<< live emit size
  # The decomposer is handed the per-child budget. Without it the children come
  # back the size of the parent and the split bought a round trip and nothing
  # else. Extra args are optional there, so an older bin/ on a half-synced box
  # still splits — it just splits blind.
  # rc 3 is the splitter refusing a HELD ticket (BH-1526): not a failed split,
  # a deferral, so it is never paged as DECOMPOSE_FAILED.
  "$HARNESS/bin/run-decompose.sh" "$PROJECT" "$TICKET" "$KEY" "$BUILD" "$SG_MAXL" "$SG_MAXF"; SG_DRC=$?
  if [ "$SG_DRC" = 0 ]; then
    # The parent's ledger row ends here, not at `planning` (BH-3481.1). Fail-open: BB never blocks RESULT.
    BB decomposed "" "" "" false "split into $(paste -sd, "$BUILD/children.txt" 2>/dev/null)"
    RESULT "DECOMPOSED $(paste -sd, "$BUILD/children.txt" 2>/dev/null)"
  elif [ "$SG_DRC" = 3 ]; then
    RESULT "BUILD_DEFERRED held at split — $(grep -m1 '^DECOMPOSE_HELD' "$BUILD/decompose-run.txt" 2>/dev/null)"; exit 3
  else
    RESULT "DECOMPOSE_FAILED see $BUILD/decompose-run.txt"
  fi
  exit 0
fi
# <<< size gate
# >>> child plan tripwire (BH-3478)
# A split child arrives with its parent planner's context pack (bin/lib/context-pack.sh);
# the tripwire checker (bin/lib/child-plan-tripwire.sh, a sibling slice) judges the
# child's plan spend against the parent's. Fail-open: no pack means no log line, and
# the checker runs inside $(...) so neither its rc nor an exit can change this build.
[ -r "$HARNESS/bin/lib/context-pack.sh" ] && . "$HARNESS/bin/lib/context-pack.sh" 2>/dev/null
[ -r "$HARNESS/bin/lib/child-plan-tripwire.sh" ] && . "$HARNESS/bin/lib/child-plan-tripwire.sh" 2>/dev/null
if [ -z "${CP_PARENT:-}" ]; then
  if [ -s "$BUILD/context-pack.md" ] \
     || { command -v cp_fetch >/dev/null 2>&1 \
          && JOBS_ALERT=0 cp_fetch "$PROJECT" "$KEY" "$BUILD/context-pack.md" >/dev/null 2>&1; }; then
    CP_PARENT=$(head -n1 "$BUILD/context-pack.md.parent" 2>/dev/null)
  fi
fi
if [ -n "${CP_PARENT:-}" ]; then
  if command -v cpt_check >/dev/null 2>&1; then
    CPT_VERDICT=$(cpt_check "$PROJECT" "$KEY" "$CP_PARENT" 2>/dev/null | head -n1) || true
    echo "$(STAMP) [$PROJECT/$KEY] CHILD_PLAN_TRIPWIRE ${CPT_VERDICT:-UNMEASURED checker printed nothing}" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] CHILD_PLAN_TRIPWIRE skipped (no checker)" >> "$BUILD/pipeline.log"
  fi
fi
true
# <<< child plan tripwire

# SCALE-PLAN wave 1: conflict-aware deferral. Extract the plan's touched files;
# if a RUNNING sibling build overlaps, hand the ticket back to the queue instead
# of editing the same code concurrently — the union-merge class dies here.
"$HARNESS/bin/planned-files.sh" "$BUILD" 2>/dev/null || true
# >>> test reroute (tests/run-build-test-home.bh-580-test.sh drives this block)
# PER-TICKET TEST FILES, consumer side (#580). A pre-plan may have recorded that
# a test file this plan names is already held by a sibling build, and where this
# ticket's cases should go instead. The swap happens HERE, between the list
# being derived and the claim being published, because the claims copy,
# bin/conflict-check.sh and bin/plan-overlap.sh all read that same list — a
# sibling must see the path this build will actually write. The same record
# becomes the executor's note, so the prompt and the claim can never disagree:
# both are read off $BUILD/test-reroute.txt.
#
# Fail-open at every step. No lib (old box), no record, or the kill switch, and
# this block does nothing at all — no file written, no log line, empty note.
if command -v th_enabled >/dev/null 2>&1 && th_enabled "$HARNESS"; then
  # Relay first, hub second: on a Fly builder the record arrives as a flat copy
  # next to the job, and the hub path may not exist on that machine at all.
  TH_REC=""
  for TH_R in "$(th_relay_path "$PROJECT" "$KEY")" "$(th_record_path "$HARNESS" "$PROJECT" "$KEY")"; do
    [ -r "$TH_R" ] && [ -s "$TH_R" ] && { TH_REC="$TH_R"; break; }
  done
  # >>> test home plan
  # ADVISORY plan-time finding, BEFORE the swap so it judges what the planner
  # actually wrote. A shared test file that already exists and is named as a
  # plain add target is the merge-conflict shape this whole item exists to kill.
  # It refuses nothing and writes no RESULT — it hands the reviewer a sentence.
  : > "$BUILD/test-home.txt"
  if [ "${KIND:-}" != bug ] && [ -s "$BUILD/planned-files.txt" ]; then
    TH_N=0
    while IFS= read -r TH_P; do
      [ -n "$TH_P" ] || continue
      th_is_test_path "$TH_P" || continue
      th_is_per_ticket "$TH_P" && continue
      # A file that does not exist yet is nobody's shared file.
      [ -e "$WT/$TH_P" ] || continue
      # "Every plan line naming this path carries a change-word" is the skip, so
      # the finding needs at least one line naming it with none of them: a
      # ticket whose scope IS the existing test, a bug reproduction, or a path
      # mentioned only as a regression risk is not planning to append cases.
      grep -F -- "$TH_P" "$BUILD/plan.md" 2>/dev/null \
        | grep -Eiv 'existing|change|modif|update|fix|rewrite|reproduc|regression|risk|TEST-CHANGE' \
        | grep -q . || continue
      printf 'SHARED: %s -> %s\n' "$TH_P" "$(th_per_ticket_path "$TH_P" "$KEY")" >> "$BUILD/test-home.txt"
      TH_N=$((TH_N+1))
    done < "$BUILD/planned-files.txt"
    if [ "$TH_N" -gt 0 ]; then
      printf 'TEST_HOME_PLAN: %s\n' "$TH_N" >> "$BUILD/test-home.txt"
      echo "$(STAMP) [$PROJECT/$KEY] TEST_HOME_PLAN: $TH_N shared test file(s) named as a plain add target (advisory) — $BUILD/test-home.txt" >> "$BUILD/pipeline.log"
    fi
  fi
  # <<< test home plan
  if [ -n "$TH_REC" ]; then
    cp -f "$TH_REC" "$BUILD/test-reroute.txt" 2>/dev/null
    # Idempotent by contract: a resumed build whose list is already swapped gets
    # a byte-identical list back, and still gets the note its EXECUTE needs.
    th_apply "$BUILD/test-reroute.txt" "$BUILD/planned-files.txt"
    REROUTE_EXEC_NOTE=$(th_exec_note "$BUILD/test-reroute.txt")
    TH_RN=$(grep -c '^REROUTE tests: ' "$BUILD/test-reroute.txt" 2>/dev/null || true)
    echo "$(STAMP) [$PROJECT/$KEY] TEST_REROUTE: ${TH_RN:-0} path(s) forwarded to EXECUTE" >> "$BUILD/pipeline.log"
  fi
fi
# <<< test reroute
# SCALE-PLAN-2 claims ledger: publish this build's file set so sibling PLANNERS
# shard around us instead of colliding. Stale claims (dead builds) age out at 4h.
mkdir -p "$HARNESS/state/claims/$PROJECT"
find "$HARNESS/state/claims/$PROJECT" -type f -mmin +240 -delete 2>/dev/null
cp "$BUILD/planned-files.txt" "$HARNESS/state/claims/$PROJECT/$KEY" 2>/dev/null || true
# >>> hotspot claim
# BH-5268: the claim also names every stored conflict hotspot (the project's
# conflict_hotspots rows, bin/lib/plan-hotspots.sh) this plan mentions anywhere,
# because planned-files.sh's directory allowlist drops bin/, cron/, root config
# files and the like, and a sibling planner on any box must still see a light
# touch on one. The union goes to claim-files.txt; planned-files.txt is NOT
# changed (the size and scope gates read it). Nothing to add, or the hotspot
# list unread, leaves CLAIM_FILES empty and the claim exactly as above.
CLAIM_FILES=""; HC_N=0; PH_SOURCE=none
# shellcheck source=bin/lib/plan-hotspots.sh
[ -r "$HARNESS/bin/lib/plan-hotspots.sh" ] && . "$HARNESS/bin/lib/plan-hotspots.sh" 2>/dev/null
if command -v ph_hot_list >/dev/null 2>&1 && ph_hot_list "$PROJECT" "$BUILD/.hotspots.txt" 2>>"$BUILD/pipeline.log"; then
  HC_N=$(ph_mentions "$BUILD/plan.md" "$BUILD/.hotspots.txt" | tee "$BUILD/.hotspot-mentions.txt" | grep -c .)
  if [ "${HC_N:-0}" -gt 0 ] && ph_union "$BUILD/planned-files.txt" "$BUILD/.hotspot-mentions.txt" "$BUILD/claim-files.txt"; then
    CLAIM_FILES="$BUILD/claim-files.txt"
    cp "$CLAIM_FILES" "$HARNESS/state/claims/$PROJECT/$KEY" 2>/dev/null || true
  fi
fi
echo "$(STAMP) [$PROJECT/$KEY] HOTSPOT_CLAIM n=${HC_N:-0} source=$PH_SOURCE" >> "$BUILD/pipeline.log"
# <<< hotspot claim
# >>> touch claim
# BH-5965: when the plan declares its files (## Files to touch), the claim is
# that list and nothing the plan only mentions. bin/touch-files.sh writes
# touch-source = declared | none | off; anything but declared leaves the claim
# exactly as the two regions above made it. A test reroute is applied to the
# declared list too, so the claim names the per-ticket test file.
TC_SRC=absent
if [ -x "$HARNESS/bin/touch-files.sh" ]; then
  "$HARNESS/bin/touch-files.sh" "$BUILD" "$PROJECT" 2>>"$BUILD/pipeline.log" || :
  TC_SRC=$(cat "$BUILD/touch-source" 2>/dev/null || echo absent)
  if [ "$TC_SRC" = declared ] && [ -s "$BUILD/touch-files.txt" ]; then
    [ -s "$BUILD/test-reroute.txt" ] && command -v th_apply >/dev/null 2>&1 \
      && th_apply "$BUILD/test-reroute.txt" "$BUILD/touch-files.txt"
    CLAIM_FILES="$BUILD/touch-files.txt"
    cp "$CLAIM_FILES" "$HARNESS/state/claims/$PROJECT/$KEY" 2>/dev/null || true
  fi
fi
TC_N=$(grep -c . "$BUILD/touch-files.txt" 2>/dev/null); TC_X=$(grep -c $'\texcluded$' "$BUILD/touch-files.src" 2>/dev/null)
echo "$(STAMP) [$PROJECT/$KEY] TOUCH_CLAIM source=$TC_SRC n=${TC_N:-0} excluded=${TC_X:-0}" >> "$BUILD/pipeline.log"
# <<< touch claim
# >>> file claim db
# BH-2524.2: the same file set on this build's job_claims row, so PLANNERS on
# OTHER boxes see it. AFTER the local cp on purpose: a DB failure never loses
# the local claim. Honest status: skipped = no lib / JOBS_URL / JOB_ID,
# failed = fclaim_put returned non-zero (outage, or the contract stub), ok only on rc 0.
FC_DB=skipped
# shellcheck source=bin/lib/file-claims.sh
[ -r "$HARNESS/bin/lib/file-claims.sh" ] && . "$HARNESS/bin/lib/file-claims.sh" 2>/dev/null
if [ -n "${JOBS_URL:-}" ] && [ -n "${JOB_ID:-}" ] && command -v fclaim_put >/dev/null 2>&1; then
  if fclaim_put "${CLAIM_FILES:-$BUILD/planned-files.txt}" >/dev/null 2>&1; then FC_DB=ok; else FC_DB=failed; fi
fi
echo "$(STAMP) [$PROJECT/$KEY] FILE_CLAIM db=$FC_DB" >> "$BUILD/pipeline.log"
# <<< file claim db
# >>> hot files
# BH-475: the reviewer's half of the hot-file report. The claim above says what
# this build owns; this says which of those files OTHER planned tickets also
# intend to touch, so the review can ask the only question that actually shrinks
# the problem — does this change belong in a per-ticket file instead? It is
# context, never a gate: an empty file means nothing was measured (the scheduler
# is off, or no siblings have pre-plans), not that the diff is clean, and the
# GATES_NOTE assembly says nothing at all in that case.
"$HARNESS/bin/overlap-schedule.sh" "$PROJECT" --hot-for "$BUILD/planned-files.txt" "$KEY" \
  > "$BUILD/hot-files.txt" 2>/dev/null || :
# <<< hot files
# CKPT_ON_EXIT runs FIRST and is a no-op outside the execute stage: whatever the
# worktree is carrying gets committed and pushed before the job row is closed,
# so an rc != 0 / timeout / max-turns death still leaves the tree on origin.
} # end rb_plan
