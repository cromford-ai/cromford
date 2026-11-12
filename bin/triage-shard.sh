#!/bin/bash
# bin/triage-shard.sh <project> <key> <prompt-file>
#
# ONE TRIAGER FOR ONE TICKET (the operator, 2026-09-14: "can we get multiple triagers
# like we have multiple builders? ... do that"). bin/run-triage.sh used to BE the
# triager: one agent call per project per tick that read every changed thread,
# every queue line and every result dir one after another, under a flock the next
# tick bounced off for as long as it ran. It is now a dispatcher, and this is the
# worker it launches — once per ticket key, detached, in parallel with its
# siblings. Everything expensive about a tick lives here; everything cheap and
# deterministic stays there.
#
# THIS FILE IS NOT A SECOND SOP. The prompt was composed by the dispatcher (the
# same scope wording the single session has always carried, narrowed to one key)
# and is read from a FILE rather than argv — a prompt over MAX_ARG_STRLEN makes
# execve fail E2BIG before a line of agent-call.sh runs, which looks exactly like
# a dead runner. Model, effort and gate reason are resolved ONCE by the
# dispatcher, for the tick, and arrive in the environment: a shard that re-derived
# them could route one ticket of a tick to a different model than its siblings.
#
# GUARDS, in cost order:
#   1. locks/triage-key-<project>-<KEY>.lock, flock -n — DEDUPE, never a queue
#      (the operator, 2026-09-13). The same shape bin/run-build.sh:257 uses per ticket.
#      Held means a shard from an earlier tick still owns this key: exit, say so,
#      and let the dispatcher's re-arm put the key back in scope.
#   2. the coordination ledger's ticket-keyed claim — the flock only sees THIS
#      box, and a project can be triaged from the hub's poll-commands handler or
#      a wake-loop launch while its own cron ticks. Fail-open exactly like every
#      other claim in this repo: no worker, no JOB_ID, and the shard runs.
#
# Kill flag: none of its own — bin/lib/triage-shards-lib.sh:triage_shards_on
# (TRIAGE_SHARDS=0 / flags/triage-shards-off) stops the dispatcher ever launching
# this file, and the tick runs its single session exactly as it did before.
set -uo pipefail
# BH-2303: every model call this lane makes names the lane, so its cost rows
# carry lane_id and its LLM_* knobs (on/off, runners, daily cap) bind it alone.
export AGENT_CALL_LANE=run-triage
PROJECT="${1:?usage: triage-shard.sh <project> <key> <prompt-file>}"
KEY="${2:?key}"
PROMPT_FILE="${3:?prompt-file}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
LOG="$HARNESS/logs/$PROJECT.log"
ALERTS="$HARNESS/logs/ALERTS.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
START=$(date +%s)

mkdir -p "$HARNESS/logs" "$HARNESS/locks"
[ -s "$PROMPT_FILE" ] || { echo "$(STAMP) [$PROJECT/$KEY] triage shard: prompt file $PROMPT_FILE is missing or empty — nothing launched" >> "$ALERTS"; exit 1; }

set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a

# shellcheck source=bin/lib/triage-shards-lib.sh
[ -r "$HARNESS/bin/lib/triage-shards-lib.sh" ] && . "$HARNESS/bin/lib/triage-shards-lib.sh"
# Same lock hygiene the dispatcher uses, same fallback for a box mid-sync
# (BH-651). This shard's own fd 8 is untouched — the closing happens in the
# child's subshell.
# shellcheck source=bin/lib/lock-hygiene.sh
[ -r "$HARNESS/bin/lib/lock-hygiene.sh" ] && . "$HARNESS/bin/lib/lock-hygiene.sh"
if ! command -v lock_run_unheld >/dev/null 2>&1; then
  lock_run_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ); }
