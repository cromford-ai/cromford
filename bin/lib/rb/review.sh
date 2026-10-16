# bin/lib/rb/review.sh — the review stage: the e2e smoke lane, the three lenses, fix rounds, the extra lens a reopen earns, and the backstop join.
# Entry functions, pipeline order: rb_review
# Reads: _ ALERTS BASE BRANCH BUILD E2E_GATE_SAID E2E_JOIN_CAPPED E2E_JOIN_MAX E2E_JOIN_MAX_S
#   E2E_NOTE E2E_PID E2E_RC E2E_SLUG E2E_VERDICT EV_OUT EV_RC FIX_MODEL FIX_ROUND_CAP
#   GATES_ASYNC_FINDINGS GATES_JOINED GATES_NOTE GATES_PAR GATES_PARALLEL HARNESS HIGHRISK KEY
#   KIND_SKIP_E2E KIND_SKIP_SECLENS L_ART L_CKPT L_FIX L_FIXLOG L_FIXRUN L_LOGLINE L_PROMPT
#   L_PUSH L_RE L_RUN L_RUN2 LENS LENS_BLOCKED LENS_FIX_FILES LENS_LAUNCHED LENS_MR LENS_NAMED
#   LENS_PID LENS_PIDS LENS_SHA LENS_TAG LENS_TAGS LENS_TIER LENS_V LENSES LENSES_PARALLEL
#   NH_ISSUE NH_SLUG NH_SUFFIX PR_URL PROJECT REFUTE_PRIORS REFUTE_PROMPT REFUTE_READ_PRIORS REOPEN_EXTRA_LENS REOPEN_HOT
#   REOPEN_NOTE REVIEW_MODEL REVIEW_MODEL_T0 REVIEW_PROMPT REVIEW_TIER REVIEW_TIER_LINE
#   REVIEW_TIER_REASON RISKY RT_LINE SECURITY_PROMPT SPEC_DIR T_E2E T_LENSES
#   VMAP_LIES_OUT VMAP_LINE VMAP_NOTE
# Writes: CC_ARTIFACT_KIND E2E_BASE_REF E2E_GATE_SAID E2E_JOIN_CAPPED E2E_JOIN_MAX E2E_NOTE
#   E2E_PID E2E_RC E2E_SLUG E2E_VERDICT EV_OUT FIX_ROUND_CAP GATES_JOINED GATES_NOTE HIGHRISK
#   L_ART L_CKPT L_FIX L_FIXLOG L_LOGLINE L_PROMPT L_PUSH L_RE L_RUN LENS_BLOCKED
#   LENS_FIX_FILES LENS_LAUNCHED LENS_MR LENS_PIDS LENS_SHA LENS_T0 LENS_TAGS LENS_TIER LENS_V
#   LENSES NH_ISSUE NH_SLUG NH_SUFFIX PTG_DETAIL PTG_IDS PTG_OUT PTG_RC PTG_SINCE REFUTE_PRIORS REFUTE_PROMPT REFUTE_READ_PRIORS REVIEW_PROMPT REVIEW_TIER
#   REVIEW_TIER_LINE RISKY RT_LINE SECURITY_PROMPT T_E2E T_LENSES
#   VMAP_LIES_OUT VMAP_LINE VMAP_NOTE
# shellcheck shell=bash

rb_review() {
# >>> plan thread pre-review (BH-5799)
# THE LAST CHECK THAT THE PLAN READ THE NEWEST COMMENTS, before any lens, smoke
# push or paid review session. A comment by a person or our App that landed
# after the plan's stamp, and that plan.md does not cite by id, means the build
# may have shipped the body the comment changed. plan.md is moved aside BEFORE
# the RESULT, so no later attempt can reuse it: a resume of this dir plans
# fresh, and PLAN_STALE is already "re-plans next tick, no comment, no ALERTS".
# This build's own posts (the replan comment, the BUILD BLOCKED notice) are in
# own-comments.sha256 and never count. An unreadable thread fails open.
# shellcheck source=bin/lib/plan-thread.sh
command -v ptg_check >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/plan-thread.sh" ] && . "$HARNESS/bin/lib/plan-thread.sh" 2>/dev/null; }
if [ -s "$BUILD/plan.md" ] && command -v ptg_check >/dev/null 2>&1; then
  if PTG_SINCE=$(ptg_since "$BUILD"); then
    PTG_SINCE=${PTG_SINCE%%$'\t'*}
    PTG_OUT=$(ptg_check "$PROJECT" "$KEY" "$BUILD/plan.md" "$PTG_SINCE" "$BUILD/own-comments.sha256"); PTG_RC=$?
    PTG_DETAIL=${PTG_OUT#*$'\t'}
    case "$PTG_RC" in
      0) echo "$(STAMP) [$PROJECT/$KEY] plan-thread: ${PTG_OUT%%$'\t'*} $PTG_DETAIL (pre-review)" >> "$BUILD/pipeline.log" ;;
      1)
        PTG_IDS=$(ptg_ids "$PTG_DETAIL")
        if [ "$(ptg_enforce)" = 1 ]; then
          ptg_refuse_plan "$BUILD"
          echo "$(STAMP) [$PROJECT/$KEY] PLAN_THREAD_REFUSED (pre-review) $PTG_DETAIL — plan moved to plan.md.thread-refused" >> "$BUILD/pipeline.log"
          BB plan_stale "" "" "" false "uncited comment(s) newer than the plan: $PTG_IDS"
          RESULT "PLAN_STALE uncited comment(s) newer than the plan: $PTG_IDS — re-plan"; exit 3
        fi
        echo "$(STAMP) [$PROJECT/$KEY] PLAN_THREAD_WARN (pre-review) $PTG_DETAIL — PLAN_THREAD_GATE_ENFORCE=0, review continues" >> "$BUILD/pipeline.log" ;;
      *) echo "$(STAMP) [$PROJECT/$KEY] plan-thread: $PTG_DETAIL — gate fails open (pre-review)" >> "$BUILD/pipeline.log" ;;
    esac
  else
    echo "$(STAMP) [$PROJECT/$KEY] plan-thread: no plan time — gate fails open (pre-review)" >> "$BUILD/pipeline.log"
  fi
fi
# <<< plan thread pre-review (BH-5799)
# >>> e2e smoke (tests/pipeline-gaps-test.sh runs this block)
# --- E2E SMOKE (SDLC playbook item 2) ----------------------------------------
# Until now a build proved itself with typecheck + `npm run build`, so nothing
# in the pipeline ever LOADED the thing it built: a page that 500s on mount or
# a component that throws in the browser reached the reviewer, and then prod,
# unverified. This stage drives the branch's own Vercel PREVIEW deployment
# before the reviewer reads the diff, and its verdict rides into REVIEW_PROMPT
# with the other mechanical gates.
#
# WHY THE PUSH IS HERE AND NOT AT PR TIME. A preview deployment is Vercel's
# response to a pushed branch — an unpushed branch has no preview, so a
# pre-review smoke that refused to push could only ever record SKIP, which is a
# dead gate wearing a stage's clothes. The push is narrowed to the case that
# needs it: a UI-touching diff on a project that actually has a Vercel lane.
# Everything else skips before touching the network. Pushing a BRANCH is not a
# merge and not a deploy to prod — the iron guardrail this box lives under
# forbids `gh pr merge`, pushes to main, and prod deploys, none of which this
# does. The PR-time push below is unchanged and becomes a no-op or a fast-
# forward of the fix-round commits.
#
# The smoke is strictly READ-ONLY (navigate and observe, never click or submit)
# because previews share the PRODUCTION database — the same reason the QA
# prompt forbids destructive actions.
#
# IT IS ALSO THE DEAD GAP (the operator, 2026-09-14). Measured on project-5 tonight:
# 6-8 minutes between the execute push and the review-lens launch, and this
# stage is all of it — pushing a branch, waiting for Vercel to finish building
# a preview of it, then driving routes in a browser. Nothing the lenses do
# depends on its verdict (it never blocks; its only consequence is a tier
# demotion at settle time), and nothing it does touches the tree, so under
# GATES_PARALLEL=1 it runs as a background lane BESIDE the lenses instead of in
# front of them. The body is unchanged — it is wrapped in a function so the same
# lines serve both orders, which is the rule the lens seam already follows.
#
# AND IT IS BOUNDED AT BOTH ENDS (BH-539). Two libs carry the parts of this
# stage worth testing on their own: bin/lib/e2e-ui-paths.sh answers "can this
# diff change a rendered route?" and bin/lib/e2e-join.sh holds the bounded wait.
# The matcher runs BEFORE the push, so a diff of server code costs nothing at
# all instead of a branch push plus a 600 s preview wait; the wait itself is
# capped, and a verdict that lands after the cap is applied at the tier decision
# (E2E_LATE_SETTLE below) and appended to the PR as a comment.
#
# BOTH SOURCES ARE FAIL-OPEN. A box whose render lost one of these files writes
# one ALERTS line and takes the old path — a spent smoke, an uncapped join —
# because a gate that silently skipped every build from then on is the one
# failure nobody would notice. One known loose end: a lane stopped at the tier
# decision leaves its `job_phase_open e2e` row unclosed. jobs-client is fail-open
# about that and it is deliberately not fixed here.
[ -r "$HARNESS/bin/lib/e2e-ui-paths.sh" ] && . "$HARNESS/bin/lib/e2e-ui-paths.sh"
[ -r "$HARNESS/bin/lib/e2e-join.sh" ] && . "$HARNESS/bin/lib/e2e-join.sh"
# >>> needs-human seam
# BH-3433 (BH-3442): the needs-human hooks below — REVIEW_PROMPT's tail and
# LENS_REFUSE's review case — call this lib. Fail-open: a box without it
# builds exactly as before. NH_ISSUE / NH_SLUG are set for an issues board
# (fleet.conf board prefix "-", the test pr.sh's CLOSES_LINE uses) and empty
# otherwise.
[ -r "$HARNESS/bin/lib/needs-human.sh" ] && . "$HARNESS/bin/lib/needs-human.sh" 2>/dev/null || true
# BH-7123: review levels. rl_cap demotes a general-lens BLOCK that names no
# ALWAYS-BLOCK class to a NOTE before LENS_APPROVED reads the verdict.
[ -r "$HARNESS/bin/lib/review-level.sh" ] && . "$HARNESS/bin/lib/review-level.sh" 2>/dev/null || true
# BH-4923: the DATA_LANE: field (dl_prompt_field_note) — same fail-open shape.
[ -r "$HARNESS/bin/lib/data-lane.sh" ] && . "$HARNESS/bin/lib/data-lane.sh" 2>/dev/null || true
NH_ISSUE=""; NH_SLUG=""
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  NH_ISSUE=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  NH_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
fi
# <<< needs-human seam

