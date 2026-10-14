#!/bin/bash
# bin/lib/outcome-metrics.d/mq-full-share.sh — the `mq-full-share` measurer for
# bin/outcome-check.sh (BH-6372). Sourced, never executed.
#
# om_mq_full_share <since-iso> <until-iso>
#   Prints `<share> <n>`, rc 0. n = the merge-queue CI runs of ${OM_REPO}
#   (default HARNESS_REPO) that completed in [since, until] on a
#   `mergify/merge-queue/*` ref and carry a ci-plan mode. share = the runs whose
#   ci-plan mode was `full`, divided by n, as %.2f. n = 0 prints `- 0`, never
#   0.00. A `full-legacy` row is a run with no `::notice title=ci-plan::` line,
#   so it has no ci-plan mode and is not counted.
#   The rows are the worker's ci_batches table (GET /api/ci-batches), which
#   bin/ci-batch-ledger.sh fills from that notice over GitHub REST.
#   rc 1 and nothing printed when the read fails, the answer has no rows array,
#   or the answer is truncated: an incomplete window is never a number.
#   The caller supplies _jobs_req (bin/jobs-client.sh).
#
# THE MEASURER CONTRACT (bin/lib/outcome-metrics.d/<id>.sh): the file defines
# om_<id with - as _> <since> <until> and prints `<number|-> <int>`.
# shellcheck shell=bash

om_mq_full_share() {
  local since="${1:-}" until="${2:-}" repo="${OM_REPO:-${HARNESS_REPO:-}}" enc resp counts
  [ -n "$since" ] && [ -n "$until" ] && [ -n "$repo" ] || return 1
  declare -F _jobs_req >/dev/null || return 1
  enc=$(jq -rn --arg r "$repo" '$r | @uri') || return 1
  resp=$(_jobs_req GET "/api/ci-batches?repo=$enc&since=$since&limit=5000") || return 1
  counts=$(printf '%s' "$resp" | jq -er --arg u "$until" '
    if (.rows | type) != "array" or .truncated == true then error("incomplete") else . end
    | [.rows[]
       | select((.head_ref // "") | startswith("mergify/merge-queue/"))
       | select((.completed_at // "") != "" and .completed_at <= $u)
       | select(.mode != null and .mode != "full-legacy")]
    | "\([.[] | select(.mode == "full")] | length) \(length)"' 2>/dev/null) || return 1
  awk '{ if ($2 == 0) print "- 0"; else printf "%.2f %d\n", $1 / $2, $2 }' <<<"$counts"
}
