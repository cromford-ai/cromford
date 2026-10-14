#!/bin/bash
# bin/ci-runners-status.sh — how many bh-ci runners are registered, and how many
# of them can take a job right now.
#
#   ci-runners-status.sh [--repo <owner/repo>] [--label <label>] [--json]
#
# WHY (BH-1206). Harness CI runs on the Fly `bh-ci` pool and has NO
# GitHub-hosted fallback by design: when the machines are down the jobs QUEUE
# rather than fail. That is the right failure — it is recoverable and it loses
# nothing — but it is also completely silent. A queued job looks exactly like a
# slow one, and the drain just stops merging. So the pool's own count has to be
# readable on demand and by the lane tick that reports it.
#
# WHAT IT READS. `GET /repos/<slug>/actions/runners` over REST — never GraphQL
# (the accounts here hit GraphQL rate limits that kill a session mid-run), and
# never a Fly-side machine list: a machine that is up with a runner that failed
# to register is exactly the outage this is for, and only GitHub knows.
#
# WHICH TOKEN. Through `gh_ci_api` (bin/lib/gh-ci-read.sh): the default token
# answers first and only a failure retries once with a read-only App token. The
# Actions endpoints have been 403 for some of our fine-grained PATs for months
# (the 2026-09-14 project-2 shape), and this endpoint additionally wants
# repo administration rights — so a single-credential read here would report
# "no runners" on a healthy pool, which is worse than reporting nothing.
#
# THREE OUTCOMES, NEVER TWO. "Zero runners" and "could not ask" must never be
# the same answer, because one of them pages someone and the other one is a
# broken token:
#   rc 0   at least one runner is ONLINE (idle or busy) — the pool can take work
#   rc 1   the pool answered and NO runner is online — this is the alert
#   rc 2   the read failed, or the answer did not parse — nothing is known
#
# Counting: `status` is online|offline and `busy` is a boolean, so an online
# runner is idle or busy and an offline one is neither. Only runners carrying
# the pool label are counted — a self-hosted runner registered for something
# else must not make an empty bh-ci pool look staffed.
set -uo pipefail

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
DIR=$(cd "$(dirname "$SELF")/.." && pwd)

# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$DIR/bin/lib/deployment.sh}" || exit 2  # BH-4080: HARNESS_REPO
SLUG="${CI_RUNNERS_SLUG:-$HARNESS_REPO}"
LABEL="${CI_RUNNERS_LABEL:-bh-ci}"
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  SLUG="${2:-}"; shift 2 || exit 2 ;;
    --label) LABEL="${2:-}"; shift 2 || exit 2 ;;
    --json)  JSON=1; shift ;;
    -h|--help)
      echo "usage: ci-runners-status.sh [--repo <owner/repo>] [--label <label>] [--json]" >&2
      exit 2 ;;
    *)
      echo "ci-runners-status: unknown argument '$1'" >&2
      echo "usage: ci-runners-status.sh [--repo <owner/repo>] [--label <label>] [--json]" >&2
      exit 2 ;;
  esac
done

