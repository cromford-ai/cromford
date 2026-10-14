#!/bin/bash
# box triage runner. Cron entry point: run-triage.sh <project>
export AGENT_CALL_LANE=run-triage  # BH-2303: cost rows carry lane_id; this lane's LLM_* knobs bind it alone
set -uo pipefail
PROJECT="${1:?usage: run-triage.sh <project>}"
HARNESS="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")
REPO="/root/repos/$PROJECT"
LOG="$HARNESS/logs/$PROJECT.log"
ALERTS="$HARNESS/logs/ALERTS.log"
PROMPT_FILE="$HARNESS/prompts/$PROJECT.md"
STAMP="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

mkdir -p "$HARNESS/logs" "$HARNESS/locks"

# Load auth + per-project env
set -a
[ -f "$HENV/global.env" ] && . "$HENV/global.env"
[ -f "$HENV/$PROJECT.env" ] && . "$HENV/$PROJECT.env"
set +a
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true; command -v lane_gate_or_exit >/dev/null 2>&1 && { lane_gate_or_exit run-triage "$PROJECT"; lane_env_apply run-triage "$PROJECT"; }  # BH-1165 lane gate + knobs, ONE line: tests/rt-split-layout-test.sh caps this driver at 380

# >>> triage github auth
# --- GitHub auth for this tick (2026-09-16, the 17:20Z halt) --------------------
# bin/run-build.sh has billed its `gh` calls to a repo-scoped GitHub App
# installation token since 09-14; this lane never did. Its shards — the
# codex/grok sessions that read ticket threads and post close-outs — inherited
# the box's `gh auth login`, the operator account, 5,000/h shared by every box AND
# the operator's Mac. That bucket emptied in twenty minutes on 2026-09-16 and
# seven project-5 shards logged `GitHub API rate limit exhausted` and skipped
# their close-outs while the project's App token sat at 6,569/6,600.
# Same helper, same kill switches, same fallback as the build lane: gh_auth_for
# exports GH_TOKEN (gh prefers it over hosts.yml, git through `gh auth
# setup-git`) or leaves the env exactly as it was — env/github-app.env absent,
# GH_APP_TOKENS=0, flags/gh-app-tokens-off, or a project fleet.conf cannot name.
# The token lives an hour and every dispatch below inherits it (a tick's life: bin/lib/triage-gh-token.sh).
#
# BELOW THE ENV LOAD, NOT ABOVE IT (BH-470). This block used to sit at line 9,
# above `set -a; . global.env`. Two things were wrong with that. global.env
# carries a GH_TOKEN= line, so the env load could overwrite the App token this
# block had just exported; and gh-app-auth.sh snapshots "the token this shell
# started with" AT SOURCE TIME, so on an unarmed box the snapshot was an unset
# GH_TOKEN and a later gh_default_auth_reset would have thrown the PAT away.
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# The rate-limit logger (#469): a `gh` wrapper that writes one identity= line
# when GitHub refuses a call for budget. Fail-open — a box that has not synced
# the file yet defines nothing and behaves exactly as it does today.
# shellcheck source=bin/lib/gh-limit-logger.sh
[ -r "$HARNESS/bin/lib/gh-limit-logger.sh" ] && . "$HARNESS/bin/lib/gh-limit-logger.sh"
TRIAGE_GH_SLUG=$(git -C "$REPO" remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')
[ -n "$TRIAGE_GH_SLUG" ] || TRIAGE_GH_SLUG=$("$HARNESS/bin/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)
[ -r "$HARNESS/bin/lib/triage-gh-token.sh" ] && . "$HARNESS/bin/lib/triage-gh-token.sh" && { triage_gh_premint "$TRIAGE_GH_SLUG" || true; }  # a tick outlives a nearly-spent token (project-4 2026-09-24)
# The `command -v` guard is the whole compatibility story: gh_default_auth_for_project
# is #469's and lands separately, so until it does the elif below is what runs
# and this lane behaves byte for byte as it did.
if command -v gh_default_auth_for_project >/dev/null 2>&1; then
  gh_default_auth_for_project "$PROJECT" || true
  case "${GH_TOKEN:-}" in ghs_*) echo "$(date -u +%Y-%m-%d\ %H:%M:%SZ) [$PROJECT] triage github auth: App installation token for $TRIAGE_GH_SLUG (this tick's shards bill the installation, not the box login)" >> "$LOG" ;; esac
elif [ -n "$TRIAGE_GH_SLUG" ] && command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$TRIAGE_GH_SLUG"; then
  echo "$(date -u +%Y-%m-%d\ %H:%M:%SZ) [$PROJECT] triage github auth: App installation token for $TRIAGE_GH_SLUG (this tick's shards bill the installation, not the box login)" >> "$LOG"
fi
# <<< triage github auth

# The shard vocabulary, sourced HERE rather than beside the dispatcher at the
# bottom of this file (where it used to live). Three decisions above the
# dispatcher now read it — the ledger claim's runner label, the model tiering and
# the event-wake scope's key filter — and a file sourced after its first caller
# is a set of functions that silently are not there. Nothing in it runs on
# sourcing and every function answers a question; a box missing the file behaves
# exactly as it did before shards existed (every call site tests command -v).
# shellcheck source=bin/lib/triage-shards-lib.sh
[ -r "$HARNESS/bin/lib/triage-shards-lib.sh" ] && . "$HARNESS/bin/lib/triage-shards-lib.sh"; [ -r "$HARNESS/bin/lib/triage-hotfix-lib.sh" ] && . "$HARNESS/bin/lib/triage-hotfix-lib.sh"  # BH-645

# Lock hygiene (BH-651): every child this tick spawns after it takes the lock
# runs through lock_run_unheld (foreground) or lock_spawn_unheld (detached), so
# none of them inherits the fd the per-project flock lives on. There are exactly
# two such spawn sites in this file — the shard fork and the single-session agent
# call — and both are below.
# The fallbacks are not decoration — a box mid-sync that has not
# received bin/lib/lock-hygiene.sh yet must still close the fds, because a
# leaked descriptor is a lane that stops triaging for the life of a build.
# Holder naming is the part that degrades there: no lib, no scan, and the skip
# line says "(holder unknown)" rather than inventing a pid.
# shellcheck source=bin/lib/lock-hygiene.sh
[ -r "$HARNESS/bin/lib/lock-hygiene.sh" ] && . "$HARNESS/bin/lib/lock-hygiene.sh"
if ! command -v lock_run_unheld >/dev/null 2>&1; then
  lock_run_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ); }
