#!/bin/bash
# tests/disk-clean-tool-caches.bh-7932-test.sh — BH-7932 stage `tool-caches`:
# bin/disk-clean-stages.sh deletes gh cache files older than GH_CACHE_STALE_D
# days and pip cache files older than PIP_CACHE_STALE_D days, and never reads
# or touches the playwright browser cache.
#
# What is proved here, against the REAL bin/disk-clean-stages.sh over a scratch
# HOME (BOX_HK_HOME) and a frozen clock (DISK_CLEAN_NOW):
#   §1  gh: an 8d file goes, a 6d file stays; pip: a 31d file goes, a 29d file
#       stays and the dir the sweep emptied goes; the playwright cache and
#       .cache/other at 90d are untouched; the summary line counts each;
#   §2  the knobs move the cutoffs; an invalid knob skips the stage, logged;
#   §3  a symlinked .cache/gh is refused and its target is untouched;
#   §4  under HARNESS_TEST_SANDBOX=1 with no BOX_HK_HOME the stage is skipped
#       and logged, and a planted $HOME is untouched;
#   §7  a relative or `..` root is refused and logged, nothing swept;
#   §5  no line of the script that is not a comment names the playwright cache
#       except the log word `playwright=untouched`.
# Run from anywhere: tests/disk-clean-tool-caches.bh-7932-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

S="$REPO/bin/disk-clean-stages.sh"
[ -f "$S" ] || { echo "FAIL: bin/disk-clean-stages.sh does not exist"; exit 1; }
unset GH_CACHE_STALE_D PIP_CACHE_STALE_D 2>/dev/null || true

NOW=1789514400                     # 2026-09-15T23:20:00Z
DAY=86400
age() { local s=$1; shift; touch -h -d "@$((NOW - s))" "$@"; }

HH="$T/h"; FH="$T/home"; C="$T/home/.cache"; FP="$T/proc"
LOG="$HH/logs/disk-clean.log"
mkf() { mkdir -p "$(dirname "$1")"; echo x > "$1"; age $(($2 * DAY)) "$1"; }
build_fixture() {
  scratch_rm "$HH"; scratch_rm "$FH"; scratch_rm "$T/elsewhere"; scratch_rm "$T/home2"
  mkdir -p "$HH/tmp" "$HH/logs" "$HH/locks" "$FP"
  mkf "$C/gh/old8" 8
  mkf "$C/gh/sub/new6" 6
  mkf "$C/pip/http/a/old31" 31
  mkf "$C/pip/new29" 29
  mkf "$C/ms-playwright/chromium/x" 90
  mkf "$C/other/x" 90
}
run() {
  env HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" \
      DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$T/units" "$@" bash "$S" > "$T/out" 2>&1
}
line() { grep 'tool-caches gh_files=' "$LOG" | tail -n 1; }
field() { line | tr ' ' '\n' | sed -n "s/^$1=//p"; }

# ══ 1. defaults ══════════════════════════════════════════════════════════════
build_fixture
run; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the run exits 0 (rc=$RC: $(cat "$T/out"))"
[ ! -e "$C/gh/old8" ] && ok || bad "1 a gh cache file at 8d must go"
[ -f "$C/gh/sub/new6" ] && ok || bad "1 a gh cache file at 6d must stay"
[ ! -e "$C/pip/http/a/old31" ] && ok || bad "1 a pip cache file at 31d must go"
[ ! -e "$C/pip/http" ] && ok || bad "1 the pip dirs the sweep emptied must go"
[ -f "$C/pip/new29" ] && ok || bad "1 a pip cache file at 29d must stay"
[ -d "$C/gh" ] && [ -d "$C/pip" ] && ok || bad "1 the cache roots themselves stay"
[ -f "$C/ms-playwright/chromium/x" ] && ok || bad "1 the playwright cache at 90d must be untouched"
[ -f "$C/other/x" ] && ok || bad "1 .cache/other at 90d must be untouched"
[ "$(field gh_files)" = 1 ] && ok || bad "1 gh_files=1 ($(line))"
[ "$(field pip_files)" = 1 ] && ok || bad "1 pip_files=1 ($(line))"
[ "$(field playwright)" = untouched ] && ok || bad "1 playwright=untouched ($(line))"
for k in gh_freed_kb pip_freed_kb; do
  v=$(field "$k"); case "$v" in ''|*[!0-9]*) bad "1 $k is a number ($(line))" ;; *) ok ;; esac
done
grep -q '\[disk-clean-stages\] tool-caches gh_files=' "$LOG" && ok || bad "1 the line is tagged [disk-clean-stages]"

# ══ 2. knobs ═════════════════════════════════════════════════════════════════
build_fixture
run GH_CACHE_STALE_D=10 PIP_CACHE_STALE_D=28
[ -f "$C/gh/old8" ] && ok || bad "2 GH_CACHE_STALE_D=10 keeps the 8d gh file"
[ ! -e "$C/pip/new29" ] && ok || bad "2 PIP_CACHE_STALE_D=28 removes the 29d pip file"
for junk in 0 abc; do
  build_fixture; : > "$LOG"
  run GH_CACHE_STALE_D=$junk
  [ -f "$C/gh/old8" ] && [ -f "$C/pip/http/a/old31" ] && ok || bad "2 GH_CACHE_STALE_D=$junk removes nothing"
  grep -q "GH_CACHE_STALE_D invalid ($junk) - tool-caches skipped" "$LOG" && ok || bad "2 GH_CACHE_STALE_D=$junk is logged ($(cat "$LOG"))"
