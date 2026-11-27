# shellcheck shell=bash
# bin/lib/repo-change-mark.sh — BH-10218: a repo's CHANGE MARK, read from the
# wake mirror, so a memo of repo metadata (bin/lib/repo-meta.sh) or of a repo's
# merge-queue provider (bin/lib/dequeue-watch/provider-memo.sh) can tell "the
# repo moved since I read GitHub" without reading GitHub. Sourced, never run.
#
#   rcm_mark <slug>
#       prints the mark, rc 0: the highest worker wake id the mirror has read
#       for <slug> (pr-snapshot-wakes.sh's wakes.wm). The worker assigns wake
#       ids in order, so every wake that arrives later has a higher id.
#       rc 2 = the feed cannot tell (no mirror, read not complete, feed not
#       fresh, no wm). Take the mark BEFORE the GitHub read it stamps, so a
#       push during the read voids the memo at the next call.
#   rcm_moved <slug> <kinds> <mark> <stamp-epoch>
#       rc 0 = a wake of one of <kinds> (a comma list: push, repo, ...) with an
#       id above <mark> is in the mirror (moved). rc 1 = none is (quiet).
#       rc 2 = cannot tell: a non-digit mark or stamp, the feed cannot tell
#       (as above), the mirror's wm is below <mark> (its state was reset), or
#       the stamp is older than the mirror's gap-free coverage (wakes.state
#       cov_epoch) or than its 3-day row horizon less one hour.
#
# THE CHANGE MARK IS A SEQUENCE, NEVER A CLOCK. "Moved" compares wake ids only:
# a wake with a higher id and an older `at` is still a move. The stamp epoch is
# read only to prove the mirror still holds every row since the stamp (rows
# older than 3 days are pruned, and a mirror rebuilt after the stamp has a gap
# before its coverage); a stamp outside that window is "cannot tell".
#
# READ, NEVER ACK: the rows come from bin/lib/pr-snapshot-wakes.sh (prs_changed,
# prs_feed_fresh and its state files), the read-only mirror of the worker's
# wakes table. No GitHub call, no wake claimed, bin/wake-loop.sh's cursor is
# untouched. `push` wakes are default-branch pushes only (wakeOf, core.js);
# `repo` wakes are a default-branch change, a rename or a transfer (BH-10218).
#
# The root is ${HARNESS:-${H:-}} and nothing else. With no _jobs_req loaded,
# bin/jobs-client.sh is sourced from that root when it is there; with none,
# every answer is rc 2. No `set -e`, no `exit`.
if [ -n "${REPO_CHANGE_MARK_LIB:-}" ]; then return 0 2>/dev/null; fi
REPO_CHANGE_MARK_LIB=1
# The mirror's row horizon (pr-snapshot-wakes.sh PRSW_KEEP_S, 3 days) less one
# hour of margin for a wake whose minute bucket is older than its id. Mechanism
# bounds, the mirror's own, not settings.
RCM_HORIZON_S=255600

_rcm_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) printf '%s' "$((10#$1))" ;; esac; }
_rcm_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && _rcm_int "${RCM_NOW:-}" >/dev/null; then
    printf '%s' "$((10#$RCM_NOW))"
  else date +%s; fi
}

# _rcm_load — the mirror and the jobs client, once. rc 1 = no mirror.
_rcm_load() {
  local root="${HARNESS:-${H:-}}" l
  if ! command -v _jobs_req >/dev/null 2>&1 && [ -n "$root" ] && [ -r "$root/bin/jobs-client.sh" ]; then
    # shellcheck source=/dev/null
    . "$root/bin/jobs-client.sh" >/dev/null 2>&1
  fi
  if ! declare -F _prsw_refresh >/dev/null 2>&1; then
    l="$(dirname "${BASH_SOURCE[0]}")/pr-snapshot.sh"
    # shellcheck source=bin/lib/pr-snapshot.sh
    [ -r "$l" ] && . "$l" >/dev/null 2>&1
  fi
  declare -F _prsw_refresh >/dev/null 2>&1 && declare -F _prs_dir >/dev/null 2>&1
}

# _rcm_feed <slug> — refresh the mirror, then set RCM_DIR and RCM_WM. rc 0 only
# when the last read was complete, the feed is fresh and coverage has begun.
_rcm_feed() {
  local slug="${1:-}"
  RCM_DIR=""; RCM_WM=""
  [ -n "$slug" ] && _rcm_load || return 2
  RCM_DIR=$(_prs_dir "$slug" 2>/dev/null) || return 2
  _prsw_refresh "$slug" || return 2
  _prsw_state "$RCM_DIR"
  [ "$PRSW_COMPLETE" = 1 ] && [ "$PRSW_FRESH" = 1 ] && [ "$PRSW_COV" -gt 0 ] || return 2
  RCM_WM=$(_rcm_int "$(tr -dc '0-9' 2>/dev/null < "$RCM_DIR/wakes.wm")") || return 2
  return 0
}

rcm_mark() {
  _rcm_feed "${1:-}" || return 2
  printf '%s\n' "$RCM_WM"
}

rcm_moved() {
  local slug="${1:-}" kinds="${2:-}" mark stamp now
  mark=$(_rcm_int "${3:-}") || return 2
  stamp=$(_rcm_int "${4:-}") || return 2
  [ -n "$kinds" ] || return 2
  _rcm_feed "$slug" || return 2
  [ "$RCM_WM" -ge "$mark" ] || return 2
  now=$(_rcm_now)
  [ "$stamp" -ge "$PRSW_COV" ] || return 2
  [ $((now - stamp)) -lt "$RCM_HORIZON_S" ] || return 2
  [ -r "$RCM_DIR/changed.tsv" ] || return 1
  # shellcheck disable=SC2016
  awk -F'\t' -v ks=",$kinds," -v m="$mark" '
    $3 ~ /^[0-9]+$/ && $3 + 0 > m + 0 && index(ks, "," $1 ",") { f = 1; exit }
    END { exit f ? 0 : 1 }' "$RCM_DIR/changed.tsv" && return 0
  return 1
}
