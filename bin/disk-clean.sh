#!/bin/bash
# disk-clean.sh — daily disk hygiene for harness boxes (2026-08-31, the operator via Telegram).
# Reclaims the three chronic accumulators found on the hub at 94% disk:
# npm cache, old bench runs, stale git worktrees. Conservative on worktrees:
# never touches one that is dirty, unpushed (except aged triage-*), recently
# modified, or referenced by a running process. Logs one summary line; alerts
# only if disk is still >90% after cleaning.
#
# Since BH-1044 it also bounds the four state accumulators the 2026-09-19 audit
# found on the hub (a 45 MB state/closeout-aged-out.tsv nothing ever pruned,
# 3,153 stale lock files, ~40 operator one-offs loose in state/, a dead
# state/leases/), because this lane already runs daily on every box:
#   4. prune state/closeout-aged-out.tsv to CLOSEOUT_TSV_KEEP_DAYS days of build
#      dirs whose dir is GONE, archiving every row it drops under state/archive/
#      FIRST (a row whose build dir still exists is kept at any age — pipeline-
#      health would re-record it ten minutes later, so archiving it would move
#      the growth into state/archive/ rather than end it);
#   5. delete locks/*.lock older than LOCK_STALE_H with no holder — three probes
#      (mtime, an open fd in /proc, flock -n) must all agree before an unlink;
#   6. move operator scratch (state/*.sh, *.done, *.bak-*) under state/scratch/,
#      which bin/state-backup.sh leaves out of the off-box copy;
#   7. delete state/leases/ once nothing in it changed for LEASES_STALE_D days.
# Since BH-1363 it also sweeps the scratch under tmp/ that no process holds:
#   8. remove tmp/brfix/* (blocked-resolver fix-round worktrees) and
#      tmp/state-backup.* (backup staging) older than TMP_SCRATCH_STALE_H hours
#      with no /proc cwd and no cmdline naming them, through the owning repo's
#      `git worktree remove` + `worktree prune`, reporting the KB it freed.
#      tmp/batch-resolve/<slug> is NOT swept at any age: it is a reused
#      blob:none clone cache, so deleting it buys a re-clone every train.
# Since BH-4440 it also runs bin/box-housekeeping.sh as stage 9 (session
# ledgers and /tmp top level, see that file's header).
# Stage 10 bounds each logs/*-cron.log at CRON_LOG_MAX_KB: over it, the file is
# cut in place (same inode, so a >> writer keeps appending) to its newest half.
# Each is a no-op on a box with nothing to clean, and each counter in the
# summary line is incremented only after the work really happened.
#
# Test seams (every default is the live path, so cron is unchanged):
# HARNESS_ROOT, DISK_CLEAN_REPOS, DISK_CLEAN_NPM_DIR, DISK_CLEAN_NOW,
# DISK_CLEAN_PROC.
set -u
H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
REPOS="${DISK_CLEAN_REPOS:-/root/repos}"
NPM_DIR="${DISK_CLEAN_NPM_DIR:-/root/.npm}"
NOW_S="${DISK_CLEAN_NOW:-$(date +%s)}"
PROC="${DISK_CLEAN_PROC:-/proc}"

# The knobs are operator knobs, so they are read from where operators set them.
# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-disk-clean
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off disk-clean.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit disk-clean
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    disk-clean

LOG="$H/logs/disk-clean.log"
ALERTS="$H/logs/ALERTS.log"
NOW=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
mkdir -p "$H/logs" 2>/dev/null
say() { printf '%s [disk-clean] %s\n' "$NOW" "$*" >> "$LOG"; }
before=$(df --output=pcent / | tail -1 | tr -dc 0-9)

