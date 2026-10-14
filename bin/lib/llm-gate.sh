#!/bin/bash
# bin/lib/llm-gate.sh — BH-1141 phase 2. ONE gate, consulted BEFORE the vendor
# call, for every model call that goes through bin/agent-call.sh. Sourced, never
# executed. No side effect at source time beyond defining functions.
#
# WHY. On 2026-09-20 alert-triage burned $793 in twelve hours by descending a
# ladder — grok cliff -> codex -> Fable over OpenRouter — that costs ~100x the
# standing lane, and nothing in the fleet could have stopped it before the
# money was gone: no per-lane pathway control, no daily USD ceiling that runs
# BEFORE the call, and refusals indistinguishable from billed failures. The
# shape of that bug is the one `~/.claude/rules/metered-api-dedup.md` is written
# about: a guard that exists, reads correctly, and runs after the charge.
#
# THE THREE KNOBS, resolved through BH-1132's `lane_knob` so there is ONE knob
# resolver in this fleet and ONE spelling of each key:
#
#   LLM_LANE_ENABLED     1 (default) | 0 — 0 makes this lane call no model at all.
#   LLM_RUNNER_ALLOWED   "" (default) | a comma/space list of the ONLY rungs this
#                        lane may reach. Empty is every rung, i.e. today's
#                        ladder unchanged. A rung outside the list is refused
#                        BEFORE the call, so a cliff or a failure on the
#                        standing lane cannot descend into a costlier one.
#   LLM_RUNNER_ALLOWED_<STAGE>  "" (default) | the same kind of list, for ONE
#                        call stage (BH-2581; `execute` reads
#                        LLM_RUNNER_ALLOWED_EXECUTE, a `-` in the stage reads as
#                        `_`). A rung has to pass BOTH this and LLM_RUNNER_ALLOWED;
#                        empty is every rung. A stage with a character outside
#                        letters, digits, `-` and `_` reads no knob. fly-pool registers PLAN/EXECUTE/REVIEW/FIX/QA, so
#                        `lane.fly-pool.<project>.llm_runner_allowed_execute`
#                        scopes it to one project's builds.
#   LLM_USD_CAP_DAY      0 (default) = unlimited. Dollars this lane may spend in
#                        the current UTC day, read from D1 `cost_rows` — never
#                        from the box's own logs/cost.csv, which is one box's
#                        share of a fleet-wide bill. Resolved twice: the LANE
#                        scope (settings `lane.<id>.llm_usd_cap_day`, or the
#                        environment) and the (LANE, PROJECT) scope (settings
#                        `lane.<id>.<project>.llm_usd_cap_day` ONLY — a project
#                        cap is a row somebody wrote, never an inherited one).
#   LLM_GATE_IN_TICKET   unset (default) | 1 — set by bin/agent-call.sh, never a
#                        knob, when the call's $OUT is in a build dir that holds
#                        ADMITTED and no RESULT, and the lane is fly-pool
#                        (BH-5526). Both LLM_USD_CAP_DAY scopes of the fly-pool
#                        lane are then skipped (any other lane ignores the
#                        flag): a day cap refuses only at the ticket boundary
#                        (the launch gate in bin/lib/rb/gates.sh), never between
#                        plan, execute and review. LLM_LANE_ENABLED=0 still
#                        refuses, because it is a kill switch, not a ceiling.
#
# THE RUNAWAY CEILING (BH-5526 C3). The settings row `spend.ceiling.<lane>.day_usd`
# is a hard ceiling on the dollars a lane spends in the UTC day, every stage
# and every project (GET /api/metrics/llm-spend?lane=<lane>, no stage: only
# rows stamped lane_id=<lane>). A dollar amount > 0 arms it; `off`, `0`, junk
# or no row is no ceiling, and no row makes no read. bin/spend-ceiling-seed.sh
# writes it once at 3x the lane's p99 (insert-if-absent), so an operator value
# always wins. It is checked AFTER the LLM_GATE_IN_TICKET return: an admitted
# fly-pool ticket finishes every stage, and a fresh build is refused at the
# launch gate. Any other call is its own start. Spent >= ceiling refuses
# (LLM_GATE_REASON `spend-ceiling lane=<l> spent=$X ceiling=$Y ...`) and raises
# one alert per (lane, UTC day, box). An unreadable spend ALLOWS the call. The
# switch `spend-ceiling-off` (lane_switch, file mode) turns the check off.
#
# WHAT A REFUSAL LEAVES BEHIND. A zero-cost row in logs/cost.csv with
# `row_source=refused` and `note=refused:<reason>`, which the fleet mirror
# pushes to D1 like any other row. A refusal that leaves no row is
# indistinguishable from a lane nobody asked to run — and "the lane went quiet"
# is exactly what an operator must be able to tell apart from "the lane is being
# stopped". `cost_usd` is the literal 0, never blank: a blank is what the
# pricing-parity lane pages on, and a refusal has nothing to price.
#
# FAIL OPEN, EVERY WAY. No registry, no lane-gate library, no jq, no worker, an
# unreachable D1, a box whose sync has not landed this file — every one of them
# leaves the call running exactly as it runs today. Every lane in this fleet
# runs today with NO gate at all, and that is the behaviour a failure has to
# degrade to. A spend control that stops the fleet when a database blinks costs
# more than the spend it was built to stop.
#
# HONEST SCOPE, because this is easy to over-credit:
#   * It gates bin/agent-call.sh and, since BH-2534, bin/claude-cost.sh (the
#     orchestrator's primary turn, greenfield, box-chat's `-c` rung), which
#     calls llm_gate_precall / llm_gate_runner_ok before claude starts. Any
#     other site catalog/llm-sites.json marks `gated: none` is NOT gated by this
#     file, and docs/LLM_CALL_SITES.md is the list.
#   * BH-2303 (phase 3 of #1141): a cost row now carries `lane_id` and every
#     LLM lane exports AGENT_CALL_LANE, so each per-stage spend read below also
#     names the lane and counts only rows stamped with it (plus rows written
#     before lane_id existed). What follows is the history the lane id retires;
#     it still describes a call whose lane names nothing:
#   * A cost row carries (stage, project) and nothing that names a lane, so
#     three review lanes share one signature. A lane-scope cap therefore sums
#     the SIGNATURE, and the refusal reason says so. `lane_id` on the row is
#     phase 3 of #1141. Two consequences worth saying out loud:
#       - a lane with NO project filter (run-triage, postmerge-qa,
#         run-product, preplan-tick, rule-miner, prompt-eval, …) sums its whole
#         stage FLEET-WIDE. `run-triage`'s cap is measured against
#         alert-triage + alerts-medic + watchdog-responder + run-triage, because
#         all four price as stage=triage. A per-project ceiling for those lanes
#         is the (lane, project) row, which sums only that project.
#       - a lane registered with SEVERAL stages (`stats.cost_stage` as an
#         array, BH-2304: run-product is map/signals/ideate/synth, plus
#         prd/mockup since BH-2489 because the bin/draft-proposal.sh child it
#         runs inherits its AGENT_CALL_LANE and the lane declares that helper
#         in `stats.cost_stage_via`) is one budget: its cap sums the day's
#         spend over every one of them, one D1 read per stage, and any read
#         that fails makes the sum unknown.
#       - `review` and `execute` are shared by several lanes (merge-conductor,
#         blocked-resolver, fly-pool and the review lanes), so they resolve to
#         the synthetic `stage-review` / `stage-execute` and are capped by that
#         id's row, never per lane, until phase 3 adds lane_id.
#     tests/lane-stage-ratchet.bh-2304-test.sh holds every lane's registered
#     stages equal to the stages its own script passes to agent-call.sh; a
#     lane registered under a stage it never calls gates somebody else's calls.
#
# Knobs on the gate itself: LLM_GATE_DISABLE=1 (off — the escape hatch if this
# file is ever the thing that is wrong), LLM_GATE_NOW (epoch, injectable).

