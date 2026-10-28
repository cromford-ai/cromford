# shellcheck shell=bash
# bin/lib/pool-tailnet.sh — the pool names a box that is off the tailnet
# (BH-6693). Sourced by bin/fly-pool.sh; defining functions is its only effect.
#
# WHY. On 2026-10-14 tailscaled died on box-small and the pool logged
# `env bundle FAILED for <KEY>: ssh env extract from <box> failed` 11
# times in ~2 h. Each line named a ticket; nothing named the box or the cause.
#
# ptn_note <project> <bundle-reason>
#   Called on every env-bundle failure. A reason that is not
#   `ssh env extract from <box> failed` counts nothing. Otherwise one epoch line
#   goes to state/pool-tailnet/<box>.fails (lines older than the window are
#   dropped). At POOL_TAILNET_FAILS failures (3) inside POOL_TAILNET_WINDOW_S
#   (1800; BH-8281: the pool ticks every 10 min, so 3 failed ticks in a row
#   span 1200 s and a 900 s window never alerted on one queued row) it writes ONE alert line through bin/alert-line.sh, which names the
#   box and says "tailnet unreachable or box overloaded" (BH-8281: on
#   2026-10-24 the tailnet was up and the box was at load 92), and marks the episode
#   (<box>.alerted). The episode ends when a failure arrives after a quiet
#   window (no failure for longer than POOL_TAILNET_WINDOW_S): the marker goes,
#   and the next streak alerts again. rc 0 always; a state dir it cannot write
#   is no alert, never a failed tick. Both are fly-pool lane knobs
#   (catalog/lanes.d/fly-pool.knobs.d/).
ptn_note() {
  local p="${1:-}" why="${2:-}" box dir f now win n last ok_n min root
  box=$(sed -n 's/.*ssh env extract from \([^ ]*\) failed.*/\1/p' <<<"$why" | head -n 1)
  [ -n "$box" ] || return 0
  case "$box" in *[!A-Za-z0-9._:-]*) return 0 ;; esac
  root="${HARNESS:-${H:-}}"; [ -n "$root" ] || return 0
  dir="$root/state/pool-tailnet"
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/$box.fails"
  now=$(date -u +%s)
  win="${POOL_TAILNET_WINDOW_S:-1800}"; case "$win" in ''|*[!0-9]*) win=1800 ;; esac
  min="${POOL_TAILNET_FAILS:-3}"; case "$min" in ''|*[!0-9]*|0) min=3 ;; esac
  # A quiet window since the newest recorded failure ends the episode.
  last=$(tail -n 1 "$f" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$last" -gt 0 ] && [ $((now - last)) -gt "$win" ]; then rm -f "$dir/$box.alerted"; fi
  { awk -v c=$((now - win)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" 2>/dev/null; echo "$now"; } > "$f.tmp" \
    && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; return 0; }
  n=$(grep -c . "$f" 2>/dev/null); ok_n="${n:-0}"
  [ "$ok_n" -ge "$min" ] || return 0
  [ -e "$dir/$box.alerted" ] && return 0
  : > "$dir/$box.alerted" 2>/dev/null || return 0
  HARNESS="$root" "$root/bin/alert-line.sh" \
    "[pool/$p] box $box: tailnet unreachable or box overloaded — ssh env extract failed $ok_n times in $((win / 60)) min, so no build can start on it. Check tailscaled on the box (bin/tailscaled-watchdog.sh restarts it every 2 min), then the load on the box (uptime, ps); a cargo build can starve sshd (BH-8281). The hub reaches it again when ssh root@$box works." \
    >/dev/null 2>&1 || true
  return 0
}
