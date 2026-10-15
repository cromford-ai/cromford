#!/bin/bash
# bin/security-updates-ensure.sh — the one place a box's OS security-update
# setup is declared (BH-6742). Run by bin/bootstrap-machine.sh on first boot
# and by bin/update-runners.sh every day, so a new box gets the setup and an
# existing box that lost a file gets it back.
#
# WHY. On 2026-10-14 the hub had 112 upgradable packages and no
# unattended-upgrades. the operator approved security updates (2026-10-14 ~18:25Z), and
# operator-a5 applied this setup by hand on the hub and 5 boxes (#6742). This script
# is that same setup, so provisioning carries it.
#
# WHAT. Security pockets only, never a reboot, never a service restart:
#   - the package unattended-upgrades (apt-get install, only when dpkg says it
#     is not installed);
#   - <apt>/apt.conf.d/52harness-security-only: Allowed-Origins = the
#     -security pocket, ESM apps security and ESM infra security;
#     Automatic-Reboot "false"; Remove-Unused-Dependencies "false";
#     MinimalSteps "true";
#   - <needrestart>/conf.d/50-harness.conf: $nrconf{restart} = "l" (list the
#     services that need a restart, restart none);
#   - <cron.d>/harness-security-updates: 04:17Z daily, a random delay up to 20
#     min, apt-get update (timeout 600 s), then /usr/bin/unattended-upgrade,
#     both into /var/log/harness-unattended.log.
#     A cron line, not the apt timers: the Orgo boxes have no systemd, so the
#     timers never fire there.
# A file is written only when its content differs (tmp file + mv), so a daily
# run on a set-up box changes nothing.
#
# One line in logs/security-updates-ensure.log per run (and on stdout):
#   security-updates-ensure package=<installed|present|failed> files=<n written> cron=<ok|written>
# Exit 0 after any attempt (fail-open: a box with no apt keeps working).
#
# Test seams: HARNESS_ROOT, SEC_ETC (the /etc root), SEC_DPKG_QUERY,
# SEC_APT_GET. Under HARNESS_TEST_SANDBOX=1 with no SEC_ETC it skips, so a
# suite never writes the real /etc.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
LOG="$H/logs/security-updates-ensure.log"
mkdir -p "$H/logs" 2>/dev/null
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { echo "$1"; echo "$(STAMP) $1" >> "$LOG" 2>/dev/null; }

if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -z "${SEC_ETC:-}" ]; then
  say "security-updates-ensure skipped (HARNESS_TEST_SANDBOX=1 and no SEC_ETC)"; exit 0
fi
ETC="${SEC_ETC:-/etc}"
DPKG_QUERY="${SEC_DPKG_QUERY:-dpkg-query}"
APT_GET="${SEC_APT_GET:-apt-get}"

APT_CONF='// BH-6742 (the operator approved 2026-10-14): security updates only, never reboot.
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; "${distro_id}ESMApps:${distro_codename}-apps-security"; "${distro_id}ESM:${distro_codename}-infra-security"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::MinimalSteps "true";'
NR_CONF='# BH-6742: list services that need a restart, never restart them automatically
$nrconf{restart} = "l";'
# unattended-upgrade does not refresh the package lists itself (apt.systemd.daily
# does, from the timers these boxes never fire), so the cron line runs
# apt-get update first. `;`, not `&&`: one broken source must not stop every
# security update; the old lists are still read.
CRON_LINE='17 4 * * * root sleep $((RANDOM \% 1200)); timeout 600 apt-get update -qq >> /var/log/harness-unattended.log 2>&1; /usr/bin/unattended-upgrade >> /var/log/harness-unattended.log 2>&1'
CRON_FILE="# BH-6742: daily security updates (cron, not the apt timers: Orgo boxes have no systemd).
SHELL=/bin/bash
$CRON_LINE"

PKG=present
if [ "$("$DPKG_QUERY" -W -f='${Status}' unattended-upgrades 2>/dev/null)" != "install ok installed" ]; then
  if command -v "$APT_GET" >/dev/null 2>&1 \
     && DEBIAN_FRONTEND=noninteractive "$APT_GET" install -y -q unattended-upgrades >> "$LOG" 2>&1; then
    PKG=installed
  else
    PKG=failed
  fi
fi

WROTE=0
# put <file> <content> — write when the content differs; rc 0 when it is right.
put() {
  local f="$1" want="$2"
  [ "$(cat "$f" 2>/dev/null)" = "$want" ] && return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  printf '%s\n' "$want" > "$f.tmp.$$" && chmod 644 "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || { rm -f "$f.tmp.$$"; return 1; }
  WROTE=$((WROTE + 1))
}
FAILS=""
put "$ETC/apt/apt.conf.d/52harness-security-only" "$APT_CONF" || FAILS="$FAILS apt.conf"
put "$ETC/needrestart/conf.d/50-harness.conf" "$NR_CONF" || FAILS="$FAILS needrestart"
CRON=ok
[ "$(cat "$ETC/cron.d/harness-security-updates" 2>/dev/null)" = "$CRON_FILE" ] || CRON=written
put "$ETC/cron.d/harness-security-updates" "$CRON_FILE" || { FAILS="$FAILS cron"; CRON=failed; }
say "security-updates-ensure package=$PKG files=$WROTE cron=$CRON${FAILS:+ failed:$FAILS}"
exit 0
