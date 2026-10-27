#!/bin/bash
# bin/hotfix-seen.sh <project> [--paused] — say once, out loud, that an
# emergency ticket exists.
#
# WHY (#368, hotfix lane 1/3). The rest of this lane makes a `hotfix` issue
# plan first, build first and exceed a cap by one, and every bit of that is
# invisible: the only difference a human sees is that the PR arrives sooner.
# The point of an emergency label is that somebody is waiting on it, so the
# fleet says so the moment it can — first seen here, PR open and merged from
# bin/run-build.sh, all three through the one channel
# bin/lib/hotfix-lib.sh:hotfix_announce owns.
#
# ONCE PER ISSUE, FOR LIFE. The marker under state/hotfix-announced/ is what
# makes a */10 cron tick safe to hook this to: the first tick after the label
# goes on announces, and every tick after it is silent.
#
# --paused: the project's triage tick is standing down on its paused-<p> flag. A
# pause is a HUMAN decision and #368 puts overriding it explicitly out of
# scope — so this writes one line per tick to the project log saying the
# hotfix is waiting on it, and beats NOTHING. Paging every ten minutes about a
# pause somebody set on purpose is how an alert channel stops being read.
#
# GitHub-Issues lanes, plus Jira and Linear through the tracker contract
# (BH-8451). Deterministic, no model call, FAIL-OPEN EVERYWHERE:
# any failure exits 0 having said nothing. This is an announcement, never a
# tick killer.
#
# gh-rest: no-graphql
#
set -uo pipefail
PROJECT="${1:?usage: hotfix-seen.sh <project> [--paused]}"
MODE="${2:-}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/hotfix-lib.sh
[ -r "$HERE/lib/hotfix-lib.sh" ] && . "$HERE/lib/hotfix-lib.sh" 2>/dev/null
command -v hotfix_lane_on >/dev/null 2>&1 || exit 0
[ "$(hotfix_lane_on "$HARNESS")" = 1 ] || exit 0
# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh" 2>/dev/null

LOGF="$HARNESS/logs/$PROJECT.log"
unverifiable() {
  mkdir -p "$HARNESS/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] hotfix listing UNVERIFIABLE ($1) — nothing announced this tick, re-read next pass" \
    >> "$LOGF" 2>/dev/null
}
LBL=$(hotfix_label "$HARNESS")

# JIRA AND LINEAR (BH-8451). Column 4 says `-` for them too, so the GitHub read
# below would announce the code repo's issues. They list the open tickets
# that carry BOTH ai-build and hotfix through the tracker contract
# (bin/lib/trk-lane.sh: a --label flag is an AND with the build label),
# and the announce names the tracker's own key (CRO-12). An absent lib, or any
# other kind, is today's path.
TRK_LANE_KIND=""
# shellcheck source=bin/lib/trk-lane.sh
[ -r "$HERE/lib/trk-lane.sh" ] && . "$HERE/lib/trk-lane.sh" 2>/dev/null && trk_lane_kind "$HARNESS" "$PROJECT"
ROWS=""
case "$TRK_LANE_KIND" in
  jira|linear)
    command -v jq >/dev/null 2>&1 || exit 0
    if ! TL=$(trk_lane_list "$HARNESS" "$PROJECT" hotfix-seen --state open --label "$LBL" 2>/dev/null); then
      unverifiable "$TRK_LANE_KIND list"
      exit 0
    fi
    ROWS=$(printf '%s' "$TL" | jq -r '.[] | select(type=="object") | select((.key // "") != "") | "\(.key)\t\(.title // "")"' 2>/dev/null) || exit 0
    ;;
  *)
BP=$("$HERE/fleet-conf.sh" "$PROJECT" board_prefix 2>/dev/null || true)
[ "$BP" = "-" ] || exit 0
REPO="${GH_ISSUES_REPO:-$("$HERE/fleet-conf.sh" "$PROJECT" repo 2>/dev/null || true)}"
[ -n "$REPO" ] || exit 0
command -v preplan_key_prefix >/dev/null 2>&1 || exit 0
PFX=$(preplan_key_prefix "$HARNESS" "$PROJECT" 2>/dev/null) || exit 0
[ -n "$PFX" ] || exit 0

# A COMMA LIST IS GITHUB'S AND, which is the prime rule of this lane: a
# `hotfix` label on an issue without `ai-build` is invisible everywhere, because
# every listing in the fleet filters on ai-build. Same semantics the two
# `--label` flags had; REST instead of GraphQL (#768), so a refused listing is
# an honest non-zero rather than an empty string that reads like "none".
# shellcheck source=bin/lib/gh-rest.sh
# BH-1485: the guard probes the name this lane CALLS (`gh_rest_var`), not the
# one it used to — a guard that found the old name would skip the source and
# die on the variant two lines later.
command -v gh_rest_var >/dev/null 2>&1 || { [ -r "$HERE/lib/gh-rest.sh" ] && . "$HERE/lib/gh-rest.sh"; }
command -v gh_rest_var >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
# BH-1485: `gh_rest_var`, never `ISSUES=$(gh_rest GET …)`. The capture was a
# subshell, so a refused listing left this lane exiting 0 with GH_REST_STATUS
# still 000 in the shell that would have named it — a rate-limited tick and a
# genuinely empty board were the same silence.
ISSUES=""
if ! gh_rest_var ISSUES GET "repos/$REPO/issues" -f "labels=ai-build,$LBL" -f state=open -F per_page=50; then
  unverifiable "HTTP ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"
  exit 0
fi
[ -n "$ISSUES" ] || exit 0
# `select(.pull_request == null)` is REQUIRED: the /issues collection returns
# PULL REQUESTS too and `gh issue list` did not, so without it a labelled PR
# would be announced as a hotfix ticket.
ROWS=$(printf '%s' "$ISSUES" | jq -r --arg p "$PFX" '.[] | select(type=="object") | select(.pull_request == null) | "\($p)-\(.number)\t\(.title // "")"' 2>/dev/null)
    ;;
esac

while IFS=$'\t' read -r KEY TITLE; do
  [ -n "${KEY:-}" ] || continue
  if [ "$MODE" = "--paused" ]; then
    mkdir -p "$HARNESS/logs" 2>/dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$PROJECT] hotfix $KEY is waiting on flags/paused-$PROJECT (a pause is a human decision; not overridden)" \
      >> "$LOGF" 2>/dev/null
  else
    hotfix_announce "$HARNESS" "$PROJECT" "$KEY" seen "$KEY — $TITLE"
  fi
done <<<"$ROWS"
exit 0