# The path gate itself, in its own function so the fallback is readable rather
# than buried in a condition. It also records WHICH list answered, because the
# skip sentence has to name it: a reader who disagrees with a skip needs to know
# whether it was the default globs, a project's E2E_PATHS, or the old regex.
#
# NOT A PIPE, and this is the whole reason the names are read into a variable
# first. This script runs under `pipefail`, and both readers below stop at the
# FIRST match: e2e_ui_path_hit returns 0, grep -q exits 0. On a diff whose name
# list is bigger than the pipe buffer (~64 KB, so a few thousand paths) the
# writing `git diff` is then killed by SIGPIPE, the pipeline's status becomes
# 141, and a real UI diff reads as a MISS — the exact silent skip this gate
# exists to prevent, and a bug today's `git diff | grep -qiE` shares. A
# here-string has no second process to kill.
E2E_UI_DIFF() {
  local names
  names=$(git diff --name-only "$BASE"...HEAD)
  if command -v e2e_ui_path_hit >/dev/null 2>&1; then
    E2E_GATE_SAID="globs: $(e2e_ui_globs)"
    e2e_ui_path_hit <<<"$names"
    return $?
  fi
  echo "$(STAMP) [$PROJECT/$KEY] E2E path gate: bin/lib/e2e-ui-paths.sh did not source on this box, fell back to the legacy UI regex (a smoke is spent rather than silently skipped)" >> "$ALERTS"
  E2E_GATE_SAID="legacy regex; bin/lib/e2e-ui-paths.sh missing"
  grep -qiE '\.(tsx|jsx|css)$|(^|/)app/|(^|/)components/|(^|/)pages/' <<<"$names"
}
E2E_NOTE=""
E2E_VERDICT="not-run"
E2E_STAGE() {
if [ "${KIND_SKIP_E2E:-0}" = 1 ]; then
  # SDLC item 7: a copy ticket buys no browser smoke. The skip is honest about
  # WHY — a reader must never have to guess whether a SKIP means "no UI in the
  # diff" or "we classified this as copy and chose not to look".
  printf 'E2E smoke did not run: this ticket is classified KIND: copy and KIND_GATE_ENFORCE=1, so the preview smoke was skipped by routing, not by absence of UI.\nE2E COVERAGE: routes=0 failed=0\nE2E: SKIP\n' > "$BUILD/e2e.md"
  E2E_RC=3
elif ! E2E_UI_DIFF && [ ! -f qa/personas.json ]; then
  # BH-535: a repo that ships qa/personas.json wants its persona flows driven on
  # every preview, UI paths in the diff or not, so the personas file alone is
  # enough to spend the smoke. Without it the rung below decides as before.
  # Rung 2. Nothing in this diff can change a rendered route, so there is no
  # preview worth building and no browser worth driving. This rung is the whole
  # point of the gate: it answers BEFORE the push, so a miss costs nothing.
  echo "$(STAMP) [$PROJECT/$KEY] E2E skip (no UI paths in diff)" >> "$BUILD/pipeline.log"
  printf 'E2E smoke did not run: no UI paths in diff (%s).\nE2E COVERAGE: routes=0 failed=0\nE2E: SKIP\n' "$E2E_GATE_SAID" > "$BUILD/e2e.md"
  E2E_RC=3
elif ! awk -v p="$PROJECT" '$1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$HARNESS/vercel.conf" 2>/dev/null; then
  # Rung 3, and its OWN sentence. These two states used to share one line, of
  # the shape "no UI-touching files ... or X has no Vercel project", which is
  # false about whichever state did not cause it, every single time it is read.
  printf 'E2E smoke did not run: %s has no Vercel project in vercel.conf.\nE2E COVERAGE: routes=0 failed=0\nE2E: SKIP\n' "$PROJECT" > "$BUILD/e2e.md"
  E2E_RC=3
else
  E2E_SLUG=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
  GH_LIVE
  if RB_PUSH -u e2e 2>>"$BUILD/pipeline.log"; then
    track_pushed
    # The sha the browser is about to drive, on disk. The fix round and the
    # pre-PR rebase can both move HEAD while a capped lane is still running, so
    # a late comment names THIS sha next to the current head rather than letting
    # a reader assume the smoke covered whatever the branch points at by then.
    git rev-parse HEAD > "$BUILD/e2e-sha"
    echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE (preview of $(git rev-parse --short HEAD))" >> "$BUILD/pipeline.log"
    # A PHASE, not a lane. run-build.sh already holds exactly one claim for this
    # build and exports JOB_ID; opening a second lane here would take a second
    # claim and bill this stage's row instead of the build's (jobs-client.sh
    # says so at job_lane_open). Fail-open: with the worker unreachable
    # JOB_PHASE_ID stays empty and every close is a no-op.
    command -v job_phase_open >/dev/null 2>&1 && job_phase_open e2e "$(hostname)" "" "preview smoke" >/dev/null 2>&1 || true
    E2E_BASE_REF="$BASE" "$HARNESS/bin/e2e-smoke.sh" "$PROJECT" "$E2E_SLUG" "$(git rev-parse HEAD)" "$BUILD" . \
      >> "$BUILD/pipeline.log" 2>&1
    E2E_RC=$?
    command -v job_phase_close >/dev/null 2>&1 && job_phase_close "$E2E_RC" "" "$(tail -1 "$BUILD/e2e.md" 2>/dev/null)" >/dev/null 2>&1 || true
  else
    echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE: branch push failed — no preview can exist, skipping" >> "$BUILD/pipeline.log"
    printf 'E2E smoke did not run: the branch could not be pushed, so no preview deployment can exist.\nE2E COVERAGE: routes=0 failed=0\nE2E: SKIP\n' > "$BUILD/e2e.md"
    E2E_RC=3
  fi
fi
# The lane's answer, on disk. A background subshell cannot hand its caller a
# variable, and this stage's ENTIRE output to the rest of the pipeline is one
# exit code (e2e.md it already writes itself). Written last, so a lane killed
# mid-flight leaves no file and the settle below reads that as "could not run"
# rather than as a verdict nobody reached.
printf '%s\n' "${E2E_RC:-99}" > "$BUILD/e2e-rc"
}
# The verdict, the note and the log line — unchanged, and in the parent shell
# either way, so E2E_VERDICT reaches the evidence block and the tier demoter
# exactly as it always has.
E2E_SETTLE() {
E2E_RC=$(cat "$BUILD/e2e-rc" 2>/dev/null)
case "${E2E_RC:-99}" in
  0) E2E_VERDICT=pass
     E2E_NOTE="E2E SMOKE: the preview deployment was loaded and every route came back clean (no 5xx, no console errors). This is browser evidence, not a build log:"$'\n'"$(tail -c 1500 "$BUILD/e2e.md" 2>/dev/null)" ;;
  4) E2E_VERDICT=fail
     E2E_NOTE="E2E SMOKE: FAILED — a route on the live preview 5xx'd, threw, or logged a console error. The diff builds and still does not stand up in a browser; treat this as evidence about THIS change until you can show the failure predates it:"$'\n'"$(tail -c 2500 "$BUILD/e2e.md" 2>/dev/null)" ;;
  3) E2E_VERDICT=skip
     E2E_NOTE="E2E SMOKE: SKIPPED — nothing about this diff was verified in a browser. Do not read this as passed:"$'\n'"$(head -2 "$BUILD/e2e.md" 2>/dev/null)" ;;
  *) E2E_VERDICT=skip
     # Two different silences, and they must not share a sentence. A lane that
     # is STILL RUNNING has not answered yet; a lane that left no rc file will
     # never answer. Neither is a pass, and only one of them is worth waiting a
     # few more stages for (E2E_LATE_SETTLE does that below).
     if [ ! -f "$BUILD/e2e-rc" ] && [ "${E2E_JOIN_CAPPED:-0}" = 1 ]; then
       E2E_NOTE="E2E SMOKE: STILL RUNNING at the join cap (E2E_JOIN_MAX_S=${E2E_JOIN_MAX:-}s). No verdict yet. Not a pass."
     else
       E2E_NOTE="E2E SMOKE: could not run (rc=${E2E_RC:-none}), so the app was never loaded on this build — do not read this as passed."
     fi ;;
esac
GATES_NOTE="$GATES_NOTE"$'\n'"$E2E_NOTE"
echo "$(STAMP) [$PROJECT/$KEY] E2E $E2E_VERDICT (rc=${E2E_RC:-none})" >> "$BUILD/pipeline.log"
# >>> live emit e2e
type LIVE >/dev/null 2>&1 && LIVE e2e "${E2E_VERDICT:-skip}" "e2e smoke: ${E2E_VERDICT:-skip} (rc=${E2E_RC:-none})"
# <<< live emit e2e
}

# --- The read-only lane, or today's order (GATES_PARALLEL, 2026-09-14) -------
# Read exactly like INTENT_GATE_ENFORCE and SCOPE_GATE_ENFORCE — the shapes
# people write in an env file — with one difference: this knob DEFAULTS ON, so
# the unrecognised value falls back to ON and says so. The fallback of a knob is
# its documented default, and silently taking the old serial path on a typo
# would be a fleet that quietly stopped saving the 6-8 minutes it thinks it is.
case "$(printf '%s' "${GATES_PARALLEL:-1}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)     GATES_PAR=1 ;;
  0|false|no|off)    GATES_PAR=0 ;;
  *) GATES_PAR=1
     echo "$(STAMP) [$PROJECT/$KEY] GATES_PARALLEL='${GATES_PARALLEL:-}' is not a recognized on/off value — treating as ON (the default)" >> "$ALERTS" ;;
esac
# The cap on that lane, read next to the switch that creates it. e2e_join_max
# never refuses to answer — an unusable value still yields 600 — so the only
# thing left here is saying so out loud. With the lib missing the cap is 0 and
# NOTHING is said yet: that alert belongs at the join, where the uncapped wait
# actually happens, so a GATES_PARALLEL=0 build that never joins does not page
# about a cap it was never going to use.
if command -v e2e_join_max >/dev/null 2>&1; then
  E2E_JOIN_MAX=$(e2e_join_max) \
    || echo "$(STAMP) [$PROJECT/$KEY] E2E_JOIN_MAX_S='${E2E_JOIN_MAX_S:-}' is not a whole number of seconds — treating as 600 (the default)" >> "$ALERTS"
else
  E2E_JOIN_MAX=0
fi
T_E2E=$(STAGE_START); E2E_PID=""; GATES_JOINED=0; GATES_ASYNC_FINDINGS=""; E2E_JOIN_CAPPED=0
# A RESUMED build re-enters a dir that may still hold the previous attempt's
# answer. Clear it before the stage runs, so a lane that is killed mid-flight
# settles as "could not run" rather than inheriting a verdict about an older
# head — the same rule the lens block applies to merged-review2.md. Nothing
# relays this file: it is one exit code handed from a subshell to its caller
# inside one run, and e2e.md (which IS relayed) remains the record.
rm -f "$BUILD/e2e-rc" "$BUILD/e2e-sha"
if [ "$GATES_PAR" = 1 ]; then
  E2E_STAGE >/dev/null 2>&1 &
  E2E_PID=$!
  echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE launched as a read-only lane beside the review (pid $E2E_PID) — joined before the fix round" >> "$BUILD/pipeline.log"
  # The reviewer is TOLD, because silence is the one thing this pipeline never
  # lets a gate say. A lens that reads no E2E line must not read that as a pass
  # — the same rule every SKIP in this file is written to.
  GATES_NOTE="$GATES_NOTE"$'\n'"E2E SMOKE: RUNNING RIGHT NOW, in parallel with your review, against this diff's own preview deployment. Its verdict is not in front of you and its absence here is NOT a pass. It is joined before any fix round: a failure reaches the fix session and the build's tier, and lands in \$BUILD/e2e.md. Review the diff on the evidence you do have and do not wait for it."
else
  E2E_STAGE
  STAGE_END e2e "$T_E2E"
  E2E_SETTLE
fi

