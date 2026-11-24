#!/bin/bash
# guardrails/lib/escape-hatch.sh — the ONE escape hatch, shared by every check.
#
# A guardrail with no way out gets deleted the first time it is wrong. A
# guardrail with a silent way out is decoration. So every check in this catalog
# can be skipped, and skipping it costs a label plus a written reason that stays
# in the PR record where a reviewer sees it.
#
# Source this and call:  guardrail_escape_hatch <check-name>
#   rc 0  -> skipped: the PR carries the `skip-guardrail` label AND a real
#            written justification. The reason is printed.
#   rc 1  -> not skipped: run the check.
#
# Inputs (CI sets these; both are required, neither alone is enough):
#   PR_LABELS               comma/space separated PR labels
#   GUARDRAIL_JUSTIFICATION text containing a `Guardrail-Justification:` line
# Batch-draft inputs (BH-9965; opt-in, see below and lib/batch-hatch.sh):
#   GUARDRAIL_HEAD_REF      the PR head branch (github.head_ref)
#   GUARDRAIL_PR_AUTHOR     the PR author login
#   GUARDRAIL_DRAFT_BODY    the draft PR body, parsed ONLY for source PR numbers
#   GITHUB_REPOSITORY, GH_TOKEN, GUARDRAIL_GH (the gh binary, default gh)
#
# TWO THINGS THIS DELIBERATELY REFUSES, both found by review:
#
#  1. WHITESPACE. An earlier version counted characters, so twenty-five spaces
#     was a valid reason to disable a security check. The marker line's payload
#     is stripped before it is measured, and a blank payload is no payload.
#
#  2. THE WHOLE PR BODY. The natural CI wiring is
#     GUARDRAIL_JUSTIFICATION: ${{ github.event.pull_request.body }} — which
#     makes ANY body, including an empty-ish one, a justification, and it is
#     the line every drafted check copies. So a bare blob is not accepted:
#     the text must carry an explicit `Guardrail-Justification: <reason>` line.
#     Someone has to type that sentence on purpose. (bin/guardrail-promote.sh
#     refuses to open a PR for a drafted step that wires the raw body at all.)
#
# A label with no justification fails LOUDLY rather than skipping: "I said skip"
# is not a reason, and letting it through would make the label the whole gate.
#
# MERGIFY BATCH DRAFTS (BH-9965). Mergify tests a batch on its own draft PR,
# which carries neither the source PRs' labels nor their bodies. When CI marks
# the run as a batch draft (GUARDRAIL_HEAD_REF starts with
# `mergify/merge-queue/` AND GUARDRAIL_PR_AUTHOR is exactly `mergify[bot]`),
# the hatch reads each SOURCE PR instead (lib/batch-hatch.sh) and returns 1
# (run the check) with GUARDRAIL_EXEMPT set to the files only hatched source
# PRs changed. A check drops those files through guardrail_drop_exempt. Both
# inputs are opt-in: with them unset this function is byte for byte as before.
#
# GUARDRAIL_EXEMPT is cleared when this file is sourced, so a value in the
# ambient environment never exempts a file.
GUARDRAIL_EXEMPT=""

# guardrail_is_exempt <path>: rc 0 when <path> (a leading ./ stripped) is in
# GUARDRAIL_EXEMPT, a newline list of repo-relative paths.
guardrail_is_exempt() {
  local f="${1#./}"
  [ -n "${GUARDRAIL_EXEMPT:-}" ] || return 1
  case $'\n'"$GUARDRAIL_EXEMPT"$'\n' in
    *$'\n'"$f"$'\n'*) return 0 ;;
  esac
  return 1
}

# guardrail_drop_exempt: a file list on stdin, the same list minus the exempt
# paths on stdout. With nothing exempt it is cat.
guardrail_drop_exempt() {
  if [ -z "${GUARDRAIL_EXEMPT:-}" ]; then cat; return 0; fi
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    guardrail_is_exempt "$line" || printf '%s\n' "$line"
  done
}

# guardrail_semgrep_excludes: one `--exclude=<path>` line per exempt path, for
# the semgrep checks' CI form. A path holding a glob character is left out: an
# exclude pattern must never widen to files nobody hatched.
guardrail_semgrep_excludes() {
  local f
  [ -n "${GUARDRAIL_EXEMPT:-}" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *'*'*|*'?'*|*'['*) continue ;; esac
    printf -- '--exclude=%s\n' "$f"
  done <<< "$GUARDRAIL_EXEMPT"
}

guardrail_escape_hatch() {
  local _gh_head="${GUARDRAIL_HEAD_REF:-}"
  if [ "$_gh_head" != "${_gh_head#mergify/merge-queue/}" ] \
     && [ "${GUARDRAIL_PR_AUTHOR:-}" = "mergify[bot]" ]; then
    local lib
    lib="$(dirname "${BASH_SOURCE[0]}")/batch-hatch.sh"
    # shellcheck source=batch-hatch.sh
    if [ -f "$lib" ] && . "$lib" && declare -F _guardrail_batch_hatch >/dev/null; then
      _guardrail_batch_hatch "${1:-guardrail}"
      return 1
    fi
    echo "GUARDRAIL ${1:-guardrail}: batch draft: could not read source PR(s) (guardrails/lib/batch-hatch.sh is missing); no file is exempt."
    GUARDRAIL_EXEMPT=""
    return 1
  fi
  local check="${1:-guardrail}" labels="${PR_LABELS:-}" why="${GUARDRAIL_JUSTIFICATION:-}"
  local reason
  case ",${labels//[[:space:]]/,}," in
    *,skip-guardrail,*) ;;
    *) return 1 ;;
  esac
  # Take only the marker line's payload, then strip surrounding whitespace.
  # One awk, not grep|sed: the match and the strip must share ONE definition of
  # the marker, or a case the matcher accepts and the stripper misses leaves the
  # marker text itself standing in as the "reason" (24 chars — passes the length
  # check with an empty actual payload). tolower/substr are POSIX awk.
  reason=$(printf '%s\n' "$why" | awk '{
    s=$0; sub(/^[[:space:]]+/, "", s)
    if (tolower(substr(s, 1, 24)) == "guardrail-justification:") { print substr(s, 25); exit }
  }')
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  if [ "${#reason}" -lt 20 ]; then
    echo "GUARDRAIL $check: 'skip-guardrail' label present, but no usable justification."
    echo "  Add a line to the PR body reading:"
    echo "    Guardrail-Justification: <at least 20 characters of actual reason>"
    echo "  Whitespace does not count, and neither does the label on its own. Not skipping."
    return 1
  fi
  echo "GUARDRAIL $check: SKIPPED via skip-guardrail label."
  echo "  Justification: $reason"
  return 0
}
