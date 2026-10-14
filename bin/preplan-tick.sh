#!/bin/bash
# Cron tick (every 2 min): if a build is mid-flight, pre-plan the next queued
# ticket so its plan is ready when the build lock frees. Deterministic, no LLM.
#
# SPECULATIVE MODE (the operator, 2026-09-14). The rule above waited for a build to be
# running and pre-planned exactly one ticket, which is the narrowest slice of
# the latency it exists to remove. Measured tonight on project-5: plan 7-10 min
# of a 60-75 min ticket. The two tickets that pay that ten minutes for nothing
# are the ones we can see coming — a CHILD whose parent PR is already open or
# merged, and the next READY ticket the triage tick will pick up within 20
# minutes — so both classes are pre-planned too, up to PREPLAN_PARALLEL at once
# instead of one, and the "only while a build runs" gate is dropped (a child
# becomes buildable exactly when its parent's build ENDS, which is the moment
# the old gate stopped looking).
#
# MID-BUILD PARENTS (2026-09-16). "A child whose parent PR is already open"
# above is a fact about GitHub, and it arrives 45-70 minutes after the parent's
# build starts — the whole time that build runs, its children read as children
# of work nobody had started and rode the bottom of the cap as the `blocked`
# class, if they rode at all. bin/preplan-candidates.sh now also calls a parent
# CLEARING while it is BUILDING (preplan_midbuild_keys: a build dir with no
# RESULT, a held build-key lock, a `running` build row in the jobs ledger), and
# prints those children as `child-building`. That is the hour
# bin/dep-verify.sh's file half needs: it reads the CHILD's planned-files list,
# a child with no pre-plan is UNKNOWN, and UNKNOWN is obeyed exactly like a hard
# blocker — so bin/unblocked-children.sh can only release a disjoint sibling
# with evidence that already exists.
#
# bin/preplan-candidates.sh chooses; this file only launches, and only within
# the cap. PREPLAN_SPECULATIVE=0 (or flags/preplan-speculative-off) restores the
# 2026-07-23 behaviour below, byte for byte.
set -u
HARNESS="${HARNESS:-/root/harness}"
Q="$HARNESS/logs/READY-QUEUE.log"
LOG="$HARNESS/logs/preplan.log"

# --- BH-1132: the lane's one off-switch -------------------------------------
# flags/all-off, flags/lane-off-preplan-tick, or the D1 pause_flags row of the same
# name stops this tick (exit 0 — a paused lane is not a failure). With no flag
# and no row this returns immediately and the lane behaves exactly as it always
# has, and an unreachable worker fails OPEN to the last cached answer.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off preplan-tick.
# shellcheck disable=SC1091
. "${HARNESS}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit preplan-tick
# THE KNOBS, BELOW THE ENV LOAD (BH-1165). The gate above stops this lane; this
# is what lets a settings row reach its own unmodified ${KNOB:-default} reads.
# It is BELOW `set -a; . env/global.env` on purpose: above it, the env file
# re-assigns every name and the row silently loses. Fails open — with no row,
# nothing is exported and the lane behaves byte-for-byte as it does today.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    preplan-tick

# THE HUB_MODULE SIGNAL (BH-6384): one existing file planned by 3+ pre-planned
# tickets of a project. Up here, before the tick's early exits, so a busy or an
# idle tick still reaches it. The script keeps a daily stamp per project, so
# every tick but the first of the UTC day costs a file read. A signal, not a
# gate: bounded, output discarded, rc ignored.
HMW="$HARNESS/bin/hub-module-warn.sh"
[ -x "$HMW" ] && { timeout 60 "$HMW" --box >/dev/null 2>&1 </dev/null || true; }