# --- environment -------------------------------------------------------------

_llm_h() { printf '%s' "${HARNESS:-${H:-/root/harness}}"; }
_llm_now_day() {
  if [ -n "${LLM_GATE_NOW:-}" ]; then date -u -d "@$LLM_GATE_NOW" '+%Y-%m-%d' 2>/dev/null || date -u '+%Y-%m-%d'
  else date -u '+%Y-%m-%d'; fi
}
_llm_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# THE KNOB RESOLVER IS BH-1132's, not a second one. Sibling first so a test
# drives the checkout's copy; the deployed path next; and a box that has neither
# gets stubs that answer "no knob", which is the ungated fleet of yesterday.
if ! command -v lane_knob >/dev/null 2>&1; then
  for _lgf in "$(dirname "${BASH_SOURCE[0]}")/lane-gate.sh" "$(_llm_h)/bin/lib/lane-gate.sh"; do
    # shellcheck source=bin/lib/lane-gate.sh
    [ -r "$_lgf" ] && { . "$_lgf"; break; }
  done
  unset _lgf
fi
command -v lane_knob >/dev/null 2>&1 || lane_knob() { local e="${2:-}"; printf '%s' "${!e:-}"; }

# _llm_registry — the lane registry, resolved the same way agent-call resolves
# catalog/context-budgets.json: fly builders have no checkout, the hub does.
_llm_registry() {
  local r h
  [ -n "${LANE_REGISTRY:-}" ] && [ -r "$LANE_REGISTRY" ] && { printf '%s' "$LANE_REGISTRY"; return 0; }
  # THE LOADER FIRST (BH-1247, review I3). catalog/lanes.json is GENERATED from
  # catalog/lanes.d/ and no longer committed, so an existing file on disk may be
  # any age: reading it before asking the loader meant a lane added minutes ago
  # was invisible here until something else re-rendered the same path. The
  # loader answers from its stamp when the sources have not moved, so this costs
  # a cksum, not a render.
  for h in /root/harness-checkout "$(_llm_h)"; do
    [ -r "$h/bin/lib/lanes-registry.sh" ] || continue
    [ -d "$h/catalog/lanes.d" ] || continue
    # shellcheck source=lanes-registry.sh
    . "$h/bin/lib/lanes-registry.sh" 2>/dev/null || continue
    r=$(lanes_json_path "$h" 2>/dev/null) || continue
    [ -n "$r" ] && [ -r "$r" ] && { printf '%s' "$r"; return 0; }
  done
  # A tree with no SOURCES to render from is the fly builder: it carries a
  # checkout's catalog/ and no lanes.d, so an existing render is all there is
  # and is exactly right. rc 1 when there is neither — every caller in this
  # library already reads that as "no cap row", the fail-open behaviour BH-1141
  # shipped.
  for r in /root/harness-checkout/catalog/lanes.json "$(_llm_h)/catalog/lanes.json"; do
    [ -r "$r" ] && { printf '%s' "$r"; return 0; }
  done
  return 1
}

