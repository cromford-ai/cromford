#!/bin/bash
# bin/fleet-propagate.sh [--check|--force] — hub cron (*/5): land a merge to main
# on the WHOLE fleet within five minutes, instead of at 05:17Z tomorrow.
#
# Why (the operator, 2026-09-14: "Yes sync and rebake on every bin change"). Harness code
# reached the boxes only through the daily 05:17Z bin/update-runners.sh, and the
# pool images only through the 05:40Z bin/fly-image-refresh.sh. So a bin/ fix
# merged at 06:00 ran nowhere for 23 hours — and for the POOLS it ran nowhere at
# all until an image was rebaked, because pool machines are volume-less: their
# run-build.sh and entrypoint come from the BAKED image, which fly-image-build.sh
# bakes from the LIVE hub install. Both halves had to be composed by hand, which
# is what the one-off landing lane did on 2026-09-14. This is that lane, durable.
#
# The daily 05:17Z/05:40Z runs stay exactly as they are: belt and braces for a
# box that was asleep, unreachable or deferred when its merge went past.
#
# ORDER. hub -> boxes -> crontab -> record -> release the lane lock -> bakes.
# The hub syncs FIRST and alone: fly-image-build.sh bakes from the LIVE hub
# install (/root/harness/bin, /root/harness/fly), so a bake that starts before
# the hub's own rsync has finished bakes the OLD code — the failure that rebuilt
# #244 twice from a stale /root/harness/fly (see the fly/ rsync note in
# bin/harness-sync.sh). The boxes do not need the hub: each pulls from origin.
#
# SYNC BEFORE BAKE (BH-6201). The lane lock (locks/fleet-propagate.lock, fd 9)
# covers the sync step only, and it is closed before the first bake, so a slow
# bake never holds the next tick's box sync. The bake step runs under its own
# lock, locks/fleet-propagate-bake.lock (fd 6), which every bake inherits.
#   * A running fly-image-build.sh no longer defers the tick. The bake step
#     checks each pool: a bake of THAT pool already running makes it `busy` (a
#     tolerated skip like debounced: mark kept, no bake, no retry counted).
#   * Bake lock held by an older run: this run bakes nothing, marks its pools
#     dirty at its sha, writes no pool-* file, records bake:"deferred", and its
#     line says images=deferred(<n>). Never a page. A drain tick that finds it
#     held logs `drain deferred: ...` and exits before the hub step.
#   * The sync step writes state/fleet-propagate.json with
#     bake:"pending"|"deferred"|"none" and, with pools to bake, the line
#     `images=pending(<n>)`. The bake step MERGES .pools, .bake, .bake_sha and
#     .bake_finished_at under locks/fleet-propagate-state.lock (fd 5). It never
#     writes .last_sha. The final line keeps its shape and is still the last.
#   * Dirty marks go through fp_mark_dirty / fp_clear_dirty: an older run never
#     removes or overwrites a newer run's mark.
#
# BOX LAG (BH-6201). Each deploy tick, BEFORE the lane lock, compares
# state/fleet-propagate/box-shas.tsv (`<box> <sha> <rc> <epoch>`, rewritten by
# the sync step for the boxes it synced) with the hub checkout HEAD. A box is
# behind when it has no row, its sha is `-`, or it lacks the hub sha AND differs
# from it on a fleet path. state/fleet-propagate/boxes-behind-since holds
# `<epoch> <hub7>` from the first sighting. Past PROPAGATE_BOX_LAG_ALERT_MIN
# minutes: ONE --critical --id fleet-propagate-boxes-behind alert, then
# boxes-behind-alerted. No box behind: one --log-only --resolve, both removed.
#
#   PROPAGATE_BOX_LAG_ALERT_MIN  settings row, default 30. 0 = off. An
#                            unparseable value logs one line and uses 30.
#
# PHASES (BH-6201). Every bake logs `pool <P>: bake phases build=<s>s push=<s>s
# record=<s>s total=<s>s rc=<rc>` (`-` for a phase it never reached), read by
# the watchdog from the bake's own output. The same value is the sixth field of
# the pool result, pools.<p>.phases in the record and phases= in the capture
# header. It measures; it raises no limit.
#
# HONEST PER TARGET. Every box records its rc AND the sha its checkout actually
# landed on; every pool records its status AND, when it failed, why. A partial
# success is never reported as a success — exactly one alert per run:
# --critical when the hub, a box or the crontab failed, or a pool's bake failed
# with no retry left; a failed pool whose retry is queued is one warn-digest
# line (BH-3680; PROPAGATE_PAGE_ON_FIRST_FAIL=1 restores paging on the first
# failure). The page's "Still running the OLD harness:" list names only what is
# really on the old harness: a retrying pool and a cold-warm pool are not in it.
#
# POST-COPY TIMEOUT (BH-7122). The hub step runs bin/harness-sync.sh under
# `timeout $HUB_SYNC_TIMEOUT_S`. harness-sync writes state/harness-sync-phase
# (`copied`, `step=<name>` or `done`, then the sha the copy put live) after its
# code copy and at each step after it. An rc 124 whose stamp proves the copy
# for NEW (that sha, or one that descends from it) keeps hub=ok: the run line
# says `hub=ok(post-copy timeout: <step>)`, the record carries hub_post_copy
# and hub_pending (state/harness-sync-pending/), and the alert is the warn beat
# with the step and the pending deploy steps named. Anything else (no stamp,
# an older or unknown sha, a garbage line, any other rc) is the old fail and
# the CRITICAL page. The cut steps re-run on the next harness-sync.
#
#   HUB_SYNC_TIMEOUT_S       settings row lane.fleet-propagate.hub_sync_timeout_s,
#                            default 300. 0 or not a number logs one line and
#                            uses 300.
#
#   --check   print what WOULD propagate and exit. Writes nothing, ssh's
#             nothing, bakes nothing (a fetch of the checkout is all it does).
#   --force   propagate even when no fleet path changed.
#
# DEBOUNCE. Every bake is a remote Fly build and this lane fires every five
# minutes — eleven merges in eight minutes (2026-09-18) would have meant ten
# builds a tick, indefinitely (how many run AT ONCE is TWO BAKE LANES below).
# So a pool whose image was baked less than POOL_IMAGE_MIN_AGE_MIN minutes ago
# is NOT rebaked: it is recorded `debounced` (a tolerated skip, never a
# --critical) and marked dirty, and the next tick whose window has expired bakes
# it even when nothing new has merged. --force and the nightly
# bin/fly-image-refresh.sh always bake. A bake that returned ok clears the
# mark. A FAILED bake keeps it for a capped retry (BH-3463, RETRY below), and
# once the cap is spent the mark is cleared, so a broken pool is not re-drained
# every five minutes.
#
#   POOL_IMAGE_MIN_AGE_MIN   env/global.env, default 30. 0 = bake on every
#                            propagation, the behaviour before this knob existed.
#                            An unparseable value logs one line and uses 30.
#   state/fly/<project>.baked-at      epoch of the last bake that returned ok
#   state/fly/<project>.image-dirty   the sha a debounce skipped (or a failed
#                                     bake left for its retry), until a bake of
#                                     that pool returns ok or its retries run out
#
# TWO BAKE LANES. The bakes the debounce lets through used to start ALL AT ONCE.
# At 2026-09-20 00:00Z that met a freshly rolled WARM_BUST — every warm layer
# cold on the same tick — and ten full `next build`s went at one Fly builder:
# one OOM'd, five starved past the timeout. So the fan-out is bounded:
#
#   POOL_BAKE_PARALLEL       env/global.env, default 2. The most bakes of pools
#                            whose warm layer is CURRENT that run at once.
#                            0 = unlimited (the behaviour before this knob).
#                            An unparseable value logs one line and uses 2.
#   POOL_BAKE_TIMEOUT_S      per-bake timeout, default 1800. A TEST override
#                            like FLEET_PROPAGATE_PATH; production never sets it.
#
# A pool whose last ok bake is older than the warm bust is cold — its next bake
# pays for the whole checkout + install + build — so it goes in a SERIAL lane,
# one at a time, which runs alongside the capped lane: at most
# POOL_BAKE_PARALLEL+1 remote builds, and never two cold ones. --check names
# the lane per pool. The bust is state/fly/warm-bust (bin/lib/warm-bust.sh):
# the nightly bin/fly-image-refresh.sh rolls it at 05:40Z, so the ticks after
# 00:00Z stay warm. With no valid bust file, cold is "not baked TODAY".
# The refresh holds locks/fleet-propagate-bake.lock (fd 6) while it bakes, so
# a tick in that window defers its pools as it does for any running bake step.
#
# WHY A FAILED BAKE SAYS WHY. That incident's alert said only "failed: project-4
# …" and every cause had to be read out of the out files, so each failure is
# classified — timeout / oom / install / builder / build — in the log line, in
# the alert, and in the record as pools.<p>.{status,reason,warm_sha}. warm_sha
# is the sha fly/warm-bake.sh printed inside the build; empty means the layer
# was reused (or the image baked cold), not that the bake was wrong.
#
# RETRY (BH-3463). A failed bake used to wait for the next merge or the 05:40Z
# nightly. Now it keeps its dirty mark and the drain retries it on the next tick
# whose debounce window has passed — at most POOL_BAKE_RETRY_MAX times per pool
# per UTC day. After that the mark is cleared and the log says when the next
# attempt comes. Each retry is one remote Fly build, which is why it is capped.
#
#   POOL_BAKE_RETRY_MAX      env/global.env or its settings row, default 2.
#                            0 = off: one attempt, the behaviour before BH-3463.
#                            An unparseable value logs one line and uses 2.
#   state/fly/<project>.bake-retries  `<UTC-date> <n>`, retries queued today;
#                                     another date reads as 0, ok removes it
#
# While a pool's retry is queued the run is a --severity warn digest line naming
# it under `retrying:`, not a page (BH-3680); the page comes on the run whose
# failure hits the cap. A retry that then bakes ok logs `pool <p>: ok on retry
# n/N` and says so in that run's success line (same UTC-date rule: a retry that
# lands after 00:00Z loses the label, never the page).
#
#   PROPAGATE_PAGE_ON_FIRST_FAIL  env/global.env or its settings row, default 0.
#                            1 = every failed bake pages --critical, the
#                            behaviour before BH-3680. Anything but 0/1 logs one
#                            line and uses 0 (the cap still pages).
#
# PUSH GRACE (BH-3680). POOL_BAKE_TIMEOUT_S used to kill a bake wherever it was,
# including seconds before `fly deploy` returned the image line — and a pushed
# image that fly-image-build.sh never recorded is not what pools boot. So a bake
# still BUILDING at POOL_BAKE_TIMEOUT_S is killed as before, and one already
# pushing (or past the push, recording its pointer) gets POOL_BAKE_PUSH_GRACE_S
# more before the hard timeout. The log and the capture header name the phase
# the timeout hit.
#
#   POOL_BAKE_PUSH_GRACE_S   env/global.env or its settings row, default 300.
#                            0 = off: one timeout for the whole bake.
#                            An unparseable value logs one line and uses 300.
#
# WARM TIMEOUT (BH-3463). fly/warm-build.sh kills a hung warm `next build` and
# the image still ships, so that bake is ok with pools.<p>.warm = cold (warm =
# the warm build ran OK, empty = the layer was reused or baked cold). A warm
# TIMEOUT, or this lane's own outer timeout (rc 124), writes
# logs/fly-image-build/<project>-<sha7>.log: a header with the bake's elapsed
# time, every BuildKit step line, then the last 200 lines of the build. The
# path is pools.<p>.capture and the alert names it. A clean run with a warm
# timeout is one --severity warn line (the digest), not a --log-only notice.
# Captures older than 14 days are pruned when the next one is written.
#
# CATALOG-ONLY DIFFS REBAKE NOTHING (BH-3463). catalog/ reaches a pool machine
# in the spawn tarball (bin/fly-pool.sh harness_tarball), never through the
# image, so a diff whose fleet paths are all under POOL_EXEMPT_PATHS syncs the
# hub and the boxes and bakes no pool. --force, a drain and a failed diff
# still bake.
set -uo pipefail
H="${HARNESS:-/root/harness}"
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
# BH-2523: the fly_images row, the bake time a fresh hub reads first.
# shellcheck source=bin/lib/fly-image-row.sh
[ -r "$H/bin/lib/fly-image-row.sh" ] && . "$H/bin/lib/fly-image-row.sh" 2>/dev/null
# BH-6710: the warm bust the nightly refresh rolls; pool_cold reads it.
# shellcheck source=bin/lib/warm-bust.sh
. "$H/bin/lib/warm-bust.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/warm-bust.sh" 2>/dev/null || true
# BH-1372: pool check through the routing contract when loaded, the bare file otherwise.
fp_has_pool() { if command -v routing_pool_app >/dev/null 2>&1; then routing_pool_app "$1" >/dev/null 2>&1; else flag_on fly-pool-app "$1"; fi; }
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }
# NOT EXPORTED (#463). This lane fans out over ssh and spawns bakes; exporting
# the root pushed it into every one of those children and anything they in turn
# ran. The two children that need it are handed `HARNESS="$H"` below.
# BH-452's env-dir lookup above keeps its own `${HARNESS:-...}` default, which
# resolves the same value without pushing it into the environment.
# Cron hands this script a stripped PATH and flyctl lives outside it. TESTS
# override the whole thing to reach their stubs; cron never sets it, so
# production resolves exactly the path it always had.
export PATH="${FLEET_PROPAGATE_PATH:-/root/.fly/bin:/usr/local/bin:/usr/bin:/bin}"
# HARNESS_CHECKOUT overrides the checkout path for TESTS only, same contract as
# bin/harness-sync.sh.
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
# fleet-conf.sh prefers /root/harness/fleet.conf; point it at THIS harness's
# registry so a scratch HARNESS (the tests) drives a scratch fleet. Identical in
# production, where the two are the same file.
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
LOG="$H/logs/fleet-propagate.log"
STATE="$H/state/fleet-propagate.json"
WORK="$H/state/fleet-propagate"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