fi
# The run beat at the end goes strict through bin/lib/run-beat.sh (BH-2755), so
# a box that cannot beat says so once a day instead of looking idle.
# shellcheck source=bin/lib/run-beat.sh
[ -r "$HARNESS/bin/lib/run-beat.sh" ] && . "$HARNESS/bin/lib/run-beat.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/run-beat.sh" 2>/dev/null || true
command -v run_beat >/dev/null 2>&1 || run_beat() { "$HARNESS/bin/beat.sh" "$1" >/dev/null 2>&1 || true; }
# BH-3949: park a ticket the call-guard keeps refusing (bin/lib/triage-park.sh).
# shellcheck source=bin/lib/triage-park.sh
. "$HARNESS/bin/lib/triage-park.sh" 2>/dev/null || :
# BH-9286: drop a queue line the call-guard keeps refusing (bin/lib/queue-closed.sh).
# shellcheck source=bin/lib/queue-closed.sh
. "$HARNESS/bin/lib/queue-closed.sh" 2>/dev/null || :
TSH_GH="${TSH_GH:-0}"

# ── WHICH RUNNER, AND SAYING SO (2026-09-14, the shard storm) ─────────────────
# bin/agent-call.sh picks its runner from RUNNER_<STAGE> and the MODEL ARGUMENT
# IS ONLY READ BY THE CLAUDE LANE. So the Fable model was passed on every one
# of the 19Z storm's shards, ignored by the grok runner RUNNER_TRIAGE names, and
# then printed as `model=` on the finish line — 149 log lines claiming the most
# expensive model for calls that cost.csv records as grok. Nobody
# reading those lines could have got the bill right, and nobody did.
#
# Two fixes, both here. The runner is resolved ONCE by the dispatcher and arrives
# as TSH_RUNNER (bin/lib/triage-shards-lib.sh:triage_shard_runner — RUNNER_TRIAGE
# unless TRIAGE_SHARD_RUNNER overrides), and it is EXPORTED as RUNNER_TRIAGE
# because that is the variable agent-call actually reads. And the finish line
# below reports what ran, read back out of agent-call's own $OUT.runner, rather
# than the label this file hoped for.
#
# A shard launched by hand, with no TSH_RUNNER, resolves it itself — so this file
# is still runnable on its own, which is how an operator retries one ticket.
SHARD_RUNNER="${TSH_RUNNER:-}"
if [ -z "$SHARD_RUNNER" ]; then
  SHARD_RUNNER="${RUNNER_TRIAGE:-claude}"
  command -v triage_shard_runner >/dev/null 2>&1 && SHARD_RUNNER=$(triage_shard_runner "$HARNESS")
fi
case "$SHARD_RUNNER" in ''|*[!A-Za-z0-9._-]*) SHARD_RUNNER="${RUNNER_TRIAGE:-claude}" ;; esac
export RUNNER_TRIAGE="$SHARD_RUNNER"
# >>> model-route (BH-1510.2): the dispatcher's TSH_MODEL, else the tick's own
# selection (triage_model: env, else model_routes role triage / triage.light for
# this project), else — a box whose lib predates it — role `triage.shard`. No
# route = rc 75 before anything is claimed; bin/lib/model-route.sh alerted it.
SHARD_MODEL="${TSH_MODEL:-}"
if [ -z "$SHARD_MODEL" ]; then
  if command -v triage_model >/dev/null 2>&1; then
    SHARD_MODEL=$(triage_model "$HARNESS" "${TSH_GATE:-}" "$PROJECT")
  else
    . "$HARNESS/bin/lib/lane-model.sh" && SHARD_MODEL=$(lane_role_model triage.shard "$PROJECT")
  fi || { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT/$KEY] shard: no model route for triage — not run (rc 75)" >> "$HARNESS/logs/$PROJECT.log"; exit 75; }
