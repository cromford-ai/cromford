#!/bin/bash
# bin/lib/stage-iron-laws.sh — the iron-law text a model stage carries in its
# system prompt (BH-6557). Sourced by bin/agent-call.sh; no side effects here.
#
# A law set is one file <dir>/*.md:
#   line 1   stages: <stage> <stage> ...   (bin/agent-call.sh stage names)
#   line 2   empty
#   line 3-  the law text, verbatim
# A new law set is a new file, never an append to another one.

# sil_text <stage> <dir> — print the body of every <dir>/*.md whose `stages:`
# line lists <stage> as a whole word, in file-name order, one empty line
# between bodies. A file whose line 1 is not a `stages:` line is skipped.
# Missing dir, empty stage or no match prints nothing. Always returns 0.
sil_text() {
  local stage="${1:-}" dir="${2:-}" f first body out="" w; local -a words
  [ -n "$stage" ] && [ -n "$dir" ] && [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] && [ -r "$f" ] || continue
    first=""; IFS= read -r first < "$f" || [ -n "$first" ] || continue
    first="${first//$'\r'/}"
    case "$first" in stages:*) ;; *) continue ;; esac
    read -ra words <<< "${first#stages:}"
    for w in ${words[@]+"${words[@]}"}; do
      [ "$w" = "$stage" ] || continue
      body=$(tail -n +3 "$f" | tr -d '\r'; printf x); body="${body%x}"
      body="${body%$'\n'}"
      out="${out:+$out$'\n\n'}$body"
      break
    done
  done
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}
