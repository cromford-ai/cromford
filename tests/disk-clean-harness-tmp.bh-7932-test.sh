#!/bin/bash
# tests/disk-clean-harness-tmp.bh-7932-test.sh — BH-7932 stage `harness-tmp`:
# bin/disk-clean-stages.sh removes a stale top-level entry of $HARNESS/tmp only
# when nothing holds it, nothing claims it and no keep-glob names it.
#
# What is proved here, against the REAL bin/disk-clean-stages.sh over a scratch
# $HARNESS, a fake /proc (BOX_HK_PROC) and a frozen clock (DISK_CLEAN_NOW):
#   §1  an 8d entry with no reference, a 30d scratch dir and an 8d file go; a
#       6d entry, an 8d entry with a 1d nested file, entries held by a /proc
#       cwd, fd or argv argument, an entry named in a job claim, the keep-glob
#       names at 30d and a symlink stay; scratch.ABC goes while scratch.ABCdef
#       is held (prefix near miss); the summary line counts each outcome. The
#       claim is a job_claims row served by a fake $HARNESS/bin/jobs-client.sh
#       (_jobs_req) for the one project of a scratch FLEET_CONF;
#   §1b the job_claims rows cannot be read (the fake answers rc 1, or the
#       project list is empty): the stage is skipped and logged, nothing goes;
#   §2  HARNESS_TMP_STALE_D below 2 or not a number: the stage is skipped and
#       logged, nothing is removed;
#   §3  an age the scan cannot read keeps the entry (skipped_unreadable);
#   §4  a removal that fails counts failed=1, removed=0;
#   §5  the run deadline leaves the rest untouched and counted left=;
#   §6  a held lock: one log line, nothing removed;
#   §7  the production entry point: bin/disk-clean.sh runs the stage as stage 12
#       and its own summary line keeps its shape.
# Run from anywhere: tests/disk-clean-harness-tmp.bh-7932-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

S="$REPO/bin/disk-clean-stages.sh"
[ -f "$S" ] || { echo "FAIL: bin/disk-clean-stages.sh does not exist"; exit 1; }
unset HARNESS_TMP_STALE_D HARNESS_TMP_SCAN_TIMEOUT_S HARNESS_TMP_RUN_DEADLINE_S HARNESS_TMP_KEEP_GLOBS 2>/dev/null || true

NOW=1789514400                     # 2026-09-15T23:20:00Z — every age derives from this
DAY=86400
age() { local s=$1; shift; touch -h -d "@$((NOW - s))" "$@"; }