# GATES_JOIN — where the lane stops being concurrent. Idempotent, because the
# lens block reaches it from three different places (the parallel path, the
# sequential path, and a checkpoint-hit build that skipped both) and only the
# FIRST one may pay the wait.
#
# WAIT ON THE PID, NEVER A BARE `wait` — the same reason spelled out in the lens
# block: this shell owns job_beat_start's heartbeat child, which never exits,
# and a bare wait would hang the build until the claim timed out.
#
# It is called BEFORE the first commit-producing stage (the fix round), which is
# what keeps the lane read-only in fact and not just in intent: e2e-smoke.sh
# reads the worktree once, in its first second, and everything after that is a
# preview URL and a browser.
GATES_JOIN() {
  [ "${GATES_JOINED:-0}" = 1 ] && return 0
  GATES_JOINED=1
  [ -n "${E2E_PID:-}" ] || return 0
  # ...and BOUNDED, because "joined before the fix round" must not turn into
  # "the fix round waits for Vercel". Past the cap the build moves on with no
  # verdict, and E2E_LATE_SETTLE picks the answer up at the tier decision.
  if command -v e2e_wait_pid_capped >/dev/null 2>&1; then
    e2e_wait_pid_capped "$E2E_PID" "$E2E_JOIN_MAX" || {
      E2E_JOIN_CAPPED=1
      echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE: still running after E2E_JOIN_MAX_S=${E2E_JOIN_MAX}s. The fix round proceeds without it; a verdict that lands before the tier settles is applied then and appended to the PR as a comment" >> "$BUILD/pipeline.log"
    }
  else
    echo "$(STAMP) [$PROJECT/$KEY] E2E join cap: bin/lib/e2e-join.sh did not source on this box, so this join is UNCAPPED and the build waits for the lane exactly as it did before" >> "$ALERTS"
    wait "$E2E_PID" 2>/dev/null || true
  fi
  STAGE_END e2e "$T_E2E"
  E2E_SETTLE
  # ...and the finding rides into the SAME fix round the lenses share. A failing
  # preview is the one answer this lane has that someone must act on, and under
  # the old order it reached the reviewer's prompt; under this one it reaches
  # the session that is about to edit the code. An E2E that passed, skipped or
  # could not run adds nothing here — it is already in the tier and the record.
  [ "${E2E_VERDICT:-}" = fail ] && GATES_ASYNC_FINDINGS=" ALSO, from a check that finished while the lenses were reading: the preview E2E SMOKE FAILED. A route on this branch's own preview deployment 5xx'd, threw, or logged a console error — the diff builds and still does not stand up in a browser. Read $BUILD/e2e.md and fix that failure in this same pass, unless you can show it predates this diff, in which case say so explicitly in your output. Re-verify and commit as above."
  return 0
}

# E2E_LATE_SETTLE — the other half of the cap. A capped join is a DEFERRAL, not
# a verdict, and this is where the deferral is paid: one line above the tier
# demoter, after the PR exists, which is the last moment the answer can still
# change anything. A build that was never capped returns here immediately, so
# the call site costs nothing on the normal path.
#
# Idempotent by construction: it acts once, clears the flag, and a second call
# is a no-op. That matters more than usual — the PR comment below is an external
# write, and "at most one per run" is the flag, not a hope.
E2E_LATE_SETTLE() {
  [ "${E2E_JOIN_CAPPED:-0}" = 1 ] || return 0
  E2E_JOIN_CAPPED=0
  if [ -f "$BUILD/e2e-rc" ]; then
    # The lane landed after all. This is a real verdict from a real browser, so
    # it settles exactly as it would have at the join, and the demoter on the
    # lines below demotes a tier-1 build on a fail the way it always has.
    E2E_SETTLE
    echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE: verdict arrived after the join cap: $E2E_VERDICT" >> "$BUILD/pipeline.log"
    # ...and gates.json carries the same word. It was written with the pre-cap
    # verdict on the line above `gh pr create`, bin/evidence-summary.sh reads its
    # `e2e` field, and the evidence block is rendered AGAIN after the tier
    # decision — so leaving it alone puts `| e2e smoke | skip |` on a PR whose
    # own e2e.md ends `E2E: FAIL`. One field, rewritten in place; a jq that is
    # missing or unhappy leaves the file exactly as it was and changes nothing
    # else about this settle.
    if [ -s "$BUILD/gates.json" ] && command -v jq >/dev/null 2>&1; then
      if jq -c --arg e "$E2E_VERDICT" '.e2e=$e' "$BUILD/gates.json" > "$BUILD/gates.json.tmp" 2>/dev/null; then
        mv "$BUILD/gates.json.tmp" "$BUILD/gates.json"
      else
        rm -f "$BUILD/gates.json.tmp"
      fi
    fi
    # The record above is settled and stands on its own. The comment is a COPY
    # of it — sent last, at most once, and its failure changes nothing about
    # what this build recorded. With no PR to comment on, nothing is sent and
    # the record is still complete.
    if [ -n "${PR_URL:-}" ]; then
      command -v GH_LIVE >/dev/null 2>&1 && GH_LIVE
      gh pr comment "$PR_URL" --body "$(printf 'Preview E2E smoke (landed after the %ss join cap, so the review did not wait for it). It drove the preview of %s; the branch head is now %s.\n%s' "$E2E_JOIN_MAX" "$(cat "$BUILD/e2e-sha" 2>/dev/null || echo unknown)" "$(git rev-parse --short HEAD)" "$(tail -c 900 "$BUILD/e2e.md" 2>/dev/null)")" 2>>"$BUILD/gh-stderr.log" || true   # gh-guard-allow: a write, not a decision read
    fi
  else
    # Still no answer, and the build is out of stages to spend. Stop the lane
    # first so it cannot write over the record a moment later, then record the
    # honest non-verdict: "did not finish" is a SKIP, never a pass.
    #
    # CHILDREN BEFORE THE PARENT, and the order is the whole point. The lane is
    # a subshell; the process that WRITES $BUILD/e2e.md is its child,
    # bin/e2e-smoke.sh. Kill the subshell first and that child is reparented in
    # the same instant, so the `pkill -P` after it names a parent that no longer
    # exists, matches nothing, and the smoke runs on — minutes past the tier
    # decision it finishes and writes its own `E2E: PASS` over the SKIP recorded
    # below, which is the line bin/merge-sweep.sh and the evidence block then
    # read. TERM the child first and it stops where it stands — measured: the
    # shell takes the signal even while it waits on a child of its own, and never
    # reaches the line that writes e2e.md.
    #
    # The residual, stated rather than hidden: `pkill -P` is ONE level deep, and
    # what it stops is bin/e2e-smoke.sh, not everything under it. A lane already
    # in the browser-drive phase leaves a node grandchild (bin/e2e-smoke.mjs)
    # that can still write e2e.md; killing the whole process group would need
    # `setsid` at lane launch, which this change does not do. An orphaned
    # bin/wait-preview.sh is harmless — it writes no record.
    [ -n "${E2E_PID:-}" ] && { pkill -TERM -P "$E2E_PID" 2>/dev/null; kill "$E2E_PID" 2>/dev/null; }
    printf 'E2E smoke did not finish: still running when the build reached its tier decision (join cap E2E_JOIN_MAX_S=%ss was hit at the fix round).\nE2E COVERAGE: routes=0 failed=0\nE2E: SKIP\n' "$E2E_JOIN_MAX" > "$BUILD/e2e.md"
    E2E_VERDICT=skip
    echo "$(STAMP) [$PROJECT/$KEY] E2E SMOKE: no verdict by the tier decision, so the lane was stopped and recorded as SKIP" >> "$BUILD/pipeline.log"
  fi
  return 0
}
# <<< e2e smoke

# Boundary 3 of 3, and the LAST one: the lenses are about to be bought, and
# after them comes the PR. Nothing stands down once a PR is open — that would
# leave an open PR with no build behind it.
YIELD_CHECK review
HOLD_STAGE_CHECK review

T_LENSES=$(STAGE_START)
# >>> review lenses (tests/parallel-lenses-test.sh runs this block)
# --- The three review lenses read ONE diff, so they read it at the same time --
# (2026-09-12) The general REVIEW, the SECURITY lens (risky files) and the
# adversarial REFUTER (schema/money files) each used to run to completion before
# the next one started, each with its OWN fix round and its OWN re-review — and
# every one of those fix rounds committed past `review-head`, which then
# re-triggered the head-bound gate and bought a FOURTH review. Three read-only
# passes over the SAME immutable diff were serialised for no reason but the
# order the code was written in, and a build spent 40-60 minutes in here.
#
# LENSES_PARALLEL=1 launches the lens REVIEWS
# concurrently — they only READ, so there is nothing for them to race over — and
# then buys ONE fix round handed every lens's findings together, ONE suite
# re-run on the fixed head, and ONE re-review that adjudicates each lens's
# objection separately and writes each lens's own verdict back onto its own
# artifact. Artifact names, the TIER/VERDICT line contracts and the three
# terminals are unchanged: a lens that still refuses exits with ITS OWN
# REVIEW_BLOCKED / SECURITY_BLOCKED / REFUTE_BLOCKED, and those still do not
# requeue (docs/RUN-BUILD-GRAPH.md).
#
# IT SHIPS ON (2026-09-14). It shipped OFF on 2026-09-12 with project-5 as the
# pilot, because nothing about the parallel flow had met a real model. project-5
# then ran it for two days of real pool builds, and the operator's standing order that
# day was that build, conductor, review and merge all run parallel with no caps.
# The sequential flow is still here, verbatim, as the opt-out:
#   env/<project>.env  ->  LENSES_PARALLEL=0
# which run-build.sh sources itself (`set -a` near the top) on a watcher box, and
# which rides to a pool machine in the env bundle — bin/fly-envbundle.sh copies
# the project's env file WHOLE, and fly/builder-runner.sh sources it `set -a`,
# so no allowlist entry is needed for this or any other project knob.
# What the pilot was waiting on, and still is worth watching in the
# per-lens verdict lines parsing and no rate-limit failures from the three
# concurrent calls.
#
# Anything that is not exactly `1` takes the sequential path, including a typo:
# the fallback of a knob this new has to be the proven flow, not the new one.
#
# Both paths make the per-lens review call through the SAME LENS_CALL function
# and read the same LENS_VARS table, so a prompt or a filename can never be
# edited in one path and missed in the other.
#
# WHAT PARALLEL COSTS, stated rather than hidden. Sequentially a BLOCK from the
# general lens exited before the other two were bought, so a diff the first
# reviewer refused paid for one review; in parallel it pays for up to three.
# That is the price of not waiting. It is bounded — the extra lenses only run on
# diffs whose FILE NAMES already earned them — and it buys back up to two fix
# rounds and two re-reviews on every build that needs repair, which is the
# expensive half. The merged fix round is deliberately NOT parallel: three fix
# sessions editing one worktree at once is a race with a commit at the end of it.
#
# KNOWN, AND ACCEPTED: the merged round writes ONE `review2-run.txt`, so
# bin/repair-count.sh counts one repair where the sequential flow could count
# three. That is the honest number — the build was sent back once.
#
# CONCURRENCY, audited rather than assumed. The three calls go through
# bin/agent-call.sh, whose shared writes were already parallel-safe because
# several BUILDS share a box: cost.csv appends under a flock, the merged
# settings file is keyed on its input list and renamed atomically, run files and
# transcripts are per-lens, and each call opens its OWN job-phase row (three
# `review` rows on one job, which job_phases allows; fleet-status reports the
# most recently opened). Two things are NOT insulated and are the cost of this:
# three lenses can land on the same vendor account at once, so a rate-limited
# lane shows up as three failures instead of one; and the box carries three
# model sessions where it carried one, which is memory the kill watchdog sees.