MODE=deploy; FORCE=0
case "${1:-}" in
  --check) MODE=check ;;
  --force) FORCE=1 ;;
  -h|--help) sed -n '/^set -uo pipefail$/q;2,$p' "$0"; exit 0 ;;
  "") ;;
  *) echo "fleet-propagate.sh: unknown flag $1" >&2; exit 2 ;;
esac

# The list of paths that matter to the fleet (BH-5247), shared with
# pipeline-health.sh's drift check. FAIL CLOSED: an empty list would read every
# range as "touches no fleet path — skipped" and advance last_sha past real
# merges, so a missing lib stops the run before it can record anything.
unset FLEET_PATHS   # never an inherited value: only the lib may define it
# shellcheck source=bin/lib/fleet-paths.sh
. "$H/bin/lib/fleet-paths.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/fleet-paths.sh" 2>/dev/null
if [ -z "${FLEET_PATHS:-}" ]; then
  MSG="bin/lib/fleet-paths.sh missing — cannot tell what matters to the fleet, nothing propagated"
  if [ "$MODE" = check ]; then echo "$MSG"
  else mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $MSG" >> "$LOG"; fi
  echo "fleet-propagate.sh: $MSG" >&2
  exit 1
fi


# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fleet-propagate
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fleet-propagate.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
[ "${MODE:-deploy}" = deploy ] && command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fleet-propagate
[ "${MODE:-deploy}" = deploy ] && command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fleet-propagate
# The operator knobs (POOL_IMAGE_MIN_AGE_MIN) live here, and --check has to
# answer with the SAME knob the real run would use, so the sourcing is outside
# the deploy-only block below. The mkdir and the lock stay inside it: --check
# still writes nothing.
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1091
  . "$HENV/global.env"; set +a; fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
[ "${MODE:-deploy}" = deploy ] && command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fleet-propagate

# >>> box lag (BH-6201) — see BOX LAG in the header. It runs BEFORE the lane
# lock, so a run that holds the lock for an hour cannot also hide that the
# boxes are behind (the 2026-10-12 incident).
fp_boxes() { # fp_boxes — every distinct box the registry assigns a project to, the hub excluded
  local P
  while read -r P; do
    [ -n "$P" ] || continue
    "$H/bin/box-for.sh" "$P" 2>/dev/null
  done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null) | grep -v '^local$' | sort -u
}
LAG_MIN="${PROPAGATE_BOX_LAG_ALERT_MIN:-30}"
case "$LAG_MIN" in
  ''|*[!0-9]*)
    MSG="PROPAGATE_BOX_LAG_ALERT_MIN=$LAG_MIN is not a number of minutes — using 30"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $MSG" >> "$LOG"; fi
    LAG_MIN=30 ;;
esac
BOX_SHAS="$WORK/box-shas.tsv"
LAG_SINCE="$WORK/boxes-behind-since"
LAG_ALERTED="$WORK/boxes-behind-alerted"
fp_lag_scan() { # fp_lag_scan — sets LAG_HUB LAG_N LAG_TOTAL LAG_BEHIND; rc 1 = cannot judge
  LAG_HUB=""; LAG_N=0; LAG_TOTAL=0; LAG_BEHIND=""
  [ -f "$BOX_SHAS" ] || return 1
  LAG_HUB=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)
  [ -n "$LAG_HUB" ] || return 1
  local -A ROW=()
  local b s
  while IFS=$'\t' read -r b s _; do
    [ -n "$b" ] && ROW[$b]="$s"
  done < "$BOX_SHAS"
  for b in $(fp_boxes); do
    LAG_TOTAL=$((LAG_TOTAL+1))
    s="${ROW[$b]:-}"
    if [ -n "$s" ] && [ "$s" != - ]; then
      git -C "$CHECKOUT" merge-base --is-ancestor "$LAG_HUB" "$s" 2>/dev/null && continue
      # BH-5247 rule: a lag on non-fleet paths only is not a lag. An unknown
      # sha answers rc 128 here and stays behind.
      # shellcheck disable=SC2086
      git -C "$CHECKOUT" diff --quiet "$s" "$LAG_HUB" -- $FLEET_PATHS 2>/dev/null && continue
    fi
    LAG_N=$((LAG_N+1))
    LAG_BEHIND="$LAG_BEHIND, $b@${s:0:7}"
  done
  LAG_BEHIND="${LAG_BEHIND#, }"
  # An empty registry read (fleet-conf.sh or box-for.sh gave nothing) judged no
  # box, so it can neither resolve the alert nor restart the 30-minute clock.
  [ "$LAG_TOTAL" -gt 0 ] || return 1
  return 0
}
fp_lag_age_min() { # fp_lag_age_min — whole minutes since the first sighting, 0 if none
  local S=""
  read -r S _ 2>/dev/null < "$LAG_SINCE"
  case "$S" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  printf '%s' "$(( ($(date -u +%s) - S) / 60 ))"
}
fp_box_lag() { # fp_box_lag — the deploy-mode check: one alert per episode, one resolve
  [ "$LAG_MIN" = 0 ] && return 0
  exec 7>"$H/locks/fleet-propagate-lag.lock"
  if ! flock -n 7; then exec 7>&-; return 0; fi
  if fp_lag_scan; then
    local NOW_L S="" AGE M
    NOW_L=$(date -u +%s)
    if [ "$LAG_N" -gt 0 ]; then
      [ -f "$LAG_SINCE" ] || echo "$NOW_L ${LAG_HUB:0:7}" > "$LAG_SINCE"
      read -r S _ 2>/dev/null < "$LAG_SINCE"
      case "$S" in ''|*[!0-9]*) S=$NOW_L; echo "$NOW_L ${LAG_HUB:0:7}" > "$LAG_SINCE" ;; esac
      AGE=$((NOW_L - S)); M=$((AGE / 60))
      if [ "$AGE" -gt $((LAG_MIN * 60)) ] && [ ! -f "$LAG_ALERTED" ]; then
        echo "$(STAMP) box lag: $LAG_N/$LAG_TOTAL boxes ${M}m behind the hub at ${LAG_HUB:0:7} ($LAG_BEHIND) — alerted" >> "$LOG"
        "$H/bin/lane-alert.sh" --critical --id fleet-propagate-boxes-behind fleet-propagate \
          "$LAG_N/$LAG_TOTAL boxes are ${M}m behind the hub's synced sha ${LAG_HUB:0:7}: $LAG_BEHIND. Code merged since then has not reached them. See $LOG."
        : > "$LAG_ALERTED"
      fi
    else
      if [ -f "$LAG_ALERTED" ]; then
        M=$(fp_lag_age_min)
        echo "$(STAMP) box lag: all $LAG_TOTAL boxes caught up with the hub at ${LAG_HUB:0:7} after ${M}m" >> "$LOG"
        "$H/bin/lane-alert.sh" --log-only --resolve --id fleet-propagate-boxes-behind fleet-propagate \
          "boxes caught up with the hub at ${LAG_HUB:0:7} after ${M}m"
      fi
      rm -f "$LAG_SINCE" "$LAG_ALERTED" 2>/dev/null
    fi
  fi
  exec 7>&-
}
if [ "$MODE" = check ]; then
  if ! fp_lag_scan; then echo "  box lag: not measured yet (no $BOX_SHAS, or no registry box)"
  elif [ "$LAG_N" -gt 0 ]; then echo "  box lag: $LAG_N behind the hub ($(fp_lag_age_min)m)"
  else echo "  box lag: none"; fi
fi
# <<< box lag

if [ "$MODE" != check ]; then
  mkdir -p "$H/logs" "$H/locks" "$H/state" "$WORK" 2>/dev/null
  fp_box_lag
  # One propagation at a time. A tick that lands on a running one just leaves.
  # The lock covers the SYNC step only: it is released before the first bake
  # (see SYNC BEFORE BAKE in the header).
  exec 9>"$H/locks/fleet-propagate.lock"; flock -n 9 || exit 0
  # >>> BH-1061 wake backstop
  if [ -r "$H/bin/lib/wake-lanes.sh" ]; then
    # shellcheck source=bin/lib/wake-lanes.sh
    . "$H/bin/lib/wake-lanes.sh"
  fi
  if command -v wake_backstop_skip >/dev/null 2>&1 && wake_backstop_skip fleet-propagate fleet 60; then
    exit 0
  fi
  # <<< BH-1061 wake backstop
fi

# FLEET_PATHS: bin/lib/fleet-paths.sh (also read by pipeline-health.sh's drift check, BH-5247).
# Fleet paths that never reach the pool IMAGE (BH-3463). A pool machine gets
# catalog/ from the spawn tarball (bin/fly-pool.sh: harness_tarball ... catalog),
# and fly-image-build.sh's build context is fly/ alone, so a catalog-only diff
# has nothing to rebake. The hub, box and crontab steps still run for it.
# orchestrator/ is the hub's alone (BH-4064), so it never rebakes an image either.
POOL_EXEMPT_PATHS="catalog/ orchestrator/"

