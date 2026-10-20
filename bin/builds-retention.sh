#!/bin/bash
# bin/builds-retention.sh [--dry-run] — the retention rule for builds/. Hub
# only, daily at 04:27Z (cron/lanes/737-builds-retention.cron). No LLM call.
#
# It MOVES settled build-dir groups older than the window from builds/ to
# builds-archive/<YYYYMM>/<dir> (a rename on the same filesystem) and writes
# one row per moved dir to builds-archive/index.tsv (bin/lib/build-archive.sh).
# Nothing is deleted: a restore is one `mv` back plus deleting the index row.
#
# A GROUP is every dir whose name parses to one (project, KEY): <p>-<K>-<ts>,
# pool-, fly-, -remote<ts>[-n], -r2-/-rerun- (ba_parse). A group moves only
# whole and only when every rule holds; the first rule that fails is the
# group's kept reason in the run line:
#   no-stamp     a dir name with no build stamp (a hand-made dir)
#   young        a name stamp, or the mtime of a RESULT or COMMENTED, is newer
#                than cut = now - (window_days + 1) days
#   not-merged   no dir has RESULT line 1 starting PR_MERGED
#   unswept      a dir with RESULT and no COMMENTED, RELAYED or DEFERRED, line
#                1 not QUEUED_FLY/BUILD_DEFERRED (bin/orphan-reconcile.sh)
#   remote-json  state/remote-results/<p>/<K>.json exists
#   live         locks/build-key-<p>-<K>.lock is held
#   collision    a dir already archived (index row or archive path); +1 error
#
# Settings rows (setting_get; a missing row, an outage or a bad value uses the
# code default, named in the run line as `(default)`):
#   builds_retention.window_days  14    days
#   builds_retention.dry_run      1     1 = list only; --dry-run forces 1
#   builds_retention.max_dirs     2000  dirs per run; the run stops between
#                                       groups (capped=1) and the next day
#                                       drains the rest
#
# Per dir: the index row first, then `mv -T -n`, then a check that the source
# is gone and the destination is a dir. A failed move appends a tombstone row
# (result1 MOVE_FAILED) and counts an error; the live dir stays.
# Dry run: logs/builds-retention-dryrun.txt (<dir> TAB <relpath>), no move.
#
# One line per run in logs/builds-retention.log:
#   <ts> run dry=<0|1> window=<d>[(default)] cut=<YYYYMMDDHHMM> dirs=<n>
#   groups=<n> eligible_groups=<n> moved=<n> would_move=<n> kept no-stamp=<n>
#   young=<n> not-merged=<n> unswept=<n> remote-json=<n> live=<n>
#   collision=<n> capped=<0|1> errors=<n> wall=<s>s
#   | <ts> already running | <ts> cross-fs (no move)
#
# Exit 0 on every path. Alerts (bin/lane-alert.sh, warn):
#   builds-retention:cross-fs  builds/ and builds-archive/ on two filesystems
#   builds-retention:errors    errors > 0; a clean run resolves it
#
# Env (test seams, not settable): BUILDS_RETENTION_NOW (epoch seconds for the
# clock), BUILDS_RETENTION_FORCE_XFS=1 (act as if cross-filesystem).
# OFF: flags/lane-off-builds-retention (bin/harness-ctl.sh off builds-retention).
# Registry: catalog/lanes.d/builds-retention.json.
# Doc: docs/notes/2026-10-19-BH-7437-builds-retention.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

# Lowest CPU and IO priority. Re-exec once; the pid stays the same.
if [ -z "${BUILDS_RETENTION_NICED:-}" ]; then
  export BUILDS_RETENTION_NICED=1
  if command -v ionice >/dev/null 2>&1 && ionice -c3 true 2>/dev/null; then
    exec nice -n 19 ionice -c3 "$0" "$@"
  fi
  exec nice -n 19 "$0" "$@"
fi

FORCE_DRY=0
[ "${1:-}" = "--dry-run" ] && FORCE_DRY=1

. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit builds-retention
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply builds-retention

# shellcheck source=bin/lib/build-archive.sh
. "$SELF/lib/build-archive.sh" || exit 0

mkdir -p "$H/logs" "$H/locks" 2>/dev/null
LOG="$H/logs/builds-retention.log"
NOW="${BUILDS_RETENTION_NOW:-}"
[[ $NOW =~ ^[0-9]+$ ]] || NOW=$(date -u +%s)
BA_NOW_ISO=$(date -u -d "@$NOW" +%FT%TZ)
line() { printf '%s %s\n' "$BA_NOW_ISO" "$1" >> "$LOG"; }
alert() { "$SELF/lane-alert.sh" "$@" >/dev/null 2>&1 || true; }

exec 8>>"$H/locks/builds-retention.lock"
flock -n 8 || { line "already running"; exit 0; }

