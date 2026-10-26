#!/bin/bash
# bin/disk-clean-stages.sh — three more stages of the daily disk-clean lane
# (bin/disk-clean.sh runs this as its stage 12, 04:47Z, every box).
#
# WHY. The 2026-10-21 fleet survey: disk-clean freed 0 on the two near-full
# boxes (small 80%->80%, project-3 88%->88%). What fills them is outside its other
# stages: $HARNESS/tmp (hub 7.7 GB; small 5.5 GB, 4.7 GB of it older than 7
# days), ~/.cache (hub: gh 1.1 GB, pip 0.3 GB) and hand-made dirs under /root
# (hub: wt-orc 11 GB). Each stage writes one summary line, tagged
# [disk-clean-stages], to logs/disk-clean.log.
#
#   1. harness-tmp: a top-level entry of $HARNESS/tmp is removed only when ALL
#      of these hold:
#        - its basename matches no glob in HARNESS_TMP_KEEP_GLOBS (default
#          `conductor batch-resolve brfix state-restore`: live lane dirs and an
#          operator CLI's DEST);
#        - it is not a symlink, socket or FIFO, and it is on the same mount as
#          $HARNESS/tmp;
#        - its NEWEST mtime anywhere inside, read within
#          HARNESS_TMP_SCAN_TIMEOUT_S, is older than HARNESS_TMP_STALE_D days
#          (default 7, min 2); an age it cannot read keeps the entry;
#        - no /proc/<pid>/cwd, /proc/<pid>/fd/* or argv argument points into it;
#        - no line of a live job claim names a path under it. The claims are
#          the job_claims rows (BH-5002) of every fleet.conf project, read
#          through fclaim_list_dir (bin/lib/file-claims.sh). If any project's
#          rows cannot be read, the stage is skipped: an outage never reads as
#          "nothing claims it".
#      The same guards as bin/tmp-sweep.sh (BH-5608), with the same literal
#      prefix matching. The stage stops at HARNESS_TMP_RUN_DEADLINE_S and counts
#      the rest as left=. A removed git worktree gets one `git worktree prune`
#      in its repo after the loop, bounded by HARNESS_TMP_SCAN_TIMEOUT_S.
#   2. tool-caches: regular files under ~/.cache/gh older than GH_CACHE_STALE_D
#      days (default 7) and under ~/.cache/pip older than PIP_CACHE_STALE_D days
#      (default 30) are deleted, then the empty dirs under those two roots. The
#      age is per file: a cache in daily use always holds fresh files. The
#      playwright browser cache is never read and never touched (QA needs the
#      browsers; a removal re-downloads 1.9 GB per box). A symlinked root is
#      refused.
#   3. root-orphans: LIST ONLY, nothing is deleted. Each top-level dir under
#      /root whose name is not in ROOT_ORPHAN_KNOWN and whose newest mtime is
#      older than ROOT_ORPHAN_STALE_D days (default 7) gets one log line
#      `root orphan: <path> <kb> KB newest <YYYY-MM-DD>`. All of them go in ONE
#      warn (the batched digest) per run through bin/lane-alert.sh, id
#      root-orphan-<host>; with none, that id is resolved. console-worker is
#      known only when a systemd unit file under DISK_CLEAN_UNIT_DIRS names
#      /root/console-worker.
#
# A knob that is not a whole number at or over its minimum skips ITS stage with
# a log line: these numbers gate deletion, so a guessed one is never used. Every
# count moves only after `[ ! -e ]` proved the removal, and the KB is measured
# before it. Exit is 0 after the lane gate. The lock is dedupe, not a queue.
#
# Off: flags/lane-off-disk-clean. Knobs: catalog/lanes.d/disk-clean.knobs.d/.
# Test seams (every default is the live path): HARNESS_ROOT, BOX_HK_HOME,
# BOX_HK_PROC, DISK_CLEAN_NOW, DISK_CLEAN_UNIT_DIRS; the job claims come from
# $HARNESS/bin/jobs-client.sh (_jobs_req) and FLEET_CONF. Under
# HARNESS_TEST_SANDBOX=1 with no BOX_HK_HOME, stages 2 and 3 are skipped, so a
# suite never reads or deletes the real ~/.cache or /root.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"

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

HK_HOME="${BOX_HK_HOME:-${HOME:-/root}}"
PROC="${BOX_HK_PROC:-/proc}"
NOW_S="${DISK_CLEAN_NOW:-$(date +%s)}"
UNIT_DIRS="${DISK_CLEAN_UNIT_DIRS:-/etc/systemd/system /lib/systemd/system}"
SELF="$(cd "$(dirname "$0")" && pwd)"
HOST=$(hostname)

