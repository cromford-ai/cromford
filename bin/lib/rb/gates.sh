# bin/lib/rb/gates.sh — the gates a build passes before it plans: context gate, fly enqueue gate, WIP cap and build slots, overlap not-before, GH auth, coordination-DB claim, queue claim, reopen trust signal, stacked child builds, repo lock, worktree and branch suffix, and the post-plan overlap wait and plan-overlap file-claim gate.
# Each body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
#
# WHERE SLICE 2 ENDS, AND WHY IT IS NOT THE ANCHOR #478 NAMED. The parent plan
# ended `rb_gate_claim_and_workspace` at the `TAKEN=$(git ls-remote --heads
# origin "$BRANCH*" …)` line. That line sits inside the `else` arm of the
# driver's `if [ -n "${TARGET_BRANCH:-}" ]`, and the checkpoint-adopt block that
# landed on 2026-09-15 sits between it and the closing `fi`. A body cut at the
# anchor opens an `if` it never closes: `bash -n` rc 2, reproduced, and the
# ticket's own side-effect check refuses it too. After the cut the pipeline
# would open an `if` in one function and close it in another.
#
# So the body runs to the `fi` that closes that `if` — the whole `if/else/fi`
# lives in one function, which is the shape the cut needs, and it is the same
# correction the sibling slice made from the other side: bin/lib/rb/plan.sh
# starts `rb_plan` at the first line AFTER that `fi` (`# Record the branch for
# checkpoint-resume:`), so the two slices meet on that boundary with no line in
# both and no line in neither. Every other slice in this file ends exactly on
# its anchor, byte-verbatim.
# Entry functions, pipeline order: rb_gate_prelude rb_gate_claim_and_workspace rb_gate_overlap
# Reads: ACTIVE_KEY ALERTS ATTEMPT BASE BASE_BRANCH BASE_MAIN BKEY BRANCH BRANCH_SUFFIX BUILD
#   BUILD_ATTEMPT BUILD_SLOTS BUILDER_DIRECT_META BUILDER_DIRECT_ON BUILDER_EXEC CI_LINE
#   CI_N CI_RC CI_REPO CKPT_LOOKUP CKPT_RB CKPT_RB_REST CKPT_RESUME_LINE CKPT_START_POINT
#   CKPT_WIP_N CMSG CWAIT EXECUTE_MODEL FILES FIX_MODEL GATE_MSG GH_AUTH_SLUG
#   GH_ISSUES_REPO GOT HARNESS HENV HF_RC HOTFIX ISSUE_CREATED_AT JOB_BEAT JOB_CLAIM JOB_ID
#   JOB_JSON KEY NB_AT NB_F NB_NOW OV_CAP OV_ENFORCE OV_VERDICT OV_WAKE OV_WHY
#   OVERLAP_DEFER_ENFORCE OVERLAP_DEFER_NOTBEFORE_SECS OVERLAP_SCHED OVERLAP_WAIT_SECS
#   PLAN_MODEL PO_AT PO_MSG PO_NB PO_RC POOL_MODE PROJECT QA_MODEL QDIR QMETA QRC QRFLAG
#   QUEUE_CLAIMED QUEUE_ROW_OK REOPEN_DEMOTE_RATE REOPEN_MIN_SAMPLE REOPEN_RATE_FILE REPO
#   REPO_SLUG RESUME_BUILD REVIEW_MODEL REVIEW_MODEL_T0 RN RO_D RO_MIN RO_N RO_RATE
#   RUNNER_PLAN S SCOPE_BASE SLOTS SLOTWHY STACK_BASE STACK_ON STACK_PARENT_PR STACKED_BUILDS
#   STAGE_TIMING TAKEN TARGET_BRANCH TEST_SELECT TEST_SELECT_EFFECTIVE TICKET WIP WT
# Writes: ACTIVE_KEY ATTEMPT BASE BASE_MAIN BKEY BRANCH BUILDER_DIRECT_META BUILDER_DIRECT_ON
#   CI_LINE CI_N CI_REPO CKPT_LOOKUP CKPT_RB CKPT_START_POINT CKPT_WIP_N CWAIT
#   EXECUTE_MODEL FIX_MODEL GH_AUTH_SLUG GOT HOTFIX ISSUE_CREATED_AT JOB_BEAT JOB_CLAIM
#   JOB_ID JOB_JSON JOB_PHASE_ID JOBS_TIMEOUT NB_AT NB_F NB_NOW OV_CAP OV_WAKE OV_WHY
#   PLAN_MODEL PO_AT PO_MSG QA_MODEL QDIR QMETA QRFLAG QUEUE_CLAIMED QUEUE_ROW_OK
#   REOPEN_HOT REOPEN_NOTE REOPEN_RATE_FILE REVIEW_MODEL REVIEW_MODEL_T0 RN RO_AT RO_D
#   RO_MIN RO_N RO_RATE RO_ROW RO_SRC SLOTS SLOTWHY SPR_HOW SPR_N SPR_ST SPR_URL SQUASH_OK STACK_NOTE STACK_ON STACK_PARENT_PR TAKEN TARGET_BRANCH
#   TEST_SELECT_EFFECTIVE WIP
# shellcheck shell=bash

rb_gate_prelude() {

# >>> stage timing
# --- How long each section of this pipeline actually took (the operator, 2026-09-14) --
# The reorder below this line is sold on measured numbers — 6-8 minutes between
# the execute push and the review-lens launch, ~10 minutes after the review —
# and until now those numbers came from reading wall-clock stamps out of
# pipeline.log by hand, one build at a time. Nothing in the fleet could answer
# "which section is the dead gap on THIS project" without a person doing
# arithmetic, so the first thing a change that claims to cut 15 minutes owes is
# a way to see whether it did.
#
# One line per section, greppable, machine-readable:
#   STAGE-TIMING <stage> start=<epoch> end=<epoch> secs=<n>
#
# INSTRUMENTATION, NOT BEHAVIOUR. It writes nothing but pipeline.log lines, and
# STAGE_TIMING=0 silences it — so a box that wants today's log byte-for-byte
# sets that alongside GATES_PARALLEL=0 and gets exactly the file it had. The two
# knobs are separate ON PURPOSE: the timing is what proves (or disproves) the
# reorder, so turning the reorder off must not also blind the comparison.
#
# No global stack: the caller holds its own t0. Nested and overlapping stages
# (the read-only lane runs INSIDE the lens stage) therefore cost nothing to
# record, where a single "current stage" variable would have had them clobber
# each other. Never fails a build — a stage that cannot be timed is a missing
# log line, not a stopped pipeline.
STAGE_START() { date +%s; }
STAGE_END() { # STAGE_END <stage> <t0>
  [ "${STAGE_TIMING:-1}" = 0 ] && return 0
  local t1; t1=$(date +%s)
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  echo "$(STAMP) [$PROJECT/$KEY] STAGE-TIMING $1 start=$2 end=$t1 secs=$(( t1 - $2 ))" >> "$BUILD/pipeline.log"
  return 0
}
# <<< stage timing

# --- The per-ticket test-file contract (#580) ----------------------------------
# Test files are the fleet's largest merge-conflict surface, and the fix is "a
# ticket adds its OWN test file". The spelling of that rule lives in one lib so
# the planner sentence, the claim-list rewrite and the executor note cannot
# drift apart. Sourced fail-open: every consumer below is guarded with
# `command -v th_enabled`, so a box whose harness predates the lib runs
# byte-identically to today.
# shellcheck source=bin/lib/test-home-lib.sh
[ -r "$HARNESS/bin/lib/test-home-lib.sh" ] && . "$HARNESS/bin/lib/test-home-lib.sh" 2>/dev/null

# >>> harness suite run (tests/parallel-lenses-test.sh, tests/head-bound-approval-test.sh and tests/headbound-outcome-test.sh source this block)
# --- The ONE place this harness runs the repo's own suite (2026-09-17) -------
# Three sites re-ran it inline — before the lenses read the diff, after the
# merged fix round, and on a moved head — each carrying its own copy of the
# script pick and its own log line. They are one function now, so the phase is
# named in the log, the minutes land in STAGE-TIMING, and the per-diff selection
# seam has exactly one place to live.
#
# NOTHING IS SELECTED TODAY. TEST_SELECT_EFFECTIVE resolves to 0 unless an
# operator sets TEST_SELECT, and bin/lib/test-select.sh is a stub that answers
# FULL until the selector child replaces its body — so every call here runs the
# whole suite, exactly as the three inline blocks did.

# Is per-diff test selection on for THIS build? Resolved here rather than at
# env-sourcing time because the default rule reads the repo CHECKOUT, and the
# checkout is not the cwd when env/global.env is sourced. Never fails a build:
# every probe is guarded and this always returns 0.
TEST_SELECT_RESOLVE() {
  local why bp
  if [ -n "${TEST_SELECT+set}" ]; then
    # Read in the shapes people actually write in an env file, and a typo says so
    # rather than quietly turning selection ON — same contract as the gate flags.
    case "$(printf '%s' "$TEST_SELECT" | tr '[:upper:]' '[:lower:]')" in
      1|true|yes|on)  TEST_SELECT_EFFECTIVE=1; why="TEST_SELECT=$TEST_SELECT" ;;
      0|false|no|off) TEST_SELECT_EFFECTIVE=0; why="TEST_SELECT=$TEST_SELECT" ;;
      *) TEST_SELECT_EFFECTIVE=0
         why="TEST_SELECT='$TEST_SELECT' is not an on/off value"
         echo "$(STAMP) [$PROJECT/$KEY] TEST_SELECT='$TEST_SELECT' is not a recognized on/off value — treating as OFF (full suite)" >> "${ALERTS:-$HARNESS/logs/ALERTS.log}" ;;
    esac
  else
    # The default: only a GitHub-Issues project whose checkout carries a
    # selection map. A missing fleet-conf.sh or a project with no row answers
    # nothing, which is "not that kind of project" — never a reason to select.
    bp=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
    if [ "$bp" = "-" ] && { [ -f tests/impact-map.json ] || [ -f tests/static-guards.txt ] || [ -d tests/static-guards ]; }; then
      TEST_SELECT_EFFECTIVE=1; why="default: GitHub-Issues project with a selection map in tests/"
    else
      TEST_SELECT_EFFECTIVE=0; why="default: not a GitHub-Issues project with a selection map in tests/"
    fi
  fi
  echo "$(STAMP) [$PROJECT/$KEY] TEST-SELECT effective=$TEST_SELECT_EFFECTIVE ($why)" >> "$BUILD/pipeline.log"
  return 0
}

# RB_TOKEN_REDACT <file> — scrub GitHub-token shapes out of a build file before
# a lens, evidence.md or a PR reads it (BH-6672: a suite printed the box's real
# App token into harness-suite). bin/lib/token-redact.sh does the work and
# fails closed. A harness with no lib leaves the file as written and says so in
# pipeline.log. Always returns 0: a scrub never stops a build.
RB_TOKEN_REDACT() {
  local f="$1"
  if ! command -v token_redact_file >/dev/null 2>&1; then
    if [ -r "$HARNESS/bin/lib/token-redact.sh" ]; then
      # shellcheck source=bin/lib/token-redact.sh
      . "$HARNESS/bin/lib/token-redact.sh"
    else
      echo "$(STAMP) [$PROJECT/$KEY] token-redact: bin/lib/token-redact.sh missing — $f not scrubbed" >> "$BUILD/pipeline.log"
      return 0
    fi
  fi
  token_redact_file "$f" \
    || echo "$(STAMP) [$PROJECT/$KEY] token-redact: could not scrub $f — its output is withheld" >> "$BUILD/pipeline.log"
  return 0
}

# HARNESS_SUITE_RUN <outfile-name> <phase: lenses|fix|head>
# Runs the repo's suite, appends it to $BUILD/<outfile-name>, and records what
# ran. Always returns 0: a red suite is EVIDENCE the reviewer reads, never a
# reason this script stops.
HARNESS_SUITE_RUN() {
  local outfile="$1" phase="$2" script mode rc t0 stage reason prelude
  local pgenv=()
  local sel="$BUILD/test-select-$phase.txt" err="$BUILD/test-select-$phase.err"
  local FILES=()
  # The script pick, unchanged from the three inline sites. A repo with no test
  # script is recorded honestly and never treated as green — and it stops here,
  # before anything asks fleet.conf or the selector about a suite that does not
  # exist.
  if grep -q '"test:unit"' package.json 2>/dev/null; then script=test:unit
  elif grep -q '"test"' package.json 2>/dev/null; then script=test
  elif [ -x bin/test-impact-gate.sh ]; then
    # A repo whose suites are not npm's and which carries its own impact gate
    # (cromford: bash suites, no package.json). Until BH-1524 this fell to
    # `no-test-script`, so a pool build of the harness pushed having run NO
    # suite, and every pinned-contract suite was first run by CI, a round late.
    # The gate is the selection: TEST_SELECT does not narrow it further, and it
    # leaves what is past its cap to CI, by name, in the output below.
    HARNESS_IMPACT_GATE_RUN "$outfile" "$phase"
    return 0
  else
    echo "HARNESS_EXIT: no-test-script" > "$BUILD/$outfile"
    return 0
  fi
  [ -n "${TEST_SELECT_EFFECTIVE:-}" ] || TEST_SELECT_RESOLVE
  if [ "${TEST_SELECT_EFFECTIVE:-0}" = 1 ]; then
    # FAIL-SAFE BY CONSTRUCTION: only rc 0 with a non-empty list narrows the run.
    # A selector that is missing (rc 127 during a harness-sync window), crashed,
    # or declined answers FULL, and the reason it gave rides in the mode string
    # so nobody reads a degraded run as a selected one.
    "$HARNESS/bin/lib/test-select.sh" . "${SCOPE_BASE:-$BASE}" HEAD > "$sel" 2> "$err"; rc=$?
    if [ "$rc" = 0 ] && [ -s "$sel" ]; then
      mapfile -t FILES < "$sel"
      mode="selected ${#FILES[@]} of the suite"
    else
      reason=$(head -1 "$err" 2>/dev/null)
      if [ -n "$reason" ];  then mode="full ($reason)"
      elif [ "$rc" = 0 ];   then mode="full (empty selection)"
      else                       mode="full (selector rc=$rc, no reason given)"
      fi
    fi
  else
    mode="full (TEST_SELECT=0)"
  fi
  # The file header and the log line come from the SAME variable, so the record
  # in the build dir and the record in pipeline.log can never disagree.
  echo "HARNESS_SUITE: $mode — npm run $script" > "$BUILD/$outfile"
  echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase (npm run $script) $mode" >> "$BUILD/pipeline.log"
  # command -v, because a block test may source this block without the timing
  # one. A stage that cannot be timed is a missing log line, never a stopped run.
  t0=""; command -v STAGE_START >/dev/null 2>&1 && t0=$(STAGE_START)
  # THE PRELUDE (BH-1955). A prisma repo's suite imports the generated client,
  # which a fresh checkout does not have, so a unit run without it is red for a
  # reason no diff caused. Unpiped, rc recorded as the number it is; the suite
  # runs after it whatever it returned — a failed generate is evidence in this
  # file, never a stop and never a green.
  if [ -f prisma/schema.prisma ] || [ -d prisma/schema ]; then
    timeout 300 npx prisma generate >> "$BUILD/$outfile" 2>&1; rc=$?
    prelude="npx prisma generate (rc=$rc)"
  else
    prelude="none (no prisma schema)"
  fi
  echo "HARNESS_PRELUDE: $prelude" >> "$BUILD/$outfile"
  echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase prelude: $prelude" >> "$BUILD/pipeline.log"
  # THE THROWAWAY POSTGRES (BH-5962). A project with the fly-pool knob
  # POOL_TEST_POSTGRES=1 gets a local Postgres for this run only (bin/lib/pg-test.sh):
  # DATABASE_URL and DIRECT_URL reach the setup script and the suite, never the rest
  # of the build, always 127.0.0.1, and every other exported DB-address name is unset
  # for those two children (pgt_env). Off, or no lib: nothing here runs.
  if { command -v pgt_enabled >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/pg-test.sh" ] && . "$HARNESS/bin/lib/pg-test.sh"; }; } && pgt_enabled; then
    if pgt_start "$BUILD/$outfile"; then
      pgt_setup "$BUILD/$outfile"
      pgt_env && pgenv=("${PGT_ENV[@]}")
    fi
    echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase postgres: $(grep '^HARNESS_PG: ' "$BUILD/$outfile" | tail -1)" >> "$BUILD/pipeline.log"
  fi
  # Unpiped, and HARNESS_EXIT written only AFTER the run returns: a pre-stamped
  # exit code is a claim, and 124 (timeout) and 127 (no npm) must land as the
  # numbers they are.
  if [ "${#FILES[@]}" -gt 0 ]; then
    ${pgenv[@]+"${pgenv[@]}"} timeout 1500 npm run "$script" -- "${FILES[@]}" >> "$BUILD/$outfile" 2>&1; rc=$?
  else
    ${pgenv[@]+"${pgenv[@]}"} timeout 1500 npm run "$script" >> "$BUILD/$outfile" 2>&1; rc=$?
  fi
  # The teardown runs on every suite exit (green, red, 124), before HARNESS_EXIT.
  [ -n "${PGT_DIR:-}" ] && pgt_stop "$BUILD/$outfile"
  RB_TOKEN_REDACT "$BUILD/$outfile"
  echo "HARNESS_EXIT: $rc" >> "$BUILD/$outfile"
  case "$phase" in lenses) stage=suite ;; *) stage="suite-$phase" ;; esac
  command -v STAGE_END >/dev/null 2>&1 && STAGE_END "$stage" "$t0"
  return 0
}

# HARNESS_IMPACT_GATE_RUN <outfile-name> <phase> — HARNESS_SUITE_RUN's arm for
# a checkout that carries bin/test-impact-gate.sh. Same record shape as the npm
# arm: a HARNESS_SUITE header, the gate's own output, and HARNESS_EXIT written
# only after it returns. 2 (no selection) lands as the number it is. Two exits
# are written `could-not-run` — not green, and not a red suite either, the same
# class as `no-test-script`; a number there would read as failing tests and
# block every build on a box that merely lacks a tool, or ran long:
#   125  the gate's runner could not start (no setpriv, a setpriv that cannot
#        switch to nobody, a snapshot that would not build)
#   124  this stage's timeout killed it mid-run (#1541 review I2). The gate
#        stops STARTING suites at its own budget, well inside this timeout, so
#        124 means one suite overran. The suites that finished are listed from
#        the gate's own `done` lines, and the rest were never run.
# THE RULES PACK (BH-3513). A checkout with an executable bin/rules-pack.sh runs
# it FIRST, outside the gate's 1500 s timeout (its own is 3x RULES_PACK_BUDGET_S),
# and records a `RULES_PACK: <state>` line plus up to 40 findings. The suites it
# ran (its --out suites.txt) are dropped from the gate with --skip-suites, only
# when it actually ran. Red folds into HARNESS_EXIT only on a gate rc 0 (1);
# could-not-run never changes the gate rc. No pack: byte-identical to before.
# GITLEAKS_REQUIRED=1 (BH-5789) rides on both: on a box with no gitleaks the leak
# suite is red, never a skip, so a fixture leak is found here and not in the queue.
HARNESS_IMPACT_GATE_RUN() {
  local outfile="$1" phase="$2" base="${SCOPE_BASE:-$BASE}" rc t0 stage prc pst="" pel p0 budget rpo skip=() fm
  echo "HARNESS_SUITE: impact gate — bin/test-impact-gate.sh --base $base" > "$BUILD/$outfile"
  echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase (bin/test-impact-gate.sh --base $base)" >> "$BUILD/pipeline.log"
  if [ -x bin/rules-pack.sh ]; then
    budget=60; command -v rules_pack_budget >/dev/null 2>&1 && budget=$(rules_pack_budget)
    rpo="$BUILD/rules-pack-$phase"; rm -rf -- "${rpo:?}"
    p0=$(date +%s)
    GITLEAKS_REQUIRED=1 timeout $((3 * budget)) bin/rules-pack.sh --tree . --base "$base" --out "$rpo" > "$rpo.findings" 2>> "$BUILD/$outfile"; prc=$?
    pel=$(( $(date +%s) - p0 ))
    echo "$(STAMP) [$PROJECT/$KEY] HARNESS-VERIFY $phase rules pack rc=$prc" >> "$BUILD/pipeline.log"
    case "$prc" in
      0) pst=clean ;;
      1) if [ -s "$rpo.findings" ]; then pst=red; else pst=could-not-run; fi ;;
      *) pst=could-not-run ;;
    esac
    { echo "RULES_PACK: $pst (rc $prc, ${pel}s of ${budget}s)"; head -40 "$rpo.findings"; } >> "$BUILD/$outfile"
    [ "$pst" != could-not-run ] && [ -s "$rpo/suites.txt" ] && skip=(--skip-suites "$rpo/suites.txt")
  fi
  t0=""; command -v STAGE_START >/dev/null 2>&1 && t0=$(STAGE_START)
  export SUITE_REUSE_RUN_KEY="$(basename "$BUILD")-gate-$phase-$(date +%s)"
  # BH-6459: the whole-repo suites run on HEAD merged with fresh main. The
  # fly-pool knob; anything but 0 or 1 is 1, and no resolver is 1.
  fm=1; command -v lane_knob >/dev/null 2>&1 && fm=$(lane_knob fly-pool TEST_IMPACT_GATE_FRESH_MAIN "$PROJECT" 2>/dev/null)
  case "$fm" in 0|1) ;; *) fm=1 ;; esac
  TEST_IMPACT_GATE_FRESH_MAIN="$fm" GITLEAKS_REQUIRED=1 timeout 1500 bin/test-impact-gate.sh --base "$base" --project "$PROJECT" --table "$BUILD/impact-gate-$phase.md" ${skip[@]+"${skip[@]}"} >> "$BUILD/$outfile" 2>&1; rc=$?
  if [ "$rc" = 124 ]; then
    { echo "impact-gate: TIMED OUT — the stage's 1500 s timeout killed the gate mid-run. Not a pass and not a failure: these suites completed before it,"
      grep '^impact-gate: done ' "$BUILD/$outfile" | sed 's/^impact-gate: done /  /'
      echo "impact-gate: and every other selected suite was not run (left to CI)."
    } >> "$BUILD/$outfile"
    echo "**Gate: timed out after 1500 s — could-not-run. See harness-suite for the suites that completed.**" > "$BUILD/impact-gate-$phase.md"
    rc=could-not-run
  fi
  [ "$rc" = 125 ] && rc=could-not-run
  [ "$rc" = 0 ] && [ "$pst" = red ] && rc=1
  RB_TOKEN_REDACT "$BUILD/$outfile"
  echo "HARNESS_EXIT: $rc" >> "$BUILD/$outfile"
  case "$phase" in lenses) stage=suite ;; *) stage="suite-$phase" ;; esac
  command -v STAGE_END >/dev/null 2>&1 && STAGE_END "$stage" "$t0"
  return 0
}
# <<< harness suite run