is_pool_exempt() { # is_pool_exempt <changed-file>
  local f="$1" p
  for p in $POOL_EXEMPT_PATHS; do
    [ "${f#"$p"}" != "$f" ] && return 0
  done
  return 1
}

is_fleet_path() { # is_fleet_path <changed-file>
  local f="$1" p
  for p in $FLEET_PATHS; do
    case "$p" in
      */) [ "${f#"$p"}" != "$f" ] && return 0 ;;
      *)  [ "$f" = "$p" ] && return 0 ;;
    esac
  done
  return 1
}

# --- 2. what moved -----------------------------------------------------------
[ -d "$CHECKOUT/.git" ] || {
  echo "$(STAMP) no checkout at $CHECKOUT — nothing propagated" >> "$LOG" 2>/dev/null
  echo "no checkout at $CHECKOUT" >&2; exit 1
}
# --check writes NOTHING under $H/state, so its stderr goes nowhere either.
FETCH_ERR="$WORK/fetch.err"; [ "$MODE" = check ] && FETCH_ERR=/dev/null
if ! timeout 60 git -C "$CHECKOUT" fetch -q origin 2>"$FETCH_ERR"; then
  # UNKNOWN, never "nothing to do" (harness-sync.sh's own lesson). Silent for the
  # first hour: a fetch blip must not page every five minutes. Then one alert,
  # because a fetch that stays broken means this lane is blind, not idle.
  [ "$MODE" = check ] && { echo "fetch FAILED — cannot say what would propagate"; exit 1; }
  SINCE_F="$WORK/fetch-fail-since"
  [ -f "$SINCE_F" ] || date -u +%s > "$SINCE_F"
  SINCE=$(cat "$SINCE_F" 2>/dev/null || echo 0)
  AGE=$(( $(date -u +%s) - SINCE ))
  echo "$(STAMP) fetch FAILED (blind for ${AGE}s) — nothing propagated" >> "$LOG"
  if [ "$AGE" -ge 3600 ] && [ ! -f "$WORK/fetch-fail-alerted" ]; then
    : > "$WORK/fetch-fail-alerted"
    "$H/bin/lane-alert.sh" --critical fleet-propagate \
      "git fetch in $CHECKOUT has failed for $((AGE/60))m — no merge to main has reached the fleet since then. The daily 05:17Z sync is the only path left until this is fixed."
  fi
  exit 1
fi
[ "$MODE" = check ] || rm -f "$WORK/fetch-fail-since" "$WORK/fetch-fail-alerted" 2>/dev/null

NEW=$(git -C "$CHECKOUT" rev-parse --verify -q origin/main 2>/dev/null)
[ -n "$NEW" ] || { echo "$(STAMP) origin/main unresolvable — nothing propagated" >> "$LOG" 2>/dev/null; exit 1; }
# Absent state = the checkout's CURRENT head: a first run propagates nothing,
# it just records where the fleet already is. --force overrides that.
STATE_LAST=$(jq -r '.last_sha // empty' "$STATE" 2>/dev/null)
LAST=$STATE_LAST
[ -n "$LAST" ] || LAST=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)

# --- 2b. guard the checkout before any "nothing new" short-circuit -----------
HUB=ok
HUB_REASON=""
HUB_PC=""; HUB_PC_PHASE=""; HUB_PC_SHA=""; HUB_SHOW=""; HUB_PC_NOTE=""; HUB_PENDING=""   # POST-COPY TIMEOUT (BH-7122)
if [ "$MODE" != check ]; then
  # `branch --show-current` prints EMPTY with rc 0 on a detached HEAD, so the
  # `||` fallback never runs there; map empty to HEAD (the same datum
  # bin/harness-sync.sh uses) and let the clean/dirty branches below handle it.
  CUR_BRANCH=$(git -C "$CHECKOUT" branch --show-current 2>/dev/null || git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ -n "$CUR_BRANCH" ] || CUR_BRANCH=HEAD
  if [ "$CUR_BRANCH" != main ]; then
    if [ -z "$(git -C "$CHECKOUT" status --porcelain 2>/dev/null)" ]; then
      INUSE_PID=""
      for _pid in /proc/[0-9]*; do
        [ -d "$_pid" ] || continue
        _pidnum=${_pid#/proc/}
        [ "$_pidnum" = "$$" ] && continue
        [ -r "$_pid/cwd" ] || continue
        _cwdp=$(readlink "$_pid/cwd" 2>/dev/null) || continue
        case "$_cwdp" in
          "$CHECKOUT"|"$CHECKOUT"/*) INUSE_PID="$_pidnum"; break ;;
        esac
      done
      if [ -z "$INUSE_PID" ]; then
        # Log AFTER the checkout succeeds: a line that claimed "forced back"
        # before a failed checkout would leave HUB=ok and the pull failing on
        # the side branch with the log already saying otherwise.
        if git -C "$CHECKOUT" checkout -q main 2>/dev/null; then
          echo "$(STAMP) hub: checkout was on $CUR_BRANCH, forced back to main" >> "$LOG"
        else
          HUB=fail
          HUB_REASON="checkout on $CUR_BRANCH, checkout main failed"
          echo "$(STAMP) hub: checkout on $CUR_BRANCH, checkout main FAILED, refusing" >> "$LOG"
        fi
      else
        HUB=fail
        HUB_REASON="checkout on $CUR_BRANCH, in-use by pid $INUSE_PID"
        echo "$(STAMP) hub: checkout on $CUR_BRANCH (in-use by pid $INUSE_PID), refusing" >> "$LOG"
      fi
    else
      HUB=fail
      HUB_REASON="checkout on $CUR_BRANCH, dirty"
      echo "$(STAMP) hub: checkout on $CUR_BRANCH (dirty), refusing" >> "$LOG"
    fi
  fi
  if [ "$HUB" != ok ]; then
    # A refusal STOPS the tick here. Resetting MATCHED/BOXES/POOLS and falling
    # through was dead code — every later section recomputes them — so a
    # refused tick ssh'd every box and rebaked every due pool at an unchanged
    # sha, every five minutes, until a human reconciled. The record keeps
    # last_sha at LAST (not NEW) so the range this tick missed still propagates
    # once the checkout is back on main; nothing below the guard runs.
    T0=$(STAMP)
    jq -n --arg s "$LAST" --arg t "$T0" --arg hub "$HUB" --arg hub_reason "$HUB_REASON" \
      '{last_sha:$s,started_at:$t,finished_at:$t,hub:$hub,hub_reason:$hub_reason,cron:"not-needed",drain:false,boxes:{},pools:{},changed_paths:[]}' \
      > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    echo "$(STAMP) ${LAST:0:7}..${NEW:0:7} hub=$HUB ($HUB_REASON) — NOT propagated, no box or pool touched" >> "$LOG"
    "$H/bin/lane-alert.sh" --critical fleet-propagate \
      "hub checkout refused ($HUB_REASON) — ${LAST:0:7}..${NEW:0:7} was NOT propagated: no box synced, no pool image rebaked. The reconcile is not automated on purpose; see $LOG."
    exit 0
  fi
  [ -z "$STATE_LAST" ] && LAST=$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)
fi

# --- the bake debounce (see DEBOUNCE in the header) --------------------------
FLY_STATE="$H/state/fly"
NOW_S=$(date -u +%s)
MIN_AGE_MIN="${POOL_IMAGE_MIN_AGE_MIN:-30}"
case "$MIN_AGE_MIN" in
  ''|*[!0-9]*)
    # Never silently: a typo that restored the ten-way bake on every merge is
    # the exact cost this knob exists to stop, so it falls back to the default
    # and says which value it refused.
    MSG="POOL_IMAGE_MIN_AGE_MIN=$MIN_AGE_MIN is not a number of minutes — using 30"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    MIN_AGE_MIN=30 ;;
esac

# The fan-out cap (see TWO BAKE LANES in the header). Same shape as the knob
# above, and read outside the deploy-only block for the same reason: --check has
# to answer with the value the real run would use.
BAKE_PAR="${POOL_BAKE_PARALLEL:-2}"
case "$BAKE_PAR" in
  ''|*[!0-9]*)
    MSG="POOL_BAKE_PARALLEL=$BAKE_PAR is not a number of bakes — using 2"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    BAKE_PAR=2 ;;
esac
BAKE_TIMEOUT_S="${POOL_BAKE_TIMEOUT_S:-1800}"
case "$BAKE_TIMEOUT_S" in
  ''|*[!0-9]*|0)
    MSG="POOL_BAKE_TIMEOUT_S=$BAKE_TIMEOUT_S is not a number of seconds — using 1800"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    BAKE_TIMEOUT_S=1800 ;;
esac
# The capped retry of a failed bake (see RETRY in the header).
RETRY_MAX="${POOL_BAKE_RETRY_MAX:-2}"
case "$RETRY_MAX" in
  ''|*[!0-9]*)
    MSG="POOL_BAKE_RETRY_MAX=$RETRY_MAX is not a number of retries — using 2"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    RETRY_MAX=2 ;;
esac
# BH-3680: 1 pages --critical on the first failed bake even with a retry queued.
PAGE_FIRST="${PROPAGATE_PAGE_ON_FIRST_FAIL:-0}"
case "$PAGE_FIRST" in
  0|1) ;;
  *)
    # 0 cannot lose a page: a pool whose retries run out still pages.
    MSG="PROPAGATE_PAGE_ON_FIRST_FAIL=$PAGE_FIRST is not 0 or 1 — using 0"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    PAGE_FIRST=0 ;;
esac
# BH-3680: the margin a bake already pushing gets past BAKE_TIMEOUT_S (PUSH GRACE).
PUSH_GRACE_S="${POOL_BAKE_PUSH_GRACE_S:-300}"
case "$PUSH_GRACE_S" in
  ''|*[!0-9]*)
    MSG="POOL_BAKE_PUSH_GRACE_S=$PUSH_GRACE_S is not a number of seconds — using 300"
    if [ "$MODE" = check ]; then echo "  warning: $MSG"; else echo "$(STAMP) $MSG" >> "$LOG"; fi
    PUSH_GRACE_S=300 ;;
esac
TODAY=$(date -u +%F)

stamp_of() { # stamp_of <project> — epoch of its last ok bake, empty if unusable
  local S=""
  # BH-2523: the fly_images row first, so a hub with no state/fly/ reads the
  # bake the fleet already has; the file when the row gives no usable time
  # (none, off, worker down, not a number, in the future).
  if declare -F fir_baked_at >/dev/null 2>&1; then
    S=$(fir_baked_at "$1" 2>/dev/null) || S=""
    case "$S" in ''|*[!0-9]*) S="" ;; *) [ "$S" -gt "$NOW_S" ] && S="" ;; esac
  fi
  [ -n "$S" ] || S=$(cat "$FLY_STATE/$1.baked-at" 2>/dev/null)
  case "$S" in ''|*[!0-9]*) return 0 ;; esac
  # A stamp in the future (clock skew, a hand-edited file) must not suppress
  # bakes until it passes. Unusable is treated as absent, and absent is not fresh.
  [ "$S" -gt "$NOW_S" ] && return 0
  printf '%s' "$S"
}

pool_due() { # pool_due <project> — true when this run should bake it
  # One fly_images GET per pool per run, in THIS shell, so every $(stamp_of)
  # after it reads the memo instead of asking again.
  declare -F fir_load >/dev/null 2>&1 && { fir_load "$1" >/dev/null 2>&1 || true; }
  [ "$FORCE" = 1 ] && return 0
  [ "$MIN_AGE_MIN" = 0 ] && return 0
  local S; S=$(stamp_of "$1")
  [ -n "$S" ] || return 0
  [ "$(( NOW_S - S ))" -ge "$(( MIN_AGE_MIN * 60 ))" ]
}

pool_bake_date() { # pool_bake_date <project> — UTC date of its last ok bake, or never
  local S; S=$(stamp_of "$1")
  [ -n "$S" ] || { printf '%s' never; return 0; }
  printf '%s' "$(date -u -d "@$S" +%F 2>/dev/null || printf '%s' never)"
}

pool_cold() { # pool_cold <project> — true when its warm layer is not the current bust's
  # fly-image-build.sh passes the date in state/fly/warm-bust as WARM_BUST, and
  # bin/fly-image-refresh.sh rolls that file when it starts (BH-6710). So a
  # layer baked before the bust epoch is rebuilt from scratch: checkout,
  # install, build. With no valid bust file the build passes $(date -u +%F),
  # and a layer baked on any earlier date is cold. Absent or unusable is cold —
  # the conservative side, same as the debounce's.
  local B S
  if declare -F warm_bust_read >/dev/null 2>&1 && read -r _ B < <(warm_bust_read "$FLY_STATE" "$NOW_S"); then
    S=$(stamp_of "$1")
    [ -z "$S" ] || [ "$S" -lt "$B" ]
    return
  fi
  [ "$(pool_bake_date "$1")" != "$TODAY" ]
}

pool_age_min() { # pool_age_min <project> — whole minutes since its last ok bake
  local S; S=$(stamp_of "$1")
  [ -n "$S" ] || { printf '%s' '?'; return 0; }
  printf '%s' "$(( (NOW_S - S) / 60 ))"
}

# >>> dirty-marker (BH-6201)
# Two runs can now overlap: a newer run syncs the boxes while an older one still
# bakes. So a dirty mark is never written or removed blind: a mark NEWER than
# the sha at hand stays. Every real mark is a sha this checkout fetched, so a
# mark it does not know is stale (a force-push, a hand edit). A new mark never
# replaces it, and a finished bake removes it: unknown costs one extra bake,
# never a stale image and never a bake every window.
fp_mark_dirty() { # fp_mark_dirty <project> <sha>
  local F="$FLY_STATE/$1.image-dirty" CUR=""
  mkdir -p "$FLY_STATE" 2>/dev/null
  read -r CUR 2>/dev/null < "$F"
  if [ -n "$CUR" ] && [ "$CUR" != "$2" ]; then
    git -C "$CHECKOUT" cat-file -e "$CUR^{commit}" 2>/dev/null || return 0
    git -C "$CHECKOUT" merge-base --is-ancestor "$2" "$CUR" 2>/dev/null && return 0
  fi
  echo "$2" > "$F"
}
fp_clear_dirty() { # fp_clear_dirty <project> <sha> — a mark at <sha>, older, or unknown
  local F="$FLY_STATE/$1.image-dirty" CUR=""
  [ -f "$F" ] || return 0
  read -r CUR 2>/dev/null < "$F"
  if [ -z "$CUR" ] || [ "$CUR" = "$2" ] \
     || ! git -C "$CHECKOUT" cat-file -e "$CUR^{commit}" 2>/dev/null \
     || git -C "$CHECKOUT" merge-base --is-ancestor "$CUR" "$2" 2>/dev/null; then
    rm -f "$F" 2>/dev/null
  fi
  return 0
}
# <<< dirty-marker

# A pool debounced earlier waits in state, not in memory. When nothing new has
# merged, a tick still runs if some pool's window has expired — otherwise a skip
# would leave that pool on a stale image until the next merge or 05:40Z.
DRAIN=""; DRAIN_MODE=0
if [ "$HUB" = ok ] && [ "$NEW" = "$LAST" ] && [ "$FORCE" = 0 ]; then
  for F in "$FLY_STATE"/*.image-dirty; do
    [ -f "$F" ] || continue
    P=$(basename "$F" .image-dirty)
    if ! fp_has_pool "$P"; then
      # The project no longer has a pool; the marker has nothing left to bake.
      [ "$MODE" = check ] || rm -f "$F" 2>/dev/null
      continue
    fi
    pool_due "$P" && DRAIN="$DRAIN $P"
  done
  DRAIN="${DRAIN# }"
  if [ -z "$DRAIN" ]; then
    [ "$MODE" = check ] && echo "up to date at ${NEW:0:7} — nothing would propagate"
    exit 0
  fi
  DRAIN_MODE=1
fi

# --- 3. does it matter to the fleet? -----------------------------------------
DIFF_RC=0
CHANGED=$(git -C "$CHECKOUT" diff --name-only "$LAST..$NEW" 2>/dev/null) || DIFF_RC=$?
MATCHED=""
if [ "$DIFF_RC" != 0 ]; then
  # A force-push or a pruned object makes the range unanswerable. Unknown is not
  # "nothing changed" — propagate and say why.
  MATCHED="(diff-failed)"
  echo "$(STAMP) diff $LAST..$NEW failed (force-push? pruned object?) — propagating blind" >> "$LOG" 2>/dev/null
else
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    is_fleet_path "$F" && MATCHED="$MATCHED$F"$'\n'
  done <<<"$CHANGED"
  MATCHED="${MATCHED%$'\n'}"
fi
# A drain has no range of its own (NEW = LAST), so it names itself. It matches
# neither cron/ nor fleet.conf, so it never re-renders the crontab.
[ "$DRAIN_MODE" = 1 ] && MATCHED="(dirty-drain)"
# Which matched paths reach a pool image. Only a clean diff can say "none": a
# drain, --force and a failed diff bake as before.
NO_IMAGE_INPUT=0
if [ "$DIFF_RC" = 0 ] && [ "$DRAIN_MODE" = 0 ] && [ "$FORCE" = 0 ] && [ -n "$MATCHED" ]; then
  IMAGE_MATCHED=""
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    is_pool_exempt "$F" || IMAGE_MATCHED="$IMAGE_MATCHED$F"$'\n'
  done <<<"$MATCHED"
  [ -z "$IMAGE_MATCHED" ] && NO_IMAGE_INPUT=1
fi

# --- who the targets are (registry only; never a hand-typed list) ------------
# Boxes: every distinct box the registry assigns a project to. A PARKED box is a
# commented-out row, so --projects already excludes it. "local" is the hub, which
# target (a) below already covers.
BOXES=$(fp_boxes)   # the same list the box-lag check reads (BH-6201)
# Pools: a project has a pool exactly when flags/fly-pool-app-<project> names its
# dedicated app (bin/fly-pool.sh refuses to spawn without it).
# BH-1372: a row-only enrollment has no file until synced, and the glob below
# would skip its pool. One sync per tick; an outage leaves the files as they are.
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
# BH-1627: the glob lists candidates and fp_has_pool decides, so the two can
# never disagree. With the client, an EMPTY app file is no pool (routing_pool_app,
# and bin/fly-pool.sh spawns nothing for it); after the sync above that answer
# costs no request.
POOLS=$(for F in "$H"/flags/fly-pool-app-*; do
          [ -f "$F" ] || continue
          fp_has_pool "${F##*/fly-pool-app-}" || continue
          echo "${F##*/fly-pool-app-}"
        done | sort -u)

