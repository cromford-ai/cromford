#!/bin/bash
# tests/disk-clean-cron-log.bh-6530-test.sh — disk-clean's stage 10: every
# logs/*-cron.log over CRON_LOG_MAX_KB is cut in place to its newest half.
#
# Eight cron lanes append their stderr to logs/<lane>-cron.log and nothing
# bounded those files. One glob, one knob, one daily stage covers all of them.
#
# What is proved here, against the REAL bin/disk-clean.sh (installed with its
# closure into a scratch HARNESS_ROOT, clock and paths pinned):
#   §1  a 20 MB merge-conductor-cron.log, knob unset (10240 KB): cut to between
#       5 MB minus one line and 10 MB, starting at a whole fixture line, ending
#       on the last fixture line, and a contiguous suffix of the original;
#   §2  the cut keeps the inode, and a writer holding the file open with >>
#       goes on appending at the new end;
#   §3  a 1 KB cron log is byte-identical after the run;
#   §4  a file of exactly CRON_LOG_MAX_KB*1024 bytes is kept, one byte more is cut;
#   §5  out of scope and untouched: a big logs/pipeline-health.log, a big
#       logs/sub/x-cron.log, a symlink logs/link-cron.log to a big file;
#   §6  CRON_LOG_MAX_KB=abc / 63 skip the stage with one line; 64 applies;
#   §7  a failed tail (temp write) and a failed in-place copy each log a line
#       and count nothing;
#   §8  two over-bound files in one run: both cut, cronlogs_cut=2;
#   §9  the summary line ends with the measured cronlogs_cut / cronlogs_freed_kb
#       and still matches the prefix the older suites pin;
#   §10 no .<name>.cut.<pid> temp file is left in logs/ after any run.
# Run from anywhere: tests/disk-clean-cron-log.bh-6530-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NOW=1791936000            # 2026-10-14T00:00:00Z, pinned
H="$T/h"
LOG="$H/logs/disk-clean.log"
MB=1048576

mkdir -p "$T/fakebin" "$T/nonpm" "$T/repos" "$T/proc" "$T/hkhome" "$T/hktmp" "$T/outside"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/pgrep"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/crontab"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/npm"
# THE BREAKERS (§7 only). Root ignores permission bits, so a failed write is
# injected where the code meets the system: tail fails for the path in
# DC_TAIL_BREAK, cat fails when its argument names DC_CAT_BREAK.
cat > "$T/fakebin/tail" <<'SH'
#!/bin/bash
if [ -n "${DC_TAIL_BREAK:-}" ]; then
  case " $* " in *"$DC_TAIL_BREAK"*) exit 1 ;; esac
fi
exec /usr/bin/tail "$@"
SH
cat > "$T/fakebin/cat" <<'SH'
#!/bin/bash
if [ -n "${DC_CAT_BREAK:-}" ]; then
  case " $* " in *"$DC_CAT_BREAK"*) exit 1 ;; esac
fi
exec /usr/bin/cat "$@"
SH
chmod +x "$T/fakebin/"*
[ -x /usr/bin/tail ] && [ -x /usr/bin/cat ] || { echo "tail/cat not where the shims expect them - skipping"; exit 0; }

# One numbered-line master of 20 MB (13 bytes a line), built once.
MASTER="$T/master.log"
awk -v n=$((20 * MB / 13)) 'BEGIN { for (i = 1; i <= n; i++) printf "line-%07d\n", i }' > "$MASTER"
MASTER_LAST=$(/usr/bin/tail -n 1 "$MASTER")

mkfix() { # a fresh scratch harness with the real lane closure
  scratch_rm "$H"
  mkdir -p "$H/env" "$H/logs" "$H/state" "$H/locks" "$H/flags"
  scratch_install_closure bin/disk-clean.sh "$H" >/dev/null || { bad "fixture: closure install"; exit 1; }
  : > "$H/env/global.env"
}

run() { # run [VAR=VAL ...] — the production entry point, as cron drives it
  env -u CRON_LOG_MAX_KB PATH="$T/fakebin:$PATH" HARNESS_ROOT="$H" HARNESS="$H" \
      ETC_HARNESS_ENV="$T/no-such-etc" DISK_CLEAN_REPOS="$T/repos" \
      DISK_CLEAN_NPM_DIR="$T/nonpm" DISK_CLEAN_NOW="$NOW" DISK_CLEAN_PROC="$T/proc" \
      BOX_HK_HOME="$T/hkhome" BOX_HK_TMP="$T/hktmp" BOX_HK_PROC="$T/proc" BOX_HK_NOW="$NOW" \
      "$@" bash "$H/bin/disk-clean.sh" > "$T/run.out" 2>&1
  [ -z "$(find "$H/logs" -maxdepth 1 -name '.*.cut.*' -print -quit)" ] \
    && ok || bad "§10 a .*.cut.* temp file is left in logs/ after a run"
}
summary() { grep 'disk-clean: ' "$LOG" 2>/dev/null | /usr/bin/tail -n 1; }
field()   { summary | sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }
size()    { stat -c %s "$1"; }