# --- Second review lens (the operator, 2026-07-31): schema/auth/money diffs get an
# INDEPENDENT security-focused pass on top of the general adversarial review.
# Two different failure lenses beat one; both must APPROVE or it's a fix round.
RISKY=$(git diff --name-only "$BASE"...HEAD | grep -icE 'schema\.prisma|prisma/schema/.+\.prisma$|migrations?/|\.sql$|middleware|auth|permission|role|billing|stripe|tipalti|invoice|payment|payout|token|webhook' || true)
# >>> reopen extra lens
# Trust knob, default OFF (Wave D): on a project whose reopens say its shipped
# work is not holding, buy the second lens even when the file names look safe —
# the file-name heuristic is what missed the last one. REOPEN_EXTRA_LENS=1 to
# arm it; the reason is logged, not folded into the "risky files" count, so the
# count stays an honest diff measurement.
if [ "${REOPEN_EXTRA_LENS:-0}" = 1 ] && [ "${REOPEN_HOT:-0}" = 1 ] && [ "${RISKY:-0}" -eq 0 ] \
   && [ "${KIND_SKIP_SECLENS:-0}" != 1 ]; then
  RISKY=1
  echo "$(STAMP) [$PROJECT/$KEY] TRUST: $REOPEN_NOTE — security lens added (REOPEN_EXTRA_LENS)" >> "$BUILD/pipeline.log"
fi
# SDLC item 7's "copy skips the security lens", and the narrowing it ships with:
# what a copy classification skips is the REOPEN-ARMED lens above, never the
# lens the DIFF earns. RISKY counts files named auth/billing/migration/webhook,
# and a diff that touches those is not a copy change whatever the board's label
# says — the file names are the stronger evidence, and the disagreement is
# logged rather than resolved in favour of the cheaper answer.
if [ "${KIND_SKIP_SECLENS:-0}" = 1 ]; then
  if [ "${RISKY:-0}" -gt 0 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] KIND: copy, but the diff touches $RISKY risky file(s) — the security lens stands" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] KIND: copy — no risky files and the reopen-armed lens is skipped by routing" >> "$BUILD/pipeline.log"
  fi
fi
# <<< reopen extra lens

# --- Third lens: adversarial REFUTER on the highest-blast-radius class --------
# (2026-08-18, verification-intensity router): schema/migration/money diffs get
# a reviewer whose ONLY brief is to overturn the two prior approvals. Review
# depth now scales with blast radius instead of being flat — a docs diff gets
# one reviewer, a route change two, a schema-or-money change three. Distinct
# framing beats a third copy of the same lens: this one is told the change is
# guilty until proven innocent.
HIGHRISK=$(git diff --name-only "$BASE"...HEAD | grep -icE 'schema\.prisma|prisma/schema/.+\.prisma$|migrations?/|\.sql$|billing|stripe|tipalti|invoice|payment|payout' || true)

# --- The RISK TIER (BH-485): how much review this diff has earned ------------
# Every lens above is a full model read of the diff, and this stage runs 8.5 min
# median / 35 min p90. A docs change and a schema change were read identically.
# bin/lib/review-tier.sh classifies the diff first — T0 docs/tests/CI-config,
# T1 product code, T2 risky — and the tier decides the lens set, the review
# model, the prompt variant and how many fix rounds this build may buy.
#
# ABSENT IS NEVER THE CHEAP TIER. No lib (a box whose bin/lib/ has not synced, or
# tests/parallel-lenses-test.sh, which extracts this block on its own), a lib
# that cannot be sourced, or a line this cannot parse all land on T2 with today's
# RISKY/HIGHRISK lens set and uncapped fix rounds — byte-identical to the
# behaviour before this existed.
REVIEW_TIER=T2; REVIEW_TIER_REASON=classifier-unavailable
# shellcheck source=bin/lib/review-tier.sh
[ -r "${HARNESS:-}/bin/lib/review-tier.sh" ] && . "${HARNESS:-}/bin/lib/review-tier.sh" 2>/dev/null
# The delta-or-full decision for the merged re-review (BH-2546). Same stance as
# the tier: a lib that did not sync decides nothing, and the re-review reads the
# whole branch as it always has.
# shellcheck source=bin/lib/fix-delta-review.sh
[ -r "${HARNESS:-}/bin/lib/fix-delta-review.sh" ] && . "${HARNESS:-}/bin/lib/fix-delta-review.sh" 2>/dev/null
if command -v review_tier >/dev/null 2>&1; then
  RT_LINE=$(review_tier "$BASE" HEAD 2>/dev/null)
  case "$RT_LINE" in
    "T0 reason="*|"T1 reason="*|"T2 reason="*)
      REVIEW_TIER=${RT_LINE%% *}; REVIEW_TIER_REASON=${RT_LINE#*reason=} ;;
  esac
fi
# Fix rounds this tier buys. 0 = uncapped, which is what every tier did before,
# so an unrecognised tier keeps today's behaviour rather than inventing a limit.
FIX_ROUND_CAP=0
command -v review_tier_cap >/dev/null 2>&1 && FIX_ROUND_CAP=$(review_tier_cap "$REVIEW_TIER")

# The lens list THIS diff earns. T0 buys ONE lens; every other tier keeps the
# same two conditions as before, evaluated once and up front because the
# parallel path has to know what it is launching.
LENSES=review
if [ "$REVIEW_TIER" != T0 ]; then
  [ "${RISKY:-0}" -gt 0 ] && LENSES="$LENSES security"
  [ "${HIGHRISK:-0}" -gt 0 ] && LENSES="$LENSES refute"
fi
# T0 is read on its own model tier. Unset, REVIEW_MODEL_T0 IS REVIEW_MODEL, so
# this line changes nothing until an operator sets one in env/global.env.
[ "$REVIEW_TIER" = T0 ] && REVIEW_MODEL="${REVIEW_MODEL_T0:-$REVIEW_MODEL}"

# The record, written BEFORE a single lens is launched, so "a lens ran at a
# depth nothing recorded" cannot happen. review-tier.txt is a RECORD and never
# an input: a missing one is recomputed next run, and bin/evidence-summary.sh
# simply omits its row. Neither write may ever fail a build.
REVIEW_TIER_LINE="REVIEW-TIER $REVIEW_TIER reason=$REVIEW_TIER_REASON lenses=$(printf '%s' "$LENSES" | tr ' ' ',') cap=$FIX_ROUND_CAP"
printf '%s\n' "$REVIEW_TIER_LINE" > "$BUILD/review-tier.txt" 2>/dev/null || true
echo "$(STAMP) [$PROJECT/$KEY] $REVIEW_TIER_LINE model=$REVIEW_MODEL" >> "$BUILD/pipeline.log" || true

# Has this build already spent the fix rounds its tier buys? Counted from the
# build dir's own artifacts — the same three bin/evidence-summary.sh counts, and
# deliberately NOT qa-fix-run.txt, which is a different stage's round. Counting
# files rather than a new counter means the cap survives a resume with no new
# state to keep honest.
FIX_ROUNDS_SPENT() {
  local _n=0 _f
  for _f in fix-run.txt security-fix-run.txt refute-fix-run.txt; do
    [ -s "$BUILD/$_f" ] && _n=$((_n + 1))
  done
  printf '%s' "$_n"
}
# rc 0 = this build may buy another lens fix round. The refusal is logged where
# it happens; adjudication below is untouched, so a lens that still refuses
# exits on its own existing terminal.
FIX_ROUND_ALLOWED() {
  [ "${FIX_ROUND_CAP:-0}" -gt 0 ] || return 0
  local _spent; _spent=$(FIX_ROUNDS_SPENT)
  [ "$_spent" -lt "$FIX_ROUND_CAP" ] && return 0
  echo "$(STAMP) [$PROJECT/$KEY] FIX-ROUND CAP $FIX_ROUND_CAP reached at tier $REVIEW_TIER — no further fix round" >> "$BUILD/pipeline.log"
  return 1
}

# The ONE place a lens's artifact name lives. Every other helper asks this, so a
# rename cannot land in the guard and miss the checkpoint.
LENS_ART() { # LENS_ART <review|security|refute>
  case "$1" in
    review)   printf '%s' "$BUILD/review.md" ;;
    security) printf '%s' "$BUILD/security-review.md" ;;
    refute)   printf '%s' "$BUILD/refute-review.md" ;;
  esac
}
# A lens has approved when the anchored VERDICT line in the final block of its
# artifact says APPROVE (bin/lib/verdict-parse.sh, BH-1625). A missing file, a
# half-written one, a session that died, a final block that quotes another
# verdict, or a tree without the reader all fail this the same way — silence
# is never an approval.
LENS_APPROVED() {
  # BH-7123: the general lens is read through the level cap first. A BLOCK that
  # names no ALWAYS-BLOCK class becomes a NOTE and a lens with no BLOCK left
  # approves. Idempotent, so every caller may run it; the security and refute
  # lenses are never capped (their whole brief is the ALWAYS-BLOCK floor).
  if [ "$1" = review ] && command -v rl_cap >/dev/null 2>&1 && [ -s "$(LENS_ART review)" ]; then
    local _rl; _rl=$(rl_cap "$(LENS_ART review)" "$PROJECT" --approve APPROVE --block BLOCK --lens inbuild 2>>"$BUILD/pipeline.log") \
      && echo "$(STAMP) [$PROJECT/$KEY] review level: $_rl" >> "$BUILD/pipeline.log"
  fi
  verdict_is APPROVE -L "$(LENS_ART "$1")" 2>/dev/null; }