# 1. npm cache: keep it under NPM_CACHE_MAX_MB (default 2048). A value that is
# not a whole number skips the clean rather than guessing a line (BH-4440).
sz=$(du -sm "$NPM_DIR" 2>/dev/null | cut -f1 || echo 0)
NPM_MAX="${NPM_CACHE_MAX_MB:-2048}"
case "$NPM_MAX" in
  ''|*[!0-9]*) say "NPM_CACHE_MAX_MB is not a number ($NPM_MAX) - npm cache clean skipped" ;;
  *) [ "${sz:-0}" -gt "$((10#$NPM_MAX))" ] && npm cache clean --force >/dev/null 2>&1 ;;
esac

# 2. bench runs older than 7 days
find "$H/state/bench" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null

# 3. stale worktrees
PROCS=$(pgrep -af 'run-build|run-triage|agent-call' 2>/dev/null || true)
removed=0
for repo in "$REPOS"/*/; do
  [ -d "$repo/.git" ] || continue
  git -C "$repo" worktree prune 2>/dev/null
  while read -r wt; do
    [ "$wt" = "${repo%/}" ] && continue; [ -d "$wt" ] || continue
    case "$PROCS" in *"$wt"*) continue;; esac
    # recently modified (<48h) -> keep
    [ -n "$(find "$wt" -maxdepth 1 -mmin -2880 -print -quit 2>/dev/null)" ] && continue
    # uncommitted changes -> keep
    # No `| head -1`: the test is non-emptiness, which the first line and the
    # whole output answer the same way, and head on a git pipe is a SIGPIPE race
    # under pipefail (BH-1248).
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && continue
    # HEAD not on any remote: keep, unless it is a triage-* scratch older than 14d
    if [ -z "$(git -C "$wt" branch -r --contains HEAD 2>/dev/null)" ]; then
      case "$(basename "$wt")" in triage-*) ;; *) continue;; esac
      [ -n "$(find "$wt" -maxdepth 1 -mmin -20160 -print -quit 2>/dev/null)" ] && continue
    fi
    if git -C "$repo" worktree remove "$wt" 2>/dev/null || { rm -rf "$wt" && git -C "$repo" worktree prune 2>/dev/null; }; then
      removed=$((removed+1))
    fi
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
done

# 4. state/closeout-aged-out.tsv: keep the last CLOSEOUT_TSV_KEEP_DAYS days of
# build dirs, archive the older ones whose dir is gone (see the paragraph below
# for why the dir has to be gone). The rows carry no timestamp of their own
# (bin/lib/closeout-terminal.sh writes project, dir, RESULT line, reason), so the
# cutoff compares the 12-digit launch stamp bin/run-build.sh and bin/fly-pool.sh
# put at the end of a build dir name. A dir with no stamp is KEPT, never aged
# out. A second row for a dir already kept is archived: that lib says the file is
# a set keyed on the dir, so a duplicate is the defect, not data. The archive is
# appended FIRST and the file swapped only after, so the worst failure duplicates
# rows, never loses them.
#
# A ROW WHOSE BUILD DIR IS STILL ON THE BOX IS KEPT AT ANY AGE (BH-1044 fix
# round). bin/pipeline-health.sh re-records an aged dir on its next tick, 10
# minutes later, for as long as that dir exists with a RESULT and no COMMENTED —
# and nothing in this harness deletes build dirs. Archiving such a row by age
# only moves it: the tsv wins the row straight back and the archive collects the
# same ~800 dirs every single day, inside state/, which state-backup.sh tars
# every 15 minutes. So the archive receives a dir exactly once, when the dir
# itself is gone and nobody can record it again. What actually bounds the live
# file is the dedupe fix in bin/lib/closeout-terminal.sh (same fix round): one
# row per dir, ~800 rows, not 45 MB.
TSV="$H/state/closeout-aged-out.tsv"
KEEP_DAYS="${CLOSEOUT_TSV_KEEP_DAYS:-30}"
case "$KEEP_DAYS" in ''|*[!0-9]*)
  say "CLOSEOUT_TSV_KEEP_DAYS is not a number - using 30"; KEEP_DAYS=30 ;;
esac
tsv_kept=0; tsv_archived=0; tsv_kept_live=0
if [ -s "$TSV" ]; then
  CUT=$(date -u -d "@$((NOW_S - KEEP_DAYS * 86400))" +%Y%m%d%H%M 2>/dev/null)
  ARCHD="$H/state/archive"
  ARCHF="$ARCHD/closeout-aged-out.$(date -u -d "@$NOW_S" +%Y%m%d 2>/dev/null).tsv"
  KEEPTMP="$H/state/.closeout-prune-keep.$$"
  DROPTMP="$H/state/.closeout-prune-drop.$$"
  LIVETMP="$H/state/.closeout-prune-live.$$"
  # The build dirs that still exist, by basename (the writer records a basename;
  # a hand-written row may carry a path, so awk compares basenames). Built before
  # the lock: a dir that appears after this list does no harm — its row is
  # archived once and pipeline-health records it again, which is duplication in
  # the archive, never a lost row.
  find "$H/builds" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort -u > "$LIVETMP" || : > "$LIVETMP"
  mkdir -p "$H/locks" 2>/dev/null
  # The lock closeout_record_aged takes, so no append interleaves with the
  # rewrite. Held elsewhere means nothing is touched this run; tomorrow retries.
  # Both locks (BH-6892): closeout_record_aged and the hub's @rows apply of a
  # machine write-back take $TSV.lock; the old lock stays first.
  COUNTS=$(
    exec 9>"$H/locks/closeout-aged-out.lock" 2>/dev/null || exit 3
    flock -w 5 9 || exit 4
    exec 8>"$TSV.lock" 2>/dev/null || exit 3
    flock -w 5 8 || exit 4
    : > "$KEEPTMP" || exit 5
    : > "$DROPTMP" || exit 5
    # No interval quantifiers in the pattern: /usr/bin/awk is mawk on Debian and
    # older mawk ignores {12} silently, which would match nothing and keep
    # everything forever. The live list is read with getline, not the NR==FNR
    # two-file idiom: an empty live list would make NR==FNR true for the tsv's
    # own first pass and swallow the whole file.
    awk -F'\t' -v cut="$CUT" -v keepf="$KEEPTMP" -v dropf="$DROPTMP" -v livef="$LIVETMP" '
      BEGIN { while ((getline ln < livef) > 0) live[ln] = 1; close(livef) }
      { dir = $2; sub(/^.*\//, "", dir)
        stamp = ""
        if (match(dir, /-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/))
          stamp = substr(dir, RSTART + 1, 12)
        if ($2 in seen) { print $0 > dropf; a++ }
        else if (stamp != "" && stamp < cut && !(dir in live)) { print $0 > dropf; a++ }
        else { seen[$2] = 1; print $0 > keepf; k++
               if (stamp != "" && stamp < cut) l++ }
      }
      END { printf "%d %d %d\n", k + 0, a + 0, l + 0 }' "$TSV" || exit 5
    [ -s "$DROPTMP" ] || exit 0      # nothing to drop: no churn, no new inode
    mkdir -p "$ARCHD" 2>/dev/null || exit 6
    cat "$DROPTMP" >> "$ARCHF" || exit 6
    mv "$KEEPTMP" "$TSV" || exit 7
  )
  PRC=$?
  rm -f "$KEEPTMP" "$DROPTMP" "$LIVETMP"
  case "$PRC" in
    0) read -r tsv_kept tsv_archived tsv_kept_live <<< "$COUNTS" ;;
    3) say "tsv prune skipped: cannot open locks/closeout-aged-out.lock or state/closeout-aged-out.tsv.lock" ;;
    4) say "tsv prune skipped: lock held" ;;
    6) say "tsv prune failed: archive append to ${ARCHF##*/} - the tsv is untouched" ;;
    7) say "tsv prune failed: rewrite - the dropped rows are in ${ARCHF##*/} AND still in the tsv" ;;
    *) say "tsv prune failed: could not read the file back (rc=$PRC)" ;;
  esac
  case "$tsv_kept$tsv_archived$tsv_kept_live" in
    ''|*[!0-9]*) tsv_kept=0; tsv_archived=0; tsv_kept_live=0 ;;
  esac
  [ "$tsv_kept_live" -gt 0 ] && say \
    "tsv: $tsv_kept_live row(s) past the ${KEEP_DAYS}d cutoff kept - their build dir is still on this box and pipeline-health re-records it every tick"