# ============================================================================
# §1 §2 §9: the 20 MB log, knob unset
# ============================================================================
mkfix
F="$H/logs/merge-conductor-cron.log"
cp "$MASTER" "$F"
S0=$(size "$F"); I0=$(stat -c %i "$F")
exec 7>>"$F"               # a lane that has the log open with >> across the cut
run
S1=$(size "$F")
[ "$S1" -le $((10240 * 1024)) ] && ok || bad "§1 cut file is $S1 bytes, over 10 MB"
[ "$S1" -ge $((5 * MB - 13)) ] && ok || bad "§1 cut file is $S1 bytes, under 5 MB minus one line"
[ "$(/usr/bin/tail -n 1 "$F")" = "$MASTER_LAST" ] && ok || bad "§1 last line is not the last fixture line"
grep -Eq '^line-[0-9]{7}$' <(head -n 1 "$F") && ok || bad "§1 first line is not a whole fixture line: $(head -c 20 "$F")"
KEPT=$(wc -l < "$F")
cmp -s <(/usr/bin/tail -n "$KEPT" "$MASTER") "$F" && ok || bad "§1 kept lines are not a contiguous suffix of the original"
[ "$(stat -c %i "$F")" = "$I0" ] && ok || bad "§2 inode changed across the cut"
echo "line-appended" >&7
exec 7>&-
[ "$(/usr/bin/tail -n 1 "$F")" = "line-appended" ] && ok || bad "§2 a >> writer did not land at the new end"
[ "$(size "$F")" -eq $((S1 + 14)) ] && ok || bad "§2 >> write did not append right after the kept text (size $(size "$F"), want $((S1 + 14)))"
[ "$(field cronlogs_cut)" = 1 ] && ok || bad "§9 cronlogs_cut is '$(field cronlogs_cut)', want 1: $(summary)"
[ "$(field cronlogs_freed_kb)" = $(((S0 - S1) / 1024)) ] && ok \
  || bad "§9 cronlogs_freed_kb is '$(field cronlogs_freed_kb)', want $(((S0 - S1) / 1024))"
summary | grep -Eq 'cronlogs_cut=[0-9]+ cronlogs_freed_kb=[0-9]+$' && ok || bad "§9 summary does not end with the two fields: $(summary)"
summary | grep -q 'disk-clean: [0-9]*%->[0-9]*% npm=' && ok || bad "§9 summary lost its pinned prefix: $(summary)"
[ "$(grep -c 'disk-clean: ' "$LOG")" = 1 ] && ok || bad "§9 not exactly one summary line"

# ============================================================================
# §3 §4 §5: what is kept
# ============================================================================
mkfix
head -c 1024 "$MASTER" > "$H/logs/stuck-work-cron.log"
head -c $((10240 * 1024)) "$MASTER" > "$H/logs/lane-fleet-cron.log"
head -c $((10240 * 1024 + 1)) "$MASTER" > "$H/logs/blocked-resolver-cron.log"
cp "$MASTER" "$H/logs/pipeline-health.log"
mkdir -p "$H/logs/sub"; cp "$MASTER" "$H/logs/sub/x-cron.log"
cp "$MASTER" "$T/outside/big.log"; ln -s "$T/outside/big.log" "$H/logs/link-cron.log"
declare -A SUM
for f in stuck-work-cron.log lane-fleet-cron.log pipeline-health.log sub/x-cron.log; do
  SUM[$f]=$(cksum < "$H/logs/$f")
done
SUM[link]=$(cksum < "$T/outside/big.log")
run
[ "$(cksum < "$H/logs/stuck-work-cron.log")" = "${SUM[stuck-work-cron.log]}" ] && ok || bad "§3 a 1 KB cron log changed"
[ "$(cksum < "$H/logs/lane-fleet-cron.log")" = "${SUM[lane-fleet-cron.log]}" ] && ok || bad "§4 a file of exactly the bound was cut"
[ "$(size "$H/logs/blocked-resolver-cron.log")" -le $((10240 * 1024)) ] && ok || bad "§4 bound+1 byte was not cut"
[ "$(cksum < "$H/logs/pipeline-health.log")" = "${SUM[pipeline-health.log]}" ] && ok || bad "§5 logs/pipeline-health.log (not -cron.log) changed"
[ "$(cksum < "$H/logs/sub/x-cron.log")" = "${SUM[sub/x-cron.log]}" ] && ok || bad "§5 logs/sub/x-cron.log (depth 2) changed"
[ "$(cksum < "$T/outside/big.log")" = "${SUM[link]}" ] && ok || bad "§5 the target of a symlinked -cron.log changed"
[ -L "$H/logs/link-cron.log" ] && ok || bad "§5 the symlink itself was replaced"
[ "$(field cronlogs_cut)" = 1 ] && ok || bad "§4/§9 cronlogs_cut is '$(field cronlogs_cut)', want 1 (only bound+1)"