# Split the pools this run considers into the ones it bakes and the ones that
# are still inside their window. A drain bakes exactly the dirty pools and does
# NOT re-sync the boxes: they already hold this sha, and ssh'ing ten of them per
# drain would move the cost the debounce just saved one lane over.
POOL_SKIP=""
if [ "$DRAIN_MODE" = 1 ]; then
  BOXES=""
  POOLS="$DRAIN"
elif [ "$MODE" != check ]; then
  POOL_BAKE=""
  for P in $POOLS; do
    if pool_due "$P"; then POOL_BAKE="$POOL_BAKE$P"$'\n'; else POOL_SKIP="$POOL_SKIP $P"; fi
  done
  POOLS="${POOL_BAKE%$'\n'}"
  POOL_SKIP="${POOL_SKIP# }"
fi
# Nothing the image is built from moved: no pool is baked, debounced or marked.
[ "$NO_IMAGE_INPUT" = 1 ] && { POOLS=""; POOL_SKIP=""; }

if [ "$MODE" = check ]; then
  echo "fleet-propagate --check"
  echo "  last:    ${LAST:0:7}"
  echo "  new:     ${NEW:0:7}"
  if [ "$DRAIN_MODE" = 1 ]; then
    echo "  changed: nothing new — would drain the pools debounced earlier"
    echo "  hub:     git pull --ff-only + bin/harness-sync.sh"
    echo "  boxes:   none (they already hold ${NEW:0:7})"
    echo "  pools:   $DRAIN"
    echo "  crontab: not needed"
    exit 0
  fi
  if [ -z "$MATCHED" ]; then
    echo "  changed: no fleet path touched — would record last_sha and skip"
    echo "  (--force would propagate anyway)"
    exit 0
  fi
  echo "  changed (fleet paths):"; printf '    %s\n' $MATCHED
  echo "  hub:     git pull --ff-only + bin/harness-sync.sh"
  echo "  boxes:   $(echo "$BOXES" | tr '\n' ' ')"
  if [ "$NO_IMAGE_INPUT" = 1 ]; then echo "  pools:   none (no image input changed)"; else echo "  pools:"; fi
  for P in $POOLS; do
    if pool_due "$P"; then
      if pool_cold "$P"; then echo "    $P: bake (cold, serial lane)"; else echo "    $P: bake"; fi
    else echo "    $P: debounced ($(pool_age_min "$P")m old, under ${MIN_AGE_MIN}m)"; fi
  done
  case "$MATCHED" in
    *cron/*|*fleet.conf*|*"(diff-failed)"*) echo "  crontab: render + install (a crontab input moved)" ;;
    *)                                      echo "  crontab: not needed" ;;
  esac
  exit 0
fi

if [ "$HUB" = ok ] && [ -z "$MATCHED" ] && [ "$FORCE" = 0 ]; then
  jq -n --arg s "$NEW" --arg t "$(STAMP)" \
    '{last_sha:$s,started_at:$t,finished_at:$t,skipped:true,hub:"skipped",hub_reason:"",boxes:{},pools:{},changed_paths:[]}' \
    > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  echo "$(STAMP) ${LAST:0:7}..${NEW:0:7} touches no fleet path — skipped" >> "$LOG"
  exit 0
fi

if [ "$HUB" = ok ]; then
  # --- 8. never pile on a hub sync that is already running ---------------------
  # A running BAKE no longer defers the tick (BH-6201): the boxes never wait on
  # an image. The bake step checks each pool for a bake of its own (`busy`).
  lock_busy() { # lock_busy <lockfile> — true when someone else holds it
    # fd 8, not 9: fd 9 is this run's own propagate lock, and the probe runs in a
    # subshell that inherits it.
    [ -e "$1" ] || return 1
    ( exec 8>>"$1"; flock -n 8 ) 2>/dev/null && return 1
    return 0
  }
  DEFER=""
  lock_busy "$H/locks/harness-sync.lock" && DEFER="harness-sync.lock held"
  if [ -n "$DEFER" ]; then
    echo "$(STAMP) DEFERRED ($DEFER) — ${NEW:0:7} not propagated this tick, next tick retries" >> "$LOG"
    exit 0
  fi
fi

# --- the bake lock (see SYNC BEFORE BAKE in the header) ----------------------
# fd 6, held by the bake step and every bake it starts. Dedupe, never a queue:
# a run that finds it held does not bake.
BAKE_HELD=0
fp_take_bake_lock() {
  exec 6>"$H/locks/fleet-propagate-bake.lock"
  if flock -n 6; then BAKE_HELD=1; return 0; fi
  exec 6>&-; return 1
}
# A drain only bakes, so a drain that cannot bake has nothing to do: it leaves
# BEFORE the hub step, and the marks stay for the next tick.
if [ "$DRAIN_MODE" = 1 ] && ! fp_take_bake_lock; then
  echo "$(STAMP) drain deferred: a bake step is running ($DRAIN)" >> "$LOG"
  exit 0
fi

# --- 4. propagate ------------------------------------------------------------
STARTED=$(STAMP)
# The pool-* files belong to the bake step; a run that overlaps one must not
# delete them.
rm -f "$WORK"/box-*.result 2>/dev/null
if [ "$NO_IMAGE_INPUT" = 1 ]; then
  NOIMG_PATHS=$(printf '%s' "$MATCHED" | tr '\n' ',')
  echo "$(STAMP) pools: no image input changed (${NOIMG_PATHS:0:200}) — no pool rebaked" >> "$LOG"
fi

# >>> pool-first-fail
# `fail` on its own sent an operator to a pool-<P>.out that the next tick
# overwrites. The log now carries the line that says WHY (BH-806: 10 pools
# failed for 11 hours on "FATAL: apps create failed" and the record said 0/10).
pool_first_fail() { # pool_first_fail <pool-P.out> — the first line that says why, else the last non-empty one
  local f="$1" line
  line=$(grep -m1 -iE '^(FATAL|Error|WARN: apps list failed)|error:|failed|timed out|Terminated' "$f" 2>/dev/null)
  [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1)
  # `| head -c 300` is an early-exit pipeline under the set -o pipefail above:
  # head closes the pipe at 300 bytes and printf takes the SIGPIPE, so this
  # helper returned 141 on any longer line. Cap in the shell instead.
  line="${line:-(no output)}"; printf '%s' "${line:0:300}"
}
# <<< pool-first-fail

# >>> post-copy timeout (BH-7122) — see POST-COPY TIMEOUT in the header.
# fp_hub_post_copy <new-sha> — rc 0 only when state/harness-sync-phase proves
# the hub's code copy for <new-sha>: phase copied, step=<name> or done, and a
# stamp sha that is <new-sha> or descends from it. Sets HUB_PC (the step label,
# `step=` stripped), HUB_PC_PHASE and HUB_PC_SHA. No stamp, a garbage line, an
# older sha or a sha this checkout does not know: rc 1 (fail closed).
fp_hub_post_copy() {
  local ph="" sha="" _ts=""
  read -r ph sha _ts < "$H/state/harness-sync-phase" 2>/dev/null || return 1
  [[ "$ph" =~ ^(copied|done|step=[a-z0-9-]+)$ ]] || return 1
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [ "$sha" != "$1" ]; then
    git -C "$CHECKOUT" cat-file -e "$sha^{commit}" 2>/dev/null || return 1
    git -C "$CHECKOUT" merge-base --is-ancestor "$1" "$sha" 2>/dev/null || return 1
  fi
  HUB_PC="${ph#step=}"; HUB_PC_PHASE="$ph"; HUB_PC_SHA="$sha"
  return 0
}
# fp_hub_pending — the hub's pending deploy steps (state/harness-sync-pending/,
# written by bin/lib/harness-sync-step.sh), one name per line.
fp_hub_pending() {
  local f
  for f in "$H/state/harness-sync-pending"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done
  return 0
}
# <<< post-copy timeout

# a. the hub, first and alone (see ORDER in the header).
if [ "$HUB" = ok ] && ! timeout 120 git -C "$CHECKOUT" pull --ff-only -q origin main >"$WORK/hub.out" 2>&1; then
  HUB=fail
  CUR_BRANCH=$(git -C "$CHECKOUT" branch --show-current 2>/dev/null || git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD 2>/dev/null)
  AHEAD=$(git -C "$CHECKOUT" rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
  BEHIND=$(git -C "$CHECKOUT" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
  FIRST_ERR=$(head -n 1 "$WORK/hub.out" 2>/dev/null)
  HUB_REASON="checkout on ${CUR_BRANCH:-?}, ahead $AHEAD / behind $BEHIND: $FIRST_ERR"
  echo "$(STAMP) hub: git pull --ff-only FAILED ($HUB_REASON)" >> "$LOG"
elif [ "$HUB" = ok ]; then
  SYNC_RC=0
  HUB_SYNC_TO="${HUB_SYNC_TIMEOUT_S:-300}"
  case "$HUB_SYNC_TO" in
    0|*[!0-9]*) echo "$(STAMP) HUB_SYNC_TIMEOUT_S=${HUB_SYNC_TO:0:40} is not a number of seconds — using 300" >> "$LOG"; HUB_SYNC_TO=300 ;;
  esac
  HARNESS="$H" timeout "$HUB_SYNC_TO" "$H/bin/harness-sync.sh" >>"$WORK/hub.out" 2>&1 || SYNC_RC=$?
  # harness-sync's exit codes are a classification, not noise. 30 = diverged or
  # locally dirty, which it REFUSES to force-reset: a human owns that reconcile,
  # so it is a FAIL and never a retry. 20 = unknown, also a fail. 124 = our
  # timeout: ok when the phase stamp proves the code copy for NEW (BH-7122).
  if [ "$SYNC_RC" = 124 ] && fp_hub_post_copy "$NEW"; then
    HUB_SHOW="ok(post-copy timeout: $HUB_PC)"
    echo "$(STAMP) hub: harness-sync rc=124 after the code copy (phase $HUB_PC_PHASE ${HUB_PC_SHA:0:7}), step $HUB_PC — counted ok" >> "$LOG"
  elif [ "$SYNC_RC" != 0 ]; then
    HUB="fail(harness-sync rc=$SYNC_RC)"; HUB_REASON="harness-sync rc=$SYNC_RC"; echo "$(STAMP) hub: harness-sync rc=$SYNC_RC" >> "$LOG"
  fi
fi
HUB_PENDING=$(fp_hub_pending)
if [ -n "$HUB_PC" ]; then
  HUB_PC_NOTE=" The hub sync timed out after the code copy, in step $HUB_PC; live bin/ is at ${HUB_PC_SHA:0:7}. Pending deploy steps: $(printf '%s' "${HUB_PENDING:-none}" | tr '\n' ' ' | sed 's/ /, /g'). They re-run on the next harness-sync (next fleet-path merge or 05:17Z update-runners)."
fi

# b. boxes, in parallel. ssh -n inside the loop: without it the first ssh eats
# the loop's stdin and the rest of the boxes are silently skipped.
BOX_PIDS=()
for B in $BOXES; do
  (
    IP=$("$H/bin/fleet-conf.sh" --tailnet-ip-of-box "$B" 2>/dev/null)
    if [ -z "$IP" ]; then
      # Fail CLOSED: an empty target is `root@`, which hangs rather than errors.
      echo "rc=255 sha=- note=no-address" > "$WORK/box-$B.result"; exit 0
    fi
    RC=0
    SHA=$(timeout 660 ssh -n -o BatchMode=yes -o ConnectTimeout=15 "root@$IP" \
      'timeout 600 /root/harness/bin/update-runners.sh >/dev/null 2>&1; RC=$?; git -C /root/harness-checkout rev-parse HEAD 2>/dev/null; exit $RC' \
      2>"$WORK/box-$B.err") || RC=$?
    echo "rc=$RC sha=${SHA:--}" > "$WORK/box-$B.result"
  ) &
  BOX_PIDS+=("$!")
done
# The boxes only: no bake has started yet, and none ever holds this wait.
[ "${#BOX_PIDS[@]}" -gt 0 ] && wait "${BOX_PIDS[@]}"

# d. the hub crontab. bin/update-runners.sh owns the full version of this (render
# + drift guard + apply); running the whole of it here would re-run cli-update.sh
# every five minutes, so this is the render and the guard that matters: a render
# that FAILS or comes back EMPTY installs nothing, and a render that would DROP a
# live triage lane is refused — the 2026-08-30 project-7 wipe.
#
# ONLY when a crontab INPUT moved (cron/ or fleet.conf). The render's base is the
# repo's cron/<box>.cron, not the live crontab, so installing it drops any line
# somebody added live and never committed (2026-09-07: the hand-added orc-monitor
# line went exactly that way). The daily tick already re-asserts the repo's
# version; there is no reason to re-assert it every five minutes for a change
# that cannot have altered it.
CRON=not-needed
CRON_NEEDED=0
# catalog/lanes.d/ joins the list (BH-1247): the registry says WHICH lanes a box
# runs, so a lane file that moved changes this box's crontab exactly as a
# cron/ fragment does — and since the render is no longer committed, a
# catalog-only change would otherwise reach the box with nothing re-installed.
case "$MATCHED" in *cron/*|*fleet.conf*|*catalog/lanes.d*|*"(diff-failed)"*) CRON_NEEDED=1 ;; esac
[ "$FORCE" = 1 ] && CRON_NEEDED=1
BOX_ID=$(tr -dc 'a-z0-9-' < "$H/state/box-id" 2>/dev/null); BOX_ID="${BOX_ID:-hub}"
if [ "$CRON_NEEDED" = 0 ]; then
  :
elif [ ! -x "$CHECKOUT/bin/render-crontab.sh" ] \
     || { [ ! -f "$CHECKOUT/cron/$BOX_ID.cron" ] && [ ! -x "$CHECKOUT/bin/render-cron.sh" ]; }; then
  # cron/<box>.cron is GENERATED and no longer committed (BH-1247), so its
  # ABSENCE is the normal state of a fresh checkout and must not skip the
  # install. What would make the install impossible is having neither the file
  # nor the renderer that produces it; render-crontab.sh renders the base and
  # fails closed on its own, so every guard below is reached as before.
  CRON=skipped
else
  R_RC=0
  RENDERED=$("$CHECKOUT/bin/render-crontab.sh" --root "$CHECKOUT" "$BOX_ID" 2>>"$WORK/cron.err") || R_RC=$?
  LIVE=$(crontab -l 2>/dev/null)
  if [ "$R_RC" != 0 ] || [ -z "$RENDERED" ]; then
    CRON="render-failed"
  elif [ "$LIVE" = "$RENDERED" ]; then
    CRON=current
  elif [ -n "$(comm -23 <(grep -o 'run-triage\.sh [a-z0-9-]*' <<<"$LIVE" | sort -u) \
                        <(grep -o 'run-triage\.sh [a-z0-9-]*' <<<"$RENDERED" | sort -u))" ]; then
    CRON="refused-would-drop-a-live-lane"
  else
    printf '%s\n' "$RENDERED" > "$WORK/crontab.new"
    if crontab "$WORK/crontab.new" 2>>"$WORK/cron.err"; then CRON=installed; else CRON="install-failed"; fi
  fi
fi

# --- 5. the sync record ------------------------------------------------------
BOX_ROWS=""; BOX_OK=0; BOX_BAD=""
for F in "$WORK"/box-*.result; do
  [ -e "$F" ] || continue
  B=$(basename "$F" .result); B="${B#box-}"
  RC=$(sed -n 's/.*rc=\([^ ]*\).*/\1/p' "$F"); SHA=$(sed -n 's/.*sha=\([^ ]*\).*/\1/p' "$F")
  BOX_ROWS="$BOX_ROWS$B"$'\t'"${RC:-255}"$'\t'"${SHA:--}"$'\n'
  if [ "${RC:-255}" = 0 ]; then BOX_OK=$((BOX_OK+1)); else BOX_BAD="$BOX_BAD $B(rc=${RC:-255})"; fi
