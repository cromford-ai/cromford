#!/bin/bash
# Wave 3: tick every flagged project's runner pool. Cron: */2 on the hub.
# An orphaned flyctl agent holding a lock fd makes every tick below a silent
# no-op (2026-09-12 project-5 stall) — clear it before ticking.
#
# EVERY PROJECT AT ONCE (the operator, 2026-09-14: pool autoscale). A tick OWNS its
# spawns and waits for them (~40-60s each), so a sequential sweep made the last
# project's pool wait on the first eight: nine projects meant a pool that ticked
# once every ~8 minutes on a */2 cron, and a sibling project is a throughput
# ceiling we chose, not one Fly imposed. Each bin/fly-pool.sh self-locks on its
# own locks/fly-pool-<p>.lock with `flock -n` and exits if it is held, so running
# them together is exactly the same safety with none of the waiting.
# KILL FLAG: POOL_AUTOSCALE=0 (env/global.env) restores the sequential sweep and
# skips the one-shot below. bin/pool-cap.sh --autoscale is its one reader.
#
# HARNESS is overridable for the same reason bin/fly-pool.sh took that seam: a
# suite that cannot point this loop at a scratch tree cannot drive it at all,
# and an undriven loop passes vacuously. Cron sets it nowhere.
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fly-pool-tick
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fly-pool-tick.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-pool-tick
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-pool-tick

"$H/bin/fly-lock-guard.sh" >/dev/null 2>&1 || true
AS=$("$H/bin/pool-cap.sh" --autoscale 2>/dev/null)

# --- ONE-SHOT: the legacy per-project ceilings go (the operator, 2026-09-14) ----------
# Every box's flags/fly-pool-<p> holds a NUMBER, because bin/fly-pool-rollout.sh
# wrote one — 2 at wave-3, then 10, then 20 for project-5, raised by hand "as
# much parallel as possible". Those numbers are a HARD ceiling under the new
# resolution too, so shipping "unlimited by default" without retiring them would
# change precisely nothing: nine projects would stay capped at 10 and the fleet
# ceiling would still be ours. Nothing in this harness waits for a person to
# empty nine files, so the code that makes the flag meaningless also retires it.
# The flag's PRESENCE is the pool's enable switch and is left exactly as it is;
# only the number inside is dropped, ONCE per project, with the old value kept
# in state/fly-pool/legacy-caps.<p> so the change is auditable and reversible.
# A ceiling anyone genuinely wants belongs in fly/pool-caps.conf, where it is a
# reviewed line that survives this and every later rollout.
retire_legacy_cap() { # retire_legacy_cap <flag-file> <project>
  local n; n=$(cat "$1" 2>/dev/null | tr -dc '0-9')
  [ -n "$n" ] || return 0
  # Retired once and once only: a number written AFTER this ran is a decision
  # someone made with the new semantics in hand, and it stands.
  [ -e "$H/state/fly-pool/legacy-caps.$2" ] && return 0
  mkdir -p "$H/state/fly-pool" "$H/logs"
  printf '%s retired %s by bin/fly-pool-tick.sh (2026-09-14 pool autoscale)\n' \
    "$n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$H/state/fly-pool/legacy-caps.$2"
  : > "$1"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$2] legacy flag cap $n retired — the pool now follows queue depth (old value in state/fly-pool/legacy-caps.$2; a ceiling you want belongs in fly/pool-caps.conf)" >> "$H/logs/fly-pool.log"
}