fi
# <<< model-route
# REARM puts the ticket back in the board fingerprint. REARM_UNOWNED ALSO takes
# back the spend stamp (BH-1015): the dispatcher wrote
# state/triage-shards/<project>/<KEY>.fp before it launched this file, and that
# stamp says "a shard owns this world". A refused ledger claim, a missing
# contract and a nonzero exit all mean this shard does NOT own it, so the stamp
# comes off with the re-arm — otherwise a shard that died would take its ticket
# dark for the whole TTL, re-offered by the board diff and refused every tick by
# a stamp nothing ever earned.
#
# THE HELD PATH USES THE PLAIN REARM, and that distinction is load-bearing. Two
# shards meet on one key only when the dispatcher's held census races the first
# shard's flock; the loser must not delete the WINNER's stamp, which is a live
# claim on work that is running right now. Clearing it there would re-dispatch
# the key on the tick after next while the first shard was still going.
REARM() { command -v triage_shard_rearm >/dev/null 2>&1 && triage_shard_rearm "$HARNESS" "$PROJECT" "$KEY" "$TSH_GH"; }
REARM_UNOWNED() {
  command -v triage_shard_fp_clear >/dev/null 2>&1 && triage_shard_fp_clear "$HARNESS" "$PROJECT" "$KEY"
  REARM
}

# fd 8, never 9: the dispatcher holds the per-project lock on 9 and closes it
# across the setsid, and a shard that opened 9 for its own purpose would make
# that mistake survivable-looking instead of loud.
# The agent session below is spawned through lock_run_unheld, so the build IT
# detaches sees neither 8 nor 9 — a build that kept this key locked for an hour
# made every later tick say "another shard owns this ticket" (BH-651).
exec 8>"$HARNESS/locks/triage-key-$PROJECT-$KEY.lock"
flock -n 8 || {
  echo "$(STAMP) [$PROJECT/$KEY] triage shard: key lock already held — another shard owns this ticket, skipping" >> "$LOG"
  REARM || true
  exit 0
}

# BUILD_DEFER (BH-3949): a LAUNCH-ONLY shard (its prompt has a launch-queue
# section and no board or finished-build section) for a key that already has an
# open PR would pay a session to learn that. Asked of GitHub first, before the
# ledger claim, through the BH-3948 contract. rc 1 (verified none) or rc 2
# (unreadable — never "none") falls through to today's path.
#
# NOT FOR A REBUILD. A CI-parked PR stays open until its re-plan's PR replaces
# it (guardrail 1), so an open PR for the key is exactly what a re-plan or a
# rebuild line sits next to: deferring it would keep the parked PR forever and
# never run the re-plan. Any of these means the line IS the rebuild, and the
# session runs: a carried note waiting for the next build
# (state/build-notes/<p>/<KEY>.md, the ci-replan brief or an adjudication), the
# blocked-resolver's record for the ticket parked CI_PARKED, or a queue line
# that says rebuild / re-plan / blocked-resolver.
#
# A deferred line is DROPPED (bin/queue-line-drop.sh): the open PR now covers
# the work, which is the "satisfied or superseded" case the shard prompt drops
# a line for, and a line left in place would be re-read for 2 REST reads on
# every tick the PR stays open.
if grep -qxF 'In the launch queue:' "$PROMPT_FILE" 2>/dev/null \
   && ! grep -qxF 'On the board:' "$PROMPT_FILE" 2>/dev/null \
   && ! grep -q '^Finished builds awaiting' "$PROMPT_FILE" 2>/dev/null; then
  BD_REBUILD=""
  BD_NOTE="$HARNESS/state/build-notes/$PROJECT/$KEY.md"
  BD_REC="$HARNESS/state/blocked-resolver/$PROJECT/${PROJECT//[^A-Za-z0-9._-]/-}-${KEY//[^A-Za-z0-9._-]/-}.json"
  if [ -s "$BD_NOTE" ]; then
    BD_REBUILD="carried note $BD_NOTE"
  elif [ -s "$BD_REC" ] && [ "$(jq -r '.outcome // ""' "$BD_REC" 2>/dev/null)" = CI_PARKED ]; then
    BD_REBUILD="blocked-resolver record CI_PARKED"
  elif sed -n '/^In the launch queue:$/,/^$/p' "$PROMPT_FILE" 2>/dev/null | grep -qiE 'rebuild|re-?plan|blocked-resolver'; then
    BD_REBUILD="queue line names a rebuild"
  fi
  if [ -n "$BD_REBUILD" ]; then
    echo "$(STAMP) [$PROJECT/$KEY] BUILD_DEFER not checked: $BD_REBUILD — the queue line is the rebuild, session runs" >> "$LOG"
  else
    BD_SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || BD_SLUG=""
    # shellcheck source=bin/lib/open-pr-precheck.sh
    [ -n "$BD_SLUG" ] && . "$HARNESS/bin/lib/open-pr-precheck.sh" 2>/dev/null || :
    if [ -n "$BD_SLUG" ] && command -v open_pr_for_key >/dev/null 2>&1 && BD_PR=$(open_pr_for_key "$BD_SLUG" "$KEY"); then
      command -v triage_park_note >/dev/null 2>&1 && triage_park_note "$HARNESS" "$PROJECT" "$KEY" "skip build-defer open-pr $BD_PR"
      BD_DROP=$(HARNESS="$HARNESS" "$HARNESS/bin/queue-line-drop.sh" "$KEY" 2>&1) || BD_DROP="queue line NOT dropped: $BD_DROP"
      echo "$(STAMP) [$PROJECT/$KEY] BUILD_DEFER $KEY open-pr $BD_PR - paid_avoided; $BD_DROP" >> "$LOG"
      exit 0
    fi
  fi