fi
if ! command -v lock_spawn_unheld >/dev/null 2>&1; then
  lock_spawn_unheld() { [ $# -gt 0 ] || return 0; ( exec 8>&- 9>&-; exec "$@" ) & }
fi
if ! command -v lock_holders >/dev/null 2>&1; then
  lock_holders() { return 0; }
fi

# --- Lane liveness (2026-08-30) -----------------------------------------------
# THE FIRST THING THIS SCRIPT DOES, and deliberately before every early exit
# below it. On 2026-08-30 project-7's crons vanished from box-project-6-1
# at 05:17 and the lane sat silent for TEN HOURS with nothing alerting: the box
# was pinging, the hub was pushing status, and no ledger anywhere held the fact
# that this lane was supposed to tick six times an hour. What is recorded here
# is exactly "the cron fired", which is the one signal a lost crontab removes.
#
# Every path out of this script is a live lane: a missing prompt file, a console
# pause, a lock held by the previous run, a gate SKIP on an unchanged board —
# on a quiet board the SKIP is the normal shape, and it claims no job and spends
# nothing, which is why the jobs ledger cannot answer this question and this
# call exists. Only the crontab itself disappearing stops the tick, and that is
# the failure being watched for.
#
# Fail-open: no client, no worker, no secret -> no row, no noise, and everything
# below behaves byte-for-byte as it did before this block existed.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
command -v lane_tick >/dev/null 2>&1 && lane_tick "$PROJECT" start >/dev/null 2>&1
LANE_TICK() { command -v lane_tick >/dev/null 2>&1 && lane_tick "$PROJECT" "${1:-tick}" >/dev/null 2>&1; return 0; }

# The tick's stages (BH-479), sourced after the lane tick; each file defines
# functions only, and everything below this line is a call into one of them.
# MANDATORY (BH-479.4): a tick that ran without its staging or its scope would be
# a different tick, silently — a quiet-looking log line for a run that never
# staged a finished build or never read the queue. So a stage file this tick
# cannot USE refuses here: unreadable, or — the likelier half, since rsync is
# per-file — TRUNCATED mid-sync, which `[ -r ]` accepts. Hence `&& . && continue`
# rather than a brace group, which would swallow the source's own exit status and
# fail open. It sits after the lane tick (a broken sync still records that the
# cron fired) and before the prompt-file check and the lock, so nothing is
# half-done when it refuses: no lock taken, no job claimed, no prompt written,
# no session bought.
RT_CG_SKIP=""; BEAT_RC=""; for RT_STAGE in staging gate scope shards launch; do  # BH-4120: those two are rt_launch outputs, not knobs
  # shellcheck source=/dev/null
  [ -r "$HARNESS/bin/lib/rt/$RT_STAGE.sh" ] && . "$HARNESS/bin/lib/rt/$RT_STAGE.sh" && continue
  echo "$STAMP [$PROJECT] TRIAGE STAGE MISSING: bin/lib/rt/$RT_STAGE.sh is not on this box, so the tick would run without its $RT_STAGE stage — refusing the tick rather than running part of it. Fix: bin/harness-sync.sh (the checkout's bin/ did not fully rsync)." >> "$ALERTS"
  exit 1
done
if [ ! -f "$PROMPT_FILE" ]; then echo "$STAMP [$PROJECT] prompt file missing" >> "$ALERTS"; exit 1; fi
# Console pause flag (BH-4153): paused-<project> is a harness_flags ROW read
# DB-first by flag_active, the cache on an outage, ON when nothing can be read
# (a stop switch fails closed). No worker or no client: flags/paused-<project>.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
if { command -v flag_active >/dev/null 2>&1 && flag_active "paused-$PROJECT" >/dev/null 2>&1; } \
   || { ! command -v flag_active >/dev/null 2>&1 && [ -f "$HARNESS/flags/paused-$PROJECT" ]; }; then
  # A PAUSE IS A HUMAN DECISION AND IS NOT OVERRIDDEN (#368). The hotfix lane
  # jumps caps, not pauses — so the only thing that happens here is that the
  # wait becomes visible: one line per tick naming the hotfix that is held.
  # Fail-open and silent on every project that has no hotfix.
  "$HARNESS/bin/hotfix-seen.sh" "$PROJECT" --paused >/dev/null 2>&1 || true
  LANE_TICK paused; echo "$STAMP [$PROJECT] paused via console, skipping" >> "$LOG"; exit 0
fi
rt_pause_triage  # BH-1672: a live triage pause row exits 0 here, like the flag above (bin/lib/rt/gate.sh)
RUN_START_EPOCH=$(date +%s)
# Repo is only needed for build waves; triage runs fine without it.
WORKDIR="$REPO"; [ -d "$REPO" ] || WORKDIR="$HARNESS"

# Per-project overlap guard (triage runs are fine in parallel across projects,
# but never two runs of the same project at once)
PLOCK="$HARNESS/locks/$PROJECT.lock"
exec 9>"$PLOCK"
# >>> tick lock holder
# A SKIP THAT NAMES ITS HOLDER (BH-651). "previous run still active, skipping"
# was true for 35 minutes while no run was active: a build detached by a finished
# tick held the descriptor. The line now says WHO, and a holder that is not a
# run-triage.sh process is a leaked fd rather than a routine overlap, so it rings
# once instead of reading like a quiet day. The scan runs ONLY here, never on a
# tick that takes the lock. The prefix is unchanged, so anything grepping the old
# wording still matches.
if ! flock -n 9; then
  LANE_TICK locked
  # We lost the race, so fd 9 is dead weight — and worse than dead weight: every
  # subshell of the scan below would inherit it and report ITSELF as a holder of
  # the very file it is scanning. Drop it before asking who has the lock.
  exec 9>&-
  HOLDER=$(lock_holders "$PLOCK" | head -1)
  echo "$STAMP [$PROJECT] previous run still active (holder ${HOLDER:-unknown}), skipping" >> "$LOG"
  case "$HOLDER" in
    ''|*run-triage.sh*) ;;
    *)
      "$HARNESS/bin/lane-alert.sh" --id "triage-lock-leak-$PROJECT" --severity warn triage \
        "[$PROJECT] locks/$PROJECT.lock is held by a process that is not run-triage.sh — $HOLDER. A child inherited the tick's fd 9; every triage tick skips until it exits (BH-651). Kill that pid, or close the fd at its spawn site." \
        >/dev/null 2>&1 \
        || echo "$STAMP [$PROJECT] tick lock held by a foreign process ($HOLDER) and bin/lane-alert.sh did not run" >> "$ALERTS"
      # The marker exists so the resolve below costs nothing on a normal tick:
      # without it every acquire would spawn lane-alert.sh to close a condition
      # that was never open. Written after the send, so the worst case is one
      # silent resolve rather than a condition nobody ever closes.
      : > "$HARNESS/state/triage-lock-leak-$PROJECT" 2>/dev/null || true
      ;;
  esac
  exit 0
