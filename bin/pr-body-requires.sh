#!/bin/bash
# bin/pr-body-requires.sh check --plan <file> (--body <file> | --pr <owner/repo>#<n>)
#   BH-7378: list each item of the plan's fenced ```pr-body-requires block that
#   the PR body lacks (bin/lib/pr-body-requires.sh has the format), one line each:
#     [NOTE] PR body lacks <item> (required by <source>)
#   10 lines at most, then one `[NOTE] PR body lacks <n> more required items`
#   line. --pr reads the live body with ONE gh_rest GET (bin/lib/gh-rest.sh,
#   REST only). A rate-limited read (rc 75) prints one
#   `[NOTE] not verified here: PR body read rate-limited` line, any other failed
#   read one `... read failed (rc <n>)` line, and no item is called missing.
#   No plan file or no block: no output, and no read.
#   Exit 0 on every one of these paths; exit 2 only for a usage error.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/pr-body-requires.sh
. "$SELF_DIR/lib/pr-body-requires.sh" || { echo "pr-body-requires: bin/lib/pr-body-requires.sh missing" >&2; exit 2; }
usage() { echo "usage: bin/pr-body-requires.sh check --plan <file> (--body <file> | --pr <owner/repo>#<n>)" >&2; exit 2; }
[ "${1:-}" = check ] || usage
shift
PLAN=""; BODY=""; PR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="${2:-}"; shift ;;
    --body) BODY="${2:-}"; shift ;;
    --pr) PR="${2:-}"; shift ;;
    *) echo "pr-body-requires: unknown argument $1" >&2; usage ;;
  esac
  shift
done
[ -n "$PLAN" ] || usage
{ [ -n "$BODY" ] && [ -z "$PR" ]; } || { [ -z "$BODY" ] && [ -n "$PR" ]; } || usage
if [ -n "$PR" ]; then
  [[ "$PR" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]] || usage
  SLUG="${BASH_REMATCH[1]}"; NUM="${BASH_REMATCH[2]}"
fi
[ -n "$(pbr_items "$PLAN")" ] || exit 0

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pbr-cli.XXXXXX") || { echo "[NOTE] not verified here: no temp directory for the PR body"; exit 0; }
trap 'rm -rf "$TMPD"' EXIT
if [ -n "$PR" ]; then
  # shellcheck source=bin/lib/gh-rest.sh
  command -v gh_rest >/dev/null 2>&1 || . "$SELF_DIR/lib/gh-rest.sh" 2>/dev/null
  command -v gh_rest >/dev/null 2>&1 || { echo "[NOTE] not verified here: PR body read failed (bin/lib/gh-rest.sh missing)"; exit 0; }
  grc=0; gh_rest GET "repos/$SLUG/pulls/$NUM" > "$TMPD/pr.json" 2>/dev/null || grc=$?
  if [ "$grc" = 75 ]; then echo "[NOTE] not verified here: PR body read rate-limited"; exit 0; fi
  if [ "$grc" != 0 ]; then echo "[NOTE] not verified here: PR body read failed (rc $grc)"; exit 0; fi
  jrc=0; jq -r '.body // ""' "$TMPD/pr.json" > "$TMPD/body.md" 2>/dev/null || jrc=$?
  if [ "$jrc" != 0 ]; then echo "[NOTE] not verified here: PR body read failed (rc $jrc)"; exit 0; fi
  BODY="$TMPD/body.md"
fi
mrc=0; MISS=$(pbr_missing "$PLAN" "$BODY") || mrc=$?
if [ "$mrc" != 0 ]; then echo "[NOTE] not verified here: PR body read failed ($BODY will not read)"; exit 0; fi
n=0
while IFS=$'\t' read -r item src; do
  [ -n "$item" ] || continue
  n=$((n + 1))
  [ "$n" -le 10 ] && echo "[NOTE] PR body lacks $item (required by $src)"
done <<<"$MISS"
[ "$n" -gt 10 ] && echo "[NOTE] PR body lacks $((n - 10)) more required items (see the plan's pr-body-requires block)"
exit 0