fi

# --- Coordination DB claim (docs/DB-COORDINATION-SPEC.md) ----------------------
# Ticket-KEYED, unlike the dispatcher's own ticketless tick row: the flock above
# is box-local and this is what stops a second box (or the hub's poll-commands
# handler) triaging the same client ticket at the same moment. kind=triage, so it
# shares nothing with the build claim on the same key — closing out a finished
# build is exactly the work that must be able to run while that key has a build
# row open. Fail-open: no worker, no JOB_ID, and everything below is unchanged.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
JOB_ID=""; JOB_BEAT=""
if command -v job_open >/dev/null 2>&1; then
  JOB_CLAIM=$(job_open "$PROJECT" "$KEY" triage triage "triage/$PROJECT/$SHARD_RUNNER" \
    "$(jq -nc --arg k "$KEY" --arg g "${TSH_GATE:-}" '{key:$k,gate:$g,shard:true}' 2>/dev/null)"); JOB_RC=$?
  if [ "$JOB_RC" -eq 9 ]; then
    # A refusal is a CLEAN SKIP, never an error (the rule bin/run-triage.sh's own
    # claim follows): the DB has said this ticket may not be triaged here right
    # now. Put the key back in scope so the next tick offers it again — dropping
    # it here is the silent loss the whole re-arm exists to prevent.
    echo "$(STAMP) [$PROJECT/$KEY] triage shard: claim refused: ${JOB_CLAIM#REFUSED } — left in scope for the next tick" >> "$LOG"
    REARM_UNOWNED || true
    exit 0
  fi
  [ "$JOB_RC" -eq 0 ] && JOB_ID="$JOB_CLAIM" || JOB_ID=""
  if [ -n "$JOB_ID" ]; then
    export JOB_ID
    job_heartbeat "$JOB_ID" start >/dev/null 2>&1 || true
    JOB_BEAT=$(job_beat_start "$JOB_ID") || JOB_BEAT=""
  fi
fi