HH="$T/h"; HT="$HH/tmp"; FP="$T/proc"; FH="$T/home"; FB="$T/fakebin"
LOG="$HH/logs/disk-clean.log"
mkent() { # mkent <name> <days> — a dir with one file, both at <days>
  mkdir -p "$HT/$1"; echo x > "$HT/$1/f"; age $(($2 * DAY)) "$HT/$1/f" "$HT/$1"
}
build_fixture() {
  scratch_rm "$HH"; scratch_rm "$FP"; scratch_rm "$FH"; scratch_rm "$T/outside"; scratch_rm "$FB"
  mkdir -p "$HT" "$HH/logs" "$HH/locks" "$HH/bin" "$FP/1" "$FH" "$T/outside" "$FB"
  mkent old8 8
  mkent scratch-x 30; mkdir -p "$HT/scratch-x/deep"; echo x > "$HT/scratch-x/deep/g"
  age $((30 * DAY)) "$HT/scratch-x/deep/g" "$HT/scratch-x/deep" "$HT/scratch-x"
  echo x > "$HT/old-file.txt"; age $((8 * DAY)) "$HT/old-file.txt"
  mkent heldcwd 8; mkdir -p "$HT/heldcwd/sub"; age $((8 * DAY)) "$HT/heldcwd/sub" "$HT/heldcwd"
  mkent heldfd 8
  mkent heldarg 8
  mkent fresh6 6
  mkent nested 8; mkdir -p "$HT/nested/in"; echo x > "$HT/nested/in/new"
  age $((1 * DAY)) "$HT/nested/in/new"; age $((8 * DAY)) "$HT/nested/in" "$HT/nested"
  mkent claimed 8
  for k in conductor batch-resolve brfix; do mkent "$k" 30; done
  mkent scratch.ABCdef 8
  mkent scratch.ABC 8
  echo x > "$T/outside/keep.txt"; age $((30 * DAY)) "$T/outside/keep.txt" "$T/outside"
  ln -s "$T/outside" "$HT/link"; age $((30 * DAY)) "$HT/link"
  # the fake /proc: cwd, fd and argv references
  mkdir -p "$FP/101" "$FP/102/fd" "$FP/103" "$FP/104"
  ln -s "$HT/heldcwd/sub" "$FP/101/cwd"
  ln -s "$HT/heldfd/f" "$FP/102/fd/3"
  printf 'bash\0--dir=%s/heldarg/x\0' "$HT" > "$FP/103/cmdline"
  ln -s "$HT/scratch.ABCdef" "$FP/104/cwd"
  ln -s / "$FP/1/cwd"                          # pid 1's cwd is / and holds nothing here
  # the job_claims rows: project p, key K-1 claims $HT/claimed; $T/jobs.down
  # makes the fake answer like an outage. A real row's planned_files is the
  # build's repo-relative file list and never names a $HARNESS/tmp path, so in
  # prod this guard keeps nothing today; this row proves the parsing and the
  # match for a claim that does name one. The cwd, fd and argv guards are what
  # protect a live dir (case 1: heldcwd, heldfd, heldarg).
  printf 'p box-x\n' > "$T/fleet.conf"; rm -f "$T/jobs.down"
  cat > "$HH/bin/jobs-client.sh" <<SH
_jobs_req() {
  [ -e "$T/jobs.down" ] && return 1
  [ "\$1 \$2" = "GET /api/file-claims?project=p" ] || return 1
  printf '{"claims":[{"ticket_id":"K-1","files_claimed_at":"2026-09-15T00:00:00Z","planned_files":"%s"}]}' "$HT/claimed"
}
SH
}
run() { # run [env...] — the stages over the fixture; stdout+stderr in $T/out
  env HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" \
      FLEET_CONF="$T/fleet.conf" REGISTRY_SOURCE=file DISK_CLEAN_NOW="$NOW" DISK_CLEAN_UNIT_DIRS="$T/units" "$@" bash "$S" > "$T/out" 2>&1
}
line() { grep 'harness-tmp removed=' "$LOG" | tail -n 1; }
field() { # field <name> — the value of <name>= on the last harness-tmp line
  line | tr ' ' '\n' | sed -n "s/^$1=//p"
}

# ══ 1. the decision rule, default knobs ══════════════════════════════════════
build_fixture
run; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the run exits 0 (rc=$RC: $(cat "$T/out"))"
for g in old8 scratch-x old-file.txt scratch.ABC; do
  [ ! -e "$HT/$g" ] && ok || bad "1 $g (stale, unheld, unclaimed) must be removed"
done
for k in heldcwd heldfd heldarg fresh6 nested claimed conductor batch-resolve brfix scratch.ABCdef; do
  [ -d "$HT/$k" ] && ok || bad "1 $k must be kept"
done
[ -f "$HT/nested/in/new" ] && ok || bad "1 the 1d nested file keeps its 8d parent whole"
[ -L "$HT/link" ] && [ -f "$T/outside/keep.txt" ] && ok || bad "1 a symlink is kept and its target untouched"
[ "$(field removed)" = 4 ] && ok || bad "1 removed=4 ($(line))"
[ "$(field skipped_held)" = 5 ] && ok || bad "1 skipped_held=5: cwd, fd, argv, claim, ABCdef ($(line))"
[ "$(field skipped_fresh)" = 2 ] && ok || bad "1 skipped_fresh=2: fresh6, nested ($(line))"
[ "$(field skipped_kept)" = 3 ] && ok || bad "1 skipped_kept=3: conductor batch-resolve brfix ($(line))"
[ "$(field left)" = 0 ] && ok || bad "1 left=0 ($(line))"
[ "$(field failed)" = 0 ] && ok || bad "1 failed=0 ($(line))"
[ "$(field stale_d)" = 7 ] && ok || bad "1 the default HARNESS_TMP_STALE_D is 7 ($(line))"
fk=$(field freed_kb)
case "$fk" in ''|*[!0-9]*) bad "1 freed_kb is a number ($(line))" ;; *) [ "$fk" -gt 0 ] && ok || bad "1 freed_kb > 0 ($(line))" ;; esac
grep -q '\[disk-clean-stages\] harness-tmp removed=' "$LOG" && ok || bad "1 the line is tagged [disk-clean-stages]"
# the knob moves the cutoff
build_fixture
run HARNESS_TMP_STALE_D=9
[ -d "$HT/old8" ] && ok || bad "1 HARNESS_TMP_STALE_D=9 keeps an 8d entry"
[ ! -e "$HT/scratch-x" ] && ok || bad "1 HARNESS_TMP_STALE_D=9 still removes a 30d entry"
# the keep-glob knob is read
build_fixture
run "HARNESS_TMP_KEEP_GLOBS=old*"
[ -d "$HT/old8" ] && ok || bad "1 HARNESS_TMP_KEEP_GLOBS=old* keeps old8"
[ ! -e "$HT/brfix" ] && ok || bad "1 a keep-glob list without brfix lets a 30d brfix go"

