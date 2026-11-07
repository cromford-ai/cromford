#!/bin/bash
# tests/audit-install.bh-9173-test.sh — bin/audit-install.sh records only what
# the tailer reads, and never lets the trail go silently dead.
#
# WHY (BH-9173, measured 2026-11-06). The BH-443 rules were `-w <root> -p wa`:
# every write under /root/harness. The hub's 1G cap held about 2 hours of
# atomic-write churn. On project-3-2 the log filled the disk, auditd hit its SUSPEND
# action and recorded nothing for 2 days; on project-4 the last record was
# 2026-10-03. `--check` called both boxes healthy, because "daemon running +
# rules loaded" was its whole test. And `-F dir=` / `-w` on a missing root is a
# kernel refusal (project-3-2 has no /root/orchestrator and no /etc/harness).
#
# What is proved here, every case through the real script's CLI with
# auditctl/augenrules/auditd/ausearch/pgrep stubbed on PATH:
#   R1-R7  --render: syscall rules, `never` rules for the harness churn first,
#          one `always` rule per EXISTING root, byte-stable, no `-p wa`;
#   C1-C2  auditd.conf: ROTATE on admin_space_left and disk_full, 50M x 5,
#          no SUSPEND anywhere; the happy path and its --check;
#   S1-S5  a stale audit.log is rc 1 + one alert (AUDIT_STALE_H), with the
#          near miss, the knob, the absent log and a fresh-start install;
#   P1-P5  the live probe: recorded, recorded after `auditctl --signal resume`,
#          NOT recorded (rc 1 + one alert, never a "rules loaded" claim), a root
#          the probe cannot write, and a box with no ausearch;
#   L1     the auditctl -R fallback drops the old harness rules first.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/audit-install.bh-9173-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/fakebin" "$T/fakectl" "$T/fakeaus" "$T/h/bin" "$T/h/env" "$T/etc" \
         "$T/orch" "$T/etch" "$T/ssh"
cp "$DIR/bin/audit-install.sh" "$T/h/bin/"; chmod +x "$T/h/bin/audit-install.sh"
S="$T/h/bin/audit-install.sh"

stub() { # stub <dir> <name> <body...>
  local d="$1" n="$2"; shift 2
  { echo '#!/bin/bash'; echo "T=\"$T\""; printf '%s\n' "$@"; } > "$d/$n"
  chmod +x "$d/$n"
}
# auditctl: -l prints $T/loaded; `--signal resume` leaves $T/resumed behind,
# which is what heals the ausearch stub in "heal" mode.
stub "$T/fakectl" auditctl \
  'echo "$*" >> "$T/auditctl.calls"' \
  'case "${1:-}" in' \
  '  -l) [ -f "$T/loaded" ] && cat "$T/loaded"; exit 0 ;;' \
  '  --signal) [ "${2:-}" = resume ] && touch "$T/resumed"; exit 0 ;;' \
  'esac' \
  'exit 0'
stub "$T/fakebin" augenrules \
  'echo "$*" >> "$T/augenrules.calls"' \
  '[ -f "$T/augfail" ] && { echo "augenrules: failed" >&2; exit 1; }' \
  'exit 0'
# the daemon comes up when started: S3's "daemon was down at the start of the run"
stub "$T/fakebin" auditd 'echo "$*" >> "$T/auditd.calls"; touch "$T/running"; exit 0'
stub "$T/fakebin" pgrep  '[ -f "$T/running" ] && exit 0; exit 1'
stub "$T/fakebin" pkill  'echo "$*" >> "$T/pkill.calls"; exit 0'
stub "$T/fakebin" apt-get 'echo "$*" >> "$T/apt.calls"; exit 0'
# ausearch: $T/aus-mode is ok (rc 0), fail (rc 1), or heal (rc 0 only after resume)
stub "$T/fakeaus" ausearch \
  'echo "$*" >> "$T/ausearch.calls"' \
  'case "$(cat "$T/aus-mode" 2>/dev/null)" in' \
  '  ok)   exit 0 ;;' \
  '  heal) [ -f "$T/resumed" ] && exit 0; exit 1 ;;' \
  'esac' \
  'exit 1'

