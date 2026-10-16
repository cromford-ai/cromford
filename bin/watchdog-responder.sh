#!/bin/bash
# bin/watchdog-responder.sh — the watchdog first responder (the operator go: 2026-08-14).
#
# The watchdog pages the operator when a signal PERSISTS (stale-owed counts, wedged
# queues) — by design that fires only after the mechanical self-heal (sweep ->
# READY-QUEUE -> force-triage) already failed. Tonight's incident review showed
# every such page then cost a the operator->orchestrator round-trip just to get a
# DIAGNOSIS. This responder runs the orchestrator's playbook automatically on
# the SAME persist conditions, slightly ahead of the watchdog's own threshold:
# read the stuck tickets' threads, classify (ball-with-client / missing
# close-out / blocked-on-merge / infra wedge / genuinely buildable), fix what
# is within bounds, and escalate the rest as ONE enriched beat naming the
# specific decision needed — so a page that still fires arrives with its "why"
# attached.
#
# THE EVIDENCE IS FETCHED, NOT DISCOVERED (BH-654, 2026-09-17). The lane was
# carrying a median 4.27M input tokens per call — $559 over 68h — because the
# prompt told the model to go and read each ticket's thread, its PR state and
# the queue files through the agentic tool loop. Bash already knows every one of
# those URLs before the session starts, so it fetches them itself. The pass is
# now TWO calls, and the second one is conditional:
#   1. a DECISION call with AGENT_CALL_NO_TOOLS=1 over the fixed evidence. It
#      cannot read, write or launch anything; it answers one
#      `DECISION: <project>:<key> :: <class> :: none|act :: why` line per item.
#   2. the existing tooled playbook call — unchanged invocation, unchanged
#      playbook steps 2-5 — run ONLY when a decision says `act`, fed the same
#      evidence and told not to re-read the threads. Zero valid decisions fails
#      OPEN to this call, which is then told to classify every item itself — a
#      broken decision step must cost what today costs, never silence the lane.
# Evidence that could NOT be fetched is named MISSING in the prompt, per item,
# with the reason. A session on partial evidence must not read like one on full
# evidence.
#
# Hub cron */20 (offset from the medic). Also launched on demand by
# watchdog-poll.sh command type "respond" (worker->hub escalation path,
# docs/watchdog-spec.md §2).
# Kill switches, read through lane_switch (bin/lib/lane-switch.sh): the settings
# rows switch.responder-disabled[.<box>] (the whole lane) and
# switch.responder-prefetch-off[.<box>] (the prefetch: back to today's single
# tooled call on today's prompt, byte for byte). With no row, flag_active
# <name> answers when the jobs client is loaded (lane_switch's settings fetch
# loads it; a pause_flags row reconciled into flags/<name>, then the file),
# else the bare file, which is what a still-warm settings cache leaves.
# WHAT THIS LANE CONSUMES, and what it therefore does not filter. Its inputs are
# STALE-OWED TICKETS and WEDGED QUEUE JOBS — never alert lines — so the
# conductor-paused hold that bin/lib/conductor-mode.sh applies to alert-shaped
# work has nothing to filter here, and that library is deliberately not sourced.
#
# THE SESSION CEILING (BH-1384). Both calls below run under
# bin/agent-call.sh's context kill. RESPONDER_CONTEXT_CAP_TOKENS is that ceiling
# verbatim when it is > 0; at 0 (the default) the lane asks for the ceiling to
# be DERIVED from the runner's own price cliff — `cliff_tokens` in
# catalog/model-prices.json minus RESPONDER_CLIFF_MARGIN_TOKENS — which on a
# model with no cliff (every claude model in today's table) is exactly today's
# behaviour, the lane's 6,000,000 ceiling in catalog/context-budgets.json.
# Knobs: RESPONDER_THREAD_COMMENTS (default 10, comments kept per ticket),
#        RESPONDER_EVIDENCE_CAP_BYTES (default 60000, ceiling on the whole
#        rendered prompt; comments are dropped OLDEST-first to fit it. A cap
#        set BELOW the prompt's fixed scaffold cannot be honoured — the
#        evidence is dropped and the log says so, rather than the prompt
#        pretending there was none),
#        RESPONDER_PR_CALLS_MAX (default 12, gh calls per pass),
#        RESPONDER_CONTEXT_CAP_TOKENS (default 0, the session ceiling verbatim;
#        0 derives it from the model cliff),
#        RESPONDER_CLIFF_MARGIN_TOKENS (default 10000, how far under the cliff).
# RESPONDER_DRY=1 prints the session prompt instead of running it.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=watchdog-responder
H="${HARNESS:-/root/harness}"
export HARNESS="$H"       # board-fetch/internal-token-for/gh-budget read it
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
LOG="$H/logs/responder.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch responder-disabled && exit 0
set -a; . "$HENV/global.env" 2>/dev/null; set +a

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-watchdog-responder, or the D1 pause_flags row of the
# same name stops this tick (exit 0 — a paused lane is not a failure). With no
# flag and no row this returns immediately and the lane behaves exactly as it
# always has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off watchdog-responder.
# shellcheck disable=SC1091
. "${H}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit watchdog-responder
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    watchdog-responder

# --- ONE RUN PER PROJECT (BH-5942) -------------------------------------------
# No argument (cron, watchdog-poll's `respond`) = a dispatch: one detached
# `watchdog-responder.sh <project>` per fleet.conf project, then exit. A project
# run holds only locks/watchdog-responder-<project>.lock, reads only that
# project's stale tickets and wedged jobs, and runs its claude call on the
# project's pinned account with the project's App token. Below the gate, so a
# lane that is off forks nothing. bin/lib/llm-lane-project.sh has the contract.
LLP_LOG="$LOG"
# shellcheck source=bin/lib/llm-lane-project.sh
. "$H/bin/lib/llm-lane-project.sh" || exit 1
llp_enter watchdog-responder responder "${1:-}"
llp_arm

# --- THE COOLDOWN'S DURABLE COPY (BH-2346) ------------------------------------
# handled.json is hub-local, so a rebuilt hub starts with no cooldown and buys
# the same sessions again. With flags/alerts-db the pass also reads the
# `brake:responder-handled` rows back (a union, below signal 1's read) and
# writes each key it stamps through to them after the local stamp. The file
# stays primary: no flag, no library or a worker that does not answer is
# exactly today's pass.
BRAKE_DB=0
# shellcheck source=bin/lib/alert-state.sh
[ -r "$H/bin/lib/alert-state.sh" ] && . "$H/bin/lib/alert-state.sh" 2>/dev/null
# shellcheck source=bin/lib/brake-ledger.sh
[ -r "$H/bin/lib/brake-ledger.sh" ] && . "$H/bin/lib/brake-ledger.sh" 2>/dev/null
declare -F brake_db_on >/dev/null 2>&1 && brake_db_on && BRAKE_DB=1

# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh"   # App token for the gh calls below (gh_auth_for / gh_auth_reset)
# Scripted remedies for known conditions (BH-2548). A box whose sync has not
# landed the library fixes nothing, which is exactly the pass before it.
# shellcheck source=bin/lib/responder-fix.sh
. "$H/bin/lib/responder-fix.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/responder-fix.sh" 2>/dev/null \
  || rfix_pass() { :; }
mkdir -p "$H/state/responder" "$H/logs"
HIST="$LLP_STATE/stale-history.json"              # this project's previous stale-owed snapshot + its epoch
HANDLED="$H/state/responder/handled.json"        # per-key last-handled epoch (12h cooldown), shared by every project run
NOW=$(date +%s)
PERSIST_SECS=$((90*60))     # a key stale in two snapshots >=90 min apart has persisted
COOLDOWN_SECS=$((12*3600))  # do not re-work a key the responder touched <12h ago
# HANDLED is shared: every write to it is under this short lock (never a wait
# for another run's life), and a run changes only its own <project>:<key> keys.
HANDLED_LOCK="$HANDLED.lock"
( flock -w 5 8 || exit 1; [ -s "$HANDLED" ] || echo '{}' > "$HANDLED" ) 8>"$HANDLED_LOCK"