# THE READY SET (BH-1033): the file's lines UNION the `ready` build_queue rows.
# One definition, in one lib; with it absent this is the grep of $Q that was
# here before, character for character.
# shellcheck source=bin/lib/ready-queue.sh
[ -r "$HARNESS/bin/lib/ready-queue.sh" ] && . "$HARNESS/bin/lib/ready-queue.sh" 2>/dev/null
command -v rq_lines >/dev/null 2>&1 || rq_lines() { grep -E '^[A-Z]+-[0-9]' "$Q" 2>/dev/null; }
# READ ONCE PER TICK, AND ONLY IF THE TICK GETS THAT FAR. The housekeeping
# sweep below walks every directory under plans/, and asking the worker inside
# that loop would buy one request per directory every two minutes for an answer
# that cannot change mid-tick; computing it at the top instead would buy one on
# every tick that stands down before it has any use for the queue at all.
# rql_load SETS $RQL in the CURRENT shell and must not be called in a pipeline
# or a command substitution — a memo written in a subshell dies with it, and the
# next `rql_load` would buy the read again, which is the cost this avoids.
RQL=""; _RQL_SET=0
rql_load() {
  [ "$_RQL_SET" = 1 ] && return 0
  RQL=$(rq_lines "$HARNESS" "" 2>/dev/null); _RQL_SET=1
}
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HARNESS/bin/lib/preplan-lib.sh" ] && . "$HARNESS/bin/lib/preplan-lib.sh"
command -v preplan_speculative >/dev/null 2>&1 || preplan_speculative() { echo 0; }
# BH-2543: the readiness and cadence gates of the speculative loop. Fail-open
# like the lib above — a box without them launches exactly as it did.
# shellcheck source=bin/lib/preplan-ready.sh
[ -r "$HARNESS/bin/lib/preplan-ready.sh" ] && . "$HARNESS/bin/lib/preplan-ready.sh"
# shellcheck source=bin/lib/preplan-cadence.sh
[ -r "$HARNESS/bin/lib/preplan-cadence.sh" ] && . "$HARNESS/bin/lib/preplan-cadence.sh"
# BH-1016 fallbacks. A box whose lib has not synced yet must behave exactly as it
# does today — every re-plan allowed, nothing terminal — rather than deny every
# key because a function is missing. The cap fails OPEN, like every other gate
# in this file.
PP_CAP_SHIM=0
command -v preplan_replan_allow >/dev/null 2>&1 || {
  PP_CAP_SHIM=1
  preplan_replan_allow() { return 0; }
  preplan_deferred()     { return 1; }
  preplan_replan_fp()    { printf -- '-\n'; }
  preplan_stale_max()    { printf -- '-\n'; }
}

# >>> cap-off trace (BH-1053)
# A CAP THAT IS OFF MUST SAY SO. Both fail-open paths are silent by
# construction: preplan_replan_allow returns 0 when _preplan_state cannot make
# the ledger directory (state/ unwritable, a full disk, a bad mode), and the
# shim above returns 0 when the library has not synced to this box. Either way
# EVERY stale answer is allowed and logs/preplan.log carries no trace at all —
# which is the 152-re-plans-in-a-day runaway (project-4, 2026-09-18, $1,037 of
# pre-plan spend) running again with nothing to find it by. The fail-open
# stays; failing closed is a lane that silently stops pre-planning and nobody
# notices for a week. The silence is what goes.
#
# ONE LINE PER TICK, written by the first key this tick judges: a box with
# nothing queued says nothing (this is a trace on the cap being consulted, not
# a heartbeat), and a box that is genuinely off says it every two minutes for
# as long as the fault lasts, which is what makes it findable. rc is always 0 —
# this reports, it never gates.
PP_CAP_SAID=0
preplan_cap_trace() {
  [ "$PP_CAP_SAID" = 0 ] || return 0
  PP_CAP_SAID=1
  local why=""
  if [ "${PP_CAP_SHIM:-0}" = 1 ] || ! command -v _preplan_state >/dev/null 2>&1; then
    why="bin/lib/preplan-lib.sh carries no stale re-plan cap on this box (not synced)"
  elif ! _preplan_state "$HARNESS" >/dev/null 2>&1; then
    why="$HARNESS/state/preplan cannot be created"
  else
    return 0
  fi
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$(date -u '+%F %TZ') PREPLAN_CAP_OFF $why — every stale re-plan is ALLOWED and none is counted (fail-open)" >> "$LOG"
  return 0
}
# <<< cap-off trace