# Everything else about a lens, in one table both flows read.
LENS_VARS() { # LENS_VARS <lens> -> L_ART L_RUN L_RUN2 L_FIXRUN L_PUSH L_LOGLINE L_FIXLOG L_CKPT L_PROMPT L_FIX L_RE
  L_ART=$(LENS_ART "$1")
  case "$1" in
    review)
      L_RUN=review-run.txt; L_RUN2=review2-run.txt; L_FIXRUN=fix-run.txt
      L_PUSH="the fix round"
      L_LOGLINE="REVIEW ($REVIEW_MODEL)"
      L_FIXLOG="FIX ROUND ($FIX_MODEL)"
      L_CKPT="REVIEW checkpoint hit — APPROVE on this exact head stands"
      L_PROMPT="${REVIEW_PROMPT:-}"
      L_FIX="Address every blocking finding in $BUILD/review.md on branch $BRANCH (plan: $BUILD/plan.md). Re-verify; 'npm run build' must pass. Commit."
      L_RE="${REVIEW_PROMPT:-} Re-review after fixes; append to $BUILD/review.md." ;;
    security)
      L_RUN=security-review-run.txt; L_RUN2=security-review2-run.txt; L_FIXRUN=security-fix-run.txt
      L_PUSH="the security fix round"
      L_LOGLINE="SECURITY REVIEW ($REVIEW_MODEL, $RISKY risky files)"
      L_FIXLOG="SECURITY FIX ROUND"
      L_CKPT="SECURITY checkpoint hit — APPROVE on this head stands"
      L_PROMPT="${SECURITY_PROMPT:-}"
      L_FIX="Address every blocking finding in $BUILD/security-review.md on branch $BRANCH. Re-verify; 'npm run build' must pass. Commit."
      L_RE="Re-run the SECURITY-ONLY review after fixes (same lens as before, findings were in $BUILD/security-review.md): git diff $BASE...HEAD on branch $BRANCH. Keep the FRAUD: tagging convention on any finding that is one of the six classes. Append updated findings to $BUILD/security-review.md. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK." ;;
    refute)
      L_RUN=refute-review-run.txt; L_RUN2=refute-review2-run.txt; L_FIXRUN=refute-fix-run.txt
      L_PUSH="the refuter fix round"
      L_LOGLINE="REFUTER REVIEW ($REVIEW_MODEL, $HIGHRISK schema/money files)"
      L_FIXLOG="REFUTER FIX ROUND"
      L_CKPT="REFUTER checkpoint hit — APPROVE on this head stands"
      L_PROMPT="${REFUTE_PROMPT:-}"
      L_FIX="Address every blocking finding in $BUILD/refute-review.md on branch $BRANCH. Re-verify; 'npm run build' must pass. Commit."
      L_RE="Re-run the adversarial REFUTER review after fixes (your findings were in $BUILD/refute-review.md): git diff $BASE...HEAD on branch $BRANCH. Same brief — refute or concede, keeping the FRAUD: tagging convention. Append to $BUILD/refute-review.md. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK." ;;
  esac
}
# ONE review call for one lens — the only place either flow talks to a reviewer.
# Only the general lens declares a review_file artifact, exactly as before: the
# other two close their phase without one, which is what they always did.
LENS_CALL() { # LENS_CALL <lens>
  LENS_VARS "$1"
  if [ "$1" = review ]; then
    CC_ARTIFACT_KIND=review_file CC_ARTIFACT_FILE="$L_ART" \
      CC review "$REVIEW_MODEL" 1200 "$BUILD/$L_RUN" "$L_PROMPT"
  else
    CC review "$REVIEW_MODEL" 1200 "$BUILD/$L_RUN" "$L_PROMPT"
  fi
}
LENS_HEAD_MATCHES() { [ "$(cat "$BUILD/review-head" 2>/dev/null)" = "$(git rev-parse HEAD)" ]; }
# The terminal a refusing lens exits on. WRITTEN OUT AS LITERALS rather than
# composed from a variable: tests/run-build-graph-test.sh reads the terminals
# this script can write straight out of its own RESULT calls, and a terminal
# assembled at runtime is an exit path that document cannot audit — which is
# exactly the "unaudited exit" shape the graph exists to stop. All three keep
# their no-requeue close-out rule (docs/RUN-BUILD-GRAPH.md).
LENS_REFUSE() { # LENS_REFUSE <lens> — never returns
  # A refusal from a lens, its fix round or the merged re-review that ran out
  # of runner lane is a deferral, not a verdict (BH-1853): see STAGE_LANE_DEFER.
  LENS_VARS "$1"
  # fix-run.txt / review2-run.txt are the general lens's OWN fix round and
  # re-review on the sequential path (they are its L_FIXRUN / L_RUN2), and the
  # ONE merged round every lens shares on the parallel path. Only there do they
  # speak for security or refute: a genuine BLOCK must not defer on another
  # lens's exhausted lane (BH-1872).
  local _shared=()
  [ "${LENSES_PARALLEL:-1}" = 1 ] && _shared=("$BUILD/fix-run.txt" "$BUILD/review2-run.txt")
  STAGE_LANE_DEFER "$1 review" "$BUILD/$L_RUN2" "$BUILD/$L_FIXRUN" "$BUILD/$L_RUN" ${_shared[@]+"${_shared[@]}"}
  case "$1" in
    review)   # BH-3433: a needs-human suffix (empty today) and the tripwire;
              # neither can suppress or change the terminal word.
              { NH_SUFFIX="$(nh_on_block "$PROJECT" "${NH_ISSUE:-}" "$BUILD/review.md" "$BUILD" 2>/dev/null || true)"
                nh_trip_on_block "$PROJECT" "${NH_ISSUE:-}" "$BUILD/review.md" "$(basename "$BUILD")" 2>/dev/null || true
                RESULT "REVIEW_BLOCKED $(LENS_ART review)${NH_SUFFIX}"; } ;;
    security) RESULT "SECURITY_BLOCKED $(LENS_ART security)" ;;
    refute)   RESULT "REFUTE_BLOCKED $(LENS_ART refute)" ;;
  esac
  exit 6
}

# Checkpoint: APPROVE tails from a prior attempt stand — but ONLY if the branch
# head those verdicts were about is unchanged (a resumed EXECUTE means new
# commits no verdict ever saw). Every lens this diff earns has to have one,
# which is stricter than the old per-lens checkpoints: there, the general lens
# could hit its checkpoint on a head the security lens had never been asked
# about. The cost of the stricter rule is one extra suite re-run on a partial
# resume; the cost of the looser one was a lens that silently did not happen.
LENS_ALL_APPROVED() { local _l; for _l in $LENSES; do LENS_APPROVED "$_l" || return 1; done; return 0; }
if LENS_ALL_APPROVED && LENS_HEAD_MATCHES; then
  echo "$(STAMP) [$PROJECT/$KEY] REVIEW checkpoint hit — every lens ($LENSES) APPROVEd on this exact head" >> "$BUILD/pipeline.log"
else
BB reviewing
# Executed-verification gate (2026-08-24, builder-swap pilot): the harness runs
# the repo's unit suite ITSELF before review — validate.txt/red.txt are agent-
# authored and a builder once reported green with 13/16 of its own tests failing.
# harness-suite.txt is ground truth for the reviewer; absence of a test script is
# recorded honestly, never treated as green.
HARNESS_SUITE_RUN harness-suite.txt lenses
# >>> live emit suite
type LIVE_SUITE >/dev/null 2>&1 && LIVE_SUITE "$BUILD/harness-suite.txt" ""
# <<< live emit suite

# >>> evidence verdicts (tests/evidence-gate-test.sh drives this block)
# --- The acceptance claims, scored, into the review prompt (#527) -------------
# The contract is bin/lib/evidence.sh: the execute session PROPOSES a verdict
# per acceptance claim in $BUILD/evidence-proposed.txt, and the scorer decides
# CONFIRMED from the artifact that is actually on disk. This is the FIRST of the
# two scoring points and the only one a reviewer sees: the rows land in
# GATES_NOTE, which REVIEW_PROMPT interpolates one line below, so they arrive
# beside the mechanical gates rather than as a file the reviewer has to know to
# open. The settle-time demoter re-scores the head that merges.
#
# IT SCORES RIGHT HERE, after HARNESS-VERIFY, because that is the run whose
# result the verdicts are about — harness-suite.txt is the ground truth a
# CONFIRMED claim has to match, and scoring before it would read the previous
# attempt's artifacts.
#
# FAIL-OPEN, AND OUT LOUD. A box mid-sync has no lib; a box without jq has no
# scorer. Both append one honest line and change nothing else. Nothing in here
# exits, writes a RESULT or moves the tier — a verification aid that could stop
# a build would be a new terminal nobody audited, and the scorer's own rc is
# logged rather than acted on.
if [ -r "$HARNESS/bin/lib/evidence.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/evidence.sh"
fi
if declare -F evidence_score >/dev/null 2>&1; then
  EV_OUT=$(evidence_score "$BUILD" "$BUILD/plan.md" "${BASE:-}" . 2>>"$BUILD/pipeline.log" \
           | tee "$BUILD/evidence-verdicts.txt"); EV_RC=$?
  GATES_NOTE="${GATES_NOTE:-}"$'\n'"EVIDENCE VERDICTS:"$'\n'"$EV_OUT"
  echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE VERDICTS: scored (rc=$EV_RC)" >> "$BUILD/pipeline.log"
else
  GATES_NOTE="${GATES_NOTE:-}"$'\n'"EVIDENCE VERDICTS: could not run (lib absent)"
  echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE VERDICTS: could not run (lib absent)" >> "$BUILD/pipeline.log"
fi
# <<< evidence verdicts

# >>> vmap lies (tests/review-vmap.bh-2005-test.sh drives this block)
# --- The "What usually lies" bullets of the map entries this ticket's QA
# screens hit (BH-2005.2) -------------------------------------------------------
# An entry's lies field is the list of ways its feature looks right and is not.
# The reviewer gets those bullets through GATES_NOTE, beside the evidence rows,
# so a claim of "works" is read against them. The bullets come from
# vmap_entries_for + vmap_lies directly, not from vmap_note's text: that note is
# capped for a prompt, and a cap must never hide a bullet from the reviewer.
#
# FAIL-OPEN, AND OUT LOUD, like the evidence block above: every outcome appends
# one honest line and one pipeline.log line. Nothing in here exits, writes a
# RESULT or moves the tier.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/lib/vmap-entry.sh" ] && . "$HARNESS/bin/lib/vmap-entry.sh" 2>/dev/null || true
VMAP_LIES_OUT=""
if declare -F vmap_note >/dev/null 2>&1; then
  VMAP_NOTE=$(vmap_note . "$BUILD/plan.md")
  case "$(head -n1 <<<"$VMAP_NOTE")" in
    *" for this ticket's screens")
      VMAP_LIES_OUT=$(vmap_plan_screens "$BUILD/plan.md" | { mapfile -t _vs; [ "${#_vs[@]}" -gt 0 ] && vmap_entries_for . "${_vs[@]}"; } \
                      | while IFS= read -r _vf; do vmap_lies "$_vf"; done)
      if [ -n "$VMAP_LIES_OUT" ]; then
        VMAP_LINE="WHAT USUALLY LIES (verification map): check each bullet against this PR's evidence (screenshots, qa report, tests); a bullet the evidence cannot rule out is a finding"$'\n'"$VMAP_LIES_OUT"
      else
        VMAP_LINE="WHAT USUALLY LIES: matched entries carry no 'What usually lies' bullets (note only)"
      fi ;;
    *"no map entry for screens:"*) VMAP_LINE="WHAT USUALLY LIES: no map entry for this ticket's screens (note only)" ;;
    *) VMAP_LINE="WHAT USUALLY LIES: none in this repo" ;;
  esac
else
  VMAP_LINE="WHAT USUALLY LIES: could not run (lib absent)"
fi
GATES_NOTE="${GATES_NOTE:-}"$'\n'"$VMAP_LINE"
echo "$(STAMP) [$PROJECT/$KEY] VMAP LIES: $(head -n1 <<<"$VMAP_LINE") ($(grep -cE '^[[:space:]]*[-*][[:space:]]' <<<"$VMAP_LIES_OUT" || true) bullets)" >> "$BUILD/pipeline.log"
# <<< vmap lies

REVIEW_PROMPT="MECHANICAL GATES ran before you, on the diff itself. Their findings are ground truth about WHAT CHANGED (they are diff counts, not opinions) — treat them as evidence to adjudicate, never as a verdict already reached:${GATES_NOTE}

SPEC ARTIFACT, NOT CODE: this diff also carries $SPEC_DIR/ — this build's own plan.md (plus requirements.md when the plan stage wrote one), committed so the PR shows the spec beside the code. SKIP those files as a review target: they are ticket prose, so the iron laws do not apply to their lines (a client sentence quoting a native dialog, a model name, or VERCEL_URL inside the plan is not a violation), they are neither test evidence nor scope creep, and they are byte-identical to the plan you are already reviewing AGAINST. Judge the code against the spec; never judge the spec.

