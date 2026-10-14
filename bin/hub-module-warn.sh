#!/bin/bash
# bin/hub-module-warn.sh — the HUB_MODULE signal (BH-6384). When 3 or more
# pre-planned tickets of one project each plan a real edit to the same EXISTING
# file, that file is a hub every parallel build collides on. This logs it once
# a day per project, so an operator can split the module. It is a signal, not a
# gate: rc is 0 on every path except a usage error (rc 2).
#
# Usage:
#   hub-module-warn.sh <project> [--index FILE] [--repo DIR] [--now EPOCH]
#   hub-module-warn.sh --box     run it for every project of this box
#                                (bin/box-name.sh + bin/fleet-conf.sh)
#
#   --index FILE  read the pre-plan index TSV from FILE, not the worker
#                 (key, base_sha, updated_at, planned_files with `|` between)
#   --repo DIR    the checkout to test "existing" against (default
#                 ${REPOS_ROOT:-/root/repos}/<project>)
#   --now EPOCH   the clock, for the daily stamp and the log stamp
#
# Steps, in order:
#   1. state/hub-module/<project>.day holds the UTC date of the last run. If it
#      is today, exit 0 with no read at all.
#   2. Write the stamp BEFORE the read, so a dead worker costs one call a day,
#      not one per 2-minute tick.
#   3. Read the index (--index, else preplan_index through bin/jobs-client.sh).
#      A failed read logs `HUB_MODULE_SKIPPED <project> index-unreachable`.
#   4. Keep a planned path only if it is a file (a blob) at HEAD of the repo. A
#      new path or a bare directory is not a hub. No checkout logs
#      `HUB_MODULE_SKIPPED <project> no-checkout`.
#   5. Count distinct ticket keys per path. Each path with 3 or more appends
#      `<stamp> HUB_MODULE <path> <n> tickets (<key>,<key>,...)` to
#      logs/<project>.log.
# The threshold 3 is the ticket's number (BH-6384 scope 4); the line gates
# nothing, so it stays a code constant.
set -u
HARNESS="${HARNESS:-/root/harness}"
HM_MIN=3

if [ "${1:-}" = "--box" ]; then
  box=$("$HARNESS/bin/box-name.sh" 2>/dev/null || true)
  [ -n "$box" ] || exit 0
  for p in $("$HARNESS/bin/fleet-conf.sh" --projects-on-box "$box" 2>/dev/null); do
    "$0" "$p" </dev/null || true
  done
  exit 0
fi

P="${1:-}"
case "$P" in ''|-*) echo "usage: hub-module-warn.sh <project> [--index FILE] [--repo DIR] [--now EPOCH] | --box" >&2; exit 2 ;; esac
shift
INDEX=""; REPO="${REPOS_ROOT:-/root/repos}/$P"; NOW=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --index) INDEX="${2:-}"; shift 2 ;;
    --repo)  REPO="${2:-}"; shift 2 ;;
    --now)   NOW="${2:-}"; shift 2 ;;
    *) echo "hub-module-warn: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$NOW" in '') NOW=$(date -u +%s) ;; *[!0-9]*) echo "hub-module-warn: --now takes epoch seconds" >&2; exit 2 ;; esac
DAY=$(date -u -d "@$NOW" +%F)
STAMP=$(date -u -d "@$NOW" '+%F %TZ')
PLOG="$HARNESS/logs/$P.log"
SDIR="$HARNESS/state/hub-module"
SFILE="$SDIR/$P.day"

[ "$(cat "$SFILE" 2>/dev/null)" = "$DAY" ] && exit 0
mkdir -p "$SDIR" "$HARNESS/logs" 2>/dev/null
printf '%s\n' "$DAY" > "$SFILE" 2>/dev/null

if ! git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo "$STAMP HUB_MODULE_SKIPPED $P no-checkout" >> "$PLOG"
  exit 0
fi

ROWS=""; RD=0
if [ -n "$INDEX" ]; then
  ROWS=$(cat "$INDEX" 2>/dev/null) || RD=1
else
  # shellcheck source=/dev/null
  if [ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null \
     && command -v preplan_index >/dev/null 2>&1; then
    ROWS=$(preplan_index "$P" 2>/dev/null) || RD=1
  else
    RD=1
  fi
fi
if [ "$RD" != 0 ]; then
  echo "$STAMP HUB_MODULE_SKIPPED $P index-unreachable" >> "$PLOG"
  exit 0
fi

# key<TAB>path, one per distinct pair, so a key that lists a path twice counts once.
PAIRS=$(printf '%s\n' "$ROWS" | awk -F'\t' 'NF >= 4 && $1 != "" {
  n = split($4, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") print $1 "\t" a[i] }' | LC_ALL=C sort -u)
[ -n "$PAIRS" ] || exit 0
# Only paths that are a blob at HEAD, in one batch call. git answers one line
# per input line, in order (`<type>` or `HEAD:<path> missing`), so the answers
# are pasted back onto the paths they belong to.
CANDS=$(printf '%s\n' "$PAIRS" | cut -f2 | LC_ALL=C sort -u)
BLOBS=$(paste <(printf '%s\n' "$CANDS") \
          <(printf '%s\n' "$CANDS" | sed 's/^/HEAD:/' | git -C "$REPO" cat-file --batch-check='%(objecttype)' 2>/dev/null) \
        | awk -F'\t' '$2 == "blob" { print $1 }')
[ -n "$BLOBS" ] || exit 0

printf '%s\n' "$PAIRS" | awk -F'\t' -v min="$HM_MIN" -v stamp="$STAMP" '
  NR == FNR { keep[$0] = 1; next }
  ($2 in keep) { c[$2]++; k[$2] = (k[$2] == "" ? $1 : k[$2] "," $1) }
  END { for (p in c) if (c[p] >= min) printf "%s HUB_MODULE %s %d tickets (%s)\n", stamp, p, c[p], k[p] }' \
  <(printf '%s\n' "$BLOBS") - | LC_ALL=C sort >> "$PLOG"
exit 0
