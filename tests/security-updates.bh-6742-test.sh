#!/bin/bash
# tests/security-updates.bh-6742-test.sh — the OS security-update setup a box
# gets from provisioning (bin/security-updates-ensure.sh), and the per-box line
# bin/cli-version-check.sh reports about it (BH-6742). Stubs only: no real
# apt-get, dpkg or /etc.
#
#   E1  a fresh box: unattended-upgrades is installed, and the apt.conf,
#       needrestart and cron files get exactly the approved content
#   E2  a second run writes nothing and installs nothing
#   E3  the hand-made hub file of 2026-10-14 is rewritten once to the declared
#       content (the cron file gains SHELL=/bin/bash, so $RANDOM is a delay)
#   E4  apt-get install fails: package=failed, the files are still written,
#       exit 0
#   E5  HARNESS_TEST_SANDBOX=1 with no SEC_ETC: skipped, nothing written
#   E6  bootstrap-machine.sh and update-runners.sh call the script
#   E7  the cron command, run as cron runs it, refreshes the package lists
#       (apt-get update) before unattended-upgrade (lead BLOCK on c29ca501c)
#   E8  a failed apt-get update still runs unattended-upgrade (one broken
#       source must not stop every security update)
#   C1  cli-version-check reports a set-up box: the newest unattended-upgrade
#       log time, the security packages apt-get -s would install, setup yes
#   C2  a box that is not set up: last run never, setup NO
#   C3  the security line is a report, never an ALERTS line
#   C4  apt-get -s fails: the pending count is unknown, not 0
# Run from anywhere: tests/security-updates.bh-6742-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
ENSURE="$DIR/bin/security-updates-ensure.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

APT_WANT='// BH-6742 (the operator approved 2026-10-14): security updates only, never reboot.
Unattended-Upgrade::Allowed-Origins { "${distro_id}:${distro_codename}-security"; "${distro_id}ESMApps:${distro_codename}-apps-security"; "${distro_id}ESM:${distro_codename}-infra-security"; };
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::MinimalSteps "true";'
NR_WANT='# BH-6742: list services that need a restart, never restart them automatically
$nrconf{restart} = "l";'
CRON_WANT='# BH-6742: daily security updates (cron, not the apt timers: Orgo boxes have no systemd).
SHELL=/bin/bash
17 4 * * * root sleep $((RANDOM \% 1200)); timeout 600 apt-get update -qq >> /var/log/harness-unattended.log 2>&1; /usr/bin/unattended-upgrade >> /var/log/harness-unattended.log 2>&1'

# box <name> — a scratch /etc, harness and stub dpkg-query / apt-get.
box() {
  local B="$T/$1"; mkdir -p "$B/etc" "$B/h/logs" "$B/bin"; : > "$B/apt-calls"
  cat > "$B/bin/dpkg-query" <<EOF
#!/bin/bash
[ -f "$B/installed" ] && printf 'install ok installed' || printf 'unknown ok not-installed'
EOF
  cat > "$B/bin/apt-get" <<EOF
#!/bin/bash
echo "\$*" >> "$B/apt-calls"
[ "\${APT_RC:-0}" = 0 ] || exit "\$APT_RC"
touch "$B/installed"
EOF
  chmod +x "$B/bin/dpkg-query" "$B/bin/apt-get"
  echo "$B"
}
ens() { local B="$1"; shift; OUT=$(env HARNESS_ROOT="$B/h" SEC_ETC="$B/etc" SEC_DPKG_QUERY="$B/bin/dpkg-query" SEC_APT_GET="$B/bin/apt-get" "$@" bash "$ENSURE" 2>&1); RC=$?; }

