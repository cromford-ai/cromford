#!/bin/bash
# bin/audit-install.sh — put a kernel audit watch on the harness roots, on every
# box, every day. Cron reaches it through bin/update-runners.sh (05:17Z); a fresh
# box gets it from bin/bootstrap-machine.sh.
#
# WHY IT EXISTS (hub wipe, incident #388, 2026-09-15). At 16:50Z
# /root/harness/{env,bin,prompts,logs,builds} vanished and nothing on the box
# could say who did it — no record of the unlink, no pid, no argv. Deliverable
# (1) of #395 is that a deletion leaves a line. This script is the half that
# makes the KERNEL write that line: auditd installed, one rules file of syscall
# rules (delete, rename, truncate) on the roots under key `harness`, the log
# rotation bounded, the rules loaded and the load VERIFIED by a live probe. The
# half that READS those records is the tailer (BH-444); nothing in this file
# calls it or writes its state.
#
# THREE MODES:
#   audit-install.sh            install/repair — apt, rules file, auditd.conf
#                               knobs, daemon, load, verify
#   audit-install.sh --render   print the rules file to stdout and nothing else
#   audit-install.sh --check    print state; rc 1 when something is off. With
#                               rules loaded it writes and removes one probe
#                               file, may send `auditctl --signal resume`, and
#                               on a stale or dead trail writes one alert_once.
#                               With no auditctl or no rules loaded it writes
#                               nothing.
#
# IT EXITS 0 FROM EVERY CRON PATH. apt refusing, the daemon refusing to start, a
# kernel that will not take the rules: each is a classed line in
# logs/audit-install.log plus ONE logs/ALERTS.log line per day naming what is
# needed and from whom (marker state/audit-install-denied-YYYYMMDD, the same
# shape bin/clock-sync.sh uses). Never a non-zero exit — update-runners and
# bootstrap have their own contracts and this must not change them.
#
# KILL SWITCHES: AUDIT_INSTALL=0 in env/global.env, or the settings row
# switch.audit-off[.<box>] (flags/audit-off when no row). Both stop
# the INSTALL path before it writes anything of its own. --render and --check still answer
# under either one and say which is on: a silent rc 0 from --check would read as
# a healthy box.
#
# NOT `set -e`: every failure branch has to reach its own log line, and errexit
# would take the process out before it got there.
set -uo pipefail

# cron's PATH is /usr/bin:/bin, and auditctl/auditd/augenrules live in sbin. Test
# seam: AUDIT_SBIN_PATH="" leaves PATH alone, so a suite can drive the "auditctl
# is not installed" box on a machine that happens to have auditd. Deliberately
# not in env-templates/global.env.example — it is for tests, not for operators.
PATH="$PATH${AUDIT_SBIN_PATH-:/usr/sbin:/sbin}"

H="${HARNESS:-/root/harness}"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
if [ -f "$HENV/global.env" ]; then set -a; # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env"; set +a; fi
# Below the env load, so lane-gate.sh fills its LANE_GATE_* defaults after global.env.
# shellcheck source=lib/lane-switch.sh
. "$H/bin/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$H/flags/$1" ]; }   # no lib: the file, as before

MODE_ARG="${1:-}"

ROOTS="${AUDIT_ROOTS:-/root/harness /root/orchestrator /etc/harness /root/.ssh}"
LOG_MB="${AUDIT_LOG_MB:-50}"      # knob AUDIT_LOG_MB (env/global.env); 50 x 5 = 250M (BH-9173)
LOG_KEEP="${AUDIT_LOG_KEEP:-5}"   # knob AUDIT_LOG_KEEP
STALE_H="${AUDIT_STALE_H:-6}"     # knob AUDIT_STALE_H: hours without a write before audit.log is STALE
PROBE_WAIT="${AUDIT_PROBE_WAIT_S:-5}"  # knob AUDIT_PROBE_WAIT_S: seconds the probe waits for its record
# A non-number would make the probe's `[ -ge ]` fail on every pass and loop forever.
case "$STALE_H" in ''|*[!0-9]*) STALE_H=6 ;; esac
case "$PROBE_WAIT" in ''|*[!0-9]*) PROBE_WAIT=5 ;; esac
RULES_FILE="${AUDIT_RULES_FILE:-/etc/audit/rules.d/harness.rules}"
CONF="${AUDITD_CONF:-/etc/audit/auditd.conf}"
SUPDIR="${AUDIT_SUPERVISOR_DIR:-/etc/supervisor/conf.d}"
SYSDIR="${AUDIT_SYSTEMD_DIR:-/run/systemd/system}"
LOG="$H/logs/audit-install.log"
ALERTS="$H/logs/ALERTS.log"