PREFETCH=1
lane_switch responder-prefetch-off && PREFETCH=0
# Knobs resolve env -> default. A junk value takes the default and SAYS so:
# silently reading "banana" as 10 is how an operator ends up debugging a knob
# that was never in effect.
_knob() {  # _knob <VARNAME> <default>
  local v="${!1:-}" d="$2"
  case "$v" in
    '') printf '%s' "$d"; return 0 ;;
    0|*[!0-9]*) echo "$(STAMP) knob $1='$v' is not a positive integer — using the default $d" >> "$LOG"
                printf '%s' "$d"; return 0 ;;
  esac
  printf '%s' "$v"
}
THREAD_N=$(_knob RESPONDER_THREAD_COMMENTS 10)

# --- VOLUME CAPS (begin, BH-1039) -------------------------------------------
# This lane already caps its evidence; what it never had is a bound on what the
# DAY may cost (3.9M tokens a call, ~$40 each, every row unpriced). Both now
# come from the same place: bin/lib/lane-caps.sh over catalog/lane-caps.conf,
# per lane, editable without a deploy. RESPONDER_EVIDENCE_CAP_BYTES still wins
# for one run, so nothing an operator already types changes meaning — only the
# DEFAULT moved out of this file.
# shellcheck source=bin/lib/cost-row.sh
. "$H/bin/lib/cost-row.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/cost-row.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lane-caps.sh
. "$H/bin/lib/lane-caps.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/lane-caps.sh" 2>/dev/null || true
command -v lane_day_cap_tripped >/dev/null 2>&1 || lane_day_cap_tripped() { return 1; }
# The documented fallback is the number this file used to carry, so a box whose
# sync has not landed the library caps at exactly what it capped at yesterday.
command -v lane_cap_bytes >/dev/null 2>&1 || lane_cap_bytes() { printf '60000\n'; }
CAP_BYTES=$(_knob RESPONDER_EVIDENCE_CAP_BYTES "$(lane_cap_bytes responder)")
PR_MAX=$(_knob RESPONDER_PR_CALLS_MAX 12)

# --- THE SESSION CEILING (BH-1384) ------------------------------------------
# What the evidence cap above bounds is the PROMPT; what this bounds is the
# SESSION — the 1.7M-3.7M tokens a tooled pass accumulates over its own tool
# loop, which no prompt cap can see. Read through lane_knob so a settings row
# can move it without a deploy, with the documented defaults on a box whose
# sync has not landed bin/lib/lane-gate.sh: 0 and 10000, which is the cliff
# path at today's margin, which on a model with no cliff is today's behaviour
# byte for byte.
command -v lane_knob >/dev/null 2>&1 || lane_knob() { printf ''; }
RESP_CTX_CAP=$(lane_knob watchdog-responder RESPONDER_CONTEXT_CAP_TOKENS)
case "$RESP_CTX_CAP" in ''|*[!0-9]*) RESP_CTX_CAP=0 ;; esac
if [ "$RESP_CTX_CAP" -gt 0 ]; then
  # An operator naming this exact number beats a derivation, so the two are
  # never exported together: CONTEXT_KILL_TOKENS returns before the cliff is
  # ever consulted, and arming both would say the cliff had a vote.
  RESP_CEIL_ENV=(CONTEXT_KILL_TOKENS="$RESP_CTX_CAP")
else
  RESP_CLIFF_MARGIN=$(lane_knob watchdog-responder RESPONDER_CLIFF_MARGIN_TOKENS)
  case "$RESP_CLIFF_MARGIN" in ''|*[!0-9]*) RESP_CLIFF_MARGIN=10000 ;; esac
  RESP_CEIL_ENV=(CONTEXT_KILL_CLIFF=1 CONTEXT_KILL_CLIFF_MARGIN="$RESP_CLIFF_MARGIN")
fi
# Passed as a per-command prefix on the two tooled calls, never exported: the
# decision call and anything else this script runs stay unbounded by it.

# BEFORE THE STALE-OWED PROBE and everything it leads to. A lane that fetches,
# reads threads and burns gh budget before discovering it cannot afford a
# session has already done most of the work that ends in one. Nothing is
# consumed here: handled.json is only written after a pass runs, so every key
# this tick would have covered is offered again next tick.
if lane_day_cap_tripped responder; then
  echo "$(STAMP) responder: STOPPED on the lane's daily spend cap — no probe, no fetch, no session, nothing marked handled (see ALERTS.log)" >> "$LOG"
  exit 0
fi
# --- VOLUME CAPS (end) -------------------------------------------------------

# The stale-owed snapshot. Its own hourly lane writes it (cron/lanes/
# 300-stale-owed-tickets.cron): the sweep loops over every project, so a project
# run never refreshes it. The run keeps only its own project's entry.
CUR_ALL="$H/state/stale-owed.json"
[ -s "$CUR_ALL" ] || exit 0
CUR="$LLP_STATE/stale-owed.json"
if ! jq -c --arg p "$LLP_PROJECT" 'if has($p) then {($p): .[$p]} else {} end' "$CUR_ALL" > "$CUR.tmp" 2>/dev/null; then
  rm -f "$CUR.tmp"
  echo "$(STAMP) responder project=$LLP_PROJECT: state/stale-owed.json does not parse — no pass" >> "$LOG"
  exit 0
fi
mv "$CUR.tmp" "$CUR"