# --- ONE-SHOT: the stale persistent-builder record goes (BH-660) --------------
# A pool-routed project still carries state/fly/<p>.json with the machine_id of
# the persistent builder it stopped using. Nothing on the pool route reads that
# id — bin/fly-dispatch.sh stands down for pool projects before it ever reaches
# bin/fly-api.sh — but bin/fleet-fly-block.sh publishes it as `builder`, so the
# console and the watchdog keep reporting a builder machine that is doing
# nothing, and BH-660 counted two of them.
#
# The RECORD is what this retires, never the MACHINE: the pool must not run a
# single Fly command against a builder-* app (the SPRAWL GUARD in
# bin/fly-pool.sh — that app auto-recreates machines on destroy), and those
# machines carry volumes. So the id is moved, not deleted — `app` stays where
# bin/fly-pool.sh and bin/fly-sync-harness.sh read it, everything else nests
# under `builder_retired`, and one ALERTS line hands a human the exact destroy
# command. Reversible by construction, and a no-op on every later tick because
# the top-level machine_id is gone.
retire_builder_record() { # retire_builder_record <project>
  local f="$H/state/fly/$1.json" mid app tmp
  [ -s "$f" ] || return 0
  mid=$(jq -r 'select(type=="object") | .machine_id // ""' "$f" 2>/dev/null)
  [ -n "$mid" ] && [ "$mid" != null ] || return 0
  app=$(jq -r '.app // ""' "$f" 2>/dev/null)
  tmp="$f.retire.$$"
  jq --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg by 'bin/fly-pool-tick.sh (BH-660)' \
     '{app:(.app // "")} + {builder_retired: (del(.app) + {retired_at:$ts,retired_by:$by})}' \
     "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  [ -s "$tmp" ] || { rm -f "$tmp"; return 0; }
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mkdir -p "$H/logs"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$1] stale builder record retired — machine $mid in ${app:-no app} is no longer published as this project's builder (the id is kept under builder_retired in state/fly/$1.json)" >> "$H/logs/fly-pool.log"
  HARNESS="$H" "$H/bin/alert-line.sh" "[pool/$1] builder machine $mid is still in ${app:-its builder app} and nothing uses it — this box never runs a Fly command against a builder-* app (sprawl guard), so destroy it by hand: fly machine destroy $mid -a ${app:-builder-$1} --force (its volume is your call)"
}

# --- BH-7491: bounded wait and the hard limit on one project tick -------------
# Both knobs are lane.fly-pool-tick.* settings rows (catalog/lanes.d/
# fly-pool-tick.knobs.d), put in the environment by lane_env_apply above.
tick_knob() { # tick_knob <NAME> <default> — digits only, else the default
  local v; v=$(printf %s "${!1:-}" | tr -dc '0-9'); printf '%s\n' "${v:-$2}"
}
tick_wait_bound() {
  local w t0=$SECONDS; w=$(tick_knob POOL_TICK_WAIT_S 300)
  if [ "$w" = 0 ]; then wait; return 0; fi
  # `jobs -pr` lists only RUNNING children; kill -0 would count a finished
  # child nobody has reaped yet.
  while [ -n "$(jobs -pr)" ] && [ $((SECONDS - t0)) -lt "$w" ]; do sleep 1; done
}
# tick_hang_check <project> — runs before that project's tick starts. The
# project lock is the truth about "a tick is running": free -> stamp the start
# of the tick about to run; held -> the stamp says how old the running tick is.
# Past the hard limit (POOL_TICK_HARD_LIMIT_S; 0 = 2 x POOL_TICK_BUDGET_S, so
# 1200 s) one log line and one alert per episode (state/fly-pool-tick/<p>.alerted).
# The tick is never killed.
tick_hang_check() {
  local p="$1" lock="$H/locks/fly-pool-$1.lock" d="$H/state/fly-pool-tick"
  local stamp="$d/$1.since" alerted="$d/$1.alerted" lim b since age
  mkdir -p "$d" 2>/dev/null
  if ! command -v flock >/dev/null 2>&1 || [ ! -e "$lock" ] \
     || ( exec 9>>"$lock"; flock -n 9 ) 2>/dev/null; then
    date +%s > "$stamp" 2>/dev/null
    # The episode marker lives beside the stamp, not in flags/: it is this
    # wrapper's own state, and no switch reads it.
    rm -f "$alerted"
    return 0
  fi
  lim=$(tick_knob POOL_TICK_HARD_LIMIT_S 1200)
  if [ "$lim" = 0 ]; then b=$(tick_knob POOL_TICK_BUDGET_S 600); lim=$((b * 2)); fi
  since=$(tr -dc 0-9 < "$stamp" 2>/dev/null)
  [ -n "$since" ] || { date +%s > "$stamp" 2>/dev/null; return 0; }
  age=$(( $(date +%s) - since ))
  [ "$age" -gt "$lim" ] || return 0
  [ -e "$alerted" ] && return 0
  date +%s > "$alerted" 2>/dev/null
  mkdir -p "$H/logs"
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$p] tick has run ${age}s, past the hard limit of ${lim}s (POOL_TICK_HARD_LIMIT_S; 2 x POOL_TICK_BUDGET_S by default): it holds locks/fly-pool-$p.lock and is NOT killed; other projects tick on" >> "$H/logs/fly-pool.log"
  HARNESS="$H" "$H/bin/alert-line.sh" --id "pool-tick-hung-$p" --project "$p" "[pool/$p] tick has run ${age}s, past the hard limit of ${lim}s: it holds the project lock and is not killed; check logs/fly-pool.log and the tick process on the hub"
}