LOG="$H/logs/disk-clean.log"
NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
say() { printf '%s [disk-clean-stages] %s\n' "$NOW" "$*" >> "$LOG"; }

exec 9>"$H/locks/disk-clean-stages.lock" || { say "cannot open locks/disk-clean-stages.lock - all stages skipped"; exit 0; }
flock -n 9 || { say "lock held - another run is in progress, all stages skipped"; exit 0; }

HOME_SKIP=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -z "${BOX_HK_HOME:-}" ]; then
  HOME_SKIP="BOX_HK_HOME unset under HARNESS_TEST_SANDBOX"
fi

# int_knob <value> <min> — the value as a number, rc 1 when it is not a whole
# number at or over min.
int_knob() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 9 ] || return 1
  [ "$((10#$1))" -ge "$2" ] || return 1
  printf '%s' "$((10#$1))"
}

kb_of() { # kb_of <path> — KB on this filesystem, rc 1 when unreadable
  local k
  k=$(timeout "${SCAN_T:-60}" du -skx -- "$1" 2>/dev/null | cut -f1)
  case "$k" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$k"
}

# newest_of <path> — the newest mtime (epoch s) anywhere inside, on this
# filesystem, read within SCAN_T; rc 1 when it cannot be read whole.
newest_of() {
  local n
  n=$(timeout "$SCAN_T" find -P "$1" -xdev -printf '%T@\n' 2>/dev/null \
      | awk -F. '{ n = $1 + 0; if (!seen || n > m) { m = n; seen = 1 } } END { if (seen) print m }'
      exit "${PIPESTATUS[0]}")
  case "$?:$n" in 0:[0-9]*) printf '%s' "$n" ;; *) return 1 ;; esac
}

# held_set <real> <root> — every path under <real> a live process names: its
# cwd, an open fd, or an argv argument (anywhere in the argument, so --dir=<p>
# counts). Copied from bin/tmp-sweep.sh: literal string work, never a regex
# built from a path. An unreadable /proc entry is skipped.
held_set() {
  local real="$1" root="$2" p arg rest pre pres line args
  pres=("$real"); [ "$root" != "$real" ] && pres+=("$root")
  {
    find "$PROC"/[0-9]*/fd -mindepth 1 -maxdepth 1 -printf '%l\n' 2>/dev/null
    find "$PROC"/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null
    for p in "$PROC"/[0-9]*/cmdline; do
      [ -r "$p" ] || continue
      args=()
      mapfile -d '' -t args 2>/dev/null < "$p" || continue
      for arg in "${args[@]}"; do
        for pre in "${pres[@]}"; do
          rest="$arg"
          while [[ $rest == *"$pre/"* ]]; do
            rest="${rest#*"$pre/"}"
            [ -n "$rest" ] && printf '%s/%s\n' "$real" "$rest"
          done
        done
      done
    done
  } | while IFS= read -r line; do
    # a path spelled through <root> is rewritten onto <real>
    case "$line" in
      "$real"/?*) printf '%s\n' "$line" ;;
      "$root"/?*) printf '%s/%s\n' "$real" "${line#"$root"/}" ;;
    esac
  done | sort -u
}

# claims_fetch <dir> — every fleet.conf project's job_claims rows into
# <dir>/<project>/<KEY> through fclaim_list_dir. rc 1 when the project list or
# any project's rows cannot be read.
claims_fetch() {
  local d="$1" p projects
  if [ -r "$H/bin/jobs-client.sh" ]; then
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" 2>/dev/null || true
  fi
  # shellcheck source=bin/lib/file-claims.sh
  . "$SELF/lib/file-claims.sh" 2>/dev/null || return 1
  projects=$("$SELF/fleet-conf.sh" --projects 2>/dev/null) || return 1
  [ -n "$projects" ] || return 1
  for p in $projects; do
    mkdir -p "$d/$p" 2>/dev/null || return 1
    fclaim_list_dir "$p" "$d/$p" 2>/dev/null || return 1
  done
}

