#!/bin/bash
# Pre-plan stage: runs the Fable PLAN for the NEXT queued ticket while another
# build's execute/review occupies the CPU. Output is consumed by run-build.sh
# (it skips its own plan stage when a pre-plan exists). Added 2026-07-23.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=preplan-tick
PROJECT="${1:?project}"; TICKET="${2:?ticket-id}"; KEY="${3:?ticket-key}"
# Both overridable so this stage can be DRIVEN against a scratch tree, the same
# reason bin/run-build.sh takes them. Cron sets neither, so production resolves
# to exactly the paths it always has.
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
PLANDIR="$HARNESS/plans/$PROJECT-$KEY"
WT="${REPOS_ROOT:-/root/repos}/.preplan-$PROJECT"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
LOG="$HARNESS/logs/preplan.log"

# >>> preplan lock
# THE LOCK IDENTITY IS WHAT SPECULATIVE MODE CHANGES, so it is resolved before
# the lock is opened and before env is sourced (2026-09-14, the operator).
#
# Legacy (PREPLAN_SPECULATIVE=0): one pre-plan at a time under one box-wide
# lock — "it's light, but no reason to stack Fable sessions".
# Speculative: the cap moved to bin/preplan-tick.sh (PREPLAN_PARALLEL), which is
# where a cap belongs, and this lock went back to being what every other lock in
# this harness is — a DEDUPE on the key (the operator, 2026-09-13: "we never lock and
# serialize"). Two ticks racing one ticket is a duplicate to drop; a second
# ticket is not something to make wait behind the first.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh"
command -v preplan_speculative >/dev/null 2>&1 || preplan_speculative() { echo 0; }
mkdir -p "$HARNESS/locks" 2>/dev/null
if [ "$(preplan_speculative "$HARNESS")" = 0 ]; then
  exec 9>"$HARNESS/locks/preplan.lock"
else
  exec 9>"$HARNESS/locks/preplan-$PROJECT-$KEY.lock"
fi
flock -n 9 || exit 0
# <<< preplan lock

# >>> test-home rule
# THE PLANNER IS TOLD THE RULE, not just corrected afterwards (#580). The
# pre-plan list rewrite in bin/planned-files-cheap.sh only fires for a ticket
# whose body named a test file; every other ticket gets the rule here, in the
# prompt it is planned from, so the plan's files-to-touch names THIS ticket's
# test file instead of the shared suite a sibling is already editing.
# Fail-open: a box whose sync has not landed the lib interpolates nothing and
# pre-plans exactly as it did before.
# shellcheck source=bin/lib/test-home-lib.sh
[ -r "$HERE/lib/test-home-lib.sh" ] && . "$HERE/lib/test-home-lib.sh"
command -v th_plan_rule >/dev/null 2>&1 || th_plan_rule() { :; }
command -v th_fragment_rule >/dev/null 2>&1 || th_fragment_rule() { :; }
# BH-5800: a pre-plan for bin/ or worker/ answers the failure-mode checklist too,
# or the build's plan gate sends it to a repair pass.
[ -r "$HARNESS/bin/lib/plan-failure-modes.sh" ] && . "$HARNESS/bin/lib/plan-failure-modes.sh" 2>/dev/null
# BH-6299: files to touch are edits only; run-only paths go under ## Verify.
# shellcheck source=bin/lib/verify-list.sh
[ -r "$HERE/lib/verify-list.sh" ] && . "$HERE/lib/verify-list.sh" 2>/dev/null
# <<< test-home rule

set -a; . "$HENV/global.env"; [ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"; set +a

# >>> hub-no-build
# THE HUB RUNS NO AGENT BUILD WORK (BH-393, docs/HUB-THINNING-PLAN.md).
# bin/preplan-tick.sh runs here every 2 minutes and — because
# `fleet-conf.sh --projects-on-box box-hub` prints nothing — falls back
# to EVERY project, so it pre-planned any project with a checkout on the hub.
# That is the leak this closes. Placed after the lock (two ticks racing one key
# still dedupe) and before PLANDIR is created, so a refused pre-plan leaves no
# plans/<project>-<KEY> dir for a later run-build.sh to adopt.
# shellcheck source=bin/lib/hub-box.sh
for _hb in "$(dirname "$0")/lib/hub-box.sh" "$HARNESS/bin/lib/hub-box.sh"; do
  [ -r "$_hb" ] && { . "$_hb"; break; }
done
command -v hub_no_build_refuse >/dev/null 2>&1 || hub_no_build_refuse() { return 1; }
if hub_no_build_refuse preplan "$KEY"; then
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] pre-plan refused: the hub runs no agent build work" >> "$LOG"
  exit 3