done
# box-shas.tsv (BH-6201): what the box-lag check reads. This tick's boxes
# replace their own rows; a box not synced this tick keeps its row, so a drain
# never makes the boxes look current.
if [ -n "$BOX_ROWS" ]; then
  NOW_E=$(date -u +%s)
  {
    if [ -f "$BOX_SHAS" ]; then
      while IFS=$'\t' read -r B SHA RC EP; do
        [ -n "$B" ] && [ ! -e "$WORK/box-$B.result" ] && printf '%s\t%s\t%s\t%s\n' "$B" "$SHA" "$RC" "$EP"
      done < "$BOX_SHAS"
    fi
    printf '%s' "$BOX_ROWS" | while IFS=$'\t' read -r B RC SHA; do
      printf '%s\t%s\t%s\t%s\n' "$B" "$SHA" "$RC" "$NOW_E"
    done
  } | sort > "$BOX_SHAS.tmp" && mv "$BOX_SHAS.tmp" "$BOX_SHAS"
fi
BOX_N=$(printf '%s' "$BOX_ROWS" | grep -c . || true)
BOXES_JSON=$(printf '%s' "$BOX_ROWS" | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))
              |map({(.[0]):{rc:((.[1]|tonumber?) // .[1]),sha:.[2]}})|add // {}')
PATHS_JSON=$(printf '%s' "$MATCHED" | jq -R -s 'split("\n")|map(select(length>0))')
DRAIN_JSON=false; [ "$DRAIN_MODE" = 1 ] && DRAIN_JSON=true

# Who bakes. none: no pool to bake or debounce. pending: this run holds the
# bake lock. deferred: an older run's bake step holds it, so this run marks its
# pools dirty at NEW, writes no pool-* file and bakes nothing.
BAKE=none; DEFER_N=0; DEFER_JSON="{}"
if [ -n "$POOLS$POOL_SKIP" ]; then
  if [ "$BAKE_HELD" = 1 ] || fp_take_bake_lock; then
    BAKE=pending
  else
    BAKE=deferred
    for P in $POOLS $POOL_SKIP; do
      fp_mark_dirty "$P" "$NEW"
      DEFER_N=$((DEFER_N+1))
    done
    DEFER_JSON=$(printf '%s\n' $POOLS $POOL_SKIP | jq -R -s 'split("\n")|map(select(length>0))|map({(.):{status:"deferred"}})|add // {}')
    echo "$(STAMP) pools: a bake step is already running — $DEFER_N pool images deferred, marked dirty at ${NEW:0:7}" >> "$LOG"
  fi
fi

# The record is written under the state lock (fd 5), which the bake step's
# merge takes too, and BEFORE the lane lock goes: the next tick reads last_sha.
STATE_LOCK="$H/locks/fleet-propagate-state.lock"
exec 5>"$STATE_LOCK"
flock -w 30 5 || echo "$(STAMP) state lock busy for 30s — writing the sync record anyway" >> "$LOG"
jq -n --arg s "$NEW" --arg a "$STARTED" --arg b "$(STAMP)" --arg hub "$HUB" --arg cron "$CRON" --arg hub_reason "$HUB_REASON" \
      --argjson boxes "$BOXES_JSON" --argjson pools "$DEFER_JSON" --argjson paths "$PATHS_JSON" \
      --argjson drain "$DRAIN_JSON" --arg bake "$BAKE" --arg hub_pc "$HUB_PC" --arg hub_pending "$HUB_PENDING" \
  '{last_sha:$s,started_at:$a,finished_at:$b,hub:$hub,hub_reason:$hub_reason,cron:$cron,drain:$drain,boxes:$boxes,pools:$pools,changed_paths:$paths,bake:$bake,hub_post_copy:$hub_pc,hub_pending:($hub_pending|split("\n")|map(select(length>0)))}' \
  > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
exec 5>&-

# The sync step ends here. The lane lock goes BEFORE the first bake, so the
# next tick can sync the boxes while this run's bakes run (fd 6 stays).
exec 9>&-
POOL_N_PENDING=$(printf '%s\n' $POOLS | grep -c . || true)
if [ "$BAKE" = pending ] && [ "$POOL_N_PENDING" -gt 0 ]; then
  echo "$(STAMP) ${LAST:0:7}..${NEW:0:7} hub=${HUB_SHOW:-$HUB} boxes=$BOX_OK/$BOX_N images=pending($POOL_N_PENDING) cron=$CRON paths=$(printf '%s' "$MATCHED" | tr '\n' ',' | head -c 200)" >> "$LOG"
fi

# c. pool images, in two lanes. fly-image-build.sh needs no serialization for
# CORRECTNESS: each build pushes to its OWN app registry, and its image-ref
# state write greps the shared log for ITS app only (the 2026-08-25 TK-1175
# fix), so concurrent bakes cannot hand a project another project's image. The
# bound below is about the shared RESOURCE — one Fly remote builder, one pool of
# memory — not about the data (see TWO BAKE LANES in the header).
bake_reason() { # bake_reason <rc> <outfile> — why a failed bake failed, one word
  # Called only for a non-zero rc: an ok bake never carries a reason, whatever
  # its output says. Narrow, anchored patterns and a stated precedence, because
  # this word is what the operator reads at 00:00Z instead of the out file.
  local RC="$1" F="$2"
  [ "$RC" = 124 ] && { printf '%s' timeout; return 0; }   # killed by OUR timeout
  grep -qE 'exit code:? 137([^0-9]|$)' "$F" 2>/dev/null && { printf '%s' oom; return 0; }
  grep -qE 'npm (ERR!|error) code (EUSAGE|ERESOLVE)|ERR_PNPM_OUTDATED_LOCKFILE|from lock file' "$F" 2>/dev/null \
    && { printf '%s' install; return 0; }
  grep -qE 'deadline_exceeded|releas(e|ing) (the )?builder|creat(e|ing) (the )?builder' "$F" 2>/dev/null \
    && { printf '%s' builder; return 0; }
  printf '%s' build
}

warm_sha_of() { # warm_sha_of <outfile> — the sha warm-bake.sh installed against
  # Empty when the layer was reused (the RUN did not re-execute) or the image
  # baked cold. Read after the rc is known; it never influences the status.
  grep -oE 'warm-bake: repo sha [0-9a-f]{40}' "$1" 2>/dev/null | tail -1 | awk '{print $NF}'
}

# BH-3463: the line fly/warm-build.sh prints when it killed the warm build. The
# optional prefix is BuildKit's `#<step> <seconds> `; anything else on the line
# before it (a test log saying "TIMED OUT", next's own page timeout) is not it.
WARM_TIMEOUT_RE='^(#[0-9]+ [0-9.]+ )?warm-build: TIMED OUT after [0-9]+s'
warm_of() { # warm_of <outfile> — cold | warm | empty (layer reused, or no warm bake)
  if grep -qE "$WARM_TIMEOUT_RE" "$1" 2>/dev/null \
     || grep -qE '^(#[0-9]+ [0-9.]+ )?warm build FAILED' "$1" 2>/dev/null; then
    printf '%s' cold
  elif grep -qE '^(#[0-9]+ [0-9.]+ )?warm build OK' "$1" 2>/dev/null; then
    printf '%s' warm
  fi
}

bake_phase() { # bake_phase <outfile> — build | push | record: how far a bake got
  # record: fly deploy printed the image line fly-image-build.sh parses, so the
  # push is over and only the pointer write is left. push: BuildKit is
  # exporting or pushing the image. Anything else is still building.
  if grep -qE '^image: registry\.fly\.io/' "$1" 2>/dev/null; then
    printf '%s' record
  elif grep -qE '^(#[0-9]+ ([0-9.]+ )?)?(pushing (layers?|manifest)|exporting (to image|layers))' "$1" 2>/dev/null; then
    printf '%s' push
  else
    printf '%s' build
  fi
}

bake_capture() { # bake_capture <project> <rc> <reason> <elapsed-s> <outfile> [phase] [phases] — prints the path
  # The evidence an operator needs for a bake that ran out of time, kept past
  # the next tick (which overwrites pool-<P>.out): the step timings BuildKit
  # printed, then the tail. Written whole or not at all.
  local P="$1" RC="$2" R="$3" EL="$4" F="$5" PH="${6:-}" PHS="${7:-}" D="$H/logs/fly-image-build" C
  mkdir -p "$D" 2>/dev/null || return 0
  find "$D" -maxdepth 1 -type f -name '*.log' -mtime +14 -delete 2>/dev/null
  C="$D/$P-${NEW:0:7}.log"
  {
    echo "# fleet-propagate bake capture (BH-3463)"
    echo "pool=$P sha=$NEW rc=$RC reason=${R:-none}${PH:+ phase=$PH} bake elapsed=${EL}s phases=${PHS:--} written=$(STAMP)"
    echo "## step timings"
    grep -E '^#[0-9]+ (\[|DONE |ERROR|CANCELED)|warm-build: ' "$F" 2>/dev/null
    echo "## last 200 lines"
    tail -n 200 "$F" 2>/dev/null
  } > "$C.tmp" && mv "$C.tmp" "$C" && printf '%s' "$C"
}

bake_one() { # bake_one <project> — one remote bake: status reason warm_sha warm capture phases
  local P="$1" RC=0 T0 EL R="" W CAPF="" OUTF="$WORK/pool-$P.out" BPID KILLED="" PH="" CUR
  local PUSH_AT="" REC_AT="" PHS B_S U_S R_S
  T0=$(date +%s)
  # PUSH GRACE (BH-3680): the hard timeout is the build limit plus the grace;
  # the watchdog kills at the build limit a bake that has not reached the push.
  # At grace 0 the watchdog kills nothing and the one timeout is the build
  # limit, as before. GNU timeout passes the TERM on to its child's process group.
  HARNESS="$H" timeout "$((BAKE_TIMEOUT_S + PUSH_GRACE_S))" "$H/bin/fly-image-build.sh" "$P" \
    >"$OUTF" 2>&1 &
  BPID=$!
  # PHASES (BH-6201): the watchdog runs for EVERY bake and notes the first
  # second the bake's own output reads push, then record.
  while kill -0 "$BPID" 2>/dev/null; do
    if [ -z "$REC_AT" ]; then
      CUR=$(bake_phase "$OUTF")
      [ "$CUR" != build ] && [ -z "$PUSH_AT" ] && PUSH_AT=$(( $(date +%s) - T0 ))
      [ "$CUR" = record ] && REC_AT=$(( $(date +%s) - T0 ))
    else
      CUR=record
    fi
    if [ "$PUSH_GRACE_S" != 0 ] && [ $(( $(date +%s) - T0 )) -ge "$BAKE_TIMEOUT_S" ] && [ "$CUR" = build ]; then
      kill -TERM "$BPID" 2>/dev/null; KILLED=1; break
    fi
    sleep 1
  done
  wait "$BPID"; RC=$?
  [ -n "$KILLED" ] && RC=124
  EL=$(( $(date +%s) - T0 ))
  # A phase reached between the last poll and the exit counts from the exit.
  CUR=$(bake_phase "$OUTF")
  [ "$CUR" != build ] && [ -z "$PUSH_AT" ] && PUSH_AT=$EL
  [ "$CUR" = record ] && [ -z "$REC_AT" ] && REC_AT=$EL
  B_S=$EL; U_S=-; R_S=-
  [ -n "$PUSH_AT" ] && { B_S=$PUSH_AT; U_S=$(( ${REC_AT:-$EL} - PUSH_AT )); }
  [ -n "$REC_AT" ] && R_S=$(( EL - REC_AT ))
  PHS="build=${B_S}s,push=${U_S}$([ "$U_S" = - ] || printf s),record=${R_S}$([ "$R_S" = - ] || printf s),total=${EL}s"
  echo "$(STAMP) pool $P: bake phases $(printf '%s' "$PHS" | tr ',' ' ') rc=$RC" >> "$LOG"
  if [ "$RC" = 124 ]; then
    PH=$(bake_phase "$OUTF")
    echo "$(STAMP) pool $P: outer timeout hit in the $PH phase (${BAKE_TIMEOUT_S}s build limit$([ "$PUSH_GRACE_S" = 0 ] || printf ', +%ss push grace' "$PUSH_GRACE_S"))" >> "$LOG"
  elif [ "$RC" = 0 ] && [ "$EL" -gt "$BAKE_TIMEOUT_S" ]; then
    echo "$(STAMP) pool $P: bake ran ${EL}s, past the ${BAKE_TIMEOUT_S}s build limit, finished in its push grace" >> "$LOG"
  fi
  [ "$RC" = 0 ] || R=$(bake_reason "$RC" "$OUTF")
  W=$(warm_of "$OUTF")
  if [ "$RC" = 124 ] || grep -qE "$WARM_TIMEOUT_RE" "$OUTF" 2>/dev/null; then
    CAPF=$(bake_capture "$P" "$RC" "$R" "$EL" "$OUTF" "$PH" "$PHS")
  fi
  if [ "$RC" = 0 ]; then
    printf 'ok\t\t%s\t%s\t%s\t%s\n' "$(warm_sha_of "$WORK/pool-$P.out")" "$W" "$CAPF" "$PHS" > "$WORK/pool-$P.result"
  else
    printf 'fail\t%s\t%s\t%s\t%s\t%s\n' "$R" \
      "$(warm_sha_of "$WORK/pool-$P.out")" "$W" "$CAPF" "$PHS" > "$WORK/pool-$P.result"
    # The one-word class above is what the SUMMARY carries; this is the line the
    # bake itself printed (BH-806), kept because a class says which kind of
    # failure and the quoted line says which failure. rc first: a `timeout` kill
    # (124) leaves no output to quote, and "why" with no rc would read as if the
    # bake had answered.
    printf 'rc=%s: %s\n' "$RC" "$(pool_first_fail "$WORK/pool-$P.out")" > "$WORK/pool-$P.why"
  fi
}

# --- the bake step (see SYNC BEFORE BAKE in the header) ----------------------
# Only with the bake lock: the pool-* files are this step's alone.
if [ "$BAKE" = pending ]; then
  rm -f "$WORK"/pool-*.result "$WORK"/pool-*.why 2>/dev/null
  # A debounced pool is a result like any other — `debounced`, not a failure — and
  # it is marked dirty at the sha it skipped, so a later tick bakes it.
  if [ -n "$POOL_SKIP" ]; then
    mkdir -p "$FLY_STATE" 2>/dev/null
    for P in $POOL_SKIP; do
      # The first three fields of the shape a bake writes: a skip has no reason to
      # give and no layer to name. The parser reads the missing warm/capture as empty.
      printf 'debounced\t\t\n' > "$WORK/pool-$P.result"
      fp_mark_dirty "$P" "$NEW"
      echo "$(STAMP) $P: image $(pool_age_min "$P")m old, under ${MIN_AGE_MIN}m — debounced, marked dirty at ${NEW:0:7}" >> "$LOG"
    done
  fi

  # A bake of THIS pool already running (the 05:40Z refresh, a rollout, a bake
  # that outlived its run) makes this pool `busy`: tolerated like debounced, the
  # mark kept, no bake and no retry counted. Every check runs before this run
  # starts a bake of its own.
  if [ -n "$POOLS" ] && command -v pgrep >/dev/null 2>&1; then
    BAKE_LIST=""
    for P in $POOLS; do
      if pgrep -f "fly-image-build\.sh ${P}( |\$)" >/dev/null 2>&1; then
        printf 'busy\t\t\n' > "$WORK/pool-$P.result"
        fp_mark_dirty "$P" "$NEW"
        echo "$(STAMP) pool $P: a bake of this pool is already running — busy, marked dirty at ${NEW:0:7}" >> "$LOG"
      else
        BAKE_LIST="$BAKE_LIST $P"
      fi
    done
    POOLS="${BAKE_LIST# }"
  fi
  POOL_COLD=""; POOL_WARM=""
  for P in $POOLS; do
    if pool_cold "$P"; then
      POOL_COLD="$POOL_COLD $P"
      echo "$(STAMP) $P: warm layer cold (last ok bake $(pool_bake_date "$P")) — serial lane" >> "$LOG"
    else
      POOL_WARM="$POOL_WARM $P"
    fi
  done
  # The cold lane: one full checkout+install+build at a time, for as many as there
  # are. It runs ALONGSIDE the capped lane rather than inside it, because one cold
  # bake at a time is the whole point — taking a cap slot would only starve the
  # warm pools on exactly the day they are cheapest.
  if [ -n "$POOL_COLD" ]; then
    ( for P in $POOL_COLD; do bake_one "$P"; done ) &
  fi
  # The warm lane: at most BAKE_PAR at once. `wait -n` here reaps only this
  # subshell's own children — the cold lane is the PARENT's job, not this one's.
  if [ -n "$POOL_WARM" ]; then
    (
      INFLIGHT=0
      for P in $POOL_WARM; do
        if [ "$BAKE_PAR" != 0 ] && [ "$INFLIGHT" -ge "$BAKE_PAR" ]; then
          wait -n; INFLIGHT=$((INFLIGHT-1))
        fi
        bake_one "$P" &
        INFLIGHT=$((INFLIGHT+1))
      done
      wait
    ) &
  fi
  wait
fi

# POOL_BAD is the bare pool NAMES — it is what the per-pool why-lines below
# index by (BH-806: `$WORK/pool-<P>.why`), so a reason must never be glued
# into it. POOL_BAD_LABEL is the same list decorated `name(reason)` for the
# summary line and the alert, the two places an operator reads first.
POOL_ROWS=""; POOL_OK=0; POOL_BAD=""; POOL_BAD_LABEL=""; POOL_KNOWN=""; POOL_DEB=""; POOL_BUSY=""
# BH-3463: pools whose warm build timed out inside a shipped image, the capture
# of each pool that has one, and what happens next to each failed pool.
COLD_NOTE=""; declare -A POOL_CAP=() POOL_RETRY=() POOL_REASON=()
# BH-3680: `; <p> ok on retry n/N` per pool whose queued retry baked ok.
OK_RETRY=""
# Only a run that owns the bake step reads the pool-* files (BH-6201): a
# deferred run's files would be the bake step's of an older run.
POOL_RESULTS=()
[ "$BAKE" = pending ] && POOL_RESULTS=("$WORK"/pool-*.result)
for F in "${POOL_RESULTS[@]}"; do
  [ -e "$F" ] || continue
  P=$(basename "$F" .result); P="${P#pool-}"
  # status<TAB>reason<TAB>warm_sha<TAB>warm<TAB>capture<TAB>phases, split by hand: `read`
  # with IFS=$'\t' folds the empty reason of an ok row into nothing and hands
  # the sha to $R. A missing trailing field is empty (a debounced or busy row
  # has three).
  # An unreadable or empty result is a FAILURE with no reason to give, never a
  # success.
  L=$(head -1 "$F" 2>/dev/null); REST="$L"; FLD=()
  while :; do
    FLD+=("${REST%%$'\t'*}")
    case "$REST" in *$'\t'*) REST="${REST#*$'\t'}" ;; *) break ;; esac
  done
  S="${FLD[0]:-}"; R="${FLD[1]:-}"; W="${FLD[2]:-}"; WM="${FLD[3]:-}"; CP="${FLD[4]:-}"; PHS="${FLD[5]:-}"
  S="${S:-fail}"
  POOL_ROWS="$POOL_ROWS$P"$'\t'"$S"$'\t'"$R"$'\t'"$W"$'\t'"$WM"$'\t'"$CP"$'\t'"$PHS"$'\n'
  if [ "$S" = ok ] && [ -n "$CP" ]; then
    COLD_NOTE="$COLD_NOTE${COLD_NOTE:+, }$P (${CP#"$H"/})"
    echo "$(STAMP) pool $P: warm build timed out — image shipped cold, see $CP" >> "$LOG"
  fi
  [ -n "$CP" ] && POOL_CAP[$P]="$CP"
  case "$S" in
    ok)         POOL_OK=$((POOL_OK+1))
                # The stamp follows the delivery: it is written from the RESULT
                # of the bake, so a stamp without a completed bake is impossible.
                mkdir -p "$FLY_STATE" 2>/dev/null
                date -u +%s > "$FLY_STATE/$P.baked-at"
                # BH-3680: close the loop on a retry that landed. Read before
                # the rm below, with the counter's own rule: another date is 0.
                read -r OD ON < "$FLY_STATE/$P.bake-retries" 2>/dev/null || { OD=""; ON=""; }
                case "$ON" in ''|*[!0-9]*) ON=0 ;; esac
                if [ "$OD" = "$TODAY" ] && [ "$ON" -gt 0 ]; then
                  OK_RETRY="$OK_RETRY; $P ok on retry $ON/$RETRY_MAX"
                  echo "$(STAMP) pool $P: ok on retry $ON/$RETRY_MAX" >> "$LOG"
                fi
                fp_clear_dirty "$P" "$NEW"
                rm -f "$FLY_STATE/$P.bake-retries" 2>/dev/null ;;
    debounced)  POOL_DEB="$POOL_DEB $P" ;;
    busy)       POOL_BUSY="$POOL_BUSY $P" ;;
    known-fail) POOL_KNOWN="$POOL_KNOWN $P"
                fp_clear_dirty "$P" "$NEW" ;;
    *)          POOL_BAD="$POOL_BAD $P"
                POOL_BAD_LABEL="$POOL_BAD_LABEL $P${R:+($R)}"
                POOL_REASON[$P]="$R"
                # A failed bake is deliberately NOT stamped — "paid for" must
                # never mean "attempted". BH-3463: its dirty marker stays for a
                # retry on the next due tick, POOL_BAKE_RETRY_MAX times per UTC
                # day. Past the cap the marker goes: an uncapped drain would
                # cost one permanently broken pool 288 remote builds a day, the
                # spend the debounce exists to stop. The bake then comes back on
                # the next merge or the 05:40Z nightly.
                RN=0
                read -r RD RC_N < "$FLY_STATE/$P.bake-retries" 2>/dev/null || { RD=""; RC_N=""; }
                case "$RC_N" in ''|*[!0-9]*) RC_N=0 ;; esac
                [ "$RD" = "$TODAY" ] && RN=$RC_N
                mkdir -p "$FLY_STATE" 2>/dev/null
                if [ "$RN" -lt "$RETRY_MAX" ]; then
                  fp_mark_dirty "$P" "$NEW"
                  echo "$TODAY $((RN+1))" > "$FLY_STATE/$P.bake-retries"
                  POOL_RETRY[$P]="retry queued ($((RN+1))/$RETRY_MAX)"
                  echo "$(STAMP) pool $P: retry $((RN+1))/$RETRY_MAX queued for the next tick (bake failed)" >> "$LOG"
                else
                  fp_clear_dirty "$P" "$NEW"
                  if [ "$RETRY_MAX" = 0 ]; then POOL_RETRY[$P]="no retry (POOL_BAKE_RETRY_MAX=0)"
                  else
                    POOL_RETRY[$P]="retry cap reached"
                    echo "$(STAMP) pool $P: retry cap $RETRY_MAX reached today (bake failed), next attempt on the next merge or the 05:40Z nightly" >> "$LOG"
                  fi
                fi ;;
  esac
