# bin/lib/rb/pr.sh — the PR stage: rebase, tier classification, size posthoc, the migration gate, opening the PR, the phase-7 artifact, and preview QA.
# The body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
# Entry functions, pipeline order: rb_pr
# Reads: ADDED_SQL ALERTS ASSUMPTIONS_SECTION BASE BASEF BASE_MAIN BRANCH BUILD
#   BUILDER_NO_MERGE CHANGED CLOSES_LINE COST_LINE CTX_COMMIT CTX_FRESH CTX_SIG CTX_SYNC
#   DELTA E2E_VERDICT EB_SUBJECT EVIDENCE EVIDENCE_BLOCK EVIDENCE_SECTION EVID_MIG
#   EXECUTE_MODEL FIX_MODEL GH_ERR_AT HARNESS HF_LABEL HF_NUM HF_PR HF_SLUG HOTFIX
#   HOTFIX_PREFIX INTENT_RC JOB_ID KEY MERGE_NOTE MIG_FILES MIG_NOTE MIG_SECTION MQ_COM
#   MQ_ENQUEUED MQ_PRNUM NEWERR NF NFLAG NODE_OPTIONS PAT PCF_SLUG PLAN_MODEL PREBASE
#   PREUN PREVIEW_URL PROJECT PR_CREATE_ERR PR_SUBJECT PR_SUBJECTS PR_URL
#   QA_CLERK_SECRET_KEY QA_MODEL QA_TEST_USER_ID RB_HEAP RB_HEAP_SRC RB_MAIN RB_MAIN_S
#   RB_MB RB_MB_S RB_RC REPRO_RC REVIEW_MODEL RH_N RH_NEW RH_PRE RH_UN RH_UNEW RH_UPRE RM
#   SECRET SG_ENFORCE SG_SWITCH_SRC SHA SLUG SPEC_LINE SP_BOUND SP_ENFORCE SP_FILES
#   SP_LIMITS SP_LINES SP_MAXL SP_OUT SR_ANS SR_HEAD SR_MERGED_AT SR_PARENT SR_PROVEN
#   SR_RC SR_SLUG SR_STATE SR_TIP SR_UNSTACKED SR_URL SR_WHY STACK_ON STACK_PARENT_PR
#   SPEC_CHANGES_SECTION STACK_SECTION TAMPER_RC TC_INCONCLUSIVE TC_OK TIER TIER_HIT TIER_HITS TMPDIR TSC_FLAGS
#   TSC_HEAP_MB T_PR T_QA T_REBASE T_TIER UN_BASEF UN_HOW UN_NEWERR UN_TC UN_TSC_FLAGS
#   UN_VERIFIED UN_WHYNOT VERDICT_PROV VERDICT_RSHA VERDICT_WORD VERIFY_LINE WHAT_BASE
#   WHAT_LIST WHAT_MB WHY_EXCERPT WP_RC WP_WHY WT _ _ASSUM _CL_ISSUE _PRM _SPECC
#   CALLERS_SECTION CK_CONF_WARN CK_MAX_LINES
# Writes: ADDED_SQL ASSUMPTIONS_SECTION BASE BASEF CHANGED CLOSES_LINE COST_LINE DELTA DIFF_NOTE
#   EB_SUBJECT EVIDENCE EVIDENCE_SECTION EVID_MIG GH_ERR_AT HF_LABEL HF_NUM HF_PR HF_SLUG
#   HOTFIX HOTFIX_PREFIX IFS MERGE_NOTE MIG_FILES MIG_NOTE MIG_SECTION MQ_COM MQ_ENQUEUED
#   MQ_PRNUM NEWERR NFLAG NODE_OPTIONS PAT PCF_SLUG PREBASE PREUN PR_CREATE_ERR PR_SUBJECT
#   PR_SUBJECTS PR_URL RB_MAIN RB_MAIN_S RB_MB RB_MB_S RB_RC REBASE_NOTE RH_N RH_PRE RH_UN
#   RH_UPRE SHA SIZE_NOTE SLUG SP_BOUND SP_ENFORCE SP_FILES SP_LIMITS SP_LINES SP_MAXL
#   SP_OUT SR_ANS SR_PARENT SR_PROVEN SR_RC SR_SLUG SR_STATE SR_TIP SR_UNSTACKED SR_WHY
#   SPEC_CHANGES_SECTION STACK_NOTE STACK_SECTION TC_INCONCLUSIVE TC_OK TIER TIER_HITS TSC_FLAGS T_PR T_QA
#   T_REBASE T_TIER UN_BASEF UN_HOW UN_NEWERR UN_TC UN_TSC_FLAGS UN_WHYNOT VERDICT_PROV
#   VERDICT_RSHA VERDICT_WORD VERIFY_LINE WHAT_BASE WHAT_LIST WHAT_MB WHY_EXCERPT WP_RC WP_WHY _ASSUM _SPECC
#   _CL_ISSUE
#   CALLERS_SECTION CK_BASE CK_RC CK_SUM RB_BUILT_SHA
# shellcheck shell=bash

