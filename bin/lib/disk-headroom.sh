#!/bin/bash
# bin/lib/disk-headroom.sh — free disk at build start, and the headroom step
# that TRIMS old SETTLED build dirs when free disk is under a knob (BH-9435).
# Sourced by bin/lib/rb/gates.d/disk-headroom.sh, right above the disk gate.
#
# What it may trim (the candidates), oldest mtime first:
#   - on every machine, the dirs under builds-archive/<YYYYMM>/. bin/builds-retention.sh
#     moved them there by its own rules (merged or settled and swept). index.tsv
#     itself is never a candidate.
#   - on a pool machine (BUILDER_EXEC=1) only, the dirs under builds/ with a RESULT,
#     a COMMENTED, RELAYED or DEFERRED marker, and nothing in them newer than
#     DISK_HEADROOM_KEEP_DAYS.
# A candidate is kept (never trimmed) when it is the running build's own dir, a
# symlink, not a dir, a name with a newline, a name ba_parse rejects, a dir with no
# RESULT, a dir already trimmed (HEADROOM_TRIMMED), a dir with nothing but
# top-level files (no-bulk), or a dir whose locks/build-key-<p>-<K>.lock is held
# (flock -n fails). state/remote-results/ is not read at all.
#
# TRIM, NEVER REMOVE (refute review of BH-9435). The dir itself and every
# top-level regular file in it stay: RESULT, job.json, the COMMENTED/RELAYED/
# DEFERRED markers, plan.md, review.md, pipeline.log, cost.csv and the rest.
# Only its subdirs and top-level symlinks go (the worktrees, node_modules, the
# throwaway Postgres data: the bulk). The archive readers in
# bin/lib/build-archive.sh (ba_dirs, ba_has_key, ba_path, ba_merged_other) need
# the dir to exist, and they are the duplicate-build guards: launch-fastpath
# check 17, ticket-identity b2 (TK-1789), merged-ticket-advance _ma_builds and
# fetch-artifact. A trimmed dir still answers all of them, so a merged ticket
# keeps its build record. After a trim the step writes HEADROOM_TRIMMED
# (`<stamp> <MB>`) in the dir.
#
# Order of side effects: the audit of what is trimmed goes to stdout (the build's
# pipeline.log) BEFORE each trim, as a `trimming <dir> (<MB> MB)` line. Then ONE
# audit line per run that found free disk under the knob, in logs/disk-headroom.log:
#   <stamp> <host> dry_run=<0|1> min=<MB> before=<MB> after=<MB> removed=<n> dirs=<list> kept=<reason:n,...>
# removed= counts the dirs trimmed. A dry run (the default) lists in dirs= what
# it WOULD trim (`<name>:<MB>`), trims nothing, and after= equals before=. A
# space in a name is written %20.
# A run with free disk at or over the knob writes no audit line.
#
# It NEVER fails the build: every path returns 0, and a failure is one stdout line.

# shellcheck source=bin/lib/build-archive.sh
command -v ba_parse >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/build-archive.sh" 2>/dev/null

# dh_knob <ENV> <fallback> — a non-negative integer knob on the disk-guard lane.
# lane_knob when loaded (the settings row, then the env, then the registry
# default), else the env, else the fallback. A value that is not a number is the fallback.
dh_knob() {
  local e="$1" fb="$2" v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob disk-guard "$e" "${PROJECT:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!e:-}"
  [[ "$v" =~ ^[0-9]{1,9}$ ]] || v="$fb"
  printf '%s' "$v"
}

# dh_free_mb [path] — the free MB on the filesystem of path (default /). rc 1, no
# output, when df cannot be read.
dh_free_mb() {
  df -Pm "${1:-/}" 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4; f = 1 } END { exit !f }'
}

# _dh_bulk <dir> — the entries a trim removes: everything at depth 1 that is
# not a regular file (subdirs, symlinks, fifos), NUL-separated. A symlink is
# removed as a link; its target is never touched.
_dh_bulk() { find "$1" -mindepth 1 -maxdepth 1 ! -type f -print0 2>/dev/null; }