if [ "$(preplan_speculative "$HARNESS")" = 0 ]; then
# >>> legacy single pre-plan (2026-07-23) — unchanged, and the kill flag's target
# only overlap while a build is actually running
pgrep -f 'bin/run-build.sh' >/dev/null || exit 0
# don't stack pre-plans
pgrep -f 'bin/run-preplan.sh' >/dev/null && exit 0
# `[ -n "$RQL" ]`, not the `[ -s "$Q" ]` this replaces: the test is now "is
# there ready WORK", which a row satisfies and a file of blank lines does not.
# The one case that changes is a queue file with bytes but no `^<KEY>-<n>` line
# — it used to fall through to the housekeeping sweep below having launched
# nothing, and now exits first. The sweep is a >24h pruner that runs again on
# the next tick with a real line; nothing it drops is time-critical.
rql_load
[ -n "$RQL" ] || exit 0
# Refuse on an empty registry. Without this, project-of.sh below returns nothing
# for every queue line, each one logs "no project" into a file nobody reads, and
# pre-planning stops fleet-wide while the tick keeps exiting 0.
"$HARNESS/bin/fleet-projects-or-alert.sh" preplan-tick >/dev/null || exit 1

# current build's key (from the newest build dir with no terminal PR/blocked marker)
CUR_KEY=$(pgrep -af 'bin/run-build.sh' | grep -oE '[A-Z]+-[0-9A-Za-z]+$' | head -1)

# first queue line: "<KEY> <ticket-id> — ... project=<repo> ..." (project= token
# preferred; fall back to a repo name mentioned anywhere in the line)
while IFS= read -r line; do
  key=$(echo "$line" | grep -oE '^[A-Z]+-[0-9A-Za-z]+') || continue
  [ -n "$key" ] || continue
  [ "$key" = "${CUR_KEY:-}" ] && continue
  tid=$(echo "$line" | awk '{print $2}')
  proj=$(echo "$line" | grep -oE 'project=[a-z-]+' | cut -d= -f2)
  if [ -z "$proj" ]; then
    # fleet.conf, not four names: a queue line for a newer project matched
    # nothing, the tick logged "no project", and that ticket was never
    # pre-planned — an optimisation that silently applied to four projects.
    proj=$("$HARNESS/bin/project-of.sh" "$line" 2>/dev/null || echo "")
  fi
  [ -z "$proj" ] && { echo "$(date -u '+%F %TZ') tick: no project for $key, skip" >> "$LOG"; continue; }
  # already pre-planned?
  [ -s "$HARNESS/plans/$proj-$key/plan.md" ] && exit 0
  # >>> legacy terminal skip
  # A key the pre-plan ledger has settled (#1014 review). The lane refuses it
  # anyway, so launching it here spends this tick's ONE pre-plan on a refusal
  # and writes the same PREPLAN_SKIP line every two minutes for as long as the
  # key sits on the queue. Move to the next queue line instead, and say why
  # once — the marker lives beside the record it explains.
  if command -v preplan_terminal >/dev/null 2>&1 \
     && LREASON=$(preplan_terminal "$HARNESS" "$proj" "$key"); then
    LD="$HARNESS/plans/$proj-$key"
    if [ ! -e "$LD/skip-logged" ]; then
      echo "$(date -u '+%F %TZ') [$proj/$key] PREPLAN_SKIP $LREASON" >> "$LOG"
      : > "$LD/skip-logged" 2>/dev/null
    fi
    continue
  fi
  # <<< legacy terminal skip
  # >>> legacy small skip (P2): a pre-plan that buys nothing is not bought.
  if command -v preplan_small_reason >/dev/null 2>&1 \
     && LSMALL=$(preplan_small_reason "$HARNESS" "$proj" "$key"); then
    preplan_small_log "$HARNESS" "$proj" "$key" "$LSMALL" "$LOG"
    continue
  fi
  # <<< legacy small skip
  setsid "$HARNESS/bin/run-preplan.sh" "$proj" "$tid" "$key" >/dev/null 2>&1 &
  exit 0
done < <(printf '%s\n' "$RQL")

# housekeeping: drop pre-plans whose key left the queue (>24h old)
rql_load
# >>> queue housekeeping
# A HERE-STRING, NOT A PIPE (BH-1033 fix round 2). This script is `set -u` only,
# but it now sources bin/lib/ready-queue.sh, which sources bin/jobs-client.sh,
# which sets `-o pipefail` for the whole shell. `grep -q` exits at the first
# match; with a ready set bigger than the pipe buffer (~64KB, roughly 600 lines
# fleet-wide) `printf` is still writing, takes SIGPIPE, and under pipefail the
# pipeline is 141 — so the `||` fires and this deletes the pre-plan of a key
# that IS on the queue. Same shape as the BH-1044 dedupe read already written up
# in bin/lib/closeout-terminal.sh. A here-string has no second process and
# cannot report a match as a failure at any size.
find "$HARNESS/plans" -maxdepth 1 -mindepth 1 -type d -mmin +1440 2>/dev/null | while read -r d; do
  k=$(basename "$d" | grep -oE '[A-Z]+-[0-9A-Za-z]+$')
  grep -q "^$k " <<<"$RQL" || rm -rf "$d"