mkdir -p "$BUILD"
BKEY="build:$PROJECT:$KEY:$(basename "$BUILD")"
# The act-time iron-law guard (bin/iron-law-guard.sh) files every blocked
# command as a finding, and a finding with no ticket cannot be routed back to
# the build that produced it. Exported so it reaches the hook through
# agent-call.sh -> claude -> the hook process.
export HARNESS_TICKET="$KEY"
# Resume wiring (2026-08-23): record this build's identity so
# the jobs watchdog's resume pass (bin/lib/resume-dead.sh) can relaunch a
# died-mid-flight pipeline through the
# checkpoints above without parsing dir names. Never fatal.
#
# LANE DECLARATION (#643 slice 1, BH-644). The keys below are ADDITIVE and must
# stay that way: bin/resume-dead-builds.sh reads project/ticket_id/key and
# nothing else, and no reader validates a closed schema. They exist for the
# lane reaper (the BH-643 sibling), which has to know WHICH process is this
# build (pid, plus the pgid so a whole lane of children can be signalled), what
# it is (script), when it started, and when it is late — expected_by is
# started_at + LANE_EXPECTED_SECS, defaulting to 14400 to line up with the 4h
# claims ageout. `job_id` is written further down, once job_open answers; a
# job.json with no job_id means this build never claimed a ledger row.
# On a RESUME this file is rewritten on every re-entry, so pid/pgid/started_at
# describe the process that is alive NOW — which is the liveness signal the
# reaper wants, not the one that died.
# >>> job json
[ -r "$HARNESS/bin/lib/scheduler-conf.sh" ] && . "$HARNESS/bin/lib/scheduler-conf.sh" 2>/dev/null
LANE_EXP=14400
command -v sched_num >/dev/null 2>&1 && LANE_EXP=$(sched_num LANE_EXPECTED_SECS 14400 "$HARNESS")
case "$LANE_EXP" in ''|*[!0-9]*) LANE_EXP=14400 ;; esac
JOB_T0=$(date +%s)
# Field 5 of /proc/<pid>/stat is the process group. Split AFTER the closing
# paren of comm, never on whitespace from the start: a command name with a
# space in it shifts every field otherwise. No /proc (not Linux) -> null.
JOB_PGID=$(sed 's/^.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $3}')
JOB_SCRIPT=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
jq -nc --arg p "$PROJECT" --arg t "$TICKET" --arg k "$KEY" --arg ts "$(STAMP)" \
  --arg pid "$$" --arg pgid "$JOB_PGID" --arg sc "$JOB_SCRIPT" \
  --arg t0 "$JOB_T0" --arg exp "$(( JOB_T0 + LANE_EXP ))" \
  '{project:$p,ticket_id:$t,key:$k,created_at:$ts,
    pid:($pid|tonumber? // null),pgid:($pgid|tonumber? // null),script:$sc,
    started_at:($t0|tonumber),expected_by:($exp|tonumber)}' \
  > "$BUILD/job.json" 2>/dev/null || true
# <<< job json

# --- Context acceptance gate (the operator, 2026-08-14) --------------------------------
# FIRST thing, before the queue hop, the worktree, the plan — anything. A build
# under rules that disagree with the repo is wasted work at best and a bad PR at
# worst, and catching it at PR time means the whole wave already ran. Refuse
# early instead. The gate self-heals rules drift from the checkout and refuses
# only what a human must resolve. Kill switch: flags/context-gate-disabled.
#
# rc 3 = the harness checkout was behind and the gate just synced it. This
# process is running the OLD run-build.sh and stage modules, so it re-execs
# itself ONCE on the fresh ones, in the same build dir, instead of refusing and
# waiting a ~20 min watcher tick that found the checkout behind again every time
# main merged (BH-1174/BH-1795, 2026-09-28). No lock, claim, job row or worktree
# exists yet, and fds 7-9 are closed on entry, so exec carries nothing across.
# RB_CTX_REEXEC_DONE (from `# >>> ctx reexec` in bin/run-build.sh) tells the
# gate it is the second pass — it proceeds on a still-behind checkout — and a
# second rc 3 is refused here, so there is never an exec loop.
# >>> context gate
GATE_MSG=$(RB_CTX_REEXEC="${RB_CTX_REEXEC_DONE:-}" "$HARNESS/bin/context-gate.sh" "$PROJECT" "$BUILD" "$REPO" 2>&1); GATE_RC=$?
if [ "$GATE_RC" = 3 ] && [ -z "${RB_CTX_REEXEC_DONE:-}" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] context gate: $GATE_MSG — re-exec run-build.sh on the fresh harness" >> "$BUILD/pipeline.log"
  export RB_CTX_REEXEC=1 RB_CTX_REEXEC_BUILD="$BUILD"
  # execfail: without it a failed exec ends this non-interactive shell (rc
  # 126/127) and the refusal below never runs (review of #3297).
  shopt -s execfail
  exec "$HARNESS/bin/run-build.sh" "$PROJECT" "$TICKET" "$KEY"
  # exec returns only when it could not run the new image.
  shopt -u execfail
  unset RB_CTX_REEXEC RB_CTX_REEXEC_BUILD
  GATE_MSG="re-exec of the fresh run-build.sh failed — $GATE_MSG"
fi
if [ "$GATE_RC" != 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] context gate REFUSED: $GATE_MSG" >> "$BUILD/pipeline.log"
  RESULT "BUILD_REFUSED context drift — $GATE_MSG"
  exit 3
fi
echo "$(STAMP) [$PROJECT/$KEY] context gate: $GATE_MSG" >> "$BUILD/pipeline.log"
# <<< context gate

# >>> ticket identity guard
# --- ONE IDENTITY PER TICKET (BH-866) -----------------------------------------
# A board ticket id may have ONE build identity. Everything downstream dedupes
# on the KEY — job_open claims (project, KEY, kind) and the worker's
# double-build guard matches on that tuple — so a decomposed child launched
# under its `<PARENT>.<n>` TITLE LABEL while the board's own key for the same
# ticket is something else is invisible to every existing guard: TK-1766.5 and
# TK-1789 were one board ticket, two claims, two plans, two PRs.
#
# HERE, and not lower down, on purpose. This sits above `# >>> hotfix detect`,
# so it precedes the Fly enqueue (both launch routes refuse identically), the
# wip gate, the slot flock and the queue claim. A refused duplicate therefore
# takes no lock, holds no slot, writes no queue row and spends no model tokens —
# it is a dedupe, never a queue (the operator, 2026-09-13).
#
# The word is the existing BUILD_DEFERRED (exit 3): _job_finish parks it and the
# triage tick re-offers the ticket, which is what should happen the moment the
# other build finishes or its PR closes. Knob: TICKET_IDENTITY_GUARD=0 to skip.
#
# AND THE KNOB IS READ FROM THE FILE IT IS DOCUMENTED IN. env/global.env is not
# sourced until ~300 lines below this block, so an operator who sets the switch
# where env-templates/global.env.example and the verification map tell them to
# would have been turning off nothing at all — a kill switch that silently does
# not work is worse than no kill switch. An exported variable still wins; the
# file is only consulted when the environment is silent.
if [ -z "${TICKET_IDENTITY_GUARD:-}" ] && [ -r "$HENV/global.env" ]; then
  TICKET_IDENTITY_GUARD=$(sed -n 's/^[[:space:]]*TICKET_IDENTITY_GUARD=["'"'"']*\([^"'"'"'#[:space:]]*\).*/\1/p' \
    "$HENV/global.env" 2>/dev/null | tail -1)
fi
if [ "${TICKET_IDENTITY_GUARD:-1}" = 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] identity guard: off (TICKET_IDENTITY_GUARD=0)" >> "$BUILD/pipeline.log"
elif [ -r "$HARNESS/bin/lib/ticket-identity.sh" ]; then
  # shellcheck source=bin/jobs-client.sh
  [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
  # shellcheck source=bin/lib/ticket-identity.sh
  . "$HARNESS/bin/lib/ticket-identity.sh" 2>/dev/null
  TI_LINE=""; TI_RC=2
  if command -v ticket_identity_conflict >/dev/null 2>&1; then
    TI_LINE=$(ticket_identity_conflict "$HARNESS" "$PROJECT" "$TICKET" "$KEY" 2>/dev/null); TI_RC=$?
  fi
  if [ "$TI_RC" = 0 ]; then
    IFS=$'\t' read -r TI_KEY TI_SRC TI_STATE <<<"$TI_LINE"
    TI_SAY=$(ticket_identity_say "$TICKET" "$TI_KEY" "$TI_SRC" "$TI_STATE")
    echo "$(STAMP) [$PROJECT/$KEY] identity guard REFUSED: $TI_SAY" >> "$BUILD/pipeline.log"
    mkdir -p "$HARNESS/logs" 2>/dev/null
    echo "$(STAMP) [$PROJECT/$KEY] identity guard REFUSED: $TI_SAY" >> "$HARNESS/logs/$PROJECT.log"
    # Stopping is an alert, not a whisper — but a BOUNDED one (D21): the queue
    # re-offers this ticket every tick, so the alert is once per
    # (project, ticket, other key, day) and not once per tick.
    TI_FLAG="$HARNESS/flags/alerted-identity-$PROJECT-$TICKET-$TI_KEY-$(date -u +%Y%m%d)"
    if [ ! -e "$TI_FLAG" ]; then
      mkdir -p "$HARNESS/flags" 2>/dev/null && : > "$TI_FLAG" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] duplicate identity refused: $TI_SAY — one identity per ticket. Launch it under $TI_KEY, or let that build finish; nothing is queued." >> "$ALERTS"
    fi
    RESULT "BUILD_DEFERRED duplicate identity: $TI_SAY — one identity per ticket; launch it under $TI_KEY or wait for that build"
    exit 3
  elif [ "$TI_RC" = 2 ]; then
    # Fail-open, and say so. A worker outage that refused every launch would
    # stop the fleet, which is a worse failure than the duplicate.
    echo "$(STAMP) [$PROJECT/$KEY] identity guard could not consult the ledger — proceeding on local evidence only" >> "$BUILD/pipeline.log"
  fi
fi
# <<< ticket identity guard

# >>> hotfix detect
# --- Is this the emergency ticket? (#368, hotfix lane 1/3) ---------------------
# BEFORE the queue hop, because the answer has to RIDE the job: a pool machine
# is two hops from the issue that carries the label, and asking GitHub again
# from there is a second chance to get a different answer than the watcher did.
# HOTFIX=1 in the environment wins (fly/builder-runner.sh exports it from the
# job file, and a hand-run can force it); otherwise the label is read once,
# here, from the issue. Any failure — no lib, no gh, a board project, a
# non-numeric key — is "not a hotfix", which is exactly today's behaviour.
HOTFIX="${HOTFIX:-}"
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
if command -v hotfix_lane_on >/dev/null 2>&1 && [ "$(hotfix_lane_on "$HARNESS")" = 0 ]; then
  HOTFIX=""
elif [ -z "$HOTFIX" ] && command -v hotfix_key_is >/dev/null 2>&1; then
  # THREE answers, not two. rc 2 is the lib saying the GitHub read itself
  # failed, which is NOT "ordinary ticket" — a dead token would answer "not
  # urgent" for every ticket in the fleet and nothing would say a word. So rc 2
  # buys exactly one retry with the token unset (gh falls back to its stored
  # auth), in a SUBSHELL because a shell function cannot be run through
  # `env -u` and the parent's token must survive. Still 2 -> say so and build
  # as plain: the check that is supposed to make an emergency faster must never
  # be the thing that stops it.
  hotfix_key_is "$HARNESS" "$PROJECT" "$KEY"; HF_RC=$?
  if [ "$HF_RC" = 2 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] HOTFIX check could not be made (gh failed) - retrying once without GH_TOKEN" >> "$BUILD/pipeline.log"
    ( unset GH_TOKEN; hotfix_key_is "$HARNESS" "$PROJECT" "$KEY" ); HF_RC=$?
    [ "$HF_RC" = 2 ] && echo "$(STAMP) [$PROJECT/$KEY] hotfix check unavailable, building as plain" >> "$BUILD/pipeline.log"
  fi
  [ "$HF_RC" = 0 ] && HOTFIX=1
fi
if [ "$HOTFIX" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] HOTFIX: this ticket carries the $(hotfix_label "$HARNESS") label — cap-exempt, and its PR will carry the label too" >> "$BUILD/pipeline.log"
  # Backstop for the triage-tick announcement (bin/hotfix-seen.sh): the marker
  # dedupes, so whichever of the two sees it first is the one that speaks.
  # QUEUED, not built: on a Fly lane this fires at the enqueue hop, minutes
  # before a machine picks the job up, so the text states the rung it has.
  hotfix_announce "$HARNESS" "$PROJECT" "$KEY" seen "$KEY queued for build" >/dev/null 2>&1 || true
fi
# <<< hotfix detect

# >>> closed issue skip
# --- Is this ticket already shipped? (BH-637 §3a) ------------------------------
# `ai-build` is the handoff label and nothing took it off when a merge closed the
# issue, so the label outlived the work and kept offering it — each re-offer a
# full pool build spent rebuilding shipped work. The label is also not enough to
# fix on its own: humans close issues by hand, and that close strips nothing. So
# the state is read LIVE, here.
#
# HERE, because this script is the only mechanical enqueue point in the fleet —
# the triage session, bin/up10-lane.sh, bin/unblocked-children.sh, the
# READY-QUEUE tick, the blocked-resolver rebuild and fly/builder-runner.sh all
# funnel through it — and ABOVE the enqueue gate below, so a refused build never
# writes a queue row, never takes a build slot and never takes the per-key lock.
#
# BUILD_REFUSED, not BUILD_DEFERRED: a deferral is re-offered by the pool up to
# DEFER_MAX times and reads as `parked` in the ledger. A closed issue is not
# "not now", it is "never", and BUILD_REFUSED is the terminal the sweep SOP
# already owns — one ALERTS line naming the ticket and the reason, which is
# exactly the "the label is lying on #n" signal an operator wants.
#
# FAIL-OPEN: no lib, a board project, a non-numeric key or a gh that failed all
# fall through and build exactly as today. A dead token must not refuse every
# build in the fleet.
# shellcheck source=bin/lib/issue-state-lib.sh
if [ -r "$(dirname "$0")/lib/issue-state-lib.sh" ]; then . "$(dirname "$0")/lib/issue-state-lib.sh" 2>/dev/null
elif [ -r "$HARNESS/bin/lib/issue-state-lib.sh" ]; then . "$HARNESS/bin/lib/issue-state-lib.sh" 2>/dev/null
fi
if command -v issue_is_closed >/dev/null 2>&1 \
   && [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  CI_N=$(printf '%s' "$KEY" | sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p')
  CI_REPO="${GH_ISSUES_REPO:-$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)}"
  if [ -n "$CI_N" ] && [ -n "$CI_REPO" ]; then
    # BH-1735: the read keeps the issue JSON in the build dir, and the created-at
    # stamp below is served from it — one GET of this issue per enqueue, not two.
    CI_MEMO=""; command -v issue_memo_file >/dev/null 2>&1 && CI_MEMO=$(issue_memo_file "$BUILD" "$CI_REPO" "$CI_N")
    issue_is_closed "$CI_REPO" "$CI_N" "$HARNESS" "$CI_MEMO"; CI_RC=$?
    if [ "$CI_RC" = 0 ]; then
      CI_LINE="SKIP_CLOSED #$CI_N — issue is CLOSED on $CI_REPO; the ai-build label is stale, nothing enqueued"
      echo "$(STAMP) [$PROJECT/$KEY] $CI_LINE" >> "$BUILD/pipeline.log"
      mkdir -p "$HARNESS/logs" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] $CI_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
      RESULT "BUILD_REFUSED SKIP_CLOSED #$CI_N — issue is CLOSED on $CI_REPO; nothing enqueued, nothing built"
      exit 3
    elif [ "$CI_RC" = 2 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] closed-issue check unavailable (gh failed) — building as today" >> "$BUILD/pipeline.log"
    fi
  fi
fi
# <<< closed issue skip

# >>> held issue skip
# --- A HELD TICKET IS NEVER QUEUED, AND A BUILD IT CATCHES STANDS DOWN (BH-1526)
# A body `HOLD:` line is how the lead reserves a ticket for a Mac build, and
# until this block only bin/fly-pool.sh's spawn gate read it: this script, the
# fleet's one mechanical enqueue point, queued BH-1485 four minutes after it was
# filed, and a HOLD typed 25 minutes into a pool build did not stop the box.
# Same place and same reasoning as the closed-issue skip above: a held ticket
# writes no queue row, takes no slot and spends no model tokens.
#
# HOLD_STAGE_CHECK is ALSO the mid-build half. It is called here and again at
# each stage boundary YIELD_CHECK uses (plan, execute, review) plus one last
# time before the PR is opened, so a ticket held while its build runs stops at
# the next boundary and never opens a PR. TOP LEVEL ONLY, like YIELD_CHECK: the
# exit 3 is the point and a subshell would swallow it. BUILD_DEFERRED, not
# REFUSED: a hold is "not now" and RESUME on the ticket is the way back, and the
# pool's own spawn gate keeps a held row queued until then.
#
# The reading is bin/lib/hold.sh's (through bin/lib/ticket-ownership.sh), so a
# closed or de-labelled issue is NOT a hold here. FAIL-OPEN on a read that did
# not answer: one log line, and the build goes on exactly as today.
# shellcheck source=bin/lib/ticket-ownership.sh
if [ -r "$(dirname "$0")/lib/ticket-ownership.sh" ]; then . "$(dirname "$0")/lib/ticket-ownership.sh" 2>/dev/null
elif [ -r "$HARNESS/bin/lib/ticket-ownership.sh" ]; then . "$HARNESS/bin/lib/ticket-ownership.sh" 2>/dev/null
fi
# THE FACTORY STOP PARKS A BUILD AT THE SAME BOUNDARIES (BH-3687). While settings
# row switch.factory-stop is on, every HOLD_STAGE_CHECK call parks the build:
# the queue boundary refuses a new launch whoever launched it, and a build in
# flight stops at its next stage. BUILD_DEFERRED + exit 3 is the park, which
# _job_finish already maps back to queued, so the next tick re-offers the key.
# bin/lib/factory-stop.sh is the only reader; no row reads as NOT stopped, and a
# missing lib builds as today with one pipeline.log line.
# shellcheck source=bin/lib/factory-stop.sh
if ! command -v factory_stopped >/dev/null 2>&1; then
  if [ -r "$(dirname "$0")/lib/factory-stop.sh" ]; then . "$(dirname "$0")/lib/factory-stop.sh" 2>/dev/null
  elif [ -r "${HARNESS:-}/bin/lib/factory-stop.sh" ]; then . "${HARNESS:-}/bin/lib/factory-stop.sh" 2>/dev/null
  fi
fi
FACTORY_STOP_CHECK() { # FACTORY_STOP_CHECK <stage>
  if ! command -v factory_stopped >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT/$KEY] factory-stop lib not loaded at $1 — building as today" >> "$BUILD/pipeline.log"
    return 0
  fi
  if factory_stopped; then
    echo "$(STAMP) [$PROJECT/$KEY] FACTORY-STOP at $1: switch.factory-stop is on — parking" >> "$BUILD/pipeline.log"
    RESULT "BUILD_DEFERRED factory-stop at $1 — bin/factory-stop.sh off resumes; the next tick re-offers $KEY"
    exit 3
  fi
  return 0
}
HOLD_STAGE_CHECK() { # HOLD_STAGE_CHECK <stage>
  FACTORY_STOP_CHECK "$1"
  command -v to_build_hold >/dev/null 2>&1 || return 0
  local v rc
  v=$(to_build_hold "$PROJECT" "$TICKET" "$KEY"); rc=$?
  if [ "$rc" = 0 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] HELD at $1: ${v#*	} — standing down, nothing is queued and no PR is opened" >> "$BUILD/pipeline.log"
    RESULT "BUILD_DEFERRED held at $1 — the ticket says ${v#*	}; RESUME on the ticket lifts it"
    exit 3
  elif [ "$rc" = 2 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] hold check unreadable at $1 (${v#*	}) — building as today" >> "$BUILD/pipeline.log"
  fi
  return 0
}
HOLD_STAGE_CHECK queue
# <<< held issue skip

# >>> abandoned ticket skip
# --- AN ABANDONED TICKET IS NEVER QUEUED AGAIN BY A WATCHER (2026-09-23) -------
# bin/blocked-resolver.sh ends a ladder that could not land a ticket with an
# ABANDONED outcome: PR closed, queue row failed, one ALERTS line. That record
# lives on the hub. A watcher whose triage still sees the ticket open runs this
# script, and queue_put below turns the failed row straight back into a queued
# one — BH-1681 was rebuilt at 19:04 and again at 00:06 after its ABANDONED
# (requested_by box-small), each rebuild a pool machine.
#
# So the fleet ledger carries the outcome (br_abandon writes `abandoned
# "<project> <KEY>"`), and this reads it before anything is queued. A queue row
# that is still failed with the resolver's ABANDONED reason says the same thing
# for an abandon recorded before the ledger row existed. An operator lifts it
# with `jobs-client.sh ledger-put abandoned "<project> <KEY>" released`.
# BUILD_REFUSED, like the closed-issue skip above: "never", not "not now".
# FAIL-OPEN: no client, an outage, or no row at all builds exactly as today.
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
AB_ST=""
if command -v job_ledger_get >/dev/null 2>&1; then
  AB_ST=$(job_ledger_get abandoned "$PROJECT $KEY" 2>/dev/null) || AB_ST=""
fi
if [ -z "$AB_ST" ] && command -v queue_row >/dev/null 2>&1; then
  AB_ROW=$(queue_row "$PROJECT" "$KEY" 2>/dev/null) || AB_ROW=""
  case "$(printf '%s' "$AB_ROW" | cut -f1)|$(printf '%s' "$AB_ROW" | cut -f5)" in
    "failed|ABANDONED by the blocked-resolver"*) AB_ST=abandoned ;;
  esac
fi
if [ "$AB_ST" = abandoned ]; then
  AB_LINE="SKIP_ABANDONED $KEY — the blocked-resolver ABANDONED this ticket; nothing enqueued, nothing built. Release: jobs-client.sh ledger-put abandoned \"$PROJECT $KEY\" released"
  echo "$(STAMP) [$PROJECT/$KEY] $AB_LINE" >> "$BUILD/pipeline.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] $AB_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
  RESULT "BUILD_REFUSED $AB_LINE"
  exit 3
fi
# <<< abandoned ticket skip

# >>> trigger actor gate (BH-4490)
# --- ONLY A LISTED HUMAN OR THE HARNESS ITSELF MAKES A TICKET BUILDABLE --------
# The trigger is the newest `labeled ai-build` event (GitHub Issues) or the
# newest `status_change` in the ticket's activity (in-app board, only when the
# project has a trigger.actors.<p> row). bin/lib/trigger-actor.sh owns the rule,
# the one-comment-per-episode record (ledger trigger-actor "<p> <KEY>") and the
# kill switch (lane_switch trigger-actor-off). Here for the closed-issue skip's
# reason: every launch path funnels through this script, and above the enqueue
# gate nothing is queued, slotted or locked yet. On a Fly builder it runs again
# at claim time, so a bot that re-labels after the enqueue is caught there.
# BUILD_REFUSED for an ignored trigger ("never, until a listed person triggers
# again"); COMMENTED because the lib already spoke on the ticket, so the sweep
# SOP adds no ALERTS line on a re-offer. BUILD_DEFERRED when the answer cannot
# be read (fail closed: the next tick re-offers). TOP LEVEL ONLY: the exit 3 is
# the point and a subshell would swallow it.
# shellcheck source=bin/lib/trigger-actor.sh
if [ -r "$(dirname "$0")/lib/trigger-actor.sh" ]; then . "$(dirname "$0")/lib/trigger-actor.sh" 2>/dev/null
elif [ -r "$HARNESS/bin/lib/trigger-actor.sh" ]; then . "$HARNESS/bin/lib/trigger-actor.sh" 2>/dev/null
fi
if ! command -v ta_gate >/dev/null 2>&1; then
  PROJECT_2_LINE="trigger-actor lib missing on $(hostname)"
  echo "$(STAMP) [$PROJECT/$KEY] TRIGGER-ACTOR defer: $PROJECT_2_LINE (half-synced bin/?)" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED $PROJECT_2_LINE — the next tick re-offers $KEY"
  exit 3
fi
PROJECT_2_RC=0
ta_gate "$PROJECT" "$KEY" "${TICKET:-}" "$BUILD" || PROJECT_2_RC=$?
if [ "$PROJECT_2_RC" = 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] TRIGGER-ACTOR $PROJECT_2_LINE" >> "$BUILD/pipeline.log"
elif [ "$PROJECT_2_RC" = 1 ]; then
  PROJECT_2_LINE="SKIP_ACTOR $KEY — $PROJECT_2_LINE"
  echo "$(STAMP) [$PROJECT/$KEY] TRIGGER-ACTOR $PROJECT_2_LINE" >> "$BUILD/pipeline.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] $PROJECT_2_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
  RESULT "BUILD_REFUSED $PROJECT_2_LINE"
  touch "$BUILD/COMMENTED"
  exit 3
else
  echo "$(STAMP) [$PROJECT/$KEY] TRIGGER-ACTOR defer: $PROJECT_2_LINE" >> "$BUILD/pipeline.log"
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] TRIGGER-ACTOR defer: $PROJECT_2_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
  RESULT "BUILD_DEFERRED trigger-actor unverifiable ($PROJECT_2_LINE) — the next tick re-offers $KEY"
  exit 3
fi
# <<< trigger actor gate (BH-4490)

# >>> tripwire paused skip
# BH-3481.4 wrote ledger build-tripwire "<p> <KEY>" paused when a build of this
# ticket tripped the mid-build spend tripwire. Since BH-6705 the tripwire never
# stops a build: a trip writes `alerted`, and a leftover `paused` row gets one
# log line and the build runs. Unreadable (rc 2) also builds, with one line.
command -v tw_paused >/dev/null 2>&1 || . "$HARNESS/bin/lib/build-tripwire.sh" 2>/dev/null || true
TW_RC=1
command -v tw_paused >/dev/null 2>&1 && { tw_paused "$PROJECT" "$KEY"; TW_RC=$?; }
if [ "$TW_RC" = 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] tripwire: leftover paused row for $KEY ignored; the tripwire never stops a build (BH-6705)" >> "$BUILD/pipeline.log"
elif [ "$TW_RC" = 2 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] tripwire pause row unreadable; building as today (fail-open)" >> "$BUILD/pipeline.log"
fi
# <<< tripwire paused skip

# >>> dispatch mode gate
# BH-6350: a project in dispatch mode hotfix-only (bin/lib/dispatch-mode.sh)
# starts a build only for a hotfix-labelled or allow-listed ticket. Triage is
# told so by a prompt directive and the fastpath holds the key itself; this is
# the deterministic backstop for every launcher, placed before the budget gate
# and the Fly enqueue, so a held launch takes no claim, no slot and no queue
# row. Admitted without a read: a resume (a fix round of an admitted build) and
# a pool machine (the job was admitted at enqueue or spawn). An unknown label
# read (HF_RC=2) admits, as the hotfix detect block says. BUILD_DEFERRED: the
# next tick re-offers the ticket, and on normal it builds.
if [ "${BUILDER_EXEC:-}" != 1 ] && [ -z "${RESUME_BUILD:-}" ]; then
  # shellcheck source=bin/lib/dispatch-mode.sh
  [ -r "$HARNESS/bin/lib/dispatch-mode.sh" ] && . "$HARNESS/bin/lib/dispatch-mode.sh" 2>/dev/null
  if command -v dm_read >/dev/null 2>&1; then
    dm_read "$PROJECT"
    DM_HFD=0
    if [ "${HOTFIX:-}" = 1 ]; then DM_HFD=1; elif [ "${HF_RC:-}" = 2 ]; then DM_HFD=2; fi
    if ! dm_admit_ticket "${TICKET:-}" "$DM_HFD"; then
      DM_LINE="dispatch mode hotfix-only: $KEY waits (no hotfix label, not on the allow-list)"
      echo "$(STAMP) [$PROJECT/$KEY] $DM_LINE; allow-list: $(dm_allow_text)" >> "$BUILD/pipeline.log"
      mkdir -p "$HARNESS/logs" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] $DM_LINE" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
      RESULT "BUILD_DEFERRED $DM_LINE"
      exit 3
    fi
  fi