# claim_set <dir> <real> <root> — every path under <real> a line of a live job
# claim in <dir> (as claims_fetch wrote it) names.
claim_set() {
  local dir="$1" real="$2" root="$3" f line
  for f in "$dir"/*/*; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$real"/?*) printf '%s\n' "$line" ;;
        "$root"/?*) printf '%s/%s\n' "$real" "${line#"$root"/}" ;;
      esac
    done < "$f"
  done
}

# is_held <entry> <held set> — the entry itself, below it, or the entry followed
# by something that cannot continue a file name: scratch.ABC is not held by
# scratch.ABCdef.
is_held() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    case "$c" in "$1"|"$1"/*|"$1"[!A-Za-z0-9._-]*) return 0 ;; esac
  done <<< "$2"
  return 1
}

# ── 1. harness-tmp ───────────────────────────────────────────────────────────
TMPROOT="$H/tmp"
if ! STALE_D=$(int_knob "${HARNESS_TMP_STALE_D:-7}" 2); then
  say "HARNESS_TMP_STALE_D invalid (${HARNESS_TMP_STALE_D:-}) - harness-tmp skipped"
elif ! SCAN_T=$(int_knob "${HARNESS_TMP_SCAN_TIMEOUT_S:-60}" 5); then
  say "HARNESS_TMP_SCAN_TIMEOUT_S invalid (${HARNESS_TMP_SCAN_TIMEOUT_S:-}) - harness-tmp skipped"
elif ! DEADLINE=$(int_knob "${HARNESS_TMP_RUN_DEADLINE_S:-900}" 2); then
  say "HARNESS_TMP_RUN_DEADLINE_S invalid (${HARNESS_TMP_RUN_DEADLINE_S:-}) - harness-tmp skipped"
elif [ -L "$TMPROOT" ]; then
  say "harness-tmp skipped: $TMPROOT is a symlink - refused, not followed"
elif [ ! -d "$TMPROOT" ]; then
  say "harness-tmp skipped: $TMPROOT absent"
elif ! CLAIMD=$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-claims.XXXXXX" 2>/dev/null); then
  say "harness-tmp skipped: no scratch dir for the job claims"
elif ! claims_fetch "$CLAIMD"; then
  rm -rf -- "$CLAIMD"
  say "harness-tmp skipped: job_claims rows unreadable - nothing removed"
else
  removed=0; freed=0; held_n=0; fresh=0; kept=0; unread=0; failed=0; left=0; WTDIRS=()
  TMPREAL=$(cd -P -- "$TMPROOT" 2>/dev/null && pwd)
  TMPMNT=$(stat -c %m -- "$TMPREAL" 2>/dev/null)
  KEEP_GLOBS="${HARNESS_TMP_KEEP_GLOBS:-conductor batch-resolve brfix state-restore}"
  CUT=$((NOW_S - STALE_D * 86400))
  HELD=$(held_set "$TMPREAL" "$TMPROOT"; claim_set "$CLAIMD" "$TMPREAL" "$TMPROOT")
  rm -rf -- "$CLAIMD"
  START=$SECONDS
  while IFS= read -r -d '' e; do
    if [ $((SECONDS - START)) -ge "$DEADLINE" ]; then left=$((left + 1)); continue; fi
    case "$e" in "$TMPREAL"/?*) ;; *) continue ;; esac
    base="${e##*/}"
    case "$base" in .|..|*/*) continue ;; esac
    match=0
    set -f
    for g in $KEEP_GLOBS; do
      # shellcheck disable=SC2254
      case "$base" in $g) match=1; break ;; esac
    done
    set +f
    [ "$match" = 1 ] && { kept=$((kept + 1)); continue; }
    [ -L "$e" ] && continue
    [ -S "$e" ] || [ -p "$e" ] && continue
    [ -e "$e" ] || continue
    [ "$(stat -c %m -- "$e" 2>/dev/null)" = "$TMPMNT" ] || continue
    newest=$(newest_of "$e") || { unread=$((unread + 1)); continue; }
    [ "$newest" -lt "$CUT" ] || { fresh=$((fresh + 1)); continue; }
    is_held "$e" "$HELD" && { held_n=$((held_n + 1)); continue; }
    kb=$(kb_of "$e") || kb=0
    # a git worktree's .git is a file: `gitdir: <repo>/worktrees/<name>`
    wtcommon=""
    if [ -f "$e/.git" ] && [ ! -L "$e/.git" ]; then
      IFS= read -r gd < "$e/.git" 2>/dev/null || gd=""
      case "$gd" in "gitdir: "*/worktrees/*) gd="${gd#gitdir: }"; wtcommon="${gd%/worktrees/*}" ;; esac
    fi
    rm -rf --one-file-system -- "$e" 2>/dev/null
    if [ -e "$e" ] && command -v chattr >/dev/null 2>&1; then
      chattr -R -ia -- "$e" 2>/dev/null
      rm -rf --one-file-system -- "$e" 2>/dev/null
    fi
    if [ ! -e "$e" ] && [ ! -L "$e" ]; then
      removed=$((removed + 1)); freed=$((freed + kb))
      [ -n "$wtcommon" ] && WTDIRS+=("$wtcommon")
    else
      failed=$((failed + 1))
      say "harness-tmp kept: $e could not be removed"
    fi
  done < <(find "$TMPREAL" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  if [ "${#WTDIRS[@]}" -gt 0 ]; then
    while IFS= read -r gcd; do
      [ -d "$gcd" ] || continue
      timeout "$SCAN_T" git --git-dir="$gcd" worktree prune >/dev/null 2>&1; rc=$?
      if [ "$rc" = 0 ]; then say "pruned worktrees in $gcd"; else say "worktree prune failed in $gcd rc=$rc"; fi
    done < <(printf '%s\n' "${WTDIRS[@]}" | sort -u)
  fi
  [ "$left" -gt 0 ] && say "harness-tmp hit HARNESS_TMP_RUN_DEADLINE_S=${DEADLINE}s - $left entries left for the next run"
  say "harness-tmp removed=$removed freed_kb=$freed skipped_held=$held_n skipped_fresh=$fresh skipped_kept=$kept skipped_unreadable=$unread failed=$failed left=$left stale_d=$STALE_D"
fi
# SCAN_T is shared with stage 3; a skipped stage 1 leaves it at its default.
SCAN_T=$(int_knob "${HARNESS_TMP_SCAN_TIMEOUT_S:-60}" 5) || SCAN_T=60

# ── 2. tool-caches ───────────────────────────────────────────────────────────
# sweep_cache <root> <cut> <end> — deletes the regular files under <root> older
# than <cut>, then the empty dirs under it; stops once $SECONDS reaches <end>.
# Prints `<files> <kb> <left>` (left=1 when it stopped at the deadline).
# A root that is not an absolute <home>/.cache/gh or <home>/.cache/pip (empty,
# "/", relative, or with a .. step) is refused: nothing is listed or deleted.
cache_root_ok() {
  case "$1" in
    *//*|*/../*|*/./*) return 1 ;;
    /?*/.cache/gh|/?*/.cache/pip) return 0 ;;
    *) return 1 ;;
  esac
}
sweep_cache() {
  local root="$1" cut="$2" end="$3" n=0 kb=0 left=0 rec mt f k
  cache_root_ok "$root" || { printf '0 0 0'; return 1; }
  while IFS= read -r -d '' rec; do
    if [ "$SECONDS" -ge "$end" ]; then left=1; break; fi
    mt="${rec%%.*}"; rec="${rec#*$'\t'}"; k="${rec%%$'\t'*}"; f="${rec#*$'\t'}"
    case "$mt" in ''|*[!0-9]*) continue ;; esac
    [ "$mt" -lt "$cut" ] || continue
    case "$f" in "$root"/?*) ;; *) continue ;; esac
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$k" in ''|*[!0-9]*) k=0 ;; esac
    rm -f -- "$f" 2>/dev/null
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then n=$((n + 1)); kb=$((kb + k)); fi
  done < <(find -P "$root" -xdev -mindepth 1 -type f -printf '%T@\t%k\t%p\0' 2>/dev/null)
  # find never follows a symlink without -L/-H, and the path comes first so a
  # trace reader sees the root it deletes under (BH-7932 trace gate).
  find "$root" -xdev -mindepth 1 -depth -type d -empty -delete 2>/dev/null
  printf '%s %s %s' "$n" "$kb" "$left"
}
if [ -n "$HOME_SKIP" ]; then
  say "tool-caches skipped ($HOME_SKIP)"