fi
if [ -e "$HARNESS/state/triage-lock-leak-$PROJECT" ]; then
  "$HARNESS/bin/lane-alert.sh" --resolve --id "triage-lock-leak-$PROJECT" triage \
    "[$PROJECT] tick lock free again" >/dev/null 2>&1
  rm -f "$HARNESS/state/triage-lock-leak-$PROJECT"
fi
# <<< tick lock holder

# Stage: bin/lib/rt/staging.sh — bring finished builds onto this box before the gate.
rt_stage

# Stage: bin/lib/rt/gate.sh — reconcile, announce hotfixes, then the cost gate.
rt_gate
# >>> model-route (BH-1510.2): triage_model — env, else model_routes role triage /
# triage.light for this project. No route = rc 75 BEFORE the job claim below, so
# no row is opened and nothing is bought; bin/lib/model-route.sh alerted it.
# A $HARNESS without the lib (mid-sync) reads the copy beside this script, in the
# subshell only — its other functions must not change this tick's shape.
TRIAGE_MODEL=$(command -v triage_model >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/lib/triage-shards-lib.sh" 2>/dev/null
  triage_model "$HARNESS" "${GATE_DECISION#RUN }" "$PROJECT") \
  || { echo "$STAMP [$PROJECT] no model route for triage — tick skipped (rc 75)" >> "$LOG"; exit 75; }