done
# <<< queue housekeeping
exit 0
# <<< legacy single pre-plan
fi

# >>> speculative fan-out
"$HARNESS/bin/fleet-projects-or-alert.sh" preplan-tick >/dev/null || exit 1
# HOW MANY ARE IN FLIGHT IS A LOCK CENSUS, NOT A pgrep. See
# bin/lib/preplan-lib.sh:preplan_held — a cmdline match counts anything that
# merely mentions the script, and a tick that miscounts stands down having done
# nothing, which looks exactly like a tick with nothing to do.
CAP=$(preplan_parallel "$HARNESS")
RUNNING=0
for L in "$HARNESS"/locks/preplan-*.lock; do
  preplan_held "$L" && RUNNING=$((RUNNING+1))
done
FREE=$((CAP - RUNNING))
[ "$FREE" -gt 0 ] || exit 0

# This box's projects, not the fleet's: a pre-plan for a project whose watcher
# and repo live on another machine has no checkout here to plan against.
BOX=$("$HARNESS/bin/box-name.sh" 2>/dev/null || true)
PROJECTS=""
[ -n "$BOX" ] && PROJECTS=$("$HARNESS/bin/fleet-conf.sh" --projects-on-box "$BOX" 2>/dev/null || true)
[ -n "$PROJECTS" ] || PROJECTS=$("$HARNESS/bin/fleet-projects-or-alert.sh" preplan-tick 2>/dev/null || true)

