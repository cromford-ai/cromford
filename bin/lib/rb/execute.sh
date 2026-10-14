# bin/lib/rb/execute.sh — the execute stage: the EXECUTE checkpoint and its result, PUSH_BRANCH, the mechanical gates, semgrep, and the mined checks.
# Each body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
# Both slices end exactly on the anchor #478 named, byte-verbatim.
# Entry functions, pipeline order: rb_execute rb_execute_gates
# Reads: _ ALERTS BASE BRANCH BUILD CHECKS_NOTE CHECKS_RC CHECKS_RUNNER CKPT_RESUME_NOTE
#   CKPT_START_POINT CKPT_WIP_N EXECUTE_MODEL EXECUTE_TIMEOUT_SECS GATES_NOTE GH_AUTH_SLUG
#   HARNESS INTENT_ENFORCE INTENT_GATE_ENFORCE INTENT_OUT INTENT_RC KEY KIND_EXEC_NOTE
#   KIND_G KIND_G_REPRO PROJECT REPRO_OUT REPRO_RC REROUTE_EXEC_NOTE SCOPE_BASE SCOPE_OUT
#   SCOPE_RC T_CHECKS T_GATE T_GATES T_SEMGREP TAMPER_OUT TAMPER_RC TEST_HOME_PRS_FILE TH_A
#   TH_AGE TH_BR TH_C TH_CACHE TH_CAND TH_FILES TH_FIND TH_LKEY TH_MB TH_MSG TH_NUM
#   TH_NUMSTAT TH_P TH_PRS TH_TSV TH_TTL TH_VERDICT
# Writes: CHECKS_NOTE CHECKS_RC CHECKS_RUNNER CKPT_RESUME_NOTE CKPT_WIP_N GATES_NOTE INTENT_OUT
#   KIND_G KIND_G_REPRO REPRO_OUT SCOPE_BASE SCOPE_OUT T_CHECKS T_GATE T_GATES T_SEMGREP
#   TAMPER_OUT TH_AGE TH_CACHE TH_CAND TH_FIND TH_LKEY TH_MB TH_PRS TH_TTL TH_VERDICT
# shellcheck shell=bash

rb_execute() {
# >>> live emit execute
# The long one. Everything above this line takes a couple of minutes; the stage
# below it is where an hour goes, so the console needs to say it started and on
# which model.
type LIVE >/dev/null 2>&1 && LIVE execute started "execute started on ${EXECUTE_MODEL:-the stage model}"
# <<< live emit execute

# Boundary 1 of 3: nothing has been edited yet, so standing down here costs the
# plan session and nothing else.
YIELD_CHECK plan
HOLD_STAGE_CHECK plan

# Checkpoint: a resumed branch already carrying a diff skips EXECUTE (a fresh
# branch is always empty here, so the normal path is unchanged).
#
# A LANE CHECKPOINT IS NOT WORK (2026-09-15). Since bin/lane-checkpoint.sh
# commits mid-stage, "the branch carries a diff" no longer implies "the execute
# stage finished" — a lane that died at minute 12 leaves exactly that shape. Skip
# EXECUTE only when a NON-wip commit exists; otherwise the resume below runs the
# stage again, and tells the session what is already on the branch.
if [ -z "${CKPT_START_POINT:-}" ] && ! git diff --quiet "$BASE"...HEAD 2>/dev/null && [ "$(CKPT_NONWIP_COUNT)" -gt 0 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] EXECUTE checkpoint hit — branch already carries commits" >> "$BUILD/pipeline.log"
else
CKPT_WIP_N=$(CKPT_WIP_COUNT)
if [ "$CKPT_WIP_N" -gt 0 ]; then
  CKPT_RESUME_NOTE="RESUME FROM CHECKPOINT — DO NOT START OVER. Branch $BRANCH already carries $CKPT_WIP_N 'wip: checkpoint' commit(s) written by an earlier session of this same ticket that died before it could finish (max-turns, timeout, or a reaped machine). That work is real and it is yours. BEFORE YOU EDIT ANYTHING: run \`git log --oneline $BASE..HEAD\` and \`git diff $BASE...HEAD\` and read what is already done, then continue from there — re-implementing it wastes the whole session and usually conflicts with itself. The checkpoint commits are squashed away automatically before the PR, so leave them alone and just commit your own work on top. "
  echo "$(STAMP) [$PROJECT/$KEY] CHECKPOINT resume: EXECUTE told to continue from $CKPT_WIP_N wip commit(s) on $BRANCH" >> "$BUILD/pipeline.log"
fi
echo "$(STAMP) [$PROJECT/$KEY] EXECUTE ($EXECUTE_MODEL)" >> "$BUILD/pipeline.log"
BB executing
CKPT_START
# >>> execute prompt (tests/run-build-test-home.bh-580-test.sh drives this block)
CC execute "$EXECUTE_MODEL" "${EXECUTE_TIMEOUT_SECS:-7200}" "$BUILD/execute-run.txt" "${CKPT_RESUME_NOTE}${KIND_EXEC_NOTE}${REROUTE_EXEC_NOTE}Execute the plan at $BUILD/plan.md for ticket $KEY, on the current branch ($BRANCH). Follow the repo CLAUDE.md and the iron laws in ~/.claude/CLAUDE.md. MANDATORY: read /root/harness/prompts/build-discipline.md (rules D1-D34, each mined from a real blocked build) and self-check your final diff against it before committing. Four of them are the top block-causes and are non-negotiable: (D1) mutation-check your acceptance tests — break each core behavior once and confirm a test goes red before restoring it; (D2) at least one test drives the production entry point (real route/CLI/component), not only pure seams; (D6) never pipe a verification command through tail/head/grep and claim its result — record true exit codes, never fabricate red.txt; (D7) execute everything you ship once as-delivered: script commands verbatim from their own docs, new pages rendered including the empty state, new screens reachable from the nav. INTENT, BEFORE YOUR FIRST BEHAVIOR-CHANGING EDIT (D34): print exactly one line in your final output — 'INTENT: <where the intended behavior is defined: file:line, the docstring, the spec, or the ticket line you are working from> :: agree' when every source you checked says the same thing, or 'INTENT: <source> :: CONFLICT: <which sides disagree, which one you are trusting, and why>' when they do not. A build that changes no behavior (docs-only, config-only) writes 'INTENT: none (no behavior change)'. The harness reads this line mechanically and the reviewer adjudicates any CONFLICT you declare; picking a side silently — implementing the ticket over a docstring that contradicts it, or the reverse, without saying so — is the thing this exists to stop, and it costs you one line. CODEGRAPH: the line at the TOP of this prompt says whether the graph is available and gives the exact command — use it to locate code and callers BEFORE grep/find, and do not probe for a .codegraph/ directory (the worktree's is empty). TEST-FIRST, in this order: (1) implement the plan's '## Acceptance tests' as real tests FIRST; (2) run them and save the failing output to $BUILD/red.txt — they MUST fail before the feature exists (a test that passes immediately is vacuous: rewrite it until it genuinely exercises the new behavior); (3) implement the feature until those tests pass; (4) run the load-bearing suites named in the repo CLAUDE.md Verification Contract (plus any the plan flags as regression risk) — all green, ONCE, at the END. TEST ECONOMY (speed rule): while iterating, run ONLY the test files affected by your change (pass explicit paths/patterns to the runner); the full load-bearing suites and the production build run exactly ONCE each, as the final verification before your last commit — never inside the edit loop. Same for typecheck: iterate on the files you touch, full check once at the end. If the repo has no test framework, write 'no-test-infra' to $BUILD/red.txt and verify per the plan's manual checklist instead. RUN THE PLAN'S VALIDATE COMMANDS: each task in plan.md carries a 'VALIDATE:' line. Run every one of them as written, at the end, and append to \$BUILD/validate.txt one block per task: the task name, the exact command, its true exit code, and its output at EVIDENCE ECONOMY: for a PASSING command record only its summary/count lines and the last ~15 lines — never a full per-test pass log (a 300KB validate.txt of green checkmarks costs the reviewer real context and proves nothing the summary line doesn't); for a FAILING or surprising command record the full failure output verbatim. A VALIDATE you could not run (needs a browser, needs prod) is recorded as 'NOT RUN: <why>' — never as a pass, and never quietly omitted. Write 'NOT RUN:' at the start of its own line, and start no other line of a block with the words 'not run' in any case, indented or not: the scorer closes that block's evidence window at such a line on purpose, so an exit code recorded after it is never read. This file is what the reviewer reads to tell shipped from claimed. EVIDENCE PROPOSAL: write $BUILD/evidence-proposed.txt, one line per item in the plan's '## Acceptance tests': 'CLAIM <n>: <CONFIRMED|REFUTED|INCONCLUSIVE> :: <artifact path[:line]> :: <note>'. You PROPOSE; the harness decides CONFIRMED deterministically from the artifact. Editing a test to pass, faking a screenshot, or asserting without running is REFUTED by definition and a firing offence for a build, same as a fabricated red.txt. TEST INTEGRITY (iron rule): never weaken, skip, or delete an existing test to get green; if a test is genuinely wrong, fix it and flag exactly why in the commit message. Where the plan has independent workstreams, fan them out to parallel subagents (Task tool). 'npm run build' (or the repo's stricter build config) MUST pass. Commit your work with a descriptive message. Do NOT push, do NOT open a PR, do NOT merge."
# <<< execute prompt
# >>> execute result (tests/run-build-checkpoint-test.sh drives this block)
CKPT_STOP
# A CALL-GUARD REFUSAL IS NOT AN EMPTY SESSION (BH-2305). With execute guarded
# by default, bin/agent-call.sh can refuse this call before any session runs
# (rc 74, its marker on line 1 of the outfile). "no changes produced" would be
# false: nothing was called and nothing was billed. It is a deferral, like the
# plan stage's empty-output verdict; the next build of the key is a new build
# dir with a new prompt, so a new fingerprint.
CG_LINE=$(head -1 "$BUILD/execute-run.txt" 2>/dev/null)
case "$CG_LINE" in
  "AGENT_CALL_REFUSED call-guard "*)
    CG_LINE=$(head -c 300 <<<"$CG_LINE")
    echo "$(STAMP) [$PROJECT/$KEY] EXECUTE refused by the call-guard before the call: $CG_LINE" >> "$BUILD/pipeline.log"
    RESULT "BUILD_DEFERRED execute refused by the call-guard: $CG_LINE"; exit 3 ;;