# The roots that exist, trailing `/` stripped, in $ROOTS order. The kernel
# refuses `-F dir=` on a missing path (project-3-2 has no /root/orchestrator), so a
# missing root is never rendered. EXPECT is the number of `-k harness` rules the
# render produces, and therefore how many the kernel must report back. An EMPTY
# AUDIT_ROOTS falls to the default above rather than to a zero-rule file.
HN="${H%/}"
LIVE_ROOTS=""; EXPECT=0
for _r in $ROOTS; do
  [ "$_r" = / ] || _r="${_r%/}"
  [ -d "$_r" ] || continue
  LIVE_ROOTS="$LIVE_ROOTS${LIVE_ROOTS:+ }$_r"; EXPECT=$((EXPECT + 1))
done
FIRST_ROOT="${LIVE_ROOTS%% *}"

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) audit-install: $*" >> "$LOG"; }

# One ALERTS line a day, whatever the class. Marker FIRST, then the line: a crash
# between them costs a line, never a duplicate (bin/clock-sync.sh:101-107).
alert_once() { # alert_once <reason> <what is needed>
  say "$1"
  local mark="$H/state/audit-install-denied-$(date -u +%Y%m%d)"
  [ -f "$mark" ] && return 0
  mkdir -p "$H/state" "$H/logs" 2>/dev/null
  touch "$mark" 2>/dev/null
  echo "$(STAMP) [audit-install] $1 NEEDED FROM OPERATOR/OPS: $2" >> "$ALERTS"
}

# The rules file, and nothing else. A pure function of $ROOTS and of which of
# those dirs exist: no clock, no hostname — that is what makes it byte-stable,
# and what lets --check compare the installed file against a fresh render.
# The `never` rules come FIRST (the kernel takes the first match): the rename
# churn of atomic tmp+mv writes under state/ logs/ locks/ tmp/, and the unlink
# churn under locks/ and tmp/. unlink/rmdir under state/ logs/ builds/ bin/ env/
# prompts/ cron/ stays recorded: a wipe ends in the rmdir of each top-level dir.
# No `-e 2` and no `-f 2` (immutability is its own ticket), and no chattr.
render_rules() {
  echo "# /etc/audit/rules.d/harness.rules — written by bin/audit-install.sh (BH-395 / BH-443 / BH-9173)."
  echo "# Delete, rename and truncate syscalls under each existing harness root get a kernel audit"
  echo "# record keyed 'harness'. Do not hand-edit: the installer rewrites it whenever it differs."
  local r d
  case " $LIVE_ROOTS " in
    *" $HN "*)
      for d in state logs locks tmp; do
        [ -d "$HN/$d" ] && echo "-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$HN/$d"
      done
      for d in locks tmp; do
        [ -d "$HN/$d" ] && echo "-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=$HN/$d"
      done ;;
  esac
  for r in $LIVE_ROOTS; do
    echo "-a always,exit -F arch=b64 -S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate -F dir=$r -k harness"
  done
  return 0
}

daemon_mode() {
  if   [ -d "$SYSDIR" ]; then echo systemd
  elif [ -d "$SUPDIR" ]; then echo supervisord
  else echo bare; fi
}