# _dh_bulk_mb <dir> — the MB a trim of dir frees (du of _dh_bulk), 0 when none.
_dh_bulk_mb() {
  local mb
  mb=$(_dh_bulk "$1" | du -smc --files0-from=- 2>/dev/null | awk 'END { print $1 }')
  [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
  printf '%s' "$mb"
}

# _dh_trim <dir> — remove _dh_bulk, keep the dir and its top-level files. rc 0
# when nothing but regular files is left at depth 1.
_dh_trim() {
  _dh_bulk "$1" | xargs -0 -r rm -rf -- 2>/dev/null
  [ -z "$(find "$1" -mindepth 1 -maxdepth 1 ! -type f -print -quit 2>/dev/null)" ]
}

# _dh_enc <name> — the name for one audit field: a space is %20.
_dh_enc() { local n="${1// /%20}"; printf '%s' "${n//$'\t'/%09}"; }

# dh_candidates <harness> <own-build-dir> — fills DH_CAND (paths, oldest mtime
# first) and DH_KEPT (one reason word per kept dir). Never deletes.
dh_candidates() {
  local h="$1" own="$2" keep d n lk ownr dr mt pool=0 mins
  DH_CAND=(); DH_KEPT=()
  ownr=$(readlink -f -- "$own" 2>/dev/null || printf '%s' "$own")
  # The row lane.disk-guard.disk_headroom_keep_days; 1 is its fallback.
  keep=$(dh_knob DISK_HEADROOM_KEEP_DAYS 1)
  mins=$(( keep * 1440 ))
  [ "${BUILDER_EXEC:-}" = 1 ] && pool=1
  local all=() rows=()
  for d in "$h"/builds-archive/[0-9][0-9][0-9][0-9][0-9][0-9]/*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    all+=("a$d")
  done
  if [ "$pool" = 1 ]; then
    for d in "$h"/builds/*; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      all+=("b$d")
    done
  fi
  local e
  for e in ${all[@]+"${all[@]}"}; do
    d="${e:1}"; n="${d##*/}"
    [ -L "$d" ] && { DH_KEPT+=(symlink); continue; }
    [ -d "$d" ] || { DH_KEPT+=(not-dir); continue; }
    case "$n" in *$'\n'*|*$'\r'*) DH_KEPT+=(bad-name); continue ;; esac
    dr=$(readlink -f -- "$d" 2>/dev/null || printf '%s' "$d")
    [ "$dr" = "$ownr" ] && { DH_KEPT+=(own); continue; }
    ba_parse "$n" || { DH_KEPT+=(bad-name); continue; }
    [ -f "$d/RESULT" ] || { DH_KEPT+=(no-result); continue; }
    [ -e "$d/HEADROOM_TRIMMED" ] && { DH_KEPT+=(trimmed); continue; }
    [ -n "$(find "$d" -mindepth 1 -maxdepth 1 ! -type f -print -quit 2>/dev/null)" ] || { DH_KEPT+=(no-bulk); continue; }
    if [ "${e:0:1}" = b ]; then
      [ -f "$d/COMMENTED" ] || [ -f "$d/RELAYED" ] || [ -f "$d/DEFERRED" ] || { DH_KEPT+=(unswept); continue; }
      [ -n "$(find "$d" -maxdepth 1 -mmin "-$mins" -print -quit 2>/dev/null)" ] && { DH_KEPT+=(young); continue; }
      [ -e "$h/state/remote-results/$BA_P/$BA_K.json" ] && { DH_KEPT+=(remote-json); continue; }
    fi
    lk="$h/locks/build-key-$BA_P-$BA_K.lock"
    if [ -e "$lk" ] && ! { flock -n 7; } 7<"$lk" 2>/dev/null; then DH_KEPT+=(live); continue; fi
    mt=$(stat -c %Y -- "$d" 2>/dev/null) || { DH_KEPT+=(no-stat); continue; }
    rows+=("$mt"$'\t'"$d")
  done
  [ "${#rows[@]}" -gt 0 ] || return 0
  while IFS=$'\t' read -r mt d; do
    [ -n "$d" ] && DH_CAND+=("$d")
  done < <(printf '%s\n' "${rows[@]}" | LC_ALL=C sort -t$'\t' -k1,1n -k2)
  return 0
}

