# shellcheck shell=bash
# bin/blocked-resolver.d/bh-10350-merged-record.sh — BH-10350 (BH-9926): the
# resolver's merged-PR lookup (br_merged_prs_for) answers from the PR record.
#
# THE READ. br_already_merged asks br_merged_prs_for <slug> <key> <park-epoch>
# for the ticket's merged PRs. Today that is two search/issues reads plus one
# pulls/<n> read per hit, on every park check. The first line of
# br_merged_prs_for calls brmr_read here, which goes through prr_read
# blocked-resolver on the lane's step GH_SOURCE (settings row
# lane.blocked-resolver.gh_source, default shadow; the bh-10157 fragment pins
# it before this file loads):
#   off     today's searches, 0 jobs reads.
#   shadow  today's searches, and the record answer is compared
#           (PRR_SHADOW key=<slug>#<KEY>@merged in logs/prr-shadow.log).
#   record  one jobs GET: the repo's merged rows since the park
#           (brs_merged_record in bin/lib/prr-shadow.d/blocked-resolver.sh).
#           A hit makes 0 GitHub calls. A miss logs PRR_MISS and runs today's
#           searches, unchanged.
#
# THE REASON. Each search that still runs writes one resolver log line:
#   <slug>: the merged-PR search for <KEY> ran, reason=step-off|step-shadow
#   <slug>: the merged-PR search for <KEY> ran, reason=record-miss:<why>, rc <n>
#
# FAIL OPEN. With no bin/lib/prr-shadow.sh, or no seam, brmr_read runs today's
# search. BR_OPT_OFF=bh-10350-merged-record does not source this file, and
# br_merged_prs_for then never calls brmr_read.
if ! command -v prr_read >/dev/null 2>&1 && [ -n "${H:-}" ] && [ -r "$H/bin/lib/prr-shadow.sh" ]; then
  # shellcheck source=bin/lib/prr-shadow.sh
  . "$H/bin/lib/prr-shadow.sh"
fi
if ! command -v brs_merged_record >/dev/null 2>&1 && command -v prr_seam_load >/dev/null 2>&1; then
  prr_seam_load blocked-resolver || true
fi
# Pin the step once, when the bh-10157 fragment did not (BR_OPT_OFF named it).
if command -v prr_pin >/dev/null 2>&1 && [ "${GH_SOURCE_LANE:-}" != blocked-resolver ]; then
  prr_pin blocked-resolver || true
fi

# brmr_github <file> <owner/repo> <ticket-key> [since] — today's search.
brmr_github() {
  _BRMR_GH=1 br_merged_prs_for "${2:-}" "${3:-}" > "${1:-/dev/null}"
}

# brs_merged_note <out> <github-rc> <why> <owner/repo> <ticket-key> [since] —
#   prr_read calls it once after a record miss in step record. It writes the
#   reason line only, and nothing into the record.
brs_merged_note() {
  say "${4:-}: the merged-PR search for ${5:-} ran, reason=record-miss:${3:-unknown}, rc ${2:-}"
  return 0
}

# brmr_read <owner/repo> <ticket-key> [since-epoch] — the TSV of
#   br_merged_prs_for on stdout, from the source the step names. rc 0, or 75
#   when the search did not answer (as today).
brmr_read() {
  local slug="${1:-}" tkey="${2:-}" since="${3:-}" step f rc
  if ! command -v prr_read >/dev/null 2>&1 || ! command -v prr_step >/dev/null 2>&1 \
     || ! command -v brs_merged_record >/dev/null 2>&1 \
     || ! f=$(mktemp "${TMPDIR:-/tmp}/brmr.XXXXXX"); then
    _BRMR_GH=1 br_merged_prs_for "$slug" "$tkey"; return $?
  fi
  step=$(prr_step blocked-resolver)
  case "$step" in off|shadow) say "$slug: the merged-PR search for $tkey ran, reason=step-$step" ;; esac
  _BRMR_SINCE="$since" prr_read blocked-resolver "$slug#$tkey@merged" "$f" \
    brs_merged_record brmr_github brs_merged_norm "$slug" "$tkey" "$since"; rc=$?
  [ "$rc" = 0 ] && cat "$f"
  rm -f "$f"
  return "$rc"
}