daemon_running() {
  if [ -d "$SYSDIR" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet auditd 2>/dev/null && return 0
  fi
  pgrep -x auditd >/dev/null 2>&1
}

# Count by KEY, never by path: /root/harness is itself a watched root, so a
# `grep -c harness` over `auditctl -l` also counts any rule that merely mentions
# the path under somebody else's key. The never rules carry no key and so are
# not counted.
loaded_count() {
  auditctl -l 2>/dev/null | grep -cE '(-k|key=) ?harness$' || true
}

# ── is the trail alive? (BH-9173) ───────────────────────────────────────────
# "daemon running + rules loaded" is not health: a SUSPENDed auditd is both.
audit_log_path() {
  if [ -n "${AUDIT_LOG_PATH:-}" ]; then echo "$AUDIT_LOG_PATH"; return 0; fi
  local p=""
  [ -f "$CONF" ] && p=$(sed -nE 's/^[[:space:]]*log_file[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$CONF" 2>/dev/null | tail -n 1)
  echo "${p:-/var/log/audit/audit.log}"
}

# trail_stale -> rc 0 when the log is absent or older than STALE_H hours. It
# sets AGE_H (hours, or "absent"). Measured BEFORE the probe: a probe that
# works writes the log and would hide the age.
AGE_H=""
trail_stale() {
  local f m now
  f=$(audit_log_path)
  if ! m=$(stat -c %Y "$f" 2>/dev/null); then AGE_H=absent; return 0; fi
  now="${AUDIT_NOW:-$(date +%s)}"   # AUDIT_NOW: test seam (epoch seconds), not an operator knob
  AGE_H=$(( (now - m) / 3600 ))
  [ $(( now - m )) -gt $(( STALE_H * 3600 )) ]
}
stale_line() { # the --check / log line for the age
  if [ "$AGE_H" = absent ]; then echo "audit.log: STALE ($(audit_log_path) absent, AUDIT_STALE_H=$STALE_H)"
  else echo "audit.log: STALE ${AGE_H}h (AUDIT_STALE_H=$STALE_H)"; fi
}

stale_alert() {
  alert_once "$(stale_line): no record written while rules are loaded" \
    "auditd stopped recording on this box; check the disk, auditd.conf *_action keys and the auditd status, then restart auditd"
}

# probe_once <root> <n> -> rc 0 recorded, 1 not recorded, 2 could not write the file
probe_once() {
  local f="$1/.audit-probe.$$.$2" i=1
  ( : > "$f" ) 2>/dev/null || return 2
  rm -f "$f" 2>/dev/null
  while :; do
    ausearch -k harness -f "$f" -ts recent >/dev/null 2>&1 && return 0
    [ "$i" -ge "$PROBE_WAIT" ] && return 1
    i=$((i + 1)); sleep 1
  done
}

# probe_trail -> rc 0 recorded (PROBE says how), 1 dead, 2 could not write, 3 skipped.
# A miss gets ONE `auditctl --signal resume` and one more probe; the second
# probe, never the resume's own rc, is the judge.
PROBE=""
probe_trail() {
  if ! command -v ausearch >/dev/null 2>&1; then PROBE="skipped (ausearch not installed)"; return 3; fi
  probe_once "$FIRST_ROOT" 1; local rc=$?
  case "$rc" in
    0) PROBE="recorded"; return 0 ;;
    2) PROBE="could not write $FIRST_ROOT"; return 2 ;;
  esac
  auditctl --signal resume >/dev/null 2>&1
  if probe_once "$FIRST_ROOT" 2; then
    PROBE="recorded after resume"
    say "auditd was suspended; resumed (probe recorded)"
    return 0
  fi
  PROBE="NOT recorded"
  alert_once "audit trail DEAD: probe not recorded after resume" \
    "auditd records nothing on this box although the rules are loaded; read /var/log/audit and the auditd status (disk full, SUSPEND, lost backlog) and restart auditd"
  return 1
}

usage() {
  echo "usage: audit-install.sh [--render|--check]"
  echo "  (no argument)  install/repair: package, rules file, auditd.conf knobs, daemon, load, verify"
  echo "  --render       print the rules file to stdout    --check  print state, rc 1 when something is off"
}

