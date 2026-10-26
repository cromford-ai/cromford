# bin/lib/prompt-note.sh — the seven `PROMPT <kind>: …` lines a build note ends
# with (BH-7971, BH-7940.3; docs/PROMPTS.md "## Hub render and build note").
#
#   prompt_note_lines <project> <harness> <checkout>
#       Seven lines, kinds in the fixed order rules watcher plan execute review
#       fix-round qa, read from <harness>/state/prompts/<project>/sources.tsv
#       (written by bin/prompt-render.sh, one `--source` line per kind):
#         a fleet or project line  -> PROMPT <kind>: <source> v<n> (<version_id>)
#         a repo line, no line, or a malformed line
#                                  -> PROMPT <kind>: repo default (<sha12>)
#       sha12 is the first 12 hex digits of `git hash-object` of the repo file:
#       rules <checkout>/rules/CLAUDE.md, watcher <harness>/prompts/<project>.md,
#       a stage kind <harness>/prompts/stages/<kind>.md. A missing file is
#       `repo default (no file)`. With no sources.tsv: `PROMPT <kind>: repo
#       default` for all seven. The first line of a kind wins.
#   prompt_note_append <build> <project>
#       Appends those lines to <build>/evidence.md. The harness is $HARNESS (or
#       $H); the checkout is $HARNESS_CHECKOUT, else <harness>/../harness-checkout
#       (the layout every box has). No harness: rc 1, nothing appended.
# shellcheck shell=bash

PROMPT_NOTE_KINDS="rules watcher plan execute review fix-round qa"

prompt_note_lines() {
  local project=$1 harness=$2 checkout=$3 tsv k line src ver vid f sha extra
  tsv="$harness/state/prompts/$project/sources.tsv"
  for k in $PROMPT_NOTE_KINDS; do
    if [ ! -f "$tsv" ]; then printf 'PROMPT %s: repo default\n' "$k"; continue; fi
    line=$(awk -v k="$k" '$1 == k {print; exit}' "$tsv" 2>/dev/null)
    src="" ver="" vid="" extra=""
    [ -n "$line" ] && read -r _ src ver vid extra <<<"$line"
    if [ -z "$extra" ] && [[ "$line" =~ ^[a-z-]+\ [a-z]+\ v[0-9]+\ [0-9]+$ ]] \
       && { [ "$src" = fleet ] || [ "$src" = project ]; }; then
      printf 'PROMPT %s: %s %s (%s)\n' "$k" "$src" "$ver" "$vid"
      continue
    fi
    case "$k" in
      rules) f="$checkout/rules/CLAUDE.md" ;;
      watcher) f="$harness/prompts/$project.md" ;;
      *) f="$harness/prompts/stages/$k.md" ;;
    esac
    if [ -f "$f" ] && sha=$(git hash-object -- "$f" 2>/dev/null) && [ -n "$sha" ]; then
      printf 'PROMPT %s: repo default (%s)\n' "$k" "${sha:0:12}"
    else
      printf 'PROMPT %s: repo default (no file)\n' "$k"
    fi
  done
}

prompt_note_append() {
  local build=$1 project=$2 lines h=${HARNESS:-${H:-}}
  [ -n "$h" ] && [ -f "$build/evidence.md" ] || return 1
  lines=$(prompt_note_lines "$project" "$h" "${HARNESS_CHECKOUT:-${h%/*}/harness-checkout}") || return 1
  [ -n "$lines" ] || return 1
  # evidence.md ends with a newline when result.sh wrote it; a file that does
  # not gets one, so the first PROMPT line starts its own line.
  [ -z "$(tail -c 1 "$build/evidence.md")" ] || printf '\n' >> "$build/evidence.md"
  printf '%s\n' "$lines" >> "$build/evidence.md"
}