KNOWN GATE BLIND SPOT, yours to cover: the reproduction gate only proves tests that are NEW FILES. A test APPENDED to an existing suite is reported but never blocked, so an always-passing test added to a file that already existed reaches you unchallenged. When the note above says modified test files were seen, read the added cases in them and ask the question the gate could not: would this test FAIL if the feature broke? The same applies to a TEST-CHANGE: justification — the gate stops blocking once one is present, it does not check that it is true.

EVIDENCE VERDICTS: for every CONFIRMED row in the gates note above open the artifact it names and check it exists and shows the named test passing — a CONFIRMED whose artifact does not match is a verification-integrity finding (FRAUD: false-completion); a REFUTED row is a BLOCK unless the diff explains it; say for each INCONCLUSIVE row whether the diff lets you confirm it.

Adversarially review the diff of branch $BRANCH against $BASE in this repo (git diff $BASE...HEAD) for ticket $KEY, against the plan at $BUILD/plan.md and the iron laws in ~/.claude/CLAUDE.md (correctness, edge cases, additive-only schema, RLS on new tables, indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table, DB-driven config, no native dialogs, sortable headers, list-over-cards, drill-down, De-AI voice, idempotent writes, dedup-before-spend on metered/billable APIs, honest verification). PERFORMANCE BY DEFAULT (BH-6946), each one a [NOTE] (a BLOCK only on a measured regression on a key screen over the REVIEW LEVELS thresholds, or on a perf ticket): a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). GROUND TRUTH FIRST: read $BUILD/harness-suite.txt — the harness ran the repo's suite itself; its HARNESS_EXIT line outranks every agent-written claim. A nonzero HARNESS_EXIT with validate.txt/red.txt claiming green is an instant BLOCK and a verification-integrity finding (name it as such); 'no-test-script' and 'could-not-run' are recorded honestly, not treated as green (could-not-run: the impact gate's runner could not start or its stage timed out — nothing, or not everything, ran; it is not a red suite either). REQUIREMENTS COVERAGE: check the plan's '## Requirements coverage' matrix against the TICKET itself (re-read the ticket/thread) — a ticket requirement, including a negative one ('stop doing X'), absent from the matrix or undelivered by the diff is a blocking gap even if every listed task validated. SYSTEM INVARIANTS: verify the diff honors the plan's '## System invariants' section; an invariant the implementation quietly ignores is blocking. VALIDATION TRACE: read $BUILD/validate.txt against the plan's tasks. Every task's VALIDATE command must appear with a real exit code; a task the diff claims to deliver with no VALIDATE evidence is a [NOTE]; a VALIDATE recorded NOT RUN because it needs a key, prod, a browser or a CI token is a [NOTE] not verified here, never NEEDS_HUMAN; a recorded output that CONTRADICTS the claim on an ALWAYS-BLOCK path (data, tenant, auth, money, build) is a [BLOCK wrong-data] (an empty or missing validate.txt when the plan has VALIDATE lines is a [NOTE]). Check the SATISFIES traces too: work in the diff that traces to no acceptance criterion is scope creep, and a criterion with no task delivering it is a gap — call both. TEST HONESTY is part of the review: read the new/changed tests and $BUILD/red.txt — do the new tests actually assert the ticket's behavior (would they FAIL if the feature broke)? Was red proven before green? Was any existing test weakened, skipped, or deleted (instant BLOCK unless the diff justifies it as fixing a genuinely wrong test)? If the repo has test infra and the diff adds none for new behavior, that is a [NOTE] at smoke level and a [BLOCK core-flow-broken] only when the untested behavior is a core flow or an ALWAYS-BLOCK path. SECURITY: if $BUILD/semgrep.txt exists, triage every finding in it — real issues (injection, authz, secrets, SSRF, XSS) are blocking findings; note false positives with one line of reasoning each. For every finding that matches a rule in /root/harness/prompts/build-discipline.md, cite its rule number (D1-D34) so recurrence is measurable — and where the finding is ALSO one of the six fraud classes below, both citations ride the same line, e.g. (D1, FRAUD: weakened-tests); the top block-causes to hunt: non-probative tests (D1-D4), failure-mapped-to-success and dishonest completeness (D9-D13), authz fail-open and ungated sibling paths (D14-D15). FRAUD CLASSES — hunt these six by name. They are the shapes that survive review by looking like work: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done — PR body, board comment, status copy, validate.txt — the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec, docstring, or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. When a finding IS one of them, tag it on the finding line as FRAUD: <weakened-tests|false-completion|scope-creep|unauthorized-action|spec-betrayal|debris> — one class, the closest fit, and no tag at all on a finding that is none of them. The tag is harvested into logs/findings.log, so a class that keeps recurring becomes measurable rather than a feeling. HUB PROBES (D44): when a check needs hub-only credentials and it is one of \`app-status-write <owner/repo> <40-hex sha>\`, \`app-permissions <app-slug>\`, \`app-installation-repos\` or \`d1-count <table> <all|last-24h>\`, write \`HUB_PROBE: <name> <args>\` on its own line at column 0, outside any code block, in $BUILD/review.md above the TIER:/VERDICT: lines, instead of saying it needs a human; the harness files it and the hub runs it. A go-live step a user depends on (a live connector key, a vendor console, a production credential, a product decision) gets \`NEEDS_HUMAN: <the step>\`; a verification this box cannot run (no Clerk key, no prod database, no browser, no CI token, a Lighthouse run, a design screenshot) is a [NOTE] not verified here, never NEEDS_HUMAN. Write findings to $BUILD/review.md, one per line, each tagged [BLOCK <class>] (class from the ALWAYS-BLOCK list in the REVIEW LEVELS rule: data-loss, tenant-leak, auth-bypass, money, destructive-migration, red-build, core-flow-broken, wrong-data, secret, model-id, weakened-test) or [NOTE]; a review whose findings are all [NOTE] is VERDICT: APPROVE. Second-to-last line must be exactly 'TIER: 1' (low-risk: copy/docs/small UI, no schema, auth, permissions, payments, env, cron, or workflow changes, nothing touching client data handling) or 'TIER: 2' (everything else; reported, not gated). Last line must be exactly VERDICT: APPROVE or VERDICT: BLOCK.$(nh_prompt_field_note 2>/dev/null)$(dl_prompt_field_note 2>/dev/null)$(nh_prompt_release_note "${NH_SLUG:-}" "${NH_ISSUE:-}" 2>/dev/null)$(rl_prompt_note "$PROJECT" 2>/dev/null)"

# The T0 variant (BH-485). PREPENDED, never a rewrite: the gate note, the fraud
# classes, the requirements/invariants/validation trace and the TIER:/VERDICT:
# contract below are the general lens's whole brief and all of it still applies
# to a docs/tests diff. What the paragraph removes is the ONE class of finding a
# static diff cannot answer — "you did not show me this running" — on a diff
# where nothing was built because there was nothing to build.
if [ "$REVIEW_TIER" = T0 ]; then
  REVIEW_PROMPT="STATIC REVIEW, NO BUILD RUN. Every changed path in this diff is documentation, tests or CI config ($REVIEW_TIER_REASON). No application build, preview deployment or runtime check was run for this diff and none is expected of it. Judge the CONTENT of the changed files and the HONESTY of the claims made in them — a doc that describes behaviour the code does not have, a test that cannot fail, a claim of done the evidence does not support — and do not raise findings that demand build, preview or runtime evidence. Everything below still applies.

$REVIEW_PROMPT"
fi

SECURITY_PROMPT="SECURITY-ONLY review of the diff of branch $BRANCH against $BASE (git diff $BASE...HEAD) for ticket $KEY. You are the SECOND reviewer with ONE lens: could this change lose, leak, corrupt, or double-move client data or money? Judge ONLY: authz on every new/changed route (who can call it, what tenant scoping), injection (SQL/command/path), secrets or tokens in code or logs, RLS coverage on new tables, a client snapshot (localStorage, sessionStorage, IndexedDB, a persisted store) that holds a token, is not keyed by user and company, or survives sign-out, idempotency where money or records move (retries, webhooks, crons — can any path double-fire?), runaway SPEND on metered/billable third-party APIs (any call billed per minute/token/record inside a cron, poll or retry loop MUST consult a persisted ledger BEFORE the call; a dedup that runs after the response has already cost the money, and a vendor success that returns nothing is billed and must be terminal, never retried), fail-open vs fail-closed on auth checks, and unsafe trust of client-supplied ids. Ignore style, tests, UX — the general review covered those. FRAUD CLASSES — hunt these six by name. They are the shapes that survive review by looking like work: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done — PR body, board comment, status copy, validate.txt — the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec, docstring, or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. When a finding IS one of them, tag it on the finding line as FRAUD: <weakened-tests|false-completion|scope-creep|unauthorized-action|spec-betrayal|debris> — one class, the closest fit, and no tag at all on a finding that is none of them. The tag is harvested into logs/findings.log, so a class that keeps recurring becomes measurable rather than a feeling. Write findings to $BUILD/security-review.md. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."

# The refuter's framing depends on WHEN it runs. Sequentially it opened on "two
# reviewers already APPROVED" and was told to attack what they waved through;
# in parallel those two are reading the same diff at the same moment and their
# files may not exist yet, so that sentence would be a false premise pointing at
# an empty file. Same lens, honest premise — the rest of the brief is identical.
if [ "${LENSES_PARALLEL:-1}" != 1 ]; then
  REFUTE_PRIORS="Two reviewers already APPROVED ($BUILD/review.md, $BUILD/security-review.md). Your ONLY job is to REFUTE them:"
  REFUTE_READ_PRIORS="Read the plan ($BUILD/plan.md) and both prior reviews — a risk they NOTED but waved through is your first target."
else
  REFUTE_PRIORS="Two other reviewers are reading this SAME diff right now — the general adversarial review and the security-only lens. Do not wait for them and do not assume they found anything: $BUILD/review.md and $BUILD/security-review.md may not exist yet, and a missing or half-written one is not an approval. Your ONLY job is to refute the case that this diff is safe:"
  REFUTE_READ_PRIORS="Read the plan ($BUILD/plan.md). If $BUILD/review.md or $BUILD/security-review.md happens to be complete by the time you look, a risk it NOTED but waved through is your first target — but their absence tells you nothing and must not soften your verdict."
fi
REFUTE_PROMPT="You are the adversarial REFUTER on branch $BRANCH vs $BASE (git diff $BASE...HEAD) for ticket $KEY. $REFUTE_PRIORS assume this diff corrupts data, loses money, or breaks an invariant, and hunt for the proof they missed. This diff touches schema/migrations or money paths — the class where a wrong merge costs a revert plus a data repair. Attack: the migration's failure midway (is every statement idempotent and re-runnable? what state exists if it dies between statements?), schema-code ordering (does deployed code read a table/column before the migration applies, or vice versa — the TK-64 class?), money paths under retry/duplicate delivery, backfill correctness against real existing rows, and any assumption the plan made that the thread does not actually support. $REFUTE_READ_PRIORS If after genuine effort you cannot break it, say what you tried and concede. FRAUD CLASSES — hunt these six by name. They are the shapes that survive review by looking like work: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done — PR body, board comment, status copy, validate.txt — the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec, docstring, or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. When a finding IS one of them, tag it on the finding line as FRAUD: <weakened-tests|false-completion|scope-creep|unauthorized-action|spec-betrayal|debris> — one class, the closest fit, and no tag at all on a finding that is none of them. The tag is harvested into logs/findings.log, so a class that keeps recurring becomes measurable rather than a feeling. Write findings to $BUILD/refute-review.md. Last line exactly VERDICT: APPROVE (could not refute) or VERDICT: BLOCK."

