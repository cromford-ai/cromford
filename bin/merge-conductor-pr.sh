#!/bin/bash
# bin/merge-conductor-pr.sh <project> <owner/repo>#<pr> <head40> [<run key>]
# — one PR's conductor worker on a lane-run machine (BH-6495, BH-6047.5).
#
# The hub's tick enqueues this as a lane_runs row of lane merge-conductor-pr
# (bin/lib/mc/fly-workers.sh, mc_fly_enqueue), and bin/lane-run-worker.sh runs
# it through bin/project-lane-run.sh, which appends the row's project, the run
# key <project>.<pr>.<head12>, as the last argument. Steps:
#
#   1. check    the project's repo in fleet.conf is <owner/repo>, the head is
#               40 hex, and a run key, when given, is mc_fly_run_key of the
#               other arguments. Else exit 2 and run nothing.
#   2. head     ONE REST read of the PR. A head other than <head40> prints
#               `PROF mc-pr state=HEAD_MOVED reason=head-moved deferred=-` and
#               exits 0: the hub enqueues the new head as a new row. A PR that
#               is gone prints state=ABSENT and exits 0. A read that cannot be
#               verified prints state=UNVERIFIABLE and exits 75, with reason
#               head-read-rc<n>-<GH_REST_STATUS>-<GH_REST_REASON|none>
#               [-via-<app|default|admin|unknown>].
#   3. run      bin/merge-conductor.sh with MC_ONLY_PR=<owner/repo>#<pr>,
#               MC_FANIN_SOLO_RUN=1 and MC_ON_MACHINE=1: today's keyed tick for
#               this one PR. MC_ON_MACHINE=1 makes the detached rebase,
#               re-review and deploy-verify spawns and every landing (a READY
#               PR's enqueue or merge, a settle) answer "deferred" and write
#               their name to MC_PR_DEFERRED_FILE (they need this box's job
#               files, build records or merge lock, which the hub keeps). The
#               repo-wide QUEUED settle pass and the self-enqueue steps do
#               not run.
#   4. report   ONE line `PROF mc-pr state=<S> reason=<word> deferred=<w|->`:
#               S is the PR's row in state/merge-conductor/pr-state.tsv after
#               the run (NONE when the run wrote none), reason is the first
#               four words of the row's reason joined by `-` (at most 40
#               bytes of [A-Za-z0-9._:-]), and deferred is the spawns that
#               deferred, comma-joined. The hub reads deferred= from the stored
#               row and runs that PR on the hub on its next tick.
#
# The exit code is the conductor's own. Contract:
# docs/notes/2026-10-14-BH-6495-conductor-fly.md.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS="$H"
# The conductor's own rule: this root's fleet.conf, not another harness's.
[ -f "$H/fleet.conf" ] && export FLEET_CONF="${FLEET_CONF:-$H/fleet.conf}"
# shellcheck source=bin/lib/mc/fly-workers.sh
. "$H/bin/lib/mc/fly-workers.sh" || exit 1
# shellcheck source=bin/lib/gh-rest.sh
. "$H/bin/lib/gh-rest.sh" || exit 1
# shellcheck source=bin/lib/gh-repo-token.sh
[ -r "$H/bin/lib/gh-repo-token.sh" ] && . "$H/bin/lib/gh-repo-token.sh"

usage() { echo "usage: merge-conductor-pr.sh <project> <owner/repo>#<pr> <head40> [<run key>]" >&2; exit 2; }
[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
P="$1"; KEY="$2"; HEAD="$3"; RUNKEY="${4:-}"
[[ $KEY =~ ^([^#[:space:]]+/[^#[:space:]]+)#([0-9]+)$ ]] || usage
SLUG="${BASH_REMATCH[1]}"; NUM="${BASH_REMATCH[2]}"
[[ $HEAD =~ ^[0-9a-f]{40}$ ]] || { echo "merge-conductor-pr: head '$HEAD' is not 40 hex" >&2; exit 2; }
WANT=$(mc_fly_run_key "$P" "$NUM" "$HEAD") || { echo "merge-conductor-pr: no run key for '$P' #$NUM" >&2; exit 2; }
if [ -n "$RUNKEY" ] && [ "$RUNKEY" != "$WANT" ]; then
  echo "merge-conductor-pr: run key '$RUNKEY' is not $WANT" >&2; exit 2
fi
REPO=$("$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null) || REPO=""
[ -n "$REPO" ] && [ "${REPO,,}" = "${SLUG,,}" ] \
  || { echo "merge-conductor-pr: fleet.conf repo of '$P' is '${REPO:-none}', not $SLUG" >&2; exit 2; }

prof() { printf 'PROF mc-pr state=%s reason=%s deferred=%s\n' "$1" "$2" "$3"; }

mkdir -p "$H/state/merge-conductor-pr" 2>/dev/null
TMP=$(mktemp "$H/state/merge-conductor-pr/run.XXXXXX") || exit 1
DEF="$TMP.deferred"
trap 'rm -f "$TMP" "$DEF"' EXIT

command -v gh_repo_use_token >/dev/null 2>&1 && { gh_repo_use_token "$SLUG" >/dev/null 2>&1 || true; }
grc=0
gh_rest GET "repos/$SLUG/pulls/$NUM" > "$TMP" || grc=$?
case "$grc" in
  0) ;;
  44) prof ABSENT pr-absent -; exit 0 ;;
  *)
    # The status and reason of the read (BH-6942): gh_rest ran as a plain
    # command, so they are still in this shell.
    HRW="head-read-rc$grc-${GH_REST_STATUS:-000}-${GH_REST_REASON:-none}"
    command -v gh_repo_current_rung >/dev/null 2>&1 && HRW="$HRW-via-$(gh_repo_current_rung)"
    prof UNVERIFIABLE "$(printf '%s' "$HRW" | tr -cd 'A-Za-z0-9._:-')" -; exit 75 ;;
esac
NOW=$(jq -r '.head.sha // empty' "$TMP" 2>/dev/null)
[ -n "$NOW" ] || { prof UNVERIFIABLE head-read-no-sha -; exit 75; }
if [ "$NOW" != "$HEAD" ]; then
  prof HEAD_MOVED head-moved -
  exit 0
fi

: > "$DEF"
MC_ONLY_PR="$SLUG#$NUM" MC_FANIN_SOLO_RUN=1 MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$DEF" \
  "$H/bin/merge-conductor.sh"
rc=$?

ROWF="$H/state/merge-conductor/pr-state.tsv"
ROW=$(awk -F'\t' -v k="${SLUG,,}#$NUM" 'tolower($1) == k { r = $0 } END { if (r != "") print r }' "$ROWF" 2>/dev/null)
STATE=$(printf '%s' "$ROW" | cut -f2)
REASON=$(printf '%s' "$ROW" | cut -f7 | awk '{ for (i = 1; i <= NF && i <= 4; i++) printf "%s%s", (i > 1 ? "-" : ""), $i }' \
  | tr -cd 'A-Za-z0-9._:-' | head -c 40)
DEFW=$(sort -u "$DEF" 2>/dev/null | tr -cd 'a-z\n' | grep . | paste -sd, -)
prof "${STATE:-NONE}" "${REASON:--}" "${DEFW:--}"
exit "$rc"
