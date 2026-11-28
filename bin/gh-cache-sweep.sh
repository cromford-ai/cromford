#!/bin/bash
# bin/gh-cache-sweep.sh [project…] — the missed-webhook sweep of the gh shim
# cache (state/gh-cache/, bin/lib/gh-cache.sh). Hub cron every 5 minutes; a
# sweep runs once per GH_CACHE_SWEEP_PERIOD_S.
#
# WHY. The shim cache serves a PR-scoped entry past its TTL while the wake feed
# is healthy, because a webhook wake drops the entry when the PR changes. A
# webhook that never arrives would hide the change. This lane reads each
# registry repo's open PRs and recently updated issues, compares them with its
# own last record, and drops the entries of every object that changed.
#
# PER REPO (bin/fleet-conf.sh --projects, then <project> repo; unique slugs):
#   1. GET repos/<slug>/pulls?state=open&per_page=100&page=<k> until a page has
#      fewer than 100 rows. A full page GH_CACHE_SWEEP_MAX_PAGES = incomplete.
#   2. With a stamp: GET repos/<slug>/issues?state=all&sort=updated&direction=desc
#      &since=<prev sweep start - GH_CACHE_SWEEP_OVERLAP_S>&per_page=100&page=<k>.
#      A full last page = the window is too big: the chain restarts (no drops,
#      nothing fetched before this sweep is covered).
#   3. Any read rc != 0 or a body that is not a JSON array: the repo is
#      unreadable. Nothing is dropped or written for it; the next run tries again.
#   4. Changed (dropped): an open PR whose updated_at or head differs from the
#      record, a recorded open PR that left the list, a new open PR, an issues
#      row whose (number, updated_at) is not in the record. For each: the cache
#      entries <repo>~n-<N>~* and <repo>~s-<sha12>~* of its old and new head.
#      One or more changes also drop <repo>~r~* (the lists).
#   5. Then the record state/gh-cache-sweep/<repo>.tsv and the stamp
#      state/gh-cache-sweep/<repo>.stamp (`v3 <sweep_start> <chain_start>
#      <period_s> <base> <end> <trust_periods>`), each tmp+mv, the stamp last.
#      <trust_periods> is GH_CACHE_SWEEP_TRUST_PERIODS: ghc_sweep_covers trusts
#      the stamp for that many periods. <end> is the time
#      this sweep finished its reads and drops. <base> is the previous stamp's
#      <end> (a restart: this sweep's own <end>): an entry fetched at or before
#      it is never vouched for, because that sweep may have read the page, or
#      dropped the entry, after the fetch.
# ghc_sweep_covers (bin/lib/gh-cache-sweep.sh) reads the stamp.
#
# The sweep's own reads never come from the shim cache: GH_CACHE_TTL_S=0 for
# this process. gh_rest still sends its ETag, so an unchanged page is a 304.
#
# Log: one line per run to logs/gh-cache-sweep.log:
#   repos=<n> rows=<n> changed=<n> unreadable=<n> requests=<n> period=<s> overlap=<s> max_pages=<n> trust_periods=<n>
#
# Off by default (GH_CACHE_SWEEP default 0: its open-PR list read doubles the
# BH-9939 prr-sweep list read, off until a rework trusts the prr-sweep stamp).
# On: GH_CACHE_SWEEP=1. Off: GH_CACHE_SWEEP=0, flags/lane-off-gh-cache-sweep, or
# bin/harness-ctl.sh off gh-cache-sweep. rc 0 always.
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$BIN/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165). Registry: catalog/lanes.d/gh-cache-sweep.json.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit gh-cache-sweep
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-cache-sweep
set -a +u; # shellcheck disable=SC1090,SC1091
. "$HENV/global.env" 2>/dev/null; set +a -u
# Applied again: global.env re-assigns every name it carries.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    gh-cache-sweep
[ "${GH_CACHE_SWEEP:-0}" = 1 ] || exit 0   # fallback for the settings row lane.gh-cache-sweep.gh_cache_sweep: unset = off (ships off)