rb_pr() {
# --- Rebase onto latest main before the PR (2026-08-17, the #318 class) ------
# A 1-2h execute means main moves mid-build: #318 was cut at 22:29Z, #316
# merged mid-flight, and #318 arrived DIRTY — a full rebuild to recover. So:
# fetch, and if main moved, rebase THIS branch onto origin/$BASE now, then
# mechanically re-typecheck (a clean rebase can still break semantically).
# Conflict -> abort the rebase and say so LOUDLY in RESULT/PR (the old
# behavior, minus the surprise). Typecheck fail -> reset to the pre-rebase
# head and say that instead. Never silently ship a base older than claimed.
#
# SERIAL EDGE, and the hardest one in the file: this block REWRITES the
# worktree. Nothing that reads the tree may run beside it, which is why the
# read-only lane is joined on the line above rather than here.
# >>> stack recheck
# THE PARENT CAN VANISH MID-BUILD (#574). The stack was settled ONCE, at build
# start (`# >>> stacked child builds`), by a fetch that succeeded. A build takes
# tens of minutes: project-5 #1663's PR merged at 16:30Z, GitHub deleted
# ticket/TK-1663, and the child's `gh pr create --base ticket/TK-1663` at 16:49Z
# had no base left to point at. Nothing between those two moments re-asked.
# The rebase below cannot notice either — its fetch ends in `|| true`, so a
# fetch that failed because the branch is GONE leaves the stale
# refs/remotes/origin/<parent> in place, the rev-parse == merge-base test reads
# "the parent has not moved", and the child ships a base nobody has: which is
# also exactly how that child re-added a file its parent had deleted.
#
# `ls-remote` and not `fetch`, because only ls-remote gives the three-way answer
# the decision needs: rc 0 present, rc 2 absent, rc 128 origin unreachable.
# A fetch cannot tell "gone" from "network", and unstacking onto main because of
# a network blip would rebase a child off a parent that is still alive.
if [ -n "${STACK_ON:-}" ]; then
  SR_RC=0
  git ls-remote --exit-code --heads origin "$STACK_ON" >/dev/null 2>&1 || SR_RC=$?
  if [ "$SR_RC" = 0 ]; then
    : # The parent is alive. The rebase block below fetches it and rebases onto
      # its CURRENT head, which is the other half of the ticket.
  elif [ "$SR_RC" != 2 ]; then
    # Not an answer, an outage. Stay stacked — today's behaviour — and if the
    # branch really was gone, the create below fails honestly and says so.
    echo "$(STAMP) [$PROJECT/$KEY] stack recheck: could not probe origin for $STACK_ON (git ls-remote rc $SR_RC) — staying stacked on it" >> "$BUILD/pipeline.log"
  else
    # GONE. Only a MERGED parent PR may unstack this child: main contains the
    # parent's work, so dropping the parent's commits loses nothing. A parent
    # closed unmerged, an unanswerable `gh`, or a PR on some OTHER branch that
    # merely starts with the parent's name (ticket/TK-611-r2) all escalate
    # instead — `rebase --onto` is irreversible inside this build, and an
    # unproven merge would ship a child whose base is missing.
    SR_PARENT="$STACK_ON"
    SR_SLUG=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
    SR_ANS=$(gh pr list -R "$SR_SLUG" --head "$SR_PARENT" --state all --json url,state,mergedAt,headRefName -q '.[0] | "\(.state // "")\t\(.url // "")\t\(.mergedAt // "")\t\(.headRefName // "")"' 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
    # One read, not four `cut`s: cut with no delimiter in the line echoes the
    # WHOLE line back for every field, so a one-word answer from a broken gh
    # would arrive as a non-empty mergedAt AND a matching headRefName.
    SR_STATE=""; SR_URL=""; SR_MERGED_AT=""; SR_HEAD=""
    IFS=$'\t' read -r SR_STATE SR_URL SR_MERGED_AT SR_HEAD <<< "$SR_ANS" || true
    SR_UNSTACKED=0
    SR_PROVEN=0
    if [ "$SR_HEAD" = "$SR_PARENT" ] && { [ -n "$SR_MERGED_AT" ] || [ "$SR_STATE" = MERGED ]; }; then
      SR_PROVEN=1
      git fetch origin "+refs/heads/$BASE_MAIN:refs/remotes/origin/$BASE_MAIN" --quiet 2>/dev/null || true
      # The parent's tip AS THIS CHILD KNOWS IT is the merge-base: everything
      # below it belongs to the parent, everything above it is this ticket's.
      SR_TIP=$(git merge-base "refs/remotes/origin/$SR_PARENT" HEAD 2>/dev/null || true)
      PREUN=$(git rev-parse HEAD)
      # Head-bound approval: measured here, CARRIED ONLY IF SOMETHING VERIFIES
      # the rebased tree (below). The distance is only meaningful while the
      # reviewed sha is still on this branch, so it is measured against PREUN
      # and refused otherwise — a half-resolved mapping would let the
      # head-bound gate see LESS drift than there is, which is the one way this
      # block could make the pipeline blinder than it was.
      RH_UPRE=$(cat "$BUILD/review-head" 2>/dev/null || true)
      RH_UN=""
      [ -n "$RH_UPRE" ] && git merge-base --is-ancestor "$RH_UPRE" "$PREUN" 2>/dev/null \
        && RH_UN=$(git rev-list --count "$RH_UPRE".."$PREUN" 2>/dev/null || true)
      if [ -z "$SR_TIP" ]; then
        # Nothing was rewritten: no merge-base with the parent's remote ref, so
        # there is no honest `--onto` point. Said in its own words, because
        # "CONFLICTED" here would describe a rebase that never ran.
        echo "$(STAMP) [$PROJECT/$KEY] unstack from $SR_PARENT: could not resolve the parent's tip in this checkout (no merge-base with refs/remotes/origin/$SR_PARENT) — nothing was rewritten, staying stacked" >> "$BUILD/pipeline.log"
      elif git rebase --onto "refs/remotes/origin/$BASE_MAIN" "$SR_TIP" >> "$BUILD/pipeline.log" 2>&1; then
        # A CLEAN REBASE IS NOT A VERIFIED ONE. This moves the child off the
        # parent's branch onto a main that has also gained every other PR that
        # landed while this build ran — a BIGGER base change than the pre-PR
        # rebase below, which typechecks before it dares carry the approval
        # ("a clean rebase can still break semantically"). Same bar here, for
        # the same reason: red means reset and escalate, never a tier-1
        # auto-merge on an approval rebound to a tree nothing compiled.
        UN_TC=1; UN_VERIFIED=0; UN_HOW="this repo has no typecheck to run"
        UN_TSC_FLAGS=""; [ -f tsconfig.build.json ] && UN_TSC_FLAGS="-p tsconfig.build.json"
        if [ -f tsconfig.build.json ] || [ -f tsconfig.json ]; then
          UN_HOW="typecheck green"; UN_VERIFIED=1
          timeout 900 npx tsc $UN_TSC_FLAGS --noEmit > "$BUILD/unstack-tsc.txt" 2>&1 || UN_TC=0
          cat "$BUILD/unstack-tsc.txt" >> "$BUILD/pipeline.log"
          # Baseline-aware for the same reason the rebase below is: an error
          # main already had is main's, not this unstack's damage. No cached
          # baseline = the strict reading stands (fail closed).
          if [ "$UN_TC" = 0 ]; then
            UN_BASEF="$HARNESS/state/tsc-baseline-$PROJECT.txt"
            if [ -s "$UN_BASEF" ] && [ "$(find "$UN_BASEF" -mmin -240 2>/dev/null | wc -l)" -gt 0 ]; then
              UN_NEWERR=$(grep "error TS" "$BUILD/unstack-tsc.txt" | sort -u | comm -13 "$UN_BASEF" - | wc -l)
              if [ "$UN_NEWERR" -eq 0 ]; then
                UN_TC=1; UN_HOW="typecheck red but zero NEW errors vs the $PROJECT baseline"
                echo "$(STAMP) [$PROJECT/$KEY] unstack typecheck red but zero NEW errors vs the $PROJECT baseline — accepting" >> "$BUILD/pipeline.log"
              fi
            fi
          fi
        fi
        if [ "$UN_TC" = 1 ]; then
          SR_UNSTACKED=1
          BASE="$BASE_MAIN"; STACK_ON=""
          STACK_NOTE=" | UNSTACKED from $SR_PARENT (its PR ${SR_URL:-url not resolved} merged and the branch was deleted mid-build) — rebased onto $BASE_MAIN and this PR targets $BASE_MAIN"
          # THE APPROVAL MOVES ONLY WITH THE PROOF. A typecheck actually ran and
          # passed, so the reviewed tree is carried across by DISTANCE the way
          # the pre-PR rebase does it: `rebase --onto` preserves this child's own
          # commit count, so the commit RH_UN back from the new head holds the
          # tree the reviewer read. With NO typecheck in this repo nothing has
          # read this tree on this base, so the file is left alone and the
          # head-bound gate re-runs the suite and buys one re-review — fail
          # toward being read, which is also what keeps the released stacked
          # merge-hold from turning into an unreviewed tier-1 merge.
          if [ "$UN_VERIFIED" = 1 ] && [ -n "$RH_UPRE" ] && [ -n "$RH_UN" ]; then
            if [ "$RH_UN" = 0 ]; then
              git rev-parse HEAD > "$BUILD/review-head"
            elif RH_UNEW=$(git rev-parse --verify -q "HEAD~$RH_UN" 2>/dev/null); then
              echo "$RH_UNEW" > "$BUILD/review-head"
            else
              echo "$(STAMP) [$PROJECT/$KEY] unstack: could not map the reviewed head ${RH_UPRE:0:8} (~$RH_UN) across it — the head-bound gate will re-review" >> "$BUILD/pipeline.log"
            fi
          elif [ -n "$RH_UPRE" ]; then
            if [ "$UN_VERIFIED" = 1 ]; then
              UN_WHYNOT="the reviewed sha is not on this branch any more, so no distance describes where it went"
            else
              UN_WHYNOT="$UN_HOW, so nothing has read this tree on $BASE_MAIN"
            fi
            echo "$(STAMP) [$PROJECT/$KEY] unstack: the approval stays bound to ${RH_UPRE:0:8} — $UN_WHYNOT, and the head-bound gate re-runs the suite and buys one re-review" >> "$BUILD/pipeline.log"
          fi
          echo "$(STAMP) [$PROJECT/$KEY] UNSTACKED from $SR_PARENT: its PR ${SR_URL:-url not resolved} merged and origin deleted the branch mid-build — rebased $BRANCH onto $BASE_MAIN ($(git rev-parse --short "refs/remotes/origin/$BASE_MAIN")) + $UN_HOW, and the PR targets $BASE_MAIN" >> "$BUILD/pipeline.log"
        else
          git reset --hard "$PREUN" >> "$BUILD/pipeline.log" 2>&1 || true
          echo "$(STAMP) [$PROJECT/$KEY] unstack from $SR_PARENT onto $BASE_MAIN typechecked RED — reset to $(git rev-parse --short HEAD), still stacked" >> "$BUILD/pipeline.log"
        fi
      else
        git rebase --abort >> "$BUILD/pipeline.log" 2>&1 || true
        git reset --hard "$PREUN" >> "$BUILD/pipeline.log" 2>&1 || true
        echo "$(STAMP) [$PROJECT/$KEY] unstack from $SR_PARENT CONFLICTED — aborted and reset to $(git rev-parse --short HEAD), still stacked" >> "$BUILD/pipeline.log"
      fi
    fi
    if [ "$SR_UNSTACKED" = 0 ]; then
      # WHY it could not unstack is two different facts, and the log has to say
      # which: a parent nobody could prove merged, or a parent that IS merged
      # whose rebase this build refused (conflict, red typecheck, no tip). The
      # second one reading "not provably merged (state MERGED)" is the log
      # contradicting itself in the exact state an operator is reading it to
      # understand.
      if [ "$SR_PROVEN" = 1 ]; then
        SR_WHY="gone from origin and its PR ${SR_URL:-url not resolved} IS merged, but this build could not rebase $BRANCH onto $BASE_MAIN (the line above says which step refused)"
      else
        SR_WHY="gone from origin and not provably merged (state ${SR_STATE:-unknown})"
      fi
      # ONE actionable line, because a build that needs a decision this box
      # cannot make has to say so where a human reads it.
      echo "$(STAMP) [$PROJECT/$KEY] STACK PARENT GONE: $SR_PARENT was deleted from origin mid-build and this build could not unstack $BRANCH from it — parent PR ${SR_URL:-none found} state ${SR_STATE:-unknown}, merged ${SR_MERGED_AT:-no}. The PR create will fail against the missing base. A human decides: rebase $BRANCH onto $BASE_MAIN and open it there, or close the ticket." >> "$ALERTS"
      echo "$(STAMP) [$PROJECT/$KEY] stack parent $SR_PARENT is $SR_WHY — escalated to ALERTS, staying on the missing base so the create fails honestly" >> "$BUILD/pipeline.log"
    fi
  fi
fi
# <<< stack recheck

# >>> pre-pr rebase
T_REBASE=$(STAGE_START)
# STACKED (2026-09-14): $BASE is the parent's branch, so this is a rebase onto
# the PARENT, never onto main — the child's PR must keep showing only the
# child's diff. The refspec is explicit for the same single-branch-clone reason
# the worktree setup gives: a plain `git fetch origin <parent>` lands in
# FETCH_HEAD and leaves refs/remotes/origin/<parent> stale, which would rebase
# onto the parent as it looked when this build started rather than as it is.
REBASE_NOTE=""
# >>> rebase verify
if [ -n "$STACK_ON" ]; then
  git fetch origin "+refs/heads/$BASE:refs/remotes/origin/$BASE" --quiet 2>/dev/null || true
else
  git fetch origin "$BASE" --quiet 2>/dev/null || true
fi
# BH-575: the heap this verify typecheck runs at. A project whose tsc needs more
# than Node's default (project-5: 6144, its own CI sets it) aborted here at 134
# before printing a single diagnostic, and the step called that "red". Order:
# the operator's per-project knob first (env/<project>.env, sourced at :349),
# then the largest heap the repo's own CI declares, then 70% of RAM capped at
# 12288 — the rule bin/edit-feedback-hook.sh:52-54 already uses. Echoes
# "<MB> <source>" because a command substitution cannot hand a global back.
rebase_tsc_heap() {
  local h="" src=""
  case "${TSC_HEAP_MB:-}" in ''|0|*[!0-9]*) : ;; *) h="$TSC_HEAP_MB"; src=env ;; esac
  if [ -z "$h" ]; then
    h=$(grep -rhoE 'max-old-space-size=[0-9]+' .github/workflows/ 2>/dev/null | grep -oE '[0-9]+$' | sort -n | tail -1)
    [ -n "$h" ] && src=workflow
  fi
  if [ -z "$h" ]; then
    local mem; mem=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null); [ -n "$mem" ] || mem=8192
    h=$(( mem * 7 / 10 )); [ "$h" -gt 12288 ] && h=12288; src=ram
  fi
  echo "$h $src"
}
# BH-575: "main moved" is a claim about two shas, so read them once and print
# them in every note. An EMPTY merge-base (a shallow pool clone, unrelated
# histories) also compares unequal to a real sha — the old test read that as a
# move and rebased on the strength of nothing.
RB_MAIN=$(git rev-parse "origin/$BASE" 2>/dev/null || true)
RB_MB=$(git merge-base "origin/$BASE" HEAD 2>/dev/null || true)
RB_MAIN_S=unresolved; [ -n "$RB_MAIN" ] && RB_MAIN_S=$(git rev-parse --short=12 "$RB_MAIN" 2>/dev/null || echo unresolved)
RB_MB_S=unresolved;   [ -n "$RB_MB" ]   && RB_MB_S=$(git rev-parse --short=12 "$RB_MB" 2>/dev/null || echo unresolved)
if [ -n "$RB_MAIN" ] && [ -n "$RB_MB" ] && [ "$RB_MAIN" != "$RB_MB" ]; then
  PREBASE=$(git rev-parse HEAD)
  # Head-bound approval (SDLC item 1): where the reviewed head sits relative to
  # HEAD, measured BEFORE the rebase rewrites every sha on the branch. The
  # security and refuter fix rounds commit ABOVE this line, so by the time we
  # get here review-head is usually an ANCESTOR of HEAD rather than HEAD itself
  # — matching on equality alone left the file pointing at a sha the rebase
  # orphaned, and the gate below then counted main's whole merged history as
  # this build's unreviewed drift.
  # >>> head-bound rebase measure
  RH_PRE=$(cat "$BUILD/review-head" 2>/dev/null || true)
  RH_N=""
  [ -n "$RH_PRE" ] && RH_N=$(git rev-list --count "$RH_PRE".."$PREBASE" 2>/dev/null || true)
  # <<< head-bound rebase measure
  # NEVER REWRITE A PUBLISHED PARENT (BH-5234). A branch already on origin that
  # open PRs are stacked on would leave them carrying its old commits if it were
  # rebased (#5010 under #5053), and bin/lib/hold-push.sh refuses that push. So
  # it takes origin/$BASE by MERGE: the published head stays an ancestor, the
  # reviewed head too (nothing to carry — bin/lib/patch-same.sh rebinds a clean
  # main merge), and the children are not touched. Children that cannot be read
  # merge as well: a merge is always safe, a blind rebase is not.
  RB_UPDATE=rebase; RB_KIDS=""
  if [ -n "${BRANCH:-}" ] && git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
    # shellcheck source=bin/lib/stale-parent.sh
    command -v sp_open_children >/dev/null 2>&1 || . "$HARNESS/bin/lib/stale-parent.sh" 2>/dev/null
    RB_SLUG="${GH_AUTH_SLUG:-}"
    [ -n "$RB_SLUG" ] || RB_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://([^@/]*@)?github.com/)##; s#\.git$##')
    if ! command -v sp_open_children >/dev/null 2>&1; then
      RB_UPDATE=merge; RB_KIDS="unreadable: bin/lib/stale-parent.sh is not loaded"
    elif RB_KIDS=$(sp_open_children "$RB_SLUG" "$BRANCH"); then
      # shellcheck disable=SC2086 # one number a line, split on purpose
      [ -n "$RB_KIDS" ] && { RB_UPDATE=merge; RB_KIDS=$(printf '#%s ' $RB_KIDS); RB_KIDS="${RB_KIDS% }"; }
    else
      RB_UPDATE=merge; RB_KIDS="unreadable: $RB_KIDS"
    fi
  fi
  if [ "$RB_UPDATE" = merge ]; then
    RH_N=""
    echo "$(STAMP) [$PROJECT/$KEY] pre-PR update by MERGE: $BRANCH has open stacked children ($RB_KIDS) — merging origin/$BASE rather than rewriting a published parent" >> "$BUILD/pipeline.log"
    RB_ABORT=(merge --abort); RB_DID="merged origin/$BASE into $BRANCH"
  else
    RB_ABORT=(rebase --abort); RB_DID="rebased onto origin/$BASE"
  fi
  if { if [ "$RB_UPDATE" = merge ]; then git merge --no-edit "origin/$BASE"; else git rebase "origin/$BASE"; fi; } >> "$BUILD/pipeline.log" 2>&1; then
    TC_OK=1
    TC_INCONCLUSIVE=""
    TSC_FLAGS=""; [ -f tsconfig.build.json ] && TSC_FLAGS="-p tsconfig.build.json"
    if [ -f tsconfig.build.json ] || [ -f tsconfig.json ]; then
      read -r RB_HEAP RB_HEAP_SRC <<<"$(rebase_tsc_heap)"
      echo "$(STAMP) [$PROJECT/$KEY] rebase typecheck at heap ${RB_HEAP}MB (source: $RB_HEAP_SRC)" >> "$BUILD/pipeline.log"
      # BH-575: append, never clobber — a later --max-old-space-size wins in V8,
      # so whatever the build environment already asked for survives.
      NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=$RB_HEAP" \
        timeout 900 npx tsc $TSC_FLAGS --noEmit > "$BUILD/rebase-tsc.txt" 2>&1
      RB_RC=$?
      cat "$BUILD/rebase-tsc.txt" >> "$BUILD/pipeline.log"
      # BH-575: a tsc that CRASHED did not say no. `|| TC_OK=0` collapsed a V8
      # abort (>=128), a SIGKILL, a `timeout` (124) and an npx that could not
      # find tsc into "typechecks red", and the PR was parked on a sentence
      # nobody could check. Red is an exit with `error TS` diagnostics in it;
      # everything else is INCONCLUSIVE — neither green nor red, and said so.
      if [ "$RB_RC" != 0 ]; then
        TC_OK=0
        if [ "$RB_RC" = 124 ]; then
          TC_INCONCLUSIVE="tsc exit 124 (timeout 900s)"
        elif [ "$RB_RC" -ge 128 ] || ! grep -qE 'error TS[0-9]+' "$BUILD/rebase-tsc.txt"; then
          TC_INCONCLUSIVE="tsc exit $RB_RC with no diagnostics at heap ${RB_HEAP}MB"
        fi
      fi
      # Baseline-aware (2026-08-20, the #578/#579 park class): a red typecheck
      # whose every error line ALREADY exists on origin/$BASE is main's own
      # baseline, not this rebase's damage — the train learned this first;
      # its 4h-cached baseline file is reused here. No baseline cached = the
      # old strict behavior stands (fail closed).
      # An inconclusive run has no error lines to diff, so the baseline branch
      # is skipped for it (BH-575) — accepting a crash as "zero new errors"
      # would be the same false green from the other side.
      if [ "$TC_OK" = 0 ] && [ -z "$TC_INCONCLUSIVE" ]; then
        BASEF="$HARNESS/state/tsc-baseline-$PROJECT.txt"
        if [ -s "$BASEF" ] && [ "$(find "$BASEF" -mmin -240 2>/dev/null | wc -l)" -gt 0 ]; then
          NEWERR=$(grep "error TS" "$BUILD/rebase-tsc.txt" | sort -u | comm -13 "$BASEF" - | wc -l)
          if [ "$NEWERR" -eq 0 ]; then
            TC_OK=1
            echo "$(STAMP) [$PROJECT/$KEY] rebase typecheck red but zero NEW errors vs origin/$BASE baseline — accepting" >> "$BUILD/pipeline.log"
          fi
        fi
      fi
    fi
    if [ "$TC_OK" = 1 ]; then
      # Head-bound approval (SDLC item 1): a CLEAN rebase this pipeline performed
      # itself, typechecked green, carries the reviewed tree onto a newer base —
      # it is not a fix commit nobody read. Carry the approval across by the
      # reviewed head's DISTANCE from the old head: a linear rebase preserves
      # the commit count, so the commit RH_N back from the new head holds the
      # same tree the reviewer read, now on the new base. 0 = the head itself.
      # A distance that will not resolve (a rebase that dropped or squashed a
      # commit) LEAVES the file alone and the gate below re-reviews — fail
      # toward being read, never toward silence.
      # >>> head-bound rebase carry
      if [ -n "$RH_PRE" ] && [ -n "$RH_N" ]; then
        if [ "$RH_N" = 0 ]; then
          git rev-parse HEAD > "$BUILD/review-head"
        elif RH_NEW=$(git rev-parse --verify -q "HEAD~$RH_N" 2>/dev/null); then
          echo "$RH_NEW" > "$BUILD/review-head"
        else
          echo "$(STAMP) [$PROJECT/$KEY] rebase: could not map the reviewed head ${RH_PRE:0:8} (~$RH_N) across it — the head-bound gate will re-review" >> "$BUILD/pipeline.log"
        fi
      fi
      # <<< head-bound rebase carry
      echo "$(STAMP) [$PROJECT/$KEY] $RB_DID (base=$RB_MB_S main=$RB_MAIN_S) + typecheck green" >> "$BUILD/pipeline.log"
    else
      git reset --hard "$PREBASE" >> "$BUILD/pipeline.log" 2>&1
      if [ -n "$TC_INCONCLUSIVE" ]; then
        REBASE_NOTE=" | REBASE_VERIFY_INCONCLUSIVE: main moved (base=$RB_MB_S main=$RB_MAIN_S) but the rebase typecheck did not finish — $TC_INCONCLUSIVE — PR is based on the older main, rebase unverified"
        echo "$(STAMP) [$PROJECT/$KEY] rebase onto origin/$BASE typecheck INCONCLUSIVE ($TC_INCONCLUSIVE) — reset to pre-rebase head, not claiming red" >> "$BUILD/pipeline.log"
      else
        REBASE_NOTE=" | REBASE_VERIFY_FAILED: main moved (base=$RB_MB_S main=$RB_MAIN_S) and the rebase typechecks red — PR is based on the older main, needs a fix pass"
        echo "$(STAMP) [$PROJECT/$KEY] rebase onto origin/$BASE typechecked RED — reset to pre-rebase head" >> "$BUILD/pipeline.log"
      fi
    fi
  else
    git "${RB_ABORT[@]}" >> "$BUILD/pipeline.log" 2>&1 || true
    git reset --hard "$PREBASE" >> "$BUILD/pipeline.log" 2>&1 || true
    REBASE_NOTE=" | REBASE_CONFLICT vs origin/$BASE @$(git rev-parse --short "origin/$BASE") (base=$RB_MB_S main=$RB_MAIN_S) — PR will be DIRTY, needs a rebase/fix pass"
    echo "$(STAMP) [$PROJECT/$KEY] rebase onto origin/$BASE CONFLICTED — aborted, PR ships on older base" >> "$BUILD/pipeline.log"
  fi