elif ! GH_D=$(int_knob "${GH_CACHE_STALE_D:-7}" 1); then
  say "GH_CACHE_STALE_D invalid (${GH_CACHE_STALE_D:-}) - tool-caches skipped"
elif ! PIP_D=$(int_knob "${PIP_CACHE_STALE_D:-30}" 1); then
  say "PIP_CACHE_STALE_D invalid (${PIP_CACHE_STALE_D:-}) - tool-caches skipped"
elif ! TC_DEADLINE=$(int_knob "${TOOL_CACHE_RUN_DEADLINE_S:-900}" 2); then
  say "TOOL_CACHE_RUN_DEADLINE_S invalid (${TOOL_CACHE_RUN_DEADLINE_S:-}) - tool-caches skipped"
elif [ -L "$HK_HOME/.cache" ]; then
  say "tool-caches skipped: $HK_HOME/.cache is a symlink - refused, not followed"
else
  gh_n=0; gh_kb=0; pip_n=0; pip_kb=0; gh_left=0; pip_left=0
  TC_END=$((SECONDS + TC_DEADLINE))
  # Two literal roots. No path here is built from a listing of .cache.
  for name in gh pip; do
    root="$HK_HOME/.cache/$name"
    if [ -L "$root" ]; then say "tool-caches: $root is a symlink - refused, not followed"; continue; fi
    if ! cache_root_ok "$root"; then say "tool-caches: $root is not an absolute <home>/.cache/$name - refused"; continue; fi
    [ -d "$root" ] || continue
    if [ "$name" = gh ]; then
      read -r gh_n gh_kb gh_left <<< "$(sweep_cache "$root" $((NOW_S - GH_D * 86400)) "$TC_END")"
    else
      read -r pip_n pip_kb pip_left <<< "$(sweep_cache "$root" $((NOW_S - PIP_D * 86400)) "$TC_END")"
    fi
  done
  [ $((gh_left + pip_left)) -gt 0 ] && say "tool-caches hit TOOL_CACHE_RUN_DEADLINE_S=${TC_DEADLINE}s - the rest is left for the next run"
  say "tool-caches gh_files=$gh_n gh_freed_kb=$gh_kb pip_files=$pip_n pip_freed_kb=$pip_kb playwright=untouched"