# The contract, resolved here for the same reason bin/run-triage.sh resolves it:
# an EMPTY append drops the BUILD DEDUPE and DECISION LOG rules and the session
# stops emitting DECISION lines, which looks exactly like a calm day. Refuse the
# shard rather than degrade it — and re-arm, so the ticket is not lost with it.
TRIAGE_APPEND="$("$HARNESS/bin/triage-contract.sh" 2>>"$ALERTS")"
if [ -z "$TRIAGE_APPEND" ]; then
  echo "$(STAMP) [$PROJECT/$KEY] TRIAGE CONTRACT MISSING: bin/triage-contract.sh returned nothing, so this shard would run without its BUILD DEDUPE and DECISION LOG rules — refusing. Fix: bin/harness-sync.sh." >> "$ALERTS"
  REARM_UNOWNED || true
  exit 1
fi

OUT="$HARNESS/logs/$PROJECT.triage-$KEY.out"
TO=10800
command -v triage_shard_timeout >/dev/null 2>&1 && TO=$(triage_shard_timeout "$HARNESS")
# Where the cost rows for THIS call will land. cost.csv has no key column and is
# not getting one — bin/cost-rollup.sh groups on (runner, stage, project) and a
# new column would have to be added to every reader at once. So a shard's row is
# an ordinary stage=triage row, and the line number taken here is how this log
# line attributes it without inventing a schema.
COST="$HARNESS/logs/cost.csv"
CLINES=$(wc -l < "$COST" 2>/dev/null | tr -d ' '); case "$CLINES" in ''|*[!0-9]*) CLINES=0 ;; esac

# THE PRE-CALL GUARD'S KEY (K3, bin/lib/call-guard.sh). `triage` is shared by
# alert-triage, the medic and the responder, so this family names itself:
# AGENT_CALL_GUARD_STAGE=triage-shard. The fingerprint is the ticket plus the
# board-state digest the dispatcher stamped for it before launching this file
# (BH-1015, state/triage-shards/<p>/<KEY>.fp): the same ticket in the same
# world is the same work, however the prompt's prose drifted between ticks. A
# shard launched by hand has no stamp, and agent-call.sh then keys on the
# ticket and the exact prompt.
CG_FP=""
if command -v triage_shard_fp_file >/dev/null 2>&1; then
  CG_FP=$(head -1 "$(triage_shard_fp_file "$HARNESS" "$PROJECT" "$KEY")" 2>/dev/null | tr -dc '0-9a-f')
fi
# THE UNTRUSTED-INPUT RULE (BH-4491) leads the prompt: the shard fetches its
# ticket's thread itself. It goes into a sibling file, so the dispatcher's file
# is left exactly as it wrote it; a box without the lib sends that file as is.
# shellcheck source=bin/lib/untrusted-input.sh
[ -r "$HARNESS/bin/lib/untrusted-input.sh" ] && . "$HARNESS/bin/lib/untrusted-input.sh"
TSH_PF="$PROMPT_FILE"
if command -v ui_notice >/dev/null 2>&1 \
   && { ui_notice; printf '\n\n'; cat "$PROMPT_FILE"; } > "$PROMPT_FILE.ui" 2>/dev/null; then
  TSH_PF="$PROMPT_FILE.ui"
fi
# THE COST-ROW NOTE (BH-3926): `ts=<class>` for this key, read from the
# snapshot the dispatcher took for it (TSH_TS_HASH, bin/lib/triage-state.sh:
# ts_shard_hash), so a later tick's pre-check cannot change the class. Computed
# here rather than in bin/lib/rt/shards.sh, which the BH-3418 contract keeps
# untouched. A TSH_TS_NOTE handed in wins; no lib or no snapshot is no note.
if [ -z "${TSH_TS_NOTE:-}" ] && [ -n "${TSH_TS_HASH:-}" ] && [ -r "$HARNESS/bin/lib/triage-state.sh" ]; then
  TSH_TS_NOTE=$( . "$HARNESS/bin/lib/triage-state.sh" 2>/dev/null
    command -v ts_row_note_of >/dev/null 2>&1 || exit 0
    TSH_SNAP="$(_ts_dir)/snap/$KEY.$TSH_TS_HASH"
    [ -d "$TSH_SNAP" ] && ts_row_note_of "$KEY" "$TSH_SNAP" )
