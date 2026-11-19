#!/bin/bash
# bin/discovery-setup.sh — BH-9795: switch the discovery-daily lane on for a
# project. It writes the per-project settings rows
# lane.discovery-daily.<project>.<knob> through bin/harness-ctl.sh set (its
# settable, range and fleet.conf checks) and prints what it wrote. A second run
# with the same input writes nothing.
#
#   discovery-setup.sh --project <p> --sources <csv> [--sentry-project <slug>]
#                      [--sentry-org <slug>] [--repo <owner/repo>]
#
# Validation, before any read or write: the project is a fleet.conf name; each
# source has an adapter bin/lib/discovery/<source>.sh; the Sentry project slug
# and the Sentry org slug (BH-9820, knob DISCOVERY_SENTRY_ORG) each match
# ^[a-z0-9_-]+$; the repo matches ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ and is a
# fleet.conf repo (column 2). Any miss: rc 2, nothing written. With no --repo,
# tickets go to the project's fleet.conf repo (DISCOVERY_TARGET_REPO empty).
# Then each given knob is read with setting_get. Equal: `unchanged <key>=<v>`.
# Else: harness-ctl.sh set, then `set <key>=<v>`. A settings read that does not
# answer: rc 1, and nothing is written (every read runs before the first write).
# The since row (BH-9820): the jobs ledger row discovery-daily-since/<project>
# is read with the knobs. Absent: it is written {since: <today, UTC>} after the
# knobs, and the missed-run check (bin/lib/discovery-missed.sh) alerts from the
# day after the setup. Present: `since ... kept`, never rewritten. A read that does
# not answer: rc 1, nothing written.
# The cron line is NOT written here: it lives in cron/lanes/782-discovery-daily.cron.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: discovery-setup.sh --project <p> --sources <csv> [--sentry-project <slug>] [--sentry-org <slug>] [--repo <owner/repo>]" >&2; exit 2; }
P=""; SOURCES=""; SLUG=""; ORG=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; P=$2; shift 2 ;;
    --sources) [ $# -ge 2 ] || usage; SOURCES=$2; shift 2 ;;
    --sentry-project) [ $# -ge 2 ] || usage; SLUG=$2; shift 2 ;;
    --sentry-org) [ $# -ge 2 ] || usage; ORG=$2; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$P" ] && [ -n "$SOURCES" ] || usage
FC="${FLEET_CONF:-$H/fleet.conf}"
[[ $P =~ ^[a-z0-9-]+$ ]] && awk -v p="$P" 'NF && $1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$FC" 2>/dev/null \
  || { echo "discovery-setup: no project '$P' in $FC; nothing written" >&2; exit 2; }
IFS=',' read -r -a SRCS <<<"$SOURCES"
[ "${#SRCS[@]}" -gt 0 ] || usage
for s in "${SRCS[@]}"; do
  if ! [[ $s =~ ^[a-z0-9-]+$ ]] || [ ! -r "$SELF/lib/discovery/$s.sh" ]; then
    echo "discovery-setup: source '$s' has no adapter bin/lib/discovery/$s.sh; nothing written" >&2; exit 2
  fi
done
if [ -n "$SLUG" ] && ! [[ $SLUG =~ ^[a-z0-9_-]+$ ]]; then
  echo "discovery-setup: Sentry project slug '$SLUG' is not ^[a-z0-9_-]+\$; nothing written" >&2; exit 2
fi
if [ -n "$ORG" ] && ! [[ $ORG =~ ^[a-z0-9_-]+$ ]]; then
  echo "discovery-setup: Sentry org slug '$ORG' is not ^[a-z0-9_-]+\$; nothing written" >&2; exit 2
fi
if [ -n "$REPO" ] && { ! [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] \
     || ! awk -v r="$REPO" 'NF && $1 !~ /^#/ && $2 == r {f=1} END {exit !f}' "$FC" 2>/dev/null; }; then
  echo "discovery-setup: repo '$REPO' is not an owner/repo that $FC names; nothing written" >&2; exit 2
fi

# shellcheck disable=SC1091
. "$SELF/jobs-client.sh" 2>/dev/null || true
# The suite's seam. Sandbox only, and settable:false in the registry.
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${DISCOVERY_DAILY_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$DISCOVERY_DAILY_FIXTURE"
fi
for fn in setting_get job_ledger_row job_ledger_put jq; do
  command -v "$fn" >/dev/null 2>&1 || { echo "discovery-setup: $fn missing (bin/jobs-client.sh)" >&2; exit 1; }
done
NOW_S=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${DISCOVERY_DAILY_NOW:-} =~ ^[0-9]+$ ]]; then NOW_S=$DISCOVERY_DAILY_NOW; fi
[ -n "$NOW_S" ] || NOW_S=$(date -u +%s)
DAY=$(date -u -d "@$NOW_S" +%F) || { echo "discovery-setup: date -d failed; nothing written" >&2; exit 1; }

# Every read first: the knobs to write, in a fixed order.
ENVS=(DISCOVERY_SOURCES); VALS=("$SOURCES")
[ -n "$SLUG" ] && { ENVS+=(DISCOVERY_SENTRY_PROJ); VALS+=("$SLUG"); }
[ -n "$ORG" ] && { ENVS+=(DISCOVERY_SENTRY_ORG); VALS+=("$ORG"); }
[ -n "$REPO" ] && { ENVS+=(DISCOVERY_TARGET_REPO); VALS+=("$REPO"); }
declare -a KEYS CUR
for i in "${!ENVS[@]}"; do
  KEYS[i]=$(printf 'lane.discovery-daily.%s.%s' "$P" "${ENVS[i]}" | tr '[:upper:]' '[:lower:]')
  rc=0; CUR[i]=$(setting_get "${KEYS[i]}") || rc=$?
  case "$rc" in
    0) ;;
    2) CUR[i]="" ;;
    *) echo "discovery-setup: the settings read of ${KEYS[i]} did not answer (rc $rc); nothing written" >&2; exit 1 ;;
  esac
done
rc=0; job_ledger_row discovery-daily-since "$P" >/dev/null || rc=$?
case "$rc" in
  0) SINCE_NEW=0 ;;
  2) SINCE_NEW=1 ;;
  *) echo "discovery-setup: the ledger read of discovery-daily-since/$P did not answer (rc $rc); nothing written" >&2; exit 1 ;;
esac
for i in "${!ENVS[@]}"; do
  if [ "${CUR[i]}" = "${VALS[i]}" ]; then
    echo "unchanged ${KEYS[i]}=${VALS[i]}"
  else
    "$H/bin/harness-ctl.sh" set discovery-daily "${ENVS[i]}" "${VALS[i]}" "$P" >/dev/null \
      || { echo "discovery-setup: harness-ctl.sh set ${ENVS[i]} failed for $P" >&2; exit 1; }
    echo "set ${KEYS[i]}=${VALS[i]}"
  fi
done
if [ "$SINCE_NEW" = 1 ]; then
  job_ledger_put discovery-daily-since "$P" active "$(jq -nc --arg d "$DAY" '{since: $d}')" \
    || { echo "discovery-setup: ledger put discovery-daily-since/$P failed" >&2; exit 1; }
  echo "since discovery-daily-since/$P=$DAY (written)"
else
  echo "since discovery-daily-since/$P kept (not rewritten)"
fi
echo "note: the daily cron line lives in cron/lanes/782-discovery-daily.cron; add a line for $P there if it is not in it."