fi
# <<< hub-no-build
# >>> preplan spend guard
# DEDUP BEFORE THE BILLABLE CALL (BH-475 review, ~/.claude/rules/
# metered-api-dedup.md). This is the choke point: every pre-plan the fleet buys
# goes through the agent-call below, so the "have we already paid for this key
# and got nothing?" question is asked HERE, before the worktree, the primer and
# the model. bin/preplan-tick.sh asks it too — that saves the PREPLAN_PARALLEL
# slot — but a lane launched any other way (an operator, the legacy path) must
# not be able to walk past it.
#
# Fail-open by absence, like every other lib here: a box whose sync has not
# landed preplan_terminal pre-plans exactly as it did before.
if command -v preplan_terminal >/dev/null 2>&1 \
   && PP_TERM=$(preplan_terminal "$HARNESS" "$PROJECT" "$KEY"); then
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_SKIP $PP_TERM" >> "$LOG"
  exit 0
fi
# THE STALE RE-PLAN CAP, AT THE SAME CHOKE POINT (BH-1053). bin/preplan-tick.sh
# asks preplan_deferred before it spends a PREPLAN_PARALLEL slot, and that saves
# the slot — not the money. A lane launched any other way (an operator by hand,
# the legacy path, a launcher written next month) walked straight past the cap
# and re-bought a key the ledger had already terminalized, which is the whole
# failure BH-1016 exists to stop. The question belongs where the spend is.
#
# rc 0 and one line: a deferred key is a DECISION — the BUILD stage plans it
# from scratch, exactly as it did before pre-planning existed — never a failure.
# Asked BEFORE `mkdir -p "$PLANDIR"` below, so a refused pre-plan leaves no
# directory a later bin/run-build.sh could adopt. Fail-open by absence, like
# every other lib call here: a box whose sync has not landed these functions
# pre-plans exactly as it did before.
if command -v preplan_deferred >/dev/null 2>&1 \
   && command -v preplan_replan_fp >/dev/null 2>&1 \
   && preplan_deferred "$HARNESS" "$PROJECT" "$KEY" "$(preplan_replan_fp "$HARNESS" "$KEY")"; then
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_SKIP deferred — the stale re-plan cap terminalized this key; the build stage will plan" >> "$LOG"
  exit 0
