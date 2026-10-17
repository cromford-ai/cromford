#!/bin/bash
# bin/lib/prepush-record.sh — the pre-push gate record: which suites the gate
# ran green on one head, written into the PR body, read by the merge-queue plan.
#
# WHY. bin/prepush-gate.sh runs the fast always-suites (fast-lints) and the
# rules-pack suite components on the builder, on the head it pushes. A batch
# re-ran all of them. bin/ci-plan.sh drops the suites of
# catalog/test-impact-always-prepush.txt from a batch only when EVERY member's
# PR body carries a record whose head is that member's head; it drops only the
# suites in every record (the intersection), never one that a member's gate
# did not run green.
#
# THE RECORD (v1), in the PR body:
#   <!-- prepush-gate-record v1 head=<40-hex> -->
#   <details><summary>Suites the pre-push gate ran green on this head (N)</summary>
#
#   prepush-ran: tests/a.sh
#   </details>
#   <!-- /prepush-gate-record -->
# The markers must start their line, so a quoted reply (`> <!-- …`) is not one.
#
#   ppr_write <gate-out-dir> <head-sha> [<tree>]
#       stdout: the block above (with a `## Pre-push gate: record` heading),
#       rc 0. The suites: every fast-lints.d/timings.tsv row with rc 0, and,
#       when the rules-pack row of summary.tsv is green, every rules-pack
#       component that summary.json says is green and whose catalog row
#       (<tree>/catalog/rules-pack.tsv, kind suite) names a suite that is in
#       rules-pack.d/suites.txt. A path must match ^tests/[A-Za-z0-9._/-]+\.sh$
#       with no `..`. rc 1 and no output: a sha that is not 40-hex, no
#       summary.tsv, or no suite.
#   ppr_read <body-file> <head-sha>
#       CR is stripped. Exactly one v1 start marker, its head equal to the
#       argument, and an end marker after it: prints each valid
#       `prepush-ran: <path>` path between them, sorted, rc 0. Anything else
#       (no marker, two markers, another version, another head, no end
#       marker, no valid path) is rc 1 with no output.
#   ppr_list_build <tree>
#       The always-suites the gate runs: `bin/test-impact.sh always` of the
#       tree, joined with (`bin/fast-lints.sh --list` ∪ the rules-pack kind
#       suite paths). FAST_LINTS_DURATIONS is passed through. rc 1 when a
#       reader fails or the set is empty. Writes the data lines of
#       catalog/test-impact-always-prepush.txt.
#
# Sourced lib: no set -e, no exit, no harness root default.

PPR_SUITE_RE='^tests/[A-Za-z0-9._/-]+\.sh$'

# _ppr_valid <path> — rc 0 for a plain tests/ suite path.
_ppr_valid() {
  [[ "$1" =~ $PPR_SUITE_RE ]] || return 1
  case "$1" in *..*) return 1 ;; esac
  return 0
}

ppr_write() {
  local out="${1:-}" head="${2:-}" tree="${3:-.}" s rc st id cat_argv suites n
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "$out" ] && [ -r "$out/summary.tsv" ] || return 1
  suites=""
  # fast-lints: <suite>\t<seconds>\t<rc>, rc 0 only.
  if [ -r "$out/fast-lints.d/timings.tsv" ]; then
    while IFS=$'\t' read -r s _ rc; do
      [ "$rc" = 0 ] && _ppr_valid "$s" && suites+="$s"$'\n'
    done < "$out/fast-lints.d/timings.tsv"
  fi
  # rules-pack: the gate row green, then each green suite component.
  st=$(LC_ALL=C awk -F'\t' '$1 == "rules-pack" { print $2; exit }' "$out/summary.tsv" 2>/dev/null)
  if [ "$st" = green ] && [ -r "$out/rules-pack.d/summary.json" ] && [ -r "$out/rules-pack.d/suites.txt" ] \
     && [ -r "$tree/catalog/rules-pack.tsv" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      cat_argv=$(LC_ALL=C awk -F'\t' -v i="$id" '$1 == i && $3 == "suite" { print $4; exit }' "$tree/catalog/rules-pack.tsv")
      s="${cat_argv%% *}"
      [ -n "$s" ] && _ppr_valid "$s" || continue
      LC_ALL=C awk -v s="$s" '{ split($0, w, " ") } w[1] == s { f = 1 } END { exit !f }' "$out/rules-pack.d/suites.txt" \
        && suites+="$s"$'\n'
    done < <(jq -r '.components[]? | select(.state == "green") | .id // empty' "$out/rules-pack.d/summary.json" 2>/dev/null)
  fi
  suites=$(printf '%s' "$suites" | LC_ALL=C sort -u | grep .) || return 1
  n=$(grep -c . <<<"$suites")
  printf '\n## Pre-push gate: record\n\n'
  printf '<!-- prepush-gate-record v1 head=%s -->\n' "$head"
  printf '<details><summary>Suites the pre-push gate ran green on this head (%s)</summary>\n\n' "$n"
  while IFS= read -r s; do printf 'prepush-ran: %s\n' "$s"; done <<<"$suites"
  printf '</details>\n<!-- /prepush-gate-record -->\n'
  return 0
}

ppr_read() {
  local f="${1:-}" head="${2:-}" body starts got paths
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 1
  [ -n "$f" ] && [ -r "$f" ] || return 1
  body=$(tr -d '\r' < "$f") || return 1
  # Every line that starts like a record marker counts, any version.
  starts=$(LC_ALL=C grep -c '^<!-- prepush-gate-record ' <<<"$body")
  [ "$starts" = 1 ] || return 1
  got=$(LC_ALL=C sed -n 's/^<!-- prepush-gate-record v1 head=\([0-9a-f]\{40\}\) -->$/\1/p' <<<"$body")
  [ -n "$got" ] && [ "$got" = "$head" ] || return 1
  paths=$(LC_ALL=C awk '
    /^<!-- prepush-gate-record v1 head=/ { inr = 1; next }
    inr && /^<!-- \/prepush-gate-record -->$/ { done = 1; exit }
    inr && /^prepush-ran: / { print substr($0, 14) }
    END { if (!done) exit 1 }' <<<"$body") || return 1
  paths=$(while IFS= read -r p; do _ppr_valid "$p" && printf '%s\n' "$p"; done <<<"$paths" | LC_ALL=C sort -u)
  [ -n "$paths" ] || return 1
  printf '%s\n' "$paths"
}

ppr_list_build() {
  local tree="${1:-}" always fast rp
  [ -n "$tree" ] && [ -d "$tree" ] || return 1
  always=$(cd "$tree" && bin/test-impact.sh always 2>/dev/null) && [ -n "$always" ] || return 1
  fast=$(cd "$tree" && bin/fast-lints.sh --list 2>/dev/null) || return 1
  rp=$(LC_ALL=C awk -F'\t' '!/^#/ && $3 == "suite" { split($4, w, " "); print w[1] }' "$tree/catalog/rules-pack.tsv" 2>/dev/null) || return 1
  LC_ALL=C awk 'NR == FNR { a[$0] = 1; next } ($0 in a) && !seen[$0]++' \
    <(printf '%s\n' "$always") <(printf '%s\n%s\n' "$fast" "$rp") | LC_ALL=C sort -u | grep .
}