elif [ -n "$RB_MAIN" ] && [ -z "$RB_MB" ]; then
  # BH-575: origin/$BASE resolves but shares no history with HEAD. The old test
  # read that as "main moved" and rebased; there is nothing here to rebase onto,
  # so say what is true and leave the branch alone. ($RB_MAIN empty — no ref, a
  # failed fetch — stays what it has always been: nothing happens, nothing is
  # claimed.)
  REBASE_NOTE=" | REBASE_VERIFY_INCONCLUSIVE: merge-base of origin/$BASE and HEAD is unresolvable (base=unresolved main=$RB_MAIN_S) — rebase skipped, PR ships on its original base"
  echo "$(STAMP) [$PROJECT/$KEY] merge-base of origin/$BASE and HEAD is unresolvable (main=$RB_MAIN_S) — rebase skipped, not claiming main moved" >> "$BUILD/pipeline.log"
fi
# <<< rebase verify
# >>> caller check (BH-5791)
# After #4332 merged main, bin/data-lane-apply.sh still read the old pause
# file. So, after the rebase or merge of main above (the final tree), list
# every caller of each interface this diff changes as ported or left alone,
# with a reason, in the PR body (PR_BODY_FOR prints CALLERS_SECTION). Item 13
# of prompts/lead-review-checklist.md tells the lead to check that list.
# It never fails the build and never calls RESULT: one pipeline.log line, and
# a missing lib leaves CALLERS_SECTION empty. CALLER_CHECK_MAX_LINES=0 is off.
CALLERS_SECTION=""
# shellcheck source=bin/lib/caller-check.sh
command -v cc_section >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/caller-check.sh" ] && . "$HARNESS/bin/lib/caller-check.sh" 2>/dev/null; }
if ! command -v cc_section >/dev/null 2>&1 || [ ! -x "$HARNESS/bin/caller-check.sh" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] caller check: lib missing on $(hostname) — the PR body lists no callers" >> "$BUILD/pipeline.log"
else
  cc_conf "$PROJECT"
  if [ "$CK_MAX_LINES" = 0 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] caller check: off (CALLER_CHECK_MAX_LINES=0)" >> "$BUILD/pipeline.log"
  else
    CK_BASE=$(git merge-base "origin/$BASE" HEAD 2>/dev/null)
    CK_SUM=$("$HARNESS/bin/caller-check.sh" --repo . --base "${CK_BASE:-unresolved}" --head HEAD \
      --plan "$BUILD/plan.md" --out "$BUILD/callers.txt" 2>>"$BUILD/pipeline.log"); CK_RC=$?
    CALLERS_SECTION=$(cc_section "$BUILD/callers.txt" "$CK_MAX_LINES")
    echo "$(STAMP) [$PROJECT/$KEY] caller check: ${CK_SUM:-no summary} (rc=$CK_RC${CK_CONF_WARN:+, $CK_CONF_WARN})" >> "$BUILD/pipeline.log"
  fi
fi
# <<< caller check (BH-5791)
STAGE_END rebase "$T_REBASE"
# <<< pre-pr rebase

# >>> prepr late
# --- PRE-PR GATE, LATE PASS (BH-2021) ------------------------------------------
# The prepr gate above runs before the review fix rounds and the pre-PR rebase,
# and both can still move the head: #1983's raw rm came in with a review fix
# round and its sigpipe-negative hit with main's newer lint on the rebase. So
# the same gate runs again on the head that is pushed and opened as the PR,
# skipped when that head is the one already judged. The fix turn is shared with
# the first pass; a late fix commit is drift the head-bound gate re-reviews.
# No lib on the box: the first block already logged it, and this is a no-op.
command -v prepr_gate_late >/dev/null 2>&1 && prepr_gate_late . "$BASE" "$BUILD"
# <<< prepr late

# >>> rules pack block
# BH-3513: a rules pack still red after the prepr fix turn stops here, including one
# that went red on the late pass, before the tier/size/migration gates and PR create.
command -v rules_pack_block >/dev/null 2>&1 && rules_pack_block pr
# <<< rules pack block

# --- Tier classification: mechanical gate AND Fable's judgment must both say tier-1 ---
# MEASURED, 2026-09-14, before anything here was touched: bin/size-scope.sh
# --diff on a real project-5 tree is 0.16s, bin/size-threshold.sh 0.007s and
# bin/scope-gate.sh 0.002s. The "~10 minutes of post-review size/scope work"
# is therefore not size or scope work, and backgrounding a 0.16s measurement
# would have bought nothing while putting a git read next to the rebase above.
# So this window is INSTRUMENTED rather than reordered: the STAGE-TIMING lines
# through to the settle name which stage actually holds those minutes, and the
# next pass aims at that instead of at the two scripts whose names were nearest.
T_TIER=$(STAGE_START)
TIER=1
CHANGED=$(git diff --name-only "$BASE"...HEAD)
# Here-string, not `echo | grep -q`: under pipefail the pipeline is 141 when
# grep matches early and the producer still has bytes to write, so a big diff
# that DID touch schema/auth stayed TIER=1 and auto-merged (BH-806).
PAT='schema\.prisma|prisma/schema/.+\.prisma$|migrations?/|\.sql$|middleware|auth|permission|role|billing|stripe|invoice|payment|payout|\.github/workflows|\.env|vercel\.json|cron'
grep -qiE "$PAT" <<<"$CHANGED" && TIER=2
# WHICH pattern matched, for the console's one-line reason. Captured beside the
# boolean above rather than folded into it: the tier decision must keep reading
# off exactly the expression it always did.
# Two statements, not `grep -oiE ... | head -1`: head exits at the first line
# and the producing grep dies of SIGPIPE, the same early-exit pipeline this
# ticket is auditing. `%%$'\n'*` takes the first match of the capture, which
# is exactly what head -1 printed.
TIER_HITS=$(grep -oiE "$PAT" <<<"$CHANGED"); TIER_HIT=${TIER_HITS%%$'\n'*}
# >>> diff size note
# THE RAW DIFF SIZE IS A REPORT, NOT A TIER (BH-5292, the operator 2026-10-07). This
# used to force tier 2 past 400 changed lines: a line count is not itself harmful, and
# what IS risky (auth, billing, schema, workflows, env) is the path rule above,
# which still decides. Since BH-4572 the tier gates nothing unless
# tier_gate_mode says `human`, but it still picks who merges a tier-1 APPROVE
# here and what the console reads, so the line is GONE, not left inert: the
# size now rides the PR as a note ("large diff: N lines", the RESULT/evidence
# channel below) and the console's tier event as a metric. The spec artifact
# is excluded: a 200-line plan.md is not 200 lines of blast radius — the same
# "spec text is not code" rule the review prompt and the merge sweep's
# added-line scan follow.
DELTA=$(git diff --shortstat "$BASE"...HEAD -- . ':(exclude).harness/specs' | grep -oE '[0-9]+ (insertion|deletion)' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
DIFF_NOTE=""
case "${DELTA:-}" in ''|*[!0-9]*) ;; *)
  if [ "$DELTA" -gt 400 ]; then
    DIFF_NOTE=" | large diff: $DELTA lines (a note, not a tier)"
    echo "$(STAMP) [$PROJECT/$KEY] DIFF: large diff: $DELTA lines changed (reported, no tier change)" >> "$BUILD/pipeline.log"
  fi ;;
esac
# <<< diff size note
# >>> live emit tier
type LIVE >/dev/null 2>&1 && LIVE tier "$TIER" \
  "tier $TIER: ${TIER_HIT:+touches $TIER_HIT; }${DELTA:-?} line(s) changed"
# <<< live emit tier
# >>> size posthoc
# --- What actually shipped, measured (2026-09-12) ----------------------------
# The size gate at PLAN time judges an ESTIMATE. This judges the fact. By the
# time it can, the code is written — so this one NEVER BLOCKS: refusing a PR
# here would strand finished work on a branch nobody merges, and the estimate
# being wrong is a planning finding, not a reason to throw the diff away.
#
# 2x the threshold is the line. Slightly over is an estimate being an estimate;
# at twice the decomposition threshold the plan was not optimistic, it was wrong
# about what the ticket was — and the reviewer is about to read a diff nobody
# sized. Measured in PRODUCT lines through the same bin/size-scope.sh the plan
# gate used, so "600 product lines" means the same thing on both sides.
#
# THE NOTE IS NOT GUARDED BY THE FLAG, only the demotion is — the rule the scope
# gate already follows. A reviewer facing a 1,400-line PR has to be told it is a
# 1,400-line PR whether or not the fleet is enforcing anything.
#
# Since BH-5292 the raw-delta heuristic above no longer demotes anything, so
# this is the only size-based demotion left, and only while size enforcement
# is armed. It names the reason — "1,412 product lines, over 2x the line
# threshold" — and it is the row that makes the estimate-versus-reality gap
# visible at all.
SIZE_NOTE=""
SP_LIMITS=$("$HARNESS/bin/size-threshold.sh" "$PROJECT" 2>/dev/null)
SP_MAXL=$(printf '%s' "$SP_LIMITS" | awk '{print $1}')
case "${SP_MAXL:-}" in ''|*[!0-9]*) SP_MAXL=700 ;; esac
SP_BOUND=$(( SP_MAXL * 2 ))
SP_OUT=$("$HARNESS/bin/size-scope.sh" --diff "$BASE" . 2>/dev/null)
SP_LINES=$(sed -n 's/^SIZE_PRODUCT_LINES:[[:space:]]*//p' <<<"$SP_OUT" | tail -1)
SP_FILES=$(sed -n 's/^SIZE_PRODUCT_FILES:[[:space:]]*//p' <<<"$SP_OUT" | tail -1)
case "${SP_LINES:-}" in ''|*[!0-9]*) SP_LINES="" ;; esac
case "${SP_FILES:-}" in ''|*[!0-9]*) SP_FILES="?" ;; esac
# An unmeasurable diff demotes NOTHING. An unreadable diff is not a small diff,
# and it is not a large one either — and a demotion nobody can point at a number
# for is a demotion a reviewer cannot act on.
if [ -z "$SP_LINES" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] SIZE: the shipped diff could not be measured against $BASE — no size note on this PR" >> "$BUILD/pipeline.log"
elif [ "$SP_LINES" -gt "$SP_BOUND" ]; then
  # Read exactly as the plan-time gate reads it — one switch, one spelling of
  # "on", now literally one implementation (`# >>> size enforce switch`), which
  # is what keeps the flag, the per-project override and the armed default from
  # meaning one thing at plan time and another in the PR body. This block is
  # extracted and driven on its own by tests/size-gate-test.sh, so it CALLS the
  # resolver rather than carrying a variable down from a block a resumed build
  # may not have run; the call is memoized, so this costs nothing.
  SG_SWITCH_RESOLVE
  SP_ENFORCE="$SG_ENFORCE"
  if [ "$SP_ENFORCE" = 1 ]; then
    if [ "$TIER" = "1" ]; then
      TIER=2; SIZE_NOTE=" | SIZE: $SP_LINES product lines across $SP_FILES file(s) — over 2x the $SP_MAXL-line threshold ($SP_BOUND) — recorded tier-2 (risk signal)"
    else
      SIZE_NOTE=" | SIZE: $SP_LINES product lines across $SP_FILES file(s) — over 2x the $SP_MAXL-line threshold ($SP_BOUND) — already tier-$TIER"
    fi
  else
    SIZE_NOTE=" | SIZE: $SP_LINES product lines across $SP_FILES file(s) — over 2x the $SP_MAXL-line threshold ($SP_BOUND), tier-2 eligible (size enforcement OFF via $SG_SWITCH_SRC, warn only)"
  fi
  echo "$(STAMP) [$PROJECT/$KEY] SIZE: shipped $SP_LINES product lines in $SP_FILES file(s), over 2x the $SP_MAXL-line threshold — the plan's estimate was wrong about this ticket" >> "$BUILD/pipeline.log"
else
  echo "$(STAMP) [$PROJECT/$KEY] SIZE: shipped $SP_LINES product lines in $SP_FILES file(s) (bound $SP_BOUND)" >> "$BUILD/pipeline.log"
fi
# <<< size posthoc
tail -2 "$BUILD/review.md" | grep -q 'TIER: 1' || TIER=2
# Judge provenance (2026-08-03): tier-1 needs its verdicts authored by the PRIMARY
# review lane (Fable on claude). A review served by a fallback/survival runner still
# gates the build, but its APPROVE never auto-merges — the judge node is the one
# place a cheaper lane costs everything.
for RM in "$BUILD"/review-run.txt.runner "$BUILD"/review2-run.txt.runner "$BUILD"/security-review-run.txt.runner "$BUILD"/security-review2-run.txt.runner "$BUILD"/refute-review-run.txt.runner "$BUILD"/refute-review2-run.txt.runner; do
  [ -f "$RM" ] || continue
  # The PAIR, not the runner word (2026-09-16): the tier-3 lane runs the stage's
  # own Claude model through OpenRouter, and a Claude read is a Claude read
  # whichever CLI carried it. Everything else demotes exactly as before.
  rp_out_is_claude "${RM%.runner}" && continue
  echo "$(STAMP) [$PROJECT/$KEY] review served by $(rp_out_label "${RM%.runner}") — demoted to tier 2 (judge provenance)" >> "$BUILD/pipeline.log"; TIER=2