fi
# <<< preplan spend guard
# >>> preplan hold gate
# A HELD TICKET IS NEVER PRE-PLANNED (BH-1526): a pre-plan is a Fable session
# bought for a build the ticket has said must not happen, and the plan dir it
# leaves is what a later run-build.sh would adopt. Same choke point and the same
# rc 0 + one line as the spend guard above. The reading is bin/lib/hold.sh's; a
# read that did not answer pre-plans as today.
# shellcheck source=bin/lib/ticket-ownership.sh
[ -r "$HERE/lib/ticket-ownership.sh" ] && . "$HERE/lib/ticket-ownership.sh"
if command -v to_build_hold >/dev/null 2>&1 && PP_HOLD=$(to_build_hold "$PROJECT" "$TICKET" "$KEY"); then
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_SKIP held — ${PP_HOLD#*	}; a held ticket is never pre-planned" >> "$LOG"
  exit 0
fi
# <<< preplan hold gate
# >>> preplan small skip (P2, 2026-09-25)
# The same question bin/preplan-tick.sh asks, at the choke point, for the same
# reason the spend guard above is here too: the tick's answer saves the slot, a
# launch from anywhere else must still not buy a pre-plan that adds nothing
# (triage sized it S, or it is copy/docs work). No mid-build list here — that
# costs a ledger read, and the tick already asked it. rc 0 and one line, BEFORE
# the plan dir exists, so a skipped key leaves nothing a build could adopt.
if command -v preplan_small_reason >/dev/null 2>&1 \
   && PP_SMALL=$(preplan_small_reason "$HARNESS" "$PROJECT" "$KEY"); then
  preplan_small_log "$HARNESS" "$PROJECT" "$KEY" "$PP_SMALL" "$LOG"
  exit 0
fi
# <<< preplan small skip
# >>> preplan untrusted input (BH-4491)
# A pre-plan is a plan model call, so a ticket the untrusted-input gate would
# refuse must not buy one either. Only when untrusted_input.mode is block (or
# cannot be read): the scan is grep over one REST read, and under log/warn the
# build's own gate decides with the same notice in its prompt. Flagged or
# unreadable -> one line and rc 0, BEFORE the plan dir exists, no comment: the
# build's gate (bin/lib/rb/plan.sh) is the one that speaks on the ticket.
# shellcheck source=bin/lib/untrusted-input.sh
[ -r "$HERE/lib/untrusted-input.sh" ] && . "$HERE/lib/untrusted-input.sh"
if command -v ui_mode >/dev/null 2>&1 && _ui_deps; then
  ui_mode
  case "$UI_MODE" in
    block|unknown)
      PP_UI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preplan-untrusted.XXXXXX") || PP_UI_DIR=""
      PP_UI_RC=2; [ -n "$PP_UI_DIR" ] && { PP_UI_RC=0; ui_check "$PROJECT" "$KEY" "$TICKET" "$PP_UI_DIR" || PP_UI_RC=$?; }
      PP_UI_RULES=$( [ -n "$PP_UI_DIR" ] && cut -f1 "$PP_UI_DIR/untrusted-scan.tsv" 2>/dev/null | sort -u | paste -sd, - )
      [ -n "$PP_UI_DIR" ] && rm -rf "$PP_UI_DIR"
      if [ "$PP_UI_RC" != 0 ]; then
        mkdir -p "$(dirname "$LOG")" 2>/dev/null
        if [ "$PP_UI_RC" = 1 ]; then
          echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_SKIP untrusted-input flagged (rules=$PP_UI_RULES, mode=$UI_MODE) — no pre-plan bought, the build's gate decides" >> "$LOG"
        else
          echo "$(STAMP) [$PROJECT/$KEY] PREPLAN_SKIP untrusted-input unreadable (${UI_NOTE:-read failed}, mode=$UI_MODE) — no pre-plan bought" >> "$LOG"
        fi
        exit 0
      fi ;;
  esac
fi
# <<< preplan untrusted input
# >>> per-key worktree (2026-09-14, the TK-265/TK-266 collision)
# In speculative mode the tick launches up to PREPLAN_PARALLEL pre-plans and two
# of them can be the SAME project (project-1 TK-265 + TK-266, 04:42Z): both ran
# `git worktree add` on the one per-project path above and collided on its
# index.lock, so neither planned for three ticks while the cap counted them as
# launched. One worktree per key; removed at the end so they do not pile up.
# Legacy mode keeps the per-project path, byte for byte.
if [ "$(preplan_speculative "$HARNESS")" = 1 ]; then
  WT="${REPOS_ROOT:-/root/repos}/.preplan-$PROJECT-$KEY"
fi
# <<< per-key worktree
BASE="${BASE_BRANCH:-main}"

# The ticket's activity fingerprint, in the shape bin/run-build.sh:TICKET_FP
# writes it, so the value this records and the value that build compares it
# against are the same string. A boardless project (fleet prefix "-") and any
# API weather print nothing, and absence fails OPEN downstream exactly as it
# does there — a board outage must not stop a pre-plan from being used.
TICKET_FP() {
  local base prefix tok
  base=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" prod 2>/dev/null)
  prefix=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)
  [ -n "$base" ] && [ "$base" != "-" ] || return 0
  tok=$(grep -hoE '^[A-Z_]*INTERNAL_API_TOKEN=.*' "$HENV/$PROJECT.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')
  [ -n "$tok" ] || return 0
  curl -s -m 20 -H "Authorization: Bearer $tok" -H "User-Agent: curl/8" "$base$prefix/tickets/$TICKET" 2>/dev/null \
    | jq -r '(.ticket // .) as $t | "\($t.lastActivityAt // "")|\($t.updatedAt // "")|\($t.turnChangedAt // "")|\((.comments // $t.comments // []) | length)"' 2>/dev/null
}

