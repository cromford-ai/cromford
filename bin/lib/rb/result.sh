# bin/lib/rb/result.sh — the result stage: the QA-proof gate, demoters, repair rounds, head-bound approval, evidence settle, the verdict artifact, the tier-1 merge gate, and builder-direct close-out.
# Each body is the VERBATIM text of its former slice of bin/run-build.sh. Since the
# BH-572 cut the driver runs it as a bare `rb_<name>` call, in pipeline order.
#
# WHERE SLICE 11 STARTS, AND WHY IT IS NOT THE ANCHOR #478 NAMED. The parent plan
# ended slice 10 at `STAGE_END settle` plus the blank line after it, and started
# slice 11 at `# >>> tier-1 merge gate`. The hotfix migrate stage (`# >>> hotfix
# migrate stage` … `# <<< hotfix migrate stage` plus a blank) landed between those
# two anchors afterwards, so under the parent plan it belongs to neither slice.
# The ticket says every line of the driver belongs to exactly one slice, so
# `rb_close_out` starts at `# >>> hotfix migrate stage`: the block runs after
# settle and sets the TIER the tier-1 merge gate reads, so it sits with the
# close-out. `rb_settle` ends exactly on its anchor plus the blank line, and the
# two bodies meet on that boundary with no line in both and no line in neither.
# Entry functions, pipeline order: rb_settle rb_close_out
# Reads: ALERTS BASE BASE_MAIN BD_NOTE BD_PR BD_PRNUM BD_RLINE BD_TIER BD_VERDICT BD_WHERE
#   BGOUT BGRC BG_HEAD BG_ISSUE BG_NUM BRANCH BUILD BUILDER_DIRECT_META BUILDER_DIRECT_ON
#   BUILDER_EXEC BUILDER_NO_MERGE CLOSES_LINE CONDUCTOR_OWNS_MERGES DIFF_NOTE E2E_VERDICT EVIDENCE
#   EVIDENCE_BLOCK EVIDENCE_GATE_ENFORCE EVIDENCE_SECTION EV_BAD EV_C EV_COUNTS
#   EV_ENFORCE EV_I EV_N EV_R EV_RC EV_T EV_WHY HARNESS HB_NOT HB_OUTCOME HB_PROMPT
#   HB_RETRIED HB_WHY HEADBOUND_ENFORCE HEADBOUND_N HEADBOUND_NOW HEADBOUND_REREVIEW
#   HEADBOUND_SCOPE HEADBOUND_SHA HM_D HM_HOTFIX HM_RC HM_W HOTFIX HOTFIX_ISSUE JOB_ID
#   KEY KIND_D KIND_D_ENFORCE KIND_D_MISS KIND_D_REPRO KIND_GATE_ENFORCE MERGE_SHA
#   MIG_NOTE MQ_COM MQ_ENQUEUED MQ_PRNUM MRG_FLAG PDGOUT PDGRC PRNUM PROJECT
#   PR_CREATE_ERR PR_URL QA_LAST QA_NOTE QA_SCREENS QA_SHOTS RB_MFLAG RB_PIN REBASE_NOTE
#   REOPEN_HOT REOPEN_NOTE REPAIRS REPAIR_MAX REPAIR_ROUNDS REPAIR_TIER_ENFORCE
#   REPAIR_TIER_MAX REVIEW_MODEL SCOPE_BASE SCOPE_COUNTS SCOPE_ENFORCE SCOPE_GATE_ENFORCE
#   SCOPE_HEAD_NOW SCOPE_N SCOPE_OUT SCOPE_PROT SCOPE_RC SCOPE_SCORED_HEAD SCOPE_VERDICT
#   SIZE_NOTE SLUG STACK_NOTE STACK_ON T1_FACTS T1_HEAD T1_LEAD_CLEARED T1_WHO TICKET
#   TIER TIER1_INQ TIER1_STATE TO_LEAD_CLEARED TO_PR_HEAD TO_PR_LOGIN T_BD T_SETTLE
#   VERDICT_PROV VERDICT_WORD VSZ WT _PRM
# Writes: BD_NOTE BD_PR BD_PRNUM BD_RLINE BD_TIER BD_VERDICT BGOUT BG_HEAD BG_ISSUE BG_NUM
#   BUILDER_DIRECT_META CONDUCTOR_OWNS_MERGES EVIDENCE EVIDENCE_SECTION EV_BAD EV_C
#   EV_COUNTS EV_I EV_R EV_T EV_WHY HB_NOT HB_OUTCOME HB_PROMPT HB_RETRIED HEADBOUND_N
#   HEADBOUND_NOW HEADBOUND_SCOPE HEADBOUND_SHA HM_HOTFIX HM_RC IFS KIND_D KIND_D_MISS
#   KIND_D_REPRO MERGE_NOTE MERGE_SHA MQ_COM MQ_ENQUEUED MQ_PRNUM PDGOUT PRNUM PR_URL
#   QA_LAST QA_NOTE QA_SCREENS QA_SHOTS RB_MFLAG RB_PIN REPAIRS REPAIR_MAX SCOPE_BASE
#   SCOPE_COUNTS SCOPE_HEAD_NOW SCOPE_N SCOPE_OUT SCOPE_PROT SCOPE_SCORED_HEAD
#   SCOPE_VERDICT T1_FACTS T1_HEAD T1_WHO TIER TIER1_INQ TIER1_STATE T_BD T_SETTLE
#   VERDICT_PROV VERDICT_WORD VSZ
# shellcheck shell=bash

rb_settle() {
T_SETTLE=$(STAGE_START)

# --- GATE: tier-1 auto-merge requires MECHANICAL QA proof (2026-08-14) --------
# Incident: preview QA silently skipped fleet-wide for days behind the
# "preview unavailable — QA skipped (fail-open)" path while tier-1 merges kept
# landing unQA'd. The fail-open stays CORRECT for the pipeline — a missing
# preview must never block the PR — but it must never feed the AUTO-merge.
# Deterministic rule: tier-1 auto-merge only when qa.md's last line is exactly
# "QA: PASS". Skipped, absent, or malformed QA demotes to tier-2 handling
# (PR opens/stays open; only the build's own unattended merge is withheld — it
# lands through the merge queue).
# This deliberately includes non-UI tier-1 diffs that never enter the QA block:
# no QA proof, no unattended merge. The demotion note rides the FIRST RESULT
# line because builder-runner.sh/fly-pool reap only carry rline (head -1).
#
# EMPTY IS NOT PASS (2026-08-14): the word PASS is not evidence. A gate that only
# reads a verdict line will, over enough runs, be handed one by a QA session that
# loaded nothing — same failure shape as the four green SMOKEs that proved boot
# and not function (08-13). So tier-1 also requires COUNTED work: a coverage line
# claiming at least one screen, and screenshot FILES on disk, which is the one
# piece of evidence the QA session cannot assert its way past.
# Seeded with the post-hoc size note and the large-diff note (BH-5292; both
# empty on a small PR), so the
# measured size rides into the PR body, the evidence block, the verdict row and
# the RESULT line through the one channel every other demoter already uses.
# Two lines on purpose: tests/preview-qa.bh-3438-test.sh J cuts the QA gate out
# of the pipeline starting at the exact SIZE_NOTE seed line.
QA_NOTE="${SIZE_NOTE:-}"
QA_NOTE="$QA_NOTE${DIFF_NOTE:-}"
QA_LAST=$(tail -1 "$BUILD/qa.md" 2>/dev/null)
QA_SCREENS=$(grep -oE 'QA COVERAGE:[[:space:]]*screens=[0-9]+' "$BUILD/qa.md" 2>/dev/null | tail -1 | grep -oE '[0-9]+$')
QA_SHOTS=$(find "$BUILD/qa-shots" -maxdepth 1 -type f 2>/dev/null | wc -l)
if [ "$TIER" = "1" ]; then
  if [ "$QA_LAST" != "QA: PASS" ]; then
    TIER=2; QA_NOTE=" | QA: SKIPPED — recorded tier-2 (risk signal)"
    echo "$(STAMP) [$PROJECT/$KEY] QA: SKIPPED — recorded tier-2 (risk signal) (qa.md last line: '$QA_LAST')" >> "$BUILD/pipeline.log"
  elif [ "${QA_SCREENS:-0}" -lt 1 ] || [ "$QA_SHOTS" -lt 1 ]; then
    TIER=2; QA_NOTE=" | QA: EMPTY PASS — recorded tier-2 (risk signal)"
    echo "$(STAMP) [$PROJECT/$KEY] QA claimed PASS with no counted work (screens=${QA_SCREENS:-none}, shots=$QA_SHOTS) — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
    printf '\nGATE: PASS claimed with screens=%s and %s screenshots on disk — not merge-worthy evidence.\n' "${QA_SCREENS:-none}" "$QA_SHOTS" >> "$BUILD/qa.md"
  fi
fi
# >>> preview-qa signed-out (BH-3438): a project whose previews cannot sign in
# (catalog/preview-qa.conf) was QA'd signed out, so its authed screens were never
# observed and its PASS never feeds an unattended merge. Keyed on the registry,
# not on anything the QA session wrote. A missing lib reads `auth`: no demotion.
if [ "$TIER" = "1" ]; then
  . "$HARNESS/bin/lib/preview-qa-mode.sh" 2>/dev/null || preview_qa_mode() { echo auth; }
  if [ "$(preview_qa_mode "$PROJECT")" = signed-out ]; then
    TIER=2; QA_NOTE="$QA_NOTE | QA: SIGNED-OUT ONLY — recorded tier-2 (risk signal)"
    echo "$(STAMP) [$PROJECT/$KEY] QA: SIGNED-OUT ONLY (preview has no sign-in, catalog/preview-qa.conf) — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
  fi
fi
# <<< preview-qa signed-out

# The browser's answer, on the same terms. merge-sweep refuses to merge over a
# recorded E2E: FAIL, but the tier-1 path below never reaches merge-sweep — it
# merges here — so the demotion has to be repeated or the gate has a bypass.
# A SKIP is deliberately NOT demoting: the QA gate above already withholds
# unattended merges from builds with no browser evidence, and making the same
# absence demote twice would just be the same rule wearing two names.
#
# Last call for the lane, one line above the demoter that reads its verdict: a
# smoke that was capped at the join has had the whole PR-open and QA stretch to
# finish, and whatever it found is applied HERE or not at all. A build that was
# never capped returns from this immediately.
E2E_LATE_SETTLE
if [ "$TIER" = "1" ] && [ "${E2E_VERDICT:-not-run}" = "fail" ]; then
  TIER=2; QA_NOTE="$QA_NOTE | E2E: smoke FAILED on the preview — recorded tier-2 (risk signal)"
  echo "$(STAMP) [$PROJECT/$KEY] E2E smoke FAILED on the preview deployment — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
fi

# Same rule for the tests: red.txt is the proof the acceptance tests were seen to
# FAIL before the feature existed. Missing or empty means nothing proved it, and
# an unattended merge is not the place to find out. "no-test-infra" is an honest,
# accepted answer; silence is not.
if [ "$TIER" = "1" ] && ! grep -qs '[^[:space:]]' "$BUILD/red.txt"; then
  TIER=2; QA_NOTE="$QA_NOTE | TESTS: no red proof — recorded tier-2 (risk signal)"
  echo "$(STAMP) [$PROJECT/$KEY] no red.txt content (tests never proven red) — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
fi

# And for the plan's own checks: if the plan named VALIDATE commands, something
# has to show they ran. An unattended merge on a plan whose checks were never
# executed is exactly the gap these lines exist to close.
# Evidence-economy tripwire (token audit 2026-08-23): a fat validate.txt is
# almost always a full green-suite log pasted against the prompt's economy
# rule, and the review stage reads the whole file into context (~75k tokens
# at the 300KB worst case). Log-only — never truncate, failure evidence wins.
VSZ=$(stat -c %s "$BUILD/validate.txt" 2>/dev/null || echo 0)
[ "$VSZ" -gt 61440 ] && echo "$(STAMP) [$PROJECT/$KEY] validate.txt is ${VSZ}B — evidence-economy rule likely ignored; review pays this in context" >> "$BUILD/pipeline.log"

if [ "$TIER" = "1" ] && grep -q '^[[:space:]]*VALIDATE:' "$BUILD/plan.md" 2>/dev/null \
   && ! grep -qs '[^[:space:]]' "$BUILD/validate.txt"; then
  TIER=2; QA_NOTE="$QA_NOTE | VALIDATE: plan checks never recorded — recorded tier-2 (risk signal)"
  echo "$(STAMP) [$PROJECT/$KEY] plan has VALIDATE lines but validate.txt is empty — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
fi

# >>> reopen trust demoter
# And the one gate that is about the PROJECT rather than this build. Every
# demoter above asks whether THIS build proved itself; none of them ask whether
# the last fortnight of this project's merged work actually held. REOPEN_HOT
# was measured at the top of the run from the reopen_rate row (the hub's
# state/reopen-rate.json as fallback) — a project over the threshold lands
# through the merge queue at tier 2 until its rate falls back.
if [ "$TIER" = "1" ] && [ "${REOPEN_HOT:-0}" = 1 ]; then
  TIER=2; QA_NOTE="$QA_NOTE | TRUST: $REOPEN_NOTE — recorded tier-2 (risk signal)"
  echo "$(STAMP) [$PROJECT/$KEY] TRUST: $REOPEN_NOTE — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
fi
# <<< reopen trust demoter

# >>> repair rounds
# --- Repair cycles as a risk signal (SDLC item 3, 2026-09-06) ---------------
# Every demoter above asks whether this build PROVED something. None of them
# asked how many times it had to be sent back to get there: a diff that needed
# a security fix round, a refuter fix round and a QA fix round settled at the
# same tier-1 auto-merge as one that passed every lens first time. The count is
# the cheapest risk signal already on this box's disk (bin/repair-count.sh names
# the six facts it is made of), and it is also the one number the fleet needs in
# order to LEARN a threshold: it rides into the verdict row, logs/findings.log
# and logs/outcome-metrics.csv, so bin/outcome-metrics.sh can ask whether builds
# that were repaired twice are the builds that get reverted, and
# bin/review-tighten.sh can tune this threshold from that answer instead of from
# a guess.
#
# Env switches, defaults as shipped:
#   REPAIR_TIER_MAX=2       repairs at or above this reach the demotion
#   REPAIR_TIER_ENFORCE=0   WARN-FIRST, the standing rule for a new gate that can
#                           demote: the note is written, the count is recorded
#                           everywhere, the tier is untouched. Set to 1 to arm
#                           the demotion once the correlation above says 2 is the
#                           right number — the threshold is a guess until then,
#                           and a guess that withholds tier-1 merges would slow
#                           the fleet on no evidence.
REPAIRS=0; REPAIR_ROUNDS="-"
IFS=$'\t' read -r REPAIRS REPAIR_ROUNDS < <("$HARNESS/bin/repair-count.sh" "$BUILD" 2>/dev/null)
case "${REPAIRS:-}" in ''|*[!0-9]*) REPAIRS=0; REPAIR_ROUNDS="-" ;; esac
[ -n "${REPAIR_ROUNDS:-}" ] || REPAIR_ROUNDS="-"
# The file fallback, in the build record beside reviewed-sha: the ledger row
# below is the reader, this is what an operator (or a re-render of an archived
# record) has when the ledger has no row for the PR.
printf '%s\t%s\n' "$REPAIRS" "$REPAIR_ROUNDS" > "$BUILD/repairs"
[ "$REPAIRS" -gt 0 ] && echo "$(STAMP) [$PROJECT/$KEY] REPAIRS: $REPAIRS ($REPAIR_ROUNDS)" >> "$BUILD/pipeline.log"
REPAIR_MAX="${REPAIR_TIER_MAX:-2}"
case "$REPAIR_MAX" in ''|*[!0-9]*) REPAIR_MAX=2 ;; esac
if [ "$TIER" = "1" ] && [ "$REPAIRS" -ge "$REPAIR_MAX" ]; then
  if [ "${REPAIR_TIER_ENFORCE:-0}" = 1 ]; then
    TIER=2; QA_NOTE="$QA_NOTE | REPAIRS: $REPAIRS repair round(s) ($REPAIR_ROUNDS) — recorded tier-2 (risk signal)"
    echo "$(STAMP) [$PROJECT/$KEY] REPAIRS: $REPAIRS >= $REPAIR_MAX ($REPAIR_ROUNDS) — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
  else
    QA_NOTE="$QA_NOTE | REPAIRS: $REPAIRS repair round(s) ($REPAIR_ROUNDS) — at the tier-2 threshold (REPAIR_TIER_ENFORCE=0, warn only)"
    echo "$(STAMP) [$PROJECT/$KEY] REPAIRS: $REPAIRS >= $REPAIR_MAX ($REPAIR_ROUNDS) — REPAIR_TIER_ENFORCE=0, warning only" >> "$BUILD/pipeline.log"
  fi
