#!/bin/bash
# bin/cost-prices-push.sh [--dry-run] — BH-9068: push each account's
# usd_per_month from catalog/cost-accounts.json into the settings row
# cost.usd_per_month.<account>. GET /api/metrics/cost-breakdown reads those rows
# for the CASH line on /costs (worker/jobs/src/routes/cost-breakdown.js).
#
# The value is the number as jq prints it, or "null" when the catalog holds
# null or no key: the reader shows that account as unknown, never as $0.
# A value that is not null and not a number >= 0 is refused for that account:
# nothing is written for it and the run exits 1.
#
# Run it on the hub after a price edit in the catalog. Each run PUTs every row
# (6 accounts today) through bin/jobs-client.sh setting_set.
#
#   --dry-run   print `<key> <value>` per account and write nothing
#
# Output: `cost-prices-push: accounts=<n> written=<w> refused=<r> failed=<f>`.
# rc 0 = every row written (or printed); 1 = a refused or failed row, or an
# unreadable catalog; 2 = usage.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="${HARNESS:-/root/harness}"
DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: cost-prices-push.sh [--dry-run]" >&2; exit 2 ;;
esac
CAT="$H/catalog/cost-accounts.json"
ROWS=$(jq -r '.accounts | to_entries[] | .key + "\t" + (.value.usd_per_month
  | if . == null then "null" elif type == "number" and . >= 0 then tostring else "BAD" end)' "$CAT" 2>/dev/null) \
  || { echo "cost-prices-push: cannot read .accounts from $CAT" >&2; exit 1; }
[ -n "$ROWS" ] || { echo "cost-prices-push: $CAT lists no account" >&2; exit 1; }
if [ "$DRY" = 0 ]; then
  # shellcheck source=bin/jobs-client.sh
  . "$HERE/jobs-client.sh" 2>/dev/null || { echo "cost-prices-push: bin/jobs-client.sh not loadable" >&2; exit 1; }
fi
N=0; W=0; R=0; F=0
while IFS=$'\t' read -r acct val; do
  N=$((N+1))
  key="cost.usd_per_month.$acct"
  if [ "$val" = BAD ] || ! [[ "$key" =~ ^[a-z0-9_.-]{1,64}$ ]]; then
    echo "cost-prices-push: refused $acct: usd_per_month must be null or a number >= 0, and the key must match ^[a-z0-9_.-]{1,64}\$" >&2
    R=$((R+1)); continue
  fi
  if [ "$DRY" = 1 ]; then printf '%s %s\n' "$key" "$val"; W=$((W+1)); continue; fi
  if setting_set "$key" "$val" "BH-9068: catalog/cost-accounts.json usd_per_month (null = not entered)"; then
    W=$((W+1))
  else
    echo "cost-prices-push: PUT $key failed" >&2; F=$((F+1))
  fi
done <<< "$ROWS"
echo "cost-prices-push: accounts=$N written=$W refused=$R failed=$F"
[ "$R" -eq 0 ] && [ "$F" -eq 0 ]