# <<< model-route

# --- Coordination DB claim (phase 1, docs/DB-COORDINATION-SPEC.md) -------------
# A triage tick is a job like any other: it spends money and it is the thing
# that launches builds, so the fleet-wide in-flight view is wrong without it.
# Ticketless by nature, so it never trips the double-build guard (the
# per-project flock above already serializes ticks) — this is registration and
# spend, not mutual exclusion. Fail-open: no worker, no JOB_ID, no change.
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh"
JOB_ID=""; JOB_BEAT=""
if command -v job_open >/dev/null 2>&1; then
  # The lane label is the SHARED selection (bin/lib/triage-shards-lib.sh:
  # triage_runner), so the tick's row and its shards' rows name the same runner —
  # and the same one bin/agent-call.sh will actually pick from RUNNER_TRIAGE.
  TICK_RUNNER="${RUNNER_TRIAGE:-claude}"
  command -v triage_runner >/dev/null 2>&1 && TICK_RUNNER=$(triage_runner "$HARNESS")
  JOB_CLAIM=$(job_open "$PROJECT" "" triage triage "triage/$PROJECT/$TICK_RUNNER"); JOB_RC=$?
  # Phase 6: a refusal is a CLEAN SKIP, not an error. The DB has said this tick
  # may not start — a concurrency rule is at its limit, or a retry of this same
  # work is scheduled behind a backoff — so the tick logs why and exits 0. A
  # nonzero exit here would put a cron failure in front of a human for a
  # decision the system made on purpose. Only a REFUSAL does this: an
  # unreachable worker still returns rc 1 and the tick runs exactly as today.
  if [ "$JOB_RC" -eq 9 ]; then
    LANE_TICK refused
    echo "$STAMP [$PROJECT] claim refused: ${JOB_CLAIM#REFUSED }" >> "$LOG"
    exit 0
  fi
  [ "$JOB_RC" -eq 0 ] && JOB_ID="$JOB_CLAIM" || JOB_ID=""
  if [ -n "$JOB_ID" ]; then
    export JOB_ID
    # Heartbeat for as long as the tick runs (phase 3). A triage tick can sit in
    # one agent call for hours; without a beat, a killed tick is indistinguish-
    # able from a slow one. One call every ~150s of WALL CLOCK, never per token.
    job_heartbeat "$JOB_ID" start >/dev/null 2>&1 || true
    JOB_BEAT=$(job_beat_start "$JOB_ID") || JOB_BEAT=""
  fi