# shellcheck source=bin/jobs-client.sh
. "$SELF/jobs-client.sh" >/dev/null 2>&1 || true
set -uo pipefail
# knob <key> <default> <pattern> — the row value when it matches, else the
# default with `(default)` in KNOB_TAG.
knob() {
  local v=""
  KNOB_TAG=""
  command -v setting_get >/dev/null 2>&1 && v=$(setting_get "$1" 2>/dev/null | tr -d '[:space:]')
  if [[ $v =~ $3 ]]; then KNOB="$v"; else KNOB="$2"; KNOB_TAG="(default)"; fi
}
knob builds_retention.window_days 14 '^[1-9][0-9]{0,3}$'; WIN="$KNOB"; WIN_TAG="$KNOB_TAG"
knob builds_retention.dry_run 1 '^[01]$'; DRY="$KNOB"
knob builds_retention.max_dirs 2000 '^[1-9][0-9]{0,6}$'; MAX="$KNOB"
[ "$FORCE_DRY" = 1 ] && DRY=1

B="$H/builds"
AR=$(ba_root "$H")
CUT_E=$(( NOW - (WIN + 1) * 86400 ))
CUT=$(date -u -d "@$CUT_E" +%Y%m%d%H%M%S)
[ -d "$B" ] || { line "run dry=$DRY window=$WIN$WIN_TAG cut=${CUT:0:12} dirs=0 (no builds/)"; exit 0; }
mkdir -p "$AR" 2>/dev/null

# ── cross-filesystem refusal: a move must be a rename ───────────────────────
if [ "${BUILDS_RETENTION_FORCE_XFS:-0}" = 1 ] \
   || [ "$(stat -c %d "$B" 2>/dev/null)" != "$(stat -c %d "$AR" 2>/dev/null)" ]; then
  alert --id builds-retention:cross-fs --severity warn builds-retention \
    "builds/ and builds-archive/ are on different filesystems. builds-retention moved nothing. Put builds-archive/ on the builds/ filesystem."
  line "cross-fs (no move) dry=$DRY window=$WIN$WIN_TAG"
  exit 0
fi

REF=$(mktemp "${TMPDIR:-/tmp}/bret-ref.XXXXXX") || { line "run failed (mktemp)"; exit 0; }
trap 'rm -f "$REF"' EXIT
touch -d "@$CUT_E" "$REF"

# ── the archived names, read once ───────────────────────────────────────────
declare -A INDEXED=()
IDX=$(ba_index "$H")
if [ -r "$IDX" ]; then
  while IFS=$'\t' read -r _ d _ _ _ _ r1; do
    case "$d" in ''|\#*) continue ;; esac
    if [ "$r1" = MOVE_FAILED ]; then unset "INDEXED[$d]"; else INDEXED[$d]=1; fi
  done < "$IDX"
fi

# ── one readdir, grouped by (project, KEY) ──────────────────────────────────
# A name that parses to no key is counted in no-stamp on its own (a hand-made
# dir such as cost-rows-db-20260902). A name with a key and no stamp makes its
# whole group no-stamp.
declare -A GDIRS=() GNEW=() GBAD=() GMAX=()
NDIRS=0; NOSTAMP=0
KRE='^(pool-|fly-)?([a-z0-9][a-z0-9-]*)-([A-Z][A-Z0-9]*-[0-9]+(\.[0-9]+)*)(-|$)'
while IFS= read -r n; do
  [ -n "$n" ] || continue
  NDIRS=$((NDIRS + 1))
  if ba_parse "$n"; then
    g="$BA_P"$'\t'"$BA_K"
    GDIRS[$g]+="$n"$'\t'"$BA_STAMP"$'\n'
    [[ $BA_STAMP < $CUT ]] || GNEW[$g]=1
    [[ ${GMAX[$g]:-} > $BA_STAMP ]] || GMAX[$g]="$BA_STAMP"
  elif [[ $n =~ $KRE ]]; then
    g="${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[3]}"
    GDIRS[$g]+=""; GBAD[$g]=1
  else
    NOSTAMP=$((NOSTAMP + 1))
  fi