echo "E1: a fresh box"
B=$(box e1); ens "$B"
[ "$RC" = 0 ] && ok "E1 exit 0" || bad "E1 rc $RC: $OUT"
grep -q 'install -y -q unattended-upgrades' "$B/apt-calls" && ok "E1 unattended-upgrades is installed" || bad "E1 apt: $(cat "$B/apt-calls")"
[ "$(cat "$B/etc/apt/apt.conf.d/52harness-security-only")" = "$APT_WANT" ] && ok "E1 apt.conf: security pockets only, no reboot" || bad "E1 apt.conf: $(cat "$B/etc/apt/apt.conf.d/52harness-security-only" 2>&1)"
[ "$(cat "$B/etc/needrestart/conf.d/50-harness.conf")" = "$NR_WANT" ] && ok "E1 needrestart in list mode" || bad "E1 needrestart: $(cat "$B/etc/needrestart/conf.d/50-harness.conf" 2>&1)"
[ "$(cat "$B/etc/cron.d/harness-security-updates")" = "$CRON_WANT" ] && ok "E1 the 04:17Z cron line under bash" || bad "E1 cron: $(cat "$B/etc/cron.d/harness-security-updates" 2>&1)"
[ "$OUT" = "security-updates-ensure package=installed files=3 cron=written" ] && ok "E1 the result line" || bad "E1 out: $OUT"
[ "$(stat -c %a "$B/etc/cron.d/harness-security-updates")" = 644 ] && ok "E1 the cron file is 644" || bad "E1 mode: $(stat -c %a "$B/etc/cron.d/harness-security-updates")"

echo "E2: a second run changes nothing"
M1=$(stat -c %Y:%i "$B/etc/apt/apt.conf.d/52harness-security-only" "$B/etc/cron.d/harness-security-updates" | tr '\n' ' ')
: > "$B/apt-calls"; ens "$B"
[ "$OUT" = "security-updates-ensure package=present files=0 cron=ok" ] && ok "E2 package=present files=0 cron=ok" || bad "E2 out: $OUT"
[ ! -s "$B/apt-calls" ] && ok "E2 apt-get is not called" || bad "E2 apt: $(cat "$B/apt-calls")"
[ "$(stat -c %Y:%i "$B/etc/apt/apt.conf.d/52harness-security-only" "$B/etc/cron.d/harness-security-updates" | tr '\n' ' ')" = "$M1" ] \
  && ok "E2 no file is rewritten" || bad "E2 the files changed"

echo "E3: the hand-made hub files are brought to the declared content"
B=$(box e3); touch "$B/installed"; mkdir -p "$B/etc/cron.d"
printf '17 4 * * * root sleep $((RANDOM \\%% 1200)); /usr/bin/unattended-upgrade >> /var/log/harness-unattended.log 2>&1\n' > "$B/etc/cron.d/harness-security-updates"
ens "$B"
[ "$(cat "$B/etc/cron.d/harness-security-updates")" = "$CRON_WANT" ] && ok "E3 the cron file now runs under bash" || bad "E3 cron: $(cat "$B/etc/cron.d/harness-security-updates")"
grep -q 'cron=written' <<<"$OUT" && ok "E3 cron=written" || bad "E3 out: $OUT"

echo "E4: apt-get install fails"
B=$(box e4); ens "$B" APT_RC=100
[ "$RC" = 0 ] && grep -q 'package=failed files=3' <<<"$OUT" && [ -s "$B/etc/cron.d/harness-security-updates" ] \
  && ok "E4 package=failed, files written, exit 0" || bad "E4 rc $RC: $OUT"

echo "E5: the sandbox guard"
B=$(box e5); OUT=$(env HARNESS_ROOT="$B/h" HARNESS_TEST_SANDBOX=1 SEC_APT_GET="$B/bin/apt-get" SEC_DPKG_QUERY="$B/bin/dpkg-query" bash "$ENSURE" 2>&1)
grep -q skipped <<<"$OUT" && [ ! -s "$B/apt-calls" ] && ok "E5 skipped, apt-get not called" || bad "E5 out: $OUT"