# read-only worktree pinned to origin/"$BASE" so the planner never sees the
# in-flight build's working tree
if [ ! -d "$WT" ]; then
  git -C "${REPOS_ROOT:-/root/repos}/$PROJECT" worktree add --detach "$WT" origin/"$BASE" >>"$LOG" 2>&1 || exit 1
fi
git -C "$WT" fetch origin "$BASE" >>"$LOG" 2>&1
git -C "$WT" reset --hard origin/"$BASE" >>"$LOG" 2>&1

mkdir -p "$PLANDIR"
echo "$(STAMP) [$PROJECT/$KEY] pre-plan start" >> "$LOG"
# The prompt below tells the planner to read state/$PROJECT-context.md FIRST.
# Write it before the planner looks, from the read-only worktree it is about to
# plan against. Fail-open: no primer is a worse plan, not a failed pre-plan.
"$HARNESS/bin/verification-map.sh" render "$PROJECT" --repo "$WT" >> "$LOG" 2>&1 \
  || echo "$(STAMP) [$PROJECT/$KEY] verification-map render failed — pre-planning without a primer" >> "$LOG"
# >>> model-route (BH-1510.2): model_routes role `plan` (PLAN_MODEL still wins
# when set). No route = rc 75 BEFORE the call, so no attempt is recorded and the
# key is offered again once a route exists; bin/lib/model-route.sh alerted it.
. "$HARNESS/bin/lib/lane-model.sh"
PLAN_MODEL=$(lane_model PLAN_MODEL plan "$PROJECT") \
  || { echo "$(STAMP) [$PROJECT/$KEY] pre-plan: no model route for role plan — not planned" >> "$LOG"; exit 75; }
