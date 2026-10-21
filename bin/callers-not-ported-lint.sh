#!/bin/bash
# bin/callers-not-ported-lint.sh --base <ref> [--head <ref>] [--repo <dir>]
#   BH-7815: list each place the merge of <base> and <head> (default HEAD, in
#   <dir>, default .) still names a path the head deletes or renames
#   (bin/lib/callers-not-ported.sh has the rule), one line each:
#     [NOTE] callers-not-ported: <file>:<line> still references <old>, which this
#     PR deletes or renames; port it after you merge main.[ (<file> was added by <sha12>, not in this PR's diff)]
#   20 lines at most, then `[NOTE] callers-not-ported: and <n> more`. A step
#   that cannot run prints `[NOTE] callers-not-ported: could not run: <why>`.
#   Exit 0 in every case, a usage error included (the usage goes to stderr):
#   this lint never stops a build or a merge.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/callers-not-ported.sh
. "$SELF_DIR/lib/callers-not-ported.sh" || { echo "callers-not-ported: bin/lib/callers-not-ported.sh missing" >&2; exit 0; }
usage() { echo "usage: bin/callers-not-ported-lint.sh --base <ref> [--head <ref>] [--repo <dir>]" >&2; exit 0; }
BASE=""; HEAD_REF="HEAD"; REPO="."
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift ;;
    --head) HEAD_REF="${2:-}"; shift ;;
    --repo) REPO="${2:-}"; shift ;;
    *) echo "callers-not-ported: unknown argument $1" >&2; usage ;;
  esac
  shift
done
[ -n "$BASE" ] && [ -n "$HEAD_REF" ] && [ -n "$REPO" ] || usage
while IFS= read -r l; do
  [ -n "$l" ] && printf '[NOTE] callers-not-ported: %s\n' "$l"
done < <(cnp_scan "$REPO" "$BASE" "$HEAD_REF")
exit 0
