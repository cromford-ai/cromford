#!/bin/bash
# tests/disk-clean-root-orphans.bh-7932-test.sh — BH-7932 stage `root-orphans`:
# bin/disk-clean-stages.sh LISTS each hand-made top-level dir under /root that
# is older than ROOT_ORPHAN_STALE_D days, in one warn alert per run, and
# deletes nothing.
#
# What is proved here, against the REAL bin/disk-clean-stages.sh over a scratch
# HOME (BOX_HK_HOME), scratch unit dirs (DISK_CLEAN_UNIT_DIRS), a stub
# $HARNESS/bin/lane-alert.sh that records its argv, and a frozen clock:
#   §1  two unknown old dirs give one lane-alert call (id root-orphan-<host>,
#       warn) that names each once with its KB and newest date, and one
#       `root orphan:` log line each; both still exist; known dirs, a fresh
#       dir, a file and a symlink give no line; console-worker is known when a
#       unit file names it;
#   §2  console-worker with no unit naming it is listed;
#   §3  no orphans: one --resolve call for the same id;
#   §4  ROOT_ORPHAN_KNOWN adds a name; an invalid ROOT_ORPHAN_STALE_D skips the
#       stage, logged, with no alert call;
#   §5  under HARNESS_TEST_SANDBOX=1 with no BOX_HK_HOME the stage is skipped;
#   §6  the stage block of the script holds no rm, mv or unlink.
# Run from anywhere: tests/disk-clean-root-orphans.bh-7932-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

S="$REPO/bin/disk-clean-stages.sh"
[ -f "$S" ] || { echo "FAIL: bin/disk-clean-stages.sh does not exist"; exit 1; }
unset ROOT_ORPHAN_STALE_D ROOT_ORPHAN_KNOWN 2>/dev/null || true

NOW=1789514400                     # 2026-09-15T23:20:00Z
DAY=86400
age() { local s=$1; shift; touch -h -d "@$((NOW - s))" "$@"; }
HOST=$(hostname)

HH="$T/h"; FH="$T/home"; FP="$T/proc"; U="$T/units"
LOG="$HH/logs/disk-clean.log"; CALLS="$T/alert.calls"
mkd() { mkdir -p "$FH/$1"; echo x > "$FH/$1/f"; age $(($2 * DAY)) "$FH/$1/f" "$FH/$1"; }
build_fixture() {
  scratch_rm "$HH"; scratch_rm "$FH"; scratch_rm "$U"; scratch_rm "$T/olddir"
  mkdir -p "$HH/tmp" "$HH/logs" "$HH/locks" "$HH/bin" "$FH" "$FP" "$U" "$T/olddir"
  cat > "$HH/bin/lane-alert.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLS"
SH
  chmod +x "$HH/bin/lane-alert.sh"
  rm -f "$CALLS"
  mkd wt-orc 30; mkdir -p "$FH/wt-orc/big"; head -c 40960 /dev/zero > "$FH/wt-orc/big/blob"
  age $((30 * DAY)) "$FH/wt-orc/big/blob" "$FH/wt-orc/big" "$FH/wt-orc"
  mkd tmp-bhfix4785 8
  for k in harness repos .cache; do mkd "$k" 30; done
  mkd fresh-dir 2
  mkd console-worker 30
  echo x > "$FH/notes.txt"; age $((30 * DAY)) "$FH/notes.txt"
  age $((30 * DAY)) "$T/olddir"; ln -s "$T/olddir" "$FH/link"
  printf '[Service]\nExecStart=/usr/bin/node %s/console-worker/index.js\n' "$FH" > "$U/console-worker.service"
}
run() {
  env HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" \
      DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$U" "$@" bash "$S" > "$T/out" 2>&1
}
D30=$(date -u -d "@$((NOW - 30 * DAY))" +%F)
D8=$(date -u -d "@$((NOW - 8 * DAY))" +%F)
cnt() { grep -cF -- "$1" "$2" 2>/dev/null || true; }

# ══ 1. two unknown dirs, one alert call ══════════════════════════════════════
build_fixture
run; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the run exits 0 (rc=$RC: $(cat "$T/out"))"
[ "$(wc -l < "$CALLS" 2>/dev/null)" = 1 ] && ok || bad "1 exactly one lane-alert call ($(cat "$CALLS" 2>/dev/null))"
A=$(cat "$CALLS" 2>/dev/null)
[[ $A == "--id root-orphan-$HOST --severity warn disk-clean "* ]] && ok || bad "1 the call is --id root-orphan-$HOST --severity warn disk-clean ($A)"
[[ $A == *"list only, nothing deleted"* ]] && ok || bad "1 the alert says list only ($A)"
[ "$(grep -o -F "$FH/wt-orc " <<< "$A" | wc -l)" = 1 ] && ok || bad "1 the alert names wt-orc once ($A)"
[ "$(grep -o -F "$FH/tmp-bhfix4785 " <<< "$A" | wc -l)" = 1 ] && ok || bad "1 the alert names tmp-bhfix4785 once ($A)"
[[ $A =~ $FH/wt-orc\ [0-9]+\ KB\ newest\ $D30 ]] && ok || bad "1 wt-orc carries KB and newest $D30 ($A)"
[[ $A =~ $FH/tmp-bhfix4785\ [0-9]+\ KB\ newest\ $D8 ]] && ok || bad "1 tmp-bhfix4785 carries KB and newest $D8 ($A)"
[[ $A == "--id root-orphan-$HOST --severity warn disk-clean 2 hand-made dir(s) under $FH, older than 7d"* ]] && ok \
  || bad "1 the alert counts 2 dirs and names the default 7d ($A)"