done
# >>> automerge pause
# BH-1285: the tier-1 merge below is a box-side merge writer too, so it honours
# the console pause rows (flag_active) and the project pause.
# Demoted to tier 2 it lands only through bin/merge-queue.sh, which holds both.
# automerge-disabled-<project> is the Project page toggle (#2322). Since
# BH-4153 these are harness_flags rows read by flag_active, and an unreadable
# one is ON (fails closed); the file is read only when no client is loaded.
for RB_PF in automerge-disabled "automerge-disabled-$PROJECT" "paused-$PROJECT"; do
  if { command -v flag_active >/dev/null 2>&1 && flag_active "$RB_PF" >/dev/null 2>&1; } \
     || { ! command -v flag_active >/dev/null 2>&1 && [ -f "$HARNESS/flags/$RB_PF" ]; }; then
    [ "$TIER" = "1" ] && echo "$(STAMP) [$PROJECT/$KEY] $RB_PF is on — tier-1 merge held, demoted to tier 2" >> "$BUILD/pipeline.log"
    TIER=2
  fi
done
# <<< automerge pause

# >>> migration gate
# --- GATE: migration appliability (2026-08-14) --------------------------------
# New scripts/migrations/*.sql get a mechanical statement lint BEFORE the PR:
# SQL outside the conservative endpoint-appliable allowlist (DO blocks,
# functions/triggers, destructive statements, GRANTs...) forces tier 2 and a
# MIGRATION GATE section in the PR body, so a human sees the SQL before merge.
# Never blocks the PR — TK-90's DO-guarded migration stalled ~8h at APPLY time
# because nothing checked appliability at BUILD time, and TK-64's finance
# tables sat unapplied for days while deployed code threw on every load.
#
# What is REPORTED is wider than what is LINTED (BH-1355). The lint's input is
# still added scripts/migrations/*.sql — that set is the app's own
# /api/internal/migrations allowlist — but a Prisma migration is schema too, and
# the gate used to answer `none` on a PR that shipped one (project-5 #3082).
# bin/lib/migration-files.sh owns both queries and the reasons they differ.
MIG_NOTE=""; MIG_SECTION=""; MIG_FILES=""; ADDED_SQL=""
[ -r "$HARNESS/bin/lib/migration-files.sh" ] && . "$HARNESS/bin/lib/migration-files.sh"
if type migration_files_changed >/dev/null 2>&1; then
  MIG_FILES=$(migration_files_changed "$BASE" "$WT")
  ADDED_SQL=$(migration_sql_added "$BASE" "$WT")
fi
if [ -n "$MIG_FILES" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] MIGRATION GATE: $(printf '%s\n' "$MIG_FILES" | grep -c .) migration file(s) in diff: $(printf '%s\n' "$MIG_FILES" | tr '\n' ' ' | sed 's/ *$//')" >> "$BUILD/pipeline.log"
fi
if [ -n "$ADDED_SQL" ] && ! "$HARNESS/bin/check-migration-appliable.sh" "$PROJECT" "$WT" $ADDED_SQL > "$BUILD/migration-gate.txt" 2>&1; then
  TIER=2
  NFLAG=$(grep -c 'FLAGGED' "$BUILD/migration-gate.txt" 2>/dev/null || echo "?")
  MIG_NOTE=" | MIGRATION GATE: $NFLAG statement(s) outside the appliable allowlist — tier 2"
  MIG_SECTION=$(printf '\n\nMIGRATION GATE: this PR ships migration SQL outside the endpoint-appliable allowlist — the apply needs the app'"'"'s own /api/internal/migrations endpoint (orchestrator judged apply, after the deploy serves), because no box holds production DB credentials. The merge is forced tier 2 for the same reason.\n\n```\n%s\n```' "$(head -c 1500 "$BUILD/migration-gate.txt")")
  echo "$(STAMP) [$PROJECT/$KEY] MIGRATION GATE: $NFLAG flagged statement(s) — forced tier 2" >> "$BUILD/pipeline.log"
fi
# <<< migration gate

STAGE_END tier "$T_TIER"

# --- The judgement, recorded where it is MADE (BH-858) ------------------------
# Both facts the verdict row carries exist HERE: the word settled at the review
# stage, the tier four lines up. The only write used to be 500 lines down behind
# `[ -n "$PR_URL" ]`, so a build whose `gh pr create` died wrote PR_CREATE_FAILED
# and no verdict at all — a reviewer had read the diff and answered, and the
# answer was thrown away.
#
# PROVISIONAL, and that is the whole design: every demoter after this point (QA,
# E2E, red/VALIDATE, reopen-trust, repairs, scope, kind, head-bound) can still
# change the tier, so this row says `settled:false` and the merge readers treat
# it as "the ledger has nothing to say" until the block below settles it.
# docs/verification-map/verdict-ledger.md carries the reader table.
#
# STANDALONE ON PURPOSE: the word and the provenance are computed here rather
# than through a shared helper, because the suites extract each marked block and
# run it under `bash` on its own — a helper defined outside the markers would
# break every one of them.
# >>> verdict at review
if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  VERDICT_WORD=BLOCK
  # The shared reader (bin/lib/verdict-parse.sh, BH-1625): an anchored VERDICT
  # line in the final block, or BLOCK — including when the reader is missing.
  verdict_is APPROVE -L "$BUILD/review.md" 2>/dev/null && VERDICT_WORD=APPROVE
  # Provenance by the SAME rule the tier gate above applies: a Claude word only
  # when every review lane that ran was a Claude one.
  VERDICT_PROV=claude
  for _PRM in "$BUILD"/review-run.txt.runner "$BUILD"/review2-run.txt.runner \
              "$BUILD"/security-review-run.txt.runner "$BUILD"/security-review2-run.txt.runner \
              "$BUILD"/refute-review-run.txt.runner "$BUILD"/refute-review2-run.txt.runner; do
    [ -f "$_PRM" ] || continue
    rp_out_is_claude "${_PRM%.runner}" && continue
    VERDICT_PROV=$(rp_out_prov "${_PRM%.runner}"); break
  done
  # Empty is OMITTED, never written as "": a blank sha reads as a claim about the
  # head, and every reader downstream fails open on absence.
  VERDICT_RSHA=$(cat "$BUILD/review-head" 2>/dev/null || true)
  if job_artifact_put verdict "$VERDICT_WORD" \
      "$(jq -nc --arg t "$TIER" --arg p "$VERDICT_PROV" --arg r "$(basename "$BUILD")" \
          --arg s "$VERDICT_RSHA" \
          '{tier:$t,provenance:$p,record:$r,settled:false}
           + (if $s == "" then {} else {reviewed_sha:$s} end)' 2>/dev/null)" >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT/$KEY] VERDICT: $VERDICT_WORD recorded provisionally (tier $TIER, provenance $VERDICT_PROV, reviewed sha ${VERDICT_RSHA:-none}) — the judgement is in the ledger before the PR exists" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] VERDICT: the provisional row was not written (job_artifact_put failed) — the settle write after the PR is the only copy" >> "$BUILD/pipeline.log"
  fi
  # BH-1026.2: THE TIER-2 HAND-OFF, AT THE MOMENT THE JUDGEMENT IS MADE. This
  # replaces the retired tier-2 merge sweep, which ran six times an hour on eight
  # boxes re-grepping builds/ for a VERDICT this process already holds in a
  # variable, and which is retired in the same change.
  #
  # THE GATE IS $VERDICT_WORD, never a grep over review.md. Four prompt bodies
  # in this file carry the literal sentence `Last line exactly VERDICT: APPROVE
  # or VERDICT: BLOCK`, so a text match enqueues blocked builds.
  #
  # TIER 1 IS EXCLUDED. This process merges a tier-1 PR itself further down and
  # its failure arm already enqueues; a row on a PR we are about to self-merge
  # is recorded by bin/merge-queue.sh as `dropped` — a PR that landed, written
  # into the ledger as not landed.
  #
  # NOTHING IS SILENT. The sweep used to be the retry and it is gone, so a
  # refused row falls back to the file this queue has always read and names the
  # PR in ALERTS either way.
  if [ "$VERDICT_WORD" = APPROVE ] && [ "${TIER:-}" != 1 ] \
     && command -v merge_queue_put >/dev/null 2>&1; then
    MQ_COM=0
    if command -v flag_active >/dev/null 2>&1 && flag_active conductor-owns-merges \
       || [ -f "$HARNESS/flags/conductor-owns-merges" ]; then MQ_COM=1; fi
    MQ_PRNUM=$(grep -oE '[0-9]+$' <<<"${PR_URL:-}")
    # THE LEAD FENCE (BH-1606): a LEAD PR goes on the box queue only on a lead/
    # human MERGE row standing on its live head — this build's APPROVE is never
    # that. to_lane_lead_hold reads the PR's author and live head itself and has
    # logged the one MERGE_HELD line. An UNREADABLE fence (rc 2) still enqueues:
    # bin/merge-queue.sh asks the same fence at landing and holds the entry
    # there, while skipping the enqueue would cost a pool PR its only hand-off
    # whenever the worker is down (the file fallback below exists for that).
    MQ_LEAD=1
    if [ "$MQ_COM" != 1 ] && [ -n "$MQ_PRNUM" ] && [ "${MQ_ENQUEUED:-}" != "$MQ_PRNUM" ] \
       && command -v to_lane_lead_hold >/dev/null 2>&1; then
      to_lane_lead_hold "$PROJECT" "${SLUG:-}" "$MQ_PRNUM" "" "" "$BUILD/pipeline.log"; MQ_LEAD=$?
      [ "$MQ_LEAD" = 2 ] && echo "$(STAMP) [$PROJECT/$KEY] the lead fence could not be read for #$MQ_PRNUM — enqueued anyway: bin/merge-queue.sh asks it again at landing and holds the entry there" >> "$BUILD/pipeline.log"
    fi
    # THE TIER GATE (BH-4572): the tier decides nothing unless the operator row
    # tier_gate_mode[.<project>] says `human`; an unreadable row holds and pages
    # (bin/lib/tier-gate.sh). Loaded here because the suites run this block on
    # its own. A tree without the lib enqueues as before, and says so.
    command -v tg_holds >/dev/null 2>&1 \
      || { [ -r "$HARNESS/bin/lib/tier-gate.sh" ] && . "$HARNESS/bin/lib/tier-gate.sh"; }
    MQ_TG=1
    if [ "$MQ_COM" != 1 ] && [ -n "$MQ_PRNUM" ] && [ "${MQ_ENQUEUED:-}" != "$MQ_PRNUM" ]; then
      if command -v tg_holds >/dev/null 2>&1; then
        tg_holds "$PROJECT" "$TIER"; MQ_TG=$?
      else
        echo "$(STAMP) [$PROJECT/$KEY] tier gate lib not loaded — enqueued as before" >> "$BUILD/pipeline.log"
      fi
    fi
    if [ "$MQ_COM" = 1 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] APPROVE not enqueued: flags/conductor-owns-merges is on — bin/merge-conductor.sh owns merges" >> "$BUILD/pipeline.log"
    elif [ -z "$MQ_PRNUM" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] APPROVE with no PR number yet — the settle block's enqueue covers it once the PR is open" >> "$BUILD/pipeline.log"
    elif [ "${MQ_ENQUEUED:-}" = "$MQ_PRNUM" ]; then
      :
    elif [ "$MQ_LEAD" = 0 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] APPROVE not enqueued: #$MQ_PRNUM is a lead PR with no lead MERGE verdict on its head — left for the lead" >> "$BUILD/pipeline.log"
    elif [ "$MQ_TG" = 0 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] APPROVE not enqueued: tier_gate_mode=${TG_MODE:-unreadable} (${TG_MODE_SRC:-unreadable}) holds tier $TIER" >> "$BUILD/pipeline.log"
    elif merge_queue_put "$PROJECT" "$MQ_PRNUM" "${SLUG:-}" "tier-$TIER APPROVE from $KEY" >/dev/null 2>&1; then
      MQ_ENQUEUED="$MQ_PRNUM"
      echo "$(STAMP) [$PROJECT/$KEY] APPROVE enqueued #$MQ_PRNUM on the merge queue" >> "$BUILD/pipeline.log"
    else
      if [ -z "${BUILDER_NO_MERGE:-}" ]; then
        mkdir -p "$HARNESS/state/merge-queue/$PROJECT"
        touch "$HARNESS/state/merge-queue/$PROJECT/$MQ_PRNUM"
        MQ_ENQUEUED="$MQ_PRNUM"
        echo "$(STAMP) [$PROJECT/$KEY] the merge_queue row was refused — wrote state/merge-queue/$PROJECT/$MQ_PRNUM instead" >> "$BUILD/pipeline.log"
      fi
      echo "$(STAMP) [merge-queue] $PROJECT #$MQ_PRNUM: the merge_queue row was refused at the APPROVE verdict (worker unreachable). Nothing re-offers this PR — the tier-2 sweep is retired: https://github.com/${SLUG:-unknown}/pull/$MQ_PRNUM" >> "$HARNESS/logs/ALERTS.log"
    fi
  fi
fi
# <<< verdict at review

