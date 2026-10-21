#!/bin/bash
# fly/hub/entrypoint.sh — boot of the hub Fly machine (BH-7715). The runbook is
# docs/notes/2026-10-20-BH-7715-hub-move.md.
#
# The Fly root fs is lost on every restart, so everything durable lives on the
# volume at /data:
#   1. create /data/{harness,harness-checkout,etc-harness,repos,root-ssh,
#      root-claude,root-config,cron-spool,ssh-host} once; symlink /root/harness,
#      /root/harness-checkout, /etc/harness, /root/repos, /root/.ssh,
#      /root/.claude, /root/.config and /var/spool/cron/crontabs to them. A real
#      directory the image shipped at one of those paths is copied to /data
#      (no clobber) on the first boot, then replaced by the symlink.
#   2. tailscaled with its state on /data/tailscaled.state, then `tailscale up
#      --hostname $HUB_TS_HOSTNAME`. No TS_AUTHKEY and no saved state = exit 1:
#      a hub nobody can reach must not run.
#   3. sshd, key login only. The Fly secret HUB_AUTHORIZED_KEY is added to
#      /root/.ssh/authorized_keys when that line is not there yet. Host keys
#      live on /data/ssh-host, so they survive a restart.
#   4. exec cron -f.
# It NEVER installs a crontab. A crontab exists only after
# `bin/hub-move.sh cutover --step C6` ran update-runners.sh, and it survives a
# restart through the symlinked spool. A booted target is inert: that is the
# split-brain guard.
#
# HUB_ENTRYPOINT_ROOT (default empty) prefixes every path, and
# HUB_TS_SOCKET_WAIT_S (default 30) bounds the wait for the tailscaled socket;
# the suite boots this script in a scratch tree with stub daemons.
set -uo pipefail

R="${HUB_ENTRYPOINT_ROOT:-}"
D="$R/data"
TS_HOSTNAME="${HUB_TS_HOSTNAME:-}"
log() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [hub-entrypoint] $*"; }

# --- 1. volume layout ---------------------------------------------------------
[ -d "$D" ] || { log "FATAL: $D is not mounted"; exit 1; }
mkdir -p "$R/root" "$R/etc" "$R/var/spool/cron"
link() { # link <data-subdir> <path>
  local src="$D/$1" dst="$R$2"
  mkdir -p "$src"
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    cp -an "$dst/." "$src/" 2>/dev/null
    rm -rf "$dst"
  fi
  [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ] && return 0
  rm -f "$dst"
  ln -s "$src" "$dst"
}
link harness /root/harness
link harness-checkout /root/harness-checkout
link etc-harness /etc/harness
link repos /root/repos
link root-ssh /root/.ssh
link root-claude /root/.claude
link root-config /root/.config
link cron-spool /var/spool/cron/crontabs
chmod 700 "$D/root-ssh"
chmod 1730 "$D/cron-spool" 2>/dev/null
log "volume layout ready"

# --- 2. tailscale -------------------------------------------------------------
if [ -z "${TS_AUTHKEY:-}" ] && [ ! -s "$D/tailscaled.state" ]; then
  log "FATAL: TS_AUTHKEY unset and no $D/tailscaled.state to resume from"
  exit 1
fi
mkdir -p "$R/var/run/tailscale" "$R/var/log"
tailscaled --state="$D/tailscaled.state" --socket="$R/var/run/tailscale/tailscaled.sock" \
  >"$R/var/log/tailscaled.log" 2>&1 &
for _ in $(seq 1 "${HUB_TS_SOCKET_WAIT_S:-30}"); do [ -S "$R/var/run/tailscale/tailscaled.sock" ] && break; sleep 1; done
UP=(up --ssh=false)
[ -n "$TS_HOSTNAME" ] && UP+=(--hostname "$TS_HOSTNAME")
[ -n "${TS_AUTHKEY:-}" ] && UP+=(--authkey "$TS_AUTHKEY")
tailscale --socket="$R/var/run/tailscale/tailscaled.sock" "${UP[@]}" \
  || { log "FATAL: tailscale up failed"; exit 1; }
log "tailscale up as ${TS_HOSTNAME:-<default hostname>}"

# --- 3. sshd ------------------------------------------------------------------
mkdir -p "$D/ssh-host"
[ -s "$D/ssh-host/ssh_host_ed25519_key" ] \
  || ssh-keygen -q -t ed25519 -N '' -f "$D/ssh-host/ssh_host_ed25519_key" \
  || { log "FATAL: ssh-keygen failed"; exit 1; }
if [ -n "${HUB_AUTHORIZED_KEY:-}" ]; then
  touch "$D/root-ssh/authorized_keys"
  grep -qxF "$HUB_AUTHORIZED_KEY" "$D/root-ssh/authorized_keys" \
    || printf '%s\n' "$HUB_AUTHORIZED_KEY" >> "$D/root-ssh/authorized_keys"
  chmod 600 "$D/root-ssh/authorized_keys"
fi
mkdir -p "$R/run/sshd"
"$(command -v sshd || echo /usr/sbin/sshd)" -h "$D/ssh-host/ssh_host_ed25519_key" \
  -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password \
  || { log "FATAL: sshd did not start"; exit 1; }
log "sshd started"

# --- 4. cron ------------------------------------------------------------------
log "starting cron (crontab: $(ls "$D/cron-spool" 2>/dev/null | tr '\n' ' '))"
exec cron -f