fi
# <<< repair rounds

# >>> scope gate
# --- Unplanned files where a surprise is expensive (SDLC item 4) ------------
# The gate itself ran back in the mechanical-gates block and never blocks; this
# is the only place its verdict has a consequence. The counts are re-read from
# $BUILD/scope-gate.txt rather than carried in a variable so a resumed build
# (which re-runs the gates) and an operator re-reading an archived record score
# the same diff the same way.
#
# ONLY `protected` demotes. adjacent/test/spec/foreign are the reviewer's to
# judge with the classification in front of them; a foreign file can be exactly
# right for a ticket and a tier demotion on a count would just teach planners to
# over-list. The protected set is different: workflow files, package manifests,
# prisma/, env files and an unplanned migration change how the repo BUILDS,
# DEPLOYS or reads its data, and none of them were in the plan a reviewer read.
#
# Env switches, defaults as shipped:
#   SCOPE_GATE_ENFORCE=0     WARN-FIRST, the standing rule for a new gate that
#                            can demote: the note is written, the counts reach
#                            the reviewer, the PR body and the ledger, the tier
#                            is untouched. Set to 1 in env/global.env to arm it.
#   SCOPE_GATE_MAX_LIST=12   how many paths bin/scope-gate.sh names before the
#                            listing says "... and N more" (counts never truncate).
#
# THE VERDICT DESCRIBES THE HEAD THAT MERGES. The gate ran before SEMGREP; the
# review fix round, the security fix, the refutation fix and the QA fix all
# commit after it. A fix round that adds package.json or a workflow file would
# be invisible to the demoter, and the ledger's `scope` field would then ride to
# the merge sweep describing a diff that no longer exists. So: if HEAD moved
# since the SCOPE_HEAD the gate recorded, re-score. It is one `git diff
# --name-only` and no model call. Same principle as item 1's head-bound
# approval. A report with no SCOPE_HEAD line (written before this shipped, or by
# a gate that could not resolve the base) is left exactly as it is.
SCOPE_SCORED_HEAD=$(sed -n 's/^SCOPE_HEAD:[[:space:]]*//p' "$BUILD/scope-gate.txt" 2>/dev/null | tail -1)
SCOPE_HEAD_NOW=$(git rev-parse HEAD 2>/dev/null)
if [ -n "$SCOPE_SCORED_HEAD" ] && [ "$SCOPE_SCORED_HEAD" != "-" ] \
   && [ -n "$SCOPE_HEAD_NOW" ] && [ "$SCOPE_SCORED_HEAD" != "$SCOPE_HEAD_NOW" ]; then
  # Resolved here too, not carried from the gates block: this block is
  # extracted and driven on its own by tests/scope-gate-test.sh, and a resumed
  # build re-enters it. Same reason as the gates block above — after the rebase
  # a stale local `main` would drag every sibling PR's files into the re-score.
  SCOPE_BASE="${BASE:-}"
  git rev-parse -q --verify "origin/${BASE:-}" >/dev/null 2>&1 && SCOPE_BASE="origin/${BASE:-}"
  SCOPE_OUT=$("$HARNESS/bin/scope-gate.sh" "$BUILD" "$SCOPE_BASE" . 2>&1); SCOPE_RC=$?
  printf '%s\n' "$SCOPE_OUT" > "$BUILD/scope-gate.txt"
  echo "$(STAMP) [$PROJECT/$KEY] SCOPE: head moved ${SCOPE_SCORED_HEAD:0:8} -> ${SCOPE_HEAD_NOW:0:8} since the gate ran — re-scored the settled diff (rc=$SCOPE_RC)" >> "$BUILD/pipeline.log"
fi
SCOPE_VERDICT=$(sed -n 's/^SCOPE_VERDICT:[[:space:]]*//p' "$BUILD/scope-gate.txt" 2>/dev/null | tail -1)
SCOPE_COUNTS=$(sed -n 's/^SCOPE_COUNTS:[[:space:]]*//p' "$BUILD/scope-gate.txt" 2>/dev/null | tail -1)
SCOPE_PROT=$(sed -n 's/^SCOPE_PROTECTED:[[:space:]]*//p' "$BUILD/scope-gate.txt" 2>/dev/null | tail -1)
[ -n "$SCOPE_VERDICT" ] || SCOPE_VERDICT=not-recorded
[ -n "$SCOPE_COUNTS" ] || SCOPE_COUNTS="-"
[ -n "$SCOPE_PROT" ] || SCOPE_PROT="-"
# The note lands in QA_NOTE, which RESULT, the PR body and the verdict row all
# carry, and bin/evidence-summary.sh bounds that whole string to 400 chars — so
# a twelve-path protected list would push the OTHER demoters' reasons off the
# end. The count is exact; the path list is a sample.
SCOPE_N=$(printf '%s' "$SCOPE_COUNTS" | grep -oE '(^| )protected=[0-9]+' | tr -d ' ' | cut -d= -f2)
case "${SCOPE_N:-}" in ''|*[!0-9]*) SCOPE_N="?" ;; esac
[ "${#SCOPE_PROT}" -le 120 ] || SCOPE_PROT="${SCOPE_PROT:0:120}…"
# Same reading as INTENT_GATE_ENFORCE: an unrecognised value is OFF and says so,
# because a `true` that silently means off is the never-fires shape again.
case "$(printf '%s' "${SCOPE_GATE_ENFORCE:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)     SCOPE_ENFORCE=1 ;;
  0|''|false|no|off) SCOPE_ENFORCE=0 ;;
  *) SCOPE_ENFORCE=0
     echo "$(STAMP) [$PROJECT/$KEY] SCOPE_GATE_ENFORCE='${SCOPE_GATE_ENFORCE:-}' is not a recognized on/off value — treating as OFF (warn-only)" >> "$ALERTS" ;;
