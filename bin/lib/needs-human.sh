# bin/lib/needs-human.sh — the needs-human contract (BH-3433; this slice BH-3442).
# Sourced, never executed. A review BLOCK whose only open finding is a step a
# human has to take (set an env var, apply a migration, click a vendor console)
# is held on the issue instead of being rebuilt forever. This file is the
# interface the later BH-3433 slices implement; every function below except
# nh_fingerprint is a stub in bin/lib/needs-human/ with its documented default,
# so sourcing it today changes nothing.
#
# Markers: a hold comment starts "NEEDS-HUMAN:", its release "HUMAN-STEP-DONE:",
# and carries the hidden fingerprint <!-- nh-fp:<fp> -->.
#
# nh_fingerprint <text>              prints 12 hex, rc 0; nothing + rc 1 when no
#                                    token survives. Pure: no network, no root.
# classify.sh
#   nh_classify <review.md | --text STRING>
#                                    rc 0 prints "needs-human<TAB><action>",
#                                    rc 1 prints "none", rc 2 unreadable.
#   nh_on_block <project> <issue> <review.md> <build-dir>
#                                    prints the RESULT suffix
#                                    " NEEDS_HUMAN:<fp>:<action>" or nothing;
#                                    never fails the caller.
#   nh_prompt_field_note             prints review-prompt text, or nothing.
# trip.sh
#   nh_trip_note <project> <issue> <fp> <build-id>
#                                    rc 0 trip, 1 no trip, 2 ledger unreadable.
#   nh_trip_on_block <project> <issue> <review.md> <build-id> [<nh-action>]
#                                    rc 0, no output.
# release.sh (each prints text or nothing, rc 0)
#   nh_release_evidence <slug> <issue>
#   nh_prompt_release_note <slug> <issue>
#   nh_pr_body_section <slug> <issue>
# step-done.sh (BH-6536: a human-step-only BLOCK after the person did the step)
#   nh_sd_human_only <review.md>     rc 0 prints "human-step<TAB><action>",
#                                    rc 1 prints "none", rc 2 unreadable.
#   nh_sd_done_after <comments-json> <since-iso>
#                                    rc 0 prints the evidence, rc 1 none,
#                                    rc 2 unreadable. Pure: no network.
#   nh_sd_rescue_on [project]        rc 0 shape D runs for the project: the
#                                    review-rescue knob RESCUE_HUMAN_STEP (read
#                                    with lane_knob) is 1 and that lane is not off.
#   nh_sd_pending <record-dir> [project]
#                                    rc 0 the record waits for the rescue
#                                    lane's human-step re-review, else rc 1.
#   nh_sd_stage_put <project> <issue> <key> <state> <reason>
#                                    writes the ticket_stage row; rc 0 always.
#   nh_sd_stage_lines <project>      the hub-local rows in the window; rc 0.
# bin/needs-human-hold.sh <project> <issue> <fp> <action> <source>
#                                    0 placed / already held / switch off / not
#                                    an issues board; 1 could not place; 75
#                                    thread unreadable.
#
# The sub-libs load relative to this file, each fail-open: a half-synced box
# keeps whatever loaded and every call site tolerates a missing function. The
# kill switch is `lane_switch needs-human-hold-off`; the trip threshold is the
# settings row lib.needs-human.needs_human_trip_count (catalog/lanes.d/_lib.needs-human.json).
# shellcheck shell=bash

[ -n "${_NH_LIB_LOADED:-}" ] && return 0
_NH_LIB_LOADED=1

NH_MARKER_PREFIX='NEEDS-HUMAN:'
NH_DONE_PREFIX='HUMAN-STEP-DONE:'
NH_FP_TAG='nh-fp'

# Lowercase; strip D-rule cites "(D3)", "(D1, D4)", FRAUD: <class> tags and
# backticks; punctuation to spaces; drop whole-token hex runs of 7+ with a digit
# (shas — "defaced" is a word), then digits, tokens under 4 chars and
# stopwords; sort -u; sha1; first 12 hex. Algorithm constants, not settings: a
# change here re-keys every stored fingerprint.
nh_fingerprint() { # nh_fingerprint <text>
  local toks
  toks=$(printf '%s\n' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\(d[0-9]+[^)]*\)//g; s/fraud:[[:space:]]*[a-z-]*//g; s/`//g' \
    | tr -c 'a-z0-9' ' ' | tr -s ' ' '\n' \
    | awk 'BEGIN { n = split("that this with from have were when then than they them their there these those what which while will would should could into onto only also been being does done over under about after before again just more most some such very each other your ours here", w, " "); for (i = 1; i <= n; i++) stop[w[i]] = 1 }
           /^[0-9a-f]+$/ && length($0) >= 7 && /[0-9]/ { next }
           { gsub(/[0-9]/, "") }
           length($0) >= 4 && !($0 in stop) { print }' \
    | LC_ALL=C sort -u)
  [ -n "$toks" ] || return 1
  printf '%s\n' "$toks" | sha1sum | cut -c1-12
}

_nh_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for _nh_f in classify trip release step-done; do
  [ -r "$_nh_dir/needs-human/$_nh_f.sh" ] && . "$_nh_dir/needs-human/$_nh_f.sh" 2>/dev/null || true
done
unset _nh_f