fi
# <<< dispatch mode gate

# >>> budget launch gate (BH-4489)
# A project at its day budget cap (settings budget.project.<p>.day_usd, then
# budget.project._default.day_usd), or at the stage-day cap of ANY stage a
# build calls (budget.stage.<s>.day_usd|day_calls for BS_BUILD_STAGES, then
# _default), against D1's llm-spend for the UTC day, starts no new build: no
# queue row, no pool machine, no slot, no claim. Placed before the Fly enqueue
# gate for exactly that. Every stage, not just the first: a build deferred on
# its review cap is not resumed, the ticket is re-offered as a fresh build, and
# without this check every re-offer would buy plan and execute again before
# being refused at review. BUILD_DEFERRED, because the caps reset at 00:00Z;
# bin/fly-pool.sh's pool_lane_failure reads a day-cap deferral as the lane, not
# the ticket, so it is not counted. FAIL-CLOSED here too: an unreadable cap or
# spend defers (counted, like the call gate's own outage deferral), since the
# call gate would refuse the same build mid-way after spending on the stages
# before it. budget-stop-off turns it off. Inert without the jobs client.
#
# THIS IS THE TICKET BOUNDARY (BH-5526). It also checks the fly-pool lane's
# LLM_USD_CAP_DAY (fail open on unknown spend, as llm-gate does everywhere).
# A refusal logs the spend that tripped it and alerts once per (project, UTC
# day). The fly-pool lane's runaway ceiling (spend.ceiling.fly-pool.day_usd,
# BH-5526 C3) is read by the same llm_gate_precall call. When both checks pass it writes $BUILD/ADMITTED, and from then until
# RESULT no day cap refuses a call of this build's own lane (bin/lib/budget-stop.sh
# bs_admitted, bin/lib/llm-gate.sh LLM_GATE_IN_TICKET). A resume of an admitted dir is the
# same ticket in progress, so the caps are not re-applied to it.
# The cost autohalt's hold (flags/spend-hold-<p>, written by bin/pipeline-health.sh
# and bin/cost-local-brake.sh) is read HERE and nowhere else, so a held project
# starts no new build and everything already started finishes. budget-stop-off
# does not lift it; `flag_set spend-hold-<p> off` does.
if [ -n "${RESUME_BUILD:-}" ] && [ -f "$BUILD/ADMITTED" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: resume of an admitted ticket — launch caps not re-applied" >> "$BUILD/pipeline.log"
else
  command -v bs_launch_check >/dev/null 2>&1 || . "$HARNESS/bin/lib/budget-stop.sh" 2>/dev/null || true
  command -v bs_launch_check >/dev/null 2>&1 || bs_launch_check() { return 0; }
  command -v _bs_alert_once >/dev/null 2>&1 || _bs_alert_once() { return 0; }
  BL_RC=0; bs_launch_check "$PROJECT" || BL_RC=$?
  if [ "$BL_RC" = 1 ]; then
    BL_LINE="BUILD_DEFERRED $BS_REFUSE — re-offered next tick; the cap resets at 00:00Z"
    echo "$(STAMP) [$PROJECT/$KEY] $BL_LINE" >> "$BUILD/pipeline.log"
    RESULT "$BL_LINE"
    _bs_alert_once "budget-launch-$PROJECT-$(date -u +%Y%m%d)" "$PROJECT" \
      "[spend-boundary] $PROJECT/$KEY refused at ticket start: $BS_REFUSE. No new build starts for $PROJECT until 00:00Z; builds already running finish."
    exit 3
  elif [ "$BL_RC" = 2 ]; then
    BL_LINE="BUILD_DEFERRED budget-cap-unreadable launch ${BS_REASON:-unknown} — a day budget cap or its spend could not be read; re-offered next tick"
    echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: $BL_LINE" >> "$BUILD/pipeline.log"
    RESULT "$BL_LINE"
    exit 3
  fi
  command -v llm_gate_precall >/dev/null 2>&1 || . "$HARNESS/bin/lib/llm-gate.sh" 2>/dev/null || true
  command -v llm_gate_precall >/dev/null 2>&1 || llm_gate_precall() { return 0; }
  BL_RC=0; AGENT_CALL_LANE=fly-pool llm_gate_precall plan "$PROJECT" || BL_RC=$?
  if [ "$BL_RC" = 2 ]; then
    BL_LINE="BUILD_DEFERRED ${LLM_GATE_REASON:-llm-gate} — refused at ticket start; re-offered next tick; the cap resets at 00:00Z"
    RESULT "$BL_LINE"
    echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: $BL_LINE" >> "$BUILD/pipeline.log"
    # BH-5526 C3: llm-gate already raised the lane's one runaway-ceiling alert.
    case "${LLM_GATE_REASON:-}" in
      spend-ceiling*) ;;
      *) _bs_alert_once "llm-cap-launch-$PROJECT-$(date -u +%Y%m%d)" "$PROJECT" \
           "[spend-boundary] $PROJECT/$KEY refused at ticket start: ${LLM_GATE_REASON:-llm-gate}. No new build starts for $PROJECT until 00:00Z; builds already running finish." ;;
    esac
    exit 3
  fi
  # The hold: the row via flag_active when the client is loaded, and the file
  # either way, so a worker outage answers from the file (rb/pr.sh's shape).
  SH_ON=0
  if command -v flag_active >/dev/null 2>&1 && flag_active "spend-hold-$PROJECT"; then SH_ON=1; fi
  [ -f "$HARNESS/flags/spend-hold-$PROJECT" ] && SH_ON=1
  if [ "$SH_ON" = 1 ]; then
    SH_WHY=$(cat "$HARNESS/flags/spend-hold-$PROJECT" 2>/dev/null)
    [ -n "$SH_WHY" ] || SH_WHY="cost autohalt"
    BL_LINE="BUILD_DEFERRED spend-hold $PROJECT — the cost autohalt holds new builds (lift: bin/jobs-client.sh flag_set spend-hold-$PROJECT off); re-offered next tick"
    RESULT "$BL_LINE"
    echo "$(STAMP) [$PROJECT/$KEY] budget launch gate: $BL_LINE ($SH_WHY)" >> "$BUILD/pipeline.log"
    _bs_alert_once "spend-hold-launch-$PROJECT-$(date -u +%Y%m%d)" "$PROJECT" \
      "[spend-boundary] $PROJECT/$KEY refused at ticket start: the cost autohalt holds $PROJECT (flags/spend-hold-$PROJECT: $SH_WHY). Builds, reviews and merges already running finish."
    exit 3
  fi
  echo "$(STAMP) $KEY" > "$BUILD/ADMITTED" 2>/dev/null || true
fi
# <<< budget launch gate