echo "E6: provisioning calls it"
grep -q 'security-updates-ensure.sh' "$DIR/bin/bootstrap-machine.sh" && ok "E6 bootstrap-machine.sh" || bad "E6 bootstrap-machine.sh does not call it"
grep -q '/root/harness/bin/security-updates-ensure.sh' "$DIR/bin/update-runners.sh" && ok "E6 update-runners.sh (daily)" || bad "E6 update-runners.sh does not call it"

echo "E7: the cron command refreshes the lists before unattended-upgrade"
# Run the written command the way cron does: the % escape removed, under
# SHELL=/bin/bash, with stubs for sleep, apt-get and unattended-upgrade.
cronrun() {
  local B="$1" rc="$2" cmd; mkdir -p "$B/cb"; : > "$B/order"
  printf '#!/bin/bash\n:\n' > "$B/cb/sleep"
  printf '#!/bin/bash\necho "apt-get $*" >> "%s/order"\nexit %s\n' "$B" "$rc" > "$B/cb/apt-get"
  printf '#!/bin/bash\necho unattended-upgrade >> "%s/order"\n' "$B" > "$B/cb/uu"
  chmod +x "$B/cb/sleep" "$B/cb/apt-get" "$B/cb/uu"
  cmd=$(grep '^17 4 ' "$B/etc/cron.d/harness-security-updates" | sed -e 's/^17 4 \* \* \* root //' -e 's/\\%/%/g' \
        -e "s#/usr/bin/unattended-upgrade#$B/cb/uu#" -e "s#/var/log/harness-unattended.log#$B/uu.log#g")
  PATH="$B/cb:$PATH" /bin/bash -c "$cmd"
}
B=$(box e7); ens "$B"; cronrun "$B" 0
[ "$(tr '\n' '|' < "$B/order")" = "apt-get update -qq|unattended-upgrade|" ] \
  && ok "E7 apt-get update runs, then unattended-upgrade" || bad "E7 order: $(tr '\n' '|' < "$B/order")"
grep -q 'timeout [0-9]* apt-get update' "$B/etc/cron.d/harness-security-updates" && ok "E7 apt-get update has a timeout" || bad "E7 no timeout on apt-get update"

echo "E8: a failed apt-get update still runs unattended-upgrade"
B=$(box e8); ens "$B"; cronrun "$B" 100
[ "$(tr '\n' '|' < "$B/order")" = "apt-get update -qq|unattended-upgrade|" ] \
  && ok "E8 unattended-upgrade runs after a failed update" || bad "E8 order: $(tr '\n' '|' < "$B/order")"