ROOTS4="$T/h $T/orch $T/etch $T/ssh"
# the clock is pinned: audit.log ages are set relative to NOW, never to the wall clock
NOW=1793988000
ago() { touch -d "@$((NOW - $1))" "$2"; }   # ago <seconds> <file>
REDIR=(HARNESS="$T/h"
       AUDIT_ROOTS="$ROOTS4"
       AUDIT_RULES_FILE="$T/etc/harness.rules"
       AUDITD_CONF="$T/etc/auditd.conf"
       AUDIT_SUPERVISOR_DIR="$T/nosup"
       AUDIT_SYSTEMD_DIR="$T/nosys"
       AUDIT_LOG_PATH="$T/audit.log"
       AUDIT_PROBE_WAIT_S=1
       AUDIT_NOW="$NOW"
       AUDIT_SBIN_PATH="")
FULLPATH="$T/fakectl:$T/fakeaus:$T/fakebin:/usr/bin:/bin"
run()    { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S"; }
check()  { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S" --check 2>&1; }
render() { env PATH="$FULLPATH" "${REDIR[@]}" "$@" bash "$S" --render; }
LOG="$T/h/logs/audit-install.log"
ALERTS="$T/h/logs/ALERTS.log"
cnt() { [ -f "$2" ] || { echo 0; return 0; }; grep -c -- "$1" "$2" 2>/dev/null || true; }
lastlog() { tail -n 1 "$LOG" 2>/dev/null; }
reset() {
  rm -rf "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/tmp"
  mkdir -p "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/tmp" "$T/orch" "$T/etch" "$T/ssh"
  rm -f "$T/etc/harness.rules" "$T/etc/auditd.conf" "$T/loaded" "$T/running" "$T/resumed" \
        "$T"/*.calls "$T/augfail" "$T/aus-mode" "$T/audit.log"
  rm -f "$T"/h/.audit-probe.*
  : > "$T/h/env/global.env"
}
# the kernel's `auditctl -l` answer for exactly the rules the render asks for
seed_loaded() { render "$@" | grep '^-a ' | sed 's/ -k harness$/ -F key=harness/' > "$T/loaded"; }
# a box where everything works: daemon up, rules loaded, a fresh log, probes recorded
good_box() { reset; touch "$T/running"; ago 0 "$T/audit.log"; seed_loaded; echo ok > "$T/aus-mode"; }

ALWAYS_TAIL='-S unlink,unlinkat,rmdir,rename,renameat,renameat2,truncate,ftruncate'

# ── R1. byte-stable ─────────────────────────────────────────────────────────
reset
render > "$T/r1" 2>"$T/r1.err"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R1 --render must exit 0 (rc=$RC, $(cat "$T/r1.err"))"
render HOSTNAME=other TZ=America/Chicago > "$T/r2" 2>/dev/null
cmp -s "$T/r1" "$T/r2" && ok || bad "R1 --render must be byte-stable: $(diff "$T/r1" "$T/r2")"
[ "$(head -n 3 "$T/r1" | grep -c '^#')" -eq 3 ] && ok || bad "R1 the 3-line header stays: $(head -n 3 "$T/r1")"

# ── R2. the never lines, exactly, and all of them before every always line ─
H="$T/h"
EXPECT_NEVER="-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$H/state
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$H/logs
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$H/locks
-a never,exit -F arch=b64 -S rename,renameat,renameat2 -F dir=$H/tmp
-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=$H/locks
-a never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=$H/tmp"
GOT=$(grep '^-a never,exit' "$T/r1")
[ "$GOT" = "$EXPECT_NEVER" ] && ok || bad "R2 the never lines must be exactly:
$EXPECT_NEVER
got:
$GOT"
LAST_NEVER=$(grep -n '^-a never,exit' "$T/r1" | tail -n 1 | cut -d: -f1)
FIRST_ALWAYS=$(grep -n '^-a always,exit' "$T/r1" | head -n 1 | cut -d: -f1)
[ -n "$LAST_NEVER" ] && [ -n "$FIRST_ALWAYS" ] && [ "$LAST_NEVER" -lt "$FIRST_ALWAYS" ] && ok \
  || bad "R2 every never line must precede every always line: $(cat "$T/r1")"

# ── R3. one always rule per root, in AUDIT_ROOTS order; nothing of the old shape
EXPECT_ALWAYS=""
for r in $ROOTS4; do EXPECT_ALWAYS="$EXPECT_ALWAYS-a always,exit -F arch=b64 $ALWAYS_TAIL -F dir=$r -k harness
"; done
GOT=$(grep '^-a always,exit' "$T/r1")
[ "$GOT" = "${EXPECT_ALWAYS%$'\n'}" ] && ok || bad "R3 the always lines must be exactly:
$EXPECT_ALWAYS
got:
$GOT"
[ "$(grep -c '^-w ' "$T/r1")" -eq 0 ] && ok || bad "R3 no -w watch is left: $(cat "$T/r1")"
[ "$(grep -c -- '-p wa' "$T/r1")" -eq 0 ] && ok || bad "R3 no -p wa is left: $(cat "$T/r1")"
[ "$(grep -c -- '-e 2' "$T/r1")" -eq 0 ] && ok || bad "R3 -e 2 is out of scope"
[ "$(grep -vc '^#\|^-a never,exit \|^-a always,exit ' "$T/r1")" -eq 0 ] && ok \
  || bad "R3 the render holds only the header, never and always lines: $(cat "$T/r1")"

# ── R4. never rules carry no key ────────────────────────────────────────────
[ "$(grep '^-a never,exit' "$T/r1" | grep -c 'key\|-k ')" -eq 0 ] && ok \
  || bad "R4 a never rule has no key: $(grep '^-a never' "$T/r1")"

# ── R5. a wipe's unlink/rmdir stays recorded under the dirs that matter ─────
for d in state logs builds bin env prompts cron; do
  [ "$(grep '^-a never,exit' "$T/r1" | grep 'unlink' | grep -c -- "-F dir=$H/$d\$")" -eq 0 ] && ok \
    || bad "R5 unlink/rmdir under $d/ must not be dropped: $(grep '^-a never' "$T/r1")"
done

# ── R6. missing roots, missing subdirs, zero roots ──────────────────────────
reset; rmdir "$T/orch"
render > "$T/r6" 2>/dev/null
[ "$(grep -c '^-a always,exit' "$T/r6")" -eq 3 ] && ok || bad "R6 one root missing renders 3 always rules: $(cat "$T/r6")"
[ "$(grep -c -- "$T/orch" "$T/r6")" -eq 0 ] && ok || bad "R6 no line may name the missing root: $(cat "$T/r6")"
OUT=$(check)
grep -q 'loaded harness rules: 0 (expected 3)' <<<"$OUT" && ok || bad "R6 EXPECT counts rendered rules, not roots: $OUT"
grep -q 'harness roots: 3 of 4 exist' <<<"$OUT" && ok || bad "R6 --check names the live root count: $OUT"
: > "$T/afile"
render AUDIT_ROOTS="$T/h $T/afile" > "$T/r6f" 2>/dev/null
[ "$(grep -c '^-a always,exit' "$T/r6f")" -eq 1 ] && ok || bad "R6 a regular file is not a root: $(cat "$T/r6f")"
reset; rmdir "$T/h/tmp"
render > "$T/r6t" 2>/dev/null
[ "$(grep -c -- "-F dir=$T/h/tmp" "$T/r6t")" -eq 0 ] && ok || bad "R6 a missing tmp/ gets no never rule: $(cat "$T/r6t")"
[ "$(grep -c '^-a never,exit' "$T/r6t")" -eq 4 ] && ok || bad "R6 without tmp/ 4 never lines remain: $(cat "$T/r6t")"
render AUDIT_ROOTS="$T/orch $T/ssh" > "$T/r6h" 2>/dev/null
[ "$(grep -c '^-a never,exit' "$T/r6h")" -eq 0 ] && ok || bad "R6 a root other than HARNESS gets no never rule: $(cat "$T/r6h")"
# zero live roots
reset
NONE="$T/none-a $T/none-b"
render AUDIT_ROOTS="$NONE" > "$T/r6z" 2>/dev/null
[ "$(wc -l < "$T/r6z")" -eq 3 ] && [ "$(grep -c '^#' "$T/r6z")" -eq 3 ] && ok || bad "R6 zero roots render the header only: $(cat "$T/r6z")"
OUT=$(check AUDIT_ROOTS="$NONE"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "R6 --check with zero live roots is rc 1 (rc=$RC): $OUT"
grep -q 'harness roots: none exist' <<<"$OUT" && ok || bad "R6 --check must say no root exists: $OUT"
touch "$T/running"
run AUDIT_ROOTS="$NONE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "R6 install with zero roots exits 0 (rc=$RC)"
[ -f "$T/etc/harness.rules" ] && bad "R6 install with zero roots must not write a rules file: $(cat "$T/etc/harness.rules")" || ok
[ "$(cnt '\[audit-install\] no audit root exists' "$ALERTS")" -eq 1 ] && ok || bad "R6 zero roots is one alert: $(cat "$ALERTS" 2>/dev/null)"
grep -q 'rules loaded' "$LOG" 2>/dev/null && bad "R6 zero roots never claims rules loaded: $(cat "$LOG")" || ok

# ── R7. a trailing slash is normalized ──────────────────────────────────────
reset
render AUDIT_ROOTS="$T/h/ $T/ssh" > "$T/r7" 2>/dev/null
grep -q -- "-F dir=$T/h -k harness\$" "$T/r7" && ok || bad "R7 '$T/h/' renders as '$T/h': $(cat "$T/r7")"
grep -q -- "-F dir=$T/h/ " "$T/r7" && bad "R7 no trailing slash in a dir= field: $(cat "$T/r7")" || ok
[ "$(grep -c '^-a never,exit' "$T/r7")" -eq 6 ] && ok || bad "R7 HARNESS written with a slash still gets its never rules: $(cat "$T/r7")"

# ── C1. the happy path, end to end ──────────────────────────────────────────
good_box
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "C1 install exits 0 (rc=$RC)"
for KV in "max_log_file = 50" "num_logs = 5" "max_log_file_action = ROTATE" \
          "space_left_action = SYSLOG" "admin_space_left_action = ROTATE" "disk_full_action = ROTATE"; do
  grep -qx "$KV" "$T/etc/auditd.conf" && ok || bad "C1 auditd.conf must carry '$KV': $(cat "$T/etc/auditd.conf" 2>/dev/null)"
done
[ "$(cnt SUSPEND "$T/etc/auditd.conf")" -eq 0 ] && ok || bad "C1 SUSPEND must not be written: $(cat "$T/etc/auditd.conf")"
lastlog | grep -q 'rules loaded, n=4, daemon=bare' && ok || bad "C1 success line: $(cat "$LOG")"
[ -f "$ALERTS" ] && bad "C1 a working box is not an alert: $(cat "$ALERTS")" || ok
OUT=$(check); RC=$?
[ "$RC" -eq 0 ] && ok || bad "C1 --check on a healthy box is rc 0 (rc=$RC): $OUT"
grep -q 'harness rules: present (4 always, 6 never)' <<<"$OUT" && ok || bad "C1 --check counts always and never rules: $OUT"
grep -q 'audit.log: written' <<<"$OUT" && ok || bad "C1 --check reports the log age: $OUT"
grep -q '^probe: recorded$' <<<"$OUT" && ok || bad "C1 --check reports the probe: $OUT"
[ -z "$(find "$T/h" -maxdepth 1 -name '.audit-probe.*')" ] && ok || bad "C1 the probe file must be removed: $(ls -a "$T/h")"
[ -f "$ALERTS" ] && bad "C1 a healthy --check is not an alert: $(cat "$ALERTS")" || ok

# ── C2. a SUSPEND conf is rewritten to ROTATE ───────────────────────────────
good_box
printf 'log_file = %s\ndisk_full_action = SUSPEND\n#admin_space_left_action = SUSPEND\nadmin_space_left = 50\n' "$T/audit.log" > "$T/etc/auditd.conf"
run >/dev/null 2>&1
grep -qx 'disk_full_action = ROTATE' "$T/etc/auditd.conf" && ok || bad "C2 disk_full_action SUSPEND -> ROTATE: $(cat "$T/etc/auditd.conf")"
grep -qx 'admin_space_left_action = ROTATE' "$T/etc/auditd.conf" && ok || bad "C2 admin_space_left_action -> ROTATE: $(cat "$T/etc/auditd.conf")"
[ "$(cnt SUSPEND "$T/etc/auditd.conf")" -eq 0 ] && ok || bad "C2 no SUSPEND left: $(cat "$T/etc/auditd.conf")"
grep -qx 'admin_space_left = 50' "$T/etc/auditd.conf" && ok || bad "C2 an unrelated key is kept: $(cat "$T/etc/auditd.conf")"

# ── S1-S5. a stale log ──────────────────────────────────────────────────────
good_box; run >/dev/null 2>&1; rm -f "$ALERTS" "$T"/h/state/audit-install-denied-*
ago 60 "$T/audit.log"
OUT=$(check); RC=$?
[ "$RC" -eq 0 ] && ok || bad "S1 a 1-minute-old log is rc 0 (rc=$RC): $OUT"
grep -q STALE <<<"$OUT" && bad "S1 a fresh log is not STALE: $OUT" || ok

ago $((7*3600)) "$T/audit.log"
OUT=$(check); RC=$?
[ "$RC" -eq 1 ] && ok || bad "S2 a 7h-old log is rc 1 (rc=$RC): $OUT"
grep -q 'audit.log: STALE 7h (AUDIT_STALE_H=6)' <<<"$OUT" && ok || bad "S2 --check names the stale log: $OUT"
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok || bad "S2 a stale log is one alert: $(cat "$ALERTS" 2>/dev/null)"
grep -q STALE "$ALERTS" 2>/dev/null && ok || bad "S2 the alert names STALE: $(cat "$ALERTS" 2>/dev/null)"
check >/dev/null
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok || bad "S2 a second --check the same day adds no alert: $(cat "$ALERTS")"

# S3: install path, daemon up -> alert; daemon down at the start -> logged only
good_box; ago $((7*3600)) "$T/audit.log"
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "S3 install exits 0 on a stale log (rc=$RC)"
[ "$(cnt '\[audit-install\].*STALE' "$ALERTS")" -eq 1 ] && ok || bad "S3 install with the daemon up alerts STALE once: $(cat "$ALERTS" 2>/dev/null)"
good_box; rm -f "$T/running"; ago $((7*3600)) "$T/audit.log"
run >/dev/null 2>&1
[ -f "$T/auditd.calls" ] && ok || bad "S3 the daemon was started by this run"
[ "$(cnt 'STALE' "$ALERTS")" -eq 0 ] && ok || bad "S3 a run that just started the daemon does not alert STALE: $(cat "$ALERTS")"
grep -q STALE "$LOG" && ok || bad "S3 the stale log is still logged: $(cat "$LOG")"
lastlog | grep -q 'rules loaded, n=4, daemon=bare' && ok || bad "S3 the probe judged the fresh daemon healthy: $(cat "$LOG")"

# S4: near miss, the knob, the absent log
good_box; run >/dev/null 2>&1
ago $((5*3600 + 59*60)) "$T/audit.log"
OUT=$(check); RC=$?
[ "$RC" -eq 0 ] && ! grep -q STALE <<<"$OUT" && ok || bad "S4 5h59m is fresh (rc=$RC): $OUT"
ago $((2*3600)) "$T/audit.log"
OUT=$(check AUDIT_STALE_H=1); RC=$?
[ "$RC" -eq 1 ] && grep -q 'STALE 2h (AUDIT_STALE_H=1)' <<<"$OUT" && ok || bad "S4 AUDIT_STALE_H=1 moves a 2h log to STALE (rc=$RC): $OUT"
rm -f "$T/audit.log"
OUT=$(check); RC=$?
[ "$RC" -eq 1 ] && grep -q 'audit.log: STALE' <<<"$OUT" && ok || bad "S4 an absent log with rules loaded is STALE (rc=$RC): $OUT"

# S5: with no AUDIT_LOG_PATH the log is auditd.conf's own log_file
good_box; run >/dev/null 2>&1
printf 'log_file = %s\n' "$T/other.log" >> "$T/etc/auditd.conf"
ago $((8*3600)) "$T/other.log"
OUT=$(env PATH="$FULLPATH" "${REDIR[@]}" AUDIT_LOG_PATH= bash "$S" --check 2>&1); RC=$?
[ "$RC" -eq 1 ] && grep -q 'STALE 8h' <<<"$OUT" && ok || bad "S5 the log path comes from auditd.conf log_file (rc=$RC): $OUT"

# ── P1-P5. the live probe ───────────────────────────────────────────────────
good_box; run >/dev/null 2>&1; rm -f "$T/auditctl.calls" "$T/ausearch.calls"
OUT=$(check); RC=$?
grep -q '^probe: recorded$' <<<"$OUT" && ok || bad "P1 probe recorded: $OUT"
grep -q -- "-k harness -f $T/h/.audit-probe\." "$T/ausearch.calls" 2>/dev/null && ok \
  || bad "P1 ausearch asked for a harness record of the probe file: $(cat "$T/ausearch.calls" 2>/dev/null)"
[ "$(cnt '--signal resume' "$T/auditctl.calls")" -eq 0 ] && ok || bad "P1 a recorded probe sends no resume"

good_box; run >/dev/null 2>&1; rm -f "$T/auditctl.calls" "$T/resumed"; echo heal > "$T/aus-mode"
OUT=$(check); RC=$?
[ "$RC" -eq 0 ] && ok || bad "P2 recorded after resume is rc 0 (rc=$RC): $OUT"
grep -q '^probe: recorded after resume$' <<<"$OUT" && ok || bad "P2 says recorded after resume: $OUT"
[ "$(cnt '--signal resume' "$T/auditctl.calls")" -eq 1 ] && ok || bad "P2 resume is sent once: $(cat "$T/auditctl.calls")"
[ -f "$ALERTS" ] && bad "P2 a resumed trail is not an alert: $(cat "$ALERTS")" || ok
grep -q 'resumed' "$LOG" && ok || bad "P2 the resume is logged: $(cat "$LOG")"

good_box; run >/dev/null 2>&1; rm -f "$T/auditctl.calls" "$T/resumed"; echo fail > "$T/aus-mode"
OUT=$(check); RC=$?
[ "$RC" -eq 1 ] && ok || bad "P3 daemon up + rules loaded + no record is rc 1 (rc=$RC): $OUT"
grep -q 'daemon (bare): running' <<<"$OUT" && grep -q 'loaded harness rules: 4 (expected 4)' <<<"$OUT" && ok \
  || bad "P3 the daemon and the rules look healthy: $OUT"
grep -q '^probe: NOT recorded$' <<<"$OUT" && ok || bad "P3 says NOT recorded: $OUT"
[ "$(cnt '\[audit-install\] audit trail DEAD' "$ALERTS")" -eq 1 ] && ok || bad "P3 one DEAD alert: $(cat "$ALERTS" 2>/dev/null)"
[ "$(cnt '--signal resume' "$T/auditctl.calls")" -eq 1 ] && ok || bad "P3 resume is tried exactly once: $(cat "$T/auditctl.calls")"
check >/dev/null
[ "$(cnt '\[audit-install\]' "$ALERTS")" -eq 1 ] && ok || bad "P3 a second --check the same day adds no alert"

good_box; echo fail > "$T/aus-mode"
run >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P4 install exits 0 on a dead trail (rc=$RC)"
grep -q 'rules loaded, n=' "$LOG" && bad "P4 a dead trail is never 'rules loaded': $(cat "$LOG")" || ok
lastlog | grep -q 'trail DEAD (probe not recorded after resume)' && ok || bad "P4 the last line says trail DEAD: $(cat "$LOG")"
[ "$(cnt '\[audit-install\] audit trail DEAD' "$ALERTS")" -eq 1 ] && ok || bad "P4 one DEAD alert: $(cat "$ALERTS" 2>/dev/null)"

# a knob that is not a number falls to its default instead of a probe loop with no end
good_box; run >/dev/null 2>&1; echo fail > "$T/aus-mode"; rm -f "$T/ausearch.calls"
OUT=$(timeout 60 env PATH="$FULLPATH" "${REDIR[@]}" AUDIT_PROBE_WAIT_S=x AUDIT_STALE_H=y bash "$S" --check 2>&1); RC=$?
[ "$RC" -eq 1 ] && grep -q '^probe: NOT recorded$' <<<"$OUT" && ok || bad "P4 a non-number AUDIT_PROBE_WAIT_S still ends (rc=$RC): $OUT"
[ "$(cnt . "$T/ausearch.calls")" -eq 10 ] && ok || bad "P4 the default wait is 5 tries per probe, 2 probes: $(cnt . "$T/ausearch.calls") calls"

# P5: a root the probe cannot write (/proc/1 is a dir no user can create a file in)
good_box
seed_loaded AUDIT_ROOTS="/proc/1 $T/ssh"
OUT=$(check AUDIT_ROOTS="/proc/1 $T/ssh")
grep -q '^probe: could not write /proc/1' <<<"$OUT" && ok || bad "P5 an unwritable root is its own class: $OUT"
grep -q 'NOT recorded\|DEAD' <<<"$OUT" && bad "P5 an unwritable root is not a dead trail: $OUT" || ok
[ "$(cnt 'DEAD' "$ALERTS")" -eq 0 ] && ok || bad "P5 an unwritable root is no DEAD alert: $(cat "$ALERTS")"
good_box
OUT=$(env PATH="$T/fakectl:$T/fakebin:/usr/bin:/bin" "${REDIR[@]}" bash "$S" --check 2>&1); RC=$?
grep -q '^probe: skipped (ausearch not installed)' <<<"$OUT" && ok || bad "P5 no ausearch skips the probe: $OUT"
[ -f "$ALERTS" ] && bad "P5 a skipped probe is not an alert: $(cat "$ALERTS")" || ok

# P6: the skip branches write nothing and claim nothing
reset; touch "$T/running" "$T/audit.log"; echo ok > "$T/aus-mode"
OUT=$(check)
grep -q '^probe: skipped (no harness rules loaded)$' <<<"$OUT" && ok || bad "P6 no rules loaded skips the probe: $OUT"
[ -f "$T/ausearch.calls" ] && bad "P6 a skipped probe asks ausearch nothing: $(cat "$T/ausearch.calls")" || ok
grep -q '^audit.log:' <<<"$OUT" && bad "P6 no rules loaded judges no log age: $OUT" || ok
OUT=$(env PATH="$T/fakeaus:$T/fakebin:/usr/bin:/bin" "${REDIR[@]}" bash "$S" --check 2>&1)
grep -q '^probe: skipped (auditctl not installed)$' <<<"$OUT" && ok || bad "P6 no auditctl skips the probe: $OUT"
[ -f "$ALERTS" ] && bad "P6 a skipped probe is not an alert: $(cat "$ALERTS")" || ok
# install path: no ausearch -> logged, and the kernel's count is the only claim
good_box
env PATH="$T/fakectl:$T/fakebin:/usr/bin:/bin" "${REDIR[@]}" bash "$S" >/dev/null 2>&1
grep -q 'probe: skipped (ausearch not installed)' "$LOG" && ok || bad "P6 install logs the skipped probe: $(cat "$LOG")"
lastlog | grep -q 'rules loaded, n=4, daemon=bare' && ok || bad "P6 install without ausearch still verifies the load: $(cat "$LOG")"
# install path: an unwritable first root -> not verified, not a success, not DEAD
good_box; seed_loaded AUDIT_ROOTS="/proc/1 $T/ssh"
run AUDIT_ROOTS="/proc/1 $T/ssh" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "P6 install exits 0 on an unwritable root (rc=$RC)"
lastlog | grep -q 'trail not verified: probe could not write /proc/1' && ok || bad "P6 install names the unverified trail: $(cat "$LOG")"
grep -q 'rules loaded, n=\|DEAD' "$LOG" && bad "P6 an unverified trail is neither loaded nor DEAD: $(cat "$LOG")" || ok
[ -f "$ALERTS" ] && bad "P6 an unwritable root is not an alert: $(cat "$ALERTS")" || ok

# ── L1. the auditctl -R fallback clears the old harness rules first ─────────
good_box; touch "$T/augfail"
run >/dev/null 2>&1
R_LINE=$(grep -n '^-R ' "$T/auditctl.calls" | head -n 1 | cut -d: -f1)
D_LINE=$(grep -n '^-D -k harness$' "$T/auditctl.calls" | head -n 1 | cut -d: -f1)
[ -n "$R_LINE" ] && [ -n "$D_LINE" ] && [ "$D_LINE" -lt "$R_LINE" ] && ok \
  || bad "L1 '-D -k harness' runs before '-R': $(cat "$T/auditctl.calls")"
[ "$(head -n "${R_LINE:-0}" "$T/auditctl.calls" | grep -c '^-d never,exit -F arch=b64 -S ')" -eq 6 ] && ok \
  || bad "L1 the 6 never rules are deleted before '-R': $(cat "$T/auditctl.calls")"
grep -qx -- "-d never,exit -F arch=b64 -S unlink,unlinkat,rmdir -F dir=$T/h/tmp" "$T/auditctl.calls" && ok \
  || bad "L1 the delete carries the rule's own fields: $(cat "$T/auditctl.calls")"
lastlog | grep -q 'rules loaded, n=4' && ok || bad "L1 the fallback load still verifies: $(cat "$LOG")"
good_box; run >/dev/null 2>&1
grep -q -- '^-D ' "$T/auditctl.calls" && bad "L1 augenrules success never deletes rules by hand: $(cat "$T/auditctl.calls")" || ok

echo "audit-install bh-9173: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