# ══ 1b. unreadable job_claims rows skip the stage ═════════════════════════════
build_fixture; : > "$LOG"; : > "$T/jobs.down"
run; RC=$?
[ "$RC" = 0 ] && ok || bad "1b an outage still exits 0 (rc=$RC)"
[ -d "$HT/old8" ] && [ -d "$HT/scratch-x" ] && ok || bad "1b a job_claims outage must remove nothing"
grep -q 'harness-tmp skipped: job_claims rows unreadable' "$LOG" && ok || bad "1b the outage is logged ($(cat "$LOG"))"
grep -q 'harness-tmp removed=' "$LOG" && bad "1b a skipped stage writes no summary line" || ok
build_fixture; : > "$LOG"; : > "$T/fleet.conf"
run
[ -d "$HT/old8" ] && ok || bad "1b an empty project list must remove nothing"
grep -q 'job_claims rows unreadable' "$LOG" && ok || bad "1b an empty project list is logged ($(cat "$LOG"))"

# ══ 2. an invalid stale knob skips the stage ═════════════════════════════════
for junk in 1 abc; do
  build_fixture; : > "$LOG"
  run HARNESS_TMP_STALE_D=$junk
  [ -d "$HT/old8" ] && [ -d "$HT/scratch-x" ] && ok || bad "2 HARNESS_TMP_STALE_D=$junk must remove nothing"
  grep -q "HARNESS_TMP_STALE_D invalid ($junk) - harness-tmp skipped" "$LOG" && ok || bad "2 HARNESS_TMP_STALE_D=$junk is logged ($(cat "$LOG"))"
  grep -q 'harness-tmp removed=' "$LOG" && bad "2 a skipped stage writes no summary line" || ok
done

# ══ 3. an unreadable age keeps the entry ═════════════════════════════════════
build_fixture; mkent unread 30
cat > "$FB/find" <<SH
#!/bin/bash
[ "\${1:-}" = -P ] && case "\${2:-}" in */unread) exit 1 ;; esac
exec /usr/bin/find "\$@"
SH
chmod +x "$FB/find"
run PATH="$FB:$PATH"
[ -d "$HT/unread" ] && ok || bad "3 an entry whose age cannot be read is kept"
[ "$(field skipped_unreadable)" = 1 ] && ok || bad "3 skipped_unreadable=1 ($(line))"
[ ! -e "$HT/old8" ] && ok || bad "3 the other stale entries still go"
rm -f "$FB/find"

# ══ 4. a failed removal is counted, never as removed ═════════════════════════
build_fixture
scratch_rm "$HT"; mkdir -p "$HT"; mkent stuck 8
printf '#!/bin/bash\nexit 1\n' > "$FB/rm"; printf '#!/bin/bash\nexit 1\n' > "$FB/chattr"; chmod +x "$FB/rm" "$FB/chattr"
run PATH="$FB:$PATH"
[ -d "$HT/stuck" ] && ok || bad "4 the stub rm leaves the entry"
[ "$(field failed)" = 1 ] && [ "$(field removed)" = 0 ] && [ "$(field freed_kb)" = 0 ] && ok \
  || bad "4 failed=1 removed=0 freed_kb=0 ($(line))"