esac
# THE NOTE IS NOT GUARDED BY THE TIER, only the demotion is. A build already at
# tier 2 for another reason (QA skipped, HIGHRISK, repairs) still has to carry
# WHICH protected files the plan never named into the PR body and the verdict
# row — that list is the one fact the merge sweep's reader needs, and leaving it
# only in the review prompt hides it from every later reader.
if [ "$SCOPE_VERDICT" = "protected" ]; then
  if [ "$SCOPE_ENFORCE" = 1 ]; then
    if [ "$TIER" = "1" ]; then
      TIER=2; QA_NOTE="$QA_NOTE | SCOPE: $SCOPE_N unplanned file(s) in the protected set ($SCOPE_PROT) — recorded tier-2 (risk signal)"
      echo "$(STAMP) [$PROJECT/$KEY] SCOPE: protected files outside the plan ($SCOPE_PROT) — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
    else
      QA_NOTE="$QA_NOTE | SCOPE: $SCOPE_N unplanned file(s) in the protected set ($SCOPE_PROT) — already tier-$TIER"
      echo "$(STAMP) [$PROJECT/$KEY] SCOPE: protected files outside the plan ($SCOPE_PROT) — already tier-$TIER" >> "$BUILD/pipeline.log"
    fi
  else
    QA_NOTE="$QA_NOTE | SCOPE: $SCOPE_N unplanned file(s) in the protected set ($SCOPE_PROT) — tier-2 eligible (SCOPE_GATE_ENFORCE=0, warn only)"
    echo "$(STAMP) [$PROJECT/$KEY] SCOPE: protected files outside the plan ($SCOPE_PROT) — SCOPE_GATE_ENFORCE=0, warning only" >> "$BUILD/pipeline.log"
  fi
fi
[ "$SCOPE_VERDICT" = "not-recorded" ] || echo "$(STAMP) [$PROJECT/$KEY] SCOPE: $SCOPE_VERDICT ($SCOPE_COUNTS)" >> "$BUILD/pipeline.log"
# <<< scope gate

# >>> kind demoter
# --- A bug fix with no proof the bug existed (SDLC item 7) ------------------
# The classification happened at plan time; this is the only place it has a
# consequence for the merge. ONE condition demotes: KIND is bug and the plan's
# '## Reproduction' never established the defect. Nothing else here moves a
# tier — a copy or migration classification changes which lenses RAN, and the
# lenses' own verdicts already speak for themselves.
#
# Re-read from $BUILD/kind.txt rather than carried in a variable, like the
# scope demoter next door: a resumed build and an operator re-scoring an
# archived record must reach the same verdict this build acted on.
#
#   KIND_GATE_ENFORCE=0  WARN-FIRST, the shipped default: the note is written
#                        everywhere (RESULT, the PR's evidence block, the
#                        verdict row), the tier stands.
#   KIND_GATE_ENFORCE=1  arms the demotion to tier 2 — and, back at the gates,
#                        the copy skips.
KIND_D=$(sed -n 's/^KIND:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)
KIND_D_REPRO=$(sed -n 's/^KIND_REPRO:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)
KIND_D_MISS=$(sed -n 's/^KIND_REPRO_MISSING:[[:space:]]*//p' "$BUILD/kind.txt" 2>/dev/null | tail -1)
[ -n "$KIND_D" ] || KIND_D=unknown
[ -n "$KIND_D_REPRO" ] || KIND_D_REPRO="n/a"
# QA_NOTE is bounded to 400 chars by bin/evidence-summary.sh and shared with
# every other demoter's reason, so the missing list is a sample and the verdict
# word is the fact.
[ "${#KIND_D_MISS}" -le 90 ] || KIND_D_MISS="${KIND_D_MISS:0:90}…"
case "$(printf '%s' "${KIND_GATE_ENFORCE:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)     KIND_D_ENFORCE=1 ;;
  0|''|false|no|off) KIND_D_ENFORCE=0 ;;
  *) KIND_D_ENFORCE=0 ;;
esac
if [ "$KIND_D" = bug ] && [ "$KIND_D_REPRO" != ok ] && [ "$KIND_D_REPRO" != "n/a" ]; then
  if [ "$KIND_D_ENFORCE" = 1 ]; then
    if [ "$TIER" = "1" ]; then
      TIER=2; QA_NOTE="$QA_NOTE | KIND: bug with a $KIND_D_REPRO reproduction (${KIND_D_MISS:-the whole section}) — recorded tier-2 (risk signal)"
      echo "$(STAMP) [$PROJECT/$KEY] KIND: bug, reproduction $KIND_D_REPRO — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
    else
      QA_NOTE="$QA_NOTE | KIND: bug with a $KIND_D_REPRO reproduction (${KIND_D_MISS:-the whole section}) — already tier-$TIER"
    fi
  else
    QA_NOTE="$QA_NOTE | KIND: bug with a $KIND_D_REPRO reproduction (${KIND_D_MISS:-the whole section}) — tier-2 eligible (KIND_GATE_ENFORCE=0, warn only)"
    echo "$(STAMP) [$PROJECT/$KEY] KIND: bug, reproduction $KIND_D_REPRO — KIND_GATE_ENFORCE=0, warning only" >> "$BUILD/pipeline.log"
  fi
fi
# <<< kind demoter

# >>> head-bound approval
# --- GATE: the approval is bound to the head that merges (SDLC item 1) -------
# review-head is written once, after the general review and its fix round. Every
# commit after it — the security fix round, the refuter fix round, the preview-QA
# fix round — is code NO reviewer and NO suite has seen: the harness suite runs
# once, before the general review, and the tier-1 merge below never compared HEAD
# to the sha that was approved. A QA-fix commit could therefore auto-merge on an
# approval it was never part of.
#
# The drift is answered here, not just noticed: re-run the repo's own suite on
# THIS head and buy ONE more general review of the full diff. APPROVE rebinds the
# approval to this head and the build proceeds at the tier it earned; anything
# else records tier 2, which lands only through the merge queue. The reviewed sha then rides into
# the verdict artifact below, so the merge sweep and the merge queue can park a
# PR whose head moved after the approval on any box, not just this one.
#
# The pre-PR rebase is NOT drift: it carries the approval forward itself (above).
#
# Env switches, defaults as shipped:
#   HEADBOUND_REREVIEW=1  buy the suite + one re-review when the head moved
#                         (0 = skip straight to the demotion; cheaper, and still
#                         never merges code a reviewer has not seen)
#   HEADBOUND_ENFORCE=1   drift that was not re-approved demotes to tier 2
#                         (0 = warn-only kill switch: logged and noted in RESULT,
#                         tier untouched — the same shape as the other demoters)
# THE OUTCOME IS ABOUT A SHA, exactly as the approval is. `n/a` is bare (no head
# was in question); every other word carries the full head it judged, as
# `<word>@<sha>`. Without the suffix a `blocked` outlives the head it was about:
# a human pushes a fix on top of a blocked head and the record still says
# "blocked", so a reader parks a head no reviewer has ever seen — the same
# never-ending park this whole change exists to kill, one commit further along.
HB_OUTCOME=n/a          # n/a | reapproved@<sha> | blocked@<sha> | no-verdict@<sha>
HEADBOUND_SHA=$(cat "$BUILD/review-head" 2>/dev/null || true)
HEADBOUND_NOW=$(git rev-parse HEAD 2>/dev/null || true)
if [ -n "$HEADBOUND_SHA" ] && [ -n "$HEADBOUND_NOW" ] && [ "$HEADBOUND_SHA" != "$HEADBOUND_NOW" ]; then
  # Two things keep "the commits since the approval" honest. First, main's own
  # merged work is EXCLUDED (--not origin/$BASE): after a rebase the range
  # otherwise sweeps in every commit main gained during the build, and the
  # prompt would hand a reviewer other people's PRs as "the part nobody has
  # adjudicated". Second, if the reviewed sha is not even on this branch any
  # more (a rebase whose mapping did not resolve above), there IS no honest
  # range — say so and hand over the whole diff instead of a fabricated one.
  HB_NOT=""
  git rev-parse --verify -q "origin/$BASE" >/dev/null 2>&1 && HB_NOT="--not origin/$BASE"
  if git merge-base --is-ancestor "$HEADBOUND_SHA" "$HEADBOUND_NOW" 2>/dev/null; then
    # shellcheck disable=SC2086
    HEADBOUND_N=$(git rev-list --count "$HEADBOUND_SHA".."$HEADBOUND_NOW" $HB_NOT 2>/dev/null || echo "?")
    HEADBOUND_SCOPE="the commits since $HEADBOUND_SHA (git log --oneline $HEADBOUND_SHA..HEAD $HB_NOT, git diff $HEADBOUND_SHA..HEAD) as the part nobody has adjudicated"
  else
    HEADBOUND_N="?"
    HEADBOUND_SCOPE="the reviewed sha $HEADBOUND_SHA is NO LONGER ON THIS BRANCH — history was rewritten after the approval and no commit range describes the gap, so treat the WHOLE diff as unadjudicated"
  fi
  # A verdict from an EARLIER resume of this build approved an earlier head; it
  # is not evidence about this one. Same rule as every checkpoint in this script.
  rm -f "$BUILD/headbound-review.md"
  echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: ${HEADBOUND_N} commit(s) landed after the reviewed head (${HEADBOUND_SHA:0:8} -> ${HEADBOUND_NOW:0:8})" >> "$BUILD/pipeline.log"
  if [ "${HEADBOUND_REREVIEW:-1}" = 1 ]; then
    # Ground truth first, on THIS head — the same suite the general review reads,
    # re-run because its result is about the tree, and the tree moved.
    HARNESS_SUITE_RUN harness-suite-head.txt head
    echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND RE-REVIEW ($REVIEW_MODEL)" >> "$BUILD/pipeline.log"
    HB_PROMPT="RE-REVIEW ON A MOVED HEAD. Branch $BRANCH was approved at commit $HEADBOUND_SHA, and ${HEADBOUND_N} commit(s) have landed since (head is now $HEADBOUND_NOW) — fix rounds from the security lens, the refuter, or preview QA. No reviewer has read that code and, until the suite re-run above, no suite had run on it. Your job is the general adversarial review of the CURRENT diff (git diff $BASE...HEAD) for ticket $KEY against the plan at $BUILD/plan.md and the iron laws in ~/.claude/CLAUDE.md, with $HEADBOUND_SCOPE. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). A follow-up ticket is filed only for a core-flow defect a user would notice (review.followup_min_level, BH-7123); smoke-level findings stay as [NOTE] lines in the review, and a ticket that is itself a follow-up files no follow-ups. GROUND TRUTH FIRST: read $BUILD/harness-suite-head.txt — the harness re-ran the repo suite on THIS head, and its HARNESS_EXIT line outranks every agent-written claim; a nonzero exit is an instant BLOCK and a verification-integrity finding, and 'no-test-script' or 'could-not-run' (the impact gate's runner could not start or its stage timed out) is not green and not a red suite. Check that the fixes did what the review, security, refuter or QA findings that caused them asked ($BUILD/review.md, $BUILD/security-review.md, $BUILD/refute-review.md, $BUILD/qa.md — read the ones that exist), that no earlier finding was answered by weakening a test or a claim, and that nothing outside those findings rode along. GUARD_SILENCED: a fix round that makes a static guard pass by editing the guard's own rule module, allow-list or fixture (checks/, guardrails/, *allowlist*, *ignore files, semgrep/eslint/gitleaks config, fixtures, snapshots) instead of the code the guard points at is an automatic BLOCK — write GUARD_SILENCED on that finding line. FRAUD CLASSES — hunt these six by name: (weakened-tests) an assertion softened, skipped, deleted, or written so it cannot fail; (false-completion) a claim of done the evidence does not support; (scope-creep) work in the diff nobody asked for; (unauthorized-action) a capability, route, permission, deletion or write the ticket never authorized; (spec-betrayal) an implementation that quietly contradicts the spec or ticket line it claims to implement; (debris) leftover scaffolding, dead code, temp scripts, or stray logging shipped as if it belonged. Tag any finding that is one of them as FRAUD: <class>. Write findings to $BUILD/headbound-review.md. Last line exactly VERDICT: APPROVE or VERDICT: BLOCK."
    CC review "$REVIEW_MODEL" 1200 "$BUILD/headbound-review-run.txt" "$HB_PROMPT"
    # ONE RETRY, AND ONLY FOR SILENCE (2026-09-12, project-5 TK-419/TK-290).
    # An absent verdict file is not a verdict: the agent call died, timed out
    # or wrote nothing. Before this, that silence took the same branch as an
    # explicit BLOCK, so a dead session cost the build its tier-1 lane and
    # left the PR parked on a sha nobody had re-read. A reviewer who ANSWERED
    # "BLOCK" is never retried — re-asking buys the same word for a second
    # Fable call. The retry writes its OWN run file so the provenance of each
    # attempt stays readable.
    HB_RETRIED=0
    if [ ! -s "$BUILD/headbound-review.md" ]; then
      HB_RETRIED=1
      echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: re-review produced no verdict file — one retry" >> "$BUILD/pipeline.log"
      CC review "$REVIEW_MODEL" 1200 "$BUILD/headbound-review-run.txt.2" "$HB_PROMPT"
    fi
  else
    echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: re-review disabled (HEADBOUND_REREVIEW=0)" >> "$BUILD/pipeline.log"
  fi
  # THREE OUTCOMES, NOT TWO. `blocked` (a reviewer read this head and said no)
  # and `no-verdict` (nobody answered) take the SAME demotion — the gate is not
  # weakened here — but they are different facts and a reader has to be able to
  # act on the difference. bin/lib/merge-conductor-lib.sh routes `blocked` to
  # BLOCKED_HUMAN instead of buying yet another re-review; `no-verdict` keeps
  # HEAD_MOVED, which is exactly what the conductor's re-review is for.
  # Both words through the shared reader (bin/lib/verdict-parse.sh, BH-1625):
  # a re-review that quotes the approval it overturns is not a re-approval.
  if verdict_is APPROVE "$BUILD/headbound-review.md" 2>/dev/null; then
    HB_OUTCOME="reapproved@$HEADBOUND_NOW"
    git rev-parse HEAD > "$BUILD/review-head"
    HEADBOUND_SHA="$HEADBOUND_NOW"
    echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: re-review APPROVED ${HEADBOUND_NOW:0:8} — approval rebound to this head" >> "$BUILD/pipeline.log"
  else
    if [ -s "$BUILD/headbound-review.md" ] && verdict_is BLOCK "$BUILD/headbound-review.md" 2>/dev/null; then
      HB_OUTCOME="blocked@$HEADBOUND_NOW"; HB_WHY="not re-approved (BLOCK)"
    elif [ "${HB_RETRIED:-0}" = 1 ]; then
      HB_OUTCOME="no-verdict@$HEADBOUND_NOW"; HB_WHY="no verdict after retry"
    else
      # No retry ran, so "after retry" would be a lie: either the re-review was
      # switched off, or the file holds something that is neither verdict word.
      HB_OUTCOME="no-verdict@$HEADBOUND_NOW"; HB_WHY="no verdict (re-review not retried)"
    fi
    if [ "${HEADBOUND_ENFORCE:-1}" = 1 ]; then
      TIER=2; QA_NOTE="$QA_NOTE | HEAD: ${HEADBOUND_N} commit(s) after the reviewed head, $HB_WHY — recorded tier-2 (risk signal)"
      echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: head ${HEADBOUND_NOW:0:8} $HB_WHY — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
    else
      QA_NOTE="$QA_NOTE | HEAD: ${HEADBOUND_N} commit(s) after the reviewed head, $HB_WHY (HEADBOUND_ENFORCE=0 — warn only)"
      echo "$(STAMP) [$PROJECT/$KEY] HEAD-BOUND: head ${HEADBOUND_NOW:0:8} $HB_WHY, HEADBOUND_ENFORCE=0 — warning only" >> "$BUILD/pipeline.log"
    fi
  fi