# --- BH-7509: at most POOL_TICK_MAX_PARALLEL project ticks at once --------------
# Unset (no digits) = nproc; 0 = no cap (zero_means unlimited in the registry,
# BH-7659). A held locks/fly-pool-<p>.lock is a running tick and counts. Free projects are offered oldest state/fly-pool-tick/<p>.since first
# (no stamp = oldest), so a cap never starves the same names. A project over
# the cap gets one line and no stamp; the next cron start offers it again.
# A held project is still started: its own lock turns it away, and
# tick_hang_check still sees how long it has run.
tick_cap() {
  local c; c=$(tick_knob POOL_TICK_MAX_PARALLEL "")
  [ -n "$c" ] || c=$(nproc 2>/dev/null | tr -dc 0-9)
  printf '%s\n' "${c:-0}"   # nproc unreadable: 0 = no cap, as before BH-7509
}
tick_held() { # tick_held <project> — rc 0 when its tick runs now
  local lock="$H/locks/fly-pool-$1.lock"
  command -v flock >/dev/null 2>&1 && [ -e "$lock" ] && ! ( exec 9>>"$lock"; flock -n 9 ) 2>/dev/null
}
tick_start_capped() { # tick_start_capped <project>... — the autoscale start
  local cap run=0 p s
  local -a free=()
  cap=$(tick_cap)
  for p in "$@"; do
    if tick_held "$p"; then
      run=$((run + 1)); tick_hang_check "$p"; "$H/bin/fly-pool.sh" "$p" &
    else
      s=$(tr -dc 0-9 2>/dev/null < "$H/state/fly-pool-tick/$p.since"); free+=("${s:-0} $p")
    fi
  done
  [ "${#free[@]}" -gt 0 ] || return 0
  while read -r s p; do
    [ -n "$p" ] || continue
    if [ "$cap" -gt 0 ] && [ "$run" -ge "$cap" ]; then
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$p] max-ticks: $run of $cap running — $p waits for the next start (POOL_TICK_MAX_PARALLEL)" >> "$H/logs/fly-pool.log"
      continue
    fi
    run=$((run + 1)); tick_hang_check "$p"; "$H/bin/fly-pool.sh" "$p" &
  done < <(printf '%s\n' "${free[@]}" | LC_ALL=C sort -k1,1n -k2,2)
}

# shellcheck source=bin/jobs-client.sh
[ -r "$H/bin/jobs-client.sh" ] && [ -d "$H/bin/lib/jobs" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
# LOAD SHED (BH-7509): while state/hub-load/verdict says over, the ticks still
# start (each one's REAP finishes builds that already run) and bin/fly-pool.sh
# skips its own SPAWN half. One note line here per wrapper run.
# shellcheck source=bin/lib/hub-load-shed.sh
. "$H/bin/lib/hub-load-shed.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/hub-load-shed.sh" 2>/dev/null \
  || hls_over() { return 1; }
# BH-7432: the batched enqueue of the fly-placed projects (ptb_split, below).
# shellcheck source=bin/lib/pool-tick-batch.sh
. "$H/bin/lib/pool-tick-batch.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/pool-tick-batch.sh" 2>/dev/null || true
if hls_over "$H"; then
  mkdir -p "$H/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool] $HLS_LINE — project ticks reap, they spawn nothing" >> "$H/logs/fly-pool.log"
fi
TICK_PROJECTS=()
for f in "$H"/flags/fly-pool-*; do
  [ -f "$f" ] || continue
  case "$f" in *fly-pool-app-*) continue;; esac   # app-name flag, not a project
  P="${f##*fly-pool-}"
  # Only pool-routed projects: this loop is the definition of one, and a project
  # that never had a machine_id is a no-op every tick.
  retire_builder_record "$P"
  if [ "$AS" = 0 ]; then
    "$H/bin/fly-pool.sh" "$P"
  else
    retire_legacy_cap "$f" "$P"
    TICK_PROJECTS+=("$P")
  fi
done
# BATCHED ENQUEUE (BH-7432). ptb_split enqueues every fly-placed project in
# one POST /api/lane-runs/batch and leaves in PTB_HUB only the projects that
# still need a hub tick. With no fly row, the knob POOL_TICK_BATCH=0 or no
# lib, PTB_HUB is every project and this is the start above it replaced.
if [ "${#TICK_PROJECTS[@]}" -gt 0 ]; then
  PTB_HUB=("${TICK_PROJECTS[@]}")
  command -v ptb_split >/dev/null 2>&1 && ptb_split "${TICK_PROJECTS[@]}"
  [ "${#PTB_HUB[@]}" -gt 0 ] && tick_start_capped "${PTB_HUB[@]}"