fi

# 5. locks/: a lock file nobody holds, older than LOCK_STALE_H. Three probes
# must agree before an unlink — the mtime gate (every lock here is opened with
# exec N> before flock, and O_TRUNC updates mtime), no open fd in /proc, and
# flock -n — and the unlink happens INSIDE the lock, so nothing can take the
# inode between the probe and the rm.
LOCKS="$H/locks"
STALE_H="${LOCK_STALE_H:-24}"
case "$STALE_H" in ''|*[!0-9]*)
  say "LOCK_STALE_H is not a number - using 24"; STALE_H=24 ;;
esac
locks_removed=0; locks_skipped_held=0
if [ -d "$LOCKS" ]; then
  # One pass over /proc for every fd pointing into locks/ (neither fuser nor
  # lsof is installed on these boxes). It sees a flock -w waiter too.
  OPENFDS=$(find "$PROC"/[0-9]*/fd -maxdepth 1 -lname "$LOCKS/*" -printf '%l\n' 2>/dev/null | sort -u)
  while IFS= read -r lk; do
    [ -n "$lk" ] || continue
    if grep -qxF "$lk" <<<"$OPENFDS"; then
      locks_skipped_held=$((locks_skipped_held + 1)); continue
    fi
    if LOCKF="$lk" flock -n "$lk" -c 'rm -f -- "$LOCKF"' 2>/dev/null && [ ! -e "$lk" ]; then
      locks_removed=$((locks_removed + 1))
    else
      locks_skipped_held=$((locks_skipped_held + 1))
    fi
  done < <(find "$LOCKS" -maxdepth 1 -type f -printf '%T@\t%p\n' 2>/dev/null \
           | awk -F'\t' -v cutoff="$((NOW_S - STALE_H * 3600))" \
               '$1 + 0 < cutoff { sub(/^[^\t]*\t/, ""); print }')
