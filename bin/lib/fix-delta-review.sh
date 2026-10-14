#!/bin/bash
# bin/lib/fix-delta-review.sh — does the merged re-review after the one fix
# round read the DELTA, or the whole branch again? (BH-2546)
#
# Sourced by the `# >>> review lenses` block in bin/lib/rb/review.sh, never run.
# The lenses already read the whole branch diff at FIX_FROM. The fix round then
# commits on top of it, usually a few lines. Re-reading the whole branch for
# those few lines is most of what a re-review costs, so a small delta is handed
# to the re-review on its own, next to the prior findings it has to answer.
#
# EVERY UNKNOWN IS A FULL REVIEW. Delta mode lowers review depth in front of an
# auto-merge, so it is bought only when every fact it rests on was measured:
# the knob resolved to a number, the reviewed head exists and is an ancestor of
# the new head (a fix session that amended or rebased rewrote what the lenses
# read), the delta has no binary file numstat cannot size, and git produced the
# range-diff, and the delta text fits the byte ceiling. Anything else answers
# `full <reason>` — the prompt as it was.
#
# LINES ARE NOT BYTES. The delta rides INLINE in the re-review prompt, and that
# prompt is one argv element to bin/agent-call.sh: over MAX_ARG_STRLEN (128KB)
# execve fails E2BIG before anything runs, and over AGENT_ARGV_MAX agent-call
# refuses it — either way an empty review that every refusing lens reads as
# BLOCK. One numstat line can be a 100KB minified file, so the delta file's own
# size is capped by FIX_DELTA_REVIEW_MAX_BYTES, well under both.
#
# fdr_decide <base> <from> <to> <out>
#   prints ONE line and returns 0:
#     delta <lines> <max>   and <out> holds `git range-diff <base> <from> <to>`
#                           followed by `git diff <from> <to>`: the range-diff
#                           shows a commit the fix round ADDED only as a header
#                           line, so the changed lines themselves ride under it.
#     full <reason>         reason: knob-unresolved knob-off no-prev-head
#                           history-rewritten diff-unavailable binary over-max
#                           range-diff-failed over-bytes. <out> is not left.
# fdr_knob <ENV> — a knob of catalog/lanes.d/_lib.fix-delta-review.json
#   (FIX_DELTA_REVIEW_MAX_LINES, FIX_DELTA_REVIEW_MAX_BYTES): operator row > cached row >
#   env > registry default, through lane-gate.sh's lib_env_apply in a subshell
#   (bin/lib/review-post.sh's _rp_knobs is the precedent), then this checkout's
#   own registry default. An EMPTY value falls through to the default; a value
#   that is set but not digits is rc 1 — garbage is never read as small or off.

_FDR_LIB="${BASH_SOURCE[0]%/*}"

fdr_knob() {
  local k="${1:-}" v
  case "$k" in FIX_DELTA_REVIEW_MAX_LINES|FIX_DELTA_REVIEW_MAX_BYTES) ;; *) return 1 ;; esac
  v=$(
    lg="${HARNESS:-${H:-/root/harness}}/bin/lib/lane-gate.sh"
    [ -r "$lg" ] || lg="$_FDR_LIB/lane-gate.sh"
    command -v lib_env_apply >/dev/null 2>&1 || { [ -r "$lg" ] && . "$lg" >/dev/null 2>&1; }
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply fix-delta-review >/dev/null 2>&1
    printf '%s' "${!k:-}"
  ) || v=""
  if [ -z "$v" ]; then
    v=$(jq -r --arg k "$k" '.libs[]? | select(.id == "fix-delta-review") | .knobs[]?
               | select(.env == $k) | .default // empty' \
          "$_FDR_LIB/../../catalog/lanes.d/_lib.fix-delta-review.json" 2>/dev/null)
  fi
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$v))"
}
fdr_max_lines() { fdr_knob FIX_DELTA_REVIEW_MAX_LINES; }
fdr_max_bytes() { fdr_knob FIX_DELTA_REVIEW_MAX_BYTES; }

fdr_decide() {
  local base="${1:-}" from="${2:-}" to="${3:-}" out="${4:-}" max maxb ns sum
  max=$(fdr_max_lines) || { echo "full knob-unresolved"; return 0; }
  [ "$max" -gt 0 ] || { echo "full knob-off"; return 0; }
  maxb=$(fdr_max_bytes) || { echo "full knob-unresolved"; return 0; }
  [ "$maxb" -gt 0 ] || { echo "full knob-off"; return 0; }
  if [ -z "$from" ] || ! git rev-parse -q --verify "$from^{commit}" >/dev/null 2>&1; then
    echo "full no-prev-head"; return 0
  fi
  git merge-base --is-ancestor "$from" "$to" 2>/dev/null || { echo "full history-rewritten"; return 0; }
  ns=$(git diff --numstat "$from" "$to" 2>/dev/null) || { echo "full diff-unavailable"; return 0; }
  # numstat prints `-<TAB>-` for a file it cannot count lines in.
  if grep -qE $'^-\t' <<<"$ns"; then echo "full binary"; return 0; fi
  sum=$(printf '%s\n' "$ns" | awk -F'\t' 'NF>=3 {s += $1 + $2} END {print s + 0}')
  [ "$sum" -le "$max" ] || { echo "full over-max"; return 0; }
  if ! { git range-diff --no-color "$base" "$from" "$to" && git diff --no-color "$from" "$to"; } > "$out" 2>/dev/null; then
    rm -f "$out"; echo "full range-diff-failed"; return 0
  fi
  [ "$(wc -c < "$out" | tr -d ' ')" -le "$maxb" ] || { rm -f "$out"; echo "full over-bytes"; return 0; }
  echo "delta $sum $max"
}
