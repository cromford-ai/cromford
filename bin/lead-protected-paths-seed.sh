#!/bin/bash
# lead-protected-paths-seed.sh — seed of the jobs worker's
# lead_protected_paths rows from catalog/lead-protected-paths.seed.tsv (BH-4146,
# BH-4140.1). Since BH-4148 the rows are the source of truth; until a seed
# glob has a row, bin/lib/lead-authority.sh still protects it (the seed floor),
# so this is what turns that floor into rows the console can edit. Run it once
# on the hub; a re-run re-adds a glob the console removed, so don't loop it.
#
# Usage: bin/lead-protected-paths-seed.sh [--tsv <path>]
#        bin/lead-protected-paths-seed.sh -h
#
# Each `<owner/repo><TAB><glob>` line becomes one
#   PUT /api/lead-protected-paths {repo, glob, op:"add", added_by=seed:BH-4140}
# through bin/jobs-client.sh (JOBS_URL + HARNESS_SECRET). A 201 counts as
# added and a 200 as already live; anything else (4xx, 5xx, no answer) counts
# as failed and is named on stderr as `<glob> http=<code>`. Every line is sent
# even after a failure, then one line is printed:
#   added N, already M[, failed K]
# The PUT is idempotent, so a re-run prints `added 0, already <all>`.
#
# Exit: 0 every line added or already live; 1 any failed PUT, or a TSV that is
# missing, malformed or holds no globs (refused before any request); 2 JOBS_URL
# is not configured (nothing sent).
set -uo pipefail

usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

TSV="$(dirname "$0")/../catalog/lead-protected-paths.seed.tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tsv) [ $# -ge 2 ] || { echo "lead-protected-paths-seed: --tsv needs a path" >&2; exit 1; }; TSV="$2"; shift 2 ;;
    *) echo "lead-protected-paths-seed: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" || { echo "lead-protected-paths-seed: bin/jobs-client.sh did not load" >&2; exit 1; }
jobs_configured || { echo "lead-protected-paths-seed: JOBS_URL is not configured: nothing sent" >&2; exit 2; }

[ -r "$TSV" ] || { echo "lead-protected-paths-seed: cannot read $TSV" >&2; exit 1; }

# Validate the whole file before the first PUT: a half-seeded table from a
# file that turns out to be broken on line 20 is worse than no seed.
LINES=$(grep -v '^#' "$TSV" | grep -v '^[[:space:]]*$')
[ -n "$LINES" ] || { echo "lead-protected-paths-seed: $TSV holds no globs: nothing sent" >&2; exit 1; }
BADLINE=$(printf '%s\n' "$LINES" | awk -F'\t' 'NF != 2 || $1 == "" || $2 == "" { print; exit }')
[ -z "$BADLINE" ] || { echo "lead-protected-paths-seed: malformed line (want repo<TAB>glob): $BADLINE" >&2; exit 1; }

added=0; already=0; failed=0
while IFS="$(printf '\t')" read -r repo glob; do
  body=$(python3 -c 'import json,sys; print(json.dumps({"repo": sys.argv[1], "glob": sys.argv[2], "op": "add", "added_by": "seed:BH-4140"}))' "$repo" "$glob") \
    || { failed=$((failed+1)); echo "$glob http=encode-failed" >&2; continue; }
  _jobs_req PUT /api/lead-protected-paths "$body" >/dev/null
  case "$JOBS_HTTP" in
    201) added=$((added+1)) ;;
    200) already=$((already+1)) ;;
    *)   failed=$((failed+1)); echo "$glob http=${JOBS_HTTP:-none}" >&2 ;;
  esac
done <<EOF
$LINES
EOF

if [ "$failed" -gt 0 ]; then
  echo "added $added, already $already, failed $failed"
  exit 1
fi
echo "added $added, already $already"