if [ "${LENSES_PARALLEL:-1}" != 1 ]; then
  # --- Rollback path: the flow exactly as it shipped ------------------------
  # Per lens: review, one fix round, one re-review, harvest, adjudicate — and a
  # BLOCK exits here, so the lenses after it are never bought. That early exit
  # is the one thing the sequential order had going for it, and it survives.
  for LENS in $LENSES; do
    LENS_VARS "$LENS"
    if LENS_APPROVED "$LENS" && LENS_HEAD_MATCHES; then
      echo "$(STAMP) [$PROJECT/$KEY] $L_CKPT" >> "$BUILD/pipeline.log"
    else
      echo "$(STAMP) [$PROJECT/$KEY] $L_LOGLINE" >> "$BUILD/pipeline.log"
      LENS_CALL "$LENS"
      # The read-only lane joins here, before this lens's fix round — the first
      # thing in the pipeline that writes to the tree. `command -v` because
      # tests/parallel-lenses-test.sh extracts this block on its own, where the
      # lane and its joiner do not exist; with GATES_PARALLEL=0 the joiner is
      # defined and does nothing, the stage having already run in front of us.
      command -v GATES_JOIN >/dev/null 2>&1 && GATES_JOIN
      # Sequentially a round is bought PER LENS, so this is the path where a
      # tier's cap binds on a first run; over it, the round is skipped and the
      # lens is adjudicated on the verdict it already gave.
      if ! LENS_APPROVED "$LENS" && FIX_ROUND_ALLOWED; then
        echo "$(STAMP) [$PROJECT/$KEY] $L_FIXLOG" >> "$BUILD/pipeline.log"
        CC fix "$FIX_MODEL" 4800 "$BUILD/$L_FIXRUN" "$L_FIX${GATES_ASYNC_FINDINGS:-}"
        PUSH_BRANCH "$L_PUSH"
        CC review "$REVIEW_MODEL" 1200 "$BUILD/$L_RUN2" "$L_RE"
      fi
    fi
    # Harvest BEFORE the blocking guard — a BLOCK is the most valuable row in
    # logs/findings.log and exiting first would drop exactly those.
    "$HARNESS/bin/findings-log.sh" "$BUILD" "$PROJECT" "$KEY" >/dev/null 2>&1 || true
    LENS_APPROVED "$LENS" || LENS_REFUSE "$LENS"
    if [ "$LENS" = review ]; then git rev-parse HEAD > "$BUILD/review-head"; fi
  done
else
  # --- Parallel path -------------------------------------------------------
  LENS_T0=$(date +%s)
  LENS_LAUNCHED=""; LENS_PIDS=""
  for LENS in $LENSES; do
    LENS_VARS "$LENS"
    if LENS_APPROVED "$LENS" && LENS_HEAD_MATCHES; then
      echo "$(STAMP) [$PROJECT/$KEY] $L_CKPT" >> "$BUILD/pipeline.log"
      continue
    fi
    echo "$(STAMP) [$PROJECT/$KEY] $L_LOGLINE — launched in parallel" >> "$BUILD/pipeline.log"
    LENS_CALL "$LENS" &
    LENS_PIDS="$LENS_PIDS $!"
    LENS_LAUNCHED="$LENS_LAUNCHED $LENS"
  done
  # WAIT ON THE LENS PIDS, NEVER A BARE `wait`. This shell already owns a
  # background child that never exits: job_beat_start's heartbeat loop, launched
  # at claim time and killed only on EXIT (JOB_BEAT). A bare `wait` would block
  # on it until the claim's timeout, turning the fastest stage in the pipeline
  # into the one that hangs every build. Waiting on the named pids also means a
  # lens that dies is just a lens with no verdict, which the guards below
  # already treat as a refusal — no lens can abort its siblings.
  for LENS_PID in $LENS_PIDS; do wait "$LENS_PID" 2>/dev/null || true; done
  echo "$(STAMP) [$PROJECT/$KEY] LENSES:${LENS_LAUNCHED:- none} finished in $(( $(date +%s) - LENS_T0 ))s (parallel)" >> "$BUILD/pipeline.log"

  # THE JOIN. The read-only lane that was launched in front of these lenses
  # lands here — after every lens has read the diff, and before the merged fix
  # round, which is the first stage that moves the tree. Its findings go into
  # that one round with the lenses' own (GATES_ASYNC_FINDINGS below), which is
  # the whole point of joining here rather than after the block: a failure this
  # lane found is answered by the session that is already editing the code.
  # `command -v` for the extracted-block test, as in the sequential path.
  command -v GATES_JOIN >/dev/null 2>&1 && GATES_JOIN

  # BH-4489: a lens CC() deferred on a day budget cap (or an unreadable one)
  # left BUDGET_DEFER and exited its OWN subshell, so its missing verdict is
  # not a refusal. Defer here, before a fix round is bought on it or a lens
  # BLOCK is written for an outage or a cap that resets at 00:00Z.
  if [ -s "$BUILD/BUDGET_DEFER" ]; then
    # BH-5839: a steer-hold uses the same marker; the marker's line names which.
    echo "$(STAMP) [$PROJECT/$KEY] LENSES: a lens deferred on a budget cap or a hold ($(head -1 "$BUILD/BUDGET_DEFER")) — deferring the build, not a verdict" >> "$BUILD/pipeline.log"
    RESULT "BUILD_DEFERRED $(head -1 "$BUILD/BUDGET_DEFER")"
    exit 3
  fi

  LENS_BLOCKED=""
  for LENS in $LENSES; do LENS_APPROVED "$LENS" || LENS_BLOCKED="$LENS_BLOCKED $LENS"; done
  # >>> live emit review
  # One event per lens, read off the artifact that lens wrote. A lens that died
  # without writing a verdict emits `none`, which is what LIVE_LENS makes of a
  # missing file — silence is never an approval here either.
  if type LIVE_LENS >/dev/null 2>&1; then
    for LENS in $LENSES; do LIVE_LENS "$LENS" "$(LENS_ART "$LENS")" ""; done
  fi
  # <<< live emit review

  # On this path exactly ONE merged round is ever bought, so a cap of 1 or 2
  # binds here only on a RESUMED build that already carries a *fix-run.txt.
  if [ -n "$LENS_BLOCKED" ] && FIX_ROUND_ALLOWED; then
    # ONE fix round for all of them. The lenses read the same diff from
    # different angles, so two of them can name the same line and a fix for one
    # can reopen another — which is exactly why this is one session holding
    # every findings file rather than three sessions holding one each.
    LENS_FIX_FILES=""
    for LENS in $LENS_BLOCKED; do LENS_FIX_FILES="$LENS_FIX_FILES $(LENS_ART "$LENS")"; done
    echo "$(STAMP) [$PROJECT/$KEY] MERGED FIX ROUND ($FIX_MODEL) for lens(es):$LENS_BLOCKED" >> "$BUILD/pipeline.log"
    # >>> live emit fix
    # "1 of 1" and not a counter: this path buys exactly one merged round (the
    # cap above binds only on a resumed build), so there is nothing to count.
    type LIVE >/dev/null 2>&1 && LIVE fix started "fix round 1 of 1: lens(es)$LENS_BLOCKED refused"
    # <<< live emit fix
    # The head the fix round starts from, read BEFORE it runs: the gate below
    # judges what this session changed, not what the whole branch contains.
    FIX_FROM=$(git rev-parse HEAD 2>/dev/null)
    CC fix "$FIX_MODEL" 4800 "$BUILD/fix-run.txt" "Address every blocking finding from ALL of these review lenses in ONE pass, on branch $BRANCH (plan: $BUILD/plan.md):$LENS_FIX_FILES. They reviewed the SAME diff from different angles, so read every one of those files BEFORE you change anything: two lenses can name the same line, and a fix that satisfies one can reopen another. Never answer a finding by weakening, skipping or deleting a test, or by softening a claim. Re-verify; 'npm run build' must pass. Commit.${GATES_ASYNC_FINDINGS:-}"
    PUSH_BRANCH "the merged fix round"
    # >>> guard-silenced gate (tests/review-record-integrity-test.sh section 3 drives this block)
    # GUARD_SILENCED (BH-641). The cheapest way to turn a BLOCK into an APPROVE
    # is to edit the guard instead of the code it points at: add the flagged
    # path to the allow-list, to the ignore file, or rewrite the fixture the
    # check reads. The diff goes green and nothing was fixed. So the merged fix
    # round's OWN diff is classified before anyone reads it, and a round that
    # touched only guard rules, allow-lists or fixtures is an automatic BLOCK.
    # Same shape as the test-tamper gate above: one ALERTS line, an escalation,
    # a literal RESULT terminal, exit 6. A box without the lib classifies
    # nothing — a gate's own absence never demotes a build.
    if command -v gs_classify >/dev/null 2>&1 && [ -n "${FIX_FROM:-}" ]; then
      GS_VERDICT=$(git diff --name-only "$FIX_FROM"..HEAD 2>/dev/null | gs_classify); GS_RC=$?
      if [ "$GS_RC" = 1 ] && [ "$GS_VERDICT" = GUARD_SILENCED ]; then
        git diff --name-only "$FIX_FROM"..HEAD 2>/dev/null > "$BUILD/guard-silenced.txt"
        echo "$(STAMP) [$PROJECT/$KEY] BLOCKED: the fix round edited only guard rules/allow-lists/fixtures (GUARD_SILENCED)" >> "$ALERTS"
        echo "$(STAMP) [$PROJECT/$KEY] GUARD_SILENCED: $(tr '\n' ' ' < "$BUILD/guard-silenced.txt")" >> "$BUILD/pipeline.log"
        escalate_block "guard-silenced" "The merged fix round answered the blocking findings by editing only guard rules, allow-lists or fixtures — the code those guards point at is unchanged. Files it touched: $(tr '\n' ' ' < "$BUILD/guard-silenced.txt")"
        RESULT "REVIEW_BLOCKED guard-silenced: the fix round made a guard pass by editing its rule module/allow-list/fixture; see $BUILD/guard-silenced.txt"
        exit 6
      fi
    fi
    # <<< guard-silenced gate
    # >>> live emit fix done
    type LIVE >/dev/null 2>&1 && LIVE fix done "fix round done: $(git rev-parse --short HEAD 2>/dev/null || echo 'head not recorded') pushed for re-review"
    # <<< live emit fix done
    # Ground truth on the FIXED head, once, before anyone reads it. Its own file:
    # harness-suite.txt is the record of what the suite said when the lenses
    # first read the diff, and overwriting it would destroy that.
    HARNESS_SUITE_RUN harness-suite-fix.txt fix
    # >>> live emit suite fix
    type LIVE_SUITE >/dev/null 2>&1 && LIVE_SUITE "$BUILD/harness-suite-fix.txt" "after the fix round: "
    # <<< live emit suite fix
    # ONE re-review, adjudicating every lens that refused. A verdict file left
    # behind by an EARLIER resume of this build is about an earlier head and is
    # not evidence about this one — same rule as every other checkpoint here.
    rm -f "$BUILD/merged-review2.md"
    LENS_TAGS=""; LENS_NAMED=""
    for LENS in $LENSES; do
      case "$LENS" in
        review)   LENS_TAGS="$LENS_TAGS VERDICT-REVIEW:";   LENS_NAMED="$LENS_NAMED the general adversarial review ($BUILD/review.md);" ;;
        security) LENS_TAGS="$LENS_TAGS VERDICT-SECURITY:"; LENS_NAMED="$LENS_NAMED the security-only lens ($BUILD/security-review.md);" ;;
        refute)   LENS_TAGS="$LENS_TAGS VERDICT-REFUTE:";   LENS_NAMED="$LENS_NAMED the adversarial refuter ($BUILD/refute-review.md);" ;;
      esac
    done
    # DELTA OR FULL (BH-2546). Every lens read the whole branch at FIX_FROM; if
    # what the fix round added is small, the re-review reads that delta and the
    # prior findings instead of the whole branch again. The decision is logged
    # BEFORE the call, so a review that dies still says which prompt it had. A
    # delta file left by an earlier resume is about another head: removed first.
    rm -f "$BUILD/fix-delta.diff"
    FDR=""; FDR_MODE=full
    command -v fdr_decide >/dev/null 2>&1 && FDR=$(fdr_decide "$BASE" "${FIX_FROM:-}" HEAD "$BUILD/fix-delta.diff")
    case "$FDR" in "delta "*|"full "*) ;; *) FDR="full lib-unavailable" ;; esac
    if [ "${FDR%% *}" = delta ] && [ -r "$BUILD/fix-delta.diff" ]; then
      read -r _ FDR_LINES FDR_MAX <<<"$FDR"
      FDR_MODE=delta
      # The TIER a delta reviewer writes is about the delta, but it becomes the
      # build's tier. The whole-branch tier the general lens gave is its FLOOR:
      # any TIER: 2 the general lens ever wrote (or none at all) keeps it 2.
      FDR_PRIOR_TIER="TIER: 1"
      grep -qE '^TIER: 1$' "$BUILD/review.md" 2>/dev/null && ! grep -qE '^TIER: 2$' "$BUILD/review.md" 2>/dev/null || FDR_PRIOR_TIER="TIER: 2"
      echo "$(STAMP) [$PROJECT/$KEY] FIX-DELTA-REVIEW mode=delta lines=$FDR_LINES max=$FDR_MAX reason=within-max" >> "$BUILD/pipeline.log"
      FIX_REVIEW_SCOPE="(1) A DELTA REVIEW for ticket $KEY, not a re-read of the whole branch. TIER FLOOR: the general lens tiered the WHOLE branch '$FDR_PRIOR_TIER'; your TIER line cannot lower it (a delta is not the branch, and the harness keeps the higher of the two), so write 'TIER: 2' if the delta itself is tier 2, and never read 'the delta is small' as 'the branch is tier 1'. Every lens above already read the whole diff at head $FIX_FROM (git diff $BASE...$FIX_FROM); the only thing new is what the fix round committed on top of it, $FDR_LINES changed line(s), shown at the end of this paragraph as git range-diff $BASE $FIX_FROM HEAD followed by git diff $FIX_FROM HEAD (the same text is in $BUILD/fix-delta.diff). PRIOR FINDINGS — the blocking findings this delta has to answer are in:$LENS_FIX_FILES. Judge ONLY (a) whether each prior blocking finding is actually answered by this delta, and (b) whether the delta itself introduces a regression, a weakened test, a guard edit or scope creep against the plan at $BUILD/plan.md and the iron laws in ~/.claude/CLAUDE.md; read code outside the delta only where a finding or the delta points at it. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). A delta with no new commit means the fix round changed nothing, so every prior blocking finding is unanswered. THE DELTA:
