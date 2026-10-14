#!/bin/bash
# tests/audit-install.bh-443-test.sh — bin/audit-install.sh against a scratch
# harness tree, with auditctl/augenrules/auditd/apt-get/supervisorctl stubbed on
# PATH. Nothing here installs a package, writes /etc/audit, or touches the
# kernel's audit socket: every path the script writes is redirected into $T.
#
# WHY THE SCRIPT EXISTS (hub wipe #388, 2026-09-15). /root/harness/{env,bin,
# prompts,logs,builds} vanished at 16:50Z and nothing on the box could say who
# did it. bin/audit-install.sh is the leg that makes the kernel write that line:
# auditd installed, one rules file watching the harness roots for `wa` under key
# `harness`, rotation bounded, loaded and verified. The tailer that READS those
# records is BH-444 and is deliberately not referenced from here.
#
# What is proved here:
#   1. `--render` is byte-stable and is exactly the 3-line header + one
#      `-w <root> -p wa -k harness` per root — no -e 2, no -f 2, no chattr;
#   2. `--check` on a box with no auditctl says `NOT installed`, answers rc 1,
#      and writes NOTHING; a bogus argument is usage + rc 2, also writing
#      nothing;
#   3. both kill switches stop the install path dead — no log, no apt;
#   4. a kernel that refuses the rules is ONE actionable ALERTS line per day,
#      never a "loaded" claim, and the classifier does not call a plain
#      "Rule exists" a permission problem;
#   5. the happy path writes the rules file and the rotation knobs, says
#      `rules loaded, n=4`, and the run after it says `no change`; a loaded
#      count short of the roots is `rules NOT loaded`, never success;
#   6. the two production call sites (update-runners, bootstrap-machine) and
#      the bootstrap UTC step are present, written so an absent symbol FAILS.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-443-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin" "$T/fakectl" "$T/fakebin-empty" "$T/h/bin" "$T/h/env" "$T/etc"
if [ ! -f "$DIR/bin/audit-install.sh" ]; then
  bad "bin/audit-install.sh does not exist"
  echo "audit-install: $PASS passed, $FAIL failed"
  exit 1
fi
cp "$DIR/bin/audit-install.sh" "$T/h/bin/"; chmod +x "$T/h/bin/audit-install.sh"
S="$T/h/bin/audit-install.sh"

# --- the stubs ---------------------------------------------------------------
# auditctl lives in its own directory so a test can take it off PATH (the "not
# installed" box) while keeping apt-get and the rest.
stub() { # stub <dir> <name> <body...>
  local d="$1" n="$2"; shift 2
  { echo '#!/bin/bash'; echo "T=\"$T\""; printf '%s\n' "$@"; } > "$d/$n"
  chmod +x "$d/$n"
}
# -l prints whatever the case under test seeded; -R fails with $T/deny-msg when
# $T/deny exists, which is how a kernel refusal is driven.
stub "$T/fakectl" auditctl \
  'echo "$*" >> "$T/auditctl.calls"' \
  'case "${1:-}" in' \
  '  -l) [ -f "$T/loaded" ] && cat "$T/loaded"; exit 0 ;;' \
  '  -R) if [ -f "$T/deny" ]; then cat "$T/deny-msg" >&2; exit 1; fi; exit 0 ;;' \
  'esac' \
  'exit 0'
stub "$T/fakebin" augenrules \
  'echo "$*" >> "$T/augenrules.calls"' \
  'if [ -f "$T/deny" ]; then cat "$T/deny-msg" >&2; exit 1; fi' \
  'exit 0'
stub "$T/fakebin" auditd 'echo "$*" >> "$T/auditd.calls"; exit 0'
stub "$T/fakebin" pgrep  '[ -f "$T/running" ] && exit 0; exit 1'
stub "$T/fakebin" pkill  'echo "$*" >> "$T/pkill.calls"; exit 0'
stub "$T/fakebin" apt-get 'echo "$*" >> "$T/apt.calls"; exit 0'
stub "$T/fakebin" supervisorctl 'echo "$*" >> "$T/supervisorctl.calls"; exit 0'
stub "$T/fakebin" systemctl 'echo "$*" >> "$T/systemctl.calls"; exit 0'

REDIR=(HARNESS="$T/h"
       AUDIT_RULES_FILE="$T/etc/harness.rules"
       AUDITD_CONF="$T/etc/auditd.conf"
       AUDIT_SUPERVISOR_DIR="$T/nosup"
       AUDIT_SYSTEMD_DIR="$T/nosys"
       AUDIT_SBIN_PATH="")