fi
GROK_EFFORT="${TSH_EFFORT:-${GROK_EFFORT:-}}" \
AGENT_SYSTEM_APPEND="$TRIAGE_APPEND" \
AGENT_CALL_GUARD_STAGE=triage-shard AGENT_CALL_TICKET="$KEY" \
AGENT_CALL_FP="${CG_FP:+$KEY:$CG_FP}" \
AGENT_CALL_ROW_NOTE="${TSH_TS_NOTE:-}" \
  lock_run_unheld "$HARNESS/bin/agent-call.sh" triage "$PROJECT" "$SHARD_MODEL" "$TO" "$OUT" "@$TSH_PF"
RC=$?
[ "$TSH_PF" = "$PROMPT_FILE" ] || rm -f "$TSH_PF"
# A CALL-GUARD REFUSAL IS "NOTHING WAS CALLED", not a dead shard, so there is
# no ALERTS line per shard per tick (agent-call.sh writes ONE warn line a day).
#   repeat              this ticket's unchanged world already had its ceiling
#                       of paid shards today. The stamp STAYS (it is true: the
#                       world was handled) with a plain re-arm, so the ticket is
#                       not re-offered every tick for 24h; a real change moves
#                       the fingerprint and still reaches it.
#   counter-unreadable  a metered lane, the counter did not answer: nobody owns
#                       the world, so the stamp comes off with the re-arm.
CG_REFUSED=""; CG_PARK=""
CG_MARK=$(head -1 "$OUT" 2>/dev/null)
if [ "$RC" -eq 74 ]; then
  case "$CG_MARK" in
    "AGENT_CALL_REFUSED call-guard repeat "*)
      CG_REFUSED=1; REARM || true
      # BH-3949: N of these on one fingerprint parks the ticket, below.
      CG_PARK=1
      echo "$(STAMP) [$PROJECT/$KEY] triage shard: call-guard refused before the call (${CG_MARK:0:160}) — nothing called; stamp kept, ticket left in scope" >> "$LOG" ;;
    "AGENT_CALL_REFUSED call-guard "*)
      CG_REFUSED=1; REARM_UNOWNED || true
      echo "$(STAMP) [$PROJECT/$KEY] triage shard: call-guard refused before the call (${CG_MARK:0:160}) — nothing called; stamp cleared, ticket left in scope" >> "$LOG" ;;
    # BH-2538: this ticket was context-killed its limit of times and a person
    # has the alert. Same handling as a guard repeat — stamp kept, no per-tick
    # ALERTS line — so the shard is not re-bought every tick while they decide.
    "AGENT_CALL_REFUSED context-kill repeat "*)
      CG_REFUSED=1; REARM || true
      echo "$(STAMP) [$PROJECT/$KEY] triage shard: context-kill repeat refused before the call (${CG_MARK:0:160}) — nothing called; escalated to a person, stamp kept" >> "$LOG" ;;
  esac
fi

if [ -n "${JOB_ID:-}" ] && command -v job_update >/dev/null 2>&1; then
  [ -n "${JOB_BEAT:-}" ] && job_beat_stop "$JOB_BEAT"
  job_update "$JOB_ID" stage=done "status=$([ "$RC" -eq 0 ] && echo "done" || echo failed)"
fi