$(cat "$BUILD/fix-delta.diff")
(end of the delta)."
    else
      FDR_WHY=${FDR#full }; [ "${FDR%% *}" = full ] || FDR_WHY=delta-file-missing
      echo "$(STAMP) [$PROJECT/$KEY] FIX-DELTA-REVIEW mode=full lines=- max=- reason=$FDR_WHY" >> "$BUILD/pipeline.log"
      FIX_REVIEW_SCOPE="(1) The general adversarial review of the CURRENT diff (git diff $BASE...HEAD) for ticket $KEY against the plan at $BUILD/plan.md and the iron laws in ~/.claude/CLAUDE.md — the fix round moved the tree, so the earlier general verdict is about a head that no longer exists. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902)."
    fi
    echo "$(STAMP) [$PROJECT/$KEY] MERGED RE-REVIEW ($REVIEW_MODEL)" >> "$BUILD/pipeline.log"
    CC review "$REVIEW_MODEL" 1200 "$BUILD/review2-run.txt" "RE-REVIEW AFTER ONE MERGED FIX ROUND. Branch $BRANCH was read by these lenses at once:$LENS_NAMED and the ones that refused were answered by a SINGLE fix session, so the commits you are about to read were written against several sets of findings at the same time. Do two things. $FIX_REVIEW_SCOPE GROUND TRUTH FIRST: read $BUILD/harness-suite-fix.txt — the harness re-ran the repo's suite on THIS head and its HARNESS_EXIT line outranks every agent-written claim; a nonzero exit is an instant BLOCK and a verification-integrity finding, and 'no-test-script' and 'could-not-run' are recorded honestly, never treated as green (could-not-run: the impact gate's runner could not start or its stage timed out — it is not a red suite either). (2) For EACH lens listed above, read its findings file and say whether THAT lens's blocking findings are actually answered on this head — an unanswered finding, or one answered by weakening a test, skipping an assertion or softening a claim, is still a BLOCK for that lens. GUARD_SILENCED: a fix round that makes a static guard pass by editing the guard's own rule module, allow-list or fixture (checks/, guardrails/, *allowlist*, *ignore files, semgrep/eslint/gitleaks config, fixtures, snapshots) instead of the code the guard points at is an automatic BLOCK — write GUARD_SILENCED on that finding line. Work the fix round did that no finding asked for is scope creep and belongs in the general verdict. FRAUD CLASSES — hunt these six by name: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. Tag any finding that is one of them as FRAUD: <class>, and cite build-discipline rule numbers (D1-D34) where they apply.$(dl_prompt_field_note 2>/dev/null) Write everything to $BUILD/merged-review2.md. Its LAST lines must be, in this order and nothing after them: 'TIER: 1' or 'TIER: 2' (the same tier rule the general review has always used), then exactly one line per lens, each of the form '<tag> APPROVE' or '<tag> BLOCK', for these tags and no others:$LENS_TAGS"
    # Fan the per-lens verdicts back onto the per-lens artifacts, so every
    # consumer that has ever read "the last line of security-review.md" still
    # reads a verdict about the head that is actually going to merge.
    LENS_MR="$BUILD/merged-review2.md"
    LENS_TIER=$(grep -oE '^TIER: [12]$' "$LENS_MR" 2>/dev/null | tail -1)
    [ -n "$LENS_TIER" ] || LENS_TIER=$(grep -oE '^TIER: [12]$' "$BUILD/review.md" 2>/dev/null | tail -1)
    [ -n "$LENS_TIER" ] || LENS_TIER="TIER: 2"
    # A delta re-review never lowers the whole-branch tier (see TIER FLOOR).
    if [ "$FDR_MODE" = delta ] && [ "$FDR_PRIOR_TIER" = "TIER: 2" ] && [ "$LENS_TIER" != "TIER: 2" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] DELTA-TIER-FLOOR: the delta re-review wrote $LENS_TIER; the whole-branch tier was $FDR_PRIOR_TIER, which stands" >> "$BUILD/pipeline.log"
      LENS_TIER="TIER: 2"
    fi
    LENS_SHA=$(git rev-parse --short HEAD 2>/dev/null)
    for LENS in $LENSES; do
      LENS_VARS "$LENS"
      case "$LENS" in review) LENS_TAG=VERDICT-REVIEW ;; security) LENS_TAG=VERDICT-SECURITY ;; refute) LENS_TAG=VERDICT-REFUTE ;; esac
      # The tag lines are the LAST lines of the merged re-review, one per lens
      # after TIER, so the reader's final block is widened by exactly that many
      # (BH-1625). Unknown is the empty answer below: silence, never APPROVE.
      LENS_V=$(verdict_parse -l "$LENS_TAG" -x "$(wc -w <<<"$LENS_TAGS" | tr -d ' ')" "$LENS_MR" 2>/dev/null) || LENS_V=""
      if [ -z "$LENS_V" ]; then
        # The re-review said nothing about this lens. Two different silences.
        # For the general lens and for any lens that REFUSED, silence is a
        # refusal: this re-review IS the general lens's pass over the new head,
        # and nothing can lift a refusal by saying nothing. For a lens that
        # APPROVED and was simply not re-asked, its own verdict stands — the
        # same residual the head-bound gate settles with one general re-review,
        # and defaulting it to BLOCK would turn a sloppy re-review into a
        # terminal that does not requeue.
        case " review $LENS_BLOCKED " in *" $LENS "*) LENS_V=BLOCK ;; *) continue ;; esac
      fi
      {
        printf '\n=== MERGED RE-REVIEW after the single fix round (head %s) ===\n' "$LENS_SHA"
        if [ "$LENS" = review ]; then
          grep -vE "^[[:space:]]*(VERDICT-(REVIEW|SECURITY|REFUTE):|TIER: [12]$)" "$LENS_MR" 2>/dev/null
          printf '%s\n' "$LENS_TIER"
        else
          printf 'The lenses ran in parallel and ONE fix round answered them together; the full re-review is in %s and its %s line is the verdict below.\n' "$LENS_MR" "$LENS_TAG"
        fi
        printf 'VERDICT: %s\n' "$LENS_V"
      } >> "$L_ART"
      echo "$(STAMP) [$PROJECT/$KEY] MERGED RE-REVIEW: $LENS -> $LENS_V" >> "$BUILD/pipeline.log"
      # >>> live emit rereview
      type LIVE >/dev/null 2>&1 && LIVE review "$LENS_V" "re-review after the fix round: $LENS -> $LENS_V"
      # <<< live emit rereview
    done
  fi
  # Harvest every lens BEFORE adjudicating, for the same reason the sequential
  # path does it in that order: a BLOCK is the row worth keeping.
  "$HARNESS/bin/findings-log.sh" "$BUILD" "$PROJECT" "$KEY" >/dev/null 2>&1 || true
  # Adjudicate in the order the sequential flow reached them, so a diff several
  # lenses refuse terminates under the same name it always did.
  for LENS in review security refute; do
    case " $LENSES " in *" $LENS "*) ;; *) continue ;; esac
    LENS_VARS "$LENS"
    LENS_APPROVED "$LENS" || LENS_REFUSE "$LENS"
  done
  # Every lens has approved THIS head, and no fix round commits after this line
  # — so the approval and the head are bound here, once. The head-bound gate
  # further down sees no drift unless preview QA commits later, which is
  # precisely the drift it exists to catch.
  git rev-parse HEAD > "$BUILD/review-head"
fi
fi  # end REVIEW checkpoint
# <<< review lenses
STAGE_END lenses "$T_LENSES"

# THE BACKSTOP JOIN. A build whose lenses all hit their checkpoint reaches here
# without having touched either call site above, and the rebase on the next line
# rewrites the worktree — so the lane has to be collected before it, whatever
# path got us here. Idempotent: on every other path this is already done and
# costs a variable read.
GATES_JOIN

} # end rb_review
