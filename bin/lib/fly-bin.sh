#!/bin/bash
# bin/lib/fly-bin.sh — where flyctl is on this box (BH-6061). Sourced, never
# executed; sourcing it has no side effects.
#
#   fly_bin   print the absolute path of flyctl, rc 127 when there is none
#
# PATH FIRST, then the install directories. Cron's PATH is /usr/bin:/bin and the
# flyctl installer puts the binary in $HOME/.fly/bin, so a lookup that only asks
# `command -v` finds nothing under cron. testhost-tick did exactly that and read
# `state=unknown` for 13 days. PATH stays first so a test stub, or an operator's
# own flyctl, is never shadowed by an installed one.
#
# Then ${FLY_BIN_DIR:-/root/.fly/bin}, the same seam bin/fly-pool.sh uses, and
# last ${FLY_SYSTEM_DIRS-/usr/local/bin}, where the Fly hub image installs it
# (BH-7715); a test sets FLY_SYSTEM_DIRS="" for a "no flyctl" row. Cron and
# prod set FLY_BIN_DIR nowhere. A test sets it to a stub dir, or to an empty dir
# (with FLY_SYSTEM_DIRS="") to prove "not found" on a box with a real flyctl. bin/lane-fleet.sh, bin/testhost-tick.sh and bin/fly-idle-reaper.sh
# all look flyctl up here.
fly_bin() {
  local b d
  for b in flyctl fly; do
    d=$(command -v "$b" 2>/dev/null) || continue
    case "$d" in /*) [ -x "$d" ] && { printf '%s\n' "$d"; return 0; } ;; esac
  done
  # ${FLY_SYSTEM_DIRS-/usr/local/bin}: the Fly hub image installs flyctl there
  # (BH-7715), and cron's PATH (/usr/bin:/bin) does not carry it. On bh-hub-2,
  # 2026-10-22, that left the pool tick with no flyctl at all. A test sets
  # FLY_SYSTEM_DIRS="" to prove "not found" on a box that has one there.
  for d in ${FLYCTL_INSTALL:+"$FLYCTL_INSTALL/bin"} ${HOME:+"$HOME/.fly/bin"} "${FLY_BIN_DIR:-/root/.fly/bin}" ${FLY_SYSTEM_DIRS-/usr/local/bin}; do
    [ -x "$d/flyctl" ] && { printf '%s\n' "$d/flyctl"; return 0; }
  done
  return 127
}
