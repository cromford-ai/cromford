#!/bin/bash
# bin/fly-image-refresh.sh — nightly (hub cron 05:40Z, after the 05:17Z harness
# sync): rebuild every pool project's builder image so the baked entrypoint/
# runner can never drift a day behind the repo again (2026-08-13: a stale image
# without the POOL_MODE entrypoint dead-looped the project-3 pool all night). Depot
# layer cache makes an unchanged rebuild cost seconds.
set -uo pipefail
H="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-fly-image-refresh
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off fly-image-refresh.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit fly-image-refresh
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    fly-image-refresh
export PATH="/root/.fly/bin:$PATH"
LOG="$H/logs/fly-image-refresh.log"
# BH-1035.3: the image ref's DB twin, a settings row fly_image.<project> (a
# pool-routed project has no builder row to carry it). Sourced once, guarded,
# fail-open — the file write inside the loop never depends on it.
# shellcheck source=/dev/null
[ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh"
# BH-1517: cli_patch_drift for the floor check below.
# shellcheck source=bin/lib/cli-version.sh
[ -r "$H/bin/lib/cli-version.sh" ] && . "$H/bin/lib/cli-version.sh"
# BH-1528: the baked-dependency manifest (bake_deps / bake_row_version /
# bake_last_baked) for the per-dependency drift check below.
# shellcheck source=bin/lib/bake-deps.sh
[ -r "$H/bin/lib/bake-deps.sh" ] && . "$H/bin/lib/bake-deps.sh"
# BH-6710: warm_bust_roll, the key every pool bake's warm layer is cached by.
# shellcheck source=bin/lib/warm-bust.sh
[ -r "$H/bin/lib/warm-bust.sh" ] && . "$H/bin/lib/warm-bust.sh"

# _bake_alert_once <flag-suffix> <line> — one ALERTS.log line per flag per UTC
# day; the lane runs nightly and a stuck image must not page every night twice.
_bake_alert_once() {
  local flag
  mkdir -p "$H/flags" 2>/dev/null
  flag="$H/flags/alerted-fly-image-$1-$(date -u +%Y%m%d)"
  [ -e "$flag" ] && return 0
  : > "$flag" 2>/dev/null
  HARNESS="$H" ALERT_LINE_STAMP="$(date -u '+%F %T Z')" "$H/bin/alert-line.sh" "$2"
}

# _bake_drift <project> <bake-file> — compares what <project>'s image baked
# against each bake.<name>.version row. A mismatch is one alert per project
# per dependency per UTC day (a row bumped while the rebuild keeps failing, or a
# dependency added to the manifest that this image predates). A missing row is
# not judged here: _bake_norow_fleet reports it once for the whole fleet.
_bake_drift() {
  local p="$1" file="$2" name want baked
  while read -r name _; do
    [ -n "$name" ] || continue
    want=$(bake_row_version "$name"); [ $? = 1 ] && return 0   # outage: judge nothing
    [ -n "$want" ] || continue
    baked=$(bake_last_baked "$file" "$name")
    [ "$baked" = "$want" ] && continue
    _bake_alert_once "bake-drift-$p-$name" "[$p] fly builder image $name drift: baked=${baked:-missing} row bake.$name.version=$want — fix: bin/fly-image-build.sh $p (the nightly refresh re-pins once the rebuild succeeds)"
  done < <(bake_deps)
}

# _bake_norow_fleet — ONE line per UTC day naming every bake.<name>.version row
# that is missing or unparseable (BH-1528 review F3). It runs before the
# project loop and needs no state/fly/<project>.bake, so it also fires on the
# night that matters most: before the first pinned build, when a missing row
# makes every project's build refuse (the per-project FATAL names the rows only
# in logs/fly-image-build.log). With a .bake the build holds the last baked
# version instead, and this line is the reminder that nobody owns that pin.
_bake_norow_fleet() {
  local name want missing=""
  while read -r name _; do
    [ -n "$name" ] || continue
    want=$(bake_row_version "$name"); [ $? = 1 ] && return 0   # outage: judge nothing
    [ -n "$want" ] || missing="$missing bake.$name.version"
  done < <(bake_deps)
  [ -z "$missing" ] || _bake_alert_once "bake-norow-fleet" "[fleet] fly builder images have no usable row for:$missing — a project with no last baked set refuses to build, the others hold their last baked versions; set them with bin/bake-seed.sh <name>=<version>"
}
command -v routing_sync_all >/dev/null 2>&1 && { routing_sync_all >/dev/null 2>&1 || true; }
# Only when this hub builds pool images at all (a fly-pool-* flag exists).
compgen -G "$H/flags/fly-pool-*" >/dev/null 2>&1 \
  && command -v bake_deps >/dev/null 2>&1 && command -v setting_get >/dev/null 2>&1 && _bake_norow_fleet

# --- BH-6710: one bake lane with fleet-propagate, then roll the warm bust -----
# The refresh bakes every pool serially on the same org remote builder that
# bin/fleet-propagate.sh bakes on. Unlocked, it ran beside the propagate lanes
# (2026-10-14 06:11Z: four builds at once, project-2 build 1473s against
# 198s alone). So it holds the propagate bake lock (fd 6) for its whole run; a
# propagate tick that finds it held defers its pools to a later tick. The wait
# for a running propagate bake step is bounded and fails open: the refresh
# never skips. Then it rolls state/fly/warm-bust, so the warm layer this run
# builds is the one every bake reuses until the next refresh, and the first
# propagate tick after 00:00Z no longer rebuilds every pool cold.
if compgen -G "$H/flags/fly-pool-*" >/dev/null 2>&1; then
  WAIT="${FLY_IMAGE_REFRESH_LOCK_WAIT_S:-2100}"
  case "$WAIT" in
    ''|*[!0-9]*)
      echo "$(date -u '+%F %T Z') FLY_IMAGE_REFRESH_LOCK_WAIT_S=$WAIT is not a number of seconds — using 2100" >> "$LOG"
      WAIT=2100 ;;
  esac
  mkdir -p "$H/locks" 2>/dev/null
  if ! exec 6>"$H/locks/fleet-propagate-bake.lock"; then
    echo "$(date -u '+%F %T Z') bake lock cannot be opened ($H/locks/fleet-propagate-bake.lock) — baking without it" >> "$LOG"
  elif flock -w "$WAIT" 6; then
    echo "$(date -u '+%F %T Z') bake lock taken" >> "$LOG"
  else
    echo "$(date -u '+%F %T Z') bake lock busy for ${WAIT}s — baking without it" >> "$LOG"
  fi
  # WARM_BUST_NOW is a test clock seam; production never sets it.
  WB_NOW="${WARM_BUST_NOW:-$(date -u +%s)}"
  if command -v warm_bust_roll >/dev/null 2>&1 && warm_bust_roll "$H/state/fly" "$WB_NOW"; then
    echo "$(date -u '+%F %T Z') warm bust rolled to $(date -u -d "@$WB_NOW" +%F)" >> "$LOG"
  else
    echo "$(date -u '+%F %T Z') warm bust NOT rolled (bin/lib/warm-bust.sh missing or $H/state/fly not writable) — bakes keep the last bust or the date rule" >> "$LOG"
  fi
