#!/bin/bash
# bin/lib/review-false-block.sh — the false-BLOCK counter (BH-7123 wave B).
# Sourced by bin/lead-review-precision.sh; never executed. Report-only, no gate.
#
#   rfb_count <reports-dir> <days>   one JSON object:
#     {reports, demoted, standing, rate}
#   over every lead report under <reports-dir> modified in the last <days>
#   days that carries a `Review level (BH-7123)` marker (rl_cap's header line
#   `- review level (BH-7123): mode=<m> demoted=<k> standing=<s> ...`, else the
#   body marker `Review level (BH-7123): mode <m>, <k> finding(s) demoted to
#   NOTE, <s> BLOCK stands; ...`). rate = demoted / (demoted + standing), three
#   decimals, null when the sum is 0. A report with no marker was never capped
#   (its model verdict was not BLOCK) and is not counted. A missing directory
#   is {reports:0, ...}, never an error: this is a number next to precision,
#   not a lane that can fail a tick.
if [ -n "${REVIEW_FALSE_BLOCK_LIB:-}" ]; then return 0 2>/dev/null; fi
REVIEW_FALSE_BLOCK_LIB=1

rfb_count() { # rfb_count <reports-dir> <days>
  local d="${1:-}" days="${2:-30}" f k s n=0 dem=0 st=0 line
  case "$days" in ''|*[!0-9]*|0) days=30 ;; esac
  if [ -n "$d" ] && [ -d "$d" ]; then
    while IFS= read -r f; do
      [ -r "$f" ] || continue
      line=$(sed -nE 's/^- review level \(BH-7123\): mode=[a-z]+ demoted=([0-9]+) standing=([0-9]+).*/\1 \2/p' "$f" 2>/dev/null | tail -1)
      [ -n "$line" ] || line=$(sed -nE 's/^Review level \(BH-7123\): mode [a-z]+, ([0-9]+) finding\(s\) demoted to NOTE, ([0-9]+) BLOCK stands;.*/\1 \2/p' "$f" 2>/dev/null | tail -1)
      [ -n "$line" ] || continue
      k="${line% *}"; s="${line#* }"
      n=$((n+1)); dem=$((dem+k)); st=$((st+s))
    done < <(find "$d" -maxdepth 1 -type f -name '*.md' -mtime "-$days" 2>/dev/null)
  fi
  jq -nc --argjson n "$n" --argjson k "$dem" --argjson s "$st" \
    '{reports:$n, demoted:$k, standing:$s, rate:(if ($k + $s) == 0 then null else ((($k / ($k + $s)) * 1000) | round) / 1000 end)}'
}