esac
# BH-5911: an EXECUTE_EMPTY build keeps its transcript ($BUILD/execute-transcript.md)
# and why the model stopped ($BUILD/stop-reason.txt), both scrubbed, through
# bin/lib/execute-empty.sh. The model's text never goes on the RESULT line, which
# readers match by substring: the line stays the fixed text it always was.
command -v ee_on_empty >/dev/null 2>&1 || . "${HARNESS:-/nonexistent}/bin/lib/execute-empty.sh" 2>/dev/null || true
git diff --quiet "$BASE"...HEAD 2>/dev/null && {
  STAGE_LANE_DEFER execute "$BUILD/execute-run.txt"
  command -v ee_on_empty >/dev/null 2>&1 && ee_on_empty "$BUILD"
  RESULT "EXECUTE_EMPTY no changes produced"; exit 5; }
# ...and a branch carrying ONLY checkpoints is EXECUTE_EMPTY too. The session
# died before it committed anything of its own, so there is no finished work to
# review — but unlike the line above, the tree is not gone: it is on origin, and
# the next attempt on this key adopts that branch instead of starting over. Same
# RESULT prefix on purpose (every project prompt already routes EXECUTE_EMPTY to
# one ALERTS line and no board comment); the detail says where the tree is.
if [ "$(CKPT_NONWIP_COUNT)" = 0 ]; then
  STAGE_LANE_DEFER execute "$BUILD/execute-run.txt"
  command -v ee_on_empty >/dev/null 2>&1 && ee_on_empty "$BUILD"
  RESULT "EXECUTE_EMPTY the execute session committed nothing of its own — $(CKPT_WIP_COUNT) lane checkpoint(s) are pushed on $BRANCH and the next build of $KEY resumes from them (or force it with TARGET_BRANCH=$BRANCH)"
  exit 5
fi
CKPT_SQUASH_WIP || CKPT_SQUASH_REFUSED execute
# <<< execute result
fi  # end EXECUTE checkpoint

} # end rb_execute

rb_execute_gates() {

# >>> generated no-commit
# --- BUILDS DO NOT COMMIT DECLARED GENERATED FILES (BH-1680) ------------------
# A path the target repo's `## Generated files` table declares is regenerated
# on merge by the conductor, so committing it here only buys a merge conflict.
# bin/lib/generated-table.sh resets those paths to merge-base($BASE, HEAD) as
# one commit. HERE, before the gates, the review and the first push, so every
# one of them — and the head-bound approval — sees the stripped head; at the
# PR stage it would move the head after the APPROVE, which CKPT_SQUASH_WIP
# refuses for the same reason. Rows flagged `committed` are never stripped. A
# repo with no table, a diff touching nothing declared, or a box without the
# lib is untouched. Never fatal. The PR line is built from the COMMITTED tree,
# so it is only there when the strip really landed.
GEN_NC_LIST="$BUILD/generated-not-committed.txt"
# shellcheck disable=SC1091
if . "${HARNESS:-/root/harness}/bin/lib/generated-table.sh" 2>/dev/null \
   && type gen_nocommit_strip >/dev/null 2>&1; then
  GEN_NC_MSG=$(gen_nocommit_strip "$BASE" "$GEN_NC_LIST" "$KEY")
  echo "$(STAMP) [$PROJECT/$KEY] generated no-commit: ${GEN_NC_MSG:-no declared generated file in this diff}" >> "$BUILD/pipeline.log"
  GEN_NC_LINE=$(gen_nocommit_line "$BASE" "$GEN_NC_LIST")
  if [ -n "$GEN_NC_LINE" ]; then
    SPEC_LINE="${SPEC_LINE:+$SPEC_LINE
}$GEN_NC_LINE"
  fi
else
  echo "$(STAMP) [$PROJECT/$KEY] generated no-commit: bin/lib/generated-table.sh not on this box — skipped" >> "$BUILD/pipeline.log"
fi
# <<< generated no-commit