# The cooldown both signals read: handled.json, or with the ledger on a temp
# copy of it merged with the DB rows (max epoch per key). The copy is never
# written back; the stamp at the end of the pass still writes $HANDLED alone.
# A read that fails is one log line and the local file only, never "no brakes".
HANDLED_R="$HANDLED"; HANDLED_TMP=""
if [ "$BRAKE_DB" = 1 ]; then
  ROWS=$(brake_read responder-handled "$COOLDOWN_SECS"); BRC=$?
  if [ "$BRC" -ne 0 ]; then
    echo "$(STAMP) responder: brake ledger read failed (rc=$BRC) — local handled.json only this pass" >> "$LOG"
  else
    [ "${ROWS##*$'\n'}" = "#truncated" ] && echo "$(STAMP) responder: brake ledger read hit its page cap — the DB copy is incomplete this pass, using the rows read" >> "$LOG"
    HANDLED_TMP=$(mktemp "$H/state/responder/handled.merged.XXXXXX") || HANDLED_TMP=""
    if [ -n "$HANDLED_TMP" ] && printf '%s\n' "$ROWS" | jq -R -s --slurpfile loc "$HANDLED" '
         [split("\n")[] | select(length > 0 and (startswith("#") | not)) | split("\t") | {key: .[0], value: (.[1] | tonumber)}]
         | from_entries as $db
         | reduce ($db | to_entries[]) as $e ($loc[0]; .[$e.key] = ([(.[$e.key] // 0), $e.value] | max))' \
         > "$HANDLED_TMP" 2>/dev/null; then
      HANDLED_R="$HANDLED_TMP"
    else
      [ -n "$HANDLED_TMP" ] && rm -f "$HANDLED_TMP"; HANDLED_TMP=""
    fi
  fi
fi

# ---------- signal 1: persisted stale-owed keys ------------------------------
PERSISTED="[]"
if [ -s "$HIST" ]; then
  PREV_TS=$(jq -r '.ts // 0' "$HIST")
  if [ $((NOW - PREV_TS)) -ge "$PERSIST_SECS" ]; then
    # keys present in BOTH snapshots, minus handled-cooldown keys
    PERSISTED=$(jq -nc --slurpfile prev "$HIST" --slurpfile cur "$CUR" --slurpfile h "$HANDLED_R" --argjson now "$NOW" --argjson cd "$COOLDOWN_SECS" '
      [ $cur[0] | to_entries[] | .key as $p | .value.tickets[]?
        | select(. as $t | ($prev[0].snap[$p].tickets // []) | any(.key == $t.key))
        | select(($h[0][($p + ":" + (.key|tostring))] // 0) < ($now - $cd))
        | {project: $p, key, status, waitingOn, hours, title}
      ]')
    # refresh history only when the persist window was actually evaluated
    jq -nc --argjson ts "$NOW" --slurpfile cur "$CUR" '{ts:$ts, snap:$cur[0]}' > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
  fi
else
  jq -nc --argjson ts "$NOW" --slurpfile cur "$CUR" '{ts:$ts, snap:$cur[0]}' > "$HIST.tmp" && mv "$HIST.tmp" "$HIST"
fi

# ---------- signal 2: wedged build queues ------------------------------------
# A queued job >45 min old whose key has no live pool machine = nothing owns it.
WEDGED=""
# One queue dir, this lane's project; an array so the loop body's `continue` keeps its meaning.
QDS=("$H/state/build-queue/$LLP_PROJECT/")
for QD in "${QDS[@]}"; do
  [ -d "$QD" ] || continue
  P="$LLP_PROJECT"
  for JF in "$QD"*.json; do
    [ -f "$JF" ] || continue
    case "$JF" in *.failed.json) continue;; esac
    AGE=$(( NOW - $(stat -c %Y "$JF") ))
    [ "$AGE" -ge 2700 ] || continue
    K=$(jq -r '.key // ""' "$JF" 2>/dev/null); [ -n "$K" ] || continue
    grep -ls "\"key\": *\"$K\"" "$H/state/fly-pool/$P/"*.json >/dev/null 2>&1 && continue
    CK=$(jq -r --arg k "$P:$K" '.[$k] // 0' "$HANDLED_R")
    [ "$CK" -ge $((NOW - COOLDOWN_SECS)) ] && continue
    WEDGED="$WEDGED$P $K queued $((AGE/60))min with no live machine ($JF)\n"
  done
done

# The wedged loop above was the merged copy's last reader.
[ -n "$HANDLED_TMP" ] && rm -f "$HANDLED_TMP"

NP=$(echo "$PERSISTED" | jq 'length')
[ "$NP" -gt 0 ] || [ -n "$WEDGED" ] || exit 0

# Client-authored text (titles) is FLATTENED to one line everywhere it is
# rendered. A prompt now gates a tooled session on `^DECISION:` lines, and a
# ticket title carrying a newline could otherwise put one at the start of a
# line. The parser reads the model's output file and never this text, so this is
# the second layer, not the first — but a board is a place strangers type.
_render_evidence() {  # rendered twice when a scripted remedy settles items (BH-2548)
  printf '%s' "PERSISTED OWED-STALE TICKETS (stale across two sweeps >=90 min apart, mechanical self-heal already failed):
$(echo "$PERSISTED" | jq -r '.[] | "- \(.project) \(.key) [\(.status)/\(.waitingOn)] \(.hours)h: \(.title)" | gsub("[\\n\\r\\t]+"; " ")')

WEDGED QUEUE JOBS:
$(printf '%b' "$WEDGED")"
}
# The sentinel keeps the trailing newline an empty WEDGED list leaves, which a
# bare $(…) would strip: the prompt stays byte for byte what it was.
EVIDENCE=$(_render_evidence; printf x); EVIDENCE="${EVIDENCE%x}"

echo "$(STAMP) responder pass project=$LLP_PROJECT: $NP persisted key(s), wedged=[$(printf '%b' "$WEDGED" | wc -l | tr -d ' ') line(s)]" >> "$LOG"

# The project registry is fleet.conf, never a list typed into a prompt: a
# hardcoded roster goes stale the moment a project is added or parked, and
# then the model names a project that routes nowhere. Same rule as every other
# assumption in this repo - the registry is the source, the prompt is a view.
# $HARNESS, not $H, and they are the same path: it is exported at the top of this
# file (so nothing here is unbound under `set -u` any more), and
# tests/alert-project-routing-test.sh pins this call site verbatim.
FLEET_PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null | grep -xF -- "$LLP_PROJECT" | tr '\n' ' ')
[ -n "${FLEET_PROJECTS// /}" ] || FLEET_PROJECTS="(fleet.conf unreadable - name the project from the alert itself)"

# ---------- the prompt, in pieces --------------------------------------------
# Today's prompt is HEAD + EVIDENCE + step 1 + steps 2-5 + the skeptic line, and
# the kill-switch path below reassembles exactly that. The prefetch path swaps
# step 1 for evidence that is already in the prompt.
# BH-4491: the responder reads ticket threads (fetched by itself, or prefetched
# into the evidence below), so the prompt opens with the untrusted-input rule.
# shellcheck source=bin/lib/untrusted-input.sh
. "$H/bin/lib/untrusted-input.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/untrusted-input.sh" 2>/dev/null || true
RESP_UI_NOTICE=""
command -v ui_notice >/dev/null 2>&1 && RESP_UI_NOTICE="$(ui_notice)"$'\n\n'
RESP_HEAD="${RESP_UI_NOTICE}You are the watchdog FIRST RESPONDER on the harness hub. The mechanical self-heal (stale sweep -> READY-QUEUE -> forced triage) already ran on these signals and they persisted anyway — the box-level watcher could not clear them, so the cause is usually one level up (an unmerged PR, a wrong board state, a wedged queue, a mislabeled turn). Diagnose the current truth of each item and act within bounds."

RESP_STEP1="Read the ticket's FULL thread + status/waitingOn/triageVerdict via its project's board API (access method + conventions in /root/harness/prompts/<project>.md; env in $HENV/<project>.env). THREAD RECENCY IS LAW: the newest comments define the current ask; older confirmations are void."

# What the prefetch actually bought is the THREADS, the decision fields and a
# 3-PR snapshot of state/mergeStateStatus/headRefOid. It did NOT buy step 2d's
# live PR check (review decision, who it waits on) and it did NOT buy step 2e's
# pre-launch duplicate check (branches, the build queue, the pool, the owning
# box's running builds). 2e is a dedup-before-spend guard on a metered path — a
# session that skips it launches a SECOND build for a key that already has one —
# so the prohibition names exactly what is above and nothing more.
RESP_EVIDENCE_ABOVE="The thread, the decision fields and an open-PR snapshot for every item are ABOVE — the harness fetched them before this session started. Do not re-read ticket threads or board lists; they are already in this prompt, and an item whose evidence is MISSING is escalated as \"evidence unavailable\" rather than investigated by going to its board. Everything else the playbook tells you to verify, you still verify with tools: the PR lines above carry only state/mergeStateStatus/headRefOid for at most 3 open PRs, so step 2d's live PR check (review decision, who it waits on) and step 2e's duplicate check before any launch (open PRs and branches for the key, the build queue, the pool state, the owning box's running builds) are NOT in the prefetch and are still owed. THREAD RECENCY IS LAW: the newest comments define the current ask; older confirmations are void."

RESP_STEP1_ACT="$RESP_EVIDENCE_ABOVE Act only on the DECISION lines marked act."

# The fail-open variant. When the decision call answers nothing usable there are
# NO decision lines in the prompt, and pointing the session at them would tell it
# to act on the empty set — the lane would bill two calls, stamp a 12h cooldown
# and do nothing, which is the exact silence this lane exists to fix. So the gate
# sentence is replaced by the instruction it degrades to: today's job, done from
# the evidence that is already here.
RESP_STEP1_ACT_OPEN="$RESP_EVIDENCE_ABOVE The fixed-evidence decision pass returned nothing usable this tick, so there are no DECISION lines below: classify and act on every item above yourself, with the same table and the same bounds."

RESP_STEP2="2. Classify and act:
   a. BALL ACTUALLY WITH CLIENT (their answer/validation is owed): flip waitingOn to the client via the project's turn endpoint. Add ONE short comment only if our side's ask is not already the latest turn — De-AI voice, direct production links per the project's conventions. Never nudge a client more than once per week for the same ask.
   b. FINISHED BUT NEVER CLOSED OUT (work merged + live but no what-shipped comment): verify against production FIRST (real request to the prod URL/API — a merge record is not verification), then post the close-out comment with direct links and set status per that project's convention.
   c. WRONG BOARD STATE (decomposed master sitting in todo/review; done-ticket whose PR is actually unmerged): correct the status per convention with a one-line note.
   d. BLOCKED ON AN UNMERGED PR (ours or an external team's): you may NOT merge, close, or push. Verify the PR's live state with gh (mergeStateStatus, review decision, who it waits on) and include that verified summary in your escalation beat. For an external team's stalled PR you may post one nudge comment ON THE PR (never the board) if none exists from the last 72h.
   e. GENUINELY BUILDABLE (thread confirms mechanism, verdict ready, ball with team, nothing in flight): re-verify no duplicate first — open PRs and branches for the key (gh pr list, git ls-remote), the pool queue/state (/root/harness/state/build-queue/, /root/harness/state/fly-pool/), and the owning box's running builds — then launch: setsid /root/harness/bin/run-build.sh <project> <ticket-id> <KEY> (ticket id from the board API).
   f. INFRA WEDGE (queued job with no owner, stale pool-state file for a destroyed machine, marker files for merged PRs): clean the state file or requeue, exactly one intervention per item, smallest possible."

RESP_STEPS345="3. FORBIDDEN always: gh pr merge/close, pushing code, editing scripts/env/crontabs, prod database writes of any kind beyond the boards' own APIs, creating tickets, promising timelines, claiming anything is tested/live that you did not verify against production this session.
4. Journal one line per item to /root/harness/logs/responder.log: '<utc> <project>:<key> <classification> -> <action taken or escalated>'.
5. Escalate AT MOST ONE beat for the whole pass, and only for items you verified are real and outside your bounds: /root/harness/bin/beat.sh '{\"kind\":\"fleet_alert\",\"project\":\"<the project this is about, spelled exactly as in the FLEET table (valid names, rendered from fleet.conf on this run: $FLEET_PROJECTS). Leave it EMPTY only when the problem is genuinely fleet-wide and belongs to no single project — the project is what routes this alert to its own Telegram topic, so a blank one buries a project problem in the General channel with everybody else's.)\",\"akey\":\"responder:<utc-hour>\",\"line\":\"RESPONDER: <per item: what is truly stuck + the ONE decision/action needed and from whom>\"}'. A healthy or self-resolved item gets journaled, never escalated."

RESP_TAIL="Be a skeptic: the signal may be stale — verify current truth before every action, prefer the smallest intervention, never duplicate work another lane (watcher, medic, merge queue, a running build) already owns."

# ---------- evidence prefetch (BH-654) ---------------------------------------
_blen() { LC_ALL=C printf '%s' "${1:-}" | wc -c | tr -d ' '; }

RCACHE=""
_rcache() {  # one temp dir per pass for the board lists and the per-key blocks
  [ -n "$RCACHE" ] && return 0
  RCACHE=$(mktemp -d "${TMPDIR:-/tmp}/responder-evidence.XXXXXX") || return 1
  trap 'rm -rf "$RCACHE"' EXIT
}

_conf() {  # _conf <project> <field> — fleet.conf field, "-" normalised to empty
  local v
  v=$("$H/bin/fleet-conf.sh" "$1" "$2" 2>/dev/null) || v=""
  [ "$v" = "-" ] && v=""
  printf '%s' "$v"
}

# _tickets_file <project> — the project's board ticket list, fetched ONCE per
# pass (two GETs: the board list, then its tickets). Prints the cache path on
# success; on failure prints the reason and returns 1 — every caller turns that
# reason into a MISSING line rather than an empty thread.
_tickets_file() {
  # Two `local`s on purpose: in one statement the right-hand sides are expanded
  # BEFORE the new locals exist, so `F` would be built from the CALLER's $P —
  # and every project would then share one cache file and answer from another
  # project's board list (shellcheck SC2318).
  local P="$1"
  local F="$RCACHE/tickets-$P.json" E="$RCACHE/ticketsfail-$P"
  local BASE PREFIX TOKEN BOARDS BID MISS=""
  [ -f "$F" ] && { printf '%s' "$F"; return 0; }
  [ -f "$E" ] && { cat "$E"; return 1; }
  BASE=$(_conf "$P" prod); PREFIX=$(_conf "$P" board_prefix)
  TOKEN=$("$H/bin/internal-token-for.sh" "$P" 2>/dev/null) || TOKEN=""
  [ -n "$BASE" ]   || MISS="$MISS no prod base url"
  [ -n "$PREFIX" ] || MISS="$MISS no board API prefix in fleet.conf"
  [ -n "$TOKEN" ]  || MISS="$MISS token unreadable"
  if [ -n "$MISS" ]; then
    printf 'no board access for %s (%s)' "$P" "${MISS# }" > "$E"; cat "$E"; return 1
  fi
  BOARDS=$(curl -s -m 20 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" \
    "$BASE$PREFIX/boards" 2>/dev/null) || BOARDS=""
  BID=$(printf '%s' "$BOARDS" | jq -r 'if type=="array" then (.[0].id // empty) else (.boards[0].id // empty) end' 2>/dev/null) || BID=""
  if [ -z "$BID" ]; then
    printf 'board list unreadable for %s' "$P" > "$E"; cat "$E"; return 1
  fi
  curl -s -m 30 -H "Authorization: Bearer $TOKEN" -H "User-Agent: curl/8" \
    "$BASE$PREFIX/boards/$BID/tickets" > "$F.part" 2>/dev/null
  if ! jq -e 'type=="array" or type=="object"' "$F.part" >/dev/null 2>&1; then
    rm -f "$F.part"; printf 'ticket list for %s unreadable' "$P" > "$E"; cat "$E"; return 1
  fi
  mv "$F.part" "$F"; printf '%s' "$F"
}

# _ticket_id <project> <key> — stale-owed.json carries no id and no URL, so the
# key is resolved against the board list. Same first-board choice the sweep that
# produced the key makes (bin/stale-owed-tickets.sh).
_ticket_id() {
  local P="$1" K="$2" F ID
  F=$(_tickets_file "$P") || { printf '%s' "$F"; return 1; }
  ID=$(jq -r --arg k "$K" '
    (if type=="array" then . else (.tickets // .data // []) end)[]
    | select((((.key // "") | tostring) == $k)
             or (("#" + ((.number // "") | tostring)) == $k)
             or (((.id // "") | tostring) == $k))
    | .id' "$F" 2>/dev/null | head -1) || ID=""
  if [ -z "$ID" ] || [ "$ID" = null ]; then
    printf 'key %s is not on the %s board list' "$K" "$P"; return 1
  fi
  printf '%s' "$ID"
}

# GitHub reads are non-essential by the budget library's definition, so they are
# the first thing to skip when the token is close to its limit — and the skip is
# a MISSING line, never a silent gap.
GH_LOW=0
if [ "$PREFETCH" = 1 ] && [ "$NP" -gt 0 ] && [ -r "$H/bin/lib/gh-budget.sh" ]; then
  # shellcheck source=bin/lib/gh-budget.sh
  . "$H/bin/lib/gh-budget.sh" 2>/dev/null || true
  if command -v gh_budget_low >/dev/null 2>&1; then
    # rc 0 = low (skip), 1 = healthy, 2 = unknown (proceed, same as every other
    # consumer of this library).
    gh_budget_low responder >/dev/null 2>&1 && GH_LOW=1
  fi
fi
GH_CALLS=0   # hard per-pass ceiling: the responder must not starve the conductor

# _pr_lines <project> <key> — open PRs matching the key, with exactly the fields
# the ticket names. THREE distinct answers, because collapsing them is the bug:
#   "PRs: none open matching K"  the search ran and found nothing
#   "PR #n <state>/<mss> head=…" found
#   "PR state: MISSING (…)"      we did not look, and why
_pr_lines() {
  local P="$1" K="$2" SLUG OUT RC NUMS N V VRC URL ERR
  if [ "$GH_LOW" = 1 ]; then
    printf 'PR state: MISSING (gh budget low)\n'; return 0
  fi
  SLUG=$(_conf "$P" repo)
  if [ -z "$SLUG" ]; then
    printf 'PR state: MISSING (repo not in fleet.conf for %s)\n' "$P"; return 0
  fi
  if [ "$GH_CALLS" -ge "$PR_MAX" ]; then
    printf 'PR state: MISSING (gh call cap RESPONDER_PR_CALLS_MAX=%s reached this pass)\n' "$PR_MAX"; return 0
  fi
  ERR="$RCACHE/gh-err"
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$SLUG" || true
  GH_CALLS=$((GH_CALLS+1))
  OUT=$(gh pr list -R "$SLUG" --state open --search "$K" \
        --json number,url,state,headRefName --limit 3 2>"$ERR"); RC=$?
  if [ "$RC" -ne 0 ]; then
    printf 'PR state: MISSING (rc=%s: %s)\n' "$RC" "$(head -1 "$ERR" 2>/dev/null | cut -c1-160)"
    return 0
  fi
  NUMS=$(printf '%s' "$OUT" | jq -r 'if type=="array" then (.[].number // empty) else empty end' 2>/dev/null) || NUMS=""
  if [ -z "$NUMS" ]; then
    printf 'PRs: none open matching %s\n' "$K"; return 0
  fi
  for N in $NUMS; do
    if [ "$GH_CALLS" -ge "$PR_MAX" ]; then
      printf 'PR #%s state: MISSING (gh call cap RESPONDER_PR_CALLS_MAX=%s reached this pass)\n' "$N" "$PR_MAX"
      continue
    fi
    GH_CALLS=$((GH_CALLS+1))
    V=$(gh pr view "$N" -R "$SLUG" --json state,mergeStateStatus,headRefOid 2>"$ERR"); VRC=$?
    if [ "$VRC" -ne 0 ] || [ -z "$V" ]; then
      printf 'PR #%s state: MISSING (rc=%s: %s)\n' "$N" "$VRC" "$(head -1 "$ERR" 2>/dev/null | cut -c1-160)"
      continue
    fi
    URL=$(printf '%s' "$OUT" | jq -r --argjson n "$N" '.[] | select(.number == $n) | .url // "?"' 2>/dev/null | head -1)
    printf '%s' "$V" | jq -r --arg n "$N" --arg u "${URL:-?}" \
      '"PR #\($n) \(.state // "?")/\(.mergeStateStatus // "?") head=\((.headRefOid // "?")[0:12]) \($u)"' 2>/dev/null \
      || printf 'PR #%s state: MISSING (gh answered something that is not a PR)\n' "$N"
  done
}

# _key_evidence <index> <project> <key> <snapshot-title> — writes the key's
# header block (title, decision fields, PR state, or the MISSING line saying
# why) to $RCACHE/hdr-<i>, and one line per comment, OLDEST FIRST, to
# $RCACHE/cmt-<i>. The cap below spends the comment file from its old end.
_key_evidence() {
  local I="$1" P="$2" K="$3" STITLE="$4"
  local HDR="$RCACHE/hdr-$I" CMT="$RCACHE/cmt-$I"
  local ID RAW BASE PREFIX TOKEN SL CL HASC BTITLE
  : > "$HDR"; : > "$CMT"
  if ! ID=$(_ticket_id "$P" "$K"); then
    printf -- '### %s:%s — %s (snapshot title; the board record could not be read)\n' "$P" "$K" "$STITLE" >> "$HDR"
    printf 'EVIDENCE MISSING for %s:%s — thread: %s\n' "$P" "$K" "$ID" >> "$HDR"
    _pr_lines "$P" "$K" >> "$HDR"
    return 0
  fi
  BASE=$(_conf "$P" prod); PREFIX=$(_conf "$P" board_prefix)
  TOKEN=$("$H/bin/internal-token-for.sh" "$P" 2>/dev/null) || TOKEN=""
  RAW=$(INTERNAL_TOKEN="$TOKEN" "$H/bin/board-fetch.sh" "$BASE$PREFIX/tickets/$ID" \
        --last "$THREAD_N" 2>/dev/null) || RAW=""
  case "$RAW" in
    ''|'BOARD-FETCH FAILED:'*)
      printf -- '### %s:%s — %s (snapshot title; the board record could not be read)\n' "$P" "$K" "$STITLE" >> "$HDR"
      if [ -z "$RAW" ]; then
        printf 'EVIDENCE MISSING for %s:%s — thread: board-fetch returned nothing for ticket %s\n' "$P" "$K" "$ID" >> "$HDR"
      else
        printf 'EVIDENCE MISSING for %s:%s — thread: %s\n' "$P" "$K" "$(head -1 <<<"$RAW")" >> "$HDR"
      fi
      _pr_lines "$P" "$K" >> "$HDR"
      return 0 ;;
  esac
  BTITLE=$(printf '%s' "$RAW" | jq -r '
    (if type=="object" then . else {} end) | (.ticket // .data // .)
    | (.title // "") | gsub("[\\n\\r\\t]+"; " ")' 2>/dev/null) || BTITLE=""
  [ -n "$BTITLE" ] && [ "$BTITLE" != null ] || BTITLE="$STITLE (snapshot title; the fetched record carries none)"
  printf -- '### %s:%s — %s\n' "$P" "$K" "$BTITLE" >> "$HDR"
  SL=$(printf '%s' "$RAW" | jq -r '
    (if type=="object" then . else {} end) | (.ticket // .data // .)
    | "FIELDS: status=\(.status // "?") waitingOn=\(.waitingOn // "?") triageVerdict=\(.triageVerdict // "?") turn=\(.turnChangedAt // "?") updated=\(.updatedAt // .lastActivityAt // "?")"
    | gsub("[\\n\\r\\t]+"; " ")' 2>/dev/null) || SL=""
  [ -n "$SL" ] || SL="FIELDS: status=? waitingOn=? triageVerdict=? (decision fields: shape not recognised)"
  printf '%s\n' "$SL" >> "$HDR"
  _pr_lines "$P" "$K" >> "$HDR"
  HASC=$(printf '%s' "$RAW" | jq -r '
    if type=="object" and (((.comments|type)=="array") or ((.ticket.comments?|type)=="array") or ((.data.comments?|type)=="array"))
    then "yes" else "no" end' 2>/dev/null) || HASC=no
  if [ "$HASC" != yes ]; then
    printf -- 'THREAD: MISSING — the fetched record has no comment array this fetcher recognises (%s bytes)\n' "$(_blen "$RAW")" >> "$HDR"
    return 0
  fi
  # One line per comment: the cap drops whole comments, and a body with newlines
  # in it would otherwise take its neighbours' budget with it.
  CL=$(printf '%s' "$RAW" | jq -r '
    (if (.comments|type)=="array" then .comments
     elif (.ticket.comments?|type)=="array" then .ticket.comments
     else .data.comments end)[]
    | if has("_omitted") then "-- [\(._omitted) earlier comments omitted by the trimmer]"
      else ((.body // .content // .text // "") | tostring | gsub("[\\n\\r\\t]+"; " ")) as $b
           | "-- [\(.createdAt // .created_at // "?")] \(.author.name? // .author? // .authorName? // "?")\(if (.isInternal // false) then " (internal)" else "" end): "
             + (if ($b|length) > 1500 then ($b[0:1500] + "…[cut]") else $b end)
      end' 2>/dev/null) || CL=""
  if [ -n "$CL" ]; then
    printf 'THREAD (oldest kept first, newest LAST — recency is law):\n' >> "$HDR"
    printf '%s\n' "$CL" >> "$CMT"
  else
    printf -- 'THREAD: no comments on this ticket\n' >> "$HDR"
  fi
}

OFFERED_LIST=""
PF_BLOCKS=""
PF_HEADER=""
NB=0
KEYIDS=()
NFIX=0      # items a scripted remedy settled this pass (BH-2548)
if [ "$PREFETCH" = 1 ]; then
  _rcache || true
  if [ -n "$RCACHE" ]; then
    while IFS=$'\t' read -r EP EK ET; do
      [ -n "${EP:-}" ] && [ -n "${EK:-}" ] || continue
      _key_evidence "$NB" "$EP" "$EK" "${ET:-(untitled)}"
      KEYIDS+=("$EP:$EK")
      NB=$((NB+1))
    done < <(echo "$PERSISTED" | jq -r '.[] | [.project, (.key|tostring), (.title // "(untitled)")] | @tsv')
    # THE MODEL RUNS ONLY ON AN UNKNOWN CONDITION (BH-2548). Items whose evidence
    # matches a known condition with a remedy row are settled, journalled and
    # stamped by bin/lib/responder-fix.sh, then dropped from everything below:
    # the item list, the evidence, the prompt. Dry runs only journal.
    rfix_pass "$RCACHE" "${RESPONDER_DRY:-0}"
    if [ -s "$RCACHE/fixed-keys" ]; then
      NFIX=$(sort -u "$RCACHE/fixed-keys" | wc -l | tr -d ' ')
      PERSISTED=$(echo "$PERSISTED" | jq -c --rawfile fx "$RCACHE/fixed-keys" '
        ($fx | split("\n") | map(select(length > 0))) as $f
        | [.[] | select((.project + ":" + (.key|tostring)) as $pk | any($f[]; . == $pk) | not)]')
      NP=$(echo "$PERSISTED" | jq 'length')
      EVIDENCE=$(_render_evidence; printf x); EVIDENCE="${EVIDENCE%x}"
      if [ "$NP" -eq 0 ] && [ -z "$WEDGED" ]; then
        echo "$(STAMP) responder: all $NFIX item(s) matched a scripted condition — no model call this pass" >> "$LOG"
        command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
        exit 0
      fi
      echo "$(STAMP) responder: $NFIX item(s) settled by a scripted remedy; $NP persisted key(s) left for the model" >> "$LOG"
    fi
  fi
  OFFERED_LIST=$(printf '%s\n%s' \
    "$(echo "$PERSISTED" | jq -r '.[] | .project + ":" + (.key|tostring)')" \
    "$(printf '%b' "$WEDGED" | awk 'NF {print $1 ":" $2}')" | awk 'NF')
  if [ "$NB" -gt "$NFIX" ]; then
    PF_HEADER="PREFETCHED EVIDENCE — fetched $(date -u '+%Y-%m-%dT%H:%M:%SZ') by the harness. Per ticket: the decision fields, the newest $THREAD_N comments (oldest first, newest LAST — recency is law) and open-PR state. A line marked MISSING means the harness could NOT fetch that item: treat it as UNKNOWN, never as empty, and say so in your decision."
  elif [ "$NP" -gt 0 ]; then
    # Says the true thing in this state too: there ARE tickets, we just could
    # not build the workspace to fetch them into.
    PF_HEADER="PREFETCHED EVIDENCE — MISSING for every item: the harness could not create its evidence workspace (mktemp failed), so no thread and no PR state was fetched this pass. Treat every item above as UNKNOWN."
  else
    PF_HEADER="PREFETCHED EVIDENCE — nothing to fetch this pass: no persisted owed-stale ticket, only the wedged queue job(s) listed above."
  fi
fi

RESP_DECIDE="You have NO tools in this session. Do not attempt to read, fetch or run anything — everything you get is above. Reply with exactly one line per item, nothing else:
DECISION: <project>:<key> :: <a|b|c|d|e|f|healthy> :: <none|act> :: <one-line reason>
Use \"act\" only when the playbook step for that class requires a write, a launch, a state-file change or an escalation beat that you would perform if you had tools. Use \"none\" when the item is healthy or already self-resolved and nothing is owed on it.
An item whose evidence is MISSING is \"act\". The harness could not read that item, so the action owed is the escalation: the tooled pass reports it as \"evidence unavailable\" and names what could not be read. Deciding \"none\" on a MISSING item stamps its 12h cooldown and sends nothing — that is the one answer that is always wrong here.

ITEMS THIS PASS (use these exact <project>:<key> strings):
$OFFERED_LIST"

# ---------- the cap, spent from the OLD end ----------------------------------
# The ceiling is on the WHOLE rendered prompt, so the fixed text is measured
# first — the LONGER of the two scaffolds, so both calls are bounded — and what
# is left is split evenly across the keys. Inside a key the header (title,
# decision fields, PR state) is kept whole and comments are dropped OLDEST-first,
# because the newest comment is the one that defines the current ask.
FIXED_HEAD=""
FIXED_TAIL_DECIDE=""
FIXED_TAIL_ACT=""
if [ "$PREFETCH" = 1 ]; then
  FIXED_HEAD="$RESP_HEAD

$EVIDENCE

$PF_HEADER

"
  FIXED_TAIL_DECIDE="PLAYBOOK — classify every item above with the same table the act pass uses:
$RESP_STEP2

$RESP_DECIDE"
  FIXED_TAIL_ACT="PLAYBOOK — for each persisted ticket, in order:
1. $RESP_STEP1_ACT
$RESP_STEP2
$RESP_STEPS345

$RESP_TAIL"
  FIXED_TAIL_ACT_OPEN="PLAYBOOK — for each persisted ticket, in order:
1. $RESP_STEP1_ACT_OPEN
$RESP_STEP2
$RESP_STEPS345

$RESP_TAIL"
  DEC_RESERVE=2000                       # the act prompt's DECISIONS block
  # All THREE tails are measured: the fail-open act prompt is a real rendering of
  # this budget, so a cap that bounds only the other two does not bound the pass.
  LTD=$(_blen "$FIXED_TAIL_DECIDE"); LTA=$(_blen "$FIXED_TAIL_ACT")
  LTAO=$(_blen "$FIXED_TAIL_ACT_OPEN")
  MAXTAIL=$LTD; [ "$LTA" -gt "$MAXTAIL" ] && MAXTAIL=$LTA
  [ "$LTAO" -gt "$MAXTAIL" ] && MAXTAIL=$LTAO
  # The evidence goes out fenced as one ui_wrap block (BH-4491); its two
  # delimiter lines are fixed text too. ui_wrap never makes the text longer.
  UI_FENCE=0
  command -v ui_wrap >/dev/null 2>&1 && UI_FENCE=$(( $(printf '' | ui_wrap ticket-thread | wc -c) + 2 ))
  FIXED=$(( $(_blen "$FIXED_HEAD") + MAXTAIL + UI_FENCE ))
  BUDGET=$(( CAP_BYTES - FIXED - DEC_RESERVE ))
  SHARE=0
  # A key a scripted remedy settled has no block, so it takes no share.
  NLIVE=$(( NB - NFIX ))
  [ "$NLIVE" -gt 0 ] && [ "$BUDGET" -gt 0 ] && SHARE=$(( BUDGET / NLIVE ))
  if [ "$NB" -gt 0 ] && [ "$BUDGET" -le 0 ]; then
    echo "$(STAMP) RESPONDER_EVIDENCE_CAP_BYTES=$CAP_BYTES leaves no room past the ${FIXED}B fixed prompt — no thread evidence this pass" >> "$LOG"
  fi
  I=0
  while [ "$I" -lt "$NB" ]; do
    if [ -s "$RCACHE/fixed-keys" ] && grep -qxF -- "${KEYIDS[$I]}" "$RCACHE/fixed-keys"; then
      I=$((I+1)); continue
    fi
    BHDR=$(cat "$RCACHE/hdr-$I" 2>/dev/null)
    KEEP=$(( SHARE - $(_blen "$BHDR") - 200 ))
    if [ "$BUDGET" -le 0 ] || [ "$KEEP" -lt 200 ]; then
      # Say it, per key. An evidence block that is silently absent reads exactly
      # like a ticket with nothing on its thread.
      PF_BLOCKS="$PF_BLOCKS### ${KEYIDS[$I]}
EVIDENCE DROPPED for ${KEYIDS[$I]} — prompt cap ${CAP_BYTES}B leaves no room for its thread

"
      I=$((I+1)); continue
    fi
    CLINES=(); USED=0; DROPPED=0
    mapfile -t ALLC < "$RCACHE/cmt-$I"
    J=$(( ${#ALLC[@]} - 1 ))
    while [ "$J" -ge 0 ]; do
      L=$(( $(_blen "${ALLC[$J]}") + 1 ))
      if [ $(( USED + L )) -gt "$KEEP" ]; then DROPPED=$(( J + 1 )); break; fi
      USED=$(( USED + L ))
      CLINES=("${ALLC[$J]}" ${CLINES[@]+"${CLINES[@]}"})
      J=$(( J - 1 ))
    done
    BLOCK="$BHDR"
    [ "$DROPPED" -gt 0 ] && BLOCK="$BLOCK
-- [capped: dropped $DROPPED older comment(s) to fit RESPONDER_EVIDENCE_CAP_BYTES]"
    if [ "${#CLINES[@]}" -gt 0 ]; then
      BLOCK="$BLOCK
$(printf '%s\n' "${CLINES[@]}")"
    fi
    # Backstop: one comment can be larger than the whole share.
    if [ "$(_blen "$BLOCK")" -gt "$SHARE" ]; then
      BLOCK="$(head -c "$SHARE" < <(printf '%s' "$BLOCK"))
-- [capped: truncated to fit RESPONDER_EVIDENCE_CAP_BYTES]"
    fi
    PF_BLOCKS="$PF_BLOCKS$BLOCK

"
    I=$((I+1))
  done

  # Last-resort guard. The per-key share is what is supposed to bind; if some
  # shape we have not seen still blows the ceiling, the evidence is cut from its
  # HEAD (oldest first, same rule) and the prompt says it was cut. Only when
  # there was room for evidence at all — cutting the DROPPED markers of a pass
  # that fetched nothing would hide the one fact the prompt has to carry.
  WORST=$(( $(_blen "$FIXED_HEAD") + $(_blen "$PF_BLOCKS") + MAXTAIL + DEC_RESERVE + UI_FENCE ))
  if [ "$BUDGET" -gt 0 ] && [ "$WORST" -ge "$CAP_BYTES" ]; then
    OVER=$(( WORST - CAP_BYTES + 256 ))
    PF_BLOCKS="[evidence truncated to fit cap]
$(printf '%s' "$PF_BLOCKS" | tail -c "+$((OVER+1))")"
    echo "$(STAMP) evidence cut by the last-resort guard: ${WORST}B worst-case prompt over the ${CAP_BYTES}B cap" >> "$LOG"
  fi

  if [ -n "$PF_BLOCKS" ] && command -v ui_wrap >/dev/null 2>&1; then
    PF_BLOCKS="$(printf '%s' "$PF_BLOCKS" | ui_wrap ticket-thread)

"
  fi
  PROMPT_DECIDE="$FIXED_HEAD$PF_BLOCKS$FIXED_TAIL_DECIDE"
  PROMPT="$PROMPT_DECIDE"
else
  PROMPT="$RESP_HEAD

$EVIDENCE

PLAYBOOK — for each persisted ticket, in order:
1. $RESP_STEP1
$RESP_STEP2
$RESP_STEPS345

$RESP_TAIL"
fi

if [ "${RESPONDER_DRY:-0}" = 1 ]; then
  printf '%s\n' "$PROMPT"
  exit 0                                    # dry runs never burn the cooldown
fi

# >>> model-route (BH-1510.2): every responder call runs on model_routes role
# `responder`. No route = rc 75 BEFORE any call, and before the cooldown marking
# below, so no key is stamped handled by a pass that looked at nothing. The role
# is alerted by bin/lib/model-route.sh; nothing is guessed.
. "$H/bin/lib/lane-model.sh"
RESPONDER_M=$(lane_role_model responder) \
  || { echo "$(STAMP) responder: no model route for role responder — pass skipped" >> "$LOG"; exit 75; }
# <<< model-route

# ---------- the session(s) ---------------------------------------------------
# RESP_RC is the rc of the LAST call this pass made — the one the cooldown
# marking at the bottom is allowed to read. 74..79 is bin/agent-call.sh's
# before-billing family (BH-1141: the lane's own gate, a lock, no account with
# headroom, the hub refusing build work, a no-tools or argv-only refusal), and a
# pass that made no call must not stamp a 12h cooldown on the keys it never
# looked at.
RESP_RC=0
RUN_OUT="$H/logs/responder-run.$LLP_PROJECT.txt"
# ONE HONEST LINE WHEN THE CEILING STOPPED THE SESSION (BH-1384). The rc alone
# says 143, which reads as any other kill; the marker files say which bound
# fired and at what total. The cooldown wording is the TRUE one: 143 is outside
# the 74..79 no-call family below, so the keys this pass was offered ARE stamped
# and come back after the 12h cooldown, not next tick.
_resp_ctxkill_note() {  # _resp_ctxkill_note <outfile>
  local out="$1" ck="" cc="" kv tag="CONTEXT KILL" cliff="" model="" tot="" cap="" why=""
  [ -f "$out.ctxkill" ] || return 0
  read -r ck < "$out.ctxkill" || true
  for kv in $ck; do
    case "$kv" in ceiling=*) cap="${kv#*=}" ;; total=*) tot="${kv#*=}" ;; esac
  done
  if [ -f "$out.cliffcap" ]; then
    read -r cc < "$out.cliffcap" || true
    for kv in $cc; do
      case "$kv" in cliff=*) cliff="${kv#*=}" ;; model=*) model="${kv#*=}" ;; esac
    done
    # THE BILLING CLAUSE RIDES THE CLIFF, NOT THE STOP. "no 2x bill" is only
    # true when the cliff is what lowered the ceiling; an ordinary lane-cap stop
    # never had a doubled band in play.
    [ -n "$cliff" ] && { tag="CLIFF-AVOIDED"; why=" (cliff $cliff for $model) — no 2x bill"; }
  fi
  echo "$(STAMP) responder act session $tag: stopped at $tot against ceiling $cap$why; the keys this pass covered are stamped handled and come back after the 12h cooldown." >> "$LOG"
}
if [ "$PREFETCH" = 0 ]; then
  rm -f "$RUN_OUT.ctxkill" "$RUN_OUT.cliffcap"
  env "${RESP_CEIL_ENV[@]}" "$H/bin/agent-call.sh" triage responder "$RESPONDER_M" 2400 "$RUN_OUT" "$PROMPT" >/dev/null 2>&1
  RESP_RC=$?
  echo "$(STAMP) responder session rc=$RESP_RC" >> "$LOG"
  _resp_ctxkill_note "$RUN_OUT"
else
  DEC_OUT="$H/logs/responder-decide.$LLP_PROJECT.txt"
  : > "$DEC_OUT"
  # PINNED TO THE CLAUDE RUNG, per call (BH-1384). bin/agent-call.sh REFUSES a
  # no-tools call on a non-claude primary with rc 78, and which runner triage
  # gets is one env line away (RUNNER_TRIAGE). AGENT_CALL_RUNNERS replaces a
  # disallowed primary with the first name in the list BEFORE that check, so
  # the refusal becomes unreachable by construction. It is a prefix and not an
  # export on purpose: the act call below keeps the whole ladder.
  AGENT_CALL_RUNNERS=claude AGENT_CALL_NO_TOOLS=1 "$H/bin/agent-call.sh" triage responder "$RESPONDER_M" 900 "$DEC_OUT" "$PROMPT_DECIDE" >/dev/null 2>&1
  DRC=$?
  echo "$(STAMP) responder decision call (no tools, claude) rc=$DRC" >> "$LOG"

  # Parse the MODEL'S OUTPUT FILE and nothing else. A ticket comment can contain
  # the word DECISION — reading the prompt back would let a client's text buy a
  # tooled session on their own board.
  VALID=0; NACT=0; IGN=0; DEC_TEXT=""
  while IFS= read -r LINE || [ -n "${LINE:-}" ]; do
    case "$LINE" in *DECISION*) ;; *) continue ;; esac
    if [[ "$LINE" =~ ^[[:space:]]*DECISION:[[:space:]]+([^[:space:]]+):([^[:space:]]+)[[:space:]]+::[[:space:]]+([A-Za-z]+)[[:space:]]+::[[:space:]]+(none|act)[[:space:]]+::[[:space:]]*(.*)$ ]]; then
      DITEM="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"
      DCLS="${BASH_REMATCH[3]}"; DACT="${BASH_REMATCH[4]}"; DWHY="${BASH_REMATCH[5]:0:200}"
      if grep -qxF -- "$DITEM" <<<"$OFFERED_LIST"; then
        VALID=$((VALID+1))
        [ "$DACT" = act ] && NACT=$((NACT+1))
        # Playbook step 4, for the part bash actually knows: the no-tools call
        # cannot journal, so the script does — and it is journalled BEFORE the
        # act call is spent, not after.
        echo "$(STAMP) $DITEM $DCLS -> $DACT $DWHY" >> "$LOG"
        DEC_TEXT="$DEC_TEXT
DECISION: $DITEM :: $DCLS :: $DACT :: $DWHY"
        continue
      fi
    fi
    IGN=$((IGN+1))
    echo "$(STAMP) ignored decision line: $(printf '%s' "$LINE" | cut -c1-160)" >> "$LOG"
  done < "$DEC_OUT"

  RUN_ACT=0
  if [ "$VALID" -eq 0 ]; then
    # Fail OPEN. A decision step that answers nothing (rc!=0, a refusal, an
    # empty file, all-malformed) must not turn the responder into silence — the
    # lane exists because silence is what it is fixing.
    echo "$(STAMP) decision call produced no decisions (rc=$DRC, ignored=$IGN) — running the tooled pass anyway" >> "$LOG"
    RUN_ACT=1; DEC_TEXT=""
  elif [ "$NACT" -gt 0 ]; then
    RUN_ACT=1
  else
    echo "$(STAMP) all $VALID item(s) decided none — no act pass this tick" >> "$LOG"
  fi

  if [ "$RUN_ACT" = 1 ]; then
    # The tail follows the block. With decisions rendered, the act call is gated
    # on them; on the fail-open path there is no block to point at, so it gets
    # the variant that tells it to classify the items itself. Handing the gated
    # tail to a prompt with no DECISIONS block is an instruction that is false in
    # the exact state that renders it.
    DEC_BLOCK=""; TAIL_ACT="$FIXED_TAIL_ACT_OPEN"
    if [ "$VALID" -gt 0 ] && [ -n "$DEC_TEXT" ]; then
      DEC_BLOCK="DECISIONS FROM THE FIXED-EVIDENCE PASS (act only on the ones marked act):$(head -c "$((DEC_RESERVE - 200))" < <(printf '%s' "$DEC_TEXT"))

"
      TAIL_ACT="$FIXED_TAIL_ACT"
    fi
    PROMPT_ACT="$FIXED_HEAD$PF_BLOCKS$DEC_BLOCK$TAIL_ACT"
    # THE MARKERS BELONG TO THE CALL BELOW, NOT TO A PREVIOUS TICK: a ladder that
    # never reaches agent-call's claude arm would otherwise leave an old marker.
    rm -f "$RUN_OUT.ctxkill" "$RUN_OUT.cliffcap"
    env "${RESP_CEIL_ENV[@]}" "$H/bin/agent-call.sh" triage responder "$RESPONDER_M" 2400 "$RUN_OUT" "$PROMPT_ACT" >/dev/null 2>&1
    RESP_RC=$?
    echo "$(STAMP) responder act session rc=$RESP_RC" >> "$LOG"
    _resp_ctxkill_note "$RUN_OUT"
  fi
fi

# Mark everything offered to this pass as handled (cooldown), even on session
# failure — a crashing responder must not retry-loop the same keys every tick.
#
# EXCEPT WHEN NOTHING WAS CALLED (BH-1141 round 2, I4). A session that FAILED
# read the evidence and cost money, so re-offering it every two minutes is the
# loop this cooldown exists to stop. A session that was REFUSED before the call
# read nothing and cost nothing, so the keys it was offered have not been looked
# at — stamping them would throw away up to 12h of wedged-ticket detection for
# an operator who turned the lane off for ten minutes, and re-offering them
# costs $0 because the gate refuses again at the same price.
if [ "$RESP_RC" -ge 74 ] && [ "$RESP_RC" -le 79 ]; then
  echo "$(STAMP) responder pass made no call (rc=$RESP_RC: nothing called, nothing billed) — no cooldown stamped; the same keys come back next tick" >> "$LOG"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  exit 0
fi
MARK=$(jq -nc --slurpfile p <(echo "$PERSISTED") '[$p[0][] | .project + ":" + (.key|tostring)]')
WEDGEKEYS="$LLP_STATE/.wedgekeys"
printf '%b' "$WEDGED" | while read -r P K _; do [ -n "${K:-}" ] && echo "$P:$K"; done > "$WEDGEKEYS"
# Re-read and rewrite under the short lock, so two project runs that stamp at the
# same moment both keep their keys. A lock that is not free in 5 s stamps
# nothing: the items come back next pass, never a false "handled".
if ! (
  flock -w 5 8 || exit 1
  jq -c --argjson now "$NOW" --argjson keys "$MARK" --rawfile wk "$WEDGEKEYS" \
    'reduce (($keys[]), ($wk | split("\n")[] | select(length > 0))) as $k (.; .[$k] = $now)' \
    "$HANDLED" > "$HANDLED.$LLP_PROJECT.tmp" && mv "$HANDLED.$LLP_PROJECT.tmp" "$HANDLED"
) 8>"$HANDLED_LOCK"; then
  rm -f "$HANDLED.$LLP_PROJECT.tmp" "$WEDGEKEYS"
  echo "$(STAMP) responder project=$LLP_PROJECT: handled.json lock not free in 5 s or the rewrite failed — nothing stamped; the same keys come back next pass" >> "$LOG"
  command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  exit 0
fi
# The write-through, AFTER the local stamp: the same MARK and wedge keys, P:K
# verbatim. A failed row leaves the file stamp standing and is one line a pass.
if [ "$BRAKE_DB" = 1 ]; then
  BM_N=0; BM_FAIL=0
  while read -r BK; do
    [ -n "$BK" ] || continue
    BM_N=$((BM_N+1))
    brake_mark responder-handled "$BK" "$NOW" || BM_FAIL=$((BM_FAIL+1))
  done < <(jq -r '.[]' <<< "$MARK"; cat "$WEDGEKEYS")
  [ "$BM_FAIL" -gt 0 ] && echo "$(STAMP) responder: brake ledger mark failed for $BM_FAIL of $BM_N key(s) — local handled.json stamp stands" >> "$LOG"
fi
rm -f "$WEDGEKEYS"
command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
exit 0