T_PR=$(STAGE_START)
echo "$(STAMP) [$PROJECT/$KEY] PR (tier $TIER)" >> "$BUILD/pipeline.log"
# Push must succeed before a PR can exist — and a rejected push must be LOUD:
# --quiet swallowed rejections and the build sailed on to a PR_CREATED with an
# empty URL (the TK-122/TK-223 class). One retry for transient weather, then
# defer honestly so the watcher requeues.
# --force-with-lease, since 2026-08-29: the E2E smoke stage above pushes this
# branch before review so Vercel has something to build a preview from, and the
# pre-PR rebase then REWRITES those commits. A plain push is a non-fast-forward
# at that point and would be rejected, deferring the build with no PR — which is
# the bug the e2e push would otherwise have introduced on every UI build where
# main moved mid-build. The lease keeps the safety that matters: this branch is
# created and written by this pipeline alone, so the only thing a lease failure
# can mean is that something else touched it, and that still lands in the
# REJECTED path below rather than clobbering someone's work.
# THE TOKEN IS RE-READ HERE, not inherited from minute zero: this is the push the
# 2026-09-14 incident rejected, and the retry below re-reads it again because ten
# seconds is exactly long enough for a rotation to have landed.
# >>> pre-pr squash (tests/run-build-checkpoint.bh-1319-test.sh drives this block)
# Last call on tidying: normally a no-op, because the execute stage already
# squashed its own checkpoints. It matters for the build that took a fix round
# on a checkpoint-resumed branch, where the wip commits outlived that squash.
# A refusal here is recorded as the failed step (where=pr) and the push goes
# ahead with the wip commits — never fatal, docs/CHECKPOINTS.md.
CKPT_SQUASH_WIP || CKPT_SQUASH_REFUSED pr
# <<< pre-pr squash
# >>> pr push
# The rejected line names the head this build made: the pool reap compares it
# with the remote branch, and a push that did land gets its PR from the hub.
GH_LIVE
{ RB_PUSH -u pr-push && track_pushed; } || { sleep 10; GH_LIVE; RB_PUSH -u pr-push && track_pushed; } || {
  RB_BUILT_SHA=$(git rev-parse HEAD 2>/dev/null) || RB_BUILT_SHA=""
  echo "$(STAMP) [$PROJECT/$KEY] the push of $BRANCH at ${RB_BUILT_SHA:-an unreadable head} was REJECTED (a HOLD on the ticket, an unreadable hold, or the lease) — deferring, no PR claimed" >> "$BUILD/pipeline.log"
  RESULT "BUILD_DEFERRED push of $BRANCH rejected${RB_BUILT_SHA:+ at $RB_BUILT_SHA}"; exit 3
}
# <<< pr push
# What/why for humans (the operator 2026-08-24: the body showed only models+cost —
# our own rule says what/why + verify evidence). Deterministic, no model call:
# the commit subjects are the WHAT, the plan's opening section is the WHY,
# validate.txt's size/presence is the verify pointer.
# `git log -12`, not `| head -12`: one line per commit, so -N IS the truncation,
# and head on a git pipe is a SIGPIPE race under pipefail (BH-1248).
# >>> pr what list (tests/run-build-pr-title.bh-1415-test.sh drives this block)
# THE BASE IS THE REMOTE REF, AND THE CUT IS THE MERGE BASE (BH-1415). `$BASE`
# is the LOCAL ref, which is fast-forwarded once at build start and never again,
# while the pre-PR block above rebases this branch onto **origin/$BASE**. After
# that rebase `$BASE..HEAD` lists everything main gained since the local ref last
# moved — so the 2026-09-22 wave's bodies listed `merge train: 1 approved PRs
# (#1362)`, `train: #1360` and other tickets' commits as this branch's work.
# origin/$BASE is resolved exactly as SCOPE_BASE resolves it above, and an
# unresolvable merge base falls back to the ref itself: today's behaviour, never
# an empty What.
WHAT_BASE="$BASE"
git rev-parse -q --verify "origin/$BASE" >/dev/null 2>&1 && WHAT_BASE="origin/$BASE"
WHAT_MB=$(git merge-base "$WHAT_BASE" HEAD 2>/dev/null)
[ -n "$WHAT_MB" ] || WHAT_MB="$WHAT_BASE"
# The spec commit is this pipeline's own artifact (`# >>> spec artifact` above),
# committed after execute. It is never the WHAT of the ticket.
WHAT_LIST=$(git log -12 --format='- %s' "$WHAT_MB..HEAD" \
  | grep -vxF -- "- spec($KEY): the plan this build was executed from")
# A bash regex on the variable, not `grep -q` on a pipe: grep closing a git pipe
# early answers 141 under pipefail and the warning would be swallowed. The
# subject is KEPT either way — a branch may legitimately carry one — and the
# line is what says the base resolution needs a look.
if [[ "$WHAT_LIST" =~ (^|$'\n')-\ (merge\ )?train: ]]; then
  echo "$(STAMP) [$PROJECT/$KEY] PR What list still carries a main-train subject after $WHAT_MB..HEAD — the base resolution is wrong" >> "$BUILD/pipeline.log"
fi
# <<< pr what list
WHY_EXCERPT=$(awk 'NR==1{next} /^## /{exit} {print}' "$BUILD/plan.md" 2>/dev/null | grep -v '^$' | head -8 | head -c 900)
VERIFY_LINE="Verification evidence: validate.txt ($(stat -c %s "$BUILD/validate.txt" 2>/dev/null || echo 0)B), red.txt ($(stat -c %s "$BUILD/red.txt" 2>/dev/null || echo 0)B), review.md on the build box ($(basename "$BUILD"))."
# >>> merge note fn
# A function because the body is rendered TWICE (SDLC item 2): once here, and
# once after the tier settles. A second copy of the sentence would let the two
# renders disagree about how this PR merges.
MERGE_NOTE_FOR() { # MERGE_NOTE_FOR <tier>
  if [ -n "${STACK_ON:-}" ]; then
    printf 'Tier %s, STACKED — NOT merged from here at any tier: the base is a feature branch. The merge conductor picks it up once GitHub retargets it to `%s`.' "$1" "${BASE_MAIN:-main}"
  elif [ "$1" = "1" ]; then
    printf 'Tier 1 (low-risk class) — auto-merging per standing policy.'
  else
    printf 'Tier 2 — risk class recorded; lands through the merge queue on the same gates as tier 1 (migration-gated PRs via the orchestrator'"'"'s judged apply).'
  fi
}
MERGE_NOTE=$(MERGE_NOTE_FOR "$TIER")
# <<< merge note fn
# The build's own bill, computed from the rows agent-call teed into this dir.
COST_LINE=""
if [ -f "$BUILD/cost.csv" ]; then
  # $13 is cost_usd. It was $NF until 2026-09-14, when the row grew session_id/
  # row_source/result_usd and the attribution tags and $NF became run_id.
  COST_LINE=$(awk -F, 'NR>1 {s[$4]+=$13; t+=$13; ti+=$9; to+=$10; cr+=$11; cw+=$12} END {if (t>0) {printf "AI cost to PR: $%.2f (", t; sep=""; for (k in s) {printf "%s%s $%.2f", sep, k, s[k]; sep=", "}; printf ") — tokens: %.0fk in / %.0fk out (cache %.1fM read, %.1fM write)", ti/1000, to/1000, cr/1000000, cw/1000000}}' "$BUILD/cost.csv" 2>/dev/null)
fi
# BH-6392: psc_test_change_section, the `## Test changes` lines PR_BODY_FOR
# prints. A missing lib leaves the body as it was.
# shellcheck source=bin/lib/pr-self-check.sh
command -v psc_test_change_section >/dev/null 2>&1 || { [ -r "$HARNESS/bin/lib/pr-self-check.sh" ] && . "$HARNESS/bin/lib/pr-self-check.sh" 2>/dev/null; }
# >>> evidence block
# --- The evidence a human merges on (SDLC item 2) ----------------------------
# The verification section of this body used to be "validate.txt (4812B)" — a
# byte count of a file only the build box can open. the operator merges tier-2 PRs from
# the PR page, so the harness was asking for trust in checks it never showed,
# which is the claim-discipline rule it enforces on every agent it runs.
#
# bin/evidence-summary.sh renders the block deterministically from files this
# pipeline already wrote — no model call, no extra cost. Two things have to be
# handed to it first, because they are the only facts that live in variables
# rather than in a file:
#   gates.json         each mechanical gate's OWN verdict (the rc it returned,
#                      the e2e word, the migration state), so the renderer maps
#                      one vocabulary instead of re-deriving five gates' output
#   changed-files.txt  this diff's file list, for planned-vs-actual
# Both are written unconditionally: a build that dies later still leaves a
# record an operator can render the same block from.
#
# Kill switch: EVIDENCE_BLOCK=0 (default 1) drops the block from the body, the
# artifact and evidence.md — everything else about the PR is byte-identical.
printf '%s\n' "$CHANGED" > "$BUILD/changed-files.txt"
# >>> gates json
# Four words, widest first, each overriding the last. `present` (BH-1355) is
# migration-shaped files in the diff that NOTHING linted — a Prisma migration,
# which the classifier's allowlist was never written against. It is a separate
# word from `clean` on purpose: `clean` means the classifier passed, and saying
# that about SQL nothing judged would be the second lie on the same row.
EVID_MIG=none
[ -n "${MIG_FILES:-}" ] && EVID_MIG=present
[ -n "${ADDED_SQL:-}" ] && EVID_MIG=clean
# A non-zero exit from check-migration-appliable.sh is not always a verdict: the
# classifier can also crash, and MIG_NOTE then reads "? statement(s)". Calling
# that `flagged` would tell the PR page that statements sat outside the
# allowlist when nothing ever judged them.
[ -n "${MIG_NOTE:-}" ] && { grep -q FLAGGED "$BUILD/migration-gate.txt" 2>/dev/null \
  && EVID_MIG=flagged || EVID_MIG=gate-failed; }
jq -nc --arg t "${TAMPER_RC:-}" --arg r "${REPRO_RC:-}" --arg i "${INTENT_RC:-}" \
       --arg e "${E2E_VERDICT:-not-run}" --arg m "$EVID_MIG" --arg mf "${MIG_FILES:-}" \
  '{tamper:$t,repro:$r,intent:$i,e2e:$e,migration:$m,
    migration_files:($mf|split("\n")|map(select(.!="")))}' > "$BUILD/gates.json" 2>/dev/null || true
# <<< gates json
EVIDENCE=""
if [ "${EVIDENCE_BLOCK:-1}" = 1 ]; then
  # At PR-open time the tier is NOT settled — QA, the E2E demoter, the red/
  # VALIDATE demoters and the head-bound gate all run after this point. Saying
  # so is the honest render; the settle pass below replaces it with the real one.
  EVIDENCE=$("$HARNESS/bin/evidence-summary.sh" "$BUILD" "$TIER" \
    "QA and the tier demoters run after this PR opens" provisional 2>/dev/null || true)
fi
# A blank line on BOTH sides, built WITHOUT a command substitution: $() strips
# the trailing newline, and markdown would then run the attribution footer
# straight onto the digest line.
EVIDENCE_SECTION=""
[ -n "$EVIDENCE" ] && EVIDENCE_SECTION=$'\n'"$EVIDENCE"$'\n'
# >>> evidence head (BH-5798)
# THE EVIDENCE NAMES THE HEAD IT RAN ON. bin/pr-self-check.sh (evidence-head)
# refuses a body whose evidence sha is not the head, or an ancestor the PR's
# files moved past: 15 review BLOCKs read a body about an older head.
if [ -n "$EVIDENCE_SECTION" ]; then
  _EV_HEAD=$(git rev-parse HEAD 2>/dev/null) || _EV_HEAD=""
  [ -n "$_EV_HEAD" ] && EVIDENCE_SECTION="${EVIDENCE_SECTION}<!-- evidence-head: $_EV_HEAD -->"$'\n'