rm -f "$FB/rm" "$FB/chattr"

# ══ 5. the run deadline ══════════════════════════════════════════════════════
build_fixture
scratch_rm "$HT"; mkdir -p "$HT"; mkent d1 8; mkent d2 8; mkent d3 8
cat > "$FB/du" <<SH
#!/bin/bash
[ -e "$T/du.slept" ] || { : > "$T/du.slept"; sleep 3; }  # determinism: ok the slow scan IS the input under test, not a wait; more load only makes it longer, and longer still leaves left=2
exec /usr/bin/du "\$@"
SH
chmod +x "$FB/du"; rm -f "$T/du.slept"
run PATH="$FB:$PATH" HARNESS_TMP_RUN_DEADLINE_S=2
n=0; for e in d1 d2 d3; do [ -d "$HT/$e" ] && n=$((n + 1)); done
[ "$n" = 2 ] && ok || bad "5 the deadline leaves 2 of 3 stale entries untouched ($n left)"
[ "$(field left)" = 2 ] && [ "$(field removed)" = 1 ] && ok || bad "5 left=2 removed=1 ($(line))"
rm -f "$FB/du"
build_fixture; : > "$LOG"
run HARNESS_TMP_RUN_DEADLINE_S=1
[ -d "$HT/old8" ] && ok || bad "5 HARNESS_TMP_RUN_DEADLINE_S=1 (under min 2) removes nothing"
grep -q 'HARNESS_TMP_RUN_DEADLINE_S invalid' "$LOG" && ok || bad "5 the invalid deadline is logged"

# ══ 6. a held lock ═══════════════════════════════════════════════════════════
build_fixture; : > "$LOG"
exec 8>"$HH/locks/disk-clean-stages.lock"; flock -n 8
run; RC=$?
exec 8>&-
[ "$RC" = 0 ] && ok || bad "6 a held lock exits 0 (rc=$RC)"
[ -d "$HT/old8" ] && ok || bad "6 a held lock removes nothing"
grep -q 'lock held' "$LOG" && ok || bad "6 a held lock is one log line ($(cat "$LOG"))"

# ══ 7. the production entry point: bin/disk-clean.sh stage 12 ════════════════
build_fixture
scratch_rm "$HT"; mkdir -p "$HT"; mkent old8 8
mkdir -p "$HH/state" "$T/repos" "$T/npmdir"
scratch_install_closure bin/disk-clean-stages.sh "$HH" >/dev/null || bad "7 the closure installs"
scratch_install_closure bin/fleet-conf.sh "$HH" >/dev/null || bad "7 bin/fleet-conf.sh installs (the stage runs it for the project list)"
chmod +x "$HH/bin/disk-clean-stages.sh"
printf '#!/bin/bash\nexit 1\n' > "$FB/pgrep"; printf '#!/bin/bash\nexit 1\n' > "$FB/crontab"
printf '#!/bin/bash\nexit 0\n' > "$FB/npm"; chmod +x "$FB/"*
: > "$LOG"
env PATH="$FB:$PATH" HARNESS_ROOT="$HH" HARNESS="$HH" HARNESS_TEST_SANDBOX=1 DISK_CLEAN_REPOS="$T/repos" \
    DISK_CLEAN_NPM_DIR="$T/npmdir" DISK_CLEAN_NOW="$NOW" DISK_CLEAN_PROC="$FP" \
    BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" DISK_CLEAN_UNIT_DIRS="$T/units" \
    FLEET_CONF="$T/fleet.conf" REGISTRY_SOURCE=file \
    bash "$REPO/bin/disk-clean.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "7 bin/disk-clean.sh exits 0 (rc=$RC)"
[ ! -e "$HT/old8" ] && ok || bad "7 bin/disk-clean.sh must run the harness-tmp stage"
grep -q '\[disk-clean-stages\] harness-tmp removed=1 ' "$LOG" && ok || bad "7 one harness-tmp removed=1 line ($(cat "$LOG"))"
grep -Eq ' disk-clean: [0-9]+%->[0-9]+% npm=' "$LOG" && ok || bad "7 the disk-clean summary line keeps its shape"

echo "disk-clean-harness-tmp: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