fi

cd "$WORKDIR" || exit 1
# Keep main (and its CLAUDE.md) fresh: fast-forward when clean and on the default branch.
if [ -d "$REPO" ]; then
  BR=$(git -C "$REPO" branch --show-current 2>/dev/null)
  if [ "$BR" = "main" ] && [ -z "$(git -C "$REPO" status --porcelain)" ]; then
    git -C "$REPO" pull --ff-only --quiet origin main 2>>"$ALERTS" || true
  else
    git -C "$REPO" fetch origin --quiet 2>>"$ALERTS"
  fi
  # Staleness alert: if the checkout still lags origin/main after the sync attempt
  # (dirty tree, wrong branch, diverged, failed pull), the session is running on a
  # stale CLAUDE.md/codebase. Alert once per new origin/main head, not every tick.
  ORIGIN_HEAD=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null)
  BEHIND=$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  STALE_FLAG="$HARNESS/flags/stale-alerted-$PROJECT"
  if [ "${BEHIND:-0}" -gt 0 ]; then
    if [ "$(cat "$STALE_FLAG" 2>/dev/null)" != "$ORIGIN_HEAD" ]; then
      DIRTY_N=$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')
      echo "$STAMP [$PROJECT] STALE CHECKOUT: $BEHIND commits behind origin/main (branch=$BR, dirty=$DIRTY_N) — triage is running on an outdated CLAUDE.md/codebase; fix the checkout" >> "$ALERTS"
      echo "$ORIGIN_HEAD" > "$STALE_FLAG"
    fi
  else
    rm -f "$STALE_FLAG"
  fi
fi

OUT="$HARNESS/logs/$PROJECT.last-run.txt"
# The model was resolved above, right after the gate, through the shared
# selection (triage_model), so a shard and its tick can never route differently.
# Cost lever 3 (the operator 2026-08-07, "not $200/day on triage") — retiered 2026-08-14
# on the operator's routing principle: JUDGMENT runs on the strong model, COORDINATION
# runs light.
#
# board-changed is judgment, not routine: it is the tick where a client's answer
# lands and someone decides ready-to-build vs waiting-on-client. That call is the
# expensive one to get wrong (the early-engagement incident was built off a thread nobody had
# read to the end), and it was running on the light model while the queue-pending
# tick that merely LAUNCHES what it decided ran strong. Backwards, so it moved.
#
# Left light: results-sweep and remote-results-pending — read RESULT, post the
# close-out comment, set status. Mechanical, high-volume (128 of today's 131
# project-1 ticks), no build/no-build decision in them.