fi
# The sha this gate SETTLED on, as the merge sweep's documented fallback for a
# PR the ledger has no row for. A distinct file on purpose: review-head is
# written by the general review and the old pipeline let fix rounds commit past
# it, so a sweep that trusted review-head would be reading a claim nobody made.
[ -n "${HEADBOUND_SHA:-}" ] && echo "$HEADBOUND_SHA" > "$BUILD/reviewed-sha"
# What the gate ANSWERED, and about WHICH HEAD, beside the sha it settled on.
# Always written, including `n/a` for a build that never drifted: absence is what
# a reader of an OLD record sees, and it must not be confused with "this build
# never drifted". Belt and braces with the ledger row below — the file survives
# a worker outage, the ledger row survives a relay that drops the file — the
# same posture reviewed_sha already has.
echo "${HB_OUTCOME:-n/a}" > "$BUILD/headbound-outcome"
# <<< head-bound approval

# >>> evidence demoter (tests/evidence-gate-test.sh drives this block)
# --- The acceptance claims, re-scored on the head that merges (#527) ----------
# The verdicts block up in the review lenses scored the head the REVIEWER read.
# Every fix round since then committed past it, so this is the score that
# describes what merges — the same reason the scope gate re-scores here — and it
# sits BEFORE `evidence settle` so the settle render, the PR body and the
# verdict row all carry the tier this gate leaves behind.
#
# WARN-FIRST, the standing rule for a new gate that can demote: the note is
# written, the counts reach QA_NOTE (and so RESULT, the PR's evidence block and
# the verdict row), the tier is untouched until EVIDENCE_GATE_ENFORCE=1 in
# env/global.env arms it. THE NOTE IS NOT GUARDED BY THE TIER, only the
# demotion is: a build already at tier 2 for another reason still has to carry
# how many of its acceptance claims were not confirmed.
#
# Fail-open everywhere it cannot answer, and each of those is a DIFFERENT fact
# in the log: no lib (a box mid-sync) is not a failed scorer, and neither is
# zero refutations. `not-recorded` counts never demote — a build nobody scored
# is not a build that passed.
if [ -r "$HARNESS/bin/lib/evidence.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/evidence.sh"
fi
if declare -F evidence_score >/dev/null 2>&1; then
  evidence_score "$BUILD" "$BUILD/plan.md" "${BASE:-}" . 2>>"$BUILD/pipeline.log" \
    | tee "$BUILD/evidence-verdicts.txt" >/dev/null; EV_RC=$?
  # Same reading as SCOPE_GATE_ENFORCE next door, adjudicated whether or not the
  # score came back: an unrecognised value is OFF and says so, because a `true`
  # that silently means off is the never-fires shape.
  case "$(printf '%s' "${EVIDENCE_GATE_ENFORCE:-0}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)     EV_ENFORCE=1 ;;
    0|''|false|no|off) EV_ENFORCE=0 ;;
    *) EV_ENFORCE=0
       echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE_GATE_ENFORCE='${EVIDENCE_GATE_ENFORCE:-}' is not a recognized on/off value — treating as OFF (warn-only)" >> "$ALERTS" ;;
  esac
  EV_COUNTS=$(evidence_counts "$BUILD")
  EV_C=$(printf '%s' "$EV_COUNTS" | grep -oE '(^| )confirmed=[0-9]+' | tr -d ' ' | cut -d= -f2)
  EV_R=$(printf '%s' "$EV_COUNTS" | grep -oE '(^| )refuted=[0-9]+' | tr -d ' ' | cut -d= -f2)
  EV_I=$(printf '%s' "$EV_COUNTS" | grep -oE '(^| )inconclusive=[0-9]+' | tr -d ' ' | cut -d= -f2)
  EV_T=$(printf '%s' "$EV_COUNTS" | grep -oE '(^| )total=[0-9]+' | tr -d ' ' | cut -d= -f2)
  EV_BAD=0
  for EV_N in "${EV_C:-}" "${EV_R:-}" "${EV_I:-}" "${EV_T:-}"; do
    case "$EV_N" in ''|*[!0-9]*) EV_BAD=1 ;; esac
  done
  if [ "$EV_BAD" = 1 ]; then
    echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE not-recorded (scorer rc=$EV_RC, counts: ${EV_COUNTS:-none}) — no note, no demotion" >> "$BUILD/pipeline.log"
  else
    # The readout the flip decision is made from (env-templates/global.env.example).
    echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE confirmed=$EV_C refuted=$EV_R inconclusive=$EV_I total=$EV_T" >> "$BUILD/pipeline.log"
    if [ "$((EV_R + EV_I))" -gt 0 ]; then
      EV_WHY="EVIDENCE: $EV_R refuted, $EV_I inconclusive of $EV_T acceptance claims"
      if [ "$EV_ENFORCE" = 1 ]; then
        if [ "$TIER" = "1" ]; then
          TIER=2; QA_NOTE="$QA_NOTE | $EV_WHY — recorded tier-2 (risk signal)"
          echo "$(STAMP) [$PROJECT/$KEY] $EV_WHY — recorded tier-2 (risk signal)" >> "$BUILD/pipeline.log"
        else
          QA_NOTE="$QA_NOTE | $EV_WHY — already tier-$TIER"
          echo "$(STAMP) [$PROJECT/$KEY] $EV_WHY — already tier-$TIER" >> "$BUILD/pipeline.log"
        fi
      else
        QA_NOTE="$QA_NOTE | $EV_WHY — tier-2 eligible (EVIDENCE_GATE_ENFORCE=0, warn only)"
        echo "$(STAMP) [$PROJECT/$KEY] $EV_WHY — EVIDENCE_GATE_ENFORCE=0, warning only" >> "$BUILD/pipeline.log"
      fi
    fi
  fi
else
  echo "$(STAMP) [$PROJECT/$KEY] EVIDENCE: could not run (lib absent)" >> "$BUILD/pipeline.log"
fi
# <<< evidence demoter

# >>> evidence settle
# --- The SETTLED evidence, on the PR and in the ledger (SDLC item 2) ---------
# The block written at PR-open time could not name the tier: QA, the E2E and
# red/VALIDATE demoters, the reopen-rate demoter and the head-bound gate all run
# after the PR exists. Here every one of them has run, so this render is the one
# that says what the build settled at and why — and the PR body is rewritten
# with it, because a body claiming "Tier 1, auto-merging" beside an evidence row
# reading "settled tier 2" is worse than no block at all.
#
# evidence.md is the file fallback the sweep and an operator read when the
# ledger has no row (same posture as reviewed-sha next door). A failed gh edit
# costs the PR nothing beyond keeping its PR-open-time block: it is logged, not
# fatal, and the ledger row below is written either way.
#
# The file list is RE-DERIVED first. The one written at PR-open time is the diff
# as it stood before preview QA, whose fix round commits and pushes new code —
# so on exactly the builds this item exists to make honest (the ones that had to
# be sent back), a settled row built on it would report a diff the branch has
# since outgrown. Same worktree the head-bound gate above just ran git in.
# Written via a temp file: a git that cannot answer leaves the PR-open list
# standing, which is stale but true of some head, rather than truncating it to
# an empty file the renderer would have to read as "not recorded".
if [ -n "${BASE:-}" ]; then
  if git diff --name-only "$BASE"...HEAD > "$BUILD/changed-files.new" 2>/dev/null; then
    mv "$BUILD/changed-files.new" "$BUILD/changed-files.txt"
  else
    rm -f "$BUILD/changed-files.new"
  fi