done
build_fixture; : > "$LOG"
run PIP_CACHE_STALE_D=x
[ -f "$C/pip/http/a/old31" ] && [ -f "$C/gh/old8" ] && ok || bad "2 PIP_CACHE_STALE_D=x removes nothing"
grep -q 'PIP_CACHE_STALE_D invalid (x) - tool-caches skipped' "$LOG" && ok || bad "2 PIP_CACHE_STALE_D=x is logged"

# ══ 3. a symlinked root is refused ═══════════════════════════════════════════
build_fixture; : > "$LOG"
mkf "$T/elsewhere/old90" 90
scratch_rm "$C/gh"; ln -s "$T/elsewhere" "$C/gh"
run
[ -f "$T/elsewhere/old90" ] && ok || bad "3 a symlinked .cache/gh is never followed"
grep -q 'refused' "$LOG" && ok || bad "3 the refusal is logged ($(cat "$LOG"))"
[ ! -e "$C/pip/http/a/old31" ] && ok || bad "3 pip is still swept"

# ══ 4. sandbox: no BOX_HK_HOME, nothing touched ══════════════════════════════
build_fixture; : > "$LOG"
mkf "$T/home2/.cache/gh/old30" 30
mkf "$T/home2/.cache/pip/old90" 90
env -u BOX_HK_HOME HOME="$T/home2" HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 \
    BOX_HK_PROC="$FP" DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$T/units" bash "$S" > "$T/out" 2>&1
[ -f "$T/home2/.cache/gh/old30" ] && [ -f "$T/home2/.cache/pip/old90" ] && ok || bad "4 a sandboxed run with no BOX_HK_HOME touches nothing under \$HOME"
grep -q 'tool-caches skipped (BOX_HK_HOME unset under HARNESS_TEST_SANDBOX)' "$LOG" && ok || bad "4 the skip is logged ($(cat "$LOG"))"
grep -q 'tool-caches gh_files=' "$LOG" && bad "4 a skipped stage writes no summary line" || ok

# ══ 6. the run deadline ══════════════════════════════════════════════════════
# The first rm of a cache file takes 3 s, past TOOL_CACHE_RUN_DEADLINE_S=2:
# gh's one stale file goes, and pip's is left for the next run.
build_fixture; : > "$LOG"
FB="$T/fb"; mkdir -p "$FB"
cat > "$FB/rm" <<SH
#!/bin/bash
case "\$*" in *"$C/"*) [ -e "$T/rm.slept" ] || { : > "$T/rm.slept"; sleep 3; } ;; esac  # determinism: ok the slow delete IS the input under test, not a wait; more load only makes it longer, and longer still passes the 2 s deadline
exec /bin/rm "\$@"
SH
chmod +x "$FB/rm"; rm -f "$T/rm.slept"
run PATH="$FB:$PATH" TOOL_CACHE_RUN_DEADLINE_S=2
[ ! -e "$C/gh/old8" ] && ok || bad "6 the file judged before the deadline goes"
[ -f "$C/pip/http/a/old31" ] && ok || bad "6 past the deadline the pip file stays for the next run"
grep -q 'tool-caches hit TOOL_CACHE_RUN_DEADLINE_S=2s' "$LOG" && ok || bad "6 the deadline is logged ($(cat "$LOG"))"
rm -f "$FB/rm"
build_fixture; : > "$LOG"
run TOOL_CACHE_RUN_DEADLINE_S=1
[ -f "$C/gh/old8" ] && [ -f "$C/pip/http/a/old31" ] && ok || bad "6 TOOL_CACHE_RUN_DEADLINE_S=1 (under min 2) removes nothing"
grep -q 'TOOL_CACHE_RUN_DEADLINE_S invalid (1) - tool-caches skipped' "$LOG" && ok || bad "6 the invalid deadline is logged"

# ══ 7. a root that is not an absolute <home>/.cache/<name> is refused ═══════
# A relative BOX_HK_HOME resolves against the cwd. The run starts in a scratch
# cwd that holds a stale cache: the stage must refuse it, not sweep it.
build_fixture; : > "$LOG"
mkdir -p "$T/cwd"; mkf "$T/cwd/rel/.cache/gh/old30" 30
( cd "$T/cwd" && env HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 BOX_HK_HOME=rel BOX_HK_PROC="$FP" \
    DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$T/units" bash "$S" > "$T/out" 2>&1 )
[ -f "$T/cwd/rel/.cache/gh/old30" ] && ok || bad "7 a relative BOX_HK_HOME sweeps nothing"
grep -q 'tool-caches: rel/.cache/gh is not an absolute <home>/.cache/gh - refused' "$LOG" && ok || bad "7 the refusal is logged ($(cat "$LOG"))"
build_fixture; : > "$LOG"
run BOX_HK_HOME="$FH/../home"
[ -f "$C/gh/old8" ] && ok || bad "7 a root with a .. step sweeps nothing"
grep -q 'is not an absolute <home>/.cache/gh - refused' "$LOG" && ok || bad "7 the .. refusal is logged"

# ══ 5. nothing but the log word names the playwright cache ═══════════════════
hits=$(grep -v '^[[:space:]]*#' "$S" | grep -ci 'playwright')
pw=$(grep -v '^[[:space:]]*#' "$S" | grep -i 'playwright')
[ "$hits" = 1 ] && [[ $pw == *'playwright=untouched'* ]] && ok \
  || bad "5 only the log word playwright=untouched names that cache ($hits hits: $pw)"

echo "disk-clean-tool-caches: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