fi

# 6. operator scratch out of state/: *.sh, *.done and *.bak-*, top level only,
# into state/scratch/ (which bin/state-backup.sh leaves out of the off-box copy).
# A *.sh the crontab runs, or one a bin/ script reads by name, is a lane's file
# and stays. mv -n, so a name collision never clobbers what is already there.
SCRATCHD="$H/state/scratch"
scratch_moved=0; scratch_skipped=0
CRONTXT=$(crontab -l 2>/dev/null || true)
while IFS= read -r sf; do
  [ -n "$sf" ] || continue
  sb=$(basename "$sf")
  case "$sb" in
    *.sh)
      if grep -qF "$sb" <<<"$CRONTXT"; then
        say "scratch kept: $sb (the crontab runs it)"
        scratch_skipped=$((scratch_skipped + 1)); continue
      fi
      if grep -rqF "state/$sb" "$H/bin" 2>/dev/null; then
        say "scratch kept: $sb (a bin/ script reads it)"
        scratch_skipped=$((scratch_skipped + 1)); continue
      fi ;;
  esac
  mkdir -p "$SCRATCHD" 2>/dev/null || { say "scratch skipped: cannot create state/scratch"; break; }
  if mv -n "$sf" "$SCRATCHD/" 2>/dev/null && [ ! -e "$sf" ]; then
    scratch_moved=$((scratch_moved + 1))
  else
    say "scratch kept: $sb (a file of that name is already under state/scratch)"
    scratch_skipped=$((scratch_skipped + 1))
  fi
