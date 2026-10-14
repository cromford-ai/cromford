#!/bin/bash
# bin/pr-self-check.sh check --repo <dir> --base <ref> --head <sha> --body <file>
#                            [--ticket <file>] [--only <ERE on the rule id>]
#                            [--key <KEY>]
#   BH-5798: the pre-review self-check (bin/lib/pr-self-check.sh). Prints one
#   line per finding; exit 0 nothing refused, 1 refused, 2 could not run.
#   The rules are catalog/pr-self-check.tsv (PR_SELF_CHECK_CATALOG overrides).
#   --key is the PR's own ticket key (PSC_PR_KEY) for the test-ownership and
#   foreign-commits rules; without it they read the key from the body or the
#   spec path.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/pr-self-check.sh
. "$SELF_DIR/lib/pr-self-check.sh" || { echo "pr-self-check: bin/lib/pr-self-check.sh missing" >&2; exit 2; }
[ "${1:-}" = check ] || { echo "usage: bin/pr-self-check.sh check --repo <dir> --base <ref> --head <sha> --body <file>" >&2; exit 2; }
shift
REPO="."; BASE="origin/main"; HEAD_SHA="HEAD"; BODY=""; TICKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift ;;
    --base) BASE="${2:-}"; shift ;;
    --head) HEAD_SHA="${2:-}"; shift ;;
    --body) BODY="${2:-}"; shift ;;
    --ticket) TICKET="${2:-}"; shift ;;
    --only) export PR_SELF_CHECK_ONLY="${2:-}"; shift ;;
    --key) export PSC_PR_KEY="${2:-}"; shift ;;
    *) echo "pr-self-check: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
psc_check "$REPO" "$BASE" "$HEAD_SHA" "$BODY" "$TICKET"