# --- Fly builder trial (Phase 2): enqueue gate ---------------------------------
# When this project is flagged for the Fly builder AND we are NOT already running
# on a builder (BUILDER_EXEC unset — builders set it), this invocation is a
# WATCHER triage session that should NOT build locally. Instead it writes a job
# file to the HUB's build queue and returns immediately; the hub dispatcher wakes
# the Fly builder and drives the pipeline there. Self-gating: with the flag
# absent this whole block is skipped and behavior is byte-identical to before.
#
# On the hub itself (env/fly.env present) we write the queue file locally; on a
# watcher the ROW is the queue and no file is written at all (#229). HUB_IP used
# to live here for a push that no longer exists — removed 2026-09-11 rather than
# left as the last IP literal in this file.
if { { command -v routing_builder >/dev/null 2>&1 && [ "$(routing_builder "$PROJECT" 2>/dev/null)" != local ]; } || [ -f "$HARNESS/flags/builder-fly-$PROJECT" ]; } && [ -z "${BUILDER_EXEC:-}" ]; then
  QDIR="state/build-queue/$PROJECT"
  ATTEMPT="${BUILD_ATTEMPT:-0}"
  # The kill flag reaches the enqueue too: with stacked builds switched off, a
  # STACK_BASE left in the environment must not ride into the row either. Only
  # the FILE flag is readable here — env/global.env is sourced further down, so
  # a box that wants the env switch sets it where the watcher can see it.
  if [ -f "$HARNESS/flags/stacked-builds-off" ] || [ "${STACKED_BUILDS:-1}" = 0 ]; then STACK_BASE=""; fi
  # STACK_BASE rides the queue entry (2026-09-14, stacked child builds). The
  # watcher that decided this ticket is launchable knows the parent PR's branch;
  # the machine that will actually build it is reached through a job file and a
  # queue row, so the branch has to travel in both. Empty = today's entry, key
  # for key: no field is added and every reader is byte-identical.
  # `hotfix` rides both the file and the row exactly as `stack_base` does, and
  # for the same reason (#368): the machine that will build this ticket is two
  # hops away, and a cap exemption that does not survive the trip is an
  # emergency that queues behind ordinary work on the far side.
  # >>> queue job json
  JOB_JSON=$(jq -nc --arg t "$TICKET" --arg k "$KEY" --argjson a "$ATTEMPT" \
    --arg ts "$(STAMP)" --arg sb "${STACK_BASE:-}" --arg hf "${HOTFIX:-}" \
    '{ticket_id:$t,key:$k,attempt:$a,enqueued_at:$ts}
     + (if $sb == "" then {} else {stack_base:$sb} end)
     + (if $hf == "1" then {hotfix:true} else {} end)')
  QMETA=$(jq -nc --arg sb "${STACK_BASE:-}" --arg hf "${HOTFIX:-}" \
    '(if $sb == "" then {} else {stack_base:$sb} end)
     + (if $hf == "1" then {hotfix:true} else {} end)' 2>/dev/null)
  # Neither set = no meta at all, byte for byte the row this wrote before #368.
  [ "$QMETA" = "{}" ] && QMETA=""
  # <<< queue job json
  # --- The queue as a ROW (2026-09-10, docs/DB-COORDINATION-SPEC.md) ----------
  # WRITE-THROUGH, and the ROW first: this is the only mechanical enqueue point
  # in the fleet, so it is where a queued build stops being invisible to
  # everything that cannot ssh into this box. The file below is still the queue
  # — bin/fly-dispatch.sh and bin/fly-pool.sh read the directory until they move
  # — so a failed row changes nothing at all.
  #
  # Idempotent on (project, KEY) in the worker, which is the same identity the
  # dedup checks below enforce on the file. Fail-open: no client, no worker, no
  # secret -> no row, no log noise, and this branch behaves byte-for-byte as it
  # did before this block existed.
  # shellcheck source=/dev/null
  [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
  QUEUE_ROW_OK=0
  if command -v queue_put >/dev/null 2>&1; then
    # rc 0 covers BOTH "queued" and "duplicate": either way the row exists, which
    # is the only thing the hub needs to find this build.
    queue_put "$PROJECT" "$KEY" "$TICKET" fly "$ATTEMPT" "$QMETA" >/dev/null 2>&1 && QUEUE_ROW_OK=1
  fi
  if [ -f "$HENV/fly.env" ]; then
    # On the hub: write locally. Dedup against an already-queued or active job —
    # including a live POOL machine (2026-08-13: TK-70 was re-enqueued mid-build;
    # the leftover dup would have spawned a second build after the reap).
    mkdir -p "$HARNESS/$QDIR"
    # BH-1026.0: one read, two call sites (the copy in bin/lib/rb/gates.sh is
    # this same block). The KEY is passed because the question below is "is THIS
    # key already building", and a project-wide answer would name some other
    # claimed ticket and open the guard. With build_queue_rows_only off — the
    # seeded state — the helper returns what the file returned; an unarmed box
    # with no client on PATH stays on the file read itself.
    if command -v build_queue_active_key >/dev/null 2>&1; then
      ACTIVE_KEY=$(build_queue_active_key "$PROJECT" "$KEY" 2>/dev/null | cut -f1)
    else
      ACTIVE_KEY=$(jq -r '.key // ""' "$HARNESS/state/fly/$PROJECT-active.json" 2>/dev/null)
    fi
    if [ -f "$HARNESS/$QDIR/$KEY.json" ] || [ "$ACTIVE_KEY" = "$KEY" ] \
       || grep -ls "\"key\": *\"$KEY\"" "$HARNESS/state/fly-pool/$PROJECT/"*.json >/dev/null 2>&1; then
      RESULT "QUEUED_FLY $KEY (already queued/active)"; exit 0
    fi
    printf '%s\n' "$JOB_JSON" > "$HARNESS/$QDIR/$KEY.json"
    echo "$(STAMP) [$PROJECT/$KEY] enqueued to local hub Fly queue" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
    RESULT "QUEUED_FLY $KEY"; exit 0
  else
    # ON A WATCHER, THE ROW IS THE QUEUE (2026-09-11).
    #
    # This used to write state/build-queue/<p>/<KEY>.json unconditionally, and
    # that file is the whole reason the hub holds ssh into every box: a queue
    # living on a box can only be read by reaching into the box, so
    # bin/fly-dispatch.sh had to `ls`, `scp` and `rm` this directory every two
    # minutes. With the row written, the hub finds the build without the hop —
    # so the file is not written at all, and the hop has nothing left to carry.
    #
    # A leftover file from before this change still short-circuits, because the
    # hub's drain is still what clears those and a second enqueue underneath one
    # would be a duplicate.
    mkdir -p "$HARNESS/$QDIR"
    if [ -f "$HARNESS/$QDIR/$KEY.json" ]; then
      RESULT "QUEUED_FLY $KEY (already queued locally)"; exit 0
    fi
    if [ "$QUEUE_ROW_OK" = 1 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] enqueued to the coordination DB; no box file written — the hub reads the row" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
      RESULT "QUEUED_FLY $KEY"; exit 0
    fi
    # THE FALLBACK IS FOR A D1 OUTAGE ONLY, AND IT IS LOUD. Writing the file
    # silently is what would let the fleet drift back onto the ssh path without
    # anyone noticing — the build still runs, so nothing else would ever say so.
    printf '%s\n' "$JOB_JSON" > "$HARNESS/$QDIR/$KEY.json"
    # ONE ALERT PER PROJECT PER DAY. A D1 outage is a per-BOX condition, not a
    # per-build one: every build queued while it lasts would page identically,
    # and a wave of five tickets would send five copies of the same sentence.
    # Same per-day flag shape bin/jobs-client.sh uses for its own outage line.
    # The FILE short-circuit above is untouched and the per-build line still goes
    # to the project log every time — only the paging is bounded.
    QRFLAG="$HARNESS/flags/alerted-queue-row-$PROJECT-$(date -u +%Y%m%d)"
    if [ ! -f "$QRFLAG" ]; then
      mkdir -p "$HARNESS/flags" 2>/dev/null && touch "$QRFLAG" 2>/dev/null
      echo "$(STAMP) [$PROJECT/$KEY] QUEUE ROW REFUSED OR UNREACHABLE — this build was queued as a FILE on this box instead, so it now depends on the hub's ssh drain to reach the fly lane. The build is NOT lost; the coordination DB is degraded. Check worker/jobs + HARNESS_SECRET on this box. (One alert per project per day; every affected build is in ${PROJECT}.log.)" >> "$ALERTS"
    fi
    echo "$(STAMP) [$PROJECT/$KEY] QUEUE ROW REFUSED OR UNREACHABLE — enqueued to local Fly queue instead (hub pulls over ssh)" >> "$HARNESS/logs/${PROJECT}.log" 2>/dev/null || true
    RESULT "QUEUED_FLY $KEY"; exit 0
  fi
fi
BB() { # BB <stage> [tier] [verdict] [pr_url] [merged] [detail]
  /root/harness/bin/beat.sh "$(jq -nc --arg bkey "$BKEY" --arg p "$PROJECT" --arg t "$KEY" \
    --arg stage "${1}" --arg tier "${2:-}" --arg v "${3:-}" --arg pr "${4:-}" --argjson m "${5:-false}" --arg d "${6:-}" \
    '{kind:"build",bkey:$bkey,project:$p,ticket_key:$t,stage:$stage,tier:(if $tier=="" then null else ($tier|tonumber) end),verdict:$v,pr_url:$pr,merged:$m,detail:$d}')"
}
# F2 (docs/RUN-BUILD-GRAPH.md): $BUILD already exists and the ticket is already
# claimed, so leaving without a RESULT is the 232-abandoned-rows shape. A
# missing checkout is not "not now" — every tick repeats it until a human loads
# the project onto this box — so it refuses rather than defers.
[ -d "$REPO" ] || { echo "$(STAMP) [$PROJECT/$KEY] build: repo missing" >> "$ALERTS"; RESULT "BUILD_REFUSED no $REPO checkout on this box — load the project here before it can build"; exit 3; }

# >>> wip gate
# Wave 6a WIP limit: flags/wip-limit-<project> caps concurrent builds per
# project beyond the box-wide slot count (matters in the runner era).
#
# A HOTFIX IS THE ONE ROW ALLOWED PAST IT (#368), by exactly one: the cap is
# there to bound how much ordinary work a project runs at once, and an
# emergency ticket waiting for an ordinary build to finish is the failure this
# lane exists to end. It is one row per hotfix, not a suspension of the cap —
# every plain build behind it still defers, and the excess says so in the log
# so a project that is permanently over its cap is greppable rather than a
# mystery.
WIP=$(cat "$HARNESS/flags/wip-limit-$PROJECT" 2>/dev/null || echo "")
if [ -n "$WIP" ] && [ "$("$HARNESS/bin/count-builds.sh" "$PROJECT")" -ge "$WIP" ]; then
  if [ "${HOTFIX:-}" = 1 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] hotfix: wip-limit $WIP reached, exceeding it by one for $KEY" >> "$BUILD/pipeline.log"
  else
    RESULT "BUILD_DEFERRED wip-limit $WIP reached"; exit 3
  fi
fi
# <<< wip gate
# >>> build slots
# BUILD SLOTS ARE A CAP, NOT A QUEUE (the operator, 2026-09-13: "change the rule so we
# never lock and serialize"). The count is BUILD_SLOTS — env/global.env, or the
# environment — resolved by bin/lib/build-caps.sh:build_slots, and its DEFAULT IS
# 0 = UNLIMITED: no slot lock is opened at all, so a build never holds a
# descriptor another build is waiting behind. A number greater than zero is a
# deliberate box cap (cores, RAM) and still refuses rather than waits: every slot
# held -> BUILD_DEFERRED + exit 3, which is this pipeline's word for "not now,
# re-offer me next tick". Nothing in here ever blocks.
#
# Fail-open on a missing lib (scratch trees, a half-synced box) to BUILD_SLOTS or
# 0 — an unreadable arithmetic helper must not invent a cap nobody set.
#
# A HOTFIX MAY TAKE ONE EXTRA SLOT (BH-5021), mirroring the wip gate above: when
# every regular slot is held, HOTFIX=1 tries exactly one more lock,
# build-slot-<SLOTS+1>, shared by all hotfixes, so the box is bounded at
# SLOTS+1. Regular slots record nothing about who holds them, so the rule is
# "the regular ones are full", not "full of non-hotfix builds". A plain build
# never tries it. On a pool machine (BUILDER_EXEC=1) one job runs at a time, so
# a busy slot can only be a stray holder: the refusal says the machine is dirty,
# and the hub reap destroys it rather than handing it the next job.
# A POOL machine (POOL_MODE=1 as well) never reaches this refusal: the block
# below skips the gate there (BH-5046), and fly/builder-runner.sh slot_preflight
# (BH-5021) is what catches a stray holder before the job starts. The wording
# still applies to a dedicated builder (BUILDER_EXEC=1, no POOL_MODE).
SLOTS=""
# shellcheck source=bin/lib/build-caps.sh
[ -r "$HARNESS/bin/lib/build-caps.sh" ] && . "$HARNESS/bin/lib/build-caps.sh" 2>/dev/null
command -v build_slots >/dev/null 2>&1 && SLOTS=$(build_slots "$HARNESS")
[ -n "$SLOTS" ] || SLOTS="${BUILD_SLOTS:-0}"
case "$SLOTS" in ''|*[!0-9]*) SLOTS=0;; esac
# A POOL MACHINE RUNS ONE JOB (BH-5025.1). fly/entrypoint.sh writes
# flags/build-slots=1 on every machine, so a reused pool machine whose last
# job left a process holding locks/build-slot-1.lock deferred the next job
# with "all 1 slots busy". On the pool route the pool cap and the ledger
# claim are the concurrency controls (docs/BUILD-CONCURRENCY.md, routing
# table), so the box slot does not apply. Both vars are required: a watcher
# box (no BUILDER_EXEC) and a dedicated builder (no POOL_MODE) keep the gate.
if [ "$SLOTS" -gt 0 ] && [ "${POOL_MODE:-}" = 1 ] && [ "${BUILDER_EXEC:-}" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] build slots: pool machine (POOL_MODE=1), one machine runs one job, slot gate skipped (BUILD_SLOTS=$SLOTS not applied)" >> "$BUILD/pipeline.log"
  SLOTS=0
fi
GOT=""
if [ "$SLOTS" -gt 0 ]; then
  for S in $(seq 1 "$SLOTS"); do
    eval "exec $((7+S))>\"$HARNESS/locks/build-slot-$S.lock\""
    if flock -n $((7+S)); then GOT=$S; break; fi
  done
  SLOTWHY=""
  if [ -z "$GOT" ] && [ "${HOTFIX:-}" = 1 ]; then
    S=$((SLOTS+1))
    eval "exec $((7+S))>\"$HARNESS/locks/build-slot-$S.lock\""
    if flock -n $((7+S)); then
      GOT=$S
      echo "$(STAMP) [$PROJECT/$KEY] hotfix: all $SLOTS slots busy, taking extra slot $GOT for $KEY" >> "$BUILD/pipeline.log"
    else
      SLOTWHY=" and the hotfix slot is held"
    fi
  fi
  if [ -z "$GOT" ]; then
    [ "${BUILDER_EXEC:-}" = 1 ] && SLOTWHY="$SLOTWHY — slot held on this machine"
    RESULT "BUILD_DEFERRED all $SLOTS slots busy$SLOTWHY"; exit 3
  fi
elif [ -e "$HARNESS/flags/build-slots" ] && ! { [ "${POOL_MODE:-}" = 1 ] && [ "${BUILDER_EXEC:-}" = 1 ]; }; then
  # Said out loud once per build rather than left as a surprise: the legacy flag
  # is only read when BUILD_SLOTS is unset (build_slots above), so a box carrying
  # both has one of them doing nothing.
  echo "$(STAMP) [$PROJECT/$KEY] BUILD_SLOTS=0 (unlimited) — flags/build-slots is present but overridden; delete it or set BUILD_SLOTS in env/global.env" >> "$BUILD/pipeline.log"
fi
# <<< build slots
} # end rb_gate_prelude

rb_gate_claim_and_workspace() {

# >>> hub-no-build
# THE HUB RUNS NO AGENT BUILD WORK (BH-393, docs/HUB-THINNING-PLAN.md).
#
# WHY HERE AND NOT AT THE TOP. Three things above this line are the hub's
# legitimate job and must keep working: the Fly enqueue block (it writes the
# queue row and answers QUEUED_FLY — that is coordination, not building), the
# RESUME path that needs $BUILD to exist before a RESULT can be written, and
# this very line, because HUB_BUILD_OK belongs in env/global.env like every
# other operator knob rather than in a second place nobody looks.
#
# BUILD_REFUSED + exit 3 is the shape the missing-checkout refusal above
# already uses: the sweep closes the record with one ALERTS line, and the
# per-key flock opened just above is released by the exit. No claim row has
# been opened yet, so nothing is left half-claimed.
# shellcheck source=bin/lib/hub-box.sh
for _hb in "$(dirname "$0")/lib/hub-box.sh" "$HARNESS/bin/lib/hub-box.sh"; do
  [ -r "$_hb" ] && { . "$_hb"; break; }
done
command -v hub_no_build_refuse >/dev/null 2>&1 || hub_no_build_refuse() { return 1; }
if hub_no_build_refuse build "$KEY"; then
  RESULT "BUILD_REFUSED hub-no-build — the hub runs no agent build work; this ticket belongs on $("$HARNESS/bin/box-for.sh" "$PROJECT" 2>/dev/null || echo 'its owning box') (HUB_BUILD_OK=1 overrides)"
  exit 3
fi
# <<< hub-no-build

# >>> disk gate
# A BUILD IS NOT STARTED ON A FULL DISK (BH-1123). At or over
# DISK_BUILD_REFUSE_PCT (default 92, a knob on the disk-guard lane) the build
# answers BUILD_DEFERRED with the reading and the line, and is re-offered next
# tick, instead of buying a plan session and dying on ENOSPC halfway through.
# Here, below hub-no-build, so a hub build under HUB_BUILD_OK=1 is gated too,
# and above the overlap check and every claim, so nothing is left half-claimed.
# Pool machines (BUILDER_EXEC=1) are not gated: the ticket asked for board boxes
# and the hub. No reading, or no lib, fails OPEN: a broken probe must not stop
# the fleet. The alert id is the one bin/disk-guard.sh raises, so the two
# writers are one open condition.
if [ "${BUILDER_EXEC:-}" != 1 ]; then
  _dg=""
  for _dgf in "$(dirname "$0")/lib/disk-guard.sh" "$HARNESS/bin/lib/disk-guard.sh"; do
    # shellcheck source=bin/lib/disk-guard.sh
    [ -r "$_dgf" ] && . "$_dgf" && { _dg=1; break; }
  done
  if [ -z "$_dg" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] disk gate: bin/lib/disk-guard.sh not readable, not gated" >> "$BUILD/pipeline.log"
  elif DG_REASON=$(disk_build_refuse_reason); then
    echo "$(STAMP) [$PROJECT/$KEY] disk gate: $DG_REASON" >> "$BUILD/pipeline.log"
    "$HARNESS/bin/lane-alert.sh" --id "disk-refuse-$(hostname)" --severity critical disk-guard \
      "build $PROJECT/$KEY refused: $DG_REASON" >/dev/null 2>&1 || true
    RESULT "BUILD_DEFERRED $DG_REASON"
    exit 3
  fi
fi
# <<< disk gate

# >>> overlap not-before
# THE OTHER HALF OF THE FLEET OVERLAP DEFERRAL (W2-D, 2026-09-14). The hook
# after PLAN writes state/overlap-defer/<project>/<KEY> when a build stands down
# because something in flight claims a file its plan names, and puts the ticket
# back on the queue. Without a not-before the very next tick re-offers it, buys
# a whole PLAN session, and stands down again against the same sibling — which
# is a spend loop, not scheduling. So the marker is read HERE, before the plan
# is bought: a ticket inside its not-before window defers for free.
#
# It is a floor, never a ceiling: the marker is consumed the moment it expires,
# and a build that arrives after it runs the overlap test again from scratch —
# the sibling may well be finished by then. Same kill flag as the hook itself,
# because a box that turns fleet overlap scheduling off must not keep honouring
# markers only that scheduler writes.
#
# THE MARKER FILE LIVES ON ONE MACHINE (BH-1036). Re-offer the ticket to a
# different box, or wipe the hub, and the window is invisible — the very spend
# loop above, one machine over. The deferring build already writes the same fact
# to the fleet DB as an `overlap_defer` artifact (the hook at the bottom of this
# file), so when the no-twin-ledgers flag is up that artifact is READ BACK here
# when the file has nothing. Read only: nothing below writes an artifact, and
# there is no file to consume on this path.
NB_F="$HARNESS/state/overlap-defer/$PROJECT/$KEY"
case "$(printf '%s' "${OVERLAP_SCHED:-1}" | tr '[:upper:]' '[:lower:]')" in 0|off|false|no) NB_F="" ;; esac
[ -e "$HARNESS/flags/plan-overlap-off" ] && NB_F=""
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# shellcheck source=bin/lib/ledger-twin.sh
[ -r "$HARNESS/bin/lib/ledger-twin.sh" ] && . "$HARNESS/bin/lib/ledger-twin.sh"
# shellcheck source=bin/lib/file-claims.sh
[ -r "$HARNESS/bin/lib/file-claims.sh" ] && . "$HARNESS/bin/lib/file-claims.sh"
NB_AT=""
if [ -n "$NB_F" ] && [ -s "$NB_F" ]; then
  NB_AT=$(head -1 "$NB_F" 2>/dev/null)
  case "${NB_AT:-}" in ''|*[!0-9]*) NB_AT=0 ;; esac
  if [ "$NB_AT" -le "$(date -u +%s)" ]; then rm -f "$NB_F"; NB_AT=""; fi
fi
# THE FLEET ROW (BH-2524.2): the not-before another box wrote on its job_claims
# row, asked by project+key. Its own `if`, before the artifact feed and not
# behind lt_on. An outage (rc != 0, empty, non-numeric, 0) is a miss, never a
# window: it falls through to the feed and then to today's behaviour.
if [ -z "$NB_AT" ] && [ -n "$NB_F" ] && command -v fclaim_not_before_left >/dev/null 2>&1; then
  NB_LEFT=$(fclaim_not_before_left "$PROJECT" "$KEY" 2>/dev/null) || NB_LEFT=""
  case "${NB_LEFT:-}" in ''|*[!0-9]*) NB_LEFT="" ;; esac
  [ -n "$NB_LEFT" ] && [ "$NB_LEFT" -gt 0 ] && NB_AT=$(( $(date -u +%s) + NB_LEFT ))
fi
# AN EXPIRED FILE IS NOT AN ANSWER, it is the absence of one — so this is its
# own `if` on NB_AT, not an `elif` on the file's existence. Box 1 defers BH-x
# and its window passes; the hub re-offers BH-x to box 2, which defers again
# and writes the artifact; box 1 gets it back with a stale file on disk. As an
# `elif` the stale file is consumed, the feed is never asked, and the plan is
# bought inside box 2's live window — the exact "re-offered to a different pool
# box" spend loop this gate exists to close.
if [ -z "$NB_AT" ] && [ -n "$NB_F" ] && type lt_on >/dev/null 2>&1 && lt_on \
   && command -v job_artifact_feed >/dev/null 2>&1; then
  # THE CAP CANNOT HIDE A LIVE DEFERRAL, which is the thing to check before
  # trusting any capped read (D12): the window asked for is an hour and the
  # limit 500 rows, while the fact's own lifetime is
  # OVERLAP_DEFER_NOTBEFORE_SECS (default 600s) — a row old enough to fall off
  # the end of that feed has already expired, so falling through is correct.
  NB_ROW=$(job_artifact_feed overlap_defer "$PROJECT" \
             "$(date -u -d "@$(( $(date -u +%s) - 3600 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" 500 \
           2>/dev/null | awk -F'\t' -v k="$KEY" \
             'NF >= 6 && $2 == "deferred" && $4 == k { print $5 "\t" $6; exit }')
  if [ -n "${NB_ROW:-}" ]; then
    # A `proceeded` artifact (the verdict the hook writes when it does NOT stand
    # down) carries no not_before_s and never reaches here; a `deferred` row
    # whose detail will not parse is a miss, not a deferral.
    NB_S=$(printf '%s' "${NB_ROW#*$'\t'}" | jq -r '.not_before_s // empty' 2>/dev/null)
    NB_BASE=$(date -u -d "${NB_ROW%%$'\t'*}" +%s 2>/dev/null)
    case "${NB_S:-}"    in ''|*[!0-9]*) NB_S="" ;; esac
    case "${NB_BASE:-}" in ''|*[!0-9]*) NB_BASE="" ;; esac
    [ -n "$NB_S" ] && [ -n "$NB_BASE" ] && NB_AT=$(( NB_BASE + NB_S ))
    [ -n "$NB_AT" ] && [ "$NB_AT" -le "$(date -u +%s)" ] && NB_AT=""
  fi
fi
if [ -n "$NB_AT" ]; then
  NB_NOW=$(date -u +%s)
  RESULT "BUILD_DEFERRED plan overlap not-before $(date -u -d "@$NB_AT" '+%H:%M:%SZ' 2>/dev/null || echo "$NB_AT") — $KEY stood down on a file overlap and its window has $(( (NB_AT - NB_NOW + 59) / 60 ))m left; the next tick after that re-offers it and re-runs the overlap test"
  exit 3
fi
# THE AFTER: HOLD (BH-4988). Past the floor, a ticket that stood down against a
# named build stays held, still before any plan is bought, until that build is
# finished and has no open PR (bin/plan-after.sh check). It reads this box's
# marker file, or, with none (a pool re-offer lands on a fresh machine), the
# `overlap_defer` artifact the hook at the bottom of this file wrote with
# choice "after". Only rc 3 holds: a
# missing script, an unreadable PR answer or any other rc goes on to PLAN,
# where plan-overlap judges it again exactly as before.
# BH-6292: a hotfix is never held. Past PLAN_AFTER_MAX_MIN, check answers
# `EXPIRED <OTHER>`; that key goes to $BUILD/after-expired, which
# `plan-sibling.sh inflight` (the plan overlap block) reads, so the same pair
# does not start a new hold and the ticket dispatches.
if [ -n "$NB_F" ] && [ "${HOTFIX:-}" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] AFTER_HOLD skipped hotfix — a hotfix is never deferred" >> "$BUILD/pipeline.log"
elif [ -n "$NB_F" ] && [ -x "$HARNESS/bin/plan-after.sh" ]; then
  PA=$("$HARNESS/bin/plan-after.sh" check "$PROJECT" "$KEY" 2>>"$BUILD/pipeline.log"); PA_RC=$?
  if [ "$PA_RC" = 3 ] && [ -n "$PA" ]; then
    RESULT "BUILD_DEFERRED After: ${PA#AFTER } — $KEY overlaps it on a non-splittable file and builds after it merges; re-checked each tick before any plan is bought"
    exit 3
  fi
  PA_X=$(printf '%s\n' "$PA" | sed -n 's/^EXPIRED \([A-Za-z0-9._-]\{1,64\}\)$/\1/p' | head -1)
  if [ "$PA_RC" = 0 ] && [ -n "$PA_X" ]; then
    printf '%s\n' "$PA_X" > "$BUILD/after-expired"
    echo "$(STAMP) [$PROJECT/$KEY] AFTER_CAP $KEY after=$PA_X cap=PLAN_AFTER_MAX_MIN — dispatching anyway" >> "$BUILD/pipeline.log"
  fi
fi
# <<< overlap not-before


# --- GitHub auth for this build (2026-09-14, the operator: "every throughput ceiling is
# a bug") -----------------------------------------------------------------------
# TOKEN RESOLUTION ONLY — nothing below this block changes. Every `gh` call and
# every `git push` in this pipeline reads GH_TOKEN (git through `gh auth
# setup-git`'s credential helper, which answers with GH_TOKEN when it is set), so
# resolving it ONCE here covers the whole run: one place to read, one place to
# roll back. The token is a repo-scoped GitHub App installation token that dies
# in an hour instead of the fleet-wide PAT that never does — 4000 builders can
# not share one 5000/h bucket.
# UNARMED IS TODAY, WITH NO EXTRA FORK: gh_auth_for returns 1 without running a
# process when env/github-app.env is absent, GH_APP_TOKENS=0 or
# flags/gh-app-tokens-off exists, and GH_TOKEN keeps whatever global.env set.
# >>> gh default auth
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# The rate-limit logger (#469, BH-470): a `gh` wrapper that writes one
# identity= line when GitHub refuses a call for budget, so a 403 says WHICH
# credential ran out. Fail-open — a box that has not synced the file yet
# defines nothing and this pipeline is unchanged.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
# The REST contract every decision path reads GitHub through (#768): rc 0 = act
# on the body, rc 44 = an affirmative 404, rc 75 = UNVERIFIABLE, skip this tick.
# The issue created-at read, TICKET_META, the tier-1 close-out and the blocked
# notice below are its callers here. A box whose sync has not landed the file
# defines nothing and each of those degrades to its existing failure path.
# shellcheck source=bin/lib/gh-rest.sh
[ -r "$HARNESS/bin/lib/gh-rest.sh" ] && . "$HARNESS/bin/lib/gh-rest.sh"
# <<< gh default auth
# The board token resolver (BH-1955): TICKET_FP and TICKET_META below read the
# token NAME through it. Absent lib = no board read, their documented fail-open.
for _P in "$(dirname "$0")/lib/board-creds.sh" "$HARNESS/bin/lib/board-creds.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_P" ] && { . "$_P"; break; }
done
# ...AND ONCE IS NOT ENOUGH ON A POOL MACHINE (2026-09-14, TK-680/681/682). An
# installation token lives exactly one hour; this pipeline runs 40-75 minutes on a
# Fly builder, and the resolution above happens at minute zero. Three project-5
# builds resolved a token that had already been alive 47 minutes, finished, and
# were rejected at the pre-PR push with `remote: Invalid username or token` —
# the whole build thrown away over a credential, not over the code.
# bin/fly-pool.sh's tick now pushes a fresh token to /run/harness-env/gh-token
# under the running build; gh_token_live re-reads that file at each point this
# pipeline actually spends the token. A watcher box has no such file and every
# call is a no-op, so nothing off the pool changes.
# shellcheck source=bin/lib/gh-token-live.sh
[ -r "$HARNESS/bin/lib/gh-token-live.sh" ] && . "$HARNESS/bin/lib/gh-token-live.sh"
# REPO_SLUG rides in the fly builder's env bundle; on a watcher the checkout's
# own remote is the truth. fleet.conf is the last resort, for a build whose
# clone does not exist yet. Named here, above GH_LIVE, because on a watcher box
# there is no live token file and gh_token_live mints a fresh token FOR THIS
# SLUG instead (2026-09-15 22:11Z, BH-375's push on a dead minute-0 token).
GH_AUTH_SLUG="${REPO_SLUG:-}"
[ -n "$GH_AUTH_SLUG" ] || GH_AUTH_SLUG=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
[ -n "$GH_AUTH_SLUG" ] || GH_AUTH_SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
GH_LIVE() { command -v gh_token_live >/dev/null 2>&1 && gh_token_live "${GH_AUTH_SLUG:-}"; return 0; }
# >>> gh default auth
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  # rc 1 = no fleet.conf row for this project (a clone-less build on a box that
  # has not synced fleet.conf, or a pool builder carrying only REPO_SLUG): fall
  # back to the slug the checkout's own remote named, exactly as before #469.
  gh_default_auth_for_project "$PROJECT" || gh_auth_for "$GH_AUTH_SLUG" || true
elif command -v gh_auth_for >/dev/null 2>&1; then
  gh_auth_for "$GH_AUTH_SLUG" || true
fi
# <<< gh default auth