done < <(find "$H/state" -maxdepth 1 -type f \
         \( -name '*.sh' -o -name '*.done' -o -name '*.bak-*' \) 2>/dev/null)

# 7. state/leases/: three August files and no reader anywhere in bin/, cron/,
# docs/, fly/ or worker/ (the hits are all state/quota/leases/, a different path
# this never touches). Removed only once nothing inside changed for
# LEASES_STALE_D days, so a box where something new appears under that name
# keeps it and says so.
LEASES="$H/state/leases"
STALE_D="${LEASES_STALE_D:-7}"
case "$STALE_D" in ''|*[!0-9]*)
  say "LEASES_STALE_D is not a number - using 7"; STALE_D=7 ;;
esac
leases=none
if [ -d "$LEASES" ] && [ ! -L "$LEASES" ]; then
  RECENT=$(find "$LEASES" -printf '%T@\n' 2>/dev/null \
           | awk -v cutoff="$((NOW_S - STALE_D * 86400))" '$1 + 0 > cutoff { print "recent"; exit }')
  if [ -n "$RECENT" ]; then
    say "leases kept: something under state/leases changed in the last ${STALE_D}d"
    leases=kept
  else
    case "$LEASES" in "$H/state/leases") rm -rf "$LEASES" ;; esac
    if [ -e "$LEASES" ]; then
      say "leases kept: state/leases could not be removed"
      leases=kept
    else
      leases=removed
    fi
  fi
fi

# 8. tmp/ scratch nothing owns any more (BH-1363). bin/blocked-resolver.sh
# builds each fix round a worktree under tmp/brfix/ and removes it on every exit
# a shell can catch; this is the backstop for the ones it cannot — SIGKILL, OOM,
# a power cut. Stage 3 above can never do it: it keeps any worktree whose HEAD is
# on no remote unless the basename is triage-*, and a brfix/<ck> checkpoint is
# local-only by construction, so a leaked fix worktree was ineligible for ever.
# The hub carried 14 GB of them (eleven trees, 09-17..09-20) at 92% disk.
# bin/state-backup.sh's staging dir gets the same backstop; its own EXIT trap
# already covers every catchable exit.
#
# THREE FACTS DECIDE, all read at run time: the newest mtime of the directory
# and its direct children (nothing touched for TMP_SCRATCH_STALE_H hours), no
# /proc/<pid>/cwd pointing into it, and no run-build/run-triage/agent-call
# cmdline naming it (the same PROCS list stage 3 uses; neither lsof nor fuser is
# installed on these boxes). A candidate this is unsure about is KEPT — an
# unreadable age keeps it, and a worst-case fix round is ~2.5 h, so anything
# this sweep sees is hours past its own timeout.
#
# NOT swept, deliberately: tmp/batch-resolve/<slug> is a reused blob:none clone
# cache, so deleting it converts saved disk into repeated clone traffic; and
# tmp/state-restore is an operator CLI's explicit DEST. See
# docs/notes/2026-09-22-BH-1363-brfix-worktree-cleanup.md.
TMPD="$H/tmp"
TMP_STALE_H="${TMP_SCRATCH_STALE_H:-24}"
case "$TMP_STALE_H" in ''|*[!0-9]*)
  say "TMP_SCRATCH_STALE_H is not a number - using 24"; TMP_STALE_H=24 ;;