# --check writes nothing on a box with no auditctl or no harness rules loaded.
# With rules loaded it proves the trail is alive (BH-9173): it reads the age of
# audit.log, then writes and removes one probe file under the first root and
# asks ausearch for its record. A miss sends `auditctl --signal resume` and
# probes again. A stale log or a dead trail is rc 1 plus one alert_once (log
# line, day marker, ALERTS line): a SUSPENDed daemon looks "running + loaded".
do_check() {
  local rc=0 mode loaded
  if command -v auditctl >/dev/null 2>&1; then echo "auditctl: installed"
  else echo "auditctl: NOT installed"; rc=1; fi

  if [ "$EXPECT" -eq 0 ]; then echo "harness roots: none exist (AUDIT_ROOTS=$ROOTS)"; rc=1
  else
    # shellcheck disable=SC2086
    set -- $ROOTS; echo "harness roots: $EXPECT of $# exist"
  fi

  if [ -f "$RULES_FILE" ]; then
    if render_rules | cmp -s - "$RULES_FILE"; then
      echo "harness rules: present ($(grep -c -- '-k harness$' "$RULES_FILE") always, $(grep -c '^-a never,exit' "$RULES_FILE") never)"
    else
      echo "harness rules: DIFFERS from --render"; rc=1
    fi
  else
    echo "harness rules: absent"; rc=1
  fi

  mode=$(daemon_mode)
  if daemon_running; then echo "daemon ($mode): running"
  else echo "daemon ($mode): not running"; rc=1; fi

  loaded=$(loaded_count)
  echo "loaded harness rules: $loaded (expected $EXPECT)"
  [ "$loaded" -ge "$EXPECT" ] || rc=1

  # Stale first, then the probe (the probe refreshes the log's mtime).
  if ! command -v auditctl >/dev/null 2>&1; then echo "probe: skipped (auditctl not installed)"
  elif [ "$loaded" -eq 0 ] || [ "$EXPECT" -eq 0 ]; then echo "probe: skipped (no harness rules loaded)"
  else
    if trail_stale; then
      stale_line; rc=1
      stale_alert
    else echo "audit.log: written ${AGE_H}h ago"; fi
    probe_trail; case $? in 1) rc=1 ;; esac
    echo "probe: $PROBE"
  fi

  # The switch is answered from the settings cache as it stands: no refresh and
  # no lane-gate.log line, in a subshell.
  if [ "${AUDIT_INSTALL:-1}" = 0 ]; then echo "kill switch: AUDIT_INSTALL=0"
  else
    ( LANE_SWITCH_SRC=
      _lg_settings_refresh() { :; }
      _lg_log_throttled() { :; }
      if lane_switch audit-off file; then
        case "${LANE_SWITCH_SRC:-legacy}" in
          box-row)   echo "kill switch: settings switch.audit-off.$(_lg_box | tr '[:upper:]' '[:lower:]')" ;;
          fleet-row) echo "kill switch: settings switch.audit-off" ;;
          *)         echo "kill switch: flags/audit-off" ;;
        esac
      else echo "kill switch: none"; fi )
  fi
  return "$rc"
}

case "$MODE_ARG" in
  --render) render_rules; exit 0 ;;
  # `do_check ` with a trailing space on purpose. tests/context-budget-manifest-test.sh
  # proves every bin/ function named *_check/*_guard/*_hit is actually called in
  # its own file, and its call pattern only matches a call followed by a space or
  # a quote — `do_check;` reads to it as a function defined and never used.
  --check)  do_check || exit $?
            exit 0 ;;
  '')       : ;;
  *)        usage >&2; exit 2 ;;
esac

# ── the install path ────────────────────────────────────────────────────────
# Switches first, before any mkdir or log write of this script's own: off must
# cost nothing here. The switch read may refresh the shared settings cache.
[ "${AUDIT_INSTALL:-1}" = 0 ] && exit 0
lane_switch audit-off file && exit 0

# Nothing to watch is not "rules loaded, n=0".
if [ "$EXPECT" -eq 0 ]; then
  alert_once "no audit root exists (AUDIT_ROOTS=$ROOTS)" \
    "none of the audit roots is a directory on this box; set AUDIT_ROOTS in env/global.env to the harness roots that exist"
  exit 0
fi

CHANGED=0

# 1. the package
if ! command -v auditctl >/dev/null 2>&1; then
  mkdir -p "$H/logs" 2>/dev/null
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -q auditd >>"$LOG" 2>&1; then
    alert_once "apt-get install auditd FAILED" \
      "apt cannot install auditd on this box; add auditd to the box image or fix apt here"
    exit 0
  fi
  CHANGED=1
  say "auditd installed (apt-get)"
fi

# 2. the rules file — written only when it differs, and moved into place atomically
mkdir -p "$(dirname "$RULES_FILE")" 2>/dev/null
RTMP="$RULES_FILE.tmp"
if ! render_rules > "$RTMP" 2>/dev/null; then
  rm -f "$RTMP"
  alert_once "cannot write $RULES_FILE" \
    "this box refuses writes under $(dirname "$RULES_FILE"); check the mount and the permissions"
  exit 0
fi
if cmp -s "$RTMP" "$RULES_FILE"; then
  rm -f "$RTMP"
