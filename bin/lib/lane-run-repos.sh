#!/bin/bash
# bin/lib/lane-run-repos.sh — which fleet repos a lane-run machine can read,
# checked once at process start (BH-6942). Sourced, never executed.
#
#   lrr_enabled    rc 0 when ${LANE_RUN_REPO_CHECK:-$LANE_RUN_CODE_SYNC} is 1.
#                  A lane-run machine has LANE_RUN_CODE_SYNC=1 from its
#                  entrypoint; the hub and a --once run do not.
#   lrr_check      one classified REST read (gh_rest GET repos/<slug>) per
#                  DISTINCT repo in fleet.conf, with the conductor's own token
#                  path (gh_repo_use_token). The verdict comes from the read:
#                    rc 0                  readable
#                    rc 44 (404)           unreadable 404 (+ -no-token when no
#                                          rung of the token ladder sees it)
#                    rc 75, status 401     unreadable 401-auth
#                    any other rc 75       unknown <status>-<reason>: a rate
#                                          limit, a network error, a 5xx or a
#                                          quota reserve. NOT refused, so a
#                                          transient error never strands rows.
#                  It writes state/lane-run-worker/skip-prefixes (tmp + mv):
#                  one `<project>.` line for each project whose repo is
#                  unreadable, empty when none is. One line per unreadable or
#                  unknown repo, then one summary line `repo check: <r> of <n>
#                  repos readable, <u> unreadable, <k> unknown`, go to
#                  logs/lane-run-worker.log and to stderr (the Fly log). Each
#                  refused project gets ONE `lane-alert.sh --severity warn --id
#                  lane-run-repo-unreadable-<project>` (lane-alert dedupes by
#                  id across machines). When fleet-conf.sh fails it writes no
#                  file (an old one is removed first) and one log line, and
#                  nothing is refused. Always rc 0.
#   lrr_skip_json  the skip file as a JSON array of at most 64 entries (the
#                  claim route's cap); `[]` when the file is missing or empty.
#
# The worker sends the array as `skip_prefixes` in its claim
# (worker/jobs/src/routes/lane-runs.js), so a merge-conductor-pr row
# `<project>.<pr>.<head12>` of an unreadable repo stays queued and the hub
# takes it back (bin/lib/mc/fly-workers.sh, no-capacity). Token values never
# reach a log: only repo slugs, statuses and reason words do.
_LRR_H="${HARNESS:-${H:-}}"
_LRR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=bin/lib/gh-rest.sh
. "$_LRR_LIB/gh-rest.sh" || return 1
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$_LRR_LIB/gh-repo-token.sh" ] && . "$_LRR_LIB/gh-repo-token.sh"

lrr_enabled() {
  [ "${LANE_RUN_REPO_CHECK:-${LANE_RUN_CODE_SYNC:-0}}" = 1 ]
}

_lrr_file() { printf '%s/state/lane-run-worker/skip-prefixes' "$_LRR_H"; }

_lrr_log() {
  local ts
  if [ -n "${LANE_RUN_NOW:-}" ]; then ts=$(date -u -d "@$LANE_RUN_NOW" '+%F %TZ' 2>/dev/null); else ts=$(date -u '+%F %TZ'); fi
  mkdir -p "$_LRR_H/logs" 2>/dev/null
  echo "$ts [lane-run-worker] ${MACHINE:-${FLY_MACHINE_ID:-machine}}: $*" >> "$_LRR_H/logs/lane-run-worker.log"
  echo "lane-run-worker ${MACHINE:-${FLY_MACHINE_ID:-machine}}: $*" >&2
}

