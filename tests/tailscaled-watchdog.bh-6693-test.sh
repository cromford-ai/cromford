#!/bin/bash
# tests/tailscaled-watchdog.bh-6693-test.sh — a box restarts tailscaled after
# an OOM kill instead of staying off the tailnet (BH-6693).
#
# WHY. On 2026-10-14 the OOM killer took tailscaled on box-small at
# 10:48Z. Only the @reboot crontab line starts tailscaled, so the box stayed
# off the tailnet for ~1 h 50 m: the hub could not ssh to it and the
# cromford pool could not start builds (11 env-extract failures).
#
#   W1  every box that runs the fleet's box lanes renders the watchdog line
#       (bin/render-cron.sh, the source bin/render-crontab.sh splices)
#   W2  pgrep finds no tailscaled: the start command runs once and the log
#       gets one line
#   W3  pgrep finds tailscaled: nothing starts and nothing is logged
#   W4  no tailscaled binary on the box: nothing starts, rc 0
#   W5  oom_score_adj is -900 for the tailscaled pid pgrep names; a value
#       already -900 is not rewritten and not logged
#   W8  no sshd pid is adjusted (lead BLOCK on 9252d3a6c): children inherit
#       oom_score_adj at fork, so -900 on the sshd listener would pass to every
#       ssh session and every build it starts
#   W6  the start command is the one bin/box-launch.sh sends: one definition
#       (bin/lib/tailscaled-start.sh), no copy of the tailscaled flags in
#       either script
#   W7  flags/lane-off-tailscaled-watchdog: nothing starts
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/tailscaled-watchdog.bh-6693-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

WD="$DIR/bin/tailscaled-watchdog.sh"
LINE='*/2 * * * * /root/harness/bin/tailscaled-watchdog.sh'

# ── W1 — the rendered crontab of every box the box lanes run on ──────────────
[ -f "$DIR/catalog/lanes.d/disk-guard.json" ] || bad "W1 fixture: no disk-guard lane to read the box list from"
BOXES=$(jq -r '.boxes[]' "$DIR/catalog/lanes.d/disk-guard.json" 2>/dev/null)
[ -n "$BOXES" ] || bad "W1 fixture: the disk-guard lane names no boxes"
for b in $BOXES; do
  OUT=$(bash "$DIR/bin/render-cron.sh" --root "$DIR" "$b" 2>"$T/rc.err"); RC=$?
  [ "$RC" = 0 ] || { bad "W1 render-cron $b failed (rc $RC): $(head -c 200 "$T/rc.err")"; continue; }
  grep -qF -- "$LINE" <<<"$OUT" && ok || bad "W1 box $b renders the watchdog line"
done

# ── a scratch harness for W2-W7 ───────────────────────────────────────────────
H="$T/h"; mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$T/stub" "$T/proc"
# The watchdog and every lib it sources (lane-gate.sh, tailscaled-start.sh).
[ -f "$WD" ] && scratch_install_closure bin/tailscaled-watchdog.sh "$H" >/dev/null || bad "W2 fixture: cannot install $WD"
: > "$T/tailscaled"; chmod +x "$T/tailscaled"
# pgrep: `-x <name>` answers from $T/pids.<name> (one pid per line); none = rc 1.
cat > "$T/stub/pgrep" <<EOF
#!/bin/bash
n="\${@: -1}"; f="$T/pids.\$n"
[ -s "\$f" ] || exit 1
cat "\$f"
EOF
# setsid: records what the start command ran; it never starts anything.
cat > "$T/stub/setsid" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/setsid.calls"
exit 0
EOF
chmod +x "$T/stub/pgrep" "$T/stub/setsid"
reset_case() {
  rm -f "$T"/pids.* "$T/setsid.calls" "$H/logs/tailscaled-watchdog.log" "$H/flags/lane-off-tailscaled-watchdog"
  scratch_rm "$T/proc"; mkdir -p "$T/proc"
}
run_wd() { PATH="$T/stub:$PATH" HARNESS="$H" TSW_TAILSCALED="${1:-$T/tailscaled}" TSW_PROC="$T/proc" \
             bash "$H/bin/tailscaled-watchdog.sh" > "$T/wd.out" 2>&1; WRC=$?; }
calls() { local n; n=$(grep -c . "$T/setsid.calls" 2>/dev/null) || n=0; printf '%s' "$n"; }
lines() { local n; n=$(grep -c . "$H/logs/tailscaled-watchdog.log" 2>/dev/null) || n=0; printf '%s' "$n"; }