elif mv "$RTMP" "$RULES_FILE"; then
  CHANGED=1; say "rules file written ($EXPECT harness rules) -> $RULES_FILE"
else
  # A failed move leaves whatever was there before. Carrying on would load the
  # OLD rules and then report them as this run's success.
  rm -f "$RTMP"
  alert_once "could not install $RULES_FILE" \
    "this box refuses writes under $(dirname "$RULES_FILE"); check the mount and the permissions"
  exit 0
fi

# 3. the rotation knobs. These six keys ARE the bound on /var/log/audit, and every
# disk-pressure action is ROTATE: SUSPEND stops recording silently (project-3-2,
# 2026-11-04, BH-9173), and a dead trail is worse than an old record lost. sed
# the key where it exists (commented or not), append it where it does not — a
# key this box never had is a bound that was never applied.
set_conf() { # set_conf <key> <value>  -> rc 0 when it changed the file
  local k="$1" v="$2"
  [ -f "$CONF" ] || : > "$CONF" 2>/dev/null || return 1
  if grep -qE "^[#[:space:]]*${k}[[:space:]]*=" "$CONF"; then
    grep -qE "^${k}[[:space:]]*=[[:space:]]*${v}\$" "$CONF" && return 1
    sed -i -E "s|^[#[:space:]]*${k}[[:space:]]*=.*|$k = $v|" "$CONF" || return 1
  else
    printf '%s = %s\n' "$k" "$v" >> "$CONF" || return 1
  fi
  return 0
}
mkdir -p "$(dirname "$CONF")" 2>/dev/null
CONF_CHANGED=0
for KV in "max_log_file:$LOG_MB" "num_logs:$LOG_KEEP" "max_log_file_action:ROTATE" \
          "space_left_action:SYSLOG" "admin_space_left_action:ROTATE" "disk_full_action:ROTATE"; do
  set_conf "${KV%%:*}" "${KV#*:}" && CONF_CHANGED=1
done
if [ "$CONF_CHANGED" = 1 ]; then
  CHANGED=1
  say "auditd.conf rotation bounded (max_log_file=$LOG_MB num_logs=$LOG_KEEP, ROTATE on full and low disk)"
fi

# 4. the daemon, by whatever this box runs
MODE=$(daemon_mode)
WAS_UP=0; daemon_running && WAS_UP=1
case "$MODE" in
  systemd)
    if [ "$WAS_UP" = 0 ]; then
      if ! systemctl enable --now auditd >>"$LOG" 2>&1; then
        alert_once "systemctl enable --now auditd FAILED" \
          "auditd will not start under systemd on this box; check the container's audit capability or run auditd on the host"
        exit 0
      fi
      CHANGED=1
    fi
    ;;
  supervisord)
    # Same shape as the cron program bin/bootstrap-machine.sh registers.
    SUPCONF="$SUPDIR/auditd.conf"; STMP="$SUPCONF.tmp"
    printf '[program:auditd]\ncommand=/sbin/auditd -n\nautostart=true\nautorestart=true\nstdout_logfile=/var/log/auditd-supervisor.log\nstderr_logfile=/var/log/auditd-supervisor.log\n' > "$STMP" 2>/dev/null
    if cmp -s "$STMP" "$SUPCONF"; then
      rm -f "$STMP"
    elif mv "$STMP" "$SUPCONF"; then
      CHANGED=1; say "supervisord program auditd written -> $SUPCONF"
    else
      rm -f "$STMP"
      alert_once "could not write $SUPCONF" \
        "this box refuses writes under $SUPDIR; check the mount and the permissions, or point AUDIT_SUPERVISOR_DIR at the real one"
      exit 0
    fi
    if ! { supervisorctl reread >>"$LOG" 2>&1 && supervisorctl update >>"$LOG" 2>&1; }; then
      alert_once "supervisorctl reread/update FAILED" \
        "auditd will not start under supervisord on this box; check the container's audit capability or run auditd on the host"
      exit 0
    fi
    # `update` is a no-op for an unchanged program that is STOPPED, so the
    # explicit start is what actually runs it. An already-running program
    # answers "already started", which is the state we wanted.
    if ! SUPOUT=$(supervisorctl start auditd 2>&1); then
      case "$SUPOUT" in
        *"already started"*|*"ALREADY STARTED"*) : ;;
        *) alert_once "supervisorctl start auditd FAILED: $(printf '%s' "$SUPOUT" | head -n 1)" \
             "auditd will not start under supervisord on this box; check the container's audit capability or run auditd on the host"
           exit 0 ;;
      esac
    fi
    [ "$WAS_UP" = 0 ] && CHANGED=1
    ;;
  bare)
    if [ "$WAS_UP" = 0 ]; then
      if ! auditd >>"$LOG" 2>&1; then
        alert_once "auditd would not start (no systemd, no supervisord)" \
          "auditd will not start on this box; check the container's audit capability or run auditd on the host"
        exit 0
      fi
      CHANGED=1
    fi
    ;;