for P in $PROJECTS; do
  [ "$FREE" -gt 0 ] || break
  [ -d "${REPOS_ROOT:-/root/repos}/$P" ] || continue
  BREF=$(preplan_base_ref "$HARNESS" "$P")
  # THE CANDIDATE SNAPSHOT (BH-475). bin/overlap-schedule.sh needs the same
  # ready-set this loop is about to walk, and it runs on the triage tick — a
  # different cadence, on a box whose gh budget is one PAT. Asking the
  # classifier again there would buy two more GitHub requests per project per
  # tick for an answer that was computed here 0-2 minutes ago, so the answer is
  # written down instead and the scheduler reads it while it is young enough
  # (OVERLAP_SNAPSHOT_MAX_AGE, default 600s), falling back to a live call when
  # it is not. Written temp-then-mv so a reader never sees a half file, and a
  # classifier that printed nothing leaves an EMPTY snapshot rather than a stale
  # one — "no candidates" and "the last candidates we happened to see" are not
  # the same answer.
  CSNAP="$HARNESS/state/preplan-candidates/$P.tsv"
  mkdir -p "$HARNESS/state/preplan-candidates" 2>/dev/null
  CTMP=$(mktemp 2>/dev/null) || CTMP="$CSNAP.$$"
  if ! "$HARNESS/bin/preplan-candidates.sh" "$P" > "$CTMP" 2>/dev/null; then :; fi
  mv -f "$CTMP" "$CSNAP" 2>/dev/null && CTMP="$CSNAP"
  while IFS=$'\t' read -r KEY TID WHY; do
    [ -n "${KEY:-}" ] || continue
    [ "$FREE" -gt 0 ] || break
    # A key whose build-key flock is HELD is already building, and that build
    # writes its own plan.md — pre-planning it now spends a session to lose a
    # race. Same lock bin/run-build.sh takes for per-ticket dedupe.
    preplan_held "$HARNESS/locks/build-key-$P-$KEY.lock" && continue
    # A key whose pre-plan lock is HELD is mid-plan from an earlier tick: the
    # child would exit 0 on its flock, but the "launch" line and the cap slot
    # were already spent on it (04:42-04:46Z 09-14: two phantom launches per
    # tick starved the third candidate). Skip it here, silently.
    preplan_held "$HARNESS/locks/preplan-$P-$KEY.lock" && continue
    # THE RE-PLAN CAP, ASKED BEFORE THE SESSION IS BOUGHT (BH-1016). A key that
    # has spent its stale re-plans is terminal until its queue line changes: the
    # BUILD stage plans it from scratch, exactly as it did before pre-planning
    # existed. Silent on purpose — the one PREPLAN_SKIP line was written by the
    # tick that terminalized it, and repeating it every 2 minutes is the noise
    # that makes a log unreadable. bin/lib/preplan-lib.sh holds the why.
    preplan_cap_trace
    RFP=$(preplan_replan_fp "$HARNESS" "$KEY")
    preplan_deferred "$HARNESS" "$P" "$KEY" "$RFP" && continue
    D=$(preplan_dir "$HARNESS" "$P" "$KEY")
    # >>> preplan terminal skip
    # A key the pre-plan ledger has already settled (BH-475 review): a session
    # ran, it was billed, and it produced no plan — `empty` once, or `failed`
    # up to PREPLAN_MAX_ATTEMPTS. The lane itself refuses too, which is what
    # saves the money; this saves the PREPLAN_PARALLEL slot, so the tick spends
    # it on a key that can still produce something.
    #
    # THE REASON IS LOGGED ONCE, not every two minutes. The marker rides in the
    # same directory as the record it explains, so "why did this key stop being
    # planned" is answerable from the log, without 720 identical lines a day
    # burying every other reason the tick writes.
    if command -v preplan_terminal >/dev/null 2>&1 \
       && TREASON=$(preplan_terminal "$HARNESS" "$P" "$KEY"); then
      if [ ! -e "$D/skip-logged" ]; then
        echo "$(date -u '+%F %TZ') [$P/$KEY] PREPLAN_SKIP $TREASON" >> "$LOG"
        : > "$D/skip-logged" 2>/dev/null
      fi
      continue
    fi
    # <<< preplan terminal skip
    # >>> preplan small skip (P2, 2026-09-25)
    # A PRE-PLAN THAT BUYS NOTHING IS NOT BOUGHT: triage sized it S, it is
    # copy/docs work, or its build is running right now (bin/lib/preplan-lib.sh
    # :preplan_small_reason has the why and the knob). Asked before the stale
    # re-plan below as well, so a small key never re-buys a plan either; a plan
    # already on disk is left alone for the build to adopt or discard. The
    # mid-build set costs one ledger read, so it is asked once per project and
    # only when a candidate actually reaches this line.
    if command -v preplan_small_reason >/dev/null 2>&1; then
      if [ "${PP_MID_P:-}" != "$P" ]; then
        PP_MID=$(preplan_midbuild_keys "$HARNESS" "$P" 2>/dev/null); PP_MID_P="$P"
      fi
      if SREASON=$(preplan_small_reason "$HARNESS" "$P" "$KEY" "$PP_MID"); then
        preplan_small_log "$HARNESS" "$P" "$KEY" "$SREASON" "$LOG"
        continue
      fi
    fi
    # <<< preplan small skip
    # >>> preplan readiness (BH-2543)
    # A key bin/lib/preplan-ready.sh calls not ready is not bought. Logged once
    # per (key, reason) through the small-skip logger, which also keeps the
    # key's planned-files.txt on the free tiers. Needs that logger: without it
    # the key launches rather than vanishing with no line.
    if command -v preplan_not_ready >/dev/null 2>&1 && command -v preplan_small_log >/dev/null 2>&1 \
       && NREASON=$(preplan_not_ready "$HARNESS" "$P" "$KEY" "$WHY"); then
      preplan_small_log "$HARNESS" "$P" "$KEY" "not-ready: $NREASON" "$LOG"
      continue
    fi
    # <<< preplan readiness
    PP_STALE=0
    if [ -s "$D/plan.md" ]; then
      # A pre-plan that main has already invalidated is worse than none: the
      # consumer would discard it at adopt time and the build would pay the
      # full plan anyway, 20 minutes later than it had to. Drop it here and
      # re-plan now, while the ticket is still waiting.
      WHYS=$(preplan_check "$D" "${REPOS_ROOT:-/root/repos}/$P" "$BREF"); RCS=$?
      [ "$RCS" = 0 ] && continue
      # Stale. The cadence gate below decides whether anything launches
      # BEFORE the re-plan is counted and the plan dropped, so a deny costs
      # nothing (BH-2998). It sits after the fresh-plan continue above because
      # an allow stamps cadence-<p>.last.
      PP_STALE=1
    fi
    # >>> preplan cadence (BH-2543)
    # bin/lib/preplan-cadence.sh may hold a launch back; a missing function
    # means allow. `continue`, never FREE: a held key leaves its slot to the next.
    if type preplan_cadence_allow >/dev/null 2>&1; then
      preplan_cadence_allow "$HARNESS" "$P" "$WHY" || continue
    fi
    # <<< preplan cadence
    if [ "$PP_STALE" = 1 ]; then
      # Re-plan only while this ticket has re-plans left. The counter is
      # persisted by the call below BEFORE the launch, and the directory is
      # kept on the deny path: a stale plan the build stage discards costs
      # nothing, while deleting it would hand the next tick a MISSING plan and
      # a fresh reason to buy one.
      if ! preplan_replan_allow "$HARNESS" "$P" "$KEY" "$RFP"; then
        # ONCE PER KEY PER ARMING, EVEN WHEN THE MARKER COULD NOT BE WRITTEN
        # (BH-1053). The terminal marker preplan_replan_allow just wrote is
        # what stops the next tick repeating this line — so a marker write that
        # FAILS (a full disk, a path that is not a file) brought the line back
        # every two minutes, 720 identical lines a day in the one file an
        # operator reads to find out why a ticket stopped being planned. The
        # log is the fallback memory: it is the file we are writing to anyway,
        # and it is the one thing still writable at that moment. The
        # FINGERPRINT in the prefix is what keeps this per-ARMING rather than
        # per-key-forever — a ticket that really moved re-arms the budget and
        # gets its own line when it spends it again.
        PP_SAID="[$P/$KEY] PREPLAN_SKIP stale re-plan cap reached (fp $RFP"
        grep -qF "$PP_SAID" "$LOG" 2>/dev/null \
          || echo "$(date -u '+%F %TZ') $PP_SAID, $(preplan_stale_max "$HARNESS")/24h) — PREPLAN_DEFER_TO_BUILD, the build stage will plan ($WHYS)" >> "$LOG"
        continue
      fi
      echo "$(date -u '+%F %TZ') [$P/$KEY] PREPLAN_STALE ($WHYS) — dropping and re-planning" >> "$LOG"
      case "$D" in "$HARNESS/plans/"*) rm -rf "$D" ;; esac
    fi
    echo "$(date -u '+%F %TZ') [$P/$KEY] pre-plan launch ($WHY, $((CAP-FREE+1))/$CAP)" >> "$LOG"
    setsid "$HARNESS/bin/run-preplan.sh" "$P" "${TID:--}" "$KEY" >/dev/null 2>&1 &
    FREE=$((FREE-1))
  done < "$CTMP"
  # The snapshot IS the file we just read when the mv landed; anything else is a
  # temp this tick owns and must not leave behind.
  [ "$CTMP" = "$CSNAP" ] || rm -f "$CTMP"