# --- Coordination DB claim (phase 1, docs/DB-COORDINATION-SPEC.md) -------------
# The flocks above only see THIS box. Builds now run on watchers AND ephemeral
# fly builders, so in-flight work elsewhere is invisible to every file guard we
# have — which is exactly how one ticket gets built twice. job_open registers
# the claim centrally and returns 9 when another box already holds it.
# Everything here is fail-open: with the worker unreachable job_open returns 1,
# JOB_ID stays empty, and this pipeline behaves precisely as it does today.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
# >>> live events
# --- BH-520: SUB-STAGE PROGRESS, as events on the claim ----------------------
# The jobs row carries one `stage` word and, until now, two events: `done` at
# the end and `BUDGET_STOP` when a call ran out of money. So a build in flight
# looked identical at minute 3 and minute 70, and "is it stuck?" was answerable
# only by ssh-ing to the box and reading pipeline.log.
#
# These helpers post ONE short line per gate the pipeline already passes,
# through the existing job_event transport — no new endpoint, no new table, no
# transcript, no diff, no secret. They are DISPLAY ONLY: nothing downstream
# reads them, so an event that never lands costs a row in the console and
# nothing else, which is why every one of them is fail-open and silent.
#
# Message hygiene is enforced HERE rather than at each call site: newlines and
# tabs flattened (the console renders one row), 200 characters hard cap, and a
# 4s timeout with no retry so a slow worker cannot add minutes to a build.
LIVE() { # LIVE <stage> <verdict-or-empty> <message>
  [ -n "${JOB_ID:-}" ] || return 0
  command -v job_event >/dev/null 2>&1 || return 0
  local msg
  msg=$(printf '%s' "${3:-}" | tr '\n\r\t' '   ' | cut -c1-200)
  JOBS_TIMEOUT=4 JOBS_RETRIES=0 job_event "$JOB_ID" "${1:-}" "${2:-}" "$msg" >/dev/null 2>&1 || true
  return 0
}
# Blocking findings, counted off the artifact the lens actually wrote. An ABSENT
# heading prints `-`, never 0 (D11): "the lens listed no findings" and "this file
# has no findings section" are different facts and only one of them is good news.
LIVE_COUNT() { # LIVE_COUNT <review-artifact>
  local f="${1:-}"
  [ -r "$f" ] || { printf '%s' '-'; return 0; }
  grep -qiE '^#+[[:space:]]*Blocking findings' "$f" 2>/dev/null || { printf '%s' '-'; return 0; }
  awk 'BEGIN{f=0;n=0}
       /^#+[[:space:]]*[Bb]locking [Ff]indings/{f=1;next}
       f && /^#+[[:space:]]/{exit}
       f && /^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]+/{n++}
       END{print n}' "$f"
}
# A lens verdict is the anchored VERDICT line in the final block of its
# artifact, read by bin/lib/verdict-parse.sh — the same reader LENS_APPROVED
# uses (BH-1625). A missing, silent or unreadable artifact is `none` — never
# APPROVE.
LIVE_LENS() { # LIVE_LENS <lens> <artifact> <prefix>
  local lens="${1:-}" art="${2:-}" pre="${3:-}" v=none n
  v=$(verdict_parse -L "$art" 2>/dev/null) || v=none
  n=$(LIVE_COUNT "$art")
  LIVE review "$v" "$pre$lens: $v, $n blocking finding(s)"
}
# The harness-run suite, read off its own HARNESS_EXIT line. Failure is never
# mapped to success and absence is never mapped to green (D9/D13): a build whose
# suite file is missing says so in the words the reviewer needs to see.
LIVE_SUITE() { # LIVE_SUITE <suite-file> <prefix>
  local f="${1:-}" pre="${2:-}" ex pass
  if [ ! -r "$f" ]; then
    LIVE tests_green not-run "${pre}the suite left no record on this head — do not read that as green"
    return 0
  fi
  ex=$(sed -n 's/^HARNESS_EXIT:[[:space:]]*//p' "$f" 2>/dev/null | tail -1)
  case "${ex:-}" in
    0) pass=$(grep -oiE '[0-9]+ (tests? )?(passed|pass)' "$f" 2>/dev/null | tail -1)
       LIVE tests_green pass "${pre}tests green${pass:+: $pass}" ;;
    no-test-script) LIVE tests_green none "${pre}this repo has no test script — nothing was run, and that is not green" ;;
    could-not-run) LIVE tests_green not-run "${pre}the impact gate could not run its suites (its runner could not start, or the stage timed out) — that is not green" ;;
    '') LIVE tests_green not-run "${pre}the suite wrote no HARNESS_EXIT line — no verdict, not a pass" ;;
    *) LIVE tests_green fail "${pre}tests FAILED (exit $ex): $(grep -iE 'fail|error' "$f" 2>/dev/null | tail -1)" ;;
  esac
}
# <<< live events
# The merge-queue provider probe, from the conductor's lib (sourced, never
# copied — a second answer to "does this repo have a queue" that drifted would be
# a silent double merge). It decides what the tier-1 gate's own `gh pr merge`
# would do. A tree without the lib answers "no queue", i.e. today's behaviour.
# shellcheck source=bin/lib/merge-conductor-lib.sh
if [ -r "$HARNESS/bin/lib/merge-conductor-lib.sh" ]; then . "$HARNESS/bin/lib/merge-conductor-lib.sh"
else mc_queue_conductor_only() { return 1; }; mc_pr_queued() { return 1; }; fi
# Judge provenance as a (runner, model) pair — bin/lib/review-provenance.sh,
# which the lib above also sources. This script is where the provenance WORD is
# written (the verdict artifact below), so the shim matters: a tree without the
# lib records the runner word exactly as it always did, and every reader treats
# anything but `claude` as non-primary. Fail-closed in both halves.
type rp_prov_word >/dev/null 2>&1 || { rp_prov_word() { printf '%s' "${1:--}"; }
  rp_prov_is_claude() { [ "${1:-}" = claude ]; }
  rp_out_prov() { head -1 "${1:-}.runner" 2>/dev/null || printf 'claude'; }
  rp_out_is_claude() { rp_prov_is_claude "$(rp_out_prov "$1")"; }
  rp_out_label() { rp_out_prov "$1"; }; }
# The guard-silencing classifier (BH-641): a fix round that answers a static
# guard by editing the guard's own rule module, allow-list or fixture is not a
# fix. Sourced next to the other mechanical gates' libs; a box without it
# classifies nothing and blocks nothing, which is this script's behaviour before
# BH-641 — a gate's own absence never demotes a build here.
# shellcheck source=bin/lib/guard-silenced.sh
[ -r "$HARNESS/bin/lib/guard-silenced.sh" ] && . "$HARNESS/bin/lib/guard-silenced.sh"
# >>> builder-direct arm
# THE BUILDER FINISHES ITS OWN JOB (W2-B, the operator 2026-09-14). Resolved HERE, once,
# because two places below read it and they must not be able to disagree: the
# queue claim (which becomes a stand-down instead of a shrug when this is on)
# and the close-out block at the end of the file. bin/lib/builder-direct.sh owns
# the flag; a tree without the lib answers 0, which is today's behaviour.
# Kill flag: BUILDER_DIRECT=0 / flags/builder-direct-off.
# shellcheck source=bin/lib/builder-direct.sh
[ -r "$HARNESS/bin/lib/builder-direct.sh" ] && . "$HARNESS/bin/lib/builder-direct.sh"
BUILDER_DIRECT_ON=0
command -v builder_direct_on >/dev/null 2>&1 && BUILDER_DIRECT_ON=$(builder_direct_on "$HARNESS")
# The terminal facts the close-out block writes to this job's row. Empty on every
# other path, and _job_finish falls back to the summary it has always written.
BUILDER_DIRECT_META=""
# <<< builder-direct arm
JOB_ID=""; JOB_BEAT=""
_job_finish() { # EXIT hook: close the claim with the verdict the RESULT file carries
  [ -n "${JOB_ID:-}" ] || return 0
  [ -n "${JOB_BEAT:-}" ] && job_beat_stop "$JOB_BEAT"
  command -v job_update >/dev/null 2>&1 || return 0
  local r; r=$(head -c 300 "$BUILD/RESULT" 2>/dev/null)
  local st
  case "$r" in
    # ROLLOUT_FILED beside DECOMPOSED (BH-985): the master's waves are filed and
    # the build's work is finished. ROLLOUT_FAILED is deliberately NOT here — it
    # reaches `failed` through `*)`, exactly as DECOMPOSE_FAILED does.
    PR_MERGED*|PR_CREATED*|DECOMPOSED*|ROLLOUT_FILED*)   st="done" ;;
    BUILD_DEFERRED*|QUEUED_FLY*|PLAN_BLOCKED*|PLAN_MALFORMED*|PLAN_STALE*) st=parked ;;
    # Named, not left to `*)` (BH-614): a build that opened no PR is a FAILED row
    # bin/blocked-resolver.sh re-enters, and the word is load-bearing enough (the
    # RESULT ratchet above writes it) to be read here on purpose. The `D` in
    # FAILED is what keeps it out of the `PR_CREATED*` arm one line up.
    PR_CREATE_FAILED*)                    st=failed ;;
    "")                                   st=failed ;;
    *)                                    st=failed ;;
  esac
  # Phase 5: close any phase still reading `running` BEFORE the job closes, so
  # the ledger can answer which phase died. On the normal path agent-call.sh has
  # already closed its own row with the stage's real rc; this catches the case
  # it cannot — its own process killed (rc=137 runs no trap), or this pipeline
  # exiting between stages — where the row would otherwise stay open forever.
  # The phase name that comes back is recorded on the job's closing event, which
  # is what makes "this build failed" name a stage instead of a job.
  local ph=""
  if command -v job_phase_close_open >/dev/null 2>&1; then
    case "$st" in done) ph=$(job_phase_close_open "$JOB_ID" done "" "closed by the pipeline: $r" 2>/dev/null) ;;
                  *)    ph=$(job_phase_close_open "$JOB_ID" failed "" "the pipeline ended while this phase was still open: $r" 2>/dev/null) ;;
    esac
  fi
  # BUILDER-DIRECT (W2-B, 2026-09-14): when this build already wrote its terminal
  # facts (pr_url, sha, tier, verdict, cost) to the row, they are the job's last
  # word and this trap must not overwrite them with the one-line summary. Unset
  # — every watcher build, and any builder with the direct path switched off —
  # this is byte-for-byte the meta it has always written.
  job_update "$JOB_ID" "status=$st" "meta=${BUILDER_DIRECT_META:-$r}"
  job_event "$JOB_ID" "done" "$st" "$r${ph:+ (phase left open: $ph)}"
# >>> blocking artifact body
  # THE FILE THE LINE NAMES (BH-531). A build that ends blocked writes its
  # reason into a FILE and records a one-line pointer to it below. On a pool
  # machine that path dies with the machine at reap, so the owning box stages a
  # RESULT naming a file on a host that no longer exists — and the session that
  # was supposed to ask the client the plan's questions has nothing to quote.
  # The body goes up here, as a transcript row, BEFORE the result row: a box
  # that reads the row on its very next tick must already be able to fetch it.
  #
  # Exactly three terminals, each with the one file its line points at. $r is
  # `head -c 300` of the RESULT, so these match on its first word; the trailing
  # space makes that word COMPLETE, which is what keeps a future terminal whose
  # name merely begins with one of these out of the match. The neighbours that
  # would otherwise be tempting — PLAN_MALFORMED, PLAN_STALE, DECOMPOSED,
  # RESULT_UNVERIFIED PLAN_BLOCKED … — are all pinned as negatives in
  # tests/run-build-blocked-artifact.bh-531-test.sh.
  local bart="" bsrc="" bstage=""
  case "$r" in
    "PLAN_BLOCKED "*)     bart="$BUILD/plan.md";           bsrc=plan_md;       bstage=plan ;;
    "REVIEW_BLOCKED "*)   bart="$BUILD/review.md";         bsrc=review_md;     bstage=review ;;
    "DECOMPOSE_FAILED "*) bart="$BUILD/decompose-run.txt"; bsrc=decompose_run; bstage=decompose ;;
  esac
  # Fail-open like everything else in this trap: no file, an empty file, or a
  # box whose bin/ predates the pusher, and nothing happens. The log line says
  # "handed to" and not "pushed" on purpose — transcript-push.sh always exits 0
  # and whether the ledger took it is ITS log's to record, not this one's.
  if [ -n "$bart" ] && [ -s "$bart" ] && [ -r "$HARNESS/bin/transcript-push.sh" ]; then
    JOB_PHASE_ID="" TRANSCRIPT_SOURCE="$bsrc" \
      bash "$HARNESS/bin/transcript-push.sh" "$bstage" pipeline "" "$bart" >/dev/null 2>&1 || true
    echo "$(STAMP) [$PROJECT/$KEY] blocking artifact $(basename "$bart") handed to transcript-push.sh as $bsrc (job $JOB_ID); the outcome is in logs/transcripts.log" \
      >> "$BUILD/pipeline.log" 2>/dev/null || true
  fi
# <<< blocking artifact body
# >>> plan-blocked notice
  # THE BUILDER SAYS WHY ON THE TICKET (BH-7116). bin/board-closeout.sh words
  # only a PR, so a pool PLAN_BLOCKED reached no ticket: plan.md died with the
  # machine and the stranded watch re-offered the ticket first. A builder with
  # the direct path armed (the two conditions rb_close_out step 3 uses) posts
  # the plan's blocked section once and marks RESULT line 1, BEFORE the result
  # row below reads that line. Everything else keeps today's path. It never
  # changes this trap's outcome.
  if [ -n "${BUILDER_EXEC:-}" ] && [ "${BUILDER_DIRECT_ON:-0}" = 1 ]; then
    case "$r" in
      PLAN_BLOCKED|"PLAN_BLOCKED "*|PLAN_BLOCKED$'\n'*)
        # shellcheck source=bin/lib/plan-blocked.sh
        if [ -r "$HARNESS/bin/lib/plan-blocked.sh" ] && . "$HARNESS/bin/lib/plan-blocked.sh" 2>/dev/null \
           && command -v pb_notice >/dev/null 2>&1; then
          pb_notice "$HARNESS" "$PROJECT" "${TICKET:-}" "$KEY" "$BUILD" >> "$BUILD/pipeline.log" 2>&1 || true
        fi ;;
    esac
  fi
# <<< plan-blocked notice
  # THE RESULT AS A ROW (2026-09-10). A build that runs on an ephemeral fly
  # machine has always handed its RESULT back by scp into the owning box's
  # state/remote-results/ — a push that needs the machine to hold a path INTO
  # the box, and that strands the whole close-out when it fails (TK-124 sat a
  # day until a medic hand-delivered it). Recorded here it is a row the owning
  # box PULLS instead, and the same line goes up from every box, so nothing
  # about this is fly-specific: `result` is simply what this build concluded.
  # The first line only — the same summary the relay payload has always carried
  # — because the artifact_ref column is 1024 chars and a close-out is one line.
  if command -v job_artifact_put >/dev/null 2>&1; then
    local rline; rline=$(head -1 "$BUILD/RESULT" 2>/dev/null)
    [ -n "$rline" ] && job_artifact_put result "$rline" \
      "$(jq -nc --arg b "$(basename "$BUILD")" --arg k "$KEY" --arg s "$st" \
         '{build_dir:$b,key:$k,job_status:$s}' 2>/dev/null)" "$JOB_ID" >/dev/null 2>&1 || true
  fi
  # The queue row this build claimed, closed with the SAME verdict — derived
  # from $st rather than re-parsed from the RESULT line, so the two ledgers
  # cannot come to disagree about what happened. A DEFERRAL goes back to
  # `queued`: exit 3 is this pipeline's word for "not now, not a failure" and
  # the ticket must be re-offered on the next tick, exactly as the queue FILE
  # is left in place today. Only set when a claim actually landed, so a row
  # nobody took is never marked finished by a box that never ran it.
  if [ -n "${QUEUE_CLAIMED:-}" ] && command -v queue_done >/dev/null 2>&1; then
    case "$st" in
      done)   queue_done "$PROJECT" "$KEY" done "$r" >/dev/null 2>&1 || true ;;
      parked) queue_done "$PROJECT" "$KEY" queued "$r" >/dev/null 2>&1 || true ;;
      *)      queue_done "$PROJECT" "$KEY" failed "$r" >/dev/null 2>&1 || true ;;
    esac
  fi
  return 0
}
# >>> issue created-at stamp
# The acceptance clock (docs/DORA.md launch_lead_time) starts when the issue was
# FILED, not when this fleet got round to claiming it — lead_time already
# measures the second half. GitHub-Issues projects only; an in-app board has no
# issue to ask about, so it is not asked. FAIL-OPEN everywhere: a read that
# fails, is refused, or answers something that is not a whole-second Z stamp
# leaves a null column and one `unknown` log line, never a stopped build.
ISSUE_CREATED_AT=""
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ] \
   && [[ "$TICKET" =~ ^[0-9]+$ ]] && [ -n "${GH_AUTH_SLUG:-}" ]; then
  # ONE READ PER ENQUEUE (BH-1735). The closed-issue skip above already read
  # this issue and kept the JSON (issue_memo_file); created_at never changes, so
  # the stamp is served from that read. The memo only ever holds THIS enqueue's
  # successful read of THIS (repo, issue), so when the skip was switched off,
  # failed, or read another repo there is no file and the read below is made.
  ICA_M=""; command -v issue_memo_file >/dev/null 2>&1 && ICA_M=$(issue_memo_file "$BUILD" "$GH_AUTH_SLUG" "$TICKET")
  if [ -n "$ICA_M" ] && [ -s "$ICA_M" ] && jq -e 'type == "object"' "$ICA_M" >/dev/null 2>&1; then
    ISSUE_CREATED_AT=$(jq -r '.created_at // empty' "$ICA_M" 2>/dev/null)
    echo "$(STAMP) [$PROJECT/$KEY] issue created-at served from the closed-issue read (no second GET)" >> "$BUILD/pipeline.log"
  else
    # Every other gh spend in this file re-mints the minute-0 App token first. This
    # read fails open, so an expired token would not raise anything — it would just
    # record `unknown` for every build on every pool box, which is the one way a
    # fail-open metric read can lie without anybody noticing.
    GH_LIVE
    # REST (bin/lib/gh-rest.sh), through a temp file so the status stays in this shell.
    ICA_RC=0; ICA_T=$(mktemp "${TMPDIR:-/tmp}/issue-created.XXXXXX") || ICA_RC=75
    [ "$ICA_RC" = 0 ] && { gh_rest GET "repos/$GH_AUTH_SLUG/issues/$TICKET" > "$ICA_T" || ICA_RC=$?; }
    [ "$ICA_RC" = 0 ] && ISSUE_CREATED_AT=$(jq -r '.created_at // empty' "$ICA_T" 2>/dev/null)
    rm -f "${ICA_T:-}"
  fi
  [ -z "$ICA_M" ] || rm -f "$ICA_M"
  [[ "$ISSUE_CREATED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || ISSUE_CREATED_AT=""
fi
# Written BEFORE the claim goes out, and from the same variable the claim sends,
# so a build that dies inside job_open still leaves the evidence and the log can
# never name a stamp the ledger was not offered.
echo "$(STAMP) [$PROJECT/$KEY] ISSUE-CREATED-AT ${ISSUE_CREATED_AT:-unknown}" >> "$BUILD/pipeline.log"
# <<< issue created-at stamp
if command -v job_open >/dev/null 2>&1; then
  JOB_CLAIM=$(job_open "$PROJECT" "$KEY" build plan "plan/$PROJECT/${RUNNER_PLAN:-claude}" \
    "$(jq -nc --arg b "$(basename "$BUILD")" --arg t "$TICKET" '{build:$b,ticket_id:$t}' 2>/dev/null)" \
    "${ISSUE_CREATED_AT:-}")
  case "$?" in
    0) JOB_ID="$JOB_CLAIM"; export JOB_ID; trap _job_finish EXIT
# >>> job json id
       # The ledger row this build just claimed, recorded beside the lane
       # declaration above (BH-644) so the reaper that kills a hung lane can
       # close the row it was holding. Written to a temp file and moved into
       # place because bin/resume-dead-builds.sh reads this file and must never
       # catch it half-written. Never fatal: a build does not fail because a
       # bookkeeping key did not land.
       jq --arg j "$JOB_ID" '. + {job_id:$j}' "$BUILD/job.json" > "$BUILD/job.json.tmp" 2>/dev/null \
         && mv -f "$BUILD/job.json.tmp" "$BUILD/job.json" 2>/dev/null \
         || rm -f "$BUILD/job.json.tmp" 2>/dev/null
       true
# <<< job json id
       # Heartbeat for the life of the build (phase 3). A build is the longest
       # thing this fleet runs and the likeliest thing to be killed, and until
       # now a killed one left a row stuck at `running` forever — no evidence of
       # death, and the ticket blocked behind its own dead claim.
       job_heartbeat "$JOB_ID" claim >/dev/null 2>&1 || true
       JOB_BEAT=$(job_beat_start "$JOB_ID") || JOB_BEAT="" ;;
    9) # CLAIM REFUSED. Defer rather than race: something else is already
       # holding this work, and two PRs for one ticket is the expensive half of
       # this class. Deferring is reversible; a duplicate build is not.
       #
       # Two shapes arrive here and the log says which. "IN_FLIGHT <box> <id>"
       # is the phase-1 double-build guard. "REFUSED <scope> :: <reason>" is a
       # phase-6 concurrency rule — a repo or box already at its configured
       # limit, or a retry of this same work scheduled with a backoff still to
       # run — and it quotes the rule's OWN words, so the deferral names the
       # row an operator would edit instead of leaving them to guess.
       case "$JOB_CLAIM" in
         "REFUSED "*) echo "$(STAMP) [$PROJECT/$KEY] claim refused: ${JOB_CLAIM#REFUSED } — deferring, the DB says this may not start now" >> "$ALERTS" ;;
         *)           echo "$(STAMP) [$PROJECT/$KEY] double-build guard: $JOB_CLAIM — deferring, another box holds this ticket" >> "$ALERTS" ;;
       esac
       # exit 3 / BUILD_DEFERRED is this pipeline's existing word for "not now,
       # not a failure" — the queue re-offers the ticket on the next tick. A
       # refusal must never read as a failed build.
       RESULT "BUILD_DEFERRED $JOB_CLAIM"; exit 3 ;;
    *) JOB_ID="" ;;
  esac
fi