fi
# BOUNDED WAIT (BH-7491). The sweep used to wait for EVERY tick, so one slow
# project held this wrapper, the single-run gate (BH-7422) turned each later
# cron start away, and every project ticked once per round of the slowest one
# (2026-10-19: project-6-os, 156 queued rows, four tick lines in 5 hours). Now
# the wrapper waits at most POOL_TICK_WAIT_S for its ticks (default 300, under
# the 600 s cron cadence; 0 = wait for all, the old contract). A tick still
# running at the bound is left to finish: it holds its own
# locks/fly-pool-<p>.lock, so a later wrapper run ticks every OTHER project
# while that lock turns the slow one away.
tick_wait_bound

# BH-2522: the files/rows preflight, after every pool above has settled. It
# backfills machines rows from the pool files while fly_machines_rows is off,
# and flips the flag on once they agree and the row is still the seed. Fail
# open: whatever it answers, the tick and the onboard drain below are unchanged.
[ -x "$H/bin/fly-pool-rows-parity.sh" ] && HARNESS="$H" "$H/bin/fly-pool-rows-parity.sh" --backfill --flip >/dev/null 2>&1 || true

# >>> fly-onboard-drain
# THE SSH-FREE CHANNEL (BH-662). fly/onboard-queue.conf is repo-tracked, so a
# merged line reaches the hub on its own fleet-propagate (*/5) with no ssh in
# either direction — which matters because most sessions cannot reach the hub at
# all. This is the half that acts on it: for every queued project that is not
# already routed, launch bin/fly-onboard.sh here, detached, bounded by a ledger.
#
# HUB ONLY, and it asks bin/lib/hub-box.sh rather than assuming: this cron line
# is on cron/hub.cron today, but the file syncs to every box and a watcher box
# that started draining would mint org tokens it has no session for.
#
# BOUNDED, BECAUSE EACH ATTEMPT SPENDS (D21). An onboarding is an image build
# plus a real probe machine, and this tick fires every 2 minutes; a retry-forever
# drain on a project whose token mint is broken would spend all day. The ledger
# is written BEFORE the launch, so a crash after spawning cannot re-spend on the
# next tick.
Q="$H/fly/onboard-queue.conf"
if [ -r "$Q" ]; then
  for _hb in "$(dirname "$0")/lib/hub-box.sh" "$H/bin/lib/hub-box.sh"; do
    [ -r "$_hb" ] && { . "$_hb"; break; }
  done
  if command -v is_hub_box >/dev/null 2>&1 && is_hub_box "$(local_box_name)"; then
    # shellcheck source=bin/lib/env-path.sh
    [ -r "$H/bin/lib/env-path.sh" ] && . "$H/bin/lib/env-path.sh" 2>/dev/null
    command -v harness_env_dir >/dev/null 2>&1 \
      || harness_env_dir() { printf '%s\n' "${HARNESS:-/root/harness}/env"; }
    # Digits only, environment first, then the operator's global.env. A
    # non-numeric value is the DEFAULT, never 0 — "" is not a number of attempts
    # and an unparseable knob must not mean "never retry" or "retry forever".
    onboard_knob() { # onboard_knob <NAME> <default>
      local v="${!1:-}" f
      f="$(harness_env_dir)/global.env"
      if [ -z "$v" ] && [ -r "$f" ]; then
        v=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=//p" "$f" | tail -1)
      fi
      v=$(printf %s "$v" | tr -dc '0-9')
      printf '%s\n' "${v:-$2}"
    }
    MAXA=$(onboard_knob FLY_ONBOARD_MAX_ATTEMPTS 3)
    RETRY=$(( $(onboard_knob FLY_ONBOARD_RETRY_MIN 360) * 60 ))
    BASE_MAXA=$MAXA
    BASE_RETRY=$RETRY
    # Phase-6 retry policy: per-project cap/backoff from retry_policies before
    # the env knobs, gated by the Fly machine registry contract. Fail-open to
    # the env defaults if the worker is down, the contract is off, or the row
    # is absent/malformed.
    # shellcheck source=bin/jobs-client.sh
    [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
    # One contract read per tick, not one per queued project — and none at all
    # on a tick where no project reaches the lookup. ROWS_ON empty means "not
    # asked yet"; it is resolved lazily below, AFTER the routed and gave-up
    # skips, because this loop runs 720 times a day on a hub whose queue holds
    # mostly projects that are already routed.
    ROWS_ON=""
    grep -vE '^[[:space:]]*(#|$)' "$Q" | awk '{print $1}' | while read -r QP; do
      # Field 1 only, and a name that needed cleaning is refused rather than
      # sanitised — it would name a flag file and a Fly app.
      P=$(printf %s "$QP" | tr -dc 'A-Za-z0-9._-'); [ -n "$P" ] && [ "$P" = "$QP" ] || continue
      if command -v routing_builder >/dev/null 2>&1; then
        [ "$(routing_builder "$P" 2>/dev/null)" = pool ] && continue
      else
        flag_on fly-pool "$P" && flag_on builder-fly "$P" && continue
      fi
      S="$H/state/fly-onboard/$P"; mkdir -p "$H/state/fly-onboard" "$H/logs"
      # A project that already gave up costs nothing: no worker call, no log
      # line, before anything else is read. The flag is written once below.
      G="$H/flags/alerted-fly-onboard-gaveup-$P"; [ -e "$G" ] && continue
      # Start from env defaults; a matching retry_policy row may override.
      # POL is the suffix the launch and give-up lines carry when a row applied;
      # there is no per-tick policy line of its own (720 ticks a day).
      MAXA=$BASE_MAXA
      RETRY=$BASE_RETRY
      POL=""
      if [ -z "$ROWS_ON" ]; then
        ROWS_ON=0
        command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on >/dev/null 2>&1 && ROWS_ON=1
      fi
      if [ "$ROWS_ON" = 1 ]; then
        POLICY=$(job_retry_policy "fly-onboard/$P/hub" 2>/dev/null)
        if [ -n "$POLICY" ]; then
          # Digit-only, the same check job_retry_policy_set applies on write:
          # "-5" and "1.5" are refused, not stripped into 5 and 15.
          P_MAXA=$(printf %s "$POLICY" | cut -f2)
          P_RETRY=$(printf %s "$POLICY" | cut -f3)
          case "$P_MAXA" in ''|*[!0-9]*) P_MAXA="" ;; esac
          case "$P_RETRY" in ''|*[!0-9]*) P_RETRY="" ;; esac
          [ -n "$P_MAXA" ] && [ "$P_MAXA" -gt 0 ] && MAXA=$P_MAXA
          [ -n "$P_RETRY" ] && [ "$P_RETRY" -gt 0 ] && RETRY=$P_RETRY
          POL=" (policy fly-onboard/$P/hub max_attempts=$MAXA backoff=${RETRY}s)"
        fi
      fi
      N=$(tr -dc 0-9 2>/dev/null < "$S.attempts"); N=${N:-0}
      if [ "$N" -ge "$MAXA" ]; then
        # One give-up line, ever, per project — flag-deduped, because this loop
        # runs 720 times a day.
        : > "$G"
        HARNESS="$H" "$H/bin/alert-line.sh" "[fly-onboard] $P: $N onboarding attempts failed, not retrying$POL — fix the step named in the earlier [fly-onboard] line, then rm state/fly-onboard/$P.attempts and flags/alerted-fly-onboard-gaveup-$P on the hub (or run bin/fly-onboard.sh $P there)"
        continue
      fi
      LAST=$(tr -dc 0-9 2>/dev/null < "$S.last"); NOW=$(date +%s)
      [ $(( NOW - ${LAST:-0} )) -ge "$RETRY" ] || continue
      echo $((N+1)) > "$S.attempts"; echo "$NOW" > "$S.last"
      echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [pool/$P] fly-onboard queued line -> launching bin/fly-onboard.sh $P (attempt $((N+1)) of $MAXA$POL)" >> "$H/logs/fly-pool.log"
      # Detached: a rollout takes minutes and this tick owns none of it.
      # fly-onboard.sh's own flock -n makes a duplicate launch a no-op anyway.
      setsid "$H/bin/fly-onboard.sh" "$P" >> "$H/logs/fly-onboard.log" 2>&1 < /dev/null &
    done
  fi
fi
# <<< fly-onboard-drain
# >>> pool machine-hour budget (BH-7190)
# One pass over every pool project: log the day's machine-hours and ALERT at the
# budget row's percent. Alert only, it changes no cap and stops no machine, and it
# is bounded by its own timeout so a slow settings read cannot hold the tick.
[ -x "$H/bin/pool-budget.sh" ] && HARNESS="$H" timeout 120 "$H/bin/pool-budget.sh" >/dev/null 2>&1 || true
# <<< pool machine-hour budget
exit 0