# >>> prepr gate
# --- PRE-PR GATE (BH-1706) -----------------------------------------------------
# CI runs `bin/checks-run.sh --tree .` and `bin/test-determinism-lint.sh` on
# every cromford PR, and the build did not: a finding in a test file was a
# red CI round after the PR was already open. Here, after the last execute-stage
# commit and BEFORE the push, the mechanical gates and the review, the build
# runs the same two commands on its own worktree. A finding in a file this
# build changed buys the execute agent ONE fix turn (the fix stage, $FIX_MODEL,
# the fix budget) and a re-scan; still red, the PR opens anyway with a
# "Pre-PR gate: unresolved" section and ` | prepr=red` on RESULT. So the head
# that is reviewed and pushed is the fixed head. A repo that ships neither gate
# is skipped; RB_PREPR_FIX_TURNS=0 is detection only. bin/lib/prepr-gate.sh.
PREPR_NOTE=""; PREPR_SECTION=""
if [ -r "$HARNESS/bin/lib/prepr-gate.sh" ] && . "$HARNESS/bin/lib/prepr-gate.sh"; then
  prepr_gate . "$BASE" "$BUILD"
else
  echo "$(STAMP) [$PROJECT/$KEY] prepr gate: bin/lib/prepr-gate.sh missing on $(hostname) — not run, the PR opens as before" >> "$BUILD/pipeline.log"
fi
# <<< prepr gate

# --- THE TREE SURVIVES THIS MACHINE (2026-09-11) ------------------------------
# A pool build lives on an ephemeral Fly machine that can be reaped, killed or
# lost at any point between here and the PR — and until now the ONLY copy of the
# built tree was that machine's disk: project-5 TK-269 lost a finished build
# that way today. Pushing the branch after every commit-producing stage makes
# origin the second copy, so a lost machine costs a re-review at worst instead
# of the whole build.
#
# NEVER FATAL HERE, deliberately. The authoritative push is still the one before
# PR creation — that one decides whether this build claims a PR and defers when
# it is rejected. These are backups, and a backup that can fail a build is worse
# than no backup. Same reasoning as the E2E smoke push below: pushing a BRANCH
# is not a merge and not a deploy, and no PR is created any earlier.
PUSH_BRANCH() { # PUSH_BRANCH <after-what>
  GH_LIVE
  if RB_PUSH -u "$1" 2>>"$BUILD/pipeline.log"; then
    track_pushed
    echo "$(STAMP) [$PROJECT/$KEY] branch pushed after $1 — the tree is on origin, not only on this machine" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] branch push after $1 did not land — not fatal, the pre-PR push is the authoritative one" >> "$BUILD/pipeline.log"
  fi
  return 0
}
PUSH_BRANCH execute
# Boundary 2 of 3: AFTER the push, never before it. The execute stage's work is
# on origin at this line, so the sentence YIELD_CHECK writes about where the
# tree is can name a sha that another machine can actually fetch.
YIELD_CHECK execute
HOLD_STAGE_CHECK execute

# The diff is IMMUTABLE from this line until the first fix round: the execute
# session is finished, its commits are on origin, and nothing between here and
# the lens block writes to the tree. That is what makes the reorder below legal
# — every stage from here to the review is a reader of one fixed diff.
T_GATES=$(STAGE_START)
# >>> mechanical gates (tests/run-build-gates-test.sh runs this block)
# --- Mechanical gates (2026-08-24, deterministic-before-LLM) -----------------
# Two iron rules that were enforced only by asking the reviewer to notice are now
# COUNTED before an LLM sees the diff: test integrity, and red-before-green.
# Both feed their findings into the review prompt either way — a gate that
# passes silently teaches the reviewer nothing.
#
# VOCABULARY: these reuse REVIEW_BLOCKED with a reason rather than introducing
# TAMPER_BLOCKED/REPRO_BLOCKED. New RESULT first-lines would have to be
# propagated to the sweep SOP verdict list, resume-dead-builds' terminal set,
# and harness-console's BUILDING_STAGES/DEAD_STAGES + DASH_API.md — a four-place
# cross-repo change for a distinction the reason line already carries. Every
# existing consumer treats REVIEW_BLOCKED as terminal, which is exactly right
# for both of these.
GATES_NOTE=""