# --- The local launch path CLAIMS its queue row (2026-09-10) -------------------
# This build is about to run here. If a `build_queue` row exists for this key,
# take it: a claimed row is one the fly dispatcher will not hand to a machine
# and one Mission Control shows as in flight rather than waiting.
#
# BOOKKEEPING, NOT AUTHORITY. Whether this build may run at all was decided
# above by job_open — the fleet-wide, ticket-keyed guard with the concurrency
# rules behind it. Losing this compare-and-swap therefore logs and continues
# rather than deferring: a second refusal path here could only ever turn a
# legitimate build into a no-op, and the expensive failure this whole layer
# exists to stop is already covered.
#
# Gated on JOB_ID for a reason that matters: the EXIT trap that CLOSES the row
# is installed only on that path, so claiming without it would leave a row
# reading `claimed` forever with nobody to finish it. No claim, no row touched.
# >>> queue claim
QUEUE_CLAIMED=""
if [ -n "${JOB_ID:-}" ] && command -v queue_claim >/dev/null 2>&1; then
  queue_claim "$PROJECT" "" "$KEY" >/dev/null 2>&1; QRC=$?
  case "$QRC" in
    # rc 2 is the common case and is silent: no row for this key, because the
    # build was launched straight from a triage session rather than queued.
    0) QUEUE_CLAIMED=1 ;;
    # THE LEDGER CLAIM IS THE DEDUPE OF RECORD (W2-B, 2026-09-14). The per-key
    # flock above only ever saw THIS box, and 277 build-key lock files on one
    # pool machine is how little that is worth when the same key can be offered
    # to any of 4000 builders. The queued row is taken with a CONDITIONAL write
    # — the worker claims it only WHILE it is still `queued` and answers 409
    # when somebody else got there — so losing that race means another builder
    # owns this ticket, and the honest answer is to stand down rather than open
    # a second PR for one client request. exit 3 / BUILD_DEFERRED is this
    # pipeline's existing word for "not now, re-offer me": nothing is lost.
    # With the direct path off this stays exactly what it was — bookkeeping,
    # logged, and built through.
    9) if [ "${BUILDER_DIRECT_ON:-0}" = 1 ]; then
         echo "$(STAMP) [$PROJECT/$KEY] queue row claimed by another builder — standing down; the ledger claim is the dedupe, the box flock is only a same-box fast path" >> "$ALERTS"
         RESULT "BUILD_DEFERRED $KEY claimed by another builder"; exit 3
       fi
       echo "$(STAMP) [$PROJECT/$KEY] queue row was taken by another claimant — building anyway (job_open holds the claim)" >> "$ALERTS" ;;
  esac
fi
# <<< queue claim

# >>> reopen trust signal
# --- Trust measurement, DEMOTION ONLY (Wave D, 2026-08-25) ---------------------
# The reality anchor for a project is whether the client comes BACK.
# bin/reopen-metrics.sh (hub, daily) measures {"reopens_14d": N, "builds_total":
# D} per project — a ticket that regressed from review/done, or a GitHub issue
# reopened / re-labelled after close. A project whose rate is above
# REOPEN_DEMOTE_RATE has demonstrably been shipping work that did not hold, so it
# loses auto-merge until the rate falls.
#
# WHERE IT IS READ FROM (BH-117): the D1 `ledgers` row kind=reopen_rate, through
# jobs-client's reopen_rate_get, FIRST. state/reopen-rate.json is the fallback
# only, for no row, an outage or a malformed row. The file exists only on the
# hub, so before the row a watcher box always read no signal. Which source
# answered, or that none did, goes to pipeline.log on every build.
#
# Read ONCE here, used twice: the tier gate far below, and (behind a
# default-off flag) the review-lens count. Placed here because it must follow
# env/global.env — the documented home for the knobs below, which a read
# earlier in the file would silently ignore — and precede the lens seam.
#
# Three ways this changes nothing, all of them deliberate:
#   * no row and no file / unparseable / non-numeric -> no signal. A measurement outage
#     must never widen autonomy, and it must not narrow it on a guess either.
#   * builds_total < REOPEN_MIN_SAMPLE     -> no signal. 1 reopen out of 3
#     builds is 33% and means nothing; demoting off a denominator that small
#     would make the metric noise with consequences.
#   * rate at or below the threshold       -> no signal.
# There is no path here that GRANTS tier 1. Trust is withdrawn mechanically and
# returned only by the rate falling on its own.
REOPEN_HOT=0; REOPEN_NOTE=""
# The THRESHOLD is validated as hard as the measurement is. awk coerces a
# non-numeric -v to 0, so a fat-fingered REOPEN_DEMOTE_RATE=oops would make
# every rate "over 0" and demote the entire fleet on a typo. Junk falls back to
# the default rather than reading hot; the same guard on the sample floor.
RO_RATE="${REOPEN_DEMOTE_RATE:-0.15}"
case "$RO_RATE" in ''|*[!0-9.]*|*.*.*|.) RO_RATE=0.15 ;; esac
RO_MIN="${REOPEN_MIN_SAMPLE:-10}"
case "$RO_MIN" in ''|*[!0-9]*) RO_MIN=10 ;; esac
REOPEN_RATE_FILE="$HARNESS/state/reopen-rate.json"
RO_N=""; RO_D=""; RO_AT=""; RO_ROW=""; RO_SRC="none"
if command -v reopen_rate_get >/dev/null 2>&1 \
   && RO_ROW=$(reopen_rate_get "$PROJECT" 2>/dev/null); then
  IFS=$'\t' read -r RO_N RO_D RO_AT <<<"$RO_ROW"
  RO_SRC="db row ${RO_AT:-undated}"
elif [ -s "$REOPEN_RATE_FILE" ]; then
  RO_N=$(jq -r --arg p "$PROJECT" '.[$p].reopens_14d // empty' "$REOPEN_RATE_FILE" 2>/dev/null)
  RO_D=$(jq -r --arg p "$PROJECT" '.[$p].builds_total // empty' "$REOPEN_RATE_FILE" 2>/dev/null)
  RO_SRC="file $REOPEN_RATE_FILE"
fi
case "${RO_N:-x}${RO_D:-x}" in *[!0-9]*) RO_N=""; RO_D="" ;; esac
if [ -n "${RO_N:-}" ] && [ -n "${RO_D:-}" ] \
   && [ "$RO_D" -ge "$RO_MIN" ] \
   && awk -v n="$RO_N" -v d="$RO_D" -v t="$RO_RATE" \
          'BEGIN{exit !(d > 0 && t > 0 && n / d > t)}'; then
  REOPEN_HOT=1
  REOPEN_NOTE=$(awk -v n="$RO_N" -v d="$RO_D" -v t="$RO_RATE" \
    'BEGIN{printf "reopen rate %.2f (%d/%d, 14d) over %s", n/d, n, d, t}')
fi
echo "$(STAMP) [$PROJECT/$KEY] TRUST: reopen signal from $RO_SRC: ${RO_N:-?}/${RO_D:-?} — $([ "$REOPEN_HOT" = 1 ] && echo "$REOPEN_NOTE" || echo 'no demotion')" >> "$BUILD/pipeline.log" 2>/dev/null
# <<< reopen trust signal

# Base branch (2026-07-28): repos whose default branch is not main (e.g. project-10's dev)
# set BASE_BRANCH in their project env; every diff/checkout/PR targets it.
BASE="${BASE_BRANCH:-main}"
# >>> stacked child builds
# STACKED CHILD BUILDS (the operator, 2026-09-14). A child ticket whose Blocked-by
# parent has an OPEN PR used to sit idle until that PR merged to main — one full
# hour per chain level, and tonight TK-563..567 all spent it behind #611. The
# parent's work already exists on its branch, so STACK_BASE=<parent-branch>
# builds the child ON TOP of it: the branch is cut from origin/<parent>, plan,
# execute and the three review lenses all diff against <parent> (so reviewers
# read ONLY the child's change), the pre-PR rebase rebases onto <parent>, and
# the PR opens with --base <parent>. GitHub retargets that PR to $BASE_MAIN by
# itself when the parent merges and its branch is deleted; until then the merge
# conductor classifies it STACKED_WAIT and never merges it into a feature
# branch (docs/MERGE-CONDUCTOR.md section 3).
#
# EVERYTHING DOWNSTREAM IS UNTOUCHED because the stack is expressed as $BASE and
# nothing else: the ~30 checkout/diff/review/rebase/PR sites below already read
# that one variable. $BASE_MAIN keeps the real base for the two places that must
# still know it — the retarget note and the tier-1 merge hold.
#
# Kill flag: STACKED_BUILDS=0 in env/global.env, or flags/stacked-builds-off.
# Either one ignores STACK_BASE completely and this build is byte-for-byte the
# one today's harness would have run. Default ON.
BASE_MAIN="$BASE"
STACK_ON=""; STACK_NOTE=""
if [ -n "${STACK_BASE:-}" ]; then
  if [ "${STACKED_BUILDS:-1}" = 0 ] || [ -f "$HARNESS/flags/stacked-builds-off" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] STACK_BASE=$STACK_BASE ignored — stacked builds are switched off; building on $BASE" >> "$BUILD/pipeline.log"
  else
    # A branch name reaches this from a triage session's shell line, so it is
    # validated as a ref before it is ever interpolated into a git command.
    case "$STACK_BASE" in
      "$BASE"|''|-*|*[!A-Za-z0-9._/-]*|*..*)
        echo "$(STAMP) [$PROJECT/$KEY] STACK_BASE '$STACK_BASE' is not a usable stack base (unsafe name, or it IS the base) — building on $BASE" >> "$BUILD/pipeline.log" ;;
      *)
        # The fetch IS the existence probe, and it is done here rather than in
        # the worktree critical section below for the reason that section's own
        # comment gives: the lock is for the checkout mutation, never for a
        # network round trip. The refspec is explicit because pool warm repos
        # are single-branch `clone --depth 50` — a plain fetch would leave no
        # refs/remotes/origin/<parent> to cut from.
        #
        # A failure here is usually the GOOD outcome: the parent branch was
        # deleted because its PR merged between the tick that decided this and
        # this build starting. Fall back to the real base rather than dying.
        # >>> parent PR state (BH-6537)
        # A repo with delete_branch_on_merge=false keeps a merged parent's
        # branch, so the fetch alone read "still open" and TK-260 deferred 4
        # times after #275 merged. The PR's state decides first (sw_parent_pr):
        # merged/closed builds on $BASE without the fetch; unreadable with a
        # live branch waits, a merge is never assumed; open, none and unchecked
        # (no gh_rest or slug in this shell) leave branch existence to decide.
        SPR_ST=unchecked; SPR_N=""; SPR_URL=""
        # shellcheck source=bin/lib/stack-wait.sh
        command -v sw_parent_pr >/dev/null 2>&1 || . "$HARNESS/bin/lib/stack-wait.sh" 2>/dev/null
        command -v sw_parent_pr >/dev/null 2>&1 \
          && read -r SPR_ST SPR_N SPR_URL <<<"$(sw_parent_pr "${GH_AUTH_SLUG:-}" "$STACK_BASE" 2>/dev/null)"
        [ -n "$SPR_ST" ] || SPR_ST=unchecked
        # <<< parent PR state (BH-6537)
        if [ "$SPR_ST" = merged ] || [ "$SPR_ST" = closed ]; then
          SPR_HOW=merged; [ "$SPR_ST" = merged ] || SPR_HOW="closed without a merge"
          echo "$(STAMP) [$PROJECT/$KEY] stack-wait: parent PR #$SPR_N is $SPR_HOW and its branch $STACK_BASE still exists — building on $BASE, not stacked" >> "$BUILD/pipeline.log"
        elif git -C "$REPO" fetch origin "+refs/heads/$STACK_BASE:refs/remotes/origin/$STACK_BASE" --quiet 2>/dev/null; then
          if [ "$SPR_ST" = unreadable ]; then
            echo "$(STAMP) [$PROJECT/$KEY] stack-wait: the state of parent PR for branch $STACK_BASE could not be read (rc $SPR_N) — deferred, a merge is never assumed" >> "$BUILD/pipeline.log"
            command -v _sw_log >/dev/null 2>&1 && _sw_log "$PROJECT" "$KEY" "parent-pr=unreadable rc=$SPR_N parent=$STACK_BASE (deferred)"
            RESULT "BUILD_DEFERRED stack-wait: the state of parent PR for branch $STACK_BASE could not be read (rc $SPR_N) — waiting; a merge is never assumed"
            exit 3
          fi
          case "$SPR_ST" in
            open) [ -z "${STACK_PARENT_PR:-}" ] && [ -n "$SPR_URL" ] && STACK_PARENT_PR="$SPR_URL" ;;
            *) echo "$(STAMP) [$PROJECT/$KEY] stack-wait: parent PR state $SPR_ST for $STACK_BASE — branch existence decides" >> "$BUILD/pipeline.log" ;;
          esac
          # WAIT FOR THE PARENT TO MERGE (BH-5234). STACK_WAIT_PARENT_MERGE
          # (bin/lib/stale-parent.sh sp_wait_mode; off|rollouts|all|plan,
          # default plan): `all` never stacks, `rollouts` does not stack a
          # rollout wave child (`Rollout wave N of M:` in its issue body), which
          # is the shape whose parent kept being rewritten under it. Decided
          # here, before any model spend; the next tick re-offers the ticket and
          # the parent's branch is gone once it merged. An issue body that cannot
          # be read under `rollouts` waits too. A board project has no issue:
          # only `all` defers there. `plan` (BH-6389) is `rollouts` plus the
          # stack plan gate below.
          SW_MODE=rollouts; SW_WHY=""; SWP_ACT=""
          # shellcheck source=bin/lib/stale-parent.sh
          command -v sp_wait_mode >/dev/null 2>&1 || . "$HARNESS/bin/lib/stale-parent.sh" 2>/dev/null
          command -v sp_wait_mode >/dev/null 2>&1 && SW_MODE=$(sp_wait_mode "$PROJECT" 2>/dev/null)
          case "$SW_MODE" in
            all) SW_WHY=all ;;
            off) ;;
            *)
              [ "$SW_MODE" = plan ] || SW_MODE=rollouts
              if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ] \
                 && [[ "${TICKET:-}" =~ ^[0-9]+$ ]] && [ -n "${GH_AUTH_SLUG:-}" ]; then
                SW_RC=0; SW_T=$(mktemp "${TMPDIR:-/tmp}/stack-wait.XXXXXX") || SW_RC=75
                [ "$SW_RC" = 0 ] && { gh_rest GET "repos/$GH_AUTH_SLUG/issues/$TICKET" > "$SW_T" || SW_RC=$?; }
                if [ "$SW_RC" != 0 ]; then
                  SW_WHY="rollouts (the issue body of #$TICKET could not be read, rc $SW_RC)"
                elif grep -qE '^Rollout wave [0-9]+ of [0-9]+:' <<<"$(jq -r '.body // ""' "$SW_T" 2>/dev/null)"; then
                  SW_WHY="rollouts (#$TICKET is a rollout wave)"
                fi
                rm -f "${SW_T:-}"
              fi ;;
          esac
          if [ -n "$SW_WHY" ]; then
            echo "$(STAMP) [$PROJECT/$KEY] stack-wait: parent branch $STACK_BASE is still open and STACK_WAIT_PARENT_MERGE=$SW_WHY — deferred, not stacked" >> "$BUILD/pipeline.log"
            RESULT "BUILD_DEFERRED stack-wait: parent branch $STACK_BASE is still open and STACK_WAIT_PARENT_MERGE=$SW_WHY — the child builds after the parent merges"
            exit 3
          fi
          # >>> stack plan gate (BH-6389)
          # A child on an OPEN parent stacks only when its plan's `## Stack`
          # files are disjoint from the parent's (bin/lib/stack-wait.sh sw_pre).
          # pending: plan on the parent, and the `stack plan check (BH-6389)`
          # block at the top of rb_gate_overlap decides; wait: a deferral is
          # already on record and under STACK_WAIT_CAP_H, so no plan is bought;
          # capped: build from the real base without the parent; exempt: a
          # hotfix stacks as before. No lib on the box: today's stack.
          if [ "$SW_MODE" = plan ]; then
            # shellcheck source=bin/lib/stack-wait.sh
            command -v sw_pre >/dev/null 2>&1 || . "$HARNESS/bin/lib/stack-wait.sh" 2>/dev/null
            if command -v sw_pre >/dev/null 2>&1; then
              read -r SWP_ACT SWP_H SWP_CAP <<<"$(sw_pre "$PROJECT" "$KEY" "$STACK_BASE" 2>/dev/null)"
              SWP_N=$(sw_pkey "$STACK_BASE"); SWP_REF="#$SWP_N"; [ -n "$SWP_N" ] || SWP_REF="$STACK_BASE"
              case "${SWP_ACT:-}" in
                exempt)
                  echo "$(STAMP) [$PROJECT/$KEY] stack-wait: hotfix exempt — stacking on $STACK_BASE" >> "$BUILD/pipeline.log" ;;
                wait)
                  echo "$(STAMP) [$PROJECT/$KEY] stack-wait: parent branch $STACK_BASE is still open and $KEY has waited ${SWP_H}h of STACK_WAIT_CAP_H=${SWP_CAP}h — deferred before the plan" >> "$BUILD/pipeline.log"
                  RESULT "BUILD_DEFERRED stack-wait: parent branch $STACK_BASE is still open and $KEY has waited ${SWP_H}h of STACK_WAIT_CAP_H=${SWP_CAP}h — Blocked-by $SWP_REF; the child builds after the parent merges"
                  exit 3 ;;
                capped)
                  SWP_SINCE=$(sw_row_get "$PROJECT" "$KEY" "$STACK_BASE" 2>/dev/null | awk '{print $2}')
                  sw_row_put "$PROJECT" "$KEY" "$STACK_BASE" capped "${SWP_SINCE:-0}" "STACK_WAIT_CAP_H=${SWP_CAP}h reached" \
                    || echo "$(STAMP) [$PROJECT/$KEY] stack-wait: the capped row could not be written (ledger and file both failed)" >> "$BUILD/pipeline.log"
                  echo "$(STAMP) [$PROJECT/$KEY] stack-wait: STACK_WAIT_CAP_H=${SWP_CAP}h reached (waited ${SWP_H}h) for parent $STACK_BASE — building $KEY from $BASE without the parent" >> "$BUILD/pipeline.log" ;;
                *)
                  SWP_ACT=pending
                  { printf '%s\n' "$STACK_BASE"; sw_parent_files "$REPO" "$BASE_MAIN" "$STACK_BASE" 2>/dev/null; } > "$BUILD/stack-wait-pending" ;;
              esac
            fi
          fi
          # <<< stack plan gate (BH-6389)
          if [ "${SWP_ACT:-}" != capped ]; then
            STACK_ON="$STACK_BASE"; BASE="$STACK_ON"
            # The parent PR's URL is what a human reading the board comment or
            # the PR body actually clicks. The launcher may pass it (the
            # STACKABLE line carries it); otherwise it is one cheap lookup off
            # the branch. Empty is fine everywhere it is printed — the sentence
            # still reads.
            if [ -z "${STACK_PARENT_PR:-}" ]; then
              STACK_PARENT_PR=$(gh pr list -R "$(git -C "$REPO" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')" --head "$STACK_ON" --state open --json url -q '.[0].url' 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
            fi
            STACK_NOTE=" | STACKED on $STACK_ON (${STACK_PARENT_PR:-parent PR not resolved}) — this PR is based on the parent's branch and retargets to $BASE_MAIN when the parent merges"
            echo "$(STAMP) [$PROJECT/$KEY] STACKED on $STACK_ON (${STACK_PARENT_PR:-parent PR url not resolved}) — branch cut from origin/$STACK_ON, diffs/review/PR all target it" >> "$BUILD/pipeline.log"
          fi
        else
          echo "$(STAMP) [$PROJECT/$KEY] STACK_BASE $STACK_BASE could not be fetched from origin (parent merged and its branch was deleted?) — building on $BASE" >> "$BUILD/pipeline.log"
        fi ;;
    esac
  fi
fi
# <<< stacked child builds

# >>> model tiering
# Model tiering (cost lever 2): every stage's model is a model_routes row
# (BH-1510.1), read through bin/lib/model-route.sh — retier with the console's
# MODELS screen or PUT /api/model-routes, per project or for the hub, with no
# redeploy. A value in env/global.env or env/<project>.env still wins, exactly
# as it did when the fallback was a literal here.
#
# The two derived roles keep their old meaning for a box that pins by env: an
# env REVIEW_MODEL is still what a T0 diff (docs/tests/CI-config only) is read
# on unless REVIEW_MODEL_T0 says otherwise (BH-485), and an env EXECUTE_MODEL
# is still what a fix round runs on unless FIX_MODEL does. With neither set,
# each has its own row (build.review.t0, build.fix).
#
# NO ROUTE, NO BUILD. A role with no row and no cached answer on this box stops
# the build here, before any model is called: deferred (exit 3, the pipeline's
# "not now"), so the queue offers the ticket again once a route exists. The
# resolver has already written the one ALERTS line naming the role. A guessed
# model would just be the literal this block used to carry, in a new place.
[ -n "${REVIEW_MODEL:-}" ] && REVIEW_MODEL_T0="${REVIEW_MODEL_T0:-$REVIEW_MODEL}"
[ -n "${EXECUTE_MODEL:-}" ] && FIX_MODEL="${FIX_MODEL:-$EXECUTE_MODEL}"
# shellcheck source=bin/lib/model-route.sh
[ -r "$HARNESS/bin/lib/model-route.sh" ] && . "$HARNESS/bin/lib/model-route.sh"
for _mr in PLAN_MODEL:build.plan EXECUTE_MODEL:build.execute REVIEW_MODEL:build.review \
           REVIEW_MODEL_T0:build.review.t0 FIX_MODEL:build.fix QA_MODEL:build.qa; do
  _mv="${_mr%%:*}"
  if ! command -v model_env_or_route >/dev/null 2>&1; then
    [ -n "${!_mv:-}" ] && continue
    echo "$(STAMP) [$PROJECT/$KEY] bin/lib/model-route.sh is missing on $(hostname) and ${_mr%%:*} is not set in env — nothing was built (half-synced bin/?)" >> "$ALERTS"
    RESULT "BUILD_DEFERRED no model route for ${_mr#*:} (bin/lib/model-route.sh missing on $(hostname))"; exit 3
  fi
  model_env_or_route "${_mr%%:*}" "${_mr#*:}" "$PROJECT" && continue
  echo "$(STAMP) [$PROJECT/$KEY] no model route for ${_mr#*:} (${_mr%%:*}) — deferring; nothing was called" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED no model route for ${_mr#*:} — seed model_routes or PUT /api/model-routes"; exit 3
done
unset _mr _mv
# <<< model tiering

# Persistent per-build worktree (2026-07-23, 100GB era): builds of the SAME
# project run side by side in their own checkout, and node_modules/.next persist
# there across builds (execute sessions npm-install as needed per CLAUDE.md).
#
# WHAT MAKES IT EXCLUSIVE decides the name. With BUILD_SLOTS > 0 the slot flock
# does — one holder per slot, so <project>-slot<N> is safe and reuse is maximal.
# With BUILD_SLOTS=0 (unlimited, the default since 2026-09-13) there is no slot
# lock, so the name comes from the KEY instead: the per-key dedupe flock this
# pipeline already holds guarantees exactly one build per key on this box, and two
# builds of the same project get two directories rather than trampling one.
# bin/disk-clean.sh collects the ones that go quiet (clean, pushed, untouched 48h).
if [ -n "$GOT" ]; then WT="/root/worktrees/$PROJECT-slot$GOT"
else WT="/root/worktrees/$PROJECT-$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')"; fi
# THE ONE WAIT LEFT IN THIS FILE, and it is a critical section, not a queue: the
# shared checkout can only be fast-forwarded and `worktree add`ed by one process
# at a time, which is a few seconds of git, never a build's lifetime. It is held
# around exactly those commands and released before the pipeline does any work.
#
# STACKED: the base is the parent's branch, and it is made resolvable with
# `update-ref` rather than `checkout` on purpose. The parent's own build leaves
# ticket/<parent-key> checked out in ITS persistent worktree, so checking the
# same name out here would move a branch under a live worktree — and the shared
# checkout's HEAD has no business sitting on a feature branch either. The ref is
# all the worktree add, the diffs and the rebase below actually need.
(
  exec 6>"$HARNESS/locks/build-repo-$PROJECT.lock"
  flock -w 300 6 || exit 1
  cd "$REPO" || exit 1
  if [ -n "$STACK_ON" ]; then git update-ref "refs/heads/$BASE" "refs/remotes/origin/$BASE" || exit 1   # stacked: fetched above, outside this lock; a REF, never a checkout (see below)
  else git checkout "$BASE" --quiet && git pull --ff-only --quiet origin "$BASE" || exit 1; fi
  git worktree prune
  [ -d "$WT" ] || git worktree add --detach "$WT" "$BASE" --quiet || exit 1
) || { echo "$(STAMP) [$PROJECT/$KEY] worktree setup failed" >> "$ALERTS"; RESULT "BUILD_DEFERRED worktree setup failed"; exit 3; }

BRANCH="ticket/$(echo "$KEY" | tr '[:upper:]' '[:lower:]')"
# >>> branch suffix
# BRANCH_SUFFIX (2026-09-13, bin/blocked-resolver.sh). A fresh rebuild of a key
# whose earlier branch is still on the remote — which is ALWAYS the case after
# the resolver closes a stale PR, because the branch behind a closed PR is never
# deleted — names itself explicitly (ticket/TK-510-r2) instead of leaning on the
# taken-name bump below. The bump stays as the backstop and still runs: if the
# suffixed name is ALSO taken, it walks on to -r3. Unset, this line does nothing
# and every existing launch path is byte-identical.
[ -n "${BRANCH_SUFFIX:-}" ] && BRANCH="$BRANCH$BRANCH_SUFFIX"
# <<< branch suffix
cd "$WT"
# Checkpoint-resume: the original run recorded its branch; re-enter it. A branch
# that was pushed resumes via the TARGET_BRANCH path below; one that never got
# pushed still exists as a repo-level local ref, picked up in the same path.
if [ -n "${RESUME_BUILD:-}" ] && [ -s "$BUILD/branch" ] && [ -z "${TARGET_BRANCH:-}" ]; then
  TARGET_BRANCH=$(cat "$BUILD/branch")
  echo "$(STAMP) [$PROJECT/$KEY] resume: re-entering recorded branch $TARGET_BRANCH" >> "$BUILD/pipeline.log"
fi
# Review-fix rounds (TK-700/TK-662 class, 2026-08-15): when the dispatcher names
# an existing PR head via TARGET_BRANCH, CONTINUE on it — a fix commit on a new
# branch strands with no PR and nothing picks it up. Continue-mode checks out
# the remote head instead of cutting a fresh branch from base; a resume whose
# branch never reached origin falls back to the local ref (worktrees share it).
# Pool warm repos are `git clone --depth 50` = single-branch, so neither
# `git fetch origin <branch>` nor a successful push creates
# refs/remotes/origin/<branch>. `--force-with-lease` (no args) leases on that
# ref: missing ref = "remote must not exist" = every second push of a branch
# is REJECTED (2026-09-11: 8/8 pool builds deferred at the PR push after the
# #244 backup push). Keep the lease meaningful: record what WE pushed, and
# fetch continue-mode heads with an explicit refspec.
track_pushed(){ git update-ref "refs/remotes/origin/$BRANCH" "$(git rev-parse HEAD)" 2>/dev/null || true; }
# ...and lease on it EXPLICITLY. `--force-with-lease` with no value resolves the
# expected sha through the remote's FETCH refspec, not by reading
# refs/remotes/origin/<branch> — in a single-branch clone that mapping does not
# exist, so update-ref alone still yields "remote must not exist" and every push
# after the first is rejected "(stale info)" (verified 2026-09-12, git 2.43,
# project-4 TK-1587 attempt 2: remote never moved, fix-round + pre-PR pushes both
# rejected). An explicit <branch>:<sha> lease needs no refspec; an empty sha
# keeps the "must not exist yet" guard for the first push of a fresh branch.
# RB_PUSH [-u] [<stage>] — EVERY push of $BRANCH from this pipeline (BH-2504).
# The lease is explicit: what WE last pushed, or "must not exist yet", and the
# ticket's HOLD is re-read at each push through bin/lib/hold-push.sh: a lead who
# held the ticket while this build ran owns the branch now (#2592 was rebuilt
# under a HOLD on 2026-09-25). rc = hold_push's.
#
# A HELD PUSH YIELDS THE BUILD (BH-6091). <stage> names the write point
# (default `push`). When hold_push answers rc 3 (held), RB_HOLD_YIELD writes
# `HOLD_YIELD <KEY> at <stage>` to pipeline.log and RESULT and exits 3: nothing
# is pushed and the commits stay in this worktree. An unreadable hold (rc 4) is
# held for this write only: no push, rc 4 back to the caller, and the next
# write point reads the hold again.
# shellcheck source=bin/lib/hold-push.sh
[ -r "$HARNESS/bin/lib/hold-push.sh" ] && . "$HARNESS/bin/lib/hold-push.sh" 2>/dev/null
# RB_HOLD_YIELD <stage> <why> — the build stops at this write point. In the
# main shell it writes RESULT and exits 3, the exit HOLD_STAGE_CHECK takes. In
# a subshell (the background E2E lane) an exit ends only the subshell, so it
# returns 3 with no RESULT, and the main shell yields at its next write point.
# Once the PR is open (RB_PR_OPEN=1, set right after the create block), a hold
# yields THAT write only: the build must still record PR_CREATED with its URL,
# so the yield is a note (HOLD_YIELD_NOTE, carried on the PR_CREATED line), not
# an exit (review of e68d8e58: a HOLD during the QA fix session).
RB_HOLD_YIELD(){
  echo "$(STAMP) [$PROJECT/$KEY] HOLD_YIELD $KEY at $1 — $2; nothing pushed, the work stays in $PWD" >> "$BUILD/pipeline.log"
  if [ -n "${RB_PR_OPEN:-}" ]; then
    HOLD_YIELD_NOTE="${HOLD_YIELD_NOTE:-} | HOLD_YIELD $KEY at $1 — the ticket says $2; that push was skipped, the PR stays open"
    return 3
  fi
  [ "$BASHPID" = "$$" ] || return 3
  RESULT "BUILD_DEFERRED HOLD_YIELD $KEY at $1 — the ticket says $2; a newer RESUME on the ticket lifts it"
  exit 3
}
# RB_HOLD_GATE <stage> — the hold read for a write that is not a push (PR open).
# rc 0 clear. Held: RB_HOLD_YIELD. rc 2 unreadable or no hold library: the
# caller skips this write. The reader is hold_push_verdict, the one RB_PUSH uses.
RB_HOLD_GATE(){
  local v rc
  command -v hold_push_verdict >/dev/null 2>&1 || { echo "$(STAMP) [$PROJECT/$KEY] bin/lib/hold-push.sh missing at $1 — this write is skipped" >> "$BUILD/pipeline.log"; return 2; }
  v=$(hold_push_verdict "$PROJECT" - "$BRANCH"); rc=$?
  case "$rc" in
    0) return 0 ;;
    1) RB_HOLD_YIELD "$1" "${v#*	}"; return 3 ;;
  esac
  echo "$(STAMP) [$PROJECT/$KEY] hold unreadable at $1 (${v#*	}) — this write is skipped" >> "$BUILD/pipeline.log"
  return 2
}
RB_PUSH(){
  local up=() l stage rc=0
  [ "${1:-}" = -u ] && { up=(-u); shift; }
  stage="${1:-push}"
  l=$(git rev-parse -q --verify "refs/remotes/origin/$BRANCH" 2>/dev/null) || l=""
  command -v hold_push >/dev/null 2>&1 || { echo "$(STAMP) [$PROJECT/$KEY] bin/lib/hold-push.sh missing — $BRANCH NOT pushed" >> "$BUILD/pipeline.log"; return 1; }
  HOLD_PUSH_LOG="$BUILD/pipeline.log" hold_push ${up[@]+"${up[@]}"} "$PROJECT" - "$PWD" origin "$BRANCH" "$BRANCH" "${l:-new}" || rc=$?
  [ "$rc" = 3 ] && RB_HOLD_YIELD "$stage" "the ticket is held (see the hold-push line above)"
  return "$rc"
}
# SQUASH_OK: may this pipeline rewrite the branch's history before the PR? Only
# for a branch it cut itself. A dispatcher-supplied TARGET_BRANCH is an existing
# PR's head — rewriting it would orphan a review and confuse the PR's own diff.
SQUASH_OK=1
if [ -n "${TARGET_BRANCH:-}" ]; then
  BRANCH="$TARGET_BRANCH"
  # ...except a resume re-entering its OWN recorded branch, which never had a PR
  # (bin/lib/resume-dead.sh refuses any build whose branch carries an open
  # one). Leaving that case at 0 would ship the resumed build's checkpoints into
  # its PR history for no reason.
  if [ -z "${RESUME_BUILD:-}" ] || [ "$TARGET_BRANCH" != "$(cat "$BUILD/branch" 2>/dev/null)" ]; then
    SQUASH_OK=0
  fi
  if git fetch origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet 2>/dev/null; then
    git reset --hard --quiet
    git checkout --detach "$BASE" --quiet
    git branch -D "$BRANCH" 2>/dev/null
    git checkout -b "$BRANCH" "origin/$BRANCH" --quiet || { echo "$(STAMP) [$PROJECT/$KEY] cannot check out origin/$BRANCH" >> "$ALERTS"; RESULT "BUILD_DEFERRED cannot check out origin/$BRANCH — retried by the next resume"; exit 3; }  # F3
  elif git rev-parse --verify "refs/heads/$BRANCH" >/dev/null 2>&1; then
    git reset --hard --quiet
    git checkout --detach "$BASE" --quiet
    git checkout "$BRANCH" --quiet 2>/dev/null || git checkout -B "$BRANCH" "refs/heads/$BRANCH" --quiet \
      || { echo "$(STAMP) [$PROJECT/$KEY] local branch $BRANCH held by another worktree — cannot resume here" >> "$ALERTS"; RESULT "BUILD_DEFERRED resume branch $BRANCH locked"; exit 3; }
  else
    echo "$(STAMP) [$PROJECT/$KEY] TARGET_BRANCH $BRANCH not fetchable and no local ref" >> "$ALERTS"; RESULT "BUILD_DEFERRED target branch $BRANCH not fetchable"; exit 3
  fi
  git clean -fd -e node_modules -e .next --quiet
  echo "$(STAMP) [$PROJECT/$KEY] continue-mode: building on existing head $BRANCH" >> "$BUILD/pipeline.log"
