#!/bin/bash
# bin/migration-number.sh — BH-7325: the next numbered migration of a project,
# and its reservation. The rules are in bin/lib/migration-number.sh.
#
#   bin/migration-number.sh floor <project> [--repo <dir>] [--ref <ref>]
#       prints 1 + the highest NNNN on <ref> (default origin/main) and in the
#       files the open PRs add; one detail line on stderr. rc 1 when the
#       project has no migrations_glob.<project> row.
#   bin/migration-number.sh reserve <project> <key> [--repo <dir>] [--ref <ref>] [--floor <n>]
#       reserves a number for <key> (one row per key; a second migration of one
#       ticket uses <KEY>.2). Prints `<n> reserved|reused`, or `<floor> unreserved`
#       and rc 1 when the worker did not answer.
#   bin/migration-number.sh taken [--repo <dir>] [--base <ref>] [--head <ref>] [--project <p>]
#       the numbered files the diff base...head adds that main or another open PR
#       already holds, one `NNNN<TAB>taken by ...` line each (a `note: ...` line
#       when this PR keeps the number: it holds the reservation, or it is the
#       older PR). rc 0 none, 1 some, 2 the open PRs were not read whole
#       (nothing found in what was read) or the settings read failed.
# --repo defaults to the current directory. The project of `taken` defaults to
# the fleet.conf row whose column 2 is the origin slug.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/jobs-client.sh
. "$SELF_DIR/jobs-client.sh" >/dev/null 2>&1 || :
# shellcheck source=bin/lib/gh-rest.sh
. "$SELF_DIR/lib/gh-rest.sh" 2>/dev/null || :
# shellcheck source=bin/lib/migration-number.sh
. "$SELF_DIR/lib/migration-number.sh" || { echo "migration-number: bin/lib/migration-number.sh missing" >&2; exit 2; }

usage() { echo "usage: bin/migration-number.sh floor <project> | reserve <project> <key> | taken  [--repo <dir>] [--ref|--base|--head <ref>] [--floor <n>] [--project <p>]" >&2; exit 2; }
VERB="${1:-}"; shift || usage
POS=(); REPO="."; REF="origin/main"; BASE="origin/main"; HEADREF="HEAD"; FLOOR=""; PROJ=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift ;;
    --ref) REF="${2:-}"; shift ;;
    --base) BASE="${2:-}"; shift ;;
    --head) HEADREF="${2:-}"; shift ;;
    --floor) FLOOR="${2:-}"; shift ;;
    --project) PROJ="${2:-}"; shift ;;
    --*) usage ;;
    *) POS+=("$1") ;;
  esac
  shift
done
[ -d "$REPO" ] || { echo "migration-number: no repo $REPO" >&2; exit 2; }

case "$VERB" in
  floor|reserve)
    P="${POS[0]:-}"; [ -n "$P" ] || usage
    if [ "$VERB" = reserve ]; then K="${POS[1]:-}"; [ -n "$K" ] || usage; fi
    mn_dir "$P" >/dev/null; DIR=$MN_DIR
    if [ -z "$DIR" ] && mn_dir_unread; then echo "migration-number: migrations_glob.$P could not be read ($MN_DIR_SRC)" >&2; exit 2; fi
    [ -n "$DIR" ] || { echo "migration-number: $P has no migrations_glob.$P row" >&2; exit 1; }
    if [ -z "$FLOOR" ]; then
      mn_floor "$REPO" "$REF" "$DIR" "$(mn_slug "$REPO" "$P")" >/dev/null
      echo "migration-number: $P floor=$MN_FLOOR main_max=$MN_MAIN_MAX pr_max=$MN_PR_MAX prs_read=$MN_PRS_READ incomplete=${MN_INCOMPLETE:-no}" >&2
      FLOOR=$MN_FLOOR
    fi
    [[ "$FLOOR" =~ ^[0-9]{1,6}$ ]] || usage
    if [ "$VERB" = floor ]; then printf '%04d\n' $((10#$FLOOR)); exit 0; fi
    if mn_reserve "$P" "$K" "$FLOOR" >/dev/null; then echo "$MN_NUMBER $MN_RESERVED"; exit 0; fi
    printf '%04d unreserved\n' $((10#$FLOOR)); exit 1 ;;
  taken)
    SLUG=$(mn_slug "$REPO")
    [ -n "$PROJ" ] || PROJ=$(mn_project_of "$SLUG")
    [ -n "$PROJ" ] || { echo "migration-number: no fleet.conf project for ${SLUG:-this repo}" >&2; exit 0; }
    mn_dir "$PROJ" >/dev/null; DIR=$MN_DIR
    if [ -z "$DIR" ] && mn_dir_unread; then echo "migration-number: migrations_glob.$PROJ could not be read ($MN_DIR_SRC), numbers not checked" >&2; exit 2; fi
    [ -n "$DIR" ] || exit 0
    mn_taken "$REPO" "$BASE" "$HEADREF" "$SLUG" "$DIR" "$PROJ"; RC=$?
    [ -z "$MN_INCOMPLETE" ] || echo "migration-number: open PRs not read whole ($MN_INCOMPLETE)" >&2
    exit "$RC" ;;
  *) usage ;;
esac