# --- cli-version-check's report line ----------------------------------------
H="$T/harness"; FLEET="$T/fleet"
mkdir -p "$H/logs" "$H/state" "$H/env" "$T/fakebin"
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null || { echo "closure install failed"; exit 1; }
echo "HARNESS_SECRET=x" > "$H/env/global.env"
printf '#!/bin/bash\nprintf "{\\"accepted\\":1}\\n200\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
fake_cli() { printf '#!/bin/bash\n[ "$1" = --version ] && echo "%s"\n' "$2" > "$1"; chmod +x "$1"; }
# cbox <name> <setup 0|1> <pending> — a box with current CLIs and its own /etc.
cbox() {
  local b="$FLEET/$1"; mkdir -p "$b/cronbin" "$b/shim" "$b/home/.grok/bin" "$b/etc/apt/apt.conf.d" "$b/etc/cron.d" "$b/log"
  fake_cli "$b/cronbin/claude" "2.1.299 (Claude Code)"; fake_cli "$b/cronbin/codex" "codex-cli 0.162.1"; fake_cli "$b/home/.grok/bin/grok" "grok 1.0.40"
  printf '#!/bin/bash\necho "PATH=%s"\n' "$b/cronbin" > "$b/shim/crontab"
  # apt-get -s: <pending> security lines and one that is not security.
  { echo '#!/bin/bash'; [ "$3" = fail ] && echo 'exit 100'; [ "$3" = fail ] && set -- "$1" "$2" 0; for i in $(seq 1 "$3"); do echo "echo 'Inst libfoo$i [1.0] (1.1 Ubuntu:24.04/noble-security [amd64])'"; done
    echo "echo 'Inst bar [1.0] (1.1 Ubuntu:24.04/noble-updates [amd64])'"; } > "$b/shim/apt-get"
  chmod +x "$b/shim/crontab" "$b/shim/apt-get"
  if [ "$2" = 1 ]; then
    echo x > "$b/etc/apt/apt.conf.d/52harness-security-only"; echo x > "$b/etc/cron.d/harness-security-updates"
    echo ran > "$b/log/harness-unattended.log"; touch -d '2026-10-14 04:30:00 UTC' "$b/log/harness-unattended.log"
  fi
  echo "HARNESS_SECRET=x" > "$b/global.env"
}
cat > "$T/fake-ssh.sh" <<'EOF'
#!/bin/bash
BOX="${1#root@}"; ROOT="$FLEET/$BOX"
[ -d "$ROOT" ] || exit 255
PATH="$ROOT/shim:$SYS_PATH" CLI_CHECK_ENV_FILE="$ROOT/global.env" CLI_CHECK_LOGIN_PATH="$ROOT/cronbin" \
  CLI_CHECK_HOME="$ROOT/home" CLI_CHECK_ETC="$ROOT/etc" CLI_CHECK_UU_LOGS="$ROOT/log/harness-unattended.log" bash -s
EOF
chmod +x "$T/fake-ssh.sh"
cbox hub 1 3; cbox box-zeta 0 0; cbox box-eta 1 fail
B0=0; [ -f "$H/logs/ALERTS.log" ] && B0=$(wc -l < "$H/logs/ALERTS.log")
COUT=$(PATH="$FLEET/hub/shim:$T/fakebin:$PATH" SYS_PATH="$T/fakebin:$PATH" FLEET="$FLEET" HARNESS="$H" HARNESS_CHECKOUT="$DIR" \
       CLI_CHECK_BOXES="local box-zeta box-eta" CLI_CHECK_SSH="$T/fake-ssh.sh" CLI_CHECK_SELF_REPORT_FRESH_S=0 \
       CLI_CHECK_ENV_FILE="$FLEET/hub/global.env" CLI_CHECK_LOGIN_PATH="$FLEET/hub/cronbin" CLI_CHECK_HOME="$FLEET/hub/home" \
       CLI_CHECK_ETC="$FLEET/hub/etc" CLI_CHECK_UU_LOGS="$FLEET/hub/log/harness-unattended.log" \
       bash "$DIR/bin/cli-version-check.sh" 2>&1)
echo "C1-C3: the cli-version-check report"
grep -q '^  hub security updates: last run 2026-10-14T04:30:00Z, 3 pending, setup yes$' <<<"$COUT" \
  && ok "C1 the hub line: last run, 3 pending, setup yes" || bad "C1 report: $(grep -i security <<<"$COUT")"
grep -q '^  zeta security updates: last run never, 0 pending, setup NO$' <<<"$COUT" \
  && ok "C2 the zeta line: never, 0 pending, setup NO" || bad "C2 report: $(grep -i security <<<"$COUT")"
grep -q '^  eta security updates: last run 2026-10-14T04:30:00Z, unknown pending, setup yes$' <<<"$COUT" \
  && ok "C4 apt-get -s fails: unknown pending, not 0" || bad "C4 report: $(grep -i security <<<"$COUT")"
NEW=$(tail -n +$((B0+1)) "$H/logs/ALERTS.log" 2>/dev/null)
! grep -qi 'security' <<<"$NEW" && ok "C3 no ALERTS line names security updates" || bad "C3 alerts: $NEW"

echo "security-updates.bh-6742: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