fi
if [ "${EVIDENCE_BLOCK:-1}" = 1 ]; then
  EVIDENCE=$("$HARNESS/bin/evidence-summary.sh" "$BUILD" "$TIER" "${QA_NOTE:-}" 2>/dev/null || true)
  if [ -n "$EVIDENCE" ]; then
    printf '%s\n' "$EVIDENCE" > "$BUILD/evidence.md"
    MERGE_NOTE=$(MERGE_NOTE_FOR "$TIER")
    EVIDENCE_SECTION=$'\n'"$EVIDENCE"$'\n'
    # >>> pr-body hold gate (tests/pool-hold-yield.bh-6091-test.sh drives this block)
    # The PR is open and RESULT already says so (BH-6091). A held or unreadable
    # ticket skips only this edit: no exit, and RESULT keeps its PR_CREATED.
    # Fails CLOSED, like RB_HOLD_GATE: no hold library is no edit.
    PR_BODY_HOLD=""
    if [ -n "$PR_URL" ]; then
      if command -v hold_push_verdict >/dev/null 2>&1; then
        PR_BODY_HOLD=$(hold_push_verdict "$PROJECT" - "$BRANCH") && PR_BODY_HOLD=""
      else
        PR_BODY_HOLD=$'unreadable\tbin/lib/hold-push.sh missing'
      fi
    fi
    if [ -n "$PR_BODY_HOLD" ]; then
      echo "$(STAMP) [$PROJECT/$KEY] HOLD_YIELD $KEY at pr-body-edit — ${PR_BODY_HOLD#*	}; the PR keeps its PR-open-time body" >> "$BUILD/pipeline.log"
      PR_URL_EDIT=""
    else
      PR_URL_EDIT="$PR_URL"
    fi
    # <<< pr-body hold gate
    if [ -n "$PR_URL_EDIT" ]; then
      PR_BODY_FOR "$EVIDENCE_SECTION" > "$BUILD/pr-body-edit.md"
      # BH-6393: the edited body is self-checked like the opened one (all rules,
      # reason lines for the head as it is now, the open-time fix sections put
      # back, no new model turn), or it would drop what the open phase wrote.
      command -v _pr_self_check_prepush >/dev/null 2>&1 && _pr_self_check_prepush "$BUILD/pr-body-edit.md" edit
      command -v RB_TOKEN_REDACT >/dev/null 2>&1 && RB_TOKEN_REDACT "$BUILD/pr-body-edit.md"
      gh pr edit "$PR_URL" --body "$(cat "$BUILD/pr-body-edit.md")" >/dev/null 2>>"$BUILD/gh-stderr.log" || echo "$(STAMP) [$PROJECT/$KEY] evidence block: gh pr edit failed — the PR keeps its PR-open-time block" >> "$BUILD/pipeline.log"   # gh-guard-allow: a write, not a decision read
    fi
  fi
  # ...and as a row, so the console and any box can read this build's evidence
  # without the build box's disk. Fail-open exactly like every other artifact
  # put: no claim, no worker, no client means no row and nothing else changes.
  if [ -n "$PR_URL" ] && [ -n "${JOB_ID:-}" ] && command -v job_evidence_put >/dev/null 2>&1; then
    # Logged, not swallowed: the failed `gh pr edit` above leaves a pipeline.log
    # line, and a row that silently never lands makes "why does the console show
    # no evidence for this job" unanswerable from the record.
    job_evidence_put "$BUILD" "$TIER" "${QA_NOTE:-}" >/dev/null 2>&1 \
      || echo "$(STAMP) [$PROJECT/$KEY] evidence block: ledger row not written (job_evidence_put failed)" >> "$BUILD/pipeline.log"
  fi
fi
# <<< evidence settle
# >>> live emit tier settled
# AFTER the demoters (QA, migration, head-bound), so this is the tier the merge
# decision below actually acts on rather than the one the heuristic guessed.
type LIVE >/dev/null 2>&1 && LIVE tier "$TIER" \
  "tier $TIER settled${QA_NOTE:+:$QA_NOTE}${MIG_NOTE:+ $MIG_NOTE}"
# <<< live emit tier settled

# --- Phase 7: the VERDICT this merge acts on, as a row ------------------------
# Until now the three inputs to a merge decision lived only as files on the box
# that ran the build: review.md's last line, the .runner sidecars that say which
# lane authored it, and the tier this script computes and then throws away.
# bin/merge-sweep.sh re-derived all three by scraping them, which works exactly
# as long as the record and the sweep are on the same disk.
#
# Recorded HERE, after every demotion has run, because the tier that matters is
# the settled one — writing it at PR-create time would record a tier-1 that QA
# went on to demote. The sweep still scrapes when no row exists, so a fleet with
# an empty ledger merges precisely as it does today.
#
# SINCE BH-858 THIS IS THE UPDATE, NEVER THE FIRST WRITE. `# >>> verdict at
# review` above already recorded the word, the tier and the reviewed sha as
# `settled:false`, so the judgement survives a create that dies. This write adds
# what only exists once the PR is open and the demoters have run — note, scope,
# kind, repairs, headbound — and flips `settled` to true, which is what makes the
# row visible to job_verdict and the merge lanes behind it. The artifact upserts
# on (job_id, artifact_kind), so it replaces that row in place. It keeps its
# PR_URL guard on purpose: a row claiming to be settled while the create was
# failing would be a lie about a pipeline that never finished, and
# bin/review-rescue.sh's backfill settles those at tier 2 instead.
#
# SDLC item 1: the row also carries the sha the approval is BOUND to, so a merge
# path on another box can refuse a PR whose head has moved since. The build
# record's review-head file is the documented fallback for a fleet whose ledger
# has no row for this PR.
# >>> verdict artifact
if [ -n "$PR_URL" ] && [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1; then
  VERDICT_WORD=BLOCK
  # The shared reader (bin/lib/verdict-parse.sh, BH-1625): an anchored VERDICT
  # line in the final block, or BLOCK — including when the reader is missing.
  verdict_is APPROVE -L "$BUILD/review.md" 2>/dev/null && VERDICT_WORD=APPROVE
  # Provenance, by the SAME rule the tier gate above applies: a Claude word only
  # when every review lane that ran was a Claude one. A cheap-lane APPROVE gates
  # the build but never auto-merges, and that fact has to survive off this box.
  # The word is the (runner, model) pair's word: `claude`, `claude-via-openrouter`
  # for the stage model served on the tier-3 lane, or the lane's own name. It is
  # honest about which lane carried the call in every case — a reader that has
  # not been taught the new word holds the PR rather than merging it.
  VERDICT_PROV=claude
  # >>> live emit verdict
  type LIVE >/dev/null 2>&1 && LIVE verdict "$VERDICT_WORD" \
    "verdict $VERDICT_WORD, tier $TIER, reviewed sha ${HEADBOUND_SHA:-n/a}"
  # <<< live emit verdict
  for _PRM in "$BUILD"/review-run.txt.runner "$BUILD"/review2-run.txt.runner \
              "$BUILD"/security-review-run.txt.runner "$BUILD"/security-review2-run.txt.runner \
              "$BUILD"/refute-review-run.txt.runner "$BUILD"/refute-review2-run.txt.runner; do
    [ -f "$_PRM" ] || continue
    rp_out_is_claude "${_PRM%.runner}" && continue
    VERDICT_PROV=$(rp_out_prov "${_PRM%.runner}"); break
  done
  # Empty is OMITTED rather than written as "": a blank reviewed sha would read
  # as a claim about the head, and every reader downstream fails open on absence.
  # `repairs` (SDLC item 3) is ALWAYS written, including as 0: unlike a sha, zero
  # is a real measurement — this build was never sent back — and the correlation
  # bin/outcome-metrics.sh runs needs the clean builds as much as the repaired
  # ones. Rows written before this shipped carry no field at all, which every
  # reader treats as "not measured" rather than as zero.
  # `scope` (SDLC item 4) is the scope gate's verdict word and its counts line —
  # the ledger's copy of "did this diff stay inside the plan". Written on every
  # build, including `not-recorded` for a record whose gate could not run: a
  # missing field would read as in-scope, which is the one thing it never means.
  # `kind` (SDLC item 7) rides on the same terms — `unknown` is a real answer
  # and the one a reader must not confuse with `feature`. The build_kind
  # artifact written at plan time is the row for builds that never get here;
  # this is the copy a merge decision can read beside the tier it produced.
  # `headbound` is the head-bound gate's answer, BOUND TO THE HEAD IT JUDGED —
  # `n/a` (never drifted) or `<word>@<sha>` for reapproved / blocked (a reviewer
  # read that head and said no) / no-verdict (nobody answered, after one retry).
  # The conductor reads it to decide whether a HEAD_MOVED PR is worth another
  # re-review or is a human's problem; without it both look identical from the
  # hub, and without the sha a `blocked` would outlive the head it was about.
  job_artifact_put verdict "$VERDICT_WORD" \
    "$(jq -nc --arg t "$TIER" --arg p "$VERDICT_PROV" --arg r "$(basename "$BUILD")" \
        --arg n "${QA_NOTE:-}" --arg s "${HEADBOUND_SHA:-}" \
        --argjson rp "${REPAIRS:-0}" --arg rr "${REPAIR_ROUNDS:--}" \
        --arg sc "${SCOPE_VERDICT:-not-recorded}" --arg sn "${SCOPE_COUNTS:--}" \
        --arg kd "${KIND_D:-unknown}" --arg kr "${KIND_D_REPRO:-n/a}" \
        --arg hb "${HB_OUTCOME:-n/a}" \
        '{tier:$t,provenance:$p,record:$r,note:$n,repairs:$rp,repair_rounds:$rr,
          scope:$sc,scope_counts:$sn,kind:$kd,kind_repro:$kr,headbound:$hb,settled:true}
         + (if $s == "" then {} else {reviewed_sha:$s} end)' 2>/dev/null)" \
    >/dev/null 2>&1 || true
  # BH-1026.2: the same hand-off as `# >>> verdict at review`, spelled again
  # rather than shared, for the reason every other line between these markers is
  # spelled twice — the suites extract each block and run it under bash on its
  # own, and a helper defined outside the markers would break all of them.
  # MQ_ENQUEUED is what makes the pair produce ONE row: this block is the one
  # that runs when the PR exists, and the block above is the one that runs when
  # the create later fails.
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
# <<< verdict artifact
STAGE_END settle "$T_SETTLE"

} # end rb_settle