# ── W2 — tailscaled is gone: one start, one log line ─────────────────────────
reset_case; echo 41 > "$T/pids.sshd"
run_wd
[ "$WRC" = 0 ] && ok || bad "W2 rc 0 (rc $WRC): $(cat "$T/wd.out")"
[ "$(calls)" = 1 ] && grep -q -- '-f /usr/sbin/tailscaled --tun=userspace-networking' "$T/setsid.calls" && ok \
  || bad "W2 the start command ran once: $(cat "$T/setsid.calls" 2>/dev/null)"
[ "$(grep -c 'tailscaled was not running' "$H/logs/tailscaled-watchdog.log" 2>/dev/null)" = 1 ] && ok \
  || bad "W2 one start line in the log: $(cat "$H/logs/tailscaled-watchdog.log" 2>/dev/null)"

# ── W3 — tailscaled is running: nothing ──────────────────────────────────────
reset_case; echo 77 > "$T/pids.tailscaled"; mkdir -p "$T/proc/77"; echo -900 > "$T/proc/77/oom_score_adj"
run_wd
[ "$WRC" = 0 ] && [ "$(calls)" = 0 ] && [ "$(lines)" = 0 ] && ok \
  || bad "W3 a running tailscaled starts nothing and logs nothing (rc $WRC, calls $(calls), lines $(lines))"

# ── W4 — no tailscaled binary: nothing, rc 0 ─────────────────────────────────
reset_case
run_wd "$T/no-such-tailscaled"
[ "$WRC" = 0 ] && [ "$(calls)" = 0 ] && ok || bad "W4 no binary: rc 0 and no start (rc $WRC, calls $(calls))"

# ── W5 — oom_score_adj ───────────────────────────────────────────────────────
reset_case
echo 77 > "$T/pids.tailscaled"; printf '41\n42\n' > "$T/pids.sshd"
for p in 77 41 42; do mkdir -p "$T/proc/$p"; echo 0 > "$T/proc/$p/oom_score_adj"; done
run_wd
[ "$(cat "$T/proc/77/oom_score_adj")" = -900 ] && ok || bad "W5 tailscaled pid 77 oom_score_adj is -900 (got $(cat "$T/proc/77/oom_score_adj"))"
# W8: the sshd pids keep their value.
for p in 41 42; do
  [ "$(cat "$T/proc/$p/oom_score_adj")" = 0 ] && ok || bad "W8 sshd pid $p oom_score_adj is untouched (got $(cat "$T/proc/$p/oom_score_adj"))"
done
grep -q 'sshd' "$H/logs/tailscaled-watchdog.log" 2>/dev/null && bad "W8 the oom line names no sshd pid: $(cat "$H/logs/tailscaled-watchdog.log")" || ok
[ "$(grep -c 'oom_score_adj' "$H/logs/tailscaled-watchdog.log" 2>/dev/null)" = 1 ] && ok \
  || bad "W5 one oom line for the change: $(cat "$H/logs/tailscaled-watchdog.log" 2>/dev/null)"
run_wd
[ "$(grep -c 'oom_score_adj' "$H/logs/tailscaled-watchdog.log" 2>/dev/null)" = 1 ] && ok \
  || bad "W5 a value already -900 is not logged again: $(cat "$H/logs/tailscaled-watchdog.log" 2>/dev/null)"

# ── W6 — one definition of the start command ─────────────────────────────────
grep -q 'tailscaled-start.sh' "$DIR/bin/box-launch.sh" && ok || bad "W6 bin/box-launch.sh sources bin/lib/tailscaled-start.sh"
for f in bin/box-launch.sh bin/tailscaled-watchdog.sh; do
  grep -q -- '--tun=userspace-networking' "$DIR/$f" 2>/dev/null && bad "W6 $f carries no copy of the tailscaled flags" || ok
done
grep -q -- '--tun=userspace-networking' "$DIR/bin/lib/tailscaled-start.sh" 2>/dev/null && ok \
  || bad "W6 bin/lib/tailscaled-start.sh holds the flags"

# ── W7 — the lane switch ─────────────────────────────────────────────────────
reset_case; : > "$H/flags/lane-off-tailscaled-watchdog"
run_wd
[ "$WRC" = 0 ] && [ "$(calls)" = 0 ] && ok || bad "W7 lane-off: no start (rc $WRC, calls $(calls)): $(cat "$T/wd.out")"

echo "tailscaled-watchdog.bh-6693: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