else
# Branch-per-attempt uniquification (medic alert 2026-08-13): the remote may
# still hold this name from an earlier attempt whose PR already merged — the
# push then rejects and the finished build dies with its reaped machine
# (TK-143 twice tonight; same class as TK-82/TK-160/TK-115). Never delete the
# remote branch (an open PR could hang off it) — take the first free name.
TAKEN=$(git ls-remote --heads origin "$BRANCH*" 2>/dev/null | awk '{print $2}')
# >>> checkpoint adopt (tests/run-build-checkpoint-test.sh drives this block)
# LANE CHECKPOINTS (2026-09-15, docs/CHECKPOINTS.md). "The name is taken on the
# remote" used to mean exactly one thing — an earlier attempt got far enough to
# push, so take the next free name. Now that bin/lane-checkpoint.sh pushes from
# INSIDE the execute stage it also means "a lane died mid-build and its tree is
# sitting on origin", and those two cases must not be treated the same: a branch
# still carrying `wip: checkpoint` commits at its tip never reached the PR step
# (every finished build squashes them away first), so cutting ticket/<key>-r2
# beside it throws away real, finished work. That is the rebuild that made the
# operator push project-5 #1156 by hand.
#
# The decision is bin/lane-checkpoint.sh --resume-branch's, not this file's: it
# reads the REMOTE (the disk that held the last attempt is usually gone), takes
# the newest attempt, and skips any branch with an open PR because that head
# belongs to the dispatcher's TARGET_BRANCH path instead.
#
# LOOKED UP ON THE UNSUFFIXED NAME, deliberately. bin/blocked-resolver.sh
# enqueues every rebuild with branch_suffix=-rN, so BRANCH is already
# ticket/<key>-r2 by the time we get here and a lookup on THAT name would miss
# the very branch the dead lane left at ticket/<key>. --resume-branch scans the
# name plus its -rN family newest-first, so handing it the stem covers both, and
# an earlier attempt that reached a PR is skipped on the open-PR test rather than
# on its name.
CKPT_START_POINT=""; CKPT_WIP_N=0
CKPT_LOOKUP=$(printf '%s' "$BRANCH" | sed -E 's/-r[0-9]+$//')
if CKPT_RESUME_LINE=$("$HARNESS/bin/lane-checkpoint.sh" --resume-branch "$WT" "$CKPT_LOOKUP" "$BASE" 2>/dev/null) \
   && [ -n "$CKPT_RESUME_LINE" ]; then
  CKPT_RB=${CKPT_RESUME_LINE%%|*}; CKPT_RB_REST=${CKPT_RESUME_LINE#*|}; CKPT_WIP_N=${CKPT_RB_REST%%|*}
  case "$CKPT_WIP_N" in ''|*[!0-9]*) CKPT_WIP_N=0 ;; esac
  if [ -n "$CKPT_RB" ] && [ "$CKPT_WIP_N" -gt 0 ]; then
    BRANCH="$CKPT_RB"; CKPT_START_POINT="origin/$BRANCH"
    echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: origin/$BRANCH carries $CKPT_WIP_N checkpoint commit(s) and no open PR — adopting that branch instead of rebuilding beside it" >> "$BUILD/pipeline.log"
    # HEAL A SHALLOW CLONE BEFORE ANYTHING DIFFS AGAINST $BASE (BH-1319). A pool
    # warm repo is `git clone --depth 50` (fly/Dockerfile), and a checkpoint
    # branch whose fork point is older than that boundary has NO merge-base with
    # $BASE at all: `git diff $BASE...HEAD` exits 128, CKPT_SQUASH_WIP refuses,
    # and the tamper scan reads the whole branch as a deletion. One plain
    # unshallow restores the ancestry — the conductor's mc_unshallow_once shape,
    # gated on --is-shallow-repository AND on the merge-base actually being
    # missing, so a complete clone and a fork inside the boundary both pay
    # nothing. Never fatal: a failed heal is logged with git's rc and the
    # adoption stands.
    CKPT_MB=$(git merge-base "$BASE" "$CKPT_START_POINT" 2>/dev/null)
    if [ -z "$CKPT_MB" ] && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
      # Written BEFORE the fetch: a remote that hangs costs this build its tick,
      # and a wait nobody can see is the expensive half of that.
      echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: no merge-base($BASE, $CKPT_START_POINT) in this clone and it is SHALLOW ($(wc -l < "$(git rev-parse --git-path shallow)" 2>/dev/null | tr -d ' ') boundary commit(s)) — git fetch --unshallow origin, once, before anything diffs against $BASE" >> "$BUILD/pipeline.log"
      if timeout "${CHECKPOINT_UNSHALLOW_SECS:-900}" git fetch -q --unshallow origin >> "$BUILD/pipeline.log" 2>&1; then
        CKPT_MB=$(git merge-base "$BASE" "$CKPT_START_POINT" 2>/dev/null)
        echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: unshallowed $(pwd)" >> "$BUILD/pipeline.log"
      else
        CKPT_UNSHALLOW_RC=$?
        echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: git fetch --unshallow origin failed (rc $CKPT_UNSHALLOW_RC) — the clone stays shallow; the squash will refuse and the wip commits ship unsquashed" >> "$BUILD/pipeline.log"
      fi
    fi
    if [ -n "$CKPT_MB" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: merge-base ${CKPT_MB:0:8} — $BASE is $(git rev-list --count "$CKPT_MB..$BASE" 2>/dev/null || echo '?') commit(s) past the fork, $CKPT_START_POINT carries $(git rev-list --count "$CKPT_MB..$CKPT_START_POINT" 2>/dev/null || echo '?') commit(s) on top of it" >> "$BUILD/pipeline.log"
    else
      echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: merge-base($BASE, $CKPT_START_POINT) UNRESOLVED — three-dot diffs against $BASE will fail and CKPT_SQUASH_WIP will refuse" >> "$BUILD/pipeline.log"
    fi
  else
    CKPT_WIP_N=0
  fi
fi
# <<< checkpoint adopt
if [ -z "$CKPT_START_POINT" ] && grep -qx "refs/heads/$BRANCH" <<<"$TAKEN"; then
  RN=2; while grep -qx "refs/heads/$BRANCH-r$RN" <<<"$TAKEN"; do RN=$((RN+1)); done
  BRANCH="$BRANCH-r$RN"
  echo "$(STAMP) [$PROJECT/$KEY] branch name taken on remote — building as $BRANCH" >> "$BUILD/pipeline.log"
fi
git reset --hard --quiet
git checkout --detach "$BASE" --quiet
git branch -D "$BRANCH" 2>/dev/null
git checkout -b "$BRANCH" ${CKPT_START_POINT:+"$CKPT_START_POINT"} --quiet || { echo "$(STAMP) [$PROJECT/$KEY] branch $BRANCH unavailable (held by a stale worktree?)" >> "$ALERTS"; RESULT "BUILD_DEFERRED branch $BRANCH unavailable, held by a stale worktree — retried next tick"; exit 3; }  # F4
git clean -fd -e node_modules -e .next --quiet
fi
} # end rb_gate_claim_and_workspace

rb_gate_overlap() {
# >>> stack plan check (BH-6389)
# The post-plan half of the stack plan gate in `stacked child builds`. That
# block planned this child on its parent's OPEN branch and left
# $BUILD/stack-wait-pending; the plan now has to carry a `## Stack` section
# whose files are disjoint from the parent's diff and plan files
# (bin/lib/stack-wait.sh sw_post). Approved: record `stacked` and go on.
# Anything else: record `waiting` (the first deferral's time is kept, it is the
# STACK_WAIT_CAP_H clock), post one Blocked-by comment, then defer. Ledger,
# then comment, then RESULT: the row exists before anything says so.
if [ -e "$BUILD/stack-wait-pending" ] && [ -n "${STACK_ON:-}" ]; then
  # shellcheck source=bin/lib/stack-wait.sh
  command -v sw_post >/dev/null 2>&1 || . "$HARNESS/bin/lib/stack-wait.sh" 2>/dev/null
  if command -v sw_post >/dev/null 2>&1; then
    SWC_OUT=$(sw_post "$BUILD" "$REPO" "${BASE_MAIN:-main}" "$STACK_ON" 2>/dev/null)
    case "$SWC_OUT" in
      "stack "*)
        read -r _ SWC_C SWC_P <<<"$SWC_OUT"
        sw_row_put "$PROJECT" "$KEY" "$STACK_ON" stacked "$(sw_now)" "Stack section approved" \
          || echo "$(STAMP) [$PROJECT/$KEY] stack-wait: the stacked row could not be written (ledger and file both failed)" >> "$BUILD/pipeline.log"
        rm -f "$BUILD/stack-wait-pending"
        echo "$(STAMP) [$PROJECT/$KEY] stack-wait: Stack section approved — $SWC_C child files disjoint from $SWC_P parent files on $STACK_ON" >> "$BUILD/pipeline.log" ;;
      *)
        SWC_WHY="${SWC_OUT#defer }"
        [ -n "$SWC_WHY" ] && [ "$SWC_WHY" != "$SWC_OUT" ] || SWC_WHY="the stack check gave no answer"
        SWC_SINCE=""
        read -r SWC_ST SWC_SINCE <<<"$(sw_row_get "$PROJECT" "$KEY" "$STACK_ON" 2>/dev/null)"
        case "${SWC_ST:-}:${SWC_SINCE:-}" in waiting:[1-9]*) ;; *) SWC_SINCE=$(sw_now) ;; esac
        sw_row_put "$PROJECT" "$KEY" "$STACK_ON" waiting "$SWC_SINCE" "$SWC_WHY" \
          || echo "$(STAMP) [$PROJECT/$KEY] stack-wait: the waiting row could not be written (ledger and file both failed)" >> "$BUILD/pipeline.log"
        sw_note "$PROJECT" "$KEY" "$STACK_ON" "$SWC_WHY" "$BUILD"
        SWC_N=$(sw_pkey "$STACK_ON"); SWC_REF="#$SWC_N"; [ -n "$SWC_N" ] || SWC_REF="$STACK_ON"
        SWC_CAP=$(sw_cap "$PROJECT")
        echo "$(STAMP) [$PROJECT/$KEY] stack-wait: $KEY's plan builds on open parent $STACK_ON and $SWC_WHY — deferred until the parent merges or STACK_WAIT_CAP_H=${SWC_CAP}h" >> "$BUILD/pipeline.log"
        RESULT "BUILD_DEFERRED stack-wait: $KEY's plan builds on open parent $STACK_ON and $SWC_WHY — Blocked-by $SWC_REF; the child builds from ${BASE_MAIN:-main} after the parent merges, or at STACK_WAIT_CAP_H=${SWC_CAP}h"
        exit 3 ;;
    esac
  fi