rb_close_out() {
# >>> hotfix migrate stage (tests/hotfix-migrate-endpoint-test.sh drives this block)
# A ticket labelled `hotfix` wants its schema change live WITH its code, not two
# cron ticks later. bin/hotfix-migrate.sh does that work and posts a proof comment
# on the PR; this block only decides whether to call it and what its answer means
# for the tier. Same contract as the MIGRATION GATE above: the work always ships,
# only the UNATTENDED merge is withheld when the hotfix could not prove itself.
#
# HOTFIX is the SETTLED script global by the time we get here (the `hotfix
# detect` block above, plus the pr-open second opinion), and the tier-1 merged
# announcement below reads it. So this block READS it and never assigns it: a
# re-derivation here would step over flags/hotfix-lane-off on one path, and on a
# resumed Fly build (HOTFIX=1 from the job env, ticket-meta.json missing or
# stale) it would zero the global and silently lose the merged announcement.
# HOTFIX_ISSUE=1 is the documented hand-run override; ticket-meta.json is the
# second opinion, asked through the lib so the HOTFIX_LABEL knob and the exact
# whole-name match apply, with a raw jq read only when the lib is not loaded.
# The lane kill flag wins over every other answer, including the hand-run one —
# a kill switch an env var can step over is not a kill switch.
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HARNESS/bin/lib/hotfix-lib.sh" ] && ! command -v hotfix_meta_is >/dev/null 2>&1 \
  && . "$HARNESS/bin/lib/hotfix-lib.sh" 2>/dev/null
HM_HOTFIX=0
[ "${HOTFIX:-}" = 1 ] && HM_HOTFIX=1
[ "${HOTFIX_ISSUE:-0}" = 1 ] && HM_HOTFIX=1
if [ "$HM_HOTFIX" = 0 ]; then
  if command -v hotfix_meta_is >/dev/null 2>&1; then
    hotfix_meta_is "$BUILD/ticket-meta.json" "$HARNESS" && HM_HOTFIX=1
  else
    jq -e '.labels[]? | select(.name == "hotfix")' "$BUILD/ticket-meta.json" >/dev/null 2>&1 && HM_HOTFIX=1
  fi
fi
if command -v hotfix_lane_on >/dev/null 2>&1 && [ "$(hotfix_lane_on "$HARNESS")" = 0 ]; then HM_HOTFIX=0; fi
if [ "$HM_HOTFIX" = 1 ] && [ -n "$PR_URL" ] && [ -x "$HARNESS/bin/hotfix-migrate.sh" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] HOTFIX MIGRATE stage" >> "$BUILD/pipeline.log"
  PR_URL="$PR_URL" WT="$WT" BRANCH="$BRANCH" BASE="$BASE" SLUG="$SLUG" \
    "$HARNESS/bin/hotfix-migrate.sh" "$PROJECT" "$BUILD" > "$BUILD/hotfix-migrate.txt" 2>&1
  HM_RC=$?
  case "$HM_RC" in
    0) HM_D=$(jq -r '.decision // "applied"' "$BUILD/hotfix-migrate.json" 2>/dev/null)
       QA_NOTE="$QA_NOTE | HOTFIX-MIGRATE: ${HM_D:-applied}" ;;
    4) : ;;   # no migration files in this PR — the stage has nothing to say
    *) case "$HM_RC" in
         2)  HM_W=flagged ;;
         3)  HM_W=hold ;;
         5)  HM_W=no-path ;;
         75) HM_W=busy ;;
         *)  HM_W=failed ;;
       esac
       TIER=2; QA_NOTE="$QA_NOTE | HOTFIX-MIGRATE: $HM_W (rc $HM_RC) — tier 2"
       echo "$(STAMP) [$PROJECT/$KEY] HOTFIX MIGRATE: $HM_W (rc $HM_RC) — forced tier 2" >> "$BUILD/pipeline.log" ;;
  esac
fi
# <<< hotfix migrate stage

# >>> tier-1 merge gate (tests/conductor-owns-merges-test.sh drives this block)
# flags/conductor-owns-merges (docs/MERGE-CONDUCTOR.md section 9): while it is
# on, bin/merge-conductor.sh is the fleet's only merger. A tier-1 build then
# exits through the PR_CREATED path exactly as BUILDER_NO_MERGE makes it do on
# the pool builders — the PR is reviewed, approved and open, and the conductor
# classifies it READY on its next tick. Off (the default), nothing changes.
#
# MERGIFY does the same thing without a flag, decided by the REPO. On a Mergify
# repo `gh pr merge` below does not feed the queue — it merges around it, onto
# main, unbatched. The conductor is the only actor that knows how to label a PR
# into that queue, so a tier-1 build there exits through PR_CREATED too. (Under
# GitHub's NATIVE queue the same call IS the enqueue, which is why this keys on
# mc_queue_conductor_only and not on mc_queue_enabled.)
CONDUCTOR_OWNS_MERGES=0
if command -v flag_active >/dev/null 2>&1 && flag_active conductor-owns-merges \
   || [ -f "$HARNESS/flags/conductor-owns-merges" ]; then CONDUCTOR_OWNS_MERGES=1; fi
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 1 ]; then
  echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge left to the merge conductor (flags/conductor-owns-merges)" >> "$BUILD/pipeline.log"
fi
# A STACKED PR is never merged from here, at any tier: its base is the parent's
# feature branch, so `gh pr merge` would land this ticket INTO the parent rather
# than into $BASE_MAIN. The conductor holds it as STACKED_WAIT and merges it
# after GitHub retargets it (2026-09-14, stacked child builds).
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ -n "${STACK_ON:-}" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ]; then
  CONDUCTOR_OWNS_MERGES=1
  echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge HELD: this PR is stacked on $STACK_ON — merging it now would land the child into the parent's branch. The conductor merges it once its base is ${BASE_MAIN:-main}." >> "$BUILD/pipeline.log"
fi
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] && mc_queue_conductor_only "$SLUG"; then
  CONDUCTOR_OWNS_MERGES=1
  echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge left to the merge conductor: $SLUG is behind a Mergify merge queue — a direct gh pr merge would BYPASS it" >> "$BUILD/pipeline.log"
fi
# A HUMAN BLOCK ON THE THREAD HOLDS A TIER-1 MERGE TOO (BH-762). This build
# reviewed its own diff and approved it; a person who read the ticket thread in
# the meantime outranks that, and the tier-1 gate is one of the five automatic
# merge paths the block gate covers. The stand-down is the one the flag and
# Mergify already take — exit through PR_CREATED — so the PR stays open, and the
# conductor asks the same thread the same question on its next tick.
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && command -v bg_scan >/dev/null 2>&1; then
  BG_NUM="${PR_URL##*/}"
  BG_HEAD="${HEADBOUND_SHA:-}"
  [ -n "$BG_HEAD" ] || BG_HEAD=$(gh pr view "$PR_URL" --json headRefOid -q .headRefOid 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  # CLOSES_LINE is "Closes #N", or "Refs #N" on a partial build (bin/lib/rb/pr.sh,
  # BH-5798). Both name the ticket thread the gate must read.
  BG_ISSUE=""
  case "${CLOSES_LINE:-}" in
    "Closes #"*) BG_ISSUE="${CLOSES_LINE#Closes #}" ;;
    "Refs #"*) BG_ISSUE="${CLOSES_LINE#Refs #}" ;;
  esac
  BGOUT=$(bg_scan "$SLUG" "$BG_NUM" "$PR_URL" "$BG_HEAD" "$BG_ISSUE"); BGRC=$?
  if [ "$BGRC" != 0 ] && ! bg_enforce; then
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 block gate WARN-ONLY (BLOCK_GATE_ENFORCE=0): $(bg_reason "$BGRC" "$BGOUT" "$BG_HEAD") — merging as it would have before the gate" >> "$BUILD/pipeline.log"
  elif [ "$BGRC" = 1 ]; then
    CONDUCTOR_OWNS_MERGES=1
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge REFUSED block-gate: $(bg_why "$BGOUT" "$BG_HEAD") — the PR stays open and the conductor re-asks the thread every tick" >> "$BUILD/pipeline.log"
    bg_refuse "$SLUG" "$BG_NUM" "$PR_URL" "$BG_HEAD" "$BGOUT" tier-1 \
      || echo "$(STAMP) [$PROJECT/$KEY] block gate could not post the refusal comment on $PR_URL — the merge is refused either way" >> "$BUILD/pipeline.log"
  elif [ "$BGRC" = 2 ]; then
    CONDUCTOR_OWNS_MERGES=1
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge left to the merge conductor: the block gate could not read $BGOUT, so this build does not merge on an unread thread" >> "$BUILD/pipeline.log"
  fi
fi
# AN OPEN DEPENDENCY THIS PR DECLARES HOLDS THE TIER-1 MERGE (BH-629). #615
# landed with "Depends on #459 (PR #609)" in its own body while #609 was open,
# and main then carried a suite sourcing a file main did not have. The stand-down
# is the one the flag, Mergify and the block gate already take — exit through
# PR_CREATED, no new terminal state — so the PR stays open and the conductor
# merges it once the dependency closes. rc 2 stands down too: this build does not
# merge on a body nobody could read.
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && command -v pdg_hold >/dev/null 2>&1; then
  PDGOUT=$(pdg_hold "$SLUG" "${PR_URL##*/}" "$PR_URL" ""); PDGRC=$?
  if [ "$PDGRC" = 0 ]; then
    CONDUCTOR_OWNS_MERGES=1
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge HELD by the PR-dependency gate: this PR declares ${PDGOUT:-a dependency} that is still open — the PR stays open and the conductor merges it once that closes" >> "$BUILD/pipeline.log"
  elif [ "$PDGRC" = 2 ]; then
    CONDUCTOR_OWNS_MERGES=1
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge left to the merge conductor: the PR-dependency gate could not read this PR's dependency, so this build does not merge on an unread body" >> "$BUILD/pipeline.log"
  fi
fi
# THE FACTORY STOP HOLDS THE TIER-1 MERGE (BH-3687). While settings row
# switch.factory-stop is on nothing merges, and this is a direct merge path.
# Same stand-down as every hold here: exit through PR_CREATED, the PR stays
# open, and the conductor (a merge-tagged lane, stopped by the same switch)
# merges it once the switch is off. Ahead of main-red and the ticket fence so a
# stopped build buys none of their reads. No lib, or no readable row: as today.
# shellcheck source=bin/lib/factory-stop.sh
command -v factory_stopped >/dev/null 2>&1 \
  || { [ -r "$HARNESS/bin/lib/factory-stop.sh" ] && . "$HARNESS/bin/lib/factory-stop.sh" 2>/dev/null; }
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && command -v factory_stopped >/dev/null 2>&1 && factory_stopped; then
  CONDUCTOR_OWNS_MERGES=1
  echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge HELD by factory-stop — the PR stays open and the conductor merges it after bin/factory-stop.sh off" >> "$BUILD/pipeline.log"
fi
# A RED MAIN HOLDS THE TIER-1 MERGE TOO (BH-945). A tier-1 build that merges
# itself into a red main compounds the red exactly as any other lane does, and
# the stand-down is the one the flag, Mergify, the block gate and the dep gate
# already take — exit through PR_CREATED, no new terminal state — so the PR
# stays open and the conductor merges it once the flag clears. Two ways
# through, the conductor's own: the fix label, or a whole diff of test files.
# Inert on a Fly builder, which never reaches the merge below at all
# (BUILDER_NO_MERGE=1).
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && command -v main_red_hold >/dev/null 2>&1 \
   && main_red_hold "$PROJECT" "$SLUG" "${PR_URL##*/}" "$PR_URL" "${HEADBOUND_SHA:-}"; then
  CONDUCTOR_OWNS_MERGES=1
  echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge HELD by the main-red freeze: $SLUG main is red (flags/${MRG_FLAG:-main-red}) — the PR stays open and the conductor merges it once the flag clears" >> "$BUILD/pipeline.log"