# Context diet (cost levers 4+5, the operator 2026-08-20/21): the volume is the bill —
# full-context ticks re-read every board ticket (~1.2M input tokens/tick on
# the grok lane) to conclude work the gate already identified precisely.
# Lever 4: board-changed ticks get the fingerprint diff as their reading list.
# Lever 5: queue-pending and results-sweep ticks — the dominant tick types on
# a quiet board (~80% of triage spend, 2026-08-20 audit) — get the queue lines
# / un-commented RESULT dirs the gate fired on, plus a fresh board diff so any
# board movement that rode along is still worked and consumed (the gate checks
# queue/sweep BEFORE the board diff, so without this a busy queue could starve
# a client's answer). All scopes are advisory, deterministic, capped, and
# fail-open: any doubt anywhere collapses to the plain full-context prompt.
# daily-sweep and forced ticks always keep full context.
PROMPT_TEXT="$(cat "$PROMPT_FILE")"
# >>> overlap guard (docs/SCHEDULER.md, 2026-09-15)
# The launch decision on THIS path belongs to the triage agent, so the guard
# reaches it as one instruction rather than a branch — appended once, here,
# BEFORE SHARD_SOP is taken and before the scope arms wrap it, so every tick
# type and every shard carries it. No script on the box, no sentence: the SOP is
# byte-for-byte what it was.
[ -x "$HARNESS/bin/overlap-guard.sh" ] && PROMPT_TEXT="$PROMPT_TEXT