esac
tmp_removed=0; tmp_freed_kb=0; tmp_skipped_held=0
if [ -d "$TMPD" ]; then
  # One pass over /proc for every cwd pointing into the scratch tree.
  CWDS=$(find "$PROC"/[0-9]*/cwd -maxdepth 0 -printf '%l\n' 2>/dev/null | sort -u)
  TMPCUT=$((NOW_S - TMP_STALE_H * 3600))
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    # The max mtime, in awk rather than `sort -rn | head -1`: a short-circuiting
    # head on the right of a pipe is the SIGPIPE shape bin/test-determinism-lint
    # reads. An unreadable or empty listing prints NOTHING, and the case below
    # keeps the directory — absent is never zero (D11), and zero here would be
    # the epoch, which is stale by 56 years.
    newest=$(find "$d" -maxdepth 1 -printf '%T@\n' 2>/dev/null \
             | awk -F. '{ n = $1 + 0; if (!seen || n > m) { m = n; seen = 1 } }
                        END { if (seen) print m }')
    case "$newest" in ''|*[!0-9]*) continue ;; esac
    [ "$newest" -lt "$TMPCUT" ] || continue
    held=0
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      case "$c" in "$d"|"$d"/*) held=1; break ;; esac
    done <<< "$CWDS"
    case "$PROCS" in *"$d"*) held=1 ;; esac
    if [ "$held" = 1 ]; then
      tmp_skipped_held=$((tmp_skipped_held + 1)); continue
    fi
    # MEASURE, REMOVE, VERIFY, COUNT — in that order, so "freed" can never
    # describe bytes that are still on the disk.
    kb=$(du -sk "$d" 2>/dev/null | cut -f1)
    case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
    # The owning repo comes from the worktree's own .git file, and only counts
    # when it is one of ours: a .git naming a path outside $REPOS gets no git
    # command aimed at it at all, just the scratch directory removed.
    owner=""
    if [ -f "$d/.git" ]; then
      owner=$(sed -n 's|^gitdir: \(.*\)/\.git/worktrees/.*$|\1|p' "$d/.git" 2>/dev/null | head -1)
      case "$owner" in
        "$REPOS"/*) [ -d "$owner/.git" ] || owner="" ;;
        *) owner="" ;;
      esac
    fi
    if [ -n "$owner" ]; then
      git -C "$owner" worktree remove --force "$d" >/dev/null 2>&1
      # -f -f is the override for a LOCKED working tree, which --force refuses.
      [ -e "$d" ] && git -C "$owner" worktree remove --force --force "$d" >/dev/null 2>&1
    fi
    # ANCHORED: the last resort only ever deletes a path under tmp/brfix/ or a
    # tmp/state-backup.* staging dir, matched against the literal prefix.
    if [ -e "$d" ]; then
      case "$d" in "$TMPD"/brfix/?*|"$TMPD"/state-backup.?*) rm -rf "$d" ;; esac
    fi
    [ -n "$owner" ] && git -C "$owner" worktree prune >/dev/null 2>&1
    if [ -e "$d" ]; then
      say "tmp scratch kept: $d is stale and unheld but could not be removed"
    else
      tmp_removed=$((tmp_removed + 1)); tmp_freed_kb=$((tmp_freed_kb + kb))
    fi
  done < <( find "$TMPD/brfix" -mindepth 1 -maxdepth 1 -type d 2>/dev/null
            find "$TMPD" -mindepth 1 -maxdepth 1 -type d -name 'state-backup.*' 2>/dev/null )
fi

# 9. box housekeeping (BH-4440): agent session ledgers past
# AGENT_SESSION_KEEP_DAYS and stale /tmp top-level entries nothing holds open.
# It writes its own summary lines here, so the line below keeps its shape and
# its before/after % includes what it freed.
if [ -x "$H/bin/box-housekeeping.sh" ]; then
  HARNESS_ROOT="$H" "$H/bin/box-housekeeping.sh" >/dev/null 2>&1 \
    || say "box-housekeeping exited rc=$? - see its lines above"
fi

# 10. cron lane logs (BH-6530): every logs/*-cron.log over CRON_LOG_MAX_KB is
# cut to its newest CRON_LOG_MAX_KB/2 KB, starting at a line start. One glob
# covers every lane that appends its stderr there. Keeping half means a file is
# not re-cut every day. The cut is copy-truncate IN PLACE (`cat tmp > log`), not
# `mv tmp log`: a lane running at this minute holds the log open with >>
# (O_APPEND), so on the same inode its next line lands at the new end, where a
# rename would send it to an unlinked file. Lines appended between the tail and
# the truncate are lost; that window is milliseconds, once a day. -type f skips
# symlinks, and -maxdepth 1 skips anything under a subdirectory. A knob that is
# not a whole number >= 64 skips the stage, never guessed (a typo of 1 would
# empty every log daily).
CRON_KB="${CRON_LOG_MAX_KB:-10240}"
cronlogs_cut=0; cronlogs_freed_kb=0
case "$CRON_KB" in
  ''|*[!0-9]*) CRON_KB_OK=0 ;;
  *) if [ "${#CRON_KB}" -le 9 ] && [ "$((10#$CRON_KB))" -ge 64 ]; then CRON_KB_OK=1; else CRON_KB_OK=0; fi ;;
esac
if [ "$CRON_KB_OK" = 0 ]; then
  say "cron log bound skipped: CRON_LOG_MAX_KB='$CRON_KB' is not a whole number >= 64"
else
  CRON_MAXB=$(( 10#$CRON_KB * 1024 )); CRON_KEEPB=$(( CRON_MAXB / 2 ))
  while IFS= read -r cf; do
    [ -n "$cf" ] || continue
    cb=$(basename "$cf")
    csz=$(stat -c %s "$cf" 2>/dev/null)
    case "$csz" in ''|*[!0-9]*) continue ;; esac
    [ "$csz" -gt "$CRON_MAXB" ] || continue
    ctmp="$H/logs/.$cb.cut.$$"
    # sed 1d drops the partial first line, so the kept text starts at a line start.
    tail -c "$CRON_KEEPB" -- "$cf" 2>/dev/null | sed '1d' 2>/dev/null > "$ctmp"
    crc=("${PIPESTATUS[@]}")
    if [ "${crc[0]}" != 0 ] || [ "${crc[1]:-1}" != 0 ]; then
      say "cron log kept: $cb is ${csz} bytes, but its newest part could not be written to a temp file"
      rm -f "$ctmp"; continue
    fi
    if ! cat "$ctmp" 2>/dev/null > "$cf"; then
      say "cron log cut failed: $cb could not be rewritten in place - it can be partly written"
      rm -f "$ctmp"; continue
    fi
    rm -f "$ctmp"
    cnew=$(stat -c %s "$cf" 2>/dev/null)
    case "$cnew" in ''|*[!0-9]*) say "cron log cut: $cb size unreadable after the cut"; continue ;; esac
    if [ "$cnew" -le "$CRON_MAXB" ]; then
      cronlogs_cut=$((cronlogs_cut + 1))
      cronlogs_freed_kb=$((cronlogs_freed_kb + (csz - cnew) / 1024))
    else
      say "cron log cut: $cb is still ${cnew} bytes after the cut"
    fi
  done < <(find "$H/logs" -maxdepth 1 -type f -name '*-cron.log' 2>/dev/null)
fi

after=$(df --output=pcent / | tail -1 | tr -dc 0-9)
echo "$NOW disk-clean: ${before}%->${after}% npm=${sz}M worktrees_removed=${removed} tsv_kept=${tsv_kept} tsv_archived=${tsv_archived} tsv_kept_live=${tsv_kept_live} locks_removed=${locks_removed} locks_skipped_held=${locks_skipped_held} scratch_moved=${scratch_moved} scratch_skipped=${scratch_skipped} leases=${leases} tmp_removed=${tmp_removed} tmp_freed_kb=${tmp_freed_kb} tmp_skipped_held=${tmp_skipped_held} cronlogs_cut=${cronlogs_cut} cronlogs_freed_kb=${cronlogs_freed_kb}" >> "$LOG"
if [ "${after:-0}" -gt 90 ]; then
  echo "$NOW [disk-clean] $(hostname): disk still ${after}% after cleanup — the alert medic (bin/alerts-medic.sh) owns this line; it needs a resize or a triage of dirty/unpushed worktrees, neither of which this script will do unasked" >> "$ALERTS"
fi
exit 0