FULLPATH="$T/fakectl:$T/fakebin:/usr/bin:/bin"
run()    { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S"; }
render() { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S" --render; }
LOG="$T/h/logs/audit-install.log"
ALERTS="$T/h/logs/ALERTS.log"
reset() {
  rm -rf "$T/h/logs" "$T/h/state" "$T/h/flags"
  mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags"
  rm -f "$T/etc/harness.rules" "$T/etc/auditd.conf" "$T/apt.calls" "$T/deny" \
        "$T/deny-msg" "$T/loaded" "$T/running" "$T/auditctl.calls" \
        "$T/augenrules.calls" "$T/supervisorctl.calls" "$T/auditd.calls"
  rm -rf "$T/sup"
  : > "$T/h/env/global.env"
}
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
# grep -c on a file that does not exist prints nothing and exits 2, which turns
# every count assertion into a bash syntax error instead of a FAIL line.
cnt() { # cnt <pattern> <file>
  [ -f "$2" ] || { echo 0; return 0; }
  grep -c -- "$1" "$2" 2>/dev/null || true
}

# ── 1. --render: byte-stable, and exactly the rules the ticket asked for ─────
reset
render > "$T/r1" 2>"$T/r1.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "--render must exit 0 (rc=$RC, $(cat "$T/r1.err"))"
render HOSTNAME=other TZ=America/Chicago > "$T/r2" 2>/dev/null
cmp -s "$T/r1" "$T/r2" && ok || bad "--render must be byte-stable across runs: $(diff "$T/r1" "$T/r2")"
[ "$(grep -c '^-w ' "$T/r1")" -eq 4 ] && ok || bad "--render must print 4 watch lines: $(cat "$T/r1")"
[ "$(grep -c -- ' -p wa -k harness$' "$T/r1")" -eq 4 ] && ok \
  || bad "every watch line must end ' -p wa -k harness': $(cat "$T/r1")"
GOT=$(grep '^-w ' "$T/r1" | awk '{print $2}' | tr '\n' ' ')
[ "$GOT" = "/root/harness /root/orchestrator /etc/harness /root/.ssh " ] && ok \
  || bad "the four default roots, in order, are the watch set: got '$GOT'"
[ "$(grep -c -- '-e 2' "$T/r1")" -eq 0 ] && ok || bad "-e 2 is the immutability ticket, not this one"
[ "$(grep -c -- '-f 2' "$T/r1")" -eq 0 ] && ok || bad "-f 2 is out of scope for this slice"
[ "$(grep -c chattr "$T/r1")" -eq 0 ] && ok || bad "chattr has no business in the rules file"
[ "$(head -n 3 "$T/r1" | grep -c '^#')" -eq 3 ] && ok || bad "the render opens with a 3-line comment header: $(head -n 3 "$T/r1")"
[ "$(head -n 3 "$T/r1" | grep -c 'audit-install.sh')" -ge 1 ] && ok || bad "the header must name the script that wrote the file"
render AUDIT_ROOTS="/a /b" > "$T/r3" 2>/dev/null
[ "$(grep -c '^-w ' "$T/r3")" -eq 2 ] && ok || bad "AUDIT_ROOTS=\"/a /b\" must render 2 watch lines: $(cat "$T/r3")"
[ "$(grep -c '^-w /a -p wa -k harness$' "$T/r3")" -eq 1 ] && ok || bad "AUDIT_ROOTS must drive the watch paths: $(cat "$T/r3")"
[ "$(grep -c audit-tail "$DIR/bin/audit-install.sh")" -eq 0 ] && ok \
  || bad "the tailer (BH-444) must not be referenced from the installer"

# ── 2. --check on a box with no auditctl, and a bogus argument ───────────────
reset
BEFORE=$(find "$T/h" | sort)
OUT=$(env PATH="$T/fakebin-empty:/usr/bin:/bin" "${REDIR[@]}" bash "$S" --check 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "--check with no auditctl must answer rc 1 (rc=$RC): $OUT"
grep -qi 'not installed' <<<"$OUT" && ok || bad "--check must say the package is not installed: $OUT"
grep -q 'loaded harness rules: 0 (expected 4)' <<<"$OUT" && ok \
  || bad "--check must print the loaded count against the expected one: $OUT"
grep -q 'kill switch: none' <<<"$OUT" && ok || bad "--check must report the kill switches: $OUT"
[ "$(find "$T/h" | sort)" = "$BEFORE" ] && ok || bad "--check must write NOTHING: $(diff <(printf '%s\n' "$BEFORE") <(find "$T/h" | sort))"
# a kill switch does not silence --check: a silent rc 0 would read as healthy
printf 'AUDIT_INSTALL=0\n' > "$T/h/env/global.env"
OUT=$(env PATH="$T/fakebin-empty:/usr/bin:/bin" "${REDIR[@]}" bash "$S" --check 2>&1); RC=$?
grep -q 'kill switch: AUDIT_INSTALL=0' <<<"$OUT" && ok || bad "--check must still answer under a kill switch: $OUT"
: > "$T/h/env/global.env"
BEFORE=$(find "$T/h" | sort)
ERR=$(env PATH="$FULLPATH" "${REDIR[@]}" bash "$S" bogus 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 2 ] && ok || bad "an unknown argument must exit 2 (rc=$RC)"
grep -q 'usage' <<<"$ERR" && ok || bad "an unknown argument must print usage on stderr: $ERR"
[ "$(find "$T/h" | sort)" = "$BEFORE" ] && ok || bad "a usage error must write nothing"

# ── 3. the kill switches stop the install path dead ─────────────────────────
# auditctl is OFF this PATH on purpose: without a switch the script would reach
# for apt-get, and $T/apt.calls is what proves it never did.
NOCTL="$T/fakebin:/usr/bin:/bin"
reset
printf 'AUDIT_INSTALL=0\n' > "$T/h/env/global.env"
env PATH="$NOCTL" "${REDIR[@]}" bash "$S" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "AUDIT_INSTALL=0 must exit 0 (rc=$RC)"
[ -f "$LOG" ] && bad "AUDIT_INSTALL=0 must cost nothing at all, not even a log line" || ok
[ -f "$T/apt.calls" ] && bad "AUDIT_INSTALL=0 must not reach apt-get: $(cat "$T/apt.calls")" || ok
reset
touch "$T/h/flags/audit-off"
env PATH="$NOCTL" "${REDIR[@]}" bash "$S" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "flags/audit-off must exit 0 (rc=$RC)"
[ -f "$LOG" ] && bad "flags/audit-off must cost nothing at all" || ok
[ -f "$T/apt.calls" ] && bad "flags/audit-off must not reach apt-get" || ok

# ── 4. the kernel refuses: ONE actionable alert a day, never a success line ──
reset
touch "$T/running"; touch "$T/deny"; echo "Operation not permitted" > "$T/deny-msg"
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a denied load must still exit 0 for cron (rc=$RC)"
[ "$(cnt . "$LOG")" -ge 1 ] && ok || bad "a denied load must be recorded in logs/audit-install.log"
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok \
  || bad "a denied load must alert exactly once: $(cat "$ALERTS" 2>/dev/null)"
grep -q 'NEEDED FROM' "$ALERTS" && ok || bad "the alert must name what is needed and from whom: $(cat "$ALERTS")"
grep -q 'kernel audit socket' "$ALERTS" && ok || bad "a permission refusal is the kernel class: $(cat "$ALERTS")"
[ "$(find "$T/h/state" -name 'audit-install-denied-*' | wc -l)" -eq 1 ] && ok \
  || bad "exactly one denied marker per day: $(find "$T/h/state" -name 'audit-install-denied-*')"
grep -q 'rules loaded, n=' "$LOG" && bad "a denied load must never claim the rules are loaded: $(cat "$LOG")" || ok
LINES1=$(cnt . "$LOG")
run >/dev/null 2>&1
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok \
  || bad "the marker must dedupe the alert on the second run: $(cat "$ALERTS")"
[ "$(cnt . "$LOG")" -gt "$LINES1" ] && ok || bad "the second run must still say something in its own log"

# 4b. the classifier's negative: "Rule exists" is a load failure, not a refusal
reset
touch "$T/running"; touch "$T/deny"
echo "Error sending add rule data request (Rule exists)" > "$T/deny-msg"
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a rules-load failure must still exit 0 (rc=$RC)"
grep -q 'kernel audit socket' "$ALERTS" && bad "'Rule exists' is not a permission problem: $(cat "$ALERTS")" || ok
lastlog | grep -q 'rules load FAILED' && ok || bad "'Rule exists' must be logged as a load failure: $(lastlog)"
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok \
  || bad "a load failure still earns one alert: $(cat "$ALERTS" 2>/dev/null)"

# ── 5. the happy path (bare daemon), its idempotence, and a short count ─────
reset
touch "$T/running"
# The fifth line is a watch on a harness path under ANOTHER key: counting by
# path instead of by key would read it as a harness rule and report 5.
cat > "$T/loaded" <<'RULES'
-w /root/harness -p wa -k harness
-w /root/orchestrator -p wa -k harness
-w /etc/harness -p wa -k harness
-w /root/.ssh -p wa -k harness
-w /root/harness/builds -p wa -k someone-else
RULES
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "the happy path must exit 0 (rc=$RC): $(cat "$LOG" 2>/dev/null)"
lastlog | grep -q 'rules loaded, n=4, daemon=bare' && ok || bad "the success line names the count and the daemon mode: $(lastlog)"
render > "$T/expect-rules" 2>/dev/null
cmp -s "$T/expect-rules" "$T/etc/harness.rules" && ok \
  || bad "the installed rules file must equal --render: $(diff "$T/expect-rules" "$T/etc/harness.rules" 2>&1)"
for KV in "max_log_file = 100" "num_logs = 10" "max_log_file_action = ROTATE" \
          "space_left_action = SYSLOG" "disk_full_action = SUSPEND"; do
  grep -qx "$KV" "$T/etc/auditd.conf" && ok || bad "auditd.conf must carry '$KV': $(cat "$T/etc/auditd.conf" 2>/dev/null)"
done
[ -f "$ALERTS" ] && bad "a working install is not an alert: $(cat "$ALERTS")" || ok
# second run: nothing to do, and it says so
run >/dev/null 2>&1
lastlog | grep -q 'no change (rules loaded, n=4, daemon=bare)' && ok || bad "the run after a successful install must say 'no change': $(lastlog)"
cmp -s "$T/expect-rules" "$T/etc/harness.rules" && ok || bad "the second run must not rewrite the rules file"
[ -f "$ALERTS" ] && bad "an unchanged box is not an alert" || ok
# the knobs are knobs
reset; touch "$T/running"; cp /dev/null "$T/loaded"
printf -- '-w /a -p wa -k harness\n' > "$T/loaded"
run AUDIT_ROOTS="/a" AUDIT_LOG_MB=25 AUDIT_LOG_KEEP=3 >/dev/null 2>&1
lastlog | grep -q 'rules loaded, n=1, daemon=bare' && ok || bad "AUDIT_ROOTS must drive the expected count: $(lastlog)"
grep -qx 'max_log_file = 25' "$T/etc/auditd.conf" && ok || bad "AUDIT_LOG_MB must reach auditd.conf: $(cat "$T/etc/auditd.conf")"
grep -qx 'num_logs = 3' "$T/etc/auditd.conf" && ok || bad "AUDIT_LOG_KEEP must reach auditd.conf: $(cat "$T/etc/auditd.conf")"
# a short load is never reported as installed
reset; touch "$T/running"
printf -- '-w /root/harness -p wa -k harness\n-w /root/orchestrator -p wa -k harness\n-w /etc/harness -p wa -k harness\n' > "$T/loaded"
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "a short load must still exit 0 (rc=$RC)"
lastlog | grep -q 'rules NOT loaded: expected=4 loaded=3' && ok || bad "a short load must say so: $(lastlog)"
[ "$(cnt 'rules loaded, n=' "$LOG")" -eq 0 ] && ok || bad "a short load must never claim success: $(cat "$LOG")"

# 5b. supervisord mode registers the program the way the cron block does
reset
mkdir -p "$T/sup"; touch "$T/running"
printf -- '-w /root/harness -p wa -k harness\n-w /root/orchestrator -p wa -k harness\n-w /etc/harness -p wa -k harness\n-w /root/.ssh -p wa -k harness\n' > "$T/loaded"
run AUDIT_SUPERVISOR_DIR="$T/sup" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "supervisord mode must exit 0 (rc=$RC): $(cat "$LOG" 2>/dev/null)"
lastlog | grep -q 'daemon=supervisord' && ok || bad "supervisord mode must be named in the success line: $(lastlog)"
for L in '\[program:auditd\]' 'command=/sbin/auditd -n' 'autostart=true' 'autorestart=true'; do
  grep -q "$L" "$T/sup/auditd.conf" 2>/dev/null && ok || bad "the supervisord program needs '$L': $(cat "$T/sup/auditd.conf" 2>/dev/null)"
done
for C in 'reread' 'update' 'start auditd'; do
  grep -q "^$C$" "$T/supervisorctl.calls" 2>/dev/null && ok \
    || bad "supervisorctl must be told to '$C': $(cat "$T/supervisorctl.calls" 2>/dev/null)"
done

# ── 6. the wiring: both production call sites, written so absence FAILS ─────
[ "$(grep -c 'audit-install.sh' "$DIR/bin/update-runners.sh")" -ge 1 ] && ok \
  || bad "bin/update-runners.sh must call bin/audit-install.sh"
[ "$(grep -c 'audit-install.sh' "$DIR/bin/bootstrap-machine.sh")" -ge 1 ] && ok \
  || bad "bin/bootstrap-machine.sh must call bin/audit-install.sh"
[ "$(grep -c 'Etc/UTC\|set-timezone UTC' "$DIR/bin/bootstrap-machine.sh")" -ge 1 ] && ok \
  || bad "bin/bootstrap-machine.sh must set the box timezone to UTC"
bash -n "$DIR/bin/update-runners.sh" 2>/dev/null && ok || bad "bin/update-runners.sh must parse"
bash -n "$DIR/bin/bootstrap-machine.sh" 2>/dev/null && ok || bad "bin/bootstrap-machine.sh must parse"
bash -n "$DIR/bin/audit-install.sh" 2>/dev/null && ok || bad "bin/audit-install.sh must parse"

echo "audit-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