esac
if ! daemon_running; then
  alert_once "auditd is NOT running after start (daemon=$MODE)" \
    "auditd will not stay up under $MODE on this box; check the container's audit capability or run auditd on the host"
  exit 0
fi
# New rotation knobs only reach a daemon that re-reads its config.
[ "$CONF_CHANGED" = 1 ] && [ "$WAS_UP" = 1 ] && pkill -HUP -x auditd >/dev/null 2>&1

# 5. load the rules — augenrules first, auditctl -R as the fallback. -R only
# ADDS: it would keep the old `-w ... -k harness` watches and answer "Rule
# exists" on a never rule already in the kernel. So drop every harness-keyed
# rule and each of our never rules first (errors ignored: absent is fine).
LOAD_OUT=$(augenrules --load 2>&1); LOAD_RC=$?
if [ "$LOAD_RC" != 0 ]; then
  auditctl -D -k harness >/dev/null 2>&1
  while IFS= read -r NL; do
    # shellcheck disable=SC2086
    auditctl -d ${NL#-a } >/dev/null 2>&1
  done < <(grep '^-a never,exit ' "$RULES_FILE" 2>/dev/null)
  ALT_OUT=$(auditctl -R "$RULES_FILE" 2>&1); ALT_RC=$?
  if [ "$ALT_RC" != 0 ]; then
    BOTH="$LOAD_OUT
$ALT_OUT"
    printf '%s\n' "$BOTH" >> "$LOG"
    FIRST=$(printf '%s\n' "$BOTH" | grep -v '^[[:space:]]*$' | head -n 1)
    # Narrow on purpose (D10). "Rule exists", a syntax error in the rules file
    # and `augenrules: command not found` are NOT permission problems, and
    # telling the operator to go ask for CAP_AUDIT_CONTROL over one of them wastes the
    # only alert this script gets to send today.
    case "$BOTH" in
      *"Operation not permitted"*|*EPERM*|*"Permission denied"*|*"already in use"*|*netlink*)
        alert_once "audit socket DENIED (kernel: $FIRST)" \
          "this container's kernel audit socket is not permitted / owned elsewhere; run the box with audit access or install auditd on the host" ;;
      *)
        alert_once "rules load FAILED (rc=$ALT_RC): $FIRST" \
          "augenrules/auditctl refused the rules for a non-permission reason (logs/audit-install.log); read the rules file and the kernel message" ;;
    esac
    exit 0
  fi
fi

# 6. verify against the kernel's own answer, then against a real record, and
# only then say anything succeeded
LOADED=$(loaded_count)
if [ "$LOADED" != "$EXPECT" ]; then
  say "rules NOT loaded: expected=$EXPECT loaded=$LOADED (daemon=$MODE)"
  exit 0
fi
# Stale first: the probe writes the log. A run that just started the daemon
# logs a stale log and lets the probe judge (a fresh box has no recent log).
if trail_stale; then
  if [ "$WAS_UP" = 1 ]; then
    stale_alert
  else
    say "$(stale_line) (daemon started by this run; the probe decides)"
  fi
fi
probe_trail; PRC=$?
[ "$PRC" = 3 ] && say "probe: $PROBE"
if [ "$PRC" = 1 ]; then
  say "trail DEAD (probe not recorded after resume): expected=$EXPECT loaded=$LOADED daemon=$MODE"
elif [ "$PRC" = 2 ]; then
  say "rules in the kernel n=$LOADED, daemon=$MODE; trail not verified: probe $PROBE"
elif [ "$CHANGED" = 1 ]; then
  say "rules loaded, n=$LOADED, daemon=$MODE"
else
  say "no change (rules loaded, n=$LOADED, daemon=$MODE)"
fi
exit 0
