# shellcheck shell=bash
# bin/lib/ironlaw-rules.sh — the iron-law block names the rule and the lines
# (BH-9696, BH-9427.4). Sourced by bin/merge-conductor.d/bh-9696-ironlaw-rules.sh
# (the conductor's BLOCKED_HUMAN reason) and by brlad_ila_note_rules in
# bin/blocked-resolver.d/bh-9437-ironlaw-adj.sh (the REJECT build note).
# Functions only, no exit. Tests: tests/mc-iron-law-fix.bh-9696-test.sh.
#
# This file must carry no iron-law scan literal on a code line: the rule words
# are matched by a short prefix, so the PR that adds it does not park itself.

# ilr_rule_of <match> — the rule word for one mc_iron_law_lines match.
ilr_rule_of() {
  case "${1:-}" in
    window.*) printf 'native-dialog' ;;
    claude-*) printf 'model-id' ;;
    *)        printf 'vercel-url' ;;
  esac
}

# ilr_rules <diff-file> — one "<rule> <file>:<line>" per iron-law hit in the
#   diff: the literal hits of mc_iron_law_lines (bin/lib/mc/classify.sh, the
#   same file, comment and added-line filters as the scan count), then each
#   "CHECK-HIT <slug> <path>:<line> ..." of ${MC_H:-$H}/bin/checks-run.sh as
#   "<slug> <path>:<line>". A diff with no @@ hunk has no line numbers and gives
#   no literal line (plan A4). No scanner, no checks-run.sh or no diff gives
#   fewer lines, never an error. Always rc 0.
ilr_rules() {
  local df="${1:-}" loc m tag slug rest cr
  [ -n "$df" ] && [ -s "$df" ] || return 0
  if command -v mc_iron_law_lines >/dev/null 2>&1; then
    while IFS=$'\t' read -r loc m; do
      [ -n "$loc" ] && [ -n "$m" ] || continue
      printf '%s %s\n' "$(ilr_rule_of "$m")" "${loc//[[:space:]]/}"
    done < <(mc_iron_law_lines "$df" 2>/dev/null)
  fi
  cr="${MC_H:-${H:-}}/bin/checks-run.sh"
  if [ -x "$cr" ]; then
    while read -r tag slug loc rest; do
      [ "$tag" = CHECK-HIT ] && [ -n "$slug" ] && [ -n "$loc" ] && printf '%s %s\n' "$slug" "$loc"
    done < <("$cr" "$df" 2>/dev/null)
  fi
  return 0
}

# ilr_join <max> — stdin rules (one per line) joined by "; ", the first <max>
#   named and "+K more" for the rest. Empty stdin or max 0 prints nothing.
ilr_join() {
  awk -v m="${1:-0}" 'NF { n++; if (n <= m) s = s (n > 1 ? "; " : "") $0 }
    END { if (m > 0 && n > 0) { if (n > m) s = s "; +" (n - m) " more"; printf "%s", s } }'
}

# ilr_why <state> <why> <rules> <max> — the conductor reason with the rules
#   appended: "<why>: r1; r2; +K more". Only for state BLOCKED_HUMAN, a reason
#   that starts "iron-law (" (mc_classify's scan reason), a non-empty rule list
#   and a max above 0. Else <why> unchanged. Every reader of the reason matches
#   a prefix (mc_resolver_owns, br_reason_of, the hold-comment kind,
#   bin/human-block-report.sh), so the class stays iron-law.
ilr_why() {
  local state="${1:-}" why="${2:-}" rules="${3:-}" max="${4:-0}" named
  case "$max" in ''|*[!0-9]*) max=0 ;; esac
  if [ "$state" = BLOCKED_HUMAN ] && [ -n "$rules" ] && [ "$((10#$max))" -gt 0 ]; then
    case "$why" in
      "iron-law ("*)
        named=$(printf '%s\n' "$rules" | ilr_join "$((10#$max))")
        [ -n "$named" ] && { printf '%s: %s' "$why" "$named"; return 0; } ;;
    esac
  fi
  printf '%s' "$why"
}
