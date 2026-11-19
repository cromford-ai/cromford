#!/bin/bash
# bin/discovery-setup.sh — BH-9795: switch the discovery-daily lane on for a
# project. It writes the per-project settings rows
# lane.discovery-daily.<project>.<knob> through bin/harness-ctl.sh set (its
# settable, range and fleet.conf checks) and prints what it wrote. A second run
# with the same input writes nothing.
#
#   discovery-setup.sh --project <p> --sources <csv> [--sentry-project <slug>] [--repo <owner/repo>]
#
# Validation, before any read or write: the project is a fleet.conf name; each
# source has an adapter bin/lib/discovery/<source>.sh; the slug matches
# ^[a-z0-9_-]+$; the repo matches ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ and is a
# fleet.conf repo (column 2). Any miss: rc 2, nothing written. With no --repo,
# tickets go to the project's fleet.conf repo (DISCOVERY_TARGET_REPO empty).
# Then each given knob is read with setting_get. Equal: `unchanged <key>=<v>`.
# Else: harness-ctl.sh set, then `set <key>=<v>`. A settings read that does not
# answer: rc 1, and nothing is written (every read runs before the first write).
# The cron line is NOT written here: it lives in cron/lanes/782-discovery-daily.cron.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"

usage() { echo "usage: discovery-setup.sh --project <p> --sources <csv> [--sentry-project <slug>] [--repo <owner/repo>]" >&2; exit 2; }
P=""; SOURCES=""; SLUG=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; P=$2; shift 2 ;;
    --sources) [ $# -ge 2 ] || usage; SOURCES=$2; shift 2 ;;
    --sentry-project) [ $# -ge 2 ] || usage; SLUG=$2; shift 2 ;;
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
command -v setting_get >/dev/null 2>&1 || { echo "discovery-setup: setting_get missing (bin/jobs-client.sh)" >&2; exit 1; }

# Every read first: the knobs to write, in a fixed order.
ENVS=(DISCOVERY_SOURCES); VALS=("$SOURCES")
[ -n "$SLUG" ] && { ENVS+=(DISCOVERY_SENTRY_PROJ); VALS+=("$SLUG"); }
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
for i in "${!ENVS[@]}"; do
  if [ "${CUR[i]}" = "${VALS[i]}" ]; then
    echo "unchanged ${KEYS[i]}=${VALS[i]}"
  else
    "$H/bin/harness-ctl.sh" set discovery-daily "${ENVS[i]}" "${VALS[i]}" "$P" >/dev/null \
      || { echo "discovery-setup: harness-ctl.sh set ${ENVS[i]} failed for $P" >&2; exit 1; }
    echo "set ${KEYS[i]}=${VALS[i]}"
  fi
done
echo "note: the daily cron line lives in cron/lanes/782-discovery-daily.cron; add a line for $P there if it is not in it."
