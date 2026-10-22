#!/bin/bash
# tests/disk-clean-transcripts.bh-7933-test.sh — BH-7933: the disk-clean stage
# `agent-transcripts` that bounds ~/.claude/projects at CLAUDE_TRANSCRIPT_KEEP_DAYS.
#
# What is proved here, against the REAL bin/agent-transcripts-clean.sh (and, in
# §6, the real bin/disk-clean.sh that runs it from cron) over a fixture HOME and
# /proc through the BOX_HK_HOME / BOX_HK_PROC seams and a frozen DISK_CLEAN_NOW:
#   §1  age and dry: with no knobs a 15d transcript is only counted
#       (`dry-run would_remove=N freed_kb=K`), with TRANSCRIPTS_DRY_RUN=0 it goes;
#       a 13d file and a file at exactly the cutoff stay;
#   §2  dirs: a dir the run emptied and an old empty dir go; projects/ itself,
#       a dir still holding a file and a fresh empty dir stay; an unremovable
#       file is counted failed, never removed;
#   §3  a 15d file a /proc/<pid>/fd link names is kept (skipped_held=1); a link
#       to another file holds nothing else;
#   §4  off-limits at any age: .claude/settings*, plugins/, session-env/,
#       backups/, $HOME outside .claude, projects/*/memory/; a symlink and its
#       target; a projects/ that is itself a symlink is refused;
#   §5  knobs: an invalid keep-days skips the stage with a log line; 3 and 20
#       move the cutoff; only an exact TRANSCRIPTS_DRY_RUN=0 deletes; --dry-run
#       wins over 0; an absent projects/ logs `absent`;
#   §6  the production entry point: bin/disk-clean.sh runs the stage dry;
#   §7  an unknown flag exits 2 and deletes nothing.
# Run from anywhere: tests/disk-clean-transcripts.bh-7933-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$DIR/bin/agent-transcripts-clean.sh" ] || { echo "FAIL: bin/agent-transcripts-clean.sh does not exist"; exit 1; }
HH="$T/h"
mkdir -p "$HH/logs"
scratch_install_closure bin/agent-transcripts-clean.sh "$HH" >/dev/null || { echo "FAIL: cannot install the closure"; exit 1; }
AT="$HH/bin/agent-transcripts-clean.sh"

NOW=1789514400                     # 2026-09-15T23:20:00Z — every age derives from this
DAY=86400
age() { # age <seconds-ago> <path...>
  local s=$1; shift
  touch -h -d "@$((NOW - s))" "$@"
}