case "$SLUG" in */*) ;; *) echo "ci-runners-status: --repo wants owner/repo, got '$SLUG'" >&2; exit 2 ;; esac
[ -n "$LABEL" ] || { echo "ci-runners-status: --label may not be empty" >&2; exit 2; }

# Without the lib this is the plain `gh api` every box has always run; with it,
# the App-token retry. Either way the call below is identical.
# The entry point owns the root default (BH-2613 rule 4): the libs below have none.
H="${HARNESS:-${H:-/root/harness}}"
# shellcheck source=lib/gh-ci-read.sh
if [ -r "$DIR/bin/lib/gh-ci-read.sh" ]; then . "$DIR/bin/lib/gh-ci-read.sh"
else gh_ci_api() { shift; gh api "$@"; }; fi

command -v jq >/dev/null 2>&1 || { echo "ci-runners-status: jq is not on PATH — cannot read the answer" >&2; exit 2; }

# PAGINATED, because the pool outgrew one page (BH-1206). This endpoint
# defaults to 30 per page and the fleet is past 70 registrations, so a single
# unpaginated read reports a THIRD of the pool and every count below it is
# wrong in the safe-looking direction — "plenty online" while the truth might
# be none. That is the failure this script exists to catch, so it must not be
# the failure this script has.
#
# An explicit page loop rather than `gh api --paginate`: --paginate emits one
# JSON document PER PAGE, concatenated, and the jq below expects a single
# object. A wrapper's extra flag is also the kind of thing that stops being
# passed when a caller changes; the loop is what it looks like.
PAGE=1
RUNNERS='[]'
TOTAL_COUNT=""
while :; do
  RAW=$(gh_ci_api "$SLUG" "repos/$SLUG/actions/runners?per_page=100&page=$PAGE" 2>&1)
  RC=$?
  if [ "$RC" != 0 ] || [ -z "$RAW" ]; then
    echo "ci-runners-status: could not read repos/$SLUG/actions/runners page $PAGE (rc=$RC)" >&2
    head -3 <<<"$RAW" >&2
    exit 2
  fi
  # Shape is checked per page, not once at the end: a 403 on page 2 must be
  # "nothing is known", never "the pool is however big page 1 said".
  PAGE_JSON=$(printf '%s' "$RAW" | jq -c '
    if (type != "object") or (has("runners") | not) or (.runners | type != "array")
    then "BADSHAPE" else {t: (.total_count // -1), r: .runners} end' 2>/dev/null)
  if [ -z "$PAGE_JSON" ] || [ "$PAGE_JSON" = '"BADSHAPE"' ]; then
    echo "ci-runners-status: repos/$SLUG/actions/runners page $PAGE did not answer with a runner list" >&2
    head -3 <<<"$RAW" >&2
    exit 2
  fi
  [ -n "$TOTAL_COUNT" ] || TOTAL_COUNT=$(printf '%s' "$PAGE_JSON" | jq -r '.t')
  RUNNERS=$(printf '%s\n%s' "$RUNNERS" "$PAGE_JSON" | jq -c -s '.[0] + .[1].r')
  GOT=$(printf '%s' "$PAGE_JSON" | jq -r '.r | length')
  HAVE=$(printf '%s' "$RUNNERS" | jq -r 'length')
  # Stop on a short page — the last one always is, including a first page that
  # is the only one. The page cap is a runaway guard, not a limit anyone should
  # reach: 100 pages is 10,000 runners.
  [ "$GOT" -lt 100 ] && break
  [ -n "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -ge 0 ] && [ "$HAVE" -ge "$TOTAL_COUNT" ] && break
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt 100 ]; then
    echo "ci-runners-status: stopped after 100 pages — the endpoint is not terminating" >&2
    exit 2
  fi
done

# The pages must add up to what the endpoint said it had. A silent short read
# (a dropped page, a wrapper that swallowed one) is exactly the wrong-in-the-
# safe-direction answer this loop exists to prevent, so it is rc 2.
HAVE=$(printf '%s' "$RUNNERS" | jq -r 'length')
if [ -n "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -ge 0 ] && [ "$HAVE" -lt "$TOTAL_COUNT" ]; then
  echo "ci-runners-status: read $HAVE of $TOTAL_COUNT registered runners — the listing is short, so nothing is known" >&2
  exit 2
fi
RAW=$(printf '%s' "$RUNNERS" | jq -c '{runners: .}')

# A body that is not the shape we expect is rc 2, not "0 runners": an error
# object parses as valid JSON and would otherwise read as an empty pool.
COUNTS=$(printf '%s' "$RAW" | jq -r --arg label "$LABEL" '
  if (type != "object") or (has("runners") | not) or (.runners | type != "array")
  then "BADSHAPE"
  else
    [ .runners[] | select([.labels[]?.name] | index($label)) ] as $pool
    | [ ($pool | length),
        ($pool | map(select(.status == "online" and (.busy | not))) | length),
        ($pool | map(select(.status == "online" and .busy)) | length),
        ($pool | map(select(.status != "online")) | length) ]
    | @tsv
  end' 2>/dev/null)

if [ -z "$COUNTS" ] || [ "$COUNTS" = BADSHAPE ]; then
  echo "ci-runners-status: repos/$SLUG/actions/runners did not answer with a runner list" >&2
  head -3 <<<"$RAW" >&2
  exit 2
fi

IFS=$'\t' read -r TOTAL IDLE BUSY OFFLINE <<< "$COUNTS"
ONLINE=$((IDLE + BUSY))

if [ "$JSON" = 1 ]; then
  printf '{"repo":"%s","label":"%s","total":%s,"online":%s,"idle":%s,"busy":%s,"offline":%s}\n' \
    "$SLUG" "$LABEL" "$TOTAL" "$ONLINE" "$IDLE" "$BUSY" "$OFFLINE"
else
  echo "ci-runners-status $SLUG label=$LABEL: $TOTAL registered — $ONLINE online ($IDLE idle, $BUSY busy), $OFFLINE offline"
  printf '%s' "$RAW" | jq -r --arg label "$LABEL" '
    .runners[] | select([.labels[]?.name] | index($label))
    | [ .name, .status, (if .busy then "busy" else "idle" end) ] | @tsv' 2>/dev/null \
    | LC_ALL=C sort | awk -F'\t' '{printf "  %-28s %-8s %s\n", $1, $2, $3}'
fi

if [ "$ONLINE" -eq 0 ]; then
  echo "ci-runners-status: NO online $LABEL runner on $SLUG — Harness CI jobs will queue, not fail." >&2
  exit 1
fi
exit 0