# ============================================================================
# §6: the knob
# ============================================================================
for v in abc 63 -5; do
  mkfix
  cp "$MASTER" "$H/logs/fleet-propagate-cron.log"
  before=$(cksum < "$H/logs/fleet-propagate-cron.log")
  run CRON_LOG_MAX_KB="$v"
  [ "$(cksum < "$H/logs/fleet-propagate-cron.log")" = "$before" ] && ok || bad "§6 CRON_LOG_MAX_KB=$v still cut a file"
  [ "$(grep -c "cron log bound skipped: CRON_LOG_MAX_KB='$v' is not a whole number >= 64" "$LOG")" = 1 ] && ok \
    || bad "§6 CRON_LOG_MAX_KB=$v: want one skipped line, log: $(cat "$LOG")"
  [ "$(field cronlogs_cut)" = 0 ] && ok || bad "§6 CRON_LOG_MAX_KB=$v: cronlogs_cut is '$(field cronlogs_cut)', want 0"
done
mkfix
head -c $((200 * 1024)) "$MASTER" > "$H/logs/pr-owner-sweep-cron.log"
run CRON_LOG_MAX_KB=64
[ "$(size "$H/logs/pr-owner-sweep-cron.log")" -le $((64 * 1024)) ] && ok || bad "§6 CRON_LOG_MAX_KB=64 did not cut a 200 KB file"
grep -q 'cron log bound skipped' "$LOG" && bad "§6 CRON_LOG_MAX_KB=64 was refused" || ok
[ "$(field cronlogs_cut)" = 1 ] && ok || bad "§6 CRON_LOG_MAX_KB=64: cronlogs_cut is '$(field cronlogs_cut)', want 1"

# ============================================================================
# §7: failure paths count nothing
# ============================================================================
mkfix
cp "$MASTER" "$H/logs/stranded-watch-cron.log"
before=$(cksum < "$H/logs/stranded-watch-cron.log")
run DC_TAIL_BREAK="stranded-watch-cron.log"
[ "$(cksum < "$H/logs/stranded-watch-cron.log")" = "$before" ] && ok || bad "§7 a failed temp write changed the log"
[ "$(grep -c 'cron log kept: stranded-watch-cron.log' "$LOG")" = 1 ] && ok || bad "§7 no single kept line for the failed temp write: $(cat "$LOG")"
[ "$(field cronlogs_cut)" = 0 ] && ok || bad "§7 failed temp write: cronlogs_cut is '$(field cronlogs_cut)', want 0"
[ "$(field cronlogs_freed_kb)" = 0 ] && ok || bad "§7 failed temp write: cronlogs_freed_kb is '$(field cronlogs_freed_kb)', want 0"

mkfix
cp "$MASTER" "$H/logs/stranded-watch-cron.log"
run DC_CAT_BREAK=".stranded-watch-cron.log.cut."
[ "$(grep -c 'cron log cut failed: stranded-watch-cron.log' "$LOG")" = 1 ] && ok || bad "§7 no single line for the failed in-place copy: $(cat "$LOG")"
[ "$(field cronlogs_cut)" = 0 ] && ok || bad "§7 failed copy: cronlogs_cut is '$(field cronlogs_cut)', want 0"

# ============================================================================
# §8: two lanes' logs, one rule, one run
# ============================================================================
mkfix
cp "$MASTER" "$H/logs/merge-conductor-cron.log"
head -c $((12 * MB)) "$MASTER" > "$H/logs/lane-snapshot-publish-cron.log"
A0=$(size "$H/logs/merge-conductor-cron.log"); B0=$(size "$H/logs/lane-snapshot-publish-cron.log")
run
A1=$(size "$H/logs/merge-conductor-cron.log"); B1=$(size "$H/logs/lane-snapshot-publish-cron.log")
[ "$A1" -le $((10240 * 1024)) ] && [ "$B1" -le $((10240 * 1024)) ] && ok || bad "§8 not both files cut ($A1, $B1)"
[ "$(field cronlogs_cut)" = 2 ] && ok || bad "§8 cronlogs_cut is '$(field cronlogs_cut)', want 2"
[ "$(field cronlogs_freed_kb)" = $(( (A0 - A1) / 1024 + (B0 - B1) / 1024 )) ] && ok \
  || bad "§8/§9 cronlogs_freed_kb is '$(field cronlogs_freed_kb)', want $(( (A0 - A1) / 1024 + (B0 - B1) / 1024 ))"

echo "disk-clean-cron-log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