PERIOD="${GH_CACHE_SWEEP_PERIOD_S:-}"
case "$PERIOD" in ''|*[!0-9]*) PERIOD=900 ;; esac       # fallback for the settings row lane.gh-cache-sweep.gh_cache_sweep_period_s
PERIOD=$((10#$PERIOD)); [ "$PERIOD" -ge 300 ] || PERIOD=300   # the knob's min: the cron runs every 5 minutes
OVERLAP="${GH_CACHE_SWEEP_OVERLAP_S:-}"
case "$OVERLAP" in ''|*[!0-9]*) OVERLAP=120 ;; esac     # fallback for the settings row lane.gh-cache-sweep.gh_cache_sweep_overlap_s
OVERLAP=$((10#$OVERLAP))
MAXP="${GH_CACHE_SWEEP_MAX_PAGES:-}"
case "$MAXP" in ''|*[!0-9]*|0) MAXP=20 ;; esac          # fallback for the settings row lane.gh-cache-sweep.gh_cache_sweep_max_pages
MAXP=$((10#$MAXP)); [ "$MAXP" -ge 1 ] || MAXP=20
TRUST="${GH_CACHE_SWEEP_TRUST_PERIODS:-}"
case "$TRUST" in ''|*[!0-9]*) TRUST=2 ;; esac           # fallback for the settings row lane.gh-cache-sweep.gh_cache_sweep_trust_periods
TRUST=$((10#$TRUST)); [ "$TRUST" -ge 1 ] || TRUST=1; [ "$TRUST" -le 8 ] || TRUST=8   # the knob's min and max

LOG="$H/logs/gh-cache-sweep.log"
SD="$H/state/gh-cache-sweep"
CACHE="$H/state/gh-cache"
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
say() { echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') $*" >> "$LOG" 2>/dev/null; }

# shellcheck source=bin/lib/gh-rest.sh
. "$BIN/lib/gh-rest.sh" 2>/dev/null || { say "cannot load bin/lib/gh-rest.sh — skipped"; exit 0; }
# shellcheck source=bin/lib/gh-cache.sh
. "$BIN/lib/gh-cache.sh" 2>/dev/null || { say "cannot load bin/lib/gh-cache.sh — skipped"; exit 0; }
# shellcheck disable=SC1091
[ -r "$H/bin/lib/gh-app-auth.sh" ] && . "$H/bin/lib/gh-app-auth.sh" 2>/dev/null
command -v jq >/dev/null 2>&1 || { say "no jq — skipped"; exit 0; }

exec 9>"$H/locks/gh-cache-sweep.lock" || { say "cannot open locks/gh-cache-sweep.lock — skipped"; exit 0; }
flock -n 9 2>/dev/null || exit 0

NOW=$(ghc_now)
LAST=""; [ -r "$SD/.last-run" ] && read -r LAST _ < "$SD/.last-run" 2>/dev/null
case "${LAST:-}" in ''|*[!0-9]*) LAST="" ;; esac
# Whole minutes, so cron jitter of a few seconds never skips a period.
if [ -n "$LAST" ] && [ $((NOW / 60 - LAST / 60)) -ge 0 ] && [ $((NOW / 60 - LAST / 60)) -lt $((PERIOD / 60)) ]; then exit 0; fi

# The shim cache must never answer the sweep's own reads.
export GH_CACHE_TTL_S=0

# project-loop-ok: the loop only maps projects to unique repo slugs (projects that share a repo are read once); the sweep reads per repo, not per project, in one bounded pass per GH_CACHE_SWEEP_PERIOD_S under one lock, so per-project runners would read a shared repo twice.
if [ $# -gt 0 ]; then PROJECTS=$(printf '%s\n' "$@")
else PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null) || PROJECTS=""
fi
SLUGS=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  s=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || continue
  [[ "$s" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
  SLUGS="$SLUGS$s"$'\n'
done <<<"$PROJECTS"
SLUGS=$(printf '%s' "$SLUGS" | awk 'NF && !seen[tolower($0)]++')
if [ -z "$SLUGS" ]; then say "registry unreadable or empty — skipped"; exit 0; fi

mkdir -p "$SD" 2>/dev/null || { say "cannot create state/gh-cache-sweep — skipped"; exit 0; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-cache-sweep.XXXXXX") || { say "no temp dir — skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

REQS=0; NREPO=0; NROWS=0; NCHANGED=0; NBAD=0

_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; }

# read_list <path without page> <jq row filter> <out> — rc 0 complete, rc 1
# unreadable (WHY set), rc 2 GH_CACHE_SWEEP_MAX_PAGES full pages.
read_list() {
  local base="$1" filt="$2" out="$3" k=1 rc n
  : > "$out"
  while [ "$k" -le "$MAXP" ]; do
    rc=0
    REQS=$((REQS + 1))
    gh_rest GET "$base&page=$k" > "$WORK/page" || rc=$?
    if [ "$rc" != 0 ]; then WHY="status=$GH_REST_STATUS reason=${GH_REST_REASON:-rc$rc} page=$k"; return 1; fi
    n=$(jq -e 'if type == "array" then length else error("not an array") end' "$WORK/page" 2>/dev/null) \
      || { WHY="status=$GH_REST_STATUS reason=not-an-array page=$k"; return 1; }
    jq -r "$filt" "$WORK/page" >> "$out" 2>/dev/null || { WHY="status=$GH_REST_STATUS reason=bad-rows page=$k"; return 1; }
    [ "$n" -lt 100 ] && return 0
    k=$((k + 1))
  done
  return 2
}

# R1: <record> <new rows> → changed objects, one `N<TAB>old head<TAB>new head` line each.
classify() {
  awk -F'\t' '
    FNR == NR { if ($1 == "p") { op[$2] = $3 "\t" $4 } seen[$2 "\t" $3] = 1; next }
    $1 == "p" { np[$2] = 1
                if (!($2 in op)) { ch[$2] = "-\t" $4 }
                else { split(op[$2], o, "\t"); if (o[1] != $3 || o[2] != $4) ch[$2] = o[2] "\t" $4 }
                next }
    $1 == "i" { if (!(($2 "\t" $3) in seen) && !($2 in ch)) ch[$2] = "-\t-" }
    END {
      for (n in op) if (!(n in np)) { split(op[n], o, "\t"); ch[n] = o[2] "\t-" }
      for (n in ch) print n "\t" ch[n]
    }' "$1" "$2"
}

PROW='.[] | ["p", (.number | tostring), (.updated_at // "-"), (.head.sha // "-")] | @tsv'
IROW='.[] | ["i", (.number | tostring), (.updated_at // "-"), "-"] | @tsv'

while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  NREPO=$((NREPO + 1))
  repo=$(_ghc_repo_tag "$slug") || { NBAD=$((NBAD + 1)); say "repo=$slug unreadable reason=bad-slug"; continue; }
  command -v gh_auth_for >/dev/null 2>&1 && { gh_auth_for "$slug" || true; }
  rec="$SD/$repo.tsv"; stp="$SD/$repo.stamp"
  start=$(ghc_now)
  # The previous complete sweep, if its stamp and record are both there.
  pv=""; ps=""; pc=""; pe=""; restart=0
  [ -r "$stp" ] && read -r pv ps pc _ _ pe _ < "$stp" 2>/dev/null
  if [ "${pv:-}" != v3 ] || ! [[ "${ps:-}" =~ ^[0-9]+$ ]] || ! [[ "${pc:-}" =~ ^[0-9]+$ ]] || ! [[ "${pe:-}" =~ ^[0-9]+$ ]] || [ ! -f "$rec" ]; then restart=1; fi
  WHY=""
  rc=0; read_list "repos/$slug/pulls?state=open&per_page=100" "$PROW" "$WORK/new" || rc=$?
  if [ "$rc" = 2 ]; then WHY="reason=max-pages pulls"; fi
  if [ "$rc" = 0 ] && [ "$restart" = 0 ]; then
    since=$(_iso $((ps - OVERLAP)))
    if [ -z "$since" ]; then rc=1; WHY="reason=no-date"
    else
      rc=0; read_list "repos/$slug/issues?state=all&sort=updated&direction=desc&since=$since&per_page=100" "$IROW" "$WORK/iss" || rc=$?
      if [ "$rc" = 2 ]; then rc=0; restart=1; say "repo=$slug issues window over $MAXP pages — chain restarts"
      elif [ "$rc" = 0 ]; then cat "$WORK/iss" >> "$WORK/new"; fi
    fi
  fi
  if [ "$rc" != 0 ]; then NBAD=$((NBAD + 1)); say "repo=$slug unreadable $WHY"; continue; fi
  end=$(ghc_now)
  LC_ALL=C sort -u "$WORK/new" -o "$WORK/new"
  NROWS=$((NROWS + $(grep -c . "$WORK/new")))
  : > "$WORK/changed"
  if [ "$restart" = 0 ]; then classify "$rec" "$WORK/new" > "$WORK/changed"; chain="$pc"; else chain="$end"; fi
  # Drops first, then the record, then the stamp: a crash in between re-detects.
  n=0
  while IFS=$'\t' read -r num oh nh; do
    [[ "$num" =~ ^[0-9]+$ ]] || continue
    n=$((n + 1))
    ghc_drop "$CACHE/$repo~n-$((10#$num))~*"
    for hs in "$oh" "$nh"; do
      hs=$(printf '%s' "$hs" | tr 'A-Z' 'a-z')
      [[ "$hs" =~ ^[0-9a-f]{7,64}$ ]] && ghc_drop "$CACHE/$repo~s-${hs:0:12}~*"
    done
  done < "$WORK/changed"
  [ "$n" -gt 0 ] && ghc_drop "$CACHE/$repo~r~*"
  NCHANGED=$((NCHANGED + n))
  done_at=$(ghc_now)
  if [ "$restart" = 0 ]; then sbase="$pe"; else sbase="$done_at"; fi
  { cp "$WORK/new" "$rec.tmp.$$" && mv -f "$rec.tmp.$$" "$rec"; } 2>/dev/null \
    || { rm -f "$rec.tmp.$$"; NBAD=$((NBAD + 1)); say "repo=$slug record not written"; continue; }
  { printf 'v3 %s %s %s %s %s %s\n' "$start" "$chain" "$PERIOD" "$sbase" "$done_at" "$TRUST" > "$stp.tmp.$$" && mv -f "$stp.tmp.$$" "$stp"; } 2>/dev/null \
    || { rm -f "$stp.tmp.$$"; say "repo=$slug stamp not written"; }
done <<<"$SLUGS"

# A run where every repo was unreadable writes no .last-run: the next 5-minute run tries again.
if [ "$NBAD" -lt "$NREPO" ]; then
  { printf '%s\n' "$NOW" > "$SD/.last-run.$$" && mv -f "$SD/.last-run.$$" "$SD/.last-run"; } 2>/dev/null
fi
rm -f "$SD/.last-run.$$" 2>/dev/null
say "repos=$NREPO rows=$NROWS changed=$NCHANGED unreadable=$NBAD requests=$REQS period=$PERIOD overlap=$OVERLAP max_pages=$MAXP trust_periods=$TRUST"
exit 0
