#!/bin/bash
# shellcheck shell=bash
# bin/lib/unblock/seam-defect.sh — the unblock tick's fold of a lane-wide
# batch_failure seam defect (BH-8748). Sourced by bin/unblock.sh, never run;
# nothing here runs on source.
#
# WHY. When the seam itself is broken (no mcp/tools/batch-failure.mjs, no
# node, no console URL, no GitHub token), every red-batch draft of the repo
# fails for ONE cause. Before BH-8748 each draft became its own
# queue-unreadable card: 99 Tackler cards with no cause for one missing file.
# The queue collector now prints ONE record with lane_defect:true for that
# case (bin/lib/unblock/collectors/queue.sh, _ubq_seam_record). This fold
# turns it into ONE ALERT per project and reason per window, and no card.
#
#   ubs_fold <project> <records file>
#     Removes every `lane_defect == true` record from the file (temp file +
#     mv). For each one: when the marker
#     $HARNESS/state/unblock-seam-alert/<project>-<reason> is absent or older
#     than UNBLOCK_SEAM_ALERT_WINDOW_H hours, writes one line through
#     bin/alert-line.sh (--id unblock-seam-<project>-<reason>), then touches
#     the marker. A failed alert-line.sh leaves the marker as it was, so the
#     next tick tries again; it never fails the tick. Prints the count it
#     removed. rc 0 always.
#
# Knob (env, set from the lane registry; the code default is the fallback):
#   UNBLOCK_SEAM_ALERT_WINDOW_H (24)  the ALERT dedupe window, in hours

_ubs_int() { # _ubs_int <value> <default>
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

ubs_fold() {
  local proj="${1:-}" f="${2:-}" h tmp n=0 win now line repo why seam cnt first key mk mt
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -f "$f" ] || { echo 0; return 0; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/ubs.XXXXXX") || { echo 0; return 0; }
  jq -c 'select(.lane_defect != true)' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; echo 0; return 0; }
  # Fallback 24 = the UNBLOCK_SEAM_ALERT_WINDOW_H knob default
  # (catalog/lanes.d/unblock.knobs.d/UNBLOCK_SEAM_ALERT_WINDOW_H.json).
  win=$(_ubs_int "${UNBLOCK_SEAM_ALERT_WINDOW_H:-}" 24)
  now=$(date -u +%s)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    IFS=$'\t' read -r repo why seam cnt first < <(jq -r '[(.repo // "?"), (.reason // "unknown"),
        (.seam_file // "?"), ((.drafts // []) | length), ((.drafts // [])[0:5] | map(tostring) | join(" "))] | @tsv' <<< "$line")
    key=$(printf '%s' "$why" | tr -c 'a-z0-9_-' '_')
    mk="$h/state/unblock-seam-alert/$proj-$key"
    mt=$(stat -c %Y "$mk" 2>/dev/null || echo 0)
    [ $((now - mt)) -ge $((win * 3600)) ] || continue
    if "$h/bin/alert-line.sh" --id "unblock-seam-$proj-$key" \
        "[$(hostname)] tackler: cannot read any merge batch on $repo: $why ($seam); $cnt red-batch drafts unread ($first). No card per draft. Fix: bin/harness-sync.sh copies mcp/; check CONSOLE_URL and bin/gh-token.sh --read $repo." \
        >/dev/null 2>&1; then
      mkdir -p "${mk%/*}" 2>/dev/null && touch "$mk" 2>/dev/null
    fi
  done < <(jq -c 'select(.lane_defect == true)' "$f" 2>/dev/null)
  if [ "$n" -gt 0 ]; then mv "$tmp" "$f"; else rm -f "$tmp"; fi
  echo "$n"
  return 0
}