fi
# THE TICKET AND THE LEAD HOLD THE TIER-1 MERGE TOO (BH-1558). The same two
# questions the conductor, merge-sweep, tier-2 and the box queue ask, from the
# one library (bin/lib/ticket-ownership.sh, sourced at the top of this script):
# a HELD ticket's PR does not merge, and a LEAD-authored PR merges only on a
# lead/human MERGE row standing on its live head — this build's own APPROVE is
# never that. Unreadable holds too. Both log their one line; the stand-down is
# the PR_CREATED exit every gate above takes.
#
# ONE HEAD, READ ONCE (#1603 review F1): T1_HEAD is the PR's live head, read
# here, and it is BOTH the head the lead verdict is asked about AND the head the
# merge below is pinned to (--match-head-commit), so a push between the two is
# refused by GitHub instead of landing a head nobody cleared. A head that cannot
# be read is no pin: the build does not merge unpinned, it stands down. The read
# runs inside `$( )` because it arms the repo's token. T1_LEAD_CLEARED keeps a
# cleared lead PR whose pinned merge fails away from the box queue (F1b).
# Skipped on a Fly builder (BUILDER_NO_MERGE=1), which never reaches the merge.
T1_HEAD=""; T1_LEAD_CLEARED=0
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && [ -z "${BUILDER_NO_MERGE:-}" ] && command -v to_lane_hold >/dev/null 2>&1; then
  T1_FACTS=$(to_pr_author_head "$SLUG" "${PR_URL##*/}" && printf '%s %s' "$TO_PR_LOGIN" "$TO_PR_HEAD")
  T1_WHO="${T1_FACTS% *}"; T1_HEAD="${T1_FACTS##* }"
  if ! [[ "$T1_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    T1_HEAD=""; CONDUCTOR_OWNS_MERGES=1
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge left to the merge conductor: the PR's author and head could not be read, so this build has no head to pin a merge to" >> "$BUILD/pipeline.log"
  elif to_lane_hold "$PROJECT" "$SLUG" "${PR_URL##*/}" "$BUILD/pipeline.log"; then
    CONDUCTOR_OWNS_MERGES=1
  else
    to_lane_lead_hold "$PROJECT" "$SLUG" "${PR_URL##*/}" "$T1_HEAD" "$T1_WHO" "$BUILD/pipeline.log"
    if [ "$?" = 1 ]; then T1_LEAD_CLEARED="$TO_LEAD_CLEARED"; else CONDUCTOR_OWNS_MERGES=1; fi
  fi
  [ "$CONDUCTOR_OWNS_MERGES" = 1 ] && [ -n "$T1_HEAD" ] \
    && echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge HELD by the ticket-ownership fence (the MERGE_HELD line says why) — the PR stays open for the lane that owns it" >> "$BUILD/pipeline.log"
fi
# THE CONDUCTOR'S VERDICT HOLDS THE TIER-1 MERGE TOO (BH-5914). project-6 #27:
# the conductor refused a head (its diff was unreadable, so the iron-law scan
# never ran) and a second lane merged it 20 seconds later. cv_hold
# (bin/lib/conductor-verdict.sh) reads the conductor's jobs-ledger row for this
# head: the head the fence above read, else the reviewed head. A hold takes the
# PR_CREATED exit every gate above takes, and the conductor merges it once it
# clears the head. A worker outage fails open (logged), as the gates above do.
# shellcheck source=bin/lib/conductor-verdict.sh
[ -r "$HARNESS/bin/lib/conductor-verdict.sh" ] && . "$HARNESS/bin/lib/conductor-verdict.sh"
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ -z "${BUILDER_NO_MERGE:-}" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ] \
   && command -v cv_hold >/dev/null 2>&1 \
   && cv_hold "$SLUG" "${PR_URL##*/}" "${T1_HEAD:-${HEADBOUND_SHA:-}}" "$BUILD/pipeline.log" "$(STAMP) [$PROJECT/$KEY] tier-1"; then
  CONDUCTOR_OWNS_MERGES=1
fi
if [ "$TIER" = "1" ] && [ -n "$PR_URL" ] && [ -z "${BUILDER_NO_MERGE:-}" ] && [ "$CONDUCTOR_OWNS_MERGES" = 0 ]; then
  # Fly builder trial (Phase 1): BUILDER_NO_MERGE=1 (set by fly/builder-runner.sh)
  # forces every build to exit via the PR_CREATED path — builders structurally
  # never run `gh pr merge`; merges happen only on watcher boxes. Inert (unset)
  # on Orgo, so watcher behavior here is byte-identical.
  # No --delete-branch: it does local git ops that fail inside worktrees
  # ("main is already used by worktree") and mislabel a SUCCESSFUL remote
  # merge as failure (TK-34 #326, 2026-07-24). Merge remotely, then verify
  # actual PR state — GitHub is the truth, not gh's exit code.
  # THE METHOD COMES FROM THE REPO (BH-1313/BH-1428). Sourced HERE, inside the
  # gate block the suites extract and run, for the same reason as in
  # bin/review-prs.sh: this is a pool-side merge and the lib is not loaded
  # anywhere else on this path. `--squash` stands when the lib is absent.
  # shellcheck source=bin/lib/gh-pr-merge.sh
  [ -r "$HARNESS/bin/lib/gh-pr-merge.sh" ] && . "$HARNESS/bin/lib/gh-pr-merge.sh"
  RB_MFLAG=--squash
  command -v gh_pr_merge_flag >/dev/null 2>&1 \
    && RB_MFLAG=$(gh_pr_merge_flag "$SLUG" "${PR_URL##*/}" "$BUILD/pipeline.log" "$PROJECT/$KEY tier-1")
  RB_PIN=(); [ -n "$T1_HEAD" ] && RB_PIN=(--match-head-commit "$T1_HEAD")   # BH-1558 F1: the head the fence read
  gh pr merge "$PR_URL" "$RB_MFLAG" ${RB_PIN[@]+"${RB_PIN[@]}"} 2>>"$BUILD/gh-stderr.log" || true   # gh-guard-allow: a write, not a decision read
  sleep 5
  # On a repo behind GitHub's native merge queue that call ENQUEUED the PR (gh
  # exits 0, the PR stays OPEN). Reading only `state` said "not merged" and sent
  # it to the box merge queue, which would try to land it again every 20 minutes
  # while the queue was already building it. Queued is its own outcome, and the
  # question goes through the PROVIDER-AWARE reader so a PR sitting in a Mergify
  # queue (which never sets isInMergeQueue) gets the same answer.
  TIER1_STATE=$(gh pr view "$PR_URL" --json state -q .state 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
  TIER1_INQ=false
  if [ "${TIER1_STATE:-}" != "MERGED" ] && mc_pr_queued "$PR_URL"; then TIER1_INQ=true; fi
  if [ "${TIER1_STATE:-}" = "MERGED" ]; then
    BB pr_merged "$TIER" "APPROVE" "$PR_URL" true "$(printf 'REVIEW:\n%s' "$(tail -c 900 "$BUILD/review.md")")"
    # Post-merge prod gate, detached — never holds the build slot (2026-07-27).
    MERGE_SHA=$(gh pr view "$PR_URL" --json mergeCommit -q .mergeCommit.oid 2>/dev/null)   # gh-guard-allow: read not converted by BH-770.1; #770 tracks it
    [ -n "$MERGE_SHA" ] && "$HARNESS/bin/deploy-request.sh" "$PROJECT" "$SLUG" "$MERGE_SHA" "$BUILD"
    CLOSE_ISSUE_AFTER_MERGE "$PR_URL"   # issue-driven projects: close the ticket explicitly (2026-09-12)
# >>> hotfix merged announce
    # The third and last of the hotfix lane's announcements (#368). Tier-1 only:
    # a tier-2 hotfix lands through the merge conductor, which is #369's half of
    # this lane and calls the same helper from its own merged path.
    #
    # THE HOTFIX GUARD IS THE POINT, not the `command -v`. hotfix_announce checks
    # the kill flag and its dedupe marker and nothing else — the lib header says
    # the CALLER decides what is a hotfix — so an unguarded call here would page
    # the console and Telegram with `HOTFIX merged` for EVERY plain tier-1 merge
    # on every box in the fleet. HOTFIX is the same script global the seen, WIP,
    # body and label regions read, and the pr-open region has already re-set it
    # to 1 on the ticket-meta second-opinion path, so by here it is the settled
    # answer for this build.
    if [ "${HOTFIX:-}" = 1 ] && command -v hotfix_announce >/dev/null 2>&1; then
      hotfix_announce "$HARNESS" "$PROJECT" "$KEY" merged "$PR_URL merged" >/dev/null 2>&1 || true
    fi
# <<< hotfix merged announce
    RESULT "PR_MERGED $PR_URL"
    # >>> live emit handoff merged
    type LIVE >/dev/null 2>&1 && LIVE handoff merged "tier 1: merged by the gated step in this build — $PR_URL"
    # <<< live emit handoff merged
  elif [ "${TIER1_INQ:-}" = true ]; then
    # Enqueued, not merged, and not a failure: the merge conductor watches the
    # PR to MERGED and then does the issue close, the merge_sha artifact and the
    # deploy request with the REAL merge sha. Nothing is enqueued on the box
    # queue — that would race GitHub's queue for the same PR. The RESULT keeps
    # the PR_CREATED prefix every discovery in the fleet greps for (the merge
    # sweep, the conductor's record lookup, pipeline-health) and says QUEUED in
    # the note, which is the same shape the QA/migration notes already use.
    echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge ENQUEUED in $SLUG's merge queue — the merge conductor settles it" >> "$BUILD/pipeline.log"
    BB pr_created "$TIER" "APPROVE" "$PR_URL" false "$(printf 'REVIEW:\n%s' "$(tail -c 900 "$BUILD/review.md")")"
    RESULT "PR_CREATED $PR_URL | QUEUED: in the repo's merge queue, the merge conductor settles it${PREPR_NOTE:-}${HOLD_YIELD_NOTE:-}${NH_GOLIVE_SUFFIX:-}"
    # >>> live emit handoff conductor
    type LIVE >/dev/null 2>&1 && LIVE handoff conductor "tier 1: enqueued in the repo's merge queue, the merge conductor settles it"
    # <<< live emit handoff conductor
  else
    # Wave 4a: a failed clean merge (usually a sibling conflict) goes to the
    # merge queue, which rebases onto fresh main and lands it serially.
    PRNUM=$(grep -oE '[0-9]+$' <<<"$PR_URL")
    if [ "${T1_LEAD_CLEARED:-0}" = 1 ]; then
      # BH-1558 F1b: a LEAD PR cleared on T1_HEAD whose pinned merge did not
      # land. The box queue would land it later, on whatever head then stands,
      # and asks no lead question — so it is left for the lead instead.
      echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge of lead PR #$PRNUM cleared on ${T1_HEAD:0:12} did not land — left for the lead (no box-queue entry: a newer head needs its own lead verdict)" >> "$BUILD/pipeline.log"
    elif [ -n "$PRNUM" ]; then
      mkdir -p "$HARNESS/state/merge-queue/$PROJECT"; touch "$HARNESS/state/merge-queue/$PROJECT/$PRNUM"
      (setsid "$HARNESS/bin/merge-queue.sh" "$PROJECT" </dev/null >/dev/null 2>&1 &)
      echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge failed — enqueued #$PRNUM to merge queue" >> "$BUILD/pipeline.log"
      # >>> live emit handoff merge-queue
      type LIVE >/dev/null 2>&1 && LIVE handoff merge-queue "tier 1: the clean merge failed, #$PRNUM is queued for a serial rebase-and-land"
      # <<< live emit handoff merge-queue
    else
      echo "$(STAMP) [$PROJECT/$KEY] tier-1 merge failed, leaving PR open" >> "$ALERTS"
    fi
    BB pr_created "$TIER" "APPROVE" "$PR_URL" false "$(printf 'REVIEW:\n%s' "$(tail -c 900 "$BUILD/review.md")")"
    RESULT "PR_CREATED $PR_URL${PREPR_NOTE:-}${HOLD_YIELD_NOTE:-}${NH_GOLIVE_SUFFIX:-}"
  fi
else
  # THE LEDGER SAYS THE SAME THING THE RESULT SAYS. Every other tier-1 branch
  # above only beats pr_created with a URL in hand; this one did not, so a build
  # whose create failed used to beat `stage:pr_created, pr_url:""` one line
  # before RESULT() recorded PR_CREATE_FAILED — two records of one build
  # disagreeing, and the ledger's was the one claiming a PR (#574).
  if [ -n "$PR_URL" ]; then
    BB pr_created "$TIER" "APPROVE" "$PR_URL" false "$(printf 'PLAN:\n%s\n\nREVIEW:\n%s' "$(head -c 600 "$BUILD/plan.md")" "$(tail -c 900 "$BUILD/review.md")")"
  else
    BB pr_create_failed "$TIER" "" "" false "${PR_CREATE_ERR:-gh pr create produced no url}"
  fi
  # >>> live emit handoff
  # Guarded on PR_URL for the same reason BB splits above (#745): "the PR is
  # open and approved" is a claim about an artifact, and this branch is reached
  # by builds that have none.
  if type LIVE >/dev/null 2>&1; then
    if [ -n "$PR_URL" ]; then
      LIVE handoff hub-sweep "tier $TIER: the PR is open and approved, the hub merge sweep lands it"
    else
      LIVE handoff failed "no PR to hand off: the create call failed"
    fi
  fi
  # <<< live emit handoff
  RESULT "PR_CREATED $PR_URL$QA_NOTE$MIG_NOTE$REBASE_NOTE${STACK_NOTE:-}${PREPR_NOTE:-}${HOLD_YIELD_NOTE:-}${NH_GOLIVE_SUFFIX:-}"
fi
# <<< tier-1 merge gate

# >>> builder-direct close-out
# THE BUILDER FINISHES ITS OWN JOB (W2-B, the operator 2026-09-14: "4000 builder boxes
# submitting PRs all day; every throughput ceiling is a bug").
#
# THE FUNNEL THIS REMOVES. A pool machine's result went to the HUB
# (bin/fly-results-ingest.sh -> state/remote-results/<p>/KEY.json), waited for
# the owning box's next triage tick to stage it, waited again for that paid
# session to read the RESULT and post the client's comment, and only then did a
# */5 merge-conductor tick look at the PR. Three clocks and two machines, with
# the hub sitting in the middle of every hop — which at 4000 builders is the
# bottleneck AND the single point of failure. The "remote-result unconsumed
# >30m" alerts in bin/pipeline-health.sh are that funnel backing up.
#
# This machine has the project env, the board token and the finished record. So
# it does the last four things itself, in the order a reader would want them:
#   1. the terminal result as the job's final PATCH (pr_url, sha, tier, verdict,
#      cost), so the ledger is the delivery and the relay is a copy;
#   2. the tier-1 hand-off row for a PR it is structurally forbidden to merge;
#   3. the board close-out — the comment and the status move — which is the part
#      a CLIENT sees, and therefore the part every clock above was costing;
#   4. the doorbell, so the conductor does not wait out a tick.
#
# BUILDERS ONLY. BUILDER_EXEC is set by fly/builder-runner.sh and by nothing
# else, so a watcher build is untouched: its own triage session sweeps its own
# build dirs on the same box, and there is no hub in that path to take out of it.
#
# THE NOTE ON THE RESULT LINE IS THE HAND-OFF. A close-out that posted must be
# visible to every path that could post a SECOND one, and the only thing the
# relay json, the ledger feed and the hub's ingest all spell identically is the
# first line of RESULT. So a posted close-out appends the marker there
# (bin/lib/builder-direct.sh owns it — one definition), the hub's ingest reads
# it as "already delivered", and bin/run-triage.sh's staging marks such a dir
# COMMENTED instead of handing it to a session. A second comment lands on a
# CLIENT's ticket and there is no taking it back, so it gets two guards.
#
# NOTHING HERE CAN FAIL A BUILD. Every step is best-effort and says so in
# pipeline.log; a step that does not land leaves the RESULT unmarked, which is
# exactly the state the relay path already knows how to carry.
#
# KILL FLAG: BUILDER_DIRECT=0 in env/global.env or the environment, or
# flags/builder-direct-off. Then this block never runs, no marker is appended,
# and the relay path is byte for byte what it is today.
if [ -n "${BUILDER_EXEC:-}" ] && [ "${BUILDER_DIRECT_ON:-0}" = 1 ] && [ -s "$BUILD/RESULT" ]; then
  T_BD=$(STAGE_START)
  # The last GitHub calls this build makes, and the furthest from the env bundle
  # in time: the close-out's issue comment runs after QA and the tier settle, well
  # past the hour a bundled installation token lives.
  GH_LIVE
  BD_RLINE=$(head -1 "$BUILD/RESULT")
  # The change list, from this build's own history against the base it built on.
  # A stacked child's base is its parent's branch, so this is only ITS change —
  # the same diff the reviewers read and the same one the PR body lists.
  git log -12 --format='- %s' "$BASE"..HEAD > "$BUILD/what.txt" 2>/dev/null || true
  BUILDER_DIRECT_META=$(bd_facts "$BUILD" "$(git rev-parse HEAD 2>/dev/null)" "${TIER:-}" 2>/dev/null) || BUILDER_DIRECT_META=""

  # 1) THE TERMINAL RESULT, STRAIGHT TO THE LEDGER. Written here rather than
  # left to the EXIT trap's one-line summary: these are the facts the owning box
  # and the conductor read, and they should be in the row the moment the build
  # concludes. The trap still closes the row's STATUS — facts here, lifecycle
  # there — and it reads BUILDER_DIRECT_META so it cannot overwrite them.
  if [ -n "${JOB_ID:-}" ] && [ -n "$BUILDER_DIRECT_META" ] && command -v job_result_put >/dev/null 2>&1; then
    if job_result_put "$JOB_ID" "$BUILDER_DIRECT_META" >/dev/null 2>&1; then
      echo "$(STAMP) [$PROJECT/$KEY] builder-direct: terminal result written to job $JOB_ID" >> "$BUILD/pipeline.log"
    else
      echo "$(STAMP) [$PROJECT/$KEY] builder-direct: the terminal PATCH did not land — the EXIT trap's summary and the hub relay still carry this result" >> "$BUILD/pipeline.log"
    fi
  fi

  # 2) THE TIER-1 HAND-OFF, AS A ROW. A builder never merges (BUILDER_NO_MERGE),
  # so an approved tier-1 PR needs the owning box's merge queue to land it —
  # which is the one thing bin/fly-results-ingest.sh reached into that box over
  # ssh to arrange. merge_queue_put is idempotent on (project, pr), so the hub
  # doing it too is a duplicate and never a second merge.
  # A STACKED PR is deliberately excluded: its base is the parent's feature
  # branch, and the box queue would land the child INTO the parent. The merge
  # conductor holds those as STACKED_WAIT (docs/MERGE-CONDUCTOR.md section 3).
  # THE TIER IS THE SETTLED ONE, not review.md's. Everything outside this process
  # can only read the file, which says TIER: 1 for a build the QA, scope, size,
  # repair and trust demoters then moved to tier 2 — this is the one place that
  # holds the number those produced, so this is the one place that can be right.
  BD_TIER=$(printf '%s' "${BUILDER_DIRECT_META:-}" | jq -r '.tier // ""' 2>/dev/null)
  BD_VERDICT=$(printf '%s' "${BUILDER_DIRECT_META:-}" | jq -r '.verdict // ""' 2>/dev/null)
  BD_PR=$(printf '%s' "${BUILDER_DIRECT_META:-}" | jq -r '.pr_url // ""' 2>/dev/null)
  if [ "$BD_TIER" = "1" ] && [ "$BD_VERDICT" = "APPROVE" ] && [ -n "$BD_PR" ] \
     && [ -z "${STACK_ON:-}" ] && command -v merge_queue_put >/dev/null 2>&1; then
    BD_PRNUM=$(grep -oE '[0-9]+$' <<<"$BD_PR")
    if [ -n "$BD_PRNUM" ] && merge_queue_put "$PROJECT" "$BD_PRNUM" "${SLUG:-}" "tier-1 APPROVE from builder $KEY" >/dev/null 2>&1; then
      echo "$(STAMP) [$PROJECT/$KEY] builder-direct: tier-1 APPROVE -> merge-queue row for #$BD_PRNUM" >> "$BUILD/pipeline.log"
    fi
  fi

  # 3) THE BOARD CLOSE-OUT. bin/board-closeout.sh words exactly one shape — a
  # build that ended with a PR — and refuses everything else (exit 4), so a
  # deferral or a PLAN_BLOCKED still travels to a session that can say WHY.
  # ONLY a posted comment marks the RESULT: the marker is what suppresses the
  # sweep's own close-out, so claiming it on a failed POST would lose the
  # client's comment entirely.
  if BD_WHERE=$("$HARNESS/bin/board-closeout.sh" "$PROJECT" "$TICKET" "$KEY" "$BUILD" 2>>"$BUILD/pipeline.log"); then
    BD_NOTE=$(bd_note "${BD_WHERE#POSTED }")
    printf '%s%s\n' "$BD_RLINE" "$BD_NOTE" > "$BUILD/RESULT.bd" \
      && tail -n +2 "$BUILD/RESULT" >> "$BUILD/RESULT.bd" \
      && mv "$BUILD/RESULT.bd" "$BUILD/RESULT"
    # Re-read: the marker is part of the terminal facts every other path reads,
    # so the row must carry the line the file now has.
    BUILDER_DIRECT_META=$(bd_facts "$BUILD" "$(git rev-parse HEAD 2>/dev/null)" "${TIER:-}" 2>/dev/null) || true
    [ -n "${JOB_ID:-}" ] && [ -n "$BUILDER_DIRECT_META" ] && command -v job_result_put >/dev/null 2>&1 \
      && job_result_put "$JOB_ID" "$BUILDER_DIRECT_META" >/dev/null 2>&1
    echo "$(STAMP) [$PROJECT/$KEY] builder-direct: board close-out posted ($BD_WHERE)" >> "$BUILD/pipeline.log"
  else
    echo "$(STAMP) [$PROJECT/$KEY] builder-direct: no board close-out from this machine — the RESULT is unmarked, so the owning box's sweep posts it exactly as today" >> "$BUILD/pipeline.log"
  fi

  # 4) THE DOORBELL. Identifiers only (docs/EVENTS.md section 3) and entirely
  # best-effort: until the worker grows POST /api/wakes this is a fail-open
  # no-op, and GitHub's own pull_request webhook already rings the conductor.
  if [ -n "${BD_PR:-}" ] && [ -n "${SLUG:-}" ] && command -v wake_put >/dev/null 2>&1; then
    wake_put "$SLUG" pr "$(grep -oE '[0-9]+$' <<<"$BD_PR")" >/dev/null 2>&1 || true
  fi
  STAGE_END builder-direct "$T_BD"
fi
# <<< builder-direct close-out
} # end rb_close_out