# <<< model-route
# >>> context pack delta (BH-3478)
# A SPLIT CHILD STARTS WARM. Decompose leaves the parent planner's codebase map
# as a context_packs row keyed on (project, key); a ticket is a child only when
# that row exists. A child's pre-plan is handed the map as a WARM START prefix,
# runs on the child plan route (bin/lib/child-plan.sh), carries `delta` on its
# cost row and is capped at child_preplan_delta_tokens (fallback 150000), because
# re-surveying what the parent already mapped is the spend this exists to stop.
# Fail-open: no lib, no row or an outage writes at most one line and runs the
# pre-plan below exactly as before; PP_ENV and PP_PREAMBLE stay empty.
PP_DELTA=0; PP_PREAMBLE=""; PP_ENV=()
# shellcheck source=bin/lib/context-pack.sh
[ -r "$HARNESS/bin/lib/context-pack.sh" ] && . "$HARNESS/bin/lib/context-pack.sh" 2>/dev/null
# shellcheck source=bin/lib/child-plan.sh
[ -r "$HARNESS/bin/lib/child-plan.sh" ] && . "$HARNESS/bin/lib/child-plan.sh" 2>/dev/null
# shellcheck source=bin/lib/plan-thread.sh
[ -r "$HARNESS/bin/lib/plan-thread.sh" ] && . "$HARNESS/bin/lib/plan-thread.sh" 2>/dev/null
# BH-5910: the pre-plan writes the same CROSS-REPO-READ lines a fresh plan
# does, because bin/lib/rb/plan.sh gates a pre-plan HIT on them.
# shellcheck source=bin/lib/rb/cross-repo-read.sh
[ -r "$HARNESS/bin/lib/rb/cross-repo-read.sh" ] && . "$HARNESS/bin/lib/rb/cross-repo-read.sh" 2>/dev/null
if command -v cp_fetch >/dev/null 2>&1; then
  JOBS_ALERT=0 cp_fetch "$PROJECT" "$KEY" "$PLANDIR/context-pack.md"; PP_CP_RC=$?
  if [ "$PP_CP_RC" = 0 ] && PP_PREAMBLE="$(cp_preamble "$PLANDIR/context-pack.md")"$'\n\n' \
     && [ -n "${PP_PREAMBLE//[$'\n']/}" ]; then
    command -v child_plan_model >/dev/null 2>&1 \
      && PP_M=$(child_plan_model "$PROJECT" "$PLAN_MODEL") && [ -n "$PP_M" ] && PLAN_MODEL=$PP_M
    PP_DELTA=1
    # The cap is a settings row; 150000 is only its documented fallback, and the
    # log line names which one answered.
    PP_TOKCAP=""; PP_TOKSRC="no settings client"
    if command -v setting_get >/dev/null 2>&1; then
      PP_TOKCAP=$(JOBS_ALERT=0 setting_get child_preplan_delta_tokens); PP_SET_RC=$?
      case "$PP_SET_RC" in 0) PP_TOKSRC="" ;; 2) PP_TOKSRC="no row" ;; *) PP_TOKSRC="settings unreachable" ;; esac
    fi
    if [ -z "$PP_TOKSRC" ]; then
      case "$PP_TOKCAP" in
        ''|*[!0-9]*) PP_TOKSRC="not a positive integer" ;;
        *) PP_TOKCAP=$((10#$PP_TOKCAP)); [ "$PP_TOKCAP" -gt 0 ] || PP_TOKSRC="not a positive integer" ;;
      esac
    fi
    if [ -z "$PP_TOKSRC" ]; then PP_TOKSRC="setting child_preplan_delta_tokens"
    else PP_TOKCAP=150000; PP_TOKSRC="fallback 150000 ($PP_TOKSRC)"; fi
    PP_ENV=(AGENT_CALL_ROW_NOTE=delta "CONTEXT_KILL_TOKENS=$PP_TOKCAP")
    echo "$(STAMP) [$PROJECT/$KEY] pre-plan delta: parent=$(head -n1 "$PLANDIR/context-pack.md.parent" 2>/dev/null) model=$PLAN_MODEL token cap=$PP_TOKCAP ($PP_TOKSRC)" >> "$LOG"
  else
    PP_PREAMBLE=""
    if [ "$PP_CP_RC" = 2 ]; then
      echo "$(STAMP) [$PROJECT/$KEY] no context pack" >> "$LOG"
    else
      echo "$(STAMP) [$PROJECT/$KEY] context pack unreachable — full pre-plan" >> "$LOG"
    fi
  fi
fi
# <<< context pack delta
# >>> changed symbols note (BH-5791)
# A pre-plan lists the symbols it changes too, because the build checks an
# adopted pre-plan for design collisions (bin/lib/rb/plan.sh). It appends to
# PP_PREAMBLE, so the prompt line below does not change. No lib: unchanged.
# shellcheck source=bin/lib/plan-collisions.sh
[ -r "$HARNESS/bin/lib/plan-collisions.sh" ] && . "$HARNESS/bin/lib/plan-collisions.sh" 2>/dev/null
command -v pc_plan_note >/dev/null 2>&1 && PP_PREAMBLE="${PP_PREAMBLE:-}$(pc_plan_note) "
# <<< changed symbols note (BH-5791)
# The cost ledger as it stands BEFORE the call. agent-call.sh appends one
# logs/cost.csv row per attempt that actually ran and none for a refusal, so
# this number is what separates "the ladder ended on a refusal rung" from
# "nothing was ever called" — see preplan_billed in bin/lib/preplan-lib.sh.
PP_ROWS0=0
command -v preplan_cost_rows >/dev/null 2>&1 && PP_ROWS0=$(preplan_cost_rows "$HARNESS")
# AC_RC below is what separates `empty` from `failed` (BH-475 review): a session
# that exits 0 having written nothing was billed and answered — nothing to plan,
# a refusal, an empty completion — and retrying it is how a guard becomes a
# loop. A session that DIED gets a small cap instead.
# BH-2537: AGENT_CALL_TICKET names the ticket this plan is for, so its cost row
# carries it (bin/lib/cost-row.sh cost_row_tags).
# BH-5799: when this plan starts reading the thread. The plan thread gate in
# bin/lib/rb/plan.sh reads it after the adopt copies it into $BUILD, and
# bin/fly-pool.sh relays it with base-sha and ticket-fp.
command -v ptg_stamp >/dev/null 2>&1 && mkdir -p "$PLANDIR" 2>/dev/null && ptg_stamp "$PLANDIR/plan-thread-at"
AGENT_CALL_TICKET="$KEY" nice -n 10 env ${PP_ENV[@]+"${PP_ENV[@]}"} "$HARNESS/bin/agent-call.sh" preplan "$PROJECT" "$PLAN_MODEL" 1200 "$PLANDIR/plan-run.txt" \
  "${PP_PREAMBLE:-}$(command -v ui_notice >/dev/null 2>&1 && printf '%s ' "$(ui_notice)")PLAN ONLY - do not modify any files except writing the plan, and do NOT run git checkout/branch anywhere. Read ticket $KEY (id $TICKET) on this project's product board (access method in /root/harness/prompts/$PROJECT.md), including its FULL comment thread. SPEC CHANGES FROM COMMENTS: read the ticket's comment thread NEWEST FIRST. plan.md MUST carry a '## Spec changes from comments' section with one line per comment that changes scope (a new or removed column or field, a cadence, 'do not merge', an input folded in, a narrowed or reversed body item). Start each line with the comment's id (the number after #issuecomment- on a GitHub issue), then the author, then what changed and which task delivers it. If no comment changes scope, write the single line 'none'. A comment by the operator or the triage that is newer than this plan and not cited by id in plan.md makes the pipeline refuse the plan before review. $(command -v xrepo_plan_note >/dev/null 2>&1 && xrepo_plan_note)If /root/harness/state/$PROJECT-context.md exists, read it FIRST — it is the project primer (architecture, conventions, reference implementations, cross-repo pointers) written by an understand-pass; trust it for orientation, verify specifics in code. Read the relevant code in the READ-ONLY checkout at $WT (a build for a different ticket may be running in /root/repos/$PROJECT — stay out of that directory). $(th_plan_rule "$KEY")$(th_fragment_rule "$KEY" "$WT")$(command -v pfm_plan_rule >/dev/null 2>&1 && pfm_plan_rule)$(command -v vl_plan_rule >/dev/null 2>&1 && vl_plan_rule)Write a precise implementation plan to $PLANDIR/plan.md: scope, files to touch, edge cases, how the iron laws in ~/.claude/CLAUDE.md apply (sortable headers, list-over-cards, drill-down, DB-driven config, RLS, indexes for every query on a new table in the same migration (proven with EXPLAIN on seeded data), no per-row correlated subquery over a large table, a retention rule (scheduled delete/archive, window in a settings row) for every growing table, De-AI, and — if the change calls any metered/billable API — dedup-before-spend: a persisted 'already paid for this?' check BEFORE the call, 'succeeded but empty' treated as billed+terminal, ledger keyed on a stable input fingerprint not a tokenized URL), and a verification checklist. PERFORMANCE BY DEFAULT (BH-6946): a plan for a screen or loader lists its reads, which of them run in parallel, the expected statement count, the indexes they use, and the loading skeleton. PERFORMANCE BY DEFAULT (BH-6946), each one a BLOCK: a new sequential await over independent reads; a list read in a layout where a count would do; a route without loading.tsx; a repeated config read without a request memo; a list query without a matching index at seeded volume; unbounded rows to the client; a speed claim without before and after numbers; a client snapshot that holds a token, is not keyed by user and company, or survives sign-out; a key screen with two or more independent requests in sequence before its first content. FOLLOW-UPS ARE GROUPED: a follow-up found during a build or review goes into ONE follow-up ticket per screen or flow, with every item as a checklist, never one ticket per finding (BH-6902). DEPENDENCIES ARE CLAIMS THE HARNESS NOW CHECKS (W2-G, 2026-09-14): if the ticket's body carries any 'Blocked-by: #N' lines, the plan MUST carry a '## Dependencies' section with ONE LINE PER BLOCKER, each exactly 'DEPENDS: #N hard - <reason>' or 'DEPENDS: #N soft - <reason>'. hard means THIS slice imports, calls, extends or migrates on top of code #N adds, so it cannot compile or run until #N lands. soft means ordering preference only - nothing in this slice reads a symbol, table or route #N introduces. Decide it from the code you just read, never from the fact that somebody typed the line. A missing or unreadable DEPENDS line is read as hard and the ticket waits for its blocker, so an honest 'soft' is what lets this build on main today instead of hours from now; an over-stated 'soft' is a build against a base that does not carry the code it needs, so say hard when it is hard. The plan MUST end with two sections: '## Acceptance tests' — the ticket's acceptance criteria written as CONCRETE test cases (test file path + what each asserts, in the repo's test framework per the Verification Contract in its CLAUDE.md; if the repo has no test framework, say so and give a manual verification script instead) — and '## QA screens' — the app routes/screens a browser QA pass should exercise, with the primary user flow per screen. Also name which existing test suites are at regression risk. The plan will be executed later in /root/repos/$PROJECT, so reference repo-relative file paths, not $WT paths. If the thread does NOT actually confirm the mechanism, write BLOCKED-NEEDS-CLARIFICATION as the first line of plan.md with the open questions."
AC_RC=$?

if [ -s "$PLANDIR/plan.md" ]; then
  # The outcome is `ok`, so whatever this key cost before is spent history.
  command -v preplan_attempt_clear >/dev/null 2>&1 && preplan_attempt_clear "$PLANDIR"
  date -u '+pre-planned %Y-%m-%dT%H:%M:%SZ' > "$PLANDIR/.meta"
  # >>> consumable record (2026-09-14)
  # WHAT MAKES THIS PLAN USABLE LATER, written here because here is the only
  # place that knows what the planner actually read:
  #   base-sha          the origin/$BASE commit the read-only worktree was
  #                     pinned to. bin/lib/preplan-lib.sh:preplan_check discards
  #                     the plan if main has since moved in any file it lists.
  #   planned-files.txt bin/planned-files.sh over plan.md — the same extractor
  #                     the file-claim gate uses, so "the files this plan owns"
  #                     means one thing.
  #   key               which ticket this directory is for. A fly pool machine
  #                     is REUSED between jobs, so the relayed copy must say who
  #                     it belongs to or build B adopts build A's plan.
  #   ticket-fp         the board thread as it stood when the plan was written.
  #                     bin/run-build.sh copies this into $BUILD/ticket-fp on
  #                     adopt, which hands the adopted plan to the SAME
  #                     resume-stale gate a checkpointed plan already passes
  #                     through — otherwise consuming a pre-plan would quietly
  #                     delete the TK-143 #517 protection every build has today.
  printf '%s\n' "$KEY" > "$PLANDIR/key"
  preplan_record "$PLANDIR" "$WT" "origin/$BASE" 2>/dev/null || \
    echo "$(STAMP) [$PROJECT/$KEY] pre-plan: could not record base sha — it will re-plan at build time" >> "$LOG"
  TICKET_FP > "$PLANDIR/ticket-fp" 2>/dev/null
  [ -s "$PLANDIR/ticket-fp" ] || rm -f "$PLANDIR/ticket-fp"
  #   published      ...and the same record as a row in the coordination DB
  #                  (BH-658). A pool machine that builds this ticket cannot
  #                  read this directory: bin/fly-pool.sh relays the row and
  #                  the builder asks the DB for it itself (BH-3437). Published
  #                  LAST, after every file above exists, so a row can never
  #                  describe a half-written plan. EVERY project publishes:
  #                  routing is decided on the hub, and the flags/builder-fly-*
  #                  file this used to gate on is one a watcher box need not
  #                  have, so project-5, project-1 and project-3 published
  #                  nothing and every pool build of theirs re-planned.
  # shellcheck source=bin/jobs-client.sh
  [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
  if command -v preplan_put >/dev/null 2>&1; then
    # FAIL-OPEN, and each outcome is its own line: "REFUSED" (a 4xx — the
    # worker judged this plan) sends an operator to the payload, "unreachable"
    # (no answer, or a 5xx — the worker broke) sends them to the worker, and
    # neither of them may ever change this stage's exit code. The status rides
    # on both lines so neither reading is a guess.
    preplan_put "$PROJECT" "$KEY" "$PLANDIR" >/dev/null; PP_PUB_RC=$?
    case "$PP_PUB_RC" in
      0) echo "$(STAMP) [$PROJECT/$KEY] pre-plan published ($(wc -c < "$PLANDIR/plan.md" | tr -d ' ') bytes)" >> "$LOG" ;;
      3) echo "$(STAMP) [$PROJECT/$KEY] pre-plan publish REFUSED (http ${JOBS_HTTP:-?}) — the hub will record PREPLAN_MISS" >> "$LOG" ;;
      *) echo "$(STAMP) [$PROJECT/$KEY] pre-plan publish unreachable (${JOBS_HTTP:-no answer}) — the hub will record PREPLAN_MISS" >> "$LOG" ;;
    esac
  fi
  # <<< consumable record
  # >>> ticket edges (BH-6977)
  # One ticket_edges row per blocker the plan declares (Blocked-by, Needs,
  # DEPENDS). The text lines stay where they are. Fail-open: no stdout, rc 0.
  # shellcheck source=bin/lib/ticket-edges.sh
  [ -r "$HARNESS/bin/lib/ticket-edges.sh" ] && . "$HARNESS/bin/lib/ticket-edges.sh" 2>/dev/null
  if command -v te_put_edges >/dev/null 2>&1; then
    te_put_edges "$PROJECT" "$TICKET" planner "$PLANDIR/plan.md" "$PLANDIR/planned-files.txt" >/dev/null 2>&1 || true
  fi
  # <<< ticket edges
  echo "$(STAMP) [$PROJECT/$KEY] pre-plan done" >> "$LOG"