"$HARNESS/bin/decision-log.sh" "$PROJECT" "${TSH_GATE:-shard}" "${TSH_SCOPE:-shard}" "$OUT" 2>>"$ALERTS" || true
# >>> needs-human escalate
# BH-3433 (BH-3444): an escalate whose reason names a step only a person can
# take asks for the needs-human hold (source triage). Fail-open; issues boards
# only; bounded exactly like decision-log.sh (first 40 DECISION lines, 330 chars).
# shellcheck source=bin/lib/needs-human.sh
[ -r "$HARNESS/bin/lib/needs-human.sh" ] && . "$HARNESS/bin/lib/needs-human.sh" 2>/dev/null || true
if command -v nh_classify >/dev/null 2>&1 && [ -f "$OUT" ] && [ -x "$HARNESS/bin/needs-human-hold.sh" ] \
   && [ "$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null)" = "-" ]; then
  grep -a '^DECISION:' "$OUT" 2>/dev/null | sed -n '1,40p' | cut -c1-330 | while IFS= read -r L; do
    L=${L#DECISION: }; K=${L%% :: *}; R=${L#* :: }; A=${R%% :: *}; R=${R#* :: }
    [ "$(tr -d ' ' <<<"$A")" = escalate ] || continue
    N=$(sed -nE 's/^[A-Za-z]+-([0-9]+)$/\1/p' <<<"$(tr -d ' ' <<<"$K")"); [ -n "$N" ] || continue
    V=$(nh_classify --text "$R" 2>/dev/null) || continue
    NA=${V#*$'\t'}; FP=$(nh_fingerprint "$NA" 2>/dev/null) || continue
    "$HARNESS/bin/needs-human-hold.sh" "$PROJECT" "$N" "$FP" "$NA" triage >/dev/null 2>&1; PRC=$?
    echo "$(STAMP) [$PROJECT/$K] needs-human: escalate reads as human-only ($FP) — hold asked, placer rc=$PRC" >> "$LOG"
  done
fi
# <<< needs-human escalate
# TRIAGE-STATE: this key's verdict onto its triage_state row, stamped with the
# hash the dispatcher handed this shard (TSH_TS_HASH, empty = record nothing).
[ -n "${TSH_TS_HASH:-}" ] && [ -r "$HARNESS/bin/lib/triage-state.sh" ] && . "$HARNESS/bin/lib/triage-state.sh" \
  && ts_after_session "$HARNESS" "$PROJECT" "$RC" "$OUT" "$KEY" "$TSH_TS_HASH"
# BH-3949: after the stamp above, so the park is the last write to the row.
[ -n "${CG_PARK:-}" ] && command -v triage_park_on_refusal >/dev/null 2>&1 \
  && triage_park_on_refusal "$HARNESS" "$PROJECT" "$KEY" "$CG_FP" "$CG_MARK"
# BH-9286: N `call-guard repeat` refusals IN A ROW on unchanged queue text
# (TSH_QUEUE, this shard's queue lines from the dispatcher) drop the line and
# write one alert; any other outcome resets the count. No TSH_QUEUE = no-op.
command -v qc_refusal_note >/dev/null 2>&1 \
  && qc_refusal_note "$HARNESS" "$PROJECT" "$KEY" "$([ -n "${CG_PARK:-}" ] && echo repeat || echo other)" "${TSH_QUEUE:-}"

# A FAILED SHARD PUTS ITS TICKET BACK. The dispatcher consumed the board
# fingerprint when it handed this key out, which is only honest while somebody is
# actually working it. Deleting this key's entry from the consumed copy makes the
# next tick's diff report it again — one ticket re-offered, not the whole board
# re-read. Said out loud too: a shard that died is the one thing about this split
# that nothing else in the fleet would notice.
if [ "$RC" -ne 0 ] && [ -z "$CG_REFUSED" ]; then
  if REARM_UNOWNED; then
    echo "$(STAMP) [$PROJECT/$KEY] triage shard exited rc=$RC (see $OUT) — ticket put back in scope for the next tick" >> "$ALERTS"
  else
    echo "$(STAMP) [$PROJECT/$KEY] triage shard exited rc=$RC (see $OUT) and the board fingerprint could NOT be re-armed — this ticket will not be re-offered until the daily full sweep; check state/$PROJECT.gate.json" >> "$ALERTS"
  fi
fi

# cost + seconds, from the rows this call appended (there may be two: a failover
# attempt writes its own).
#
# HONEST ONLY WHEN IT IS ALONE. `tail -n +<lines-before-my-call>` selects every
# stage=triage row of this project written since this shard started — INCLUDING
# every sibling's. With a dozen shards in flight each of them sums most of the
# others, which is how the 19Z hour read as ~$713 off these lines while the rows
# themselves add to $54.99. So the figure is printed only when no sibling shard
# of this project held a key lock at the end of the call; otherwise `cost=$?`,
# and `spend1h` — the window sum, read once, from the rows — is the number.
CSIB=0
if command -v triage_shard_held >/dev/null 2>&1; then
  for L in "$HARNESS"/locks/triage-key-"$PROJECT"-*.lock; do
    case "$L" in "$HARNESS/locks/triage-key-$PROJECT-$KEY.lock") continue ;; esac
    triage_shard_held "$L" && CSIB=$((CSIB+1))
  done
fi
CUSD=""
[ "$CSIB" = 0 ] && CUSD=$(tail -n +$((CLINES + 1)) "$COST" 2>/dev/null \
  | awk -F, -v p="$PROJECT" '$3==p && $4=="triage" && $13 ~ /^[0-9.]+$/ {s+=$13} END{if (s>0) printf "%.4f", s}')
# The rolling-hour spend the dispatcher's cap reads, on every shard line, so the
# lane's real rate is visible without joining anything.
CHOUR="?"
command -v triage_hour_usd >/dev/null 2>&1 && CHOUR=$(triage_hour_usd "$HARNESS" "$PROJECT")
# What bin/agent-call.sh actually ran. $OUT.runner is ITS record of the attempt
# that served this call (last attempt wins, so a failover is reported as the
# failover), and the model comes off this call's own cost rows rather than the
# argv the runner may have ignored.
RUNNER_REAL=$(head -1 "$OUT.runner" 2>/dev/null | tr -dc 'A-Za-z0-9._-')
[ -n "$RUNNER_REAL" ] || RUNNER_REAL="$SHARD_RUNNER"
MODEL_REAL=$(tail -n +$((CLINES + 1)) "$COST" 2>/dev/null \
  | awk -F, -v p="$PROJECT" -v r="$RUNNER_REAL" '$3==p && $4=="triage" && $5==r {m=$6} END{print m}')
[ -n "$MODEL_REAL" ] || MODEL_REAL="$SHARD_MODEL"
SUMMARY="$(grep -oE 'tickets=[^"]*' "$OUT" 2>/dev/null | tail -1 | cut -c1-160)"
[ -n "$SUMMARY" ] || SUMMARY="$(tail -3 "$OUT" 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
SECS=$(( $(date +%s) - START ))
# `rc=<n> :: <summary>` deliberately, in that order: bin/pipeline-health.sh's
# no-op-streak detector (check "a lane buying ticks that conclude nothing") reads
# `rc=(0|skip) ::` out of this file, and a shard line that put cost between the
# two would have made every sharded lane invisible to it — a detector that goes
# quiet looks exactly like a lane with nothing wrong.
echo "$(STAMP) [$PROJECT] shard $KEY rc=$RC :: $SUMMARY [gate=${TSH_GATE:-?} scope=${TSH_SCOPE:-?} runner=$RUNNER_REAL model=$MODEL_REAL cost=\$${CUSD:-?} spend1h=\$$CHOUR ${SECS}s]" >> "$LOG"

# Console beat, one per shard — the tick itself no longer buys a session, so
# without this a sharded lane would go dark on the Jobs screen.
run_beat "$(jq -nc --arg rkey "run:$PROJECT:$KEY:$START" --arg p "$PROJECT" \
  --argjson rc "$RC" --arg s "shard $KEY: $SUMMARY" --arg st "$(date -u -d @$START '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg fin "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg detail "$(tail -c 7000 "$OUT" 2>/dev/null)" \
  '{kind:"run",rkey:$rkey,project:$p,run_kind:"triage",rc:$rc,summary:$s,started_at:$st,finished_at:$fin,detail:$detail}')"
exit 0