done

# housekeeping: drop pre-plans nothing is waiting for any more (>24h old and no
# longer on the queue). Unchanged from the legacy path — the fan-out adds
# candidates, never a second retention rule.
rql_load
# >>> queue housekeeping
# A HERE-STRING, NOT A PIPE (BH-1033 fix round 2). This script is `set -u` only,
# but it now sources bin/lib/ready-queue.sh, which sources bin/jobs-client.sh,
# which sets `-o pipefail` for the whole shell. `grep -q` exits at the first
# match; with a ready set bigger than the pipe buffer (~64KB, roughly 600 lines
# fleet-wide) `printf` is still writing, takes SIGPIPE, and under pipefail the
# pipeline is 141 — so the `||` fires and this deletes the pre-plan of a key
# that IS on the queue. Same shape as the BH-1044 dedupe read already written up
# in bin/lib/closeout-terminal.sh. A here-string has no second process and
# cannot report a match as a failure at any size.
find "$HARNESS/plans" -maxdepth 1 -mindepth 1 -type d -mmin +1440 2>/dev/null | while read -r d; do
  k=$(basename "$d" | grep -oE '[A-Z]+-[0-9A-Za-z]+$')
  grep -q "^$k " <<<"$RQL" || rm -rf "$d"
done
# <<< queue housekeeping
# ...and the re-plan ledger with them (BH-1016). 48h, not 24: past the window
# every stamp is pruned and every marker expires on its own read, so a file
# older than that holds nothing anyone will act on. One tiny file per key is
# cheap, but a directory that only ever grows is still a directory that only
# ever grows.
find "$HARNESS/state/preplan" -maxdepth 1 -type f -mmin +2880 -delete 2>/dev/null
exit 0
# <<< speculative fan-out
