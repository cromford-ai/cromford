#!/bin/bash
# bin/lib/claim-roots.sh — the top-level directories a project's plans may claim
# beyond bin/planned-files.sh's default prefixes (src, prisma, scripts, ...).
# Sourced; defines functions only. The rows are catalog/claim-roots.d/<project>.txt,
# one directory name per line. A project with no row claims the defaults only.
#
# claim_roots_project <catalog-dir> <project-or-dir-basename>
#   prints the project whose row applies, or nothing. An exact row name wins.
#   Else a leading `pool-` is stripped and the LONGEST row name p with the name
#   starting `<p>-` wins, so cromford-BH-1-<stamp> is cromford even
#   when a row `board` exists.
# claim_roots_list <catalog-dir> <project>
#   prints the row's roots, one per line. Blank lines and `#` comments are
#   skipped, and a line that is not one plain name (^[A-Za-z0-9._-]+$, not . or
#   ..) is dropped. A missing row prints nothing, rc 0.

claim_roots_project() {
  local cat="${1:-}" name="${2:-}" f p best=""
  [ -n "$cat" ] && [ -n "$name" ] && [ -d "$cat/claim-roots.d" ] || return 0
  if [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] && [ -f "$cat/claim-roots.d/$name.txt" ]; then
    printf '%s\n' "$name"; return 0
  fi
  name="${name#pool-}"
  for f in "$cat/claim-roots.d"/*.txt; do
    [ -f "$f" ] || continue
    p=$(basename "$f" .txt)
    case "$name" in "$p"-*) [ "${#p}" -gt "${#best}" ] && best="$p" ;; esac
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

claim_roots_list() {
  local cat="${1:-}" p="${2:-}" r
  [ -n "$cat" ] && [[ "$p" =~ ^[A-Za-z0-9._-]+$ ]] && [ -r "$cat/claim-roots.d/$p.txt" ] || return 0
  while IFS= read -r r || [ -n "$r" ]; do
    r="${r#"${r%%[![:space:]]*}"}"; r="${r%"${r##*[![:space:]]}"}"
    case "$r" in ''|'#'*|.|..) continue ;; esac
    [[ "$r" =~ ^[A-Za-z0-9._-]+$ ]] && printf '%s\n' "$r"
  done < "$cat/claim-roots.d/$p.txt"
  return 0
}