fi

# ── 3. root-orphans ──────────────────────────────────────────────────────────
# LIST ONLY. This block holds no delete of any kind (the root-orphans suite
# reads it to prove that). Size and age are read with the same SCAN_T bound.
if [ -n "$HOME_SKIP" ]; then
  say "root-orphans skipped ($HOME_SKIP)"
elif ! ORPHAN_D=$(int_knob "${ROOT_ORPHAN_STALE_D:-7}" 1); then
  say "ROOT_ORPHAN_STALE_D invalid (${ROOT_ORPHAN_STALE_D:-}) - root-orphans skipped"
else
  KNOWN="${ROOT_ORPHAN_KNOWN:-harness repos worktrees .npm .cache .claude .codex .grok .fly .local .config .ssh orchestrator bhfix-lane .docker .cargo .rustup .bun .vscode-server}"
  OCUT=$((NOW_S - ORPHAN_D * 86400))
  read -r -a KNOWN_A <<< "$KNOWN"
  read -r -a UNIT_A <<< "$UNIT_DIRS"
  CW_UNIT=0
  for ud in "${UNIT_A[@]}"; do
    [ -d "$ud" ] && grep -rlsF -- "$HK_HOME/console-worker" "$ud" >/dev/null 2>&1 && { CW_UNIT=1; break; }
  done
  listed=0; o_unread=0; ITEMS=""
  while IFS= read -r -d '' d; do
    name="${d##*/}"
    known=0
    for k in "${KNOWN_A[@]}"; do [ "$name" = "$k" ] && { known=1; break; }; done
    [ "$name" = console-worker ] && [ "$CW_UNIT" = 1 ] && known=1
    [ "$known" = 1 ] && continue
    newest=$(newest_of "$d") || { o_unread=$((o_unread + 1)); say "root orphan age unreadable: $d"; continue; }
    [ "$newest" -lt "$OCUT" ] || continue
    if kb=$(kb_of "$d"); then size="$kb KB"; else size="size unknown"; fi
    day=$(date -u -d "@$newest" +%F 2>/dev/null)
    say "root orphan: $d $size newest $day"
    listed=$((listed + 1))
    ITEMS="${ITEMS:+$ITEMS; }$d $size newest $day"
  done < <(find -P "$HK_HOME" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
  LA="$H/bin/lane-alert.sh"
  if [ "$listed" -gt 0 ]; then
    "$LA" --id "root-orphan-$HOST" --severity warn disk-clean \
      "$listed hand-made dir(s) under $HK_HOME, older than ${ORPHAN_D}d (list only, nothing deleted): $ITEMS" >/dev/null 2>&1 || true
  else
    "$LA" --resolve --id "root-orphan-$HOST" disk-clean \
      "no hand-made dir under $HK_HOME older than ${ORPHAN_D}d" >/dev/null 2>&1 || true
  fi
  if [ "$o_unread" -gt 0 ]; then say "root-orphans listed=$listed unreadable=$o_unread"; else say "root-orphans listed=$listed"; fi
fi
# ── end root-orphans ─────────────────────────────────────────────────────────
exit 0
