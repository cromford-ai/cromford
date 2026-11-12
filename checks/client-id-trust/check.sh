#!/bin/bash
# checks/client-id-trust/check.sh
#
# FAMILY fd7bbe69fac5 — "Unsafe trust of client-supplied ids", 7 recurrences in
# 30 days across project-4, project-1, pool-project-4 and pool-project-2.
#
# WHAT IT CATCHES. An added data-access call in a request-handling file whose
# `where` clause is keyed on an id and NOTHING ELSE — no owner, tenant, org or
# membership column. That is the shape where swapping the id in the URL hands
# you someone else's row, and it is the security finding our reviewers have
# written by hand seven times.
#
# EXCLUSIONS. checks/client-id-trust/exclusions.tsv holds the known false
# positives WHY.md lists as path rows (kind path, action note|skip, an awk ERE,
# a why). A matching row turns a hit into "NOTE<TAB>path:line<TAB>reason", which
# bin/checks-run.sh shows and never counts (action skip prints nothing). A
# missing list, or an invalid row, is no exclusion: the check stays strict.
#
# Reads the normalized added-line stream on stdin (path<TAB>line<TAB>text).
# Prints "path:line<TAB>reason" per hit. rc 0 = clean, rc 1 = hits.
# DETECTION ONLY: it reads stdin and writes stdout. Nothing else.
set -uo pipefail
LIST="$(dirname "$0")/exclusions.tsv"
OUT=$(awk -F'\t' -v LIST="$LIST" '
  BEGIN {
    NX = 0; ln = 0
    while ((getline row < LIST) > 0) {
      ln++
      if (row ~ /^[[:space:]]*(#|$)/) continue
      if (split(row, a, "\t") != 4 || a[1] != "path" || a[2] !~ /^(note|skip)$/ || a[3] == "") continue
      NX++; XA[NX] = a[2]; XP[NX] = a[3]; XW[NX] = a[4]; XR[NX] = ln
    }
    close(LIST)
  }
  $1 ~ /(\/api\/|\/server\/|\/actions\/)/ || $1 ~ /(^|\/)(route|actions|handler)\.(ts|tsx|js|mjs|cjs)$/ {
    t=$3
    # a where-clause object on this line ...
    if (t !~ /where[[:space:]]*:[[:space:]]*[{]/) next
    # ... keyed on a bare id (`{ id: x }`, `{ id }`, `, id }`) ...
    if (t !~ /[{,][[:space:]]*id[[:space:]]*[:}]/) next
    # ... and carrying no scoping column anywhere on the line.
    if (t ~ /(userId|user_id|ownerId|owner_id|orgId|organizationId|org_id|tenantId|tenant_id|clerkId|accountId|account_id|workspaceId|companyId|createdById|memberships|AND[[:space:]]*:|OR[[:space:]]*:)/) next
    r = "data access scoped only by a client-supplied id — no owner/tenant/org column in the same where clause (family fd7bbe69fac5)"
    for (k = 1; k <= NX; k++) if ($1 ~ XP[k]) break
    if (k <= NX) {
      if (XA[k] == "note") printf "NOTE\t%s:%s\t%s [excluded by checks/client-id-trust/exclusions.tsv row %d: %s]\n", $1, $2, r, XR[k], XW[k]
      next
    }
    printf "%s:%s\t%s\n", $1, $2, r
  }
')
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
exit 1