FH="$T/home"; FP="$T/proc"; PR="$FH/.claude/projects"; SID="sid-bh7933-a"
build_fixture() {
  scratch_rm "$FH"; scratch_rm "$FP"; scratch_rm "$T/outside"
  mkdir -p "$PR/p/$SID/tool-results" "$PR/p/memory" "$PR/q" "$PR/r" "$PR/s" \
           "$FH/.claude/plugins/p" "$FH/.claude/session-env/s" "$FH/.claude/backups" \
           "$FH/other" "$FP/123/fd" "$FP/124/fd" "$T/outside"
  echo aaaa > "$PR/p/a.jsonl";                        age $((15 * DAY)) "$PR/p/a.jsonl"
  echo tttt > "$PR/p/$SID/tool-results/t.txt";       age $((15 * DAY)) "$PR/p/$SID/tool-results/t.txt"
  echo bbbb > "$PR/p/b.jsonl";                        age $((13 * DAY)) "$PR/p/b.jsonl"
  echo edge > "$PR/s/edge.jsonl";                     age $((14 * DAY)) "$PR/s/edge.jsonl"
  echo held > "$PR/p/held.jsonl";                     age $((15 * DAY)) "$PR/p/held.jsonl"
  echo near > "$PR/p/near.jsonl";                     age $((15 * DAY)) "$PR/p/near.jsonl"
  echo mem  > "$PR/p/memory/MEMORY.md";               age $((30 * DAY)) "$PR/p/memory/MEMORY.md"
  echo fact > "$PR/p/memory/fact.md";                 age $((30 * DAY)) "$PR/p/memory/fact.md"
  echo nm   > "$PR/p/notes-memory.md";                age $((15 * DAY)) "$PR/p/notes-memory.md"
  echo out  > "$T/outside/target.txt";                age $((30 * DAY)) "$T/outside/target.txt"
  ln -s "$T/outside/target.txt" "$PR/p/link.jsonl";   age $((15 * DAY)) "$PR/p/link.jsonl"
  for f in settings.json settings.local.json plugins/p/x session-env/s/x backups/b; do
    echo x > "$FH/.claude/$f"; age $((30 * DAY)) "$FH/.claude/$f"
  done
  echo x > "$FH/other/old.jsonl";                     age $((30 * DAY)) "$FH/other/old.jsonl"
  age $((15 * DAY)) "$PR/p/$SID/tool-results" "$PR/p/$SID"
  age $((30 * DAY)) "$PR/r" "$PR/p/memory"           # r: old and empty
  age 3600 "$PR/q"                                   # q: fresh and empty
  ln -s "$PR/p/held.jsonl" "$FP/123/fd/4"
  ln -s "$T/outside/target.txt" "$FP/124/fd/5"       # near miss: a different file
}
at() { # at [env...] [-- args] -> runs the stage over the fixture; stdout in $T/out
  local args=() envs=()
  while [ $# -gt 0 ]; do
    [ "$1" = -- ] && { shift; args=("$@"); break; }
    envs+=("$1"); shift
  done
  env -u CLAUDE_TRANSCRIPT_KEEP_DAYS -u TRANSCRIPTS_DRY_RUN \
      HARNESS_ROOT="$HH" HARNESS="$HH" BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" \
      DISK_CLEAN_NOW="$NOW" "${envs[@]}" bash "$AT" "${args[@]}" > "$T/out" 2>&1
}
LOG="$HH/logs/disk-clean.log"
last() { grep '\[agent-transcripts\]' "$LOG" 2>/dev/null | tail -1; }
kb() { du -k -- "$1" | cut -f1; }

# ══ 1. age and dry ═══════════════════════════════════════════════════════════
build_fixture; : > "$LOG"
KB_DRY=$(( $(kb "$PR/p/a.jsonl") + $(kb "$PR/p/$SID/tool-results/t.txt") + $(kb "$PR/p/near.jsonl") + $(kb "$PR/p/notes-memory.md") ))
at; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the dry run exits 0 (rc=$RC: $(cat "$T/out"))"
[ -f "$PR/p/a.jsonl" ] && [ -f "$PR/p/$SID/tool-results/t.txt" ] && ok \
  || bad "1 with no knobs the stage is dry: the 15d files must stay"
last | grep -q "agent-transcripts: dry-run would_remove=4 freed_kb=$KB_DRY skipped_held=1 keep_days=14" && ok \
  || bad "1 the dry line names would_remove=4 freed_kb=$KB_DRY (got: $(last))"
grep -q "would remove $PR/p/a.jsonl" "$T/out" && grep -q "would remove $PR/p/$SID/tool-results/t.txt" "$T/out" && ok \
  || bad "1 the dry run names each file it would remove ($(cat "$T/out"))"
grep -q "would remove $PR/p/b.jsonl" "$T/out" && bad "1 a 13d file is not a candidate" || ok
at TRANSCRIPTS_DRY_RUN=0; RC=$?
[ "$RC" = 0 ] && ok || bad "1 the live run exits 0 (rc=$RC)"
[ ! -e "$PR/p/a.jsonl" ] && ok || bad "1 a 15d transcript must go with TRANSCRIPTS_DRY_RUN=0"
[ ! -e "$PR/p/$SID/tool-results/t.txt" ] && ok || bad "1 a 15d nested tool result must go"
[ -f "$PR/p/b.jsonl" ] && ok || bad "1 a 13d transcript must stay"
[ -f "$PR/s/edge.jsonl" ] && ok || bad "1 a file at exactly the cutoff (14d 0s) must stay"
last | grep -q 'agent-transcripts: removed_files=4 removed_dirs=[0-9]* freed_kb=[0-9]* skipped_held=1 failed=0 keep_days=14' && ok \
  || bad "1 the live line names removed_files=4 (got: $(last))"

# ══ 2. dirs ══════════════════════════════════════════════════════════════════
[ ! -e "$PR/p/$SID/tool-results" ] && [ ! -e "$PR/p/$SID" ] && ok || bad "2 dirs the run emptied must go"
[ -d "$PR" ] && ok || bad "2 projects/ itself must stay"
[ -d "$PR/p" ] && ok || bad "2 a dir still holding a file must stay"
[ -d "$PR/q" ] && ok || bad "2 a fresh empty dir must stay"
[ ! -e "$PR/r" ] && ok || bad "2 an old empty dir must go"
[ -d "$PR/p/memory" ] && ok || bad "2 a memory dir must stay"
last | grep -q 'removed_dirs=3 ' && ok || bad "2 removed_dirs counts the 3 dirs really gone (got: $(last))"
# An unremovable file: a read-only parent as a user, an immutable file as root.
build_fixture; : > "$LOG"
UF="$PR/p/$SID/tool-results/t.txt"
if [ "$(id -u)" != 0 ]; then
  chmod 555 "$PR/p/$SID/tool-results"; LOCKED=1
elif chattr +i "$UF" 2>/dev/null; then
  LOCKED=1
else
  LOCKED=0; echo "note: root with no chattr +i here - the unremovable-file case of §2 is skipped"
fi
if [ "$LOCKED" = 1 ]; then
  at TRANSCRIPTS_DRY_RUN=0
  chattr -i "$UF" 2>/dev/null; chmod 755 "$PR/p/$SID/tool-results"
  [ -f "$UF" ] && ok || bad "2 the unremovable file is still there"
  last | grep -q 'removed_files=3 .*failed=1 ' && ok || bad "2 an unremovable file is counted failed=1, not removed (got: $(last))"
  grep -q "kept: $UF could not be removed" "$LOG" && ok || bad "2 an unremovable file gets a kept: line"
fi

# ══ 3. held ══════════════════════════════════════════════════════════════════
build_fixture; : > "$LOG"
at TRANSCRIPTS_DRY_RUN=0
[ -f "$PR/p/held.jsonl" ] && ok || bad "3 a 15d file a /proc fd names must stay"
[ ! -e "$PR/p/near.jsonl" ] && ok || bad "3 a 15d file next to an fd link to another path must go"
last | grep -q 'skipped_held=1 ' && ok || bad "3 the line names skipped_held=1 (got: $(last))"

# ══ 4. off-limits ════════════════════════════════════════════════════════════
for f in settings.json settings.local.json plugins/p/x session-env/s/x backups/b; do
  [ -f "$FH/.claude/$f" ] && ok || bad "4 ~/.claude/$f must stay at any age"
done
[ -f "$FH/other/old.jsonl" ] && ok || bad "4 \$HOME outside .claude must stay"
[ -f "$PR/p/memory/MEMORY.md" ] && [ -f "$PR/p/memory/fact.md" ] && ok || bad "4 projects/*/memory/ must stay at any age"
[ ! -e "$PR/p/notes-memory.md" ] && ok || bad "4 a 15d notes-memory.md is not a memory dir and must go"
[ -L "$PR/p/link.jsonl" ] && ok || bad "4 a symlink in projects/ must stay"
[ -f "$T/outside/target.txt" ] && ok || bad "4 a symlink's target must stay"
# projects/ itself a symlink: refused, its target untouched
build_fixture; : > "$LOG"
mkdir -p "$T/outside/real/p"; echo x > "$T/outside/real/p/old.jsonl"; age $((30 * DAY)) "$T/outside/real/p/old.jsonl"
scratch_rm "$PR"; ln -s "$T/outside/real" "$PR"
at TRANSCRIPTS_DRY_RUN=0; RC=$?
[ "$RC" = 0 ] && ok || bad "4 a symlinked projects/ exits 0 (rc=$RC)"
[ -f "$T/outside/real/p/old.jsonl" ] && ok || bad "4 a symlinked projects/ must not be followed"
last | grep -q 'is a symlink - refused' && ok || bad "4 a symlinked projects/ is logged refused (got: $(last))"

# ══ 5. knobs ═════════════════════════════════════════════════════════════════
for v in 2 abc -5 14.5 99999 ''; do
  build_fixture; : > "$LOG"
  at TRANSCRIPTS_DRY_RUN=0 CLAUDE_TRANSCRIPT_KEEP_DAYS="$v"; RC=$?
  [ "$RC" = 0 ] && ok || bad "5 keep-days '$v' exits 0 (rc=$RC)"
  [ -f "$PR/p/a.jsonl" ] && ok || bad "5 keep-days '$v' must delete nothing"
  last | grep -q "CLAUDE_TRANSCRIPT_KEEP_DAYS invalid ($v) - agent-transcripts stage skipped" && ok \
    || bad "5 keep-days '$v' is logged invalid (got: $(last))"
done
build_fixture; : > "$LOG"
echo x > "$PR/p/four.jsonl"; age $((4 * DAY)) "$PR/p/four.jsonl"
at TRANSCRIPTS_DRY_RUN=0 CLAUDE_TRANSCRIPT_KEEP_DAYS=3
[ ! -e "$PR/p/four.jsonl" ] && ok || bad "5 keep-days 3 (the minimum) must remove a 4d file"
last | grep -q 'keep_days=3$' && ok || bad "5 keep-days 3 is used (got: $(last))"
build_fixture; : > "$LOG"
at TRANSCRIPTS_DRY_RUN=0 CLAUDE_TRANSCRIPT_KEEP_DAYS=20
[ -f "$PR/p/a.jsonl" ] && ok || bad "5 keep-days 20 must keep a 15d file"
for v in yes 00 2 ' 0'; do
  build_fixture; : > "$LOG"
  at TRANSCRIPTS_DRY_RUN="$v"
  [ -f "$PR/p/a.jsonl" ] && ok || bad "5 TRANSCRIPTS_DRY_RUN='$v' must run dry"
  grep -q "TRANSCRIPTS_DRY_RUN invalid ($v) - running dry" "$LOG" && ok || bad "5 TRANSCRIPTS_DRY_RUN='$v' is logged invalid"
  last | grep -q 'dry-run would_remove=' && ok || bad "5 TRANSCRIPTS_DRY_RUN='$v' writes the dry line (got: $(last))"
done
build_fixture; : > "$LOG"
at TRANSCRIPTS_DRY_RUN=1
[ -f "$PR/p/a.jsonl" ] && last | grep -q 'dry-run would_remove=4 ' && ok || bad "5 TRANSCRIPTS_DRY_RUN=1 runs dry (got: $(last))"
grep -q 'TRANSCRIPTS_DRY_RUN invalid' "$LOG" && bad "5 TRANSCRIPTS_DRY_RUN=1 is valid" || ok
at TRANSCRIPTS_DRY_RUN=0 -- --dry-run
[ -f "$PR/p/a.jsonl" ] && ok || bad "5 --dry-run wins over TRANSCRIPTS_DRY_RUN=0"
build_fixture; : > "$LOG"
scratch_rm "$PR"
at TRANSCRIPTS_DRY_RUN=0; RC=$?
[ "$RC" = 0 ] && ok || bad "5 an absent projects/ exits 0 (rc=$RC)"
last | grep -q "agent-transcripts: absent $PR" && ok || bad "5 an absent projects/ is logged (got: $(last))"

# ══ 6. the production entry point: bin/disk-clean.sh ═════════════════════════
build_fixture; : > "$LOG"
mkdir -p "$HH/state" "$T/repos" "$T/fakebin" "$T/npmdir"
scratch_install_closure bin/disk-clean.sh "$HH" >/dev/null || bad "6 cannot install bin/disk-clean.sh"
cat > "$T/fakebin/npm" <<SH
#!/bin/bash
printf '%s\n' "npm \$*" >> "$T/npm.calls"
SH
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/pgrep"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/crontab"
chmod +x "$T/fakebin/"*
env -u CLAUDE_TRANSCRIPT_KEEP_DAYS -u TRANSCRIPTS_DRY_RUN PATH="$T/fakebin:$PATH" \
    HARNESS_ROOT="$HH" HARNESS="$HH" DISK_CLEAN_REPOS="$T/repos" DISK_CLEAN_NPM_DIR="$T/npmdir" \
    DISK_CLEAN_NOW="$NOW" DISK_CLEAN_PROC="$FP" BOX_HK_HOME="$FH" BOX_HK_PROC="$FP" \
    BOX_HK_TMP="$T/emptytmp" bash "$HH/bin/disk-clean.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "6 bin/disk-clean.sh exits 0 (rc=$RC)"
grep -q '\[agent-transcripts\] agent-transcripts: dry-run would_remove=4 freed_kb=' "$LOG" && ok \
  || bad "6 bin/disk-clean.sh must run the agent-transcripts stage dry ($(grep -c . "$LOG") log lines)"
[ -f "$PR/p/a.jsonl" ] && ok || bad "6 the cron run is dry by default: the 15d file must stay"
grep -q 'disk-clean: .*cronlogs_cut=' "$LOG" && ok || bad "6 the disk-clean summary line keeps its shape"

# ══ 7. args ══════════════════════════════════════════════════════════════════
build_fixture; : > "$LOG"
at TRANSCRIPTS_DRY_RUN=0 -- --bogus; RC=$?
[ "$RC" = 2 ] && [ -f "$PR/p/a.jsonl" ] && ok || bad "7 an unknown flag exits 2 and deletes nothing (rc=$RC)"
[ ! -s "$LOG" ] && ok || bad "7 an unknown flag writes no log line"

echo "disk-clean-transcripts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