FILE-OVERLAP GUARD (deterministic — run it, do not reason about it). Immediately before you launch a build for a ticket, run \`$HARNESS/bin/overlap-guard.sh $PROJECT <KEY>\`. It answers LAUNCH (go — every error answers LAUNCH too, except an unreadable open-PR list with no cached copy, which DEFERs as \`DEFER <KEY> gh unknown …\`) or DEFER, and a DEFER names the sibling build or open PR whose files collide. On DEFER do NOT launch that ticket this tick: leave its queue line in place, and say in your output which key deferred and on which files. The next tick re-offers it — this is BUILD_DEFERRED semantics, not a queue and not a wait."
# <<< overlap guard
rt_pause_builds  # BH-1672: a live builds pause appends a no-launch directive before SHARD_SOP (bin/lib/rt/gate.sh)
rt_dispatch_mode  # BH-6350: hotfix-only mode — one log line + launch directive (bin/lib/rt/gate.sh)
# BH-6159: the saved reasons of this project's reopened tickets (bin/lib/reopen-reason.sh); empty = prompt unchanged
[ -r "$HARNESS/bin/lib/reopen-reason.sh" ] && . "$HARNESS/bin/lib/reopen-reason.sh" 2>/dev/null && rr_on && RR_NOTE=$(rr_triage_note "$PROJECT" 2>/dev/null) && [ -n "$RR_NOTE" ] && PROMPT_TEXT="$PROMPT_TEXT

$RR_NOTE"
# The SOP as written, kept aside before the arms below wrap it in this tick's
# scope. A triage shard carries its OWN one-ticket scope and then the SOP; handed
# the wrapped copy it would also be handed the whole tick's reading list, which
# is the serial tick rebuilt inside every shard.
SHARD_SOP="$PROMPT_TEXT"
SCOPE_N=full
GATE_REASON="${GATE_DECISION#RUN }"

# Stage: bin/lib/rt/scope.sh — board_section() and this tick's scope arms.
rt_scope
# Scoped-effort tiering (the operator 2026-08-21): queue/sweep ticks are the mechanical
# tick types (same reasoning that already routes results-sweep to the light
# claude model above) AND now carry a small deterministic scope instead of full
# board context — reasoning effort "high" was benched on FULL-context triage
# and is oversized here (~1.3M reasoning tokens/day on the hub). Judgment ticks
# (board-changed, daily-sweep, forced) keep the standing GROK_EFFORT. Override
# with SCOPED_GROK_EFFORT in env; only affects the grok runner.
EFFECTIVE_GROK_EFFORT="${GROK_EFFORT:-}"
case "$SCOPE_N" in
  queue|sweep) EFFECTIVE_GROK_EFFORT="${SCOPED_GROK_EFFORT:-medium}" ;;
esac
# The contract is catalog/agent-contracts/triage-system-append.txt, read through
# bin/triage-contract.sh, so the fleet and the weekly eval cannot ship different
# words.
#
# Resolved into a variable FIRST, and checked, for two reasons. `VAR="$(cmd)" prog`
# swallows cmd's exit status entirely — this file runs under `set -uo pipefail`,
# not `-e` — so a missing contract would hand agent-call an EMPTY append, the
# model would stop emitting DECISION lines, bin/decision-log.sh would harvest
# nothing, and logs/decisions.log would go quiet looking exactly like a calm day.
# And a comment may never sit between a `\` continuation and its command: the
# backslash joins the two lines, so the rest of the command becomes commented
# out. That is invisible to `bash -n` and cost GROK_EFFORT its export here.
TRIAGE_APPEND="$("$HARNESS/bin/triage-contract.sh" 2>>"$ALERTS")"
if [ -z "$TRIAGE_APPEND" ]; then
  echo "$STAMP [$PROJECT] TRIAGE CONTRACT MISSING: bin/triage-contract.sh returned nothing, so this tick would run without its BUILD DEDUPE and DECISION LOG rules — refusing the tick rather than degrading it silently. Fix: bin/harness-sync.sh (catalog/agent-contracts/triage-system-append.txt is missing from this box)." >> "$ALERTS"
  exit 1
fi
# Stage: bin/lib/rt/shards.sh — one session per ticket; exits the tick when it dispatches.
rt_shards
# Stage: bin/lib/rt/launch.sh — the single-session agent call and its close-out.
rt_launch

# $13 (cost_usd), not $NF: the row grew seven columns on 2026-09-14 and $NF is
# now run_id. A position that moves is not a column.
COST_USD=$(tail -1 "$HARNESS/logs/cost.csv" 2>/dev/null | awk -F, '$4=="triage"{print $13}')
SUMMARY="$(grep -oE 'tickets=[^"]*' "$OUT" | tail -1 | cut -c1-200)"
[ -n "$SUMMARY" ] || SUMMARY="$(tail -3 "$OUT" | tr '\n' ' ' | cut -c1-200)"
SUMMARY="$SUMMARY [gate=${GATE_DECISION#RUN } scope=$SCOPE_N model=$TRIAGE_MODEL cost=\$${COST_USD:-?}]"
rt_cg_skip_log || echo "$STAMP [$PROJECT] rc=$RC :: $SUMMARY" >> "$LOG"  # BH-4120: a call-guard repeat logs rc=skip and sets BEAT_RC (bin/lib/rt/launch.sh)
[ -z "$RT_CG_SKIP" ] && [ $RC -ne 0 ] && echo "$STAMP [$PROJECT] triage run exited rc=$RC (see $OUT)" >> "$ALERTS"
# Console beat
DISK=$(df -h / | awk 'NR==2{print $5" used, "$4" free"}')
MEM=$(free -m | awk 'NR==2{printf "%.0f%% mem", $3/$2*100}')
"$HARNESS/bin/beat.sh" "$(jq -nc --arg rkey "run:$PROJECT:$RUN_START_EPOCH" --arg p "$PROJECT" \
  --argjson rc "$([ -n "$BEAT_RC" ] && echo "$BEAT_RC" || echo "$RC")" --arg s "$SUMMARY" --arg st "$(date -u -d @$RUN_START_EPOCH '+%Y-%m-%dT%H:%M:%SZ')" \
  --arg fin "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg disk "$DISK" --arg mem "$MEM" \
  --arg detail "$(tail -c 7000 "$OUT" 2>/dev/null)" \
  '{kind:"run",rkey:$rkey,project:$p,run_kind:"triage",rc:$rc,summary:$s,started_at:$st,finished_at:$fin,disk:$disk,mem:$mem,detail:$detail}')"
exit 0