done
DEB_N=$(printf '%s' "$POOL_DEB" | wc -w | tr -d ' ')
BUSY_N=$(printf '%s' "$POOL_BUSY" | wc -w | tr -d ' ')
# The bake step MERGES its part into the record, under the state lock: .pools,
# .bake, .bake_sha, .bake_finished_at. It never writes .last_sha, so a run that
# an overlapping newer run has passed cannot move last_sha back; .finished_at
# only while last_sha is still this run's.
if [ "$BAKE" = pending ]; then
  POOLS_JSON=$(printf '%s' "$POOL_ROWS" | jq -R -s 'split("\n")|map(select(length>0))|map(split("\t"))
                |map({(.[0]):{status:.[1],reason:(.[2]//""),warm_sha:(.[3]//""),warm:(.[4]//""),capture:(.[5]//""),phases:(.[6]//"")}})|add // {}')
  FINISHED=$(STAMP)
  exec 5>"$STATE_LOCK"
  if flock -w 30 5; then
    jq --argjson pools "$POOLS_JSON" --arg s "$NEW" --arg t "$FINISHED" \
      '.pools=((.pools // {}) + $pools) | .bake="done" | .bake_sha=$s | .bake_finished_at=$t
       | if .last_sha == $s then .finished_at=$t else . end' \
      "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  else
    echo "$(STAMP) state lock busy for 30s — the bake result for ${NEW:0:7} is not merged into $STATE (the line below has it)" >> "$LOG"
  fi
  exec 5>&-
fi

POOL_N=$(printf '%s' "$POOL_ROWS" | grep -c . || true)
# One why-line per FAILED pool, before the summary so the summary stays the last
# line of the run. A failed pool with no .why is impossible by construction, and
# says so rather than being skipped.
for P in $POOL_BAD; do
  WHY=$(cat "$WORK/pool-$P.why" 2>/dev/null)
  echo "$(STAMP) pool $P: fail — ${WHY:-(no why recorded)}" >> "$LOG"
done
# POOL_N counts every pool this run considered, debounced ones included, so
# "images=0/10 (10 debounced)" reads literally — and 0/10 is never printed
# without the reason it is 0.
DEB_NOTE=""
[ "$DEB_N" -gt 0 ] && DEB_NOTE=" ($DEB_N debounced)"
# Only ever printed when something really failed (D13): a clean run's line has
# no failed= at all, so the token's presence IS the signal.
FAIL_NOTE=""
[ -n "$POOL_BAD" ] && FAIL_NOTE=" failed=$(printf '%s' "${POOL_BAD_LABEL# }" | tr ' ' ',')"
NOIMG_NOTE=""
[ "$NO_IMAGE_INPUT" = 1 ] && NOIMG_NOTE=" (no image input changed)"
BUSY_NOTE=""
[ "$BUSY_N" -gt 0 ] && BUSY_NOTE=" ($BUSY_N busy)"
IMAGES="$POOL_OK/$POOL_N$DEB_NOTE$BUSY_NOTE"
[ "$BAKE" = deferred ] && IMAGES="deferred($DEFER_N)"
echo "$(STAMP) ${LAST:0:7}..${NEW:0:7} hub=${HUB_SHOW:-$HUB} boxes=$BOX_OK/$BOX_N images=$IMAGES$NOIMG_NOTE$FAIL_NOTE cron=$CRON paths=$(printf '%s' "$MATCHED" | tr '\n' ',' | head -c 200)" >> "$LOG"

# --- 6. exactly one alert, and never a silent partial success ----------------
DEB_ALERT=""
[ "$DEB_N" -gt 0 ] && DEB_ALERT=" ($DEB_N debounced, dirty until the image is ${MIN_AGE_MIN}m old)"
# BH-6201: a busy or deferred pool is a tolerated skip, never a page.
[ "$BUSY_N" -gt 0 ] && DEB_ALERT="$DEB_ALERT ($BUSY_N busy: a bake of that pool was already running, dirty until it bakes)"
[ "$BAKE" = deferred ] && DEB_ALERT="$DEB_ALERT, $DEFER_N pool images deferred to the bake step already running (marked dirty at ${NEW:0:7})"
KNOWN_NOTE=""
[ -n "$POOL_KNOWN" ] && KNOWN_NOTE=" (known-fail, tolerated:$POOL_KNOWN)"
CRON_BAD=""
case "$CRON" in render-failed|install-failed|refused-*) CRON_BAD=1 ;; esac
# BH-3463: per failed pool, what happens next and where its capture is.
FAIL_DETAIL=""
for P in $POOL_BAD; do
  D="${POOL_RETRY[$P]:-}"
  [ -n "${POOL_CAP[$P]:-}" ] && D="${D:+$D, }see ${POOL_CAP[$P]}"
  [ -n "$D" ] && FAIL_DETAIL="$FAIL_DETAIL; $P: $D"
done
COLD_ALERT=""
[ -n "$COLD_NOTE" ] && COLD_ALERT="; shipped the new harness, warm layer cold (warm build timed out): $COLD_NOTE"
# BH-3680: a failed pool whose retry is queued is RETRYING — it goes in the warn
# digest, and pages only when its retries run out. Every other failed pool
# PAGES, including one with no retry verdict at all (fail open: that should be
# impossible, and an impossible state is not a reason to stay quiet).
PAGE_POOLS=""; PAGE_LABEL=""; RETRY_POOLS=""; RETRY_LABEL=""
for P in $POOL_BAD; do
  L="$P${POOL_REASON[$P]:+(${POOL_REASON[$P]})}"
  case "$PAGE_FIRST:${POOL_RETRY[$P]:-}" in
    "0:retry queued"*) RETRY_POOLS="$RETRY_POOLS $P"; RETRY_LABEL="$RETRY_LABEL $L" ;;
    *)                 PAGE_POOLS="$PAGE_POOLS $P";   PAGE_LABEL="$PAGE_LABEL $L" ;;
  esac
done
CRIT=""
if [ "$HUB" != ok ] || [ -n "$BOX_BAD" ] || [ "$BOX_OK" != "$BOX_N" ] || [ -n "$PAGE_POOLS" ] || [ -n "$CRON_BAD" ]; then
  CRIT=1
fi
# What a page says is still on the old harness: the hub, the failed boxes and
# the paging pools. Not a retrying pool (its own clause) and not a cold-warm
# pool (it shipped the new harness).
OLD_LIST=""
[ "$HUB" != ok ] && OLD_LIST=" hub"
OLD_LIST="$OLD_LIST$BOX_BAD$PAGE_POOLS"
# A clean run whose image shipped with a timed-out warm build is not a notice:
# it goes to the warn digest, once, so a hang that recurs every night is seen.
OK_SEV=(--log-only)
[ -n "$COLD_NOTE" ] && OK_SEV=(--severity warn)
# BH-7122: a hub sync cut after its code copy is the warn beat, never a page.
[ -n "$HUB_PC" ] && OK_SEV=(--severity warn)
# A success is a NOTICE (BH-2337): --log-only keeps its ALERTS.log line and
# opens no alert row. Anything short of N/N boxes, or any FAILED part, stays an
# alert — the explicit count check is the belt for a box that neither synced
# nor recorded a failure. BH-3680: a pool whose retry is queued is not a page.
if [ -n "$CRIT" ]; then
  "$H/bin/lane-alert.sh" --critical fleet-propagate \
    "propagating ${NEW:0:7} to the fleet FAILED in part — hub=$HUB${HUB_REASON:+ ($HUB_REASON)}, $BOX_OK/$BOX_N boxes synced${BOX_BAD:+, failed:$BOX_BAD}, $POOL_OK/$POOL_N pool images rebaked$DEB_ALERT${PAGE_LABEL:+, failed:$PAGE_LABEL}${RETRY_LABEL:+, retrying:$RETRY_LABEL}$KNOWN_NOTE, crontab $CRON$FAIL_DETAIL$COLD_ALERT$OK_RETRY.${OLD_LIST:+ Still running the OLD harness:$OLD_LIST.}${RETRY_LABEL:+ Retrying (still on the previous image until the retry lands):$RETRY_LABEL.}$HUB_PC_NOTE See $LOG and $STATE."
elif [ -n "$RETRY_POOLS" ]; then
  # The warn digest: once per run, and deliberately NOT the page's prefix, which
  # the fleet-propagate-partial alert-verify row matches.
  if [ "$DRAIN_MODE" = 1 ]; then
    W_HEAD="drained the pool images debounced earlier at ${NEW:0:7} with pool bakes retrying: $POOL_OK/$POOL_N rebaked ($DRAIN)$DEB_ALERT, retrying:$RETRY_LABEL$KNOWN_NOTE, hub ok. No box needed syncing"
  else
    W_HEAD="propagated ${NEW:0:7} with pool bakes retrying: $BOX_OK/$BOX_N boxes synced, $POOL_OK/$POOL_N pool images rebaked$DEB_ALERT, retrying:$RETRY_LABEL$KNOWN_NOTE, hub ok, crontab $CRON"
  fi
  "$H/bin/lane-alert.sh" --severity warn fleet-propagate \
    "$W_HEAD$FAIL_DETAIL$COLD_ALERT$OK_RETRY. The retrying pools keep their previous image until the retry lands; this pages only if the retries run out.$HUB_PC_NOTE"
elif [ "$DRAIN_MODE" = 1 ]; then
  # 0/0 boxes on a drain is the design, not a failure: the boxes already hold
  # this sha and only the pools debounced earlier are baked here.
  "$H/bin/lane-alert.sh" "${OK_SEV[@]}" fleet-propagate \
    "drained the pool images debounced earlier at ${NEW:0:7}: $POOL_OK/$POOL_N rebaked ($DRAIN)$DEB_ALERT$KNOWN_NOTE, hub ok. No box needed syncing$COLD_ALERT$OK_RETRY.$HUB_PC_NOTE"
else
  "$H/bin/lane-alert.sh" "${OK_SEV[@]}" fleet-propagate \
    "propagated ${NEW:0:7} to the fleet: $BOX_OK/$BOX_N boxes synced, $POOL_OK/$POOL_N pool images rebaked$NOIMG_NOTE$DEB_ALERT$KNOWN_NOTE, hub ok, crontab $CRON$COLD_ALERT$OK_RETRY.$HUB_PC_NOTE"
fi
exit 0