[ "$(cnt "root orphan: $FH/wt-orc " "$LOG")" = 1 ] && ok || bad "1 one root orphan: log line for wt-orc ($(cat "$LOG"))"
[ "$(cnt "root orphan: $FH/tmp-bhfix4785 " "$LOG")" = 1 ] && ok || bad "1 one root orphan: log line for tmp-bhfix4785"
grep -q "root orphan: $FH/wt-orc [0-9]* KB newest $D30\$" "$LOG" && ok || bad "1 the wt-orc log line carries KB and date"
grep -q '\[disk-clean-stages\] root-orphans listed=2$' "$LOG" && ok || bad "1 root-orphans listed=2 ($(grep root-orphans "$LOG"))"
[ -f "$FH/wt-orc/big/blob" ] && [ -f "$FH/tmp-bhfix4785/f" ] && ok || bad "1 both orphans still exist"
for k in harness repos .cache fresh-dir notes.txt link console-worker; do
  [ "$(cnt "$FH/$k " "$LOG")" = 0 ] && [[ $A != *"$FH/$k "* ]] && ok || bad "1 $k gives no line"
  [ -e "$FH/$k" ] && ok || bad "1 $k still exists"
done

# ══ 2. console-worker with no unit naming it ═════════════════════════════════
build_fixture; rm -f "$U/console-worker.service"
run
A=$(cat "$CALLS" 2>/dev/null)
[[ $A == *"$FH/console-worker "* ]] && ok || bad "2 console-worker with no unit is listed ($A)"
grep -q 'root-orphans listed=3$' "$LOG" && ok || bad "2 listed=3"
[ -d "$FH/console-worker" ] && ok || bad "2 console-worker still exists"

# ══ 3. no orphans: one resolve ═══════════════════════════════════════════════
build_fixture; scratch_rm "$FH/wt-orc"; scratch_rm "$FH/tmp-bhfix4785"
run
[ "$(wc -l < "$CALLS" 2>/dev/null)" = 1 ] && ok || bad "3 exactly one lane-alert call"
[[ $(cat "$CALLS" 2>/dev/null) == "--resolve --id root-orphan-$HOST disk-clean "* ]] && ok || bad "3 a --resolve call for root-orphan-$HOST ($(cat "$CALLS" 2>/dev/null))"
grep -q 'root-orphans listed=0$' "$LOG" && ok || bad "3 listed=0"

# ══ 4. knobs ═════════════════════════════════════════════════════════════════
build_fixture
run "ROOT_ORPHAN_KNOWN=harness repos .cache wt-orc"
A=$(cat "$CALLS" 2>/dev/null)
[[ $A != *"$FH/wt-orc "* ]] && [[ $A == *"$FH/tmp-bhfix4785 "* ]] && ok || bad "4 ROOT_ORPHAN_KNOWN with wt-orc drops it ($A)"
build_fixture
run ROOT_ORPHAN_STALE_D=10
A=$(cat "$CALLS" 2>/dev/null)
[[ $A != *"$FH/tmp-bhfix4785 "* ]] && [[ $A == *"$FH/wt-orc "* ]] && ok || bad "4 ROOT_ORPHAN_STALE_D=10 drops the 8d dir ($A)"
for junk in 0 abc; do
  build_fixture; : > "$LOG"
  run ROOT_ORPHAN_STALE_D=$junk
  [ ! -e "$CALLS" ] && ok || bad "4 ROOT_ORPHAN_STALE_D=$junk sends no alert call"
  grep -q "ROOT_ORPHAN_STALE_D invalid ($junk) - root-orphans skipped" "$LOG" && ok || bad "4 ROOT_ORPHAN_STALE_D=$junk is logged"
done

# ══ 5. sandbox: no BOX_HK_HOME ═══════════════════════════════════════════════
build_fixture; : > "$LOG"
env -u BOX_HK_HOME HOME="$FH" HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 \
    BOX_HK_PROC="$FP" DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$U" bash "$S" > "$T/out" 2>&1
[ ! -e "$CALLS" ] && ok || bad "5 a sandboxed run with no BOX_HK_HOME sends no alert"
grep -q 'root-orphans skipped (BOX_HK_HOME unset under HARNESS_TEST_SANDBOX)' "$LOG" && ok || bad "5 the skip is logged ($(cat "$LOG"))"

# ══ 6. the stage block deletes nothing ═══════════════════════════════════════
BLOCK=$(awk '/^# ── 3\. root-orphans/{on=1} on{print} /^# ── end root-orphans/{on=0}' "$S")
[ "$(printf '%s\n' "$BLOCK" | wc -l)" -gt 10 ] && ok || bad "6 the root-orphans block markers are present"
CODE=$(grep -v '^[[:space:]]*#' <<< "$BLOCK")
DEL=$(grep -E '(^|[^a-z_-])(rm|mv|unlink|rmdir)( |$)|-delete' <<< "$CODE")
[ -z "$DEL" ] && ok || bad "6 the root-orphans block holds a delete: $DEL"

echo "disk-clean-root-orphans: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