fi
# <<< evidence head
# The sentence this item was filed to delete. Its numbers are now rows in the
# block (red.txt bytes, validate.txt bytes and its NOT RUN count), and the block
# names the record, so repeating them here is the byte count outliving its
# replacement. It stays as the fallback for a body rendered with the block
# switched off, where it is still the only pointer to the evidence files.
[ -n "$EVIDENCE" ] && VERIFY_LINE="Verification evidence: the Evidence block below, rendered from this build's own files (the adversarial review is \`review.md\` in that record on the build box)."
# Issue-driven projects (fleet.conf board prefix "-"): a "Closes #n" line in
# the body, so a merge closes the issue and the box's issue-fingerprint gate
# sees it move (2026-09-12: hand-merged project-5 PRs left their issues open
# all day and the tick answered "gate no-change" from 06:21Z to 14:49Z). The
# number is the KEY's (<PREFIX>-<n>). Board projects get no line. Fail-open:
# no fleet-conf.sh, no numeric key, no line — the body is byte-identical.
CLOSES_LINE=""
if [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  _CL_ISSUE=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  [ -n "$_CL_ISSUE" ] && CLOSES_LINE="Closes #$_CL_ISSUE"
fi
# >>> partial build refs (BH-5798)
# A PARTIAL BUILD NEVER CLOSES ITS ISSUE. When the scored evidence
# (bin/lib/evidence.sh, $BUILD/evidence.json) has a REFUTED acceptance claim,
# the line says `Refs #n` and the body lists what is not met, so a merge leaves
# the issue open for the rest (11 review BLOCKs: "Closes" on a partial build).
# INCONCLUSIVE is not REFUTED and keeps Closes. No file, no jq: unchanged.
NOTMET_SECTION=""
if [ -n "$CLOSES_LINE" ] && [ -r "${BUILD:-}/evidence.json" ] && command -v jq >/dev/null 2>&1; then
  _NOTMET=$(jq -r '[.claims[]? | select(.verdict == "REFUTED")
      | "- [ ] claim \(.n): \(.claim // "" | .[0:200]) (not met: REFUTED\(if (.note // "") != "" then ", " + .note else "" end))"] | .[]' \
      "$BUILD/evidence.json" 2>/dev/null)
  if [ -n "$_NOTMET" ]; then
    CLOSES_LINE="Refs #${CLOSES_LINE#Closes #}"
    NOTMET_SECTION=$(printf '\n## Acceptance self-check\n\nNot every acceptance item is met, so this PR says Refs, not Closes, and a merge leaves the issue open. Not met:\n%s\n' "$_NOTMET")
  fi
fi
# <<< partial build refs
# >>> needs-human pr section
# BH-3433 (BH-3442): the needs-human release section for an issues board's PR
# body — empty until the release slice lands, so the body is byte-identical.
# Fail-open: sourced here only when review.sh's seam did not already load it.
command -v nh_pr_body_section >/dev/null 2>&1 \
  || { [ -r "$HARNESS/bin/lib/needs-human.sh" ] && . "$HARNESS/bin/lib/needs-human.sh" 2>/dev/null || true; }
NH_PR_SECTION=""
if [ -n "${_CL_ISSUE:-}" ] && command -v nh_pr_body_section >/dev/null 2>&1; then
  NH_PR_SECTION=$(nh_pr_body_section "$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')" "$_CL_ISSUE" 2>/dev/null || true)
fi
# <<< needs-human pr section
# The belt to that brace: after a VERIFIED tier-1 merge, comment on and close
# the issue explicitly — a squash by another actor may not carry the body.
# One pipeline.log line either way; never fails the build.
CLOSE_ISSUE_AFTER_MERGE() { # CLOSE_ISSUE_AFTER_MERGE <pr-url>
  [ -n "$CLOSES_LINE" ] || return 0
  # A `Refs` line (a partial build, BH-5798) never closes the issue.
  case "$CLOSES_LINE" in "Closes #"*) ;; *) return 0 ;; esac
  local n="${CLOSES_LINE#Closes #}" w
  # The close takes `ai-build` off with it (BH-637 §3b): the label is the
  # handoff, and an issue that is shipped but still carries it is what re-offers
  # finished work to every selector in the fleet. The strip word rides the log
  # line so `strip-failed` is greppable on a box. A tree without the lib keeps
  # exactly today's pair below.
  if command -v issue_close_shipped >/dev/null 2>&1; then
    # The PR url and this build's plan let the helper leave a merge that only
    # SLICED the issue open (BH-2477: a C<n> plan, open children).
    if w=$(issue_close_shipped "$SLUG" "$n" "Merged in $1 (tier-1, reviewed and gated in this build). Closing this issue." "$HARNESS" "$1" "$BUILD"); then
      case "$w" in
        kept-slice*) echo "$(STAMP) [$PROJECT/$KEY] left issue #$n open after merge, slice delivered ($w)" >> "$BUILD/pipeline.log" ;;
        *)           echo "$(STAMP) [$PROJECT/$KEY] closed issue #$n after merge (ai-build: $w)" >> "$BUILD/pipeline.log" ;;
      esac
    else
      echo "$(STAMP) [$PROJECT/$KEY] merged $1 but issue #$n could not be commented/closed — bin/reconcile-prs.sh re-reads merged PRs and closes it on a later tick" >> "$BUILD/pipeline.log"
    fi
    return 0
  fi
  # THE FALLBACK PAIR, OVER REST (BH-781). Comment first, close second, and the
  # close only counts when gh_rest_close's own re-read says `closed` — a 403 on
  # either leaves the issue OPEN with the line below, and bin/reconcile-prs.sh
  # re-reads merged PRs and closes it on a later tick. The body goes by FILE so
  # it never reaches argv or a process list.
  #
  # THE COMMENT IS POSTED EXACTLY ONCE, whatever retries the pair. Two calls in
  # place of one atomic `gh issue close --comment` means a POST that landed
  # under a PATCH that was refused is invisible to the next attempt, and the
  # next attempt would say the same sentence again on a client-visible thread
  # (TK-88). The marker lives in $HARNESS/state, not $BUILD, because a retry may
  # be a different build of the same ticket; it follows the POST, never the
  # attempt, so a rate-limited tick still leaves the issue explainable.
  local _cf _cm
  _cm="$HARNESS/state/merge-close-commented-${SLUG//\//_}-$n"
  # The marker is a D1 `commented` row too (BH-2317), so a wiped box does not
  # say it twice; bin/lib/comment-mark.sh has the read rule. A bin/ without the
  # lib (127) answers from the file alone, as before.
  declare -F cm_has >/dev/null || . "$HARNESS/bin/lib/comment-mark.sh" 2>/dev/null
  local _cmk="merge-close $SLUG $n" _cmrc=0
  cm_has "$_cmk" - "$_cm" 2>/dev/null || _cmrc=$?
  [ "$_cmrc" = 127 ] && { [ -e "$_cm" ] && _cmrc=0; }
  _cf=$(mktemp "${TMPDIR:-/tmp}/close-body.XXXXXX") || _cf=""
  if [ -n "$_cf" ]; then
    printf 'Merged in %s (tier-1, reviewed and gated in this build). Closing this issue.\n' "$1" > "$_cf"
    local _cok=0
    if [ "$_cmrc" = 0 ]; then
      _cok=1
    elif gh_rest_comment "$SLUG" "$n" "$_cf"; then
      mkdir -p "$HARNESS/state" 2>/dev/null || true
      cm_put "$_cmk" - "$_cm" 2>/dev/null || : > "$_cm" 2>/dev/null || true
      _cok=1
    fi
    if [ "$_cok" = 1 ] && gh_rest_close "$SLUG" "$n" issues; then
      echo "$(STAMP) [$PROJECT/$KEY] closed issue #$n after merge" >> "$BUILD/pipeline.log"
      # Its job is done the moment the issue is closed; a reopened issue closed
      # again later deserves its own comment rather than a silent close.
      cm_clear "$_cmk" "$_cm" 2>/dev/null || rm -f "$_cm" 2>/dev/null || true
    else
      echo "$(STAMP) [$PROJECT/$KEY] merged $1 but issue #$n could not be commented/closed — bin/reconcile-prs.sh re-reads merged PRs and closes it on a later tick" >> "$BUILD/pipeline.log"
    fi
    rm -f "$_cf"
  else
    echo "$(STAMP) [$PROJECT/$KEY] merged $1 but issue #$n could not be commented/closed — bin/reconcile-prs.sh re-reads merged PRs and closes it on a later tick" >> "$BUILD/pipeline.log"
  fi
}
# >>> assumptions section
# THE ASSUMPTIONS RIDE INTO THE PR (2026-09-13). On a GitHub-Issues lane the
# planner no longer parks on ambiguity — it picks the most conservative reading
# and writes it down (see "plan ambiguity rule" above). That list is worth
# nothing sitting in plan.md on a build box: the PR body is where a reviewer
# actually reads it and where a wrong assumption is cheap to correct. Lifted
# verbatim from the plan's '## ASSUMPTIONS' heading to the next heading. A plan
# with no such section (every board project, and any issue-lane plan that had
# nothing to assume) produces an empty string and the body is byte-identical.
ASSUMPTIONS_SECTION=""
_ASSUM=$(awk '/^##[[:space:]]*ASSUMPTIONS/{f=1;next} f&&/^##[[:space:]]/{exit} f' "$BUILD/plan.md" 2>/dev/null | head -c 1500)
[ -n "$(printf '%s' "$_ASSUM" | tr -d '[:space:]')" ] && \
  ASSUMPTIONS_SECTION=$(printf '\n## Assumptions\n\nThe ticket did not settle these; the plan took the most conservative reading and built. Correct any of them here and the fix is one comment.\n%s\n' "$_ASSUM")
# <<< assumptions section
# >>> spec changes section (BH-5799)
# The plan's '## Spec changes from comments' section rides into the PR body,
# so the lead review can compare it with the ticket thread (checklist item 1).
# Verbatim to the next '## ' heading, capped at 1500 bytes. A plan with no such
# section says so in one line: the reviewer must see that it is missing.
SPEC_CHANGES_SECTION=""
_SPECC=$(awk '/^##[[:space:]]*Spec changes from comments/{f=1;next} f&&/^##[[:space:]]/{exit} f' "$BUILD/plan.md" 2>/dev/null | head -c 1500)
if [ -n "$(printf '%s' "$_SPECC" | tr -d '[:space:]')" ]; then
  SPEC_CHANGES_SECTION=$(printf '\n## Spec changes from comments\n%s\n' "$_SPECC")
else
  SPEC_CHANGES_SECTION=$(printf "\n## Spec changes from comments\n\nThe plan carried no 'Spec changes from comments' section.\n")
fi
# <<< spec changes section (BH-5799)
# >>> repro section
# The pre-build repro's PR-body section (BH-2004). Empty with the stub render.
REPRO_SECTION=""
command -v pr_pr_section >/dev/null 2>&1 && REPRO_SECTION="$(pr_pr_section "$BUILD")"
# <<< repro section
# >>> stacked banner
# Every variable here is defaulted because this block sits INSIDE the evidence
# block, which tests/evidence-block-test.sh and tests/pr-body-closes-test.sh
# extract verbatim and source under `set -u` with only their own inputs.
# The one fact a reviewer of a stacked PR needs before reading anything else:
# the base is a feature branch, so the diff is only this ticket's change and the
# PR retargets itself when the parent lands. Empty on every ordinary build, and
# the body is then byte-identical.
STACK_SECTION=""
[ -n "${STACK_ON:-}" ] && STACK_SECTION=$(printf '\nSTACKED on `%s` (%s). This PR'"'"'s base is that branch, not `%s`, so the diff below is ONLY this ticket'"'"'s change — the parent'"'"'s work is already in the base. GitHub retargets this PR to `%s` when the parent merges and its branch is deleted; until then the merge conductor holds it as STACKED_WAIT and never merges a PR into a feature branch.\n' \
  "$STACK_ON" "${STACK_PARENT_PR:-the parent PR}" "${BASE_MAIN:-main}" "${BASE_MAIN:-main}")
# <<< stacked banner
# >>> hotfix banner
# The first line of the body names it (#368). Defaulted INSIDE the evidence
# block's markers, because tests/pr-body-closes-test.sh and
# tests/evidence-block-test.sh source this region verbatim under `set -u` with
# only their own variables — and guarded on the lane's kill flag so that
# HOTFIX_LANE=0 renders the body this pipeline rendered before #368, byte for
# byte. The line COUNT does not change, so `Closes #n` is still line 2.
HOTFIX_PREFIX=""
if [ "${HOTFIX:-}" = 1 ]; then
  if ! command -v hotfix_lane_on >/dev/null 2>&1 \
     || [ "$(hotfix_lane_on "${HARNESS:-/root/harness}")" = 1 ]; then
    HOTFIX_PREFIX="HOTFIX: "
  fi
fi
# <<< hotfix banner
PR_BODY_FOR() { # PR_BODY_FOR <evidence-section>
  # The body's first line names the same subject the title does (BH-1415): it
  # read `git log -1` and printed `Ticket BH-<n> — spec(BH-<n>): …` on every
  # build of the 2026-09-22 wave. The `:-` default is mandatory, not tidiness —
  # tests/pr-body-closes-test.sh, tests/evidence-block-test.sh and
  # tests/hotfix-pr-label-test.sh source this block under `set -u` without
  # setting PR_SUBJECT, and for them the rendered body stays byte-identical.
  # Captured inside the function, so the fallback is still THIS call's HEAD;
  # head on a git pipe is a SIGPIPE race under pipefail (BH-1248).
  local EB_SUBJECT; EB_SUBJECT="${PR_SUBJECT:-}"
  [ -n "$EB_SUBJECT" ] || EB_SUBJECT=$(git log -1 --format=%s)
  EB_SUBJECT=${EB_SUBJECT:0:100}
  # A child slice never closes its parent (BH-1706): prepr_body_keywords turns
  # `Closes #<parent>` into `Part of #<parent>`. Without bin/lib/prepr-gate.sh
  # (the suites that source this block alone) the body passes through as is.
  local _KW=cat
  command -v prepr_body_keywords >/dev/null 2>&1 && _KW=prepr_body_keywords
  # BH-6392: the plan's tests-that-must-change and the commits' TEST-CHANGE:
  # lines, for the self-check's test-ownership rule. Empty without the lib.
  local TEST_CHANGE_SECTION=""
  if command -v psc_test_change_section >/dev/null 2>&1; then
    TEST_CHANGE_SECTION=$(psc_test_change_section "$BUILD/plan.md" "origin/${BASE:-main}")
  fi
  printf '%sTicket %s — %s
%s%s
## What
%s

## Why
%s

%s
%s
%s

---
Plan: harness build %s. Planned on %s, executed on %s, adversarially reviewed on %s (VERDICT: APPROVE). %s%s %s

<details><summary>Build context %s</summary>

Which rules and prompts produced this diff. Same signature = identical context; a different one means the rules or prompts moved between builds.

- context signature: `%s`
- harness commit: `%s`
- box: `%s`
- rules/bin in sync with checkout: %s
- checkout vs origin: %s

Full manifest (per-input digests): `%s/context.json` on the build box.

</details>
%s
🤖 Generated with [Claude Code](https://claude.com/claude-code)' \
    "$HOTFIX_PREFIX" "$KEY" "$EB_SUBJECT" "${CLOSES_LINE:+$CLOSES_LINE
}" "$STACK_SECTION" "$WHAT_LIST" "$WHY_EXCERPT" "$VERIFY_LINE" "$SPEC_LINE" "${ASSUMPTIONS_SECTION}${PREPR_SECTION:-}${REPRO_SECTION:-}${SPEC_CHANGES_SECTION:-}${NOTMET_SECTION:-}${NH_PR_SECTION:-}${CALLERS_SECTION:-}${TEST_CHANGE_SECTION:-}" "$(basename "$BUILD")" "$PLAN_MODEL" "$EXECUTE_MODEL" "$REVIEW_MODEL" "$MERGE_NOTE" "$MIG_SECTION" "$COST_LINE" \
    "$CTX_SIG" "$CTX_SIG" "$CTX_COMMIT" "$(hostname)" "$CTX_SYNC" "$CTX_FRESH" "$BUILD" "$1" \
    | "$_KW"
}
# <<< evidence block
# The last boundary before a PR exists (BH-1526): a ticket held during the
# review stands down here, with its branch pushed and no PR opened.
HOLD_STAGE_CHECK pr
# >>> pr open
GH_LIVE
# >>> pr create call
# WHERE THIS CREATE'S STDERR STARTS. The log is append-only and survives a
# RESUME_BUILD, so reading its tail would hand the PREVIOUS run's error to this
# run's failure line as if it were the reason — a lie about which create failed
# and why. Nothing is truncated (the file ships as a build artifact); the
# failure block below reads only the bytes this create wrote.
GH_ERR_AT=$(wc -c < "$BUILD/gh-stderr.log" 2>/dev/null | tr -d ' ')
# Hoisted out of the failure block below, because the ladder needs the slug too.
PCF_SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
# >>> pr create ladder (BH-848)
# ONE RUNG WAS THE BUG. `gh pr create` is GraphQL, and on a pool machine it runs
# on an App installation token whose GraphQL budget is chronically exhausted
# ("API rate limit already exceeded for installation ID 161623167"). The adopt
# that used to live here was `gh pr list` — GraphQL again, same bucket, same
# failure — so the build wrote PR_CREATE_FAILED while the PR itself got opened by
# a later path, and bin/merge-sweep.sh (line 1 must read `PR_CREATED https://`)
# never saw it. Ten CI-green APPROVE PRs in one day.
# bin/lib/gh-pr-create.sh climbs instead: GraphQL create, GraphQL adopt, REST
# adopt, REST create, then every other identity this box holds. REST and GraphQL
# are separate budgets (the same lesson BH-709 and BH-374 already taught the read
# paths).
# THE GRAPHQL ADOPT MOVED INTO THE LIB, IT DID NOT GO AWAY — it is rung
# graphql-adopt, above the kill flag, so PR_CREATE_REST_FALLBACK=0 leaves this
# call site doing create-then-adopt exactly as the else branch below does. An
# adopt out here as well would only spend the same exhausted budget twice.
# WHEN THE LIB IS ABSENT — an older tree mid-propagation — the else branch is the
# create and the GraphQL adopt exactly as they were before #848.
# shellcheck source=bin/lib/gh-pr-create.sh
[ -r "$HARNESS/bin/lib/gh-pr-create.sh" ] && . "$HARNESS/bin/lib/gh-pr-create.sh"
# >>> pr trailers (BH-3987)
# THE PR SAYS WHO BUILT IT. A `Harness-Job:` / `Harness-Ticket:` block goes at
# the foot of $BUILD/pr-body.md, after the footer, before either create below
# reads it. A box build's job id is $JOB_ID; a pool build (BUILDER_EXEC=1) has it
# in job.json; with neither it is `none`. A missing trailer never fails a build: with
# the lib absent the body opens as it always did, and a write that fails leaves
# the body untouched and says so once in pipeline.log.
# shellcheck source=bin/lib/pr-trailers.sh
[ -r "$HARNESS/bin/lib/pr-trailers.sh" ] && . "$HARNESS/bin/lib/pr-trailers.sh"
_pr_trailers_s1() {
  command -v pr_trailers_apply >/dev/null 2>&1 || return 0
  pr_trailers_apply "$BUILD/pr-body.md" "$(pr_trailers_job_for "$BUILD")" "$KEY" \
    || echo "$(STAMP) [$PROJECT/$KEY] pr trailers: could not write $BUILD/pr-body.md — PR opened without trailers" >> "$BUILD/pipeline.log"
  return 0
}
# <<< pr trailers
# >>> pr title subject (tests/run-build-pr-title.bh-1415-test.sh drives this block)
# THE TITLE IS THE TICKET, NOT THE LAST COMMIT (BH-1415). `git log -1` was the
# whole rule until this block, and the spec artifact stage commits
# `spec(<KEY>): the plan this build was executed from` AFTER execute — so on
# nearly every build HEAD *is* that commit and the PR was called
# `BH-<n>: spec(BH-<n>): the plan this build was executed from`. 33 of them in
# one wave on 2026-09-22.
#
# Three rungs, first non-empty wins:
#   1. the ticket's own title, which is what the PR is FOR;
#   2. the newest commit subject that is not the spec commit;
#   3. HEAD's subject — today's behaviour, so a build with no ticket-meta.json
#      and nothing but a spec commit still opens a PR with a name on it.
# The `$KEY: ` strip is not cosmetic: rung 2's subjects already start with the
# key, and the create below prefixes it again.
# git log is captured into a variable BEFORE the filter: head/grep on a git pipe
# is a SIGPIPE race under pipefail (BH-1248), and a 141 here would open the PR
# with an empty title.
PR_SUBJECT=$(jq -r '.title // ""' "$BUILD/ticket-meta.json" 2>/dev/null)
if [ -z "${PR_SUBJECT//[[:space:]]/}" ]; then
  PR_SUBJECTS=$(git log -12 --format=%s HEAD)
  PR_SUBJECT=$(printf '%s\n' "$PR_SUBJECTS" \
    | grep -vxF -- "spec($KEY): the plan this build was executed from" | sed -n 1p)