# _llm_log <line> — one line into logs/lane-gate.log, throttled by BH-1132's own
# throttle when it is there (a lane on a */2 cron would otherwise bury the line
# that matters under 720 identical ones). Never fatal.
_llm_log() {
  local key="${1:-llm-gate}" line="${2:-}"
  if command -v _lg_log_throttled >/dev/null 2>&1; then
    _lg_log_throttled "llm-gate-$key" "$line"; return 0
  fi
  mkdir -p "$(_llm_h)/logs" 2>/dev/null
  printf '%s %s\n' "$(_llm_stamp)" "$line" >> "$(_llm_h)/logs/lane-gate.log" 2>/dev/null
  return 0
}

# --- which lane is this call ------------------------------------------------

# llm_gate_lane_id <stage> <project> — the lane this call belongs to.
#
#   1. $AGENT_CALL_LANE, when the caller said so outright. Every LLM lane in
#      catalog/llm-sites.json exports it (BH-2303), so this is the usual answer.
#   2. the registry lane whose cost_project_filter IS this project — the lane
#      that declared it owns this signature.
#   3. failing that, the lane that takes the WHOLE stage (a null filter), and
#      only when there is exactly one of them.
#   4. `stage-<stage>` when the signature is genuinely shared or unknown. A
#      synthetic id rather than nothing, because a knob on a stage that three
#      lanes share is still a knob somebody can set — and it is spelled so
#      nobody mistakes it for a registry lane. It is NOT settable with
#      `bin/harness-ctl.sh set` (that refuses an id the registry does not
#      carry); docs/verification-map/llm-choke-point.md names the raw key.
#
# WHY EXACT-FIRST, AND WHY THIS IS THE BLOCKING DETAIL (round-1 review, B1).
# The first draft matched `cost_stage == stage AND (filter == null OR filter ==
# project)` in ONE pass and demanded a unique answer. `run-triage` carries
# cost_stage=triage with NO filter, so it matched every triage call and
# collided with alert-triage, alerts-medic and watchdog-responder — the three
# filtered triage lanes — which made all of them resolve to `stage-triage`. A
# `lane.alert-triage.llm_usd_cap_day` row was therefore never read: the cap on
# the lane that spent $793 was a row nothing looked up, and nothing logged it,
# because _llm_log only fires when a cap IS found. That is the same failure
# shape as a dedup keyed on a tokenised URL — present, correct-looking, never
# firing.
#
# This ordering is the worker's, which keys ambiguity on the exact
# `stage|filter` PAIR (`sig()` in worker/jobs/src/index.js, GET
# /api/lanes/status): under that rule `triage|alert-triage` is unique and
# `triage|-` is unique, and only review (×3) and execute (×2) are shared. So a
# cap is compared against the same number the lanes page attributes to the lane.
# Memo for the RESOLVED lane id, read and written by _llm_lane_resolve below
# and by nothing else. llm_gate_lane_id itself cannot memoise: every caller
# reads it through `$(...)`, so anything it assigns dies with the subshell —
# which is what the first draft did, two jq runs per rung, silently (round-2
# review, N1).
_LLM_LANE_MEMO_KEY=""; _LLM_LANE_MEMO=""
# `stats.cost_stage` is a string or, for a lane that calls agent-call.sh with
# several stages (run-product: map/signals/ideate/synth, and prd/mockup from
# the draft-proposal helper it declares, BH-2489), an array of them (BH-2304). A stage inside the array matches exactly as the string would.
_LLM_STAGE_MATCH='(.stats.cost_stage // "") | if type == "array" then any(.[]; . == $s) else . == $s end'
_llm_lane_ids() { # _llm_lane_ids <registry> <stage> <project|EMPTY-for-null-filter>
  local reg="$1" st="$2" pj="${3:-}"
  if [ -n "$pj" ]; then
    jq -r --arg s "$st" --arg p "$pj" "
      [ .lanes[]? | select($_LLM_STAGE_MATCH)
        | select((.stats.cost_project_filter // \"\") == \$p)
        | .id ] | .[]" "$reg" 2>/dev/null
  else
    jq -r --arg s "$st" "
      [ .lanes[]? | select($_LLM_STAGE_MATCH)
        | select((.stats.cost_project_filter // null) == null)
        | .id ] | .[]" "$reg" 2>/dev/null
  fi
}
llm_gate_lane_id() {
  local st="${1:-}" pj="${2:-}" reg ids n
  [ -n "${AGENT_CALL_LANE:-}" ] && { printf '%s' "$AGENT_CALL_LANE"; return 0; }
  if reg=$(_llm_registry) && command -v jq >/dev/null 2>&1; then
    ids=""; n=0
    if [ -n "$pj" ]; then
      ids=$(_llm_lane_ids "$reg" "$st" "$pj")
      n=$(printf '%s' "$ids" | grep -c . 2>/dev/null) || n=0
    fi
    # Only when NO lane claimed this project by name. Two lanes claiming the
    # same (stage, project) is a registry fault, and falling through to the
    # stage lane would answer it with somebody else's cap: say `stage-<stage>`.
    if [ "$n" = 0 ]; then
      ids=$(_llm_lane_ids "$reg" "$st")
      n=$(printf '%s' "$ids" | grep -c . 2>/dev/null) || n=0
    fi
    if [ "$n" = 1 ]; then
      printf '%s' "$ids"; return 0
    fi
  fi
  printf 'stage-%s' "$st"
}

# _llm_lane_resolve <stage> <project> — sets LLM_GATE_LANE, memoised for THIS
# process. The ladder asks once per rung and (stage, project) are one call's own
# arguments, so they cannot change under it; assigning through a variable rather
# than a subshell is what lets the memo survive to the second rung.
_llm_lane_resolve() {
  if [ "$_LLM_LANE_MEMO_KEY" = "${1:-}|${2:-}" ] && [ -n "$_LLM_LANE_MEMO" ]; then
    LLM_GATE_LANE="$_LLM_LANE_MEMO"; return 0
  fi
  LLM_GATE_LANE=$(llm_gate_lane_id "${1:-}" "${2:-}")
  _LLM_LANE_MEMO_KEY="${1:-}|${2:-}"; _LLM_LANE_MEMO="$LLM_GATE_LANE"
  return 0
}

# _llm_lane_project_filter <lane> — the lane's declared cost project filter, or
# empty. It is what makes a LANE-scope spend query the lane's own rows rather
# than every project's.
_llm_lane_project_filter() {
  local reg
  reg=$(_llm_registry) || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r --arg i "${1:-}" '.lanes[]? | select(.id==$i) | .stats.cost_project_filter // empty' "$reg" 2>/dev/null
}

# _llm_lane_stages <lane> <call-stage> — the stages whose spend is this lane's,
# one per line: every stage the registry lists for it (BH-2304: run-product's
# one cap is "dollars this lane may spend", and it spends across four stages).
# A synthetic `stage-*` id, a lane the registry does not carry, or no
# registry/jq at all is just the call's own stage — what this gate summed
# before a lane could register more than one.
_llm_lane_stages() {
  local lane="${1:-}" st="${2:-}" reg out=""
  case "$lane" in stage-*) ;; *)
    if reg=$(_llm_registry) && command -v jq >/dev/null 2>&1; then
      out=$(jq -r --arg i "$lane" '.lanes[]? | select(.id==$i) | .stats.cost_stage
        | if type == "array" then .[] elif type == "string" then . else empty end' "$reg" 2>/dev/null)
    fi ;;
  esac
  [ -n "$out" ] || out="$st"
  printf '%s\n' "$out"
}

# _llm_setting_only <lane> <ENV> <project> — the PROJECT-scoped settings row and
# nothing else: no env fallback, no registry default, no walk up to the lane
# key. lane_knob deliberately walks up (most specific first), which is right for
# a knob and wrong for a SECOND ceiling: inheriting the lane's cap as the
# project's would make one $10 lane cap mean "$10 per project" without anybody
# writing that row. The KEY is built by lane-gate's own `_lg_setting_key`, so
# there is one spelling of it — the BH-1132 lesson where the console wrote one
# key and the reader looked up another, and nothing errored anywhere.
_llm_setting_only() {
  local key
  command -v _lg_setting_key >/dev/null 2>&1 || return 1
  command -v _lg_setting_lookup >/dev/null 2>&1 || return 1
  key=$(_lg_setting_key "${1:-}" "${2:-}" "${3:-}") || return 1
  _lg_setting_lookup "$key"
}

_llm_is_num() { grep -qE '^[0-9]+(\.[0-9]+)?$' <<<"${1:-}"; }

# --- the day's spend, from D1 ------------------------------------------------

# llm_gate_spend_today <stage> [project] [lane] — dollars on stdout, rc 0. rc 1
# means NOT KNOWN, which every caller must read as "do not refuse".
#
# WITH A LANE (BH-2303) the question is "what did THIS lane spend on this
# stage": the worker counts the stage's rows stamped lane_id=<lane> plus the
# rows written before lane_id existed — never another lane's — so review-prs,
# review-autopilot and merge-conductor, all stage=review, stop sharing one
# number. The caller sums it over the lane's registered stages (BH-2304).
#
# The aggregate endpoint, never the raw-rows one: a page of rows is capped at
# 2000 and a truncated sum is a cap that silently never fires — the same failure
# shape as a dedup that never matches.
llm_gate_spend_today() {
  local st="${1:-}" pj="${2:-}" ln="${3:-}" q resp usd
  command -v _jobs_req >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # The query string is built by concatenation, so anything that is not a plain
  # slug does not go into it. Returning "not known" makes the caller fail open,
  # which is the right answer for a name this function does not recognise.
  case "$st" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$pj" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$ln" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  q="stage=$st&since=$(_llm_now_day)T00:00:00Z"
  [ -n "$pj" ] && q="project=$pj&$q"
  # The lane rides LAST, so the question keeps the (project, stage, since)
  # shape every other reader of this query knows (BH-2304's per-stage reads).
  [ -n "$ln" ] && q="$q&lane=$ln"
  resp=$(_jobs_req GET "/api/metrics/llm-spend?$q" 2>/dev/null) || return 1
  usd=$(printf '%s' "$resp" | jq -r '.usd // empty' 2>/dev/null) || return 1
  _llm_is_num "$usd" || return 1
  printf '%s' "$usd"
}

# --- the runaway ceiling (BH-5526 C3) ----------------------------------------

_LLM_LIB=$(dirname "${BASH_SOURCE[0]}")

# _llm_ceiling_off — rc 0 when the spend-ceiling-off kill switch is ON.
_llm_ceiling_off() {
  if ! command -v lane_switch >/dev/null 2>&1; then
    # shellcheck source=bin/lib/lane-switch.sh
    [ -r "$_LLM_LIB/lane-switch.sh" ] && { . "$_LLM_LIB/lane-switch.sh" 2>/dev/null || true; }
    command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$(_llm_h)/flags/$1" ]; }
  fi
  lane_switch spend-ceiling-off file >/dev/null 2>&1
}

# _llm_ceiling <lane> — prints the lane's ceiling in dollars, rc 0. rc 1 is no
# ceiling: the switch is on, no row, `off`, 0 or junk (junk is logged).
_llm_ceiling() {
  local lane="${1:-}" v
  grep -qE '^[a-z0-9_.-]{1,42}$' <<<"$lane" || return 1
  command -v _lg_setting_lookup >/dev/null 2>&1 || return 1
  _llm_ceiling_off && return 1
  v=$(_lg_setting_lookup "spend.ceiling.$lane.day_usd" 2>/dev/null) || return 1
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ "$v" = off ] && return 1
  if ! _llm_is_num "$v"; then
    _llm_log "ceiling-junk-$lane" "[llm-gate] $lane: settings spend.ceiling.$lane.day_usd is '$v', not a dollar amount or off — no ceiling applied (BH-5526)."
    return 1
  fi
  awk -v c="$v" 'BEGIN{exit !(c+0 > 0)}' || return 1
  printf '%s' "$v"
}

# _llm_lane_day_spend <lane> — the lane's dollars this UTC day, all stages and
# projects. rc 1 = not known.
_llm_lane_day_spend() {
  local ln="${1:-}" resp usd
  command -v _jobs_req >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  case "$ln" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  resp=$(_jobs_req GET "/api/metrics/llm-spend?lane=$ln" 2>/dev/null) || return 1
  usd=$(printf '%s' "$resp" | jq -r '.usd // empty' 2>/dev/null) || return 1
  _llm_is_num "$usd" || return 1
  printf '%s' "$usd"
}

# _llm_ceiling_alert <lane> <text> — one alert per (lane, UTC day, box): the
# first claimer of the flag file raises it. Always rc 0.
_llm_ceiling_alert() {
  local lane="${1:-}" text="${2:-}" h day
  h=$(_llm_h); day=$(_llm_now_day | tr -d -)
  mkdir -p "$h/flags" 2>/dev/null
  ( set -C; : > "$h/flags/alerted-spend-ceiling-$lane-$day" ) 2>/dev/null || return 0
  [ -x "$h/bin/alert-line.sh" ] \
    && "$h/bin/alert-line.sh" --id "spend-ceiling:$lane:$day" --project fleet "[spend-ceiling] $text" >/dev/null 2>&1 && return 0
  mkdir -p "$h/logs" 2>/dev/null
  echo "$(date -u '+%FT%TZ') [fleet] spend-ceiling alert failed for $lane" >> "$h/logs/failovers.log" 2>/dev/null
  return 0
}

# --- the gate ----------------------------------------------------------------

LLM_GATE_REASON=""
# The lane _llm_lane_resolve last resolved. Declared here so `set -u` in a
# caller cannot trip on the first read.
LLM_GATE_LANE=""

# _llm_cap_check <lane> <cap> <stage> <project-filter-or-empty> <scope-label>
# rc 0 = allowed, rc 2 = over the cap (LLM_GATE_REASON set), rc 1 = unknown.
_llm_cap_check() {
  local lane="$1" cap="$2" st="$3" pj="$4" scope="$5" spent="" s one
  _llm_is_num "$cap" || return 0
  awk -v c="$cap" 'BEGIN{exit !(c+0 > 0)}' || return 0      # 0 = unlimited
  # One read per registered stage, summed. ANY failed read makes the whole
  # figure unknown: a partial sum compared against the cap would refuse on a
  # number nobody measured, or allow on one that is short (D12).
  for s in $(_llm_lane_stages "$lane" "$st"); do
    if ! one=$(llm_gate_spend_today "$s" "$pj" "$lane"); then
      _llm_log "spend-$lane" "[llm-gate] $lane $scope cap \$$cap is set but the day's spend for stage $s could not be read from D1 — the call was ALLOWED (fail open). A cap that stops the fleet when the coordination DB blinks costs more than the spend it guards."
      return 1
    fi
    if [ -z "$spent" ]; then spent="$one"
    else spent=$(awk -v a="$spent" -v b="$one" 'BEGIN{print a+b}'); fi
  done
  [ -n "$spent" ] || return 1
  if awk -v s="$spent" -v c="$cap" 'BEGIN{exit !(s+0 >= c+0)}'; then
    LLM_GATE_REASON="usd-cap-day $scope spent=\$$spent cap=\$$cap"
    return 2
  fi
  return 0
}

# llm_gate_precall <stage> <project> — the WHOLE-CALL gate: is this lane allowed
# to make a model call at all right now. rc 0 = yes, rc 2 = refuse.
#
# THAT 2 IS THIS LIBRARY'S OWN, and it is not what a caller of bin/agent-call.sh
# sees: agent-call turns a refusal into EXIT 74, its before-billing code, because
# rc 2 is also a vendor CLI's generic error and no caller could tell the two
# apart (round-1 review, I3). Do not propagate this rc to a lane.
llm_gate_precall() {
  local st="${1:-}" pj="${2:-}" lane enabled cap pcap filt rc ceil spent
  LLM_GATE_REASON=""
  [ "${LLM_GATE_DISABLE:-0}" = 1 ] && return 0
  [ -n "$st" ] || return 0
  _llm_lane_resolve "$st" "$pj"; lane="$LLM_GATE_LANE"

  enabled=$(lane_knob "$lane" LLM_LANE_ENABLED "$pj" 2>/dev/null)
  if [ "$enabled" = 0 ]; then
    LLM_GATE_REASON="lane-disabled $lane"
    return 2
  fi

  cap=$(lane_knob "$lane" LLM_USD_CAP_DAY 2>/dev/null)

  # AN ADMITTED TICKET IS NOT STOPPED MIDWAY (BH-5526). The launch gate in
  # bin/lib/rb/gates.sh checks the fly-pool lane's cap, and ONLY that lane's,
  # so only a fly-pool call is exempt. Any other lane is its own start and
  # checks its cap here, even when its $OUT is in an admitted build dir. The
  # log line names a cap that exists: no cap set, no line.
  if [ "${LLM_GATE_IN_TICKET:-0}" = 1 ] && [ "$lane" = fly-pool ]; then
    pcap=""
    [ -n "$pj" ] && { pcap=$(_llm_setting_only "$lane" LLM_USD_CAP_DAY "$pj" 2>/dev/null) || pcap=""; }
    if awk -v a="$cap" -v b="$pcap" 'BEGIN{exit !((a+0)>0 || (b+0)>0)}'; then
      _llm_log "in-ticket-$lane" "[llm-gate] $lane: LLM_USD_CAP_DAY (lane \$${cap:-0}, lane+project \$${pcap:-0}) was not applied to a call inside an admitted ticket (BH-5526); the cap is checked at the ticket's launch gate."
    fi
    return 0
  fi

  # THE RUNAWAY CEILING (BH-5526 C3), after the in-ticket return on purpose.
  if ceil=$(_llm_ceiling "$lane"); then
    if ! spent=$(_llm_lane_day_spend "$lane"); then
      _llm_log "ceiling-spend-$lane" "[llm-gate] $lane runaway ceiling \$$ceil is set but the lane's day spend could not be read from D1 — the call was ALLOWED (fail open)."
    elif awk -v s="$spent" -v c="$ceil" 'BEGIN{exit !(s+0 >= c+0)}'; then
      LLM_GATE_REASON="spend-ceiling lane=$lane spent=\$$spent ceiling=\$$ceil key=spend.ceiling.$lane.day_usd"
      _llm_ceiling_alert "$lane" "lane $lane spent=\$$spent ceiling=\$$ceil today (UTC): at or over its runaway ceiling (settings spend.ceiling.$lane.day_usd). No new ticket, build or review starts on this lane until 00:00Z; work already admitted finishes. Raise or lift: bin/jobs-client.sh setting-set spend.ceiling.$lane.day_usd <usd|off>."
      return 2
    fi
  fi

  # THE LANE SCOPE, summed over the lane's own cost signature.
  filt=$(_llm_lane_project_filter "$lane" 2>/dev/null) || filt=""
  _llm_cap_check "$lane" "$cap" "$st" "$filt" "lane"; rc=$?
  [ "$rc" -eq 2 ] && { LLM_GATE_REASON="$LLM_GATE_REASON lane=$lane"; return 2; }

  # ...and the (LANE, PROJECT) scope, which only exists when somebody wrote the
  # row. No row, no second ceiling.
  if [ -n "$pj" ]; then
    pcap=$(_llm_setting_only "$lane" LLM_USD_CAP_DAY "$pj" 2>/dev/null) || pcap=""
    _llm_cap_check "$lane" "$pcap" "$st" "$pj" "lane+project"; rc=$?
    [ "$rc" -eq 2 ] && { LLM_GATE_REASON="$LLM_GATE_REASON lane=$lane project=$pj"; return 2; }
  fi
  return 0
}

# llm_gate_runner_ok <stage> <project> <runner> — may this lane reach THIS rung.
# rc 0 = yes (the default everywhere, because an unset list is every rung).
llm_gate_runner_ok() {
  local st="${1:-}" pj="${2:-}" rn="${3:-}" lane list sfx slist
  LLM_GATE_REASON=""
  [ "${LLM_GATE_DISABLE:-0}" = 1 ] && return 0
  [ -n "$rn" ] || return 0
  _llm_lane_resolve "$st" "$pj"; lane="$LLM_GATE_LANE"
  list=$(lane_knob "$lane" LLM_RUNNER_ALLOWED "$pj" 2>/dev/null)
  if [ -n "$list" ]; then
    list=$(_llm_runner_list "$list")
    case ",$list," in
      *",$rn,"*) ;;
      *) LLM_GATE_REASON="runner-not-allowed $rn not in [$list] lane=$lane"
         return 2 ;;
    esac
  fi
  # BH-2581: the per-stage list, a SECOND list the rung must also pass. A stage
  # that cannot spell a knob name reads nothing rather than some other knob.
  sfx=$(printf '%s' "$st" | tr '[:lower:]-' '[:upper:]_')
  grep -qE '^[A-Z0-9_]+$' <<<"$sfx" || return 0
  slist=$(lane_knob "$lane" "LLM_RUNNER_ALLOWED_$sfx" "$pj" 2>/dev/null)
  [ -n "$slist" ] || return 0
  slist=$(_llm_runner_list "$slist"); slist="${slist#,}"; slist="${slist%,}"
  case ",$slist," in
    *",$rn,"*) return 0 ;;
  esac
  LLM_GATE_REASON="runner-not-allowed $rn not in [$slist] lane=$lane stage=$st"
  return 2
}