# A mechanical block stops the build dead: no PR, no reviewer, nothing on the
# ticket. That news has to LEAVE the box. Until now a block only appended to
# logs/ALERTS.log, which is box-local — the sole reader is the hub's 15-minute
# heartbeat scrape, so nothing reached the ticket, the board, or the operator
# channel. TK-71 (2026-09-01) sat blocked saying "Needed from a human" while the
# person who filed it watched a silent thread for hours.
#
# beat.sh is the fleet's escalation path (quarantine -> alert-triage -> the
# resolver), and every other lane that has to hand work on already calls it.
# Only a gate that REACHED ITS VERDICT escalates — a crashed scanner degrades to a warning and
# must never page anyone with a verdict nobody actually reached. Never fails the
# caller: an escalation that cannot send must not also cost the reviewer the
# RESULT and evidence that were about to be written.
escalate_block() { # escalate_block <gate> <detail>
  local gate="$1" detail="$2" akey line payload
  [ -x "$HARNESS/bin/beat.sh" ] || return 0
  akey="review-blocked:$PROJECT:$KEY:$(basename "$BUILD")"
  line="[$PROJECT/$KEY] BUILD BLOCKED by the $gate gate - no PR was opened and no reviewer was asked. $detail bin/blocked-resolver.sh adjudicates it on its next tick (one Fable ruling: ACCEPT writes the TEST-CHANGE justification into the record and resumes the review stage, REJECT rebuilds the ticket fresh against current main). Nobody is waiting on a person. Evidence: $BUILD"
  payload=$(jq -nc --arg p "$PROJECT" --arg akey "$akey" --arg l "$line" \
    '{kind:"fleet_alert",project:$p,akey:$akey,line:$l}' 2>/dev/null) || return 0
  [ -n "$payload" ] || return 0
  "$HARNESS/bin/beat.sh" "$payload" >/dev/null 2>&1 || true

  # ...and onto the TICKET. The beat reaches the operator channel; the ticket
  # is what the person who FILED the work reads, and on a GitHub-Issues lane
  # the app's board mirrors issue comments straight into their thread. TK-71's
  # operator asked for an ETA into a thread whose build had been stopped for 50
  # minutes with nothing there saying so.
  #
  # GitHub-Issues lanes ONLY (fleet.conf board prefix "-"). The in-app product
  # boards are CLIENT-FACING — project-9 bans even health tickets on its board —
  # and a build-internal "BUILD BLOCKED" posted there is the same leak class as
  # a stray E2E probe ticket. A key with no issue number maps to no issue, so
  # it posts nothing rather than guessing at a number.
  local prefix repo issue stamp
  prefix=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null) || return 0
  repo=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || return 0
  issue=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$KEY")
  [ "$prefix" = "-" ] && [ -n "$repo" ] && [ -n "$issue" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  # One comment per blocked build. exit 6 is terminal, but a resumed or
  # relaunched attempt must not restate the same block on the operator's thread.
  mkdir -p "$HARNESS/state" 2>/dev/null
  stamp="$HARNESS/state/blocked-commented-$PROJECT-$KEY-$(basename "$BUILD")"
  # AND IN D1 (BH-2317): a `commented` row keyed on the ticket, so a wiped or
  # rebuilt box does not post the notice again. A bin/ without the lib (127)
  # answers from the stamp, exactly as before.
  declare -F cm_has >/dev/null || . "$HARNESS/bin/lib/comment-mark.sh" 2>/dev/null
  local _cmrc=0
  cm_has "blocked $PROJECT $KEY" "$(basename "$BUILD")" "$stamp" 2>/dev/null || _cmrc=$?
  [ "$_cmrc" = 127 ] && { [ -e "$stamp" ] && _cmrc=0; }
  [ "$_cmrc" = 0 ] && return 0
  # THE STAMP STILL FOLLOWS THE POST (BH-781 preserved it; the merge-base line
  # was `gh issue comment … && : > "$stamp" || true`, which already stamped only
  # on success). A rate-limited comment that stamped anyway would leave the
  # block never restated and the thread silent — the exact TK-71 shape this
  # notice exists to stop, and the reason the `&&` survived the conversion
  # unchanged. What BH-781 changed here is only the call: REST instead of the
  # CLI, and the body rides in a FILE so it never reaches argv.
  local body
  body=$(mktemp "${TMPDIR:-/tmp}/blocked-notice.XXXXXX") || return 0
  cat > "$body" <<EOF
**This build is blocked and stopped — an agent is adjudicating it.**

The $gate gate refused it, so no pull request was opened and no reviewer was asked.

$detail

What happens next: \`bin/blocked-resolver.sh\` picks this up on its next tick and buys one adversarial ruling on the flagged evidence. ACCEPT writes the justification into the build record and resumes the review stage; REJECT rebuilds this ticket from scratch against current main. Three rebuilds is the cap, after which the ticket gets one ABANDONED comment listing everything that was tried. Evidence is on the box at \`$BUILD\`.
EOF
  # BH-5799: a posted notice goes in this build's own-post ledger, so the plan
  # thread gate never refuses this build's plan on its own notice when the
  # resolver's ACCEPT resumes the review stage.
  declare -F ptg_own_post >/dev/null || . "$HARNESS/bin/lib/plan-thread.sh" 2>/dev/null
  gh_rest_comment "$repo" "$issue" "$body" \
    && { cm_put "blocked $PROJECT $KEY" "$(basename "$BUILD")" "$stamp" 2>/dev/null || : > "$stamp"
         command -v ptg_own_post >/dev/null 2>&1 && ptg_own_post "$BUILD" "$body"; } || true
  rm -f "$body"
}
# >>> rules pack block
# BH-3513: a rules pack still red after the prepr fix turn stops here, AFTER the
# branch push (the tree is on origin for the resolver) and before any reviewer.
command -v rules_pack_block >/dev/null 2>&1 && rules_pack_block execute
# <<< rules pack block

T_GATE=$(STAGE_START)
TAMPER_OUT=$(BUILD_DIR="$BUILD" "$HARNESS/bin/test-tamper-scan.sh" "$BASE" . 2>&1); TAMPER_RC=$?
printf '%s\n' "$TAMPER_OUT" > "$BUILD/test-tamper.txt"
# Timed BEFORE the case, so a gate that ends the build at exit 6 still leaves its
# minute in pipeline.log — "gates took four minutes" could never say which gate,
# and the repro one below re-runs the added tests at the merge base.
STAGE_END gates.tamper "$T_GATE"
case "$TAMPER_RC" in
  0) # rc 0 with stub-flip lines is a WEAKER clean than the plain one: cases WERE
     # removed, and the scanner cleared them because it found replacements in a
     # file importing the same module (BH-1047). Mechanically that is all it can
     # check — whether the replacement actually tests what the stub promised is a
     # reading job, so the pairing goes to the reviewer rather than passing in
     # silence. A genuinely clean scan keeps the old one-liner: claiming
     # pairings on a diff that removed nothing would be false in that state.
     if grep -q '^stub-flip:' <<<"$TAMPER_OUT"; then
       GATES_NOTE="$GATES_NOTE"$'\n'"TEST-TAMPER GATE: clean (no tests deleted or removed) — $(grep -c '^stub-flip:' <<<"$TAMPER_OUT") stub-flip pairing(s) below; confirm each replacement tests what the stub promised, a missing assertion there is a BLOCK:"$'\n'"$TAMPER_OUT"
     else
       GATES_NOTE="$GATES_NOTE"$'\n'"TEST-TAMPER GATE: clean (no tests deleted or removed)."
     fi ;;
  2) GATES_NOTE="$GATES_NOTE"$'\n'"TEST-TAMPER GATE: deletions found WITH a TEST-CHANGE justification — adjudicate whether it holds, it is not a free pass:"$'\n'"$TAMPER_OUT" ;;
  1) # rc=1 is the scanner's "tampering, unjustified" — but a `set -u` crash or an
     # unexpected error inside the scanner ALSO exits 1, and the two are
     # indistinguishable by exit code alone. So a block additionally requires the
     # scanner to have actually REACHED ITS VERDICT.
     #
     # Keyed on JUSTIFICATION: NONE, which ONLY the rc=1 path prints — the same
     # shape repro-gate uses with GATE FAILED, which is why repro never had this
     # hole. An earlier version keyed on ^BLOCKING_COUNT:, which EVERY reporting
     # path prints including the clean one, so a scanner that reported clean and
     # then died in the dozen lines before exit still blocked, citing evidence
     # that itself said BLOCKING_COUNT: 0. A block contradicted by the proof
     # stapled to it is worse than no gate. The count is asserted too, so a
     # future reword of the verdict line cannot silently re-open this.
     if ! grep -q 'JUSTIFICATION: NONE' <<<"$TAMPER_OUT" \
        || ! grep -qE '^BLOCKING_COUNT: [1-9]' <<<"$TAMPER_OUT"; then
       echo "$(STAMP) [$PROJECT/$KEY] test-tamper scan exited 1 without a verdict (crash?) — NOT blocking" >> "$ALERTS"
       GATES_NOTE="$GATES_NOTE"$'\n'"TEST-TAMPER GATE: scan_failed — exited 1 without reaching its verdict line, so it crashed rather than judged; integrity was NOT checked mechanically. Read the counts below with that in mind: they may be a partial report the scanner never got to stand behind."$'\n'"$TAMPER_OUT"
     else
       echo "$(STAMP) [$PROJECT/$KEY] BLOCKED: tests deleted without a TEST-CHANGE justification" >> "$ALERTS"
       echo "$TAMPER_OUT" >> "$BUILD/pipeline.log"
       escalate_block "test-tamper" "Tests were deleted with no TEST-CHANGE justification: $(head -1 <<<"$TAMPER_OUT")."
       RESULT "REVIEW_BLOCKED test-tamper: $(head -1 <<<"$TAMPER_OUT") — no TEST-CHANGE justification; see $BUILD/test-tamper.txt"
       exit 6
     fi ;;
  # EVERY other code degrades, deliberately. 3 is the scanner's own "I could not
  # run"; 126/127 mean the script is not on this box yet; 137 is an OOM kill; a
  # set -u crash gives something else again. Blocking on those would stall the
  # fleet AND print a reason that is a lie — during a staggered harness-sync a
  # box can carry the new run-build.sh with the old bin/, and every build would
  # die claiming its tests were weakened.
  *) echo "$(STAMP) [$PROJECT/$KEY] test-tamper scan did not run (rc=$TAMPER_RC, not blocking): $(head -1 <<<"$TAMPER_OUT")" >> "$ALERTS"
     GATES_NOTE="$GATES_NOTE"$'\n'"TEST-TAMPER GATE: scan_failed (rc=$TAMPER_RC) — integrity was NOT checked mechanically on this build; read the test diff yourself:"$'\n'"$TAMPER_OUT" ;;
esac

T_GATE=$(STAGE_START)
REPRO_OUT=$("$HARNESS/bin/repro-gate.sh" "$BASE" . 2>&1); REPRO_RC=$?
printf '%s\n' "$REPRO_OUT" > "$BUILD/repro-gate.txt"
STAGE_END gates.repro "$T_GATE"
# >>> live emit tests_red
# `type LIVE` and not a bare call: tests/run-build-gates-test.sh extracts this
# whole region and drives it in a shell that has neither the helper nor the
# jobs client, so an unguarded call would be a command-not-found inside a gate.
case "$REPRO_RC" in
  0) type LIVE >/dev/null 2>&1 && LIVE tests_red proven "acceptance tests run red at the merge base and green here" ;;
  2) type LIVE >/dev/null 2>&1 && LIVE tests_red none "the diff adds no new test files as red-before-green evidence" ;;
  4) type LIVE >/dev/null 2>&1 && LIVE tests_red not-green "red proven at the base, but the tests do not pass on this branch" ;;
  *) type LIVE >/dev/null 2>&1 && LIVE tests_red not-run "the reproduction gate did not reach a verdict (rc=$REPRO_RC) — red-before-green is unproven" ;;
esac
# <<< live emit tests_red
case "$REPRO_RC" in
  0) GATES_NOTE="$GATES_NOTE"$'\n'"REPRODUCTION GATE: proven — the added tests fail at the merge base and pass here." ;;
  2) GATES_NOTE="$GATES_NOTE"$'\n'"REPRODUCTION GATE: the diff adds NO new test files as evidence. Not auto-blocked; whether that is acceptable for this ticket is your call."$'\n'"$REPRO_OUT" ;;
  4) GATES_NOTE="$GATES_NOTE"$'\n'"REPRODUCTION GATE: red proven at base, but the tests do NOT pass on this branch:"$'\n'"$REPRO_OUT" ;;
  1) # Same reasoning as the tamper gate: rc=1 blocks only if the gate reached a
     # verdict. A crash inside it exits 1 too, and "your tests prove nothing" is
     # the wrong thing to tell someone whose gate fell over.
     if ! grep -q 'GATE FAILED' <<<"$REPRO_OUT"; then
       echo "$(STAMP) [$PROJECT/$KEY] repro gate exited 1 without a verdict (crash?) — NOT blocking" >> "$ALERTS"
       GATES_NOTE="$GATES_NOTE"$'\n'"REPRODUCTION GATE: could not run — exited 1 but produced no verdict, so red-before-green is UNPROVEN here:"$'\n'"$REPRO_OUT"
     else
       echo "$(STAMP) [$PROJECT/$KEY] BLOCKED: added tests pass at the merge base — they prove nothing" >> "$ALERTS"
       echo "$REPRO_OUT" >> "$BUILD/pipeline.log"
       escalate_block "reproduction-gate" "The added tests pass against the pre-change code, so they prove nothing."
       RESULT "REVIEW_BLOCKED reproduction-gate: added tests pass against the pre-change code; see $BUILD/repro-gate.txt"
       exit 6
     fi ;;
  # Same reasoning as the tamper catch-all: 3 is the gate's own "could not run
  # honestly", and anything undefined (missing script, OOM, crash) must degrade
  # rather than block on a code nobody designed for.
  *) GATES_NOTE="$GATES_NOTE"$'\n'"REPRODUCTION GATE: could not run (rc=$REPRO_RC), so red-before-green is UNPROVEN here — do not read this as passed:"$'\n'"$REPRO_OUT" ;;
esac
# INTENT GATE (2026-08-26, D34). The other two gates ask whether the evidence
# holds; this one asks whether the builder ever said WHAT it was implementing
# and against which source. A silent pick between two disagreeing sources
# (docstring vs ticket, plan vs schema) is invisible in a diff and expensive to
# discover in review, so the pick is made a declaration.
#
# WARN-FIRST BY DESIGN: INTENT_GATE_ENFORCE defaults to 0 and this gate then
# blocks nothing at all — it only feeds the reviewer. One week of GATES_NOTE
# data decides whether the line is one builders reliably write; only then does
# the flag flip to 1 in env/global.env, the env file this script sources `set -a`
# above (NOT fleet.conf: that is a positional project registry, and a key=value
# line in it would be read as a project named INTENT_GATE_ENFORCE=1 by
# fleet-conf.sh --projects). The flip plan and the readout that decides it are
# written out in bin/intent-gate.sh's header. Even at 1, only an ABSENT line
# blocks: a malformed line and a declared CONFLICT are judgement calls, and this
# gate does not make those.
#
# The flag is read in the shapes people actually write in an env file. A `true`
# that silently means off is the same never-fires shape as a guard that never
# runs, and a typo must say so rather than disable the gate quietly.
case "$(printf '%s' "${INTENT_GATE_ENFORCE:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)     INTENT_ENFORCE=1 ;;
  0|''|false|no|off) INTENT_ENFORCE=0 ;;
  *) INTENT_ENFORCE=0
     echo "$(STAMP) [$PROJECT/$KEY] INTENT_GATE_ENFORCE='${INTENT_GATE_ENFORCE:-}' is not a recognized on/off value — treating as OFF (warn-only)" >> "$ALERTS" ;;
esac
T_GATE=$(STAGE_START)
INTENT_OUT=$("$HARNESS/bin/intent-gate.sh" "$BUILD" 2>&1); INTENT_RC=$?
printf '%s\n' "$INTENT_OUT" > "$BUILD/intent-gate.txt"
STAGE_END gates.intent "$T_GATE"
case "$INTENT_RC" in
  0) GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: the builder declared its source of intent and the sources agree — check the diff against the source it named, not against your own reading of the ticket:"$'\n'"$INTENT_OUT" ;;
  4) GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: a CONFLICT was DECLARED — two sources of truth disagree and the builder chose one. ADJUDICATE IT EXPLICITLY in your findings: say which side you think is right, whether the chosen side matches what the ticket thread actually asked for, and whether the losing side (docstring, spec, comment, sibling code) was updated in this diff or left contradicting it. Do not wave this through as disclosed:"$'\n'"$INTENT_OUT" ;;
  5) GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: the builder claims this diff makes NO BEHAVIOR CHANGE (docs-only/config-only). That is a claim about the diff in front of you — if it touches code paths, the claim is false and that is a finding:"$'\n'"$INTENT_OUT" ;;
  2) # Guarded like rc=1, and for a sharper reason: bash exits 2 on a SYNTAX
     # ERROR, so a gate broken by a bad edit lands here and would otherwise
     # produce a note asserting an INTENT line exists that nothing ever read.
     if ! grep -q 'INTENT_VERDICT: malformed' <<<"$INTENT_OUT"; then
       echo "$(STAMP) [$PROJECT/$KEY] intent gate exited 2 without a verdict (syntax error?) — NOT blocking" >> "$ALERTS"
       GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: could not run — exited 2 without reaching its verdict line (bash exits 2 on a syntax error), so intent was NOT checked mechanically:"$'\n'"$INTENT_OUT"
     else
       GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: an INTENT line is present but MALFORMED — it names no source, no ruling, or both, so intent is undeclared in practice. Never blocking; read the diff for a silent pick between disagreeing sources yourself:"$'\n'"$INTENT_OUT"
     fi ;;
  1) # Same shape as the two gates above: rc=1 also comes out of a crash, and
     # accusing a builder of skipping a line on the word of a gate that fell
     # over is exactly the failure the tamper gate had. The verdict marker is
     # printed on the missing path and nowhere else.
     if ! grep -q 'INTENT_VERDICT: missing' <<<"$INTENT_OUT"; then
       echo "$(STAMP) [$PROJECT/$KEY] intent gate exited 1 without a verdict (crash?) — NOT blocking" >> "$ALERTS"
       GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: could not run — exited 1 without reaching its verdict line, so it crashed rather than judged; intent was NOT checked mechanically:"$'\n'"$INTENT_OUT"
     elif [ "$INTENT_ENFORCE" = 1 ]; then
       echo "$(STAMP) [$PROJECT/$KEY] BLOCKED: no INTENT line in the execute output" >> "$ALERTS"
       echo "$INTENT_OUT" >> "$BUILD/pipeline.log"
       RESULT "REVIEW_BLOCKED intent-gate: the execute output declares no INTENT line (D34); see $BUILD/intent-gate.txt"
       exit 6
     else
       GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: NO INTENT line in the execute output — the builder never said which source of truth it implemented against (D34). Enforcement is off (warn-only) while this is measured, so this is not a block; it IS a reason to check the diff for a silent pick between disagreeing sources:"$'\n'"$INTENT_OUT"
     fi ;;
  # Same degradation contract as the other two: an absent script during a
  # staggered harness-sync, an OOM, a set -u crash — none of those are evidence
  # about the build, and none may block or read as a pass.
  *) GATES_NOTE="$GATES_NOTE"$'\n'"INTENT GATE: could not run (rc=$INTENT_RC), so intent was NOT checked mechanically on this build — do not read this as passed:"$'\n'"$INTENT_OUT" ;;
esac

# --- SCOPE GATE: the diff against the plan's own file list (SDLC item 4) -----
# prompts/plan-contract.md carries the bounce rule in prose — "needing a file
# outside scope = stop and report, never improvise" — and nothing checked it.
# bin/scope-gate.sh diffs the changed files against planned-files.txt (written
# at PLAN time, before an edit was made) and classifies what the builder reached
# for that the plan never named: adjacent / test / spec / foreign, with the
# expensive subset of foreign — .github/workflows, package manifests, prisma/,
# env files, and scripts/migrations when the plan named no migration — reported
# as `protected`.
#
# NEVER BLOCKS HERE. The counts feed the reviewer; the only consequence is a
# tier demotion in the settle section below, behind SCOPE_GATE_ENFORCE (default
# 0, warn-only). A gate that could not run says so and is never read as a pass.
# WHICH BASE THE GATE DIFFS AGAINST. $BASE is a branch NAME, and the local
# branch ref is fast-forwarded once at build start and never again — while the
# pre-PR block below rebases this branch onto **origin/$BASE**, by construction
# only when main moved. After that rebase `git diff main...HEAD` takes the
# merge-base with the STALE local main, so every file the OTHER PRs merged in
# the meantime lands in this build's unplanned/protected counts — a demotion
# for a sibling PR's package.json. So resolve the remote-tracking ref when it
# exists. It is also right BEFORE the rebase: the three-dot form takes the
# merge-base, so an unmoved main reads identically.
SCOPE_BASE="$BASE"
git rev-parse -q --verify "origin/$BASE" >/dev/null 2>&1 && SCOPE_BASE="origin/$BASE"
T_GATE=$(STAGE_START)
SCOPE_OUT=$("$HARNESS/bin/scope-gate.sh" "$BUILD" "$SCOPE_BASE" . 2>&1); SCOPE_RC=$?
printf '%s\n' "$SCOPE_OUT" > "$BUILD/scope-gate.txt"
STAGE_END gates.scope "$T_GATE"
case "$SCOPE_RC" in
  0) GATES_NOTE="$GATES_NOTE"$'\n'"SCOPE GATE: every changed file was in the plan's file set — the diff stayed inside the scope the plan declared:"$'\n'"$SCOPE_OUT" ;;
  2) GATES_NOTE="$GATES_NOTE"$'\n'"SCOPE GATE: the diff touches files the plan never named, classified below. Not a block, and not automatically wrong — the plan's file list is a heuristic superset, a test or a doc is usually the discipline working, and an adjacent file is usually the plan being imprecise. A FOREIGN file is the one to read: work in a part of the repo nobody asked about is the scope-creep fraud class, and the plan contract's own rule is stop-and-report rather than improvise. Judge each one against the ticket:"$'\n'"$SCOPE_OUT" ;;
  1) GATES_NOTE="$GATES_NOTE"$'\n'"SCOPE GATE: unplanned files landed in the PROTECTED set — workflow files, package manifests, prisma/, env files or an unplanned migration. These are the places a surprise is expensive and the plan named none of them. Say explicitly whether each one belongs to this ticket; an unasked-for change here is the unauthorized-action fraud class:"$'\n'"$SCOPE_OUT" ;;
  3) # Not a verdict: no plan file list, no diff, or an unresolvable base. Every
     # changed file would score as unplanned, so scoring it would demote a build
     # for the planner's silence.
     GATES_NOTE="$GATES_NOTE"$'\n'"SCOPE GATE: could not run — the plan named no files, or the diff was unreadable, so the diff was NOT checked against the plan's scope. Do not read this as in-scope:"$'\n'"$SCOPE_OUT" ;;
  *) GATES_NOTE="$GATES_NOTE"$'\n'"SCOPE GATE: could not run (rc=$SCOPE_RC), so the diff was NOT checked against the plan's scope — do not read this as passed:"$'\n'"$SCOPE_OUT" ;;
esac

# --- HOT FILES: what else in the backlog plans to touch these files ----------
# Written by the `# >>> hot files` block above, from bin/overlap-schedule.sh.
# NOT a gate and never a block: it is the one piece of context a reviewer cannot
# get from the diff, because it lives in other tickets' plans.
if [ -s "$BUILD/hot-files.txt" ]; then
  GATES_NOTE="$GATES_NOTE"$'\n'"HOT FILES: this plan touches files that other planned tickets also intend to touch. Not a block, and not a finding on its own. Ask whether each change belongs in a per-ticket file instead of the shared one, and say so in your findings if it does — a shared file edited by four tickets is four rebases and four re-reviews:"$'\n'"$(cat "$BUILD/hot-files.txt")"
fi
# --- KIND: the workflow this build was routed through (SDLC item 7) ---------
# Settled back at plan time; re-read from the file so a resumed build and an
# operator re-reading an archived record tell the reviewer the same thing. The
# reviewer needs it because a bug is judged differently from a feature: the
# question is whether the reproduction proves the defect and the fix lands at
# the root cause, not whether a new capability is well built.
KIND_G=$(sed -n 's/^KIND:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)
KIND_G_REPRO=$(sed -n 's/^KIND_REPRO:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)
case "${KIND_G:-}" in
  bug) if [ "${KIND_G_REPRO:-}" = ok ]; then
         GATES_NOTE="$GATES_NOTE"$'\n'"KIND: bug. The plan carries a '## Reproduction' section — read it, then read \$BUILD/red.txt: the red proof for a defect is that reproduction FAILING on the pre-fix code, and a red.txt that shows something else (or a fresh feature test) means the bug was never proven. Check that the fix lands at the ROOT CAUSE the plan named and not at the call site where the symptom showed, and that the reproduction is in the suite so the defect cannot come back unnoticed."
       else
         GATES_NOTE="$GATES_NOTE"$'\n'"KIND: bug, and the plan's '## Reproduction' is ${KIND_G_REPRO:-not recorded} (missing: $(sed -n 's/^KIND_REPRO_MISSING:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)). Nothing mechanically established that this defect exists, where it lives, or who else calls that code — so the diff is a proposed fix to an unproven bug. Judge it on that basis: does the evidence in the build actually show the failure, and does the change address a cause rather than a symptom?"
       fi ;;
  copy|feature|migration|infra)
       GATES_NOTE="$GATES_NOTE"$'\n'"KIND: $KIND_G. This is how the pipeline classified the ticket and routed the build; if the diff is plainly a different kind of work than that, say so — a migration that arrived as a copy ticket skipped the depth its blast radius deserves." ;;
  *)   GATES_NOTE="$GATES_NOTE"$'\n'"KIND: not classified on this build — the board carried no type, label or title prefix and the plan wrote no KIND line, so no kind-specific routing applied. Do not read it as a feature; read it as unmeasured." ;;