elif command -v preplan_billed >/dev/null 2>&1 && ! preplan_billed "$HARNESS" "${AC_RC:-0}" "$PP_ROWS0"; then
  # >>> preplan not-billed exit
  # NOTHING WAS CALLED, SO NOTHING IS RECORDED (#1014 review 2, #1073 review).
  # agent-call answered with a refusal code AND wrote no cost row: no account
  # headroom, the hub's no-build refusal, a no-tools refusal, an argv-only lane
  # refusing the prompt. No model ran and no money moved, so this is not an
  # attempt — the directory and whatever ledger it already carries are left
  # exactly as they were, and the key stays buyable the moment the refusal
  # clears. A refusal code with a cost row behind it is a SPENT session and
  # falls through to the record below, because the rc is the last rung's and a
  # billed rung can descend into a refusing one.
  #
  # LOGGED ONCE PER KEY, in its own marker rather than the tick's `skip-logged`:
  # an outage lasts hours and this lane runs every two minutes, and a terminal
  # PREPLAN_SKIP later must still get its own line instead of being swallowed
  # by a marker this path had already written.
  if [ ! -e "$PLANDIR/refusal-logged" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] pre-plan refused before billing (rc=${AC_RC:-?}) — not an attempt, the key stays buyable" >> "$LOG"
    mkdir -p "$PLANDIR" 2>/dev/null && : > "$PLANDIR/refusal-logged" 2>/dev/null
  fi
  # The refusal marker agent-call wrote into the plan output is debris: nothing
  # reads it, and the reason is in the line above. The directory itself stays —
  # it carries the once-per-key marker, and any ledger the key already had.
  rm -f "$PLANDIR/plan-run.txt" "$PLANDIR/plan-thread-at" 2>/dev/null
  # <<< preplan not-billed exit