# _llm_runner_list <list> — a runner list spelled however an operator spelled
# it (commas, spaces, semicolons, or a mix) as one comma list. Matching against
# it is exact: `case ",$list,"` with the rung comma-bounded on both sides.
_llm_runner_list() {
  printf '%s' "${1:-}" | tr ' ;' ',,' | tr -s ','
}

# llm_gate_refused_row <stage> <project> <runner> <model> <rc> <reason>
# The zero-cost ledger row a refusal leaves behind. Best-effort and silent:
# instrumentation must never be able to break the thing it measures, and a gate
# that cannot write its row must still refuse.
llm_gate_refused_row() {
  local st="${1:-}" pj="${2:-}" rn="${3:-}" md="${4:-}" rc="${5:-2}" why="${6:-}" row tags gfp
  command -v cost_append >/dev/null 2>&1 || return 0
  if command -v cost_csv_field >/dev/null 2>&1; then
    why=$(cost_csv_field "$why"); md=$(cost_csv_field "$md")
  else
    why=$(printf '%s' "$why" | tr -d '\r\n"' | tr ',' ' ')
    md=$(printf '%s' "$md" | tr -d '\r\n"' | tr ',' ' ')
  fi
  if command -v cost_row_tags >/dev/null 2>&1; then tags=$(cost_row_tags); else tags=',,,'; fi
  if command -v cost_csv_field >/dev/null 2>&1; then gfp=$(cost_csv_field "${CG_FP:-}")
  else gfp=$(printf '%s' "${CG_FP:-}" | tr -d '\r\n"' | tr ',' ' '); fi
  # 26 columns, the canonical header, in order (lane_id, then guard_fp last, BH-2303/BH-2537). Zeros where a call would have
  # had numbers — never blanks: a blank cost_usd is what the pricing-parity lane
  # pages on, and there is nothing here to price.
  row="$(date -u '+%Y-%m-%dT%H:%M:%SZ'),$(hostname),$pj,$st,$rn,$md,$rc,0,0,0,0,0,0,none,none,unknown,,refused,0,$tags,refused:$why,$(printf '%s' "${AGENT_CALL_LANE:-${LLM_GATE_LANE:-}}" | tr -d '\r\n",'),$gfp"
  cost_append "$row" 2>/dev/null || true
  return 0
}