esac
echo "$(STAMP) [$PROJECT/$KEY] GATES tamper=$TAMPER_RC repro=$REPRO_RC intent=$INTENT_RC scope=$SCOPE_RC kind=${KIND_G:-unknown}" >> "$BUILD/pipeline.log"
# <<< mechanical gates
STAGE_END gates "$T_GATES"

# >>> test home diff (tests/run-build-test-home.bh-580-test.sh drives this block)
# EXECUTE-TIME BACKSTOP for the per-ticket test-file rule (#580). The plan-time
# finding above only sees what the planner DECLARED; this one sees what the
# session actually wrote, and checks it against the test files open sibling PRs
# are already changing. It is advisory in the strongest sense: it never refuses,
# never writes a RESULT, and always ends rc 0 — it appends a verdict line to
# $BUILD/test-home.txt and one paragraph to GATES_NOTE, read by the general lens.
#
# EVERY failure path lands on `not-judged`, never on `clean`. A reviewer told
# "no sibling holds these files" off a GitHub read that failed has been told
# something false, and that is worse than being told nothing.
if command -v th_enabled >/dev/null 2>&1 && th_enabled "$HARNESS"; then
  TH_VERDICT=not-judged
  TH_CAND="$BUILD/test-home-cand.txt"
  : > "$TH_CAND"
  # The merge base, not the tip of $BASE: main moves while a branch is open, and
  # a file main added after the fork is still a brand-new file for this diff.
  # `$BASE...HEAD` measures from that same commit, so the two must agree.
  TH_MB=$(git merge-base "$BASE" HEAD 2>/dev/null)
  if [ -n "$TH_MB" ] && TH_NUMSTAT=$(git diff --numstat "$BASE"...HEAD 2>/dev/null); then
    # Candidates: a test file this diff ADDED LINES to, that is not already
    # somebody's per-ticket file, and that existed at the merge base — a brand
    # new file is nobody's shared file and can collide with nothing.
    while IFS=$'\t' read -r TH_A TH_D TH_P; do
      [ -n "${TH_P:-}" ] || continue
      case "${TH_A:-}" in ''|0|-) continue ;; esac
      th_is_test_path "$TH_P" || continue
      th_is_per_ticket "$TH_P" && continue
      git cat-file -e "$TH_MB:$TH_P" 2>/dev/null || continue
      printf '%s\n' "$TH_P" >> "$TH_CAND"
    done <<< "$TH_NUMSTAT"
    if [ ! -s "$TH_CAND" ]; then
      TH_VERDICT=clean
    else
      # Sibling source, cheapest first: a file an operator handed us, then
      # bin/overlap-guard.sh's own PR cache while it is fresh, then ONE
      # harness_pr_list call. The cache is READ, never written — overlap-guard
      # owns that file, and its freshness window is the operator's existing
      # OVERLAP_PR_CACHE_SECS knob (default 120), not a constant of ours.
      TH_PRS=""
      if [ -n "${TEST_HOME_PRS_FILE:-}" ] && [ -s "${TEST_HOME_PRS_FILE:-}" ]; then
        TH_PRS="$TEST_HOME_PRS_FILE"
      else
        # shellcheck source=bin/lib/scheduler-conf.sh
        [ -r "$HARNESS/bin/lib/scheduler-conf.sh" ] && . "$HARNESS/bin/lib/scheduler-conf.sh" 2>/dev/null
        TH_TTL=$(command -v sched_num >/dev/null 2>&1 && sched_num OVERLAP_PR_CACHE_SECS 120 "$HARNESS" || echo 120)
        TH_CACHE="$HARNESS/state/overlap-guard/$PROJECT-prs.json"
        TH_AGE=$(( $(date -u +%s) - $(stat -c %Y "$TH_CACHE" 2>/dev/null || echo 0) ))
        if [ -s "$TH_CACHE" ] && [ "$TH_TTL" -gt 0 ] && [ "$TH_AGE" -ge 0 ] && [ "$TH_AGE" -lt "$TH_TTL" ]; then
          TH_PRS="$TH_CACHE"
        elif [ -n "${GH_AUTH_SLUG:-}" ]; then
          # shellcheck source=bin/lib/gh-pr-list.sh
          [ -r "$HARNESS/bin/lib/gh-pr-list.sh" ] && . "$HARNESS/bin/lib/gh-pr-list.sh" 2>/dev/null
          if command -v harness_pr_list >/dev/null 2>&1 \
             && harness_pr_list "$GH_AUTH_SLUG" open "number,headRefName,isDraft,files" \
                  > "$BUILD/test-home-prs.json" 2>/dev/null \
             && [ -s "$BUILD/test-home-prs.json" ]; then
            TH_PRS="$BUILD/test-home-prs.json"
          fi
        fi
      fi
      # The same projection bin/overlap-guard.sh uses, so a `files` entry in
      # either the REST (`filename`) or the GraphQL (`path`) shape is read.
      if [ -n "$TH_PRS" ] \
         && TH_TSV=$(jq -r '.[]? | select((.isDraft // false) | not)
                            | [(.number|tostring), (.headRefName // "-"),
                               ((.files // []) | map(.path // .filename // empty) | join(","))]
                            | @tsv' "$TH_PRS" 2>/dev/null); then
        TH_VERDICT=clean
        TH_LKEY=$(printf '%s' "$KEY" | tr '[:upper:]' '[:lower:]')
        while IFS=$'\t' read -r TH_NUM TH_BR TH_FILES; do
          [ -n "${TH_FILES:-}" ] || continue
          # Our own branch is not a sibling: a repair round on this ticket is the
          # same work, not a collision. The key has to END there, though —
          # ticket/ab-1, ticket/ab-1-r2 and hotfix/ab-1 are ours, ticket/ab-12
          # is somebody else's ticket that merely starts the same way.
          if [ -n "$TH_LKEY" ]; then
            case "$(printf '%s' "${TH_BR:-}" | tr '[:upper:]' '[:lower:]')" in
              *"$TH_LKEY"|*"$TH_LKEY"[!0-9]*) continue ;;
            esac
          fi
          while IFS= read -r TH_C; do
            [ -n "$TH_C" ] || continue
            printf '%s\n' "$TH_FILES" | tr ',' '\n' | grep -qxF "$TH_C" || continue
            printf 'SHARED: %s (PR#%s) -> %s\n' "$TH_C" "$TH_NUM" "$(th_per_ticket_path "$TH_C" "$KEY")" \
              >> "$BUILD/test-home.txt"
            TH_VERDICT=shared
          done < "$TH_CAND"
        done <<< "$TH_TSV"
      fi
    fi
  fi
  printf 'TEST_HOME_VERDICT: %s\n' "$TH_VERDICT" >> "$BUILD/test-home.txt"
  case "$TH_VERDICT" in
    shared) TH_MSG="a test file this diff changes is ALSO changed by an open sibling PR, so the two will collide on merge; each SHARED line below names the per-ticket file these cases belong in instead." ;;
    clean)  TH_MSG="no shared test file in this diff is held by an open sibling PR." ;;
    *)      TH_MSG="the check could not run (no diff, or no readable PR list), so nothing was established either way — do not read this as clean." ;;
  esac
  GATES_NOTE="${GATES_NOTE:-}"$'\n'"TEST-HOME GATE: $TH_VERDICT — $TH_MSG This is advisory — not a block."
  # The plan-time findings ride here too, so the reviewer sees them even when
  # the diff itself came out clean.
  TH_FIND=$(grep '^SHARED: ' "$BUILD/test-home.txt" 2>/dev/null || true)
  if [ -n "$TH_FIND" ]; then GATES_NOTE="$GATES_NOTE"$'\n'"$TH_FIND"; fi
fi
# <<< test home diff

# SERIAL EDGE, and why it stays one (2026-09-14). The scope gate and the KIND
# note sit inside the block above rather than in the read-only lane below, even
# though neither can block: they are one `git diff --name-only` and one file
# read, so moving them off the critical path would buy the build seconds, and it
# would cost the reviewer their scope evidence — GATES_NOTE is consumed by
# REVIEW_PROMPT and by nothing else, so a note that lands after the lenses
# launch is a note no lens ever reads. The lane below is for the stage whose
# cost is MINUTES.

# Mechanical static-security scan on the changed files (fed to the reviewer;
# fail-open — a missing/broken semgrep never blocks the pipeline).
#
# SERIAL EDGE: REVIEW_PROMPT hands the reviewer this file BY PATH ("if
# $BUILD/semgrep.txt exists, triage every finding in it"), so a scan still
# writing it while a lens reads it is a half-written file presented as evidence.
# It is bounded at 300s and runs over the changed files only.
T_SEMGREP=$(STAGE_START)
if command -v semgrep >/dev/null 2>&1; then
  echo "$(STAMP) [$PROJECT/$KEY] SEMGREP" >> "$BUILD/pipeline.log"
  git diff --name-only "$BASE"...HEAD | while read -r f; do [ -f "$f" ] && echo "$f"; done > "$BUILD/changed-files.txt"
  [ -s "$BUILD/changed-files.txt" ] && timeout 300 semgrep scan --quiet --config p/default \
    $(cat "$BUILD/changed-files.txt") > "$BUILD/semgrep.txt" 2>&1 || true
fi
STAGE_END semgrep "$T_SEMGREP"
# >>> live emit semgrep
# A MISSING semgrep.txt is `skipped`, never `clean`: the scanner is not
# installed on every box, and "nothing found" and "nothing looked" are
# different facts (D11).
if type LIVE >/dev/null 2>&1; then
  if [ ! -f "$BUILD/semgrep.txt" ]; then
    LIVE semgrep skipped "semgrep did not run on this box — no scan, and that is not a clean scan"
  elif [ ! -s "$BUILD/semgrep.txt" ]; then
    LIVE semgrep clean "semgrep clean over $(grep -c . "$BUILD/changed-files.txt" 2>/dev/null || echo 0) changed file(s)"
  else
    LIVE semgrep findings "semgrep: $(grep -c . "$BUILD/semgrep.txt" 2>/dev/null || echo 0) output line(s) over $(grep -c . "$BUILD/changed-files.txt" 2>/dev/null || echo 0) changed file(s) — triage in semgrep.txt"
  fi
fi
# <<< live emit semgrep

# --- MINED CHECKS (checks/, promoted from ruled repeat-finding families) ------
# Families the rule miner has already RULED on, turned into deterministic
# scripts (see checks/README.md). They run here, before the reviewer, for the
# same reason the other mechanical gates do: a family that recurred seven times
# across four projects should be answered by a script in milliseconds, not
# re-litigated by a paid model on the eighth build.
#
# DETECTION ONLY and never blocking. bin/checks-run.sh reads a diff and writes
# stdout — no git write, no gh call, no edit path. The hits become evidence in
# REVIEW_PROMPT that the reviewer ADJUDICATES; they are not a verdict, and a
# runner that is missing or crashes says so honestly rather than reading as
# passed.
#
# SERIAL EDGE, same reason as the scope gate: checks-run.sh is a grep over one
# diff — milliseconds — and its HIT list is evidence the REVIEWER adjudicates.
# Deferring it would move those hits from the lens prompt to the fix round,
# which is a worse review for no time saved.
T_CHECKS=$(STAGE_START)
CHECKS_NOTE="MINED CHECKS: not run on this build (no checks/ runner on this box) — nothing here was checked mechanically; do not read it as passed."
CHECKS_RUNNER=""
for _cr in "$HARNESS/bin/checks-run.sh" "$(dirname "$0")/checks-run.sh"; do
  [ -x "$_cr" ] && { CHECKS_RUNNER="$_cr"; break; }
done
if [ -n "$CHECKS_RUNNER" ]; then
  git diff "$BASE"...HEAD > "$BUILD/checks-input.diff" 2>/dev/null
  "$CHECKS_RUNNER" "$BUILD/checks-input.diff" > "$BUILD/checks.txt" 2>&1
  CHECKS_RC=$?
  rm -f "$BUILD/checks-input.diff"
  case "$CHECKS_RC" in
    0) CHECKS_NOTE="MINED CHECKS: clean — $(tail -1 "$BUILD/checks.txt")" ;;
    1) CHECKS_NOTE="MINED CHECKS: HIT. These are deterministic matches on ADDED lines, promoted from review-finding families that recurred across projects (checks/README.md names each one's evidence). They are a reason to look, not a verdict: adjudicate every one in your findings, and say plainly which are real and which are the documented false positives listed in that check's WHY.md:"$'\n'"$(head -40 "$BUILD/checks.txt")" ;;
    *) CHECKS_NOTE="MINED CHECKS: could not run (rc=$CHECKS_RC), so these families were NOT checked mechanically on this build — do not read this as passed:"$'\n'"$(head -5 "$BUILD/checks.txt")" ;;
  esac
  echo "$(STAMP) [$PROJECT/$KEY] CHECKS rc=$CHECKS_RC" >> "$BUILD/pipeline.log"
fi
GATES_NOTE="$GATES_NOTE"$'\n'"$CHECKS_NOTE"
STAGE_END checks "$T_CHECKS"

} # end rb_execute_gates