fi
# <<< stack plan check (BH-6389)
# >>> priority yield
# --- PRIORITY YIELD (#647, BH-643 fix 3) -------------------------------------
# THE OVERLAP DEFERRAL BELOW DOES NOT KNOW WHO IS URGENT. Two builds that claim
# the same file cannot both run, and until now the tie was broken by arrival
# order alone: whoever got there first keeps the claim, and the other one is
# handed back to the queue until that claim disappears — a RESULT, or the 4h
# ageout at :1794. For an ordinary pair that is exactly right. For a hotfix
# behind a plain build it is four hours of an emergency waiting on work nobody
# called urgent, and no line anywhere says so.
#
# So when the deferring build OUTRANKS the sibling holding the claim, it leaves
# a marker in that sibling's build dir and the sibling stands down at its next
# safe stage boundary. Two halves, one switch:
#   the REQUEST — inside the deferral branch of `# >>> overlap wait` below;
#   the RELEASE — YIELD_CHECK, called at three boundaries further down.
#
# THIS IS NOT A QUEUE AND NOTHING WAITS (the operator, 2026-09-13). The deferring build
# still exits 3 immediately; it just leaves behind a reason for the claim to
# clear in minutes instead of hours. The yielding build does not pause either —
# it writes a terminal and gets out of the way. Nobody blocks on anybody.
#
# RANKS ARE bin/lib/hotfix-lib.sh's, not a second opinion: 0 hotfix, 1 main-red,
# 2 everything else, and an unreadable ticket-meta.json is 2. Reading "unknown"
# as urgent would let every build dir written before that file existed evict an
# emergency, which is the failure this whole lane exists to prevent.
#
# KILL SWITCH: PRIORITY_YIELD=0 (env, or env/global.env, sourced at :379) and
# flags/priority-yield-off for a console-side switch. Either one makes both
# halves no-ops and this pipeline byte-for-byte what it was before.
PY_ON() { # PY_ON -> rc 0 when the priority yield is armed
  [ -e "$HARNESS/flags/priority-yield-off" ] && return 1
  # `0`/`off`/`false`/`no` all mean off: env/global.env is edited by hand and a
  # box that wrote `off` meant off (same shape as bin/plan-overlap.sh:51).
  case "$(printf '%s' "${PRIORITY_YIELD:-1}" | tr '[:upper:]' '[:lower:]')" in
    0|off|false|no) return 1 ;;
  esac
  return 0
}

# PY_SELF_RANK -> this build's rank, 0 | 1 | 2. HOTFIX=1 from the environment
# is rank 0 even when ticket-meta.json carries no hotfix label (fly's
# builder-runner exports it from the job env), which the lib does not read.
PY_SELF_RANK() {
  if [ "${HOTFIX:-}" = 1 ]; then echo 0
  elif command -v priority_rank_meta >/dev/null 2>&1; then
    priority_rank_meta "$BUILD/ticket-meta.json" "$HARNESS"
  else echo 2
  fi
}
# PUBLISHED ONCE, here, before any stage boundary (BH-1142). A requester can
# read a sibling's ticket-meta.json but not its environment, so a sibling whose
# urgency came from HOTFIX=1 used to read as rank 2 and a rank-1 build could
# evict it. The request half below takes the LOWER of this file and the meta
# rank: either source can make a build urgent, neither can demote it.
PY_SELF_RANK > "$BUILD/priority-rank" 2>/dev/null || :

# YIELD_CHECK <stage> — stand down if a higher-priority build asked for this claim.
#
# Called at TOP LEVEL only, never inside a subshell or a pipeline: the exit 3 is
# the whole point and a subshell would swallow it. The EXIT trap two lines above
# removes state/claims/$PROJECT/$KEY and _job_finish maps BUILD_DEFERRED* to
# parked -> queued, so THAT is the claim release; there is no new terminal word
# here and docs/RUN-BUILD-GRAPH.md needs no row.
#
# WHERE THE TREE IS gets MEASURED, never asserted (D13). At the first boundary
# nothing has been built yet, at the second the branch is on origin, and at the
# third it may have moved since — one sentence that claimed "checkpointed on
# origin" would be false at two of the three. TARGET_BRANCH is named rather than
# the checkpoint-adopt path because `# >>> checkpoint adopt` only adopts a tip
# that still carries `wip: checkpoint` commits, and CKPT_SQUASH_WIP has squashed
# those away by boundaries 2 and 3 — same honest escape EXECUTE_EMPTY offers.
#
# PAST THE LAST CHECKPOINT (BH-1142). `review` is the last boundary, so it
# leaves YIELD_CLOSED BEFORE it looks for a marker. A requester that sees it
# promises nothing; one that wrote its marker first re-reads it after the write.
# One side always sees the other's write, so a "yields at its next checkpoint"
# sentence is only ever written about a build that will still check.
YIELD_CHECK() {
  if [ "$1" = review ]; then : > "$BUILD/YIELD_CLOSED" 2>/dev/null || :; fi
  [ -f "$BUILD/YIELD" ] || return 0
  PY_ON || return 0
  local who head_sha origin_sha where
  who=$(sed -n 's/.*requested_by=\([^ ]*\).*/\1/p' "$BUILD/YIELD" 2>/dev/null | head -1)
  # D26: the requester comes out of the file or is left unnamed. Never invented.
  [ -n "$who" ] || who="a higher-priority build"
  # Consumed BEFORE the RESULT: a crash between the two leaves a dir that gets
  # resumed and rebuilt, which is recoverable. The other order leaves a dir that
  # stands down again on every re-entry, for ever.
  mv -f "$BUILD/YIELD" "$BUILD/YIELD.honored" 2>/dev/null
  head_sha=$(git -C "$WT" rev-parse --short=8 HEAD 2>/dev/null)
  origin_sha=$(git -C "$WT" rev-parse --short=8 "origin/$BRANCH" 2>/dev/null)
  if [ -z "$origin_sha" ]; then
    where="nothing of this build reached origin, so the next build of $KEY starts from the plan"
  elif [ -n "$head_sha" ] && [ "$head_sha" = "$origin_sha" ]; then
    where="branch $BRANCH is on origin at $origin_sha; force the next build onto it with TARGET_BRANCH=$BRANCH"
  else
    where="origin/$BRANCH is at $origin_sha and this machine's HEAD was ${head_sha:-unreadable}, so that local difference is lost; force the next build onto the pushed branch with TARGET_BRANCH=$BRANCH"
  fi
  echo "$(STAMP) [$PROJECT/$KEY] PRIORITY YIELD at $1: $who asked for this claim — standing down" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED yielded to $who at $1 — $where; the next triage tick re-offers $KEY"
  exit 3
}
# <<< priority yield
# >>> overlap wait
# The wait has a cap, and until SDLC item 6 the cap had no owner: at 45 minutes
# the pipeline proceeded into the very concurrent edit this wait exists to
# prevent, said so in a per-build log nobody sweeps, and left the PR-time rebase
# to discover it. LESSONS "every new work source needs a wake condition" applies
# to every skip path too — so the timeout now names what it is waiting for and
# hands the ticket back to the queue.
#
# NOTHING WAITS IN LINE ANY MORE (the operator, 2026-09-13). This wait was 45 minutes by
# default, which is precisely "a build queued behind another build" — the shape
# the order removed everywhere else in this file. The default is now 0: the first
# failing conflict check defers immediately, the build dir is retired, and the
# next triage tick re-plans the ticket against whatever main looks like then.
# Setting OVERLAP_WAIT_SECS to a positive number restores the old behaviour for a
# box that would rather pay the wait than the re-plan.
#
# Switches (defaults named here, both read from env/global.env):
#   OVERLAP_WAIT_SECS=0        seconds to wait before the cap fires (0 = never
#                              wait: defer on the first overlap). A non-numeric
#                              value alerts and falls back to 0 — a typo must not
#                              reintroduce a wait nobody asked for.
#   OVERLAP_DEFER_ENFORCE=1    SHIPPED DEFAULT: the timeout DEFERS. It is
#                              recorded (overlap-defer.txt + the ledger) and the
#                              build ends BUILD_DEFERRED with a RESULT naming its
#                              wake condition; the next triage tick re-plans it.
#                              =0 is the kill switch: record the timeout and
#                              proceed exactly as before. Disarm it only if the
#                              deferral (a requeue is a NEW build dir, so it
#                              costs a fresh PLAN session) proves more expensive
#                              than the PR-time rebase it replaces.
case "${OVERLAP_WAIT_SECS:-}" in
  ''|*[!0-9]*)
    [ -n "${OVERLAP_WAIT_SECS:-}" ] && \
      echo "$(STAMP) [$PROJECT/$KEY] OVERLAP_WAIT_SECS='${OVERLAP_WAIT_SECS}' is not a number — using 0 (never wait)" >> "$ALERTS"
    OV_CAP=0 ;;
  *) OV_CAP=$OVERLAP_WAIT_SECS ;;
esac
CWAIT=0
until CMSG=$("$HARNESS/bin/conflict-check.sh" "$PROJECT" "$BUILD" 2>/dev/null); do
  if [ "$CWAIT" -eq 0 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] serialized on file overlap: $CMSG" >> "$BUILD/pipeline.log"
  fi
  if [ "$CWAIT" -ge "$OV_CAP" ]; then
    OV_WAKE="the sibling build releases its claim (it writes a RESULT, or state/claims/$PROJECT/ ages it out at 4h) and the next triage tick re-offers $KEY"
    OV_WHY="$CMSG — still overlapping after $((CWAIT/60))m"
    case "$(printf '%s' "${OVERLAP_DEFER_ENFORCE:-1}" | tr '[:upper:]' '[:lower:]')" in
      1|''|true|yes|on) OV_ENFORCE=1 ;;
      0|false|no|off) OV_ENFORCE=0 ;;
      *) OV_ENFORCE=1
         echo "$(STAMP) [$PROJECT/$KEY] OVERLAP_DEFER_ENFORCE='${OVERLAP_DEFER_ENFORCE:-}' is not a recognized on/off value — treating as ON (the timeout defers)" >> "$ALERTS" ;;
    esac
    [ "$OV_ENFORCE" = 1 ] && OV_VERDICT=deferred || OV_VERDICT=proceeded
    # --- PRIORITY YIELD, the request half (see `# >>> priority yield` above) --
    # HERE, and not after the three writes below, ON PURPOSE: overlap-defer.txt,
    # the ledger artifact and the RESULT all quote $OV_WAKE, so the sentence has
    # to be final before the first of them reads it. A wake condition that is
    # one thing in the RESULT and another in the artifact is the bug this
    # placement prevents (D13).
    #
    # Only when the deferral is ENFORCED. With OVERLAP_DEFER_ENFORCE=0 this
    # build proceeds into the overlap anyway, and a build that is not standing
    # down has no business asking anybody else to.
    PY_ASKED=0
    if [ "$OV_ENFORCE" = 1 ] && PY_ON; then
      MY_RANK=$(PY_SELF_RANK)
      # $CMSG is bin/conflict-check.sh:29's line: `CONFLICT with <dir>: <p> ~ <q>`.
      # Anything else (a helper that failed, free text, nothing at all) names
      # nobody and asks nobody to stand down.
      SIB_D=$(printf '%s' "$CMSG" | sed -nE 's/^CONFLICT with ([^:]+):.*/\1/p' | head -1)
      SIBD="$HARNESS/builds/$SIB_D"
      # A sibling that already wrote a RESULT is finished and cannot yield —
      # saying it will would make the wake sentence a condition that never fires.
      # A sibling past YIELD_CHECK review (YIELD_CLOSED) never looks at a
      # marker again, so it is asked nothing and promised nothing (BH-1142).
      if [ -n "$SIB_D" ] && [ -d "$SIBD" ] && [ ! -f "$SIBD/RESULT" ] && [ -f "$SIBD/YIELD_CLOSED" ]; then
        echo "$(STAMP) [$PROJECT/$KEY] priority yield: sibling $SIB_D is past its last yield checkpoint — deferring on the ordinary claim release" >> "$BUILD/pipeline.log"
      elif [ -n "$SIB_D" ] && [ -d "$SIBD" ] && [ ! -f "$SIBD/RESULT" ]; then
        SIB_RANK=2
        command -v priority_rank_meta >/dev/null 2>&1 && \
          SIB_RANK=$(priority_rank_meta "$SIBD/ticket-meta.json" "$HARNESS")
        [ -s "$SIBD/ticket-meta.json" ] || \
          echo "$(STAMP) [$PROJECT/$KEY] priority yield: sibling $SIB_D has no readable ticket-meta.json — reading it as rank 2 (plain)" >> "$BUILD/pipeline.log"
        # The sibling's own published rank (PY_SELF_RANK above) counts when it
        # is lower. Exactly one digit 0-2 or it is ignored: garbage never reads
        # as urgent, and a stale file never demotes a label added since.
        SIB_PR=$(cat "$SIBD/priority-rank" 2>/dev/null)
        case "$SIB_PR" in
          0|1|2) [ "$SIB_PR" -lt "$SIB_RANK" ] 2>/dev/null && SIB_RANK=$SIB_PR ;;
        esac
        if [ "$MY_RANK" -lt "$SIB_RANK" ] 2>/dev/null; then
          # `cromford-BH-387-202609171830` -> `BH-387`; anything the
          # pattern does not fit stays the directory name (D26).
          SIBKEY=$(printf '%s' "$SIB_D" | sed -E "s/^$PROJECT-//; s/-[0-9]+$//")
          [ -n "$SIBKEY" ] || SIBKEY="$SIB_D"
          if [ -f "$SIBD/YIELD" ]; then
            # Never overwritten: the first requester owns the marker, and a
            # second rewrite would only change who the recipient names.
            echo "$(STAMP) [$PROJECT/$KEY] priority yield: $SIB_D already carries a YIELD (this build rank $MY_RANK, sibling rank $SIB_RANK) — left untouched" >> "$BUILD/pipeline.log"
            PY_ASKED=1
          elif printf 'requested_by=%s rank=%s at=%s\n' "$KEY" "$MY_RANK" "$(STAMP)" > "$SIBD/YIELD" 2>/dev/null; then
            # Re-read AFTER the write: a sibling that closed in between will
            # never see the marker. It is left in place (removing it would race
            # the sibling's own mv) but promised nothing.
            if [ -f "$SIBD/YIELD_CLOSED" ]; then
              echo "$(STAMP) [$PROJECT/$KEY] priority yield: sibling $SIB_D passed its last yield checkpoint while the marker was written — deferring on the ordinary claim release" >> "$BUILD/pipeline.log"
            else
              echo "$(STAMP) [$PROJECT/$KEY] priority yield: asked $SIB_D to stand down at its next checkpoint (this build rank $MY_RANK, sibling rank $SIB_RANK)" >> "$BUILD/pipeline.log"
              PY_ASKED=1
            fi
          else
            echo "$(STAMP) [$PROJECT/$KEY] priority yield: could not write $SIBD/YIELD — deferring on the ordinary claim release instead" >> "$BUILD/pipeline.log"
          fi
          # ...and the wake sentence changes ONLY on a marker that exists. A
          # failed write leaves today's 4h-ageout sentence, which is then the
          # true one.
          [ "$PY_ASKED" = 1 ] && OV_WAKE="the sibling $SIBKEY yields at its next checkpoint (rank $SIB_RANK behind this build's $MY_RANK) and the next triage tick re-offers $KEY"
        fi
      fi
    fi
    # Recorded either way, because "we built these files concurrently anyway" is
    # the fact a later union-merge investigation needs, and it exists nowhere
    # else. The file is the documented fallback; the ledger row is the copy the
    # rest of the fleet can read.
    printf 'OVERLAP_DEFER: %s\nVERDICT: %s\nWAKE: %s\n' "$OV_WHY" "$OV_VERDICT" "$OV_WAKE" > "$BUILD/overlap-defer.txt"
    if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
      job_artifact_put overlap_defer "$OV_VERDICT" \
        "$(jq -nc --argjson w "$CWAIT" --arg c "$(head -1 <<<"$CMSG" | cut -c1-300)" \
            --arg k "$OV_WAKE" --argjson e "$OV_ENFORCE" \
            '{waited_s:$w,conflict:$c,wake:$k,enforced:($e==1)}' 2>/dev/null)" \
        >/dev/null 2>&1 || true
    fi
    if [ "$OV_ENFORCE" = 1 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] conflict wait timed out ($((CWAIT/60))m) — deferring: $OV_WHY" >> "$BUILD/pipeline.log"
      RESULT "BUILD_DEFERRED file overlap — $OV_WHY; wakes when $OV_WAKE"
      exit 3
    fi
    echo "$(STAMP) [$PROJECT/$KEY] conflict wait timed out ($((CWAIT/60))m) — OVERLAP_DEFER_ENFORCE=0, proceeding; PR-time rebase will surface any clash ($BUILD/overlap-defer.txt)" >> "$BUILD/pipeline.log"
    break
  fi
  sleep 60; CWAIT=$((CWAIT + 60))
done
# <<< overlap wait

# >>> plan overlap
# CONFLICT-AWARE SCHEDULING, FLEET-WIDE (W2-D, 2026-09-14, the operator: "every
# throughput ceiling is a bug"). The wait above asks bin/conflict-check.sh
# whether a build ON THIS BOX claims a file this plan names. With a pool that is
# the wrong horizon: the sibling that will conflict with this plan is usually on
# another machine, and the two of them only meet at MERGE time — as a conflict
# on the single line into main, paid twice, once as a rebase and once as the
# re-review the rebase's moved head buys. bin/plan-overlap.sh asks the same
# question of the claims ledger and the queue's CLAIMED rows as well, and this
# is its ONE hook point: right after PLAN, where the file list first exists and
# before a single line has been edited.
#
# A DEFERRAL IS NOT A FAILURE and not a queue. The ticket goes back to `queued`
# (BUILD_DEFERRED -> parked -> queue_done ... queued, in _job_finish above) with
# a NOT-BEFORE ten minutes out, so the next tick re-offers it to whatever box is
# free rather than holding this one open behind somebody else's build. The
# not-before is read at the top of this script, before the plan is bought again.
#
# KILL FLAG: OVERLAP_SCHED=0 (or flags/plan-overlap-off) — the helper exits 0
# before reading anything and this block is a no-op, so the pipeline is
# byte-for-byte what it was before this change.
# BH-6292: a hotfix (HOTFIX=1, `# >>> hotfix detect`) runs none of the checks.
if [ "${HOTFIX:-}" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] PLAN_OVERLAP skipped hotfix — a hotfix is never deferred" >> "$BUILD/pipeline.log"
elif [ -x "$HARNESS/bin/plan-overlap.sh" ]; then
  PO_MSG=$(PLAN_OVERLAP_REPO="${REPO:-}" "$HARNESS/bin/plan-overlap.sh" "$PROJECT" "$BUILD/plan.md" 2>>"$BUILD/pipeline.log"); PO_RC=$?
  # BH-4988 r2: a SIBLING (same `Part of #P`) that finished building but whose
  # PR is still open is in none of plan-overlap's in-flight sources, so it is
  # asked here from that PR's changed files. It answers in plan-overlap's own
  # line and rc, so the defer below is the same path; any rc but 1 is build.
  if [ "$PO_RC" = 0 ] && [ -x "$HARNESS/bin/plan-sibling.sh" ]; then
    PO_MSG=$(PLAN_OVERLAP_REPO="${REPO:-}" PLAN_SIBLING_STACK_ON="${STACK_ON:-}" "$HARNESS/bin/plan-sibling.sh" check "$PROJECT" "$BUILD" 2>>"$BUILD/pipeline.log"); PO_RC=$?
  fi
  # BH-6292: ANY ticket's open PR that edits a file on the conflict hotspot
  # list this plan also edits. Same line and rc; any rc but 1 is build.
  if [ "$PO_RC" = 0 ] && [ -x "$HARNESS/bin/plan-sibling.sh" ]; then
    PO_MSG=$(PLAN_OVERLAP_REPO="${REPO:-}" PLAN_SIBLING_STACK_ON="${STACK_ON:-}" "$HARNESS/bin/plan-sibling.sh" inflight "$PROJECT" "$BUILD" 2>>"$BUILD/pipeline.log"); PO_RC=$?
  fi
  if [ "$PO_RC" = 1 ] && [ -n "$PO_MSG" ]; then
    case "${OVERLAP_DEFER_NOTBEFORE_SECS:-600}" in ''|*[!0-9]*) PO_NB=600 ;; *) PO_NB="${OVERLAP_DEFER_NOTBEFORE_SECS:-600}" ;; esac
    PO_AT=$(( $(date -u +%s) + PO_NB ))
    mkdir -p "$HARNESS/state/overlap-defer/$PROJECT"
    printf '%s\n' "$PO_AT" > "$HARNESS/state/overlap-defer/$PROJECT/$KEY"
    echo "$(STAMP) [$PROJECT/$KEY] $PO_MSG — deferring for $((PO_NB/60))m instead of co-building" >> "$BUILD/pipeline.log"
    # BH-4988: name the build this one waits for, so the not-before reader
    # above holds it for free until that build merges instead of re-planning
    # every ten minutes. Written before RESULT; a box without the script, or a
    # refused line, keeps exactly the ten-minute behaviour (choice "defer").
    PO_OTHER=$(printf '%s\n' "$PO_MSG" | awk 'NR==1{print $4}')
    PO_CHOICE=defer
    if [ -x "$HARNESS/bin/plan-after.sh" ] \
       && "$HARNESS/bin/plan-after.sh" record "$PROJECT" "$KEY" "$PO_MSG" >> "$BUILD/pipeline.log" 2>&1; then
      PO_CHOICE=after
    fi
    # BH-4988 r2: say so on the child issue, once per (KEY, OTHER) pair.
    if [ "$PO_CHOICE" = after ] && [ -x "$HARNESS/bin/plan-sibling.sh" ]; then
      "$HARNESS/bin/plan-sibling.sh" note "$PROJECT" "$KEY" "$PO_MSG" "$BUILD" >> "$BUILD/pipeline.log" 2>&1 || true
    fi
    if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
      job_artifact_put overlap_defer deferred \
        "$(jq -nc --arg c "$(head -1 <<<"$PO_MSG" | cut -c1-300)" --argjson nb "$PO_NB" \
            --arg ch "$PO_CHOICE" --arg af "$PO_OTHER" \
            '{scope:"fleet",conflict:$c,not_before_s:$nb,choice:$ch,after:$af}' 2>/dev/null)" \
        >/dev/null 2>&1 || true
    fi
    # BH-2524.2: the same window on this build's job_claims row (fleet read in
    # `overlap not-before`). The local file above stays the first write.
    command -v fclaim_not_before_put >/dev/null 2>&1 && { fclaim_not_before_put "$PO_NB" >/dev/null 2>&1 || true; }
    if [ "$PO_CHOICE" = after ]; then
      RESULT "BUILD_DEFERRED $PO_MSG; After: $PO_OTHER — held until it merges (not before $(date -u -d "@$PO_AT" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo "+$((PO_NB/60))m")), then the next triage tick re-offers $KEY to any free box"
    else
      RESULT "BUILD_DEFERRED $PO_MSG; not before $(date -u -d "@$PO_AT" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo "+$((PO_NB/60))m"), then the next triage tick re-offers $KEY to any free box"
    fi
    exit 3
  fi
fi
# <<< plan overlap
} # end rb_gate_overlap
