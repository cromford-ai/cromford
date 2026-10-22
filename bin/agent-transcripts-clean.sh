#!/bin/bash
# bin/agent-transcripts-clean.sh [--dry-run] — the agent-transcripts stage of
# the daily disk-clean lane (bin/disk-clean.sh runs it as its stage 11, 04:47Z).
#
# It bounds $HOME/.claude/projects, where Claude Code writes the session
# transcripts and tool-result files of this box's own agent sessions:
#   - a regular file older than CLAUDE_TRANSCRIPT_KEEP_DAYS days (default 14,
#     minimum 3) is removed;
#   - then a directory under projects/ goes when this run emptied it, or when
#     it was already empty past the cutoff. projects/ itself always stays.
# KEPT at any age: a file any /proc/<pid>/fd link names (a live session holds
# its transcript open; one /proc scan, no lsof on these boxes), anything under
# a `memory/` directory of a project (the agent's persistent memory, read by
# bin/orchestrate.sh), a symlink and its target, and everything outside
# projects/ (settings*, plugins/, session-env/, backups/, the rest of $HOME).
# A projects/ that is itself a symlink is refused, never followed.
#
# It ships DRY. Only TRANSCRIPTS_DRY_RUN=0 (settings row
# lane.disk-clean.transcripts_dry_run) deletes. Any other value, or --dry-run,
# prints `would remove <path> (<kb> KB)` and logs one
# `dry-run would_remove=N freed_kb=K` line. A keep-days value that is not a
# whole number from 3 to 9999 skips the stage with a log line: the number gates
# deletion, so a guessed one is never used. Each count is bumped only after
# `[ ! -e ]` proved the removal, and the KB is read before it.
#
# Off: flags/lane-off-disk-clean (this is that lane's work). Knobs are
# disk-clean rows (catalog/lanes.d/disk-clean.knobs.d/).
# Test seams (every default is the live path): HARNESS_ROOT, BOX_HK_HOME,
# BOX_HK_PROC, DISK_CLEAN_NOW.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
HK_HOME="${BOX_HK_HOME:-${HOME:-/root}}"
PROC="${BOX_HK_PROC:-/proc}"
NOW_S="${DISK_CLEAN_NOW:-$(date +%s)}"

FLAG_DRY=0
case "${1:-}" in
  --dry-run) FLAG_DRY=1 ;;
  '') ;;
  *) echo "usage: bin/agent-transcripts-clean.sh [--dry-run]" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")
# Same lane gate and knob order as bin/disk-clean.sh: rows, then env/global.env,
# then the rows again so the box's env file cannot shadow a settings row.
# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit disk-clean
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean

LOG="$H/logs/disk-clean.log"
NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
mkdir -p "$H/logs" 2>/dev/null
say() { printf '%s [agent-transcripts] %s\n' "$NOW" "$*" >> "$LOG"; }

# An empty value is a set value: it is invalid, not the default.
KEEP_RAW="${CLAUDE_TRANSCRIPT_KEEP_DAYS-14}"
case "$KEEP_RAW" in
  ''|*[!0-9]*) KEEP_D="" ;;
  *) if [ "${#KEEP_RAW}" -le 4 ] && [ "$((10#$KEEP_RAW))" -ge 3 ]; then KEEP_D=$((10#$KEEP_RAW)); else KEEP_D=""; fi ;;
esac
if [ -z "$KEEP_D" ]; then
  say "CLAUDE_TRANSCRIPT_KEEP_DAYS invalid ($KEEP_RAW) - agent-transcripts stage skipped"
  exit 0
fi

DRY=1
if [ "$FLAG_DRY" = 0 ]; then
  case "${TRANSCRIPTS_DRY_RUN-1}" in
    0) DRY=0 ;;
    1) ;;
    *) say "TRANSCRIPTS_DRY_RUN invalid (${TRANSCRIPTS_DRY_RUN-}) - running dry" ;;
  esac
fi

R="$HK_HOME/.claude/projects"
if [ -L "$R" ]; then say "agent-transcripts: $R is a symlink - refused, not followed"; exit 0; fi
if [ ! -d "$R" ]; then say "agent-transcripts: absent $R"; exit 0; fi
CUT=$((NOW_S - KEEP_D * 86400))

# Every path any process holds open, in one pass over /proc.
declare -A HELD=()
while IFS= read -r l; do
  [ -n "$l" ] && HELD["$l"]=1
done < <(find "$PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%l\n' 2>/dev/null)

# is_memory <path> — rc 0 when the path is in, or is, a memory/ dir of a project.
is_memory() {
  case "/${1#"$R"/}/" in */memory/*) return 0 ;; esac
  return 1
}

removed=0; dirs=0; kb_sum=0; held=0; failed=0; would=0
declare -A EMPTIED=()
while IFS= read -r -d '' rec; do
  mt="${rec%%.*}"; rest="${rec#*$'\t'}"
  kb="${rest%%$'\t'*}"; f="${rest#*$'\t'}"
  case "$mt" in ''|*[!0-9]*) continue ;; esac
  [ "$mt" -lt "$CUT" ] || continue
  case "$f" in "$R"/?*) ;; *) continue ;; esac
  is_memory "$f" && continue
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  if [ -n "${HELD[$f]:-}" ]; then held=$((held + 1)); continue; fi
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  if [ "$DRY" = 1 ]; then
    echo "would remove $f ($kb KB)"; would=$((would + 1)); kb_sum=$((kb_sum + kb)); continue
  fi
  rm -f -- "$f" 2>/dev/null
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    removed=$((removed + 1)); kb_sum=$((kb_sum + kb)); EMPTIED["${f%/*}"]=1
  else
    say "kept: $f could not be removed"; failed=$((failed + 1))
  fi
done < <(find -P "$R" -xdev -mindepth 2 -type f -printf '%T@\t%k\t%p\0' 2>/dev/null)

if [ "$DRY" = 1 ]; then
  say "agent-transcripts: dry-run would_remove=$would freed_kb=$kb_sum skipped_held=$held keep_days=$KEEP_D"
  exit 0
fi

# Deepest first, so a parent is judged after its children. A dir goes when
# this run emptied it or it was already empty past the cutoff; a fresh empty
# dir is a writer's, and rmdir refuses one a writer just filled.
while IFS= read -r -d '' rec; do
  mt="${rec%%.*}"; d="${rec#*$'\t'}"
  case "$d" in "$R"/?*) ;; *) continue ;; esac
  is_memory "$d" && continue
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  case "$mt" in ''|*[!0-9]*) mt="$NOW_S" ;; esac
  [ -n "${EMPTIED[$d]:-}" ] || [ "$mt" -lt "$CUT" ] || continue
  [ -z "$(find "$d" -mindepth 1 -print -quit 2>/dev/null)" ] || continue
  if rmdir -- "$d" 2>/dev/null && [ ! -e "$d" ]; then
    dirs=$((dirs + 1)); EMPTIED["${d%/*}"]=1
  fi
done < <(find -P "$R" -xdev -mindepth 1 -depth -type d -printf '%T@\t%p\0' 2>/dev/null)

say "agent-transcripts: removed_files=$removed removed_dirs=$dirs freed_kb=$kb_sum skipped_held=$held failed=$failed keep_days=$KEEP_D"
exit 0