else
  # >>> preplan attempt record
  # TERMINAL STATE ON EVERY NON-SUCCESS EXIT (BH-475 review). The directory is
  # still emptied — a planless dir must never look adoptable — and then the one
  # fact that stops this key being bought again is written back into it:
  #   rc 0  -> `empty`  the session answered and there was nothing. Terminal.
  #   rc !0 -> `failed` the session died. Retried to preplan_max_attempts.
  # The record is written on EVERY billed non-success exit: a path that writes
  # nothing is a dedup that can never become true, and the next tick re-buys the
  # same key.
  PP_OUT=empty; [ "${AC_RC:-0}" = 0 ] || PP_OUT=failed
  echo "$(STAMP) [$PROJECT/$KEY] pre-plan produced no plan.md (rc=${AC_RC:-?}, $PP_OUT)" >> "$LOG"
  # Read BEFORE the wipe and handed to the record below: the directory carries
  # the count, and removing it without carrying the number forward restarts the
  # cap at 1 on every attempt, which is the same as having no cap.
  PP_N=$(cat "$PLANDIR/attempts" 2>/dev/null)
  case "$PLANDIR" in "$HARNESS/plans/"*) rm -rf "$PLANDIR" ;; esac
  if command -v preplan_attempt_record >/dev/null 2>&1; then
    preplan_attempt_record "$PLANDIR" "$PP_OUT" "$PP_N" \
      || echo "$(STAMP) [$PROJECT/$KEY] pre-plan: could not record the $PP_OUT outcome — this key can be bought again" >> "$LOG"
  fi
  # <<< preplan attempt record
fi
# >>> per-key worktree cleanup
if [ "$(preplan_speculative "$HARNESS")" = 1 ] && [ -d "$WT" ]; then
  git -C "${REPOS_ROOT:-/root/repos}/$PROJECT" worktree remove --force "$WT" >>"$LOG" 2>&1 || rm -rf "$WT"
fi
# <<< per-key worktree cleanup