done < <(find "$B" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

declare -A KEPT=([no-stamp]=$NOSTAMP [young]=0 [not-merged]=0 [unswept]=0 [remote-json]=0 [live]=0 [collision]=0)
NGROUPS=${#GDIRS[@]}
ELIG=0; MOVED=0; WOULD=0; CAPPED=0; ERRS=0; DONE=0
LIST="$H/logs/builds-retention-dryrun.txt"
[ "$DRY" = 1 ] && : > "$LIST"

# judge <group> — rc 0 eligible, else KEPT_WHY names the rule. File reads and
# stats happen only here, for groups whose every name is past the cut.
judge() {
  local g="$1" p="${1%%$'\t'*}" k="${1#*$'\t'}" n s d l merged=0 unsw=0 lk
  KEPT_WHY=""
  [ -z "${GBAD[$g]:-}" ] || { KEPT_WHY=no-stamp; return 1; }
  [ -z "${GNEW[$g]:-}" ] || { KEPT_WHY=young; return 1; }
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] || continue
    d="$B/$n"
    if [[ -e $d/RESULT && $d/RESULT -nt $REF ]] || [[ -e $d/COMMENTED && $d/COMMENTED -nt $REF ]]; then
      KEPT_WHY=young; return 1
    fi
  done <<<"${GDIRS[$g]}"
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] || continue
    d="$B/$n"
    [ -f "$d/RESULT" ] || continue
    l=$(head -n 1 "$d/RESULT" 2>/dev/null)
    case "$l" in PR_MERGED*) merged=1 ;; esac
    [ -f "$d/COMMENTED" ] && continue
    [ -f "$d/RELAYED" ] && continue
    [ -f "$d/DEFERRED" ] && continue
    case "$l" in QUEUED_FLY*|BUILD_DEFERRED*) continue ;; esac
    unsw=1
  done <<<"${GDIRS[$g]}"
  [ "$merged" = 1 ] || { KEPT_WHY=not-merged; return 1; }
  [ "$unsw" = 0 ] || { KEPT_WHY=unswept; return 1; }
  [ ! -e "$H/state/remote-results/$p/$k.json" ] || { KEPT_WHY=remote-json; return 1; }
  lk="$H/locks/build-key-$p-$k.lock"
  if [ -e "$lk" ] && ! { flock -n 7 ; } 7<"$lk" 2>/dev/null; then KEPT_WHY=live; return 1; fi
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] || continue
    if [ -n "${INDEXED[$n]:-}" ] || [ -e "$AR/${s:0:6}/$n" ]; then KEPT_WHY=collision; return 1; fi
  done <<<"${GDIRS[$g]}"
  return 0
}

# Oldest group first (its newest stamp), so a capped run settles the oldest.
while IFS=$'\t' read -r _ p k; do
  [ -n "$p" ] || continue
  g="$p"$'\t'"$k"
  if [ "$DONE" -ge "$MAX" ]; then CAPPED=1; break; fi
  if ! judge "$g"; then
    KEPT[$KEPT_WHY]=$(( ${KEPT[$KEPT_WHY]} + 1 ))
    [ "$KEPT_WHY" = collision ] && ERRS=$((ERRS + 1))
    continue
  fi
  ELIG=$((ELIG + 1))
  while IFS=$'\t' read -r n s; do
    [ -n "$n" ] || continue
    rel="${s:0:6}/$n"
    DONE=$((DONE + 1))
    if [ "$DRY" = 1 ]; then
      printf '%s\t%s\n' "$n" "$rel" >> "$LIST"; WOULD=$((WOULD + 1)); continue
    fi
    src="$B/$n"; dst="$AR/$rel"
    tid=$(jq -r '.ticket_id // "-" | tostring' "$src/job.json" 2>/dev/null) || tid="-"
    r1=$(head -n 1 "$src/RESULT" 2>/dev/null) || r1=""
    if ! ba_index_append "$H" "$n" "$rel" "$p" "$k" "${tid:--}" "${r1:--}"; then
      ERRS=$((ERRS + 1)); continue   # no row, no move: the dir stays live
    fi
    mkdir -p "$AR/${s:0:6}" 2>/dev/null
    mv -T -n "$src" "$dst" 2>/dev/null
    if [ ! -e "$src" ] && [ -d "$dst" ]; then
      MOVED=$((MOVED + 1))
    else
      ba_index_append "$H" "$n" "$rel" "$p" "$k" "${tid:--}" MOVE_FAILED
      ERRS=$((ERRS + 1))
    fi
  done <<<"${GDIRS[$g]}"
done < <(for g in "${!GDIRS[@]}"; do printf '%s\t%s\n' "${GMAX[$g]:-0}" "$g"; done | sort)

[ "$DRY" = 1 ] && WOULD=$(( $(wc -l < "$LIST" 2>/dev/null || echo 0) ))
line "run dry=$DRY window=$WIN$WIN_TAG cut=${CUT:0:12} dirs=$NDIRS groups=$NGROUPS eligible_groups=$ELIG moved=$MOVED would_move=$WOULD kept no-stamp=${KEPT[no-stamp]} young=${KEPT[young]} not-merged=${KEPT[not-merged]} unswept=${KEPT[unswept]} remote-json=${KEPT[remote-json]} live=${KEPT[live]} collision=${KEPT[collision]} capped=$CAPPED errors=$ERRS wall=${SECONDS}s"
if [ "$ERRS" -gt 0 ]; then
  alert --id builds-retention:errors --severity warn builds-retention \
    "builds-retention had $ERRS error(s) (a failed move or an already archived dir). See logs/builds-retention.log and builds-archive/index.tsv."
else
  alert --resolve --id builds-retention:errors builds-retention "builds-retention runs clean again."
fi
exit 0