fi
[ -n "${PR_SUBJECT//[[:space:]]/}" ] || PR_SUBJECT=$(git log -1 --format=%s)
case "$PR_SUBJECT" in "$KEY: "*) PR_SUBJECT=${PR_SUBJECT#"$KEY: "} ;; esac
PR_SUBJECT=${PR_SUBJECT:0:80}
# <<< pr title subject
# The REST rung posts the body from a file, and `--body-file` is what rung 1
# wants anyway, so the body is written once and every rung reads the same bytes.
PR_BODY_FOR "$EVIDENCE_SECTION" > "$BUILD/pr-body.md"
# >>> pr body fix round
# BH-5790 / BH-6393: THE BODY CARRIES WHAT THE LEAD REVIEW WOULD BLOCK ON, and
# the builder checks it before the hub does. Every row of
# catalog/pr-self-check.tsv runs on the final head and body (no --only: the
# same rules self_check_hold in bin/lead-review-enqueue.sh runs after the PR is
# open), at most 2 times:
#   - a plan-files refusal gets one reason line per unplanned file under
#     `## Files outside the plan`, from psc_plan_missing, with no model turn;
#   - a body-* refusal (Why, an acceptance section or gate table, the probe the
#     ticket names) buys ONE fix turn in the open phase that writes only the
#     missing sections to $BUILD/pr-body-fix.md, inserted here;
#   - what still refuses on the second check goes into the body under
#     `## Pre-open check: refusals left`. That heading must never match the
#     acceptance/self-check/evidence/why section matchers, or a finding would
#     score as a section.
# The PR opens (or its body is edited) either way. Phase `edit` is the settle
# stage's `gh pr edit` (bin/lib/rb/result.sh): its body is rendered fresh, so
# the open-time fix sections are inserted again, never bought again. One line
# per phase goes to $BUILD/self-check-prepush.txt. PR_SELF_CHECK=0 turns the
# step off together with the hub hold.
_pr_body_insert() { # <body-file> <section-file>
  # Before the footer (the `---` above "Plan: harness build"), so the added
  # sections sit with the body and the attribution footer stays last; no
  # footer = appended.
  awk -v f="$2" '
    { L[++n] = $0 }
    END {
      at = 0
      for (i = 1; i < n; i++) if (L[i] == "---" && L[i + 1] ~ /^Plan: harness build/) { at = i; break }
      for (i = 1; i <= n; i++) {
        if (i == at) { while ((getline x < f) > 0) print x; print "" }
        print L[i]
      }
      if (!at) { print ""; while ((getline x < f) > 0) print x }
    }' "$1" > "$1.new" && mv -f "$1.new" "$1"
}
_pr_self_check_prepush() { # <body-file> <open|edit>
  local body="$1" phase="${2:-open}" psc="$HARNESS/bin/pr-self-check.sh" tk="$BUILD/ticket-body.md"
  local b out rc ref miss k try=0 bought=0 verdict ids p subj n=0 fixed
  local rec="$BUILD/self-check-prepush.txt"
  if ! [ -x "$psc" ] || ! [ -s "$body" ]; then
    echo "$phase tries=0 verdict=could-not-run rules=-" >> "$rec"; return 0
  fi
  # The self-check's kill switch is the fix round's too (lead review
  # lr-5846): PR_SELF_CHECK=0 buys no FIX_MODEL turn. Env first, then the
  # lead-review-enqueue lane registry; unread = on, like the enqueue.
  k="${PR_SELF_CHECK:-}"
  [ -n "$k" ] || { command -v lane_knob >/dev/null 2>&1 && k=$(lane_knob lead-review-enqueue PR_SELF_CHECK "${PROJECT:-}" 2>/dev/null); }
  if [ "$k" = 0 ]; then
    echo "$(STAMP) [${PROJECT:-?}/${KEY:-?}] pr body: the self-check is off (PR_SELF_CHECK=0); no fix round" >> "$BUILD/pipeline.log"
    return 0
  fi
  jq -r '.body // ""' "$BUILD/ticket-meta.json" > "$tk" 2>/dev/null || : > "$tk"
  b="origin/${BASE:-main}"; git rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1 || b="${BASE:-main}"
  # psc_plan_missing lists the files plan-files refuses, uncut. A lib that will
  # not source writes no reason lines; the check itself still runs.
  command -v psc_plan_missing >/dev/null 2>&1 || . "$HARNESS/bin/lib/pr-self-check.sh" 2>/dev/null
  # Edit phase: put back the sections the open phase's fix turn wrote, unless
  # every line of them is already in the body.
  if [ "$phase" = edit ] && [ -s "$BUILD/pr-body-fix.md" ] \
     && grep -v '^[[:space:]]*$' "$BUILD/pr-body-fix.md" | grep -qvxF -f "$body"; then
    _pr_body_insert "$body" "$BUILD/pr-body-fix.md"
  fi
  while :; do
    try=$((try + 1))
    out=$(env -u PR_SELF_CHECK_ONLY "$psc" check --repo . --base "$b" --head HEAD --body "$body" --ticket "$tk" ${KEY:+--key "$KEY"} 2>/dev/null); rc=$?
    if [ "$rc" != 0 ] && [ "$rc" != 1 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] pr self-check: could not run ($phase): $(head -1 <<<"$out" | cut -c1-200)" >> "$BUILD/pipeline.log"
      echo "$phase tries=$try verdict=could-not-run rules=-" >> "$rec"
      return 0
    fi
    ref=$(sed -n 's/^REFUSE //p' <<<"$out")
    [ -n "$ref" ] && [ "$try" -lt 2 ] || break
    if grep -q '^plan-files:' <<<"$ref" && command -v psc_plan_missing >/dev/null 2>&1 \
       && miss=$(psc_plan_missing . "$b" HEAD "$body" "") && [ -n "$miss" ]; then
      { printf '## Files outside the plan\n\n'
        while IFS= read -r p; do
          [ -n "$p" ] || continue
          n=$((n + 1))
          subj=$(git log -1 --format=%s "$b..HEAD" -- "$p" 2>/dev/null | tr -d '`' | cut -c1-120)
          if [ -n "$subj" ]; then printf -- '- `%s`: changed in this build by "%s"; the plan'"'"'s Files to touch does not name it.\n' "$p" "$subj"
          else printf -- '- `%s`: changed in this build; the plan'"'"'s Files to touch does not name it.\n' "$p"; fi
        done <<<"$miss"; } > "$BUILD/pr-body-outside.md"
      _pr_body_insert "$body" "$BUILD/pr-body-outside.md"
      echo "$(STAMP) [$PROJECT/$KEY] pr self-check: wrote $n reason line(s) under Files outside the plan" >> "$BUILD/pipeline.log"
    fi
    miss=$(grep '^body-' <<<"$ref")
    if [ -n "$miss" ] && [ "$phase" = open ]; then
      bought=1
      rm -f "$BUILD/pr-body-fix.md"
      CC fix "$FIX_MODEL" 900 "$BUILD/pr-body-fix-run.txt" "The PR body at $body is missing sections the lead review would BLOCK on. Do NOT edit any repo file and do NOT commit. Write ONLY the missing sections, as markdown, to $BUILD/pr-body-fix.md, from the facts of this build. The body always has a '## Why' heading, so a body-why finding means its text is too thin; an acceptance finding wants a section that names the acceptance tests and their results (the plan at $BUILD/plan.md, the diff \`git diff $b...HEAD\`, the test output in $BUILD). Each one must be true: if a fact is not in the build record, say it was not run. Missing:
$miss"
      [ -s "$BUILD/pr-body-fix.md" ] && _pr_body_insert "$body" "$BUILD/pr-body-fix.md"
    fi
  done
  if [ "$bought" = 1 ]; then
    fixed=$(grep '^body-' <<<"$ref")
    if [ -z "$fixed" ]; then echo "$(STAMP) [$PROJECT/$KEY] pr body: fixed — the fix turn added the missing sections" >> "$BUILD/pipeline.log"
    else echo "$(STAMP) [$PROJECT/$KEY] pr body: still missing after the fix turn — $(tr '\n' ';' <<<"$fixed" | cut -c1-400)" >> "$BUILD/pipeline.log"; fi
  fi
  if [ -z "$ref" ]; then
    verdict=pass; ids=-
    echo "$(STAMP) [$PROJECT/$KEY] pr self-check: pass on try $try ($phase)" >> "$BUILD/pipeline.log"
  else
    verdict=refused; ids=$(sed 's/:.*//' <<<"$ref" | awk '!s[$0]++' | paste -sd, -)
    { printf '## Pre-open check: refusals left\n\n'
      printf 'The builder ran bin/pr-self-check.sh %s times on this head before it %s the PR. These findings are still open, and the lead review reads them:\n' \
        "$try" "$([ "$phase" = edit ] && echo updated || echo opened)"
      sed 's/^/- /' <<<"$ref"; } > "$BUILD/pr-body-findings.md"
    _pr_body_insert "$body" "$BUILD/pr-body-findings.md"
    echo "$(STAMP) [$PROJECT/$KEY] pr self-check: still refused after $try tries ($phase) — $ids; the findings are in the body" >> "$BUILD/pipeline.log"
  fi
  echo "$phase tries=$try verdict=$verdict rules=$ids" >> "$rec"
  return 0
}
_pr_self_check_prepush "$BUILD/pr-body.md" open
# <<< pr body fix round
# BH-6672: the body carries suite output and evidence; no token shape is sent.
RB_TOKEN_REDACT "$BUILD/pr-body.md"
# >>> pr-open hold gate (tests/pool-hold-yield.bh-6091-test.sh drives this block)
# THE HOLD IS READ AGAIN AT THE CREATE (BH-6091). HOLD_STAGE_CHECK pr ran
# before the PR-body model turn above, so it is not a write-time read. Held:
# RB_HOLD_YIELD exits 3 with `HOLD_YIELD <KEY> at pr-open`. Unreadable: no PR
# is opened, the branch is already pushed, and the next run reads it again.
RB_HOLD_GATE pr-open || {
  RESULT "BUILD_DEFERRED hold unreadable at pr-open — the branch is pushed, no PR opened"; exit 3
}
# <<< pr-open hold gate
if command -v gh_pr_create_ladder >/dev/null 2>&1 && [ -n "$PCF_SLUG" ]; then
  _pr_trailers_s1
  PR_URL=$(gh_pr_create_ladder "$PCF_SLUG" "$BRANCH" "$BASE" \
    "$KEY: $PR_SUBJECT" "$BUILD/pr-body.md" \
    "$BUILD/gh-stderr.log" "$BUILD/pipeline.log" "$PROJECT/$KEY")
else
  _pr_trailers_s1
  PR_URL=$(gh pr create --head "$BRANCH" --base "$BASE" --title "$KEY: $PR_SUBJECT" --body-file "$BUILD/pr-body.md" 2>>"$BUILD/gh-stderr.log")   # gh-guard-allow: a write, not a decision read
  # gh pr create fails when the head already has an open PR (continue-mode always,
  # retries sometimes). The PR existing IS success — adopt its URL instead of
  # shipping a PR_CREATED with an empty URL that no close-out handler can heal.
  if [ -z "$PR_URL" ]; then
    PR_URL=$(gh pr list --head "$BRANCH" --state open --json url -q '.[0].url' 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
    [ -n "$PR_URL" ] && echo "$(STAMP) [$PROJECT/$KEY] pr create failed but open PR exists on $BRANCH — adopted $PR_URL" >> "$BUILD/pipeline.log"
  fi
fi
# <<< pr create ladder
# >>> pr create failed
# NO URL AND NO PR TO ADOPT: this build has no PR, and the only honest thing to
# do is say why in the words gh used (#574). PR_CREATE_ERR is what the RESULT
# ratchet at the top of this file folds into the terminal line, so the sweep
# escalates for the real reason instead of chasing a PR that was never opened.
# The ALERTS line is written HERE, before the RESULT, so a pipeline killed
# between the two still leaves the human-readable escalation on disk.
if [ -z "$PR_URL" ]; then
  PR_CREATE_ERR=$(tail -c "+$(( ${GH_ERR_AT:-0} + 1 ))" "$BUILD/gh-stderr.log" 2>/dev/null | tr '\n\t' '  ' | tr -s ' ' | tail -c 300)
  [ -n "${PR_CREATE_ERR// /}" ] || PR_CREATE_ERR="gh pr create returned no url and wrote no error"
  echo "$(STAMP) [$PROJECT/$KEY] PR CREATE FAILED on $BRANCH (base $BASE): $PR_CREATE_ERR — nothing to adopt, so this build has NO PR. Open it by hand with: gh pr create --head $BRANCH --base $BASE_MAIN -R $PCF_SLUG" >> "$ALERTS"
  echo "$(STAMP) [$PROJECT/$KEY] pr create failed and no open PR exists on $BRANCH: $PR_CREATE_ERR" >> "$BUILD/pipeline.log"
  # THE LEDGER ROW FOR "built, reviewed, no PR" (BH-614). The `result` artifact
  # carries line 1 and the `pr_url` one is guarded on a url, so nothing could
  # list these builds by branch. ref = the branch, because that is what an
  # operator opens the PR from by hand and what a rebuild targets. Written
  # before RESULT() like the ALERTS line above, and fail-open: a box with no
  # jobs worker records nothing and the build still ends the same way.
  if [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
    job_artifact_put pr_create_failed "$BRANCH" "$(jq -nc \
      --arg b "$(basename "$BUILD")" --arg br "$BRANCH" --arg base "$BASE" \
      --arg e "$(printf '%.900s' "$PR_CREATE_ERR")" \
      '{record:$b,branch:$br,base:$base,error:$e}' 2>/dev/null)" >/dev/null 2>&1 || true
  fi
fi
# <<< pr create failed
# <<< pr create call
# THE PR IS OPEN from here on (BH-6091 review): a hold at a later write point
# (the QA fix push) yields that write only, and RESULT still says PR_CREATED.
[ -n "$PR_URL" ] && RB_PR_OPEN=1
# --- THE LABEL FOLLOWS THE WORK (#368, hotfix lane 1/3) ----------------------
# A SEPARATE REST WRITE, never a `--label` flag on the create above. That flag
# fails the whole CREATE when the label does not exist in the target repo, which
# would turn a missing label into a lost PR; POST issues/<n>/labels is the path
# bin/lib/merge-conductor-lib.sh already uses (gh pr edit --add-label broke on
# every example-org PR on 2026-09-13). Child #2's merge rule keys on this label,
# so a failed write is ONE ALERTS line naming the command that fixes it — and
# never a failed build: the PR is open either way, and a label is not worth
# throwing a finished diff away over.
#
# ticket-meta.json is read as the second opinion because a RESUME_BUILD (or a
# build whose early detection ran while gh was down) can reach this point with
# HOTFIX empty and the label sitting right there in the fetched issue.
HF_PR=0
[ "${HOTFIX:-}" = 1 ] && HF_PR=1
if [ "$HF_PR" = 0 ] && command -v hotfix_meta_is >/dev/null 2>&1; then
  hotfix_meta_is "$BUILD/ticket-meta.json" "$HARNESS" && HF_PR=1
fi
if command -v hotfix_lane_on >/dev/null 2>&1 && [ "$(hotfix_lane_on "$HARNESS")" = 0 ]; then HF_PR=0; fi
if [ -n "$PR_URL" ] && [ "$HF_PR" = 1 ]; then
  HOTFIX=1
  HF_LABEL=$(hotfix_label "$HARNESS")
  # The slug comes off the PR URL itself rather than from git: it is the repo
  # the PR was actually opened in, which is the only one this write may touch.
  HF_SLUG=$(sed -nE 's#^https://github.com/([^/]+/[^/]+)/pull/[0-9]+$#\1#p' <<<"$PR_URL")
  HF_NUM=$(grep -oE '[0-9]+$' <<<"$PR_URL")
  if [ -n "$HF_SLUG" ] && [ -n "$HF_NUM" ] \
     && gh api -X POST "repos/$HF_SLUG/issues/$HF_NUM/labels" -f "labels[]=$HF_LABEL" >/dev/null 2>&1; then
    echo "$(STAMP) [$PROJECT/$KEY] labelled $PR_URL '$HF_LABEL'" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] HOTFIX $PR_URL could NOT be labelled '$HF_LABEL' — the hotfix merge rule keys on this label, so it will be treated as an ordinary PR until somebody adds it. If the label does not exist in the repo: gh label create $HF_LABEL -R ${HF_SLUG:-<slug>}" >> "$ALERTS"
  fi
  hotfix_announce "$HARNESS" "$PROJECT" "$KEY" pr_open "PR opened $PR_URL" >/dev/null 2>&1 || true
fi
STAGE_END pr-open "$T_PR"
# >>> live emit pr
# THE #745 FINDING, as code: a build whose `gh pr create` failed must never emit
# a PR as opened, and must never post an empty url as if it were one. Same split
# the tier-2 close-out below makes between `pr_created` and `pr_create_failed`.
if type LIVE >/dev/null 2>&1; then
  if [ -n "$PR_URL" ]; then
    LIVE pr_opened "" "PR opened: $PR_URL"
  else
    LIVE pr_opened failed "no PR could be opened: ${PR_CREATE_ERR:-gh pr create produced no url}"
  fi
fi
# <<< live emit pr
# <<< pr open

# --- Phase 7: the PR is an ARTIFACT of this claim -----------------------------
# Recorded the moment the URL exists — before QA, before the tier settles — so a
# build that dies after this point still leaves the ledger able to answer WHICH
# job made this PR. That lookup is the whole basis of bin/merge-sweep.sh reading
# a verdict rather than scraping one. Fail-open: no claim, no worker or no
# client means no artifact and nothing about this build changes.
if [ -n "$PR_URL" ] && [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  job_artifact_put pr_url "$PR_URL" \
    "$(jq -nc --arg b "$(basename "$BUILD")" --arg br "$BRANCH" '{record:$b,branch:$br}' 2>/dev/null)" \
    >/dev/null 2>&1 || true
fi

# --- Preview QA (2026-07-27): drive the Vercel preview deployment before any merge.
# UI-touching diffs only; fail-open on infra (no preview / protected URL -> skipped).
# A QA FAIL gets one fix round; still failing -> demote to tier 2, which means
# the build session may not merge it — the hub's sweep and conductor still do.
T_QA=$(STAGE_START)
SLUG=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
QA_PROMPT_FOR() { printf 'QA stage. A Vercel PREVIEW deployment of branch %s is live at %s. ACCESS: if env var VERCEL_AUTOMATION_BYPASS_SECRET is set, use Vercel bypass COOKIE mode — navigate FIRST to "<url>/?x-vercel-protection-bypass=$SECRET&x-vercel-set-bypass-cookie=true", after which the cookie authenticates every request. NEVER send the bypass as a global playwright extraHTTPHeaders header: it rides along on third-party requests and breaks their CORS preflight (Clerk CDN lesson, 2026-07-28). SIGN-IN: if env vars QA_CLERK_SECRET_KEY and QA_TEST_USER_ID are set, authenticate as the low-privilege QA test user before driving screens: mint a one-time token (POST https://api.clerk.com/v1/sign_in_tokens with {"user_id":$QA_TEST_USER_ID,"expires_in_seconds":300}, Authorization: Bearer $QA_CLERK_SECRET_KEY) and open "<url>/sign-in?__clerk_ticket=<token>" (reference implementation: /root/harness/bin/qa-signin-check.mjs). Screens the QA role legitimately cannot access show a permission wall — note that as observed behavior, not a defect. If sign-in env is absent, QA the public surface and note authed screens as not-covered. Read %s/plan.md, especially "## QA screens". VERIFICATION MAP: if this repo has a docs/verification-map/ directory, it is the established record of how each feature is reached and driven — read the entries for the screens you are about to exercise and take their nav paths, routes, selectors and preconditions from there instead of rediscovering them, and follow their driving conventions (ARIA/data-attr selectors, poll an observable end-state rather than sleeping, evaluate only to READ state). An entry that no longer matches the app is a finding to report in qa.md, not something to quietly work around. The THIRD-TO-LAST line of qa.md must be exactly "MAP ENTRIES: <comma-separated entry files you used, or none>" — "none" is the honest answer when the repo has no map or none of its entries covered these screens. Write and run a HEADLESS playwright script (chromium; resolve playwright via createRequire from the repo, ESM ignores NODE_PATH) that, for each listed screen: loads it at 1280px AND 375px viewports, exercises the primary flow with obviously-fake test inputs on NON-DESTRUCTIVE actions only (never mutate real client data, never trigger deletes/payments/emails — previews share the PROD database), captures console errors + failed requests, and screenshots to %s/qa-shots/. Verify the UI iron laws: no horizontal body scroll at 375px, data tables sort on header click, list rows link to detail (no dead rows), no native browser dialogs. Write findings to %s/qa.md — pre-existing issues outside this ticket are noted separately, not failed. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). COUNT WHAT YOU ACTUALLY DID: the SECOND-TO-LAST line of qa.md must be exactly "QA COVERAGE: screens=<n> flows=<n> shots=<n>", counting only screens you really loaded, flows you really drove, and screenshots really written to %s/qa-shots/ — never what the plan listed or what you intended. If you exercised zero screens (playwright would not install, every URL failed, sign-in never worked), the verdict is QA: FAIL with screens=0; a pass with nothing behind it is the one outcome that must never happen. Last line exactly "QA: PASS" or "QA: FAIL" (FAIL only for real in-scope defects, console errors, broken screens, or zero coverage).' "$BRANCH" "$1" "$BUILD" "$BUILD" "$BUILD" "$BUILD"; }
# >>> preview-qa mode (BH-3438): catalog/preview-qa.conf names the projects whose
# previews cannot sign anyone in. Their QA drives signed out instead of spending
# the session on a sign-in that fails and ends screens=0. The text goes AFTER
# QA_PROMPT_FOR's own, which it overrides where they disagree; a missing lib
# reads `auth`, the prompt as before. The tier-1 gate in result.sh keys the
# demotion on the same registry, never on what the QA session writes.
. "$HARNESS/bin/lib/preview-qa-mode.sh" 2>/dev/null || preview_qa_mode() { echo auth; }
QA_PROMPT_MODE() {
  QA_PROMPT_FOR "$1"
  [ "$(preview_qa_mode "$PROJECT")" = signed-out ] || return 0
  printf ' %s' "SIGNED-OUT PREVIEW: this project's previews have no sign-in (no Clerk key on the Vercel preview). Do NOT attempt a Clerk sign-in even if QA_* env vars are set. Drive / and every \"## QA screens\" route signed out. A route that lands on /sign-in is recorded 'not covered (auth-walled on preview)': not a defect and not a counted screen. Count only screens that rendered signed out. Write a line \"QA AUTH: signed-out\" above the MAP ENTRIES line."
}
# <<< preview-qa mode
if [ -n "$PR_URL" ] && grep -qiE '\.(tsx|jsx|css)$|(^|/)app/|(^|/)components/|(^|/)pages/' <<<"$(git diff --name-only "$BASE"...HEAD)"; then
  SHA=$(git rev-parse HEAD)
  # wait-preview.sh's stderr goes to its own file first, so the reason a skip
  # skipped can ride onto qa.md and the PR; pipeline.log still gets every line.
  PREVIEW_URL=$("$HARNESS/bin/wait-preview.sh" "$SLUG" "$SHA" 600 2>"$BUILD/wait-preview.err"); WP_RC=$?
  cat "$BUILD/wait-preview.err" >> "$BUILD/pipeline.log" 2>/dev/null
  if [ "$WP_RC" = 0 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] PREVIEW QA ($QA_MODEL) $PREVIEW_URL" >> "$BUILD/pipeline.log"
    BB qa "$TIER"
    CC qa "$QA_MODEL" 1800 "$BUILD/qa-run.txt" "$(QA_PROMPT_MODE "$PREVIEW_URL")"
    if ! tail -1 "$BUILD/qa.md" 2>/dev/null | grep -q 'QA: PASS'; then
      echo "$(STAMP) [$PROJECT/$KEY] QA FAIL -> fix round" >> "$BUILD/pipeline.log"
      CC fix "$FIX_MODEL" 4800 "$BUILD/qa-fix-run.txt" "Address every defect in $BUILD/qa.md (browser QA of the preview deployment) on branch $BRANCH (plan: $BUILD/plan.md). Keep tests green; 'npm run build' must pass. Commit your work. Do NOT push: the harness pushes $BRANCH after this session, through its hold check."
      GH_LIVE
      { RB_PUSH qa-fix 2>/dev/null && track_pushed; } || true
      SHA=$(git rev-parse HEAD)
      PREVIEW_URL=$("$HARNESS/bin/wait-preview.sh" "$SLUG" "$SHA" 600 2>"$BUILD/wait-preview.err"); WP_RC=$?
      cat "$BUILD/wait-preview.err" >> "$BUILD/pipeline.log" 2>/dev/null
      if [ "$WP_RC" = 0 ]; then
        CC qa "$QA_MODEL" 1800 "$BUILD/qa2-run.txt" "$(QA_PROMPT_MODE "$PREVIEW_URL") Re-QA after fixes; append to $BUILD/qa.md."
      fi
      tail -1 "$BUILD/qa.md" 2>/dev/null | grep -q 'QA: PASS' || { TIER=2; echo "QA still failing after fix round — demoted to tier 2." >> "$BUILD/qa.md"; }
    fi
    gh pr comment "$PR_URL" --body "$(printf 'Preview QA (%s):\n%s' "$QA_MODEL" "$(tail -c 900 "$BUILD/qa.md" 2>/dev/null)")" 2>>"$BUILD/gh-stderr.log" || true   # gh-guard-allow: a write, not a decision read
  else
# >>> preview-qa skip reason (BH-3438): the fail-open line names why, from the
# last non-empty line wait-preview.sh wrote to stderr. The prefix is unchanged.
    WP_WHY=$(grep -v '^[[:space:]]*$' "$BUILD/wait-preview.err" 2>/dev/null | tail -1)
    echo "preview unavailable — QA skipped (fail-open): ${WP_WHY:-no reason given}" > "$BUILD/qa.md"
# <<< preview-qa skip reason
  fi
fi
STAGE_END qa "$T_QA"
} # end rb_pr