fi

for F in "$H"/flags/fly-pool-*; do
  [ -f "$F" ] || continue
  case "$F" in *fly-pool-app-*) continue;; esac
  P="${F##*fly-pool-}"
  OK=0
  for ATTEMPT in 1 2; do
    if timeout 1800 "$H/bin/fly-image-build.sh" "$P" >> "$H/logs/fly-image-build.log" 2>&1; then OK=1; break; fi
    echo "$(date -u '+%F %T Z') $P image rebuild attempt $ATTEMPT failed" >> "$LOG"
  done
  if [ "$OK" = 1 ]; then
    IMG=$(grep -oE "image: registry\.fly\.io/builder-$P:[^ ]+" "$H/logs/fly-image-build.log" | tail -1 | cut -d' ' -f2)
    if [ -n "$IMG" ]; then
      echo "$IMG" > "$H/state/fly/$P.image"
      if command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on; then
        setting_set "fly_image.$P" "$IMG" "BH-1035: the image $P's pool spawns from; state/fly/$P.image is its cache" \
          || echo "$(date -u '+%F %T Z') $P image row not written (worker unreachable or refused) — state/fly/$P.image is authoritative this cycle" >> "$LOG"
      fi
    fi
    echo "$(date -u '+%F %T Z') $P refreshed: ${IMG:-ref-not-parsed}" >> "$LOG"
  else
    echo "$(date -u '+%F %T Z') $P image rebuild FAILED (pool keeps last good image)" >> "$LOG"
    HARNESS="$H" ALERT_LINE_STAMP="$(date -u '+%F %T Z')" "$H/bin/alert-line.sh" "[$P] nightly builder-image rebuild FAILED — pool runs yesterday's image until fixed"
  fi

  # --- BH-1517: baked-CLI bookkeeping + drift floor ------------------------
  # BH-1531 (N1): this block sits OUTSIDE the rebuild-succeeded branch on
  # purpose, so it runs on EVERY project iteration, a FAILED rebuild included.
  # state/fly/<project>.cli is written only next to a parsed image ref (see
  # bin/fly-image-build.sh), so on a failed night it still describes the image
  # the pool actually runs — which is what makes the comparison below a real
  # stale-builder detector instead of a same-run self-compare.
  # bin/fly-image-build.sh writes state/fly/<project>.cli ("claude=X\ncodex=Y")
  # for the build it JUST ran; record it next to the image ref and compare it
  # against the hub's own cli.claude_code.version / cli.codex.version rows (the
  # write side is bin/cli-update.sh, hub-scoped). A builder more than
  # CLI_DRIFT_MAX_PATCH patch versions behind either floor gets ONE ALERTS
  # line per project per UTC day — the dedupe matters because this lane runs
  # nightly and a stuck image would otherwise page every night it stays stuck.
  CLI_INFO="$H/state/fly/$P.cli"
  if [ -f "$CLI_INFO" ]; then
    BAKED_CLAUDE=$(sed -n 's/^claude=//p' "$CLI_INFO" | head -1)
    BAKED_CODEX=$(sed -n 's/^codex=//p' "$CLI_INFO" | head -1)
    if command -v setting_set >/dev/null 2>&1 && command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on; then
      setting_set "fly_image_cli.$P" "claude=$BAKED_CLAUDE codex=$BAKED_CODEX" "BH-1517: CLI versions baked into $P's builder image, next to fly_image.$P" \
        || echo "$(date -u '+%F %T Z') $P fly_image_cli row not written (worker unreachable or refused) — $CLI_INFO is authoritative this cycle" >> "$LOG"
    fi
    if command -v setting_get >/dev/null 2>&1 && command -v cli_patch_drift >/dev/null 2>&1; then
      DRIFT_MAX_PATCH="${CLI_DRIFT_MAX_PATCH:-3}"
      HUB_CLAUDE=$(setting_get cli.claude_code.version 2>/dev/null || true)
      HUB_CODEX=$(setting_get cli.codex.version 2>/dev/null || true)
      DRIFTED=""
      if [ -n "$HUB_CLAUDE" ]; then
        CD=$(cli_patch_drift "$BAKED_CLAUDE" "$HUB_CLAUDE" 2>/dev/null || echo 0)
        case "$CD" in *[!0-9-]*) CD=0 ;; esac
        [ "$CD" -gt "$DRIFT_MAX_PATCH" ] 2>/dev/null && DRIFTED="${DRIFTED}claude baked=${BAKED_CLAUDE:-missing} hub=$HUB_CLAUDE (${CD} patch behind); "
      fi
      if [ -n "$HUB_CODEX" ]; then
        XD=$(cli_patch_drift "$BAKED_CODEX" "$HUB_CODEX" 2>/dev/null || echo 0)
        case "$XD" in *[!0-9-]*) XD=0 ;; esac
        [ "$XD" -gt "$DRIFT_MAX_PATCH" ] 2>/dev/null && DRIFTED="${DRIFTED}codex baked=${BAKED_CODEX:-missing} hub=$HUB_CODEX (${XD} patch behind); "
      fi
      if [ -n "$DRIFTED" ]; then
        mkdir -p "$H/flags" 2>/dev/null
        DRIFT_FLAG="$H/flags/alerted-fly-image-drift-$P-$(date -u +%Y%m%d)"
        if [ ! -e "$DRIFT_FLAG" ]; then
          : > "$DRIFT_FLAG" 2>/dev/null
          HARNESS="$H" ALERT_LINE_STAMP="$(date -u '+%F %T Z')" "$H/bin/alert-line.sh" "[$P] fly builder image CLI drift beyond $DRIFT_MAX_PATCH patch versions: ${DRIFTED%; } — fix: bin/fly-image-build.sh $P (tomorrow's nightly refresh re-pins automatically once cli.claude_code.version/cli.codex.version are current)"
        fi
      fi
    fi
  fi

  # --- BH-1528: baked-dependency bookkeeping + drift -------------------------
  # Same placement rule as the CLI block (BH-1531 N1): every iteration, a failed
  # rebuild included, because state/fly/<project>.bake is written only next to
  # a parsed image ref and so always describes the image the pool runs.
  BAKE_INFO="$H/state/fly/$P.bake"
  if [ -f "$BAKE_INFO" ] && command -v bake_deps >/dev/null 2>&1; then
    if command -v setting_set >/dev/null 2>&1 && command -v machines_rows_on >/dev/null 2>&1 && machines_rows_on; then
      setting_set "fly_image_bake.$P" "$(tr '\n' ' ' < "$BAKE_INFO" | sed 's/ *$//')" "BH-1528: dependency versions baked into $P's builder image, next to fly_image.$P" \
        || echo "$(date -u '+%F %T Z') $P fly_image_bake row not written (worker unreachable or refused) — $BAKE_INFO is authoritative this cycle" >> "$LOG"
    fi
    command -v setting_get >/dev/null 2>&1 && _bake_drift "$P" "$BAKE_INFO"
  fi
done