# _dh_kept_summary — DH_KEPT as `reason:n,...` (sorted), or `-`.
_dh_kept_summary() {
  [ "${#DH_KEPT[@]}" -gt 0 ] || { printf -- '-'; return; }
  printf '%s\n' "${DH_KEPT[@]}" | LC_ALL=C sort | uniq -c | awk '{ printf "%s%s:%s", (NR > 1 ? "," : ""), $2, $1 }'
}

# dh_run <harness> <own-build-dir> — the headroom step. Prints the build-start
# measure line and what it did on stdout; writes the audit line. Always rc 0.
dh_run() {
  local h="$1" own="$2" host min dry before free after mb d n removed=0 list="" sim
  host=$(hostname 2>/dev/null || echo unknown)
  if ! before=$(dh_free_mb /); then
    echo "disk headroom: free disk unreadable (df -Pm / failed) — nothing removed"
    return 0
  fi
  echo "disk: $before MB free on / at build start ($host, builder_exec=$([ "${BUILDER_EXEC:-}" = 1 ] && echo 1 || echo 0))"
  # The row lane.disk-guard.disk_headroom_min_free_mb; 8192 is its fallback
  # (a project-6 build, a throwaway Postgres and node_modules need about 6 GB).
  min=$(dh_knob DISK_HEADROOM_MIN_FREE_MB 8192)
  # The row lane.disk-guard.disk_headroom_dry_run; 1 (dry run, delete nothing) is its fallback.
  dry=$(dh_knob DISK_HEADROOM_DRY_RUN 1); [ "$dry" = 0 ] || dry=1
  if [ "$before" -ge "$min" ]; then
    echo "disk headroom ok: $before MB free >= $min MB"
    return 0
  fi
  dh_candidates "$h" "$own"
  after="$before"; sim="$before"
  for d in ${DH_CAND[@]+"${DH_CAND[@]}"}; do
    n="${d##*/}"
    if [ "$dry" = 1 ]; then
      [ "$sim" -ge "$min" ] && break
      mb=$(_dh_bulk_mb "$d")
      list="$list,$(_dh_enc "$n"):$mb"; sim=$(( sim + mb ))
      continue
    fi
    free=$(dh_free_mb /) || { echo "disk headroom: free disk unreadable mid-run — stopped"; break; }
    after="$free"
    [ "$free" -ge "$min" ] && break
    mb=$(_dh_bulk_mb "$d")
    echo "disk headroom: trimming $d ($mb MB, $free MB free < $min MB; the dir and its top-level files stay)"
    if _dh_trim "$d"; then
      printf '%s %s\n' "$(date -u +%FT%TZ)" "$mb" > "$d/HEADROOM_TRIMMED" 2>/dev/null
      removed=$((removed + 1)); list="$list,$(_dh_enc "$n")"
    else
      echo "disk headroom: could not trim $d"
    fi
  done
  if [ "$dry" = 0 ]; then after=$(dh_free_mb /) || after="$before"; fi
  list="${list#,}"; [ -n "$list" ] || list=-
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s %s dry_run=%s min=%s before=%s after=%s removed=%s dirs=%s kept=%s\n' \
    "$(date -u +%FT%TZ)" "$host" "$dry" "$min" "$before" "$after" "$removed" "$list" "$(_dh_kept_summary)" \
    >> "$h/logs/disk-headroom.log" 2>/dev/null \
    || echo "disk headroom: could not write logs/disk-headroom.log"
  echo "disk headroom: dry_run=$dry before=${before}MB after=${after}MB removed=$removed (min ${min}MB; audit: logs/disk-headroom.log)"
  return 0
}