# _lrr_verdict <slug> — sets LRR_VERDICT (readable|unreadable|unknown) and
# LRR_WHY in THIS shell. gh_rest runs as a plain command, so its status
# variables survive (the gh-rest.sh scope rule).
_lrr_verdict() {
  local slug="$1" grc=0 tok=1
  if command -v gh_repo_use_token >/dev/null 2>&1; then gh_repo_use_token "$slug" >/dev/null 2>&1 || tok=0; fi
  gh_rest GET "repos/$slug" > /dev/null || grc=$?
  command -v gh_repo_token_reset >/dev/null 2>&1 && gh_repo_token_reset
  case "$grc" in
    0) LRR_VERDICT=readable; LRR_WHY="" ;;
    44) LRR_VERDICT=unreadable; LRR_WHY=404; [ "$tok" = 0 ] && LRR_WHY="404-no-token" ;;
    *)
      if [ "$grc" = 75 ] && [ "${GH_REST_STATUS:-}" = 401 ] && [ "${GH_REST_REASON:-}" = auth ]; then
        LRR_VERDICT=unreadable; LRR_WHY=401-auth
      else
        LRR_VERDICT=unknown; LRR_WHY="${GH_REST_STATUS:-000}-${GH_REST_REASON:-}"
      fi ;;
  esac
}

lrr_check() {
  local f tmp projects p slug n=0 r=0 u=0 k=0
  local -A repo_of=() verdict=() why=()
  local -a order=()
  [ -n "$_LRR_H" ] || return 0
  f=$(_lrr_file)
  mkdir -p "${f%/*}" 2>/dev/null
  rm -f "$f"
  if ! projects=$("$_LRR_H/bin/fleet-conf.sh" --projects 2>/dev/null); then
    _lrr_log "repo check: fleet-conf.sh --projects failed; no repo is refused"
    return 0
  fi
  for p in $projects; do
    slug=$("$_LRR_H/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
    case "$slug" in ''|-) continue ;; */*) ;; *) continue ;; esac
    repo_of[$p]="$slug"
    if [ -z "${verdict[$slug]+x}" ]; then
      _lrr_verdict "$slug"
      verdict[$slug]="$LRR_VERDICT"; why[$slug]="$LRR_WHY"; order+=("$slug")
    fi
  done
  for slug in ${order[@]+"${order[@]}"}; do
    n=$((n + 1))
    case "${verdict[$slug]}" in
      readable) r=$((r + 1)) ;;
      unreadable) u=$((u + 1)); _lrr_log "repo check: $slug unreadable ${why[$slug]}; its merge-conductor-pr rows are refused at claim and go to the hub" ;;
      *) k=$((k + 1)); _lrr_log "repo check: $slug unknown ${why[$slug]}; not refused" ;;
    esac
  done
  tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || { _lrr_log "repo check: cannot write the skip file; no repo is refused"; return 0; }
  for p in $projects; do
    slug="${repo_of[$p]:-}"
    [ -n "$slug" ] && [ "${verdict[$slug]}" = unreadable ] && printf '%s.\n' "$p"
  done > "$tmp"
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; _lrr_log "repo check: cannot write the skip file; no repo is refused"; return 0; }
  _lrr_log "repo check: $r of $n repos readable, $u unreadable, $k unknown"
  for p in $projects; do
    slug="${repo_of[$p]:-}"
    [ -n "$slug" ] && [ "${verdict[$slug]}" = unreadable ] || continue
    [ -x "$_LRR_H/bin/lane-alert.sh" ] && "$_LRR_H/bin/lane-alert.sh" --severity warn --id "lane-run-repo-unreadable-$p" lane-run-worker \
      "lane machine ${MACHINE:-${FLY_MACHINE_ID:-machine}} cannot read $slug (${why[$slug]}). The merge-conductor-pr rows of $p are refused at claim and go to the hub after MC_FLY_QUEUE_STALE_S. Check the machine's GitHub token for $slug." \
      >/dev/null 2>&1
  done
  return 0
}

lrr_skip_json() {
  local f
  [ -n "$_LRR_H" ] || { printf '[]\n'; return 0; }
  f=$(_lrr_file)
  if [ ! -s "$f" ]; then printf '[]\n'; return 0; fi
  grep -E '^[A-Za-z0-9._-]{1,65}$' "$f" 2>/dev/null | awk 'NR <= 64' | jq -Rnc '[inputs]'
}
