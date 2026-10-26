# bin/lib/rules-canon.sh — which file is the box canon for ~/.claude/CLAUDE.md
# (BH-7971, BH-7940.3 decision 7; docs/PROMPTS.md "## Hub render and build note").
#
#   rules_canon_path <harness> <checkout>   (both required; no default root)
#       <harness>/state/prompts/_fleet/rules.md when it is a regular, readable,
#       non-empty file (the hub render writes it only for a fleet `rules` head),
#       else <checkout>/rules/CLAUDE.md. A missing, empty or directory path, a
#       stray .tmp or a project rules.md never picks the fleet file.
#   rules_canon_source <harness> <checkout>
#       `fleet` or `repo`, for log lines.
#
# Readers: bin/update-runners.sh, bin/sync-agent-rules.sh apply,
# bin/context-signature.sh. bin/rules-drift-check.sh carries the same rule
# inline in its remote probe. Each reader falls back to the checkout path when
# this lib is missing, which is the behaviour before BH-7971.
# shellcheck shell=bash

rules_canon_path() {
  local f="$1/state/prompts/_fleet/rules.md"
  if [ -n "$1" ] && [ -f "$f" ] && [ -r "$f" ] && [ -s "$f" ]; then
    printf '%s\n' "$f"
  else
    printf '%s\n' "$2/rules/CLAUDE.md"
  fi
}

rules_canon_source() {
  case "$(rules_canon_path "$@")" in
    */state/prompts/_fleet/rules.md) echo fleet ;;
    *) echo repo ;;
  esac
}
